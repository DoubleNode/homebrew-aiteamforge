#!/bin/bash
# test-xaca-1269-installer-only-launchagents-doctor.sh
#
# XACA-1269-007: BOTH doctors (libexec/commands/aiteamforge-doctor.sh and
# bin/aiteamforge-doctor.sh) must WARN about installer-only LaunchAgents that are
# missing / unloaded / disabled, and about the RETIRED lcars-runatload agent when
# a leftover is still present. Before this ticket M1Pro ran for months without
# cellar-watch + lcars-watch and `aiteamforge doctor` was all green.
#
# Both doctors are executed FOR REAL against a sandbox (HOME, AITEAMFORGE_DIR,
# AITF_LAUNCHAGENT_OPTOUT_FILE, KB_KNOWLEDGE_GLOBAL_ROOT all under TEST_TMP_DIR)
# with a STUB `launchctl` first on PATH. The real launchctl is never invoked and
# nothing under the real ~/Library/LaunchAgents is touched.
#
# Discrimination: run against the pre-change tree (git stash-free: see the
# XACA-1269 PR description) — every WARN case FAILS there because neither doctor
# emits any installer-only line at all.
#
# Runs standalone or via test-runner.sh. The doctors run under $DOCTOR_BASH
# (default: the system bash 3.2); export DOCTOR_BASH=$(command -v bash) to drive
# them under a newer bash.

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIBEXEC_DOCTOR="$TAP_ROOT/libexec/commands/aiteamforge-doctor.sh"
BIN_DOCTOR="$TAP_ROOT/bin/aiteamforge-doctor.sh"

_STANDALONE=false
_PASS=0
_FAIL=0
_CURRENT_TEST=""
if ! declare -F test_start >/dev/null 2>&1; then
    _STANDALONE=true
    test_start() { _CURRENT_TEST="$1"; printf "TEST: %s\n" "$1"; }
    test_pass()  { _PASS=$((_PASS + 1)); printf "  PASS: %s\n" "$_CURRENT_TEST"; }
    test_fail()  { _FAIL=$((_FAIL + 1)); printf "  FAIL: %s -- %s\n" "$_CURRENT_TEST" "${1:-}" >&2; }
fi

_BLOCK_FAILED=false
_block_start()     { _BLOCK_FAILED=false; test_start "$1"; }
_block_note_fail() { _BLOCK_FAILED=true; test_fail "$1"; }
_block_end()       { if [ "$_BLOCK_FAILED" = false ]; then test_pass; fi; return 0; }

assert_contains() {
    case "$1" in *"$2"*) : ;; *) _block_note_fail "${3:-expected to find [$2]}" ;; esac
}
assert_not_contains() {
    case "$1" in *"$2"*) _block_note_fail "${3:-expected NOT to find [$2]}" ;; *) : ;; esac
}

for f in "$LIBEXEC_DOCTOR" "$BIN_DOCTOR"; do
    [ -f "$f" ] || { echo "FATAL: missing $f" >&2; exit 1; }
done
JQ_BIN="$(command -v jq || true)"
if [ -z "$JQ_BIN" ]; then
    echo "FATAL: jq required (same as doctor itself)" >&2
    exit 1
fi

if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca1269-doctor.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
_cleanup() {
    if [ "$_OWN_TMP" = true ] && [ -n "$TEST_TMP_DIR" ] && [ -d "$TEST_TMP_DIR" ]; then
        rm -r "$TEST_TMP_DIR"
    fi
}
trap _cleanup EXIT

# Never let the ambient dev environment steer a sandboxed run.
export AITEAMFORGE_DIR="$TEST_TMP_DIR/aiteamforge"

