#!/usr/bin/env bash
# test-xaca-0799-restart-symmetry.sh
# Regression test for XACA-0799 — `aiteamforge restart lcars` must bring back
# every LCARS server it tore down, not just the configured ones.
#
# Bug: the two halves of a restart had mismatched scope.
#   STOP  — stop_lcars() in libexec/commands/aiteamforge-stop.sh matches
#           `server\.py [0-9]` with NO port, deliberately (see the kill-all note
#           there, XACA-0560-001). It reaps EVERY LCARS server on the box.
#   START — start_lcars() in libexec/commands/aiteamforge-start.sh iterates only
#           get_configured_teams(), i.e. .aiteamforge-config's .teams[].
#
# On a box where most LCARS servers are launched by their own per-team
# *-startup.sh, those teams never appear in .teams[]. So a restart killed all of
# them and started only the configured handful; the rest stayed down until the
# 300s com.aiteamforge.lcars-health check healed them — a fleet-wide LCARS
# outage of up to 5 minutes on EVERY restart. Observed on M4Mini immediately
# after the v0.17.7 upgrade (2026-07-13): lcars-watch fired `aiteamforge restart
# lcars`, 8 servers were killed, only finance-personal (8361) came back;
# ios/android/firebase/academy/dns/command/legal were all DOWN.
#
# XACA-0792 fixed the OTHER half of this (start skipped project-scoped teams
# because it passed a base id to a registry keyed by instance id). That made
# `finance` come back. This ticket is the REMAINING half: the blast radius of
# stop still does not match the coverage of start.
#
# Fix (snapshot & restore): the `restart` dispatcher in bin/aiteamforge-cli.sh
# snapshots the ports actually SERVING *before* the teardown and exports them as
# AITEAMFORGE_RESTORE_LCARS_PORTS; start_lcars() maps each back to a team via the
# registry reverse lookup and unions them into its team list. `stop` keeps its
# kill-all semantics and a standalone `start` keeps its configured-teams-only
# semantics — only `restart`, the path that caused the outage, becomes symmetric.
#
# Covers:
#   Case 1 — Unit: reverse lookup resolves a port to its owning team.
#   Case 2 — Unit: a port no team owns returns nonzero AND empty (must not
#            resurrect a server under a bogus team id).
#   Case 3 — Unit: reverse lookup round-trips with the FORWARD lookup for every
#            team in the registry. This is the anti-drift property — the reverse
#            must never claim a pairing the forward lookup would not assign.
#   Case 4 — Behavioral: the running-port scan finds a live `server.py <port>`
#            process and stops reporting it once that process is gone.
#   Case 5 — Behavioral (the regression, pinned): against an M4Mini-shaped
#            fixture, the running set resolves to teams the CONFIGURED set does
#            not contain. That non-empty delta is exactly what a restart used to
#            lose; it is what the restore path now recovers.
#   Case 6 — Structural: the snapshot must happen BEFORE stop.sh is invoked.
#            Ordering is the whole fix — snapshotting after the teardown returns
#            an empty set and silently restores nothing.
#   Case 7 — Structural: start_lcars() must consume AITEAMFORGE_RESTORE_LCARS_PORTS.
#   Case 8 — Structural: the "no configured teams" early-return must sit AFTER
#            the restore union. Before it, a box with an empty .teams[] bails out
#            before restoring and the outage returns in full.
#   Case 9 — Structural (anti-regression on the OTHER side): stop's kill-all
#            matcher must stay port-less. Narrowing it would "fix" the asymmetry
#            by breaking stop-all, which XACA-0560-001 explicitly warns against.
#   Case 10 — Portability: the port scan must not rely on unquoted word
#            splitting. zsh does not split unquoted expansions, so `for pid in
#            $pids` silently yields an EMPTY port set while still exiting 0 — a
#            vacuous success that hands restart nothing to restore. (Hit for real
#            while developing this fix.)
#   Case 11 — Negative control: proves Cases 6-8 are non-vacuous by re-running
#            them against a synthesized PRE-FIX copy and requiring them to FAIL.

# No `set -e`: assert_* helpers signal failure by RETURNING 1, so -e would abort
# the run on the first failing assertion instead of reporting the full tally
# (matching test-xaca-0792 / test-xaca-0585). No `set -u` either: the shared
# runner's assert helpers declare `local a="$1" msg="...$a..."` on one line, and
# bash declares both names before assigning — so the self-referencing default
# expands an unset local and -u would abort inside the harness itself.
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMMON_LIB="$TAP_ROOT/libexec/lib/common.sh"
PATHS_LIB="$TAP_ROOT/libexec/lib/aiteamforge-paths.sh"
START_CMD="$TAP_ROOT/libexec/commands/aiteamforge-start.sh"
STOP_CMD="$TAP_ROOT/libexec/commands/aiteamforge-stop.sh"
CLI_CMD="$TAP_ROOT/bin/aiteamforge-cli.sh"

