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
      isCollapsed: false,
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
function engine(on: On, stored: Record<string, unknown> = {}, stepTools: Record<string, string[]> = {}, fx: SwitchFiles = switchFiles(), extraEnv: Record<string, string> = {}) {
  let now = 1_000_000
  // The mock clock answers clock.every (the switch poll); this test's own clock.now below ticks forward by itself.
  const clock = mock.clock(on, { now })
  mock.env(on, { HOME: fx.home, ...extraEnv })
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
  const spawned: string[] = []
  on('agent.spawn', (_, e) => {
    spawned.push(e.subagentType)

    return {
      model: models[e.subagentType] ?? 'claude-sonnet-5-5',
      agentId: ids[e.subagentType] ?? 'ax',
    }
  })
  // What the lint shows the person: notices under the Agent call, and dim transcript lines.
  const notices: { id: string; text: string | undefined }[] = []
  const logs: string[] = []
  on('ui.notice', (_, e) => {
    notices.push({ id: e.tool_use_id, text: e.text })

    return { value: undefined }
  })
  on('ui.log', (_, e) => {
    logs.push(e.text)

    return { value: undefined }
  })
  on('tool.call', () => ({ result: {} }))
  on('skill.prompt', (_, e) => ({ text: e.text }))
  // Another mod's band line, beneath this one.
  on('ui.render', { component: 'AbovePrompt' }, ($, e) => {
    const { Text } = $.ui.resolve(e)

    return <Text>other mod line</Text>
  })

  return Object.assign(stored, { clock, fx, spawned, notices, logs })
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
function spawn(
  $: Engine,
  fields: { prompt: string; description: string; subagentType: string; name?: string; model?: string; fork?: boolean },
) {
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

// ---- XACA-1639: dispatch lint, effort visibility, elapsed time, "This chat used" ----

const ask = (subagentType: string, extra: { model?: string; fork?: boolean } = {}) => ({
  prompt: 'do it',
  description: 'do the thing',
  subagentType,
  ...extra,
})

// A subagent's request, as the engine raises it.
function step($: Engine, agentId: string | undefined, index: number, model: string, effort?: 'low' | 'high' | 'max') {
  return drain(
    $.turn.step({ turnId: `s-${agentId ?? 'main'}-${index}`, index, model, messageCount: 1, ...(agentId === undefined ? {} : { agentId }), ...(effort === undefined ? {} : { effort }) }),
  )
}

test('lint warn: a built-in with no model warns once with the rule and source; a model set, a fork or a persona never does', async ($, on) => {
  const fx = engine(on)
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })

  await spawn($, ask('general-purpose'))
  expect(fx.notices).toHaveLength(1)
  expect(fx.notices[0]?.id).toBe('tu-general-purpose')
  expect(fx.notices[0]?.text).toContain('MODEL_SELECTION.md §2')
  expect(fx.notices[0]?.text).toContain('model: sonnet')
  expect(fx.logs, 'the dim log line is written too, so a finding is never lost when no dialog is open').toEqual([fx.notices[0]?.text])
  expect(fx.spawned, 'warn mode lets the spawn run').toEqual(['general-purpose'])

  await spawn($, ask('general-purpose', { model: 'sonnet' }))
  await spawn($, ask('Explore', { model: 'claude-opus-5-5' }))
  await spawn($, ask('general-purpose', { fork: true }))
  await spawn($, ask('worf'))
  expect(fx.notices, 'model set, fork and named persona: no warning').toHaveLength(1)
  expect(fx.logs).toHaveLength(1)

  await spawn($, ask('Plan'))
  expect(fx.notices).toHaveLength(2)
  expect((await command($, 'status')).text).toBe('Dispatch lint warn. Session: 2 missing-model, 0 opus+low, 0 max-effort.')
})

