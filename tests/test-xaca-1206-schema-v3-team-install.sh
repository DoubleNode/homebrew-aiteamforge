#!/bin/bash
# test-xaca-1206-schema-v3-team-install.sh
#
# XACA-1206: on a consumer whose team-paths.json is schema_version 3 — which
# the Python reader has WRITTEN since XACA-0279 — installing a team through the
# port allocator failed. Two defects combined:
#
#   1. libexec/lib/aiteamforge-paths.sh treated schema_version outside {0,1,2}
#      as unsupported at TWO sites (the jq overlay filter and its python
#      fallback) and printed "[aiteamforge-paths] WARNING: schema_version=3
#      unsupported" on stderr.
#   2. libexec/installers/install-team.sh captured the allocator with `2>&1`,
#      so that warning became part of TEAM_LCARS_PORT and the startup-script
#      sed died ("unescaped newline inside substitute pattern").
#
# MEASURED on M4Mini upgrading to v0.20.10: the XACA-1070 mandatory Space Dock
# backfill reported "Provisioned 0 mandatory team(s); 1 failed".
#
# Each half is tested on its own, so reverting EITHER fix turns this suite red:
#   A/B  — no v3 warning on the jq path and on the python-fallback path
#   C    — v2 control (never warned)
#   D    — an unknown version still warns (the warning was not deleted)
#   E/F  — install-team.sh's capture block, executed against stub allocators:
#          stderr noise never reaches the port; a non-port stdout fails closed
#   G    — assertion-count pin
#
# Sandboxed: every config is a TEST_TMP_DIR fixture passed via
# AITEAMFORGE_CONFIG and the allocator's explicit path argument. Nothing reads
# or writes the real ~/.aiteamforge. Runs under /bin/bash 3.2 and bash 5.

# Harness detection keys on the harness FUNCTIONS, not on TEST_TMP_DIR
# (XACA-1206-011). The inherited pattern (`[ -z "$TEST_TMP_DIR" ]`) treats a
# caller-exported TEST_TMP_DIR as "running under test-runner.sh" — so a bare
# invocation from a sandboxed shell defined no test_pass/test_fail, every
# assertion died with "command not found", and the suite exited 0 having
# asserted nothing. A pre-set TEST_TMP_DIR is honoured as the scratch root;
# only the absence of test_pass decides standalone mode.
_STANDALONE=false
if ! type test_pass >/dev/null 2>&1; then
    _STANDALONE=true
    if [ -z "${TEST_TMP_DIR:-}" ]; then
        TEST_TMP_DIR=$(mktemp -d -t aiteamforge-xaca1206-test.XXXXXX)
        trap 'rm -rf "$TEST_TMP_DIR"' EXIT INT TERM
    else
        mkdir -p "$TEST_TMP_DIR" || { echo "cannot create TEST_TMP_DIR=$TEST_TMP_DIR" >&2; exit 1; }
    fi
    _PASS_COUNT=0
    _FAIL_COUNT=0
    test_start() { _CURRENT_TEST="$1"; }
    test_pass() {
        _PASS_COUNT=$(( _PASS_COUNT + 1 ))
        printf "PASS: %s\n" "$_CURRENT_TEST"
    }
    test_fail() {
        _FAIL_COUNT=$(( _FAIL_COUNT + 1 ))
        printf "FAIL: %s — %s\n" "$_CURRENT_TEST" "$1" >&2
    }
fi