# ── Standalone framework (mirrors test-xaca-0651 / test-xaca-0585 pattern) ────
_STANDALONE=false
if ! type -t test_start >/dev/null 2>&1; then
    _STANDALONE=true
    _PASS_COUNT=0
    _FAIL_COUNT=0
    _CURRENT_TEST=""

    test_start() { _CURRENT_TEST="$1"; echo "  >> $1"; }
    test_pass()  { _PASS_COUNT=$((_PASS_COUNT + 1)); echo "     PASS: $_CURRENT_TEST"; }
    test_fail()  { _FAIL_COUNT=$((_FAIL_COUNT + 1)); echo "     FAIL: $_CURRENT_TEST — $1" >&2; }

    assert_equal() {
        local expected="$1" actual="$2"
        local msg="${3:-Expected '$expected', got '$actual'}"
        [ "$expected" = "$actual" ] || { test_fail "$msg"; return 1; }
    }
    assert_contains() {
        local haystack="$1" needle="$2"
        local msg="${3:-Expected to find: $needle}"
        case "$haystack" in *"$needle"*) return 0 ;; esac
        test_fail "$msg"; return 1
    }
    assert_not_contains() {
        local haystack="$1" needle="$2"
        local msg="${3:-Expected NOT to find: $needle}"
        case "$haystack" in *"$needle"*) test_fail "$msg"; return 1 ;; esac
        return 0
    }
    assert_empty() {
        # Two `local` statements, not one: bash declares every name in a single
        # `local` before assigning any, so a self-referencing default in the same
        # statement expands an unset variable.
        local value="$1"
        local msg="${2:-Expected empty, got '$value'}"
        [ -z "$value" ] || { test_fail "$msg"; return 1; }
    }
    assert_not_empty() {
        local value="$1"
        local msg="${2:-Expected non-empty}"
        [ -n "$value" ] || { test_fail "$msg"; return 1; }
    }
    assert_file_not_exists() {
        local file="$1"
        local msg="${2:-Expected file NOT to exist: $1}"
        [ ! -f "$file" ] || { test_fail "$msg"; return 1; }
    }
fi

