#!/bin/bash

# test-xaca-1753-upgrade-materialize.sh
# Regression tests for XACA-1753-005: the fleet session-guard set must reach
# UPGRADED machines (script files AND hook registrations), not only fresh installs.
#
# REGRESSION INTENT: sync-tap.sh mirrors the session guards, their checkers and
# aitf-root.sh into share/scripts/. update_runtime_helpers only refreshes what
# already exists under WORKING_DIR/scripts/, so every already-installed box would
# skip all of them unless each basename is in
# _xaca0673_mandatory_materialize_basenames. And the settings.json fill-absent
# refresh only manages scalar keys, so the template's hook registrations would
# never be wired (files present, nothing runs them).
#
# Assertions are made by LISTING the destination / parsing the resulting JSON,
# never by reading the upgrade log:
#   1. Every basename present after the REAL update_runtime_helpers, executable,
#      byte-identical; a stale copy is refreshed.
#   2. Negative control: one basename dropped from the list is NOT materialised.
#   3. Not aux-owned; install-shell.sh / validate-install.sh list every basename.
#   4. Real shipped copies survive the render byte-identically.
#   5. REAL update_claude_settings against a fixture settings.json with a
#      box-local SessionStart hook: every hook in the RENDERED TEMPLATE is present
#      exactly once, the box-local hook survives, a second run changes nothing,
#      a backup exists, and DRY_RUN writes nothing.
#
# Sandboxed to TEST_TMP_DIR. NEVER touches real $HOME / ~/.aiteamforge.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$TAP_ROOT/libexec/lib/atomic-write.sh"
UPGRADE_SH="$TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh"
INSTALL_SHELL_SH="$TAP_ROOT/libexec/installers/install-shell.sh"
VALIDATE_SH="$TAP_ROOT/libexec/lib/validate-install.sh"
TEMPLATE="$TAP_ROOT/share/templates/claude/settings.json.template"

_STANDALONE=false
if ! type -t test_start >/dev/null 2>&1; then
    _STANDALONE=true
    _PASS_COUNT=0
    _FAIL_COUNT=0
    _CURRENT_TEST=""
    test_start() { _CURRENT_TEST="$1"; echo "  >> $1"; }
    test_pass()  { _PASS_COUNT=$((_PASS_COUNT + 1)); echo "     PASS: $_CURRENT_TEST"; }
    test_fail()  { _FAIL_COUNT=$((_FAIL_COUNT + 1)); echo "     FAIL: $_CURRENT_TEST - $1" >&2; }
fi

for _p in print_section print_info print_success print_warning print_error; do
    if ! declare -f "$_p" >/dev/null 2>&1; then eval "${_p}() { :; }"; fi
done

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq is required" >&2; exit 1; }

if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca1753-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
cleanup() { if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then find "$TEST_TMP_DIR" -delete 2>/dev/null; fi; }
trap cleanup EXIT

_extract_fn() {
    awk -v fn="$1" '
      $0 ~ ("^" fn "\\(\\) \\{") { capture=1 }
      capture { print }
      capture && /^}$/ { exit }
    ' "$UPGRADE_SH"
}
for _fn in _xaca0608_render_team_script _xaca0608_aux_script_map \
           _xaca0608_aux_scriptdir_basenames _xaca0673_mandatory_materialize_basenames \
           _xaca1753_verbatim_basenames update_runtime_helpers update_claude_settings; do
    _src="$(_extract_fn "$_fn")"
    if [ -z "$_src" ]; then echo "FATAL: could not extract $_fn from upgrade.sh"; exit 1; fi
    eval "$_src"
    declare -f "$_fn" >/dev/null || { echo "FATAL: $_fn not defined after extraction"; exit 1; }
done
if ! declare -f _aitf_consumer_datafiles >/dev/null 2>&1; then
    _aitf_consumer_datafiles() { :; }
fi

# The set under test. A follow-on guard is a one-line addition here AND in
# _xaca0673_mandatory_materialize_basenames (+ install-shell.sh / validate-install.sh).
NAMES="aitf-root.sh
kb-gh-credential-guard.sh
kb-knowledge-sync-guard.sh
kanban-crash-detect.sh
kb-session-knowledge-check.sh
kb-team-registry-loss-guard.sh
kb-lcars-port-drift-guard.sh
kb-where-refresh.sh
kb-gh-credential-check.sh
kb-team-registry-loss-check.py
kb-knowledge-sync-health-check.sh
kb-lcars-port-drift-check.sh
kb-live-config-drift-guard.sh
kb-live-config-drift-check.sh"
N_NAMES="$(printf '%s\n' "$NAMES" | wc -l | tr -d ' ')"

SANDBOX="$TEST_TMP_DIR/xaca1753"
FW="$SANDBOX/framework"
mkdir -p "$FW/share/scripts"
while IFS= read -r n; do
    printf '#!/bin/bash\n# XACA-1753 fixture stub for %s\necho "stub %s"\n' "$n" "$n" > "$FW/share/scripts/$n"
    chmod 644 "$FW/share/scripts/$n"   # source NOT executable: exec bit must come from the render
done <<< "$NAMES"
printf '#!/bin/bash\necho optional\n' > "$FW/share/scripts/zz-xaca1753-optional.sh"

_new_working() {
    mkdir -p "$1/scripts"
    printf '#!/bin/bash\n# pre-existing sibling\n' > "$1/scripts/kanban-helpers.sh"
    chmod +x "$1/scripts/kanban-helpers.sh"
}
_run_helpers() {
    FRAMEWORK_DIR="$FW" WORKING_DIR="$1" FORCE=false DRY_RUN=false \
        update_runtime_helpers >/dev/null 2>&1
}
_has_line() { case $'\n'"$2"$'\n' in *$'\n'"$1"$'\n'*) return 0 ;; esac; return 1; }

