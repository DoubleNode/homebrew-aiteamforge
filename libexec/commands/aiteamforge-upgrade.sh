#!/bin/bash
# aiteamforge-upgrade.sh
# Upgrade aiteamforge components and framework
# Updates formula, templates, LCARS UI, and skills

set -eo pipefail

# Get framework location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIBEXEC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source shared libraries
source "${LIBEXEC_DIR}/lib/common.sh"
source "${LIBEXEC_DIR}/lib/config.sh"
source "${LIBEXEC_DIR}/lib/constants.sh"
# XACA-0611: imgcat provisioning helper (must come after common.sh — uses info/warning/error)
source "${LIBEXEC_DIR}/lib/imgcat-provision.sh"

# Version — read from VERSION file (single source of truth)
_find_version() { for p in "${LIBEXEC_DIR}/../VERSION" "${LIBEXEC_DIR}/../../VERSION"; do [ -f "$p" ] && cat "$p" | tr -d '[:space:]' && return; done; echo "unknown"; }
VERSION="$(_find_version)"

# Options
DRY_RUN=false
FORCE=false
NON_INTERACTIVE=false  # XACA-0571: auto-answer 'yes' to all prompts; for cron / auto-upgrade

# Usage
usage() {
  cat <<EOF
AITeamForge Upgrade v${VERSION}
Update aiteamforge components to latest version

Usage: aiteamforge upgrade [options]

Options:
  --dry-run         Show what would be updated without making changes
  --force           Force upgrade even if up to date
  --non-interactive Auto-answer 'yes' to all prompts (for cron / auto-upgrade)
  -v, --version     Show version
  -h, --help        Show this help

What Gets Updated:
  • Homebrew formula (if newer version available)
  • Template files (re-processed with current config)
  • LCARS UI files (updated from framework)
  • Kanban hooks (Python lifecycle hooks, e.g. aiteamforge_paths.py)
  • Helper scripts (board-check, restore-helper, backup, kb-cr)
  • Team launch scripts (per-team startup/shutdown + station scripts)
  • Shell aliases and helpers (re-sourced)
  • Skills (symlinks verified or re-copied)
  • LaunchAgents (updated if changed)

What Gets Preserved:
  • User customizations in config files
  • Kanban board data and backups
  • Team configurations
  • secrets.env and credentials

Examples:
  aiteamforge upgrade               # Upgrade to latest version
  aiteamforge upgrade --dry-run     # Preview changes
  aiteamforge upgrade --force       # Re-install even if current

Exit Codes:
  0 - Upgrade successful or already up to date
  1 - Upgrade failed
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --force)
      FORCE=true
      shift
      ;;
    --non-interactive|--yes|-y)
      NON_INTERACTIVE=true
      shift
      ;;
    -v|--version)
      echo "AITeamForge Upgrade v${VERSION}"
      exit 0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      print_error "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

# Check if configured
if ! is_configured; then
  print_error "Dev-team not configured"
  echo "Run: aiteamforge setup"
  exit 1
fi

# Get directories
FRAMEWORK_DIR=$(get_framework_dir)
WORKING_DIR=$(get_working_dir)
CURRENT_VERSION=$(get_installed_version)

# Banner
[[ -t 1 ]] && clear
print_header "AITEAMFORGE UPGRADE"

echo "Current version: ${CURRENT_VERSION:-unknown}"
echo "Framework: ${FRAMEWORK_DIR}"
echo "Working: ${WORKING_DIR}"
echo ""

if [ "$DRY_RUN" = true ]; then
  print_warning "DRY RUN MODE - No changes will be made"
  echo ""
fi

# Check for Homebrew formula updates
check_brew_updates() {
  print_section "Checking for Updates"

  if ! command -v brew &>/dev/null; then
    print_warning "Homebrew not found, skipping formula check"
    return
  fi

  print_info "Checking Homebrew formula..."

  # Check if aiteamforge is installed via Homebrew
  if ! brew list aiteamforge &>/dev/null; then
    print_warning "aiteamforge not installed via Homebrew"
    return
  fi

  # Check for updates
  if brew outdated aiteamforge &>/dev/null; then
    local available_version
    available_version=$(brew info aiteamforge --json | jq -r '.[0].versions.stable')
    print_warning "Update available: ${available_version}"

    if [ "$DRY_RUN" = false ]; then
      # XACA-0571: skip the brew step entirely under --non-interactive — the
      # auto-upgrade LaunchAgent has already run `brew upgrade aiteamforge`
      # before invoking this command; re-running it here would be redundant.
      if [ "$NON_INTERACTIVE" = true ]; then
        print_info "Skipping brew upgrade prompt (--non-interactive); caller already handled brew"
      elif prompt_yes_no "Upgrade Homebrew formula?" "y"; then
        print_info "Upgrading via Homebrew..."
        brew upgrade aiteamforge
        print_success "Formula upgraded"
      fi
    else
      echo "Would upgrade: brew upgrade aiteamforge"
    fi
  else
    print_success "Homebrew formula is up to date"
  fi
}