if [ -z "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR=$(mktemp -d -t aiteamforge-0799.XXXXXX)
    export TEST_TMP_DIR
fi

# NOTE ON THE HARNESS: assert_* returns 0 silently on success and only records on
# FAILURE (via test_fail). A bare `assert_equal` therefore registers a START with
# no PASS, and the suite reports "all passed" on 0 passed / 0 failed — a vacuous
# green. Every assertion below MUST pair with an explicit `&& test_pass`.

export AITEAMFORGE_DIR="$TEST_TMP_DIR/aiteamforge"
mkdir -p "$AITEAMFORGE_DIR"

# shellcheck source=/dev/null
source "$COMMON_LIB"
# shellcheck source=/dev/null
source "$PATHS_LIB"
# config.sh + kanban-paths.sh supply get_board_id / get_team_instance_id, which
# aiteamforge_resolve_team_key() consults to map a BASE id ("finance") to its
# registry INSTANCE id ("finance-personal"). Without them that mapping silently
# degrades to the base id and the base-vs-instance dedupe case below would pass
# for the wrong reason — the comparison never being exercised at all.
# shellcheck source=/dev/null
source "$TAP_ROOT/libexec/lib/config.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "$TAP_ROOT/libexec/lib/kanban-paths.sh" 2>/dev/null || true

# ═══════════════════════════════════════════════════════════════════════════
# Fixture — an M4Mini-shaped install: many teams in the port registry, but only
# ONE of them listed in .aiteamforge-config's .teams[]. That gap IS the bug.
# ═══════════════════════════════════════════════════════════════════════════
export AITEAMFORGE_CONFIG="$TEST_TMP_DIR/team-paths.json"
cat > "$AITEAMFORGE_CONFIG" <<'EOF'
{
  "schema_version": 2,
  "teams": {
    "ios":               {"team_code": "IOS", "lcars_port": 8180},
    "android":           {"team_code": "AND", "lcars_port": 8203},
    "firebase":          {"team_code": "FIR", "lcars_port": 8234},
    "academy":           {"team_code": "ACA", "lcars_port": 8240},
    "dns":               {"team_code": "DNS", "lcars_port": 8260},
    "command":           {"team_code": "CMD", "lcars_port": 8280},
    "legal-coparenting": {"team_code": "LEG", "lcars_port": 8320},
    "finance-personal":  {"team_code": "FIN", "lcars_port": 8361}
  }
}
EOF

# ═══════════════════════════════════════════════════════════════════════════
# Case 1 — reverse lookup resolves a port to its owning team
# ═══════════════════════════════════════════════════════════════════════════
test_start "XACA-0799 Case 1: port 8361 → 'finance-personal'"
actual=$(aiteamforge_team_for_lcars_port 8361 2>/dev/null || true)
assert_equal "finance-personal" "$actual" && test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Case 2 — an unowned port must NOT resolve
# ═══════════════════════════════════════════════════════════════════════════
# A bogus team id here would be worse than skipping: start would try to launch a
# server for a team that has no registry entry, on a port it does not own.
test_start "XACA-0799 Case 2: unowned port 9999 returns nonzero and empty"
if unowned=$(aiteamforge_team_for_lcars_port 9999 2>/dev/null); then
    test_fail "port 9999 unexpectedly resolved to '$unowned'"
else
    assert_empty "${unowned:-}" && test_pass
fi

# ═══════════════════════════════════════════════════════════════════════════
# Case 3 — reverse round-trips with forward for EVERY registry team
# ═══════════════════════════════════════════════════════════════════════════
# The reverse lookup is implemented as a scan over the forward lookup precisely
# so this can never drift. Pin it: a future "optimisation" that reimplements the
# reverse as an independent jq query would break here first.
test_start "XACA-0799 Case 3: reverse lookup round-trips with forward lookup"
_roundtrip_ok=true
_roundtrip_msg=""
for _team in ios android firebase academy dns command legal-coparenting finance-personal; do
    _fwd=$(aiteamforge_team_lcars_port "$_team" 2>/dev/null || true)
    if [ -z "$_fwd" ]; then
        _roundtrip_ok=false
        _roundtrip_msg="forward lookup produced no port for '$_team'"
        break
    fi
    _rev=$(aiteamforge_team_for_lcars_port "$_fwd" 2>/dev/null || true)
    if [ "$_rev" != "$_team" ]; then
        _roundtrip_ok=false
        _roundtrip_msg="port $_fwd owned by '$_team' but reverse said '$_rev'"
        break
    fi
done
if [ "$_roundtrip_ok" = true ]; then
    test_pass
else
    test_fail "$_roundtrip_msg"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Case 4 — the running-port scan sees a real process, and stops seeing it
# ═══════════════════════════════════════════════════════════════════════════
# Spawns a stand-in whose argv is literally `server.py <port>` so it matches the
# same pgrep pattern stop_lcars() uses. Port 19911 is far outside every LCARS
# band so it cannot collide with a real server on the machine running the tests.
test_start "XACA-0799 Case 4: running-port scan detects a live server.py process"
_FAKE_PORT=19911
_FAKE_DIR="$TEST_TMP_DIR/fakesrv"
mkdir -p "$_FAKE_DIR"
cat > "$_FAKE_DIR/server.py" <<'PYEOF'
import sys, time
# Stand-in for an LCARS server: binds nothing, just stays alive so the process
# table carries an argv of `server.py <port>` for the scanner to find.
time.sleep(120)
PYEOF

_FAKE_PID=""
if command -v python3 >/dev/null 2>&1; then
    ( cd "$_FAKE_DIR" && exec python3 server.py "$_FAKE_PORT" ) >/dev/null 2>&1 &
    _FAKE_PID=$!
    # Give the process table a moment to reflect the exec.
    sleep 1

    _cleanup_fake() {
        if [ -n "${_FAKE_PID:-}" ] && kill -0 "$_FAKE_PID" 2>/dev/null; then
            kill "$_FAKE_PID" 2>/dev/null || true
        fi
    }
    trap _cleanup_fake EXIT

    _scan=$(aiteamforge_lcars_running_ports 2>/dev/null || true)
    assert_contains "$_scan" "$_FAKE_PORT" \
        "scan did not report the live fake server on port $_FAKE_PORT (got: $_scan)" \
        && test_pass

    # ...and it must disappear once the process is gone. This half is what
    # distinguishes a real scan from a hardcoded list.
    test_start "XACA-0799 Case 4b: scan drops the port once the process exits"
    kill "$_FAKE_PID" 2>/dev/null || true
    wait "$_FAKE_PID" 2>/dev/null || true
    sleep 1
    _scan_after=$(aiteamforge_lcars_running_ports 2>/dev/null || true)
    assert_not_contains "$_scan_after" "$_FAKE_PORT" \
        "scan still reports port $_FAKE_PORT after the process exited" \
        && test_pass
    trap - EXIT
else
    test_fail "python3 not available — cannot spawn the stand-in server process"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Case 5 — THE REGRESSION: running set contains teams the configured set does not
# ═══════════════════════════════════════════════════════════════════════════
# This is the M4Mini shape in miniature. .teams[] holds only finance; the box is
# actually serving 8 teams. Every port in that running set that maps to a team
# OUTSIDE the configured set is a server the old restart killed and never
# restored. Assert the delta is non-empty and names the right teams.
test_start "XACA-0799 Case 5: running set resolves teams absent from the configured set"
_CONFIGURED="finance-personal"
_RUNNING_PORTS="8180 8203 8234 8240 8260 8280 8320 8361"

_delta=""
while IFS= read -r _p; do
    _t=$(aiteamforge_team_for_lcars_port "$_p" 2>/dev/null || true)
    [ -z "$_t" ] && continue
    case " $_CONFIGURED " in
        *" $_t "*) : ;;                       # already configured — start covers it
        *) _delta="$_delta $_t" ;;            # would have been lost by a restart
    esac
done < <(printf '%s\n' "$_RUNNING_PORTS" | tr ' ' '\n')
_delta="${_delta# }"

assert_not_empty "$_delta" "expected teams outside the configured set, got none" \
    && assert_contains "$_delta" "academy" \
    && assert_contains "$_delta" "ios" \
    && assert_contains "$_delta" "legal-coparenting" \
    && assert_not_contains "$_delta" "finance-personal" \
    && test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Case 6 — the snapshot must be taken BEFORE the teardown
