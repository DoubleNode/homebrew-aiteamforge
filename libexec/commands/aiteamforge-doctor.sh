#!/bin/bash
# aiteamforge-doctor.sh
# Comprehensive health check and diagnostics for aiteamforge installation
# Verifies dependencies, configuration, services, and system health

set -eo pipefail

# Get framework location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIBEXEC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source shared libraries
source "${LIBEXEC_DIR}/lib/common.sh"
source "${LIBEXEC_DIR}/lib/config.sh"
source "${LIBEXEC_DIR}/lib/constants.sh"
# XACA-0734: shared LaunchAgent vocabulary — mandatory set, opt-out sentinel, and
# the render+load helper backing the `--fix` backstop in check_launchagents /
# _apply_remediation. Must come after common.sh (print_*/_aitf_launchctl) and
# config.sh (get_working_dir, used by the renderer to resolve {{AITEAMFORGE_DIR}}).
source "${LIBEXEC_DIR}/lib/launchagents.sh"
# XACA-0650: resolve tap-owned venv Python (sets AITEAMFORGE_PYTHON)
# shellcheck source=../lib/python-env.sh
[ -f "${LIBEXEC_DIR}/lib/python-env.sh" ] && source "${LIBEXEC_DIR}/lib/python-env.sh" 2>/dev/null || true
# XACA-0655: path resolvers for check_board_resolution — use the SAME resolver
# functions the runtime uses (kanban-dir resolution, org placeholder detection)
# rather than reinventing path logic. Both carry include-guards (idempotent).
# shellcheck source=../lib/aiteamforge-paths.sh
[ -f "${LIBEXEC_DIR}/lib/aiteamforge-paths.sh" ] && source "${LIBEXEC_DIR}/lib/aiteamforge-paths.sh" 2>/dev/null || true
# shellcheck source=../lib/kanban-paths.sh
[ -f "${LIBEXEC_DIR}/lib/kanban-paths.sh" ] && source "${LIBEXEC_DIR}/lib/kanban-paths.sh" 2>/dev/null || true

# Version — read from VERSION file (single source of truth)
_find_version() { for p in "${LIBEXEC_DIR}/../VERSION" "${LIBEXEC_DIR}/../../VERSION"; do [ -f "$p" ] && cat "$p" | tr -d '[:space:]' && return; done; echo "unknown"; }
VERSION="$(_find_version)"

# Counters
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0
WARNING_CHECKS=0

# Options
VERBOSE=false
FIX=false
CHECK_COMPONENT="all"
PREFLIGHT=false   # XACA-0655-004: first-launch fast/critical self-heal subset

# Usage
usage() {
  cat <<EOF
AITeamForge Doctor v${VERSION}
Comprehensive health check and diagnostics

Usage: aiteamforge doctor [options]

Options:
  --verbose              Show detailed diagnostic information
  --fix                  Attempt to fix common issues
  --check <component>    Check specific component only
  -v, --version          Show version
  -h, --help             Show this help

Components:
  dependencies    External dependencies (brew, node, python, etc.)
  tap-trust       Homebrew tap-trust gate (untrusted tap blocks upgrades) (XACA-0676)
  python-venv     Tap-owned Python venv + required packages + real import test (XACA-0650/0655)
  framework       Framework installation integrity
  version-drift   Cellar vs working-dir version drift (XACA-0578)
  config          Configuration files and validity
  board           Kanban board resolution + template/stub-collision detection (XACA-0655)
  connect         Cockpit connect scripts vs installed team instances (XACA-0845)
  services        Running services + LCARS server durability (XACA-0655)
  lcars-port-drift  LCARS server bound to a non-canonical port (XACA-0706/0613)
  lcars-python-runtime  LCARS python >=3.10 floor + launchd-context resolver + server.py 3.9-safety (XACA-0713)
  launchagents    LaunchAgent status
  git             Git repository health
  network         Network connectivity (Tailscale if configured)
  disk            Disk space for kanban backups
  all             Run all checks (default)

Examples:
  aiteamforge doctor                    # Run all health checks
  aiteamforge doctor --verbose          # Detailed diagnostics
  aiteamforge doctor --check services   # Check services only
  aiteamforge doctor --fix              # Auto-fix common issues

Exit Codes:
  0 - All checks passed
  1 - Warnings detected (system should work)
  2 - Failures detected (system may not work correctly)
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --verbose)
      VERBOSE=true
      shift
      ;;
    --fix)
      FIX=true
      shift
      ;;
    --check)
      CHECK_COMPONENT="$2"
      shift 2
      ;;
    --preflight)
      # XACA-0655-004: first-launch self-heal. Runs only the fast/critical
      # subset (venv+iterm2 import, board resolution, server durability),
      # auto-applies SAFE remediations SILENTLY, logs one line per action, and
      # never blocks. Implies --fix; output is summarized to a single line.
      PREFLIGHT=true
      FIX=true
      DOCTOR_QUIET=true
      shift
      ;;
    -v|--version)
      echo "AITeamForge Doctor v${VERSION}"
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

# Check result tracker
check_result() {
  local status=$1
  local message=$2
  local detail="${3:-}"

  TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

  case $status in
    pass)
      print_success "$message"
      PASSED_CHECKS=$((PASSED_CHECKS + 1))
      ;;
    fail)
      print_error "$message"
      FAILED_CHECKS=$((FAILED_CHECKS + 1))
      ;;
    warn)
      print_warning "$message"
      WARNING_CHECKS=$((WARNING_CHECKS + 1))
      ;;
  esac

  if [ "$VERBOSE" = true ] && [ -n "$detail" ]; then
    echo "    $detail"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Remediation dispatch (XACA-0655-003)
#
# attempt_remediation <issue-kind> [--apply]
#
# Single reusable remediation engine shared by `doctor --fix` AND the
# first-launch preflight self-heal (XACA-0655-004). Each issue-kind maps to a
# remediation classified SAFE (idempotent, auto-applicable) or RISKY (re-runs
# setup / rewrites config — print-only, NEVER auto-applied).
#
# Modes:
#   default (no --apply): PRINT the exact fix command, do not run it.
#   --apply             : auto-run SAFE remediations; still print-only for RISKY.
#
# Returns 0 if a remediation was applied or printed; 1 on unknown kind.
# Every applied action is logged to stdout (callers may redirect).
#
# issue-kinds:
#   venv        SAFE  — brew postinstall aiteamforge  (re-provision venv + deps)
#   keepalive   SAFE  — launchctl load lcars-health plist
#   server      SAFE  — aiteamforge start kanban
#   board|setup RISKY — print `aiteamforge setup` (rewrites config — never auto)
# ─────────────────────────────────────────────────────────────────────────────
REMEDIATION_LOG=""   # populated with one line per action taken/suggested
_remediation_note() {
  # Append a line to the in-memory remediation log AND echo it.
  local line="$1"
  REMEDIATION_LOG="${REMEDIATION_LOG}${line}"$'\n'
  echo "$line"
}

