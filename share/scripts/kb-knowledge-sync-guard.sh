#!/usr/bin/env bash
# kb-knowledge-sync-guard.sh
#
# SessionStart hook — surfaces whether this machine's knowledge-sync
# LaunchAgent is installed/loaded AND whether ~/knowledge is actually
# staying in sync (ahead/behind + dirty/stalled), plus whether there is any
# positive evidence the agent has ever actually run.
#
# XACA-1259-005: closed the "detector nobody calls" gap identified in the
# ticket's design doc (kanban/XACA-1259_scheduler_design.md § 2.1, § 3.2) —
# `generate-launchagents.py --check` already detected a NOT-INSTALLED
# condition, but nothing in the repo ever invoked it, and its exit code was
# masked by an unrelated drift finding besides. This hook is the real entry
# point 005 gave that detector.
#
# XACA-1259-007 extended the underlying script (NOT this wrapper — see
# design doc § 9 "one surface, two checks") with a second, independent
# check: is ~/knowledge diverged from its upstream, or dirty? At the time
# this was written, ANY dirty tree GUARANTEED kb-knowledge-sync.sh no-opped
# indefinitely, since it never stashes a human's in-flight work — measured
# live on M4Mini (loaded agent, 2 commits behind, dirty tree, no sync log
# at all). That guarantee no longer holds (XACA-1266): the daemon now
# fetches unconditionally and converges a dirty-but-not-diverged tree via
# `git merge --ff-only`, so a dirty tree alone does NOT by itself mean it
# cannot RECEIVE. As of XACA-1291 it does not mean it cannot SEND either:
# the daemon auto-commits allowlisted, complete, quiescent entries from a
# private index and pushes whenever ahead>0 and behind==0, dirty or clean.
# The one dirty shape that still genuinely blocks receiving — and, for the
# same reason (a fast-forward is impossible until a human resolves it),
# blocks sending too — is dirty AND diverged (local commits ahead AND
# behind); that still gets the loud STALLED/STRANDED treatment below. A
# machine can still be installed, loaded, firing every 30 minutes, and
# unable to converge — read apart, either
# check alone can support a wrong conclusion; read together they are
# diagnostic. This wrapper needed NO changes to carry any of that — it
# already treats any non-zero exit as "not confirmed healthy" and prints
# the script's own output verbatim, which now covers both checks (plus a
# third: run evidence).
#
# Thin wrapper — ALL detection logic lives in
# scripts/kb-knowledge-sync-health-check.sh, which is independently callable
# with real exit codes for direct/CI use (exit 0 = confirmed healthy, 1 = a
# confirmed problem, 2 = ambiguous/no run evidence only — see that script's
# own header). This wrapper only:
#   1. Runs that script on every session start. Its checks are per-MACHINE
#      (launchd + ~/Library/LaunchAgents + the local ~/knowledge clone),
#      identical from any repo checkout or worktree — so, like
#      kb-lcars-port-drift-guard.sh, this hook is NOT scope-guarded to the
#      main repo. It NEVER passes --fleet (that mode does a bounded ssh
#      round-trip per fleet host and is manual/CI-only — it does not fit a
#      SessionStart hook's <5s budget).
#   2. Translates a non-zero exit into human-visible output, SCALED to what
#      the exit code actually means: rc=1 (a confirmed problem) gets the
#      full boxed banner; rc=2 (AMBIGUOUS — everything else confirmed
#      healthy, only run-evidence unresolved, the ORDINARY post-reboot
#      state) gets one unobtrusive line, never the alarm treatment — see
#      the inline comment at that branch for the full reasoning.
#   3. NEVER blocks the session — same house rule as every other guard hook
#      in this directory (aiteamforge-stub-guard.sh,
#      kb-lcars-port-drift-guard.sh, kb-live-config-drift-guard.sh):
#      warning-only, ALWAYS exits 0.
#
# NEVER auto-remediates — a human decides whether and how to install or
# reconcile. In particular this hook never stashes, commits, or pushes
# anyone's ~/knowledge.
#
# Reference: kanban/XACA-1259_scheduler_design.md § 4 Part C, § 9.
#
# XACA-1259-008 QA finding A: this wrapper had ZERO automated coverage —
# every existing assertion invoked scripts/kb-knowledge-sync-health-check.sh
# directly, and nothing in the repo ever invoked this file. That is exactly
# the XACA-0991/XACA-0297 "check nobody calls" shape, just one hop further
# down the chain: the DETECTOR had a caller (this wrapper), but the CALLER
# had no test proving it actually renders the warning block / stays silent
# / never exits non-zero, for every exit code the detector can produce.
# $KB_KNOWLEDGE_SYNC_GUARD_CHECK_SCRIPT lets a test point this wrapper at a
# disposable STUB script instead of the real detector, so the WRAPPER's own
# contract (warning rendering + the never-block-the-session guarantee) can
# be exercised in isolation from the detector's actual git/launchctl logic
# — see tests/test-xaca-1259-knowledge-sync-guard.sh. Unset in any real
# session, so production behavior (always the real health-check script) is
# unchanged.
# XACA-1753: shared root resolver (sibling of this hook in every layout).
_AITF_SELF="${BASH_SOURCE[0]:-$0}"
_AITF_SELF="$(readlink -f "$_AITF_SELF" 2>/dev/null || printf '%s' "$_AITF_SELF")"
_AITF_LIB="$(dirname "$_AITF_SELF")/aitf-root.sh"
if [ -f "$_AITF_LIB" ]; then
    . "$_AITF_LIB"
