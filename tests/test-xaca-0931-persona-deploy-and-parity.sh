#!/bin/bash
# test-xaca-0931-persona-deploy-and-parity.sh
#
# XACA-0931-005 (Testing & Debugging): failure-mode / edge-case coverage for
# the five files built under XACA-0931-002/003 — deliberately NOT a
# happy-path re-verification (that is XACA-0931-004's job; see the parent
# ticket's field-evidence doc). This suite tries to break:
#
#   - libexec/lib/persona-targets.sh          (pt_enumerate_targets)
#   - libexec/commands/aiteamforge-upgrade.sh (update_team_personas UNION,
#                                               deploy_team_personas_to_projects,
#                                               _xaca0931_load_persona_targets)
#   - scripts/deploy-worktree-personas.sh     (emit-transformed)
#   - share/scripts/aiteamforge-persona-parity-check.sh (S3 surface)
#
# Focus areas (see XACA-0931-005's own dispatch prompt for the full list):
#   A. fail-closed behaviour (unreadable/malformed config, missing git/python3,
#      unreadable dirs, "no targets" vs "could not determine targets")
#   B. the `set -eo pipefail` hazard (XACA-1028 precedent)
#   C. subshell-visibility of the #UNINSPECTABLE trailer
#   D. enumeration edge cases (impostor dirs, linked worktree, no .claude/agents,
#      zero project dirs, no .synced-from-tap marker)
#   E. idempotency
#   F. the path-safety guard
#   G. /bin/bash 3.2 specifically
#
# All filesystem activity is sandboxed under TEST_TMP_DIR with a fake $HOME,
# AITEAMFORGE_DIR, FRAMEWORK_DIR and WORKING_DIR. NEVER touches the real
# $HOME/aiteamforge, ~/aiteamforge-backups, or this repo's own share/personas —
# installer-test safety rule. This suite only READS the real tap tree
# (libexec/lib/*.sh, scripts/deploy-worktree-personas.sh,
# share/scripts/aiteamforge-persona-parity-check.sh) as a dependency.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UPGRADE_SH="$TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh"
CONFIG_LIB="$TAP_ROOT/libexec/lib/config.sh"
PT_LIB="$TAP_ROOT/libexec/lib/persona-targets.sh"
DEPLOY_SH="$TAP_ROOT/share/scripts/deploy-worktree-personas.sh"
PARITY_SH="$TAP_ROOT/share/scripts/aiteamforge-persona-parity-check.sh"
# The canonical deploy script lives in dev-team/scripts/; the tap copy is a
# mirror (see the five-files list in XACA-0931-001_decision.md §5). Prefer
# the dev-team canonical if present (this worktree has both), since that is
# what a real `--nested-main-root` invocation from aiteamforge-upgrade.sh
# resolves to on this box (WORKING_DIR/scripts/... after update_aux_scripts
# refreshes it from the canonical/mirror). Fall back to the tap copy.
DEV_TEAM_DEPLOY_SH="$(cd "$TAP_ROOT/.." 2>/dev/null && pwd)/scripts/deploy-worktree-personas.sh"
if [ -f "$DEV_TEAM_DEPLOY_SH" ]; then
    DEPLOY_SH_REAL="$DEV_TEAM_DEPLOY_SH"
else
    DEPLOY_SH_REAL="$DEPLOY_SH"
fi

for _need in "$UPGRADE_SH" "$CONFIG_LIB" "$PT_LIB" "$PARITY_SH" "$DEPLOY_SH_REAL"; do
    if [ ! -f "$_need" ]; then
        echo "FATAL: required file not found: $_need" >&2
        exit 1
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework (works sourced by test-runner.sh OR invoked directly).
# ─────────────────────────────────────────────────────────────────────────────
_STANDALONE=false
if ! type -t test_start >/dev/null 2>&1; then
    _STANDALONE=true
    _PASS_COUNT=0
    _FAIL_COUNT=0
    _CURRENT_TEST=""
    test_start() { _CURRENT_TEST="$1"; echo "  >> $1"; }
    test_pass()  { _PASS_COUNT=$((_PASS_COUNT + 1)); echo "     PASS: $_CURRENT_TEST"; }
    test_fail()  { _FAIL_COUNT=$((_FAIL_COUNT + 1)); echo "     FAIL: $_CURRENT_TEST -- $1" >&2; }
fi

if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca0931-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
cleanup() { if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then rm -rf "$TEST_TMP_DIR"; fi; }
trap cleanup EXIT

WORK_DIR="$TEST_TMP_DIR/xaca0931"
mkdir -p "$WORK_DIR"
_next_sandbox() { mktemp -d "$WORK_DIR/sbx-XXXXXX"; }

# ─────────────────────────────────────────────────────────────────────────────
# Fixture builders
# ─────────────────────────────────────────────────────────────────────────────

# _mk_conf <teams_dir> <basename-no-ext> <has_projects> <requires_client> <working_dir_literal>
# working_dir_literal is written VERBATIM (so callers can pass "$HOME/x" to
# exercise real expansion at source time, or "" to omit the var entirely, or
# an already-expanded absolute path).
_mk_conf() {
    local teams_dir="$1" name="$2" has_proj="$3" req_client="$4" wd="$5"
    mkdir -p "$teams_dir"
    {
        printf 'TEAM_ID="%s"\n' "$name"
        [ -n "$has_proj" ] && printf 'TEAM_HAS_PROJECTS="%s"\n' "$has_proj"
        [ -n "$req_client" ] && printf 'TEAM_REQUIRES_CLIENT_ID="%s"\n' "$req_client"
        [ -n "$wd" ] && printf 'TEAM_WORKING_DIR="%s"\n' "$wd"
    } > "${teams_dir}/${name}.conf"
}

# _mk_project_git_root <dir> — a real git repo root at <dir>.
_mk_project_git_root() {
    local d="$1"
    mkdir -p "$d"
    ( cd "$d" && git init -q . && git config user.email t@t.test && git config user.name t ) >/dev/null 2>&1
}

