#!/bin/bash

# test-xaca-1143-worktree-helpers-materialize.sh
# Regression test for XACA-1143: update_aux_scripts() can never CREATE
# $AITEAMFORGE_DIR/worktree-helpers.sh on upgrade — only refresh it.
#
# REGRESSION INTENT: share/templates/aiteamforge-env.sh sources
# "$AITEAMFORGE_DIR/worktree-helpers.sh" behind an `[ -f ]` guard, and
# worktree-aliases.sh prints "✓ Worktree helpers loaded" immediately before
# that guarded source line — so a shell can announce a successful load that
# never happened. worktree-helpers.sh IS already listed in
# _xaca0608_aux_script_map (root-destined: "worktree-helpers.sh|${WORKING_DIR}/worktree-helpers.sh"),
# but update_aux_scripts()'s loop guards EVERY entry with
# `[ ! -f "$target" ] && continue` before it ever reaches the refresh-or-create
# decision — so a machine that never had this file at the root (never
# installed, or installed before XACA-0594 added the entry) can NEVER get it
# from `aiteamforge upgrade`, no matter how many upgrades run. wt-dev and
# every other wt-* function silently stay undefined.
#
# Assertions:
#   1. Simulated upgrade from a state where $AITEAMFORGE_DIR/worktree-helpers.sh
#      is ABSENT: after update_aux_scripts() runs, the file MUST exist.
#   2. Materialised copy still passes the ~/dev-team -> WORKING_DIR rewrite
#      (proves it went through the rewrite-aware render, not a bypass cp).
#   3. Materialised copy retains its exec bit.
#   4. wt-dev resolves in a real interactive shell that sources the
#      materialised file via the SAME guarded pattern aiteamforge-env.sh uses
#      — checked under `zsh -ic` (interactive, non-login). NEVER `zsh -lc`:
#      -l is login-but-non-interactive and never sources .zshrc, so a -lc
#      check can never fail regardless of what ships (see EPIC-0056 false
#      BLOCKED / XACA-1137 correction).
#   5. The pre-existing scripts/-destined aux entries (e.g. kb-cr.sh) are
#      UNAFFECTED by the fix — still refresh-only-if-present, not
#      materialised. worktree-helpers.sh is the odd one out precisely
#      because it is root-destined, not scripts/-destined.
#
# All filesystem activity is sandboxed to TEST_TMP_DIR / a private ZDOTDIR.
# NEVER touches real $HOME / ~/.zshrc / ~/.aiteamforge — installer-test safety rule.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UPGRADE_SH="$TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh"
REAL_WT_HELPERS_SRC="$TAP_ROOT/share/scripts/worktree-helpers.sh"

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework: works both as a sourced test-runner.sh file AND as a
# directly-invoked script (mirrors test-xaca-0608 pattern).
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

if ! type -t assert_not_contains >/dev/null 2>&1; then
    assert_not_contains() {
        local haystack="$1" needle="$2" msg="${3:-Expected NOT to find '$2' in string}"
        [[ "$haystack" != *"$needle"* ]] || { test_fail "$msg"; return 1; }
    }
fi

for _p in print_section print_info print_success print_warning print_error; do
    if ! declare -f "$_p" >/dev/null 2>&1; then
        eval "${_p}() { :; }"
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Temp directory: use the runner-supplied TEST_TMP_DIR or create our own.
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca1143-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi

cleanup() {
    if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then
        rm -rf "$TEST_TMP_DIR"
    fi
}
trap cleanup EXIT

if [ ! -f "$REAL_WT_HELPERS_SRC" ]; then
    test_start "Sanity: share/scripts/worktree-helpers.sh ships in the tap"
    test_fail "not found at $REAL_WT_HELPERS_SRC"
    if [ "$_STANDALONE" = true ]; then echo "Results: ${_PASS_COUNT} passed, $((_FAIL_COUNT + 1)) failed"; fi
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Extract _xaca0608_render_team_script, _xaca0608_aux_script_map, and
# update_aux_scripts from upgrade.sh, rather than sourcing the whole script
# (which has side effects: is_configured, get_framework_dir, etc.).
# ─────────────────────────────────────────────────────────────────────────────
_extract_fn() {
    awk -v fn="$1" '
      $0 ~ ("^" fn "\\(\\) \\{") { capture=1 }
      capture { print }
      capture && /^}$/ { exit }
    ' "$UPGRADE_SH"
}