test('lint deny refuses only when switched, with a reason the model can act on, and the setting is remembered', async ($, on) => {
  const fx = switchFiles('/home/me', { 'cache-clock:hidden': true })
  const eng = engine(on, {}, {}, fx)
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })

  expect((await command($)).text, 'sanity: the pane command still works').toContain('Agents pane')
  const before = await spawn($, ask('Explore'))
  expect(before.deny, 'default is warn, not deny').toBeUndefined()

  expect((await command($, 'lint deny')).text).toContain('Dispatch lint deny')
  expect(fx.json()).toEqual({ 'cache-clock:hidden': true, 'agent-watch:lint': 'deny' })
  eng.spawned.length = 0
  const denied = await spawn($, ask('Explore'))
  expect(denied.deny).toContain('model: sonnet')
  expect(denied.deny).toContain('MODEL_SELECTION.md §2')
  expect(eng.spawned, 'a refused spawn never reaches the engine').toEqual([])

  const retry = await spawn($, ask('Explore', { model: 'sonnet' }))
  expect(retry.deny).toBeUndefined()
  expect(eng.spawned).toEqual(['Explore'])
  expect((await spawn($, ask('worf'))).deny, 'a persona is never refused').toBeUndefined()
  expect((await spawn($, ask('general-purpose', { fork: true }))).deny, 'a fork is never refused').toBeUndefined()
  expect((await command($, 'status')).text).toContain('2 missing-model')

  expect((await command($, 'lint')).text).toContain('is deny')
  await command($, 'lint warn')
  expect(fx.json(), 'warn is the default: the key is cleared, others kept').toEqual({ 'cache-clock:hidden': true })
  expect((await spawn($, ask('Explore'))).deny).toBeUndefined()
  expect((await command($, 'lint nonsense')).text).toContain('Unknown lint mode')
  expect(fx.json()).toEqual({ 'cache-clock:hidden': true })
})

test('lint off passes everything and counts nothing; a corrupt switch file cannot be written and reads as warn', async ($, on) => {
  const fx = switchFiles()
  const eng = engine(on, {}, {}, fx)
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  await command($, 'lint off')
  expect(fx.json()).toEqual({ 'agent-watch:lint': 'off' })
  await spawn($, ask('Plan'))
  await step($, 'a3', 0, 'claude-opus-5-5', 'low')
  expect(eng.notices).toHaveLength(0)
  expect(eng.logs).toHaveLength(0)
  expect((await command($, 'status')).text).toBe('Dispatch lint off. Session: 0 missing-model, 0 opus+low, 0 max-effort.')

  fx.put('{ nope')
  expect((await command($, 'lint deny')).text).toContain('could not save')
  expect((await spawn($, ask('Plan'))).deny, 'unreadable file: warn').toBeUndefined()
})

test('effort lint judges only a subagent\'s first step, once per agent, and only warns', async ($, on) => {
  const fx = switchFiles()
  const eng = engine(on, {}, {}, fx)
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  await $.turn.start({ text: 'go', turnId: 't1' })
  await spawn($, ask('Plan', { model: 'opus' })) // a3
  await spawn($, ask('Explore', { model: 'sonnet' })) // a1
  await spawn($, ask('general-purpose', { model: 'sonnet' })) // a2

  await step($, 'a3', 0, 'claude-opus-5-5', 'low')
  expect(eng.logs).toHaveLength(1)
  expect(eng.logs[0]).toContain('MODEL_SELECTION.md §2')
  await step($, 'a3', 1, 'claude-opus-5-5', 'low')
  await step($, 'a3', 0, 'claude-opus-5-5', 'low') // a second turn's first step, same agent: still once
  expect(eng.logs, 'once per agent, not once per step').toHaveLength(1)

  await step($, 'a1', 1, 'claude-sonnet-5-5', 'max') // not a first step
  expect(eng.logs).toHaveLength(1)
  await step($, 'a1', 0, 'claude-sonnet-5-5', 'low') // sonnet + low is the flagship pairing
  expect(eng.logs).toHaveLength(1)
  await step($, 'a2', 0, 'claude-sonnet-5-5', 'max')
  expect(eng.logs).toHaveLength(2)
  expect(eng.logs[1]).toContain('max effort')
  await step($, undefined, 0, 'claude-opus-5-5', 'low') // the main loop is not judged
  expect(eng.logs).toHaveLength(2)
  expect((await command($, 'status')).text).toBe('Dispatch lint warn. Session: 0 missing-model, 1 opus+low, 1 max-effort.')

  // deny mode refuses spawns, never steps: the step still returns its result.
  await command($, 'lint deny')
  await spawn($, ask('worf')) // ax
  const result = await $.turn.step({ turnId: 'sx', index: 0, model: 'claude-opus-5-5', effort: 'low', messageCount: 1, agentId: 'ax' }).next()
  expect(result.done || result.value !== undefined).toBe(true)
  expect(eng.logs).toHaveLength(3)

  // opus + max is the sanctioned rung.
  await spawn($, ask('worf', { model: 'opus' }))
  await step($, 'a9', 0, 'claude-opus-5-5', 'max')
  expect(eng.logs).toHaveLength(3)
})

