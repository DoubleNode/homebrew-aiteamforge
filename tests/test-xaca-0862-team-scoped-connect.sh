#!/bin/bash
# test-xaca-0862-team-scoped-connect.sh
#
# XACA-0862 (subitem -007, PROTECTED [Test] gate, DURABILITY phase).
#
# Regression suite for the SETTLED CONTRACT this ticket establishes:
#   1. Connect/disconnect scripts are TEAM-SCOPED and parameterized:
#      <team>-connect.sh <host> [project], <team>-disconnect.sh — never
#      <team>-<project>-connect.sh (the XACA-0845 instance-scoped naming).
#   2. DEFAULT_PROJECT baked into a team-scoped connect script is DERIVED
#      from the registered instance in team-paths.json, never a static
#      literal off the team .conf (TEAM_DEFAULT_PROJECT) and never dependent
#      on the CLI --project flag being re-supplied on every render.
#   3. The renderer produces this behaviour identically under a tap-CONSUMER
#      directory layout (the doubled `libexec/` nesting Homebrew's Cellar
#      produces — see .github/workflows/tests.yml "Verify installation"
#      step), not only the flat dev-team layout.
#
# WRITTEN AGAINST THE CONTRACT, NOT THE IMPLEMENTATION. This suite drives the
# real install-team.sh end-to-end and inspects only its OUTPUT (filenames on
# disk, the DEFAULT_PROJECT= line of a rendered script, team-paths.json
# content) — it does not reference any internal function/variable name that
# subitems 001-003 (owned by a parallel agent) may choose. That independence
# is deliberate: this suite is the acceptance test for the settled contract,
# not a mirror of one implementation of it.
#
# THREE PRIOR TICKETS IN THIS EXACT CODE PATH — XACA-0845, XACA-0814,
# XACA-0661 — were all marked COMPLETED while the defect remained observable
# in the field (see kanban/plans/XACA-0862 plan doc, "Notes"). This suite is
# written so it FAILS against the pre-XACA-0862 codebase and PASSES only once
# the team-scoped-naming + derived-DEFAULT_PROJECT fix lands. Do not "fix"
# this suite to pass early — a suite that always passes is not a gate.
#
# CURRENT (pre-fix) BEHAVIOUR, for context on why each case discriminates:
#   - install-team.sh:588 names the render `${INSTANCE_ID}-connect.sh` (e.g.
#     "finance-personal-connect.sh") for parametric teams — Case 1 fails.
#   - install-team.sh:740 bakes DEFAULT_PROJECT from
#     `${ARG_PROJECT:-$TEAM_DEFAULT_PROJECT}` (the CLI flag, or the static
#     conf literal) — never team-paths.json. A render with no --project flag
#     (exactly what a later regeneration/upgrade does) silently reverts to
#     the conf literal even when a DIFFERENT project is already registered —
#     Case 2 fails. This is the exact field defect: `legal-connect
#     darren-m4-mini` resolved INSTANCE=legal-default while the live
#     registered instance was legal-coparenting.
#
# Runs standalone (`bash tests/test-xaca-0862-team-scoped-connect.sh`) OR via
# test-runner.sh. Exit 0 = all pass, exit 1 = any fail.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_TEAM_SH="$TAP_ROOT/libexec/installers/install-team.sh"

if [ ! -f "$INSTALL_TEAM_SH" ]; then
    echo "FATAL: required file not found: $INSTALL_TEAM_SH" >&2
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
    TEST_TMP_DIR="$(mktemp -d -t xaca0862-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
cleanup() { if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ] && [ -d "${TEST_TMP_DIR:-}" ]; then find "$TEST_TMP_DIR" -depth -delete 2>/dev/null || true; fi; }
trap cleanup EXIT

WORK_DIR="$TEST_TMP_DIR/xaca0862"
mkdir -p "$WORK_DIR"
_next_sandbox() { mktemp -d "$WORK_DIR/sbx-XXXXXX"; }

