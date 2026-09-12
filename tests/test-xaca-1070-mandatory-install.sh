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
# registry.json two ways: (1) ${AITEAMFORGE_HOME}/share/teams/registry.json
# when AITEAMFORGE_HOME is set and that file exists, else (2) self-location
# from mandatory-teams.sh's OWN on-disk path (two directories up from
# wherever the sourced copy actually lives).
#
# XACA-1070-023 (doc drift, PR #865 round 3): this comment block used to
# document branch (1) as "${AITEAMFORGE_HOME}/../share/teams/registry.json"
# — one directory too high — and flagged that as an open, unfixed FINDING,
# explicitly out of scope for this test file ("do NOT modify the
# implementation"). That was an accurate description of the code WHEN
# WRITTEN, but PR #865 review, item 3 subsequently fixed branch (1) in
# libexec/lib/mandatory-teams.sh itself to
# "${AITEAMFORGE_HOME}/share/teams/registry.json" (no ".."), matching how
# AITEAMFORGE_HOME is used as the tap root everywhere else in this codebase
# (see that file's own header comment, above _atf_mandatory_teams_registry_path,
# for the full before/after rationale). Leaving the OLD wording here after
# the fix landed left this comment block flatly contradicting G8/G9 a few
# hundred lines below, which exist specifically to PROVE the fix: G8 shows
# branch (1) now resolves the registry DIRECTLY, with no self-location
# fallback needed, and G9 is a sanity check that the OLD "one level up"
# guess is NOT also incidentally reachable (which would let G8 pass for the
# wrong reason). Corrected here in the comment only — no test behavior or
# assertion changes; G8/G9 themselves were already correct.
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
grep -qF 'if command -v atf_mandatory_teams >/dev/null 2>&1; then' "$SETUP_SH" || _block_note_fail "setup.sh no longer contains the force-append if-anchor"
grep -q '^_atf_apply_mandatory_teams() {' "$SETUP_SH" || _block_note_fail "setup.sh no longer defines _atf_apply_mandatory_teams() at column 0 (PR #865 BLOCKING 1 fix)"
[ "$(grep -c '^_atf_apply_mandatory_teams$' "$SETUP_SH")" -ge 2 ] || _block_note_fail "setup.sh no longer calls _atf_apply_mandatory_teams from (at least) two call sites -- PR #865 BLOCKING 1 fix regressed"
grep -qF '# Get selected teams from wizard env var, config file, or default' "$INSTALL_KANBAN_SH" || _block_note_fail "install-kanban.sh no longer contains the team-resolution anchor comment"
grep -qF 'continuing without mandatory-team enforcement (XACA-1070)' "$INSTALL_KANBAN_SH" || _block_note_fail "install-kanban.sh no longer contains the fail-soft warning anchor"
grep -qF 'skipping mandatory-team enforcement (XACA-1070)' "$INSTALL_KANBAN_SH" || _block_note_fail "install-kanban.sh no longer contains the XACA-1070-020 silent-when-absent warning anchor (Section D extraction end-of-block depends on this being unique)"
grep -qF 'skipping mandatory-team enforcement (XACA-1070)' "$SETUP_SH" || _block_note_fail "setup.sh no longer contains the XACA-1070-020 silent-when-absent warning anchor"
grep -q '^_xaca1070_mandatory_team_has_board() {' "$UPGRADE_SH" || _block_note_fail "upgrade.sh no longer defines _xaca1070_mandatory_team_has_board() at column 0"
grep -q '^_xaca1070_add_team_to_config() {' "$UPGRADE_SH" || _block_note_fail "upgrade.sh no longer defines _xaca1070_add_team_to_config() at column 0"
grep -q '^update_mandatory_teams() {' "$UPGRADE_SH" || _block_note_fail "upgrade.sh no longer defines update_mandatory_teams() at column 0"
grep -q '^atf_team_has_board() {' "$MANDATORY_TEAMS_SH" || _block_note_fail "mandatory-teams.sh no longer defines atf_team_has_board() at column 0 (XACA-1070-017 factor-out)"
grep -q '^check_mandatory_teams() {' "$DOCTOR_LIBEXEC_SH" || _block_note_fail "libexec/commands/aiteamforge-doctor.sh no longer defines check_mandatory_teams() at column 0"
grep -q '^check_mandatory_teams() {' "$DOCTOR_BIN_SH" || _block_note_fail "bin/aiteamforge-doctor.sh no longer defines check_mandatory_teams() at column 0"
grep -qF '_MANDATORY_TEAMS_LIB_OK=false' "$DOCTOR_BIN_SH" || _block_note_fail "bin/aiteamforge-doctor.sh no longer contains the _MANDATORY_TEAMS_LIB_OK preamble anchor"
# XACA-1070 / PR #865 round 2 (Sections I-N) extraction anchors:
grep -qF 'echo -e "${BOLD}Installing teams...${NC}"' "$SETUP_SH" || _block_note_fail "setup.sh no longer contains the 'Installing teams...' anchor Section I's team-install-loop extraction depends on"
grep -qF 'if [ "$INSTALL_PROFILE" = "cockpit" ] && ! { command -v atf_is_mandatory_team >/dev/null 2>&1 && atf_is_mandatory_team "$team_id"; }; then' "$SETUP_SH" || _block_note_fail "setup.sh no longer contains the per-iteration cockpit-mandatory guard Section I/J assert on"
grep -qF 'mkdir -p "${INSTALL_DIR}/avatars"' "$SETUP_SH" || _block_note_fail "setup.sh no longer contains the persona-loop anchor Section J's extraction depends on"
grep -qF '_cockpit_has_mandatory_team="false"' "$SETUP_SH" || _block_note_fail "setup.sh no longer contains the LCARS carve-out start anchor Section K's extraction depends on"
grep -qF 'fi  # end: cockpit mandatory-team LCARS instance (XACA-1070, PR #865 round 2)' "$SETUP_SH" || _block_note_fail "setup.sh no longer contains the LCARS carve-out end sentinel Section K's extraction depends on"
grep -q '^_cockpit_mandatory_teams_str() {' "$SETUP_SH" || _block_note_fail "setup.sh no longer defines _cockpit_mandatory_teams_str() at column 0 (Section L)"
# XACA-1070-021/022/023 (PR #865 round 3) extraction anchors:
grep -qF '# For project-based teams, ask for ClientID and/or ProjectID' "$SETUP_SH" || _block_note_fail "setup.sh no longer contains the Client-ID-prompt loop anchor comment Section O's extraction depends on"
grep -qF 'is a mandatory team and cannot be skipped by leaving Client ID blank' "$SETUP_SH" || _block_note_fail "setup.sh no longer contains the XACA-1070-021 mandatory-team-refuses-drop message Section O asserts on"
# XACA-1070-025 (PR #865 round 3): the null-safe lambda sort key was
# replaced by a named _order_sort_key() helper that additionally ranks by
# JSON type (see that subitem's fix) -- update this anchor to match rather
# than pin the superseded one-liner, which no longer exists verbatim.
grep -qF "def _order_sort_key(t):" "$MANDATORY_TEAMS_SH" || _block_note_fail "mandatory-teams.sh's python3 fallback no longer defines the XACA-1070-025 type-ranked sort key helper"
grep -qF "mandatory.sort(key=_order_sort_key)" "$MANDATORY_TEAMS_SH" || _block_note_fail "mandatory-teams.sh's python3 fallback no longer calls the XACA-1070-025 sort key helper"
grep -qF 'XACA1070_BAD_COUNT' "$MANDATORY_TEAMS_SH" || _block_note_fail "mandatory-teams.sh's python3 fallback no longer emits the XACA-1070-022 malformed-entry sentinel Section P asserts on"
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
#
# PR #865 review, BLOCKING 1 (post-fix): the force-append logic that used to
# be a raw inline block at a single (too-late) location is now the function
# _atf_apply_mandatory_teams(), called from TWO sites in setup.sh -- see that
# function's own header comment. Extraction below now pulls the FUNCTION
# itself (via the generic _extract_fn helper already used elsewhere in this
# suite), not an ad hoc anchor-to-"fi" block -- a extraction technique that
# is blind to WHERE the function is called from, which is exactly why the
# original C1-C4 below caught the EFFECT (an isolated call appends the
# team) but never the ordering defect (the call happened after every real
# consumer had already iterated SELECTED_TEAMS). C5/C6 below close that gap
# with assertions keyed to the actual call-site line numbers and to the
# real Step-2-selection-plus-working-dir-loop source span, respectively --
# both would fail if the call site regressed back to after line 970's
# working-dir loop (i.e. reverted to the pre-PR-865 shape).
# ═══════════════════════════════════════════════════════════════════════════

_force_append_snippet="$(_extract_fn "_atf_apply_mandatory_teams" "$SETUP_SH")"
if [ -z "$_force_append_snippet" ]; then
    test_start "SECTION C setup: extract setup.sh _atf_apply_mandatory_teams()"
    test_fail "extraction produced no output -- cannot run Section C"
else
    eval "$_force_append_snippet"
    _x1070_force_append() { _atf_apply_mandatory_teams; }

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

    # ── C5: STRUCTURAL -- the call site precedes the first SELECTED_TEAMS
    # consumer (PR #865 review, BLOCKING 1). This is the assertion the
    # original C1-C4 above did NOT have: they proved the function appends
    # correctly in ISOLATION, never where it is called from. The pre-fix
    # bug was exactly this -- a single call site placed AFTER the per-team
    # working-dir loop, the persona/avatar copy, and the install-team.sh
    # loop had already iterated SELECTED_TEAMS without the mandatory team
    # present. This grep-based check would fail immediately if a future
    # edit moved (or removed) the early call site.
    _block_start "C5: force-append -- call site precedes the first SELECTED_TEAMS-consuming loop (ordering, not just effect)"
    _first_call_line="$(grep -n '^_atf_apply_mandatory_teams$' "$SETUP_SH" | head -1 | cut -d: -f1)"
    _first_loop_line="$(grep -n '^for team_id in "\${SELECTED_TEAMS\[@\]}"; do' "$SETUP_SH" | head -1 | cut -d: -f1)"
    assert_not_empty "$_first_call_line" "expected at least one bare call to _atf_apply_mandatory_teams in $SETUP_SH"
    assert_not_empty "$_first_loop_line" "expected the per-team working-dir loop ('for team_id in \"\${SELECTED_TEAMS[@]}\"; do') in $SETUP_SH"
    if [ -n "$_first_call_line" ] && [ -n "$_first_loop_line" ]; then
        [ "$_first_call_line" -lt "$_first_loop_line" ] || _block_note_fail "force-append call site (line $_first_call_line) does not precede the first SELECTED_TEAMS-consuming loop (line $_first_loop_line) -- this is BLOCKING 1 regressing"
    fi
    _block_end

    # ── C6: FUNCTIONAL / ordering-sensitive regression -- extract the REAL
    # source span that runs "team_choices resolution -> empty check ->
    # _atf_apply_mandatory_teams call site 1 -> per-team working-dir loop"
    # verbatim from setup.sh (anchored on the unique `if [ "$team_choices" =
    # "all" ]; then` line through the matching "fi  # end: if INSTALL_PROFILE
    # != cockpit (team selection block)" sentinel) and actually RUN it with
    # a mandatory team that the (fake) user never selected. Unlike C1-C4,
    # which call _atf_apply_mandatory_teams directly, this drives it only
    # through its real call site inside the real surrounding control flow --
    # so if the call site were ever moved back to AFTER this span (the
    # pre-PR-865 shape), 'widget' would be absent from SELECTED_TEAMS and
    # _WORKDIR_widget would never be set, and this test would fail.
    _extract_selection_and_workdir_span() {
        awk '
          $0=="if [ \"$team_choices\" = \"all\" ]; then" {capture=1}
          capture && $0=="fi  # end: if INSTALL_PROFILE != cockpit (team selection block)" {exit}
          capture {print}
        ' "$SETUP_SH"
    }
    _selection_snippet="$(_extract_selection_and_workdir_span)"
    _block_start "C6 setup: extract setup.sh team_choices-resolution-through-working-dir-loop span"
    if [ -z "$_selection_snippet" ]; then
        _block_note_fail "extraction produced no output -- cannot run C6"
    else
        test_pass
    fi
    if [ -n "$_selection_snippet" ]; then
        eval "_x1070_selection_and_workdir() {
$_selection_snippet
}"
        _c6_teams_dir="$SANDBOX/teamsdir-c6"
        mkdir -p "$_c6_teams_dir"
        # widget deliberately carries no TEAM_HAS_PROJECTS/TEAM_REQUIRES_CLIENT_ID
        # (falls into the plain "else: eval _WORKDIR_<team>=working_dir" branch)
        # so a MODE=non-interactive run never hits an interactive `read -rp`.
        printf 'TEAM_NAME="Widget"\nTEAM_DESCRIPTION="Widget fleet team"\nTEAM_WORKING_DIR="$HOME/aiteamforge"\n' > "$_c6_teams_dir/widget.conf"
        _c6_reg_dir="$(_x1070_mk_reg_sandbox c6-selection "$REG_ONE_TRUE")"
        _c6_install_dir="$SANDBOX/c6-install-dir"
        _res="$(
            unset AITEAMFORGE_HOME AITEAMFORGE_DIR AITEAMFORGE_CONFIG
            # shellcheck disable=SC1091
            . "$_c6_reg_dir/libexec/lib/mandatory-teams.sh"
            GREEN=""; NC=""; YELLOW=""; RED=""; CYAN=""
            TEAMS_DIR="$_c6_teams_dir"
            INSTALL_DIR="$_c6_install_dir"
            MODE="non-interactive"
            # The fake user picks NOTHING that resolves to widget -- only
            # AVAILABLE_TEAMS[0] (alpha, a placeholder team_choices never
            # references widget by name or number).
            AVAILABLE_TEAMS=(alpha)
            SELECTED_TEAMS=()
            team_choices="1"
            _x1070_selection_and_workdir
            printf 'SELECTED=%s\n' "${SELECTED_TEAMS[*]}"
            printf 'WORKDIR_WIDGET=%s\n' "${_WORKDIR_widget:-<UNSET>}"
        )"
        _block_start "C6: force-append call site 1 -- a mandatory team the (fake) user never picked still reaches the working-dir loop"
        assert_contains "$_res" "SELECTED=alpha widget" "expected SELECTED_TEAMS to contain both the user's pick (alpha) and the force-appended mandatory team (widget), got: $_res"
        assert_not_contains "$_res" "WORKDIR_WIDGET=<UNSET>" "expected _WORKDIR_widget to be set by the working-dir loop reached via call site 1 -- if this is UNSET, the force-append ran too late (or not at all) relative to that loop: $_res"
        _block_end
    fi

    # ── C7 (XACA-1070-020): mandatory-teams.sh itself entirely ABSENT (never
    # sourced at all -- distinct from C4, which covers "sourced fine but the
    # registry it reads is unreadable"). Before this fix, the outer
    # `command -v atf_mandatory_teams` guard skipped the whole function with
    # ZERO console output; aiteamforge-upgrade.sh's update_mandatory_teams()
    # has always warned in the same situation. Assert the wizard now does too.
    _block_start "C7 (XACA-1070-020): _atf_apply_mandatory_teams warns when mandatory-teams.sh itself was never sourced (previously silent)"
    _c7_err="$SANDBOX/c7-stderr.log"
    _res="$(
        exec 2>"$_c7_err"
        unset AITEAMFORGE_HOME AITEAMFORGE_DIR AITEAMFORGE_CONFIG
        # Deliberately do NOT source mandatory-teams.sh -- atf_mandatory_teams
        # stays undefined, matching a real box with the lib missing entirely.
        GREEN=""; NC=""; YELLOW=""
        SELECTED_TEAMS=("alpha")
        _x1070_force_append
        printf 'SELECTED=%s\n' "${SELECTED_TEAMS[*]}"
    )"
    assert_eq "$_res" "$(printf 'SELECTED=alpha')" "SELECTED_TEAMS must be left untouched when the lib is absent (fail-soft, not fail-closed)"
    assert_contains "$(cat "$_c7_err")" "mandatory-teams.sh not available" "expected an explicit warning on stderr when mandatory-teams.sh itself is missing entirely (XACA-1070-020) -- this used to be completely silent"
    assert_contains "$(cat "$_c7_err")" "skipping mandatory-team enforcement" "expected the warning to name what was skipped"
    _block_end
