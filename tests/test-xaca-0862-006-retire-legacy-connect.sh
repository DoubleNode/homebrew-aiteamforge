#!/bin/bash
# test-xaca-0862-006-retire-legacy-connect.sh
#
# XACA-0862 (subitem -006, PROTECTED [Test] gate).
#
# Regression suite for the migration half of subitem 006:
#   1. `aiteamforge doctor --check connect` composes its "installed"
#      identifier for a PARAMETRIC team (finance/legal/medical/freelance —
#      TEAM_HAS_PROJECTS="true" AND a shipped <base>-startup.sh) as the bare
#      team id, matching what subitems 001-003's renderer actually writes
#      (<base>-connect.sh), not the pre-XACA-0862 instance-keyed name
#      (<base>-<project>-connect.sh). A PRE-XACA-0862 per-instance file still
#      on disk is therefore reported as an ORPHAN, with a hint naming its
#      replacement when one has been rendered.
#   2. `aiteamforge migrate --retire-legacy-connect-scripts` is the one-shot,
#      opt-in retirement of exactly those legacy orphans: never deletes (mv
#      to a timestamped backup dir), only retires a legacy pair once its
#      team-scoped replacement already exists on disk, and is idempotent.
#
# WRITTEN AGAINST OBSERVABLE OUTPUT (doctor's report text, files on disk,
# migrate's exit code) — not against internal function/variable names.
#
# Runs standalone (`bash tests/test-xaca-0862-006-retire-legacy-connect.sh`)
# OR via test-runner.sh. Exit 0 = all pass, exit 1 = any fail.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI_SH="$TAP_ROOT/bin/aiteamforge-cli.sh"
MIGRATE_SH="$TAP_ROOT/libexec/commands/aiteamforge-migrate.sh"

for _req in "$CLI_SH" "$MIGRATE_SH"; do
    if [ ! -f "$_req" ]; then
        echo "FATAL: required file not found: $_req" >&2
        exit 1
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework (works sourced by test-runner.sh OR invoked directly).
# ─────────────────────────────────────────────────────────────────────────────
_STANDALONE=false
if ! type -t test_start >/dev/null 2>&1; then
    _STANDALONE=true
    _PASS_COUNT=0
    _FAIL_COUNT=0
    _CURRENT_TEST=""
    test_start() { _CURRENT_TEST="$1"; echo "  >> $1"; }
    test_pass()  { _PASS_COUNT=$((_PASS_COUNT + 1)); echo "     PASS: $_CURRENT_TEST"; }
    test_fail()  { _FAIL_COUNT=$((_FAIL_COUNT + 1)); echo "     FAIL: $_CURRENT_TEST — $1" >&2; }
fi

# ─────────────────────────────────────────────────────────────────────────────
# Temp directory (runner-supplied or our own). Never touches real $HOME.
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca0862006-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
cleanup() { if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ] && [ -d "${TEST_TMP_DIR:-}" ]; then find "$TEST_TMP_DIR" -depth -delete 2>/dev/null || true; fi; }
trap cleanup EXIT

WORK_DIR="$TEST_TMP_DIR/xaca0862006"
mkdir -p "$WORK_DIR"
_next_sandbox() { mktemp -d "$WORK_DIR/sbx-XXXXXX"; }

_new_sandbox() {
    local sbx
    sbx="$(_next_sandbox)"
    mkdir -p "$sbx/home/.aiteamforge" "$sbx/aiteamforge"
    echo "$sbx"
}

_stub_script() {
    printf '#!/bin/zsh\necho stub\n' > "$1"
    chmod +x "$1"
}

_write_config() {
    # $1=path, $2.. = team ids to list in "teams"
    local cfg="$1"; shift
    local teams_json="[]"
    if [ "$#" -gt 0 ]; then
        teams_json="$(printf '"%s",' "$@")"
        teams_json="[${teams_json%,}]"
    fi
    printf '{ "teams": %s, "team_paths": {} }\n' "$teams_json" > "$cfg"
}

_run_doctor() {
    local sbx="$1"
    HOME="$sbx/home" \
    AITEAMFORGE_HOME="$TAP_ROOT" \
    AITEAMFORGE_DIR="$sbx/aiteamforge" \
    AITEAMFORGE_CONFIG="$sbx/home/.aiteamforge/team-paths.json" \
        bash "$CLI_SH" doctor --check connect --verbose 2>&1
}

