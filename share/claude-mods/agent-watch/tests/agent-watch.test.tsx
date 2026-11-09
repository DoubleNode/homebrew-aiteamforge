import { expect, mock, test } from 'claude-code/testing'
import type { Engine, TestBody } from 'claude-code/testing'

import { switchFiles } from './switch-fixture'
import type { SwitchFiles } from './switch-fixture'

type On = Parameters<TestBody>[1]

const SURFACES = ['terminal', 'desktop'] as const

const band = (bodyColumns: number) =>
  ({
    plugin: 'agent-watch',
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
  plugin: 'agent-watch',
  component: 'Pane',
  requestId: 'agent-watch',
  props: {
    title: 'Agents',
    isFocused: false,
    bodyColumns: 100,
    placement: 'dock',
    scroll: { offset: 0, bodyRows: 40 },
    view: {},
  },
} as const

const USAGE = { input_tokens: 1200, output_tokens: 300, cache_read_input_tokens: 5000, cache_creation_input_tokens: 0 }

// Nothing sits beneath the plugin: these hooks stand for the engine.
function engine(on: On, stored: Record<string, unknown> = {}, stepTools: Record<string, string[]> = {}, fx: SwitchFiles = switchFiles()) {
  let now = 1_000_000
  // The mock clock answers clock.every (the switch poll); this test's own clock.now below ticks forward by itself.
  const clock = mock.clock(on, { now })
  mock.env(on, { HOME: fx.home })
  const ids: Record<string, string> = { Explore: 'a1', 'general-purpose': 'a2', Plan: 'a3' }
  const models: Record<string, string> = {
    Explore: 'claude-haiku-4-5',
    'general-purpose': 'claude-sonnet-5-5',
    Plan: 'claude-opus-5-5',
  }

  on('fs.exists', (_, e) => ({ value: fx.exists(e.path) }))
  on('fs.read', (_, e) => ({ value: fx.read(e.path) }))
  on('fs.write', (_, e) => {
    fx.write(e.path, e.text)

    return { value: undefined }
  })
  on('process.run', (_, e) => ({
    value: fx.run(e.argv) ?? { exitCode: 127, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false },
  }))
  on('command.register', () => ({ value: { command: 'agent-watch' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('agent.list', () => ({ value: [] }))
  on('session.messages', () => ({ value: [] }))
  on('store.get', (_, e) => ({ value: stored[e.key] }))
  on('store.set', (_, e) => {
    stored[e.key] = e.value

    return { value: undefined }
  })
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('turn.start', (_, e) => ({ turnId: e.turnId }))
  on('turn.step', async function* (_, e) {
    return {
      turnId: e.turnId,
      index: e.index,
      answer: '',
      toolUses: (stepTools[e.turnId] ?? []).map((name, i) => ({ id: `tu${i}`, name, input: {} })),
      stopReason: 'end_turn' as const,
      usage: { ...USAGE, model: e.model },
    }
  })
  on('turn.complete', (_, e) => ({ text: e.answer }))
  on('agent.spawn', (_, e) => ({
    model: models[e.subagentType] ?? 'claude-sonnet-5-5',
    agentId: ids[e.subagentType] ?? 'ax',
  }))
  on('tool.call', () => ({ result: {} }))
  on('skill.prompt', (_, e) => ({ text: e.text }))
  // Another mod's band line, beneath this one.
  on('ui.render', { component: 'AbovePrompt' }, ($, e) => {
    const { Text } = $.ui.resolve(e)

    return <Text>other mod line</Text>
  })

  return Object.assign(stored, { clock, fx })
}

// A slash command as the person types it at the prompt.
function command($: Engine, args = '') {
  return $.command.run({
    command: 'agent-watch',
    args,
    origin: { kind: 'composer' },
    presentation: { isFullscreen: true, columns: 200 },
  })
}

// An Agent call from the main loop, as the engine raises it.
function spawn($: Engine, fields: { prompt: string; description: string; subagentType: string; name?: string }) {
  return $.agent.spawn({
    tool_use_id: `tu-${fields.subagentType}`,
    provider: { plugin: 'engine', tier: 'core' },
    parentModel: 'claude-opus-5-5',
    background: false,
    fork: false,
    ...fields,
  })
}

async function drain(stream: AsyncGenerator<unknown, unknown>) {
  for await (const _ of stream) {
    // read to the end
  }
}

async function playTurn($: Engine, surface: (typeof SURFACES)[number], withPlan = false) {
  await $.session.start({ cwd: '/', surface, isInteractive: true })
  await command($, 'clear')
  await $.turn.start({ text: 'find the hooks and check prices', turnId: 't1' })
  await drain($.turn.step({ turnId: 't1', index: 0, model: 'claude-opus-5-5', messageCount: 1 }))
  await spawn($, { prompt: 'Find every hook file', description: 'find the hooks', subagentType: 'Explore' })
  await spawn($, {
    prompt: 'Check the prices',
    description: 'check the prices',
    subagentType: 'general-purpose',
    name: 'fact-checker',
  })
  if (withPlan) {
    await spawn($, { prompt: 'Plan it', description: 'plan the rollout', subagentType: 'Plan' })
  }
  // One skill run inside Explore: the Skill tool call and the prompt it
  // expands. Unpaired, the prompt would also be credited to main.
  await $.tool.call({ tool: 'Skill', skill: 'watch', agentId: 'a1' })
  await $.skill.prompt({ skill: 'watch', text: 'Watch the agents.' })
  await $.tool.call({ tool: 'Bash', command: 'ls', agentId: 'a1' })
  await $.turn.complete({
    answer: 'found them',
    durationMs: 10,
    isAborted: false,
    turnId: 's1',
    agentId: 'a1',
    reason: 'answer',
    usage: { ...USAGE, model: 'claude-haiku-4-5' },
  })
}

test('the band names every agent of the turn, on terminal and desktop', async ($, on) => {
  engine(on)

  for (const surface of SURFACES) {
    await playTurn($, surface)
    const ui = await $.ui.mount({ ...band(200), surface })
    const line = await ui.find({ type: 'Text', text: /AGENTS/ })

    expect(line?.text).toBe(
      ' ◎ AGENTS  main opus·5.5 ⟳ │ Explore haiku "find the hooks" ✓ · fact-checker sonnet "check the prices" ⟳ │ skills: watch',
    )
    const chip = await ui.find({ type: 'Text', text: /^ ◎ AGENTS $/ })
    expect(chip?.props).toMatchObject({ color: '#0b0b0f', backgroundColor: '#f472b6', weight: 'bold' })
    const haiku = await ui.find({ type: 'Text', text: /^ haiku$/ })
    expect(haiku?.props.color).toBe('autoAccept')
    // XACA-1605-033: a raw hex foreground is only allowed on a chip (paired with a background).
    for (const t of await ui.findAll({ type: 'Text' })) {
      const c = t.props.color
      if (typeof c === 'string' && c.startsWith('#')) expect(t.props.backgroundColor).toBeTruthy()
    }

    // Stacked on top of the other mod's line, which stays.
    const texts = (await ui.findAll({ type: 'Text' })).map(t => t.text)
    expect(texts.indexOf('other mod line')).toBeGreaterThan(texts.findIndex(t => /AGENTS/.test(t)))
    await ui.unmount()
  }
})

test('a narrow band drops task text first, oldest agents first, keeping the first', async ($, on) => {
  engine(on)
  await playTurn($, 'terminal', true)

  const wide = await $.ui.mount({ ...band(500), surface: 'terminal' })
  const full = (await wide.find({ type: 'Text', text: /AGENTS/ }))?.text ?? ''
  await wide.unmount()
  expect(full).toContain('"check the prices"')

  // Ten columns short: the second agent's task is enough to give up.
  const ui = await $.ui.mount({ ...band([...full].length - 10), surface: 'terminal' })
  const text = (await ui.find({ type: 'Text', text: /AGENTS/ }))?.text ?? ''

  expect(text).toContain('Explore haiku "find the hooks"')
  expect(text).not.toContain('check the prices')
  expect(text).toContain('fact-checker sonnet ⟳')
  expect(text).toContain('Plan opus "plan the rollout"')
  expect(text).toContain('skills: watch')
  await ui.unmount()

  // Far too narrow: agents fold into "+N more"; the first task and a skill stay.
  const tight = await $.ui.mount({ ...band(70), surface: 'terminal' })
  const tightText = (await tight.find({ type: 'Text', text: /AGENTS/ }))?.text ?? ''
  expect(tightText).toContain('"find the hooks"')
  expect(tightText).toContain('more')
  await tight.unmount()
})

test('a skill is counted once, in the band and the pane', async ($, on) => {
  engine(on)
  await playTurn($, 'desktop')

  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  const skills = await ui.findAll({ type: 'Text', text: /^watch$/ })
  expect(skills).toHaveLength(1)
  await ui.unmount()
})

test('the pane nests agents with models, calls, tokens; timeline on the terminal only', async ($, on) => {
  engine(on)

  for (const surface of SURFACES) {
    await playTurn($, surface)
    const opened = await command($)
    expect(opened.text).toBe('Agents pane opened.')

    const ui = await $.ui.mount({ ...PANE, surface })
    expect(await ui.find({ type: 'Text', text: /main — find the hooks/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^ {2}✓ Explore — find the hooks$/ })).toBeDefined()
    expect((await ui.find({ type: 'Text', text: /haiku·4\.5 · 2 calls · 6\.2k in \/ 300 out/ }))?.text).toContain(
      '    haiku',
    )
    expect(await ui.find({ type: 'Text', text: 'Per model' })).toBeDefined()
    const timeline = await ui.find({ type: 'Text', text: 'Timeline' })
    if (surface === 'terminal') {
      expect(timeline).toBeDefined()
      expect(await ui.find({ type: 'Text', text: /Explore done/ })).toBeDefined()
    } else {
      expect(timeline).toBeUndefined()
    }
    await ui.unmount()
  }
})

test('off hides the band, stops tracking and is remembered in the shared switch file', async ($, on) => {
  const fx = switchFiles()
  engine(on, {}, {}, fx)
  await playTurn($, 'terminal')

  const off = await command($, 'off')
  expect(off.text).toBe('Agent band off.')
  expect(fx.json()).toEqual({ 'agent-watch': false })

  const ui = await $.ui.mount({ ...band(200), surface: 'terminal' })
  expect(await ui.find({ type: 'Text', text: /AGENTS/ })).toBeUndefined()
  expect(await ui.find({ type: 'Text', text: 'other mod line' })).toBeDefined()
  await ui.unmount()
  expect((await command($)).text, 'the pane does not open while off').toContain('is off')

  expect((await command($, 'on')).text).toBe('Agent band on.')
  expect(fx.json()).toEqual({})
})

test('a stored off is read back at session start', async ($, on) => {
  engine(on, {}, {}, switchFiles('/home/me', { 'agent-watch': false }))
  await playTurn($, 'terminal')

  const ui = await $.ui.mount({ ...band(200), surface: 'terminal' })
  expect(await ui.find({ type: 'Text', text: /AGENTS/ })).toBeUndefined()
  await ui.unmount()

  const help = await command($, 'help')
  expect(help.text).toContain('/agent-watch clear')
})

test('while off nothing is tracked; hidden tracks but draws nothing', async ($, on) => {
  const fx = switchFiles('/home/me', { 'agent-watch': false })
  engine(on, {}, {}, fx)
  await playTurn($, 'terminal')
  await command($, 'on')
  let ui = await $.ui.mount({ ...band(200), surface: 'terminal' })
  expect(await ui.find({ type: 'Text', text: /AGENTS/ }), 'the turn played while off left no band').toBeUndefined()
  await ui.unmount()

  await command($, 'hide')
  expect(fx.json()).toEqual({ 'agent-watch:hidden': true })
  await $.turn.start({ text: 'second ask', turnId: 't9' })
  ui = await $.ui.mount({ ...band(200), surface: 'terminal' })
  expect(await ui.find({ type: 'Text', text: /AGENTS/ }), 'hidden').toBeUndefined()
  await ui.unmount()
  await command($, 'show')
  expect(fx.json()).toEqual({})
  ui = await $.ui.mount({ ...band(200), surface: 'terminal' })
  expect(await ui.find({ type: 'Text', text: /AGENTS/ }), 'tracked while hidden, shown again').toBeDefined()
  await ui.unmount()
})

test('a missing or malformed switch file shows the band; another chat flipping it is picked up', async ($, on) => {
  const fx = switchFiles()
  const { clock } = engine(on, {}, {}, fx)
  await playTurn($, 'terminal')
  const shown = async () => {
    const ui = await $.ui.mount({ ...band(200), surface: 'terminal' })
    const found = (await ui.find({ type: 'Text', text: /AGENTS/ })) !== undefined
    await ui.unmount()

    return found
  }
  expect(await shown(), 'missing file: shown').toBe(true)
  for (const bad of ['{ nope', '[]', '{"agent-watch":"false","agent-watch:hidden":"true"}']) {
    fx.put({ 'agent-watch:hidden': true })
    await clock.advance(3100)
    expect(await shown()).toBe(false)
    fx.put(bad)
    await clock.advance(3100)
    expect(await shown(), `malformed (${bad}): shown`).toBe(true)
  }
  fx.put('{ nope')
  expect((await command($, 'off')).text).toContain('could not save')
  expect(fx.files[fx.path]).toBe('{ nope')
})

test('toggling keeps every other key in the switch file', async ($, on) => {
  const fx = switchFiles('/home/me', { 'cache-clock:hidden': true, extra: { a: [1] } })
  engine(on, {}, {}, fx)
  await playTurn($, 'terminal')
  await command($, 'off')
  await command($, 'hide')
  expect(fx.json()).toEqual({ 'cache-clock:hidden': true, extra: { a: [1] }, 'agent-watch': false, 'agent-watch:hidden': true })
  await command($, 'on')
  expect(fx.json()).toEqual({ 'cache-clock:hidden': true, extra: { a: [1] } })
  expect(fx.clean()).toBe(true)
})

test('a log an earlier version stored is declined', async ($, on) => {
  on('state.get', (_, e) =>
    e.key === 'log'
      ? { value: { value: { agents: [{ id: 'main' }] }, version: 1 } }
      : { value: { value: undefined, version: 0 } },
  )

  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect((await ui.find({ type: 'Text' }))?.text).toBe('No agents yet. They show up here as they work.')
  await ui.unmount()
})

test('a notification turn keeps the task and the band; an Agent call counts', async ($, on) => {
  engine(on, {}, { t1: ['Agent'] })
  await playTurn($, 'terminal')
  await $.turn.start({ text: '<task-notification> agent finished', turnId: 't2' })

  const band200 = await $.ui.mount({ ...band(200), surface: 'terminal' })
  const line = (await band200.find({ type: 'Text', text: /AGENTS/ }))?.text ?? ''
  expect(line).toContain('Explore haiku "find the hooks" ✓')
  await band200.unmount()

  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect(await ui.find({ type: 'Text', text: /main — find the hooks/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /task-notification>/ })).toBeUndefined()
  expect(await ui.find({ type: 'Text', text: /main \(task-notification\)/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /opus·5\.5 · 1 calls/ })).toBeDefined()
  await ui.unmount()
})
