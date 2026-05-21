#!/usr/bin/env bats
# XACA-0361: Tap-hygiene guard coverage
#
# Tests scripts/check-tap-hygiene.sh against a TEMP COPY of the tap tree.
# The live tree is never mutated.
#
# Test cases:
#   1. Clean tree → script exits 0
#   2. Orphan formula file added → exits 1, message names the orphan
#   3. VERSION mismatched → exits 1, message names VERSION and Formula/aiteamforge.rb
#   4. Stale doublenode filename tracked → exits 1, message names the file
#
# Fixture pattern mirrors xaca-0139-debrand-guard.bats: setup() copies the
# minimal tap structure to a BATS_TEST_TMPDIR-scoped directory; teardown()
# removes it. Tests mutate their own FIXTURE_DIR, never the real tap.

TAP_ROOT="${BATS_TEST_DIRNAME}/.."
SCRIPT="${TAP_ROOT}/scripts/check-tap-hygiene.sh"

setup() {
  # Create a minimal tap fixture in a temp directory.
  # We only need the files check-tap-hygiene.sh actually inspects.
  FIXTURE_DIR="${BATS_TEST_TMPDIR}/tap-fixture"
  mkdir -p "${FIXTURE_DIR}/Formula"
  mkdir -p "${FIXTURE_DIR}/scripts"
  mkdir -p "${FIXTURE_DIR}/tests"
  mkdir -p "${FIXTURE_DIR}/fleet-monitor/plugins"

  # Minimal valid Formula/aiteamforge.rb
  cat > "${FIXTURE_DIR}/Formula/aiteamforge.rb" <<'RUBY'
class Aiteamforge < Formula
  version "1.2.3"
  url "https://github.com/DoubleNode/homebrew-aiteamforge.git",
      tag: "v1.2.3"
end
RUBY

  # VERSION aligned with formula
  printf '1.2.3\n' > "${FIXTURE_DIR}/VERSION"

  # Copy the real check script into the fixture (it derives TAP_ROOT from BASH_SOURCE)
  cp "${SCRIPT}" "${FIXTURE_DIR}/scripts/check-tap-hygiene.sh"
  chmod +x "${FIXTURE_DIR}/scripts/check-tap-hygiene.sh"

  # Initialize a bare git repo in the fixture so `git ls-files` works.
  # We only add the files we want "tracked"; the stale-rebrand check uses git ls-files.
  git -C "${FIXTURE_DIR}" init -q
  git -C "${FIXTURE_DIR}" config user.email "test@example.com"
  git -C "${FIXTURE_DIR}" config user.name "Test"
  git -C "${FIXTURE_DIR}" add Formula/aiteamforge.rb VERSION scripts/check-tap-hygiene.sh
  git -C "${FIXTURE_DIR}" commit -q -m "fixture init"
}

