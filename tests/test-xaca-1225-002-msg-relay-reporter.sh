#!/bin/bash
# test-xaca-1225-002-msg-relay-reporter.sh
#
# XACA-1225-002: on a fleet=skip consumer (the tap's own non-interactive
# default — bin/aiteamforge-setup.sh Step 3: "fleet=skip (defaults)"),
# install_fleet_monitor() returns early and NEVER installs fleet-reporter.sh
# or its LaunchAgent — the ONLY thing that runs the kb-msg Tier-2 sealed-relay
# PULL (fleet-monitor/client/fleet-reporter.sh's pull_messages(), XACA-0777).
# `kb-msg doctor` reported "receive path: never attempted a pull" on every
# such box, permanently.
#
# This suite covers both halves of the fix:
#   (A) fleet-reporter.sh itself (canonical: fleet-monitor/client/
#       fleet-reporter.sh; mirrored at share/scripts/fleet-reporter.sh) must
#       run the kb-msg pull WITHOUT attempting a status POST when status
#       reporting was never configured, instead of exiting before ever
#       reaching pull_messages() the moment send_status fails against a
#       phantom localhost endpoint.
#   (B) the fleet-reporter LaunchAgent must be installed on every consumer
#       regardless of FLEET_MODE, via ensure_msg_relay_reporter() in
#       install-fleet-monitor.sh (called from both setup and upgrade),
#       idempotent/non-clobbering, and with a PATH that can find node
#       wherever it actually resolves at install time.
#
# Cases:
#   R1  fleet-reporter.sh: no fleet-config.json/machine-identity.json ->
#       skips the status POST entirely, still runs pull_messages, exits 0
#   R2  fleet-reporter.sh: fleet-config.json PRESENT -> _fleet_status_configured
#       is true (does not take the relay-only shortcut) — behavioural proof
#       the existing configured path is untouched
#   R3  ensure_msg_relay_reporter: fresh install materialises the plist,
#       the operative fleet-reporter.sh copy, and does NOT write
#       fleet-config.json (so R1's on-disk signal stays true afterward)
#   R4  ensure_msg_relay_reporter: idempotent — a pre-existing plist is left
#       byte-for-byte untouched (never clobbers a full Fleet Monitor install)
#   R5  ensure_msg_relay_reporter: fail-soft when fleet-reporter.sh was never
#       shipped to this box (older tap) — no plist created, rc=0
#   R6  install_fleet_reporter_launchagent: the rendered plist's PATH begins
#       with node's resolved bin dir (when node is stubbed at a non-standard
#       location) — the actual PATH-lookup fix, not just presence of a plist
#   R7  install_fleet_reporter_launchagent: no unresolved {{...}} placeholder
#       survives rendering, and the rendered plist is well-formed XML
#   R12 XACA-1225-008 review round 1, Fix 3: rendered plist's Label is
#       com.aiteamforge.fleet-reporter (not the old com.devteam.fleet-reporter,
#       which mismatched the plist's own filename) and ProgramArguments[0]
#       is /bin/bash (not /opt/homebrew/bin/bash, absent on Intel/no-Homebrew
#       machines).
#   R8  fleet-reporter.sh: fleet-config.json PRESENT but send_status FAILS
#       (nothing listening on the configured port) -> main() still runs
#       pull_messages() before exiting 1, rather than starving the relay
#       pull the moment the status POST fails (the orchestrator's own
#       explicit ask — this path had no coverage before this case).
#   R9  REGRESSION found+fixed during XACA-1225-006 testing:
#       _fleet_status_configured() must also recognise load_config()'s
#       documented env-var-only fallback (FLEET_MODE/etc, no files at all),
#       reading a pre-load_config() snapshot rather than load_config()'s own
#       defaulted globals. R9a: no files, no vars -> still skips (real
#       fleet=skip default). R9b: no files, FLEET_MODE+FLEET_LOCAL_PORT set
#       -> reports.
#   R10 REGRESSION found+fixed during XACA-1225-008 review round 1: R1-R9
#       above all run fleet-reporter.sh from ITS OWN checkout location,
#       where a sibling msg-client.sh always happens to exist (dev checkout,
#       or the flattened share/scripts/ mirror) — none of them can catch a
#       regression in the resolution used by the layout the LaunchAgent
#       ACTUALLY runs: install_fleet_reporter() copies ONLY
#       fleet-reporter.sh into "$AITEAMFORGE_DIR/fleet-monitor/client/", with
#       msg-client.sh living exclusively under "$AITEAMFORGE_DIR/scripts/".
#       R10a/R10b lay out that installed shape (no sibling msg-client.sh) and
#       assert msg-client.sh is actually INVOKED (a marker file it writes),
#       not just that a pull-status file exists — R8's bare existence check
#       cannot distinguish a real pull from a "no-client" skip, since
#       pull_messages() writes that file on every guard path. R10a covers
#       the relay-only (unconfigured) path, R10b repeats R8's
#       send_status-FAILS scenario on the same installed layout.
#   S1  ensure_msg_relay_reporter is defined and reuses install_fleet_reporter
#       + install_fleet_reporter_launchagent (no reimplementation)
#   S2  bin/aiteamforge-setup.sh calls ensure_msg_relay_reporter
#       UNCONDITIONALLY (not gated on INSTALL_FLEET)
#   S3  aiteamforge-upgrade.sh's update_msg_relay_reporter is wired into the
#       run sequence, after provision_msg_routing
#   S4  aiteamforge-uninstall.sh's remove_launchagents list includes
#       com.aiteamforge.fleet-reporter.plist
#
# Runs standalone (`bash tests/test-xaca-1225-002-msg-relay-reporter.sh`) OR
# via test-runner.sh. Exit 0 = all pass, exit 1 = any fail.
#
# HARD CONSTRAINTS (dev-machine safety): every case sandboxes HOME (so
# ~/Library/LaunchAgents is never the real one) and sets
# AITEAMFORGE_SKIP_LAUNCHCTL=1 (common.sh's _aitf_launchctl short-circuits to
# a no-op) — no real `launchctl load`/`bootstrap` ever runs. No network. No
# real npm/brew invocation.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# fleet-reporter.sh: prefer the CANONICAL dev-team source — this worktree has
# homebrew-tap as a sibling of fleet-monitor/ (see the ticket's own "Location"
# section), and XACA-1225-002's fix lands there FIRST; the orchestrator syncs
# it into share/scripts/fleet-reporter.sh afterward via sync-tap.sh, which
# this test must not depend on having already run. Fall back to the tap's own
# mirrored copy for any context where the canonical sibling doesn't exist
# (post-sync, or this suite running against a standalone homebrew-tap
# checkout with no sibling dev-team tree at all — e.g. CI on the tap alone).
_CANONICAL_FLEET_REPORTER="$(cd "$TAP_ROOT/.." 2>/dev/null && pwd)/fleet-monitor/client/fleet-reporter.sh"
if [ -f "$_CANONICAL_FLEET_REPORTER" ]; then
    FLEET_REPORTER_SH="$_CANONICAL_FLEET_REPORTER"
else
    FLEET_REPORTER_SH="$TAP_ROOT/share/scripts/fleet-reporter.sh"
fi
INSTALL_FLEET_SH="$TAP_ROOT/libexec/installers/install-fleet-monitor.sh"
COMMON_SH="$TAP_ROOT/libexec/lib/common.sh"
CONSTANTS_SH="$TAP_ROOT/libexec/lib/constants.sh"
PLIST_TEMPLATE="$TAP_ROOT/share/templates/fleet-monitor/fleet-reporter-launchagent.template.plist"
SETUP_SH="$TAP_ROOT/bin/aiteamforge-setup.sh"
UPGRADE_SH="$TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh"
UNINSTALL_SH="$TAP_ROOT/libexec/commands/aiteamforge-uninstall.sh"

for _need in "$FLEET_REPORTER_SH" "$INSTALL_FLEET_SH" "$COMMON_SH" "$CONSTANTS_SH" \
             "$PLIST_TEMPLATE" "$SETUP_SH" "$UPGRADE_SH" "$UNINSTALL_SH"; do
    if [ ! -f "$_need" ]; then
        echo "FATAL: required file not found: $_need" >&2
        exit 1
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework.
# ─────────────────────────────────────────────────────────────────────────────
if ! type -t test_start >/dev/null 2>&1; then
    _PASS_COUNT=0
    _FAIL_COUNT=0
    _CURRENT_TEST=""
    test_start() { _CURRENT_TEST="$1"; echo "  >> $1"; }
    test_pass()  { _PASS_COUNT=$((_PASS_COUNT + 1)); echo "     PASS: $_CURRENT_TEST"; }
    test_fail()  { _FAIL_COUNT=$((_FAIL_COUNT + 1)); echo "     FAIL: $_CURRENT_TEST — $1" >&2; }
fi

# ─────────────────────────────────────────────────────────────────────────────
# Temp directory.
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca1225002-relay.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
TEST_TMP_DIR="$(cd "$TEST_TMP_DIR" && pwd -P)"
WORK_DIR="$TEST_TMP_DIR/xaca1225002"
mkdir -p "$WORK_DIR"