attempt_remediation() {
  local kind="$1"
  local apply=false
  [ "${2:-}" = "--apply" ] && apply=true

  case "$kind" in
    venv)
      # SAFE: idempotent — brew postinstall re-provisions the venv from
      # requirements.txt without touching user config.
      if [ "$apply" = true ]; then
        _remediation_note "[fix] venv: running 'brew postinstall aiteamforge'"
        if command -v brew >/dev/null 2>&1; then
          if brew postinstall aiteamforge >/dev/null 2>&1; then
            _remediation_note "[fix] venv: brew postinstall completed"
          else
            _remediation_note "[fix] venv: brew postinstall FAILED — run manually: brew postinstall aiteamforge"
          fi
        else
          _remediation_note "[fix] venv: brew not found — install Homebrew, then: brew postinstall aiteamforge"
        fi
      else
        _remediation_note "[suggest] venv: brew postinstall aiteamforge"
      fi
      ;;
    keepalive)
      # SAFE: idempotent — launchctl load is a no-op if already loaded, and the
      # render path below rewrites a plist from the shipped template.
      #
      # XACA-0734: this used to be load-only. When the plist was MISSING it just
      # printed "run: aiteamforge setup" and gave up — so a box that never had the
      # agent stayed broken, and `doctor --fix` (the thing you run precisely when
      # something is broken) could not fix it. Now --fix renders the plist from the
      # template and loads it, using the shared lib so this does not become a fourth
      # copy of the render logic.
      local _ka_agent="com.aiteamforge.lcars-health.plist"
      local _ka_dir="${LAUNCHAGENTS_DIR:-$HOME/Library/LaunchAgents}"
      local plist="${_ka_dir}/${_ka_agent}"
      if [ "$apply" = true ]; then
        if [ -f "$plist" ]; then
          _remediation_note "[fix] keepalive: launchctl load ${plist}"
          _aitf_launchctl load "$plist" >/dev/null 2>&1 || \
            _remediation_note "[fix] keepalive: launchctl load returned non-zero (may already be loaded)"
        elif ! _xaca0734_launchagents_applicable; then
          # XACA-0734 review, BLOCKING 1: this install RECORDED that it has no
          # LaunchAgents (cockpit / kanban declined). `--fix` must not "fix" a box
          # into a state it deliberately opted out of — on a cockpit box the
          # lcars-health agent would poll an LCARS server that runs on a DIFFERENT
          # machine, failing on every tick forever.
          _remediation_note "[info] keepalive: not applicable — $(_xaca0734_launchagents_skip_reason)"
        elif _xaca0734_is_opted_out "$_ka_agent"; then
          # Recorded opt-out — the user removed this on purpose. Absence is the
          # CORRECT state; report it as information, never as a failure to fix.
          _remediation_note "[info] keepalive: ${_ka_agent} is opted out ($(_xaca0734_optout_file)) — leaving it absent"
        else
          _remediation_note "[fix] keepalive: plist missing — rendering ${plist} from template"
          # XACA-0734: discoverability hint on the materialize path — mirrors
          # update_launchagents' identical hint in aiteamforge-upgrade.sh.
          _xaca0734_print_optout_hint "$_ka_agent"
          local _ka_framework
          _ka_framework="$(get_framework_dir)"
          if _xaca0734_render_and_load_launchagent "$_ka_agent" "$_ka_framework" "$_ka_dir"; then
            _remediation_note "[fix] keepalive: rendered and loaded ${_ka_agent}"
          elif [ -f "$plist" ]; then
            # Rendered, but launchd did not register it (load returns 0 even on
            # reject — hence the launchctl list verify inside the lib helper).
            _remediation_note "[fix] keepalive: rendered ${plist} but it did not register — activate with: launchctl load ${plist}"
          else
            _remediation_note "[fix] keepalive: could not render ${_ka_agent} (template missing?) — run: aiteamforge setup"
          fi
        fi
      else
        if ! _xaca0734_launchagents_applicable; then
          _remediation_note "[info] keepalive: not applicable — $(_xaca0734_launchagents_skip_reason)"
        elif _xaca0734_is_opted_out "$_ka_agent"; then
          _remediation_note "[info] keepalive: ${_ka_agent} is opted out — nothing to do"
        elif [ -f "$plist" ]; then
          _remediation_note "[suggest] keepalive: launchctl load ${plist}"
        else
          _remediation_note "[suggest] keepalive: render + load ${_ka_agent} (aiteamforge doctor --fix)"
          _xaca0734_print_optout_hint "$_ka_agent"
        fi
      fi
      ;;
    server)
      # SAFE: idempotent — `aiteamforge start kanban` leaves a healthy server
      # running and only (re)launches a missing one.
      #
      # PREFLIGHT EXCEPTION (XACA-0655 review fix): in --preflight mode we are
      # running at the very top of `aiteamforge start`, which is itself about to
      # bring the server up. Shelling out to `aiteamforge start kanban` here is
      # both premature (the parent start does it moments later) AND the trigger
      # for first-launch recursion. So under preflight we never auto-start the
      # server — we only record a suggestion. (The start.sh re-entry guard is the
      # hard backstop; this keeps the behavior correct, not just non-fatal.)
      if [ "$apply" = true ] && [ "${PREFLIGHT:-false}" != true ]; then
        _remediation_note "[fix] server: aiteamforge start kanban"
        if command -v aiteamforge >/dev/null 2>&1; then
          aiteamforge start kanban >/dev/null 2>&1 || \
            _remediation_note "[fix] server: 'aiteamforge start kanban' returned non-zero"
        else
          _remediation_note "[fix] server: 'aiteamforge' not on PATH — run: aiteamforge start kanban"
        fi
      else
        _remediation_note "[suggest] server: aiteamforge start kanban"
      fi
      ;;
    board|setup)
      # RISKY: `aiteamforge setup` rewrites configuration — too risky to auto-apply.
      # ALWAYS print-only, even under --apply.
      _remediation_note "[manual] config/board: aiteamforge setup  (rewrites config — apply manually)"
      ;;
    *)
      return 1
      ;;
  esac
  return 0
}

# Banner — suppressed in quiet preflight mode (XACA-0655-004).
if [ "${DOCTOR_QUIET:-false}" != "true" ]; then
  [[ -t 1 ]] && clear
  print_header "AITEAMFORGE DOCTOR - HEALTH CHECK"
fi

# Check: External Dependencies
check_dependencies() {
  print_section "Checking External Dependencies"

  # Python
  if command -v python3 &>/dev/null; then
    py_version=$(python3 --version 2>&1 | awk '{print $2}')
    check_result pass "Python 3 (${py_version})"
  else
    check_result fail "Python 3 not found" "Install: brew install python@3.13"
  fi

  # Node.js
  if command -v node &>/dev/null; then
    node_version=$(node --version)
    check_result pass "Node.js (${node_version})"
  else
    check_result fail "Node.js not found" "Install: brew install node"
  fi

  # jq
  if command -v jq &>/dev/null; then
    jq_version=$(jq --version)
    check_result pass "jq (${jq_version})"
  else
    check_result fail "jq not found" "Install: brew install jq"
  fi

  # GitHub CLI
  if command -v gh &>/dev/null; then
    gh_version=$(gh --version | head -n1)
    check_result pass "GitHub CLI (${gh_version})"

    # Check authentication
    if gh auth status &>/dev/null; then
      check_result pass "GitHub CLI authenticated"
    else
      check_result warn "GitHub CLI not authenticated" "Run: gh auth login"
    fi
  else
    check_result fail "GitHub CLI not found" "Install: brew install gh"
  fi

  # Git
  if command -v git &>/dev/null; then
    git_version=$(git --version | awk '{print $3}')
    check_result pass "Git (${git_version})"
  else
    check_result fail "Git not found" "Install: xcode-select --install"
  fi

  # iTerm2
  # XACA-0698: iTerm2 and Claude Code are intentionally absent on headless CI
  # runners (GH Actions macOS). We downgrade these to 'warn' in CI so the doctor
  # exit-code stays clean for the 'aiteamforge doctor' gate in the E2E acceptance
  # test. On a real consumer workstation (no CI env var) they remain hard failures
  # so a misconfigured install is still surfaced correctly.
  # CI detection: standard GITHUB_ACTIONS=true or CI=true env vars (both set by GH
  # Actions). Not set by a normal interactive terminal session.
  _doc_ci_mode=false
  [ "${GITHUB_ACTIONS:-}" = "true" ] || [ "${CI:-}" = "true" ] && _doc_ci_mode=true

  if [ -d "/Applications/iTerm.app" ]; then
    check_result pass "iTerm2"
  elif [ "$_doc_ci_mode" = "true" ]; then
    check_result warn "iTerm2 not found (expected-absent in CI)" "Install locally: brew install --cask iterm2"
  else
    check_result fail "iTerm2 not found" "Install: brew install --cask iterm2"
  fi

  # Claude Code
  if command -v claude &>/dev/null; then
    claude_version=$(claude --version 2>&1 || echo "unknown")
    check_result pass "Claude Code (${claude_version})"

    # Check authentication
    if [ -f "$HOME/.config/claude/config.json" ]; then
      check_result pass "Claude Code configured"
    else
      check_result warn "Claude Code not configured" "Run: claude auth login"
    fi
  elif [ "$_doc_ci_mode" = "true" ]; then
    check_result warn "Claude Code not found (expected-absent in CI)" "Install locally: npm install -g @anthropic-ai/claude-code"
  else
    check_result fail "Claude Code not found" "Install: npm install -g @anthropic-ai/claude-code"
  fi

  # Optional: Tailscale (check CLI in PATH, Homebrew, and macOS app)
  if command -v tailscale &>/dev/null; then
    check_result pass "Tailscale (CLI in PATH)"
  elif [ -x "/opt/homebrew/bin/tailscale" ]; then
    check_result pass "Tailscale (Homebrew)"
  elif [ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]; then
    check_result pass "Tailscale (macOS app)"
  else
    check_result warn "Tailscale not installed (optional)" "Install: brew install --cask tailscale"
  fi

  # Optional: ImageMagick
  if command -v convert &>/dev/null; then
    check_result pass "ImageMagick (optional)"
  else
    check_result warn "ImageMagick not installed (optional)" "Install: brew install imagemagick"
  fi
}

# Check: Homebrew tap-trust gate (XACA-0676)
# Recent Homebrew refuses to load formulae from an untrusted tap when
# $HOMEBREW_REQUIRE_TAP_TRUST is set. On a gated box this makes `brew outdated`/
# `brew upgrade` silently no-op — the machine rots on an old version while every
# upgrade reports success. This diagnostic surfaces that condition LOUDLY.
# Detection only (warn-loud): the fix is a one-liner the operator runs explicitly.
check_tap_trust() {
  print_section "Checking Homebrew Tap Trust"

  local tap
  tap="$(_aitf_tap_name)"

  if ! command -v brew &>/dev/null; then
    check_result warn "Homebrew not found — cannot verify tap trust" \
      "Install Homebrew, then: brew trust --tap ${tap}"
    return
  fi

  # Only meaningful when aiteamforge is actually installed/tapped via Homebrew.
  if ! brew list aiteamforge &>/dev/null \
     && ! brew tap 2>/dev/null | grep -qi "${tap}"; then
    print_info "  aiteamforge not installed via Homebrew tap — tap-trust check not applicable"
    return
  fi

  if tap_load_refused; then
    check_result fail "Homebrew is REFUSING to load the aiteamforge formula (UNTRUSTED TAP) — upgrades are silently BLOCKED and this box will stay on the OLD version" \
      "Run: brew trust --tap ${tap}"
  else
    check_result pass "aiteamforge tap is trusted (formula loads)"
  fi
}

