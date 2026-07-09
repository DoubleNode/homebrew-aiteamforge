#!/bin/bash
# test-xaca-0751-014-knowledge-url-resolution.sh
#
# XACA-0751-014 (EPIC-0047): ordered candidate resolution for the knowledge repo
# URL in install_knowledge_repo() / _knowledge_resolve_repo_url().
#
# The defect: XACA-0747 hard-defaulted KB_KNOWLEDGE_REPO_URL to
# git@github.com:DoubleNode/knowledge.git — a host for which no key exists on
# fleet machines. XACA-0750 issued a REPO-SCOPED ed25519 deploy key reachable
# ONLY through the `github-knowledge` SSH host alias. The two never met, so a
# fully-authorized machine (M4Mini) probed github.com, failed, and soft-skipped
# — never creating ~/knowledge, while blaming XACA-0750 (already granted).
#
# The fix: resolution now probes candidates in order —
#   1. explicit KB_KNOWLEDGE_REPO_URL (verbatim; defaults never probed)
#   2. github-knowledge deploy-key alias
#   3. plain github.com
# first reachable wins; none reachable → soft-skip (exit 0, nothing created).
#
# All cases are sandboxed: every invocation overrides HOME,
# KB_KNOWLEDGE_GLOBAL_ROOT, and the candidate URLs, pointing them at LOCAL git
# fixtures over file:// URLs (an unreachable candidate is a file:// path that
# does not exist). No network, no SSH auth, no touch of the real private repo,
# this machine's real ~/knowledge, or its global git config. The real
# github-knowledge alias / github.com hosts are never dialed.
#
# Runs standalone (`bash tests/test-xaca-0751-014-knowledge-url-resolution.sh`)
# OR via test-runner.sh (which exports test_start/test_pass/test_fail +
# TEST_TMP_DIR). Exit 0 = all pass, exit 1 = any fail.
#
# Requires: bash, git.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALLER="$TAP_ROOT/libexec/installers/install-kanban.sh"

if [ ! -f "$INSTALLER" ]; then
    echo "FATAL: install-kanban.sh not found at: $INSTALLER" >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework: no-op-compatible stubs when test-runner.sh has not
# exported the real harness.
# ─────────────────────────────────────────────────────────────────────────────
if ! type -t test_start >/dev/null 2>&1; then
    _PASS_COUNT=0
    _FAIL_COUNT=0
    _CURRENT_TEST=""
    test_start() { _CURRENT_TEST="$1"; echo "  >> $1"; }
    test_pass()  { _PASS_COUNT=$((_PASS_COUNT + 1)); echo "     PASS: $_CURRENT_TEST"; }
    test_fail()  { _FAIL_COUNT=$((_FAIL_COUNT + 1)); echo "     FAIL: $_CURRENT_TEST — $1" >&2; }
fi

# ─────────────────────────────────────────────────────────────────────────────
# Temp directory: runner-supplied TEST_TMP_DIR or our own.
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca0751-014-url.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
TEST_TMP_DIR="$(cd "$TEST_TMP_DIR" && pwd -P)"
WORK_DIR="$TEST_TMP_DIR/xaca0751-014"
mkdir -p "$WORK_DIR"

cleanup() {
    if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then
        rm -rf "$TEST_TMP_DIR"
    fi
}
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Build a "canonical knowledge repo" fixture with a distinct marker so a test can
# prove WHICH candidate was cloned. Ships a tracked .githooks/ so the post-clone
# hook wiring has something to retrofit (matches the real repo shape).
# Usage: _build_fixture <dir> <marker-text>
# ─────────────────────────────────────────────────────────────────────────────
_build_fixture() {
    local repo="$1" marker="$2"
    mkdir -p "$repo/.githooks" "$repo/agents"
    cat > "$repo/.githooks/pre-commit" <<'HOOK'
#!/bin/bash
exit 0
HOOK
    chmod +x "$repo/.githooks/pre-commit"
    printf '%s\n' "$marker" > "$repo/agents/INDEX.md"
    (
        cd "$repo"
        git init -q
        git config user.email test@example.com
        git config user.name "Test Fixture"
        git config commit.gpgsign false
        git add -A
        git -c core.hooksPath=/dev/null commit -q -m "fixture: $marker"
    )
}

# Advance a fixture with a new upstream commit (for the fast-forward guard).
_advance_fixture() {
    local repo="$1" file="$2" content="$3"
    (
        cd "$repo"
        printf '%s\n' "$content" > "$file"
        git -c core.hooksPath=/dev/null add "$file"
        git -c core.hooksPath=/dev/null commit -q -m "advance: $file"
    )
}