# _mk_deployed_agents <project_dir> [with_marker]
_mk_deployed_agents() {
    local d="$1" with_marker="${2:-true}"
    mkdir -p "${d}/.claude/agents"
    printf '%s\n' "---" "name: placeholder" "---" "body" > "${d}/.claude/agents/team_char_role_persona.md"
    if [ "$with_marker" = "true" ]; then
        printf 'synced_at: 2020-01-01T00:00:00Z\n' > "${d}/.claude/agents/.synced-from-tap"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Part A/D/C — source persona-targets.sh + config.sh for real, drive
# pt_enumerate_targets() and _xaca0931_load_persona_targets() directly.
# ─────────────────────────────────────────────────────────────────────────────
# shellcheck disable=SC1090
source "$CONFIG_LIB"
# shellcheck disable=SC1090
source "$PT_LIB"

_run_pt() {
    # _run_pt <framework_dir> <path_no_git=0|1>
    local fw="$1" no_git="${2:-0}"
    local out rc
    if [ "$no_git" = "1" ]; then
        # PATH override that excludes git — use a minimal sandbox bin dir
        # containing only the essentials pt_enumerate_targets itself needs
        # (none — it's pure builtins + `command -v git`). Real /bin/bash is
        # already resolved by shebang/invocation, so an empty PATH is safe.
        out="$(PATH="$WORK_DIR/empty-bin" pt_enumerate_targets "$fw" 2>"$WORK_DIR/pt-stderr.log")"
    else
        out="$(pt_enumerate_targets "$fw" 2>"$WORK_DIR/pt-stderr.log")"
    fi
    rc=$?
    printf '%s' "$out"
    return "$rc"
}
mkdir -p "$WORK_DIR/empty-bin"

_pt_uninspectable_count() {
    printf '%s\n' "$1" | tail -n 1 | awk -F'\t' '{print $2}'
}
_pt_target_lines() {
    printf '%s\n' "$1" | sed '$d'
}

echo "=== Part A: persona-targets.sh fail-closed + enumeration edge cases ==="

# TA1: git absent from PATH -> uninspectable=1, zero target lines
test_start "TA1: git absent from PATH -> UNINSPECTABLE=1, zero targets, warning names git"
T_FW="$(_next_sandbox)"
_mk_conf "$T_FW/share/teams" academy "" "" ""
OUT="$(_run_pt "$T_FW" 1)"
CNT="$(_pt_uninspectable_count "$OUT")"
LINES="$(_pt_target_lines "$OUT")"
if [ "$CNT" = "1" ] && [ -z "$LINES" ] && grep -qi "git not found" "$WORK_DIR/pt-stderr.log"; then
    test_pass
else
    test_fail "expected UNINSPECTABLE=1, 0 target lines, 'git not found' warning; got CNT=$CNT LINES=[$LINES] stderr=$(cat "$WORK_DIR/pt-stderr.log")"
fi

# TA2: share/teams missing entirely -> uninspectable=1
test_start "TA2: share/teams/ directory missing entirely -> UNINSPECTABLE=1"
T_FW="$(_next_sandbox)"
mkdir -p "$T_FW/share"   # no teams/ subdir
OUT="$(_run_pt "$T_FW")"
CNT="$(_pt_uninspectable_count "$OUT")"
if [ "$CNT" = "1" ] && grep -qi "Team conf directory not found" "$WORK_DIR/pt-stderr.log"; then
    test_pass
else
    test_fail "expected UNINSPECTABLE=1 with 'not found' warning; got CNT=$CNT stderr=$(cat "$WORK_DIR/pt-stderr.log")"
fi

# TA3: share/teams present but unreadable -> uninspectable=1
test_start "TA3: share/teams/ exists but is unreadable (mode 000) -> UNINSPECTABLE=1"
T_FW="$(_next_sandbox)"
mkdir -p "$T_FW/share/teams"
_mk_conf "$T_FW/share/teams" academy "" "" ""
chmod 000 "$T_FW/share/teams"
OUT="$(_run_pt "$T_FW")"
CNT="$(_pt_uninspectable_count "$OUT")"
chmod 755 "$T_FW/share/teams"   # restore so cleanup can rm -rf it
if [ "$CNT" = "1" ] && grep -qi "not readable/searchable" "$WORK_DIR/pt-stderr.log"; then
    test_pass
else
    test_fail "expected UNINSPECTABLE=1; got CNT=$CNT stderr=$(cat "$WORK_DIR/pt-stderr.log")"
fi

# TA4: share/teams present but EMPTY (zero .conf files) -> uninspectable=1
# NOTE: this is a real production-shape gap worth flagging in the report,
# not just a fixture quirk -- see XACA-0931-005 test report §"share/teams
# empty-but-present".
test_start "TA4: share/teams/ exists, readable, but contains zero *.conf files -> UNINSPECTABLE=1 (documents current behaviour)"
T_FW="$(_next_sandbox)"
mkdir -p "$T_FW/share/teams"
OUT="$(_run_pt "$T_FW")"
CNT="$(_pt_uninspectable_count "$OUT")"
if [ "$CNT" = "1" ] && grep -qi "No \*\.conf files found" "$WORK_DIR/pt-stderr.log"; then
    test_pass
else
    test_fail "expected UNINSPECTABLE=1 for an empty (but present) teams dir; got CNT=$CNT stderr=$(cat "$WORK_DIR/pt-stderr.log")"
fi

# TA5: a conf that fails to source -> uninspectable increments, distinguished
# from a legitimate flat-team false|false
test_start "TA5: a conf file that fails to source (syntax error) -> UNINSPECTABLE++, not a silent false|false skip"
T_FW="$(_next_sandbox)"
mkdir -p "$T_FW/share/teams"
printf 'TEAM_HAS_PROJECTS="true"\nthis is not valid shell (((\n' > "$T_FW/share/teams/broken.conf"
OUT="$(_run_pt "$T_FW")"
CNT="$(_pt_uninspectable_count "$OUT")"
LINES="$(_pt_target_lines "$OUT")"
if [ "$CNT" = "1" ] && [ -z "$LINES" ] && grep -qi "failed to source" "$WORK_DIR/pt-stderr.log"; then
    test_pass
else
    test_fail "expected UNINSPECTABLE=1 and 'failed to source' warning; got CNT=$CNT LINES=[$LINES] stderr=$(cat "$WORK_DIR/pt-stderr.log")"
fi

# TA6: TEAM_HAS_PROJECTS=true but TEAM_WORKING_DIR unset -> uninspectable++
test_start "TA6: TEAM_HAS_PROJECTS=true with TEAM_WORKING_DIR unset -> UNINSPECTABLE++"
T_FW="$(_next_sandbox)"
_mk_conf "$T_FW/share/teams" orphan "true" "" ""
OUT="$(_run_pt "$T_FW")"
CNT="$(_pt_uninspectable_count "$OUT")"
if [ "$CNT" = "1" ] && grep -qi "TEAM_WORKING_DIR not set" "$WORK_DIR/pt-stderr.log"; then
    test_pass
else
    test_fail "expected UNINSPECTABLE=1; got CNT=$CNT stderr=$(cat "$WORK_DIR/pt-stderr.log")"
fi

# TA7: TEAM_WORKING_DIR set but the directory does not exist -> CLEAN skip
# (0 targets, 0 uninspectable) -- team simply not present on this box.
test_start "TA7: TEAM_WORKING_DIR set but nonexistent -> clean skip, NOT uninspectable"
T_FW="$(_next_sandbox)"
_mk_conf "$T_FW/share/teams" ghost "true" "" "$WORK_DIR/does-not-exist-$$"
OUT="$(_run_pt "$T_FW")"
CNT="$(_pt_uninspectable_count "$OUT")"
LINES="$(_pt_target_lines "$OUT")"
if [ "$CNT" = "0" ] && [ -z "$LINES" ]; then
    test_pass
else
    test_fail "expected UNINSPECTABLE=0 and 0 targets (clean skip, team not installed); got CNT=$CNT LINES=[$LINES]"
fi

# TA8: TEAM_WORKING_DIR exists but is unreadable/non-searchable -> uninspectable++
test_start "TA8: TEAM_WORKING_DIR exists but unreadable (mode 000) -> UNINSPECTABLE++"
T_FW="$(_next_sandbox)"
T_WD="$(_next_sandbox)"
mkdir -p "$T_WD/blocked-team"
chmod 000 "$T_WD/blocked-team"
_mk_conf "$T_FW/share/teams" blocked "true" "" "$T_WD/blocked-team"
OUT="$(_run_pt "$T_FW")"
CNT="$(_pt_uninspectable_count "$OUT")"
chmod 755 "$T_WD/blocked-team"
if [ "$CNT" = "1" ] && grep -qi "not readable/searchable" "$WORK_DIR/pt-stderr.log"; then
    test_pass
else
    test_fail "expected UNINSPECTABLE=1; got CNT=$CNT stderr=$(cat "$WORK_DIR/pt-stderr.log")"
fi

# TA9: two impostor dirs (non-git) are rejected -- the darren-m4-mini live
# negative cases from the decision record, reproduced synthetically.
test_start "TA9: non-git impostor dirs (~/medical/personas-shaped, ~/legal/default-shaped) are never emitted as targets"
T_FW="$(_next_sandbox)"
T_WD="$(_next_sandbox)"
mkdir -p "$T_WD/proj/personas" "$T_WD/proj/personas/agents" "$T_WD/proj/personas/avatars" "$T_WD/proj/personas/prompts"
mkdir -p "$T_WD/proj/default/kanban" "$T_WD/proj/default/personas"
_mk_conf "$T_FW/share/teams" imp "true" "" "$T_WD/proj"
OUT="$(_run_pt "$T_FW")"
LINES="$(_pt_target_lines "$OUT")"
if [ -z "$LINES" ]; then
    test_pass
else
    test_fail "expected zero targets (both candidate dirs are non-git impostors); got LINES=[$LINES]"
fi

# TA10: linked worktree (.git is a FILE, not a dir) -> rejected
test_start "TA10: a linked git worktree (.git is a FILE) is rejected as a target"
T_FW="$(_next_sandbox)"
T_WD="$(_next_sandbox)"
_mk_project_git_root "$T_WD/mainrepo"
( cd "$T_WD/mainrepo" && git worktree add -q -b wt-branch "$T_WD/mainrepo-wt" >/dev/null 2>&1 )
if [ -f "$T_WD/mainrepo-wt/.git" ]; then
    _mk_deployed_agents "$T_WD/mainrepo-wt"
    _mk_conf "$T_FW/share/teams" wtteam "true" "" "$T_WD"
    OUT="$(_run_pt "$T_FW")"
    LINES="$(_pt_target_lines "$OUT")"
    if [ -z "$LINES" ]; then
        test_pass
    else
        test_fail "expected the linked worktree to be rejected (git-root guard); got LINES=[$LINES]"
    fi
else
    test_fail "PRECONDITION FAILED: could not create a linked worktree with .git as a file (git worktree add did not produce the expected shape)"
fi

# TA11: project dir with NO .claude/agents -> skipped (refresh-only, never create)
test_start "TA11: git-root project dir with no .claude/agents -> skipped (refresh-only gate)"
T_FW="$(_next_sandbox)"
T_WD="$(_next_sandbox)"
_mk_project_git_root "$T_WD/proj/undeployed"
_mk_conf "$T_FW/share/teams" undeployed "true" "" "$T_WD/proj"
OUT="$(_run_pt "$T_FW")"
LINES="$(_pt_target_lines "$OUT")"
if [ -z "$LINES" ] && [ ! -d "$T_WD/proj/undeployed/.claude" ]; then
    test_pass
else
    test_fail "expected zero targets and NO .claude dir created; got LINES=[$LINES] .claude exists=$([ -d "$T_WD/proj/undeployed/.claude" ] && echo yes || echo no)"
fi

# TA12: deployed dir with NO .synced-from-tap marker is STILL enumerated
# (the medical/general discriminating case from the field evidence doc).
test_start "TA12: deployed target with NO .synced-from-tap marker is still enumerated (marker is never an enumeration key)"
T_FW="$(_next_sandbox)"
T_WD="$(_next_sandbox)"
_mk_project_git_root "$T_WD/proj/general"
_mk_deployed_agents "$T_WD/proj/general" false   # no marker
if [ -f "$T_WD/proj/general/.claude/agents/.synced-from-tap" ]; then
    test_fail "PRECONDITION FAILED: marker file unexpectedly present"
else
    _mk_conf "$T_FW/share/teams" medical "true" "" "$T_WD/proj"
    OUT="$(_run_pt "$T_FW")"
    LINES="$(_pt_target_lines "$OUT")"
    if printf '%s\n' "$LINES" | grep -qE "^medical	.*/proj/general\$"; then
        test_pass
    else
        test_fail "expected medical/general to be enumerated despite the missing marker; got LINES=[$LINES]"
    fi
fi

# TA13: client-scoped team (TEAM_REQUIRES_CLIENT_ID=true) contributes ZERO
# targets even with TEAM_HAS_PROJECTS=true and a real deployed-looking dir
# sitting under its working dir -- the freelance negative case.
test_start "TA13: TEAM_REQUIRES_CLIENT_ID=true (freelance-shaped) contributes zero targets regardless of on-disk content"
T_FW="$(_next_sandbox)"
T_WD="$(_next_sandbox)"
_mk_project_git_root "$T_WD/proj/someclient"
_mk_deployed_agents "$T_WD/proj/someclient"
_mk_conf "$T_FW/share/teams" freelance "true" "true" "$T_WD/proj"
OUT="$(_run_pt "$T_FW")"
LINES="$(_pt_target_lines "$OUT")"
CNT="$(_pt_uninspectable_count "$OUT")"
if [ -z "$LINES" ] && [ "$CNT" = "0" ]; then
    test_pass
else
    test_fail "expected zero targets, zero uninspectable for a client-scoped team; got LINES=[$LINES] CNT=$CNT"
fi

# TA14: flat team (TEAM_HAS_PROJECTS unset/false) contributes zero targets
test_start "TA14: flat team (TEAM_HAS_PROJECTS unset) contributes zero targets, zero uninspectable"
T_FW="$(_next_sandbox)"
_mk_conf "$T_FW/share/teams" academy "" "" ""
OUT="$(_run_pt "$T_FW")"
LINES="$(_pt_target_lines "$OUT")"
CNT="$(_pt_uninspectable_count "$OUT")"
if [ -z "$LINES" ] && [ "$CNT" = "0" ]; then
    test_pass
else
    test_fail "expected zero targets, zero uninspectable for a flat team; got LINES=[$LINES] CNT=$CNT"
fi

# TA15: a team with a working dir that exists but has ZERO subdirectories ->
# clean no-op, not an error.
test_start "TA15: a team with zero project subdirectories under an existing working dir -> clean no-op"
T_FW="$(_next_sandbox)"
T_WD="$(_next_sandbox)"
mkdir -p "$T_WD/emptyteam"
_mk_conf "$T_FW/share/teams" emptyteam "true" "" "$T_WD/emptyteam"
OUT="$(_run_pt "$T_FW")"
LINES="$(_pt_target_lines "$OUT")"
CNT="$(_pt_uninspectable_count "$OUT")"
if [ -z "$LINES" ] && [ "$CNT" = "0" ]; then
    test_pass
else
    test_fail "expected zero targets, zero uninspectable; got LINES=[$LINES] CNT=$CNT"
fi

# TA16: .claude/agents exists but is unreadable/non-searchable -> uninspectable++
# (never silently treated as "no target here").
test_start "TA16: deployed .claude/agents dir exists but is unreadable -> UNINSPECTABLE++, not a silent skip"
T_FW="$(_next_sandbox)"
T_WD="$(_next_sandbox)"
_mk_project_git_root "$T_WD/proj/blockedagents"
mkdir -p "$T_WD/proj/blockedagents/.claude/agents"
chmod 000 "$T_WD/proj/blockedagents/.claude/agents"
_mk_conf "$T_FW/share/teams" blockedagents "true" "" "$T_WD/proj"
OUT="$(_run_pt "$T_FW")"
CNT="$(_pt_uninspectable_count "$OUT")"
LINES="$(_pt_target_lines "$OUT")"
chmod 755 "$T_WD/proj/blockedagents/.claude/agents"
if [ "$CNT" = "1" ] && [ -z "$LINES" ] && grep -qi "not readable/searchable" "$WORK_DIR/pt-stderr.log"; then
    test_pass
else
    test_fail "expected UNINSPECTABLE=1, 0 targets; got CNT=$CNT LINES=[$LINES] stderr=$(cat "$WORK_DIR/pt-stderr.log")"
fi

# TA17: trailer line is ALWAYS the last line and always present, even for a
# fully clean/empty box (0 targets, 0 uninspectable) -- absence of the
# trailer must never be indistinguishable from "nothing happened".
test_start "TA17: #UNINSPECTABLE trailer is present as the exact last line even on a fully clean/empty box"
T_FW="$(_next_sandbox)"
mkdir -p "$T_FW/share/teams"
_mk_conf "$T_FW/share/teams" flatteam "" "" ""
OUT="$(_run_pt "$T_FW")"
LAST_LINE="$(printf '%s\n' "$OUT" | tail -n 1)"
if [ "$LAST_LINE" = "$(printf '#UNINSPECTABLE\t0')" ]; then
    test_pass
else
    test_fail "expected exact trailer '#UNINSPECTABLE<TAB>0' as last line; got: [$LAST_LINE]"
fi

echo ""
echo "=== Part B: subshell-visibility of the #UNINSPECTABLE trailer ==="

# TB1: _xaca0931_load_persona_targets (process-substitution consumer) must
# populate its globals in the CALLING shell, not lose them to the subshell
# the `< <(...)` construct runs in.
test_start "TB1: _xaca0931_load_persona_targets populates _XACA0931_TARGETS(_UNINSPECTABLE) in the caller after return"
_xaca0931_load_persona_targets_extracted="$(awk '
  $0 ~ "^_xaca0931_load_persona_targets\\(\\) \\{" { capture=1 }
  capture { print }
  capture && /^}$/ { exit }