# Check: Tap-owned Python venv and required deps (XACA-0650)
# The tap venv is provisioned by the Formula post_install at:
#   $HOMEBREW_PREFIX/var/aiteamforge/venv
# If iterm2 or another required dep is missing, the fix is always:
#   brew postinstall aiteamforge  (re-provisions the venv from requirements.txt)
check_python_venv() {
  print_section "Checking Tap-Owned Python Venv"

  # AITEAMFORGE_PYTHON resolved by python-env.sh at the top of this file.
  local atf_python="${AITEAMFORGE_PYTHON:-}"

  if [ -z "$atf_python" ] || [ "$atf_python" = "python3" ]; then
    check_result fail "Tap-owned Python venv not found" \
      "Run: brew postinstall aiteamforge  (provisions the venv with all Python deps)"
    if [ "$FIX" = true ]; then
      print_info "  --fix: run 'brew postinstall aiteamforge' to reprovision the venv"
    fi
    return
  fi

  if [ ! -x "$atf_python" ]; then
    check_result fail "Tap-owned venv Python not executable: ${atf_python}" \
      "Run: brew postinstall aiteamforge"
    return
  fi

  local atf_py_version
  atf_py_version=$("$atf_python" --version 2>&1 | awk '{print $2}')
  check_result pass "Tap-owned venv Python (${atf_py_version:-unknown}) — ${atf_python}"

  # Check required deps from requirements.txt using pip show
  local venv_bin
  venv_bin="$(dirname "$atf_python")"
  local venv_pip="${venv_bin}/pip"

  if [ ! -x "$venv_pip" ]; then
    check_result fail "pip not found in tap venv — venv may be incomplete" \
      "Run: brew postinstall aiteamforge"
    return
  fi

  # Parse required Python packages from share/requirements.txt.
  # Strip comments, blank lines, PEP 508 version specifiers, extras, and
  # environment markers.  Fall back to the known set if the file is unreadable.
  local requirements_file="${LIBEXEC_DIR}/../share/requirements.txt"
  local required_packages=()
  if [ -r "$requirements_file" ]; then
    while IFS= read -r line; do
      # Skip blank lines and comment lines
      [[ -z "$line" || "$line" == \#* ]] && continue
      # Strip from first PEP 508 operator/marker/extras char onward:
      #   <>=~!  version comparisons  (==, >=, <=, ~=, !=, >, <)
      #   ;      environment markers  (pkg ; python_version < '3')
      #   [      extras spec          (pkg[extra]==1.0)
      local pkg_name
      pkg_name="${line%%[<>=~!;[]*}"
      # Trim leading whitespace
      pkg_name="${pkg_name#"${pkg_name%%[![:space:]]*}"}"
      # Trim trailing whitespace
      pkg_name="${pkg_name%"${pkg_name##*[![:space:]]}"}"
      [[ -n "$pkg_name" ]] && required_packages+=("$pkg_name")
    done < "$requirements_file"
  fi
  if [ "${#required_packages[@]}" -eq 0 ]; then
    # Fallback: requirements.txt unreadable or empty — use known set
    required_packages=("iterm2" "pyzipper")
  fi

  for pkg in "${required_packages[@]}"; do
    if "$venv_pip" show "$pkg" &>/dev/null; then
      local pkg_ver
      pkg_ver="$("$venv_pip" show "$pkg" 2>/dev/null | grep '^Version:' | awk '{print $2}')"
      check_result pass "${pkg} package installed (${pkg_ver:-unknown version})"
    else
      check_result fail "${pkg} package missing from tap venv" \
        "Run: brew postinstall aiteamforge  (re-provisions the venv from requirements.txt)"
      if [ "$FIX" = true ]; then
        attempt_remediation venv >/dev/null 2>&1 || true
        print_info "  --fix: ran 'brew postinstall aiteamforge' to reinstall ${pkg}"
      fi
    fi
  done

  # XACA-0655: real importability test.
  # `pip show <pkg>` passing is NOT proof the module imports — a broken/partial
  # install or wrong interpreter can leave metadata present but the import failing
  # at runtime. So we additionally run an actual `import` and gate on exit status.
  #
  # Why iterm2 ALONE gets a real-import probe (XACA-0655-008 review): iterm2 is a
  # native/C-extension-style package whose import genuinely fails when the venv is
  # half-provisioned, and it is the one module the iTerm2 window-manager automation
  # imports at launch — a silent import failure here directly bricks first use, the
  # exact failure mode this doctor exists to catch. The other requirements (e.g.
  # pyzipper) are pure-Python and import-trivial once pip reports them installed, so
  # the pip-show loop above is sufficient for them; adding redundant import probes
  # would only slow the check without catching a distinct real-world failure. If a
  # future launch-critical native dep is added, give it its own probe here.
  local import_probe="iterm2"
  if "$atf_python" -c "import ${import_probe}" >/dev/null 2>&1; then
    check_result pass "${import_probe} module imports cleanly (real import test)"
  else
    local import_err
    import_err="$("$atf_python" -c "import ${import_probe}" 2>&1 | tail -n1)"
    check_result fail "${import_probe} pip-show passes but 'import ${import_probe}' FAILS — broken/partial venv install" \
      "Run: brew postinstall aiteamforge  (re-provisions the venv). Import error: ${import_err}"
    if [ "$FIX" = true ]; then
      attempt_remediation venv >/dev/null 2>&1 || true
      print_info "  --fix: ran 'brew postinstall aiteamforge' to repair the venv import"
    fi
  fi
}

# Check: Framework Installation
check_framework() {
  print_section "Checking Framework Installation"

  local framework_dir
  framework_dir=$(get_framework_dir)

  # Framework directory exists
  if [ -d "$framework_dir" ]; then
    check_result pass "Framework directory: ${framework_dir}"
  else
    check_result fail "Framework directory not found: ${framework_dir}"
    return
  fi

  # Core templates exist in framework
  local core_templates=(
    "share/templates/kanban/kanban-helpers.template.sh"
    "share/templates/aliases/agent-aliases.sh"
    "share/templates/aliases/worktree-aliases.sh"
  )

  for tmpl in "${core_templates[@]}"; do
    local tmpl_name
    tmpl_name="$(basename "$tmpl")"
    if [ -f "${framework_dir}/${tmpl}" ]; then
      check_result pass "${tmpl_name} (template)"
    else
      check_result warn "${tmpl_name} template missing"
    fi
  done

  # Core directories exist
  local core_dirs=(
    "share/templates"
    "share/teams"
    "docs"
    "libexec/commands"
    "libexec/lib"
  )

  for dir in "${core_dirs[@]}"; do
    if [ -d "${framework_dir}/${dir}" ]; then
      check_result pass "${dir}/"
    else
      check_result warn "${dir}/ missing"
    fi
  done

  # Check if wizard UI library exists
  if [ -f "${framework_dir}/libexec/lib/wizard-ui.sh" ]; then
    check_result pass "Wizard UI library"
  else
    check_result fail "Wizard UI library missing"
  fi
}

# Check: Cellar-vs-working-dir version drift (XACA-0578)
# Detects when `brew upgrade aiteamforge` ran but `aiteamforge upgrade --non-interactive`
# did NOT follow (e.g. cellar-watch LaunchAgent is disabled/missing/broken).
# The .installed-version stamp is written by `aiteamforge upgrade` (Edit A); if it
# is absent the check falls back to the "version" field in .aiteamforge-config
# (install-time only — less reliable for drift detection).
check_version_drift() {
  print_section "Checking Cellar vs Working-Dir Version"

  local framework_dir working_dir
  framework_dir=$(get_framework_dir)
  working_dir=$(get_working_dir)

  # --- Cellar VERSION (what brew upgraded to) ---
  local cellar_version=""
  local cellar_version_file=""
  for _candidate in "${framework_dir}/../VERSION" "${framework_dir}/VERSION"; do
    if [ -f "$_candidate" ]; then
      cellar_version_file="$_candidate"
      cellar_version="$(cat "$_candidate" | tr -d '[:space:]' | sed 's/^v//')"
      break
    fi
  done
  unset _candidate

  if [ -z "$cellar_version" ]; then
    check_result fail "Cellar VERSION file not found (checked ${framework_dir}/../VERSION)" \
      "Verify FRAMEWORK_DIR resolves correctly: ${framework_dir}"
    return
  fi

  # --- Working-dir installed version ---
  local installed_version=""
  local drift_mode=""
  local stamp_file="${working_dir}/.installed-version"

  if [ -f "$stamp_file" ]; then
    installed_version="$(cat "$stamp_file" | tr -d '[:space:]' | sed 's/^v//')"
    drift_mode="stamp"
  else
    # Fallback: config "version" field (install-time only — less reliable)
    installed_version="$(get_installed_version | tr -d '[:space:]' | sed 's/^v//')"
    drift_mode="config-fallback"
  fi

  # --- Diagnostics for missing stamp ---
  if [ -z "$installed_version" ]; then
    check_result warn "Cannot determine working-dir version (no .installed-version stamp and no version in config)" \
      "Run: aiteamforge upgrade --non-interactive  to refresh and stamp"
    return
  fi

  # Fallback mode advisory
  if [ "$drift_mode" = "config-fallback" ]; then
    print_info "  Note: .installed-version stamp absent — using config version (less reliable; run 'aiteamforge upgrade --non-interactive' to stamp)"
  fi

  # --- Compare ---
  if [ "$cellar_version" = "$installed_version" ]; then
    check_result pass "Cellar v${cellar_version} matches working-dir v${installed_version}" \
      "Version stamp mode: ${drift_mode}"
  else
    check_result warn "Cellar v${cellar_version} BUT working-dir v${installed_version} — run: aiteamforge upgrade --non-interactive" \
      "Stamp file: ${stamp_file} | Drift mode: ${drift_mode}"
    if [ "$VERBOSE" = true ]; then
      echo "    Cellar VERSION file: ${cellar_version_file}"
      echo "    Working-dir stamp:   ${stamp_file}"
      echo "    Stamp mode:          ${drift_mode}"
    fi
  fi
}

# Check: Configuration
check_config() {
  print_section "Checking Configuration"

  local working_dir
  working_dir=$(get_working_dir)

  # Working directory exists
  if [ -d "$working_dir" ]; then
    check_result pass "Working directory: ${working_dir}"
  else
    check_result fail "Working directory not found: ${working_dir}" "Run: aiteamforge setup"
    return
  fi

  # Configuration marker exists
  if is_configured; then
    check_result pass "Configuration marker"

    # Validate config structure
    if validate_config; then
      check_result pass "Config file valid JSON"

      # Show config details in verbose mode
      if [ "$VERBOSE" = true ]; then
        echo "    Machine: $(get_machine_name)"
        echo "    Machine ID: $(get_machine_id)"
        echo "    Version: $(get_installed_version)"
        echo "    Teams: $(get_configured_teams)"
      fi
    else
      check_result fail "Config file invalid"
    fi
  else
    check_result fail "Not configured" "Run: aiteamforge setup"
  fi

  # Check kanban directory
  if [ -d "${working_dir}/kanban" ]; then
    check_result pass "Kanban directory"

    # Count board files
    local board_count
    board_count=$(find "${working_dir}/kanban" -name "*-board.json" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$VERBOSE" = true ]; then
      echo "    Kanban boards: ${board_count}"
    fi
  else
    check_result warn "Kanban directory missing"
  fi

  # Check LCARS UI directory
  if [ -d "${working_dir}/lcars-ui" ]; then
    check_result pass "LCARS UI directory"
  else
    check_result warn "LCARS UI directory missing"
  fi
}

# Check: Kanban Board Resolution (XACA-0655-001)
# Verifies the kanban board the runtime would resolve actually exists, parses as
# valid JSON, and is a REAL configured board — not a template/placeholder stub
# laid down before `aiteamforge setup` ran.
#
# Stub-collision detection is the key new value: an install whose org slug is
# still "example-org" (the shipped placeholder) is "configured `setup` never ran".
# Such an install resolves TEMPLATE paths that can lay down / mask a real team
# board. We mirror the runtime signal — _atf_paths_org_name treats "example-org"
# as "not configured" and returns empty — to detect that condition explicitly.
check_board_resolution() {
  print_section "Checking Kanban Board Resolution"

  local working_dir
  working_dir=$(get_working_dir)

  # ── Stub-collision / not-configured detection ─────────────────────────────
  # Probe the org slug the SAME way the runtime resolver does. When the slug is
  # still the shipped "example-org" placeholder, `setup` was never run and any
  # board we resolve is a template stub — flag it explicitly with the exact fix.
  local org_slug="example-org"
  if command -v _aiteamforge_org_slug >/dev/null 2>&1; then
    org_slug=$(_aiteamforge_org_slug 2>/dev/null || echo "example-org")
  fi
  if [ "$org_slug" = "example-org" ] || [ -z "$org_slug" ]; then
    # Only fail if there is ALSO no per-user team-paths overlay configured — a
    # fully de-branded single-org install (e.g. Academy dev box) legitimately
    # has no organization.yaml but DOES have a real board. Distinguish the two:
    # template-stub == placeholder org AND no configured team-paths overlay.
    local team_paths_overlay
    team_paths_overlay="${HOME}/.aiteamforge/team-paths.json"
    if [ ! -f "$team_paths_overlay" ]; then
      check_result fail "Org identity is the unconfigured placeholder (slug='example-org') and no team-paths overlay exists — board resolution would return a TEMPLATE stub" \
        "Run: aiteamforge setup  (provisions org identity + a real team board; otherwise the placeholder template can mask/collide with a real team board)"
      [ "$FIX" = true ] && attempt_remediation setup
      return
    fi
    # Placeholder org but an overlay exists — proceed but note it in verbose.
    if [ "$VERBOSE" = true ]; then
      echo "    Note: org slug is 'example-org' but a team-paths overlay exists at ${team_paths_overlay} — resolving via overlay"
    fi
  fi

  # ── Resolve the active team's kanban dir via the runtime resolver ─────────
  # Determine which team to resolve: first configured team if available, else
  # the default 'academy'. get_configured_teams may return 1 under set -e, so
  # guard with || true.
  local teams_str=""
  teams_str=$(get_configured_teams 2>/dev/null) || true
  local active_team=""
  if [ -n "$teams_str" ]; then
    # First whitespace-delimited token is the primary configured team.
    active_team="${teams_str%% *}"
  fi
  [ -z "$active_team" ] && active_team="academy"

  # Resolve the kanban dir using the SAME resolver the product uses.
  # Prefer the org-aware aiteamforge_team_kanban_dir; fall back to get_kanban_dir
  # (the .aiteamforge-config-driven resolver) when the team-paths resolver yields
  # nothing for this team.
  # active_team is a BASE id from .teams[] ("finance"), but aiteamforge_team_kanban_dir
  # is a REGISTRY lookup and the registry keys profile-scoped teams by INSTANCE id
  # ("finance-personal"). Passing the base id straight in always missed and fell
  # through to get_kanban_dir — the fallback masked the defect rather than resolving
  # it, so doctor reported a path it reached by accident (XACA-0792-002, same defect
  # shape as XACA-0792 itself). Resolve first; get_kanban_dir keeps the BASE id
  # because it is .aiteamforge-config-driven and maps template→instance internally.
  local registry_key="$active_team"
  if command -v aiteamforge_resolve_team_key >/dev/null 2>&1; then
    registry_key=$(aiteamforge_resolve_team_key "$active_team" 2>/dev/null) || registry_key="$active_team"
    [ -z "$registry_key" ] && registry_key="$active_team"
  fi

  local kanban_dir=""
  if command -v aiteamforge_team_kanban_dir >/dev/null 2>&1; then
    kanban_dir=$(aiteamforge_team_kanban_dir "$registry_key" 2>/dev/null) || true
  fi
  if [ -z "$kanban_dir" ] && command -v get_kanban_dir >/dev/null 2>&1; then
    kanban_dir=$(get_kanban_dir "$active_team" 2>/dev/null) || true
  fi
  # Last-resort fallback: the working dir's kanban/ subtree.
  [ -z "$kanban_dir" ] && kanban_dir="${working_dir}/kanban"

  if [ ! -d "$kanban_dir" ]; then
    check_result fail "Kanban directory does not resolve for team '${active_team}': ${kanban_dir}" \
      "Run: aiteamforge setup  (provisions the kanban tree). Checked: ${kanban_dir}"
    return
  fi
  check_result pass "Kanban directory resolves for '${active_team}': ${kanban_dir}"

  # ── Resolve the board file ────────────────────────────────────────────────
  # Board filenames use the INSTANCE id (get_board_id maps template→instance).
  local board_id="$active_team"
  if command -v get_board_id >/dev/null 2>&1; then
    board_id=$(get_board_id "$active_team" 2>/dev/null) || board_id="$active_team"
  fi

  local board_file="${kanban_dir}/${board_id}-board.json"
  # If the exact instance board isn't present, fall back to the first *-board.json
  # in the dir so we still validate SOMETHING real (and can detect a stub).
  if [ ! -f "$board_file" ]; then
    local first_board
    first_board=$(find "$kanban_dir" -maxdepth 1 -name "*-board.json" 2>/dev/null | head -n1)
    if [ -n "$first_board" ]; then
      board_file="$first_board"
    fi
  fi

  if [ ! -f "$board_file" ]; then
    check_result fail "No *-board.json found at resolved kanban dir for '${active_team}'" \
      "Run: aiteamforge setup  (provisions the board). Expected: ${kanban_dir}/${board_id}-board.json"
    return
  fi

  # ── Validate the board parses + has real structure ────────────────────────
  # Prefer the tap-owned Python (always present) for a JSON+structure check in
  # one shot; fall back to jq if Python is unavailable.
  local board_status="" board_team="" board_count=""
  if [ -n "${AITEAMFORGE_PYTHON:-}" ]; then
    # Emit: "<status>\t<team>\t<backlog_count>" — status is ok|badjson|empty.
    local board_probe
    board_probe=$("${AITEAMFORGE_PYTHON}" - "$board_file" <<'PYEOF' 2>/dev/null || true
import sys, json
from pathlib import Path
try:
    data = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
except Exception:
    print("badjson\t\t")
    sys.exit(0)
team = ""
t = data.get("team")
if isinstance(t, dict):
    team = str(t.get("id") or t.get("name") or "")
elif isinstance(t, str):
    team = t
# Count backlog/items structure — board is real if it has any structure keys.
backlog = data.get("backlog")
n = len(backlog) if isinstance(backlog, list) else (len(backlog) if isinstance(backlog, dict) else 0)
# A board with no team AND no recognizable structure is an empty/placeholder stub.
has_struct = bool(team) or isinstance(backlog, (list, dict)) or any(
    k in data for k in ("columns", "items", "lanes", "board")
)
status = "ok" if has_struct else "empty"
print(f"{status}\t{team}\t{n}")
PYEOF
)
    board_status="${board_probe%%	*}"
    local _rest="${board_probe#*	}"
    board_team="${_rest%%	*}"
    board_count="${_rest##*	}"
  elif command -v jq >/dev/null 2>&1; then
    if jq empty "$board_file" >/dev/null 2>&1; then
      board_status="ok"
      board_team=$(jq -r '.team.id // .team.name // (.team|strings) // ""' "$board_file" 2>/dev/null)
      board_count=$(jq -r '(.backlog | length) // 0' "$board_file" 2>/dev/null)
    else
      board_status="badjson"
    fi
  else
    check_result warn "Cannot validate board JSON — no Python venv or jq available" \
      "Board file present: ${board_file}"
    return
  fi

  case "$board_status" in
    ok)
      check_result pass "Board resolves + parses: $(basename "$board_file") (team='${board_team:-?}', backlog=${board_count:-0})" \
        "Board file: ${board_file}"
      ;;
    empty)
      check_result warn "Board parses but looks like an empty/placeholder stub (no team + no backlog/columns): $(basename "$board_file")" \
        "Run: aiteamforge setup  to provision a real team board. File: ${board_file}"
      ;;
    badjson|*)
      check_result fail "Board file is unparseable JSON: $(basename "$board_file")" \
        "Restore from backup or run: aiteamforge setup. File: ${board_file}"
      ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# Check: cockpit connect scripts (XACA-0845)
#
# Cross-checks the instances this box INSTALLED against the *-connect.sh files
# actually on disk, and reports BOTH directions:
#
#   missing — an installed instance with no connect script. The actionable
#             failure, and the XACA-0845 symptom: a parametric team was
#             scriptless precisely BECAUSE it was selected during setup, since
#             selection routed it down the install path that refused to render
#             one.
#   orphan  — a connect script matching no installed instance, typically a
#             conf-default instance ("legal-default") written by a pass that did
#             not know the real project, or a pre-0.11.5 bare-team name.
#
# SOURCE OF TRUTH is ${WORKING_DIR}/.aiteamforge-config `.teams[]`, NOT
# ~/.aiteamforge/team-paths.json. The registry is written by
# aiteamforge-team-paths-wizard.py, which enables every catalogued team by
# default (and writes all 16 verbatim under --accept-defaults), so registry
# membership does not imply the team was ever set up — it would make this check
# report a "missing connect script" for every catalogued team on every box. See
# the matching rationale in aiteamforge-upgrade.sh's update_connect_scripts
# (XACA-0845-008).
#
# COCKPIT INSTALLS ARE EXEMPT FROM THE ORPHAN DIRECTION (XACA-0845-016).
# They record an EMPTY .teams[] on purpose — a cockpit box is a thin client that
# installs no teams locally — so cross-checking against it made EVERY connect
# script an orphan: 8 warnings and 0 passes on a cockpit-shaped install, each
# advising the user (under --verbose) to delete the files the box exists to
# provide. An earlier revision of this comment claimed that shape was benign
# ("reports orphans only, never spurious missing entries"); it was not — orphans
# were the false positive. Direction 2 is now skipped entirely on that profile;
# direction 1 stays live because .teams[] already makes it self-suppressing
# there. See the block comment at the direction-2 loop for the full rationale.
#
# This check REPORTS ONLY and never removes anything, on EVERY profile. An
# orphan is a dead script; deleting one someone still invokes is a worse failure
# than leaving it, and the file is the only remaining record of how it got there.
# Removal stays a deliberate human act. The cockpit gate suppresses REPORTING,
# never files — test S4 pins that no deletion path exists here at all.
# ─────────────────────────────────────────────────────────────────────────────
# Resolve the install profile for a working dir. $1 = working dir.
# Echoes "cockpit", "full", or whatever marker value was recorded.
#
# PRIMARY signal is the `.install-profile` marker file — the same one
# libexec/lib/launchagents.sh (:227, :334) and libexec/lib/validate-install.sh
# (:571) already read, and bin/aiteamforge-doctor.sh (:53) already parses.
# Reading the same marker as every sibling is deliberate: a second, differently
# derived notion of "is this a cockpit box" is exactly the sibling-heuristic
# drift that makes two checks contradict each other on one machine.
#
# FALLBACK is `.install_profile` inside .aiteamforge-config, which
# bin/aiteamforge-setup.sh (:1677) writes from the same variable in the same
# pass that writes the marker (:1691). It costs one python call and closes the
# case where the marker was lost but the config survived — on a cockpit box the
# fallback is the difference between a clean report and a screen of advice to
# delete files the box exists to provide.
_connect_scripts_install_profile() {
  local _wd="$1"
  local _p=""

  if [ -f "${_wd}/.install-profile" ] && [ -r "${_wd}/.install-profile" ]; then
    _p="$(tr -d '[:space:]' < "${_wd}/.install-profile" 2>/dev/null || true)"
  fi

  if [ -z "$_p" ] && command -v python3 >/dev/null 2>&1; then
    # NOTE FOR EDITORS: no apostrophes in the here-doc body (bash 3.2 does not
    # treat a here-doc nested inside $( ) as opaque). See XACA-0845.
    _p="$(python3 - "${_wd}/.aiteamforge-config" <<'PYEOF' 2>/dev/null || true
import json, sys
try:
    with open(sys.argv[1]) as fh:
        cfg = json.load(fh)
    val = cfg.get("install_profile")
    if val:
        print(str(val).strip())
except Exception:
    pass
PYEOF
)"
  fi

  [ -n "$_p" ] || _p="full"
  printf '%s\n' "$_p"
}

check_connect_scripts() {
  print_section "Checking Cockpit Connect Scripts"

  local _working_dir
  _working_dir="$(get_working_dir)"
  local _install_config="${_working_dir}/.aiteamforge-config"

  if ! command -v python3 >/dev/null 2>&1; then
    check_result warn "python3 unavailable — cannot cross-check connect scripts against installed teams"
    return
  fi

  # NOTE FOR EDITORS: no apostrophes anywhere in the here-doc body below. Under
  # bash 3.2 a here-doc nested inside $( ) is NOT opaque, so one stray single
  # quote unterminates the whole file. See XACA-0845.
  local _installed
  _installed="$(python3 - "$_install_config" <<'PYEOF' 2>/dev/null || true
import json, sys

# Compose the instance id EXACTLY as install-team.sh compute_instance_id() does:
#   no project -> "<base>"; project only -> "<base>-<project>";
#   project + client -> "<base>-<client>-<project>". Components are lowercased.
#
# XACA-0845-015: client_id was ignored here, so a freelance box (the only
# TEAM_REQUIRES_CLIENT_ID template that ships) produced a DOUBLE false positive
# from one install: the composed-but-wrong "freelance-<project>" was reported
# missing, while the correct on-disk "freelance-<client>-<project>" script was
# reported an orphan. This reader must stay byte-for-byte equivalent to the one
# in aiteamforge-upgrade.sh update_connect_scripts — they answer the same
# question and a divergence makes doctor and upgrade contradict each other.
out = []
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

for i in sorted(set(x for x in out if x)):
    print(i)
PYEOF
)"

  local _on_disk="" _cs _inst _missing=0 _orphans=0 _on_disk_count=0
  for _cs in "${_working_dir}"/*-connect.sh; do
    [ -f "$_cs" ] || continue
    _inst="$(basename "$_cs")"
    _on_disk="${_on_disk}${_inst%-connect.sh}"$'\n'
    _on_disk_count=$((_on_disk_count + 1))
  done

  local _profile
  _profile="$(_connect_scripts_install_profile "$_working_dir")"

  if [ -z "$_installed" ] && [ -z "$_on_disk" ]; then
    check_result pass "No installed team instances to cross-check"
    return
  fi

  # Direction 1: installed but no script — the actionable failure.
  while IFS= read -r _inst; do
    [ -n "$_inst" ] || continue
    if [ -f "${_working_dir}/${_inst}-connect.sh" ]; then
      check_result pass "Connect script present for ${_inst}"
    else
      _missing=$((_missing + 1))
      check_result warn "Installed instance '${_inst}' has no connect script" \
        "Run: aiteamforge upgrade (recreates missing cockpit scripts)"
    fi
  done <<< "$_installed"

  # Direction 2: script with no installed instance — reported, never removed.
  #
  # SUPPRESSED ENTIRELY ON COCKPIT INSTALLS (XACA-0845-016).
  # ───────────────────────────────────────────────────────
  # A cockpit box is a thin client: LCARS and kanban run on a REMOTE host, and
  # setup deliberately records an EMPTY `.teams[]` because this box installs no
  # teams locally. Its connect scripts are therefore not evidence of a problem —
  # they are the entire reason the box exists. Cross-checking them against an
  # array that is empty BY DESIGN makes every single script an "orphan": the
  # check returned 8 warnings and 0 passes on a cockpit-shaped install, and
  # under --verbose attached "If it is genuinely unused, remove it by hand" to
  # each one. That advice, followed, would tell a user to delete their whole
  # cockpit. A check that is 100% false-positive on a supported profile is worse
  # than no check: it trains people to ignore doctor output, and this one runs in
  # the `all` fan-out, so it fired on every cockpit doctor run.
  #
  # Direction 1 is deliberately NOT gated. It is driven by `.teams[]`, which is
  # empty on a stock cockpit box, so it self-suppresses there without a special
  # case — it emits nothing rather than something wrong. Keeping it live means a
  # cockpit box that DOES record an installed instance (a profile changed after
  # the fact, a hand-edited config) still gets the actionable, non-destructive
  # "run aiteamforge upgrade" report. Gating direction 1 on the profile would buy
  # nothing and would blind the one case where it still has something true to say.
  #
  # The suppression is REPORTING-ONLY, consistent with the rest of this check:
  # no file is touched, and no deletion path exists on any profile.
  if [ "$_profile" = "cockpit" ]; then
    if [ "$_on_disk_count" -gt 0 ]; then
      check_result pass "Cockpit install — ${_on_disk_count} connect script(s) present; orphan cross-check skipped (a cockpit box installs no local teams by design)"
    fi
  else
    while IFS= read -r _inst; do
      [ -n "$_inst" ] || continue
      if ! printf '%s\n' "$_installed" | grep -qx -- "$_inst"; then
        _orphans=$((_orphans + 1))
        check_result warn "Connect script '${_inst}-connect.sh' matches no installed instance" \
          "Left in place deliberately. If it is genuinely unused, remove it by hand."
      fi
    done <<< "$_on_disk"
  fi

  if [ "$_missing" -eq 0 ] && [ "$_orphans" -eq 0 ] && [ "$_profile" != "cockpit" ]; then
    check_result pass "Connect scripts match installed instances exactly"
  fi
}

# Check: Services
check_services() {
  print_section "Checking Services"

  # LCARS Kanban server — read port from config, check root URL (no /health endpoint)
  local lcars_port=8080
  local lcars_working_dir
  lcars_working_dir=$(get_working_dir)
  if [ -f "${lcars_working_dir}/lcars-ui/.lcars-port" ]; then
    lcars_port="$(cat "${lcars_working_dir}/lcars-ui/.lcars-port" 2>/dev/null || echo 8080)"
  fi
  local lcars_up=false
  if curl -s -o /dev/null -w '%{http_code}' "http://localhost:${lcars_port}/" 2>/dev/null | grep -q '200'; then
    check_result pass "LCARS Kanban server (port ${lcars_port})"
    lcars_up=true
  else
    check_result warn "LCARS Kanban server not running"
    if [ "$VERBOSE" = true ]; then
      echo "    Start: aiteamforge start kanban"
    fi
    if [ "$FIX" = true ]; then
      attempt_remediation server --apply
    fi
  fi

  # XACA-0655: server DURABILITY — reachability alone is not enough. If the
  # keepalive/auto-restart LaunchAgent is not loaded, the server will die on the
  # next crash and NOT come back, leaving the box silently broken. Surface that.
  # (warn, not fail: the server may be up right now — the risk is future durability.)
  if _xaca0734_launchctl_is_loaded "com.aiteamforge.lcars-health"; then
    [ "$VERBOSE" = true ] && echo "    Durability: lcars-health keepalive LaunchAgent loaded"
  else
    if [ "$lcars_up" = true ]; then
      check_result warn "LCARS server is UP but has NO durability mechanism (lcars-health keepalive LaunchAgent not loaded) — it will NOT auto-restart after a crash" \
        "Run: launchctl load ~/Library/LaunchAgents/com.aiteamforge.lcars-health.plist"
    else
      check_result warn "LCARS keepalive LaunchAgent (lcars-health) not loaded — no auto-restart on crash" \
        "Run: launchctl load ~/Library/LaunchAgents/com.aiteamforge.lcars-health.plist"
    fi
    if [ "$FIX" = true ]; then
      attempt_remediation keepalive --apply
    fi
  fi

  # Port-file consistency: the .lcars-port file should match the port the server
  # is actually answering on. A stale port file means health checks / launchers
  # probe the wrong port and the keepalive can flap.
  if [ "$lcars_up" = true ] && [ -f "${lcars_working_dir}/lcars-ui/.lcars-port" ]; then
    local port_file_val
    port_file_val="$(tr -d '[:space:]' < "${lcars_working_dir}/lcars-ui/.lcars-port" 2>/dev/null || echo '')"
    if [ -n "$port_file_val" ] && [ "$port_file_val" != "$lcars_port" ]; then
      check_result warn "LCARS .lcars-port file (${port_file_val}) disagrees with the live serving port (${lcars_port})" \
        "Fix: stop/restart LCARS so the port file is rewritten — aiteamforge restart kanban"
    elif [ "$VERBOSE" = true ]; then
      echo "    Durability: .lcars-port (${port_file_val}) matches live port"
    fi
  fi

  # Fleet Monitor — check server AND client (reporter)
  local working_dir
  working_dir=$(get_working_dir)

  if [ -d "${working_dir}/fleet-monitor/server" ]; then
    # Server mode: check if server is running
    local fleet_running=false
    # shellcheck disable=SC2086
    for port in $FLEET_MONITOR_PORT_SCAN_RANGE; do
      if curl -s -o /dev/null -w '%{http_code}' "http://localhost:${port}/" 2>/dev/null | grep -q '200'; then
        check_result pass "Fleet Monitor server (port ${port})"
        fleet_running=true
        break
      fi
    done

    if [ "$fleet_running" = false ]; then
      check_result warn "Fleet Monitor server not running"
      if [ "$VERBOSE" = true ]; then
        echo "    Start: aiteamforge start fleet"
      fi
    fi
  fi

  # Fleet reporter client
  if [ -f "${working_dir}/fleet-monitor/client/fleet-reporter.sh" ]; then
    check_result pass "Fleet reporter client installed"
  elif [ -f "$HOME/.aiteamforge/fleet-config.json" ]; then
    check_result warn "Fleet reporter config exists but script missing"
  fi
}

# Check: LCARS servers bound to a NON-CANONICAL port (XACA-0706)
# ─────────────────────────────────────────────────────────────────────────────
# Root cause of XACA-0613: after a port-resolver refresh (e.g. v0.15.0 moved a
# team's cksum-derived lcars_port), a long-lived <instance>-lcars session keeps
# serving on the OLD port. The launcher's has-session idempotency guard then
# blocks recreation, so script/config fixes never rebind the running session —
# it quietly serves the wrong port until it dies, unnoticed. lcars-health-check
# now self-heals this; the doctor SURFACES it so an operator sees the drift even
# if the keepalive LaunchAgent isn't loaded.
#
# Detection (mirrors lcars-health-check.sh::detect_lcars_bound_ports): every
# LCARS server is launched as `env LCARS_TEAM=<team> ... <python> server.py
# <PORT>`. We read each live server.py's argv+env via `ps eww`, pull the team
# from `LCARS_TEAM=` and the bound port from the token after `server.py`, then
# compare against the team's CANONICAL port resolved by the shipped
# share/kanban-hooks/lcars_ports.py helper. A mismatch is a FAIL (XACA-0706): the
# server may answer right now, but it is bound to the wrong port — the launcher's
# has-session guard blocks rebinding it, health checks probe the canonical port,
# and when this stale-port server crashes nothing restarts it on canonical (the
# exact XACA-0613 refresh-gap incident this check exists to surface).
check_lcars_port_drift() {
  print_section "Checking LCARS Port Drift"

  # Locate the shipped canonical-port resolver. share/ is a sibling of libexec/.
  local ports_helper="${LIBEXEC_DIR}/../share/kanban-hooks/lcars_ports.py"
  if [ ! -f "$ports_helper" ]; then
    check_result warn "LCARS port-drift check skipped — port resolver not found (${ports_helper})"
    return 0
  fi

  local py="${AITEAMFORGE_PYTHON:-python3}"

  # Sweep live LCARS servers. pgrep returns 1 (and empty) when none match; the
  # `|| true` keeps set -e from aborting here (no servers running is normal).
  local pids
  pids="$(pgrep -f 'server\.py' 2>/dev/null || true)"
  if [ -z "$pids" ]; then
    check_result pass "No LCARS servers running (no port drift possible)"
    return 0
  fi

  local drift_found=false
  local checked=0
  local _pid _args _team _bound_port _canonical
  for _pid in $pids; do
    [ -z "$_pid" ] && continue
    _args="$(ps eww -o args= -p "$_pid" 2>/dev/null || true)"
    [ -z "$_args" ] && continue

    # Only LCARS servers carry LCARS_TEAM in their env. Parse team (no spaces).
    case "$_args" in
      *" LCARS_TEAM="*) ;;
      *) continue ;;
    esac
    _team="${_args##* LCARS_TEAM=}"
    _team="${_team%%[[:space:]]*}"
    [ -z "$_team" ] && continue

    # Bound port = first integer token immediately after "server.py ".
    _bound_port="${_args#*server.py }"
    _bound_port="${_bound_port%%[![:digit:]]*}"
    [ -z "$_bound_port" ] && continue

    # Resolve the team's canonical port. lcars_ports.py prints "team:port" on
    # stdout (warnings to stderr). `|| true` guards set -e on a skip/exit-1.
    _canonical="$("$py" "$ports_helper" "$_team" 2>/dev/null | head -1 || true)"
    _canonical="${_canonical#*:}"
    if [ -z "$_canonical" ]; then
      check_result warn "LCARS server for team '${_team}' is on port ${_bound_port} but its canonical port could not be resolved" \
        "Verify '${_team}' is registered in aiteamforge_paths.py / team-paths.json"
      drift_found=true
      checked=$((checked + 1))
      continue
    fi

    checked=$((checked + 1))
    if [ "$_bound_port" != "$_canonical" ]; then
      check_result fail "LCARS server for team '${_team}' is bound to NON-CANONICAL port ${_bound_port} (canonical is ${_canonical})" \
        "Reconcile: run lcars-health-check.sh (it now self-heals this), or 'aiteamforge restart kanban'"
      drift_found=true
    elif [ "$VERBOSE" = true ]; then
      echo "    ${_team}: bound port ${_bound_port} matches canonical"
    fi
  done

  if [ "$drift_found" = false ] && [ "$checked" -gt 0 ]; then
    check_result pass "All running LCARS servers are on their canonical port (${checked} checked)"
  elif [ "$checked" -eq 0 ]; then
    check_result pass "No identifiable LCARS team servers running (no port drift)"
  fi
}

# Check: LCARS Python Runtime (XACA-0713)
#
# Distinct from check_python_venv (which validates the venv's PACKAGES via the
# login-shell AITEAMFORGE_PYTHON). This check guards the two XACA-0713 crash
# surfaces that check_python_venv does NOT cover:
#
#   1. server.py 3.9 import-safety — the canonical server.py uses PEP-604
#      `int | None` annotations. Without `from __future__ import annotations`
#      these eval at import time and raise TypeError on macOS system python 3.9.6.
#      We py_compile it under /usr/bin/python3 (the 3.9 that crashed it).
#
#   2. Runtime resolver under a LAUNCHD / non-login PATH — the root cause. The
#      com.aiteamforge.lcars-health daemon runs with no /opt/homebrew/bin on
#      PATH, so `brew --prefix` returns empty and a brew-dependent resolver falls
#      back to system python3 (3.9) → the server crashes on auto-restart and the
#      daemon's retries SIGTERM-race any good server. We resolve the interpreter
#      exactly as the daemon would (scrubbed PATH, HOME preserved) and assert it
#      is the venv (>=3.10), never system 3.9.
check_lcars_python_runtime() {
  print_section "Checking LCARS Python Runtime (XACA-0713)"

  # share/ is a sibling of libexec/.
  local server_py="${LIBEXEC_DIR}/../share/lcars-ui/server.py"
  local helpers="${LIBEXEC_DIR}/../share/scripts/lcars-launch-helpers.sh"

  # ── 1. server.py 3.9 import-safety ──────────────────────────────────────
  if [ -f "$server_py" ]; then
    if [ -x /usr/bin/python3 ]; then
      local sysver
      sysver="$(/usr/bin/python3 --version 2>&1 | awk '{print $2}')"
      if /usr/bin/python3 -c "import py_compile; py_compile.compile('${server_py}', doraise=True)" >/dev/null 2>&1; then
        check_result pass "server.py compiles under system python3 (${sysver:-?}) — 3.9-safe"
      else
        check_result fail "server.py FAILS to compile under system python3 (${sysver:-?}) — PEP-604 annotations not deferred (XACA-0713)" \
          "server.py must begin with 'from __future__ import annotations'. Reinstall: brew upgrade aiteamforge"
      fi
    fi
  else
    check_result warn "LCARS python-runtime: server.py not found (${server_py})"
  fi

  # ── 2. resolve_lcars_python under a launchd-style PATH ───────────────────
  if [ ! -f "$helpers" ]; then
    check_result warn "LCARS python-runtime: launch helpers not found (${helpers}) — resolver check skipped"
    return 0
  fi

  # Reproduce the daemon's environment: scrub PATH (no brew), keep HOME (launchd
  # sets HOME for user agents). No LCARS_PYTHON/AITEAMFORGE_PYTHON override, so
  # this exercises the real absolute-path probe chain (XACA-0713 fix #2).
  local resolved
  resolved="$(env -i HOME="${HOME:-/tmp}" PATH=/usr/bin:/bin bash -c "source '${helpers}' >/dev/null 2>&1; resolve_lcars_python" 2>/dev/null || true)"

  if [ -z "$resolved" ]; then
    check_result warn "Daemon-context resolver returned nothing — cannot assess LCARS python" \
      "Provision the venv: brew postinstall aiteamforge"
    return 0
  fi

  # XACA-0728 review (PR #634): a SLASH-LESS result (e.g. bare "python3") is
  # resolve_lcars_python's last-resort fallback — it means NO venv was located,
  # so on a consumer under launchd this resolves via PATH to the system python3
  # (3.9) and crashes server.py. That is the XACA-0713 failure, not a soft WARN.
  # The explicit "/usr/bin/python3" branch below catches the case where PATH
  # happens to give an absolute system path; this catches the bare-name fallback.
  case "$resolved" in
    */*) : ;;  # has a slash — real (absolute) path, fall through to the checks below
    *)
      check_result fail "Daemon-context resolver fell through to bare '${resolved}' (PATH-dependent — system python on a consumer); venv not found (XACA-0713)" \
        "The venv must resolve by absolute path under launchd. Run: brew postinstall aiteamforge"
      return 0
      ;;
  esac

  if [ ! -x "$resolved" ]; then
    check_result warn "Daemon-context resolver returned a non-executable path: ${resolved}" \
      "Provision the venv: brew postinstall aiteamforge"
    return 0
  fi

  if [ "$resolved" = "/usr/bin/python3" ]; then
    check_result fail "Daemon-context resolver returns SYSTEM python3 — LCARS will crash on auto-restart (XACA-0713)" \
      "The launchd health daemon has no brew on PATH; the venv must resolve by absolute path. Run: brew postinstall aiteamforge"
    return 0
  fi

  local pv maj min
  pv="$("$resolved" -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null || true)"
  maj="${pv%%.*}"; min="${pv#*.}"; maj="${maj:-0}"; min="${min:-0}"
  if [ "$maj" -gt 3 ] 2>/dev/null || { [ "$maj" -eq 3 ] && [ "$min" -ge 10 ]; } 2>/dev/null; then
    check_result pass "Daemon-context LCARS python is ${pv} (>=3.10) — ${resolved}"
  else
    check_result fail "Daemon-context LCARS python is ${pv:-unknown} (<3.10) — server.py will crash (XACA-0713)" \
      "Provision the 3.10+ venv: brew postinstall aiteamforge"
  fi
}

