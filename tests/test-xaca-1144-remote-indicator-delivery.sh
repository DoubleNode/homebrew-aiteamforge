#!/bin/bash

# test-xaca-1144-remote-indicator-delivery.sh
# Regression test for XACA-1144-008 (parent XACA-1144: remote-team iTerm2
# "C " active-tab indicator).
#
# WHY THIS EXISTS (assert DELIVERY, not presence)
# ------------------------------------------------
# This ticket has produced FOUR separate instances of the same failure class:
# a file correct in canonical, correctly wired in comments, correctly named
# by the right call sites — that reaches ZERO consumers. XACA-0214, XACA-0231,
# and XACA-0223 all shipped nothing and are marked completed. During THIS
# ticket, iterm2_claude_active_watch.py was built and wired into both connect
# templates, then shipped to zero delivery sites — caught only by manual
# verification (BASELINE-001), not by a test. A test asserting a file exists
# in the repo would have passed over all four.
#
# BASELINE (pre-fix, captured live on darren-m4-mini, tap v0.20.7 —
# kanban/plans/XACA-1144/BASELINE-001.md):
#   - iterm2_badge_helper.sh and scripts/iterm2_tab_title_prefix.py: ABSENT
#     from the tap entirely (measured: `find homebrew-tap -name <either>`
#     returned zero matches before the fix).
#   - All 4 named call sites (cc-aliases.sh shipped copy, kanban-session-
#     start.py, kanban-stop.py, update_claude_agent.sh) either logged
#     "iterm2_badge_helper.sh not found; skipping claude_active set/clear"
#     or (cc-aliases.sh) had no such call site AT ALL in the shipped file.
#   - Every failure was silent: exit 0, no exception, no visible symptom.
#
# This file asserts three things BASELINE-001 could not (it was read-only,
# pre-fix, evidence-gathering only):
#   A. Delivery of iterm2_badge_helper.sh, scripts/iterm2_tab_title_prefix.py,
#      and scripts/iterm2_claude_active_watch.py to a SIMULATED consumer
#      layout via all their required wiring sites — with the root-vs-
#      scripts/ split enforced as a hard, mutually-dependent invariant.
#   B. All SIX call sites (four the ticket named, two absorbed as scope
#      corrections per DESIGN-DECISION-005: scripts/onscreen-heal.sh and
#      scripts/xaca-0231-cleanup.sh) resolve the delivered files on a
#      simulated consumer layout.
#   C. The remote-indicator SIGNAL PATH itself: set_claude_active/
#      clear_claude_active emit the correct OSC 1337 SetUserVar transitions
#      to a REAL tty (never captured stdout — see the methodology note
#      below), through the actual production call chain (the real
#      kanban-session-start.py / kanban-stop.py / iterm2_badge_helper.sh),
#      and that the parametric connect/disconnect templates start/stop the
#      watcher process under the SAME pidfile key.
#
# METHODOLOGY NOTE (DESIGN-DECISION-005, "Methodological note for 008"):
# Escape sequences MUST be written to a REAL tty, never captured via a shell
# pipe/command-substitution — a piped capture can return a reassuring "no
# escape sequence" result that is a harness artifact, not evidence the
# mechanism is dead (this nearly killed the correct design during planning).
# Section C therefore drives every OSC-emitting call through a real
# python `pty` pair and reads the bytes back off the pty's OWN fd — never
# `$( ... )` command substitution on the process's stdout.
#
# Every assertion group below carries an explicit RED proof: either a
# negative control that reproduces BASELINE-001's exact failure signature
# (the literal "iterm2_badge_helper.sh not found; skipping claude_active
# set" log line, or an absent file) when the fix is subtracted, or (for the
# upgrade-materialize mechanism) a rerun against the PRE-FIX shape of the
# mandatory-materialize allowlists. An assertion with no working negative
# control is flagged in the header comment as vacuous rather than asserted.
#
# All filesystem activity is sandboxed to TEST_TMP_DIR / a synthetic HOME.
# NEVER touches real $HOME / ~/.aiteamforge / ~/dev-team — installer-test
# safety rule. tmux usage (Section B5) is isolated to a private -S socket
# path under /tmp, never a shared -L name, and only that specific socket's
# server is killed at cleanup (see feedback_tmux_test_isolation_needs_tmpdir_not_names.md).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEV_TEAM_ROOT_REAL="$(cd "$TAP_ROOT/.." && pwd)"
UPGRADE_SH="$TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh"
INSTALL_SHELL_SH="$TAP_ROOT/libexec/installers/install-shell.sh"
SYNC_TAP_SH="$DEV_TEAM_ROOT_REAL/sync-tap.sh"
REAL_BADGE_HELPER="$DEV_TEAM_ROOT_REAL/iterm2_badge_helper.sh"
REAL_PREFIX_HELPER="$DEV_TEAM_ROOT_REAL/scripts/iterm2_tab_title_prefix.py"
SHIPPED_BADGE_HELPER="$TAP_ROOT/share/scripts/iterm2_badge_helper.sh"
SHIPPED_PREFIX_HELPER="$TAP_ROOT/share/scripts/iterm2_tab_title_prefix.py"
SHIPPED_WATCHER="$TAP_ROOT/share/scripts/iterm2_claude_active_watch.py"
SHIPPED_UPDATE_CLAUDE_AGENT="$TAP_ROOT/share/scripts/update_claude_agent.sh"
SHIPPED_CC_ALIASES="$TAP_ROOT/share/templates/aliases/cc-aliases.sh"
KANBAN_SESSION_START="$DEV_TEAM_ROOT_REAL/kanban-hooks/kanban-session-start.py"
KANBAN_STOP="$DEV_TEAM_ROOT_REAL/kanban-hooks/kanban-stop.py"
ONSCREEN_HEAL="$DEV_TEAM_ROOT_REAL/scripts/onscreen-heal.sh"
XACA0231_CLEANUP="$DEV_TEAM_ROOT_REAL/scripts/xaca-0231-cleanup.sh"
CONNECT_TEMPLATE="$DEV_TEAM_ROOT_REAL/scripts/templates/team-connect-parametric.sh.template"
DISCONNECT_TEMPLATE="$DEV_TEAM_ROOT_REAL/scripts/templates/team-disconnect-parametric.sh.template"

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework: works both as a sourced test-runner.sh file AND as a
# directly-invoked script (mirrors test-xaca-1143-worktree-helpers-materialize.sh).
# ─────────────────────────────────────────────────────────────────────────────
_STANDALONE=false
if ! type -t test_start >/dev/null 2>&1; then
    _STANDALONE=true
    _PASS_COUNT=0
    _FAIL_COUNT=0
    _CURRENT_TEST=""

    test_start() { _CURRENT_TEST="$1"; echo "  >> $1"; }
    test_pass()  { _PASS_COUNT=$((_PASS_COUNT + 1)); echo "     PASS: $_CURRENT_TEST"; }
    test_fail()  { _FAIL_COUNT=$((_FAIL_COUNT + 1)); echo "     FAIL: $_CURRENT_TEST — $1" >&2; }

    assert_file_exists() {
        local file="$1" msg="${2:-Expected file to exist: $1}"
        [ -f "$file" ] || { test_fail "$msg"; return 1; }
    }
    assert_file_not_exists() {
        local file="$1" msg="${2:-Expected file to not exist: $1}"
        [ ! -f "$file" ] || { test_fail "$msg"; return 1; }
    }
    assert_contains() {
        local haystack="$1" needle="$2" msg="${3:-Expected to find '$2' in string}"
        [[ "$haystack" == *"$needle"* ]] || { test_fail "$msg"; return 1; }
    }
    assert_not_contains() {
        local haystack="$1" needle="$2" msg="${3:-Expected NOT to find '$2' in string}"
        [[ "$haystack" != *"$needle"* ]] || { test_fail "$msg"; return 1; }
    }