W1="$SANDBOX/working1"
_new_working "$W1"
printf '#!/bin/bash\n# STALE old aitf-root\n' > "$W1/scripts/aitf-root.sh"
chmod 644 "$W1/scripts/aitf-root.sh"
_run_helpers "$W1"
LISTING="$(ls -1 "$W1/scripts")"

test_start "All $N_NAMES session-guard basenames are present after upgrade (directory listing)"
_ok=true
while IFS= read -r n; do
    _has_line "$n" "$LISTING" || { _ok=false; echo "     MISSING: $n" >&2; }
done <<< "$NAMES"
if [ "$_ok" = true ]; then test_pass; else test_fail "basename(s) not materialised on upgrade"; fi

test_start "Each materialised file is executable and byte-identical to source"
_ok=true
while IFS= read -r n; do
    [ -x "$W1/scripts/$n" ] || { _ok=false; echo "     NOT-EXEC: $n" >&2; }
    cmp -s "$FW/share/scripts/$n" "$W1/scripts/$n" || { _ok=false; echo "     DIFFERS: $n" >&2; }
done <<< "$NAMES"
if [ "$_ok" = true ]; then test_pass; else test_fail "exec bit / content mismatch"; fi

test_start "Stale pre-existing aitf-root.sh was refreshed"
if cmp -s "$FW/share/scripts/aitf-root.sh" "$W1/scripts/aitf-root.sh" && ! grep -q STALE "$W1/scripts/aitf-root.sh"; then
    test_pass
else
    test_fail "stale copy not refreshed"
fi

test_start "Optional non-listed script stays absent (sweep stays 'refresh only what exists')"
if _has_line "zz-xaca1753-optional.sh" "$LISTING"; then test_fail "unlisted optional script was materialised"; else test_pass; fi

test_start "NEGATIVE CONTROL: basename removed from the materialize list is NOT materialised"
eval "$(_extract_fn _xaca0673_mandatory_materialize_basenames | sed 's/^_xaca0673_mandatory_materialize_basenames()/_real_list_body()/')"
_xaca0673_mandatory_materialize_basenames() { _real_list_body | grep -vx 'kb-where-refresh.sh'; }
W2="$SANDBOX/working2"
_new_working "$W2"
_run_helpers "$W2"
L2="$(ls -1 "$W2/scripts")"
_neg_ok=true
_has_line "kb-where-refresh.sh" "$L2" && { _neg_ok=false; echo "     kb-where-refresh.sh materialised despite not being listed" >&2; }
_has_line "aitf-root.sh" "$L2" || { _neg_ok=false; echo "     control broken: aitf-root.sh should still be materialised" >&2; }
if [ "$_neg_ok" = true ]; then test_pass; else test_fail "negative control did not behave"; fi
eval "$(_extract_fn _xaca0673_mandatory_materialize_basenames)"   # restore the real list

test_start "Real materialize list contains every basename as an exact line"
_ok=true
_M="$(_xaca0673_mandatory_materialize_basenames)"
while IFS= read -r n; do
    _has_line "$n" "$_M" || { _ok=false; echo "     NOT-LISTED: $n" >&2; }
done <<< "$NAMES"
if [ "$_ok" = true ]; then test_pass; else test_fail "basename missing from _xaca0673_mandatory_materialize_basenames"; fi

test_start "No session-guard basename is aux-owned (would be skipped by the sweep)"
_AUX="$(WORKING_DIR="$W1" _xaca0608_aux_scriptdir_basenames)"
_ok=true
while IFS= read -r n; do
    _has_line "$n" "$_AUX" && { _ok=false; echo "     AUX-OWNED: $n" >&2; }
done <<< "$NAMES"
if [ "$_ok" = true ]; then test_pass; else test_fail "aux-owned basename would be skipped"; fi

test_start "Fresh-install coupling: install-shell.sh loop and validate-install.sh list every basename"
_ok=true
_IHS="$(awk '/^install_helper_scripts\(\) \{/{c=1} c{print} c&&/^}$/{exit}' "$INSTALL_SHELL_SH")"
_VCS="$(awk '/^_val_check_scripts\(\) \{/{c=1} c{print} c&&/^}$/{exit}' "$VALIDATE_SH")"
{ [ -n "$_IHS" ] && [ -n "$_VCS" ]; } || { _ok=false; echo "     could not extract install_helper_scripts/_val_check_scripts" >&2; }
while IFS= read -r n; do
    _re="$(printf '%s' "$n" | sed 's/\./\\./g')"
    printf '%s\n' "$_IHS" | grep -qE "^[[:space:]]+${_re}( \\\\|; do)" || { _ok=false; echo "     install-shell loop missing: $n" >&2; }
    printf '%s\n' "$_VCS" | grep -qE "^[[:space:]]+\"${_re}\"" || { _ok=false; echo "     validate-install list missing: $n" >&2; }
done <<< "$NAMES"
if [ "$_ok" = true ]; then test_pass; else test_fail "fresh-install lists out of step with upgrade list"; fi

test_start "Real shipped copies, run through the REAL update_runtime_helpers, are byte-identical to source"
_ok=true
_seen=0
RW="$SANDBOX/working-real"
_new_working "$RW"
mkdir -p "$SANDBOX/fw-real/share/scripts"
while IFS= read -r n; do
    [ -f "$TAP_ROOT/share/scripts/$n" ] || continue
    _seen=$((_seen + 1))
    cp "$TAP_ROOT/share/scripts/$n" "$SANDBOX/fw-real/share/scripts/$n"
