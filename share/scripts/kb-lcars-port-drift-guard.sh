#!/usr/bin/env bash
# kb-lcars-port-drift-guard.sh
#
# SessionStart hook — surfaces LCARS port drift between a live server
# process and the ~/.aiteamforge/team-paths.json registry to the agent.
#
# XACA-0998-005: closes the DETECTION gap this ticket exists for. Before
# this, nothing ever compared the two LCARS port sources, so drift survived
# two incidents undetected. This hook is the "real entry point" that makes
# the detection script (scripts/kb-lcars-port-drift-check.sh) actually run,
# rather than being a function nothing calls (XACA-0297).
#
# This is a thin wrapper — ALL detection logic lives in
# scripts/kb-lcars-port-drift-check.sh, which is independently unit-tested
# (tests/test-xaca-0998-005-lcars-port-drift-check.sh) and has real,
# meaningful exit codes for direct/CI use. This wrapper exists only to:
#   1. Run that script on every session start (a live-process check has no
#      git/worktree scope — it reflects whatever this MACHINE is currently
#      running, identically from any repo checkout or worktree, so unlike
#      homebrew-tap-drift-guard.sh this hook is NOT scope-guarded to the
#      main repo).
#   2. Translate its exit code into a visible warning block when non-zero.
#   3. NEVER block the session on it — same house rule as every other
#      guard hook in this directory (aiteamforge-stub-guard.sh,
#      homebrew-tap-drift-guard.sh): warning-only, ALWAYS exits 0.
#
# Per XACA-0998-002 §5 Correction 1 (signed off in the decision doc), the
# underlying check reports divergence WITHOUT prescribing a direction — it
# does not know which source is correct, and this wrapper does not add any
# remediation opinion on top of it either. NEVER auto-remediates.
#
# Reference: XACA-0998-002-authority-model-decision.md § "Q4 — Detection
# mechanism for subitem 005"; XACA-0297 (a check nothing calls is dead code).

# XACA-1753: shared root resolver (sibling of this hook in every layout).
_AITF_SELF="${BASH_SOURCE[0]:-$0}"
_AITF_SELF="$(readlink -f "$_AITF_SELF" 2>/dev/null || printf '%s' "$_AITF_SELF")"
_AITF_LIB="$(dirname "$_AITF_SELF")/aitf-root.sh"
if [ -f "$_AITF_LIB" ]; then
    . "$_AITF_LIB"
else
    echo "lcars-port-drift-guard: could not check: aitf-root.sh not found (looked in $_AITF_LIB)"
    exit 0
fi
aitf_init "$_AITF_SELF"
aitf_locate scripts/kb-lcars-port-drift-check.sh
CHECK_SCRIPT="$AITF_FOUND"

# XACA-1753: a missing detector is REPORTED, not a silent no-op (the silence was
# a fail-open all-clear). Never errors the session: still exit 0.
if [ -z "$CHECK_SCRIPT" ]; then
    echo "lcars-port-drift-guard: could not check: kb-lcars-port-drift-check.sh not found (looked in $AITF_LOOKED)"
    exit 0
fi

OUTPUT="$(bash "$CHECK_SCRIPT" 2>&1)"
RC=$?

# RC 0 = one or more live LCARS teams checked, all agree with the registry.
# Anything else (divergence found, OR a fail-closed condition — missing/
# unreadable/unparseable registry, missing jq, a live team absent from the
# registry, a null registry port, zero teams checked) surfaces as a warning.
if [ "$RC" -eq 0 ]; then
    exit 0
fi

cat <<WARNING

================================================================================
  WARNING: LCARS PORT DRIFT CHECK DID NOT CONFIRM AGREEMENT
================================================================================

  scripts/kb-lcars-port-drift-check.sh compares each live LCARS server's
  ACTUAL BOUND PORT against ~/.aiteamforge/team-paths.json's configured
  lcars_port for that team. It reported the following (verbatim):

${OUTPUT}

  WHAT THIS DOES NOT MEAN: this is not necessarily the registry's fault, and
  it is not necessarily the live server's fault. "Canonical" designates
  which source wins a tie — it does NOT establish which source is correct
  right now (XACA-0998-002 §1: on 2026-08-29 the registry itself was the
  stale side, and blindly trusting it would have re-broken three healthy
  servers). DO NOT restart, reconcile, or "fix" this toward either side
  without investigating which value is actually correct.

  DO NOT SELF-REMEDIATE. This guard is warning-only. To investigate:
    scripts/kb-lcars-port-drift-check.sh --verbose

  Reference: kanban/plans/XACA-0998/XACA-0998-002-authority-model-decision.md
             § "Q4 — Detection mechanism for subitem 005"

================================================================================

WARNING

exit 0
