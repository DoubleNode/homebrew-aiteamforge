#!/bin/bash
# test-xaca-1237-render-only-modes.sh
#
# XACA-1237-004 regression suite. install-team.sh's two RENDER-ONLY modes
# (--agent-scripts-only, --connect-only) were running the full-install preamble:
# the port allocator, the "Installing Team" banner and _ensure_org_config. The
# last prompts on /dev/tty and does `return 1` when there is no tty, so a
# non-interactive `aiteamforge upgrade` backfill died under `set -e` before
# rendering anything; it also wrote ~/.aiteamforge/organization.yaml as a side
# effect of a "render only" run.
#
# Contract (XACA-1237 gating design, subitem 002):
#   --agent-scripts-only : skips port allocation, banner, org config.
#   --connect-only       : skips banner, org config; STILL allocates the port
#                          (the connect templates substitute it).
#   full install         : unchanged (static checks only; never run here).
#
# CASES
#   A  AS: exit 0, no organization.yaml, no banner / port chatter, scripts
#      rendered, nothing written outside <team>/scripts.
#   B  AS with a band-exhausted port allocator: still exit 0 (proves the port
#      block is SKIPPED, not merely succeeding).
#   C  CO: exit 0, no organization.yaml, no banner, connect script rendered
#      with a numeric port.
#   D  static ordering: AS exit after XACA-0485 + XACA-0498; full install still
#      calls _ensure_org_config / prints the banner under the render-only gate.
#
# NO-TTY: every installer run goes through a fork+os.setsid() wrapper so
# /dev/tty is genuinely unavailable (a plain setsid fails with EPERM when the
# caller is a session leader, hence the fork). The suite asserts the wrapper
# really lacks a tty, so a pass cannot be vacuous on a developer's terminal.
#
# Override the installer under test (negative control):
#   XACA1237_INSTALLER=/path/to/orig-install-team.sh bash tests/test-xaca-1237-render-only-modes.sh
# A non-default installer is copied into a shim tap layout whose lib/ and
# share/ symlink to this tap (the script derives HOMEBREW_TAP_ROOT from its own
# location).
#
# Sandboxing: HOME, AITEAMFORGE_DIR, AITEAMFORGE_CONFIG and --install-dir are all
# under TEST_TMP_DIR. spacedock has empty TEAM_BREW_DEPS and both modes exit
# before any brew section. Runs under /bin/bash 3.2.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_INSTALLER="$TAP_ROOT/libexec/installers/install-team.sh"
INSTALLER_UNDER_TEST="${XACA1237_INSTALLER:-$DEFAULT_INSTALLER}"

if [ ! -f "$INSTALLER_UNDER_TEST" ]; then
    echo "FATAL: installer under test not found: $INSTALLER_UNDER_TEST" >&2
    exit 1
fi

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
    TEST_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/xaca1237-test.XXXXXX")"
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
            echo "FATAL SANDBOX ESCAPE: '$1' is not under TEST_TMP_DIR ($TEST_TMP_DIR) — refusing to proceed." >&2
            exit 1
            ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# Installer under test, placed in a shim tap layout when it is not the real one.
# ─────────────────────────────────────────────────────────────────────────────
INSTALLER="$INSTALLER_UNDER_TEST"
if [ "$INSTALLER_UNDER_TEST" != "$DEFAULT_INSTALLER" ]; then
    SHIM_TAP="$TEST_TMP_DIR/shim-tap"
    mkdir -p "$SHIM_TAP/libexec/installers"
    ln -s "$TAP_ROOT/libexec/lib" "$SHIM_TAP/libexec/lib"
    ln -s "$TAP_ROOT/share" "$SHIM_TAP/share"
    cp "$INSTALLER_UNDER_TEST" "$SHIM_TAP/libexec/installers/install-team.sh"
    INSTALLER="$SHIM_TAP/libexec/installers/install-team.sh"
    echo "NOTE: installer under test is an override: $INSTALLER_UNDER_TEST"
fi
_assert_sandboxed_or_real() { :; }