_run_retire() {
    local sbx="$1"; shift
    HOME="$sbx/home" \
    AITEAMFORGE_HOME="$TAP_ROOT" \
    AITEAMFORGE_DIR="$sbx/aiteamforge" \
        bash "$MIGRATE_SH" --retire-legacy-connect-scripts "$@"
}

# ═══════════════════════════════════════════════════════════════════════════
# R1: doctor reports a legacy per-instance orphan with a specific,
#     replacement-naming hint once the team-scoped script has been rendered.
# ═══════════════════════════════════════════════════════════════════════════
test_start "R1: doctor names the team-scoped replacement in the orphan hint for a superseded legacy file"
R1_SBX="$(_new_sandbox)"
_stub_script "$R1_SBX/aiteamforge/finance-connect.sh"
_stub_script "$R1_SBX/aiteamforge/finance-disconnect.sh"
_stub_script "$R1_SBX/aiteamforge/finance-personal-connect.sh"
_stub_script "$R1_SBX/aiteamforge/finance-personal-disconnect.sh"
_write_config "$R1_SBX/aiteamforge/.aiteamforge-config" finance
R1_OUT="$(_run_doctor "$R1_SBX")"
R1_OK=true
echo "$R1_OUT" | grep -qF "Connect script present for finance" || R1_OK=false
echo "$R1_OUT" | grep -qF "'finance-personal-connect.sh' matches no installed instance" || R1_OK=false
echo "$R1_OUT" | grep -qF "Superseded by team-scoped finance-connect.sh" || R1_OK=false
echo "$R1_OUT" | grep -qF "aiteamforge migrate --retire-legacy-connect-scripts" || R1_OK=false
if [ "$R1_OK" = true ]; then test_pass; else test_fail "expected present+superseded-orphan report; got: $R1_OUT"; fi

# ═══════════════════════════════════════════════════════════════════════════
# R2: a legacy orphan with NO team-scoped replacement yet gets the generic
#     hint, never the migrate pointer (nothing to retire it INTO).
# ═══════════════════════════════════════════════════════════════════════════
test_start "R2: doctor gives the generic hint (not the migrate pointer) when no team-scoped replacement exists yet"
R2_SBX="$(_new_sandbox)"
_stub_script "$R2_SBX/aiteamforge/legal-coparenting-connect.sh"
_stub_script "$R2_SBX/aiteamforge/legal-coparenting-disconnect.sh"
_write_config "$R2_SBX/aiteamforge/.aiteamforge-config" legal
R2_OUT="$(_run_doctor "$R2_SBX")"
R2_OK=true
echo "$R2_OUT" | grep -qF "'legal-coparenting-connect.sh' matches no installed instance" || R2_OK=false
echo "$R2_OUT" | grep -qF "Left in place deliberately" || R2_OK=false
echo "$R2_OUT" | grep -qF "Superseded by team-scoped" && R2_OK=false
if [ "$R2_OK" = true ]; then test_pass; else test_fail "expected generic orphan hint only; got: $R2_OUT"; fi

# ═══════════════════════════════════════════════════════════════════════════
# R3: --dry-run previews retirement without touching the filesystem.
# ═══════════════════════════════════════════════════════════════════════════
test_start "R3: --retire-legacy-connect-scripts --dry-run changes nothing on disk"
R3_SBX="$(_new_sandbox)"
_stub_script "$R3_SBX/aiteamforge/finance-connect.sh"
_stub_script "$R3_SBX/aiteamforge/finance-disconnect.sh"
_stub_script "$R3_SBX/aiteamforge/finance-personal-connect.sh"
_stub_script "$R3_SBX/aiteamforge/finance-personal-disconnect.sh"
R3_BEFORE="$(ls "$R3_SBX/aiteamforge" | sort)"
R3_OUT="$(_run_retire "$R3_SBX" --dry-run)"
R3_AFTER="$(ls "$R3_SBX/aiteamforge" | sort)"
R3_OK=true
[ "$R3_BEFORE" = "$R3_AFTER" ] || R3_OK=false
# Native bash substring match instead of `echo ... | grep -qF` — grep -q exits
# as soon as it finds its match, which can SIGPIPE the echo mid-write and
# print a cosmetic "write error: Broken pipe" that has nothing to do with the
# assertion's actual pass/fail result. No subprocess/pipe needed for a plain
# substring check against an already-captured variable.
case "$R3_OUT" in
    *"[DRY RUN] Would retire: finance-personal-connect.sh"*) ;;
    *) R3_OK=false ;;
