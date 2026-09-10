#!/bin/bash
# test-xaca-1162-dry-run-is-read-only.sh
#
# XACA-1162-003: `aiteamforge setup --dry-run` claimed to preview without
# making changes, but several code paths in bin/aiteamforge-setup.sh ignored
# DRY_RUN entirely and mutated the real system: `brew install --cask
# font-fira-code-nerd-font` (font check), `defaults write com.googlecode.iterm2
# EnableAPIServer -bool true` (both the non-interactive AND interactive
# iTerm2-API-enable branches), `bash -c "$install"` + `exec bash "$0"` (the
# dependency auto-install prompt), and — most severe — the ENTIRE `--uninstall`
# block (LaunchAgent removal, ~/.zshrc rewrite, `rm -rf "$INSTALL_DIR"`), which
# had ZERO DRY_RUN checks: `--uninstall` and `--dry-run` are independent flags,
# and nothing stopped them combining into a preview that actually deletes.
#
# XACA-1162-002 gates all of the above behind DRY_RUN. This suite proves the
# fix BY FILESYSTEM DIFF, never by grepping for the "DRY RUN MODE" banner —
# that log line was already printed unconditionally on the buggy code, so a
# grep-for-the-banner test would have passed throughout the whole incident.
#
# ─────────────────────────────────────────────────────────────────────────────
# THE SAFETY PROBLEM AND HOW THIS SUITE NEUTRALISES IT
# ─────────────────────────────────────────────────────────────────────────────
# The script under test mutates the REAL system when run naively: real `brew
# install`, real `defaults write` on this machine's actual iTerm2
# preferences, real `npm install -g`, real LaunchAgent/zshrc/directory
# deletion. AITeamForge must NEVER be installed on this machine (M3Pro is the
# dev source of truth for the whole fleet — see CLAUDE.md). Every invocation
# below is therefore sandboxed with BOTH layers at once:
#
#   1. HOME redirected to a fresh throwaway directory per case (AITEAMFORGE_DIR
#      pointed under it too) — a fake HOME alone is NOT enough, see (2).
#   2. A PATH-prepended stub bin/ directory intercepts brew, defaults, npm,
#      xcode-select, launchctl, osascript and softwareupdate — each stub logs
#      its full argv to a call-log file and performs NO real action (`defaults
#      read` returns non-zero/empty so the script's own "is it enabled?" check
#      takes the "disabled" branch, which is what exercises the mutation this
#      suite is hunting for). Shim interception is verified live (`command -v`
#      resolves inside the stub dir) BEFORE any real case runs — SELFTEST-1/2
#      below additionally prove the violation-detection regex and the
#      filesystem-snapshot diff can each actually catch something, so a green
#      run here is never "the detector was broken" wearing a passing suit.
#
# `_aitf_launchctl` (common.sh) is ALSO short-circuited via
# AITEAMFORGE_SKIP_LAUNCHCTL=1 as a second, independent safety layer over the
# launchctl PATH stub — belt and suspenders around anything that talks to the
# real, running launchd for this user session.
#
# `AITEAMFORGE_HOME` is pinned explicitly to this tap checkout's root for
# EVERY invocation (of either script variant) rather than left to the script's
# own directory-relative auto-detection — this matters because the pre-fix
# baseline used for the RED run (see below) is a free-standing file outside
# any tap tree, and without an explicit override its self-location logic would
# fall through to `$(brew --prefix)/opt/aiteamforge/libexec` (our fake, stub
# `brew --prefix`), silently failing to source libexec/lib/common.sh — which
# would make `_aitf_launchctl` undefined and crash the uninstall path for the
# WRONG reason (missing function) rather than demonstrating the real bug.
#
# Every subprocess is run under a manual background+watchdog timeout (no
# dependency on GNU coreutils `timeout`/`gtimeout`, which is not guaranteed on
# a bare macOS runner) and is ALWAYS given explicit, finite stdin (never the
# suite's own inherited stdin — the plain-shell CI loop in .github/workflows/
# tests.yml already runs every test with `< /dev/null`, and a `read` against
# empty/exhausted stdin under `set -eo pipefail` simply — and safely —
# terminates the wizard early; several cases below rely on exactly that to
# stay bounded without needing to answer every prompt in a multi-hundred-line
# interactive wizard).
#
# ─────────────────────────────────────────────────────────────────────────────
# MODES COVERED (each gets: fs-diff identity, zero mutating stub calls, DRY
# RUN banner present, exit status sane, real preview progress):
#   CASE 1  `--dry-run`                    (interactive-ish, empty stdin —
#                                            terminates at the first prompt it
#                                            can't answer; still exercises the
#                                            unconditional font-check mutation
#                                            before that point)
#   CASE 2  `--dry-run --non-interactive`  (runs to full wizard completion —
#                                            verified empirically to reach
#                                            "DRY RUN COMPLETE" with zero fs
#                                            writes on the fixed script)
#   CASE 3  `--uninstall --dry-run`        (fixture pre-populates a configured
#                                            install — .aiteamforge-config,
#                                            both LaunchAgent plists, a
#                                            zshrc block — so is_configured()
#                                            is true and the destructive
#                                            branch is actually reached; fed
#                                            "yes\nyes\n" so it would answer
#                                            BOTH confirmation prompts if the
#                                            pre-fix code ever asked them)
#   CASE 4  `--dry-run` with dependency checks forced non-empty (bonus,
#           beyond the three required modes — targets the `bash -c "$install"`
#           + `exec bash "$0"` dependency-auto-install path specifically,
#           which no combination of the other three modes can reach: the
#           non-interactive branch never calls it at all, pre- or post-fix,
#           and the plain interactive case's empty stdin dies at an earlier
#           prompt before ever reaching it). PATH is narrowed to
#           stubbin:/usr/bin:/bin:/usr/sbin:/sbin — excluding
#           /opt/homebrew/bin and friends — which deterministically makes
#           node/gh/tmux/claude report "missing" on any machine regardless of
#           what's actually installed, without needing to fake `command -v`
#           itself. Bounded: fed exactly "yes\nyes\n", so a pre-fix exec-loop
#           re-runs the wizard exactly once before stdin exhaustion EOF-kills
#           it (verified empirically, see RED report) — never an unbounded
#           loop even before the wrapper's watchdog kill would fire.
#
# Each case's target script defaults to the real, shipped
# bin/aiteamforge-setup.sh (so this suite is a permanent CI regression guard
# on the fixed script) but honors AITF_SETUP_SCRIPT_UNDER_TEST to point at any
# other copy — this is how the pre-fix baseline (`git show
# c61cb5c2061bfafea6e0700139f40df4cc40bf83:bin/aiteamforge-setup.sh`) was
# proven to fail every one of these cases before landing this file; that RED
# run is reported separately (it is not part of the committed, always-green
# CI assertions below — embedding the ~2000-line pre-fix script verbatim as a
# negative control was judged not worth the bloat versus a targeted, reported
# manual run with the same harness).
#
# Runs standalone (`bash tests/test-xaca-1162-dry-run-is-read-only.sh`) OR via
# tests/test-runner.sh. Exit 0 = all assertions pass, exit 1 = any fail.
# bash-3.2 compatible (no `declare -A`, no bash-4-only syntax) — CI's
# plain-shell loop invokes this under whatever `bash` resolves to on a
# macOS runner, which is the system /bin/bash 3.2, not Homebrew's bash 5.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SETUP_SCRIPT="${AITF_SETUP_SCRIPT_UNDER_TEST:-$TAP_ROOT/bin/aiteamforge-setup.sh}"

