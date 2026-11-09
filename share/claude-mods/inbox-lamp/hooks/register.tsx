import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Mail } from '../types'
import { createSwitch } from './switches'
import type { SwitchIo } from './switches'

const POLL_MS = 60_000
const RECENT_MS = 12 * 60 * 60_000
const CHIP = { text: ' ✉ INBOX ', color: '#0b0b0f', calm: '#22d3ee', alarm: '#ef4444' }
const RED = 'error'
const AMBER = 'warning'
// What a freeze or merge-order instruction looks like in practice.
export const URGENT =
  /\b(freeze|frozen|merge[- ]order|do not merge|don'?t merge|hold (off )?(on )?merg\w*|do not push|don'?t push|stop push\w*)/i

const EMPTY: Mail = {
  address: null,
  unread: 0,
  newestFrom: null,
  newestBody: null,
  urgentUnread: 0,
  urgentRecent: 0,
  checkedAt: 0,
  error: null,
}

const mail = atom({ plugin: 'inbox-lamp', key: 'mail' } as const, EMPTY, { shape: 'mail-1' })
// On/off and shown/hidden live in the shared switch file (hooks/switches.ts), read by every chat.
const sw = createSwitch('inbox-lamp')

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
  '/inbox-lamp           check the inbox now',
  '/inbox-lamp on|off    turn the lamp on or off in every chat (remembered)',
  '/inbox-lamp hide|show hide the line but keep polling, or show it again',
  '/inbox-lamp help      this text',
  'Read mail with kb-msg inbox / kb-msg read <id>: the lamp never marks anything read.',
].join('\n')

type Record = {
  from_team?: string
  from_terminal?: string
  body?: string
  created_at?: string
  read_at?: string | null
}

function cut(text: string, max: number): string {
  const flat = text.replace(/\s+/g, ' ').trim()
  const chars = [...flat]

  return chars.length <= max ? flat : `${chars.slice(0, max - 1).join('')}…`
}

// The same address the inbox hook resolves: the tmux session name
// <team>-<terminal>, else KB_TEAM / KB_TERMINAL.
async function address($: EngineInterface): Promise<{ team: string; terminal: string } | null> {
  const pane = await $.env.get('TMUX_PANE')
  if (pane !== undefined && pane !== '') {
    const ran = await $.process
      .run(['tmux', 'display-message', '-t', pane, '-p', '#S'], { timeoutMs: 5000 })
      .catch(() => null)
    const name = ran?.exitCode === 0 ? ran.stdout.trim() : ''
    const dash = name.lastIndexOf('-')
    if (dash > 0) return { team: name.slice(0, dash), terminal: name.slice(dash + 1) }
  }
  const team = await $.env.get('KB_TEAM')
  if (team === undefined || team === '') return null

  return { team, terminal: (await $.env.get('KB_TERMINAL')) || 'agent' }
}

async function storePath($: EngineInterface): Promise<string | null> {
  const home = await $.env.get('HOME')
  const bases = [await $.env.get('AITEAMFORGE_DIR'), home && `${home}/aiteamforge`, home && `${home}/dev-team`]
  for (const base of bases) {
    if (base === undefined || base === '') continue
    const path = `${base}/kanban-hooks/msg-store.py`
    if (await $.fs.exists(path).catch(() => false)) return path
  }

  return null
}

export function summarize(records: readonly Record[], now: number): Omit<Mail, 'address' | 'checkedAt' | 'error'> {
  const unread = records.filter(r => !r.read_at)
  const newest = [...unread].sort((a, b) => (a.created_at ?? '').localeCompare(b.created_at ?? '')).at(-1)
  const isRecent = (r: Record) => {
    const at = Date.parse(r.read_at ?? r.created_at ?? '')

    return !Number.isNaN(at) && now - at <= RECENT_MS
  }

  return {
    unread: unread.length,
    newestFrom: newest === undefined ? null : `${newest.from_team ?? '?'}:${newest.from_terminal ?? '?'}`,
    newestBody: newest?.body ?? null,
    urgentUnread: unread.filter(r => URGENT.test(r.body ?? '')).length,
    urgentRecent: records.filter(r => r.read_at && isRecent(r) && URGENT.test(r.body ?? '')).length,
  }
}

