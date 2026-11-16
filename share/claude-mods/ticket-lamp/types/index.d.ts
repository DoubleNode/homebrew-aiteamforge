// How the session's subject was chosen: a /ticket pin, the CC_SESSION_NAME
// a kb-run / kb-work / kb-run-{test,review,ux} / kb-debug launcher exported, or
// a later ticket this session started working on (kb-pick, kb-backlog sub start|done, kb-done <ID>).
export type Source = 'pinned' | 'launch' | 'followed'

// A ticket this session worked on before the current one, and where it stands now.
export type Prior = { id: string; status: string }

// The launcher's tag: kb-run-review starts "[Review] XACA-…", and so on.
export type Role = 'Review' | 'Test' | 'UX' | 'Debug' | null

export type Sub = { id: string; title: string; status: string }

export type TicketView = {
  kind: 'ticket'
  title: string
  status: string
  subs: Sub[]
  release: { id: string; name: string; short: string; target: string } | null
  epic: { id: string; title: string; short: string } | null
  prMerged: number | null
}

// Tokens for one ticket, read from release.orchestration.tokens.perItem (XACA-1808): total = input + cacheCreate +
// cacheRead + output. null = nothing to show (no block, or the ticket is not in perItem); '?' = a malformed block.
export type Tok = { total: number; cacheRead: number } | '?' | null

// The ticket a lane is working on (release.orchestration.lanes[].current, joined with the board's title and subitems).
// status is an orchestrator_state.STATES name and stage its release_orchestrator.STATE_STAGE value; both are null when
// the writer's value was not a string.
export type LaneCurrent = {
  id: string | null
  status: string | null
  stage: string | null
  prNumber: number | null
  title: string
  subsDone: number
  subsTotal: number
  tokens: Tok
}

export type QueuedTicket = { id: string; title: string }

// One dispatch slot. current is null while the slot is free (after DONE or CANCELLED, or not yet filled).
export type Lane = { lane: number; since: string | null; current: LaneCurrent | null; queue: QueuedTicket[]; queueLen: number }

// A ticket the run has finished (DONE or CANCELLED).
export type FinishedTicket = { id: string; state: string; title: string; tokens: Tok }

export type ReleaseView = {
  kind: 'release'
  name: string
  short: string
  status: string
  stage: string
  // "<platform>:<environment>" per platform.
  platforms: string[]
  version: string
  target: string
  branch: string
  tickets: { completed: number; cancelled: number; total: number }
  // Open tickets, first few, for /ticket.
  open: Sub[]
  archived: boolean
  // Orchestrated run (XACA-1786), all from the board's release.orchestration in the same jq pass.
  // True when activeRunId is set and the run is not closed.
  runActive: boolean
  // The lane cap: orchestration.maxParallel (2 when absent or invalid).
  maxParallel: number
  // Lanes sorted by number, at most maxParallel. [] when no run is active; null when the block is malformed.
  lanes: Lane[] | null
  finished: FinishedTicket[]
  // The whole run's tokens (orchestration.tokens.run).
  runTok: Tok
}

export type View = (TicketView | ReleaseView) & {
  id: string
  source: Source
  role: Role
  // false when no board holds the id: the line stays hidden.
  found: boolean
  // board path + mtime the view was read at, plus the earlier tickets; a change re-reads.
  key: string
  checkedAt: number
  // Earlier tickets of this session, oldest first (never the current one).
  prior: Prior[]
}

declare module 'claude-code' {
  interface PluginState {
    'ticket-lamp': {
      view: Shaped<View | null>
      isOn: boolean
      pinned: string | null
      // Tickets this session has worked on, in order; the last is the current one.
      followed: string[]
    }
  }
}
