import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import { EMPTY, footerLabel, isHeld, levelName, release, shouldOffer, stepEffort } from './floor'
import { LABEL, SHORT, classify, isRoundLimit, runsMonitor } from './signals'
import type { SignalClass } from './signals'
import { createSwitch } from './switches'
import type { SwitchIo } from './switches'

// XACA-1640: before a high-stakes action no downstream gate re-checks (merge, tap release, the homebrew-tap
// gitlink, arming the publisher, acting on a ROUND_LIMIT verdict), offer once per turn to hold it and run it
// again at High effort. Raise-only, never automatic, main loop only, no classifier: see hooks/floor.ts for
// why the raise lands on the NEXT turn (measured: a mid-turn rewrite does not reach the request).

const floor = atom({ plugin: 'effort-floor', key: 'floor' } as const, EMPTY, { shape: 'floor-2' })
// On/off and shown/hidden live in the shared switch file (hooks/switches.ts), read by every chat.
const sw = createSwitch('effort-floor')

// BEGIN switch-io (identical in every mod; tests/test-claude-mods-switches-sync.sh keeps it so)
const switchIo = ($: EngineInterface): SwitchIo => ({
  exists: path => $.fs.exists(path),
  read: path => $.fs.read(path),
  write: (path, text) => $.fs.write(path, text),
  run: argv => $.process.run(argv, { timeoutMs: 5000 }),
  home: () => $.env.get('HOME'),
  every: (ms, fn) => $.clock.every(ms, fn),
  root: $.plugin.root,
})
// END switch-io

export const HOLD = 'Hold, re-run at High'
export const RUN = 'Run now'
export const PAUSE = 'Pause, decide at High'
export const CONTINUE = 'Continue'

// Set at session.start: a dismissed dialog means cancel only where a person could have answered it.
let isInteractive = false

const HELP = [
  '/effort-floor          status: the effort being sent, any hold or raise, and this chat\'s counts',
  '/effort-floor on       offer a hold before a high-stakes action at Low/Medium effort (every chat, remembered)',
  '/effort-floor off      never offer; nothing is held or raised',
  '/effort-floor hide     keep offering but drop the footer label; /effort-floor show brings it back',
  '/effort-floor help     this text',
  '',
  'Watched (main chat only, Bash): kb-merge / gh pr merge, kb-tap-release patch|minor|major|--push-tap-edit,',
  'git add|commit naming homebrew-tap, gh variable set TAP_PUBLISHER_ENABLED, a kb-pr-monitor ROUND_LIMIT verdict.',
].join('\n')

const question = (cls: SignalClass, sent: string | null) =>
  cls === 'round-limit'
    ? `ROUND_LIMIT reached at ${levelName(sent)} effort. Pause and decide the next step at High from your next message? (Esc pauses)`
    : `About to ${LABEL[cls]} at ${levelName(sent)} effort. Hold it and re-run at High from your next message? (Esc cancels it)`

const held = (cls: SignalClass, sent: string | null) =>
  cls === 'round-limit'
    ? `effort-floor paused after kb-pr-monitor returned ROUND_LIMIT (effort ${levelName(sent)}). Effort is raised to ` +
      "High from the user's next message. Stop now: do not merge, push, re-run the monitor or start another fix round " +
      'in this turn. Tell the user and ask them to reply "go"; then decide the next step at High.'
    : `effort-floor held this (${LABEL[cls]}, effort ${levelName(sent)}). Effort is raised to High from the user's next ` +
  'message. Stop now: do not retry this command or work around the hold in this turn. Tell the user it is held ' +
  'and ask them to reply "go"; then re-check the facts and run it again at High.'

// `null` is a kb-pr-monitor run refused in the cancelled turn (it can merge on green): named as itself, not a merge.
const cancelled = (cls: SignalClass | null) =>
  `effort-floor: the user dismissed the effort question, so this (${cls === null ? 'a kb-pr-monitor run, which can merge' : LABEL[cls]}) did not run and effort is unchanged. ` +
  'Do not retry it or any other merge, release, gitlink or publisher command in this turn; ask the user how to proceed.'

type Choice = 'hold' | 'run' | 'cancel'

/**
 * Ask once. A dismissed dialog (or text typed under Other) in an interactive session is a cancel (Esc means cancel
 * in Claude Code dialogs; PR #1320 UX gate); with no one to ask (claude -p) it runs as it was (fail open). On the
 * ROUND_LIMIT path the monitor has already run, so a cancel there is a pause, the safe direction.
 */
