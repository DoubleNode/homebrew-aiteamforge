import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, SessionCost, SessionRateLimit } from 'claude-code'

import type { CacheClock, Gauge, Window } from '../types'
import { createSwitch, readSwitchFile, setSwitch, stateFrom } from './switches'
import type { SwitchIo } from './switches'
import {
  AMBER,
  CHIP,
  GREEN,
  bar,
  color,
  hasPacePair,
  long,
  paceOutMs,
  resetLabel,
  short,
  span,
  usd,
} from './layout'
import {
  GUARD_MIN_TOKENS,
  cacheText,
  cacheView,
  coldCost,
  effortLabel,
  isRestorable,
  menuEffort,
  parseCacheTtl,
  tokens,
  ttlName,
} from './cache'

const PANE = 'usage-gauge'
const TICK_MS = 60_000
const KEEP_TURNS = 10
const KEEP_READINGS = 30
const DEFAULT_WARN = [75, 90]

const EMPTY: Gauge = {
  windows: [],
  contextPercent: null,
  costUsd: null,
  lastTurnUsd: null,
  turns: [],
  readings: [],
  toasted: {},
  utcOffsetMin: 0,
  tick: 0,
  effortSent: null,
  effortMenu: null,
  effortBase: null,
  cache: null,
}

// Change the tag when Gauge's fields change: it declines what an older
// version stored, which outlives a reload.
const gauge = atom({ plugin: 'usage-gauge', key: 'gauge' } as const, EMPTY, { shape: 'gauge-2' })
const warn = atom({ plugin: 'usage-gauge', key: 'warn' } as const, DEFAULT_WARN)
// On/off and shown/hidden live in the shared switch file (hooks/switches.ts), read by every chat.
const sw = createSwitch('usage-gauge')
// The cold-send guard (018) has its own key in the same file. Missing means OFF: it is read when a prompt
// arrives, so there is no poll for it.
const GUARD_KEY = 'usage-gauge:cold-guard'
// The cache line has its own on/off, default on (key `usage-gauge:cache`), so hiding it keeps the plan line.
const swCache = createSwitch('usage-gauge:cache')
const TAIL_BYTES = 400_000
const COUNTDOWN_MS = 1000

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

const HELP = [
  '/usage-gauge              open the Usage pane',
  '/usage-gauge on|off       turn the gauge on or off in every chat (remembered)',
  '/usage-gauge hide|show    hide the line and status text but keep measuring,',
  '                          or show them again',
  '/usage-gauge warn 75 90   toast at these window percents (remembered)',
  '/usage-gauge cache        the cache line above the prompt: cache on|off',
  '                          (default on, remembered)',
  '/usage-gauge cold-guard   hold a person-sent prompt once when the cache is cold:',
  '                          cold-guard on|off (default off)',
  '/usage-gauge status       the figures as text',
].join('\n')

type Figures = { context: { percent?: number }; rateLimits: readonly SessionRateLimit[]; cost?: SessionCost }

// The local offset, from the host's own clock settings: the module's time
// zone need not be the person's.
async function utcOffset($: EngineInterface): Promise<number> {
  const ran = await $.process.run(['date', '+%z'], { timeoutMs: 5000 }).catch(() => null)
  const hit = /^([+-])(\d{2})(\d{2})/.exec(ran?.stdout.trim() ?? '')
  if (hit === null) return 0
  const minutes = Number(hit[2]) * 60 + Number(hit[3])

  return hit[1] === '-' ? -minutes : minutes
}

async function measure($: EngineInterface, f: Figures, at: number): Promise<void> {
  if (sw.off) return
  const thresholds = await read($, warn)
  const crossed: string[] = []

  await update($, gauge, g => {
    const windows: Window[] = f.rateLimits.map(w => ({
      kind: w.kind,
      percentUsed: w.percentUsed,
      resetsAt: w.resetsAt ?? null,
    }))
    const five = windows.find(w => w.kind === 'five_hour')
    const lastFive = g.windows.find(w => w.kind === 'five_hour')
    const isNewFive = five !== undefined && lastFive !== undefined && five.resetsAt !== lastFive.resetsAt
    const readings =
      five === undefined
        ? []
        : [...(isNewFive ? [] : g.readings), { at, percent: five.percentUsed }].slice(-KEEP_READINGS)

    // Each threshold toasts once per window per reset.
    const toasted = { ...g.toasted }
    for (const w of windows) {
      const id = `${w.kind}@${w.resetsAt ?? ''}`
      const done = toasted[id] ?? []
      const fresh = thresholds.filter(t => w.percentUsed >= t && !done.includes(t))
      if (fresh.length === 0) continue
      toasted[id] = [...done, ...fresh]
      const top = Math.max(...fresh)
      const when = resetLabel(w.resetsAt, at, g.utcOffsetMin)
      crossed.push(`${long(w.kind)} at ${top}%${when === null ? '' : ` — resets ${when}`}`)
    }

    return {
      ...g,
      windows,
      readings,
      toasted,
      contextPercent: f.context.percent ?? g.contextPercent,
      costUsd: f.cost?.usd ?? g.costUsd,
    }
  })

  for (const text of crossed) $.ui.toast(text)
  await showStatus($)
}

