import { expect, mock, test } from 'claude-code/testing'
import type { Engine, TestBody } from 'claude-code/testing'

// Consumer layout (a tap install): the module keeps per-process caches, so each
// file runs in its own child; the working layout is in consumer-layout.test.tsx.
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

function engine(on: On, files: Record<string, string>, jqExit: number) {
  const clock = mock.clock(on, { now: 1_000_000 })
  mock.store(on)
  mock.env(on, { HOME: '/home/me', CC_SESSION_NAME: 'XACME-0100: Ship it' })
  on('command.register', () => ({ value: { command: 'ticket' } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('session.id', () => ({ value: 'sess-1' }))
  on('fs.read', (_, e) => {
    const text = files[e.path]
    if (text === undefined) throw new Error('ENOENT')

    return { value: text }
  })
  on('fs.list', () => ({ value: [{ name: 'acme-board.json', kind: 'file' as const, size: 1, mtimeMs: 1, isLink: false }] }))
  on('process.run', (_, e) => (e.argv[0] === 'jq' ? out(jqExit, '') : out(127, '')))
  on('ui.render', { component: 'AbovePrompt' }, ($, e) => {
    const { Text } = $.ui.resolve(e)

    return <Text>other mod line</Text>
  })

  return clock
}

async function line($: Engine) {
  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
  const texts = (await ui.findAll({ type: 'Text' })).map(t => t.text)
  await ui.unmount()

  return { texts, ticket: texts.find(t => t.includes('XACME-0100')) }
}

const start = ($: Engine) => $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })

test('consumer: no team-paths.json draws nothing and the command says the ticket is not on any board', async ($, on) => {
  const clock = engine(on, {}, 0)
  await start($)
  await clock.settle()
  const { texts, ticket } = await line($)

  expect(ticket).toBeUndefined()
  expect(texts).toContain('other mod line')
  const r = await $.command.run({ command: 'ticket', args: '', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 200 } })
  expect(r.text).toContain('not found on any board')
})

test('consumer: jq missing or failing draws nothing, never an empty ticket', async ($, on) => {
  const clock = engine(on, { [CONFIG]: JSON.stringify(TEAMS) }, 127)
  await start($)
  await clock.settle()
  const { texts, ticket } = await line($)

  expect(ticket).toBeUndefined()
  expect(texts).toContain('other mod line')
})
