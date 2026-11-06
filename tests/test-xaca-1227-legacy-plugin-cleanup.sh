#!/bin/bash
# test-xaca-1227-legacy-plugin-cleanup.sh  (XACA-1227-005)
#
# The pre-fix settings.json.template force-enabled five enabledPlugins keys that
# cannot resolve on a generic consumer (4 x @claude-plugins-official, plus
# kanban-integration@local, which is an MCP server, not a plugin). XACA-1227
# drops them from the template and ships a one-time, receipt-guarded cleanup,
# _xaca1227_remove_legacy_template_plugins (install-claude-config.sh), wired into
# install_settings_json (before the merge) and update_claude_settings
# (aiteamforge-upgrade.sh). It also guards install_settings_json's mv so a merge
# failure can no longer truncate the user's settings.json.
#
#   C1  fresh install (no target) from the canonical template -> no legacy key
#   C2  upgrade path: the REAL update_claude_settings (extracted) removes all 5;
#       install_settings_json with an existing target also removes them
#   C3  survivors: user plugin, false / "true" / 1 / object legacy values,
#       emptied enabledPlugins stays {}, other top-level keys identical
#   C4  NEGATIVE CONTROL: the same upgrade assertion against the PRISTINE
#       (pre-fix) tap code leaves the legacy keys in place -> the test
#       discriminates. Reported as "CONTROL" lines, never silently skipped.
#   C5  receipt: second run is a no-op even after a legacy key is re-added;
#       a receipt for another target does not count
#   C6  order guard: template still carrying legacy keys -> skip, no receipt
#   C7  dry-run (helper and upgrade DRY_RUN branch): no write/receipt/backup
#   C8  backup byte-identical to the original; file mode preserved
#   C9  invalid JSON / missing / symlink / non-object enabledPlugins: untouched
#   C11 TABLE-DRIVEN ADVERSARIAL ROWS R1-R11 (PR #1287 blocking findings 018/019):
#       receipt identity/provenance; each row seeds state, lets the user
#       deliberately re-enable a legacy id, re-runs, and asserts it SURVIVES.
#       Controls run R1-R5 against tap 56b6a55a and assert they FAIL there.
#   C10 merge-failure guard: an invalid-JSON target through install_settings_json
#       (inside `if`) is not truncated; control: pristine code truncates it
#
# Mutation seams (used by the XACA-1227-005 mutation sentinels; unset in CI):
#   XACA1227_INSTALLER=<path>  run against a mutated copy of install-claude-config.sh
#   XACA1227_UPGRADE=<path>    run against a mutated copy of aiteamforge-upgrade.sh
#
# Sandboxed: HOME, AITEAMFORGE_DIR, CLAUDE_CONFIG_DIR, TEMPLATE_DIR, TMPDIR all
# live under TEST_TMP_DIR. Never touches real $HOME or ~/.claude.
# Bash 3.2 compatible (no associative arrays, no ${x,,}).

# shellcheck disable=SC2034  # variables are read by sourced/extracted functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALLER="${XACA1227_INSTALLER:-$TAP_ROOT/libexec/installers/install-claude-config.sh}"
UPGRADE_SH="${XACA1227_UPGRADE:-$TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh}"
CANON_TEMPLATE="$TAP_ROOT/../scripts/templates/tap/settings.json.template"

# Hostile-environment hygiene: never let an exported git/tmux context leak in.
unset GIT_DIR GIT_WORK_TREE TMUX
export GIT_CONFIG_GLOBAL=/dev/null

for _need in "$INSTALLER" "$UPGRADE_SH"; do
    [ -f "$_need" ] || { echo "FATAL: required file not found: $_need" >&2; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 1; }

if ! type -t test_start >/dev/null 2>&1; then
    _PASS_COUNT=0
    _FAIL_COUNT=0
    _SKIP_COUNT=0
    _CURRENT_TEST=""
    test_start() { _CURRENT_TEST="$1"; echo "  >> $1"; }
    test_pass()  { _PASS_COUNT=$((_PASS_COUNT + 1)); echo "     PASS: $_CURRENT_TEST"; }
    test_fail()  { _FAIL_COUNT=$((_FAIL_COUNT + 1)); echo "     FAIL: $_CURRENT_TEST - $1" >&2; }
fi
: "${_SKIP_COUNT:=0}"
test_skip_loud() { _SKIP_COUNT=$((_SKIP_COUNT + 1)); echo "     SKIPPED (LOUD): $_CURRENT_TEST - $1"; }

if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca1227-legacy.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
cleanup() {
    if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ] && [ -d "${TEST_TMP_DIR:-}" ]; then
        find "$TEST_TMP_DIR" -depth -delete 2>/dev/null || true
    fi
}
trap cleanup EXIT

_REAL_HOME="${HOME:-}"
export TMPDIR="$TEST_TMP_DIR/tmp"
mkdir -p "$TMPDIR"
export USER="${USER:-xaca1227}"

LEGACY_IDS='["frontend-design@claude-plugins-official","atlassian@claude-plugins-official","firebase@claude-plugins-official","swift-lsp@claude-plugins-official","kanban-integration@local"]'

# ---- fixtures ---------------------------------------------------------------
# Canonical (post-fix) template: the fixture for every "template is fixed" case.
GOOD_TMPL_DIR="$TEST_TMP_DIR/tmpl-good"
mkdir -p "$GOOD_TMPL_DIR/claude"
# Prefer the dev-team canonical template (scripts/templates/tap/, present when
# the tap is a submodule of dev-team). A standalone tap checkout has no outer
# tree, so derive the same shape from the tap's own share/ copy by dropping
# enabledPlugins (the only difference XACA-1227 makes).
if [ -f "$CANON_TEMPLATE" ]; then
    cp "$CANON_TEMPLATE" "$GOOD_TMPL_DIR/claude/settings.json.template"
elif [ -f "$TAP_ROOT/share/templates/claude/settings.json.template" ]; then
    jq 'del(.enabledPlugins)' "$TAP_ROOT/share/templates/claude/settings.json.template" \
        > "$GOOD_TMPL_DIR/claude/settings.json.template" || { echo "FATAL: cannot derive template" >&2; exit 1; }
else
    echo "FATAL: no settings.json.template fixture source found" >&2
    exit 1
fi
CANON_TEMPLATE="$GOOD_TMPL_DIR/claude/settings.json.template"
# Legacy-bearing template (the pre-fix shape), derived from the canonical one so
# it is independent of the tap's own share/ copy. Placeholders live in string
# values only, so jq round-trips the template safely.
BAD_TMPL_DIR="$TEST_TMP_DIR/tmpl-bad"
mkdir -p "$BAD_TMPL_DIR/claude"
jq --argjson ids "$LEGACY_IDS" '.enabledPlugins = (reduce $ids[] as $k ({}; .[$k] = true))' \
    "$CANON_TEMPLATE" > "$BAD_TMPL_DIR/claude/settings.json.template"

# Code under test, copied to a private libexec so LIBEXEC_DIR can point at it
# (and mutation seams / pristine controls substitute cleanly).
UT_LIBEXEC="$TEST_TMP_DIR/ut-libexec"
mkdir -p "$UT_LIBEXEC/installers"
cp "$INSTALLER" "$UT_LIBEXEC/installers/install-claude-config.sh"

_extract_fn() {
    awk -v fn="$2" '
      $0 ~ ("^" fn "\\(\\) \\{") { capture=1 }
      capture { print }
      capture && /^}$/ { exit }
    ' "$1"
}
UPD_FN_SRC="$TEST_TMP_DIR/update_claude_settings.extracted.sh"
_extract_fn "$UPGRADE_SH" update_claude_settings > "$UPD_FN_SRC"

