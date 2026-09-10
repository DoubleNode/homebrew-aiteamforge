#!/bin/bash
# test-xaca-1162-host-ready-config-upgrade-registration.sh
#
# XACA-1162: structural anti-regression guard, same idiom as
# test-xaca-1159-global-claude-md-upgrade-registration.sh and the
# provision_msg_routing() precedent it in turn was modeled on.
#
# THE BUG THIS GUARDS AGAINST
# ────────────────────────────
# XACA-1066 shipped scripts/kb-host-ready.sh and
# com.aiteamforge.host-ready.plist through this tap's mandatory sets
# (_xaca0673_mandatory_materialize_basenames /
# _xaca0734_mandatory_launchagent_basenames in libexec/lib/launchagents.sh)
# — both of which correctly reach an already-installed box on
# `aiteamforge upgrade` — but ~/.aiteamforge/host-ready.json itself had NO
# writer anywhere. Verified over SSH on both consumer machines: script on
# disk, plist installed and loaded, config never written. The feature
# shipped and did nothing everywhere, because "no config" and "no
# LaunchAgent" both look identical from inside the script's own
# absent-config no-op. See
# kanban/plans/XACA-1162/XACA-1162-004-host-ready-provisioning-decision.md.
#
# The sibling function this ticket is modeled on, provision_msg_routing(),
# shipped with NO structural test at all (confirmed empty
# `grep -rl provision_msg_routing .` test-file hit at decision time) — that
# omission is precisely the bug class that let XACA-1066 ship
# un-provisioned in the first place. This suite exists so
# provision_host_ready_config() does not repeat it.
#
# "Testing that a function works is a DIFFERENT ASSERTION from testing that
# it is invoked" — the entire bug class here is a correct function that
# nothing calls (or a function that IS called but too early to find
# anything to act on). This suite asserts DEFINITION, INVOCATION, and
# ORDERING (source-text only — no sourcing, no sandboxed execution). See
# scripts/kb-host-ready.sh's own `init-config` subcommand and
# kb-host-ready-init-config sandbox exercises (run by hand during
# XACA-1162-implementation) for functional correctness of the seed itself.
#
# Checks:
#   T1  provision_host_ready_config() is defined in aiteamforge-upgrade.sh
#   T2  provision_host_ready_config is CALLED (bare line) in the run
#       sequence — the assertion that would have caught the XACA-1066 class
#       of bug: a defined-but-never-called function
#   T3  provision_host_ready_config's bare call is ordered AFTER
#       update_runtime_helpers' bare call — LOAD-BEARING, not a style
#       preference: update_runtime_helpers is what materializes
#       scripts/kb-host-ready.sh itself onto an already-installed box that
#       never had it; calling this step earlier finds nothing to invoke on
#       exactly the machines that need it (decision doc, Point 3)
#   T4  extracted provision_host_ready_config() invokes
#       kb-host-ready.sh init-config (the correct subcommand, not some
#       other invocation)
#   T5  provision_host_ready_config is DRY_RUN-aware (never writes under
#       --dry-run)
#   T6  provision_host_ready_config is missing-script tolerant (warns and
#       returns 0 rather than aborting the upgrade when kb-host-ready.sh is
#       absent)
#   T7  provision_host_ready_config uses the `if VAR="$(cmd)"; then ... else
#       ... fi` idiom, NOT a bare failing assignment or `cmd && other` —
#       this script runs under `set -eo pipefail | pipefail`, and either of
#       those shapes would abort the ENTIRE upgrade right here
#       (feedback_set_e_last_line_short_circuit.md)
#   T8  install-kanban.sh's install_host_ready_launchagent() ALSO invokes
#       kb-host-ready.sh init-config — the fresh-install call site sharing
#       the SAME implementation (one implementation, two call sites; no
#       drift possible between fresh-install and upgrade per
#       feedback_install_time_provisioning_unreachable_from_upgrade.md)
#   T9  scripts/kb-host-ready.sh defines the `init-config` subcommand
#       (cmd_init_config)
#   T10 scripts/kb-host-ready.sh REGISTERS init-config in its own subcommand
#       dispatcher (main()'s case statement) — the same "defined but
#       unregistered" bug class as T2, one layer down: a cmd_init_config
#       that main() never routes to is exactly as dead as
#       provision_host_ready_config never being called
#   T11 the seed literal in scripts/kb-host-ready.sh carries BOTH
#       non-negotiable properties from the decision doc:
#       "_seeded_unconfigured": true and "lock_after_login": false. Seeding
#       `lock_after_login: true` would lock a shared machine at login as a
#       side effect of an unattended upgrade; seeding without the marker
#       produces a file that is byte-for-byte the documented M1Pro profile
#       with the one field that matters inverted — looks configured, passes
#       `check`, never locks. Regression-guards the two properties an
#       "improvement" is most likely to touch.
#
# Pure source-text assertions against the real files — no sourcing, no
# sandboxed execution, no $HOME mutation. Safe under TEST_TMP_DIR (declared
# for house-style consistency; used only for this suite's own scratch
# extraction files).
#
# CANONICAL-SOURCE NOTE (XACA-0340): scripts/kb-host-ready.sh is a
# tap-mirrored file — homebrew-tap/share/scripts/kb-host-ready.sh is a COPY,
# kept in sync by ./sync-tap.sh, and can legitimately lag the canonical
# dev-team copy between a canonical commit and the next sync. T9-T11 below
# therefore resolve against whichever of the two is newest/present, PREFERRING
# the canonical dev-team copy (homebrew-tap is always a submodule directly
# under the dev-team repo root in every real checkout, so "../scripts" from
# this tap's root is a structural fact, not a path hack) and falling back to
# the tap mirror so the suite stays meaningful after a sync too.
#
# Runs standalone (`bash tests/test-xaca-1162-host-ready-config-upgrade-registration.sh`)
# OR via test-runner.sh. Exit 0 = all pass (and at least one assertion ran),
# exit 1 = any fail OR zero assertions executed (vacuous-green guard).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UPGRADE_SH="$TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh"
INSTALLER="$TAP_ROOT/libexec/installers/install-kanban.sh"

