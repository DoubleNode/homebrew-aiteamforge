import { expect, mock, test } from 'claude-code/testing'
import type { Engine, TestBody } from 'claude-code/testing'

import { switchFiles } from '../tests/switch-fixture'
import type { SwitchFiles } from '../tests/switch-fixture'

// The shared switch file (hooks/switches.ts) decides whether the ticket line is drawn.
type On = Parameters<TestBody>[1]

const BAND = {
  plugin: 'ticket-lamp',
  component: 'AbovePrompt',
  props: { hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: 160, scroll: { offset: 0, bodyRows: 10 }, view: {} },
} as const
const CONFIG = '/home/me/.aiteamforge/team-paths.json'
const TEAMS = { teams: { acme: { kanban_dir: '/home/me/acme/kanban', team_code: 'ACME' } } }
const out = (exitCode: number, stdout: string) => ({
  value: { exitCode, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false },
})

function engine(on: On, fx: SwitchFiles, calls: string[][] = []) {
  const clock = mock.clock(on, { now: 1_000_000 })
  mock.store(on)
  mock.env(on, { HOME: fx.home, CC_SESSION_NAME: 'XACME-0100: Ship it' })
  on('command.register', () => ({ value: { command: 'ticket' } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('session.id', () => ({ value: 'sess-1' }))
  on('fs.exists', (_, e) => ({ value: fx.exists(e.path) }))
  on('fs.read', (_, e) => {
    if (fx.owns(e.path)) return { value: fx.read(e.path) }
    if (e.path !== CONFIG) throw new Error('ENOENT')
    calls.push(['team registry'])

    return { value: JSON.stringify(TEAMS) }
  })
  on('fs.write', (_, e) => {
    fx.write(e.path, e.text)

    return { value: undefined }
  })
  on('fs.list', () => ({ value: [{ name: 'acme-board.json', kind: 'file' as const, size: 1, mtimeMs: 1, isLink: false }] }))
  on('process.run', (_, e) => {
    const moved = fx.run(e.argv)
    if (moved) return { value: moved }
    if (e.argv[0] !== 'jq') return out(127, '')

    return out(0, JSON.stringify({ found: true, kind: 'ticket', title: 'Ship it', status: 'in_progress', subs: [], release: null, epic: null, prMerged: null }))
  })
  on('ui.render', { component: 'AbovePrompt' }, ($, e) => {
    const { Text } = $.ui.resolve(e)

    return <Text>other mod line</Text>
  })

  return clock
}

const start = ($: Engine) => $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
const command = ($: Engine, args: string) =>
  $.command.run({ command: 'ticket', args, origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 200 } })

async function line($: Engine) {
  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
  const texts = (await ui.findAll({ type: 'Text' })).map(t => t.text)
  await ui.unmount()

  return { texts, shown: texts.some(t => t.includes('XACME-0100')) }
}

test('off hides the line and stops the board reads; on brings it back (shared switch file)', async ($, on) => {
  const fx = switchFiles()
  const calls: string[][] = []
  const clock = engine(on, fx, calls)
  await start($)
  await clock.settle()
  expect((await line($)).shown).toBe(true)

  expect((await command($, 'off')).text).toBe('Ticket line off.')
  expect(fx.json()).toEqual({ 'ticket-lamp': false })
  const { texts, shown } = await line($)
  expect(shown).toBe(false)
  expect(texts, 'other bands still draw').toContain('other mod line')
  const before = calls.length
  await clock.advance(10 * 60_000)
  expect(calls.length, 'no board reads while off').toBe(before)

  expect((await command($, 'on')).text).toBe('Ticket line on.')
  expect(fx.json()).toEqual({})
  await clock.settle()
  expect((await line($)).shown).toBe(true)
})

test('hidden hides the line but keeps reading; missing and malformed files show it', async ($, on) => {
  const fx = switchFiles('/home/me', { 'ticket-lamp:hidden': true })
  const calls: string[][] = []
  const clock = engine(on, fx, calls)
  await start($)
  await clock.settle()
  expect((await line($)).shown, 'hidden by the file').toBe(false)
  const before = calls.length
  await clock.advance(121_000)
  expect(calls.length, 'still reading while hidden').toBeGreaterThan(before)

  fx.remove()
  await clock.advance(3100)
  expect((await line($)).shown, 'missing file: shown').toBe(true)
  for (const bad of ['{ nope', '[]', '{"ticket-lamp":"false","ticket-lamp:hidden":"true"}']) {
    fx.put({ 'ticket-lamp:hidden': true })
    await clock.advance(3100)
    expect((await line($)).shown).toBe(false)
    fx.put(bad)
    await clock.advance(3100)
    expect((await line($)).shown, `malformed (${bad}): shown`).toBe(true)
  }
  fx.put('{ nope')
  expect((await command($, 'off')).text).toContain('could not save')
  expect(fx.files[fx.path]).toBe('{ nope')
})

test('toggling keeps every other key in the switch file', async ($, on) => {
  const fx = switchFiles('/home/me', { 'cache-clock:hidden': true, extra: [1, 2] })
  const clock = engine(on, fx)
  await start($)
  await clock.settle()
  await command($, 'off')
  await command($, 'hide')
  expect(fx.json()).toEqual({ 'cache-clock:hidden': true, extra: [1, 2], 'ticket-lamp': false, 'ticket-lamp:hidden': true })
  await command($, 'on')
  expect(fx.json()).toEqual({ 'cache-clock:hidden': true, extra: [1, 2] })
  expect(fx.clean()).toBe(true)
})