# Update templates
update_templates() {
  print_section "Updating Templates"

  local templates_updated=0

  # Check if templates directory exists
  if [ ! -d "${FRAMEWORK_DIR}/share/templates" ]; then
    print_warning "Templates directory not found in framework"
    return
  fi

  # Find all templates
  local templates
  templates=$(find "${FRAMEWORK_DIR}/share/templates" -name "*.template" 2>/dev/null)

  if [ -z "$templates" ]; then
    print_info "No templates to update"
    return
  fi

  # Process each template
  while IFS= read -r template; do
    local template_name
    template_name=$(basename "$template" .template)
    local target_file="${WORKING_DIR}/config/${template_name}"

    # Skip if target doesn't exist (wasn't originally installed)
    if [ ! -f "$target_file" ]; then
      continue
    fi

    # Check if template is newer than target
    if [ "$template" -nt "$target_file" ] || [ "$FORCE" = true ]; then
      print_info "Updating ${template_name}..."

      if [ "$DRY_RUN" = false ]; then
        # Back up existing file
        cp "$target_file" "${target_file}.backup-$(date +%Y%m%d-%H%M%S)"

        # Re-process template (this would call template processor)
        # For now, just copy
        cp "$template" "$target_file"

        print_success "Updated ${template_name}"
        templates_updated=$((templates_updated + 1))
      else
        echo "Would update: ${template_name}"
        templates_updated=$((templates_updated + 1))
      fi
    fi
  done <<< "$templates"

  if [ $templates_updated -eq 0 ]; then
    print_success "All templates up to date"
  else
    print_success "Updated ${templates_updated} template(s)"
  fi
}

# Update LCARS UI
update_lcars() {
  print_section "Updating LCARS UI"

  local lcars_source="${FRAMEWORK_DIR}/share/lcars-ui"
  local lcars_target="${WORKING_DIR}/lcars-ui"

  if [ ! -d "$lcars_source" ]; then
    print_warning "LCARS UI not found in framework"
    return
  fi

  if [ ! -d "$lcars_target" ]; then
    print_warning "LCARS UI not installed in working directory"
    return
  fi

  print_info "Syncing LCARS UI files..."

  if [ "$DRY_RUN" = false ]; then
    # Sync files. Preserve the user-customized TOP-LEVEL runtime dir lcars-ui/config/
    # (per-team customizations) — but NOTHING else. XACA-0600: the exclude MUST be
    # anchored with a leading slash so it matches ONLY lcars-ui/config/ at the transfer
    # root. An unanchored 'config/' matches config/ at ANY depth and silently strips the
    # SHIPPED data dir lcars-ui/team_transfer/config/ (the per-team .yaml definitions),
    # which left upgraded tap machines unable to import/export ("No team_transfer config
    # for team X"). Fresh installs (cp -r) were unaffected; only upgrades dropped it.
    rsync -av --exclude '/config/' \
      "${lcars_source}/" "${lcars_target}/"

    print_success "LCARS UI updated"

    # XACA-0600 regression guard: team_transfer/config/ is shipped data that MUST track
    # the framework. If the installed yaml count diverges from the share (e.g. a future
    # exclude-pattern regression or a partial copy), warn loudly but do not fail the
    # upgrade — a stale config is recoverable, a half-applied upgrade is worse.
    local tt_src="${lcars_source}/team_transfer/config"
    local tt_dst="${lcars_target}/team_transfer/config"
    if [ -d "$tt_src" ]; then
      local src_n dst_n
      # Count regular files AND symlinks: 3 of the per-team configs are intra-dir
      # symlink aliases (e.g. medical.yaml -> medical-general.yaml). rsync -a ships
      # them as symlinks, so a -type f count would under-report and let a dropped
      # alias slip past the guard.
      src_n=$(find "$tt_src" -maxdepth 1 -name '*.yaml' \( -type f -o -type l \) 2>/dev/null | wc -l | tr -d ' ')
      dst_n=$(find "$tt_dst" -maxdepth 1 -name '*.yaml' \( -type f -o -type l \) 2>/dev/null | wc -l | tr -d ' ')
      if [ "$src_n" != "$dst_n" ]; then
        print_warning "team_transfer/config yaml mismatch: installed ${dst_n} vs framework ${src_n} (import/export may be impaired — re-run upgrade or report XACA-0600)"
      fi
    fi
  else
    echo "Would sync: ${lcars_source}/ -> ${lcars_target}/"
  fi
}