done <<< "$NAMES"
FRAMEWORK_DIR="$SANDBOX/fw-real" WORKING_DIR="$RW" FORCE=false DRY_RUN=false update_runtime_helpers >/dev/null 2>&1
while IFS= read -r n; do
    [ -f "$SANDBOX/fw-real/share/scripts/$n" ] || continue
    cmp -s "$SANDBOX/fw-real/share/scripts/$n" "$RW/scripts/$n" || { _ok=false; echo "     UPGRADE REWROTE: $n" >&2; }
    [ -x "$RW/scripts/$n" ] || { _ok=false; echo "     NOT-EXEC: $n" >&2; }
done <<< "$NAMES"
echo "     (real files present in share/scripts: $_seen of $N_NAMES)"
[ "$_seen" -ge 1 ] || { _ok=false; echo "     vacuous: no real shipped copies found" >&2; }
if [ "$_ok" = true ]; then test_pass; else test_fail "upgrade altered a shipped guard script (placeholder rewrite)"; fi

# ═══════════════════════════════════════════════════════════════════════════
# settings.json hook registrations through the REAL update_claude_settings.
# Expected hooks come from the RENDERED TEMPLATE, never a hardcoded list.
# ═══════════════════════════════════════════════════════════════════════════
SW="$SANDBOX/working-settings"
mkdir -p "$SW/scripts"
export CLAUDE_CONFIG_DIR="$SANDBOX/claude"
export HOME="$SANDBOX/home"
mkdir -p "$CLAUDE_CONFIG_DIR" "$HOME"
unset TMUX GIT_DIR GIT_WORK_TREE
SETTINGS="$CLAUDE_CONFIG_DIR/settings.json"
BOXLOCAL="/opt/box-local/my-own-hook.sh"
cat > "$SETTINGS" <<EOF
{"model":"opus","hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"$BOXLOCAL"}]}]}}
EOF

# Render the template exactly the way the upgrade will (same working dir).
RENDERED="$SANDBOX/rendered.json"
sed "s|{{AITEAMFORGE_DIR}}|$SW|g; s|{{HOME}}|$HOME|g; s|{{CLAUDE_CONFIG_DIR}}|$CLAUDE_CONFIG_DIR|g; s|{{USER}}|tester|g" "$TEMPLATE" > "$RENDERED"
EXPECT_CMDS="$(jq -r '.hooks | to_entries[] | .key as $e | .value[].hooks[]? | select(.command|test("/scripts/(kb-|kanban-crash)")) | "\($e)|\(.command)"' "$RENDERED" 2>/dev/null)"

_run_settings() { # dry_run
    FRAMEWORK_DIR="$TAP_ROOT" WORKING_DIR="$SW" LIBEXEC_DIR="$TAP_ROOT/libexec" \
        FORCE=false DRY_RUN="$1" update_claude_settings >"$SANDBOX/settings-run.out" 2>&1
}
_count() { jq --arg e "$2" --arg c "$3" '[.hooks[$e][]?.hooks[]? | select(.command == $c)] | length' "$1"; }

test_start "Template carries session-guard hooks to verify (non-vacuity)"
if [ "$(printf '%s\n' "$EXPECT_CMDS" | grep -c .)" -ge 8 ]; then test_pass; else test_fail "rendered template yielded <8 guard hooks; test would be vacuous"; fi

test_start "DRY_RUN does not modify settings.json"
_before="$(cksum < "$SETTINGS")"
_run_settings true
if [ "$_before" = "$(cksum < "$SETTINGS")" ]; then test_pass; else test_fail "dry-run modified settings.json"; fi

test_start "Upgrade registers every template hook exactly once and keeps the box-local hook"
_run_settings false
_ok=true
while IFS='|' read -r ev cmd; do
    [ -n "$cmd" ] || continue
    [ "$(_count "$SETTINGS" "$ev" "$cmd")" = "1" ] || { _ok=false; echo "     NOT exactly once: $ev $cmd" >&2; }
done <<< "$EXPECT_CMDS"
[ "$(_count "$SETTINGS" SessionStart "$BOXLOCAL")" = "1" ] || { _ok=false; echo "     box-local hook lost" >&2; }
[ "$(jq -r .model "$SETTINGS")" = "opus" ] || { _ok=false; echo "     user key clobbered" >&2; }
if [ "$_ok" = true ]; then test_pass; else test_fail "hook registration after upgrade incorrect"; fi

test_start "A backup of settings.json was taken before the write"
_bk="$(find "$SW/.backups" -name settings.json -type f 2>/dev/null | head -1)"
if [ -n "$_bk" ] && [ "$(_count "$_bk" SessionStart "$BOXLOCAL")" = "1" ] \
    && [ "$(jq '[.hooks.SessionStart[]?.hooks[]?] | length' "$_bk")" = "1" ]; then
    test_pass
else
    test_fail "no pre-change backup of settings.json found under WORKING_DIR/.backups"
fi

test_start "Second upgrade is idempotent (file byte-identical, nothing added)"
_before="$(cksum < "$SETTINGS")"
_run_settings false
_ok=true
[ "$_before" = "$(cksum < "$SETTINGS")" ] || { _ok=false; echo "     settings.json changed on second run" >&2; }
while IFS='|' read -r ev cmd; do
    [ -n "$cmd" ] || continue
    [ "$(_count "$SETTINGS" "$ev" "$cmd")" = "1" ] || { _ok=false; echo "     duplicated: $ev $cmd" >&2; }
done <<< "$EXPECT_CMDS"
if [ "$_ok" = true ]; then test_pass; else test_fail "second upgrade not idempotent"; fi

# Direct driver for _xaca1753_refresh_settings_hooks (the print_* stubs above
# swallow update_claude_settings' log lines, so stale-line assertions go here).
# $1 = installer file to source (real one, or a mutated copy).
_run_refresh() {
    (
        AITEAMFORGE_DIR="$SW"
        TEMPLATE_DIR="$TAP_ROOT/share/templates"
        export AITEAMFORGE_DIR TEMPLATE_DIR
        # shellcheck source=/dev/null
        source "$1" >/dev/null 2>&1
        if [ -n "${_TEST_BACKUP_DIR:-}" ]; then BACKUP_DIR="$_TEST_BACKUP_DIR"; fi
        set +e +u +o pipefail
        _xaca1753_refresh_settings_hooks "${@:2}"
    ) 2>&1
}
REAL_INSTALLER="$TAP_ROOT/libexec/installers/install-claude-config.sh"
GUARD="$SW/scripts/kb-gh-credential-guard.sh"
DEAD='~/dev-team/claude-hooks/kb-gh-credential-guard.sh'

test_start "(a) A DEAD ~/dev-team registration does not suppress the working path; stale line printed, entry kept"
printf '%s' "{\"hooks\":{\"SessionStart\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"$DEAD\"}]}]}}" > "$SETTINGS"
_out_a="$(_run_refresh "$REAL_INSTALLER")"
_ok=true
[ "$(_count "$SETTINGS" SessionStart "$GUARD")" = "1" ] || { _ok=false; echo "     working path not added" >&2; }
[ "$(_count "$SETTINGS" SessionStart "$DEAD")" = "1" ] || { _ok=false; echo "     dead entry was removed (must be add-only)" >&2; }
case "$_out_a" in *"stale registration $DEAD (script missing)"*) : ;; *) _ok=false; echo "     no stale line; output: $_out_a" >&2 ;; esac
if [ "$_ok" = true ]; then test_pass; else test_fail "dead registration handling incorrect"; fi