fi

# ═══════════════════════════════════════════════════════════════════════════
# SECTION D -- Non-interactive path: install_kanban_system()'s team
# resolution + force-append, including the fresh-box "resolves to nothing
# at all" case.
# ═══════════════════════════════════════════════════════════════════════════

_extract_installkanban_resolution() {
    # XACA-1070-020: the extraction used to end 2 fixed lines after the
    # "continuing without mandatory-team enforcement" warning (the two `fi`s
    # closing, respectively, the rc==0 check and the outer `command -v
    # atf_mandatory_teams` guard). Adding the silent-when-absent `else`
    # branch (a new warning + its own trailing `fi`) moved the real end of
    # the block later, so the anchor now keys off THAT new branch's warning
    # text instead -- unique to this snippet, added by this same subitem --
    # and captures exactly 1 trailing line: the final `fi` that closes the
    # outer if/else.
    awk '
      index($0,"# Get selected teams from wizard env var, config file, or default")>0 {capture=1}
      capture {print}
      capture && index($0,"skipping mandatory-team enforcement (XACA-1070)")>0 {trail=1; next}
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

    # ── D5 (XACA-1070-020): mandatory-teams.sh itself entirely ABSENT (never
    # sourced at all -- distinct from any "sourced fine, registry unreadable"
    # case elsewhere in this suite). Before this fix, the outer `command -v
    # atf_mandatory_teams` guard skipped the whole block with ZERO console
    # output; aiteamforge-upgrade.sh's update_mandatory_teams() has always
    # warned in the same situation. Resolution of the user's OWN selection
    # must still succeed (fail-soft) -- only mandatory-team enforcement is
    # skipped, not the install.
    _block_start "D5 (XACA-1070-020): install-kanban.sh warns when mandatory-teams.sh itself was never sourced (previously silent)"
    _d5_dir="$SANDBOX/d5-dir"
    mkdir -p "$_d5_dir"
    _out="$(
        unset AITEAMFORGE_HOME AITEAMFORGE_CONFIG
        # Deliberately do NOT source mandatory-teams.sh -- atf_mandatory_teams
        # stays undefined, matching a real box with the lib missing entirely.
        info() { :; }; warning() { echo "WARN: $*"; }
        AITEAMFORGE_DIR="$_d5_dir"
        SELECTED_TEAMS_STR="alpha"
        _x1070_resolve_teams
    )"
    assert_contains "$_out" "alpha" "expected the user's own selection (alpha) to still resolve when the lib is absent entirely (fail-soft, not fail-closed)"
    assert_not_contains "$_out" "widget" "the mandatory team must NOT be force-appended when the lib is absent -- there is nothing to enforce it with"
    assert_contains "$_out" "WARN: mandatory-teams.sh not available" "expected an explicit warning when mandatory-teams.sh itself is missing entirely (XACA-1070-020) -- this used to be completely silent"
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
# BLOCKING A (second symptom): see Section N's identical comment -- extract
# this too, or the eval'd update_mandatory_teams below calls an undefined
# function (non-fatal via its own `|| true`, but a spurious "command not
# found" pollutes captured output).
_add_wd_to_config_fn_for_e="$(_extract_fn _xaca1070_add_team_working_dir_to_config "$UPGRADE_SH")"

if [ -z "$_has_board_fn" ] || [ -z "$_update_mandatory_fn" ] || [ -z "$_add_to_config_fn_for_e" ] || [ -z "$_add_wd_to_config_fn_for_e" ]; then
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
          eval "$_add_wd_to_config_fn_for_e"
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

    # ── E6 (XACA-1070-017): PROVE the shared definition, not just that both
    # callers happen to return the right answer against a real fixture (E1-E5
    # already do that implicitly, but a passing answer alone cannot
    # distinguish "delegates to one shared function" from "two independently
    # correct copies of the same glob" -- which is exactly the drift vector
    # this subitem closes). Redefine atf_team_has_board() to something that
    # provably runs (writes a sentinel line) and returns the OPPOSITE of
    # reality (1, "no board") against a fixture that genuinely HAS a board on
    # disk. If atf_team_provisioned() and upgrade.sh's
    # _xaca1070_mandatory_team_has_board() truly call this one function
    # rather than each carrying its own inline "*-board.json" glob, both
    # MUST flip to "not provisioned" even though nothing on disk changed --
    # and the sentinel must show the override was reached exactly twice.
    _block_start "E6 (XACA-1070-017): atf_team_provisioned() and upgrade.sh's _xaca1070_mandatory_team_has_board() delegate to the SAME atf_team_has_board -- overriding it flips BOTH"
    _e6_sentinel="$SANDBOX/e6-atf-team-has-board-calls.log"
    rm -f "$_e6_sentinel"
    _e6_dir="$SANDBOX/e6-dir"
    mkdir -p "$_e6_dir/kanban/widget"
    printf '{"teams":["widget"]}' > "$_e6_dir/.aiteamforge-config"
    echo '{"real":"board"}' > "$_e6_dir/kanban/widget/widget-board.json"
    _tp_e6="$(_x1070_mk_team_paths e6 widget "$_e6_dir/kanban/widget")"

    # Sanity pass FIRST, no override: against this real fixture both must
    # already agree "provisioned" / "has board" -- establishes the baseline
    # the override below is expected to flip.
    _e6_sanity="$(
        unset AITEAMFORGE_HOME
        AITEAMFORGE_DIR="$_e6_dir" AITEAMFORGE_CONFIG="$_tp_e6"
        # shellcheck disable=SC1091
        . "$MANDATORY_TEAMS_SH"
        # shellcheck disable=SC1091
        . "$CONFIG_SH"
        # shellcheck disable=SC1091
        . "$PATHS_SH"
        eval "$_has_board_fn"
        atf_team_provisioned widget; p1=$?
        _xaca1070_mandatory_team_has_board widget; p2=$?
        echo "PROV=$p1 HASBOARD=$p2"
    )"
    assert_contains "$_e6_sanity" "PROV=0" "sanity: atf_team_provisioned must report provisioned (0) against the real, unmodified fixture"
    assert_contains "$_e6_sanity" "HASBOARD=0" "sanity: _xaca1070_mandatory_team_has_board must report has-board (0) against the real, unmodified fixture"

    _e6_out="$(
        unset AITEAMFORGE_HOME
        AITEAMFORGE_DIR="$_e6_dir" AITEAMFORGE_CONFIG="$_tp_e6"
        # shellcheck disable=SC1091
        . "$MANDATORY_TEAMS_SH"
        # shellcheck disable=SC1091
        . "$CONFIG_SH"
        # shellcheck disable=SC1091
        . "$PATHS_SH"
        eval "$_has_board_fn"
        atf_team_has_board() { echo "OVERRIDE CALLED for $1" >> "$_e6_sentinel"; return 1; }
        atf_team_provisioned widget; p1=$?
        _xaca1070_mandatory_team_has_board widget; p2=$?
        echo "PROV=$p1 HASBOARD=$p2"
    )"
    assert_contains "$_e6_out" "PROV=1" "atf_team_provisioned must flip to NOT PROVISIONED (1) once the shared atf_team_has_board is overridden -- the real board file on disk never changed, so this can only happen if it DELEGATES rather than re-implementing the glob itself"
    assert_contains "$_e6_out" "HASBOARD=1" "_xaca1070_mandatory_team_has_board must ALSO flip to 1 once atf_team_has_board is overridden -- proves upgrade.sh calls the SAME shared function, not its own independent copy"
    _e6_calls="$(grep -c 'OVERRIDE CALLED for widget' "$_e6_sentinel" 2>/dev/null || echo 0)"
    assert_eq "$_e6_calls" "2" "expected the override to run exactly twice -- once from atf_team_provisioned, once from _xaca1070_mandatory_team_has_board -- proving both call sites resolve to the SAME function object (XACA-1070-017's actual requirement), got $_e6_calls"
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

    # ── F7 (XACA-1070-019): a NESTED "teams" key earlier in the raw text must
    # not be mistaken for the root key. Before this fix, the naive
    # pattern.search() returned the FIRST "teams": [...] occurrence in the
    # file -- here that is {"metadata": {"teams": [...]}}, not the real
    # root-level .teams[] several lines below it. This never corrupted
    # anything (the post-write re-parse-and-compare already caught a wrong
    # target and aborted, file untouched -- QA confirmed in review), but the
    # real root .teams[] never got the team added. The fix must (a) target
    # the ROOT key specifically, (b) leave the nested metadata.teams block
    # byte-for-byte untouched, and (c) still pass the existing post-write
    # verification.
    _block_start "F7 (XACA-1070-019): a nested {\"metadata\":{\"teams\":[...]}} occurring BEFORE the real root .teams[] is not mistaken for it"
    _f7_dir="$SANDBOX/f7-dir"
    mkdir -p "$_f7_dir"
    cat > "$_f7_dir/.aiteamforge-config" <<'EOF'
{
  "metadata": {
    "teams": [
      "decoy1",
      "decoy2"
    ]
  },
  "installed_features": ["kanban"],
  "teams": [
    "alpha",
    "ios"
  ]
}
EOF
    _sha_before_f7="$(shasum -a 256 "$_f7_dir/.aiteamforge-config" | awk '{print $1}')"
    _out="$(_run_add_to_config widget "$_f7_dir")"; _rc=$?
    assert_eq "$_rc" "0" "expected successful registration against the ROOT .teams[] despite the earlier nested decoy, got rc=$_rc, out=[$_out]"
    assert_contains "$_out" "OK: XACA-1070: registered 'widget'" "expected the registration success message"
    _root_teams_f7="$(jq -c '.teams' "$_f7_dir/.aiteamforge-config" 2>/dev/null)"
    assert_contains "$_root_teams_f7" "widget" "the ROOT .teams[] must now contain widget: $_root_teams_f7"
    assert_contains "$_root_teams_f7" "alpha" "the ROOT .teams[] must still contain the pre-existing alpha: $_root_teams_f7"
    assert_contains "$_root_teams_f7" "ios" "the ROOT .teams[] must still contain the pre-existing ios: $_root_teams_f7"
    _nested_teams_f7="$(jq -c '.metadata.teams' "$_f7_dir/.aiteamforge-config" 2>/dev/null)"
    assert_eq "$_nested_teams_f7" '["decoy1","decoy2"]' "the NESTED metadata.teams[] must be left completely untouched, got: $_nested_teams_f7"
    assert_not_contains "$_nested_teams_f7" "widget" "widget must NEVER be added to the nested decoy array"
    _sha_after_f7="$(shasum -a 256 "$_f7_dir/.aiteamforge-config" | awk '{print $1}')"
    assert_ne "$_sha_after_f7" "$_sha_before_f7" "the file must actually have changed (root .teams[] grew) -- an unchanged sha would mean nothing was written at all"
    _block_end

    # ── F8 (XACA-1070-019 negative control): TWO depth-1 "teams" keys (a
    # duplicate root key -- valid-ish raw text that json.loads silently
    # resolves by keeping the LAST value, per the JSON spec's usual
    # last-wins handling of duplicate keys) must refuse to guess which span
    # is "the real one" rather than silently editing the first (or last)
    # match -- warn, rc!=0, file untouched. Exercises the "more than one
    # top-level match" arm added alongside the depth check; F7 already
    # covers its "found exactly one, and it is the right one" sibling, and
    # F6 already covers "no .teams key at the root at all".
    _block_start "F8 (XACA-1070-019 negative control): duplicate depth-1 \"teams\" keys -> refuses to guess, warned, rc!=0, byte-identical"
    _f8_dir="$SANDBOX/f8-dir"
    mkdir -p "$_f8_dir"
    cat > "$_f8_dir/.aiteamforge-config" <<'EOF'
{
  "teams": [
    "alpha"
  ],
  "installed_features": ["kanban"],
  "teams": [
    "ios"
  ]
}
EOF
    _sha_before_f8="$(shasum -a 256 "$_f8_dir/.aiteamforge-config" | awk '{print $1}')"
    _out_f8="$(_run_add_to_config widget "$_f8_dir")"; _rc_f8=$?
    assert_ne "$_rc_f8" "0" "a duplicate top-level .teams key must produce a non-zero return code, got $_rc_f8"
    assert_contains "$_out_f8" "WARN:" "expected a warning to be printed rather than a silent guess"
    _sha_after_f8="$(shasum -a 256 "$_f8_dir/.aiteamforge-config" | awk '{print $1}')"
    assert_eq "$_sha_after_f8" "$_sha_before_f8" "a config with an ambiguous duplicate root key must be left BYTE-IDENTICAL, never guessed at"
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

    # ── G7b/G7c (PR #865 review, item 4 -- WARN -> FAULT, gated): lib
    # unavailable now FAULTs when the surrounding install otherwise looks
    # real (a sibling common.sh is present -- git + the Formula both
    # guarantee mandatory-teams.sh's own presence, so that specific file
    # being the ONE thing missing is a genuine partial-install defect, not
    # a shrug), but still WARNs -- never a hard failure -- when
    # AITEAMFORGE_HOME/LIBEXEC_DIR itself doesn't look like a real
    # framework root at all (G5 above already covers that second case for
    # the bin/ copy; G7c below is its libexec/ copy counterpart).
    _mk_libdir_with_common() {
        local dir="$SANDBOX/libdir-$1"
        mkdir -p "$dir/lib"
        : > "$dir/lib/common.sh"
        printf '%s' "$dir"
    }

    _run_doctor_libexec_check_custom_libexecdir() {
        local reg_dir="$1" libexec_dir="$2"
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
          LIBEXEC_DIR="$libexec_dir"
          check_mandatory_teams
          echo "COUNTERS total=$TOTAL_CHECKS passed=$PASSED_CHECKS failed=$FAILED_CHECKS warn=$WARNING_CHECKS"
        ) 2>&1
    }

    _block_start "G7b (libexec copy): lib genuinely unavailable but common.sh present (looks like a real install) -> FAULT, not WARN"
    _libdir_g7b="$(_mk_libdir_with_common g7b)"
    _out="$(_run_doctor_libexec_check_custom_libexecdir "__NOLIB__" "$_libdir_g7b")"
    assert_contains "$_out" "failed=1" "expected a FAULT: common.sh exists right next to the missing mandatory-teams.sh, so this looks like a genuine partial install, got: $_out"
    assert_not_contains "$_out" "warn=1" "must not ALSO count as a warning: $_out"
    _block_end

    _block_start "G7c (libexec copy): lib unavailable AND common.sh also absent (unfaithful LIBEXEC_DIR, mirrors G5) -> WARN, never a hard failure"
    _libdir_g7c="$SANDBOX/libdir-g7c-empty"; mkdir -p "$_libdir_g7c"
    _out="$(_run_doctor_libexec_check_custom_libexecdir "__NOLIB__" "$_libdir_g7c")"
    assert_contains "$_out" "warn=1" "expected a WARN: LIBEXEC_DIR doesn't look like a real framework root at all (no common.sh either), got: $_out"
    assert_not_contains "$_out" "failed=1" "an unfaithful LIBEXEC_DIR must not become a hard failure here (already a different, more fundamental problem elsewhere): $_out"
    _block_end

    _block_start "G7d (bin copy): lib unavailable but common.sh present under AITEAMFORGE_HOME (looks like a real install) -> FAULT, not WARN"
    _home_g7d="$(_mk_libdir_with_common g7d)"
    mkdir -p "${_home_g7d}/libexec"
    mv "${_home_g7d}/lib" "${_home_g7d}/libexec/lib"
    # _run_doctor_bin_check sets AITEAMFORGE_HOME="$aitf_home" and sources the
    # real preamble against it; the fixture above has NO
    # libexec/lib/mandatory-teams.sh (only common.sh was moved in), so the
    # preamble's own `[ -f ... ]` guard leaves _MANDATORY_TEAMS_LIB_OK=false
    # exactly like G5 -- but common.sh IS present alongside it here.
    _out="$(_run_doctor_bin_check "$_home_g7d" "$SANDBOX/g7d-work")"
    assert_contains "$_out" "LIB_OK=false" "expected the lib to still fail to load (fixture has no mandatory-teams.sh): $_out"
    assert_contains "$_out" "failed=1" "expected a FAULT: common.sh is present under this AITEAMFORGE_HOME, so it looks like a real install missing exactly one file, got: $_out"
    assert_not_contains "$_out" "warn=1" "must not ALSO count as a warning: $_out"
    _block_end

    # ── G8 (PR #865 review, item 3 -- POST-FIX, was a "dead code" FINDING):
    # this suite used to document (not assert against) that the
    # AITEAMFORGE_HOME priority-1 branch guessed
    # "${AITEAMFORGE_HOME}/../share/teams/registry.json", which does NOT
    # exist under the real Homebrew-installed / dev-clone tap-root layout
    # -- the feature only ever worked end-to-end because priority-2
    # (self-location) silently carried it. That branch has now been fixed
    # to guess "${AITEAMFORGE_HOME}/share/teams/registry.json" (no "..") --
    # see _atf_mandatory_teams_registry_path's header comment for the full
    # rationale (bin/aiteamforge-doctor.sh's own real preamble treats
    # AITEAMFORGE_HOME as the tap root everywhere else it uses it, e.g.
    # "${AITEAMFORGE_HOME}/share/templates/...").
    #
    # G8 below proves priority 1 now resolves the registry DIRECTLY --
    # without falling through to self-location -- by giving the two
    # priorities DIFFERENT, distinguishable answers: mandatory-teams.sh is
    # sourced from sandbox A (so self-location's own tap-root guess is A),
    # while AITEAMFORGE_HOME is pointed at an entirely separate sandbox B
    # carrying a different mandatory-team list. If priority 1 is broken
    # (the old "../share" guess, or removed entirely), resolution falls
    # through to self-location and returns A's team ('gizmo'+'widget',
    # sorted); with the fix, it returns B's ('widget') and the resolved
    # path is exactly "$B/share/teams/registry.json" -- proving priority 1
    # fired, not just that SOME priority eventually found a file.
    _block_start "G8: AITEAMFORGE_HOME priority-1 branch resolves \${AITEAMFORGE_HOME}/share/teams/registry.json DIRECTLY (no '..', no fallback needed)"
    _reg_g8_self="$(_x1070_mk_reg_sandbox g8-self "$REG_TWO_TRUE_ORDERED")"
    _reg_g8_home="$(_x1070_mk_reg_sandbox g8-home "$REG_ONE_TRUE")"
    _out="$(
        unset AITEAMFORGE_DIR AITEAMFORGE_CONFIG
        # shellcheck disable=SC1091
        . "$_reg_g8_self/libexec/lib/mandatory-teams.sh"
        AITEAMFORGE_HOME="$_reg_g8_home"
        printf 'RESOLVED=%s\n' "$(_atf_mandatory_teams_registry_path)"
        printf 'TEAMS=%s\n' "$(atf_mandatory_teams | tr '\n' ',')"
    )"
    assert_contains "$_out" "RESOLVED=${_reg_g8_home}/share/teams/registry.json" "expected priority 1 to resolve AITEAMFORGE_HOME's OWN registry.json directly, got: $_out"
    assert_not_contains "$_out" "RESOLVED=${_reg_g8_self}" "must NOT have fallen through to self-location's sandbox when AITEAMFORGE_HOME was set and valid: $_out"
    assert_contains "$_out" "TEAMS=widget," "expected the AITEAMFORGE_HOME registry's mandatory team ('widget'), got: $_out"
    assert_not_contains "$_out" "gizmo" "must NOT have read the self-location sandbox's registry ('gizmo'+'widget') when AITEAMFORGE_HOME pointed elsewhere: $_out"
    _block_end

    # ── G9 (sanity, documents the historical bug shape): the OLD "one level
    # too high" guess must not accidentally exist in the real tap either --
    # if it did, G8 above could pass for the wrong reason (both guesses
    # resolving to the same fixture by coincidence in some future layout).
    _block_start "G9: sanity -- the real tap's OWN registry.json is not ALSO reachable via the old (wrong) '\${AITEAMFORGE_HOME}/../share' guess"
    assert_file_not_exists "$TAP_ROOT/../share/teams/registry.json" "if this ever starts existing, G8's distinguishing test above stops being conclusive and must be revisited"
    assert_file_exists "$TAP_ROOT/share/teams/registry.json" "sanity: the real file is still exactly where the fixed priority-1 guess (no '..') expects it"
    _block_end