# ═══════════════════════════════════════════════════════════════════════════
# Ordering IS the fix. Snapshotting after stop.sh has run returns an empty set,
# which restores nothing while looking entirely correct in a diff.
test_start "XACA-0799 Case 6: restart snapshots running ports before invoking stop"
# XACA-0799-007: the first cut anchored on `grep -n aiteamforge-stop.sh | tail -1`
# — the LAST match anywhere in the file. Mutation-proven defeatable: moving the
# snapshot AFTER the teardown and appending a trailing comment that mentions the
# path pushed the anchor past it and the guard went green with the exact
# regression it exists to catch fully present. Anchor instead on the FIRST stop.sh
# invocation at or after the `restart)` case label, which is the one the restart
# path actually executes.
_restart_line=$(grep -n '^[[:space:]]*restart)' "$CLI_CMD" | head -1 | cut -d: -f1)
_snap_line=$(awk -v s="${_restart_line:-1}" 'NR>=s && /aiteamforge_lcars_running_ports/ {print NR; exit}' "$CLI_CMD")
_stop_line=$(awk -v s="${_restart_line:-1}" 'NR>=s && /aiteamforge-stop\.sh/ {print NR; exit}' "$CLI_CMD")
if [ -z "$_restart_line" ]; then
  _snap_line=""; _stop_line=""   # no restart case found -> fail loudly below
fi
if [ -z "$_snap_line" ] || [ -z "$_stop_line" ]; then
    test_fail "could not locate snapshot ('$_snap_line') and/or stop invocation ('$_stop_line') in $CLI_CMD"
elif [ "$_snap_line" -lt "$_stop_line" ]; then
    test_pass
else
    test_fail "snapshot at line $_snap_line does not precede stop invocation at line $_stop_line"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Case 7 — start_lcars must consume the restore set
# ═══════════════════════════════════════════════════════════════════════════
test_start "XACA-0799 Case 7: start consumes AITEAMFORGE_RESTORE_LCARS_PORTS"
# XACA-0799-013: strip comments first. Both needles appear in start.sh's own
# explanatory comments, so a start.sh carrying ONLY the comments — with every line
# of restore logic deleted — passed this case. Case 11's negative control does not
# rescue it: that control strips every line mentioning the needles, so it cannot
# distinguish code from prose either.
start_src=$(grep -vE '^[[:space:]]*#' "$START_CMD")
# The reverse lookup itself now lives inside aiteamforge_build_restore_union()
# (XACA-0799-015), so pinning that symbol HERE would fail on a legitimate move.
# Assert the real contract: start.sh consumes the variable AND delegates.
assert_contains "$start_src" "AITEAMFORGE_RESTORE_LCARS_PORTS" \
    && assert_contains "$start_src" "aiteamforge_build_restore_union" \
    && test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Case 8 — the empty-configured-teams early return must follow the union
# ═══════════════════════════════════════════════════════════════════════════
# Subtle and load-bearing: if the "no configured teams" bail-out runs first, a
# box with an empty .teams[] returns before restoring anything — the outage in
# full, with the restore code present but unreachable.
test_start "XACA-0799 Case 8: empty-teams early return sits after the restore union"
# XACA-0799-021: match on CODE lines only. The unstripped form is the same
# comment-defeatable class Case 6 was fixed for — both needles appear in
# start.sh's own prose, so a comment above the bail-out would move the anchor.
_union_line=$(grep -nE "AITEAMFORGE_RESTORE_LCARS_PORTS" "$START_CMD" | grep -vE ":[[:space:]]*#" | head -1 | cut -d: -f1)
# Anchor on the LCARS-specific wording. validate_boards() emits a near-identical
# "No configured teams found — skipping board validation" earlier in the file;
# matching that one compares against the wrong bail-out entirely.
_bail_line=$(grep -nE "No configured teams found — skipping LCARS startup" "$START_CMD" | grep -vE ":[[:space:]]*#" | head -1 | cut -d: -f1)
if [ -z "$_union_line" ] || [ -z "$_bail_line" ]; then
    test_fail "could not locate union ('$_union_line') and/or bail-out ('$_bail_line') in $START_CMD"
elif [ "$_union_line" -lt "$_bail_line" ]; then
    test_pass
else
    test_fail "bail-out at line $_bail_line precedes the restore union at line $_union_line"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Case 9 — stop's kill-all matcher must stay port-less
# ═══════════════════════════════════════════════════════════════════════════
# The tempting "fix" for this ticket is to narrow stop to the configured teams.
# That trades a restart outage for a broken stop-all, which XACA-0560-001
# explicitly warns future auditors against. Pin the kill-all matcher.
test_start "XACA-0799 Case 9: stop retains its deliberate port-less kill-all matcher"
stop_src=$(cat "$STOP_CMD")
assert_contains "$stop_src" 'pgrep -f "server\.py [0-9]"' \
    && test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Case 10 — the scan must not depend on unquoted word splitting