esac
case "$R3_OUT" in
    *"[DRY RUN] Would retire: finance-personal-disconnect.sh"*) ;;
    *) R3_OK=false ;;
esac
if [ "$R3_OK" = true ]; then test_pass; else test_fail "dry-run must preview only, no filesystem change; before='$R3_BEFORE' after='$R3_AFTER' out=$R3_OUT"; fi

# ═══════════════════════════════════════════════════════════════════════════
# R4 [HEADLINE, field-target replica]: a real run retires exactly the legacy
#     pair, MOVES (never deletes) it into a timestamped backup dir, and
#     leaves `doctor --check connect` fully clean afterward.
# ═══════════════════════════════════════════════════════════════════════════
test_start "R4 [HEADLINE]: real retirement moves the legacy pair to backup and doctor goes clean"
R4_SBX="$(_new_sandbox)"
_stub_script "$R4_SBX/aiteamforge/finance-connect.sh"
_stub_script "$R4_SBX/aiteamforge/finance-disconnect.sh"
_stub_script "$R4_SBX/aiteamforge/finance-personal-connect.sh"
_stub_script "$R4_SBX/aiteamforge/finance-personal-disconnect.sh"
_write_config "$R4_SBX/aiteamforge/.aiteamforge-config" finance
_run_retire "$R4_SBX" >/dev/null 2>&1
R4_REMAINING="$(ls "$R4_SBX/aiteamforge" | sort)"
R4_BACKUP_COUNT="$(find "$R4_SBX/home/aiteamforge-backups" -type f -name '*-connect.sh' -o -type f -name '*-disconnect.sh' 2>/dev/null | wc -l | tr -d ' ')"
R4_DOCTOR_OUT="$(_run_doctor "$R4_SBX")"
R4_OK=true
[ "$R4_REMAINING" = "$(printf 'finance-connect.sh\nfinance-disconnect.sh')" ] || R4_OK=false
[ "${R4_BACKUP_COUNT:-0}" -eq 2 ] || R4_OK=false
echo "$R4_DOCTOR_OUT" | grep -qi "orphan\|matches no installed instance" && R4_OK=false
echo "$R4_DOCTOR_OUT" | grep -qE "Warnings:[[:space:]]*0" || R4_OK=false
if [ "$R4_OK" = true ]; then
    test_pass
else
    test_fail "expected only team-scoped files left + 2 backed-up legacy files + clean doctor; remaining='$R4_REMAINING' backup_count=$R4_BACKUP_COUNT doctor_out=$R4_DOCTOR_OUT"
fi

# ═══════════════════════════════════════════════════════════════════════════
# R5 [SAFETY]: a legacy pair with NO team-scoped replacement rendered yet is
#     left completely untouched — retiring it first would strand a live team
#     with no connect script at all.
# ═══════════════════════════════════════════════════════════════════════════
test_start "R5 [SAFETY]: a legacy pair is untouched when its team-scoped replacement has not been rendered"
R5_SBX="$(_new_sandbox)"
_stub_script "$R5_SBX/aiteamforge/legal-coparenting-connect.sh"
_stub_script "$R5_SBX/aiteamforge/legal-coparenting-disconnect.sh"
# Capture the exit status directly off the command itself (`$?` here reflects
# `_run_retire`, NOT a `| tail`/`| grep` sitting downstream of it — there is
# no pipe in this call at all, but capture-first is kept as the house pattern
# regardless: assign, THEN inspect, never inspect after any intervening
# command touches `$?`). Output captured to a sandbox-scoped file (never real
# /tmp) so a failure message can show it without a second, status-clobbering
# command substitution.
R5_OUT_FILE="$WORK_DIR/r5-retire-out.$$"
_run_retire "$R5_SBX" >"$R5_OUT_FILE" 2>&1
R5_EXIT=$?
R5_REMAINING="$(ls "$R5_SBX/aiteamforge" | sort)"
R5_OK=true
[ "$R5_EXIT" -eq 0 ] || R5_OK=false
[ "$R5_REMAINING" = "$(printf 'legal-coparenting-connect.sh\nlegal-coparenting-disconnect.sh')" ] || R5_OK=false
if [ "$R5_OK" = true ]; then
    test_pass
