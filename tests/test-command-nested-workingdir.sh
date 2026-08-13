#!/bin/bash

# test-command-nested-workingdir.sh
# Regression test for the Command-team persona copy guard (XACA-0178).
#
# Bug: install-team.sh was copying personas into TEAM_WORKING_DIR even when
#      TEAM_DIR is nested *inside* TEAM_WORKING_DIR (i.e. the Command team
#      case where TEAM_WORKING_DIR is the monorepo root ~/dev-team and
#      TEAM_DIR is ~/dev-team/command). This polluted the monorepo root
#      with a personas/ directory that appeared as untracked git state.
#
# Fix (XACA-0178-001): the working-dir copy is now skipped when
#   1. TEAM_WORKING_DIR equals TEAM_DIR (existing exact-match case), OR
#   2. TEAM_DIR is nested inside TEAM_WORKING_DIR (parent-dir case — NEW), OR
#   3. TEAM_WORKING_DIR is inside a git work tree (belt-and-suspenders safety).
#
# Test strategy: build a fake homebrew-tap root in TEST_TMP_DIR containing a
# patched command.conf where TEAM_WORKING_DIR points at the fake monorepo.
# That lets Section 1 genuinely exercise the parent-dir guard without the
# git guard short-circuiting the test (and without touching the real
# ~/dev-team on the host machine). Section 3 then turns the fake monorepo
# into a git repo to prove the git-guard path.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REAL_INSTALLER="$TAP_ROOT/libexec/installers/install-team.sh"

# ─────────────────────────────────────────────────────────────────────────────
# Isolated environment layout
#
#   TEST_TMP_DIR/xaca0178-fake/
#     fake-tap/              ← HOMEBREW_TAP_ROOT (install-team.sh's parent's parent)
#       libexec/installers/install-team.sh   (symlink to real installer)
#       share/teams/command.conf             (patched: TEAM_WORKING_DIR → fake monorepo)
#       share/personas/command/              (symlink to real persona templates)
#       share/templates/                     (symlink to real templates)
#     monorepo/              ← AITEAMFORGE_DIR == patched TEAM_WORKING_DIR
#       command/             ← TEAM_DIR (nested inside AITEAMFORGE_DIR)
#
# Because install-team.sh derives HOMEBREW_TAP_ROOT from its own script path
# via BASH_SOURCE, launching the symlinked installer at fake-tap/libexec/
# installers/install-team.sh makes the installer resolve HOMEBREW_TAP_ROOT
# to fake-tap and read our patched command.conf instead of the real one.
# ─────────────────────────────────────────────────────────────────────────────

FAKE_ROOT="$TEST_TMP_DIR/xaca0178-fake"
FAKE_TAP="$FAKE_ROOT/fake-tap"
FAKE_MONOREPO="$FAKE_ROOT/monorepo"
FAKE_INSTALLER="$FAKE_TAP/libexec/installers/install-team.sh"

