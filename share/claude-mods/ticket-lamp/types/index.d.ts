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
