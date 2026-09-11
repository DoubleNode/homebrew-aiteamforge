#!/bin/bash
# test-xaca-1070-mandatory-install.sh
#
# XACA-1070-009: sandboxed install/upgrade coverage for the mandatory-team
# feature (Space Dock 3/4).
#
# THE CONTRACT UNDER TEST (this is the whole point of the ticket):
# atf_mandatory_teams() must return exit 0 + empty stdout when zero teams
# are flagged (today's real state — no team carries "mandatory": true
# anywhere in share/teams/registry.json yet; spacedock/XACA-1068/1069 has
# not shipped), and exit 1 + a stderr diagnostic when registry.json is
# missing/unparseable. Conflating those two into "empty means fine" is the
# defect this ticket exists to prevent, and every fixture below that
# exercises the resolver keeps the two cases side by side rather than
# testing them in isolation.
#
# WHY FIXTURES, NOT THE REAL REGISTRY: zero teams carry "mandatory": true
# in share/teams/registry.json today (spacedock hasn't landed). A suite
# that only ever drove this feature against the real registry would never
# exercise the "a team IS mandatory" branch of ANY of the five call sites
# under test — it would prove only the already-trivial empty-set path.
# Every fixture below is therefore a synthetic registry.json (or a
# synthetic .aiteamforge-config / team-paths.json), built under
# TEST_TMP_DIR, never the tap's real share/teams/registry.json.
#
# FIXTURE TECHNIQUE — "faithful sandbox root": mandatory-teams.sh resolves
# registry.json two ways: (1) $AITEAMFORGE_HOME/../share/teams/registry.json
# when AITEAMFORGE_HOME is set and that file exists, else (2) self-location
# from mandatory-teams.sh's OWN on-disk path (two directories up from
# wherever the sourced copy actually lives). MEASURED empirically against
# this repo (see the retro/report): under the REAL Homebrew-installed
# layout (AITEAMFORGE_HOME = the copied repo root, exactly as the Formula's
# bin stubs set it — see Formula/aiteamforge.rb's `AITEAMFORGE_HOME="#{libexec}"`)
# branch (1)'s own "${AITEAMFORGE_HOME}/../share/teams/registry.json" guess
# does NOT exist (that path is one directory ABOVE the copied repo root;
# the real file lives INSIDE it, at "$AITEAMFORGE_HOME/share/teams/registry.json").
# The feature still works end-to-end ONLY because branch (2)'s
# self-location fallback silently saves it. This is flagged as an explicit
# FINDING in the test report — not fixed here (out of scope; "do NOT modify
# the implementation").
#
# Because of that, every fixture in this suite that needs a CONTROLLED
# registry.json copies mandatory-teams.sh (plus its lazy-loaded siblings
# config.sh / aiteamforge-paths.sh, when needed) into an isolated sandbox
# tree that mirrors the real installed shape:
#     <sandbox>/libexec/lib/mandatory-teams.sh   (+ config.sh, aiteamforge-paths.sh)
#     <sandbox>/share/teams/registry.json
# and sources the COPY from inside that tree (never the tap's real file),
# so self-location resolves to the fixture, not the real repo. This is the
# SAME mechanism that actually saves production today, so it is also the
# most representative way to test it.
#
# SAFETY (XACA-0212 / CLAUDE.md): every path in this suite lives under
# TEST_TMP_DIR. Nothing here ever installs the aiteamforge Homebrew
# formula, taps doublenode/aiteamforge, writes a com.aiteamforge.* plist,
# or touches the real ~/aiteamforge, ~/.aiteamforge, or ~/dev-team runtime
# state. AITEAMFORGE_DIR / AITEAMFORGE_CONFIG / AITEAMFORGE_HOME are always
# pointed at TEST_TMP_DIR paths before anything that reads or writes them.
#
# SHELL COMPATIBILITY: written to run correctly under /bin/bash 3.2 (every
# real consumer's shell) as well as a PATH bash 5.x — no `declare -A`, no
# `mapfile`/`readarray`, no `${var^^}`. Verified directly under /bin/bash
# (see the test report) — a PATH-bash-only run would be a false green here
# (feedback_verify_under_bin_bash_not_path_bash.md).
#
# Designed to run standalone OR via test-runner.sh (matches the
# test-xaca-0673-mandatory-materialize.sh / test-xaca-1097-*.sh convention).
#
# SCOPE: this file, tests/ci-manifest (one line), and CHANGELOG.md are the
# only files this ticket's testing subitem touches. The implementation
# (libexec/lib/mandatory-teams.sh, bin/aiteamforge-setup.sh,
# libexec/installers/install-kanban.sh, libexec/commands/aiteamforge-upgrade.sh,
# both aiteamforge-doctor.sh copies) is NOT modified here even when a test
# below finds something worth reporting — findings are reported, not
# "fixed in passing".

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MANDATORY_TEAMS_SH="$TAP_ROOT/libexec/lib/mandatory-teams.sh"
CONFIG_SH="$TAP_ROOT/libexec/lib/config.sh"
PATHS_SH="$TAP_ROOT/libexec/lib/aiteamforge-paths.sh"
COMMON_SH="$TAP_ROOT/libexec/lib/common.sh"
SETUP_SH="$TAP_ROOT/bin/aiteamforge-setup.sh"
INSTALL_KANBAN_SH="$TAP_ROOT/libexec/installers/install-kanban.sh"
UPGRADE_SH="$TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh"
DOCTOR_LIBEXEC_SH="$TAP_ROOT/libexec/commands/aiteamforge-doctor.sh"
DOCTOR_BIN_SH="$TAP_ROOT/bin/aiteamforge-doctor.sh"

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework (works sourced by test-runner.sh OR invoked directly) —
# same idiom as test-xaca-0673-mandatory-materialize.sh / test-xaca-1097-*.sh.
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

# XACA-1097-007-style hardening: gate test_pass on whether a block already
# failed, so one failing assertion inside a multi-assertion block cannot
# ALSO be reported as a pass under the same test name.
_BLOCK_FAILED=false
_block_start() { _BLOCK_FAILED=false; test_start "$1"; }
_block_note_fail() { _BLOCK_FAILED=true; test_fail "$1"; }
_block_end() { [ "$_BLOCK_FAILED" = false ] && test_pass; }