if [ ! -f "$SETUP_SCRIPT" ]; then
    echo "FATAL: setup script not found: $SETUP_SCRIPT" >&2
    exit 1
fi
chmod +x "$SETUP_SCRIPT" 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework (works sourced by test-runner.sh OR invoked directly).
# ─────────────────────────────────────────────────────────────────────────────
_STANDALONE=false
if ! type -t test_start >/dev/null 2>&1; then
    _STANDALONE=true
    test_start() { _CURRENT_TEST="$1"; echo "  >> $1"; }
    test_pass()  { echo "     PASS: $_CURRENT_TEST"; }
    test_fail()  { echo "     FAIL: $_CURRENT_TEST — $1" >&2; }
fi

# ─────────────────────────────────────────────────────────────────────────────
# EXPLICIT pass/fail counters — independent of the outer harness (known trap:
# feedback_tap_test_harness_vacuous_green — tap assert_* helpers record only
# on FAILURE, so a suite that runs zero real assertions prints "All tests
# passed" vacuously). We increment on EVERY assertion and gate the final exit
# on both zero failures AND a non-zero total.
# ─────────────────────────────────────────────────────────────────────────────
_PASS=0
_FAIL=0

# ok <label> <cond(1|0)> [failure_detail]
ok() {
    local label="$1" cond="$2" detail="${3:-}"
    test_start "$label"
    if [ "$cond" = "1" ]; then
        _PASS=$((_PASS + 1)); test_pass
    else
        _FAIL=$((_FAIL + 1)); test_fail "$detail"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Temp directory.
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca1162-dryrun-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
TEST_TMP_DIR="$(cd "$TEST_TMP_DIR" && pwd -P)"
WORK_DIR="$TEST_TMP_DIR/xaca1162"
mkdir -p "$WORK_DIR"
cleanup() { if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ] && [ -d "${TEST_TMP_DIR:-}" ]; then find "$TEST_TMP_DIR" -depth -delete 2>/dev/null || true; fi; }
trap cleanup EXIT