SEED_ALL='{
  "model": "opus",
  "cleanupPeriodDays": 30,
  "permissions": {"deny": ["Bash(x:*)"], "allow": ["Bash(user-added:*)"]},
  "enabledPlugins": {
    "frontend-design@claude-plugins-official": true,
    "atlassian@claude-plugins-official": true,
    "firebase@claude-plugins-official": true,
    "swift-lsp@claude-plugins-official": true,
    "kanban-integration@local": true
  }
}'

_sb_n=0
# new_sandbox <seed-json-or-empty> -> sets SB
new_sandbox() {
    _sb_n=$((_sb_n + 1))
    SB="$TEST_TMP_DIR/sb$_sb_n"
    mkdir -p "$SB/home/.claude" "$SB/aiteamforge" "$SB/fw/share/templates/claude"
    cp "$GOOD_TMPL_DIR/claude/settings.json.template" "$SB/fw/share/templates/claude/settings.json.template"
    [ -n "${1:-}" ] && printf '%s\n' "$1" > "$SB/home/.claude/settings.json"
    return 0
}
settings() { printf '%s' "$SB/home/.claude/settings.json"; }
receipt()  { printf '%s' "$SB/aiteamforge/.xaca1227-legacy-plugins.receipt"; }
canon_path() { printf '%s/%s' "$(cd "$(dirname "$1")" && pwd -P)" "$(basename "$1")"; }
cksum_of() { cksum < "$1" 2>/dev/null; }
mode_of()  { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null; }
count_backups() { find "$SB/aiteamforge/.backups" -type d -name 'xaca1227-legacy-plugins-*' 2>/dev/null | wc -l | tr -d '[:space:]'; }
legacy_true_count() {   # number of the 5 ids still == true in $1
    jq -r --argjson ids "$LEGACY_IDS" '(.enabledPlugins // {}) as $e | [$ids[] | select($e[.] == true)] | length' "$1"
}
legacy_present_count() {  # number of the 5 ids present at all
    jq -r --argjson ids "$LEGACY_IDS" '(.enabledPlugins // {}) as $e | [$ids[] | . as $k | select($e | has($k))] | length' "$1"
}

# run_helper <sb-set-by-new_sandbox> <tmpl-dir> [args]: output -> $OUT, rc -> $RC
run_helper() {
    local tmpl="$1"; shift
    OUT="$(
        export HOME="$SB/home" AITEAMFORGE_DIR="$SB/aiteamforge" \
               CLAUDE_CONFIG_DIR="$SB/home/.claude" TEMPLATE_DIR="$tmpl"
        # shellcheck source=/dev/null
        source "$UT_LIBEXEC/installers/install-claude-config.sh" >/dev/null 2>&1
        set +e
        _xaca1227_remove_legacy_template_plugins "$@"
        echo "::rc=$?"
    )"
    RC="${OUT##*::rc=}"
    OUT="${OUT%::rc=*}"
}

# run_upgrade [libexec-dir] [fn-src] [dry]: the REAL extracted update_claude_settings
run_upgrade() {
    local libexec="${1:-$UT_LIBEXEC}" fn_src="${2:-$UPD_FN_SRC}" dry="${3:-false}"
    # (bash 3.2 cannot parse a case/esac with ")" arms inside $( ), so guard out here)
    if [ "$SB/home/.claude" = "$_REAL_HOME/.claude" ]; then echo "FATAL: sandbox escaped" >&2; exit 99; fi
    UOUT="$(
        export HOME="$SB/home" AITEAMFORGE_DIR="$SB/aiteamforge" \
               CLAUDE_CONFIG_DIR="$SB/home/.claude"
        LIBEXEC_DIR="$libexec"
        FRAMEWORK_DIR="$SB/fw"
        WORKING_DIR="$SB/aiteamforge"
        DRY_RUN="$dry"
        print_section() { :; }
        print_info() { :; }
        print_success() { echo "OK: $*"; }
        print_warning() { echo "WARN: $*"; }
        # shellcheck source=/dev/null
        source "$fn_src"
        update_claude_settings
    ) 2>&1)"
}

# run_install [libexec-dir] : install_settings_json inside `if` (errexit-off context)
run_install() {
    local libexec="${1:-$UT_LIBEXEC}" tmpl="${2:-$GOOD_TMPL_DIR}"
    IOUT="$(
        export HOME="$SB/home" AITEAMFORGE_DIR="$SB/aiteamforge" \
               CLAUDE_CONFIG_DIR="$SB/home/.claude" TEMPLATE_DIR="$tmpl"
        # shellcheck source=/dev/null
        source "$libexec/installers/install-claude-config.sh" >/dev/null 2>&1
        if install_settings_json; then echo "::install-rc=0"; else echo "::install-rc=1"; fi
    ) 2>&1)"
}

# ===========================================================================
# C1 - fresh install: no legacy key
# ===========================================================================
test_start "C1: fresh install (no existing settings.json) from the canonical template has no legacy plugin key"
new_sandbox ""
run_install
S="$(settings)"
if [ ! -f "$S" ] || ! jq -e 'type == "object"' "$S" >/dev/null 2>&1; then
    test_fail "no valid settings.json produced: $IOUT"
elif [ "$(legacy_present_count "$S")" != "0" ]; then
    test_fail "fresh install contains legacy keys: $(jq -c '.enabledPlugins' "$S")"
elif ! jq -e '.hooks.SessionStart | length > 0' "$S" >/dev/null 2>&1; then
    test_fail "fresh install lost the template hooks (vacuous green guard)"
else
    test_pass
fi

# ===========================================================================
# C2 - upgrade path removes all 5 (real update_claude_settings), and the
#      install_settings_json (setup) path with an existing target does too
# ===========================================================================
test_start "C2a: upgrade (real update_claude_settings) removes all 5 legacy keys from an existing settings.json"
new_sandbox "$SEED_ALL"
[ "$(legacy_true_count "$(settings)")" = "5" ] || echo "     (precondition: seed has 5 legacy keys - FAILED)" >&2
run_upgrade
S="$(settings)"
if [ "$(legacy_present_count "$S")" != "0" ]; then
    test_fail "legacy keys remain after upgrade: $(jq -c '.enabledPlugins' "$S"); out: $UOUT"
elif [ ! -f "$(receipt)" ]; then
    test_fail "no receipt written; out: $UOUT"
elif [[ "$UOUT" != *"legacy-plugins: removed=5"* ]]; then
    test_fail "missing 'legacy-plugins: removed=5' report line; out: $UOUT"
else
    test_pass
fi

test_start "C2b: install_settings_json (setup path) with an existing target removes the 5 legacy keys (cleanup runs BEFORE the template-wins merge)"
new_sandbox "$SEED_ALL"
run_install
S="$(settings)"
if [ "$(legacy_present_count "$S")" != "0" ]; then
    test_fail "legacy keys remain after setup merge: $(jq -c '.enabledPlugins' "$S")"
elif ! jq -e '.permissions.allow | index("Bash(user-added:*)")' "$S" >/dev/null 2>&1; then
    test_fail "merge lost the user's own permissions.allow entry (merge broken)"
elif [ ! -f "$(receipt)" ]; then
    test_fail "no receipt after setup-path cleanup"
else
    test_pass
fi