# ── Sandbox + stub launchctl ────────────────────────────────────────────────
# Stub behaviour is driven by files so each case is declarative:
#   $SB/lc-list      lines emitted after the header by `launchctl list`
#   $SB/lc-disabled  lines emitted by `launchctl print-disabled`
#   $SB/lc-fail      exists => `launchctl list` exits 1 with an error
SB=""
LA=""
new_sandbox() {
    SB="$TEST_TMP_DIR/sb.$1"
    LA="$SB/home/Library/LaunchAgents"
    mkdir -p "$LA" "$SB/home/.aiteamforge" "$SB/home/.config/aiteamforge" "$SB/bin" "$AITEAMFORGE_DIR"
    # lcars-watch is only expected once lcars-ui is installed (installer gate).
    mkdir -p "$AITEAMFORGE_DIR/lcars-ui"
    if [ -f "$AITEAMFORGE_DIR/.install-profile" ]; then rm "$AITEAMFORGE_DIR/.install-profile"; fi
    : > "$SB/lc-list"
    : > "$SB/lc-disabled"
    cat > "$SB/bin/launchctl" <<'STUB'
#!/bin/bash
SB="$(cd "$(dirname "$0")/.." && pwd)"
case "$1" in
  list)
    if [ -f "$SB/lc-fail" ]; then echo "launchctl: simulated failure" >&2; exit 1; fi
    printf 'PID\tStatus\tLabel\n'
    cat "$SB/lc-list"
    ;;
  print-disabled)
    printf 'disabled services = {\n'
    cat "$SB/lc-disabled"
    printf '}\n'
    ;;
  *) echo "stub launchctl: refusing '$*'" >&2; exit 0 ;;
esac
exit 0
STUB
    chmod +x "$SB/bin/launchctl"
    # Every mandatory agent present + loaded so only the installer-only
    # section is under test unless a case says otherwise.
    local m
    for m in auto-upgrade lcars-health kanban-backup host-ready; do
        : > "$LA/com.aiteamforge.$m.plist"
        printf -- '-\t0\tcom.aiteamforge.%s\n' "$m" >> "$SB/lc-list"
    done
}

# run_doctor <libexec|bin> -> stdout (ANSI stripped) in $OUT, exit code in $RC
OUT=""
RC=0
run_doctor() {
    local which="$1" script comp
    if [ "$which" = libexec ]; then script="$LIBEXEC_DOCTOR"; comp="launchagents"
    else script="$BIN_DOCTOR"; comp="services"; fi
    OUT="$(env -i PATH="$SB/bin:$(dirname "$JQ_BIN"):/usr/bin:/bin" \
        HOME="$SB/home" \
        AITEAMFORGE_HOME="$TAP_ROOT" \
        AITEAMFORGE_DIR="$AITEAMFORGE_DIR" \
        AITF_LAUNCHAGENT_OPTOUT_FILE="$SB/home/.aiteamforge/launchagents.optout" \
        KB_KNOWLEDGE_GLOBAL_ROOT="$SB/home/knowledge" \
        LAUNCHAGENTS_DIR="$LA" \
        "${DOCTOR_BASH:-/bin/bash}" "$script" --check "$comp" 2>&1)"
    RC=$?
    OUT="$(printf '%s\n' "$OUT" | sed $'s/\x1b\\[[0-9;]*m//g')"
    return 0
}

both() { # both <fn> : run a case function once per doctor
    local w
    for w in libexec bin; do "$1" "$w"; done
}

CELLAR="com.aiteamforge.cellar-watch"
LWATCH="com.aiteamforge.lcars-watch"

# ── 1. absent -> WARN (naming agent + install fix + opt-out line) ───────────
case_absent_warns() {
    local w="$1"
    _block_start "[$w] cellar-watch + lcars-watch ABSENT -> WARN with remediation"
    new_sandbox "absent-$w"
    run_doctor "$w"
    assert_contains "$OUT" "MISSING: $LA/$CELLAR.plist" "no WARN naming cellar-watch"
    assert_contains "$OUT" "MISSING: $LA/$LWATCH.plist" "no WARN naming lcars-watch"
    assert_contains "$OUT" "install_cellar_watch_launchagent" "no install-function remediation"
    assert_contains "$OUT" "echo \"$CELLAR.plist\" >> $SB/home/.aiteamforge/launchagents.optout" "no opt-out sentinel line"
    _block_end
}
both case_absent_warns

