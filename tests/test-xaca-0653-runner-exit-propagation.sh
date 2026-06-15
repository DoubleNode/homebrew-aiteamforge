#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# XACA-0653 — Regression: test-runner.sh exit-code propagation
# ═══════════════════════════════════════════════════════════════════════════
# Guards the defect where test-runner.sh's results-file branch only PRINTED
# "Failed:" for a suite that exited non-zero but recorded NO "FAIL:" lines
# (suites that keep their OWN pass/fail counters — e.g. the e2e fresh-install
# driver — never call the runner's test_fail, so fails=0). Because FAILED_TESTS
# was never incremented in that branch, the runner reported "All tests passed!"
# and exited 0, silently green-lighting a hard suite failure.
#
# This suite drives the REAL runner against trivial stub suites and asserts:
#   Case A  suite exits 1, writes NO FAIL: lines  -> runner exit code != 0  (the regression)
#   Case B  suite exits 0, writes NO FAIL: lines  -> runner exit code == 0  (no false-positive)
#   Case C  suite calls test_fail (1 FAIL: line) and exits 1
#                                                -> runner exit != 0 AND summary "Failed: 1"
#                                                   (proves the guard does not double-count)
#
# Self-contained: stubs live in an mktemp sandbox, trap-cleaned, no pollution.
# Does NOT depend on a clean install — only exercises the runner's exit-code
# aggregation with trivial stubs, so it runs green on a dev machine and in CI.
#
# Exit codes:
#   0 = all cases passed
#   1 = a regression was detected
# ═══════════════════════════════════════════════════════════════════════════

set -o pipefail

# ─────────────────────────────────────────────────────────────────────────
# Locate the runner under test (sibling of this file)
# ─────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$SCRIPT_DIR/test-runner.sh"

# ─────────────────────────────────────────────────────────────────────────
# Output helpers (match the tap test idiom: pass/fail/section)
# ─────────────────────────────────────────────────────────────────────────
PASS=0
FAIL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

pass() { PASS=$((PASS + 1)); echo -e "  ${GREEN}✓${NC} $1"; }
fail() { FAIL=$((FAIL + 1)); echo -e "  ${RED}✗${NC} $1"; }
section() { echo ""; echo -e "${BLUE}${BOLD}── $1 ──${NC}"; }

# ─────────────────────────────────────────────────────────────────────────
# Sandbox (mktemp + trap cleanup)
# ─────────────────────────────────────────────────────────────────────────
SANDBOX=""
cleanup() {
  if [ -n "$SANDBOX" ] && [ -d "$SANDBOX" ]; then
    rm -rf "$SANDBOX"
  fi
}
trap cleanup EXIT INT TERM

SANDBOX=$(mktemp -d -t xaca-0653-runner.XXXXXX)

# ─────────────────────────────────────────────────────────────────────────
# Preconditions
# ─────────────────────────────────────────────────────────────────────────
section "Preconditions"

if [ -f "$RUNNER" ]; then
  pass "runner under test found: $(basename "$RUNNER")"
else
  fail "runner under test not found: $RUNNER"
  echo ""
  echo -e "${RED}Cannot continue without the runner.${NC}"
  exit 1
fi

if [ -d "$SANDBOX" ]; then
  pass "sandbox created: $SANDBOX"
else
  fail "failed to create sandbox"
  exit 1
fi

# Confirm the runner accepts an out-of-tree absolute path (main() checks
# `[ -f "$test_file" ]` before falling back to $TEST_DIR/$test_file, so an
# absolute path to a stub in the sandbox is honored as-is).
STUB_PROBE="$SANDBOX/stub-probe.sh"
printf '#!/bin/bash\nexit 0\n' > "$STUB_PROBE"
chmod +x "$STUB_PROBE"
probe_out="$(bash "$RUNNER" "$STUB_PROBE" 2>&1)"
if echo "$probe_out" | grep -aq "Running: stub-probe.sh"; then
  pass "runner executes out-of-tree absolute path (no forced tests/ prefix)"
else
  fail "runner did NOT execute the out-of-tree stub — cannot validate exit propagation"
  echo ""
  echo -e "${RED}Runner refused an absolute path arg; escalate rather than hacking the runner.${NC}"
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────
# Case A — the regression: non-zero exit, NO FAIL: lines -> runner must fail
# ─────────────────────────────────────────────────────────────────────────
section "Case A — non-zero suite exit, no FAIL: lines (the XACA-0653 defect)"

