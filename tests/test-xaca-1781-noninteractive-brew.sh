#!/bin/bash

# test-xaca-1781-noninteractive-brew.sh
# XACA-1781 -- `aiteamforge upgrade --non-interactive` must not blindly trust that
# the caller ran `brew upgrade`, and the failure box must name the REAL reason
# instead of always blaming an untrusted tap.
#
# CONTRACT (libexec/commands/aiteamforge-upgrade.sh):
#   --non-interactive + AITEAMFORGE_BREW_UPGRADE_DONE=1  -> skip brew, re-probe
#       `brew outdated`; still outdated => Reason: caller-upgrade-did-not-advance
#   --non-interactive + marker absent / any other value  -> run `brew upgrade
#       aiteamforge` ourselves with the pre/post installed-version check
#   Reasons: tap-refused | caller-upgrade-did-not-advance |
#            brew-upgrade-did-not-advance | brew-upgrade-exit-nonzero
#   Failure box: `UPGRADE FAILED`, `STILL on the OLD version`, exit 1, one
#   `Reason: <code>` line; UNTRUSTED / `brew trust` ONLY for tap-refused.
#
# Table-driven: every case gets a fresh shim state. `brew` is mocked via a PATH
# shim only (same approach as test-xaca-0704-negative.sh); the real tap/brew is
# never touched. upgrade.sh runs as a subprocess with stdin from /dev/null.
#
# Anti-vacuity: every case asserts non-empty output and the exact upgrade-call
# count recorded by the shim, and the suite asserts an assertion-count floor.
# Case d2 uses a "stale first probe" shim so that a mutant which ignores the
# marker is observable (a plain empty `brew outdated` never reaches the
# brew-upgrade code path at all and would be vacuous -- see d1 vs d2).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UPGRADE_SH="$TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh"

_STANDALONE=false
if ! type -t test_start >/dev/null 2>&1; then
    _STANDALONE=true
    _PASS_COUNT=0
    _FAIL_COUNT=0
    _CURRENT_TEST=""
    test_start() { _CURRENT_TEST="$1"; echo "  >> $1"; }
    test_pass()  { _PASS_COUNT=$((_PASS_COUNT + 1)); echo "     PASS: $_CURRENT_TEST"; }
    test_fail()  { _FAIL_COUNT=$((_FAIL_COUNT + 1)); echo "     FAIL: $_CURRENT_TEST -- $1" >&2; }
fi
# Local assertion helpers (prefixed so they never collide with test-runner.sh's).
_ASSERTIONS=0
_x_eq()    { _ASSERTIONS=$((_ASSERTIONS + 1)); [ "$1" = "$2" ] || { test_fail "${3:-expected '$1' got '$2'}"; return 1; }; }
_x_has()   { _ASSERTIONS=$((_ASSERTIONS + 1)); [[ "$1" == *"$2"* ]] || { test_fail "${3:-expected to find '$2'}"; return 1; }; }
_x_hasnt() { _ASSERTIONS=$((_ASSERTIONS + 1)); [[ "$1" != *"$2"* ]] || { test_fail "${3:-expected NOT to find '$2'}"; return 1; }; }
_x_nonempty() { _ASSERTIONS=$((_ASSERTIONS + 1)); [ -n "$1" ] || { test_fail "${2:-expected non-empty}"; return 1; }; }

if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca1781.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
cleanup() {
    if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then
        rm -rf "$TEST_TMP_DIR"
    fi
}
trap cleanup EXIT

if [ ! -f "$UPGRADE_SH" ]; then
    echo "FATAL: upgrade.sh not found at $UPGRADE_SH" >&2
    exit 1
fi

# -- Sandbox ----------------------------------------------------------------
_AITEAMFORGE_DIR="$TEST_TMP_DIR/aiteamforge"
_AITEAMFORGE_HOME="$TEST_TMP_DIR/framework"       # empty => update_* sweeps bail early
_TEST_HOME="$TEST_TMP_DIR/home"                    # keeps LaunchAgent plists off the real HOME
mkdir -p "$_AITEAMFORGE_DIR" "$_AITEAMFORGE_HOME" "$_TEST_HOME/Library/LaunchAgents"
touch "$_AITEAMFORGE_DIR/.aiteamforge-config"

