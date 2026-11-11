// effort-floor's $.state contract (XACA-1640). Self-contained: claude plugin validate refuses imports here.

export type SignalClass = 'merge' | 'round-limit' | 'tap-release' | 'gitlink-stage' | 'publisher-arming'

export type Counts = { offered: number; held: number; ran: number; cancelled: number }

export type Floor = {
  /** The effort the last main-loop request was sent with (a level, a number as text, or null: none). */
  sent: string | null
  /** The main loop's current turn (its turn.start id). */
  turnId: string | null
  /** The turn already offered in: at most one offer per turn. */
  offeredTurn: string | null
  /** The turn whose dialog was dismissed (Esc = cancel): its high-stakes calls are refused, nothing is raised. */
  cancelledTurn: string | null
  /** Held: raise the next main-loop turn's step 0 to High for this class. */
  pending: SignalClass | null
  /** Raised: this turn runs at High because of this class; cleared at its turn.complete. */
  active: { cls: SignalClass; turnId: string } | null
  counts: Counts
}

declare module 'claude-code' {
  interface PluginState {
    'effort-floor': {
      floor: Shaped<Floor>
    }
  }
}
