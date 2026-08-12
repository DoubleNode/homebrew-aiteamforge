#!/bin/bash
# test-xaca-0845-connect-script-parametric-teams.sh
#
# XACA-0845 (subitem -004, PROTECTED [Test] gate). Regression suite for the
# defect: parametric teams (finance/freelance/legal/medical —
# TEAM_HAS_PROJECTS="true" in share/teams/*.conf, note the value is QUOTED,
# an unquoted grep finds nothing) got NO connect script on the full-install
# path. Being SELECTED — the thing that makes an instance live — was the
# disqualifying condition: install-team.sh's full-install path had a
# deliberate `_PARAMETRIC_MODE == true: skip` no-op for connect/disconnect
# rendering, and the setup wizard's separate --connect-only pass (the only
# path that DID render them) explicitly excludes already-selected teams. A
# live parametric instance could therefore only ever get a connect script if
# nobody had actually set it up — the opposite of the intended guarantee.
#
# THE FIX (already implemented — this suite verifies, does not reimplement):
#   - libexec/installers/install-team.sh: retires the skip. Rendering is now
#     ONE function, _render_connect_disconnect() (~line 582), behind a shared
#     predicate _is_parametric_team() (~line 314) defined ABOVE the
#     --connect-only early exit, with two callers: the connect-only early
#     exit (~line 711) and the full-install path (~line 1209). Both callers
#     asking the SAME predicate is the structural fix — the two paths can no
#     longer silently disagree about whether a team is parametric.
#   - Parametric teams now render from share/templates/team-connect-parametric
#     .sh.template / team-disconnect-parametric.sh.template, NOT the flat
#     team-connect.sh.template. This is not cosmetic: the flat template bakes
#     TMUX_SOCKET=<instance-id> (e.g. "finance-personal"), but parametric
#     <team>-startup.sh scripts open tmux sessions on a socket named after the
#     TEAM ("finance"). A flat render for a parametric team therefore
#     produces a script that is PRESENT but attaches to a socket no startup
#     script ever creates — non-functional, and a file-existence-only test
#     would pass on it. Case 2 below is built specifically to catch this.
#   - The XACA-0483 stale-migration sweep (which moves legacy instance-keyed
#     startup/shutdown scripts aside to .stale-pre-XACA-0483 on re-install)
#     no longer includes connect/disconnect in its glob — those are
#     inherently instance-keyed by design now, so including them would move
#     every freshly rendered script aside on every re-install.
#   - libexec/commands/aiteamforge-upgrade.sh: update_connect_scripts()'s
#     work list is now a UNION of (a) *-connect.sh files already on disk and
#     (b) instances recorded in the install's own .aiteamforge-config
#     `.teams[]`. Source (a) alone can only ever REFRESH an existing file,
#     never CREATE a missing one — which is exactly the state XACA-0845 found:
#     two live installed instances with no connect script, forever un-healable
#     by upgrade. The "never materialise for a team this box didn't set up"
#     guarantee is preserved: .aiteamforge-config is written by setup from
#     SELECTED_TEAMS AFTER the install loop, neither source invents an instance
#     id, and anything unrecognised is still skipped, not guessed at.
#
#     XACA-0845-008: source (b) originally ALSO read ~/.aiteamforge/
#     team-paths.json, on the premise that registry membership proves setup.
#     It does not — the wizard enables every catalogued team by default (T6A),
#     so that read silently materialised cockpit scripts for up to 8 teams a
#     box never installed. T6B/T6C/T6D are the regression guards.
#
# TEST CASES (mapped to the XACA-0845-004 subitem brief):
#   S1  STRUCTURAL: _is_parametric_team() is defined once and referenced by
#       BOTH callers of _render_connect_disconnect().
#   S2  STRUCTURAL (Case 4, half): no deletion path exists anywhere for
#       *-connect.sh / *-disconnect.sh in either install-team.sh or
#       aiteamforge-upgrade.sh.
#   S3  STRUCTURAL (Case 5, half): the XACA-0483 stale-migration glob no
#       longer matches connect/disconnect filenames.
#   T1  Case 1 (HEADLINE): a live parametric instance (finance --project
#       personal) that previously got nothing now gets
#       finance-personal-connect.sh (+ disconnect) via the FULL install path
#       (not --connect-only) — driven for real, sandboxed.
#   T2  Case 2 (SUBTLE — the one that makes this suite meaningful): the
#       rendered socket is the TEAM base ("finance"), never the instance id
#       ("finance-personal"). A file-existence-only assertion would pass on
#       a script that can never attach to a real tmux session.
#   T3  Case 3: idempotency — re-running the full install refreshes in place,
#       never creates a bare team-keyed twin (finance-connect.sh) or a
#       doubly-qualified twin (finance-personal-personal-connect.sh).
#   T4  Case 5: re-installing over an already-rendered parametric instance
#       does not sweep its connect/disconnect scripts into
#       .stale-pre-XACA-0483.
#   T5  Case 7: non-parametric renders (academy) are byte-identical before
#       and after the fix — proven by rendering academy's connect/disconnect
#       through the REAL (fixed) installer AND through an embedded pre-fix
#       fixture fed the same real template + real conf data, then diffing.
#   T6  Case 6 (union, half): a REGISTERED-but-scriptless instance
#       (finance-personal in team-paths.json, no file on disk) gets its
#       connect/disconnect CREATED by `aiteamforge upgrade` — the capability
#       source (a) alone never had.
#   T7  Case 6 (union, half): an empty registry + empty WORKING_DIR creates
#       NOTHING — the "never materialise for a team this box didn't set up"
#       guarantee, preserved.
#   T8  Case 4 (functional): an on-disk connect script for an instance NOT
#       present in the registry is neither deleted nor made to vanish — the
#       file exists before and after.
#   T9  Case 8 (fleet-audit latent case): medical-general is DECLARED (a
#       medical.conf template ships) but NOT LIVE on this box (no registry
#       entry, no on-disk script). Asserts + explains the intended behavior:
#       nothing is materialised for it — being catalogued is not the same as
#       being set up, and conflating the two is the exact inversion this
#       ticket exists to fix in the other direction.
#   NC1 [[MANDATORY negative control, Case 1]]: an embedded pre-fix fixture,
#       gated the OLD way (_PARAMETRIC_MODE == true -> skip), produces NO
#       connect script for finance-personal — reproducing the headline
#       defect.
#   NC2 [[MANDATORY negative control, Case 2]]: the SAME embedded pre-fix
#       fixture, called directly (bypassing the skip, as the OLD
#       --connect-only path always did), bakes TMUX_SOCKET="finance-personal"
#       — the wrong value — using the real, unmodified template.
#   NC3 [[bonus negative control, Case 6]]: the pre-XACA-0845
#       update_connect_scripts (on-disk-files-only work list, embedded
#       verbatim from tap commit d263bbb) NEVER creates a connect script for
#       a registered-but-scriptless instance — proving source (b) is what
#       XACA-0845 actually added, not a restatement of source (a).
#
# WHY FIXTURES ARE EMBEDDED, NOT `git show`'d AT RUNTIME (house convention,
# XACA-0799 / XACA-0834): .github/workflows/tests.yml's `actions/checkout@v4`
# steps carry no `fetch-depth` override, which defaults to a SHALLOW
# (fetch-depth: 1) clone. A live `git show <old-sha>:...` or `git checkout
# <old-sha> -- ...` would fail on every CI run once that commit ages out of
# the shallow window. Fixtures below are therefore literal text embedded in
# this file, verified byte-identical against the real pre-fix source at
# authoring time (commit d263bbb, 419f4ba's immediate parent) and pinned by
# an in-file marker check before use — see "verify the revert landed" notes
# at each NC.
#
# Sandboxing: every filesystem write goes under a per-case mktemp sandbox
# with its OWN HOME and AITEAMFORGE_DIR — the real installer is driven for
# REAL (not stubbed) because finance.conf and academy.conf's TEAM_BREW_DEPS /
# TEAM_BREW_CASK_DEPS arrays are verified empty below (S0), so no `brew
# install` can ever fire; --connect-only mode additionally can never reach
# the brew-install section at all (it exits at the CONNECT-ONLY EARLY EXIT,
# which is textually above that section in both pre- and post-fix source).
# Real $HOME, real ~/.aiteamforge, and real ~/aiteamforge are never touched.
#
# Runs standalone (`bash tests/test-xaca-0845-connect-script-parametric-teams.sh`)
# OR via test-runner.sh. Exit 0 = all pass, exit 1 = any fail.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_TEAM_SH="$TAP_ROOT/libexec/installers/install-team.sh"
UPGRADE_SH="$TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh"

if [ ! -f "$INSTALL_TEAM_SH" ]; then
    echo "FATAL: required file not found: $INSTALL_TEAM_SH" >&2
    exit 1
fi
if [ ! -f "$UPGRADE_SH" ]; then
    echo "FATAL: required file not found: $UPGRADE_SH" >&2
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
# Temp directory (runner-supplied or our own).
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca0845-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
cleanup() { if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ] && [ -d "${TEST_TMP_DIR:-}" ]; then find "$TEST_TMP_DIR" -depth -delete 2>/dev/null || true; fi; }
trap cleanup EXIT

WORK_DIR="$TEST_TMP_DIR/xaca0845"
mkdir -p "$WORK_DIR"

_next_sandbox() { mktemp -d "$WORK_DIR/sbx-XXXXXX"; }

# Fresh sandbox with its own HOME/AITEAMFORGE_DIR. Never touches real $HOME.
_new_install_sandbox() {
    local sbx
    sbx="$(_next_sandbox)"
    mkdir -p "$sbx/home/.aiteamforge" "$sbx/aiteamforge"
    echo "$sbx"
}

# Drive the REAL install-team.sh in a sandbox. $1=sandbox root, rest = args.
# AITEAMFORGE_ORG_CONFIG (non-empty, need not exist) skips the interactive
# org-identity prompt (_ensure_org_config, install-team.sh ~line 424).
#
# AITEAMFORGE_CONFIG is pinned into the sandbox too (XACA-0845-011). Overriding
# HOME alone is NOT enough: AITEAMFORGE_CONFIG is consulted directly wherever it
# is set, so an ambient exported value would escape the sandbox and let the
# installer read — and the port allocator WRITE — the real registry on this
# machine. tests/test-xaca-0799-restart-symmetry.sh exports one, so under
# test-runner.sh this is a live leak, not a hypothetical.
_run_install() {
    local sbx="$1"; shift
    HOME="$sbx/home" \
    AITEAMFORGE_DIR="$sbx/aiteamforge" \
    AITEAMFORGE_CONFIG="$sbx/home/.aiteamforge/team-paths.json" \
    AITEAMFORGE_ORG_CONFIG="$sbx/home/.aiteamforge/organization.yaml" \
        bash "$INSTALL_TEAM_SH" "$@" --install-dir "$sbx/aiteamforge"
}