cleanup() {
    if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ] && [ -d "${TEST_TMP_DIR:-}" ]; then
        find "$TEST_TMP_DIR" -depth -delete 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Fixture: a fake framework tree carrying the REAL fleet-reporter.sh mirror,
# REAL plist template, and copies of common.sh/constants.sh/
# install-fleet-monitor.sh so ensure_msg_relay_reporter runs against real
# code end to end without ever touching the actual $HOME.
# ─────────────────────────────────────────────────────────────────────────────
FAKE_TAP="$WORK_DIR/fake-tap"
mkdir -p "$FAKE_TAP/share/scripts" "$FAKE_TAP/share/templates/fleet-monitor" \
         "$FAKE_TAP/libexec/installers" "$FAKE_TAP/libexec/lib"
cp "$FLEET_REPORTER_SH" "$FAKE_TAP/share/scripts/fleet-reporter.sh"
cp "$PLIST_TEMPLATE" "$FAKE_TAP/share/templates/fleet-monitor/fleet-reporter-launchagent.template.plist"
cp "$INSTALL_FLEET_SH" "$FAKE_TAP/libexec/installers/install-fleet-monitor.sh"
cp "$COMMON_SH" "$FAKE_TAP/libexec/lib/common.sh"
cp "$CONSTANTS_SH" "$FAKE_TAP/libexec/lib/constants.sh"

_new_home() {
    local dir="$WORK_DIR/$1"
    mkdir -p "$dir/aiteamforge"
    printf '%s' "$dir"
}

# _xaca1225_portable_timeout <secs> <cmd...> — round-2 review: R11a/R11b used
# to call GNU `timeout` directly, which coreutils provides on this dev
# machine (/opt/homebrew/bin/timeout) but is ABSENT on stock macOS — a
# consumer box running these suites would get a spurious "command not found"
# failure rather than a real test result. Prefer the real `timeout`/`gtimeout`
# when either is on PATH (exact, well-tested semantics); fall back to a
# portable job-control watchdog otherwise. `wait "$cmd_pid"` after already
# reaping it via `kill` is safe — POSIX `wait` on an already-reaped pid just
# returns its exit status again, it does not error.
_xaca1225_portable_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
        return $?
    fi
    if command -v gtimeout >/dev/null 2>&1; then
        gtimeout "$secs" "$@"
        return $?
    fi
    "$@" &
    local cmd_pid=$!
    ( sleep "$secs"; kill -TERM "$cmd_pid" 2>/dev/null ) &
    local watchdog_pid=$!
    local rc=0
    wait "$cmd_pid" 2>/dev/null || rc=$?
    kill "$watchdog_pid" 2>/dev/null
    wait "$watchdog_pid" 2>/dev/null || true
    return "$rc"
}

# _run_ensure <home_dir> [extra_path_prefix] — runs ensure_msg_relay_reporter
# in a sandboxed subshell. extra_path_prefix (optional) is prepended to PATH
# so a stubbed `node` can be made discoverable at a controlled location.
_run_ensure() {
    local home_dir="$1" extra_path="${2:-}"
    (
        export HOME="$home_dir"
        export AITEAMFORGE_DIR="$home_dir/aiteamforge"
        export AITEAMFORGE_SKIP_LAUNCHCTL=1
        [ -n "$extra_path" ] && export PATH="$extra_path:$PATH"
        # shellcheck source=/dev/null
        source "$FAKE_TAP/libexec/installers/install-fleet-monitor.sh"
        ensure_msg_relay_reporter
    )
}

# ═══════════════════════════════════════════════════════════════════════════
# R1 — fleet-reporter.sh: not configured -> skips status POST, still pulls,
# exits 0.
# ═══════════════════════════════════════════════════════════════════════════
test_start "R1: fleet-reporter.sh skips status POST and still runs pull_messages when not configured"
R1_HOME=$(_new_home r1)
R1_OUT="$WORK_DIR/r1.out"
(
    # Isolate from this HOST machine's own real fleet-monitor env vars (this
    # is a live consumer machine and may legitimately export FLEET_MONITOR_API
    # etc. — measured on this box: FLEET_MONITOR_API=https://fleet-monitor.fly.dev/...
    # load_config()'s env-var fallback would otherwise leak that in and this
    # test would spuriously take the CONFIGURED path against a real server).
    unset FLEET_MONITOR_API FLEET_MODE FLEET_AUTH_TOKEN FLEET_LOCAL_PORT \
          FLEET_DASHBOARD_GROUP FLEET_SERVER_URL FLEET_DEBUG FLEET_MACHINE_NAME \
          FLEET_REQUIRE_AUTH
    export HOME="$R1_HOME"
    export AITEAMFORGE_DIR="$R1_HOME/aiteamforge"
    bash "$FLEET_REPORTER_SH"
) >"$R1_OUT" 2>&1
R1_RC=$?
if [ "$R1_RC" = "0" ] \
    && grep -q "not configured on this machine (no fleet-config.json / machine identity found)" "$R1_OUT" \
    && grep -q "Checking kb-msg relay for cross-machine mail" "$R1_OUT" \
    && ! grep -q "Reporting to" "$R1_OUT"; then
    test_pass
else
    test_fail "rc=$R1_RC; expected skip-POST + pull attempt; out=$(cat "$R1_OUT")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# R2 — fleet-reporter.sh: fleet-config.json present -> configured path
# (proves the existing behaviour for a real Fleet Monitor install is
# untouched — it still attempts to build+send a status report).
# ═══════════════════════════════════════════════════════════════════════════
test_start "R2: fleet-reporter.sh takes the configured (status-report) path when fleet-config.json exists"
R2_HOME=$(_new_home r2)
mkdir -p "$R2_HOME/.aiteamforge"
cat >"$R2_HOME/.aiteamforge/fleet-config.json" <<'EOF'
{"mode":"standalone","centralServer":{"enabled":false,"apiEndpoint":"","authToken":""},"localServer":{"enabled":true,"port":59321},"reporting":{"interval":60},"dashboardGroup":""}
EOF
R2_OUT="$WORK_DIR/r2.out"
(
    export HOME="$R2_HOME"
    export AITEAMFORGE_DIR="$R2_HOME/aiteamforge"
    timeout 20 bash "$FLEET_REPORTER_SH"
) >"$R2_OUT" 2>&1
if ! grep -q "not configured on this machine" "$R2_OUT" && grep -q "Reporting to" "$R2_OUT"; then
    test_pass
else
    test_fail "expected the configured path (no skip message, attempts to report); out=$(cat "$R2_OUT")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# R3 — ensure_msg_relay_reporter: fresh install materialises the plist + the
# operative fleet-reporter.sh copy, and deliberately does NOT write
# fleet-config.json.
# ═══════════════════════════════════════════════════════════════════════════
test_start "R3: ensure_msg_relay_reporter materialises plist + operative copy, never writes fleet-config.json"
R3_HOME=$(_new_home r3)
R3_OUT="$WORK_DIR/r3.out"
_run_ensure "$R3_HOME" >"$R3_OUT" 2>&1
R3_PLIST="$R3_HOME/Library/LaunchAgents/com.aiteamforge.fleet-reporter.plist"
R3_OPERATIVE="$R3_HOME/aiteamforge/fleet-monitor/client/fleet-reporter.sh"
if [ -f "$R3_PLIST" ] && [ -x "$R3_OPERATIVE" ] && [ ! -f "$R3_HOME/.aiteamforge/fleet-config.json" ]; then
    test_pass
else
    test_fail "expected plist+operative copy present, fleet-config.json absent; out=$(cat "$R3_OUT")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# R4 — idempotent / non-clobbering: a pre-existing plist (as if the user
# opted into the full Fleet Monitor feature) is left byte-for-byte untouched.
# ═══════════════════════════════════════════════════════════════════════════
test_start "R4: ensure_msg_relay_reporter never clobbers a pre-existing plist"
R4_HOME=$(_new_home r4)
mkdir -p "$R4_HOME/Library/LaunchAgents"
R4_PLIST="$R4_HOME/Library/LaunchAgents/com.aiteamforge.fleet-reporter.plist"
printf 'PRE-EXISTING-SENTINEL-%s' "$RANDOM" >"$R4_PLIST"
R4_BEFORE="$(cat "$R4_PLIST")"
_run_ensure "$R4_HOME" >"$WORK_DIR/r4.out" 2>&1
R4_AFTER="$(cat "$R4_PLIST")"
if [ "$R4_BEFORE" = "$R4_AFTER" ]; then
    test_pass
else
    test_fail "pre-existing plist was modified (before=$R4_BEFORE after=$R4_AFTER)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# R5 — fail-soft when fleet-reporter.sh was never shipped (older tap): no