_new_install_sandbox() {
    local sbx
    sbx="$(_next_sandbox)"
    mkdir -p "$sbx/home/.aiteamforge" "$sbx/aiteamforge"
    echo "$sbx"
}

# Drive the REAL install-team.sh in a sandbox. $1=sandbox root, rest = args.
# Mirrors tests/test-xaca-0845-connect-script-parametric-teams.sh's
# _run_install (AITEAMFORGE_CONFIG pinned into the sandbox too — XACA-0845-011
# — an ambient export would otherwise let the port allocator write the real
# registry on this machine).
_run_install() {
    local sbx="$1"; shift
    HOME="$sbx/home" \
    AITEAMFORGE_DIR="$sbx/aiteamforge" \
    AITEAMFORGE_CONFIG="$sbx/home/.aiteamforge/team-paths.json" \
    AITEAMFORGE_ORG_CONFIG="$sbx/home/.aiteamforge/organization.yaml" \
        bash "$INSTALL_TEAM_SH" "$@" --install-dir "$sbx/aiteamforge"
}

# Like _run_install, but sets AITEAMFORGE_CONNECT_REFRESH_SWEEP=true — the exact
# env var aiteamforge-upgrade.sh's update_connect_scripts sets on every
# iteration of its nightly unattended refresh sweep (XACA-0862-024). Use this
# to simulate that sweep's call shape; use plain _run_install to simulate a
# genuine, hand-typed invocation (including a hand-typed `--connect-only`).
_run_install_sweep() {
    local sbx="$1"; shift
    HOME="$sbx/home" \
    AITEAMFORGE_DIR="$sbx/aiteamforge" \
    AITEAMFORGE_CONFIG="$sbx/home/.aiteamforge/team-paths.json" \
    AITEAMFORGE_ORG_CONFIG="$sbx/home/.aiteamforge/organization.yaml" \
    AITEAMFORGE_CONNECT_REFRESH_SWEEP=true \
        bash "$INSTALL_TEAM_SH" "$@" --install-dir "$sbx/aiteamforge"
}

# Like _run_install but through a SYMLINKED tap-consumer-shaped layout
# instead of the real $TAP_ROOT (Case 3). $1=sandbox root, rest = args.
_run_install_consumer() {
    local sbx="$1"; shift
    local consumer_installer="$sbx/consumer-tap/libexec/libexec/installers/install-team.sh"
    HOME="$sbx/home" \
    AITEAMFORGE_DIR="$sbx/aiteamforge" \
    AITEAMFORGE_CONFIG="$sbx/home/.aiteamforge/team-paths.json" \
    AITEAMFORGE_ORG_CONFIG="$sbx/home/.aiteamforge/organization.yaml" \
        bash "$consumer_installer" "$@" --install-dir "$sbx/aiteamforge"
}

# Build a consumer-shaped tap layout under $1/consumer-tap: real content
# reached only through the DOUBLED libexec/ nesting Homebrew's Cellar
# produces for this formula (`libexec.install Dir["*"]` mirrors the whole tap
# repo under `prefix/libexec/`, verified structurally by
# .github/workflows/tests.yml's "Verify installation" step, which asserts
# `$(brew --prefix)/opt/aiteamforge/libexec/libexec/commands` and
# `.../libexec/share/templates` both exist). Symlinks, not copies — real
# tap content is 130+ MB and a copy per sandbox would make this suite slow
# without proving anything a symlink doesn't already prove (install-team.sh
# self-locates HOMEBREW_TAP_ROOT via `$SCRIPT_DIR/../..`, which is agnostic
# to whether the directories it walks through are real dirs or symlinks).
_build_consumer_tap_layout() {
    local sbx="$1"
    mkdir -p "$sbx/consumer-tap/libexec"
    ln -s "$TAP_ROOT/libexec" "$sbx/consumer-tap/libexec/libexec"
    ln -s "$TAP_ROOT/share" "$sbx/consumer-tap/libexec/share"
    [ -d "$TAP_ROOT/bin" ] && ln -s "$TAP_ROOT/bin" "$sbx/consumer-tap/libexec/bin"
}