# ===========================================================================
# C3 - survivors
# ===========================================================================
test_start "C3a: a user-added plugin key survives; legacy keys go; other top-level keys are unchanged"
SEED_USER="$(jq '.enabledPlugins["my-plugin@my-market"] = true | .enabledPlugins["kotlin-lsp@claude-plugins-official"] = false' <<<"$SEED_ALL")"
new_sandbox "$SEED_USER"
BEFORE_REST="$(jq -S -c 'del(.enabledPlugins)' "$(settings)")"
run_helper "$GOOD_TMPL_DIR"
S="$(settings)"
AFTER_REST="$(jq -S -c 'del(.enabledPlugins)' "$S")"
if [ "$RC" != "2" ]; then
    test_fail "rc=$RC (want 2); out: $OUT"
elif [ "$(jq -r '.enabledPlugins["my-plugin@my-market"]' "$S")" != "true" ] \
  || [ "$(jq -r '.enabledPlugins["kotlin-lsp@claude-plugins-official"]' "$S")" != "false" ]; then
    test_fail "user plugin keys did not survive: $(jq -c .enabledPlugins "$S")"
elif [ "$(legacy_present_count "$S")" != "0" ]; then
    test_fail "legacy keys remain"
elif [ "$BEFORE_REST" != "$AFTER_REST" ]; then
    test_fail "other top-level keys changed"
elif [[ "$OUT" != *"kept=2"* ]] || [[ "$OUT" == *"kept-user="* ]]; then
    test_fail "report should say kept=2 (field renamed from kept-user): $OUT"
else
    test_pass
fi

test_start "C3b: legacy keys valued false / \"true\" / 1 / object / null survive (only JSON true is removed)"
SEED_ODD='{"enabledPlugins":{
  "frontend-design@claude-plugins-official": false,
  "atlassian@claude-plugins-official": "true",
  "firebase@claude-plugins-official": 1,
  "swift-lsp@claude-plugins-official": {"enabled": true},
  "kanban-integration@local": null,
  "firebase-extra@x": true}}'
new_sandbox "$SEED_ODD"
BEFORE="$(jq -S -c . "$(settings)")"
run_helper "$GOOD_TMPL_DIR"
AFTER="$(jq -S -c . "$(settings)")"
if [ "$RC" != "0" ]; then
    test_fail "rc=$RC (want 0 = nothing to remove); out: $OUT"
elif [ "$BEFORE" != "$AFTER" ]; then
    test_fail "file changed though no legacy key was JSON true: $AFTER"
elif [ ! -f "$(receipt)" ] || [[ "$OUT" != *"removed=0"* ]]; then
    test_fail "expected removed=0 and a recorded receipt; out: $OUT"
elif [ "$(count_backups)" != "0" ]; then
    test_fail "backup created though nothing was removed"
else
    test_pass
fi

test_start "C3c: emptied enabledPlugins stays {} (key is not deleted)"
new_sandbox "$SEED_ALL"
run_helper "$GOOD_TMPL_DIR"
if [ "$(jq -c '.enabledPlugins' "$(settings)")" = "{}" ]; then test_pass; else
    test_fail "enabledPlugins is now: $(jq -c '.enabledPlugins' "$(settings)")"; fi

# ===========================================================================
# C4 - NEGATIVE CONTROL against the pristine (pre-fix) tap code
# ===========================================================================
# The pristine blobs are the last commits of each file that do NOT yet contain
# the XACA-1227 helper, read from the tap repo's own history. If that history
# is unavailable (shallow clone / no git) the control is SKIPPED LOUDLY and
# counted - never reported as a pass.
pristine_blob() {  # <relpath> <marker-that-must-be-absent> -> stdout (blob) / rc 1
    local rel="$1" marker="$2" sha
    command -v git >/dev/null 2>&1 || return 1
    for sha in $(git -C "$TAP_ROOT" rev-list -n 60 HEAD -- "$rel" 2>/dev/null); do
        if ! git -C "$TAP_ROOT" show "$sha:$rel" 2>/dev/null | grep -q "$marker"; then
            git -C "$TAP_ROOT" show "$sha:$rel" 2>/dev/null
            return 0
        fi
    done
    return 1
}
CTRL="$TEST_TMP_DIR/pristine"
mkdir -p "$CTRL/libexec/installers"
CTRL_OK=true
if pristine_blob libexec/installers/install-claude-config.sh _xaca1227_remove_legacy_template_plugins \
        > "$CTRL/libexec/installers/install-claude-config.sh" \
   && [ -s "$CTRL/libexec/installers/install-claude-config.sh" ] \
   && pristine_blob libexec/commands/aiteamforge-upgrade.sh _xaca1227_remove_legacy_template_plugins \
        > "$CTRL/upgrade.pristine.sh" \
   && [ -s "$CTRL/upgrade.pristine.sh" ]; then
    _extract_fn "$CTRL/upgrade.pristine.sh" update_claude_settings > "$CTRL/update_claude_settings.sh"
    [ -s "$CTRL/update_claude_settings.sh" ] || CTRL_OK=false
else
    CTRL_OK=false
fi

test_start "C4 CONTROL: the C2a assertion FAILS on the pristine pre-fix code (legacy keys REMAIN) - proves the test discriminates"
if [ "$CTRL_OK" != true ]; then
    test_skip_loud "pristine pre-fix blobs not obtainable from tap git history (shallow/no git); control NOT exercised"
else
    new_sandbox "$SEED_ALL"
    run_upgrade "$CTRL/libexec" "$CTRL/update_claude_settings.sh"
    N="$(legacy_true_count "$(settings)")"
    if [ "$N" = "5" ] && [ ! -f "$(receipt)" ] && [[ "$UOUT" != *"legacy-plugins:"* ]]; then
        echo "     CONTROL OK: pristine code leaves $N/5 legacy keys (C2a's cleanup assertion would be RED here)"
        test_pass
    else
        test_fail "control did not behave like pre-fix code (legacy true count=$N): the C2a assertion may be vacuous. out: $UOUT"
    fi
fi

test_start "C4b CONTROL: the C1/C2 assertion also detects the legacy template (pre-fix template yields legacy keys on a fresh install)"
new_sandbox ""
run_install "$UT_LIBEXEC" "$BAD_TMPL_DIR"
if [ "$(legacy_true_count "$(settings)")" = "5" ]; then
    echo "     CONTROL OK: legacy-bearing template -> 5 legacy keys on fresh install (C1 would be RED)"
    test_pass
else
    test_fail "legacy template did not produce legacy keys; C1 may be vacuous: $IOUT"
fi

# ===========================================================================
# C5 - receipt
# ===========================================================================
test_start "C5a: second run is a no-op even after the user re-adds a legacy key=true"
new_sandbox "$SEED_ALL"
run_helper "$GOOD_TMPL_DIR"; _rc1="$RC"
jq '.enabledPlugins["firebase@claude-plugins-official"] = true' "$(settings)" > "$SB/readd.json" && mv "$SB/readd.json" "$(settings)"
_ck="$(cksum_of "$(settings)")"
_nb="$(count_backups)"
run_helper "$GOOD_TMPL_DIR"
if [ "$_rc1" != "2" ]; then test_fail "first run rc=$_rc1 (want 2)"
elif [ "$RC" != "0" ] || [[ "$OUT" != *"already migrated"* ]]; then test_fail "second run rc=$RC out=$OUT (want 0 / already migrated)"
elif [ "$(cksum_of "$(settings)")" != "$_ck" ]; then test_fail "second run modified the file"
elif [ "$(jq -r '.enabledPlugins["firebase@claude-plugins-official"]' "$(settings)")" != "true" ]; then test_fail "re-added key was removed"
elif [ "$(count_backups)" != "$_nb" ]; then test_fail "second run created another backup"
else test_pass; fi