# ── 2. absent + opted out -> no WARN ────────────────────────────────────────
case_optout_silent() {
    local w="$1"
    _block_start "[$w] absent + opted out -> no WARN, intentional pass"
    new_sandbox "optout-$w"
    printf '%s\n%s\n' "$CELLAR.plist" "$LWATCH.plist" > "$SB/home/.aiteamforge/launchagents.optout"
    run_doctor "$w"
    assert_not_contains "$OUT" "Installer-only LaunchAgent MISSING" "opted-out agent still warned"
    assert_contains "$OUT" "$CELLAR.plist absent (opted out" "no intentional-absence pass line"
    _block_end
}
both case_optout_silent

# ── 3. present + loaded -> pass ─────────────────────────────────────────────
case_loaded_passes() {
    local w="$1"
    _block_start "[$w] present + loaded -> pass, no WARN"
    new_sandbox "loaded-$w"
    : > "$LA/$CELLAR.plist"; : > "$LA/$LWATCH.plist"
    printf -- '-\t0\t%s\n-\t0\t%s\n' "$CELLAR" "$LWATCH" >> "$SB/lc-list"
    run_doctor "$w"
    assert_contains "$OUT" "$CELLAR LaunchAgent loaded" "cellar-watch loaded not reported"
    assert_contains "$OUT" "$LWATCH LaunchAgent loaded" "lcars-watch loaded not reported"
    assert_not_contains "$OUT" "Installer-only LaunchAgent MISSING" "false MISSING on loaded agent"
    _block_end
}
both case_loaded_passes

# ── 4. present but not loaded / DISABLED distinct ───────────────────────────
case_unloaded_and_disabled() {
    local w="$1"
    _block_start "[$w] present+unloaded -> NOT loaded WARN; present+disabled -> DISABLED WARN"
    new_sandbox "unloaded-$w"
    : > "$LA/$CELLAR.plist"; : > "$LA/$LWATCH.plist"
    printf '    "%s" => disabled\n' "$LWATCH" > "$SB/lc-disabled"
    run_doctor "$w"
    assert_contains "$OUT" "$CELLAR LaunchAgent plist present but NOT loaded" "unloaded not reported"
    assert_contains "$OUT" "$LWATCH LaunchAgent DISABLED" "DISABLED not reported distinctly"
    assert_contains "$OUT" "launchctl enable gui/" "no enable remediation"
    _block_end
}
both case_unloaded_and_disabled

