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
#   Zero or more lines:  "<team>\t<project_dir>\t<mode>"  (project_dir
#                        canonicalized; mode is "git" or "flat" — see
#                        XACA-1305 below)
#   Exactly one final line: "#UNINSPECTABLE\t<N>"
#
# XACA-1305 — FLAT (NON-GIT) TARGETS: a project dir that is not a git work
# tree at all can still be a legitimate deploy target (e.g. ~/finance/personal
# on a box where that project was never `git init`-ed). Admitting it purely
# because it "looks like a project" would widen discovery into arbitrary
# directories, so admission is SENTINEL-gated, never inferred from directory
# shape (memory: sentinel files over structural inference): a non-git
# candidate is admitted only when <dir>/.claude/agents/.synced-from-tap
# exists, is a regular file (not a symlink), and its `team:`/`source_path:`
# fields name THIS team's canonical source
# (`<framework_dir>/<team>/personas/agents`). The marker is written only by
# deploy-worktree-personas.sh's own `--flat-dir`/`--nested-main-root` modes,
# so its presence with a matching source is proof a prior deploy put personas
# there — see _pt_flat_target_ok() below for the exact rule. Both old-format
# (no `mode:`/`deployed_file:` lines) and new-format markers are accepted;
# only `team:` and `source_path:` are read. A git-root candidate is emitted
# with mode "git" exactly as before this ticket; a sentinel-admitted non-git
# candidate is emitted with mode "flat". Consumers must route on this column,
# never re-derive git-ness themselves (k501 sibling-heuristic drift) — the
# upgrade path calls `--nested-main-root` for "git" and `--flat-dir` for
# "flat"; the parity checker compares "git" targets directly and verifies
# "flat" targets via `--verify-flat-dir`.
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
# _pt_flat_target_ok <team> <canon_d>
#
# XACA-1305: the sentinel-admission rule for a NON-GIT project dir (see the
# file header's "FLAT (NON-GIT) TARGETS" section). Called only when
# `git -C <canon_d> rev-parse --show-toplevel` has ALREADY failed for
# <canon_d> in the caller's loop — this function does its OWN, stricter
# git-territory check rather than trusting that, because the caller's check
# used unscrubbed environment. Returns 0 (admit) or 1 (reject); never
# crashes, never admits on doubt (fail closed).
#
# GIT-TERRITORY CHECK, MIRRORED FROM deploy-worktree-personas.sh's
# _dwp_flat_target_guard step 3 (its own header explains why BOTH signals run
# and neither is skippable): rev-parse with GIT_* scrubbed (a leaked GIT_DIR
# makes plain rev-parse lie), AND a structural walk to / looking for a `.git`
# entry (covers git missing, "dubious ownership", or a bare `.git` dir git
# itself won't recognise). This is deliberately AT LEAST as strict as the
# enumerator's own git-root test above it — it must be, or the enumerator and
# the deployer's own --flat-dir refusal (rc 4) could disagree about the same
# directory (k501 sibling-heuristic drift). Do not weaken this to match the
# caller's simpler check; mirror the deployer's, exactly.
#
# SENTINEL CHECKS: <canon_d>/.claude/agents must be a real directory (not a
# symlink); its .synced-from-tap marker must be a regular file (not a
# symlink); the marker's `team:` must equal <team>; the marker's
# `source_path:`, canonicalized, must equal this team's canonical S2 source
# dir, canonicalized — and that source dir must actually exist (a marker
# naming a since-deleted source is rejected, not admitted on faith).
#
# WHY THE COMPARISON TARGET IS `${AITEAMFORGE_DIR:-$HOME/aiteamforge}/<team>/
# personas/agents`, NOT `<framework_dir>/<team>/personas/agents` (the Cellar/
# S1 dir pt_enumerate_targets's own <framework_dir> parameter names): the
# marker's `source_path:` is written by deploy-worktree-personas.sh's
# `_write_marker` as its caller's `primary_src`, which BOTH `--flat-dir` and
# `--nested-main-root` derive as `${AITEAMFORGE_DIR:-$HOME/aiteamforge}/
# <team>/personas/agents` (the working-dir S2 source) — never the Cellar.
# The field evidence this ticket was filed from confirms it byte-for-byte
# (source_path: /Users/…/aiteamforge/finance/personas/agents, aiteamforge_dir:
# /Users/…/aiteamforge). Comparing against the Cellar path instead would
# reject every real marker on the fleet, including the one this ticket exists
# to admit — so this function reads AITEAMFORGE_DIR directly, matching
# `_deploy_flat_dir_impl`'s own default EXACTLY, rather than re-deriving a
# second, diverging definition of "this team's source" from the framework_dir
# parameter (k501 sibling-heuristic drift).
#
# Marker parsing tolerates CRLF line endings and trailing whitespace on every
# line, and both the old marker format (synced_at/team/source_path/
# aiteamforge_dir only) and the new one (adds mode:/deployed_file: lines) —
# only `team:` and `source_path:` are ever read, so both formats satisfy this
# test identically. A `.synced-from-master` marker (kb-sync-personas' own,
# unrelated format) is invisible to this test by construction: we look for
# `.synced-from-tap` specifically, never the other filename.
# ---------------------------------------------------------------------------
_pt_flat_target_ok() {
  local team="$1"
  local canon_d="$2"

  # --- Git-territory refusal (stricter, mirrors the deployer's guard) ---
  if command -v git >/dev/null 2>&1; then
    local rp_out=""
    rp_out=$(unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_CEILING_DIRECTORIES
             git -C "$canon_d" rev-parse --is-inside-work-tree 2>/dev/null) || rp_out=""
    [ "$rp_out" = "true" ] && return 1
  fi
  local walk="$canon_d"
  while :; do
    if [ ! -x "$walk" ]; then
      return 1   # cannot search an ancestor -> cannot rule out .git -> fail closed
    fi
    if [ -e "${walk}/.git" ] || [ -L "${walk}/.git" ]; then
      return 1
    fi
    [ "$walk" = "/" ] && break
    walk=$(dirname "$walk")
  done

  # --- Sentinel: .claude/agents must be a real dir, not a symlink ---
  local agents_dir="${canon_d}/.claude/agents"
  [ -L "$agents_dir" ] && return 1
  [ -d "$agents_dir" ] || return 1
  [ -L "${canon_d}/.claude" ] && return 1

  # --- Sentinel: .synced-from-tap must be a regular file, not a symlink ---
  local marker="${agents_dir}/.synced-from-tap"
  [ -L "$marker" ] && return 1
  [ -f "$marker" ] || return 1

  # --- Parse team:/source_path: only, tolerating CRLF + trailing whitespace ---
  local marker_team="" marker_source="" line
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"                                # tolerate CRLF
    line="${line%"${line##*[![:space:]]}"}"             # trim trailing whitespace
    case "$line" in
      'team: '*)        marker_team="${line#team: }" ;;
      'source_path: '*) marker_source="${line#source_path: }" ;;
    esac
  done < "$marker"

  [ -n "$marker_team" ] && [ "$marker_team" = "$team" ] || return 1
  [ -n "$marker_source" ] || return 1

  # --- source_path: must (canonically) name THIS team's S2 source dir, and
  #     that source dir must actually exist -- reject, don't crash, on a
  #     marker naming a source that is no longer there. Matches
  #     _deploy_flat_dir_impl's own primary_src default EXACTLY (see the
  #     header comment above for why this is AITEAMFORGE_DIR, not
  #     framework_dir). ---
  local expected_source="${AITEAMFORGE_DIR:-${HOME:-}/aiteamforge}/${team}/personas/agents"
  [ -d "$expected_source" ] || return 1
  local canon_source="" canon_expected=""
  canon_source="$(_pt_canon_path "$marker_source")" || return 1
  canon_expected="$(_pt_canon_path "$expected_source")" || return 1
  [ "$canon_source" = "$canon_expected" ] || return 1

  return 0
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

    local d bname agents_dir canon_d top canon_top mode
    for d in "$working_dir"/*/; do
      [ -d "$d" ] || continue
      d="${d%/}"
      bname="$(basename "$d")"
      case "$bname" in
        .*) continue ;;   # dotfiles excluded (belt-and-suspenders — the glob above already excludes them)
      esac

      canon_d="$(_pt_canon_path "$d")" || continue

      # GIT-ROOT resolution — the load-bearing filter (see header comment).
      # UNCHANGED for a real git root (mode "git"). When rev-parse fails
      # outright (not a git work tree at all), XACA-1305 gives the candidate
      # a second chance via the sentinel-gated flat-target admission below —
      # a dir INSIDE a work tree but not its root, or a linked worktree,
      # still falls straight through to `continue` exactly as before this
      # ticket, and never reaches the flat check (git territory stays git
      # territory).
      mode=""
      top="$(git -C "$canon_d" rev-parse --show-toplevel 2>/dev/null)" || top=""
      if [ -n "$top" ]; then
        canon_top="$(_pt_canon_path "$top")" || continue
        [ "$canon_d" = "$canon_top" ] || continue        # inside a repo but not its root
        [ -f "${canon_d}/.git" ] && continue              # linked worktree (.git FILE, not dir) — wrong mode
        mode="git"
      else
        if _pt_flat_target_ok "$team" "$canon_d"; then
          mode="flat"
        else
          continue   # not a git repo AND not a sentinel-admitted flat target -> not a project
        fi
      fi

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

      printf '%s\t%s\t%s\n' "$team" "$canon_d" "$mode"
    done
  done

  printf '#UNINSPECTABLE\t%d\n' "$uninspectable"
  return 0
}