_ASSERTIONS=0
check() {
    # check <description> <condition-result: 0 pass / non-zero fail> <detail>
    _ASSERTIONS=$(( _ASSERTIONS + 1 ))
    test_start "$1"
    if [ "$2" -eq 0 ]; then test_pass; else test_fail "$3"; fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PATHS_LIB="$TAP_ROOT/libexec/lib/aiteamforge-paths.sh"
INSTALL_TEAM="$TAP_ROOT/libexec/installers/install-team.sh"
# Child shells use the SAME bash running this suite, so a bash-5 run exercises
# bash 5 end to end instead of silently dropping to /bin/bash 3.2 inside.
BASH_BIN="${BASH:-/bin/bash}"
export AITEAMFORGE_ALLOW_DEV_OVERWRITE="${AITEAMFORGE_ALLOW_DEV_OVERWRITE:-}"

write_fixture() {
    # write_fixture <schema_version> <path>
    printf '{"schema_version": %s, "teams": {"academy": {"lcars_port": 8203}}}\n' "$1" > "$2"
}

# run_allocator <config> [PATH override]
# Sources the lib in a FRESH bash (the lib guards against double-sourcing) and
# writes stdout / stderr / rc to separate files.
run_allocator() {
    local cfg="$1" path_override="${2:-}"
    local out="$TEST_TMP_DIR/alloc.out" err="$TEST_TMP_DIR/alloc.err"
    if [ -n "$path_override" ]; then
        PATH="$path_override" AITEAMFORGE_CONFIG="$cfg" "$BASH_BIN" -c \
            '. "$1" && aiteamforge_compute_instance_port spacedock "$2"' _ "$PATHS_LIB" "$cfg" \
            >"$out" 2>"$err"
    else
        AITEAMFORGE_CONFIG="$cfg" "$BASH_BIN" -c \
            '. "$1" && aiteamforge_compute_instance_port spacedock "$2"' _ "$PATHS_LIB" "$cfg" \
            >"$out" 2>"$err"
    fi
    ALLOC_RC=$?
    ALLOC_OUT=$(cat "$out")
    ALLOC_ERR=$(cat "$err")
}

is_port() { case "$1" in ''|*[!0-9]*|0) return 1 ;; *) return 0 ;; esac; }

printf "=== XACA-1206: schema_version 3 team install ===\n"

# ── A: jq path, schema 3 ─────────────────────────────────────────────────────
if command -v jq >/dev/null 2>&1; then
    write_fixture 3 "$TEST_TMP_DIR/v3.json"
    run_allocator "$TEST_TMP_DIR/v3.json"
    is_port "$ALLOC_OUT"; r=$?
    check "A1: jq path, v3 — allocator stdout is a bare port" "$r" "stdout=[$ALLOC_OUT] rc=$ALLOC_RC"
    printf '%s' "$ALLOC_ERR" | grep -q 'schema_version=3 unsupported'; r=$?
    [ "$r" -ne 0 ]; r=$?
    check "A2: jq path, v3 — no 'schema_version=3 unsupported' on stderr" "$r" "stderr=[$ALLOC_ERR]"
else
    check "A0: jq must be on PATH for the jq-path cases" 1 "jq not found — install jq; refusing to report the jq path as green without running it"
fi

