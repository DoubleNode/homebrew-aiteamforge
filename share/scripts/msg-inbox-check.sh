#!/usr/bin/env bash
#
#  msg-inbox-check.sh
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#
# kb-msg inbox surfacing hook (XACA-0777).
#
# Fires on SessionStart and on Stop (after every assistant turn). Tells the
# CURRENT session it has unread kb-msg mail so a chat learns another chat
# pinged it without manual polling.
#
# Rules that keep it from becoming another ignored nag, or a context hog:
#   1. EMPTY INBOX PRINTS NOTHING — no "you have 0 messages" noise.
#   2. ONE LINE, ever (XACA-1833). The live session only sees a count notice;
#      the listing/reading/replying happens in a comms subagent (nahla on
#      Academy; elsewhere a general-purpose agent handed `msg-store.py
#      triage-brief`), so the inbox never lands in the live context.
#   3. A per-TERMINAL 5-min timer (KB_MSG_THROTTLE_SECONDS, default 300)
#      gates Stop AND SessionStart. Only a brand-new session (SessionStart
#      source "startup") bypasses it, so "you have mail" shows on open.
#   4. The count covers this terminal's directed mail AND team broadcasts,
#      including broadcasts sent while this terminal had no live session
#      (msg-store.py unread-count --sync-broadcasts claims those).
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

# Read the hook event name (and SessionStart source) from stdin JSON
# (best-effort; default to "Stop").
INPUT="$(cat 2>/dev/null || true)"
EVENT="Stop"
SOURCE=""
if [ -n "$INPUT" ]; then
    _ev=$(printf '%s' "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('hook_event_name') or 'Stop', d.get('source') or '')
except Exception:
    print('Stop')
" 2>/dev/null || echo "Stop")
    EVENT="${_ev%% *}"
    case "$_ev" in *" "*) SOURCE="${_ev#* }" ;; esac
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

# Per-terminal timer on Stop AND SessionStart (XACA-1833). Only a brand-new
# session's SessionStart (source "startup") bypasses it; resume/clear/compact
# are gated like Stop.
TS_FILE="${THROTTLE_DIR}/.last_msg_inbox_check_${TEAM}_${TERMINAL}"
if ! { [ "$EVENT" = "SessionStart" ] && [ "$SOURCE" = "startup" ]; }; then
    NOW=$(date +%s)
    LAST=$(cat "$TS_FILE" 2>/dev/null || echo 0)
    case "$LAST" in ''|*[!0-9]*) LAST=0 ;; esac
    if [ $((NOW - LAST)) -lt "$THROTTLE_SECONDS" ]; then
        exit 0
    fi
fi

# Record the check time before checking (so throttling advances even on
# empty). mkdir -p first: on a fresh box / sandboxed HOME ~/.claude may not
# exist yet (parity with msg-store.py's _ensure_mail_dir).
mkdir -p "$THROTTLE_DIR" 2>/dev/null || true
date +%s > "$TS_FILE" 2>/dev/null || true

# One JSON object: total/team/terminal/scope counts, after claiming any team
# broadcasts this terminal missed while it had no live session.
COUNTS=$(python3 "$STORE" unread-count --team "$TEAM" --terminal "$TERMINAL" \
    --breakdown --sync-broadcasts 2>/dev/null || true)
[ -n "$COUNTS" ] || exit 0

NOTICE=$(printf '%s' "$COUNTS" | python3 -c "
import sys, json, shlex
term, team, store = sys.argv[1], sys.argv[2].lower(), sys.argv[3]
try:
    c = json.load(sys.stdin)
    total = int(c.get('total', 0))
except Exception:
    sys.exit(0)
if total <= 0:
    sys.exit(0)  # EMPTY INBOX PRINTS NOTHING
line = ('\U0001F4E8 kb-msg: %d unread (%d team-wide, %d for %s)'
        % (total, int(c.get('team', 0)), int(c.get('terminal', 0)), term))
scope = int(c.get('scope', 0))
if scope:
    srcs = ', '.join(c.get('scope_sources') or []) or 'outside'
    line += (' \u26a0 SCOPE (XACA-1296): %d from %s, escalate per rule 4'
             % (scope, srcs))
# Only Academy ships the nahla persona (XACA-1833 review): every other team
# gets a general-purpose subagent plus the brief msg-store.py prints, so the
# notice never names an agent the session cannot start.
if team == 'academy':
    line += ' \u2014 spawn the nahla comms subagent to triage (kb-msg inbox)'
else:
    line += (' \u2014 spawn a general-purpose subagent to triage; brief: python3 %s triage-brief'
             % shlex.quote(store))
print(line)
" "$TERMINAL" "$TEAM" "$STORE" 2>/dev/null || true)

[ -n "$NOTICE" ] && printf '%s\n' "$NOTICE"
exit 0
