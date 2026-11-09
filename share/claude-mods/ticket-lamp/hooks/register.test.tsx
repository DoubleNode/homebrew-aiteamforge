import { expect, test } from 'claude-code/testing'

import { ROLE_COLOR, follow, fromLaunch, keepTrail, parentId, priorIds, releaseVerdict, tally, ticketVerdict, workedOn } from './register'
import type { ReleaseView, Sub, TicketView } from '../types'

const sub = (status: string): Sub => ({ id: 'X', title: 't', status })
const ticket = (status: string, subs: Sub[]): TicketView => ({
  kind: 'ticket', title: 't', status, subs, release: null, epic: null, prMerged: null,
})
const release = (over: Partial<ReleaseView>): ReleaseView => ({
  kind: 'release', name: 'R02', short: 'R02', status: 'in_progress', stage: 'PLANNED', platforms: ['other:PLANNED'],
  version: '1.30.0', target: '', branch: '', tickets: { completed: 3, cancelled: 0, total: 51 }, open: [], archived: false,
  ...over,
})

test('ids: subitem ids collapse to the parent, releases win over their digits', async () => {
  expect(parentId('XACA-1739-004')).toBe('XACA-1739')
  expect(parentId('feature/XACA-0926-kbmsg')).toBe('XACA-0926')
  expect(parentId('REL-2026-Q4-053')).toBe('REL-2026-Q4-053')
  expect(parentId('rel-van-v10'.toUpperCase())).toBe('REL-VAN-V10')
  expect(parentId('REL-XFAS-001')).toBe('REL-XFAS-001')
  expect(parentId('develop')).toBe(null)
})

test('every kb-* launcher spelling of CC_SESSION_NAME is a ticket session', async () => {
  // kb-run / kb-work
  expect(fromLaunch('XACA-1739: Bugfix: retro gate')).toEqual({ id: 'XACA-1739', source: 'launch', role: null })
  // kb-run-review / -test / -ux, kb-debug
  expect(fromLaunch('[Review] XACA-1739: t')?.role).toBe('Review')
  expect(fromLaunch('[Test] XFIR-0247: t')).toEqual({ id: 'XFIR-0247', source: 'launch', role: 'Test' })
  expect(fromLaunch('[UX] XACA-1739: t')?.role).toBe('UX')
  expect(fromLaunch('[Debug] XACA-1739: t')?.role).toBe('Debug')
  // kb-run <REL-ID>; the release id must not be cut down to "REL-2026"
  expect(fromLaunch('REL-2026-Q4-053: Academy R02 2026-11-20')?.id).toBe('REL-2026-Q4-053')
  expect(fromLaunch('REL-2026-Q4-053: release')?.id).toBe('REL-2026-Q4-053')
  // Freelance boards name releases per project; kb-run takes any REL-*.
  expect(fromLaunch('REL-VAN-V10: Caravan 1.0')?.id).toBe('REL-VAN-V10')
  expect(fromLaunch('REL-XFAS-001: AwaySentry')?.id).toBe('REL-XFAS-001')
  expect(fromLaunch('[Test] REL-VAN-V10: t')).toEqual({ id: 'REL-VAN-V10', source: 'launch', role: 'Test' })
})

test('a session nothing launched, or named some other way, is not a ticket session', async () => {
  expect(fromLaunch(null)).toBe(null)
  expect(fromLaunch('')).toBe(null)
  expect(fromLaunch('academy-chancellor')).toBe(null)
  // The id must lead: a title that merely mentions one does not count.
  expect(fromLaunch('notes on XACA-1739: later')).toBe(null)
  expect(fromLaunch('[Chore] XACA-1739: t')).toBe(null)
})