else
    echo "knowledge-sync: could not check: aitf-root.sh not found (looked in $_AITF_LIB)"
    exit 0
fi
aitf_init "$_AITF_SELF"
CHECK_SCRIPT="${KB_KNOWLEDGE_SYNC_GUARD_CHECK_SCRIPT:-}"
[ -n "$CHECK_SCRIPT" ] || { aitf_locate scripts/kb-knowledge-sync-health-check.sh; CHECK_SCRIPT="$AITF_FOUND"; }

# Silent no-op if the check script isn't present at the expected canonical
# location (e.g. a machine that hasn't pulled this change yet) — never error
# a session over a missing optional diagnostic.
#
# XACA-1753 SUPERSEDES the "silent no-op" decision below: the silence was the
# defect (ai-sol ran with this guard registered, detector unreachable, and no
# signal). The text below is kept as history of the earlier decision.
# XACA-1259-008 CONSIDER item, DECLINED: a reviewer flagged this silence as
# worth reconsidering (a missing detector produces no signal that it's
# missing). Declined rather than fixed: this is the same convention EVERY
# guard hook in this directory shares (aiteamforge-stub-guard.sh,
# kb-lcars-port-drift-guard.sh, kb-live-config-drift-guard.sh,
# kb-team-registry-loss-guard.sh) — special-casing this one hook to warn on
# its own absence would be an inconsistency, not an improvement, and would
# need its own justification for why THIS detector's absence deserves
# louder treatment than every sibling's. Covered by
# tests/test-xaca-1259-knowledge-sync-guard.sh CASE6 (missing script ->
# silent no-op, asserted explicitly, not merely unexercised).
if [ -z "$CHECK_SCRIPT" ] || { [ ! -x "$CHECK_SCRIPT" ] && [ ! -f "$CHECK_SCRIPT" ]; }; then
    # XACA-1753: no longer silent. A missing detector must say so (fail visible);
    # the old silent exit was a fail-open all-clear on any machine whose root
    # was not the legacy checkout. Unboxed one-liner, still exit 0 (never block).
    echo "knowledge-sync: could not check: kb-knowledge-sync-health-check.sh not found (looked in ${CHECK_SCRIPT:-$AITF_LOOKED})."
    exit 0
fi

OUTPUT="$(bash "$CHECK_SCRIPT" 2>&1)"
RC=$?

if [ "$RC" -eq 0 ]; then
    exit 0
fi

