import { expect, mock, test } from 'claude-code/testing'
import type { Engine, TestBody } from 'claude-code/testing'

import { switchFiles } from './switch-fixture'
import type { SwitchFiles } from './switch-fixture'

type On = Parameters<TestBody>[1]

const SURFACES = ['terminal', 'desktop'] as const
const HEAD = 'aaaa1111'
const REPO = '/repo/dev-team'
const BOARD = `${REPO}/kanban/academy-board.json`

const BAND = {
  plugin: 'gate-board',
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

type World = {
  branch: string
  pr: object | null
  board: object
}

const success = (n: number) => Array.from({ length: n }, () => ({ status: 'COMPLETED', conclusion: 'SUCCESS' }))
const review = (login: string, state: string, oid = HEAD) => ({ author: { login }, state, commit: { oid } })

function world(overrides: Partial<World> = {}): World {
  return {
    branch: 'feature/xaca-1201-gates',
    pr: {
      number: 1201,
      state: 'OPEN',
      headRefOid: HEAD,
      reviews: [review('ds9-tester-bot', 'APPROVED'), review('ai-security-review-bot', 'CHANGES_REQUESTED')],
      statusCheckRollup: [...success(12), { status: 'IN_PROGRESS', conclusion: null }, { status: 'QUEUED', conclusion: null }],
    },
    board: {
      backlog: [
        {
          id: 'XACA-1201',
          subitems: [
            { title: '[Review] fix the guard (PR #1201)', status: 'todo' },
            { title: '[Test] add a case (PR #1201)' },
            { title: '[UX] no UX/UI surface', status: 'cancelled' },
            { title: 'write code', status: 'todo' },
          ],
        },
      ],
    },
    ...overrides,
  }
}

// Nothing sits beneath the plugin: these hooks stand for the engine, git,
// gh and the board on disk.
function engine(on: On, w: World, fx: SwitchFiles = switchFiles(), calls: string[][] = []) {
  const clock = mock.clock(on, { now: 1_000_000 })
  mock.store(on)
  mock.env(on, { HOME: fx.home })
  const out = (exitCode: number, stdout: string) => ({
    value: { exitCode, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false },
  })

  on('command.register', () => ({ value: { command: 'gate-board' } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('process.run', (_, e) => {
    const moved = fx.run(e.argv)
    if (moved) return { value: moved }
    calls.push([...e.argv])
    const [cmd, sub] = e.argv
    if (cmd === 'git' && sub === 'branch') return out(0, `${w.branch}\n`)
    if (cmd === 'git' && sub === 'rev-parse') return out(0, `${REPO}/.git\n`)
    if (cmd === 'gh') return w.pr === null ? out(1, '') : out(0, JSON.stringify(w.pr))

    return out(127, '')
  })
  on('fs.list', (_, e) => ({
    value: e.path === `${REPO}/kanban` ? [{ name: 'academy-board.json', kind: 'file' as const, size: 1, mtimeMs: 0, isLink: false }] : [],
  }))
  on('fs.read', (_, e) => (e.path === BOARD ? { value: JSON.stringify(w.board) } : { value: fx.read(e.path) }))
  on('fs.exists', (_, e) => ({ value: fx.exists(e.path) }))
  on('fs.write', (_, e) => {
    fx.write(e.path, e.text)

    return { value: undefined }
  })
  // Another mod's band line, beneath this one.
  on('ui.render', { component: 'AbovePrompt' }, ($, e) => {
    const { Text } = $.ui.resolve(e)

    return <Text>other mod line</Text>
  })

  return clock
}

async function start($: Engine, surface: (typeof SURFACES)[number] = 'terminal') {
  await $.session.start({ cwd: REPO, surface, isInteractive: true })
}

async function board($: Engine, surface: (typeof SURFACES)[number] = 'terminal') {
  const ui = await $.ui.mount({ ...BAND, surface })
  const texts = (await ui.findAll({ type: 'Text' })).map(t => t.text)
  const find = (text: RegExp) => ui.find({ type: 'Text', text })
  const parts = {
    chip: await find(/^ ⛭ GATES $/),
    ci: await find(/^CI /),
    sweep: await find(/^sweep /),
    test: await find(/^✓ stale$/),
  }
  await ui.unmount()

  return { line: texts.find(t => t.includes('GATES')), texts, ...parts }
}

function command($: Engine, args = '') {
  return $.command.run({
    command: 'gate-board',
    args,
    origin: { kind: 'composer' },
    presentation: { isFullscreen: true, columns: 200 },
  })
}

test('an open PR shows bots, CI and the sweep, above another mod', async ($, on) => {
  const clock = engine(on, world())

  for (const surface of SURFACES) {
    await start($, surface)
    await clock.settle()
    const { line, texts, chip, ci, sweep } = await board($, surface)

    expect(line).toBe(' ⛭ GATES  PR #1201 · test ✓ · review ✗ · CI 12/14 · sweep 2 open')
    expect(chip?.props).toMatchObject({ color: '#0b0b0f', backgroundColor: '#a78bfa', weight: 'bold' })
    expect(ci?.props.color).toBe('warning')
    expect(sweep?.props.color).toBe('warning')
    expect(texts.indexOf('other mod line')).toBeGreaterThan(texts.findIndex(t => t.includes('GATES')))
  }
})

test('an approval of an older commit reads stale; a failed check reads red', async ($, on) => {
  const w = world()
  w.pr = {
    number: 1201,
    state: 'OPEN',
    headRefOid: HEAD,
    reviews: [review('ds9-tester-bot[bot]', 'APPROVED', 'old0000'), review('ai-security-review-bot', 'APPROVED')],
    statusCheckRollup: [...success(13), { status: 'COMPLETED', conclusion: 'FAILURE' }],
  }
  const clock = engine(on, w)
  await start($)
  await clock.settle()
  const { line, test: stale, ci } = await board($)

  expect(line).toContain('test ✓ stale · review ✓ · CI ✗ 1 of 14')
  expect(stale?.props.color).toBe('warning')
  expect(ci?.props.color).toBe('error')
})

test('a subitem with no status is still open; all resolved reads sweep ✓', async ($, on) => {
  const w = world()
  const clock = engine(on, w)
  await start($)
  await clock.settle()
  expect((await board($)).line).toContain('sweep 2 open')

  w.board = { backlog: [{ id: 'XACA-1201', subitems: [{ title: '[Review] x', status: 'completed' }] }] }
  await clock.advance(120_000)
  expect((await board($)).line).toContain('sweep ✓')
})

test('develop and a branch with no PR draw nothing', async ($, on) => {
  const w = world({ branch: 'develop' })
  const clock = engine(on, w)
  await start($)
  await clock.settle()
  const onDevelop = await board($)
  expect(onDevelop.line).toBeUndefined()
  expect(onDevelop.texts).toContain('other mod line')

  w.branch = 'feature/xaca-9999'
  w.pr = null
  await clock.advance(120_000)
  expect((await board($)).line).toBeUndefined()
  expect((await command($)).text).toBe('No PR found for this branch (or gh is not signed in).')
})

test('a merged PR shows merged ✓ for ten minutes, then leaves', async ($, on) => {
  const w = world()
  w.pr = { ...(w.pr as object), state: 'MERGED' }
  const clock = engine(on, w)
  await start($)
  await clock.settle()
  expect((await board($)).line).toBe(' ⛭ GATES  PR #1201 merged ✓')

  await clock.advance(10 * 60_000)
  expect((await board($)).line).toBeUndefined()
})

test('off hides the board, stops the checks and is remembered in the shared switch file', async ($, on) => {
  const fx = switchFiles()
  const calls: string[][] = []
  const clock = engine(on, world(), fx, calls)
  await start($)
  await clock.settle()
  expect((await board($)).line).toContain('PR #1201')

  expect((await command($, 'off')).text).toBe('Gate board off.')
  expect(fx.json()).toEqual({ 'gate-board': false })
  expect((await board($)).line).toBeUndefined()
  const before = calls.length
  await clock.advance(10 * 60_000)
  expect(calls.length, 'no gh calls while off').toBe(before)
  await start($)
  await clock.settle()
  expect((await board($)).line).toBeUndefined()
  expect((await command($, 'help')).text).toContain('kb-pr-monitor still decides')

  expect((await command($, 'on')).text).toBe('Gate board on.')
  expect(fx.json()).toEqual({})
})

test('hidden hides the line; a missing or malformed switch file shows it', async ($, on) => {
  const fx = switchFiles('/home/me', { 'gate-board:hidden': true })
  const clock = engine(on, world(), fx)
  await start($)
  await clock.settle()
  expect((await board($)).line, 'hidden by the file').toBeUndefined()

  fx.remove()
  await clock.advance(3100)
  expect((await board($)).line, 'missing file: shown').toContain('PR #1201')
  fx.put({ 'gate-board:hidden': true })
  await clock.advance(3100)
  expect((await board($)).line).toBeUndefined()
  for (const bad of ['{ nope', '[]', '{"gate-board":"false","gate-board:hidden":"true"}']) {
    fx.put(bad)
    await clock.advance(3100)
    expect((await board($)).line, `malformed (${bad}): shown`).toContain('PR #1201')
  }
  fx.put('{ nope')
  expect((await command($, 'off')).text).toContain('could not save')
  expect(fx.files[fx.path]).toBe('{ nope')
})

test('toggling keeps every other key in the switch file', async ($, on) => {
  const fx = switchFiles('/home/me', { 'cache-clock:hidden': true, extra: { a: 1 } })
  const clock = engine(on, world(), fx)
  await start($)
  await clock.settle()
  await command($, 'off')
  await command($, 'hide')
  expect(fx.json()).toEqual({ 'cache-clock:hidden': true, extra: { a: 1 }, 'gate-board': false, 'gate-board:hidden': true })
  await command($, 'on')
  expect(fx.json()).toEqual({ 'cache-clock:hidden': true, extra: { a: 1 } })
  await command($, 'hide')
  await command($, 'show')
  expect(fx.json()).toEqual({ 'cache-clock:hidden': true, extra: { a: 1 } })
  expect(fx.clean()).toBe(true)
})

// Consumer layout: gh may be missing or signed out (exit 4 with a "gh auth login"
// hint), and the repo may keep no kanban board. Either way: nothing wrong on screen.
test('consumer: gh signed out draws nothing, leaves the other line, and the command says why', async ($, on) => {
  const w = world({ pr: null })
  const clock = engine(on, w)
  await start($)
  await clock.settle()
  const { line, texts } = await board($)

  expect(line).toBeUndefined()
  expect(texts).toContain('other mod line')
  expect((await command($)).text).toContain('gh is not signed in')
})

test('consumer: gh signing out mid-session keeps the last reading for a few minutes, then drops it', async ($, on) => {
  const w = world()
  const clock = engine(on, w)
  await start($)
  await clock.settle()
  expect((await board($)).line).toContain('PR #1201')

  w.pr = null
  await clock.advance(120_000)
  expect((await board($)).line).toContain('PR #1201')
  await clock.advance(5 * 60_000)
  expect((await board($)).line).toBeUndefined()
})

test('consumer: a repo with no kanban board shows the gates without a sweep segment', async ($, on) => {
  const w = world()
  w.board = { backlog: [] }
  const clock = engine(on, w)
  await start($)
  await clock.settle()
  const { line } = await board($)

  expect(line).toContain('PR #1201')
  expect(line).not.toContain('sweep')
})

test('consumer: a PR no gate bot has reviewed reads pending, never approved', async ($, on) => {
  const w = world()
  w.pr = { ...(w.pr as object), reviews: [review('some-human', 'APPROVED')] }
  const clock = engine(on, w)
  await start($)
  await clock.settle()
  const { line } = await board($)

  expect(line).toContain('test ⟳ · review ⟳')
  expect(line).not.toContain('✓ ·')
})
