#!/bin/bash
# managed-policy-status.sh
#
# XACA-1624-003/004: the ONE implementation of "is the Claude Code L1 managed policy installed
# and current on this machine?", sourced by BOTH doctors (bin/aiteamforge-doctor.sh and
# libexec/commands/aiteamforge-doctor.sh) and by `aiteamforge upgrade`, so they cannot drift
# (k501 sibling-heuristic drift). TAP-NATIVE: no dev-team canonical, edit in the submodule.
#
# The policy is a ROOT-OWNED file under /Library/Application Support/ClaudeCode. Nothing here
# ever installs it, runs sudo, or prompts: this only READS status through
#     python3 "${AITEAMFORGE_DIR}/scripts/kb-sync-plugins" managed-policy --status
# and turns it into a verdict plus the exact command a human must run in a local terminal.
#
# CONTRACT with `kb-sync-plugins managed-policy --status` (parsed strictly, fail closed):
#   rc 0 + line 1 `POLICY_STATUS=OK path=<p>`                       -> OK
#   rc 1 + line 1 `POLICY_STATUS=POLICY_ABSENT|POLICY_STALE path=<p>` -> ACTION (install it)
#   anything else -> UNKNOWN ("cannot determine"): tool missing, rc 2 (a shipped tool that
#   predates --status), rc 3, any other rc, no well-formed POLICY_STATUS line on line 1, or an
#   rc/status mismatch (rc 0 with ABSENT, rc 1 with OK). UNKNOWN is NEVER a pass: a malformed
#   check must not return the reassuring result.
#
# SKIP guards mirror invoke_managed_policy_offer() in libexec/installers/install-claude-config.sh
# exactly (that function is deliberately left as is, its messages are asserted by tests):
#   * dev machine: ${HOME}/dev-team/.claude/agents-master exists (policy ships via
#     deploy-to-production.sh there);
#   * staged/sandbox: the effective CLAUDE_CONFIG_DIR is not ${HOME}/.claude. Effective dir uses
#     the installer's own precedence: explicit CLAUDE_CONFIG_DIR, else
#     ${AITEAMFORGE_DIR}/.claude-staging under CLAUDE_SANDBOX=1, else ${HOME}/.claude.
#
# USAGE
#   atf_mp_evaluate <aiteamforge_dir>
# Always returns 0 (safe under `set -e`/pipefail) and sets these globals:
#   ATF_MP_VERDICT  SKIP | OK | ACTION | UNKNOWN
#   ATF_MP_SUMMARY  one-line message, no color, no newline
#   ATF_MP_HINT     zero or more lines (newline-separated) of remediation, "" when none
# Callers map the verdict onto their own output style. Bash 3.2 compatible: no associative
# arrays, no ${var,,}, no mapfile, and no command is allowed to fail the caller.

# shellcheck disable=SC2034  # ATF_MP_* are the output contract, read by the sourcing script
ATF_MP_VERDICT=""
ATF_MP_SUMMARY=""
ATF_MP_HINT=""

# atf_mp_skip_reason <aiteamforge_dir>: prints the reason and returns 0 when the check must be
# skipped; prints nothing and returns 1 when it applies.
atf_mp_skip_reason() {
  local dir="${1:-${HOME}/aiteamforge}"
  local cfg
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    cfg="$CLAUDE_CONFIG_DIR"
  elif [ "${CLAUDE_SANDBOX:-0}" = "1" ]; then
    cfg="${dir}/.claude-staging"
  else
    cfg="${HOME}/.claude"
  fi

  if [ -d "${HOME}/dev-team/.claude/agents-master" ]; then
    printf '%s' "dev machine (the managed policy ships via deploy-to-production.sh)"
    return 0
  fi
  if [ "$cfg" != "${HOME}/.claude" ]; then
    printf '%s' "staged/sandbox install (CLAUDE_CONFIG_DIR=${cfg})"
    return 0
  fi
  return 1
}