// The status text under the prompt: the plan windows, or nothing while the gauge is off or hidden.
async function showStatus($: EngineInterface): Promise<void> {
  const g = await read($, gauge)
  const statusText = g.windows.map(w => `${w.kind === 'seven_day' ? 'wk' : short(w.kind)} ${Math.round(w.percentUsed)}%`)
  $.ui.status(sw.shown && statusText.length > 0 ? statusText.join(' · ') : undefined)
}

const projectSlug = (cwd: string): string => cwd.replace(/[^A-Za-z0-9]/g, '-')

// The tail of this chat's transcript, or null when it cannot be found or read whole enough to trust
// (a consumer layout with no transcript access lands here, and the clock then draws nothing).
async function transcriptTail($: EngineInterface): Promise<string | null> {
  try {
    const id = await $.session.id()
    const cwd = await $.session.cwd()
    const home = (await switchIo($).home()) ?? ''
    const fromEnv = await $.env.get('CLAUDE_CONFIG_DIR').catch(() => undefined)
    const base = fromEnv !== undefined && fromEnv !== '' ? fromEnv : home === '' ? '' : `${home}/.claude`
    if (base === '' || id === '') return null
    const direct = `${base}/projects/${projectSlug(cwd)}/${id}.jsonl`
    let path: string | null = (await $.fs.exists(direct)) ? direct : null
    if (path === null) {
      for (const d of await $.fs.list(`${base}/projects`)) {
        const candidate = `${base}/projects/${d.name}/${id}.jsonl`
        if (d.kind === 'dir' && (await $.fs.exists(candidate))) {
          path = candidate
          break
        }
      }
    }
    if (path === null) return null
    const ran = await $.process.run(['tail', '-c', String(TAIL_BYTES), path], { timeoutMs: 5000 })

    return ran.exitCode === 0 && !ran.isStdoutTruncated ? ran.stdout : null
  } catch {
    return null
  }
}

// The cache clock as of a reply that just ended; null when the transcript says nothing usable.
async function readCache($: EngineInterface, at: number): Promise<CacheClock | null> {
  const tail = await transcriptTail($)
  const ttl = tail === null ? null : parseCacheTtl(tail)
  if (ttl === null) return null
  const usage = await $.session.usage().catch(() => null)
  const used = usage?.context.tokens

  return { ...ttl, lastEnd: at, contextTokens: typeof used === 'number' ? used : null }
}

async function guardOn($: EngineInterface): Promise<boolean> {
  const io = switchIo($)
  const json = await readSwitchFile(io, sw.home || ((await io.home()) ?? ''))

  return json !== null && !stateFrom(json, GUARD_KEY, true).off
}