test_start "C5b: a receipt that covers a DIFFERENT target does not count; an UNREADABLE receipt -> untouched rc 3 (spec: modify nothing)"
new_sandbox "$SEED_ALL"
printf '{"ticket":"XACA-1227","target":"/somewhere/else/settings.json"}\n' > "$(receipt)"
run_helper "$GOOD_TMPL_DIR"
_rcA="$RC"; _outA="$OUT"; _remA="$(legacy_present_count "$(settings)")"
new_sandbox "$SEED_ALL"
printf 'not json at all' > "$(receipt)"
_ckC="$(cksum_of "$(settings)")"
run_helper "$GOOD_TMPL_DIR"
# XACA-1227 review spec: an unparseable receipt is "untouched" (rc 3), never a
# license to migrate (the receipt is the only protection for later user choices).
if [ "$_rcA" = "2" ] && [ "$_remA" = "0" ] && [ "$RC" = "3" ] \
   && [ "$(cksum_of "$(settings)")" = "$_ckC" ] && [ "$(legacy_true_count "$(settings)")" = "5" ]; then
    test_pass
else
    test_fail "other-target receipt: rc=$_rcA remaining=$_remA ($_outA); corrupt receipt: rc=$RC (want 3) remaining=$(legacy_true_count "$(settings)") (want 5 untouched)"
fi

# ===========================================================================
# C6 - order guard
# ===========================================================================
test_start "C6a: template still carrying legacy keys -> skip, rc 1, file unchanged, no receipt, no backup"
new_sandbox "$SEED_ALL"
_ck="$(cksum_of "$(settings)")"
run_helper "$BAD_TMPL_DIR"
if [ "$RC" != "1" ]; then test_fail "rc=$RC (want 1); out: $OUT"
elif [ "$(cksum_of "$(settings)")" != "$_ck" ]; then test_fail "file changed"
elif [ -e "$(receipt)" ]; then test_fail "receipt was written despite the order guard"
elif [ "$(count_backups)" != "0" ]; then test_fail "backup created despite the order guard"
elif [[ "$OUT" != *"legacy-plugins: skipped"* ]]; then test_fail "no 'legacy-plugins: skipped' line: $OUT"
else test_pass; fi

test_start "C6b: a template carrying even ONE legacy key (value false) trips the guard; missing template also skips"
new_sandbox "$SEED_ALL"
mkdir -p "$SB/t1/claude"
jq '.enabledPlugins = {"firebase@claude-plugins-official": false}' "$CANON_TEMPLATE" > "$SB/t1/claude/settings.json.template"
run_helper "$SB/t1"; _rcA="$RC"
mkdir -p "$SB/t2"
run_helper "$SB/t2"; _rcB="$RC"
if [ "$_rcA" = "1" ] && [ "$_rcB" = "1" ] && [ "$(legacy_true_count "$(settings)")" = "5" ] && [ ! -e "$(receipt)" ]; then
    test_pass
else
    test_fail "false-valued key rc=$_rcA, missing template rc=$_rcB, remaining=$(legacy_true_count "$(settings)")"
fi

test_start "C6c: setup path (install_settings_json) with a legacy-bearing template does not write a receipt"
new_sandbox "$SEED_ALL"
run_install "$UT_LIBEXEC" "$BAD_TMPL_DIR"
if [ ! -e "$(receipt)" ]; then test_pass; else test_fail "receipt written although the template re-adds the keys"; fi

# ===========================================================================
# C7 - dry-run
# ===========================================================================
test_start "C7a: helper --dry-run: rc 0, no write, no receipt, no backup, no stray temp file"
new_sandbox "$SEED_ALL"
_ck="$(cksum_of "$(settings)")"
_ls_before="$(ls -A "$SB/home/.claude" | wc -l | tr -d '[:space:]')"
run_helper "$GOOD_TMPL_DIR" --dry-run
if [ "$RC" != "0" ]; then test_fail "rc=$RC"
elif [ "$(cksum_of "$(settings)")" != "$_ck" ]; then test_fail "dry-run modified settings.json"
elif [ -e "$(receipt)" ]; then test_fail "dry-run wrote a receipt"
elif [ "$(count_backups)" != "0" ]; then test_fail "dry-run made a backup"
elif [ "$(ls -A "$SB/home/.claude" | wc -l | tr -d '[:space:]')" != "$_ls_before" ]; then test_fail "dry-run left a stray file beside the target"
elif [[ "$OUT" != *"legacy-plugins: dry-run (would remove 5"* ]]; then test_fail "report line wrong: $OUT"
else test_pass; fi

test_start "C7b: upgrade DRY_RUN=true branch: reports, writes nothing"
new_sandbox "$SEED_ALL"
_ck="$(cksum_of "$(settings)")"
_ls_before="$(ls -A "$SB/home/.claude" | wc -l | tr -d '[:space:]')"
run_upgrade "$UT_LIBEXEC" "$UPD_FN_SRC" true
if [[ "$UOUT" != *"legacy-plugins: dry-run"* ]]; then test_fail "no legacy-plugins dry-run line: $UOUT"
elif [ "$(cksum_of "$(settings)")" != "$_ck" ]; then test_fail "modified settings.json"
elif [ -e "$(receipt)" ] || [ "$(count_backups)" != "0" ]; then test_fail "receipt or backup written in dry-run"
elif [ "$(ls -A "$SB/home/.claude" | wc -l | tr -d '[:space:]')" != "$_ls_before" ]; then test_fail "stray file beside target"
else test_pass; fi

# ===========================================================================
# C8 - backup and mode
# ===========================================================================
test_start "C8: backup is byte-identical to the original; file mode 0600 preserved"
new_sandbox "$SEED_ALL"
chmod 600 "$(settings)"
cp "$(settings)" "$SB/original.json"
run_helper "$GOOD_TMPL_DIR"
BK="$(find "$SB/aiteamforge/.backups" -type f -path '*xaca1227-legacy-plugins-*' -name settings.json 2>/dev/null | head -1)"
if [ -z "$BK" ]; then test_fail "no backup file found"
elif ! cmp -s "$BK" "$SB/original.json"; then test_fail "backup differs from the original"
elif [ "$(mode_of "$(settings)")" != "600" ]; then test_fail "mode is $(mode_of "$(settings)"), want 600"
elif [ "$(count_backups)" != "1" ]; then test_fail "expected exactly 1 backup dir, got $(count_backups)"
elif [ "$(jq -r --arg c "$(canon_path "$(settings)")" '(.targets[$c].backup // .backup)' "$(receipt)")" != "$BK" ]; then test_fail "receipt backup path != actual backup"
else test_pass; fi

# ===========================================================================
# C9 - untouchable targets
# ===========================================================================
test_start "C9a: invalid JSON target: rc 3, byte-identical, no receipt, no backup"
new_sandbox ""
printf '{"enabledPlugins": {"firebase@claude-plugins-official": true,' > "$(settings)"
_ck="$(cksum_of "$(settings)")"
run_helper "$GOOD_TMPL_DIR"
if [ "$RC" = "3" ] && [ "$(cksum_of "$(settings)")" = "$_ck" ] && [ ! -e "$(receipt)" ] && [ "$(count_backups)" = "0" ]; then test_pass
else test_fail "rc=$RC receipt=$([ -e "$(receipt)" ] && echo yes || echo no) out=$OUT"; fi

test_start "C9b: missing target: rc 1, nothing created"
new_sandbox ""
run_helper "$GOOD_TMPL_DIR"
if [ "$RC" = "1" ] && [ ! -e "$(settings)" ] && [ ! -e "$(receipt)" ]; then test_pass
else test_fail "rc=$RC out=$OUT"; fi

