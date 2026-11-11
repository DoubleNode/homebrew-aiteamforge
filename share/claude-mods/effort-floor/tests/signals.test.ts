import { expect, test } from 'claude-code/testing'

import { classify, isRoundLimit, runsMonitor, segments } from '../hooks/signals'

// XACA-1640-002: positives, and the near-misses that must stay `null`.
const POSITIVE: Array<[string, string]> = [
  ['kb-merge 1315', 'merge'],
  ['gh pr merge 1315 --squash --delete-branch --admin', 'merge'],
  ['gh pr merge 1315 -R DoubleNode/dev-team --squash', 'merge'],
  ['gh -R DoubleNode/dev-team pr merge 1315', 'merge'],
  ['cd /repo && source kanban-helpers.sh && kb-merge 1315', 'merge'],
  ['/Users/me/aiteamforge/scripts/kb-merge 1315', 'merge'],
  ['bash -c "kb-merge 1315"', 'merge'],
  ['scripts/kb-tap-release patch > /tmp/rel.log 2>&1', 'tap-release'],
  ['KB_TAP_RELEASE_LOCK_WAIT=600 kb-tap-release minor', 'tap-release'],
  ['kb-tap-release --push-tap-edit', 'tap-release'],
  ['git add homebrew-tap', 'gitlink-stage'],
  ['git add homebrew-tap/ CHANGELOG.md', 'gitlink-stage'],
  ['git -C /repo add homebrew-tap', 'gitlink-stage'],
  ['git commit -m "bump" homebrew-tap', 'gitlink-stage'],
  ['git add /Users/Shared/dev-team/homebrew-tap && git commit -m x', 'gitlink-stage'],
  ['gh variable set TAP_PUBLISHER_ENABLED --body true', 'publisher-arming'],
  ['gh variable set TAP_PUBLISHER_ENABLED -R o/r -b true', 'publisher-arming'],
  // Wrappers (PR #1320 advisory): each runs the command after it.
  ['timeout 600 kb-merge 1', 'merge'],
  ['timeout -s KILL 30m kb-merge 1', 'merge'],
  ['nice -n 5 kb-tap-release patch', 'tap-release'],
  ['nice kb-merge 1', 'merge'],
  ['caffeinate -i kb-tap-release patch', 'tap-release'],
  ['caffeinate -t 600 kb-merge 1', 'merge'],
  ['sudo -u me kb-merge 1', 'merge'],
  ['env -i kb-merge 1', 'merge'],
  ['env -u HOME kb-merge 1', 'merge'],
  ['echo 1315 | xargs kb-merge', 'merge'],
  ['echo 1315 | xargs -I {} kb-merge {}', 'merge'],
  ['eval "kb-merge 1"', 'merge'],
  ['bash -lc "kb-merge 1"', 'merge'],
  ['zsh -ec \'gh pr merge 1 --squash\'', 'merge'],
  ['kb-tap-release --push-only', 'tap-release'],
  // Reserved words and command substitution (PR #1320 test gate).
  ['if kb-merge 1; then echo ok; fi', 'merge'],
  ['for n in 1 2; do kb-merge $n; done', 'merge'],
  ['while true; do gh pr merge 1; done', 'merge'],
  ['{ kb-merge 1; }', 'merge'],
  ['! kb-merge 1', 'merge'],
  ['[ -n "$X" ] && then_var=1 || kb-tap-release patch', 'tap-release'],
  ['out=`kb-merge 1`', 'merge'],
  ['echo "result: $(kb-merge 1)"', 'merge'],
  ['echo "`gh pr merge 1 --squash`"', 'merge'],
  ['x=$(cd /r && $(echo kb-merge) 1; kb-tap-release minor)', 'tap-release'],
  // An option VALUE must not switch detection off.
  ['gh variable set TAP_PUBLISHER_ENABLED -b help', 'publisher-arming'],
  ['kb-tap-release patch --notes -n', 'tap-release'],
  ['gh pr merge 1 --body help', 'merge'],
  // PR #1320 test gate 022: option values equal to a flag, function bodies, scripts a shell reads on stdin.
  ['gh pr merge 1 --body "--help"', 'merge'],
  ['gh pr merge 1 -b --help --squash', 'merge'],
  ['kb-tap-release patch --notes "--dry-run"', 'tap-release'],
  ['function m { kb-merge 1; }; m', 'merge'],
  ['m() { gh pr merge 1; }; m', 'merge'],
  ['bash <<< "kb-merge 1"', 'merge'],
  ["bash <<<'kb-tap-release patch'", 'tap-release'],
  ["bash <<'EOF'\nkb-merge 1\nEOF", 'merge'],
  ['sh <<-EOF\n\tgit add homebrew-tap\n\tEOF', 'gitlink-stage'],
  ['echo "kb-merge 1" | bash', 'merge'],
  ["printf 'gh pr merge 1\\n' | sh", 'merge'],
  ["cat <<'EOF' | bash\nkb-tap-release minor\nEOF", 'tap-release'],
  ['echo kb-merge 1 |& zsh -s', 'merge'],
]

