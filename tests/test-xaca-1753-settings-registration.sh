#!/bin/bash
# test-xaca-1753-settings-registration.sh
#
# XACA-1753-004: the seven session-guard hooks shipped in share/scripts/ must be
# REGISTERED by the tap's settings.json.template, and the REAL
# merge_settings_json() (sourced from install-claude-config.sh, not a copy) must
# union them into an existing box settings.json without dropping box-local hooks
# and without duplicating a registration on re-run.
#
# Also documents (as a NOTE, not a failure) the stale-entry behaviour: a base
# entry registering the SAME hook at an old ~/dev-team path is a different
# object, so the union keeps it alongside the new one.
#
# Sandboxed: scratch dir for everything, no real $HOME mutation, no network.
# Exit 0 = all pass and >=1 assertion ran; 1 = any fail or zero assertions.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALLER="$TAP_ROOT/libexec/installers/install-claude-config.sh"
TEMPLATE="$TAP_ROOT/share/templates/claude/settings.json.template"
for _need in "$INSTALLER" "$TEMPLATE"; do
    [ -f "$_need" ] || { echo "FATAL: required file not found: $_need" >&2; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq is required" >&2; exit 1; }

_PASS=0; _FAIL=0
ok()   { _PASS=$((_PASS + 1)); echo "  PASS: $1"; }
bad()  { _FAIL=$((_FAIL + 1)); echo "  FAIL: $1"; }
check() { # desc, expected, actual
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/xaca1753-reg.XXXXXX")" || exit 1
trap 'find "$WORK" -delete 2>/dev/null' EXIT
export HOME="$WORK/home"; mkdir -p "$HOME"
unset TMUX GIT_DIR GIT_WORK_TREE
export AITEAMFORGE_DIR="$WORK/atf"
export CLAUDE_CONFIG_DIR="$WORK/claude"
export USER="${USER:-tester}"
mkdir -p "$AITEAMFORGE_DIR" "$CLAUDE_CONFIG_DIR"

# Source the REAL installer (main is guarded by BASH_SOURCE == $0). It enables
# set -e/-u/pipefail; relax them for the harness.
# shellcheck disable=SC1090
source "$INSTALLER"
set +e +u +o pipefail
if ! { type -t merge_settings_json >/dev/null && type -t apply_template >/dev/null; }; then
    echo "FATAL: installer did not define merge_settings_json/apply_template" >&2
    exit 1
fi

# event|script|timeout  (where-refresh is registered under both events)
EXPECT="SessionStart|kb-session-knowledge-check.sh|20
SessionStart|kanban-crash-detect.sh|20
SessionStart|kb-lcars-port-drift-guard.sh|20
SessionStart|kb-team-registry-loss-guard.sh|20
SessionStart|kb-knowledge-sync-guard.sh|20
SessionStart|kb-gh-credential-guard.sh|20
SessionStart|kb-where-refresh.sh|10
Stop|kb-where-refresh.sh|10"

# count registrations of an exact command string under an event in a file
count_cmd() { # file event command
    jq --arg e "$2" --arg c "$3" \
        '[.hooks[$e][]?.hooks[]? | select(.command == $c)] | length' "$1"
}
timeout_of() { # file event command
    jq -r --arg e "$2" --arg c "$3" \
        '[.hooks[$e][]?.hooks[]? | select(.command == $c) | .timeout][0] // "none"' "$1"
}

echo "== R1: template renders to valid JSON via the real apply_template"
RENDERED="$WORK/rendered.json"
apply_template "$TEMPLATE" "$RENDERED" >/dev/null
if jq empty "$RENDERED" 2>/dev/null; then ok "rendered template is valid JSON"; else bad "rendered template is NOT valid JSON"; fi
check "no unsubstituted {{AITEAMFORGE_DIR}} left" "0" "$(grep -c '{{AITEAMFORGE_DIR}}' "$RENDERED")"

echo "== R2: each hook registered under the right event, timeout, tap path"
while IFS='|' read -r ev scr to; do
    cmd="$AITEAMFORGE_DIR/scripts/$scr"
    check "$ev registers $scr exactly once" "1" "$(count_cmd "$RENDERED" "$ev" "$cmd")"
    check "$ev $scr timeout" "$to" "$(timeout_of "$RENDERED" "$ev" "$cmd")"
done <<< "$EXPECT"
check "template carries no hardcoded dev-team path" "0" "$(grep -c 'dev-team' "$TEMPLATE")"

echo "== R3: merge keeps box-local hook, adds new entries, keeps stale old-path entry"
BASE="$WORK/base.json"
LOCAL_CMD="bash $CLAUDE_CONFIG_DIR/hooks/box-local-session.sh"
OLD_CMD="$HOME/dev-team/claude-hooks/kb-where-refresh.sh"
jq -n --arg l "$LOCAL_CMD" --arg o "$OLD_CMD" '{
  hooks: { SessionStart: [
      {hooks:[{type:"command",command:$l}]},
      {hooks:[{type:"command",command:$o,timeout:10}]} ] }
}' > "$BASE"
M1="$WORK/m1.json"; M2="$WORK/m2.json"; M3="$WORK/m3.json"
merge_settings_json "$BASE" "$RENDERED" "$M1"
if jq empty "$M1" 2>/dev/null; then ok "merge output valid JSON"; else bad "merge output invalid JSON"; fi
check "box-local SessionStart hook preserved" "1" "$(count_cmd "$M1" SessionStart "$LOCAL_CMD")"
while IFS='|' read -r ev scr to; do
    check "after merge: $ev $scr present once" "1" "$(count_cmd "$M1" "$ev" "$AITEAMFORGE_DIR/scripts/$scr")"
done <<< "$EXPECT"
STALE=$(count_cmd "$M1" SessionStart "$OLD_CMD")
echo "  NOTE: stale old-path entry ($OLD_CMD) count after merge = $STALE (merge unions; it does not retire old paths)"

echo "== R4: idempotent -- re-running the merge adds nothing"
merge_settings_json "$M1" "$RENDERED" "$M2"
merge_settings_json "$M2" "$RENDERED" "$M3"
check "run2 == run1 (hooks)" "$(jq -S -c .hooks "$M1")" "$(jq -S -c .hooks "$M2")"
check "run3 == run1 (hooks)" "$(jq -S -c .hooks "$M1")" "$(jq -S -c .hooks "$M3")"
check "SessionStart entry count stable" "$(jq '.hooks.SessionStart|length' "$M1")" "$(jq '.hooks.SessionStart|length' "$M3")"
check "Stop entry count stable" "$(jq '.hooks.Stop|length' "$M1")" "$(jq '.hooks.Stop|length' "$M3")"
while IFS='|' read -r ev scr to; do
    check "after 3 runs: $ev $scr still exactly once" "1" "$(count_cmd "$M3" "$ev" "$AITEAMFORGE_DIR/scripts/$scr")"
done <<< "$EXPECT"
check "box-local hook still once after 3 runs" "1" "$(count_cmd "$M3" SessionStart "$LOCAL_CMD")"
echo "  counts: SessionStart entries base=$(jq '.hooks.SessionStart|length' "$BASE") run1=$(jq '.hooks.SessionStart|length' "$M1") run3=$(jq '.hooks.SessionStart|length' "$M3")"

echo "== R5: negative control -- a template missing a hook is detected"
BROKEN="$WORK/broken.json"
jq '.hooks.SessionStart |= map(select(any(.hooks[]; (.command|endswith("kanban-crash-detect.sh")))|not))' "$RENDERED" > "$BROKEN"
check "negative control: crash-detect absent from broken template" "0" "$(count_cmd "$BROKEN" SessionStart "$AITEAMFORGE_DIR/scripts/kanban-crash-detect.sh")"
merge_settings_json "$BASE" "$BROKEN" "$WORK/mb.json"
check "negative control: merge of broken template lacks crash-detect" "0" "$(count_cmd "$WORK/mb.json" SessionStart "$AITEAMFORGE_DIR/scripts/kanban-crash-detect.sh")"

echo "== R6: every registered script ships in share/scripts/"
while IFS='|' read -r scr; do
    if [ -f "$TAP_ROOT/share/scripts/$scr" ]; then ok "share/scripts/$scr exists"; else bad "share/scripts/$scr MISSING from tap"; fi
done <<< "$(printf '%s\n' "$EXPECT" | awk -F'|' '!s[$2]++ {print $2}')"

echo ""
echo "Results: $_PASS passed, $_FAIL failed"
[ "$_FAIL" -eq 0 ] && [ "$_PASS" -gt 0 ]