test('the commands that move a session onto a ticket, and the ones that do not', async () => {
  expect(workedOn('source ~/aiteamforge/kanban-helpers.sh && kb-backlog sub start XACA-1764-002')).toBe('XACA-1764')
  expect(workedOn('kb-backlog sub done XACA-1764-005')).toBe('XACA-1764')
  expect(workedOn('kb-pick XACA-1527')).toBe('XACA-1527')
  expect(workedOn('kb-done XACA-1708')).toBe('XACA-1708')
  expect(workedOn("zsh -i -l -c 'kb-backlog sub start \"XFIR-0247-001\"'")).toBe('XFIR-0247')
  // Several in one command: the last one named is where the session went.
  expect(workedOn('kb-backlog sub done XACA-1700-011 && kb-done XACA-1700 && kb-pick XACA-1764')).toBe('XACA-1764')
  // Reading, adding to or tidying another ticket is not working on it.
  expect(workedOn('kb-backlog show XACA-1764')).toBe(null)
  expect(workedOn('kb-backlog sub add XACA-1763 "Persist per-host reasons"')).toBe(null)
  expect(workedOn('kb-backlog sub cancel XACA-1763-012 --reason "moved"')).toBe(null)
  expect(workedOn('kb-sweep XACA-1764')).toBe(null)
  expect(workedOn('kb-done')).toBe(null)
  expect(workedOn('grep -n "kb-pick" kanban-helpers.sh')).toBe(null)
})

test('the trail starts at the launched ticket, keeps each ticket once, newest last', async () => {
  expect(follow([], 'XACA-0002', 'XACA-0001')).toEqual(['XACA-0001', 'XACA-0002'])
  // No launch ticket (a pinned or plain session that picked one up).
  expect(follow([], 'XACA-0002', null)).toEqual(['XACA-0002'])
  // Touching the launch ticket first changes nothing visible.
  expect(follow([], 'XACA-0001', 'XACA-0001')).toEqual(['XACA-0001'])
  // Going back to an earlier ticket moves it to the end, never duplicated.
  expect(follow(['XACA-0001', 'XACA-0002'], 'XACA-0001', 'XACA-0001')).toEqual(['XACA-0002', 'XACA-0001'])
  expect(priorIds(['XACA-0001', 'XACA-0002', 'XACA-0003'], 'XACA-0003')).toEqual(['XACA-0001', 'XACA-0002'])
  expect(priorIds(['XACA-0001'], 'XACA-0001')).toEqual([])
})

test('saved trails keep only the most recent sessions', async () => {
  const all = keepTrail(keepTrail({}, 's1', ['A-0001'], 1, 2), 's2', ['A-0002'], 2, 2)
  expect(Object.keys(keepTrail(all, 's3', ['A-0003'], 3, 2)).sort()).toEqual(['s2', 's3'])
  // Re-saving a session updates it in place rather than adding a second entry.
  expect(keepTrail(all, 's1', ['A-0001', 'A-0004'], 5, 2).s1?.trail).toEqual(['A-0001', 'A-0004'])
})

test('the line draws earlier tickets before the current one: done struck green, cancelled struck red, open amber', async ($, on) => {
  const current = {
    kind: 'ticket', title: 'Current', status: 'in_progress', subs: [], release: null, epic: null, prMerged: null,
    id: 'XACA-0004', source: 'followed', role: null, found: true, key: 'k', checkedAt: 0,
    prior: [
      { id: 'XACA-0001', status: 'completed' },
      { id: 'XACA-0002', status: 'cancelled' },
      { id: 'XACA-0003', status: 'in_progress' },
    ],
  }
  on('state.get', (_, e, next) =>
    e.key === 'view' ? { value: { value: { shape: 'view-3', value: current }, version: 1 } } : next(e),
  )
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)

    return <Text>prompt</Text>
  })

  const ui = await $.ui.mount({
    plugin: 'ticket-lamp', component: 'AbovePrompt', surface: 'terminal',
    props: { hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: 160, scroll: { offset: 0, bodyRows: 10 }, view: {} },
  })
  const done = await ui.find({ type: 'Text', text: /^XACA-0001$/ })
  expect(done?.props.strikethrough).toBe(true)
  expect(done?.props.color).toBe('success')
  const dropped = await ui.find({ type: 'Text', text: /^XACA-0002$/ })
  expect(dropped?.props.strikethrough).toBe(true)
  expect(dropped?.props.color).toBe('error')
  const open = await ui.find({ type: 'Text', text: /^XACA-0003$/ })
  expect(open?.props.strikethrough).toBe(undefined)
  expect(open?.props.color).toBe('warning')
  // XACA-1605-023: each state has its own non-colour cue (done, cancelled and open differ in text).
  const cues = [await ui.find({ type: 'Text', text: /^✓$/ }), await ui.find({ type: 'Text', text: /^✗$/ }), await ui.find({ type: 'Text', text: /^!$/ })]
  for (const c of cues) expect(c).toBeDefined()
  // Order on the line: earlier tickets, the separator, then the current ticket.
  expect((await ui.find({ type: 'Text', text: /✓XACA-0001 ✗XACA-0002 !XACA-0003 › XACA-0004/ }))).not.toBe(undefined)
  await ui.unmount()
})

