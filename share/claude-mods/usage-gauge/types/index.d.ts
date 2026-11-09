export type Window = { kind: string; percentUsed: number; resetsAt: string | null }

export type Reading = { at: number; percent: number }

export type TurnCost = { at: number; usd: number }

export type Gauge = {
  windows: Window[]
  contextPercent: number | null
  costUsd: number | null
  lastTurnUsd: number | null
  turns: TurnCost[]
  // Five-hour readings since that window last reset, for the pace warning.
  readings: Reading[]
  // Thresholds already toasted, per window and reset: "seven_day@<resetsAt>".
  toasted: Record<string, number[]>
  // The machine's offset from UTC in minutes, for local reset times.
  utcOffsetMin: number
  tick: number
}

declare module 'claude-code' {
  interface PluginState {
    'usage-gauge': { gauge: Shaped<Gauge>; isOn: boolean; warn: number[] }
  }
}
