#!/bin/bash
# test-xaca-1159-global-claude-md-upgrade-registration.sh
#
# XACA-1159-017: structural anti-regression guard, same idiom as
# test-knowledge-sync-upgrade-registration.sh (XACA-0761) and
# test-xaca-0771-upgrade-materialize-missing.sh.
#
# install_global_claude_md() (libexec/installers/install-claude-config.sh)
# renders ~/.claude/CLAUDE.md from share/templates/claude/claude-md-global.template,
# but its ONLY call site was install_claude_config() — reached on a FRESH
# `aiteamforge setup`, NEVER on `aiteamforge upgrade`. Without a SEPARATE
# upgrade-side call, an already-installed fleet machine could ship a
# corrected template (e.g. the fail-open-merge-gate fix this same ticket
# makes to the template's content) and NEVER receive it — the exact defect
# class XACA-0751/XACA-0761/XACA-0771/XACA-0925 already fixed for
# ~/knowledge, the knowledge-sync LaunchAgent, ~/.claude/hooks, and team
# personas respectively. "Testing that a function works is a DIFFERENT
# ASSERTION from testing that it is invoked" — the entire bug class here is
# a correct function that nothing calls, so this suite asserts INVOCATION,
# not (only) correctness. Functional correctness of the render-receipt
# overwrite guard itself is exercised separately (sandbox tests run by hand
# during XACA-1159-016; see the plan doc / retro for that evidence).
#
# This suite additionally guards the WRONG fix for this ticket: naively
# reusing install_global_claude_md() verbatim (the idiom every precedent
# ticket above uses) is actively destructive here, because unlike hooks/
# personas/knowledge-repo, ~/.claude/CLAUDE.md is user-facing prose the
# template itself invites hand-editing of. install_global_claude_md() always
# overwrites (after a backup, but unconditionally) — calling it from upgrade
# would silently clobber a customized CLAUDE.md on every unattended nightly
# auto-upgrade. The fix must route through the GUARDED helper
# (_xaca1159_refresh_global_claude_md), never the raw install function.
#
# Checks (source-text / structural only — no functional rendering here):
#   T1  update_global_claude_md() is defined in aiteamforge-upgrade.sh
#   T2  update_global_claude_md is CALLED (bare line) in the run sequence —
#       the assertion that would have caught the original bug: a defined-but-
#       never-called function
#   T3  update_global_claude_md is called AFTER update_claude_hooks (its
#       nearest sibling in the run sequence; both refresh ~/.claude/* content
#       via the same subshell-isolated reuse-the-installer idiom)
#   T4  update_global_claude_md REUSES _xaca1159_refresh_global_claude_md
#       (sources install-claude-config.sh + calls the GUARDED helper)
#   T5  update_global_claude_md does NOT call the raw, unconditional
#       install_global_claude_md() — that function has no overwrite guard and
#       would clobber a user-customized CLAUDE.md on every upgrade
#   T6  install-claude-config.sh defines all three XACA-1159 guard-support
#       functions this ticket introduces: _xaca1159_write_claude_md_receipt,
#       _xaca1159_bootstrap_claude_md_provenance,
#       _xaca1159_refresh_global_claude_md
#   T7  install_global_claude_md() itself now WRITES the receipt (calls
#       _xaca1159_write_claude_md_receipt) — required so the upgrade-side
#       check has something to compare against starting with the very next
#       fresh install, not just already-installed boxes via the bootstrap
#   T8  the shipped historical-render corpus that
#       _xaca1159_bootstrap_claude_md_provenance depends on actually exists on
#       disk (share/templates/claude/historical/*.template) — a structural
#       guard is worthless if its data dependency silently went missing
#
# Pure source-text assertions against the real files — no sourcing, no
# sandboxed execution, no $HOME mutation. Safe under TEST_TMP_DIR (declared
# for house-style consistency; unused since this suite does no filesystem
# writes of its own beyond its own scratch extraction files).
#
# Runs standalone (`bash tests/test-xaca-1159-global-claude-md-upgrade-registration.sh`)
# OR via test-runner.sh. Exit 0 = all pass (and at least one assertion ran),
# exit 1 = any fail OR zero assertions executed (vacuous-green guard).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UPGRADE_SH="$TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh"
INSTALLER="$TAP_ROOT/libexec/installers/install-claude-config.sh"
HISTORICAL_DIR="$TAP_ROOT/share/templates/claude/historical"

