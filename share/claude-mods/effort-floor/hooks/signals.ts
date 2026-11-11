// Pure signal matcher for effort-floor (XACA-1640-002): which high-stakes action, if any, a main-loop
// Bash command is about to take. Structural only: no model call, so every row is table-testable.
//
// A command is cut into segments at unquoted `&&`, `||`, `;`, `|`, `&`, parentheses and newlines (heredoc
// bodies skipped), and each segment is judged by its command word alone. Text that merely MENTIONS a
// command (an echo, a commit message, a grep pattern) is an argument, never a command word, so it is
// not a signal. Read-only lookalikes (`gh pr view`, `kb-merge --help`, `gh variable get`) are `null`.

import type { SignalClass } from '../types'

export type { SignalClass }

/** How the offer names the action: "About to <label> at Low effort". */
export const LABEL: Record<SignalClass, string> = {
  merge: 'merge a PR',
  'round-limit': 'act on a ROUND_LIMIT verdict',
  'tap-release': 'cut a tap release',
  'gitlink-stage': 'stage the homebrew-tap gitlink',
  'publisher-arming': 'arm the tap publisher',
}

/** Short form for the footer: "Effort raised: High (merge)". */
export const SHORT: Record<SignalClass, string> = {
  merge: 'merge',
  'round-limit': 'round limit',
  'tap-release': 'tap release',
  'gitlink-stage': 'gitlink',
  'publisher-arming': 'publisher',
}

// Shell reserved words that can stand before a command (`if kb-merge 1; then`, `{ kb-merge 1; }`, `! kb-merge 1`).
const RESERVED = new Set(['if', 'then', 'else', 'elif', 'do', 'while', 'until', '{', '}', '!', 'time'])
// Wrappers that run the command after them (PR #1320 review: timeout/nice/caffeinate/sudo -u/xargs were blind).
const PREFIX = new Set(['sudo', 'command', 'env', 'time', 'exec', 'nohup', 'builtin', 'nice', 'timeout', 'caffeinate', 'xargs', 'stdbuf', 'ionice', 'doas'])
// Per wrapper, the options that take the next word as their value (`sudo -u me`, `nice -n 5`, `xargs -I {}`).
// Per wrapper on purpose: `env -i` and `caffeinate -i` take none, so one shared set would skip the command.
const TAKES_VALUE: Record<string, ReadonlySet<string>> = {
  sudo: new Set(['-u', '-g', '-h', '-p', '-C', '-D', '-r', '-t', '-U', '--user', '--group']),
  doas: new Set(['-u', '-C']),
  env: new Set(['-u', '-S', '-C', '--unset', '--chdir']),
  nice: new Set(['-n', '--adjustment']),
  timeout: new Set(['-s', '-k', '--signal', '--kill-after']),
  xargs: new Set(['-I', '-L', '-P', '-d', '-E', '-n', '-s', '-a']),
  ionice: new Set(['-c', '-n', '-p']),
  stdbuf: new Set(['-i', '-o', '-e']),
  caffeinate: new Set(['-t', '-w']),
}
const ASSIGN = /^[A-Za-z_][A-Za-z0-9_]*=/

/**
 * A heredoc operator at `line[i]` (`<<`, `<<-`; not `<<<`), its delimiter read as bash reads a word (PR #1320 test
 * gate 024): unquoted characters plus `'...'`, `"..."`, `$'...'` and `\x` parts. ANY quoting means the body is not
 * expanded; the delimiter is the word with its quotes removed. One helper for both scanners, so they cannot drift.
 */
export type Heredoc = { word: string; isQuoted: boolean; isDash: boolean; length: number }