test('the pane shows effort and elapsed time per agent, and the lint counters', async ($, on) => {
  const eng = engine(on)
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  await command($, 'clear')
  await $.turn.start({ text: 'go', turnId: 't1' })
  await spawn($, ask('Plan', { model: 'opus' }))
  await spawn($, ask('Explore'))
  await step($, 'a3', 0, 'claude-opus-5-5', 'low')
  await step($, 'a1', 0, 'claude-haiku-4-5', 'high')
  await eng.clock.advance(65_000)

  let ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  const plan = await ui.find({ type: 'Text', text: /opus·5\.5 · \d+ calls .*effort low · 1m05s$/ })
  expect(plan, 'running: elapsed since startedAt, effort beside the model').toBeDefined()
  expect(await ui.find({ type: 'Text', text: /haiku·4\.5 .*effort high · 1m05s$/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: 'Dispatch lint' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: 'mode warn · missing-model 1 · opus+low 1 · max-effort 0' })).toBeDefined()
  await ui.unmount()

  await eng.clock.advance(5_000)
  ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect(await ui.find({ type: 'Text', text: /opus·5\.5 .*· 1m10s$/ }), 'a running row ticks').toBeDefined()
  await ui.unmount()

  await $.turn.complete({ answer: 'ok', durationMs: 1, isAborted: false, turnId: 'c1', agentId: 'a3', reason: 'answer', usage: { ...USAGE, model: 'claude-opus-5-5' } })
  await eng.clock.advance(600_000)
  ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect(await ui.find({ type: 'Text', text: /opus·5\.5 .*effort low · 1m10s$/ }), 'finished: endedAt - startedAt, fixed').toBeDefined()
  expect(await ui.find({ type: 'Text', text: /haiku·4\.5 .*· 11m10s$/ }), 'the other is still running').toBeDefined()
  await ui.unmount()
})

test('"This chat used" lists files once, read apart from written, skips /tmp and tool-results, counts MCP per server', async ($, on) => {
  engine(on)
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  await command($, 'clear')
  await $.turn.start({ text: 'go', turnId: 't1' })
  const call = (input: Record<string, unknown>) => $.tool.call({ tool_use_id: 'x', ...input } as never)

  let ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect(await ui.find({ type: 'Text', text: 'This chat used' }), 'nothing used yet: no section').toBeUndefined()
  await ui.unmount()

  await call({ tool: 'Read', file_path: '/repo/a.ts' })
  await call({ tool: 'Read', file_path: '/repo/a.ts', agentId: 'a1' }) // twice, from two agents
  await call({ tool: 'Read', file_path: '/repo/b.ts' })
  await call({ tool: 'Edit', file_path: '/repo/c.ts' })
  await call({ tool: 'Write', file_path: '/repo/c.ts' })
  await call({ tool: 'NotebookEdit', notebook_path: '/repo/n.ipynb' })
  await call({ tool: 'Read', file_path: '/tmp/scratch.txt' })
  await call({ tool: 'Read', file_path: '/private/tmp/scratch2.txt' })
  await call({ tool: 'Read', file_path: '/home/me/.claude/projects/p/s/tool-results/abc.txt' })
  await call({ tool: 'Read' }) // no path
  await call({ tool: 'mcp__atlassian__getIssue' })
  await call({ tool: 'mcp__atlassian__search' })
  await call({ tool: 'mcp__plugin_firebase_firebase__firebase_init' })
  await call({ tool: 'Bash', command: 'ls' })

  ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect(await ui.find({ type: 'Text', text: 'This chat used' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: 'files read (2)' })).toBeDefined()
  expect(await ui.findAll({ type: 'Text', text: /^ {2}\/repo\/a\.ts$/ }), 'a file read twice is listed once').toHaveLength(1)
  expect(await ui.find({ type: 'Text', text: /^ {2}\/repo\/b\.ts$/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: 'files written (2)' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /^ {2}\/repo\/c\.ts$/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /^ {2}\/repo\/n\.ipynb$/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /scratch/ })).toBeUndefined()
  expect(await ui.find({ type: 'Text', text: /tool-results/ })).toBeUndefined()
  expect((await ui.find({ type: 'Text', text: /^MCP calls/ }))?.text).toBe('MCP calls atlassian 2 · plugin_firebase_firebase 1')
  await ui.unmount()
})

test('the lint counters survive clear and are zeroed only by lint reset', async ($, on) => {
  const eng = engine(on)
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  await spawn($, ask('Plan'))
  await spawn($, ask('Explore', { model: 'opus' }))
  await step($, 'a1', 0, 'claude-opus-5-5', 'low')
  const status = async () => (await command($, 'status')).text
  expect(await status()).toContain('1 missing-model, 1 opus+low, 0 max-effort')

  await command($, 'clear')
  expect(await status(), 'clear keeps the evidence').toContain('1 missing-model, 1 opus+low, 0 max-effort')
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect(await ui.find({ type: 'Text', text: 'No agents yet. They show up here as they work.' })).toBeDefined()
  await ui.unmount()

  expect((await command($, 'lint reset')).text).toBe('Dispatch lint counters reset.')
  expect(await status()).toContain('0 missing-model, 0 opus+low, 0 max-effort')
  expect(eng.fx.json(), 'reset touches no setting').toEqual({})
})

