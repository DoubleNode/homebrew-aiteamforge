#!/bin/bash
# shellcheck disable=SC2034  # LIBEXEC_DIR/FRAMEWORK_DIR/WORKING_DIR/DRY_RUN are read by the sourced update_claude_settings
# test-xaca-1283-settings-merge-env-and-scalar.sh
#
# XACA-1283: settings.json keys must reach ALREADY-INSTALLED tap boxes on
# `aiteamforge upgrade`, not only on a fresh `aiteamforge setup`.
#
# Root cause this guards: install_settings_json() (the only thing that ever
# applied settings.json.template) is reached ONLY from `aiteamforge setup`.
# `aiteamforge upgrade` had no function touching ~/.claude/settings.json, so a
# template key never reached a box installed before it was added. Fix:
# update_claude_settings() in aiteamforge-upgrade.sh -> the fill-absent helper
# _xaca1283_refresh_settings_json_keys() in install-claude-config.sh, driven by
# the single-source key list _xaca1283_upgrade_settings_key_paths().
#
# STAGED ROLLOUT. Stage A (this file as shipped) delivers ONLY the top-level
# scalar skipDangerousModePermissionPrompt=true -- NOTE that key SUPPRESSES
# Claude Code's dangerous-mode permission prompt. Stage B adds the nested
# env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE="50" after the P=50 7-day gate. The
# nested-key merge is proven NOW against a FIXTURE template + injected key
# list (F* cases), so Stage B only has to flip XACA1283_STAGE below.
#
# Semantics asserted:
#   UPGRADE (unattended, nightly): listed key ABSENT -> template value added.
#     Key PRESENT with any value (P="70", skip=false) -> USER WINS. Nothing
#     outside the list changes. Idempotent. A symlinked settings.json is never
#     written through. Every run logs one greppable "settings-keys:" line.
#   SETUP (operator re-runs `aiteamforge setup`): merge_settings_json() is
#     template-WINS on scalar collisions (`$base * $ovl`) -- pre-existing
#     behavior, documented here so a change to it is a deliberate decision.
#
# Every functional case runs the REAL code against a sandboxed HOME /
# CLAUDE_CONFIG_DIR under TEST_TMP_DIR. No real $HOME mutation, no network,
# no launchctl, no brew.
#
# Exit 0 = all pass and >=1 assertion ran; 1 = any fail or zero assertions.

# ── STAGE-A GUARD (XACA-1283) ────────────────────────────────────────────────
# Stage B flips this ONE line to B, which flips the G1 guard (template + key
# list must now CARRY env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE="50") and the U1/P1
# expectations. Until then G1 FAILS if P=50 leaks into the shipped tap early.
XACA1283_STAGE=A

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UPGRADE_SH="$TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh"
INSTALLER="$TAP_ROOT/libexec/installers/install-claude-config.sh"
TEMPLATE="$TAP_ROOT/share/templates/claude/settings.json.template"

for _need in "$UPGRADE_SH" "$INSTALLER" "$TEMPLATE"; do
    [ -f "$_need" ] || { echo "FATAL: required file not found: $_need" >&2; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq is required" >&2; exit 1; }

if ! type -t test_start >/dev/null 2>&1; then
    _PASS_COUNT=0
    _FAIL_COUNT=0
    _CURRENT_TEST=""
    test_start() { _CURRENT_TEST="$1"; echo "  >> $1"; }
    test_pass()  { _PASS_COUNT=$((_PASS_COUNT + 1)); echo "     PASS: $_CURRENT_TEST"; }
    test_fail()  { _FAIL_COUNT=$((_FAIL_COUNT + 1)); echo "     FAIL: $_CURRENT_TEST — $1" >&2; }
    _STANDALONE=true
else
    _STANDALONE=false
fi

if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca1283-settings.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
cleanup() {
    if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ] && [ -d "${TEST_TMP_DIR:-}" ]; then
        rm -rf "$TEST_TMP_DIR"
    fi
}
trap cleanup EXIT

_REAL_HOME="$HOME"
P_PATH='["env","CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"]'
SKIP_PATH='["skipDangerousModePermissionPrompt"]'

if [ "$XACA1283_STAGE" = B ]; then
    EXPECT_P='"50"'; EXPECT_ADDED=2
