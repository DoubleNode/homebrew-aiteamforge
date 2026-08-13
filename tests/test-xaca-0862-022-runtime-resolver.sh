#!/bin/bash
# test-xaca-0862-022-runtime-resolver.sh
#
# XACA-0862 (subitems -022 and -026, PROTECTED [Review] gates).
#
# Automated coverage for the RUNTIME resolver functions baked into every
# rendered parametric connect script —
# scripts/templates/team-connect-parametric.sh.template's
# _xaca0862_resolve_default_project() and _xaca0862_resolve_default_group().
# Before this suite, these functions had ZERO automated coverage: they were
# the actual fix for this ticket's originating bug (legal-connect.sh <host>
# silently targeting a nonexistent "legal-default" instance), they run on
# EVERY parametric connect invocation, and they feed a value into an SSH
# command string — guarded only by manual sandbox runs recorded in a PR
# review comment. A schema rename (e.g. "kanban_dir" -> something else)
# could silently revert every parametric connect script to the XACA-0862 bug
# with no CI signal. This suite closes that gap.
#
# EXTRACTION TECHNIQUE: both bots that reviewed PR #744 independently
# verified this code by extracting the function VERBATIM (via awk, byte for
# byte) from a rendered connect script and driving it directly — not a hand
# copy, not a paraphrase. This suite does the same, but extracts from the
# CANONICAL mirrored template at $TAP_ROOT/share/templates/ rather than an
# outer-repo rendered *-connect.sh, so the tap test suite stays entirely
# self-contained (no dependency on the outer dev-team repo's committed
# cockpit scripts, which a plain `brew install aiteamforge` consumer would
# not have checked out alongside this repo). The function bodies contain no
# {{PLACEHOLDER}} substitutions, so extracting from the unrendered template
# is byte-identical to extracting from any of its rendered instances.
#
# CONTRACT UNDER TEST (XACA-0862-023, unified across all three resolvers —
# see check-resolve-cochange-guard.sh's header):
#   exactly 1 filesystem-verified match (working_dir AND kanban_dir both
#     exist as real directories, remainder matches ^[a-z0-9_]+$) -> resolve.
#   0 or >1 matches -> leave empty; NEVER guess.
#   Any failure (missing/unreadable/malformed registry, absent python3,
#     missing kanban_dir/working_dir) -> degrade to 0 matches, NEVER crash.
#
# Runs standalone (`bash tests/test-xaca-0862-022-runtime-resolver.sh`) OR
# via test-runner.sh. Exit 0 = all pass, exit 1 = any fail.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONNECT_TEMPLATE="$TAP_ROOT/share/templates/team-connect-parametric.sh.template"

if [ ! -f "$CONNECT_TEMPLATE" ]; then
    echo "FATAL: required file not found: $CONNECT_TEMPLATE" >&2
    exit 1
fi

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
    test_fail()  { _FAIL_COUNT=$((_FAIL_COUNT + 1)); echo "     FAIL: $_CURRENT_TEST — $1" >&2; }
fi

# ─────────────────────────────────────────────────────────────────────────────
# Temp directory (runner-supplied or our own). Never touches real $HOME.
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca0862022-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
cleanup() { if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ] && [ -d "${TEST_TMP_DIR:-}" ]; then find "$TEST_TMP_DIR" -depth -delete 2>/dev/null || true; fi; }
trap cleanup EXIT

WORK_DIR="$TEST_TMP_DIR/xaca0862022"
mkdir -p "$WORK_DIR"
_next_sandbox() { mktemp -d "$WORK_DIR/sbx-XXXXXX"; }

# ─────────────────────────────────────────────────────────────────────────────
# Extraction: pull _xaca0862_resolve_default_project() and
# _xaca0862_resolve_default_group() verbatim out of the template (same awk
# recipe as check-resolve-cochange-guard.sh's _extract_body).
# ─────────────────────────────────────────────────────────────────────────────
_extract_fn() {
    awk -v fn="$1" '
      $0 ~ ("^" fn "\\(\\) \\{") { capture=1 }
      capture { print }
      capture && /^}$/ { exit }
    ' "$CONNECT_TEMPLATE"
}