export function heredocAt(line: string, i: number): Heredoc | null {
  if (line.charAt(i) !== '<' || line.charAt(i + 1) !== '<' || line.charAt(i + 2) === '<' || line.charAt(i - 1) === '<') return null
  let j = i + 2
  const isDash = line.charAt(j) === '-'
  if (isDash) j++
  while (line.charAt(j) === ' ' || line.charAt(j) === '\t') j++
  let word = ''
  let isQuoted = false
  while (j < line.length) {
    const c = line.charAt(j)
    if (c === ' ' || c === '\t' || ';|&<>()'.includes(c)) break
    if (c === '\\') {
      isQuoted = true
      word += line.charAt(j + 1)
      j += 2
    } else if (c === "'" || c === '"' || (c === '$' && line.charAt(j + 1) === "'")) {
      isQuoted = true
      const open = c === '$' ? j + 2 : j + 1
      const quote = c === '"' ? '"' : "'"
      const close = line.indexOf(quote, open)
      const stop = close < 0 ? line.length : close
      word += line.slice(open, stop)
      j = stop + 1
    } else {
      word += c
      j++
    }
  }

  return word === '' ? null : { word, isQuoted, isDash, length: j - i }
}

/** The line that ends a heredoc: exactly the delimiter; leading tabs are stripped only under `<<-`, spaces never. */
export const endsHeredoc = (line: string, h: Heredoc) => (h.isDash ? line.replace(/^\t+/, '') : line) === h.word

/**
 * One simple command as the shell would split it. `stdin` is what reaches its standard input from a heredoc body
 * or a here-string (`<<<`); `pipeIn` is the segment piped into it (`a | b`, not `a || b`). PR #1320 test gate 022:
 * a shell reading its script from stdin (`bash <<'EOF'`, `bash <<< '...'`, `echo ... | bash`) runs that script.
 */
export type Seg = { words: string[]; stdin: string | null; pipeIn: Seg | null }

/** Splits a command into simple commands: quotes honoured, heredoc bodies kept apart as the owner's stdin. */
export function segmentsDetailed(command: string): Seg[] {
  const out: Seg[] = []
  let cur: Seg = { words: [], stdin: null, pipeIn: null }
  let word = ''
  let hasWord = false
  let quote: '' | "'" | '"' = ''
  let isHereString = false
  const heredocs: Array<{ h: Heredoc; owner: Seg; body: string[] }> = []
  let arith = 0 // inside (( )) / $(( )): `<<` there is a shift
  const flushWord = () => {
    if (hasWord) {
      if (isHereString) {
        cur.stdin = word
        isHereString = false
      } else cur.words.push(word)
    }
    word = ''
    hasWord = false
  }
  const flushSeg = (isPipe = false) => {
    flushWord()
    const done = cur
    if (done.words.length > 0 || done.stdin !== null) out.push(done)
    // The next simple command reads this one's output only across a real pipe (`|`, `|&`), never `||`.
    cur = { words: [], stdin: null, pipeIn: isPipe && done.words.length > 0 ? done : null }
  }
  const lines = command.split('\n')
  for (let li = 0; li < lines.length; li++) {
    const line = lines[li] ?? ''
    const open = heredocs[0]
    if (open !== undefined && quote === '') {
      // Inside a heredoc body: collect it for its owner until the terminator line.
      if (endsHeredoc(line, open.h)) {
        open.owner.stdin = open.body.join('\n')
        heredocs.shift()
      } else open.body.push(open.h.isDash ? line.replace(/^\t+/, '') : line)
      continue
    }
    for (let i = 0; i < line.length; i++) {
      const c = line.charAt(i)
      if (quote !== '') {
        if (c === quote) quote = ''
        else if (c === '\\' && quote === '"' && i + 1 < line.length) word += line.charAt(++i)
        else word += c
        continue
      }
      if (c === "'" || c === '"') {
        quote = c
        hasWord = true
        continue
      }
      if (c === '\\' && i + 1 < line.length) {
        word += line.charAt(++i)
        hasWord = true
        continue
      }
      if (c === '#' && !hasWord) break // comment to end of line
      if (c === '<' && line.charAt(i + 1) === '<' && line.charAt(i + 2) === '<') {
        flushWord()
        isHereString = true
        i += 2
        continue
      }
      if (c === '(' && line.charAt(i + 1) === '(') {
        arith++
        flushSeg()
        i++
        continue
      }
      if (c === ')' && line.charAt(i + 1) === ')' && arith > 0) {
        arith--
        flushSeg()
        i++
        continue
      }
      const h = arith === 0 ? heredocAt(line, i) : null
      if (h !== null) {
        flushWord()
        heredocs.push({ h, owner: cur, body: [] })
        i += h.length - 1
        continue
      }
      if (c === ' ' || c === '\t') {
        flushWord()
        continue
      }
      if (c === '|') {
        const isOr = line.charAt(i + 1) === '|'
        if (isOr) i++
        else if (line.charAt(i + 1) === '&') i++
        flushSeg(!isOr)
        continue
      }
      if (c === '&' || c === ';' || c === '(' || c === ')') {
        flushSeg()
        continue
      }
      word += c
      hasWord = true
    }
    if (quote === '') flushSeg()
    else word += '\n'
  }
  flushSeg()
  for (const h of heredocs) h.owner.stdin = h.body.join('\n') // unterminated: the rest is the body

  return out
}

