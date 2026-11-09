// Pure helpers: model names, colors, number formatting and the band's
// width budget. No `$` here, so everything is plain data in and out.
import type { AgentRec, AgentStatus, Tokens } from '../types'

export const MAIN = 'main'

export const CHIP = { text: ' ◎ AGENTS ', color: '#0b0b0f', bg: '#f472b6' }
export const SKILL_COLOR = 'remember'
export const MODEL_COLORS: Record<string, string> = {
  fable: 'merged',
  opus: 'claude',
  sonnet: 'permission',
  haiku: 'autoAccept',
}
export const STATUS: Record<AgentStatus, { mark: string; color: string }> = {
  running: { mark: '⟳', color: 'warning' },
  done: { mark: '✓', color: 'success' },
  failed: { mark: '✗', color: 'error' },
}

const TASK_CHARS = 22

export type Seg = {
  text: string
  color?: string
  bg?: string
  isBold?: boolean
  isDim?: boolean
}

export function family(model: string): string | null {
  const hit = /fable|opus|sonnet|haiku/.exec(model.toLowerCase())

  return hit === null ? null : hit[0]
}

// claude-opus-5-5 -> opus·5.5, claude-sonnet-4-5-20250929 -> sonnet·4.5,
// haiku -> haiku. Anything unrecognised is shown as given, minus "claude-".
export function shortModel(model: string, withVersion: boolean): string {
  const lower = model.toLowerCase()
  const hit = /(fable|opus|sonnet|haiku)(?:-(\d+)(?:-(\d{1,2})(?!\d))?)?/.exec(lower)
  const [, name, major, minor] = hit ?? []
  if (name === undefined) {
    return lower.replace(/^claude-/, '')
  }
  if (!withVersion || major === undefined) {
    return name
  }

  return `${name}·${major}${minor === undefined ? '' : `.${minor}`}`
}

export function modelColor(model: string): string | undefined {
  const name = family(model)

  return name === null ? undefined : MODEL_COLORS[name]
}

export function cut(text: string, max = TASK_CHARS): string {
  const flat = text.replace(/\s+/g, ' ').trim()
  const chars = [...flat]

  return chars.length <= max ? flat : `${chars.slice(0, max - 1).join('')}…`
}

export function compact(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}k`

  return String(n)
}

export function sumTokens(all: Record<string, Tokens>): Tokens {
  const total: Tokens = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }
  for (const t of Object.values(all)) {
    total.input += t.input
    total.output += t.output
    total.cacheRead += t.cacheRead
    total.cacheWrite += t.cacheWrite
  }

  return total
}

export function label(agent: AgentRec): string {
  return agent.name ?? agent.type
}

export function lastModel(agent: AgentRec): string | undefined {
  return agent.models[agent.models.length - 1]
}

export function width(segs: readonly Seg[]): number {
  return segs.reduce((n, s) => n + [...s.text].length, 0)
}

type Plan = { tasks: boolean[]; helpers: number; skills: number }

function draw(
  main: AgentRec | undefined,
  helpers: readonly AgentRec[],
  skills: readonly string[],
  plan: Plan,
): Seg[] {
  const segs: Seg[] = [{ text: CHIP.text, color: CHIP.color, bg: CHIP.bg, isBold: true }]

  if (main !== undefined) {
    segs.push({ text: ' main' })
    const model = lastModel(main)
    if (model !== undefined) {
      segs.push({ text: ` ${shortModel(model, true)}`, color: modelColor(model) })
    }
    const status = STATUS[main.status]
    segs.push({ text: ` ${status.mark}`, color: status.color })
  }

  if (helpers.length > 0) {
    segs.push({ text: ' │ ', isDim: true })
    helpers.slice(0, plan.helpers).forEach((agent, i) => {
      if (i > 0) segs.push({ text: ' · ', isDim: true })
      segs.push({ text: label(agent) })
      const model = lastModel(agent)
      if (model !== undefined) {
        segs.push({ text: ` ${shortModel(model, false)}`, color: modelColor(model) })
      }
      if (plan.tasks[i] && agent.task !== '') {
        segs.push({ text: ` "${cut(agent.task)}"` })
      }
      const status = STATUS[agent.status]
      segs.push({ text: ` ${status.mark}`, color: status.color })
    })
    const hidden = helpers.length - plan.helpers
    if (hidden > 0) segs.push({ text: ` · +${hidden} more`, isDim: true })
  }

  if (skills.length > 0) {
    segs.push({ text: ' │ skills: ', isDim: true })
    segs.push({ text: skills.slice(0, plan.skills).join(', '), color: SKILL_COLOR })
    const hidden = skills.length - plan.skills
    if (hidden > 0) segs.push({ text: ` +${hidden} more`, isDim: true })
  }

  return segs
}

// The band at a width: everything if it fits; else task text goes first,
// oldest agents first (the first agent's stays), then skills shrink to one
// and agents fold into "+N more" from the newest end, the first one kept.
// Past that the Text truncates what is left.
export function layoutBand(
  main: AgentRec | undefined,
  helpers: readonly AgentRec[],
  skills: readonly string[],
  columns: number,
): Seg[] {
  const plan: Plan = {
    tasks: helpers.map(() => true),
    helpers: helpers.length,
    skills: skills.length,
  }
  const fits = () => width(draw(main, helpers, skills, plan)) <= columns

  for (let i = 1; i < helpers.length && !fits(); i += 1) {
    plan.tasks[i] = false
  }
  while (plan.skills > 1 && !fits()) {
    plan.skills -= 1
  }
  while (plan.helpers > 1 && !fits()) {
    plan.helpers -= 1
  }

  return draw(main, helpers, skills, plan)
}

// "+1m05s" from the session's first event: no clock zone to get wrong.
export function since(at: number, start: number): string {
  const s = Math.max(0, Math.round((at - start) / 1000))
  const m = Math.floor(s / 60)

  return m > 0 ? `+${m}m${String(s % 60).padStart(2, '0')}s` : `+${s}s`
}