# ═══════════════════════════════════════════════════════════════════════════
# zsh does not word-split unquoted parameter expansions. Under `for pid in
# $pids` the loop runs ONCE over the whole multi-line PID blob, every ps lookup
# fails, and the function returns an empty set while still exiting 0 — restart
# then restores nothing and reports success. Hit for real during development.
test_start "XACA-0799 Case 10: port scan avoids the word-splitting PID loop"
# Strip comments before asserting. The fix documents the broken form by name in
# a warning comment, so a whole-file grep matches the PROSE and fails a correct
# implementation. Assert against executable lines only.
common_code=$(grep -vE '^[[:space:]]*#' "$COMMON_LIB")
assert_not_contains "$common_code" 'for pid in $pids' \
    && assert_contains "$common_code" 'while IFS= read -r pid' \
    && test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Case 11 — NEGATIVE CONTROL: Cases 6-8 must fail against a pre-fix copy
# ═══════════════════════════════════════════════════════════════════════════
# Structural greps are the easiest assertions in this file to satisfy by
# accident. Synthesize the PRE-FIX state (strip every mention of the restore
# variable and the snapshot call) and require the same checks to fail. If they
# still pass here, they were never testing anything.
test_start "XACA-0799 Case 11: structural checks fail against a synthesized pre-fix copy"
_PREFIX_DIR="$TEST_TMP_DIR/prefix"
mkdir -p "$_PREFIX_DIR"
grep -v "AITEAMFORGE_RESTORE_LCARS_PORTS\|aiteamforge_team_for_lcars_port" "$START_CMD" > "$_PREFIX_DIR/start.sh"
grep -v "aiteamforge_lcars_running_ports" "$CLI_CMD" > "$_PREFIX_DIR/cli.sh"

_neg_ok=true
_neg_msg=""

# Case 7 equivalent must now FAIL to find the restore wiring.
if grep -q "AITEAMFORGE_RESTORE_LCARS_PORTS" "$_PREFIX_DIR/start.sh" 2>/dev/null; then
    _neg_ok=false
    _neg_msg="pre-fix start.sh still mentions AITEAMFORGE_RESTORE_LCARS_PORTS"
fi
# Case 6 equivalent must now FAIL to find a snapshot call.
if [ "$_neg_ok" = true ] && grep -q "aiteamforge_lcars_running_ports" "$_PREFIX_DIR/cli.sh" 2>/dev/null; then
    _neg_ok=false
    _neg_msg="pre-fix cli.sh still mentions aiteamforge_lcars_running_ports"
fi
# Sanity: the stripped copies must still be substantial files, not empty — an
# empty file would make the two greps above pass for the wrong reason.
if [ "$_neg_ok" = true ]; then
    _pf_lines=$(wc -l < "$_PREFIX_DIR/start.sh" | tr -d ' ')
    if [ "${_pf_lines:-0}" -lt 100 ]; then
        _neg_ok=false
        _neg_msg="synthesized pre-fix start.sh is implausibly short (${_pf_lines} lines) — strip removed too much"
    fi
fi

if [ "$_neg_ok" = true ]; then
    test_pass
else
    test_fail "$_neg_msg"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Case 12 — port extraction is a real function, driven directly (XACA-0799-006)
# ═══════════════════════════════════════════════════════════════════════════
# The first cut re-typed the production sed into the test body. That proves only
# that the test's own copy works and keeps passing after production drifts away
# from it, so the rule now lives in aiteamforge_extract_lcars_port().
test_start "XACA-0799 Case 12a: extraction is anchored on server.py"
assert_equal "8203" "$(aiteamforge_extract_lcars_port 'python3 server.py 8203')" \
  && assert_equal "8361" "$(aiteamforge_extract_lcars_port '/opt/homebrew/bin/Python server.py 8361')" \
  && test_pass

test_start "XACA-0799 Case 12b: a trailing numeric arg does not become the port"
# A right-to-left "last all-numeric token" scan returns 2 here. That form shipped
# once carrying a comment claiming it "tolerates trailing flags"; it does the
# opposite. Anchoring is what actually tolerates them.
assert_equal "8203" "$(aiteamforge_extract_lcars_port 'python3 server.py 8203 --workers 2')" \
  && test_pass

test_start "XACA-0799 Case 12c: non-server.py cmdlines and empty input yield nothing"
assert_empty "$(aiteamforge_extract_lcars_port 'python3 some-other.py 8203')" \
  && assert_empty "$(aiteamforge_extract_lcars_port '')" \
  && test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Case 13 — the restore dedupe predicate (XACA-0799-001)
# ═══════════════════════════════════════════════════════════════════════════
# Previously inline in start_lcars()'s restore loop, reachable only by launching
# real servers. A review-round mutation pass DELETED the dedupe outright with the
# suite still fully green, so it is now a pure predicate the suite drives.
test_start "XACA-0799 Case 13a: an unrelated team is new"
aiteamforge_restore_key_is_new "academy" "ios" "android" && test_pass \
  || test_fail "unrelated team reported as duplicate"

test_start "XACA-0799 Case 13b: an exact repeat is NOT new (this is the dedupe)"
if aiteamforge_restore_key_is_new "academy" "ios" "academy"; then
  test_fail "an exact duplicate was reported new — dedupe is not working"
else
  test_pass
fi