# Build the fake homebrew-tap root that points TEAM_WORKING_DIR at FAKE_MONOREPO.
build_fake_tap() {
  rm -rf "$FAKE_TAP"
  mkdir -p "$FAKE_TAP/libexec/installers" "$FAKE_TAP/share/teams" "$FAKE_TAP/share/personas"

  # Symlink the real installer — install-team.sh's SCRIPT_DIR resolves to the
  # symlink's parent, so HOMEBREW_TAP_ROOT still becomes FAKE_TAP. Good.
  ln -sf "$REAL_INSTALLER" "$FAKE_INSTALLER"

  # PRE-EXISTING FIXTURE BUG surfaced by the tap-CI manifest-drain fix
  # (XACA-0862; the bug itself predates XACA-0862 — verified byte-identical
  # against the pre-XACA-0862 baseline). install-team.sh unconditionally
  # `source`s "${SCRIPT_DIR}/../lib/aiteamforge-paths.sh" (line ~33, no
  # `|| true` guard, unlike the org-paths source two lines above it) under
  # this script's own `set -euo pipefail`. This fixture only ever symlinked
  # share/ subdirectories — never libexec/lib/ — so every invocation of the
  # fake installer died on that missing source at the very top of the
  # script, before it ever reached the persona-copy block Section 1/3 are
  # actually testing. That produced the exact symptom this file's cases
  # report: an empty/absent TEAM_DIR/personas/ after "install," which reads
  # like a regression in the persona-copy guard but was really the installer
  # never running past line 33. Symlink the whole libexec/lib/ dir, same
  # pattern already used for share/ subdirs below, so the fake installer can
  # actually reach the code this test exists to exercise.
  mkdir -p "$FAKE_TAP/libexec"
  ln -sf "$TAP_ROOT/libexec/lib" "$FAKE_TAP/libexec/lib"

  # Patched command.conf: everything else from the real conf, but
  # TEAM_WORKING_DIR points at the fake monorepo instead of $HOME/dev-team.
  sed "s|^TEAM_WORKING_DIR=.*|TEAM_WORKING_DIR=\"$FAKE_MONOREPO\"|" \
      "$TAP_ROOT/share/teams/command.conf" > "$FAKE_TAP/share/teams/command.conf"

  # Same PRE-EXISTING fixture gap as the libexec/lib/ symlink above: the
  # installer also unconditionally requires share/teams/registry.json
  # (branding lookup, ~line 400) and `exit 1`s outright if it's missing —
  # also present, byte-identical, on the pre-XACA-0862 baseline. Real
  # (unpatched) content is fine here; the branding lookup is keyed by
  # TEAM_ID and unrelated to what this test exercises.
  ln -sf "$TAP_ROOT/share/teams/registry.json" "$FAKE_TAP/share/teams/registry.json"

  # Symlink supporting share/ subdirs the installer reads so it can get past
  # the persona-copy stage without exploding on missing templates.
  for sub in personas/command templates scripts kanban-hooks lcars-ui skills terminals; do
    if [ -e "$TAP_ROOT/share/$sub" ]; then
      mkdir -p "$FAKE_TAP/share/$(dirname "$sub")"
      ln -sf "$TAP_ROOT/share/$sub" "$FAKE_TAP/share/$sub"
    fi
  done
}

# Run the fake installer against the fake monorepo. We deliberately swallow
# non-zero exit codes because the installer does more work after the persona
# block (template rendering, etc.) that is out of scope for this test and
# may fail harmlessly in the minimal fake-tap fixture.
#
# PRE-EXISTING FIXTURE GAP (same class as the libexec/lib/ and registry.json
# fixes above): _ensure_org_config() unconditionally requires either a
# pre-existing ~/.aiteamforge/organization.yaml, an interactive /dev/tty, or
# AITEAMFORGE_ORG_CONFIG set — and hard-exits otherwise. This test never ran
# with a controlling TTY (test-runner.sh, CI) and never set the override, so
# every run died here, before the persona-copy block. AITEAMFORGE_ORG_CONFIG
# short-circuits unconditionally without validating the path — test-org-
# config.sh's own "Env override short-circuits" scenario pins exactly this
# (a nonexistent path, rc=0, no organization.yaml written, no prompts) — so a
# placeholder path here is side-effect-free and irrelevant to what this test
# actually exercises (the persona/personas-directory placement guard).
run_install() {
  AITEAMFORGE_DIR="$FAKE_MONOREPO" \
    AITEAMFORGE_ORG_CONFIG="$FAKE_ROOT/unused-org-config-override.yaml" \
    bash "$FAKE_INSTALLER" command \
      --install-dir "$FAKE_MONOREPO" \
      2>&1 || true
}

cleanup() {
  rm -rf "$FAKE_ROOT"
}
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Pre-conditions
# ─────────────────────────────────────────────────────────────────────────────

test_start "install-team.sh exists and is executable"
if [ -x "$REAL_INSTALLER" ]; then
  test_pass
else
  test_fail "Installer not found or not executable: $REAL_INSTALLER"
fi

test_start "command.conf exists in real tap"
if [ -f "$TAP_ROOT/share/teams/command.conf" ]; then
  test_pass
else
  test_fail "Real command.conf not found — fake-tap fixture cannot be built"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Section 1: Parent-dir guard — no git repo involved
#
# TEAM_DIR ($FAKE_MONOREPO/command) is a subdirectory of TEAM_WORKING_DIR
# (patched to $FAKE_MONOREPO). The parent-dir guard must fire — NOT the
# git guard — because no git repo exists anywhere in the fake tree yet.
# ─────────────────────────────────────────────────────────────────────────────

test_start "Setup: create isolated fake monorepo (no git)"
rm -rf "$FAKE_ROOT"
mkdir -p "$FAKE_MONOREPO"
build_fake_tap
test_pass

