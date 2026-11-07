#!/usr/bin/env bash
# scripts/kb-lcars-port-drift-check.sh
#
# XACA-0998-005: DETECTION for live-LCARS-process-vs-registry port drift.
#
# ── WHY THIS EXISTS ─────────────────────────────────────────────────────────
# XACA-0998's root inventory found a family of readers that each trust
# exactly one of {lcars-ports/*.port, ~/.aiteamforge/team-paths.json} for a
# team's LCARS port, with nothing that ever compares the two — so drift
# between them survived two incidents undetected (XACA-0998-002 §1). This
# script closes that DETECTION gap: it is a standalone, read-only diagnostic
# with a real non-zero exit code on disagreement. It changes nothing.
#
# ── SIBLING IMPLEMENTATIONS (XACA-1007-018) ────────────────────────────────
# Three tools in this repo read LCARS ports and compare sources against each
# other. This repo has a documented sibling-heuristic-drift problem (MEMORY
# k501-sibling-heuristic-drift-pattern.md, 24+ datapoints) whose mitigation is
# DISCOVERABILITY, so each is named here with what actually distinguishes it —
# they are NOT redundant, and picking the wrong one gives a confidently wrong
# answer rather than no answer:
#
#   * THIS SCRIPT (XACA-0998-005) — read-only. Third source is the LIVE BOUND
#     PORT of the running server.py process. Requires the servers to be UP;
#     with them down it fails closed on "zero teams checked", correctly.
#   * scripts/kb-lcars-port-band-audit.sh (XACA-1007-004) — read-only, names
#     no winner either. Third source is the ALLOCATOR'S DECLARED BAND, loaded
#     out of aiteamforge_paths.py rather than reimplemented. Works on a machine
#     whose LCARS servers are DOWN, which is exactly when this script cannot
#     help. Its exit codes distinguish "could not audit" (3) from "audited and
#     found drift" (1); this script does not make that distinction.
#   * scripts/kb-port-reconcile — the only one of the three that WRITES.
#     --check compares .port against the registry and resolves an authoritative
#     side by precedence (--prefer, default "team-paths"); --apply and
#     --set-port act on it. On M3Pro that default names the STALE side for the
#     XACA-0838 teams, so following its advice reverts a correct port. It is
#     also TAP-MIRRORED (sync-tap.sh ~line 431), so editing it takes the
#     two-step submodule commit (XACA-0340) that the other two do not.
#
# Neither this script nor the band audit is in sync-tap.sh's allowlist, so
# neither reaches the consumers. Only kb-port-reconcile ships.
#
# ── WHY THIS COMPARES LIVE PROCESS vs REGISTRY, NOT .port vs REGISTRY ──────
# XACA-0998-002 §5 (Q4, signed off) rejected the naive ".port file vs
# team-paths.json" comparison: neither file is ground truth, and on
# 2026-08-29 that exact comparison would have reported three HEALTHY
# freelance servers as drifted, because the *registry* was the stale side
# that day (a restore from a pre-XACA-0838 backup, not a bad write — see the
# decision doc's root-cause section). The pattern this script follows
# instead is the one already proven in this codebase for exactly this class
# of check: homebrew-tap/libexec/commands/aiteamforge-doctor.sh's
# check_lcars_port_drift() reads the ACTUAL BOUND PORT off the live
# server.py process (ps eww + its own LCARS_TEAM env var) rather than
# trusting either file. This script adopts that pattern, WITH TWO
# CORRECTIONS the decision doc requires (both from XACA-0998-002 §5):
#
#   Correction 1 — report divergence WITHOUT prescribing a direction. The
#   doctor pattern is not immune to the direction trap merely by reading the
#   live process: it still resolves "canonical" from the registry, so it can
#   (and on 2026-08-29 would have) FAILed healthy servers against a stale
#   registry, and its remediation text ("restart") would have RE-APPLIED the
#   wrong value. "Canonical" designates which source wins a TIE. It does not
#   establish which source is CORRECT right now. This script never says
#   "expected"/"canonical" and never suggests a restart, a --prefer mode, or
#   any other remediation that names a winning side — it states both values
#   with their provenance and stops. A human decides the direction.
#
#   Correction 2 — fail CLOSED, enumerated explicitly (never silently pass
#   as agreement):
#     - registry file missing or unreadable
#     - registry unparseable (not valid JSON, or no "teams" object)
#     - a live team is absent from the registry
#     - a live team's registry lcars_port is null/missing
#     - ZERO teams checked (no live LCARS server found at all) — a sweep
#       that examined nothing must not report "no problems found"; that is
#       the exact vacuous-green failure this whole ticket exists to close.
#       (Cf. MEMORY feedback_ci_green_needs_positive_run_count.md — and note
#       the doctor's OWN check_lcars_port_drift() has a "checked -eq 0"
#       branch that reports PASS; this script deliberately does the
#       opposite.)
#
# ── XACA-0803 REGRESSION GUARD (mandatory, tested) ─────────────────────────
# The XACA-0463 band allocator legitimately assigns a team the lowest FREE
# port in its declared [lcars_port_base, lcars_port_base + lcars_port_range)
# band, which is very often NOT the band base (e.g. finance-personal sits at
# 8361 while its band base is 8360 — both fields live directly on the
# team's registry entry). That is a CORRECT allocation, not drift.
# XACA-0803 fixed a real shipped bug where a different port-drift guard
# compared a resolved port against the band BASE instead of the team's
# actual assigned lcars_port, flagging every legitimately-banded team.
# This script avoids reintroducing that bug structurally, not by a separate
# band-membership check bolted on afterward: divergence here is defined as
# `bound_port != registry.teams[<team>].lcars_port` — the team's actual
# assigned port, never lcars_port_base. An in-band, non-base allocation
# whose live process is bound to exactly its assigned lcars_port is by
# construction not a finding. See the XACA-0803 negative-control test case
# in this ticket's test suite for a live demonstration.
#
# ── WHAT THIS SCRIPT DOES NOT DO ────────────────────────────────────────────
# - Never writes to .port, team-paths.json, or any other file.
# - Never restarts, rebinds, or "heals" anything.
# - Never recommends which source is correct.
# - Does not duplicate the separate, pre-existing band-membership WARN-only
#   check in scripts/lcars-launch-helpers.sh::_lcars_port_drift_guard()
#   Check-2 (registry port vs band). That is a different question
#   (misallocation vs. band) and XACA-0998-002 §5 explicitly says not to
#   merge the two checks.
#
# ── DEPENDENCIES ────────────────────────────────────────────────────────────
# jq (to parse team-paths.json) and the standard pgrep/ps. All three are on
# the fixed PATH of every LaunchAgent-style automation in this repo. Per the
# fail-closed rule above, a MISSING jq is treated the same as an unreadable
# registry — DIVERGENT/unverifiable, never a silent pass. No python3
# dependency: team-paths.json already carries lcars_port_base/
# lcars_port_range directly on each team entry (verified: XACA-0998-001
# §0), so no aiteamforge_paths.py import is needed for the comparison this
# script makes.
#
# ── USAGE ────────────────────────────────────────────────────────────────
#   scripts/kb-lcars-port-drift-check.sh [--registry PATH] [--verbose]
#
#   Exit 0 — one or more live LCARS teams were checked, all agree with the
#            registry.
#   Exit 1 — divergence found, OR any fail-closed condition triggered
#            (see Correction 2 above). Non-zero on purpose: this is a
#            report-and-alarm tool, not a reporter — "I could not tell" is
#            not "they agree" (XACA-0998-002 §5.1).
#
# Testing hook: pgrep/ps are looked up via PATH, so a test can prepend a
# directory with shim scripts of the same names ahead of the real ones
# (same technique as tests/test-xaca-0830-027-ps-snapshot-guard.sh's ps
# shim). --registry lets a test point at a scratch team-paths.json instead
# of the real ~/.aiteamforge/team-paths.json.