const NEGATIVE: string[] = [
  'gh pr view 1315',
  'gh pr merge --help',
  'kb-merge --help',
  'kb-merge',
  'kb-tap-release --help',
  'kb-tap-release patch --dry-run',
  'kb-tap-release',
  'git log homebrew-tap',
  'git diff homebrew-tap',
  'git submodule update homebrew-tap',
  'git add homebrew-tap-notes.md',
  'gh variable get TAP_PUBLISHER_ENABLED',
  'gh variable set OTHER_VAR --body true',
  'timeout 600 gh pr view 1',
  'bash -l script.sh',
  'eval "echo kb-merge 1"',
  "echo '$(kb-merge 1)'",
  "echo 'out=`kb-merge 1`'",
  'kb-merge -h',
  'kb-tap-release help',
  'git commit -m "if kb-merge 1; then done"',
  // A shell given a script FILE reads stdin as data; a pipe into a non-shell is data; `||` is not a pipe.
  "bash run.sh <<'EOF'\nkb-merge 1\nEOF",
  'echo "kb-merge 1" | grep kb',
  'echo "kb-merge 1" || bash',
  "cat <<'EOF' > notes.md\nkb-merge 1\nEOF",
  'gh pr merge --help',
  'gh pr merge 1 --squash --help',
  'kb-tap-release patch --dry-run --notes x',
  'echo "kb-merge 1315"',
  "grep -n 'gh pr merge' CLAUDE.md",
  'git commit -m "kb-merge 1315 then gh pr merge"',
  '# kb-merge 1315',
  'cat > /tmp/x.md <<\'EOF\'\nkb-merge 1315\ngh pr merge 7\nEOF\nwc -l /tmp/x.md',
  'git commit -F - <<EOF\nchore: bump homebrew-tap\n\ngit add homebrew-tap\nEOF',
  '',
]

test('signals: every positive row classifies to its class', () => {
  for (const [cmd, cls] of POSITIVE) expect(classify(cmd), cmd).toBe(cls)
})

test('signals: every near-miss is null', () => {
  for (const cmd of NEGATIVE) expect(classify(cmd), cmd).toBeNull()
})

test('signals: a heredoc body is skipped but the line after the terminator is read', () => {
  expect(classify('cat <<EOF\nnothing here\nEOF\nkb-merge 12')).toBe('merge')
  expect(classify('cat <<-EOF\n\tkb-merge 12\n\tEOF\necho ok')).toBeNull()
})

// PR #1320 review round 2: a QUOTED heredoc body is never expanded, so a backtick or $( ) mention inside it is
// text, not a command; an unquoted <<EOF body IS expanded (the positive control). This is how this repo writes
// commit messages and PR bodies, which routinely name `kb-merge` / `gh pr merge` in backticks.
const HEREDOC: Array<[string, string | null]> = [
  ['gh pr create --body "$(cat <<\'EOF\'\nthen `gh pr merge 5`\nEOF\n)"', null],
  ['git commit -m "$(cat <<\'EOF\'\nfix `kb-merge 1` docs\nEOF\n)"', null],
  ['git commit -F - <<\'EOF\'\nBump `git add homebrew-tap`\nEOF', null],
  ['cat > f.md <<\'EOF\'\nrun `kb-merge 12`\nEOF', null],
  ['cat > f <<\'EOF\'\nsee $(kb-merge 3)\nEOF', null],
  ['cat > f <<"EOF"\nsee `kb-merge 3`\nEOF', null],
  ['cat > f <<-\'EOF\'\n\tsee `kb-tap-release patch`\n\tEOF', null],
  ['gh pr create --body "$(cat <<\'EOF\'\n## Summary\nuse `kb-merge` (it\'s safe) and $(gh pr merge 9)\nEOF\n)" --title x', null],
  ['gh pr comment 1 --body \'use `kb-merge 1`\'', null],
  // Positive controls: the shell expands these.
  ['cat > f <<EOF\nsee `kb-merge 3`\nEOF', 'merge'],
  ['cat > f <<EOF\nit\'s $(kb-tap-release patch)\nEOF', 'tap-release'],
  ['git commit -m "$(cat <<\'EOF\'\nnotes\nEOF\n)" && kb-merge 7', 'merge'],
  ['x="$(cat <<EOF\n`kb-merge 2`\nEOF\n)"', 'merge'],
]