async function check($: EngineInterface): Promise<void> {
  const at = await $.clock.now()
  const who = await address($)
  const store = await storePath($)
  if (who === null || store === null) {
    await update($, mail, () => ({ ...EMPTY, checkedAt: at, error: who === null ? 'no address' : 'no msg-store' }))
    return
  }

  const label = `${who.team}:${who.terminal}`
  const ran = await $.process
    .run(['python3', store, 'inbox', '--team', who.team, '--terminal', who.terminal, '--all', '--json'], {
      timeoutMs: 10_000,
    })
    .catch(() => null)
  let records: Record[] | null = null
  if (ran?.exitCode === 0) {
    try {
      const parsed: unknown = JSON.parse(ran.stdout || '[]')
      if (Array.isArray(parsed)) records = parsed as Record[]
    } catch {
      records = null
    }
  }

  if (records === null) {
    // Keep what we knew; say the read failed.
    await update($, mail, m => ({ ...m, address: label, checkedAt: at, error: 'inbox unreadable' }))
    return
  }
  const seen = summarize(records, at)
  await update($, mail, () => ({ ...seen, address: label, checkedAt: at, error: null }))
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'inbox-lamp',
      description: 'kb-msg inbox line: check now, or on | off | help',
      argumentHint: '[on|off|help]',
    })
    await sw.start(switchIo($), () => {
      void check($)
      $.ui.invalidate('ui.render')
    })
    $.clock.every(POLL_MS, () => {
      if (!sw.off) void check($)
    })
    if (!sw.off) void check($)

    return next(e)
  })

  // Mail often lands while a turn runs; look again as each one ends.
  on('turn.complete', async ($, e, next) => {
    if (e.agentId === undefined && !sw.off) void check($)

    return next(e)
  })

  on('command.run', { command: 'inbox-lamp' }, async ($, e) => {
    const arg = e.args.trim().toLowerCase()
    if (arg === 'on' || arg === 'off' || arg === 'hide' || arg === 'show') {
      const patch = arg === 'on' ? { off: false, hidden: false } : arg === 'off' ? { off: true } : { hidden: arg === 'hide' }
      if (!(await sw.set(switchIo($), patch))) return { text: 'Inbox lamp: could not save the switch (switches.json is unreadable).' }

      return { text: `Inbox lamp ${arg}.` }
    }
    if (arg === 'help') return { text: HELP }
    if (arg !== '') return { text: `Unknown option "${arg}".\n${HELP}` }

    await check($)
    const m = await read($, mail)
    if (m.error !== null && m.address === null) return { text: `Inbox lamp: ${m.error}.` }

    return { text: `${m.address}: ${m.unread} unread${m.urgentUnread > 0 ? `, ${m.urgentUnread} freeze/merge-order` : ''}.` }
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const below = await next(e)
    if (e.props.hasSurvey || !sw.shown) return below

    const m = await read($, mail)
    if (m.address === null || (m.unread === 0 && m.urgentRecent === 0 && m.error === null)) return below

    const isAlarm = m.urgentUnread > 0
    const { Box, Text } = $.ui.resolve(e)
    const body = m.newestBody === null ? '' : ` "${cut(m.newestBody, Math.max(16, e.props.bodyColumns - 60))}"`

    return (
      <Box flexDirection="column">
        <Text wrap="truncate-end">
          <Text color={CHIP.color} backgroundColor={isAlarm ? CHIP.alarm : CHIP.calm} weight="bold">
            {CHIP.text}
          </Text>
          {m.unread > 0 && <Text weight="bold"> {m.unread} unread</Text>}
          {isAlarm && <Text color={RED}> · ⚠ {m.urgentUnread} freeze/merge-order</Text>}
          {m.urgentRecent > 0 && <Text color={AMBER}> · ⚑ {m.urgentRecent} read in 12h</Text>}
          {m.error !== null && <Text dimColor> · {m.error}</Text>}
          {m.newestFrom !== null && (
            <Text dimColor>
              {' '}
              · newest {m.newestFrom}
              {body}
            </Text>
          )}
        </Text>
        {below}
      </Box>
    )
  })
}
