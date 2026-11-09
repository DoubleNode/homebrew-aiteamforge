import { expect, mock, test } from 'claude-code/testing'
import type { Engine, TestBody } from 'claude-code/testing'

import { switchFiles } from './switch-fixture'
import type { SwitchFiles } from './switch-fixture'

type On = Parameters<TestBody>[1]

const HOME = '/home/me'
const MODS = '/opt/brew/libexec/share/claude-mods'
const MARKET = {
  name: 'aiteamforge-mods',
  plugins: [
    { name: 'agent-watch', source: './agent-watch', description: 'Who is doing the work.' },
    { name: 'goal-meter', source: './goal-meter', description: 'Task-list progress.' },
    { name: 'usage-gauge', source: './usage-gauge', description: 'Plan usage.' },
    { name: 'replay-theater', source: './replay-theater', description: 'Replay edits.' },
    { name: 'blast-radius', source: './blast-radius', description: 'Holds risky commands.' },
    { name: 'ticket-lamp', source: './ticket-lamp', description: 'The ticket line.' },
    { name: 'mods-switchboard', source: './mods-switchboard', description: 'This pane.' },
  ],
}
const PLUGIN_DIRS = [`${HOME}/.claude/mods/agent-watch`, `${HOME}/.claude/mods/cache-clock`]
const ok = (stdout = '') => ({ exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false })
const PANE = {
  plugin: 'mods-switchboard',
  component: 'Pane',
  requestId: 'mods',
  props: { title: 'Mods', isFocused: false, bodyColumns: 100, placement: 'dock', scroll: { offset: 0, bodyRows: 40 }, view: {} },
} as const

type World = {
  fx: SwitchFiles
  market?: unknown
  settings?: unknown
  files: Record<string, string>
  opened: string[]
  isPlaced: boolean
}

function engine(on: On, w: Partial<World> = {}) {
  const world: World = {
    fx: w.fx ?? switchFiles(HOME),
    market: 'market' in w ? w.market : MARKET,
    settings: w.settings,
    files: { ...(w.files ?? {}) },
    opened: [],
    isPlaced: w.isPlaced ?? true,
  }
  const text = (v: unknown) => (typeof v === 'string' ? v : JSON.stringify(v))
  const clock = mock.clock(on, { now: 1_000_000 })
  mock.env(on, { HOME, CLAUDE_CODE_PLUGIN_DIRS: PLUGIN_DIRS.join(':') })
  const isMarket = (p: string) => p.endsWith('/.claude-plugin/marketplace.json')
  const isSettings = (p: string) => p === `${HOME}/.claude/settings.json`
  const plugin = (p: string) => (p.endsWith('/.claude-plugin/plugin.json') ? p.split('/').slice(-3, -2)[0] : undefined)

  on('session.start', async (_$, e) => ({ cwd: e.cwd }) as never)
  on('command.register', async () => ({ value: undefined }) as never)
  on('ui.open', async () => ({ value: { isPlaced: world.isPlaced } }) as never)
  on('ui.toast', async () => ({ value: undefined }) as never)
  on('fs.exists', async (_$, e) => {
    const p = (e as { path: string }).path

    return { value: world.fx.exists(p) || (isMarket(p) && world.market !== undefined) || (isSettings(p) && world.settings !== undefined) || plugin(p) !== undefined || p in world.files } as never
  })
  on('fs.read', async (_$, e) => {
    const p = (e as { path: string }).path
    if (isMarket(p)) return { value: text(world.market) } as never
    if (isSettings(p)) return { value: text(world.settings) } as never
    const who = plugin(p)
    if (who !== undefined) return { value: JSON.stringify({ name: who, description: `${who} from a plugin dir` }) } as never

    return { value: world.fx.owns(p) ? world.fx.read(p) : (world.files[p] ?? '') } as never
  })
  on('fs.write', async (_$, e) => {
    world.fx.write((e as { path: string }).path, (e as { text: string }).text)

    return { value: undefined } as never
  })
  on('process.run', async (_$, e) => ({ value: world.fx.run((e as { argv: string[] }).argv) ?? ok() }) as never)
  for (const command of ['agent-watch', 'goals', 'usage-gauge', 'replay']) {
    on('command.run', { command }, async (_$, e) => {
      world.opened.push((e as { command: string }).command)

      return { text: `${command} pane opened` } as never
    })
  }

  return { world, clock }
}

