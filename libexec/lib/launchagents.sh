#!/bin/bash
# launchagents.sh
# Shared LaunchAgent vocabulary for aiteamforge lifecycle commands (XACA-0734).
#
# WHY THIS FILE EXISTS
# ────────────────────
# LaunchAgent render logic used to be duplicated across three places:
#   1. libexec/commands/aiteamforge-upgrade.sh  (_render_launchagent_template)
#   2. libexec/commands/aiteamforge-migrate.sh  (_render_kanban_template)
#   3. libexec/installers/install-kanban.sh     (inline `sed` per installer)
# The XACA-0571-014 SIBLING-DRIFT NOTE in upgrade.sh warned that adding a
# placeholder to a template required updating every renderer or upgraded plists
# would ship with unresolved {{...}} tokens. XACA-0734 needed the same logic in a
# FOURTH place (`aiteamforge doctor --fix`), so rather than add another copy the
# renderer and the plist→template map now live here and are sourced by upgrade.sh
# and doctor.sh. Add a new {{PLACEHOLDER}} in ONE place: the sed chain below.
#
# THE OPT-OUT SENTINEL (the core of XACA-0734)
# ────────────────────────────────────────────
# `aiteamforge upgrade` used to skip any LaunchAgent whose plist was absent from
# ~/Library/LaunchAgents, on the theory that "absent == the user opted out at
# install time". That inference is WRONG, and it fails in the one direction that
# matters: it cannot distinguish
#     (a) "the user deliberately removed this agent"          — respect it
# from
#     (b) "this plist did not exist when this box was installed" — install it
# so every NET-NEW mandatory LaunchAgent was permanently unreachable on every
# already-installed box. Field-confirmed on M1Pro: it had no
# com.aiteamforge.auto-upgrade.plist, and auto-upgrade is the agent that PERFORMS
# upgrades — so the box could never auto-upgrade, and therefore could never
# receive the fix that would have installed the auto-upgrade plist. A self-sealing
# failure; it only got recent fixes because a human upgraded it by hand.
#
# The fix: intent is RECORDED, never INFERRED from disk state. A plist's absence
# means nothing on its own. An agent is only suppressed when its basename appears
# in the opt-out sentinel — a file the user's own uninstall action wrote.
#
# This is the THIRD instance of this bug class in this codebase; it mirrors
# _xaca0673_mandatory_materialize_basenames (shared Python modules) and
# _xaca0771_mandatory_alias_basenames / _xaca0771_mandatory_hook_basenames
# (alias files / claude hooks) in aiteamforge-upgrade.sh.
#
# DEPENDENCIES: lib/common.sh (print_* helpers, _aitf_launchctl) and, optionally,
# lib/constants.sh (KANBAN_BACKUP_INTERVAL_DEFAULT) / lib/config.sh
# (get_working_dir). All are consumed defensively so this file is safe to source
# from a test harness that only stubs the print_* helpers.