PROJECT_FN_SRC="$WORK_DIR/resolve_default_project.extracted.sh"
GROUP_FN_SRC="$WORK_DIR/resolve_default_group.extracted.sh"
_extract_fn _xaca0862_resolve_default_project > "$PROJECT_FN_SRC"
_extract_fn _xaca0862_resolve_default_group > "$GROUP_FN_SRC"

if [ ! -s "$PROJECT_FN_SRC" ] || [ ! -s "$GROUP_FN_SRC" ]; then
    echo "FATAL: could not extract _xaca0862_resolve_default_project / _xaca0862_resolve_default_group from $CONNECT_TEMPLATE" >&2
    exit 1
fi
# Fixture sanity: extracted bodies must be non-trivial (both currently ~25-40
# lines), or every case below would be exercising an empty function.
PROJECT_FN_LINES=$(wc -l < "$PROJECT_FN_SRC" | tr -d ' ')
GROUP_FN_LINES=$(wc -l < "$GROUP_FN_SRC" | tr -d ' ')
if [ "$PROJECT_FN_LINES" -lt 15 ] || [ "$GROUP_FN_LINES" -lt 15 ]; then
    echo "FATAL: extracted function body suspiciously small (project=$PROJECT_FN_LINES group=$GROUP_FN_LINES lines) — extraction broken, refusing to run a vacuous suite." >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$PROJECT_FN_SRC"
# shellcheck disable=SC1090
source "$GROUP_FN_SRC"
declare -f _xaca0862_resolve_default_project >/dev/null || { echo "FATAL: _xaca0862_resolve_default_project not defined after extraction"; exit 1; }
declare -f _xaca0862_resolve_default_group >/dev/null || { echo "FATAL: _xaca0862_resolve_default_group not defined after extraction"; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
# Registry-writing helper. $1 = output path, then repeated specs:
#   "<instance_id>"                                 -> {} entry (no dirs)
#   "<instance_id>::<working_dir>"                  -> working_dir only
#   "<instance_id>::<working_dir>::<kanban_dir>"     -> both
# When --malformed / --not-json / --array / --teams-not-dict is passed as
# $2, writes that specific malformed shape instead (ignores further specs).
# ─────────────────────────────────────────────────────────────────────────────
_write_registry() {
    local out="$1"; shift
    mkdir -p "$(dirname "$out")"
    case "${1-}" in
        --not-json)
            printf 'this is not { json' > "$out"
            return 0
            ;;
        --array)
            printf '[1, 2, 3]\n' > "$out"
            return 0
            ;;
        --teams-not-dict)
            printf '{"teams": "not-a-dict"}\n' > "$out"
            return 0
            ;;
    esac
    if [ "$#" -eq 0 ]; then
        printf '{"teams": {}}\n' > "$out"
        return 0
    fi
    python3 - "$out" "$@" <<'PYEOF'
import json, sys
out = sys.argv[1]
specs = sys.argv[2:]
teams = {}
for spec in specs:
    if "::" in spec:
        parts = spec.split("::")
        instance_id = parts[0]
        working_dir = parts[1] if len(parts) > 1 else ""
        kanban_dir = parts[2] if len(parts) > 2 else ""
        entry = {}
        if working_dir:
            entry["working_dir"] = working_dir
        if kanban_dir:
            entry["kanban_dir"] = kanban_dir
        teams[instance_id] = entry
    else:
        teams[spec] = {}
data = {"teams": teams}
with open(out, "w") as f:
    json.dump(data, f)
PYEOF
}

# Drive the extracted project resolver. $1=registry path, $2=prefix.
# Prints resolved value (or empty) on stdout; returns the function's exit code.
_run_project_resolver() {
    local registry="$1" prefix="$2"
    AITEAMFORGE_CONFIG="$registry" HOME="$WORK_DIR/unused-home" \
        _xaca0862_resolve_default_project "$prefix"
}

# Same, for the group resolver.
_run_group_resolver() {
    local registry="$1" prefix="$2"
    AITEAMFORGE_CONFIG="$registry" HOME="$WORK_DIR/unused-home" \
        _xaca0862_resolve_default_group "$prefix"
}