# ─────────────────────────────────────────────────────────────────────────────
# No-tty wrapper (fork + setsid + exec). Parent propagates the child's exit code.
# ─────────────────────────────────────────────────────────────────────────────
NOTTY_PY="$TEST_TMP_DIR/notty.py"
cat > "$NOTTY_PY" <<'PYEOF'
import os, sys
pid = os.fork()
if pid == 0:
    os.setsid()
    os.execvp(sys.argv[1], sys.argv[1:])
_, status = os.waitpid(pid, 0)
sys.exit(os.waitstatus_to_exitcode(status))
PYEOF

test_start "Preflight: wrapper really detaches the controlling terminal (/dev/tty unusable)"
NOTTY_PROBE_EXIT=0
python3 -I "$NOTTY_PY" bash -c 'exec 3</dev/tty' </dev/null >/dev/null 2>&1 || NOTTY_PROBE_EXIT=$?
NOTTY_CTRL_EXIT=0
# Self-check of the probe: the same probe must be capable of succeeding
# somewhere is not provable without a tty, so assert the failure is the
# /dev/tty open itself (not e.g. a missing python) by exit code 1 from bash.
if [ "$NOTTY_PROBE_EXIT" -ne 0 ]; then
    NOTTY_ERR="$(python3 -I "$NOTTY_PY" bash -c 'exec 3</dev/tty' </dev/null 2>&1 >/dev/null || true)"
    case "$NOTTY_ERR" in
        *"/dev/tty"*) test_pass ;;
        *) test_fail "probe exited $NOTTY_PROBE_EXIT but not because /dev/tty failed: $NOTTY_ERR" ;;
    esac
else
    test_fail "wrapped child could open /dev/tty — the suite would not be exercising the no-tty path"
fi
if [ "$NOTTY_PROBE_EXIT" -eq 0 ]; then
    echo "Results: ${_PASS_COUNT:-0} passed, ${_FAIL_COUNT:-1} failed"
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Sandbox fixture helper. $1 = case name; sets CASE_HOME / CASE_ATF / CASE_CFG.
# ─────────────────────────────────────────────────────────────────────────────
_new_case() {
    local name="$1"
    CASE_HOME="$TEST_TMP_DIR/$name/home"
    CASE_ATF="$TEST_TMP_DIR/$name/aiteamforge"
    CASE_CFG="$CASE_HOME/.aiteamforge/team-paths.json"
    _assert_sandboxed "$CASE_HOME"; _assert_sandboxed "$CASE_ATF"; _assert_sandboxed "$CASE_CFG"
    mkdir -p "$CASE_HOME/.aiteamforge" "$CASE_ATF/lcars-ports"
    # Pre-existing state the render-only modes must leave untouched.
    printf '{"schema_version": 2, "teams": {}}\n' > "$CASE_CFG"
    printf '{"teams": []}\n' > "$CASE_ATF/.aiteamforge-config"
    printf '8999\n' > "$CASE_ATF/lcars-ports/sentinel.port"
}

# Run the installer with no tty, sandboxed env, no org config, stdin /dev/null.
# PYTHONDONTWRITEBYTECODE: Apple's /usr/bin/python3 caches bytecode under
# $HOME/Library/Caches/com.apple.python, which case A's whole-sandbox snapshot
# would otherwise report as an installer write.
# $1 = out-file prefix; remaining args = installer args. Sets RUN_EXIT.
_run_installer() {
    local prefix="$1"; shift
    RUN_EXIT=0
    ( cd "$TEST_TMP_DIR" && \
      env -u TMUX -u TMUX_PANE -u TMUX_SOCKET -u AITEAMFORGE_ORG_CONFIG \
        HOME="$CASE_HOME" AITEAMFORGE_DIR="$CASE_ATF" AITEAMFORGE_CONFIG="$CASE_CFG" \
        NON_INTERACTIVE=true \
        PYTHONDONTWRITEBYTECODE=1 \
        python3 -I "$NOTTY_PY" bash "$INSTALLER" "$@" --install-dir "$CASE_ATF" \
        </dev/null >"$prefix.out" 2>"$prefix.err" ) || RUN_EXIT=$?
    cat "$prefix.out" "$prefix.err" > "$prefix.all"
}

