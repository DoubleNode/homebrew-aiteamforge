#!/bin/bash
# persona-targets.sh
#
# XACA-0931-001/002: SHARED, tap-native enumerator for nested-project persona
# DEPLOY TARGETS — directories under a projects-enabled team's working dir
# that already have a deployed `.claude/agents/` (S3, in the decision
# record's vocabulary: S1 Cellar -> S2 working-dir source -> S3 deployed).
#
# WHY THIS IS A SEPARATE, SHARED FILE (XACA-0931-001 §3.2/§4.3): both the
# upgrade-path FIXER (aiteamforge-upgrade.sh's deploy_team_personas_to_projects,
# XACA-0931-002) and the drift DETECTOR (aiteamforge-persona-parity-check.sh's
# S3 surface, XACA-0931-003) must agree on exactly which directories are
# targets. Two independent implementations of "what counts as a deploy
# target" is the k501 sibling-heuristic-drift pattern this codebase has 24+
# recorded datapoints for, and it would produce the specific catastrophe of
# a checker reporting "clean" because it looked at a smaller target set than
# the fixer wrote to (or vice versa). There is exactly ONE enumerator; both
# consumers source this file and call pt_enumerate_targets.
#
# TAP-NATIVE, NOT MIRRORED (XACA-0931-001 §5): no dev-team canonical, not in
# sync-tap.sh's map. Edit directly in the submodule.
#
# SELF-CONTAINED BY DESIGN: this file does NOT depend on libexec/lib/common.sh's
# print_* family — aiteamforge-upgrade.sh sources common.sh, but
# aiteamforge-persona-parity-check.sh does not (it has its own minimal output
# style). Warnings are emitted via the local _pt_warn helper (stderr, plain
# printf) so this lib behaves identically regardless of which caller sourced
# it.
#
# THE ENUMERATOR'S OUTPUT CONTRACT — read this before changing the emission
# shape:
#   Zero or more lines:  "<team>\t<project_dir>"    (project_dir canonicalized)
#   Exactly one final line: "#UNINSPECTABLE\t<N>"
#
# WHY THE COUNT RIDES ON STDOUT AS A TRAILER LINE, NOT A GLOBAL VARIABLE:
# the natural way to consume a streaming enumerator in bash is
# `while ... read; do ...; done < <(pt_enumerate_targets ...)` — but the
# right-hand side of `<(...)` runs in a SUBSHELL. Any global variable
# pt_enumerate_targets assigned (an uninspectable COUNTER, matching this
# codebase's established _XACA0925_TEAM_UPDATED-style side-channel-return
# convention) would be invisible to the caller the instant that subshell
# exits — the caller's copy of the variable is simply never touched. Every
# caller of this function MUST go through process substitution or a pipe (it
# streams targets one at a time), so that failure mode is not a corner case,
# it is the only way this function is ever actually called. Multiplexing the
# count onto the same stdout stream as a distinguishable trailer line sidesteps
# the subshell boundary entirely, regardless of how the caller invokes this
# function. "#UNINSPECTABLE" can never collide with a real team name — team
# names come from tap-shipped share/teams/*.conf basenames, never from `#`.
#
# EXIT STATUS: pt_enumerate_targets always returns 0. Its failure signal is
# the uninspectable count, not its exit code — a partial enumeration is not
# the same thing as "the function itself failed to run."
#
# See XACA-0931-001 §3.1-3.2 for the full algorithm rationale, including the
# two live negative cases on darren-m4-mini (~/medical/personas — a persona
# STORE, not a project; ~/legal/default — likewise) that motivate git-root
# resolution over a directory-listing glob.

# ---------------------------------------------------------------------------
# _pt_warn <message>
# Plain stderr warning, independent of common.sh's print_warning (see header).
# ---------------------------------------------------------------------------
_pt_warn() {
  printf '[persona-targets] WARN: %s\n' "$*" >&2
}

# ---------------------------------------------------------------------------
# _pt_canon_path <path>
# Canonicalize a path (resolve symlinks; tolerate a nonexistent tail).
#
# Deliberately DUPLICATED from deploy-worktree-personas.sh's _canon_path
# rather than sourced from it: that script is an executable entry point with
# an unconditional `main "$@"` at EOF and is not safe to `source` (it would
# execute immediately). This is a generic filesystem primitive, not business
# logic — the git-root TEST that actually decides "is this a project" (below,
# inlined in pt_enumerate_targets) is the thing that must stay singular, and
# it does; only this small canonicalization utility is duplicated.
# ---------------------------------------------------------------------------
_pt_canon_path() {
  local p="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$p"
    return
  fi
  local suffix="" cur="$p" real base
  while [ -n "$cur" ] && [ "$cur" != "/" ]; do
    if [ -e "$cur" ]; then
      real=$(cd "$cur" 2>/dev/null && pwd -P) || return 1
      if [ -n "$suffix" ]; then
        printf '%s/%s\n' "$real" "$suffix"
      else
        printf '%s\n' "$real"
      fi
      return 0
    fi
    base=$(basename "$cur")
    suffix="${base}${suffix:+/$suffix}"
    cur=$(dirname "$cur")
  done
  return 1
}

