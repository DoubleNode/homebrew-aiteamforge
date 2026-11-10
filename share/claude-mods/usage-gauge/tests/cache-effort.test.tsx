// XACA-1639: the footer Effort label (005), the cache TTL read from the transcript (014), the warm/cold
// line above the prompt (015) and the cold-send guard (018).
import { expect, mock, test } from 'claude-code/testing'
import type { Engine, TestBody } from 'claude-code/testing'

import { parseCacheTtl } from '../hooks/cache'
import { effortLabel, isRestorable, menuEffort } from '../hooks/cache'
import { switchFiles } from './switch-fixture'
import type { SwitchFiles } from './switch-fixture'

type On = Parameters<TestBody>[1]

const NOW = Date.parse('2026-11-09T15:00:00Z')
const SEC = 1000
const MIN = 60_000
const HOME = '/home/me'
const TRANSCRIPT = `${HOME}/.claude/projects/-work-proj/sess-1.jsonl`

const BAND = (isWorking = false) =>
  ({
    plugin: 'usage-gauge',
    component: 'AbovePrompt',
    props: {
      hasSurvey: false,
      isCollapsed: false,
      isWorking,
      maxRows: 10,
      bodyColumns: 160,
      scroll: { offset: 0, bodyRows: 10 },
      view: {},
    },
    surface: 'terminal',
  }) as const

const USAGE = { input_tokens: 10, output_tokens: 20, cache_read_input_tokens: 0, cache_creation_input_tokens: 0, model: 'm' }

// ---- transcript fixtures (JSON lines, as the host writes them) -------------------------------

const assistant = (split: { m5?: number; h1?: number } | null, extra: Record<string, unknown> = {}) =>
  JSON.stringify({
    type: 'assistant',
    ...extra,
    message: {
      usage: {
        input_tokens: 5,
        cache_creation_input_tokens: (split?.m5 ?? 0) + (split?.h1 ?? 0),
        ...(split === null ? {} : { cache_creation: { ephemeral_5m_input_tokens: split.m5 ?? 0, ephemeral_1h_input_tokens: split.h1 ?? 0 } }),
      },
    },
  })
const user = JSON.stringify({ type: 'user', message: { content: 'hi' } })
const lines = (...l: string[]) => `${l.join('\n')}\n`

type World = {
  files: Record<string, string>
  rows: { key: string; label: string; value: unknown }[]
  contextTokens: number | undefined
  truncated: boolean
  filled: string[]
  fillOk: boolean
  plan: boolean
  tails: string[][]
}