else
    EXPECT_P='null'; EXPECT_ADDED=1
fi

# ── Extract the REAL upgrade-side function (so the test fails if it is
#    rewired, not just if the helper breaks). ─────────────────────────────────
UPD_FN_SRC="$TEST_TMP_DIR/update_claude_settings.extracted.sh"
awk '
  /^update_claude_settings\(\) \{/ { capture=1 }
  capture { print }
  capture && /^}$/ { exit }
' "$UPGRADE_SH" > "$UPD_FN_SRC"

# The SHIPPED key list, read through the real single-source function.
SHIPPED_KEYS="$(
    export HOME="$TEST_TMP_DIR/keys-home" AITEAMFORGE_DIR="$TEST_TMP_DIR/keys-aitf" \
           CLAUDE_CONFIG_DIR="$TEST_TMP_DIR/keys-home/.claude"
    # shellcheck source=/dev/null
    source "$INSTALLER" >/dev/null 2>&1
    _xaca1283_upgrade_settings_key_paths_json
)"

# Run the extracted update_claude_settings (shipped template + shipped key
# list) in a fresh sandbox whose pre-existing settings.json is $2.
# stdout: the sandbox CLAUDE_CONFIG_DIR. Upgrade output: <sandbox>/upgrade.out
run_upgrade_in() {
    local sb="$1"
    (
        export HOME="$sb/home"
        export AITEAMFORGE_DIR="$sb/aiteamforge"
        export CLAUDE_CONFIG_DIR="$sb/home/.claude"
        case "$CLAUDE_CONFIG_DIR" in "$_REAL_HOME"/.claude*) echo "FATAL: sandbox escaped" >&2; exit 99 ;; esac
        LIBEXEC_DIR="$TAP_ROOT/libexec"
        FRAMEWORK_DIR="$TAP_ROOT"
        WORKING_DIR="$sb/aiteamforge"
        DRY_RUN=false
        print_section() { :; }
        print_info() { :; }
        print_success() { echo "OK: $*"; }
        print_warning() { echo "WARN: $*"; }
        # shellcheck source=/dev/null
        source "$UPD_FN_SRC"
        update_claude_settings
    ) >> "$sb/upgrade.out" 2>&1
}
run_upgrade_case() {
    local name="$1" seed="$2"
    local sb="$TEST_TMP_DIR/$name"
    mkdir -p "$sb/home/.claude" "$sb/aiteamforge"
    [ -n "$seed" ] && printf '%s\n' "$seed" > "$sb/home/.claude/settings.json"
    run_upgrade_in "$sb"
    echo "$sb/home/.claude"
}

# FIXTURE run: the REAL _xaca1283_refresh_settings_json_keys, but against a
# fixture template ($3) and an injected key list ($4, one JSON path per line)
# instead of the shipped ones. Proves the nested-key merge independent of what
# the shipped template carries today.
run_fixture_case() {
    local name="$1" seed="$2" fixture_tmpl="$3" fixture_keys="$4"
    local sb="$TEST_TMP_DIR/$name"
    mkdir -p "$sb/home/.claude" "$sb/aiteamforge" "$sb/templates/claude"
    printf '%s\n' "$seed" > "$sb/home/.claude/settings.json"
    printf '%s\n' "$fixture_tmpl" > "$sb/templates/claude/settings.json.template"
    printf '%s\n' "$fixture_keys" > "$sb/keys.list"
    (
        export HOME="$sb/home"
        export AITEAMFORGE_DIR="$sb/aiteamforge"
        export CLAUDE_CONFIG_DIR="$sb/home/.claude"
        export TEMPLATE_DIR="$sb/templates"
        case "$CLAUDE_CONFIG_DIR" in "$_REAL_HOME"/.claude*) echo "FATAL: sandbox escaped" >&2; exit 99 ;; esac
        # shellcheck source=/dev/null
        source "$INSTALLER" >/dev/null 2>&1
        # Inject the fixture key list by overriding the single-source function.
        _xaca1283_upgrade_settings_key_paths() { cat "$sb/keys.list"; }
        _xaca1283_refresh_settings_json_keys
    ) > "$sb/fixture.out" 2>&1
    echo "$sb/home/.claude"
}