/** Splits one shell line-set into segments of words, quotes honoured, heredoc bodies dropped. */
export function segments(command: string): string[][] {
  return segmentsDetailed(command).filter(s => s.words.length > 0).map(s => s.words)
}

const base = (w: string) => w.slice(w.lastIndexOf('/') + 1)

/** The segment from its command word on: env assignments and wrappers (`sudo`, `env`) dropped. */
function commandWords(seg: string[]): string[] {
  let i = 0
  for (;;) {
    while (i < seg.length && (ASSIGN.test(seg[i] ?? '') || RESERVED.has(seg[i] ?? '') || seg[i] === 'function')) {
      i += seg[i] === 'function' ? 2 : 1 // `function name { ... }`: the keyword and the name
    }
    const w = seg[i]
    if (w === undefined || !PREFIX.has(base(w))) break
    const wrapper = base(w)
    i++
    // The wrapper's own options, then (timeout) its duration.
    while (i < seg.length && (seg[i] ?? '').startsWith('-')) {
      const opt = seg[i] ?? ''
      i += TAKES_VALUE[wrapper]?.has(opt) === true ? 2 : 1
    }
    if (wrapper === 'timeout' && /^[0-9.]+[smhd]?$/.test(seg[i] ?? '')) i++
  }

  return seg.slice(i)
}

/** git's own options before the subcommand (`-C dir`, `-c k=v`, `--git-dir=x`, `--no-pager`). */
function gitSub(args: string[]): { sub: string; rest: string[] } | null {
  let i = 0
  while (i < args.length && (args[i] ?? '').startsWith('-')) {
    i += args[i] === '-C' || args[i] === '-c' || args[i] === '--git-dir' || args[i] === '--work-tree' ? 2 : 1
  }
  if (i >= args.length) return null

  return { sub: args[i] ?? '', rest: args.slice(i + 1) }
}

const isGitlink = (p: string) => {
  const t = p.replace(/\/+$/, '')

  return t === 'homebrew-tap' || t.endsWith('/homebrew-tap')
}

/**
 * Help, judged by position only (PR #1320 test gate: an option VALUE such as `-b help` or `--notes -n` must not
 * switch detection off): `--help` anywhere, `-h` / `help` only as the first argument.
 */
// Options whose next word is their VALUE in the watched tools: `--body "--help"` is a body, not a help request.
const VALUE_OPTS = new Set(['-b', '--body', '-t', '--title', '-m', '--message', '--notes', '--subject', '-F', '--body-file',
  '-R', '--repo', '-A', '--author-email', '--match-head-commit', '-B', '--base', '-H', '--head', '--body-text'])
/** `flag` present as a flag, not as the value of a value-taking option. */
const hasFlag = (args: readonly string[], flag: string) => args.some((a, i) => a === flag && !(i > 0 && VALUE_OPTS.has(args[i - 1] ?? '')))
const isHelp = (args: readonly string[]) => hasFlag(args, '--help') || args[0] === '-h' || args[0] === 'help'