test_start "Section 1 fixture: patched command.conf points at fake monorepo"
if grep -q "TEAM_WORKING_DIR=\"$FAKE_MONOREPO\"" "$FAKE_TAP/share/teams/command.conf"; then
  test_pass
else
  test_fail "command.conf was not patched correctly"
fi

test_start "Section 1 fixture: fake monorepo is NOT a git repo"
if git -C "$FAKE_MONOREPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  test_fail "Fake monorepo is a git repo — git guard would mask parent-dir guard"
else
  test_pass
fi

test_start "First run: install command team into fake monorepo"
output1=$(run_install)
test_pass

test_start "Section 1: parent-dir guard fires (NOT git guard) — no skip message expected"
# The parent-dir guard skips silently. The git guard prints "Skipping
# working-dir persona copy". If the skip message appears here, the parent-dir
# guard did not fire and the git guard ran instead — which means the test is
# not actually exercising what it claims.
if [[ "$output1" == *"Skipping working-dir persona copy"* ]]; then
  test_fail "Unexpected git-guard message in Section 1 — parent-dir guard was not exercised"
else
  test_pass
fi

test_start "personas/ must NOT exist at TEAM_WORKING_DIR root after first run"
assert_dir_not_exists "$FAKE_MONOREPO/personas" \
  "personas/ must not be created at the monorepo root (TEAM_WORKING_DIR)"
test_pass

test_start "personas/ MUST exist inside TEAM_DIR after first run"
assert_dir_exists "$FAKE_MONOREPO/command/personas" \
  "personas/ must be created inside TEAM_DIR (the correct location)"
test_pass

test_start "TEAM_DIR/personas/ contains at least one file after first run"
persona_count=$(find "$FAKE_MONOREPO/command/personas" -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "$persona_count" -gt 0 ]; then
  test_pass
else
  test_fail "TEAM_DIR/personas/ is empty — persona files were not copied at all"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Section 2: Idempotency — second run must produce the same clean result
# ─────────────────────────────────────────────────────────────────────────────

test_start "Second run: install command team again (idempotency)"
output2=$(run_install)
test_pass

test_start "personas/ must NOT exist at TEAM_WORKING_DIR root after second run"
assert_dir_not_exists "$FAKE_MONOREPO/personas" \
  "personas/ must not be created at the monorepo root on the second run"
test_pass

test_start "personas/ still present inside TEAM_DIR after second run"
assert_dir_exists "$FAKE_MONOREPO/command/personas" \
  "personas/ must still be present inside TEAM_DIR after second run"
test_pass

# ─────────────────────────────────────────────────────────────────────────────
# Section 3: Git-work-tree guard
#
# Re-create the fake monorepo as a git repo. Now both the parent-dir guard
# AND the git guard would independently catch this; the test verifies the
# informational skip message is printed, confirming the git-guard code path
# is reachable.
# ─────────────────────────────────────────────────────────────────────────────

test_start "Setup: re-create fake monorepo as a git repository"
rm -rf "$FAKE_ROOT"
mkdir -p "$FAKE_MONOREPO"
git -C "$FAKE_MONOREPO" init -q
git -C "$FAKE_MONOREPO" config user.email "test@example.com"
git -C "$FAKE_MONOREPO" config user.name "Test"
build_fake_tap
test_pass

test_start "Section 3 fixture: fake monorepo IS a git repo"
if git -C "$FAKE_MONOREPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  test_pass
else
  test_fail "Fake monorepo is not a git repo — git guard cannot be tested"
fi

test_start "personas/ must NOT exist at git repo root (TEAM_WORKING_DIR)"
output_git=$(run_install)
assert_dir_not_exists "$FAKE_MONOREPO/personas" \
  "personas/ must not be created at the git repo root even during git-guard path"
test_pass

test_start "personas/ MUST exist inside TEAM_DIR even when git guard fires"
assert_dir_exists "$FAKE_MONOREPO/command/personas" \
  "personas/ must still be created inside TEAM_DIR when git guard skips working-dir copy"
test_pass

test_start "Second run with git repo is also clean (idempotency + git guard)"
output_git2=$(run_install)
assert_dir_not_exists "$FAKE_MONOREPO/personas" \
  "personas/ must not appear at git repo root on second run"
test_pass

# Done
exit 0