test_start "XACA-0799 Case 13c: instance id matches a configured BASE id"
# THE case the dedupe exists for: .teams[] holds "finance", the reverse lookup
# returns "finance-personal". A raw-only comparison misses it and races two
# servers onto port 8361. Needs kanban-paths.sh (sourced above) for the mapping.
if aiteamforge_restore_key_is_new "finance-personal" "finance"; then
  test_fail "instance id 'finance-personal' did not match configured base 'finance'"
else
  test_pass
fi

test_start "XACA-0799 Case 13d: empty candidate is never treated as new"
if aiteamforge_restore_key_is_new "" "academy"; then
  test_fail "empty candidate reported as a startable team"
else
  test_pass
fi

# ═══════════════════════════════════════════════════════════════════════════
# Case 14 — single-pass port map (XACA-0799-004)
# ═══════════════════════════════════════════════════════════════════════════
test_start "XACA-0799 Case 14a: map emits one port<TAB>team row per allocated team"
_map=$(aiteamforge_lcars_port_team_map)
assert_contains "$_map" "8361	finance-personal" \
  && assert_contains "$_map" "8240	academy" \
  && test_pass

test_start "XACA-0799 Case 14b: map is READ-ONLY (never materializes a registry)"
# The old per-team path went through aiteamforge_team_lcars_port, which writes a
# default registry on first lookup when none exists — so a reverse lookup could
# create state just by running (the XACA-0792-001 precedent set by `status`).
_ro2=$(mktemp -d)
( AITEAMFORGE_CONFIG="$_ro2/team-paths.json" aiteamforge_lcars_port_team_map >/dev/null 2>&1 ) || true
assert_file_not_exists "$_ro2/team-paths.json" && test_pass

test_start "XACA-0799 Case 14c: map-based lookup resolves and rejects correctly"
# The lookup callers actually use. Driven against a map built once, which is the
# whole point of the fix — a batch of probes costs one jq fork, not one per port.
_m=$(aiteamforge_lcars_port_team_map)
assert_equal "academy" "$(aiteamforge_team_for_lcars_port_in_map 8240 "$_m")" \
  && assert_equal "finance-personal" "$(aiteamforge_team_for_lcars_port_in_map 8361 "$_m")" \
  && assert_empty "$(aiteamforge_team_for_lcars_port_in_map 9999 "$_m" 2>/dev/null || true)" \
  && test_pass

test_start "XACA-0799 Case 14d: start builds the port map OUTSIDE the restore loop"
# The cost only disappears if the map is built once. Building it per iteration
# would still be O(ports) jq forks while every behavioral assertion above stayed
# green — so this is pinned structurally. An earlier attempt memoized inside the
# map builder instead; that was dead code, because callers invoke it through
# $( ... ) and the cache never survived the subshell.
_sc=$(grep -vE '^[[:space:]]*#' "$START_CMD")
# start.sh builds the map once; the fork-free per-port lookup now lives in
# aiteamforge_build_restore_union() in common.sh. Assert each half in its real
# home, so a regression in either is still caught.
_cmn_code=$(grep -vE '^[[:space:]]*#' "$COMMON_LIB")
assert_contains "$_sc" "aiteamforge_lcars_port_team_map" \
  && assert_contains "$_cmn_code" "aiteamforge_team_for_lcars_port_in_map" \
  && test_pass
# XACA-0799-021: CODE lines only, same reason as Case 8 above.
_map_line=$(grep -n "aiteamforge_lcars_port_team_map" "$START_CMD" | grep -vE ":[[:space:]]*#" | head -1 | cut -d: -f1)
_loop_line=$(grep -nE "aiteamforge_build_restore_union" "$START_CMD" | grep -vE ":[[:space:]]*#" | head -1 | cut -d: -f1)
test_start "XACA-0799 Case 14e: the map build precedes the union call"
if [ -n "$_map_line" ] && [ -n "$_loop_line" ] && [ "$_map_line" -lt "$_loop_line" ]; then
  test_pass
else
  test_fail "map built at line ${_map_line:-?} does not precede the union call at ${_loop_line:-?}"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Case 15 — matcher literal across EVERY kill/capture site (XACA-0799-005)
# ═══════════════════════════════════════════════════════════════════════════
# The guard previously pinned 2 of 5 sites. aiteamforge-doctor.sh is deliberately
# EXCLUDED and named here rather than silently skipped: it greps `server\.py`
# without the ` [0-9]` port guard because it only PROBES for reporting and wants
# the broader match, so asserting it identical would be wrong.
test_start "XACA-0799 Case 15: every kill/capture site uses one matcher spelling"
_pats=$(grep -rhoE '(pgrep|pkill) -f "server\\\.py \[0-9\]"' \
          "$TAP_ROOT/libexec/commands/aiteamforge-stop.sh" \
          "$TAP_ROOT/libexec/commands/aiteamforge-uninstall.sh" \
          "$TAP_ROOT/libexec/commands/aiteamforge-migrate.sh" \
          "$COMMON_LIB" 2>/dev/null \
        | sed -E 's/^(pgrep|pkill) -f //' | sort -u)