# plist created, function returns 0 even under set -euo pipefail.
# ═══════════════════════════════════════════════════════════════════════════
test_start "R5: ensure_msg_relay_reporter is fail-soft when fleet-reporter.sh is not shipped"
R5_HOME=$(_new_home r5)
NO_REPORTER_TAP="$WORK_DIR/fake-tap-no-reporter"
mkdir -p "$NO_REPORTER_TAP/share/scripts" "$NO_REPORTER_TAP/share/templates/fleet-monitor" \
         "$NO_REPORTER_TAP/libexec/installers" "$NO_REPORTER_TAP/libexec/lib"
cp "$PLIST_TEMPLATE" "$NO_REPORTER_TAP/share/templates/fleet-monitor/fleet-reporter-launchagent.template.plist"
cp "$INSTALL_FLEET_SH" "$NO_REPORTER_TAP/libexec/installers/install-fleet-monitor.sh"
cp "$COMMON_SH" "$NO_REPORTER_TAP/libexec/lib/common.sh"
cp "$CONSTANTS_SH" "$NO_REPORTER_TAP/libexec/lib/constants.sh"
# deliberately no share/scripts/fleet-reporter.sh
R5_OUT="$WORK_DIR/r5.out"
(
    set -euo pipefail
    export HOME="$R5_HOME"
    export AITEAMFORGE_DIR="$R5_HOME/aiteamforge"
    export AITEAMFORGE_SKIP_LAUNCHCTL=1
    # shellcheck source=/dev/null
    source "$NO_REPORTER_TAP/libexec/installers/install-fleet-monitor.sh"
    ensure_msg_relay_reporter
    echo "SURVIVED_SET_E"
) >"$R5_OUT" 2>&1
R5_RC=$?
if [ "$R5_RC" = "0" ] && grep -q "SURVIVED_SET_E" "$R5_OUT" \
    && [ ! -f "$R5_HOME/Library/LaunchAgents/com.aiteamforge.fleet-reporter.plist" ]; then
    test_pass
else
    test_fail "rc=$R5_RC; expected fail-soft rc=0, no plist; out=$(cat "$R5_OUT")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# R6 — rendered plist's PATH begins with a stubbed node's resolved bin dir.
# ═══════════════════════════════════════════════════════════════════════════
test_start "R6: rendered LaunchAgent PATH is prefixed with node's resolved bin dir"
R6_HOME=$(_new_home r6)
NODE_STUB_DIR="$WORK_DIR/node-stub-bin"
mkdir -p "$NODE_STUB_DIR"
cat >"$NODE_STUB_DIR/node" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$NODE_STUB_DIR/node"
_run_ensure "$R6_HOME" "$NODE_STUB_DIR" >"$WORK_DIR/r6.out" 2>&1
R6_PLIST="$R6_HOME/Library/LaunchAgents/com.aiteamforge.fleet-reporter.plist"
R6_PATH_LINE="$(awk '/<key>PATH<\/key>/{getline; while ($0 !~ /<string>/) getline; print; exit}' "$R6_PLIST" 2>/dev/null)"
if [ -f "$R6_PLIST" ] && printf '%s' "$R6_PATH_LINE" | grep -qF "$NODE_STUB_DIR"; then
    test_pass
else
    test_fail "expected PATH to contain $NODE_STUB_DIR; got: $R6_PATH_LINE"
fi

# ═══════════════════════════════════════════════════════════════════════════
# R7 — no unresolved {{...}} placeholder survives rendering; plist is
# well-formed XML (plutil -lint, when available).
# ═══════════════════════════════════════════════════════════════════════════
test_start "R7: rendered plist has no unresolved placeholders and is well-formed XML"
R7_HOME=$(_new_home r7)
_run_ensure "$R7_HOME" >"$WORK_DIR/r7.out" 2>&1
R7_PLIST="$R7_HOME/Library/LaunchAgents/com.aiteamforge.fleet-reporter.plist"
R7_OK=true
[ -f "$R7_PLIST" ] || R7_OK=false
if [ "$R7_OK" = "true" ] && grep -qE '\{\{[A-Z_]+\}\}' "$R7_PLIST"; then
    R7_OK=false
fi
if [ "$R7_OK" = "true" ] && command -v plutil >/dev/null 2>&1; then
    plutil -lint "$R7_PLIST" >/dev/null 2>&1 || R7_OK=false
fi
if [ "$R7_OK" = "true" ]; then
    test_pass
else
    test_fail "unresolved placeholder or invalid plist; $(grep -E '\{\{[A-Z_]+\}\}' "$R7_PLIST" 2>/dev/null)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# R12 — XACA-1225-008 review round 1, Fix 3: the rendered plist's Label must
# be com.aiteamforge.fleet-reporter (every checker — aiteamforge-doctor.sh,
# aiteamforge-status.sh, aiteamforge-start.sh — greps launchctl output for
# exactly that string; the OLD template's internal Label,
# com.devteam.fleet-reporter, mismatched the plist's own FILENAME, which is
# already com.aiteamforge.fleet-reporter.plist everywhere it's referenced —
# see install-fleet-monitor.sh/aiteamforge-doctor.sh/etc), and
# ProgramArguments[0] must be /bin/bash (the system bash always present at
# that fixed path, not /opt/homebrew/bin/bash, which does not exist on an
# Intel Mac or any machine without Homebrew installed at all — and
# fleet-reporter.sh is documented bash-3.2-safe, see its own "must run under
# bash 3.2" comments, so it never needed a newer bash in the first place).
# Renders the template via the SAME install_fleet_reporter_launchagent() path
# R6/R7 already exercise (_run_ensure), not a hand-rolled sed, so this proves
# what actually ships.
# ═══════════════════════════════════════════════════════════════════════════
test_start "R12: rendered plist has Label=com.aiteamforge.fleet-reporter and ProgramArguments[0]=/bin/bash"
R12_HOME=$(_new_home r12)
_run_ensure "$R12_HOME" >"$WORK_DIR/r12.out" 2>&1
R12_PLIST="$R12_HOME/Library/LaunchAgents/com.aiteamforge.fleet-reporter.plist"
R12_OK=true
[ -f "$R12_PLIST" ] || R12_OK=false
R12_LABEL=""
R12_ARG0=""
if [ "$R12_OK" = "true" ] && command -v plutil >/dev/null 2>&1; then
    plutil -lint "$R12_PLIST" >/dev/null 2>&1 || R12_OK=false
    R12_LABEL="$(plutil -extract Label raw -o - "$R12_PLIST" 2>/dev/null)"
    R12_ARG0="$(plutil -extract ProgramArguments.0 raw -o - "$R12_PLIST" 2>/dev/null)"
elif [ "$R12_OK" = "true" ]; then
    # No plutil (non-macOS test runner) — fall back to a plain-text extraction
    # matching R6's own awk-based pattern above.
    R12_LABEL="$(awk '/<key>Label<\/key>/{getline; print; exit}' "$R12_PLIST" | sed -E 's/^\s*<string>(.*)<\/string>\s*$/\1/')"
    R12_ARG0="$(awk '/<key>ProgramArguments<\/key>/{f=1; next} f && /<string>/{print; exit}' "$R12_PLIST" | sed -E 's/^\s*<string>(.*)<\/string>\s*$/\1/')"
fi
[ "$R12_LABEL" = "com.aiteamforge.fleet-reporter" ] || R12_OK=false
[ "$R12_ARG0" = "/bin/bash" ] || R12_OK=false
if [ "$R12_OK" = "true" ]; then
    test_pass
else
    test_fail "Label='$R12_LABEL' (want com.aiteamforge.fleet-reporter), ProgramArguments[0]='$R12_ARG0' (want /bin/bash)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# R8 — fleet-reporter.sh: fleet-config.json IS present (configured path,
