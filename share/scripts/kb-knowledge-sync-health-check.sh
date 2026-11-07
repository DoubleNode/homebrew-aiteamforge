#!/usr/bin/env bash
# scripts/kb-knowledge-sync-health-check.sh
#
# XACA-1259-005/007: DETECTION for the knowledge-sync LaunchAgent's
# installation AND divergence state on this machine (and, in --fleet mode,
# a best-effort read of other fleet machines).
#
# ── WHY THIS EXISTS ─────────────────────────────────────────────────────────
# XACA-1259's design doc (kanban/XACA-1259_scheduler_design.md § 3.2) found
# that `python3 scripts/generate-launchagents.py --check` already detects a
# MANIFEST entry that is not installed, but (a) nothing in the repo ever
# calls `--check` (a check nobody runs is dead code — XACA-0991/XACA-0297),
# and (b) until this ticket's C1 fix, a NOT-INSTALLED finding for
# knowledge-sync was masked behind an unrelated `kanban-health` drift's exit
# code — the correct answer for the wrong reason, which would have INVERTED
# to a false green the moment that unrelated drift was reconciled. This
# script gives the detector a real caller with its own meaningful exit code,
# independent of `--reload`-only issues like the kanban-health drift.
#
# ── 005 vs 007 — TWO INDEPENDENT CHECKS, ONE SCRIPT ─────────────────────────
# Per the design doc § 9: "installed" alone is NOT evidence that syncing is
# actually happening — kb-knowledge-sync.sh exits 0 on a held lock, a
# mid-rebase, a rejected push, or missing auth without ever converging.
# Read together the two checks below are diagnostic; read apart, each can
# support a wrong conclusion:
#   - "installed, no divergence check" reads a false green when the agent is
#     loaded, firing every 30 min, and genuinely stuck (e.g. diverged while
#     dirty — see check_sync_divergence below).
#   - "divergence check, no install check" on a machine that never installed
#     the agent at all reports "N behind" and points the reader at the fork
#     (the SYMPTOM) while the actual CAUSE — an agent that was never
#     installed or scheduled — stays invisible. That is this ticket's entire
#     history: the fork was noticed, its cause was not.
#
# check_scheduler_installed (005)  — is a knowledge-sync LaunchAgent
#   installed AND loaded, in EITHER namespace: com.devteam.* (the dev
#   machine, M3Pro) or com.aiteamforge.* (tap-installed fleet consumers,
#   M1Pro/M4Mini/M1Mini). Checking only one namespace would misreport on
#   whichever machine legitimately uses the other one.
#
# check_sync_divergence (007) — is this machine's ~/knowledge ahead/behind
#   its upstream, and is it DIRTY? As of XACA-1266, kb-knowledge-sync.sh
#   fetches unconditionally and converges a dirty-but-not-diverged tree via
#   `git merge --ff-only` — so a dirty tree ALONE no longer means the
#   machine can't receive. As of XACA-1291, dirty alone doesn't mean it
#   can't SEND either: the daemon auto-commits allowlisted (agents/,
#   subjects/, teams/), complete, quiescent entries from a private index
#   and pushes whenever ahead>0 and behind==0 — dirty or clean,
#   unconditionally (see kb-knowledge-sync.sh's header comment). The one
#   thing a dirty tree ALONE still withholds outbound on is being BEHIND:
#   auto-commit and push both require 0 behind (precondition P3), so a
#   dirty tree that is also behind waits for the next ff-only fetch to
#   resolve that before it can send. Dirty AND diverged (local commits
#   ahead AND behind, making a fast-forward impossible) is the one shape
#   that genuinely blocks RECEIVING too, and still gets the loudest
#   (STALLED/STRANDED) signal — it blocks SENDING too, for the same
#   behind>0 (or mid-rebase) reason, never because the tree is dirty.
#   Reads CACHED remote-tracking refs only — see the <5s budget note below.
#   A "0 ahead, 0 behind" reading is trusted ONLY if the cache was refreshed
#   recently (`.git/FETCH_HEAD` mtime younger than a threshold) — never
#   reports "in sync" off a cache nobody has refreshed in a long time.
#
# check_run_evidence (007) — is there any positive evidence the agent has
#   EVER actually executed (a non-empty /tmp/knowledge-sync.log with at
#   least one `[kb-knowledge-sync]` line)? "installed+loaded" from launchctl
#   is NOT such evidence — launchctl only reports the job is registered to
#   run, not that it has. An ABSENT log is reported as UNKNOWN/ambiguous,
#   never as a confirmed pass OR a confirmed failure: /tmp clears on reboot,
#   so absence does not prove the agent never ran. (Measured live on
#   M4Mini during this ticket: a correctly-loaded agent with NO log at all.)
#
# ── FAIL-CLOSED, NOT PRESENCE-ONLY ──────────────────────────────────────────
# Every check below fails CLOSED: an unreadable answer (missing launchctl,
# missing/unparseable git state, an unresolvable upstream, an unreachable
# fleet host) is reported as a finding, never silently treated as healthy.
# See house precedent: scripts/kb-lcars-port-drift-check.sh.
#
# ── THE <5s SESSIONSTART BUDGET (XACA-1259 design doc § 9's constraint) ────
# check_sync_divergence NEVER fetches. It reads `@{u}` — the LOCAL cached
# remote-tracking ref left by the last fetch/pull/push kb-knowledge-sync.sh
# (or a human) actually performed — via `git rev-list --left-right --count`.
# That is a local, in-repo, sub-millisecond operation with no network
# round-trip, so it is safe to run from claude-hooks/kb-knowledge-sync-
# guard.sh on every session start. It can therefore be STALE (if nothing has
# fetched recently) but it can never hang. --fleet mode is the opposite
# trade: it DOES leave the machine (one ssh round-trip per host, bounded by
# ConnectTimeout), so it is a manual/CI invocation only and is NEVER called
# by the SessionStart guard — seconds-to-tens-of-seconds latency there would
# blow the budget on a slow network or an unreachable host.
#
# ── USAGE ────────────────────────────────────────────────────────────────
#   scripts/kb-knowledge-sync-health-check.sh [--verbose]
#       Local-machine check only (installed + divergence + run evidence).
#       Safe for a SessionStart hook: no network access, no fetch.
#
#   scripts/kb-knowledge-sync-health-check.sh --fleet [--fleet-hosts "h1 h2"]
#       ADDITIONALLY probes other fleet machines over ssh (one round-trip
#       per host, `-o BatchMode=yes -o ConnectTimeout=8`). An unreachable
#       host is reported as UNKNOWN, never as converged. Default host list
#       is $KB_KNOWLEDGE_SYNC_FLEET_HOSTS if set, else a small built-in
#       list of known fleet machines (see FLEET_HOSTS_DEFAULT below) — pass
#       --fleet-hosts explicitly once a new machine (e.g. M1Mini, XACA-
#       1259-006) has its own sync agent provisioned. Manual/CI use only —
#       never invoked by claude-hooks/kb-knowledge-sync-guard.sh.
#
# Env var overrides (all optional):
#   KB_KNOWLEDGE_REPO                    Path to the local ~/knowledge clone
#                                         (default: $HOME/knowledge). Same
#                                         var name kb-knowledge-sync.sh uses.
#   KB_KNOWLEDGE_SYNC_LOG_PATH            Path to the sync log (default:
#                                         /tmp/knowledge-sync.log, matching
#                                         the plist's StandardOutPath).
#   KB_KNOWLEDGE_SYNC_LAUNCH_AGENTS_DIR   Override ~/Library/LaunchAgents
#                                         (testability).
#   KB_KNOWLEDGE_SYNC_FLEET_HOSTS         Space-separated ssh host list for
#                                         --fleet mode.
#   KB_KNOWLEDGE_SYNC_STATE_FILE          Path to the (d)-notify state file
#                                         kb-knowledge-sync.sh writes
#                                         (default: $HOME/.aiteamforge/run/
#                                         knowledge-sync-state.json). SAME
#                                         env var / default the daemon
#                                         computes — see check_notify_state
#                                         below and design doc XACA-1266-003
#                                         §4.4/§10.
#
# Exit codes:
#   0 — everything checked is confirmed healthy (installed+loaded in some
#       namespace, not diverged, not dirty, run evidence found, and notify
#       state present/parseable/below threshold).
#   1 — a CONFIRMED problem: not installed/loaded in any namespace, diverged
#       (ahead and/or behind), dirty/mid-rebase (stalled), notify state file
#       present but unparseable, notify state at/past its stall threshold
#       (inbound, or — XACA-1291 — the OUTBOUND withheld counter),
#       or any other fail-closed condition (missing launchctl, unreadable
#       repo state, no upstream configured, an unreachable --fleet host).
#   2 — AMBIGUOUS only: every confirmed check is healthy, but run evidence
#       is absent (no log found) and/or the notify state file is absent
#       (daemon has not completed a tick since upgrading to it yet), or the
#       file lacks the XACA-1291 outbound fields (written by an older daemon
#       — NOTIFY-STATE-OUTBOUND-UNKNOWN). Not a
#       pass, not a confirmed failure — see check_run_evidence and
#       check_notify_state above. This code is distinct from 1 specifically
#       so a caller can tell "definitely broken" from "cannot fully confirm".
#  64 — USAGE ERROR (EX_USAGE, same sysexits.h convention kb-knowledge-
#       sync.sh already uses for its own usage-error path): an unrecognized
#       command-line flag. XACA-1259-008: previously shared exit code 2
#       with AMBIGUOUS, so a caller could not distinguish "you typed a bad
#       flag" from "detection ran fine but is inconclusive" — split apart
#       since nothing about the two conditions is otherwise related.
#
# This script never writes anything — detection only. It never invokes
# `generate-launchagents.py --install`, `git`  mutating commands, or any
# other remediation; a human (or an explicit, separate step) decides
# whether and how to install or reconcile.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
LABEL_DEVTEAM="com.devteam.knowledge-sync"
LABEL_AITEAMFORGE="com.aiteamforge.knowledge-sync"
LAUNCH_AGENTS_DIR="${KB_KNOWLEDGE_SYNC_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
KNOWLEDGE_REPO_DIR="${KB_KNOWLEDGE_REPO:-$HOME/knowledge}"
SYNC_LOG_PATH="${KB_KNOWLEDGE_SYNC_LOG_PATH:-/tmp/knowledge-sync.log}"
# XACA-1753-002: the tap-installed com.aiteamforge.knowledge-sync agent logs to
# <AITEAMFORGE_DIR>/logs/knowledge-sync.log (its plist's {{LOG_DIR}}), not
# /tmp. When the caller did not pin a path and the dev-job /tmp log has no
# evidence, use the consumer log if it has some; otherwise run evidence would
# be permanently "unknown" on every consumer.
if [ -z "${KB_KNOWLEDGE_SYNC_LOG_PATH:-}" ] && [ ! -s "$SYNC_LOG_PATH" ] \
   && [ -s "${AITEAMFORGE_DIR:-$HOME/aiteamforge}/logs/knowledge-sync.log" ]; then
  SYNC_LOG_PATH="${AITEAMFORGE_DIR:-$HOME/aiteamforge}/logs/knowledge-sync.log"
fi
# Same env var / default kb-knowledge-sync.sh itself computes for its (d)
# notify state file (design doc XACA-1266-003 §4.4/§10) — deliberately NOT
# derived from SYNC_LOG_PATH above, for the same reason the daemon's own
# comment gives: the log path is plist-assigned per host and not knowable
# from either side, while this path is the SAME formula everywhere.
NOTIFY_STATE_FILE="${KB_KNOWLEDGE_SYNC_STATE_FILE:-$HOME/.aiteamforge/run/knowledge-sync-state.json}"
# Small, known-good default. Deliberately does NOT include M1Mini — its
# sync agent is being provisioned concurrently by sibling subitem XACA-1259-
# 006 as this is written, and its hostname/namespace are not yet a settled
# fact this script should hardcode. Pass --fleet-hosts (or the env var)
# explicitly to include it once provisioned.
FLEET_HOSTS_DEFAULT="darren-m1pro-mbp darren-m4-mini"
VERBOSE=0
FLEET=0
TEST_FLEET_PROBE_LOCAL=0
FLEET_HOSTS="${KB_KNOWLEDGE_SYNC_FLEET_HOSTS:-$FLEET_HOSTS_DEFAULT}"

