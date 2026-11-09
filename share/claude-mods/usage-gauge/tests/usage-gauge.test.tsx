import { expect, mock, test } from 'claude-code/testing'
import type { Engine, TestBody } from 'claude-code/testing'

import { switchFiles } from './switch-fixture'
import type { SwitchFiles } from './switch-fixture'

type On = Parameters<TestBody>[1]

const SURFACES = ['terminal', 'desktop'] as const
// Saturday 00:00 at UTC-5.
const NOW = Date.parse('2026-10-24T05:00:00Z')
const MIN = 60_000
const FIVE_RESET = new Date(NOW + 131 * MIN).toISOString() // 2h11m
const WEEK_RESET = '2026-10-29T14:00:00Z' // Thu 9am at UTC-5

const BAND = {
  plugin: 'usage-gauge',
  component: 'AbovePrompt',
  props: {
    hasSurvey: false,
    isWorking: false,
    maxRows: 10,
    bodyColumns: 160,
    scroll: { offset: 0, bodyRows: 10 },
    view: {},
  },
} as const

const PANE = {
  plugin: 'usage-gauge',
  component: 'Pane',
  requestId: 'usage-gauge',
  props: {
    title: 'Usage',
    isFocused: false,
    bodyColumns: 60,
    placement: 'dock',
    scroll: { offset: 0, bodyRows: 40 },
    view: {},
  },
} as const

type Limit = { kind: string; percentUsed: number; resetsAt?: string }
type Usage = { context: { window: number; percent?: number; tokens?: number }; rateLimits: Limit[]; cost?: { usd: number } }

const plan = (five: number, week: number, usd = 3.81): Usage => ({
  context: { window: 1_000_000, percent: 42, tokens: 420_000 },
  rateLimits: [
    { kind: 'five_hour', percentUsed: five, resetsAt: FIVE_RESET },
    { kind: 'seven_day', percentUsed: week, resetsAt: WEEK_RESET },
  ],
  cost: { usd },
})