# same as R2), but the configured endpoint has nothing listening — send_status
# fails every retry. main() must still run pull_messages() before exiting 1,
# not starve the relay pull the instant the status POST fails. This is the
# half of XACA-1225-002's main() change R2 never exercised: R2 only proves
# the configured path is TAKEN, not what happens when it fails.
#
# Positive evidence pull_messages() actually ran (not just that main()
# intended to call it): pull_messages() unconditionally writes
# $HOME/.aiteamforge/run/kb-msg-pull-status on every guard path it takes
# (see its own _msg_record_skip, fleet-monitor/client/fleet-reporter.sh) —
# its presence after this run is proof of execution, not an inference from
# console text alone.
# ═══════════════════════════════════════════════════════════════════════════
test_start "R8: send_status FAILS on a configured box -> pull_messages still runs, exit 1"
R8_HOME=$(_new_home r8)
mkdir -p "$R8_HOME/.aiteamforge"
cat >"$R8_HOME/.aiteamforge/fleet-config.json" <<'EOF'
{"mode":"standalone","centralServer":{"enabled":false,"apiEndpoint":"","authToken":""},"localServer":{"enabled":true,"port":59323},"reporting":{"interval":60},"dashboardGroup":""}
EOF
R8_PULL_STATUS="$R8_HOME/.aiteamforge/run/kb-msg-pull-status"
R8_OUT="$WORK_DIR/r8.out"
(
    # Same host-env isolation as R1 — a real FLEET_MONITOR_API etc. on this
    # box must not leak in and change which endpoint gets dialed.
    unset FLEET_MONITOR_API FLEET_MODE FLEET_AUTH_TOKEN FLEET_LOCAL_PORT \
          FLEET_DASHBOARD_GROUP FLEET_SERVER_URL FLEET_DEBUG FLEET_MACHINE_NAME \
          FLEET_REQUIRE_AUTH
    export HOME="$R8_HOME"
    export AITEAMFORGE_DIR="$R8_HOME/aiteamforge"
    bash "$FLEET_REPORTER_SH"
) >"$R8_OUT" 2>&1
R8_RC=$?
R8_OK=true
[ "$R8_RC" = "1" ] || R8_OK=false
grep -q "Report failed. Check API_ENDPOINT configuration." "$R8_OUT" || R8_OK=false
grep -q "Checking kb-msg relay for cross-machine mail" "$R8_OUT" || R8_OK=false
[ -f "$R8_PULL_STATUS" ] || R8_OK=false
# Order matters: the pull must happen AFTER the reported failure, not before
# it (a coincidental pass from a reordered/duplicated code path).
if [ "$R8_OK" = "true" ]; then
    fail_line=$(grep -n "Report failed. Check API_ENDPOINT configuration." "$R8_OUT" | head -1 | cut -d: -f1)
    pull_line=$(grep -n "Checking kb-msg relay for cross-machine mail" "$R8_OUT" | head -1 | cut -d: -f1)
    if [ -z "$fail_line" ] || [ -z "$pull_line" ] || [ "$pull_line" -le "$fail_line" ]; then
        R8_OK=false
    fi
fi
if [ "$R8_OK" = "true" ]; then
    test_pass
else
    test_fail "rc=$R8_RC; expected failed-status path to still pull + exit 1; pull-status file present=$([ -f "$R8_PULL_STATUS" ] && echo yes || echo no); out=$(cat "$R8_OUT")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# R9 — REGRESSION (found + fixed during XACA-1225-006 testing):
# _fleet_status_configured() must recognise env-var-only configuration
# (load_config()'s own documented "environment variables (legacy support)"
# fallback), not just the two files. Two sub-cases against the SAME clean
# HOME (no fleet-config.json/machine-identity.json):
#   R9a — no files, no FLEET_* env vars at all -> not-configured (skip path).
#         This is the real fleet=skip default and must stay unaffected.
#   R9b — no files, but FLEET_MODE/FLEET_LOCAL_PORT SET -> configured
#         (reporting) path, matching tests/test-xaca-0395-006-consumer-
#         auth.sh's pre-existing case 7 (which this suite's R1/R2 fixture
#         style does not otherwise exercise), and proving the check reads a
#         PRE-load_config() snapshot rather than load_config()'s own
#         defaulted globals (load_config() unconditionally sets
#         FLEET_MODE="${FLEET_MODE:-client}", so testing the live var after
#         it runs would read "configured" on every machine, env-configured
#         or not — the exact defect this case is here to catch a
#         regression of).
# ═══════════════════════════════════════════════════════════════════════════
test_start "R9a: fleet-reporter.sh with no files AND no FLEET_* env vars -> still skips (real fleet=skip default unaffected)"
R9_HOME=$(_new_home r9)
R9A_OUT="$WORK_DIR/r9a.out"
(
    unset FLEET_MONITOR_API FLEET_MODE FLEET_AUTH_TOKEN FLEET_LOCAL_PORT \
          FLEET_DASHBOARD_GROUP FLEET_SERVER_URL FLEET_DEBUG FLEET_MACHINE_NAME \
          FLEET_REQUIRE_AUTH
    export HOME="$R9_HOME"
    export AITEAMFORGE_DIR="$R9_HOME/aiteamforge"
    bash "$FLEET_REPORTER_SH"
) >"$R9A_OUT" 2>&1
if grep -q "not configured on this machine" "$R9A_OUT" && ! grep -q "Reporting to" "$R9A_OUT"; then
    test_pass
else
    test_fail "expected the skip path with no files and no env vars; out=$(cat "$R9A_OUT")"
fi

test_start "R9b: fleet-reporter.sh with no files but FLEET_MODE/FLEET_LOCAL_PORT set -> takes the configured (reporting) path"
R9B_OUT="$WORK_DIR/r9b.out"
(
    unset FLEET_MONITOR_API FLEET_AUTH_TOKEN FLEET_DASHBOARD_GROUP \
          FLEET_SERVER_URL FLEET_DEBUG FLEET_MACHINE_NAME FLEET_REQUIRE_AUTH
    export HOME="$R9_HOME"
    export AITEAMFORGE_DIR="$R9_HOME/aiteamforge"
    export FLEET_MODE="standalone"
    export FLEET_LOCAL_PORT="59987"
    bash "$FLEET_REPORTER_SH"
) >"$R9B_OUT" 2>&1
if ! grep -q "not configured on this machine" "$R9B_OUT" && grep -q "Reporting to" "$R9B_OUT"; then
    test_pass
else
    test_fail "expected the configured/reporting path with FLEET_MODE+FLEET_LOCAL_PORT set and no files; out=$(cat "$R9B_OUT")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# R10 — XACA-1225-008 review round 1, Fix 1 regression coverage: the
# INSTALLED consumer layout, where fleet-reporter.sh has NO sibling
# msg-client.sh (see the header comment above for the full rationale).
#
# _r10_compute_slug replicates NOTHING of its own — it sources the reporter's
# own _msg_default_machine_slug() (extracted, so this fixture can never drift
# from what the real guard actually computes) purely to know which
# "$HOME/.aiteamforge/vault/<slug>.key" file-fallback path to seed, so Guard
# 2 (vault key) passes deterministically without depending on, or writing
# to, the real macOS Keychain. This is a throwaway stub file inside this
# test's own sandboxed HOME, not a real secret — only its *existence* is
# ever checked by the guard under test.
# ═══════════════════════════════════════════════════════════════════════════
_R10_SLUG_FN="$WORK_DIR/r10-slug-fn.sh"
awk '/^_msg_default_machine_slug\(\)/,/^}/' "$FLEET_REPORTER_SH" >"$_R10_SLUG_FN"
_r10_compute_slug() {
    bash -c "source '$_R10_SLUG_FN'; _msg_default_machine_slug"
}

# _r10_layout <home_dir> <marker_path> — installed-consumer shape:
# fleet-reporter.sh ALONE under fleet-monitor/client/ (no sibling), an
# executable msg-client.sh STUB under scripts/ that writes <marker_path>
# when actually invoked (instead of touching a real relay), the msg-store.py
# it also needs, and a file-fallback vault key stub for whatever slug this
# host's `hostname` actually derives to.
_r10_layout() {
    local home_dir="$1" marker="$2"
    mkdir -p "$home_dir/aiteamforge/fleet-monitor/client"
    cp "$FLEET_REPORTER_SH" "$home_dir/aiteamforge/fleet-monitor/client/fleet-reporter.sh"
    mkdir -p "$home_dir/aiteamforge/scripts"
    cat >"$home_dir/aiteamforge/scripts/msg-client.sh" <<EOF
#!/usr/bin/env bash
touch "$marker"
exit 0
EOF
    chmod +x "$home_dir/aiteamforge/scripts/msg-client.sh"
    mkdir -p "$home_dir/aiteamforge/kanban-hooks"
    touch "$home_dir/aiteamforge/kanban-hooks/msg-store.py"
    local slug
    slug="$(_r10_compute_slug)"
    mkdir -p "$home_dir/.aiteamforge/vault"
    printf 'stub-not-a-real-key\n' >"$home_dir/.aiteamforge/vault/${slug}.key"
}

test_start "R10a: installed layout (no sibling msg-client.sh) — relay-only path still invokes msg-client.sh, not a no-client skip"
R10A_HOME=$(_new_home r10a)
R10A_MARKER="$WORK_DIR/r10a.marker"
_r10_layout "$R10A_HOME" "$R10A_MARKER"
R10A_PULL_STATUS="$R10A_HOME/.aiteamforge/run/kb-msg-pull-status"
R10A_OUT="$WORK_DIR/r10a.out"
(
    unset FLEET_MONITOR_API FLEET_MODE FLEET_AUTH_TOKEN FLEET_LOCAL_PORT \
          FLEET_DASHBOARD_GROUP FLEET_SERVER_URL FLEET_DEBUG FLEET_MACHINE_NAME \
          FLEET_REQUIRE_AUTH
    export HOME="$R10A_HOME"
    export AITEAMFORGE_DIR="$R10A_HOME/aiteamforge"
    bash "$R10A_HOME/aiteamforge/fleet-monitor/client/fleet-reporter.sh"
) >"$R10A_OUT" 2>&1
R10A_OK=true
[ -f "$R10A_MARKER" ] || R10A_OK=false
[ -f "$R10A_PULL_STATUS" ] || R10A_OK=false
[ -f "$R10A_PULL_STATUS" ] && grep -q "^no-client" "$R10A_PULL_STATUS" && R10A_OK=false
if [ "$R10A_OK" = "true" ]; then
    test_pass
