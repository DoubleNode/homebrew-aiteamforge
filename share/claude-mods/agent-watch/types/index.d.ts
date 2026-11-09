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
  // The main turn it belongs to; the band shows the current one only.
  turnSeq: number
}

export type Moment = {
  at: number
  agentId: string
  text: string
  status: AgentStatus | null
}

export type Log = {
  turnSeq: number
  sessionStartedAt: number
  agents: AgentRec[]
  turnSkills: string[]
  timeline: Moment[]
}

declare module 'claude-code' {
  interface PluginState {
    'agent-watch': { log: Shaped<Log>; isOn: boolean }
  }
}
