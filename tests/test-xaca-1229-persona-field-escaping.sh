#!/bin/bash
# test-xaca-1229-persona-field-escaping.sh
# Regression tests for XACA-1229: install-team.sh's per-agent startup-script
# generator (generate_per_agent_startup_scripts / generate_script) and
# per-agent zshrc generator (generate_per_agent_zshrc_files) embedded persona
# free-text fields (Core Identity **Name**/**Character** -> SESSION_DEVELOPER,
# **Role** -> SESSION_ROLE, **Location** -> SESSION_LOCATION, **Uniform
# Color** -> SESSION_THEME, frontmatter description -> SESSION_DESCRIPTION,
# frontmatter name -> @claude_agent) into double-quoted bash assignments and
# a `tmux send-keys`-retyped banner line WITHOUT escaping them. Real personas
# carry exactly this shape of value:
#   - Montgomery "Scotty" Scott   (embedded double quotes)
#   - Una Chin-Riley ("Number One")  (embedded quotes + parens)
#   - Miles Edward O'Brien        (embedded apostrophe)
# The fix (render_dq/render_sq in install-team.sh, XACA-1229):
#   (a) escapes \ " ` $ for every double-quoted assignment in both
#       generators, and refuses (skips, with a stderr warning naming
#       XACA-1229) any persona whose field contains a control character
#       rather than emit it unsafely;
#   (b) pre-quotes each of the 10 banner send-keys args individually via
#       `printf %q` (the same LC_ALL=C /bin/bash -c 'printf %q' mechanism as
#       XACA-1215's _SESSION_DIRECTORY_Q) so the pane's own zsh, which
#       RE-PARSES the retyped send-keys string a second time, reconstructs
#       exactly one literal argument per field instead of letting an
#       embedded " / $() / backtick split or execute;
#   (c) the zshrc generator's @developer/@claude_agent double-quoted tmux
#       args and SESSION_TITLE single-quoted assignment get the matching
#       (double- vs single-quote) escaping.
#
# ── CI / default-run contract (no git dependency) ───────────────────────────
# The default invocation (no arguments) never touches git history: HEAD may
# be pre-fix (mid-development) or post-fix depending on when this runs, and a
# default-run comparison against git history would be meaningless either way.
# The default suite runs entirely against the CURRENT on-disk
# libexec/installers/install-team.sh (extracted the same heredoc-aware way
# test-xaca-1215-session-directory.sh does).
#
# A true negative control (proving this test file can actually DETECT the
# pre-fix bug, by extracting and running the generators from `git show
# HEAD:...`) is available but opt-in only:
#
#     bash test-xaca-1229-persona-field-escaping.sh --negative-control <ref>
#
# <ref> is a git ref resolved via
# `git -C <tap-root> show <ref>:libexec/installers/install-team.sh` (never a
# checkout — this worktree has a concurrent editor on the real file). It
# exits 0 only when the pre-fix source is confirmed detectably buggy across
# multiple independent signals (round-trip value corruption AND real
# command-substitution side effects in a sandboxed dir) and FAILS LOUDLY
# (never silently skips) if `git show` cannot produce the source.
#
# ── Sandbox isolation (non-negotiable) ──────────────────────────────────────
# HOME and AITEAMFORGE_DIR are exported under TEST_TMP_DIR before anything is
# sourced/run. TMUX/TMUX_PANE/TMUX_SOCKET are stripped (this test commonly
# runs inside a real tmux pane). tmux is stubbed on PATH — it never starts a
# real server, it only logs argv and returns controlled exit codes. Every
# path this test or a generated script touches is asserted to resolve under
# TEST_TMP_DIR. The one deliberate exception: when proving the PRE-FIX
# negative control is vulnerable, a `$(touch ...)`/backtick payload is
# allowed to actually fire `touch` — but ONLY against a dedicated
# TEST_TMP_DIR subdirectory reserved for that proof, checked and reported
# explicitly, never against the FIXED-generator's own sandboxed output area
# (which is asserted PWNED-file-free at the end of the default suite).
#
# Runs under /bin/bash 3.2 (macOS) — no bash-4-only constructs (no
# `declare -A`, no `mapfile`, no `${var,,}`).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_TEAM="$TAP_ROOT/libexec/installers/install-team.sh"

# ─────────────────────────────────────────────────────────────────────────────
# Arg parsing: only recognised flag is --negative-control <ref>.
# ─────────────────────────────────────────────────────────────────────────────
NEGATIVE_CONTROL_TARGET=""
while [ $# -gt 0 ]; do
    case "$1" in
        --negative-control)
            if [ -z "${2:-}" ]; then
                echo "FATAL: --negative-control requires an argument (a git ref)" >&2
                exit 2
            fi
            NEGATIVE_CONTROL_TARGET="$2"
            shift 2
            ;;
        *) shift ;;
    esac
done

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework (mirrors test-xaca-1215-session-directory.sh).
# ─────────────────────────────────────────────────────────────────────────────
_STANDALONE=false
if ! type -t test_start >/dev/null 2>&1; then
    _STANDALONE=true
    _PASS_COUNT=0
    _FAIL_COUNT=0
    _SKIP_COUNT=0
    _CURRENT_TEST=""

    test_start() { _CURRENT_TEST="$1"; echo "  >> $1"; }
    test_pass()  { _PASS_COUNT=$((_PASS_COUNT + 1)); echo "     PASS: $_CURRENT_TEST"; }
    test_fail()  { _FAIL_COUNT=$((_FAIL_COUNT + 1)); echo "     FAIL: $_CURRENT_TEST — $1" >&2; }
    test_skip()  { _SKIP_COUNT=$((_SKIP_COUNT + 1)); echo "     SKIP: $_CURRENT_TEST — $1"; }
fi

# ─────────────────────────────────────────────────────────────────────────────
# Sandbox root
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca1229test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
TEST_TMP_DIR="$(cd "$TEST_TMP_DIR" && pwd -P)"

cleanup() {
    if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then
        rm -rf "$TEST_TMP_DIR"
    fi
}
trap cleanup EXIT INT TERM