# Run the SETUP path (install_settings_json -> merge_settings_json).
run_setup_case() {
    local name="$1" seed="$2"
    local sb="$TEST_TMP_DIR/$name"
    mkdir -p "$sb/home/.claude" "$sb/aiteamforge"
    printf '%s\n' "$seed" > "$sb/home/.claude/settings.json"
    (
        export HOME="$sb/home"
        export AITEAMFORGE_DIR="$sb/aiteamforge"
        export CLAUDE_CONFIG_DIR="$sb/home/.claude"
        export TEMPLATE_DIR="$TAP_ROOT/share/templates"
        case "$CLAUDE_CONFIG_DIR" in "$_REAL_HOME"/.claude*) echo "FATAL: sandbox escaped" >&2; exit 99 ;; esac
        # shellcheck source=/dev/null
        source "$INSTALLER"
        install_settings_json
    ) > "$sb/setup.out" 2>&1
    echo "$sb/home/.claude"
}

jget() { jq -c "$2" "$1" 2>/dev/null; }
tmpl_get() { sed -e 's/{{[A-Z_]*}}/x/g' "$TEMPLATE" | jq -c "$1" 2>/dev/null; }

# Pre-existing file shaped like a real deployed box that predates the keys:
# custom permissions, a custom env var, user-chosen model, a custom hook.
SEED_ABSENT='{"model":"sonnet","permissions":{"allow":["Bash(make:*)"],"deny":["Bash(mkfs:*)"]},"env":{"MY_VAR":"keep"},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo mine"}]}]}}'
SEED_NO_ENV='{"model":"sonnet"}'
SEED_CONFLICT='{"env":{"CLAUDE_AUTOCOMPACT_PCT_OVERRIDE":"70"},"skipDangerousModePermissionPrompt":false}'

# Fixture: a template carrying the nested env key PLUS decoys that are NOT in
# the injected list (must never be added), and the injected two-path list.
FIX_TMPL='{"model":"opus","env":{"CLAUDE_AUTOCOMPACT_PCT_OVERRIDE":"50","DECOY_ENV":"no"},"skipDangerousModePermissionPrompt":true}'
FIX_KEYS="$P_PATH
$SKIP_PATH"

# ═══ Structural ════════════════════════════════════════════════════════════
test_start "S1: update_claude_settings is defined AND invoked (bare call) in the upgrade run sequence"
if [ -s "$UPD_FN_SRC" ] && grep -qE '^update_claude_settings$' "$UPGRADE_SH"; then
    test_pass
else
    test_fail "update_claude_settings must be defined and called as a bare line in aiteamforge-upgrade.sh — a defined-but-uncalled function means no installed box ever receives a new template key (XACA-0771/1159/1283 bug class)"
fi

test_start "S2: update_claude_settings routes through the fill-absent helper, never install_settings_json, and names no keys itself (single-source list)"
if [ -s "$UPD_FN_SRC" ] && ! grep -qE '(^|[^_])install_settings_json\b' "$UPD_FN_SRC" \
    && grep -qE '_xaca1283_refresh_settings_json_keys' "$UPD_FN_SRC" \
    && ! grep -qE 'skipDangerousModePermissionPrompt|CLAUDE_AUTOCOMPACT_PCT_OVERRIDE' "$UPD_FN_SRC"; then
    test_pass
else
    test_fail "upgrade wrapper must call _xaca1283_refresh_settings_json_keys, never install_settings_json, and must not hard-code key names"
fi

test_start "S3: the shipped key list is readable and every listed path is carried by the shipped template (no dead entries)"
_dead="$(sed -e 's/{{[A-Z_]*}}/x/g' "$TEMPLATE" | jq -c --argjson k "${SHIPPED_KEYS:-null}" \
    'if ($k|type) != "array" or ($k|length) == 0 then "UNREADABLE" else . as $t | [ $k[] | select(. as $p | ($t | getpath($p)) == null) ] end' 2>/dev/null)"
if [ "$_dead" = '[]' ]; then
    test_pass
else
    test_fail "shipped key list=${SHIPPED_KEYS:-<empty>} ; paths missing from template: ${_dead:-<jq error>}"
fi

