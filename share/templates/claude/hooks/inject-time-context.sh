#!/usr/bin/env bash
# inject-time-context.sh — UserPromptSubmit hook
# Injects <context-tick> date/time line only when state changes.
# Kill-switch: CLAUDE_TIME_INJECT=0 disables injection.
# Reads session_id from stdin JSON ({"session_id":"...","hook_event_name":"UserPromptSubmit",...})
# per Claude Code UserPromptSubmit contract — harness does NOT export CLAUDE_SESSION_ID to env.

set -euo pipefail

# --- Kill-switch (checked before stdin read — early exit is safe) ---
[[ "${CLAUDE_TIME_INJECT:-1}" == "0" ]] && exit 0

# --- Read session_id from stdin JSON (D1 fix) ---
# Claude Code passes hook metadata via stdin, not env vars.
# Consume stdin once; use python3 (already a dependency) for portability.
# D3 fix: sanitize session_id via positive whitelist [A-Za-z0-9._-] so
# untrusted input cannot escape STATE_DIR (e.g. session_id="../etc/passwd").
STDIN_JSON=$(cat)
SESSION_ID=$(printf '%s' "$STDIN_JSON" | python3 -c \
  "import sys,json,re
try:
    sid = json.load(sys.stdin).get('session_id','unknown')
except Exception:
    sid = 'unknown'
sid = re.sub(r'[^A-Za-z0-9._-]', '', sid) or 'unknown'
print(sid)" 2>/dev/null || echo "unknown")

STATE_DIR="${HOME}/.claude/state/time-inject"
STATE_FILE="${STATE_DIR}/${SESSION_ID}.json"
# D2 fix: silent exit when state dir cannot be created or is not writable.
# The hook is best-effort — if we can't persist state, we can't decide whether
# to inject, so skip rather than spam Claude Code's UI with stderr.
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
[[ -w "$STATE_DIR" ]] || exit 0

# --- Current values ---
NOW_DATE=$(date +%Y-%m-%d)
NOW_TIME=$(date +%H:%M)
NOW_TZ=$(date +%Z)              # e.g. PDT, UTC, EST
NOW_IANA=$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')  # e.g. America/Los_Angeles
# Quarter-hour bucket: HH:MM-floored-to-15. Hour MUST be included or
# 14:04 and 15:04 collapse to the same key.
NOW_HOUR=$(date +%H)
RAW_MIN=$(date +%-M)
QH_MIN=$(printf "%02d" $(( (RAW_MIN / 15) * 15 )))
QH_KEY="${NOW_HOUR}:${QH_MIN}"

# --- Read prior state ---
PRIOR_DATE=""
PRIOR_QH=""
PRIOR_IANA=""
FIRST_RUN="true"

if [[ -f "$STATE_FILE" ]]; then
  FIRST_RUN="false"
  PRIOR_DATE=$(python3 -c "import json,sys; d=json.load(open('$STATE_FILE')); print(d.get('date',''))" 2>/dev/null || echo "")
  PRIOR_QH=$(python3   -c "import json,sys; d=json.load(open('$STATE_FILE')); print(d.get('qh',''))"   2>/dev/null || echo "")
  PRIOR_IANA=$(python3 -c "import json,sys; d=json.load(open('$STATE_FILE')); print(d.get('iana',''))" 2>/dev/null || echo "")
fi

# --- Decide what to inject ---
INJECT=""
REASON=""

if [[ "$FIRST_RUN" == "true" ]]; then
  INJECT="${NOW_DATE} · ${NOW_TIME} ${NOW_TZ}"
  REASON="first-run"
elif [[ "$NOW_IANA" != "$PRIOR_IANA" ]]; then
  # DST/timezone shift — force full re-inject
  INJECT="${NOW_DATE} · ${NOW_TIME} ${NOW_TZ}"
  REASON="tz-shift"
elif [[ "$NOW_DATE" != "$PRIOR_DATE" ]]; then
  INJECT="${NOW_DATE} · ${NOW_TIME} ${NOW_TZ}"
  REASON="date-rollover"
elif [[ "${NOW_DATE}T${QH_KEY}" != "$PRIOR_QH" ]]; then
  INJECT="${NOW_DATE} · ${NOW_TIME} ${NOW_TZ}"
  REASON="qh-tick"
fi

# --- Write new state (atomic) ---
if [[ -n "$INJECT" ]]; then
  # D2 fix: silent fall-through if mktemp fails (e.g. dir made read-only mid-run).
  # Trap cleans up the .tmp.* orphan on any abnormal exit path before mv.
  TMP=$(mktemp "${STATE_DIR}/.tmp.XXXXXX" 2>/dev/null) || exit 0
  trap 'rm -f "$TMP" 2>/dev/null' EXIT
  python3 - "$TMP" "$NOW_DATE" "${NOW_DATE}T${QH_KEY}" "$NOW_IANA" "$NOW_TZ" "$REASON" <<'PYEOF'
import json, sys
_, tmp, date, qh, iana, tz, reason = sys.argv
data = {
    "date":   date,
    "qh":     qh,
    "iana":   iana,
    "tz":     tz,
    "reason": reason
}
with open(tmp, "w") as f:
    json.dump(data, f)
PYEOF
  mv "$TMP" "$STATE_FILE"

  # Emit injection via UserPromptSubmit protocol (D2 fix)
  # Canonical schema per Claude Code hooks docs:
  # {"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"..."}}
  python3 -c "
import json, sys
context_text = '<context-tick>' + sys.argv[1] + '</context-tick>'
payload = {
    'hookSpecificOutput': {
        'hookEventName': 'UserPromptSubmit',
        'additionalContext': context_text
    }
}
print(json.dumps(payload))
" "$INJECT"
fi

exit 0
