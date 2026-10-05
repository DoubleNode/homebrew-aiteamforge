#!/bin/bash

# test-xaca-1240-install-team-routing.sh
# Regression test for XACA-1240: install-team.sh script-writer ROUTING.
#
# REGRESSION INTENT: commit f03b44f6 converted install-team.sh's script writers
# to `_aitf_atomic_write_script <dst> <cmd...>` but MISROUTED several of them:
#   - the startup-template render was wrapped with $SHUTDOWN_SCRIPT as <dst>;
#   - the non-parametric connect render was wrapped with $disconnect_script;
#   - the real shutdown and disconnect seds lost their `> "$X"` redirect and
#     printed the rendered script to STDOUT.
# Every pre-existing test only checked that SOME file existed, so none noticed.
# This suite gives each role (connect/disconnect/startup/shutdown) a template
# with a DISTINCT marker and asserts each destination holds ITS OWN role (and
# no other role's), that nothing leaked to stdout, placeholders and
# TEAM_AGENT_WINDOWS_CONFIG were expanded, no temp files remain, and a
# pre-existing target got a NEW inode (atomic).
#
# Harness: the real writer code is awk-extracted from install-team.sh
#   - _render_connect_disconnect()                (function)
#   - the startup-template branch  (elif [[ -f "$STARTUP_TEMPLATE" ]] ... fi)
#   - the shutdown-template branch (elif [[ -f "$SHUTDOWN_TEMPLATE" ]] ... fi)
# and eval'd in a sandboxed child under `set -euo pipefail` (as the installer
# runs). Whole-script execution is NOT used: install-team.sh at top level
# allocates ports, writes the registry and calls many external tools.
# Stubbed in the child: _is_parametric_team, _has_preauthored_connect,
# _resolve_parametric_defaults, _extract_session_order, _xaca0483_install_script.
#
# Cases (positive = real file; every mutant must FAIL the same checks):
#   NONPARAM   flat templates present: connect, disconnect, startup, shutdown
#   FALLBACK   startup/shutdown templates absent -> heredoc fallbacks
#              (connect/disconnect have NO heredoc fallback by design: they
#              only warn and skip, which is asserted.)
#   PARAM      parametric connect/disconnect templates
#   MUT-1..5   scratch copies of install-team.sh with f03b44f6-class bugs
#              re-introduced by exact-string python replacement
#
#   PARAMSS    parametric startup/shutdown: the REAL _xaca0483_install_script
#              (awk-extracted, with the real atomic-write.sh) installs
#              share/scripts/teams/<id>-{startup,shutdown}.sh; asserts own
#              role per dst, dev-team path rewrite, mode kept (+x), new inode,
#              helpers installed, and that the later shutdown-TEMPLATE branch
#              is a no-op for parametric teams.
#   MUT-6/7    parametric startup routed to $SHUTDOWN_SCRIPT; and
#              _xaca0483_install_script reverted to the in-place `> "$dst"`.
#
# Unreachable by this harness: the hand-authored XACA-0853 connect path (it
# uses the same real _xaca0483_install_script, covered by PARAMSS).
#
# All filesystem activity is sandboxed to TEST_TMP_DIR with HOME in the sandbox
# and TMUX stripped. Never runs tmux, launchctl or brew. Never touches real
# $HOME or ~/aiteamforge.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_TEAM="$TAP_ROOT/libexec/installers/install-team.sh"
ATOMIC_SH="$TAP_ROOT/libexec/lib/atomic-write.sh"

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

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: prerequisite 'python3' not on PATH" >&2
    exit 2
fi

if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca1240-routing.XXXXXX)"
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

# Sandbox BEFORE anything else.
SBX="$TEST_TMP_DIR/xaca1240-routing"
mkdir -p "$SBX/home"
export AITEAMFORGE_DIR="$SBX/aiteamforge"
export HOME="$SBX/home"
unset TMUX TMUX_PANE

_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
_inode() { stat -c %i "$1" 2>/dev/null || stat -f %i "$1"; }

# ── Mutants: exact-string replacement in a scratch copy (never the real file) ─
# mutate <out> <old> <new>: fails (rc 1) unless <old> occurs exactly once.
mutate() {
    python3 - "${4:-$INSTALL_TEAM}" "$1" "$2" "$3" <<'PY'
import sys
src, out, old, new = sys.argv[1:5]
t = open(src, encoding='utf-8').read()
if t.count(old) != 1:
    sys.stderr.write("mutation anchor count=%d for: %s\n" % (t.count(old), old))
    sys.exit(1)
open(out, 'w', encoding='utf-8').write(t.replace(old, new))
PY
}
MUT_DIR="$SBX/mutants"
mkdir -p "$MUT_DIR"
# MUT-1: f03b44f6 bug -- startup render wrapped with $SHUTDOWN_SCRIPT as dst.
mutate "$MUT_DIR/m1.sh" \
    '_aitf_atomic_write_script "$STARTUP_SCRIPT" cat "${STARTUP_SCRIPT}.tmp"' \
    '_aitf_atomic_write_script "$SHUTDOWN_SCRIPT" cat "${STARTUP_SCRIPT}.tmp"'; M1=$?
