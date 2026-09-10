#!/bin/bash

# test-xaca-0787-012-claude-config-flag-guard.sh
#
# Regression tests for XACA-0787-012.
#
# DEFECT (call site, tests/test-installers.sh): the "Claude config installer
# handles missing ~/.claude/" test ran the REAL install-claude-config.sh
# against the REAL $HOME — `bash "$INSTALLERS_DIR/install-claude-config.sh"
# --help`, with neither HOME nor CLAUDE_CONFIG_DIR overridden — and asserted
# only `assert_not_empty "$output"`, with a fallback to `grep -c "claude"`
# over the script's own source when output was empty. That assertion passes
# whether or not --help does anything at all: a test that cannot fail.
#
# DEFECT (callee, libexec/installers/install-claude-config.sh): the script
# had NO flag parsing whatsoever. `install_claude_config()` takes
# `local selected_teams=("$@")`, a vestige from before XACA-0285 (per-team
# agent dirs are no longer written by this function — see its own comment);
# the entry point at the bottom of the file was a bare
# `if [[ "$1" == "--restore" ]]; then restore_claude_config ...; else
# install_claude_config "$@"; fi`. An unrecognised flag — --help included —
# fell straight through to the ELSE branch and ran a FULL install: creates
# CLAUDE_CONFIG_DIR, writes CLAUDE.md/settings.json/hooks/skills, and calls
# invoke_persona_sync. Verified live during this ticket: a scratch copy of
# the pre-fix entry point, run with --help against a sandboxed $HOME, wrote
# real files under $CLAUDE_CONFIG_DIR/hooks/ — same class as the standing
# "AITeamForge must NEVER be installed on M3Pro" rule exists to prevent, and
# the same recurrence class as XACA-0787-003/XACA-0787-005 (sandbox
# AITEAMFORGE_DIR but not HOME).
#
# Fix:
#   - install-claude-config.sh gained a real usage()/flag parser at its
#     entry point: -h/--help prints usage and exits 0 WITHOUT installing;
#     --restore is unchanged; an unrecognised `-`-prefixed flag prints an
#     error and exits 1 WITHOUT installing; anything else (no leading "-")
#     is treated as a positional TEAM arg and passed through via "$@"
#     unchanged (kept for call-site compatibility — no current caller uses
#     it; see grep evidence in the ticket).
#   - Deliberately NOT collected into a bash array first: an empty array
#     reference under `set -u` throws "unbound variable" on bash < 4.4, and
#     macOS ships bash 3.2 as /bin/bash — exactly the class of trap recorded
#     in knowledge "verify under /bin/bash 3.2, not PATH bash 5.x"
#     (XACA-0845). The production call site (aiteamforge-setup.sh) always
#     invokes with zero args, so this path must not regress under bash 3.2.
#   - tests/test-installers.sh's existing probe is now sandboxed (HOME,
#     AITEAMFORGE_DIR, CLAUDE_CONFIG_DIR, AITEAMFORGE_SKIP_LAUNCHCTL,
#     AITF_LAUNCHAGENT_OPTOUT_FILE — via a shared run_installer_sandboxed
#     helper reused for its two sibling probes at the same unsandboxed
#     call-site shape: install-fleet-monitor.sh and install-team.sh) and its
#     assertion strengthened to require real usage text AND the absence of
#     full-install markers.
#
# THIS FILE covers what test-installers.sh's tightened probe does not:
#   T1  HELP-EXIT-CODE: -h/--help exits 0.
#   T2  HELP-PRINTS-USAGE: --help output names "Usage:" and "--restore".
#   T3  HELP-NO-INSTALL: --help does NOT create CLAUDE_CONFIG_DIR or any
#       file under it (the actual regression — a non-vacuous, filesystem-
#       level assertion, not just an output-text check).
#   T4  UNKNOWN-FLAG-EXIT-CODE: an unrecognised flag exits non-zero.
#   T5  UNKNOWN-FLAG-NO-INSTALL: an unrecognised flag does NOT create
#       CLAUDE_CONFIG_DIR or any file under it.
#   T6  UNKNOWN-FLAG-STDERR: an unrecognised flag's error message names the
#       bad flag (so a real typo is diagnosable, not just silently eaten).
#   T7  RESTORE-STILL-WORKS: --restore with no matching backup still exits
#       non-zero with the pre-existing "Backup not found" message (proves
#       the refactor did not regress the one flag that already worked).
#   T8  SHORT-HELP-FLAG: -h behaves the same as --help (usage, exit 0, no
#       install).
#
# All filesystem activity is sandboxed under a throwaway $HOME created via
# mktemp — NEVER touches the real $HOME/.claude or ~/aiteamforge. Installer-
# test safety rule (this ticket's own subject matter). CLAUDE_CONFIG_DIR is
# also overridden explicitly (belt-and-suspenders on top of HOME) and
# AITEAMFORGE_SKIP_LAUNCHCTL / AITF_LAUNCHAGENT_OPTOUT_FILE are set even
# though this installer does not touch launchd today, for parity with the
# sandboxing convention used by the sibling installer probes.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLAUDE_INSTALLER="$TAP_ROOT/libexec/installers/install-claude-config.sh"

if [ ! -f "$CLAUDE_INSTALLER" ]; then
    echo "FATAL: required file not found: $CLAUDE_INSTALLER" >&2
    exit 1