_assert_sandboxed() {
    case "$1" in
        "$TEST_TMP_DIR"/*) return 0 ;;
        *)
            echo "FATAL SANDBOX ESCAPE: path '$1' does not resolve under TEST_TMP_DIR ($TEST_TMP_DIR) — refusing to proceed." >&2
            exit 1
            ;;
    esac
}

export HOME="$TEST_TMP_DIR/home"
export AITEAMFORGE_DIR="$TEST_TMP_DIR/aiteamforge"
_assert_sandboxed "$HOME"
_assert_sandboxed "$AITEAMFORGE_DIR"
mkdir -p "$HOME" "$AITEAMFORGE_DIR"

unset TMUX TMUX_PANE TMUX_SOCKET

export TMUX_TMPDIR="$TEST_TMP_DIR/tmux-tmpdir"
mkdir -p "$TMUX_TMPDIR"

# Dedicated hostile-payload target dirs. $SANDBOX is referenced LITERALLY
# (never pre-expanded) inside fixture persona field text as the bash
# variable name "$SANDBOX" — if a command-substitution/backtick injection
# ever actually fires, it resolves whatever SANDBOX points to in the
# environment of the process running the (buggy) generated script AT THAT
# MOMENT. Two separate dirs keep the negative control's deliberate proof-of-
# vulnerability side effects from ever being confused with the fixed
# generator's (expected-empty) output area.
SANDBOX_FIXED="$TEST_TMP_DIR/hostile-sandbox-fixed"
SANDBOX_NEGCTRL="$TEST_TMP_DIR/hostile-sandbox-negctrl"
_assert_sandboxed "$SANDBOX_FIXED"; _assert_sandboxed "$SANDBOX_NEGCTRL"
mkdir -p "$SANDBOX_FIXED" "$SANDBOX_NEGCTRL"

# ─────────────────────────────────────────────────────────────────────────────
# Stub tmux: logs each call's argv to a per-call file (one arg per line —
# safe because none of our fixture values contain a real embedded newline;
# the one persona that does, case 5, is refused before ever reaching tmux)
# PLUS a flat space-joined log for cheap substring checks. `has-session`'s
# exit code is controlled by TMUX_STUB_HAS_SESSION_EXIT (default 1 = "no
# session" -> generated script takes the create-session path) so callers can
# choose between "assignments only, no session creation" (exit 0) and "drive
# the full creation path to capture the banner send-keys call" (exit 1).
# ─────────────────────────────────────────────────────────────────────────────
STUB_BIN="$TEST_TMP_DIR/stub-bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/tmux" <<'STUBEOF'
#!/bin/sh
: "${TMUX_STUB_LOG:?TMUX_STUB_LOG not set — refusing to run stub tmux without a log target}"
: "${TMUX_STUB_CALL_DIR:?TMUX_STUB_CALL_DIR not set}"
_cf="$TMUX_STUB_CALL_DIR/.count"
_n=$(cat "$_cf" 2>/dev/null || echo 0)
_n=$((_n + 1))
echo "$_n" > "$_cf"
_argf="$TMUX_STUB_CALL_DIR/call-$_n.args"
: > "$_argf"
for _a in "$@"; do
    printf '%s\n' "$_a" >> "$_argf"
done
echo "$@" >> "$TMUX_STUB_LOG"
for _a in "$@"; do
    case "$_a" in
        has-session) exit "${TMUX_STUB_HAS_SESSION_EXIT:-1}" ;;
    esac
done
exit 0
STUBEOF
chmod +x "$STUB_BIN/tmux"
export PATH="$STUB_BIN:$PATH"

test_start "Sandbox preflight: stub tmux resolves ahead of any real tmux on PATH"
if [ "$(command -v tmux)" = "$STUB_BIN/tmux" ]; then
    test_pass
else
    test_fail "PATH resolves tmux to $(command -v tmux 2>&1), expected $STUB_BIN/tmux — refusing to continue"
    echo "Results: ${_PASS_COUNT} passed, $((_FAIL_COUNT)) failed"
    exit 1
fi

# Reset the stub tmux call log/call-dir for a fresh capture. Call BEFORE
# every generated-script invocation whose tmux calls you intend to inspect.
_reset_tmux_stub() {
    TMUX_STUB_LOG="$TEST_TMP_DIR/tmux-stub-$1.log"
    TMUX_STUB_CALL_DIR="$TEST_TMP_DIR/tmux-stub-calls-$1"
    _assert_sandboxed "$TMUX_STUB_LOG"; _assert_sandboxed "$TMUX_STUB_CALL_DIR"
    rm -rf "$TMUX_STUB_CALL_DIR"
    mkdir -p "$TMUX_STUB_CALL_DIR"
    : > "$TMUX_STUB_LOG"
    export TMUX_STUB_LOG TMUX_STUB_CALL_DIR
}

# Find the single call-N.args file (one argv item per line) whose 4th line
# (send-keys's literal string argument) contains a given substring, e.g.
# "banner.sh". Prints the call file path, or nothing if not found.
_find_call_with() {
    # $1 = call dir, $2 = substring to find on the 4th line (0-indexed line 4)
    local d="$1" needle="$2" f
    for f in "$d"/call-*.args; do
        [ -f "$f" ] || continue
        # Line 4 (1-indexed) is the send-keys literal-string argument for
        # our "send-keys -t <target> <string> C-m" calls (5 lines total).
        local l4
        l4=$(sed -n '4p' "$f")
        case "$l4" in
            *"$needle"*) echo "$f"; return 0 ;;
        esac
    done
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Heredoc-aware function extractor (copied from test-xaca-1215-session-
# directory.sh's own comment: generic over function name/source file).
# generate_per_agent_startup_scripts() and generate_per_agent_zshrc_files()
# both embed `python3 - ... <<'PYEOF' ... PYEOF` heredocs with bare "}"
# lines inside dict/function literals that would fool a naive brace counter.
# ─────────────────────────────────────────────────────────────────────────────
_extract_fn_heredoc_aware() {
    # $1 = source file, $2 = original function name, $3 = new name.
    awk -v origname="$2" -v newname="$3" '
        $0 ~ ("^" origname "\\(\\) \\{") {
            capture = 1
            print newname "() {"
            next
        }
        capture && $0 ~ /<<.[A-Za-z_]+.$/ { in_heredoc = 1; heredoc_term = $0; sub(/^.*<</, "", heredoc_term); gsub(/[\x27"]/, "", heredoc_term) }
        capture { print }
        capture && in_heredoc && $0 == heredoc_term { in_heredoc = 0; next }
        capture && !in_heredoc && /^}$/ { exit }
    ' "$1"
}

# ─────────────────────────────────────────────────────────────────────────────
# Persona fixtures.
#
# Field-transform notes (so the "expected" values below actually match what
# the generator will compute, not just the raw fixture text):
#   - Core Identity **Name**/**Role** flow straight through (find_field only
#     .strip()s and rstrip("\\")s a TRAILING backslash) -> raw pass-through,
#     so none of our fixture Name/Role values end with a bare backslash.
#   - **Location** goes through make_location(), which only rewrites the
#     value if it contains " - "; every fixture Location below deliberately
#     avoids " - " so it passes through unchanged (raw round-trip).
#   - frontmatter `description` goes through make_session_desc(), which DOES
#     transform: "<TEAM> <TERMINAL> - <UPPERCASED SUFFIX-BEFORE-FIRST-,-OR-.>"
#     when the description contains " - ". Fixture descriptions below avoid
#     commas/periods in the suffix so the upper-cased suffix is fully
#     predictable and asserted exactly.
#   - frontmatter `name:` is also the AGENT_TERMINAL_<char_key> lookup key
#     (char_key = name.lower().replace('-','_'), matched against a `\w+`
#     regex in the conf parser) -- a name containing quotes/spaces/$/backtick
#     could never resolve to a mapped terminal slug at all (the persona
#     would just be treated as subagent-only and skipped), so that
#     particular field is structurally unreachable for a *hostile-character*
#     test. It still gets a plain round-trip check via the zshrc generator's
#     @claude_agent assertion below.
# ─────────────────────────────────────────────────────────────────────────────

CI_NAME_SCOTTY='Montgomery "Scotty" Scott'
CI_NAME_UNA='Una Chin-Riley ("Number One")'
CI_NAME_OBRIEN="Miles Edward O'Brien"
# XACA-1229-testnote: parse_core_identity's field regex is
# `\*\*Name\*\*:?\s*(.+)` matched with plain re.search (no re.MULTILINE /
# re.DOTALL) -- `.` never matches `\n`, so a literal embedded newline can
# never survive into a parsed field value in the first place; the value is
# truncated at the line boundary by the parser itself, long before render_dq
# ever sees it. A raw ESC (0x1b) byte on the SAME line reaches render_dq's
# `ord(c) < 0x20` check identically to how a newline would if it could get
# there, so it exercises the exact same refusal code path.
CI_NAME_CTRL=$'Bad\x1bName'

# Case 4: hostile characters spread across Role ($()/backtick), Location
# (mid-string backslash, never trailing), and frontmatter description
# (non-ASCII, XACA-1215-019-style). $SANDBOX is a LITERAL two dollar-sign
# variable reference in the fixture text (never pre-expanded here) --
# whichever SANDBOX_* dir is exported at the time a (possibly still-buggy)
# generated script actually evaluates this text is where a real `touch`
# would land if the injection fires.
CI_ROLE_HOSTILE='Analysis - handles $(touch $SANDBOX/PWNED_role_dollar) and `touch $SANDBOX/PWNED_role_tick` intrusions!'
CI_LOCATION_HOSTILE='Spacedock Analysis Bay\Sensor Array'
FM_DESC_HOSTILE='Space Dock Analysis - Zoë 日本 Ops'

PERSONAS_DIR="$AITEAMFORGE_DIR/spacedock/personas/agents"
mkdir -p "$PERSONAS_DIR"

_write_persona() {
    # $1=out $2=fm_name $3=fm_desc $4=ci_name $5=ci_role $6=ci_location $7=ci_uniform
    local out="$1" fm_name="$2" fm_desc="$3" ci_name="$4" ci_role="$5" ci_location="$6" ci_uniform="$7"
    cat > "$out" <<PERSONAEOF
---
name: $fm_name
description: $fm_desc
version: 1.0.0
author: XACA-1229-test
tags: [spacedock, test]
model: sonnet
---

# $fm_name Test Persona

## Core Identity

**Name:** $ci_name
**Role:** $ci_role
**Location:** $ci_location
**Uniform Color:** $ci_uniform

---
PERSONAEOF
}

_write_persona "$PERSONAS_DIR/spacedock_scotty-sd_repair_persona.md" \
    "scotty-sd" "Space Dock Repair - Recovery Operations" \
    "$CI_NAME_SCOTTY" "Repair & Salvage - Hands-On Recovery Execution" \
    "Spacedock Engineering Deck" "Operations"

_write_persona "$PERSONAS_DIR/spacedock_sisko-sd_dockmaster_persona.md" \
    "sisko-sd" "Space Dock Command - Fleet Operations" \
    "$CI_NAME_UNA" "Dockmaster - Fleet Coordination" \
    "Spacedock Command Deck" "Command"

_write_persona "$PERSONAS_DIR/spacedock_geordi-sd_diagnostics_persona.md" \
    "geordi-sd" "Space Dock Diagnostics - Systems Analysis" \
    "$CI_NAME_OBRIEN" "Diagnostics - Systems Engineering" \
    "Spacedock Diagnostics Bay" "Engineering"

_write_persona "$PERSONAS_DIR/spacedock_spock-sd_analysis_persona.md" \
    "spock-sd" "$FM_DESC_HOSTILE" \
    "Spock" "$CI_ROLE_HOSTILE" \
    "$CI_LOCATION_HOSTILE" "Science"

_write_persona "$PERSONAS_DIR/spacedock_worf-sd_security_persona.md" \
    "worf-sd" "Space Dock Security - Perimeter Defense" \
    "$CI_NAME_CTRL" "Security - Standard Duty" \
    "Spacedock Security Deck" "Security"

test_start "Fixture preflight: 5 persona files written"
FIXTURE_COUNT=$(find "$PERSONAS_DIR" -maxdepth 1 -name '*_persona.md' 2>/dev/null | wc -l | tr -d ' ')
if [ "${FIXTURE_COUNT:-0}" -eq 5 ]; then test_pass; else test_fail "Expected 5 fixture files, found ${FIXTURE_COUNT:-0}"; fi

# Synthetic team conf: only the two grep'd-for-directly variable families the
# generators actually read (AGENT_WINDOWS_*, AGENT_TERMINAL_*) -- the
# generators never source $TEAM_CONF, they grep it, so no other team-conf
# machinery is needed.
TEAM_CONF_SYNTH="$TEST_TMP_DIR/synthetic-spacedock.conf"
_assert_sandboxed "$TEAM_CONF_SYNTH"
cat > "$TEAM_CONF_SYNTH" <<'CONFEOF'
AGENT_WINDOWS_repair="repair-cmd monitor scratch debug"
AGENT_WINDOWS_dockmaster="dockmaster-cmd monitor scratch debug"
AGENT_WINDOWS_diagnostics="diagnostics-cmd monitor scratch debug"
AGENT_WINDOWS_analysis="analysis-cmd monitor scratch debug"
AGENT_WINDOWS_security="security-cmd monitor scratch debug"
AGENT_TERMINAL_scotty_sd="repair"
AGENT_TERMINAL_sisko_sd="dockmaster"
AGENT_TERMINAL_geordi_sd="diagnostics"
AGENT_TERMINAL_spock_sd="analysis"
AGENT_TERMINAL_worf_sd="security"
CONFEOF

# Expected values (see field-transform notes above).
E_SCOTTY_DEV="$CI_NAME_SCOTTY";  E_SCOTTY_ROLE="Repair & Salvage - Hands-On Recovery Execution"
E_SCOTTY_LOC="Spacedock Engineering Deck"; E_SCOTTY_DESC="SPACEDOCK REPAIR - RECOVERY OPERATIONS"
E_SCOTTY_THEME="OPERATIONS"

E_UNA_DEV="$CI_NAME_UNA"; E_UNA_ROLE="Dockmaster - Fleet Coordination"
E_UNA_LOC="Spacedock Command Deck"; E_UNA_DESC="SPACEDOCK DOCKMASTER - FLEET OPERATIONS"
E_UNA_THEME="COMMAND"

E_OBRIEN_DEV="$CI_NAME_OBRIEN"; E_OBRIEN_ROLE="Diagnostics - Systems Engineering"
E_OBRIEN_LOC="Spacedock Diagnostics Bay"; E_OBRIEN_DESC="SPACEDOCK DIAGNOSTICS - SYSTEMS ANALYSIS"
E_OBRIEN_THEME="ENGINEERING"

E_SPOCK_DEV="Spock"; E_SPOCK_ROLE="$CI_ROLE_HOSTILE"
E_SPOCK_LOC="$CI_LOCATION_HOSTILE"; E_SPOCK_DESC="SPACEDOCK ANALYSIS - ZOË 日本 OPS"
E_SPOCK_THEME="SCIENCE"

# ═══════════════════════════════════════════════════════════════════════════
# Shared harness bodies (used by both the default suite, against the CURRENT
# install-team.sh, and — reparented onto a different extracted source — by
# negative-control mode against a pre-fix source). Defined as functions
# parameterised on a name PREFIX so both runs can coexist in one process
# without clobbering each other's extracted-function names.
# ═══════════════════════════════════════════════════════════════════════════

# Run the extracted startup-script generator once. $1=fn name to call,
# $2=atf dir, $3=scripts-dir-will-be $2/spacedock/scripts
_run_startup_gen() {
    local fn="$1" atf="$2"
    _assert_sandboxed "$atf"
    mkdir -p "$atf"
    (
        AITEAMFORGE_DIR="$atf"
        HOMEBREW_TAP_ROOT="$TAP_ROOT"
        TEAM_ID="spacedock"
        TEAM_CONF="$TEAM_CONF_SYNTH"
        TEAM_COLOR="#CC66FF"
        TEAM_WORKING_DIR="\$HOME/.aiteamforge/spacedock"
        "$fn"
    ) >"$TEST_TMP_DIR/gen-stdout.log" 2>"$TEST_TMP_DIR/gen-stderr.log"
}

_run_zshrc_gen() {
    local fn="$1" atf="$2"
    _assert_sandboxed "$atf"
    mkdir -p "$atf"
    (
        AITEAMFORGE_DIR="$atf"
        HOMEBREW_TAP_ROOT="$TAP_ROOT"
        TEAM_ID="spacedock"
        TEAM_CONF="$TEAM_CONF_SYNTH"
        "$fn"
    ) >"$TEST_TMP_DIR/zshrc-gen-stdout.log" 2>"$TEST_TMP_DIR/zshrc-gen-stderr.log"
}

# Assignment round-trip: run a generated startup script with has-session=0
# (skip session creation entirely — pure top-of-script assignments), under a
# given interpreter, sourced in a subshell, dumping the 4 vars of interest to
# files for byte-exact comparison. $1=interpreter ("bash" or "zsh"),
# $2=script path, $3=out-prefix, $4=SANDBOX dir to export for this run.
_capture_assignments() {
    local interp="$1" script="$2" outpref="$3" sbox="$4"
    _assert_sandboxed "$outpref"
    _reset_tmux_stub "assign-$(basename "$outpref")"
    TMUX_STUB_HAS_SESSION_EXIT=0
    export TMUX_STUB_HAS_SESSION_EXIT
    (
        HOME="$HOME"
        SANDBOX="$sbox"
        SKIP_ATTACH=1
        export HOME SANDBOX SKIP_ATTACH TMUX_STUB_LOG TMUX_STUB_CALL_DIR TMUX_STUB_HAS_SESSION_EXIT PATH
        if [ "$interp" = "zsh" ]; then
            # shellcheck disable=SC2016
            zsh -f -c '. "$1"; printf "%s" "$SESSION_DEVELOPER" > "$2.developer"; printf "%s" "$SESSION_ROLE" > "$2.role"; printf "%s" "$SESSION_LOCATION" > "$2.location"; printf "%s" "$SESSION_DESCRIPTION" > "$2.description"; printf "%s" "$SESSION_THEME" > "$2.theme"' _ "$script" "$outpref" \
                >"$outpref.stdout.log" 2>"$outpref.stderr.log"
        else
            /bin/bash -c '. "$1"; printf "%s" "$SESSION_DEVELOPER" > "$2.developer"; printf "%s" "$SESSION_ROLE" > "$2.role"; printf "%s" "$SESSION_LOCATION" > "$2.location"; printf "%s" "$SESSION_DESCRIPTION" > "$2.description"; printf "%s" "$SESSION_THEME" > "$2.theme"' _ "$script" "$outpref" \
                >"$outpref.stdout.log" 2>"$outpref.stderr.log"
        fi
    )
}

_assert_capture_eq() {
    # $1=label $2=outpref $3=field(developer|role|location|description|theme) $4=expected
    local label="$1" outpref="$2" field="$3" expected="$4" actual
    test_start "$label"
    if [ ! -f "$outpref.$field" ]; then
        test_fail "no captured output file $outpref.$field (interpreter run failed?) stderr: $(cat "$outpref.stderr.log" 2>/dev/null)"
        return
    fi
    actual=$(cat "$outpref.$field")
    if [ "$actual" = "$expected" ]; then
        test_pass
    else
        test_fail "expected [$expected] got [$actual]"
    fi
}

# Banner-args capture + zsh reparse. Drives the create-session path
# (has-session=1) to capture the literal send-keys banner string, then
# re-parses that EXACT string under `zsh -f -c` (simulating the pane
# retyping it) with a stub banner.sh sourced in place of the real one, and
# asserts exactly 10 args land with the right values at the right positions.
# $1=script $2=atf(scripts live under $atf/spacedock/scripts) $3=out-prefix
# $4=sandbox dir $5=expected description $6=expected location
# $7=expected developer $8=expected role
_capture_banner_args() {
    local script="$1" atf="$2" outpref="$3" sbox="$4"
    local e_desc="$5" e_loc="$6" e_dev="$7" e_role="$8"
    _assert_sandboxed "$outpref"
    _reset_tmux_stub "banner-$(basename "$outpref")"
    # Record the resolved call dir under a predictable name so callers don't
    # have to reconstruct _reset_tmux_stub's naming scheme themselves (it
    # prefixes with "banner-" AND $outpref's basename already starts with
    # "banner-", so the actual dir is tmux-stub-calls-banner-banner-<name>,
    # not tmux-stub-calls-banner-<name>).
    LAST_BANNER_CALL_DIR="$TMUX_STUB_CALL_DIR"
    TMUX_STUB_HAS_SESSION_EXIT=1
    export TMUX_STUB_HAS_SESSION_EXIT

    (
        HOME="$HOME"
        SANDBOX="$sbox"
        SKIP_ATTACH=1
        export HOME SANDBOX SKIP_ATTACH TMUX_STUB_LOG TMUX_STUB_CALL_DIR TMUX_STUB_HAS_SESSION_EXIT PATH
        bash "$script"
    ) >"$outpref.run-stdout.log" 2>"$outpref.run-stderr.log"

    test_start "$(basename "$outpref"): banner send-keys call captured"
    local callfile
    callfile=$(_find_call_with "$TMUX_STUB_CALL_DIR" "banner.sh")
    if [ -z "$callfile" ]; then
        test_fail "no send-keys call containing 'banner.sh' found in $TMUX_STUB_CALL_DIR. run stderr: $(cat "$outpref.run-stderr.log" 2>/dev/null)"
        return 1
    fi
    test_pass

    # Line 4 of the call file (1-indexed) is the literal string arg.
    local bannerline
    bannerline=$(sed -n '4p' "$callfile")
    printf '%s' "$bannerline" > "$outpref.bannerline"

    # Stub banner.sh at the exact path the real one would occupy, so the
    # zsh -f -c reparse below sources OUR stub (dumps argv NUL-separated)
    # instead of trying to source a nonexistent real banner script.
    local scripts_dir="$atf/spacedock/scripts"
    mkdir -p "$scripts_dir"
    cat > "$scripts_dir/spacedock-banner.sh" <<'BANNERSTUBEOF'
: > "$BANNER_ARGS_OUT"
for _a in "$@"; do
    printf '%s\n' "$_a" >> "$BANNER_ARGS_OUT"
done
printf '%s\n' "$#" > "$BANNER_ARGS_OUT.count"
BANNERSTUBEOF

    BANNER_ARGS_OUT="$outpref.banner-args"
    _assert_sandboxed "$BANNER_ARGS_OUT"
    rm -f "$BANNER_ARGS_OUT" "$BANNER_ARGS_OUT.count"
    export BANNER_ARGS_OUT

    # Feed the EXACT captured bannerline text to zsh -c, precisely as tmux
    # send-keys would retype those bytes into the pane for the pane's own
    # zsh to parse.
    zsh -f -c "$bannerline" >"$outpref.reparse-stdout.log" 2>"$outpref.reparse-stderr.log"

    test_start "$(basename "$outpref"): zsh reparse of the banner line produced exactly 10 args"
    local nargs
    nargs=$(cat "$BANNER_ARGS_OUT.count" 2>/dev/null || echo "<none>")
    if [ "$nargs" = "10" ]; then
        test_pass
    else
        test_fail "expected 10 args after zsh reparse, got '$nargs'. bannerline: $bannerline | reparse stderr: $(cat "$outpref.reparse-stderr.log" 2>/dev/null)"
    fi

    if [ "$nargs" = "10" ]; then
        local a1 a6 a7 a8 a9
        a1=$(sed -n '1p' "$BANNER_ARGS_OUT")
        a6=$(sed -n '6p' "$BANNER_ARGS_OUT")
        a7=$(sed -n '7p' "$BANNER_ARGS_OUT")
        a8=$(sed -n '8p' "$BANNER_ARGS_OUT")
        a9=$(sed -n '9p' "$BANNER_ARGS_OUT")

        test_start "$(basename "$outpref"): banner arg 8 (developer) byte-exact"
        if [ "$a8" = "$e_dev" ]; then test_pass; else test_fail "expected [$e_dev] got [$a8]"; fi

        test_start "$(basename "$outpref"): banner arg 6 (description) byte-exact"
        if [ "$a6" = "$e_desc" ]; then test_pass; else test_fail "expected [$e_desc] got [$a6]"; fi

        test_start "$(basename "$outpref"): banner arg 7 (location) byte-exact"
        if [ "$a7" = "$e_loc" ]; then test_pass; else test_fail "expected [$e_loc] got [$a7]"; fi

        test_start "$(basename "$outpref"): banner arg 9 (role) byte-exact"
        if [ "$a9" = "$e_role" ]; then test_pass; else test_fail "expected [$e_role] got [$a9]"; fi
    else
        test_start "$(basename "$outpref"): banner arg 8 (developer) byte-exact"
        test_fail "skipped — arg count was not 10"
        test_start "$(basename "$outpref"): banner arg 6 (description) byte-exact"
        test_fail "skipped — arg count was not 10"
        test_start "$(basename "$outpref"): banner arg 7 (location) byte-exact"
        test_fail "skipped — arg count was not 10"
        test_start "$(basename "$outpref"): banner arg 9 (role) byte-exact"
        test_fail "skipped — arg count was not 10"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# NEGATIVE-CONTROL MODE (opt-in only — never runs on default invocation)
# ═══════════════════════════════════════════════════════════════════════════
if [ -n "$NEGATIVE_CONTROL_TARGET" ]; then
    test_start "NEGATIVE CONTROL: resolve '$NEGATIVE_CONTROL_TARGET' via git show"
    NC_SRC="$TEST_TMP_DIR/negative-control-install-team.sh"
    _assert_sandboxed "$NC_SRC"
    if git -C "$TAP_ROOT" show "${NEGATIVE_CONTROL_TARGET}:libexec/installers/install-team.sh" > "$NC_SRC" 2>"$TEST_TMP_DIR/nc-git.err" && [ -s "$NC_SRC" ]; then
        test_pass
    else
        test_fail "Could not resolve '$NEGATIVE_CONTROL_TARGET' via git show: $(cat "$TEST_TMP_DIR/nc-git.err" 2>/dev/null)"
        echo ""
        echo "Results: ${_PASS_COUNT} passed, $((_FAIL_COUNT + 1)) failed"
        echo "NEGATIVE CONTROL ABORTED (not a pass) — could not obtain the pre-fix source; refusing to report green."
        exit 1
    fi

    NC_EXTRACTED="$TEST_TMP_DIR/nc-extracted.sh"
    _extract_fn_heredoc_aware "$NC_SRC" "generate_per_agent_startup_scripts" "nc_gen_startup" > "$NC_EXTRACTED"

    test_start "NEGATIVE CONTROL: generator extracts to valid bash"
    if [ -s "$NC_EXTRACTED" ] && bash -n "$NC_EXTRACTED" 2>"$TEST_TMP_DIR/nc-syn.err"; then
        test_pass
    else
        test_fail "Extraction empty or syntax-invalid: $(cat "$TEST_TMP_DIR/nc-syn.err" 2>/dev/null)"
        echo "Results: ${_PASS_COUNT} passed, $((_FAIL_COUNT)) failed"
        echo "NEGATIVE CONTROL ABORTED (not a pass) — could not extract a runnable generator from the given source."
        exit 1
    fi
    # shellcheck source=/dev/null
    source "$NC_EXTRACTED"

    # Must match $AITEAMFORGE_DIR (where $PERSONAS_DIR fixtures live) for the
    # same reason as the default suite's ATF= above — a mismatched dir here
    # falls back to the REAL share/personas/spacedock/agents personas.
    NC_ATF="$AITEAMFORGE_DIR"
    _run_startup_gen nc_gen_startup "$NC_ATF"
    NC_SCRIPTS_DIR="$NC_ATF/spacedock/scripts"

    DETECTED=false
    EVIDENCE=""

    # Signal 1: SESSION_DEVELOPER round-trip corruption for any of the
    # quote/paren/apostrophe personas.
    #
    # IMPORTANT: this must compare the ACTUAL SHELL VALUE the pre-fix script
    # assigns (i.e. run/source it and read $SESSION_DEVELOPER back), not a
    # raw-text comparison against a naively-reconstructed
    # `SESSION_DEVELOPER="$expected"` string — the latter re-embeds
    # $expected's own embedded quote characters completely unescaped, which
    # reproduces the EXACT SAME malformed source text as the bug it's
    # supposed to detect, so it always "matches" and never fires. (Caught
    # empirically: this signal read as "round-tripped correctly" against
    # genuinely pre-fix HEAD until switched to executing the script.)
    for pair in "scotty-sd:$E_SCOTTY_DEV" "sisko-sd:$E_UNA_DEV" "geordi-sd:$E_OBRIEN_DEV"; do
        slug="${pair%%:*}"; expected="${pair#*:}"
        term=""
        case "$slug" in scotty-sd) term=repair ;; sisko-sd) term=dockmaster ;; geordi-sd) term=diagnostics ;; esac
        f="$NC_SCRIPTS_DIR/spacedock-$term-startup.sh"
        if [ -f "$f" ]; then
            ncpref="$TEST_TMP_DIR/nc-assign-$term"
            _capture_assignments "bash" "$f" "$ncpref" "$SANDBOX_NEGCTRL"
            got="<capture failed>"
            [ -f "$ncpref.developer" ] && got=$(cat "$ncpref.developer")
            if [ "$got" != "$expected" ]; then
                DETECTED=true
                EVIDENCE="${EVIDENCE}[$slug SESSION_DEVELOPER corrupted: got [$got] expected [$expected]] "
            fi
        else
            DETECTED=true
            EVIDENCE="${EVIDENCE}[$slug: no script generated at all — $f missing] "
        fi
    done

    test_start "NEGATIVE CONTROL: pre-fix source shows corrupted SESSION_DEVELOPER for at least one quote/paren/apostrophe persona"
    if [ "$DETECTED" = true ]; then
        test_pass
        echo "     EVIDENCE: $EVIDENCE"
    else
        test_fail "SESSION_DEVELOPER round-tripped correctly for all three — this source may not actually be pre-fix"
    fi

    # Signal 2 (independent, unambiguous): sourcing the pre-fix Spock script
    # under bash should actually EXECUTE the embedded $(...) / backtick
    # payload as real shell command substitution during the SESSION_ROLE
    # assignment itself, creating real files in SANDBOX_NEGCTRL.
    SPOCK_F="$NC_SCRIPTS_DIR/spacedock-analysis-startup.sh"
    rm -f "$SANDBOX_NEGCTRL"/PWNED_* 2>/dev/null
    if [ -f "$SPOCK_F" ]; then
        _reset_tmux_stub "nc-spock"
        TMUX_STUB_HAS_SESSION_EXIT=0
        (
            HOME="$HOME"
            SANDBOX="$SANDBOX_NEGCTRL"
            SKIP_ATTACH=1
            export HOME SANDBOX SKIP_ATTACH TMUX_STUB_LOG TMUX_STUB_CALL_DIR TMUX_STUB_HAS_SESSION_EXIT PATH
            /bin/bash "$SPOCK_F"
        ) >"$TEST_TMP_DIR/nc-spock-stdout.log" 2>"$TEST_TMP_DIR/nc-spock-stderr.log"
    fi
    NC_PWNED_COUNT=$(find "$SANDBOX_NEGCTRL" -maxdepth 1 -name 'PWNED_*' 2>/dev/null | wc -l | tr -d ' ')

    test_start "NEGATIVE CONTROL: pre-fix source's hostile Role field actually executes \$(...)/backtick command substitution (PWNED file created)"
    if [ "${NC_PWNED_COUNT:-0}" -ge 1 ]; then
        test_pass
        echo "     EVIDENCE: $(find "$SANDBOX_NEGCTRL" -maxdepth 1 -name 'PWNED_*' 2>/dev/null | tr '\n' ' ')"
        DETECTED=true
    else
        test_fail "No PWNED_* file appeared in $SANDBOX_NEGCTRL — either this source is not pre-fix, or Spock's script wasn't generated (stderr: $(cat "$TEST_TMP_DIR/nc-spock-stderr.log" 2>/dev/null))"
    fi
    rm -f "$SANDBOX_NEGCTRL"/PWNED_* 2>/dev/null

    echo ""
    echo "Negative-control results: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    if [ "$_FAIL_COUNT" -gt 0 ] && [ "$DETECTED" != true ]; then
        echo "NEGATIVE CONTROL FAILED — '$NEGATIVE_CONTROL_TARGET' was NOT detected as buggy by any signal."
        exit 1
    fi
    if [ "$DETECTED" != true ]; then
        echo "NEGATIVE CONTROL FAILED — no detection signal fired."
        exit 1
    fi
    echo "NEGATIVE CONTROL PASSED — '$NEGATIVE_CONTROL_TARGET' was confirmed buggy (own assertions above may still show individual FAILs; that is the point)."
    exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════