const start = ($: Engine) => $.session.start({ source: 'startup', cwd: '/', surface: 'terminal', isInteractive: true } as never)
const run = async ($: Engine, args: string) => String((await $.command.run({ command: 'mods', args } as never)).text ?? '')
const lineOf = (list: string, name: string) => list.split('\n').find(l => l.startsWith(`${name} `)) ?? ''

test('/mods list shows every marketplace mod beside its folder, and the CLAUDE_CODE_PLUGIN_DIRS entries', async ($, on) => {
  engine(on)
  await start($)
  const list = await run($, 'list')

  expect(lineOf(list, 'agent-watch')).toContain('on · shown')
  expect(lineOf(list, 'agent-watch'), 'the marketplace folder').toContain(`${'/'}agent-watch`)
  expect(lineOf(list, 'agent-watch'), 'and the plugin dir that loads it too').toContain(`CLAUDE_CODE_PLUGIN_DIRS ${HOME}/.claude/mods/agent-watch`)
  expect(lineOf(list, 'goal-meter')).toContain('goal-meter')
  expect(lineOf(list, 'cache-clock'), 'a plugin-dir mod that is not in the marketplace').toContain('(not in the marketplace)')
  expect(lineOf(list, 'cache-clock')).toContain(`CLAUDE_CODE_PLUGIN_DIRS ${HOME}/.claude/mods/cache-clock`)
  for (const m of MARKET.plugins) expect(lineOf(list, m.name), `${m.name} is listed`).not.toBe('')
})

test('blast-radius ships off and /mods on writes an explicit true; the others turn on by clearing their key', async ($, on) => {
  const { world } = engine(on, { fx: switchFiles(HOME, { keep: { me: 1 } }) })
  await start($)
  expect(lineOf(await run($, 'list'), 'blast-radius')).toContain('off (ships off)')

  expect(await run($, 'on blast-radius')).toContain('blast-radius: on')
  expect(world.fx.json()).toEqual({ keep: { me: 1 }, 'blast-radius': true })
  expect(await run($, 'off blast-radius')).toContain('off')
  expect(world.fx.json()).toEqual({ keep: { me: 1 }, 'blast-radius': false })

  expect(await run($, 'off goal-meter')).toContain('goal-meter: off')
  expect(world.fx.json()).toEqual({ keep: { me: 1 }, 'blast-radius': false, 'goal-meter': false })
  expect(await run($, 'on goal-meter')).toContain('goal-meter: on · shown')
  expect(world.fx.json()).toEqual({ keep: { me: 1 }, 'blast-radius': false })
})

test('hide and show write the :hidden key and keep every other key; no temp file is left', async ($, on) => {
  const { world } = engine(on, { fx: switchFiles(HOME, { 'cache-clock:hidden': true, extra: [1, 2] }) })
  await start($)
  expect(await run($, 'hide ticket-lamp')).toContain('on · hidden')
  expect(world.fx.json()).toEqual({ 'cache-clock:hidden': true, extra: [1, 2], 'ticket-lamp:hidden': true })
  expect(lineOf(await run($, 'list'), 'ticket-lamp')).toContain('on · hidden')
  expect(await run($, 'show ticket-lamp')).toContain('on · shown')
  expect(world.fx.json()).toEqual({ 'cache-clock:hidden': true, extra: [1, 2] })
  expect(world.fx.clean()).toBe(true)
  expect(world.fx.writes.every(p => p.endsWith('.tmp'))).toBe(true)
})

