// Pure helpers: goal arithmetic and the band's segments. No `$` here.
import type { Goal, GoalTask } from '../types'

export const CHIP = { text: ' ◆ GOAL ', color: '#0b0b0f', bg: '#facc15' }
export const GREEN = 'success'
export const AMBER = 'warning'
export const BAR_CELLS = 6
export const DONE_SHOWS_MS = 2 * 60_000
const NAME_CHARS = 50

export type Seg = { text: string; color?: string; bg?: string; isBold?: boolean; isDim?: boolean }

export function cut(text: string, max: number): string {
  const flat = text.replace(/\s+/g, ' ').trim()
  const chars = [...flat]

  return chars.length <= max ? flat : `${chars.slice(0, Math.max(1, max - 1)).join('')}…`
}

// A goal is named for the first line of the prompt that started it.
export function goalName(prompt: string): string {
  const first = prompt.split('\n').find(line => line.trim() !== '') ?? ''

  return first === '' ? 'Current goal' : cut(first, NAME_CHARS)
}

export function duration(ms: number): string {
  const s = Math.max(0, Math.round(ms / 1000))
  if (s < 60) return `${s}s`
  const m = Math.round(s / 60)
  if (m < 60) return `${m}m`

  return `${Math.floor(m / 60)}h${String(m % 60).padStart(2, '0')}m`
}

export function taskTime(task: GoalTask, now: number): number {
  const from = task.startedAt ?? task.firstSeenAt

  return (task.doneAt ?? now) - from
}

export type Progress = {
  total: number
  done: number
  percent: number
  elapsedMs: number
  avgMs: number | null
  etaMs: number | null
  running: GoalTask | undefined
  isSlow: boolean
}

export function progress(goal: Goal, now: number): Progress {
  const total = goal.tasks.length
  const finished = goal.tasks.filter(t => t.status === 'done')
  const done = finished.length
  const avgMs =
    done === 0 ? null : finished.reduce((n, t) => n + taskTime(t, now), 0) / done
  const running = goal.tasks.find(t => t.status === 'running')
  const left = total - done

  return {
    total,
    done,
    percent: total === 0 ? 0 : Math.round((done / total) * 100),
    elapsedMs: (goal.doneAt ?? now) - goal.startedAt,
    avgMs,
    etaMs: avgMs === null || left === 0 ? null : avgMs * left,
    running,
    isSlow:
      avgMs !== null && avgMs > 0 && running !== undefined && taskTime(running, now) > 2 * avgMs,
  }
}

export function bar(done: number, total: number): string {
  const filled = total === 0 ? 0 : Math.round((done / total) * BAR_CELLS)

  return '▰'.repeat(filled) + '▱'.repeat(BAR_CELLS - filled)
}

function width(segs: readonly Seg[]): number {
  return segs.reduce((n, s) => n + [...s.text].length, 0)
}

// The band: chip, name, bar, counts, ETA, then the running task. The name
// gives up width (down to 12 cells) so the counts stay whole; the running
// task, last, is what the Text truncates.
export function layoutBand(goal: Goal, now: number, columns: number): Seg[] {
  const p = progress(goal, now)
  const chip: Seg = { text: CHIP.text, color: CHIP.color, bg: CHIP.bg, isBold: true }

  const counts: Seg[] =
    goal.doneAt !== null
      ? [
          { text: ' ' },
          { text: bar(p.total, p.total), color: GREEN },
          { text: ` done ✓ in ${duration(p.elapsedMs)}`, color: GREEN },
        ]
      : [
          { text: ' ' },
          { text: bar(p.done, p.total), color: p.isSlow ? AMBER : GREEN },
          { text: ` ${p.done}/${p.total} · ${p.percent}% · ${duration(p.elapsedMs)}${p.isSlow ? ' · slow' : ''}` },
          ...(p.etaMs === null ? [] : [{ text: ` · ETA ~${duration(p.etaMs)}`, isDim: true }]),
        ]
  const running: Seg[] =
    goal.doneAt !== null || p.running === undefined
      ? []
      : [
          { text: ' │ ', isDim: true },
          { text: `▶ ${p.running.active ?? p.running.title}`, color: p.isSlow ? AMBER : undefined },
        ]

  const room = columns - width([chip, ...counts]) - 1
  const name: Seg = { text: ` ${cut(goal.name, Math.max(12, Math.min(NAME_CHARS, room)))}`, isBold: true }

  return [chip, name, ...counts, ...running]
}