test_start "(b) A LIVE dev-path registration (file exists) is not duplicated"
mkdir -p "$HOME/dev-team/claude-hooks"
printf '#!/bin/bash\n' > "$HOME/dev-team/claude-hooks/kb-where-refresh.sh"
LIVE_CMD='$HOME/dev-team/claude-hooks/kb-where-refresh.sh'
printf '%s' "{\"hooks\":{\"SessionStart\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"$LIVE_CMD\"}]}]}}" > "$SETTINGS"
_out_b="$(_run_refresh "$REAL_INSTALLER")"
if [ "$(jq '[.hooks.SessionStart[]?.hooks[]? | select(.command | endswith("/kb-where-refresh.sh"))] | length' "$SETTINGS")" = "1" ] \
    && ! printf '%s' "$_out_b" | grep -q "stale registration"; then
    test_pass
else
    test_fail "live dev-path registration was duplicated or reported stale; output: $_out_b"
fi

test_start "(c) A template NON-guard hook missing from settings is NOT added (scope = shipped scripts/ guards only)"
printf '%s' '{"model":"opus"}' > "$SETTINGS"
_run_refresh "$REAL_INSTALLER" >/dev/null
_ok=true
[ "$(jq '[.hooks.SessionStart[]?.hooks[]? | select(.command | endswith("/kb-where-refresh.sh"))] | length' "$SETTINGS")" = "1" ] || { _ok=false; echo "     guard not added (control)" >&2; }
_nonguard="$(jq '[.. | objects | select(has("command")) | .command | select(test("damage-control|kanban-session-start|kanban-stop|subagent-track|inject-time-context"))] | length' "$SETTINGS")"
[ "$_nonguard" = "0" ] || { _ok=false; echo "     non-guard template hooks were added: $_nonguard" >&2; }
[ "$(jq '.hooks | has("PreToolUse")' "$SETTINGS")" = "false" ] || { _ok=false; echo "     PreToolUse re-added" >&2; }
# every added hook command is under the rendered scripts/ prefix
_outside="$(jq --arg p "$SW/scripts/" '[.hooks[][]?.hooks[]? | .command | select(startswith($p) | not)] | length' "$SETTINGS")"
[ "$_outside" = "0" ] || { _ok=false; echo "     added hook outside $SW/scripts/: $_outside" >&2; }
if [ "$_ok" = true ]; then test_pass; else test_fail "union added hooks outside the shipped guard scope"; fi

test_start "(d) MUTATION: with the script-existence check disabled, (a) fails (dead entry suppresses the add)"
MUT="$SANDBOX/install-claude-config.mutant.sh"
sed 's/|| \[\[ -f "\$r" \]\]; then printf/|| true; then printf/' "$REAL_INSTALLER" > "$MUT"
if cmp -s "$REAL_INSTALLER" "$MUT"; then
    test_fail "mutation did not apply (existence-check line in _xaca1753_presence changed?) -- control is vacuous"
else
    printf '%s' "{\"hooks\":{\"SessionStart\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"$DEAD\"}]}]}}" > "$SETTINGS"
    _run_refresh "$MUT" >/dev/null
    if [ "$(_count "$SETTINGS" SessionStart "$GUARD")" = "0" ]; then
        test_pass
    else
        test_fail "with the existence check disabled the working path was still added: the check is not what protects (a)"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# XACA-1753-019/-020/-021/-022 advisory fixes
# ═══════════════════════════════════════════════════════════════════════════
WRAP="$HOME/wrapped"
mkdir -p "$WRAP"
printf '#!/bin/bash\n' > "$WRAP/kb-gh-credential-guard.sh"
printf '#!/bin/bash\n' > "$WRAP/kb-where-refresh.sh"
printf '#!/usr/bin/env python3\n' > "$WRAP/helper.py"
mkdir -p "$WRAP/with space"
printf '#!/bin/bash\n' > "$WRAP/with space/kb-gh-credential-guard.sh"
GUARD_BASE="kb-gh-credential-guard.sh"
GUARD_EV="$(jq -r '.hooks | to_entries[] | .key as $e | .value[].hooks[]? | select(.command | endswith("/kb-gh-credential-guard.sh")) | $e' "$RENDERED" | head -1)"
WHERE_EVS="$(jq -r '.hooks | to_entries[] | .key as $e | .value[].hooks[]? | select(.command | endswith("/kb-where-refresh.sh")) | $e' "$RENDERED")"
WHERE_E1="$(printf '%s\n' "$WHERE_EVS" | sed -n 1p)"
WHERE_E2="$(printf '%s\n' "$WHERE_EVS" | sed -n 2p)"