test('a mod that settings disable is "not loaded", has no toggle, and is never written', async ($, on) => {
  const { world } = engine(on, { settings: { enabledPlugins: { 'goal-meter@aiteamforge-mods': false, 'agent-watch@aiteamforge-mods': true } } })
  await start($)
  const list = await run($, 'list')
  expect(lineOf(list, 'goal-meter')).toContain('not loaded')
  expect(lineOf(list, 'agent-watch')).toContain('on · shown')

  expect(await run($, 'off goal-meter')).toContain('is not loaded')
  expect(await run($, 'on goal-meter')).toContain('cannot be switched here')
  expect(await run($, 'open goal-meter')).toContain('is not loaded')
  // XACA-1605-036: the dead end names its own way out.
  const FIX = 'claude plugin enable goal-meter@aiteamforge-mods'
  expect(await run($, 'on goal-meter')).toContain(FIX)
  expect(await run($, 'off goal-meter')).toContain('restart')
  expect(await run($, 'help')).toContain('claude plugin enable <mod>@aiteamforge-mods')
  expect(world.fx.writes, 'nothing was written').toEqual([])

  await run($, '')
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect(await ui.find({ key: 'toggle:goal-meter' }), 'no toggle for a not-loaded mod').toBeUndefined()
  expect(await ui.find({ key: 'toggle:agent-watch' })).toBeDefined()
  expect(await ui.find({ text: /not loaded/ })).toBeDefined()
  expect(await ui.find({ text: /claude plugin enable goal-meter@aiteamforge-mods/ }), 'pane row names the fix').toBeDefined()
  await ui.unmount()
})

test('a malformed switch file shows defaults, says so, and refuses to overwrite it', async ($, on) => {
  const { world } = engine(on, { fx: switchFiles(HOME, '{ nope') })
  await start($)
  const list = await run($, 'list')
  expect(lineOf(list, 'agent-watch')).toContain('on · shown')
  expect(lineOf(list, 'blast-radius')).toContain('off (ships off)')
  expect(list).toContain('switches.json is unreadable')

  expect(await run($, 'off agent-watch')).toContain('unreadable')
  expect(world.fx.files[world.fx.path]).toBe('{ nope')
  expect(world.fx.writes).toEqual([])
})

for (const market of [undefined, '{ nope', { plugins: 'x' }]) {
  test(`a missing or broken marketplace.json (${JSON.stringify(market)}) still lists the plugin dirs, with a note`, async ($, on) => {
    engine(on, { market })
    await start($)
    const list = await run($, 'list')
    expect(lineOf(list, 'agent-watch')).toContain('CLAUDE_CODE_PLUGIN_DIRS')
    expect(lineOf(list, 'cache-clock')).toContain('CLAUDE_CODE_PLUGIN_DIRS')
    expect(list).toMatch(/marketplace\.json/)
  })
}

test('the pane lists the mods with On/Off, Hide/Show and Open pane buttons, backed by the file', async ($, on) => {
  const { world } = engine(on, { fx: switchFiles(HOME, { 'goal-meter': false }) })
  await start($)
  expect(await run($, '')).toBe('Mods pane opened.')
  let ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await ui.find({ key: 'toggle:goal-meter' }))?.props.label, 'off, so the button turns it on').toBe('Turn goal-meter on')
  expect((await ui.find({ key: 'toggle:agent-watch' }))?.props.label).toBe('Turn agent-watch off')
  expect((await ui.find({ key: 'view:agent-watch' }))?.props.label).toBe('Hide agent-watch')
  expect(await ui.find({ key: 'open:agent-watch' }), 'agent-watch has a pane').toBeDefined()
  expect(await ui.find({ key: 'open:ticket-lamp' }), 'ticket-lamp has none').toBeUndefined()
  expect(await ui.find({ key: 'toggle:mods-switchboard' }), 'the pane cannot switch itself off').toBeUndefined()

  await ui.press({ key: 'toggle:agent-watch' })
  expect(world.fx.json()).toEqual({ 'goal-meter': false, 'agent-watch': false })
  await ui.press({ key: 'toggle:goal-meter' })
  await ui.press({ key: 'view:ticket-lamp' })
  expect(world.fx.json()).toEqual({ 'agent-watch': false, 'ticket-lamp:hidden': true })
  await ui.unmount()

  ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await ui.find({ key: 'toggle:agent-watch' }))?.props.label).toBe('Turn agent-watch on')
  expect((await ui.find({ key: 'view:ticket-lamp' }))?.props.label).toBe('Show ticket-lamp')
  await ui.unmount()
})

