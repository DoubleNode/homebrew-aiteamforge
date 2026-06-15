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
  # || true guards: grep returns nonzero on no-match; set -eo pipefail would abort without it.
  # The standalone version line was removed in XACA-0394 (version now derived from tag:).
  formula_version_val="$(grep -E '^\s+version "' "$FORMULA_FILE" | head -1 | sed 's/.*version "\([^"]*\)".*/\1/' || true)"
  formula_tag_val="$(grep -E 'tag:' "$FORMULA_FILE" | head -1 | sed 's/.*tag: "v\([^"]*\)".*/\1/' || true)"
fi

if [ -z "$version_file_val" ]; then
  fail "VERSION file missing or empty: ${VERSION_FILE}"
elif [ -z "$formula_tag_val" ]; then
  fail "Cannot parse tag from Formula/aiteamforge.rb (expected: tag: \"vX.Y.Z\")"
elif [ "$version_file_val" != "$formula_tag_val" ]; then
  # Tag must strictly match VERSION; formula version line is OPTIONAL (XACA-0394).
  fail "Version mismatch:
    VERSION:                        ${version_file_val}
    Formula/aiteamforge.rb tag:     ${formula_tag_val}${formula_version_val:+
    Formula/aiteamforge.rb version: ${formula_version_val}}
  Fix: align VERSION and tag: \"v...\" to the same value."
elif [ -n "$formula_version_val" ] && [ "$version_file_val" != "$formula_version_val" ]; then
  # Only compare formula version when it's present (not all Formulas have the standalone line).
  fail "Version mismatch:
    VERSION:                        ${version_file_val}
    Formula/aiteamforge.rb version: ${formula_version_val}
    Formula/aiteamforge.rb tag:     ${formula_tag_val}
  Fix: align VERSION, version \"...\", and tag: \"v...\" to the same value."
elif [ -z "$formula_version_val" ]; then
  ok "Version consistent — VERSION and Formula tag agree (${version_file_val}); no standalone version line (derived from tag, per XACA-0394)."
else
  ok "Version consistent across VERSION, Formula version, and Formula tag (${version_file_val})"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Check 3: Stale rebrand filenames
# Any tracked filename matching *doublenode* (case-insensitive) is a leftover
# from the DoubleNode rebrand (XACA-0252). Check is filename-only, not content.
#
# Allow-list (two forms, both skipped):
#   - REBRAND_ALLOWLIST     exact path: the bats test that references the term.
#   - REBRAND_ALLOWLIST_DIR config dir for freelance CLIENT configs created by
#     XACA-0521. Here "doublenode" is the CLIENT name (working dir
#     /Users/Shared/Development/DoubleNode/...), parallel to freelance-liquidstyle-*,
#     NOT rebrand debt. Renaming would break team_transfer identity +
#     amb-session-map.json refs. Only DIRECT children matching freelance-*.yaml
#     are excused (dirname guard) so a genuine rebrand leftover — whether
#     elsewhere in the tree or nested under this dir — still fails. (XACA-0535)
# ─────────────────────────────────────────────────────────────────────────────
REBRAND_ALLOWLIST="tests/xaca-0139-debrand-guard.bats"
REBRAND_ALLOWLIST_DIR="share/lcars-ui/team_transfer/config"

stale_found=false
while IFS= read -r tracked_file; do
  # Skip the allow-listed bats test
  if [ "$tracked_file" = "$REBRAND_ALLOWLIST" ]; then
    continue
  fi
  # Skip allow-listed freelance client configs — DIRECT children of the flat
  # config dir only. The quoted dir + literal `freelance-*.yaml` glob matches
  # the family; the dirname guard then rejects any nested path the glob's `*`
  # would otherwise span (e.g. config/freelance-X/evil-doublenode.yaml stays a
  # failure). Keeps the allow-list narrow to where 'doublenode' is the CLIENT
  # name, not rebrand debt. (XACA-0535)
  case "$tracked_file" in
    "$REBRAND_ALLOWLIST_DIR"/freelance-*.yaml)
      if [ "$(dirname "$tracked_file")" = "$REBRAND_ALLOWLIST_DIR" ]; then
        continue
      fi
      ;;
  esac
  fail "Stale rebrand filename: ${tracked_file} (tracked filename contains 'doublenode' — remove or rename)"
  stale_found=true
done < <(git -C "$TAP_ROOT" ls-files | grep -iE 'doublenode' || true)

if [ "$stale_found" = false ]; then
  ok "No stale rebrand filenames found (allow-listed: ${REBRAND_ALLOWLIST}, ${REBRAND_ALLOWLIST_DIR}/freelance-*.yaml)"
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
