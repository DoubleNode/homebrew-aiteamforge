#!/bin/bash

# test-xaca-1740-upgrade-skill-links.sh
#
# XACA-1740: `aiteamforge upgrade` never linked newly shipped skills into
# ~/.claude/skills. install_skills() (install-claude-config.sh) creates one
# symlink per skill at INSTALL time only; update_skills() refreshed
# ${WORKING_DIR}/skills but never linked a skill added later, so every skill
# shipped after a machine's first install was missing on every consumer
# (measured on M1Pro, M4Mini, M1Mini 2026-11-03).
#
# CONTRACT UNDER TEST (from the ticket, not from the implementation):
#   After update_skills():
#     1. Every skill dir in ${WORKING_DIR}/skills with no ~/.claude/skills
#        entry is linked to it.
#     2. An existing correct link is left exactly as it was.
#     3. A real directory in ~/.claude/skills is never touched; a warning names it.
#     4. A dangling link that points into ${WORKING_DIR}/skills is pruned.
#     5. A link pointing anywhere else (dangling or not) is never touched;
#        a name collision with a shipped skill gets a warning.
#     6. DRY_RUN writes nothing.
#     7. Works when ${WORKING_DIR}/skills is itself a symlink to the Cellar.
#     8. A missing ~/.claude/skills dir is created.
#     9. update_skills is still CALLED in the upgrade run sequence.
#
# NEGATIVE CONTROL: against the pre-XACA-1740 update_skills(), T1, T4, T7, T8
# and T9b FAIL (nothing links or prunes). See the PR for the captured run.
#
# Every path is under TEST_TMP_DIR with a fake HOME and an explicit
# CLAUDE_CONFIG_DIR. Never touches the real ~/.claude or ~/aiteamforge.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UPGRADE_SH="$TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh"

if [ ! -f "$UPGRADE_SH" ]; then
    echo "FATAL: required file not found: $UPGRADE_SH" >&2
    exit 1
fi

# ─── Standalone framework (works under test-runner.sh or run directly) ───────
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

if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca1740-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
cleanup() { if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then rm -rf "$TEST_TMP_DIR"; fi; }
trap cleanup EXIT

WORK_DIR="$TEST_TMP_DIR/xaca1740"
mkdir -p "$WORK_DIR"
# Physical path, so fixtures compare cleanly on macOS (/var -> /private/var).
WORK_DIR="$(cd -P "$WORK_DIR" && pwd)"

# ─── Extract update_skills + every top-level helper it calls (transitively) ──
_extract_fn() {
    awk -v fn="$1" '
      $0 ~ ("^" fn "\\(\\) \\{") { capture=1 }
      capture { print }
      capture && /^}$/ { exit }
    ' "$UPGRADE_SH"
}

FN_MISSING=false
_ALL_TOPLEVEL_FNS="$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*\(\) \{' "$UPGRADE_SH" | sed -E 's/\(\) \{$//')"
_COMBINED_SRC="$(_extract_fn update_skills)"
if [ -z "$_COMBINED_SRC" ]; then
    FN_MISSING=true
    echo "  !! update_skills() not found in $UPGRADE_SH" >&2
else
    _EXTRACTED_NAMES=$'\n'"update_skills"$'\n'
    _pass=0
    while [ $_pass -lt 5 ]; do
        _pass=$((_pass + 1))
        _added=false
        for _cand in $_ALL_TOPLEVEL_FNS; do
            case "$_EXTRACTED_NAMES" in *$'\n'"${_cand}"$'\n'*) continue ;; esac
            if printf '%s\n' "$_COMBINED_SRC" | sed -E '/^[[:space:]]*#/d' | grep -qE "(^|[^A-Za-z0-9_])${_cand}([^A-Za-z0-9_(]|\$)"; then
                _helper="$(_extract_fn "$_cand")"
                [ -z "$_helper" ] && continue
                _COMBINED_SRC="${_helper}"$'\n\n'"${_COMBINED_SRC}"
                _EXTRACTED_NAMES="${_EXTRACTED_NAMES}${_cand}"$'\n'
                _added=true
            fi
        done
        [ "$_added" = true ] || break
    done
    printf '%s\n' "$_COMBINED_SRC" > "$WORK_DIR/extracted.sh"
    # shellcheck disable=SC1091
    source "$WORK_DIR/extracted.sh"
    declare -f update_skills >/dev/null || FN_MISSING=true
