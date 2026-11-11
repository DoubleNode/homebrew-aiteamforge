# effort-floor

Before the main chat takes a high-stakes action that no downstream gate re-checks, while the effort being sent is
Low or Medium, effort-floor asks once per turn:

> About to merge a PR at Low effort. Hold it and re-run at High from your next message?

- **Hold, re-run at High**: the call is denied with a stop message ("ask the user to reply go"), and your next
  message's turn is sent at High (released when that turn ends). The action is then re-decided and re-run at High.
- **Run now at Low**: the call runs as it was.
- **Esc** (dismissing the dialog) cancels: the call does not run, nothing is raised, and the rest of that turn's
  high-stakes calls are refused too. With no one to ask (`claude -p`) the call runs as it was (fail open).

The stop message is only advice to the model, so the held turn enforces it: until your next message, every
high-stakes call (the same one again, an equivalent such as `gh pr merge` for `kb-merge`, another class, or a
`kb-pr-monitor` run, which can merge on green) is refused with the same message, without asking again.

It never lowers effort, never applies on its own, uses no model call, ignores subagents, and fails open (a fault
in the mod lets the command run).

## Watched (main chat, Bash)

| Class | Matches | Not matched (near-misses) |
|---|---|---|
| merge | `kb-merge <N>`, `gh pr merge` | `gh pr view`, `kb-merge` alone, `--help` |
| tap release | `kb-tap-release patch\|minor\|major`, `--push-tap-edit`, `--push-only` | `--help`, `--dry-run` |
| gitlink | `git add` / `git commit` naming `homebrew-tap` | `git log` / `git diff homebrew-tap`, `git submodule update` |
| publisher | `gh variable set TAP_PUBLISHER_ENABLED` | `gh variable get`, other variables |
| round limit | a `kb-pr-monitor` result ending `VERDICT: ROUND_LIMIT`: the monitor has already run, so the question is "Pause and decide the next step at High?" and Pause (or Esc) adds the stop message to its result | other verdicts |

Commands are judged by each segment's command word (`&&`, `;`, `|` split; quotes honoured; heredoc bodies,
`bash -c` / `-lc` scripts and `eval` read; wrappers such as `timeout`, `nice`, `caffeinate`, `sudo -u`, `env` and
`xargs` looked through), so text that only mentions a command, such as an `echo` or a commit message, is not a
signal. Shell reserved words (`if`, `do`, `{`, `!`) and command substitution (`$( )`, backticks, also inside double
quotes) are read, and so are `function` bodies and a script a shell reads on stdin (`bash <<'EOF'`, `bash <<< '...'`,
`echo ... | bash`, `cat <<EOF | sh`). `--help` / `--dry-run` count as flags only when they are not an option's value
(`--body "--help"` is a body), and `-h` / `help` only as the first argument.

Not detected: a `git commit` with the gitlink already staged but not named on the line, and a ROUND_LIMIT
verdict from a **backgrounded** `kb-pr-monitor` (its output never reaches the `tool.call` that started it; a
foreground run is caught). A monitor run during a held or cancelled turn is refused either way, since it can merge.
Also out of reach of a structural matcher: a script handed to an interpreter by path (`bash scripts/kb-pr-monitor`)
or code that shells out (`python3 -c "os.system('kb-merge 1')"`). Subagents are not watched, by design, so a held
turn could still delegate the action; the stop message tells the model not to work around the hold.

A quoted heredoc body (`<<'EOF'`) is text, so a commit message or PR body naming `kb-merge` in backticks is not a
signal; an unquoted `<<EOF` body is expanded by the shell, so its substitutions are read.

## Why it holds instead of raising now

Measured on Claude Code 2.1.322 / Opus 5.5 (XACA-1640 Phase 0):

- A `turn.step` effort rewrite on a tool-result step does not reach the request (low, low, low); the same rewrite
  on the step carrying the person's input does, and stays for that turn's tool steps (high, high, high). A
  `tool.call` always fires mid-turn, so the current turn cannot be raised.
- Switching effort between turns does not rebuild the prompt cache: each switch step read the full prefix
  (46.8k and 138.7k tokens) and wrote only ~50 new tokens.

## Commands

`/effort-floor` (status and this chat's offered / held / ran counts), `on`, `off`, `hide` (no footer label), `show`,
`help`. The switch lives in the shared `~/.claude/mods/switches.json` (see `../README.md`). The footer shows
`Held: High from next message (merge)` while a hold waits and `Effort raised: High (merge)` during the raised turn.