usage() {
  cat <<'EOF'
Usage: kb-knowledge-sync-health-check.sh [--verbose] [--fleet] [--fleet-hosts "h1 h2"]

Detects, for the LOCAL machine:
  1. SCHEDULER   — is a knowledge-sync LaunchAgent installed AND loaded, in
                   EITHER namespace (com.devteam.* or com.aiteamforge.*)?
  2. SYNC STATE  — is ~/knowledge ahead/behind its upstream (cached refs, no
                   fetch)? Dirty alone (XACA-1266) no longer stalls inbound
                   sync — only dirty-AND-diverged (STALLED/STRANDED) does;
                   outbound (push) stays blocked by any dirty tree, always.
  3. RUN EVIDENCE — is there positive evidence the agent has ever actually
                   executed (a non-empty sync log)? Absence is reported as
                   UNKNOWN, never as pass or confirmed failure.
  4. NOTIFY STATE — the daemon's own persisted (d) stall counter
                   (XACA-1266 §4.4): ABSENT is UNKNOWN (expected briefly
                   after upgrading to the new daemon, never a pass), a
                   PRESENT-but-unparseable file is a confirmed problem
                   (never benign), and a PRESENT/parseable file at or past
                   its own stall threshold is a confirmed problem (the
                   daemon reporting it cannot converge, in its own words).

With --fleet, ALSO probes other fleet machines over ssh (one round-trip per
host, bounded timeout). An unreachable host is reported as UNKNOWN, never as
converged. --fleet is a manual/CI-only mode; it is never invoked by the
SessionStart guard (network round-trips do not fit its <5s budget). --fleet
does NOT probe notify state (item 4) — that check is local-only.

Every check fails CLOSED: an unreadable answer is a finding, never a
silent pass. Detection only — never installs, fetches, or remediates.

Exit 0 = everything confirmed healthy.
Exit 1 = a confirmed problem (not scheduled, diverged, stalled/dirty, an
         unparseable or past-threshold notify state file, or any other
         fail-closed condition, including an unreachable --fleet host).
Exit 2 = ambiguous only: everything else healthy, but no run evidence
         and/or no notify state file found yet.
Exit 64 = usage error (unrecognized flag) — EX_USAGE, distinct from the
          AMBIGUOUS 2 above.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --verbose|-v)
      VERBOSE=1
      shift
      ;;
    --fleet)
      FLEET=1
      shift
      ;;
    --fleet-hosts)
      # XACA-1259-008 finding 4: `shift 2` when `--fleet-hosts` is the FINAL
      # argument ($#=1, no value follows) does not decrement $# at all —
      # neither bash nor zsh shifts past the end of the positional params
      # (zsh additionally prints "shift count must be <= $#" to stderr, but
      # neither shell treats it as fatal) — so $1 stays "--fleet-hosts"
      # forever and this `while [ $# -gt 0 ]` loop spins on the same case
      # arm indefinitely. Measured: rc=124 (timeout) under both shells,
      # zero output under bash, ~100K+ repeated error lines/second under
      # zsh. `${2:-}` already degrades correctly to an empty FLEET_HOSTS
      # when no value follows (matched below by run_fleet_check's own
      # "no hosts configured" guard) — the missing piece was only ever
      # guaranteeing forward progress through the argument list, which this
      # now does explicitly rather than assuming two args are always there.
      FLEET_HOSTS="${2:-}"
      if [ "$#" -ge 2 ]; then
        shift 2
      else
        shift 1
      fi
      ;;
    --fleet-hosts=*)
      FLEET_HOSTS="${1#--fleet-hosts=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --__test-fleet-probe-local)
      # Internal, undocumented (deliberately omitted from usage()): runs the
      # exact --fleet remote probe script locally via `bash -c`, no ssh/
      # network involved, so the test suite can exercise the freshness-gate
      # logic against a disposable fixture with no real fleet dependency.
      # Never use this in a hook or in production — it exists only so
      # tests/test-xaca-1259-007-knowledge-sync-divergence-check.sh can
      # assert on the probe's own output without needing ssh access.
      TEST_FLEET_PROBE_LOCAL=1
      shift
      ;;
    *)
      # XACA-1259-008 CONSIDER item (reviewer's unfiled observation, judged
      # cheap+low-risk, fixed): exit 2 was overloaded between "usage error"
      # (an unrecognized flag) and "AMBIGUOUS" (a fully successful run whose
      # only unresolved question is run evidence) — a caller could not tell
      # them apart from the exit code alone. 64 is EX_USAGE, the same
      # sysexits.h convention kb-knowledge-sync.sh already uses for its own
      # sole usage-error path; AMBIGUOUS keeps exit 2.
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

# ── check_scheduler_installed (005, extended in 007 for EITHER namespace) ──
# Reports on its own, independent of the other checks. Sets $SCHEDULER_OK
# ("1"/"0").
#
# XACA-1259-007 fix (coordinator finding 1, false alarm on M3Pro): on the
# dev machine, com.aiteamforge.* MUST NOT exist (XACA-0212) — that is the
# CORRECT state, not a finding. The original cut probed both labels and
# printed each losing label's NOT-INSTALLED/NOT-LOADED diagnostics
# unconditionally, so a perfectly healthy com.devteam.*-only machine still
# printed two lines that read as problems ("NOT-INSTALLED:
# com.aiteamforge.knowledge-sync.plist does not exist."). A guard that
# cries wolf on a correct configuration trains people to ignore it — the
# exact way kb-live-config-drift-guard.sh died (see HOOKS-STATUS.md). Fix:
# capture each label's diagnostics instead of letting them print directly;
# only surface them (both, since the reader needs to know both were
# checked) when NEITHER namespace is healthy. When one namespace IS
# healthy, say which and stay silent about the other — its diagnostics are
# discarded, not merely suppressed from a log level.
SCHEDULER_OK=0
SCHEDULER_WINNING_LABEL=""

_kb_label_installed_and_loaded() {
  # $1 = label, $2 = "1" to also require the canonical repo-tracked plist
  # (only meaningful for com.devteam.*, whose plist is repo-tracked; the
  # aiteamforge plist is tap-shipped and has no repo-local counterpart here).
  local label="$1" require_repo_plist="$2"
  local plist_name="${label}.plist"
  local installed_plist="$LAUNCH_AGENTS_DIR/$plist_name"
  local ok=1

  if [ "$require_repo_plist" = "1" ]; then
    local repo_plist="$REPO_ROOT/$plist_name"
    if [ ! -f "$repo_plist" ]; then
      echo "FAIL-CLOSED: repo plist not found at ${repo_plist} — cannot confirm this machine's declared MANIFEST entry for ${label}." >&2
      ok=0
    fi
  fi

  if [ ! -f "$installed_plist" ]; then
    echo "NOT-INSTALLED: ${installed_plist} does not exist." >&2
    ok=0
  fi

  if ! command -v launchctl >/dev/null 2>&1; then
    echo "FAIL-CLOSED: launchctl is not on PATH — cannot confirm load state for ${label}. Treating as NOT-HEALTHY." >&2
    ok=0
  elif ! launchctl list "$label" >/dev/null 2>&1; then
    echo "NOT-LOADED: launchctl list does not report ${label} as loaded." >&2
    ok=0
  fi

  [ "$ok" -eq 1 ]
}

check_scheduler_installed() {
  local devteam_ok=0 aiteamforge_ok=0
  local devteam_diag aiteamforge_diag

  # Capture each label's diagnostics (stdout+stderr — the helper only ever
  # writes to stderr, but 2>&1 is belt-and-suspenders) instead of letting
  # them print directly, so a losing label's findings can be discarded
  # entirely when the OTHER label is healthy (see header note above).
  if devteam_diag="$(_kb_label_installed_and_loaded "$LABEL_DEVTEAM" 1 2>&1)"; then
    devteam_ok=1
  fi
  if aiteamforge_diag="$(_kb_label_installed_and_loaded "$LABEL_AITEAMFORGE" 0 2>&1)"; then
    aiteamforge_ok=1
  fi

  if [ "$devteam_ok" -eq 1 ]; then
    SCHEDULER_WINNING_LABEL="$LABEL_DEVTEAM"
    SCHEDULER_OK=1
  elif [ "$aiteamforge_ok" -eq 1 ]; then
    SCHEDULER_WINNING_LABEL="$LABEL_AITEAMFORGE"
    SCHEDULER_OK=1
  else
    SCHEDULER_OK=0
    # Neither namespace is healthy — NOW surface both sets of diagnostics,
    # since the reader needs to know both were actually checked.
    [ -n "$devteam_diag" ] && printf '%s\n' "$devteam_diag" >&2
    [ -n "$aiteamforge_diag" ] && printf '%s\n' "$aiteamforge_diag" >&2
  fi

  if [ "$VERBOSE" = "1" ] && [ "$SCHEDULER_OK" = "1" ]; then
    echo "OK: ${SCHEDULER_WINNING_LABEL} is installed and loaded."
  fi

  [ "$SCHEDULER_OK" -eq 1 ]
}

# ── check_sync_divergence (007) ─────────────────────────────────────────────
# Sets $SYNC_DIVERGED, $SYNC_STALLED, $SYNC_UNVERIFIED ("1"/"0") and prints
# a human-readable finding for whichever conditions fired. Never fetches —
# reads the cached upstream ref (@{u}) only, so this is safe under the <5s
# SessionStart budget (see header). A repo argument lets --fleet mode and
# tests point this at something other than $KNOWLEDGE_REPO_DIR without an
# env var round-trip.
#
# ── CACHE-FRESHNESS GATE (design doc § 9's explicit instruction) ───────────
# "Never report 'in sync' from a stale ref it did not refresh." A 0-ahead/
# 0-behind reading against @{u} is only trustworthy if something (kb-
# knowledge-sync.sh's own `git pull --rebase`, or a human `git fetch`)
# actually refreshed the local remote-tracking ref recently. On a DIRTY
# machine the sync script's Guard 3 skips the fetch entirely — so a tree
# that went dirty and then sat untouched for days would otherwise report a
# reassuring "0 ahead, 0 behind" that is really "0 ahead, 0 behind AS OF
# WHENEVER WE LAST LOOKED", which is exactly the false-green shape this
# ticket exists to close. `.git/FETCH_HEAD`'s mtime is updated by every
# `git fetch`/`git pull` regardless of whether anything changed, so its age
# is a direct, free (no-network) proxy for "how long since we last actually
# checked". Default staleness threshold matches kb-knowledge-sync.sh's own
# LOCK_STALE_SECONDS default (3600s = 2x the 30-min sync interval) for the
# same reasoning: two missed intervals is a real gap, not a rounding error.
# A NONZERO ahead/behind reading is never suppressed by staleness — real
# divergence, once observed, does not become less real for being old; it is
# only the "0/0 therefore healthy" claim that a stale cache cannot support.
SYNC_DIVERGED=0
SYNC_STALLED=0
SYNC_UNVERIFIED=0
SYNC_AHEAD=""
SYNC_BEHIND=""
SYNC_UPSTREAM=""
SYNC_CACHE_STALE_SECONDS="${KB_KNOWLEDGE_SYNC_CACHE_STALE_SECONDS:-3600}"
# XACA-1291-024/-026: set inside check_sync_divergence's dirty-AND-diverged
# branch when _hc_all_own_ahead confirms every ahead commit is this host's
# own auto-commit AND _hc_unwind_blocker finds nothing known to stop the
# daemon's unwind step (§4.4). It means "the daemon will TRY on its next
# tick" — never "this heals with no human" (XACA-1291-026: that prediction
# was false in at least 7 reproduced cases). Consulted by the STRANDED
# finding and the scheduler-installed WARNING further down so all three
# sites agree about the identical repo state.
SYNC_DIVERGED_SELF_HEAL=0
# Human-readable reason set by _hc_unwind_blocker when it returns 0.
_HC_UNWIND_BLOCKER=""
# The daemon's last inbound notify-state token, as read by
# _hc_unwind_blocker (empty if the state file could not be read).
_HC_UNWIND_TOKEN=""

# ── _hc_all_own_ahead (XACA-1291-024) ───────────────────────────────────────
# A dirty-AND-diverged tree does not always need a human. kb-knowledge-
# sync.sh's own unwind step (§4.4 "UNWIND own unpushed auto-commits") moves
# a diverged HEAD back to the merge-base and returns its own auto-commits
# to the working tree — with NO human action — whenever EVERY commit the
# tree is ahead by is THIS host's own knowledge-sync auto-commit. This
# mirrors that step's ownership predicate EXACTLY, so the health check's
# wording cannot drift from what the daemon will actually do:
#   canonical copy: scripts/kb-knowledge-sync.sh, `_ac_all_own_ahead()`
#   (§4.4 "OWN_AUTOCOMMIT" comment, next to it) — committer name
#   AC_COMMITTER_NAME="knowledge-sync daemon", trailer mark
#   AC_TRAILER_MARK="Knowledge-Sync-Autocommit: v1", host via `_ac_host()`.
# If the daemon's constants or predicate ever change, update BOTH copies
# together — there is deliberately no shared sourced file between a
# SessionStart hook's health check and the daemon's own tick script.
#
# Returns 0 only when every commit in `@{u}..HEAD` (in $1) has the daemon's
# committer identity AND carries both trailers naming THIS host. Returns 1
# on ANY foreign commit, an empty range, OR a git error — the same "not
# provably ours" bucket the daemon's own predicate uses, which is exactly
# the fail-closed behavior the caller needs (git error => keep the
# conservative human-resolve wording, never claim self-heal on a hunch).
_HC_AC_COMMITTER_NAME="knowledge-sync daemon"
_HC_AC_TRAILER_MARK="Knowledge-Sync-Autocommit: v1"

_hc_ac_host() {
  local h
  h="$(scutil --get LocalHostName 2>/dev/null || true)"
  [ -n "$h" ] || h="$(hostname -s 2>/dev/null || true)"
  [ -n "$h" ] || h="unknown-host"
  printf '%s' "$h" | tr -c 'A-Za-z0-9-' '-'
}

_hc_all_own_ahead() {
  local repo="$1" list c cn body host
  host="$(_hc_ac_host)"
  list="$(git -C "$repo" rev-list '@{u}..HEAD' 2>/dev/null </dev/null || true)"
  [ -n "$list" ] || return 1
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    cn="$(git -C "$repo" log -1 --format=%cn "$c" 2>/dev/null </dev/null || true)"
    [ "$cn" = "$_HC_AC_COMMITTER_NAME" ] || return 1
    body="$(git -C "$repo" log -1 --format=%B "$c" 2>/dev/null </dev/null || true)"
    printf '%s\n' "$body" | grep -qxF "$_HC_AC_TRAILER_MARK" || return 1
    printf '%s\n' "$body" | grep -qxF "Knowledge-Sync-Host: ${host}" || return 1
  done <<EOF_HC_OWN
$list
EOF_HC_OWN
  return 0
}