' "$UPGRADE_SH")"
if [ -z "$_xaca0931_load_persona_targets_extracted" ]; then
    test_fail "could not extract _xaca0931_load_persona_targets from $UPGRADE_SH"
else
    # shellcheck disable=SC1090
    eval "$_xaca0931_load_persona_targets_extracted"
    T_FW="$(_next_sandbox)"
    T_WD="$(_next_sandbox)"
    _mk_project_git_root "$T_WD/proj/a"
    _mk_deployed_agents "$T_WD/proj/a"
    _mk_conf "$T_FW/share/teams" teama "true" "" "$T_WD/proj"
    _mk_conf "$T_FW/share/teams" brokenconf "true" "" ""   # forces UNINSPECTABLE=1 too

    # _xaca0931_load_persona_targets reads the FRAMEWORK_DIR global (it is
    # not a parameter) -- must be set in THIS shell before calling.
    FRAMEWORK_DIR="$T_FW"
    # Unset first to prove the function itself (not a stale global) sets these.
    unset _XACA0931_TARGETS _XACA0931_TARGETS_UNINSPECTABLE
    _xaca0931_load_persona_targets
    _rc=$?
    if [ "$_rc" -eq 0 ] \
        && [ "${#_XACA0931_TARGETS[@]}" -eq 1 ] \
        && [ "${_XACA0931_TARGETS_UNINSPECTABLE:-MISSING}" = "1" ] \
        && [[ "${_XACA0931_TARGETS[0]}" == teama$'\t'*"/proj/a" ]]; then
        test_pass
    else
        test_fail "globals not visible/correct after return: count=${#_XACA0931_TARGETS[@]} uninspectable=${_XACA0931_TARGETS_UNINSPECTABLE:-MISSING} first=${_XACA0931_TARGETS[0]:-<empty>}"
    fi