fi

# print_* stubs record output so tests can check warnings.
_LOG="$WORK_DIR/out.log"
for _p in print_section print_info print_success print_warning print_error; do
    eval "${_p}() { printf '%s %s\n' '${_p}' \"\$*\" >> \"\$_LOG\"; }"
done
prompt_yes_no() { return 0; }

# ─── Fixture builder ─────────────────────────────────────────────────────────
# _new_sandbox [symlinked]
#   FRAMEWORK_DIR/share/skills/<skills>   (the Cellar copy)
#   WORKING_DIR/skills                    (copied, or a symlink to the Cellar)
#   CLAUDE_CONFIG_DIR/skills              (created by each test as needed)
_new_sandbox() {
    SBX="$(mktemp -d "$WORK_DIR/sbx-XXXXXX")"
    export HOME="$SBX/home"
    FRAMEWORK_DIR="$SBX/cellar"
    WORKING_DIR="$HOME/aiteamforge"
    export CLAUDE_CONFIG_DIR="$HOME/.claude"
    unset CLAUDE_SANDBOX
    DRY_RUN=false
    NON_INTERACTIVE=true
    mkdir -p "$HOME" "$FRAMEWORK_DIR/share/skills" "$WORKING_DIR"
    local s
    for s in "Old Skill" "New Skill" "plain-skill"; do
        mkdir -p "$FRAMEWORK_DIR/share/skills/$s"
        printf 'name: %s\n' "$s" > "$FRAMEWORK_DIR/share/skills/$s/SKILL.md"
    done
    if [ "${1:-}" = symlinked ]; then
        ln -s "$FRAMEWORK_DIR/share/skills" "$WORKING_DIR/skills"
    else
        mkdir -p "$WORKING_DIR/skills"
        cp -R "$FRAMEWORK_DIR/share/skills/Old Skill" "$WORKING_DIR/skills/"
    fi
    CSK="$CLAUDE_CONFIG_DIR/skills"
    : > "$_LOG"
}

_run() { update_skills > "$SBX/stdout.log" 2>&1; }

# Snapshot of a tree: type, name and link target of every entry.
_snapshot() {
    ( cd "$1" 2>/dev/null && find . -print | LC_ALL=C sort | while IFS= read -r p; do
        if [ -L "$p" ]; then printf 'L %s -> %s\n' "$p" "$(readlink "$p")"
        elif [ -d "$p" ]; then printf 'D %s\n' "$p"
        else printf 'F %s %s\n' "$p" "$(cksum < "$p")"; fi
      done )
}

_skip_if_missing() {
    if [ "$FN_MISSING" = true ]; then test_fail "update_skills() not extractable"; return 0; fi
    return 1
}

# ─── T1: a skill added after install is linked ───────────────────────────────
test_start "T1: newly shipped skills are linked into ~/.claude/skills"
if ! _skip_if_missing; then
    _new_sandbox
    mkdir -p "$CSK"
    ln -s "$WORKING_DIR/skills/Old Skill" "$CSK/Old Skill"
    # Precondition: the new skill is not linked yet.
    if [ -e "$CSK/New Skill" ]; then
        test_fail "precondition: New Skill already present"
    else
        _run
        if [ -L "$CSK/New Skill" ] && [ "$(readlink "$CSK/New Skill")" = "$WORKING_DIR/skills/New Skill" ] \
           && [ -f "$CSK/New Skill/SKILL.md" ] \
           && [ -L "$CSK/plain-skill" ] && [ -f "$CSK/plain-skill/SKILL.md" ]; then
            test_pass
        else
            test_fail "New Skill/plain-skill not linked to the working copy: $(ls -l "$CSK" 2>&1 | tr '\n' ' ')"
        fi
    fi