# MUT-2: f03b44f6 bug -- non-parametric connect wrapped with $disconnect_script.
mutate "$MUT_DIR/m2.sh" \
    '_aitf_atomic_write_script "$connect_script" cat "${connect_script}.tmp"' \
    '_aitf_atomic_write_script "$disconnect_script" cat "${connect_script}.tmp"'; M2=$?
# MUT-3: f03b44f6 bug -- shutdown sed lost its redirect (prints to stdout).
mutate "$MUT_DIR/m3.sh" \
    '_aitf_atomic_write_script "$SHUTDOWN_SCRIPT" sed -e "s|{{TEAM_ID}}|$INSTANCE_ID|g"' \
    'sed -e "s|{{TEAM_ID}}|$INSTANCE_ID|g"'; M3=$?
# MUT-4: f03b44f6 bug -- non-parametric disconnect sed lost its redirect.
mutate "$MUT_DIR/m4.sh" \
    '_aitf_atomic_write_script "$disconnect_script" sed -e "s|{{TEAM_ID}}|$INSTANCE_ID|g"' \
    'sed -e "s|{{TEAM_ID}}|$INSTANCE_ID|g"'; M4=$?
# MUT-5: startup heredoc fallback routed to $SHUTDOWN_SCRIPT.
mutate "$MUT_DIR/m5.sh" \
    '_aitf_atomic_write_script "$STARTUP_SCRIPT" cat <<EOF' \
    '_aitf_atomic_write_script "$SHUTDOWN_SCRIPT" cat <<EOF'; M5=$?

# MUT-6: parametric startup install routed to $SHUTDOWN_SCRIPT.
mutate "$MUT_DIR/m6.sh" \
    '_xaca0483_install_script "$HOMEBREW_TAP_ROOT/share/scripts/teams/${TEAM_ID}-startup.sh" "$STARTUP_SCRIPT"' \
    '_xaca0483_install_script "$HOMEBREW_TAP_ROOT/share/scripts/teams/${TEAM_ID}-startup.sh" "$SHUTDOWN_SCRIPT"'; M6=$?
# MUT-7: _xaca0483_install_script reverted to the pre-fix in-place redirect.
mutate "$MUT_DIR/m7a.sh" \
    '    _aitf_atomic_write_script "$dst" sed -e "s|\$HOME/dev-team/iterm2_window_manager.py|' \
    '    sed -e "s|\$HOME/dev-team/iterm2_window_manager.py|'; M7=$?
if [ "$M7" -eq 0 ]; then
    mutate "$MUT_DIR/m7.sh" \
        '        "$src"
}

# XACA-0853: does this team ship' \
        '        "$src" > "$dst"
}

# XACA-0853: does this team ship' "$MUT_DIR/m7a.sh"; M7=$?
fi

# MUT-8: hand-authored (XACA-0853) connect install routed to $disconnect_script.
mutate "$MUT_DIR/m8.sh" \
    '"$HOMEBREW_TAP_ROOT/share/scripts/teams/${TEAM_ID}-connect.sh" "$connect_script"' \
    '"$HOMEBREW_TAP_ROOT/share/scripts/teams/${TEAM_ID}-connect.sh" "$disconnect_script"'; M8=$?

# ── Child driver ─────────────────────────────────────────────────────────────
CHILD="$SBX/child.sh"
cat > "$CHILD" <<'CHILD_EOF'
#!/bin/bash
# usage: child.sh <install-team.sh> <sandbox> <mode: nonparam|fallback|param> <atomic-write.sh>
IT="$1"; SB="$2"; MODE="$3"; ATOMIC="$4"
unset TMUX TMUX_PANE
export AITEAMFORGE_DIR="$SB/aiteamforge" HOME="$SB/home"
HOMEBREW_TAP_ROOT="$SB/tap"
set -euo pipefail
. "$ATOMIC"

_ex_fn() { awk -v fn="$1" '$0 ~ ("^" fn "\\(\\) \\{") {c=1} c {print} c && /^}$/ {exit}' "$IT"; }
# branch: from its `elif` line to the first column-0 `fi`, as an if-chain
_ex_branch() { { echo 'if false; then :'; awk -v pat="$1" '$0 == pat {c=1} c {print} c && /^fi$/ {exit}' "$IT"; }; }