/**
 * Heredoc bodies as the shell expands them (PR #1320 review round 2): a body under a QUOTED delimiter (`<<'EOF'`,
 * `<<"EOF"`, `<<-'EOF'`) is never expanded, so it is blanked; a body under an unquoted `<<EOF` IS expanded, and
 * quotes mean nothing there, so its quote marks are blanked and its substitutions still count. A `<<` inside
 * double quotes is detected too, since `"$(cat <<'EOF' ...)"` is how commit messages and PR bodies are written.
 */
export function stripHeredocBodies(command: string): string {
  const lines = command.split('\n')
  const queued: Heredoc[] = []
  let arith = 0
  for (let li = 0; li < lines.length; li++) {
    const line = lines[li] ?? ''
    const head = queued[0]
    if (head !== undefined) {
      if (endsHeredoc(line, head)) queued.shift()
      else lines[li] = head.isQuoted ? '' : line.replace(/['"]/g, ' ')
      continue
    }
    // Outside single quotes and comments, and outside (( )) arithmetic. Double quotes are NOT a barrier: a
    // `"$(cat <<'EOF' ...)"` heredoc is real.
    let single = false
    for (let i = 0; i < line.length; i++) {
      const c = line.charAt(i)
      if (single) {
        if (c === "'") single = false
        continue
      }
      if (c === '\\') {
        i++
        continue
      }
      if (c === "'") {
        single = true
        continue
      }
      if (c === '#' && (i === 0 || line.charAt(i - 1) === ' ' || line.charAt(i - 1) === '\t')) break
      if (c === '(' && line.charAt(i + 1) === '(') {
        arith++
        i++
        continue
      }
      if (c === ')' && line.charAt(i + 1) === ')' && arith > 0) {
        arith--
        i++
        continue
      }
      const h = arith === 0 ? heredocAt(line, i) : null
      if (h !== null) {
        queued.push(h)
        i += h.length - 1
      }
    }
  }

  return lines.join('\n')
}

/**
 * The command substitutions in a command (`$( ... )`, backticks), outside single quotes, where they run even
 * inside double quotes, heredoc bodies taken as the shell expands them. Not nested backticks; a `$(` that never
 * closes takes the rest of the text. Each one found is read again by commands(), which strips its own heredocs.
 */
export function substitutions(command: string): string[] {
  return scanSubstitutions(stripHeredocBodies(command))
}

function scanSubstitutions(command: string): string[] {
  const out: string[] = []
  let quote = ''
  for (let i = 0; i < command.length; i++) {
    const c = command.charAt(i)
    if (quote === "'") {
      if (c === "'") quote = ''
      continue
    }
    if (c === '\\') {
      i++
      continue
    }
    if (c === "'" && quote === '') {
      quote = "'"
      continue
    }
    if (c === '"') {
      quote = quote === '"' ? '' : '"'
      continue
    }
    if (c === '`') {
      const close = command.indexOf('`', i + 1)
      const stop = close < 0 ? command.length : close
      out.push(command.slice(i + 1, stop))
      i = stop
      continue
    }
    if (c === '$' && command.charAt(i + 1) === '(' && command.charAt(i + 2) !== '(') {
      let depth = 1
      let j = i + 2
      for (; j < command.length && depth > 0; j++) {
        const d = command.charAt(j)
        if (d === '(') depth++
        else if (d === ')') depth--
      }
      out.push(command.slice(i + 2, depth === 0 ? j - 1 : j))
      i = j - 1
    }
  }

  return out
}

type Cmd = { words: string[]; viaXargs: boolean }

const SHELLS = new Set(['bash', 'zsh', 'sh', 'dash', 'ksh'])

/**
 * The script a shell with no `-c` reads from stdin, or null: none, or it runs a script file (`bash x.sh <<EOF` feeds
 * the file, not a script). Stdin is a heredoc body or here-string, else what `echo` / `printf` / `cat <<EOF` pipe in.
 */
function stdinScript(s: Seg, args: readonly string[]): string | null {
  if (args.some(a => !a.startsWith('-'))) return null
  if (s.stdin !== null) return s.stdin
  const from = s.pipeIn
  if (from === null) return null
  const fw = commandWords(from.words)
  const fc = base(fw[0] ?? '')
  if (fc === 'echo' || fc === 'printf') return fw.slice(1).filter(a => !/^-[neE]+$/.test(a)).join(' ').replace(/\\n/g, '\n')
  if (fc === 'cat' && from.stdin !== null) return from.stdin

  return null
}

/**
 * Every command the shell would run, wrappers looked through: each segment's command words, plus the scripts of
 * `bash|zsh|sh -c` (combined flags too), `eval`, and command substitutions, read recursively (depth-capped).
 * classify and runsMonitor both read this one list, so their coverage cannot drift apart.
 */
export function commands(command: string, depth = 0): Cmd[] {
  if (depth > 4) return []
  const out: Cmd[] = []
  for (const inner of substitutions(command)) out.push(...commands(inner, depth + 1))
  for (const s of segmentsDetailed(command)) {
    const seg = s.words
    const words = commandWords(seg)
    if (words.length === 0) continue
    const cmd = base(words[0] ?? '')
    const args = words.slice(1)
    if (SHELLS.has(cmd)) {
      // `-c`, or combined short flags with c in them (`-lc`, `-ec`): the next word is the script.
      const at = args.findIndex(a => /^-[a-zA-Z]*c[a-zA-Z]*$/.test(a))
      const script = at < 0 ? stdinScript(s, args) : args[at + 1]
      if (script !== undefined && script !== null) out.push(...commands(script, depth + 1))
      continue
    }
    if (cmd === 'eval') {
      out.push(...commands(args.join(' '), depth + 1))
      continue
    }
    // Under xargs the arguments come on stdin, so a bare `kb-merge` there still merges.
    out.push({ words, viaXargs: seg.slice(0, seg.length - words.length).some(w => base(w) === 'xargs') })
  }

  return out
}

function classifyCommand({ words, viaXargs }: Cmd): SignalClass | null {
  const cmd = base(words[0] ?? '')
  const args = words.slice(1)
  if (isHelp(args)) return null

  if (cmd === 'kb-merge') return args.length > 0 || viaXargs ? 'merge' : null
  if (cmd === 'gh') {
    const pos = args.filter((a, i) => !a.startsWith('-') && !(i > 0 && (args[i - 1] === '-R' || args[i - 1] === '--repo')))
    if (pos[0] === 'pr' && pos[1] === 'merge') return 'merge'
    if (pos[0] === 'variable' && pos[1] === 'set' && args.includes('TAP_PUBLISHER_ENABLED')) return 'publisher-arming'

    return null
  }
  if (cmd === 'kb-tap-release') {
    if (hasFlag(args, '--dry-run')) return null
    if (args.includes('--push-tap-edit') || args.includes('--push-only')) return 'tap-release'

    return args.some(a => a === 'patch' || a === 'minor' || a === 'major') ? 'tap-release' : null
  }
  if (cmd === 'git') {
    const g = gitSub(args)
    if (g === null) return null
    if ((g.sub === 'add' || g.sub === 'commit') && g.rest.some(a => !a.startsWith('-') && isGitlink(a))) return 'gitlink-stage'

    return null
  }

  return null
}

/** The high-stakes class of a Bash command, or null. The first matching command wins. */
export function classify(command: string): SignalClass | null {
  for (const c of commands(command)) {
    const cls = classifyCommand(c)
    if (cls !== null) return cls
  }

  return null
}

/** True when the command runs kb-pr-monitor (its result is then read for a ROUND_LIMIT verdict). */
export function runsMonitor(command: string): boolean {
  return commands(command).some(c => base(c.words[0] ?? '') === 'kb-pr-monitor' && !isHelp(c.words.slice(1)))
}

/** True when a kb-pr-monitor output ends on a ROUND_LIMIT verdict line. */
export const isRoundLimit = (text: string) => /^VERDICT: ROUND_LIMIT\b/m.test(text)