test('the lint runs on its own setting: an off or hidden band does not stop warn, deny, counters or the effort lint', async ($, on) => {
  const fx = switchFiles('/home/me', { 'agent-watch': false, 'agent-watch:lint': 'deny' })
  const eng = engine(on, {}, {}, fx)
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })

  const denied = await spawn($, ask('Explore'))
  expect(denied.deny, 'mod off, deny selected: still refused').toContain('model: sonnet')
  expect(eng.spawned).toEqual([])

  await command($, 'lint warn')
  expect(fx.json()).toEqual({ 'agent-watch': false })
  expect((await spawn($, ask('Plan'))).deny).toBeUndefined()
  expect(eng.notices, 'warn still shows while off').toHaveLength(1)
  expect(eng.logs).toHaveLength(1)
  await step($, 'a3', 0, 'claude-opus-5-5', 'low')
  expect(eng.logs, 'effort lint too').toHaveLength(2)
  expect((await command($, 'status')).text).toBe('Dispatch lint warn. Session: 2 missing-model, 1 opus+low, 0 max-effort.')

  // Hidden (tracking on, band hidden) is no different; and only lint off stops it.
  fx.put({ 'agent-watch:hidden': true, 'agent-watch:lint': 'deny' })
  await eng.clock.advance(3100)
  expect((await spawn($, ask('Plan'))).deny).toContain('model: sonnet')
  fx.put({ 'agent-watch': false, 'agent-watch:lint': 'off' })
  expect((await spawn($, ask('Plan'))).deny).toBeUndefined()
  expect((await command($, 'status')).text, 'the denied spawn counted; lint off adds nothing').toContain('3 missing-model')
})

test('the missing-model lint exempts workflow agents and resumed agents', async ($, on) => {
  const eng = engine(on)
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  await command($, 'lint deny')
  const base = { tool_use_id: 'tu', provider: { plugin: 'engine', tier: 'core' }, parentModel: 'claude-opus-5-5', background: false, fork: false, prompt: 'p', description: 'd', subagentType: 'general-purpose' } as const

  const wf = await $.agent.spawn({ ...base, workflow: { runId: 'wf_1', agentIndex: 1 } } as never)
  expect(wf.deny, 'a workflow agent is not refused').toBeUndefined()
  const rs = await $.agent.spawn({ ...base, resume: { agentId: 'a2' } } as never)
  expect(rs.deny, 'a resumed agent is not refused').toBeUndefined()
  expect(eng.notices).toHaveLength(0)
  expect((await command($, 'status')).text).toContain('0 missing-model')
  expect((await $.agent.spawn(base as never)).deny, 'the same spawn without them is refused').toContain('model: sonnet')
  expect((await command($, 'status')).text).toContain('1 missing-model')
})

test('a session that forces the subagent model is not linted', async ($, on) => {
  const eng = engine(on, {}, {}, switchFiles('/home/me', { 'agent-watch:lint': 'deny' }), { CLAUDE_CODE_SUBAGENT_MODEL: 'sonnet' })
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  expect((await spawn($, ask('Explore'))).deny).toBeUndefined()
  expect(eng.spawned).toEqual(['Explore'])
  expect(eng.notices).toHaveLength(0)
  expect((await command($, 'status')).text).toContain('0 missing-model')
})

// XACA-1639-024: every HELP row's description starts at one column, and continuations line up under it.
test('024: every /agent-watch HELP row aligns its description at one column, within 80 columns', async ($, on) => {
  engine(on)
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  const rows = ((await command($, 'help')).text ?? '').split('\n')
  const cols = rows.filter(r => r.startsWith('/')).map(r => /^\/\S+(?: \S+)*? {2,}(?=\S)/.exec(r)?.[0]?.length)

  expect(rows.length).toBeGreaterThan(5)
  expect(new Set(cols).size, `description columns: ${cols.join(',')}`).toBe(1)
  expect(cols[0]).toBeDefined()
  for (const r of rows) {
    expect(r.length, r).toBeLessThanOrEqual(80)
    if (!r.startsWith('/')) expect(r.length - r.trimStart().length, `continuation: ${r}`).toBe(cols[0])
  }
})