test_start "S4: shipped template carries skipDangerousModePermissionPrompt=true and the key list includes it"
if [ "$(tmpl_get '.skipDangerousModePermissionPrompt')" = 'true' ] \
    && printf '%s' "$SHIPPED_KEYS" | jq -e --argjson p "$SKIP_PATH" 'index([$p]) != null' >/dev/null 2>&1; then
    test_pass
else
    test_fail "template=$(tmpl_get '.skipDangerousModePermissionPrompt') keys=$SHIPPED_KEYS"
fi

# ═══ G1: STAGE-A GUARD — flipped by Stage B ═════════════════════════════════
if [ "$XACA1283_STAGE" = B ]; then
    test_start "G1 (Stage B): shipped template carries env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=\"50\" (string) AND the key list includes it"
    if [ "$(tmpl_get '.env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE')" = '"50"' ] \
        && printf '%s' "$SHIPPED_KEYS" | jq -e --argjson p "$P_PATH" 'index([$p]) != null' >/dev/null 2>&1; then
        test_pass
    else
        test_fail "template P=$(tmpl_get '.env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE') keys=$SHIPPED_KEYS"
    fi
else
    test_start "G1 (STAGE-A GUARD): shipped template does NOT carry env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE and the key list does NOT include it (P=50 must not ship before its 7-day gate)"
    if [ "$(tmpl_get '.env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE')" = 'null' ] \
        && printf '%s' "$SHIPPED_KEYS" | jq -e --argjson p "$P_PATH" 'index([$p]) == null' >/dev/null 2>&1; then
        test_pass
    else
        test_fail "P=50 is present early: template P=$(tmpl_get '.env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE') keys=$SHIPPED_KEYS — Stage B must not land before the gate; if it is time, apply stage-b.patch (flips XACA1283_STAGE)"
    fi
fi

# ═══ U1: real upgrade, shipped template, pre-existing file lacking keys ════
CD="$(run_upgrade_case u1 "$SEED_ABSENT")"
test_start "U1a: upgrade adds top-level scalar skipDangerousModePermissionPrompt=true to a pre-existing settings.json that lacks it"
if [ "$(jget "$CD/settings.json" '.skipDangerousModePermissionPrompt')" = 'true' ]; then
    test_pass
else
    test_fail "got $(jget "$CD/settings.json" '.skipDangerousModePermissionPrompt') ; upgrade output: $(cat "$TEST_TMP_DIR/u1/upgrade.out")"
fi
test_start "U1b: env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE after upgrade is ${EXPECT_P} (stage ${XACA1283_STAGE})"
if [ "$(jget "$CD/settings.json" '.env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE')" = "$EXPECT_P" ]; then
    test_pass
else
    test_fail "got $(jget "$CD/settings.json" '.env')"
fi
test_start "U1c: upgrade preserves unrelated user content (custom env key, permissions arrays, model, hooks) exactly"
_expect="$(printf '%s' "$SEED_ABSENT" | jq -S -c --argjson p "$EXPECT_P" \
    '.skipDangerousModePermissionPrompt=true | if $p != null then .env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=$p else . end')"
_got="$(jq -S -c . "$CD/settings.json" 2>/dev/null)"
if [ -n "$_got" ] && [ "$_got" = "$_expect" ]; then
    test_pass
else
    test_fail "expected $_expect ; got $_got"
fi
test_start "U1d: upgrade logs a greppable 'settings-keys: added=${EXPECT_ADDED}' line"
if grep -q "settings-keys: added=${EXPECT_ADDED} keys=" "$TEST_TMP_DIR/u1/upgrade.out"; then
    test_pass
else
    test_fail "upgrade output: $(cat "$TEST_TMP_DIR/u1/upgrade.out")"
fi

# ═══ U3: conflict — user's differing value WINS on upgrade ═════════════════
CD="$(run_upgrade_case u3 "$SEED_CONFLICT")"
test_start "U3: upgrade leaves a user-set skipDangerousModePermissionPrompt=false (and env P=\"70\") alone"
if [ "$(jget "$CD/settings.json" '[.skipDangerousModePermissionPrompt,.env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE]')" = '[false,"70"]' ]; then
    test_pass
else
    test_fail "got $(jget "$CD/settings.json" '.')"
fi

