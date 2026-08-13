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
# XACA-0734: shared LaunchAgent vocabulary — the agent→template map, the mandatory
# set, the opt-out sentinel helpers, and _render_launchagent_template (which used to
# live in THIS file). Sourced by doctor.sh too; see lib/launchagents.sh for why the
# renderer moved out (it was about to become a fourth copy).
# Must come after common.sh (print_* helpers) and constants.sh (KANBAN_BACKUP_INTERVAL_DEFAULT).
source "${LIBEXEC_DIR}/lib/launchagents.sh"

# Version — read from VERSION file (single source of truth)
_find_version() { for p in "${LIBEXEC_DIR}/../VERSION" "${LIBEXEC_DIR}/../../VERSION"; do [ -f "$p" ] && cat "$p" | tr -d '[:space:]' && return; done; echo "unknown"; }
VERSION="$(_find_version)"

# Options
DRY_RUN=false
FORCE=false
NON_INTERACTIVE=false  # XACA-0571: auto-answer 'yes' to all prompts; for cron / auto-upgrade

# XACA-0702: upgrade-outcome state. check_brew_updates() sets this true when the
# brew step is the install method but the installed version did NOT advance —
# either because the tap is refused (untrusted) or because `brew upgrade` ran but
# the post-upgrade version equals the pre-upgrade version. The final summary block
# reads it: on true we print a LOUD boxed failure + remediation and exit 1, instead
# of the old unconditional "upgraded successfully!" + exit 0. Default false so a
# box with no brew install (or already-current) still reports success normally.
UPGRADE_BREW_FAILED=false
# Whether aiteamforge is installed via Homebrew (decides version-stamp source and
# whether the no-advance check applies at all). Resolved in check_brew_updates().
UPGRADE_VIA_BREW=false
# Real installed brew version AFTER the brew step (parsed from `brew list --versions`).
# Used to stamp .installed-version accurately so doctor/status drift detection is
# not fooled into thinking the box advanced when brew never did.
UPGRADE_BREW_VERSION=""

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

# XACA-0702: parse the installed version token out of `brew list --versions`.
# Output shape is "aiteamforge 0.15.0" (formula name + one-or-more version tokens);
# we want the LAST whitespace-delimited field (the version). Returns empty string
# when the formula is not installed via brew or brew is absent — callers treat an
# empty pre/post pair as "comparison not possible" and skip the no-advance gate.
# set -eo pipefail safe: the whole pipeline is captured by the caller with `|| true`.
_brew_installed_version() {
  command -v brew >/dev/null 2>&1 || { echo ""; return 0; }
  local line
  line="$(brew list --versions aiteamforge 2>/dev/null || true)"
  [ -n "$line" ] || { echo ""; return 0; }
  # Last field = newest installed version token.
  echo "${line##* }"
}

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

  # From here on we KNOW brew is the install method — record it so the final
  # summary stamps the real brew version and applies the no-advance gate.
  UPGRADE_VIA_BREW=true

  # XACA-0702: snapshot the installed version BEFORE any brew mutation so we can
  # detect a stuck box afterwards. Captured into a var first (never inline in a
  # comparison) to stay safe under set -eo pipefail.
  local pre_version=""
  pre_version="$(_brew_installed_version || true)"
  UPGRADE_BREW_VERSION="$pre_version"   # provisional; refreshed post-upgrade below

  # XACA-0676: trust the tap BEFORE any brew load. On a Homebrew with the
  # tap-trust gate active ($HOMEBREW_REQUIRE_TAP_TRUST), an untrusted tap makes
  # `brew outdated` return empty and the formula refuse to load — which would
  # otherwise fall through to a false "Homebrew formula is up to date". Idempotent.
  if ! ensure_tap_trusted; then
    print_warning "Could not run 'brew trust --tap $(_aitf_tap_name)' (older Homebrew without trust gate?) — continuing"
  fi

  # If the formula is STILL refused after trusting, warn LOUDLY and bail —
  # never report success while stuck on the old version.
  # XACA-0702: also record the failure so the FINAL summary fails loudly + exit 1,
  # instead of falling through to "upgraded successfully!". The early return here
  # short-circuits the rest of check_brew_updates (no point probing `brew outdated`
  # on a formula brew refuses to load).
  if tap_load_refused; then
    print_warning "═══════════════════════════════════════════════════════════════"
    print_warning "Homebrew is REFUSING to load the aiteamforge formula (UNTRUSTED TAP)."
    print_warning "Upgrades are BLOCKED — your box will stay on the OLD version."
    print_warning "Remediation:  brew trust --tap $(_aitf_tap_name)"
    print_warning "═══════════════════════════════════════════════════════════════"
    UPGRADE_BREW_FAILED=true
    return
  fi

  # Check for updates. XACA-0702 fix: `brew outdated <formula>` exits 0 when the
  # formula is UP-TO-DATE and 1 when it is OUTDATED (verified on Homebrew 6.x),
  # and prints the formula name to stdout ONLY when outdated. The exit code is the
  # OPPOSITE of "is outdated" — gating on it directly (the prior
  # `if brew outdated ...; then outdated_before=true`) was INVERTED: a genuinely
  # outdated box was classified up-to-date (false success) and a current box was
  # classified outdated. Detect via STDOUT PRESENCE instead, which is direction-
  # unambiguous. `|| true` keeps the captured non-zero (outdated) exit from
  # tripping set -e on the assignment.
  local outdated_before=false
  local _outdated_probe=""
  _outdated_probe="$(brew outdated aiteamforge 2>/dev/null || true)"
  if [ -n "$_outdated_probe" ]; then
    outdated_before=true
  fi

  if [ "$outdated_before" = true ]; then
    local available_version
    available_version=$(brew info aiteamforge --json 2>/dev/null | jq -r '.[0].versions.stable' 2>/dev/null || true)
    print_warning "Update available: ${available_version:-unknown}"

    if [ "$DRY_RUN" = false ]; then
      # XACA-0571: skip the brew step entirely under --non-interactive — the
      # auto-upgrade LaunchAgent has already run `brew upgrade aiteamforge`
      # before invoking this command; re-running it here would be redundant.
      if [ "$NON_INTERACTIVE" = true ]; then
        print_info "Skipping brew upgrade prompt (--non-interactive); caller already handled brew"
        # XACA-0702: the LaunchAgent ran `brew upgrade` BEFORE us, so the pre-snapshot
        # already reflects whatever brew did. We cannot bracket our own brew step here
        # — instead detect a stuck box by re-probing `brew outdated`. XACA-0702: a
        # non-empty stdout means STILL outdated (exit code is inverted; see the
        # detection note above). If outdated, brew never advanced → fail loudly.
        local _still_outdated=""
        _still_outdated="$(brew outdated aiteamforge 2>/dev/null || true)"
        if [ -n "$_still_outdated" ]; then
          print_warning "Formula is STILL outdated after the caller's brew upgrade — brew did not advance."
          UPGRADE_BREW_FAILED=true
        fi
      elif prompt_yes_no "Upgrade Homebrew formula?" "y"; then
        print_info "Upgrading via Homebrew..."
        # XACA-0702: never let a non-zero brew exit kill the script before we can
        # report it. Capture the outcome, then compare pre/post installed versions.
        if brew upgrade aiteamforge; then
          print_success "Formula upgraded"
        else
          print_warning "brew upgrade aiteamforge exited non-zero"
        fi
        local post_version=""
        post_version="$(_brew_installed_version || true)"
        UPGRADE_BREW_VERSION="${post_version:-$UPGRADE_BREW_VERSION}"
        # No-advance detection: a brew upgrade that left the installed version
        # unchanged means the box is stuck (refused tap, pinned, etc.). Only flag
        # when we have BOTH a pre and post token to compare (empty = can't tell).
        if [ -n "$pre_version" ] && [ -n "$post_version" ] && [ "$pre_version" = "$post_version" ]; then
          print_warning "Installed brew version did not advance (still ${post_version})."
          UPGRADE_BREW_FAILED=true
        fi
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

# XACA-0751: Knowledge-repo provisioning on the UPGRADE path.
#
# install_knowledge_repo() (XACA-0747) makes ~/knowledge a real git clone of the
# canonical knowledge repo. Its ONLY call site was install_kanban_system(), which
# runs on a fresh `aiteamforge setup` — NOT on `aiteamforge upgrade`. So every
# already-installed box (the whole fleet) upgraded to a kb-knowledge-carrying
# release yet never received the ~/knowledge directory those 15 helpers operate
# on (confirmed empirically: M4Mini on 0.17.0 with no ~/knowledge). Same bug
# class as XACA-0558 / XACA-0608 (update_kanban_hooks / update_runtime_helpers):
# install-time provisioning the upgrade path never learned about.
#
# We REUSE install_knowledge_repo verbatim — it already handles all four states
# (existing clone -> fetch + ff-only; auth-gate soft-skip; M1Pro husk -> move
# aside, never delete; fresh machine -> clone), is DRY_RUN-aware, honors
# HOME / KB_KNOWLEDGE_GLOBAL_ROOT / KB_KNOWLEDGE_REPO_URL / KB_KNOWLEDGE_SKIP_
# HOOK_SETUP, and is fail-soft by design (always returns 0). We do NOT reimplement
# it (contrast update_kanban_hooks, which re-derives a plain rsync).
#
# Everything runs in a SUBSHELL, for two hard reasons:
#   1. install-kanban.sh opens with `set -euo pipefail`; sourcing it in-process
#      would leak `set -u` into the remainder of the upgrade (which runs `set -eo`
#      WITHOUT -u by design) and abort on the first unset variable. The subshell
#      contains the option change.
#   2. Fail-soft: the nightly auto-upgrade LaunchAgent runs unattended. A knowledge
#      remote that is unreachable / unauthorized (M1Pro's current state — its
#      deploy key is not yet authorized) must NOT fail the upgrade. install_
#      knowledge_repo already soft-skips, but the trailing `|| ...` on the subshell
#      guarantees that even a sourcing error or an unforeseen non-zero exit cannot
#      abort the parent under `set -e`.
# DRY_RUN and all KB_KNOWLEDGE_* overrides are inherited by the subshell (child
# shells inherit non-exported vars too), so `--dry-run` and every override hold.
update_knowledge_repo() {
  print_section "Updating Knowledge Repository"

  local installer="${LIBEXEC_DIR}/installers/install-kanban.sh"
  if [ ! -f "$installer" ]; then
    print_warning "install-kanban.sh not found ($installer) — skipping knowledge-repo provisioning"
    return 0
  fi

  if [ "$DRY_RUN" = true ]; then
    print_info "Would ensure ~/knowledge is provisioned (clone / fast-forward; auth-gated soft-skip; dirty clone left for the sync daemon)"
  else
    print_info "Ensuring ~/knowledge is provisioned (idempotent; fail-soft)..."
  fi

  # Subshell isolates install-kanban.sh's `set -u`; the `||` branch keeps the
  # upgrade fail-soft even if sourcing or provisioning errors. Redirect applies
  # ONLY to the `source` line — install_knowledge_repo's own info/warn/success
  # output still flows to the console.
  if (
      # shellcheck source=/dev/null
      source "$installer" >/dev/null 2>&1
      install_knowledge_repo
    ); then
    print_success "Knowledge repository check complete"
  else
    print_warning "Knowledge-repo provisioning skipped (non-fatal; upgrade continues)"
  fi
  return 0
}