# ── 5. cr-confluence-poller: config-gated (per-team plists) ─────────────────
case_cr_gate() {
    local w="$1"
    new_sandbox "cr-off-$w"
    _block_start "[$w] cr poller gate OFF (no cr-config) -> no cr WARN"
    run_doctor "$w"
    assert_not_contains "$OUT" "cr-confluence-poller" "cr warned with gate off"
    _block_end

    new_sandbox "cr-off2-$w"
    _block_start "[$w] cr poller: team disabled in cr-config -> no cr WARN"
    printf '{"teams":{"academy":false}}\n' > "$SB/home/.config/aiteamforge/cr-config.json"
    printf '{"teams":{"academy":{"x":1}}}\n' > "$SB/home/.config/aiteamforge/confluence-credentials.json"
    run_doctor "$w"
    assert_not_contains "$OUT" "cr-confluence-poller" "cr warned for disabled team"
    _block_end

    new_sandbox "cr-nocreds-$w"
    _block_start "[$w] cr poller: enabled but NO credentials (installer skips) -> no cr WARN"
    printf '{"teams":{"academy":true}}\n' > "$SB/home/.config/aiteamforge/cr-config.json"
    run_doctor "$w"
    assert_not_contains "$OUT" "cr-confluence-poller" "cr warned though installer would skip"
    _block_end

    new_sandbox "cr-on-$w"
    _block_start "[$w] cr poller: team enabled + credentials, plist absent -> WARN per-team"
    printf '{"teams":{"academy":true}}\n' > "$SB/home/.config/aiteamforge/cr-config.json"
    printf '{"teams":{"academy":{"x":1}}}\n' > "$SB/home/.config/aiteamforge/confluence-credentials.json"
    run_doctor "$w"
    assert_contains "$OUT" "MISSING: $LA/com.aiteamforge.cr-confluence-poller.academy.plist" "per-team cr WARN missing"
    _block_end

    new_sandbox "cr-bad-$w"
    _block_start "[$w] cr poller: unparseable cr-config -> WARN (ambiguous never passes)"
    printf '{not json\n' > "$SB/home/.config/aiteamforge/cr-config.json"
    run_doctor "$w"
    assert_contains "$OUT" "CR poller check: cannot parse" "ambiguous cr-config passed silently"
    _block_end
}
both case_cr_gate

# ── 6. knowledge-sync: gated on ~/knowledge being a git clone ───────────────
case_knowledge_gate() {
    local w="$1"
    new_sandbox "kn-off-$w"
    _block_start "[$w] knowledge-sync gate OFF (~/knowledge not a clone) -> no WARN"
    run_doctor "$w"
    assert_not_contains "$OUT" "knowledge-sync" "knowledge-sync warned with gate off"
    _block_end

    new_sandbox "kn-on-$w"
    _block_start "[$w] knowledge-sync gate ON (.git dir), plist absent -> WARN"
    mkdir -p "$SB/home/knowledge/.git"
    run_doctor "$w"
    assert_contains "$OUT" "MISSING: $LA/com.aiteamforge.knowledge-sync.plist" "knowledge-sync WARN missing"
    assert_contains "$OUT" "install_knowledge_sync_launchagent" "no install-function remediation"
    _block_end
}
both case_knowledge_gate

# ── 7. lcars-runatload: INVERSE ─────────────────────────────────────────────
case_runatload() {
    local w="$1"
    new_sandbox "rl-absent-$w"
    _block_start "[$w] lcars-runatload ABSENT -> pass (absence is correct)"
    run_doctor "$w"
    assert_contains "$OUT" "lcars-runatload retired agent absent (correct)" "absent retired agent not a pass"
    assert_not_contains "$OUT" "Retired LaunchAgent still present" "false leftover WARN"
    _block_end

    new_sandbox "rl-present-$w"
    _block_start "[$w] lcars-runatload plist PRESENT -> WARN with remediation"
    : > "$LA/com.aiteamforge.lcars-runatload.plist"
    run_doctor "$w"
    assert_contains "$OUT" "Retired LaunchAgent still present: com.aiteamforge.lcars-runatload" "leftover not warned"
    assert_contains "$OUT" "remove_legacy_lcars_runatload_agent" "no remediation"
    _block_end

    new_sandbox "rl-loaded-$w"
    _block_start "[$w] lcars-runatload LOADED with no plist -> WARN"
    printf -- '-\t0\tcom.aiteamforge.lcars-runatload\n' >> "$SB/lc-list"
    run_doctor "$w"
    assert_contains "$OUT" "Retired LaunchAgent still present" "loaded leftover not warned"
    _block_end
}
both case_runatload