# ═══ U4: idempotent — a second run changes nothing and logs a no-op ════════
CD="$(run_upgrade_case u4 "$SEED_ABSENT")"
cp "$CD/settings.json" "$TEST_TMP_DIR/u4.first"
: > "$TEST_TMP_DIR/u4/upgrade.out"
run_upgrade_in "$TEST_TMP_DIR/u4"
test_start "U4: second upgrade run is a byte-for-byte no-op and logs 'settings-keys: added=0'"
if cmp -s "$TEST_TMP_DIR/u4.first" "$CD/settings.json" && grep -q "settings-keys: added=0" "$TEST_TMP_DIR/u4/upgrade.out"; then
    test_pass
else
    test_fail "file changed or wrong log: $(cat "$TEST_TMP_DIR/u4/upgrade.out")"
fi

# ═══ U5: symlinked settings.json is never written through ═════════════════
sb="$TEST_TMP_DIR/u5"; mkdir -p "$sb/home/.claude" "$sb/dotfiles" "$sb/aiteamforge"
printf '%s\n' "$SEED_NO_ENV" > "$sb/dotfiles/settings.json"
ln -s "$sb/dotfiles/settings.json" "$sb/home/.claude/settings.json"
run_upgrade_in "$sb"
test_start "U5: a symlinked settings.json (dotfiles) is left untouched — link and destination — and logs 'settings-keys: untouched'"
if [ -L "$sb/home/.claude/settings.json" ] && [ "$(jq -c . "$sb/dotfiles/settings.json")" = "$SEED_NO_ENV" ] \
    && grep -q "settings-keys: untouched" "$sb/upgrade.out"; then
    test_pass
else
    test_fail "symlink or its destination was modified: $(cat "$sb/upgrade.out")"
fi

# ═══ F*: nested env-key merge, FIXTURE template + INJECTED key list ════════
CD="$(run_fixture_case f1 "$SEED_ABSENT" "$FIX_TMPL" "$FIX_KEYS")"
test_start "F1: nested env key is added into an EXISTING env object, keeping the user's other env key; decoys outside the list are not added"
_got="$(jq -S -c . "$CD/settings.json" 2>/dev/null)"
_expect="$(printf '%s' "$SEED_ABSENT" | jq -S -c '.env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE="50" | .skipDangerousModePermissionPrompt=true')"
if [ -n "$_got" ] && [ "$_got" = "$_expect" ] && grep -q "settings-keys: added=2 keys=" "$TEST_TMP_DIR/f1/fixture.out"; then
    test_pass
else
    test_fail "expected $_expect ; got $_got ; log: $(cat "$TEST_TMP_DIR/f1/fixture.out")"
fi
CD="$(run_fixture_case f2 "$SEED_NO_ENV" "$FIX_TMPL" "$FIX_KEYS")"
test_start "F2: nested env key creates the env object when the file has none (user model kept, template model not applied)"
if [ "$(jq -S -c . "$CD/settings.json" 2>/dev/null)" = '{"env":{"CLAUDE_AUTOCOMPACT_PCT_OVERRIDE":"50"},"model":"sonnet","skipDangerousModePermissionPrompt":true}' ]; then
    test_pass
else
    test_fail "got $(jq -S -c . "$CD/settings.json" 2>/dev/null)"
fi
CD="$(run_fixture_case f3 "$SEED_CONFLICT" "$FIX_TMPL" "$FIX_KEYS")"
test_start "F3: user's env P=\"70\" and skip=false WIN over the fixture template; logs added=0"
if [ "$(jq -S -c . "$CD/settings.json" 2>/dev/null)" = "$(printf '%s' "$SEED_CONFLICT" | jq -S -c .)" ] \
    && grep -q "settings-keys: added=0" "$TEST_TMP_DIR/f3/fixture.out"; then
    test_pass
else
    test_fail "got $(jq -S -c . "$CD/settings.json" 2>/dev/null) ; log: $(cat "$TEST_TMP_DIR/f3/fixture.out")"
fi