fi

# ─── T2: an existing correct link is left as it was ──────────────────────────
test_start "T2: existing correct link untouched"
if ! _skip_if_missing; then
    _new_sandbox
    mkdir -p "$CSK"
    ln -s "$WORKING_DIR/skills/Old Skill" "$CSK/Old Skill"
    before_inode="$(ls -id "$CSK/Old Skill" | awk '{print $1}')"
    _run
    after_inode="$(ls -id "$CSK/Old Skill" | awk '{print $1}')"
    if [ -L "$CSK/Old Skill" ] && [ "$(readlink "$CSK/Old Skill")" = "$WORKING_DIR/skills/Old Skill" ] \
       && [ "$before_inode" = "$after_inode" ]; then
        test_pass
    else
        test_fail "link changed (inode $before_inode -> $after_inode, target $(readlink "$CSK/Old Skill"))"
    fi
fi

# ─── T3: a real user dir is untouched and warned about ───────────────────────
test_start "T3: real directory with a shipped skill's name is untouched, with a warning"
if ! _skip_if_missing; then
    _new_sandbox
    mkdir -p "$CSK/New Skill"
    printf 'mine\n' > "$CSK/New Skill/SKILL.md"
    printf 'keep\n' > "$CSK/New Skill/notes.txt"
    before="$(_snapshot "$CSK/New Skill")"
    _run
    after="$(_snapshot "$CSK/New Skill")"
    if [ -d "$CSK/New Skill" ] && [ ! -L "$CSK/New Skill" ] && [ "$before" = "$after" ] \
       && grep -q "^print_warning .*New Skill" "$_LOG"; then
        test_pass
    else
        test_fail "user dir changed or no warning (log: $(tr '\n' ' ' < "$_LOG"))"
    fi
fi

# ─── T4: a dangling link we own is pruned ────────────────────────────────────
test_start "T4: dangling link into the aiteamforge skills dir is pruned"
if ! _skip_if_missing; then
    _new_sandbox
    mkdir -p "$CSK"
    ln -s "$WORKING_DIR/skills/Removed Skill" "$CSK/Removed Skill"
    if [ ! -L "$CSK/Removed Skill" ] || [ -e "$CSK/Removed Skill" ]; then
        test_fail "precondition: fixture link is not dangling"
    else
        _run
        if [ ! -L "$CSK/Removed Skill" ] && [ ! -e "$CSK/Removed Skill" ]; then
            test_pass
        else
            test_fail "dangling owned link still present"
        fi
    fi
fi

# ─── T5: links pointing elsewhere are untouched ──────────────────────────────
test_start "T5: foreign links (dangling and live) untouched; collision warned"
if ! _skip_if_missing; then
    _new_sandbox
    mkdir -p "$CSK" "$SBX/elsewhere/plain-skill"
    ln -s "$SBX/nowhere/ghost" "$CSK/ghost"                      # foreign, dangling
    ln -s "$SBX/elsewhere/plain-skill" "$CSK/plain-skill"        # foreign, live, collides
    _run
    if [ -L "$CSK/ghost" ] && [ "$(readlink "$CSK/ghost")" = "$SBX/nowhere/ghost" ] \
       && [ -L "$CSK/plain-skill" ] && [ "$(readlink "$CSK/plain-skill")" = "$SBX/elsewhere/plain-skill" ] \
       && grep -q "^print_warning .*plain-skill" "$_LOG"; then
        test_pass
    else
        test_fail "foreign link changed or no collision warning ($(ls -l "$CSK" | tr '\n' ' '))"
    fi
fi