_with_cmd_under() { # event command -> writes settings.json with one registration
    jq -n --arg e "$1" --arg c "$2" '{hooks: {($e): [{hooks: [{type: "command", command: $c}]}]}}' > "$SETTINGS"
}
_guard_count() { # registrations of the credential guard (any spelling) under GUARD_EV
    jq --arg e "$GUARD_EV" '[.hooks[$e][]?.hooks[]? | select(.command | contains("kb-gh-credential-guard.sh"))] | length' "$SETTINGS"
}

# ═══════════════════════════════════════════════════════════════════════════
# XACA-1753-023/-025: STRUCTURAL presence (replaces the old script-token grammar
# parser tests (e)/(g): that function no longer exists, so its parser-table unit
# rows have nothing to call. The same spellings are now asserted END TO END as
# "live => the guard is not added again", which is the behaviour that matters.)
# ═══════════════════════════════════════════════════════════════════════════
P="$WRAP/kb-gh-credential-guard.sh"
DP='~/dev-team/claude-hooks/kb-gh-credential-guard.sh'

test_start "(e) Template guards are PLAIN \${AITEAMFORGE_DIR}/scripts/X paths (a wrapped guard would never be added)"
_ok=true
_n_guards="$(jq --arg p "$SW/scripts/" '[.hooks[][]?.hooks[]? | .command | select(startswith($p))] | length' "$RENDERED")"
[ "$_n_guards" -ge 8 ] || { _ok=false; echo "     only $_n_guards guards under the scripts/ prefix (vacuous)" >&2; }
_bad="$(jq -r --arg p "$SW/scripts/" '.hooks[][]?.hooks[]? | .command | select(contains("/scripts/"))
        | select((startswith($p) and (.[($p|length):] | test("^[A-Za-z0-9._-]+$"))) | not)' "$RENDERED")"
[ -z "$_bad" ] || { _ok=false; echo "     non-plain template guard(s): $_bad" >&2; }
printf '%s' '{"model":"opus"}' > "$SETTINGS"
_out_e="$(_run_refresh "$REAL_INSTALLER" --dry-run)"
case "$_out_e" in *"not a plain"*) _ok=false; echo "     installer rejected a template guard: $_out_e" >&2 ;; esac
if [ "$_ok" = true ]; then test_pass; else test_fail "template guards are not plain scripts/ paths"; fi

# Every spelling here MUST count as already registering the guard (live: P is an
# existing file, or the form spells the shipped path itself).
LIVE_FORMS_FILE="$SANDBOX/live-forms.txt"
cat > "$LIVE_FORMS_FILE" <<EOT
$P; echo done
$P>/dev/null
$P 2>&1
cd $WRAP && ./kb-gh-credential-guard.sh
sh -c '$P args'
bash -c "$P"
\$AITEAMFORGE_DIR/scripts/$GUARD_BASE
\${AITEAMFORGE_DIR}/scripts/$GUARD_BASE
[ -f $P ] && $P || true
($P)
$DP || $P
bash "$P"
$P --quiet
$P 2>/dev/null
$P 2>/dev/null || true
$P || true
env FOO=bar $P
bash "\$HOME/wrapped/$GUARD_BASE"
\${HOME}/wrapped/$GUARD_BASE 2>&1
~/wrapped/$GUARD_BASE --x
$P > /dev/null
EOT
_N_LIVE="$(grep -c . "$LIVE_FORMS_FILE")"

test_start "(f) Every live spelling is recognised: the guard is not added a second time"
_ok=true
while IFS= read -r form <&3; do
    [ -n "$form" ] || continue
    _with_cmd_under "$GUARD_EV" "$form"
    _run_refresh "$REAL_INSTALLER" >/dev/null
    c="$(_guard_count)"
    [ "$c" = "1" ] || { _ok=false; echo "     form [$form]: $c registrations (want 1)" >&2; }
done 3< "$LIVE_FORMS_FILE"
[ "$_N_LIVE" -ge 20 ] || { _ok=false; echo "     live table shrank to $_N_LIVE rows" >&2; }
if [ "$_ok" = true ]; then test_pass; else test_fail "a live registration spelling was duplicated"; fi

test_start "(f2) Every DEAD wrapped spelling still gets the shipped path added, is kept, and is reported stale"
_ok=true
DEAD_FORMS_FILE="$SANDBOX/dead-forms.txt"
cat > "$DEAD_FORMS_FILE" <<EOT
$DP; echo done
$DP>/dev/null
$DP 2>&1
cd ~/dev-team/claude-hooks && ./$GUARD_BASE
sh -c '$DP args'
bash -c "$DP"
[ -f $DP ] && $DP || true
($DP)
$DP || true
bash "$DP"
\$HOME/dev-team/claude-hooks/$GUARD_BASE
\${HOME}/dev-team/claude-hooks/$GUARD_BASE --x
EOT
while IFS= read -r form <&3; do
    [ -n "$form" ] || continue
    _with_cmd_under "$GUARD_EV" "$form"
    _out_f2="$(_run_refresh "$REAL_INSTALLER")"
    [ "$(_count "$SETTINGS" "$GUARD_EV" "$GUARD")" = "1" ] || { _ok=false; echo "     form [$form]: shipped path NOT added" >&2; }
    [ "$(_count "$SETTINGS" "$GUARD_EV" "$form")" = "1" ] || { _ok=false; echo "     form [$form]: dead entry not kept" >&2; }
    case "$_out_f2" in *"stale registration $form (script missing)"*) : ;; *) _ok=false; echo "     form [$form]: not reported stale: $_out_f2" >&2 ;; esac