REAL_PATH="$PATH"

# ─────────────────────────────────────────────────────────────────────────────
# Stub bin/ dir — one shared set of 7 stub executables, reused by every case.
# Each stub logs its own basename + full argv to $AITF_STUB_LOG (set per-case
# in the environment before invoking the target script) and takes NO real
# action, with two narrow exceptions needed to drive the target script down
# the branches this suite is hunting for:
#   - `brew --prefix` prints AITF_FAKE_BREW_PREFIX (a nonexistent path with no
#     Caskroom) so the font check's Caskroom lookup deterministically misses
#     and falls through to the `brew install --cask ...` line, regardless of
#     what is or isn't actually installed via real Homebrew on the host.
#   - `defaults read ...` exits 1 with no stdout, so `api_enabled` resolves
#     empty and the script takes the "disabled" branch — the one branch that
#     can call `defaults write`.
# ─────────────────────────────────────────────────────────────────────────────
STUB_BIN="$WORK_DIR/stubbin"
mkdir -p "$STUB_BIN"
for _tool in brew defaults npm xcode-select launchctl osascript softwareupdate; do
cat > "$STUB_BIN/$_tool" <<'STUBEOF'
#!/bin/sh
# Safety stub — logs full argv, performs NO real action (except `defaults
# read`, which must fail to drive the target script's "disabled" branch).
_prog="$(basename "$0")"
{
  printf '%s' "$_prog"
  for _a in "$@"; do printf ' %s' "$_a"; done
  printf '\n'
} >> "${AITF_STUB_LOG:-/dev/null}"

case "$_prog" in
  brew)
    if [ "$1" = "--prefix" ]; then
      printf '%s\n' "${AITF_FAKE_BREW_PREFIX:-/nonexistent-fake-brew-prefix}"
    fi
    ;;
  defaults)
    if [ "$1" = "read" ]; then
      exit 1
    fi
    ;;
  xcode-select)
    if [ "$1" = "-p" ]; then
      printf '%s\n' "/Library/Developer/CommandLineTools"
    fi
    ;;
esac
exit 0
STUBEOF
chmod +x "$STUB_BIN/$_tool"
done
unset _tool

# ─────────────────────────────────────────────────────────────────────────────
# Violation patterns — the EXACT mutating invocations this suite must never
# see in a stub log. Deliberately narrow: `brew tap` (bare, no argument) is a
# legitimate READ-ONLY "list current taps" query the script runs unconditionally
# during a normal preview (XACA-0676 tap-trust check) — a broader `brew
# (install|tap)` pattern was tried during development and produced a FALSE
# POSITIVE against the fixed script's own benign `brew tap` call. Verified via
# manual dry-run trial before being narrowed to this list.
# ─────────────────────────────────────────────────────────────────────────────
VIOLATION_PATTERNS='^brew install|^defaults write|^npm install|^xcode-select .*--install|^launchctl (load|unload)'