# ── 8. mandatory absent is STILL a FAIL (XACA-0734 unchanged) ───────────────
case_mandatory_still_fails() {
    local w="$1"
    _block_start "[$w] mandatory agent absent -> still FAIL, not downgraded to WARN"
    new_sandbox "mand-$w"
    rm "$LA/com.aiteamforge.lcars-health.plist"
    # bin doctor judges "loaded" before "present": drop the label too, or the
    # agent is legitimately reported loaded (a test artifact, not a defect).
    grep -v 'com.aiteamforge.lcars-health' "$SB/lc-list" > "$SB/lc-list.new" && mv "$SB/lc-list.new" "$SB/lc-list"
    run_doctor "$w"
    assert_contains "$OUT" "com.aiteamforge.lcars-health" "mandatory agent not reported"
    if [ "$w" = libexec ]; then
        assert_contains "$OUT" "Mandatory LaunchAgent missing: $LA/com.aiteamforge.lcars-health.plist" "mandatory FAIL text changed"
    else
        assert_contains "$OUT" "com.aiteamforge.lcars-health LaunchAgent MISSING" "mandatory FAIL text changed"
    fi
    if [ "$RC" -eq 0 ]; then _block_note_fail "doctor exit 0 despite missing mandatory agent"; fi
    _block_end
}
both case_mandatory_still_fails

# ── 9. launchctl list failing must not read as a clean bill of health ───────
case_launchctl_failure() {
    local w="$1"
    _block_start "[$w] launchctl list FAILS -> explicit WARN, no silent pass"
    new_sandbox "lcfail-$w"
    : > "$LA/$CELLAR.plist"
    : > "$SB/lc-fail"
    run_doctor "$w"
    assert_contains "$OUT" "cannot verify load state (launchctl list failed" "launchctl failure swallowed"
    assert_not_contains "$OUT" "$CELLAR LaunchAgent loaded" "reported loaded without evidence"
    _block_end
}
both case_launchctl_failure

# ── 10. cockpit / kanban-declined: watchers not expected ────────────────────
case_not_applicable() {
    local w="$1"
    _block_start "[$w] LaunchAgents not applicable (kanban declined) -> no watcher WARN"
    new_sandbox "na-$w"
    printf '{"features":{"lcars_kanban":false}}\n' > "$AITEAMFORGE_DIR/.aiteamforge-config"
    run_doctor "$w"
    assert_not_contains "$OUT" "Installer-only LaunchAgent MISSING" "warned on a non-applicable install"
    rm "$AITEAMFORGE_DIR/.aiteamforge-config"
    _block_end
}
both case_not_applicable

# ── ROUND 2 (PR #981 advisory fold-ins, XACA-1269-014..018) ─────────────────

# 014: knowledge-sync MISSING text must not claim upgrade can't re-create it.
case_r2_014() {
    local w="$1"
    _block_start "[$w] 014 knowledge-sync MISSING message: upgrade DOES re-create it"
    new_sandbox "r2-014-$w"
    mkdir -p "$SB/home/knowledge/.git"
    run_doctor "$w"
    assert_contains "$OUT" "MISSING: $LA/com.aiteamforge.knowledge-sync.plist" "knowledge-sync WARN absent"
    assert_not_contains "$OUT" "knowledge-sync.plist — nothing re-creates it on upgrade" "false 'nothing re-creates it' claim"
    assert_contains "$OUT" "update_knowledge_sync" "remediation does not name the upgrade path"
    # the genuinely installer-only agents keep the original wording
    assert_contains "$OUT" "$CELLAR.plist — nothing re-creates it on upgrade" "cellar-watch wording regressed"
    _block_end
}
both case_r2_014

# 015/018: retired agent must not PASS when launchctl list failed.
case_r2_015() {
    local w="$1"
    _block_start "[$w] 015/018 retired agent + launchctl list FAILS -> no PASS, UNVERIFIED WARN"
    new_sandbox "r2-015-$w"
    : > "$SB/lc-fail"
    run_doctor "$w"
    assert_not_contains "$OUT" "retired agent absent (correct)" "retired PASS despite failed launchctl list"
    assert_contains "$OUT" "load state UNVERIFIED" "no unverified WARN for retired agent"
    _block_end
}
both case_r2_015

