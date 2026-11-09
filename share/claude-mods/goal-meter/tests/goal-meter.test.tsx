import { expect, mock, test } from 'claude-code/testing'
import type { Engine, TestBody } from 'claude-code/testing'

import { switchFiles } from './switch-fixture'
import type { SwitchFiles } from './switch-fixture'

type On = Parameters<TestBody>[1]

const SURFACES = ['terminal', 'desktop'] as const
const MIN = 60_000

const band = (bodyColumns = 200) =>
  ({
    plugin: 'goal-meter',
    component: 'AbovePrompt',
    props: {
      hasSurvey: false,
      isWorking: true,
      maxRows: 10,
      bodyColumns,
      scroll: { offset: 0, bodyRows: 10 },
      view: {},
    },
  }) as const

const PANE = {
  plugin: 'goal-meter',
  component: 'Pane',
  requestId: 'goal-meter',
  props: {
    title: 'Goals',
    isFocused: false,
    bodyColumns: 100,
    placement: 'dock',
    scroll: { offset: 0, bodyRows: 40 },
    view: {},
  },
} as const

// Nothing sits beneath the plugin: these hooks stand for the engine.
function engine(on: On, stored: Record<string, unknown> = {}, fx: SwitchFiles = switchFiles()) {
  const clock = mock.clock(on, { now: 1_000_000 })
  mock.store(on, stored)
  mock.env(on, { HOME: fx.home })
  const toasts: string[] = []

  on('command.register', () => ({ value: { command: 'goals' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.toast', (_, e) => {
    toasts.push(e.text)

    return { value: undefined }
  })
  on('fs.exists', (_, e) => ({ value: fx.exists(e.path) }))
  on('fs.read', (_, e) => ({ value: fx.read(e.path) }))
  on('fs.write', (_, e) => {
    fx.write(e.path, e.text)

    return { value: undefined }
  })
  on('process.run', (_, e) => ({
    value: fx.run(e.argv) ?? { exitCode: 127, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false },
  }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('turn.start', (_, e) => ({ turnId: e.turnId }))
  on('tool.call', (_, e) => {
    // Task ids are the subjects, so a test names the task it moves.
    if (e.tool === 'TaskCreate') return { result: { task: { id: e.subject, subject: e.subject } } }

    return { result: {} } as never
  })
  // Another mod's band line, beneath this one.
  on('ui.render', { component: 'AbovePrompt' }, ($, e) => {
    const { Text } = $.ui.resolve(e)

    return <Text>other mod line</Text>
  })

  return { clock, toasts }
}

function command($: Engine, args = '') {
  return $.command.run({
    command: 'goals',
    args,
    origin: { kind: 'composer' },
    presentation: { isFullscreen: true, columns: 200 },
  })
}

async function begin($: Engine, surface: (typeof SURFACES)[number], text = 'Ship the release notes\nwith care') {
  await $.session.start({ cwd: '/', surface, isInteractive: true })
  await command($, 'clear')
  await $.turn.start({ text, turnId: 't1' })
}

const create = ($: Engine, subject: string) =>
  $.tool.call({ tool: 'TaskCreate', subject, description: subject, activeForm: `Doing ${subject}` })
const status = ($: Engine, taskId: string, s: 'in_progress' | 'completed') =>
  $.tool.call({ tool: 'TaskUpdate', taskId, status: s })

async function bandText($: Engine, surface: (typeof SURFACES)[number], columns = 200) {
  const ui = await $.ui.mount({ ...band(columns), surface })
  const texts = (await ui.findAll({ type: 'Text' })).map(t => t.text)
  await ui.unmount()

  return { line: texts.find(t => t.includes('GOAL')), texts }
}

test('4 tasks, 2 finished: the band reads 2/4 · 50% above another mod, on terminal and desktop', async ($, on) => {
  const { clock } = engine(on)

  for (const surface of SURFACES) {
    await begin($, surface)
    for (const s of ['draft', 'review', 'publish', 'announce']) await create($, s)
    await status($, 'draft', 'in_progress')
    await clock.advance(2 * MIN)
    await status($, 'draft', 'completed')
    await status($, 'review', 'in_progress')
    await clock.advance(2 * MIN)
    await status($, 'review', 'completed')
    await status($, 'publish', 'in_progress')

    const { line, texts } = await bandText($, surface)
    expect(line).toContain('2/4 · 50%')
    expect(line).toContain(' ◆ GOAL  Ship the release notes ▰▰▰▱▱▱ 2/4 · 50% · 4m · ETA ~4m │ ▶ Doing publish')
    expect(texts.indexOf('other mod line')).toBeGreaterThan(texts.findIndex(t => t.includes('GOAL')))
  }
})

test('the chip is gold, the bar green, then amber once the running task takes twice the average', async ($, on) => {
  const { clock } = engine(on)
  await begin($, 'terminal')
  await create($, 'a')
  await create($, 'b')
  await status($, 'a', 'in_progress')
  await clock.advance(MIN)
  await status($, 'a', 'completed')
  await status($, 'b', 'in_progress')

  const ui = await $.ui.mount({ ...band(), surface: 'terminal' })
  expect((await ui.find({ type: 'Text', text: /^ ◆ GOAL $/ }))?.props).toMatchObject({
    color: '#0b0b0f',
    backgroundColor: '#facc15',
    weight: 'bold',
  })
  expect((await ui.find({ type: 'Text', text: /^▰▰▰▱▱▱$/ }))?.props.color).toBe('success')
  await ui.unmount()

  await clock.advance(2 * MIN + 1000)
  const slow = await $.ui.mount({ ...band(), surface: 'terminal' })
  expect((await slow.find({ type: 'Text', text: /^▰▰▰▱▱▱$/ }))?.props.color).toBe('warning')
  // XACA-1605-023: slow is also said in words, not only in amber.
  expect(await slow.find({ type: 'Text', text: /· slow$/ }), 'the band says slow').toBeDefined()
  await slow.unmount()
})

test('ETA waits for the first finished task', async ($, on) => {
  engine(on)
  await begin($, 'desktop')
  await create($, 'a')
  await status($, 'a', 'in_progress')

  const { line } = await bandText($, 'desktop')
  expect(line).toContain('0/1 · 0%')
  expect(line).not.toContain('ETA')
})

test('done shows in green for two minutes, toasts once, then hides', async ($, on) => {
  const { clock, toasts } = engine(on)
  await begin($, 'terminal')
  for (const s of ['a', 'b', 'c', 'd']) await create($, s)
  for (const id of ['a', 'b', 'c', 'd']) {
    await status($, id, 'in_progress')
    await clock.advance(3 * MIN)
    await status($, id, 'completed')
  }
  // A repeat update of a finished task toasts nothing more.
  await status($, 'd', 'completed')

  const ui = await $.ui.mount({ ...band(), surface: 'terminal' })
  expect((await ui.find({ type: 'Text', text: /^ done ✓ in 12m$/ }))?.props.color).toBe('success')
  await ui.unmount()
  expect(toasts).toEqual(['Goal done in 12m — 4 tasks'])

  await clock.advance(2 * MIN + 1000)
  const { line, texts } = await bandText($, 'terminal')
  expect(line).toBeUndefined()
  expect(texts).toContain('other mod line')
})

test('TodoWrite lists drive the goal too; a subagent list is ignored', async ($, on) => {
  const { clock } = engine(on)
  await begin($, 'terminal', 'Fix the flaky test')
  const todos = (statuses: string[]) =>
    ['find it', 'fix it', 'prove it'].map((content, i) => ({
      content,
      activeForm: `${content}ing`,
      status: statuses[i] as 'pending' | 'in_progress' | 'completed',
    }))

  await $.tool.call({ tool: 'TodoWrite', todos: todos(['in_progress', 'pending', 'pending']) })
  await clock.advance(MIN)
  await $.tool.call({ tool: 'TodoWrite', todos: todos(['completed', 'in_progress', 'pending']) })
  await $.tool.call({
    tool: 'TodoWrite',
    agentId: 'a1',
    todos: [{ content: 'sub task', activeForm: 'subbing', status: 'completed' }],
  })

  const { line } = await bandText($, 'terminal')
  expect(line).toContain('Fix the flaky test')
  expect(line).toContain('1/3 · 33%')
  expect(line).toContain('▶ fix iting')
})

test('the pane lists every task with its time, and the last 5 goals', async ($, on) => {
  const { clock } = engine(on)

  for (const surface of SURFACES) {
    await begin($, surface, 'First goal')
    await create($, 'only')
    await status($, 'only', 'in_progress')
    await clock.advance(MIN)
    await status($, 'only', 'completed')
    await $.turn.start({ text: 'Second goal', turnId: 't2' })
    await create($, 'one')
    await create($, 'two')
    await status($, 'one', 'in_progress')

    expect((await command($)).text).toBe('Goals pane opened.')
    const ui = await $.ui.mount({ ...PANE, surface })
    expect(await ui.find({ type: 'Text', text: /^▶ one {2}0s$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^○ two$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^✓ First goal {2}1\/1 · 1m$/ })).toBeDefined()
    await ui.unmount()
  }
})

test('off hides the band, stops tracking and is remembered in the shared switch file', async ($, on) => {
  const fx = switchFiles()
  engine(on, {}, fx)
  await begin($, 'terminal')
  await create($, 'a')
  expect((await bandText($, 'terminal')).line).toContain('GOAL')

  expect((await command($, 'off')).text).toBe('Goal band off.')
  expect(fx.json()).toEqual({ 'goal-meter': false })
  expect((await bandText($, 'terminal')).line).toBeUndefined()
  expect((await bandText($, 'terminal')).texts, 'other bands still draw').toContain('other mod line')
  await create($, 'b')
  expect((await command($)).text, 'the pane does not open while off').toContain('is off')

  // The next session reads the shared file.
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  expect((await bandText($, 'terminal')).line).toBeUndefined()
  expect((await command($, 'help')).text).toContain('/goals clear')

  expect((await command($, 'on')).text).toBe('Goal band on.')
  expect(fx.json()).toEqual({})
  const line = (await bandText($, 'terminal')).line
  expect(line, 'tracking stopped while off: b was never counted').toContain('0/1')
})

test('hidden hides the band but keeps tracking; show brings it back', async ($, on) => {
  const fx = switchFiles('/home/me', { 'goal-meter:hidden': true })
  engine(on, {}, fx)
  await begin($, 'terminal')
  await create($, 'a')
  expect((await bandText($, 'terminal')).line, 'hidden by the file').toBeUndefined()
  await create($, 'b')
  await command($, 'show')
  expect(fx.json()).toEqual({})
  expect((await bandText($, 'terminal')).line, 'tracked while hidden').toContain('0/2')
  await command($, 'hide')
  expect(fx.json()).toEqual({ 'goal-meter:hidden': true })
  expect((await bandText($, 'terminal')).line).toBeUndefined()
})

test('a missing or malformed switch file shows the band; another chat flipping it is picked up', async ($, on) => {
  const fx = switchFiles()
  const { clock } = engine(on, {}, fx)
  await begin($, 'terminal')
  await create($, 'a')
  expect((await bandText($, 'terminal')).line, 'missing file: shown').toContain('GOAL')
  for (const bad of ['{ nope', '[]', '{"goal-meter":"false","goal-meter:hidden":"true"}']) {
    fx.put({ 'goal-meter:hidden': true })
    await clock.advance(3100)
    expect((await bandText($, 'terminal')).line).toBeUndefined()
    fx.put(bad)
    await clock.advance(3100)
    expect((await bandText($, 'terminal')).line, `malformed (${bad}): shown`).toContain('GOAL')
  }
  fx.put('{ nope')
  expect((await command($, 'off')).text).toContain('could not save')
  expect(fx.files[fx.path]).toBe('{ nope')
})

test('toggling keeps every other key in the switch file', async ($, on) => {
  const fx = switchFiles('/home/me', { 'cache-clock:hidden': true, extra: { a: [1] } })
  engine(on, {}, fx)
  await begin($, 'terminal')
  await command($, 'off')
  await command($, 'hide')
  expect(fx.json()).toEqual({ 'cache-clock:hidden': true, extra: { a: [1] }, 'goal-meter': false, 'goal-meter:hidden': true })
  await command($, 'on')
  expect(fx.json()).toEqual({ 'cache-clock:hidden': true, extra: { a: [1] } })
  expect(fx.clean()).toBe(true)
})