# find_violations <stublog>
find_violations() {
    grep -E "$VIOLATION_PATTERNS" "$1" 2>/dev/null || true
}

# assert_shim_active <label> <path_value>
assert_shim_active() {
    local label="$1" path_value="$2" tool resolved all_ok=1 detail=""
    for tool in brew defaults npm xcode-select launchctl osascript softwareupdate; do
        resolved="$(PATH="$path_value" command -v "$tool" 2>/dev/null || true)"
        if [ "$resolved" != "$STUB_BIN/$tool" ]; then
            all_ok=0
            detail="$detail [$tool -> ${resolved:-<not found>}]"
        fi
    done
    ok "$label" "$all_ok" "expected every tool to resolve under $STUB_BIN/; mismatches:$detail"
}

# snapshot_fs <dir> — sorted "name|size|mtime|perms" lines for every entry
# under dir. Two independent runs over an untouched tree must be byte-
# identical; any create/modify/delete changes at least one line.
snapshot_fs() {
    find "$1" -exec stat -f '%N|%z|%Sm|%Lp' {} \; 2>/dev/null | LC_ALL=C sort
}

# ─────────────────────────────────────────────────────────────────────────────
# SELFTEST 1/2 — prove the detection machinery itself can fail before trusting
# any "clean" verdict from it (the vacuous-green trap: a broken detector and a
# genuinely clean run are indistinguishable unless something first proves the
# detector CAN catch a planted violation).
# ─────────────────────────────────────────────────────────────────────────────
_SELFTEST_LOG="$WORK_DIR/selftest-stub.log"
: > "$_SELFTEST_LOG"
AITF_STUB_LOG="$_SELFTEST_LOG" "$STUB_BIN/brew" install --cask font-fira-code-nerd-font >/dev/null 2>&1
AITF_STUB_LOG="$_SELFTEST_LOG" "$STUB_BIN/defaults" write com.googlecode.iterm2 EnableAPIServer -bool true >/dev/null 2>&1
AITF_STUB_LOG="$_SELFTEST_LOG" "$STUB_BIN/brew" tap >/dev/null 2>&1
_SELFTEST_VIOL="$(find_violations "$_SELFTEST_LOG")"
_SELFTEST_VIOL_LINES=$(printf '%s\n' "$_SELFTEST_VIOL" | grep -c . || true)
ok "SELFTEST-1: violation regex catches planted brew-install + defaults-write, ignores bare brew-tap" \
   "$([ "$_SELFTEST_VIOL_LINES" = "2" ] && echo 1 || echo 0)" \
   "expected exactly 2 matching lines; got $_SELFTEST_VIOL_LINES: [$_SELFTEST_VIOL]"

_SELFTEST_FS_DIR="$WORK_DIR/selftest-fs"
mkdir -p "$_SELFTEST_FS_DIR"
_SELFTEST_FS_BEFORE="$(snapshot_fs "$_SELFTEST_FS_DIR")"
echo canary > "$_SELFTEST_FS_DIR/canary-file"
_SELFTEST_FS_AFTER="$(snapshot_fs "$_SELFTEST_FS_DIR")"
ok "SELFTEST-2: snapshot_fs detects a planted new file" \
   "$([ "$_SELFTEST_FS_BEFORE" != "$_SELFTEST_FS_AFTER" ] && echo 1 || echo 0)" \
   "before and after snapshots were identical — the detector cannot see filesystem changes"

# Shim-interception check, BEFORE any real case runs, for both PATH shapes
# this suite uses.
RESTRICTED_PATH="$STUB_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
assert_shim_active "Shim interception (default PATH shape): stub dir wins over real PATH" "$STUB_BIN:$REAL_PATH"
assert_shim_active "Shim interception (restricted PATH shape, CASE 4): stub dir wins" "$RESTRICTED_PATH"