# -- Mock brew --------------------------------------------------------------
_MOCK_BIN="$TEST_TMP_DIR/mock-bin"
mkdir -p "$_MOCK_BIN"
BREW_CALL_LOG="$TEST_TMP_DIR/brew-calls.log"
S_LIST="$TEST_TMP_DIR/brew-list-output"
S_VER="$TEST_TMP_DIR/brew-list-versions-file"
S_VER_POST="$TEST_TMP_DIR/brew-list-versions-post"
S_OUTDATED="$TEST_TMP_DIR/brew-outdated-output"
S_OUTDATED_ONCE="$TEST_TMP_DIR/brew-outdated-once"      # present => only the FIRST probe reports outdated
S_OUTDATED_SEEN="$TEST_TMP_DIR/brew-outdated-seen"
S_UPG_EXIT="$TEST_TMP_DIR/brew-upgrade-exit"
S_UPG_DONE="$TEST_TMP_DIR/brew-upgrade-done"
S_UNTRUSTED="$TEST_TMP_DIR/brew-info-untrusted"

# shellcheck disable=SC2016
cat > "$_MOCK_BIN/brew" <<'MOCK_EOF'
#!/bin/bash
[ -n "${BREW_CALL_LOG:-}" ] && printf '%s\n' "$*" >> "$BREW_CALL_LOG"
case "$1 $2" in
    "list aiteamforge")
        [ -f "${S_LIST:-}" ] && cat "$S_LIST"
        exit 0 ;;
    "list --versions")
        if [ -f "${S_UPG_DONE:-}" ] && [ -f "${S_VER_POST:-}" ]; then
            cat "$S_VER_POST"
        elif [ -f "${S_VER:-}" ]; then
            cat "$S_VER"
        fi
        exit 0 ;;
    "outdated aiteamforge")
        if [ -f "${S_OUTDATED_ONCE:-}" ]; then
            # Stale-first-probe mode: report outdated once, then up to date.
            if [ ! -f "${S_OUTDATED_SEEN:-}" ]; then
                touch "$S_OUTDATED_SEEN"
                [ -f "${S_OUTDATED:-}" ] && cat "$S_OUTDATED"
            fi
        elif [ -f "${S_OUTDATED:-}" ]; then
            cat "$S_OUTDATED"
        fi
        exit 0 ;;
    "upgrade aiteamforge")
        [ -n "${S_UPG_DONE:-}" ] && touch "$S_UPG_DONE"
        exit "$(cat "${S_UPG_EXIT:-}" 2>/dev/null || echo 0)" ;;
    "info aiteamforge"*)
        if [ -f "${S_UNTRUSTED:-}" ]; then
            # Exits NON-ZERO like a real refusing brew. Before the XACA-1781 fix,
            # tap_load_refused() was `brew info | grep -q` under the caller's
            # `set -o pipefail`, so this exit turned the pipeline red and the
            # refusal was reported as "not refused" — cases f/f2 pin that fix.
            echo "Error: Refusing to load formula aiteamforge from untrusted tap doublenode/aiteamforge"
            exit 1
        fi
        echo '[{"versions":{"stable":"0.15.0"}}]'
        exit 0 ;;
    "trust --tap"*) exit 0 ;;
    "--prefix"*) echo "/opt/homebrew"; exit 0 ;;
    *) exit 0 ;;
esac
MOCK_EOF
chmod +x "$_MOCK_BIN/brew"

_reset_shim() {
    : > "$BREW_CALL_LOG"
    rm -f "$S_LIST" "$S_VER" "$S_VER_POST" "$S_OUTDATED" "$S_OUTDATED_ONCE" \
          "$S_OUTDATED_SEEN" "$S_UPG_EXIT" "$S_UPG_DONE" "$S_UNTRUSTED" \
          "$_AITEAMFORGE_DIR/.installed-version"
}

# Scenario setup (all start from a fresh shim; formula installed at 0.14.0).
_scenario() {
    _reset_shim
    echo "aiteamforge"        > "$S_LIST"
    echo "aiteamforge 0.14.0" > "$S_VER"
    case "$1" in
        advance)         # outdated; our brew upgrade exits 0 and the version flips
            echo aiteamforge > "$S_OUTDATED"; echo 0 > "$S_UPG_EXIT"
            echo "aiteamforge 0.15.0" > "$S_VER_POST" ;;
        noadvance_zero)  # outdated; upgrade exits 0 but version never moves
            echo aiteamforge > "$S_OUTDATED"; echo 0 > "$S_UPG_EXIT" ;;
        noadvance_fail)  # outdated; upgrade exits non-zero, version never moves
            echo aiteamforge > "$S_OUTDATED"; echo 1 > "$S_UPG_EXIT" ;;
        current)         # brew outdated empty
            : > "$S_OUTDATED"; echo 0 > "$S_UPG_EXIT" ;;
        stale_probe)     # first probe says outdated (stale), re-probe says current
            echo aiteamforge > "$S_OUTDATED"; touch "$S_OUTDATED_ONCE"; echo 0 > "$S_UPG_EXIT" ;;
        still_outdated)  # outdated, stays outdated
            echo aiteamforge > "$S_OUTDATED"; echo 0 > "$S_UPG_EXIT" ;;
        refused)         # tap refuses to load
            echo aiteamforge > "$S_OUTDATED"; echo 0 > "$S_UPG_EXIT"; touch "$S_UNTRUSTED" ;;
        *) echo "FATAL: unknown scenario $1" >&2; exit 1 ;;
    esac
}