_snapshot() { ( cd "$1" && find . -type f -o -type l | sort | while IFS= read -r f; do printf '%s %s\n' "$(shasum "$f" 2>/dev/null | awk '{print $1}')" "$f"; done ); }

_no_org_yaml() {
    local found
    found="$(find "$CASE_HOME" "$CASE_ATF" -name 'organization.yaml' 2>/dev/null)"
    [ -z "$found" ]
}

_forbidden_output() {
    # prints first offending pattern found in $1, if any
    local f="$1" p
    for p in "Installing Team" "allocated port" "reusing existing port" \
             "needs an interactive terminal" "Organization slug"; do
        if grep -qiF -- "$p" "$f"; then echo "$p"; return 0; fi
    done
    return 1
}

_diag() { echo "exit=$RUN_EXIT stdout: $(head -c 600 "$1.out" | tr '\n' '|') stderr: $(head -c 600 "$1.err" | tr '\n' '|')"; }

# ═══════════════════════════════════════════════════════════════════════════
# CASE A — --agent-scripts-only
# ═══════════════════════════════════════════════════════════════════════════
_new_case case-a
A_PREFIX="$TEST_TMP_DIR/run-case-a"
mkdir -p "$CASE_ATF/spacedock"
SNAP_A_BEFORE="$TEST_TMP_DIR/snap-a-before.txt"
_snapshot "$TEST_TMP_DIR/case-a" > "$SNAP_A_BEFORE"
_run_installer "$A_PREFIX" spacedock --agent-scripts-only

test_start "A: --agent-scripts-only exits 0 with no tty and no organization.yaml"
if [ "$RUN_EXIT" -eq 0 ]; then test_pass; else test_fail "$(_diag "$A_PREFIX")"; fi

test_start "A: organization.yaml was NOT created"
if _no_org_yaml; then test_pass; else test_fail "found: $(find "$CASE_HOME" "$CASE_ATF" -name organization.yaml)"; fi

test_start "A: no banner / port-allocation / org-prompt output"
A_BAD="$(_forbidden_output "$A_PREFIX.all" || true)"
if [ -z "$A_BAD" ]; then test_pass; else test_fail "output contains '$A_BAD' — $(_diag "$A_PREFIX")"; fi

test_start "A: per-agent scripts rendered under <team>/scripts"
A_COUNT=$(find "$CASE_ATF/spacedock/scripts" -name 'spacedock-*-startup.sh' 2>/dev/null | wc -l | tr -d ' ')
if [ "${A_COUNT:-0}" -ge 1 ]; then test_pass; else test_fail "no spacedock-*-startup.sh under $CASE_ATF/spacedock/scripts (count=$A_COUNT)"; fi

test_start "A: nothing written outside <team>/scripts (team-paths.json, .aiteamforge-config, lcars-ports unchanged)"
SNAP_A_AFTER="$TEST_TMP_DIR/snap-a-after.txt"
_snapshot "$TEST_TMP_DIR/case-a" > "$SNAP_A_AFTER"
A_OUTSIDE="$(diff "$SNAP_A_BEFORE" "$SNAP_A_AFTER" | grep -E '^[<>]' | grep -vE ' \./aiteamforge/spacedock/scripts/' || true)"
if [ -z "$A_OUTSIDE" ]; then test_pass; else test_fail "unexpected changes: $A_OUTSIDE"; fi

