#!/usr/bin/env bash
# kb-gh-credential-guard.sh
#
# SessionStart hook (XACA-1073-006) — surfaces a gh token stored in PLAINTEXT
# (hosts.yml `oauth_token:`), a GH_TOKEN/GITHUB_TOKEN in the environment, or a
# github.com entry in ~/.git-credentials. gh falls back to plaintext silently
# when the macOS keychain is unusable (-25308); on a FileVault-off machine that
# left a broad-scope gho_ token on an unencrypted disk with nobody the wiser.
#
# Thin wrapper — ALL detection logic lives in scripts/kb-gh-credential-check.sh
# (independently callable; exit 0 OK/N-A, 1 confirmed finding, 2 UNKNOWN). Same
# shape and house rules as kb-knowledge-sync-guard.sh:
#   * Runs the check on every session start; makes NO network call (never
#     passes --scopes).
#   * rc=1 -> full banner; rc=2 -> a shorter UNKNOWN banner (fail closed:
#     "could not check" is shown, not swallowed); rc=0 -> silent.
#   * NEVER blocks the session: warning-only, ALWAYS exits 0.
#   * NEVER auto-remediates. The check output never contains a token value.
#
# $KB_GH_CREDENTIAL_GUARD_CHECK_SCRIPT lets a test point this wrapper at a stub.
# Unset in any real session.
# XACA-1753: shared root resolver (sibling of this hook in every layout).
_AITF_SELF="${BASH_SOURCE[0]:-$0}"
_AITF_SELF="$(readlink -f "$_AITF_SELF" 2>/dev/null || printf '%s' "$_AITF_SELF")"
_AITF_LIB="$(dirname "$_AITF_SELF")/aitf-root.sh"
if [ -f "$_AITF_LIB" ]; then
    . "$_AITF_LIB"
else
    echo "kb-gh-credential-guard: could not check: aitf-root.sh not found (looked in $_AITF_LIB)"
    exit 0
fi
aitf_init "$_AITF_SELF"
CHECK_SCRIPT="${KB_GH_CREDENTIAL_GUARD_CHECK_SCRIPT:-}"
[ -n "$CHECK_SCRIPT" ] || { aitf_locate scripts/kb-gh-credential-check.sh; CHECK_SCRIPT="$AITF_FOUND"; }

# The check script ships in the same repo as this wrapper, so its absence (or
# a non-regular file) means this install is broken, not "not pulled yet". A
# silent exit here would be a fail-open: report UNKNOWN instead (still rc 0).
if [ ! -f "$CHECK_SCRIPT" ]; then
    OUTPUT="  could not check: kb-gh-credential-check.sh not found (looked in ${CHECK_SCRIPT:-$AITF_LOOKED}); the check did not run."
    RC=2
else
    OUTPUT="$(bash "$CHECK_SCRIPT" 2>&1)"
    RC=$?
fi

if [ "$RC" -eq 0 ]; then
    exit 0
fi

if [ "$RC" -eq 1 ]; then
    HEADLINE="WARNING: GITHUB CREDENTIAL STORED IN THE CLEAR ON THIS MACHINE"
else
    HEADLINE="WARNING: GITHUB CREDENTIAL CHECK COULD NOT CONFIRM THIS MACHINE IS CLEAN"
fi

cat <<WARNING

================================================================================
  ${HEADLINE}
================================================================================

  scripts/kb-gh-credential-check.sh reported (token values are never printed):

${OUTPUT}

  WHAT THIS MEANS: gh (or git) is holding a GitHub credential somewhere other
  than a keychain. gh does this SILENTLY when the macOS keychain is unusable
  (e.g. -25308 errSecInteractionNotAllowed). A gho_/ghp_ token is broad-scope
  (repo, workflow, ...): anyone with read access to the disk can use it. On a
  machine without FileVault that is anyone with the disk.

  DO NOT SELF-REMEDIATE. Do not delete hosts.yml, run 'gh auth logout', or
  rewrite any config on your own. Do not paste the file's contents anywhere.
  STOP and tell the user; they decide whether to rotate the token, move it
  into a keychain that works, and/or enable disk encryption.

  Re-run by hand:  scripts/kb-gh-credential-check.sh [--json]
  Reference:       XACA-1073 (plaintext gh token on an unencrypted host)

================================================================================

WARNING

exit 0