test_start "C9c: symlink target: rc 3, link and destination untouched, no receipt"
new_sandbox ""
mkdir -p "$SB/managed"
printf '%s\n' "$SEED_ALL" > "$SB/managed/real-settings.json"
ln -s "$SB/managed/real-settings.json" "$(settings)"
_ck="$(cksum_of "$SB/managed/real-settings.json")"
run_helper "$GOOD_TMPL_DIR"
if [ "$RC" = "3" ] && [ -L "$(settings)" ] && [ "$(cksum_of "$SB/managed/real-settings.json")" = "$_ck" ] \
   && [ ! -e "$(receipt)" ] && [ "$(count_backups)" = "0" ]; then test_pass
else test_fail "rc=$RC link=$([ -L "$(settings)" ] && echo yes || echo no) out=$OUT"; fi

test_start "C9d: enabledPlugins that is an array / top-level array: rc 3, untouched, no receipt"
new_sandbox '{"enabledPlugins":["firebase@claude-plugins-official"]}'
_ck="$(cksum_of "$(settings)")"; run_helper "$GOOD_TMPL_DIR"; _rcA="$RC"; _ckA="$(cksum_of "$(settings)")"
new_sandbox '[1,2]'
_ckB0="$(cksum_of "$(settings)")"; run_helper "$GOOD_TMPL_DIR"
if [ "$_rcA" = "3" ] && [ "$_ckA" = "$_ck" ] && [ "$RC" = "3" ] && [ "$(cksum_of "$(settings)")" = "$_ckB0" ] && [ ! -e "$(receipt)" ]; then test_pass
else test_fail "rcA=$_rcA rcB=$RC"; fi

# ===========================================================================
# C10 - merge-failure guard (install_settings_json)
# ===========================================================================
test_start "C10a: invalid-JSON target through install_settings_json (inside if) is NOT truncated"
new_sandbox ""
printf '{"model": "opus", "enabledPlugins": {' > "$(settings)"
cp "$(settings)" "$SB/invalid.orig"
run_install
if [ ! -s "$(settings)" ]; then test_fail "settings.json truncated to $(wc -c < "$(settings)" | tr -d ' ') bytes (data loss): $IOUT"
elif ! cmp -s "$(settings)" "$SB/invalid.orig"; then test_fail "settings.json content changed"
elif [ -n "$(find "$TMPDIR" -maxdepth 1 -name 'claude-settings-merged-*' 2>/dev/null)" ]; then test_fail "merge temp left behind"
else test_pass; fi

test_start "C10b: top-level-array target (merge fails differently) is NOT replaced"
new_sandbox '[1,2,3]'
cp "$(settings)" "$SB/array.orig"
run_install
if [ -s "$(settings)" ] && cmp -s "$(settings)" "$SB/array.orig"; then test_pass
else test_fail "array target changed/truncated: $(cat "$(settings)")"; fi

test_start "C10c: a VALID target still merges (the guard must not block the success path)"
new_sandbox '{"customUserKey": 42, "model": "sonnet"}'
run_install
if jq -e '.customUserKey == 42 and (.hooks | type) == "object"' "$(settings)" >/dev/null 2>&1; then test_pass
else test_fail "valid merge did not produce merged object: $(head -c 300 "$(settings)")"; fi

test_start "C10 CONTROL: the C10a assertion FAILS on the pristine pre-fix install_settings_json (target truncated)"
if [ "$CTRL_OK" != true ]; then
    test_skip_loud "pristine pre-fix installer not obtainable from tap git history; control NOT exercised"
else
    new_sandbox ""
    printf '{"model": "opus", "enabledPlugins": {' > "$(settings)"
    run_install "$CTRL/libexec"
    if [ ! -s "$(settings)" ]; then
        echo "     CONTROL OK: pristine code truncated the invalid target to 0 bytes (C10a would be RED here)"
        test_pass
    else
        test_fail "pristine code did not truncate; C10a may be vacuous. target now: $(head -c 200 "$(settings)")"
    fi
fi

# ===========================================================================
# C11 - TABLE-DRIVEN ADVERSARIAL ROWS (PR #1287 blocking findings 018 / 019)
# ===========================================================================
# Provenance rule: the helper cannot tell a template-originated `true` from a
# user's deliberate `true`, so the RECEIPT is the only thing protecting later
# user choices. Every row below: seed state -> (first migration) -> the user
# deliberately sets a legacy id to true again -> second run -> assert the key
# SURVIVES and the receipt/output match the spec. Receipt v2 =
# {"ticket":"XACA-1227","version":2,"targets":{"<canon>":{removed,backup,at}}}
# keyed by canon = $(cd "$(dirname t)" && pwd -P)/basename.
#
# Row functions return 0 = every spec assertion holds, 1 = an assertion failed
# (ROW_MSG says which), 2 = harness/setup problem. The CONTROL driver runs the
# SAME function against tap 56b6a55a and passes ONLY on rc 1 (assertion red on
# pre-fix code); rc 2 can never masquerade as a discriminating control.
FW_FIRE='firebase@claude-plugins-official'
FW_SWIFT='swift-lsp@claude-plugins-official'
ROW_MSG=""