async function askHold($: EngineInterface, cls: SignalClass, sent: string | null): Promise<Choice> {
  await update($, floor, f => ({ ...f, offeredTurn: f.turnId, counts: { ...f.counts, offered: f.counts.offered + 1 } }))
  const [yes, no] = cls === 'round-limit' ? [PAUSE, `${CONTINUE} at ${levelName(sent)}`] : [HOLD, `${RUN} at ${levelName(sent)}`]
  const answer = await $.ui.ask(question(cls, sent), { header: 'Effort', options: [yes, no] }).catch(() => null)
  let choice: Choice = answer === yes ? 'hold' : answer === no ? 'run' : isInteractive ? 'cancel' : 'run'
  if (choice === 'cancel' && cls === 'round-limit') choice = 'hold'
  await update($, floor, f =>
    choice === 'hold'
      ? { ...f, pending: cls, counts: { ...f.counts, held: f.counts.held + 1 } }
      : choice === 'cancel'
        ? { ...f, cancelledTurn: f.turnId, counts: { ...f.counts, cancelled: f.counts.cancelled + 1 } }
        : { ...f, counts: { ...f.counts, ran: f.counts.ran + 1 } },
  )
  if (choice === 'hold') $.ui.invalidate('ui.render')

  return choice
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    isInteractive = e.isInteractive === true
    await $.command.register({
      name: 'effort-floor',
      description: 'Offer to hold high-stakes actions taken at low effort: status, or on | off | hide | show | help',
      argumentHint: '[on|off|hide|show|help]',
    })
    await sw.start(switchIo($), async () => {
      if (sw.off) await update($, floor, f => ({ ...f, pending: null, active: null }))
      $.ui.invalidate('ui.render')
    })

    return next(e)
  })

  on('command.run', { command: 'effort-floor' }, async ($, e) => {
    const arg = e.args.trim().toLowerCase()
    if (arg === '' || arg === 'status') {
      const f = await read($, floor)
      const state = sw.off
        ? 'off'
        : f.active !== null
          ? `raised to High this turn (${SHORT[f.active.cls]})`
          : f.pending !== null
            ? `held: High from your next message (${SHORT[f.pending]})`
            : 'watching'
      const c = f.counts

      return { text: `Effort floor: ${state}. Effort sent: ${levelName(f.sent)}. This chat: ${c.offered} offered, ${c.held} held, ${c.cancelled} cancelled, ${c.ran} ran as-is.` }
    }
    if (arg === 'on' || arg === 'off' || arg === 'hide' || arg === 'show') {
      const patch = arg === 'on' ? { off: false, hidden: false } : arg === 'off' ? { off: true } : { hidden: arg === 'hide' }
      if (!(await sw.set(switchIo($), patch))) return { text: 'Effort floor: could not save the switch (switches.json is unreadable).' }

      return { text: `Effort floor ${arg}.` }
    }
    if (arg === 'help') return { text: HELP }

    return { text: `Unknown option "${arg}".\n${HELP}` }
  })

  on('turn.start', async ($, e, next) => {
    if (e.agentId === undefined) await update($, floor, f => ({ ...f, turnId: e.turnId }))

    return next(e)
  })

  // The only write: step 0 of the main loop's turn after a Hold, raised to High (never lowered).
  on('turn.step', async function* ($, e, next) {
    if (e.agentId !== undefined) return yield* next(e)
    const f = await read($, floor)
    const { effort, next: after } = stepEffort(sw.off ? { ...f, pending: null } : f, e)
    await update($, floor, () => after)
    if (after.active !== f.active) $.ui.invalidate('ui.render')

    return yield* next(effort === e.effort ? e : { ...e, effort: effort as typeof e.effort })
  })

  on('turn.complete', async ($, e, next) => {
    if (e.agentId === undefined) {
      const f = await read($, floor)
      const after = release(f, e.turnId)
      if (after !== f) {
        await update($, floor, () => after)
        $.ui.invalidate('ui.render')
      }
    }

    return next(e)
  })

  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    if (sw.off || e.agentId !== undefined) return next(e)
    const cls = classify(e.command)
    const isMonitor = cls === null && runsMonitor(e.command)
    if (cls === null && !isMonitor) return next(e)
    const held0 = await read($, floor)
    // Held (PR #1320 BLOCKING 1): the stop message is only advice, so a retry, an equivalent command, another
    // class, or a monitor run (which can merge on green) in the held turn is refused too, without asking again.
    if (isHeld(held0) && held0.pending !== null) return { deny: held(held0.pending, held0.sent) }
    if (held0.cancelledTurn !== null && held0.cancelledTurn === held0.turnId) return { deny: cancelled(cls) }
    if (cls !== null) {
      if (!shouldOffer(held0, held0.turnId)) return next(e)
      const choice = await askHold($, cls, held0.sent)
      if (choice === 'hold') return { deny: held(cls, held0.sent) }
      if (choice === 'cancel') return { deny: cancelled(cls) }

      return next(e)
    }

    // kb-pr-monitor: the verdict is in its output, so the call runs first and the hold rides on its result.
    const ran = await next(e)
    if (ran.deny !== undefined || !isRoundLimit(ran.text ?? '')) return ran
    const f = await read($, floor)
    if (!shouldOffer(f, f.turnId) || (await askHold($, 'round-limit', f.sent)) !== 'hold') return ran

    return { ...ran, context: [...(ran.context ?? []), held('round-limit', f.sent)] }
  }).catch(($, e, next) => {
    // Advisory, so it fails OPEN: a fault in this mod must never block the command it watches.
    $.ui.log(`effort-floor: its Bash hook failed; the command ran as-is`, { to: 'debug' })

    // Before next ran: run the command now. After (the monitor path): next(e) hands back that same result.
    return next(e)
  })

  // The footer's mode labels: say so while a hold waits or a raise is on.
  on('ui.render', { component: 'SessionMode' }, async ($, e, next) => {
    if (!sw.shown) return next(e)
    const label = footerLabel(await read($, floor), SHORT)
    if (label === null) return next(e)

    return next({ ...e, props: { ...e.props, modes: [...e.props.modes, label] } })
  })
}
