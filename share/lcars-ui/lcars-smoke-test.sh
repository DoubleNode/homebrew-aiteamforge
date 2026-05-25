#!/bin/zsh

#
#  lcars-smoke-test.sh
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

# ============================================================================
# LCARS Team-Binding Smoke Test
# ============================================================================
# Verifies that each running LCARS server is bound to the correct team.
# Detects the "silent default" bug: a server launched without LCARS_TEAM env
# silently falls back to "freelance", serving the wrong team's data.
#
# Usage:
#   ./lcars-smoke-test.sh                  # Test all servers
#   ./lcars-smoke-test.sh --port 8203      # Test a single server
#   ./lcars-smoke-test.sh --verbose        # Debug output
#   ./lcars-smoke-test.sh --help
#
# Exit codes:
#   0  - All running servers PASS
#   1  - One or more servers FAIL
#   2  - Usage error
#
# Integration:
#   Alias: kb-lcars-smoke  (add to claude_code_cc_aliases.sh — see bottom)
#   Periodic: reference this script in lcars-health-check.sh --status flow,
#             or wire into a launchd plist alongside the health-check plist
#             (com.devteam.lcars-health.plist). Currently not auto-wired —
#             run manually or from cron:
#               */30 * * * * /path/to/lcars-ui/lcars-smoke-test.sh >> /tmp/lcars-smoke.log 2>&1
#
# NOTE (XACA-0561): Both this script and lcars-health-check.sh derive lcars_port
# at runtime from kanban-hooks/aiteamforge_paths.py (DEFAULT_TEAMS[team]["lcars_port"]).
# Port numbers are NOT hardcoded here. To add a team, add it to the TEAMS list
# below AND to aiteamforge_paths.py DEFAULT_TEAMS.
# ============================================================================

# ============================================================================
# Team List — used to build PORT_TEAM_MAP at runtime
# Format: "team:expected_team" — expected_team is usually identical to team.
# Ports are derived from aiteamforge_paths.py; they are NOT hardcoded here.
# ============================================================================
declare -a _SMOKE_TEAMS=(
    "ios:ios"
    "android:android"
    "firebase:firebase"
    "academy:academy"
    "dns:dns"
    "freelance:freelance"
    "command:command"
    "finance-personal:finance-personal"
    "legal-coparenting:legal-coparenting"
)

# Derive lcars_port for each team from the canonical source at runtime.
# lcars-smoke-test.sh lives in lcars-ui/ — one level below the script root in
# both dev-tree (lcars-ui/ inside dev-team/) and shipped tap layout
# (share/lcars-ui/ inside share/). kanban-hooks/ is always the sibling of
# lcars-ui/'s parent, so we go one level up.
_SCRIPT_DIR="${0:A:h}"
_KANBAN_HOOKS_DIR="${_SCRIPT_DIR}/../kanban-hooks"

# Extract team keys for the python lookup.
_SMOKE_TEAM_KEYS=()
for _e in "${_SMOKE_TEAMS[@]}"; do
    _SMOKE_TEAM_KEYS+=("${_e%%:*}")
done