# DEFAULT SUITE (against the CURRENT on-disk install-team.sh)
# ═══════════════════════════════════════════════════════════════════════════

test_start "Preflight: install-team.sh exists and is executable"
if [ -x "$INSTALL_TEAM" ]; then test_pass; else test_fail "Not found/executable: $INSTALL_TEAM"; fi

STARTUP_EXTRACTED="$TEST_TMP_DIR/extracted-startup-gen.sh"
_extract_fn_heredoc_aware "$INSTALL_TEAM" "generate_per_agent_startup_scripts" "gen_startup_current" > "$STARTUP_EXTRACTED"

test_start "Extraction: generate_per_agent_startup_scripts extracts to valid bash"
if [ -s "$STARTUP_EXTRACTED" ] && bash -n "$STARTUP_EXTRACTED" 2>"$TEST_TMP_DIR/syn1.err"; then
    test_pass
else
    test_fail "Extraction empty or syntax-invalid: $(cat "$TEST_TMP_DIR/syn1.err" 2>/dev/null)"
fi
# shellcheck source=/dev/null
source "$STARTUP_EXTRACTED"

ZSHRC_EXTRACTED="$TEST_TMP_DIR/extracted-zshrc-gen.sh"
_extract_fn_heredoc_aware "$INSTALL_TEAM" "generate_per_agent_zshrc_files" "gen_zshrc_current" > "$ZSHRC_EXTRACTED"