# Guard against double-sourcing (readonly errors in subshells)
if [[ -n "${_LAUNCHAGENTS_SH_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
_LAUNCHAGENTS_SH_LOADED=1

#──────────────────────────────────────────────────────────────────────────────
# Agent → template map
#──────────────────────────────────────────────────────────────────────────────
# Newline-delimited "plist-basename:template-subpath" pairs. Subpaths resolve
# against ${FRAMEWORK_DIR}/share/templates/. This is the single source of truth
# for "which LaunchAgents does the upgrade path manage, and where does each one's
# template live" — upgrade.sh iterates it, doctor.sh looks up individual entries.
#
# com.aiteamforge.lcars-runatload is intentionally ABSENT: it was retired by
# XACA-0763-005. Legacy installs are torn down by remove_legacy_lcars_runatload_agent
# (lib/common.sh); it must never be re-rendered here.
_xaca0734_launchagent_map() {
  cat <<'EOF'
com.aiteamforge.kanban-backup.plist:kanban/backup-plist.template
com.aiteamforge.lcars-health.plist:kanban/lcars-health-plist.template
com.aiteamforge.auto-upgrade.plist:auto-upgrade/auto-upgrade-launchagent.template.plist
com.aiteamforge.lcars-watch.plist:auto-upgrade/lcars-watch-launchagent.template.plist
com.aiteamforge.cellar-watch.plist:auto-upgrade/cellar-watch-launchagent.template.plist
EOF
}

# Resolve the template subpath for a plist basename.
# Usage: _xaca0734_launchagent_template_for <plist-basename>
# Echoes the subpath, or nothing (and returns 1) when the agent is unknown.
_xaca0734_launchagent_template_for() {
  local agent="$1"
  local line
  while IFS= read -r line; do
    case "$line" in
      "${agent}:"*) printf '%s\n' "${line#*:}"; return 0 ;;
    esac
  done <<EOF
$(_xaca0734_launchagent_map)
EOF
  return 1
}

#──────────────────────────────────────────────────────────────────────────────
# Mandatory set
#──────────────────────────────────────────────────────────────────────────────
# LaunchAgents whose ABSENCE BREAKS CORE FUNCTION, and which upgrade must
# therefore materialize even when the plist is not on disk (unless the user has
# recorded an explicit opt-out — see the sentinel helpers below).
#
# Keep this set MINIMAL. An agent belongs here only if a box without it is
# meaningfully broken, not merely less convenient. Newline-delimited basenames;
# exact-line membership test.
#
#   com.aiteamforge.auto-upgrade.plist
#       HIGHEST PRIORITY. This is the agent that performs upgrades. Without it a
#       box is permanently stranded on whatever version it happens to have and can
#       never self-heal — including from this very bug. This is the agent M1Pro was
#       missing (XACA-0734-001).
#   com.aiteamforge.lcars-health.plist
#       Keepalive/health for the LCARS server. Without it a crashed cockpit stays
#       down until a human notices.
#   com.aiteamforge.kanban-backup.plist
#       Periodic kanban board backups. Without it board data has no recovery point.
#
# DELIBERATE EXCLUSIONS — do not re-litigate these without a reason:
#   com.aiteamforge.lcars-watch.plist / com.aiteamforge.cellar-watch.plist
#       Auto-upgrade ACCELERATORS, not core function. They make an upgrade land
#       sooner (restart LCARS on file change / notice a new Cellar); a box without
#       them still upgrades correctly on the auto-upgrade agent's daily schedule.
#       Materializing them would silently add filesystem watchers to boxes that
#       never had them, which is a behavior change with no correctness payoff.
#   com.aiteamforge.cr-confluence-poller.plist
#       Config-gated and DISABLED BY DEFAULT — _cr_reconcile_disabled_plists
#       (install-kanban.sh) already implements a real, first-class opt-out concept
#       for it. It is not in the upgrade map at all, and force-materializing a
#       poller that most boxes intentionally do not run would be actively wrong.
_xaca0734_mandatory_launchagent_basenames() {
  cat <<'EOF'
com.aiteamforge.auto-upgrade.plist
com.aiteamforge.lcars-health.plist
com.aiteamforge.kanban-backup.plist
EOF
}

# True (exit 0) when <plist-basename> is in the mandatory set.
_xaca0734_is_mandatory() {
  local agent="$1"
  case $'\n'"$(_xaca0734_mandatory_launchagent_basenames)"$'\n' in
    *$'\n'"${agent}"$'\n'*) return 0 ;;
  esac
  return 1
}