# Confirm the restricted PATH actually makes node/gh/tmux/claude report
# missing (the forcing function CASE 4 depends on) — a stale assumption here
# would silently turn CASE 4 into a no-op duplicate of CASE 1.
_DEPS_MISSING_OK=1
_DEPS_DETAIL=""
for _dep in node gh tmux claude; do
    if PATH="$RESTRICTED_PATH" command -v "$_dep" >/dev/null 2>&1; then
        _DEPS_MISSING_OK=0
        _DEPS_DETAIL="$_DEPS_DETAIL $_dep(unexpectedly found)"
    fi
done
unset _dep
ok "CASE 4 precondition: node/gh/tmux/claude are NOT on the restricted PATH" "$_DEPS_MISSING_OK" "unexpected hits:$_DEPS_DETAIL"

# ─────────────────────────────────────────────────────────────────────────────
# run_case — invoke $SETUP_SCRIPT under full sandboxing, bounded by a manual
# background+watchdog timeout (no dependency on GNU coreutils timeout/
# gtimeout). Populates the LAST_* globals for the caller's assertions.
#
#   run_case <home_dir> <path_value> <stdin_file> <timeout_secs> <args...>
# ─────────────────────────────────────────────────────────────────────────────
LAST_RC=""
LAST_OUT=""
LAST_STUBLOG=""
LAST_BEFORE=""
LAST_AFTER=""

run_case() {
    local home_dir="$1" path_value="$2" stdin_file="$3" timeout_secs="$4"
    shift 4
    local case_dir stublog fakeprefix outfile pid watcher rc

    case_dir="$WORK_DIR/run-$$-$RANDOM"
    mkdir -p "$case_dir"
    stublog="$case_dir/stub.log"
    : > "$stublog"
    fakeprefix="$case_dir/fake-brew-prefix"
    outfile="$case_dir/output.log"

    LAST_BEFORE="$(snapshot_fs "$home_dir")"

    env AITF_STUB_LOG="$stublog" AITF_FAKE_BREW_PREFIX="$fakeprefix" \
        HOME="$home_dir" AITEAMFORGE_DIR="$home_dir/aiteamforge" \
        AITEAMFORGE_HOME="$TAP_ROOT" AITEAMFORGE_SKIP_LAUNCHCTL=1 \
        PATH="$path_value" \
        "$SETUP_SCRIPT" "$@" <"$stdin_file" >"$outfile" 2>&1 &
    pid=$!

    ( sleep "$timeout_secs"; kill -9 "$pid" 2>/dev/null ) &
    watcher=$!

    wait "$pid" 2>/dev/null
    rc=$?

    kill "$watcher" 2>/dev/null
    wait "$watcher" 2>/dev/null

    LAST_RC="$rc"
    LAST_OUT="$outfile"
    LAST_STUBLOG="$stublog"
    LAST_AFTER="$(snapshot_fs "$home_dir")"
}

# assert_case_common <label_prefix> <expect_progress_marker>
# Shared assertions every case needs: fs identity, zero violations, DRY RUN
# banner, sane exit status, and real progress beyond the first line.
assert_case_common() {
    local prefix="$1" progress_marker="$2" viol rc_sane

    ok "$prefix: filesystem under HOME is byte-identical before/after" \
       "$([ "$LAST_BEFORE" = "$LAST_AFTER" ] && echo 1 || echo 0)" \
       "diff:$(diff <(printf '%s\n' "$LAST_BEFORE") <(printf '%s\n' "$LAST_AFTER") 2>&1)"

    viol="$(find_violations "$LAST_STUBLOG")"
    ok "$prefix: zero mutating stub invocations (brew install / defaults write / npm install / xcode-select --install / launchctl load|unload)" \
       "$([ -z "$viol" ] && echo 1 || echo 0)" \
       "violations found: [$viol] (full stub log: $(cat "$LAST_STUBLOG" 2>/dev/null | tr '\n' ';'))"

    ok "$prefix: DRY RUN MODE banner printed" \
       "$(grep -q "DRY RUN MODE" "$LAST_OUT" 2>/dev/null && echo 1 || echo 0)" \
       "output was: $(cat "$LAST_OUT" 2>/dev/null | tr '\n' ' ' | cut -c1-500)"

    rc_sane=0
    if [ "$LAST_RC" = "0" ] || [ "$LAST_RC" = "1" ]; then rc_sane=1; fi
    ok "$prefix: exit status sane (0 or 1, not a timeout-kill/crash signal)" "$rc_sane" "rc=$LAST_RC"

    if [ -n "$progress_marker" ]; then
        ok "$prefix: preview progressed past the banner (not a trivial immediate exit)" \
           "$(grep -q "$progress_marker" "$LAST_OUT" 2>/dev/null && echo 1 || echo 0)" \
           "expected to find '$progress_marker' in output"
    fi
}