fi

# ═══════════════════════════════════════════════════════════════════════════
# SECTION H -- install-kanban.sh's mandatory-teams.sh source is GUARDED
# (PR #865 review, item 5).
# ═══════════════════════════════════════════════════════════════════════════

_block_start "H1: install-kanban.sh sources mandatory-teams.sh through a guarded [ -f ... ] && source, not a bare source"
grep -qE '^\[ -f "\$SCRIPT_DIR/\.\./lib/mandatory-teams\.sh" \] && source "\$SCRIPT_DIR/\.\./lib/mandatory-teams\.sh"' "$INSTALL_KANBAN_SH" \
    || _block_note_fail "install-kanban.sh no longer guards its mandatory-teams.sh source with [ -f ... ] && source -- item 5 regressed"
grep -qE '^source "\$SCRIPT_DIR/\.\./lib/mandatory-teams\.sh"' "$INSTALL_KANBAN_SH" \
    && _block_note_fail "install-kanban.sh STILL has a bare (unguarded) source of mandatory-teams.sh alongside the guarded one"
_block_end

_block_start "H2: FUNCTIONAL -- the exact guarded idiom does NOT abort under set -euo pipefail when the target is missing"
_h2_out="$(
    /bin/bash -c '
        set -euo pipefail
        SCRIPT_DIR="/no/such/tap/dir/libexec/installers"
        [ -f "$SCRIPT_DIR/../lib/mandatory-teams.sh" ] && source "$SCRIPT_DIR/../lib/mandatory-teams.sh"
        echo "REACHED_AFTER_GUARD"
    '
)"
assert_contains "$_h2_out" "REACHED_AFTER_GUARD" "the guarded idiom must not abort the script under set -euo pipefail when mandatory-teams.sh is absent, got: $_h2_out"
_block_end

_block_start "H3: NEGATIVE CONTROL -- the OLD (unguarded) idiom DOES abort under set -euo pipefail, proving H2 exercises a real difference"
_h3_out="$(
    /bin/bash -c '
        set -euo pipefail
        SCRIPT_DIR="/no/such/tap/dir/libexec/installers"
        source "$SCRIPT_DIR/../lib/mandatory-teams.sh"
        echo "REACHED_AFTER_BARE_SOURCE"
    ' 2>/dev/null
)"; _h3_rc=$?
assert_ne "$_h3_rc" "0" "the pre-fix bare 'source' must exit non-zero under set -euo pipefail when the file is missing (sanity check that H2 is testing something real)"
assert_not_contains "$_h3_out" "REACHED_AFTER_BARE_SOURCE" "the pre-fix bare 'source' must abort BEFORE the next line runs, got: $_h3_out"
_block_end

# ═══════════════════════════════════════════════════════════════════════════
# SECTIONS I-N -- XACA-1070 / PR #865 round 2: cockpit had ZERO coverage
# before this round (grep for "cockpit" in this file historically matched
# only prose inside Section C's comments about the interactive selection
# span) -- which is exactly why three review passes missed the original
# defect: `aiteamforge setup --cockpit-only` never ran install-team.sh for
# a mandatory team at all, and nothing here would have caught it.
#
# THE USER DECISION UNDER TEST: a mandatory team gets its FULL setup on
# EVERY install, cockpit included -- team, board, config entry, personas,
# kanban board (via install-team.sh, not the box-wide kanban SYSTEM), and
# its LCARS server + tabs. Every section below maps to one of the four
# carve-outs in bin/aiteamforge-setup.sh's own "Install selected teams" /
# persona-loop / "Cockpit mandatory-team LCARS instance" / summary-text
# header comments -- read those first if a test here fails, they explain
# the WHY behind what each assertion checks.
# ═══════════════════════════════════════════════════════════════════════════

# ─────────────────────────────────────────────────────────────────────────────
# SECTION I -- Carve-out 1: the team-install loop's per-iteration cockpit
# guard ("Install selected teams" header comment in setup.sh). Extracted by
# anchoring on the unique "Installing teams..." echo immediately above the
# loop through the loop's own terminating `done`.
# ─────────────────────────────────────────────────────────────────────────────
_extract_team_install_loop() {
    awk '
      $0=="echo -e \"${BOLD}Installing teams...${NC}\"" {capture=1}
      capture {print}
      capture && $0=="done" {exit}
    ' "$SETUP_SH"
}
_team_loop_snippet="$(_extract_team_install_loop)"

_block_start "SECTION I setup: extract the cockpit team-install-loop span from setup.sh"
if [ -z "$_team_loop_snippet" ]; then
    _block_note_fail "extraction produced no output -- cannot run Section I"
fi
_block_end

if [ -n "$_team_loop_snippet" ]; then
    eval "_x1070_team_install_loop() {
$_team_loop_snippet
}"

    _i_installers_dir="$SANDBOX/i-installers"
    mkdir -p "$_i_installers_dir"
    cat > "$_i_installers_dir/install-team.sh" <<'STUB'