for _fn in _xaca0608_render_team_script _xaca0608_aux_script_map _xaca1143_aux_mandatory_materialize_basenames update_aux_scripts; do
    _src="$(_extract_fn "$_fn")"
    if [ -z "$_src" ]; then
        test_start "Sanity: can extract $_fn from upgrade.sh"
        test_fail "awk returned empty"
        if [ "$_STANDALONE" = true ]; then echo "Results: ${_PASS_COUNT} passed, $((_FAIL_COUNT + 1)) failed"; fi
        exit 1
    fi
    eval "$_src"
    declare -f "$_fn" >/dev/null || { echo "FATAL: $_fn not defined after extraction"; exit 1; }
done

# ─────────────────────────────────────────────────────────────────────────────
# Sandbox: a fake FRAMEWORK_DIR (tap Cellar stand-in, ships the REAL
# worktree-helpers.sh source so the rewrite is meaningful) and a fake
# WORKING_DIR (AITEAMFORGE_DIR stand-in) that starts WITHOUT
# worktree-helpers.sh — this is the precondition the ticket names: "a state
# where it is ABSENT".
# ─────────────────────────────────────────────────────────────────────────────
FRAMEWORK_DIR="$TEST_TMP_DIR/framework"
WORKING_DIR="$TEST_TMP_DIR/aiteamforge"
mkdir -p "$FRAMEWORK_DIR/share/scripts" "$WORKING_DIR/scripts"
cp "$REAL_WT_HELPERS_SRC" "$FRAMEWORK_DIR/share/scripts/worktree-helpers.sh"

# Give the sandbox at least one OTHER already-installed aux target so we can
# also prove update_aux_scripts' existing refresh-if-present behavior for
# scripts/-destined entries is untouched by this fix (assertion 5).
printf '#!/bin/bash\n# PRE-EXISTING-KB-CR-SENTINEL\n' > "$WORKING_DIR/scripts/kb-cr.sh"
chmod +x "$WORKING_DIR/scripts/kb-cr.sh"
if [ -f "$FRAMEWORK_DIR/share/scripts/kb-cr.sh" ]; then :; else
    printf '#!/bin/bash\n# updated kb-cr\n' > "$FRAMEWORK_DIR/share/scripts/kb-cr.sh"
fi
touch -t 203001010000 "$FRAMEWORK_DIR/share/scripts/kb-cr.sh" 2>/dev/null || true

# XACA-1143-009 (review finding, PR #848): the negative control for assertion 5
# MUST have its framework source in place BEFORE the single update_aux_scripts()
# call below, or that entry never reaches the mandatory-check logic at all and
# the assertion passes no matter what the fix does. Verified vacuous as
# originally written: adding cellar-watch-trigger.sh to the mandatory list —
# i.e. manufacturing the exact over-materialize bug assertion 5 exists to
# catch — still produced 6/6 GREEN. A control that cannot fail is not a control.
printf '#!/bin/bash\n# framework cellar-watch-trigger\n' > "$FRAMEWORK_DIR/share/scripts/cellar-watch-trigger.sh"

WT_TARGET="$WORKING_DIR/worktree-helpers.sh"

test_start "Sanity: sandbox precondition — $WT_TARGET is ABSENT before upgrade"
if assert_file_not_exists "$WT_TARGET" \
    "Test setup bug: worktree-helpers.sh must NOT pre-exist at WORKING_DIR root"; then
    test_pass
fi

# ── TEST 1 (the RED-before-fix assertion): materialise on upgrade even when absent ──
test_start "update_aux_scripts() materialises worktree-helpers.sh at WORKING_DIR root when previously ABSENT"
FORCE=false DRY_RUN=false update_aux_scripts >/dev/null 2>&1
if assert_file_exists "$WT_TARGET" \
    "worktree-helpers.sh was never created — update_aux_scripts()'s per-entry '[ ! -f \$target ] && continue' guard skips every entry that is not already installed, so a machine that never had this file at the root can never get it from 'aiteamforge upgrade'"; then
    test_pass