_atf_mp_evaluate_core() {
  local dir="${1:-${HOME}/aiteamforge}"
  local tool="${dir}/scripts/kb-sync-plugins"
  local install_cmd="python3 ${tool} managed-policy --install"
  local verify_cmd="python3 ${tool} check --host --probe"
  local reason out rc line1 status

  ATF_MP_VERDICT=""
  ATF_MP_SUMMARY=""
  ATF_MP_HINT=""

  if reason="$(atf_mp_skip_reason "$dir")"; then
    ATF_MP_VERDICT="SKIP"
    ATF_MP_SUMMARY="Claude Code managed policy: not checked (${reason})"
    return 0
  fi

  if [ ! -f "$tool" ]; then
    ATF_MP_VERDICT="UNKNOWN"
    ATF_MP_SUMMARY="Claude Code managed policy: cannot determine status (kb-sync-plugins not installed at ${tool})"
    return 0
  fi

  # stdout only: line 1 is the contract. stderr is discarded so a warning can never become line 1.
  out="$(python3 "$tool" managed-policy --status 2>/dev/null)" && rc=0 || rc=$?
  line1="${out%%$'\n'*}"

  # Strict line-1 parse: exactly POLICY_STATUS=<WORD> path=<non-empty>, nothing else.
  status=""
  case "$line1" in
    "POLICY_STATUS=OK path="?*)            status="OK" ;;
    "POLICY_STATUS=POLICY_ABSENT path="?*) status="POLICY_ABSENT" ;;
    "POLICY_STATUS=POLICY_STALE path="?*)  status="POLICY_STALE" ;;
  esac

  if [ -z "$status" ]; then
    ATF_MP_VERDICT="UNKNOWN"
    case "$rc" in
      2) ATF_MP_SUMMARY="Claude Code managed policy: cannot determine status (installed kb-sync-plugins predates managed-policy --status; rc=2)" ;;
      3) ATF_MP_SUMMARY="Claude Code managed policy: cannot determine status (kb-sync-plugins reported rc=3)" ;;
      *) ATF_MP_SUMMARY="Claude Code managed policy: cannot determine status (rc=${rc}, no well-formed POLICY_STATUS line)" ;;
    esac
    return 0
  fi

  case "${status}:${rc}" in
    OK:0)
      ATF_MP_VERDICT="OK"
      ATF_MP_SUMMARY="Claude Code managed policy is installed and current"
      ;;
    POLICY_ABSENT:1|POLICY_STALE:1)
      ATF_MP_VERDICT="ACTION"
      if [ "$status" = "POLICY_ABSENT" ]; then
        ATF_MP_SUMMARY="Claude Code managed policy is NOT installed (POLICY_ABSENT): superpowers, commit-commands and ralph-loop are not blocked here"
      else
        ATF_MP_SUMMARY="Claude Code managed policy is STALE (POLICY_STALE): the installed policy differs from the shipped one"
      fi
      ATF_MP_HINT="Install: ${install_cmd}
Run it from a local terminal (needs sudo).
Verify afterwards: ${verify_cmd}
(local terminal only: over SSH the probe is PROBE_UNVERIFIABLE because the login keychain is locked)"
      ;;
    *)
      ATF_MP_VERDICT="UNKNOWN"
      ATF_MP_SUMMARY="Claude Code managed policy: cannot determine status (rc=${rc} contradicts POLICY_STATUS=${status})"
      ;;
  esac
  return 0
}

atf_mp_evaluate() {
  _atf_mp_evaluate_core "$@"
  if [ "$ATF_MP_VERDICT" = "UNKNOWN" ]; then
    ATF_MP_HINT="Not a pass: the status could not be read. After 'aiteamforge upgrade' delivers a current kb-sync-plugins, re-check with: aiteamforge doctor --check managed-policy"
  fi
  return 0
}