_UPGRADE_OUTPUT_FILE="$TEST_TMP_DIR/upgrade-output.txt"
UPGRADE_OUTPUT=""
UPGRADE_EXIT=0

# _run_upgrade <marker-spec> [upgrade args...]
#   marker-spec: @unset => variable absent; @empty => set to ""; else exported verbatim.
_run_upgrade() {
    local marker="$1"; shift
    local -a marker_env=()
    if [ "$marker" = "@unset" ]; then
        marker_env=(-u AITEAMFORGE_BREW_UPGRADE_DONE)
    elif [ "$marker" = "@empty" ]; then
        marker_env=("AITEAMFORGE_BREW_UPGRADE_DONE=")
    else
        marker_env=("AITEAMFORGE_BREW_UPGRADE_DONE=$marker")
    fi
    UPGRADE_EXIT=0
    : > "$_UPGRADE_OUTPUT_FILE"
    env "${marker_env[@]}" \
        HOME="$_TEST_HOME" \
        AITEAMFORGE_DIR="$_AITEAMFORGE_DIR" \
        AITEAMFORGE_HOME="$_AITEAMFORGE_HOME" \
        WORKING_DIR="$_AITEAMFORGE_DIR" \
        AITEAMFORGE_SKIP_LAUNCHCTL=1 \
        PATH="$_MOCK_BIN:$PATH" \
        BREW_CALL_LOG="$BREW_CALL_LOG" \
        S_LIST="$S_LIST" S_VER="$S_VER" S_VER_POST="$S_VER_POST" \
        S_OUTDATED="$S_OUTDATED" S_OUTDATED_ONCE="$S_OUTDATED_ONCE" \
        S_OUTDATED_SEEN="$S_OUTDATED_SEEN" S_UPG_EXIT="$S_UPG_EXIT" \
        S_UPG_DONE="$S_UPG_DONE" S_UNTRUSTED="$S_UNTRUSTED" \
        bash "$UPGRADE_SH" "$@" < /dev/null > "$_UPGRADE_OUTPUT_FILE" 2>&1
    UPGRADE_EXIT=$?
    UPGRADE_OUTPUT="$(cat "$_UPGRADE_OUTPUT_FILE")"
}

INFO_NOMARK="--non-interactive: no caller marker (AITEAMFORGE_BREW_UPGRADE_DONE); running brew upgrade aiteamforge"
INFO_SKIP="Skipping brew upgrade (--non-interactive; AITEAMFORGE_BREW_UPGRADE_DONE=1: the caller already ran it)"

# Table row (pipe-delimited):
#   id | scenario | args | marker | exit | reason(- = none) | untrusted(0/1) | upgrade-calls | info(nomark|skip|none)
# `reason` of - means success path: no `Reason:` line and no failure box.
CASES='a-nomarker-advances|advance|--non-interactive|@unset|0|-|0|1|nomark
b-nomarker-noadvance-exit0|noadvance_zero|--non-interactive|@unset|1|brew-upgrade-did-not-advance|0|1|nomark
c-nomarker-upgrade-fails|noadvance_fail|--non-interactive|@unset|1|brew-upgrade-exit-nonzero|0|1|nomark
d1-marker-current-box|current|--non-interactive|1|0|-|0|0|none
d2-marker-stale-first-probe|stale_probe|--non-interactive|1|0|-|0|0|skip
e-marker-still-outdated|still_outdated|--non-interactive|1|1|caller-upgrade-did-not-advance|0|0|skip
f-tap-refused|refused|--non-interactive|@unset|1|tap-refused|1|0|none
f2-tap-refused-with-marker|refused|--non-interactive|1|1|tap-refused|1|0|none
g1-marker-true|advance|--non-interactive|true|0|-|0|1|nomark
g2-marker-zero|advance|--non-interactive|0|0|-|0|1|nomark
g3-marker-empty|advance|--non-interactive|@empty|0|-|0|1|nomark
g4-marker-zero-noadvance|noadvance_zero|--non-interactive|0|1|brew-upgrade-did-not-advance|0|1|nomark
h-interactive-noadvance|noadvance_zero||@unset|1|brew-upgrade-did-not-advance|0|1|none
h2-interactive-upgrade-fails|noadvance_fail||@unset|1|brew-upgrade-exit-nonzero|0|1|none
h3-interactive-ignores-marker|noadvance_zero||1|1|brew-upgrade-did-not-advance|0|1|none'

