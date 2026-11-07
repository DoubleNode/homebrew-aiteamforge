#!/usr/bin/env bash
# kb-live-config-drift-guard.sh
#
# SessionStart hook — surfaces drift between the TRACKED deploy sources and the
# LIVE copies in ~/.claude/, and staleness in the installed git hooks.
#
# XACA-0208 follow-up (2026-09-09). XACA-0208 automated tracked -> live via a
# post-merge hook and closed complete; nothing ever watched the reverse. The
# live ~/.claude/CLAUDE.md was found carrying XACA-0822 and XACA-1122 edits
# present nowhere in git, and both installed hooks were stale. CI cannot see any
# of it — the live copy does not exist on a runner — so this session-start check
# is the only layer with visibility.
#
# Thin wrapper, same house rule as every other guard here
# (aiteamforge-stub-guard.sh, kb-lcars-port-drift-guard.sh): all detection lives
# in scripts/kb-live-config-drift-check.sh, which has meaningful exit codes for
# direct/CI use. This wrapper only runs it, renders a non-zero exit as a warning,
# and NEVER blocks the session — it always exits 0.
#
# NEVER auto-remediates. The check deliberately does not know whether live or
# tracked is correct, and this wrapper adds no remediation opinion on top.
#
# Scope-guarded (dev mode) to the main repo: the live copies are per-MACHINE, so
# running this from every worktree would report the same drift N times.
# Two modes (XACA-1753-006): dev checkout vs installed tap templates; see the checker.

# XACA-1753: resolve the detector (and the mode) from the hook's OWN location via
# the shared resolver, not a hardcoded checkout path. Dev tree: a sibling in
# <repo>/scripts. Tap/installed: a sibling of this hook. M3Pro keeps working via
# the resolver's documented legacy fallback.
_AITF_SELF="${BASH_SOURCE[0]:-$0}"
_AITF_SELF="$(readlink -f "$_AITF_SELF" 2>/dev/null || printf '%s' "$_AITF_SELF")"
_AITF_LIB="$(dirname "$_AITF_SELF")/aitf-root.sh"
if [ -f "$_AITF_LIB" ]; then
    . "$_AITF_LIB"
else
    echo "WARNING: kb-live-config-drift-guard: could not check: aitf-root.sh not found (looked in $_AITF_LIB)" >&2
    exit 0
fi
aitf_init "$_AITF_SELF"
aitf_locate scripts/kb-live-config-drift-check.sh
CHECK="$AITF_FOUND"

if [ -z "$CHECK" ]; then
    # A guard whose detector is missing must say so. Silence here is exactly the
    # failure this hook exists to catch: a check that never runs and a check
    # that passes are indistinguishable to the reader.
    echo "WARNING: kb-live-config-drift-guard: could not check: detector not found (looked in $AITF_LOOKED)" >&2
    exit 0
fi

# Scope guard, DEV MODE ONLY (deploy-to-production.sh beside the detector's repo
# root = a dev checkout): only the main repo, not worktrees (see scope note
# above). A consumer has one live ~/.claude per machine and nothing to scope.
REPO="$(cd "$(dirname "$CHECK")/.." 2>/dev/null && pwd -P)"
if [ -f "$REPO/deploy-to-production.sh" ]; then
    [ -d "$REPO/.git" ] || exit 0   # worktree (.git is a file) or export: skip
    if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
        _P="$(cd "$CLAUDE_PROJECT_DIR" 2>/dev/null && pwd -P || printf '%s' "$CLAUDE_PROJECT_DIR")"
        case "$_P" in
            "$REPO"|"$REPO"/*) ;;
            *) exit 0 ;;
        esac
    fi
fi

# Exit 2 = "could not check" (neither mode's inputs found): render it, never 0-silent.
OUT="$("$CHECK" 2>&1)"; RC=$?
[ -n "$OUT" ] && printf '%s\n' "$OUT"
[ "$RC" -eq 2 ] && echo "WARNING: kb-live-config-drift-guard: could not check (detector exit 2, see above)" >&2
exit 0