set -u

REGISTRY_PATH="${KB_LCARS_PORT_REGISTRY:-$HOME/.aiteamforge/team-paths.json}"
VERBOSE=0

usage() {
  cat <<'EOF'
Usage: kb-lcars-port-drift-check.sh [--registry PATH] [--verbose]

Detects divergence between live LCARS server processes' ACTUAL BOUND PORT
and ~/.aiteamforge/team-paths.json's configured lcars_port for that team.

Reports divergence without prescribing a direction — it does not know which
source is correct, and never suggests a remediation that picks one. Fails
CLOSED (non-zero exit) on a missing/unreadable/unparseable registry, a live
team absent from the registry, a null registry port, or zero teams checked.

Exit 0 = one or more teams checked, all agree.
Exit 1 = divergence found, or a fail-closed condition fired.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --registry)
      REGISTRY_PATH="${2:-}"
      shift 2
      ;;
    --registry=*)
      REGISTRY_PATH="${1#--registry=}"
      shift
      ;;
    --verbose|-v)
      VERBOSE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# ── Fail-closed guard 1: jq must be present ────────────────────────────────
# A missing parser means we cannot verify agreement at all. Per Correction 2,
# "cannot tell" is DIVERGENT, never a silent pass.
if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL-CLOSED: jq is not on PATH — cannot parse the port registry (${REGISTRY_PATH})." >&2
  echo "  Cannot verify agreement between live LCARS servers and the registry." >&2
  echo "  Treating as UNVERIFIED/DIVERGENT (fail closed) — never silently passing." >&2
  exit 1
fi