fi

# ── TEST 2: materialised copy went through the rewrite-aware render ──
test_start "Materialised worktree-helpers.sh has ~/dev-team rewritten to WORKING_DIR (rewrite-aware render, not a bypass cp)"
if [ -f "$WT_TARGET" ]; then
    WT_CONTENT="$(cat "$WT_TARGET")"
    if assert_not_contains "$WT_CONTENT" '$HOME/dev-team' \
        "Materialised worktree-helpers.sh must not retain a literal \$HOME/dev-team reference"; then
        if assert_contains "$WT_CONTENT" "$WORKING_DIR" \
            "Materialised worktree-helpers.sh must reference the WORKING_DIR base after rewrite"; then
            test_pass
        fi
    fi
else
    test_fail "worktree-helpers.sh missing — cannot check rewrite (see TEST 1)"
fi

# ── TEST 3: materialised copy keeps its exec bit ──
test_start "Materialised worktree-helpers.sh retains exec bit"
if [ -f "$WT_TARGET" ] && [ -x "$WT_TARGET" ]; then
    test_pass
else
    test_fail "worktree-helpers.sh is not executable (or missing)"
fi

# ── TEST 4: the actual shell-acceptance check — wt-dev resolves under a REAL
# interactive zsh that sources the materialised file through the SAME
# guarded pattern aiteamforge-env.sh uses. Sandboxed via a private ZDOTDIR —
# never touches the real ~/.zshrc. MUST use zsh -ic, never zsh -lc (a -lc
# probe never sources .zshrc and can never fail regardless of what ships —
# see EPIC-0056 / XACA-1137). ──
test_start "wt-dev resolves under 'zsh -ic' after sourcing the materialised worktree-helpers.sh"
if command -v zsh >/dev/null 2>&1; then
    ZDOT_SANDBOX="$TEST_TMP_DIR/zdotdir"
    mkdir -p "$ZDOT_SANDBOX"
    # Mirrors share/templates/aiteamforge-env.sh's actual guarded source line
    # verbatim (AITEAMFORGE_DIR substituted to our sandbox WORKING_DIR).
    cat > "$ZDOT_SANDBOX/.zshrc" <<EOF
AITEAMFORGE_DIR="$WORKING_DIR"
if [ -f "\$AITEAMFORGE_DIR/worktree-helpers.sh" ]; then
    source "\$AITEAMFORGE_DIR/worktree-helpers.sh"
fi
EOF
    WT_DEV_CHECK="$(ZDOTDIR="$ZDOT_SANDBOX" HOME="$TEST_TMP_DIR" zsh -ic 'typeset -f wt-dev >/dev/null 2>&1 && echo WT_DEV_FOUND || echo WT_DEV_MISSING' 2>/dev/null)"
    if assert_contains "$WT_DEV_CHECK" "WT_DEV_FOUND" \
        "wt-dev did not resolve under zsh -ic (got: '$WT_DEV_CHECK') — the guarded source in aiteamforge-env.sh silently no-ops when worktree-helpers.sh is absent"; then
        test_pass
    fi
else
    test_fail "zsh not found on this machine — cannot run the shell-acceptance check (this is an environment problem, not a pass)"
fi

# ── TEST 5: pre-existing scripts/-destined aux behavior is unaffected —
# still refresh-only-if-present (no over-eager materialize creep). Uses
# cellar-watch-trigger.sh: a genuine scripts/-destined aux entry
# ("cellar-watch-trigger.sh|${WORKING_DIR}/scripts/cellar-watch-trigger.sh")
# that is NOT worktree-helpers.sh and must NOT be swept onto the new
# mandatory-materialize list this fix adds. ──
test_start "update_aux_scripts() still leaves an un-installed scripts/-destined aux entry absent (no over-materialize)"
UNINSTALLED_PROBE="$WORKING_DIR/scripts/cellar-watch-trigger.sh"
if assert_file_not_exists "$UNINSTALLED_PROBE" \
    "cellar-watch-trigger.sh must stay absent — it was never installed on this sandboxed machine and is not on the mandatory-materialize allowlist"; then
    test_pass
fi

if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "Results: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    [ "$_FAIL_COUNT" -eq 0 ] || exit 1
fi