# XACA-1259-008 THIRD round finding 1: rc=2 (AMBIGUOUS) used to fall
# through to the exact same full-width "DID NOT CONFIRM HEALTHY" banner as
# rc=1 (a confirmed problem) — this wrapper had built three distinct lanes
# into the underlying script and then collapsed them back to two at the
# ONE surface a human actually reads every session.
#
# By construction of scripts/kb-knowledge-sync-health-check.sh's own
# main() (see its header), rc=2 can ONLY happen when every other check —
# scheduler installed/loaded, sync state, dirty/stalled, and (in --fleet
# mode, never used by this hook) every probed host's core tokens — is
# ALREADY confirmed healthy, and the sole open question is run evidence
# (no /tmp/knowledge-sync.log found). /tmp clears on reboot, so this is the
# ORDINARY state of a healthy, recently-rebooted machine, not a finding —
# it will recur every session until the agent's next scheduled run writes
# a fresh log, which on the default 30-minute interval could be most of a
# session. A guard that shouts the full alarm for that every time is the
# EXACT cry-wolf shape already fixed twice elsewhere in this ticket (the
# aiteamforge-namespace false alarm on M3Pro; the fleet allowlist counting
# RUN=UNKNOWN hosts as problems) — and this ticket exists in the first
# place because an accurate signal got tuned out from being ignored.
#
# THE LOAD-BEARING REASON THIS QUIET RENDERING IS SAFE (round 4, item 3 —
# do not lose this): rc=2 is SELF-LIMITING, not merely benign. An agent
# that never actually fires never refreshes its own FETCH_HEAD, and
# check_sync_divergence's OWN freshness gate (scripts/kb-knowledge-sync-
# health-check.sh, the SYNC_CACHE_STALE_SECONDS comparison, default 3600s)
# escalates a machine whose cache has not been refreshed within that
# window from AMBIGUOUS straight to a confirmed STALE-CACHE PROBLEM — rc=1
# — which DOES get the full banner. So the quiet lane cannot structurally
# swallow a DURABLE failure (an agent that is actually broken, not merely
# quiet since the last reboot): it can only defer a TRANSIENT one, and
# only for at most SYNC_CACHE_STALE_SECONDS (one hour, by default). This
# bound is WHY quiet-by-default is safe here at all, and it means two
# things for anyone touching this later: (1) do not "fix" the quiet
# rendering back into an alarm on the theory that rc=2 might be hiding a
# real problem indefinitely — it structurally cannot, past the bound; and
# (2) do not raise SYNC_CACHE_STALE_SECONDS without re-deriving this
# argument — a much longer window widens exactly the blind spot this
# paragraph claims does not exist.
#
# Chosen shape: ONE unobtrusive, unboxed, un-ALARMED line — informative
# for anyone reading session output closely, easy to visually filter out
# for everyone else, and specifically NOT sharing any visual weight with
# the rc=1 banner below (no box-drawing border, no all-caps "WARNING",
# no blank-line padding). Deliberately does NOT embed $OUTPUT verbatim
# (unlike the rc=1 banner) — by construction there is nothing alarming in
# it to show, and printing scheduler/sync-state detail here would still
# read as "something to look at" even in a single line. A reader who wants
# the detail is pointed at --verbose. This keeps the hook's contract
# intact: still always exits 0, still never blocks the session, still
# never auto-remediates.
if [ "$RC" -eq 2 ]; then
    echo "knowledge-sync: run evidence not yet confirmed (ambiguous, not a problem — everything else checked out healthy; see scripts/kb-knowledge-sync-health-check.sh --verbose for detail)."
    exit 0
fi