#!/bin/bash
echo "CALLED:$1" >> "$I_LOG_FILE"
exit 0
STUB
    chmod +x "$_i_installers_dir/install-team.sh"
    _i_reg="$(_x1070_mk_reg_sandbox section-i "$REG_ONE_TRUE")"

    # Runs the extracted loop with SELECTED_TEAMS=("$@") under the given
    # profile, against the stub install-team.sh above, and returns everything
    # the stub logged (one "CALLED:<team_id>" line per real invocation).
    _run_team_install_loop() {
        local profile="$1"; shift
        local log="$SANDBOX/i-log-$profile-$RANDOM.txt"
        : > "$log"
        ( unset AITEAMFORGE_HOME AITEAMFORGE_DIR AITEAMFORGE_CONFIG
          # shellcheck disable=SC1091
          . "$_i_reg/libexec/lib/mandatory-teams.sh"
          BOLD=""; NC=""; BLUE=""; RED=""; GREEN=""
          INSTALL_PROFILE="$profile"
          INSTALLERS_DIR="$_i_installers_dir"
          INSTALL_DIR="$SANDBOX/i-install-dir"
          INSTALL_ERRORS=0
          I_LOG_FILE="$log"; export I_LOG_FILE
          SELECTED_TEAMS=("$@")
          _x1070_team_install_loop
        ) >/dev/null 2>&1
        cat "$log" 2>/dev/null
    }

    _block_start "I1: cockpit + mandatory team ('widget') in SELECTED_TEAMS -> install-team.sh IS invoked"
    _res="$(_run_team_install_loop cockpit widget)"
    assert_contains "$_res" "CALLED:widget" "expected install-team.sh to be invoked for the mandatory team on cockpit, got: [$_res]"
    _block_end

    _block_start "I2: cockpit + a non-mandatory team ('alpha') in SELECTED_TEAMS (hypothetical upstream regression) -> install-team.sh is NOT invoked"
    _res="$(_run_team_install_loop cockpit alpha)"
    assert_not_contains "$_res" "CALLED:alpha" "the per-iteration cockpit guard must refuse a non-mandatory team even if it somehow reached SELECTED_TEAMS, got: [$_res]"
    _block_end

    _block_start "I3: cockpit + BOTH a mandatory and non-mandatory team present -> ONLY the mandatory one is installed"
    _res="$(_run_team_install_loop cockpit alpha widget)"
    assert_contains "$_res" "CALLED:widget" "mandatory team must still be installed alongside a non-mandatory one, got: [$_res]"
    assert_not_contains "$_res" "CALLED:alpha" "non-mandatory team must be skipped even when a mandatory team is also present, got: [$_res]"
    _block_end

    _block_start "I4: full (non-cockpit) profile -- unaffected; both a mandatory and a non-mandatory team get installed normally"
    _res="$(_run_team_install_loop full alpha widget)"
    assert_contains "$_res" "CALLED:alpha" "full-profile install must be unaffected by the cockpit-only guard, got: [$_res]"
    assert_contains "$_res" "CALLED:widget" "full-profile install must still install a (also-mandatory) team normally, got: [$_res]"
    _block_end

    _block_start "I5: cockpit + unreadable registry -> fails closed (installs nothing, never 'installs everything')"
    _i_reg_bad="$(_x1070_mk_reg_sandbox section-i-bad "__MISSING__")"
    _res="$(
        local_log="$SANDBOX/i5-log.txt"; : > "$local_log"
        ( unset AITEAMFORGE_HOME AITEAMFORGE_DIR AITEAMFORGE_CONFIG
          # shellcheck disable=SC1091
          . "$_i_reg_bad/libexec/lib/mandatory-teams.sh"
          BOLD=""; NC=""; BLUE=""; RED=""; GREEN=""
          INSTALL_PROFILE="cockpit"
          INSTALLERS_DIR="$_i_installers_dir"
          INSTALL_DIR="$SANDBOX/i5-install-dir"
          INSTALL_ERRORS=0
          I_LOG_FILE="$local_log"; export I_LOG_FILE
          SELECTED_TEAMS=("widget")
          _x1070_team_install_loop
        ) >/dev/null 2>&1
        cat "$local_log" 2>/dev/null
    )"
    assert_not_contains "$_res" "CALLED:widget" "an unreadable registry must fail CLOSED (install nothing on cockpit), never fail open, got: [$_res]"
    _block_end
fi

# ─────────────────────────────────────────────────────────────────────────────
# SECTION J -- Carve-out 2: the persona/avatar/logo copy loop. No explicit
# cockpit gate existed before this round (the loop's old comment claimed it
# was "skipped in cockpit mode" purely because SELECTED_TEAMS used to always
# be empty there); this round adds the same belt-and-suspenders per-
# iteration guard as Section I's loop, in case a future regression ever
# lets a non-mandatory id reach SELECTED_TEAMS on cockpit.
# ─────────────────────────────────────────────────────────────────────────────
_extract_persona_loop() {
    awk '
      $0=="mkdir -p \"${INSTALL_DIR}/avatars\"" {capture=1}
      capture {print}
      capture && $0=="done" {exit}
    ' "$SETUP_SH"
}
_persona_loop_snippet="$(_extract_persona_loop)"

_block_start "SECTION J setup: extract the persona/avatar/logo copy loop span from setup.sh"
if [ -z "$_persona_loop_snippet" ]; then
    _block_note_fail "extraction produced no output -- cannot run Section J"
fi
_block_end

if [ -n "$_persona_loop_snippet" ]; then
    eval "_x1070_persona_loop() {
$_persona_loop_snippet
}"

    _j_reg="$(_x1070_mk_reg_sandbox section-j "$REG_ONE_TRUE")"
    _j_home="$SANDBOX/j-home"
    for _jt in widget alpha; do
        mkdir -p "$_j_home/share/personas/$_jt/agents" "$_j_home/share/personas/$_jt/avatars"
        printf '# %s persona\n' "$_jt" > "$_j_home/share/personas/$_jt/agents/${_jt}_persona.md"
        : > "$_j_home/share/personas/$_jt/avatars/${_jt}.png"
    done

    # Runs the extracted persona loop with SELECTED_TEAMS=("$@") under the
    # given profile; returns the fresh INSTALL_DIR it copied into.
    _run_persona_loop() {
        local profile="$1"; shift
        local install_dir="$SANDBOX/j-install-$profile-$RANDOM"
        mkdir -p "$install_dir"
        ( unset AITEAMFORGE_HOME AITEAMFORGE_DIR AITEAMFORGE_CONFIG
          # shellcheck disable=SC1091
          . "$_j_reg/libexec/lib/mandatory-teams.sh"
          GREEN=""; NC=""
          INSTALL_PROFILE="$profile"
          AITEAMFORGE_HOME="$_j_home"
          INSTALL_DIR="$install_dir"
          SELECTED_TEAMS=("$@")
          _x1070_persona_loop
        ) >/dev/null 2>&1
        printf '%s' "$install_dir"
    }

    _block_start "J1: cockpit + mandatory team ('widget') -> its personas/avatars ARE copied"
    _dir="$(_run_persona_loop cockpit widget)"
    assert_file_exists "$_dir/widget/personas/agents/widget_persona.md" "expected widget's persona file to be copied on cockpit"
    assert_file_exists "$_dir/avatars/widget.png" "expected widget's avatar to also land in the flat avatars/ pool"
    _block_end

    _block_start "J2: cockpit + non-mandatory team ('alpha') (hypothetical regression) -> its personas are NOT copied"
    _dir="$(_run_persona_loop cockpit alpha)"
    assert_file_not_exists "$_dir/alpha/personas/agents/alpha_persona.md" "a non-mandatory team's personas must not leak onto a cockpit box even if it somehow reached SELECTED_TEAMS"
    _block_end

    _block_start "J3: full (non-cockpit) profile -- unaffected; both teams' personas are copied normally"
    _dir="$(_run_persona_loop full alpha widget)"
    assert_file_exists "$_dir/alpha/personas/agents/alpha_persona.md" "full-profile install must be unaffected by the cockpit-only guard"
    assert_file_exists "$_dir/widget/personas/agents/widget_persona.md" "full-profile install must still copy a (also-mandatory) team's personas normally"
    _block_end
fi

# ─────────────────────────────────────────────────────────────────────────────
# SECTION K -- Carve-out 3: the "Cockpit mandatory-team LCARS instance"
# block. Extracted by anchoring on its first statement through its own
# trailing sentinel comment (same idiom this file already uses elsewhere,
# e.g. "fi  # end: if INSTALL_PROFILE != cockpit (team selection block)").
# ─────────────────────────────────────────────────────────────────────────────
_extract_lcars_carveout() {
    awk '
      $0=="_cockpit_has_mandatory_team=\"false\"" {capture=1}
      capture {print}
      capture && $0=="fi  # end: cockpit mandatory-team LCARS instance (XACA-1070, PR #865 round 2)" {exit}
    ' "$SETUP_SH"
}
_lcars_snippet="$(_extract_lcars_carveout)"

_block_start "SECTION K setup: extract the cockpit mandatory-team LCARS instance block from setup.sh"
if [ -z "$_lcars_snippet" ]; then
    _block_note_fail "extraction produced no output -- cannot run Section K"
fi
_block_end

if [ -n "$_lcars_snippet" ]; then
    # ── K1-K3: FUNCTIONAL -- run the real block against the REAL tap's
    # install-kanban.sh + share/lcars-ui, pointed at a sandbox AITEAMFORGE_DIR.
    # install_lcars_ui / configure_lcars_port are pure static-file writers
    # scoped entirely under AITEAMFORGE_DIR, so this is safe to run for real
    # (XACA-0212: nothing here ever touches ~/aiteamforge, ~/.aiteamforge, or
    # any real LaunchAgent).
    eval "_x1070_lcars_carveout() {
$_lcars_snippet
}"

    # XACA-1070-027 (PR #865 round 3 review): the carve-out now gates on
    # `atf_is_mandatory_team` (matching carve-outs 1 and 2) instead of
    # `[ -n "$_clt" ]`, so this harness must provide that function. It
    # cannot reuse _x1070_mk_reg_sandbox's AITEAMFORGE_HOME-pointed registry
    # trick the way Section J's harness does: this subshell ALSO needs
    # AITEAMFORGE_HOME="$TAP_ROOT" so install-kanban.sh/share/lcars-ui
    # resolve against the REAL tap checkout, and the real tap's own
    # share/teams/registry.json would then win priority 1 of
    # _atf_mandatory_teams_registry_path over any sandboxed one -- making
    # this test depend on whatever the checkout's live registry.json
    # happens to say. A minimal inline stub isolates exactly what this
    # section means to test (does the carve-out correctly call and gate on
    # atf_is_mandatory_team) from registry resolution, which Section A
    # already covers on its own.
    atf_is_mandatory_team() { [ "$1" = "widget" ]; }

    _run_lcars_carveout() {
        local profile="$1" install_dir="$2"; shift 2
        ( BOLD=""; NC=""; YELLOW=""
          INSTALL_PROFILE="$profile"
          INSTALLERS_DIR="$TAP_ROOT/libexec/installers"
          AITEAMFORGE_HOME="$TAP_ROOT"
          INSTALL_DIR="$install_dir"
          INSTALL_ERRORS=0
          SELECTED_TEAMS=("$@")
          _x1070_lcars_carveout
        ) >/dev/null 2>&1
    }

    _block_start "K1: cockpit + mandatory team present -> install_lcars_ui copies lcars-ui/server.py into AITEAMFORGE_DIR"
    _k1_dir="$SANDBOX/k1-install-dir"; mkdir -p "$_k1_dir"
    _run_lcars_carveout cockpit "$_k1_dir" widget
    if [ -d "$TAP_ROOT/share/lcars-ui" ]; then
        assert_file_exists "$_k1_dir/lcars-ui/server.py" "expected install_lcars_ui to copy server.py so a mandatory team's start_lcars_server has something to launch"
    else
        echo "     (skipped file-existence assertion -- this tap checkout has no share/lcars-ui; install_lcars_ui's own no-op guard is exercised instead)"
    fi
    _block_end

    _block_start "K2: cockpit + mandatory team present -> configure_lcars_port writes the port config files"
    if [ -d "$TAP_ROOT/share/lcars-ui" ]; then
        assert_file_exists "$_k1_dir/lcars-ui/lcars-target.js" "expected configure_lcars_port to write lcars-target.js"
        assert_file_exists "$_k1_dir/lcars-ui/.lcars-port" "expected configure_lcars_port to write .lcars-port"
        assert_contains "$(cat "$_k1_dir/lcars-ui/.lcars-port" 2>/dev/null)" "8080" "expected the default LCARS port (8080) to be recorded"
    else
        echo "     (skipped -- no share/lcars-ui in this checkout, see K1)"
    fi
    _block_end

    _block_start "K3: cockpit + ZERO mandatory teams selected (today's real state until spacedock ships) -> complete no-op, no lcars-ui/ created at all"
    _k3_dir="$SANDBOX/k3-install-dir"; mkdir -p "$_k3_dir"
    _run_lcars_carveout cockpit "$_k3_dir"
    assert_file_not_exists "$_k3_dir/lcars-ui/server.py" "a cockpit box with no mandatory team must gain NOTHING from this block"
    _block_end

    _block_start "K4: STRUCTURAL -- the carve-out calls ONLY install_lcars_ui + configure_lcars_port, never install_kanban_system or any LaunchAgent installer, never touches INSTALL_KANBAN"
    _lcars_code_only="$(printf '%s\n' "$_lcars_snippet" | grep -v '^[[:space:]]*#')"
    assert_contains "$_lcars_code_only" "install_lcars_ui" "expected a real call to install_lcars_ui"
    assert_contains "$_lcars_code_only" "configure_lcars_port" "expected a real call to configure_lcars_port"
    assert_not_contains "$_lcars_code_only" "install_kanban_system" "must NOT call install_kanban_system -- that would flip on the backup system, port-mgmt templates, and every mandatory LaunchAgent box-wide (this is carve-out 3's whole point: narrow, not a wholesale INSTALL_KANBAN flip)"
    assert_not_contains "$_lcars_code_only" "_launchagent" "must NOT reference any install_*_launchagent function (cockpit must gain zero LaunchAgents from this)"
    assert_not_contains "$_lcars_code_only" "INSTALL_KANBAN=" "must NOT set/flip INSTALL_KANBAN as a side effect"
    _block_end

    _block_start "K5: full (non-cockpit) profile -- this block never runs at all, regardless of SELECTED_TEAMS (full mode's LCARS setup goes through install_kanban_system unchanged)"
    _k5_dir="$SANDBOX/k5-install-dir"; mkdir -p "$_k5_dir"
    _run_lcars_carveout full "$_k5_dir" widget
    assert_file_not_exists "$_k5_dir/lcars-ui/server.py" "full-profile installs must not go through this cockpit-only carve-out at all"
    _block_end

    # XACA-1070-027 (PR #865 round 3 review): this
    # carve-out used to gate on `[ -n "$_clt" ]` -- "is this slot
    # non-empty" -- instead of `atf_is_mandatory_team`, unlike carve-outs 1
    # (persona/avatar copy, Section J) and 2 (team-install loop, per-
    # iteration guard). K1-K5 above all pass "widget" (which THIS
    # harness's atf_is_mandatory_team stub recognizes as mandatory), so
    # none of them can distinguish the old `[ -n ]` gate from the fixed
    # `atf_is_mandatory_team` gate -- both agree on "widget". K6 uses
    # "alpha", which the SAME stub does NOT recognize as mandatory, to
    # actually separate the two: pre-fix, `[ -n "$_clt" ]` is true for
    # "alpha" too (any non-empty string) and an LCARS instance would be
    # created for a non-mandatory team on cockpit; post-fix,
    # atf_is_mandatory_team alpha is false and nothing is created.
    _block_start "K6: cockpit + a NON-mandatory but non-empty team ('alpha') in SELECTED_TEAMS (hypothetical upstream regression) -> LCARS instance is NOT created (XACA-1070-027)"
    _k6_dir="$SANDBOX/k6-install-dir"; mkdir -p "$_k6_dir"
    _run_lcars_carveout cockpit "$_k6_dir" alpha
    assert_file_not_exists "$_k6_dir/lcars-ui/server.py" "a non-mandatory team reaching SELECTED_TEAMS on cockpit must gain NOTHING from this carve-out, even though the slot is non-empty (pre-fix: [ -n \"\$_clt\" ] alone would have created one)"
    _block_end