# Distinct fixtures so a clone's provenance is unambiguous.
ALIAS_FIX="$WORK_DIR/alias-fixture.git-src"
DIRECT_FIX="$WORK_DIR/direct-fixture.git-src"
EXPLICIT_FIX="$WORK_DIR/explicit-fixture.git-src"
_build_fixture "$ALIAS_FIX"    "ALIAS candidate marker"    || { echo "FATAL: alias fixture" >&2; exit 1; }
_build_fixture "$DIRECT_FIX"   "DIRECT candidate marker"   || { echo "FATAL: direct fixture" >&2; exit 1; }
_build_fixture "$EXPLICIT_FIX" "EXPLICIT candidate marker" || { echo "FATAL: explicit fixture" >&2; exit 1; }

ALIAS_URL="file://$ALIAS_FIX"
DIRECT_URL="file://$DIRECT_FIX"
EXPLICIT_URL="file://$EXPLICIT_FIX"
# An "unreachable" candidate is a file:// path to a repo that does not exist —
# git ls-remote --exit-code fails fast, exactly as an unauthorized SSH host would.
BOGUS_ALIAS="file://$WORK_DIR/no-such-alias-repo.git"
BOGUS_DIRECT="file://$WORK_DIR/no-such-direct-repo.git"

# ─────────────────────────────────────────────────────────────────────────────
# Run install_knowledge_repo() in a sandboxed bash subshell.
# Usage: _run <home> <root> <explicit_url> <alias_url> <direct_url> [<dry_run>]
# An EMPTY explicit_url ("") models KB_KNOWLEDGE_REPO_URL being unset (the
# candidate resolver treats empty as unset), so the alias/direct defaults drive.
# Echoes the subshell exit code on stdout.
# ─────────────────────────────────────────────────────────────────────────────
R_STDOUT="$WORK_DIR/r-stdout.txt"
R_STDERR="$WORK_DIR/r-stderr.txt"
_run() {
    local home_dir="$1" global_root="$2" explicit_url="$3"
    local alias_url="$4" direct_url="$5" dry_run="${6:-false}"
    (
        set -euo pipefail
        export INSTALL_ROOT="$TAP_ROOT"
        export AITEAMFORGE_HOME="$TAP_ROOT"
        export AITEAMFORGE_DIR="$home_dir/aiteamforge"
        export HOME="$home_dir"
        export KB_KNOWLEDGE_GLOBAL_ROOT="$global_root"
        export KB_KNOWLEDGE_REPO_URL="$explicit_url"
        export KB_KNOWLEDGE_REPO_URL_ALIAS="$alias_url"
        export KB_KNOWLEDGE_REPO_URL_DIRECT="$direct_url"
        export DRY_RUN="$dry_run"
        export TEAM_WORKING_DIRS_STR=""
        export KANBAN_BACKUP_INTERVAL=900
        mkdir -p "$AITEAMFORGE_DIR"
        # git inside the sandbox must not inherit this machine's identity/templateDir.
        export GIT_CONFIG_GLOBAL="$home_dir/.gitconfig"
        git config --file "$GIT_CONFIG_GLOBAL" user.email test@example.com
        git config --file "$GIT_CONFIG_GLOBAL" user.name "Sandbox"
        source "$INSTALLER" >"$R_STDOUT" 2>"$R_STDERR"
        install_knowledge_repo >>"$R_STDOUT" 2>>"$R_STDERR"
    )
    echo $?
}
_r_out() { cat "$R_STDOUT" 2>/dev/null; }
_next_home() { mktemp -d "$WORK_DIR/home-XXXXXX"; }
_marker() { cat "$1/agents/INDEX.md" 2>/dev/null; }

# ═══════════════════════════════════════════════════════════════════════════
# C1 — alias reachable → alias URL chosen (THE M4Mini REGRESSION TEST)
# KB_KNOWLEDGE_REPO_URL unset; alias reachable, direct unreachable.
# ═══════════════════════════════════════════════════════════════════════════
test_start "C1: alias reachable → clones from the github-knowledge alias (M4Mini regression)"
C1_HOME=$(_next_home); C1_ROOT="$C1_HOME/knowledge"
C1_RC=$(_run "$C1_HOME" "$C1_ROOT" "" "$ALIAS_URL" "$BOGUS_DIRECT" false)
if [ "$C1_RC" = "0" ] && [ -d "$C1_ROOT/.git" ] \
    && [ "$(_marker "$C1_ROOT")" = "ALIAS candidate marker" ]; then
    test_pass
else
    test_fail "rc=$C1_RC has_git=$([ -d "$C1_ROOT/.git" ] && echo y || echo n) marker='$(_marker "$C1_ROOT")'; stderr=$(tail -3 "$R_STDERR" 2>/dev/null)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# C2 — alias unreachable, github.com reachable → falls back to github.com