# XACA-1753-002: the remediation differs by machine role, and neither form may
# hardcode a checkout path. A dev tree ships scripts/generate-launchagents.py
# (installs com.devteam.knowledge-sync); a tap consumer does not ship it, and
# its com.aiteamforge.knowledge-sync agent is (re)created by `aiteamforge
# upgrade` (homebrew-tap libexec/lib/launchagents.sh registry row
# "com.aiteamforge.knowledge-sync.plist ... aiteamforge upgrade", and
# aiteamforge-upgrade.sh "Updating knowledge-sync LaunchAgent"). `aiteamforge
# doctor` reports the same agent's state without changing anything.
if aitf_locate scripts/generate-launchagents.py; then
    _GLA_ROOT="$(cd "$(dirname "$AITF_FOUND")/.." 2>/dev/null && pwd)"
    INSTALL_HINT="Dev machine: from the MAIN repo (not a worktree), without
      --reload: cd ${_GLA_ROOT:-<dev checkout>} && python3 scripts/generate-launchagents.py --install"
else
    INSTALL_HINT="AITeamForge consumer: run 'aiteamforge upgrade' (it re-creates the
      com.aiteamforge.knowledge-sync LaunchAgent when ~/knowledge is a git clone;
      'aiteamforge doctor' reports its state). Sync log:
      ${AITEAMFORGE_DIR:-$HOME/aiteamforge}/logs/knowledge-sync.log"
fi

cat <<WARNING

================================================================================
  WARNING: KNOWLEDGE-SYNC HEALTH CHECK DID NOT CONFIRM HEALTHY
================================================================================

  scripts/kb-knowledge-sync-health-check.sh checks FOUR independent things
  on this machine: (1) is a knowledge-sync LaunchAgent installed and loaded,
  in either namespace; (2) is ~/knowledge actually converged with its
  upstream (not diverged, not dirty/stalled); (3) is there positive evidence
  the agent has ever actually run; (4) does the daemon's own persisted (d)
  stall counter (its notify state file) show it converging normally. It
  reported the following (verbatim):

${OUTPUT}

  WHAT THIS DOES NOT MEAN: an "installed+loaded" line by itself is NOT proof
  that syncing is actually happening — the sync script exits 0 on a held
  lock, a mid-rebase, a rejected push, or missing auth without converging.
  A dirty tree ALONE no longer means it isn't syncing (XACA-1266): it still
  fetches and fast-forwards inbound. Nor does it mean it cannot SEND
  (XACA-1291): the daemon auto-commits COMPLETE, quiescent knowledge entries
  and pushes whenever it is 0 behind, dirty or clean. Whether this machine is
  actually sending is the OUTBOUND half of the notify lane:
  NOTIFY-STATE-OUTBOUND-STUCK means entries have been withheld for ~a day (or
  a hook refused / is broken), and NOTIFY-STATE-OUTBOUND-UNKNOWN means the
  daemon predates outbound reporting. Only dirty AND diverged by a commit
  that is not the daemon's own blocks RECEIVING too, and that is exactly
  what the STALLED/STRANDED lines above report. Likewise, "RUN EVIDENCE: unknown" and "NOTIFY-STATE-UNKNOWN"
  are both AMBIGUOUS, not confirmed failures — neither by itself means the
  agent never ran or never converged (a state file absent right after this
  machine upgraded to the XACA-1266 daemon is EXPECTED, not a finding, until
  it persists past one sync interval).

  DO NOT SELF-REMEDIATE blindly.
    - Not installed/loaded? ${INSTALL_HINT}
    - Dirty/stalled ~/knowledge? The knowledge-sync DAEMON auto-commits
      only complete, quiescent entries (never a stub, a file still being
      edited, or one marked <!-- knowledge-sync: hold -->); everything else
      is a human's uncommitted work. THIS guard hook still never stashes,
      commits, or pushes anything. Finish or remove what is held (grep
      autocommit-held in the sync log), then the next run resumes syncing.
    - Diverged (ahead/behind)? Investigate before assuming a direction —
      inspect with: scripts/kb-knowledge-sync-health-check.sh --verbose
      For a fleet-wide picture (manual/CI only — not run by this hook):
      scripts/kb-knowledge-sync-health-check.sh --fleet

  Reference: kanban/XACA-1259_scheduler_design.md § 4 Part C, § 9

================================================================================

WARNING

exit 0