else
    test_fail "marker present=$([ -f "$R10A_MARKER" ] && echo yes || echo no); pull-status=$(cat "$R10A_PULL_STATUS" 2>/dev/null || echo MISSING); out=$(cat "$R10A_OUT")"
fi

test_start "R10b: installed layout, send_status FAILS (R8's scenario) — pull_messages still invokes msg-client.sh, not a no-client skip"
R10B_HOME=$(_new_home r10b)
R10B_MARKER="$WORK_DIR/r10b.marker"
_r10_layout "$R10B_HOME" "$R10B_MARKER"
mkdir -p "$R10B_HOME/.aiteamforge"
# NOTE: pull_messages() derives its relay base URL from
# .centralServer.apiEndpoint directly (read_config(), independent of
# FLEET_MODE) — so unlike R8 (which leaves apiEndpoint empty, since R8 only
# asserts the pull-status FILE exists, satisfied even by a "no-relay" skip),
# this fixture deliberately sets a non-empty apiEndpoint so pull_messages()
# actually reaches the msg-client.sh stub. FLEET_MODE stays "standalone"
# pointing send_status at a nothing-listening local port, so the status POST
# genuinely still fails, matching R8's scenario.
cat >"$R10B_HOME/.aiteamforge/fleet-config.json" <<'EOF'
{"mode":"standalone","centralServer":{"enabled":true,"apiEndpoint":"http://127.0.0.1:1/api/status","authToken":""},"localServer":{"enabled":true,"port":59324},"reporting":{"interval":60},"dashboardGroup":""}
EOF
R10B_PULL_STATUS="$R10B_HOME/.aiteamforge/run/kb-msg-pull-status"
R10B_OUT="$WORK_DIR/r10b.out"
(
    unset FLEET_MONITOR_API FLEET_MODE FLEET_AUTH_TOKEN FLEET_LOCAL_PORT \
          FLEET_DASHBOARD_GROUP FLEET_SERVER_URL FLEET_DEBUG FLEET_MACHINE_NAME \
          FLEET_REQUIRE_AUTH
    export HOME="$R10B_HOME"
    export AITEAMFORGE_DIR="$R10B_HOME/aiteamforge"
    bash "$R10B_HOME/aiteamforge/fleet-monitor/client/fleet-reporter.sh"
) >"$R10B_OUT" 2>&1
R10B_RC=$?
R10B_OK=true
[ "$R10B_RC" = "1" ] || R10B_OK=false
[ -f "$R10B_MARKER" ] || R10B_OK=false
[ -f "$R10B_PULL_STATUS" ] || R10B_OK=false
[ -f "$R10B_PULL_STATUS" ] && grep -q "^no-client" "$R10B_PULL_STATUS" && R10B_OK=false
if [ "$R10B_OK" = "true" ]; then
    test_pass
else
    test_fail "rc=$R10B_RC; marker present=$([ -f "$R10B_MARKER" ] && echo yes || echo no); pull-status=$(cat "$R10B_PULL_STATUS" 2>/dev/null || echo MISSING); out=$(cat "$R10B_OUT")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# R11 — XACA-1225-008 review round 1, Fix 2: _fleet_status_configured()'s
# file arm used to treat bare FLEET_CONFIG_FILE existence as "configured".
# scripts/kb-msg-provision's persist_relay_url() writes fleet-config.json
# containing ONLY .centralServer — that file's mere presence routed such a
# consumer into main()'s configured branch, which attempts a real
# send_status() POST (3 retries x 5s backoff) before ever falling through to
# pull_messages(). R2/R9b already prove a REAL (create_fleet_reporter_config()
# shaped) fleet-config.json still takes the configured path — R11a/R11b cover
# the other two shapes end to end: centralServer-ONLY (must now take the
# relay-only path, no POST attempted) and an unparseable file (must fall back
# to the OLD bare-existence behaviour, never silently downgrade a real fleet
# host that happens to have a corrupt file).
#
# R11c drives _fleet_config_has_more_than_central_server() directly (the
# parser helper itself, EXTRACTED rather than run inside the full script) so
# its jq path and python3-fallback path can each be tested in true isolation
# — running the FULL fleet-reporter.sh cannot exercise the no-jq path at all:
# the script's own top-of-file `export PATH="/opt/homebrew/bin:/usr/local/bin
# :/usr/bin:/bin:..."` unconditionally PREPENDS those dirs ahead of anything
# a caller sets, and jq lives in more than one of them on this machine
# (`/opt/homebrew/bin/jq` AND `/usr/bin/jq` — confirmed via `which -a jq`), so
# no caller-supplied PATH can ever hide it from a full script run. R11a/R11b
# above therefore only ever exercise the jq path; R11c is what actually
# proves the python3 fallback (and the no-tooling fallback) agree with it.
# ═══════════════════════════════════════════════════════════════════════════
test_start "R11a: centralServer-only fleet-config.json (kb-msg-provision shape) -> relay-only, no status POST attempted"
R11A_HOME=$(_new_home r11a)
mkdir -p "$R11A_HOME/.aiteamforge"
cat >"$R11A_HOME/.aiteamforge/fleet-config.json" <<'EOF'
{"centralServer":{"enabled":true,"apiEndpoint":"http://127.0.0.1:1/api/status","authToken":"tok"}}
EOF
R11A_OUT="$WORK_DIR/r11a.out"
(
    unset FLEET_MONITOR_API FLEET_MODE FLEET_AUTH_TOKEN FLEET_LOCAL_PORT \
          FLEET_DASHBOARD_GROUP FLEET_SERVER_URL FLEET_DEBUG FLEET_MACHINE_NAME \
          FLEET_REQUIRE_AUTH
    export HOME="$R11A_HOME"
    export AITEAMFORGE_DIR="$R11A_HOME/aiteamforge"
    _xaca1225_portable_timeout 20 bash "$FLEET_REPORTER_SH"
) >"$R11A_OUT" 2>&1
# XACA-1225-016 (round 2): a centralServer-only fleet-config.json IS present
# in this fixture, so the diagnostic must say so — "relay-only fleet-config.json
# (no mode/identity)" — not the generic "no fleet-config.json / machine
# identity found" reason, which is only accurate when no file exists at all
# (see R1). This is a genuine negative control: pre-fix code printed the
# generic reason UNCONDITIONALLY on every not-configured path, so this exact
# assertion fails against the pre-fix _xaca1225_fleet_unconfigured_reason-less
# code (verified: reverting to the single hardcoded string makes this check
# fail while the old, weaker "not configured on this machine" substring check
# still passes).
if grep -q "not configured on this machine (relay-only fleet-config.json (no mode/identity))" "$R11A_OUT" \
    && ! grep -q "Reporting to" "$R11A_OUT"; then
    test_pass
else
    test_fail "expected the relay-only path with an accurate reason (no status POST); out=$(cat "$R11A_OUT")"
fi

test_start "R11b: unparseable fleet-config.json -> falls back to OLD bare-existence behaviour, status POST attempted"
R11B_HOME=$(_new_home r11b)
mkdir -p "$R11B_HOME/.aiteamforge"
# With the file present but genuinely unparseable, read_config() can extract
# nothing from it at all (not even .centralServer.apiEndpoint), so
# FLEET_MODE/CENTRAL_API both fall back to the script's own hardcoded
# defaults ("client" / http://localhost:3000/api/status) — there is no field
# in this fixture to override that with (any content that WOULD let us steer
# CENTRAL_API to a chosen port would also have to be valid JSON with a real
# .centralServer object, which would flip _fleet_config_has_more_than_
# central_server()'s verdict and test a different code path than "genuinely
# unparseable" — the two goals are mutually exclusive given the production
# code, not an oversight here).
#
# XACA-1225-017 (round 2): the prior version of this fixture relied on
# nothing REALLY listening on localhost:3000 on whichever machine runs this
# suite — true on this dev box today, but not guaranteed, and this repo's own
# fleet-monitor server can plausibly be running locally. A real POST would
# have registered a phantom node on a live dashboard. Since the target port
# can't be steered via the fixture (see above), shadow `curl` with a shell
# FUNCTION instead of a PATH stub. A PATH stub does NOT work here: R11c's own
# comment above already established that fleet-reporter.sh's top-of-file
# `export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:..."` PREPENDS
# those fixed dirs ahead of anything a caller sets, and curl lives in one of
# them on every real macOS box — a caller-side PATH stub would never be
# reached. A bash FUNCTION named `curl`, exported into the child bash's
# environment, is resolved before PATH search regardless of PATH's value, so
# it intercepts the call unconditionally. `bash "$FLEET_REPORTER_SH"` below
# execs a genuine child bash process (not `source`), which is exactly the
# case `export -f` is for.
#
# The assertion only needs "Reporting to $API_ENDPOINT..." to have been
# printed (that happens unconditionally before curl is ever invoked — see
# send_status()) and does not care whether the POST itself succeeded, so a
# stub that never touches the network satisfies the test intent exactly and
# guarantees zero real network egress, regardless of what happens to be
# listening on port 3000 wherever this suite runs. Shape mirrors real curl's
# own output on a failed connect with `-w "\n%{http_code}"` (empty body, then
# curl's own "000" placeholder for "no HTTP response received"), so
# send_to_endpoint()'s http_code/body parsing sees a realistic failure.
printf 'this is not valid json at all {{{' >"$R11B_HOME/.aiteamforge/fleet-config.json"
curl() {
    printf '\n000\n'
    return 0
}
export -f curl
R11B_OUT="$WORK_DIR/r11b.out"
(
    unset FLEET_MONITOR_API FLEET_MODE FLEET_AUTH_TOKEN FLEET_LOCAL_PORT \
          FLEET_DASHBOARD_GROUP FLEET_SERVER_URL FLEET_DEBUG FLEET_MACHINE_NAME \
          FLEET_REQUIRE_AUTH
    export HOME="$R11B_HOME"
    export AITEAMFORGE_DIR="$R11B_HOME/aiteamforge"
    _xaca1225_portable_timeout 20 bash "$FLEET_REPORTER_SH"
) >"$R11B_OUT" 2>&1
unset -f curl
if ! grep -q "not configured on this machine" "$R11B_OUT" && grep -q "Reporting to" "$R11B_OUT"; then
    test_pass
