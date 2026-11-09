import { expect, mock, test } from 'claude-code/testing'
import type { Engine, TestBody } from 'claude-code/testing'

import { switchFiles } from './switch-fixture'

type On = Parameters<TestBody>[1]

const SURFACES = ['terminal', 'desktop'] as const
const NOW = Date.parse('2026-10-24T05:00:00Z')
const STORE = '/home/me/dev-team/kanban-hooks/msg-store.py'

const BAND = {
  plugin: 'inbox-lamp',
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

type Msg = { from_team: string; from_terminal: string; body: string; created_at: string; read_at: string | null }

const msg = (body: string, hoursAgo: number, isRead = false): Msg => ({
  from_team: 'academy',
  from_terminal: hoursAgo === 1 ? 'medical' : 'engineering',
  body,
  created_at: new Date(NOW - hoursAgo * 3_600_000).toISOString(),
  read_at: isRead ? new Date(NOW - hoursAgo * 3_600_000 + 60_000).toISOString() : null,
})

// Nothing sits beneath the plugin: these hooks stand for the engine, a
// tmux session named academy-engineering and the msg-store.py CLI.
function engine(
  on: On,
  inbox: Msg[],
  env: Record<string, string> = { HOME: '/home/me', TMUX_PANE: '%3' },
  store = STORE,
  exitCode = 0,
) {
  const clock = mock.clock(on, { now: NOW })
  mock.store(on)
  mock.env(on, env)
  const argvs: string[][] = []
  const fx = switchFiles()

  on('command.register', () => ({ value: { command: 'inbox-lamp' } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('fs.exists', (_, e) => ({ value: fx.owns(e.path) ? fx.exists(e.path) : e.path === store }))
  on('fs.read', (_, e) => ({ value: fx.read(e.path) }))
  on('fs.write', (_, e) => {
    fx.write(e.path, e.text)

    return { value: undefined }
  })
  on('process.run', (_, e) => {
    const moved = fx.run(e.argv)
    if (moved) return { value: moved }
    argvs.push([...e.argv])
    const out = (stdout: string) => ({
      value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false },
    })
    if (e.argv[0] === 'tmux') return out('academy-engineering\n')
    if (e.argv[0] === 'python3' && e.argv[1] === store) {
      return exitCode === 0
        ? out(JSON.stringify(inbox))
        : { value: { exitCode, stdout: '', stderr: 'boom', isStdoutTruncated: false, isStderrTruncated: false } }
    }

    return { value: { exitCode: 127, stdout: '', stderr: 'nope', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  // Another mod's band line, beneath this one.
  on('ui.render', { component: 'AbovePrompt' }, ($, e) => {
    const { Text } = $.ui.resolve(e)

    return <Text>other mod line</Text>
  })

  return { clock, argvs, fx }
}

async function start($: Engine, surface: (typeof SURFACES)[number] = 'terminal') {
  await $.session.start({ cwd: '/', surface, isInteractive: true })
}

async function lamp($: Engine, surface: (typeof SURFACES)[number]) {
  const ui = await $.ui.mount({ ...BAND, surface })
  const texts = (await ui.findAll({ type: 'Text' })).map(t => t.text)
  const chip = await ui.find({ type: 'Text', text: /^ ✉ INBOX $/ })
  await ui.unmount()

  return { line: texts.find(t => t.includes('INBOX')), texts, chip }
}

function command($: Engine, args = '') {
  return $.command.run({
    command: 'inbox-lamp',
    args,
    origin: { kind: 'composer' },
    presentation: { isFullscreen: true, columns: 200 },
  })
}

test('unread mail with a freeze order turns the lamp red, above another mod', async ($, on) => {
  const { clock } = engine(on, [
    msg('build is green, merging', 3),
    msg('FREEZE: do not merge to develop until 1200 lands', 2),
    msg('XACA-1457 merge order: #1107 first', 1),
    msg('old note', 30, true),
  ])

  for (const surface of SURFACES) {
    await start($, surface)
    await clock.settle()
    const { line, texts, chip } = await lamp($, surface)

    expect(line).toContain('3 unread')
    expect(line).toContain('⚠ 2 freeze/merge-order')
    expect(line).toContain('newest academy:medical "XACA-1457 merge order: #1107 first"')
    expect(chip?.props).toMatchObject({ color: '#0b0b0f', backgroundColor: '#ef4444', weight: 'bold' })
    expect(texts.indexOf('other mod line')).toBeGreaterThan(texts.findIndex(t => t.includes('INBOX')))
  }
})

test('plain unread mail keeps the lamp cyan', async ($, on) => {
  const { clock } = engine(on, [msg('repull the port map', 1)])
  await start($)
  await clock.settle()
  const { line, chip } = await lamp($, 'terminal')

  expect(line).toContain('1 unread')
  expect(line).not.toContain('⚠')
  expect(chip?.props.backgroundColor).toBe('#22d3ee')
})

test('a freeze order a sibling already read still shows, amber, for 12 hours', async ($, on) => {
  const { clock } = engine(on, [msg('merge freeze on develop tonight', 2, true), msg('freeze lifted last week', 40, true)])
  await start($)
  await clock.settle()
  const { line, chip } = await lamp($, 'desktop')

  expect(line).toContain('⚑ 1 read in 12h')
  expect(line).not.toContain('unread')
  expect(chip?.props.backgroundColor).toBe('#22d3ee')
})

test('an empty inbox draws nothing and leaves the other line', async ($, on) => {
  const { clock } = engine(on, [msg('old', 30, true)])
  await start($)
  await clock.settle()
  const { line, texts } = await lamp($, 'terminal')

  expect(line).toBeUndefined()
  expect(texts).toContain('other mod line')
})

test('new mail is picked up on the next poll', async ($, on) => {
  const inbox: Msg[] = []
  const { clock } = engine(on, inbox)
  await start($)
  await clock.settle()
  expect((await lamp($, 'terminal')).line).toBeUndefined()

  inbox.push(msg('ping', 1))
  await clock.advance(60_000)
  expect((await lamp($, 'terminal')).line).toContain('1 unread')
})

test('the lamp only ever lists: it never marks mail read', async ($, on) => {
  const { clock, argvs } = engine(on, [msg('hello', 1)])
  await start($)
  await clock.settle()
  await command($)
  await clock.advance(5 * 60_000)

  const storeCalls = argvs.filter(a => a[1] === STORE)
  expect(storeCalls.length).toBeGreaterThan(1)
  for (const argv of storeCalls) {
    expect(argv.slice(2, 3)).toEqual(['inbox'])
    expect(argv).toContain('--json')
  }
})

test('with no kb-msg address the lamp stays dark and says why', async ($, on) => {
  const { clock } = engine(on, [msg('hello', 1)], { HOME: '/home/me' })
  await start($)
  await clock.settle()

  expect((await lamp($, 'terminal')).line).toBeUndefined()
  expect((await command($)).text).toBe('Inbox lamp: no address.')
})

test('off hides the lamp, stops the polling and is remembered in the shared switch file', async ($, on) => {
  const { clock, argvs, fx } = engine(on, [msg('hello', 1)])
  await start($)
  await clock.settle()
  expect((await lamp($, 'terminal')).line).toContain('1 unread')

  expect((await command($, 'off')).text).toBe('Inbox lamp off.')
  expect(fx.json()).toEqual({ 'inbox-lamp': false })
  expect((await lamp($, 'terminal')).line).toBeUndefined()
  const before = argvs.length
  await clock.advance(5 * 60_000)
  expect(argvs.length, 'no polling while off').toBe(before)
  await start($)
  await clock.settle()
  expect((await lamp($, 'terminal')).line).toBeUndefined()
  expect((await command($, 'help')).text).toContain('never marks anything read')

  expect((await command($, 'on')).text).toBe('Inbox lamp on.')
  expect(fx.json()).toEqual({})
  await clock.settle()
  expect((await lamp($, 'terminal')).line).toContain('1 unread')
})

test('hidden hides the line but keeps polling; show brings it back', async ($, on) => {
  const { clock, argvs, fx } = engine(on, [msg('hello', 1)])
  fx.put({ 'inbox-lamp:hidden': true })
  await start($)
  await clock.settle()
  expect((await lamp($, 'terminal')).line, 'hidden by the file').toBeUndefined()
  const before = argvs.length
  await clock.advance(60_000)
  expect(argvs.length, 'still polling while hidden').toBeGreaterThan(before)

  await command($, 'show')
  expect(fx.json()).toEqual({})
  expect((await lamp($, 'terminal')).line).toContain('1 unread')
  await command($, 'hide')
  expect(fx.json()).toEqual({ 'inbox-lamp:hidden': true })
  expect((await lamp($, 'terminal')).line).toBeUndefined()
})

test('a missing switch file shows the lamp; a malformed one shows it too and is left alone', async ($, on) => {
  const { clock, fx } = engine(on, [msg('hello', 1)])
  await start($)
  await clock.settle()
  expect(fx.exists(fx.path)).toBe(false)
  expect((await lamp($, 'terminal')).line, 'missing file: shown').toContain('1 unread')

  for (const bad of ['{ nope', '[]', '"off"', '{"inbox-lamp":"false","inbox-lamp:hidden":"true"}']) {
    fx.put(bad)
    await clock.advance(3100)
    expect((await lamp($, 'terminal')).line, `malformed (${bad}): shown`).toContain('1 unread')
  }
  fx.put('{ nope')
  expect((await command($, 'off')).text).toContain('could not save')
  expect(fx.files[fx.path], 'the broken file is not overwritten').toBe('{ nope')
})

test('toggling keeps every other key in the switch file, and another chat flipping it is picked up', async ($, on) => {
  const { clock, fx } = engine(on, [msg('hello', 1)])
  fx.put({ 'cache-clock:hidden': true, 'agent-watch': false, extra: [1] })
  await start($)
  await clock.settle()
  await command($, 'off')
  await command($, 'hide')
  expect(fx.json()).toEqual({ 'cache-clock:hidden': true, 'agent-watch': false, extra: [1], 'inbox-lamp': false, 'inbox-lamp:hidden': true })
  await command($, 'on')
  expect(fx.json()).toEqual({ 'cache-clock:hidden': true, 'agent-watch': false, extra: [1] })
  expect(fx.clean()).toBe(true)

  // Another chat (or /mods) turns it off: the poll sees it within 3 s.
  fx.put({ 'inbox-lamp': false })
  await clock.advance(3100)
  expect((await lamp($, 'terminal')).line).toBeUndefined()
})

// Consumer layout (a tap install): msg-store.py lives under ~/aiteamforge, there
// may be no dev-team clone, and a failed read must never read as an empty inbox.
const TAP_STORE = '/home/me/aiteamforge/kanban-hooks/msg-store.py'

test('consumer: a tap install finds msg-store.py under ~/aiteamforge with no dev-team clone', async ($, on) => {
  const { clock, argvs } = engine(on, [msg('repull the port map', 1)], { HOME: '/home/me', TMUX_PANE: '%3' }, TAP_STORE)
  await start($)
  await clock.settle()

  expect((await lamp($, 'terminal')).line).toContain('1 unread')
  expect(argvs.some(a => a[0] === 'python3' && a[1] === TAP_STORE)).toBe(true)
})

test('consumer: AITEAMFORGE_DIR wins when the install is not under ~/aiteamforge', async ($, on) => {
  const odd = '/opt/forge/kanban-hooks/msg-store.py'
  const { clock } = engine(on, [msg('hello', 1)], { HOME: '/home/me', TMUX_PANE: '%3', AITEAMFORGE_DIR: '/opt/forge' }, odd)
  await start($)
  await clock.settle()

  expect((await lamp($, 'terminal')).line).toContain('1 unread')
})

test('consumer: no msg-store anywhere draws nothing, runs no python and says why', async ($, on) => {
  const { clock, argvs } = engine(on, [msg('hello', 1)], { HOME: '/home/me', TMUX_PANE: '%3' }, '/nowhere/msg-store.py')
  await start($)
  await clock.settle()
  const { line, texts } = await lamp($, 'terminal')

  expect(line).toBeUndefined()
  expect(texts).toContain('other mod line')
  expect(argvs.some(a => a[0] === 'python3')).toBe(false)
  expect((await command($)).text).toBe('Inbox lamp: no msg-store.')
})

test('consumer: a msg-store that fails shows no unread count, only that the inbox is unreadable', async ($, on) => {
  const { clock } = engine(on, [msg('hello', 1)], { HOME: '/home/me', TMUX_PANE: '%3' }, STORE, 1)
  await start($)
  await clock.settle()
  const { line } = await lamp($, 'terminal')

  expect(line).toContain('inbox unreadable')
  expect(line).not.toMatch(/\d+ unread/)
})
