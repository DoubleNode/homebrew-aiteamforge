import { expect, mock, test } from 'claude-code/testing'
import type { Engine, TestBody } from 'claude-code/testing'

import { LANES_FIXTURE } from '../tests/lanes.fixture'
import { RELEASE_BASELINE } from '../tests/release-baseline.snapshot'
import { switchFiles } from '../tests/switch-fixture'
import type { SwitchFiles } from '../tests/switch-fixture'
import { LANE_STAGE, cacheShare, fmtTokens, laneDetails, laneList, laneVerdict, tokenDetail, tokenText } from './register'
import type { ReleaseView } from '../types'

// XACA-1786: lane lines under the release line. The fixture is GENERATED from the real writer
// (kanban-hooks/release_orchestrator.py) and the real RELEASE_FILTER by tests/gen_lanes_fixture.py, and
// tests/test_xaca1786_lanes_fixture.py fails when it is stale, so nothing here is an invented shape.
type On = Parameters<TestBody>[1]
type Json = Record<string, any> // eslint-disable-line @typescript-eslint/no-explicit-any

const scenarios = LANES_FIXTURE.scenarios as unknown as Record<string, { view: Json }>
const view = (name: string): ReleaseView => {
  const v = scenarios[name]?.view
  if (v === undefined) throw new Error(`no fixture scenario ${name}`)

  return v as unknown as ReleaseView
}
const stageOf = LANES_FIXTURE.stateStage as Record<string, string>

const BAND = {
  plugin: 'ticket-lamp',
  component: 'AbovePrompt',
  props: { hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: 160, scroll: { offset: 0, bodyRows: 10 }, view: {} },
} as const

// ---------------------------------------------------------------- rendering a view directly
// The release view captured BEFORE this ticket: RELEASE_BASELINE is the tree the old code drew for it.
const OLD_RELEASE = {
  kind: 'release', name: 'Academy R02', short: 'R02', status: 'in_progress', stage: 'PLANNED', platforms: ['other:PLANNED'],
  version: '1.30.0', target: '2026-11-20', branch: '', tickets: { completed: 3, cancelled: 1, total: 51 }, open: [], archived: false,
  id: 'REL-2026-Q4-053', source: 'launch', role: null, found: true, key: 'k', checkedAt: 0, prior: [],
}

type Node = { type: string; props?: Json; children?: (Node | string)[] }
const textOf = (n: Node | string): string => (typeof n === 'string' ? n : (n.children ?? []).map(textOf).join(''))

// The drawn tree's NESTING differs between Claude Code versions (2.1.319 flattens the lamp's Box into the outer column Box,
// 2.1.325 keeps it), so no test indexes into it. A lamp line is any <Text wrap="truncate-end"> wherever it sits, the way
// consumer-layout.test.tsx and register.test.tsx find their text; the lamp only ever draws its lines that way.
function lampLines(n: Node | string, out: Node[] = []): Node[] {
  if (typeof n === 'string') return out
  if (n.type === 'Text' && n.props?.wrap === 'truncate-end') {
    out.push(n)

    return out
  }
  for (const c of n.children ?? []) lampLines(c, out)

  return out
}
// The release-only render captured BEFORE this change, reduced to the same shape-free list of lines.
const BASELINE_LINES = JSON.stringify(lampLines(JSON.parse(RELEASE_BASELINE) as Node))

// Hooks must be registered before the test first calls $, so a test rigs the engine once and draws many views through it.
function rig(on: On, $: Engine): (shown: Json) => Promise<{ tree: Node; lines: Node[]; raw: string }> {
  let current: Json = {}
  on('state.get', (_, e) => (e.key === 'view' ? { value: { value: { shape: 'view-3', value: current }, version: 1 } } : { value: { value: null, version: 1 } }))
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)

    return <Text>prompt</Text>
  })

  return async shown => {
    current = shown
    const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
    const tree = (await ui.drawn()) as unknown as Node
    await ui.unmount()
    const lines = lampLines(tree)

    // The lamp's own rows: the release line first, then one row per lane. raw is those rows only, never the nesting.
    return { tree, lines, raw: JSON.stringify(lines) }
  }
}

const asShown = (v: ReleaseView, over: Json = {}): Json => ({
  ...v, id: 'REL-2026-Q4-070', source: 'launch', role: null, found: true, key: 'k', checkedAt: 0, prior: [], ...over,
})

