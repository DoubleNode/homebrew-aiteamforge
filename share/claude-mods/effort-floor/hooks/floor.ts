// Pure state rules for effort-floor (XACA-1640-003/004). Design (user decision 2026-11-10, "Hold and
// resume at High"): a turn.step effort rewrite on a tool-result step is ignored on a model that takes
// effort per message (measured: low/low/low), and tool.call always fires mid-turn. So the mod cannot
// raise the CURRENT turn. On Hold it denies the one high-stakes call and raises the NEXT turn's step 0
// (the step with the person's input, where a rewrite lands and stays for that turn's tool steps), then
// releases at that turn's end. Raise-only: it never writes a level at or below the one being sent.

import type { Floor, SignalClass } from '../types'

export type { Floor }
export type Level = 'low' | 'medium' | 'high' | 'xhigh' | 'max'
export const LEVELS: readonly Level[] = ['low', 'medium', 'high', 'xhigh', 'max']
export const FLOOR: Level = 'high'

export const EMPTY: Floor = {
  sent: null,
  turnId: null,
  offeredTurn: null,
  cancelledTurn: null,
  pending: null,
  active: null,
  counts: { offered: 0, held: 0, ran: 0, cancelled: 0 },
}

/** A level's rank, or -1 for anything else (a number budget, none): never treated as below the floor. */
export const rank = (e: unknown): number => (typeof e === 'string' ? LEVELS.indexOf(e as Level) : -1)

/** Below the floor: a known level under `high`. A number or no effort is never offered on. */
export const isBelowFloor = (e: unknown): boolean => {
  const r = rank(e)

  return r >= 0 && r < rank(FLOOR)
}

/** While a hold waits for the next message, every high-stakes call is refused, without asking again. */
export const isHeld = (f: Floor): boolean => f.pending !== null

/** Should a high-stakes call in this turn be offered on? */
export function shouldOffer(f: Floor, turnId: string | null): boolean {
  if (f.active !== null && f.active.turnId === turnId) return false // already raised this turn
  if (f.pending !== null) return false // already held; the raise comes with the next message
  if (turnId !== null && f.offeredTurn === turnId) return false // once per turn

  return isBelowFloor(f.sent)
}

/** The effort a main-loop step should be sent with, and the state after. Raise-only. */
export function stepEffort(
  f: Floor,
  e: { index: number; turnId: string; effort?: unknown },
): { effort: unknown; next: Floor } {
  if (f.pending !== null && e.index === 0) {
    if (isBelowFloor(e.effort)) {
      return { effort: FLOOR, next: { ...f, pending: null, active: { cls: f.pending, turnId: e.turnId }, sent: FLOOR } }
    }
    // Already at or above the floor (or a number): nothing to raise; the hold is spent.
    return { effort: e.effort, next: { ...f, pending: null, sent: e.effort === undefined ? null : String(e.effort) } }
  }

  // The raised turn's later (tool) steps: keep sending the floor, as the measured positive control did.
  if (f.active !== null && f.active.turnId === e.turnId && isBelowFloor(e.effort)) {
    return { effort: FLOOR, next: { ...f, sent: FLOOR } }
  }

  return { effort: e.effort, next: { ...f, sent: e.effort === undefined ? null : String(e.effort) } }
}

/** At a main-loop turn's end: release a raise that belonged to it. */
export const release = (f: Floor, turnId: string): Floor =>
  f.active !== null && f.active.turnId === turnId ? { ...f, active: null } : f

export const levelName = (e: string | null) => (e === null ? 'unknown' : e.charAt(0).toUpperCase() + e.slice(1))

/** The footer label, or null when there is nothing to say. */
export function footerLabel(f: Floor, short: Record<SignalClass, string>): string | null {
  if (f.active !== null) return `Effort raised: High (${short[f.active.cls]})`
  if (f.pending !== null) return `Held: High from next message (${short[f.pending]})`

  return null
}
