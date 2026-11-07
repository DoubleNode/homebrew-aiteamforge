#!/usr/bin/env bash
#
#  kb-where-refresh.sh
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
# Keeps the `kb-where` snapshot fresh (XACA-1607-004). Registered under BOTH
# Stop and SessionStart in claude/settings.json.
#
# CONTRACT (this runs inside every Claude session, so it must never hurt one):
#   * ALWAYS exits 0 and prints NOTHING on stdout. The one exception (XACA-1753):
#     when kb-where itself cannot be located it says so on STDERR.
#   * Never blocks: the real work (`kb-where --write-snapshot`) is detached into
#     the background with stdio on /dev/null; the hook returns immediately.
#   * Stop is THROTTLED by the snapshot's own mtime (60 s per team, no second
#     state file). SessionStart never throttles.
#   * Refreshes only the team of the invoking window (from the $TMUX socket
#     name). No tmux context (subagents, CI) => silent no-op.
#   * A stale-after-60s O_EXCL lock inside kb-where stops 12 windows ending a
#     turn together from running 12 collectors.
#   * Kill switch: KB_WHERE_DISABLE=1.
#
# Env for tests: KB_WHERE_DIR (snapshot dir), KB_WHERE_BIN (script path),
# KB_WHERE_THROTTLE_SECONDS (default 60).

# Deliberately no `set -e`: nothing in here is allowed to fail the session.
trap 'exit 0' EXIT

[ "${KB_WHERE_DISABLE:-0}" = "1" ] && exit 0

# Read hook JSON from stdin only when it is a pipe/file, with a short timeout.
INPUT=""
if [ ! -t 0 ]; then
    IFS= read -r -t 1 -d '' INPUT 2>/dev/null || true
fi
EVENT="Stop"
case "$INPUT" in
    *'"hook_event_name":"SessionStart"'* | *'"hook_event_name": "SessionStart"'*) EVENT="SessionStart" ;;
esac

# Team = tmux socket basename (the first comma field of $TMUX).
SOCK_PATH="${TMUX%%,*}"
[ -n "$SOCK_PATH" ] || exit 0
TEAM="${SOCK_PATH##*/}"
case "$TEAM" in
    "" | *[!A-Za-z0-9._-]*) exit 0 ;;
esac

SNAP_DIR="${KB_WHERE_DIR:-$HOME/.aiteamforge/run/where}"
THROTTLE="${KB_WHERE_THROTTLE_SECONDS:-60}"

if [ "$EVENT" != "SessionStart" ]; then
    # GNU `stat -c` first: BSD stat rejects -c (falls through to -f %m), whereas GNU
    # `stat -f %m` is the *filesystem* form and can exit 0 with garbage on Linux.
    MTIME=$(stat -c %Y "$SNAP_DIR/$TEAM.json" 2>/dev/null || stat -f %m "$SNAP_DIR/$TEAM.json" 2>/dev/null || echo 0)
    case "$MTIME" in "" | *[!0-9]*) MTIME=0 ;; esac
    NOW=$(date +%s)
    if [ $((NOW - ${MTIME:-0})) -lt "$THROTTLE" ] 2>/dev/null; then
        exit 0
    fi
fi

# Locate kb-where: explicit override (tests), else the shared resolver
# (aitf-root.sh, a sibling of this hook in the dev, tap and installed layouts):
# own location, AITEAMFORGE_DIR, then the legacy checkout / default install.
# XACA-1753: failing to find it is REPORTED on stderr (never stdout, never a
# non-zero exit: the never-hurt-a-session contract above stands). By this point
# there IS a tmux team context, so subagents/CI stay quiet. An explicit
# KB_WHERE_BIN that is unusable stays silent: that is a test/operator override.
BIN="${KB_WHERE_BIN:-}"
if [ -z "$BIN" ]; then
    _AITF_SELF="${BASH_SOURCE[0]:-$0}"
    _AITF_SELF="$(readlink -f "$_AITF_SELF" 2>/dev/null || printf '%s' "$_AITF_SELF")"
    _AITF_LIB="$(dirname "$_AITF_SELF")/aitf-root.sh"
    if [ -f "$_AITF_LIB" ]; then
        . "$_AITF_LIB"
        aitf_init "$_AITF_SELF"
        aitf_locate scripts/kb-where || true
        BIN="$AITF_FOUND"
        _LOOKED="$AITF_LOOKED"
    else
        _LOOKED="$_AITF_LIB (aitf-root.sh missing)"
    fi
    if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
        echo "kb-where-refresh: could not refresh: kb-where not found or not executable (looked in $_LOOKED)" >&2
        exit 0
    fi
fi
[ -n "$BIN" ] && [ -x "$BIN" ] || exit 0

PY="$(command -v python3 2>/dev/null || true)"
[ -n "$PY" ] || PY=/usr/bin/python3
[ -x "$PY" ] || exit 0

# Detach: the subshell exits at once, the grandchild is reparented, stdio is /dev/null.
( "$PY" "$BIN" --write-snapshot --quiet --team "$TEAM" --writer "hook:$EVENT" \
    </dev/null >/dev/null 2>&1 & ) >/dev/null 2>&1

exit 0