# ═══════════════════════════════════════════════════════════════════════════
# CASE B — --agent-scripts-only with a band-EXHAUSTED allocator.
# spacedock's band is [8380, 8390). Occupy all 10 ports under other keys so
# aiteamforge_compute_instance_port returns 1 ("Port band exhausted") and the
# unpatched installer hits `exit 1` on its allocator-failure branch.
# ═══════════════════════════════════════════════════════════════════════════
_new_case case-b
B_PREFIX="$TEST_TMP_DIR/run-case-b"
python3 -I - "$CASE_CFG" <<'PYEOF'
import json, sys
teams = {"filler-%d" % i: {"lcars_port": 8380 + i} for i in range(10)}
json.dump({"schema_version": 2, "teams": teams}, open(sys.argv[1], "w"))
PYEOF
# Control: prove the allocator really fails on this fixture (so a pass below is
# attributable to the port block being skipped, not to a harmless fixture).
B_CTRL_EXIT=0
( env -u TMUX -u TMUX_PANE HOME="$CASE_HOME" AITEAMFORGE_CONFIG="$CASE_CFG" \
    bash -c 'source "$1/libexec/lib/aiteamforge-paths.sh" && aiteamforge_compute_instance_port spacedock "$2"' _ "$TAP_ROOT" "$CASE_CFG" \
    </dev/null >"${B_PREFIX}-ctrl.out" 2>"${B_PREFIX}-ctrl.err" ) || B_CTRL_EXIT=$?
test_start "B: fixture control — allocator itself fails on the exhausted band"
if [ "$B_CTRL_EXIT" -ne 0 ] && grep -qi "exhausted" "${B_PREFIX}-ctrl.err"; then
    test_pass
else
    test_fail "allocator exit=$B_CTRL_EXIT stderr=$(head -c 300 "${B_PREFIX}-ctrl.err") — fixture does not break the allocator"
fi
_run_installer "$B_PREFIX" spacedock --agent-scripts-only

test_start "B: --agent-scripts-only exits 0 even though the port allocator would fail"
if [ "$RUN_EXIT" -eq 0 ]; then test_pass; else test_fail "$(_diag "$B_PREFIX")"; fi

test_start "B: scripts still rendered and no organization.yaml"
B_COUNT=$(find "$CASE_ATF/spacedock/scripts" -name 'spacedock-*-startup.sh' 2>/dev/null | wc -l | tr -d ' ')
if [ "${B_COUNT:-0}" -ge 1 ] && _no_org_yaml; then test_pass; else test_fail "scripts=$B_COUNT org_yaml_absent=$(_no_org_yaml && echo yes || echo no)"; fi

# ═══════════════════════════════════════════════════════════════════════════
# CASE C — --connect-only
# ═══════════════════════════════════════════════════════════════════════════
_new_case case-c
C_PREFIX="$TEST_TMP_DIR/run-case-c"
_run_installer "$C_PREFIX" spacedock --connect-only

test_start "C: --connect-only exits 0 with no tty and no organization.yaml"
if [ "$RUN_EXIT" -eq 0 ]; then test_pass; else test_fail "$(_diag "$C_PREFIX")"; fi

test_start "C: organization.yaml was NOT created"
if _no_org_yaml; then test_pass; else test_fail "found: $(find "$CASE_HOME" "$CASE_ATF" -name organization.yaml)"; fi

test_start "C: no 'Installing Team' banner / org-prompt output"
C_BAD=""
for p in "Installing Team" "needs an interactive terminal" "Organization slug"; do
    if grep -qiF -- "$p" "$C_PREFIX.all"; then C_BAD="$p"; break; fi
done
if [ -z "$C_BAD" ]; then test_pass; else test_fail "output contains '$C_BAD' — $(_diag "$C_PREFIX")"; fi

test_start "C: connect script rendered with a numeric port substituted"
C_CONNECT="$CASE_ATF/spacedock-connect.sh"
if [ -f "$C_CONNECT" ] && ! grep -q '{{TEAM_LCARS_PORT}}' "$C_CONNECT" \
   && grep -Eq '^LCARS_PORT="[0-9]+"' "$C_CONNECT"; then
    test_pass
else
    test_fail "missing or unsubstituted: $C_CONNECT ($(grep -n 'LCARS_PORT' "$C_CONNECT" 2>/dev/null | head -3 | tr '\n' '|'))"
fi