# th_* runners: explicit CLAUDE_CONFIG_DIR spelling + libexec, all sandboxed.
th_guard() {
    case "$1" in
        "$SB"/*) return 0 ;;
    esac
    echo "FATAL: sandbox escape: $1" >&2; exit 99
}
th_helper() {   # <cfg-spelling> <tmpl-dir> [libexec] -> OUT RC
    local cfg="$1" tmpl="$2" lib="${3:-$UT_LIBEXEC}"
    th_guard "$cfg"
    OUT="$(
        export HOME="$SB/home" AITEAMFORGE_DIR="$SB/aiteamforge" CLAUDE_CONFIG_DIR="$cfg" TEMPLATE_DIR="$tmpl"
        # shellcheck source=/dev/null
        source "$lib/installers/install-claude-config.sh" >/dev/null 2>&1
        set +e
        _xaca1227_remove_legacy_template_plugins
        echo "::rc=$?"
    )"
    RC="${OUT##*::rc=}"
    OUT="${OUT%::rc=*}"
}
th_install() {  # <cfg-spelling> [libexec] [tmpl-dir] -> IOUT
    local cfg="$1" lib="${2:-$UT_LIBEXEC}" tmpl="${3:-$GOOD_TMPL_DIR}"
    th_guard "$cfg"
    IOUT="$(
        export HOME="$SB/home" AITEAMFORGE_DIR="$SB/aiteamforge" CLAUDE_CONFIG_DIR="$cfg" TEMPLATE_DIR="$tmpl"
        # shellcheck source=/dev/null
        source "$lib/installers/install-claude-config.sh" >/dev/null 2>&1
        if install_settings_json; then echo "::install-rc=0"; else echo "::install-rc=1"; fi
    ) 2>&1)"
}
th_upgrade() {  # <cfg-spelling> -> UOUT   (the REAL extracted update_claude_settings)
    local cfg="$1"
    th_guard "$cfg"
    UOUT="$(
        export HOME="$SB/home" AITEAMFORGE_DIR="$SB/aiteamforge" CLAUDE_CONFIG_DIR="$cfg"
        LIBEXEC_DIR="$UT_LIBEXEC"
        FRAMEWORK_DIR="$SB/fw"
        WORKING_DIR="$SB/aiteamforge"
        DRY_RUN=false
        print_section() { :; }
        print_info() { :; }
        print_success() { echo "OK: $*"; }
        print_warning() { echo "WARN: $*"; }
        # shellcheck source=/dev/null
        source "$UPD_FN_SRC"
        update_claude_settings
    ) 2>&1)"
}

row_world() {   # fresh sandbox + $SB/real, $SB/realB config dirs
    new_sandbox ""
    mkdir -p "$SB/real" "$SB/realB"
}
set_key_true() {  # <file> <id>
    jq --arg k "$2" '.enabledPlugins[$k] = true' "$1" > "$1.tmp.$$" && mv "$1.tmp.$$" "$1"
}
key_is_true() { [ "$(jq -r --arg k "$2" '.enabledPlugins[$k]' "$1" 2>/dev/null)" = "true" ]; }
receipt_v2_has() {  # <canon-target>
    jq -e --arg c "$1" '.version == 2 and .ticket == "XACA-1227" and (.targets | type) == "object" and (.targets | has($c))' "$(receipt)" >/dev/null 2>&1
}
unlock_aitf() { chmod 755 "$SB/aiteamforge" 2>/dev/null; return 0; }
lock_aitf() {   # make ONLY new files in AITEAMFORGE_DIR impossible; .backups stays writable
    mkdir -p "$SB/aiteamforge/.backups"
    chmod 755 "$SB/aiteamforge/.backups"
    chmod 555 "$SB/aiteamforge"
}
row_fail() { ROW_MSG="$*"; return 1; }
row_setup_fail() { ROW_MSG="SETUP: $*"; return 2; }

# --- R2b/R3-R5 (+variants): re-run via a different spelling of the same file --
row_survive() {  # <spelling-token> [libexec]
    local spell="$1" lib="${2:-$UT_LIBEXEC}" S cfg ck c
    row_world
    S="$SB/real/settings.json"
    printf '%s\n' "$SEED_ALL" > "$S"
    c="$(canon_path "$S")"
    th_helper "$SB/real" "$GOOD_TMPL_DIR" "$lib"
    if [ "$RC" != "2" ] || [ "$(legacy_present_count "$S")" != "0" ]; then row_setup_fail "first migration rc=$RC out=$OUT"; return; fi
    set_key_true "$S" "$FW_FIRE"
    ln -s "$SB/real" "$SB/link"
    case "$spell" in
        plain)    cfg="$SB/real" ;;
        slash)    cfg="$SB/real/" ;;
        dslash)   cfg="$SB/real//" ;;
        symlink)  cfg="$SB/link" ;;
        dotdot)   cfg="$SB/real/../real" ;;
        combo)    cfg="$SB/link/../real/" ;;
        *)        row_setup_fail "unknown spelling $spell"; return ;;
    esac
    ck="$(cksum_of "$S")"
    th_helper "$cfg" "$GOOD_TMPL_DIR" "$lib"
    if ! key_is_true "$S" "$FW_FIRE"; then row_fail "user's re-enabled $FW_FIRE was REMOVED on rerun via '$cfg' (rc=$RC out=$OUT)"; return; fi
    if [ "$(cksum_of "$S")" != "$ck" ]; then row_fail "settings.json modified on rerun via '$cfg'"; return; fi
    if [ "$RC" != "0" ] || [[ "$OUT" != *"already migrated"* ]]; then row_fail "rerun via '$cfg': rc=$RC out=$OUT (want 0 / already migrated)"; return; fi
    if ! receipt_v2_has "$c"; then row_fail "receipt is not a v2 set holding canonical $c: $(cat "$(receipt)" 2>/dev/null)"; return; fi
    if [ "$(jq -r '.targets | length' "$(receipt)")" != "1" ]; then row_fail "one physical file produced $(jq -r '.targets | length' "$(receipt)") receipt entries"; return; fi
    return 0
}

# --- R2: migrate A, migrate B (same AITEAMFORGE_DIR), re-enable on A, rerun A -
row_two_targets() {  # [libexec]
    local lib="${1:-$UT_LIBEXEC}" A B ca cb ck
    row_world
    A="$SB/real/settings.json"; B="$SB/realB/settings.json"
    printf '%s\n' "$SEED_ALL" > "$A"; printf '%s\n' "$SEED_ALL" > "$B"
    ca="$(canon_path "$A")"; cb="$(canon_path "$B")"
    th_helper "$SB/real" "$GOOD_TMPL_DIR" "$lib"; if [ "$RC" != "2" ]; then row_setup_fail "migrate A rc=$RC: $OUT"; return; fi
    th_helper "$SB/realB" "$GOOD_TMPL_DIR" "$lib"; if [ "$RC" != "2" ]; then row_setup_fail "migrate B rc=$RC: $OUT"; return; fi
    set_key_true "$A" "$FW_FIRE"; set_key_true "$B" "$FW_SWIFT"
    ck="$(cksum_of "$A")"
    th_helper "$SB/real" "$GOOD_TMPL_DIR" "$lib"
    if ! key_is_true "$A" "$FW_FIRE"; then row_fail "A's re-enabled key removed after B was migrated in between (rc=$RC out=$OUT)"; return; fi
    if [ "$RC" != "0" ] || [ "$(cksum_of "$A")" != "$ck" ] || [[ "$OUT" != *"already migrated"* ]]; then row_fail "A rerun rc=$RC out=$OUT"; return; fi
    th_helper "$SB/realB" "$GOOD_TMPL_DIR" "$lib"
    if ! key_is_true "$B" "$FW_SWIFT"; then row_fail "B's re-enabled key removed on rerun (rc=$RC out=$OUT)"; return; fi
    if ! receipt_v2_has "$ca"; then row_fail "receipt lost A ($ca): $(cat "$(receipt)" 2>/dev/null)"; return; fi
    if ! receipt_v2_has "$cb"; then row_fail "receipt lost B ($cb): $(cat "$(receipt)" 2>/dev/null)"; return; fi
    return 0
}

# --- R1: fresh install (target absent) -> user enables legacy id -> upgrade ---
row_fresh_then_upgrade() {  # [libexec]
    local lib="${1:-$UT_LIBEXEC}" S c ck
    row_world
    S="$SB/real/settings.json"; c="$(canon_path "$S")"
    th_install "$SB/real" "$lib" "$GOOD_TMPL_DIR"
    if [ ! -f "$S" ] || [ "$(legacy_present_count "$S")" != "0" ]; then row_setup_fail "fresh install produced no clean settings: $IOUT"; return; fi
    if [ ! -f "$(receipt)" ]; then row_fail "fresh install recorded NO receipt (target never held template-originated keys; helper cannot tell a later user enable apart)"; return; fi
    if ! receipt_v2_has "$c"; then row_fail "fresh-install receipt does not cover $c as v2: $(cat "$(receipt)")"; return; fi
    if [ "$(jq -c --arg c "$c" '.targets[$c].removed' "$(receipt)")" != "[]" ]; then row_fail "fresh-install receipt removed != []: $(cat "$(receipt)")"; return; fi
    set_key_true "$S" "$FW_SWIFT"
    ck="$(cksum_of "$S")"
    th_helper "$SB/real" "$GOOD_TMPL_DIR" "$lib"
    if ! key_is_true "$S" "$FW_SWIFT"; then row_fail "helper removed the user's $FW_SWIFT after a fresh install (rc=$RC out=$OUT)"; return; fi
    if [ "$(cksum_of "$S")" != "$ck" ]; then row_fail "helper modified settings after fresh install"; return; fi
    th_upgrade "$SB/real"
    if ! key_is_true "$S" "$FW_SWIFT"; then row_fail "UPGRADE (update_claude_settings) removed the user's $FW_SWIFT; out: $UOUT"; return; fi
    if [[ "$UOUT" == *"legacy-plugins: removed="* ]]; then row_fail "upgrade reported a removal: $UOUT"; return; fi
    return 0
}

# --- TABLE (spelling rows; id|token|description) ------------------------------
TABLE_SURVIVE='R3|slash|trailing slash CLAUDE_CONFIG_DIR=real/
R3b|dslash|double trailing slash real//
R4|symlink|parent reached through a symlink (link -> real)
R5|dotdot|non-normalized real/../real
R5b|combo|symlink + dotdot + trailing slash (link/../real/)'

test_start "R1: fresh install (target absent) -> user enables legacy id -> helper AND upgrade update_claude_settings leave it; v2 receipt records removed=[]"
row_fresh_then_upgrade; _r=$?
if [ "$_r" = 0 ]; then test_pass; else test_fail "$ROW_MSG"; fi

test_start "R2: migrate A, migrate B (same AITEAMFORGE_DIR), user re-enables on A, rerun A -> survives; receipt holds A AND B"
row_two_targets; _r=$?
if [ "$_r" = 0 ]; then test_pass; else test_fail "$ROW_MSG"; fi

test_start "R2b: plain same-spelling rerun survives (baseline row of the spelling table)"
row_survive plain; _r=$?
if [ "$_r" = 0 ]; then test_pass; else test_fail "$ROW_MSG"; fi

while IFS='|' read -r _id _spell _desc; do
    [ -n "$_id" ] || continue
    test_start "$_id: $_desc -> re-enabled key survives, 'already migrated', single canonical receipt entry"
    row_survive "$_spell"; _r=$?
    if [ "$_r" = 0 ]; then test_pass; else test_fail "$ROW_MSG"; fi
done <<EOT
$TABLE_SURVIVE
EOT

# --- R6: removal path, receipt write forced to fail ---------------------------
test_start "R6a: removal path, AITEAMFORGE_DIR not writable for the receipt -> rc 1, settings byte-identical, 'could not record receipt; nothing removed'"
if [ "$(id -u)" = "0" ]; then
    test_skip_loud "running as root: chmod cannot make the receipt unwritable"
else
    row_world
    printf '%s\n' "$SEED_ALL" > "$SB/real/settings.json"
    cp "$SB/real/settings.json" "$SB/pre.json"
    lock_aitf
    th_helper "$SB/real" "$GOOD_TMPL_DIR"
    unlock_aitf
    if [ "$RC" != "1" ]; then test_fail "rc=$RC (want 1); out: $OUT"
    elif ! cmp -s "$SB/real/settings.json" "$SB/pre.json"; then test_fail "settings.json changed although the receipt could not be recorded"
    elif [[ "$OUT" != *"legacy-plugins: skipped (could not record receipt; nothing removed)"* ]]; then test_fail "wrong message: $OUT"
    elif [ -e "$(receipt)" ]; then test_fail "a receipt exists after a failed write"
    elif [ "$(legacy_true_count "$SB/real/settings.json")" != "5" ]; then test_fail "legacy keys were removed"
    else test_pass; fi
fi

test_start "R6b: receipt path pre-created as a DIRECTORY -> nothing removed, settings byte-identical, rc 1 (write failed) or 3 (unreadable receipt), no file moved INTO the directory"
row_world
printf '%s\n' "$SEED_ALL" > "$SB/real/settings.json"
cp "$SB/real/settings.json" "$SB/pre.json"
mkdir -p "$(receipt)"
th_helper "$SB/real" "$GOOD_TMPL_DIR"
# A directory at the receipt path is either an unwritable receipt (rc 1, "could not
# record receipt") or an unreadable one (rc 3, "untouched (receipt ... unreadable");
# both honour the invariant (nothing removed). R6a pins the exact rc-1 contract.
if [ "$RC" != "1" ] && [ "$RC" != "3" ]; then test_fail "rc=$RC (want 1 or 3); out: $OUT"
elif ! cmp -s "$SB/real/settings.json" "$SB/pre.json"; then test_fail "settings.json changed although the receipt could not be recorded"
elif [[ "$OUT" != *"could not record receipt; nothing removed"* ]] && [[ "$OUT" != *"legacy-plugins: untouched (receipt"* ]]; then test_fail "wrong message: $OUT"
elif [ -n "$(find "$(receipt)" -type f 2>/dev/null)" ]; then test_fail "receipt file was written INTO the directory (mv onto a directory moves into it)"
else test_pass; fi

# --- R7: v1 receipt (56b6a55a format) ----------------------------------------
test_start "R7: v1 single-record receipt covers its (canonicalized) target -> survives; a write for another target upgrades to v2 and still covers the v1 target"
row_world
A="$SB/real/settings.json"; B="$SB/realB/settings.json"
printf '%s\n' "{\"enabledPlugins\":{\"$FW_FIRE\":true,\"mine@x\":true}}" > "$A"
printf '%s\n' "$SEED_ALL" > "$B"
# v1 exactly as 56b6a55a wrote it: raw (un-canonicalized) target string
jq -n -c --arg t "$A" '{ticket:"XACA-1227",target:$t,removed:["frontend-design@claude-plugins-official"],backup:null,at:"2026-11-06T00:00:00Z"}' > "$(receipt)"
ck="$(cksum_of "$A")"
th_helper "$SB/real/" "$GOOD_TMPL_DIR"      # trailing-slash spelling vs the raw v1 string
_rc_a="$RC"; _out_a="$OUT"
th_helper "$SB/realB" "$GOOD_TMPL_DIR"; _rc_b="$RC"
th_helper "$SB/real" "$GOOD_TMPL_DIR"; _rc_a2="$RC"; _out_a2="$OUT"
if [ "$_rc_a" != "0" ] || [[ "$_out_a" != *"already migrated"* ]]; then test_fail "v1 receipt not honored: rc=$_rc_a out=$_out_a"
elif [ "$_rc_b" != "2" ]; then test_fail "migrating B rc=$_rc_b (want 2)"
elif ! key_is_true "$A" "$FW_FIRE" || [ "$(cksum_of "$A")" != "$ck" ]; then test_fail "A's key removed or file modified"
elif ! receipt_v2_has "$(canon_path "$A")" || ! receipt_v2_has "$(canon_path "$B")"; then test_fail "receipt after B write is not a v2 set covering both A and B: $(cat "$(receipt)")"
elif [ "$_rc_a2" != "0" ] || [[ "$_out_a2" != *"already migrated"* ]]; then test_fail "A rerun after v2 upgrade rc=$_rc_a2 out=$_out_a2"
else test_pass; fi

# --- R8: unreadable receipt ----------------------------------------------------
test_start "R8: unreadable receipt (garbage / truncated) -> 'untouched (receipt ... unreadable' rc 3; settings AND receipt unchanged; no backup"
_r8_fail=""
_r8_i=0
for _g in 'not json at all' '{"ticket":"XACA-1227","version":2,"targets":{'; do
    _r8_i=$((_r8_i + 1))
    row_world
    printf '%s\n' "$SEED_ALL" > "$SB/real/settings.json"
    printf '%s' "$_g" > "$(receipt)"
    ck="$(cksum_of "$SB/real/settings.json")"; rk="$(cksum_of "$(receipt)")"
    th_helper "$SB/real" "$GOOD_TMPL_DIR"
    if [ "$RC" != "3" ]; then _r8_fail="$_r8_fail [#$_r8_i rc=$RC (want 3): $OUT]"
    elif [[ "$OUT" != *"legacy-plugins: untouched (receipt"*"unreadable"* ]]; then _r8_fail="$_r8_fail [#$_r8_i wrong message: $OUT]"
    elif [ "$(cksum_of "$SB/real/settings.json")" != "$ck" ]; then _r8_fail="$_r8_fail [#$_r8_i settings changed]"
    elif [ "$(cksum_of "$(receipt)")" != "$rk" ]; then _r8_fail="$_r8_fail [#$_r8_i receipt changed]"
    elif [ "$(count_backups)" != "0" ]; then _r8_fail="$_r8_fail [#$_r8_i backup created]"; fi
done
if [ -z "$_r8_fail" ]; then test_pass; else test_fail "$_r8_fail"; fi

# --- R9: removed=0 + receipt-write failure (documented residual) --------------
test_start "R9: removed=0 and the receipt cannot be written -> rc 0, settings unchanged, the output REPORTS it could not record (documented residual)"
if [ "$(id -u)" = "0" ]; then
    test_skip_loud "running as root: chmod cannot make the receipt unwritable"
else
    row_world
    printf '%s\n' '{"enabledPlugins":{"mine@x":true}}' > "$SB/real/settings.json"
    cp "$SB/real/settings.json" "$SB/pre.json"
    lock_aitf
    th_helper "$SB/real" "$GOOD_TMPL_DIR"
    unlock_aitf
    if [ "$RC" != "0" ]; then test_fail "rc=$RC (want 0); out: $OUT"
    elif ! cmp -s "$SB/real/settings.json" "$SB/pre.json"; then test_fail "settings changed"
    elif ! printf '%s' "$OUT" | grep -Eq 'could not (record|write)'; then test_fail "output does not report the receipt failure: $OUT"
    elif [[ "$OUT" == *"receipt recorded"* ]]; then test_fail "output claims a receipt was recorded: $OUT"
    elif [ -e "$(receipt)" ]; then test_fail "receipt exists"
    else test_pass; fi
fi

# --- R10: order guard on a FRESH install ---------------------------------------
test_start "R10: fresh install while the template still ships legacy keys -> NO receipt recorded (setup re-adds the keys; recording would be wrong)"
row_world
th_install "$SB/real" "$UT_LIBEXEC" "$BAD_TMPL_DIR"
if [ ! -f "$SB/real/settings.json" ] || [ "$(legacy_true_count "$SB/real/settings.json")" != "5" ]; then test_fail "precondition: fresh install from legacy template should carry 5 legacy keys: $IOUT"
elif [ -e "$(receipt)" ]; then test_fail "receipt recorded despite a legacy-bearing template: $(cat "$(receipt)")"
else test_pass; fi

# --- R11: positive control (the table must not pass by never removing) --------
test_start "R11: genuine pre-fix legacy file, no receipt -> all 5 keys ARE removed, user key kept, v2 receipt written, report uses kept= (not kept-user=)"
row_world
S="$SB/real/settings.json"
jq '.enabledPlugins["mine@x"] = true' <<<"$SEED_ALL" > "$S"
th_helper "$SB/real" "$GOOD_TMPL_DIR"
if [ "$RC" != "2" ]; then test_fail "rc=$RC (want 2); out: $OUT"
elif [ "$(legacy_present_count "$S")" != "0" ]; then test_fail "legacy keys remain: $(jq -c .enabledPlugins "$S")"
elif ! key_is_true "$S" "mine@x"; then test_fail "user key lost"
elif ! receipt_v2_has "$(canon_path "$S")"; then test_fail "no v2 receipt for the target: $(cat "$(receipt)" 2>/dev/null)"
elif [[ "$OUT" != *"removed=5"* ]] || [[ "$OUT" != *"kept=1"* ]] || [[ "$OUT" == *"kept-user="* ]]; then test_fail "report wrong: $OUT"
else test_pass; fi

# --- NEGATIVE CONTROLS: the same rows against tap 56b6a55a ---------------------
PRIOR_SHA=56b6a55a
PRIOR_LIBEXEC="$TEST_TMP_DIR/prior-libexec"
mkdir -p "$PRIOR_LIBEXEC/installers"
PRIOR_OK=true
if ! command -v git >/dev/null 2>&1 \
   || ! git -C "$TAP_ROOT" show "$PRIOR_SHA:libexec/installers/install-claude-config.sh" > "$PRIOR_LIBEXEC/installers/install-claude-config.sh" 2>/dev/null \
   || [ ! -s "$PRIOR_LIBEXEC/installers/install-claude-config.sh" ] \
   || ! grep -q '_xaca1227_remove_legacy_template_plugins' "$PRIOR_LIBEXEC/installers/install-claude-config.sh"; then
    PRIOR_OK=false
fi

# control_row <label> <function> [args...]: passes ONLY when the row assertion is RED (rc 1) on the prior code
control_row() {
    local label="$1" fn="$2" r
    shift 2
    test_start "$label CONTROL: this row FAILS on tap $PRIOR_SHA (single-slot, string-keyed receipt) - proves the table discriminates"
    if [ "$PRIOR_OK" != true ]; then
        test_skip_loud "tap $PRIOR_SHA not obtainable from git history; control NOT exercised"
        return
    fi
    "$fn" "$@" "$PRIOR_LIBEXEC"; r=$?
    if [ "$r" = 1 ]; then
        echo "     CONTROL OK: red on $PRIOR_SHA as required: $ROW_MSG"
        test_pass
    elif [ "$r" = 2 ]; then
        test_fail "control could not run (harness problem, not a discrimination proof): $ROW_MSG"
    else
        test_fail "row is GREEN on pre-fix code: the row is vacuous for this variant"
    fi
}
control_row R1 row_fresh_then_upgrade
control_row R2 row_two_targets
while IFS='|' read -r _id _spell _desc; do
    [ -n "$_id" ] || continue
    control_row "$_id" row_survive "$_spell"
done <<EOT
$TABLE_SURVIVE
EOT

# ===========================================================================
# S1 - wiring: the function is defined AND called from both paths
# ===========================================================================
test_start "S1: helper is defined once, called from install_settings_json and update_claude_settings (a defined-but-uncalled helper is the bug class)"
_def="$(grep -cE '^_xaca1227_remove_legacy_template_plugins\(\) \{' "$INSTALLER")"
_inst="$(_extract_fn "$INSTALLER" install_settings_json | grep -c '_xaca1227_remove_legacy_template_plugins')"
_upg="$(grep -c '_xaca1227_remove_legacy_template_plugins' "$UPD_FN_SRC")"
if [ "$_def" = "1" ] && [ "$_inst" -ge 1 ] && [ "$_upg" -ge 2 ] && grep -qE '^update_claude_settings$' "$UPGRADE_SH"; then test_pass
else test_fail "def=$_def install_settings_json refs=$_inst update_claude_settings refs=$_upg (want 1, >=1, >=2) or no bare call"; fi

# ---------------------------------------------------------------------------
if [ -n "${_PASS_COUNT+x}" ]; then
    _TOTAL=$((_PASS_COUNT + _FAIL_COUNT))
    echo ""
    echo "XACA-1227 legacy-plugin cleanup tests: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed, ${_SKIP_COUNT} skipped-loud (${_TOTAL} assertions executed)"
    if [ "$_TOTAL" -eq 0 ]; then
        echo "FATAL: zero assertions executed - vacuous pass, not a real result" >&2
        exit 1
    fi
    [ "${_FAIL_COUNT:-0}" -eq 0 ] || exit 1
fi
exit 0
