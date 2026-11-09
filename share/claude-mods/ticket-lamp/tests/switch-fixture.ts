// Test fixture for the shared switch file (XACA-1605-016): an in-memory stand-in for the
// files the switch reader and writer touch, with the `mv` and `rm` the atomic write uses.
// BYTE-IDENTICAL in every claude-mods/<mod>/tests/ (tests/test-claude-mods-switches-sync.sh).
// A mod's own engine mock delegates to it for any path it owns.

export const SWITCHES_NAME = '/.claude/mods/switches.json'

export type SwitchFiles = ReturnType<typeof switchFiles>

type Run = { exitCode: number; stdout: string; stderr: string; isStdoutTruncated: boolean; isStderrTruncated: boolean }
const ok = (): Run => ({ exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false })

export function switchFiles(home = '/home/me', initial?: Record<string, unknown> | string) {
  const path = `${home}${SWITCHES_NAME}`
  const files: Record<string, string> = {}
  if (initial !== undefined) files[path] = typeof initial === 'string' ? initial : JSON.stringify(initial)
  const writes: string[] = []

  return {
    home,
    path,
    files,
    /** Every path written, in order (temp files included). */
    writes,
    /** True for the switch file and its temp files: the paths this fixture answers for. */
    owns: (p: string) => p === path || (p.startsWith(`${path}.`) && p.endsWith('.tmp')),
    exists: (p: string) => p in files,
    read: (p: string) => files[p] ?? '',
    write: (p: string, text: string) => {
      writes.push(p)
      files[p] = text
    },
    /** The `mv -f a b` and `rm -f a` of the atomic write; undefined for any other argv. */
    run: (argv: readonly string[]): Run | undefined => {
      if (argv[0] === 'mv' && argv[2] !== undefined && argv[3] !== undefined) {
        files[argv[3]] = files[argv[2]] ?? ''
        delete files[argv[2]]

        return ok()
      }
      if (argv[0] === 'rm' && argv[2] !== undefined) {
        delete files[argv[2]]

        return ok()
      }

      return undefined
    },
    /** The parsed switch file ({} when absent). */
    json: (): Record<string, unknown> => JSON.parse(files[path] ?? '{}'),
    /** Replaces the file's text, as another chat or /mods would. */
    put: (value: Record<string, unknown> | string) => {
      files[path] = typeof value === 'string' ? value : JSON.stringify(value)
    },
    remove: () => {
      delete files[path]
    },
    /** True when no temp file is left behind. */
    clean: () => Object.keys(files).every(k => k === path || !k.endsWith('.tmp')),
  }
}