# ═══════════════════════════════════════════════════════════════════════════
# S0 — SAFETY PRECONDITION (not a XACA-0845 assertion, a sandboxing guardrail):
# finance and academy (the two real teams this suite drives through the REAL
# installer) must ship EMPTY TEAM_BREW_DEPS / TEAM_BREW_CASK_DEPS, or a full
# (non---connect-only) install would invoke a real `brew install` on THIS
# machine — forbidden regardless of ticket context. If a future conf change
# adds a dep, this test must fail loudly rather than silently start calling
# brew.
# ═══════════════════════════════════════════════════════════════════════════
test_start "S0 [safety]: finance.conf and academy.conf ship empty TEAM_BREW_DEPS/TEAM_BREW_CASK_DEPS (a full install must never invoke real brew)"
_s0_ok=true
_s0_detail=""
for _s0_team in finance academy; do
    _s0_conf="$TAP_ROOT/share/teams/${_s0_team}.conf"
    if [ ! -f "$_s0_conf" ]; then
        _s0_ok=false; _s0_detail="${_s0_detail}${_s0_team}.conf missing; "
        continue
    fi
    if [ "$_s0_team" = "academy" ]; then
        # academy DOES ship brew deps (python@3, node, jq, gh) — this suite
        # only ever drives academy via --connect-only, which exits at the
        # CONNECT-ONLY EARLY EXIT strictly before the brew-install section in
        # BOTH pre- and post-fix source (grep-verified below), so this is
        # safe regardless of academy's deps. Skip the emptiness requirement
        # for academy; pin the ordering guarantee instead.
        _s0_connect_only_line=$(grep -n '^if \[\[ "\$CONNECT_ONLY" == "true" \]\]; then' "$INSTALL_TEAM_SH" | head -1 | cut -d: -f1)
        _s0_brew_line=$(grep -n '^# INSTALL HOMEBREW DEPENDENCIES' "$INSTALL_TEAM_SH" | head -1 | cut -d: -f1)
        if [ -z "$_s0_connect_only_line" ] || [ -z "$_s0_brew_line" ] || [ "$_s0_connect_only_line" -ge "$_s0_brew_line" ]; then
            _s0_ok=false; _s0_detail="${_s0_detail}CONNECT_ONLY early-exit (line ${_s0_connect_only_line:-?}) is not strictly before the brew-install section (line ${_s0_brew_line:-?}); "
        fi
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
        echo "XACA-0845 connect-script tests: ${_PASS_COUNT} passed, $((_FAIL_COUNT)) failed"
    fi
    exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════
# S1 — STRUCTURAL: shared predicate, both callers.
# ═══════════════════════════════════════════════════════════════════════════
test_start "S1: _is_parametric_team() is defined once and both callers of _render_connect_disconnect() reference it"
_s1_predicate_defs=$(grep -c '^_is_parametric_team() {' "$INSTALL_TEAM_SH")
_s1_renderer_defs=$(grep -c '^_render_connect_disconnect() {' "$INSTALL_TEAM_SH")
_s1_callers=$(grep -cE '^[[:space:]]*_render_connect_disconnect$' "$INSTALL_TEAM_SH")
# XACA-0862: scan the FULL function body (awk, bounded by the next top-level
# "}"), not a fixed `-A 6` line slice. The fixed line count was coupled to
# the function's exact pre-XACA-0862 shape; XACA-0862 prefixed the predicate
# branch with an explanatory comment block (team-scoped-naming rationale),
# which alone pushed the `_is_parametric_team` call past line 6 with no
# change to the branching logic itself — a false failure this awk-bounded
# scan does not reproduce.
_s1_body=$(awk '/^_render_connect_disconnect\(\) \{/{f=1} f{print} f && /^}$/{exit}' "$INSTALL_TEAM_SH")
_s1_branches_on_predicate=$(printf '%s\n' "$_s1_body" | grep -c '_is_parametric_team')
if [ "$_s1_predicate_defs" -eq 1 ] && [ "$_s1_renderer_defs" -eq 1 ] && [ "$_s1_callers" -ge 2 ] && [ "$_s1_branches_on_predicate" -ge 1 ]; then
    test_pass
else
    test_fail "expected _is_parametric_team defined once (found=$_s1_predicate_defs), _render_connect_disconnect defined once (found=$_s1_renderer_defs) with >=2 callers (found=$_s1_callers), branching on the predicate (found=$_s1_branches_on_predicate)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# S2 — STRUCTURAL (Case 4, half): no deletion path for connect/disconnect
# scripts anywhere in the two files this fix touches.
# ═══════════════════════════════════════════════════════════════════════════
test_start "S2: no 'rm'/'rm -f' targeting *-connect.sh or *-disconnect.sh exists in install-team.sh or aiteamforge-upgrade.sh"
_s2_hits=$(grep -nE 'rm[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*.*-(connect|disconnect)\.sh' "$INSTALL_TEAM_SH" "$UPGRADE_SH" 2>/dev/null | grep -vE '\.tmp"?$' || true)
if [ -z "$_s2_hits" ]; then
    test_pass
else
    test_fail "found a deletion path targeting connect/disconnect scripts: $_s2_hits"
fi

# ═══════════════════════════════════════════════════════════════════════════
# S3 — STRUCTURAL (Case 5, half): stale-migration glob excludes
# connect/disconnect.
# ═══════════════════════════════════════════════════════════════════════════
test_start "S3: the XACA-0483 stale-migration glob only matches *-startup.sh / *-shutdown.sh, never *-connect.sh / *-disconnect.sh"
# Narrow to JUST the `for _stale_glob in ... ; do` glob list itself, not the
# surrounding comment block — the comment block legitimately DISCUSSES
# "<team>-<project>-connect.sh" in prose (explaining why it's excluded),
# which would false-positive a whole-block substring grep.
_s3_glob_list=$(awk '/^[[:space:]]*for _stale_glob in/,/; do$/' "$INSTALL_TEAM_SH")
if [ -n "$_s3_glob_list" ] \
    && echo "$_s3_glob_list" | grep -qF -- '-startup.sh' \
    && echo "$_s3_glob_list" | grep -qF -- '-shutdown.sh' \
    && ! echo "$_s3_glob_list" | grep -qF -- '-connect.sh' \
    && ! echo "$_s3_glob_list" | grep -qF -- '-disconnect.sh'; then
    test_pass
else
    test_fail "expected the stale-migration glob list to contain startup/shutdown patterns only; glob list was: $_s3_glob_list"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T1 — Case 1 (HEADLINE): finance --project personal via the FULL install
# path (not --connect-only) now produces a connect + disconnect script.
#
# XACA-0862 UPDATE: the settled contract (kanban/plans/XACA-0862) supersedes
# the instance-scoped filename this case originally asserted
# (finance-personal-connect.sh). Output is now TEAM-SCOPED
# (finance-connect.sh) — see test-xaca-0862-team-scoped-connect.sh Case 1 for
# the dedicated regression suite (naming + derived DEFAULT_PROJECT +
# consumer-layout coverage). This case is updated in place, not duplicated,
# so it never asserts a filename contract XACA-0862 retired.
# ═══════════════════════════════════════════════════════════════════════════
test_start "T1 [Case 1, HEADLINE]: finance --project personal (full install) creates finance-connect.sh + disconnect.sh (team-scoped, XACA-0862)"
T1_SBX="$(_new_install_sandbox)"
T1_LOG="$WORK_DIR/t1-install.log"
if _run_install "$T1_SBX" finance --project personal >"$T1_LOG" 2>&1; then
    T1_CONNECT="$T1_SBX/aiteamforge/finance-connect.sh"
    T1_DISCONNECT="$T1_SBX/aiteamforge/finance-disconnect.sh"
    if [ -s "$T1_CONNECT" ] && [ -x "$T1_CONNECT" ] && [ -s "$T1_DISCONNECT" ] && [ -x "$T1_DISCONNECT" ]; then
        test_pass
    else
        test_fail "expected non-empty, executable finance-connect.sh + disconnect.sh (team-scoped); connect=$([ -f "$T1_CONNECT" ] && echo present || echo MISSING) disconnect=$([ -f "$T1_DISCONNECT" ] && echo present || echo MISSING); install log tail: $(tail -20 "$T1_LOG")"
    fi
else
    test_fail "install-team.sh finance --project personal exited non-zero; log: $(tail -40 "$T1_LOG")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T2 — Case 2 (SUBTLE): the rendered socket is the TEAM base ("finance"),
# never the instance id ("finance-personal"). See NC2 below for the negative
# control proving this assertion can actually fail.
# ═══════════════════════════════════════════════════════════════════════════
test_start "T2 [Case 2, SUBTLE]: rendered TMUX_SOCKET is the team base 'finance', never the instance id 'finance-personal'"
T2_CONNECT="$T1_SBX/aiteamforge/finance-connect.sh"
if [ -f "$T2_CONNECT" ] \
    && grep -qF 'TMUX_SOCKET="finance"' "$T2_CONNECT" \
    && ! grep -qF 'TMUX_SOCKET="finance-personal"' "$T2_CONNECT"; then
    test_pass
else
    test_fail "expected TMUX_SOCKET=\"finance\" present and TMUX_SOCKET=\"finance-personal\" absent; actual TMUX_SOCKET line(s): $(grep -n 'TMUX_SOCKET=' "$T2_CONNECT" 2>/dev/null | head -3)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T3 — Case 3: idempotency. Re-running the full install twice more must
# refresh in place.
#
# XACA-0862 UPDATE: under team-scoped naming, "finance-connect.sh" IS the
# correct primary output (not a "bare twin" to avoid, as it was pre-XACA-0862
# when the instance-scoped name was the contract). The twin this case now
# guards against is the RETIRED instance-scoped name reappearing
# (finance-personal-connect.sh) alongside the team-scoped one.
# ═══════════════════════════════════════════════════════════════════════════
test_start "T3 [Case 3]: re-running finance --project personal is idempotent — no instance-scoped twin, socket still correct (team-scoped, XACA-0862)"
T3_LOG1="$WORK_DIR/t3-install-1.log"
T3_LOG2="$WORK_DIR/t3-install-2.log"
_run_install "$T1_SBX" finance --project personal >"$T3_LOG1" 2>&1
_run_install "$T1_SBX" finance --project personal >"$T3_LOG2" 2>&1
T3_CONNECT_COUNT=$(find "$T1_SBX/aiteamforge" -maxdepth 1 -name '*connect.sh' | wc -l | tr -d ' ')
T3_RETIRED_INSTANCE_TWIN="$T1_SBX/aiteamforge/finance-personal-connect.sh"
T3_DOUBLE_TWIN="$T1_SBX/aiteamforge/finance-personal-personal-connect.sh"
if [ "$T3_CONNECT_COUNT" -eq 2 ] \
    && [ ! -f "$T3_RETIRED_INSTANCE_TWIN" ] \
    && [ ! -f "$T3_DOUBLE_TWIN" ] \
    && grep -qF 'TMUX_SOCKET="finance"' "$T1_SBX/aiteamforge/finance-connect.sh"; then
    test_pass
else
    test_fail "expected exactly 2 *connect.sh files (team-scoped connect+disconnect for finance only), no retired-instance-scoped/double twins, socket still correct; found $T3_CONNECT_COUNT files: $(find "$T1_SBX/aiteamforge" -maxdepth 1 -name '*connect.sh' -exec basename {} \; 2>/dev/null | tr '\n' ' ')"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T4 — Case 5: re-installing over an already-rendered parametric instance
# does not sweep connect/disconnect into .stale-pre-XACA-0483 (T3 already
# re-installed twice over the same sandbox above — this checks the residue).
# XACA-0862 UPDATE: checks the team-scoped filenames (finance-connect.sh).
# ═══════════════════════════════════════════════════════════════════════════
test_start "T4 [Case 5]: re-install does not move finance-connect/disconnect.sh aside to .stale-pre-XACA-0483 (team-scoped, XACA-0862)"
T4_STALE_COUNT=$(find "$T1_SBX/aiteamforge" -maxdepth 1 -name '*connect*.stale-pre-XACA-0483' -o -name '*disconnect*.stale-pre-XACA-0483' 2>/dev/null | wc -l | tr -d ' ')
if [ "$T4_STALE_COUNT" -eq 0 ] \
    && [ -f "$T1_SBX/aiteamforge/finance-connect.sh" ] \
    && [ -f "$T1_SBX/aiteamforge/finance-disconnect.sh" ]; then
    test_pass
else
    test_fail "expected 0 .stale-pre-XACA-0483 connect/disconnect files and the live team-scoped scripts still present; stale_count=$T4_STALE_COUNT"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Shared helper for T5 / NC1 / NC2: load the fields _render_connect_disconnect