CANONICAL_HR="$(cd "$TAP_ROOT/.." 2>/dev/null && pwd)/scripts/kb-host-ready.sh"
MIRROR_HR="$TAP_ROOT/share/scripts/kb-host-ready.sh"
HR_SCRIPT=""
if [ -f "$CANONICAL_HR" ]; then
    HR_SCRIPT="$CANONICAL_HR"
elif [ -f "$MIRROR_HR" ]; then
    HR_SCRIPT="$MIRROR_HR"
fi

for _need in "$UPGRADE_SH" "$INSTALLER"; do
    if [ ! -f "$_need" ]; then
        echo "FATAL: required file not found: $_need" >&2
        exit 1
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework: no-op-compatible stubs when test-runner.sh has not
# exported the real harness (mirrors test-xaca-1159 / test-xaca-0761 pattern).
# ─────────────────────────────────────────────────────────────────────────────
if ! type -t test_start >/dev/null 2>&1; then
    _PASS_COUNT=0
    _FAIL_COUNT=0
    _CURRENT_TEST=""
    test_start() { _CURRENT_TEST="$1"; echo "  >> $1"; }
    test_pass()  { _PASS_COUNT=$((_PASS_COUNT + 1)); echo "     PASS: $_CURRENT_TEST"; }
    test_fail()  { _FAIL_COUNT=$((_FAIL_COUNT + 1)); echo "     FAIL: $_CURRENT_TEST — $1" >&2; }
fi

# TEST_TMP_DIR-safe: use the runner-supplied dir if present, else our own.
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca1162-host-ready-upgrade.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
cleanup() {
    if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ] && [ -d "${TEST_TMP_DIR:-}" ]; then
        find "$TEST_TMP_DIR" -depth -delete 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Extract provision_host_ready_config() body once, reused by several checks.
UPG_FN_SRC="$TEST_TMP_DIR/provision_host_ready_config.extracted.sh"
awk '
  /^provision_host_ready_config\(\) \{/ { capture=1 }
  capture { print }
  capture && /^}$/ { exit }
' "$UPGRADE_SH" > "$UPG_FN_SRC"

# Extract install_host_ready_launchagent() body once (install-kanban.sh).
INSTALL_FN_SRC="$TEST_TMP_DIR/install_host_ready_launchagent.extracted.sh"
awk '
  /^install_host_ready_launchagent\(\) \{/ { capture=1 }
  capture { print }
  capture && /^}$/ { exit }