# One python3 call emitting "team:port" lines; missing/None → stderr warning,
# omitted from output so we never build a PORT_TEAM_MAP entry with a bogus port.
_PORT_LOOKUP=$(python3 -c "
import sys
khdir = sys.argv[1]
teams = sys.argv[2:]
sys.path.insert(0, khdir)
try:
    from aiteamforge_paths import DEFAULT_TEAMS, load_config
    try:
        cfg = load_config()
        live = cfg.get('teams', {})
    except Exception:
        live = {}
    for t in teams:
        entry = live.get(t) or DEFAULT_TEAMS.get(t)
        if entry is None:
            print(\"WARNING: team '\" + t + \"' not in aiteamforge_paths — skipping\", file=sys.stderr)
            continue
        port = entry.get('lcars_port')
        if port is None:
            print(\"WARNING: team '\" + t + \"' lcars_port is None — skipping\", file=sys.stderr)
            continue
        print(t + ':' + str(port))
except ImportError as e:
    print('ERROR: cannot import aiteamforge_paths from ' + khdir + ': ' + str(e), file=sys.stderr)
    sys.exit(1)
" "$_KANBAN_HOOKS_DIR" "${_SMOKE_TEAM_KEYS[@]}")

# Build a team->port associative array.
typeset -A _TEAM_PORT
while IFS=':' read -r _t _p; do
    [[ -n "$_t" && -n "$_p" ]] && _TEAM_PORT[$_t]=$_p
done <<< "$_PORT_LOOKUP"

# Build PORT_TEAM_MAP by combining team list with derived ports.
# Format: "local_port:expected_team"
declare -a PORT_TEAM_MAP=()
for _e in "${_SMOKE_TEAMS[@]}"; do
    IFS=':' read -r _team _expected <<< "$_e"
    _lp="${_TEAM_PORT[$_team]}"
    if [[ -z "$_lp" ]]; then
        print "WARNING: no canonical lcars_port for team '$_team' — skipping smoke-test entry" >&2
        continue
    fi
    PORT_TEAM_MAP+=("${_lp}:${_expected}")
done

# ============================================================================
# Defaults
# ============================================================================
CURL_TIMEOUT=3
VERBOSE=false
SINGLE_PORT=""
PASS=0
FAIL=0
SKIP=0

# ============================================================================
# Argument parsing
# ============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)
            SINGLE_PORT="$2"
            shift 2
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --help|-h)
            grep '^#' "$0" | grep -v '^#!' | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            print "Unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

# ============================================================================
# Helpers
# ============================================================================
log_verbose() {
    [[ "$VERBOSE" == "true" ]] && print "  [dbg] $*"
}

pass_line() {
    print "  PASS  port=$1  team=$2  $3"
    (( PASS++ ))
}

fail_line() {
    print "  FAIL  port=$1  $2"
    (( FAIL++ ))
}

skip_line() {
    print "  SKIP  port=$1  $2"
    (( SKIP++ ))
}

# ============================================================================
# smoke_test_port <port> <expected_team>
# ============================================================================
smoke_test_port() {
    local port="$1"
    local expected_team="$2"

    # ------------------------------------------------------------------
    # Step 0: Reachability check
    # ------------------------------------------------------------------
    local status_json
    status_json=$(curl -s --max-time "$CURL_TIMEOUT" "http://localhost:${port}/api/status" 2>/dev/null)
    if [[ -z "$status_json" ]]; then
        skip_line "$port" "not responding — server not running"
        return
    fi
    log_verbose "/api/status responded"

    # ------------------------------------------------------------------
    # Step 1: Team binding — prefer /api/team (sibling XACA-0249-003),
    #         fall back to /api/status (available on all current servers)
    # ------------------------------------------------------------------
    local team_json resolved_team team_was_explicit default_used
    # Single curl: capture body and HTTP code together to avoid duplicate requests.
    local team_response team_http_code
    team_response=$(curl -s -w $'\n%{http_code}' --max-time "$CURL_TIMEOUT" \
        "http://localhost:${port}/api/team" 2>/dev/null)
    team_http_code="${team_response##*$'\n'}"
    team_json="${team_response%$'\n'*}"

    if [[ "$team_http_code" == "200" ]] && [[ -n "$team_json" ]]; then
        # /api/team is available — use it (richer binding validation)
        log_verbose "/api/team returned HTTP 200"
        resolved_team=$(print "$team_json" | python3 -c \
            "import sys,json; d=json.load(sys.stdin); print(d.get('team',''))" 2>/dev/null)
        team_was_explicit=$(print "$team_json" | python3 -c \
            "import sys,json; d=json.load(sys.stdin); print(str(d.get('team_was_explicit',False)).lower())" 2>/dev/null)
        default_used=$(print "$team_json" | python3 -c \
            "import sys,json; d=json.load(sys.stdin); print(str(d.get('default_used',True)).lower())" 2>/dev/null)

        log_verbose "team=$resolved_team team_was_explicit=$team_was_explicit default_used=$default_used"

        # Validate explicit binding
        if [[ "$team_was_explicit" != "true" ]] || [[ "$default_used" != "false" ]]; then
            fail_line "$port" \
                "server on port ${port} is using fallback default — LCARS_TEAM env was unset on launch (team_was_explicit=${team_was_explicit}, default_used=${default_used})"
            return
        fi

        # Validate team identity
        if [[ "$resolved_team" != "$expected_team" ]]; then
            fail_line "$port" \
                "team mismatch: expected='${expected_team}' got='${resolved_team}' (check LCARS_TEAM env on launch)"
            return
        fi

        pass_line "$port" "$resolved_team" "(/api/team verified: explicit binding)"

    elif [[ "$team_http_code" == "404" ]] || [[ -z "$team_json" ]]; then
        # /api/team not yet deployed — fall back to /api/status
        # /api/status exposes the resolved team but NOT whether it was set explicitly.
        # We can detect the silent-default only by checking if the resolved team matches
        # the expected team. If it matches "freelance" when we expected something else,
        # that's a likely silent-default — but we cannot be certain without /api/team.
        log_verbose "/api/team not available (HTTP ${team_http_code}) — falling back to /api/status"

        resolved_team=$(print "$status_json" | python3 -c \
            "import sys,json; d=json.load(sys.stdin); print(d.get('team',''))" 2>/dev/null)

        log_verbose "resolved_team from /api/status = $resolved_team"

        if [[ -z "$resolved_team" ]]; then
            fail_line "$port" \
                "server lacks /api/team endpoint AND /api/status returned no team field — cannot validate team binding"
            return
        fi

        if [[ "$resolved_team" != "$expected_team" ]]; then
            local hint=""
            [[ "$resolved_team" == "freelance" ]] && \
                hint=" (resolved to 'freelance' — likely LCARS_TEAM was unset on launch)"
            fail_line "$port" \
                "team mismatch: expected='${expected_team}' got='${resolved_team}'${hint} — WARNING: /api/team absent, cannot confirm explicit binding"
            return
        fi

        # Team matches expected, but we cannot confirm it was explicit
        pass_line "$port" "$resolved_team" "(/api/status fallback — /api/team not deployed, explicit binding unconfirmed)"

    else
        fail_line "$port" \
            "unexpected HTTP ${team_http_code} from /api/team — cannot validate team binding"
        return
    fi

    # ------------------------------------------------------------------
    # Step 2: /api/epics?team=<expected> — must return 200 + JSON with 'epics' field
    # ------------------------------------------------------------------
    local epics_file="/tmp/lcars-smoke-epics-${port}.json"
    local epics_http_code
    epics_http_code=$(curl -s -o "$epics_file" -w "%{http_code}" --max-time "$CURL_TIMEOUT" \
        "http://localhost:${port}/api/epics?team=${expected_team}" 2>/dev/null)

    log_verbose "/api/epics?team=${expected_team} → HTTP ${epics_http_code}"

    if [[ "$epics_http_code" != "200" ]]; then
        fail_line "$port" \
            "/api/epics?team=${expected_team} returned HTTP ${epics_http_code} (expected 200)"
        rm -f "$epics_file"
        return
    fi

    local epics_valid
    epics_valid=$(python3 -c \
        "import sys,json; d=json.load(open('${epics_file}')); print('ok' if 'epics' in d else 'missing-epics-field')" \
        2>/dev/null || print "parse-error")

    if [[ "$epics_valid" != "ok" ]]; then
        rm -f "$epics_file"
        fail_line "$port" \
            "/api/epics?team=${expected_team} response invalid: ${epics_valid}"
        return
    fi

    log_verbose "/api/epics?team=${expected_team} → valid JSON with 'epics' field"

    # ------------------------------------------------------------------
    # Step 3 (optional): /api/epics (no param) — confirm it equals ?team= result
    # Design choice: without /api/team we cannot guarantee paramless endpoint
    # uses the right team, so we verify it returns the same epics array as
    # the explicit ?team= call. On mismatch we warn but do NOT fail — the
    # critical invariant is the explicit-param endpoint, not the default.
    # ------------------------------------------------------------------
    if [[ "$VERBOSE" == "true" ]]; then
        local no_param_file="/tmp/lcars-smoke-noparam-${port}.json"
        curl -s --max-time "$CURL_TIMEOUT" \
            "http://localhost:${port}/api/epics" -o "$no_param_file" 2>/dev/null

        local match
        match=$(python3 -c "
import json
try:
    a = json.load(open('${epics_file}'))
    b = json.load(open('${no_param_file}'))
    ids_a = sorted(e.get('id','') for e in a.get('epics',[]))
    ids_b = sorted(e.get('id','') for e in b.get('epics',[]))
    print('match' if ids_a == ids_b else 'differ (explicit=%d default=%d)' % (len(ids_a), len(ids_b)))
except Exception as ex:
    print('compare-error: ' + str(ex))
" 2>/dev/null)
        log_verbose "/api/epics (no param) vs ?team=${expected_team}: ${match}"
        rm -f "$no_param_file"
    fi

    rm -f "$epics_file"
}

# ============================================================================
# Main
# ============================================================================
print "═══════════════════════════════════════════════════════"
print "LCARS Team-Binding Smoke Test  $(date '+%Y-%m-%d %H:%M:%S')"
print "═══════════════════════════════════════════════════════"

if [[ -n "$SINGLE_PORT" ]]; then
    # Single-port mode: find expected team from map
    found=false
    for entry in "${PORT_TEAM_MAP[@]}"; do
        IFS=':' read -r p t <<< "$entry"
        if [[ "$p" == "$SINGLE_PORT" ]]; then
            smoke_test_port "$p" "$t"
            found=true
            break
        fi
    done
    if [[ "$found" == "false" ]]; then
        print "ERROR: port $SINGLE_PORT not in PORT_TEAM_MAP" >&2
        exit 2
    fi
else
    for entry in "${PORT_TEAM_MAP[@]}"; do
        IFS=':' read -r port team <<< "$entry"
        smoke_test_port "$port" "$team"
    done
fi

print "───────────────────────────────────────────────────────"
print "Results: ${PASS} PASS  ${FAIL} FAIL  ${SKIP} SKIP (not running)"
print "═══════════════════════════════════════════════════════"

# Alias: add to claude_code_cc_aliases.sh:
#   alias kb-lcars-smoke='bash ~/dev-team/lcars-ui/lcars-smoke-test.sh'

[[ $FAIL -gt 0 ]] && exit 1 || exit 0