// Nothing sits beneath the plugin: these hooks stand for the engine.
function engine(on: On, usage: { now: Usage }, fx: SwitchFiles = switchFiles()) {
  const clock = mock.clock(on, { now: NOW })
  mock.store(on)
  mock.env(on, { HOME: fx.home })
  const toasts: string[] = []
  const status: (string | undefined)[] = []

  on('command.register', () => ({ value: { command: 'usage-gauge' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.toast', (_, e) => {
    toasts.push(e.text)

    return { value: undefined }
  })
  on('ui.status', (_, e) => {
    status.push(e.text)

    return { value: undefined }
  })
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('session.usage', () => ({ value: { startedAt: NOW, ...usage.now } }))
  on('session.measure', (_, e) => ({ changed: e.changed }))
  on('turn.start', (_, e) => ({ turnId: e.turnId }))
  on('turn.complete', (_, e) => ({ text: e.answer }))
  on('fs.exists', (_, e) => ({ value: fx.exists(e.path) }))
  on('fs.read', (_, e) => ({ value: fx.read(e.path) }))
  on('fs.write', (_, e) => {
    fx.write(e.path, e.text)

    return { value: undefined }
  })
  on('process.run', (_, e) => {
    const moved = fx.run(e.argv)
    if (moved) return { value: moved }

    return {
      value: {
        exitCode: e.argv[0] === 'date' ? 0 : 127,
        stdout: e.argv[0] === 'date' ? '-0500\n' : '',
        stderr: '',
        isStdoutTruncated: false,
        isStderrTruncated: false,
      },
    }
  })
  // Another mod's band line, beneath this one.
  on('ui.render', { component: 'AbovePrompt' }, ($, e) => {
    const { Text } = $.ui.resolve(e)

    return <Text>other mod line</Text>
  })

  return { clock, toasts, status }
}

async function start($: Engine, surface: (typeof SURFACES)[number] = 'terminal') {
  await $.session.start({ cwd: '/', surface, isInteractive: true })
}

function measure($: Engine, u: Usage) {
  return $.session.measure({ ...u, changed: ['rateLimits'] })
}

async function turn($: Engine, usage: { now: Usage }, usdAfter: number) {
  await $.turn.start({ text: 'do it', turnId: `t${usdAfter}` })
  usage.now = { ...usage.now, cost: { usd: usdAfter } }
  await $.turn.complete({ answer: 'ok', durationMs: 1, isAborted: false, turnId: `t${usdAfter}`, reason: 'answer' })
}

async function band($: Engine, surface: (typeof SURFACES)[number] = 'terminal') {
  const ui = await $.ui.mount({ ...BAND, surface })
  const texts = (await ui.findAll({ type: 'Text' })).map(t => t.text)
  const percent = async (p: string) => (await ui.find({ type: 'Text', text: new RegExp(`^${p}$`) }))?.props.color
  const chip = await ui.find({ type: 'Text', text: /^ ◔ PLAN $/ })
  const colors = { p34: await percent('34%'), p83: await percent('83%'), p91: await percent('91%') }
  await ui.unmount()

  return { line: texts.find(t => t.includes('PLAN')), texts, chip, colors }
}

function command($: Engine, args = '') {
  return $.command.run({
    command: 'usage-gauge',
    args,
    origin: { kind: 'composer' },
    presentation: { isFullscreen: true, columns: 200 },
  })
}

test('the band reads like the slide, above another mod, on terminal and desktop', async ($, on) => {
  const usage = { now: plan(34, 83) }
  const { status } = engine(on, usage)

  for (const surface of SURFACES) {
    usage.now = plan(34, 83)
    await start($, surface)
    await turn($, usage, 4.12)
    const { line, texts, chip, colors } = await band($, surface)

    expect(line).toBe(' ◔ PLAN  5h ▰▰▱▱▱▱ 34% ↻2h11m │ week ▰▰▰▰▰▱ 83% ↻Thu 9am │ session $4.12 (+$0.31)')
    expect(chip?.props).toMatchObject({ color: '#0b0b0f', backgroundColor: '#60a5fa', weight: 'bold' })
    expect(colors.p34).toBe('success')
    expect(colors.p83).toBe('warning')
    expect(texts.indexOf('other mod line')).toBeGreaterThan(texts.findIndex(t => t.includes('PLAN')))
  }
  expect(status.at(-1)).toBe('5h 34% · wk 83%')
})

test('over 85% reads red; another window kind shows by its own name', async ($, on) => {
  const usage = { now: plan(91, 20) }
  usage.now.rateLimits.push({ kind: 'spend_limit', percentUsed: 12 })
  engine(on, usage)
  await start($)
  const { line, colors } = await band($)

  expect(colors.p91).toBe('error')
  expect(line).toContain('│ spend_limit ▰▱▱▱▱▱ 12%')
})

test('API billing: context fill and cost only, never a made-up 0%', async ($, on) => {
  const usage = { now: { context: { window: 200_000, percent: 42 }, rateLimits: [], cost: { usd: 1 } } }
  engine(on, usage)
  await start($)
  const { line } = await band($)

  expect(line).toBe(' ◔ PLAN  context 42% │ session $1.00')
  expect(line).not.toContain('0%')
})

test('each threshold toasts once per crossing', async ($, on) => {
  const usage = { now: plan(10, 70) }
  const { toasts } = engine(on, usage)
  await start($)
  await measure($, plan(10, 80))
  await measure($, plan(10, 82))
  await measure($, plan(10, 91))
  await measure($, plan(10, 92))

  expect(toasts).toEqual(['Weekly limit at 75% — resets Thu 9am', 'Weekly limit at 90% — resets Thu 9am'])
})

test('the pace warning waits for two readings five minutes apart', async ($, on) => {
  const usage = { now: plan(50, 10) }
  const { clock } = engine(on, usage)
  await start($)
  await clock.advance(2 * MIN)
  await measure($, plan(55, 10))
  expect((await band($)).line).not.toContain('pace')

  await clock.advance(4 * MIN)
  await measure($, plan(62, 10))
  // 12 points in 6 minutes: 38 left at 2 a minute.
  expect((await band($)).line).toContain('⚠ at this pace: out in ~19m')
})

test('warn and off are remembered; status reads the windows', async ($, on) => {
  const usage = { now: plan(10, 50) }
  const fx = switchFiles()
  const { toasts, status } = engine(on, usage, fx)
  await start($)

  expect((await command($, 'warn 50 60')).text).toBe('Usage gauge warns at 50% and 60%.')
  await measure($, plan(10, 61))
  expect(toasts).toEqual(['Weekly limit at 60% — resets Thu 9am'])
  expect((await command($, 'warn nope')).text).toContain('between 1 and 100')
  expect((await command($, 'status')).text).toContain('Weekly limit: 61%, resets Thu 9am')

  expect((await command($, 'off')).text).toBe('Usage gauge off.')
  expect(fx.json()).toEqual({ 'usage-gauge': false })
  expect(status.at(-1)).toBeUndefined()
  await start($)
  expect((await band($)).line).toBeUndefined()
})

test('off hides the band and status and stops measuring; hidden hides them but keeps measuring', async ($, on) => {
  const usage = { now: plan(34, 83) }
  const fx = switchFiles()
  const { clock, status } = engine(on, usage, fx)
  await start($)
  await clock.settle()
  expect((await band($)).line).toContain('34%')
  expect(status.at(-1)).toContain('5h 34%')

  await command($, 'hide')
  expect(fx.json()).toEqual({ 'usage-gauge:hidden': true })
  expect((await band($)).line).toBeUndefined()
  expect(status.at(-1), 'status text clears while hidden').toBeUndefined()
  usage.now = plan(40, 83)
  await measure($, plan(40, 83))
  expect((await command($, 'status')).text, 'still measuring while hidden').toContain('40%')
  await command($, 'show')
  expect((await band($)).line).toContain('40%')
  expect(status.at(-1)).toContain('5h 40%')

  await command($, 'off')
  expect((await band($)).line).toBeUndefined()
  expect(status.at(-1)).toBeUndefined()
  await measure($, plan(55, 83))
  expect((await command($, '')).text, 'the pane does not open while off').toContain('is off')
  await command($, 'on')
  expect(fx.json()).toEqual({})
  const after = (await command($, 'status')).text
  expect(after, 'nothing was measured while off; turning it on re-reads the session').not.toContain('55%')
  expect(after).toContain('40%')
})

test('a missing or malformed switch file shows the gauge; another chat flipping it is picked up', async ($, on) => {
  const usage = { now: plan(34, 83) }
  const fx = switchFiles()
  const { clock } = engine(on, usage, fx)
  await start($)
  await clock.settle()
  expect((await band($)).line, 'missing file: shown').toContain('34%')
  for (const bad of ['{ nope', '[]', '{"usage-gauge":"false","usage-gauge:hidden":"true"}']) {
    fx.put({ 'usage-gauge:hidden': true })
    await clock.advance(3100)
    expect((await band($)).line).toBeUndefined()
    fx.put(bad)
    await clock.advance(3100)
    expect((await band($)).line, `malformed (${bad}): shown`).toContain('34%')
  }
  fx.put('{ nope')
  expect((await command($, 'off')).text).toContain('could not save')
  expect(fx.files[fx.path]).toBe('{ nope')
})

test('toggling keeps every other key in the switch file', async ($, on) => {
  const usage = { now: plan(34, 83) }
  const fx = switchFiles('/home/me', { 'cache-clock:hidden': true, extra: { a: [1] } })
  engine(on, usage, fx)
  await start($)
  await command($, 'off')
  await command($, 'hide')
  expect(fx.json()).toEqual({ 'cache-clock:hidden': true, extra: { a: [1] }, 'usage-gauge': false, 'usage-gauge:hidden': true })
  await command($, 'on')
  expect(fx.json()).toEqual({ 'cache-clock:hidden': true, extra: { a: [1] } })
  expect(fx.clean()).toBe(true)
})

test('the pane has a bar per window, pace and the last turns', async ($, on) => {
  const usage = { now: plan(34, 83) }
  engine(on, usage)

  for (const surface of SURFACES) {
    usage.now = plan(34, 83)
    await start($, surface)
    await turn($, usage, 4.12)
    expect((await command($)).text).toBe('Usage pane opened.')

    const ui = await $.ui.mount({ ...PANE, surface })
    expect(await ui.find({ type: 'Text', text: '5-hour limit' })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: 'resets Thu 9am' })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /needs two readings/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /\$0\.31/ })).toBeDefined()
    await ui.unmount()
  }
})

// Consumer layout: an API-billing key reports no plan windows, and a plan can
// disappear mid-session (key swapped in). The gauge must not keep drawing a
// plan percentage the account no longer has.
test('consumer: plan windows that stop being reported leave no stale bar behind', async ($, on) => {
  const usage = { now: plan(34, 83) }
  engine(on, usage)
  await start($)
  expect((await band($)).line).toContain('34%')

  await measure($, { context: { window: 200_000, percent: 42 }, rateLimits: [], cost: { usd: 1 } })
  const { line } = await band($)
  expect(line).not.toContain('34%')
  expect(line).not.toContain('83%')
  expect(line).not.toContain('▰')
  expect((await command($, 'status')).text).toContain('No plan windows reported (API billing, or no response yet).')
})

test('consumer: no usage at all (nothing reported yet) draws nothing and leaves the other line', async ($, on) => {
  const usage = { now: { context: { window: 200_000 }, rateLimits: [] } as Usage }
  engine(on, usage)
  await start($)
  const { line, texts } = await band($)

  expect(line).toBeUndefined()
  expect(texts).toContain('other mod line')
})
