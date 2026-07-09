#!/bin/bash
# test-xaca-0747-knowledge-repo.sh
#
# XACA-0747 (EPIC-0047): install_knowledge_repo() turns an empty/absent/husk
# ~/knowledge into a REAL git clone of the canonical knowledge repo, handles the
# M1Pro pre-XACA-0222 husk (move aside, never delete), soft-skips when the fleet
# is not yet authorized to reach the repo (XACA-0750 gate), updates an existing
# clone in place instead of re-cloning, wires the zero-touch frontmatter
# pre-commit gate, and honors DRY_RUN.
#
# All cases are sandboxed: every invocation overrides HOME, KB_KNOWLEDGE_GLOBAL_
# ROOT, and KB_KNOWLEDGE_REPO_URL. The "canonical repo" is a LOCAL git fixture
# served over a file:// URL — no network, no SSH auth, no touch of the real
# private repo or this machine's real ~/knowledge / global git config.
#
# Runs standalone (`bash tests/test-xaca-0747-knowledge-repo.sh`) OR via
# test-runner.sh (which exports test_start/test_pass/test_fail + TEST_TMP_DIR).
# Exit 0 = all pass, exit 1 = any fail.
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
# exported the real harness (mirrors test-xaca-0743-four-tier-knowledge.sh).
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
    TEST_TMP_DIR="$(mktemp -d -t xaca0747-knowledge-repo.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
TEST_TMP_DIR="$(cd "$TEST_TMP_DIR" && pwd -P)"
WORK_DIR="$TEST_TMP_DIR/xaca0747"
mkdir -p "$WORK_DIR"

cleanup() {
    if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then
        rm -rf "$TEST_TMP_DIR"
    fi
}
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Build the "canonical knowledge repo" fixture: a real git repo shipping a
# tracked .githooks/ (frontmatter pre-commit + setup-global-hooks dispatcher
# installer) plus a marker file, served to install_knowledge_repo() over a
# file:// URL.
# ─────────────────────────────────────────────────────────────────────────────
FIXTURE_REPO="$WORK_DIR/knowledge-fixture.git-src"
mkdir -p "$FIXTURE_REPO/.githooks" "$FIXTURE_REPO/agents"
cat > "$FIXTURE_REPO/.githooks/pre-commit" <<'HOOK'
#!/bin/bash
# fixture frontmatter gate (no-op for the test — presence + executability is what
# install_knowledge_repo verifies)
exit 0
HOOK
chmod +x "$FIXTURE_REPO/.githooks/pre-commit"
# Minimal faithful copy of the real repo's dispatcher installer: writes a
# dispatcher into $HOME/.git-templates/hooks and sets init.templateDir.
cat > "$FIXTURE_REPO/.githooks/setup-global-hooks.sh" <<'SETUP'
#!/bin/bash
set -eu
TEMPLATE_DIR="${GIT_HOOK_TEMPLATE_DIR:-$HOME/.git-templates}"
HOOKS_DIR="$TEMPLATE_DIR/hooks"
mkdir -p "$HOOKS_DIR"
for name in pre-commit pre-push commit-msg; do
  cat > "$HOOKS_DIR/$name" <<'DISP'
#!/bin/bash
set -eu
root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
hook="${root}/.githooks/$(basename "$0")"
[ -x "$hook" ] || exit 0
exec "$hook" "$@"
DISP
  chmod +x "$HOOKS_DIR/$name"
done
CURRENT=$(git config --global --get init.templateDir 2>/dev/null || true)
if [ -z "$CURRENT" ] || [ "$CURRENT" = "$TEMPLATE_DIR" ]; then
  git config --global init.templateDir "$TEMPLATE_DIR"
fi
SETUP
chmod +x "$FIXTURE_REPO/.githooks/setup-global-hooks.sh"
echo "canonical knowledge repo marker" > "$FIXTURE_REPO/agents/INDEX.md"

(
    cd "$FIXTURE_REPO"
    git init -q
    git config user.email test@example.com
    git config user.name "Test Fixture"
    git config commit.gpgsign false
    git add -A
    git -c core.hooksPath=/dev/null commit -q -m "fixture: canonical knowledge repo"
) || { echo "FATAL: could not build fixture repo" >&2; exit 1; }