STUB_A="$SANDBOX/stub-a-fail-no-faillines.sh"
cat > "$STUB_A" <<'STUB'
#!/bin/bash
# A suite that keeps its OWN counters and never calls the runner's test_fail.
# It prints output and exits non-zero WITHOUT writing any "FAIL:" line to
# TEST_RESULTS_FILE. This is the exact shape of the e2e fresh-install driver
# when its dev-source guard refuses.
echo "stub-a: simulating a hard suite failure with no FAIL: lines"
exit 1
STUB
chmod +x "$STUB_A"

rc_a=0
bash "$RUNNER" "$STUB_A" >/dev/null 2>&1 || rc_a=$?

if [ "$rc_a" -ne 0 ]; then
  pass "runner propagated non-zero exit (rc=$rc_a) for a failing suite with no FAIL: lines"
else
  fail "REGRESSION: runner exited 0 for a suite that exited non-zero with no FAIL: lines"
fi

# ─────────────────────────────────────────────────────────────────────────
# Case B — no false-positive: zero exit, NO FAIL: lines -> runner must pass
# ─────────────────────────────────────────────────────────────────────────
section "Case B — clean suite exit, no FAIL: lines (must stay green)"

STUB_B="$SANDBOX/stub-b-pass-no-faillines.sh"
cat > "$STUB_B" <<'STUB'
#!/bin/bash
echo "stub-b: a clean suite that exits 0 and writes no FAIL: lines"
exit 0
STUB
chmod +x "$STUB_B"

rc_b=0
bash "$RUNNER" "$STUB_B" >/dev/null 2>&1 || rc_b=$?

if [ "$rc_b" -eq 0 ]; then
  pass "runner kept exit 0 for a clean suite (no false-positive failure)"
else
  fail "runner exited non-zero (rc=$rc_b) for a clean, passing suite"
fi

# ─────────────────────────────────────────────────────────────────────────
# Case C — no double-count: a real test_fail (1 FAIL: line) + non-zero exit
# ─────────────────────────────────────────────────────────────────────────
section "Case C — test_fail FAIL: line + non-zero exit (no double-count)"

STUB_C="$SANDBOX/stub-c-testfail-and-exit.sh"
cat > "$STUB_C" <<'STUB'
#!/bin/bash
# Uses the runner's exported framework: one test_start + one test_fail
# (writes a single "FAIL:" line), then exits non-zero. The runner must count
# exactly ONE failure here — the FAIL: line aggregation, NOT an additional
# exit-code increment (the fix's `fails -eq 0` guard prevents the double-count).
test_start "intentional failure"
test_fail "stub-c deliberate failure"
exit 1
STUB
chmod +x "$STUB_C"

out_c="$(bash "$RUNNER" "$STUB_C" 2>&1)"
rc_c=0
bash "$RUNNER" "$STUB_C" >/dev/null 2>&1 || rc_c=$?

if [ "$rc_c" -ne 0 ]; then
  pass "runner propagated non-zero exit (rc=$rc_c) for a test_fail + exit-1 suite"
else
  fail "runner exited 0 for a suite with a FAIL: line and non-zero exit"
fi

# The summary line is "  Failed:       N" — assert exactly 1 (no double-count).
# Strip ANSI color escapes first: when FAILED_TESTS>0 the runner wraps the whole
# summary line in ${RED}...${NC}, so the escape sits BEFORE the word "Failed",
# defeating a naive `^[[:space:]]*Failed:` anchor. We also must avoid the
# per-suite "✗ Failed: <file>" line (no trailing count) — restrict to the
# summary line that ends in a digit.
clean_c="$(printf '%s\n' "$out_c" | sed $'s/\033\\[[0-9;]*m//g')"
failed_n="$(printf '%s\n' "$clean_c" | grep -aE '^[[:space:]]*Failed:[[:space:]]+[0-9]+[[:space:]]*$' | grep -aoE '[0-9]+' | head -1)"
if [ "$failed_n" = "1" ]; then
  pass "summary reports exactly 1 failure (no double-count from exit-code guard)"
else
  fail "summary reported '$failed_n' failures; expected 1 (possible double-count)"
fi

# ─────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}${BOLD}  XACA-0653 runner exit-propagation — Summary${NC}"
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${GREEN}Passed: $PASS${NC}"
if [ "$FAIL" -gt 0 ]; then
  echo -e "  ${RED}Failed: $FAIL${NC}"
else
  echo -e "  Failed: $FAIL"
fi
echo ""

if [ "$FAIL" -eq 0 ]; then
  echo -e "${GREEN}${BOLD}✓ All XACA-0653 exit-propagation checks passed.${NC}"
  echo ""
  exit 0
else
  echo -e "${RED}${BOLD}✗ $FAIL check(s) failed — runner exit-code propagation regressed.${NC}"
  echo ""
  exit 1
fi