// Nothing sits beneath the plugin: these hooks stand for the engine.
function engine(on: On, world: World, fx: SwitchFiles = switchFiles(HOME)) {
  const clock = mock.clock(on, { now: NOW })
  mock.store(on)
  mock.env(on, { HOME })

  on('command.register', () => ({ value: { command: 'usage-gauge' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.toast', () => ({ value: undefined }))
  on('ui.status', () => ({ value: undefined }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('session.id', () => ({ value: 'sess-1' }))
  on('session.cwd', () => ({ value: '/work/proj' }))
  on('session.usage', () => ({
    value: {
      startedAt: NOW,
      context: { window: 1_000_000, ...(world.contextTokens === undefined ? {} : { tokens: world.contextTokens }) },
      rateLimits: world.plan ? [{ kind: 'five_hour', percentUsed: 34, resetsAt: new Date(NOW + 131 * MIN).toISOString() }] : [],
    },
  }))
  on('session.measure', (_, e) => ({ changed: e.changed }))
  on('config.list', () => ({ value: world.rows.map(r => ({ ...r, kind: 'choice', provider: { plugin: 'engine', tier: 'core' }, isLocked: false })) as never }))
  on('turn.start', (_, e) => ({ turnId: e.turnId }))
  on('turn.complete', (_, e) => ({ text: e.answer }))
  on('turn.step', async function* (_, e) {
    return { turnId: e.turnId, index: e.index, answer: '', toolUses: [], stopReason: 'end_turn' as const, usage: null }
  })
  on('prompt.submit', (_, e) => ({ text: e.text }))
  on('prompt.fill', (_, e) => {
    world.filled.push(e.text)

    return { isFilled: world.fillOk }
  })
  on('fs.exists', (_, e) => ({ value: fx.exists(e.path) || e.path in world.files || e.path === `${HOME}/.claude/projects` }))
  on('fs.read', (_, e) => ({ value: fx.read(e.path) }))
  on('fs.write', (_, e) => {
    fx.write(e.path, e.text)

    return { value: undefined }
  })
  on('fs.list', () => ({ value: [{ name: '-work-proj', kind: 'dir', size: 0, mtimeMs: 0, isLink: false }] }))
  on('process.run', (_, e) => {
    const moved = fx.run(e.argv)
    if (moved) return { value: moved }
    if (e.argv[0] === 'tail') {
      world.tails.push([...e.argv])
      const text = world.files[e.argv[3] ?? '']

      return {
        value: { exitCode: text === undefined ? 1 : 0, stdout: text ?? '', stderr: '', isStdoutTruncated: world.truncated, isStderrTruncated: false },
      }
    }

    return { value: { exitCode: e.argv[0] === 'date' ? 0 : 127, stdout: e.argv[0] === 'date' ? '+0000\n' : '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  // The engine's footer: the mode labels as one line.
  on('ui.render', { component: 'SessionMode' }, ($, e) => {
    const { Text } = $.ui.resolve(e)

    return <Text>{`modes: ${e.props.modes.join(' & ')}`}</Text>
  })
  on('ui.render', { component: 'AbovePrompt' }, ($, e) => {
    const { Text } = $.ui.resolve(e)

    return <Text>other mod line</Text>
  })

  return { clock, fx }
}

const world = (over: Partial<World> = {}): World => ({
  files: { [TRANSCRIPT]: lines(user, assistant({ m5: 900 })) },
  rows: [],
  contextTokens: 412_000,
  truncated: false,
  filled: [],
  fillOk: true,
  plan: false,
  tails: [],
  ...over,
})

const start = ($: Engine, isInteractive = true) =>
  $.session.start({ cwd: '/work/proj', surface: isInteractive ? 'terminal' : null, isInteractive })

// A main-loop reply that ended with usage, so the cache clock restarts.
async function reply($: Engine, id = 't1') {
  await $.turn.start({ text: 'go', turnId: id })
  await $.turn.complete({ answer: 'ok', durationMs: 1, isAborted: false, turnId: id, reason: 'answer', usage: USAGE })
}

async function drain(stream: AsyncGenerator<unknown, unknown>) {
  for await (const _ of stream) {
    // read to the end
  }
}

const step = ($: Engine, effort?: 'low' | 'medium' | 'high' | 'xhigh' | 'max', agentId?: string) =>
  drain($.turn.step({ turnId: 's1', index: 0, model: 'claude-opus-5-5', messageCount: 1, ...(effort ? { effort } : {}), ...(agentId ? { agentId } : {}) }))

async function modes($: Engine) {
  const ui = await $.ui.mount({ plugin: 'usage-gauge', component: 'SessionMode', props: { modes: [] }, surface: 'terminal' })
  const text = (await ui.findAll({ type: 'Text' })).map(t => t.text).find(t => t.startsWith('modes:'))
  await ui.unmount()

  return text
}

async function cacheLine($: Engine, isWorking = false) {
  const ui = await $.ui.mount(BAND(isWorking))
  const texts = (await ui.findAll({ type: 'Text' })).map(t => t.text)
  const node = await ui.find({ type: 'Text', text: /cache (warm|cooling|cold)/ })
  await ui.unmount()

  return { line: texts.find(t => t.includes('cache ')), color: node?.props.color, texts }
}

const submit = ($: Engine, text = 'next', origin: { kind: string } = { kind: 'composer' }, extra: Record<string, unknown> = {}) =>
  $.prompt.submit({ text, wait: false, origin: origin as never, ...extra } as never)

// ---- pure helpers ---------------------------------------------------------------------------

test('effort: menuEffort reads the row by key or label, only for a real level', () => {
  expect(menuEffort([{ key: 'effortLevel', label: 'x', value: 'High' }])).toBe('high')
  expect(menuEffort([{ key: 'k', label: 'Reasoning effort', value: 'max' }])).toBe('max')
  expect(menuEffort([{ key: 'effortLevel', label: 'x', value: 'auto' }])).toBeNull()
  expect(menuEffort([{ key: 'theme', label: 'Theme', value: 'dark' }])).toBeNull()
  expect(menuEffort([])).toBeNull()
})

test('effort: label shows a difference from the menu, else from the first level seen', () => {
  expect(effortLabel('low', 'high', 'high')).toBe('Effort low')
  expect(effortLabel('high', 'high', 'low')).toBeNull()
  expect(effortLabel('high', null, 'high')).toBeNull()
  expect(effortLabel('max', null, 'high')).toBe('Effort max')
  expect(effortLabel(null, 'high', 'high')).toBeNull()
  expect(effortLabel('low', null, null)).toBeNull()
})

test('ttl: the newest main-thread write decides; mixed counts as 5m; unreadable is null', () => {
  expect(parseCacheTtl(lines(assistant({ m5: 10 })))).toEqual({ ttlMs: 5 * MIN, ttlSource: 'detected' })
  expect(parseCacheTtl(lines(assistant({ h1: 10 })))).toEqual({ ttlMs: 60 * MIN, ttlSource: 'detected' })
  expect(parseCacheTtl(lines(assistant({ m5: 1, h1: 10 })))?.ttlMs).toBe(5 * MIN)
  // a sidechain (subagent) record newer than the main one is ignored
  expect(parseCacheTtl(lines(assistant({ m5: 10 }), assistant({ h1: 10 }, { isSidechain: true })))?.ttlMs).toBe(5 * MIN)
  // the newest record wrote nothing: look back to the last that did
  expect(parseCacheTtl(lines(assistant({ h1: 10 }), user, assistant({ m5: 0, h1: 0 })))?.ttlMs).toBe(60 * MIN)
  // a half line at the cut is skipped
  expect(parseCacheTtl(`rt":"x"}}\n${lines(assistant({ h1: 10 }))}`)?.ttlMs).toBe(60 * MIN)
  // readable assistant records with no split: a guess, labelled as one
  expect(parseCacheTtl(lines(assistant(null)))).toEqual({ ttlMs: 5 * MIN, ttlSource: 'guess' })
  // nothing readable
  expect(parseCacheTtl('')).toBeNull()
  expect(parseCacheTtl(lines(user, '{ nope'))).toBeNull()
})

// ---- 005: the footer label ------------------------------------------------------------------

test('005: the footer shows Effort <level> when the request differs from the menu, and hides it when equal', async ($, on) => {
  const w = world({ rows: [{ key: 'effortLevel', label: 'Effort', value: 'high' }] })
  engine(on, w)
  await start($)

  await step($, 'low')
  expect(await modes($)).toBe('modes: Effort low')
  await step($, 'high')
  expect(await modes($), 'equal to the menu: hidden').toBe('modes: ')
  await step($)
  expect(await modes($), 'no effort on the request (a model without effort): hidden').toBe('modes: ')
  await step($, 'xhigh')
  expect(await modes($)).toBe('modes: Effort xhigh')
})

test('005: a subagent step never moves the label', async ($, on) => {
  const w = world({ rows: [{ key: 'effortLevel', label: 'Effort', value: 'high' }] })
  engine(on, w)
  await start($)
  await step($, 'high')
  await step($, 'low', 'agent-1')

  expect(await modes($)).toBe('modes: ')
})

test('005: with no readable menu setting the label flags a change from the first level seen', async ($, on) => {
  const w = world({ rows: [{ key: 'effortLevel', label: 'Effort', value: 'auto' }] })
  engine(on, w)
  await start($)

  await step($, 'medium')
  expect(await modes($), 'the first level is the reference, not a difference').toBe('modes: ')
  await step($, 'max')
  expect(await modes($)).toBe('modes: Effort max')
  await step($, 'medium')
  expect(await modes($)).toBe('modes: ')
})

test('005: a new session forgets the old levels; off and hidden draw no label', async ($, on) => {
  const w = world({ rows: [{ key: 'effortLevel', label: 'Effort', value: 'high' }] })
  const { fx } = engine(on, w)
  await start($)
  await step($, 'low')
  expect(await modes($)).toBe('modes: Effort low')

  fx.put({ 'usage-gauge:hidden': true })
  await $.command.run({ command: 'usage-gauge', args: 'status', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 200 } })
  fx.put({})
  await start($)
  expect(await modes($), 'new session: nothing observed yet').toBe('modes: ')

  await step($, 'low')
  await $.command.run({ command: 'usage-gauge', args: 'hide', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 200 } })
  expect(await modes($)).toBe('modes: ')
})

// ---- 014 / 015: the cache clock -------------------------------------------------------------

test('014/015: a 5m cache counts down above the prompt, goes cooling, then cold with the re-read size', async ($, on) => {
  const w = world()
  const { clock } = engine(on, w)
  await start($)
  await reply($)

  let { line, color } = await cacheLine($)
  expect(line).toBe('◉ cache warm · 5:00 left · 5m TTL · 412k tokens')
  expect(color).toBe('success')

  await clock.advance(2 * MIN + 30 * SEC)
  ;({ line } = await cacheLine($))
  expect(line).toBe('◉ cache warm · 2:30 left · 5m TTL · 412k tokens')

  await clock.advance(1 * MIN + 45 * SEC)
  ;({ line, color } = await cacheLine($))
  expect(line).toBe('◐ cache cooling · 0:45 left · 5m TTL · 412k tokens')
  expect(color).toBe('warning')

  await clock.advance(44 * SEC)
  expect((await cacheLine($)).line).toContain('0:01 left')

  await clock.advance(1 * SEC)
  ;({ line, color } = await cacheLine($))
  expect(line).toBe('◌ cache cold since 15:05 (0m ago) · next message re-writes ~412k tokens · 5m TTL')
  expect(color).toBe('warning')

  await clock.advance(8 * MIN)
  expect((await cacheLine($)).line).toContain('cold since 15:05 (8m ago)')
})

test('014: a 1h cache counts down from an hour', async ($, on) => {
  const w = world({ files: { [TRANSCRIPT]: lines(assistant({ h1: 900 })) } })
  engine(on, w)
  await start($)
  await reply($)

  expect((await cacheLine($)).line).toBe('◉ cache warm · 1:00:00 left · 1h TTL · 412k tokens')
})

test('014: a transcript with no cache split shows a labelled guess, never "detected"', async ($, on) => {
  const w = world({ files: { [TRANSCRIPT]: lines(assistant(null)) } })
  engine(on, w)
  await start($)
  await reply($)

  const { line } = await cacheLine($)
  expect(line).toBe('◉ cache warm · 5:00 left · 5m TTL (guess) · 412k tokens')
})

test('014: the transcript is found by session id when the folder name does not match the slug rule', async ($, on) => {
  const odd = `${HOME}/.claude/projects/-work-proj/sess-1.jsonl`
  const w = world({ files: { [odd]: lines(assistant({ m5: 1 })) } })
  engine(on, w)
  await $.session.start({ cwd: '/work/proj', surface: 'terminal', isInteractive: true })
  await reply($)

  expect((await cacheLine($)).line).toContain('cache warm')
  expect(w.tails[0]?.slice(0, 2)).toEqual(['tail', '-c'])
})

const consumerCases: [string, () => World][] = [
  ['no transcript file', () => world({ files: {} })],
  ['a truncated read', () => world({ truncated: true })],
  ['a transcript with no assistant record', () => world({ files: { [TRANSCRIPT]: lines(user) } })],
]
for (const [name, make] of consumerCases) {
  test(`consumer: ${name} draws no cache line and shows no figure`, async ($, on) => {
    const { clock } = engine(on, make())
    await start($)
    await reply($)
    await clock.advance(10 * MIN)
    const { texts } = await cacheLine($)

    expect(texts.some(t => t.includes('cache '))).toBe(false)
    expect(texts.some(t => t.includes('NaN'))).toBe(false)
  })
}

test('015: no cache line while a turn is working, and none without a reply that carried usage', async ($, on) => {
  const w = world()
  engine(on, w)
  await start($)
  expect((await cacheLine($)).line, 'nothing yet').toBeUndefined()

  await $.turn.start({ text: 'go', turnId: 'x' })
  await $.turn.complete({ answer: '', durationMs: 1, isAborted: true, turnId: 'x', reason: 'aborted' })
  expect((await cacheLine($)).line, 'an interrupted turn with no usage did not touch the cache').toBeUndefined()

  await reply($, 'y')
  expect((await cacheLine($)).line).toContain('cache warm')
  expect((await cacheLine($, true)).line, 'band says a turn is running').toBeUndefined()
})

test('015: a subagent turn does not restart the clock; hidden and off draw nothing', async ($, on) => {
  const w = world()
  const { clock } = engine(on, w)
  await start($)
  await reply($)
  await clock.advance(2 * MIN)
  await $.turn.complete({ answer: 'x', durationMs: 1, isAborted: false, turnId: 'sub', agentId: 'a1', reason: 'answer', usage: USAGE })
  expect((await cacheLine($)).line).toContain('3:00 left')

  await $.command.run({ command: 'usage-gauge', args: 'hide', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 200 } })
  expect((await cacheLine($)).line).toBeUndefined()
})

test('015: the cache line sits above another mod and does not disturb the plan line', async ($, on) => {
  const w = world()
  engine(on, w)
  await start($)
  await reply($)
  const { texts } = await cacheLine($)

  expect(texts.findIndex(t => t.includes('cache warm'))).toBeLessThan(texts.indexOf('other mod line'))
  expect(texts.some(t => t.includes('PLAN'))).toBe(false)
})

// ---- 018: the cold-send guard ---------------------------------------------------------------

async function goCold($: Engine, clock: { advance: (ms: number) => Promise<unknown> }) {
  await start($)
  await reply($)
  await clock.advance(6 * MIN)
}
const guardOn = ($: Engine, arg = 'on') =>
  $.command.run({ command: 'usage-gauge', args: `cold-guard ${arg}`, origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 200 } })

test('018: a person-sent prompt into a cold, big cache is held once; the resend proceeds', async ($, on) => {
  const w = world()
  const { clock, fx } = engine(on, w)
  await goCold($, clock)
  expect((await guardOn($)).text).toBe('Cold-send guard on.')
  expect(fx.json()['usage-gauge:cold-guard']).toBe(true)

  const held = await submit($, 'please continue')
  expect(held.drop).toContain('Held once')
  expect(held.drop).toContain('~412k tokens re-written at 1.25x')
  expect(held.drop).toContain('Send again')
  expect(w.filled).toEqual(['please continue'])

  const again = await submit($, 'please continue')
  expect(again.drop).toBeUndefined()
  expect(again.text).toBe('please continue')
  expect((await submit($, 'and another')).drop, 'one hold per cold stretch').toBeUndefined()

  // the next reply restarts the clock and re-arms the guard
  await reply($, 't2')
  await clock.advance(6 * MIN)
  expect((await submit($, 'later')).drop).toContain('Held once')
})

test('018: default is OFF; off passes; the status line says which', async ($, on) => {
  const w = world()
  const { clock, fx } = engine(on, w)
  await goCold($, clock)

  expect((await guardOn($, 'status')).text).toContain('Cold-send guard is off')
  expect((await submit($)).drop, 'no switch written: passes').toBeUndefined()
  await guardOn($, 'on')
  expect((await guardOn($, 'status')).text).toContain('Cold-send guard is on')
  await guardOn($, 'off')
  expect(fx.json()['usage-gauge:cold-guard']).toBe(false)
  expect((await submit($)).drop).toBeUndefined()
})

test('018: only a person is held: notifications, schedules, peers, the SDK, slash commands and meta pass', async ($, on) => {
  const w = world()
  const { clock } = engine(on, w)
  await goCold($, clock)
  await guardOn($)

  for (const kind of ['task-notification', 'scheduled-trigger', 'sdk']) {
    expect((await submit($, 'n', { kind })).drop, kind).toBeUndefined()
  }
  expect((await submit($, 'm', { kind: 'composer' }, { isMeta: true })).drop, 'meta').toBeUndefined()
  expect((await submit($, '/x', { kind: 'composer' }, { command: { name: 'x', args: '' } })).drop, 'command').toBeUndefined()
  expect((await submit($, 'typed over a running turn', { kind: 'composer' }, { turnId: 't9' })).drop, 'mid-turn').toBeUndefined()
  expect(w.filled, 'nothing held, nothing refilled').toEqual([])
  expect((await submit($, 'a person', { kind: 'composer' })).drop, 'the person is still held afterwards').toContain('Held once')
})

test('018: a headless run (no surface) is never held', async ($, on) => {
  const w = world()
  const { clock } = engine(on, w)
  await start($, false)
  await reply($)
  await clock.advance(6 * MIN)
  await guardOn($)

  expect((await submit($, 'p', { kind: 'composer' })).drop).toBeUndefined()
  expect((await submit($, 'p', { kind: 'sdk' })).drop).toBeUndefined()
})

test('018: warm cache, small context or unknown context size pass', async ($, on) => {
  const w = world()
  const { clock } = engine(on, w)
  await start($)
  await reply($)
  await guardOn($)
  expect((await submit($)).drop, 'warm').toBeUndefined()

  w.contextTokens = 49_999
  await reply($, 't2')
  await clock.advance(6 * MIN)
  expect((await submit($)).drop, 'below 50k').toBeUndefined()

  w.contextTokens = undefined
  await reply($, 't3')
  await clock.advance(6 * MIN)
  expect((await submit($)).drop, 'size unknown: never hold blind').toBeUndefined()

  w.contextTokens = 50_000
  await reply($, 't4')
  await clock.advance(6 * MIN)
  expect((await submit($)).drop, 'exactly 50k is held').toContain('Held once')
})

test('018: a 1h cache is warm at six minutes, and its cost is stated at 2x', async ($, on) => {
  const w = world({ files: { [TRANSCRIPT]: lines(assistant({ h1: 5 })) } })
  const { clock } = engine(on, w)
  await goCold($, clock)
  await guardOn($)
  expect((await submit($)).drop).toBeUndefined()

  await clock.advance(55 * MIN)
  expect((await submit($)).drop).toContain('re-written at 2x')
})

test('018: with the mod off the guard does nothing; an unreadable switch file leaves it off', async ($, on) => {
  const w = world()
  const { clock, fx } = engine(on, w)
  await goCold($, clock)
  await guardOn($)
  fx.put('{ nope')
  expect((await submit($)).drop, 'unreadable file: default off').toBeUndefined()
  fx.put({ 'usage-gauge:cold-guard': true, 'usage-gauge': false })
  await clock.advance(3100)
  expect((await submit($)).drop, 'mod off').toBeUndefined()
})

// XACA-1639-022 / 020: a hold can only put back plain text into the local box, so anything else passes.
const attach = (type: 'image' | 'audio' | 'document') => ({ attachments: [{ type, id: 'a1' }] })
const SHAPES: [string, string, { kind: string }, Record<string, unknown>][] = [
  ['composer + image', 'look', { kind: 'composer' }, attach('image')],
  ['composer + audio', 'listen', { kind: 'composer' }, attach('audio')],
  ['composer + document', 'read', { kind: 'composer' }, attach('document')],
  ['bridge, text only', 'from my phone', { kind: 'bridge' }, {}],
  ['bridge + image', 'from my phone', { kind: 'bridge' }, attach('image')],
  ['composer, attachments of unknown shape', 'x', { kind: 'composer' }, { attachments: 'weird' }],
  ['composer, empty text', '   ', { kind: 'composer' }, {}],
  ['unknown origin kind', 'x', { kind: 'something-new' }, {}],
]

test('022: the restorable shapes are exactly composer + non-empty text + no attachment', () => {
  expect(isRestorable({ text: 'hi', origin: { kind: 'composer' } })).toBe(true)
  expect(isRestorable({ text: 'hi', origin: { kind: 'composer' }, attachments: [] })).toBe(true)
  for (const [, text, origin, extra] of SHAPES) expect(isRestorable({ text, origin, ...extra })).toBe(false)
  expect(isRestorable({ text: 5, origin: { kind: 'composer' } })).toBe(false)
  expect(isRestorable({ text: 'hi' })).toBe(false)
  expect(isRestorable({ text: 'hi', origin: null })).toBe(false)
})

test('022: attachments, bridge, empty and unknown shapes always pass; nothing is refilled', async ($, on) => {
  const w = world()
  const { clock } = engine(on, w)
  await goCold($, clock)
  await guardOn($)

  for (const [name, text, origin, extra] of SHAPES) {
    expect((await submit($, text, origin, extra)).drop, name).toBeUndefined()
  }
  expect(w.filled, 'no hold, so no refill into a box').toEqual([])
  expect((await submit($, 'plain', { kind: 'composer' })).drop, 'plain composer text is still held').toContain('Held once')
  expect(w.filled).toEqual(['plain'])
  expect((await submit($, 'plain', { kind: 'composer' })).drop, 'resend proceeds').toBeUndefined()
})

test('022: a hold whose refill the box does not confirm lets the prompt go', async ($, on) => {
  const w = world({ fillOk: false })
  const { clock } = engine(on, w)
  await goCold($, clock)
  await guardOn($)

  const r = await submit($, 'plain')
  expect(r.drop).toBeUndefined()
  expect(r.text).toBe('plain')
})

// XACA-1639-024: every HELP row's description starts at one column, and continuations line up under it.
const run = ($: Engine, args: string) =>
  $.command.run({ command: 'usage-gauge', args, origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 200 } })

test('024: every /usage-gauge HELP row aligns its description at one column, within 80 columns', async ($, on) => {
  engine(on, world())
  await start($)
  const rows = ((await run($, 'nope')).text ?? '').split('\n').slice(1)
  const cols = rows.filter(r => r.startsWith('/')).map(r => /^\/\S+(?: \S+)*? {2,}(?=\S)/.exec(r)?.[0]?.length)

  expect(rows.length).toBeGreaterThan(5)
  expect(new Set(cols).size, `description columns: ${cols.join(',')}`).toBe(1)
  expect(cols[0]).toBeDefined()
  for (const r of rows) {
    expect(r.length, r).toBeLessThanOrEqual(80)
    if (!r.startsWith('/')) expect(r.length - r.trimStart().length, `continuation: ${r}`).toBe(cols[0])
  }
})

// ---- 025: the cache line's own switch --------------------------------------------------------

test('025: cache off removes only the cache line; the plan line stays; on brings it back', async ($, on) => {
  const w = world({ plan: true })
  const { fx } = engine(on, w)
  await start($)
  await reply($)
  let { texts } = await cacheLine($)
  expect(texts.some(t => t.includes('cache warm')), 'default on').toBe(true)
  expect(texts.some(t => t.includes('PLAN'))).toBe(true)

  expect((await run($, 'cache off')).text).toBe('Cache line off.')
  expect(fx.json()).toEqual({ 'usage-gauge:cache': false })
  ;({ texts } = await cacheLine($))
  expect(texts.some(t => t.includes('cache '))).toBe(false)
  expect(texts.some(t => t.includes('PLAN')), 'plan line stays').toBe(true)
  expect((await run($, 'cache')).text).toContain('Cache line is off')

  expect((await run($, 'cache on')).text).toBe('Cache line on.')
  expect(fx.json()).toEqual({})
  ;({ texts } = await cacheLine($))
  expect(texts.some(t => t.includes('cache warm'))).toBe(true)
})

test('025: hide still hides both lines; the cache switch is independent of the guard', async ($, on) => {
  const w = world({ plan: true })
  const { fx, clock } = engine(on, w)
  await start($)
  await reply($)
  await run($, 'hide')
  const { texts } = await cacheLine($)
  expect(texts.some(t => t.includes('PLAN') || t.includes('cache '))).toBe(false)

  await run($, 'show')
  await run($, 'cache off')
  await run($, 'cold-guard on')
  await clock.advance(6 * MIN)
  expect(fx.json()).toEqual({ 'usage-gauge:cache': false, 'usage-gauge:cold-guard': true })
  expect((await submit($, 'x')).drop, 'guard works with the line off').toContain('Held once')
})

test('025: another chat flipping the cache switch is picked up; an unreadable file leaves it on', async ($, on) => {
  const w = world({ plan: true })
  const { fx, clock } = engine(on, w)
  await start($)
  await reply($)
  fx.put({ 'usage-gauge:cache': false })
  await clock.advance(3100)
  expect((await cacheLine($)).texts.some(t => t.includes('cache '))).toBe(false)
  fx.put('{ nope')
  await clock.advance(3100)
  expect((await cacheLine($)).texts.some(t => t.includes('cache '))).toBe(true)
})