fi

echo ""
echo "=== Part C/D: deploy_team_personas_to_projects / update_team_personas (extracted, real execution) ==="

# Extract each needed function INDIVIDUALLY (never transitively-by-comment-
# grep) to avoid the k501-shaped false dependency this ticket's own new
# comment prose introduces into the sibling suite's transitive extractor
# (see XACA-0931-005 test report: T12 of test-xaca-0925-persona-refresh.sh
# now vacuums in update_aux_scripts() -- which legitimately uses `-nt` for
# an unrelated purpose -- purely because deploy_team_personas_to_projects()'s
# comment block mentions its name in prose, not code). Hand-picking exactly
# the real call graph sidesteps that here.
_FN_NAMES="update_team_personas deploy_team_personas_to_projects _xaca0931_load_persona_targets _xaca0925_refresh_team_personas _xaca0925_valid_team_id _xaca0925_cleanup_failed_backup_if_empty _xaca0925_prune_persona_backups"
_COMBINED_SRC=""
for _fn in $_FN_NAMES; do
    _src="$(awk -v fn="$_fn" '
      $0 ~ ("^" fn "\\(\\) \\{") { capture=1 }
      capture { print }
      capture && /^}$/ { exit }
    ' "$UPGRADE_SH")"
    if [ -z "$_src" ]; then
        echo "FATAL: could not extract $_fn from $UPGRADE_SH" >&2
        exit 1
    fi
    _COMBINED_SRC="${_COMBINED_SRC}"$'\n\n'"${_src}"
done
EXTRACTED="$WORK_DIR/extracted-deploy-fns.sh"
printf '%s\n' "$_COMBINED_SRC" > "$EXTRACTED"
# shellcheck disable=SC1090
source "$EXTRACTED"

_STUB_LOG="$WORK_DIR/stub-output.log"
_install_print_stubs() {
    : > "$_STUB_LOG"
    for _p in print_section print_info print_success print_warning print_error; do
        eval "${_p}() { printf '%s\n' \"\$*\" >> \"\$_STUB_LOG\"; }"
    done
}
_install_print_stubs

_seed_config() {
    local wd="$1"; shift
    local teams_json="" t
    for t in "$@"; do
        [ -n "$teams_json" ] && teams_json="${teams_json}, "
        teams_json="${teams_json}\"${t}\""
    done
    printf '{\n  "schema_version": 1,\n  "teams": [%s]\n}\n' "$teams_json" > "${wd}/.aiteamforge-config"
}

# Lay down the REAL deployer at WORKING_DIR/scripts/deploy-worktree-personas.sh
# (mirrors update_aux_scripts having already refreshed it earlier in the run,
# per the ordering contract in XACA-0931-001 §3.6).
_seed_real_deployer() {
    local wd="$1"
    mkdir -p "${wd}/scripts"
    cp "$DEPLOY_SH_REAL" "${wd}/scripts/deploy-worktree-personas.sh"
    chmod +x "${wd}/scripts/deploy-worktree-personas.sh"
}

# Reset UPGRADE_PERSONA_DEPLOY_* deferred-warning globals between tests
# (production initializes these once at file top; we must mirror that here).
_reset_deploy_globals() {
    UPGRADE_PERSONA_DEPLOY_HAD_WARNINGS=false
    UPGRADE_PERSONA_DEPLOY_WARNING_SUMMARY=""
}