# ── _hc_unwind_blocker (XACA-1291-026) ──────────────────────────────────────
# _hc_all_own_ahead answers only "are the ahead commits ours?". Whether the
# daemon's unwind will actually RUN, and whether the fast-forward after it
# will land, depends on more than ownership. XACA-1291-026 reproduced 7
# cases where ownership held and the daemon still did not heal: something
# staged in the index; the kill switch (sentinel file or env);
# CHERRY_PICK_HEAD / REVERT_HEAD / sequencer / BISECT_LOG present; and
# upstream changing a path the own commit also changed (the unwind succeeds,
# then `merge --ff-only` is refused — blocked-ff-conflict).
#
# Replicating every daemon precondition here would be a drift trap, so this
# function checks only the CHEAP, STABLE ones, each pointing at its canonical
# daemon check, and otherwise defers to the daemon's own record of what it
# did: the notify state file (source of truth, NOTIFY_STATE_FILE). Anything
# not predictable from here (like the ff conflict above) shows up there as
# an unproductive tick after the daemon tries, and escalates on the next
# health check.
#
# Prints nothing. Returns 0 when a BLOCKER is known (reason in
# _HC_UNWIND_BLOCKER), 1 when nothing known blocks the next tick's attempt.
# Every read error is a blocker (fail closed toward the human-resolve
# wording).
_HC_AC_SENTINEL="${HOME}/.aiteamforge/knowledge-sync-autocommit.off"
_hc_unwind_blocker() {
  local repo="$1" git_dir="$2" f rc cnt
  _HC_UNWIND_BLOCKER=""
  _HC_UNWIND_TOKEN=""

  # Read the state first so every wording can name the daemon's last token.
  if [ -r "$NOTIFY_STATE_FILE" ]; then
    _HC_UNWIND_TOKEN="$(_kb_notify_json_field "$NOTIFY_STATE_FILE" last_outcome_token)"
  fi

  # Kill switch. Canonical: kb-knowledge-sync.sh `_ac_enabled()` (env
  # KB_KNOWLEDGE_SYNC_AUTOCOMMIT=0, or the AC_SENTINEL file). When it is
  # on, the daemon skips the unwind entirely. The env var here is THIS
  # shell's, which the LaunchAgent may not share; the sentinel is the one
  # both see. Either one is treated as a blocker (conservative).
  if [ "${KB_KNOWLEDGE_SYNC_AUTOCOMMIT:-1}" = "0" ]; then
    _HC_UNWIND_BLOCKER="the auto-commit kill switch is on in this environment (KB_KNOWLEDGE_SYNC_AUTOCOMMIT=0), which also disables the unwind"
    return 0
  fi
  if [ -e "$_HC_AC_SENTINEL" ]; then
    _HC_UNWIND_BLOCKER="the auto-commit kill switch is on (${_HC_AC_SENTINEL} exists), which also disables the unwind"
    return 0
  fi

  # Git operation in progress. Canonical: kb-knowledge-sync.sh
  # `_ac_git_busy()` (precondition P4); keep this list identical to its.
  if [ -z "$git_dir" ]; then
    _HC_UNWIND_BLOCKER="the git dir of ${repo} could not be resolved"
    return 0
  fi
  for f in MERGE_HEAD rebase-merge rebase-apply CHERRY_PICK_HEAD REVERT_HEAD sequencer BISECT_LOG index.lock; do
    if [ -e "${git_dir}/${f}" ]; then
      _HC_UNWIND_BLOCKER="a git operation is in progress (${git_dir}/${f} exists); the daemon's unwind refuses while git is busy"
      return 0
    fi
  done

  # Staged changes. Canonical: the unwind guard in kb-knowledge-sync.sh
  # (`git -C "$REPO_DIR" diff --cached --quiet` right before
  # `_ac_all_own_ahead`). rc 1 = staged; any other nonzero = unreadable.
  git -C "$repo" diff --cached --quiet >/dev/null 2>&1 </dev/null
  rc=$?
  if [ "$rc" -eq 1 ]; then
    _HC_UNWIND_BLOCKER="something is staged in the index; the daemon never unwinds over staged changes"
    return 0
  elif [ "$rc" -ne 0 ]; then
    _HC_UNWIND_BLOCKER="the index of ${repo} could not be read (git diff --cached exited ${rc})"
    return 0
  fi

  # The daemon's own record. Canonical writer: kb-knowledge-sync.sh
  # `_update_notify_state()`. Its inbound counter resets on the tick that
  # makes an auto-commit (outbound only runs after inbound converged), so a
  # counter >= 1 here was earned AFTER that commit, while diverged: the
  # daemon has already had a tick in this state and did not heal it. Any
  # token outside the converged set, or no readable state, fails closed.
  if [ ! -r "$NOTIFY_STATE_FILE" ]; then
    _HC_UNWIND_BLOCKER="there is no readable notify state file at ${NOTIFY_STATE_FILE}, so there is no evidence the daemon is ticking"
    return 0
  fi
  cnt="$(_kb_notify_json_field "$NOTIFY_STATE_FILE" consecutive_unproductive_ticks)"
  case "$cnt" in
    ''|*[!0-9]*)
      _HC_UNWIND_BLOCKER="the notify state file ${NOTIFY_STATE_FILE} could not be parsed (consecutive_unproductive_ticks='${cnt}')"
      return 0 ;;
  esac
  case "$_HC_UNWIND_TOKEN" in
    converged-ff|converged-ff-index-regen|rebased-advanced|already-current|fetch-only-dirty|synced) ;;
    *)
      _HC_UNWIND_BLOCKER="the daemon's last tick ended in last_outcome_token=${_HC_UNWIND_TOKEN:-<none>} (${cnt} consecutive unproductive tick(s))"
      return 0 ;;
  esac
  if [ "$cnt" -ge 1 ]; then
    _HC_UNWIND_BLOCKER="the daemon has already had ${cnt} unproductive tick(s) in this state (last_outcome_token=${_HC_UNWIND_TOKEN})"
    return 0
  fi
  return 1
}

# ── _hc_ff_refused (XACA-1291-026) ──────────────────────────────────────────
# Returns 0 only on POSITIVE evidence from the daemon's notify state that
# its dirty-tree fast-forward was refused: last_outcome_token is
# blocked-ff-conflict or blocked-ff-diverged with a counter >= 1 (tokens and
# counter written by kb-knowledge-sync.sh's `_update_notify_state()`). A
# missing or unreadable state returns 1 and keeps the existing DIRTY-behind
# wording (that branch predates XACA-1291-026 and is not fail-closed on a
# missing file; check_notify_state reports a missing file on its own).
_HC_FF_TOKEN=""
_HC_FF_COUNT=""
_hc_ff_refused() {
  [ -r "$NOTIFY_STATE_FILE" ] || return 1
  _HC_FF_TOKEN="$(_kb_notify_json_field "$NOTIFY_STATE_FILE" last_outcome_token)"
  _HC_FF_COUNT="$(_kb_notify_json_field "$NOTIFY_STATE_FILE" consecutive_unproductive_ticks)"
  case "$_HC_FF_COUNT" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_HC_FF_COUNT" -ge 1 ] || return 1
  case "$_HC_FF_TOKEN" in
    blocked-ff-conflict|blocked-ff-diverged) return 0 ;;
  esac
  return 1
}

check_sync_divergence() {
  local repo="${1:-$KNOWLEDGE_REPO_DIR}"

  if ! git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "FAIL-CLOSED: ${repo} is not a git repository (or does not exist) — cannot determine sync state." >&2
    SYNC_UNVERIFIED=1
    return 1
  fi

  local git_dir mid_rebase=0
  git_dir="$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null || true)"
  if [ -n "$git_dir" ] && { [ -d "${git_dir}/rebase-merge" ] || [ -d "${git_dir}/rebase-apply" ] || [ -f "${git_dir}/MERGE_HEAD" ]; }; then
    echo "STALLED: ${repo} has an in-progress rebase/merge — kb-knowledge-sync.sh leaves it untouched until this is resolved by a human; it can neither RECEIVE nor SEND while wedged." >&2
    SYNC_STALLED=1
    mid_rebase=1
  fi

  # XACA-1266: a dirty tree ALONE is no longer a stall. kb-knowledge-sync.sh
  # now fetches unconditionally and converges a dirty-but-not-diverged tree
  # via `git merge --ff-only` — it does NOT mean this machine cannot
  # RECEIVE. As of XACA-1291, dirty alone does not mean it cannot SEND
  # either: the daemon auto-commits allowlisted, complete, quiescent
  # entries from a private index and pushes whenever ahead>0 and
  # behind==0, dirty or clean. The one dirty shape that genuinely blocks
  # receiving (and, for the same reason, sending) is dirty AND diverged
  # (local commits ahead AND behind, so a fast-forward is impossible) —
  # that is reported as STALLED below, once ahead/behind are known.
  # Capture the raw dirty status now; the human-readable finding is
  # deferred to the ahead/behind reveal further down so it can say
  # "can/cannot RECEIVE/SEND" accurately instead of guessing before the
  # counts exist (see design doc XACA-1266-003 §5 and XACA-1291's outbound
  # design doc).
  local dirty
  dirty="$(git -C "$repo" status --porcelain 2>&1)"

  local upstream
  upstream="$(git -C "$repo" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
  if [ -z "$upstream" ]; then
    echo "FAIL-CLOSED: ${repo} has no upstream tracking branch configured — cannot determine ahead/behind." >&2
    SYNC_UNVERIFIED=1
    return 1
  fi
  SYNC_UPSTREAM="$upstream"

  local counts behind ahead
  counts="$(git -C "$repo" rev-list --left-right --count '@{u}...HEAD' 2>/dev/null || true)"
  if [ -z "$counts" ]; then
    echo "FAIL-CLOSED: could not compute ahead/behind for ${repo} against ${upstream} — treating as unverified (fail closed)." >&2
    SYNC_UNVERIFIED=1
    return 1
  fi
  behind="${counts%%[[:space:]]*}"
  ahead="${counts##*[[:space:]]}"
  SYNC_BEHIND="$behind"
  SYNC_AHEAD="$ahead"

  if [ "$behind" != "0" ] || [ "$ahead" != "0" ]; then
    SYNC_DIVERGED=1
  fi

  # ── Dirty-tree classification (XACA-1266), now that ahead/behind are known ──
  # A fast-forward is impossible if and ONLY IF there are BOTH local commits
  # ahead AND commits behind — that AND, not SYNC_DIVERGED's OR, is the
  # precise "cannot RECEIVE" condition (SYNC_DIVERGED alone also covers
  # e.g. "behind only", which converges fine via ff and is NOT a stall).
  if [ -n "$dirty" ]; then
    if [ "$ahead" != "0" ] && [ "$behind" != "0" ]; then
      # XACA-1291-024/-026: a dirty-AND-diverged tree whose ahead commits are
      # ALL this host's own auto-commits (_hc_all_own_ahead, canonical copy
      # in kb-knowledge-sync.sh's _ac_all_own_ahead()) is one the daemon
      # will TRY to unwind on its next tick. That is not a promise it
      # heals: _hc_unwind_blocker checks the known blockers and the
      # daemon's own notify state, and any hit keeps the human-resolve
      # wording (naming the blocker). Mid-rebase is excluded up front, and a
      # git error, an empty ahead range or any foreign commit falls through
      # to the human-resolve wording too (fail closed).
      if [ "$mid_rebase" -eq 0 ] && _hc_all_own_ahead "$repo"; then
        if _hc_unwind_blocker "$repo" "$git_dir"; then
          echo "STALLED: ${repo} is dirty AND diverged (${ahead} ahead, ${behind} behind ${upstream}). Every ahead commit is this host's own knowledge-sync auto-commit, but the daemon's unwind will not heal it: ${_HC_UNWIND_BLOCKER}. A human must resolve it. Until then this machine CANNOT RECEIVE (no fast-forward is possible), and it also CANNOT SEND this tick: auto-commit and push both require 0 behind (XACA-1291 precondition P3), and this tree is ${behind} behind." >&2
          SYNC_STALLED=1
        else
          SYNC_STALLED=1
          SYNC_DIVERGED_SELF_HEAL=1
          echo "UNWIND-PENDING: ${repo} is dirty AND diverged (${ahead} ahead, ${behind} behind ${upstream}), and every commit it is ahead by is THIS host's own knowledge-sync auto-commit (same ownership check kb-knowledge-sync.sh's unwind step uses). The daemon will try to unwind them and fast-forward on its next tick. If this state is still reported after that tick, a human must resolve it (see the daemon's last notify-state token: last_outcome_token=${_HC_UNWIND_TOKEN:-<none>}, in ${NOTIFY_STATE_FILE}, and ${SYNC_LOG_PATH}). Outbound stays withheld until it catches up: auto-commit and push both require 0 behind (XACA-1291 precondition P3), and this tree is ${behind} behind." >&2
        fi
      else
        echo "STALLED: ${repo} is dirty AND diverged (${ahead} ahead, ${behind} behind ${upstream}) — a fast-forward is impossible, so this machine CANNOT RECEIVE until a human resolves the dirty tree (kb-knowledge-sync.sh never stashes or rebases a dirty tree). It also CANNOT SEND this tick: auto-commit and push both require 0 behind (XACA-1291 precondition P3), and this tree is ${behind} behind — resolving the divergence lets outbound resume on its own." >&2
        SYNC_STALLED=1
      fi
    elif [ "$behind" != "0" ] && _hc_ff_refused; then
      # XACA-1291-026 (reviewer case: upstream changed a path the daemon's
      # own commit also changed): the unwind succeeds, leaving 0 ahead / N
      # behind and dirty, then `merge --ff-only` is refused every tick. The
      # repo shape alone reads like the healthy DIRTY-behind case below, so
      # the daemon's own notify state decides (see _hc_ff_refused).
      echo "DIRTY (receive blocked): ${repo} has uncommitted changes and is ${behind} behind ${upstream}, and the daemon's last fast-forward was refused (last_outcome_token=${_HC_FF_TOKEN}, ${_HC_FF_COUNT} consecutive unproductive tick(s), in ${NOTIFY_STATE_FILE}). A local uncommitted change collides with an incoming one (see ${SYNC_LOG_PATH} for the path). This does not resolve on another tick: a human must commit, move or reconcile the colliding local path. Until then this machine CANNOT RECEIVE, and outbound stays withheld (it requires 0 behind — XACA-1291 precondition P3)." >&2
    elif [ "$behind" != "0" ]; then
      echo "DIRTY (not stalled): ${repo} has uncommitted changes and is ${behind} behind ${upstream}. It CAN still RECEIVE — kb-knowledge-sync.sh fetches unconditionally and fast-forwards a dirty-but-not-diverged tree (XACA-1266). Outbound is deferred until it catches up: auto-commit and push both require 0 behind (XACA-1291 precondition P3); once the ff-only lands, outbound resumes on its own next tick. This is expected/by design, not itself a problem." >&2
    else
      echo "DIRTY (not stalled): ${repo} has uncommitted changes, 0 behind ${upstream}. It CAN still RECEIVE (already caught up) and it CAN still SEND — kb-knowledge-sync.sh auto-commits allowlisted (agents/, subjects/, teams/), complete, quiescent (15-minute) entries from a private index and pushes when ahead>0, dirty or clean (XACA-1291; see kanban/plans/XACA-1291/XACA-1291_outbound_autocommit_design.md). Whether anything actually moves this tick depends on entry state — see the NOTIFY-STATE-OUTBOUND finding below, or grep autocommit-held / autocommit-refused / outbound-nonallowlisted in the sync log, for the specific reason if nothing is. This is expected/by design, not itself a problem." >&2
    fi
  fi

  # Freshness gate — only relevant when we are about to claim "0/0 = in
  # sync"; a nonzero reading stands regardless of cache age (see header
  # note above this function).
  if [ "$SYNC_DIVERGED" -eq 0 ]; then
    local fetch_head="${git_dir}/FETCH_HEAD"
    if [ -z "$git_dir" ] || [ ! -f "$fetch_head" ]; then
      echo "STALE-CACHE: ${repo} has no recorded fetch (${fetch_head:-<unknown git-dir>} missing) — a 0-ahead/0-behind reading cannot be trusted as 'in sync' without ever having refreshed the cache. Treating as unverified (fail closed)." >&2
      SYNC_UNVERIFIED=1
      return 1
    fi
    local fetch_epoch now_epoch fetch_age
    fetch_epoch="$(stat -c %Y "$fetch_head" 2>/dev/null || stat -f %m "$fetch_head" 2>/dev/null || echo "")"
    if [ -z "$fetch_epoch" ]; then
      echo "STALE-CACHE: could not read the mtime of ${fetch_head} — cannot confirm cache freshness. Treating as unverified (fail closed)." >&2
      SYNC_UNVERIFIED=1
      return 1
    fi
    now_epoch="$(date +%s)"
    fetch_age=$(( now_epoch - fetch_epoch ))
    # XACA-1259-008 finding 5: a NEGATIVE age (FETCH_HEAD's mtime is in the
    # future — clock skew, a restored backup, a bad NFS timestamp) passed
    # the "younger than threshold" test below undisturbed, since any
    # negative number is "less than" a positive threshold. That let a
    # cache that cannot possibly be trusted read as freshly-fetched. A
    # negative age is exactly as untrustworthy as an over-threshold one —
    # both mean "the mtime does not support the freshness claim" — so it
    # is checked FIRST and unconditionally fails closed, before the
    # threshold comparison ever runs.
    if [ "$fetch_age" -lt 0 ]; then
      echo "STALE-CACHE: ${repo}'s FETCH_HEAD mtime is in the FUTURE (computed age ${fetch_age}s — clock skew, a restored backup, or a bad timestamp) — a 0-ahead/0-behind reading cannot be trusted as 'in sync' against an untrustworthy mtime. Treating as unverified (fail closed)." >&2
      SYNC_UNVERIFIED=1
      return 1
    fi
    if [ "$fetch_age" -ge "$SYNC_CACHE_STALE_SECONDS" ]; then
      echo "STALE-CACHE: ${repo}'s last fetch was ${fetch_age}s ago (threshold ${SYNC_CACHE_STALE_SECONDS}s) — a 0-ahead/0-behind reading this old is not trustworthy as 'in sync'. Treating as unverified (fail closed) rather than reporting a possibly-false green." >&2
      SYNC_UNVERIFIED=1
      return 1
    fi
  fi

  if [ "$SYNC_STALLED" -eq 1 ] && [ "$SYNC_DIVERGED" -eq 1 ]; then
    if [ "$SYNC_DIVERGED_SELF_HEAL" -eq 1 ]; then
      # XACA-1291-024/-026: same determination as the UNWIND-PENDING
      # finding above (SYNC_DIVERGED_SELF_HEAL=1 is only ever set there),
      # restated so a reader who skims STRANDED sees the same claim. It says
      # the daemon will TRY, never that no human is needed.
      echo "STRANDED (unwind pending): ${repo} is dirty AND diverged (${ahead} ahead, ${behind} behind ${upstream}), and every commit it is ahead by is this host's own knowledge-sync auto-commit (see the UNWIND-PENDING finding above). The daemon will try to unwind them on its next tick; if this is still reported after that tick, a human must resolve it (last_outcome_token=${_HC_UNWIND_TOKEN:-<none>}). Outbound (auto-commit and push) stays withheld until it catches up (0 behind — XACA-1291 precondition P3)." >&2
    else
      echo "STRANDED: ${repo} is BOTH stalled (dirty-and-diverged, or mid-rebase) AND diverged (${ahead} ahead, ${behind} behind ${upstream}) — this machine CANNOT RECEIVE until a human resolves it (no fast-forward is possible; this daemon never stashes or rebases a dirty tree). It also CANNOT SEND: auto-commit and push both require the tree to be caught up and quiescent first (0 behind, no in-progress rebase/merge — XACA-1291 preconditions P2/P3), so outbound is withheld here too. This is the worst-case combination." >&2
    fi
  fi

  if [ "$VERBOSE" = "1" ] && [ "$SYNC_DIVERGED" -eq 0 ] && [ "$SYNC_STALLED" -eq 0 ]; then
    echo "OK: ${repo} is clean and in sync with ${upstream} (0 ahead, 0 behind)."
  fi

  [ "$SYNC_DIVERGED" -eq 0 ] && [ "$SYNC_STALLED" -eq 0 ]
}