# (fixed) and the pre-fix CONNECT-ONLY EARLY EXIT (embedded below) both need,
# by sourcing a real team .conf exactly the way install-team.sh's own
# _read_conf() does (read-only; never mutates the conf).
# ═══════════════════════════════════════════════════════════════════════════
_xaca0845_load_conf_vars() {
    local conf_file="$1"
    (
        # shellcheck disable=SC1090
        source "$conf_file"
        printf 'TEAM_NAME=%q\n' "${TEAM_NAME:-}"
        printf 'TEAM_THEME=%q\n' "${TEAM_THEME:-}"
        printf 'TEAM_LCARS_PORT=%q\n' "${TEAM_LCARS_PORT:-8200}"
        printf 'TEAM_TERMINAL_LIST=%q\n' "${TEAM_AGENTS[*]+"${TEAM_AGENTS[*]}"}"
        local _cfg="" _agent _agent_key _var _val
        for _agent in "${TEAM_AGENTS[@]+"${TEAM_AGENTS[@]}"}"; do
            _agent_key="${_agent//-/_}"
            _var="AGENT_WINDOWS_${_agent_key}"
            _val="${!_var:-}"
            if [[ -n "$_val" ]]; then
                _cfg+="AGENT_WINDOWS_${_agent_key}=\"${_val}\""$'\n'
            fi
        done
        printf 'TEAM_AGENT_WINDOWS_CONFIG=%q\n' "$_cfg"
    )
}

# ─────────────────────────────────────────────────────────────────────────────
# PRE-FIX FIXTURE: _pre_fix_render_connect_only()
#
# Embedded VERBATIM (renamed only; sed/python bodies byte-for-byte) from tap
# commit d263bbb — install-team.sh's CONNECT-ONLY EARLY EXIT block, lines
# 511-558, immediately before XACA-0845's fix (419f4ba's parent). This is the
# rendering the OLD --connect-only path used UNCONDITIONALLY, for every team:
# always the flat team-connect.sh.template, always
# `{{TEAM_TMUX_SOCKET}} -> $instance_id`. Correct for non-parametric teams
# (instance id == team id there — this is what makes T5's byte-identical
# claim true), WRONG for parametric teams (Case 2's defect).
#
# "Verify the revert landed": before use, NC1/NC2 grep this function's own
# `declare -f` output for the exact smoking-gun substitution
# `{{TEAM_TMUX_SOCKET}}|$instance_id` — proving the embedded text is
# genuinely the OLD always-flat behavior and not an accidental copy of the
# NEW parametric-template path (which uses a differently-named placeholder,
# {{TEAM_SOCKET}}, and a $_socket variable, not $instance_id).
# ─────────────────────────────────────────────────────────────────────────────
_pre_fix_render_connect_only() {
    local instance_id="$1" team_name="$2" team_theme="$3" team_lcars_port="$4" \
          team_terminal_list="$5" team_agent_windows_config="$6" \
          homebrew_tap_root="$7" aiteamforge_dir="$8"

    local CONNECT_TEMPLATE="$homebrew_tap_root/share/templates/team-connect.sh.template"
    local CONNECT_SCRIPT="$aiteamforge_dir/${instance_id}-connect.sh"

    if [[ -f "$CONNECT_TEMPLATE" ]]; then
        sed -e "s|{{TEAM_ID}}|$instance_id|g" \
            -e "s|{{TEAM_NAME}}|$team_name|g" \
            -e "s|{{TEAM_THEME}}|$team_theme|g" \
            -e "s|{{TEAM_LCARS_PORT}}|$team_lcars_port|g" \
            -e "s|{{TEAM_TMUX_SOCKET}}|$instance_id|g" \
            -e "s|{{TEAM_TERMINAL_LIST}}|$team_terminal_list|g" \
            -e "s|{{AITEAMFORGE_DIR}}|$aiteamforge_dir|g" \
            "$CONNECT_TEMPLATE" > "${CONNECT_SCRIPT}.tmp"

        python3 - "${CONNECT_SCRIPT}.tmp" "$CONNECT_SCRIPT" <<PYEOF
import sys
src, dst = sys.argv[1], sys.argv[2]
windows_config = """${team_agent_windows_config}""".rstrip('\n')
if windows_config:
    windows_config += '\n'
with open(src) as f:
    content = f.read()
content = content.replace('{{TEAM_AGENT_WINDOWS_CONFIG}}\n', windows_config)
if '{{TEAM_AGENT_WINDOWS_CONFIG}}' in content:
    content = content.replace('{{TEAM_AGENT_WINDOWS_CONFIG}}', windows_config.rstrip('\n'))
with open(dst, 'w') as f:
    f.write(content)
PYEOF
        rm -f "${CONNECT_SCRIPT}.tmp"
        chmod +x "$CONNECT_SCRIPT"
    fi

    local DISCONNECT_TEMPLATE="$homebrew_tap_root/share/templates/team-disconnect.sh.template"
    local DISCONNECT_SCRIPT="$aiteamforge_dir/${instance_id}-disconnect.sh"
    if [[ -f "$DISCONNECT_TEMPLATE" ]]; then
        sed -e "s|{{TEAM_ID}}|$instance_id|g" \
            -e "s|{{TEAM_NAME}}|$team_name|g" \
            -e "s|{{TEAM_LCARS_PORT}}|$team_lcars_port|g" \
            -e "s|{{AITEAMFORGE_DIR}}|$aiteamforge_dir|g" \
            "$DISCONNECT_TEMPLATE" > "$DISCONNECT_SCRIPT"
        chmod +x "$DISCONNECT_SCRIPT"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# T5 — Case 7: non-parametric renders (academy) are byte-identical pre/post
# fix. Proven functionally: render via the REAL (fixed) installer AND via
# the embedded pre-fix fixture, fed the SAME real conf data and the SAME
# real templates, then diff byte-for-byte.
# ═══════════════════════════════════════════════════════════════════════════
test_start "T5 [Case 7]: academy connect/disconnect renders are byte-identical through the fixed installer vs. the embedded pre-fix fixture"
T5_SBX="$(_new_install_sandbox)"
T5_POST_LOG="$WORK_DIR/t5-post.log"
_run_install "$T5_SBX" academy --connect-only >"$T5_POST_LOG" 2>&1
T5_POST_CONNECT="$T5_SBX/aiteamforge/academy-connect.sh"
T5_POST_DISCONNECT="$T5_SBX/aiteamforge/academy-disconnect.sh"

T5_PRE_DIR="$(_next_sandbox)"
eval "$(_xaca0845_load_conf_vars "$TAP_ROOT/share/teams/academy.conf")"
_pre_fix_render_connect_only "academy" "$TEAM_NAME" "$TEAM_THEME" "$TEAM_LCARS_PORT" \
    "$TEAM_TERMINAL_LIST" "$TEAM_AGENT_WINDOWS_CONFIG" "$TAP_ROOT" "$T5_PRE_DIR"
T5_PRE_CONNECT="$T5_PRE_DIR/academy-connect.sh"
T5_PRE_DISCONNECT="$T5_PRE_DIR/academy-disconnect.sh"

# Normalize the ONE expected difference — the {{AITEAMFORGE_DIR}} value baked
# into both renders is the literal sandbox path, and the two renders
# necessarily used DIFFERENT mktemp sandboxes (post-fix via _run_install's
# "$T5_SBX/aiteamforge", pre-fix via the fixture's own "$T5_PRE_DIR"). Replace
# each render's own path with a common placeholder before diffing, so the
# comparison catches any REAL difference without false-failing on this
# structural (not behavioral) path mismatch.
T5_POST_NORM="$WORK_DIR/t5-post-connect.norm"
T5_PRE_NORM="$WORK_DIR/t5-pre-connect.norm"
T5_POST_DISC_NORM="$WORK_DIR/t5-post-disconnect.norm"
T5_PRE_DISC_NORM="$WORK_DIR/t5-pre-disconnect.norm"
sed "s|$T5_SBX/aiteamforge|__AITEAMFORGE_DIR__|g" "$T5_POST_CONNECT" > "$T5_POST_NORM" 2>/dev/null
sed "s|$T5_PRE_DIR|__AITEAMFORGE_DIR__|g" "$T5_PRE_CONNECT" > "$T5_PRE_NORM" 2>/dev/null
sed "s|$T5_SBX/aiteamforge|__AITEAMFORGE_DIR__|g" "$T5_POST_DISCONNECT" > "$T5_POST_DISC_NORM" 2>/dev/null
sed "s|$T5_PRE_DIR|__AITEAMFORGE_DIR__|g" "$T5_PRE_DISCONNECT" > "$T5_PRE_DISC_NORM" 2>/dev/null

if [ -f "$T5_POST_CONNECT" ] && [ -f "$T5_PRE_CONNECT" ] \
    && [ -f "$T5_POST_DISCONNECT" ] && [ -f "$T5_PRE_DISCONNECT" ] \
    && diff -q "$T5_POST_NORM" "$T5_PRE_NORM" >/dev/null 2>&1 \
    && diff -q "$T5_POST_DISC_NORM" "$T5_PRE_DISC_NORM" >/dev/null 2>&1; then
    test_pass
else
    test_fail "expected byte-identical academy connect/disconnect renders (after normalizing the AITEAMFORGE_DIR path); connect diff: $(diff "$T5_POST_NORM" "$T5_PRE_NORM" 2>&1 | head -10); disconnect diff: $(diff "$T5_POST_DISC_NORM" "$T5_PRE_DISC_NORM" 2>&1 | head -10)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# NC1 [MANDATORY negative control, Case 1]: the OLD gating logic
# (_PARAMETRIC_MODE == true -> skip entirely, install-team.sh d263bbb lines
# 1036-1037) reproduces the headline defect — no connect script for a live
# parametric instance.
# ═══════════════════════════════════════════════════════════════════════════
test_start "NC1 [negative control, Case 1]: pre-fix gating (_PARAMETRIC_MODE==true -> skip) produces NO connect script for finance-personal"
# Verify the revert landed: the embedded fixture must contain the exact old
# always-flat marker, and must NOT contain the new parametric-only markers —
# proving this is genuinely pre-fix behavior, not an accidental copy of the
# fixed code.
NC1_FIXTURE_SRC="$(declare -f _pre_fix_render_connect_only)"
NC1_MARKER_OK=true
echo "$NC1_FIXTURE_SRC" | grep -qF '{{TEAM_TMUX_SOCKET}}|$instance_id' || NC1_MARKER_OK=false
echo "$NC1_FIXTURE_SRC" | grep -qF '{{TEAM_SOCKET}}' && NC1_MARKER_OK=false
echo "$NC1_FIXTURE_SRC" | grep -qF 'team-connect-parametric.sh.template' && NC1_MARKER_OK=false
if [ "$NC1_MARKER_OK" != true ]; then
    test_fail "embedded fixture does not encode pre-fix behavior (marker check failed) — the negative control below would prove nothing; fixture source: $NC1_FIXTURE_SRC"
else
    NC1_SBX="$(_next_sandbox)"
    NC1_PARAMETRIC_MODE="true"
    eval "$(_xaca0845_load_conf_vars "$TAP_ROOT/share/teams/finance.conf")"
    # Reproduce install-team.sh d263bbb's exact gate: `if PARAMETRIC_MODE==true: :  (no-op) else <render>`.
    if [[ "$NC1_PARAMETRIC_MODE" == "true" ]]; then
        :  # No connect script for parametric teams — the pre-fix (buggy) behavior.
    else
        _pre_fix_render_connect_only "finance-personal" "$TEAM_NAME" "$TEAM_THEME" "$TEAM_LCARS_PORT" \
            "$TEAM_TERMINAL_LIST" "$TEAM_AGENT_WINDOWS_CONFIG" "$TAP_ROOT" "$NC1_SBX"
    fi
    if [ ! -f "$NC1_SBX/finance-personal-connect.sh" ] && [ ! -f "$NC1_SBX/finance-personal-disconnect.sh" ]; then
        test_pass
    else
        test_fail "expected the pre-fix gate to produce NO connect/disconnect script for finance-personal — if a file now exists, the negative control no longer discriminates from the fixed behavior in T1"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# NC2 [MANDATORY negative control, Case 2]: the OLD --connect-only path
# ALWAYS used the flat template — even for parametric teams — baking the
# WRONG socket (instance id, not team base).
# ═══════════════════════════════════════════════════════════════════════════
test_start "NC2 [negative control, Case 2]: pre-fix flat-template render bakes TMUX_SOCKET=\"finance-personal\" (wrong) — the exact bug T2 guards against"
NC2_FIXTURE_SRC="$(declare -f _pre_fix_render_connect_only)"
NC2_MARKER_OK=true
echo "$NC2_FIXTURE_SRC" | grep -qF '{{TEAM_TMUX_SOCKET}}|$instance_id' || NC2_MARKER_OK=false
if [ "$NC2_MARKER_OK" != true ]; then
    test_fail "embedded fixture does not encode the pre-fix always-flat socket substitution — marker check failed; fixture source: $NC2_FIXTURE_SRC"
else
    NC2_SBX="$(_next_sandbox)"
    eval "$(_xaca0845_load_conf_vars "$TAP_ROOT/share/teams/finance.conf")"
    # Pre-fix --connect-only never checked parametric-ness at all — call the
    # flat renderer directly, exactly as the old CONNECT-ONLY EARLY EXIT did.
    _pre_fix_render_connect_only "finance-personal" "$TEAM_NAME" "$TEAM_THEME" "$TEAM_LCARS_PORT" \
        "$TEAM_TERMINAL_LIST" "$TEAM_AGENT_WINDOWS_CONFIG" "$TAP_ROOT" "$NC2_SBX"
    if [ -f "$NC2_SBX/finance-personal-connect.sh" ] \
        && grep -qF 'TMUX_SOCKET="finance-personal"' "$NC2_SBX/finance-personal-connect.sh"; then
        test_pass
    else
        test_fail "expected the pre-fix render to bake TMUX_SOCKET=\"finance-personal\" (the wrong value) — if it now matches the correct 'finance', the negative control no longer discriminates from T2; actual: $(grep -n 'TMUX_SOCKET=' "$NC2_SBX/finance-personal-connect.sh" 2>/dev/null)"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# Extract the REAL (fixed) update_connect_scripts + _connect_script_team_flags
# from aiteamforge-upgrade.sh — do NOT source the whole file (its main body
# has side effects: is_configured, get_framework_dir, brew checks, the
# upgrade itself). Mirrors test-xaca-0834-connect-script-recovery.sh's
# extraction technique.
# ═══════════════════════════════════════════════════════════════════════════
_extract_fn() {
    awk -v fn="$1" '
      $0 ~ ("^" fn "\\(\\) \\{") { capture=1 }
      capture { print }
      capture && /^}$/ { exit }
    ' "$UPGRADE_SH"
}