# Check: LaunchAgents
check_launchagents() {
  print_section "Checking LaunchAgents"

  local working_dir
  working_dir=$(get_working_dir)

  local launchagents_dir="${LAUNCHAGENTS_DIR:-$HOME/Library/LaunchAgents}"

  # XACA-0734: MANDATORY plist presence.
  #
  # The per-agent checks below only ask "is it LOADED?", which quietly conflates
  # two very different states: "the plist exists but launchd has not loaded it"
  # (a warning — a re-login fixes it) and "the plist does not exist at all" (a
  # real failure — nothing will ever load it, and upgrade used to skip absent
  # plists, so it would never come back). The second case is how M1Pro ended up
  # with no auto-upgrade agent and no way to ever get one. Surface it as a FAILURE
  # with an actionable fix, not silence.
  #
  # An agent with a recorded opt-out is SUPPOSED to be absent — that is a pass,
  # not a problem. Absence is only a defect when nobody asked for it.
  #
  # ...and neither is it a defect on an install that RECORDED, at setup time, that
  # it has no LaunchAgents at all (XACA-0734 review, BLOCKING 1). Without this
  # gate `aiteamforge doctor` would turn RED with three FAILs on a perfectly
  # healthy cockpit box — while bin/aiteamforge-doctor.sh (check_services) calls
  # that identical state a PASS. Two doctors contradicting each other on the same
  # machine is worse than either verdict alone: it makes both untrustworthy.
  # Keep this consistent with bin/aiteamforge-doctor.sh, which now shares this gate.
  local _mandatory_applicable=true
  if ! _xaca0734_launchagents_applicable "$working_dir"; then
    _mandatory_applicable=false
    check_result pass "Mandatory LaunchAgents not applicable ($(_xaca0734_launchagents_skip_reason "$working_dir"))"
  fi

  local _agent
  if [ "$_mandatory_applicable" = true ]; then
    for _agent in $(_xaca0734_mandatory_launchagent_basenames); do
      if [ -f "${launchagents_dir}/${_agent}" ]; then
        continue
      fi
      if _xaca0734_is_opted_out "$_agent"; then
        check_result pass "${_agent} absent (opted out — intentional)"
        continue
      fi
      check_result fail "Mandatory LaunchAgent missing: ${launchagents_dir}/${_agent}"
      if [ "$VERBOSE" = true ]; then
        echo "    Fix: aiteamforge upgrade   (re-materializes mandatory LaunchAgents)"
        echo "    Or:  aiteamforge doctor --fix"
      fi
      # XACA-0734: always print the opt-out escape hatch (not VERBOSE-gated) —
      # this IS the "report a missing mandatory agent" moment the hint exists for,
      # mirroring update_launchagents' materialize path. No new CLI subcommand;
      # the sentinel is a plain user-editable file (see lib/launchagents.sh).
      _xaca0734_print_optout_hint "$_agent"
    done
  fi

  # Per-agent LOADED checks.
  #
  # XACA-0734 review #2: these are strictly about "the plist exists but launchd
  # has not loaded it" (a warning — a re-login fixes it). The "no plist at all"
  # case is ALREADY reported, with far better remediation, by the mandatory-presence
  # loop above. Reporting it a second time here as "not loaded" double-counted a
  # single defect: one missing plist produced a FAIL *and* a WARN, which inflates
  # the doctor's failure count and reads like two unrelated problems.
  # So: only warn about not-loaded when the plist is actually THERE — matching the
  # `elif [ -f ... ]` idiom the fleet-reporter and cr-poller checks below already use.
  local _kb_plist="${launchagents_dir}/com.aiteamforge.kanban-backup.plist"
  if _xaca0734_launchctl_is_loaded "com.aiteamforge.kanban-backup"; then
    check_result pass "Kanban backup LaunchAgent loaded"
  elif [ -f "$_kb_plist" ]; then
    check_result warn "Kanban backup LaunchAgent not loaded"
    if [ "$VERBOSE" = true ]; then
      echo "    Load: launchctl load ${_kb_plist}"
    fi
  fi

  # LCARS health agent
  local _lh_plist="${launchagents_dir}/com.aiteamforge.lcars-health.plist"
  if _xaca0734_launchctl_is_loaded "com.aiteamforge.lcars-health"; then
    check_result pass "LCARS health LaunchAgent loaded"
  elif [ -f "$_lh_plist" ]; then
    check_result warn "LCARS health LaunchAgent not loaded"
    if [ "$VERBOSE" = true ]; then
      echo "    Load: launchctl load ${_lh_plist}"
    fi
  fi
  # XACA-0585: script the LaunchAgent invokes must exist; missing = exit 127 on every tick
  # XACA-0651: resolve via get_working_dir — bare ${AITEAMFORGE_DIR} is unset in the
  # doctor context on consumers, which collapsed the path to /lcars-health-check.sh
  # (root) and produced a false FAILURE even when the script was installed correctly.
  if [ -f "${working_dir}/lcars-health-check.sh" ]; then
    check_result pass "LCARS health check script present"
  else
    check_result fail "LCARS health check script missing: ${working_dir}/lcars-health-check.sh"
    if [ "$VERBOSE" = true ]; then
      echo "    Fix: aiteamforge setup  (re-runs the installer lay-down)"
      echo "    Note: 'aiteamforge upgrade' will NOT create a missing script — update_aux_scripts skips absent targets."
    fi
  fi

  # Fleet reporter agent
  if _xaca0734_launchctl_is_loaded "com.aiteamforge.fleet-reporter"; then
    check_result pass "Fleet reporter LaunchAgent loaded"
  elif [ -f "$HOME/Library/LaunchAgents/com.aiteamforge.fleet-reporter.plist" ]; then
    check_result warn "Fleet reporter LaunchAgent not loaded"
    if [ "$VERBOSE" = true ]; then
      echo "    Load: launchctl load ~/Library/LaunchAgents/com.aiteamforge.fleet-reporter.plist"
    fi
  fi

  # CR Confluence Poller agent (XACA-0328-003)
  if _xaca0734_launchctl_is_loaded "com.aiteamforge.cr-confluence-poller"; then
    check_result pass "CR Confluence Poller LaunchAgent loaded"
  elif [ -f "$HOME/Library/LaunchAgents/com.aiteamforge.cr-confluence-poller.plist" ]; then
    check_result warn "CR Confluence Poller LaunchAgent not loaded"
    if [ "$VERBOSE" = true ]; then
      echo "    Load: launchctl load ~/Library/LaunchAgents/com.aiteamforge.cr-confluence-poller.plist"
    fi
  fi
}