RCD="$(_ex_fn _render_connect_disconnect)"
SUB="$(_ex_branch 'elif [[ -f "$STARTUP_TEMPLATE" ]]; then')"
SHB="$(_ex_branch 'elif [[ -f "$SHUTDOWN_TEMPLATE" ]]; then')"
[ -n "$RCD" ] || { echo "CHILD-FATAL: cannot extract _render_connect_disconnect" >&2; exit 90; }
[ "$(printf '%s\n' "$SUB" | wc -l)" -gt 5 ] || { echo "CHILD-FATAL: cannot extract startup branch" >&2; exit 91; }
[ "$(printf '%s\n' "$SHB" | wc -l)" -gt 5 ] || { echo "CHILD-FATAL: cannot extract shutdown branch" >&2; exit 92; }
eval "$RCD"

# Stubs (callers of things that are out of scope for the writers under test)
# hand|handhalf: the REAL predicate (extracted) -- it answers from the sandbox
# tap's share/scripts/teams/ contents. Every other mode: stub false.
case "$MODE" in
    hand|handhalf)
        HPC="$(_ex_fn _has_preauthored_connect)"
        [ -n "$HPC" ] || { echo "CHILD-FATAL: cannot extract _has_preauthored_connect" >&2; exit 96; }
        eval "$HPC" ;;
    *) _has_preauthored_connect() { return 1; } ;;