# 016a: lcars-watch only expected when lcars-ui exists.
case_r2_016a() {
    local w="$1"
    _block_start "[$w] 016a lcars-watch absent + NO lcars-ui dir -> no lcars-watch WARN; cellar still warns"
    new_sandbox "r2-016a-$w"
    rmdir "$AITEAMFORGE_DIR/lcars-ui"
    run_doctor "$w"
    assert_not_contains "$OUT" "$LWATCH.plist" "lcars-watch warned though installer would skip (no lcars-ui)"
    assert_contains "$OUT" "MISSING: $LA/$CELLAR.plist" "cellar-watch must still warn"
    _block_end
}
both case_r2_016a

# 016b: cockpit profile: both doctors agree (no installer-only findings at all).
case_r2_016b() {
    local w="$1"
    _block_start "[$w] 016b cockpit profile -> no cr/knowledge/retired/watcher findings (doctors agree)"
    new_sandbox "r2-016b-$w"
    printf 'cockpit\n' > "$AITEAMFORGE_DIR/.install-profile"
    printf '{"teams":{"academy":true}}\n' > "$SB/home/.config/aiteamforge/cr-config.json"
    printf '{"teams":{"academy":{"x":1}}}\n' > "$SB/home/.config/aiteamforge/confluence-credentials.json"
    mkdir -p "$SB/home/knowledge/.git"
    : > "$LA/com.aiteamforge.lcars-runatload.plist"
    run_doctor "$w"
    assert_not_contains "$OUT" "cr-confluence-poller" "cr finding on cockpit"
    assert_not_contains "$OUT" "knowledge-sync" "knowledge finding on cockpit"
    assert_not_contains "$OUT" "lcars-runatload" "retired finding on cockpit"
    assert_not_contains "$OUT" "Installer-only LaunchAgent MISSING" "watcher finding on cockpit"
    rm "$AITEAMFORGE_DIR/.install-profile"
    _block_end
}
both case_r2_016b

# 017: valid config with no/null .teams is "no teams enabled", not a parse error.
case_r2_017() {
    local w="$1" body
    for body in '{}' '{"teams":null}'; do
        _block_start "[$w] 017 cr-config $body -> no 'cannot parse' WARN"
        new_sandbox "r2-017-$w"
        printf '%s\n' "$body" > "$SB/home/.config/aiteamforge/cr-config.json"
        run_doctor "$w"
        assert_not_contains "$OUT" "cannot parse" "false parse WARN on valid config $body"
        _block_end
    done
}
both case_r2_017

# ── 11. single-roster structure ─────────────────────────────────────────────
_block_start "one shared roster: both doctors call the lib evaluator, neither re-declares agents"
LIB="$TAP_ROOT/libexec/lib/launchagents.sh"
for f in "$LIBEXEC_DOCTOR" "$BIN_DOCTOR"; do
    if ! grep -q '_xaca1269_check_installer_only_launchagents' "$f"; then
        _block_note_fail "$(basename "$(dirname "$f")")/$(basename "$f") does not call the shared evaluator"
    fi
    if grep -q 'com.aiteamforge.cellar-watch\|com.aiteamforge.lcars-watch\|com.aiteamforge.lcars-runatload\|com.aiteamforge.knowledge-sync' "$f"; then
        _block_note_fail "$f re-declares an installer-only agent (roster drift)"
    fi
done
grep -q '^_xaca1269_installer_only_launchagent_roster()' "$LIB" || _block_note_fail "roster missing from lib"
_block_end

# ── 12. bash 3.2 syntax parity ──────────────────────────────────────────────
_block_start "launchagents.sh parses under /bin/bash"
/bin/bash -n "$LIB" || _block_note_fail "syntax error under /bin/bash"
_block_end

if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "Results: $_PASS passed, $_FAIL failed"
    [ "$_FAIL" -eq 0 ] || exit 1
fi
exit 0
