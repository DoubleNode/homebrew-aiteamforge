// What /mods lists and how it reads each mod's state. Pure functions, no engine: the hooks file
// reads the files and hands the text here.
import { stateFrom } from './switches'

/** A mod found in the marketplace folder, in CLAUDE_CODE_PLUGIN_DIRS, or both. */
export type Entry = {
  name: string
  description: string
  /** The mod's own folder inside the marketplace folder, or null when it is not in the marketplace. */
  folder: string | null
  /** The CLAUDE_CODE_PLUGIN_DIRS entry that loads it, or null. */
  pluginDir: string | null
}

export type Row = Entry & {
  /** enabledPlugins says false in the user settings: Claude Code does not load it, so nothing here can switch it. */
  isHardDisabled: boolean
  off: boolean
  hidden: boolean
  /** A mod that ships off (missing key means off). */
  isDefaultOff: boolean
  /** The slash command that opens the mod's side pane, or null when it has none. */
  paneCommand: string | null
  /** This pane itself: always on, so /mods can always bring the others back. */
  isSelf: boolean
}

export const SELF = 'mods-switchboard'

/**
 * The slash command that opens a mod's side pane. Mods not listed have no pane.
 * tests/test-claude-mods-pane-commands.sh checks each one is registered by its mod.
 */
export const PANE_COMMANDS: Readonly<Record<string, string>> = {
  'agent-watch': 'agent-watch',
  'goal-meter': 'goals',
  'usage-gauge': 'usage-gauge',
  'replay-theater': 'replay',
}

/**
 * Mods whose switch defaults to off when the key is missing. tests/test-claude-mods-pane-commands.sh
 * checks this list against the mods that create their switch with `defaultOff: true`.
 */
export const DEFAULT_OFF: ReadonlySet<string> = new Set(['blast-radius'])

const isObject = (v: unknown): v is Record<string, unknown> => v !== null && typeof v === 'object' && !Array.isArray(v)

/** `a/./b/../c` to `a/c` for an absolute or relative path. */
export function normalize(path: string): string {
  const abs = path.startsWith('/')
  const out: string[] = []
  for (const part of path.split('/')) {
    if (part === '' || part === '.') continue
    if (part === '..') {
      if (out.length > 0 && out[out.length - 1] !== '..') out.pop()
      else if (!abs) out.push('..')
      continue
    }
    out.push(part)
  }

  return `${abs ? '/' : ''}${out.join('/')}` || (abs ? '/' : '.')
}

export const dirname = (path: string): string => {
  const i = path.replace(/\/+$/, '').lastIndexOf('/')

  return i <= 0 ? (i === 0 ? '/' : '.') : path.slice(0, i)
}

export const basename = (path: string): string => path.replace(/\/+$/, '').split('/').pop() ?? path

/**
 * The plugins a marketplace.json lists. `base` is the folder the sources are relative to (the
 * folder that holds the mods). Anything unreadable gives no entries and a `problem` to show.
 */
export function parseMarketplace(text: string, base: string): { entries: Entry[]; problem: string } {
  let json: unknown
  try {
    json = JSON.parse(text)
  } catch {
    return { entries: [], problem: 'marketplace.json is not valid JSON' }
  }
  if (!isObject(json) || !Array.isArray(json.plugins)) return { entries: [], problem: 'marketplace.json lists no plugins' }
  const entries: Entry[] = []
  for (const p of json.plugins as unknown[]) {
    if (!isObject(p) || typeof p.name !== 'string' || p.name === '') continue
    const source = typeof p.source === 'string' ? p.source : `./${p.name}`
    entries.push({
      name: p.name,
      description: typeof p.description === 'string' ? p.description : '',
      folder: normalize(source.startsWith('/') ? source : `${base}/${source}`),
      pluginDir: null,
    })
  }

  return { entries, problem: '' }
}