esac
# hand modes report parametric=true so a broken branch ORDER would render the
# parametric template instead (and be caught by the TEMPLATE- marker check).
_is_parametric_team() { [[ "$MODE" == param || "$MODE" == hand* ]]; }
_resolve_parametric_defaults() { _DERIVED_DEFAULT_PROJECT=proj; _DERIVED_DEFAULT_GROUP=grp; _DERIVED_MATCH_COUNT=1; }
_extract_session_order() { echo "s1 s2"; }
# REAL _xaca0483_install_script (extracted from the file under test)
XIS="$(_ex_fn _xaca0483_install_script)"
[ -n "$XIS" ] || { echo "CHILD-FATAL: cannot extract _xaca0483_install_script" >&2; exit 93; }
eval "$XIS"
PB="$(awk '{a[NR]=$0} END{for(i=1;i<=NR;i++) if(a[i]=="if [[ \"$_PARAMETRIC_MODE\" == \"true\" ]]; then" && a[i+1] ~ /^    _xaca0483_install_script/){for(j=i;j<=NR && a[j] !~ /^elif/;j++) print a[j]; print "fi"; exit}}' "$IT")"
SHC="$(awk '{a[NR]=$0} END{for(i=1;i<=NR;i++) if(a[i]=="if [[ \"$_PARAMETRIC_MODE\" == \"true\" ]]; then" && a[i+1] ~ /^    :  # Shutdown/){for(j=i;j<=NR;j++){print a[j]; if(a[j]=="fi") exit}}}' "$IT")"

TEAM_ID=zqteam; INSTANCE_ID=zqinst; TEAM_NAME="Zq Team"; TEAM_THEME="Zq Theme"
TEAM_SHIP=zqship; TEAM_LCARS_PORT=8765; TEAM_TERMINAL_LIST="a b"
TEAM_WORKING_DIR="$SB/work"; IS_PROJECT_TEAM=false; REQUIRES_CLIENT=false
TEAM_PERSONA_DEPLOY_MODE=""; TEAM_REQUIRES_CLIENT_ID=false
RESOLVED_PROJECT=""; RESOLVED_CLIENT=""; TEAM_TMUX_SOCKET=""; TEAM_LCARS_PORT_BASE=8700
TEAM_AGENT_WINDOWS_CONFIG='AGENT_WINDOWS_zq="WINMARK-ONE"
AGENT_WINDOWS_zr="WINMARK-TWO"
'
STARTUP_TEMPLATE="$HOMEBREW_TAP_ROOT/share/templates/team-startup.sh.template"
SHUTDOWN_TEMPLATE="$HOMEBREW_TAP_ROOT/share/templates/team-shutdown.sh.template"
STARTUP_SCRIPT="$AITEAMFORGE_DIR/${INSTANCE_ID}-startup.sh"
SHUTDOWN_SCRIPT="$AITEAMFORGE_DIR/${INSTANCE_ID}-shutdown.sh"
TEAM_STARTUP_SCRIPT="${INSTANCE_ID}-startup.sh"
TEAM_SHUTDOWN_SCRIPT="${INSTANCE_ID}-shutdown.sh"

if [ "$MODE" = paramss ]; then
    _PARAMETRIC_MODE=true
    STARTUP_SCRIPT="$AITEAMFORGE_DIR/${TEAM_ID}-startup.sh"
    SHUTDOWN_SCRIPT="$AITEAMFORGE_DIR/${TEAM_ID}-shutdown.sh"
    TEAM_STARTUP_SCRIPT="${TEAM_ID}-startup.sh"
    TEAM_SHUTDOWN_SCRIPT="${TEAM_ID}-shutdown.sh"
    [ "$(printf '%s\n' "$PB" | wc -l)" -gt 10 ] || { echo "CHILD-FATAL: cannot extract parametric block" >&2; exit 94; }
    [ "$(printf '%s\n' "$SHC" | wc -l)" -gt 5 ] || { echo "CHILD-FATAL: cannot extract shutdown chain" >&2; exit 95; }
    eval "$PB"
    eval "$SHC"
    exit 0
fi
_render_connect_disconnect
case "$MODE" in
    nonparam|fallback) eval "$SUB"; eval "$SHB" ;;
esac
CHILD_EOF

# Build a sandbox tap + pre-existing OLD targets. $1 name, $2 mode.
make_sandbox() {
    local name="$1" mode="$2" b="$SBX/$1"
    rm -rf "$b"
    mkdir -p "$b/home" "$b/work" "$b/aiteamforge/scripts" "$b/tap/share/templates" "$b/tap/share/scripts"
    local t="$b/tap/share/templates"
    if [ "$mode" = paramss ]; then
        :
    elif [ "$mode" = hand ] || [ "$mode" = handhalf ]; then
        # Templates that MUST NOT be used (TEMPLATE- marker) + hand-authored sources.
        printf '#!/bin/bash\nTEMPLATE-FLAT-CONNECT\n' > "$t/team-connect.sh.template"
        printf '#!/bin/bash\nTEMPLATE-FLAT-DISCONNECT\n' > "$t/team-disconnect.sh.template"
        printf '#!/bin/bash\nTEMPLATE-PARAM-CONNECT\n' > "$t/team-connect-parametric.sh.template"
        printf '#!/bin/bash\nTEMPLATE-PARAM-DISCONNECT\n' > "$t/team-disconnect-parametric.sh.template"
        local hd="$b/tap/share/scripts/teams"
        mkdir -p "$hd"
        printf '#!/bin/bash\nROLE=connect\nID=zqteam\nDIR=$HOME/dev-team/scripts\n' > "$hd/zqteam-connect.sh"
        if [ "$mode" = hand ]; then
            printf '#!/bin/bash\nROLE=disconnect\nID=zqteam\nDIR=${HOME}/dev-team/scripts\n' > "$hd/zqteam-disconnect.sh"
        fi
    elif [ "$mode" = param ]; then
        printf '#!/bin/bash\nROLE=connect\nID={{TEAM_ID}}\nSOCK={{TEAM_SOCKET}}\n' > "$t/team-connect-parametric.sh.template"
        printf '#!/bin/bash\nROLE=disconnect\nID={{TEAM_ID}}\n' > "$t/team-disconnect-parametric.sh.template"
    else
        printf '#!/bin/bash\nROLE=connect\nID={{TEAM_ID}}\nSOCK={{TEAM_TMUX_SOCKET}}\n{{TEAM_AGENT_WINDOWS_CONFIG}}\n' > "$t/team-connect.sh.template"
        printf '#!/bin/bash\nROLE=disconnect\nID={{TEAM_ID}}\n' > "$t/team-disconnect.sh.template"
        if [ "$mode" = nonparam ]; then
            printf '#!/bin/bash\nROLE=startup\nID={{TEAM_ID}}\n{{TEAM_AGENT_WINDOWS_CONFIG}}\n' > "$t/team-startup.sh.template"
            printf '#!/bin/bash\nROLE=shutdown\nID={{TEAM_ID}}\n' > "$t/team-shutdown.sh.template"
        fi
    fi
    if [ "$mode" = paramss ]; then
        local sd="$b/tap/share/scripts/teams"
        mkdir -p "$sd/zqteam/scripts"
        printf '#!/bin/bash\nROLE=startup\nID=zqteam\nAWM=~/dev-team/iterm2_window_manager.py\nDIR=$HOME/dev-team/scripts\nABS=/Users/someone/dev-team/foo\n' > "$sd/zqteam-startup.sh"
        printf '#!/bin/bash\nROLE=shutdown\nID=zqteam\nDIR=${HOME}/dev-team/scripts\n' > "$sd/zqteam-shutdown.sh"
        printf '#!/bin/bash\nAGENT=~/dev-team/x\n' > "$sd/zqteam/scripts/agent.sh"
        echo '# dummy' > "$b/tap/share/scripts/kb-init-team-guard.sh"
        echo '# dummy' > "$b/tap/share/scripts/kb-init-team"
        printf 'FLAT-STARTUP-TEMPLATE\n' > "$t/team-startup.sh.template"
        printf 'FLAT-SHUTDOWN-TEMPLATE\n' > "$t/team-shutdown.sh.template"
        echo OLD-startup > "$b/aiteamforge/zqteam-startup.sh"; chmod 640 "$b/aiteamforge/zqteam-startup.sh"
        echo OLD-shutdown > "$b/aiteamforge/zqteam-shutdown.sh"; chmod 600 "$b/aiteamforge/zqteam-shutdown.sh"
    fi
    echo '# dummy' > "$b/tap/share/scripts/lcars-launch-helpers.sh"
    echo '# dummy' > "$b/tap/share/scripts/kb-run-marker.sh"
    echo '# dummy' > "$b/tap/share/scripts/iterm2_venv_bootstrap.py"
    local f
    if [ "$mode" = paramss ]; then
        :
    elif [ "$mode" = hand ] || [ "$mode" = handhalf ]; then
        for f in connect disconnect; do echo "OLD-$f" > "$b/aiteamforge/zqteam-$f.sh"; chmod 644 "$b/aiteamforge/zqteam-$f.sh"; done
    elif [ "$mode" = param ]; then
        for f in connect disconnect; do echo "OLD-$f" > "$b/aiteamforge/zqteam-$f.sh"; chmod 644 "$b/aiteamforge/zqteam-$f.sh"; done
    else
        for f in connect disconnect; do echo "OLD-$f" > "$b/aiteamforge/zqteam-$f.sh"; chmod 644 "$b/aiteamforge/zqteam-$f.sh"; done
        for f in startup shutdown; do echo "OLD-$f" > "$b/aiteamforge/zqinst-$f.sh"; chmod 644 "$b/aiteamforge/zqinst-$f.sh"; done
    fi
}

# run_flow <name> <install-team.sh> <mode>  -> sets F_RC F_OUT F_ERR, F_INODES_BEFORE
run_flow() {
    local name="$1" it="$2" mode="$3" b="$SBX/$1"
    make_sandbox "$name" "$mode"
    F_INO_BEFORE=""
    local f
    for f in zqteam-connect zqteam-disconnect zqinst-startup zqinst-shutdown zqteam-startup zqteam-shutdown; do
        if [ -f "$b/aiteamforge/$f.sh" ]; then F_INO_BEFORE="$F_INO_BEFORE $f=$(_inode "$b/aiteamforge/$f.sh")"; fi
    done
    # capture-first: rc is the child's. stdout and stderr kept separate.
    F_OUT="$(env -u TMUX -u TMUX_PANE HOME="$b/home" AITEAMFORGE_DIR="$b/aiteamforge" \
        "$BASH" "$CHILD" "$it" "$b" "$mode" "$ATOMIC_SH" 2>"$b/stderr")"
    F_RC=$?
    F_ERR="$(cat "$b/stderr")"
}

# check_role <label> <file> <role> <idtoken> <expect-windows: yes|no>  (adds to CHK_FAILS)
_check_role() {
    local label="$1" file="$2" role="$3" idtok="$4" win="$5" o
    local roles="connect disconnect startup shutdown"
    if [ ! -f "$file" ]; then CHK_FAILS="$CHK_FAILS [$label: missing $(basename "$file")]"; return; fi
    [ -x "$file" ] || CHK_FAILS="$CHK_FAILS [$label: not executable]"
    grep -q "^ROLE=$role\$" "$file" || CHK_FAILS="$CHK_FAILS [$label: lacks own marker ROLE=$role]"
    for o in $roles; do
        [ "$o" = "$role" ] && continue
        grep -q "^ROLE=$o\$" "$file" && CHK_FAILS="$CHK_FAILS [$label: contains foreign marker ROLE=$o]"
    done
    grep -q '{{' "$file" && CHK_FAILS="$CHK_FAILS [$label: unsubstituted placeholder]"
    grep -q "^ID=$idtok\$" "$file" || CHK_FAILS="$CHK_FAILS [$label: ID not substituted to $idtok]"
    if [ "$win" = yes ]; then
        grep -q 'AGENT_WINDOWS_zq="WINMARK-ONE"' "$file" && grep -q 'AGENT_WINDOWS_zr="WINMARK-TWO"' "$file" \
            || CHK_FAILS="$CHK_FAILS [$label: TEAM_AGENT_WINDOWS_CONFIG not expanded]"
    fi
}

_check_common() {
    local b="$1" f
    [ "$F_RC" -eq 0 ] || CHK_FAILS="$CHK_FAILS [child rc=$F_RC err=$F_ERR]"
    case "$F_OUT" in
        *ROLE=*) CHK_FAILS="$CHK_FAILS [rendered script content leaked to stdout]" ;;
    esac
    local leftovers
    leftovers="$(find "$b/aiteamforge" -maxdepth 1 \( -name '*.tmp' -o -name '.*.??????' \) 2>/dev/null | wc -l | tr -d ' ')"
    [ "$leftovers" = 0 ] || CHK_FAILS="$CHK_FAILS [$leftovers temp leftover(s)]"
    for f in $F_INO_BEFORE; do
        local nm="${f%%=*}" ino="${f#*=}"
        # INODE_EXPECT_SAME: names whose inode MUST be unchanged (untouched target)
        case " ${INODE_EXPECT_SAME:-} " in *" $nm "*) continue ;; esac
        if [ -f "$b/aiteamforge/$nm.sh" ] && [ "$(_inode "$b/aiteamforge/$nm.sh")" = "$ino" ]; then
            # a file that stayed untouched (still OLD) is a routing failure too, but
            # report the inode fact precisely
            CHK_FAILS="$CHK_FAILS [$nm.sh inode unchanged (not atomic / never written)]"
        fi
    done
}