# TC1: per-target deploy failure is NON-FATAL: one failing target, one
# succeeding target -> refreshed=1, failed=1, function itself returns 0,
# HAD_WARNINGS=true, and (critically, XACA-1028) execution continues past
# the call under `set -eo pipefail`.
test_start "TC1: one failing target among two is non-fatal -- refreshed=1/failed=1, fn returns 0, HAD_WARNINGS=true, execution continues past the call"
T_HOME="$(_next_sandbox)"; T_FW="$(_next_sandbox)"; T_WD="$(_next_sandbox)"
_seed_real_deployer "$T_WD"
# Each team gets its OWN working dir (mirrors real box layout, $HOME/<team>/) --
# sharing one working dir between two team confs would make pt_enumerate_targets
# emit BOTH project dirs under BOTH team names (4 targets, not 2), which is
# exactly the fixture bug this comment exists to prevent regressing into.
_mk_project_git_root "$T_WD/teamgood-projects/good"
_mk_deployed_agents "$T_WD/teamgood-projects/good"
mkdir -p "$T_WD/teamgood/personas/agents"   # S2: working-dir source the deployer actually reads
printf '%s\n' "---" "name: x" "---" "body" > "$T_WD/teamgood/personas/agents/teamgood_char_role_persona.md"
_mk_project_git_root "$T_WD/teambad-projects/bad"
_mk_deployed_agents "$T_WD/teambad-projects/bad"
mkdir -p "$T_WD/teambad/personas/agents"
printf '%s\n' "---" "name: x" "---" "body" > "$T_WD/teambad/personas/agents/teambad_char_role_persona.md"
_mk_conf "$T_FW/share/teams" teamgood "true" "" "$T_WD/teamgood-projects"
_mk_conf "$T_FW/share/teams" teambad "true" "" "$T_WD/teambad-projects"
_seed_config "$T_WD" teamgood teambad
# Force teambad's deploy to fail: make its deployed .claude/agents dir
# read-only so the deployer's write into it fails (mkdir -p / cp) without
# touching the enumerator's own directory checks -- .claude/agents itself
# stays r-x so pt_enumerate_targets still emits it as a target; only the
# WRITE inside _deploy_core fails.
chmod 555 "$T_WD/teambad-projects/bad/.claude/agents"
_reset_deploy_globals
_REACHED_AFTER=false
(
    set -eo pipefail
    HOME="$T_HOME" AITEAMFORGE_DIR="$T_WD" FRAMEWORK_DIR="$T_FW" WORKING_DIR="$T_WD" DRY_RUN=false
    _install_print_stubs
    deploy_team_personas_to_projects
    echo "REACHED_AFTER_CALL" >> "$_STUB_LOG"
) >"$WORK_DIR/tc1.log" 2>&1
_RC=$?
chmod 755 "$T_WD/teambad-projects/bad/.claude/agents"
if [ "$_RC" -eq 0 ] \
    && grep -q "REACHED_AFTER_CALL" "$_STUB_LOG" \
    && grep -qE "1 target\(s\) refreshed, 0 skipped, 1 failed" "$_STUB_LOG"; then
    test_pass
else
    test_fail "expected rc=0, execution to continue past the call, and '1 refreshed, 1 failed' in summary; rc=$_RC stub log: $(cat "$_STUB_LOG"); log: $(cat "$WORK_DIR/tc1.log")"
fi

# TC2: deployer script missing entirely -> function returns 0 (does not
# abort the caller), HAD_WARNINGS=true, summary names the missing path.
test_start "TC2: deployer script missing at WORKING_DIR/scripts/... -> fn returns 0, HAD_WARNINGS=true, execution continues"
T_HOME="$(_next_sandbox)"; T_FW="$(_next_sandbox)"; T_WD="$(_next_sandbox)"
mkdir -p "$T_WD/scripts"   # deployer intentionally NOT copied here
_seed_config "$T_WD"
_reset_deploy_globals
(
    set -eo pipefail
    HOME="$T_HOME" AITEAMFORGE_DIR="$T_WD" FRAMEWORK_DIR="$T_FW" WORKING_DIR="$T_WD" DRY_RUN=false
    _install_print_stubs
    deploy_team_personas_to_projects
    echo "REACHED_AFTER_CALL" >> "$_STUB_LOG"
) >"$WORK_DIR/tc2.log" 2>&1
_RC=$?
if [ "$_RC" -eq 0 ] && grep -q "REACHED_AFTER_CALL" "$_STUB_LOG" && grep -qi "deploy-worktree-personas.sh not found" "$_STUB_LOG"; then
    test_pass
else
    test_fail "expected rc=0, continued execution, 'deploy-worktree-personas.sh not found' warning; rc=$_RC stub log: $(cat "$_STUB_LOG")"
fi

# TC3: genuine zero-target clean no-op is NOT swallowed silently -- an
# explicit "0 target(s)" summary is always printed (never nothing), success
# path (not a warning), HAD_WARNINGS stays false.
test_start "TC3: zero-target clean no-op prints an explicit '0 target(s)' success summary, never silence, HAD_WARNINGS stays false"
T_HOME="$(_next_sandbox)"; T_FW="$(_next_sandbox)"; T_WD="$(_next_sandbox)"
_seed_real_deployer "$T_WD"
mkdir -p "$T_FW/share/teams"
_mk_conf "$T_FW/share/teams" flat "" "" ""
_seed_config "$T_WD"
_reset_deploy_globals
(
    set -eo pipefail
    HOME="$T_HOME" AITEAMFORGE_DIR="$T_WD" FRAMEWORK_DIR="$T_FW" WORKING_DIR="$T_WD" DRY_RUN=false
    _install_print_stubs
    deploy_team_personas_to_projects
) >"$WORK_DIR/tc3.log" 2>&1
_RC=$?
if [ "$_RC" -eq 0 ] \
    && grep -qE "0 target\(s\) refreshed, 0 skipped, 0 failed, 0 uninspectable" "$_STUB_LOG" \
    && ! grep -qi "warning" "$WORK_DIR/tc3.log"; then
    test_pass
else
    test_fail "expected an explicit '0 target(s)' success line and no warnings; rc=$_RC stub log: $(cat "$_STUB_LOG")"
fi

# TC4: a deployed target whose team is ABSENT from .teams[] is still
# refreshed (never skipped) but triggers a distinct "config is incomplete"
# warning naming the team -- the §3.3 cross-check.
test_start "TC4: deployed target for a team absent from .teams[] is refreshed anyway, with a distinct 'config is incomplete' warning"
T_HOME="$(_next_sandbox)"; T_FW="$(_next_sandbox)"; T_WD="$(_next_sandbox)"
_seed_real_deployer "$T_WD"
_mk_project_git_root "$T_WD/proj/coparenting"
_mk_deployed_agents "$T_WD/proj/coparenting"
# S2: working-dir source -- what the deployer actually reads (AITEAMFORGE_DIR
# is set to $T_WD below, so this is ${AITEAMFORGE_DIR}/legal/personas/agents).
mkdir -p "$T_WD/legal/personas/agents"
printf '%s\n' "---" "name: x" "---" "REAL-CONTENT-v2" > "$T_WD/legal/personas/agents/legal_char_role_persona.md"
_mk_conf "$T_FW/share/teams" legal "true" "" "$T_WD/proj"
_seed_config "$T_WD" finance   # legal deliberately absent
_reset_deploy_globals
(
    set -eo pipefail
    HOME="$T_HOME" AITEAMFORGE_DIR="$T_WD" FRAMEWORK_DIR="$T_FW" WORKING_DIR="$T_WD" DRY_RUN=false
    _install_print_stubs
    deploy_team_personas_to_projects
) >"$WORK_DIR/tc4.log" 2>&1
_RC=$?
if [ "$_RC" -eq 0 ] \
    && grep -qE "1 target\(s\) refreshed, 0 skipped, 0 failed" "$_STUB_LOG" \
    && grep -qi "not listed in .aiteamforge-config .teams\[\]" "$_STUB_LOG" \
    && grep -q "REAL-CONTENT-v2" "$T_WD/proj/coparenting/.claude/agents/legal_char_role_persona.md" 2>/dev/null; then
    test_pass
else
    test_fail "expected 1 refreshed + a 'not listed in .teams[]' warning naming legal + REAL content actually deployed; deployed content: $(cat "$T_WD/proj/coparenting/.claude/agents/legal_char_role_persona.md" 2>/dev/null); stub log: $(cat "$_STUB_LOG")"
fi