_n=$(printf '%s\n' "$_pats" | grep -c . || true)
# XACA-0799-008: a set-size check alone only catches a DIVERGENT-but-still-matching
# spelling. It cannot see a site that drops OUT of the grep entirely — widening
# common.sh's capture matcher to a port-less `pgrep -f "server\.py"` (the exact
# violation its own CONTRACT comment forbids) removed it from the result set and
# left size 1, so the guard passed. Require each named file to contribute at least
# one match, so disappearing is a failure rather than a silent pass.
_floor_ok=true
_floor_msg=""
for _f in "$TAP_ROOT/libexec/commands/aiteamforge-stop.sh" \
          "$TAP_ROOT/libexec/commands/aiteamforge-uninstall.sh" \
          "$TAP_ROOT/libexec/commands/aiteamforge-migrate.sh" \
          "$COMMON_LIB"; do
  _c=$(grep -cE '(pgrep|pkill) -f "server\\.py \[0-9\]"' "$_f" 2>/dev/null || true)
  if [ "${_c:-0}" -lt 1 ]; then
    _floor_ok=false
    _floor_msg="$(basename "$_f") contributes 0 matches — it dropped out of the family"
    break
  fi
done
if [ "${_n:-0}" -eq 0 ]; then
  test_fail "extracted no matchers at all — the grep is broken, not the code"
elif [ "$_floor_ok" != true ]; then
  test_fail "$_floor_msg"
else
  assert_equal "1" "$_n" \
    "kill/capture sites disagree; found: $(printf '%s' "$_pats" | tr '\n' ' ')" \
    && test_pass
fi

# ═══════════════════════════════════════════════════════════════════════════
# Case 16 — the fail-soft degrade contract (XACA-0799-012)
# ═══════════════════════════════════════════════════════════════════════════
# The PR's central safety claim is that with AITEAMFORGE_RESTORE_LCARS_PORTS
# unset, start behaves byte-for-byte as before, and that the mechanism can only
# ever ADD teams. Nothing asserted it — every other case exercises the restore
# path. The degrade rests on two mechanisms, both pinned here.

test_start "XACA-0799 Case 16a: whitespace-only restore var yields ZERO ports"
# The guard is `[ -n "${VAR:-}" ]`, which is TRUE for "   " — so a whitespace
# value ENTERS the restore block. The degrade then depends entirely on read -ra
# producing an empty array. Pin that, or a future refactor to a different split
# silently starts iterating a bogus single empty element.
_wsA=(); read -ra _wsA <<< "   "
_wsB=(); read -ra _wsB <<< ""
assert_equal "0" "${#_wsA[@]}" \
  && assert_equal "0" "${#_wsB[@]}" \
  && test_pass

test_start "XACA-0799 Case 16b: the restore block is guarded on the variable"
_sc16=$(grep -vE '^[[:space:]]*#' "$START_CMD")
assert_contains "$_sc16" 'if [ -n "${AITEAMFORGE_RESTORE_LCARS_PORTS:-}" ]; then' \
  && test_pass

test_start "XACA-0799 Case 16c: start UNSETS the variable after consuming it"
# XACA-0799-011: the dispatcher EXPORTS it, so without an unset it leaks down the
# whole process tree — into the per-team *-startup.sh launches that follow the
# union and anything they invoke. A nested STANDALONE start inheriting it would
# perform its own restore union outside any restart: exactly the failure mode for
# which the disk-manifest design was rejected.
#
# (XACA-0799-019 corrected an earlier version of this comment that named
# run_first_launch_preflight -> aiteamforge-doctor.sh -> `aiteamforge start
# kanban` as the threat. That path cannot fire: the preflight runs BEFORE dispatch
# reaches start_lcars, so the unset is too late to affect it, and the doctor
# refuses to auto-start under --preflight anyway. The unset is still correct.)
assert_contains "$_sc16" "unset AITEAMFORGE_RESTORE_LCARS_PORTS" \
  && test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Case 17 — reverse map must cover the same set as the forward lookup
# ═══════════════════════════════════════════════════════════════════════════
# XACA-0799-010. The jq fast path reads team-paths.json only, but the FORWARD
# lookup falls back to _AITEAMFORGE_DEFAULT_TEAMS_DATA. A team absent from the
# config therefore resolved FORWARD while being invisible to the REVERSE map, so
# its live port hit "no team owns it" and the team was silently dropped from a
# restart. The original fixture gave every team an explicit port, so no case could
# see it.
test_start "XACA-0799 Case 17: a config-absent team still round-trips"
_c17=$(mktemp -d)
cat > "$_c17/team-paths.json" <<'EOF'
{"schema_version": 2, "teams": {"academy": {"team_code": "ACA", "lcars_port": 8240}}}
EOF
_c17_fwd=$(AITEAMFORGE_CONFIG="$_c17/team-paths.json" aiteamforge_team_lcars_port ios 2>/dev/null || true)
_c17_map=$(AITEAMFORGE_CONFIG="$_c17/team-paths.json" aiteamforge_lcars_port_team_map 2>/dev/null || true)
_c17_rev=$(AITEAMFORGE_CONFIG="$_c17/team-paths.json" \
             aiteamforge_team_for_lcars_port_in_map "$_c17_fwd" "$_c17_map" 2>/dev/null || true)
if [ -z "$_c17_fwd" ]; then
  test_fail "fixture invalid: 'ios' does not resolve forward, so nothing is being tested"