export const register: Register = on => {
  // The cost when this main turn began, for "(+$x)".
  let costAtTurnStart: number | null = null
  // A main turn is running (the clock hides while it is).
  let working = false
  // When the warm cache goes cold, for the one-second countdown tick; 0 when there is none to count.
  let warmUntil = 0
  // The session has a screen and a person (headless runs are never held).
  let interactive = false
  // The reply end a cold-send hold was issued for: the resend of that prompt proceeds.
  let heldFor: number | null = null

  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'usage-gauge',
      description: 'Plan usage: pane, or on | off | warn <a> <b> | status',
      argumentHint: '[on|off|warn <a> <b>|status]',
    })
    await swCache.start(switchIo($))
    await sw.start(switchIo($), async () => {
      if (!sw.off) {
        const usage = await $.session.usage().catch(() => null)
        if (usage !== null) await measure($, usage, await $.clock.now())
      }
      await showStatus($)
    })
    const storedWarn = await $.store.get('warn')
    if (Array.isArray(storedWarn) && storedWarn.every(n => typeof n === 'number')) {
      await update($, warn, () => storedWarn as number[])
    }
    const offset = await utcOffset($)
    interactive = e.isInteractive && e.surface !== null
    working = false
    warmUntil = 0
    heldFor = null
    await update($, gauge, g => ({
      ...g,
      utcOffsetMin: offset,
      effortSent: null,
      effortMenu: null,
      effortBase: null,
      cache: null,
    }))

    const usage = await $.session.usage().catch(() => null)
    if (usage !== null) await measure($, usage, await $.clock.now())

    // Countdowns move with the clock, not only with readings.
    $.clock.every(TICK_MS, () => {
      if (sw.off) return
      void (async () => {
        const at = await $.clock.now()
        await update($, gauge, g => ({ ...g, tick: at }))
      })()
    })

    // The cache countdown moves every second, but only while one is on screen: idle and warm.
    $.clock.every(COUNTDOWN_MS, () => {
      if (!sw.shown || working || warmUntil === 0) return
      void (async () => {
        const at = await $.clock.now()
        if (at > warmUntil + COUNTDOWN_MS) return
        await update($, gauge, g => ({ ...g, tick: at }))
      })()
    })

    return next(e)
  })

  on('session.measure', async ($, e, next) => {
    await measure($, e, await $.clock.now())

    return next(e)
  })

  on('turn.start', async ($, e, next) => {
    if (e.agentId === undefined) working = true
    if (e.agentId === undefined && !sw.off) costAtTurnStart = (await read($, gauge)).costUsd

    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    if (e.agentId === undefined && !sw.off) {
      const usage = await $.session.usage().catch(() => null)
      const at = await $.clock.now()
      const now = usage?.cost?.usd ?? null
      if (now !== null && costAtTurnStart !== null) {
        const turn = Math.max(0, now - costAtTurnStart)
        await update($, gauge, g => ({
          ...g,
          costUsd: now,
          lastTurnUsd: turn,
          turns: [...g.turns, { at, usd: turn }].slice(-KEEP_TURNS),
        }))
      } else if (now !== null) {
        await update($, gauge, g => ({ ...g, costUsd: now }))
      }
      costAtTurnStart = null
      // The reply ended: the cache clock restarts from now, with the lifetime the transcript shows. A turn
      // with no usage (interrupted before an answer, an API error) did not touch the cache.
      if (e.usage !== undefined) {
        const cache = await readCache($, at)
        warmUntil = cache === null ? 0 : cache.lastEnd + cache.ttlMs
        await update($, gauge, g => ({ ...g, cache }))
      }
    }
    if (e.agentId === undefined) working = false

    return next(e)
  })

  // The effort the main chat's request actually carries, read on its way out. Observation only.
  on('turn.step', async function* ($, e, next) {
    if (e.agentId === undefined && !sw.off) {
      const sent = e.effort === undefined ? null : String(e.effort)
      const rows = await $.config.list().catch(() => [])
      const menu = menuEffort(rows)
      await update($, gauge, g => ({ ...g, effortSent: sent, effortMenu: menu, effortBase: g.effortBase ?? sent }))
    }

    return yield* next(e)
  })

  // The footer's mode labels (right of the prompt): add `Effort <level>` when it differs from the menu.
  on('ui.render', { component: 'SessionMode' }, async ($, e, next) => {
    if (!sw.shown) return next(e)
    const g = await read($, gauge)
    const label = effortLabel(g.effortSent, g.effortMenu, g.effortBase)
    if (label === null) return next(e)

    return next({ ...e, props: { ...e.props, modes: [...e.props.modes, label] } })
  })

  // Cold-send guard: a prompt a person sent into a cold cache of a big context is held once.
  on('prompt.submit', async ($, e, next) => {
    if (sw.off || !interactive || e.isMeta === true || e.command !== undefined || e.turnId !== undefined) return next(e)
    if (!isRestorable(e)) return next(e)
    const { cache } = await read($, gauge)
    if (cache === null || cache.contextTokens === null || cache.contextTokens < GUARD_MIN_TOKENS) return next(e)
    if (cacheView(cache, await $.clock.now())?.state !== 'cold') return next(e)
    if (heldFor === cache.lastEnd || !(await guardOn($))) return next(e)

    // Put the text back first and only hold when the box confirms it has it; otherwise let the prompt go.
    const filled = await $.prompt.fill({ text: e.text }).catch(() => ({ isFilled: false }))
    if (!filled.isFilled) return next(e)
    heldFor = cache.lastEnd

    return {
      drop: `Held once: the prompt cache is cold (${ttlName(cache.ttlMs)} TTL). Sending now re-writes ${coldCost(cache) ?? 'the whole context'}. Send again to proceed, or /usage-gauge cold-guard off.`,
    }
  })

  on('command.run', { command: 'usage-gauge' }, async ($, e) => {
    const [word = '', ...rest] = e.args.trim().toLowerCase().split(/\s+/)

    if (word === '' && sw.off) return { text: 'Usage gauge is off. Turn it on with /usage-gauge on, or in /mods.' }
    if (word === '') {
      const { isPlaced } = await $.ui.open({ id: PANE, title: 'Usage' })

      return { text: isPlaced ? 'Usage pane opened.' : 'Usage pane opens once there is room for it.' }
    }
    if (word === 'on' || word === 'off' || word === 'hide' || word === 'show') {
      const patch = word === 'on' ? { off: false, hidden: false } : word === 'off' ? { off: true } : { hidden: word === 'hide' }
      if (!(await sw.set(switchIo($), patch))) return { text: 'Usage gauge: could not save the switch (switches.json is unreadable).' }

      return { text: `Usage gauge ${word}.` }
    }
    if (word === 'warn') {
      const levels = rest.map(Number)
      if (levels.length === 0 || levels.some(n => !Number.isFinite(n) || n <= 0 || n > 100)) {
        return { text: 'Give one or more percents between 1 and 100: /usage-gauge warn 75 90' }
      }
      const sorted = [...new Set(levels)].sort((a, b) => a - b)
      await update($, warn, () => sorted)
      await $.store.set('warn', sorted)

      return { text: `Usage gauge warns at ${sorted.join('% and ')}%.` }
    }
    if (word === 'cache') {
      const arg = rest[0] ?? 'status'
      if (arg === 'on' || arg === 'off') {
        if (!(await swCache.set(switchIo($), { off: arg === 'off' }))) {
          return { text: 'Cache line: could not save the switch (switches.json is unreadable).' }
        }
        const at = await $.clock.now()
        await update($, gauge, g => ({ ...g, tick: at }))

        return { text: `Cache line ${arg}.` }
      }

      return { text: `Cache line is ${swCache.off ? 'off' : 'on'}. Turn it ${swCache.off ? 'on' : 'off'} with /usage-gauge cache ${swCache.off ? 'on' : 'off'}.` }
    }
    if (word === 'cold-guard') {
      const arg = rest[0] ?? 'status'
      if (arg === 'on' || arg === 'off') {
        const io = switchIo($)
        const saved = await setSwitch(io, sw.home || ((await io.home()) ?? ''), GUARD_KEY, { off: arg === 'off' }, true)

        return { text: saved ? `Cold-send guard ${arg}.` : 'Cold-send guard: could not save the switch (switches.json is unreadable).' }
      }

      return {
        text: `Cold-send guard is ${(await guardOn($)) ? 'on' : 'off'} (holds a person-sent prompt once, when the cache is cold and the context is ${tokens(GUARD_MIN_TOKENS)}+ tokens).`,
      }
    }
    if (word === 'status') {
      const g = await read($, gauge)
      const at = await $.clock.now()
      const lines = g.windows.map(w => {
        const when = resetLabel(w.resetsAt, at, g.utcOffsetMin)

        return `${long(w.kind)}: ${w.percentUsed}%${when === null ? '' : `, resets ${when}`}`
      })
      if (g.windows.length === 0) lines.push('No plan windows reported (API billing, or no response yet).')
      if (g.costUsd !== null) lines.push(`Session: ${usd(g.costUsd)} on API pricing`)
      const cache = cacheText(g.cache, at, g.utcOffsetMin)
      if (cache !== null) lines.push(cache.text)
      const effort = effortLabel(g.effortSent, g.effortMenu, g.effortBase)
      if (effort !== null) lines.push(`${effort} (the last request; the menu holds ${g.effortMenu ?? 'an unreadable value'})`)

      return { text: lines.join('\n') }
    }

    return { text: `Unknown option "${word}".\n${HELP}` }
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const below = await next(e)
    if (e.props.hasSurvey || !sw.shown) return below

    const g = await read($, gauge)
    const now = await $.clock.now()
    const hasWindows = g.windows.length > 0
    // The cache line shows only while idle: a running turn is using the cache, not letting it cool.
    const cache = e.props.isWorking || swCache.off ? null : cacheText(g.cache, now, g.utcOffsetMin)
    const hasPlan = hasWindows || g.costUsd !== null || g.contextPercent !== null
    if (!hasPlan && cache === null) return below

    const { Box, Text } = $.ui.resolve(e)
    const five = g.windows.find(w => w.kind === 'five_hour')
    const outIn = five === undefined ? null : paceOutMs(g.readings, five.resetsAt, now)

    return (
      <Box flexDirection="column">
        {hasPlan && (
          <Text wrap="truncate-end">
            <Text color={CHIP.color} backgroundColor={CHIP.bg} weight="bold">
              {CHIP.text}
            </Text>
            {g.windows.map((w, i) => {
              const when = resetLabel(w.resetsAt, now, g.utcOffsetMin)

              return (
                <Text>
                  {i > 0 && <Text dimColor> │</Text>} {short(w.kind)} <Text color={color(w.percentUsed)}>{bar(w.percentUsed, 6)}</Text>{' '}
                  <Text color={color(w.percentUsed)}>{Math.round(w.percentUsed)}%</Text>
                  {when !== null && <Text dimColor> ↻{when}</Text>}
                </Text>
              )
            })}
            {!hasWindows && g.contextPercent !== null && <Text> context {g.contextPercent}%</Text>}
            {g.costUsd !== null && (
              <Text>
                <Text dimColor> │</Text> session {usd(g.costUsd)}
                {g.lastTurnUsd !== null && <Text dimColor> (+{usd(g.lastTurnUsd)})</Text>}
              </Text>
            )}
            {outIn !== null && <Text color={AMBER}> ⚠ at this pace: out in ~{span(outIn)}</Text>}
          </Text>
        )}
        {cache !== null && (
          <Text wrap="truncate-end" color={cache.level === 'ok' ? GREEN : AMBER}>
            {cache.text}
          </Text>
        )}
        {below}
      </Box>
    )
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text } = $.ui.resolve(e)
    const g = await read($, gauge)
    const now = await $.clock.now()
    const cells = Math.max(10, Math.min(40, e.props.bodyColumns - 20))
    const five = g.windows.find(w => w.kind === 'five_hour')
    const outIn = five === undefined ? null : paceOutMs(g.readings, five.resetsAt, now)

    return (
      <Box flexDirection="column">
        {g.windows.length === 0 && (
          <Text dimColor>No plan windows reported: API billing, or no response yet.</Text>
        )}
        {g.windows.map(w => {
          const when = resetLabel(w.resetsAt, now, g.utcOffsetMin)

          return (
            <Box flexDirection="column">
              <Text weight="bold">{long(w.kind)}</Text>
              <Text>
                <Text color={color(w.percentUsed)}>{bar(w.percentUsed, cells)}</Text> {w.percentUsed}%
              </Text>
              {when !== null && <Text dimColor>resets {when}</Text>}
              <Text> </Text>
            </Box>
          )
        })}
        <Text>
          Pace:{' '}
          {outIn !== null ? (
            <Text color={AMBER}>out in ~{span(outIn)} at this rate</Text>
          ) : (
            <Text dimColor>{hasPacePair(g.readings) ? 'fine until the reset' : 'needs two readings 5 minutes apart'}</Text>
          )}
        </Text>
        {g.contextPercent !== null && <Text>Context: {g.contextPercent}%</Text>}
        {g.costUsd !== null && <Text>Session: {usd(g.costUsd)} on API pricing</Text>}
        {cacheText(g.cache, now, g.utcOffsetMin) !== null && <Text>Cache: {cacheText(g.cache, now, g.utcOffsetMin)?.text}</Text>}
        <Text> </Text>
        <Text weight="bold">Last {KEEP_TURNS} turns</Text>
        {g.turns.length === 0 && <Text dimColor>None yet.</Text>}
        {g.turns.map((t, i) => (
          <Text>
            <Text dimColor>{String(i + 1).padStart(2)}.</Text> {usd(t.usd)}
          </Text>
        ))}
      </Box>
    )
  })
}