# TC5: config missing entirely for the deploy step -> cross-check is
# skipped with ONE warning (config unreadable), but the sweep still
# proceeds and still refreshes the target (never blocks on the config).
test_start "TC5: missing .aiteamforge-config skips the cross-check (one warning) but the deploy sweep still proceeds"
T_HOME="$(_next_sandbox)"; T_FW="$(_next_sandbox)"; T_WD="$(_next_sandbox)"
_seed_real_deployer "$T_WD"
_mk_project_git_root "$T_WD/proj/coparenting"
_mk_deployed_agents "$T_WD/proj/coparenting"
mkdir -p "$T_WD/legal/personas/agents"
printf '%s\n' "---" "name: x" "---" "body" > "$T_WD/legal/personas/agents/legal_char_role_persona.md"
_mk_conf "$T_FW/share/teams" legal "true" "" "$T_WD/proj"
# NOTE: no .aiteamforge-config written at all in $T_WD
_reset_deploy_globals
(
    set -eo pipefail
    HOME="$T_HOME" AITEAMFORGE_DIR="$T_WD" FRAMEWORK_DIR="$T_FW" WORKING_DIR="$T_WD" DRY_RUN=false
    _install_print_stubs
    deploy_team_personas_to_projects
) >"$WORK_DIR/tc5.log" 2>&1
_RC=$?
if [ "$_RC" -eq 0 ] \
    && grep -qE "1 target\(s\) refreshed" "$_STUB_LOG" \
    && grep -qi "could not read .aiteamforge-config" "$_STUB_LOG"; then
    test_pass
else
    test_fail "expected 1 refreshed + a 'could not read config' warning, sweep not blocked; stub log: $(cat "$_STUB_LOG")"
fi

# TC6: path-safety guard -- a team whose id (derived from the conf's
# basename) contains characters outside [A-Za-z0-9_-] must be SKIPPED by
# _xaca0925_valid_team_id, never handed to the deployer subprocess.
test_start "TC6: a team id containing disallowed characters is skipped by the path-safety guard, never passed to the deployer"
T_HOME="$(_next_sandbox)"; T_FW="$(_next_sandbox)"; T_WD="$(_next_sandbox)"
# A canary deployer: if it is EVER invoked, it drops a tripwire file we can
# detect -- proves the guard actually prevents invocation, not just that the
# real deployer happens to reject the id gracefully.
mkdir -p "$T_WD/scripts"
cat > "$T_WD/scripts/deploy-worktree-personas.sh" <<EOF
#!/bin/bash
echo "INVOKED with args: \$*" >> "$WORK_DIR/tc6-canary.log"
exit 0
EOF
chmod +x "$T_WD/scripts/deploy-worktree-personas.sh"
_mk_project_git_root "$T_WD/proj/weird"
_mk_deployed_agents "$T_WD/proj/weird"
# ';' is a legal filesystem character but not a legal team-id character.
_mk_conf "$T_FW/share/teams" 'bad;team' "true" "" "$T_WD/proj"
_seed_config "$T_WD"
rm -f "$WORK_DIR/tc6-canary.log"
_reset_deploy_globals
(
    set -eo pipefail
    HOME="$T_HOME" AITEAMFORGE_DIR="$T_WD" FRAMEWORK_DIR="$T_FW" WORKING_DIR="$T_WD" DRY_RUN=false
    _install_print_stubs
    deploy_team_personas_to_projects
) >"$WORK_DIR/tc6.log" 2>&1
_RC=$?
if [ "$_RC" -eq 0 ] \
    && [ ! -f "$WORK_DIR/tc6-canary.log" ] \
    && grep -qi "path-safety guard" "$_STUB_LOG" \
    && grep -qE "0 target\(s\) refreshed, 1 skipped" "$_STUB_LOG"; then
    test_pass
else
    test_fail "expected the deployer to NEVER be invoked (no canary file), 1 skipped, path-safety warning; canary exists=$([ -f "$WORK_DIR/tc6-canary.log" ] && echo yes || echo no) stub log: $(cat "$_STUB_LOG")"
fi

# TC7: idempotency -- running the real deploy step TWICE against the same
# target must not duplicate the .git/info/exclude entry, and both runs
# must report success (the --force in XACA-0931-002 is unconditional, so
# this specifically exercises "does --force break the deployer's own
# idempotent-exclude guarantee").
test_start "TC7: running deploy_team_personas_to_projects twice does not duplicate .git/info/exclude entries"
T_HOME="$(_next_sandbox)"; T_FW="$(_next_sandbox)"; T_WD="$(_next_sandbox)"
_seed_real_deployer "$T_WD"
_mk_project_git_root "$T_WD/proj/coparenting"
_mk_deployed_agents "$T_WD/proj/coparenting"
mkdir -p "$T_WD/legal/personas/agents"
printf '%s\n' "---" "name: x" "---" "body" > "$T_WD/legal/personas/agents/legal_char_role_persona.md"
_mk_conf "$T_FW/share/teams" legal "true" "" "$T_WD/proj"
_seed_config "$T_WD" legal
_reset_deploy_globals
for _i in 1 2; do
    (
        set -eo pipefail
        HOME="$T_HOME" AITEAMFORGE_DIR="$T_WD" FRAMEWORK_DIR="$T_FW" WORKING_DIR="$T_WD" DRY_RUN=false
        _install_print_stubs
        deploy_team_personas_to_projects
    ) >"$WORK_DIR/tc7-run${_i}.log" 2>&1
done
EXCL_FILE="$T_WD/proj/coparenting/.git/info/exclude"
OCCURRENCES="$(grep -cxF ".claude/agents/" "$EXCL_FILE" 2>/dev/null || echo 0)"
if [ "$OCCURRENCES" = "1" ] && grep -qE "1 target\(s\) refreshed" "$_STUB_LOG"; then
    test_pass
else
    test_fail "expected exactly 1 occurrence of '.claude/agents/' after 2 runs; got $OCCURRENCES; exclude file: $(cat "$EXCL_FILE" 2>/dev/null)"
fi

# TC8: update_team_personas() union -- a team discovered ONLY via an
# on-disk deploy target (absent from .teams[], and its SOURCE dir does not
# yet exist) is repaired from the Cellar, with the distinct "repairing"
# warning (not the plain "config is incomplete" one used when SOURCE
# already exists) (XACA-0931-001 §3.4 branch ii).
test_start "TC8: update_team_personas repairs SOURCE from the Cellar for a discovered-but-unconfigured team with no prior SOURCE dir"
T_HOME="$(_next_sandbox)"; T_FW="$(_next_sandbox)"; T_WD="$(_next_sandbox)"
_mk_project_git_root "$T_WD/proj/general"
_mk_deployed_agents "$T_WD/proj/general" false
mkdir -p "$T_FW/share/personas/medical/agents"
printf '%s\n' "---" "name: x" "---" "CELLAR-CONTENT" > "$T_FW/share/personas/medical/agents/medical_char_role_persona.md"
_mk_conf "$T_FW/share/teams" medical "true" "" "$T_WD/proj"
_seed_config "$T_WD"   # medical absent from .teams[]
if [ -d "$T_WD/medical/personas/agents" ]; then
    test_fail "PRECONDITION FAILED: SOURCE dir already exists before the run"
else
    (
        set -eo pipefail
        HOME="$T_HOME" AITEAMFORGE_DIR="$T_WD" FRAMEWORK_DIR="$T_FW" WORKING_DIR="$T_WD" DRY_RUN=false
        _install_print_stubs
        update_team_personas
    ) >"$WORK_DIR/tc8.log" 2>&1
    _RC=$?
    if [ "$_RC" -eq 0 ] \
        && [ -f "$T_WD/medical/personas/agents/medical_char_role_persona.md" ] \
        && grep -q "CELLAR-CONTENT" "$T_WD/medical/personas/agents/medical_char_role_persona.md" \
        && grep -qi "repairing from the Cellar" "$_STUB_LOG"; then
        test_pass
    else
        test_fail "expected SOURCE created from Cellar + 'repairing' warning; rc=$_RC source exists=$([ -f "$T_WD/medical/personas/agents/medical_char_role_persona.md" ] && echo yes || echo no) stub log: $(cat "$_STUB_LOG")"
    fi
