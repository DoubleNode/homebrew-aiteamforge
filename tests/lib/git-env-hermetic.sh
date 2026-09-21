#!/bin/bash
# tests/lib/git-env-hermetic.sh — drop INHERITED repository-local git env vars
# so no test fixture can reach a real repository through them.
#
# Background: git honours GIT_DIR / GIT_WORK_TREE / GIT_INDEX_FILE (and the rest
# of `git rev-parse --local-env-vars`) over the current directory. A fixture
# that does
#     ( cd "$FIXTURE"; git init -q; git config user.name "X"; git add -A; git commit ... )
# therefore re-inits, reconfigures and COMMITS INTO whatever repo GIT_DIR names
# whenever the caller exported one — and the fixture never gets a .git at all.
#
# Measured incident (2026-09-08): a tester ran suites extracted to /tmp with
# GIT_DIR/GIT_WORK_TREE exported at the dev machine's main tap checkout, "so
# they had a repo". test-xaca-0761's Case 3 wrote `Sandbox <test@example.com>`
# into that checkout's local config, and 18 tap commits (17 pushed to public
# main) were authored under it before anyone noticed. It only failed to also
# commit the tap's working tree because that tree happened to be clean. Git
# hooks export GIT_DIR too, so any suite run from a hook is exposed the same way.
#
# Scope: this removes the REPOSITORY-LOCAL variables only. It does not touch
# HOME or GIT_CONFIG_GLOBAL (suites sandbox those themselves) and it does not
# stop a suite that deliberately sets GIT_DIR for its own fixture afterwards.
#
# Sourced at the top of tests/test-runner.sh (every suite it launches inherits
# the scrubbed environment) AND at the top of each suite that builds fixture
# repos with bare `git init`/`git config`, so a standalone `bash tests/<suite>`
# is covered too. Guarded by tests/test-git-env-hermetic.sh.

git_env_hermetic() {
    local _v
    # git's own authoritative list, plus a fixed fallback in case git cannot
    # run here (unset of an already-unset name is a harmless no-op).
    for _v in $(git rev-parse --local-env-vars 2>/dev/null) \
              GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR \
              GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
              GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT \
              GIT_IMPLICIT_WORK_TREE GIT_GRAFT_FILE GIT_NO_REPLACE_OBJECTS \
              GIT_REPLACE_REF_BASE GIT_PREFIX GIT_SHALLOW_FILE; do
        unset "$_v" 2>/dev/null || true
    done
}

git_env_hermetic