test('a ticket is DONE only when closed with nothing open under it', async () => {
  expect(ticketVerdict(ticket('completed', [sub('completed'), sub('cancelled')])).text).toBe('DONE ✓')
  expect(ticketVerdict(ticket('completed', [sub('completed'), sub('todo')])).text).toBe('completed · 1 open!')
  expect(ticketVerdict(ticket('in_progress', [sub('completed')])).text).toContain('run kb-done')
  expect(ticketVerdict(ticket('todo', [sub('todo')])).text).toBe('todo')
  expect(tally([sub('completed'), sub('cancelled'), sub('in_progress')]).resolved).toBe(2)
})

test('a release reads shipped, ready to promote, or its stage', async () => {
  expect(releaseVerdict(release({ status: 'released', stage: 'PROD' })).text).toBe('released ✓ PROD')
  expect(releaseVerdict(release({ archived: true })).text).toBe('archived ✓')
  expect(releaseVerdict(release({ tickets: { completed: 7, cancelled: 0, total: 7 } })).text).toContain('tickets done')
  // Cancelled tickets leave the denominator.
  expect(releaseVerdict(release({ tickets: { completed: 7, cancelled: 2, total: 9 } })).text).toContain('tickets done')
  expect(releaseVerdict(release({})).text).toBe('PLANNED')
  // REL-VAN-V10 on M4Mini: no single stage, platforms apart.
  const split = releaseVerdict(release({ stage: '', platforms: ['ios:DEV', 'android:PLANNED', 'web:PLANNED'] }))
  expect(split.text).toBe('ios:DEV android:PLANNED web:PLANNED')
  expect(split.color).not.toBe('')
  expect(releaseVerdict(release({ stage: '', platforms: ['ios:PLANNED', 'android:PLANNED'] })).color).toBe('')
})

// XACA-1605-033: the role word is foreground-only text, so it takes an engine theme key
// (follows the person's theme, keeps contrast on light and dark), never a raw hex.
test('every role colour is a theme key, distinct per role, never a raw hex', async () => {
  const allowed = new Set(['text', 'inactive', 'subtle', 'suggestion', 'remember', 'success', 'error', 'warning', 'merged', 'claude', 'permission', 'planMode', 'autoAccept', 'ide'])
  const roles = ['Review', 'Test', 'UX', 'Debug'] as const
  for (const r of roles) {
    expect(ROLE_COLOR[r]).not.toMatch(/^#/)
    expect(allowed.has(ROLE_COLOR[r])).toBe(true)
  }
  expect(new Set(roles.map(r => ROLE_COLOR[r])).size).toBe(roles.length)
})

// XACA-1605-037: success/warning/error mean DONE/AMBER/RED verdicts in the same band; an identity
// colour (a role) must never borrow one of them.
test('role colours never use a status key', async () => {
  for (const r of ['Review', 'Test', 'UX', 'Debug'] as const) expect(['success', 'warning', 'error']).not.toContain(ROLE_COLOR[r])
})