/** CLAUDE_CODE_PLUGIN_DIRS is a ':'-separated list of mod folders. */
export function parsePluginDirs(value: string | undefined): string[] {
  const seen = new Set<string>()
  for (const part of (value ?? '').split(':')) {
    const dir = part.trim()
    if (dir !== '') seen.add(normalize(dir))
  }

  return [...seen]
}

/** The plugin name in a plugin.json's text, or null. */
export function nameFromManifest(text: string): string | null {
  try {
    const json: unknown = JSON.parse(text)

    return isObject(json) && typeof json.name === 'string' && json.name !== '' ? json.name : null
  } catch {
    return null
  }
}

/** The description in a plugin.json's text, or ''. */
export function descriptionFromManifest(text: string): string {
  try {
    const json: unknown = JSON.parse(text)

    return isObject(json) && typeof json.description === 'string' ? json.description : ''
  } catch {
    return ''
  }
}

/**
 * Whether the user settings turn a plugin off for good: some `enabledPlugins` key `<name>@<anything>`
 * is false and none is true. Read-only; anything unreadable means "not disabled".
 */
export function isHardDisabled(settingsText: string, name: string): boolean {
  let json: unknown
  try {
    json = JSON.parse(settingsText)
  } catch {
    return false
  }
  if (!isObject(json) || !isObject(json.enabledPlugins)) return false
  let falses = 0
  let trues = 0
  for (const [key, value] of Object.entries(json.enabledPlugins)) {
    if (key !== name && !key.startsWith(`${name}@`)) continue
    if (value === false) falses += 1
    else if (value === true) trues += 1
  }

  return falses > 0 && trues === 0
}

/** Merges the marketplace entries and the plugin-dir entries by name, marketplace first. */
export function mergeEntries(market: Entry[], dirs: Entry[]): Entry[] {
  const byName = new Map<string, Entry>()
  for (const e of market) byName.set(e.name, { ...e })
  for (const d of dirs) {
    const have = byName.get(d.name)
    if (have) byName.set(d.name, { ...have, pluginDir: d.pluginDir, description: have.description || d.description })
    else byName.set(d.name, { ...d })
  }

  return [...byName.values()]
}

export type RowInput = {
  entries: Entry[]
  settingsText: string
  /** The parsed switches file (null when unreadable). */
  switches: Record<string, unknown> | null
}

export function buildRows({ entries, settingsText, switches }: RowInput): Row[] {
  return entries.map(e => {
    const isDefaultOff = DEFAULT_OFF.has(e.name)
    const state = stateFrom(switches, e.name, isDefaultOff)

    return {
      ...e,
      isHardDisabled: isHardDisabled(settingsText, e.name),
      off: state.off,
      hidden: state.hidden,
      isDefaultOff,
      paneCommand: PANE_COMMANDS[e.name] ?? null,
      isSelf: e.name === SELF,
    }
  })
}

/** The way back for a mod that settings disable: Claude Code loads plugins at session start, so it needs a restart. */
export function enableHint(name: string): string {
  return `To load it: run "claude plugin enable ${name}@aiteamforge-mods" (or /plugin), then restart the session.`
}

/** "on · shown", "off", "on · hidden", or "not loaded". */
export function stateLabel(r: Row): string {
  if (r.isHardDisabled) return 'not loaded (disabled in settings)'
  if (r.isSelf) return 'on (this pane)'
  if (r.off) return r.isDefaultOff ? 'off (ships off)' : 'off'

  return r.hidden ? 'on · hidden' : 'on · shown'
}

/** One text line per mod, for `/mods list` and the tests. */
export function listLines(rows: Row[]): string[] {
  return rows.map(r => {
    const where = [r.folder ?? '(not in the marketplace)', r.pluginDir !== null ? `CLAUDE_CODE_PLUGIN_DIRS ${r.pluginDir}` : null]
      .filter(Boolean)
      .join(' · ')

    return `${r.name}  ${stateLabel(r)}  ${where}`
  })
}
