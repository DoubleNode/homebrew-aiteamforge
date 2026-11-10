export type AgentStatus = 'running' | 'done' | 'failed'

export type Tokens = {
  input: number
  output: number
  cacheRead: number
  cacheWrite: number
}

// One loop: the main chat (id "main") or a helper agent.
export type AgentRec = {
  id: string
  parentId: string | null
  type: string
  name: string | null
  task: string
  models: string[]
  status: AgentStatus
  calls: number
  tokens: Record<string, Tokens>
  skills: string[]
  startedAt: number
  endedAt: number | null
  // The effort its first request carried (a level name, or a number as text); null until seen, or when the
  // model takes none. Recorded once, on the agent's first turn.step.
  effort: string | null
  // The main turn it belongs to; the band shows the current one only.
  turnSeq: number
}

export type Moment = {
  at: number
  agentId: string
  text: string
  status: AgentStatus | null
}

// Session counters of what the dispatch lint saw (XACA-1639): kept in every mode so warn-mode data can
// decide whether deny becomes the default.
export type LintCounts = {
  missingModel: number
  opusLow: number
  max: number
}

// What this chat touched (XACA-1639-016): paths deduped, newest last, bounded; MCP calls per server.
export type Used = {
  read: string[]
  written: string[]
  mcp: Record<string, number>
}

export type Log = {
  turnSeq: number
  sessionStartedAt: number
  agents: AgentRec[]
  turnSkills: string[]
  timeline: Moment[]
  lint: LintCounts
  used: Used
}

declare module 'claude-code' {
  interface PluginState {
    'agent-watch': { log: Shaped<Log>; isOn: boolean }
  }
}