# Read a single conf field ($2) from a team conf ($1) via subshell source
# (read-only; never mutates the conf; matches the technique used by
# test-xaca-0845-connect-script-parametric-teams.sh's _xaca0845_load_conf_vars).
_read_conf_field() {
    local conf_file="$1" field="$2"
    ( source "$conf_file" >/dev/null 2>&1; printf '%s' "${!field:-}" )
}

# Extract the DEFAULT_PROJECT= value baked into a rendered connect script.
# Handles both `DEFAULT_PROJECT="value"` and an unquoted form defensively.
_rendered_default_project() {
    local script="$1"
    grep -m1 '^DEFAULT_PROJECT=' "$script" 2>/dev/null \
        | sed -E 's/^DEFAULT_PROJECT="?([^"]*)"?[[:space:]]*$/\1/'
}

# Read the single registered team-paths.json instance KEY whose prefix is
# "<team_id>-" (there is exactly one per sandbox in this suite — each case
# uses a fresh sandbox). Prints nothing if none found (caller must check).
_registered_instance_key() {
    local registry="$1" team_id="$2"
    [ -f "$registry" ] || return 0
    python3 - "$registry" "$team_id" <<'PYEOF'
import json, sys
registry, team_id = sys.argv[1], sys.argv[2]
try:
    with open(registry) as f:
        data = json.load(f)
except Exception:
    sys.exit(0)
prefix = team_id + "-"
for key in data.get("teams", {}):
    if key.startswith(prefix):
        print(key)
        break
PYEOF
}