fi

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
# Temp directory (runner-supplied or our own). Doubles as the sandboxed HOME
# for every installer invocation below — a fresh subdir per invocation so
# T3/T5's "nothing was created" checks can't be confused by a sibling test's
# artifacts.
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca0787012-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
cleanup() { if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then rm -rf "$TEST_TMP_DIR"; fi; }
trap cleanup EXIT

WORK_DIR="$TEST_TMP_DIR/xaca0787012"
mkdir -p "$WORK_DIR"

# Run install-claude-config.sh in a fresh, isolated sandbox HOME.
# Usage: _run_sandboxed <sandbox-dir> [args...]
# Prints combined stdout+stderr; returns the installer's real exit code
# (unlike test-installers.sh's probe helper, callers here need the exit
# code itself for T1/T4/T7).
_run_sandboxed() {
    local _sb="$1"; shift
    mkdir -p "$_sb"
    (
        HOME="$_sb" \
        AITEAMFORGE_DIR="$_sb/aiteamforge" \
        AITEAMFORGE_SKIP_LAUNCHCTL=1 \
        CLAUDE_CONFIG_DIR="$_sb/.claude" \
        AITF_LAUNCHAGENT_OPTOUT_FILE="$_sb/.aiteamforge/launchagents.optout" \
        bash "$CLAUDE_INSTALLER" "$@"
    ) 2>&1
}

# ─────────────────────────────────────────────────────────────────────────────
# T1 / T2 / T3 — --help
# ─────────────────────────────────────────────────────────────────────────────
SB1="$WORK_DIR/sb-help"
OUTPUT1=$(_run_sandboxed "$SB1" --help)
RC1=$?

test_start "T1 HELP-EXIT-CODE: --help exits 0"
if [ "$RC1" -eq 0 ]; then
    test_pass
else
    test_fail "Expected exit 0, got $RC1. Output: $OUTPUT1"
fi

test_start "T2 HELP-PRINTS-USAGE: --help output names Usage: and --restore"
if [[ "$OUTPUT1" == *"Usage: install-claude-config.sh"* ]] && [[ "$OUTPUT1" == *"--restore"* ]]; then
    test_pass
else
    test_fail "Expected usage text mentioning --restore, got: $OUTPUT1"
fi

test_start "T3 HELP-NO-INSTALL: --help does not create CLAUDE_CONFIG_DIR"
if [ ! -e "$SB1/.claude" ]; then
    test_pass
else
    test_fail "Expected $SB1/.claude to not exist after --help; contents: $(find "$SB1/.claude" 2>&1)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# T4 / T5 / T6 — unrecognized flag
# ─────────────────────────────────────────────────────────────────────────────
SB2="$WORK_DIR/sb-badflag"
OUTPUT2=$(_run_sandboxed "$SB2" --this-flag-does-not-exist)
RC2=$?

test_start "T4 UNKNOWN-FLAG-EXIT-CODE: unrecognized flag exits non-zero"
if [ "$RC2" -ne 0 ]; then
    test_pass
else
    test_fail "Expected non-zero exit, got 0. Output: $OUTPUT2"
fi

test_start "T5 UNKNOWN-FLAG-NO-INSTALL: unrecognized flag does not create CLAUDE_CONFIG_DIR"
if [ ! -e "$SB2/.claude" ]; then
    test_pass
else
    test_fail "Expected $SB2/.claude to not exist after a bad flag; contents: $(find "$SB2/.claude" 2>&1)"
fi

test_start "T6 UNKNOWN-FLAG-STDERR: error message names the offending flag"
if [[ "$OUTPUT2" == *"--this-flag-does-not-exist"* ]]; then
    test_pass
else
    test_fail "Expected the bad flag to be named in the output, got: $OUTPUT2"
fi

# ─────────────────────────────────────────────────────────────────────────────
# T7 — --restore still works (no regression on the flag that already worked)
# ─────────────────────────────────────────────────────────────────────────────
SB3="$WORK_DIR/sb-restore"
OUTPUT3=$(_run_sandboxed "$SB3" --restore 19700101-000000)
RC3=$?

test_start "T7 RESTORE-STILL-WORKS: --restore with a missing backup exits non-zero and reports it"
if [ "$RC3" -ne 0 ] && [[ "$OUTPUT3" == *"Backup not found"* ]]; then
    test_pass
else
    test_fail "Expected non-zero exit + 'Backup not found', got rc=$RC3 output: $OUTPUT3"
fi

# ─────────────────────────────────────────────────────────────────────────────
# T8 — -h short form
# ─────────────────────────────────────────────────────────────────────────────
SB4="$WORK_DIR/sb-shorthelp"
OUTPUT4=$(_run_sandboxed "$SB4" -h)
RC4=$?

test_start "T8 SHORT-HELP-FLAG: -h behaves like --help (exit 0, usage text, no install)"
if [ "$RC4" -eq 0 ] && [[ "$OUTPUT4" == *"Usage: install-claude-config.sh"* ]] && [ ! -e "$SB4/.claude" ]; then
    test_pass
else
    test_fail "Expected exit 0 + usage text + no install for -h, got rc=$RC4 output: $OUTPUT4"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Standalone summary
# ─────────────────────────────────────────────────────────────────────────────
if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "Results: $_PASS_COUNT passed, $_FAIL_COUNT failed"
    [ "$_FAIL_COUNT" -eq 0 ]
fi
