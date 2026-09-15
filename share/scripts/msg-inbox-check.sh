#!/usr/bin/env bash
#
#  msg-inbox-check.sh
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#
# kb-msg inbox surfacing hook (XACA-0777).
#
# Fires on SessionStart and on Stop (after every assistant turn). Surfaces the
# CURRENT session's unread kb-msg mail so a chat learns another chat pinged it
# without manual polling.
#
# Two rules that keep it from becoming another ignored nag:
#   1. EMPTY INBOX PRINTS NOTHING — no "you have 0 messages" noise.
#   2. Stop is THROTTLED (default 5 min per session); SessionStart always shows.
#
# Register in ~/.claude/settings.json under BOTH SessionStart and Stop, e.g.:
#   "Stop":         [ { "hooks": [ { "type": "command",
#       "command": "bash ~/dev-team/claude-hooks/msg-inbox-check.sh" } ] } ],
#   "SessionStart": [ { "hooks": [ { "type": "command",
#       "command": "bash ~/dev-team/claude-hooks/msg-inbox-check.sh" } ] } ]

# XACA-1225: resolve the store without assuming AITEAMFORGE_DIR is exported.
# Claude Code hooks inherit whatever env launched the session, so on a tap
# consumer the old `${AITEAMFORGE_DIR:-$HOME/dev-team}` fell back to a
# ~/dev-team that does not exist there, and the `[ -f "$STORE" ] || exit 0`
# below turned that into silence: registered, doctor [ok], mail never shown.
# Order: explicit AITEAMFORGE_DIR, then this script's own parent (dev:
# claude-hooks/.. ; consumer: ~/aiteamforge/scripts/..), then both defaults.
_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
STORE=""
for _base in ${AITEAMFORGE_DIR:+"$AITEAMFORGE_DIR"} ${_self_dir:+"$_self_dir/.."} \
             "$HOME/aiteamforge" "$HOME/dev-team"; do
    if [ -f "$_base/kanban-hooks/msg-store.py" ]; then
        STORE="$_base/kanban-hooks/msg-store.py"
        break
    fi
done
THROTTLE_DIR="$HOME/.claude"
THROTTLE_SECONDS="${KB_MSG_THROTTLE_SECONDS:-300}"

[ -f "$STORE" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

# Read the hook event name from stdin JSON (best-effort; default to "Stop").
INPUT="$(cat 2>/dev/null || true)"
EVENT="Stop"
if [ -n "$INPUT" ]; then
    EVENT=$(printf '%s' "$INPUT" | python3 -c "
import sys, json
try:
    print(json.load(sys.stdin).get('hook_event_name', 'Stop'))
except Exception:
    print('Stop')
" 2>/dev/null || echo "Stop")
fi

# Resolve current session identity via tmux (mirrors _kb_detect_context split).
PANE_TARGET="${TMUX_PANE:-}"
if [ -n "$PANE_TARGET" ]; then
    SESSION_NAME=$(tmux display-message -t "$PANE_TARGET" -p '#S' 2>/dev/null || echo "")
else
    SESSION_NAME=$(tmux display-message -p '#S' 2>/dev/null || echo "")
fi

# Fall back to explicit env when there is no tmux pane (subagents/CI never nag).
if [ -n "$SESSION_NAME" ] && [ "${SESSION_NAME##*-}" != "$SESSION_NAME" ]; then
    TEAM="${SESSION_NAME%-*}"
    TERMINAL="${SESSION_NAME##*-}"
elif [ -n "${KB_TEAM:-}" ]; then
    TEAM="${KB_TEAM}"
    TERMINAL="${KB_TERMINAL:-agent}"
else
    exit 0
fi

# Throttle Stop (but never SessionStart) to avoid nagging on every turn.
TS_FILE="${THROTTLE_DIR}/.last_msg_inbox_check_${TEAM}_${TERMINAL}"
if [ "$EVENT" != "SessionStart" ]; then
    NOW=$(date +%s)
    LAST=$(cat "$TS_FILE" 2>/dev/null || echo 0)
    if [ $((NOW - LAST)) -lt "$THROTTLE_SECONDS" ]; then
        exit 0
    fi
fi

UNREAD=$(python3 "$STORE" unread-count --team "$TEAM" --terminal "$TERMINAL" 2>/dev/null || echo 0)

# Record the check time regardless (so throttling advances even on empty).
# mkdir -p first — THROTTLE_DIR is normally ~/.claude which exists, but on a
# fresh box / sandboxed HOME it may not yet (parity with msg-store.py's
# _ensure_mail_dir, which does the same before its first write).
mkdir -p "$THROTTLE_DIR" 2>/dev/null || true
date +%s > "$TS_FILE" 2>/dev/null || true

# EMPTY INBOX PRINTS NOTHING.
if [ -z "$UNREAD" ] || [ "$UNREAD" = "0" ]; then
    exit 0
fi

echo "📨 kb-msg: you (${TEAM}:${TERMINAL}) have ${UNREAD} unread message(s):"
python3 "$STORE" inbox --team "$TEAM" --terminal "$TERMINAL" 2>/dev/null
echo "   Read one: kb-msg read <id>   Reply: kb-msg reply <id> \"...\"   List: kb-msg inbox"
exit 0
