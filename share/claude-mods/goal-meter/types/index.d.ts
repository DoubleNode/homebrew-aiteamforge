export type TaskStatus = 'pending' | 'running' | 'done'

export type GoalTask = {
  id: string
  title: string
  // The "Running tests" form the task list gives a task in progress.
  active: string | null
  status: TaskStatus
  firstSeenAt: number
  startedAt: number | null
  doneAt: number | null
}

export type Goal = {
  name: string
  startedAt: number
  doneAt: number | null
  tasks: GoalTask[]
}

export type GoalSummary = {
  name: string
  startedAt: number
  doneAt: number | null
  total: number
  done: number
}

declare module 'claude-code' {
  interface PluginState {
    'goal-meter': {
      goal: Shaped<Goal | null>
      history: Shaped<GoalSummary[]>
      prompt: string
      isOn: boolean
      tick: number
    }
  }
}