fi

# TC9: update_team_personas with ZERO configured AND zero discovered teams
# -> clean warning, return 0 (never fatal, never a crash).
test_start "TC9: update_team_personas with zero configured and zero discovered teams -> clean warning, returns 0"
T_HOME="$(_next_sandbox)"; T_FW="$(_next_sandbox)"; T_WD="$(_next_sandbox)"
mkdir -p "$T_FW/share/personas"
mkdir -p "$T_FW/share/teams"
_mk_conf "$T_FW/share/teams" flat "" "" ""
_seed_config "$T_WD"
(
    set -eo pipefail
    HOME="$T_HOME" AITEAMFORGE_DIR="$T_WD" FRAMEWORK_DIR="$T_FW" WORKING_DIR="$T_WD" DRY_RUN=false
    _install_print_stubs
    update_team_personas
) >"$WORK_DIR/tc9.log" 2>&1
_RC=$?
if [ "$_RC" -eq 0 ] && grep -qi "No configured or discovered teams found" "$_STUB_LOG"; then
    test_pass
else
    test_fail "expected rc=0 and 'No configured or discovered teams found'; rc=$_RC stub log: $(cat "$_STUB_LOG")"
fi

echo ""
echo "=== Part E: emit-transformed + S3 parity-check fail-closed behaviour ==="

# TE0: XACA-0340 mirror-sync gate. aiteamforge-persona-parity-check.sh
# resolves DEPLOY_SCRIPT as ITS OWN SIBLING (share/scripts/deploy-worktree-
# personas.sh -- the TAP MIRROR), never the dev-team canonical. As of this
# test run the canonical scripts/deploy-worktree-personas.sh has
# emit-transformed; the tap mirror does NOT yet (sync-tap.sh + the manual
# two-step is XACA-0931-005's sibling subitem 006's job, not run from here
# per this subitem's FORBIDDEN ACTIONS).
#
# MEASURED CONSEQUENCE of shipping in that state (see the XACA-0931-005 test
# report for the full repro): the OLD mirror script has no "emit-transformed"
# dispatch arm, so main() falls through to single-worktree deploy mode,
# treating the literal string "emit-transformed" as a worktree_path and the
# real source file as a team name. That path's guard rejects the bogus
# worktree_path and the whole invocation is a *safe* no-op (verified: no
# writes, exit 0) -- but exit 0 with a stray WARN line on STDOUT (not
# stderr) is exactly the input _check_s3_target's `expected_rc -ne 0` check
# cannot catch, so the checker proceeds to `cmp` deployed content against
# that garbage "expected" text and reports false DRIFT on every S3 file,
# on every target, always -- the precise "cries wolf" failure mode
# XACA-0931-001_decision.md §4.2 says is worse than no detector at all.
#
# This assertion is a MERGE GATE, not a style nit: it must be RED right now
# (documenting the current, pre-sync state honestly) and MUST turn green
# before/as part of delivery once the tap mirror is synced -- if it is still
# red at merge time, the S3 surface ships permanently broken on every
# consumer that has the new upgrade.sh/persona-targets.sh/parity-check.sh
# but the stale mirror (i.e. every consumer, until sync-tap.sh runs).
test_start "TE0 [MERGE GATE]: tap mirror share/scripts/deploy-worktree-personas.sh has emit-transformed (XACA-0340 sync required before/at delivery)"
if grep -q "emit-transformed" "$DEPLOY_SH" 2>/dev/null; then
    test_pass
else
    test_fail "share/scripts/deploy-worktree-personas.sh (the tap mirror aiteamforge-persona-parity-check.sh actually invokes) does NOT have emit-transformed yet -- canonical scripts/deploy-worktree-personas.sh does. Until './sync-tap.sh' + the manual two-step (XACA-0340, subitem 006) syncs it, the S3 surface will report false DRIFT on every deployed file, on every target, silently (exit 0 with a stray WARN line as the 'expected' comparison text) -- see this test's header comment for the full repro. This is EXPECTED to be red before subitem 006 delivers; it must be green at merge time."
fi

# The remaining Part E tests validate the S3 comparison LOGIC itself,
# independent of whether the mirror sync (TE0) has happened yet -- they run
# against a SCRATCH COPY of the parity checker with DEPLOY_SCRIPT repointed
# at the dev-team CANONICAL deploy script (the post-sync end state), so a
# logic bug isn't masked by, or confused with, the TE0 sync gap above. This
# never touches the real tap mirror file (shared with other sessions in this
# worktree) -- everything happens under TEST_TMP_DIR.
#
# The scratch copy must live TWO DIRECTORIES BELOW a libexec/lib sibling
# (share/scripts/<script> -> ../../libexec/lib), because the real script
# resolves LIB_DIR relative to its OWN location -- replicate that shape here
# with symlinks back to the real libs rather than flattening it, or the
# script's own `cd "$SCRIPT_DIR/../../libexec/lib"` fails outright.
mkdir -p "$WORK_DIR/scratch-tap/share/scripts" "$WORK_DIR/scratch-tap/libexec/lib"
ln -sf "$CONFIG_LIB" "$WORK_DIR/scratch-tap/libexec/lib/config.sh"
ln -sf "$PT_LIB" "$WORK_DIR/scratch-tap/libexec/lib/persona-targets.sh"
PARITY_SYNCED="$WORK_DIR/scratch-tap/share/scripts/aiteamforge-persona-parity-check.sh"
cp "$PARITY_SH" "$PARITY_SYNCED"
python3 - "$PARITY_SYNCED" "$DEPLOY_SH_REAL" <<'PYEOF'
import sys
p, real = sys.argv[1], sys.argv[2]
s = open(p).read()
old = 'DEPLOY_SCRIPT="${SCRIPT_DIR}/deploy-worktree-personas.sh"'
if old not in s:
    print("FATAL: anchor line not found in parity checker -- script structure changed", file=sys.stderr)
    sys.exit(1)
s = s.replace(old, f'DEPLOY_SCRIPT="{real}"  # XACA-0931-005 TEST OVERRIDE: see TE0')
open(p, 'w').write(s)
PYEOF
if [ ! -f "$PARITY_SYNCED" ] || ! grep -q "TEST OVERRIDE" "$PARITY_SYNCED"; then
    echo "FATAL: could not build the scratch synced-parity-checker fixture for Part E logic tests" >&2
    exit 1
fi
chmod +x "$PARITY_SYNCED"