// ---------------------------------------------------------------- laneVerdict
const EXPECT: Record<string, { text: string | RegExp; mark: RegExp; green: boolean }> = {
  queued: { text: 'dispatching…', mark: /…/, green: false },
  dispatching: { text: 'dispatching…', mark: /…/, green: false },
  coding: { text: 'implementing', mark: /implementing/, green: false },
  question: { text: 'question !', mark: /!/, green: false },
  review: { text: 'PR #7 gates', mark: /PR #7/, green: false },
  merged: { text: 'merged ✓', mark: /✓/, green: true },
  done: { text: 'done ✓', mark: /✓/, green: true },
  failed: { text: 'failed ✗', mark: /✗/, green: false },
  crashed: { text: 'crashed ✗', mark: /✗/, green: false },
  stalled: { text: 'stalled !', mark: /!/, green: false },
  cancelled: { text: 'cancelled –', mark: /–/, green: false },
  unknown: { text: '?', mark: /\?/, green: false },
}
const lane = (status: string, stage: string, over: Json = {}) => ({ lane: 1, current: { id: 'XACA-1', status, stage, prNumber: 7, ...over }, queue: [], queueLen: 0 })

test('the lamp knows exactly the writer\'s stage vocabulary (LANE_STAGE == STATE_STAGE read from the writer)', async () => {
  expect(LANE_STAGE).toEqual(stageOf)
  expect([...LANES_FIXTURE.states].sort()).toEqual(Object.keys(stageOf).sort())
})

test('laneVerdict table: EVERY writer state maps to its verdict, a new stage fails here', async () => {
  const stages = [...new Set(Object.values(stageOf))]
  expect(stages.length).toBeGreaterThan(8)
  for (const stage of stages) expect(EXPECT[stage], `stage "${stage}" has no expected verdict: add it to the lamp AND this table`).toBeDefined()
  for (const [status, stage] of Object.entries(stageOf)) {
    const want = EXPECT[stage]!
    const got = laneVerdict(lane(status, stage))
    expect(got.text, `${status}/${stage}`).toBe(want.text)
    expect(got.text, `${status}/${stage} carries a non-colour marker`).toMatch(want.mark)
    expect(got.color === 'success', `${status}/${stage} green only when really done`).toBe(want.green)
  }
})

test('laneVerdict: no prNumber is "in review"; a freed lane is idle', async () => {
  expect(laneVerdict(lane('IN_REVIEW', 'review', { prNumber: null })).text).toBe('in review')
  expect(laneVerdict(lane('IN_REVIEW', 'review', { prNumber: 0 })).text).toBe('in review')
  expect(laneVerdict({ lane: 2, current: null }).text).toBe('idle')
})

test('colour stripped, the verdict texts still tell the states apart', async () => {
  const stages = [...new Set(Object.values(stageOf))]
  const byStage = new Map(Object.entries(stageOf).map(([status, stage]) => [stage, laneVerdict(lane(status, stage)).text]))
  const texts = stages.map(s => byStage.get(s))
  // queued and dispatching share one verdict by design; every other stage has its own.
  expect(new Set(texts).size).toBe(stages.length - 1)
  expect(new Set([...texts, laneVerdict({ current: null }).text]).size).toBe(stages.length)
})

test('unknown, unrecognised or malformed is a dim "?", never green, never a check mark', async () => {
  const merged = laneVerdict(lane('MERGED_PENDING_DONE', 'merged'))
  const bad: unknown[] = [
    undefined, null, 'XACA-1', 7, [], {}, { lane: 1 }, { current: undefined }, { current: 'XACA-1' }, { current: [] }, { current: {} },
    lane('WARP_CORE_BREACH', 'teleporting'), lane('UNKNOWN', 'unknown'), lane('RUNNING', 'teleporting'),
    lane('WARP_CORE_BREACH', 'merged'), lane('DONE', 'merged'), lane('IN_REVIEW', 'merged'), lane('MERGED_PENDING_DONE', 'coding'),
    { current: { status: null, stage: null } }, { current: { status: 3, stage: 'merged' } }, { current: { status: 'MERGED_PENDING_DONE' } },
    { current: { stage: 'merged' } }, lane('toString', 'merged'), lane('__proto__', 'merged'), lane('constructor', 'merged'),
  ]
  for (const b of bad) {
    const got = laneVerdict(b)
    expect(got, JSON.stringify(b)).toEqual({ text: '?', color: '' })
    expect(got.text).not.toBe(merged.text)
    expect(got.text).not.toMatch(/✓/)
    expect(got.color).not.toBe('success')
  }
})

test('every lane the REAL writer produced gets a real verdict; only deliberately corrupted ones are "?"', async () => {
  for (const [name, sc] of Object.entries(scenarios)) {
    const synthetic = (LANES_FIXTURE.scenarios as unknown as Record<string, { synthetic: boolean }>)[name]!.synthetic
    for (const l of (sc.view.lanes ?? []) as Json[]) {
      const v = laneVerdict(l)
      if (l.current === null) expect(v.text, name).toBe('idle')
      else if (!synthetic) expect(v.text, `${name}: a writer-valid lane must not read "?"`).not.toBe('?')
    }
  }
  const unknown = (view('unknown_stage').lanes as Json[])[0]!
  expect(laneVerdict(unknown)).toEqual({ text: '?', color: '' })
})

// ---------------------------------------------------------------- tokens
test('fmtTokens: compact figures', async () => {
  expect(fmtTokens(0)).toBe('0')
  expect(fmtTokens(999)).toBe('999')
  expect(fmtTokens(1115)).toBe('1.1k')
  expect(fmtTokens(1_206_200)).toBe('1.2M')
  expect(fmtTokens(999_950)).toBe('1M')
  expect(fmtTokens(250_000)).toBe('250k')
  expect(fmtTokens(2_500_000_000)).toBe('2.5B')
})

test('tokenText: nothing when absent, "tok ?" when malformed, never 0', async () => {
  expect(tokenText(null)).toBe(null)
  expect(tokenText(undefined)).toBe(null)
  expect(tokenText({ total: 1_206_200, cacheRead: 1_000_000 })).toBe('1.2M tok')
  expect(tokenText({ total: 0, cacheRead: 0 })).toBe('0 tok')
  for (const bad of ['?', 'x', 7, [], {}, { total: 'many' }, { total: -1 }, { total: NaN }, { total: null }]) expect(tokenText(bad), JSON.stringify(bad)).toBe('tok ?')
})

test('cache-read share: whole percent, no division by zero, nothing for a malformed block', async () => {
  expect(cacheShare({ total: 1_206_200, cacheRead: 1_000_000 })).toBe(83)
  expect(cacheShare({ total: 0, cacheRead: 0 })).toBe(null)
  for (const bad of [null, '?', {}, { total: 10 }, { total: 10, cacheRead: 11 }, { total: 10, cacheRead: -1 }, { total: 'a', cacheRead: 1 }]) expect(cacheShare(bad)).toBe(null)
  expect(tokenDetail({ total: 1_206_200, cacheRead: 1_000_000 })).toBe('1.2M tok · 83% cache-read')
  expect(tokenDetail({ total: 0, cacheRead: 0 })).toBe('0 tok')
  expect(tokenDetail(null)).toBe('tokens —')
  expect(tokenDetail('?')).toBe('tok ?')
})

test('the XACA-1808 contract file, read by the real jq pass, gives total = input+cacheCreate+cacheRead+output', async () => {
  const c = LANES_FIXTURE.tokenContract as Json
  const b = c.perItem['XACA-0000']
  const want = b.input + b.cacheCreate + b.cacheRead + b.output
  expect(want).toBeGreaterThan(b.cacheRead)
  const cur = (view('contract_tokens').lanes as Json[])[0]!.current
  expect(cur.id).toBe('XACA-0000')
  expect(cur.tokens).toEqual({ total: want, cacheRead: b.cacheRead })
  expect(view('contract_tokens').runTok).toEqual({ total: c.run.input + c.run.cacheCreate + c.run.cacheRead + c.run.output, cacheRead: c.run.cacheRead })
})

// ---------------------------------------------------------------- the lane lines
test('no active run, an old stored view, or a malformed block: byte-identical to the render BEFORE this change', async ($, on) => {
  const d = rig(on, $)
  const mk = (over: Json) => ({ ...OLD_RELEASE, ...over })
  const cases: Record<string, Json> = {
    'no orchestration fields (an old stored view)': mk({}),
    'runActive false': mk({ runActive: false, maxParallel: 2, lanes: [], finished: [], runTok: null }),
    'runActive false even when lanes were sent': mk({ runActive: false, maxParallel: 2, lanes: view('two_lanes').lanes }),
    'active but lanes not an array': mk({ runActive: true, maxParallel: 2, lanes: null }),
    'active but lanes a string': mk({ runActive: true, maxParallel: 2, lanes: 'oops' }),
    'active with zero lanes': mk({ runActive: true, maxParallel: 2, lanes: [], finished: [], runTok: null }),
    'finished tickets alone draw nothing': mk({ runActive: false, lanes: [], finished: view('freed_lane').finished }),
  }
  for (const [name, shown] of Object.entries(cases)) {
    const out = await d(shown)
    expect(out.raw, name).toBe(BASELINE_LINES)
    expect(textOf(out.tree), name).toContain('prompt')
    expect(out.lines.length, name).toBe(1)
  }
})

test('0, 1 and 2 lanes draw the release line plus that many lane lines', async ($, on) => {
  const d = rig(on, $)
  const none = await d(asShown(view('two_lanes'), { lanes: [] }))
  expect(none.lines.length).toBe(1)
  const one = await d(asShown(view('contract_tokens')))
  expect(one.lines.length).toBe(2)
  expect(textOf(one.lines[0]!)).toContain('RELEASE')
  expect(textOf(one.lines[1]!)).toMatch(/^ └ L1 XACA-0000 · implementing · subs 1\/2 · 1\.1k tok · Ticket named in the XACA-1808 c…$/)
  const two = await d(asShown(view('two_lanes')))
  expect(two.lines.length).toBe(3)
  const [l1, l2] = [textOf(two.lines[1]!), textOf(two.lines[2]!)]
  expect(l1).toMatch(/^ ├ L1 XACA-9001 · PR #1320 gates · subs 3\/5 · \+2 queued · 1\.2M tok · Lane one ticket: wire the gates$/)
  expect(l2).toMatch(/^ └ L2 XACA-9002 · question ! · subs 1\/3 · \+1 queued · Lane two ticket: ask a question$/)
  expect(l2).not.toContain('tok')
  // the release line itself is untouched
  expect(textOf(two.lines[0]!)).toBe(textOf(one.lines[0]!))
})

test('lane lines truncate rather than wrap, and the verdict comes before the title', async ($, on) => {
  const d = rig(on, $)
  const out = await d(asShown(view('two_lanes')))
  for (const l of out.lines) expect(l.props?.wrap).toBe('truncate-end')
  // truncate-end eats the END of the line, so the verdict must come before the title: at 60 columns the
  // title-first order cut the state to "awai…" (XACA-1786 render check). The title is the last field.
  for (const [line, verdict, title] of [
    [textOf(out.lines[1]!), 'PR #1320 gates', 'Lane one ticket'],
    [textOf(out.lines[2]!), 'question !', 'Lane two ticket'],
  ] as const) {
    expect(line.indexOf(verdict), line).toBeGreaterThan(-1)
    expect(line.indexOf(verdict), line).toBeLessThan(line.indexOf(title))
    expect(line.endsWith(title) || /· [^·]*$/.test(line), line).toBe(true)
  }
})

// ---------------------------------------------------------------- the lane cap mirrors the writer's lanes_view
// release_orchestrator.lanes_view / _init_lanes: an OCCUPIED lane (current not null) is kept at any lane number, because
// STALLED, CRASHED and FAILED tickets keep their lane and a human must see them; an EMPTY lane is drawn only when numbered
// 1..maxParallel; lanes are ordered by number. Expected rows are (lane number, ticket id | 'idle'), written by hand, never
// derived from the code under test. Every row is asserted through jq (the committed fixture), laneList, the render and /ticket.
type Row = [number, string]
const CAP_ROWS: Record<string, Row[]> = {
  over_cap: [[1, 'XACA-9001'], [2, 'XACA-9002']], // re-run max 2 -> 1, both occupied
  shrunk_all_occupied: [[1, 'XACA-9001'], [2, 'XACA-9002'], [3, 'XACA-9005']], // re-run max 3 -> 2, all occupied
  overcap_stalled: [[1, 'idle'], [2, 'idle'], [3, 'XACA-9005']], // the reviewer's reproduction: occupied above max, empty below
  overcap_crashed: [[1, 'idle'], [2, 'idle'], [3, 'XACA-9005']],
  overcap_failed: [[1, 'idle'], [2, 'idle'], [3, 'XACA-9005']],
  lane_gap: [[1, 'idle'], [2, 'idle'], [4, 'XACA-9001']], // lanes 1, 2, 4: no lane 3
  lane_gap_missing_first: [[2, 'XACA-9001']], // lane 1 missing, empty lane 3 above max 2 dropped (synthetic)
  empty_above_max_dropped: [[1, 'XACA-9001']], // NEGATIVE CONTROL: empty lanes 2 and 3 above max 1 are dropped (synthetic)
  empty_above_max_beside_occupied: [[1, 'idle'], [2, 'idle'], [4, 'XACA-9001']], // NEGATIVE CONTROL: empty 3 dropped, occupied 4 kept (synthetic)
  lanes_duplicate_no: [[1, 'XACA-9001'], [2, 'XACA-9002']], // a second "lane 1" entry: the first wins (synthetic)
  lanes_out_of_order: [[1, 'XACA-9001'], [2, 'XACA-9002']], // stored [2, 1]: drawn in lane order (synthetic)
  stalled_crashed_failed: [[1, 'XACA-9001'], [2, 'XACA-9002'], [3, 'XACA-9005']], // all three dead lanes, max 3
}
const rowsOf = (lanes: Json[]): Row[] => lanes.map(l => [l.lane as number, (l.current?.id as string | undefined) ?? 'idle'])

test('the cap rows are real: jq output (the committed fixture) draws every occupied lane and only the in-range empty ones', async () => {
  for (const [name, want] of Object.entries(CAP_ROWS)) expect(rowsOf(view(name).lanes as Json[]), `jq ${name}`).toEqual(want)
  // the over-cap lanes really are over the cap, so these rows test something
  expect(view('over_cap').maxParallel).toBe(1)
  expect(view('overcap_stalled').maxParallel).toBe(2)
  expect(view('lane_gap').maxParallel).toBe(2)
  expect(view('overcap_stalled').lanes).toEqual(expect.arrayContaining([expect.objectContaining({ lane: 3, current: expect.objectContaining({ status: 'STALLED', stage: 'stalled' }) })]))
  expect(view('overcap_crashed').lanes).toEqual(expect.arrayContaining([expect.objectContaining({ lane: 3, current: expect.objectContaining({ status: 'CRASHED' }) })]))
  expect(view('overcap_failed').lanes).toEqual(expect.arrayContaining([expect.objectContaining({ lane: 3, current: expect.objectContaining({ status: 'FAILED' }) })]))
})

test('laneList draws the same lanes (TS layer), whichever the jq pass sent', async () => {
  for (const [name, want] of Object.entries(CAP_ROWS)) expect(rowsOf(laneList(view(name)) as unknown as Json[]), `laneList ${name}`).toEqual(want)
  const empty = (n: number) => ({ lane: n, current: null, queue: [], queueLen: 0 })
  const busy = (n: number) => ({ lane: n, current: { id: `XACA-${n}`, status: 'STALLED', stage: 'stalled' }, queue: [], queueLen: 0 })
  const lanes = [empty(1), empty(2), empty(3), empty(4), busy(5)] as unknown as ReleaseView['lanes']
  const ids = (maxParallel: unknown) => laneList({ runActive: true, maxParallel, lanes } as unknown as ReleaseView).map(l => l.lane)
  expect(ids(3)).toEqual([1, 2, 3, 5])
  expect(ids(1)).toEqual([1, 5])
  // an unusable cap falls back to the default 2, and still keeps the occupied lane
  for (const cap of [0, -1, 'x', null, 1.5, undefined]) expect(ids(cap), String(cap)).toEqual([1, 2, 5])
  // order by lane number, not by position
  const shuffled = [busy(3), empty(2), empty(1)] as unknown as ReleaseView['lanes']
  expect(laneList({ runActive: true, maxParallel: 2, lanes: shuffled }).map(l => l.lane)).toEqual([1, 2, 3])
  // no active run: nothing, whatever the lanes hold
  expect(laneList({ runActive: false, maxParallel: 2, lanes })).toEqual([])
})

test('the render draws exactly those lanes, last one with the closing connector', async ($, on) => {
  const d = rig(on, $)
  for (const [name, want] of Object.entries(CAP_ROWS)) {
    const drawn = (await d(asShown(view(name)))).lines.slice(1).map(textOf)
    const got = drawn.map(t => {
      const m = /^ [├└] L(\d+) (\S+)/.exec(t)
      expect(m, `${name}: ${t}`).not.toBeNull()

      return [Number(m![1]), m![2]!] as Row
    })
    expect(got, `render ${name}`).toEqual(want)
    drawn.forEach((t, i) => expect(t.startsWith(i === drawn.length - 1 ? ' └' : ' ├'), `${name}: ${t}`).toBe(true))
  }
  // the dead tickets keep their verdict word on the over-cap lane
  for (const [name, word] of [['overcap_stalled', 'stalled !'], ['overcap_crashed', 'crashed ✗'], ['overcap_failed', 'failed ✗']] as const) {
    expect((await d(asShown(view(name)))).lines.slice(1).map(textOf).at(-1), name).toMatch(new RegExp(`^ └ L3 XACA-9005 · ${word.replace('!', '\\!')}`))
  }
})

test('laneDetails (what /ticket prints) lists exactly those lanes', async () => {
  for (const [name, want] of Object.entries(CAP_ROWS)) {
    const got = laneDetails(view(name))
      .map(t => /^ {2}L(\d+) {2}(\S+)/.exec(t))
      .filter((m): m is RegExpExecArray => m !== null)
      .map(m => [Number(m[1]), m[2]!] as Row)
    expect(got, `laneDetails ${name}`).toEqual(want)
  }
})

for (const [name, want] of Object.entries(CAP_ROWS)) {
  test(`/ticket on the engine path lists exactly the lanes of ${name}`, async ($, on) => {
    const fx = switchFiles()
    const clock = engine(on, fx, name)
    await start($)
    await clock.settle()
    const text = (await command($, '')).text as string
    const got = text.split('\n')
      .map(t => /^ {2}L(\d+) {2}(\S+)/.exec(t))
      .filter((m): m is RegExpExecArray => m !== null)
      .map(m => [Number(m[1]), m[2]!] as Row)
    expect(got).toEqual(want)
  })
}

test('/ticket "open tickets" does not repeat the lane and queued tickets the orchestrated run lists', async ($, on) => {
  const fx = switchFiles()
  const clock = engine(on, fx, 'two_lanes')
  await start($)
  await clock.settle()
  const text = (await command($, '')).text as string
  const open = text.slice(text.indexOf('open tickets:'), text.indexOf('orchestrated run:'))
  // the one open ticket the run does not mention stays; every lane and queued ticket is only under the run
  expect(open).toMatch(/^ {2}[▶·] XACA-0000 \[in_progress\]/m)
  for (const id of ['XACA-9001', 'XACA-9002', 'XACA-9003', 'XACA-9004', 'XACA-9005']) {
    expect(open, id).not.toContain(id)
    expect(text, id).toContain(id)
  }
  expect(open).toContain('(+5 more open, listed under the orchestrated run below)')
})

test('/ticket "open tickets" with every open ticket already in the run says so instead of repeating them', async ($, on) => {
  const fx = switchFiles()
  const clock = engine(on, fx, 'all_open_in_run')
  await start($)
  await clock.settle()
  const text = (await command($, '')).text as string
  expect(text).toContain('open tickets: all 5 are listed under the orchestrated run below')
  expect(text).not.toMatch(/^ {2}[▶·] XACA-\d+ \[/m)
  expect(text).toContain('L1  XACA-9001')
  expect(text).toContain('· XACA-9005 Third lane ticket')
})

test('an idle lane and the queue count', async ($, on) => {
  const d = rig(on, $)
  const out = await d(asShown(view('freed_lane')))
  const l1 = textOf(out.lines[1]!)
  expect(l1).toBe(' ├ L1 idle · +2 queued')
  expect(textOf(out.lines[2]!)).toContain('L2 XACA-9002')
  expect(textOf(out.lines[2]!)).toContain('implementing')
  // a lane with an empty queue shows no "queued"
  expect(textOf((await d(asShown(view('contract_tokens')))).lines[1]!)).not.toContain('queued')
})

test('every state shows a marker beyond colour on its line; stalled, crashed and failed keep their lane', async ($, on) => {
  const d = rig(on, $)
  const out = await d(asShown(view('stalled_crashed_failed')))
  const rows = out.lines.slice(1).map(textOf)
  expect(rows[0]).toContain('stalled !')
  expect(rows[1]).toContain('crashed ✗')
  expect(rows[2]).toContain('failed ✗')
  const merged = await d(asShown(view('coding_merged')))
  expect(merged.lines.slice(1).map(textOf)).toEqual([
    expect.stringContaining('implementing'),
    expect.stringContaining('merged ✓'),
  ])
  const colours = out.lines.slice(1).map(l => ((l.children ?? []).find(c => typeof c !== 'string' && textOf(c).includes('!') || typeof c !== 'string' && textOf(c).includes('✗')) as Node | undefined)?.props?.color)
  expect(colours).toEqual(['warning', 'error', 'error'])
})

test('tokens: nothing for a missing ticket, "tok ?" for a malformed block, never 0', async ($, on) => {
  const d = rig(on, $)
  const bad = (await d(asShown(view('tokens_bad_item')))).lines.slice(1).map(textOf)
  expect(bad[0]).toMatch(/ · tok \? · /)
  expect(bad[1]).not.toContain('tok')
  const block = (await d(asShown(view('tokens_bad_block')))).lines.slice(1).map(textOf)
  expect(block[0]).toMatch(/ · tok \? · /)
  expect(block[0]).not.toMatch(/ 0 tok/)
  expect((await d(asShown(view('coding_merged')))).lines.slice(1).map(textOf).join('\n')).not.toContain('tok')
})

test('malformed lane data never draws a green or check-mark verdict and never throws', async ($, on) => {
  const d = rig(on, $)
  const unknown = (await d(asShown(view('unknown_stage')))).lines.slice(1).map(textOf)
  expect(unknown[0]).toMatch(/^ ├ L1 XACA-9001 · \? · /)
  expect(unknown[1]).toContain('idle')
  for (const name of ['unknown_stage', 'missing_current', 'current_not_object', 'lanes_not_array']) {
    const out = await d(asShown(view(name)))
    for (const l of out.lines.slice(1)) {
      expect(textOf(l), name).not.toMatch(/✓/)
      expect(JSON.stringify(l), name).not.toContain('"success"')
    }
  }
  expect((await d(asShown(view('missing_current')))).lines.slice(1).map(textOf)[0]).toContain(' · ? ')
  expect((await d(asShown(view('current_not_object')))).lines.slice(1).map(textOf)[0]).toMatch(/L1 \? · \?/)
  expect((await d(asShown(view('lanes_not_array')))).lines.length).toBe(1)
  // hand-broken views, as an old or corrupt stored value could hold
  for (const lanes of [{}, 'x', 7, [null, 5, 'x', []], [{}], [{ lane: 'a', current: { status: 'DONE', stage: 'merged' }, queue: 'oops', queueLen: 'many' }]]) {
    const out = await d(asShown(view('two_lanes'), { lanes }))
    for (const l of out.lines.slice(1)) expect(textOf(l)).not.toMatch(/✓/)
  }
})

// ---------------------------------------------------------------- the engine path: switches and /ticket
const CONFIG = '/home/me/.aiteamforge/team-paths.json'
const TEAMS = { teams: { acme: { kanban_dir: '/home/me/acme/kanban', team_code: 'ACME' } } }
const out = (exitCode: number, stdout: string) => ({ value: { exitCode, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } })

function engine(on: On, fx: SwitchFiles, name: string) {
  const clock = mock.clock(on, { now: 1_000_000 })
  mock.store(on)
  mock.env(on, { HOME: fx.home, CC_SESSION_NAME: 'REL-2026-Q4-070: Lane run' })
  on('command.register', () => ({ value: { command: 'ticket' } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('session.id', () => ({ value: 'sess-1' }))
  on('fs.exists', (_, e) => ({ value: fx.exists(e.path) }))
  on('fs.read', (_, e) => {
    if (fx.owns(e.path)) return { value: fx.read(e.path) }
    if (e.path !== CONFIG) throw new Error('ENOENT')

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
    if (e.argv[0] === 'grep') return out(0, '')
    if (e.argv[0] !== 'jq') return out(127, '')

    return out(0, JSON.stringify(scenarios[name]!.view))
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
async function shownTexts($: Engine) {
  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
  const texts = (await ui.findAll({ type: 'Text' })).map(t => t.text)
  await ui.unmount()

  return texts
}

test('hidden or off draws no lane lines (and no release line); shown draws them (shared switch file)', async ($, on) => {
  const fx = switchFiles()
  const clock = engine(on, fx, 'two_lanes')
  await start($)
  await clock.settle()
  const on1 = await shownTexts($)
  expect(on1.some(t => t.includes('L1 XACA-9001')) || on1.some(t => t.includes('XACA-9001'))).toBe(true)
  expect(on1.some(t => t.includes('REL-2026-Q4-070'))).toBe(true)

  await command($, 'hide')
  const hidden = await shownTexts($)
  expect(hidden.some(t => t.includes('XACA-9001') || t.includes('REL-2026-Q4-070'))).toBe(false)
  expect(hidden).toContain('other mod line')

  await command($, 'show')
  await command($, 'off')
  const off = await shownTexts($)
  expect(off.some(t => t.includes('XACA-9001') || t.includes('REL-2026-Q4-070'))).toBe(false)
})

test('/ticket in a release session lists every lane, its full queue, the finished tickets and tokens with cache-read share', async ($, on) => {
  const fx = switchFiles()
  const clock = engine(on, fx, 'two_lanes')
  await start($)
  await clock.settle()
  const text = (await command($, '')).text as string
  const share = Math.round((1_000_000 / 1_206_200) * 100)
  expect(text).toContain('orchestrated run: active   maxParallel: 2')
  expect(text).toContain(`run: 1.2M tok · ${Math.round((1_010_000 / 1_226_700) * 100)}% cache-read`)
  expect(text).toContain('L1  XACA-9001 — Lane one ticket: wire the gates')
  expect(text).toContain(`PR #1320 gates   subs 3/5   1.2M tok · ${share}% cache-read`)
  expect(text).toContain('L2  XACA-9002 — Lane two ticket: ask a question')
  expect(text).toContain('question !   subs 1/3   tokens —')
  expect(text).toContain('queue (2):')
  expect(text).toContain('· XACA-9005 Third lane ticket')
  expect(text).toContain('· XACA-9004 Queued ticket behind lane two')
  expect(text).toContain('queue (1):')
  expect(text).toContain('· XACA-9003 Queued ticket behind lane one')
  // the original release block is still there
  expect(text).toContain('open tickets:')
})

test('/ticket lists the tickets the run has finished, with their tokens', async ($, on) => {
  const fx = switchFiles()
  const clock = engine(on, fx, 'freed_lane')
  await start($)
  await clock.settle()
  const text = (await command($, '')).text as string
  expect(text).toContain('L1  idle')
  expect(text).toContain('finished this run:')
  expect(text).toContain(`✓ XACA-9001 Lane one ticket: wire the gates   1.1k tok · ${Math.round((1000 / 1115) * 100)}% cache-read`)
})

test('/ticket: malformed lanes say so, a plain release adds nothing, bad tokens are "tok ?"', async ($, on) => {
  expect(laneDetails(view('no_orchestration'))).toEqual([])
  expect(laneDetails(view('closed_run'))).toEqual(['finished this run:', '  ✓ XACA-9001 Lane one ticket: wire the gates   tokens —'])
  expect(laneDetails(view('lanes_not_array')).join('\n')).toContain('lanes: ? (release.orchestration.lanes is malformed')
  expect(laneDetails({ ...view('two_lanes'), finished: 'x', lanes: [null, { lane: 1, current: 'x' }] } as unknown as ReleaseView).join('\n')).toContain('L1  ?')
  expect(laneDetails(view('tokens_bad_block')).join('\n')).toContain('tok ?')
  expect(laneDetails(view('tokens_bad_item')).join('\n')).toContain('   tok ?')
  // the fixture run is real writer output: the lanes of a freed run render nothing as active
  expect(laneDetails(view('closed_run')).join('\n')).not.toContain('orchestrated run')
})
