#!/bin/bash
# test-xaca-0770-local-only-knowledge-in-tap.sh
#
# XACA-0770: ports dev-team/kanban-helpers.sh's local-only team knowledge
# (PII containment, XACA-0754/XACA-0754-013/XACA-0754-014) into BOTH shipped
# helper files. Before this ticket, finance/legal/medical knowledge authored
# on a tap host (e.g. M4Mini) had ZERO local routing — kb-knowledge-add wrote
# every tier straight to the synced ~/knowledge root, leaking PII fleet-wide
# on the next sync-daemon run. This test proves both shipped files now:
#
#   1. Define the full local-routing function roster (parity).
#   2. Route finance/legal/medical team- and agent-tier writes to
#      KB_KNOWLEDGE_LOCAL_ROOT (never the synced global root) using ONLY the
#      hardcoded floors — no ~/dev-team/.claude/agents-master checkout
#      exists anywhere in this sandbox, proving the floors (not the
#      agents-master scan) are what protects a bare tap machine.
#   3. Route subject-tier writes to local_root when the CURRENT SESSION's
#      team is local-only, and to global_root when it is a normal shareable
#      team (over-containment is the safe default; shareable teams must stay
#      frictionless).
#   4. Enforce the --force ambiguous-context guard on the fallback template
#      file (which has a real tmux/env-based _kb_detect_context that CAN
#      fail to resolve) — refuses an ambiguous subject-tier write without
#      --force, allows it through to global with --force.
#   5. kb-knowledge-local-scaffold idempotently builds the local team +
#      hardcoded-persona INDEX.md tree.
#   6. kb-knowledge-search and kb-knowledge-reindex both discover/rebuild
#      entries living under the local root.
#
# Mirrors test-xaca-0746-kb-knowledge-in-tap.sh's structure/harness exactly
# (same _run_zsh sandbox pattern, same PartA=aliases/PartB=template split).
#
# Requires: bash, zsh. No dev-team checkout, no tmux, no network.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ALIASES_PATH="$TAP_ROOT/share/templates/aliases/kanban-aliases.sh"
TEMPLATE_PATH="$TAP_ROOT/share/templates/kanban/kanban-helpers.template.sh"

if [ ! -f "$ALIASES_PATH" ]; then
    echo "FATAL: kanban-aliases.sh not found at: $ALIASES_PATH" >&2
    exit 1