for _need in "$UPGRADE_SH" "$INSTALLER"; do
    if [ ! -f "$_need" ]; then
        echo "FATAL: required file not found: $_need" >&2
        exit 1
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework: no-op-compatible stubs when test-runner.sh has not
# exported the real harness (mirrors test-xaca-0761 / test-xaca-0751 pattern).
# ─────────────────────────────────────────────────────────────────────────────
if ! type -t test_start >/dev/null 2>&1; then
    _PASS_COUNT=0
    _FAIL_COUNT=0
    _CURRENT_TEST=""
    test_start() { _CURRENT_TEST="$1"; echo "  >> $1"; }
    test_pass()  { _PASS_COUNT=$((_PASS_COUNT + 1)); echo "     PASS: $_CURRENT_TEST"; }
    test_fail()  { _FAIL_COUNT=$((_FAIL_COUNT + 1)); echo "     FAIL: $_CURRENT_TEST — $1" >&2; }
fi

# TEST_TMP_DIR-safe: use the runner-supplied dir if present, else our own.
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca1159-claude-md-upgrade.XXXXXX)"
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

# ═══════════════════════════════════════════════════════════════════════════
# T1 — update_global_claude_md() is defined
# ═══════════════════════════════════════════════════════════════════════════
test_start "T1: update_global_claude_md() is defined in aiteamforge-upgrade.sh"
if grep -qE '^update_global_claude_md\(\) \{' "$UPGRADE_SH"; then
    test_pass
else
    test_fail "no 'update_global_claude_md() {' definition found in $UPGRADE_SH"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T2 — STRUCTURAL: update_global_claude_md is CALLED in the run sequence.
# This is the assertion that would have caught the XACA-1159-class bug: the
# function may exist but must be INVOKED as a bare call near the bottom of
# the file, not merely defined.
# ═══════════════════════════════════════════════════════════════════════════
test_start "T2: update_global_claude_md is invoked (bare call) in the upgrade run sequence"
if grep -qE '^update_global_claude_md$' "$UPGRADE_SH"; then
    test_pass
else
    test_fail "aiteamforge-upgrade.sh run sequence must call update_global_claude_md (bare line) — a defined-but-never-called function means EXISTING fleet machines never receive a corrected global CLAUDE.md on upgrade (XACA-1159 lesson)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T3 — update_global_claude_md's bare call appears AFTER update_claude_hooks'.
# Not a hard ordering dependency, but they are documented siblings (same
# subshell-isolated reuse-the-installer idiom, same ~/.claude/* neighborhood)
# and were wired in that order — a regression that reorders them ahead of
# update_claude_hooks is worth a signal even though nothing would break.
# ═══════════════════════════════════════════════════════════════════════════
test_start "T3: update_global_claude_md call is ordered AFTER update_claude_hooks call"
_HOOKS_LINE=$(grep -nE '^update_claude_hooks$' "$UPGRADE_SH" | head -1 | cut -d: -f1)
_MD_LINE=$(grep -nE '^update_global_claude_md$' "$UPGRADE_SH" | head -1 | cut -d: -f1)
if [ -n "$_HOOKS_LINE" ] && [ -n "$_MD_LINE" ] && [ "$_MD_LINE" -gt "$_HOOKS_LINE" ]; then
    test_pass
else
    test_fail "expected update_global_claude_md (line ${_MD_LINE:-MISSING}) to be called after update_claude_hooks (line ${_HOOKS_LINE:-MISSING})"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T4 — update_global_claude_md REUSES _xaca1159_refresh_global_claude_md
# (sources install-claude-config.sh + calls the GUARDED helper), same idiom
# as update_claude_hooks reusing install_hooks.
# ═══════════════════════════════════════════════════════════════════════════
UPD_FN_SRC="$TEST_TMP_DIR/update_global_claude_md.extracted.sh"
awk '
  /^update_global_claude_md\(\) \{/ { capture=1 }
  capture { print }
  capture && /^}$/ { exit }
' "$UPGRADE_SH" > "$UPD_FN_SRC"

test_start "T4: update_global_claude_md reuses _xaca1159_refresh_global_claude_md (no reimplementation)"
if [ -s "$UPD_FN_SRC" ] \
    && grep -q "install-claude-config.sh" "$UPD_FN_SRC" \
    && grep -qE '(^|[^_])_xaca1159_refresh_global_claude_md\b' "$UPD_FN_SRC"; then
    test_pass