#──────────────────────────────────────────────────────────────────────────────
# Opt-out sentinel — a SUPPORTED, USER-EDITABLE FILE. This is the user-facing
# contract this ticket introduces; treat changing its format as a breaking change.
#──────────────────────────────────────────────────────────────────────────────
#
#   Location: ${HOME}/.aiteamforge/launchagents.optout
#             (override for tests via AITF_LAUNCHAGENT_OPTOUT_FILE)
#   Format:   one LaunchAgent plist BASENAME per line, e.g.:
#               com.aiteamforge.lcars-health.plist
#               com.aiteamforge.auto-upgrade.plist
#   Effect:   `aiteamforge upgrade` will not (re-)materialize a listed agent,
#             and `aiteamforge doctor --fix` will not render+load it either.
#
# THE SUPPORTED WAY TO DECLINE A MANDATORY AGENT IS TO ADD A LINE TO THIS FILE:
#
#     echo "com.aiteamforge.lcars-health.plist" >> ~/.aiteamforge/launchagents.optout
#
# and the supported way to reverse that is to remove the line (by hand, or
# `grep -v` it back out) and re-run `aiteamforge upgrade` or `aiteamforge doctor
# --fix`. `update_launchagents` (aiteamforge-upgrade.sh) and the `keepalive` fix
# (aiteamforge-doctor.sh) both print this exact command whenever they are about
# to materialize a missing mandatory agent — see _xaca0734_print_optout_hint
# below — so the escape hatch is always visible at the moment it becomes
# relevant, without adding a dedicated CLI subcommand for it.
#
# A MISSING SENTINEL FILE IS NORMAL and means "nothing is opted out" — that is
# the state of every existing box, which is exactly why absence-of-plist could
# never be read as intent (that was the XACA-0734 bug).
#
# LIFECYCLE — READ BEFORE WIRING UP A NEW CALLER (XACA-0734 FOLLOW-UP FINDING):
#   _xaca0734_record_optout / _xaca0734_clear_optout are called by
#   uninstall_<x>_launchagent() / install_<x>_launchagent() (install-kanban.sh)
#   respectively — but do not assume that means the sentinel is auto-managed
#   end-to-end. Two things to know:
#
#   1. The ONLY caller of the targeted uninstall_<x>_launchagent() helpers today
#      is the batch uninstall_kanban_system(), which immediately wipes the
#      ENTIRE sentinel afterward (see its own header comment) — so a targeted
#      record() is never externally observable through the current call graph.
#      It is kept correct for a hypothetical future targeted single-agent
#      uninstall entry point; today, hand-editing the file (above) is the
#      PRIMARY way the sentinel gets populated.
#
#   2. install_<x>_launchagent() does NOT auto-clear the opt-out on every call.
#      An earlier version of this fix had it call _xaca0734_clear_optout()
#      unconditionally — on the theory that "installing something is an
#      explicit opt back in". That was wrong: install_kanban_system() (the
#      installers' only caller) runs on EVERY `aiteamforge setup`, including
#      the explicit `reconfigure` path — not just a fresh install — and calls
#      every install_<x>_launchagent() unconditionally regardless of what the
#      user actually asked for. Auto-clearing there meant a user who opted out
#      by hand, then re-ran setup for an unrelated reason (e.g. adding a team),
#      would silently have their opt-out reversed and the agent reinstalled.
#      Each install_<x>_launchagent() now instead CHECKS the sentinel at entry
#      and refuses to install when opted out (see the guard at the top of each
#      one in install-kanban.sh) — opting back in is only ever a deliberate
#      file edit, never a side effect of running setup or upgrade for something
#      else. _xaca0734_clear_optout stays defined as a primitive for a future
#      explicit "reinstall this one agent" affordance, but nothing currently
#      calls it automatically.
_xaca0734_optout_file() {
  echo "${AITF_LAUNCHAGENT_OPTOUT_FILE:-${HOME}/.aiteamforge/launchagents.optout}"
}

# True (exit 0) when <plist-basename> has a recorded opt-out.
# Exact-line membership test — a substring match would let "lcars-health.plist"
# be shadowed by an unrelated longer entry.
_xaca0734_is_opted_out() {
  local agent="$1"
  local f
  f="$(_xaca0734_optout_file)"

  # Missing sentinel == nothing opted out. This is the common case.
  if [ ! -f "$f" ]; then
    return 1
  fi

  local line
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "$agent" ]; then
      return 0
    fi
  done < "$f"
  return 1
}