# Check: Git Repositories
check_git() {
  print_section "Checking Git Repositories"

  local working_dir
  working_dir=$(get_working_dir)

  # Main aiteamforge repo
  # XACA-0651: the git-repo checks are dev-source-of-truth-centric. A consumer tap
  # install lays down ${working_dir} (e.g. ~/aiteamforge) as a plain product dir with
  # NO .git — that is expected and healthy, not a fault. Only the dev checkout
  # (~/dev-team) is a git repo, so gate the clean/dirty checks on .git presence and
  # emit an informational note on consumers instead of a spurious warning.
  if [ -d "${working_dir}/.git" ]; then
    check_result pass "Dev-team git repository"

    # Check repo status
    cd "${working_dir}"
    if git status --porcelain 2>/dev/null | grep -q .; then
      check_result warn "Dev-team repo has uncommitted changes"
    else
      check_result pass "Dev-team repo clean"
    fi
  else
    print_info "Consumer install (${working_dir} is not a git checkout) — dev-repo checks skipped"
  fi

  # Check for worktrees
  if [ -d "${working_dir}/worktrees" ]; then
    local worktree_count
    worktree_count=$(find "${working_dir}/worktrees" -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    worktree_count=$((worktree_count - 1)) # Subtract parent dir
    if [ "$VERBOSE" = true ] && [ "$worktree_count" -gt 0 ]; then
      echo "    Active worktrees: ${worktree_count}"
    fi
  fi
}

# Check: Network Connectivity
check_network() {
  print_section "Checking Network Connectivity"

  # Internet connectivity
  if ping -c 1 -t 5 8.8.8.8 &>/dev/null; then
    check_result pass "Internet connectivity"
  else
    check_result warn "No internet connectivity"
  fi

  # Tailscale (check CLI in PATH, Homebrew, and macOS app)
  local ts_cmd=""
  if command -v tailscale &>/dev/null; then
    ts_cmd="tailscale"
  elif [ -x "/opt/homebrew/bin/tailscale" ]; then
    ts_cmd="/opt/homebrew/bin/tailscale"
  elif [ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]; then
    ts_cmd="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  fi

  if [ -n "$ts_cmd" ]; then
    if "$ts_cmd" status &>/dev/null 2>&1; then
      check_result pass "Tailscale connected"
      if [ "$VERBOSE" = true ]; then
        "$ts_cmd" status --peers=false 2>/dev/null | head -n3 || true
      fi
    else
      check_result warn "Tailscale not connected"
    fi
  fi
}

# Check: Disk Space
check_disk() {
  print_section "Checking Disk Space"

  local working_dir
  working_dir=$(get_working_dir)

  # Get disk space for aiteamforge directory
  local disk_usage
  disk_usage=$(du -sh "${working_dir}" 2>/dev/null | awk '{print $1}')
  check_result pass "Dev-team disk usage: ${disk_usage}"

  # Check available space
  local available_space
  available_space=$(df -h "${working_dir}" | awk 'NR==2 {print $4}')
  check_result pass "Available disk space: ${available_space}"

  # Warn if less than 1GB available
  local available_gb
  available_gb=$(df -g "${working_dir}" | awk 'NR==2 {print $4}')
  if [ "$available_gb" -lt 1 ]; then
    check_result warn "Low disk space (less than 1GB available)"
  fi

  # Check kanban backups
  if [ -d "${working_dir}/kanban-backups" ]; then
    local backup_count
    backup_count=$(find "${working_dir}/kanban-backups" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$VERBOSE" = true ]; then
      echo "    Kanban backups: ${backup_count}"
    fi
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# First-launch preflight self-heal (XACA-0655-004)
#
# Runs ONLY the fast/critical subset (the things that brick first use):
#   - venv + iterm2 real import
#   - board resolution + stub-collision
#   - server durability
# Auto-applies SAFE remediations SILENTLY (FIX=true was set by --preflight),
# logs one line per action to ~/.aiteamforge/logs/doctor-preflight.log, prints
# at most a concise one-line summary, and NEVER blocks (always exit 0).
# Deliberately SKIPS the slow network/disk/git suite.
# ─────────────────────────────────────────────────────────────────────────────
if [ "$PREFLIGHT" = true ]; then
  _preflight_log_dir="${HOME}/.aiteamforge/logs"
  mkdir -p "$_preflight_log_dir" 2>/dev/null || true
  _preflight_log="${_preflight_log_dir}/doctor-preflight.log"
  _preflight_ts="$(date '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || echo '?')"

  # Run the critical subset with ALL human-facing check output suppressed; the
  # remediation engine still appends to REMEDIATION_LOG, which we persist below.
  {
    check_python_venv
    check_lcars_python_runtime
    check_board_resolution
    check_services
  } >/dev/null 2>&1 || true

  # Persist results (append). Header line + each remediation action.
  {
    echo "=== doctor preflight ${_preflight_ts} (v${VERSION}) ==="
    echo "checks: pass=${PASSED_CHECKS} warn=${WARNING_CHECKS} fail=${FAILED_CHECKS}"
    if [ -n "$REMEDIATION_LOG" ]; then
      printf '%s' "$REMEDIATION_LOG"
    else
      echo "no remediation needed"
    fi
  } >> "$_preflight_log" 2>/dev/null || true

  # One concise line to the user — never block, never spam.
  if [ "$FAILED_CHECKS" -eq 0 ] && [ -z "$REMEDIATION_LOG" ]; then
    : # healthy + nothing applied → stay silent (near-no-op first launch)
  else
    # grep -c emits "0" AND exits 1 when there are no matches. Under
    # `set -eo pipefail` a failing command-substitution in an assignment aborts
    # the whole script, so the `|| true` is REQUIRED (not cosmetic). head -1
    # collapses any stray multi-line output to a single clean integer.
    _applied=$(printf '%s\n' "$REMEDIATION_LOG" | grep -c '^\[fix\]' | head -1) || true
    _manual=$(printf '%s\n' "$REMEDIATION_LOG" | grep -c '^\[manual\]' | head -1) || true
    _applied="${_applied:-0}"; _manual="${_manual:-0}"
    print_info "aiteamforge preflight: ${_applied} auto-fix(es) applied, ${_manual} manual item(s) — see ${_preflight_log}"
    # Surface any RISKY/manual items inline so the user can act.
    if [ "$_manual" -gt 0 ]; then
      printf '%s' "$REMEDIATION_LOG" | grep '^\[manual\]' || true
    fi
  fi
  exit 0
fi

# Run checks based on component
case "$CHECK_COMPONENT" in
  dependencies)
    check_dependencies
    ;;
  tap-trust)
    check_tap_trust
    ;;
  python-venv)
    check_python_venv
    ;;
  framework)
    check_framework
    ;;
  version-drift)
    check_version_drift
    ;;
  config)
    check_config
    ;;
  board)
    check_board_resolution
    ;;
  connect)
    check_connect_scripts
    ;;
  services)
    check_services
    ;;
  lcars-port-drift)
    check_lcars_port_drift
    ;;
  lcars-python-runtime)
    check_lcars_python_runtime
    ;;
  launchagents)
    check_launchagents
    ;;
  git)
    check_git
    ;;
  network)
    check_network
    ;;
  disk)
    check_disk
    ;;
  all)
    check_dependencies
    check_tap_trust
    check_python_venv
    check_framework
    check_version_drift
    check_config
    check_board_resolution
    check_connect_scripts
    check_services
    check_lcars_port_drift
    check_lcars_python_runtime
    check_launchagents
    check_git
    check_network
    check_disk
    ;;
  *)
    print_error "Unknown component: ${CHECK_COMPONENT}"
    usage
    exit 1
    ;;