test_start "Extraction: generate_per_agent_zshrc_files extracts to valid bash"
if [ -s "$ZSHRC_EXTRACTED" ] && bash -n "$ZSHRC_EXTRACTED" 2>"$TEST_TMP_DIR/syn2.err"; then
    test_pass
else
    test_fail "Extraction empty or syntax-invalid: $(cat "$TEST_TMP_DIR/syn2.err" 2>/dev/null)"
fi
# shellcheck source=/dev/null
source "$ZSHRC_EXTRACTED"

# ─── Run both generators once against the fixtures ─────────────────────────
# NOTE: must be the SAME AITEAMFORGE_DIR the fixture personas above were
# written under ($PERSONAS_DIR = $AITEAMFORGE_DIR/spacedock/personas/agents)
# — a different sandbox dir here would make personas_dir's existence check
# fail and silently fall back to the REAL share/personas/spacedock/agents
# personas (Sisko/Geordi/etc), which is exactly what happened the first time
# this test was run (evidence: "Captain Benjamin Sisko" / "Geordi La Forge"
# showing up instead of the fixture Una/O'Brien values).
ATF="$AITEAMFORGE_DIR"
_run_startup_gen gen_startup_current "$ATF"
SCRIPTS_DIR="$ATF/spacedock/scripts"