# check_flow <name> <mode>: sets CHK_FAILS ("" == all good)
check_flow() {
    local name="$1" mode="$2" b="$SBX/$1/aiteamforge"
    CHK_FAILS=""
    _check_common "$SBX/$name"
    case "$mode" in
        nonparam)
            _check_role connect    "$b/zqteam-connect.sh"    connect    zqinst yes
            _check_role disconnect "$b/zqteam-disconnect.sh" disconnect zqinst no
            _check_role startup    "$b/zqinst-startup.sh"    startup    zqinst yes
            _check_role shutdown   "$b/zqinst-shutdown.sh"   shutdown   zqinst no
            ;;
        param)
            _check_role connect    "$b/zqteam-connect.sh"    connect    zqteam no
            _check_role disconnect "$b/zqteam-disconnect.sh" disconnect zqteam no
            ;;
        paramss)
            _check_role startup  "$b/zqteam-startup.sh"  startup  zqteam no
            _check_role shutdown "$b/zqteam-shutdown.sh" shutdown zqteam no
            local f
            for f in "$b/zqteam-startup.sh" "$b/zqteam-shutdown.sh"; do
                [ -f "$f" ] || continue
                grep -qE '~/dev-team|\$HOME/dev-team|\$\{HOME\}/dev-team|/Users/[^/]+/dev-team' "$f" \
                    && CHK_FAILS="$CHK_FAILS [$(basename "$f"): dev-team path not rewritten]"
                grep -q 'FLAT-' "$f" && CHK_FAILS="$CHK_FAILS [$(basename "$f"): flat template content (shutdown/startup template branch ran)]"
            done
            grep -qF "AWM=$b/scripts/iterm2_window_manager.py" "$b/zqteam-startup.sh" 2>/dev/null || CHK_FAILS="$CHK_FAILS [startup: iterm2_window_manager path not rewritten]"
            grep -qF "DIR=$b/scripts" "$b/zqteam-startup.sh" 2>/dev/null || CHK_FAILS="$CHK_FAILS [startup: \$HOME/dev-team not rewritten]"
            grep -qF "ABS=$b/foo" "$b/zqteam-startup.sh" 2>/dev/null || CHK_FAILS="$CHK_FAILS [startup: absolute /Users/x/dev-team not rewritten]"
            grep -qF "DIR=$b/scripts" "$b/zqteam-shutdown.sh" 2>/dev/null || CHK_FAILS="$CHK_FAILS [shutdown: \${HOME}/dev-team not rewritten]"
            # existing mode's non-exec bits preserved (640 -> 6x4x0 bits kept; 600 likewise)
            [ $(( 8#$(_mode "$b/zqteam-startup.sh") & 8#0666 )) -eq $(( 8#640 )) ] || CHK_FAILS="$CHK_FAILS [startup: existing mode 640 not preserved: $(_mode "$b/zqteam-startup.sh")]"
            [ $(( 8#$(_mode "$b/zqteam-shutdown.sh") & 8#0666 )) -eq $(( 8#600 )) ] || CHK_FAILS="$CHK_FAILS [shutdown: existing mode 600 not preserved: $(_mode "$b/zqteam-shutdown.sh")]"
            for f in scripts/lcars-launch-helpers.sh scripts/kb-init-team-guard.sh scripts/kb-init-team scripts/kb-run-marker.sh scripts/iterm2_venv_bootstrap.py zqteam/scripts/agent.sh; do
                [ -x "$b/$f" ] || CHK_FAILS="$CHK_FAILS [helper $f missing/not executable]"
            done
            grep -qF "AGENT=$b/x" "$b/zqteam/scripts/agent.sh" 2>/dev/null || CHK_FAILS="$CHK_FAILS [team scripts/ loop did not rewrite]"
            # shutdown comes ONLY from the parametric install: exactly one shutdown line, tagged parametric
            [ "$(printf '%s\n' "$F_OUT" | grep -c -- '-shutdown.sh')" -eq 1 ] && printf '%s\n' "$F_OUT" | grep -- '-shutdown.sh' | grep -q parametric \
                || CHK_FAILS="$CHK_FAILS [shutdown template branch not a no-op for parametric]"
            ;;
        hand|handhalf)
            local f hb="$SBX/$name"
            _check_role connect "$b/zqteam-connect.sh" connect zqteam no
            for f in "$b/zqteam-connect.sh" "$b/zqteam-disconnect.sh"; do
                grep -q 'TEMPLATE-' "$f" && CHK_FAILS="$CHK_FAILS [$(basename "$f"): template content (template/parametric branch ran)]"
                grep -qE '~/dev-team|\$HOME/dev-team|\$\{HOME\}/dev-team|/Users/[^/]+/dev-team' "$f" \
                    && CHK_FAILS="$CHK_FAILS [$(basename "$f"): dev-team path not rewritten]"
            done
            grep -qF "DIR=$b/scripts" "$b/zqteam-connect.sh" 2>/dev/null || CHK_FAILS="$CHK_FAILS [connect: \$HOME/dev-team not rewritten]"
            [ "$(printf '%s\n' "$F_OUT" | grep -c -- '-connect.sh')" -eq 1 ] \
                && printf '%s\n' "$F_OUT" | grep -- '-connect.sh' | grep -q 'hand-authored' \
                || CHK_FAILS="$CHK_FAILS [connect: not exactly one hand-authored line]"
            if [ "$mode" = hand ]; then
                _check_role disconnect "$b/zqteam-disconnect.sh" disconnect zqteam no
                grep -qF "DIR=$b/scripts" "$b/zqteam-disconnect.sh" 2>/dev/null || CHK_FAILS="$CHK_FAILS [disconnect: \${HOME}/dev-team not rewritten]"
                [ "$(printf '%s\n' "$F_OUT" | grep -c -- '-disconnect.sh')" -eq 1 ] \
                    && printf '%s\n' "$F_OUT" | grep -- '-disconnect.sh' | grep -q 'hand-authored' \
                    || CHK_FAILS="$CHK_FAILS [disconnect: not exactly one hand-authored line]"
            else
                # connect present, disconnect source absent: warn, leave OLD disconnect untouched
                [ "$(cat "$b/zqteam-disconnect.sh" 2>/dev/null)" = "OLD-disconnect" ] || CHK_FAILS="$CHK_FAILS [disconnect: pre-existing target was modified]"
                [ "$(_inode "$b/zqteam-disconnect.sh")" = "$(printf '%s\n' $F_INO_BEFORE | sed -n 's/^zqteam-disconnect=//p')" ] || CHK_FAILS="$CHK_FAILS [disconnect: inode changed]"
                case "$F_OUT" in *"no matching disconnect script"*) ;; *) CHK_FAILS="$CHK_FAILS [missing no-disconnect warning]" ;; esac
                printf '%s\n' "$F_OUT" | grep -q -- '-disconnect.sh (hand' && CHK_FAILS="$CHK_FAILS [disconnect reported installed]"
            fi
            ;;
        fallback)
            # Templates for startup/shutdown absent -> heredoc fallbacks.
            # connect/disconnect templates exist (flat) and are checked normally.
            _check_role connect    "$b/zqteam-connect.sh"    connect    zqinst yes
            _check_role disconnect "$b/zqteam-disconnect.sh" disconnect zqinst no
            if [ -f "$b/zqinst-startup.sh" ]; then
                grep -q 'Zq Team Startup Script' "$b/zqinst-startup.sh" || CHK_FAILS="$CHK_FAILS [startup fallback lacks own marker]"
                grep -q 'Shutdown Script' "$b/zqinst-startup.sh" && CHK_FAILS="$CHK_FAILS [startup fallback holds shutdown content]"
                [ -x "$b/zqinst-startup.sh" ] || CHK_FAILS="$CHK_FAILS [startup fallback not executable]"
            else CHK_FAILS="$CHK_FAILS [startup fallback missing]"; fi
            if [ -f "$b/zqinst-shutdown.sh" ]; then
                grep -q 'Zq Team Shutdown Script' "$b/zqinst-shutdown.sh" || CHK_FAILS="$CHK_FAILS [shutdown fallback lacks own marker]"
                grep -q 'Startup Script' "$b/zqinst-shutdown.sh" && CHK_FAILS="$CHK_FAILS [shutdown fallback holds startup content]"
                [ -x "$b/zqinst-shutdown.sh" ] || CHK_FAILS="$CHK_FAILS [shutdown fallback not executable]"
            else CHK_FAILS="$CHK_FAILS [shutdown fallback missing]"; fi
            case "$F_OUT" in
                *"Startup Script"*|*"Shutdown Script"*) CHK_FAILS="$CHK_FAILS [fallback content leaked to stdout]" ;;
            esac
            ;;
    esac
}