fi

# ─────────────────────────────────────────────────────────────────────────────
# SECTION L -- Carve-out 4: the three cockpit "Teams:" display strings
# (summary, dry-run preview, completion banner) that used to hardcode
# "(none...)" regardless of SELECTED_TEAMS.
# ─────────────────────────────────────────────────────────────────────────────
_display_fn="$(_extract_fn "_cockpit_mandatory_teams_str" "$SETUP_SH")"

_block_start "SECTION L setup: extract _cockpit_mandatory_teams_str() from setup.sh"
if [ -z "$_display_fn" ]; then
    _block_note_fail "extraction produced no output -- cannot run Section L"
fi
_block_end

if [ -n "$_display_fn" ]; then
    eval "$_display_fn"

    _block_start "L1: one mandatory team selected -> its id is returned"
    assert_eq "$( (SELECTED_TEAMS=("widget"); _cockpit_mandatory_teams_str) )" "widget" "expected 'widget' back"
    _block_end

    _block_start "L2: empty entries in SELECTED_TEAMS are skipped"
    assert_eq "$( (SELECTED_TEAMS=("" "widget" ""); _cockpit_mandatory_teams_str) )" "widget" "expected empty array slots to be filtered out"
    _block_end

    _block_start "L3: zero mandatory teams (today's real state) -> empty string, never a placeholder"
    assert_eq "$( (SELECTED_TEAMS=(); _cockpit_mandatory_teams_str) )" "" "expected an empty string when SELECTED_TEAMS is genuinely empty"
    _block_end

    _block_start "L4: STRUCTURAL -- all three cockpit 'Teams:' display sites (summary, dry-run, completion) now consult _cockpit_mandatory_teams_str instead of an unconditional '(none...)'"
    _display_refs="$(grep -c '_cockpit_mandatory_teams_str' "$SETUP_SH")"
    assert_eq "$_display_refs" "4" "expected exactly 4 references (1 definition + 3 call sites) to _cockpit_mandatory_teams_str, got $_display_refs -- if this grew or shrank, a display site was added/removed/reverted"
    _block_end

    _block_start "L5: STRUCTURAL -- the non-cockpit 'Teams: \${SELECTED_TEAMS[*]}' display lines are untouched (non-cockpit path unchanged)"
    _non_cockpit_display_count="$(grep -c 'Teams:      \${SELECTED_TEAMS\[\*\]}' "$SETUP_SH")"
    [ "$_non_cockpit_display_count" -ge 2 ] || _block_note_fail "expected at least 2 non-cockpit 'Teams: \${SELECTED_TEAMS[*]}' display lines (summary + completion) to remain, got $_non_cockpit_display_count"
    _block_end
fi

# ─────────────────────────────────────────────────────────────────────────────
# SECTION M -- Doctor PASS on a mandatory team that IS provisioned. Section G
# already covers zero-mandatory PASS (G1/G4) and mandatory-but-unprovisioned
# FAULT (G2/G6); this closes the round-2 test brief's explicit requirement:
# "both doctor copies PASS on a provisioned cockpit box". check_mandatory_teams
# does not read INSTALL_PROFILE at all -- only atf_team_provisioned's
# config+board evidence -- so ".install-profile" = "cockpit" in the fixture
# below documents the scenario without being load-bearing to the assertion.
# ─────────────────────────────────────────────────────────────────────────────
_check_result_libexec_fn_m="$(_extract_fn check_result "$DOCTOR_LIBEXEC_SH")"
_check_mand_libexec_fn_m="$(_extract_fn check_mandatory_teams "$DOCTOR_LIBEXEC_SH")"
_check_result_bin_fn_m="$(_extract_fn check_result "$DOCTOR_BIN_SH")"
_check_mand_bin_fn_m="$(_extract_fn check_mandatory_teams "$DOCTOR_BIN_SH")"
_doctor_bin_preamble_m="$(awk '
      $0=="_MANDATORY_TEAMS_LIB_OK=false" {capture=1}
      capture {print}
      capture && $0=="fi" {exit}
    ' "$DOCTOR_BIN_SH")"

if [ -z "$_check_result_libexec_fn_m" ] || [ -z "$_check_mand_libexec_fn_m" ] || \
   [ -z "$_check_result_bin_fn_m" ] || [ -z "$_check_mand_bin_fn_m" ] || [ -z "$_doctor_bin_preamble_m" ]; then
    test_start "SECTION M setup: extract doctor functions from both copies"
    test_fail "one or more extractions produced no output -- cannot run Section M"
else
    _m_dir="$SANDBOX/m-provisioned"
    mkdir -p "$_m_dir/kanban/widget"
    printf '{"teams":["widget"]}' > "$_m_dir/.aiteamforge-config"
    printf 'cockpit\n' > "$_m_dir/.install-profile"
    echo '{"real":"board"}' > "$_m_dir/kanban/widget/widget-board.json"
    _tp_m="$SANDBOX/team-paths-m.json"
    cat > "$_tp_m" <<EOF
{"schema_version": 1, "teams": {"widget": {"kanban_dir": "$_m_dir/kanban/widget", "working_dir": "$_m_dir"}}}
EOF
    _reg_m="$(_x1070_mk_reg_sandbox doctor-m "$REG_ONE_TRUE" true)"

    _block_start "M1 (libexec copy): check_mandatory_teams -- mandatory team IS provisioned on a cockpit-profiled box -> clean PASS"
    _out_m1="$(
        unset AITEAMFORGE_HOME
        AITEAMFORGE_DIR="$_m_dir"; AITEAMFORGE_CONFIG="$_tp_m"
        # shellcheck disable=SC1091
        . "$COMMON_SH"
        # shellcheck disable=SC1091
        . "$_reg_m/libexec/lib/mandatory-teams.sh"
        eval "$_check_result_libexec_fn_m"
        eval "$_check_mand_libexec_fn_m"
        TOTAL_CHECKS=0; PASSED_CHECKS=0; FAILED_CHECKS=0; WARNING_CHECKS=0; VERBOSE=false
        check_mandatory_teams
        echo "COUNTERS total=$TOTAL_CHECKS passed=$PASSED_CHECKS failed=$FAILED_CHECKS warn=$WARNING_CHECKS"
    )" 2>&1
    assert_contains "$_out_m1" "COUNTERS total=1 passed=1 failed=0 warn=0" "expected a clean PASS for the already-provisioned mandatory team, got: $_out_m1"
    _block_end

    _block_start "M2 (bin copy, FAITHFUL layout): check_mandatory_teams -- same provisioned cockpit box -> clean PASS"
    _out_m2="$(
        # shellcheck disable=SC1091
        . "$COMMON_SH"
        AITEAMFORGE_HOME="$_reg_m"
        eval "$_doctor_bin_preamble_m"
        eval "$_check_result_bin_fn_m"
        eval "$_check_mand_bin_fn_m"
        TOTAL_CHECKS=0; PASSED_CHECKS=0; FAILED_CHECKS=0; WARNING_CHECKS=0; VERBOSE=false
        AITEAMFORGE_DIR="$_m_dir"; AITEAMFORGE_CONFIG="$_tp_m"
        check_mandatory_teams
        echo "LIB_OK=$_MANDATORY_TEAMS_LIB_OK COUNTERS total=$TOTAL_CHECKS passed=$PASSED_CHECKS failed=$FAILED_CHECKS warn=$WARNING_CHECKS"
    )"
    assert_contains "$_out_m2" "LIB_OK=true" "expected the lib to load under the faithful AITEAMFORGE_HOME layout"
    assert_contains "$_out_m2" "passed=1 failed=0 warn=0" "expected a clean PASS for the bin copy against the same provisioned cockpit box, got: $_out_m2"
    _block_end
fi

# ─────────────────────────────────────────────────────────────────────────────
# SECTION N -- `aiteamforge upgrade` backfill on a cockpit layout.
# update_mandatory_teams() (verified: zero references to INSTALL_PROFILE or
# "cockpit" anywhere in its body) is profile-agnostic BY DESIGN -- it always
# calls install-team.sh for an absent mandatory team regardless of what
# .install-profile says. Section E already exhaustively tests the function
# itself; this section explicitly names the cockpit-layout scenario the
# round-2 test brief calls out, rather than leaving it as an inference from
# Section E's profile-nonspecific fixtures.
# ─────────────────────────────────────────────────────────────────────────────
_has_board_fn_n="$(_extract_fn _xaca1070_mandatory_team_has_board "$UPGRADE_SH")"
_update_mandatory_fn_n="$(_extract_fn update_mandatory_teams "$UPGRADE_SH")"
_add_to_config_fn_n="$(_extract_fn _xaca1070_add_team_to_config "$UPGRADE_SH")"
# BLOCKING A (second symptom): update_mandatory_teams() now also calls
# _xaca1070_add_team_working_dir_to_config -- extract it too, or this
# section's eval'd copy of update_mandatory_teams calls an undefined
# function (caught by its own `|| true`, so non-fatal, but it pollutes
# $_n_out with a spurious "command not found" and leaves .team_paths
# unbackfilled where N3 below expects it).
_add_wd_to_config_fn_n="$(_extract_fn _xaca1070_add_team_working_dir_to_config "$UPGRADE_SH")"

if [ -z "$_has_board_fn_n" ] || [ -z "$_update_mandatory_fn_n" ] || [ -z "$_add_to_config_fn_n" ] || [ -z "$_add_wd_to_config_fn_n" ]; then
    test_start "SECTION N setup: extract upgrade.sh backfill functions"
    test_fail "one or more extractions produced no output -- cannot run Section N"
else
    _block_start "N1: STRUCTURAL -- update_mandatory_teams() never references INSTALL_PROFILE or 'cockpit' (profile-agnostic by design, matches the round-2 brief: 'already correct under this direction (no profile gate)')"
    assert_not_contains "$_update_mandatory_fn_n" "INSTALL_PROFILE" "update_mandatory_teams must not gate on INSTALL_PROFILE"
    assert_not_contains "$_update_mandatory_fn_n" "cockpit" "update_mandatory_teams must not special-case cockpit by name"
    _block_end

    _n_libexec_dir="$SANDBOX/n-fake-libexec"
    mkdir -p "$_n_libexec_dir/installers"
    _n_sentinel="$SANDBOX/n-sentinel.log"
    cat > "$_n_libexec_dir/installers/install-team.sh" <<EOF
#!/bin/bash
team_id="\$1"
echo "FAKE INSTALLER CALLED for \$team_id" >> "$_n_sentinel"
kdir="\$AITEAMFORGE_DIR/kanban/\$team_id"
mkdir -p "\$kdir"
echo '{"seed":"fresh"}' > "\$kdir/\${team_id}-board.json"
exit 0
EOF
    chmod +x "$_n_libexec_dir/installers/install-team.sh"

    # A cockpit-layout work dir: .install-profile = cockpit, matching what
    # bin/aiteamforge-setup.sh's cockpit path actually writes (Step 4, WRITE
    # CONFIGURATION FILE section, unconditional install_profile marker).
    _n_work="$SANDBOX/n-cockpit-work"
    mkdir -p "$_n_work"
    printf 'cockpit\n' > "$_n_work/.install-profile"
    _n_kdir="$_n_work/kanban/widget"
    _n_tp="$SANDBOX/n-team-paths.json"
    cat > "$_n_tp" <<EOF
{"schema_version": 1, "teams": {"widget": {"kanban_dir": "$_n_kdir", "working_dir": "$_n_work/widget"}}}
EOF
    _n_reg="$(_x1070_mk_reg_sandbox section-n "$REG_ONE_TRUE" true)"

    _block_start "N2: update_mandatory_teams -- backfills the mandatory team on a cockpit-layout work dir exactly as it would on any other layout"
    _n_out="$(
        unset AITEAMFORGE_HOME
        # shellcheck disable=SC1091
        . "$_n_reg/libexec/lib/mandatory-teams.sh"
        # shellcheck disable=SC1091
        . "$COMMON_SH"
        # shellcheck disable=SC1091
        . "$PATHS_SH"
        # shellcheck disable=SC1091
        . "$CONFIG_SH"
        eval "$_has_board_fn_n"
        eval "$_add_to_config_fn_n"
        eval "$_add_wd_to_config_fn_n"
        eval "$_update_mandatory_fn_n"
        LIBEXEC_DIR="$_n_libexec_dir"
        AITEAMFORGE_DIR="$_n_work"
        AITEAMFORGE_CONFIG="$_n_tp"
        DRY_RUN=false
        WORKING_DIR="$_n_work"
        update_mandatory_teams
    )"
    assert_file_exists "$_n_sentinel" "expected the (fake) installer to be invoked for the absent mandatory team on a cockpit-layout box"
    assert_file_exists "$_n_kdir/widget-board.json" "expected a board to now exist on disk for 'widget' on the cockpit-layout box"
    assert_contains "$_n_out" "Provisioned mandatory team 'widget'" "expected a provisioning success message"
    _block_end
fi