# ═══════════════════════════════════════════════════════════════════════════
# CASE D — static ordering / full-install gate
# ═══════════════════════════════════════════════════════════════════════════
D_EXIT_LINE=$(grep -n '^if \[\[ "\$AGENT_SCRIPTS_ONLY" == "true" \]\]; then' "$INSTALLER" | head -1 | cut -d: -f1)
D_EXIT_COUNT=$(grep -c '^if \[\[ "\$AGENT_SCRIPTS_ONLY" == "true" \]\]; then' "$INSTALLER")
D_0485_LINE=$(grep -n 'XACA-0485' "$INSTALLER" | head -1 | cut -d: -f1)
D_0498_LINE=$(grep -n 'XACA-0498' "$INSTALLER" | head -1 | cut -d: -f1)
D_LOOSE_LINE=$(grep -n 'AGENT_SCRIPTS_ONLY.*==.*true' "$INSTALLER" | head -1 | cut -d: -f1)

test_start "D: exactly one anchored AS-exit 'if' exists and it is the FIRST loose match (1215 Case C locator stays honest)"
if [ "$D_EXIT_COUNT" = "1" ] && [ -n "$D_EXIT_LINE" ] && [ "$D_EXIT_LINE" = "$D_LOOSE_LINE" ]; then
    test_pass
else
    test_fail "anchored=$D_EXIT_LINE (count $D_EXIT_COUNT) first-loose=$D_LOOSE_LINE"
fi

test_start "D: AS exit (line $D_EXIT_LINE) is after the XACA-0485 resolution and the XACA-0498 guard"
D_LAST_0485=$(grep -n 'XACA-0485' "$INSTALLER" | awk -F: -v e="${D_EXIT_LINE:-0}" '$1<e{l=$1} END{print l}')
D_LAST_0498=$(grep -n 'XACA-0498' "$INSTALLER" | awk -F: -v e="${D_EXIT_LINE:-0}" '$1<e{l=$1} END{print l}')
if [ -n "$D_EXIT_LINE" ] && [ -n "$D_LAST_0485" ] && [ -n "$D_LAST_0498" ] \
   && [ "$D_0485_LINE" -lt "$D_EXIT_LINE" ] && [ "$D_0498_LINE" -lt "$D_EXIT_LINE" ]; then
    # And the guard must be an actual refusal, not just a comment mention.
    D_GUARD_BODY=$(sed -n "${D_0498_LINE},${D_EXIT_LINE}p" "$INSTALLER")
    if printf '%s\n' "$D_GUARD_BODY" | grep -q 'exit 1'; then test_pass
    else test_fail "no 'exit 1' between first XACA-0498 mention (L$D_0498_LINE) and AS exit (L$D_EXIT_LINE)"; fi
else
    test_fail "exit=$D_EXIT_LINE 0485=$D_0485_LINE (last-before=$D_LAST_0485) 0498=$D_0498_LINE (last-before=$D_LAST_0498)"
fi

test_start "D: full install still calls _ensure_org_config, gated only by _XACA1237_RENDER_ONLY"
D_ORG_CALLS=$(grep -nE '^[[:space:]]*(\[\[ .* \]\] \|\| )?_ensure_org_config[[:space:]]*(#.*)?$' "$INSTALLER")
if [ -n "$D_ORG_CALLS" ] \
   && printf '%s\n' "$D_ORG_CALLS" | grep -q '_XACA1237_RENDER_ONLY' ; then
    test_pass
else
    test_fail "bare/gated _ensure_org_config call not found in expected shape: [$D_ORG_CALLS]"
fi

test_start "D: full-install banner ('Installing Team') is still present and gated by _XACA1237_RENDER_ONLY"
D_BANNER_LINE=$(grep -n 'Installing Team' "$INSTALLER" | head -1 | cut -d: -f1)
if [ -n "$D_BANNER_LINE" ] \
   && sed -n "$((D_BANNER_LINE>6 ? D_BANNER_LINE-6 : 1)),${D_BANNER_LINE}p" "$INSTALLER" | grep -q '_XACA1237_RENDER_ONLY'; then
    test_pass
else
    test_fail "banner at L${D_BANNER_LINE:-none} has no _XACA1237_RENDER_ONLY gate within 6 lines above it"
fi

if $_STANDALONE; then
    echo ""
    echo "Results: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    [ "$_FAIL_COUNT" -eq 0 ] && exit 0 || exit 1
fi
