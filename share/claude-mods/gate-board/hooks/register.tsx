import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Checks, Gates, Verdict } from '../types'
import { createSwitch } from './switches'
import type { SwitchIo } from './switches'

const POLL_MS = 120_000
const MIN_GAP_MS = 30_000
const MERGED_SHOWS_MS = 10 * 60_000
// How long the last good reading survives a failing gh (offline, signed out): a blip, not a figure to keep.
const KEEP_MS = 5 * 60_000
const CHIP = { text: ' ⛭ GATES ', color: '#0b0b0f', bg: '#a78bfa' }
const GREEN = 'success'
const AMBER = 'warning'
const RED = 'error'
const TESTER = /^ds9-tester-bot(\[bot\])?$/
const REVIEWER = /^ai-security-review-bot(\[bot\])?$/
const TRUNKS = new Set(['develop', 'main', 'master', ''])
const PROTECTED = /^\[(Review|Test|UX)\]/
const RESOLVED = new Set(['completed', 'cancelled'])

const gates = atom({ plugin: 'gate-board', key: 'gates' } as const, null, { shape: 'gates-1' })
// On/off and shown/hidden live in the shared switch file (hooks/switches.ts), read by every chat.
const sw = createSwitch('gate-board')

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

const HELP = [
  '/gate-board          check the gates now',
  '/gate-board on|off   turn the board on or off in every chat (remembered)',
  '/gate-board hide|show  hide the line but keep checking, or show it again',
  '/gate-board help     this text',
  'A hint, not the gate: scripts/kb-pr-monitor still decides what merges.',
].join('\n')

type Review = { author?: { login?: string }; state?: string; commit?: { oid?: string } }
type Check = { conclusion?: string | null; status?: string; state?: string }
type PrView = { number: number; state: string; headRefOid: string; reviews?: Review[]; statusCheckRollup?: Check[] }
type Sub = { title?: string; status?: string }
type Item = { id?: string; subitems?: Sub[] }

export function verdict(reviews: readonly Review[], who: RegExp, head: string): Verdict {
  const mine = reviews.filter(r => who.test(r.author?.login ?? '') && r.state !== 'COMMENTED')
  const last = mine.at(-1)
  if (last === undefined) return 'pending'
  if (last.state === 'CHANGES_REQUESTED') return 'changes'
  if (last.state !== 'APPROVED') return 'pending'

  return last.commit?.oid !== undefined && last.commit.oid !== head ? 'stale' : 'approved'
}

export function checks(rollup: readonly Check[]): Checks {
  const out: Checks = { total: rollup.length, passed: 0, failed: 0, pending: 0 }
  for (const c of rollup) {
    const word = (c.conclusion ?? c.state ?? '').toUpperCase()
    if (['SUCCESS', 'NEUTRAL', 'SKIPPED'].includes(word)) out.passed += 1
    else if (['FAILURE', 'TIMED_OUT', 'CANCELLED', 'ACTION_REQUIRED', 'ERROR', 'STARTUP_FAILURE'].includes(word)) {
      out.failed += 1
    } else out.pending += 1
  }

  return out
}

export function openProtected(items: readonly Item[], id: string): number | null {
  const item = items.find(i => i.id === id)
  if (item === undefined) return null

  // A subitem with no status is todo, never resolved.
  return (item.subitems ?? []).filter(s => PROTECTED.test(s.title ?? '') && !RESOLVED.has(s.status ?? 'todo')).length
}

async function run($: EngineInterface, argv: string[]): Promise<string | null> {
  const ran = await $.process.run(argv, { timeoutMs: 20_000 }).catch(() => null)

  return ran?.exitCode === 0 ? ran.stdout : null
}

// The board that holds the item: <repo>/kanban for teams that keep it in the
// repo, <repo>/../kanban for those that keep it beside.
async function sweep($: EngineInterface, id: string): Promise<number | null> {
  const common = (await run($, ['git', 'rev-parse', '--path-format=absolute', '--git-common-dir']))?.trim()
  if (common === undefined || common === '') return null
  const root = common.replace(/\/\.git\/?$/, '')
  for (const dir of [`${root}/kanban`, `${root.replace(/\/[^/]+$/, '')}/kanban`]) {
    const entries = await $.fs.list(dir).catch(() => [])
    for (const entry of entries) {
      if (!entry.name.endsWith('-board.json')) continue
      const text = await $.fs.read(`${dir}/${entry.name}`).catch(() => null)
      if (typeof text !== 'string') continue
      try {
        const board = JSON.parse(text) as { backlog?: Item[] }
        const open = openProtected(board.backlog ?? [], id)
        if (open !== null) return open
      } catch {
        continue
      }
    }
  }

  return null
}