test_start "Generation: startup-script stderr mentions XACA-1229 refusing the control-character persona (worf-sd)"
if grep -q "XACA-1229" "$TEST_TMP_DIR/gen-stderr.log" 2>/dev/null; then
    test_pass
else
    test_fail "No XACA-1229-tagged warning in stderr: $(cat "$TEST_TMP_DIR/gen-stderr.log" 2>/dev/null)"
fi

test_start "Generation: worf-sd (control-char Name) produced NO startup script"
if [ ! -f "$SCRIPTS_DIR/spacedock-security-startup.sh" ]; then
    test_pass
else
    test_fail "spacedock-security-startup.sh was generated despite a control character in its Name field"
fi

test_start "Generation: the other 4 personas' startup scripts WERE generated despite worf-sd's refusal"
ALL4=true
for f in spacedock-repair-startup.sh spacedock-dockmaster-startup.sh spacedock-diagnostics-startup.sh spacedock-analysis-startup.sh; do
    [ -f "$SCRIPTS_DIR/$f" ] || { ALL4=false; echo "     missing: $f" >&2; }
done
if [ "$ALL4" = true ]; then test_pass; else test_fail "one or more of the 4 expected scripts is missing"; fi

# ─── bash -n on every generated startup script ──────────────────────────────
test_start "D: every generated startup script passes bash -n"
SYNTAX_OK=true
for f in "$SCRIPTS_DIR"/spacedock-*-startup.sh; do
    [ -f "$f" ] || continue
    bash -n "$f" 2>"$TEST_TMP_DIR/synf.err" || { SYNTAX_OK=false; echo "     syntax error in $(basename "$f"): $(cat "$TEST_TMP_DIR/synf.err")" >&2; }