FLAGS_FN_SRC="$WORK_DIR/connect_script_team_flags.extracted.sh"
UPD_FN_SRC="$WORK_DIR/update_connect_scripts.extracted.sh"
_extract_fn _connect_script_team_flags > "$FLAGS_FN_SRC"
_extract_fn update_connect_scripts > "$UPD_FN_SRC"

if [ ! -s "$FLAGS_FN_SRC" ] || [ ! -s "$UPD_FN_SRC" ]; then
    echo "FATAL: could not extract update_connect_scripts / _connect_script_team_flags from $UPGRADE_SH" >&2
    if [ "$_STANDALONE" = true ]; then
        echo "XACA-0845 connect-script tests: ${_PASS_COUNT} passed, $((_FAIL_COUNT + 1)) failed"
    fi
    exit 1
fi

_STUB_LOG="$WORK_DIR/upgrade-stub-output.log"
_install_print_stubs() {
    : > "$_STUB_LOG"
    for _p in print_section print_info print_success print_warning print_error; do
        eval "${_p}() { printf '%s\n' \"\$*\" >> \"\$_STUB_LOG\"; }"
    done
}
_install_print_stubs

# shellcheck disable=SC1090
source "$FLAGS_FN_SRC"
# shellcheck disable=SC1090
source "$UPD_FN_SRC"
declare -f _connect_script_team_flags >/dev/null || { echo "FATAL: _connect_script_team_flags not defined after extraction"; exit 1; }
declare -f update_connect_scripts >/dev/null || { echo "FATAL: update_connect_scripts not defined after extraction"; exit 1; }

# Build a team-paths.json registry file. $1 = output path, remaining args =
# instance ids to register (each gets a minimal, valid-shaped entry).
_write_registry() {
    local out="$1"; shift
    mkdir -p "$(dirname "$out")"
    if [ "$#" -eq 0 ]; then
        printf '{"teams": {}}\n' > "$out"
        return 0
    fi
    python3 - "$out" "$@" <<'PYEOF'
import json, sys
out = sys.argv[1]
instances = sys.argv[2:]
data = {"teams": {i: {"lcars_port": 8360} for i in instances}}
with open(out, "w") as f:
    json.dump(data, f)
PYEOF
}

# Build an INSTALL config (.aiteamforge-config) — the installer-written record
# of what this box actually set up, and the union's only non-filesystem source
# since XACA-0845-008. $1 = output path, then:
#
#   --profile <p>            optional; writes .install_profile (default "full")
#   "<base>"                 non-parametric install
#   "<base>:<project>"       TEAM_HAS_PROJECTS, no client (finance/legal/medical)
#   "<base>:<client>:<proj>" TEAM_REQUIRES_CLIENT_ID (freelance) — XACA-0845-015
#
# This mirrors bin/aiteamforge-setup.sh's writer exactly: `.teams[]` holds BASE
# ids, and `.team_paths.<base>` carries `project_id`, plus `client_id` when BOTH
# a client and a project are present (setup emits client_id only in that case).
_write_install_config() {
    local out="$1"; shift
    local profile="full"
    if [ "${1:-}" = "--profile" ]; then
        profile="$2"; shift 2
    fi
    mkdir -p "$(dirname "$out")"
    python3 - "$out" "$profile" "$@" <<'PYEOF'
import json, sys
out = sys.argv[1]
profile = sys.argv[2]
teams = []
paths = {}
for spec in sys.argv[3:]:
    parts = spec.split(":")
    base = parts[0]
    entry = {"working_dir": "/nonexistent/" + base}
    if len(parts) == 2:
        entry["project_id"] = parts[1]
    elif len(parts) >= 3:
        entry["client_id"] = parts[1]
        entry["project_id"] = parts[2]
    paths[base] = entry
    teams.append(base)
data = {"version": "test", "teams": teams, "team_paths": paths,
        "install_profile": profile}
with open(out, "w") as f:
    json.dump(data, f)
PYEOF
}

# Write the `.install-profile` marker exactly as bin/aiteamforge-setup.sh does
# (:1691) — the PRIMARY profile signal the doctor reads.
_write_install_profile_marker() {
    printf '%s\n' "$2" > "$1/.install-profile"
}

# ═══════════════════════════════════════════════════════════════════════════
# T6 — Case 6 (union, half): an INSTALLED-but-scriptless instance gets its
# connect/disconnect CREATED by `aiteamforge upgrade` — driven through the
# REAL (fixed) install-team.sh, real templates, real finance.conf.
#
# XACA-0845-008: this case originally drove the union from a team-paths.json
# registry entry. That premise was wrong — see T6B — so the case now supplies
# the same instance through .aiteamforge-config, the source that genuinely
# records an install. The behaviour under test (a live-but-scriptless instance
# gets its connect script CREATED, with the correct team-base tmux socket) is
# unchanged; only the proof-of-setup signal driving it is corrected.
#
# XACA-0862 UPDATE: `update_connect_scripts` (aiteamforge-upgrade.sh) renders
# by re-invoking install-team.sh, so the OUTPUT filename it produces is
# transitively team-scoped once install-team.sh's fix lands, even though this
# ticket's Files-to-Modify list does not touch aiteamforge-upgrade.sh itself.
# This case's expected path is updated to match; the "installed-but-scriptless
# gets created" behaviour under test is otherwise unchanged. Full upgrade-path
# regeneration coverage (subitem XACA-0862-005) is out of scope here.
# ═══════════════════════════════════════════════════════════════════════════
test_start "T6 [Case 6]: upgrade's union creates finance-connect.sh for an installed-but-scriptless instance (team-scoped, XACA-0862)"
T6_SBX="$(_new_install_sandbox)"
T6_REGISTRY="$T6_SBX/home/.aiteamforge/team-paths.json"
_write_registry "$T6_REGISTRY"
_write_install_config "$T6_SBX/aiteamforge/.aiteamforge-config" "finance:personal"
_install_print_stubs
HOME="$T6_SBX/home" \
AITEAMFORGE_ORG_CONFIG="$T6_SBX/home/.aiteamforge/organization.yaml" \
FRAMEWORK_DIR="$TAP_ROOT" WORKING_DIR="$T6_SBX/aiteamforge" LIBEXEC_DIR="$TAP_ROOT/libexec" DRY_RUN=false \
AITEAMFORGE_CONFIG="$T6_REGISTRY" \
    update_connect_scripts >"$WORK_DIR/t6-upgrade.log" 2>&1
T6_CONNECT="$T6_SBX/aiteamforge/finance-connect.sh"
if [ -s "$T6_CONNECT" ] \
    && grep -qF 'TMUX_SOCKET="finance"' "$T6_CONNECT" \
    && grep -qi "Creating missing" "$_STUB_LOG"; then
    test_pass
else
    test_fail "expected finance-connect.sh created with correct socket + a 'Creating missing' message; connect_exists=$([ -f "$T6_CONNECT" ] && echo yes || echo no); stub_log=$(cat "$_STUB_LOG"); upgrade_log=$(tail -20 "$WORK_DIR/t6-upgrade.log")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T6A [XACA-0845-008 precondition]: the wizard catalogue really does enable
# every team by default — the fact that makes team-paths.json membership
# worthless as proof of setup.
#
# Pinned as an executable precondition rather than asserted in prose so that
# if the wizard ever becomes opt-IN, this test fails and whoever made that
# change gets told that T6B/T6C's premise moved.
# ═══════════════════════════════════════════════════════════════════════════
test_start "T6A [XACA-0845-008]: team-paths wizard enables every catalogued team by default (so registry membership proves nothing)"
T6A_WIZARD="$TAP_ROOT/share/scripts/aiteamforge-team-paths-wizard.py"
T6A_PATHS="$TAP_ROOT/share/kanban-hooks/aiteamforge_paths.py"
T6A_OK=true
[ -f "$T6A_WIZARD" ] || T6A_OK=false
[ -f "$T6A_PATHS" ] || T6A_OK=false
# (1) the per-team prompt defaults to YES
grep -qF 'default_yes=True' "$T6A_WIZARD" 2>/dev/null || T6A_OK=false
grep -qE "Enable .*team_id" "$T6A_WIZARD" 2>/dev/null || T6A_OK=false
# (2) --accept-defaults writes DEFAULT_TEAMS with no prompt at all
grep -qF -- '--accept-defaults' "$T6A_WIZARD" 2>/dev/null || T6A_OK=false
# (3) alias teams are re-added unconditionally after the prompt loop
grep -qF 'Always include alias teams unchanged' "$T6A_WIZARD" 2>/dev/null || T6A_OK=false
# (4) the catalogue really does carry teams this box need never have installed
T6A_CATALOG_COUNT=$(grep -cE '^\s*"[a-z0-9-]+":\s*\{' "$T6A_PATHS" 2>/dev/null || echo 0)
if [ "$T6A_OK" = true ] && [ "${T6A_CATALOG_COUNT:-0}" -ge 5 ]; then
    test_pass