# ═══ Sanity ══════════════════════════════════════════════════════════════════
test_start "Sanity: all eight mutants applied (anchors unique) and really differ from the real file"
_san=""
for _i in 1 2 3 4 5 6 7 8; do
    eval "_rc=\$M$_i"
    [ "$_rc" -eq 0 ] || _san="$_san [M$_i anchor not unique/absent]"
    cmp -s "$INSTALL_TEAM" "$MUT_DIR/m$_i.sh" && _san="$_san [M$_i identical to real]"
done
if [ -z "$_san" ]; then test_pass; else test_fail "$_san"; fi

test_start "Sanity: real install-team.sh routes each writer to its own dst"
_san=""
grep -q '_aitf_atomic_write_script "\$STARTUP_SCRIPT" cat "\${STARTUP_SCRIPT}.tmp"' "$INSTALL_TEAM" || _san="$_san [startup]"
grep -q '_aitf_atomic_write_script "\$SHUTDOWN_SCRIPT" sed' "$INSTALL_TEAM" || _san="$_san [shutdown]"
grep -q '_aitf_atomic_write_script "\$disconnect_script" sed' "$INSTALL_TEAM" || _san="$_san [disconnect]"
grep -q '_aitf_atomic_write_script "\$connect_script" cat "\${connect_script}.tmp"' "$INSTALL_TEAM" || _san="$_san [connect]"
if [ -z "$_san" ]; then test_pass; else test_fail "missing:$_san"; fi

