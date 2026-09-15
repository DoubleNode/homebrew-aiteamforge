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
    && grep -q "not configured on this machine" "$R1_OUT" \
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
# Standalone summary + exit code
# ═══════════════════════════════════════════════════════════════════════════
if [ -n "${_PASS_COUNT+x}" ]; then
    echo ""
    echo "XACA-1225-002 msg-relay-reporter tests: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    [ "${_FAIL_COUNT:-0}" -eq 0 ] || exit 1
fi
exit 0
