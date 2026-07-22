#!/usr/bin/env bash
# test-msg-client-install.sh — XACA-0796
#
# Guards the kb-msg Tier-2 relay payload at the layer that actually matters:
# EXECUTION from the installed consumer layout, not file presence.
#
# WHY THIS EXISTS
# ---------------
# XACA-0796 first shipped msg-client.{sh,js} into install_helper_scripts()'s
# allowlist and verified the fix with presence-only assertions plus a genuine
# negative control. Both passed. The relay was still broken, because
# msg-client.js carries a TOP-LEVEL `require('./vault-keygen.js')` and
# msg-client.sh bootstraps libsodium-wrappers with `npm install` in $SCRIPT_DIR
# — neither vault-keygen.js nor package.json was being installed.
#
# That failure mode was worse than the original bug: fleet-reporter.sh's
# Guard 1 (`[ -x "$client" ]`) started PASSING, and node then died on
# MODULE_NOT_FOUND inside a swallowed `2>/dev/null || true`, i.e. a silent
# crash every reporter cycle instead of an honest no-op.
#
# The lesson, and the reason this file is execution-level:
#   PRESENCE-ONLY ASSERTIONS STRUCTURALLY CANNOT CATCH A MISSING TRANSITIVE
#   SIBLING. Only running the thing does.
#
# Invoke: bash tests/test-msg-client-install.sh
# Exit 0 = all assertions passed; exit 1 = at least one failed.
#
# Sandboxing: every write lands under a mktemp -d. AITEAMFORGE_DIR is pointed
# into that sandbox BEFORE install_helper_scripts() runs and is never allowed
# to resolve to a real $HOME (this repo's dev machine rule, XACA-0212).
# No network is required: the require chain is exercised with npm auto-install
# DISABLED, so the pass condition is "modules resolve", not "relay succeeds".

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASSED=0
FAILED=0

pass() { PASSED=$(( PASSED + 1 )); echo "  PASS  $1"; }
fail() { FAILED=$(( FAILED + 1 )); echo "  FAIL  $1"; }

SANDBOX=""
cleanup() { [ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] && rm -rf "$SANDBOX"; }
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Harness: run install_helper_scripts() from a given install-shell.sh image
# against a fresh sandboxed AITEAMFORGE_DIR. Echoes the resulting scripts dir.
# ---------------------------------------------------------------------------
run_installer_from() {
    local installer_file="$1"
    local dest_root="$2"

    (
        export AITEAMFORGE_DIR="$dest_root/aiteamforge"
        export INSTALL_ROOT="$TAP_ROOT"
        mkdir -p "$AITEAMFORGE_DIR"
        # Stub the logging helpers the function calls.
        info()    { :; }
        success() { :; }
        warning() { :; }
        # Extract ONLY install_helper_scripts() so we never run the rest of the
        # installer (which would touch launchd, brew, and real user dirs).
        eval "$(sed -n '/^install_helper_scripts() {/,/^}/p' "$installer_file")"
        install_helper_scripts >/dev/null 2>&1
    )
    echo "$dest_root/aiteamforge/scripts"
}

echo "=== XACA-0796: kb-msg relay install (execution-level) ==="

SANDBOX="$(mktemp -d)"