done
if [ "$SYNTAX_OK" = true ]; then test_pass; else test_fail "one or more generated scripts failed bash -n"; fi

# ─── Assignment round-trip: bash AND zsh, all 4 valid personas ─────────────
for row in \
    "repair:$E_SCOTTY_DEV:$E_SCOTTY_ROLE:$E_SCOTTY_LOC:$E_SCOTTY_DESC:$E_SCOTTY_THEME" \
    "dockmaster:$E_UNA_DEV:$E_UNA_ROLE:$E_UNA_LOC:$E_UNA_DESC:$E_UNA_THEME" \
    "diagnostics:$E_OBRIEN_DEV:$E_OBRIEN_ROLE:$E_OBRIEN_LOC:$E_OBRIEN_DESC:$E_OBRIEN_THEME" \
    "analysis:$E_SPOCK_DEV:$E_SPOCK_ROLE:$E_SPOCK_LOC:$E_SPOCK_DESC:$E_SPOCK_THEME"
do
    term="${row%%:*}"; rest="${row#*:}"
    dev="${rest%%:*}"; rest="${rest#*:}"
    role="${rest%%:*}"; rest="${rest#*:}"
    loc="${rest%%:*}"; rest="${rest#*:}"
    desc="${rest%%:*}"; theme="${rest#*:}"

    script="$SCRIPTS_DIR/spacedock-$term-startup.sh"
    if [ ! -f "$script" ]; then
        test_start "$term: script exists for round-trip testing"
        test_fail "script not found: $script"
        continue
    fi

    for interp in bash zsh; do
        outpref="$TEST_TMP_DIR/assign-$term-$interp"
        _capture_assignments "$interp" "$script" "$outpref" "$SANDBOX_FIXED"
        _assert_capture_eq "$term/$interp: SESSION_DEVELOPER round-trips byte-exact" "$outpref" "developer" "$dev"
        _assert_capture_eq "$term/$interp: SESSION_ROLE round-trips byte-exact" "$outpref" "role" "$role"
        _assert_capture_eq "$term/$interp: SESSION_LOCATION round-trips byte-exact" "$outpref" "location" "$loc"
        _assert_capture_eq "$term/$interp: SESSION_DESCRIPTION round-trips byte-exact" "$outpref" "description" "$desc"
        _assert_capture_eq "$term/$interp: SESSION_THEME round-trips byte-exact" "$outpref" "theme" "$theme"
    done