// PR #1320 test gate 024: the delimiter is a shell WORD (any quoting = not expanded), `<<` in (( )) is a shift,
// and the end line must match exactly (tabs stripped only under <<-).
const DELIMITER: Array<[string, string | null]> = [
  ['cat > f <<\\EOF\nsee `kb-merge 3`\nEOF', null],
  ['cat > f <<-\\EOF\n\tsee `kb-merge 3`\n\tEOF', null],
  ['cat > f << \\EOF\nsee `kb-merge 3`\nEOF', null],
  ["cat > f <<E'O'F\nsee `kb-merge 3`\nEOF", null],
  ['cat > f <<E\\OF\nsee `kb-merge 3`\nEOF', null],
  ['cat > f <<EOF""\nsee `kb-merge 3`\nEOF', null],
  ["cat > f <<$'EOF'\nsee `kb-merge 3`\nEOF", null],
  ["cat <<'E'OF\nx\nEOF\nkb-merge 2", 'merge'],
  ['cat <<"E"OF\nx\nEOF\nkb-merge 2', 'merge'],
  ['y=$((1<<X))\nkb-merge 1', 'merge'],
  ['(( y = 1<<X ))\nkb-merge 1', 'merge'],
  ["cat <<'EOF'\n EOF\nkb-merge 1\nEOF", null],
  ['cat <<EOF\n\tEOF\n`kb-merge 1`\nEOF', 'merge'],
  ['cat <<EOF\n\tEOF\nkb-merge 1\nEOF', null],
  // PR #1320 review round 4: the round-3 rows verbatim. Delimiters with `-`, `.` or a leading digit; the
  // unquoted forms were the fail-open (terminator never matched, a later merge swallowed).
  ['cat > f <<END-MSG\nx\nEND-MSG\nkb-merge 1', 'merge'],
  ['cat > f <<EOF.txt\nx\nEOF.txt\ngh pr merge 1 --squash', 'merge'],
  ["git commit -F - <<'END-MSG'\nfix: kb-merge docs\n\nkb-merge 12 now refuses\nEND-MSG", null],
  ["cat > f <<'END-MSG'\nsee `kb-merge 3`\nEND-MSG", null],
  ["cat > f <<'EOF.txt'\nkb-merge 3\nEOF.txt", null],
  ["cat > f <<'1EOF'\nkb-merge 3\n1EOF", null],
  ['git commit -F - <<\\EOF\nsee `gh pr merge 3`\nEOF', null],
  // Controls the tester confirmed correct, kept.
  ["cat <<'EOF'\nkb-merge 1\nEOF", null],
  ['cat << \'EOF\'\nkb-merge 1\nEOF', null],
  ["cat <<'E'OF\nx\nEOF", null],
  ["echo '<<EOF'\nkb-merge 1", 'merge'],
  ['echo x # <<EOF\nkb-merge 1', 'merge'],
  ['bash <<<"kb-merge 1"', 'merge'],
]

test('signals: heredoc delimiters follow the shell word rules', () => {
  for (const [cmd, cls] of DELIMITER) expect(classify(cmd), JSON.stringify(cmd)).toBe(cls)
})

// PR #1320 advisory 026: the monitor check shares the walker, so the same table must hold for it too.
test('signals: runsMonitor reads heredoc delimiters the same way', () => {
  for (const [cmd, cls] of DELIMITER) {
    if (!cmd.includes('kb-merge')) continue
    const mon = cmd.replace(/kb-merge \d+/g, 'kb-pr-monitor --pr 1 --item X')
    expect(runsMonitor(mon), JSON.stringify(mon)).toBe(cls !== null)
  }
})

test('signals: heredoc bodies are read as the shell expands them', () => {
  for (const [cmd, cls] of HEREDOC) expect(classify(cmd), JSON.stringify(cmd)).toBe(cls)
})

test('signals: segments honour quotes and operators', () => {
  expect(segments('a "b && c" && d | e; f')).toEqual([['a', 'b && c'], ['d'], ['e'], ['f']])
  expect(segments("x 'y z'\nw")).toEqual([['x', 'y z'], ['w']])
})

test('signals: kb-pr-monitor and its ROUND_LIMIT verdict', () => {
  expect(runsMonitor('/x/scripts/kb-pr-monitor --pr 1 --item XACA-1')).toBe(true)
  expect(runsMonitor('kb-pr-monitor --help')).toBe(false)
  expect(runsMonitor('echo kb-pr-monitor')).toBe(false)
  // Same walker as classify (PR #1320 test gate: runsMonitor had the same gaps).
  for (const cmd of [
    'timeout 3600 kb-pr-monitor --pr 1 --item X',
    'bash -lc "kb-pr-monitor --pr 1 --item X"',
    'out=$(kb-pr-monitor --pr 1 --item X)',
    'if kb-pr-monitor --pr 1 --item X; then echo ok; fi',
    'eval "kb-pr-monitor --pr 1"',
    'caffeinate -i kb-pr-monitor --pr 1 --item X',
  ]) expect(runsMonitor(cmd), cmd).toBe(true)
  expect(runsMonitor("echo '$(kb-pr-monitor --pr 1)'")).toBe(false)
  expect(isRoundLimit('poll\nVERDICT: ROUND_LIMIT pr=1 item=X detail=y')).toBe(true)
  expect(isRoundLimit('VERDICT: GATES_PASSED pr=1')).toBe(false)
  expect(isRoundLimit('the ROUND_LIMIT verdict')).toBe(false)
})