# ─── T6: DRY_RUN writes nothing ──────────────────────────────────────────────
test_start "T6: DRY_RUN changes nothing under ~/.claude or the working dir"
if ! _skip_if_missing; then
    _new_sandbox
    mkdir -p "$CSK" "$CSK/User Dir"
    # DRY_RUN skips the rsync, so seed the working dir as an earlier upgrade
    # left it: skill present in ~/aiteamforge/skills, never linked (the
    # measured field shape).
    cp -R "$FRAMEWORK_DIR/share/skills/New Skill" "$WORKING_DIR/skills/"
    ln -s "$WORKING_DIR/skills/Old Skill" "$CSK/Old Skill"
    ln -s "$WORKING_DIR/skills/Removed Skill" "$CSK/Removed Skill"
    before="$(_snapshot "$HOME")"
    DRY_RUN=true
    _run
    after="$(_snapshot "$HOME")"
    if [ "$before" = "$after" ] && grep -q "Would link skill: New Skill" "$SBX/stdout.log" \
       && grep -q "Would remove dangling skill link: Removed Skill" "$SBX/stdout.log"; then
        test_pass
    else
        test_fail "tree changed under DRY_RUN or preview missing: $(diff <(echo "$before") <(echo "$after") | tr '\n' ' ') / $(tr '\n' ' ' < "$SBX/stdout.log")"
    fi
fi

# ─── T6b: DRY_RUN with no ~/.claude/skills does not create it ────────────────
test_start "T6b: DRY_RUN does not create a missing ~/.claude/skills"
if ! _skip_if_missing; then
    _new_sandbox
    DRY_RUN=true
    _run
    if [ ! -e "$CSK" ]; then test_pass; else test_fail "$CSK created under DRY_RUN"; fi
fi

# ─── T7: symlinked working skills dir ────────────────────────────────────────
test_start "T7: symlinked ~/aiteamforge/skills still links new skills"
if ! _skip_if_missing; then
    _new_sandbox symlinked
    mkdir -p "$CSK"
    _run
    if [ -L "$CSK/New Skill" ] && [ -f "$CSK/New Skill/SKILL.md" ] && [ -L "$WORKING_DIR/skills" ]; then
        test_pass
    else
        test_fail "New Skill not linked in symlinked mode ($(ls -l "$CSK" 2>&1 | tr '\n' ' '))"
    fi
fi

# ─── T8: missing ~/.claude/skills is created ─────────────────────────────────
test_start "T8: missing ~/.claude/skills is created and populated"
if ! _skip_if_missing; then
    _new_sandbox
    _run
    if [ -d "$CSK" ] && [ -L "$CSK/Old Skill" ] && [ -L "$CSK/New Skill" ] && [ -L "$CSK/plain-skill" ]; then
        test_pass
    else
        test_fail "skills dir not created/populated ($(ls -l "$CSK" 2>&1 | tr '\n' ' '))"
    fi
fi

# ─── T8b: idempotent — a second run changes nothing ──────────────────────────
test_start "T8b: second run is a no-op"
if ! _skip_if_missing; then
    _new_sandbox
    _run
    first="$(_snapshot "$HOME")"
    _run
    second="$(_snapshot "$HOME")"
    if [ -n "$first" ] && [ "$first" = "$second" ] && [ -L "$CSK/New Skill" ]; then
        test_pass
    else
        test_fail "second run changed the tree or first run linked nothing"
    fi
fi

# ─── T9: structural — update_skills is called in the run sequence ────────────
test_start "T9: update_skills is called in the upgrade run sequence"
if grep -qE '^update_skills[[:space:]]*$' "$UPGRADE_SH"; then
    test_pass
else
    test_fail "no top-level 'update_skills' call in $UPGRADE_SH"
fi

# ─── T9b: structural — update_skills reaches the linking step ────────────────
test_start "T9b: update_skills links into the Claude config dir"
if [ "$FN_MISSING" = false ] && printf '%s\n' "$_COMBINED_SRC" | sed -E '/^[[:space:]]*#/d' | grep -q 'ln -s "\$skill_dir"'; then
    test_pass
else
    test_fail "update_skills (and its helpers) never create a per-skill link"
fi

if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "  Passed: $_PASS_COUNT  Failed: $_FAIL_COUNT"
    [ "$_FAIL_COUNT" -eq 0 ] || exit 1
fi