done

# ─── Banner-arg capture + zsh reparse, all 4 valid personas ────────────────
_capture_banner_args "$SCRIPTS_DIR/spacedock-repair-startup.sh" "$ATF" "$TEST_TMP_DIR/banner-repair" "$SANDBOX_FIXED" \
    "$E_SCOTTY_DESC" "$E_SCOTTY_LOC" "$E_SCOTTY_DEV" "$E_SCOTTY_ROLE"
REPAIR_CALL_DIR="$LAST_BANNER_CALL_DIR"

_capture_banner_args "$SCRIPTS_DIR/spacedock-dockmaster-startup.sh" "$ATF" "$TEST_TMP_DIR/banner-dockmaster" "$SANDBOX_FIXED" \
    "$E_UNA_DESC" "$E_UNA_LOC" "$E_UNA_DEV" "$E_UNA_ROLE"
_capture_banner_args "$SCRIPTS_DIR/spacedock-diagnostics-startup.sh" "$ATF" "$TEST_TMP_DIR/banner-diagnostics" "$SANDBOX_FIXED" \
    "$E_OBRIEN_DESC" "$E_OBRIEN_LOC" "$E_OBRIEN_DEV" "$E_OBRIEN_ROLE"
_capture_banner_args "$SCRIPTS_DIR/spacedock-analysis-startup.sh" "$ATF" "$TEST_TMP_DIR/banner-analysis" "$SANDBOX_FIXED" \
    "$E_SPOCK_DESC" "$E_SPOCK_LOC" "$E_SPOCK_DEV" "$E_SPOCK_ROLE"

# ─── @claude_agent / @developer tmux set calls inside the startup script's
#     own creation path (same banner-driving run already captured them) ────
test_start "repair: startup script's own 'set @developer' tmux call is byte-exact"
# Search all call files for a "set ... @developer <value>" quadruple/tuple
# (line layout: set / -t / <session> / @developer / <value>) rather than
# assume a fixed call index — the exact call number shifts if the window
# count or generator internals change.
DEVSET_OK=false
for f in "$REPAIR_CALL_DIR"/call-*.args; do
    [ -f "$f" ] || continue
    if grep -qx '@developer' "$f"; then
        val=$(awk '/^@developer$/{getline; print; exit}' "$f")
        if [ "$val" = "$E_SCOTTY_DEV" ]; then DEVSET_OK=true; fi
    fi
done
if [ "$DEVSET_OK" = true ]; then test_pass; else test_fail "no 'set ... @developer' call carried the byte-exact Scotty developer value (searched $REPAIR_CALL_DIR)"; fi