# ── B: python fallback, schema 3 (jq hidden) ─────────────────────────────────
# Build a PATH that has every tool the lib needs EXCEPT jq, then PROVE jq is
# hidden before trusting the result — a shim that still exposes jq would run
# the jq path twice and call it fallback coverage.
SHIM="$TEST_TMP_DIR/nojq-bin"
mkdir -p "$SHIM"
for tool in python3 awk sed grep sort tr cut head tail dirname basename cat \
            mktemp uname stat seq env wc uniq date printf rm mkdir; do
    p=$(command -v "$tool" 2>/dev/null) || continue
    case "$p" in /*) ln -sf "$p" "$SHIM/$tool" ;; esac
done
PATH="$SHIM" "$BASH_BIN" -c 'command -v jq >/dev/null 2>&1'; hidden=$?
[ "$hidden" -ne 0 ]; r=$?
check "B0: fallback shim really hides jq (non-vacuous guard)" "$r" "jq still resolvable under the shim PATH"
write_fixture 3 "$TEST_TMP_DIR/v3b.json"
run_allocator "$TEST_TMP_DIR/v3b.json" "$SHIM"
is_port "$ALLOC_OUT"; r=$?
check "B1: python fallback, v3 — allocator stdout is a bare port" "$r" "stdout=[$ALLOC_OUT] stderr=[$ALLOC_ERR] rc=$ALLOC_RC"
printf '%s' "$ALLOC_ERR" | grep -q 'schema_version=3 unsupported'; r=$?
[ "$r" -ne 0 ]; r=$?
check "B2: python fallback, v3 — no 'schema_version=3 unsupported' on stderr" "$r" "stderr=[$ALLOC_ERR]"

# ── C: v2 control ────────────────────────────────────────────────────────────
write_fixture 2 "$TEST_TMP_DIR/v2.json"
run_allocator "$TEST_TMP_DIR/v2.json"
printf '%s' "$ALLOC_ERR" | grep -q 'unsupported'; r=$?
[ "$r" -ne 0 ] && is_port "$ALLOC_OUT"; r=$?
check "C1: v2 control — bare port, no warning" "$r" "stdout=[$ALLOC_OUT] stderr=[$ALLOC_ERR]"

# ── D: unknown version still warns ───────────────────────────────────────────
write_fixture 99 "$TEST_TMP_DIR/v99.json"
run_allocator "$TEST_TMP_DIR/v99.json"
printf '%s' "$ALLOC_ERR" | grep -q 'schema_version=99 unsupported'; r=$?
check "D1: unknown schema_version 99 still warns on stderr (warning preserved)" "$r" "stderr=[$ALLOC_ERR]"
is_port "$ALLOC_OUT"; r=$?
check "D2: unknown schema_version 99 — the warning stays OFF stdout" "$r" "stdout=[$ALLOC_OUT]"

# ── E/F: install-team.sh capture block, executed ─────────────────────────────
# Extract the real block (from the allocator capture through the assignment)
# and run it against stub allocators. Testing the extracted production lines,
# not a re-typed copy, is what makes a revert of the `2>&1` removal visible.
BLOCK="$TEST_TMP_DIR/capture-block.sh"
awk '
    /_xaca0463_allocated=""/ { p=1 }
    p { print }
    p && /TEAM_LCARS_PORT="\$_xaca0463_allocated"/ { exit }
' "$INSTALL_TEAM" > "$BLOCK"
lines=$(grep -c . "$BLOCK")
[ "$lines" -ge 3 ] && grep -q 'TEAM_LCARS_PORT="\$_xaca0463_allocated"' "$BLOCK"; r=$?
check "E0: extracted install-team.sh capture block ($lines lines)" "$r" "could not extract the block — anchors changed?"

run_block() {
    # run_block <stub-body>
    "$BASH_BIN" -c '
        TEAM_ID=spacedock; _xaca0463_team_paths=/nonexistent
        aiteamforge_compute_instance_port() { '"$1"'; }
        . "$1"
        printf "%s" "$TEAM_LCARS_PORT"
    ' _ "$BLOCK" >"$TEST_TMP_DIR/blk.out" 2>"$TEST_TMP_DIR/blk.err"
    BLK_RC=$?
    BLK_OUT=$(cat "$TEST_TMP_DIR/blk.out")
}

run_block 'echo "[aiteamforge-paths] WARNING: schema_version=3 unsupported" >&2; echo 8380'
[ "$BLK_RC" -eq 0 ] && [ "$BLK_OUT" = "8380" ]; r=$?
check "E1: stderr noise from the allocator never reaches TEAM_LCARS_PORT" "$r" "rc=$BLK_RC port=[$BLK_OUT]"

run_block 'echo "not-a-port"'
[ "$BLK_RC" -ne 0 ]; r=$?
check "F1: exit-0 allocator with non-port stdout fails closed" "$r" "rc=$BLK_RC port=[$BLK_OUT]"

run_block 'echo ""'
[ "$BLK_RC" -ne 0 ]; r=$?
check "F2: exit-0 allocator with empty stdout fails closed" "$r" "rc=$BLK_RC port=[$BLK_OUT]"

run_block 'echo "Port band exhausted" >&2; return 1'
[ "$BLK_RC" -ne 0 ]; r=$?
check "F3: failing allocator still exits non-zero" "$r" "rc=$BLK_RC"

# ── G: assertion-count pin ───────────────────────────────────────────────────
# A suite that silently stops asserting is indistinguishable from a passing one.
# Counted BEFORE G1 itself: 13 when jq is present (A1, A2), 12 without (A0).
expected=13
command -v jq >/dev/null 2>&1 || expected=12
[ "$_ASSERTIONS" -eq "$expected" ]; r=$?
check "G1: assertion-count pin ($expected expected, $_ASSERTIONS ran)" "$r" "assertion count drifted"

if [ "$_STANDALONE" = true ]; then
    printf "\nResults: %d passed, %d failed\n" "$_PASS_COUNT" "$_FAIL_COUNT"
    [ "$_FAIL_COUNT" -eq 0 ] || exit 1
    # A run that recorded no passes asserted nothing — that is not a green.
    [ "$_PASS_COUNT" -gt 0 ] || { echo "no assertions passed — refusing to report success" >&2; exit 1; }
fi
