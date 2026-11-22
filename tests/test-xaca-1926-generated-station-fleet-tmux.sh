#!/bin/bash
# XACA-1926: generated station scripts (install-team.sh generate_per_agent_startup_scripts)
# put the fleet system name on tmux's status-right, and a Mac with no fleet
# identity gets exactly the tmux line it got before.
#
# Generation: reuses test-xaca-1229-persona-field-escaping.sh as the harness
# (it extracts the generator and runs it in a sandbox). We hand it our own
# TEST_TMP_DIR so its sandbox survives for us to read.
#
# Checks, per generated script (spacedock fixtures):
#   1. the fleet lookup and the fleet-aware status-right are present, once each
#   2. with a recording fake tmux:
#        helper absent              -> set -gu @fleet_system (unset), never set -g
#        helper prints the hostname -> unset
#        helper prints "Sol"        -> set -g @fleet_system Sol
#        helper exits non-zero      -> unset
#   3. with a real tmux on an ISOLATED server (TMUX_TMPDIR, never a real team
#      socket): the expanded status-right with no fleet identity is byte-identical
#      to the pre-XACA-1926 line, and with "Sol" it reads "Sol · <host>".
#
# Usage: bash tests/test-xaca-1926-generated-station-fleet-tmux.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
HARNESS="$SCRIPT_DIR/test-xaca-1229-persona-field-escaping.sh"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

WORK="$(mktemp -d -t xaca1926gen.XXXXXX)"
WORK="$(cd "$WORK" && pwd -P)"
# Short path: a unix socket path over ~104 bytes fails ("File name too long").
TMUX_ISO="$(mktemp -d /tmp/x1926t.XXXXXX)"
cleanup() {
    TMUX_TMPDIR="$TMUX_ISO" tmux -L xaca1926 kill-server 2>/dev/null
    rm -rf "$WORK" "$TMUX_ISO"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# ─── 0. Generate via the 1229 harness ──────────────────────────────────────
if ! TEST_TMP_DIR="$WORK" bash "$HARNESS" > "$WORK/harness.log" 2>&1; then
    fail "generator harness (1229) failed; see its output:"
    tail -20 "$WORK/harness.log" >&2
fi
SCRIPTS_DIR="$WORK/aiteamforge/spacedock/scripts"
GEN=$(ls "$SCRIPTS_DIR"/spacedock-*-startup.sh 2>/dev/null)
if [ -n "$GEN" ]; then
    pass "generator produced $(echo "$GEN" | wc -l | tr -d ' ') station script(s)"
else
    fail "no generated station scripts under $SCRIPTS_DIR"
    echo "Results: $PASS passed, $FAIL failed"; exit 1
fi

# ─── 1. Static: one lookup, one fleet-aware status-right per script ────────
for f in $GEN; do
    b=$(basename "$f")
    n_look=$(grep -c '_fleet_sys=\$(' "$f")
    n_sr=$(grep -c 'status-right "🤖 #{@claude_agent} | 🖥  #{?@fleet_system,#{@fleet_system} · ,}\$DISPLAY_HOST  "' "$f")
    n_old=$(grep -c 'status-right "🤖 #{@claude_agent} | 🖥  \$DISPLAY_HOST  "' "$f")
    if [ "$n_look" = 1 ] && [ "$n_sr" = 1 ] && [ "$n_old" = 0 ]; then
        pass "$b: one fleet lookup, one fleet-aware status-right"
    else
        fail "$b: lookup=$n_look fleet-status-right=$n_sr old-status-right=$n_old (want 1/1/0)"
    fi
done
SAMPLE=$(echo "$GEN" | head -1)
LOOKUP=$(grep '_fleet_sys=\$(' "$SAMPLE")
SR_LINE=$(grep 'status-right "🤖' "$SAMPLE")

# ─── 2. Behaviour with a recording fake tmux ──────────────────────────────
FAKE="$WORK/fake-tmux"
cat > "$FAKE" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_TMUX_LOG"
EOF
chmod 755 "$FAKE"
HOST_S=$(hostname -s)

# $1 = scenario name, $2 = helper body ('' = no helper)
run_lookup() {
    local name="$1" body="$2" home="$WORK/home-$1"
    mkdir -p "$home/aiteamforge/scripts"
    if [ -n "$body" ]; then
        printf '#!/bin/bash\n%s\n' "$body" > "$home/aiteamforge/scripts/kb-fleet-identity"
        chmod 755 "$home/aiteamforge/scripts/kb-fleet-identity"
    fi
    : > "$WORK/log-$name"
    env -i PATH="/usr/bin:/bin" HOME="$home" FAKE_TMUX_LOG="$WORK/log-$name" \
        TMUX_CMD="$FAKE" AITEAMFORGE_DIR="$home/aiteamforge" \
        bash -c "$LOOKUP" >/dev/null 2>&1
    cat "$WORK/log-$name"
}

out=$(run_lookup absent '')
if [ "$out" = "set -gu @fleet_system" ]; then pass "no helper -> @fleet_system unset"; else fail "no helper -> got: $out"; fi

out=$(run_lookup hostname "echo $HOST_S")
if [ "$out" = "set -gu @fleet_system" ]; then pass "helper prints the hostname -> unset"; else fail "hostname case -> got: $out"; fi

out=$(run_lookup failing 'exit 3')
if [ "$out" = "set -gu @fleet_system" ]; then pass "helper exits non-zero -> unset"; else fail "failing helper -> got: $out"; fi

out=$(run_lookup mapped 'echo Sol')
if [ "$out" = "set -g @fleet_system Sol" ]; then pass "helper prints Sol -> set -g @fleet_system Sol"; else fail "mapped case -> got: $out"; fi

# ─── 3. Real tmux, isolated server: rendered status-right ─────────────────
if command -v tmux >/dev/null 2>&1; then
    T() { TMUX_TMPDIR="$TMUX_ISO" tmux -L xaca1926 -f /dev/null "$@"; }
    T new-session -d -s iso -x 200 -y 10 2>/dev/null
    DISPLAY_HOST="testhost"
    # shellcheck disable=SC2034  # both are read by the eval'd generated line below
    SESSION_CODE=iso
    # shellcheck disable=SC2034
    TMUX_CMD="T"
    # The line as generated (single-quoted heredoc text -> evaluate with our vars).
    eval "${SR_LINE#"${SR_LINE%%[! ]*}"}"
    T set -gu @fleet_system 2>/dev/null
    new_plain=$(T display-message -p -t iso "$(T show-options -v -t iso status-right)")
    old_plain=$(T display-message -p -t iso "🤖 #{@claude_agent} | 🖥  $DISPLAY_HOST  ")
    # Non-empty and ending in the host: an unreachable server renders '' on both sides.
    if [ -n "$new_plain" ] && [ "$new_plain" = "$old_plain" ] && [ "${new_plain%testhost  }" != "$new_plain" ]; then
        pass "no fleet identity: rendered status-right is byte-identical to the pre-XACA-1926 line"
    else
        fail "no fleet identity: new='$new_plain' old='$old_plain'"
    fi
    T set -g @fleet_system Sol
    named=$(T display-message -p -t iso "$(T show-options -v -t iso status-right)")
    case "$named" in
        *"🖥  Sol · testhost  ") pass "fleet identity Sol: renders 'Sol · testhost'" ;;
        *) fail "fleet identity Sol: got '$named'" ;;
    esac
else
    echo "  SKIP: tmux not installed; rendered-line checks not run"
fi

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