# Record an opt-out for <plist-basename>. Idempotent — never appends twice.
_xaca0734_record_optout() {
  local agent="$1"
  local f
  f="$(_xaca0734_optout_file)"

  # Already recorded — nothing to do (dedupe).
  if _xaca0734_is_opted_out "$agent"; then
    return 0
  fi

  mkdir -p "$(dirname "$f")" 2>/dev/null || true
  printf '%s\n' "$agent" >> "$f"
}

# Clear the opt-out for <plist-basename>. No-op when the sentinel is absent or
# the agent is not listed.
#
# NOT currently auto-invoked by install_<x>_launchagent() — see the LIFECYCLE
# note on the sentinel section above for why that would be actively harmful
# given the current call graph (install_kanban_system runs on every
# `aiteamforge setup`, including reconfigure, not just a fresh install). This
# is kept as a primitive for a future targeted single-agent "reinstall this
# one" affordance. Today, opting back in is a manual sentinel edit.
_xaca0734_clear_optout() {
  local agent="$1"
  local f
  f="$(_xaca0734_optout_file)"

  if [ ! -f "$f" ]; then
    return 0
  fi

  local tmp="${f}.tmp.$$"
  # grep -v exits 1 when the result is empty; that is a normal outcome here
  # (the sentinel held only this one agent), so do not let it trip `set -e`.
  grep -v -x -F "$agent" "$f" > "$tmp" 2>/dev/null || true
  mv "$tmp" "$f"
}

# Delete the ENTIRE sentinel. Called ONLY by the full-uninstall path.
# See aiteamforge-uninstall.sh for the rationale — a populated sentinel that
# survives a full uninstall would silently suppress every mandatory agent on the
# next fresh install.
_xaca0734_clear_all_optouts() {
  local f
  f="$(_xaca0734_optout_file)"
  if [ -f "$f" ]; then
    rm -f "$f"
  fi
}

# Print the opt-out escape hatch for <plist-basename>, using the REAL resolved
# sentinel path (never a hardcoded one — respects AITF_LAUNCHAGENT_OPTOUT_FILE
# so tests see the sandboxed path too).
#
# Callers: aiteamforge-upgrade.sh's update_launchagents (when materializing a
# missing mandatory agent — the row-2 case in its decision table) and
# aiteamforge-doctor.sh's `--fix` keepalive remediation. Both call this ONLY on
# the install/materialize path, never on routine refresh — printing it on every
# refresh of an agent the user already has would be noise, and the row-3 skip
# path already reports the opt-out is being honored (no hint needed there).
# Also called under --dry-run, since a would-be install is exactly when the
# hint is useful.
_xaca0734_print_optout_hint() {
  local agent="$1"
  echo "  To permanently opt out instead:"
  echo "    echo \"${agent}\" >> $(_xaca0734_optout_file)"
}