# Refuse to run if the sandbox somehow resolves near a real home dir.
case "$SANDBOX" in
    "$HOME"|"$HOME"/*) echo "ERROR: sandbox resolved inside \$HOME — refusing." >&2; exit 1 ;;
esac

CURRENT_DIR="$SANDBOX/current"
mkdir -p "$CURRENT_DIR"
SCRIPTS_DIR="$(run_installer_from "$TAP_ROOT/libexec/installers/install-shell.sh" "$CURRENT_DIR")"

# ---------------------------------------------------------------------------
# T1 — the full payload lands. (Necessary, not sufficient; T3 is the real gate.)
# ---------------------------------------------------------------------------
for f in msg-client.sh msg-client.js vault-keygen.js package.json; do
    if [ -f "$SCRIPTS_DIR/$f" ]; then
        pass "T1 $f installed"
    else
        fail "T1 $f MISSING from installed layout"
    fi
done

# ---------------------------------------------------------------------------
# T2 — mode bits match the actual contract.
# fleet-reporter.sh Guard 1 tests `[ -x "$client" ]`, so msg-client.sh's exec
# bit is load-bearing. The others are never exec'd directly (no shebang), so a
# +x bit there would advertise a contract that does not exist.
# ---------------------------------------------------------------------------
if [ -x "$SCRIPTS_DIR/msg-client.sh" ]; then
    pass "T2 msg-client.sh is executable (Guard 1 requires it)"
else
    fail "T2 msg-client.sh NOT executable — fleet-reporter.sh Guard 1 will silently no-op"
fi
for f in msg-client.js vault-keygen.js package.json; do
    if [ -x "$SCRIPTS_DIR/$f" ]; then
        fail "T2 $f is +x but is never exec'd directly (misleading mode bit)"
    else
        pass "T2 $f correctly not executable"
    fi
done

# ---------------------------------------------------------------------------
# T3 — THE ONE THAT MATTERS. Execute msg-client.js from the installed layout
# and assert the require chain fully resolves.
#
# Auto-install is disabled and node_modules is absent, so this must NOT be
# asserted as "runs successfully" — it will legitimately fail later at the
# network or at a lazy libsodium require. The assertion is narrower and exact:
# NO module-resolution error. That is what a missing transitive sibling
# produces, and it is invisible to any presence check.
# ---------------------------------------------------------------------------
if ! command -v node >/dev/null 2>&1; then
    echo "  SKIP  T3 (node not on PATH)"
else
    T3_OUT="$( cd "$SCRIPTS_DIR" && MSG_CLIENT_NO_AUTO_INSTALL=1 \
               node msg-client.js pull --server http://127.0.0.1:9 2>&1 )"
    if grep -q "Cannot find module './vault-keygen.js'" <<< "$T3_OUT"; then
        fail "T3 MODULE_NOT_FOUND on ./vault-keygen.js — transitive sibling not installed"
    elif grep -q "Cannot find module '\./" <<< "$T3_OUT"; then
        fail "T3 unresolved relative require in installed layout: $(grep -m1 "Cannot find module" <<< "$T3_OUT")"
    else
        pass "T3 require chain resolves from installed layout (no module errors)"
    fi
fi

# ---------------------------------------------------------------------------
# T4 — npm bootstrap has a manifest to resolve.
# msg-client.sh runs `npm install` in $SCRIPT_DIR. In the flattened consumer
# layout that dir has no package.json unless we install one; npm then walks up,
# finds nothing, installs nothing, and every relay attempt pays a futile
# npm+node startup. Assert the manifest is present AND declares the dep.
# (No network: we check the manifest, not a completed install.)
# ---------------------------------------------------------------------------
if [ -f "$SCRIPTS_DIR/package.json" ] && command -v node >/dev/null 2>&1; then
    DEP="$( cd "$SCRIPTS_DIR" && node -e \
        'try{const p=require("./package.json");process.stdout.write(String((p.dependencies||{})["libsodium-wrappers"]||""))}catch(e){}' )"
    if [ -n "$DEP" ]; then
        pass "T4 installed package.json declares libsodium-wrappers ($DEP)"
    else
        fail "T4 installed package.json does not declare libsodium-wrappers"
    fi
else
    fail "T4 no package.json in installed layout — npm install will resolve nothing"
fi

# ---------------------------------------------------------------------------
# T5 — NEGATIVE CONTROL. Strip the non-executed payload from a copy of the
# installer and assert T3 then FAILS. Without this, T3 could be passing for
# reasons unrelated to the fix and we would never know.
# A test that cannot fail proves nothing.
# ---------------------------------------------------------------------------
if ! command -v node >/dev/null 2>&1; then
    echo "  SKIP  T5 (node not on PATH)"
else
    NEG_INSTALLER="$SANDBOX/install-shell-neg.sh"
    # Remove ONLY vault-keygen.js from the data-file loop. msg-client.js must
    # still install, or node fails to find the ENTRYPOINT and raises a different
    # error than the transitive-sibling one T3 guards — which would make T5 pass
    # for the wrong reason (it did, on the first draft of this test).
    sed 's/^\( *for datafile in .*\)vault-keygen\.js \(.*\)$/\1\2/' \
        "$TAP_ROOT/libexec/installers/install-shell.sh" > "$NEG_INSTALLER"

    if grep -qE '^ *for datafile in .*msg-client\.js' "$NEG_INSTALLER" \
       && ! grep -qE '^ *for datafile in .*vault-keygen' "$NEG_INSTALLER"; then
        NEG_DIR="$SANDBOX/neg"; mkdir -p "$NEG_DIR"
        NEG_SCRIPTS="$(run_installer_from "$NEG_INSTALLER" "$NEG_DIR")"
        NEG_OUT="$( cd "$NEG_SCRIPTS" && MSG_CLIENT_NO_AUTO_INSTALL=1 \
                    node msg-client.js pull --server http://127.0.0.1:9 2>&1 )"
        if grep -q "Cannot find module './vault-keygen.js'" <<< "$NEG_OUT"; then
            pass "T5 negative control reproduces MODULE_NOT_FOUND (T3 is a real guard)"
        else
            fail "T5 negative control did NOT reproduce the defect — T3 may be vacuous"
        fi
    else
        fail "T5 could not construct negative control (installer shape changed — update this test)"
    fi
fi

# ---------------------------------------------------------------------------
# T6 — npm bootstrap BACKOFF state machine.
#
# This block had ZERO coverage until PR #698 round four, which is exactly why a
# fail-CLOSED defect survived that long: the unreadable-mtime branch zeroed BOTH
# _now and _stamp, making elapsed 0 — "created this instant", i.e. maximally IN
# cooldown — so it always exit 1'd while printing "ignoring cooldown". The
# comment promised fail-open; the code did the opposite. Untested logic that
# only runs on a degraded consumer box is precisely where that hides.
#
# Runs against the INSTALLED msg-client.sh. No npm/network needed: every state
# asserted here short-circuits before the install attempt.
# ---------------------------------------------------------------------------
_backoff_dir() {
    local d="$SANDBOX/backoff-$1"
    mkdir -p "$d"
    cp "$SCRIPTS_DIR/msg-client.sh" "$SCRIPTS_DIR/msg-client.js" \
       "$SCRIPTS_DIR/vault-keygen.js" "$SCRIPTS_DIR/package.json" "$d/" 2>/dev/null
    echo "$d"
}

if ! command -v node >/dev/null 2>&1; then
    echo "  SKIP  T6 (node not on PATH)"
else
    # T6a — a fresh sentinel must short-circuit WITHOUT invoking npm. This is
    # the whole point: fleet-reporter fires this every 60s.
    D=$(_backoff_dir fresh); : > "$D/.msg-client-bootstrap-failed"
    OUT=$( cd "$D" && bash msg-client.sh pull 2>&1 )
    if grep -q "in cooldown" <<< "$OUT" && [ ! -d "$D/node_modules" ]; then
        pass "T6a fresh sentinel short-circuits, npm never invoked"
    else
        fail "T6a fresh sentinel did not short-circuit cleanly"
    fi

    # T6b — an expired sentinel must NOT block (fail-open on age).
    D=$(_backoff_dir expired); : > "$D/.msg-client-bootstrap-failed"
    touch -t "$(date -v-2H +%Y%m%d%H%M 2>/dev/null || date -d '2 hours ago' +%Y%m%d%H%M)" \
          "$D/.msg-client-bootstrap-failed" 2>/dev/null
    # NOTE: do NOT set MSG_CLIENT_NO_AUTO_INSTALL=1 here. That check sits ABOVE
    # the cooldown block and exits first, so the test would pass without ever
    # reaching the logic it claims to cover (it did, until PR #698 round five).
    # Assert on the marker printed immediately BEFORE npm runs — that proves the
    # cooldown gate was passed, without depending on the install succeeding.
    OUT=$( cd "$D" && bash msg-client.sh pull 2>&1 )
    if grep -q "in cooldown" <<< "$OUT"; then
        fail "T6b expired sentinel still blocked — backoff never releases"
    elif grep -q "Installing client dependencies" <<< "$OUT"; then
        pass "T6b expired sentinel ignored (reached install)"
    else
        fail "T6b did not reach the cooldown gate at all (test is vacuous)"
    fi

    # T6c — explicit disable must win over a fresh sentinel.
    D=$(_backoff_dir override); : > "$D/.msg-client-bootstrap-failed"
    OUT=$( cd "$D" && MSG_CLIENT_BOOTSTRAP_COOLDOWN=0 bash msg-client.sh pull 2>&1 )
    if grep -q "in cooldown" <<< "$OUT"; then
        fail "T6c COOLDOWN=0 did not override the sentinel"
    elif grep -q "Installing client dependencies" <<< "$OUT"; then
        pass "T6c COOLDOWN=0 overrides sentinel (reached install)"
    else
        fail "T6c did not reach the cooldown gate at all (test is vacuous)"
    fi

    # T6d — a non-numeric override must WARN and still enforce a backoff, never
    # silently disable it (the fail-silent path this ticket closed).
    D=$(_backoff_dir nonnum); : > "$D/.msg-client-bootstrap-failed"
    OUT=$( cd "$D" && MSG_CLIENT_BOOTSTRAP_COOLDOWN=abc bash msg-client.sh pull 2>&1 )
    if grep -q "not numeric" <<< "$OUT" && grep -q "in cooldown" <<< "$OUT" \
       && [ ! -d "$D/node_modules" ]; then
        pass "T6d non-numeric cooldown warns and still enforces backoff"
    else
        fail "T6d non-numeric cooldown did not warn-and-enforce"
    fi

    # T6e — THE FAIL-OPEN BRANCH ITSELF. T6a-d exercise the state machine but
    # NEVER reach the unreadable-mtime path, because a real backdated sentinel
    # has a perfectly readable mtime. That is precisely how the fail-CLOSED bug
    # survived: it lived in the one branch no test could enter.
    #
    # Reached the same way T5 works — a controlled mutant. Neutralise the mtime
    # probe so it yields garbage, then assert the script PROCEEDS (fail-open)
    # instead of exiting "in cooldown". A stat quirk must never wedge the relay.
    D=$(_backoff_dir failopen); : > "$D/.msg-client-bootstrap-failed"
    sed 's|_stamp=$(stat -c %Y "$BOOTSTRAP_SENTINEL" 2>/dev/null \\|_stamp=$(echo "not-a-number" \\|' \
        "$SCRIPTS_DIR/msg-client.sh" > "$D/msg-client.sh"
    chmod +x "$D/msg-client.sh"
    if grep -q 'not-a-number' "$D/msg-client.sh"; then
        OUT=$( cd "$D" && bash msg-client.sh pull 2>&1 )
        if grep -q "in cooldown" <<< "$OUT"; then
            fail "T6e unreadable mtime FAILED CLOSED — wedges the relay on a stat quirk"
        elif grep -q "ignoring cooldown" <<< "$OUT"; then
            pass "T6e unreadable mtime fails OPEN and says so"
        else
            fail "T6e unreadable-mtime branch not reached (mutant ineffective)"
        fi
    else
        fail "T6e could not construct mutant (stat probe shape changed — update this test)"
    fi
fi

echo
echo "Passed: $PASSED   Failed: $FAILED"

# Gate on FAILED *and* on PASSED. Gating on FAILED alone means a run where every
# assertion was skipped — node absent, an early `return`, a refactor that stops
# reaching the assertions — reports 0/0 and exits 0, i.e. green for having tested
# nothing. That is the exact vacuous-pass failure mode this file exists to
# prevent elsewhere; it would be indefensible to leave it in the guard itself.
# T3/T5 legitimately SKIP without node, so the floor is the assertions that do
# not depend on it (T1 x4, T2 x4, T4 x1 = 9).
MIN_EXPECTED=14
if [ "$FAILED" -ne 0 ]; then
    exit 1
fi
if [ "$PASSED" -lt "$MIN_EXPECTED" ]; then
    echo "ERROR: only $PASSED assertions ran (expected >= $MIN_EXPECTED) — treating as FAILURE," >&2
    echo "       not success. A run that asserts nothing must never report green." >&2
    exit 1
fi
exit 0