# ═══════════════════════════════════════════════════════════════════════════
# SECTION O -- XACA-1070-021: a mandatory team dropped at the Client-ID
# prompt must not end up provisioned with missing metadata (PR #865 round 3).
#
# THE BUG (pre-fix): bin/aiteamforge-setup.sh's Client-ID-prompt loop drops
# a team from SELECTED_TEAMS on an empty Client ID via
# `SELECTED_TEAMS=("${SELECTED_TEAMS[@]/$team_id}")` -- a pattern
# SUBSTITUTION over every array element, not a filter. It turns the
# matching slot into the EMPTY STRING; it does not remove it. For an
# ordinary team every downstream consumer already guards with
# `[ -z "$team_id" ] && continue`, so that's harmless. For a MANDATORY
# team it is not: _atf_apply_mandatory_teams' call site 2 (the
# UPGRADE_HYDRATED/cockpit safety net, a no-op on the interactive path
# ONLY as long as the mandatory id is still literally present in
# SELECTED_TEAMS) dedup-scans for an EXACT STRING MATCH against the
# mandatory id. A blanked slot is "", not the id, so the scan finds no
# match and re-appends the id -- but this working-dir loop has already
# finished by the time call site 2 runs, so _WORKDIR_<team>/_CLIENT_<team>/
# _PROJECT_<team> are never set for that second, metadata-less append.
#
# THE FIX (this section proves it): a mandatory team's Client-ID prompt
# refuses to drop it. An empty Client ID falls back to the same
# "default-client" the non-interactive path already uses a few lines up in
# the same branch, so the assignment loop below finishes normally, the
# team is never blanked, and call site 2 stays the true no-op its own
# header comment says it is.
# ═══════════════════════════════════════════════════════════════════════════

_extract_client_id_loop() {
    awk '
      $0=="for team_id in \"${SELECTED_TEAMS[@]}\"; do" && !started {started=1; capture=1}
      capture {print}
      capture && $0=="done" {exit}
    ' "$SETUP_SH"
}

_x1070_mk_client_teams_dir() {
    local dir="$SANDBOX/teamsdir-clientid-$1"
    mkdir -p "$dir"
    # "widget" mirrors Sections A-N's mandatory-team fixture id; requires a
    # Client ID + falls back to a ProjectID default, matching a real
    # freelance-shaped team's .conf (TEAM_REQUIRES_CLIENT_ID="true").
    cat > "$dir/widget.conf" <<'EOF'
TEAM_NAME="Widget"
TEAM_DESCRIPTION="Widget fleet team"
TEAM_CATEGORY="infrastructure"
TEAM_REQUIRES_CLIENT_ID="true"
TEAM_HAS_PROJECTS="false"
TEAM_DEFAULT_PROJECT="mobile-app"
TEAM_WORKING_DIR="$HOME/aiteamforge"
EOF
    printf '%s' "$dir"
}

_client_id_snippet="$(_extract_client_id_loop)"
if [ -z "$_client_id_snippet" ]; then
    test_start "SECTION O setup: extract setup.sh Client-ID-prompt loop"
    test_fail "extraction produced no output -- cannot run Section O"
else
    eval "_x1070_client_id_loop() { $_client_id_snippet
    }"
    # The loop body calls _sanitize_id (defined much earlier in setup.sh,
    # outside the extracted span) -- redefine the same one-liner here
    # rather than pull in unrelated lines via a second extraction.
    _sanitize_id() { printf '%s' "$1" | sed 's/[^a-zA-Z0-9._-]//g'; }

    # ── O1: MANDATORY team, blank Client ID -- must NOT be dropped, must
    # get full metadata (the regression this subitem exists to catch;
    # FAILS against pre-fix code with an empty _WORKDIR_widget and widget
    # blanked out of SELECTED_TEAMS). ──
    _block_start "O1: Client-ID loop -- a MANDATORY team with a blank Client ID is NOT dropped and gets full metadata (XACA-1070-021)"
    _reg_dir_o="$(_x1070_mk_reg_sandbox client-id-o1 "$REG_ONE_TRUE")"
    _teams_dir_o="$(_x1070_mk_client_teams_dir o1)"
    # Two empty lines on stdin below simulate the user pressing Enter at
    # both the Client ID prompt with nothing typed (the drop scenario
    # under test) and the Project ID prompt this same requires_client arm
    # also issues right after (falls back to the conf default).
    #
    # NOTE: no apostrophes in comments INSIDE the "$( ... )" block below --
    # an odd/unpaired single-quote character in a comment there can throw
    # off bash quote-balance tracking while it looks for the substitution
    # closing paren, producing a spurious "unexpected EOF while looking
    # for matching `'" parse error at the END of the file, nowhere near
    # the actual offending comment. MEASURED while writing this test: a
    # single stray apostrophe in a comment here was enough to break
    # `bash -n` on the entire file (see git history for the exact case).
    #
    # Process substitution below, NOT a pipe: piping into the function
    # would run it on the RIGHT of a pipe in its OWN subshell (bash
    # default, absent "lastpipe"), and every evaluated
    # _WORKDIR_/_CLIENT_/_PROJECT_ assignment plus every SELECTED_TEAMS
    # mutation made inside it would vanish the instant that subshell
    # exits, never reaching the assertions below. Redirecting stdin with
    # a process substitution instead runs the function in THIS shell.
    _res_o1="$(
        unset AITEAMFORGE_HOME AITEAMFORGE_DIR AITEAMFORGE_CONFIG
        # shellcheck disable=SC1091
        . "$_reg_dir_o/libexec/lib/mandatory-teams.sh"
        GREEN=""; RED=""; YELLOW=""; CYAN=""; NC=""
        TEAMS_DIR="$_teams_dir_o"
        INSTALL_DIR="$HOME/aiteamforge"
        MODE="interactive"
        SELECTED_TEAMS=("widget")
        _x1070_client_id_loop < <(printf '\n\n')
        printf 'SELECTED=%s\n' "${SELECTED_TEAMS[*]}"
        printf 'WORKDIR=%s\n' "${_WORKDIR_widget:-}"
        printf 'CLIENT=%s\n' "${_CLIENT_widget:-}"
        printf 'PROJECT=%s\n' "${_PROJECT_widget:-}"
    )"
    assert_contains "$_res_o1" "cannot be skipped by leaving Client ID blank" "expected the mandatory-team refusal message, got: $_res_o1"
    # Exact-match the SELECTED= line (value + trailing newline from the
    # printf above): a surviving blank sibling slot would join as
    # "widget " or " widget" (IFS-space-joined array), which this exact
    # substring would NOT match -- catches both "still blanked" and
    # "duplicated" in one assertion.
    assert_contains "$_res_o1" $'SELECTED=widget\n' "SELECTED_TEAMS must contain EXACTLY 'widget' (no blank or duplicate sibling slot), got: $_res_o1"
    assert_contains "$_res_o1" "CLIENT=default-client" "expected the default-client fallback to have been applied, got: $_res_o1"
    # Same exact-match technique: an EMPTY _WORKDIR_widget prints as
    # "WORKDIR=" immediately followed by newline -- this is precisely the
    # metadata the pre-fix bug leaves unset.
    assert_not_contains "$_res_o1" $'WORKDIR=\n' "_WORKDIR_widget must be non-empty, got: $_res_o1"
    assert_contains "$_res_o1" "PROJECT=mobile-app" "expected the conf's default project id to have been applied, got: $_res_o1"
    _block_end

    # ── O2 (negative control): a NON-mandatory team with a blank Client ID
    # keeps the pre-existing drop behavior -- this fix must not make every
    # team un-droppable, only mandatory ones. ──
    _block_start "O2 (negative control): Client-ID loop -- a NON-mandatory team with a blank Client ID is still dropped as before"
    _teams_dir_o2="$(_x1070_mk_client_teams_dir o2)"
    # 'alpha' carries no mandatory flag in REG_ONE_TRUE (only 'widget' does).
    cat > "$_teams_dir_o2/alpha.conf" <<'EOF'
TEAM_NAME="Alpha"
TEAM_DESCRIPTION="Alpha team"
TEAM_CATEGORY="platform"
TEAM_REQUIRES_CLIENT_ID="true"
TEAM_HAS_PROJECTS="false"
TEAM_DEFAULT_PROJECT="mobile-app"
TEAM_WORKING_DIR="$HOME/aiteamforge"
EOF
    _res_o2="$(
        unset AITEAMFORGE_HOME AITEAMFORGE_DIR AITEAMFORGE_CONFIG
        # shellcheck disable=SC1091
        . "$_reg_dir_o/libexec/lib/mandatory-teams.sh"
        GREEN=""; RED=""; YELLOW=""; CYAN=""; NC=""
        TEAMS_DIR="$_teams_dir_o2"
        INSTALL_DIR="$HOME/aiteamforge"
        MODE="interactive"
        SELECTED_TEAMS=("alpha")
        _x1070_client_id_loop < <(printf '\n')
        printf 'SELECTED=[%s]\n' "${SELECTED_TEAMS[*]}"
    )"
    assert_contains "$_res_o2" "Client ID is required. Skipping alpha." "expected the ordinary (non-mandatory) drop message, got: $_res_o2"
    assert_not_contains "$_res_o2" "cannot be skipped" "a non-mandatory team must never see the mandatory-team refusal wording, got: $_res_o2"
    assert_contains "$_res_o2" "SELECTED=[]" "a dropped non-mandatory team's slot is blanked (existing, pre-fix-unchanged behavior), got: $_res_o2"
    _block_end
fi

# ═══════════════════════════════════════════════════════════════════════════
# SECTION P -- XACA-1070-022: atf_mandatory_teams' jq and python3 branches
# must agree on a registry with 2+ mandatory teams carrying `"order": null`,
# and the malformed-entry ("mandatory": true, no usable "id") diagnostic
# must appear on BOTH branches, not just jq's (PR #865 round 3).
#
# THE BUG (pre-fix): the python3 fallback's sort key was
# `t.get('order', 0)`, which only substitutes the default when the "order"
# KEY IS ABSENT. A present-but-null "order" returns `None` unchanged, and
# `list.sort()` compares keys pairwise even when they turn out equal --
# Python 3's `None` has no `__lt__`, so comparing `None < None` (two
# mandatory teams that both have `"order": null`) raises `TypeError` on
# its own. That was swallowed by the branch's blanket
# `except Exception: sys.exit(2)`, so rc=2 failed the `rc -eq 0` check and
# the registry was reported as "not valid JSON" -- a false fault on a
# registry the jq branch reads fine (jq's `.order // 0` already treats
# null as 0). Separately, the jq branch's "N entries with no usable id"
# diagnostic had no python3 equivalent at all.
#
# WHY A GENUINELY JQ-FREE PATH: this dev machine has jq at /usr/bin/jq
# AND /opt/homebrew/bin/jq -- both of those same directories also carry
# essential coreutils (grep, sed, mktemp, cut, rm) the python3 branch and
# this test's own harness need. Simply removing "the directory jq lives
# in" from PATH would ALSO remove those coreutils. Instead, a private
# bin dir is populated with symlinks to exactly the commands needed,
# resolved via `command -v` BEFORE PATH is restricted, and PATH is then
# set to ONLY that directory for the call under test -- proven jq-free
# by asserting `command -v jq` fails from INSIDE that restricted PATH,
# not by inference from what was left out.
# ═══════════════════════════════════════════════════════════════════════════