' "$INSTALLER" > "$INSTALL_FN_SRC"

# ═══════════════════════════════════════════════════════════════════════════
# T1 — provision_host_ready_config() is defined
# ═══════════════════════════════════════════════════════════════════════════
test_start "T1: provision_host_ready_config() is defined in aiteamforge-upgrade.sh"
if grep -qE '^provision_host_ready_config\(\) \{' "$UPGRADE_SH"; then
    test_pass
else
    test_fail "no 'provision_host_ready_config() {' definition found in $UPGRADE_SH"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T2 — STRUCTURAL: provision_host_ready_config is CALLED in the run sequence.
# ═══════════════════════════════════════════════════════════════════════════
test_start "T2: provision_host_ready_config is invoked (bare call) in the upgrade run sequence"
if grep -qE '^provision_host_ready_config$' "$UPGRADE_SH"; then
    test_pass
else
    test_fail "aiteamforge-upgrade.sh run sequence must call provision_host_ready_config (bare line) — a defined-but-never-called function means EXISTING fleet machines never receive ~/.aiteamforge/host-ready.json (the exact XACA-1066/XACA-1162 defect)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T3 — provision_host_ready_config's bare call appears AFTER
# update_runtime_helpers' bare call. LOAD-BEARING per the decision doc:
# update_runtime_helpers is what materializes scripts/kb-host-ready.sh onto
# an already-installed box that never had it.
# ═══════════════════════════════════════════════════════════════════════════
test_start "T3: provision_host_ready_config call is ordered AFTER update_runtime_helpers call"
_HELPERS_LINE=$(grep -nE '^update_runtime_helpers$' "$UPGRADE_SH" | head -1 | cut -d: -f1)
_HR_LINE=$(grep -nE '^provision_host_ready_config$' "$UPGRADE_SH" | head -1 | cut -d: -f1)
if [ -n "$_HELPERS_LINE" ] && [ -n "$_HR_LINE" ] && [ "$_HR_LINE" -gt "$_HELPERS_LINE" ]; then
    test_pass
else
    test_fail "expected provision_host_ready_config (line ${_HR_LINE:-MISSING}) to be called after update_runtime_helpers (line ${_HELPERS_LINE:-MISSING}) — calling earlier finds nothing to invoke on exactly the machines that need it"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T4 — extracted provision_host_ready_config() invokes
# kb-host-ready.sh init-config.
# ═══════════════════════════════════════════════════════════════════════════
test_start "T4: provision_host_ready_config invokes kb-host-ready.sh init-config"
if [ -s "$UPG_FN_SRC" ] \
    && grep -q "kb-host-ready.sh" "$UPG_FN_SRC" \
    && grep -q "init-config" "$UPG_FN_SRC"; then
    test_pass
else
    test_fail "extracted provision_host_ready_config must reference kb-host-ready.sh AND the init-config subcommand"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T5 — DRY_RUN-aware: never writes under --dry-run.
# ═══════════════════════════════════════════════════════════════════════════
test_start "T5: provision_host_ready_config is DRY_RUN-aware"
if [ -s "$UPG_FN_SRC" ] && grep -qE '\$DRY_RUN.*=.*true' "$UPG_FN_SRC"; then
    test_pass
else
    test_fail "provision_host_ready_config must check \$DRY_RUN and return before writing anything (matches provision_msg_routing's contract)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T6 — missing-script tolerant: warns and returns 0, never aborts.
# ═══════════════════════════════════════════════════════════════════════════
test_start "T6: provision_host_ready_config is fail-soft when kb-host-ready.sh is absent"
if [ -s "$UPG_FN_SRC" ] && grep -qE '!\s*-f\s*"\$hr_script"' "$UPG_FN_SRC" && grep -q "return 0" "$UPG_FN_SRC"; then
    test_pass
else
    test_fail "provision_host_ready_config must guard on the script's absence and return 0 (never abort the upgrade over a provisioning step)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T7 — set -e-safe capture idiom: `if VAR=\"\$(cmd)\"; then ... else ... fi`,
