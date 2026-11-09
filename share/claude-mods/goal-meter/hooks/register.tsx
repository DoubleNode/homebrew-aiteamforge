import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Goal, GoalSummary, GoalTask, TaskStatus } from '../types'
import { DONE_SHOWS_MS, GREEN, AMBER, duration, goalName, layoutBand, progress, taskTime } from './layout'
import { createSwitch } from './switches'
import type { SwitchIo } from './switches'

const PANE = 'goal-meter'
const KEEP_GOALS = 5
const TICK_MS = 15_000

// Change a tag when that value's fields change: it declines what an older
// version stored, which outlives a reload.
const goal = atom({ plugin: 'goal-meter', key: 'goal' } as const, null, { shape: 'goal-1' })
const history = atom({ plugin: 'goal-meter', key: 'history' } as const, [], { shape: 'history-1' })
const prompt = atom({ plugin: 'goal-meter', key: 'prompt' } as const, '')
const tick = atom({ plugin: 'goal-meter', key: 'tick' } as const, 0)
// On/off and shown/hidden live in the shared switch file (hooks/switches.ts), read by every chat.
const sw = createSwitch('goal-meter')

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
  '/goals         open the Goals pane: every task and the last 5 goals',
  '/goals on      turn the goal meter on in every chat (remembered)',
  '/goals off     turn it off: no tracking, no band (remembered)',
  '/goals hide    hide the band but keep tracking; /goals show brings it back',
  '/goals clear   forget the current goal and the history',
  '/goals help    this text',
].join('\n')

type Todo = { content: string; status: 'pending' | 'in_progress' | 'completed'; activeForm?: string }

function statusOf(s: string): TaskStatus {
  return s === 'completed' ? 'done' : s === 'in_progress' ? 'running' : 'pending'
}

function summary(g: Goal): GoalSummary {
  return {
    name: g.name,
    startedAt: g.startedAt,
    doneAt: g.doneAt,
    total: g.tasks.length,
    done: g.tasks.filter(t => t.status === 'done').length,
  }
}

// A task moving to a status: stamps when it starts and when it finishes.
function moved(task: GoalTask, status: TaskStatus, at: number): GoalTask {
  if (task.status === status) return task

  return {
    ...task,
    status,
    startedAt: status === 'running' && task.startedAt === null ? at : task.startedAt,
    doneAt: status === 'done' ? at : null,
  }
}

function newTask(id: string, title: string, active: string | null, status: TaskStatus, at: number): GoalTask {
  return {
    id,
    title,
    active,
    status,
    firstSeenAt: at,
    startedAt: status === 'pending' ? null : at,
    doneAt: status === 'done' ? at : null,
  }
}

async function archive($: EngineInterface, old: Goal | null): Promise<void> {
  if (old === null || old.tasks.length === 0) return
  const list = await update($, history, h => [summary(old), ...h].slice(0, KEEP_GOALS))
  await $.store.set('history', list)
}

// Swap in the next goal; the one it replaces goes to the history unless it
// finished, which was archived as it did.
async function replaceGoal($: EngineInterface, next: Goal | null): Promise<void> {
  const old = await read($, goal)
  if (old !== null && old.doneAt === null) await archive($, old)
  await update($, goal, () => next)
}

// After every change: a goal whose tasks are all done is finished, once.
async function settle($: EngineInterface, at: number): Promise<void> {
  const g = await read($, goal)
  if (g === null || g.doneAt !== null || g.tasks.length === 0) return
  if (!g.tasks.every(t => t.status === 'done')) return

  const done: Goal = { ...g, doneAt: at }
  await update($, goal, () => done)
  await archive($, done)
  await update($, tick, () => at)
  const took = duration(at - g.startedAt)
  $.ui.toast(`Goal done in ${took} — ${g.tasks.length} task${g.tasks.length === 1 ? '' : 's'}`)
}

async function fresh($: EngineInterface, at: number, tasks: GoalTask[]): Promise<Goal> {
  return { name: goalName(await read($, prompt)), startedAt: at, doneAt: null, tasks }
}