# ── check_run_evidence (007) ────────────────────────────────────────────────
# Positive evidence only, communicated ENTIRELY via return code (0 = found,
# 1 = unknown/ambiguous) — unlike check_sync_divergence's SYNC_* globals,
# which main() reads directly for their individual values (ahead/behind
# counts, upstream name), there is nothing here beyond a single yes/no that
# the return code doesn't already carry in full, so this function
# deliberately keeps no companion global (a prior revision did —
# $RUN_EVIDENCE_FOUND — and shellcheck correctly flagged it SC2034: assigned
# every branch, read by nothing; removed rather than kept as dangling state
# implying a consumer that doesn't exist). An absent or empty log is NOT
# treated as a confirmed failure — only as ambiguous — per the ticket's
# explicit instruction: /tmp clears on reboot, so absence does not prove the
# agent never ran. A present, non-empty, matching log IS treated as a
# confirmed positive (the agent executed at least once); this function does
# not attempt to judge the log's recency or verdict — that is what
# check_sync_divergence's ahead/behind is for.
#
# XACA-1259-008 CONSIDER item, DECLINED: a reviewer flagged that
# /tmp/knowledge-sync.log is forgeable — anything can write a
# `[kb-knowledge-sync]`-tagged line there. Declined rather than hardened
# (e.g. with a checksum, a signature, or ownership/permission checks):
# this is a warning-only diagnostic with no security boundary — it never
# gates a merge, an installation, or any automated decision, only informs
# a human reading a SessionStart banner or a manual --verbose run. Anyone
# with write access to /tmp on this machine already has write access to
# ~/knowledge, ~/dev-team, and everything else the real sync agent
# touches, so forging this log grants no privilege the forger doesn't
# already have. Hardening the evidence mechanism is a real design change
# (what would the trust anchor even be, on a single-user dev machine?),
# not a cheap fix, and is out of scope here.
check_run_evidence() {
  local log_path="${1:-$SYNC_LOG_PATH}"

  if [ ! -f "$log_path" ] || [ ! -s "$log_path" ]; then
    echo "RUN-EVIDENCE-UNKNOWN: no (or empty) log at ${log_path}. AMBIGUOUS, not a confirmed failure — /tmp clears on reboot, so this does not prove the agent has never run." >&2
    return 1
  fi

  if ! grep -q '\[kb-knowledge-sync\]' "$log_path" 2>/dev/null; then
    echo "RUN-EVIDENCE-UNKNOWN: ${log_path} exists but contains no [kb-knowledge-sync]-tagged line — cannot confirm it was written by the sync agent." >&2
    return 1
  fi

  if [ "$VERBOSE" = "1" ]; then
    echo "OK: run evidence found at ${log_path}."
  fi
  return 0
}

# ── check_notify_state (XACA-1266-004 continuation) — the READER half of ────
# design doc §4.4, which was missing entirely until now: neither this script
# nor claude-hooks/kb-knowledge-sync-guard.sh referenced the (d) notify
# state file kb-knowledge-sync.sh's _update_notify_state writes. Modeled
# directly on check_run_evidence above — an INDEPENDENT lane that does NOT
# alter the SYNC STATE / STALE-CACHE verdict from check_sync_divergence.
# That structural separation is deliberate and load-bearing: it is what lets
# ~60 existing check_sync_divergence fixtures (none of which create a state
# file) stay green, because they assert only on that function's own finding,
# never on this one.
#
# THREE outcomes, decided in this order, per the ticket lead's explicit
# ruling (not the design doc's literal wording, which would have mapped
# "absent" into the same confirmed-PROBLEM lane as STALE-CACHE and made
# every one of the four fleet machines scream on the very first session
# after upgrading to this daemon, before it has had any chance to write a
# state file at all — a false-alarm storm that trains operators to ignore
# the finding, the exact failure mode this whole ticket family exists to
# kill):
#
#   1. ABSENT       → return 2 (AMBIGUOUS, same lane as check_run_evidence's
#                      "no log yet" — never HEALTHY, never a confirmed
#                      PROBLEM). Expected for a brief window after any
#                      machine upgrades to this daemon; only a genuine
#                      finding if it PERSISTS past one sync interval, which
#                      this function says explicitly rather than silently
#                      implying "fine".
#   2. PRESENT but unparseable (corrupt) → return 1 (PROBLEM). A state file
#      the daemon itself wrote should ALWAYS parse; there is no rollout
#      explanation for corruption the way there is for absence.
#   3. PRESENT and parseable → report the persisted consecutive-unproductive
#      count and the last outcome token. If the count is AT OR PAST the same
#      threshold kb-knowledge-sync.sh's own _update_notify_state uses (6
#      normally, escalated to 2 when the last token is blocked-ff-diverged,
#      which cannot self-heal) → return 1 (PROBLEM): the daemon is telling
#      us, in its own persisted words, that it has been stuck. Otherwise →
#      return 0 (confirmed fine, contributes to overall HEALTHY).
#
# Deliberately NOT implemented: any timing logic based on how long the
# LaunchAgent has been loaded, or a guessed/hardcoded sync interval. Ticket
# lead's explicit instruction — it would add a second thing to be wrong
# about (agent-load timestamp vs. state-file timestamp can drift for
# reasons unrelated to health) for no measurable benefit over the honest
# wording below. Where a real interval IS cheaply readable (the winning
# scheduler label's own plist, already known from check_scheduler_installed
# via $SCHEDULER_WINNING_LABEL), it is named; otherwise the wording says
# "one sync interval" generically rather than inventing a number.
NOTIFY_COUNT=""
NOTIFY_TOKEN=""
NOTIFY_THRESHOLD=""
NOTIFY_FIRST_UNPRODUCTIVE_AT=""

# Minimal scalar-field reader for the single-line JSON kb-knowledge-sync.sh
# itself writes — same controlled shape, same dependency-light rationale as
# that script's own _json_field (no jq). Prints "" if the key/file is
# absent, unreadable, or the value doesn't match the expected shape.
_kb_notify_json_field() {
  local file="$1" key="$2"
  [ -r "$file" ] || { printf ''; return 0; }
  sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"\{0,1\}\([^",}]*\)"\{0,1\}.*/\1/p' "$file" 2>/dev/null | head -1
}

# Best-effort StartInterval (seconds) from the winning scheduler label's own
# plist, so an ABSENT finding can name the real cadence instead of a guessed
# one. Prints "" (never a number) if unreadable for any reason — the caller
# must never fall back to inventing a value.
_kb_read_start_interval() {
  # NOTE: deliberately THREE separate `local` statements, not one combined
  # `local label="$1" plist="...${label}..." interval` — under `set -u`,
  # bash expands a later assignment's RHS on the SAME `local` line before
  # any of that line's assignments have taken effect, so `${label}` would
  # be genuinely unbound at that point and abort with "label: unbound
  # variable" on every call, regardless of what $1 is. Reproduced directly:
  # `bash -uc 'f(){ local a="$1" b="X${a}Y"; }; f x'` fails the same way.
  local label="$1"
  local plist="${LAUNCH_AGENTS_DIR}/${label}.plist"
  local interval
  [ -n "$label" ] && [ -f "$plist" ] || { printf ''; return 0; }
  if command -v /usr/libexec/PlistBuddy >/dev/null 2>&1; then
    interval="$(/usr/libexec/PlistBuddy -c 'Print :StartInterval' "$plist" 2>/dev/null)"
  else
    # XACA-1386: PlistBuddy is macOS-only. On Linux (CI runners) fall back
    # to reading the XML plist directly: the <integer> following the
    # StartInterval <key>. Same contract: non-numeric/absent -> "".
    interval="$(awk '/<key>StartInterval<\/key>/ {f=1; next} f && /<integer>/ {gsub(/.*<integer>|<\/integer>.*/, ""); print; exit}' "$plist" 2>/dev/null)"
  fi
  case "${interval:-}" in
    ''|*[!0-9]*) printf '' ;;
    *) printf '%s' "$interval" ;;
  esac
}