#──────────────────────────────────────────────────────────────────────────────
# Renderer (moved here from aiteamforge-upgrade.sh by XACA-0734)
#──────────────────────────────────────────────────────────────────────────────
# Render a LaunchAgent template to a destination path.
# Applies the FULL substitution map to every template — harmless extras are what
# prevent the sibling-drift bugs described in this file's header.
# Usage: _render_launchagent_template <template_path> <dest_path>
# Returns: 0 on success, 1 if the template is not found.
#
# Resolves the aiteamforge working dir from WORKING_DIR when set (upgrade.sh sets
# it), else get_working_dir() (doctor.sh's context), else the documented default.
_render_launchagent_template() {
  local template="$1"
  local dest="$2"

  if [ ! -f "$template" ]; then
    print_warning "LaunchAgent template not found: $template"
    return 1
  fi

  local working_dir="${WORKING_DIR:-}"
  if [ -z "$working_dir" ]; then
    if declare -f get_working_dir >/dev/null 2>&1; then
      working_dir="$(get_working_dir)"
    else
      working_dir="${AITEAMFORGE_DIR:-$HOME/aiteamforge}"
    fi
  fi

  local kanban_backup_interval="${KANBAN_BACKUP_INTERVAL:-${KANBAN_BACKUP_INTERVAL_DEFAULT:-900}}"

  local python3_path
  # NOTE: PYTHON3_PATH is re-resolved on every render — PATH changes between
  # install and upgrade will silently re-pin the plist interpreter. See XACA-0510.
  python3_path="$(command -v python3 2>/dev/null || echo "/usr/bin/python3")"

  # XACA-0571: resolve aiteamforge binary for the LCARS watch plist.
  local aiteamforge_bin
  aiteamforge_bin="$(command -v aiteamforge 2>/dev/null || echo "/opt/homebrew/bin/aiteamforge")"

  # XACA-0578: resolve Homebrew prefix for cellar-watch plist ({{BREW_CELLAR_DIR}}).
  local brew_prefix
  brew_prefix="$(command -v brew &>/dev/null && brew --prefix 2>/dev/null || echo "/opt/homebrew")"

  sed -e "s|{{USER_HOME}}|$HOME|g" \
      -e "s|{{HOME_DIR}}|$HOME|g" \
      -e "s|{{AITEAMFORGE_DIR}}|${working_dir}|g" \
      -e "s|{{BACKUP_INTERVAL}}|${kanban_backup_interval}|g" \
      -e "s|{{PYTHON3_PATH}}|${python3_path}|g" \
      -e "s|{{AUTO_UPGRADE_SCRIPT}}|${working_dir}/scripts/auto-upgrade.sh|g" \
      -e "s|{{LOG_DIR}}|${working_dir}/logs|g" \
      -e "s|{{LCARS_UI_DIR}}|${working_dir}/lcars-ui|g" \
      -e "s|{{AITEAMFORGE_BIN}}|${aiteamforge_bin}|g" \
      -e "s|{{CELLAR_WATCH_TRIGGER}}|${working_dir}/scripts/cellar-watch-trigger.sh|g" \
      -e "s|{{BREW_CELLAR_DIR}}|${brew_prefix}/Cellar/aiteamforge|g" \
      "$template" > "$dest"
}

# Render + load a single mandatory LaunchAgent from its template.
# Used by `aiteamforge doctor --fix` as the backstop when a mandatory plist is
# missing entirely (upgrade is the primary path; doctor catches boxes that have
# not upgraded yet).
#
# Usage: _xaca0734_render_and_load_launchagent <agent> <framework_dir> [<launchagents_dir>]
# Returns 0 when the agent is rendered AND registered with launchd; 1 otherwise.
# Callers distinguish "render failed" from "rendered but did not register" by
# testing for the plist on disk afterward.
#
# `launchctl load` returns 0 even when the job is REJECTED, so registration is
# verified via `launchctl list` (the XACA-0651-009 load-verify pattern). The
# read-only `launchctl list` is intentionally NOT routed through _aitf_launchctl
# — see the wrapper's header note in lib/common.sh.
_xaca0734_render_and_load_launchagent() {
  local agent="$1"
  local framework_dir="$2"
  local launchagents_dir="${3:-${LAUNCHAGENTS_DIR:-$HOME/Library/LaunchAgents}}"

  local subpath
  if ! subpath="$(_xaca0734_launchagent_template_for "$agent")"; then
    print_warning "Unknown LaunchAgent (not in the XACA-0734 map): ${agent}"
    return 1
  fi

  local template="${framework_dir}/share/templates/${subpath}"
  local dest="${launchagents_dir}/${agent}"

  mkdir -p "$launchagents_dir" 2>/dev/null || true

  if ! _render_launchagent_template "$template" "$dest"; then
    return 1
  fi

  _aitf_launchctl unload "$dest" 2>/dev/null || true
  _aitf_launchctl load "$dest" 2>/dev/null || true

  local label="${agent%.plist}"
  if launchctl list 2>/dev/null | grep -q "$label"; then
    return 0
  fi
  return 1
}
