// Shared mod switch state (XACA-1605-016). Own implementation.
//
// BYTE-IDENTICAL in every claude-mods/<mod>/hooks/switches.ts. A marketplace install copies each mod on
// its own, so a mod cannot import a sibling's file; the copies are kept equal by
// tests/test-claude-mods-switches-sync.sh. Edit one, then copy it over the rest.
//
// One flat JSON object at $HOME/.claude/mods/switches.json:
//   "<mod>": false          off: the mod's hooks pass through and it draws nothing
//   "<mod>:hidden": true    hidden: the mod keeps tracking but draws nothing
//   key absent              on and shown
// A missing, empty, unparseable or non-object file, and any value that is not a boolean, falls back to
// the default (on and shown; `defaultOff` mods default to off). Reading never throws; a mod that wants to
// log the fallback reads `problem` from its switch.
// Writers read the whole file, change one key, write a temp file and rename it over the original, so
// other keys survive and a reader never sees half a file.

type Json = Record<string, unknown>

/**
 * The slice of the engine this file uses, as plain functions. The engine's hook checker refuses to let
 * the engine handle itself be passed into another module, so each mod builds this from its own handle
 * (see the switch-io block in its hooks file, kept identical by the same drift test).
 */
export type SwitchIo = {
  exists: (path: string) => Promise<boolean>
  read: (path: string) => Promise<unknown>
  write: (path: string, text: string) => Promise<unknown>
  run: (argv: string[]) => Promise<{ exitCode: number }>
  /** The HOME variable (the engine wants a literal name, so this takes none). */
  home: () => Promise<string | undefined>
  every: (ms: number, fn: () => void) => unknown
  root: string
}

export type SwitchState = { off: boolean; hidden: boolean }
export type SwitchOptions = {
  /** Missing key means off (blast-radius only). */
  defaultOff?: boolean
}

export const POLL_MS = 3000

export const hiddenKey = (name: string) => `${name}:hidden`
export const switchesPath = (home: string) => `${home}/.claude/mods/switches.json`

/** HOME from the environment, else the part of the plugin folder before /.claude/. */
export async function homeOf(io: SwitchIo): Promise<string> {
  const fromEnv = await io.home().catch(() => undefined)
  return fromEnv || (io.root.split('/.claude/')[0] ?? '')
}

/** Pure: the text of a switches file as an object, or null when it is not one. Empty text is an empty object. */
export function parseSwitches(text: string): Json | null {
  if (text.trim() === '') return {}
  try {
    const json: unknown = JSON.parse(text)

    return json !== null && typeof json === 'object' && !Array.isArray(json) ? (json as Json) : null
  } catch {
    return null
  }
}

/** Pure: one mod's state from a parsed file (null stands for an unreadable file). */
export function stateFrom(json: Json | null, name: string, defaultOff = false): SwitchState {
  const fallback: SwitchState = { off: defaultOff, hidden: false }
  if (json === null) return fallback
  const on = json[name]
  const hide = json[hiddenKey(name)]

  return {
    off: on === false ? true : on === true ? false : fallback.off,
    hidden: hide === true,
  }
}

/** The file as an object; `null` when it exists but cannot be read as one; {} when it does not exist. */
export async function readSwitchFile(io: SwitchIo, home: string): Promise<Json | null> {
  const path = switchesPath(home)
  try {
    if (!(await io.exists(path))) return {}

    return parseSwitches(String(await io.read(path)))
  } catch {
    return null
  }
}

/** Writes the whole object atomically: a temp file in the same folder, then a rename over the original. */
export async function writeSwitchFile(io: SwitchIo, home: string, json: Json): Promise<void> {
  const path = switchesPath(home)
  const text = `${JSON.stringify(json, null, 2)}\n`
  const tmp = `${path}.${Math.random().toString(36).slice(2, 10)}.tmp`
  await io.write(tmp, text)
  const moved = await io.run(['mv', '-f', tmp, path]).catch(() => null)
  if (moved === null || moved.exitCode !== 0) {
    // No rename available: fall back to a plain write, and clean up the temp file.
    await io.write(path, text)
    await io.run(['rm', '-f', tmp]).catch(() => undefined)
  }
}

/**
 * Sets or clears the keys for one mod in the file. `off: true` writes "<mod>": false; `off: false` clears
 * it (or writes true for a `defaultOff` mod). `hidden: true` writes "<mod>:hidden": true; false clears it.
 * Every other key is kept. A file that cannot be read as an object is left alone and the write refused.
 */
export async function setSwitch(
  io: SwitchIo,
  home: string,
  name: string,
  patch: Partial<SwitchState>,
  defaultOff = false,
): Promise<boolean> {
  const json = await readSwitchFile(io, home)
  if (json === null) return false
  if (patch.off !== undefined) {
    if (patch.off) json[name] = false
    else if (defaultOff) json[name] = true
    else delete json[name]
  }
  if (patch.hidden !== undefined) {
    if (patch.hidden) json[hiddenKey(name)] = true
    else delete json[hiddenKey(name)]
  }
  try {
    await writeSwitchFile(io, home, json)

    return true
  } catch {
    return false
  }
}

/** One mod's live switch: module-level state the mod's hooks read, kept fresh by a 3 s poll. */
export function createSwitch(name: string, options: SwitchOptions = {}) {
  const defaultOff = options.defaultOff === true
  let home = ''
  let state: SwitchState = { off: defaultOff, hidden: false }
  let problem = ''
  let onChange: () => void | Promise<void> = () => undefined

  const apply = async (next: SwitchState) => {
    if (next.off === state.off && next.hidden === state.hidden) return
    state = next
    await Promise.resolve(onChange()).catch(() => undefined)
  }

  const refresh = async (io: SwitchIo): Promise<void> => {
    if (home === '') home = await homeOf(io)
    const json = await readSwitchFile(io, home)
    problem = json === null ? 'switches.json is unreadable; using defaults' : ''
    await apply(stateFrom(json, name, defaultOff))
  }

  return {
    get off() {
      return state.off
    },
    get hidden() {
      return state.hidden
    },
    /** On and shown: the mod does its work and draws. */
    get shown() {
      return !state.off && !state.hidden
    },
    get home() {
      return home
    },
    /** Why the file was ignored on the last read, or '' (so a mod can log it once if it wants to). */
    get problem() {
      return problem
    },
    /** Reads the file now and then every 3 s. `changed` runs after a flip (redraw, stop work). */
    async start(io: SwitchIo, changed?: () => void | Promise<void>): Promise<void> {
      if (changed) onChange = changed
      home = await homeOf(io)
      await refresh(io).catch(() => undefined)
      io.every(POLL_MS, () => {
        void refresh(io).catch(() => undefined)
      })
    },
    refresh,
    /** Writes the change to the shared file, then applies it here without waiting for the poll. */
    async set(io: SwitchIo, patch: Partial<SwitchState>): Promise<boolean> {
      if (home === '') home = await homeOf(io)
      const saved = await setSwitch(io, home, name, patch, defaultOff)
      if (saved) await apply({ ...state, ...patch })

      return saved
    },
  }
}