# ═══════════════════════════════════════════════════════════════════════════
test_start "C2: alias unreachable → falls back to plain github.com candidate"
C2_HOME=$(_next_home); C2_ROOT="$C2_HOME/knowledge"
C2_RC=$(_run "$C2_HOME" "$C2_ROOT" "" "$BOGUS_ALIAS" "$DIRECT_URL" false)
if [ "$C2_RC" = "0" ] && [ -d "$C2_ROOT/.git" ] \
    && [ "$(_marker "$C2_ROOT")" = "DIRECT candidate marker" ]; then
    test_pass
else
    test_fail "rc=$C2_RC has_git=$([ -d "$C2_ROOT/.git" ] && echo y || echo n) marker='$(_marker "$C2_ROOT")'; stderr=$(tail -3 "$R_STDERR" 2>/dev/null)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# C3 — neither reachable → soft-skip, exit 0, nothing created (M1Pro case)
# ═══════════════════════════════════════════════════════════════════════════
test_start "C3: neither candidate reachable → soft-skip, exit 0, no ~/knowledge (M1Pro case)"
C3_HOME=$(_next_home); C3_ROOT="$C3_HOME/knowledge"
C3_RC=$(_run "$C3_HOME" "$C3_ROOT" "" "$BOGUS_ALIAS" "$BOGUS_DIRECT" false)
C3_OUT="$(_r_out)"
if [ "$C3_RC" = "0" ] && [ ! -e "$C3_ROOT" ] \
    && echo "$C3_OUT" | grep -qi "unreachable"; then
    test_pass
else
    test_fail "rc=$C3_RC root_exists=$([ -e "$C3_ROOT" ] && echo y || echo n); out_tail=$(echo "$C3_OUT" | tail -3)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# C4 — explicit KB_KNOWLEDGE_REPO_URL wins verbatim; candidates NOT probed.
# Explicit points at EXPLICIT_FIX; alias ALSO reachable (would win if probed) —
# assert the clone provenance is the EXPLICIT fixture, proving no candidate probe.
# ═══════════════════════════════════════════════════════════════════════════
test_start "C4: explicit KB_KNOWLEDGE_REPO_URL used verbatim, defaults never probed"
C4_HOME=$(_next_home); C4_ROOT="$C4_HOME/knowledge"
C4_RC=$(_run "$C4_HOME" "$C4_ROOT" "$EXPLICIT_URL" "$ALIAS_URL" "$DIRECT_URL" false)
if [ "$C4_RC" = "0" ] && [ -d "$C4_ROOT/.git" ] \
    && [ "$(_marker "$C4_ROOT")" = "EXPLICIT candidate marker" ]; then
    test_pass
else
    test_fail "rc=$C4_RC marker='$(_marker "$C4_ROOT")' (expected EXPLICIT); stderr=$(tail -3 "$R_STDERR" 2>/dev/null)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# C5 — existing healthy clone → fast-forward; remote URL NOT rewritten.
# THE M3Pro REGRESSION GUARD: clone from EXPLICIT_FIX, advance it, then re-run
# with NO explicit URL and alias/direct pointing at DIFFERENT reachable fixtures.
# State 1 must fetch the clone's OWN origin (EXPLICIT_FIX), fast-forward, and
# leave `git remote get-url origin` pointing at EXPLICIT_FIX — never at a
# candidate, never re-cloned.
# ═══════════════════════════════════════════════════════════════════════════
test_start "C5: existing clone fast-forwards; origin URL NOT rewritten (M3Pro guard)"
C5_HOME=$(_next_home); C5_ROOT="$C5_HOME/knowledge"
C5_ORIGIN_FIX="$WORK_DIR/c5-origin.git-src"
_build_fixture "$C5_ORIGIN_FIX" "C5 origin marker" || { echo "FATAL: c5 fixture" >&2; exit 1; }
C5_ORIGIN_URL="file://$C5_ORIGIN_FIX"
# Seed the clone via an explicit URL run.
C5_RC0=$(_run "$C5_HOME" "$C5_ROOT" "$C5_ORIGIN_URL" "$BOGUS_ALIAS" "$BOGUS_DIRECT" false)
# Drop a local-only marker (a re-clone would destroy it) and advance upstream.
echo "local-work-do-not-clobber" > "$C5_ROOT/LOCAL_MARKER"
_advance_fixture "$C5_ORIGIN_FIX" "UPSTREAM_NEW.md" "c5 upstream advance"
# Re-run with NO explicit URL and candidates pointing at OTHER reachable fixtures.
C5_RC=$(_run "$C5_HOME" "$C5_ROOT" "" "$ALIAS_URL" "$DIRECT_URL" false)
C5_OUT="$(_r_out)"
C5_ORIGIN_NOW=$(git -C "$C5_ROOT" remote get-url origin 2>/dev/null)
if [ "$C5_RC0" = "0" ] && [ "$C5_RC" = "0" ] \
    && [ -f "$C5_ROOT/LOCAL_MARKER" ] \
    && [ -f "$C5_ROOT/UPSTREAM_NEW.md" ] \
    && [ "$C5_ORIGIN_NOW" = "$C5_ORIGIN_URL" ] \
    && [ "$(_marker "$C5_ROOT")" = "C5 origin marker" ] \
    && echo "$C5_OUT" | grep -qi "already present"; then
    test_pass