_n_cases=0
while IFS='|' read -r id scen args marker exp_exit exp_reason exp_untrusted exp_calls exp_info; do
    [ -n "$id" ] || continue
    _n_cases=$((_n_cases + 1))
    _scenario "$scen"
    # shellcheck disable=SC2086  # $args is "" or a single flag
    _run_upgrade "$marker" $args
    _calls="$(grep -c '^upgrade aiteamforge' "$BREW_CALL_LOG" 2>/dev/null || true)"
    _calls="${_calls:-0}"

    test_start "[$id] output non-empty (anti-vacuity)"
    _x_nonempty "$UPGRADE_OUTPUT" "no output captured -- subprocess invocation broken" && test_pass

    test_start "[$id] exit code is $exp_exit"
    _x_eq "$exp_exit" "$UPGRADE_EXIT" "exit: expected $exp_exit got $UPGRADE_EXIT" && test_pass

    test_start "[$id] brew upgrade called $exp_calls time(s)"
    _x_eq "$exp_calls" "$_calls" "brew upgrade calls: expected $exp_calls got $_calls" && test_pass

    test_start "[$id] Reason line / failure box"
    if [ "$exp_reason" = "-" ]; then
        _x_hasnt "$UPGRADE_OUTPUT" "Reason:" "success path must not print a Reason: line" && \
        _x_hasnt "$UPGRADE_OUTPUT" "UPGRADE FAILED" "success path must not print the failure box" && \
        _x_has "$UPGRADE_OUTPUT" "upgraded successfully" "success path must print 'upgraded successfully'" && test_pass
    else
        _nreason="$(printf '%s\n' "$UPGRADE_OUTPUT" | grep -c 'Reason: ')"
        _x_has "$UPGRADE_OUTPUT" "Reason: $exp_reason" "missing 'Reason: $exp_reason'" && \
        _x_eq "1" "$_nreason" "expected exactly one 'Reason:' line, got $_nreason" && \
        _x_has "$UPGRADE_OUTPUT" "UPGRADE FAILED" "failure box missing" && \
        _x_has "$UPGRADE_OUTPUT" "STILL on the OLD version" "failure box 'STILL on the OLD version' missing" && \
        _x_hasnt "$UPGRADE_OUTPUT" "upgraded successfully" "failure must not print success" && test_pass
    fi

    test_start "[$id] UNTRUSTED/brew trust present=$exp_untrusted"
    if [ "$exp_untrusted" = "1" ]; then
        _x_has "$UPGRADE_OUTPUT" "UNTRUSTED" "tap-refused must mention UNTRUSTED" && \
        _x_has "$UPGRADE_OUTPUT" "brew trust" "tap-refused must give 'brew trust' remediation" && test_pass
    else
        _x_hasnt "$UPGRADE_OUTPUT" "UNTRUSTED" "non-tap reason must NOT mention UNTRUSTED" && \
        _x_hasnt "$UPGRADE_OUTPUT" "brew trust" "non-tap reason must NOT suggest 'brew trust'" && test_pass
    fi

    test_start "[$id] info line ($exp_info)"
    case "$exp_info" in
        nomark) _x_has "$UPGRADE_OUTPUT" "$INFO_NOMARK" "missing no-marker info line" && \
                _x_hasnt "$UPGRADE_OUTPUT" "the caller already ran it" "must not print the skip line" && test_pass ;;
        skip)   _x_has "$UPGRADE_OUTPUT" "$INFO_SKIP" "missing marker skip info line" && \
                _x_hasnt "$UPGRADE_OUTPUT" "no caller marker" "must not print the no-marker line" && test_pass ;;
        none)   _x_hasnt "$UPGRADE_OUTPUT" "no caller marker" "unexpected no-marker line" && \
                _x_hasnt "$UPGRADE_OUTPUT" "the caller already ran it" "unexpected skip line" && test_pass ;;
    esac
done <<< "$CASES"

# Vacuity guard: the table was actually iterated and assertions actually ran.
test_start "VACUITY: table iterated 15 cases and >= 100 assertions ran"
if [ "$_n_cases" -eq 15 ] && [ "$_ASSERTIONS" -ge 100 ]; then
    test_pass
