#!/bin/bash
# test-xaca-1161-004-read-path-convergence.sh
#
# Pins the shell read-path convergence: libexec/lib/aiteamforge-paths.sh must
# resolve registry fields in the SAME order, with the SAME per-field absence
# sentinels, as kanban-hooks/aiteamforge_registry.py.
#
#     OVERLAY -> DEFAULT_TEAMS -> DERIVED -> ABSENT
#
# Every case below is a behaviour that was WRONG or UNEXPRESSIBLE before
# XACA-1161-004, or a contract that must not move. In particular:
#
#   * `aiteamforge_team_kanban_dir mainevent` used to exit 0 and print the
#     literal string "null" as the path. Consumers guard with
#     `[ -n "$_result" ]` (share/scripts/lcars-tmp-dir.sh does), so a phantom
#     relative directory named `null` sailed through. Case 1 pins the fix.
#   * The absence rule was one global truthiness+"null" test, which cannot
#     express `primary_host: ""` (a DECLARED "unowned", XACA-0802-004) or
#     `board_less: false` (DATA, not absence — knowledge S002). Cases 4-6.
#   * A DECLARED-absent value at the overlay tier used to fall through to the
#     baked-in seed. For every field except team_code/alias_of that is wrong:
#     "this team has no kanban dir" is an answer, not a gap (XACA-0727).
#     Cases 7-8 pin both sides of that split.
#
# Standalone:  /bin/bash homebrew-tap/tests/test-xaca-1161-004-read-path-convergence.sh
# Via runner:  /bin/bash homebrew-tap/tests/test-runner.sh test-xaca-1161-004-read-path-convergence.sh
#
# RUN IT UNDER /bin/bash. Consumers have bash 3.2.57; the PATH bash on a dev
# Mac is 5.x and the two do not always agree.

# ─────────────────────────────────────────────────────────────────────────────
# Bootstrap: provide TEST_TMP_DIR and helpers when running standalone.
# ─────────────────────────────────────────────────────────────────────────────
_STANDALONE=false
if [ -z "${TEST_TMP_DIR:-}" ]; then
    _STANDALONE=true
    TEST_TMP_DIR=$(mktemp -d -t aiteamforge-xaca1161-test.XXXXXX)
    trap 'rm -rf "$TEST_TMP_DIR"' EXIT INT TERM

    _PASS_COUNT=0
    _FAIL_COUNT=0

    test_start() { _CURRENT_TEST="$1"; }
    test_pass() {
        _PASS_COUNT=$(( _PASS_COUNT + 1 ))
        printf "PASS: %s\n" "$_CURRENT_TEST"
    }
    test_fail() {
        _FAIL_COUNT=$(( _FAIL_COUNT + 1 ))
        printf "FAIL: %s — %s\n" "$_CURRENT_TEST" "$1" >&2
    }
fi