# F4 is the case F3 cannot reach: when EVERY listed key is present the helper
# short-circuits to added=0 before merging, so a template-wins merge would go
# unnoticed. Mixed file (one key user-set, one absent) forces the merge to run.
CD="$(run_fixture_case f4 '{"skipDangerousModePermissionPrompt":false}' "$FIX_TMPL" "$FIX_KEYS")"
test_start "F4: MIXED file — absent nested key is added while the user's skip=false in the SAME run is kept; logs added=1"
if [ "$(jq -S -c . "$CD/settings.json" 2>/dev/null)" = '{"env":{"CLAUDE_AUTOCOMPACT_PCT_OVERRIDE":"50"},"skipDangerousModePermissionPrompt":false}' ] \
    && grep -q "settings-keys: added=1 keys=env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE$" "$TEST_TMP_DIR/f4/fixture.out"; then
    test_pass
else
    test_fail "got $(jq -S -c . "$CD/settings.json" 2>/dev/null) ; log: $(cat "$TEST_TMP_DIR/f4/fixture.out")"
fi

# ═══ M*: XACA-1283-021 — settings.json file MODE must be preserved ════════
# _aitf_file_mode (defined in aiteamforge-upgrade.sh) is NOT visible to
# _xaca1283_refresh_settings_json_keys in either real call shape exercised by
# this suite: the "real upgrade path" below sources only the EXTRACTED
# update_claude_settings function body (never the sibling _aitf_file_mode
# definition elsewhere in aiteamforge-upgrade.sh -- see UPD_FN_SRC above),
# and the fixture/"installer sourced alone" path sources
# install-claude-config.sh by itself. Both must fall back to a SELF-CONTAINED
# mode lookup, not silently widen 0600 -> 0644 (reviewer-verified regression,
# PR #934).
sb="$TEST_TMP_DIR/m1"; mkdir -p "$sb/home/.claude" "$sb/aiteamforge"
printf '%s\n' "$SEED_ABSENT" > "$sb/home/.claude/settings.json"
chmod 0600 "$sb/home/.claude/settings.json"
run_upgrade_in "$sb"
test_start "M1 (real upgrade path): a 0600 settings.json stays 0600 after an add"
_got_mode="$(stat -f '%Lp' "$sb/home/.claude/settings.json" 2>/dev/null || stat -c '%a' "$sb/home/.claude/settings.json" 2>/dev/null)"
if [ "$(jget "$sb/home/.claude/settings.json" '.skipDangerousModePermissionPrompt')" = 'true' ] && [ "$_got_mode" = "600" ]; then
    test_pass
else
    test_fail "mode=$_got_mode (expected 600) ; key added=$(jget "$sb/home/.claude/settings.json" '.skipDangerousModePermissionPrompt') ; log: $(cat "$sb/upgrade.out")"
fi

sb="$TEST_TMP_DIR/m2"; mkdir -p "$sb/home/.claude" "$sb/aiteamforge" "$sb/templates/claude"
printf '%s\n' "$SEED_ABSENT" > "$sb/home/.claude/settings.json"
chmod 0600 "$sb/home/.claude/settings.json"
printf '%s\n' "$FIX_TMPL" > "$sb/templates/claude/settings.json.template"
printf '%s\n' "$FIX_KEYS" > "$sb/keys.list"
(
    export HOME="$sb/home"
    export AITEAMFORGE_DIR="$sb/aiteamforge"
    export CLAUDE_CONFIG_DIR="$sb/home/.claude"
    export TEMPLATE_DIR="$sb/templates"
    case "$CLAUDE_CONFIG_DIR" in "$_REAL_HOME"/.claude*) echo "FATAL: sandbox escaped" >&2; exit 99 ;; esac
    # shellcheck source=/dev/null
    source "$INSTALLER" >/dev/null 2>&1
    if command -v _aitf_file_mode >/dev/null 2>&1; then
        echo "FATAL: _aitf_file_mode unexpectedly in scope -- this case no longer proves the standalone path" >&2
        exit 98
    fi
    _xaca1283_upgrade_settings_key_paths() { cat "$sb/keys.list"; }
    _xaca1283_refresh_settings_json_keys
) > "$sb/fixture.out" 2>&1
test_start "M2 (installer sourced alone, _aitf_file_mode confirmed out of scope): a 0600 settings.json stays 0600 after an add"
_got_mode="$(stat -f '%Lp' "$sb/home/.claude/settings.json" 2>/dev/null || stat -c '%a' "$sb/home/.claude/settings.json" 2>/dev/null)"
if [ "$(jq -c '.skipDangerousModePermissionPrompt' "$sb/home/.claude/settings.json" 2>/dev/null)" = 'true' ] && [ "$_got_mode" = "600" ] && ! grep -q "FATAL" "$sb/fixture.out"; then
    test_pass