else
    test_fail "legacy pair with no replacement must be left in place AND retirement must exit 0; exit=$R5_EXIT remaining='$R5_REMAINING' output=$(cat "$R5_OUT_FILE" 2>/dev/null)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# R6 [IDEMPOTENCY]: running retirement twice is a no-op the second time.
# ═══════════════════════════════════════════════════════════════════════════
test_start "R6 [IDEMPOTENCY]: a second retirement run finds nothing left to move"
R6_SBX="$(_new_sandbox)"
_stub_script "$R6_SBX/aiteamforge/finance-connect.sh"
_stub_script "$R6_SBX/aiteamforge/finance-disconnect.sh"
_stub_script "$R6_SBX/aiteamforge/finance-personal-connect.sh"
_stub_script "$R6_SBX/aiteamforge/finance-personal-disconnect.sh"
_run_retire "$R6_SBX" >/dev/null 2>&1
R6_SECOND_OUT="$(_run_retire "$R6_SBX" 2>&1)"
R6_EXIT=$?
R6_OK=true
[ "$R6_EXIT" -eq 0 ] || R6_OK=false
echo "$R6_SECOND_OUT" | grep -qi "already clean\|nothing.*retire\|No legacy" || R6_OK=false
if [ "$R6_OK" = true ]; then test_pass; else test_fail "second run must exit 0 and report nothing to retire; exit=$R6_EXIT out=$R6_SECOND_OUT"; fi

# ═══════════════════════════════════════════════════════════════════════════
# R7 [S4-style safety, own suite]: no rm/unlink/shred/find-delete path exists
#     anywhere in retire_legacy_connect_scripts() — every removal is an mv.
# ═══════════════════════════════════════════════════════════════════════════
test_start "R7 [SAFETY]: retire_legacy_connect_scripts() contains no rm/unlink/shred/find-delete path"
R7_FUNC_BODY="$(awk '/^retire_legacy_connect_scripts\(\)/,/^}/' "$MIGRATE_SH")"
# POSITIVE CONTROL (XACA-0862-017): an absence-assertion below is only
# meaningful once presence is established here. Without this, the extraction
# yields an EMPTY string whenever the function is missing/renamed — the
# absence-grep then finds nothing and PASSES, silently stopping protection
# on the exact defect it exists to catch. Require the body to be non-empty
# AND to actually contain the `mv` this function uses to relocate legacy
# files (proof we captured the real function, not a false-empty extraction).
if [ -z "$R7_FUNC_BODY" ]; then
    test_fail "retire_legacy_connect_scripts() not found in $MIGRATE_SH — awk extraction returned empty (function missing/renamed); the delete-safety check below would vacuously pass on this, so treat an empty extraction as failure, not success"
elif ! echo "$R7_FUNC_BODY" | grep -qE '(^|[^_a-zA-Z])mv[[:space:]]'; then
    test_fail "retire_legacy_connect_scripts() body found but contains no 'mv' — positive control failed, extraction may not be the real function body: $R7_FUNC_BODY"
elif echo "$R7_FUNC_BODY" | grep -qE '(^|[^_a-zA-Z])(rm|unlink|shred)[[:space:]]|find[^\n]*-delete'; then
    test_fail "a destructive command was found inside retire_legacy_connect_scripts(): $(echo "$R7_FUNC_BODY" | grep -nE '(^|[^_a-zA-Z])(rm|unlink|shred)[[:space:]]|find[^\n]*-delete')"
else
    test_pass
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary (standalone only; test-runner.sh owns totals when sourced by it).
# ─────────────────────────────────────────────────────────────────────────────
if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "XACA-0862-006 retire-legacy-connect tests: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    [ "${_FAIL_COUNT:-0}" -eq 0 ] || exit 1
fi
exit 0