# ─────────────────────────────────────────────────────────────────────────────
# assert_equal is defined for BOTH modes, deliberately — it is NOT bootstrap.
#
# test-runner.sh ships its own assert_equal(), and under the runner that one
# would win. It takes (expected, actual) — the REVERSE of this file's
# (got, expected) convention — and on success it merely `return 0`: it never
# calls test_pass(). A suite that relies on it therefore reports
#   Total Tests: 27 / Passed: 0 / Failed: 0 / "All tests passed!"
# MEASURED 2026-09-11 (XACA-1161-009): that is exactly what this suite printed
# via the runner, and the pre-existing test-xaca-0463-allocator.sh prints the
# same shape. It is under-tallying, not fail-open — verified by mutation in a
# scratch copy: flipping ONE expectation produced "Failed: 1" and exit 1, so
# real failures were always detected. But "passed 0 of 27" rendering as green
# is precisely the reassuring-but-wrong output this ticket exists to eliminate,
# and a reader cannot tell it from a suite whose 27 assertions all no-op'd.
# Defining it here makes the tally honest in both modes and pins the argument
# order, so a failure message no longer prints expected and got swapped.
# ─────────────────────────────────────────────────────────────────────────────
assert_equal() {
    local got="$1" expected="$2"
    if [ "$got" = "$expected" ]; then test_pass
    else test_fail "expected '${expected}', got '${got}'"; fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PATHS_LIB="$TAP_ROOT/libexec/lib/aiteamforge-paths.sh"

# NEVER let this suite read or write the real registry.
export AITEAMFORGE_DIR="$TEST_TMP_DIR/aiteamforge"
mkdir -p "$AITEAMFORGE_DIR"
export AITEAMFORGE_CONFIG="$AITEAMFORGE_DIR/team-paths.json"
# Read-only by construction: never opt into the bootstrap write (XACA-0804).
unset AITEAMFORGE_ALLOW_BOOTSTRAP_WRITE

# shellcheck source=/dev/null
. "$PATHS_LIB"

_ASSERTIONS=0
bump() { _ASSERTIONS=$(( _ASSERTIONS + 1 )); }

# ─────────────────────────────────────────────────────────────────────────────
# Fixture — one overlay exercising every sentinel class and both chain rules.
#
# `x_seedless_*` ids are deliberately absent from _AITEAMFORGE_DEFAULT_TEAMS_DATA
# so tier 2 cannot mask a tier-1 mistake. `mainevent` and `academy` ARE in the
# seed, which is what makes the stop-chain cases meaningful.
# ─────────────────────────────────────────────────────────────────────────────
cat > "$AITEAMFORGE_CONFIG" <<'JSON'
{
  "schema_version": 2,
  "teams": {
    "academy": {
      "kanban_dir": "/tmp/xaca1161/academy/kanban",
      "working_dir": "/tmp/xaca1161/academy",
      "lcars_port": 8234,
      "lcars_port_base": 8230,
      "lcars_port_range": 10,
      "team_code": "ACA"
    },
    "mainevent": {
      "kanban_dir": null,
      "lcars_port": 8400,
      "team_code": "MEV",
      "board_less": true,
      "alias_of": "command"
    },
    "x_unowned": {
      "kanban_dir": "/tmp/xaca1161/unowned/kanban",
      "working_dir": "/tmp/xaca1161/unowned",
      "lcars_port": 8901,
      "team_code": "UNO",
      "primary_host": "",
      "board_less": false
    },
    "x_seedless_derive": {
      "kanban_dir": "/tmp/xaca1161/derive/kanban",
      "lcars_port": 8902,
      "team_code": "DRV"
    },
    "x_seedless_nullport": {
      "kanban_dir": "/tmp/xaca1161/np/kanban",
      "working_dir": "/tmp/xaca1161/np",
      "lcars_port": null,
      "team_code": "NPT"
    },
    "x_seedless_lowercode": {
      "kanban_dir": "/tmp/xaca1161/lc/kanban",
      "working_dir": "/tmp/xaca1161/lc",
      "lcars_port": 8903,
      "team_code": "lwr"
    },
    "x_seedless_strnull": {
      "kanban_dir": "null",
      "working_dir": "null",
      "lcars_port": "null",
      "team_code": "NUL"
    },
    "x_seedless_emptybool": {
      "kanban_dir": "/tmp/xaca1161/eb/kanban",
      "working_dir": "/tmp/xaca1161/eb",
      "lcars_port": 8904,
      "team_code": "EMB",
      "board_less": ""
    },
    "finance-personal": {
      "kanban_dir": "/tmp/xaca1161/fin/kanban",
      "working_dir": "/tmp/xaca1161/fin",
      "team_code": "FIN"
    },
    "medical-general": {
      "kanban_dir": "/tmp/xaca1161/med/kanban",
      "working_dir": "/tmp/xaca1161/med",
      "lcars_port": null,
      "team_code": "MED"
    }
  }
}
JSON

# ═══════════════════════════════════════════════════════════════════════════
# Case 1 — the phantom path. A board-less alias must FAIL, not hand back "null".
# ═══════════════════════════════════════════════════════════════════════════
test_start "XACA-1161-004: board-less alias yields no kanban_dir on stdout (was the literal string 'null')"
out=$(aiteamforge_team_kanban_dir "mainevent" 2>/dev/null); rc=$?
assert_equal "rc=${rc} out=[${out}]" "rc=1 out=[]"
bump

# ═══════════════════════════════════════════════════════════════════════════
# Case 2 — unknown team vs registered-but-absent are DIFFERENT exit codes.
# rc 2 is this shell's UnknownTeamError; rc 1 is "registered, no value".
# ═══════════════════════════════════════════════════════════════════════════
test_start "XACA-1161-004: _aiteamforge_get_field exits 2 for an unregistered team"
_aiteamforge_get_field "x_no_such_team_anywhere" "kanban_dir" >/dev/null 2>&1; rc=$?
assert_equal "$rc" "2"
bump

test_start "XACA-1161-004: _aiteamforge_get_field exits 1 for a REGISTERED team with no value"
_aiteamforge_get_field "mainevent" "kanban_dir" >/dev/null 2>&1; rc=$?
assert_equal "$rc" "1"
bump

# ═══════════════════════════════════════════════════════════════════════════
# Cases 3-6 — the per-field sentinel vocabulary (S002).
# ═══════════════════════════════════════════════════════════════════════════
test_start "XACA-1161-004: PATHISH — an explicit JSON null lcars_port is ABSENT, not a value"
out=$(_aiteamforge_get_field "x_seedless_nullport" "lcars_port" 2>/dev/null); rc=$?
assert_equal "rc=${rc} out=[${out}]" "rc=1 out=[]"
bump

test_start "XACA-1161-004: NULLISH — primary_host '' is a DECLARED 'unowned', not absence"
out=$(_aiteamforge_get_field "x_unowned" "primary_host" 2>/dev/null); rc=$?
assert_equal "rc=${rc} out=[${out}]" "rc=0 out=[]"
bump

test_start "XACA-1161-004: KEYONLY — board_less false is DATA"
out=$(_aiteamforge_get_field "x_unowned" "board_less" 2>/dev/null); rc=$?
assert_equal "rc=${rc} out=[${out}]" "rc=0 out=[false]"
bump

test_start "XACA-1161-004: KEYONLY — board_less true is DATA"
out=$(_aiteamforge_get_field "mainevent" "board_less" 2>/dev/null); rc=$?
assert_equal "rc=${rc} out=[${out}]" "rc=0 out=[true]"
bump

# ═══════════════════════════════════════════════════════════════════════════
# Cases 7-8 — absent_stops_chain, both sides of the split.
# ═══════════════════════════════════════════════════════════════════════════
test_start "XACA-1161-004: absent_stops_chain=TRUE — an overlay-declared null does NOT fall through to the seed"
# BOTH teams below are in the baked-in seed WITH a real lcars_port, which is what
# makes this observable at all. An earlier revision of this case used a
# seedless team and was therefore vacuous: with nothing in tier 2 to fall
# through TO, stop-chain and no-stop-chain give the same answer, and a mutation
# that removed the stop entirely still passed. (Caught by the XACA-1161-004
# mutation harness, not by review.)
#   finance-personal — overlay declares NO lcars_port key  -> NOKEY -> tier 2 (8360)
#   medical-general  — overlay declares lcars_port: null   -> DECLARED_ABSENT, STOP
out_nokey=$(_aiteamforge_get_field "finance-personal" "lcars_port" 2>/dev/null); rc_nokey=$?
out_null=$(_aiteamforge_get_field "medical-general" "lcars_port" 2>/dev/null); rc_null=$?
assert_equal "nokey=${rc_nokey}:${out_nokey} declarednull=${rc_null}:${out_null}" "nokey=0:8360 declarednull=1:"
bump

test_start "XACA-1161-004: absent_stops_chain=FALSE — team_code still falls through to the seed"
# `medical-general` declares MED in the overlay; drop it to prove the seed
# fallback is what answers when the overlay declares an EMPTY code.
cp "$AITEAMFORGE_CONFIG" "$AITEAMFORGE_CONFIG.orig"
sed 's/"team_code": "MED"/"team_code": ""/' "$AITEAMFORGE_CONFIG.orig" > "$AITEAMFORGE_CONFIG"
out=$(_aiteamforge_get_field "medical-general" "team_code" 2>/dev/null); rc=$?
cp "$AITEAMFORGE_CONFIG.orig" "$AITEAMFORGE_CONFIG"
assert_equal "rc=${rc} out=[${out}]" "rc=0 out=[MED]"
bump

test_start "XACA-1161-004: PATHISH — the STRING \"null\" is a sentinel, not a value"
# Distinct from a JSON null: the positional seed table has no way to OMIT a
# column, so it spells absence in-band as the four characters n-u-l-l
# (XACA-0727). A rule that only special-cases JSON null passes every JSON-null
# test and still leaks "null" as a path from the table. Both spellings must die.
out_kd=$(_aiteamforge_get_field "x_seedless_strnull" "kanban_dir" 2>/dev/null); rc_kd=$?
out_lp=$(_aiteamforge_get_field "x_seedless_strnull" "lcars_port" 2>/dev/null); rc_lp=$?
assert_equal "kd=${rc_kd}:[${out_kd}] lp=${rc_lp}:[${out_lp}]" "kd=1:[] lp=1:[]"
bump

test_start "XACA-1161-004: KEYONLY vs PATHISH — board_less '' is DATA, where a path-ish '' would be absence"
# true/false alone cannot tell the two sentinel classes apart: both are
# non-empty and neither is "null", so PATHISH and KEYONLY agree on them. The
# empty string is the ONLY value that separates the classes, which makes this
# the case that actually pins board_less to KEYONLY.
out=$(_aiteamforge_get_field "x_seedless_emptybool" "board_less" 2>/dev/null); rc=$?
out_p=$(_aiteamforge_get_field "x_seedless_emptybool" "team_code" 2>/dev/null); rc_p=$?
assert_equal "keyonly=${rc}:[${out}] pathish=${rc_p}:[${out_p}]" "keyonly=0:[] pathish=0:[EMB]"
bump

# ═══════════════════════════════════════════════════════════════════════════
# Case 9 — tier 3 DERIVED: working_dir = kanban_dir's parent, and only when no
# tier declared it. Never an identity derivation (K659).
# ═══════════════════════════════════════════════════════════════════════════
test_start "XACA-1161-004: DERIVED — working_dir falls back to kanban_dir's parent"
out=$(_aiteamforge_get_field "x_seedless_derive" "working_dir" 2>/dev/null); rc=$?
assert_equal "rc=${rc} out=[${out}]" "rc=0 out=[/tmp/xaca1161/derive]"
bump

# NOTE (honesty, not coverage): the mutation harness shows that DELETING the
# `_ATF_TEAM_KNOWN` guard on the deriver does NOT make the case below fail, and
# that is correct rather than a gap. The deriver reads kanban_dir through
# _aiteamforge_get_field, which already returns 2 for an unregistered team, so
# derivation cannot succeed for one even with the guard gone. The guard is
# defence-in-depth against a FUTURE deriver that reads something cheaper; this
# case pins the observable contract, not the guard.
test_start "XACA-1161-004: DERIVED never invents an identity for an unregistered team"
out=$(_aiteamforge_get_field "x_no_such_team_anywhere" "working_dir" 2>/dev/null); rc=$?
assert_equal "rc=${rc} out=[${out}]" "rc=2 out=[]"
bump

# ═══════════════════════════════════════════════════════════════════════════
# Case 10 — aiteamforge_list_teams is the UNION (registered_teams()), not the
# overlay alone. `freelance` is seed-only and absent from the fixture overlay.
# ═══════════════════════════════════════════════════════════════════════════
test_start "XACA-1161-004: list_teams returns the overlay+seed UNION, not overlay keys alone"
teams=$(aiteamforge_list_teams)
has_overlay_only=$(printf '%s\n' "$teams" | grep -cx "x_seedless_derive")
has_seed_only=$(printf '%s\n' "$teams" | grep -cx "freelance")
assert_equal "overlay_only=${has_overlay_only} seed_only=${has_seed_only}" "overlay_only=1 seed_only=1"
bump

# ═══════════════════════════════════════════════════════════════════════════
# Case 11 — reverse code lookup folds case on BOTH sides and agrees with the
# forward lookup. The old jq arm folded only the needle.
# ═══════════════════════════════════════════════════════════════════════════
test_start "XACA-1161-004: team_from_code folds case on the STORED side too"
assert_equal "$(aiteamforge_team_from_code 'LWR')" "x_seedless_lowercode"
bump

test_start "XACA-1161-004: team_from_code folds case on the needle"
assert_equal "$(aiteamforge_team_from_code 'aca')" "academy"
bump

test_start "XACA-1161-004: team_from_code and team_code round-trip"
assert_equal "$(aiteamforge_team_code "$(aiteamforge_team_from_code 'MEV')")" "MEV"
bump

# ═══════════════════════════════════════════════════════════════════════════
# Case 12 — the port map agrees with the forward lookup for every team it lists
# (the XACA-0799 round-trip invariant, now structural rather than fill-loop).
# ═══════════════════════════════════════════════════════════════════════════
# XACA-1161 review finding: BOTH cases below are vacuous on an EMPTY map — the
# while-loop body never runs and `grep -c` returns 0, so a totally broken emitter
# (`return 0`) passes them. That is not hypothetical: this map genuinely returns
# empty when the overlay file is absent (fresh install, CI sandbox), which is
# precisely the state these cases exist to catch. Guard non-emptiness FIRST, so
# the subsequent assertions can only pass for the right reason.
_map_rows=$(aiteamforge_lcars_port_team_map | grep -c .)
test_start "XACA-1161-004: the port->team map is NON-EMPTY (guards the two cases below from passing vacuously)"
if [ "${_map_rows:-0}" -gt 0 ]; then
    assert_equal "map_nonempty=yes" "map_nonempty=yes"
else
    assert_equal "map_nonempty=no(rows=${_map_rows})" "map_nonempty=yes"
fi
bump

test_start "XACA-1161-004: every (port,team) the map emits round-trips through the forward lookup"
_mismatch=""
_seen=0
while IFS=$'\t' read -r _p _t; do
    [ -z "$_p" ] && continue
    _seen=$((_seen + 1))
    _fwd=$(aiteamforge_team_lcars_port "$_t" 2>/dev/null) || _fwd="<none>"
    [ "$_fwd" = "$_p" ] || _mismatch="${_mismatch} ${_t}(map=${_p},fwd=${_fwd})"
done <<EOF
$(aiteamforge_lcars_port_team_map)
EOF
# Assert we actually iterated something, so "no mismatches" cannot mean "no rows".
assert_equal "iterated=$([ "$_seen" -gt 0 ] && echo yes || echo no) mismatches=[${_mismatch}]" "iterated=yes mismatches=[]"
bump

test_start "XACA-1161-004: a DECLARED-null port keeps the team out of the map"
# Paired with the non-emptiness guard above: absent that, grep -c on an empty
# map returns 0 and this passes while proving nothing.
assert_equal "rows_gt_0=$([ "${_map_rows:-0}" -gt 0 ] && echo yes || echo no) nullport_rows=$(aiteamforge_lcars_port_team_map | grep -c 'x_seedless_nullport')" "rows_gt_0=yes nullport_rows=0"
bump

# ═══════════════════════════════════════════════════════════════════════════
# Case 13 — the 7-column positional parser contract is a SHIPPED contract on
# every consumer machine and must not move.
# ═══════════════════════════════════════════════════════════════════════════
test_start "XACA-1161-004: DEFAULT_TEAMS table is still exactly 7 tab-separated columns on every row"
_cols=$(_AITEAMFORGE_DEFAULT_TEAMS_DATA | awk -F'\t' '{print NF}' | sort -u | tr '\n' ',')
assert_equal "$_cols" "7,"
bump

test_start "XACA-1161-004: every row round-trips through the positional consumer read"
_bad=""
while IFS=$'\t' read -r _t _kd _wd _lp _lb _lr _tc; do
    [ -z "$_t" ] && continue
    # Column 4 must never be empty: an empty field collapses under IFS=$'\t'
    # read and shifts every later column left by one. "null" is the sentinel.
    [ -n "$_lp" ] || _bad="${_bad} ${_t}:empty-lcars_port"
    [ -n "$_kd" ] || _bad="${_bad} ${_t}:empty-kanban_dir"
done < <(_AITEAMFORGE_DEFAULT_TEAMS_DATA)
assert_equal "bad=[${_bad}]" "bad=[]"
bump

# ─────────────────────────────────────────────────────────────────────────────
# Cases 14-15 — MEMBERSHIP INVARIANTS, DELIBERATELY NOT A PINNED COUNT.
#
# An earlier draft of this suite was going to assert "the table has 12 rows".
# That assertion would have gone RED on 2026-09-10 for an entirely legitimate
# reason: XACA-1068 registered `spacedock`, taking the table from 12 rows to
# 13. A row count pins the CONTENTS of a registry whose whole purpose is to
# grow, so every correct team registration reads as a regression and the
# reflex fix is to bump the number — which teaches the next person that this
# guard is noise. What must not move is not the SIZE of the table but its
# SHAPE: 7 columns on every row (case 13 above), ids unique, and the emission
# order deterministic. Those hold at 12 rows, at 13, and at 40.
#
# The count is still WORTH REPORTING — it is just derived at runtime and shown
# as evidence rather than asserted against a literal.
# ─────────────────────────────────────────────────────────────────────────────
test_start "XACA-1161-004: every team id in the table is unique (no duplicate slug)"
_ids=$(_AITEAMFORGE_DEFAULT_TEAMS_DATA | awk -F'\t' 'NF>0 {print $1}')
_n_ids=$(printf '%s\n' "$_ids" | grep -c .)
_n_uniq=$(printf '%s\n' "$_ids" | sort | uniq | grep -c .)
_dupes=$(printf '%s\n' "$_ids" | sort | uniq -d | tr '\n' ',')
# A duplicate slug silently shadows a row: every tier-2 lookup stops at the
# first match, so the second row becomes unreachable data that still passes a
# column-shape check.
assert_equal "rows=$_n_ids unique=$_n_uniq dupes=[$_dupes]" "rows=$_n_ids unique=$_n_ids dupes=[]"
bump

test_start "XACA-1161-004: the table emits its ids in a deterministic order"
# "Stable" here means REPEATABLE, not a pinned list of names. Consumers do
# first-match prefix scans over this emission (aiteamforge_compute_instance_port
# step 3), so a non-deterministic order would make which team wins a coin toss
# between runs — the kind of defect that reproduces once in twenty runs.
_order1=$(_AITEAMFORGE_DEFAULT_TEAMS_DATA | awk -F'\t' 'NF>0 {print $1}' | tr '\n' '|')
_order2=$(_AITEAMFORGE_DEFAULT_TEAMS_DATA | awk -F'\t' 'NF>0 {print $1}' | tr '\n' '|')
_order3=$(_AITEAMFORGE_DEFAULT_TEAMS_DATA | awk -F'\t' 'NF>0 {print $1}' | tr '\n' '|')
assert_equal "$([ "$_order1" = "$_order2" ] && [ "$_order2" = "$_order3" ] && echo stable || echo "UNSTABLE: $_order1 vs $_order2 vs $_order3")" "stable"
bump
echo "    [evidence] runtime-derived row count = $_n_ids (reported, NOT asserted)"

# ═══════════════════════════════════════════════════════════════════════════
# Cases 14-16 — MEMOIZATION MUST NOT SERVE A STALE ANSWER.
#
# _aiteamforge_load_default_rows caches the baked-in seed rows per process,
# keyed "<field>|$HOME", because that table is a constant compiled into the
# library and validating the key costs no forks. The OVERLAY is deliberately NOT
# cached — team-paths.json is rewritten mid-process by kb-init-team,
# kb-port-reconcile and the installers, and a stale registry is exactly the
# failure class this ticket exists to remove. These cases pin both halves: the
# cache must hit when nothing changed, and a mutated overlay must be visible
# IMMEDIATELY in the same process.
# ═══════════════════════════════════════════════════════════════════════════
test_start "XACA-1161-004: a rewritten overlay is visible immediately in the same process (no stale cache)"
# CALLED WITHOUT $( ) ON PURPOSE. A command substitution forks a subshell, so a
# process-level cache set inside the accessor dies the instant the call returns
# and this test cannot observe overlay staleness AT ALL. An earlier revision did
# use $( ) and was verifiably blind: the mutation harness memoized the overlay
# tier and the suite stayed GREEN. Redirecting to a file keeps the call in THIS
# shell, so any memo the accessor sets survives across the rewrite below and a
# stale answer becomes visible. (Blind-spot found by mutation, not by review.)
aiteamforge_team_from_code "UNO" > "$TEST_TMP_DIR/uno1" 2>/dev/null
cp "$AITEAMFORGE_CONFIG" "$AITEAMFORGE_CONFIG.memo"
# Re-point UNO's code to a different code, in the SAME process.
sed 's/"team_code": "UNO"/"team_code": "ZZQ"/' "$AITEAMFORGE_CONFIG.memo" > "$AITEAMFORGE_CONFIG"
aiteamforge_team_from_code "UNO" > "$TEST_TMP_DIR/uno2" 2>/dev/null
_stale_rc=$?
aiteamforge_team_from_code "ZZQ" > "$TEST_TMP_DIR/zzq" 2>/dev/null
cp "$AITEAMFORGE_CONFIG.memo" "$AITEAMFORGE_CONFIG"
assert_equal "first=$(cat "$TEST_TMP_DIR/uno1") stale_rc=${_stale_rc} stale_out=[$(cat "$TEST_TMP_DIR/uno2")] new=[$(cat "$TEST_TMP_DIR/zzq")]" \
             "first=x_unowned stale_rc=1 stale_out=[] new=[x_unowned]"
bump

test_start "XACA-1161-004: the seed memo actually caches (same key -> same rows, no recompute drift)"
_aiteamforge_load_default_rows "team_code"
_first="$_ATF_DEF_ROWS"
_key_after_first="$_ATF_MEMO_DEF_KEY"
_ATF_DEF_ROWS="SENTINEL_SHOULD_BE_OVERWRITTEN"
_aiteamforge_load_default_rows "team_code"
assert_equal "cached=$([ "$_ATF_DEF_ROWS" = "$_first" ] && echo yes || echo no) key=$([ "$_key_after_first" = "team_code|${HOME}" ] && echo ok || echo "$_key_after_first")" "cached=yes key=ok"
bump

test_start "XACA-1161-004: the seed memo invalidates when the FIELD changes"
_aiteamforge_load_default_rows "team_code"
_codes="$_ATF_DEF_ROWS"
_aiteamforge_load_default_rows "lcars_port"
_ports="$_ATF_DEF_ROWS"
# Different columns must yield different row content; if the memo ignored the
# field it would hand back the team_code rows for lcars_port.
assert_equal "$([ "$_codes" != "$_ports" ] && echo differ || echo SAME-STALE)" "differ"
bump

# ═══════════════════════════════════════════════════════════════════════════
# Guard — a suite that silently stops asserting is indistinguishable from a
# passing one. Pin the count. (Same guard shape as test-xaca-0822.)
# ═══════════════════════════════════════════════════════════════════════════
test_start "XACA-1161-004: expected-assertion-count guard (27 cases expected)"
# NOTE: this pin is a SUITE-SIZE pin, not a registry pin. It exists because a
# suite that silently stops asserting is indistinguishable from a passing one.
# It moves only when a case is deliberately added or removed here.
assert_equal "$_ASSERTIONS" "27"

if [ "$_STANDALONE" = true ]; then
    printf "\nResults: %d passed, %d failed\n" "$_PASS_COUNT" "$_FAIL_COUNT"
    [ "$_FAIL_COUNT" -eq 0 ] || exit 1
fi