else
    test_fail "expected the OLD bare-existence fallback (status POST attempted); out=$(cat "$R11B_OUT")"
fi

# R11c: isolated matrix over _fleet_config_has_more_than_central_server()
# itself — three fixture shapes x jq-available/python3-only/neither-available
# (9 sub-cases). Extracted, so PATH truly controls which parser answers
# (see the block comment above for why the full-script cases above cannot).
_R11C_FN="$WORK_DIR/r11c-fn.sh"
awk '/^_fleet_config_has_more_than_central_server\(\)/,/^}/' "$FLEET_REPORTER_SH" >"$_R11C_FN"
if ! grep -q '^_fleet_config_has_more_than_central_server()' "$_R11C_FN"; then
    test_start "R11c: extract _fleet_config_has_more_than_central_server"
    test_fail "could not extract the function from $FLEET_REPORTER_SH — is the name unchanged?"
else
    _R11C_ONLY_JQ_BIN="$WORK_DIR/r11c-jq-only-bin"
    _R11C_ONLY_PY_BIN="$WORK_DIR/r11c-py-only-bin"
    _R11C_NEITHER_BIN="$WORK_DIR/r11c-neither-bin"
    mkdir -p "$_R11C_ONLY_JQ_BIN" "$_R11C_ONLY_PY_BIN" "$_R11C_NEITHER_BIN"
    _JQ_BIN="$(command -v jq 2>/dev/null || true)"
    _PY_BIN="$(command -v python3 2>/dev/null || true)"
    [ -n "$_JQ_BIN" ] && ln -sf "$_JQ_BIN" "$_R11C_ONLY_JQ_BIN/jq"
    [ -n "$_PY_BIN" ] && ln -sf "$_PY_BIN" "$_R11C_ONLY_PY_BIN/python3"

    # Invoke bash by its OWN absolute path, never by bare name: exec only
    # searches PATH for a slash-free command, and $bin_dir below deliberately
    # has no `bash` symlink in it (it exists only to control what
    # _fleet_config_has_more_than_central_server() itself can find via
    # `command -v jq`/`command -v python3` INSIDE that subshell).
    _R11C_BASH_BIN="$(command -v bash)"

    _r11c_case() {
        local label="$1" fixture_json="$2" bin_dir="$3" expect_rc="$4"
        test_start "$label"
        local f="$WORK_DIR/r11c-$RANDOM.json"
        printf '%s' "$fixture_json" >"$f"
        local rc
        PATH="$bin_dir" "$_R11C_BASH_BIN" -c "source '$_R11C_FN'; _fleet_config_has_more_than_central_server '$f'"
        rc=$?
        if [ "$rc" = "$expect_rc" ]; then
            test_pass
        else
            test_fail "expected rc=$expect_rc, got rc=$rc (bin_dir=$bin_dir)"
        fi
    }

    R11C_FULL='{"mode":"client","centralServer":{"enabled":true,"apiEndpoint":"http://x/api/status"},"localServer":{"enabled":false,"port":3000},"reporting":{"interval":60},"dashboardGroup":""}'
    R11C_CENTRAL_ONLY='{"centralServer":{"enabled":true,"apiEndpoint":"http://x/api/status","authToken":"tok"}}'
    R11C_BAD='not json at all {{{'

    # jq-only PATH (no python3 reachable)
    _r11c_case "R11c: full fleet-config.json, jq-only -> rc=0 (has extra keys)"        "$R11C_FULL"         "$_R11C_ONLY_JQ_BIN" 0
    _r11c_case "R11c: centralServer-only, jq-only -> rc=1 (ONLY centralServer)"        "$R11C_CENTRAL_ONLY" "$_R11C_ONLY_JQ_BIN" 1
    _r11c_case "R11c: unparseable, jq-only -> rc=2 (fall back to old behaviour)"       "$R11C_BAD"          "$_R11C_ONLY_JQ_BIN" 2
    # python3-only PATH (no jq reachable) — proves the fallback parser agrees
    _r11c_case "R11c: full fleet-config.json, python3-only -> rc=0"                    "$R11C_FULL"         "$_R11C_ONLY_PY_BIN" 0
    _r11c_case "R11c: centralServer-only, python3-only -> rc=1"                        "$R11C_CENTRAL_ONLY" "$_R11C_ONLY_PY_BIN" 1
    _r11c_case "R11c: unparseable, python3-only -> rc=2"                               "$R11C_BAD"          "$_R11C_ONLY_PY_BIN" 2
    # neither tool reachable -- no-tooling fallback, always rc=2 regardless of shape
    _r11c_case "R11c: full fleet-config.json, no tooling -> rc=2 (fail back to old behaviour)" "$R11C_FULL"         "$_R11C_NEITHER_BIN" 2
    _r11c_case "R11c: centralServer-only, no tooling -> rc=2"                          "$R11C_CENTRAL_ONLY" "$_R11C_NEITHER_BIN" 2
    _r11c_case "R11c: unparseable, no tooling -> rc=2"                                 "$R11C_BAD"          "$_R11C_NEITHER_BIN" 2
fi

# ─────────────────────────────────────────────────────────────────────────────
# Structural cases
# ─────────────────────────────────────────────────────────────────────────────
_extract_fn() {
    local file="$1" fn="$2"
    awk -v fn="$fn" '
      $0 ~ ("^" fn "\\(\\) \\{") { capture=1 }
      capture { print }
      capture && /^}$/ { exit }
    ' "$file"
}

# ═══════════════════════════════════════════════════════════════════════════
# S1 — ensure_msg_relay_reporter is defined and reuses install_fleet_reporter
# + install_fleet_reporter_launchagent (no reimplementation).
# ═══════════════════════════════════════════════════════════════════════════
test_start "S1: ensure_msg_relay_reporter reuses install_fleet_reporter + install_fleet_reporter_launchagent"
EMRR_SRC="$WORK_DIR/ensure_msg_relay_reporter.extracted.sh"
_extract_fn "$INSTALL_FLEET_SH" ensure_msg_relay_reporter >"$EMRR_SRC"
if [ -s "$EMRR_SRC" ] && grep -q "install_fleet_reporter\b" "$EMRR_SRC" \
    && grep -q "install_fleet_reporter_launchagent\b" "$EMRR_SRC" \
    && ! grep -q "create_fleet_reporter_config" "$EMRR_SRC"; then
    test_pass
else
    test_fail "ensure_msg_relay_reporter must call install_fleet_reporter + install_fleet_reporter_launchagent, and must NOT call create_fleet_reporter_config"
fi

# ═══════════════════════════════════════════════════════════════════════════
# S2 — bin/aiteamforge-setup.sh calls ensure_msg_relay_reporter
# UNCONDITIONALLY (not gated on INSTALL_FLEET).
# ═══════════════════════════════════════════════════════════════════════════
test_start "S2: aiteamforge-setup.sh calls ensure_msg_relay_reporter, not gated on INSTALL_FLEET"
if grep -q "ensure_msg_relay_reporter" "$SETUP_SH"; then
    # Find the line and confirm the nearest enclosing `if` is NOT an
    # INSTALL_FLEET check. Extract the ~40 lines around the call and check
    # the block's own `if` guard.
    CALL_LINE=$(grep -n "ensure_msg_relay_reporter" "$SETUP_SH" | head -1 | cut -d: -f1)
    BLOCK_START=$((CALL_LINE - 25))
    [ "$BLOCK_START" -lt 1 ] && BLOCK_START=1
    BLOCK="$(sed -n "${BLOCK_START},${CALL_LINE}p" "$SETUP_SH")"
    LAST_IF="$(printf '%s\n' "$BLOCK" | grep -E '^\s*if \[' | tail -1)"
    if printf '%s' "$LAST_IF" | grep -q 'INSTALL_FLEET'; then
        test_fail "ensure_msg_relay_reporter call appears gated on INSTALL_FLEET: $LAST_IF"
    else
        test_pass
    fi