# ---------------------------------------------------------------------------
# _pt_team_conf_flags <conf-path>
#
# Read TEAM_HAS_PROJECTS / TEAM_REQUIRES_CLIENT_ID / TEAM_WORKING_DIR from a
# team conf file. Matches the established _connect_script_team_flags()
# pattern (aiteamforge-upgrade.sh:1226) — same subshell isolation + `set +eo
# pipefail` rationale (a malformed conf must never leak variables into the
# caller, nor abort it under the caller's `set -eo`) — extended with
# TEAM_WORKING_DIR, which that existing helper does not need and this one
# does. Per XACA-0931-001 §3.1: "Extend that helper (or add a sibling) to
# also emit TEAM_WORKING_DIR; do not re-implement the subshell read." This IS
# that sibling — same pattern, new lib, because this lib must also be usable
# from aiteamforge-persona-parity-check.sh, which cannot see a function
# defined inside aiteamforge-upgrade.sh.
#
# Emits "HAS|REQUIRES|WORKING_DIR" on stdout.
#
# Distinguishes "conf sourced cleanly but simply doesn't set these vars"
# (legitimate false/false/empty defaults — a normal flat team) from "conf
# FAILED to source" (a genuine fault) by emitting the sentinel "ERROR||" for
# the latter — never the same false|false a well-formed flat-team conf
# produces. XACA-0931-001 §3.7: "A conf that fails to source -> WARN +
# UNINSPECTABLE++ (never a silent false|false skip)."
# ---------------------------------------------------------------------------
_pt_team_conf_flags() {
  local conf="$1"
  (
    set +eo pipefail
    TEAM_HAS_PROJECTS=""
    TEAM_REQUIRES_CLIENT_ID=""
    TEAM_WORKING_DIR=""
    # shellcheck disable=SC1090
    if ! . "$conf" >/dev/null 2>&1; then
      printf 'ERROR||'
      exit 0
    fi
    printf '%s|%s|%s' "${TEAM_HAS_PROJECTS:-false}" "${TEAM_REQUIRES_CLIENT_ID:-false}" "${TEAM_WORKING_DIR:-}"
  )
}