# ── Fail-closed guard 2: registry must exist and be readable ──────────────
if [ ! -f "$REGISTRY_PATH" ] || [ ! -r "$REGISTRY_PATH" ]; then
  echo "FAIL-CLOSED: port registry not found or unreadable at ${REGISTRY_PATH}." >&2
  echo "  Cannot verify agreement between live LCARS servers and the registry." >&2
  echo "  Treating as UNVERIFIED/DIVERGENT (fail closed) — never silently passing." >&2
  exit 1
fi

# ── Fail-closed guard 3: registry must parse and have a "teams" object ────
if ! jq -e 'type == "object" and has("teams") and (.teams | type == "object")' \
      "$REGISTRY_PATH" >/dev/null 2>&1; then
  echo "FAIL-CLOSED: port registry at ${REGISTRY_PATH} is unparseable, or has no 'teams' object." >&2
  echo "  Cannot verify agreement between live LCARS servers and the registry." >&2
  echo "  Treating as UNVERIFIED/DIVERGENT (fail closed) — never silently passing." >&2
  exit 1
fi

# ── Sweep live LCARS servers ────────────────────────────────────────────────
# Mirrors aiteamforge-doctor.sh::check_lcars_port_drift()'s detection: every
# LCARS server is launched as `env LCARS_TEAM=<team> ... <python> server.py
# <PORT>`. Read each live server.py's argv+env via `ps eww`, pull the team
# from LCARS_TEAM= and the bound port from the token after "server.py ".
#
# `pgrep -f` returns exit 1 (and empty stdout) when nothing matches; the
# `|| true` keeps `set -u`-only mode (no set -e here) from being an issue,
# and keeps the empty-result case flowing into the zero-checked guard below
# rather than aborting.
pids="$(pgrep -f 'server\.py' 2>/dev/null || true)"

checked=0
divergent=0

for pid in $pids; do
  [ -z "$pid" ] && continue
  args="$(ps eww -o args= -p "$pid" 2>/dev/null || true)"
  [ -z "$args" ] && continue

  # Only LCARS servers carry LCARS_TEAM in their env (no spaces in a team id).
  case "$args" in
    *" LCARS_TEAM="*) ;;
    *) continue ;;
  esac
  team="${args##* LCARS_TEAM=}"
  team="${team%%[[:space:]]*}"
  [ -z "$team" ] && continue

  # Bound port = the first integer token immediately after "server.py ".
  bound_port="${args#*server.py }"
  bound_port="${bound_port%%[![:digit:]]*}"
  [ -z "$bound_port" ] && continue

  checked=$((checked + 1))

  team_present="$(jq -r --arg t "$team" '(.teams | has($t))' "$REGISTRY_PATH" 2>/dev/null)"
  if [ "$team_present" != "true" ]; then
    echo "FAIL: team '${team}' has a live LCARS server (bound port ${bound_port}) but is ABSENT from the registry (${REGISTRY_PATH})." >&2
    echo "  This is reported as-is, without a recommendation — the registry may be the stale side (see XACA-0998-002 §1)." >&2
    divergent=$((divergent + 1))
    continue
  fi

  reg_port="$(jq -r --arg t "$team" '.teams[$t].lcars_port // "null"' "$REGISTRY_PATH" 2>/dev/null)"
  if [ -z "$reg_port" ] || [ "$reg_port" = "null" ]; then
    echo "FAIL: team '${team}' has a live LCARS server (bound port ${bound_port}) but its registry lcars_port is null/missing (${REGISTRY_PATH})." >&2
    divergent=$((divergent + 1))
    continue
  fi

  if [ "$bound_port" != "$reg_port" ]; then
    echo "DIVERGENCE: team '${team}' — live process is bound to port ${bound_port}; the registry (${REGISTRY_PATH}) has lcars_port=${reg_port}." >&2
    echo "  The sources disagree. This check does not know which is correct — investigate before acting on either value." >&2
    divergent=$((divergent + 1))
  elif [ "$VERBOSE" = "1" ]; then
    echo "OK: team '${team}' bound port ${bound_port} matches the registry."
  fi
done

# ── Fail-closed guard 4: zero teams checked ────────────────────────────────
# The easiest guard to get wrong, and the one this ticket names explicitly:
# an empty result set must never read as "no divergence found".
if [ "$checked" -eq 0 ]; then
  echo "FAIL-CLOSED: zero LCARS teams were checked (no live server.py process carrying LCARS_TEAM was found)." >&2
  echo "  A sweep that examined nothing must not report agreement — treating as UNVERIFIED/DIVERGENT, never pass." >&2
  exit 1
fi

if [ "$divergent" -gt 0 ]; then
  echo "RESULT: ${divergent} of ${checked} live LCARS team(s) show port divergence between the live process and the registry." >&2
  exit 1
fi

echo "RESULT: ${checked} live LCARS team(s) checked — all agree between the live process and the registry."
exit 0