# ═══ POSITIVE ════════════════════════════════════════════════════════════════
for _m in nonparam fallback param; do
    run_flow "pos-$_m" "$INSTALL_TEAM" "$_m"
    check_flow "pos-$_m" "$_m"
    test_start "POSITIVE/$_m: every script holds its own role, no stdout leak, no temps, new inodes"
    if [ -z "$CHK_FAILS" ]; then test_pass; else test_fail "$CHK_FAILS"; fi
done

run_flow "pos-paramss" "$INSTALL_TEAM" paramss
check_flow "pos-paramss" paramss
test_start "POSITIVE/paramss: parametric startup/shutdown land in own dst, paths rewritten, mode kept, new inode, helpers, shutdown template no-op"
if [ -z "$CHK_FAILS" ]; then test_pass; else test_fail "$CHK_FAILS"; fi

run_flow "pos-hand" "$INSTALL_TEAM" hand
check_flow "pos-hand" hand
test_start "POSITIVE/hand: XACA-0853 hand-authored connect+disconnect land in own dst, paths rewritten, +x, new inode, no template branch"
if [ -z "$CHK_FAILS" ]; then test_pass; else test_fail "$CHK_FAILS"; fi

INODE_EXPECT_SAME="zqteam-disconnect"
run_flow "pos-handhalf" "$INSTALL_TEAM" handhalf
check_flow "pos-handhalf" handhalf
INODE_EXPECT_SAME=""
test_start "POSITIVE/handhalf: connect shipped, disconnect absent -> warning, old disconnect untouched"
if [ -z "$CHK_FAILS" ]; then test_pass; else test_fail "$CHK_FAILS"; fi

