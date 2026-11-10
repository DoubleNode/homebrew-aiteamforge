// Pure helpers for the effort label and the prompt-cache clock (XACA-1639-005, 014, 015, 018).
// Own implementation, written from the behaviour in the plan; nothing is copied from the third-party
// cache-clock mod. No `$` here.
import { span } from './layout'

// ---- Effort label (005) ----------------------------------------------------------------------

export const EFFORT_LEVELS: readonly string[] = ['low', 'medium', 'high', 'xhigh', 'max']

type ConfigRowLike = { key: string; label: string; value: unknown }

/**
 * The effort level the /config menu holds, or null. The engine types name no effort row, so a row is
 * taken to be the effort row when its key or label says "effort"; its value counts only when it is one
 * of the levels (an `auto` or `unset` menu says nothing a request could be compared with).
 */
export function menuEffort(rows: readonly ConfigRowLike[]): string | null {
  const row = rows.find(r => /effort/i.test(r.key) || /effort/i.test(r.label))
  if (row === undefined) return null
  const value = typeof row.value === 'string' ? row.value.trim().toLowerCase() : null

  return value !== null && EFFORT_LEVELS.includes(value) ? value : null
}

/**
 * The footer label for what the main chat's last request carried. Hidden (null) when nothing was sent,
 * or when it equals what the menu holds. When the menu setting cannot be read, the reference is the
 * first effort this session sent: the label then flags a change from that, never the first level.
 */
export function effortLabel(sent: string | null, menu: string | null, base: string | null): string | null {
  if (sent === null) return null
  const reference = menu ?? base
  if (reference === null || sent === reference) return null

  return `Effort ${sent}`
}

// ---- Prompt cache clock (014, 015) --------------------------------------------------------------

export const TTL_5M = 5 * 60_000
export const TTL_1H = 60 * 60_000
/** A cold send is held (018) only when the context is at least this many tokens. */
export const GUARD_MIN_TOKENS = 50_000

export type CacheClock = {
  /** The cache lifetime the main chat's last write used (or is guessed to have used). */
  ttlMs: number
  /** `detected`: read from the transcript's cache_creation split. `guess`: a readable transcript with no split. */
  ttlSource: 'detected' | 'guess'
  /** When the last main-chat reply ended (the clock's ms). */
  lastEnd: number
  /** Context size at that point in tokens; null when the host did not say. */
  contextTokens: number | null
}

export type TtlReading = { ttlMs: number; ttlSource: 'detected' | 'guess' }

type Json = Record<string, unknown>
const obj = (v: unknown): Json | null => (v !== null && typeof v === 'object' && !Array.isArray(v) ? (v as Json) : null)
const num = (v: unknown): number => (typeof v === 'number' && Number.isFinite(v) ? v : 0)

/**
 * The cache length from the tail of a session transcript (JSON lines): the newest main-thread assistant
 * record whose usage.cache_creation split is non-zero. 1h only when nothing was written at 5m (mixed
 * writes count as 5m: the shorter life is the one the next message can lose).
 * `guess` when assistant records were read but none wrote the cache; null when none could be read at all.
 */
export function parseCacheTtl(tail: string): TtlReading | null {
  let sawAssistant = false
  const lines = tail.split('\n')
  for (let i = lines.length - 1; i >= 0; i--) {
    const line = lines[i]?.trim() ?? ''
    if (line === '') continue
    let rec: Json | null
    try {
      rec = obj(JSON.parse(line) as unknown)
    } catch {
      continue
    }
    if (rec === null || rec.type !== 'assistant' || rec.isSidechain === true) continue
    const usage = obj(obj(rec.message)?.usage)
    if (usage === null) continue
    sawAssistant = true
    const split = obj(usage.cache_creation)
    const m5 = num(split?.ephemeral_5m_input_tokens)
    const h1 = num(split?.ephemeral_1h_input_tokens)
    if (m5 > 0) return { ttlMs: TTL_5M, ttlSource: 'detected' }
    if (h1 > 0) return { ttlMs: TTL_1H, ttlSource: 'detected' }
  }

  return sawAssistant ? { ttlMs: TTL_5M, ttlSource: 'guess' } : null
}