else
    test_fail "expected the wizard to enable every catalogued team by default and the catalogue to be non-trivial; ok=$T6A_OK catalog_entries=$T6A_CATALOG_COUNT wizard=$T6A_WIZARD"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T6B [XACA-0845-008, REGRESSION GUARD]: a fully-populated team-paths.json
# with NO .aiteamforge-config materialises NOTHING.
#
# This is the defect the -008 review finding named. The first cut of the union
# treated registry membership as affirmative proof of setup. It is not: the
# wizard (see T6A) enables every catalogued team by default, and
# aiteamforge_team_lcars_port() materialises a default registry on first
# lookup — so a box where setup NEVER RAN can hold a complete 16-team
# registry. Under the old code every one of those teams with a shipped .conf
# got a connect script it never asked for, silently inverting the guarantee
# "never materialise cockpit scripts for a team this box did not set up".
#
# The catalogue ids below are the real DEFAULT_TEAMS entries; the assertion
# targets the subset that has a shipped <team>.conf (academy, android,
# command, firebase, ios, finance-personal, legal-coparenting, medical-general
# all match a template, so all 8 WOULD have been materialised pre-fix).
# ═══════════════════════════════════════════════════════════════════════════
test_start "T6B [XACA-0845-008]: a wizard-populated team-paths.json alone materialises NOTHING (registry is not proof of setup)"
T6B_SBX="$(_new_install_sandbox)"
T6B_REGISTRY="$T6B_SBX/home/.aiteamforge/team-paths.json"
_write_registry "$T6B_REGISTRY" \
    academy android command dns finance-personal firebase ios \
    legal-coparenting mainevent medical-general
# Deliberately NO .aiteamforge-config: nothing was ever installed here.
_install_print_stubs
HOME="$T6B_SBX/home" \
AITEAMFORGE_ORG_CONFIG="$T6B_SBX/home/.aiteamforge/organization.yaml" \
FRAMEWORK_DIR="$TAP_ROOT" WORKING_DIR="$T6B_SBX/aiteamforge" LIBEXEC_DIR="$TAP_ROOT/libexec" DRY_RUN=false \
AITEAMFORGE_CONFIG="$T6B_REGISTRY" \
    update_connect_scripts >"$WORK_DIR/t6b-upgrade.log" 2>&1
T6B_COUNT=$(find "$T6B_SBX/aiteamforge" -maxdepth 1 -name '*-connect.sh' 2>/dev/null | wc -l | tr -d ' ')
T6B_DIS_COUNT=$(find "$T6B_SBX/aiteamforge" -maxdepth 1 -name '*-disconnect.sh' 2>/dev/null | wc -l | tr -d ' ')
if [ "$T6B_COUNT" -eq 0 ] && [ "$T6B_DIS_COUNT" -eq 0 ] \
    && grep -qi "No installed team connect scripts to refresh" "$_STUB_LOG"; then
    test_pass
else
    test_fail "expected ZERO scripts materialised from a registry-only box; connect=$T6B_COUNT disconnect=$T6B_DIS_COUNT; created=$(find "$T6B_SBX/aiteamforge" -maxdepth 1 -name '*connect.sh' -exec basename {} \; 2>/dev/null | tr '\n' ' '); stub_log=$(cat "$_STUB_LOG")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T6C [XACA-0845-008, REGRESSION GUARD]: with the SAME full registry present,
# only the team recorded in .aiteamforge-config is materialised.
#
# T6B proves the registry alone does nothing. T6C proves the registry is
# ignored even when a legitimate install exists alongside it — i.e. the union
# scopes to what was installed, not to what the wizard catalogued. This is the
# case that would have shipped 7 unwanted cockpit scripts.
# ═══════════════════════════════════════════════════════════════════════════
test_start "T6C [XACA-0845-008]: full registry + .aiteamforge-config listing only academy materialises ONLY academy"
T6C_SBX="$(_new_install_sandbox)"
T6C_REGISTRY="$T6C_SBX/home/.aiteamforge/team-paths.json"
_write_registry "$T6C_REGISTRY" \
    academy android command dns finance-personal firebase ios \
    legal-coparenting mainevent medical-general
_write_install_config "$T6C_SBX/aiteamforge/.aiteamforge-config" "academy"
_install_print_stubs
HOME="$T6C_SBX/home" \
AITEAMFORGE_ORG_CONFIG="$T6C_SBX/home/.aiteamforge/organization.yaml" \
FRAMEWORK_DIR="$TAP_ROOT" WORKING_DIR="$T6C_SBX/aiteamforge" LIBEXEC_DIR="$TAP_ROOT/libexec" DRY_RUN=false \
AITEAMFORGE_CONFIG="$T6C_REGISTRY" \
    update_connect_scripts >"$WORK_DIR/t6c-upgrade.log" 2>&1
T6C_MADE=$(find "$T6C_SBX/aiteamforge" -maxdepth 1 -name '*-connect.sh' -exec basename {} \; 2>/dev/null | sort | tr '\n' ' ')
T6C_UNWANTED=0
for _t6c_bad in android-connect.sh command-connect.sh firebase-connect.sh ios-connect.sh \
                finance-personal-connect.sh legal-coparenting-connect.sh medical-general-connect.sh; do
    [ -e "$T6C_SBX/aiteamforge/$_t6c_bad" ] && T6C_UNWANTED=$((T6C_UNWANTED + 1))
done
if [ -s "$T6C_SBX/aiteamforge/academy-connect.sh" ] && [ "$T6C_UNWANTED" -eq 0 ]; then
    test_pass
else
    test_fail "expected ONLY academy-connect.sh; unwanted_count=$T6C_UNWANTED; materialised='$T6C_MADE'; stub_log=$(cat "$_STUB_LOG")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T6D [XACA-0845-008, STRUCTURAL]: update_connect_scripts no longer reads the
# registry at all.
#
# T6B/T6C are behavioural and would still pass if someone re-added the
# registry read behind a condition that happens to be false in the sandbox.
# This pins the absence of the signal itself in the extracted function source.
#
# COMMENT LINES ARE STRIPPED FIRST, and that is load-bearing: the function
# carries a long "WHY NOT team-paths.json" rationale that names both rejected
# identifiers verbatim. A raw substring scan matches that prose and fails on
# correct code — which is exactly what happened when this test was first
# written. Assert against EXECUTABLE lines only.
# ═══════════════════════════════════════════════════════════════════════════
test_start "T6D [XACA-0845-008]: update_connect_scripts references neither team-paths.json nor AITEAMFORGE_CONFIG in code"
T6D_SRC="$(grep -v '^[[:space:]]*#' "$UPD_FN_SRC" || true)"
T6D_OK=true
case "$T6D_SRC" in *team-paths.json*) T6D_OK=false ;; esac
case "$T6D_SRC" in *AITEAMFORGE_CONFIG*) T6D_OK=false ;; esac
case "$T6D_SRC" in *.aiteamforge-config*) : ;; *) T6D_OK=false ;; esac
# Negative control: the stripped source must still be real code, not empty —
# otherwise the two "must not contain" assertions above would pass vacuously.
case "$T6D_SRC" in *update_connect_scripts*) : ;; *) T6D_OK=false ;; esac
if [ "$T6D_OK" = true ]; then
    test_pass
else
    test_fail "update_connect_scripts must read .aiteamforge-config and must NOT read team-paths.json/AITEAMFORGE_CONFIG (registry membership is not proof of setup, XACA-0845-008); extracted source: $UPD_FN_SRC"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T7 — Case 6 (union, half): empty registry + empty WORKING_DIR creates
# NOTHING — "never materialise for a team this box didn't set up" preserved.
# ═══════════════════════════════════════════════════════════════════════════
test_start "T7 [Case 6]: empty registry + empty WORKING_DIR creates nothing"
T7_SBX="$(_new_install_sandbox)"
T7_REGISTRY="$T7_SBX/home/.aiteamforge/team-paths.json"
_write_registry "$T7_REGISTRY"
_install_print_stubs
HOME="$T7_SBX/home" \
AITEAMFORGE_ORG_CONFIG="$T7_SBX/home/.aiteamforge/organization.yaml" \
FRAMEWORK_DIR="$TAP_ROOT" WORKING_DIR="$T7_SBX/aiteamforge" LIBEXEC_DIR="$TAP_ROOT/libexec" DRY_RUN=false \
AITEAMFORGE_CONFIG="$T7_REGISTRY" \
    update_connect_scripts >"$WORK_DIR/t7-upgrade.log" 2>&1
T7_FILE_COUNT=$(find "$T7_SBX/aiteamforge" -maxdepth 1 -name '*connect.sh' 2>/dev/null | wc -l | tr -d ' ')
if [ "$T7_FILE_COUNT" -eq 0 ] && grep -qi "No installed team connect scripts to refresh" "$_STUB_LOG"; then
    test_pass
else
    test_fail "expected 0 files created + 'No installed team connect scripts to refresh'; file_count=$T7_FILE_COUNT; stub_log=$(cat "$_STUB_LOG")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T8 — Case 4 (functional): an on-disk connect script for an instance NOT in
# the registry is never deleted. (It IS refreshed — on-disk files are always
# in the union's work list, source (a), regardless of registry state — the
# assertion here is specifically "still exists", matching S2's structural
# "no deletion path" pin.)
# ═══════════════════════════════════════════════════════════════════════════
test_start "T8 [Case 4]: an on-disk connect script for an unregistered instance is never deleted"
T8_SBX="$(_new_install_sandbox)"
T8_REGISTRY="$T8_SBX/home/.aiteamforge/team-paths.json"
_write_registry "$T8_REGISTRY"   # empty registry — finance-orphaned is NOT registered
mkdir -p "$T8_SBX/aiteamforge"
echo "#!/bin/zsh
echo placeholder-orphan-content" > "$T8_SBX/aiteamforge/finance-orphaned-connect.sh"
chmod +x "$T8_SBX/aiteamforge/finance-orphaned-connect.sh"
_install_print_stubs
HOME="$T8_SBX/home" \
AITEAMFORGE_ORG_CONFIG="$T8_SBX/home/.aiteamforge/organization.yaml" \
FRAMEWORK_DIR="$TAP_ROOT" WORKING_DIR="$T8_SBX/aiteamforge" LIBEXEC_DIR="$TAP_ROOT/libexec" DRY_RUN=false \
AITEAMFORGE_CONFIG="$T8_REGISTRY" \
    update_connect_scripts >"$WORK_DIR/t8-upgrade.log" 2>&1
if [ -f "$T8_SBX/aiteamforge/finance-orphaned-connect.sh" ]; then
    test_pass
else
    test_fail "expected finance-orphaned-connect.sh to still exist (never deleted) even though it has no registry entry; stub_log=$(cat "$_STUB_LOG")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T9 — Case 8: medical-general is DECLARED (medical.conf ships in the