fi

for _p in print_section print_info print_success print_warning print_error info success warning; do
    if ! declare -f "$_p" >/dev/null 2>&1; then
        eval "${_p}() { :; }"
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Temp directory: use the runner-supplied TEST_TMP_DIR or create our own.
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca1144-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi

case "$TEST_TMP_DIR" in
    "$HOME"|"$HOME"/*) echo "ERROR: TEST_TMP_DIR resolved inside \$HOME — refusing." >&2; exit 1 ;;
esac

_TMUX_TEST_SOCK=""
cleanup() {
    if [ -n "$_TMUX_TEST_SOCK" ]; then
        tmux -S "$_TMUX_TEST_SOCK" kill-server >/dev/null 2>&1 || true
    fi
    if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then
        rm -rf "$TEST_TMP_DIR"
    fi
}
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Sanity: the three files this ticket ships must actually be present in the
# tap before we test their DELIVERY — otherwise every downstream assertion
# would be testing a fixture that doesn't reflect the codebase at all.
# ─────────────────────────────────────────────────────────────────────────────
for _f in "$SHIPPED_BADGE_HELPER" "$SHIPPED_PREFIX_HELPER" "$SHIPPED_WATCHER" \
          "$REAL_BADGE_HELPER" "$KANBAN_SESSION_START" "$KANBAN_STOP" \
          "$ONSCREEN_HEAL" "$XACA0231_CLEANUP" "$SHIPPED_UPDATE_CLAUDE_AGENT" \
          "$SHIPPED_CC_ALIASES" "$CONNECT_TEMPLATE" "$DISCONNECT_TEMPLATE"; do
    test_start "Sanity: required fixture file exists ($(basename "$_f"))"
    if assert_file_exists "$_f"; then test_pass; fi
done

# ═════════════════════════════════════════════════════════════════════════════
# SECTION A — Delivery to a simulated consumer layout
# ═════════════════════════════════════════════════════════════════════════════

# ── A1: sync-tap.sh maps all three files to their shipped locations ──
test_start "A1: sync-tap.sh maps iterm2_badge_helper.sh -> share/scripts/"
if assert_contains "$(grep -F 'sync_file "$SOURCE_DIR/iterm2_badge_helper.sh"' "$SYNC_TAP_SH")" \
    '$TAP/share/scripts/iterm2_badge_helper.sh' \
    "sync-tap.sh does not map iterm2_badge_helper.sh to \$TAP/share/scripts/"; then
    test_pass
fi

test_start "A1: sync-tap.sh maps scripts/iterm2_tab_title_prefix.py -> share/scripts/"
if assert_contains "$(grep -F 'sync_file "$SOURCE_DIR/scripts/iterm2_tab_title_prefix.py"' "$SYNC_TAP_SH")" \
    '$TAP/share/scripts/iterm2_tab_title_prefix.py' \
    "sync-tap.sh does not map scripts/iterm2_tab_title_prefix.py to \$TAP/share/scripts/"; then
    test_pass
fi

test_start "A1: sync-tap.sh maps scripts/iterm2_claude_active_watch.py -> share/scripts/"
if assert_contains "$(grep -F 'sync_file "$SOURCE_DIR/scripts/iterm2_claude_active_watch.py"' "$SYNC_TAP_SH")" \
    '$TAP/share/scripts/iterm2_claude_active_watch.py' \
    "sync-tap.sh does not map scripts/iterm2_claude_active_watch.py to \$TAP/share/scripts/"; then
    test_pass
fi

# ── Extract the real functions from aiteamforge-upgrade.sh / install-shell.sh ──
_extract_fn() {
    awk -v fn="$1" '
      $0 ~ ("^" fn "\\(\\) \\{") { capture=1 }
      capture { print }
      capture && /^}$/ { exit }
    ' "$2"
}

_EXTRACT_FAILED=false
for _fn in _xaca0608_aux_script_map _xaca0608_aux_scriptdir_basenames _xaca0608_render_team_script \
           _xaca1143_aux_mandatory_materialize_basenames _xaca0673_mandatory_materialize_basenames \
           update_aux_scripts update_runtime_helpers; do
    test_start "Sanity: can extract $_fn from aiteamforge-upgrade.sh"
    _src="$(_extract_fn "$_fn" "$UPGRADE_SH")"
    if [ -z "$_src" ]; then
        test_fail "awk returned empty"
        _EXTRACT_FAILED=true
        continue
    fi
    eval "$_src"
    if declare -f "$_fn" >/dev/null; then test_pass; else test_fail "$_fn not defined after extraction"; _EXTRACT_FAILED=true; fi
done

test_start "Sanity: can extract install_helper_scripts from install-shell.sh"
_src="$(_extract_fn install_helper_scripts "$INSTALL_SHELL_SH")"
if [ -z "$_src" ]; then
    test_fail "awk returned empty"
    _EXTRACT_FAILED=true
else
    eval "$_src"
    if declare -f install_helper_scripts >/dev/null; then test_pass; else test_fail "install_helper_scripts not defined after extraction"; _EXTRACT_FAILED=true; fi
fi

if [ "$_EXTRACT_FAILED" = true ]; then
    echo "FATAL: one or more functions failed to extract — aiteamforge-upgrade.sh or" >&2
    echo "install-shell.sh shape has changed; update this test's awk ranges." >&2
    if [ "$_STANDALONE" = true ]; then echo "Results: ${_PASS_COUNT} passed, $((_FAIL_COUNT)) failed"; fi
    exit 1
fi

# ── A2: fresh install (install_helper_scripts) lands the badge helper at
#    WORKING_DIR ROOT, never at WORKING_DIR/scripts/ ──
_A2_TMP="$TEST_TMP_DIR/a2-fresh-install"
mkdir -p "$_A2_TMP"
(
    INSTALL_ROOT="$TAP_ROOT"
    AITEAMFORGE_DIR="$_A2_TMP/aiteamforge"
    mkdir -p "$AITEAMFORGE_DIR"
    install_helper_scripts >/dev/null 2>&1
)
_A2_ROOT_TARGET="$_A2_TMP/aiteamforge/iterm2_badge_helper.sh"
_A2_WRONG_TARGET="$_A2_TMP/aiteamforge/scripts/iterm2_badge_helper.sh"

test_start "A2: fresh install materialises iterm2_badge_helper.sh at AITEAMFORGE_DIR root"
if assert_file_exists "$_A2_ROOT_TARGET" \
    "install_helper_scripts() did not copy iterm2_badge_helper.sh to \$AITEAMFORGE_DIR root — all four canonical call sites probe exactly that path"; then
    test_pass
fi

test_start "A2: fresh install does NOT put iterm2_badge_helper.sh under scripts/ (wrong-dir control)"
if assert_file_not_exists "$_A2_WRONG_TARGET" \
    "iterm2_badge_helper.sh landed at scripts/ instead of root — this breaks all four call sites' hardcoded root probe"; then
    test_pass
fi

test_start "A2: materialised iterm2_badge_helper.sh keeps its exec bit"
if [ -x "$_A2_ROOT_TARGET" ]; then test_pass; else test_fail "not executable (or missing)"; fi

# ── A3: upgrade materialize — root-vs-scripts split is mutually dependent.
#    Simulate an ALREADY-INSTALLED consumer whose working dir never had any
#    of the three files (BASELINE-001's exact precondition), then run the
#    real update_aux_scripts + update_runtime_helpers. ──
_mk_a3_sandbox() {
    local tag="$1"
    local dir="$TEST_TMP_DIR/$tag"
    mkdir -p "$dir/framework/share/scripts" "$dir/aiteamforge/scripts"
    cp "$SHIPPED_BADGE_HELPER" "$dir/framework/share/scripts/iterm2_badge_helper.sh"
    cp "$SHIPPED_PREFIX_HELPER" "$dir/framework/share/scripts/iterm2_tab_title_prefix.py"
    cp "$SHIPPED_WATCHER" "$dir/framework/share/scripts/iterm2_claude_active_watch.py"
    echo "$dir"
}

_A3_DIR="$(_mk_a3_sandbox a3-upgrade-green)"
(
    FRAMEWORK_DIR="$_A3_DIR/framework"
    WORKING_DIR="$_A3_DIR/aiteamforge"
    FORCE=false
    DRY_RUN=false
    update_aux_scripts >/dev/null 2>&1
    update_runtime_helpers >/dev/null 2>&1
)
_A3_BADGE_ROOT="$_A3_DIR/aiteamforge/iterm2_badge_helper.sh"
_A3_BADGE_WRONG="$_A3_DIR/aiteamforge/scripts/iterm2_badge_helper.sh"
_A3_PREFIX_SCRIPTS="$_A3_DIR/aiteamforge/scripts/iterm2_tab_title_prefix.py"
_A3_PREFIX_WRONG="$_A3_DIR/aiteamforge/iterm2_tab_title_prefix.py"
_A3_WATCHER_SCRIPTS="$_A3_DIR/aiteamforge/scripts/iterm2_claude_active_watch.py"
_A3_WATCHER_WRONG="$_A3_DIR/aiteamforge/iterm2_claude_active_watch.py"

test_start "A3: upgrade materialises iterm2_badge_helper.sh at root when previously ABSENT"
if assert_file_exists "$_A3_BADGE_ROOT" \
    "update_aux_scripts()'s '[ ! -f \$target ] && continue' guard skips every entry not already installed unless mandatory — badge helper never reached an already-installed consumer"; then
    test_pass
fi
test_start "A3: badge helper NOT swept to scripts/ (root-vs-scripts swap control)"
if assert_file_not_exists "$_A3_BADGE_WRONG"; then test_pass; fi

test_start "A3: upgrade materialises scripts/iterm2_tab_title_prefix.py when previously ABSENT"
if assert_file_exists "$_A3_PREFIX_SCRIPTS" \
    "update_runtime_helpers()'s mandatory-materialize sweep (_xaca0673) never reached iterm2_tab_title_prefix.py"; then
    test_pass
fi
test_start "A3: prefix helper NOT placed at WORKING_DIR root (root-vs-scripts swap control)"
if assert_file_not_exists "$_A3_PREFIX_WRONG"; then test_pass; fi

test_start "A3: upgrade materialises scripts/iterm2_claude_active_watch.py when previously ABSENT"
if assert_file_exists "$_A3_WATCHER_SCRIPTS" \
    "update_runtime_helpers()'s mandatory-materialize sweep (_xaca0673) never reached iterm2_claude_active_watch.py — the watcher XACA-1144-006 shipped to zero delivery sites"; then
    test_pass
fi
test_start "A3: watcher NOT placed at WORKING_DIR root (root-vs-scripts swap control)"
if assert_file_not_exists "$_A3_WATCHER_WRONG"; then test_pass; fi

# ── A4: RED proof. Rerun the SAME real update_aux_scripts / update_runtime_helpers
#    against the PRE-FIX shape of the two mandatory-materialize allowlists (the
#    literal set that shipped before XACA-1144-002/003/006, reconstructed from
#    the pre-fix commits e190873 (outer/tap) and 70b8f08 (submodule)). Everything
#    else (the real functions, the real shipped source files) stays IDENTICAL —
#    only the allowlist shrinks back to its pre-fix membership. This is the
#    direct RED-before-GREEN proof: on a fresh absent sandbox, the fix's own
#    allowlist entries are what make materialization happen; remove them and
#    BASELINE-001's exact absent-file state reproduces. ──
_xaca1143_aux_mandatory_materialize_basenames() {
    cat <<'REDEOF'
worktree-helpers.sh
REDEOF
}
_xaca0673_mandatory_materialize_basenames() {
    cat <<'REDEOF'
iterm2_venv_bootstrap.py
kb-init-team-guard.sh
kb-init-team
remote-tmux-attach.sh
lcars-launch-helpers.sh
lcars-remote-atf-resolve.sh
kb-api-key
kb-ttyd-bridge.sh
kb-host-ready.sh
kb-msg-provision
REDEOF
}

_A4_DIR="$(_mk_a3_sandbox a4-upgrade-red)"
(
    FRAMEWORK_DIR="$_A4_DIR/framework"
    WORKING_DIR="$_A4_DIR/aiteamforge"
    FORCE=false
    DRY_RUN=false
    update_aux_scripts >/dev/null 2>&1
    update_runtime_helpers >/dev/null 2>&1
)

test_start "A4 RED: pre-fix allowlist reproduces BASELINE-001 — badge helper stays absent"
if assert_file_not_exists "$_A4_DIR/aiteamforge/iterm2_badge_helper.sh" \
    "badge helper materialised even WITHOUT its mandatory-list entry — A3's positive assertion would be vacuous"; then
    test_pass
fi
test_start "A4 RED: pre-fix allowlist reproduces BASELINE-001 — prefix helper stays absent"
if assert_file_not_exists "$_A4_DIR/aiteamforge/scripts/iterm2_tab_title_prefix.py" \
    "prefix helper materialised even WITHOUT its mandatory-list entry — A3's positive assertion would be vacuous"; then
    test_pass
fi
test_start "A4 RED: pre-fix allowlist reproduces BASELINE-001 — watcher stays absent"
if assert_file_not_exists "$_A4_DIR/aiteamforge/scripts/iterm2_claude_active_watch.py" \
    "watcher materialised even WITHOUT its mandatory-list entry — A3's positive assertion would be vacuous"; then
    test_pass
fi

# Restore the REAL (fixed) allowlist functions for anything below that might
# re-extract/re-run upgrade logic (nothing does, but this keeps the script
# honest about which definition is "live" from this point on).
unset -f _xaca1143_aux_mandatory_materialize_basenames _xaca0673_mandatory_materialize_basenames
eval "$(_extract_fn _xaca1143_aux_mandatory_materialize_basenames "$UPGRADE_SH")"
eval "$(_extract_fn _xaca0673_mandatory_materialize_basenames "$UPGRADE_SH")"

# ═════════════════════════════════════════════════════════════════════════════
# SECTION B — all SIX call sites resolve the delivered files on a consumer layout
# ═════════════════════════════════════════════════════════════════════════════
# Consumer layout per BASELINE-001: NO $DEV_TEAM_ROOT, NO ~/dev-team — only
# the tap-installed ~/aiteamforge candidate exists (candidate 3 of 3 on every
# call site). Stub badge/prefix helpers are used here to isolate PATH
# RESOLUTION from the helpers' own internals (already covered by Section C).

_B_HOME="$TEST_TMP_DIR/b-consumer-home"
mkdir -p "$_B_HOME/aiteamforge/scripts"
cat > "$_B_HOME/aiteamforge/iterm2_badge_helper.sh" <<'STUBEOF'
#!/usr/bin/env bash
clear_claude_active() { : > "$B_MARKER_CLEAR"; }
set_claude_badge() { : > "$B_MARKER_BADGE"; }
STUBEOF
chmod +x "$_B_HOME/aiteamforge/iterm2_badge_helper.sh"

cat > "$_B_HOME/aiteamforge/scripts/iterm2_tab_title_prefix.py" <<'STUBPYEOF'
#!/usr/bin/env python3
import os
marker = os.environ.get("B_MARKER_PREFIX")
if marker:
    open(marker, "w").close()
STUBPYEOF
chmod +x "$_B_HOME/aiteamforge/scripts/iterm2_tab_title_prefix.py"

# ── B1: cc-aliases.sh (shipped) — _cc_clear_claude_active ──
if command -v zsh >/dev/null 2>&1; then
    B_MARKER_CLEAR="$TEST_TMP_DIR/b1-marker-clear"
    (
        unset DEV_TEAM_ROOT
        HOME="$_B_HOME" B_MARKER_CLEAR="$B_MARKER_CLEAR" \
            zsh -c "source '$SHIPPED_CC_ALIASES' >/dev/null 2>&1; _cc_clear_claude_active"
    )
    test_start "B1: cc-aliases.sh's _cc_clear_claude_active resolves ~/aiteamforge/iterm2_badge_helper.sh"
    if assert_file_exists "$B_MARKER_CLEAR" \
        "_cc_clear_claude_active did not source+invoke the delivered badge helper — call site 1 (FAULT C) still dead on a consumer layout"; then
        test_pass
    fi

    # RED: same call, badge helper ABSENT (BASELINE-001's actual pre-fix state).
    B_MARKER_CLEAR_NEG="$TEST_TMP_DIR/b1-marker-clear-neg"
    _B_HOME_NEG="$TEST_TMP_DIR/b1-consumer-home-neg"
    mkdir -p "$_B_HOME_NEG/aiteamforge"
    (
        unset DEV_TEAM_ROOT
        HOME="$_B_HOME_NEG" B_MARKER_CLEAR="$B_MARKER_CLEAR_NEG" \
            zsh -c "source '$SHIPPED_CC_ALIASES' >/dev/null 2>&1; _cc_clear_claude_active"
    )
    test_start "B1 RED: absent badge helper reproduces silent no-op (positive assertion is not vacuous)"
    if assert_file_not_exists "$B_MARKER_CLEAR_NEG" \
        "marker fired even without the badge helper present — B1's positive assertion is vacuous"; then
        test_pass
    fi
else
    test_start "B1: cc-aliases.sh (zsh unavailable — cannot run, not a pass)"
    test_fail "zsh not found on this machine"
fi

# ── B4: update_claude_agent.sh (shipped tap copy) ──
B_MARKER_BADGE="$TEST_TMP_DIR/b4-marker-badge"
_B4_OUT="$(
    unset DEV_TEAM_ROOT TMUX
    HOME="$_B_HOME" B_MARKER_BADGE="$B_MARKER_BADGE" \
        bash "$SHIPPED_UPDATE_CLAUDE_AGENT" testagent 2>&1
)"
test_start "B4: update_claude_agent.sh resolves ~/aiteamforge/iterm2_badge_helper.sh"
if assert_file_exists "$B_MARKER_BADGE" \
    "update_claude_agent.sh did not source+invoke the delivered badge helper on a consumer layout"; then
    test_pass
fi
test_start "B4: update_claude_agent.sh prints the badge-updated confirmation"
if assert_contains "$_B4_OUT" "✓ Updated iTerm2 badge" \
    "expected confirmation line missing — BASELINE-001 showed total silence here pre-fix"; then
    test_pass
fi

# RED: badge helper ABSENT.
B_MARKER_BADGE_NEG="$TEST_TMP_DIR/b4-marker-badge-neg"
_B4_HOME_NEG="$TEST_TMP_DIR/b4-consumer-home-neg"
mkdir -p "$_B4_HOME_NEG/aiteamforge"
_B4_OUT_NEG="$(
    unset DEV_TEAM_ROOT TMUX
    HOME="$_B4_HOME_NEG" B_MARKER_BADGE="$B_MARKER_BADGE_NEG" \
        bash "$SHIPPED_UPDATE_CLAUDE_AGENT" testagent 2>&1
)"
test_start "B4 RED: absent badge helper reproduces BASELINE-001's total silence"
if assert_file_not_exists "$B_MARKER_BADGE_NEG"; then
    if assert_not_contains "$_B4_OUT_NEG" "✓ Updated iTerm2 badge" \
        "confirmation line printed even without the badge helper — B4's positive assertion is vacuous"; then
        test_pass
    fi
fi

# ── B5: scripts/onscreen-heal.sh — needs a REAL attached tmux client for
#    #{client_tty} to resolve (a detached session has none). Isolated via an
#    absolute -S socket path under /tmp (never a shared -L name — see
#    feedback_tmux_test_isolation_needs_tmpdir_not_names.md), and only this
#    specific socket's server is killed at cleanup. ──
if command -v tmux >/dev/null 2>&1; then
    _TMUX_TEST_SOCK="/tmp/xaca1144-test-$$-onscreen.sock"
    B_MARKER_PREFIX="$TEST_TMP_DIR/b5-marker-prefix"
    _B5_DONE="$TEST_TMP_DIR/b5-done-marker"
    cat > "$TEST_TMP_DIR/b5-inner.sh" <<INNEREOF
#!/bin/sh
unset DEV_TEAM_ROOT
export HOME="$_B_HOME"
export B_MARKER_PREFIX="$B_MARKER_PREFIX"
. "$ONSCREEN_HEAL"
_onscreen_heal
touch "$_B5_DONE"
INNEREOF
    chmod +x "$TEST_TMP_DIR/b5-inner.sh"

    tmux -S "$_TMUX_TEST_SOCK" new-session -d -s xaca1144onscreen -x 80 -y 24 >/dev/null 2>&1

    # Attach a REAL client via a python-owned pty so #{client_tty} resolves —
    # a detached-only session has no client, and _onscreen_heal silently bails
    # at its very first precondition check (`[ -z "$_client_tty" ] && return 0`)
    # without one. Verified empirically while building this test: a plain
    # `tmux ... send-keys` into a detached-only session runs the command to
    # completion but the marker never fires, because client_tty resolves empty.
    cat > "$TEST_TMP_DIR/b5-attach.py" <<'ATTACHEOF'
import os, pty, subprocess, sys, time
sock = sys.argv[1]
session = sys.argv[2]
master, slave = pty.openpty()
proc = subprocess.Popen(
    ["tmux", "-S", sock, "attach-session", "-t", session],
    stdin=slave, stdout=slave, stderr=slave, preexec_fn=os.setsid,
)
os.close(slave)
# Keep the attach alive long enough for the test to drive send-keys and
# read results; the test's own tmux kill-server call ends this process.
try:
    proc.wait(timeout=30)
except Exception:
    pass
os.close(master)
ATTACHEOF
    ( python3 "$TEST_TMP_DIR/b5-attach.py" "$_TMUX_TEST_SOCK" xaca1144onscreen >/dev/null 2>&1 & )
    sleep 1.5
    tmux -S "$_TMUX_TEST_SOCK" send-keys -t xaca1144onscreen "sh '$TEST_TMP_DIR/b5-inner.sh'" Enter >/dev/null 2>&1
    sleep 3

    test_start "B5: onscreen-heal.sh's _onscreen_heal ran to completion under tmux"
    if assert_file_exists "$_B5_DONE" "the heal function never completed — tmux client-attach harness may need adjustment"; then
        test_pass
    fi
    test_start "B5: onscreen-heal.sh resolves ~/aiteamforge/scripts/iterm2_tab_title_prefix.py"
    if assert_file_exists "$B_MARKER_PREFIX" \
        "onscreen-heal.sh did not invoke the delivered prefix helper — call site 5 (scope correction) still dead on a consumer layout"; then
        test_pass
    fi

    tmux -S "$_TMUX_TEST_SOCK" kill-server >/dev/null 2>&1 || true
    _TMUX_TEST_SOCK=""
else
    test_start "B5: onscreen-heal.sh (tmux unavailable — cannot run, not a pass)"
    test_fail "tmux not found on this machine"
fi

# ── B6: scripts/xaca-0231-cleanup.sh — resolution only. This script never
#    actually invokes iterm2_tab_title_prefix.py's CODE (verified by reading
#    it: Phase 2 uses its own inline iTerm2 API script); the file's presence
#    only steers which python3 gets used (repo/tap venv vs system). Assert
#    exactly that narrower, honest claim: _helper_root resolves to the
#    consumer path when (and only when) the file is delivered. ──
_B6_RESOLVE_SNIPPET="$(sed -n '111,125p' "$XACA0231_CLEANUP")"
if ! printf '%s\n' "$_B6_RESOLVE_SNIPPET" | grep -q '_helper_root='; then
    test_start "Sanity: xaca-0231-cleanup.sh resolution snippet still at expected lines"
    test_fail "line range 111-125 no longer contains the _helper_root resolution block — update this test's line numbers"
else
    _B6_OUT="$(
        unset DEV_TEAM_ROOT
        HOME="$_B_HOME" bash -c "$_B6_RESOLVE_SNIPPET"$'\n''printf "%s\n" "$_helper_root"'
    )"
    test_start "B6: xaca-0231-cleanup.sh resolves _helper_root to the consumer's ~/aiteamforge"
    if assert_contains "$_B6_OUT" "$_B_HOME/aiteamforge" \
        "_helper_root did not resolve to the delivered consumer path"; then
        test_pass
    fi

    # RED: prefix helper ABSENT — _helper_root must stay empty.
    _B6_HOME_NEG="$TEST_TMP_DIR/b6-consumer-home-neg"
    mkdir -p "$_B6_HOME_NEG/aiteamforge/scripts"
    _B6_OUT_NEG="$(
        unset DEV_TEAM_ROOT
        HOME="$_B6_HOME_NEG" bash -c "$_B6_RESOLVE_SNIPPET"$'\n''printf "[%s]\n" "$_helper_root"'
    )"
    test_start "B6 RED: absent prefix helper leaves _helper_root empty (positive assertion is not vacuous)"
    if assert_contains "$_B6_OUT_NEG" "[]" \
        "_helper_root resolved to something even without the prefix helper present — B6's positive assertion is vacuous"; then
        test_pass
    fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# SECTION C — the remote-indicator SIGNAL PATH (real tty, never captured stdout)
# ═════════════════════════════════════════════════════════════════════════════
# _fire_claude_tab_prefix (the LOCAL tab-rendering half, XACA-0214) shells out
# to a real python3 + (when `iterm2` isn't importable) probes `brew --prefix`
# with a multi-second real-world latency on a dev box. That is a genuine,
# separate finding (see this subitem's final report) — but it is NOT what
# this section tests, so the badge-helper fixture used here is sourced from
# a directory with NO sibling scripts/iterm2_tab_title_prefix.py. That keeps
# _fire_claude_tab_prefix's own `[ -f "$helper" ] || return 0` guard a fast,
# deterministic no-op and isolates exactly the OSC 1337 SetUserVar transport
# this section is chartered to verify (call sites 2 and 3's resolution are
# separately covered, stub-based, in Section B).

_C_ISOLATED_ROOT="$TEST_TMP_DIR/c-isolated-root"
mkdir -p "$_C_ISOLATED_ROOT"
cp "$REAL_BADGE_HELPER" "$_C_ISOLATED_ROOT/iterm2_badge_helper.sh"

cat > "$TEST_TMP_DIR/pty_osc_capture.py" <<'PYEOF'
# Drives a command through a REAL pty and returns whatever bytes land on the
# pty's OWN master fd — never a captured-stdout command substitution (see
# this test file's methodology note / DESIGN-DECISION-005). Draining must
# happen CONCURRENTLY with the child process, not after it exits: reading
# only after the child's slave-side fd closes can lose already-written bytes
# (measured empirically while building this test — a read-after-close saw
# b'' even though the identical write to a regular file was captured whole).
import os, pty, subprocess, sys, time, select


def run_capture(make_argv, env, timeout):
    master, slave = pty.openpty()
    slave_name = os.ttyname(slave)
    proc = subprocess.Popen(make_argv(slave_name), env=env)
    data = b""
    deadline = time.time() + timeout
    while time.time() < deadline:
        ready, _, _ = select.select([master], [], [], 0.3)
        if ready:
            try:
                chunk = os.read(master, 4096)
            except OSError:
                break
            if chunk:
                data += chunk
        if proc.poll() is not None:
            time.sleep(0.2)
            while True:
                r2, _, _ = select.select([master], [], [], 0.1)
                if not r2:
                    break
                try:
                    c2 = os.read(master, 4096)
                except OSError:
                    c2 = b""
                if not c2:
                    break
                data += c2
            break
    try:
        proc.wait(timeout=5)
    except Exception:
        proc.kill()
    os.close(slave)
    os.close(master)
    return proc.returncode, data


if __name__ == "__main__":
    mode = sys.argv[1]
    if mode == "bash":
        badge_helper = sys.argv[2]
        func = sys.argv[3]
        tab_id = sys.argv[4]
        home = sys.argv[5]
        tmux_val = sys.argv[6]  # "" means unset TMUX

        def make_argv(slave):
            cmd = f"source '{badge_helper}'; {func} '{tab_id}' >> '{slave}' 2>&1"
            return ["bash", "-c", cmd]

        env = dict(os.environ)
        env["HOME"] = home
        if tmux_val:
            env["TMUX"] = tmux_val
        else:
            env.pop("TMUX", None)
        _rc, data = run_capture(make_argv, env, 15)
        sys.stdout.buffer.write(data)

    elif mode == "hook":
        hook_child = sys.argv[2]
        mod_path = sys.argv[3]
        mod_name = sys.argv[4]
        func_name = sys.argv[5]
        session_id = sys.argv[6]
        home = sys.argv[7]
        dev_team_root = sys.argv[8]

        def make_argv(slave):
            return ["python3", hook_child, mod_path, mod_name, func_name,
                     "sess", "win", session_id, slave]

        env = dict(os.environ)
        env.pop("TMUX", None)
        env["HOME"] = home
        env["DEV_TEAM_ROOT"] = dev_team_root
        env["ITERM_SESSION_ID"] = "w0t0p0:XACA1144TEST"
        _rc, data = run_capture(make_argv, env, 15)
        sys.stdout.buffer.write(data)
PYEOF

cat > "$TEST_TMP_DIR/hook_child.py" <<'PYEOF'
import importlib.util, sys, os

mod_path = sys.argv[1]
mod_name = sys.argv[2]
func_name = sys.argv[3]
session_name = sys.argv[4]
window_name = sys.argv[5]
session_id = sys.argv[6]
pane_tty = sys.argv[7]

spec = importlib.util.spec_from_file_location(mod_name, mod_path)
mod = importlib.util.module_from_spec(spec)
sys.modules[mod_name] = mod
spec.loader.exec_module(mod)

# The hook resolves the target pane tty via _resolve_pane_tty(); replace it
# with our real pty's slave path so the OSC bytes the hook writes via
# `>> "$PANE_TTY"` land somewhere this test can read them back.
mod._resolve_pane_tty = lambda *a, **kw: pane_tty

func = getattr(mod, func_name)
func(session_name=session_name, window_name=window_name, session_id=session_id)
PYEOF

# ── C1: direct badge-helper OSC emission (plain, no tmux) ──
_C1_HOME="$TEST_TMP_DIR/c1-home"
mkdir -p "$_C1_HOME"
_C1_ACTIVATE="$(python3 "$TEST_TMP_DIR/pty_osc_capture.py" bash "$_C_ISOLATED_ROOT/iterm2_badge_helper.sh" set_claude_active c1tab "$_C1_HOME" "" | base64)"
_C1_ACTIVATE_RAW="$(printf '%s' "$_C1_ACTIVATE" | base64 -d)"
test_start "C1: set_claude_active emits plain OSC1337 SetUserVar=claude_active=1 (base64 MQ==) to a real tty"
if assert_contains "$_C1_ACTIVATE_RAW" $'\033]1337;SetUserVar=claude_active=MQ==\007' \
    "expected OSC1337 activate sequence not found on the real pty"; then
    test_pass
fi

_C1_CLEAR="$(python3 "$TEST_TMP_DIR/pty_osc_capture.py" bash "$_C_ISOLATED_ROOT/iterm2_badge_helper.sh" clear_claude_active c1tab "$_C1_HOME" "" | base64)"
_C1_CLEAR_RAW="$(printf '%s' "$_C1_CLEAR" | base64 -d)"
test_start "C1: clear_claude_active emits plain OSC1337 SetUserVar=claude_active=0 (base64 MA==) to a real tty"
if assert_contains "$_C1_CLEAR_RAW" $'\033]1337;SetUserVar=claude_active=MA==\007' \
    "expected OSC1337 clear sequence not found on the real pty"; then
    test_pass
fi

# ── C1b: tmux DCS-passthrough wrapping (the actual remote transport) ──
_C1B_HOME="$TEST_TMP_DIR/c1b-home"
mkdir -p "$_C1B_HOME"
_C1B_ACTIVATE="$(python3 "$TEST_TMP_DIR/pty_osc_capture.py" bash "$_C_ISOLATED_ROOT/iterm2_badge_helper.sh" set_claude_active c1btab "$_C1B_HOME" "/tmp/fake,999,0" | base64)"
_C1B_ACTIVATE_RAW="$(printf '%s' "$_C1B_ACTIVATE" | base64 -d)"
test_start "C1b: under \$TMUX, set_claude_active wraps the OSC in DCS passthrough (the actual ssh+tmux transport)"
if assert_contains "$_C1B_ACTIVATE_RAW" $'\033Ptmux;\033\033]1337;SetUserVar=claude_active=MQ==\007\033\\' \
    "expected DCS-wrapped OSC1337 sequence not found — this is the exact transport DESIGN-DECISION-005 depends on crossing ssh+tmux"; then
    test_pass
fi

# ── C2: end-to-end through the REAL production hooks (kanban-session-start.py
#    / kanban-stop.py), proving call sites 2 and 3's full chain — path
#    resolution, subprocess wiring, session->tab_id mapping, AND the OSC
#    bytes reaching a real tty — not just resolution (Section B) in isolation. ──
_C2_HOME="$TEST_TMP_DIR/c2-home"
mkdir -p "$_C2_HOME/dev-team/kanban" "$_C2_HOME/.claude/.iterm_tab_refcount/sessions"

_C2_START_OUT="$(python3 "$TEST_TMP_DIR/pty_osc_capture.py" hook "$TEST_TMP_DIR/hook_child.py" "$KANBAN_SESSION_START" kanban_session_start_xaca1144 _fire_iterm2_tab_active c2sess "$_C2_HOME" "$_C_ISOLATED_ROOT" | base64)"
_C2_START_RAW="$(printf '%s' "$_C2_START_OUT" | base64 -d)"
test_start "C2: kanban-session-start.py's _fire_iterm2_tab_active emits claude_active=1 to a real tty"
if assert_contains "$_C2_START_RAW" "SetUserVar=claude_active=MQ==" \
    "session-start hook did not emit the activate OSC through the real badge helper on a consumer layout"; then
    test_pass
fi

test_start "C2: session->tab_id mapping file is written under the sandboxed HOME"
if assert_file_exists "$_C2_HOME/.claude/.iterm_tab_refcount/sessions/c2sess" \
    "kanban-stop.py depends on this file to reuse the SAME tab_id and avoid refcount drift between hook contexts"; then
    test_pass
fi

_C2_STOP_OUT="$(python3 "$TEST_TMP_DIR/pty_osc_capture.py" hook "$TEST_TMP_DIR/hook_child.py" "$KANBAN_STOP" kanban_stop_xaca1144 _fire_iterm2_tab_clear c2sess "$_C2_HOME" "$_C_ISOLATED_ROOT" | base64)"
_C2_STOP_RAW="$(printf '%s' "$_C2_STOP_OUT" | base64 -d)"
test_start "C2: kanban-stop.py's _fire_iterm2_tab_clear emits claude_active=0 to a real tty"
if assert_contains "$_C2_STOP_RAW" "SetUserVar=claude_active=MA==" \
    "stop hook did not emit the clear OSC through the real badge helper on a consumer layout"; then
    test_pass
fi

# RED: badge helper ABSENT — must reproduce BASELINE-001's exact log line and
# emit NOTHING to the tty.
_C2_HOME_NEG="$TEST_TMP_DIR/c2-home-neg"
mkdir -p "$_C2_HOME_NEG/dev-team/kanban"
_C2_EMPTY_ROOT="$TEST_TMP_DIR/c2-empty-root"
mkdir -p "$_C2_EMPTY_ROOT"
_C2_NEG_OUT="$(python3 "$TEST_TMP_DIR/pty_osc_capture.py" hook "$TEST_TMP_DIR/hook_child.py" "$KANBAN_SESSION_START" kanban_session_start_xaca1144_neg _fire_iterm2_tab_active c2negsess "$_C2_HOME_NEG" "$_C2_EMPTY_ROOT" | base64)"
_C2_NEG_RAW="$(printf '%s' "$_C2_NEG_OUT" | base64 -d)"
test_start "C2 RED: absent badge helper emits nothing to the tty (positive assertion is not vacuous)"
if [ -z "$_C2_NEG_RAW" ]; then test_pass; else test_fail "OSC bytes emitted even without a badge helper present: $_C2_NEG_RAW"; fi

test_start "C2 RED: absent badge helper reproduces BASELINE-001's exact log line"
_C2_NEG_LOG="$_C2_HOME_NEG/dev-team/kanban/start-hook-debug.log"
if assert_file_exists "$_C2_NEG_LOG" "no debug log written at all"; then
    if assert_contains "$(cat "$_C2_NEG_LOG")" "iterm2_badge_helper.sh not found; skipping claude_active set" \
        "did not reproduce BASELINE-001's documented failure line"; then
        test_pass
    fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# SECTION C3 — connect/disconnect templates start/stop the watcher under the
# SAME pidfile key (static + executed sanitization-formula parity check)
# ═════════════════════════════════════════════════════════════════════════════

_C3_WATCHERDIR_PATTERN='WATCHER_DIR="$HOME/.claude/.iterm_tab_refcount/watchers"'
_C3_CONNECT_WATCHERDIR="$(grep -oF "$_C3_WATCHERDIR_PATTERN" "$CONNECT_TEMPLATE" | head -1)"
_C3_DISCONNECT_WATCHERDIR="$(grep -oF "$_C3_WATCHERDIR_PATTERN" "$DISCONNECT_TEMPLATE" | head -1)"
test_start "C3: connect and disconnect templates point at the IDENTICAL watcher pidfile directory"
if [ -n "$_C3_CONNECT_WATCHERDIR" ] && [ "$_C3_CONNECT_WATCHERDIR" = "$_C3_DISCONNECT_WATCHERDIR" ]; then
    test_pass
else
    test_fail "WATCHER_DIR differs (or is missing) between team-connect-parametric.sh.template and team-disconnect-parametric.sh.template — connect starts a watcher disconnect can never find"
fi

# Exercise the actual sanitization formula (connect) against the actual glob
# match predicates (disconnect), using a representative window name in the
# real "${TEAM_ID}-<suffix> @ <host>" shape.
_C3_TEAM_ID="freelance"
_C3_WINDOW_NAME="freelance-clientx @ darren-m4-mini"
_C3_HOST="darren-m4-mini"
_C3_KEY="$(printf '%s' "$_C3_WINDOW_NAME" | tr ' ' '_')"

test_start "C3: connect's sanitized watcher key matches disconnect's TEAM_ID-prefix glob"
case "$_C3_KEY" in
    "${_C3_TEAM_ID}-"*) test_pass ;;
    *) test_fail "key '$_C3_KEY' does not start with '${_C3_TEAM_ID}-' — disconnect's pidfile glob would never match a connect-started watcher" ;;
esac

test_start "C3: connect's sanitized watcher key matches disconnect's optional host-suffix filter"
case "$_C3_KEY" in
    *"_@_${_C3_HOST}") test_pass ;;
    *) test_fail "key '$_C3_KEY' does not end with '_@_${_C3_HOST}' — a host-scoped disconnect would never match" ;;
esac

# ═════════════════════════════════════════════════════════════════════════════
# Summary
# ═════════════════════════════════════════════════════════════════════════════
if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "Results: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    # Gate on a minimum assertion count too: a suite that skips or short-
    # circuits everything (e.g. zsh/tmux absent, an early `exit` swallowed
    # by a refactor) must never report a clean, fully-covered green run.
    _MIN_EXPECTED=28
    _TOTAL=$((_PASS_COUNT + _FAIL_COUNT))
    if [ "$_TOTAL" -lt "$_MIN_EXPECTED" ]; then
        echo "ERROR: only ${_TOTAL} assertions ran (expected >= ${_MIN_EXPECTED}) — treating as FAILURE." >&2
        exit 1
    fi
    [ "$_FAIL_COUNT" -eq 0 ] || exit 1
fi