esac

# Summary
echo ""
print_section "Summary"
echo "Total checks:    ${TOTAL_CHECKS}"
print_color "${COLOR_SUCCESS}" "Passed:          ${PASSED_CHECKS}"
print_color "${COLOR_WARNING}" "Warnings:        ${WARNING_CHECKS}"
print_color "${COLOR_ERROR}" "Failed:          ${FAILED_CHECKS}"
echo ""

# Overall status
if [ $FAILED_CHECKS -eq 0 ]; then
  if [ $WARNING_CHECKS -eq 0 ]; then
    print_success "All checks passed - aiteamforge is healthy!"
    exit 0
  else
    print_warning "Some warnings detected - aiteamforge should work but has minor issues"
    exit 1
  fi
else
  print_error "Some checks failed - aiteamforge may not function correctly"
  echo ""
  if [ "$FIX" = true ]; then
    # XACA-0655-003: real remediation. SAFE fixes were auto-applied INLINE at
    # each failing check above (attempt_remediation <kind> --apply). RISKY ones
    # (config/board rewrites via `aiteamforge setup`) were print-only.
    if [ -n "$REMEDIATION_LOG" ]; then
      print_section "Remediation Summary (--fix)"
      printf '%s' "$REMEDIATION_LOG"
      echo ""
      print_info "SAFE fixes applied automatically; lines tagged [manual] require you to run them."
      print_info "Re-run 'aiteamforge doctor' to confirm the issues are resolved."
    else
      print_info "No auto-remediable issues detected for the failures above."
      print_info "Run: aiteamforge setup  (if config/board needs provisioning)"
    fi
  else
    print_info "Run with --fix to auto-apply SAFE remediations (venv, keepalive, server)"
    print_info "Or run: aiteamforge setup  (for config/board provisioning)"
  fi
  exit 2
fi