# catalog) but NOT LIVE on this box (not installed, no on-disk script).
#
# ASSERTED BEHAVIOR: nothing is materialised for medical-general. WHY this is
# correct, not a gap: the union's whole purpose is "an instance this box
# ACTUALLY set up should get a connect script even if the file is missing" —
# proof of setup is either an on-disk artifact OR an .aiteamforge-config
# `.teams[]` entry. Being merely CATALOGUED (a shipped medical.conf template,
# or a wizard-written team-paths.json row — see T6B) is neither.
# Materialising a script for every catalogued team regardless of whether
# anyone asked for it would be the same class of defect this ticket fixes,
# just inverted: instead of a live instance getting nothing, a
# never-requested instance would get something. The upgrade code's own
# comment states this explicitly: "upgrade must never materialise cockpit
# scripts for a team this box didn't set up."
# ═══════════════════════════════════════════════════════════════════════════
test_start "T9 [Case 8]: medical-general (declared in the catalog, not live on this box) gets nothing materialised"
T9_SBX="$(_new_install_sandbox)"
T9_REGISTRY="$T9_SBX/home/.aiteamforge/team-paths.json"
_write_registry "$T9_REGISTRY"   # empty — medical-general is not registered
_install_print_stubs
HOME="$T9_SBX/home" \
AITEAMFORGE_ORG_CONFIG="$T9_SBX/home/.aiteamforge/organization.yaml" \
FRAMEWORK_DIR="$TAP_ROOT" WORKING_DIR="$T9_SBX/aiteamforge" LIBEXEC_DIR="$TAP_ROOT/libexec" DRY_RUN=false \
AITEAMFORGE_CONFIG="$T9_REGISTRY" \
    update_connect_scripts >"$WORK_DIR/t9-upgrade.log" 2>&1
T9_MEDICAL_FILE_COUNT=$(find "$T9_SBX/aiteamforge" -maxdepth 1 -name 'medical*' 2>/dev/null | wc -l | tr -d ' ')
if [ -f "$TAP_ROOT/share/teams/medical.conf" ] \
    && [ "$T9_MEDICAL_FILE_COUNT" -eq 0 ] \
    && grep -qi "No installed team connect scripts to refresh" "$_STUB_LOG"; then
    test_pass
else
    test_fail "expected medical.conf to exist in the catalog (declared) but zero medical* files materialised (not live); medical_conf_exists=$([ -f "$TAP_ROOT/share/teams/medical.conf" ] && echo yes || echo no); file_count=$T9_MEDICAL_FILE_COUNT; stub_log=$(cat "$_STUB_LOG")"
fi