test_start "repair: startup script's own 'set @claude_agent' tmux call is byte-exact"
AGENTSET_OK=false
for f in "$REPAIR_CALL_DIR"/call-*.args; do
    [ -f "$f" ] || continue
    if grep -qx '@claude_agent' "$f"; then
        val=$(awk '/^@claude_agent$/{getline; print; exit}' "$f")
        if [ "$val" = "scotty-sd" ]; then AGENTSET_OK=true; fi
    fi
done
if [ "$AGENTSET_OK" = true ]; then test_pass; else test_fail "no 'set ... @claude_agent' call carried the expected value 'scotty-sd' (searched $REPAIR_CALL_DIR)"; fi

# ─── zshrc generation ───────────────────────────────────────────────────────
ZATF="$AITEAMFORGE_DIR"
_run_zshrc_gen gen_zshrc_current "$ZATF"

test_start "zshrc generation: stderr mentions XACA-1229 refusing worf-sd"
if grep -q "XACA-1229" "$TEST_TMP_DIR/zshrc-gen-stderr.log" 2>/dev/null; then
    test_pass
else
    test_fail "No XACA-1229-tagged warning in zshrc stderr: $(cat "$TEST_TMP_DIR/zshrc-gen-stderr.log" 2>/dev/null)"
fi

test_start "zshrc generation: worf-sd produced no .zshrc file"
if [ ! -f "$HOME/.zshrc_spacedock_security" ]; then test_pass; else test_fail "zshrc was written for the control-char persona"; fi

test_start "zshrc generation: all 4 valid personas produced a .zshrc file"
ALL4Z=true
for f in .zshrc_spacedock_repair .zshrc_spacedock_dockmaster .zshrc_spacedock_diagnostics .zshrc_spacedock_analysis; do
    [ -f "$HOME/$f" ] || { ALL4Z=false; echo "     missing: $f" >&2; }
done
if [ "$ALL4Z" = true ]; then test_pass; else test_fail "one or more expected zshrc files missing"; fi

# Source just the tmux lines of each zshrc under zsh -f, TMUX=1, with a stub
# tmux FUNCTION (not a PATH binary this time — the zshrc calls `tmux` as a
# plain command from inside an interactive-shell context).
_check_zshrc_tmux_lines() {
    # $1=zshrc path $2=expected @developer value $3=expected-@claude_agent-suffix (character slug)
    local zshrc="$1" e_dev="$2" e_char="$3" logf driver
    logf="$TEST_TMP_DIR/zshrc-tmux-$(basename "$zshrc").log"
    _assert_sandboxed "$logf"
    : > "$logf"
    driver="$TEST_TMP_DIR/zshrc-driver-$(basename "$zshrc").zsh"
    cat > "$driver" <<'DRIVEREOF'
tmux() {
    if [[ "$1" == "set-option" ]]; then
        printf '%s\n' "$2" >> "$ZSHRC_TMUX_LOG"
        printf '%s\n' "$3" >> "$ZSHRC_TMUX_LOG"
        printf '===\n' >> "$ZSHRC_TMUX_LOG"
    fi
    return 0
}
source "$ZSHRC_FILE_TO_SOURCE"
DRIVEREOF
    ZSHRC_TMUX_LOG="$logf" ZSHRC_FILE_TO_SOURCE="$zshrc" TMUX=1 zsh -f "$driver" \
        >"$logf.stdout" 2>"$logf.stderr"

    # Parse the "key\nvalue\n===\n" triples.
    local devval agentval key val
    devval=""; agentval=""
    while IFS= read -r key && IFS= read -r val && IFS= read -r sep; do
        [ "$sep" = "===" ] || break
        case "$key" in
            "@developer") devval="$val" ;;
            "@claude_agent") agentval="$val" ;;
        esac
    done < "$logf"

    test_start "$(basename "$zshrc"): @developer tmux set-option is byte-exact"
    if [ "$devval" = "$e_dev" ]; then test_pass; else test_fail "expected [$e_dev] got [$devval]. stderr: $(cat "$logf.stderr" 2>/dev/null)"; fi

    test_start "$(basename "$zshrc"): @claude_agent tmux set-option is byte-exact (team-id-character)"
    if [ "$agentval" = "spacedock-$e_char" ]; then test_pass; else test_fail "expected [spacedock-$e_char] got [$agentval]"; fi

    test_start "$(basename "$zshrc"): SESSION_TITLE line is sane (uppercased character slug)"
    local expected_title
    expected_title=$(echo "$e_char" | tr '[:lower:]-' '[:upper:] ')
    if grep -qF "SESSION_TITLE='$expected_title'" "$zshrc"; then
        test_pass
    else
        test_fail "expected SESSION_TITLE='$expected_title' line not found in $zshrc: $(grep '^SESSION_TITLE=' "$zshrc" 2>/dev/null)"
    fi
}

_check_zshrc_tmux_lines "$HOME/.zshrc_spacedock_repair" "$E_SCOTTY_DEV" "scotty-sd"
_check_zshrc_tmux_lines "$HOME/.zshrc_spacedock_dockmaster" "$E_UNA_DEV" "sisko-sd"
_check_zshrc_tmux_lines "$HOME/.zshrc_spacedock_diagnostics" "$E_OBRIEN_DEV" "geordi-sd"
_check_zshrc_tmux_lines "$HOME/.zshrc_spacedock_analysis" "$E_SPOCK_DEV" "spock-sd"

# ─── No PWNED_* side-effect files anywhere in the sandbox, fixed run ────────
test_start "No PWNED_* side-effect files exist anywhere in the sandbox after the fixed-generator run"
PWNED_FOUND=$(find "$TEST_TMP_DIR" -name 'PWNED_*' 2>/dev/null)
if [ -z "$PWNED_FOUND" ]; then
    test_pass
else
    test_fail "PWNED file(s) found — a hostile persona field actually executed: $PWNED_FOUND"
fi

# ─── bash -n on the extracted generators, both under 3.2 and (if available)
#     a real bash 5, per the ticket's cross-version requirement ────────────
test_start "bash -n on the extracted startup generator under /bin/bash (3.2)"
if /bin/bash -n "$STARTUP_EXTRACTED" 2>"$TEST_TMP_DIR/synb32.err"; then test_pass; else test_fail "$(cat "$TEST_TMP_DIR/synb32.err")"; fi

if [ -x /opt/homebrew/bin/bash ]; then
    test_start "bash -n on the extracted startup generator under bash 5 (/opt/homebrew/bin/bash)"
    if /opt/homebrew/bin/bash -n "$STARTUP_EXTRACTED" 2>"$TEST_TMP_DIR/synb5.err"; then test_pass; else test_fail "$(cat "$TEST_TMP_DIR/synb5.err")"; fi
else
    test_skip "bash 5 assertion" "no bash 5 found at /opt/homebrew/bin/bash on this machine"
fi

echo ""
echo "Results: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed, ${_SKIP_COUNT} skipped"
if [ "$_FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
exit 0
