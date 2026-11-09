// Pure helpers: window names, colors, reset times, pace. No `$` here.
import type { Reading } from '../types'

export const CHIP = { text: ' ◔ PLAN ', color: '#0b0b0f', bg: '#60a5fa' }
export const GREEN = 'success'
export const AMBER = 'warning'
export const RED = 'error'
export const PACE_GAP_MS = 5 * 60_000
const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']

export function short(kind: string): string {
  return kind === 'five_hour' ? '5h' : kind === 'seven_day' ? 'week' : kind
}

export function long(kind: string): string {
  return kind === 'five_hour' ? '5-hour limit' : kind === 'seven_day' ? 'Weekly limit' : `${kind} limit`
}

export function color(percent: number): string {
  return percent > 85 ? RED : percent >= 60 ? AMBER : GREEN
}

export function bar(percent: number, cells: number): string {
  const filled = Math.max(0, Math.min(cells, Math.round((percent / 100) * cells)))

  return '▰'.repeat(filled) + '▱'.repeat(cells - filled)
}

export function span(ms: number): string {
  const m = Math.max(0, Math.round(ms / 60_000))
  if (m < 60) return `${m}m`

  return `${Math.floor(m / 60)}h${String(m % 60).padStart(2, '0')}m`
}

// Within a day: a countdown (2h11m). Further: the local day and hour (Thu 9am).
export function resetLabel(resetsAt: string | null, now: number, utcOffsetMin: number): string | null {
  if (resetsAt === null) return null
  const at = Date.parse(resetsAt)
  if (Number.isNaN(at)) return null
  if (at - now < 24 * 60 * 60_000) return span(at - now)

  const local = new Date(at + utcOffsetMin * 60_000)
  const h = local.getUTCHours()
  const m = local.getUTCMinutes()
  const hour = `${h % 12 === 0 ? 12 : h % 12}${m === 0 ? '' : `:${String(m).padStart(2, '0')}`}${h < 12 ? 'am' : 'pm'}`

  return `${DAYS[local.getUTCDay()]} ${hour}`
}

export function usd(n: number): string {
  return `$${n.toFixed(2)}`
}

// Whether there are two readings far enough apart to judge a pace from.
export function hasPacePair(readings: readonly Reading[]): boolean {
  const newest = readings.at(-1)

  return newest !== undefined && readings.some(r => newest.at - r.at >= PACE_GAP_MS)
}

// Minutes until the five-hour window runs out at the rate between the newest
// reading and the newest one at least five minutes older; null when there is
// no such pair, no climb, or it lasts past the reset.
export function paceOutMs(readings: readonly Reading[], resetsAt: string | null, now: number): number | null {
  const newest = readings.at(-1)
  if (newest === undefined) return null
  const older = [...readings].reverse().find(r => newest.at - r.at >= PACE_GAP_MS)
  if (older === undefined) return null
  const rate = (newest.percent - older.percent) / (newest.at - older.at)
  if (rate <= 0) return null
  const outIn = (100 - newest.percent) / rate - (now - newest.at)
  const reset = resetsAt === null ? Number.NaN : Date.parse(resetsAt)
  if (!Number.isNaN(reset) && now + outIn >= reset) return null

  return Math.max(0, outIn)
}