EMPTY_STDIN="$WORK_DIR/stdin-empty.txt"
: > "$EMPTY_STDIN"
YESYES_STDIN="$WORK_DIR/stdin-yesyes.txt"
printf 'yes\nyes\n' > "$YESYES_STDIN"

# ─────────────────────────────────────────────────────────────────────────────
# CASE 1: `--dry-run` (interactive-ish path, empty stdin)
# ─────────────────────────────────────────────────────────────────────────────
HOME_C1="$WORK_DIR/home-c1"
mkdir -p "$HOME_C1"
run_case "$HOME_C1" "$STUB_BIN:$REAL_PATH" "$EMPTY_STDIN" 15 --dry-run
assert_case_common "CASE1 (--dry-run)" "Checking dependencies"

# ─────────────────────────────────────────────────────────────────────────────
# CASE 2: `--dry-run --non-interactive` (runs the full wizard to completion —
# verified empirically to reach "DRY RUN COMPLETE" on the fixed script with
# zero filesystem writes)
# ─────────────────────────────────────────────────────────────────────────────
HOME_C2="$WORK_DIR/home-c2"
mkdir -p "$HOME_C2"
run_case "$HOME_C2" "$STUB_BIN:$REAL_PATH" "$EMPTY_STDIN" 30 --dry-run --non-interactive
assert_case_common "CASE2 (--dry-run --non-interactive)" "Checking dependencies"
ok "CASE2: wizard reached full completion (DRY RUN COMPLETE), not a partial/aborted run" \
   "$(grep -q "DRY RUN COMPLETE" "$LAST_OUT" 2>/dev/null && echo 1 || echo 0)" \
   "expected 'DRY RUN COMPLETE' in output; tail: $(tail -c 500 "$LAST_OUT" 2>/dev/null)"

# ─────────────────────────────────────────────────────────────────────────────
# CASE 3: `--uninstall --dry-run` — the most severe pre-fix case. Fixture
# pre-populates a "configured" install (is_configured() checks for
# INSTALL_DIR/.aiteamforge-config) so the destructive branch is genuinely
# reached rather than short-circuited by the "not configured" early exit.
# Fed "yes\nyes\n" so BOTH confirmation prompts ("Continue with uninstall?",
# "Remove working directory?") would be answered if the pre-fix code asked
# them — proving the fix isn't merely "the prompt never fires", but that the
# whole destructive body is skipped.
# ─────────────────────────────────────────────────────────────────────────────
HOME_C3="$WORK_DIR/home-c3"
mkdir -p "$HOME_C3/aiteamforge"
: > "$HOME_C3/aiteamforge/.aiteamforge-config"
mkdir -p "$HOME_C3/Library/LaunchAgents"
cat > "$HOME_C3/Library/LaunchAgents/com.aiteamforge.kanban-backup.plist" <<'PLISTEOF'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>Label</key><string>com.aiteamforge.kanban-backup</string></dict></plist>
PLISTEOF
cat > "$HOME_C3/Library/LaunchAgents/com.aiteamforge.lcars-health.plist" <<'PLISTEOF'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>Label</key><string>com.aiteamforge.lcars-health</string></dict></plist>
PLISTEOF
cat > "$HOME_C3/.zshrc" <<'ZSHRCEOF'
# prior shell content, unrelated to aiteamforge
echo "hello from .zshrc"
# >>> aiteamforge initialize >>>
export AITEAMFORGE_HOME=fake-for-test
# <<< aiteamforge initialize <<<
# trailing shell content
ZSHRCEOF