# ---------------------------------------------------------------------------
# pt_enumerate_targets <framework_dir>
#
# Emit every nested-project persona DEPLOY TARGET on this box. See the file
# header for the full output contract (team/dir lines + #UNINSPECTABLE
# trailer).
#
# Predicate for which teams even have nested targets (XACA-0931-001 §3.1):
# TEAM_HAS_PROJECTS="true" AND TEAM_REQUIRES_CLIENT_ID != "true". NOT
# hardcoded to {finance, legal, medical} — freelance is projects-enabled too
# but client-scoped (different topology: project dirs live under
# /Users/Shared/Development/<GROUPID>/<PROJECTID>, not
# $TEAM_WORKING_DIR/<PROJECTID>, and freelance-startup.sh deploys no
# personas at all), so it is explicitly excluded rather than accidentally
# included by a weaker predicate.
#
# REFRESH-ONLY BY CONSTRUCTION: a directory only ever becomes a target when
# <dir>/.claude/agents ALREADY exists (the gate near the bottom of the loop).
# This function can never bring a new team into being — it only rediscovers
# deploy targets a prior deploy already created. That is what licenses
# reading `.teams[]` as a cross-check rather than a gate elsewhere
# (XACA-0931-001 §2.4/§3.3): a deployed persona directory on disk is
# conclusive evidence the box installed that team, independent of what
# .aiteamforge-config says.
#
# GIT-ROOT RESOLUTION, NOT A DIRECTORY LISTING: mirrors
# _deploy_nested_main_root's own guard in deploy-worktree-personas.sh
# (project_dir must canonicalize to `git rev-parse --show-toplevel` for
# itself, and must not be a linked worktree) so enumeration here and the
# deploy-time guard there agree by construction, not by coincidence. Verified
# on darren-m4-mini: ~/medical/personas (not a git repo; a persona STORE) and
# ~/legal/default (not a git repo) are both correctly rejected by this test;
# a `~/<team>/*/` glob would have swept both in as false targets.
# ---------------------------------------------------------------------------
pt_enumerate_targets() {
  local framework_dir="$1"
  local uninspectable=0

  # "git not resolvable" cannot classify ANY candidate as project-or-not —
  # WARN + uninspectable once, globally, rather than letting every candidate
  # silently fall through the (failing) git test as "not a project"
  # (XACA-0931-001 §3.7).
  if ! command -v git >/dev/null 2>&1; then
    _pt_warn "git not found on PATH — cannot resolve git-repo roots, so no persona deploy target can be classified"
    printf '#UNINSPECTABLE\t%d\n' 1
    return 0
  fi

  local teams_dir="${framework_dir}/share/teams"
  if [ ! -d "$teams_dir" ]; then
    _pt_warn "Team conf directory not found: ${teams_dir} — cannot enumerate persona deploy targets"
    printf '#UNINSPECTABLE\t%d\n' 1
    return 0
  fi
  if [ ! -r "$teams_dir" ] || [ ! -x "$teams_dir" ]; then
    _pt_warn "${teams_dir} exists but is not readable/searchable — cannot enumerate persona deploy targets"
    printf '#UNINSPECTABLE\t%d\n' 1
    return 0
  fi

  local -a confs=()
  local conf
  for conf in "$teams_dir"/*.conf; do
    [ -f "$conf" ] || continue
    confs+=("$conf")
  done

  if [ ${#confs[@]} -eq 0 ]; then
    _pt_warn "No *.conf files found under ${teams_dir} — cannot enumerate persona deploy targets"
    printf '#UNINSPECTABLE\t%d\n' 1
    return 0
  fi

  local team flags has_projects requires_client working_dir rest
  for conf in "${confs[@]}"; do
    team="$(basename "$conf" .conf)"
    flags="$(_pt_team_conf_flags "$conf")"
    has_projects="${flags%%|*}"
    rest="${flags#*|}"
    requires_client="${rest%%|*}"
    working_dir="${rest#*|}"

    if [ "$has_projects" = "ERROR" ]; then
      _pt_warn "[${team}] ${conf} failed to source — cannot determine this team's persona deploy targets"
      uninspectable=$((uninspectable + 1))
      continue
    fi

    [ "$has_projects" = "true" ] || continue          # flat team -> no nested targets
    [ "$requires_client" = "true" ] && continue        # client-scoped topology (freelance) -> not this enumerator's shape

    if [ -z "$working_dir" ]; then
      _pt_warn "[${team}] TEAM_WORKING_DIR not set in ${conf} — cannot determine this team's persona deploy targets"
      uninspectable=$((uninspectable + 1))
      continue
    fi

    if [ ! -d "$working_dir" ]; then
      continue   # team not present on this box — clean skip, not uninspectable
    fi
    if [ ! -r "$working_dir" ] || [ ! -x "$working_dir" ]; then
      _pt_warn "[${team}] ${working_dir} exists but is not readable/searchable — cannot enumerate this team's targets"
      uninspectable=$((uninspectable + 1))
      continue
    fi

    local d bname agents_dir canon_d top canon_top
    for d in "$working_dir"/*/; do
      [ -d "$d" ] || continue
      d="${d%/}"
      bname="$(basename "$d")"
      case "$bname" in
        .*) continue ;;   # dotfiles excluded (belt-and-suspenders — the glob above already excludes them)
      esac

      canon_d="$(_pt_canon_path "$d")" || continue

      # GIT-ROOT resolution — the load-bearing filter (see header comment).
      top="$(git -C "$canon_d" rev-parse --show-toplevel 2>/dev/null)" || continue   # not a git repo -> not a project
      canon_top="$(_pt_canon_path "$top")" || continue
      [ "$canon_d" = "$canon_top" ] || continue        # inside a repo but not its root
      [ -f "${canon_d}/.git" ] && continue              # linked worktree (.git FILE, not dir) — wrong mode

      # REFRESH-ONLY gate: only targets that ALREADY have deployed personas.
      agents_dir="${canon_d}/.claude/agents"
      if [ ! -d "$agents_dir" ]; then
        continue
      fi
      if [ ! -r "$agents_dir" ] || [ ! -x "$agents_dir" ]; then
        _pt_warn "[${team}] ${agents_dir} exists but is not readable/searchable — cannot inspect this target"
        uninspectable=$((uninspectable + 1))
        continue
      fi

      printf '%s\t%s\n' "$team" "$canon_d"
    done
  done

  printf '#UNINSPECTABLE\t%d\n' "$uninspectable"
  return 0
}
