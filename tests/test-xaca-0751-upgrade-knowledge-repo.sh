#!/bin/bash
# test-xaca-0751-upgrade-knowledge-repo.sh
#
# XACA-0751 (EPIC-0047): the UPGRADE path must provision ~/knowledge.
#
# install_knowledge_repo() (XACA-0747) turns ~/knowledge into a real git clone,
# but its ONLY call site was install_kanban_system() — reached on a fresh
# `aiteamforge setup`, NEVER on `aiteamforge upgrade`. So every already-installed
# box upgraded to a kb-knowledge-carrying release and never got the ~/knowledge
# directory those helpers operate on (M4Mini: on 0.17.0 with no ~/knowledge).
# XACA-0751 adds update_knowledge_repo() to aiteamforge-upgrade.sh's run sequence,
# REUSING install_knowledge_repo verbatim (fail-soft, DRY_RUN-aware, idempotent).
#
# XACA-0747 shipped 8 cases — all FRESH-INSTALL states, which is precisely why
# this defect shipped. This suite exercises the UPGRADE path instead:
#   U1  existing install + absent ~/knowledge + reachable  -> provisioned  [M4Mini regression]
#   U2  existing healthy clone                             -> fast-forward, local marker preserved
#   U3  dirty / diverged clone                             -> left untouched, upgrade still exit 0
#   U4  unreachable / unauthorized remote                  -> soft-skip, exit 0, no ~/knowledge  [M1Pro]
#   U5  --dry-run                                          -> no filesystem change
#   U6  idempotency                                        -> second run is a no-op fast-forward
#   U7  missing installer                                  -> fail-soft, exit 0
#   U8  set -u does NOT leak out of update_knowledge_repo  -> upgrade shell survives
#   U9  STRUCTURAL: update_knowledge_repo wired into the run sequence  (would have caught the bug)
#   U10 STRUCTURAL: update_knowledge_repo REUSES install_knowledge_repo (no reimplementation)
#
# All cases are sandboxed exactly like test-xaca-0747: every invocation overrides
# HOME, KB_KNOWLEDGE_GLOBAL_ROOT, KB_KNOWLEDGE_REPO_URL, and GIT_CONFIG_GLOBAL.
# The "canonical repo" is a LOCAL git fixture over a file:// URL — no network, no
# SSH auth, no touch of the real ~/knowledge or this machine's global git config.
# The real update_knowledge_repo() is EXTRACTED from aiteamforge-upgrade.sh (its
# main body has side effects: is_configured, get_framework_dir, brew checks) and
# driven against the REAL install-kanban.sh via LIBEXEC_DIR.
#
# Runs standalone (`bash tests/test-xaca-0751-upgrade-knowledge-repo.sh`) OR via
# test-runner.sh. Exit 0 = all pass, exit 1 = any fail.
#
# Requires: bash, git.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UPGRADE_SH="$TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh"
INSTALLER="$TAP_ROOT/libexec/installers/install-kanban.sh"
LIBEXEC_DIR_REAL="$TAP_ROOT/libexec"

for _need in "$UPGRADE_SH" "$INSTALLER"; do
    if [ ! -f "$_need" ]; then
        echo "FATAL: required file not found: $_need" >&2
        exit 1
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework: no-op-compatible stubs when test-runner.sh has not
# exported the real harness (mirrors test-xaca-0747).
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
    TEST_TMP_DIR="$(mktemp -d -t xaca0751-upgrade-knowledge.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
TEST_TMP_DIR="$(cd "$TEST_TMP_DIR" && pwd -P)"
WORK_DIR="$TEST_TMP_DIR/xaca0751"
mkdir -p "$WORK_DIR"