// TodoWrite hands over the whole list each time.
async function onTodos($: EngineInterface, todos: readonly Todo[], at: number): Promise<void> {
  const cur = await read($, goal)
  if (todos.length === 0) {
    await replaceGoal($, null)
    return
  }

  const titles = new Set(todos.map(t => t.content))
  // A list that only repeats a finished goal changes nothing.
  const isRepeat =
    cur !== null &&
    cur.doneAt !== null &&
    cur.tasks.every(t => titles.has(t.title)) &&
    todos.every(t => t.status === 'completed')
  if (isRepeat) return
  // The same goal while it runs and the list still shares a task with it.
  const isSameGoal = cur !== null && cur.doneAt === null && cur.tasks.some(t => titles.has(t.title))

  if (!isSameGoal) {
    const tasks = todos.map((t, i) => newTask(`todo-${i}`, t.content, t.activeForm ?? null, statusOf(t.status), at))
    await replaceGoal($, await fresh($, at, tasks))
  } else {
    const byTitle = new Map(cur.tasks.map(t => [t.title, t]))
    const tasks = todos.map((t, i) => {
      const was = byTitle.get(t.content)
      const status = statusOf(t.status)

      return was === undefined
        ? newTask(`todo-${i}`, t.content, t.activeForm ?? null, status, at)
        : { ...moved(was, status, at), active: t.activeForm ?? was.active }
    })
    await update($, goal, () => ({ ...cur, tasks }))
  }
  await settle($, at)
}

async function onTaskCreate($: EngineInterface, id: string, title: string, active: string | null, at: number): Promise<void> {
  const cur = await read($, goal)
  const task = newTask(id, title, active, 'pending', at)
  if (cur === null || cur.doneAt !== null) {
    await replaceGoal($, await fresh($, at, [task]))
  } else {
    await update($, goal, () => ({ ...cur, tasks: [...cur.tasks, task] }))
  }
}