run_case "$HOME_C3" "$STUB_BIN:$REAL_PATH" "$YESYES_STDIN" 15 --uninstall --dry-run
assert_case_common "CASE3 (--uninstall --dry-run)" ""
ok "CASE3: uninstall preview text present (proves the uninstall path was actually reached, not skipped as 'not configured')" \
   "$(grep -qE "uninstall preview complete|AITeamForge Uninstall" "$LAST_OUT" 2>/dev/null && echo 1 || echo 0)" \
   "output: $(cat "$LAST_OUT" 2>/dev/null | tr '\n' ' ' | cut -c1-500)"
# Directly name the three destructive artifacts the fixture planted — this is
# the sharpest, most legible evidence: each must still exist, byte-for-byte
# unchanged in the case of the plists/zshrc, after a --dry-run run.
ok "CASE3: kanban-backup LaunchAgent plist still present" \
   "$([ -f "$HOME_C3/Library/LaunchAgents/com.aiteamforge.kanban-backup.plist" ] && echo 1 || echo 0)" \
   "plist was removed by a --dry-run run"
ok "CASE3: lcars-health LaunchAgent plist still present" \
   "$([ -f "$HOME_C3/Library/LaunchAgents/com.aiteamforge.lcars-health.plist" ] && echo 1 || echo 0)" \
   "plist was removed by a --dry-run run"
ok "CASE3: .aiteamforge-config / install dir still present (not rm -rf'd)" \
   "$([ -f "$HOME_C3/aiteamforge/.aiteamforge-config" ] && echo 1 || echo 0)" \
   "install dir was removed by a --dry-run run"
ok "CASE3: .zshrc was not rewritten (no .backup file created, aiteamforge block intact)" \
   "$(grep -q "aiteamforge initialize" "$HOME_C3/.zshrc" 2>/dev/null && ! ls "$HOME_C3"/.zshrc.backup.* >/dev/null 2>&1 && echo 1 || echo 0)" \
   ".zshrc contents: $(cat "$HOME_C3/.zshrc" 2>/dev/null | tr '\n' ' '); backups: $(ls "$HOME_C3"/.zshrc.backup.* 2>/dev/null)"

# ─────────────────────────────────────────────────────────────────────────────
# CASE 4 (bonus, beyond the three required modes): `--dry-run` with the
# dependency-missing prompt path forced reachable, targeting `bash -c
# "$install"` + `exec bash "$0"` specifically. PATH is narrowed (not just
# prepended) to exclude /opt/homebrew/bin and similar, so node/gh/tmux/claude
# report "missing" deterministically regardless of what is actually installed
# on the host running this suite (precondition verified above). Fed
# "yes\nyes\n": on pre-fix code this answers the iTerm2-API-enable prompt then
# the install-deps prompt, triggering the bug and the `exec` restart; the
# restarted pass's first read then hits stdin EOF and set -e terminates it —
# bounded to exactly one exec cycle, verified empirically, never an unbounded
# loop.
# ─────────────────────────────────────────────────────────────────────────────
HOME_C4="$WORK_DIR/home-c4"
mkdir -p "$HOME_C4"
run_case "$HOME_C4" "$RESTRICTED_PATH" "$YESYES_STDIN" 30 --dry-run
assert_case_common "CASE4 (--dry-run, deps forced missing)" "Checking dependencies"

# ─────────────────────────────────────────────────────────────────────────────
# Summary — explicit real assertion count (defeats vacuous-green).
# ─────────────────────────────────────────────────────────────────────────────
_TOTAL=$((_PASS + _FAIL))
echo ""
echo "──────────────────────────────────────────────────────────────"
echo "XACA-1162 dry-run-is-read-only: Passed: ${_PASS} / Total: ${_TOTAL}  (Failed: ${_FAIL})"
echo "Target script: $SETUP_SCRIPT"
echo "──────────────────────────────────────────────────────────────"

if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "Results: ${_PASS} passed, ${_FAIL} failed"
fi

if [ "$_FAIL" -gt 0 ] || [ "$_TOTAL" -eq 0 ]; then
    exit 1
fi
exit 0