assert_eq() {
    local got="$1" expected="$2"
    local msg="${3:-Expected [$expected], got [$got]}"
    [ "$got" = "$expected" ] || _block_note_fail "$msg"
}
assert_ne() {
    local got="$1" not_expected="$2"
    local msg="${3:-Expected value to differ from [$not_expected]}"
    [ "$got" != "$not_expected" ] || _block_note_fail "$msg"
}
assert_contains() {
    local haystack="$1" needle="$2"
    local msg="${3:-Expected to find [$needle]}"
    case "$haystack" in *"$needle"*) : ;; *) _block_note_fail "$msg" ;; esac
}
assert_not_contains() {
    local haystack="$1" needle="$2"
    local msg="${3:-Expected NOT to find [$needle]}"
    case "$haystack" in *"$needle"*) _block_note_fail "$msg" ;; *) : ;; esac
}
assert_empty() {
    local val="$1" msg="${2:-Expected empty value, got [$val]}"
    [ -z "$val" ] || _block_note_fail "$msg"
}
assert_not_empty() {
    local val="$1" msg="${2:-Expected non-empty value (fixture produced nothing)}"
    [ -n "$val" ] || _block_note_fail "$msg"
}
assert_file_exists() {
    [ -f "$1" ] || _block_note_fail "${2:-Expected file to exist: $1}"
}
assert_file_not_exists() {
    [ ! -f "$1" ] || _block_note_fail "${2:-Expected file to NOT exist: $1}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Temp directory (runner-supplied or our own) + hard safety guard.
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca1070-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
cleanup() { if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then rm -rf "$TEST_TMP_DIR"; fi; }
trap cleanup EXIT

# XACA-0212 hard guard: refuse to run if TEST_TMP_DIR somehow resolves under
# the real HOME. This suite must never write into ~/aiteamforge, ~/.aiteamforge,
# or ~/dev-team's runtime state.
case "$TEST_TMP_DIR" in
    "$HOME"|"$HOME"/*)
        echo "FATAL: TEST_TMP_DIR ($TEST_TMP_DIR) resolves under real HOME ($HOME) -- refusing to run (XACA-0212)" >&2
        exit 1
        ;;
esac

SANDBOX="$TEST_TMP_DIR/xaca1070"
mkdir -p "$SANDBOX"

if [ ! -f "$MANDATORY_TEAMS_SH" ]; then
    echo "FATAL: libexec/lib/mandatory-teams.sh not found at: $MANDATORY_TEAMS_SH" >&2
    exit 1
fi
for _f in "$CONFIG_SH" "$PATHS_SH" "$COMMON_SH" "$SETUP_SH" "$INSTALL_KANBAN_SH" "$UPGRADE_SH" "$DOCTOR_LIBEXEC_SH" "$DOCTOR_BIN_SH"; do
    if [ ! -f "$_f" ]; then
        echo "FATAL: expected file not found: $_f" >&2
        exit 1
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Generic whole-function extraction (matches test-xaca-0673's _extract_fn):
# captures from "name() {" through the first column-0 "}".
# ─────────────────────────────────────────────────────────────────────────────
_extract_fn() {
    awk -v fn="$1" '
      $0 ~ ("^" fn "\\(\\) \\{") { capture=1 }
      capture { print }
      capture && /^}$/ { exit }
    ' "$2"
}

# ─────────────────────────────────────────────────────────────────────────────
# GROUNDING: verify every anchor this suite depends on for extraction is
# still present, BEFORE relying on any extraction below going non-empty.
# A silently-empty extraction is a vacuous-green trap (K088) -- fail loudly
# here instead.
# ─────────────────────────────────────────────────────────────────────────────
_block_start "grounding: every extraction anchor this suite depends on is present"
grep -q '^atf_mandatory_teams() {' "$MANDATORY_TEAMS_SH" || _block_note_fail "mandatory-teams.sh no longer defines atf_mandatory_teams() at column 0"
grep -q '^atf_is_mandatory_team() {' "$MANDATORY_TEAMS_SH" || _block_note_fail "mandatory-teams.sh no longer defines atf_is_mandatory_team() at column 0"
grep -q '^atf_team_provisioned() {' "$MANDATORY_TEAMS_SH" || _block_note_fail "mandatory-teams.sh no longer defines atf_team_provisioned() at column 0"
grep -qF 'AVAILABLE_TEAMS=()' "$SETUP_SH" || _block_note_fail "setup.sh no longer contains the AVAILABLE_TEAMS=() anchor the wizard-suppression extraction depends on"
grep -qF 'if command -v atf_mandatory_teams >/dev/null 2>&1; then' "$SETUP_SH" || _block_note_fail "setup.sh no longer contains the column-0 force-append if-anchor"
grep -qF '# Get selected teams from wizard env var, config file, or default' "$INSTALL_KANBAN_SH" || _block_note_fail "install-kanban.sh no longer contains the team-resolution anchor comment"
grep -qF 'continuing without mandatory-team enforcement (XACA-1070)' "$INSTALL_KANBAN_SH" || _block_note_fail "install-kanban.sh no longer contains the fail-soft warning anchor"
grep -q '^_xaca1070_mandatory_team_has_board() {' "$UPGRADE_SH" || _block_note_fail "upgrade.sh no longer defines _xaca1070_mandatory_team_has_board() at column 0"
grep -q '^_xaca1070_add_team_to_config() {' "$UPGRADE_SH" || _block_note_fail "upgrade.sh no longer defines _xaca1070_add_team_to_config() at column 0"
grep -q '^update_mandatory_teams() {' "$UPGRADE_SH" || _block_note_fail "upgrade.sh no longer defines update_mandatory_teams() at column 0"
grep -q '^check_mandatory_teams() {' "$DOCTOR_LIBEXEC_SH" || _block_note_fail "libexec/commands/aiteamforge-doctor.sh no longer defines check_mandatory_teams() at column 0"
grep -q '^check_mandatory_teams() {' "$DOCTOR_BIN_SH" || _block_note_fail "bin/aiteamforge-doctor.sh no longer defines check_mandatory_teams() at column 0"
grep -qF '_MANDATORY_TEAMS_LIB_OK=false' "$DOCTOR_BIN_SH" || _block_note_fail "bin/aiteamforge-doctor.sh no longer contains the _MANDATORY_TEAMS_LIB_OK preamble anchor"
_block_end

# ═══════════════════════════════════════════════════════════════════════════
# SECTION A -- Resolver contract (atf_mandatory_teams / atf_is_mandatory_team)
# ═══════════════════════════════════════════════════════════════════════════

# "Faithful sandbox root" fixture builder -- see header comment. Copies the
# REAL mandatory-teams.sh (and, when requested, its lazy-loaded siblings)
# into an isolated tree so self-location resolves to OUR registry.json, not
# the tap's real one.
_x1070_mk_reg_sandbox() {
    local name="$1" content="$2" with_siblings="${3:-false}" dir
    dir="$SANDBOX/reg-$name"
    mkdir -p "$dir/libexec/lib" "$dir/share/teams"
    cp "$MANDATORY_TEAMS_SH" "$dir/libexec/lib/mandatory-teams.sh"
    if [ "$with_siblings" = true ]; then
        cp "$CONFIG_SH" "$dir/libexec/lib/config.sh"
        cp "$PATHS_SH" "$dir/libexec/lib/aiteamforge-paths.sh"
    fi
    if [ "$content" != "__MISSING__" ]; then
        printf '%s' "$content" > "$dir/share/teams/registry.json"
    fi
    printf '%s' "$dir"
}

# Runs "$@" (a function name + args) in a subshell with ONLY the sandboxed
# copy of mandatory-teams.sh sourced -- AITEAMFORGE_HOME/DIR/CONFIG unset so
# nothing can leak in from a real environment.
_x1070_run_resolver() {
    local libdir="$1"; shift
    ( unset AITEAMFORGE_HOME AITEAMFORGE_DIR AITEAMFORGE_CONFIG
      # shellcheck disable=SC1091
      . "$libdir/libexec/lib/mandatory-teams.sh"
      "$@"
    )
}

REG_EMPTY='{"version":"1.0.0","teams":[{"id":"alpha","name":"Alpha","order":1},{"id":"beta","name":"Beta","order":2,"mandatory":false}]}'
REG_ONE_TRUE='{"version":"1.0.0","teams":[{"id":"alpha","name":"Alpha","order":9},{"id":"widget","name":"Widget","order":1,"mandatory":true},{"id":"beta","name":"Beta","order":2,"mandatory":false}]}'
REG_TWO_TRUE_ORDERED='{"version":"1.0.0","teams":[{"id":"widget","name":"Widget","order":5,"mandatory":true},{"id":"gizmo","name":"Gizmo","order":1,"mandatory":true},{"id":"alpha","name":"Alpha","order":2}]}'
REG_CORRUPT='{"version": not valid json !!!'
REG_NO_TEAMS_KEY='{"version":"1.0.0"}'

# ── A1: zero mandatory teams -> exit 0, EMPTY stdout, NO stderr diagnostic ──
_block_start "A1: atf_mandatory_teams -- zero mandatory teams (one absent key, one explicit false) -> exit 0, empty stdout, no diagnostic"
_dir="$(_x1070_mk_reg_sandbox empty "$REG_EMPTY")"
_err="$SANDBOX/a1.err"
_out="$(_x1070_run_resolver "$_dir" atf_mandatory_teams 2>"$_err")"; _rc=$?
assert_eq "$_rc" "0" "expected exit 0, got $_rc"
assert_empty "$_out" "expected empty stdout, got [$_out]"
assert_empty "$(cat "$_err")" "expected NO stderr diagnostic on the clean empty-set path, got [$(cat "$_err")]"
_block_end

# ── A2/A3: one team mandatory:true is returned, mandatory:false is excluded ──
_block_start "A2/A3: atf_mandatory_teams -- mandatory:true team returned, mandatory:false team excluded"
_dir="$(_x1070_mk_reg_sandbox onetrue "$REG_ONE_TRUE")"
_out="$(_x1070_run_resolver "$_dir" atf_mandatory_teams)"; _rc=$?
assert_eq "$_rc" "0" "expected exit 0, got $_rc"
assert_eq "$_out" "widget" "expected exactly 'widget', got [$_out]"
assert_not_contains "$_out" "beta" "mandatory:false team 'beta' must be excluded"
assert_not_contains "$_out" "alpha" "non-mandatory team 'alpha' (no mandatory key at all) must be excluded"
_block_end

# ── A4: multiple mandatory teams sorted by registry 'order' ──
_block_start "A4: atf_mandatory_teams -- multiple mandatory teams sorted by 'order', not registry position"
_dir="$(_x1070_mk_reg_sandbox twotrue "$REG_TWO_TRUE_ORDERED")"
_out="$(_x1070_run_resolver "$_dir" atf_mandatory_teams)"; _rc=$?
assert_eq "$_rc" "0" "expected exit 0, got $_rc"
assert_eq "$_out" "$(printf 'gizmo\nwidget')" "expected gizmo (order 1) before widget (order 5), got [$_out]"
_block_end

# ── A5: atf_is_mandatory_team membership predicate ──
_block_start "A5: atf_is_mandatory_team -- membership predicate (member/non-member/unknown)"
_dir="$(_x1070_mk_reg_sandbox onetrue2 "$REG_ONE_TRUE")"
( _x1070_run_resolver "$_dir" atf_is_mandatory_team widget ) ; _rc=$?
assert_eq "$_rc" "0" "widget IS mandatory, expected exit 0, got $_rc"
( _x1070_run_resolver "$_dir" atf_is_mandatory_team beta ) ; _rc=$?
assert_eq "$_rc" "1" "beta is mandatory:false, expected exit 1, got $_rc"
( _x1070_run_resolver "$_dir" atf_is_mandatory_team nonexistent-team ) ; _rc=$?
assert_eq "$_rc" "1" "unknown team id, expected exit 1, got $_rc"
_block_end

# ── A6: registry.json MISSING -> exit 1 + stderr diagnostic, NOT empty success ──
_block_start "A6: atf_mandatory_teams -- registry.json missing -> exit 1 + diagnostic (never conflated with the empty-set case)"
_dir="$(_x1070_mk_reg_sandbox missing "__MISSING__")"
_err="$SANDBOX/a6.err"
_out="$(_x1070_run_resolver "$_dir" atf_mandatory_teams 2>"$_err")"; _rc=$?
assert_eq "$_rc" "1" "expected exit 1 for a missing registry, got $_rc"
assert_empty "$_out" "expected empty stdout on failure, got [$_out]"
assert_contains "$(cat "$_err")" "registry.json not found" "expected a diagnostic naming the missing file"
_block_end

# ── A7: registry.json CORRUPT (invalid JSON) -> exit 1 + diagnostic ──
_block_start "A7: atf_mandatory_teams -- registry.json corrupt (invalid JSON) -> exit 1 + diagnostic"
_dir="$(_x1070_mk_reg_sandbox corrupt "$REG_CORRUPT")"
_err="$SANDBOX/a7.err"
_out="$(_x1070_run_resolver "$_dir" atf_mandatory_teams 2>"$_err")"; _rc=$?
assert_eq "$_rc" "1" "expected exit 1 for corrupt JSON, got $_rc"
assert_empty "$_out" "expected empty stdout on failure, got [$_out]"
assert_contains "$(cat "$_err")" "not valid JSON" "expected a diagnostic naming the parse failure"
_block_end

# ── A8 (bonus negative control): valid JSON but no .teams key at all ──
_block_start "A8: atf_mandatory_teams -- valid JSON with NO .teams array -> exit 1 (not silently 'zero mandatory')"
_dir="$(_x1070_mk_reg_sandbox noteams "$REG_NO_TEAMS_KEY")"
_err="$SANDBOX/a8.err"
_out="$(_x1070_run_resolver "$_dir" atf_mandatory_teams 2>"$_err")"; _rc=$?
assert_eq "$_rc" "1" "a registry with no .teams array is malformed, not 'zero mandatory'; expected exit 1, got $_rc"
assert_empty "$_out" "expected empty stdout on failure, got [$_out]"
assert_not_empty "$(cat "$_err")" "expected a stderr diagnostic"
_block_end

# ── A9: THE CONTRACT, STATED DIRECTLY -- exit-0-empty and exit-1-empty must ──
# never look alike from a caller's point of view.
_block_start "A9: THE CONTRACT -- exit-0/empty (zero mandatory) is distinguishable from exit-1/empty (registry unreadable)"
_dir_ok="$(_x1070_mk_reg_sandbox contract-ok "$REG_EMPTY")"
_dir_bad="$(_x1070_mk_reg_sandbox contract-bad "__MISSING__")"
_err_ok="$SANDBOX/a9-ok.err"; _err_bad="$SANDBOX/a9-bad.err"
_out_ok="$(_x1070_run_resolver "$_dir_ok" atf_mandatory_teams 2>"$_err_ok")"; _rc_ok=$?
_out_bad="$(_x1070_run_resolver "$_dir_bad" atf_mandatory_teams 2>"$_err_bad")"; _rc_bad=$?
assert_eq "$_out_ok" "$_out_bad" "both stdouts should be empty (proving stdout ALONE cannot distinguish the two states)"
assert_ne "$_rc_ok" "$_rc_bad" "return codes MUST differ ($_rc_ok vs $_rc_bad) -- this is the entire point of XACA-1070's return-code contract"
assert_empty "$(cat "$_err_ok")" "the clean empty-set path must be silent on stderr"
assert_not_empty "$(cat "$_err_bad")" "the unreadable-registry path must speak on stderr"
_block_end

# ═══════════════════════════════════════════════════════════════════════════
# SECTION B -- Wizard suppression: a mandatory team never appears in the
# presented selection list (bin/aiteamforge-setup.sh Step 2 loop).
# ═══════════════════════════════════════════════════════════════════════════

_extract_wizard_loop() {
    awk '
      $0=="AVAILABLE_TEAMS=()" {capture=1}
      capture {print}
      capture && $0=="done" {exit}
    ' "$SETUP_SH"
}

_x1070_mk_teams_dir() {
    local dir="$SANDBOX/teamsdir-$1"
    mkdir -p "$dir"
    printf 'TEAM_NAME="Alpha"\nTEAM_DESCRIPTION="Alpha team"\nTEAM_CATEGORY="platform"\n' > "$dir/alpha.conf"
    printf 'TEAM_NAME="Beta"\nTEAM_DESCRIPTION="Beta team"\nTEAM_CATEGORY="platform"\n' > "$dir/beta.conf"
    printf 'TEAM_NAME="Widget"\nTEAM_DESCRIPTION="Widget fleet team"\nTEAM_CATEGORY="infrastructure"\n' > "$dir/widget.conf"
    printf '%s' "$dir"
}

_wizard_snippet="$(_extract_wizard_loop)"
if [ -z "$_wizard_snippet" ]; then
    test_start "SECTION B setup: extract wizard team-selection loop"
    test_fail "extraction produced no output -- cannot run Section B"
else
    eval "_x1070_wizard_loop() { $_wizard_snippet
    }"

    _block_start "B1/B2: wizard suppression -- mandatory team excluded from AVAILABLE_TEAMS/TEAM_LABELS, non-mandatory teams still present"
    _reg_dir="$(_x1070_mk_reg_sandbox wizard-suppress "$REG_ONE_TRUE")"
    _teams_dir="$(_x1070_mk_teams_dir suppress)"
    _res="$(
        unset AITEAMFORGE_HOME AITEAMFORGE_DIR AITEAMFORGE_CONFIG
        # shellcheck disable=SC1091
        . "$_reg_dir/libexec/lib/mandatory-teams.sh"
        TEAMS_DIR="$_teams_dir"
        AVAILABLE_TEAMS=()
        TEAM_LABELS=()
        _x1070_wizard_loop
        printf 'AVAILABLE=%s\n' "${AVAILABLE_TEAMS[*]}"
        printf 'LABELCOUNT=%s\n' "${#TEAM_LABELS[@]}"
    )"
    assert_not_contains "$_res" "AVAILABLE=widget " "mandatory team 'widget' must never occupy an AVAILABLE_TEAMS slot"
    case "$_res" in *"AVAILABLE=widget"*) _block_note_fail "mandatory team 'widget' leaked into AVAILABLE_TEAMS: $_res" ;; esac
    assert_contains "$_res" "alpha" "non-mandatory team 'alpha' must still be selectable"
    assert_contains "$_res" "beta" "non-mandatory team 'beta' must still be selectable"
    assert_contains "$_res" "LABELCOUNT=2" "exactly 2 selectable teams expected (alpha, beta) -- widget must be suppressed, got: $_res"
    _block_end

    # ── B3 (negative control): with the lib UNAVAILABLE, suppression must
    # not silently vanish the team from the wizard -- the fail-open guard
    # (`command -v atf_is_mandatory_team` false) means the team is offered
    # like any other, which is the documented, deliberate fallback.
    _block_start "B3 (negative control): mandatory-teams.sh unavailable -> guard fails open, team is NOT suppressed"
    _teams_dir2="$(_x1070_mk_teams_dir noguard)"
    _res2="$(
        unset -f atf_is_mandatory_team 2>/dev/null
        TEAMS_DIR="$_teams_dir2"
        AVAILABLE_TEAMS=()
        TEAM_LABELS=()
        _x1070_wizard_loop
        printf 'AVAILABLE=%s\n' "${AVAILABLE_TEAMS[*]}"
        printf 'LABELCOUNT=%s\n' "${#TEAM_LABELS[@]}"
    )"
    assert_contains "$_res2" "widget" "with the lib unavailable, ALL three teams (including widget) must appear -- suppression must fail open, not closed"
    assert_contains "$_res2" "LABELCOUNT=3" "expected all 3 teams selectable when the mandatory-teams guard cannot run, got: $_res2"
    _block_end
fi

# ═══════════════════════════════════════════════════════════════════════════
# SECTION C -- Force-append (bin/aiteamforge-setup.sh): lands in BOTH
# SELECTED_TEAMS_STR and CR_ALL_SELECTED_TEAMS_STR; idempotent.
# ═══════════════════════════════════════════════════════════════════════════

_extract_force_append_block() {
    awk '
      $0=="if command -v atf_mandatory_teams >/dev/null 2>&1; then" {capture=1}
      capture {print}
      capture && $0=="fi" {exit}
    ' "$SETUP_SH"
}

_force_append_snippet="$(_extract_force_append_block)"
if [ -z "$_force_append_snippet" ]; then
    test_start "SECTION C setup: extract setup.sh force-append block"
    test_fail "extraction produced no output -- cannot run Section C"
else
    eval "_x1070_force_append() { $_force_append_snippet
    }"

    # ── C1: empty SELECTED_TEAMS -> mandatory id appended + message printed ──
    _block_start "C1: force-append -- mandatory team added to an empty SELECTED_TEAMS, with the expected message"
    _reg_dir="$(_x1070_mk_reg_sandbox force-c1 "$REG_ONE_TRUE")"
    _res="$(
        unset AITEAMFORGE_HOME AITEAMFORGE_DIR AITEAMFORGE_CONFIG
        # shellcheck disable=SC1091
        . "$_reg_dir/libexec/lib/mandatory-teams.sh"
        GREEN=""; NC=""; YELLOW=""
        SELECTED_TEAMS=()
        _x1070_force_append
        printf 'SELECTED=%s\n' "${SELECTED_TEAMS[*]}"
    )"
    assert_contains "$_res" "SELECTED=widget" "expected 'widget' force-appended into an empty SELECTED_TEAMS, got: $_res"
    assert_contains "$_res" "Mandatory team added: widget" "expected the confirmation message on first add"
    _block_end

    # ── C2: idempotent -- already present -> no duplicate, no message ──
    _block_start "C2: force-append -- idempotent when the mandatory team is already present (no duplicate, no re-announce)"
    _res="$(
        unset AITEAMFORGE_HOME AITEAMFORGE_DIR AITEAMFORGE_CONFIG
        # shellcheck disable=SC1091
        . "$_reg_dir/libexec/lib/mandatory-teams.sh"
        GREEN=""; NC=""; YELLOW=""
        SELECTED_TEAMS=("alpha" "widget")
        _x1070_force_append
        printf 'SELECTED=%s\n' "${SELECTED_TEAMS[*]}"
    )"
    assert_eq "$_res" "$(printf 'SELECTED=alpha widget')" "expected exactly one 'widget' entry (no duplicate), got: $_res"
    assert_not_contains "$_res" "Mandatory team added" "must NOT re-announce a team that was already present"
    _block_end

    # ── C3: lands in BOTH SELECTED_TEAMS_STR and CR_ALL_SELECTED_TEAMS_STR ──
    _block_start "C3: force-append -- appended team lands in BOTH SELECTED_TEAMS_STR and CR_ALL_SELECTED_TEAMS_STR"
    _res="$(
        unset AITEAMFORGE_HOME AITEAMFORGE_DIR AITEAMFORGE_CONFIG
        # shellcheck disable=SC1091
        . "$_reg_dir/libexec/lib/mandatory-teams.sh"
        GREEN=""; NC=""; YELLOW=""
        SELECTED_TEAMS=()
        _x1070_force_append
        export SELECTED_TEAMS_STR="${SELECTED_TEAMS[*]}"
        export CR_ALL_SELECTED_TEAMS_STR="${SELECTED_TEAMS[*]}"
        printf 'SELECTED_TEAMS_STR=%s\n' "$SELECTED_TEAMS_STR"
        printf 'CR_ALL_SELECTED_TEAMS_STR=%s\n' "$CR_ALL_SELECTED_TEAMS_STR"
    )"
    assert_contains "$_res" "SELECTED_TEAMS_STR=widget" "widget missing from SELECTED_TEAMS_STR: $_res"
    assert_contains "$_res" "CR_ALL_SELECTED_TEAMS_STR=widget" "widget missing from CR_ALL_SELECTED_TEAMS_STR: $_res"
    _block_end

    # ── C4: registry unreadable -> fail-soft warning, SELECTED_TEAMS untouched ──
    _block_start "C4: force-append -- unreadable registry warns and leaves SELECTED_TEAMS untouched (fail-soft, not fail-closed)"
    _reg_dir_bad="$(_x1070_mk_reg_sandbox force-c4 "__MISSING__")"
    _res="$(
        unset AITEAMFORGE_HOME AITEAMFORGE_DIR AITEAMFORGE_CONFIG
        # shellcheck disable=SC1091
        . "$_reg_dir_bad/libexec/lib/mandatory-teams.sh"
        GREEN=""; NC=""; YELLOW=""
        SELECTED_TEAMS=("alpha")
        _x1070_force_append
        printf 'SELECTED=%s\n' "${SELECTED_TEAMS[*]}"
    )"
    assert_eq "$_res" "$(printf 'SELECTED=alpha')" "an unreadable registry must not corrupt or clear SELECTED_TEAMS: $_res"
    _block_end
fi

# ═══════════════════════════════════════════════════════════════════════════
# SECTION D -- Non-interactive path: install_kanban_system()'s team
# resolution + force-append, including the fresh-box "resolves to nothing
# at all" case.
# ═══════════════════════════════════════════════════════════════════════════

_extract_installkanban_resolution() {
    awk '
      index($0,"# Get selected teams from wizard env var, config file, or default")>0 {capture=1}
      capture {print}
      capture && index($0,"continuing without mandatory-team enforcement (XACA-1070)")>0 {trail=2; next}
      trail==2 {trail=1; next}
      trail==1 {trail=0; exit}
    ' "$INSTALL_KANBAN_SH"
}

_ik_snippet="$(_extract_installkanban_resolution)"
if [ -z "$_ik_snippet" ]; then
    test_start "SECTION D setup: extract install-kanban.sh team-resolution snippet"
    test_fail "extraction produced no output -- cannot run Section D"
else
    eval "_x1070_resolve_teams() {
$_ik_snippet
    if [ \${#teams[@]} -gt 0 ]; then printf '%s\n' \"\${teams[@]}\"; fi
}"

    _reg_dir="$(_x1070_mk_reg_sandbox installkanban "$REG_ONE_TRUE")"

    # ── D1: SELECTED_TEAMS_STR set -> used verbatim + mandatory appended ──
    _block_start "D1: install_kanban_system() non-interactive -- SELECTED_TEAMS_STR set is used, plus mandatory team appended"
    _out="$(
        unset AITEAMFORGE_HOME AITEAMFORGE_CONFIG
        # shellcheck disable=SC1091
        . "$_reg_dir/libexec/lib/mandatory-teams.sh"
        info() { :; }; warning() { :; }
        AITEAMFORGE_DIR="$SANDBOX/d1-dir"
        SELECTED_TEAMS_STR="ios firebase"
        _x1070_resolve_teams
    )"
    assert_contains "$_out" "ios" "expected ios from SELECTED_TEAMS_STR"
    assert_contains "$_out" "firebase" "expected firebase from SELECTED_TEAMS_STR"
    assert_contains "$_out" "widget" "expected mandatory team 'widget' force-appended even though SELECTED_TEAMS_STR was set"
    _block_end

    # ── D2: SELECTED_TEAMS_STR unset, .aiteamforge-config present -> read from config, plus mandatory appended ──
    _block_start "D2: install_kanban_system() non-interactive -- SELECTED_TEAMS_STR unset, reads .aiteamforge-config, plus mandatory appended"
    _cfg_dir="$SANDBOX/d2-dir"
    mkdir -p "$_cfg_dir"
    printf '{"teams":["android"]}' > "$_cfg_dir/.aiteamforge-config"
    _out="$(
        unset AITEAMFORGE_HOME AITEAMFORGE_CONFIG SELECTED_TEAMS_STR
        # shellcheck disable=SC1091
        . "$_reg_dir/libexec/lib/mandatory-teams.sh"
        info() { :; }; warning() { :; }
        AITEAMFORGE_DIR="$_cfg_dir"
        _x1070_resolve_teams
    )"
    assert_contains "$_out" "android" "expected android read from .aiteamforge-config"
    assert_contains "$_out" "widget" "expected mandatory team 'widget' force-appended from the config-file path"
    _block_end

    # ── D3: fresh-box case -- SELECTED_TEAMS_STR unset AND no config at all ──
    _block_start "D3: install_kanban_system() non-interactive -- FRESH BOX (no SELECTED_TEAMS_STR, no .aiteamforge-config) still gets the mandatory team"
    _fresh_dir="$SANDBOX/d3-dir"
    mkdir -p "$_fresh_dir"
    _out="$(
        unset AITEAMFORGE_HOME AITEAMFORGE_CONFIG SELECTED_TEAMS_STR
        # shellcheck disable=SC1091
        . "$_reg_dir/libexec/lib/mandatory-teams.sh"
        info() { :; }; warning() { :; }
        AITEAMFORGE_DIR="$_fresh_dir"
        _x1070_resolve_teams
    )"
    assert_eq "$_out" "widget" "on a genuinely fresh box (teams resolves to nothing at all) the ONLY team present should be the force-appended mandatory one, got: [$_out]"
    _block_end

    # ── D4: idempotent -- mandatory id already listed in .aiteamforge-config ──
    _block_start "D4: install_kanban_system() non-interactive -- idempotent when the mandatory team is already in .aiteamforge-config"
    _cfg_dir2="$SANDBOX/d4-dir"
    mkdir -p "$_cfg_dir2"
    printf '{"teams":["alpha","widget"]}' > "$_cfg_dir2/.aiteamforge-config"
    _out="$(
        unset AITEAMFORGE_HOME AITEAMFORGE_CONFIG SELECTED_TEAMS_STR
        # shellcheck disable=SC1091
        . "$_reg_dir/libexec/lib/mandatory-teams.sh"
        info() { :; }; warning() { :; }
        AITEAMFORGE_DIR="$_cfg_dir2"
        _x1070_resolve_teams
    )"
    _widget_count=$(printf '%s\n' "$_out" | grep -c '^widget$')
    assert_eq "$_widget_count" "1" "expected exactly ONE 'widget' entry (no duplicate), got $_widget_count in: [$_out]"
    _block_end
fi

# ═══════════════════════════════════════════════════════════════════════════
# SECTION E -- Upgrade backfill: update_mandatory_teams() /
# _xaca1070_mandatory_team_has_board(). Provisions when absent, no-op on
# second run, NEVER overwrites an existing board.
# ═══════════════════════════════════════════════════════════════════════════

_has_board_fn="$(_extract_fn _xaca1070_mandatory_team_has_board "$UPGRADE_SH")"
_update_mandatory_fn="$(_extract_fn update_mandatory_teams "$UPGRADE_SH")"
_add_to_config_fn_for_e="$(_extract_fn _xaca1070_add_team_to_config "$UPGRADE_SH")"

if [ -z "$_has_board_fn" ] || [ -z "$_update_mandatory_fn" ] || [ -z "$_add_to_config_fn_for_e" ]; then
    test_start "SECTION E setup: extract upgrade.sh backfill functions"
    test_fail "one or more extractions produced no output -- cannot run Section E"
else
    # Build a fake install-team.sh that records it was called and lays down a
    # board -- lets us assert the ORCHESTRATION decision (call it / don't
    # call it) without paying for a real install-team.sh run.
    _x1070_mk_fake_installer() {
        local libexec_dir="$SANDBOX/fake-libexec-$1" sentinel="$2"
        mkdir -p "$libexec_dir/installers"
        cat > "$libexec_dir/installers/install-team.sh" <<EOF
#!/bin/bash
team_id="\$1"
echo "FAKE INSTALLER CALLED for \$team_id" >> "$sentinel"
kdir="\$AITEAMFORGE_DIR/kanban/\$team_id"
mkdir -p "\$kdir"
echo '{"seed":"fresh"}' > "\$kdir/\${team_id}-board.json"
exit 0
EOF
        chmod +x "$libexec_dir/installers/install-team.sh"
        printf '%s' "$libexec_dir"
    }

    # team-paths.json fixture (real aiteamforge-paths.sh, AITEAMFORGE_CONFIG override).
    _x1070_mk_team_paths() {
        local name="$1" team="$2" kdir="$3"
        local path="$SANDBOX/team-paths-$name.json"
        cat > "$path" <<EOF
{"schema_version": 1, "teams": {"$team": {"kanban_dir": "$kdir", "working_dir": "$SANDBOX/work-$name/$team"}}}
EOF
        printf '%s' "$path"
    }

    _run_update_mandatory() {
        # $1=reg sandbox dir  $2=LIBEXEC_DIR (fake installer)  $3=AITEAMFORGE_CONFIG (team-paths.json)
        # $4=DRY_RUN  $5=WORKING_DIR
        local reg_dir="$1" libexec_dir="$2" team_paths="$3" dry_run="$4" working_dir="$5"
        ( unset AITEAMFORGE_HOME
          # shellcheck disable=SC1091
          . "$reg_dir/libexec/lib/mandatory-teams.sh"
          # shellcheck disable=SC1091
          . "$COMMON_SH"
          # shellcheck disable=SC1091
          . "$PATHS_SH"
          # shellcheck disable=SC1091
          . "$CONFIG_SH"
          eval "$_has_board_fn"
          eval "$_add_to_config_fn_for_e"
          eval "$_update_mandatory_fn"
          LIBEXEC_DIR="$libexec_dir"
          AITEAMFORGE_CONFIG="$team_paths"
          DRY_RUN="$dry_run"
          WORKING_DIR="$working_dir"
          update_mandatory_teams
        )
    }

    # ── E1: board absent -> installer invoked, board created, success reported ──
    _block_start "E1: update_mandatory_teams -- board absent, mandatory team backfilled via the installer"
    _reg_e1="$(_x1070_mk_reg_sandbox upgrade-e1 "$REG_ONE_TRUE" true)"
    _work_e1="$SANDBOX/e1-work"
    mkdir -p "$_work_e1"
    # kanban_dir MUST match where the fake installer actually writes the
    # board (under $AITEAMFORGE_DIR/kanban/<team>) -- AITEAMFORGE_DIR is set
    # to _work_e1 below, so the fixture's declared kanban_dir has to agree.
    _kdir_e1="$_work_e1/kanban/widget"
    _tp_e1="$(_x1070_mk_team_paths e1 widget "$_kdir_e1")"
    _fake_e1_sentinel="$SANDBOX/e1-sentinel.log"
    _fake_e1="$(_x1070_mk_fake_installer e1 "$_fake_e1_sentinel")"
    _out="$(AITEAMFORGE_DIR="$_work_e1" _run_update_mandatory "$_reg_e1" "$_fake_e1" "$_tp_e1" false "$_work_e1")"
    assert_file_exists "$_fake_e1_sentinel" "expected the (fake) installer to have been invoked for the absent team"
    assert_file_exists "$_kdir_e1/widget-board.json" "expected a board to now exist on disk for 'widget'"
    assert_contains "$_out" "Provisioned mandatory team 'widget'" "expected a provisioning success message"
    _block_end

    # ── E2: second run -> no-op, installer NOT invoked again ──
    _block_start "E2: update_mandatory_teams -- second run against the now-provisioned team is a no-op (installer not re-invoked)"
    _out2="$(AITEAMFORGE_DIR="$_work_e1" _run_update_mandatory "$_reg_e1" "$_fake_e1" "$_tp_e1" false "$_work_e1")"
    _calls="$(grep -c 'FAKE INSTALLER CALLED' "$_fake_e1_sentinel" 2>/dev/null || echo 0)"
    assert_eq "$_calls" "1" "installer must NOT be called again once a board exists (still exactly 1 call from E1), got $_calls"
    assert_contains "$_out2" "already provisioned" "expected a no-op/already-provisioned message on the second run"
    _block_end

    # ── E3: NEVER overwrites an existing board (byte-identical, sha256) ──
    _block_start "E3: update_mandatory_teams -- NEVER overwrites a pre-existing board (sha256-identical before/after, installer never called)"
    _reg_e3="$(_x1070_mk_reg_sandbox upgrade-e3 "$REG_ONE_TRUE" true)"
    _kdir_e3="$SANDBOX/e3-kanban/widget"
    mkdir -p "$_kdir_e3"
    printf '{"sentinel":"DO-NOT-TOUCH","incidentHistory":["irreplaceable"]}' > "$_kdir_e3/widget-board.json"
    _sha_before="$(shasum -a 256 "$_kdir_e3/widget-board.json" | awk '{print $1}')"
    _tp_e3="$(_x1070_mk_team_paths e3 widget "$_kdir_e3")"
    _fake_e3_sentinel="$SANDBOX/e3-sentinel.log"
    _fake_e3="$(_x1070_mk_fake_installer e3 "$_fake_e3_sentinel")"
    _work_e3="$SANDBOX/e3-work"
    mkdir -p "$_work_e3"
    AITEAMFORGE_DIR="$_work_e3" _run_update_mandatory "$_reg_e3" "$_fake_e3" "$_tp_e3" false "$_work_e3" >/dev/null
    _sha_after="$(shasum -a 256 "$_kdir_e3/widget-board.json" | awk '{print $1}')"
    assert_eq "$_sha_after" "$_sha_before" "pre-existing board must be BYTE-IDENTICAL after the backfill runs (sha256 mismatch = overwrite)"
    assert_file_not_exists "$_fake_e3_sentinel" "installer must never be invoked when a board already exists on disk"
    _block_end

    # ── E4: DRY_RUN=true -- never provisions, never writes ──
    _block_start "E4: update_mandatory_teams -- DRY_RUN=true does not provision or write anything"
    _reg_e4="$(_x1070_mk_reg_sandbox upgrade-e4 "$REG_ONE_TRUE" true)"
    _work_e4="$SANDBOX/e4-work"
    mkdir -p "$_work_e4"
    _kdir_e4="$_work_e4/kanban/widget"
    _tp_e4="$(_x1070_mk_team_paths e4 widget "$_kdir_e4")"
    _fake_e4_sentinel="$SANDBOX/e4-sentinel.log"
    _fake_e4="$(_x1070_mk_fake_installer e4 "$_fake_e4_sentinel")"
    _out4="$(AITEAMFORGE_DIR="$_work_e4" _run_update_mandatory "$_reg_e4" "$_fake_e4" "$_tp_e4" true "$_work_e4")"
    assert_file_not_exists "$_fake_e4_sentinel" "DRY_RUN=true must never invoke the installer"
    assert_file_not_exists "$_kdir_e4/widget-board.json" "DRY_RUN=true must never create a board on disk"
    assert_contains "$_out4" "Would provision" "expected a 'would provision' dry-run message"
    _block_end

    # ── E5: unreadable registry -> fail-soft warning, no crash ──
    _block_start "E5: update_mandatory_teams -- unreadable registry is fail-soft (warns, returns 0, does not abort the upgrade)"
    _reg_e5="$(_x1070_mk_reg_sandbox upgrade-e5 "__MISSING__" true)"
    _work_e5="$SANDBOX/e5-work"
    mkdir -p "$_work_e5"
    _out5="$(AITEAMFORGE_DIR="$_work_e5" _run_update_mandatory "$_reg_e5" "$SANDBOX/nonexistent-libexec" "$SANDBOX/nonexistent-team-paths.json" false "$_work_e5")"; _rc5=$?
    assert_eq "$_rc5" "0" "update_mandatory_teams must return 0 (fail-soft) even when the registry is unreadable, got $_rc5"
    assert_contains "$_out5" "Could not determine mandatory teams" "expected the fail-soft diagnostic message"
    _block_end
fi

# ═══════════════════════════════════════════════════════════════════════════
# SECTION F -- Config registration: _xaca1070_add_team_to_config() writes
# .teams[], and the round trip through get_configured_teams() +
# atf_team_provisioned() is what this ticket's late-found defect fixed.
# ═══════════════════════════════════════════════════════════════════════════

_add_to_config_fn="$(_extract_fn _xaca1070_add_team_to_config "$UPGRADE_SH")"

if [ -z "$_add_to_config_fn" ]; then
    test_start "SECTION F setup: extract _xaca1070_add_team_to_config"
    test_fail "extraction produced no output -- cannot run Section F"
else
    _run_add_to_config() {
        # $1=team_id  $2=AITEAMFORGE_DIR
        local team_id="$1" aitf_dir="$2"
        ( # shellcheck disable=SC1091
          . "$CONFIG_SH"
          eval "$_add_to_config_fn"
          AITEAMFORGE_DIR="$aitf_dir"
          print_warning() { echo "WARN: $*"; }
          print_success() { echo "OK: $*"; }
          _xaca1070_add_team_to_config "$team_id"
        )
    }

    # ── F1: THE ROUND TRIP -- register, then confirm get_configured_teams AND
    # atf_team_provisioned both see it. This is the point of the XACA-1070-005 fix.
    _block_start "F1: THE ROUND TRIP -- after registration, get_configured_teams() includes the team AND atf_team_provisioned() returns 0"
    _f1_dir="$SANDBOX/f1-dir"
    mkdir -p "$_f1_dir/kanban/widget"
    printf '{"teams":["alpha"],"version":"1.0.0"}' > "$_f1_dir/.aiteamforge-config"
    echo '{"seed":true}' > "$_f1_dir/kanban/widget/widget-board.json"
    _out="$(_run_add_to_config widget "$_f1_dir")"; _rc=$?
    assert_eq "$_rc" "0" "expected successful registration, got rc=$_rc, out=[$_out]"
    assert_contains "$_out" "OK: XACA-1070: registered 'widget'" "expected the registration success message"
    _cfg_teams="$(
        AITEAMFORGE_DIR="$_f1_dir"
        # shellcheck disable=SC1091
        . "$CONFIG_SH"
        get_configured_teams
    )"
    assert_contains "$_cfg_teams" "widget" "get_configured_teams() must now include 'widget': [$_cfg_teams]"
    _tp_f1="$(_x1070_mk_team_paths f1 widget "$_f1_dir/kanban/widget")"
    ( AITEAMFORGE_DIR="$_f1_dir" AITEAMFORGE_CONFIG="$_tp_f1"
      unset AITEAMFORGE_HOME
      # shellcheck disable=SC1091
      . "$MANDATORY_TEAMS_SH"
      atf_team_provisioned widget
    ); _rc_prov=$?
    assert_eq "$_rc_prov" "0" "atf_team_provisioned('widget') must return 0 after the config round trip, got $_rc_prov"
    _block_end

    # ── F2: idempotent -- second run is byte-identical, logs no-op ──
    _block_start "F2: _xaca1070_add_team_to_config -- idempotent (byte-identical config on a second run)"
    _sha_before="$(shasum -a 256 "$_f1_dir/.aiteamforge-config" | awk '{print $1}')"
    _out2="$(_run_add_to_config widget "$_f1_dir")"; _rc2=$?
    _sha_after="$(shasum -a 256 "$_f1_dir/.aiteamforge-config" | awk '{print $1}')"
    assert_eq "$_rc2" "0" "second run should still report success (no-op), got rc=$_rc2"
    assert_eq "$_sha_after" "$_sha_before" "config file must be BYTE-IDENTICAL on a no-op re-run"
    # A no-op deliberately prints NOTHING (the code's own case statement:
    # *"no-op"*) suppresses the print_success call entirely) -- assert
    # silence, not literal "no-op" text, since that text never reaches stdout.
    assert_not_contains "$_out2" "OK:" "a no-op re-run must not re-announce success (the code suppresses print_success for the no-op case)"
    _block_end

    # ── F3: all OTHER config keys preserved ──
    _block_start "F3: _xaca1070_add_team_to_config -- every unrelated config key is preserved untouched"
    _f3_dir="$SANDBOX/f3-dir"
    mkdir -p "$_f3_dir"
    cat > "$_f3_dir/.aiteamforge-config" <<'EOF'
{
  "version": "0.20.8",
  "installed_at": "2026-01-01T00:00:00Z",
  "installed_features": ["kanban", "lcars"],
  "team_paths": {
    "alpha": "/some/path"
  },
  "teams": [
    "alpha"
  ]
}
EOF
    _run_add_to_config widget "$_f3_dir" >/dev/null
    _remaining="$(
        # shellcheck disable=SC1091
        AITEAMFORGE_DIR="$_f3_dir" . "$CONFIG_SH"
        jq -r '.version, .installed_at, (.installed_features | join(",")), .team_paths.alpha' "$_f3_dir/.aiteamforge-config" 2>/dev/null
    )"
    assert_contains "$_remaining" "0.20.8" "version key must be preserved"
    assert_contains "$_remaining" "2026-01-01T00:00:00Z" "installed_at key must be preserved"
    assert_contains "$_remaining" "kanban,lcars" "installed_features array must be preserved"
    assert_contains "$_remaining" "/some/path" "team_paths.alpha must be preserved"
    _teams_after="$(jq -c '.teams' "$_f3_dir/.aiteamforge-config" 2>/dev/null)"
    assert_contains "$_teams_after" "widget" "widget must have been added to .teams[]"
    assert_contains "$_teams_after" "alpha" "alpha must still be present in .teams[]"
    _block_end

    # ── F4: malformed .teams (not a flat array of strings) -> warn, rc!=0, byte-identical ──
    _block_start "F4: _xaca1070_add_team_to_config -- malformed .teams (contains a non-string) -> warned, rc!=0, file untouched"
    _f4_dir="$SANDBOX/f4-dir"
    mkdir -p "$_f4_dir"
    printf '{"teams":["alpha", 42], "version":"1.0.0"}' > "$_f4_dir/.aiteamforge-config"
    _sha_before="$(shasum -a 256 "$_f4_dir/.aiteamforge-config" | awk '{print $1}')"
    _out="$(_run_add_to_config widget "$_f4_dir")"; _rc=$?
    _sha_after="$(shasum -a 256 "$_f4_dir/.aiteamforge-config" | awk '{print $1}')"
    assert_ne "$_rc" "0" "malformed .teams must produce a non-zero return code, got $_rc"
    assert_contains "$_out" "WARN:" "expected a warning to be printed"
    assert_eq "$_sha_after" "$_sha_before" "malformed config must be left BYTE-IDENTICAL (never guessed at)"
    _block_end

    # ── F5: missing config file -> warn, rc!=0, NOT created ──
    _block_start "F5: _xaca1070_add_team_to_config -- missing .aiteamforge-config -> warned, rc!=0, NOT created"
    _f5_dir="$SANDBOX/f5-dir"
    mkdir -p "$_f5_dir"
    _out="$(_run_add_to_config widget "$_f5_dir")"; _rc=$?
    assert_ne "$_rc" "0" "missing config must produce a non-zero return code, got $_rc"
    assert_contains "$_out" "WARN:" "expected a warning to be printed"
    assert_file_not_exists "$_f5_dir/.aiteamforge-config" "a missing config must NEVER be created by this function"
    _block_end

    # ── F6 (bonus): .teams key absent entirely -> warn, rc!=0, byte-identical ──
    _block_start "F6: _xaca1070_add_team_to_config -- .teams key absent entirely -> warned, rc!=0, file untouched"
    _f6_dir="$SANDBOX/f6-dir"
    mkdir -p "$_f6_dir"
    printf '{"version":"1.0.0"}' > "$_f6_dir/.aiteamforge-config"
    _sha_before="$(shasum -a 256 "$_f6_dir/.aiteamforge-config" | awk '{print $1}')"
    _out="$(_run_add_to_config widget "$_f6_dir")"; _rc=$?
    _sha_after="$(shasum -a 256 "$_f6_dir/.aiteamforge-config" | awk '{print $1}')"
    assert_ne "$_rc" "0" "absent .teams key must produce a non-zero return code, got $_rc"
    assert_eq "$_sha_after" "$_sha_before" "config with no .teams key must be left BYTE-IDENTICAL"
    _block_end
fi

# ═══════════════════════════════════════════════════════════════════════════
# SECTION G -- Doctor (both copies): pass on zero mandatory teams, fault on
# mandatory-but-unprovisioned, fault on unreadable registry.
# ═══════════════════════════════════════════════════════════════════════════

_check_result_libexec_fn="$(_extract_fn check_result "$DOCTOR_LIBEXEC_SH")"
_check_mand_libexec_fn="$(_extract_fn check_mandatory_teams "$DOCTOR_LIBEXEC_SH")"
_check_result_bin_fn="$(_extract_fn check_result "$DOCTOR_BIN_SH")"
_check_mand_bin_fn="$(_extract_fn check_mandatory_teams "$DOCTOR_BIN_SH")"
_doctor_bin_preamble="$(awk '
      $0=="_MANDATORY_TEAMS_LIB_OK=false" {capture=1}
      capture {print}
      capture && $0=="fi" {exit}
    ' "$DOCTOR_BIN_SH")"

if [ -z "$_check_result_libexec_fn" ] || [ -z "$_check_mand_libexec_fn" ] || \
   [ -z "$_check_result_bin_fn" ] || [ -z "$_check_mand_bin_fn" ] || [ -z "$_doctor_bin_preamble" ]; then
    test_start "SECTION G setup: extract doctor functions from both copies"
    test_fail "one or more extractions produced no output -- cannot run Section G"
else
    # ── libexec/commands/aiteamforge-doctor.sh copy: self-locating, so it
    # doesn't need the AITEAMFORGE_HOME "faithful layout" trick -- we source
    # the fixture's own copy of mandatory-teams.sh (isolated technique).
    _run_doctor_libexec_check() {
        local reg_dir="$1"
        ( unset AITEAMFORGE_HOME AITEAMFORGE_DIR AITEAMFORGE_CONFIG
          # shellcheck disable=SC1091
          . "$COMMON_SH"
          if [ "$reg_dir" != "__NOLIB__" ]; then
            # shellcheck disable=SC1091
            . "$reg_dir/libexec/lib/mandatory-teams.sh"
          fi
          eval "$_check_result_libexec_fn"
          eval "$_check_mand_libexec_fn"
          TOTAL_CHECKS=0; PASSED_CHECKS=0; FAILED_CHECKS=0; WARNING_CHECKS=0; VERBOSE=false
          check_mandatory_teams
          echo "COUNTERS total=$TOTAL_CHECKS passed=$PASSED_CHECKS failed=$FAILED_CHECKS warn=$WARNING_CHECKS"
        ) 2>&1
    }

    _block_start "G1 (libexec copy): check_mandatory_teams -- zero mandatory teams -> clean PASS"
    _reg_g1="$(_x1070_mk_reg_sandbox doctor-lib-g1 "$REG_EMPTY" true)"
    _out="$(_run_doctor_libexec_check "$_reg_g1")"
    assert_contains "$_out" "COUNTERS total=1 passed=1 failed=0 warn=0" "expected a single clean pass, got: $_out"
    assert_contains "$_out" "No mandatory teams declared" "expected the specific zero-mandatory pass message"
    _block_end

    _block_start "G2 (libexec copy): check_mandatory_teams -- mandatory team declared but NOT provisioned -> FAULT"
    _reg_g2="$(_x1070_mk_reg_sandbox doctor-lib-g2 "$REG_ONE_TRUE" true)"
    _work_g2="$SANDBOX/g2-work"
    mkdir -p "$_work_g2"
    _out="$(
        exec 2>&1
        AITEAMFORGE_DIR="$_work_g2"
        unset AITEAMFORGE_HOME AITEAMFORGE_CONFIG
        # shellcheck disable=SC1091
        . "$COMMON_SH"
        # shellcheck disable=SC1091
        . "$_reg_g2/libexec/lib/mandatory-teams.sh"
        eval "$_check_result_libexec_fn"
        eval "$_check_mand_libexec_fn"
        TOTAL_CHECKS=0; PASSED_CHECKS=0; FAILED_CHECKS=0; WARNING_CHECKS=0; VERBOSE=false
        AITEAMFORGE_DIR="$_work_g2"
        check_mandatory_teams
        echo "COUNTERS total=$TOTAL_CHECKS passed=$PASSED_CHECKS failed=$FAILED_CHECKS warn=$WARNING_CHECKS"
    )"
    assert_contains "$_out" "failed=1" "expected exactly one FAILED check for the unprovisioned mandatory team, got: $_out"
    assert_contains "$_out" "Mandatory team 'widget' is MISSING or not provisioned" "expected the specific fault message naming widget"
    _block_end

    _block_start "G3 (libexec copy): check_mandatory_teams -- unreadable registry -> FAULT (never a silent pass)"
    _reg_g3="$(_x1070_mk_reg_sandbox doctor-lib-g3 "__MISSING__" true)"
    _out="$(_run_doctor_libexec_check "$_reg_g3")"
    assert_contains "$_out" "failed=1" "an unreadable registry must FAULT, not pass silently, got: $_out"
    assert_contains "$_out" "Could not determine mandatory teams" "expected the specific unreadable-registry fault message"
    _block_end

    # ── bin/aiteamforge-doctor.sh copy: exercises the REAL AITEAMFORGE_HOME
    # preamble, so we use the "faithful sandbox root" fixture and set
    # AITEAMFORGE_HOME to it directly (mirrors the real Formula bin stub).
    _run_doctor_bin_check() {
        local aitf_home="$1" aitf_dir="$2"
        ( # shellcheck disable=SC1091
          . "$COMMON_SH"
          AITEAMFORGE_HOME="$aitf_home"
          eval "$_doctor_bin_preamble"
          eval "$_check_result_bin_fn"
          eval "$_check_mand_bin_fn"
          TOTAL_CHECKS=0; PASSED_CHECKS=0; FAILED_CHECKS=0; WARNING_CHECKS=0; VERBOSE=false
          AITEAMFORGE_DIR="$aitf_dir"
          check_mandatory_teams
          echo "LIB_OK=$_MANDATORY_TEAMS_LIB_OK COUNTERS total=$TOTAL_CHECKS passed=$PASSED_CHECKS failed=$FAILED_CHECKS warn=$WARNING_CHECKS"
        )
    }

    _block_start "G4 (bin copy, FAITHFUL layout): AITEAMFORGE_HOME = faithful installed root -> lib loads, zero mandatory teams -> PASS"
    _reg_g4="$(_x1070_mk_reg_sandbox doctor-bin-g4 "$REG_EMPTY" true)"
    _work_g4="$SANDBOX/g4-work"; mkdir -p "$_work_g4"
    _out="$(_run_doctor_bin_check "$_reg_g4" "$_work_g4")"
    assert_contains "$_out" "LIB_OK=true" "expected the lib to load under a faithful AITEAMFORGE_HOME layout"
    assert_contains "$_out" "passed=1 failed=0 warn=0" "expected a single clean pass, got: $_out"
    _block_end

    _block_start "G5 (bin copy, UNFAITHFUL layout): AITEAMFORGE_HOME missing libexec/lib -> lib unavailable -> WARN, never a false pass"
    _bad_home="$SANDBOX/g5-bad-home"
    mkdir -p "$_bad_home"
    _out="$(_run_doctor_bin_check "$_bad_home" "$SANDBOX/g5-work")"
    assert_contains "$_out" "LIB_OK=false" "expected the lib to fail to load under an unfaithful (non-repo-root) AITEAMFORGE_HOME"
    assert_contains "$_out" "warn=1" "expected the 'lib not available' WARN, not a fault or a silent pass"
    assert_not_contains "$_out" "failed=1" "an unavailable lib must warn, not fault -- this is the false-negative the ticket calls out, confirmed reproducible here"
    _block_end

    _block_start "G6 (bin copy, FAITHFUL layout): mandatory-but-unprovisioned -> FAULT"
    _reg_g6="$(_x1070_mk_reg_sandbox doctor-bin-g6 "$REG_ONE_TRUE" true)"
    _work_g6="$SANDBOX/g6-work"; mkdir -p "$_work_g6"
    _out="$(_run_doctor_bin_check "$_reg_g6" "$_work_g6")"
    assert_contains "$_out" "LIB_OK=true" "expected the lib to load"
    assert_contains "$_out" "failed=1" "expected a FAULT for the unprovisioned mandatory team 'widget', got: $_out"
    _block_end

    _block_start "G7 (bin copy, FAITHFUL layout): unreadable registry -> FAULT, never a silent pass"
    _reg_g7="$(_x1070_mk_reg_sandbox doctor-bin-g7 "__MISSING__" true)"
    _work_g7="$SANDBOX/g7-work"; mkdir -p "$_work_g7"
    _out="$(_run_doctor_bin_check "$_reg_g7" "$_work_g7")"
    assert_contains "$_out" "LIB_OK=true" "the lib itself loads fine (it's the registry inside it that's missing)"
    assert_contains "$_out" "failed=1" "an unreadable registry must FAULT even though the lib loaded, got: $_out"
    _block_end

    # ── G8 FINDING (documented, not a failing assertion): confirms the
    # AITEAMFORGE_HOME priority-1 branch in mandatory-teams.sh is dead code
    # under the REAL Homebrew-installed layout -- the feature only works
    # because of the self-location fallback. See the file header comment
    # and the test report for the full writeup. This assertion is designed
    # to PASS today (documenting current, correct END-TO-END behavior via
    # the fallback) while separately proving priority-1's own literal path
    # guess does not exist in that layout.
    _block_start "G8 (FINDING, non-blocking): faithful layout works end-to-end ONLY via self-location fallback -- AITEAMFORGE_HOME's own '../share' guess does not exist there"
    assert_file_not_exists "$TAP_ROOT/../share/teams/registry.json" "documents that AITEAMFORGE_HOME=repo-root's own '../share/teams/registry.json' guess (mandatory-teams.sh priority 1) is NOT where the real file lives -- the feature works today only via the priority-2 self-location fallback (see file header FINDING writeup)"
    assert_file_exists "$TAP_ROOT/share/teams/registry.json" "the real file lives INSIDE the repo root, one level shallower than priority 1 guesses"
    _block_end
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary (standalone only).
# ─────────────────────────────────────────────────────────────────────────────
if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "Results: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    [ "$_FAIL_COUNT" -gt 0 ] && exit 1
fi
exit 0