# Find any *-connect.sh / *-disconnect.sh file in $1 whose stem (basename
# minus the -connect.sh/-disconnect.sh suffix) still contains a hyphen — i.e.
# an INSTANCE-scoped name like "finance-personal-connect.sh" (stem
# "finance-personal") rather than the team-scoped "finance-connect.sh" (stem
# "finance", no hyphen). Every shipped TEAM_ID in this repo is a single
# hyphen-free token (academy, finance, legal, medical, freelance, ...), so
# "stem contains a hyphen" is exactly "two hyphenated components before the
# suffix" per the XACA-0862 verification checklist. Prints one path per line;
# empty output = clean.
_instance_named_files() {
    local dir="$1"
    [ -d "$dir" ] || return 0
    local f base stem
    for f in "$dir"/*-connect.sh "$dir"/*-disconnect.sh; do
        [ -e "$f" ] || continue
        base="$(basename "$f")"
        stem="${base%-connect.sh}"
        stem="${stem%-disconnect.sh}"
        case "$stem" in
            *-*) echo "$f" ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════════════════════
# S0 — SAFETY PRECONDITION: every team driven below (finance, legal, medical)
# must ship EMPTY TEAM_BREW_DEPS/TEAM_BREW_CASK_DEPS, matching
# test-xaca-0845-connect-script-parametric-teams.sh's S0. All installs in
# this suite use full installs (needed to populate team-paths.json — see
# Case 2), so this precondition is NOT relieved by --connect-only's early
# exit the way XACA-0845's S0 relieves it for academy. Refuse to proceed
# rather than risk a real `brew install` on this machine.
# ═══════════════════════════════════════════════════════════════════════════
test_start "S0 [safety]: finance/legal/medical conf ship empty TEAM_BREW_DEPS/TEAM_BREW_CASK_DEPS (this suite drives full installs)"
_s0_ok=true
_s0_detail=""
for _s0_team in finance legal medical; do
    _s0_conf="$TAP_ROOT/share/teams/${_s0_team}.conf"
    if [ ! -f "$_s0_conf" ]; then
        _s0_ok=false; _s0_detail="${_s0_detail}${_s0_team}.conf missing; "
        continue
    fi
    if grep -qE '^TEAM_BREW_DEPS=\(\s*\)' "$_s0_conf" && grep -qE '^TEAM_BREW_CASK_DEPS=\(\s*\)' "$_s0_conf"; then
        :
    else
        _s0_ok=false; _s0_detail="${_s0_detail}${_s0_team}.conf has non-empty brew deps; "
    fi
done
if [ "$_s0_ok" = true ]; then
    test_pass
else
    test_fail "safety precondition violated — refusing to proceed with real-installer tests: $_s0_detail"
    echo "FATAL: S0 safety precondition failed, aborting suite to avoid a real brew install." >&2
    if [ "$_STANDALONE" = true ]; then
        echo "XACA-0862 team-scoped connect tests: ${_PASS_COUNT} passed, $((_FAIL_COUNT)) failed"
    fi
    exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════
# CASE 1 — Team-scoped render: rendering a parametric team produces
# <team>-connect.sh (+ disconnect), and NO instance-named file exists.
#
# Proof this can fail: this drives the REAL, currently-unmodified
# install-team.sh. Pre-XACA-0862, line 588 names the output
# "${INSTANCE_ID}-connect.sh" ("finance-business-connect.sh"), so
# _instance_named_files() below is expected to find it until subitems
# 001-003 land — i.e. this case is its own negative control, not a
# synthetic one.
# ═══════════════════════════════════════════════════════════════════════════
test_start "Case 1: finance --project business (full install) renders finance-connect.sh + finance-disconnect.sh, no instance-named twin"
C1_SBX="$(_new_install_sandbox)"
C1_LOG="$WORK_DIR/c1-install.log"
if _run_install "$C1_SBX" finance --project business >"$C1_LOG" 2>&1; then
    C1_CONNECT="$C1_SBX/aiteamforge/finance-connect.sh"
    C1_DISCONNECT="$C1_SBX/aiteamforge/finance-disconnect.sh"
    C1_INSTANCE_NAMED="$(_instance_named_files "$C1_SBX/aiteamforge")"
    if [ -s "$C1_CONNECT" ] && [ -x "$C1_CONNECT" ] \
        && [ -s "$C1_DISCONNECT" ] && [ -x "$C1_DISCONNECT" ] \
        && [ -z "$C1_INSTANCE_NAMED" ]; then
        test_pass
    else
        test_fail "expected team-scoped finance-connect.sh/finance-disconnect.sh with no instance-named file; connect=$([ -f "$C1_CONNECT" ] && echo present || echo MISSING) disconnect=$([ -f "$C1_DISCONNECT" ] && echo present || echo MISSING) instance_named='$C1_INSTANCE_NAMED'; on-disk: $(ls -1 "$C1_SBX/aiteamforge" 2>/dev/null | tr '\n' ' '); install log tail: $(tail -20 "$C1_LOG")"
    fi
else
    test_fail "install-team.sh finance --project business exited non-zero; log: $(tail -40 "$C1_LOG")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# CASE 1b — Idempotency under the NEW contract: re-installing the SAME team
# with a DIFFERENT project must refresh finance-connect.sh IN PLACE, never
# create a second, project-qualified file. (Under the pre-fix contract this
# would legitimately create a distinct finance-personal-connect.sh sibling —
# that behaviour is exactly what Case 1 already proves must not happen; this
# case proves re-rendering doesn't accumulate twins either.)
# ═══════════════════════════════════════════════════════════════════════════
test_start "Case 1b: re-installing finance --project ops overwrites finance-connect.sh in place (no twin, DEFAULT_PROJECT updates)"
C1B_LOG="$WORK_DIR/c1b-install.log"
if _run_install "$C1_SBX" finance --project ops >"$C1B_LOG" 2>&1; then
    C1B_COUNT=$(find "$C1_SBX/aiteamforge" -maxdepth 1 -name '*connect.sh' | wc -l | tr -d ' ')
    C1B_PROJECT="$(_rendered_default_project "$C1_SBX/aiteamforge/finance-connect.sh")"
    if [ "$C1B_COUNT" -eq 2 ] && [ "$C1B_PROJECT" = "ops" ]; then
        test_pass
    else
        test_fail "expected exactly 2 *connect.sh files (finance-connect+disconnect only) and DEFAULT_PROJECT=ops after re-install; count=$C1B_COUNT rendered_project='$C1B_PROJECT'; on-disk: $(ls -1 "$C1_SBX/aiteamforge" 2>/dev/null | tr '\n' ' ')"
    fi
else
    test_fail "re-install finance --project ops exited non-zero; log: $(tail -40 "$C1B_LOG")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# CASE 2 — Derived DEFAULT_PROJECT: for a registered parametric instance, the
# rendered DEFAULT_PROJECT equals the instance's project component AS READ
# FROM team-paths.json — compared against a value DERIVED from the registry,
# never a literal written in this test (XACA-0862 verification checklist).
#
# Reproduces the actual field defect (plan doc "Evidence"): register an
# instance with an EXPLICIT --project (so team-paths.json records it), then
# RE-RENDER via --connect-only WITH NO --project flag — exactly what a later
# regeneration/upgrade does. Pre-fix, install-team.sh:740 falls back to the
# team .conf's static TEAM_DEFAULT_PROJECT, NOT the already-registered
# instance. Each project value below is chosen to DIFFER from that team's
# conf default (finance conf default "personal" vs. registered "biz"; legal
# conf default "default" vs. registered "coparenting" — the literal field
# defect; medical conf default "general" vs. registered "urgent") so the
# pre-fix fallback is provably wrong for all three, not coincidentally right
# for any one of them.
# ═══════════════════════════════════════════════════════════════════════════
for _c2_spec in "finance:biz" "legal:coparenting" "medical:urgent"; do
    _c2_team="${_c2_spec%%:*}"
    _c2_project="${_c2_spec#*:}"
    _c2_conf_default="$(_read_conf_field "$TAP_ROOT/share/teams/${_c2_team}.conf" TEAM_DEFAULT_PROJECT)"

    test_start "Case 2 [${_c2_team}]: DEFAULT_PROJECT on a --connect-only re-render derives from team-paths.json (registered='${_c2_project}'), not the conf literal ('${_c2_conf_default}')"

    if [ "$_c2_project" = "$_c2_conf_default" ]; then
        test_fail "test fixture error: registered project '${_c2_project}' must differ from ${_c2_team}.conf's TEAM_DEFAULT_PROJECT ('${_c2_conf_default}') or this case cannot discriminate pre-fix from post-fix behaviour"
        continue
    fi

    C2_SBX="$(_new_install_sandbox)"
    C2_REG_LOG="$WORK_DIR/c2-${_c2_team}-register.log"
    C2_RERENDER_LOG="$WORK_DIR/c2-${_c2_team}-rerender.log"

    if ! _run_install "$C2_SBX" "$_c2_team" --project "$_c2_project" >"$C2_REG_LOG" 2>&1; then
        test_fail "registering ${_c2_team} --project ${_c2_project} exited non-zero; log: $(tail -40 "$C2_REG_LOG")"
        continue
    fi

    C2_REGISTERED_KEY="$(_registered_instance_key "$C2_SBX/home/.aiteamforge/team-paths.json" "$_c2_team")"
    if [ -z "$C2_REGISTERED_KEY" ]; then
        test_fail "expected team-paths.json to record an instance keyed '${_c2_team}-*' after a full install; registry: $(cat "$C2_SBX/home/.aiteamforge/team-paths.json" 2>/dev/null)"
        continue
    fi
    # Expected value is DERIVED from the registry key, never asserted as a
    # literal — strip the "<team>-" prefix to get the project component.
    C2_EXPECTED_PROJECT="${C2_REGISTERED_KEY#${_c2_team}-}"

    if ! _run_install "$C2_SBX" "$_c2_team" --connect-only >"$C2_RERENDER_LOG" 2>&1; then
        test_fail "--connect-only re-render of ${_c2_team} (no --project) exited non-zero; log: $(tail -40 "$C2_RERENDER_LOG")"
        continue
    fi

    C2_CONNECT="$C2_SBX/aiteamforge/${_c2_team}-connect.sh"
    C2_ACTUAL_PROJECT="$(_rendered_default_project "$C2_CONNECT")"

    if [ -n "$C2_ACTUAL_PROJECT" ] && [ "$C2_ACTUAL_PROJECT" = "$C2_EXPECTED_PROJECT" ]; then
        test_pass
    else
        test_fail "rendered DEFAULT_PROJECT ('${C2_ACTUAL_PROJECT:-<absent>}') does not equal the registered instance's project component ('${C2_EXPECTED_PROJECT}', derived from team-paths.json key '${C2_REGISTERED_KEY}'); connect_script=$([ -f "$C2_CONNECT" ] && echo present || echo MISSING); DEFAULT_PROJECT line: $(grep -m1 '^DEFAULT_PROJECT=' "$C2_CONNECT" 2>/dev/null)"
    fi
done

# ═══════════════════════════════════════════════════════════════════════════
# CASE 3 — Consumer-layout coverage: the render works identically under a
# tap-CONSUMER directory layout (doubled libexec/ nesting), not only the flat
# dev-team layout every other case in this suite (and in
# test-xaca-0845-connect-script-parametric-teams.sh) exercises.
# ═══════════════════════════════════════════════════════════════════════════
test_start "Case 3: finance --project consumer renders team-scoped scripts under a tap-consumer (doubled libexec/) directory layout"
C3_SBX="$(_new_install_sandbox)"
_build_consumer_tap_layout "$C3_SBX"
C3_LOG="$WORK_DIR/c3-install.log"
if _run_install_consumer "$C3_SBX" finance --project consumer >"$C3_LOG" 2>&1; then
    C3_CONNECT="$C3_SBX/aiteamforge/finance-connect.sh"
    C3_DISCONNECT="$C3_SBX/aiteamforge/finance-disconnect.sh"
    C3_INSTANCE_NAMED="$(_instance_named_files "$C3_SBX/aiteamforge")"
    if [ -s "$C3_CONNECT" ] && [ -x "$C3_CONNECT" ] \
        && [ -s "$C3_DISCONNECT" ] && [ -x "$C3_DISCONNECT" ] \
        && [ -z "$C3_INSTANCE_NAMED" ]; then
        test_pass
    else
        test_fail "expected team-scoped finance-connect.sh/finance-disconnect.sh under the consumer layout with no instance-named file; connect=$([ -f "$C3_CONNECT" ] && echo present || echo MISSING) disconnect=$([ -f "$C3_DISCONNECT" ] && echo present || echo MISSING) instance_named='$C3_INSTANCE_NAMED'; on-disk: $(ls -1 "$C3_SBX/aiteamforge" 2>/dev/null | tr '\n' ' '); install log tail: $(tail -20 "$C3_LOG")"
    fi
else
    test_fail "consumer-layout install-team.sh finance --project consumer exited non-zero; log: $(tail -40 "$C3_LOG")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# CASE 3b — Consumer-layout DEFAULT_PROJECT derivation: Case 2's derivation
# check, repeated under the consumer layout, so the fix is proven to not be
# an accident of the dev-team directory shape.
# ═══════════════════════════════════════════════════════════════════════════
test_start "Case 3b: DEFAULT_PROJECT derivation on --connect-only re-render also holds under the consumer layout"
C3B_SBX="$(_new_install_sandbox)"
_build_consumer_tap_layout "$C3B_SBX"
C3B_REG_LOG="$WORK_DIR/c3b-register.log"
C3B_RERENDER_LOG="$WORK_DIR/c3b-rerender.log"
if _run_install_consumer "$C3B_SBX" legal --project chambers >"$C3B_REG_LOG" 2>&1; then
    C3B_REGISTERED_KEY="$(_registered_instance_key "$C3B_SBX/home/.aiteamforge/team-paths.json" legal)"
    if [ -n "$C3B_REGISTERED_KEY" ] && _run_install_consumer "$C3B_SBX" legal --connect-only >"$C3B_RERENDER_LOG" 2>&1; then
        C3B_EXPECTED="${C3B_REGISTERED_KEY#legal-}"
        C3B_ACTUAL="$(_rendered_default_project "$C3B_SBX/aiteamforge/legal-connect.sh")"
        if [ -n "$C3B_ACTUAL" ] && [ "$C3B_ACTUAL" = "$C3B_EXPECTED" ]; then
            test_pass
        else
            test_fail "consumer-layout rendered DEFAULT_PROJECT ('${C3B_ACTUAL:-<absent>}') != registered project ('${C3B_EXPECTED}', key '${C3B_REGISTERED_KEY}')"
        fi
    else
        test_fail "consumer-layout registration or re-render step failed; registered_key='${C3B_REGISTERED_KEY:-<none>}'; reg_log: $(tail -20 "$C3B_REG_LOG"); rerender_log: $(tail -20 "$C3B_RERENDER_LOG")"
    fi
else
    test_fail "consumer-layout install-team.sh legal --project chambers exited non-zero; log: $(tail -40 "$C3B_REG_LOG")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# CASE 4 [XACA-0862-024, HEADLINE regression]: the EXACT shape of the
# subitem-019 defect — a 2-INSTANCE team, refreshed via --connect-only for
# BOTH instances in sequence (mirroring aiteamforge-upgrade.sh's
# update_connect_scripts iterating its work list) — must leave the final
# rendered DEFAULT_PROJECT EMPTY, not "whichever instance was processed
# last". Case 2 (above) only ever covers the 1-instance shape, which cannot
# discriminate TIER 1 from TIER 2 (a 1-instance team's TIER-2-derived default
# and a wrongly-TIER-1'd default are the same value). This is what actually
# proves the AITEAMFORGE_CONNECT_REFRESH_SWEEP signal (not CONNECT_ONLY)
# is doing the excluding.
# ═══════════════════════════════════════════════════════════════════════════
test_start "Case 4 [XACA-0862-024]: sweep-mode --connect-only refresh of a 2-instance team leaves DEFAULT_PROJECT empty, not last-processed"
C4_SBX="$(_new_install_sandbox)"
C4_LOG1="$WORK_DIR/c4-install-alpha.log"
C4_LOG2="$WORK_DIR/c4-install-beta.log"
C4_SWEEP1="$WORK_DIR/c4-sweep-alpha.log"
C4_SWEEP2="$WORK_DIR/c4-sweep-beta.log"
if _run_install "$C4_SBX" finance --project alpha >"$C4_LOG1" 2>&1 \
    && _run_install "$C4_SBX" finance --project beta >"$C4_LOG2" 2>&1; then
    # Simulate the sweep processing BOTH registered instances in sequence,
    # exactly as update_connect_scripts' work-list loop does — each call
    # passes an explicit --project (to identify which instance THIS
    # iteration renders) AND the sweep signal.
    if _run_install_sweep "$C4_SBX" finance --project alpha --connect-only >"$C4_SWEEP1" 2>&1 \
        && _run_install_sweep "$C4_SBX" finance --project beta --connect-only >"$C4_SWEEP2" 2>&1; then
        C4_FINAL_PROJECT="$(_rendered_default_project "$C4_SBX/aiteamforge/finance-connect.sh")"
        if [ -z "$C4_FINAL_PROJECT" ] && grep -qi "2 registered instances" "$C4_SWEEP2"; then
            test_pass
        else
            test_fail "expected empty DEFAULT_PROJECT after a 2-instance sweep refresh (ambiguity warning expected too); got DEFAULT_PROJECT='${C4_FINAL_PROJECT:-<absent>}'; sweep2 log: $(tail -20 "$C4_SWEEP2")"
        fi
    else
        test_fail "sweep-mode --connect-only refresh exited non-zero; alpha log: $(tail -20 "$C4_SWEEP1"); beta log: $(tail -20 "$C4_SWEEP2")"
    fi
else
    test_fail "registering finance --project alpha / beta exited non-zero; alpha log: $(tail -20 "$C4_LOG1"); beta log: $(tail -20 "$C4_LOG2")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# CASE 4b [XACA-0862-024, contrast]: the SAME 2-instance --connect-only
# refresh, WITHOUT the sweep signal (i.e. a genuine hand-typed
# `install-team.sh finance --project X --connect-only`, exactly as a real
# interactive user could type it) correctly DOES win TIER 1 each time — this
# is the deliberate-choice case REFRESH_SWEEP must never suppress. Proves
# the exclusion is keyed to the direct signal, not to --connect-only itself
# (CONNECT_ONLY would have wrongly excluded this too — the defect XACA-0862-024
# exists to fix).
# ═══════════════════════════════════════════════════════════════════════════
test_start "Case 4b [XACA-0862-024, contrast]: the identical 2-instance --connect-only refresh WITHOUT the sweep signal still wins TIER 1 (last-processed wins, deliberately)"
C4B_SBX="$(_new_install_sandbox)"
C4B_LOG1="$WORK_DIR/c4b-install-alpha.log"
C4B_LOG2="$WORK_DIR/c4b-install-beta.log"
C4B_REFRESH1="$WORK_DIR/c4b-refresh-alpha.log"
C4B_REFRESH2="$WORK_DIR/c4b-refresh-beta.log"
if _run_install "$C4B_SBX" finance --project alpha >"$C4B_LOG1" 2>&1 \
    && _run_install "$C4B_SBX" finance --project beta >"$C4B_LOG2" 2>&1; then
    # Hand-typed --connect-only refreshes, NO sweep signal — TIER 1 must
    # still win outright each time (RESOLVED_PROJECT for THIS invocation).
    if _run_install "$C4B_SBX" finance --project alpha --connect-only >"$C4B_REFRESH1" 2>&1 \
        && _run_install "$C4B_SBX" finance --project beta --connect-only >"$C4B_REFRESH2" 2>&1; then
        C4B_FINAL_PROJECT="$(_rendered_default_project "$C4B_SBX/aiteamforge/finance-connect.sh")"
        if [ "$C4B_FINAL_PROJECT" = "beta" ]; then
            test_pass
        else
            test_fail "expected DEFAULT_PROJECT='beta' (TIER 1, last hand-typed refresh wins, no sweep signal); got '${C4B_FINAL_PROJECT:-<absent>}'"
        fi
    else
        test_fail "hand-typed --connect-only refresh exited non-zero; alpha log: $(tail -20 "$C4B_REFRESH1"); beta log: $(tail -20 "$C4B_REFRESH2")"
    fi
else
    test_fail "registering finance --project alpha / beta exited non-zero; alpha log: $(tail -20 "$C4B_LOG1"); beta log: $(tail -20 "$C4B_LOG2")"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary (standalone only; test-runner.sh owns totals when sourced by it).
# ─────────────────────────────────────────────────────────────────────────────
if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "XACA-0862 team-scoped connect tests: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    [ "${_FAIL_COUNT:-0}" -eq 0 ] || exit 1
fi
exit 0
