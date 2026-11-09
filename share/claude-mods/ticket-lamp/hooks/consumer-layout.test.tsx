import { expect, mock, test } from 'claude-code/testing'

// Consumer layout (a tap install): the team registry is where AITEAMFORGE_CONFIG
// says, not necessarily ~/.aiteamforge/team-paths.json, and the launcher is
// kb-run (the tap template has no kb-run-ux, so a UX role never appears).
const BAND = {
  plugin: 'ticket-lamp',
  component: 'AbovePrompt',
  props: { hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: 160, scroll: { offset: 0, bodyRows: 10 }, view: {} },
} as const
const CONFIG = '/srv/forge/team-paths.json'
const BOARD = '/home/me/acme/kanban/acme-board.json'
const TEAMS = { teams: { acme: { kanban_dir: '/home/me/acme/kanban', team_code: 'ACME' } } }
const out = (exitCode: number, stdout: string) => ({
  value: { exitCode, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false },
})

test('consumer: AITEAMFORGE_CONFIG is honoured and a kb-run session shows its ticket from the tap board', async ($, on) => {
  const clock = mock.clock(on, { now: 1_000_000 })
  mock.store(on)
  mock.env(on, { HOME: '/home/me', AITEAMFORGE_CONFIG: CONFIG, CC_SESSION_NAME: 'XACME-0100: Ship it' })
  const read: string[] = []
  const jq: string[][] = []
  on('command.register', () => ({ value: { command: 'ticket' } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('session.id', () => ({ value: 'sess-1' }))
  on('fs.read', (_, e) => {
    read.push(e.path)
    if (e.path !== CONFIG) throw new Error('ENOENT')

    return { value: JSON.stringify(TEAMS) }
  })
  on('fs.list', () => ({ value: [{ name: 'acme-board.json', kind: 'file' as const, size: 1, mtimeMs: 1, isLink: false }] }))
  on('process.run', (_, e) => {
    if (e.argv[0] !== 'jq') return out(127, '')
    jq.push([...e.argv])

    return out(0, JSON.stringify({ found: true, kind: 'ticket', title: 'Ship it', status: 'in_progress', subs: [], release: null, epic: null, prMerged: null }))
  })
  on('ui.render', { component: 'AbovePrompt' }, ($, e) => {
    const { Text } = $.ui.resolve(e)

    return <Text>other mod line</Text>
  })

  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  await clock.settle()
  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
  const texts = (await ui.findAll({ type: 'Text' })).map(t => t.text)
  await ui.unmount()

  expect(read).toContain(CONFIG)
  expect(read).not.toContain('/home/me/.aiteamforge/team-paths.json')
  expect(jq[0]?.at(-1)).toBe(BOARD)
  expect(texts.some(t => t.includes('XACME-0100'))).toBe(true)
})