else
  assert_equal "ios" "$_c17_rev" \
    "forward resolved ios -> ${_c17_fwd} but the reverse map does not own that port" \
    && test_pass
fi

# ═══════════════════════════════════════════════════════════════════════════
# Case 18 — the restore union itself (XACA-0799-015/016/017/020)
# ═══════════════════════════════════════════════════════════════════════════
# A review-round mutation pass found FOUR regressions in start_lcars()'s restore
# loop passing 29/29 with the suite green: deleting the dedupe CALL (the previous
# round extracted the predicate but left its call site unpinned — the wrong half),
# `teams+=` becoming `teams=` so a restore REPLACED the configured list, the
# unowned-port warn+continue replaced by a synthesized id, and the safe read -ra
# split swapped for `($VAR)`. None was reachable without launching real servers.
# The decision now lives in aiteamforge_build_restore_union() and is driven here.

_u_map=$(aiteamforge_lcars_port_team_map)

test_start "XACA-0799 Case 18a: union = configured teams THEN mapped restore teams"
_u=$(aiteamforge_build_restore_union "academy" "8361" "$_u_map" 2>/dev/null | tr '\n' ' ')
assert_equal "academy finance-personal " "$_u" && test_pass

test_start "XACA-0799 Case 18b: a restore team already configured is not added twice"
# Pins the dedupe CALL SITE, not just the predicate.
_u=$(aiteamforge_build_restore_union "finance-personal" "8361" "$_u_map" 2>/dev/null | grep -c .)
assert_equal "1" "$_u" && test_pass

test_start "XACA-0799 Case 18c: ADD-never-lose — every configured team survives"
# Pins `teams+=` vs `teams=`: a restore must never shrink or replace the list.
_u=$(aiteamforge_build_restore_union "academy ios android" "8361" "$_u_map" 2>/dev/null)
_n=$(printf '%s\n' "$_u" | grep -c .)
assert_equal "4" "$_n" \
  && assert_contains "$_u" "academy" \
  && assert_contains "$_u" "ios" \
  && assert_contains "$_u" "android" \
  && assert_contains "$_u" "finance-personal" \
  && test_pass

test_start "XACA-0799 Case 18d: an unowned port warns on stderr and is NOT started"
# Pins the warn+continue: a synthesized id here would be launched with a bogus
# LCARS_TEAM. Assert BOTH halves — the warning, and the absence from the list.
_uerr=$(aiteamforge_build_restore_union "academy" "9999" "$_u_map" 2>&1 >/dev/null)
_uout=$(aiteamforge_build_restore_union "academy" "9999" "$_u_map" 2>/dev/null | tr '\n' ' ')
assert_contains "$_uerr" "9999" \
  && assert_equal "academy " "$_uout" \
  && test_pass

test_start "XACA-0799 Case 18e: base-configured vs instance-restored collapse to one"
# .teams[] holds "finance"; the map returns "finance-personal". Same server.
_u=$(aiteamforge_build_restore_union "finance" "8361" "$_u_map" 2>/dev/null | grep -c .)
assert_equal "1" "$_u" && test_pass

test_start "XACA-0799 Case 18f: whitespace-only port list adds nothing"
# The degrade path: guard is `-n`, so "   " ENTERS the block and must be inert.
_u=$(aiteamforge_build_restore_union "academy" "   " "$_u_map" 2>/dev/null | tr '\n' ' ')
assert_equal "academy " "$_u" && test_pass

test_start "XACA-0799 Case 18g: start_lcars delegates to the union builder"
_sc18=$(grep -vE '^[[:space:]]*#' "$START_CMD")
assert_contains "$_sc18" "aiteamforge_build_restore_union" \
  && test_pass

test_start "XACA-0799 Case 18h: the union splits with read -ra, not an unquoted array"
# XACA-0799-020: this CANNOT be caught behaviorally on this machine — bash splits
# `out=($configured)` just fine, so the suite would stay green while the form is
# glob-expanding and, under zsh, not splitting at all. Case 16a asserted a
# property of bash's own `read -ra` rather than anything in our code; this asserts
# the code. Comment-stripped, since the hazard is named in the prose above it.
_u_code=$(grep -vE '^[[:space:]]*#' "$COMMON_LIB")
assert_contains "$_u_code" 'read -ra out <<< "$configured"' \
  && assert_contains "$_u_code" 'read -ra plist <<< "$ports"' \
  && assert_not_contains "$_u_code" 'out=($configured)' \
  && assert_not_contains "$_u_code" 'plist=($ports)' \
  && test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Summary (standalone mode only — the runner prints its own)
# ═══════════════════════════════════════════════════════════════════════════
if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "──────────────────────────────────────────────"
    echo "  XACA-0799 restart symmetry: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    echo "──────────────────────────────────────────────"
    # A run that asserted nothing is a failure, not a pass (vacuous-green guard).
    if [ "$_PASS_COUNT" -eq 0 ]; then
        echo "  ERROR: no assertions passed — harness did not execute" >&2
        exit 1
    fi
    [ "$_FAIL_COUNT" -eq 0 ] || exit 1
fi

exit 0

