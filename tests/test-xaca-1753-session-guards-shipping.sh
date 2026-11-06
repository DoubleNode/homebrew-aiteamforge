#!/bin/bash
# test-xaca-1753-session-guards-shipping.sh
#
# XACA-1753-003: the fleet-wide SessionStart/Stop session guards ship from the
# tap's share/scripts/ (flat layout; installed at ~/aiteamforge/scripts/).
# claude-hooks/ and scripts/ BOTH flatten there, so every hook must find aitf-root.sh
# and its checker as a SIBLING. This suite pins:
#   S1  every shipped file is present in share/scripts/
#   S2  every shipped file is executable (hooks are invoked directly)
#   S3  every hook, copied with ONLY its siblings into a fixture
#       $HOME/aiteamforge/scripts, resolves its checker in the flat layout —
#       no "could not check: ... not found" and no "aitf-root.sh not found"
#   S4  the health checker's REPO_ROOT-relative read of kb-knowledge-sync.sh
#       resolves in the flat layout (kb-knowledge-sync.sh is shipped)
#   S5  the live-config drift checker STARTS from the flat copy in consumer
#       mode (templates + install-claude-config.sh resolved via framework_home)
#       and reports a verdict, not "No such file"
#   S6  mutation sentinel: a fixture built WITHOUT a checker must flip S3's
#       "could not check" detector red (so S3 cannot pass vacuously)
#
# Runs standalone or via test-runner.sh. Never touches real $HOME. No network.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SHIP_DIR="$TAP_ROOT/share/scripts"

if ! type -t test_start >/dev/null 2>&1; then
    _PASS_COUNT=0
    _FAIL_COUNT=0
    _CURRENT_TEST=""
    test_start() { _CURRENT_TEST="$1"; echo "  >> $1"; }
    test_pass()  { _PASS_COUNT=$((_PASS_COUNT + 1)); echo "     PASS: $_CURRENT_TEST"; }
    test_fail()  { _FAIL_COUNT=$((_FAIL_COUNT + 1)); echo "     FAIL: $_CURRENT_TEST — $1" >&2; }
fi

HOOKS="kb-gh-credential-guard.sh kb-knowledge-sync-guard.sh kb-team-registry-loss-guard.sh kb-lcars-port-drift-guard.sh kb-where-refresh.sh kanban-crash-detect.sh kb-session-knowledge-check.sh kb-live-config-drift-guard.sh"
CHECKERS="kb-gh-credential-check.sh kb-team-registry-loss-check.py kb-knowledge-sync-health-check.sh kb-lcars-port-drift-check.sh kb-live-config-drift-check.sh"
SHIPPED="aitf-root.sh $HOOKS $CHECKERS kb-knowledge-sync.sh kb-where"

if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca1753-guards.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
TEST_TMP_DIR="$(cd "$TEST_TMP_DIR" && pwd -P)"
cleanup() {
    if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ] && [ -d "$TEST_TMP_DIR" ]; then
        find "$TEST_TMP_DIR" -depth -delete 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ── S1 / S2 ─────────────────────────────────────────────────────────────────
for f in $SHIPPED; do
    test_start "S1 share/scripts/$f is present"
    if [ -f "$SHIP_DIR/$f" ]; then test_pass; else test_fail "missing $SHIP_DIR/$f"; fi
    test_start "S2 share/scripts/$f is executable"
    if [ -x "$SHIP_DIR/$f" ]; then test_pass; else test_fail "not executable: $SHIP_DIR/$f"; fi
done

# ── Fixture: installed layout with only the shipped siblings ────────────────
# $1 = fixture root, $2 = optional space-separated basenames to leave out
make_fixture() {
    local root="$1" skip=" ${2:-} " f
    mkdir -p "$root/home/aiteamforge/scripts" "$root/home/.aiteamforge" "$root/home/knowledge"
    for f in $SHIPPED; do
        case "$skip" in *" $f "*) continue ;; esac
        [ -f "$SHIP_DIR/$f" ] && cp -p "$SHIP_DIR/$f" "$root/home/aiteamforge/scripts/$f"
    done
    # kanban-helpers.sh is installed one level up (install-kanban.sh), not in
    # scripts/. A stub is enough: the hooks only need to LOCATE it.
    printf '#!/bin/bash\n:\n' > "$root/home/aiteamforge/kanban-helpers.sh"
}