/** `3:07` for a countdown, `1:02:09` past an hour. */
export function clock(ms: number): string {
  const s = Math.max(0, Math.floor(ms / 1000))
  const h = Math.floor(s / 3600)
  const m = Math.floor((s % 3600) / 60)
  const sec = String(s % 60).padStart(2, '0')

  return h > 0 ? `${h}:${String(m).padStart(2, '0')}:${sec}` : `${m}:${sec}`
}

/** 412_345 -> 412k, 1_250_000 -> 1.3M. */
export function tokens(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`
  if (n >= 1000) return `${Math.round(n / 1000)}k`

  return String(n)
}

/** The local time of day for a moment, 24-hour. */
export function timeOfDay(at: number, utcOffsetMin: number): string {
  const d = new Date(at + utcOffsetMin * 60_000)

  return `${String(d.getUTCHours()).padStart(2, '0')}:${String(d.getUTCMinutes()).padStart(2, '0')}`
}

export const ttlName = (ms: number): string => (ms >= TTL_1H ? '1h' : '5m')

export type CacheView = { state: 'warm'; left: number; soon: boolean } | { state: 'cold'; since: number }

export function cacheView(c: CacheClock | null, now: number): CacheView | null {
  if (c === null) return null
  const left = c.lastEnd + c.ttlMs - now

  return left > 0 ? { state: 'warm', left, soon: left <= 60_000 } : { state: 'cold', since: c.lastEnd + c.ttlMs }
}

/** What a cold re-write costs, in plain words (multipliers are the published cache prices). */
export function coldCost(c: CacheClock): string | null {
  if (c.contextTokens === null) return null
  const mult = c.ttlMs >= TTL_1H ? 2 : 1.25

  return `~${tokens(c.contextTokens)} tokens re-written at ${mult}x the input rate (a warm read is 0.1x)`
}

/**
 * The text of the line above the prompt. Glyph and words both say the state, so colour is never the
 * only cue. null when there is nothing to say.
 */
export function cacheText(
  c: CacheClock | null,
  now: number,
  utcOffsetMin: number,
): { text: string; level: 'ok' | 'soon' | 'cold' } | null {
  const v = cacheView(c, now)
  if (v === null || c === null) return null
  const ttl = `${ttlName(c.ttlMs)} TTL${c.ttlSource === 'guess' ? ' (guess)' : ''}`
  const size = c.contextTokens === null ? '' : ` · ${tokens(c.contextTokens)} tokens`
  if (v.state === 'warm') {
    return v.soon
      ? { text: `◐ cache cooling · ${clock(v.left)} left · ${ttl}${size}`, level: 'soon' }
      : { text: `◉ cache warm · ${clock(v.left)} left · ${ttl}${size}`, level: 'ok' }
  }
  const ago = span(now - v.since)
  const rewrite = c.contextTokens === null ? '' : ` · next message re-writes ~${tokens(c.contextTokens)} tokens`

  return { text: `◌ cache cold since ${timeOfDay(v.since, utcOffsetMin)} (${ago} ago)${rewrite} · ${ttl}`, level: 'cold' }
}

// ---- Cold-send guard (018) ------------------------------------------------------------------------

/**
 * Whether a held prompt can be put back exactly as sent: the person's own composer, plain non-empty text,
 * and nothing else. `prompt.fill` restores text only and fills the LOCAL box, so an attachment, a remote
 * (bridge) sender or any shape this does not recognise is never held. Fails toward not holding.
 */
export function isRestorable(e: { text?: unknown; origin?: unknown; attachments?: unknown }): boolean {
  const origin = e.origin
  if (origin === null || typeof origin !== 'object' || (origin as { kind?: unknown }).kind !== 'composer') return false
  if (typeof e.text !== 'string' || e.text.trim() === '') return false
  if (e.attachments === undefined) return true

  return Array.isArray(e.attachments) && e.attachments.length === 0
}