# TE1: python3 unavailable -> emit-transformed exits 2 (uninspectable), and
# the parity checker treats that as a check FAILURE, NEVER falling back to
# a raw cmp against untransformed source (XACA-0931-001_decision §4.2).
test_start "TE1: python3 unavailable -> emit-transformed exits 2, and the parity checker fails closed (never a raw-cmp fallback)"
T_SRC="$(_next_sandbox)/src.md"
printf '%s\n' "---" "name: role" "---" "body" > "$T_SRC"
NO_PY_BIN="$WORK_DIR/no-python-bin"
mkdir -p "$NO_PY_BIN"
# Symlink through every real PATH entry EXCEPT python3/python, so bash/git/etc
# stay resolvable but the transform's `python3` lookup fails.
OLD_IFS="$IFS"; IFS=':'
for _d in $PATH; do
    [ -d "$_d" ] || continue
    for _f in "$_d"/*; do
        _b="$(basename "$_f")"
        case "$_b" in python3|python) continue ;; esac
        [ -e "$NO_PY_BIN/$_b" ] || ln -sf "$_f" "$NO_PY_BIN/$_b" 2>/dev/null
    done
done
IFS="$OLD_IFS"
ET_OUT="$(PATH="$NO_PY_BIN" "$DEPLOY_SH_REAL" emit-transformed "$T_SRC" 2>"$WORK_DIR/te1-stderr.log")"
ET_RC=$?
if [ "$ET_RC" -eq 2 ]; then
    test_pass
else
    test_fail "expected emit-transformed to exit 2 when python3 is unavailable; got rc=$ET_RC out=[$ET_OUT] stderr=$(cat "$WORK_DIR/te1-stderr.log")"
fi

# TE1b: now drive the SAME python3-less condition through the real parity
# checker end-to-end and confirm it reports a check FAILURE for that file,
# distinguishable from ordinary DRIFT, and never silently passes.
test_start "TE1b: aiteamforge-persona-parity-check.sh fails closed (not silently clean) when python3 is unavailable for an S3 target"
T_FW="$(_next_sandbox)"; T_WD="$(_next_sandbox)"; T_HOME="$(_next_sandbox)"
mkdir -p "$T_WD/legal/personas/agents"
printf '%s\n' "---" "name: role" "---" "body" > "$T_WD/legal/personas/agents/legal_char_role_persona.md"
_mk_project_git_root "$T_WD/proj/coparenting"
_mk_deployed_agents "$T_WD/proj/coparenting"
# Make the deployed content match what emit-transformed WOULD produce (clean
# S3 under normal conditions), so a failure below is attributable ONLY to
# python3 being unavailable, not to genuine drift.
cp "$T_WD/legal/personas/agents/legal_char_role_persona.md" "$T_WD/proj/coparenting/.claude/agents/legal_char_role_persona.md"
sed -i.bak 's/^name: role$/name: char/' "$T_WD/proj/coparenting/.claude/agents/legal_char_role_persona.md" 2>/dev/null || true
rm -f "$T_WD/proj/coparenting/.claude/agents/legal_char_role_persona.md.bak"
_mk_conf "$T_FW/share/teams" legal "true" "" "$T_WD/proj"
_seed_config "$T_WD" legal
PARITY_OUT="$(HOME="$T_HOME" AITEAMFORGE_DIR="$T_WD" PATH="$NO_PY_BIN" "$PARITY_SYNCED" --working-dir "$T_WD" --framework-dir "$T_FW" 2>&1)"
PARITY_RC=$?
if [ "$PARITY_RC" -eq 1 ] && printf '%s' "$PARITY_OUT" | grep -qi "could not compute the expected transform"; then
    test_pass
else
    test_fail "expected exit 1 with a 'could not compute the expected transform' diagnostic; got rc=$PARITY_RC out=$PARITY_OUT"
fi

# TE2: a deployed target with NO working-dir source at all -> every deployed
# file is reported as an orphan (informational), not drift by itself.
test_start "TE2: S3 files with no S2 source counterpart are reported as orphans (WARN), not DRIFT"
T_FW="$(_next_sandbox)"; T_WD="$(_next_sandbox)"; T_HOME="$(_next_sandbox)"
_mk_project_git_root "$T_WD/proj/orphanteam"
mkdir -p "$T_WD/proj/orphanteam/.claude/agents"
printf '%s\n' "---" "name: x" "---" "body" > "$T_WD/proj/orphanteam/.claude/agents/orphanteam_char_role_persona.md"
_mk_conf "$T_FW/share/teams" orphanteam "true" "" "$T_WD/proj"
_seed_config "$T_WD"
PARITY_OUT="$(HOME="$T_HOME" AITEAMFORGE_DIR="$T_WD" "$PARITY_SYNCED" --working-dir "$T_WD" --framework-dir "$T_FW" 2>&1)"
PARITY_RC=$?
if [ "$PARITY_RC" -eq 0 ] && printf '%s' "$PARITY_OUT" | grep -qi "orphan"; then
    test_pass
else
    test_fail "expected exit 0 with an orphan WARN line (no working-dir source at all is not drift by itself); got rc=$PARITY_RC out=$PARITY_OUT"
fi

# TE3 (XACA-0931-005 finding 1, regression): an EMPTY `.teams[]` must not
# short-circuit the S3 surface. The checker used to `exit 0` at its "no
# configured teams" guard BEFORE reaching the deployed-vs-source block, which
# made S3 unreachable on exactly the boxes whose config is incomplete — the
# population this ticket exists to serve. TE2 above catches this only
# incidentally (its orphan path also exits 0); this test asserts the invariant
# directly by planting GENUINE drift and requiring a non-zero exit, which is
# only reachable if S3 actually ran.
test_start "TE3: empty .teams[] still runs the deployed-vs-source surface (real drift -> exit 1, not a silent exit 0)"
T_FW="$(_next_sandbox)"; T_WD="$(_next_sandbox)"; T_HOME="$(_next_sandbox)"
mkdir -p "$T_WD/legal/personas/agents"
printf '%s\n' "---" "name: role" "---" "SOURCE BODY" > "$T_WD/legal/personas/agents/legal_char_role_persona.md"
_mk_project_git_root "$T_WD/proj/coparenting"
mkdir -p "$T_WD/proj/coparenting/.claude/agents"
# Correct transformed name, but a DIFFERENT body -> unambiguous real drift that
# no name-line-ignoring comparison can explain away.
printf '%s\n' "---" "name: char" "---" "DEPLOYED BODY IS DIFFERENT" > "$T_WD/proj/coparenting/.claude/agents/legal_char_role_persona.md"
_mk_conf "$T_FW/share/teams" legal "true" "" "$T_WD/proj"
_seed_config "$T_WD"          # NOTE: no team args -> writes "teams": []
PARITY_OUT="$(HOME="$T_HOME" AITEAMFORGE_DIR="$T_WD" "$PARITY_SYNCED" --working-dir "$T_WD" --framework-dir "$T_FW" 2>&1)"
PARITY_RC=$?
if [ "$PARITY_RC" -eq 1 ]; then
    test_pass
else
    test_fail "expected exit 1 (S3 drift detected despite empty .teams[]); got rc=$PARITY_RC. An exit 0 here means the empty-teams guard short-circuited before the deployed-vs-source surface ran. out=$PARITY_OUT"
fi

echo ""
echo "=== Part G: /bin/bash 3.2 sanity (this whole suite already runs under it; spot-check array/read semantics) ==="

test_start "TG1: bash version under test is actually 3.2.x (not silently re-execed under a newer PATH bash)"
_BV="${BASH_VERSION%%.*}"
if [ "$_BV" = "3" ]; then
    test_pass
else
    test_fail "expected BASH_VERSION major=3 (target /bin/bash 3.2); got BASH_VERSION=$BASH_VERSION -- this suite must be invoked as '/bin/bash tests/test-xaca-0931-...' not via a PATH bash"
fi

test_start "TG2: pt_enumerate_targets's array usage (\${confs[@]}, \${#confs[@]}) behaves correctly under 3.2 with an empty array"
T_FW="$(_next_sandbox)"
mkdir -p "$T_FW/share/teams"
OUT="$(_run_pt "$T_FW")"
CNT="$(_pt_uninspectable_count "$OUT")"
if [ "$CNT" = "1" ]; then
    test_pass
else
    test_fail "empty-array path under bash 3.2 misbehaved; got CNT=$CNT"
fi

echo ""
if [ "$_STANDALONE" = true ]; then
    echo "Results: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    [ "$_FAIL_COUNT" -eq 0 ]
fi