else
    test_fail "aiteamforge-setup.sh must call ensure_msg_relay_reporter"
fi

# ═══════════════════════════════════════════════════════════════════════════
# S3 — update_msg_relay_reporter is wired into the upgrade run sequence,
# after provision_msg_routing.
# ═══════════════════════════════════════════════════════════════════════════
test_start "S3: update_msg_relay_reporter is wired into the run sequence, after provision_msg_routing"
RUNSEQ="$WORK_DIR/runseq.txt"
grep -nE '^(provision_msg_routing|update_msg_relay_reporter)$' "$UPGRADE_SH" >"$RUNSEQ"
ORDER="$(awk -F: '{print $2}' "$RUNSEQ" | tr '\n' ',')"
if [ "$ORDER" = "provision_msg_routing,update_msg_relay_reporter," ]; then
    test_pass
else
    test_fail "expected run-sequence order provision_msg_routing -> update_msg_relay_reporter; got: $ORDER"
fi

# ═══════════════════════════════════════════════════════════════════════════
# S4 — aiteamforge-uninstall.sh's remove_launchagents list includes
# com.aiteamforge.fleet-reporter.plist.
# ═══════════════════════════════════════════════════════════════════════════
test_start "S4: aiteamforge-uninstall.sh removes com.aiteamforge.fleet-reporter.plist"
RLA_SRC="$WORK_DIR/remove_launchagents.extracted.sh"
_extract_fn "$UNINSTALL_SH" remove_launchagents >"$RLA_SRC"
if [ -s "$RLA_SRC" ] && grep -qE '"com\.aiteamforge\.fleet-reporter\.plist"' "$RLA_SRC"; then
    test_pass
else
    test_fail "remove_launchagents must list com.aiteamforge.fleet-reporter.plist"
fi

# ═══════════════════════════════════════════════════════════════════════════
# R13 — XACA-1225-017 (review round 2): pull_messages() must resolve the
# CLIENT and the STORE from the same root. With AITEAMFORGE_DIR unset (a
# manual run) the client resolves via the $HOME/aiteamforge/scripts/
# msg-client.sh candidate, but the OLD store path
# ("${AITEAMFORGE_DIR:-$HOME/dev-team}/kanban-hooks/msg-store.py") still
# pointed at $HOME/dev-team, which does not exist in this fixture — the run
# recorded "no-store" even though a real client was found (reproduced by the
# round-2 reviewer). NEGATIVE CONTROL: reverting store resolution to that old
# single-path form makes this test fail (marker never written, pull-status
# starts with "no-store") while every other case in this suite (R1-R12, S1-S4)
# keeps passing — verified by hand against a copied tree with that one line
# reverted, mirroring the reviewer's own M1-style mutation harness.
# ═══════════════════════════════════════════════════════════════════════════
test_start "R13: client and store resolve from the SAME root when AITEAMFORGE_DIR is unset -- stub invoked, no no-store/no-client skip"
R13_HOME=$(_new_home r13)
R13_MARKER="$WORK_DIR/r13.marker"
_r10_layout "$R13_HOME" "$R13_MARKER"
mkdir -p "$R13_HOME/.aiteamforge"
cat >"$R13_HOME/.aiteamforge/fleet-config.json" <<'EOF'
{"centralServer":{"enabled":true,"apiEndpoint":"http://127.0.0.1:1/api/status","authToken":""}}
EOF
R13_PULL_STATUS="$R13_HOME/.aiteamforge/run/kb-msg-pull-status"
R13_OUT="$WORK_DIR/r13.out"
(
    unset FLEET_MONITOR_API FLEET_MODE FLEET_AUTH_TOKEN FLEET_LOCAL_PORT \
          FLEET_DASHBOARD_GROUP FLEET_SERVER_URL FLEET_DEBUG FLEET_MACHINE_NAME \
          FLEET_REQUIRE_AUTH AITEAMFORGE_DIR
    export HOME="$R13_HOME"
    bash "$R13_HOME/aiteamforge/fleet-monitor/client/fleet-reporter.sh"
) >"$R13_OUT" 2>&1
R13_OK=true
[ -f "$R13_MARKER" ] || R13_OK=false
[ -f "$R13_PULL_STATUS" ] || R13_OK=false
[ -f "$R13_PULL_STATUS" ] && grep -qE '^no-(store|client)' "$R13_PULL_STATUS" && R13_OK=false
if [ "$R13_OK" = "true" ]; then
    test_pass
else
    test_fail "marker present=$([ -f "$R13_MARKER" ] && echo yes || echo no); pull-status=$(cat "$R13_PULL_STATUS" 2>/dev/null || echo MISSING); out=$(cat "$R13_OUT")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# R14 — XACA-1225-015 (review round 2): install_fleet_reporter_launchagent()
# must unload the EXISTING job (by whatever Label the on-disk plist carries
# at that moment) BEFORE overwriting the file, not after. Unloading after the
# rewrite resolves the job by the NEW Label and orphans an old-label
# (com.devteam.fleet-reporter) job that stays loaded until logout, so two
# reporters run every minute. A `launchctl` PATH stub records each
# invocation together with a snapshot of the plist's on-disk Label at call
# time, so ordering relative to the rewrite is directly observable.
# NEGATIVE CONTROL: reverting to the pre-fix order (sed render, THEN unload)
# makes the FIRST logged call read "unload label=com.aiteamforge.fleet-reporter"
# (the NEW label, already written) instead of "unload label=com.devteam.fleet-reporter"
# (the OLD label that was actually loaded) -- verified by hand against a
# copied tree with the two blocks swapped back.
# ═══════════════════════════════════════════════════════════════════════════
test_start "R14: install_fleet_reporter_launchagent unloads the OLD label BEFORE overwriting the plist"
R14_HOME=$(_new_home r14)
mkdir -p "$R14_HOME/aiteamforge/fleet-monitor/client" "$R14_HOME/Library/LaunchAgents"
cp "$FLEET_REPORTER_SH" "$R14_HOME/aiteamforge/fleet-monitor/client/fleet-reporter.sh"
R14_PLIST="$R14_HOME/Library/LaunchAgents/com.aiteamforge.fleet-reporter.plist"
# Pre-existing plist as if installed before XACA-1225-014: the FILENAME
# already matches today's convention, but the CONTENT still carries the
# pre-fix Label -- exactly the shape a re-render encounters on a real
# old-label box.
cat >"$R14_PLIST" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.devteam.fleet-reporter</string>
    <key>ProgramArguments</key>
    <array>
        <string>/opt/homebrew/bin/bash</string>
        <string>/tmp/placeholder-pre-fix-path</string>
    </array>
</dict>
</plist>
EOF
LAUNCHCTL_STUB_DIR="$WORK_DIR/r14-launchctl-stub-bin"
mkdir -p "$LAUNCHCTL_STUB_DIR"
LAUNCHCTL_LOG="$WORK_DIR/r14-launchctl.log"
: > "$LAUNCHCTL_LOG"
cat >"$LAUNCHCTL_STUB_DIR/launchctl" <<STUBEOF
#!/usr/bin/env bash
# XACA-1225-015 test stub: record every invocation instead of touching the
# real launchd. Snapshots the target plist's CURRENT on-disk Label at call
# time, so the log shows whether unload ran before or after the rewrite.
{
    lbl=""
    if [ -n "\${2:-}" ] && [ -f "\${2:-}" ]; then
        lbl="\$(plutil -extract Label raw -o - "\${2}" 2>/dev/null || echo UNREADABLE)"
    fi
    printf '%s label=%s\n' "\$1" "\$lbl"
} >> "$LAUNCHCTL_LOG"
exit 0
STUBEOF
chmod +x "$LAUNCHCTL_STUB_DIR/launchctl"
R14_OUT="$WORK_DIR/r14.out"
(
    export HOME="$R14_HOME"
    export AITEAMFORGE_DIR="$R14_HOME/aiteamforge"
    export PATH="$LAUNCHCTL_STUB_DIR:$PATH"
    # shellcheck source=/dev/null
    source "$FAKE_TAP/libexec/installers/install-fleet-monitor.sh"
    install_fleet_reporter_launchagent
) >"$R14_OUT" 2>&1
R14_OK=true
[ -s "$LAUNCHCTL_LOG" ] || R14_OK=false
R14_FIRST="$(sed -n '1p' "$LAUNCHCTL_LOG" 2>/dev/null)"
R14_SECOND="$(sed -n '2p' "$LAUNCHCTL_LOG" 2>/dev/null)"
[ "$R14_FIRST" = "unload label=com.devteam.fleet-reporter" ] || R14_OK=false
[ "$R14_SECOND" = "load label=com.aiteamforge.fleet-reporter" ] || R14_OK=false
if [ "$R14_OK" = "true" ]; then
    test_pass