# ═══════════════════════════════════════════════════════════════════════════
# PROJECT RESOLVER — P1: exactly 1 filesystem-verified match resolves.
# ═══════════════════════════════════════════════════════════════════════════
test_start "P1: exactly 1 filesystem-verified match resolves the project"
P1_SBX="$(_next_sandbox)"
P1_REG="$P1_SBX/team-paths.json"
P1_WD="$P1_SBX/finance/personal"; P1_KD="$P1_WD/kanban"
mkdir -p "$P1_KD"
_write_registry "$P1_REG" "finance-personal::$P1_WD::$P1_KD"
P1_OUT="$(_run_project_resolver "$P1_REG" "finance-")"; P1_RC=$?
if [ "$P1_OUT" = "personal" ] && [ "$P1_RC" -eq 0 ]; then
    test_pass
else
    test_fail "expected 'personal' rc=0; got '$P1_OUT' rc=$P1_RC"
fi

# ═══════════════════════════════════════════════════════════════════════════
# P2: 0 matches (nothing registered) -> empty, rc 0, never guesses.
# ═══════════════════════════════════════════════════════════════════════════
test_start "P2: 0 registered instances -> empty, rc 0"
P2_SBX="$(_next_sandbox)"
P2_REG="$P2_SBX/team-paths.json"
_write_registry "$P2_REG"
P2_OUT="$(_run_project_resolver "$P2_REG" "finance-")"; P2_RC=$?
if [ -z "$P2_OUT" ] && [ "$P2_RC" -eq 0 ]; then
    test_pass
else
    test_fail "expected empty rc=0; got '$P2_OUT' rc=$P2_RC"
fi

# ═══════════════════════════════════════════════════════════════════════════
# P3: 2+ matches -> empty, rc 0, refuses to guess (the headline defect this
# ticket exists to prevent — a WRONG resolved default is worse than none).
# ═══════════════════════════════════════════════════════════════════════════
test_start "P3: 2 registered instances -> empty, rc 0 (refuses to guess)"
P3_SBX="$(_next_sandbox)"
P3_REG="$P3_SBX/team-paths.json"
P3_WD1="$P3_SBX/finance/alpha"; P3_KD1="$P3_WD1/kanban"
P3_WD2="$P3_SBX/finance/beta"; P3_KD2="$P3_WD2/kanban"
mkdir -p "$P3_KD1" "$P3_KD2"
_write_registry "$P3_REG" "finance-alpha::$P3_WD1::$P3_KD1" "finance-beta::$P3_WD2::$P3_KD2"
P3_OUT="$(_run_project_resolver "$P3_REG" "finance-")"; P3_RC=$?
if [ -z "$P3_OUT" ] && [ "$P3_RC" -eq 0 ]; then
    test_pass
else
    test_fail "expected empty rc=0 (ambiguous); got '$P3_OUT' rc=$P3_RC"
fi

# ═══════════════════════════════════════════════════════════════════════════
# P4: registry file missing entirely -> empty, rc 0, never crashes.
# ═══════════════════════════════════════════════════════════════════════════
test_start "P4: registry file missing -> empty, rc 0, no crash"
P4_SBX="$(_next_sandbox)"
P4_REG="$P4_SBX/does-not-exist/team-paths.json"
P4_OUT="$(_run_project_resolver "$P4_REG" "finance-")"; P4_RC=$?
if [ -z "$P4_OUT" ] && [ "$P4_RC" -eq 0 ]; then
    test_pass
else
    test_fail "expected empty rc=0; got '$P4_OUT' rc=$P4_RC"
fi