check_notify_state() {
  local state_file="${1:-$NOTIFY_STATE_FILE}"

  if [ ! -e "$state_file" ]; then
    local interval interval_txt
    interval="$(_kb_read_start_interval "$SCHEDULER_WINNING_LABEL")"
    if [ -n "$interval" ]; then
      interval_txt=" (${interval}s, per ${SCHEDULER_WINNING_LABEL}.plist's StartInterval)"
    else
      interval_txt=""
    fi
    echo "NOTIFY-STATE-UNKNOWN: no (d) notify state file at ${state_file} — the daemon has not completed a sync tick since this machine upgraded to the XACA-1266 daemon. This is EXPECTED BRIEFLY after rollout. If it persists beyond one sync interval${interval_txt}, the daemon is not completing ticks — investigate (scheduler load state above, ${SYNC_LOG_PATH})." >&2
    return 2
  fi

  local raw_count
  raw_count="$(_kb_notify_json_field "$state_file" consecutive_unproductive_ticks)"
  case "$raw_count" in
    ''|*[!0-9]*)
      echo "NOTIFY-STATE-CORRUPT: ${state_file} exists but could not be parsed (expected a numeric consecutive_unproductive_ticks field). A state file the daemon itself wrote should always parse — this is never benign and has no innocent rollout explanation. Investigate (disk corruption, a concurrent writer, a manual edit?)." >&2
      return 1
      ;;
  esac
  NOTIFY_COUNT="$raw_count"
  NOTIFY_TOKEN="$(_kb_notify_json_field "$state_file" last_outcome_token)"
  NOTIFY_FIRST_UNPRODUCTIVE_AT="$(_kb_notify_json_field "$state_file" first_unproductive_at)"

  # ── Staleness (XACA-1266-014, finding 014) ────────────────────────────
  # Design §4.4 requires treating a "missing, unreadable, OR STALE" state
  # file as UNKNOWN — the original XACA-1266-004 implementation covered
  # only the first two. Without this, a frozen file left behind by a
  # crashed/unloaded/removed daemon whose LAST recorded outcome happened
  # to be productive reads as permanently HEALTHY with no expiry: a dead
  # component manufacturing evidence of its own health, inside the exact
  # lane built to catch that failure mode. Checked BEFORE the STUCK/OK
  # decision below and overrides it either way — a stale STUCK reading is
  # just as untrustworthy as a stale healthy one; a stopped daemon tells us
  # nothing about its CURRENT state, only its last one.
  #
  # Freshness source: the file's OWN recorded last_fetch_at field, written
  # unconditionally by _update_notify_state on every tick — deliberately
  # NOT mtime. mtime can be refreshed by an unrelated write (a backup/copy
  # tool, a `touch`, an editor save) with no daemon tick involved at all —
  # see project memory feedback_backup_mtime_inverts_write_attribution.md
  # for a documented instance of exactly this trap elsewhere in this
  # codebase. last_fetch_at is written by this script's own code path ONLY
  # when a tick actually completed, so it cannot be spoofed that way.
  local last_fetch_at last_fetch_epoch now_epoch interval max_age_s age_s
  last_fetch_at="$(_kb_notify_json_field "$state_file" last_fetch_at)"
  interval="$(_kb_read_start_interval "$SCHEDULER_WINNING_LABEL")"

  if [ -z "$interval" ]; then
    # Fail TOWARD unknown, never toward healthy (design §4.4, ticket lead's
    # explicit instruction): without a real per-host cadence there is no
    # sensible staleness bound to compute, and inventing one would add a
    # SECOND thing to be wrong about (same reasoning _kb_read_start_interval
    # itself documents for why it never guesses a cadence). An unreadable
    # interval is itself unusual enough (no scheduler installed/loaded, or
    # PlistBuddy unavailable) that treating it as "fine" would be exactly
    # backwards.
    echo "NOTIFY-STATE-UNKNOWN: ${state_file} exists (last_fetch_at=${last_fetch_at:-unknown}) but its freshness could not be verified — ${SCHEDULER_WINNING_LABEL:-<no scheduler>}.plist's StartInterval is unreadable, so no sync cadence is known to compare it against. Failing toward UNKNOWN rather than assuming the file is fresh." >&2
    return 2
  fi

  # Parse last_fetch_at ("%Y-%m-%dT%H:%M:%SZ" UTC, written by this script's
  # own _now_iso()-equivalent) into epoch seconds. BSD date (macOS, every
  # fleet host) uses -j -f; GNU date (-d) is tried second purely as cheap
  # defensive portability, not because this fleet runs it. An empty or
  # unparseable value fails exactly like an unreadable interval: UNKNOWN,
  # never healthy.
  last_fetch_epoch=""
  if [ -n "$last_fetch_at" ]; then
    last_fetch_epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$last_fetch_at" '+%s' 2>/dev/null)"
    if [ -z "$last_fetch_epoch" ]; then
      last_fetch_epoch="$(date -u -d "$last_fetch_at" '+%s' 2>/dev/null)"
    fi
  fi
  case "$last_fetch_epoch" in ''|*[!0-9]*) last_fetch_epoch="" ;; esac

  if [ -z "$last_fetch_epoch" ]; then
    echo "NOTIFY-STATE-UNKNOWN: ${state_file} exists but its last_fetch_at field (${last_fetch_at:-absent}) could not be parsed as a timestamp — freshness cannot be verified. Failing toward UNKNOWN rather than assuming the file is fresh." >&2
    return 2
  fi

  now_epoch="$(date -u '+%s')"
  age_s=$(( now_epoch - last_fetch_epoch ))
  # Staleness multiple: 4x the daemon's own sync interval. One missed tick
  # alone (up to 1x) is ordinary jitter (a slow prior tick, a LaunchAgent
  # start-time slip, clock skew); 4x gives real slack before concluding the
  # daemon has actually stopped, while still catching a genuinely dead
  # daemon well before it could read as "permanently healthy" for days —
  # matches the same *4 backoff multiplier _update_notify_state's own
  # milestone sequence already uses, one consistent cadence vocabulary
  # shared by writer and reader rather than a second invented number.
  max_age_s=$(( interval * 4 ))

  # XACA-1266-018: these are TWO different faults and they need two different
  # messages. Collapsing them printed "is -2280955354s old — past 3600s" for a
  # future timestamp: self-contradictory (nothing is negative-seconds old, and
  # a negative number is not "past" a positive one) and, worse, it named a
  # cause — "the daemon has stopped ticking" — that is NOT what a future stamp
  # indicates. The verdict was right and the diagnosis misdirected the operator,
  # in a lane whose entire job is telling a human what broke. Mirrors the
  # sibling STALE-CACHE lane, which already calls its future-dated case FUTURE
  # rather than folding it into ordinary staleness.
  if [ "$age_s" -lt 0 ]; then
    local future_s=$(( 0 - age_s ))
    echo "NOTIFY-STATE-STALE (FUTURE): ${state_file}'s last_fetch_at (${last_fetch_at}) is dated ${future_s}s IN THE FUTURE relative to this machine's clock — it is not stale, it is impossible. A daemon cannot have fetched at a time that has not happened yet, so this is clock skew (this machine's clock behind the writer's, or an NTP correction mid-run) or a corrupt/hand-edited state file — NOT evidence about whether the daemon is ticking. Its last recorded outcome (${NOTIFY_TOKEN:-unknown}) cannot be trusted either way. Treating as UNKNOWN: check this machine's clock first, then the file's integrity." >&2
    return 2
  fi

  if [ "$age_s" -gt "$max_age_s" ]; then
    echo "NOTIFY-STATE-STALE: ${state_file}'s last_fetch_at (${last_fetch_at}) is ${age_s}s old — past ${max_age_s}s (4x ${SCHEDULER_WINNING_LABEL}.plist's ${interval}s StartInterval). The daemon that wrote this file has stopped ticking (crashed, unloaded, or removed) — its last recorded outcome (${NOTIFY_TOKEN:-unknown}) is no longer trustworthy evidence of CURRENT health. Treating as UNKNOWN, distinct from an ABSENT file (a fresh rollout that has not ticked yet) — this one ticked before and then stopped." >&2
    return 2
  fi

  # Same threshold rule as kb-knowledge-sync.sh's own _update_notify_state
  # (design doc §4.2): 2 (escalated) when the LATEST token is
  # blocked-ff-diverged — that state cannot self-heal — else 6.
  if [ "$NOTIFY_TOKEN" = "blocked-ff-diverged" ]; then
    NOTIFY_THRESHOLD=2
  else
    NOTIFY_THRESHOLD=6
  fi

  # XACA-1291 §5.4: the inbound and OUTBOUND verdicts are both computed and
  # both printed, then folded into this function's SINGLE 0/1/2 return,
  # worst-of-two (1 PROBLEM beats 2 AMBIGUOUS beats 0 OK). Same lane, same
  # rollup below — the outbound counter is not a second mechanism.
  local inbound_rc=0 outbound_rc=0
  if [ "$NOTIFY_COUNT" -ge "$NOTIFY_THRESHOLD" ]; then
    echo "NOTIFY-STATE-STUCK: ${state_file} reports ${NOTIFY_COUNT} consecutive unproductive tick(s) — at or past its own threshold (${NOTIFY_THRESHOLD}). Last outcome: ${NOTIFY_TOKEN:-unknown}, first unproductive at ${NOTIFY_FIRST_UNPRODUCTIVE_AT:-unknown}. The daemon itself is reporting it cannot converge; see kb-knowledge-sync.sh's own log (${SYNC_LOG_PATH}) for detail." >&2
    inbound_rc=1
  fi

  _kb_check_notify_outbound "$state_file"
  outbound_rc=$?

  if [ "$inbound_rc" -eq 1 ] || [ "$outbound_rc" -eq 1 ]; then
    return 1
  fi
  if [ "$outbound_rc" -eq 2 ]; then
    return 2
  fi

  if [ "$VERBOSE" = "1" ]; then
    echo "OK: notify state at ${state_file} reports ${NOTIFY_COUNT} consecutive unproductive tick(s) (below threshold ${NOTIFY_THRESHOLD}), last outcome: ${NOTIFY_TOKEN:-unknown}; outbound: ${NOTIFY_OUTBOUND_COUNT} withheld tick(s), last ${NOTIFY_OUTBOUND_TOKEN:-unknown}."
  fi
  return 0
}

# _kb_check_notify_outbound <state-file> — the OUTBOUND half of the lane
# (XACA-1291 §5.4). Called only from check_notify_state, and only AFTER its
# absent / corrupt / stale / future gates, so a stale file never reaches
# this read. Prints its own finding line; returns 0 OK, 1 PROBLEM,
# 2 AMBIGUOUS.
#
#   field absent  -> NOTIFY-STATE-OUTBOUND-UNKNOWN (2). The file was written
#                    by a pre-XACA-1291 daemon; expected for at most one
#                    interval after upgrade.
#   non-numeric   -> NOTIFY-STATE-CORRUPT (1), same as inbound.
#   >= threshold  -> NOTIFY-STATE-OUTBOUND-STUCK (1). Threshold is the
#                    writer's own rule: 2 when the last outbound token is
#                    autocommit-refused / autocommit-hook-error (neither can
#                    self-heal), else 48 ticks (~24h).
NOTIFY_OUTBOUND_COUNT=""
NOTIFY_OUTBOUND_TOKEN=""
NOTIFY_OUTBOUND_THRESHOLD=""
_kb_check_notify_outbound() {
  local state_file="$1" raw withheld quarantined first
  if ! grep -q '"consecutive_outbound_withheld_ticks"' "$state_file" 2>/dev/null; then
    echo "NOTIFY-STATE-OUTBOUND-UNKNOWN: ${state_file} has no outbound fields — it was written by a daemon older than XACA-1291, so whether this machine is SENDING its knowledge cannot be determined. EXPECTED for at most one sync interval after upgrading; if it persists, the daemon on this machine was not upgraded (check the tap/installed kb-knowledge-sync.sh)." >&2
    return 2
  fi
  raw="$(_kb_notify_json_field "$state_file" consecutive_outbound_withheld_ticks)"
  case "$raw" in
    ''|*[!0-9]*)
      echo "NOTIFY-STATE-CORRUPT: ${state_file} has an unparseable consecutive_outbound_withheld_ticks field ('${raw}'). A state file the daemon itself wrote should always parse — investigate (disk corruption, a concurrent writer, a manual edit?)." >&2
      return 1
      ;;
  esac
  NOTIFY_OUTBOUND_COUNT="$raw"
  NOTIFY_OUTBOUND_TOKEN="$(_kb_notify_json_field "$state_file" last_outbound_token)"
  withheld="$(_kb_notify_json_field "$state_file" outbound_withheld_paths)"
  quarantined="$(_kb_notify_json_field "$state_file" outbound_quarantined)"
  first="$(_kb_notify_json_field "$state_file" first_outbound_withheld_at)"
  case "$NOTIFY_OUTBOUND_TOKEN" in
    autocommit-refused|autocommit-hook-error) NOTIFY_OUTBOUND_THRESHOLD=2 ;;
    *) NOTIFY_OUTBOUND_THRESHOLD=48 ;;
  esac
  if [ "$NOTIFY_OUTBOUND_COUNT" -ge "$NOTIFY_OUTBOUND_THRESHOLD" ]; then
    echo "NOTIFY-STATE-OUTBOUND-STUCK: ${NOTIFY_OUTBOUND_COUNT} consecutive outbound-withheld tick(s) (last=${NOTIFY_OUTBOUND_TOKEN:-unknown}, withheld_paths=${withheld:-unknown}, quarantined=${quarantined:-unknown}, first at ${first:-unknown}) — this machine is RECEIVING but not SENDING. autocommit-hook-error: fix the pre-commit hook (install the tracked .githooks/pre-commit). autocommit-refused: edit the quarantined entry. outbound-withheld-incomplete: finish or delete the held entry (grep autocommit-held in ${SYNC_LOG_PATH}); a size-out-of-bounds hold means an authored entry over ENTRY_MAX_BYTES (262144) or a generated INDEX.md over INDEX_MAX_BYTES (2097152). outbound-withheld-phantom-deletion: a commit made from a stale index deletes an entry that still exists on disk; the next auto-commit re-adds it (grep phantom-deletion in ${SYNC_LOG_PATH}). autocommit-disabled: the kill switch is on. Dirty paths outside agents/, subjects/ and teams/ are never counted here: the daemon never commits outside agents/, subjects/ and teams/, so a human commits those by hand (grep outbound-nonallowlisted-info)." >&2
    return 1
  fi
  return 0
}