done 3< "$DEAD_FORMS_FILE"
# a bare word that merely mentions the name is not a registration (and not stale)
_with_cmd_under "$GUARD_EV" "echo $GUARD_BASE"
_out_f2="$(_run_refresh "$REAL_INSTALLER")"
[ "$(_count "$SETTINGS" "$GUARD_EV" "$GUARD")" = "1" ] || { _ok=false; echo "     bare-word mention suppressed the add" >&2; }
case "$_out_f2" in *"stale registration"*) _ok=false; echo "     bare-word mention reported stale" >&2 ;; esac
if [ "$_ok" = true ]; then test_pass; else test_fail "dead wrapped registration handling incorrect"; fi

test_start "(g) MUTATION: presence reverted to the OLD token parser makes the live table red"
MUT_TOK="$SANDBOX/install-claude-config.mut-token.sh"
{ cat "$REAL_INSTALLER"; printf '\n# MUTANT: the pre-XACA-1753-023 grammar-style script-word parser\n'; cat <<'EOM'
# Pick the script path out of a hook command, ~ / $HOME / ${HOME} expanded.
# Rules (first match wins, scanning left to right, first simple command only):
#   - words are split on whitespace; a "double"/'single' quoted word (even one
#     containing spaces) is one word and its quotes are stripped
#   - stop at a control operator (|| && ; | &)
#   - skip redirections (2>/dev/null, >file, > file, 2>&1), env assignments
#     (FOO=bar), options (-x, --quiet) and interpreter words (bash sh zsh dash
#     ksh python python3[.x] uv env node exec nohup sudo command time nice
#     stdbuf, with or without a directory)
#   - the script is the first remaining word that contains a '/' and either
#     ends in .sh/.py or names an existing regular file
# Prints nothing and returns 1 when no word qualifies.
_xaca1753_hook_script_token() {
    local cmd="$1" w q base rest skip_next=false i=0 n
    local -a words=()
    read -r -a words <<< "$cmd"
    n=${#words[@]}
    while [[ $i -lt $n ]]; do
        w="${words[$i]}"
        case "$w" in
            \"*|\'*)
                q="${w:0:1}"
                while [[ $((i + 1)) -lt $n ]] && ! { [[ ${#w} -ge 2 ]] && [[ "${w: -1}" == "$q" ]]; }; do
                    i=$((i + 1)); w="$w ${words[$i]}"
                done
                w="${w#?}"; w="${w%"$q"}"
                ;;
        esac
        i=$((i + 1))
        case "$w" in
            '||'|'&&'|';'|'|'|'&') break ;;
        esac
        if [[ "$skip_next" == true ]]; then skip_next=false; continue; fi
        case "$w" in
            *[\<\>]*)
                rest="${w##*[<>]}"
                [[ -n "$rest" ]] || skip_next=true
                continue ;;
            -*) continue ;;
        esac
        if [[ "$w" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then continue; fi
        case "$w" in
            "~"|"~/"*) w="${HOME}${w#\~}" ;;
            "\$HOME"*) w="${HOME}${w#\$HOME}" ;;
            "\${HOME}"*) w="${HOME}${w#\$\{HOME\}}" ;;
        esac
        base="${w##*/}"
        case "$base" in
            bash|sh|zsh|dash|ksh|python|python3|python3.*|uv|env|node|exec|nohup|sudo|command|time|nice|stdbuf) continue ;;
        esac
        case "$w" in */*) ;; *) continue ;; esac
        case "$w" in
            *.sh|*.py) printf '%s' "$w"; return 0 ;;
        esac
        if [[ -f "$w" ]]; then printf '%s' "$w"; return 0; fi
    done
    return 1
}
_xaca1753_presence() {
    local tok
    tok="$(_xaca1753_hook_script_token "$1")" || tok=""
    if [[ -z "$tok" || "${tok##*/}" != "$2" ]]; then printf none; return 1; fi
    if [[ -e "$tok" || "$(_xaca1753_canon_path "$tok")" == "$(_xaca1753_canon_path "$3")" ]]; then printf live; return 0; fi
    printf stale; return 2
}
EOM
} > "$MUT_TOK"
_red=0
while IFS= read -r form <&3; do
    [ -n "$form" ] || continue
    _with_cmd_under "$GUARD_EV" "$form"
    _run_refresh "$MUT_TOK" >/dev/null
    c="$(_guard_count)"
    if [ "$c" -ge 2 ]; then _red=$((_red + 1)); fi
done 3< "$LIVE_FORMS_FILE"
echo "     (old-parser mutant red on $_red of $_N_LIVE live rows)"
if [ "$_red" -ge 8 ]; then test_pass; else test_fail "old-parser mutant was red on only $_red of $_N_LIVE live rows -- control is not discriminating"; fi

test_start "(h) Spelling drift (// in the path) and a symlinked directory are not re-added"
_ok=true
find "$SW/scripts" -name "$GUARD_BASE" -delete 2>/dev/null
_with_cmd_under "$GUARD_EV" "$SW/scripts//$GUARD_BASE"   # script NOT on disk: canonical match only
_run_refresh "$REAL_INSTALLER" >/dev/null
[ "$(_guard_count)" = "1" ] || { _ok=false; echo "     // spelling re-added the guard" >&2; }
printf '#!/bin/bash\n' > "$SW/scripts/$GUARD_BASE"
ln -s "$SW/scripts" "$SANDBOX/scripts-link"
_with_cmd_under "$GUARD_EV" "$SANDBOX/scripts-link/$GUARD_BASE"
_run_refresh "$REAL_INSTALLER" >/dev/null
[ "$(_guard_count)" = "1" ] || { _ok=false; echo "     symlinked dir re-added the guard" >&2; }
find "$SW/scripts" -name "$GUARD_BASE" -delete 2>/dev/null
find "$SANDBOX" -maxdepth 1 -name scripts-link -delete 2>/dev/null
if [ "$_ok" = true ]; then test_pass; else test_fail "path spelling drift re-added a registered guard"; fi