# ═══════════════════════════════════════════════════════════════════════════
# P5: registry unreadable (chmod 000) -> empty, rc 0, no crash.
# ═══════════════════════════════════════════════════════════════════════════
test_start "P5: registry unreadable (chmod 000) -> empty, rc 0, no crash"
P5_SBX="$(_next_sandbox)"
P5_REG="$P5_SBX/team-paths.json"
P5_WD="$P5_SBX/finance/personal"; P5_KD="$P5_WD/kanban"
mkdir -p "$P5_KD"
_write_registry "$P5_REG" "finance-personal::$P5_WD::$P5_KD"
chmod 000 "$P5_REG"
P5_OUT="$(_run_project_resolver "$P5_REG" "finance-")"; P5_RC=$?
chmod 644 "$P5_REG"
if [ -z "$P5_OUT" ] && [ "$P5_RC" -eq 0 ]; then
    test_pass
else
    test_fail "expected empty rc=0; got '$P5_OUT' rc=$P5_RC"
fi

# ═══════════════════════════════════════════════════════════════════════════
# P6: registry is malformed (not valid JSON at all) -> empty, rc 0.
# ═══════════════════════════════════════════════════════════════════════════
test_start "P6: registry is malformed (invalid JSON) -> empty, rc 0, no crash"
P6_SBX="$(_next_sandbox)"
P6_REG="$P6_SBX/team-paths.json"
_write_registry "$P6_REG" --not-json
P6_OUT="$(_run_project_resolver "$P6_REG" "finance-")"; P6_RC=$?
if [ -z "$P6_OUT" ] && [ "$P6_RC" -eq 0 ]; then
    test_pass
else
    test_fail "expected empty rc=0; got '$P6_OUT' rc=$P6_RC"
fi

# ═══════════════════════════════════════════════════════════════════════════
# P7: registry top-level is not a dict (a JSON array) -> empty, rc 0.
# ═══════════════════════════════════════════════════════════════════════════
test_start "P7: registry top-level is a JSON array, not an object -> empty, rc 0"
P7_SBX="$(_next_sandbox)"
P7_REG="$P7_SBX/team-paths.json"
_write_registry "$P7_REG" --array
P7_OUT="$(_run_project_resolver "$P7_REG" "finance-")"; P7_RC=$?
if [ -z "$P7_OUT" ] && [ "$P7_RC" -eq 0 ]; then
    test_pass
else
    test_fail "expected empty rc=0; got '$P7_OUT' rc=$P7_RC"
fi

# ═══════════════════════════════════════════════════════════════════════════
# P8: ".teams" exists but is not a dict (a string) -> empty, rc 0.
# ═══════════════════════════════════════════════════════════════════════════
test_start "P8: registry .teams is not a dict -> empty, rc 0"
P8_SBX="$(_next_sandbox)"
P8_REG="$P8_SBX/team-paths.json"
_write_registry "$P8_REG" --teams-not-dict
P8_OUT="$(_run_project_resolver "$P8_REG" "finance-")"; P8_RC=$?
if [ -z "$P8_OUT" ] && [ "$P8_RC" -eq 0 ]; then
    test_pass
else
    test_fail "expected empty rc=0; got '$P8_OUT' rc=$P8_RC"
fi

# ═══════════════════════════════════════════════════════════════════════════
# P9: entry has working_dir but NO kanban_dir -> excluded (0 matches).
# ═══════════════════════════════════════════════════════════════════════════
test_start "P9: entry missing kanban_dir -> excluded (empty, rc 0)"
P9_SBX="$(_next_sandbox)"
P9_REG="$P9_SBX/team-paths.json"
P9_WD="$P9_SBX/finance/personal"
mkdir -p "$P9_WD"
_write_registry "$P9_REG" "finance-personal::$P9_WD"
P9_OUT="$(_run_project_resolver "$P9_REG" "finance-")"; P9_RC=$?
if [ -z "$P9_OUT" ] && [ "$P9_RC" -eq 0 ]; then
    test_pass
else
    test_fail "expected empty rc=0 (no kanban_dir); got '$P9_OUT' rc=$P9_RC"
fi

# ═══════════════════════════════════════════════════════════════════════════
# P10: entry has kanban_dir but NO working_dir -> excluded (0 matches).
# ═══════════════════════════════════════════════════════════════════════════
test_start "P10: entry missing working_dir -> excluded (empty, rc 0)"
P10_SBX="$(_next_sandbox)"
P10_REG="$P10_SBX/team-paths.json"
P10_KD="$P10_SBX/finance/personal/kanban"
mkdir -p "$P10_KD"
python3 - "$P10_REG" "$P10_KD" <<'PYEOF'
import json, sys
out, kd = sys.argv[1], sys.argv[2]
with open(out, "w") as f:
    json.dump({"teams": {"finance-personal": {"kanban_dir": kd}}}, f)