# _kb_check_index_size — XACA-1487 early warning (WARN only, never changes the
# verdict). The daemon holds an allowlisted INDEX.md larger than INDEX_MAX_BYTES
# as `size-out-of-bounds` (authored entries have the smaller ENTRY_MAX_BYTES).
# Warn when any allowlisted INDEX reaches 75% of INDEX_MAX_BYTES so there is
# lead time. INDEX_MAX_BYTES is READ from the daemon script next to this one
# (single source of truth); the literal fallback is pinned equal by
# tests/test-xaca-1487-index-size-bound.sh.
_kb_index_max_bytes() {
  local v
  v="$(sed -n 's/^INDEX_MAX_BYTES=\([0-9][0-9]*\)$/\1/p' "$REPO_ROOT/scripts/kb-knowledge-sync.sh" 2>/dev/null | head -n 1)"
  case "$v" in ''|*[!0-9]*) v=2097152 ;; esac
  echo "$v"
}
# _kb_index_re — the ERE the daemon uses to classify a path as an INDEX
# (AC_INDEX_RE, built from _AC_SEG), READ from the daemon script so this check
# warns about exactly the files the daemon would apply INDEX_MAX_BYTES to
# (XACA-1487-012: a glob also matched nested paths the daemon never allowlists).
# The pinned fallback is asserted byte-equal to the daemon-derived value by
# tests/test-xaca-1487-index-size-bound.sh.
_kb_index_re() {
  local d="$REPO_ROOT/scripts/kb-knowledge-sync.sh" re=""
  if [ -r "$d" ]; then
    re="$( _AC_SEG="$(sed -n "s/^_AC_SEG='\(.*\)'\$/\1/p" "$d" | head -n 1)"
           [ -n "$_AC_SEG" ] || exit 0
           eval "$(sed -n '/^AC_INDEX_RE="/p' "$d" | head -n 1)" 2>/dev/null
           printf '%s' "${AC_INDEX_RE:-}" )"
  fi
  case "$re" in
    *INDEX*) ;;
    *) re='^(agents|teams)/[a-z0-9][a-z0-9_-]*/INDEX\.md$|^subjects/[a-z0-9][a-z0-9_-]*(/[a-z0-9][a-z0-9_-]*)?/INDEX\.md$' ;;
  esac
  printf '%s' "$re"
}
_kb_check_index_size() {
  local max warn f sz rel idx_re
  [ -d "$KNOWLEDGE_REPO_DIR" ] || return 0
  max="$(_kb_index_max_bytes)"
  warn=$(( max * 3 / 4 ))
  idx_re="$(_kb_index_re)"
  # find, not a glob: an unmatched glob aborts zsh (NOMATCH) when this script
  # is run from a zsh shell, which tests/test-xaca-1259-007 exercises.
  # XACA-0417: find's -size pre-filters to the files over the warn threshold
  # (+Nc = strictly more than N bytes, same as the -gt below), so the loop
  # forks only for oversized INDEXes. Forking printf|grep and wc for every one
  # of ~200 INDEX.md files was 86% of this script's runtime and pushed the
  # SessionStart guard past its timeout on a loaded machine.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="${f#"$KNOWLEDGE_REPO_DIR"/}"
    printf '%s\n' "$rel" | grep -Eq -- "$idx_re" || continue
    [ -f "$f" ] || continue
    sz="$(wc -c < "$f" 2>/dev/null || echo 0)"
    sz=$(( sz + 0 ))
    if [ "$sz" -gt "$warn" ]; then
      echo "WARNING: INDEX-SIZE: ${rel} is ${sz} bytes, over 75% (${warn}) of the INDEX_MAX_BYTES bound (${max}). The daemon holds an allowlisted INDEX over ${max} bytes as size-out-of-bounds (authored entries are held at the smaller ENTRY_MAX_BYTES); raise the bound or split the INDEX before it is held." >&2
    fi
  done <<INDEX_EOF
$(find "$KNOWLEDGE_REPO_DIR" -maxdepth 4 -type f -name INDEX.md -size +"${warn}"c 2>/dev/null | LC_ALL=C sort)
INDEX_EOF
  return 0
}

# ── --fleet mode (007) — manual/CI only, never called by the SessionStart guard ──
# One ssh round-trip per host. The remote probe is self-contained (does NOT
# assume this script, or even a dev-team checkout, exists on the remote —
# fleet consumers get ~/knowledge via the tap-installed agent, not a repo
# checkout) and mirrors the same questions this script asks locally, using
# only git/launchctl. An unreachable host is reported as UNKNOWN and
# counted as a fail-closed problem — never as "converged". A host whose
# probe output is unparseable, empty, or otherwise unrecognizable (see
# _kb_fleet_host_classify below) is likewise a confirmed PROBLEM, never
# merely "converged" — XACA-1259-008 finding 1 found that this file used to
# assert exactly that property in this sentence while NOT implementing it:
# the classification was a DENYLIST (flag only five known-bad shapes), so
# unrecognizable-but-non-empty output matched none of them and was silently
# counted converged, byte-identical to a genuinely healthy verdict. Fixed
# as an ALLOWLIST.
#
# THREE lanes, not two (XACA-1259-008, second round, same day): a host is
# HEALTHY only if every determinable token is positively good, a PROBLEM if
# any determinable token is positively bad OR the output can't be parsed at
# all, and — the distinction the first allowlist cut missed — UNKNOWN if
# every determinable token IS good except run-evidence, which is genuinely
# ambiguous rather than false (RUN=UNKNOWN, the ordinary state of a machine
# whose /tmp cleared on reboot since its last sync). Folding UNKNOWN into
# PROBLEM regressed the REAL fleet: darren-m1pro-mbp and darren-m4-mini were
# both scheduled, converged, clean, and fresh, yet both read as confirmed
# problems purely for lacking a log file — the exact cry-wolf shape flagged
# earlier in this ticket, now self-inflicted one round later. See
# _kb_fleet_host_classify's own header for the full rationale; it returns
# HEALTHY/UNKNOWN/PROBLEM and run_fleet_check maps UNKNOWN hosts to the
# AMBIGUOUS exit lane (2), never the confirmed-problem lane (1).
#
# XACA-1259-007 fix (coordinator finding 3): the probe now applies the SAME
# FETCH_HEAD-freshness gate as the local check_sync_divergence — a remote
# "0 ahead / 0 behind" is reported as CACHE=STALE-* (never bare "SYNC=
# 0ahead/0behind" implying trustworthy convergence) when that host's own
# cached ref has not been refreshed recently. Before this fix a remote that
# had not fetched in a week would report 0/0 and read as healthy — the
# exact false-green class the local gate exists to prevent, just not
# ported to this second code path.
#
# The probe script is defined ONCE, as a string, and used two ways:
#   1. Piped over ssh's stdin to run on a real remote host (the production
#      path).
#   2. Run locally via `bash -c` under the internal, undocumented
#      --__test-fleet-probe-local flag, so the test suite can exercise this
#      EXACT code (not a hand-written duplicate that could drift) against a
#      disposable fixture repo with no network/ssh dependency at all.
# _KB_FLEET_PROBE_MARKER must be BYTE-IDENTICAL to the `marker=` literal
# inside $_KB_FLEET_PROBE_SCRIPT below — the probe (a separate process,
# local or remote) emits it; run_fleet_check (this process) greps for it.
# They cannot share a single variable across that process boundary, so
# this is intentionally two literals kept in sync by comment, not by
# reference — if you change one, change both, in the same commit.
_KB_FLEET_PROBE_MARKER="KB1259_FLEET_PROBE_RESULT:"

# shellcheck disable=SC2016  # single-quoted on purpose: every $var below is
# REMOTE-side (or, in local-test mode, evaluated by the nested bash -c) —
# none of it should expand in THIS shell when the string is defined.
_KB_FLEET_PROBE_SCRIPT='
# XACA-1259-008 PR gate round 6, BLOCKING finding: run_fleet_check captures
# this whole ssh session with `2>&1` — so the text handed to the classifier
# is NOT "the probe line", it is "the probe line plus whatever else ssh or
# the remote shell wrote to either stream", and `case` globs match ACROSS
# NEWLINES. Two benign, non-adversarial ways this bit even after the ref-
# name anchoring fix: (1) leading noise — `ssh` prints
# "Warning: Permanently added '"'"'<host>'"'"' to the list of known hosts."
# to stderr on a hosts first connection (or a locale warning, from either
# side) BEFORE the remote command even runs, which breaks the SCHED=
# start-of-string anchor for an otherwise perfectly healthy host, reading
# it as PROBLEM; (2) trailing noise carrying a token that happens to
# satisfy a later anchored marker, reading a genuinely bad host as
# HEALTHY — fail OPEN, the more dangerous direction. Both are reachable by
# something as ordinary as adding a new machine to the fleet — which is
# exactly what XACA-1259-006 just did for M1Mini.
#
# FIX: emit the ACTUAL result on its own line, prefixed with a marker that
# is vanishingly unlikely to appear in ANY incidental ssh/PAM/locale text
# (never meant to resist a deliberate adversary forging it — same
# non-adversarial threat model as the anchoring fix itself). Positional
# selection ("take the first/last line") was considered and rejected:
# leading noise can push the real line to any position, and multi-line
# noise (a MOTD, a multi-line locale warning) has no fixed line count to
# skip. A delimiter this script both emits and later greps for is the only
# approach that is correct regardless of how much noise surrounds it, on
# EITHER side. run_fleet_check greps for this exact marker and classifies
# ONLY the text after it — never the raw ssh capture — which is what makes
# the leading-space/start-of-string anchoring argument inside
# _kb_fleet_host_classify actually hold (it is stated, and was previously ALSO believed
# true, against the raw capture; here it is finally true against what the
# classifier actually receives). See run_fleet_check below for the
# extraction side; both sides of this marker literal must match exactly.
marker="KB1259_FLEET_PROBE_RESULT:"

label_devteam="com.devteam.knowledge-sync"
label_aiteamforge="com.aiteamforge.knowledge-sync"
repo="${KB_KNOWLEDGE_REPO:-$HOME/knowledge}"
logp="${KB_KNOWLEDGE_SYNC_LOG_PATH:-/tmp/knowledge-sync.log}"
stale_threshold="${KB_KNOWLEDGE_SYNC_CACHE_STALE_SECONDS:-3600}"
case "$stale_threshold" in (""|*[!0-9]*) stale_threshold=3600 ;; esac

sched="NOT-SCHEDULED"
if command -v launchctl >/dev/null 2>&1; then
  if launchctl list "$label_devteam" >/dev/null 2>&1; then
    sched="SCHEDULED:${label_devteam}"
  elif launchctl list "$label_aiteamforge" >/dev/null 2>&1; then
    sched="SCHEDULED:${label_aiteamforge}"
  fi
else
  sched="FAIL-CLOSED:no-launchctl"
fi

if [ ! -d "$repo/.git" ] && ! git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "${marker}SCHED=${sched} SYNC=FAIL-CLOSED:not-a-repo RUN=UNKNOWN CACHE=N/A"
  exit 0
fi

# Computed once, reused below for BOTH the rebase/merge check and the
# FETCH_HEAD freshness read.
gitdir="$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null || true)"

# XACA-1259-008 finding 3 (this round): the LOCAL check
# (check_sync_divergence) has always detected an in-progress rebase/merge
# and reported STALLED for it -- this remote probe never did, so the same
# repo could report STALLED/exit-1 via the local path and DIRTY=clean
# (HEALTHY or UNKNOWN) via --fleet, a genuine local-vs-fleet disagreement
# about the same machine. Mirrors check_sync_divergence own three-way
# check exactly (rebase-merge/ rebase-apply directory, or a MERGE_HEAD
# file). Checked BEFORE the porcelain-dirty read and given a DISTINCT
# value (rebase-in-progress, not dirty) -- during an active rebase, git
# status --porcelain can show its own conflict/staged noise, which would
# read confusingly under the generic dirty label; the allowlist only
# requires DIRTY not equal to clean to disqualify the host, so any
# distinct non-clean value already fails closed correctly.
dirty="clean"
if [ -n "$gitdir" ] && { [ -d "$gitdir/rebase-merge" ] || [ -d "$gitdir/rebase-apply" ] || [ -f "$gitdir/MERGE_HEAD" ]; }; then
  dirty="rebase-in-progress"
else
  d="$(git -C "$repo" status --porcelain 2>&1)"
  [ -n "$d" ] && dirty="dirty"
fi

upstream="$(git -C "$repo" rev-parse --abbrev-ref --symbolic-full-name "@{u}" 2>/dev/null || true)"
if [ -z "$upstream" ]; then
  echo "${marker}SCHED=${sched} SYNC=FAIL-CLOSED:no-upstream DIRTY=${dirty} RUN=UNKNOWN CACHE=N/A"
  exit 0
fi

counts="$(git -C "$repo" rev-list --left-right --count "@{u}...HEAD" 2>/dev/null || true)"
if [ -z "$counts" ]; then
  echo "${marker}SCHED=${sched} SYNC=FAIL-CLOSED:no-counts DIRTY=${dirty} RUN=UNKNOWN CACHE=N/A"
  exit 0
fi
behind="${counts%%[[:space:]]*}"
ahead="${counts##*[[:space:]]}"

run="UNKNOWN"
if [ -s "$logp" ] && grep -q "\[kb-knowledge-sync\]" "$logp" 2>/dev/null; then
  run="FOUND"
fi

# Freshness gate — mirrors check_sync_divergence locally: a 0/0 reading is
# only trustworthy if this host actually refreshed its cache recently.
# Nonzero readings are never gated (real divergence does not become less
# real for being observed via an old cache).
cache="N/A"
if [ "$ahead" = "0" ] && [ "$behind" = "0" ]; then
  # $gitdir already computed above, for the rebase/merge check.
  if [ -z "$gitdir" ] || [ ! -f "$gitdir/FETCH_HEAD" ]; then
    cache="STALE-NO-FETCH"
  else
    fepoch="$(stat -c %Y "$gitdir/FETCH_HEAD" 2>/dev/null || stat -f %m "$gitdir/FETCH_HEAD" 2>/dev/null || echo "")"
    if [ -z "$fepoch" ]; then
      cache="STALE-UNREADABLE"
    else
      nowepoch="$(date +%s)"
      age=$(( nowepoch - fepoch ))
      # XACA-1259-008 finding 5 (remote-probe side of the same bug as the
      # local check): a negative age (future mtime) must fail closed, not
      # read as fresh — see the local check_sync_divergence comment for
      # the full rationale.
      if [ "$age" -lt 0 ]; then
        cache="STALE-FUTURE-MTIME-${age}s"
      elif [ "$age" -ge "$stale_threshold" ]; then
        cache="STALE-AGE-${age}s"
      else
        cache="OK-AGE-${age}s"
      fi
    fi
  fi
fi

echo "${marker}SCHED=${sched} SYNC=${ahead}ahead/${behind}behind:${upstream} DIRTY=${dirty} RUN=${run} CACHE=${cache}"
'