# connect/disconnect have no heredoc fallback: absent templates warn and skip.
test_start "FALLBACK: connect/disconnect have no heredoc fallback (absent template -> warn, no write)"
_b="$SBX/nofb"; make_sandbox nofb fallback
rm -f "$_b/tap/share/templates/team-connect.sh.template" "$_b/tap/share/templates/team-disconnect.sh.template"
_o="$(env -u TMUX -u TMUX_PANE HOME="$_b/home" AITEAMFORGE_DIR="$_b/aiteamforge" "$BASH" "$CHILD" "$INSTALL_TEAM" "$_b" fallback "$ATOMIC_SH" 2>"$_b/stderr")"; _r=$?
if [ "$_r" -eq 0 ] && echo "$_o" | grep -q 'Template not found: team-connect.sh.template' \
   && [ "$(cat "$_b/aiteamforge/zqteam-connect.sh")" = "OLD-connect" ]; then test_pass
else test_fail "rc=$_r out=$_o"; fi

# ═══ MUTATION: each mutant must FAIL the matching flow ══════════════════════
_mut_case() { # <label> <mutant-file> <mode>
    run_flow "mut-$1" "$2" "$3"
    check_flow "mut-$1" "$3"
    test_start "NEG-$1: re-introduced f03b44f6-class bug is DETECTED ($3 flow)"
    if [ -n "$CHK_FAILS" ]; then test_pass
    else test_fail "mutant survived -- test is vacuous for this bug class"; fi
}
_mut_case MUT-1-startup-to-shutdown "$MUT_DIR/m1.sh" nonparam
_mut_case MUT-2-connect-to-disconnect "$MUT_DIR/m2.sh" nonparam
_mut_case MUT-3-shutdown-stdout-leak "$MUT_DIR/m3.sh" nonparam
_mut_case MUT-4-disconnect-stdout-leak "$MUT_DIR/m4.sh" nonparam
_mut_case MUT-5-startup-fallback-misroute "$MUT_DIR/m5.sh" fallback

_mut_case MUT-6-param-startup-to-shutdown "$MUT_DIR/m6.sh" paramss
_mut_case MUT-7-install-script-in-place "$MUT_DIR/m7.sh" paramss
test_start "NEG-MUT-7: in-place revert is detected specifically as an UNCHANGED INODE"
case "$CHK_FAILS" in *"inode unchanged"*) test_pass ;; *) test_fail "no inode-unchanged finding: $CHK_FAILS" ;; esac

_mut_case MUT-8-hand-connect-to-disconnect "$MUT_DIR/m8.sh" hand

if [ "$_STANDALONE" = true ]; then
    echo "Results: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    [ "$_FAIL_COUNT" -eq 0 ]
    exit $?
fi