# Update kanban hooks (Python lifecycle hooks consumed by LCARS + kanban-helpers).
# BUGFIX XACA-0558: in-place upgrades previously never synced kanban-hooks, so a
# `brew upgrade` that shipped a new aiteamforge_paths.py to the Cellar left the
# runtime copy stale (e.g. missing build_team_code_map -> LCARS import warning,
# fallback to hardcoded dirs). Fresh installs were unaffected because
# install-kanban.sh recopies the directory. Mirrors install_kanban_hooks.
update_kanban_hooks() {
  print_section "Updating Kanban Hooks"

  local hooks_source="${FRAMEWORK_DIR}/share/kanban-hooks"
  local hooks_target="${WORKING_DIR}/kanban-hooks"

  if [ ! -d "$hooks_source" ]; then
    print_warning "Kanban hooks not found in framework"
    return
  fi

  if [ ! -d "$hooks_target" ]; then
    print_warning "Kanban hooks not installed in working directory"
    return
  fi

  print_info "Syncing kanban hooks..."

  if [ "$DRY_RUN" = false ]; then
    # Additive sync (no --delete) mirrors install_kanban_hooks: refresh
    # framework-shipped hooks while preserving any operator-added files.
    rsync -av "${hooks_source}/" "${hooks_target}/"
    chmod +x "${hooks_target}"/*.py 2>/dev/null || true
    print_success "Kanban hooks updated"
  else
    echo "Would sync: ${hooks_source}/ -> ${hooks_target}/"
  fi
}

# Canonical aux-script map (XACA-0558, extended XACA-0608). SINGLE source of
# truth: update_aux_scripts consumes it to know what to refresh, and
# update_runtime_helpers reads the scripts/-destined basenames out of it to
# EXCLUDE them from its self-maintaining sweep — so no file is refreshed twice
# (one owner per file). Emit one "source_filename|destination_path" per line.
_xaca0608_aux_script_map() {
  cat <<EOF
kanban-board-check.sh|${WORKING_DIR}/kanban-board-check.sh
kanban-restore-helper.sh|${WORKING_DIR}/kanban-restore-helper.sh
kanban-backup.py|${WORKING_DIR}/kanban-backup.py
lcars-health-check.sh|${WORKING_DIR}/lcars-health-check.sh
kb-cr.sh|${WORKING_DIR}/scripts/kb-cr.sh
auto-upgrade.sh|${WORKING_DIR}/scripts/auto-upgrade.sh
cellar-watch-trigger.sh|${WORKING_DIR}/scripts/cellar-watch-trigger.sh
deploy-worktree-personas.sh|${WORKING_DIR}/scripts/deploy-worktree-personas.sh
worktree-helpers.sh|${WORKING_DIR}/worktree-helpers.sh
EOF
}

# Emit the basenames from the aux map whose destination is WORKING_DIR/scripts/*
# — update_runtime_helpers uses this to avoid double-refreshing them. Derived
# from _xaca0608_aux_script_map so the two stay in lockstep automatically.
_xaca0608_aux_scriptdir_basenames() {
  local name dst
  while IFS='|' read -r name dst; do
    [ -n "$name" ] || continue
    case "$dst" in
      "${WORKING_DIR}/scripts/"*) echo "$name" ;;
    esac
  done < <(_xaca0608_aux_script_map)
}

# Update standalone helper scripts that install-kanban.sh copies individually but
# the upgrade path previously skipped (same bug class as kanban-hooks, XACA-0558).
# Each entry is "source_filename|destination_path"; sources live under
# share/scripts. Only refreshes scripts that are already installed (matches the
# update_shell_helpers convention — upgrade does not create newly-shipped files).
#
# XACA-0608 (extended): these are now laid down through the SAME rewrite-aware
# render the install path uses (_xaca0608_render_team_script), not a plain cp.
# Several of these files carry the literal ~/dev-team / $HOME/dev-team path
# pattern (kb-cr.sh, deploy-worktree-personas.sh, lcars-health-check.sh,
# worktree-helpers.sh) and were previously shipping UN-rewritten on upgrade —
# the working-dir copy ended up pointing at ~/dev-team on tap machines. The sed
# rewrite is a safe no-op for the members that don't carry the pattern, so
# routing the whole map through the render unifies the laydown and closes the
# latent gap without a separate code path. The render-helper's source-of-truth
# is install's _xaca0483_install_script (kept in lockstep — k501 sibling pair).
#
# AGGREGATE_SCRIPT_DIR_FILES (below) lists the basenames this function owns that
# land under WORKING_DIR/scripts/; update_runtime_helpers reads it to EXCLUDE
# them from its self-maintaining sweep so no file is refreshed twice (XACA-0608).
update_aux_scripts() {
  print_section "Updating Helper Scripts"

  local scripts_source="${FRAMEWORK_DIR}/share/scripts"
  local updated=0

  local script_map=()
  local _aux_line
  while IFS= read -r _aux_line; do
    [ -n "$_aux_line" ] && script_map+=("$_aux_line")
  done < <(_xaca0608_aux_script_map)

  local entry name target source
  for entry in "${script_map[@]}"; do
    name="${entry%%|*}"
    target="${entry#*|}"
    source="${scripts_source}/${name}"

    if [ ! -f "$source" ]; then
      continue
    fi

    if [ ! -f "$target" ]; then
      continue
    fi

    if [ "$source" -nt "$target" ] || [ "$FORCE" = true ]; then
      print_info "Updating ${name}..."
      if [ "$DRY_RUN" = false ]; then
        mkdir -p "$(dirname "$target")"
        # XACA-0608: rewrite-aware render (sets exec bit). The ~/dev-team ->
        # WORKING_DIR sed is a no-op for files without the pattern, so this is a
        # safe drop-in for the prior `cp` + `chmod +x`.
        _xaca0608_render_team_script "$source" "$target"
        print_success "Updated ${name}"
        updated=$((updated + 1))
      else
        echo "Would update: ${name}"
        updated=$((updated + 1))
      fi
    fi
  done

  if [ $updated -eq 0 ]; then
    print_success "All helper scripts up to date"
  else
    print_success "Updated ${updated} helper script(s)"
  fi
}

# Update per-team startup/shutdown + station scripts (XACA-0608).
#
# BUGFIX XACA-0608: in-place upgrades never refreshed the per-team launch
# scripts that the install path lays into the working dir. install-team.sh
# (parametric branch, XACA-0483/0484) copies share/scripts/teams/<team>-startup.sh,
# <team>-shutdown.sh and the station scripts under <team>/scripts/*.sh into
# WORKING_DIR with a ~/dev-team -> $AITEAMFORGE_DIR path rewrite, but the upgrade
# command's update_* set omitted them entirely. Result: a machine's working-dir
# <team>-startup.sh stayed FROZEN at install-time even after `brew upgrade` shipped
# a newer one to the Cellar (e.g. M1Pro on 0.12.12 still ran the old cksum LCARS
# port logic, 0 occurrences of resolve_lcars_port, because the XACA-0590 resolver
# script was never laid down). Same refresh-gap class as XACA-0558 (kanban-hooks)
# / XACA-0585 (lcars-health) and a k501 sibling-drift datapoint (install grew the
# team-script laydown; upgrade's refresh map never followed).
#
# Design:
#   • LOOP over the shipped share/scripts/teams/*-startup.sh (self-maintaining —
#     a newly-added team is covered with no edit here; avoids re-introducing the
#     hardcoded-list drift this bug came from).
#   • Refresh ONLY scripts that are ALREADY installed in WORKING_DIR (matches the
#     update_aux_scripts / update_shell_helpers convention — upgrade must not
#     materialise files for teams the user never installed).
#   • Apply the SAME ~/dev-team -> $WORKING_DIR sed rewrite that install's
#     _xaca0483_install_script() performs. These scripts carry literal ~/dev-team
#     references (incl. the iterm2_window_manager.py top-level special case); a
#     plain cp would ship broken paths to tap machines. The on-disk copy diverges
#     from source by design (path rewrite), so an mtime/-nt guard would either
#     always trip or never trip depending on clock skew — instead we re-render
#     unconditionally (cheap) when the target exists, matching the install path's
#     "always re-install, substitution is cheap" stance for path-rewritten files.
#   • Preserve exec bits (chmod +x), mirroring the installer.
#   • These are STATELESS launch scripts: they carry no per-machine rendered values
#     other than the ~/dev-team -> $AITEAMFORGE_DIR path rewrite (verified: no
#     un-rendered {{VAR}} template SLOTS in share/scripts/teams/ — the path-only
#     rewrite leaves any literal {{VAR}} sed-logic/comments untouched). Re-rendering
#     with the same rewrite install uses is therefore a faithful refresh, not a clobber.
_xaca0608_render_team_script() {
  # Mirror of install-team.sh::_xaca0483_install_script — keep these two sed
  # chains in lockstep (k501 sibling pair). The iterm2_window_manager.py special
  # case must come BEFORE the general ~/dev-team mapping.
  local src="$1" dst="$2"
  sed -e "s|\$HOME/dev-team/iterm2_window_manager.py|${WORKING_DIR}/scripts/iterm2_window_manager.py|g" \
      -e "s|\${HOME}/dev-team/iterm2_window_manager.py|${WORKING_DIR}/scripts/iterm2_window_manager.py|g" \
      -e "s|~/dev-team/iterm2_window_manager.py|${WORKING_DIR}/scripts/iterm2_window_manager.py|g" \
      -e "s|\$HOME/dev-team|${WORKING_DIR}|g" \
      -e "s|\${HOME}/dev-team|${WORKING_DIR}|g" \
      -e "s|~/dev-team|${WORKING_DIR}|g" \
      "$src" > "$dst"
  chmod +x "$dst"
}

update_team_scripts() {
  print_section "Updating Team Launch Scripts"

  local teams_source="${FRAMEWORK_DIR}/share/scripts/teams"

  if [ ! -d "$teams_source" ]; then
    print_warning "Team scripts not found in framework"
    return
  fi

  local updated=0
  local startup_src team_id

  # Self-maintaining loop: derive team ids from the shipped *-startup.sh names.
  for startup_src in "$teams_source"/*-startup.sh; do
    [ -f "$startup_src" ] || continue
    team_id="$(basename "$startup_src" -startup.sh)"

    # Top-level startup/shutdown pair: source -> WORKING_DIR/<team>-{startup,shutdown}.sh
    local kind src target
    for kind in startup shutdown; do
      src="${teams_source}/${team_id}-${kind}.sh"
      target="${WORKING_DIR}/${team_id}-${kind}.sh"
      [ -f "$src" ] || continue
      # Refresh only if already installed (do not materialise opted-out teams).
      [ -f "$target" ] || continue
      print_info "Updating ${team_id}-${kind}.sh..."
      if [ "$DRY_RUN" = false ]; then
        _xaca0608_render_team_script "$src" "$target"
        print_success "Updated ${team_id}-${kind}.sh"
      else
        echo "Would update: ${team_id}-${kind}.sh"
      fi
      updated=$((updated + 1))
    done

    # Station scripts: share/scripts/teams/<team>/scripts/*.sh -> WORKING_DIR/<team>/scripts/*.sh
    # (XACA-0484 install layout). Only refresh if the team's station dir already exists.
    local station_src_dir="${teams_source}/${team_id}/scripts"
    local station_dst_dir="${WORKING_DIR}/${team_id}/scripts"
    if [ -d "$station_src_dir" ] && [ -d "$station_dst_dir" ]; then
      local station_src station_name station_dst
      for station_src in "$station_src_dir"/*.sh; do
        [ -f "$station_src" ] || continue
        station_name="$(basename "$station_src")"
        station_dst="${station_dst_dir}/${station_name}"
        # Refresh only station scripts that are already installed.
        [ -f "$station_dst" ] || continue
        print_info "Updating ${team_id}/scripts/${station_name}..."
        if [ "$DRY_RUN" = false ]; then
          _xaca0608_render_team_script "$station_src" "$station_dst"
          print_success "Updated ${team_id}/scripts/${station_name}"
        else
          echo "Would update: ${team_id}/scripts/${station_name}"
        fi
        updated=$((updated + 1))
      done
    fi
  done

  if [ $updated -eq 0 ]; then
    print_success "All team launch scripts up to date"
  elif [ "$DRY_RUN" = true ]; then
    print_success "Would update ${updated} team script(s)"
  else
    print_success "Updated ${updated} team script(s)"
  fi
}

# Update top-level runtime helpers laid into WORKING_DIR/scripts/ (XACA-0608, extended).
#
# BUGFIX XACA-0608 (extended scope): the install path lays a set of top-level
# share/scripts/* helpers into $AITEAMFORGE_DIR/scripts/ — some WITH the
# ~/dev-team -> $AITEAMFORGE_DIR path rewrite (install-team.sh's
# _xaca0483_install_script: lcars-launch-helpers.sh, kb-init-team-guard.sh,
# kb-init-team) and some via plain cp (install-shell.sh / install-kanban.sh:
# agent-panel-display.sh, lcars-tmp-dir.sh, fleet-reporter.sh, iterm2_window_manager.py,
# cr-confluence-poller.py, …). The upgrade command refreshed NONE of them. The
# most damaging consequence: lcars-launch-helpers.sh DEFINES resolve_lcars_port
# (XACA-0590). A machine installed before that helper gained the resolver kept a
# FROZEN copy with no resolve_lcars_port, so every <team>-startup.sh fell through
# to the cksum-derived port and served LCARS on the WRONG port even after a brew
# upgrade. This is the actual root cause the team-script-only fix (this PR's
# first pass) did not reach — the startup scripts were refreshed, but the helper
# they source was not. Same refresh-gap / k501 sibling-drift class as the
# per-team scripts.
#
# Design (mirrors update_aux_scripts / update_team_scripts conventions):
#   • SELF-MAINTAINING sweep over every shipped share/scripts/*.sh, *.py and the
#     extensionless kb-init-team, targeting WORKING_DIR/scripts/<name>. A newly
#     shipped helper is covered with NO edit here — this is the whole point, to
#     stop re-introducing the hardcoded-list drift this bug class keeps causing.
#   • Refresh ONLY targets that ALREADY exist in WORKING_DIR/scripts/ (upgrade
#     never materialises files a given machine's install layout did not lay down;
#     e.g. cr-confluence-poller.py only exists if kanban CR pollers were set up).
#   • Render through the SAME rewrite-aware _xaca0608_render_team_script the
#     install path uses. The sed is a safe no-op for files without the pattern,
#     so a single code path correctly handles both the rewrite-carrying helpers
#     (lcars-launch-helpers.sh: 10 refs, agent-panel-display.sh: 4, …) and the
#     plain ones — without a parallel cp branch to drift out of sync.
#   • EXCLUDE the aux-map's scripts/-destined basenames (kb-cr.sh, auto-upgrade.sh,
#     cellar-watch-trigger.sh, deploy-worktree-personas.sh) — update_aux_scripts
#     owns those. One owner per file (no double-refresh). The exclusion set is
#     DERIVED from _xaca0608_aux_script_map so it can never drift from the map.
update_runtime_helpers() {
  print_section "Updating Runtime Helper Scripts"

  local scripts_source="${FRAMEWORK_DIR}/share/scripts"
  local scripts_dest="${WORKING_DIR}/scripts"

  if [ ! -d "$scripts_source" ]; then
    print_warning "Framework share/scripts not found"
    return
  fi
  if [ ! -d "$scripts_dest" ]; then
    print_warning "No working-dir scripts/ directory (nothing to refresh)"
    return
  fi

  # Basenames owned by update_aux_scripts (avoid double-refresh). Loaded into a
  # newline-delimited string for a simple membership test below.
  local aux_owned
  aux_owned="$(_xaca0608_aux_scriptdir_basenames)"

  local updated=0
  local src name target
  # Sweep shipped helpers. The kb-init-team provisioner is extensionless, so it is
  # listed explicitly alongside the *.sh / *.py globs.
  for src in "$scripts_source"/*.sh "$scripts_source"/*.py "$scripts_source"/kb-init-team; do
    [ -f "$src" ] || continue
    name="$(basename "$src")"
    target="${scripts_dest}/${name}"

    # Owned by update_aux_scripts? Skip (exact-line match against the derived set).
    case $'\n'"${aux_owned}"$'\n' in
      *$'\n'"${name}"$'\n'*) continue ;;
    esac

    # Refresh only what this machine already installed under scripts/.
    [ -f "$target" ] || continue

    print_info "Updating scripts/${name}..."
    if [ "$DRY_RUN" = false ]; then
      # Rewrite-aware render (sets exec bit). No-op rewrite for plain files.
      _xaca0608_render_team_script "$src" "$target"
      print_success "Updated scripts/${name}"
    else
      echo "Would update: scripts/${name}"
    fi
    updated=$((updated + 1))
  done

  if [ $updated -eq 0 ]; then
    print_success "All runtime helper scripts up to date"
  elif [ "$DRY_RUN" = true ]; then
    print_success "Would update ${updated} runtime helper script(s)"
  else
    print_success "Updated ${updated} runtime helper script(s)"
  fi
}

# Update shell helpers
update_shell_helpers() {
  print_section "Updating Shell Helpers"

  local updated=0

  # Resolve the homebrew tap share directory (under FRAMEWORK_DIR)
  local tap_share
  tap_share="${FRAMEWORK_DIR}/share"

  # Update kanban-helpers.sh from the kanban template (root of WORKING_DIR)
  local kanban_template="${tap_share}/templates/kanban/kanban-helpers.template.sh"
  local kanban_target="${WORKING_DIR}/kanban-helpers.sh"
  if [ -f "$kanban_template" ] && [ -f "$kanban_target" ]; then
    if [ "$kanban_template" -nt "$kanban_target" ] || [ "$FORCE" = true ]; then
      print_info "Updating kanban-helpers.sh..."
      if [ "$DRY_RUN" = false ]; then
        sed -e "s|{{AITEAMFORGE_DIR}}|${WORKING_DIR}|g" "$kanban_template" > "$kanban_target"
        print_success "Updated kanban-helpers.sh"
        updated=$((updated + 1))
      else
        echo "Would update: kanban-helpers.sh"
        updated=$((updated + 1))
      fi
    fi
  fi

  # Update alias files under share/aliases/
  local aliases_dir="${WORKING_DIR}/share/aliases"
  local templates_dir="${tap_share}/templates/aliases"
  local alias_files=(
    "agent-aliases.sh"
    "cc-aliases.sh"
    "worktree-aliases.sh"
  )

  for alias_file in "${alias_files[@]}"; do
    local source="${templates_dir}/${alias_file}"
    local target="${aliases_dir}/${alias_file}"

    if [ ! -f "$source" ]; then
      continue
    fi

    if [ ! -f "$target" ]; then
      continue
    fi

    if [ "$source" -nt "$target" ] || [ "$FORCE" = true ]; then
      print_info "Updating share/aliases/${alias_file}..."

      if [ "$DRY_RUN" = false ]; then
        sed -e "s|{{AITEAMFORGE_DIR}}|${WORKING_DIR}|g" "$source" > "$target"
        print_success "Updated share/aliases/${alias_file}"
        updated=$((updated + 1))
      else
        echo "Would update: share/aliases/${alias_file}"
        updated=$((updated + 1))
      fi
    fi
  done

  # Update update_claude_agent.sh
  local agent_src="${tap_share}/scripts/update_claude_agent.sh"
  local agent_target="${WORKING_DIR}/update_claude_agent.sh"
  if [ -f "$agent_src" ] && [ -f "$agent_target" ]; then
    if [ "$agent_src" -nt "$agent_target" ] || [ "$FORCE" = true ]; then
      print_info "Updating update_claude_agent.sh..."
      if [ "$DRY_RUN" = false ]; then
        cp "$agent_src" "$agent_target"
        print_success "Updated update_claude_agent.sh"
        updated=$((updated + 1))
      else
        echo "Would update: update_claude_agent.sh"
        updated=$((updated + 1))
      fi
    fi
  fi

  if [ $updated -eq 0 ]; then
    print_success "All shell helpers up to date"
  else
    print_success "Updated ${updated} helper(s)"

    if [ "$DRY_RUN" = false ]; then
      print_info "Reload shell or run: source ~/.zshrc"
    fi
  fi
}

# Update skills
update_skills() {
  print_section "Updating Skills"

  local skills_source="${FRAMEWORK_DIR}/share/skills"
  local skills_target="${WORKING_DIR}/skills"

  if [ ! -d "$skills_source" ]; then
    print_warning "Skills not found in framework"
    return
  fi

  if [ ! -d "$skills_target" ]; then
    print_warning "Skills not installed in working directory"
    return
  fi

  # Check if skills are symlinked or copied
  if [ -L "$skills_target" ]; then
    # Symlinked - just verify link is correct
    local link_target
    link_target=$(readlink "$skills_target")

    if [ "$link_target" = "$skills_source" ]; then
      print_success "Skills symlink is correct"
    else
      print_warning "Skills symlink points to: ${link_target}"
      print_warning "Expected: ${skills_source}"

      if [ "$DRY_RUN" = false ]; then
        # XACA-0571: --non-interactive auto-accepts the symlink fix (default was 'y')
        if [ "$NON_INTERACTIVE" = true ] || prompt_yes_no "Fix symlink?" "y"; then
          rm "$skills_target"
          ln -s "$skills_source" "$skills_target"
          print_success "Symlink fixed"
        fi
      else
        echo "Would fix symlink"
      fi
    fi
  else
    # Copied - sync files
    print_info "Syncing skills..."

    if [ "$DRY_RUN" = false ]; then
      rsync -av --delete "${skills_source}/" "${skills_target}/"
      print_success "Skills updated"
    else
      echo "Would sync: ${skills_source}/ -> ${skills_target}/"
    fi
  fi
}

# Cleanup helper invoked by update_launchagents' RETURN trap.
# Removes any *.new tempfiles that survived an interrupt or early return.
# _upgrade_tmpfiles is populated by update_launchagents before each render.
_upgrade_tmpfiles=()
# shellcheck disable=SC2329  # called indirectly via trap; not a dead function
_cleanup_upgrade_tmpfiles() {
  local f
  for f in "${_upgrade_tmpfiles[@]}"; do
    rm -f "$f"
  done
}

# Render a LaunchAgent template to a tempfile.
# Applies the full substitution map (USER_HOME, AITEAMFORGE_DIR,
# BACKUP_INTERVAL, PYTHON3_PATH, plus XACA-0571 auto-upgrade placeholders)
# so that every template gets every substitution — harmless extras prevent
# sibling-drift bugs.
# Usage: _render_launchagent_template <template_path> <dest_path>
# Returns: 0 on success, 1 if template not found.
#
# XACA-0571-014 SIBLING-DRIFT NOTE: this renderer handles ALL LaunchAgent
# templates during `aiteamforge upgrade`. First-time install renders happen
# in libexec/installers/install-kanban.sh via inline sed (install_*_launchagent
# functions). Both renderers must understand the same placeholder vocabulary;
# adding a placeholder to a new template requires updating BOTH this function
# AND the matching install-kanban.sh installer. The full placeholder list is
# the sed -e chain below — when adding a new {{VAR}}, add it here AND in the
# corresponding inline install sed.
_render_launchagent_template() {
  local template="$1"
  local dest="$2"

  if [ ! -f "$template" ]; then
    print_warning "LaunchAgent template not found: $template"
    return 1
  fi

  local kanban_backup_interval="${KANBAN_BACKUP_INTERVAL:-$KANBAN_BACKUP_INTERVAL_DEFAULT}"
  local python3_path
  # NOTE: PYTHON3_PATH is re-resolved on every upgrade — PATH changes between
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
      -e "s|{{AITEAMFORGE_DIR}}|${WORKING_DIR}|g" \
      -e "s|{{BACKUP_INTERVAL}}|${kanban_backup_interval}|g" \
      -e "s|{{PYTHON3_PATH}}|${python3_path}|g" \
      -e "s|{{AUTO_UPGRADE_SCRIPT}}|${WORKING_DIR}/scripts/auto-upgrade.sh|g" \
      -e "s|{{LOG_DIR}}|${WORKING_DIR}/logs|g" \
      -e "s|{{LCARS_UI_DIR}}|${WORKING_DIR}/lcars-ui|g" \
      -e "s|{{AITEAMFORGE_BIN}}|${aiteamforge_bin}|g" \
      -e "s|{{CELLAR_WATCH_TRIGGER}}|${WORKING_DIR}/scripts/cellar-watch-trigger.sh|g" \
      -e "s|{{BREW_CELLAR_DIR}}|${brew_prefix}/Cellar/aiteamforge|g" \
      "$template" > "$dest"
}

# Update LaunchAgents
update_launchagents() {
  print_section "Updating LaunchAgents"

  # Pairs of "plist-filename:template-subpath" — order matters for logging.
  # Templates resolve to ${FRAMEWORK_DIR}/share/templates/<subpath>.
  # (XACA-0571 widened this to allow subdirs other than kanban/.)
  local agents=(
    "com.aiteamforge.kanban-backup.plist:kanban/backup-plist.template"
    "com.aiteamforge.lcars-health.plist:kanban/lcars-health-plist.template"
    "com.aiteamforge.auto-upgrade.plist:auto-upgrade/auto-upgrade-launchagent.template.plist"
    "com.aiteamforge.lcars-watch.plist:auto-upgrade/lcars-watch-launchagent.template.plist"
    "com.aiteamforge.cellar-watch.plist:auto-upgrade/cellar-watch-launchagent.template.plist"
  )

  # Allow tests to inject a sandbox path instead of the real LaunchAgents dir.
  local launchagents_dir="${LAUNCHAGENTS_DIR:-$HOME/Library/LaunchAgents}"

  local updated=0
  # Reset module-level tempfile tracker; RETURN trap cleans up any survivors.
  _upgrade_tmpfiles=()
  trap '_cleanup_upgrade_tmpfiles' RETURN

  for entry in "${agents[@]}"; do
    local agent="${entry%%:*}"
    local tmpl_subpath="${entry##*:}"
    local template="${FRAMEWORK_DIR}/share/templates/${tmpl_subpath}"
    local target="${launchagents_dir}/${agent}"
    local tmpfile="${target}.new"
    _upgrade_tmpfiles+=("$tmpfile")

    # Skip agents the user has not installed — upgrade must not silently
    # materialise agents the user opted out of at install time.
    if [ ! -f "$target" ]; then
      continue
    fi

    # Template missing: report without aborting the whole upgrade run.
    if ! _render_launchagent_template "$template" "$tmpfile"; then
      continue
    fi

    # Diff rendered output against live target (not the raw template, which
    # always looks different due to {{VAR}} placeholders).
    if ! diff -q "$tmpfile" "$target" &>/dev/null || [ "$FORCE" = true ]; then
      print_info "Updating ${agent}..."

      if [ "$DRY_RUN" = false ]; then
        # Unload current agent (ignore failure — may not be loaded)
        launchctl unload "$target" 2>/dev/null || true

        # Atomically replace with rendered version
        mv "$tmpfile" "$target"

        # Reload agent (ignore failure — may need user session context)
        launchctl load "$target" 2>/dev/null || true

        print_success "Updated ${agent}"
        updated=$((updated + 1))
      else
        echo "Would update: ${agent}"
        rm -f "$tmpfile"
        updated=$((updated + 1))
      fi
    else
      # No change — clean up tempfile, count as no-op
      rm -f "$tmpfile"
    fi
  done

  if [ $updated -eq 0 ]; then
    print_success "All LaunchAgents up to date"
  elif [ "$DRY_RUN" = true ]; then
    print_success "Would update ${updated} LaunchAgent(s)"
  else
    print_success "Updated ${updated} LaunchAgent(s)"
  fi
}

# Ensure imgcat is present for agent-panel image rendering (XACA-0611).
#
# BUGFIX XACA-0611: the upgrade path never re-ensured ~/.iterm2/imgcat, so a
# machine upgraded to a newer tap still had blank agent-panel avatar/termlogo
# images if imgcat was missing. Same refresh-gap class as XACA-0608/0610.
#
# Non-fatal: a missing imgcat is operational noise, not a data hazard. We warn
# loudly but do NOT abort the upgrade. The ensure_imgcat call is guarded from
# tripping `set -e` via the explicit `|| true` on return 1.
#
# NOTE: imgcat provisioning is NOT part of the update_runtime_helpers sweep
# (share/scripts/) or any other update_* sweep. The vendored asset lives under
# share/iterm2/ and is managed exclusively by ensure_imgcat.
update_imgcat() {
  print_section "Provisioning imgcat"

  if [ "$DRY_RUN" = true ]; then
    echo "Would ensure: ~/.iterm2/imgcat (via bundled share/iterm2/imgcat or network fallback)"
    return
  fi

  if ensure_imgcat "${FRAMEWORK_DIR}/share"; then
    print_success "imgcat provisioned — agent-panel images will render"
  else
    print_warning "imgcat provisioning failed — agent-panel avatar/termlogo images will NOT render until this is resolved."
    print_warning "Expected location: ~/.iterm2/imgcat"
    print_warning "Manual fix: copy imgcat from ${FRAMEWORK_DIR}/share/iterm2/imgcat or download from https://iterm2.com/utilities/imgcat"
  fi
}

# Show changelog
show_changelog() {
  print_section "What's New"

  local changelog="${FRAMEWORK_DIR}/share/CHANGELOG.md"

  if [ ! -f "$changelog" ]; then
    print_info "No changelog available"
    return
  fi

  # Show recent changes (last 20 lines)
  print_info "Recent changes:"
  echo ""
  head -n 20 "$changelog"
  echo ""
  print_info "Full changelog: ${changelog}"
}

# Run upgrade
check_brew_updates
update_templates
update_lcars
update_kanban_hooks
update_aux_scripts
update_team_scripts
update_runtime_helpers
update_imgcat
update_shell_helpers
update_skills
update_launchagents

# XACA-0578: Stamp the installed version so `aiteamforge doctor` can detect
# Cellar-vs-working-dir drift if a user runs `brew upgrade aiteamforge` without
# chaining `aiteamforge upgrade --non-interactive`. The cellar-watch LaunchAgent
# normally handles this automatically, but the stamp is the diagnostic backstop.
# Skipped under --dry-run (stamp is a side-effect, not a preview).
if [ "$DRY_RUN" = false ]; then
  _stamp_version_file=""
  for _stamp_candidate in "${FRAMEWORK_DIR}/../VERSION" "${FRAMEWORK_DIR}/VERSION" "${LIBEXEC_DIR}/../VERSION"; do
    if [ -f "$_stamp_candidate" ]; then
      _stamp_version_file="$_stamp_candidate"
      break
    fi
  done
  if [ -n "$_stamp_version_file" ] && [ -d "$WORKING_DIR" ]; then
    if cp "$_stamp_version_file" "$WORKING_DIR/.installed-version" 2>/dev/null; then
      print_info "Stamped working-dir version: $(cat "$WORKING_DIR/.installed-version" | tr -d '[:space:]')"
    fi
  fi
  unset _stamp_version_file _stamp_candidate
fi

# Show changelog (only if not dry run)
if [ "$DRY_RUN" = false ]; then
  show_changelog
fi

# Summary
print_section "Upgrade Complete"

if [ "$DRY_RUN" = true ]; then
  print_info "Dry run complete - no changes made"
  echo ""
  print_info "Run without --dry-run to apply changes"
else
  print_success "Dev-team has been upgraded successfully!"
  echo ""
  print_info "Next steps:"
  echo "  • Reload your shell: source ~/.zshrc"
  echo "  • Restart services: aiteamforge restart"
  echo "  • Run health check: aiteamforge doctor"
fi

exit 0