# never a bare failing assignment or `cmd && other` as the function's tail.
# ═══════════════════════════════════════════════════════════════════════════
test_start "T7: provision_host_ready_config uses the set-e-safe capture idiom"
if [ -s "$UPG_FN_SRC" ] && grep -qE 'if [a-zA-Z_]+="\$\(' "$UPG_FN_SRC"; then
    test_pass
else
    test_fail "provision_host_ready_config must capture kb-host-ready.sh's output via 'if VAR=\"\$(cmd)\"; then ... else ... fi', not a bare assignment — this file runs under set -eo pipefail and a bare failing assignment aborts the ENTIRE upgrade (feedback_set_e_last_line_short_circuit.md)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T8 — install-kanban.sh's install_host_ready_launchagent() ALSO invokes
# kb-host-ready.sh init-config (fresh-install call site, same implementation).
# ═══════════════════════════════════════════════════════════════════════════
test_start "T8: install_host_ready_launchagent() invokes kb-host-ready.sh init-config"
if [ -s "$INSTALL_FN_SRC" ] && grep -qE 'init-config' "$INSTALL_FN_SRC"; then
    test_pass
else
    test_fail "install_host_ready_launchagent() must also call 'init-config' — fresh-install and upgrade must share ONE implementation (feedback_install_time_provisioning_unreachable_from_upgrade.md: 'reuse verbatim so the two paths cannot drift')"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T9 — scripts/kb-host-ready.sh defines the init-config subcommand.
# ═══════════════════════════════════════════════════════════════════════════
test_start "T9: kb-host-ready.sh defines cmd_init_config"
if [ -n "$HR_SCRIPT" ] && grep -qE '^cmd_init_config\(\) \{' "$HR_SCRIPT"; then
    test_pass
else
    test_fail "no 'cmd_init_config() {' definition found (checked ${CANONICAL_HR:-<canonical not found>} then ${MIRROR_HR})"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T10 — kb-host-ready.sh REGISTERS init-config in its own subcommand
# dispatcher. Same "defined but unregistered" bug class as T2, one layer
# down: a cmd_init_config nothing routes to is exactly as dead as
# provision_host_ready_config never being called.
# ═══════════════════════════════════════════════════════════════════════════
test_start "T10: kb-host-ready.sh registers init-config in its dispatcher"
if [ -n "$HR_SCRIPT" ] && grep -qE 'init-config\)[[:space:]]+cmd_init_config' "$HR_SCRIPT"; then
    test_pass
else
    test_fail "kb-host-ready.sh's main() case statement must route the 'init-config' subcommand to cmd_init_config"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T11 — the seed literal carries BOTH non-negotiable properties: the
# _seeded_unconfigured marker and lock_after_login: false. Seeding
# lock_after_login: true would lock a shared machine at login as a side
# effect of an unattended upgrade; seeding without the marker produces a
# file that looks configured, passes `check`, and never locks.
# ═══════════════════════════════════════════════════════════════════════════
test_start "T11: the init-config seed carries _seeded_unconfigured AND lock_after_login: false"
if [ -n "$HR_SCRIPT" ] \
    && grep -q '"_seeded_unconfigured": true' "$HR_SCRIPT" \
    && grep -q '"lock_after_login": false' "$HR_SCRIPT"; then
    test_pass
else
    test_fail "the seed literal in kb-host-ready.sh must contain both '\"_seeded_unconfigured\": true' and '\"lock_after_login\": false' — losing either reproduces the XACA-1162 decision doc's M1Pro hazard (a seed that looks configured and silently never locks a shared machine)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Standalone summary + exit code (no-op under test-runner.sh, which owns
# totals). VACUOUS-GREEN GUARD: a suite that ran zero assertions must never
# report success just because nothing failed — count executed assertions and
# require the count be non-zero.
# ═══════════════════════════════════════════════════════════════════════════
if [ -n "${_PASS_COUNT+x}" ]; then
    _TOTAL=$((_PASS_COUNT + _FAIL_COUNT))
    echo ""
    echo "XACA-1162 host-ready-config-upgrade-registration tests: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed (${_TOTAL} assertions executed)"
    if [ "$_TOTAL" -eq 0 ]; then
        echo "FATAL: zero assertions executed — this is a vacuous pass, not a real result" >&2
        exit 1
    fi
    [ "${_FAIL_COUNT:-0}" -eq 0 ] || exit 1
fi
exit 0