cleanup() {
    # Only clean a temp dir WE created; the runner owns its own. Use find -delete
    # (never rm -rf) per the damage-control convention.
    if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ] && [ -d "${TEST_TMP_DIR:-}" ]; then
        find "$TEST_TMP_DIR" -depth -delete 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Extract update_knowledge_repo() from aiteamforge-upgrade.sh (do NOT source the
# whole script — its main body runs is_configured / brew checks / the upgrade).
# Capture from its header line through its first top-level closing brace `^}$`
# (mirrors test-xaca-0608 _extract_fn).
# ─────────────────────────────────────────────────────────────────────────────
UPD_FN_SRC="$WORK_DIR/update_knowledge_repo.extracted.sh"
awk '
  /^update_knowledge_repo\(\) \{/ { capture=1 }
  capture { print }
  capture && /^}$/ { exit }
' "$UPGRADE_SH" > "$UPD_FN_SRC"

if [ ! -s "$UPD_FN_SRC" ]; then
    test_start "Sanity: extract update_knowledge_repo from aiteamforge-upgrade.sh"
    test_fail "awk returned empty — update_knowledge_repo not found in $UPGRADE_SH"
    if [ -n "${_PASS_COUNT+x}" ]; then
        echo ""
        echo "XACA-0751 upgrade-knowledge-repo tests: ${_PASS_COUNT} passed, $((_FAIL_COUNT + 1)) failed"
    fi
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Build the "canonical knowledge repo" fixture (a real git repo over file://).
# Mirrors test-xaca-0747's fixture: a tracked .githooks/ gate + a marker file.
# ─────────────────────────────────────────────────────────────────────────────
_build_fixture() {
    local dir="$1" marker="$2"
    mkdir -p "$dir/.githooks" "$dir/agents"
    cat > "$dir/.githooks/pre-commit" <<'HOOK'
#!/bin/bash
exit 0
HOOK
    chmod +x "$dir/.githooks/pre-commit"
    cat > "$dir/.githooks/setup-global-hooks.sh" <<'SETUP'
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
    chmod +x "$dir/.githooks/setup-global-hooks.sh"
    echo "$marker" > "$dir/agents/INDEX.md"
    (
        cd "$dir"
        git init -q
        git config user.email test@example.com
        git config user.name "Test Fixture"
        git config commit.gpgsign false
        git add -A
        git -c core.hooksPath=/dev/null commit -q -m "fixture: canonical knowledge repo"
    )
}

FIXTURE_REPO="$WORK_DIR/knowledge-fixture.git-src"
_build_fixture "$FIXTURE_REPO" "canonical knowledge repo marker" \
    || { echo "FATAL: could not build fixture repo" >&2; exit 1; }
FIXTURE_URL="file://$FIXTURE_REPO"
BOGUS_URL="file://$WORK_DIR/nonexistent-unauthorized-repo.git"

R_STDOUT="$WORK_DIR/r-stdout.txt"
R_STDERR="$WORK_DIR/r-stderr.txt"

# ─────────────────────────────────────────────────────────────────────────────
# Run the EXTRACTED update_knowledge_repo() in a sandboxed bash subshell that
# faithfully reproduces the upgrade context: `set -eo pipefail` (NOT -u, exactly
# as aiteamforge-upgrade.sh runs), print_* stubs, DRY_RUN, and LIBEXEC_DIR
# pointing at the REAL tap libexec so the function sources the REAL
# install-kanban.sh. Echoes the subshell exit code on stdout.
#
# Usage: _run_upgrade <home_dir> <global_root> <repo_url> [<dry_run>] [<libexec_override>]
# ─────────────────────────────────────────────────────────────────────────────
_run_upgrade() {
    local home_dir="$1" global_root="$2" repo_url="$3"
    local dry_run="${4:-false}" libexec_override="${5:-$LIBEXEC_DIR_REAL}"
    (
        set -eo pipefail   # upgrade.sh's exact options — deliberately WITHOUT -u
        export HOME="$home_dir"
        export KB_KNOWLEDGE_GLOBAL_ROOT="$global_root"
        export KB_KNOWLEDGE_REPO_URL="$repo_url"
        export DRY_RUN="$dry_run"
        export LIBEXEC_DIR="$libexec_override"
        export TEAM_WORKING_DIRS_STR=""
        export KANBAN_BACKUP_INTERVAL=900
        # An "existing install" — models the M4Mini/M1Pro upgrade scenario.
        export AITEAMFORGE_DIR="$home_dir/aiteamforge"
        mkdir -p "$AITEAMFORGE_DIR"
        # git inside the sandbox must NOT inherit this machine's identity/templateDir.
        export GIT_CONFIG_GLOBAL="$home_dir/.gitconfig"
        git config --file "$GIT_CONFIG_GLOBAL" user.email test@example.com
        git config --file "$GIT_CONFIG_GLOBAL" user.name "Sandbox"

        # print_* stubs the extracted function calls (real ones come from the
        # runner; here we no-op so output is just install_knowledge_repo's own).
        for _p in print_section print_info print_success print_warning print_error; do
            eval "${_p}() { printf '%s\n' \"\$*\"; }"
        done

        # shellcheck disable=SC1090
        source "$UPD_FN_SRC"

        update_knowledge_repo

        # Isolation proof (U8): if install-kanban.sh's `set -u` had leaked out of
        # update_knowledge_repo, referencing an unset var here would abort before
        # the marker prints. The upgrade shell must survive.
        echo "UNSET_REF=[${DEFINITELY_UNSET_VAR_XACA0751}]"
        echo "UPGRADE_SHELL_SURVIVED"
    ) >"$R_STDOUT" 2>"$R_STDERR"
    echo $?
}
_r_out() { cat "$R_STDOUT" 2>/dev/null; }
_next_home() { mktemp -d "$WORK_DIR/home-XXXXXX"; }

# ═══════════════════════════════════════════════════════════════════════════
# U1 — existing install + absent ~/knowledge + reachable remote -> provisioned
#      This is the M4Mini case and the direct regression test for the bug.
# ═══════════════════════════════════════════════════════════════════════════
test_start "U1: upgrade provisions ~/knowledge when absent (M4Mini regression)"
U1_HOME=$(_next_home); U1_ROOT="$U1_HOME/knowledge"
U1_RC=$(_run_upgrade "$U1_HOME" "$U1_ROOT" "$FIXTURE_URL" false)
if [ "$U1_RC" = "0" ] && [ -d "$U1_ROOT/.git" ] \
    && grep -q "canonical knowledge repo marker" "$U1_ROOT/agents/INDEX.md" 2>/dev/null; then
    test_pass
else
    test_fail "rc=$U1_RC has_git=$([ -d "$U1_ROOT/.git" ] && echo y || echo n); stderr=$(tail -3 "$R_STDERR" 2>/dev/null)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# U2 — existing healthy clone -> fast-forward, local marker preserved, no clobber
# ═══════════════════════════════════════════════════════════════════════════
test_start "U2: healthy existing clone fast-forwards, local marker preserved"
echo "local-work-do-not-clobber" > "$U1_ROOT/LOCAL_MARKER"
U2_RC=$(_run_upgrade "$U1_HOME" "$U1_ROOT" "$FIXTURE_URL" false)
U2_OUT="$(_r_out)"
if [ "$U2_RC" = "0" ] && [ -f "$U1_ROOT/LOCAL_MARKER" ] \
    && echo "$U2_OUT" | grep -qi "already present"; then
    test_pass
else
    test_fail "rc=$U2_RC marker=$([ -f "$U1_ROOT/LOCAL_MARKER" ] && echo kept || echo LOST); out_tail=$(echo "$U2_OUT" | tail -3)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# U3 — dirty/diverged clone -> left untouched, upgrade still exit 0
# Build a divergence: local commit adds LOCAL_ONLY; upstream advances separately.
# `git merge --ff-only @{u}` then refuses -> install_knowledge_repo leaves it be.
# ═══════════════════════════════════════════════════════════════════════════
test_start "U3: dirty/diverged clone is left untouched, upgrade exits 0"
U3_HOME=$(_next_home); U3_ROOT="$U3_HOME/knowledge"
U3_FIX="$WORK_DIR/u3-fixture.git-src"
_build_fixture "$U3_FIX" "u3 upstream marker" || { echo "FATAL: u3 fixture" >&2; exit 1; }
# Seed the clone from a first upgrade run.
U3_RC0=$(_run_upgrade "$U3_HOME" "$U3_ROOT" "file://$U3_FIX" false)
# Local divergent commit in the clone.
(
    cd "$U3_ROOT"
    git config user.email test@example.com
    git config user.name "Local Diverge"
    echo "local-only-diverged-work" > LOCAL_ONLY.md
    git -c core.hooksPath=/dev/null add LOCAL_ONLY.md
    git -c core.hooksPath=/dev/null commit -q -m "local divergent work"
) >/dev/null 2>&1
# Upstream advances on a different line.
(
    cd "$U3_FIX"
    echo "upstream advanced content" > UPSTREAM_NEW.md
    git -c core.hooksPath=/dev/null add UPSTREAM_NEW.md
    git -c core.hooksPath=/dev/null commit -q -m "upstream advance"
) >/dev/null 2>&1
U3_RC=$(_run_upgrade "$U3_HOME" "$U3_ROOT" "file://$U3_FIX" false)
U3_OUT="$(_r_out)"
if [ "$U3_RC0" = "0" ] && [ "$U3_RC" = "0" ] \
    && [ -f "$U3_ROOT/LOCAL_ONLY.md" ] \
    && [ ! -f "$U3_ROOT/UPSTREAM_NEW.md" ] \
    && echo "$U3_OUT" | grep -qi "left as-is"; then
    test_pass
else
    test_fail "rc0=$U3_RC0 rc=$U3_RC local_kept=$([ -f "$U3_ROOT/LOCAL_ONLY.md" ] && echo y || echo n) upstream_pulled=$([ -f "$U3_ROOT/UPSTREAM_NEW.md" ] && echo YES_CLOBBER || echo no) out_tail=$(echo "$U3_OUT" | tail -3)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# U4 — unreachable/unauthorized remote -> soft-skip, exit 0, no ~/knowledge
#      This is the M1Pro case (deploy key not yet authorized).
# ═══════════════════════════════════════════════════════════════════════════
test_start "U4: unreachable remote soft-skips, upgrade exits 0, no ~/knowledge (M1Pro case)"
U4_HOME=$(_next_home); U4_ROOT="$U4_HOME/knowledge"
U4_RC=$(_run_upgrade "$U4_HOME" "$U4_ROOT" "$BOGUS_URL" false)
U4_OUT="$(_r_out)"
# XACA-0751-014: soft-skip message now NAMES the attempted URL (was "not yet
# authorized"). With an explicit KB_KNOWLEDGE_REPO_URL, it reports that var unreachable.
if [ "$U4_RC" = "0" ] && [ ! -e "$U4_ROOT" ] \
    && echo "$U4_OUT" | grep -qi "unreachable" \
    && echo "$U4_OUT" | grep -q "$BOGUS_URL"; then
    test_pass
else
    test_fail "rc=$U4_RC root_exists=$([ -e "$U4_ROOT" ] && echo y || echo n); out_tail=$(echo "$U4_OUT" | tail -3)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# U5 — --dry-run -> no filesystem change
# ═══════════════════════════════════════════════════════════════════════════
test_start "U5: --dry-run touches nothing (no ~/knowledge created)"
U5_HOME=$(_next_home); U5_ROOT="$U5_HOME/knowledge"
U5_RC=$(_run_upgrade "$U5_HOME" "$U5_ROOT" "$FIXTURE_URL" true)
if [ "$U5_RC" = "0" ] && [ ! -e "$U5_ROOT" ]; then
    test_pass
else
    test_fail "rc=$U5_RC; expected $U5_ROOT absent; $([ -e "$U5_ROOT" ] && find "$U5_ROOT" -maxdepth 1)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# U6 — idempotency: running the upgrade step twice is a no-op fast-forward
# ═══════════════════════════════════════════════════════════════════════════
test_start "U6: idempotent — second upgrade run is a no-op fast-forward"
U6_HOME=$(_next_home); U6_ROOT="$U6_HOME/knowledge"
U6_RC1=$(_run_upgrade "$U6_HOME" "$U6_ROOT" "$FIXTURE_URL" false)
echo "survives-second-run" > "$U6_ROOT/IDEMPOTENT_MARKER"
U6_RC2=$(_run_upgrade "$U6_HOME" "$U6_ROOT" "$FIXTURE_URL" false)
U6_OUT="$(_r_out)"
if [ "$U6_RC1" = "0" ] && [ "$U6_RC2" = "0" ] \
    && [ -d "$U6_ROOT/.git" ] && [ -f "$U6_ROOT/IDEMPOTENT_MARKER" ] \
    && echo "$U6_OUT" | grep -qi "already present"; then
    test_pass
else
    test_fail "rc1=$U6_RC1 rc2=$U6_RC2 has_git=$([ -d "$U6_ROOT/.git" ] && echo y || echo n) marker=$([ -f "$U6_ROOT/IDEMPOTENT_MARKER" ] && echo kept || echo LOST)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# U7 — missing installer -> fail-soft (exit 0, warns, no crash)
# ═══════════════════════════════════════════════════════════════════════════
test_start "U7: missing install-kanban.sh is fail-soft (exit 0)"
U7_HOME=$(_next_home); U7_ROOT="$U7_HOME/knowledge"
U7_BADLIBEXEC="$WORK_DIR/no-such-libexec"
U7_RC=$(_run_upgrade "$U7_HOME" "$U7_ROOT" "$FIXTURE_URL" false "$U7_BADLIBEXEC")
U7_OUT="$(_r_out)"
if [ "$U7_RC" = "0" ] && [ ! -e "$U7_ROOT" ] \
    && echo "$U7_OUT" | grep -qi "not found"; then
    test_pass
else
    test_fail "rc=$U7_RC root_exists=$([ -e "$U7_ROOT" ] && echo y || echo n); out_tail=$(echo "$U7_OUT" | tail -3)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# U8 — set -u must NOT leak out of update_knowledge_repo into the upgrade shell.
# The runner prints UPGRADE_SHELL_SURVIVED only if a post-call unset-var ref did
# not abort the `set -eo pipefail` (no -u) shell — proving the installer's
# `set -u` stayed contained in the subshell.
# ═══════════════════════════════════════════════════════════════════════════
test_start "U8: install-kanban.sh 'set -u' does not leak into the upgrade shell"
U8_HOME=$(_next_home); U8_ROOT="$U8_HOME/knowledge"
U8_RC=$(_run_upgrade "$U8_HOME" "$U8_ROOT" "$FIXTURE_URL" false)
U8_OUT="$(_r_out)"
if [ "$U8_RC" = "0" ] && echo "$U8_OUT" | grep -q "UPGRADE_SHELL_SURVIVED"; then
    test_pass
else
    test_fail "rc=$U8_RC survived=$(echo "$U8_OUT" | grep -q UPGRADE_SHELL_SURVIVED && echo y || echo n); stderr=$(tail -3 "$R_STDERR" 2>/dev/null)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# U9 — STRUCTURAL: update_knowledge_repo is wired into the run sequence.
# This is the assertion that would have caught the original bug: the function may
# exist but must be CALLED in the bare-call run sequence near the bottom.
# ═══════════════════════════════════════════════════════════════════════════
test_start "U9: update_knowledge_repo is invoked in the upgrade run sequence"
if grep -qE '^update_knowledge_repo$' "$UPGRADE_SH"; then
    test_pass
else
    test_fail "aiteamforge-upgrade.sh run sequence must call update_knowledge_repo (bare line)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# U10 — STRUCTURAL: update_knowledge_repo REUSES install_knowledge_repo.
# Guards against a future reimplementation drifting from the canonical states.
# ═══════════════════════════════════════════════════════════════════════════
test_start "U10: update_knowledge_repo reuses install_knowledge_repo (no reimplementation)"
if grep -q "install-kanban.sh" "$UPD_FN_SRC" \
    && grep -qE '(^|[^_])install_knowledge_repo\b' "$UPD_FN_SRC"; then
    test_pass
else
    test_fail "extracted update_knowledge_repo must source install-kanban.sh AND call install_knowledge_repo"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Standalone summary + exit code (no-op under test-runner.sh, which owns totals)
# ═══════════════════════════════════════════════════════════════════════════
if [ -n "${_PASS_COUNT+x}" ]; then
    echo ""
    echo "XACA-0751 upgrade-knowledge-repo tests: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    [ "${_FAIL_COUNT:-0}" -eq 0 ] || exit 1
fi
exit 0