# ─────────────────────────────────────────────────────────────────────────────
# NC3 [bonus negative control, Case 6]: the pre-XACA-0845
# update_connect_scripts (embedded verbatim, tap commit d263bbb — on-disk
# files ONLY, no union) never creates a connect script for an
# installed-but-scriptless instance. Proves source (b) is genuinely what
# XACA-0845 added, not a restatement of what was already there.
#
# XACA-0845-008: the sandbox below MUST supply the instance via
# .aiteamforge-config — the CURRENT source (b). Driving it with a
# team-paths.json registry instead would make this control VACUOUS, because
# the fixed code deliberately ignores that file too: both algorithms would
# create nothing, for different reasons, and the test would no longer
# discriminate the pre-fix behaviour from the post-fix behaviour at all.
# ─────────────────────────────────────────────────────────────────────────────
_pre_xaca0845_update_connect_scripts() {
  print_section "Updating Team Connect/Disconnect Scripts"

  local teams_conf_dir="${FRAMEWORK_DIR}/share/teams"
  local installer="${LIBEXEC_DIR}/installers/install-team.sh"

  if [ ! -d "$teams_conf_dir" ]; then
    print_warning "Team configs not found ($teams_conf_dir) — skipping connect-script refresh"
    return 0
  fi
  if [ ! -f "$installer" ]; then
    print_warning "install-team.sh not found ($installer) — skipping connect-script refresh"
    return 0
  fi

  local updated=0
  local failed=0
  local skipped=0
  local f base instance_id conf team_id best_team best_conf remainder
  local flags has_projects requires_client client project
  local -a install_args

  # Iterate the RENDERED FILES ONLY (XACA-0834's fix) — no registry union
  # (this is the capability XACA-0845 added; its absence here is the point).
  for f in "${WORKING_DIR}"/*-connect.sh; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    instance_id="${base%-connect.sh}"
    if [ -z "$instance_id" ]; then
      print_warning "Skipping ${base} — empty instance id after suffix-stripping"
      skipped=$((skipped + 1))
      continue
    fi

    best_team=""
    best_conf=""
    for conf in "$teams_conf_dir"/*.conf; do
      [ -f "$conf" ] || continue
      team_id="$(basename "$conf" .conf)"
      if [ "$instance_id" = "$team_id" ] || [ "${instance_id#"${team_id}-"}" != "$instance_id" ]; then
        if [ "${#team_id}" -gt "${#best_team}" ]; then
          best_team="$team_id"
          best_conf="$conf"
        fi
      fi
    done

    if [ -z "$best_team" ]; then
      print_warning "Skipping ${base} — no team template matches instance '${instance_id}'"
      skipped=$((skipped + 1))
      continue
    fi

    flags="$(_connect_script_team_flags "$best_conf")"
    has_projects="${flags%%|*}"
    requires_client="${flags##*|}"
    remainder="${instance_id#"$best_team"}"
    remainder="${remainder#-}"

    client=""
    project=""
    if [ "$has_projects" = "true" ]; then
      if [ -z "$remainder" ]; then
        print_warning "Skipping ${base} — template '${best_team}' is parameterised but instance '${instance_id}' carries no project component"
        skipped=$((skipped + 1))
        continue
      fi
      if [ "$requires_client" = "true" ]; then
        client="${remainder%%-*}"
        project="${remainder#*-}"
        if [ -z "$client" ] || [ -z "$project" ] || [ "$client" = "$remainder" ] || [ "$project" != "${project#*-}" ]; then
          print_warning "Skipping ${base} — cannot split '${remainder}' into <client>-<project> for template '${best_team}'"
          skipped=$((skipped + 1))
          continue
        fi
      else
        project="$remainder"
        if [ "$project" != "${project#*-}" ]; then
          print_warning "Skipping ${base} — project component '${project}' for template '${best_team}' contains a dash"
          skipped=$((skipped + 1))
          continue
        fi
      fi
    elif [ -n "$remainder" ]; then
      print_warning "Skipping ${base} — template '${best_team}' takes no parameters but instance '${instance_id}' carries suffix '${remainder}'"
      skipped=$((skipped + 1))
      continue
    fi

    install_args=( "$best_team" )
    if [ -n "$client" ]; then
      install_args+=( --client "$client" )
    fi
    if [ -n "$project" ]; then
      install_args+=( --project "$project" )
    fi
    install_args+=( --connect-only --install-dir "${WORKING_DIR}" )

    if [ "$DRY_RUN" = true ]; then
      echo "Would re-render ${instance_id} connect/disconnect scripts (template ${best_team})"
      updated=$((updated + 1))
      continue
    fi

    print_info "Refreshing ${instance_id} connect/disconnect scripts..."
    if ( AITEAMFORGE_DIR="${WORKING_DIR}" bash "$installer" "${install_args[@]}" 2>&1 | sed 's/^/    /' ); then
      print_success "Refreshed ${instance_id} connect/disconnect scripts"
      updated=$((updated + 1))
    else
      print_warning "Failed to refresh ${instance_id} connect/disconnect scripts (continuing)"
      failed=$((failed + 1))
    fi
  done

  if [ $((updated + failed)) -eq 0 ]; then
    print_success "No installed team connect scripts to refresh"
  elif [ "$DRY_RUN" = true ]; then
    print_success "Would refresh ${updated} team connect/disconnect script set(s)"
  elif [ "$failed" -gt 0 ]; then
    print_warning "Refreshed ${updated} team connect/disconnect script set(s); ${failed} failed (non-fatal)"
  else
    print_success "Refreshed ${updated} team connect/disconnect script set(s)"
  fi
  if [ "$skipped" -gt 0 ]; then
    print_warning "Skipped ${skipped} unrecognised *-connect.sh file(s) (non-fatal)"
  fi
  return 0
}

test_start "NC3 [negative control, Case 6]: pre-XACA-0845 update_connect_scripts NEVER creates an installed-but-scriptless instance's connect script"
# Verify the revert landed: the embedded fixture must iterate ONLY on-disk
# files (no registry/AITEAMFORGE_CONFIG reference at all) — proving it is
# genuinely the pre-XACA-0845 algorithm.
NC3_FIXTURE_SRC="$(declare -f _pre_xaca0845_update_connect_scripts)"
NC3_MARKER_OK=true
# NOTE: `declare -f` reformats the function body (e.g. puts `do` on its own
# line), so match the on-disk-only iteration WITHOUT the trailing "; do".
echo "$NC3_FIXTURE_SRC" | grep -qF 'for f in "${WORKING_DIR}"/*-connect.sh' || NC3_MARKER_OK=false
echo "$NC3_FIXTURE_SRC" | grep -qF 'AITEAMFORGE_CONFIG' && NC3_MARKER_OK=false
echo "$NC3_FIXTURE_SRC" | grep -qF '_reg_instances' && NC3_MARKER_OK=false
if [ "$NC3_MARKER_OK" != true ]; then
    test_fail "embedded fixture does not match the pre-XACA-0845 on-disk-only algorithm (marker check failed); fixture source: $NC3_FIXTURE_SRC"
else
    NC3_SBX="$(_new_install_sandbox)"
    NC3_REGISTRY="$NC3_SBX/home/.aiteamforge/team-paths.json"
    _write_registry "$NC3_REGISTRY"
    # Source (b) as it exists TODAY — see the vacuity note above.
    _write_install_config "$NC3_SBX/aiteamforge/.aiteamforge-config" "finance:personal"
    _install_print_stubs
    HOME="$NC3_SBX/home" \
    AITEAMFORGE_ORG_CONFIG="$NC3_SBX/home/.aiteamforge/organization.yaml" \
    FRAMEWORK_DIR="$TAP_ROOT" WORKING_DIR="$NC3_SBX/aiteamforge" LIBEXEC_DIR="$TAP_ROOT/libexec" DRY_RUN=false \
    AITEAMFORGE_CONFIG="$NC3_REGISTRY" \
        _pre_xaca0845_update_connect_scripts >"$WORK_DIR/nc3-upgrade.log" 2>&1
    if [ ! -f "$NC3_SBX/aiteamforge/finance-personal-connect.sh" ]; then
        test_pass
    else
        test_fail "expected the pre-XACA-0845 algorithm to create NOTHING for the installed-but-scriptless finance-personal — if a file now exists, the negative control no longer discriminates from T6"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# D1–D3 — `aiteamforge doctor --check connect` (XACA-0845 Blocker 2)
#
# check_connect_scripts originally landed in bin/aiteamforge-doctor.sh — which
# `aiteamforge doctor` DOES NOT DISPATCH TO. bin/aiteamforge-cli.sh execs
# libexec/commands/aiteamforge-doctor.sh, so the advertised diagnostic was
# dead code: the CHANGELOG and PR body claimed a working `--check connect`
# while the command it names would have exited 1 with "Unknown component".
#
# D3 drives the check through the REAL CLI entry point rather than calling the
# function directly. That distinction is the whole point — a test that sourced
# the file and invoked check_connect_scripts would have passed against the
# broken build, since the function existed and worked; only the wiring was
# missing.
# ═══════════════════════════════════════════════════════════════════════════
DOCTOR_CMD="$TAP_ROOT/libexec/commands/aiteamforge-doctor.sh"
BIN_DOCTOR="$TAP_ROOT/bin/aiteamforge-doctor.sh"
CLI_SH="$TAP_ROOT/bin/aiteamforge-cli.sh"

test_start "D1 [Blocker 2]: check_connect_scripts is defined in the REAL dispatch target and wired into --check connect + all"
D1_OK=true
[ -f "$DOCTOR_CMD" ] || D1_OK=false
D1_SRC="$(cat "$DOCTOR_CMD" 2>/dev/null || true)"
case "$D1_SRC" in *"check_connect_scripts() {"*) : ;; *) D1_OK=false ;; esac
# the `connect)` case arm and membership in the `all` fan-out
printf '%s\n' "$D1_SRC" | grep -qE '^[[:space:]]*connect\)' || D1_OK=false
[ "$(printf '%s\n' "$D1_SRC" | grep -c '^[[:space:]]*check_connect_scripts[[:space:]]*$')" -ge 2 ] || D1_OK=false
# usage must advertise the component it now really supports
printf '%s\n' "$D1_SRC" | grep -qE '^[[:space:]]*connect[[:space:]]+' || D1_OK=false
if [ "$D1_OK" = true ]; then
    test_pass
else
    test_fail "libexec/commands/aiteamforge-doctor.sh must define check_connect_scripts, expose a 'connect)' case arm, call it from BOTH 'connect)' and 'all', and list it in usage; doctor=$DOCTOR_CMD"
fi

test_start "D2 [Blocker 2, sibling-drift]: the legacy bin/aiteamforge-doctor.sh does NOT also define check_connect_scripts"
# Mirrors test-xaca-0655-doctor-preflight.sh L3-A2: new doctor functionality
# lives ONLY in libexec/commands. Two copies of this check would drift, and the
# bin copy is not what `aiteamforge doctor` runs.
if [ ! -f "$BIN_DOCTOR" ]; then
    test_pass
else
    D2_SRC="$(cat "$BIN_DOCTOR")"
    D2_OK=true
    case "$D2_SRC" in *"check_connect_scripts"*) D2_OK=false ;; esac
    # and the CLI must still not dispatch to it
    case "$(cat "$CLI_SH" 2>/dev/null || true)" in
        *"bin/aiteamforge-doctor.sh"*) D2_OK=false ;;
    esac
    if [ "$D2_OK" = true ]; then
        test_pass
    else
        test_fail "bin/aiteamforge-doctor.sh must NOT define check_connect_scripts (it is not the CLI dispatch target — that is libexec/commands/aiteamforge-doctor.sh), and the CLI must not exec it"
    fi
fi

test_start "D3 [Blocker 2, END-TO-END]: 'aiteamforge doctor --check connect' through bin/aiteamforge-cli.sh actually runs the check"
D3_SBX="$(_new_install_sandbox)"
# One installed parametric instance with NO script (must be reported missing),
# one installed non-parametric instance WITH a script (must be reported
# present), and one orphan script (must be reported as matching nothing).
_write_install_config "$D3_SBX/aiteamforge/.aiteamforge-config" "finance:personal" "academy"
printf '#!/bin/zsh\necho stub\n' > "$D3_SBX/aiteamforge/academy-connect.sh"
printf '#!/bin/zsh\necho stub\n' > "$D3_SBX/aiteamforge/legal-default-connect.sh"
D3_LOG="$WORK_DIR/d3-doctor.log"
HOME="$D3_SBX/home" \
AITEAMFORGE_HOME="$TAP_ROOT" \
AITEAMFORGE_DIR="$D3_SBX/aiteamforge" \
AITEAMFORGE_CONFIG="$D3_SBX/home/.aiteamforge/team-paths.json" \
    bash "$CLI_SH" doctor --check connect >"$D3_LOG" 2>&1 || true
D3_OK=true
# The component must be RECOGNISED (the pre-fix failure mode was this exact
# message from the unknown-component arm).
grep -qi "Unknown component" "$D3_LOG" && D3_OK=false
# The check must actually have run and produced all three verdicts.
grep -qi "Connect Scripts" "$D3_LOG" || D3_OK=false
grep -qF "finance-personal" "$D3_LOG" || D3_OK=false
grep -qF "academy" "$D3_LOG" || D3_OK=false
grep -qF "legal-default" "$D3_LOG" || D3_OK=false
if [ "$D3_OK" = true ]; then
    test_pass
else
    test_fail "'aiteamforge doctor --check connect' must reach check_connect_scripts via the real CLI dispatch and report the missing (finance-personal), present (academy) and orphaned (legal-default) instances; output: $(cat "$D3_LOG")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# XACA-0845-015 — freelance (TEAM_REQUIRES_CLIENT_ID) coverage.
#
# The union and the doctor both read .aiteamforge-config but ignored
# `client_id`. freelance is the ONLY template shipping
# TEAM_REQUIRES_CLIENT_ID="true", and compute_instance_id() emits
# "<team>-<client>-<project>" for it. Composing only "<team>-<project>" produced
# an id the decomposition below then REJECTED ("cannot split ... into
# <client>-<project>"), so nothing was created and a live-but-scriptless
# freelance instance was unhealable — while the doctor simultaneously reported
# the phantom id missing AND the real on-disk script an orphan.
#
# This NARROWED relative to the pre-XACA-0845-008 code, which read the whole
# instance id from the team-paths.json key and so never had to compose.
#
# SAFETY: freelance.conf ships NON-EMPTY TEAM_BREW_DEPS (swiftlint, xcodegen,
# gradle, kotlin, node, firebase-cli) and TEAM_BREW_CASK_DEPS (xcode,
# android-studio) — unlike finance/academy, which S0 pins as empty. A FULL
# install of freelance in a sandbox could therefore invoke real `brew install`.
# Every freelance case below drives ONLY the upgrade/--connect-only path, which
# hits install-team.sh CONNECT-ONLY EARLY EXIT (`exit 0`, ~line 703) — textually
# and unconditionally ABOVE the brew-install section (~line 826). No freelance
# case may ever be converted to a full install without re-doing that analysis.
# ═══════════════════════════════════════════════════════════════════════════
test_start "T10 [XACA-0845-015]: upgrade composes freelance-<client>-<project> and renders it end-to-end (output team-scoped, XACA-0862)"
T10_SBX="$(_new_install_sandbox)"
T10_REGISTRY="$T10_SBX/home/.aiteamforge/team-paths.json"
_write_registry "$T10_REGISTRY"
_write_install_config "$T10_SBX/aiteamforge/.aiteamforge-config" "freelance:doublenode:starwords"
_write_install_profile_marker "$T10_SBX/aiteamforge" "full"
_install_print_stubs
HOME="$T10_SBX/home" \
AITEAMFORGE_ORG_CONFIG="$T10_SBX/home/.aiteamforge/organization.yaml" \
FRAMEWORK_DIR="$TAP_ROOT" WORKING_DIR="$T10_SBX/aiteamforge" LIBEXEC_DIR="$TAP_ROOT/libexec" DRY_RUN=false \
AITEAMFORGE_CONFIG="$T10_REGISTRY" \
    update_connect_scripts >"$WORK_DIR/t10-upgrade.log" 2>&1
# XACA-0862: the internal composition (upgrade -> install-team.sh --client
# doublenode --project starwords) is unchanged; only install-team.sh's OUTPUT
# filename changed, from the composed instance id to the team-scoped id.
T10_CONNECT="$T10_SBX/aiteamforge/freelance-connect.sh"
T10_DISCONNECT="$T10_SBX/aiteamforge/freelance-disconnect.sh"
T10_OK=true
[ -s "$T10_CONNECT" ] || T10_OK=false
[ -s "$T10_DISCONNECT" ] || T10_OK=false
# The upgrade path still had to round-trip the SAME decomposition (split the
# .aiteamforge-config remainder back into client + project and feed them to
# install-team.sh as --client/--project) to reach the render at all — a
# composition the decomposition could not reverse would still be skipped
# before ever calling the renderer, so this remains a meaningful check even
# though the renderer's own output filename is no longer client/project-qualified.
grep -qF 'TMUX_SOCKET="freelance"' "$T10_CONNECT" 2>/dev/null || T10_OK=false
# The pre-XACA-0845-015 symptoms must be gone.
grep -qi "cannot split" "$_STUB_LOG" && T10_OK=false
grep -qF "freelance-starwords-connect.sh" "$_STUB_LOG" && T10_OK=false
# No retired instance-scoped (doubly-qualified or client-less) twin.
[ -e "$T10_SBX/aiteamforge/freelance-doublenode-starwords-connect.sh" ] && T10_OK=false
[ -e "$T10_SBX/aiteamforge/freelance-starwords-connect.sh" ] && T10_OK=false
if [ "$T10_OK" = true ]; then
    test_pass
else
    test_fail "expected team-scoped freelance-connect/disconnect.sh with TMUX_SOCKET=\"freelance\" and no 'cannot split' warning, no instance-scoped twin; on_disk=$(ls -1 "$T10_SBX/aiteamforge" 2>/dev/null | tr '\n' ' '); stub_log=$(cat "$_STUB_LOG")"
fi

# ── NC4 [MANDATORY negative control for T10] ────────────────────────────────
# Proves T10 can FAIL: re-derive the PRE-FIX reader from the live source by
# reverting exactly the client-composing block, then drive the identical
# sandbox. The patch is pinned by a marker assertion first (house convention),
# so if the composition is ever restructured this control fails loudly rather
# than silently testing nothing.
test_start "NC4 [negative control, XACA-0845-015]: the client-ignoring reader composes 'freelance-starwords' and creates NOTHING"
NC4_SRC="$WORK_DIR/update_connect_scripts.prefix015.sh"
NC4_PATCH_OK=true
python3 - "$UPD_FN_SRC" "$NC4_SRC" <<'PYEOF' || NC4_PATCH_OK=false
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()

# Pin: the fixed composition must be present, or this control is testing nothing.
if 'cid = entry.get("client_id")' not in text:
    sys.exit("PIN FAILED: client-composing block not found in extracted source")

fixed = '''        entry = paths.get(base) or {}
        pid = entry.get("project_id")
        cid = entry.get("client_id")
        if pid:
            pid = str(pid).lower()
            if cid:
                out.append("%s-%s-%s" % (base, str(cid).lower(), pid))
            else:
                out.append("%s-%s" % (base, pid))
        else:
            out.append(base)
'''
prefix = '''        pid = (paths.get(base) or {}).get("project_id")
        out.append("%s-%s" % (base, str(pid).lower()) if pid else base)
'''
if fixed not in text:
    sys.exit("PIN FAILED: exact fixed composition block not matched")
text = text.replace(fixed, prefix)
text = text.replace("update_connect_scripts() {", "update_connect_scripts_prefix015() {", 1)
open(dst, "w").write(text)
PYEOF
if [ "$NC4_PATCH_OK" != true ] || [ ! -s "$NC4_SRC" ]; then
    test_fail "could not build the pre-fix fixture (pin check failed) — the negative control is not testing anything"
else
    # shellcheck disable=SC1090
    . "$NC4_SRC"
    NC4_SBX="$(_new_install_sandbox)"
    NC4_REGISTRY="$NC4_SBX/home/.aiteamforge/team-paths.json"
    _write_registry "$NC4_REGISTRY"
    _write_install_config "$NC4_SBX/aiteamforge/.aiteamforge-config" "freelance:doublenode:starwords"
    _install_print_stubs
    HOME="$NC4_SBX/home" \
    AITEAMFORGE_ORG_CONFIG="$NC4_SBX/home/.aiteamforge/organization.yaml" \
    FRAMEWORK_DIR="$TAP_ROOT" WORKING_DIR="$NC4_SBX/aiteamforge" LIBEXEC_DIR="$TAP_ROOT/libexec" DRY_RUN=false \
    AITEAMFORGE_CONFIG="$NC4_REGISTRY" \
        update_connect_scripts_prefix015 >"$WORK_DIR/nc4-upgrade.log" 2>&1
    # The defect, reproduced: the wrong id is composed, the decomposition
    # rejects it, and no script is created.
    if [ ! -e "$NC4_SBX/aiteamforge/freelance-doublenode-starwords-connect.sh" ] \
        && grep -qi "cannot split" "$_STUB_LOG" \
        && grep -qF "freelance-starwords" "$_STUB_LOG"; then
        test_pass
    else
        test_fail "pre-fix reader should have composed 'freelance-starwords', warned 'cannot split' and created nothing; on_disk=$(ls -1 "$NC4_SBX/aiteamforge" 2>/dev/null | tr '\n' ' '); stub_log=$(cat "$_STUB_LOG")"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# Doctor coverage: XACA-0845-015 (double false positive) and -016 (cockpit).
# Positive cases run the REAL CLI end-to-end, like D3.
# ═══════════════════════════════════════════════════════════════════════════
test_start "D4 [XACA-0845-015]: doctor reports a freelance install as PRESENT, not missing-plus-orphan"
D4_SBX="$(_new_install_sandbox)"
_write_install_config "$D4_SBX/aiteamforge/.aiteamforge-config" "freelance:doublenode:starwords"
_write_install_profile_marker "$D4_SBX/aiteamforge" "full"
# The script install-team.sh really renders for this install.
printf '#!/bin/zsh\necho stub\n' > "$D4_SBX/aiteamforge/freelance-doublenode-starwords-connect.sh"
D4_LOG="$WORK_DIR/d4-doctor.log"
HOME="$D4_SBX/home" \
AITEAMFORGE_HOME="$TAP_ROOT" \
AITEAMFORGE_DIR="$D4_SBX/aiteamforge" \
AITEAMFORGE_CONFIG="$D4_SBX/home/.aiteamforge/team-paths.json" \
    bash "$CLI_SH" doctor --check connect --verbose >"$D4_LOG" 2>&1 || true
D4_OK=true
grep -qF "Connect script present for freelance-doublenode-starwords" "$D4_LOG" || D4_OK=false
# Neither half of the double false positive may appear.
grep -qF "freelance-starwords" "$D4_LOG" && D4_OK=false
grep -qi "matches no installed instance" "$D4_LOG" && D4_OK=false
grep -qi "has no connect script" "$D4_LOG" && D4_OK=false
if [ "$D4_OK" = true ]; then
    test_pass
else
    test_fail "doctor must report freelance-doublenode-starwords present and emit neither a 'missing' nor an 'orphan' verdict; output: $(cat "$D4_LOG")"
fi

test_start "D5 [XACA-0845-016]: cockpit profile emits NO orphan warnings and NO remove-by-hand advice"
D5_SBX="$(_new_install_sandbox)"
# A cockpit install: EMPTY .teams[] by design, profile marker "cockpit",
# and the connect scripts that are the entire point of the box.
_write_install_config "$D5_SBX/aiteamforge/.aiteamforge-config" --profile cockpit
_write_install_profile_marker "$D5_SBX/aiteamforge" "cockpit"
for _t in academy ios android firebase command dns finance-personal legal-coparenting; do
    printf '#!/bin/zsh\necho stub\n' > "$D5_SBX/aiteamforge/${_t}-connect.sh"
done
D5_LOG="$WORK_DIR/d5-doctor.log"
HOME="$D5_SBX/home" \
AITEAMFORGE_HOME="$TAP_ROOT" \
AITEAMFORGE_DIR="$D5_SBX/aiteamforge" \
AITEAMFORGE_CONFIG="$D5_SBX/home/.aiteamforge/team-paths.json" \
    bash "$CLI_SH" doctor --check connect --verbose >"$D5_LOG" 2>&1 || true
D5_OK=true
# --verbose is deliberate: the destructive advice is the `detail` argument to
# check_result, which prints ONLY under VERBOSE. A non-verbose assertion would
# pass even if the advice were still being generated.
grep -qi "remove it by hand" "$D5_LOG" && D5_OK=false
grep -qi "matches no installed instance" "$D5_LOG" && D5_OK=false
# It must still say something useful rather than going silent.
grep -qi "Cockpit install" "$D5_LOG" || D5_OK=false
# And all 8 scripts must survive — this check never deletes.
D5_REMAINING="$(ls -1 "$D5_SBX/aiteamforge"/*-connect.sh 2>/dev/null | wc -l | tr -d '[:space:]')"
[ "$D5_REMAINING" = "8" ] || D5_OK=false
if [ "$D5_OK" = true ]; then
    test_pass
else
    test_fail "cockpit doctor run must emit no orphan warning and no deletion advice, still report the cockpit state, and leave all 8 scripts in place (remaining=$D5_REMAINING); output: $(cat "$D5_LOG")"
fi

test_start "D6 [XACA-0845-016]: a NON-cockpit box still gets its orphan report (the gate is profile-scoped, not a blanket mute)"
D6_SBX="$(_new_install_sandbox)"
_write_install_config "$D6_SBX/aiteamforge/.aiteamforge-config" "academy"
_write_install_profile_marker "$D6_SBX/aiteamforge" "full"
printf '#!/bin/zsh\necho stub\n' > "$D6_SBX/aiteamforge/academy-connect.sh"
printf '#!/bin/zsh\necho stub\n' > "$D6_SBX/aiteamforge/legal-default-connect.sh"
D6_LOG="$WORK_DIR/d6-doctor.log"
HOME="$D6_SBX/home" \
AITEAMFORGE_HOME="$TAP_ROOT" \
AITEAMFORGE_DIR="$D6_SBX/aiteamforge" \
AITEAMFORGE_CONFIG="$D6_SBX/home/.aiteamforge/team-paths.json" \
    bash "$CLI_SH" doctor --check connect --verbose >"$D6_LOG" 2>&1 || true
if grep -qF "legal-default-connect.sh' matches no installed instance" "$D6_LOG" \
    && grep -qF "Connect script present for academy" "$D6_LOG"; then
    test_pass
else
    test_fail "a full-profile box must still report legal-default as an orphan and academy as present; output: $(cat "$D6_LOG")"
fi

# ── NC5 [MANDATORY negative control for D5] ─────────────────────────────────
# Proves D5 can FAIL: rebuild the profile-BLIND direction-2 from the live
# source by deleting the cockpit gate, then run it against the same
# cockpit-shaped sandbox. Pinned by a marker assertion.
test_start "NC5 [negative control, XACA-0845-016]: the profile-blind check warns on all 8 cockpit scripts and advises deleting them"
NC5_FNS="$WORK_DIR/doctor-connect.prefix016.sh"
NC5_PATCH_OK=true
python3 - "$DOCTOR_CMD" "$NC5_FNS" <<'PYEOF' || NC5_PATCH_OK=false
import re, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()

def extract(name, body):
    m = re.search(r"^%s\(\) \{\n(.*?)^\}\n" % re.escape(name), body, re.S | re.M)
    if not m:
        sys.exit("PIN FAILED: could not extract %s" % name)
    return m.group(0)

profile_fn = extract("_connect_scripts_install_profile", text)
check_fn = extract("check_connect_scripts", text)

# Pin: the cockpit gate must exist, or this control is testing nothing.
if 'if [ "$_profile" = "cockpit" ]; then' not in check_fn:
    sys.exit("PIN FAILED: cockpit gate not present in check_connect_scripts")

# Revert to the profile-blind form: run direction 2 unconditionally.
# Match the real block textually rather than reconstructing it.
m = re.search(r'  if \[ "\$_profile" = "cockpit" \]; then\n.*?\n  fi\n', check_fn, re.S)
if not m:
    sys.exit("PIN FAILED: could not locate the cockpit-gated direction-2 block")
blind = '''  while IFS= read -r _inst; do
    [ -n "$_inst" ] || continue
    if ! printf '%s\\n' "$_installed" | grep -qx -- "$_inst"; then
      _orphans=$((_orphans + 1))
      check_result warn "Connect script '${_inst}-connect.sh' matches no installed instance" \\
        "Left in place deliberately. If it is genuinely unused, remove it by hand."
    fi
  done <<< "$_on_disk"
'''
check_fn = check_fn.replace(m.group(0), blind)
check_fn = check_fn.replace('&& [ "$_profile" != "cockpit" ]', "")
open(dst, "w").write(profile_fn + "\n" + check_fn)
PYEOF
if [ "$NC5_PATCH_OK" != true ] || [ ! -s "$NC5_FNS" ]; then
    test_fail "could not build the profile-blind fixture (pin check failed) — the negative control is not testing anything"
else
    # Run in a generated script so the doctor stubs never leak into the
    # upgrade tests sharing this shell.
    NC5_RUNNER="$WORK_DIR/nc5-runner.sh"
    cat > "$NC5_RUNNER" <<'RUNEOF'
#!/bin/bash
WD="$1"; FNS="$2"
VERBOSE=true
TOTAL_CHECKS=0; PASSED_CHECKS=0; WARNING_CHECKS=0; FAILED_CHECKS=0
print_section() { printf 'SECTION %s\n' "$*"; }
print_success() { printf 'PASS %s\n' "$*"; }
print_warning() { printf 'WARN %s\n' "$*"; }
print_error()   { printf 'ERR %s\n' "$*"; }
check_result() {
  status="$1"; message="$2"; detail="${3:-}"
  case "$status" in
    pass) print_success "$message" ;;
    warn) print_warning "$message" ;;
    fail) print_error "$message" ;;
  esac
  if [ -n "$detail" ]; then printf 'ADVICE %s\n' "$detail"; fi
  return 0
}
get_working_dir() { printf '%s\n' "$WD"; }
. "$FNS"
check_connect_scripts
RUNEOF
    NC5_SBX="$(_new_install_sandbox)"
    _write_install_config "$NC5_SBX/aiteamforge/.aiteamforge-config" --profile cockpit
    _write_install_profile_marker "$NC5_SBX/aiteamforge" "cockpit"
    for _t in academy ios android firebase command dns finance-personal legal-coparenting; do
        printf '#!/bin/zsh\necho stub\n' > "$NC5_SBX/aiteamforge/${_t}-connect.sh"
    done
    NC5_LOG="$WORK_DIR/nc5.log"
    bash "$NC5_RUNNER" "$NC5_SBX/aiteamforge" "$NC5_FNS" >"$NC5_LOG" 2>&1 || true
    NC5_WARNS="$(grep -c "matches no installed instance" "$NC5_LOG" | tr -d '[:space:]')"
    NC5_ADVICE="$(grep -c "remove it by hand" "$NC5_LOG" | tr -d '[:space:]')"
    if [ "$NC5_WARNS" = "8" ] && [ "$NC5_ADVICE" = "8" ]; then
        test_pass
    else
        test_fail "profile-blind check should have produced 8 orphan warnings and 8 deletion-advice lines on a cockpit box (got warns=$NC5_WARNS advice=$NC5_ADVICE); output: $(cat "$NC5_LOG")"
    fi
fi

test_start "S4 [XACA-0845-016]: the cockpit gate suppresses REPORTING only — no deletion path exists on any profile"
# Companion to S2 (which covers install-team.sh + upgrade). The doctor is now
# the only other file that reasons about connect scripts, and the -016 fix must
# not have introduced a "clean up the orphans" shortcut on any profile.
S4_SRC="$(cat "$DOCTOR_CMD")"
S4_OK=true
if printf '%s\n' "$S4_SRC" | grep -nE '\b(rm|unlink|shred)\b[^|]*-(connect|disconnect)\.sh' >/dev/null 2>&1; then
    S4_OK=false
fi
if printf '%s\n' "$S4_SRC" | grep -nE 'find[^|]*-(connect|disconnect)\.sh[^|]*-delete' >/dev/null 2>&1; then
    S4_OK=false
fi
if [ "$S4_OK" = true ]; then
    test_pass
else
    test_fail "aiteamforge-doctor.sh must contain no deletion path for *-connect.sh / *-disconnect.sh: $(printf '%s\n' "$S4_SRC" | grep -nE '\b(rm|unlink|shred|find)\b.*-(connect|disconnect)\.sh')"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary (standalone only; test-runner.sh owns totals when sourced by it).
# ─────────────────────────────────────────────────────────────────────────────
if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "XACA-0845 connect-script tests: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    [ "${_FAIL_COUNT:-0}" -eq 0 ] || exit 1
fi
exit 0