else
    test_fail "rc0=$C5_RC0 rc=$C5_RC local=$([ -f "$C5_ROOT/LOCAL_MARKER" ] && echo kept || echo LOST) ff=$([ -f "$C5_ROOT/UPSTREAM_NEW.md" ] && echo y || echo n) origin='$C5_ORIGIN_NOW' (expected '$C5_ORIGIN_URL') marker='$(_marker "$C5_ROOT")'"
fi

# ═══════════════════════════════════════════════════════════════════════════
# C6 — --dry-run: no filesystem change, no clone, even with a reachable alias.
# ═══════════════════════════════════════════════════════════════════════════
test_start "C6: DRY_RUN=true creates nothing (no root) even with reachable alias"
C6_HOME=$(_next_home); C6_ROOT="$C6_HOME/knowledge"
C6_RC=$(_run "$C6_HOME" "$C6_ROOT" "" "$ALIAS_URL" "$DIRECT_URL" true)
if [ "$C6_RC" = "0" ] && [ ! -e "$C6_ROOT" ]; then
    test_pass
else
    test_fail "rc=$C6_RC; expected $C6_ROOT absent; $([ -e "$C6_ROOT" ] && find "$C6_ROOT" -maxdepth 1)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# C7 — soft-skip message NAMES both attempted candidate URLs (unset explicit).
# Diagnostics fix: instead of "not yet authorized" (a ticket state), report the
# alias and github.com URLs actually tried.
# ═══════════════════════════════════════════════════════════════════════════
test_start "C7: soft-skip diagnostic names BOTH attempted candidate URLs"
C7_HOME=$(_next_home); C7_ROOT="$C7_HOME/knowledge"
C7_RC=$(_run "$C7_HOME" "$C7_ROOT" "" "$BOGUS_ALIAS" "$BOGUS_DIRECT" false)
C7_OUT="$(_r_out)"
if [ "$C7_RC" = "0" ] \
    && echo "$C7_OUT" | grep -qi "github-knowledge" \
    && echo "$C7_OUT" | grep -q "$BOGUS_ALIAS" \
    && echo "$C7_OUT" | grep -q "$BOGUS_DIRECT" \
    && echo "$C7_OUT" | grep -q "KB_KNOWLEDGE_REPO_URL"; then
    test_pass
else
    test_fail "rc=$C7_RC; message must name alias+direct URLs and the KB_KNOWLEDGE_REPO_URL escape hatch; out_tail=$(echo "$C7_OUT" | tail -4)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# C8 — soft-skip message when explicit URL was set names THAT var, and says the
# defaults were NOT tried (so an operator override isn't misdiagnosed as fleet auth).
# ═══════════════════════════════════════════════════════════════════════════
test_start "C8: soft-skip names the explicit KB_KNOWLEDGE_REPO_URL when it was the (failed) candidate"
C8_HOME=$(_next_home); C8_ROOT="$C8_HOME/knowledge"
C8_RC=$(_run "$C8_HOME" "$C8_ROOT" "$BOGUS_DIRECT" "$ALIAS_URL" "$DIRECT_URL" false)
C8_OUT="$(_r_out)"
if [ "$C8_RC" = "0" ] && [ ! -e "$C8_ROOT" ] \
    && echo "$C8_OUT" | grep -q "KB_KNOWLEDGE_REPO_URL" \
    && echo "$C8_OUT" | grep -q "$BOGUS_DIRECT"; then
    test_pass
else
    test_fail "rc=$C8_RC root_exists=$([ -e "$C8_ROOT" ] && echo y || echo n); out_tail=$(echo "$C8_OUT" | tail -4)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Standalone summary + exit code (no-op under test-runner.sh, which owns totals)
# ═══════════════════════════════════════════════════════════════════════════
if [ -n "${_PASS_COUNT+x}" ]; then
    echo ""
    echo "XACA-0751-014 knowledge-url-resolution tests: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    [ "${_FAIL_COUNT:-0}" -eq 0 ] || exit 1
fi
exit 0