else
    test_fail "cases=$_n_cases (want 15) assertions=$_ASSERTIONS (want >= 100)"
fi

# Static guard: contract tokens exist in the implementation.
test_start "STATIC: upgrade.sh references the marker env var and Reason codes"
_static_ok=true
for tok in AITEAMFORGE_BREW_UPGRADE_DONE tap-refused caller-upgrade-did-not-advance \
           brew-upgrade-did-not-advance brew-upgrade-exit-nonzero; do
    grep -qF "$tok" "$UPGRADE_SH" || { _static_ok=false; echo "     missing token: $tok" >&2; }
done
if [ "$_static_ok" = true ]; then test_pass; else test_fail "upgrade.sh lacks contract tokens"; fi

# Version pin (PR #1312 review): an explicit no-marker run that upgrades brew must
# WARN that it goes past a set pin; the marker path never runs brew, so no warning;
# no pin file => no warning.
_PIN_FILE="$_AITEAMFORGE_DIR/version-pin"
for _pc in pinned-nomarker pinned-marker unpinned-nomarker; do
    test_start "PIN: $_pc"
    case "$_pc" in
        pinned-*) echo "v0.15.0" > "$_PIN_FILE" ;;
        *) rm -f "$_PIN_FILE" ;;
    esac
    case "$_pc" in
        *-marker) _scenario stale_probe; _run_upgrade 1 --non-interactive ;;
        *)        _scenario advance;     _run_upgrade @unset --non-interactive ;;
    esac
    _calls="$(grep -c '^upgrade aiteamforge' "$BREW_CALL_LOG" 2>/dev/null || true)"
    case "$_pc" in
        pinned-nomarker)
            _x_eq 1 "${_calls:-0}" "pinned no-marker run must still upgrade (calls)" && \
            _x_has "$UPGRADE_OUTPUT" "version-pin is set (v0.15.0" "missing version-pin warning" && \
            _x_has "$UPGRADE_OUTPUT" "goes past it" "warning must say the run goes past the pin" && test_pass ;;
        pinned-marker)
            _x_eq 0 "${_calls:-0}" "marker run must not upgrade (calls)" && \
            _x_hasnt "$UPGRADE_OUTPUT" "version-pin is set" "marker path must not warn (it runs no brew)" && test_pass ;;
        unpinned-nomarker)
            _x_eq 1 "${_calls:-0}" "unpinned no-marker run must upgrade (calls)" && \
            _x_hasnt "$UPGRADE_OUTPUT" "version-pin is set" "no pin file => no warning" && test_pass ;;
    esac
done
rm -f "$_PIN_FILE"

# Unit: tap_load_refused() under the caller's `set -eo pipefail`, with a refusing
# brew that exits NON-ZERO and prints the refusal first, then a LOT of output. A
# `printf | grep -q` match SIGPIPEs on large input and pipefail turns it into a
# false "not refused" (review finding on PR #1312); the here-string match must not.
_LRB="$TEST_TMP_DIR/large-refusal-bin"
mkdir -p "$_LRB"
cat > "$_LRB/brew" <<'LRB_EOF'
#!/bin/bash
echo "Error: Refusing to load formula aiteamforge from untrusted tap doublenode/aiteamforge"
i=0; while [ $i -lt 20000 ]; do echo "padding line $i ................................................"; i=$((i + 1)); done
exit 1
LRB_EOF
chmod +x "$_LRB/brew"
for _lines in small large; do
    test_start "UNIT: tap_load_refused detects a non-zero-exit refusal under pipefail ($_lines output)"
    if [ "$_lines" = small ]; then
        _brew_dir="$_MOCK_BIN"; _env_extra="S_UNTRUSTED=$TEST_TMP_DIR/unit-untrusted"; : > "$TEST_TMP_DIR/unit-untrusted"
    else
        _brew_dir="$_LRB"; _env_extra="S_UNUSED=1"
    fi
    _ASSERTIONS=$((_ASSERTIONS + 1))
    if env "$_env_extra" PATH="$_brew_dir:/usr/bin:/bin" bash -c \
        'set -eo pipefail; source "$1"; if tap_load_refused; then echo REFUSED; else echo NOT; fi' \
        _ "$TAP_ROOT/libexec/lib/common.sh" 2>/dev/null | grep -qx REFUSED; then
        test_pass
    else
        test_fail "tap_load_refused reported the refusing tap as NOT refused ($_lines output)"
    fi
done

if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "Results: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed (assertions: $_ASSERTIONS)"
    [ "$_FAIL_COUNT" -gt 0 ] && exit 1
fi
exit 0