async function onTaskUpdate($: EngineInterface, id: string, status: string | undefined, title: string | undefined, at: number): Promise<void> {
  const cur = await read($, goal)
  if (cur === null || !cur.tasks.some(t => t.id === id)) return

  const tasks =
    status === 'deleted'
      ? cur.tasks.filter(t => t.id !== id)
      : cur.tasks.map(t => {
          if (t.id !== id) return t
          const renamed = title === undefined ? t : { ...t, title }

          return status === undefined ? renamed : moved(renamed, statusOf(status), at)
        })
  await update($, goal, () => ({ ...cur, tasks }))
  await settle($, at)
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'goals',
      description: 'Goal progress: pane, or on | off | clear | help',
      argumentHint: '[on|off|clear|help]',
    })
    await sw.start(switchIo($), () => {
      $.ui.invalidate('ui.render')
    })
    const saved = await $.store.get('history')
    if (Array.isArray(saved)) await update($, history, () => saved as GoalSummary[])

    // Redraw on a timer while a goal shows: its clock moves, and a finished
    // goal leaves the band after two minutes.
    $.clock.every(TICK_MS, () => {
      if (sw.off) return
      void (async () => {
        const g = await read($, goal)
        const at = await $.clock.now()
        if (g !== null && (g.doneAt === null || at - g.doneAt < DONE_SHOWS_MS + TICK_MS)) {
          await update($, tick, () => at)
        }
      })()
    })

    return next(e)
  })

  on('command.run', { command: 'goals' }, async ($, e) => {
    const arg = e.args.trim().toLowerCase()

    if (arg === '' && sw.off) return { text: 'Goal meter is off. Turn it on with /goals on, or in /mods.' }
    if (arg === '') {
      const { isPlaced } = await $.ui.open({ id: PANE, title: 'Goals' })

      return { text: isPlaced ? 'Goals pane opened.' : 'Goals pane opens once there is room for it.' }
    }
    if (arg === 'on' || arg === 'off' || arg === 'hide' || arg === 'show') {
      const patch = arg === 'on' ? { off: false, hidden: false } : arg === 'off' ? { off: true } : { hidden: arg === 'hide' }
      if (!(await sw.set(switchIo($), patch))) return { text: 'Goal meter: could not save the switch (switches.json is unreadable).' }

      return { text: `Goal band ${arg}.` }
    }
    if (arg === 'clear') {
      await update($, goal, () => null)
      await update($, history, () => [])
      await $.store.set('history', [])

      return { text: 'Goals cleared.' }
    }
    if (arg === 'help') return { text: HELP }

    return { text: `Unknown option "${arg}".\n${HELP}` }
  })

  // The prompt a goal is named for: the person's, not a turn the engine
  // started itself (a task notification, a continuation).
  on('turn.start', async ($, e, next) => {
    if (!sw.off && e.agentId === undefined && e.text.trim() !== '' && !/^\s*<[\w-]+>/.test(e.text)) {
      await update($, prompt, () => e.text)
    }

    return next(e)
  })

  on('tool.call', { tool: /^(TodoWrite|TaskCreate|TaskUpdate)$/ }, async ($, e, next) => {
    // Subagents keep task lists of their own; the goal is the main chat's.
    if (sw.off || e.agentId !== undefined) return next(e)

    const ran = await next(e)
    if (ran.deny !== undefined || ran.isError === true) return ran
    const at = await $.clock.now()
    const input = e as unknown as Record<string, unknown>

    if (e.tool === 'TodoWrite' && Array.isArray(input.todos)) {
      await onTodos($, input.todos as Todo[], at)
    } else if (e.tool === 'TaskCreate') {
      const made = (ran.result as { task?: { id?: unknown } } | undefined)?.task
      if (typeof made?.id === 'string') {
        const active = typeof input.activeForm === 'string' ? input.activeForm : null
        await onTaskCreate($, made.id, String(input.subject ?? ''), active, at)
      }
    } else if (e.tool === 'TaskUpdate' && typeof input.taskId === 'string') {
      const status = typeof input.status === 'string' ? input.status : undefined
      const title = typeof input.subject === 'string' ? input.subject : undefined
      await onTaskUpdate($, input.taskId, status, title, at)
    }

    return ran
  }).catch(($, e, next) => next(e)) // an observer never blocks a tool

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const below = await next(e)
    if (e.props.hasSurvey || !sw.shown) return below

    const g = await read($, goal)
    await read($, tick)
    const now = await $.clock.now()
    if (g === null || g.tasks.length === 0) return below
    if (g.doneAt !== null && now - g.doneAt >= DONE_SHOWS_MS) return below

    const { Box, Text } = $.ui.resolve(e)

    return (
      <Box flexDirection="column">
        <Text wrap="truncate-end">
          {layoutBand(g, now, e.props.bodyColumns).map(s => (
            <Text color={s.color} backgroundColor={s.bg} weight={s.isBold ? 'bold' : undefined} dimColor={s.isDim}>
              {s.text}
            </Text>
          ))}
        </Text>
        {below}
      </Box>
    )
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text } = $.ui.resolve(e)
    const g = await read($, goal)
    const past = await read($, history)
    await read($, tick)
    const now = await $.clock.now()
    const p = g === null ? null : progress(g, now)
    const MARK: Record<TaskStatus, { mark: string; color?: string }> = {
      running: { mark: '▶', color: p?.isSlow ? AMBER : GREEN },
      done: { mark: '✓', color: GREEN },
      pending: { mark: '○' },
    }

    return (
      <Box flexDirection="column">
        {g === null || p === null ? (
          <Text dimColor>No goal yet. One starts when Claude makes a task list.</Text>
        ) : (
          <Box flexDirection="column">
            <Text weight="bold" wrap="truncate-end">
              {g.name}
            </Text>
            <Text dimColor>
              {p.done}/{p.total} · {p.percent}% · {duration(p.elapsedMs)}
              {g.doneAt !== null ? ' · done ✓' : p.etaMs === null ? '' : ` · ETA ~${duration(p.etaMs)}`}
            </Text>
            {g.tasks.map(t => (
              <Text wrap="truncate-end">
                <Text color={MARK[t.status].color}>{MARK[t.status].mark}</Text> {t.title}
                <Text dimColor>{t.status === 'pending' ? '' : `  ${duration(taskTime(t, now))}`}</Text>
                {t.status === 'running' && p.isSlow && <Text color={AMBER}> · slow</Text>}
              </Text>
            ))}
          </Box>
        )}
        <Text> </Text>
        <Text weight="bold">Last goals</Text>
        {past.length === 0 && <Text dimColor>None yet.</Text>}
        {past.map(s => (
          <Text wrap="truncate-end">
            <Text color={s.doneAt === null ? undefined : GREEN}>{s.doneAt === null ? '○' : '✓'}</Text> {s.name}
            <Text dimColor>
              {'  '}
              {s.done}/{s.total}
              {s.doneAt === null ? ' · stopped' : ` · ${duration(s.doneAt - s.startedAt)}`}
            </Text>
          </Text>
        ))}
      </Box>
    )
  })
}