else
    test_fail "extracted update_global_claude_md must source install-claude-config.sh AND call _xaca1159_refresh_global_claude_md"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T5 — update_global_claude_md must NOT call the raw, unguarded
# install_global_claude_md() — that function always overwrites unconditionally
# (after a backup) and has no way to tell a customized file from a stale one.
# Calling it from upgrade would be the exact destructive wrong-fix this
# ticket's overwrite-guard design (XACA-1159-016) exists to prevent.
# ═══════════════════════════════════════════════════════════════════════════
test_start "T5: update_global_claude_md does NOT call the raw install_global_claude_md()"
if [ -s "$UPD_FN_SRC" ] && ! grep -qE '(^|[^_])install_global_claude_md\b' "$UPD_FN_SRC"; then
    test_pass
else
    test_fail "update_global_claude_md must never call install_global_claude_md() directly — it has no overwrite guard and would clobber a user-customized CLAUDE.md on every upgrade run"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T6 — install-claude-config.sh defines all three XACA-1159 guard-support
# functions.
# ═══════════════════════════════════════════════════════════════════════════
test_start "T6: install-claude-config.sh defines the XACA-1159 guard-support functions"
_missing_fn=""
for _fn in _xaca1159_write_claude_md_receipt _xaca1159_bootstrap_claude_md_provenance _xaca1159_refresh_global_claude_md; do
    grep -qE "^${_fn}\(\) \{" "$INSTALLER" || _missing_fn="${_missing_fn} ${_fn}"
done
if [ -z "$_missing_fn" ]; then
    test_pass
else
    test_fail "install-claude-config.sh is missing definition(s) for:${_missing_fn}"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T7 — install_global_claude_md() itself now WRITES the receipt. Required so
# the upgrade-side check has a receipt to compare against starting with the
# very next fresh install — not just a bootstrap fallback for boxes that
# predate this mechanism.
# ═══════════════════════════════════════════════════════════════════════════
test_start "T7: install_global_claude_md() writes the render receipt"
INSTALL_FN_SRC="$TEST_TMP_DIR/install_global_claude_md.extracted.sh"
awk '
  /^install_global_claude_md\(\) \{/ { capture=1 }
  capture { print }
  capture && /^}$/ { exit }
' "$INSTALLER" > "$INSTALL_FN_SRC"
if [ -s "$INSTALL_FN_SRC" ] && grep -qE '(^|[^_])_xaca1159_write_claude_md_receipt\b' "$INSTALL_FN_SRC"; then
    test_pass
else
    test_fail "install_global_claude_md() must call _xaca1159_write_claude_md_receipt after rendering, or a fresh install never gets a receipt for upgrade to compare against"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T8 — the historical-render corpus the bootstrap function depends on
# actually ships. A structural "is it wired up" guard is worthless if its
# runtime data dependency silently goes missing (e.g. a future `find
# share/templates -name '*.template'` sweep that doesn't know to leave
# historical/ alone).
# ═══════════════════════════════════════════════════════════════════════════
test_start "T8: share/templates/claude/historical/ ships at least one historical template variant"
if [ -d "$HISTORICAL_DIR" ] && [ -n "$(find "$HISTORICAL_DIR" -maxdepth 1 -name '*.template' -type f 2>/dev/null)" ]; then
    test_pass
else
    test_fail "expected one or more *.template files under $HISTORICAL_DIR"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Standalone summary + exit code (no-op under test-runner.sh, which owns
# totals). VACUOUS-GREEN GUARD: a suite that ran zero assertions must never
# report success just because nothing failed — count executed assertions and
# require the count be non-zero.
# ═══════════════════════════════════════════════════════════════════════════
if [ -n "${_PASS_COUNT+x}" ]; then
    _TOTAL=$((_PASS_COUNT + _FAIL_COUNT))
    echo ""
    echo "XACA-1159 global-claude-md-upgrade-registration tests: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed (${_TOTAL} assertions executed)"
    if [ "$_TOTAL" -eq 0 ]; then
        echo "FATAL: zero assertions executed — this is a vacuous pass, not a real result" >&2
        exit 1
    fi
    [ "${_FAIL_COUNT:-0}" -eq 0 ] || exit 1
fi
exit 0
