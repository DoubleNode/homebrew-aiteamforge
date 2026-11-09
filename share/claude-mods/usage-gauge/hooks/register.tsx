import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, SessionCost, SessionRateLimit } from 'claude-code'

import type { Gauge, Window } from '../types'
import { createSwitch } from './switches'
import type { SwitchIo } from './switches'
import {
  AMBER,
  CHIP,
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
}

// Change the tag when Gauge's fields change: it declines what an older
// version stored, which outlives a reload.
const gauge = atom({ plugin: 'usage-gauge', key: 'gauge' } as const, EMPTY, { shape: 'gauge-1' })
const warn = atom({ plugin: 'usage-gauge', key: 'warn' } as const, DEFAULT_WARN)
// On/off and shown/hidden live in the shared switch file (hooks/switches.ts), read by every chat.
const sw = createSwitch('usage-gauge')

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
  '/usage-gauge hide|show    hide the line and status text but keep measuring, or show them again',
  '/usage-gauge warn 75 90   toast when a window crosses these percents (remembered)',
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

export const register: Register = on => {
  // The cost when this main turn began, for "(+$x)".
  let costAtTurnStart: number | null = null

  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'usage-gauge',
      description: 'Plan usage: pane, or on | off | warn <a> <b> | status',
      argumentHint: '[on|off|warn <a> <b>|status]',
    })
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
    await update($, gauge, g => ({ ...g, utcOffsetMin: offset }))

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

    return next(e)
  })

  on('session.measure', async ($, e, next) => {
    await measure($, e, await $.clock.now())

    return next(e)
  })

  on('turn.start', async ($, e, next) => {
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
    }

    return next(e)
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
    if (word === 'status') {
      const g = await read($, gauge)
      const at = await $.clock.now()
      const lines = g.windows.map(w => {
        const when = resetLabel(w.resetsAt, at, g.utcOffsetMin)

        return `${long(w.kind)}: ${w.percentUsed}%${when === null ? '' : `, resets ${when}`}`
      })
      if (g.windows.length === 0) lines.push('No plan windows reported (API billing, or no response yet).')
      if (g.costUsd !== null) lines.push(`Session: ${usd(g.costUsd)} on API pricing`)

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
    if (!hasWindows && g.costUsd === null && g.contextPercent === null) return below

    const { Box, Text } = $.ui.resolve(e)
    const five = g.windows.find(w => w.kind === 'five_hour')
    const outIn = five === undefined ? null : paceOutMs(g.readings, five.resetsAt, now)

    return (
      <Box flexDirection="column">
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