PYEOF
P10_OUT="$(_run_project_resolver "$P10_REG" "finance-")"; P10_RC=$?
if [ -z "$P10_OUT" ] && [ "$P10_RC" -eq 0 ]; then
    test_pass
else
    test_fail "expected empty rc=0 (no working_dir); got '$P10_OUT' rc=$P10_RC"
fi

# ═══════════════════════════════════════════════════════════════════════════
# P11: python3 absent from PATH -> empty, rc 0, no crash. PATH is overridden
# to an empty directory (via an absolute /bin/bash invocation, so the shell
# itself doesn't need to be found through the overridden PATH) so `command -v
# python3` genuinely fails to resolve, rather than relying on this machine
# happening to lack python3.
# ═══════════════════════════════════════════════════════════════════════════
test_start "P11: python3 absent from PATH -> empty, rc 0, no crash"
P11_SBX="$(_next_sandbox)"
P11_REG="$P11_SBX/team-paths.json"
P11_WD="$P11_SBX/finance/personal"; P11_KD="$P11_WD/kanban"
mkdir -p "$P11_KD"
_write_registry "$P11_REG" "finance-personal::$P11_WD::$P11_KD"
P11_EMPTYBIN="$P11_SBX/empty-bin"
mkdir -p "$P11_EMPTYBIN"
P11_OUT="$(PATH="$P11_EMPTYBIN" AITEAMFORGE_CONFIG="$P11_REG" /bin/bash -c "source '$PROJECT_FN_SRC'; _xaca0862_resolve_default_project 'finance-'")"
P11_RC=$?
if [ -z "$P11_OUT" ] && [ "$P11_RC" -eq 0 ]; then
    test_pass
else
    test_fail "expected empty rc=0 (no python3 on PATH); got '$P11_OUT' rc=$P11_RC"
fi

# ═══════════════════════════════════════════════════════════════════════════
# P12 [XACA-0862-023]: a registry KEY whose remainder contains a
# metacharacter (not just a dash) is excluded, same as the anchored
# [a-z0-9_]+ charset install-team.sh and render-cockpit-scripts.sh both
# already enforce. Proves the resolver's charset check is not merely "no
# dash" (which would have let this through) — defense in depth against a
# hand-edited/corrupted registry, since install-time writes are already
# validated against this same charset.
# ═══════════════════════════════════════════════════════════════════════════
test_start "P12 [XACA-0862-023]: registry key with a metacharacter remainder (space) is excluded, not treated as a match"
P12_SBX="$(_next_sandbox)"
P12_REG="$P12_SBX/team-paths.json"
P12_WD="$P12_SBX/finance/personal x"; P12_KD="$P12_WD/kanban"
mkdir -p "$P12_KD"
python3 - "$P12_REG" "$P12_WD" "$P12_KD" <<'PYEOF'
import json, sys
out, wd, kd = sys.argv[1], sys.argv[2], sys.argv[3]
with open(out, "w") as f:
    json.dump({"teams": {"finance-personal x": {"working_dir": wd, "kanban_dir": kd}}}, f)
PYEOF
P12_OUT="$(_run_project_resolver "$P12_REG" "finance-")"; P12_RC=$?
if [ -z "$P12_OUT" ] && [ "$P12_RC" -eq 0 ]; then
    test_pass
else
    test_fail "expected empty rc=0 (metachar remainder excluded); got '$P12_OUT' rc=$P12_RC"
fi

