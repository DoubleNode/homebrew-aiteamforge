// A bot's latest verdict on the PR: stale when it reviewed another commit.
export type Verdict = 'approved' | 'changes' | 'pending' | 'stale'

export type Checks = { total: number; passed: number; failed: number; pending: number }

export type Gates = {
  branch: string
  pr: number
  state: 'OPEN' | 'MERGED' | 'CLOSED'
  test: Verdict
  review: Verdict
  ci: Checks
  // The kanban item the branch names, and its unresolved [Review]/[Test]/[UX]
  // subitems; null where no board or item was found.
  itemId: string | null
  sweepOpen: number | null
  checkedAt: number
  mergedSeenAt: number | null
}

declare module 'claude-code' {
  interface PluginState {
    'gate-board': { gates: Shaped<Gates | null>; isOn: boolean }
  }
}
