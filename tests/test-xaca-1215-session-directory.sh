#!/bin/bash
# test-xaca-1215-session-directory.sh
# Regression tests for XACA-1215: install-team.sh's
# generate_per_agent_startup_scripts() hardcoded SESSION_DIRECTORY="$HOME/{team_id}"
# for every generated per-agent startup script, ignoring the team conf's resolved
# TEAM_WORKING_DIR. Flat teams whose conf TEAM_WORKING_DIR != $HOME/<team_id>
# (command: $HOME/dev-team, dns: /Users/Shared/Development/DNSFramework, spacedock:
# $HOME/.aiteamforge/spacedock) got scripts pointing agents at a nonexistent
# directory (live-confirmed on M4Mini for command + spacedock, XACA-1215-001).
#
# Fix contract (XACA-1215 design.md "Test contract (006)"):
#   A. generate_per_agent_startup_scripts() renders SESSION_DIRECTORY from the
#      FINAL RESOLVED TEAM_WORKING_DIR (literal "$HOME/..." form when under HOME,
#      absolute otherwise; ATF_ENV_TEAM_WORKING_DIR override honored).
#   C. `install-team.sh <team> --install-dir <dir> --agent-scripts-only` regenerates
#      ONLY per-agent startup scripts (no other side effects), and never overwrites
#      a target lacking the AITEAMFORGE_GENERATED_VERSION marker.
#   D. The generated script's pre-tmux directory guard: a missing per-machine dir
#      (under $HOME/.aiteamforge/ or $AITEAMFORGE_DIR) is created and the session
#      proceeds (exit 0); any other missing (repo-style) dir errors and exits 1
#      WITHOUT ever calling tmux new-session.
#   E. aiteamforge-upgrade.sh defines update_generated_agent_scripts and calls it
#      in the run sequence (XACA-1215-005c) — HARD requirement, not advisory.
#   F. update_generated_agent_scripts actually HEALS an already-provisioned team's
#      stale (pre-fix-shaped) generated scripts in place — the exact scenario
#      XACA-1215-005 exists to solve — without touching a marker-less
#      hand-authored file in a parametric team's scripts dir, and --dry-run
#      changes nothing on disk.
#
# ── CI / default-run contract (no git dependency) ───────────────────────────
# The default invocation (no arguments — what CI runs) MUST NOT reference git
# history in any way: once this fix is committed, HEAD IS the fixed installer,
# so a default-run comparison against `git show HEAD:...` would silently
# compare fixed-against-fixed and prove nothing; on a shallow clone or a
# tarball checkout (both realistic CI shapes) the pre-fix commit may not even
# be reachable. Case F therefore builds its "stale, pre-fix-shaped" fixture
# scripts as INLINE LITERAL TEXT (the known bug shape:
# SESSION_DIRECTORY="$HOME/spacedock" + a real AITEAMFORGE_GENERATED_VERSION
# marker) rather than by rendering them with an old installer.
#
# A true end-to-end negative control (proving THIS test file can actually
# detect the bug, by running against a real pre-fix installer) is available
# but is opt-in only, via:
#
#     bash test-xaca-1215-session-directory.sh --negative-control <ref-or-path>
#
# <ref-or-path> is either a path to an install-team.sh file on disk, or a git
# ref (resolved via `git -C <tap-root> show <ref>:libexec/installers/install-team.sh`
# — never a checkout, this worktree has a concurrent editor on the real file).
# This mode runs Case-A/Case-C-shaped assertions against THAT installer and
# treats each one PASSING as "successfully detected the pre-fix bug" — it
# exits 0 only when every such detection succeeds, i.e. when the given
# installer is confirmed buggy. It does not run the rest of the suite (A/C/D/
# E/F above, which are about the FIXED installer) and never runs by default.
#
# ── Sandbox isolation (non-negotiable) ──────────────────────────────────────
# HOME and AITEAMFORGE_DIR are exported under TEST_TMP_DIR BEFORE anything is
# sourced or run. TMUX/TMUX_PANE/TMUX_SOCKET are unset (this test commonly runs
# from inside a REAL tmux session with these exported — verified live: a leaked
# TMUX_SOCKET silently changed the stub tmux's argv shape and made a stub-log
# assertion pass for the wrong reason). tmux itself is stubbed on PATH: it never
# starts a real server, just logs argv. Every path a generated script or
# install-team.sh touches is asserted to resolve under TEST_TMP_DIR; anything
# that would touch real $HOME/live boards/LCARS makes the test FAIL LOUDLY
# rather than proceed.
#
# Runs under /bin/bash 3.2 (macOS) — no bash-4-only constructs (no `declare -A`,
# no `mapfile`, no `${var,,}`).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_TEAM="$TAP_ROOT/libexec/installers/install-team.sh"
UPGRADE_SH="$TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh"
TEAM_CONF_SPACEDOCK="$TAP_ROOT/share/teams/spacedock.conf"
TEAM_CONF_FINANCE="$TAP_ROOT/share/teams/finance.conf"

# ─────────────────────────────────────────────────────────────────────────────
# Arg parsing: only recognised flag is --negative-control <ref-or-path>.
# ─────────────────────────────────────────────────────────────────────────────
NEGATIVE_CONTROL_TARGET=""
while [ $# -gt 0 ]; do
    case "$1" in
        --negative-control)
            if [ -z "${2:-}" ]; then
                echo "FATAL: --negative-control requires an argument (a git ref or a path to an install-team.sh file)" >&2
                exit 2
            fi
            NEGATIVE_CONTROL_TARGET="$2"
            shift 2
            ;;
        *) shift ;;
    esac
done

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework (mirrors test-xaca-0608 / test-xaca-0483 pattern): works
# both sourced by test-runner.sh and invoked directly.
# ─────────────────────────────────────────────────────────────────────────────
_STANDALONE=false
if ! type -t test_start >/dev/null 2>&1; then
    _STANDALONE=true
    _PASS_COUNT=0
    _FAIL_COUNT=0
    _SKIP_COUNT=0
    _CURRENT_TEST=""

    test_start() { _CURRENT_TEST="$1"; echo "  >> $1"; }
    test_pass()  { _PASS_COUNT=$((_PASS_COUNT + 1)); echo "     PASS: $_CURRENT_TEST"; }
    test_fail()  { _FAIL_COUNT=$((_FAIL_COUNT + 1)); echo "     FAIL: $_CURRENT_TEST — $1" >&2; }
    # XACA-1215-022: a SKIP is counted and reported in Results, never silent.
    # Under test-runner.sh its own test_skip (which counts) is used instead.
    test_skip()  { _SKIP_COUNT=$((_SKIP_COUNT + 1)); echo "     SKIP: $_CURRENT_TEST — $1"; }
fi

# print_section/print_info/print_warning/print_success/print_error are
# provided by the real upgrade framework at runtime; upgrade.sh itself does
# not define them. Case F sources update_generated_agent_scripts() standalone
# (test-xaca-0608's own pattern) so it needs no-op stubs here.
for _p in print_section print_info print_success print_warning print_error; do
    if ! declare -f "$_p" >/dev/null 2>&1; then
        eval "${_p}() { :; }"
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Sandbox root
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca1215-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
# Canonicalize (macOS /var -> /private/var symlink) so string-prefix sandbox
# checks below can't be fooled by a symlinked vs. resolved form mismatch.
TEST_TMP_DIR="$(cd "$TEST_TMP_DIR" && pwd -P)"

cleanup() {
    if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then
        rm -rf "$TEST_TMP_DIR"
    fi
}
trap cleanup EXIT INT TERM