# Materialize the knowledge-sync LaunchAgent onto EXISTING fleet machines
# (XACA-0761). install_knowledge_sync_launchagent's ONLY call site was
# install_kanban_system() (fresh `aiteamforge setup` only) — same defect
# class as update_knowledge_repo's own header comment describes for
# XACA-0747/0751: install-time-only provisioning never reaches boxes that
# were already installed before this feature shipped. This function is the
# fix — it runs install_knowledge_sync_launchagent from the nightly
# auto-upgrade LaunchAgent so every fleet machine eventually gets the daemon,
# not just fresh installs.
#
# We REUSE install_knowledge_sync_launchagent verbatim (same idiom as
# update_knowledge_repo reusing install_knowledge_repo above) rather than
# re-implementing the render+load logic here — it already handles the
# fail-soft ~/knowledge-is-a-real-clone gate, missing-script/template
# soft-skips, and the XACA-0651-009 launchctl-list load-verify pattern.
# install_knowledge_sync_launchagent is UNCONDITIONAL-INSTALL (it (re)renders
# and (re)loads the plist every time it's called, it does not skip when the
# plist is already present) — that "materialize" behavior is exactly what
# gets existing machines that never received the plist caught up, and is
# also idempotent/safe to re-run on machines that already have it.
#
# Unlike update_knowledge_repo, install_knowledge_sync_launchagent DOES read
# $AITEAMFORGE_DIR and $INSTALL_ROOT (to resolve the plist template, the
# script source, and both install destinations) — but neither is guaranteed
# to be exported into this process the way aiteamforge-setup.sh explicitly
# `export`s them before invoking installers. So, unlike update_knowledge_repo,
# we explicitly set both inside the subshell from this script's own
# WORKING_DIR / FRAMEWORK_DIR (the upgrade path's equivalents, see
# get_working_dir / get_framework_dir in libexec/lib/config.sh) before
# sourcing — install-kanban.sh itself never defines either var, it only
# consumes them.
#
# Same subshell rationale as update_knowledge_repo: (1) install-kanban.sh's
# `set -euo pipefail` must not leak into the rest of this `set -eo` (no -u)
# upgrade script, and (2) the nightly auto-upgrade LaunchAgent runs
# unattended, so a sourcing error or unexpected non-zero exit must never
# abort the parent upgrade — the trailing `|| ...` branch guarantees that.
update_knowledge_sync() {
  print_section "Updating knowledge-sync LaunchAgent"

  local installer="${LIBEXEC_DIR}/installers/install-kanban.sh"
  if [ ! -f "$installer" ]; then
    print_warning "install-kanban.sh not found ($installer) — skipping knowledge-sync LaunchAgent"
    return 0
  fi

  if [ "$DRY_RUN" = true ]; then
    print_info "Would materialize the knowledge-sync LaunchAgent if ~/knowledge is a real git clone (fail-soft skip otherwise)"
  else
    print_info "Ensuring knowledge-sync LaunchAgent is installed (idempotent; fail-soft)..."
  fi

  # Subshell isolates install-kanban.sh's `set -u` (see rationale above);
  # AITEAMFORGE_DIR / INSTALL_ROOT are set here — not exported — so they
  # apply only inside this subshell and never leak into the rest of the
  # upgrade run.
  if (
      AITEAMFORGE_DIR="${WORKING_DIR}"
      INSTALL_ROOT="${FRAMEWORK_DIR}"
      export AITEAMFORGE_DIR INSTALL_ROOT
      # shellcheck source=/dev/null
      source "$installer" >/dev/null 2>&1
      install_knowledge_sync_launchagent
    ); then
    print_success "Knowledge-sync LaunchAgent check complete"
  else
    print_warning "Knowledge-sync LaunchAgent provisioning skipped (non-fatal; upgrade continues)"
  fi
  return 0
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
kb-port-reconcile|${WORKING_DIR}/scripts/kb-port-reconcile
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

# Read a team conf's parameterisation flags (XACA-0834).
#
# Emits "<TEAM_HAS_PROJECTS>|<TEAM_REQUIRES_CLIENT_ID>" on stdout, defaulting
# either to "false" when the conf omits it (matching compute_instance_id()'s
# own treatment of unset flags).
#
# The conf is sourced inside a SUBSHELL so its assignments (TEAM_ID,
# TEAM_WORKING_DIR, TEAM_LCARS_PORT, ...) can never leak into the upgrade
# process — this file runs a long sequence of other update_* steps that must
# not observe a team conf's variables. `set +eo pipefail` inside the subshell
# keeps a malformed conf from aborting the upgrade under the file's `set -eo`;
# a conf that fails to source yields the "false|false" default, which routes
# the instance to the "template takes no parameters" branch and — for a
# genuinely parameterised instance — produces a visible skip warning rather
# than a silently wrong installer invocation.
_connect_script_team_flags() {
  (
    set +eo pipefail
    TEAM_HAS_PROJECTS=""
    TEAM_REQUIRES_CLIENT_ID=""
    # shellcheck disable=SC1090
    . "$1" >/dev/null 2>&1
    printf '%s|%s' "${TEAM_HAS_PROJECTS:-false}" "${TEAM_REQUIRES_CLIENT_ID:-false}"
  ) || printf 'false|false'
}

# Refresh per-team connect/disconnect cockpit scripts on upgrade (XACA-0814,
# instance-id recovery reworked in XACA-0834).
#
# BUGFIX XACA-0814: install-time-only provisioning — same bug class as the
# XACA-0608 / XACA-0673 / XACA-0751 gaps documented above this in the file
# (K113: "install path grows a step, upgrade path never learns about it").
# install-team.sh --connect-only renders ${INSTANCE_ID}-connect.sh and
# ${INSTANCE_ID}-disconnect.sh into WORKING_DIR, but ONLY at `aiteamforge
# setup` time — bin/aiteamforge-setup.sh's cockpit-mode pass (~line 1420) and
# its full-mode "render remaining teams" pass (~line 1394) are the ONLY call
# sites. The upgrade run-sequence never re-ran that step, so XACA-0785's fix
# to the connect-script generator itself shipped in a release but never
# reached a machine that had ALREADY installed under the broken generator —
# `aiteamforge upgrade` bumped every other component and left the stale,
# pre-XACA-0785 connect/disconnect scripts in place, untouched, forever, on
# every consumer box that installed before the fix landed. This function
# closes that gap the same way update_team_scripts / update_runtime_helpers
# close their equivalents: a self-maintaining, refresh-only sweep, delegated
# entirely to install-team.sh --connect-only so INSTANCE_ID computation
# (including the finance/medical/legal/freelance project-augmented instance-id
# path, XACA-0485) is never duplicated here.
#
# Design:
#   • Enumerate ${FRAMEWORK_DIR}/share/teams/*.conf — the same source list
#     install-team.sh itself derives team ids from, and the same list
#     bin/aiteamforge-setup.sh's cockpit pass iterates (mirror the
#     authoritative reference exactly, don't reinvent team discovery).
#     Parametric/umbrella teams with no .conf (DNS, MainEvent) are naturally
#     excluded here, and install-team.sh's own CONNECT_ONLY branch additionally
#     no-ops for parametric teams regardless (see install-team.sh's parametric
#     comments near its connect/disconnect generation) — belt and suspenders,
#     not a reimplementation of that skip logic.
#   • Refresh-only guard, driven by the RENDERED FILES (XACA-0834): iterate
#     "${WORKING_DIR}"/*-connect.sh and RECOVER the instance id by stripping the
#     "-connect.sh" suffix. install-team.sh writes exactly "${INSTANCE_ID}-connect.sh",
#     so the filename IS this box's record of which instance it installed —
#     recover that record rather than re-deriving it.
#
#     This function previously iterated team CONFIGS, detected installedness
#     with an unanchored "${team_id}*-connect.sh" glob, and then re-rendered
#     using the BARE team id — discarding the very instance shape the glob had
#     just matched. Three defects followed (XACA-0834):
#       - install-team.sh resolves a bare parameterised id through
#         TEAM_DEFAULT_PROJECT, so an installed "finance-work" was re-rendered
#         as "finance-personal": a cockpit script this machine never installed,
#         while the real one stayed stale. Not a no-op — active mis-materialisation.
#       - "freelance" sets TEAM_REQUIRES_CLIENT_ID=true with NO client default,
#         so the bare call could not resolve an instance id at all and its
#         connect scripts were never refreshed (the fail-soft branch below
#         swallowed the error on the TTY-less nightly LaunchAgent run; on an
#         interactive run install-team.sh would instead PROMPT for a client id
#         mid-upgrade). Passing --client explicitly retires both behaviours.
#       - the unanchored glob could false-match a longer team id sharing the
#         prefix (a "med" template matching "medical-general-connect.sh").
#         Iterating filenames makes this structurally impossible: we never glob
#         on a team id at all, so there is no prefix to collide. No hardened
#         "${team_id}*" glob remains.
#
#     A team whose connect script was never rendered on this machine (never
#     installed, or opted out) is still skipped — upgrade must never materialise
#     cockpit scripts for a team this box didn't set up. That guarantee now
#     comes from only ever refreshing files that already exist. The recovered
#     instance is still validated against the shipped team configs, using
#     ANCHORED shapes only ("<team>" exactly, or "<team>-<rest>"), so a stray
#     file cannot drive an installer invocation. Guard each glob candidate with
#     `[ -f "$f" ]` so the loop is safe whether or not nullglob is set.
#   • Instance decomposition is the exact inverse of install-team.sh's
#     compute_instance_id() (XACA-0460-008 / XACA-0485). That function emits:
#       TEAM_HAS_PROJECTS=false                     -> "<team>"
#       TEAM_HAS_PROJECTS=true, no client required  -> "<team>-<project>"
#       TEAM_HAS_PROJECTS=true, client required     -> "<team>-<client>-<project>"
#     Components are validated against ^[a-z0-9_]+$ — they never contain a
#     dash — so once the team id is known the remainder splits unambiguously.
#     Because a bare team id may itself contain a dash, matching prefers the
#     LONGEST matching template id (an exact match therefore always wins).
#   • Delegate the actual render to install-team.sh --connect-only in an
#     isolated `bash` SUBPROCESS (not `source`) — exactly like the setup
#     wizard's own cockpit loop (bin/aiteamforge-setup.sh's
#     `AITEAMFORGE_DIR="${INSTALL_DIR}" bash "${INSTALLERS_DIR}/install-team.sh"
#     "$_ct" --connect-only --install-dir "${INSTALL_DIR}"`). A full subprocess
#     fully isolates install-team.sh's `set -euo pipefail` from this script's
#     `set -eo` (no -u, see top of file) — `set -u` can never leak into the
#     upgrade the way it could if this were sourced (contrast
#     update_knowledge_repo/update_knowledge_sync above, which DO source
#     install-kanban.sh and need the subshell-with-option-change trick because
#     of that; install-team.sh's own CONNECT-ONLY EARLY EXIT block is written
#     to be invoked by a fresh interpreter, not sourced into a caller).
#   • Fail-soft: a single team's render failure never aborts the upgrade —
#     this runs unattended under the nightly auto-upgrade LaunchAgent.
#     `set -eo pipefail` is active at the top of this file, so the
#     `if ( ... | sed ... ); then` construct below correctly observes
#     install-team.sh's own exit status through the pipe.
#   • DRY_RUN-aware: prints what would be refreshed without invoking the
#     installer.
#   • XACA-0862 subitem 005: a THIRD work-list source was added — team-paths.json
#     registry entries whose recorded working_dir exists on disk. Sources (a)
#     and (b) both had a common blind spot: an instance registered on this box
#     AFTER its one .aiteamforge-config-writing setup run (e.g. a second
#     parametric project added later via install-team.sh directly) is visible
#     to neither, so its connect script — even though a template for it ships —
#     never gets created, ever. See the "Source (c)" comment block inside the
#     function for the full contract and why this differs from the team-paths.json
#     membership approach XACA-0845-008 already tried and reverted. dns and
#     mainevent remain deliberately unmaterialised (see that comment and the
#     XACA-0862 plan doc's "Cause B" section) — not an oversight, a scoped-out
#     decision pending real DNS-team agent/session data this ticket doesn't have.
#
# XACA-0862-020: ids that are PERMANENTLY, INTENTIONALLY scoped out (no
# shipped team template exists and none is planned — see the comment above
# and the XACA-0862 plan doc's "Cause B" section). Such an id still ships a
# real working_dir, so source (c) still legitimately recovers it as a
# work-list candidate — that recovery is correct and must not change — but it
# can never resolve to a template, so it is skipped downstream on EVERY
# unattended nightly upgrade, forever. A recurring print_warning for a defect
# that will never be fixed (because there is nothing to fix) trains operators
# to tune out the exact channel that also reports a genuinely broken or
# unrecognised instance. Downgrade the message to print_info (still visible,
# just not counted as a warning) and exclude it from the `skipped` tally that
# drives the final "Skipped N unrecognised..." summary line. Add an id here
# ONLY for a similarly permanent, deliberate exclusion — never for an
# instance that might legitimately be missing a template by mistake; an
# unrecognised id NOT on this list still warns and counts exactly as before.
_xaca0862_020_known_scoped_out_ids() {
  cat <<'EOF'
dns
EOF
}

_xaca0862_020_is_known_scoped_out() {
  local id="$1" known
  while IFS= read -r known; do
    [ -z "$known" ] && continue
    [ "$id" = "$known" ] && return 0
  done <<EOF
$(_xaca0862_020_known_scoped_out_ids)
EOF
  return 1
}

update_connect_scripts() {
  print_section "Updating Team Connect/Disconnect Scripts"

  local teams_conf_dir="${FRAMEWORK_DIR}/share/teams"
  local installer="${LIBEXEC_DIR}/installers/install-team.sh"

  if [ ! -d "$teams_conf_dir" ]; then
    print_warning "Team configs not found ($teams_conf_dir) — skipping connect-script refresh"
    return 0
  fi
  if [ ! -f "$installer" ]; then
    print_warning "install-team.sh not found ($installer) — skipping connect-script refresh"
    return 0
  fi

  local updated=0
  local failed=0
  local skipped=0
  local f base instance_id conf team_id best_team best_conf remainder
  local flags has_projects requires_client client project
  local -a install_args

  # ── Build the work list: a UNION of two sources (XACA-0845) ──────────────
  #   (a) *-connect.sh files already on disk — the XACA-0834 behaviour;
  #   (b) instances this box actually INSTALLED, read from the install's own
  #       .aiteamforge-config `.teams[]`.
  #
  # Why (b) had to be added: (a) alone can only ever REFRESH a script that
  # already exists. It can never CREATE a missing one, so an instance that is
  # live but scriptless stays scriptless through every upgrade, forever, while
  # orphaned scripts for instances nobody runs get refreshed on each pass. That
  # is the exact state XACA-0845 found: two live parametric instances with no
  # connect script, alongside refreshed orphans for conf-default instances.
  #
  # WHY NOT team-paths.json (XACA-0845-008). The first cut of this union ALSO
  # read the registry at ~/.aiteamforge/team-paths.json `.teams`, on the stated
  # premise that "registry membership is affirmative PROOF of setup". That
  # premise is false, and it broke the very guarantee the union was meant to
  # preserve. team-paths.json is written by aiteamforge-team-paths-wizard.py,
  # which (1) prompts "Enable <team>?" with the default answer YES for every
  # catalogued team, (2) under --accept-defaults writes DEFAULT_TEAMS verbatim
  # with no prompt at all, and (3) unconditionally re-adds every ALIAS_TEAMS
  # entry after the prompt loop. That catalogue ships 16 instances (academy,
  # android, command, dns, finance-personal, firebase, ios, legal-coparenting,
  # the mainevent set, medical-general). So a box that installed ios ALONE
  # would have had connect scripts materialised for academy, android, command,
  # firebase, finance-personal, legal-coparenting and medical-general — teams
  # it never set up. Worse, the file need not have been authored deliberately
  # at all: aiteamforge_team_lcars_port() MATERIALIZES a default registry on
  # its first lookup (see the read-only note in aiteamforge-status.sh), so a
  # full 16-team registry can exist on a box where setup never ran.
  #
  # .aiteamforge-config IS proof. bin/aiteamforge-setup.sh writes `.teams[]`
  # from SELECTED_TEAMS, and writes it AFTER the loop that runs install-team.sh
  # for each of those teams — a team reaches that array only by being chosen
  # and surviving install-time validation (which can also remove it again).
  # Cockpit installs deliberately record an EMPTY `.teams[]` and are covered
  # entirely by source (a), i.e. exactly their pre-XACA-0845 behaviour.
  #
  # Neither remaining source globs a team id or invents an instance; both yield
  # concrete instance ids that are still validated against the shipped team
  # confs below, and anything unrecognised is skipped, not guessed at.
  local work_list=""
  local _install_config="${WORKING_DIR}/.aiteamforge-config"
  local _reg_instances=""

  for f in "${WORKING_DIR}"/*-connect.sh; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    # Recover the instance id: the exact inverse of install-team.sh's
    # "${INSTANCE_ID}-connect.sh" filename composition.
    instance_id="${base%-connect.sh}"
    if [ -z "$instance_id" ]; then
      print_warning "Skipping ${base} — empty instance id after suffix-stripping"
      skipped=$((skipped + 1))
      continue
    fi
    work_list="${work_list}${instance_id}"$'\n'
  done

  # Installed instances, read from .aiteamforge-config. Read with python3 —
  # a hard dependency of the installer this function drives — and fail soft:
  # a missing or malformed config must degrade to the on-disk-only work list
  # (the pre-XACA-0845 behaviour), never abort an unattended nightly upgrade.
  #
  # NOTE FOR EDITORS: no apostrophes anywhere in the here-doc body below. Under
  # bash 3.2 (every macOS consumer box) a here-doc nested inside $( ) is NOT
  # treated as opaque, so one stray single quote opens an unterminated quote and
  # the WHOLE file fails to parse — with the error reported hundreds of lines
  # later, nowhere near the real cause. See XACA-0845.
  if command -v python3 >/dev/null 2>&1; then
    _reg_instances="$(python3 - "$_install_config" <<'PYEOF' 2>/dev/null || true
import json, sys

out = []

# .aiteamforge-config: .teams[] holds BASE ids; .team_paths.<base>.project_id
# carries the project, and .team_paths.<base>.client_id the client, for
# parameterised installs. Compose the instance id EXACTLY the way
# compute_instance_id() in install-team.sh does, lowercasing each component:
#
#     no project                  -> "<base>"
#     project, no client          -> "<base>-<project>"
#     project + client            -> "<base>-<client>-<project>"
#
# XACA-0845-015: the client component was missing here, and its absence was a
# REGRESSION relative to the pre-XACA-0845-008 code. That version took the whole
# instance id straight from the team-paths.json KEY, so it never had to compose
# anything and never lost a component. Moving the authoritative signal to
# .aiteamforge-config was correct (registry membership is not proof of setup)
# but it made composition this code paragraph responsibility, and the client was
# dropped. freelance is the only TEAM_REQUIRES_CLIENT_ID template that ships, so
# a freelance box composed "freelance-<project>", which the decomposition below
# then rejected outright with "cannot split <project> into <client>-<project>".
# Net effect: nothing was created, so a live-but-scriptless freelance instance
# was UNHEALABLE — the exact bug class this union exists to fix — and every
# upgrade printed a spurious warning about it.
#
# Ordering is load-bearing: client comes BEFORE project, matching
# compute_instance_id() and therefore matching the decomposition below, which
# splits the remainder on the FIRST dash into <client>-<project>.
#
# setup writes client_id only when BOTH a client and a project are present
# (bin/aiteamforge-setup.sh team_paths writer), so a client without a project is
# not a shape this file can emit; treat it as project-less and fall through to
# the bare base rather than inventing a component.
try:
    with open(sys.argv[1]) as fh:
        cfg = json.load(fh)
    paths = cfg.get("team_paths", {}) or {}
    for base in cfg.get("teams", []) or []:
        base = str(base)
        entry = paths.get(base) or {}
        pid = entry.get("project_id")
        cid = entry.get("client_id")
        if pid:
            pid = str(pid).lower()
            if cid:
                out.append("%s-%s-%s" % (base, str(cid).lower(), pid))
            else:
                out.append("%s-%s" % (base, pid))
        else:
            out.append(base)
except Exception:
    pass

for i in out:
    if i:
        print(i)
PYEOF
)"
  fi

  if [ -n "$_reg_instances" ]; then
    work_list="${work_list}${_reg_instances}"$'\n'
  fi

  # ── Source (c): team-paths.json REGISTRY entries whose recorded working_dir
  # exists on disk (XACA-0862 subitem 005) ──────────────────────────────────
  #
  # THE GAP THIS CLOSES. Source (b) can only see instances that were part of
  # THIS box's ONE bin/aiteamforge-setup.sh run (.aiteamforge-config `.teams[]`
  # is written once, from that run's SELECTED_TEAMS, and never updated again).
  # A parametric instance added to a box AFTER initial setup — a second
  # project registered by re-running install-team.sh directly, or via the
  # team-paths wizard — reaches team-paths.json (install-team.sh's XACA-0463
  # persist step runs on every full install) but never touches
  # .aiteamforge-config. Neither (a) nor (b) can ever see it, so its connect
  # script stays missing through every future upgrade, forever. This was the
  # live XACA-0862 field gap on M4 Mini: legal-coparenting and medical-general
  # were both registered, both had shipped confs, both had a real working_dir
  # on disk — and both were permanently invisible to this function before this
  # source existed.
  #
  # WHY THIS IS NOT THE REJECTED XACA-0845-008 APPROACH (see the comment
  # above source (b)). That attempt trusted bare KEY PRESENCE in
  # team-paths.json as proof of setup and was reverted specifically because
  # aiteamforge-team-paths-wizard.py can write an entry for a team NEVER
  # installed: interactively, its "'<path>' does not exist on disk — Use this
  # path anyway?" prompt defaults YES; under --accept-defaults it writes
  # DEFAULT_TEAMS verbatim with no existence check at all. Bare membership is
  # still not proof. This source adds a narrower gate: the instance's
  # recorded working_dir must exist as a real directory on THIS box.
  # install-team.sh's own team-paths.json persist step runs only on full
  # installs, after mkdir -p'ing the working/kanban dir — so a genuinely
  # installed instance's working_dir is guaranteed present, while a
  # wizard-catalogued-but-never-installed entry (or a stale entry surviving a
  # manual directory removal) is not. mainevent needs no special case: its
  # registry entry, on the rare box where one exists, carries the literal
  # sentinel string "null" as working_dir (XACA-0727 — mainevent is
  # deliberately board-less), which fails the directory test the same as any
  # other absent path.
  #
  # XACA-0862-021: working_dir isdir() ALONE is still not airtight.
  # --accept-defaults (see above) writes every DEFAULT_TEAMS working_dir
  # VERBATIM with no existence check at all — so a never-installed team whose
  # CATALOG-DEFAULT path merely happens to already exist on this box (e.g. a
  # directory created for an unrelated reason, or one surviving a manual
  # uninstall) satisfies isdir(working_dir) and would be wrongly materialised
  # — the XACA-0845-008 failure mode in reduced form, just narrower. Require
  # kanban_dir to ALSO exist as a real directory. install-team.sh's persist
  # step writes kanban_dir ONLY as part of a genuine install, and that same
  # install unconditionally `mkdir -p`s it before team-paths.json is ever
  # written — a bare pre-existing/coincidental working_dir will essentially
  # never also happen to already contain a "kanban" subdirectory. This is
  # deliberately a directory check, not a check for the exact
  # "<instance_id>-board.json" filename: install-team.sh may skip writing
  # that specific file when a profile-scoped canonical board already exists
  # elsewhere (see its "Skipping stub: profile-scoped canonical board already
  # exists" path), but it always creates kanban_dir itself first, so that
  # directory's existence is the reliable genuine-install signal, not the
  # board file's.
  #
  # Like (a) and (b), this yields concrete instance ids only — never a glob —
  # and every id is still validated below against the shipped team confs
  # using the same ANCHORED shapes, so an unrecognised or malformed id is
  # skipped, not guessed at. dns and mainevent are exactly this case: dns has
  # a real working_dir but ships no share/teams/dns.conf (it isn't even in
  # share/teams/registry.json's installable catalog — a separate, deliberate
  # gap this ticket does NOT close; see XACA-0862 plan doc "Cause B" and the
  # note atop this function). A dns entry surfaced by this source is
  # therefore skipped downstream with a "no team template matches" warning,
  # exactly like any other id this box has no template for — never silently
  # dropped, never guessed at.
  local _tp_reg_file="${AITEAMFORGE_CONFIG:-${HOME}/.aiteamforge/team-paths.json}"
  local _tp_instances=""
  if [ -f "$_tp_reg_file" ] && command -v python3 >/dev/null 2>&1; then
    _tp_instances="$(python3 - "$_tp_reg_file" <<'PYEOF' 2>/dev/null || true
import json, os, sys

out = []
try:
    with open(sys.argv[1]) as fh:
        cfg = json.load(fh)
    teams = cfg.get("teams", {}) or {}
    if isinstance(teams, dict):
        for instance_id, entry in teams.items():
            if not isinstance(entry, dict):
                continue
            wd = entry.get("working_dir")
            if not wd or not isinstance(wd, str):
                continue
            if not os.path.isdir(wd):
                continue
            # XACA-0862-021: working_dir isdir() alone is satisfiable by a
            # never-installed team whose CATALOG-DEFAULT path coincidentally
            # exists (see the comment block above this source) — require
            # kanban_dir to ALSO exist as a real directory. A genuine install
            # always mkdir -p s it before team-paths.json is ever written; a
            # bare coincidental working_dir essentially never already
            # contains one.
            kd = entry.get("kanban_dir")
            if not kd or not isinstance(kd, str):
                continue
            if not os.path.isdir(kd):
                continue
            out.append(str(instance_id))
except Exception:
    pass

for i in out:
    if i:
        print(i)
PYEOF
)"
  fi

  if [ -n "$_tp_instances" ]; then
    work_list="${work_list}${_tp_instances}"$'\n'
  fi

  # De-duplicate, preserving first-seen order, and drop blank lines.
  work_list="$(printf '%s' "$work_list" | awk 'NF && !seen[$0]++')"

  # Iterate line-by-line (XACA-0845-012). `for instance_id in $work_list` was an
  # UNQUOTED expansion: subject to word splitting AND pathname expansion, so an
  # instance id containing a glob metacharacter would have been silently
  # replaced by matching filenames from the caller cwd (or, with no match,
  # passed through as a literal glob). A here-string keeps the loop body in the
  # CURRENT shell, so `updated`/`failed`/`skipped` still accumulate — a pipe
  # into `while` would run the body in a subshell and lose every count.
  while IFS= read -r instance_id; do
    # `<<<` on an empty work_list still yields one empty line.
    [ -n "$instance_id" ] || continue

    # Validate the recovered instance against the shipped templates using
    # ANCHORED shapes only: "<team>" exactly, or "<team>-<rest>". Longest
    # match wins, so a dash-bearing template id beats a shorter template that
    # shares its first component.
    #
    # XACA-0862-016: `base` (the on-disk connect-script filename) cannot be
    # computed from `instance_id` alone — since XACA-0862 the rendered file
    # is TEAM-scoped ("<best_team>-connect.sh"), not instance-scoped, so for
    # any parameterised instance (e.g. "legal-coparenting") the old
    # `"${instance_id}-connect.sh"` named a file ("legal-coparenting-connect.sh")
    # that is never written. That stale name fed both the skip warnings below
    # (naming a nonexistent file) AND the existence check further down, which
    # therefore NEVER found the real team-scoped file and permanently reported
    # "Creating missing" for every parametric instance, even a pure refresh.
    # The skip messages below (before best_team is known) now name the
    # recovered `instance_id` directly instead of guessing a filename; `base`
    # itself is computed AFTER best_team is resolved, from best_team — the
    # only value that actually determines the rendered filename.
    best_team=""
    best_conf=""
    for conf in "$teams_conf_dir"/*.conf; do
      [ -f "$conf" ] || continue
      team_id="$(basename "$conf" .conf)"
      if [ "$instance_id" = "$team_id" ] || [ "${instance_id#"${team_id}-"}" != "$instance_id" ]; then
        if [ "${#team_id}" -gt "${#best_team}" ]; then
          best_team="$team_id"
          best_conf="$conf"
        fi
      fi
    done

    if [ -z "$best_team" ]; then
      if _xaca0862_020_is_known_scoped_out "$instance_id"; then
        print_info "Skipping — no team template matches instance '${instance_id}' (known scoped-out id, not counted as a warning)"
      else
        print_warning "Skipping — no team template matches instance '${instance_id}'"
        skipped=$((skipped + 1))
      fi
      continue
    fi

    # Team-scoped filename (XACA-0862): the installer renders exactly one
    # "<best_team>-connect.sh" per team, never a per-instance file. Compute it
    # from best_team, not instance_id, so both the remaining skip messages and
    # the existence check below name/check the file that will actually exist.
    base="${best_team}-connect.sh"

    # Split the remainder into client/project according to the template's own
    # parameterisation, mirroring compute_instance_id(). Components never
    # contain a dash, so these splits are unambiguous.
    flags="$(_connect_script_team_flags "$best_conf")"
    has_projects="${flags%%|*}"
    requires_client="${flags##*|}"
    remainder="${instance_id#"$best_team"}"
    remainder="${remainder#-}"

    client=""
    project=""
    if [ "$has_projects" = "true" ]; then
      if [ -z "$remainder" ]; then
        print_warning "Skipping instance '${instance_id}' — template '${best_team}' is parameterised but instance carries no project component"
        skipped=$((skipped + 1))
        continue
      fi
      if [ "$requires_client" = "true" ]; then
        client="${remainder%%-*}"
        project="${remainder#*-}"
        if [ -z "$client" ] || [ -z "$project" ] || [ "$client" = "$remainder" ] || [ "$project" != "${project#*-}" ]; then
          print_warning "Skipping instance '${instance_id}' — cannot split '${remainder}' into <client>-<project> for template '${best_team}'"
          skipped=$((skipped + 1))
          continue
        fi
      else
        project="$remainder"
        if [ "$project" != "${project#*-}" ]; then
          print_warning "Skipping instance '${instance_id}' — project component '${project}' for template '${best_team}' contains a dash"
          skipped=$((skipped + 1))
          continue
        fi
      fi
    elif [ -n "$remainder" ]; then
      print_warning "Skipping instance '${instance_id}' — template '${best_team}' takes no parameters but instance carries suffix '${remainder}'"
      skipped=$((skipped + 1))
      continue
    fi

    # Re-render EXACTLY the instance that exists on disk — never a guessed one.
    install_args=( "$best_team" )
    if [ -n "$client" ]; then
      install_args+=( --client "$client" )
    fi
    if [ -n "$project" ]; then
      install_args+=( --project "$project" )
    fi
    install_args+=( --connect-only --install-dir "${WORKING_DIR}" )

    # XACA-0845: distinguish create from refresh in the output, so a box
    # recovering a missing cockpit script says so rather than silently
    # reporting a "refresh" of a file that did not exist.
    local _action="Refreshing" _action_done="Refreshed"
    if [ ! -f "${WORKING_DIR}/${base}" ]; then
      _action="Creating missing"
      _action_done="Created missing"
    fi

    if [ "$DRY_RUN" = true ]; then
      echo "Would render ${instance_id} connect/disconnect scripts (template ${best_team}, $(printf '%s' "$_action" | tr '[:upper:]' '[:lower:]'))"
      updated=$((updated + 1))
      continue
    fi

    print_info "${_action} ${instance_id} connect/disconnect scripts..."
    # `</dev/null` is REQUIRED, not cosmetic (XACA-0845-012). The loop now reads
    # the work list from a here-string on stdin, and a child that reads stdin
    # would swallow the remaining instance ids — install-team.sh can prompt
    # (_ensure_org_config) before its --connect-only early exit, so one
    # unattended upgrade could silently process only the first instance.
    if ( AITEAMFORGE_DIR="${WORKING_DIR}" bash "$installer" "${install_args[@]}" </dev/null 2>&1 | sed 's/^/    /' ); then
      print_success "${_action_done} ${instance_id} connect/disconnect scripts"
      updated=$((updated + 1))
    else
      print_warning "Failed to render ${instance_id} connect/disconnect scripts (continuing)"
      failed=$((failed + 1))
    fi
  done <<< "$work_list"

  if [ $((updated + failed)) -eq 0 ]; then
    print_success "No installed team connect scripts to refresh"
  elif [ "$DRY_RUN" = true ]; then
    print_success "Would render ${updated} team connect/disconnect script set(s)"
  elif [ "$failed" -gt 0 ]; then
    print_warning "Rendered ${updated} team connect/disconnect script set(s); ${failed} failed (non-fatal)"
  else
    print_success "Rendered ${updated} team connect/disconnect script set(s)"
  fi
  if [ "$skipped" -gt 0 ]; then
    print_warning "Skipped ${skipped} unrecognised connect-script instance(s) (non-fatal)"
  fi
  return 0
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
# XACA-0673: Mandatory shared modules that other ALREADY-INSTALLED cockpit
# scripts import/source. update_runtime_helpers MUST materialise these on upgrade
# even when the working-dir target is ABSENT — otherwise a machine that upgrades
# ACROSS the release introducing the dependency gets the importer but never the
# module, breaking the cockpit. Originating incident: iterm2_venv_bootstrap.py
# (added by XACA-0652, imported by iterm-browser.py / iterm2_window_manager.py /
# iterm2_tab_title_prefix.py). The absent-target skip below left upgraded M4Mini
# machines with the refreshed `import iterm2_venv_bootstrap` line in
# iterm-browser.py but no module on disk, so `import iterm2` failed and the LCARS
# web tab never created.
#
# Keep this set MINIMAL: only genuine always-required shared deps that (a) ship in
# share/scripts/ and (b) are imported/sourced by another shipped script. The
# XACA-0673 parity test auto-detects sibling Python imports and FAILS if a newly
# shipped imported module is missing from this set — so it cannot silently drift.
# Newline-delimited basenames; exact-line membership test.
# XACA-0698: kb-init-team and its guard are now installed for ALL teams (not just
# parametric ones) via install_kb_init_team_scripts() in install-kanban.sh. Add both
# to the mandatory materialize set so boxes UPGRADED across this release also get them;
# without this, the install-side fix creates an asymmetry where fresh installs work but
# pre-existing upgraded boxes stay broken. The XACA-0673 parity gate only checks Python
# sibling-imports, so adding shell scripts here does not affect that gate.
# XACA-0774: remote-tmux-attach.sh is a BRAND-NEW file referenced (as a LOCAL
# client-side path) by the rendered *-connect.sh scripts. It already carries the
# .sh extension, so update_runtime_helpers' self-maintaining *.sh glob sweep
# refreshes it automatically once present — no _xaca0608_aux_script_map entry
# needed (that map is only for basenames the glob does NOT already cover, e.g.
# the extensionless kb-port-reconcile). But since this is a NEW file, existing
# installs have no target on disk yet, and the sweep's default rule is "only
# refresh what's already there" — so it needs the same materialize-when-absent
# treatment as kb-init-team-guard.sh above, or upgraded machines never get it.
# XACA-0775: lcars-launch-helpers.sh defines has_iterm_gui, which the rendered
# *-connect.sh scripts now CALL (the probe used to be inlined in the template).
# It reaches a machine three ways, and only two of them are covered without this
# entry: aiteamforge-setup.sh copies share/scripts/* unconditionally, so both
# `setup` call sites of `install-team.sh --connect-only` are fine. The THIRD call
# site is update_connect_scripts() in this file (XACA-0814), reached from
# `aiteamforge upgrade` — which does NOT run setup's copy step. Without this
# entry the sweep's default "only refresh what's already there" rule applies, so
# an upgrade can hand a machine a freshly-rendered connect script that depends on
# a helper the same run declined to create. The failure is quiet rather than
# fatal (has_iterm_gui resolves to command-not-found, the `if` takes its else
# branch, and connect completes via the Terminal.app fallback) — it just reports
# "iTerm2 not running" on a machine where iTerm2 is running. Materialising here
# rather than special-casing the connect-only block also covers team-startup.sh,
# which has hard-depended on this same file since XACA-0563.
_xaca0673_mandatory_materialize_basenames() {
  cat <<'EOF'
iterm2_venv_bootstrap.py
kb-init-team-guard.sh
kb-init-team
remote-tmux-attach.sh
lcars-launch-helpers.sh
EOF
}

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

    # Refresh only what this machine already installed under scripts/ — EXCEPT
    # mandatory shared modules, which must be materialised even when absent
    # (XACA-0673; see _xaca0673_mandatory_materialize_basenames above).
    if [ ! -f "$target" ]; then
      case $'\n'"$(_xaca0673_mandatory_materialize_basenames)"$'\n' in
        *$'\n'"${name}"$'\n'*) : ;;   # mandatory shared module — materialise it
        *) continue ;;                 # optional/layout-specific — skip if absent
      esac
    fi

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

  # XACA-0677: Refresh the root-level iterm2_window_manager.py copy.
  # open_lcars_tab (lcars-launch-helpers.sh) invokes ${WORKING_DIR}/iterm2_window_manager.py
  # directly — NOT the scripts/ copy. install_iterm2_window_manager() lays this down via plain
  # cp (no path rewrite; the file self-locates at runtime via os.path.dirname(__file__)).
  # update_runtime_helpers' scripts/ sweep above never touches the root copy, leaving upgraded
  # boxes running a stale iterm2_window_manager.py (e.g. missing the XACA-0652 bootstrap).
  # Convention (XACA-0673 pattern): refresh ONLY if the root copy already exists on disk.
  # Boxes that never installed it keep it absent; a fresh install lays it down correctly.
  local root_wm_src="${FRAMEWORK_DIR}/share/scripts/iterm2_window_manager.py"
  local root_wm_dest="${WORKING_DIR}/iterm2_window_manager.py"
  if [ -f "$root_wm_dest" ] && [ -f "$root_wm_src" ]; then
    print_info "Updating iterm2_window_manager.py (root copy)..."
    if [ "$DRY_RUN" = false ]; then
      cp "$root_wm_src" "$root_wm_dest"
      chmod +x "$root_wm_dest"
      print_success "Updated iterm2_window_manager.py (root copy)"
    else
      echo "Would update: iterm2_window_manager.py (root copy)"
    fi
  fi

  # XACA-0610: Refresh the OPERATIVE fleet-monitor/client/fleet-reporter.sh copy.
  # fleet-reporter.sh ships to TWO destinations at install time: a decorative
  # helper copy at ${WORKING_DIR}/scripts/fleet-reporter.sh (via install-shell.sh,
  # covered by the scripts/ sweep above) and the OPERATIVE copy at
  # ${WORKING_DIR}/fleet-monitor/client/fleet-reporter.sh (via
  # install-fleet-monitor.sh) — it is this second, separate-destination copy that
  # the com.aiteamforge.fleet-reporter launchd job actually executes. Because the
  # scripts/ sweep above only walks ${WORKING_DIR}/scripts/, it never reaches
  # fleet-monitor/client/, leaving upgraded boxes running a permanently frozen
  # reporter. Same defect class as XACA-0677's root-level iterm2_window_manager.py.
  # Convention (XACA-0673 pattern): refresh ONLY if the operative copy already
  # exists on disk — machines that opted out of fleet monitoring (XACA-0673)
  # never had it laid down and must not have it materialised here.
  local fr_src="${FRAMEWORK_DIR}/share/scripts/fleet-reporter.sh"
  local fr_dest="${WORKING_DIR}/fleet-monitor/client/fleet-reporter.sh"
  if [ -f "$fr_dest" ] && [ -f "$fr_src" ]; then
    print_info "Updating fleet-monitor/client/fleet-reporter.sh (operative copy)..."
    if [ "$DRY_RUN" = false ]; then
      cp "$fr_src" "$fr_dest"
      chmod +x "$fr_dest"
      print_success "Updated fleet-monitor/client/fleet-reporter.sh (operative copy)"
    else
      echo "Would update: fleet-monitor/client/fleet-reporter.sh (operative copy)"
    fi
  fi
}

# XACA-0771: Mandatory shared alias files. install_aliases() (install-shell.sh)
# lays down all three of these unconditionally on every fresh install — there
# is no "optional alias file" today. Kept as its own function (mirrors the
# XACA-0673 _xaca0673_mandatory_materialize_basenames pattern) so a FUTURE
# optional/layout-specific alias file can opt out without touching the
# create-vs-skip branching in update_shell_helpers' alias loop below.
# Newline-delimited basenames; exact-line membership test.
_xaca0771_mandatory_alias_basenames() {
  cat <<'EOF'
agent-aliases.sh
cc-aliases.sh
worktree-aliases.sh
EOF
}

# Update shell helpers
update_shell_helpers() {
  print_section "Updating Shell Helpers"

  local updated=0

  # Resolve the homebrew tap share directory (under FRAMEWORK_DIR)
  local tap_share
  tap_share="${FRAMEWORK_DIR}/share"

  # Update kanban-helpers.sh (root of WORKING_DIR).
  # XACA-0649 / Finding 2: mirror install_kanban_helpers' source preference —
  #   prefer kanban-aliases.sh (the standalone, tap-tested copy that fresh installs
  #   use); fall back to kanban-helpers.template.sh if the aliases file is absent.
  # Both files carry the same three-tier _kb_get_kanban_dir fix after XACA-0649.
  # Keeping upgrade in sync with install prevents a future edit to kanban-aliases.sh
  # from silently diverging from what upgrade ships.
  local kanban_aliases_template="${tap_share}/templates/aliases/kanban-aliases.sh"
  local kanban_template="${tap_share}/templates/kanban/kanban-helpers.template.sh"
  local _kanban_src=""
  if [ -f "$kanban_aliases_template" ]; then
    _kanban_src="$kanban_aliases_template"
  elif [ -f "$kanban_template" ]; then
    _kanban_src="$kanban_template"
  fi
  local kanban_target="${WORKING_DIR}/kanban-helpers.sh"
  if [ -n "$_kanban_src" ] && [ -f "$kanban_target" ]; then
    if [ "$_kanban_src" -nt "$kanban_target" ] || [ "$FORCE" = true ]; then
      print_info "Updating kanban-helpers.sh (from $(basename "$_kanban_src"))..."
      if [ "$DRY_RUN" = false ]; then
        sed -e "s|{{AITEAMFORGE_DIR}}|${WORKING_DIR}|g" \
            -e "s|{{SHARED_DEV_ROOT}}|${SHARED_DEV_ROOT:-/Users/Shared/Development}|g" \
            -e "s|{{ORG_NAME}}|${ORG_NAME:-}|g" \
            "$_kanban_src" > "$kanban_target"
        print_success "Updated kanban-helpers.sh"
        updated=$((updated + 1))
      else
        echo "Would update: kanban-helpers.sh (from $(basename "$_kanban_src"))"
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
      # XACA-0771: the target is missing. Prior behavior was an unconditional
      # `continue` here — upgrade NEVER created a missing alias file, only
      # refreshed one that already existed. That stranded any box whose
      # share/aliases/cc-aliases.sh was never laid down (pre-XACA-0494 install)
      # or got deleted: cc-aliases.sh defines the `cc` alias that redirects the
      # bare `cc` command away from /usr/bin/cc (clang) — without it, `cc`
      # silently falls through to clang and the box never notices until a
      # script assuming the alias breaks. Only the MANDATORY set (see
      # _xaca0771_mandatory_alias_basenames above) is created from absent; a
      # future non-mandatory/layout-specific alias file still opts out via
      # `continue`, matching the update_runtime_helpers XACA-0673 convention.
      case $'\n'"$(_xaca0771_mandatory_alias_basenames)"$'\n' in
        *$'\n'"${alias_file}"$'\n'*) : ;;   # mandatory — materialize it
        *) continue ;;                       # optional — skip if absent
      esac

      print_info "Creating share/aliases/${alias_file} (was missing)..."
      if [ "$DRY_RUN" = false ]; then
        mkdir -p "$aliases_dir"
        sed -e "s|{{AITEAMFORGE_DIR}}|${WORKING_DIR}|g" "$source" > "$target"
        chmod +x "$target" 2>/dev/null || true
        print_success "Created share/aliases/${alias_file}"
        updated=$((updated + 1))
      else
        echo "Would create: share/aliases/${alias_file} (was missing)"
        updated=$((updated + 1))
      fi
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

  # XACA-0771: assert-present — verify every mandatory alias file actually
  # exists on disk after the create/refresh loop above. This is a loud warning,
  # not a hard failure (mirrors the fail-soft stance of update_knowledge_repo /
  # update_knowledge_sync): a still-missing file here means the shipped
  # template itself was absent from this Cellar payload (the `[ ! -f "$source"
  # ] && continue` guard above would otherwise let that pass silently).
  # Skipped under --dry-run, since nothing was actually materialized to check.
  if [ "$DRY_RUN" = false ]; then
    local _mandatory_alias
    for _mandatory_alias in $(_xaca0771_mandatory_alias_basenames); do
      if [ ! -f "${aliases_dir}/${_mandatory_alias}" ]; then
        print_warning "Mandatory alias file still missing after upgrade: ${aliases_dir}/${_mandatory_alias}"
      fi
    done
  fi

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

# XACA-0771: Mandatory ~/.claude/hooks files, relative to ${CLAUDE_CONFIG_DIR}/hooks/.
# Kept as its own function (mirrors _xaca0673_mandatory_materialize_basenames /
# _xaca0771_mandatory_alias_basenames) so update_claude_hooks' assert-present
# check has a single source of truth for "which hook files must exist". This
# set intentionally EXCLUDES damage-control/README.md and the
# damage-control/test-*.py files: install_hooks() (install-claude-config.sh)
# copies every file under templates/claude/hooks/damage-control/ verbatim
# (docs and tests included — that behavior is unchanged by this ticket), but
# only the three *-damage-control.py scripts and block-icloud-paths.py /
# inject-time-context.sh are actually WIRED as hooks in settings.json.template
# — those are the files whose absence breaks a live hook, so those are the
# ones worth a loud warning if still missing after materialize.
_xaca0771_mandatory_hook_basenames() {
  cat <<'EOF'
inject-time-context.sh
block-icloud-paths.py
damage-control/bash-tool-damage-control.py
damage-control/edit-tool-damage-control.py
damage-control/write-tool-damage-control.py
EOF
}

# XACA-0771: ~/.claude/hooks materialization on the UPGRADE path.
#
# install_hooks() (libexec/installers/install-claude-config.sh) lays down the
# mandatory hook files (damage-control/*, block-icloud-paths.py, and — after
# this same ticket's install-side fix — inject-time-context.sh) into
# ${CLAUDE_CONFIG_DIR}/hooks/. Its ONLY call site was install_claude_config(),
# reached from aiteamforge-setup.sh on a FRESH INSTALL. `aiteamforge upgrade`
# had NO function that ever touched ~/.claude/hooks — same bug class as
# XACA-0751 (update_knowledge_repo) / XACA-0761 (update_knowledge_sync):
# install-time-only provisioning the upgrade path never learned about.
# Confirmed root cause: settings.json.template wires
# {{CLAUDE_CONFIG_DIR}}/hooks/inject-time-context.sh as a UserPromptSubmit
# hook, so a box whose hooks/ directory predates that file (or lost it) runs
# with time-context injection silently broken, and `aiteamforge upgrade` never
# re-materialized it.
#
# We REUSE install_hooks() verbatim (same idiom as update_knowledge_repo /
# update_knowledge_sync reusing their installer counterparts) instead of
# re-implementing the copy+chmod+template-substitution logic here. install_hooks
# already: creates ${hooks_dir} and damage-control/ if absent, copies every
# damage-control/* file (this ticket does not change what damage-control/
# ships), skips a target only when it exists AND is read-only (never silently
# clobbers a locked-down file), and applies {{...}} template substitution to
# any *.sh/*.py under hooks_dir afterward. Because install_hooks unconditionally
# cp's rather than "only if missing", calling it here BOTH creates missing
# mandatory files (the defect this ticket fixes) AND refreshes already-present
# ones with the latest shipped content — the same "materialize-if-missing,
# refresh-if-present" contract XACA-0673 established for update_runtime_helpers.
#
# Runs in a SUBSHELL for the identical two reasons update_knowledge_repo /
# update_knowledge_sync document: (1) install-claude-config.sh opens with
# `set -euo pipefail`; sourcing it in-process would leak `set -u` into this
# `set -eo` (no -u) upgrade script and abort on the next unset variable, and
# (2) fail-soft — the nightly auto-upgrade LaunchAgent runs unattended, so a
# sourcing error or unexpected non-zero exit must never abort the parent
# upgrade.
#
# AITEAMFORGE_DIR / TEMPLATE_DIR are neither read from nor exported by the
# rest of this script, so — like update_knowledge_sync's AITEAMFORGE_DIR /
# INSTALL_ROOT — they are set explicitly inside the subshell from this
# script's own WORKING_DIR / FRAMEWORK_DIR before sourcing. CLAUDE_CONFIG_DIR
# is deliberately NOT set here: install-claude-config.sh's own top-of-file
# precedence (XACA-0773) honors a caller/test-exported CLAUDE_CONFIG_DIR
# override verbatim (the sandbox/test seam), and otherwise falls back to the
# real $HOME/.claude — exactly what production `aiteamforge upgrade` needs.
# Do NOT call install_claude_config() (the full installer entrypoint) — that
# would also touch settings.json, skills, personas, tmux.conf, etc. This
# function's job is ONLY the hook files.
update_claude_hooks() {
  print_section "Updating Claude Code Hooks"

  local installer="${LIBEXEC_DIR}/installers/install-claude-config.sh"
  if [ ! -f "$installer" ]; then
    print_warning "install-claude-config.sh not found ($installer) — skipping Claude Code hooks refresh"
    return 0
  fi

  if [ "$DRY_RUN" = true ]; then
    echo "Would ensure ~/.claude/hooks/{inject-time-context.sh,block-icloud-paths.py,damage-control/*} are present and current"
    return 0
  fi

  print_info "Ensuring Claude Code hooks are present and current (idempotent; fail-soft)..."

  # Subshell isolates install-claude-config.sh's `set -u` (see rationale
  # above); AITEAMFORGE_DIR / TEMPLATE_DIR are set here — not exported — so
  # they apply only inside this subshell and never leak into the rest of the
  # upgrade run. Any caller/test-exported CLAUDE_CONFIG_DIR is inherited
  # unchanged (subshells inherit the parent's exported environment).
  if (
      AITEAMFORGE_DIR="${WORKING_DIR}"
      TEMPLATE_DIR="${FRAMEWORK_DIR}/share/templates"
      export AITEAMFORGE_DIR TEMPLATE_DIR
      # shellcheck source=/dev/null
      source "$installer" >/dev/null 2>&1
      install_hooks
    ); then
    print_success "Claude Code hooks check complete"
  else
    print_warning "Claude Code hooks refresh skipped (non-fatal; upgrade continues)"
  fi

  # XACA-0771: assert-present — verify every mandatory hook file actually
  # exists on disk after the materialize attempt above. Loud warning, not a
  # hard failure (same fail-soft stance as the rest of this function): a
  # still-missing file here means the subshell above errored partway through,
  # or the shipped template itself was absent from this Cellar payload. This
  # mirrors install-claude-config.sh's own CLAUDE_CONFIG_DIR precedence
  # (XACA-0773) exactly, so the path checked here is the SAME path install_hooks
  # actually wrote to. Skipped under --dry-run (nothing was materialized).
  local _assert_config_dir
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    _assert_config_dir="$CLAUDE_CONFIG_DIR"
  elif [ "${CLAUDE_SANDBOX:-0}" = "1" ]; then
    _assert_config_dir="${WORKING_DIR}/.claude-staging"
  else
    _assert_config_dir="$HOME/.claude"
  fi
  local _hooks_check_dir="${_assert_config_dir}/hooks"
  local _mandatory_hook
  for _mandatory_hook in $(_xaca0771_mandatory_hook_basenames); do
    if [ ! -f "${_hooks_check_dir}/${_mandatory_hook}" ]; then
      print_warning "Mandatory Claude Code hook still missing after refresh: ${_hooks_check_dir}/${_mandatory_hook}"
    fi
  done

  return 0
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

# NOTE (XACA-0734): _render_launchagent_template used to live here. It now lives in
# libexec/lib/launchagents.sh (sourced at the top of this file) because `aiteamforge
# doctor --fix` needed the same renderer and would have become a FOURTH copy of this
# logic. The agent→template map and the mandatory/opt-out vocabulary moved with it.
# Add a new {{PLACEHOLDER}} in ONE place: the sed chain in lib/launchagents.sh.

# Update LaunchAgents
#
# XACA-0734 DECISION TABLE — what happens to each agent in the map:
#
#   plist on disk | in mandatory set | in optout sentinel | action
#   --------------|------------------|--------------------|--------------------------
#   present       | —                | —                  | refresh   (unchanged)
#   absent        | yes              | no                 | RENDER + LOAD  ← the fix
#   absent        | yes              | yes                | skip (respect recorded intent)
#   absent        | no               | —                  | skip (unchanged)
#
# The old code had a single `[ ! -f "$target" ] && continue` guard, which collapsed
# rows 2 and 3 into "skip" and thereby made every NET-NEW mandatory LaunchAgent
# permanently unreachable on every already-installed box. See lib/launchagents.sh
# for the full incident write-up (M1Pro could never auto-upgrade because it was
# missing the very agent that performs upgrades).
#
# Under --dry-run nothing is materialized; a would-be install prints "Would install".
#
# Row 2 (the materialize path — both --dry-run and real) always prints the
# opt-out escape hatch right after "Would install"/"Installing", via
# _xaca0734_print_optout_hint. That is the discoverability mechanism for row 3
# — there is deliberately NO new CLI subcommand for opting out; the sentinel is
# a plain user-editable file (see lib/launchagents.sh) and this is where a user
# learns it exists, at the exact moment it becomes relevant. Row 1 (routine
# refresh of an agent already installed) does NOT print the hint — that would
# be noise on every upgrade for agents nobody is trying to remove.
update_launchagents() {
  print_section "Updating LaunchAgents"

  # Allow tests to inject a sandbox path instead of the real LaunchAgents dir.
  local launchagents_dir="${LAUNCHAGENTS_DIR:-$HOME/Library/LaunchAgents}"

  local updated=0
  # Reset module-level tempfile tracker; RETURN trap cleans up any survivors.
  _upgrade_tmpfiles=()
  trap '_cleanup_upgrade_tmpfiles' RETURN

  # XACA-0734 applicability gate. Some installs RECORD, at setup time, that they
  # deliberately have no LaunchAgents — cockpit boxes (LCARS/kanban live on a
  # remote host) and boxes where the user declined LCARS Kanban. Materializing
  # the mandatory set on those is not self-healing, it is vandalism: two of the
  # three agents point at ${WORKING_DIR}/lcars-ui and the kanban backup script,
  # which do not exist there, so they would become recurring FAILING launchd jobs.
  #
  # Computed ONCE, outside the loop: a closed gate is a property of the INSTALL,
  # not of any individual agent, so it is reported once rather than three times.
  # See _xaca0734_launchagents_applicable in lib/launchagents.sh for why the
  # markers are read rather than a sentinel written.
  local la_applicable=true
  if ! _xaca0734_launchagents_applicable; then
    la_applicable=false
    print_info "No mandatory LaunchAgents on this install — $(_xaca0734_launchagents_skip_reason)"
    print_info "Existing LaunchAgents (if any) are still refreshed; absent ones are left absent."
  fi

  # Agent→template pairs come from the shared map (lib/launchagents.sh) so
  # upgrade and doctor cannot drift apart. Order is the map's order.
  local entry
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue

    local agent="${entry%%:*}"
    local tmpl_subpath="${entry##*:}"
    local template="${FRAMEWORK_DIR}/share/templates/${tmpl_subpath}"
    local target="${launchagents_dir}/${agent}"
    local tmpfile="${target}.new"
    _upgrade_tmpfiles+=("$tmpfile")

    # is_new drives the messaging (Installing vs Updating) and the post-load
    # registration verification below. The render/diff/replace machinery is
    # shared between both paths.
    local is_new=false

    if [ ! -f "$target" ]; then
      # Absent plist. Absence is NOT intent — consult the recorded opt-out
      # sentinel instead of inferring from disk state (this is the whole point
      # of XACA-0734).
      if ! _xaca0734_is_mandatory "$agent"; then
        # Row 4: optional agent, never installed here → leave it alone.
        continue
      fi
      if [ "$la_applicable" = false ]; then
        # Row 2a (XACA-0734 review, BLOCKING 1): this install is RECORDED as
        # having no LaunchAgents at all (cockpit / kanban declined). The agent is
        # SUPPOSED to be absent. Reported once above the loop, so stay quiet here.
        continue
      fi
      if _xaca0734_is_opted_out "$agent"; then
        # Row 3: the user's own uninstall recorded this. Respect it.
        print_info "Skipping ${agent} — opted out ($(_xaca0734_optout_file))"
        continue
      fi
      # Row 2: mandatory, absent, no recorded opt-out → materialize it.
      is_new=true

      # Under --dry-run, short-circuit BEFORE any filesystem effect. There is
      # nothing to diff (the target does not exist — it would simply be created),
      # so skipping here means dry-run creates no tempfile and no LaunchAgents dir.
      if [ "$DRY_RUN" = true ]; then
        echo "Would install: ${agent}"
        _xaca0734_print_optout_hint "$agent"
        updated=$((updated + 1))
        continue
      fi

      mkdir -p "$launchagents_dir"
    fi

    # Template missing: report without aborting the whole upgrade run.
    if ! _render_launchagent_template "$template" "$tmpfile"; then
      continue
    fi

    # Diff rendered output against live target (not the raw template, which
    # always looks different due to {{VAR}} placeholders). A missing target
    # makes diff fail, which correctly routes a new agent into the write path.
    if ! diff -q "$tmpfile" "$target" &>/dev/null || [ "$FORCE" = true ]; then
      if [ "$is_new" = true ]; then
        print_info "Installing ${agent} (mandatory, was missing)..."
        _xaca0734_print_optout_hint "$agent"
      else
        print_info "Updating ${agent}..."
      fi

      if [ "$DRY_RUN" = false ]; then
        # Unload current agent (ignore failure — may not be loaded)
        _aitf_launchctl unload "$target" 2>/dev/null || true

        # Atomically replace with rendered version
        mv "$tmpfile" "$target"

        # Reload agent (ignore failure — may need user session context)
        _aitf_launchctl load "$target" 2>/dev/null || true

        if [ "$is_new" = true ]; then
          # XACA-0651-009 load-verify: `launchctl load` returns 0 even when the
          # job is REJECTED, so confirm registration rather than trust the exit
          # code. Only warn — a plist on disk that did not register is still an
          # improvement over no plist at all, and the next login will load it.
          local label="${agent%.plist}"
          if _xaca0734_launchctl_is_loaded "$label"; then
            print_success "Installed and loaded ${agent}"
          else
            print_warning "Installed ${agent} but it did not register — activate with: launchctl load ${target}"
          fi
        else
          print_success "Updated ${agent}"
        fi
        updated=$((updated + 1))
      else
        # Only reachable for an EXISTING target whose content changed — a
        # would-be install already short-circuited above with "Would install".
        echo "Would update: ${agent}"
        rm -f "$tmpfile"
        updated=$((updated + 1))
      fi
    else
      # No change — clean up tempfile, count as no-op
      rm -f "$tmpfile"
    fi
  done <<EOF
$(_xaca0734_launchagent_map)
EOF

  # XACA-0734 assert-present: verify every mandatory agent actually exists on
  # disk after the loop. Mirrors the XACA-0771 alias-file assert — a LOUD warning,
  # never fatal, because a still-missing plist here means the shipped TEMPLATE was
  # absent from this Cellar payload (the `_render_launchagent_template` failure
  # above only prints a warning and continues, which would otherwise pass silently).
  # Opted-out agents are expected to be missing and are not flagged.
  # Skipped under --dry-run, since nothing was actually materialized to check.
  #
  # Also skipped when the applicability gate is closed (XACA-0734 review): on a
  # cockpit / kanban-declined box every mandatory agent is missing BY DESIGN, and
  # warning three times per upgrade about the correct state is exactly the kind of
  # false alarm that teaches people to ignore warnings.
  if [ "$DRY_RUN" = false ] && [ "$la_applicable" = true ]; then
    local _mandatory_agent
    for _mandatory_agent in $(_xaca0734_mandatory_launchagent_basenames); do
      if _xaca0734_is_opted_out "$_mandatory_agent"; then
        continue
      fi
      if [ ! -f "${launchagents_dir}/${_mandatory_agent}" ]; then
        print_warning "Mandatory LaunchAgent still missing after upgrade: ${launchagents_dir}/${_mandatory_agent}"
      fi
    done
  fi

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
# loudly but do NOT abort the upgrade. A non-zero ensure_imgcat return is consumed
# by the `if ensure_imgcat ...; then ... else ... fi` construct below, so it never
# trips `set -e`/`set -eo pipefail` (no `|| true` is needed on the call).
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
update_knowledge_repo
update_knowledge_sync
update_aux_scripts
update_team_scripts
update_connect_scripts
update_runtime_helpers
update_imgcat
update_shell_helpers
update_claude_hooks
update_skills
update_launchagents
# XACA-0763-005: tear down the retired com.aiteamforge.lcars-runatload agent
# on any machine that still has it loaded from before the retirement. See
# remove_legacy_lcars_runatload_agent's header comment in libexec/lib/common.sh.
remove_legacy_lcars_runatload_agent "${LAUNCHAGENTS_DIR:-$HOME/Library/LaunchAgents}" "$DRY_RUN"

# XACA-0578: Stamp the installed version so `aiteamforge doctor` can detect
# Cellar-vs-working-dir drift if a user runs `brew upgrade aiteamforge` without
# chaining `aiteamforge upgrade --non-interactive`. The cellar-watch LaunchAgent
# normally handles this automatically, but the stamp is the diagnostic backstop.
# Skipped under --dry-run (stamp is a side-effect, not a preview).
#
# XACA-0702: the stamp must reflect the ACTUAL installed state, not blindly the
# framework VERSION. When brew is the install method, stamp the real
# `brew list --versions` token (UPGRADE_BREW_VERSION captured in check_brew_updates)
# — otherwise a no-op/refused brew upgrade would still stamp the NEW framework
# version, fooling `aiteamforge doctor`/`status` drift detection into thinking the
# box advanced when it is still on the old version. Only when brew is NOT the
# install method do we fall back to copying the framework VERSION file.
if [ "$DRY_RUN" = false ]; then
  if [ "$UPGRADE_VIA_BREW" = true ] && [ -n "$UPGRADE_BREW_VERSION" ] && [ -d "$WORKING_DIR" ]; then
    # Brew install method: stamp the real installed brew version.
    if printf '%s\n' "$UPGRADE_BREW_VERSION" > "$WORKING_DIR/.installed-version" 2>/dev/null; then
      print_info "Stamped working-dir version (brew): ${UPGRADE_BREW_VERSION}"
    fi
  else
    # Non-brew install method (or brew version unknown): fall back to the framework
    # VERSION file, preserving the original XACA-0578 behaviour.
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
elif [ "$UPGRADE_BREW_FAILED" = true ]; then
  # XACA-0702: the brew step never advanced (untrusted/refused tap, or a no-op
  # upgrade). The component sweeps above only refreshed files FROM the Cellar — if
  # the Cellar itself is on the old version, nothing actually changed. Report a
  # LOUD, boxed failure with the exact remediation and exit non-zero so callers
  # (auto-upgrade LaunchAgent, CI, a human) are not fooled by a false success.
  print_error "╔═══════════════════════════════════════════════════════════════╗"
  print_error "║                  UPGRADE FAILED — NOT UPGRADED                 ║"
  print_error "╚═══════════════════════════════════════════════════════════════╝"
  print_error "Homebrew did NOT advance the aiteamforge formula."
  print_error "This box is STILL on the OLD version: ${CURRENT_VERSION:-unknown}"
  echo ""
  print_error "Most common cause: the tap is UNTRUSTED on a trust-gated Homebrew,"
  print_error "so 'brew upgrade' silently no-ops while reporting success."
  echo ""
  print_error "Remediation:"
  echo "  brew trust --tap $(_aitf_tap_name)"
  echo "  brew upgrade aiteamforge"
  echo "  aiteamforge upgrade"
  echo ""
  print_error "Then re-run the health check: aiteamforge doctor"
  exit 1
else
  print_success "Dev-team has been upgraded successfully!"
  echo ""
  print_info "Next steps:"
  echo "  • Reload your shell: source ~/.zshrc"
  echo "  • Restart services: aiteamforge restart"
  echo "  • Run health check: aiteamforge doctor"
fi

exit 0
