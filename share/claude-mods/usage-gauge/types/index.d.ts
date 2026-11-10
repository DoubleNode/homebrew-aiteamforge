export type CacheClock = {
  ttlMs: number
  ttlSource: 'detected' | 'guess'
  lastEnd: number
  contextTokens: number | null
}

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
  // Effort the main chat's last request carried; the menu's setting when readable; the first one seen.
  effortSent: string | null
  effortMenu: string | null
  effortBase: string | null
  // Prompt-cache clock for the main chat; null until a reply ended with a readable transcript.
  cache: CacheClock | null
}

declare module 'claude-code' {
  interface PluginState {
    'usage-gauge': { gauge: Shaped<Gauge>; isOn: boolean; warn: number[] }
  }
}
