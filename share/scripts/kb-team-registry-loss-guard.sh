#!/usr/bin/env bash
# kb-team-registry-loss-guard.sh
#
# SessionStart hook (XACA-1029-006) — surfaces TEAM-ID LOSS in
# ~/.aiteamforge/team-paths.json to a human. `load_config()` in
# kanban-hooks/aiteamforge_paths.py has a self-heal path that can overwrite
# the registry with DEFAULT_TEAMS (15 teams, ZERO freelance-* entries),
# permanently deleting every overlay-only team. It has done this at least
# 12 times across three separate days. Nobody noticed, because the only
# prior signal was stderr from a library called by hooks, subagents, the
# LCARS server, and CI — nothing a human actually looks at. Both known
# wipes were discovered only because a person happened to ask where a team
# went. This hook is the fix for THAT gap. It does not touch the library
# bug itself (a separate, parallel fix covers that).
#
# WHY SET DIFFERENCE, NOT TEAM COUNT (XACA-1029 R10): DEFAULT_TEAMS has
# exactly 15 entries. The reproduced incident took the registry from 12
# teams (10 overlay-only) to 15 teams (0 overlay-only) — the COUNT WENT UP
# while 100% of the overlay-only data was destroyed. A count-based alarm
# would have stayed silent through the very incident this ticket exists
# for, and stays silent on any machine whose overlay holds fewer than 15
# teams — the normal shape of a fresh consumer install. The detection
# script this hook wraps compares the team-ID SET against a snapshot it
# owns, and names every lost id explicitly.
#
# This is a thin wrapper — ALL detection, snapshot-keeping, and dedupe
# logic lives in scripts/kb-team-registry-loss-check.py, which is
# independently unit-tested (tests/test-xaca1029-006-team-registry-loss-guard.sh)
# and has real, meaningful exit codes for direct/CI use. This wrapper
# exists only to:
#   1. Run that check on every session start.
#   2. Translate its exit code into a visible warning block.
#   3. NEVER block the session on it, and NEVER self-remediate — same house
#      rule as every other guard hook in this directory
#      (aiteamforge-stub-guard.sh, kb-lcars-port-drift-guard.sh): detect,
#      report, stop. A human decides what happens next. Auto-repairing a
#      data-loss symptom is how this entire class of defect started.
#
# Reference: XACA-1029 (kanban item); the checker's own module docstring
# for the full detection/dedupe/exit-code contract.

# XACA-1753: shared root resolver (sibling of this hook in every layout).
_AITF_SELF="${BASH_SOURCE[0]:-$0}"
_AITF_SELF="$(readlink -f "$_AITF_SELF" 2>/dev/null || printf '%s' "$_AITF_SELF")"
_AITF_LIB="$(dirname "$_AITF_SELF")/aitf-root.sh"
if [ -f "$_AITF_LIB" ]; then
    . "$_AITF_LIB"
else
    echo "team-registry-loss-guard: could not check: aitf-root.sh not found (looked in $_AITF_LIB)"
    exit 0
fi
aitf_init "$_AITF_SELF"
aitf_locate scripts/kb-team-registry-loss-check.py
CHECK_SCRIPT="$AITF_FOUND"

# XACA-1753: a missing detector is REPORTED, never a silent exit 0 (that was a
# fail-open all-clear for a data-loss alarm). Still exit 0: never block a session.
if [ -z "$CHECK_SCRIPT" ]; then
    echo "team-registry-loss-guard: could not check: kb-team-registry-loss-check.py not found (looked in $AITF_LOOKED)"
    exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "team-registry-loss-guard: could not check: python3 not found on PATH"
    exit 0
fi

OUTPUT="$(python3 "$CHECK_SCRIPT" 2>&1)"
RC=$?

# RC 0 = nothing to report right now (first run, no loss, or an
# already-reported condition still inside its dedupe cooldown). Stay silent.
if [ "$RC" -eq 0 ]; then
    exit 0
fi

if [ "$RC" -eq 1 ]; then
    cat <<WARNING

================================================================================
  ALARM: TEAM REGISTRY LOST ONE OR MORE TEAMS
================================================================================

  scripts/kb-team-registry-loss-check.py compares the CURRENT set of team
  ids in ~/.aiteamforge/team-paths.json against its own last known-good
  snapshot of that set. It reported the following (verbatim):

${OUTPUT}

  WHAT THIS MEANS: one or more teams that existed in a prior session are
  gone from the registry now. This matches the XACA-1029 self-heal defect
  in kanban-hooks/aiteamforge_paths.py's load_config(), which can silently
  overwrite the registry with DEFAULT_TEAMS (15 teams, zero freelance-*)
  on a corrupt/invalid read — destroying every overlay-only team in the
  process. The team COUNT can go UP even as real data is destroyed, which
  is why this alarm is keyed on the id SET, not the count.

  DO NOT SELF-REMEDIATE. This guard is warning-only and has not touched
  team-paths.json. To investigate:
    - Check for a recent .bak-* snapshot: ls -la ~/.aiteamforge/*.bak-*
    - Confirm which ids are actually missing (named above) before
      restoring anything — do not guess or reconstruct from memory.

  Reference: XACA-1029 (kanban item) — "team-registry regression alarm".

================================================================================

WARNING
    exit 0
fi

if [ "$RC" -eq 2 ]; then
    cat <<WARNING

================================================================================
  WARNING: TEAM REGISTRY COULD NOT BE VERIFIED
================================================================================

  scripts/kb-team-registry-loss-check.py could not read or parse
  ~/.aiteamforge/team-paths.json, so it cannot currently tell whether any
  team was lost. It reported the following (verbatim):

${OUTPUT}

  This is NOT a loss alarm — the team-id set is simply unknown right now.
  It may be a transient mid-write read (the underlying library is known to
  race under concurrent access) or a genuine corruption. The guard's last
  known-good snapshot has been left untouched either way.

  DO NOT SELF-REMEDIATE. This guard is warning-only. To investigate:
    python3 $CHECK_SCRIPT

  Reference: XACA-1029 (kanban item).

================================================================================

WARNING
    exit 0
fi

# Any other exit code is unexpected — surface it plainly but still never
# block the session.
cat <<WARNING

================================================================================
  WARNING: team registry loss check exited with unexpected code $RC
================================================================================
${OUTPUT}
================================================================================

WARNING

exit 0
