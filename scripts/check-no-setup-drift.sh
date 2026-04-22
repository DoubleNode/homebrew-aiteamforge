#!/bin/bash
# check-no-setup-drift.sh
#
# Drift guard for the AITeamForge setup wizard (XACA-0173).
#
# Before XACA-0173, two aiteamforge-setup.sh files existed — one in bin/
# (dispatched by Homebrew) and one in libexec/ (orphaned, but referenced by
# tests). Features drifted between them: XACA-0160 only landed in libexec,
# forcing XACA-0159 to re-implement the same pass in bin, and bin-only
# regressions were masked because tests exercised libexec.
#
# Post-consolidation, bin/aiteamforge-setup.sh is the ONLY wizard. This guard
# enforces that invariant — it fails if anyone resurrects the libexec copy or
# its architecture-specific test.
#
# Invoked from:
#   - .githooks/pre-commit (opt-in via `git config core.hooksPath .githooks`)
#   - .github/workflows/tests.yml (authoritative gate)

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

failures=0
fail() {
  echo -e "${RED}✗ ${1}${NC}" >&2
  failures=$((failures + 1))
}
ok() {
  echo -e "${GREEN}✓ ${1}${NC}"
}

# 1. The canonical wizard must exist and be executable.
canonical="${TAP_ROOT}/bin/aiteamforge-setup.sh"
if [ ! -f "$canonical" ]; then
  fail "Missing canonical wizard: bin/aiteamforge-setup.sh"
elif [ ! -x "$canonical" ]; then
  fail "Canonical wizard is not executable: bin/aiteamforge-setup.sh"
else
  ok "bin/aiteamforge-setup.sh present and executable"
fi

# 2. The orphaned libexec copy must NOT exist. Resurrecting it reintroduces
#    the drift that XACA-0173 eliminated.
orphan="${TAP_ROOT}/libexec/aiteamforge-setup.sh"
if [ -e "$orphan" ]; then
  fail "Orphaned wizard resurrected: libexec/aiteamforge-setup.sh must stay deleted (see XACA-0173)"
else
  ok "libexec/aiteamforge-setup.sh correctly absent"
fi

# 3. The libexec-architecture regression test must NOT exist. It only made
#    sense when two wizards existed.
legacy_test="${TAP_ROOT}/tests/test-setup-wizard.sh"
if [ -e "$legacy_test" ]; then
  fail "Legacy test resurrected: tests/test-setup-wizard.sh must stay deleted (see XACA-0173)"
else
  ok "tests/test-setup-wizard.sh correctly absent"
fi

if [ "$failures" -gt 0 ]; then
  echo "" >&2
  echo -e "${RED}Setup-wizard drift guard FAILED (${failures} issue(s)).${NC}" >&2
  echo "See XACA-0173 for background on why the single-wizard invariant matters." >&2
  exit 1
fi

echo "Setup-wizard drift guard passed."