async function check($: EngineInterface): Promise<void> {
  const at = await $.clock.now()
  const branch = (await run($, ['git', 'branch', '--show-current']))?.trim() ?? ''
  if (TRUNKS.has(branch)) {
    await update($, gates, () => null)
    return
  }

  const raw = await run($, ['gh', 'pr', 'view', '--json', 'number,state,headRefOid,reviews,statusCheckRollup'])
  let pr: PrView | null = null
  try {
    pr = raw === null ? null : (JSON.parse(raw) as PrView)
  } catch {
    pr = null
  }
  if (pr === null) {
    // No PR for this branch, or gh is missing, signed out or offline: nothing to show.
    // A reading from a moment ago rides out a blip; an old one is dropped, never kept as current.
    await update($, gates, g => (g !== null && g.branch === branch && at - g.checkedAt < KEEP_MS ? g : null))
    return
  }

  const itemId = /([A-Za-z]+-\d+)/.exec(branch)?.[1]?.toUpperCase() ?? null
  const sweepOpen = itemId === null ? null : await sweep($, itemId)
  const reviews = pr.reviews ?? []
  const head = pr.headRefOid
  const state: Gates['state'] = pr.state === 'MERGED' ? 'MERGED' : pr.state === 'CLOSED' ? 'CLOSED' : 'OPEN'
  await update($, gates, g => ({
    branch,
    pr: pr.number,
    state,
    test: verdict(reviews, TESTER, head),
    review: verdict(reviews, REVIEWER, head),
    ci: checks(pr.statusCheckRollup ?? []),
    itemId,
    sweepOpen,
    checkedAt: at,
    mergedSeenAt: state === 'MERGED' ? (g?.pr === pr.number && g.mergedSeenAt !== null ? g.mergedSeenAt : at) : null,
  }))
}

const MARK: Record<Verdict, { text: string; color: string }> = {
  approved: { text: '✓', color: GREEN },
  changes: { text: '✗', color: RED },
  pending: { text: '⟳', color: AMBER },
  stale: { text: '✓ stale', color: AMBER },
}

export const register: Register = on => {
  let lastCheck = 0

  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'gate-board',
      description: 'PR gates line: check now, or on | off | help',
      argumentHint: '[on|off|help]',
    })
    await sw.start(switchIo($), () => {
      if (!sw.off) void check($).catch(() => undefined)
      $.ui.invalidate('ui.render')
    })
    $.clock.every(POLL_MS, () => {
      if (!sw.off) void check($)
    })
    if (!sw.off) void check($)

    return next(e)
  })

  // Pushes and gate runs happen during turns; look again as one ends.
  on('turn.complete', async ($, e, next) => {
    const at = await $.clock.now()
    if (e.agentId === undefined && !sw.off && at - lastCheck >= MIN_GAP_MS) {
      lastCheck = at
      void check($)
    }

    return next(e)
  })

  on('command.run', { command: 'gate-board' }, async ($, e) => {
    const arg = e.args.trim().toLowerCase()
    if (arg === 'on' || arg === 'off' || arg === 'hide' || arg === 'show') {
      const patch = arg === 'on' ? { off: false, hidden: false } : arg === 'off' ? { off: true } : { hidden: arg === 'hide' }
      if (!(await sw.set(switchIo($), patch))) return { text: 'Gate board: could not save the switch (switches.json is unreadable).' }

      return { text: `Gate board ${arg}.` }
    }
    if (arg === 'help') return { text: HELP }
    if (arg !== '') return { text: `Unknown option "${arg}".\n${HELP}` }

    await check($)
    const g = await read($, gates)

    return { text: g === null ? 'No PR found for this branch (or gh is not signed in).' : `PR #${g.pr}: ${g.state.toLowerCase()}.` }
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const below = await next(e)
    if (e.props.hasSurvey || !sw.shown) return below

    const g = await read($, gates)
    const now = await $.clock.now()
    if (g === null || g.state === 'CLOSED') return below
    if (g.mergedSeenAt !== null && now - g.mergedSeenAt >= MERGED_SHOWS_MS) return below

    const { Box, Text } = $.ui.resolve(e)
    const ci = g.ci
    const ciSeg =
      ci.total === 0
        ? { text: 'CI –', color: undefined }
        : ci.failed > 0
          ? { text: `CI ✗ ${ci.failed} of ${ci.total}`, color: RED }
          : ci.pending > 0
            ? { text: `CI ${ci.passed}/${ci.total}`, color: AMBER }
            : { text: `CI ✓ ${ci.total}`, color: GREEN }

    return (
      <Box flexDirection="column">
        <Text wrap="truncate-end">
          <Text color={CHIP.color} backgroundColor={CHIP.bg} weight="bold">
            {CHIP.text}
          </Text>
          <Text weight="bold"> PR #{g.pr}</Text>
          {g.state === 'MERGED' ? (
            <Text color={GREEN}> merged ✓</Text>
          ) : (
            <Text>
              <Text dimColor> · test </Text>
              <Text color={MARK[g.test].color}>{MARK[g.test].text}</Text>
              <Text dimColor> · review </Text>
              <Text color={MARK[g.review].color}>{MARK[g.review].text}</Text>
              <Text dimColor> · </Text>
              <Text color={ciSeg.color}>{ciSeg.text}</Text>
              {g.sweepOpen !== null && <Text dimColor> · </Text>}
              {g.sweepOpen !== null && (
                <Text color={g.sweepOpen > 0 ? AMBER : GREEN}>
                  {g.sweepOpen > 0 ? `sweep ${g.sweepOpen} open` : 'sweep ✓'}
                </Text>
              )}
            </Text>
          )}
        </Text>
        {below}
      </Box>
    )
  })
}