test_start "(i) MUTATION: canonicalisation disabled makes the // case (h) red"
MUT_CANON="$SANDBOX/install-claude-config.mut-canon.sh"
{ cat "$REAL_INSTALLER"; printf '\n_xaca1753_canon_path() { printf "%%s" "$1"; }\n'; } > "$MUT_CANON"
_with_cmd_under "$GUARD_EV" "$SW/scripts//$GUARD_BASE"
_run_refresh "$MUT_CANON" >/dev/null
if [ "$(_guard_count)" -ge 2 ]; then
    test_pass
else
    test_fail "without canonicalisation the // spelling was still deduped -- (h) does not exercise it"
fi

test_start "(j) Per-event: a guard live only under one event still gets its other-event entry; live under both adds nothing"
_ok=true
{ [ -n "$WHERE_E1" ] && [ -n "$WHERE_E2" ]; } || { _ok=false; echo "     template no longer ships kb-where-refresh under two events" >&2; }
SHIPPED_WHERE="$SW/scripts/kb-where-refresh.sh"
_with_cmd_under "$WHERE_E1" "$WRAP/kb-where-refresh.sh"
_run_refresh "$REAL_INSTALLER" >/dev/null
[ "$(_count "$SETTINGS" "$WHERE_E1" "$SHIPPED_WHERE")" = "0" ] || { _ok=false; echo "     added under $WHERE_E1 although live there" >&2; }
[ "$(_count "$SETTINGS" "$WHERE_E2" "$SHIPPED_WHERE")" = "1" ] || { _ok=false; echo "     NOT added under $WHERE_E2 (global-basename suppression)" >&2; }
jq -n --arg a "$WHERE_E1" --arg b "$WHERE_E2" --arg c "$WRAP/kb-where-refresh.sh" \
    '{hooks: {($a): [{hooks: [{type: "command", command: $c}]}], ($b): [{hooks: [{type: "command", command: $c}]}]}}' > "$SETTINGS"
_run_refresh "$REAL_INSTALLER" >/dev/null
if [ "$(_count "$SETTINGS" "$WHERE_E1" "$SHIPPED_WHERE")" != "0" ] || [ "$(_count "$SETTINGS" "$WHERE_E2" "$SHIPPED_WHERE")" != "0" ]; then
    _ok=false; echo "     added although live under both events" >&2
fi
if [ "$_ok" = true ]; then test_pass; else test_fail "liveness is not scoped per event"; fi

test_start "(k) Backup cannot be written: NO write, visible message, rc 1, file byte-identical, no stray temp"
RO="$SANDBOX/ro"
mkdir -p "$RO"
chmod 500 "$RO"
if mkdir "$RO/probe" 2>/dev/null; then
    rmdir "$RO/probe"; chmod 700 "$RO"
    echo "     (skipped: this user can write to a chmod 500 dir, e.g. root)"
    test_pass
else
    printf '%s' '{"model":"opus"}' > "$SETTINGS"
    _before="$(cksum < "$SETTINGS")"
    _out_k="$(_TEST_BACKUP_DIR="$RO/sub" _run_refresh "$REAL_INSTALLER")"; _rc_k=$?
    _ok=true
    [ "$_before" = "$(cksum < "$SETTINGS")" ] || { _ok=false; echo "     settings.json was written despite the failed backup" >&2; }
    case "$_out_k" in *"settings-hooks: skipped (backup failed; existing file untouched)"*) : ;; *) _ok=false; echo "     no visible message; output: $_out_k" >&2 ;; esac
    [ "$_rc_k" = "1" ] || { _ok=false; echo "     rc=$_rc_k (want 1)" >&2; }
    [ -z "$(find "$CLAUDE_CONFIG_DIR" -maxdepth 1 -name 'settings.json.*' 2>/dev/null)" ] || { _ok=false; echo "     temp files left beside target" >&2; }
    chmod 700 "$RO"
    if [ "$_ok" = true ]; then test_pass; else test_fail "failed backup did not fail closed"; fi
fi

test_start "(l) DRY-RUN prints the computed list (count + commands) and leaves everything byte-identical"
printf '%s' '{"model":"opus"}' > "$SETTINGS"
_snap() { cksum < "$SETTINGS"; find "$CLAUDE_CONFIG_DIR" "$SW/.backups" -print 2>/dev/null | sort | cksum; }
_before="$(_snap)"
_out_l="$(_run_refresh "$REAL_INSTALLER" --dry-run)"; _rc_l=$?
_after="$(_snap)"
_ok=true
[ "$_rc_l" = "0" ] || { _ok=false; echo "     dry-run rc=$_rc_l" >&2; }
[ "$_before" = "$_after" ] || { _ok=false; echo "     dry-run changed the file/dir listing" >&2; }
_N="$(printf '%s\n' "$_out_l" | sed -n 's/.*dry-run would add=\([0-9][0-9]*\).*/\1/p' | head -1)"
{ [ -n "$_N" ] && [ "$_N" -ge 8 ]; } || { _ok=false; echo "     no/low computed count: [$_N]" >&2; }
_listed="$(printf '%s\n' "$_out_l" | grep -c 'dry-run would add [A-Za-z]*: ')"
[ "$_listed" = "$_N" ] || { _ok=false; echo "     listed $_listed commands but count is $_N" >&2; }
printf '%s\n' "$_out_l" | grep -qF "dry-run would add ${GUARD_EV}: ${SW}/scripts/kb-gh-credential-guard.sh" || { _ok=false; echo "     guard command not listed" >&2; }
_out_real="$(_run_refresh "$REAL_INSTALLER")"
case "$_out_real" in *"added=${_N}"*) : ;; *) _ok=false; echo "     real run did not add the dry-run count ($_N): $_out_real" >&2 ;; esac
if [ "$_ok" = true ]; then test_pass; else test_fail "dry-run output/side effects wrong"; fi