# ═══════════════════════════════════════════════════════════════════════════
# GROUP RESOLVER (XACA-0862-026) — same contract, evaluated at the GROUP
# level: a client with TWO registered projects still has an unambiguous
# GROUP even though PROJECT stays genuinely ambiguous between them.
# ═══════════════════════════════════════════════════════════════════════════
test_start "G1: exactly 1 distinct registered group resolves (single client, single project)"
G1_SBX="$(_next_sandbox)"
G1_REG="$G1_SBX/team-paths.json"
G1_WD="$G1_SBX/freelance/acme/widget"; G1_KD="$G1_WD/kanban"
mkdir -p "$G1_KD"
_write_registry "$G1_REG" "freelance-acme-widget::$G1_WD::$G1_KD"
G1_OUT="$(_run_group_resolver "$G1_REG" "freelance-")"; G1_RC=$?
if [ "$G1_OUT" = "acme" ] && [ "$G1_RC" -eq 0 ]; then
    test_pass
else
    test_fail "expected 'acme' rc=0; got '$G1_OUT' rc=$G1_RC"
fi

test_start "G1b: 1 client with TWO registered projects still resolves an unambiguous GROUP"
G1B_SBX="$(_next_sandbox)"
G1B_REG="$G1B_SBX/team-paths.json"
G1B_WD1="$G1B_SBX/freelance/acme/widget"; G1B_KD1="$G1B_WD1/kanban"
G1B_WD2="$G1B_SBX/freelance/acme/gadget"; G1B_KD2="$G1B_WD2/kanban"
mkdir -p "$G1B_KD1" "$G1B_KD2"
_write_registry "$G1B_REG" "freelance-acme-widget::$G1B_WD1::$G1B_KD1" "freelance-acme-gadget::$G1B_WD2::$G1B_KD2"
G1B_OUT="$(_run_group_resolver "$G1B_REG" "freelance-")"; G1B_RC=$?
# The PROJECT resolver, scoped to this now-known group, must still correctly
# stay ambiguous between "widget" and "gadget" — proving GROUP unambiguity
# does not silently smuggle in a guessed PROJECT.
G1B_PROJECT_OUT="$(_run_project_resolver "$G1B_REG" "freelance-acme-")"
if [ "$G1B_OUT" = "acme" ] && [ "$G1B_RC" -eq 0 ] && [ -z "$G1B_PROJECT_OUT" ]; then
    test_pass
else
    test_fail "expected GROUP='acme' rc=0 with PROJECT still ambiguous (empty); got GROUP='$G1B_OUT' rc=$G1B_RC PROJECT='$G1B_PROJECT_OUT'"
fi

test_start "G2: 0 registered freelance instances -> empty group, rc 0"
G2_SBX="$(_next_sandbox)"
G2_REG="$G2_SBX/team-paths.json"
_write_registry "$G2_REG"
G2_OUT="$(_run_group_resolver "$G2_REG" "freelance-")"; G2_RC=$?
if [ -z "$G2_OUT" ] && [ "$G2_RC" -eq 0 ]; then
    test_pass
else
    test_fail "expected empty rc=0; got '$G2_OUT' rc=$G2_RC"
fi

test_start "G3: 2 DISTINCT registered groups -> empty group, rc 0 (refuses to guess)"
G3_SBX="$(_next_sandbox)"
G3_REG="$G3_SBX/team-paths.json"
G3_WD1="$G3_SBX/freelance/acme/widget"; G3_KD1="$G3_WD1/kanban"
G3_WD2="$G3_SBX/freelance/globex/gizmo"; G3_KD2="$G3_WD2/kanban"
mkdir -p "$G3_KD1" "$G3_KD2"
_write_registry "$G3_REG" "freelance-acme-widget::$G3_WD1::$G3_KD1" "freelance-globex-gizmo::$G3_WD2::$G3_KD2"
G3_OUT="$(_run_group_resolver "$G3_REG" "freelance-")"; G3_RC=$?
if [ -z "$G3_OUT" ] && [ "$G3_RC" -eq 0 ]; then
    test_pass
else
    test_fail "expected empty rc=0 (2 distinct groups, ambiguous); got '$G3_OUT' rc=$G3_RC"
fi