run_hook() {  # $1 = fixture root, $2 = hook; stdout+stderr -> $1/out.$2
    local root="$1" h="$2"
    echo '{"session_id":"xaca1753","cwd":"/tmp","hook_event_name":"SessionStart"}' \
      | ( cd "$root" && env -i HOME="$root/home" PATH="$PATH" TMPDIR="$root" \
          bash "$root/home/aiteamforge/scripts/$h" >"$root/out.$h" 2>&1 )
    return $?
}

# Output meaning "the hook could not find a sibling it ships with". A checker's
# own "registry not found" FAIL-CLOSED text is a different, healthy message about
# the fixture's missing DATA, so match the hook-side wording only.
sibling_missing() {
    grep -Eqi 'could not check: .*(not found|missing)|aitf-root\.sh (not found|missing)' "$1"
}

FIX="$TEST_TMP_DIR/fixture"
make_fixture "$FIX"

for h in $HOOKS; do
    test_start "S3 $h resolves siblings in the flat layout"
    run_hook "$FIX" "$h"; rc=$?
    if [ "$rc" -ne 0 ]; then
        test_fail "hook exited $rc (hooks must always exit 0): $(head -c 300 "$FIX/out.$h")"
    elif sibling_missing "$FIX/out.$h"; then
        test_fail "sibling lookup failed: $(grep -Ei 'could not check' "$FIX/out.$h" | head -1 | cut -c1-300)"
    else
        test_pass
    fi
done

# ── S4: health-check REPO_ROOT-relative dependency ──────────────────────────
test_start "S4 health check finds kb-knowledge-sync.sh under its REPO_ROOT (flat layout)"
if [ -f "$FIX/home/aiteamforge/scripts/kb-knowledge-sync.sh" ] \
   && grep -q '^INDEX_MAX_BYTES=' "$FIX/home/aiteamforge/scripts/kb-knowledge-sync.sh"; then
    test_pass
else
    test_fail "kb-knowledge-sync.sh (or its INDEX_MAX_BYTES) not reachable at \$REPO_ROOT/scripts/"
fi

# ── S5: drift checker starts from the flat copy in consumer mode ────────────
# framework_home points at the tap tree, so $TPL/../libexec/installers/
# install-claude-config.sh (the renderer it sources) is the real shipped one.
test_start "S5 kb-live-config-drift-check.sh runs from the flat copy (consumer mode)"
if command -v jq >/dev/null 2>&1; then
    printf '{"framework_home": "%s"}\n' "$TAP_ROOT" > "$FIX/home/aiteamforge/.aiteamforge-config"
    mkdir -p "$FIX/home/.claude"
    out="$(env -i HOME="$FIX/home" PATH="$PATH" TMPDIR="$FIX" \
        bash "$FIX/home/aiteamforge/scripts/kb-live-config-drift-check.sh" 2>&1)"; rc=$?
    if [ "$rc" -eq 2 ] || printf '%s' "$out" | grep -Eqi 'No such file|no dev checkout and no installed'; then
        test_fail "rc=$rc: $(printf '%s' "$out" | head -2 | cut -c1-300)"
    elif [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
        test_fail "unexpected rc=$rc: $(printf '%s' "$out" | head -2 | cut -c1-300)"
    else
        test_pass
    fi
else
    test_pass   # jq is a hard prerequisite of the checker's consumer mode; CI installs it
fi

# ── S6: mutation sentinel ───────────────────────────────────────────────────
test_start "S6 sentinel: detector flags a hook whose checker is absent"
MUT="$TEST_TMP_DIR/mutant"
make_fixture "$MUT" "kb-gh-credential-check.sh"
run_hook "$MUT" kb-gh-credential-guard.sh
if sibling_missing "$MUT/out.kb-gh-credential-guard.sh"; then
    test_pass
else
    test_fail "an absent checker was NOT detected; S3 would pass vacuously"
fi

if [ -n "${_PASS_COUNT+x}" ]; then
    echo ""
    echo "XACA-1753 session-guards-shipping tests: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    [ "${_FAIL_COUNT:-0}" -eq 0 ] || exit 1
fi
exit 0