test_start "(m) update_claude_settings with DRY_RUN=true prints the computed list and writes nothing"
printf '%s' '{"model":"opus"}' > "$SETTINGS"
_before="$(_snap)"
_run_settings true
_after="$(_snap)"
if [ "$_before" = "$_after" ] && grep -q "settings-hooks: dry-run would add=[0-9]" "$SANDBOX/settings-run.out" \
    && grep -q "settings-hooks: dry-run would add .*: .*kb-where-refresh.sh" "$SANDBOX/settings-run.out"; then
    test_pass
else
    test_fail "upgrade dry-run branch still prints a fixed line or wrote something; out: $(cat "$SANDBOX/settings-run.out")"
fi

test_start "(n) Stale line is actionable: names the file to edit and says removal is safe once the shipped path is registered"
_with_cmd_under "$GUARD_EV" "~/dev-team/claude-hooks/$GUARD_BASE"
_out_n="$(_run_refresh "$REAL_INSTALLER")"
case "$_out_n" in
    *"stale registration ~/dev-team/claude-hooks/$GUARD_BASE (script missing)"*"edit ${SETTINGS}"*"removal is safe once the shipped path ${SW}/scripts/$GUARD_BASE is registered"*) test_pass ;;
    *) test_fail "stale line not actionable: $_out_n" ;;
esac


# ═══════════════════════════════════════════════════════════════════════════
# XACA-1753-024/-026: same-second backup collision with XACA-1283's backup_file
# (BACKUP_DIR/settings.json). Both files must survive with distinct content.
# ═══════════════════════════════════════════════════════════════════════════
_collide() { # installer-file -> sets BK, ORIG_MARK; runs one refresh into BK
    BK="$SANDBOX/bk-collide"
    find "$BK" -delete 2>/dev/null
    mkdir -p "$BK"
    printf '%s' 'ORIGINAL-1283-PRE-UPGRADE-BACKUP' > "$BK/settings.json"
    printf '%s' '{"model":"opus","marker":"pre-upgrade-state"}' > "$SETTINGS"
    cp "$SETTINGS" "$SANDBOX/pre-upgrade.json"
    _out_c="$(_TEST_BACKUP_DIR="$BK" _run_refresh "$1")"; _rc_c=$?
}

test_start "(o) Same-second collision: pre-existing BACKUP_DIR/settings.json AND our backup both survive; path printed; verified"
_ok=true
_collide "$REAL_INSTALLER"
[ "$_rc_c" = "2" ] || { _ok=false; echo "     rc=$_rc_c (want 2)" >&2; }
[ "$(cat "$BK/settings.json")" = "ORIGINAL-1283-PRE-UPGRADE-BACKUP" ] || { _ok=false; echo "     pre-existing backup was overwritten" >&2; }
_ours="$(find "$BK" -mindepth 2 -name settings.json -type f 2>/dev/null)"
[ "$(printf '%s\n' "$_ours" | grep -c .)" = "1" ] || { _ok=false; echo "     expected exactly 1 backup of our own, got: $_ours" >&2; }
cmp -s "$_ours" "$SANDBOX/pre-upgrade.json" || { _ok=false; echo "     our backup does not hold the pre-upgrade bytes" >&2; }
case "$_out_c" in *"settings-hooks: backup=$_ours"*) : ;; *) _ok=false; echo "     backup path not printed; output: $_out_c" >&2 ;; esac
# second run in (likely) the same second: restore the pre-upgrade file, run again
cp "$SANDBOX/pre-upgrade.json" "$SETTINGS"
_out_c2="$(_TEST_BACKUP_DIR="$BK" _run_refresh "$REAL_INSTALLER")"
[ "$(find "$BK" -mindepth 2 -name settings.json -type f 2>/dev/null | grep -c .)" = "2" ] || { _ok=false; echo "     second run overwrote/reused the first run's backup" >&2; }
[ "$(cat "$BK/settings.json")" = "ORIGINAL-1283-PRE-UPGRADE-BACKUP" ] || { _ok=false; echo "     pre-existing backup lost on second run" >&2; }
if [ "$_ok" = true ]; then test_pass; else test_fail "backup collision handling incorrect"; fi

test_start "(p) MUTATION: backup writing BACKUP_DIR/settings.json (old behaviour) makes the collision test (o) red"
MUT_BK="$SANDBOX/install-claude-config.mut-backup.sh"
{ cat "$REAL_INSTALLER"; cat <<'EOM'

# MUTANT: the pre-XACA-1753-024 backup (overwrites BACKUP_DIR/settings.json)
_xaca1753_backup_settings() {
    local f="$1" bp
    [[ -n "${BACKUP_DIR:-}" ]] || return 1
    bp="${BACKUP_DIR}/$(basename "$f")"
    mkdir -p "$BACKUP_DIR" 2>/dev/null || return 1
    cp "$f" "$bp" 2>/dev/null || return 1
    cmp -s "$f" "$bp" || return 1
    _XACA1753_BACKUP_PATH="$bp"
}
EOM
} > "$MUT_BK"
_collide "$MUT_BK"
if [ "$(cat "$BK/settings.json")" != "ORIGINAL-1283-PRE-UPGRADE-BACKUP" ]; then
    test_pass
else
    test_fail "with the old overwrite-prone backup the original was still intact -- (o) does not exercise the collision"
fi

if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "Results: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    [ "$_FAIL_COUNT" -gt 0 ] && exit 1
fi
exit 0