FIXTURE_URL="file://$FIXTURE_REPO"
BOGUS_URL="file://$WORK_DIR/nonexistent-unauthorized-repo.git"

# ─────────────────────────────────────────────────────────────────────────────
# Run install_knowledge_repo() in a sandboxed bash subshell.
# Usage: _run_repo <home_dir> <global_root> <repo_url> [<dry_run>]
# Echoes the subshell exit code on stdout.
# ─────────────────────────────────────────────────────────────────────────────
R_STDOUT="$WORK_DIR/r-stdout.txt"
R_STDERR="$WORK_DIR/r-stderr.txt"
_run_repo() {
    local home_dir="$1" global_root="$2" repo_url="$3" dry_run="${4:-false}"
    (
        set -euo pipefail
        export INSTALL_ROOT="$TAP_ROOT"
        export AITEAMFORGE_HOME="$TAP_ROOT"
        export AITEAMFORGE_DIR="$home_dir/aiteamforge"
        export HOME="$home_dir"
        export KB_KNOWLEDGE_GLOBAL_ROOT="$global_root"
        export KB_KNOWLEDGE_REPO_URL="$repo_url"
        export DRY_RUN="$dry_run"
        export TEAM_WORKING_DIRS_STR=""
        export KANBAN_BACKUP_INTERVAL=900
        mkdir -p "$AITEAMFORGE_DIR"
        # git inside the sandbox must not inherit this machine's identity/templateDir
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

# ═══════════════════════════════════════════════════════════════════════════
# T1 — fresh machine (root absent) + reachable remote → clone lands
# ═══════════════════════════════════════════════════════════════════════════
test_start "T1: fresh machine + reachable remote clones the knowledge repo"
T1_HOME=$(_next_home); T1_ROOT="$T1_HOME/knowledge"
T1_RC=$(_run_repo "$T1_HOME" "$T1_ROOT" "$FIXTURE_URL" false)
if [ "$T1_RC" = "0" ] && [ -d "$T1_ROOT/.git" ] \
    && grep -q "canonical knowledge repo marker" "$T1_ROOT/agents/INDEX.md" 2>/dev/null; then
    test_pass
else
    test_fail "rc=$T1_RC has_git=$([ -d "$T1_ROOT/.git" ] && echo y || echo n); stderr=$(cat "$R_STDERR" 2>/dev/null | tail -3)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T2 — idempotent: re-run over an existing clone updates in place, never re-clones
# ═══════════════════════════════════════════════════════════════════════════
test_start "T2: re-run over existing clone does not re-clone (local marker preserved)"
# Drop a local-only marker; a re-clone would destroy it.
echo "local-work-do-not-clobber" > "$T1_ROOT/LOCAL_MARKER"
T2_RC=$(_run_repo "$T1_HOME" "$T1_ROOT" "$FIXTURE_URL" false)
T2_OUT="$(_r_out)"
if [ "$T2_RC" = "0" ] && [ -f "$T1_ROOT/LOCAL_MARKER" ] \
    && echo "$T2_OUT" | grep -qi "already present"; then
    test_pass
else
    test_fail "rc=$T2_RC marker=$([ -f "$T1_ROOT/LOCAL_MARKER" ] && echo kept || echo LOST); out_tail=$(echo "$T2_OUT" | tail -3)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T3 — M1Pro husk (root exists, no .git) + reachable → moved aside, clone lands
# ═══════════════════════════════════════════════════════════════════════════
test_start "T3: pre-existing non-git husk is moved aside (not deleted) then cloned"
T3_HOME=$(_next_home); T3_ROOT="$T3_HOME/knowledge"
mkdir -p "$T3_ROOT/agents/quark"
echo "old husk content" > "$T3_ROOT/agents/quark/INDEX.md"
T3_RC=$(_run_repo "$T3_HOME" "$T3_ROOT" "$FIXTURE_URL" false)
# The husk backup is $root.husk-bak-<ts>; find it by glob.
T3_BACKUP=$(ls -d "$T3_ROOT".husk-bak-* 2>/dev/null | head -1)
if [ "$T3_RC" = "0" ] && [ -d "$T3_ROOT/.git" ] \
    && [ -n "$T3_BACKUP" ] \
    && grep -q "old husk content" "$T3_BACKUP/agents/quark/INDEX.md" 2>/dev/null; then
    test_pass
else
    test_fail "rc=$T3_RC has_git=$([ -d "$T3_ROOT/.git" ] && echo y || echo n) backup='${T3_BACKUP:-none}'; stderr=$(cat "$R_STDERR" 2>/dev/null | tail -3)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T4 — auth gate: unreachable remote, no pre-existing root → soft-skip, exit 0
# ═══════════════════════════════════════════════════════════════════════════
test_start "T4: unreachable remote soft-skips (no root created, exit 0)"
T4_HOME=$(_next_home); T4_ROOT="$T4_HOME/knowledge"
T4_RC=$(_run_repo "$T4_HOME" "$T4_ROOT" "$BOGUS_URL" false)
T4_OUT="$(_r_out)"
# XACA-0751-014: soft-skip message now NAMES the attempted URL instead of
# asserting "not yet authorized" (a ticket state the installer can't know). With
# an explicit KB_KNOWLEDGE_REPO_URL set, the message reports that var unreachable.
if [ "$T4_RC" = "0" ] && [ ! -e "$T4_ROOT" ] \
    && echo "$T4_OUT" | grep -qi "unreachable" \
    && echo "$T4_OUT" | grep -q "$BOGUS_URL"; then
    test_pass
else
    test_fail "rc=$T4_RC root_exists=$([ -e "$T4_ROOT" ] && echo y || echo n); out_tail=$(echo "$T4_OUT" | tail -3)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T5 — auth gate with husk present: husk left in place (NOT moved), exit 0
# ═══════════════════════════════════════════════════════════════════════════
test_start "T5: unreachable remote leaves an existing husk untouched (no pointless move-aside)"
T5_HOME=$(_next_home); T5_ROOT="$T5_HOME/knowledge"
mkdir -p "$T5_ROOT/agents/quark"
echo "husk stays" > "$T5_ROOT/agents/quark/INDEX.md"
T5_RC=$(_run_repo "$T5_HOME" "$T5_ROOT" "$BOGUS_URL" false)
T5_MOVED=$(ls -d "$T5_ROOT".husk-bak-* 2>/dev/null | head -1)
if [ "$T5_RC" = "0" ] && [ -f "$T5_ROOT/agents/quark/INDEX.md" ] \
    && grep -q "husk stays" "$T5_ROOT/agents/quark/INDEX.md" 2>/dev/null \
    && [ -z "$T5_MOVED" ]; then
    test_pass
else
    test_fail "rc=$T5_RC husk_in_place=$([ -f "$T5_ROOT/agents/quark/INDEX.md" ] && echo y || echo n) moved='${T5_MOVED:-none}'"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T6 — DRY_RUN=true creates nothing
# ═══════════════════════════════════════════════════════════════════════════
test_start "T6: DRY_RUN=true clones nothing (no root created)"
T6_HOME=$(_next_home); T6_ROOT="$T6_HOME/knowledge"
T6_RC=$(_run_repo "$T6_HOME" "$T6_ROOT" "$FIXTURE_URL" true)
if [ "$T6_RC" = "0" ] && [ ! -e "$T6_ROOT" ]; then
    test_pass
else
    test_fail "rc=$T6_RC; expected $T6_ROOT absent; $([ -e "$T6_ROOT" ] && find "$T6_ROOT" -maxdepth 1)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T7 — zero-touch hook: after a clone the frontmatter pre-commit gate is live
# ═══════════════════════════════════════════════════════════════════════════
test_start "T7: frontmatter pre-commit gate is wired after clone"
T7_HOME=$(_next_home); T7_ROOT="$T7_HOME/knowledge"
T7_RC=$(_run_repo "$T7_HOME" "$T7_ROOT" "$FIXTURE_URL" false)
# Gate is live if the clone's resolved hooks dir has an executable pre-commit
# (templateDir dispatcher path) OR core.hooksPath was set to .githooks.
T7_HOOKS_DIR=$(git -C "$T7_ROOT" rev-parse --git-path hooks 2>/dev/null)
T7_LIVE=false
if [ -n "$T7_HOOKS_DIR" ] && [ -x "$T7_ROOT/$T7_HOOKS_DIR/pre-commit" ]; then T7_LIVE=true; fi
if [ -x "$T7_ROOT/.git/hooks/pre-commit" ]; then T7_LIVE=true; fi
if [ "$(git -C "$T7_ROOT" config --get core.hooksPath 2>/dev/null)" = ".githooks" ] \
    && [ -x "$T7_ROOT/.githooks/pre-commit" ]; then T7_LIVE=true; fi
if [ "$T7_RC" = "0" ] && [ "$T7_LIVE" = true ]; then
    test_pass
else
    test_fail "rc=$T7_RC gate_live=$T7_LIVE hooks_dir='$T7_HOOKS_DIR'; out_tail=$(_r_out | tail -3)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T8 — two husk-moves resolve to DISTINCT backups (no mv-into-existing nesting)
# Review/test fold-in: a second-granularity timestamp collides when two moves
# land in the same UTC second; the -N suffix must keep each backup separate and
# never nest one husk inside another.
# ═══════════════════════════════════════════════════════════════════════════
test_start "T8: repeated husk moves never nest (distinct .husk-bak-* backups)"
T8_HOME=$(_next_home); T8_ROOT="$T8_HOME/knowledge"
# First husk → clone.
mkdir -p "$T8_ROOT/agents/quark"; echo "husk one" > "$T8_ROOT/agents/quark/INDEX.md"
T8_RC1=$(_run_repo "$T8_HOME" "$T8_ROOT" "$FIXTURE_URL" false)
# Remove the clone's .git so a SECOND run treats the path as a husk again, and
# re-plant husk content — the second backup must not land inside the first.
rm -rf "$T8_ROOT"
mkdir -p "$T8_ROOT/agents/quark"; echo "husk two" > "$T8_ROOT/agents/quark/INDEX.md"
T8_RC2=$(_run_repo "$T8_HOME" "$T8_ROOT" "$FIXTURE_URL" false)
# Assert: >=2 distinct backups, each holding the husk content at its TOP level
# (nesting would push it one dir deeper), and no husk nested inside another
# (signature: a subdir named "knowledge" — the root basename — inside a backup).
T8_BACKUPS=$(ls -d "$T8_ROOT".husk-bak-* 2>/dev/null | wc -l | tr -d ' ')
T8_NESTED=$(find "$T8_ROOT".husk-bak-* -mindepth 1 -maxdepth 1 -type d -name knowledge 2>/dev/null | head -1)
T8_CONTENT_OK=true
for _b in "$T8_ROOT".husk-bak-*; do
    [ -f "$_b/agents/quark/INDEX.md" ] || T8_CONTENT_OK=false
done
if [ "$T8_RC1" = "0" ] && [ "$T8_RC2" = "0" ] && [ -d "$T8_ROOT/.git" ] \
    && [ "$T8_BACKUPS" -ge 2 ] && [ -z "$T8_NESTED" ] && [ "$T8_CONTENT_OK" = true ]; then
    test_pass
else
    test_fail "rc1=$T8_RC1 rc2=$T8_RC2 backups=$T8_BACKUPS nested='${T8_NESTED:-none}' content_ok=$T8_CONTENT_OK has_git=$([ -d "$T8_ROOT/.git" ] && echo y || echo n)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Standalone summary + exit code (no-op under test-runner.sh, which owns totals)
# ═══════════════════════════════════════════════════════════════════════════
if [ -n "${_PASS_COUNT+x}" ]; then
    echo ""
    echo "XACA-0747 knowledge-repo tests: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    [ "${_FAIL_COUNT:-0}" -eq 0 ] || exit 1
fi
exit 0