else
    test_fail "launchctl log: $(cat "$LAUNCHCTL_LOG" 2>/dev/null || echo MISSING); out=$(cat "$R14_OUT")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# R15 — XACA-1225-015 (review round 2): aiteamforge-upgrade.sh's
# _xaca1225_migrate_fleet_reporter_label() must migrate an old-label plist
# left behind by a pre-XACA-1225-014 install: Label rewritten, a missing
# legacy interpreter replaced, EnvironmentVariables preserved byte-for-byte
# (M4Mini/M1Pro both hand-carry a FLEET_MONITOR_API entry there), idempotent
# on a second run, and --dry-run writes nothing at all.
#
# _XACA1225_LEGACY_BASH_PATH overrides the hardcoded default
# (/opt/homebrew/bin/bash) so this test can deterministically exercise the
# "interpreter is missing -> replace" branch regardless of whether THIS
# machine happens to have Homebrew bash installed (it does, on this dev box
# -- confirmed via `command -v bash`/`ls -la /opt/homebrew/bin/bash` -- so
# testing the literal production default here would always take the
# "already fine, leave it" branch and never exercise the replacement code at
# all). The env var defaults to the real path in production; this is a
# test-only override, not a behavior change.
# ═══════════════════════════════════════════════════════════════════════════
test_start "R15: upgrade migration -- Label + missing interpreter fixed, env preserved, idempotent, --dry-run no-op"
_R15_MIGRATE_FN="$WORK_DIR/r15-migrate-fn.sh"
_extract_fn "$UPGRADE_SH" _xaca1225_migrate_fleet_reporter_label >"$_R15_MIGRATE_FN"
if [ ! -s "$_R15_MIGRATE_FN" ]; then
    test_fail "could not extract _xaca1225_migrate_fleet_reporter_label from $UPGRADE_SH -- is the name unchanged?"
else
    R15_HOME=$(_new_home r15)
    mkdir -p "$R15_HOME/Library/LaunchAgents"
    R15_PLIST="$R15_HOME/Library/LaunchAgents/com.aiteamforge.fleet-reporter.plist"
    R15_LEGACY_BASH="$WORK_DIR/r15-legacy-bash-does-not-exist"
    cat >"$R15_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.devteam.fleet-reporter</string>
    <key>ProgramArguments</key>
    <array>
        <string>${R15_LEGACY_BASH}</string>
        <string>/Users/example/aiteamforge/fleet-monitor/client/fleet-reporter.sh</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
        <key>FLEET_MONITOR_API</key>
        <string>https://fleet-monitor.example.test/api/status</string>
    </dict>
</dict>
</plist>
EOF
    R15_BEFORE_ENV="$(plutil -extract EnvironmentVariables xml1 -o - "$R15_PLIST" 2>/dev/null)"
    LAUNCHCTL_STUB_DIR="$WORK_DIR/r15-launchctl-stub-bin"
    mkdir -p "$LAUNCHCTL_STUB_DIR"
    LAUNCHCTL_LOG="$WORK_DIR/r15-launchctl.log"
    : > "$LAUNCHCTL_LOG"
    # LAUNCHCTL_LOG's path is baked in at heredoc-write time (unquoted
    # delimiter) -- it's a fixed constant for this whole test, reused
    # unchanged across all three subshell invocations below (each just
    # truncates it first), so there is no need for a runtime env-var
    # indirection the way R14's per-call Label snapshot needs `$1`/`$2` to
    # stay unexpanded until the stub actually runs.
    cat >"$LAUNCHCTL_STUB_DIR/launchctl" <<STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$LAUNCHCTL_LOG"
exit 0
STUBEOF
    chmod +x "$LAUNCHCTL_STUB_DIR/launchctl"
    R15_OK=true

    # --dry-run must write NOTHING and call launchctl NOT AT ALL.
    : > "$LAUNCHCTL_LOG"
    R15_BEFORE_DRYRUN="$(cat "$R15_PLIST")"
    (
        export PATH="$LAUNCHCTL_STUB_DIR:$PATH"
        export _XACA1225_LEGACY_BASH_PATH="$R15_LEGACY_BASH"
        # shellcheck source=/dev/null
        source "$COMMON_SH"
        # shellcheck source=/dev/null
        source "$_R15_MIGRATE_FN"
        DRY_RUN=true
        _xaca1225_migrate_fleet_reporter_label "$R15_PLIST"
    ) >"$WORK_DIR/r15-dryrun.out" 2>&1
    R15_AFTER_DRYRUN="$(cat "$R15_PLIST")"
    [ "$R15_BEFORE_DRYRUN" = "$R15_AFTER_DRYRUN" ] || R15_OK=false
    [ -s "$LAUNCHCTL_LOG" ] && R15_OK=false

    # Real run: migrates.
    : > "$LAUNCHCTL_LOG"
    (
        export PATH="$LAUNCHCTL_STUB_DIR:$PATH"
        export _XACA1225_LEGACY_BASH_PATH="$R15_LEGACY_BASH"
        # shellcheck source=/dev/null
        source "$COMMON_SH"
        # shellcheck source=/dev/null
        source "$_R15_MIGRATE_FN"
        DRY_RUN=false
        _xaca1225_migrate_fleet_reporter_label "$R15_PLIST"
    ) >"$WORK_DIR/r15-run1.out" 2>&1
    R15_LABEL="$(plutil -extract Label raw -o - "$R15_PLIST" 2>/dev/null)"
    R15_ARG0="$(plutil -extract ProgramArguments.0 raw -o - "$R15_PLIST" 2>/dev/null)"
    R15_AFTER_ENV="$(plutil -extract EnvironmentVariables xml1 -o - "$R15_PLIST" 2>/dev/null)"
    [ "$R15_LABEL" = "com.aiteamforge.fleet-reporter" ] || R15_OK=false
    [ "$R15_ARG0" = "/bin/bash" ] || R15_OK=false
    [ "$R15_BEFORE_ENV" = "$R15_AFTER_ENV" ] || R15_OK=false
    grep -qx "unload" "$LAUNCHCTL_LOG" || R15_OK=false
    grep -qx "load" "$LAUNCHCTL_LOG" || R15_OK=false

    # Second run: idempotent no-op -- no further launchctl calls, no further edits.
    R15_BEFORE_RUN2="$(cat "$R15_PLIST")"
    : > "$LAUNCHCTL_LOG"
    (
        export PATH="$LAUNCHCTL_STUB_DIR:$PATH"
        export _XACA1225_LEGACY_BASH_PATH="$R15_LEGACY_BASH"
        # shellcheck source=/dev/null
        source "$COMMON_SH"
        # shellcheck source=/dev/null
        source "$_R15_MIGRATE_FN"
        DRY_RUN=false
        _xaca1225_migrate_fleet_reporter_label "$R15_PLIST"
    ) >"$WORK_DIR/r15-run2.out" 2>&1
    R15_AFTER_RUN2="$(cat "$R15_PLIST")"
    [ "$R15_BEFORE_RUN2" = "$R15_AFTER_RUN2" ] || R15_OK=false
    [ -s "$LAUNCHCTL_LOG" ] && R15_OK=false

    if [ "$R15_OK" = "true" ]; then
        test_pass
    else
        test_fail "label=$R15_LABEL arg0=$R15_ARG0; launchctl-log=$(cat "$LAUNCHCTL_LOG" 2>/dev/null); dryrun-out=$(cat "$WORK_DIR/r15-dryrun.out" 2>/dev/null); run1-out=$(cat "$WORK_DIR/r15-run1.out" 2>/dev/null)"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# S5 — structural: the upgrade run sequence must actually REACH the
# migration. update_msg_relay_reporter() calling
# _xaca1225_migrate_fleet_reporter_label() (proven by R15 in isolation) is
# not enough on its own if update_msg_relay_reporter itself were ever dropped
# from the run sequence -- S3 already proves it is wired in after
# provision_msg_routing; this proves the call to the migration function is
# actually present in that same function's body, so the two facts compose
# into "the run sequence reaches the migration."
# ═══════════════════════════════════════════════════════════════════════════
test_start "S5: update_msg_relay_reporter calls _xaca1225_migrate_fleet_reporter_label"
UMRR_SRC="$WORK_DIR/update_msg_relay_reporter.extracted.sh"
_extract_fn "$UPGRADE_SH" update_msg_relay_reporter >"$UMRR_SRC"
if [ -s "$UMRR_SRC" ] && grep -q "_xaca1225_migrate_fleet_reporter_label" "$UMRR_SRC"; then
    test_pass
else
    test_fail "update_msg_relay_reporter must call _xaca1225_migrate_fleet_reporter_label; extracted body: $(cat "$UMRR_SRC" 2>/dev/null)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Standalone summary + exit code
# ═══════════════════════════════════════════════════════════════════════════
if [ -n "${_PASS_COUNT+x}" ]; then
    echo ""
    echo "XACA-1225-002 msg-relay-reporter tests: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    [ "${_FAIL_COUNT:-0}" -eq 0 ] || exit 1
fi
exit 0