test_start "G4: entry missing kanban_dir is excluded from group resolution too"
G4_SBX="$(_next_sandbox)"
G4_REG="$G4_SBX/team-paths.json"
G4_WD="$G4_SBX/freelance/acme/widget"
mkdir -p "$G4_WD"
_write_registry "$G4_REG" "freelance-acme-widget::$G4_WD"
G4_OUT="$(_run_group_resolver "$G4_REG" "freelance-")"; G4_RC=$?
if [ -z "$G4_OUT" ] && [ "$G4_RC" -eq 0 ]; then
    test_pass
else
    test_fail "expected empty rc=0 (no kanban_dir); got '$G4_OUT' rc=$G4_RC"
fi

# ═══════════════════════════════════════════════════════════════════════════
# I1 [defense-in-depth, XACA-0862-022]: a metacharacter-bearing value reaches
# _validate_ident and is rejected there — the actual safety boundary for
# PROJECT/GROUP regardless of source (CLI argument, baked default, or
# runtime-resolved). Driven through the FULL rendered script (not just the
# extracted resolver) via the CLI-argument path, which is always live
# independent of any resolver change, and which fails BEFORE any network
# activity (_validate_ident runs synchronously, pre-SSH) — safe to execute
# for real in CI. This is the CLI path the approved PR review verified by
# hand ("finance-connect.sh h 'evil;$(id)'" -> "Invalid project"); this test
# automates that exact verification.
# ═══════════════════════════════════════════════════════════════════════════
_render_test_connect_script() {
    # $1=out path $2=team_id $3=has_group(true/false)
    sed -e "s|{{TEAM_ID}}|$2|g" \
        -e "s|{{TEAM_NAME}}|Test Team|g" \
        -e "s|{{TEAM_THEME}}|test|g" \
        -e "s|{{TEAM_SOCKET}}|$2|g" \
        -e "s|{{TEAM_DEFAULT_PROJECT}}||g" \
        -e "s|{{TEAM_DEFAULT_GROUP}}||g" \
        -e "s|{{TEAM_LCARS_PORT_BASE}}|9000|g" \
        -e "s|{{TEAM_HAS_GROUP}}|$3|g" \
        -e "s|{{TEAM_SESSION_ORDER}}||g" \
        -e "s|{{AITEAMFORGE_DIR}}|\$HOME/aiteamforge|g" \
        "$CONNECT_TEMPLATE" > "$1"
    chmod +x "$1"
}

test_start "I1: a metacharacter-bearing <project> CLI argument reaches _validate_ident and is rejected (pre-network, exit 2)"
I1_SBX="$(_next_sandbox)"
I1_SCRIPT="$I1_SBX/finance-connect.sh"
_render_test_connect_script "$I1_SCRIPT" finance false
I1_OUT="$(AITEAMFORGE_CONFIG="$I1_SBX/no-such-registry.json" "$I1_SCRIPT" test-host 'evil;$(id)' 2>&1)"
I1_RC=$?
if [ "$I1_RC" -eq 2 ] && printf '%s' "$I1_OUT" | grep -qi "Invalid project"; then
    test_pass
else
    test_fail "expected exit 2 + 'Invalid project'; got rc=$I1_RC output: $I1_OUT"
fi

test_start "I2: a metacharacter-bearing <group> CLI argument reaches _validate_ident and is rejected (pre-network, exit 2)"
I2_SBX="$(_next_sandbox)"
I2_SCRIPT="$I2_SBX/freelance-connect.sh"
_render_test_connect_script "$I2_SCRIPT" freelance true
I2_OUT="$(AITEAMFORGE_CONFIG="$I2_SBX/no-such-registry.json" "$I2_SCRIPT" test-host 'evil;$(id)' someproject 2>&1)"
I2_RC=$?
if [ "$I2_RC" -eq 2 ] && printf '%s' "$I2_OUT" | grep -qi "Invalid group"; then
    test_pass
else
    test_fail "expected exit 2 + 'Invalid group'; got rc=$I2_RC output: $I2_OUT"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary (standalone only; test-runner.sh owns totals when sourced by it).
# ─────────────────────────────────────────────────────────────────────────────
if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "XACA-0862-022 runtime resolver tests: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    [ "${_FAIL_COUNT:-0}" -eq 0 ] || exit 1
fi
exit 0