# Fail loudly if any path we are about to treat as "sandboxed" is not actually
# under TEST_TMP_DIR — the non-negotiable isolation requirement.
_assert_sandboxed() {
    case "$1" in
        "$TEST_TMP_DIR"/*) return 0 ;;
        *)
            echo "FATAL SANDBOX ESCAPE: path '$1' does not resolve under TEST_TMP_DIR ($TEST_TMP_DIR) — refusing to proceed." >&2
            exit 1
            ;;
    esac
}

export HOME="$TEST_TMP_DIR/home"
export AITEAMFORGE_DIR="$TEST_TMP_DIR/aiteamforge"
_assert_sandboxed "$HOME"
_assert_sandboxed "$AITEAMFORGE_DIR"
mkdir -p "$HOME" "$AITEAMFORGE_DIR"

# This session is very likely itself running inside a real tmux pane on the
# real academy socket — verified live (TMUX_SOCKET=academy leaked in and
# silently changed the stub's argv shape). Strip all of it.
unset TMUX TMUX_PANE TMUX_SOCKET

export TMUX_TMPDIR="$TEST_TMP_DIR/tmux-tmpdir"
mkdir -p "$TMUX_TMPDIR"

# ─────────────────────────────────────────────────────────────────────────────
# Stub tmux: logs argv, never starts a real server. `has-session` always
# reports "no session" (exit 1) so generated scripts deterministically take
# the create-session path every run.
# ─────────────────────────────────────────────────────────────────────────────
STUB_BIN="$TEST_TMP_DIR/stub-bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/tmux" <<'STUBEOF'
#!/bin/sh
echo "$@" >> "${TMUX_STUB_LOG:?TMUX_STUB_LOG not set — refusing to run stub tmux without a log target}"
for arg in "$@"; do
    case "$arg" in
        has-session) exit 1 ;;
    esac
done
exit 0
STUBEOF
chmod +x "$STUB_BIN/tmux"
export PATH="$STUB_BIN:$PATH"
export TMUX_STUB_LOG="$TEST_TMP_DIR/tmux-stub.log"
_assert_sandboxed "$TMUX_STUB_LOG"
: > "$TMUX_STUB_LOG"

test_start "Sandbox preflight: stub tmux resolves ahead of any real tmux on PATH"
if [ "$(command -v tmux)" = "$STUB_BIN/tmux" ]; then
    test_pass
else
    test_fail "PATH resolves tmux to $(command -v tmux 2>&1), expected $STUB_BIN/tmux — refusing to continue (would risk touching a real tmux server)"
    echo "Results: ${_PASS_COUNT} passed, $((_FAIL_COUNT)) failed"
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Heredoc-aware function extractor.
#
# generate_per_agent_startup_scripts() and update_generated_agent_scripts()
# are bash functions whose bodies embed `python3 - ... <<'PYEOF' ... PYEOF`
# heredocs containing dict/function literals with bare "}" lines (e.g.
# THEME_COLORS = { ... }) that would fool a naive "first line that is exactly
# '}'" brace-counter (the pattern test-xaca-0608 uses safely for a PURE-bash
# function) into stopping mid-heredoc. Track heredoc state explicitly and
# only treat a bare "}" line as the function's closing brace while OUTSIDE
# any heredoc. Generic over function name and source file so it serves both
# install-team.sh and aiteamforge-upgrade.sh extractions, and both the
# current tree and an alternate (negative-control) source.
# ─────────────────────────────────────────────────────────────────────────────
_extract_fn_heredoc_aware() {
    # $1 = source file, $2 = original function name (bash regex-literal, no
    #      special chars expected in practice), $3 = new name to rename to.
    awk -v origname="$2" -v newname="$3" '
        $0 ~ ("^" origname "\\(\\) \\{") {
            capture = 1
            print newname "() {"
            next
        }
        capture && $0 ~ /<<.[A-Za-z_]+.$/ { in_heredoc = 1; heredoc_term = $0; sub(/^.*<</, "", heredoc_term); gsub(/[\x27"]/, "", heredoc_term) }
        capture { print }
        capture && in_heredoc && $0 == heredoc_term { in_heredoc = 0; next }
        capture && !in_heredoc && /^}$/ { exit }
    ' "$1"
}

# Extract the (pre-existing, NOT part of this fix — see design.md Decision 1's
# "rejected: re-read TEAM_WORKING_DIR from conf inside python") unparameterized-
# team TEAM_WORKING_DIR resolution block, including the ATF_ENV_TEAM_WORKING_DIR
# override clause, by text anchor (not fixed line numbers — this file is being
# concurrently edited and line numbers shift).
_extract_resolution_block() {
    awk '
        /^TEAM_BASE_WORKING_DIR="\$\{TEAM_WORKING_DIR\}"$/ { capture = 1 }
        capture && /TEAM_WORKING_DIR DEV-SOURCE PROTECTION GUARD/ { exit }
        capture { print }
    ' "$1"
}

# ═══════════════════════════════════════════════════════════════════════════
# NEGATIVE-CONTROL MODE (opt-in only — never runs on a default/CI invocation)
# ═══════════════════════════════════════════════════════════════════════════
if [ -n "$NEGATIVE_CONTROL_TARGET" ]; then
    test_start "NEGATIVE CONTROL: resolve '$NEGATIVE_CONTROL_TARGET' to an install-team.sh source"
    NC_SRC="$TEST_TMP_DIR/negative-control-install-team.sh"
    _assert_sandboxed "$NC_SRC"
    if [ -f "$NEGATIVE_CONTROL_TARGET" ]; then
        cp "$NEGATIVE_CONTROL_TARGET" "$NC_SRC"
        test_pass
    elif git -C "$TAP_ROOT" show "${NEGATIVE_CONTROL_TARGET}:libexec/installers/install-team.sh" > "$NC_SRC" 2>"$TEST_TMP_DIR/nc-git.err"; then
        test_pass
    else
        test_fail "Could not resolve '$NEGATIVE_CONTROL_TARGET' as an existing file path OR as a git ref: $(cat "$TEST_TMP_DIR/nc-git.err" 2>/dev/null)"
        echo ""
        echo "Results: ${_PASS_COUNT} passed, $((_FAIL_COUNT + 1)) failed"
        exit 1
    fi

    NC_EXTRACTED="$TEST_TMP_DIR/negative-control-extracted.sh"
    _extract_fn_heredoc_aware "$NC_SRC" "generate_per_agent_startup_scripts" "gen_nc" > "$NC_EXTRACTED"

    test_start "NEGATIVE CONTROL: generator extracts to valid bash"
    if [ -s "$NC_EXTRACTED" ] && bash -n "$NC_EXTRACTED" 2>"$TEST_TMP_DIR/nc-syn.err"; then
        test_pass
    else
        test_fail "Extraction empty or syntax-invalid: $(cat "$TEST_TMP_DIR/nc-syn.err" 2>/dev/null)"
    fi
    # shellcheck source=/dev/null
    source "$NC_EXTRACTED"

    NC_ATF="$TEST_TMP_DIR/nc-atf"
    _assert_sandboxed "$NC_ATF"
    mkdir -p "$NC_ATF"
    (
        AITEAMFORGE_DIR="$NC_ATF"
        HOMEBREW_TAP_ROOT="$TAP_ROOT"
        TEAM_ID="spacedock"
        TEAM_CONF="$TEAM_CONF_SPACEDOCK"
        TEAM_COLOR="#CC66FF"
        TEAM_WORKING_DIR="$HOME/.aiteamforge/spacedock"
        gen_nc
    ) >"$TEST_TMP_DIR/nc-gen-stdout.log" 2>"$TEST_TMP_DIR/nc-gen-stderr.log"

    NC_FILE="$(find "$NC_ATF/spacedock/scripts" -maxdepth 1 -name 'spacedock-*-startup.sh' 2>/dev/null | head -1)"
    NC_LINE="$(grep 'SESSION_DIRECTORY=' "$NC_FILE" 2>/dev/null)"

    test_start "NEGATIVE CONTROL (Case A equiv): '$NEGATIVE_CONTROL_TARGET' produces the WRONG SESSION_DIRECTORY (bug detected)"
    if [ -n "$NC_FILE" ] && [ "$NC_LINE" != 'SESSION_DIRECTORY="$HOME/.aiteamforge/spacedock"' ]; then
        test_pass
        echo "     EVIDENCE ($NEGATIVE_CONTROL_TARGET): ${NC_LINE:-<no SESSION_DIRECTORY line found — file: ${NC_FILE:-<none generated>}>}"
    else
        test_fail "Expected a WRONG (non-fixed) SESSION_DIRECTORY value — got '$NC_LINE'. Either this source is not actually pre-fix, or the detection itself is broken."
    fi

    NC_FLAG_PRESENT=$(grep -c -- "--agent-scripts-only" "$NC_SRC" 2>/dev/null)
    test_start "NEGATIVE CONTROL (Case C equiv): '$NEGATIVE_CONTROL_TARGET' has no working --agent-scripts-only capability"
    if [ "${NC_FLAG_PRESENT:-0}" -eq 0 ]; then
        test_pass
        echo "     EVIDENCE: --agent-scripts-only string absent from $NEGATIVE_CONTROL_TARGET (grep -c = ${NC_FLAG_PRESENT:-0})"
    else
        # The flag string exists in this source for some reason (e.g. testing
        # a partially-applied ref) — fall through to actually exercising it,
        # sandboxed identically to Case C, and require it to NOT behave
        # correctly for this to count as "detected".
        NC_C_HOME="$TEST_TMP_DIR/nc-c-home"; NC_C_ATF="$TEST_TMP_DIR/nc-c-atf"
        mkdir -p "$NC_C_HOME/.aiteamforge" "$NC_C_ATF"
        ORG_EXAMPLE="$TAP_ROOT/share/config/organization.yaml.example"
        [ -f "$ORG_EXAMPLE" ] && cp "$ORG_EXAMPLE" "$NC_C_HOME/.aiteamforge/organization.yaml"
        NC_C_EXIT=0
        env -u TMUX -u TMUX_PANE -u TMUX_SOCKET \
            HOME="$NC_C_HOME" AITEAMFORGE_DIR="$NC_C_ATF" PATH="$STUB_BIN:$PATH" \
            bash "$NC_SRC" spacedock --install-dir "$NC_C_ATF" --agent-scripts-only \
            >"$TEST_TMP_DIR/nc-c-stdout.log" 2>"$TEST_TMP_DIR/nc-c-stderr.log" || NC_C_EXIT=$?
        NC_C_FILE="$(find "$NC_C_ATF/spacedock/scripts" -maxdepth 1 -name 'spacedock-*-startup.sh' 2>/dev/null | head -1)"
        NC_C_LINE="$(grep 'SESSION_DIRECTORY=' "$NC_C_FILE" 2>/dev/null)"
        if [ "$NC_C_EXIT" -ne 0 ] || [ "$NC_C_LINE" != 'SESSION_DIRECTORY="$HOME/.aiteamforge/spacedock"' ]; then
            test_pass
            echo "     EVIDENCE: exit=$NC_C_EXIT SESSION_DIRECTORY='${NC_C_LINE:-<none>}'"
        else
            test_fail "This source's --agent-scripts-only produced the CORRECT output — it is not detectably buggy"
        fi
    fi

    echo ""
    echo "Negative-control results: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    if [ "$_FAIL_COUNT" -gt 0 ]; then
        echo "NEGATIVE CONTROL FAILED — the given source ('$NEGATIVE_CONTROL_TARGET') was NOT detected as buggy."
        exit 1
    fi
    echo "NEGATIVE CONTROL PASSED — '$NEGATIVE_CONTROL_TARGET' was confirmed buggy by this test's own assertions."
    exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════
# DEFAULT SUITE (no git dependency — this is what CI runs)
# ═══════════════════════════════════════════════════════════════════════════

test_start "Preflight: install-team.sh exists and is executable"
if [ -x "$INSTALL_TEAM" ]; then test_pass; else test_fail "Not found/executable: $INSTALL_TEAM"; fi

test_start "Preflight: aiteamforge-upgrade.sh exists"
if [ -f "$UPGRADE_SH" ]; then test_pass; else test_fail "Not found: $UPGRADE_SH"; fi

CURRENT_EXTRACTED="$TEST_TMP_DIR/extracted-current.sh"
_extract_fn_heredoc_aware "$INSTALL_TEAM" "generate_per_agent_startup_scripts" "gen_current" > "$CURRENT_EXTRACTED"

test_start "Extraction: generate_per_agent_startup_scripts extracts to valid bash"
if [ -s "$CURRENT_EXTRACTED" ] && bash -n "$CURRENT_EXTRACTED" 2>"$TEST_TMP_DIR/syn1.err"; then
    test_pass
else
    test_fail "Extraction empty or syntax-invalid: $(cat "$TEST_TMP_DIR/syn1.err" 2>/dev/null)"
fi
# shellcheck source=/dev/null
source "$CURRENT_EXTRACTED"

test_start "Extraction: gen_current is callable after sourcing"
if declare -f gen_current >/dev/null 2>&1; then test_pass; else test_fail "gen_current not defined after extraction+source"; fi

# ─────────────────────────────────────────────────────────────────────────────
# Shared harness: call the extracted generator with a given resolved
# TEAM_WORKING_DIR and return the SESSION_DIRECTORY line(s) it produced.
# ─────────────────────────────────────────────────────────────────────────────
_run_generator() {
    # $1 = AITEAMFORGE_DIR sandbox subdir, $2 = TEAM_WORKING_DIR (already
    # $HOME-expanded by the caller), $3 = team id (default spacedock), $4 =
    # team conf path (default spacedock's).
    local atf_dir="$1" twd="$2" team_id="${3:-spacedock}" conf="${4:-$TEAM_CONF_SPACEDOCK}"
    _assert_sandboxed "$atf_dir"
    mkdir -p "$atf_dir"
    (
        AITEAMFORGE_DIR="$atf_dir"
        HOMEBREW_TAP_ROOT="$TAP_ROOT"
        TEAM_ID="$team_id"
        TEAM_CONF="$conf"
        TEAM_COLOR="#CC66FF"
        TEAM_WORKING_DIR="$twd"
        gen_current
    ) >"$TEST_TMP_DIR/gen-stdout.log" 2>"$TEST_TMP_DIR/gen-stderr.log"
}

# ═══════════════════════════════════════════════════════════════════════════
# CASE A — sandboxed renderer: flat-team mismatch (spacedock), absolute
# override, and the ATF_ENV_TEAM_WORKING_DIR override plumbing.
# ═══════════════════════════════════════════════════════════════════════════

SPACEDOCK_TWD="$HOME/.aiteamforge/spacedock"
A1_ATF="$TEST_TMP_DIR/case-a1-atf"
_run_generator "$A1_ATF" "$SPACEDOCK_TWD"

test_start "A1: sandboxed spacedock install generates the expected per-agent scripts"
A1_SCRIPTS_DIR="$A1_ATF/spacedock/scripts"
A1_COUNT=$(find "$A1_SCRIPTS_DIR" -maxdepth 1 -name 'spacedock-*-startup.sh' 2>/dev/null | wc -l | tr -d ' ')
if [ "${A1_COUNT:-0}" -ge 4 ]; then
    test_pass
else
    test_fail "Expected >=4 spacedock-*-startup.sh under $A1_SCRIPTS_DIR, found ${A1_COUNT:-0}. stderr: $(cat "$TEST_TMP_DIR/gen-stderr.log" 2>/dev/null)"
fi

test_start "A1: every generated spacedock script has SESSION_DIRECTORY=\"\$HOME/.aiteamforge/spacedock\""
A1_ALL_CORRECT=true
A1_BAD=""
for f in "$A1_SCRIPTS_DIR"/spacedock-*-startup.sh; do
    [ -f "$f" ] || continue
    if ! grep -qF 'SESSION_DIRECTORY="$HOME/.aiteamforge/spacedock"' "$f"; then
        A1_ALL_CORRECT=false
        A1_BAD="${A1_BAD}$(basename "$f"): $(grep 'SESSION_DIRECTORY=' "$f") | "
    fi
done
if [ "$A1_ALL_CORRECT" = true ] && [ "${A1_COUNT:-0}" -ge 1 ]; then
    test_pass
else
    test_fail "Wrong/missing SESSION_DIRECTORY in one or more generated scripts: $A1_BAD"
fi

test_start "A1: generated scripts stayed inside the sandbox (no path escape)"
A1_ESCAPED="false"
for f in "$A1_SCRIPTS_DIR"/spacedock-*-startup.sh; do
    [ -f "$f" ] || continue
    case "$f" in "$TEST_TMP_DIR"/*) : ;; *) A1_ESCAPED="true" ;; esac
done
if [ "$A1_ESCAPED" = "false" ]; then test_pass; else test_fail "A generated script landed outside TEST_TMP_DIR"; fi

# ── A2: absolute (non-$HOME) TEAM_WORKING_DIR emits an absolute path ──
A2_ATF="$TEST_TMP_DIR/case-a2-atf"
A2_ABS_PROJECT="$TEST_TMP_DIR/abs-project-not-under-home"
mkdir -p "$A2_ABS_PROJECT"
_run_generator "$A2_ATF" "$A2_ABS_PROJECT"

test_start "A2: absolute TEAM_WORKING_DIR (not under \$HOME) renders as an absolute path, not contracted"
A2_FILE="$(find "$A2_ATF/spacedock/scripts" -maxdepth 1 -name 'spacedock-*-startup.sh' 2>/dev/null | head -1)"
if [ -n "$A2_FILE" ] && grep -qF "SESSION_DIRECTORY=\"$A2_ABS_PROJECT\"" "$A2_FILE"; then
    test_pass
else
    test_fail "Expected SESSION_DIRECTORY=\"$A2_ABS_PROJECT\" in $A2_FILE, got: $(grep 'SESSION_DIRECTORY=' "$A2_FILE" 2>/dev/null || echo '<file not found>')"
fi

# ── A3: ATF_ENV_TEAM_WORKING_DIR override — proves the pre-existing
#    resolution plumbing (NOT part of this fix, see design.md Decision 1's
#    rejected alternative) still lands correctly at TEAM_WORKING_DIR for an
#    unparameterized team, and that the renderer honors whatever it resolves
#    to. Extracted by text anchor so it tracks Reno's concurrent edits.
# ═══════════════════════════════════════════════════════════════════════════
RESOLUTION_BLOCK="$TEST_TMP_DIR/resolution-block.sh"
_extract_resolution_block "$INSTALL_TEAM" > "$RESOLUTION_BLOCK"

test_start "A3 preflight: TEAM_WORKING_DIR resolution block extracted (non-empty, valid bash)"
if [ -s "$RESOLUTION_BLOCK" ] && bash -n "$RESOLUTION_BLOCK" 2>"$TEST_TMP_DIR/syn3.err"; then
    test_pass
else
    test_fail "Resolution block extraction empty or invalid: $(cat "$TEST_TMP_DIR/syn3.err" 2>/dev/null)"
fi

A3_OVERRIDE_DIR="$HOME/atf-env-override/spacedock"
A3_RESOLVED_TWD=$(
    ATF_ENV_TEAM_WORKING_DIR="$A3_OVERRIDE_DIR"
    TEAM_WORKING_DIR='$HOME/.aiteamforge/spacedock'   # raw conf value (literal, unexpanded)
    TEAM_HAS_PROJECTS="false"
    HOME="$HOME"
    # shellcheck source=/dev/null
    source "$RESOLUTION_BLOCK" 2>/dev/null
    echo "$TEAM_WORKING_DIR"
)

test_start "A3: ATF_ENV_TEAM_WORKING_DIR override is honored by the (pre-existing) resolution block"
if [ "$A3_RESOLVED_TWD" = "$A3_OVERRIDE_DIR" ]; then
    test_pass
else
    test_fail "Expected resolved TEAM_WORKING_DIR='$A3_OVERRIDE_DIR', got '$A3_RESOLVED_TWD'"
fi

A3_ATF="$TEST_TMP_DIR/case-a3-atf"
_run_generator "$A3_ATF" "$A3_RESOLVED_TWD"
test_start "A3: renderer honors the ATF_ENV-resolved TEAM_WORKING_DIR end-to-end"
A3_FILE="$(find "$A3_ATF/spacedock/scripts" -maxdepth 1 -name 'spacedock-*-startup.sh' 2>/dev/null | head -1)"
if [ -n "$A3_FILE" ] && grep -qF 'SESSION_DIRECTORY="$HOME/atf-env-override/spacedock"' "$A3_FILE"; then
    test_pass
else
    test_fail "Expected literal \$HOME contraction of the override in $A3_FILE, got: $(grep 'SESSION_DIRECTORY=' "$A3_FILE" 2>/dev/null || echo '<not found>')"
fi

# ═══════════════════════════════════════════════════════════════════════════
# CASE C — --agent-scripts-only: regenerates ONLY per-agent scripts, no other
# side effects, and never overwrites a marker-less (hand-authored) target.
# Runs the REAL install-team.sh CLI (not an extraction) because the flag's
# entire point is "no other side effects" from the full script, which an
# extracted-function test cannot demonstrate. Verified safe to run directly:
# the --agent-scripts-only branch `exit 0`s unconditionally, textually BEFORE
# the TEAM_BREW_DEPS `brew install` block — re-verified below EVERY run, not
# assumed from write-time.
# ═══════════════════════════════════════════════════════════════════════════
AGENT_SCRIPTS_ONLY_PRESENT=$(grep -c -- "--agent-scripts-only" "$INSTALL_TEAM" 2>/dev/null)

test_start "C: --agent-scripts-only flag exists in install-team.sh"
if [ "${AGENT_SCRIPTS_ONLY_PRESENT:-0}" -ge 1 ]; then
    test_pass
else
    test_fail "install-team.sh does not define --agent-scripts-only (XACA-1215-005a)"
fi

if [ "${AGENT_SCRIPTS_ONLY_PRESENT:-0}" -ge 1 ]; then
    C_EXIT_LINE=$(grep -n 'AGENT_SCRIPTS_ONLY.*==.*true' "$INSTALL_TEAM" | head -1 | cut -d: -f1)
    C_BREW_LINE=$(grep -n '^\s*brew install ' "$INSTALL_TEAM" | head -1 | cut -d: -f1)
    test_start "C preflight: --agent-scripts-only branch precedes any 'brew install' call (safety precondition)"
    if [ -n "$C_EXIT_LINE" ] && [ -n "$C_BREW_LINE" ] && [ "$C_EXIT_LINE" -lt "$C_BREW_LINE" ]; then
        test_pass
    else
        test_fail "Cannot confirm --agent-scripts-only exits before 'brew install' (agent-scripts-only@${C_EXIT_LINE:-?}, brew-install@${C_BREW_LINE:-?}) — REFUSING to run install-team.sh directly this round to avoid a live brew install"
    fi

    if [ -n "$C_EXIT_LINE" ] && [ -n "$C_BREW_LINE" ] && [ "$C_EXIT_LINE" -lt "$C_BREW_LINE" ]; then
        C_HOME="$TEST_TMP_DIR/case-c-home"
        C_ATF="$TEST_TMP_DIR/case-c-atf"
        _assert_sandboxed "$C_HOME"; _assert_sandboxed "$C_ATF"
        mkdir -p "$C_HOME/.aiteamforge" "$C_ATF"
        # Pre-seed an org config so the (pre-existing, unrelated) interactive
        # org-identity prompt short-circuits instead of blocking on /dev/tty.
        ORG_EXAMPLE="$TAP_ROOT/share/config/organization.yaml.example"
        [ -f "$ORG_EXAMPLE" ] && cp "$ORG_EXAMPLE" "$C_HOME/.aiteamforge/organization.yaml"

        # Pre-seed scripts/: one STALE marked file (should be regenerated) and
        # one MARKER-LESS "hand-authored" file at a real target filename (should
        # be left byte-identical — the XACA-1215-005b clobber guard).
        mkdir -p "$C_ATF/spacedock/scripts"
        printf '#!/bin/zsh\n# STALE-SENTINEL-XACA-1215\n# AITEAMFORGE_GENERATED_VERSION=0.0.0-stale\necho stale\n' \
            > "$C_ATF/spacedock/scripts/spacedock-analysis-startup.sh"
        chmod +x "$C_ATF/spacedock/scripts/spacedock-analysis-startup.sh"
        printf '#!/bin/zsh\n# HAND-AUTHORED-NO-MARKER-XACA-1215\necho hand-authored\n' \
            > "$C_ATF/spacedock/scripts/spacedock-repair-startup.sh"
        chmod +x "$C_ATF/spacedock/scripts/spacedock-repair-startup.sh"
        HANDAUTH_BEFORE_SUM="$(shasum "$C_ATF/spacedock/scripts/spacedock-repair-startup.sh" | awk '{print $1}')"

        TREE_BEFORE="$TEST_TMP_DIR/case-c-tree-before.txt"
        find "$C_ATF" -type f | sort > "$TREE_BEFORE"

        C_STDOUT="$TEST_TMP_DIR/case-c-stdout.log"
        C_STDERR="$TEST_TMP_DIR/case-c-stderr.log"
        C_EXIT=0
        env -u TMUX -u TMUX_PANE -u TMUX_SOCKET \
            HOME="$C_HOME" AITEAMFORGE_DIR="$C_ATF" PATH="$STUB_BIN:$PATH" \
            bash "$INSTALL_TEAM" spacedock --install-dir "$C_ATF" --agent-scripts-only \
            >"$C_STDOUT" 2>"$C_STDERR" || C_EXIT=$?

        test_start "C: --agent-scripts-only exits 0"
        if [ "$C_EXIT" -eq 0 ]; then test_pass; else
            test_fail "Exit $C_EXIT. stdout: $(cat "$C_STDOUT" 2>/dev/null) | stderr: $(cat "$C_STDERR" 2>/dev/null)"
        fi

        test_start "C: --agent-scripts-only regenerated the stale marked script"
        if ! grep -q "STALE-SENTINEL-XACA-1215" "$C_ATF/spacedock/scripts/spacedock-analysis-startup.sh" 2>/dev/null \
           && grep -qF 'SESSION_DIRECTORY="$HOME/.aiteamforge/spacedock"' "$C_ATF/spacedock/scripts/spacedock-analysis-startup.sh" 2>/dev/null; then
            test_pass
        else
            test_fail "Stale marked script was not correctly regenerated"
        fi

        test_start "C: --agent-scripts-only left the marker-less hand-authored file BYTE-IDENTICAL"
        HANDAUTH_AFTER_SUM="$(shasum "$C_ATF/spacedock/scripts/spacedock-repair-startup.sh" 2>/dev/null | awk '{print $1}')"
        if [ "$HANDAUTH_AFTER_SUM" = "$HANDAUTH_BEFORE_SUM" ]; then
            test_pass
        else
            test_fail "Marker-less file was modified (before=$HANDAUTH_BEFORE_SUM after=$HANDAUTH_AFTER_SUM) — clobber guard did not hold"
        fi

        test_start "C: --agent-scripts-only produced NO other side effects (tree diff outside spacedock/scripts/)"
        TREE_AFTER="$TEST_TMP_DIR/case-c-tree-after.txt"
        find "$C_ATF" -type f | sort > "$TREE_AFTER"
        OUTSIDE_DIFF=$(diff "$TREE_BEFORE" "$TREE_AFTER" | grep -E '^[<>]' | grep -v '/spacedock/scripts/' || true)
        if [ -z "$OUTSIDE_DIFF" ]; then
            test_pass
        else
            test_fail "Unexpected filesystem changes outside spacedock/scripts/: $OUTSIDE_DIFF"
        fi
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CASE D — generated-script directory guard (stub tmux). Uses the real files
# generated in Case A1 (spacedock, correct SESSION_DIRECTORY), plus a
# purpose-built repo-style-missing-dir fixture.
# ═══════════════════════════════════════════════════════════════════════════

test_start "D: every generated script passes bash -n"
D_SYNTAX_OK=true
for f in "$A1_SCRIPTS_DIR"/spacedock-*-startup.sh; do
    [ -f "$f" ] || continue
    bash -n "$f" 2>"$TEST_TMP_DIR/d-syn.err" || { D_SYNTAX_OK=false; test_fail "Syntax error in $(basename "$f"): $(cat "$TEST_TMP_DIR/d-syn.err")"; break; }
done
[ "$D_SYNTAX_OK" = true ] && test_pass

D1_SCRIPT="$A1_SCRIPTS_DIR/spacedock-analysis-startup.sh"
D1_HOME="$TEST_TMP_DIR/case-d1-home"
D1_ATF="$TEST_TMP_DIR/case-d1-atf"
mkdir -p "$D1_HOME" "$D1_ATF"
D1_LOG="$TEST_TMP_DIR/case-d1-tmux.log"
_assert_sandboxed "$D1_LOG"
: > "$D1_LOG"

test_start "D1 preflight: target per-machine dir does not exist before the run"
if [ ! -d "$D1_HOME/.aiteamforge/spacedock" ]; then test_pass; else test_fail "Fixture dir already existed"; fi

D1_EXIT=0
if [ -f "$D1_SCRIPT" ]; then
    env -u TMUX -u TMUX_PANE -u TMUX_SOCKET \
        HOME="$D1_HOME" AITEAMFORGE_DIR="$D1_ATF" PATH="$STUB_BIN:$PATH" \
        TMUX_STUB_LOG="$D1_LOG" SKIP_ATTACH=1 \
        bash "$D1_SCRIPT" >"$TEST_TMP_DIR/d1-stdout.log" 2>"$TEST_TMP_DIR/d1-stderr.log" || D1_EXIT=$?
else
    D1_EXIT=127
fi

test_start "D1: missing per-machine dir (under \$HOME/.aiteamforge/) is created and the script exits 0"
if [ "$D1_EXIT" -eq 0 ] && [ -d "$D1_HOME/.aiteamforge/spacedock" ]; then
    test_pass
else
    test_fail "exit=$D1_EXIT dir-created=$([ -d "$D1_HOME/.aiteamforge/spacedock" ] && echo yes || echo no). stderr: $(cat "$TEST_TMP_DIR/d1-stderr.log" 2>/dev/null)"
fi

test_start "D1: tmux new-session WAS called (session proceeded)"
if grep -q 'new-session' "$D1_LOG" 2>/dev/null; then test_pass; else test_fail "No new-session in stub tmux log: $(cat "$D1_LOG" 2>/dev/null)"; fi

# ── D2: repo-style missing dir -> error, exit 1, no new-session ──
D2_ATF="$TEST_TMP_DIR/case-d2-atf"
D2_HOME="$TEST_TMP_DIR/case-d2-home"
mkdir -p "$D2_HOME"
D2_REPO_DIR="$D2_HOME/not-cloned-repo"   # under $HOME but NOT under $HOME/.aiteamforge
_run_generator "$D2_ATF" "$D2_REPO_DIR"
D2_SCRIPT="$(find "$D2_ATF/spacedock/scripts" -maxdepth 1 -name 'spacedock-*-startup.sh' 2>/dev/null | head -1)"

D2_LOG="$TEST_TMP_DIR/case-d2-tmux.log"
_assert_sandboxed "$D2_LOG"
: > "$D2_LOG"

test_start "D2 preflight: repo-style target dir does not exist before the run"
if [ ! -d "$D2_REPO_DIR" ]; then test_pass; else test_fail "Fixture dir already existed"; fi

D2_EXIT=0
if [ -n "$D2_SCRIPT" ] && [ -f "$D2_SCRIPT" ]; then
    env -u TMUX -u TMUX_PANE -u TMUX_SOCKET \
        HOME="$D2_HOME" AITEAMFORGE_DIR="$D2_ATF" PATH="$STUB_BIN:$PATH" \
        TMUX_STUB_LOG="$D2_LOG" SKIP_ATTACH=1 \
        bash "$D2_SCRIPT" >"$TEST_TMP_DIR/d2-stdout.log" 2>"$TEST_TMP_DIR/d2-stderr.log" || D2_EXIT=$?
else
    D2_EXIT=127
fi

test_start "D2: missing repo-style dir errors to stderr and exits non-zero"
if [ "$D2_EXIT" -ne 0 ] && grep -q "does not exist" "$TEST_TMP_DIR/d2-stderr.log" 2>/dev/null; then
    test_pass
else
    test_fail "exit=$D2_EXIT stderr: $(cat "$TEST_TMP_DIR/d2-stderr.log" 2>/dev/null)"
fi

test_start "D2: dir was NOT created (repo-style dirs are never mkdir-ed)"
if [ ! -d "$D2_REPO_DIR" ]; then test_pass; else test_fail "Guard incorrectly mkdir-ed a repo-style path"; fi

test_start "D2: tmux new-session was NEVER called"
if ! grep -q 'new-session' "$D2_LOG" 2>/dev/null; then
    test_pass
else
    test_fail "new-session appeared in stub tmux log despite the guard erroring: $(cat "$D2_LOG")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# CASE E — aiteamforge-upgrade.sh wiring: update_generated_agent_scripts
# defined AND invoked in the run sequence. HARD FAIL when missing or unwired
# — no SKIP/PENDING path. Function-body-aware (not a bare substring a comment
# could satisfy): requires an actual `name() {` header, not just the string
# appearing anywhere, and requires the call site to be a real standalone
# invocation line, not commented out.
# ═══════════════════════════════════════════════════════════════════════════
E_FN_DEFINED=$(grep -cE '^update_generated_agent_scripts\(\)[[:space:]]*\{' "$UPGRADE_SH" 2>/dev/null)
E_FN_CALLED=$(grep -cE '^update_generated_agent_scripts$' "$UPGRADE_SH" 2>/dev/null)

test_start "E: update_generated_agent_scripts() is DEFINED in aiteamforge-upgrade.sh (function header, not a comment mention)"
if [ "${E_FN_DEFINED:-0}" -ge 1 ]; then
    test_pass
else
    test_fail "update_generated_agent_scripts() is not defined in $UPGRADE_SH (XACA-1215-005c)"
fi

test_start "E: update_generated_agent_scripts is CALLED as a standalone line in the run sequence (not just defined)"
if [ "${E_FN_CALLED:-0}" -ge 1 ]; then
    test_pass
else
    test_fail "No standalone 'update_generated_agent_scripts' call line found in $UPGRADE_SH — not wired into the run sequence"
fi

UPGRADE_EXTRACTED=""
if [ "${E_FN_DEFINED:-0}" -ge 1 ]; then
    test_start "E: update_generated_agent_scripts references install-team.sh --agent-scripts-only (real substance, not a stub)"
    E_BODY=$(awk '
        /^update_generated_agent_scripts\(\)[[:space:]]*\{/ { capture = 1 }
        capture { print }
        capture && /^}$/ { exit }
    ' "$UPGRADE_SH")
    if echo "$E_BODY" | grep -q -- "--agent-scripts-only"; then
        test_pass
    else
        test_fail "update_generated_agent_scripts() body does not reference --agent-scripts-only — likely a stub"
    fi

    # Extract (heredoc-aware — this function embeds python3 <<'PYEOF' blocks
    # for team-paths.json parsing) for Case F below.
    UPGRADE_EXTRACTED="$TEST_TMP_DIR/extracted-upgrade.sh"
    _extract_fn_heredoc_aware "$UPGRADE_SH" "update_generated_agent_scripts" "update_generated_agent_scripts_x" > "$UPGRADE_EXTRACTED"
    # _connect_script_team_flags is a plain-bash dependency (no heredoc) that
    # update_generated_agent_scripts calls for parametric teams.
    awk '/^_connect_script_team_flags\(\) \{/{c=1} c{print} c&&/^}$/{exit}' "$UPGRADE_SH" >> "$UPGRADE_EXTRACTED"

    test_start "E preflight: update_generated_agent_scripts + _connect_script_team_flags extract to valid bash"
    if [ -s "$UPGRADE_EXTRACTED" ] && bash -n "$UPGRADE_EXTRACTED" 2>"$TEST_TMP_DIR/syn-upgrade.err"; then
        test_pass
    else
        test_fail "Extraction empty or syntax-invalid: $(cat "$TEST_TMP_DIR/syn-upgrade.err" 2>/dev/null)"
        UPGRADE_EXTRACTED=""
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CASE F — backfill: update_generated_agent_scripts heals an already-
# provisioned team's STALE (pre-fix-shaped) generated scripts in place — the
# exact scenario XACA-1215-005 exists to solve. Per the CI/default-run
# contract above, the "stale" starting state is built as an INLINE LITERAL
# FIXTURE (the known bug shape), never by running an old installer.
# ═══════════════════════════════════════════════════════════════════════════
if [ -n "$UPGRADE_EXTRACTED" ]; then
    # shellcheck source=/dev/null
    source "$UPGRADE_EXTRACTED"

    test_start "F preflight: update_generated_agent_scripts_x + _connect_script_team_flags callable after sourcing"
    if declare -f update_generated_agent_scripts_x >/dev/null 2>&1 && declare -f _connect_script_team_flags >/dev/null 2>&1; then
        test_pass
    else
        test_fail "One or both extracted functions not defined after sourcing"
    fi

    # ── F1: flat-team backfill (spacedock) ──────────────────────────────────
    F_HOME="$TEST_TMP_DIR/case-f-home"
    F_ATF="$TEST_TMP_DIR/case-f-atf"
    _assert_sandboxed "$F_HOME"; _assert_sandboxed "$F_ATF"
    mkdir -p "$F_HOME/.aiteamforge" "$F_ATF/spacedock/scripts"
    # Pre-seed org config so install-team.sh's (pre-existing, unrelated)
    # interactive org-identity prompt short-circuits instead of blocking on
    # /dev/tty when update_generated_agent_scripts_x shells out to it.
    ORG_EXAMPLE_F="$TAP_ROOT/share/config/organization.yaml.example"
    [ -f "$ORG_EXAMPLE_F" ] && cp "$ORG_EXAMPLE_F" "$F_HOME/.aiteamforge/organization.yaml"

    # Inline literal fixture — the exact pre-fix bug shape, NOT rendered by an
    # old installer: a real AITEAMFORGE_GENERATED_VERSION marker (so
    # discovery treats spacedock as a candidate and the 005b marker guard
    # allows overwrite) but the WRONG (pre-fix) SESSION_DIRECTORY value.
    cat > "$F_ATF/spacedock/scripts/spacedock-analysis-startup.sh" <<'FIXTUREEOF'
#!/bin/zsh
# Auto-generated by aiteamforge installer (install-team.sh generate_per_agent_startup_scripts)
# AITEAMFORGE_GENERATED_VERSION=0.20.9
SESSION_TYPE="spacedock"
SESSION_NAME="analysis"
SESSION_DIRECTORY="$HOME/spacedock"
echo "pre-fix fixture — should be healed by update_generated_agent_scripts"
FIXTUREEOF
    chmod +x "$F_ATF/spacedock/scripts/spacedock-analysis-startup.sh"

    F_REG_WORKING_DIR="$F_HOME/.aiteamforge/spacedock"
    cat > "$F_HOME/.aiteamforge/team-paths.json" <<FJSONEOF
{
  "teams": {
    "spacedock": { "working_dir": "$F_REG_WORKING_DIR" }
  }
}
FJSONEOF

    F1_STDOUT="$TEST_TMP_DIR/f1-stdout.log"
    (
        HOME="$F_HOME"
        AITEAMFORGE_DIR="$F_ATF"
        FRAMEWORK_DIR="$TAP_ROOT"
        LIBEXEC_DIR="$TAP_ROOT/libexec"
        WORKING_DIR="$F_ATF"
        AITEAMFORGE_CONFIG="$F_HOME/.aiteamforge/team-paths.json"
        DRY_RUN=false
        export HOME AITEAMFORGE_DIR FRAMEWORK_DIR LIBEXEC_DIR WORKING_DIR AITEAMFORGE_CONFIG DRY_RUN
        # NOTE: `env` execs an external process and cannot see shell functions
        # — invoking `env ... update_generated_agent_scripts_x` fails with
        # "No such file or directory" and silently no-ops the whole call.
        # unset/export in-subshell, then call the function directly.
        unset TMUX TMUX_PANE TMUX_SOCKET
        export PATH="$STUB_BIN:$PATH"
        update_generated_agent_scripts_x
    ) >"$F1_STDOUT" 2>&1

    test_start "F1: update_generated_agent_scripts heals the stale spacedock fixture's SESSION_DIRECTORY"
    F1_LINE="$(grep 'SESSION_DIRECTORY=' "$F_ATF/spacedock/scripts/spacedock-analysis-startup.sh" 2>/dev/null)"
    if [ "$F1_LINE" = 'SESSION_DIRECTORY="$HOME/.aiteamforge/spacedock"' ]; then
        test_pass
    else
        test_fail "Expected healed SESSION_DIRECTORY=\"\$HOME/.aiteamforge/spacedock\", got '$F1_LINE'. Run log: $(cat "$F1_STDOUT" 2>/dev/null)"
    fi

    test_start "F1: healed script no longer carries the pre-fix fixture sentinel"
    if ! grep -q "pre-fix fixture" "$F_ATF/spacedock/scripts/spacedock-analysis-startup.sh" 2>/dev/null; then
        test_pass
    else
        test_fail "Fixture sentinel text still present — file was not actually regenerated"
    fi

    # ── F2: parametric team (finance) — marker-bearing file regenerated,
    #    marker-LESS hand-authored file left byte-identical ─────────────────
    mkdir -p "$F_ATF/finance/scripts"
    cat > "$F_ATF/finance/scripts/finance-vault-startup.sh" <<'FIXTUREEOF'
#!/bin/zsh
# Auto-generated by aiteamforge installer (install-team.sh generate_per_agent_startup_scripts)
# AITEAMFORGE_GENERATED_VERSION=0.20.9
SESSION_TYPE="finance"
SESSION_NAME="vault"
SESSION_DIRECTORY="$HOME/finance"
echo "pre-fix fixture — should be healed"
FIXTUREEOF
    chmod +x "$F_ATF/finance/scripts/finance-vault-startup.sh"

    cat > "$F_ATF/finance/scripts/finance-bar-startup.sh" <<'HANDEOF'
#!/bin/zsh
# HAND-AUTHORED-NO-MARKER (XACA-0484 style parametric copy) — must never be
# touched by the marker-guard-respecting backfill path.
SESSION_DIRECTORY="$FINANCE_PROJECT_DIR"
echo "hand authored"
HANDEOF
    chmod +x "$F_ATF/finance/scripts/finance-bar-startup.sh"
    FINANCE_HANDAUTH_BEFORE="$(shasum "$F_ATF/finance/scripts/finance-bar-startup.sh" | awk '{print $1}')"

    F2_STDOUT="$TEST_TMP_DIR/f2-stdout.log"
    (
        HOME="$F_HOME"
        AITEAMFORGE_DIR="$F_ATF"
        FRAMEWORK_DIR="$TAP_ROOT"
        LIBEXEC_DIR="$TAP_ROOT/libexec"
        WORKING_DIR="$F_ATF"
        AITEAMFORGE_CONFIG="$F_HOME/.aiteamforge/team-paths.json"
        DRY_RUN=false
        export HOME AITEAMFORGE_DIR FRAMEWORK_DIR LIBEXEC_DIR WORKING_DIR AITEAMFORGE_CONFIG DRY_RUN
        # NOTE: `env` execs an external process and cannot see shell functions
        # — invoking `env ... update_generated_agent_scripts_x` fails with
        # "No such file or directory" and silently no-ops the whole call.
        # unset/export in-subshell, then call the function directly.
        unset TMUX TMUX_PANE TMUX_SOCKET
        export PATH="$STUB_BIN:$PATH"
        update_generated_agent_scripts_x
    ) >"$F2_STDOUT" 2>&1

    test_start "F2: marker-bearing finance-vault-startup.sh was regenerated with the correct project-augmented SESSION_DIRECTORY"
    F2_LINE="$(grep 'SESSION_DIRECTORY=' "$F_ATF/finance/scripts/finance-vault-startup.sh" 2>/dev/null)"
    if [ "$F2_LINE" = 'SESSION_DIRECTORY="$HOME/finance/personal"' ]; then
        test_pass
    else
        test_fail "Expected SESSION_DIRECTORY=\"\$HOME/finance/personal\" (TEAM_DEFAULT_PROJECT=personal), got '$F2_LINE'. Run log: $(cat "$F2_STDOUT" 2>/dev/null)"
    fi

    test_start "F2: marker-LESS hand-authored finance-bar-startup.sh is BYTE-IDENTICAL after the backfill"
    FINANCE_HANDAUTH_AFTER="$(shasum "$F_ATF/finance/scripts/finance-bar-startup.sh" 2>/dev/null | awk '{print $1}')"
    if [ "$FINANCE_HANDAUTH_AFTER" = "$FINANCE_HANDAUTH_BEFORE" ]; then
        test_pass
    else
        test_fail "Hand-authored marker-less file was modified (before=$FINANCE_HANDAUTH_BEFORE after=$FINANCE_HANDAUTH_AFTER)"
    fi

    # ── F3: --dry-run changes nothing on disk ───────────────────────────────
    F3_HOME="$TEST_TMP_DIR/case-f3-home"
    F3_ATF="$TEST_TMP_DIR/case-f3-atf"
    mkdir -p "$F3_HOME/.aiteamforge" "$F3_ATF/spacedock/scripts"
    ORG_EXAMPLE_F3="$TAP_ROOT/share/config/organization.yaml.example"
    [ -f "$ORG_EXAMPLE_F3" ] && cp "$ORG_EXAMPLE_F3" "$F3_HOME/.aiteamforge/organization.yaml"
    cat > "$F3_ATF/spacedock/scripts/spacedock-analysis-startup.sh" <<'FIXTUREEOF'
#!/bin/zsh
# Auto-generated by aiteamforge installer (install-team.sh generate_per_agent_startup_scripts)
# AITEAMFORGE_GENERATED_VERSION=0.20.9
SESSION_DIRECTORY="$HOME/spacedock"
echo "pre-fix fixture for dry-run test"
FIXTUREEOF
    chmod +x "$F3_ATF/spacedock/scripts/spacedock-analysis-startup.sh"
    cat > "$F3_HOME/.aiteamforge/team-paths.json" <<FJSONEOF
{ "teams": { "spacedock": { "working_dir": "$F3_HOME/.aiteamforge/spacedock" } } }
FJSONEOF

    F3_TREE_BEFORE="$TEST_TMP_DIR/f3-tree-before.txt"
    find "$F3_ATF" -type f -exec shasum {} \; | sort > "$F3_TREE_BEFORE"

    F3_STDOUT="$TEST_TMP_DIR/f3-stdout.log"
    (
        HOME="$F3_HOME"
        AITEAMFORGE_DIR="$F3_ATF"
        FRAMEWORK_DIR="$TAP_ROOT"
        LIBEXEC_DIR="$TAP_ROOT/libexec"
        WORKING_DIR="$F3_ATF"
        AITEAMFORGE_CONFIG="$F3_HOME/.aiteamforge/team-paths.json"
        DRY_RUN=true
        export HOME AITEAMFORGE_DIR FRAMEWORK_DIR LIBEXEC_DIR WORKING_DIR AITEAMFORGE_CONFIG DRY_RUN
        # NOTE: `env` execs an external process and cannot see shell functions
        # — invoking `env ... update_generated_agent_scripts_x` fails with
        # "No such file or directory" and silently no-ops the whole call.
        # unset/export in-subshell, then call the function directly.
        unset TMUX TMUX_PANE TMUX_SOCKET
        export PATH="$STUB_BIN:$PATH"
        update_generated_agent_scripts_x
    ) >"$F3_STDOUT" 2>&1

    F3_TREE_AFTER="$TEST_TMP_DIR/f3-tree-after.txt"
    find "$F3_ATF" -type f -exec shasum {} \; | sort > "$F3_TREE_AFTER"

    test_start "F3: --dry-run changes NOTHING on disk"
    if diff -q "$F3_TREE_BEFORE" "$F3_TREE_AFTER" >/dev/null 2>&1; then
        test_pass
    else
        test_fail "Filesystem changed under --dry-run: $(diff "$F3_TREE_BEFORE" "$F3_TREE_AFTER" 2>/dev/null)"
    fi

    test_start "F3: --dry-run reports what it WOULD do"
    if grep -qi "would regenerate" "$F3_STDOUT" 2>/dev/null; then
        test_pass
    else
        test_fail "No 'would regenerate' notice in dry-run output: $(cat "$F3_STDOUT" 2>/dev/null)"
    fi
else
    test_start "F: skipped — update_generated_agent_scripts extraction unavailable (see Case E failures above)"
    test_fail "Case F cannot run without a valid update_generated_agent_scripts extraction"
fi


# ═══════════════════════════════════════════════════════════════════════════
# CASE G — hostile SESSION_DIRECTORY round-trip (XACA-1215-016), plus the
# pane-shell second-hop re-evaluation fix (XACA-1215-015, reviewer-filed
# non-blocking finding on PR #897).
#
# G1-G7: render a per-agent script from a TEAM_WORKING_DIR containing a
# hostile character/sequence, then:
#   - bash -n on the generated script must pass;
#   - the SESSION_DIRECTORY="..." assignment line, eval'd in a subshell with
#     HOME set to the same sandbox HOME used at render time, must reproduce
#     the literal raw TEAM_WORKING_DIR byte-for-byte (an over-escape or an
#     under-escape both show up here);
#   - no PWNED sentinel file must ever appear (proves the eval never
#     executed the hostile payload as a command).
#
# G8: drives the ACTUAL generated script's send-keys pane input through the
# real pane shells (zsh, then /bin/bash) to prove the XACA-1215-015 fix (the
# printf %q re-quote) survives the SECOND parse a pane's interactive shell
# performs on typed text.
# ═══════════════════════════════════════════════════════════════════════════

G_PWNED_SENTINEL="$TEST_TMP_DIR/case-g-PWNED"

# Round-trip harness: $1 = label (letters/hyphens only — used verbatim in a
# sandbox dir name), $2 = raw TEAM_WORKING_DIR, $3 = expect $HOME-contracted
# form ("true") vs literal-absolute form ("false").
_g_case() {
    local label="$1" raw="$2" expect_home_contracted="$3"
    rm -f "$G_PWNED_SENTINEL"
    local g_atf="$TEST_TMP_DIR/case-g-atf-$label"
    _run_generator "$g_atf" "$raw"
    local g_file
    g_file="$(find "$g_atf/spacedock/scripts" -maxdepth 1 -name 'spacedock-*-startup.sh' 2>/dev/null | head -1)"

    test_start "G ($label): generated script exists and passes bash -n"
    if [ -n "$g_file" ] && [ -f "$g_file" ] && bash -n "$g_file" 2>"$TEST_TMP_DIR/g-syn.err"; then
        test_pass
    else
        test_fail "bash -n failed or file missing for '$label': $(cat "$TEST_TMP_DIR/g-syn.err" 2>/dev/null)"
        return
    fi

    local g_line
    g_line="$(grep '^SESSION_DIRECTORY=' "$g_file" 2>/dev/null)"

    test_start "G ($label): SESSION_DIRECTORY= line uses the expected \$HOME contraction form"
    case "$g_line" in
        'SESSION_DIRECTORY="$HOME'*)
            if [ "$expect_home_contracted" = true ]; then test_pass; else test_fail "Got contracted form but expected literal-absolute: $g_line"; fi ;;
        *)
            if [ "$expect_home_contracted" = false ]; then test_pass; else test_fail "Got literal-absolute form but expected \$HOME contraction: $g_line"; fi ;;
    esac

    # Eval the captured assignment line in a real subshell (own script file,
    # not an inline -c string, to sidestep quoting-within-quoting entirely)
    # with the SAME sandbox HOME used at render time, then read back the
    # variable — this is the actual round-trip proof.
    local g_eval_script="$TEST_TMP_DIR/g-eval-script.sh"
    {
        printf '%s\n' "$g_line"
        printf 'echo "$SESSION_DIRECTORY"\n'
    } > "$g_eval_script"
    local g_evaled
    g_evaled="$(HOME="$HOME" bash "$g_eval_script" 2>"$TEST_TMP_DIR/g-eval.err")"

    test_start "G ($label): eval'd SESSION_DIRECTORY round-trips to the literal raw input"
    if [ "$g_evaled" = "$raw" ]; then
        test_pass
    else
        test_fail "raw='$raw' evaled='$g_evaled' line='$g_line' stderr=$(cat "$TEST_TMP_DIR/g-eval.err" 2>/dev/null)"
    fi

    test_start "G ($label): no PWNED sentinel appeared (hostile payload never executed)"
    if [ ! -e "$G_PWNED_SENTINEL" ]; then
        test_pass
    else
        test_fail "PWNED sentinel file was created — hostile input was executed: $G_PWNED_SENTINEL"
        rm -f "$G_PWNED_SENTINEL"
    fi
}

# G1: double quote
_g_case 'double-quote' "$HOME/g-quo\"te" true
# G2: command substitution
_g_case 'cmd-subst' "$HOME/g-cs-\$(touch ${G_PWNED_SENTINEL})x" true
# G3: backtick
_g_case 'backtick' "$HOME/g-bt-\`touch ${G_PWNED_SENTINEL}\`x" true
# G4: backslash
_g_case 'backslash' "$HOME/g-bs-a\\b" true
# G5: space
_g_case 'space' "$HOME/g sp ace" true
# G6: HOME-sibling prefix (must stay absolute, NOT contracted — the boundary
# check is `== "$HOME"/*`, so a sibling like "${HOME}xy/..." must not match)
_g_case 'home-sibling' "${HOME}xy/g-sibling" false
# G7: exactly $HOME (no subdir)
_g_case 'exactly-home' "$HOME" true

# ─────────────────────────────────────────────────────────────────────────────
# G8: XACA-1215-015 second-hop — drive the REAL generated script's stub-tmux
# send-keys "cd ..." argument through the pane's own shells (zsh, then bash).
# Uses a PURPOSE-BUILT, argv-preserving stub tmux (one arg per line, an
# explicit end-of-call marker) so the exact "keys" argument sent to
# send-keys can be recovered byte-for-byte — the shared STUB_BIN/tmux used
# by Cases A-F logs `echo "$@"`, which space-joins args and cannot
# distinguish an argument boundary from a space WITHIN an argument (exactly
# the kind of value a hostile path produces). Scoped to this case only via
# an explicit PATH override on the single `env` invocation below; it never
# touches the shared STUB_BIN or global PATH.
# ─────────────────────────────────────────────────────────────────────────────
G8_STUB_BIN="$TEST_TMP_DIR/g8-stub-bin"
mkdir -p "$G8_STUB_BIN"
cat > "$G8_STUB_BIN/tmux" <<'G8STUBEOF'
#!/bin/sh
LOG="${TMUX_STUB_LOG:?TMUX_STUB_LOG not set}"
{
    for a in "$@"; do
        printf '%s\n' "$a"
    done
    printf '===END===\n'
} >> "$LOG"
for arg in "$@"; do
    case "$arg" in
        has-session) exit 1 ;;
    esac
done
exit 0
G8STUBEOF
chmod +x "$G8_STUB_BIN/tmux"

G8_HOME="$TEST_TMP_DIR/case-g8-home"
G8_ATF="$TEST_TMP_DIR/case-g8-atf"
mkdir -p "$G8_HOME"
G8_PWNED="$TEST_TMP_DIR/case-g8-PWNED"
rm -f "$G8_PWNED"
# A REAL, EXISTING directory (so the missing-dir guard never engages and
# setup_window actually runs) whose name embeds a space, a live-looking
# command substitution, a backtick, and a double quote in one string —
# maximum second-hop coverage in a single generated script.
G8_DIR="$G8_HOME/g8 dir \$(touch ${G8_PWNED})x \`touch ${G8_PWNED}\` \"q"
mkdir -p "$G8_DIR"
_run_generator "$G8_ATF" "$G8_DIR"
G8_SCRIPT="$(find "$G8_ATF/spacedock/scripts" -maxdepth 1 -name 'spacedock-*-startup.sh' 2>/dev/null | head -1)"

G8_LOG="$TEST_TMP_DIR/case-g8-tmux.log"
_assert_sandboxed "$G8_LOG"
: > "$G8_LOG"
G8_EXIT=0
if [ -n "$G8_SCRIPT" ] && [ -f "$G8_SCRIPT" ]; then
    env -u TMUX -u TMUX_PANE -u TMUX_SOCKET \
        HOME="$G8_HOME" AITEAMFORGE_DIR="$G8_ATF" PATH="$G8_STUB_BIN:$PATH" \
        TMUX_STUB_LOG="$G8_LOG" SKIP_ATTACH=1 \
        bash "$G8_SCRIPT" >"$TEST_TMP_DIR/g8-stdout.log" 2>"$TEST_TMP_DIR/g8-stderr.log" || G8_EXIT=$?
else
    G8_EXIT=127
fi

test_start "G8 preflight: generated script ran cleanly against the real (existing) hostile dir"
if [ "$G8_EXIT" -eq 0 ]; then
    test_pass
else
    test_fail "exit=$G8_EXIT stderr: $(cat "$TEST_TMP_DIR/g8-stderr.log" 2>/dev/null)"
fi

test_start "G8 preflight: no PWNED sentinel from the generated script's OWN run (before any pane re-parse)"
if [ ! -e "$G8_PWNED" ]; then
    test_pass
else
    test_fail "PWNED sentinel appeared just from running the generated script — bug is in install-team.sh itself, not the second hop"
fi

# Recover the exact "keys" argument of the first send-keys call: a block is
# ["send-keys","-t",<target>,<keys>,"C-m"] followed by the "===END===" line.
G8_CD_LINE="$(python3 - "$G8_LOG" <<'G8PYEOF'
import sys
with open(sys.argv[1]) as f:
    content = f.read()
for block in content.split("===END===\n"):
    lines = block.split("\n")
    while lines and lines[-1] == "":
        lines.pop()
    if len(lines) >= 4 and lines[0] == "send-keys":
        print(lines[3])
        break
G8PYEOF
)"

test_start "G8 preflight: a 'cd ...' send-keys line was captured from the argv-preserving stub log"
case "$G8_CD_LINE" in
    cd\ *) test_pass ;;
    *) test_fail "Expected the captured keys arg to start with 'cd ', got: '$G8_CD_LINE' (log: $(cat "$G8_LOG" 2>/dev/null))" ;;
esac

test_start "G8 (XACA-1215-015): captured pane input carries no stray outer double-quotes (the second-hop bug shape)"
case "$G8_CD_LINE" in
    'cd "'*) test_fail "Outer double-quotes reached the pane verbatim — this is the pre-fix second-hop shape: $G8_CD_LINE" ;;
    *) test_pass ;;
esac

for _g8_shell in zsh bash; do
    if [ "$_g8_shell" = zsh ] && ! command -v zsh >/dev/null 2>&1; then
        test_start "G8 (XACA-1215-015): pane-shell re-parse under zsh"
        test_skip "zsh not found on PATH (expected on CI ubuntu runners) — the bash sub-assertion below still runs and is not skipped"
        continue
    fi
    rm -f "$G8_PWNED"
    G8_ELSEWHERE="$TEST_TMP_DIR/case-g8-elsewhere-$_g8_shell"
    mkdir -p "$G8_ELSEWHERE"
    if [ "$_g8_shell" = zsh ]; then
        G8_PANE_PWD="$(cd "$G8_ELSEWHERE" && HOME="$G8_HOME" zsh -fc "$G8_CD_LINE && pwd" 2>"$TEST_TMP_DIR/g8-zsh.err")"
    else
        G8_PANE_PWD="$(cd "$G8_ELSEWHERE" && HOME="$G8_HOME" /bin/bash -c "$G8_CD_LINE && pwd" 2>"$TEST_TMP_DIR/g8-bash.err")"
    fi
    test_start "G8 (XACA-1215-015): pane-shell re-parse under $_g8_shell lands in the literal dir"
    if [ "$G8_PANE_PWD" = "$G8_DIR" ]; then
        test_pass
    else
        test_fail "expected='$G8_DIR' got='$G8_PANE_PWD' cd_line='$G8_CD_LINE' stderr=$(cat "$TEST_TMP_DIR/g8-$_g8_shell.err" 2>/dev/null)"
    fi
    test_start "G8 (XACA-1215-015): no PWNED sentinel under $_g8_shell (hostile payload never executed by the pane shell)"
    if [ ! -e "$G8_PWNED" ]; then
        test_pass
    else
        test_fail "PWNED sentinel created by the pane shell's re-parse of the typed 'cd' text: $G8_PWNED"
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
# CASE G9 — XACA-1215-019: non-ASCII SESSION_DIRECTORY under a REAL
# interactive pty. G8 above only re-parses the captured `cd ...` line
# non-interactively (`zsh -fc` / `/bin/bash -c`), which CANNOT see this bug:
# the mangling happens in ZLE while a real terminal session is typing the
# bytes in, not while a non-interactive shell is parsing an argv string.
# Bare `printf %q` under bash 3.2 renders a multibyte char's bytes as a mix
# of raw bytes and octal escapes for the 0x80-0x9F range, and a real
# interactive zsh reading that back garbles it and the `cd` silently lands
# nowhere useful. Drives an actual `zsh -i` through a python pty.fork()
# harness (portable to Linux CI, unlike macOS-only `script`), typing the
# generated `cd ...` line the way a real terminal would, then reads back
# `pwd`.
# ─────────────────────────────────────────────────────────────────────────────
if ! command -v zsh >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    test_start "G9 (XACA-1215-019): non-ASCII SESSION_DIRECTORY round-trip under a real interactive pty"
    test_skip "zsh and/or python3 not found on PATH — the pty harness requires both"
else
    G9_HOME="$TEST_TMP_DIR/case-g9-home"
    G9_ZDOTDIR="$TEST_TMP_DIR/case-g9-zdotdir"
    mkdir -p "$G9_HOME" "$G9_ZDOTDIR"

    # Minimal pty harness: spawn `zsh -i` on a real pty (ZDOTDIR points at an
    # empty sandbox so no rc files slow startup or interfere), type the
    # given command line + Enter, then `pwd > <outfile>` + Enter, then exit.
    # LANG/LC_ALL=en_US.UTF-8 is forced on the spawned session itself so ZLE
    # is UTF-8-aware (matching a real user's terminal) regardless of the
    # runner's own ambient locale. os.fsencode() (not .encode("utf-8")) is
    # required to replay a pre-fix %q's mixed raw/octal bytes verbatim: Python
    # surrogateescape-decodes invalid-UTF-8 argv bytes on the way in, and only
    # fsencode() reverses that back to the exact original bytes instead of
    # raising on the surrogate codepoints.
    G9_HARNESS="$TEST_TMP_DIR/case-g9-pty-harness.py"
    cat > "$G9_HARNESS" <<'G9PYEOF'
import os, sys, pty, select, time, signal

def drain(fd, timeout, idle_gap=0.15):
    end = time.time() + timeout
    buf = b""
    last = time.time()
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if fd in r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            buf += chunk
            last = time.time()
        else:
            if buf and (time.time() - last) > idle_gap:
                break
    return buf

def main():
    zdotdir, home, cmd_line, outfile = sys.argv[1:5]
    env = dict(os.environ)
    env["ZDOTDIR"] = zdotdir
    env["HOME"] = home
    env["LANG"] = "en_US.UTF-8"
    env["LC_ALL"] = "en_US.UTF-8"
    env["TERM"] = "xterm"
    env["PS1"] = "PTYG9$ "

    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(home)
        os.execvpe("zsh", ["zsh", "-i"], env)
        os._exit(127)

    def send(s):
        os.write(fd, os.fsencode(s))

    drain(fd, 1.5)
    send(cmd_line + "\n")
    drain(fd, 1.5)
    send("pwd > " + outfile + "\n")
    drain(fd, 1.5)
    send("exit\n")

    deadline = time.time() + 3.0
    while time.time() < deadline:
        try:
            wpid, status = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            break
        if wpid == pid:
            break
        time.sleep(0.1)
    else:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass

if __name__ == "__main__":
    main()
G9PYEOF

    # NEGATIVE-CONTROL form only: the pre-fix bare `printf %q` shape, run
    # under the SAME /bin/bash 3.2 that ships on macOS. This is a
    # hand-constructed comparison (install-team.sh itself only ever emits
    # the FIXED form now, so there is no live code path left that produces
    # this) — its only job is to prove the pty harness actually reproduces
    # the ZLE-mangling bug at all, so a pass on the positive cases below
    # isn't just the harness being vacuously lenient. LANG/LC_ALL=en_US.UTF-8
    # is forced on the computing process so the bug reproduces regardless of
    # the runner's own ambient locale.
    _g9_old_q() {
        env LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 /bin/bash -c 'printf %q "$1"' _ "$1"
    }
    _g9_pty_pwd() {
        # $1 = full command line to type (e.g. "cd ..."), $2 = output file
        python3 "$G9_HARNESS" "$G9_ZDOTDIR" "$G9_HOME" "$1" "$2"
        cat "$2" 2>/dev/null
    }

    # Recover the exact "keys" argument of the first send-keys call — same
    # shape/contract as G8's extraction, factored out so G9 can call it once
    # per case. A block is ["send-keys","-t",<target>,<keys>,"C-m"] followed
    # by the "===END===" line.
    _g9_extract_cd_line() {
        python3 - "$1" <<'G9EXTPYEOF'
import sys
with open(sys.argv[1]) as f:
    content = f.read()
for block in content.split("===END===\n"):
    lines = block.split("\n")
    while lines and lines[-1] == "":
        lines.pop()
    if len(lines) >= 4 and lines[0] == "send-keys":
        print(lines[3])
        break
G9EXTPYEOF
    }

    # THE ACTUAL FIX UNDER TEST: render a REAL per-agent script via
    # install-team.sh's own generator (the same `_run_generator` /
    # `gen_current` G8 uses above) for a REAL, EXISTING hostile-named
    # directory, run it under the same argv-preserving stub tmux (G8_STUB_BIN,
    # already built above), and recover the exact "cd ..." line it sent to
    # send-keys. This exercises install-team.sh's actual
    # `_SESSION_DIRECTORY_Q=$(LC_ALL=C /bin/bash -c ...)` line — a
    # hand-rolled duplicate of that line in this test file would keep
    # passing even if the real fix regressed back to the ineffective
    # in-process `LC_ALL=C printf %q` form.
    _g9_real_cd_line() {
        local dir="$1" label="$2"
        local atf="$TEST_TMP_DIR/case-g9-atf-$label"
        _run_generator "$atf" "$dir"
        local script
        script="$(find "$atf/spacedock/scripts" -maxdepth 1 -name 'spacedock-*-startup.sh' 2>/dev/null | head -1)"
        [ -z "$script" ] && return 1
        local log="$TEST_TMP_DIR/case-g9-tmux-$label.log"
        : > "$log"
        # LANG/LC_ALL=en_US.UTF-8 here (not just inside install-team.sh's own
        # fixed line) matters for MUTATION-SENSITIVITY: the fixed form forces
        # its own subprocess's locale regardless of this ambient value, but a
        # regression back to the ineffective in-process `LC_ALL=C printf %q`
        # builtin form inherits ITS classification from whatever locale THIS
        # generated script process itself started under — without forcing
        # UTF-8 here, that regression would go undetected if the runner's own
        # ambient locale happens not to be UTF-8.
        #
        # Explicit /bin/bash, NOT PATH-resolved `bash` — MEASURED this
        # matters: on a machine where Homebrew bash 5 sits ahead of
        # /bin/bash on PATH, running the generated script under bash 5
        # masks the in-process `LC_ALL=C printf %q` regression entirely
        # (bash 5's %q is locale-correct either way), so a bare `bash
        # "$script"` here would make this whole case mutation-BLIND on
        # exactly the machines most likely to run it. install-team.sh's own
        # fix hardcodes /bin/bash for the same reason (its output must not
        # depend on PATH ordering); this harness has to match that to
        # actually exercise the failure mode the fix targets.
        env -u TMUX -u TMUX_PANE -u TMUX_SOCKET \
            LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
            HOME="$G9_HOME" AITEAMFORGE_DIR="$atf" PATH="$G8_STUB_BIN:$PATH" \
            TMUX_STUB_LOG="$log" SKIP_ATTACH=1 \
            /bin/bash "$script" >/dev/null 2>&1
        _g9_extract_cd_line "$log"
    }

    # ---- Negative control: the pre-fix form fails for 日本 under the pty,
    # proving the harness actually reproduces the bug (not just a vacuous
    # pass) ----
    G9_JP_DIR="$G9_HOME/g9-jp-日本"
    mkdir -p "$G9_JP_DIR"
    G9_JP_OLD_Q="$(_g9_old_q "$G9_JP_DIR")"
    G9_JP_OLD_PWD="$(_g9_pty_pwd "cd $G9_JP_OLD_Q" "$TEST_TMP_DIR/g9-jp-old-out")"

    test_start "G9 (negative control): pre-fix plain printf %q FAILS the pty round-trip for 日本"
    # XACA-1215-022: the mis-encoding is specific to /bin/bash 3.x (macOS).
    # bash 5 (Linux) emits raw UTF-8 that round-trips, so there the pre-fix
    # form legitimately succeeds and this control cannot reproduce the bug.
    G9_BIN_BASH_MAJOR="$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null)"
    if [ "$G9_BIN_BASH_MAJOR" != "3" ]; then
        test_skip "/bin/bash is major version ${G9_BIN_BASH_MAJOR:-unknown}, not 3 — the pre-fix mis-encoding only reproduces on bash 3.x; positive G9 assertions below still run"
    elif [ "$G9_JP_OLD_PWD" != "$G9_JP_DIR" ]; then
        test_pass
    else
        test_fail "Pre-fix form unexpectedly succeeded — the negative control no longer reproduces the bug; the positive assertions below cannot be trusted until this is understood. got=[$G9_JP_OLD_PWD]"
    fi

    # ---- Positive: install-team.sh's REAL generated `cd ...` line passes
    # for 日本, é, emoji, and the round-1 hostile set, with no PWNED
    # execution ----
    _g9_case() {
        local label="$1" suffix="$2" check_pwned="$3"
        local dir pwned cd_line out got
        pwned="$TEST_TMP_DIR/g9-pwned-$label"
        suffix="${suffix//__PWNED__/$pwned}"
        dir="$G9_HOME/$suffix"
        mkdir -p "$dir" 2>/dev/null
        cd_line="$(_g9_real_cd_line "$dir" "$label")"
        out="$TEST_TMP_DIR/g9-out-$label"
        got="$(_g9_pty_pwd "$cd_line" "$out")"

        test_start "G9 ($label): real generated cd-line round-trips correctly under the pty"
        if [ -n "$cd_line" ] && [ "$got" = "$dir" ]; then
            test_pass
        else
            test_fail "expected=[$dir] got=[$got] cd_line=[$cd_line]"
        fi

        if [ "$check_pwned" = true ]; then
            test_start "G9 ($label): no PWNED sentinel created (hostile payload never executed)"
            if [ ! -e "$pwned" ]; then
                test_pass
            else
                test_fail "PWNED sentinel file was created: $pwned"
            fi
        fi
    }

    _g9_case 'japanese'  'g9-jp-日本'                       false
    _g9_case 'accent'    'g9-accent-é'                      false
    _g9_case 'emoji'     'g9-emoji-😀'                       false
    _g9_case 'space'     'g9 space'                          false
    _g9_case 'cmd-subst' 'g9-cs-$(touch __PWNED__)x'         true
    _g9_case 'backtick'  'g9-bt-`touch __PWNED__`x'          true
    _g9_case 'dquote'    'g9-dq-"q'                          false
    _g9_case 'squote'    "g9-sq-'q"                          false
    _g9_case 'backslash' 'g9-bs-a\b'                         false
    _g9_case 'bang'      'g9-bang-!x'                        false
fi



# ═══════════════════════════════════════════════════════════════════════════
# CASE H — XACA-1215-017/018/020: the master template's retry-loop surfaces
# the REAL per-agent failure cause on the terminal, not just a pointer to
# the shared session log (017); the printed cause carries no raw terminal
# control bytes (018); and this test's own hygiene never touches a real
# team name or real /tmp (020). Drives the actual session-verify/retry
# block extracted verbatim from team-startup.sh.template with fake
# per-agent scripts that fail exactly the way the XACA-1215-004
# missing-directory guard does, under BOTH bash and zsh (the template's own
# shebang is #!/bin/zsh).
# ═══════════════════════════════════════════════════════════════════════════
H_TEMPLATE="$TAP_ROOT/share/templates/team-startup.sh.template"

# XACA-1215-020: a fake team id that cannot collide with any real team.conf
# (command/ios/android/firebase/dns/academy/medical/legal/finance/freelance/
# spacedock) — Case H used to hardcode "spacedock" throughout, which meant
# every run wrote a real /tmp/spacedock-startup-sessions-<ts>.log using a
# LIVE team's log name.
H_FAKE_TEAM="xaca1215caseh"

test_start "H preflight: team-startup.sh.template exists"
if [ -f "$H_TEMPLATE" ]; then test_pass; else test_fail "Not found: $H_TEMPLATE"; fi

# Extract the session-verify/retry block by text anchor (not fixed line
# numbers — XACA-1216 is concurrently editing other regions of this same
# template). No {{...}} template placeholders appear inside this block (they
# only appear in the config header further up), so it is valid bash/zsh as-is.
_extract_session_loop_block() {
    awk '
        /^_SESSION_LOG="\/tmp\// { capture = 1 }
        capture && /^echo "  All sessions initialized"$/ { exit }
        capture { print }
    ' "$1"
}

H_EXTRACTED_RAW="$TEST_TMP_DIR/case-h-extracted-raw.sh"
_extract_session_loop_block "$H_TEMPLATE" > "$H_EXTRACTED_RAW"

# XACA-1215-020: relocate the block's own /tmp writes into TEST_TMP_DIR
# before running it — both the shared per-run session log and the
# per-agent mktemp scratch file — so this test never touches real /tmp.
# Textual substitution on the EXTRACTED COPY only; the live template ships
# unmodified (verify with `git diff` that this test file is the only
# thing touched by this transform).
H_BODY="$TEST_TMP_DIR/case-h-body.sh"
sed \
    -e "s#^_SESSION_LOG=\"/tmp/#_SESSION_LOG=\"${TEST_TMP_DIR}/#" \
    -e "s#mktemp \"/tmp/\.#mktemp \"${TEST_TMP_DIR}/.#" \
    "$H_EXTRACTED_RAW" > "$H_BODY"

test_start "H preflight: /tmp relocation sed matched both target lines (else this test would still touch real /tmp)"
if grep -q "^_SESSION_LOG=\"${TEST_TMP_DIR}/" "$H_BODY" 2>/dev/null \
   && grep -q "mktemp \"${TEST_TMP_DIR}/\." "$H_BODY" 2>/dev/null; then
    test_pass
else
    test_fail "sed did not relocate one or both /tmp writes — template shape may have drifted: $(cat "$H_BODY" 2>/dev/null | head -40)"
fi

H_EXTRACTED="$TEST_TMP_DIR/case-h-extracted.sh"
{
    echo '_run_h_session_loop() {'
    cat "$H_BODY"
    echo '}'
} > "$H_EXTRACTED"

test_start "H preflight: session-verify/retry block extracts to valid bash"
if [ -s "$H_EXTRACTED" ] && bash -n "$H_EXTRACTED" 2>"$TEST_TMP_DIR/h-syn.err"; then
    test_pass
else
    test_fail "Extraction empty or invalid: $(cat "$TEST_TMP_DIR/h-syn.err" 2>/dev/null)"
fi

if command -v zsh >/dev/null 2>&1; then
    test_start "H preflight: session-verify/retry block also parses under zsh -n"
    if zsh -n "$H_EXTRACTED" 2>"$TEST_TMP_DIR/h-syn-zsh.err"; then
        test_pass
    else
        test_fail "zsh -n rejected the extracted block: $(cat "$TEST_TMP_DIR/h-syn-zsh.err" 2>/dev/null)"
    fi
fi

# XACA-1215-020: run the extracted block under its own process for each
# shell (never `source`d into this test script's own bash process) — a
# runner file that sources+calls it, invoked as `bash "$H_RUNNER"` and,
# when present, `zsh -f "$H_RUNNER"`.
H_RUNNER="$TEST_TMP_DIR/case-h-runner.sh"
{
    printf '. %q\n' "$H_EXTRACTED"
    echo '_run_h_session_loop'
} > "$H_RUNNER"

# Stub tmux: `has-session` ALWAYS reports missing (exit 1) regardless of
# target — forces every fake per-agent script to actually run, and forces
# BOTH the initial verify and the post-retry verify to fail, landing
# deterministically on the "still missing" branch every time.
H_STUB_BIN="$TEST_TMP_DIR/h-stub-bin"
mkdir -p "$H_STUB_BIN"
cat > "$H_STUB_BIN/tmux" <<'HSTUBEOF'
#!/bin/sh
for arg in "$@"; do
    case "$arg" in
        has-session) exit 1 ;;
    esac
done
exit 0
HSTUBEOF
chmod +x "$H_STUB_BIN/tmux"

H_HOME="$TEST_TMP_DIR/case-h-home"
H_ATF="$TEST_TMP_DIR/case-h-atf"
mkdir -p "$H_HOME" "$H_ATF/$H_FAKE_TEAM/scripts"

# Two fake per-agent scripts, each shaped like the real XACA-1215-004
# missing-directory guard's failure, with DIFFERENT cause text — proves the
# fix shows each agent's OWN cause with no cross-contamination even though
# the initial (parallel/backgrounded) launch phase interleaves both in the
# shared $_SESSION_LOG. XACA-1215-018 extension: each ALSO emits a real
# `clear`-equivalent control sequence first — exactly what the actual
# generated per-agent script does unconditionally (install-team.sh's
# generate_script(), no `[[ -t 1 ]]` guard) before this same failure path
# — so the retry capture genuinely contains raw ESC bytes, and the
# assertions below prove the template's printing step (018) strips them
# rather than the test simply never having produced any.
cat > "$H_ATF/$H_FAKE_TEAM/scripts/${H_FAKE_TEAM}-flaky-startup.sh" <<'HFAKEEOF'
#!/bin/bash
printf '\033[3J\033[H\033[2J'
printf '\033c\0337\033(B\033=\007\017'
printf 'Initializing \0338Xaca1215caseh\033> Flaky...\r\n'
echo "Initializing Xaca1215caseh Flaky..."
echo "Error: working directory does not exist: /fake/not-cloned-repo" >&2
echo "       (resolved from TEAM_WORKING_DIR for team 'xaca1215caseh' — check the team .conf, an" >&2
echo "       env override, or that the repo/project directory has actually been cloned)" >&2
exit 1
HFAKEEOF
chmod +x "$H_ATF/$H_FAKE_TEAM/scripts/${H_FAKE_TEAM}-flaky-startup.sh"

cat > "$H_ATF/$H_FAKE_TEAM/scripts/${H_FAKE_TEAM}-flaky2-startup.sh" <<'HFAKE2EOF'
#!/bin/bash
printf '\033[3J\033[H\033[2J'
echo "Initializing Xaca1215caseh Flaky2..."
echo "Error: working directory does not exist: /fake/OTHER-repo" >&2
exit 1
HFAKE2EOF
chmod +x "$H_ATF/$H_FAKE_TEAM/scripts/${H_FAKE_TEAM}-flaky2-startup.sh"

# Shared assertion set, run once per shell that executed the block.
_case_h_assert() {
    local _label="$1" _out="$2"

    test_start "H ($_label): retry loop reports BOTH agents as still missing"
    if grep -q "${H_FAKE_TEAM}-flaky still missing" "$_out" 2>/dev/null && grep -q "${H_FAKE_TEAM}-flaky2 still missing" "$_out" 2>/dev/null; then
        test_pass
    else
        test_fail "Expected both 'still missing' lines not found ($_label): $(cat "$_out" 2>/dev/null)"
    fi

    test_start "H ($_label) (XACA-1215-017): the REAL cause reaches stdout (not just the log pointer)"
    if grep -q "Error: working directory does not exist: /fake/not-cloned-repo" "$_out" 2>/dev/null \
       && grep -q "Error: working directory does not exist: /fake/OTHER-repo" "$_out" 2>/dev/null; then
        test_pass
    else
        test_fail "Cause text missing from stdout ($_label) — only the log pointer was shown: $(cat "$_out" 2>/dev/null)"
    fi

    test_start "H ($_label): cause lines are indented (visually distinct follow-up, not another top-level line)"
    if grep -qE '^       Error: working directory does not exist' "$_out" 2>/dev/null; then
        test_pass
    else
        test_fail "Cause line not indented as expected ($_label): $(cat "$_out" 2>/dev/null)"
    fi

    test_start "H ($_label): each agent's cause block shows ONLY its own cause (no cross-contamination)"
    local _b1 _b2
    _b1="$(grep -A6 "${H_FAKE_TEAM}-flaky still missing" "$_out" 2>/dev/null)"
    _b2="$(grep -A6 "${H_FAKE_TEAM}-flaky2 still missing" "$_out" 2>/dev/null)"
    if echo "$_b1" | grep -q "not-cloned-repo" && ! echo "$_b1" | grep -q "OTHER-repo" \
       && echo "$_b2" | grep -q "OTHER-repo" && ! echo "$_b2" | grep -q "not-cloned-repo"; then
        test_pass
    else
        test_fail "Cross-contamination or missing cause detected ($_label). block1=[$_b1] block2=[$_b2]"
    fi

    test_start "H ($_label) (XACA-1215-021): no C0 control bytes other than TAB/LF (BEL, SI, CR) reach stdout"
    local _c0_count
    _c0_count=$(LC_ALL=C tr -dc '\000-\010\013-\037\177' < "$_out" 2>/dev/null | wc -c | tr -d ' ')
    if [ "${_c0_count:-0}" -eq 0 ]; then
        test_pass
    else
        test_fail "$_c0_count raw control byte(s) reached stdout ($_label): $(LC_ALL=C tr -dc '\000-\010\013-\037\177' < "$_out" | od -c | head -4)"
    fi

    test_start "H ($_label) (XACA-1215-018): no raw terminal control (ESC) bytes reach stdout"
    local _esc_count
    _esc_count=$(LC_ALL=C grep -ac $'\033' "$_out" 2>/dev/null)
    if [ "${_esc_count:-0}" -eq 0 ]; then
        test_pass
    else
        test_fail "$_esc_count line(s) with a raw ESC byte reached stdout ($_label) — the fake agents' clear sequence leaked through the retry printing step: $(od -c "$_out" 2>/dev/null | head -8)"
    fi
}

for _h_shell in bash zsh; do
    if [ "$_h_shell" = zsh ] && ! command -v zsh >/dev/null 2>&1; then
        test_start "H (zsh): session-verify/retry block run"
        test_skip "zsh not found on PATH (expected on CI ubuntu runners) — the bash run is not skipped"
        continue
    fi

    H_STDOUT="$TEST_TMP_DIR/case-h-stdout-$_h_shell.log"
    (
        TEAM_ID="$H_FAKE_TEAM"
        AITEAMFORGE_DIR="$H_ATF"
        TMUX_SOCKET="h-test-socket"
        export TEAM_ID AITEAMFORGE_DIR TMUX_SOCKET
        unset TMUX TMUX_PANE TMUX_SOCKET_REAL 2>/dev/null
        export PATH="$H_STUB_BIN:$PATH"
        if [ "$_h_shell" = zsh ]; then
            zsh -f "$H_RUNNER"
        else
            bash "$H_RUNNER"
        fi
    ) >"$H_STDOUT" 2>&1

    _case_h_assert "$_h_shell" "$H_STDOUT"
done

# XACA-1215-020: no file anywhere under /tmp (real /tmp, trailing slash —
# not TEST_TMP_DIR) should ever mention the fake team id, across EITHER
# shell run. Catches a leaked mktemp scratch file (cleanup regression) AND
# a leaked _SESSION_LOG (relocation regression) in one assertion.
test_start "H: no leaked /tmp/ files for the fake team, across both shell runs"
H_LEAKED=$(find /tmp/ -maxdepth 1 -iname "*${H_FAKE_TEAM}*" 2>/dev/null | wc -l | tr -d ' ')
if [ "${H_LEAKED:-0}" -eq 0 ]; then
    test_pass
else
    test_fail "Leaked file(s) under /tmp/ matching the fake team id: $(find /tmp/ -maxdepth 1 -iname "*${H_FAKE_TEAM}*" 2>/dev/null)"
fi


# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "Results: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed, ${_SKIP_COUNT} skipped"
    if [ "$_FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
fi
exit 0
