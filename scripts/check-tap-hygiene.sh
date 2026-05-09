#!/bin/bash
# check-tap-hygiene.sh
#
# Tap-internal hygiene guard for the AITeamForge homebrew tap (XACA-0361).
#
# Catches three classes of drift that the XACA-0215 pre-push / sync-tap-check
# guards don't cover (those only guard files mapped by sync-tap.sh):
#
#   1. Orphan formula files — Formula/ should contain only aiteamforge.rb.
#      An extra .rb, .bak, or .swp file indicates a forgotten experiment.
#
#   2. Version inconsistency — VERSION file, Formula/aiteamforge.rb version "...",
#      and Formula/aiteamforge.rb tag: "v..." must all agree. Drift here means
#      brew install gets the wrong tag and the marker file stamps the wrong version.
#
#   3. Stale rebrand filenames — Any tracked filename containing "doublenode"
#      (case-insensitive) outside the allow-list is a leftover from the DoubleNode
#      rebrand (see XACA-0252). These files are dead weight and confuse the
#      debrand-guard content checks.
#
# Invoked from:
#   - .githooks/pre-commit (opt-in via `git config core.hooksPath .githooks`)
#   - .github/workflows/tests.yml (authoritative gate)
#
# Exit 0 → all checks passed.
# Exit 1 → one or more failures; all checks run before exiting.

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

# ─────────────────────────────────────────────────────────────────────────────
# Check 1: Orphan formula files
# Formula/ must contain only aiteamforge.rb. Any other .rb/.bak/.swp file
# is unexpected and likely a stale experiment.
# ─────────────────────────────────────────────────────────────────────────────
FORMULA_ALLOW_LIST="aiteamforge.rb"

orphan_found=false
while IFS= read -r f; do
  base="$(basename "$f")"
  if [ "$base" != "$FORMULA_ALLOW_LIST" ]; then
    fail "Orphan formula file: Formula/${base} (expected only ${FORMULA_ALLOW_LIST})"
    orphan_found=true
  fi
done < <(find "$TAP_ROOT/Formula" -maxdepth 1 -type f 2>/dev/null)

if [ "$orphan_found" = false ]; then
  ok "Formula/ contains only expected files (${FORMULA_ALLOW_LIST})"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Check 2: Version consistency
# VERSION file, Formula version "X.Y.Z", and Formula tag: "vX.Y.Z" must agree.
# ─────────────────────────────────────────────────────────────────────────────
FORMULA_FILE="${TAP_ROOT}/Formula/aiteamforge.rb"
VERSION_FILE="${TAP_ROOT}/VERSION"

version_file_val=""
formula_version_val=""
formula_tag_val=""

if [ -f "$VERSION_FILE" ]; then
  version_file_val="$(tr -d '[:space:]' < "$VERSION_FILE")"
fi

if [ -f "$FORMULA_FILE" ]; then
  formula_version_val="$(grep -E '^\s+version "' "$FORMULA_FILE" | head -1 | sed 's/.*version "\([^"]*\)".*/\1/')"
  formula_tag_val="$(grep -E 'tag:' "$FORMULA_FILE" | head -1 | sed 's/.*tag: "v\([^"]*\)".*/\1/')"
fi

if [ -z "$version_file_val" ]; then
  fail "VERSION file missing or empty: ${VERSION_FILE}"
elif [ -z "$formula_version_val" ]; then
  fail "Cannot parse version from Formula/aiteamforge.rb (expected: version \"X.Y.Z\")"
elif [ -z "$formula_tag_val" ]; then
  fail "Cannot parse tag from Formula/aiteamforge.rb (expected: tag: \"vX.Y.Z\")"
elif [ "$version_file_val" != "$formula_version_val" ] || \
     [ "$version_file_val" != "$formula_tag_val" ] || \
     [ "$formula_version_val" != "$formula_tag_val" ]; then
  fail "Version mismatch — all three must agree:
    VERSION:                ${version_file_val}
    Formula/aiteamforge.rb version:  ${formula_version_val}
    Formula/aiteamforge.rb tag:      ${formula_tag_val}
  Fix: align VERSION, version \"...\", and tag: \"v...\" to the same value."
else
  ok "Version consistent across VERSION, Formula version, and Formula tag (${version_file_val})"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Check 3: Stale rebrand filenames
# Any tracked filename matching *doublenode* (case-insensitive) is a leftover
# from the DoubleNode rebrand (XACA-0252). Check is filename-only, not content.
# Allow-list: the bats test that legitimately references the term in its name.
# ─────────────────────────────────────────────────────────────────────────────
REBRAND_ALLOWLIST="tests/xaca-0139-debrand-guard.bats"

stale_found=false
while IFS= read -r tracked_file; do
  # Skip the allow-listed bats test
  if [ "$tracked_file" = "$REBRAND_ALLOWLIST" ]; then
    continue
  fi
  fail "Stale rebrand filename: ${tracked_file} (tracked filename contains 'doublenode' — remove or rename)"
  stale_found=true
done < <(git -C "$TAP_ROOT" ls-files | grep -iE 'doublenode' || true)

if [ "$stale_found" = false ]; then
  ok "No stale rebrand filenames found (allow-listed: ${REBRAND_ALLOWLIST})"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
if [ "$failures" -gt 0 ]; then
  echo "" >&2
  echo -e "${RED}Tap-hygiene guard FAILED (${failures} issue(s)).${NC}" >&2
  echo "See XACA-0361 for context on what each check enforces." >&2
  exit 1
fi

echo "Tap-hygiene guard passed."