_x1070_mk_jqfree_bin() {
    local dir="$SANDBOX/jqfree-bin" cmd real
    mkdir -p "$dir"
    for cmd in bash sh python3 mktemp grep cut rm sed cat dirname basename mkdir env tail wc head; do
        real="$(command -v "$cmd" 2>/dev/null || true)"
        case "$real" in
            /*) [ -e "$dir/$cmd" ] || ln -sf "$real" "$dir/$cmd" ;;
        esac
    done
    printf '%s' "$dir"
}

REG_TWO_NULL_ORDER='{"version":"1.0.0","teams":[{"id":"widget","name":"Widget","order":null,"mandatory":true},{"id":"gizmo","name":"Gizmo","order":null,"mandatory":true},{"id":"alpha","name":"Alpha","order":2}]}'
REG_NULL_ORDER_PLUS_BAD_ID='{"version":"1.0.0","teams":[{"id":"widget","order":null,"mandatory":true},{"order":null,"mandatory":true},{"id":"alpha","order":1}]}'

_jqfree_bin="$(_x1070_mk_jqfree_bin)"

# ── P0 (proof, not a finding): the restricted PATH built above is
# genuinely jq-free -- if this ever stops being true, P1/P2 below would
# silently start exercising the jq branch instead of the python3 one. ──
_block_start "P0: proof -- the jqfree-bin PATH constructed for this section truly cannot find jq"
_p0_res="$(PATH="$_jqfree_bin" command -v jq >/dev/null 2>&1 && echo "FOUND" || echo "unreachable")"
assert_eq "$_p0_res" "unreachable" "command -v jq must fail from inside the restricted PATH, got: $_p0_res"
_block_end

# ── P1: 2+ mandatory teams, both "order": null -- python3 fallback (under
# the proven jq-free PATH) must return exit 0 with BOTH ids, in the SAME
# order the jq branch (run here under the normal, jq-present PATH)
# returns them. FAILS against pre-fix code: pre-fix python3 exits 2 /
# empty stdout while jq exits 0 / "widget\ngizmo". ──
_block_start "P1: atf_mandatory_teams -- 2 mandatory teams with order:null -- python3 fallback matches jq (XACA-1070-022)"
_reg_dir_p1="$(_x1070_mk_reg_sandbox order-null-p1 "$REG_TWO_NULL_ORDER")"
_err_jq_p1="$SANDBOX/p1-jq.err"
_out_jq_p1="$(_x1070_run_resolver "$_reg_dir_p1" atf_mandatory_teams 2>"$_err_jq_p1")"; _rc_jq_p1=$?
_err_py_p1="$SANDBOX/p1-py.err"
# NOTE: the "2>" below binds to the inner "{ ... }" group, not to the
# outer var=$(...) assignment. "var=$(cmd) 2>file" does NOT reliably
# redirect cmd's stderr into file -- the command substitution is expanded
# as part of computing the assignment value, and MEASURED here (while
# writing this test) to still write to the real stderr, bypassing the
# outer redirect entirely, silently emptying the diagnostic this
# assertion depends on. Wrapping the body in its own group and redirecting
# that closes the gap.
_out_py_p1="$(
    {
        PATH="$_jqfree_bin"
        export PATH
        unset AITEAMFORGE_HOME AITEAMFORGE_DIR AITEAMFORGE_CONFIG
        # shellcheck disable=SC1091
        . "$_reg_dir_p1/libexec/lib/mandatory-teams.sh"
        atf_mandatory_teams
    } 2>"$_err_py_p1"
)"; _rc_py_p1=$?
assert_eq "$_rc_jq_p1" "0" "sanity: jq branch expected exit 0, got $_rc_jq_p1 (stderr: $(cat "$_err_jq_p1"))"
assert_eq "$_rc_py_p1" "0" "python3 fallback expected exit 0 (pre-fix this was 2 -- a TypeError from sorting two None order keys, caught and misreported as 'not valid JSON'), got $_rc_py_p1 (stderr: $(cat "$_err_py_p1"))"
assert_eq "$_out_jq_p1" "$(printf 'widget\ngizmo')" "sanity: jq branch expected widget-then-gizmo (registry order, both tie at order 0), got: $_out_jq_p1"
assert_eq "$_out_py_p1" "$_out_jq_p1" "python3 fallback must produce the IDENTICAL id list (same ids, same order) as the jq branch on this registry, got: $_out_py_p1"
assert_empty "$(cat "$_err_py_p1")" "no malformed entries in this fixture -- python3 fallback must NOT emit a bad-id diagnostic here, got: $(cat "$_err_py_p1")"
_block_end

# ── P2: as P1, plus one id-less "mandatory": true entry -- BOTH branches
# must (a) still return the one valid id and (b) print the SAME
# malformed-entry diagnostic wording. FAILS against pre-fix code: pre-fix
# python3 has no equivalent diagnostic at all (silently drops the bad
# entry with no trace), and separately still trips the order:null
# TypeError this fixture also carries. ──
_block_start "P2: atf_mandatory_teams -- order:null + one id-less mandatory entry -- malformed-entry diagnostic on BOTH branches (XACA-1070-022)"
_reg_dir_p2="$(_x1070_mk_reg_sandbox order-null-p2 "$REG_NULL_ORDER_PLUS_BAD_ID")"
_err_jq_p2="$SANDBOX/p2-jq.err"
_out_jq_p2="$(_x1070_run_resolver "$_reg_dir_p2" atf_mandatory_teams 2>"$_err_jq_p2")"; _rc_jq_p2=$?
_err_py_p2="$SANDBOX/p2-py.err"
# Same "{ ... } 2>file" grouping as P1 above, and for the same reason:
# redirecting the outer var=$(...) assignment does not reliably capture
# this call's stderr.
_out_py_p2="$(
    {
        PATH="$_jqfree_bin"
        export PATH
        unset AITEAMFORGE_HOME AITEAMFORGE_DIR AITEAMFORGE_CONFIG
        # shellcheck disable=SC1091
        . "$_reg_dir_p2/libexec/lib/mandatory-teams.sh"
        atf_mandatory_teams
    } 2>"$_err_py_p2"
)"; _rc_py_p2=$?
assert_eq "$_rc_jq_p2" "0" "sanity: jq branch expected exit 0 (malformed sibling is skipped, not fatal), got $_rc_jq_p2"
assert_eq "$_rc_py_p2" "0" "python3 fallback expected exit 0, got $_rc_py_p2 (stderr: $(cat "$_err_py_p2"))"
assert_eq "$_out_jq_p2" "widget" "sanity: jq branch expected exactly 'widget' (the id-less entry is skipped), got: $_out_jq_p2"
assert_eq "$_out_py_p2" "widget" "python3 fallback expected exactly 'widget' too, got: $_out_py_p2"
assert_contains "$(cat "$_err_jq_p2")" 'has 1 "mandatory": true entry with no usable "id"' "sanity: jq branch expected the malformed-entry diagnostic wording"
assert_contains "$(cat "$_err_py_p2")" 'has 1 "mandatory": true entry with no usable "id"' "python3 fallback expected the SAME malformed-entry diagnostic wording (pre-fix: silent, no diagnostic at all), got: $(cat "$_err_py_p2")"
_block_end

# ═══════════════════════════════════════════════════════════════════════════
# SECTION Q -- XACA-1070-025 (PR #865 round 3 review): mixed "order" TYPES
# (a string on one mandatory entry, a number on another) must not diverge
# between the jq and python3 branches the way -022's null/null case did.
#
# THE BUG (pre-fix): `t.get('order') or 0` (the -022 fix) only substitutes
# 0 for None/absent/falsy -- a present, non-falsy "order" of a DIFFERENT
# type on each of two mandatory entries reaches list.sort() with a str key
# on one and an int key on the other. Python 3 raises TypeError comparing
# str/int with no default ordering, caught by the same blanket
# `except Exception: sys.exit(2)`, and misreported as "not valid JSON" --
# the exact same failure SHAPE -022 fixed, reached through a type -022's
# fix does not cover. jq's `sort_by` does not have this problem: jq's type
# ordering places numbers before strings regardless of value (MEASURED
# directly against this repo's jq: order:"1" (string) vs order:2 (number)
# sorts the NUMBER entry first).
# ═══════════════════════════════════════════════════════════════════════════

REG_MIXED_ORDER_TYPES='{"version":"1.0.0","teams":[{"id":"gizmo","name":"Gizmo","order":"1","mandatory":true},{"id":"widget","name":"Widget","order":2,"mandatory":true},{"id":"alpha","name":"Alpha","order":9}]}'

_block_start "Q1: atf_mandatory_teams -- order:\"1\" (string) vs order:2 (number) on two mandatory entries -- python3 fallback matches jq's type-ranked ordering (XACA-1070-025)"
_reg_dir_q1="$(_x1070_mk_reg_sandbox mixed-order-q1 "$REG_MIXED_ORDER_TYPES")"
_err_jq_q1="$SANDBOX/q1-jq.err"
_out_jq_q1="$(_x1070_run_resolver "$_reg_dir_q1" atf_mandatory_teams 2>"$_err_jq_q1")"; _rc_jq_q1=$?
_err_py_q1="$SANDBOX/q1-py.err"
_out_py_q1="$(
    {
        PATH="$_jqfree_bin"
        export PATH
        unset AITEAMFORGE_HOME AITEAMFORGE_DIR AITEAMFORGE_CONFIG
        # shellcheck disable=SC1091
        . "$_reg_dir_q1/libexec/lib/mandatory-teams.sh"
        atf_mandatory_teams
    } 2>"$_err_py_q1"
)"; _rc_py_q1=$?
assert_eq "$_rc_jq_q1" "0" "sanity: jq branch expected exit 0, got $_rc_jq_q1 (stderr: $(cat "$_err_jq_q1"))"
assert_eq "$_out_jq_q1" "$(printf 'widget\ngizmo')" "sanity: jq ranks a NUMBER order before a STRING order regardless of value -- expected widget (order:2, number) then gizmo (order:\"1\", string), got: $_out_jq_q1"
assert_eq "$_rc_py_q1" "0" "python3 fallback expected exit 0 (pre-fix this was 2 -- a TypeError comparing a str order key against an int order key, misreported as 'not valid JSON'), got $_rc_py_q1 (stderr: $(cat "$_err_py_q1"))"
assert_eq "$_out_py_q1" "$_out_jq_q1" "python3 fallback must produce the IDENTICAL id list (same ids, same type-ranked order) as the jq branch on this registry, got: $_out_py_q1"
assert_empty "$(cat "$_err_py_q1")" "no malformed entries in this fixture -- python3 fallback must NOT emit a bad-id diagnostic here, got: $(cat "$_err_py_q1")"
_block_end

# ═══════════════════════════════════════════════════════════════════════════
# SECTION R -- XACA-1070-029 (PR #865 round 3 review): atf_team_has_board()
# must check for the SPECIFIC team's own board file, never any "*-board.json"
# in the directory.
#
# THE BUG (pre-fix): the glob `"$kdir"/*-board.json` returns 0 (true) the
# moment ANY file matching that pattern exists, regardless of which team it
# belongs to. Two teams sharing a kanban_dir (multiple teams under one
# working dir, or a mis-resolved kanban_dir) makes atf_team_has_board
# report "has a board" for a team that has none of its own, as long as
# SOME *-board.json sits in that directory. REPRODUCED directly below:
# with only "academy-board.json" present, atf_team_has_board for "widget"
# must be FALSE.
# ═══════════════════════════════════════════════════════════════════════════

_block_start "R1: atf_team_has_board -- another team's board in the SAME directory must NOT satisfy this team's check (XACA-1070-029)"
_r1_kdir="$SANDBOX/r1-kanban"
mkdir -p "$_r1_kdir"
: > "$_r1_kdir/academy-board.json"
_r1_reg="$(_x1070_mk_reg_sandbox board-glob-r1 "$REG_EMPTY" true)"
_r1_res="$(
    ( unset AITEAMFORGE_HOME AITEAMFORGE_DIR AITEAMFORGE_CONFIG
      # shellcheck disable=SC1091
      . "$_r1_reg/libexec/lib/mandatory-teams.sh"
      aiteamforge_team_kanban_dir() { [ -n "$1" ] && printf '%s' "$_r1_kdir"; }
      if atf_team_has_board widget; then echo "TRUE"; else echo "FALSE"; fi
    )
)"
assert_eq "$_r1_res" "FALSE" "atf_team_has_board widget must be FALSE when only academy-board.json exists in the shared directory (pre-fix: the *-board.json glob matched it and returned TRUE), got: $_r1_res"
_block_end

_block_start "R2 (negative control): atf_team_has_board -- the team's OWN board file still satisfies the check"
_r2_res="$(
    ( unset AITEAMFORGE_HOME AITEAMFORGE_DIR AITEAMFORGE_CONFIG
      # shellcheck disable=SC1091
      . "$_r1_reg/libexec/lib/mandatory-teams.sh"
      aiteamforge_team_kanban_dir() { [ -n "$1" ] && printf '%s' "$_r1_kdir"; }
      if atf_team_has_board academy; then echo "TRUE"; else echo "FALSE"; fi
    )
)"
assert_eq "$_r2_res" "TRUE" "atf_team_has_board academy must still be TRUE for its own academy-board.json -- the fix must not break the true-positive case, got: $_r2_res"
_block_end

# ═══════════════════════════════════════════════════════════════════════════
# SECTION S -- XACA-1070-030 (PR #865 round 4 review): "the feature assumes
# template_id == instance_id". A "mandatory": true registry entry whose OWN
# conf declares it parameterized (TEAM_HAS_PROJECTS / TEAM_REQUIRES_CLIENT_ID
# = "true") must be excluded from atf_mandatory_teams()'s output -- with a
# loud stderr diagnostic naming it -- rather than silently reaching
# atf_team_has_board() (or the team-paths.json lookup inside
# aiteamforge-upgrade.sh's _xaca1070_add_team_working_dir_to_config()) under
# the WRONG (template, not instance) key forever. See
# _atf_mandatory_teams_reject_parameterized()'s own header comment in
# libexec/lib/mandatory-teams.sh for the full evidence and the two options
# weighed (auto-resolve vs. reject loudly; reject was chosen).
#
# Fixture: 6 registry entries --
#   spacedock  mandatory:true, order 1, NO conf file at all (fail-OPEN on
#              "no evidence of parameterization" -- an absent conf is a
#              different, pre-existing failure this filter does not treat
#              as fatal)
#   gizmo      mandatory:true, order 2, conf present but
#              TEAM_HAS_PROJECTS="false" (explicit negative -- must survive)
#   freelance  mandatory:true, order 3, TEAM_REQUIRES_CLIENT_ID="true"
#              (rejected)
#   finance    mandatory:true, order 4, TEAM_HAS_PROJECTS="true" alone,
#              no client requirement (rejected -- proves HAS_PROJECTS alone
#              is sufficient, not just REQUIRES_CLIENT_ID)
#   legal      mandatory:true, order 5, TEAM_HAS_PROJECTS="true" (rejected,
#              second HAS_PROJECTS-alone case so S1 cannot pass by fluke on
#              a single sample)
#   alpha      NOT mandatory (negative control, unrelated to this filter)
# ═══════════════════════════════════════════════════════════════════════════

REG_S_MANDATORY_PARAM='{"version":"1.0.0","teams":[{"id":"spacedock","name":"Space Dock","order":1,"mandatory":true},{"id":"gizmo","name":"Gizmo","order":2,"mandatory":true},{"id":"freelance","name":"Freelance","order":3,"mandatory":true},{"id":"finance","name":"Finance","order":4,"mandatory":true},{"id":"legal","name":"Legal","order":5,"mandatory":true},{"id":"alpha","name":"Alpha","order":6}]}'

_x1070_mk_s_fixture() {
    local dir
    dir="$(_x1070_mk_reg_sandbox "$1" "$REG_S_MANDATORY_PARAM")"
    printf 'TEAM_HAS_PROJECTS="false"\n' > "$dir/share/teams/gizmo.conf"
    printf 'TEAM_HAS_PROJECTS="true"\nTEAM_REQUIRES_CLIENT_ID="true"\nTEAM_DEFAULT_PROJECT="default"\n' > "$dir/share/teams/freelance.conf"
    printf 'TEAM_HAS_PROJECTS="true"\nTEAM_DEFAULT_PROJECT="personal"\n' > "$dir/share/teams/finance.conf"
    printf 'TEAM_HAS_PROJECTS="true"\nTEAM_DEFAULT_PROJECT="default"\n' > "$dir/share/teams/legal.conf"
    # spacedock deliberately gets NO conf file -- see S1's absent-conf assertion.
    printf '%s' "$dir"
}

# ── S1: parameterized entries excluded; unparameterized (incl. no-conf-at-all)
# entries survive, in registry 'order' ──
_block_start "S1: atf_mandatory_teams -- parameterized mandatory entries (TEAM_HAS_PROJECTS/TEAM_REQUIRES_CLIENT_ID) excluded, unparameterized survive (XACA-1070-030)"
_s1_dir="$(_x1070_mk_s_fixture s1)"
_s1_err="$SANDBOX/s1.err"
_s1_out="$(_x1070_run_resolver "$_s1_dir" atf_mandatory_teams 2>"$_s1_err")"; _s1_rc=$?
assert_eq "$_s1_rc" "0" "one bad (parameterized) entry must not fail the whole read -- expected exit 0, got $_s1_rc"
assert_eq "$_s1_out" "$(printf 'spacedock\ngizmo')" "expected exactly spacedock (no conf at all -- fail-open) then gizmo (TEAM_HAS_PROJECTS=false), in order; freelance/finance/legal must be excluded, got: [$_s1_out]"
assert_not_contains "$_s1_out" "freelance" "TEAM_REQUIRES_CLIENT_ID=true team must never reach the emitted list"
assert_not_contains "$_s1_out" "finance" "TEAM_HAS_PROJECTS=true (alone, no client requirement) must still be rejected"
assert_not_contains "$_s1_out" "legal" "a second TEAM_HAS_PROJECTS=true-alone entry must also be rejected (proves S1 is not passing on a single sample)"
_block_end

# ── S2: the rejection is LOUD -- a distinct stderr diagnostic names each
# rejected id and cites XACA-1070-030, never a silent drop ──
_block_start "S2: atf_mandatory_teams -- rejected parameterized entries each get a named stderr diagnostic (XACA-1070-030)"
_s2_dir="$(_x1070_mk_s_fixture s2)"
_s2_err="$SANDBOX/s2.err"
_x1070_run_resolver "$_s2_dir" atf_mandatory_teams >/dev/null 2>"$_s2_err"
_s2_err_body="$(cat "$_s2_err")"
assert_contains "$_s2_err_body" '"freelance" is flagged "mandatory": true' "expected a diagnostic naming freelance"
assert_contains "$_s2_err_body" '"finance" is flagged "mandatory": true' "expected a diagnostic naming finance"
assert_contains "$_s2_err_body" '"legal" is flagged "mandatory": true' "expected a diagnostic naming legal"
assert_contains "$_s2_err_body" "XACA-1070-030" "expected the diagnostic to cite XACA-1070-030"
assert_not_contains "$_s2_err_body" '"spacedock" is flagged' "spacedock (no conf, fail-open) must NOT be reported as rejected"
assert_not_contains "$_s2_err_body" '"gizmo" is flagged' "gizmo (TEAM_HAS_PROJECTS=false) must NOT be reported as rejected"
_block_end

# ── S3: atf_is_mandatory_team's membership predicate reflects the SAME
# filter -- it delegates to atf_mandatory_teams() rather than re-reading the
# registry itself, so it cannot independently disagree ──
_block_start "S3: atf_is_mandatory_team -- membership predicate reflects the parameterized-team rejection too (XACA-1070-030)"
_s3_dir="$(_x1070_mk_s_fixture s3)"
( _x1070_run_resolver "$_s3_dir" atf_is_mandatory_team spacedock ) 2>/dev/null; assert_eq "$?" "0" "spacedock (survives the filter) must be a mandatory-team member"
( _x1070_run_resolver "$_s3_dir" atf_is_mandatory_team gizmo ) 2>/dev/null; assert_eq "$?" "0" "gizmo (survives the filter) must be a mandatory-team member"
( _x1070_run_resolver "$_s3_dir" atf_is_mandatory_team freelance ) 2>/dev/null; assert_eq "$?" "1" "freelance is flagged mandatory:true in the registry but REJECTED by the filter -- membership must be 1 (not mandatory), never independently re-derived as 0"
( _x1070_run_resolver "$_s3_dir" atf_is_mandatory_team finance ) 2>/dev/null; assert_eq "$?" "1" "finance must likewise read as not-mandatory once rejected"
_block_end

# ── S4: jq and python3 branches AGREE on the parameterized-rejection filter
# (same technique as Section P) -- the filter is ONE shared shell function
# applied identically after either parser produces its raw candidate list,
# so this is really a proof that the shared-function wiring is correct in
# BOTH call sites, not a second independent implementation to keep in sync ──
_block_start "S4: atf_mandatory_teams -- jq and python3 branches agree on the parameterized-rejection filter (XACA-1070-030)"
_s4_dir="$(_x1070_mk_s_fixture s4)"
_s4_err_jq="$SANDBOX/s4-jq.err"
_s4_out_jq="$(_x1070_run_resolver "$_s4_dir" atf_mandatory_teams 2>"$_s4_err_jq")"; _s4_rc_jq=$?
_s4_err_py="$SANDBOX/s4-py.err"
_s4_out_py="$(
    {
        PATH="$_jqfree_bin"
        export PATH
        unset AITEAMFORGE_HOME AITEAMFORGE_DIR AITEAMFORGE_CONFIG
        # shellcheck disable=SC1091
        . "$_s4_dir/libexec/lib/mandatory-teams.sh"
        atf_mandatory_teams
    } 2>"$_s4_err_py"
)"; _s4_rc_py=$?
assert_eq "$_s4_rc_jq" "0" "sanity: jq branch expected exit 0, got $_s4_rc_jq"
assert_eq "$_s4_rc_py" "0" "python3 fallback expected exit 0, got $_s4_rc_py (stderr: $(cat "$_s4_err_py"))"
assert_eq "$_s4_out_jq" "$(printf 'spacedock\ngizmo')" "sanity: jq branch expected spacedock,gizmo"
assert_eq "$_s4_out_py" "$_s4_out_jq" "python3 fallback must produce the IDENTICAL filtered id list as the jq branch, got: $_s4_out_py"
assert_contains "$(cat "$_s4_err_py")" "XACA-1070-030" "python3 fallback path must ALSO surface the rejection diagnostic (proves the shared filter runs on both branches, not just jq's)"
_block_end

# ═══════════════════════════════════════════════════════════════════════════
# SECTION T -- XACA-1070-031: install-team.sh's ATF_ENV_TEAM_WORKING_DIR
# override (captured from the caller-supplied TEAM_WORKING_DIR env var
# BEFORE _read_conf's eval clobbers it, applied only for UNPARAMETERIZED
# teams -- see install-team.sh's own header comment on that block) shipped
# with ZERO test coverage: every existing install-team.sh test in this repo
# uses a STUB installer, and nothing referenced the variable. Runs the REAL
# install-team.sh end-to-end against the "academy" team (real conf, real
# persona templates, TEAM_HAS_PROJECTS=false -- confirmed by
# `grep TEAM_HAS_PROJECTS share/teams/academy.conf`) in a fully sandboxed
# HOME/AITEAMFORGE_DIR, mirroring test-xaca-0498-twd-guard.sh's own
# real-install-team.sh technique (Branch C: no dev-source sentinel, a
# minimal organization.yaml so the org check passes non-interactively).
#
# OBSERABLE SIDE EFFECT USED AS THE ASSERTION: install-team.sh copies
# academy's persona templates into "$TEAM_WORKING_DIR/personas/" (confirmed
# by reading that code path) whenever the resolved working dir differs from
# AITEAMFORGE_DIR/academy and is not already a git work tree -- both true
# for a fresh sandboxed HOME. A known persona file
# (academy_emh_documentation_persona.md, confirmed present under
# share/personas/academy/agents/) landing under the EXPECTED working dir
# (and NOT under the unused one) is a reliable, real-behavior proof of which
# TEAM_WORKING_DIR actually won -- more reliable than grepping stdout, which
# has no dedicated "resolved working dir" line.
#
# BOTH PATHS MATTER, PER THE TICKET: T1 (no override) is the behaviour every
# current caller relies on and must stay behaviour-neutral; T2 (override
# given) is the new mechanism this subitem exists to cover.
# ═══════════════════════════════════════════════════════════════════════════

INSTALL_TEAM_SH="$TAP_ROOT/libexec/installers/install-team.sh"
ORG_YAML_EXAMPLE="$TAP_ROOT/share/config/organization.yaml.example"
_X1070T_MARKER="personas/agents/academy_emh_documentation_persona.md"

_x1070t_write_org_config() {
    mkdir -p "$1/.aiteamforge"
    cp "$ORG_YAML_EXAMPLE" "$1/.aiteamforge/organization.yaml"
}

# ── T0: preflight -- confirm academy really is unparameterized (this suite's
# fixture assumption), so T1/T2 exercise the ATF_ENV_TEAM_WORKING_DIR branch
# and not the parametric (XACA-0485) one ──
_block_start "T0 preflight: academy.conf is unparameterized (TEAM_HAS_PROJECTS != true) -- required for T1/T2 to exercise the ATF_ENV_TEAM_WORKING_DIR branch"
if grep -qE '^TEAM_HAS_PROJECTS="true"' "$TAP_ROOT/share/teams/academy.conf" 2>/dev/null; then
    _block_note_fail "academy.conf now declares TEAM_HAS_PROJECTS=true -- T1/T2 below need a different unparameterized fixture team"
fi
_block_end

# ── T1: NO override -- TEAM_WORKING_DIR env unset -- behaviour-neutral,
# resolves to the conf default ($HOME/academy) ──
_block_start "T1: install-team.sh -- NO ATF_ENV_TEAM_WORKING_DIR override -- resolves to the conf default (XACA-1070-031, no-override path)"
_t1_home="$SANDBOX/t1-home"
_t1_aitf="$SANDBOX/t1-aitf"
mkdir -p "$_t1_home" "$_t1_aitf"
_x1070t_write_org_config "$_t1_home"
_t1_stdout="$SANDBOX/t1-stdout.txt"
_t1_stderr="$SANDBOX/t1-stderr.txt"
_t1_rc=0
HOME="$_t1_home" AITEAMFORGE_DIR="$_t1_aitf" \
    bash "$INSTALL_TEAM_SH" academy >"$_t1_stdout" 2>"$_t1_stderr" || _t1_rc=$?
assert_eq "$_t1_rc" "0" "expected a clean install, got exit $_t1_rc (stderr: $(cat "$_t1_stderr"))"
assert_file_exists "$_t1_home/academy/$_X1070T_MARKER" "with no override, personas must land under the conf default \$HOME/academy -- got nothing there (stdout: $(cat "$_t1_stdout"))"
_block_end

# ── T2: override GIVEN -- TEAM_WORKING_DIR env pre-set -- ATF_ENV_TEAM_WORKING_DIR
# wins over the conf default, and the conf default is NEVER populated ──
_block_start "T2: install-team.sh -- ATF_ENV_TEAM_WORKING_DIR override GIVEN -- wins over the conf default (XACA-1070-031, override-given path)"
_t2_home="$SANDBOX/t2-home"
_t2_aitf="$SANDBOX/t2-aitf"
_t2_custom="$SANDBOX/t2-custom-workdir"
mkdir -p "$_t2_home" "$_t2_aitf" "$_t2_custom"
_x1070t_write_org_config "$_t2_home"
_t2_stdout="$SANDBOX/t2-stdout.txt"
_t2_stderr="$SANDBOX/t2-stderr.txt"
_t2_rc=0
HOME="$_t2_home" AITEAMFORGE_DIR="$_t2_aitf" TEAM_WORKING_DIR="$_t2_custom" \
    bash "$INSTALL_TEAM_SH" academy >"$_t2_stdout" 2>"$_t2_stderr" || _t2_rc=$?
assert_eq "$_t2_rc" "0" "expected a clean install, got exit $_t2_rc (stderr: $(cat "$_t2_stderr"))"
assert_file_exists "$_t2_custom/$_X1070T_MARKER" "the ATF_ENV_TEAM_WORKING_DIR override must win -- personas must land under the caller-supplied dir (stdout: $(cat "$_t2_stdout"))"
assert_file_not_exists "$_t2_home/academy/$_X1070T_MARKER" "with an override given, the conf default (\$HOME/academy) must NEVER be populated -- both cannot win"
_block_end

# ═══════════════════════════════════════════════════════════════════════════
# SECTION U -- prose finding closed while touching this file (PR #865 round
# 4 review, "the third iteration of the same shape"): the -025 fix's
# `t.get('order') or 0` still coalesces any Python-falsy NON-number
# ("" / {} / [] / a bare falsy string does not exist, but an EMPTY one
# does) into the numeric rank, diverging from jq's `//` operator, which
# only substitutes on `null`/`false` -- every other value, however
# Python-falsy, is truthy in jq and is kept as-is. Ordering-only
# divergence (mandatory membership itself was never affected), but a real
# and avoidable jq/python3 disagreement. Fixed to coalesce ONLY on
# None/False, matching jq's `//` for ANY value type -- not just the ones
# shown in the review.
# ═══════════════════════════════════════════════════════════════════════════

REG_U_ORDER_TYPES='{"version":"1.0.0","teams":[{"id":"e_empty","order":"","mandatory":true},{"id":"e_obj","order":{},"mandatory":true},{"id":"e_arr","order":[],"mandatory":true},{"id":"e_str","order":"z","mandatory":true},{"id":"e_num","order":1,"mandatory":true}]}'

# ── U1: jq and python3 branches agree on ordering for "" / {} / [] / a
# bare string / a number, all on the SAME registry (XACA-1070-030 prose
# finding) -- FAILS against the pre-fix `t.get('order') or 0`, which
# silently reassigns "", {} and [] to rank 0 (tying with real numeric
# order 0) instead of ranking them by jq's own type order (numbers, then
# strings, then everything else) ──
_block_start "U1: atf_mandatory_teams -- jq/python3 order-key parity for \"\" / {} / [] / a bare string / a number (XACA-1070-030 prose finding)"
_u1_dir="$(_x1070_mk_reg_sandbox order-types-u1 "$REG_U_ORDER_TYPES")"
_u1_err_jq="$SANDBOX/u1-jq.err"
_u1_out_jq="$(_x1070_run_resolver "$_u1_dir" atf_mandatory_teams 2>"$_u1_err_jq")"; _u1_rc_jq=$?
_u1_err_py="$SANDBOX/u1-py.err"
_u1_out_py="$(
    {
        PATH="$_jqfree_bin"
        export PATH
        unset AITEAMFORGE_HOME AITEAMFORGE_DIR AITEAMFORGE_CONFIG
        # shellcheck disable=SC1091
        . "$_u1_dir/libexec/lib/mandatory-teams.sh"
        atf_mandatory_teams
    } 2>"$_u1_err_py"
)"; _u1_rc_py=$?
assert_eq "$_u1_rc_jq" "0" "sanity: jq branch expected exit 0, got $_u1_rc_jq (stderr: $(cat "$_u1_err_jq"))"
assert_eq "$_u1_rc_py" "0" "python3 fallback expected exit 0, got $_u1_rc_py (stderr: $(cat "$_u1_err_py"))"
assert_eq "$_u1_out_jq" "$(printf 'e_num\ne_empty\ne_str\ne_arr\ne_obj')" "sanity: jq's own type ordering -- number first, then the string-typed entries in registry order (empty string before \"z\"), then object/array last -- got: $_u1_out_jq"
assert_eq "$_u1_out_py" "$_u1_out_jq" "python3 fallback must produce the IDENTICAL order as the jq branch -- pre-fix, \"\"/{}/[] all silently ranked as 0 and tied with e_num, diverging from jq -- got: $_u1_out_py"
_block_end

# ─────────────────────────────────────────────────────────────────────────────
# Summary (standalone only).
# ─────────────────────────────────────────────────────────────────────────────
if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "Results: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    [ "$_FAIL_COUNT" -gt 0 ] && exit 1
fi
exit 0