# _kb_split_hosts <hosts-string>
# Prints one host per line. XACA-1259-008 finding 2 (round 3): `for host in
# $hosts` (unquoted variable expansion) does NOT word-split under zsh
# unless `SH_WORD_SPLIT` is set — zsh treats the whole string as ONE word,
# so a multi-host list silently collapsed to a single (mangled) "host" and
# every host after the first was never probed at all. Measured: a 3-host
# KB_KNOWLEDGE_SYNC_FLEET_HOSTS produced exactly one "FLEET ..." line under
# zsh, three under bash. Neither `${=hosts}` (zsh-only syntax — a bash
# syntax error) nor `read -a`/`read -A` (the FLAG NAME differs between the
# two shells: bash wants `-a`, zsh wants `-A`, each rejects the other) is
# portable. This tokenizes by hand with `%%`/`#*` parameter-expansion
# trimming instead, which is plain POSIX pattern matching — identical,
# shell-independent behavior in both bash 3.2 and zsh, since it never
# relies on word-splitting at all.
#
# ROUND-2 REGRESSION (subitem XACA-1259-018): the first cut of this
# function matched a literal ASCII space (`" "`/`*" "*`) only. A TAB
# specifically (KB_KNOWLEDGE_SYNC_FLEET_HOSTS is operator-supplied — a
# config file, a heredoc, a paste from somewhere else entirely could easily
# use one) does not fail LOUDLY: with no literal space present anywhere,
# the tokenizer's fallback branch swallows the WHOLE remaining string into
# one mangled "host" token (e.g. "hostA<TAB>hostB<TAB>hostC" tokenizes as a
# single garbage hostname), which then reports PROBLEM (fails closed on
# that single malformed name — never silently healthy) but every host
# after the first is simply never probed. Same UNDER-DETECTION shape as the
# zsh word-splitting bug above — "I believe I checked N hosts, I checked 1,
# badly" — just a different separator tripping the same "must match a
# literal space" assumption.
#
# CORRECTION (PR gate round 4): a purely NEWLINE-separated list was NEVER
# actually broken by the space-only version, and an earlier revision of
# this comment incorrectly claimed it was — the round-3 test coverage
# asserting that claim passed for the wrong reason (see
# tests/test-xaca-1259-007-knowledge-sync-divergence-check.sh CASE23's own
# header for the full mechanism and the corrected test). Mechanism: when no
# literal space is present anywhere, the fallback branch below emits the
# WHOLE input as a single `one="$remaining"` value, and
# `printf '%s\n' "$one"` reproduces $one's OWN embedded newlines verbatim
# — so newline-only input still arrived at the consuming
# `while IFS= read -r host` loop as separate, CLEAN lines, purely because
# that loop re-splits on newlines regardless of what this function does.
# Only a separator OTHER than a literal space or a newline (a tab, in
# practice) actually exercised the space-only bug.
#
# Fixed by matching the POSIX `[[:space:]]` character class (space, tab,
# newline, CR, FF, VT) instead of a literal space in every pattern below —
# still pure glob/parameter-expansion matching, no word-splitting, no
# behavior change for space- or newline-only input, and now ALSO correct
# for tab-separated (or any-whitespace-mixed) lists, which is the actual
# gap this fixed.
_kb_split_hosts() {
  local remaining="$1"
  local one
  while :; do
    case "$remaining" in
      [[:space:]]*) remaining="${remaining#[[:space:]]}"; continue ;;
      *) ;;
    esac
    [ -z "$remaining" ] && break
    case "$remaining" in
      *[[:space:]]*)
        one="${remaining%%[[:space:]]*}"
        remaining="${remaining#*[[:space:]]}"
        ;;
      *)
        one="$remaining"
        remaining=""
        ;;
    esac
    [ -n "$one" ] && printf '%s\n' "$one"
  done
}

# _kb_fleet_host_classify <probe-output>
# Prints exactly one of HEALTHY / UNKNOWN / PROBLEM to stdout. Pure
# function — no globals touched, safe to call via `$(...)`.
#
# XACA-1259-008 finding 1: the original version was a DENYLIST — it flagged
# a host only if its output matched one of five known-bad shapes, so
# non-empty but UNRECOGNIZABLE output (garbage, a truncated line, a future
# field this script doesn't know about yet) matched NONE of them and the
# host was silently counted CONVERGED. Reproduced live: garbage probe
# output and a genuinely healthy host produced byte-identical verdicts
# (`OVERALL: healthy`, exit 0). Fixed as an ALLOWLIST (still true here): a
# host counts HEALTHY only if its output affirmatively contains every
# required token, never merely by failing to match a bad one.
#
# XACA-1259-008 SECOND round, same-day regression: the first allowlist cut
# folded RUN=FOUND into the mandatory five tokens, so a genuinely healthy,
# converged, clean host with NO run-evidence (RUN=UNKNOWN) was classified
# identically to a garbage/unparseable host — both "not healthy". Measured
# against the REAL fleet: darren-m1pro-mbp and darren-m4-mini were BOTH
# scheduled, converged at fa99ae2, clean, and fresh, yet BOTH read as a
# confirmed problem purely because /tmp/knowledge-sync.log (which /tmp
# clears on reboot) happened to be absent. That is not an edge case — it is
# the ORDINARY state of a perfectly healthy machine after a reboot, so it
# would fire on every fleet check forever. This is the exact cry-wolf shape
# flagged earlier in this same ticket (a guard that reads red on a correct
# configuration trains people to ignore it — how kb-live-config-drift-
# guard.sh died) — and it directly contradicted a decision already made
# for the LOCAL check: check_run_evidence deliberately has its own exit
# code 2 specifically so "ambiguous" is never conflated with a confirmed
# pass or a confirmed problem. The fleet allowlist had collapsed that
# three-state distinction back into two.
#
# Fixed by splitting the tokens into two tiers instead of one flat list:
#   - CORE tokens (SCHED=SCHEDULED:, SYNC=0ahead/0behind:, DIRTY=clean,
#     CACHE=OK-AGE-): if ANY of these is missing OR positively bad, the
#     output is not just "not proven healthy" — it means either a real
#     finding (not scheduled, diverged, dirty, stale) or output this
#     function cannot make sense of at all (garbage, empty, truncated,
#     an unrecognized future format). Both are PROBLEM. This is the
#     invariant the coordinator required preserved: unparseable output is
#     a PROBLEM, never merely "unknown" — CASE17c (garbage) must stay red.
#   - RUN, checked ONLY once every core token is confirmed good: RUN=FOUND
#     is the fifth confirmation needed for HEALTHY; RUN=UNKNOWN — the
#     documented, expected shape of a machine that rebooted since its last
#     sync run — is UNKNOWN, not a confirmed problem. Any OTHER RUN value
#     (a future field this function doesn't recognize) still falls to
#     PROBLEM, matching the core tokens' own "unrecognized = problem" rule.
#
# CORRECTED (PR gate round 5): a prior revision of this comment declined to
# anchor these substring checks on the claim that every matched value comes
# from a closed vocabulary this function's own author controls, so there was
# "no external, attacker- or operator-influenced input that reaches this
# string." That premise was FALSE and was falsified: $upstream (the SYNC
# field's git ref name, e.g. "origin/main") is OPERATOR-CHOSEN — `=` is a
# perfectly legal character in a git ref name — and it is interpolated
# directly into the SAME line every one of these patterns scans. Reproduced
# end-to-end on a fixture branch literally named "DIRTY=clean": a host with a
# GENUINELY dirty tree (or an in-progress rebase) emits
# `... SYNC=0ahead/0behind:origin/DIRTY=clean DIRTY=dirty RUN=FOUND ...` — a
# line that legitimately CONTAINS the substring "DIRTY=clean" from the ref
# name, immediately before the real (bad) "DIRTY=dirty" field — and the
# unanchored `*"DIRTY=clean"*` check matched on the fake occurrence and
# classified the host HEALTHY. The same mechanism reaches every marker that
# appears AFTER the SYNC field on the line (DIRTY, RUN, CACHE), not only
# DIRTY, since $upstream sits before all three.
#
# FIX (not merely a corrected comment — the conclusion "don't refactor these
# checks" no longer held once the premise did not): anchor every marker on a
# LEADING SPACE (or start-of-string, for SCHED, which is always the first
# field). This is sound and sufficient, not merely narrower-but-still-
# guessable: git ref names cannot contain a literal space character
# (git-check-ref-format(1) rejects one), and no other field's value can
# either (SCHED's label and DIRTY/RUN/CACHE's own values are fixed constants
# this file emits; the ahead/behind counts and the cache age are digit-only,
# from `git rev-list --count` / an epoch subtraction). So every space
# character anywhere in a genuine probe line is necessarily a real
# inter-field separator, never operator content — which means an
# operator-chosen ref can never forge a LEADING-SPACE-anchored marker,
# structurally, not merely "not today." (A trailing anchor is not
# additionally needed: since the value that follows a matched marker is
# ALWAYS one of this file's own fixed tokens or digits, it cannot extend a
# short match into a look-alike longer one the way an operator-chosen value
# could.)
#
# THAT SUFFICIENCY ARGUMENT ASSUMES ITS INPUT IS A LINE, NOT A BLOB — PR
# gate round 6 caught that this function was being handed the WRONG string.
# run_fleet_check captures the whole ssh session with `2>&1`, so the raw
# text is the probe line PLUS whatever ssh/PAM/locale noise landed on
# either stream, and `case` globs match ACROSS NEWLINES: leading noise
# (e.g. ssh's own first-connection host-key warning, which fires the first
# time ANY new fleet machine is probed) breaks the start-of-string `SCHED=`
# anchor and reads a genuinely healthy host as PROBLEM; trailing noise that
# happens to contain a marker-shaped substring reads a genuinely bad host
# as HEALTHY — fail OPEN, the more dangerous direction. Both are reachable
# by entirely benign input, no crafted ref required. The anchoring argument
# above was written — and believed sufficient — against that raw blob; it
# was not, because the premise "every space is a real field separator"
# only holds for a single, actual probe line. run_fleet_check now extracts
# a marker-delimited line (see $_KB_FLEET_PROBE_MARKER and the extraction
# comment at its call site) BEFORE calling this function, so this function
# genuinely only ever receives one clean probe line — which is what makes
# the anchoring argument above actually true, not merely stated.
_kb_fleet_host_classify() {
  local out="$1"
  local core_ok=1

  case "$out" in ("SCHED=SCHEDULED:"*) ;; (*) core_ok=0 ;; esac
  case "$out" in (*" SYNC=0ahead/0behind:"*) ;; (*) core_ok=0 ;; esac
  case "$out" in (*" DIRTY=clean"*) ;; (*) core_ok=0 ;; esac
  case "$out" in (*" CACHE=OK-AGE-"*) ;; (*) core_ok=0 ;; esac

  if [ "$core_ok" -ne 1 ]; then
    echo "PROBLEM"
    return
  fi

  case "$out" in
    (*" RUN=FOUND"*) echo "HEALTHY" ;;
    (*" RUN=UNKNOWN"*) echo "UNKNOWN" ;;
    (*) echo "PROBLEM" ;;
  esac
}

# run_fleet_check <hosts>
# Returns 0 (all HEALTHY), 1 (one or more confirmed PROBLEM — takes
# priority over UNKNOWN, since a real finding must never be masked by an
# ambiguous one), or 2 (no PROBLEM anywhere, but one or more hosts landed
# in the UNKNOWN lane) — mirroring the main script's own three-way exit
# scheme (0/1/2) so callers already handling that at the top level don't
# need a fourth code invented just for --fleet.
run_fleet_check() {
  local hosts="$1"
  local any_problem=0
  local any_unknown=0
  local hosts_checked=0

  # Strip the same [[:space:]] class _kb_split_hosts tokenizes on (not just
  # a literal space) — otherwise an all-tab/all-newline "hosts" string
  # would read as non-empty here, fall through into the loop below, get
  # tokenized down to zero real hosts by _kb_split_hosts, and silently
  # return 0 (healthy) via hosts_checked staying 0 — "configured but
  # entirely whitespace" must be caught here, not discovered as an
  # accidental zero-hosts no-op two steps later.
  if [ -z "${hosts//[[:space:]]/}" ]; then
    echo "FLEET: no hosts configured (KB_KNOWLEDGE_SYNC_FLEET_HOSTS / --fleet-hosts is empty) — nothing to check." >&2
    return 1
  fi

  if ! command -v ssh >/dev/null 2>&1; then
    echo "FAIL-CLOSED: ssh is not on PATH — cannot run --fleet checks." >&2
    return 1
  fi

  # Sanitize before it ever reaches a remote command line — integers only,
  # falling back to the script's own default otherwise. This value is
  # normally operator-set (env var or --fleet-hosts sibling flag), but a
  # remote command string is exactly the wrong place to trust an unchecked
  # value on principle.
  local threshold="$SYNC_CACHE_STALE_SECONDS"
  case "$threshold" in (""|*[!0-9]*) threshold=3600 ;; esac

  # A here-doc, not a pipe, feeds the while loop below on purpose: a
  # `_kb_split_hosts "$hosts" | while read -r host; do ... done` pipeline
  # would run the loop BODY in a subshell under both bash and zsh, so
  # any_problem/any_unknown/hosts_checked (set INSIDE the loop) would be
  # invisible to this function once the pipeline ends. The here-doc form
  # runs the loop in THIS shell, so all three survive. Same "don't call a
  # state-setting routine inside a subshell" discipline the test suite
  # documents on run_check/run_fleet_probe_local, applied here to the loop
  # body instead of a function call.
  local host
  while IFS= read -r host; do
    [ -n "$host" ] || continue
    hosts_checked=$((hosts_checked + 1))
    local out rc
    out="$(printf '%s\n' "$_KB_FLEET_PROBE_SCRIPT" \
      | ssh -o BatchMode=yes -o ConnectTimeout=8 -- "$host" \
        "KB_KNOWLEDGE_SYNC_CACHE_STALE_SECONDS='${threshold}' /bin/bash -s" 2>&1)"
    rc=$?

    # An unreachable host (ssh itself failed) or a completely empty
    # response is PROBLEM, never merely UNKNOWN — this machine gave us
    # NOTHING to reason about, which is strictly less information than a
    # well-formed probe with only its RUN field unresolved. Preserves the
    # pre-existing behavior for this specific branch (never touched by
    # this round's fix — only _kb_fleet_host_classify's RUN handling
    # changed).
    if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
      echo "FLEET ${host}: unreachable or probe failed (ssh rc=${rc}) — never treated as converged." >&2
      any_problem=1
      continue
    fi

    # XACA-1259-008 PR gate round 7, cosmetic item 1: extract the
    # MARKER-DELIMITED probe line BEFORE the human-facing display line, not
    # after — so the marker prefix itself never leaks into what a person
    # reads (it exists only to disambiguate the classifier's input from ssh/
    # PAM/locale noise; it is implementation detail, not information).
    # Falls back to the RAW `$out` for display ONLY when no marker was
    # found at all (garbage/unparseable input, CASE17c's own case) — that
    # raw text is the only diagnostic signal available in that situation,
    # and hiding it would be a real loss of transparency, not a cosmetic
    # gain. Classification (below) always uses the extracted `$probe_line`
    # regardless of which text gets displayed.
    #
    # XACA-1259-008 PR gate round 6, BLOCKING finding: classify the
    # MARKER-DELIMITED probe line, never the raw `$out` capture above.
    # `$out` is `2>&1`-captured, so it can (and, on any host's first
    # connection, routinely does) carry ssh/PAM/locale noise on either
    # side of the probe's real output — a `case` glob match against the
    # raw blob is not "narrow", it is checking the wrong string. Extract
    # via `grep -F` (fixed-string, not regex — the marker has no glob
    # metacharacters, but this is also immune if it ever did) for the
    # LAST matching line (defensive: a genuinely successful run emits the
    # marker exactly once, but "last" degrades safely over "first" if
    # noise ever echoed the literal marker text incidentally earlier in
    # the stream — the reviewer separately confirmed every realistic noise
    # source, a host-key warning, a MOTD, or even an xtrace of the probe's
    # own marker= assignment under a remote `set -x`, PRECEDES the final
    # echo, so `tail`, never `head`, is the direction that degrades safely
    # here), then strip the marker prefix. `_kb_fleet_host_classify`
    # keeps ITS OWN leading-space/start-of-string anchoring unchanged —
    # that argument was always sound, it just needed to run against a
    # line, not a blob. If no marker is found at all (e.g. the remote
    # command crashed before its final echo, or the whole response was
    # noise), $probe_line is empty, and every one of the classifier's
    # anchored checks correctly fails to match an empty string —
    # PROBLEM, the same fail-closed behavior as any other unparseable
    # response, no special-casing needed here.
    local probe_line
    probe_line="$(printf '%s\n' "$out" | grep -F "$_KB_FLEET_PROBE_MARKER" | tail -n 1)"
    probe_line="${probe_line#*"$_KB_FLEET_PROBE_MARKER"}"

    # Display the CLEAN extracted line when one was found; fall back to the
    # raw capture only when extraction found nothing to show instead.
    if [ -n "$probe_line" ]; then
      echo "FLEET ${host}: ${probe_line}"
    else
      echo "FLEET ${host}: ${out}"
    fi

    local classification
    classification="$(_kb_fleet_host_classify "$probe_line")"
    case "$classification" in
      HEALTHY)
        ;;
      UNKNOWN)
        any_unknown=1
        echo "FLEET ${host}: UNKNOWN/AMBIGUOUS — scheduler, sync state, and cache freshness are all confirmed healthy, but run evidence (RUN=UNKNOWN) is absent. NOT counted as a confirmed problem — see check_run_evidence's own rationale (a rebooted machine's /tmp clears, so absence here is the ORDINARY state of a healthy host, not a finding)." >&2
        ;;
      *)
        any_problem=1
        ;;
    esac
  done <<HOSTS_EOF