test('every button on the pane has its own accessible name that includes the mod name', async ($, on) => {
  engine(on, { fx: switchFiles(HOME, {}) })
  await start($)
  await run($, '')
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  const labels: string[] = []
  for (const key of ['toggle', 'view', 'open']) {
    for (const mod of ['agent-watch', 'goal-meter', 'gate-board']) {
      const b = await ui.find({ key: `${key}:${mod}` })
      if (b === undefined) continue
      const label = String(b.props.label)
      expect(label, `${key}:${mod} names its mod`).toContain(mod)
      labels.push(label)
    }
  }
  expect(labels.length).toBeGreaterThanOrEqual(6)
  expect(new Set(labels).size, 'no two buttons share a name').toBe(labels.length)
  await ui.unmount()
})

test('the button row wraps in a narrow pane, and Open pane is hidden (with a text cue) while the mod is off', async ($, on) => {
  engine(on, { fx: switchFiles(HOME, { 'goal-meter': false }) })
  await start($)
  await run($, '')
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  const row = await ui.find({ key: 'toggle:agent-watch' })
  expect(row, 'agent-watch has its toggle').toBeDefined()
  const boxes = await ui.findAll({ type: 'Box' })
  const wrapping = boxes.filter(b => b.props.flexWrap === 'wrap')
  expect(wrapping.length, 'every button row wraps instead of clipping').toBeGreaterThanOrEqual(2)
  expect(wrapping.every(b => b.props.flexDirection === 'row')).toBe(true)

  expect(await ui.find({ key: 'open:goal-meter' }), 'goal-meter is off: no dead-end Open button').toBeUndefined()
  expect(await ui.find({ text: /pane opens once goal-meter is on/ }), 'a text cue says why').toBeDefined()
  expect(await ui.find({ key: 'open:agent-watch' }), 'agent-watch is on: Open is offered').toBeDefined()
  expect(await ui.find({ text: /pane opens once agent-watch is on/ })).toBeUndefined()
  await ui.unmount()
})

test('state colours are theme keys, and the state word travels with them', async ($, on) => {
  engine(on, { fx: switchFiles(HOME, { 'goal-meter': false }) })
  await start($)
  await run($, '')
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  const off = await ui.find({ type: 'Text', text: /^ off/ })
  const on_ = await ui.find({ type: 'Text', text: /^ on/ })
  expect(off?.props.color).toBe('warning')
  expect(on_?.props.color).toBe('success')
  await ui.unmount()
})

test('Open pane runs the mod\'s own pane command; an off mod is asked to be turned on first', async ($, on) => {
  const { world, clock } = engine(on, { fx: switchFiles(HOME, { 'goal-meter': false }) })
  await start($)
  await run($, '')
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  await ui.press({ key: 'open:agent-watch' })
  expect(world.opened).toEqual(['agent-watch'])
  await ui.unmount()

  // From the command line the run is handed to a timer, outside the command.run hook.
  expect(await run($, 'open usage-gauge')).toContain('Opening the usage-gauge pane')
  expect(await run($, 'open replay-theater')).toContain('Opening the replay-theater pane')
  await clock.advance(300)
  expect(world.opened).toEqual(['agent-watch', 'usage-gauge', 'replay'])
  expect(await run($, 'open goal-meter')).toContain('is off')
  expect(await run($, 'open ticket-lamp')).toContain('has no side pane')
  expect(world.opened).toHaveLength(3)
})

test('on a narrow terminal with no room for the pane, /mods answers with the list', async ($, on) => {
  engine(on, { isPlaced: false })
  await start($)
  expect(await run($, '')).toContain('agent-watch  on · shown')
})

test('unknown mod, unknown option and a missing name are answered, not thrown', async ($, on) => {
  const { world } = engine(on)
  await start($)
  expect(await run($, 'off nothing-here')).toContain('No mod named "nothing-here"')
  expect(await run($, 'frobnicate')).toContain('Unknown option')
  expect(await run($, 'off')).toContain('Which mod?')
  expect(await run($, 'off mods-switchboard')).toContain('stays on')
  expect(await run($, 'help')).toContain('/mods list')
  expect(world.fx.writes).toEqual([])
})