teardown() {
  rm -rf "${FIXTURE_DIR}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 1: Clean tree exits 0
# ─────────────────────────────────────────────────────────────────────────────
@test "xaca-0361: clean tree passes all checks" {
  run bash "${FIXTURE_DIR}/scripts/check-tap-hygiene.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "passed" ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 2: Orphan formula file triggers failure naming the orphan
# ─────────────────────────────────────────────────────────────────────────────
@test "xaca-0361: orphan formula file exits 1 and names the orphan" {
  # Add a tracked orphan formula
  touch "${FIXTURE_DIR}/Formula/orphan.rb"
  git -C "${FIXTURE_DIR}" add Formula/orphan.rb
  git -C "${FIXTURE_DIR}" commit -q -m "add orphan"

  run bash "${FIXTURE_DIR}/scripts/check-tap-hygiene.sh"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "orphan.rb" ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 3: VERSION mismatch exits 1, message names both VERSION and Formula
# ─────────────────────────────────────────────────────────────────────────────
@test "xaca-0361: VERSION mismatch exits 1 and names VERSION and Formula/aiteamforge.rb" {
  # Mutate VERSION to disagree with Formula
  printf '9.9.9\n' > "${FIXTURE_DIR}/VERSION"
  git -C "${FIXTURE_DIR}" add VERSION
  git -C "${FIXTURE_DIR}" commit -q -m "bump VERSION"

  run bash "${FIXTURE_DIR}/scripts/check-tap-hygiene.sh"
  [ "$status" -eq 1 ]
  # Error message should mention both sources
  [[ "$output" =~ "VERSION" ]]
  [[ "$output" =~ "Formula/aiteamforge.rb" ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 4: Stale doublenode filename exits 1 and names the offending path
# ─────────────────────────────────────────────────────────────────────────────
@test "xaca-0361: stale doublenode filename exits 1 and names the path" {
  # Add a tracked file whose name contains 'doublenode'
  mkdir -p "${FIXTURE_DIR}/fleet-monitor/legacy"
  touch "${FIXTURE_DIR}/fleet-monitor/legacy/foo-doublenode.html"
  git -C "${FIXTURE_DIR}" add fleet-monitor/legacy/foo-doublenode.html
  git -C "${FIXTURE_DIR}" commit -q -m "add stale rebrand file"

  run bash "${FIXTURE_DIR}/scripts/check-tap-hygiene.sh"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "foo-doublenode.html" ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 5: Freelance client config matching 'doublenode' is allow-listed (XACA-0535)
# freelance-<client>-*.yaml under team_transfer/config is the CLIENT name, not
# rebrand debt — it must NOT trip Check 3. Regression guard for the false-positive
# that forced a --no-verify bypass during XACA-0528.
# ─────────────────────────────────────────────────────────────────────────────
@test "xaca-0361: freelance client config (doublenode) is allow-listed and passes" {
  # Add a tracked freelance client config whose name contains 'doublenode'
  mkdir -p "${FIXTURE_DIR}/share/lcars-ui/team_transfer/config"
  printf 'team: freelance-doublenode-foo\n' \
    > "${FIXTURE_DIR}/share/lcars-ui/team_transfer/config/freelance-doublenode-foo.yaml"
  git -C "${FIXTURE_DIR}" add share/lcars-ui/team_transfer/config/freelance-doublenode-foo.yaml
  git -C "${FIXTURE_DIR}" commit -q -m "add freelance client config"

  run bash "${FIXTURE_DIR}/scripts/check-tap-hygiene.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "passed" ]]
  # The allow-listed config must not appear as a failure
  [[ ! "$output" =~ "Stale rebrand filename" ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 6: Allow-list stays narrow — a doublenode file OUTSIDE the freelance config
# dir still fails even when a legit freelance config is also present.
# ─────────────────────────────────────────────────────────────────────────────
@test "xaca-0361: allow-list is narrow — doublenode file outside config dir still fails" {
  mkdir -p "${FIXTURE_DIR}/share/lcars-ui/team_transfer/config"
  printf 'team: freelance-doublenode-foo\n' \
    > "${FIXTURE_DIR}/share/lcars-ui/team_transfer/config/freelance-doublenode-foo.yaml"
  # A genuine rebrand leftover elsewhere must NOT be excused by the glob
  mkdir -p "${FIXTURE_DIR}/fleet-monitor/legacy"
  touch "${FIXTURE_DIR}/fleet-monitor/legacy/bar-doublenode.js"
  git -C "${FIXTURE_DIR}" add \
    share/lcars-ui/team_transfer/config/freelance-doublenode-foo.yaml \
    fleet-monitor/legacy/bar-doublenode.js
  git -C "${FIXTURE_DIR}" commit -q -m "add freelance config + stale file"

  run bash "${FIXTURE_DIR}/scripts/check-tap-hygiene.sh"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "bar-doublenode.js" ]]
  # The freelance config must NOT be among the flagged files
  [[ ! "$output" =~ "freelance-doublenode-foo.yaml" ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 7: dirname guard — a NESTED path under the freelance config dir is NOT
# excused. The allow-list glob's '*' would otherwise span '/'; the dirname guard
# keeps the allow-list to direct children of the flat config dir. (XACA-0535)
# ─────────────────────────────────────────────────────────────────────────────
@test "xaca-0361: nested path under freelance config dir still fails (dirname guard)" {
  # A direct-child freelance config (allow-listed) ...
  mkdir -p "${FIXTURE_DIR}/share/lcars-ui/team_transfer/config/freelance-X"
  printf 'team: freelance-doublenode-foo\n' \
    > "${FIXTURE_DIR}/share/lcars-ui/team_transfer/config/freelance-doublenode-foo.yaml"
  # ... and a NESTED doublenode file the bare glob would wrongly excuse
  touch "${FIXTURE_DIR}/share/lcars-ui/team_transfer/config/freelance-X/evil-doublenode.yaml"
  git -C "${FIXTURE_DIR}" add \
    share/lcars-ui/team_transfer/config/freelance-doublenode-foo.yaml \
    share/lcars-ui/team_transfer/config/freelance-X/evil-doublenode.yaml
  git -C "${FIXTURE_DIR}" commit -q -m "add direct + nested config"

  run bash "${FIXTURE_DIR}/scripts/check-tap-hygiene.sh"
  [ "$status" -eq 1 ]
  # The nested file is flagged ...
  [[ "$output" =~ "freelance-X/evil-doublenode.yaml" ]]
  # ... but the direct-child config is still excused
  [[ ! "$output" =~ "freelance-doublenode-foo.yaml" ]]
}