else
    test_fail "mode=$_got_mode (expected 600) ; log: $(cat "$sb/fixture.out")"
fi

# ═══ N*: XACA-1283-022 — an explicit JSON null is a USER VALUE, not absent ═
# getpath($base;$p) == null is true BOTH for a missing key AND for an
# explicit `null` value at that path, so the old absence check overwrote a
# deliberate `"skipDangerousModePermissionPrompt": null` with the template's
# value -- contradicting the "ANY value wins" comment on
# merge_settings_json_fill_absent (reviewer finding, PR #934).
SEED_NULL_TOP='{"skipDangerousModePermissionPrompt":null}'
CD="$(run_fixture_case n1 "$SEED_NULL_TOP" "$FIX_TMPL" "$FIX_KEYS")"
test_start "N1: explicit top-level null is preserved (not overwritten by the template), while the still-absent nested env key IS added"
if [ "$(jq -S -c . "$CD/settings.json" 2>/dev/null)" = '{"env":{"CLAUDE_AUTOCOMPACT_PCT_OVERRIDE":"50"},"skipDangerousModePermissionPrompt":null}' ] \
    && grep -q "settings-keys: added=1 keys=env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE$" "$TEST_TMP_DIR/n1/fixture.out"; then
    test_pass
else
    test_fail "got $(jq -S -c . "$CD/settings.json" 2>/dev/null) ; log: $(cat "$TEST_TMP_DIR/n1/fixture.out")"
fi

SEED_NULL_NESTED='{"env":{"CLAUDE_AUTOCOMPACT_PCT_OVERRIDE":null},"skipDangerousModePermissionPrompt":false}'
CD="$(run_fixture_case n2 "$SEED_NULL_NESTED" "$FIX_TMPL" "$FIX_KEYS")"
test_start "N2: explicit NESTED env null is preserved (not overwritten), and the present skip=false is also left alone; logs added=0"
if [ "$(jq -S -c . "$CD/settings.json" 2>/dev/null)" = "$(printf '%s' "$SEED_NULL_NESTED" | jq -S -c .)" ] \
    && grep -q "settings-keys: added=0" "$TEST_TMP_DIR/n2/fixture.out"; then
    test_pass
else
    test_fail "got $(jq -S -c . "$CD/settings.json" 2>/dev/null) ; log: $(cat "$TEST_TMP_DIR/n2/fixture.out")"
fi

# ═══ P*: SETUP path semantics (pre-existing merge_settings_json) ═══════════
CD="$(run_setup_case p1 "$SEED_ABSENT")"
test_start "P1: setup merge adds skip=true, sets env P to ${EXPECT_P}, keeps the user's other env key"
if [ "$(jget "$CD/settings.json" '[.skipDangerousModePermissionPrompt,.env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE,.env.MY_VAR]')" = "[true,${EXPECT_P},\"keep\"]" ]; then
    test_pass
else
    test_fail "got $(jget "$CD/settings.json" '[.skipDangerousModePermissionPrompt,.env]') ; $(tail -5 "$TEST_TMP_DIR/p1/setup.out")"
fi
CD="$(run_setup_case p2 "$SEED_CONFLICT")"
test_start "P2: setup merge is TEMPLATE-WINS on a conflicting scalar (documents pre-existing behavior: skip false->true)"
if [ "$(jget "$CD/settings.json" '.skipDangerousModePermissionPrompt')" = 'true' ]; then
    test_pass
else
    test_fail "got $(jget "$CD/settings.json" '.skipDangerousModePermissionPrompt')"
fi

test_start "Z1: no case resolved CLAUDE_CONFIG_DIR to the real \$HOME/.claude"
if ! grep -rq "sandbox escaped" "$TEST_TMP_DIR" 2>/dev/null; then
    test_pass
else
    test_fail "a case tried to run against the real \$HOME"
fi

if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "Passed: $_PASS_COUNT  Failed: $_FAIL_COUNT"
    if [ "$_FAIL_COUNT" -gt 0 ] || [ "$_PASS_COUNT" -eq 0 ]; then
        exit 1
    fi
    exit 0
fi
