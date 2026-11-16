import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { FinishedTicket, Lane, LaneCurrent, Prior, ReleaseView, Role, Source, Sub, TicketView, View } from '../types'
import { createSwitch } from './switches'
import type { SwitchIo } from './switches'

const POLL_MS = 120_000
const MIN_GAP_MS = 20_000
const TICKET_CHIP = { text: ' ▣ TICKET ', color: '#0b0b0f', bg: '#38bdf8' }
const RELEASE_CHIP = { text: ' ⬢ RELEASE ', color: '#0b0b0f', bg: '#f472b6' }
export const ROLE_COLOR: Record<NonNullable<Role>, string> = { Review: 'permission', Test: 'ide', UX: 'suggestion', Debug: 'merged' }
const GREEN = 'success'
const AMBER = 'warning'
const RED = 'error'
const BLUE = 'suggestion'
const RESOLVED = new Set(['completed', 'cancelled'])
const TICKET_ID = /\b([A-Z]{2,6}-\d{3,5})(?:-\d+)?\b/
// kb-run treats any "REL-*" as a release. Shapes seen on the fleet (2026-11-03):
// REL-2026-Q4-053 (dated), REL-VAN-V10 (freelance project), REL-XFAS-001.
const RELEASE_ID = /\b(REL-[A-Z0-9]+(?:-[A-Z0-9]+)*)\b/
// What kb-run & co. export before launching cc:
//   "XACA-1739: <title>"  "[Review] XACA-1739: <title>"  "REL-2026-Q4-053: <name>"
const LAUNCH = /^\s*(?:\[(Review|Test|UX|Debug)\]\s+)?((?:REL-[A-Z0-9]+(?:-[A-Z0-9]+)*)|(?:[A-Z]{2,6}-\d{3,5})):/
// The commands that mean "this session is now working on <ticket>". Read-only
// ones (show, list, sub add, sweep) and housekeeping cancels deliberately do not count.
const WORK = /\bkb-(?:backlog\s+sub\s+(?:start|done)|pick|done)\s+(?:--?[\w-]+\s+)*["']?([A-Z]{2,6}-\d{3,5})(?:-\d+)?\b/g

const view = atom({ plugin: 'ticket-lamp', key: 'view' } as const, null, { shape: 'view-3' })
// On/off and shown/hidden live in the shared switch file (hooks/switches.ts), read by every chat.
const sw = createSwitch('ticket-lamp')

// BEGIN switch-io (identical in every mod; tests/test-claude-mods-switches-sync.sh keeps it so)
const switchIo = ($: EngineInterface): SwitchIo => ({
  exists: path => $.fs.exists(path),
  read: path => $.fs.read(path),
  write: (path, text) => $.fs.write(path, text),
  run: argv => $.process.run(argv, { timeoutMs: 5000 }),
  home: () => $.env.get('HOME'),
  every: (ms, fn) => $.clock.every(ms, fn),
  root: $.plugin.root,
})
// END switch-io
const pinned = atom({ plugin: 'ticket-lamp', key: 'pinned' } as const, null)
const followed = atom({ plugin: 'ticket-lamp', key: 'followed' } as const, [] as string[])

const HELP = [
  '/ticket              this ticket or release in full',
  '/ticket <ID>         pin the line to a ticket (XACA-1739) or release (REL-2026-Q4-053)',
  '/ticket auto         unpin: back to the session kb-run / kb-work launched',
  '/ticket on|off       turn the lamp on or off in every chat (remembered)',
  '/ticket hide|show    hide the line but keep following, or show it again',
  '/ticket help         this text',
  'Shown in sessions started by kb-run, kb-work, kb-run-test/review/ux or kb-debug',
  '(read from the CC_SESSION_NAME they export), or when pinned.',
  'When the session moves on to another ticket (kb-pick, kb-backlog sub start|done, kb-done <ID>)',
  'the line follows it; earlier tickets stay at the front: green struck-through = completed,',
  'red struck-through = cancelled, amber = left open. A release session stays on its release.',
].join('\n')

// jq does the 19 MB parse out of process and hands back one small object.
const TICKET_FILTER = `. as $b
| ([$b.backlog[]? | select(.id == $id)] | first) as $i
| if $i == null then {found: false}
  else (($i.releaseAssignment // {}).releaseId) as $r | ($i.epicId) as $e
  | { found: true, kind: "ticket", title: ($i.title // ""), status: ($i.status // "todo"),
      subs: [($i.subitems // [])[] | {id: (.id // ""), title: (.title // ""), status: (.status // "todo")}],
      release: (if $r == null then null else ([$b.releases[]? | select(.id == $r)
        | {id, name: (.name // ""), short: (.shortTitle // ""), target: (.targetDate // "")}] | first)
        // {id: $r, name: "", short: "", target: ""} end),
      epic: (if $e == null then null else ([$b.epics[]? | select(.id == $e)
        | {id, title: (.title // ""), short: (.shortTitle // "")}] | first) // {id: $e, title: "", short: ""} end),
      prMerged: (($i.prMerged // {}).pr // null) }
  end`

// Lane lines (XACA-1786): the SAME pass also reads release.orchestration, the summary the release orchestrator writes
// (kanban-hooks/release_orchestrator.py: lanes[], maxParallel, activeRunId, closedAt, items{}) and the token block
// (orchestrator_tokens.py). Nothing here may raise: a jq error would hide the whole release line, so every piece that
// reads orchestration is wrapped and falls back to "no lanes" / "tok ?". lanes is null when the block is malformed.
const RELEASE_FILTER = `. as $b
| ([$b.releases[]? | select(.id == $id)] | first) as $r
| if $r == null then {found: false}
  else [$b.backlog[]? | select((.releaseAssignment // {}).releaseId == $id)] as $items
  | ($r.orchestration | if type == "object" then . else {} end) as $o
  | ($o.tokens) as $t
  | ($o.activeRunId | type == "string" and length > 0) as $hasRun
  | ($hasRun and (($o.closedAt // null) == null or $o.closedAt == false or $o.closedAt == "")) as $active
  | ($o.maxParallel | if type == "number" and . >= 1 and . == floor then . else 2 end) as $mp
  | def num: type == "number" and . >= 0;
    def blk($x): if ($x | type) == "object" and ([$x.input, $x.cacheCreate, $x.cacheRead, $x.output] | all(num))
      then {total: ($x.input + $x.cacheCreate + $x.cacheRead + $x.output), cacheRead: $x.cacheRead} else "?" end;
    def tok($i): if $t == null or ($i | type) != "string" then null
      elif ($t | type) != "object" or ($t.perItem | type) != "object" then "?"
      elif ($t.perItem | has($i) | not) then null
      else blk($t.perItem[$i]) end;
    def item($i): [$b.backlog[]? | select(.id == $i)] | first;
    def title($i): (item($i) | (.title // "") | if type == "string" then . else "" end);
    def subs($i): (item($i) | (.subitems // []) | if type == "array" then [.[] | objects] else [] end);
    def badcur: {id: null, status: null, stage: null, prNumber: null, title: "", subsDone: 0, subsTotal: 0, tokens: null};
    def str: if type == "string" then . else null end;
    def lane_no($k): (.lane | if type == "number" and . >= 1 and . == floor then . else null end) // ($k + 1);
    { found: true, kind: "release", name: ($r.name // ""), short: ($r.shortTitle // ""),
      status: ($r.status // ""), stage: ($r.stage // ""),
      platforms: [($r.platforms // {}) | to_entries[] | "\\(.key):\\(.value.environment // "PLANNED")"],
      version: ([($r.platforms // {})[] | .version // empty] | first // ""),
      target: ($r.targetDate // ""), branch: ($r.branch // ""), archived: false,
      tickets: { completed: ([$items[] | select(.status == "completed")] | length),
                 cancelled: ([$items[] | select(.status == "cancelled")] | length),
                 total: ($items | length) },
      open: [$items[] | select((.status // "todo") as $s | ($s != "completed" and $s != "cancelled"))
             | {id, title: (.title // ""), status: (.status // "todo")}] | .[:12],
      runActive: $active, maxParallel: $mp,
      runTok: (try (if $t == null then null elif ($t | type) != "object" then "?" else blk($t.run) end) catch "?"),
      lanes: (if ($active | not) then [] else (try (
        if ($o.lanes | type) != "array" then null
        else [$o.lanes | to_entries[] | select(.value | type == "object") | .key as $k | .value
              | {no: lane_no($k), e: .}]
          | group_by(.no) | map(.[0]) | map(select(.e.current != null or .no <= $mp))
          | map(.e as $e | {lane: .no, since: ($e.since | str),
              current: ($e.current as $c
                | if ($e | has("current") | not) or (($c | type) != "null" and ($c | type) != "object") then badcur
                  elif $c == null then null
                  else ($c.id | str) as $cid
                    | {id: $cid, status: ($c.status | str), stage: ($c.stage | str),
                       prNumber: ($c.prNumber | if type == "number" then . else null end),
                       title: title($cid), subsTotal: (subs($cid) | length),
                       subsDone: ([subs($cid)[] | select(.status == "completed" or .status == "cancelled")] | length),
                       tokens: tok($cid)} end),
              queueLen: ([($e.queue | if type == "array" then . else [] end)[] | strings] | length),
              queue: [($e.queue | if type == "array" then . else [] end)[] | strings | {id: ., title: title(.)}] | .[:40]})
        end) catch null) end),
      finished: (try ([($o.items | if type == "object" then . else {} end) | to_entries[]
                 | select((.value | type) == "object" and (.value.state == "DONE" or .value.state == "CANCELLED"))
                 | {id: .key, state: .value.state, title: title(.key), tokens: tok(.key)}] | sort_by(.id) | .[:40]) catch []) }
  end`

type Teams = Record<string, { kanban_dir?: string; team_code?: string }>
type Found = (TicketView | ReleaseView) & { found: boolean }
type Pick = { id: string; source: Source; role: Role }

export function parentId(text: string): string | null {
  return RELEASE_ID.exec(text)?.[1] ?? TICKET_ID.exec(text)?.[1] ?? null
}

export const isRelease = (id: string) => id.startsWith('REL-')

// CC_SESSION_NAME -> the launched subject; anything else is not a ticket session.
export function fromLaunch(name: string | null | undefined): Pick | null {
  const m = LAUNCH.exec(name ?? '')
  if (m?.[2] === undefined) return null

  return { id: m[2], source: 'launch', role: (m[1] as Role | undefined) ?? null }
}

// The ticket a Bash command starts or advances work on: the LAST one it names, so
// "kb-backlog sub done X-0001-009 && kb-pick X-0002" lands on X-0002. null when it names none.
export function workedOn(command: string): string | null {
  let last: string | null = null
  for (const m of command.matchAll(WORK)) last = m[1] ?? last

  return last
}

// The session's ticket trail after it touches <id>: the launch ticket first (when
// there was one), each ticket once, most recent last.
export function follow(trail: readonly string[], id: string, launchedTicket: string | null): string[] {
  const seed = trail.length === 0 && launchedTicket !== null ? [launchedTicket] : [...trail]

  return [...seed.filter(x => x !== id), id]
}

// Earlier tickets for the line: the trail without the current one, oldest first.
export function priorIds(trail: readonly string[], current: string): string[] {
  return trail.filter(x => x !== current)
}

export function tally(subs: readonly Sub[]): { resolved: number; total: number; next: Sub | null } {
  const open = subs.filter(s => !RESOLVED.has(s.status))

  return { resolved: subs.length - open.length, total: subs.length, next: open[0] ?? null }
}

// "Are we done here?" for a ticket: the item is closed and nothing under it is open.
export function ticketVerdict(t: TicketView): { text: string; color: string } {
  const { resolved, total } = tally(t.subs)
  if (t.status === 'completed' && resolved === total) return { text: 'DONE ✓', color: GREEN }
  if (t.status === 'completed') return { text: `completed · ${total - resolved} open!`, color: AMBER }
  if (t.status === 'cancelled') return { text: 'cancelled', color: RED }
  if (t.status === 'blocked') return { text: 'blocked', color: RED }
  if (total > 0 && resolved === total) return { text: `${t.status} · all subs resolved, run kb-done`, color: AMBER }

  return { text: t.status, color: t.status === 'in_progress' ? BLUE : '' }
}

// For a release: shipped, or where it stands and what is left.
export function releaseVerdict(r: ReleaseView): { text: string; color: string } {
  const { completed, cancelled, total } = r.tickets
  const deliverable = total - cancelled
  if (r.archived) return { text: 'archived ✓', color: GREEN }
  if (r.status === 'released') return { text: `released ✓ ${r.stage || 'PROD'}`, color: GREEN }
  // No single stage on a multi-platform release: say where each platform is
  // ("ios:DEV android:PLANNED") rather than flattening it to PLANNED.
  const perPlatform = r.platforms.length > 1 ? r.platforms.join(' ') : ''
  const stage = r.stage || (r.platforms.length === 1 ? (r.platforms[0]?.split(':')[1] ?? '') : perPlatform) || 'PLANNED'
  const isPlanned = r.platforms.length > 1 && !r.stage ? r.platforms.every(p => p.endsWith(':PLANNED')) : stage === 'PLANNED'
  if (deliverable > 0 && completed === deliverable) return { text: `${stage} · tickets done, promote/close out`, color: AMBER }

  return { text: stage, color: isPlanned ? '' : BLUE }
}

// ---- lane lines (XACA-1786) ------------------------------------------------------------------------------------------
// release_orchestrator.STATE_STAGE, status -> stage. A copy: tests/lanes.test.tsx checks it against the stage vocabulary the
// REAL writer produced into tests/lanes.fixture.json, so a new or renamed stage fails the suite instead of drifting.
export const LANE_STAGE: Record<string, string> = {
  QUEUED: 'queued', DISPATCHING: 'dispatching', RUNNING: 'coding', QUESTION_PENDING: 'question', IN_REVIEW: 'review',
  MERGED_PENDING_DONE: 'merged', DONE: 'done', FAILED: 'failed', CRASHED: 'crashed', STALLED: 'stalled',
  CANCELLED: 'cancelled', UNKNOWN: 'unknown',
}
// The fallback for anything not understood. Dim, never green, never a check mark.
const LANE_UNKNOWN = { text: '?', color: '' }
const isObj = (x: unknown): x is Record<string, unknown> => x !== null && typeof x === 'object' && !Array.isArray(x)
const isCount = (x: unknown): x is number => typeof x === 'number' && Number.isInteger(x) && x >= 0

// One lane's verdict, keyed on the current ticket's stage with its status as a cross-check. Every state carries a word or
// glyph, so colour is never the only signal. Unknown, unrecognised, mismatched or malformed input is a dim "?".
export function laneVerdict(lane: unknown): { text: string; color: string } {
  if (!isObj(lane)) return LANE_UNKNOWN
  const cur = lane.current
  if (cur === null) return { text: 'idle', color: '' }
  if (!isObj(cur)) return LANE_UNKNOWN
  const { status, stage, prNumber } = cur
  if (typeof status !== 'string' || typeof stage !== 'string') return LANE_UNKNOWN
  if (!Object.prototype.hasOwnProperty.call(LANE_STAGE, status) || LANE_STAGE[status] !== stage) return LANE_UNKNOWN
  switch (stage) {
    case 'coding': return { text: 'implementing', color: BLUE }
    case 'review': return { text: typeof prNumber === 'number' && prNumber > 0 ? `PR #${prNumber} gates` : 'in review', color: BLUE }
    case 'merged': return { text: 'merged ✓', color: GREEN }
    case 'done': return { text: 'done ✓', color: GREEN }
    case 'question': return { text: 'question !', color: AMBER }
    case 'stalled': return { text: 'stalled !', color: AMBER }
    case 'crashed': return { text: 'crashed ✗', color: RED }
    case 'failed': return { text: 'failed ✗', color: RED }
    case 'queued':
    case 'dispatching': return { text: 'dispatching…', color: '' }
    case 'cancelled': return { text: 'cancelled –', color: '' }
    default: return LANE_UNKNOWN
  }
}

// 1234 -> "1.2k", 1206200 -> "1.2M". Whole numbers below 1000.
export function fmtTokens(n: number): string {
  const sizes = [1, 1e3, 1e6, 1e9]
  const names = ['', 'k', 'M', 'B']
  let i = n >= 1e9 ? 3 : n >= 1e6 ? 2 : n >= 1e3 ? 1 : 0
  if (i < 3 && Math.round(n / (sizes[i] ?? 1)) >= 1000) i += 1
  if (i === 0) return String(Math.round(n))
  const v = n / (sizes[i] ?? 1)

  return `${v >= 100 ? Math.round(v) : Math.round(v * 10) / 10}${names[i] ?? ''}`
}

// The token figure for a ticket. null = show nothing (no block, or the ticket is not in it); a malformed block is "tok ?",
// never 0. Reads the jq pass's {total, cacheRead} or "?".
export function tokenText(t: unknown): string | null {
  if (t === null || t === undefined) return null
  if (isObj(t) && typeof t.total === 'number' && Number.isFinite(t.total) && t.total >= 0) return `${fmtTokens(t.total)} tok`

  return 'tok ?'
}

// cacheRead / total, whole percent; null when it cannot be told (malformed, or nothing sent yet: no division by zero).
export function cacheShare(t: unknown): number | null {
  if (!isObj(t) || typeof t.total !== 'number' || typeof t.cacheRead !== 'number') return null
  if (!(t.total > 0) || !(t.cacheRead >= 0) || t.cacheRead > t.total) return null

  return Math.round((t.cacheRead / t.total) * 100)
}

// "1.2M tok · 98% cache-read" for /ticket.
export function tokenDetail(t: unknown): string {
  const text = tokenText(t)
  if (text === null) return 'tokens —'
  const share = cacheShare(t)

  return share === null ? text : `${text} · ${share}% cache-read`
}

const laneNo = (l: Lane, i: number) => (isCount(l.lane) && l.lane >= 1 ? l.lane : i + 1)

// The lanes to draw, mirroring release_orchestrator.lanes_view: only for an active run, only objects, ordered by lane number.
// An OCCUPIED lane (current not null) is always drawn, at any lane number: the writer keeps it above maxParallel and a
// stalled, crashed or failed ticket is exactly the one a human must see. An EMPTY lane is drawn only when numbered
// 1..maxParallel (2 when that is not a count >= 1). The cap is on lane number and occupancy, never on array position.
export function laneList(v: Pick<ReleaseView, 'runActive' | 'lanes' | 'maxParallel'>): Lane[] {
  if (v.runActive !== true || !Array.isArray(v.lanes)) return []
  const cap = isCount(v.maxParallel) && v.maxParallel >= 1 ? v.maxParallel : 2

  return v.lanes
    .flatMap((l, i) => (isObj(l) ? [{ ...(l as Lane), lane: laneNo(l as Lane, i) }] : []))
    .filter(l => (l.current !== null && l.current !== undefined) || l.lane <= cap)
    .sort((a, b) => a.lane - b.lane)
}
const laneCurrent = (l: Lane): LaneCurrent | null => (isObj(l.current) ? (l.current as LaneCurrent) : null)

async function run($: EngineInterface, argv: string[], timeoutMs = 20_000): Promise<string | null> {
  const ran = await $.process.run(argv, { timeoutMs }).catch(() => null)

  return ran?.exitCode === 0 ? ran.stdout : null
}

async function teams($: EngineInterface, home: string): Promise<Teams> {
  // The tap's kanban helpers honour AITEAMFORGE_CONFIG over the default path; do the same.
  const config = (await $.env.get('AITEAMFORGE_CONFIG')) || `${home}/.aiteamforge/team-paths.json`
  const text = await $.fs.read(config).catch(() => null)
  if (typeof text !== 'string') return {}
  try {
    const parsed = JSON.parse(text) as { teams?: Teams }

    return parsed.teams ?? (parsed as Teams)
  } catch {
    return {}
  }
}

const boardOf = (team: string, dir: string) => `${dir}/${team}-board.json`

async function mtime($: EngineInterface, path: string): Promise<number | null> {
  const dir = path.replace(/\/[^/]+$/, '')
  const name = path.slice(dir.length + 1)
  const entries = await $.fs.list(dir).catch(() => [])

  return entries.find(x => x.name === name)?.mtimeMs ?? null
}

// Which board holds <id>: tickets by team code, releases by a cheap grep over every team's board.
const located = new Map<string, string>()
async function locate($: EngineInterface, all: Teams, id: string): Promise<string | null> {
  const known = located.get(id)
  if (known !== undefined) return known
  const boards = Object.entries(all).flatMap(([team, cfg]) =>
    typeof cfg.kanban_dir === 'string' ? [{ board: boardOf(team, cfg.kanban_dir), code: cfg.team_code?.toUpperCase() }] : [],
  )
  if (!isRelease(id)) {
    const code = id.split('-')[0]?.replace(/^X/, '') ?? ''
    const hit = boards.find(b => b.code === code)?.board ?? null
    if (hit !== null) located.set(id, hit)
    return hit
  }
  for (const { board } of boards) {
    const hit = await $.process.run(['grep', '-qF', `"${id}"`, board], { timeoutMs: 10_000 }).catch(() => null)
    if (hit?.exitCode === 0) {
      located.set(id, board)
      return board
    }
  }
  // Archived: gone from every live board, its manifest kept beside one of them.
  for (const { board } of boards) {
    const dir = board.replace(/\/[^/]+$/, '')
    const entries = await $.fs.list(`${dir}/releases-archive`).catch(() => [])
    if (entries.some(x => x.name === `${id}.json`)) {
      located.set(id, board)
      return board
    }
  }

  return null
}

async function readView($: EngineInterface, board: string, id: string): Promise<Found | null> {
  const filter = isRelease(id) ? RELEASE_FILTER : TICKET_FILTER
  const raw = await run($, ['jq', '-c', '--arg', 'id', id, filter, board])
  if (raw === null) return null
  try {
    const parsed = JSON.parse(raw) as Found
    if (parsed.found || !isRelease(id)) return parsed
  } catch {
    return null
  }
  // Not on the live board: an archived release keeps its manifest beside it.
  const archive = `${board.replace(/\/[^/]+$/, '')}/releases-archive/${id}.json`
  const text = await $.fs.read(archive).catch(() => null)
  if (typeof text !== 'string') return null
  try {
    const r = JSON.parse(text) as { name?: string; shortTitle?: string; status?: string; stage?: string; targetDate?: string }
    return {
      found: true, kind: 'release', name: r.name ?? '', short: r.shortTitle ?? '', status: r.status ?? 'archived',
      stage: r.stage ?? '', platforms: [], version: '', target: r.targetDate ?? '', branch: '',
      tickets: { completed: 0, cancelled: 0, total: 0 }, open: [], archived: true,
      runActive: false, maxParallel: 2, lanes: [], finished: [], runTok: null,
    }
  } catch {
    return null
  }
}

// Status of each earlier ticket, one jq pass per board, in trail order. A ticket no
// board holds any more reads "unknown" rather than being dropped from the line.
async function readPrior($: EngineInterface, all: Teams, ids: readonly string[]): Promise<Prior[]> {
  if (ids.length === 0) return []
  const byBoard = new Map<string, string[]>()
  for (const id of ids) {
    const board = await locate($, all, id)
    if (board !== null) byBoard.set(board, [...(byBoard.get(board) ?? []), id])
  }
  const status = new Map<string, string>()
  for (const [board, list] of byBoard) {
    const raw = await run($, [
      'jq', '-c', '--argjson', 'ids', JSON.stringify(list),
      '[.backlog[]? | select(.id as $x | $ids | index($x)) | {id, status: (.status // "todo")}]', board,
    ])
    if (raw === null) continue
    try {
      for (const p of JSON.parse(raw) as Prior[]) status.set(p.id, p.status)
    } catch {
      // unreadable board: those ids stay "unknown"
    }
  }

  return ids.map(id => ({ id, status: status.get(id) ?? 'unknown' }))
}

let home: string | null = null
// Read once: the launcher's export does not change during a session.
let launched: Pick | null | undefined
// The check in flight, if any. Callers wait on it rather than being dropped:
// a /ticket typed while session.start's first check runs must see its result.
let inFlight: Promise<void> | null = null

async function launchPick($: EngineInterface): Promise<Pick | null> {
  if (launched === undefined) launched = fromLaunch(await $.env.get('CC_SESSION_NAME'))

  return launched
}

async function choose($: EngineInterface): Promise<Pick | null> {
  const pin = await read($, pinned)
  if (pin !== null) return { id: pin, source: 'pinned', role: null }
  const start = await launchPick($)
  // A release session works through many tickets: it stays on its release.
  if (start !== null && isRelease(start.id)) return start
  const current = (await read($, followed)).at(-1)
  if (current !== undefined && current !== start?.id) return { id: current, source: 'followed', role: null }

  return start
}

// $.state lasts one process; a resume (crash, reboot, cc-relaunch) starts a new one.
// The trail is also kept in $.store, per session id, the most recent TRAIL_KEEP sessions.
const TRAIL_KEEP = 40
type Trails = Record<string, { at: number; trail: string[] }>

async function storedTrails($: EngineInterface): Promise<Trails> {
  const raw = await $.store.get('trails')

  return raw !== null && typeof raw === 'object' && !Array.isArray(raw) ? (raw as Trails) : {}
}

export function keepTrail(all: Trails, sid: string, trail: string[], at: number, keep = TRAIL_KEEP): Trails {
  const next: Trails = { ...all, [sid]: { at, trail } }
  const newest = Object.entries(next).sort((a, b) => b[1].at - a[1].at).slice(0, keep)

  return Object.fromEntries(newest)
}

async function restoreTrail($: EngineInterface): Promise<void> {
  if ((await read($, followed)).length > 0) return
  const saved = (await storedTrails($))[await $.session.id()]?.trail
  if (Array.isArray(saved) && saved.every(x => typeof x === 'string') && saved.length > 0) {
    await update($, followed, () => saved)
  }
}

// The session ran a command that works on <id>: make it the current ticket.
async function noteWork($: EngineInterface, id: string): Promise<void> {
  const start = await launchPick($)
  if (start !== null && isRelease(start.id)) return
  const trail = await read($, followed)
  if (trail.at(-1) === id) return
  const next = follow(trail, id, start?.id ?? null)
  await update($, followed, () => next)
  await $.store.set('trails', keepTrail(await storedTrails($), await $.session.id(), next, await $.clock.now()))
  await check($, true)
}

async function check($: EngineInterface, force = false): Promise<void> {
  if (inFlight !== null) {
    await inFlight
    // An unforced caller is satisfied by the check that just ran; a forced one
    // (a pin, /ticket) re-reads, since the board or the pin may have changed.
    if (!force) return
    if (inFlight !== null) return check($, force)
  }
  const job = checkOnce($, force)
  inFlight = job
  try {
    await job
  } finally {
    if (inFlight === job) inFlight = null
  }
}

async function checkOnce($: EngineInterface, force: boolean): Promise<void> {
  {
    const pick = await choose($)
    if (pick === null) {
      await update($, view, () => null)
      return
    }
    home ??= (await $.env.get('HOME')) ?? null
    if (home === null) return
    const all = await teams($, home)
    const board = await locate($, all, pick.id)
    const stamp = board === null ? null : await mtime($, board)
    // A pin shows only what was pinned; otherwise the line carries the session's earlier tickets.
    const earlier = pick.source === 'pinned' || isRelease(pick.id) ? [] : priorIds(await read($, followed), pick.id)
    const key = `${board ?? '-'}@${stamp ?? '-'}|${earlier.join(',')}`
    const prev = await read($, view)
    if (!force && prev !== null && prev.id === pick.id && prev.key === key && prev.source === pick.source) return

    const found = board === null ? null : await readView($, board, pick.id)
    const prior = await readPrior($, all, earlier)
    const at = await $.clock.now()
    const base = { id: pick.id, source: pick.source, role: pick.role, key, checkedAt: at, prior }
    const next: View =
      found !== null && found.found
        ? ({ ...found, ...base } as View)
        : ({ kind: 'ticket', title: '', status: '', subs: [], release: null, epic: null, prMerged: null, found: false, ...base } as View)
    await update($, view, () => next)
  }
}

// The ticket ids laneDetails prints for an active run: each drawn lane's current ticket and the queue entries it lists.
export function runTicketIds(v: ReleaseView): Set<string> {
  const ids = new Set<string>()
  for (const l of laneList(v)) {
    const cur = laneCurrent(l)
    if (cur !== null && typeof cur.id === 'string') ids.add(cur.id)
    for (const q of Array.isArray(l.queue) ? l.queue.filter(isObj) : []) if (typeof q.id === 'string') ids.add(q.id)
  }

  return ids
}

// /ticket in a release session: every lane with its current ticket, verdict, full queue and tokens, then the tickets the run
// has finished. Empty for a release with no orchestration. Reads only what the board's jq pass returned.
export function laneDetails(v: ReleaseView): string[] {
  const out: string[] = []
  const finished = (Array.isArray(v.finished) ? v.finished.filter(isObj) : []) as FinishedTicket[]
  if (v.runActive === true) {
    const run = v.runTok === null || v.runTok === undefined ? '' : `   run: ${tokenDetail(v.runTok)}`
    out.push(`orchestrated run: active   maxParallel: ${isCount(v.maxParallel) && v.maxParallel >= 1 ? v.maxParallel : 2}${run}`)
    if (!Array.isArray(v.lanes)) {
      out.push('lanes: ? (release.orchestration.lanes is malformed, so no lane is shown)')
    } else {
      const lanes = laneList(v)
      if (lanes.length === 0) out.push('lanes: none reported yet')
      lanes.forEach((l, i) => {
        const cur = laneCurrent(l)
        const lv = laneVerdict(l)
        const queue = Array.isArray(l.queue) ? l.queue.filter(isObj) : []
        const head = `  L${laneNo(l, i)}  `
        if (cur === null) {
          out.push(`${head}${lv.text}`)
        } else {
          out.push(`${head}${typeof cur.id === 'string' ? cur.id : '?'} — ${cur.title || '(no title)'}`)
          const subs = isCount(cur.subsTotal) && cur.subsTotal > 0 ? `   subs ${cur.subsDone}/${cur.subsTotal}` : ''
          out.push(`        ${lv.text}${subs}   ${tokenDetail(cur.tokens)}`)
        }
        const n = isCount(l.queueLen) ? l.queueLen : queue.length
        if (n > 0) {
          out.push(`        queue (${n}):`)
          for (const q of queue) out.push(`          · ${String(q.id)} ${String(q.title ?? '').slice(0, 80)}`.trimEnd())
          if (n > queue.length) out.push(`          … and ${n - queue.length} more`)
        }
      })
    }
  }
  if (finished.length > 0) {
    out.push('finished this run:')
    for (const f of finished) {
      out.push(`  ${f.state === 'DONE' ? '✓' : '–'} ${String(f.id)} ${String(f.title ?? '').slice(0, 80)}   ${tokenDetail(f.tokens)}`.replace(/\s+$/, ''))
    }
  }

  return out
}

function details(v: View): string {
  if (!v.found) return `${v.id}: not found on any board (archived, another machine, or a typo). The line stays hidden.`
  const by =
    v.source === 'pinned' ? 'pinned'
    : v.source === 'followed' ? 'followed (this session moved on to it)'
    : `launched${v.role !== null ? ` as [${v.role}]` : ''}`
  const lines: string[] = []
  if (v.prior.length > 0) lines.push(`earlier this session: ${v.prior.map(p => `${p.id} (${p.status})`).join(', ')}`)
  if (v.kind === 'ticket') {
    const { resolved, total } = tally(v.subs)
    lines.push(
      `${v.id} — ${v.title || '(no title)'}`,
      `status: ${v.status}   verdict: ${ticketVerdict(v).text}   session: ${by}`,
      `subitems: ${resolved}/${total} resolved${v.prMerged !== null ? `   PR #${v.prMerged} merged` : ''}`,
      `release: ${v.release === null ? '—' : `${v.release.id} ${v.release.short || v.release.name}${v.release.target ? ` (${v.release.target})` : ''}`}`,
      `epic: ${v.epic === null ? '—' : `${v.epic.id} ${v.epic.short || v.epic.title}`}`,
    )
    for (const s of v.subs) {
      const mark = s.status === 'completed' ? '✓' : s.status === 'cancelled' ? '–' : s.status === 'in_progress' ? '▶' : '·'
      lines.push(`  ${mark} ${s.id} ${s.title.slice(0, 100)}`)
    }
  } else {
    const { completed, cancelled, total } = v.tickets
    lines.push(
      `${v.id} — ${v.name || v.short || '(no name)'}`,
      `status: ${v.status}   stage: ${v.stage || '—'}   verdict: ${releaseVerdict(v).text}   session: ${by}`,
      `platforms: ${v.platforms.join(', ') || '—'}   version: ${v.version || '—'}   target: ${v.target || '—'}   branch: ${v.branch || '—'}`,
      `tickets: ${completed} completed of ${total - cancelled}${cancelled > 0 ? ` (+${cancelled} cancelled, not counted)` : ''}`,
    )
    // A ticket the orchestrated-run section below already lists (a lane's current or a queued one) is not listed twice.
    const inRun = runTicketIds(v)
    const rest = v.open.filter(s => !inRun.has(s.id))
    const inRunCount = v.open.length - rest.length
    if (rest.length > 0) lines.push('open tickets:')
    for (const s of rest) lines.push(`  ${s.status === 'in_progress' ? '▶' : '·'} ${s.id} [${s.status}] ${s.title.slice(0, 90)}`)
    if (inRunCount > 0) {
      lines.push(rest.length > 0 ? `  (+${inRunCount} more open, listed under the orchestrated run below)` : `open tickets: all ${inRunCount} are listed under the orchestrated run below`)
    }
    lines.push(...laneDetails(v))
  }

  return lines.join('\n')
}

const short = (s: string, n: number) => (s.length > n ? `${s.slice(0, n - 1)}…` : s)

export const register: Register = on => {
  let lastCheck = 0

  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'ticket',
      description: "This kb-run session's ticket or release: details, pin <ID>, auto, on | off | help",
      argumentHint: '[ID|REL-ID|auto|on|off|help]',
    })
    await sw.start(switchIo($), () => {
      if (!sw.off) void check($).catch(() => undefined)
      $.ui.invalidate('ui.render')
    })
    if (!sw.off) await restoreTrail($)
    $.clock.every(POLL_MS, () => {
      if (!sw.off) void check($)
    })
    if (!sw.off) void check($)

    return next(e)
  })

  // Board writes happen during turns (sub done, kb-done, promote); look again as one ends.
  on('turn.complete', async ($, e, next) => {
    const at = await $.clock.now()
    if (e.agentId === undefined && !sw.off && at - lastCheck >= MIN_GAP_MS) {
      lastCheck = at
      void check($)
    }

    return next(e)
  })

  // Follow the session onto the next ticket: noted only once the command really ran.
  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const ran = await next(e)
    if (sw.off || e.tool !== 'Bash' || ran.deny !== undefined || ran.isError === true) return ran
    const id = workedOn(e.command)
    if (id !== null) void noteWork($, id)

    return ran
  })

  on('command.run', { command: 'ticket' }, async ($, e) => {
    const arg = e.args.trim()
    const low = arg.toLowerCase()
    if (low === 'on' || low === 'off' || low === 'hide' || low === 'show') {
      const patch = low === 'on' ? { off: false, hidden: false } : low === 'off' ? { off: true } : { hidden: low === 'hide' }
      if (!(await sw.set(switchIo($), patch))) return { text: 'Ticket line: could not save the switch (switches.json is unreadable).' }

      return { text: `Ticket line ${low}.` }
    }
    if (low === 'help') return { text: HELP }
    if (low === 'auto') {
      await update($, pinned, () => null)
      await check($, true)
      const v = await read($, view)

      return { text: v === null ? 'Unpinned. This session was not started by kb-run / kb-work, so the line is hidden.' : `Unpinned. Following ${v.id}.` }
    }
    if (arg !== '') {
      const id = parentId(arg.toUpperCase())
      if (id === null) return { text: `"${arg}" is not a ticket or release id.\n${HELP}` }
      await update($, pinned, () => id)
      await check($, true)
      const v = await read($, view)

      return { text: v === null ? `Pinned ${id}.` : details(v) }
    }

    await check($, true)
    const v = await read($, view)

    return { text: v === null ? 'Not a kb-run / kb-work session (no CC_SESSION_NAME ticket). Pin one with /ticket <ID>.' : details(v) }
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const below = await next(e)
    if (e.props.hasSurvey || !sw.shown) return below
    const v = await read($, view)
    // Hidden unless the session is on a ticket or release that a board actually holds.
    if (v === null || !v.found) return below

    const { Box, Text } = $.ui.resolve(e)
    const role = v.role === null ? null : <Text color={ROLE_COLOR[v.role]} weight="bold">{` ${v.role}`}</Text>

    if (v.kind === 'release') {
      const verdict = releaseVerdict(v)
      const { completed, cancelled, total } = v.tickets
      const deliverable = total - cancelled
      const lanes = laneList(v)

      return (
        <Box flexDirection="column">
          <Text wrap="truncate-end">
            <Text color={RELEASE_CHIP.color} backgroundColor={RELEASE_CHIP.bg} weight="bold">
              {RELEASE_CHIP.text}
            </Text>
            {role}
            <Text weight="bold"> {v.id}</Text>
            <Text dimColor> {short(v.short || v.name, 36)}</Text>
            <Text dimColor> · </Text>
            <Text color={verdict.color || undefined} weight={verdict.color === GREEN ? 'bold' : undefined}>
              {verdict.text}
            </Text>
            {!v.archived && <Text dimColor> · tickets </Text>}
            {!v.archived && (
              <Text color={deliverable > 0 && completed === deliverable ? GREEN : undefined}>{`${completed}/${deliverable}`}</Text>
            )}
            {cancelled > 0 && <Text dimColor>{` (+${cancelled} cxl)`}</Text>}
            {v.version !== '' && <Text dimColor> · v{v.version}</Text>}
            {v.target !== '' && <Text dimColor> · target {v.target}</Text>}
            {v.source === 'pinned' && <Text dimColor> · 📌</Text>}
          </Text>
          {lanes.map((l, i) => {
            const cur = laneCurrent(l)
            const lv = laneVerdict(l)
            const resolved = cur?.subsDone
            const subsTotal = cur?.subsTotal
            const queued = isCount(l.queueLen) ? l.queueLen : 0
            const tok = cur === null ? null : tokenText(cur.tokens)

            return (
              <Text key={`lane-${laneNo(l, i)}`} wrap="truncate-end">
                <Text dimColor>{` ${i === lanes.length - 1 ? '└' : '├'} L${laneNo(l, i)} `}</Text>
                {cur !== null && <Text weight="bold">{typeof cur.id === 'string' ? cur.id : '?'}</Text>}
                {cur !== null && <Text dimColor> · </Text>}
                <Text color={lv.color || undefined} dimColor={lv.color === ''} weight={lv.color === GREEN ? 'bold' : undefined}>
                  {lv.text}
                </Text>
                {cur !== null && isCount(subsTotal) && subsTotal > 0 && isCount(resolved) && <Text dimColor> · subs </Text>}
                {cur !== null && isCount(subsTotal) && subsTotal > 0 && isCount(resolved) && (
                  <Text color={resolved === subsTotal ? GREEN : undefined}>{`${resolved}/${subsTotal}`}</Text>
                )}
                {queued > 0 && <Text dimColor>{` · +${queued} queued`}</Text>}
                {tok !== null && <Text dimColor>{` · ${tok}`}</Text>}
                {/* Title LAST: truncate-end eats it first, so a narrow terminal keeps the verdict (render check, 60 cols). */}
                {cur !== null && typeof cur.title === 'string' && cur.title !== '' && <Text dimColor>{` · ${short(cur.title, 32)}`}</Text>}
              </Text>
            )
          })}
          {below}
        </Box>
      )
    }

    const verdict = ticketVerdict(v)
    const { resolved, total, next: nextSub } = tally(v.subs)
    const rel = v.release === null ? null : v.release.short || v.release.name || v.release.id
    const epic = v.epic === null ? null : v.epic.short || v.epic.title || v.epic.id
    // Earlier tickets of this session: done ones struck through in green with a check, cancelled
    // ones struck through in red with a cross, any left open in amber with a bang, so the state
    // never rests on colour alone.
    const earlier = v.prior.map(p => (
      <Text key={p.id}>
        <Text> </Text>
        {p.status === 'completed' ? (
          <Text><Text color={GREEN}>✓</Text><Text color={GREEN} strikethrough>{p.id}</Text></Text>
        ) : p.status === 'cancelled' ? (
          <Text><Text color={RED}>✗</Text><Text color={RED} strikethrough>{p.id}</Text></Text>
        ) : (
          <Text><Text color={AMBER}>!</Text><Text color={AMBER}>{p.id}</Text></Text>
        )}
      </Text>
    ))

    return (
      <Box flexDirection="column">
        <Text wrap="truncate-end">
          <Text color={TICKET_CHIP.color} backgroundColor={TICKET_CHIP.bg} weight="bold">
            {TICKET_CHIP.text}
          </Text>
          {role}
          {earlier}
          {earlier.length > 0 && <Text dimColor> ›</Text>}
          <Text weight="bold"> {v.id}</Text>
          <Text dimColor> {short(v.title, 44)}</Text>
          <Text dimColor> · </Text>
          <Text color={verdict.color || undefined} weight={verdict.color === GREEN ? 'bold' : undefined}>
            {verdict.text}
          </Text>
          {total > 0 && <Text dimColor> · subs </Text>}
          {total > 0 && <Text color={resolved === total ? GREEN : undefined}>{`${resolved}/${total}`}</Text>}
          {rel !== null && <Text dimColor> · rel </Text>}
          {rel !== null && <Text>{short(rel, 28)}</Text>}
          {epic !== null && <Text dimColor> · epic </Text>}
          {epic !== null && <Text>{short(epic, 28)}</Text>}
          {nextSub !== null && v.status !== 'completed' && <Text dimColor> · next: {short(nextSub.title, 40)}</Text>}
          {v.source === 'pinned' && <Text dimColor> · 📌</Text>}
        </Text>
        {below}
      </Box>
    )
  })
}