$(_kb_split_hosts "$hosts")
HOSTS_EOF

  if [ "$VERBOSE" = "1" ]; then
    echo "FLEET: ${hosts_checked} host(s) probed."
  fi

  # STRUCTURAL GUARD (XACA-1259-008, PR gate round 4, finding 1): the
  # emptiness check above (and _kb_split_hosts's own tokenizer) are what is
  # SUPPOSED to guarantee hosts_checked > 0 whenever this function did not
  # already return early — but a pattern-matching fix to either one is
  # exactly the kind of thing a future edit can silently narrow again
  # (this is the SAME "two sites must agree on a separator" class that
  # regressed once already: XACA-1259-018 fixed _kb_split_hosts's pattern
  # but left this function's OWN emptiness check on a literal space,
  # which the reviewer proved reaches a real false green — an all-tab
  # hosts string used to fall through this function's guards, tokenize to
  # NOTHING, leave the loop body never entered, and return 0/HEALTHY
  # having probed ZERO hosts). Rather than trust the emptiness check and
  # the tokenizer to keep agreeing with each other forever, assert the
  # INVARIANT directly, in the one place that actually knows whether
  # anything was probed: hosts_checked -eq 0 can NEVER return healthy,
  # full stop, regardless of what upstream logic let it get here. This
  # holds even if a FUTURE separator (or any other tokenizer bug) slips
  # past the emptiness check the same way tabs once did.
  if [ "$hosts_checked" -eq 0 ]; then
    echo "FLEET: hosts were configured (\"${hosts}\") but ZERO were actually probed — the tokenizer produced no usable host from that string. Treating as a confirmed problem, never as healthy; this must never happen if the emptiness check above and _kb_split_hosts agree, but is asserted here directly rather than trusted." >&2
    return 1
  fi

  if [ "$any_problem" -eq 1 ]; then
    return 1
  fi
  if [ "$any_unknown" -eq 1 ]; then
    return 2
  fi
  return 0
}

# Internal testing hook (undocumented in usage() on purpose — not for
# production/hook use): runs the EXACT probe script used by --fleet, but
# locally via `bash -c` with no ssh/network involved, so the freshness-gate
# logic above can be exercised deterministically against a disposable
# fixture repo. Honors the same env vars a real remote invocation would see
# (KB_KNOWLEDGE_REPO, KB_KNOWLEDGE_SYNC_LOG_PATH,
# KB_KNOWLEDGE_SYNC_CACHE_STALE_SECONDS). Prints the probe's one output
# line and exits 0 always (matching the probe's own `exit 0` contract) —
# callers assert on the printed CACHE=/SYNC=/etc. fields, not on this exit
# code.
if [ "$TEST_FLEET_PROBE_LOCAL" = "1" ]; then
  bash -c "$_KB_FLEET_PROBE_SCRIPT"
  exit 0
fi

# ── Main ─────────────────────────────────────────────────────────────────
PROBLEM=0
AMBIGUOUS=0
AMBIGUOUS_RUN_EVIDENCE=0
AMBIGUOUS_NOTIFY_STATE=0

if check_scheduler_installed; then
  echo "SCHEDULER: installed+loaded (${SCHEDULER_WINNING_LABEL})"
else
  echo "SCHEDULER: NOT SCHEDULED — no knowledge-sync LaunchAgent installed+loaded in either namespace (${LABEL_DEVTEAM}, ${LABEL_AITEAMFORGE})." >&2
  PROBLEM=1
fi

if check_sync_divergence; then
  echo "SYNC STATE: 0 ahead, 0 behind ${SYNC_UPSTREAM} (cached, no fetch)"
else
  if [ "$SYNC_UNVERIFIED" -eq 1 ]; then
    PROBLEM=1
  else
    [ -n "$SYNC_UPSTREAM" ] && echo "SYNC STATE: ${SYNC_AHEAD} ahead, ${SYNC_BEHIND} behind ${SYNC_UPSTREAM} (cached, no fetch)"
    [ "$SYNC_DIVERGED" -eq 1 ] || [ "$SYNC_STALLED" -eq 1 ] && PROBLEM=1
  fi
fi

# XACA-1259-007 fix (coordinator finding 2, self-contradictory output): the
# original single message always pointed at "SYNC STATE above" as its
# evidence, but when STALLED fired WITHOUT divergence (the common M3Pro
# shape — dirty tree, cache still reads a truthful 0/0 from before the tree
# went dirty), SYNC STATE reads CLEAN, so a reader following the pointer
# finds the opposite of the claim. Cite whichever condition actually fired,
# and phrase the stalled case as a forward-looking guarantee (no-ops on
# every FUTURE run) rather than as "not syncing right now", since the cache
# it's reading may well be truthfully clean as of the last successful run.
if [ "$SCHEDULER_OK" -eq 1 ]; then
  if [ "$SYNC_STALLED" -eq 1 ] && [ "$SYNC_DIVERGED" -eq 1 ]; then
    if [ "$SYNC_DIVERGED_SELF_HEAL" -eq 1 ]; then
      # XACA-1291-024/-026: agrees with the UNWIND-PENDING / STRANDED
      # (unwind pending) findings above. A prediction, not a promise.
      echo "WARNING: scheduler is installed+loaded; ~/knowledge is dirty AND diverged, and every ahead commit is this host's own knowledge-sync auto-commit (see the UNWIND-PENDING finding above). The daemon will try to unwind them on its next tick; if this is still reported after that tick, a human must resolve it (last_outcome_token=${_HC_UNWIND_TOKEN:-<none>})." >&2
    else
      echo "WARNING: scheduler is installed+loaded, but ~/knowledge is STALLED (see the STRANDED finding above) — it CANNOT RECEIVE until a human resolves it, and CANNOT SEND either way (auto-commit and push both require the tree to be caught up and quiescent first — XACA-1291 preconditions P2/P3). Installation is not evidence of successful sync." >&2
    fi
  elif [ "$SYNC_STALLED" -eq 1 ]; then
    # XACA-1266: SYNC_STALLED without SYNC_DIVERGED can now ONLY come from
    # the mid-rebase/merge branch of check_sync_divergence — a plain dirty
    # tree no longer sets SYNC_STALLED by itself (it converges inbound via
    # fetch + fast-forward). Mid-rebase genuinely blocks everything, so the
    # forward-looking "will no-op on every future run" claim stays accurate
    # for THIS branch specifically. The SYNC STATE line above reflects the
    # cache as of the last successful sync, NOT current health — it can
    # read clean while future syncing is already blocked.
    echo "WARNING: scheduler is installed+loaded, but ~/knowledge has an in-progress rebase/merge (see the STALLED finding above) — this GUARANTEES kb-knowledge-sync.sh will no-op (neither RECEIVE nor SEND) on every future run until a human resolves it." >&2
  elif [ "$SYNC_DIVERGED" -eq 1 ]; then
    echo "WARNING: scheduler is installed+loaded but ~/knowledge is diverged from its upstream (see SYNC STATE above) — installation is not evidence the divergence has been (or will be) resolved." >&2
  fi
fi

if check_run_evidence; then
  echo "RUN EVIDENCE: found (${SYNC_LOG_PATH})"
else
  echo "RUN EVIDENCE: unknown/no evidence (${SYNC_LOG_PATH}) — ambiguous, not a confirmed failure."
  AMBIGUOUS=1
  AMBIGUOUS_RUN_EVIDENCE=1
fi

# NOTIFY STATE (XACA-1266-004 continuation, the design §4.4 reader half).
# check_notify_state does ALL of its own finding-line printing (mirrors
# check_run_evidence's own shape); this block only interprets its 0/1/2
# return code. Deliberately does NOT touch PROBLEM/AMBIGUOUS from the
# SYNC STATE / STALE-CACHE block above — separate lane, separate verdict,
# by design (see the function's own header comment for why).
check_notify_state
NOTIFY_RC=$?
case "$NOTIFY_RC" in
  0)
    echo "NOTIFY STATE: ${NOTIFY_COUNT} consecutive unproductive tick(s) (threshold ${NOTIFY_THRESHOLD}), last outcome: ${NOTIFY_TOKEN:-unknown}; outbound: ${NOTIFY_OUTBOUND_COUNT} withheld tick(s) (threshold ${NOTIFY_OUTBOUND_THRESHOLD}), last ${NOTIFY_OUTBOUND_TOKEN:-unknown}"
    ;;
  1)
    PROBLEM=1
    ;;
  2)
    AMBIGUOUS=1
    AMBIGUOUS_NOTIFY_STATE=1
    ;;
esac

# XACA-1487: warn-only INDEX size early warning (no verdict impact).
_kb_check_index_size

if [ "$FLEET" -eq 1 ]; then
  echo "── FLEET CHECK ──"
  run_fleet_check "$FLEET_HOSTS"
  FLEET_RC=$?
  # Three-way, matching run_fleet_check's own 0/1/2 return contract: a
  # confirmed problem on any host (1) always wins; otherwise an UNKNOWN-only
  # result (2) maps to the script's own AMBIGUOUS lane, NOT to PROBLEM — a
  # host with RUN=UNKNOWN but everything else confirmed healthy must never
  # read the same as a genuine finding (XACA-1259-008, second round).
  if [ "$FLEET_RC" -eq 1 ]; then
    PROBLEM=1
  elif [ "$FLEET_RC" -eq 2 ]; then
    AMBIGUOUS=1
  fi
fi

if [ "$PROBLEM" -eq 1 ]; then
  echo "OVERALL: NOT HEALTHY — see findings above." >&2
  exit 1
fi

if [ "$AMBIGUOUS" -eq 1 ]; then
  # Name whichever lane(s) actually fired rather than a message that always
  # cites "run evidence" even when it was the notify-state lane (or a fleet
  # host) that was actually unconfirmed — same accuracy standard this
  # ticket applied to the STALLED/STRANDED wording elsewhere in this file.
  _ambiguous_reasons=""
  [ "$AMBIGUOUS_RUN_EVIDENCE" -eq 1 ] && _ambiguous_reasons="run evidence"
  if [ "$AMBIGUOUS_NOTIFY_STATE" -eq 1 ]; then
    if [ -n "$_ambiguous_reasons" ]; then
      _ambiguous_reasons="${_ambiguous_reasons} and notify state"
    else
      _ambiguous_reasons="notify state"
    fi
  fi
  if [ "$FLEET" -eq 1 ] && [ "${FLEET_RC:-0}" -eq 2 ]; then
    if [ -n "$_ambiguous_reasons" ]; then
      _ambiguous_reasons="${_ambiguous_reasons} and one or more fleet hosts"
    else
      _ambiguous_reasons="one or more fleet hosts"
    fi
  fi
  [ -z "$_ambiguous_reasons" ] && _ambiguous_reasons="an unspecified check"
  echo "OVERALL: AMBIGUOUS — no confirmed problem, but ${_ambiguous_reasons} could not be confirmed." >&2
  exit 2
fi

echo "OVERALL: healthy"
exit 0