fi
if [ ! -f "$TEMPLATE_PATH" ]; then
    echo "FATAL: kanban-helpers.template.sh not found at: $TEMPLATE_PATH" >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework (mirrors test-xaca-0746's pattern).
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
fi

if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca0770-local-knowledge-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
TEST_TMP_DIR="$(cd "$TEST_TMP_DIR" && pwd -P)"
WORK_DIR="$TEST_TMP_DIR/xaca0770"
mkdir -p "$WORK_DIR"

cleanup() {
    if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then
        rm -rf "$TEST_TMP_DIR"
    fi
}
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Render both shipped files (placeholder substitution — same as XACA-0746).
# ─────────────────────────────────────────────────────────────────────────────
A_RENDERED="$WORK_DIR/kanban-aliases-rendered.sh"
sed "s|{{AITEAMFORGE_DIR}}|$WORK_DIR/aiteamforge|g; \
     s|{{SHARED_DEV_ROOT}}|$WORK_DIR/shared|g; \
     s|{{ORG_NAME}}|TestOrg|g; \
     s|{{ORG_SLUG}}|testorg|g" \
    "$ALIASES_PATH" > "$A_RENDERED"

B_RENDERED="$WORK_DIR/kanban-helpers-template-rendered.sh"
sed "s|{{AITEAMFORGE_DIR}}|$WORK_DIR/aiteamforge|g; \
     s|{{SHARED_DEV_ROOT}}|$WORK_DIR/shared|g; \
     s|{{ORG_NAME}}|TestOrg|g; \
     s|{{ORG_SLUG}}|testorg|g" \
    "$TEMPLATE_PATH" > "$B_RENDERED"

# The local-routing function roster ported by XACA-0770 (12 privates + 1 public).
LOCAL_ROUTING_FNS=(
    _kb_overlay_config_path
    _kb_knowledge_local_root
    _kb_local_only_teams_hardcoded
    _kb_local_personas_hardcoded
    _kb_is_local_only_team
    _kb_current_session_is_local_only_team
    _kb_context_resolved
    _kb_ambiguous_tier_write_guard
    _kb_local_team_persona_group
    _kb_local_personas_for_team
    _kb_is_local_persona
    _kb_knowledge_project_path_effective
    kb-knowledge-local-scaffold
)

STDOUT_FILE="$WORK_DIR/stdout.txt"
STDERR_FILE="$WORK_DIR/stderr.txt"

# _run_zsh <rendered_file> <home_dir> <global_root> <local_root> <extra_env...;> <code...>
# extra_env is a single string of "VAR=val VAR2=val2" tokens (word-split by env -i),
# or empty. Sandboxed: env -i, no dev-team, no tmux, no network.
_run_zsh() {
    local rendered_file="$1" home_dir="$2" global_root="$3" local_root="$4" extra_env="$5"
    shift 5
    env -i \
        HOME="$home_dir" \
        PATH="$PATH" \
        TERM="${TERM:-dumb}" \
        KB_KNOWLEDGE_GLOBAL_ROOT="$global_root" \
        KB_KNOWLEDGE_LOCAL_ROOT="$local_root" \
        KB_SEARCH_TELEMETRY_DISABLED=1 \
        $extra_env \
        zsh -c "
            cd '$home_dir' 2>/dev/null
            source '$rendered_file' >/dev/null 2>/dev/null
            $*
        " >"$STDOUT_FILE" 2>"$STDERR_FILE"
}
_stdout() { cat "$STDOUT_FILE" 2>/dev/null; }
_stderr() { cat "$STDERR_FILE" 2>/dev/null; }
_rc() { echo "$?"; }

_next_home() { mktemp -d "$WORK_DIR/home-XXXXXX"; }

# Sanity: confirm no ~/dev-team checkout exists anywhere sandboxed homes could
# see it (proves the agents-master fallback genuinely has nothing to read).
if [ -d "$HOME/dev-team/.claude/agents-master" ]; then
    : # Real dev-team checkout on this machine is irrelevant — sandboxed HOME
      # is redirected via env -i above, so ${HOME}/dev-team never resolves to
      # the real checkout inside the sandboxed zsh subshells regardless.
fi

_assert_all_defined() {
    local label="$1" rendered_file="$2"
    local home_dir global_root local_root
    home_dir=$(_next_home)
    global_root="$home_dir/knowledge"
    local_root="$home_dir/knowledge-local"

    local fn missing=()
    for fn in "${LOCAL_ROUTING_FNS[@]}"; do
        _run_zsh "$rendered_file" "$home_dir" "$global_root" "$local_root" "" "typeset -f $fn >/dev/null 2>&1 && echo DEFINED || echo MISSING"
        if [ "$(_stdout | tr -d '[:space:]')" != "DEFINED" ]; then
            missing+=("$fn")
        fi
    done

    test_start "$label: all ${#LOCAL_ROUTING_FNS[@]} local-routing functions are defined (parity)"
    if [ ${#missing[@]} -eq 0 ]; then
        test_pass
    else
        test_fail "missing: ${missing[*]}"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Shared test bodies — parameterized by (label, rendered_file, team_env_var)
# team_env_var is the var this file's context resolver actually reads for an
# explicit team override: KANBAN_TEAM (aliases.sh's own _kb_get_team) vs
# KB_TEAM (template.sh's _kb_detect_context, via _kb_resolve_explicit_env_context).
# ═══════════════════════════════════════════════════════════════════════════
_run_shared_suite() {
    local label="$1" rendered_file="$2" team_env_var="$3"

    _assert_all_defined "$label" "$rendered_file"

    # ── team-tier: finance-personal routes to local_root, no session context needed ──
    test_start "$label: kb-knowledge-add team finance-personal routes to local_root (hardcoded floor, no agents-master)"
    local h1 g1 l1
    h1=$(_next_home); g1="$h1/knowledge"; l1="$h1/knowledge-local"
    _run_zsh "$rendered_file" "$h1" "$g1" "$l1" "" \
        "kb-knowledge-add team finance-personal 'client tax filing note'"
    local f1
    f1=$(find "$l1/teams/finance-personal" -maxdepth 1 -name 't001-*.md' 2>/dev/null | head -1)
    if [ -n "$f1" ] && [ -f "$f1" ] && [ ! -d "$g1/teams/finance-personal" ]; then
        test_pass
    else
        test_fail "expected t001-*.md under $l1/teams/finance-personal and NO $g1/teams/finance-personal dir; stdout=$(_stdout) stderr=$(_stderr) found='$f1'"
    fi

    # ── agent-tier: a hardcoded-floor persona (brunt, finance-personal) routes local ──
    test_start "$label: kb-knowledge-add agent brunt (hardcoded persona floor) routes to local_root, no dev-team checkout present"
    local h2 g2 l2
    h2=$(_next_home); g2="$h2/knowledge"; l2="$h2/knowledge-local"
    _run_zsh "$rendered_file" "$h2" "$g2" "$l2" "" \
        "kb-knowledge-add agent brunt 'irs correspondence tracker'"
    local f2
    f2=$(find "$l2/agents/brunt" -maxdepth 1 -name 'k001-*.md' 2>/dev/null | head -1)
    if [ -n "$f2" ] && [ -f "$f2" ] && [ ! -d "$g2/agents/brunt" ]; then
        test_pass
    else
        test_fail "expected k001-*.md under $l2/agents/brunt and NO $g2/agents/brunt dir; stdout=$(_stdout) stderr=$(_stderr) found='$f2'"
    fi

    # ── agent-tier: a NON-local persona still routes to global (no over-containment) ──
    test_start "$label: kb-knowledge-add agent emh (non-local persona) still routes to global_root"
    local h3 g3 l3
    h3=$(_next_home); g3="$h3/knowledge"; l3="$h3/knowledge-local"
    _run_zsh "$rendered_file" "$h3" "$g3" "$l3" "" \
        "kb-knowledge-add agent emh 'ordinary shareable note'"
    local f3
    f3=$(find "$g3/agents/emh" -maxdepth 1 -name 'k001-*.md' 2>/dev/null | head -1)
    if [ -n "$f3" ] && [ -f "$f3" ] && [ ! -d "$l3/agents/emh" ]; then
        test_pass
    else
        test_fail "expected k001-*.md under $g3/agents/emh and NO $l3/agents/emh dir; stdout=$(_stdout) stderr=$(_stderr) found='$f3'"
    fi

    # ── subject-tier: LOCAL-ONLY session team routes subject write to local_root ──
    test_start "$label: kb-knowledge-add subject (session team=legal-coparenting) routes to local_root"
    local h4 g4 l4
    h4=$(_next_home); g4="$h4/knowledge"; l4="$h4/knowledge-local"
    _run_zsh "$rendered_file" "$h4" "$g4" "$l4" "${team_env_var}=legal-coparenting" \
        "kb-knowledge-add subject custody-schedule 'holiday rotation notes'"
    local f4
    f4=$(find "$l4/subjects/custody-schedule" -maxdepth 1 -name 's001-*.md' 2>/dev/null | head -1)
    if [ -n "$f4" ] && [ -f "$f4" ] && [ ! -d "$g4/subjects/custody-schedule" ]; then
        test_pass
    else
        test_fail "expected s001-*.md under $l4/subjects/custody-schedule and NO $g4/subjects/custody-schedule dir; stdout=$(_stdout) stderr=$(_stderr) found='$f4'"
    fi

    # ── subject-tier: SHAREABLE session team routes subject write to global_root ──
    test_start "$label: kb-knowledge-add subject (session team=academy, shareable) still routes to global_root"
    local h5 g5 l5
    h5=$(_next_home); g5="$h5/knowledge"; l5="$h5/knowledge-local"
    _run_zsh "$rendered_file" "$h5" "$g5" "$l5" "${team_env_var}=academy" \
        "kb-knowledge-add subject shell-scripting 'ordinary shareable topic'"
    local f5
    f5=$(find "$g5/subjects/shell-scripting" -maxdepth 1 -name 's001-*.md' 2>/dev/null | head -1)
    if [ -n "$f5" ] && [ -f "$f5" ] && [ ! -d "$l5/subjects/shell-scripting" ]; then
        test_pass
    else
        test_fail "expected s001-*.md under $g5/subjects/shell-scripting and NO $l5/subjects/shell-scripting dir; stdout=$(_stdout) stderr=$(_stderr) found='$f5'"
    fi

    # ── kb-knowledge-local-scaffold builds the local team+persona INDEX tree ──
    test_start "$label: kb-knowledge-local-scaffold builds team + hardcoded-persona INDEX.md tree"
    local h6 g6 l6
    h6=$(_next_home); g6="$h6/knowledge"; l6="$h6/knowledge-local"
    _run_zsh "$rendered_file" "$h6" "$g6" "$l6" "" \
        "kb-knowledge-local-scaffold"
    if [ -f "$l6/teams/finance-personal/INDEX.md" ] \
        && [ -f "$l6/teams/legal-coparenting/INDEX.md" ] \
        && [ -f "$l6/teams/medical-general/INDEX.md" ] \
        && [ -f "$l6/agents/brunt/INDEX.md" ] \
        && [ -f "$l6/agents/advocate/INDEX.md" ] \
        && [ -f "$l6/agents/house/INDEX.md" ]; then
        test_pass
    else
        test_fail "expected team INDEX.md x3 + persona INDEX.md (brunt/advocate/house) under $l6; stdout=$(_stdout) stderr=$(_stderr); tree=$(find "$l6" -name INDEX.md 2>/dev/null)"
    fi

    # ── kb-knowledge-search finds a local-root entry via --agent ────────────
    test_start "$label: kb-knowledge-search --agent brunt finds the local-root entry"
    local h7 g7 l7
    h7=$(_next_home); g7="$h7/knowledge"; l7="$h7/knowledge-local"
    _run_zsh "$rendered_file" "$h7" "$g7" "$l7" "" \
        "kb-knowledge-add agent brunt 'quarterly estimate reminder'; kb-knowledge-search 'quarterly estimate' --agent brunt --porcelain"
    local out7
    out7="$(_stdout)"
    if echo "$out7" | grep -q '^agent:brunt'; then
        test_pass
    else
        test_fail "expected an agent:brunt porcelain line from the local-root search merge; got: $out7 (stderr=$(_stderr))"
    fi

    # ── kb-knowledge-reindex rebuilds INDEX.md for a local-root team dir ────
    test_start "$label: kb-knowledge-reindex (no args, full sweep) rebuilds INDEX.md under local_root/teams"
    local h8 g8 l8
    h8=$(_next_home); g8="$h8/knowledge"; l8="$h8/knowledge-local"
    _run_zsh "$rendered_file" "$h8" "$g8" "$l8" "" \
        "kb-knowledge-add team medical-general 'lab result follow-up'; kb-knowledge-reindex"
    if [ -f "$l8/teams/medical-general/INDEX.md" ] && grep -q 'T001' "$l8/teams/medical-general/INDEX.md"; then
        test_pass
    else
        test_fail "expected local_root/teams/medical-general/INDEX.md with a T001 entry; stdout=$(_stdout) stderr=$(_stderr)"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# PART A — kanban-aliases.sh (FALLBACK installed file as of XACA-1095; _kb_get_team
#          resolver). Until XACA-1095 this file was PREFERRED by both
#          install_kanban_helpers and update_shell_helpers; that preference is now
#          inverted in favour of kanban-helpers.template.sh, and this file is
#          selected only when the template is absent. The contract below is still
#          worth testing — the file is still shipped — but it is no longer what a
#          real consumer receives.
# ═══════════════════════════════════════════════════════════════════════════
_run_shared_suite "PartA(aliases)" "$A_RENDERED" "KANBAN_TEAM"

# ── A-guard: aliases.sh's _kb_get_team ALWAYS resolves (KANBAN_TEAM defaults
# to "academy"), so the ambiguous-tier-write-guard is a documented no-op here
# — a subject-tier write with NO team env set at all still succeeds (lands
# in global, since the default "academy" is non-local). This is the expected
# consequence of this file's single-env-var team model (see the port's
# _kb_context_resolved comment) — proving it does NOT regress into an
# unexpected refusal for the common no-KANBAN_TEAM-set case.
test_start "PartA(aliases): subject-tier add succeeds with NO team env set at all (defaults to academy, non-local, guard no-ops)"
A_G_HOME=$(_next_home); A_G_GLOBAL="$A_G_HOME/knowledge"; A_G_LOCAL="$A_G_HOME/knowledge-local"
_run_zsh "$A_RENDERED" "$A_G_HOME" "$A_G_GLOBAL" "$A_G_LOCAL" "" \
    "kb-knowledge-add subject default-team-check 'no override needed'; echo RC=\$?"
A_G_OUT="$(_stdout)"
A_G_FILE=$(find "$A_G_GLOBAL/subjects/default-team-check" -maxdepth 1 -name 's001-*.md' 2>/dev/null | head -1)
if echo "$A_G_OUT" | grep -q 'RC=0' && [ -n "$A_G_FILE" ]; then
    test_pass
else
    test_fail "expected RC=0 and a scaffolded file under $A_G_GLOBAL/subjects/default-team-check; got: $A_G_OUT (stderr=$(_stderr))"
fi

# ═══════════════════════════════════════════════════════════════════════════
# PART B — kanban-helpers.template.sh (FALLBACK file, _kb_detect_context resolver)
# ═══════════════════════════════════════════════════════════════════════════
_run_shared_suite "PartB(template)" "$B_RENDERED" "KB_TEAM"

# ── B-guard-1: ambiguous context (no tmux, no KB_TEAM/LCARS_TEAM/AITEAMFORGE_TEAM)
# refuses a subject-tier write WITHOUT --force.
test_start "PartB(template): subject-tier add is REFUSED when context is unresolvable and --force is absent"
B_G1_HOME=$(_next_home); B_G1_GLOBAL="$B_G1_HOME/knowledge"; B_G1_LOCAL="$B_G1_HOME/knowledge-local"
_run_zsh "$B_RENDERED" "$B_G1_HOME" "$B_G1_GLOBAL" "$B_G1_LOCAL" "" \
    "kb-knowledge-add subject ambiguous-check 'should be refused'; echo RC=\$?"
B_G1_OUT="$(_stdout)"
B_G1_ERR="$(_stderr)"
B_G1_RC=$(echo "$B_G1_OUT" | grep -oE 'RC=[0-9]+' | tail -1 | cut -d= -f2)
if [ "$B_G1_RC" != "0" ] \
    && [ ! -d "$B_G1_GLOBAL/subjects/ambiguous-check" ] \
    && [ ! -d "$B_G1_LOCAL/subjects/ambiguous-check" ] \
    && echo "$B_G1_ERR" | grep -qi "could not resolve the current session's team"; then
    test_pass
else
    test_fail "expected nonzero RC, no scaffolded dir in either root, and a refusal message; rc=$B_G1_RC stdout=$B_G1_OUT stderr=$B_G1_ERR"
fi

# ── B-guard-2: same ambiguous context, but --force proceeds to the SHARED/global root ──
test_start "PartB(template): --force proceeds to the shared/global root despite unresolvable context (with a warning)"
B_G2_HOME=$(_next_home); B_G2_GLOBAL="$B_G2_HOME/knowledge"; B_G2_LOCAL="$B_G2_HOME/knowledge-local"
_run_zsh "$B_RENDERED" "$B_G2_HOME" "$B_G2_GLOBAL" "$B_G2_LOCAL" "" \
    "kb-knowledge-add subject forced-check 'proceeds anyway' --force; echo RC=\$?"
B_G2_OUT="$(_stdout)"
B_G2_ERR="$(_stderr)"
B_G2_RC=$(echo "$B_G2_OUT" | grep -oE 'RC=[0-9]+' | tail -1 | cut -d= -f2)
B_G2_FILE=$(find "$B_G2_GLOBAL/subjects/forced-check" -maxdepth 1 -name 's001-*.md' 2>/dev/null | head -1)
if [ "$B_G2_RC" = "0" ] && [ -n "$B_G2_FILE" ] && [ ! -d "$B_G2_LOCAL/subjects/forced-check" ] \
    && echo "$B_G2_ERR" | grep -qi "Proceeding to the SHARED/synced knowledge root anyway because --force"; then
    test_pass
else
    test_fail "expected RC=0, a file under $B_G2_GLOBAL/subjects/forced-check, no local dir, and a --force warning; rc=$B_G2_RC stdout=$B_G2_OUT stderr=$B_G2_ERR found='$B_G2_FILE'"
fi

# ── B-guard-3: team-paths.json "local_only":true flag extends protection to a NEW team ──
test_start "PartB(template): team-paths.json local_only:true flag routes a non-hardcoded team to local_root"
B_G3_HOME=$(_next_home); B_G3_GLOBAL="$B_G3_HOME/knowledge"; B_G3_LOCAL="$B_G3_HOME/knowledge-local"
mkdir -p "$B_G3_HOME/.aiteamforge"
cat > "$B_G3_HOME/.aiteamforge/team-paths.json" <<'JSONEOF'
{"teams": {"newteam-personal": {"local_only": true}}}
JSONEOF
_run_zsh "$B_RENDERED" "$B_G3_HOME" "$B_G3_GLOBAL" "$B_G3_LOCAL" "" \
    "kb-knowledge-add team newteam-personal 'flag-extended team'"
B_G3_FILE=$(find "$B_G3_LOCAL/teams/newteam-personal" -maxdepth 1 -name 't001-*.md' 2>/dev/null | head -1)
if [ -n "$B_G3_FILE" ] && [ ! -d "$B_G3_GLOBAL/teams/newteam-personal" ]; then
    test_pass
else
    test_fail "expected t001-*.md under $B_G3_LOCAL/teams/newteam-personal (via local_only flag) and no global dir; stdout=$(_stdout) stderr=$(_stderr) found='$B_G3_FILE'"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "Results: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    if [ "$_FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
fi
exit 0
