#!/usr/bin/env zsh

# wizard-ui.sh
# LCARS-styled UI helpers for aiteamforge setup wizard
# Provides colors, prompts, banners, progress indicators

# ═══════════════════════════════════════════════════════════════════════════
# LCARS Color Palette
# ═══════════════════════════════════════════════════════════════════════════

# ANSI color codes
readonly COLOR_RESET='\033[0m'
readonly COLOR_BOLD='\033[1m'

# LCARS Primary Colors
readonly COLOR_AMBER='\033[38;5;214m'      # LCARS Amber (orange)
readonly COLOR_BLUE='\033[38;5;33m'        # LCARS Blue
readonly COLOR_RED='\033[38;5;196m'        # LCARS Red (alerts)
readonly COLOR_LILAC='\033[38;5;183m'      # LCARS Lilac (purple)
readonly COLOR_PEACH='\033[38;5;216m'      # LCARS Peach
readonly COLOR_GREEN='\033[38;5;46m'       # Success green

# Semantic colors
readonly COLOR_SUCCESS="${COLOR_GREEN}"
readonly COLOR_ERROR="${COLOR_RED}"
readonly COLOR_WARNING="${COLOR_AMBER}"
readonly COLOR_INFO="${COLOR_BLUE}"
readonly COLOR_ACCENT="${COLOR_LILAC}"

# ═══════════════════════════════════════════════════════════════════════════
# Output Functions
# ═══════════════════════════════════════════════════════════════════════════

# Print colored text
print_color() {
  local color="$1"
  local text="$2"
  echo -e "${color}${text}${COLOR_RESET}"
}

# Print success message
print_success() {
  print_color "${COLOR_SUCCESS}" "✓ $1"
}

# Print error message
print_error() {
  print_color "${COLOR_ERROR}" "✗ $1"
}

# Print warning message
print_warning() {
  print_color "${COLOR_WARNING}" "⚠ $1"
}

# Print info message
print_info() {
  print_color "${COLOR_INFO}" "ℹ $1"
}

# Print header
print_header() {
  local text="$1"
  echo ""
  print_color "${COLOR_AMBER}${COLOR_BOLD}" "═══════════════════════════════════════════════════════════════════════════"
  print_color "${COLOR_AMBER}${COLOR_BOLD}" "  $text"
  print_color "${COLOR_AMBER}${COLOR_BOLD}" "═══════════════════════════════════════════════════════════════════════════"
  echo ""
}

# Print section header
print_section() {
  local text="$1"
  echo ""
  print_color "${COLOR_BLUE}${COLOR_BOLD}" "───────────────────────────────────────────────────────────────────────────"
  print_color "${COLOR_BLUE}${COLOR_BOLD}" "  $text"
  print_color "${COLOR_BLUE}${COLOR_BOLD}" "───────────────────────────────────────────────────────────────────────────"
  echo ""
}

# ═══════════════════════════════════════════════════════════════════════════
# Banner Functions
# ═══════════════════════════════════════════════════════════════════════════

# Display LCARS-styled welcome banner
print_welcome_banner() {
  print_header "STARFLEET DEVELOPMENT ENVIRONMENT - SETUP WIZARD"

  print_color "${COLOR_AMBER}" "Welcome to the AITeamForge environment installer."
  echo ""
  print_color "${COLOR_BLUE}" "This wizard will guide you through setting up:"
  echo "  • Machine identity configuration"
  echo "  • Team assignment and agent configuration"
  echo "  • LCARS Kanban system"
  echo "  • Fleet Monitor (for multi-machine setups)"
  echo "  • Shell environment and terminal integration"
  echo ""
  print_color "${COLOR_LILAC}" "Estimated setup time: 10-15 minutes"
  echo ""
}

# Display completion banner
print_completion_banner() {
  print_header "SETUP COMPLETE"

  print_success "AITeamForge environment has been successfully installed!"
  echo ""
}

# ═══════════════════════════════════════════════════════════════════════════
# Progress Indicators
# ═══════════════════════════════════════════════════════════════════════════

# Display progress bar
# Usage: print_progress <current> <total> <label>
print_progress() {
  local current=$1
  local total=$2
  local label="$3"
  local percent=$(( (current * 100) / total ))
  local filled=$(( (current * 40) / total ))
  local empty=$(( 40 - filled ))

  local bar=""
  for ((i=0; i<filled; i++)); do bar="${bar}█"; done
  for ((i=0; i<empty; i++)); do bar="${bar}░"; done

  print_color "${COLOR_BLUE}" "[$bar] ${percent}% - $label"
}

# Display spinner while command runs
# Usage: run_with_spinner <command> <label>
run_with_spinner() {
  local cmd="$1"
  local label="$2"
  local spinner="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
  local i=0

  # Run command in background (using bash -c to avoid eval injection)
  bash -c "$cmd" &
  local pid=$!

  # Show spinner while running
  while kill -0 $pid 2>/dev/null; do
    local frame="${spinner:$i:1}"
    printf "\r${COLOR_BLUE}${frame}${COLOR_RESET} %s..." "$label"
    i=$(( (i + 1) % ${#spinner} ))
    sleep 0.1
  done

  # Wait for completion and get exit code
  wait $pid
  local exit_code=$?

  # Clear spinner line
  printf "\r"

  if [ $exit_code -eq 0 ]; then
    print_success "$label"
  else
    print_error "$label (failed)"
  fi

  return $exit_code
}

# ═══════════════════════════════════════════════════════════════════════════
# Interactive Prompts
# ═══════════════════════════════════════════════════════════════════════════

# Prompt for yes/no answer
# Usage: prompt_yes_no <question> [default]
# Returns: 0 for yes, 1 for no
prompt_yes_no() {
  local question="$1"
  local default="${2:-n}"
  local prompt="[y/n]"

  if [ "$default" = "y" ]; then
    prompt="[Y/n]"
  elif [ "$default" = "n" ]; then
    prompt="[y/N]"
  fi

  while true; do
    print_color "${COLOR_AMBER}" "$question $prompt"
    read -r answer

    # Use default if empty
    if [ -z "$answer" ]; then
      answer="$default"
    fi

    case "$answer" in
      [Yy]|[Yy][Ee][Ss])
        return 0
        ;;
      [Nn]|[Nn][Oo])
        return 1
        ;;
      *)
        print_error "Please answer 'y' or 'n'"
        ;;
    esac
  done
}

# Prompt for text input
# Usage: prompt_text <question> [default]
# Output: echoes the answer
prompt_text() {
  local question="$1"
  local default="$2"
  local prompt_text="$question"

  if [ -n "$default" ]; then
    prompt_text="$question [${default}]"
  fi

  while true; do
    print_color "${COLOR_AMBER}" "$prompt_text"
    read -r answer

    # Use default if empty
    if [ -z "$answer" ] && [ -n "$default" ]; then
      echo "$default"
      return 0
    fi

    if [ -n "$answer" ]; then
      echo "$answer"
      return 0
    fi

    print_error "Please provide an answer"
  done
}

# Prompt for single selection from list
# Usage: prompt_select <question> <option1> <option2> ...
# Output: echoes the selected option (zero-indexed)
prompt_select() {
  local question="$1"
  shift
  local options=("$@")

  print_color "${COLOR_AMBER}" "$question"
  echo ""

  # Display options
  for i in {1..${#options[@]}}; do
    print_color "${COLOR_BLUE}" "  $i) ${options[$i]}"
  done
  echo ""

  while true; do
    print_color "${COLOR_AMBER}" "Enter choice [1-${#options[@]}]:"
    read -r choice

    # Validate input
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#options[@]} ]; then
      echo $((choice - 1))
      return 0
    fi

    print_error "Invalid choice. Please enter a number between 1 and ${#options[@]}"
  done
}

# Prompt for multiple selections from list
# Usage: prompt_multi_select <question> <option1> <option2> ...
# Output: echoes space-separated list of selected indices (zero-indexed)
prompt_multi_select() {
  local question="$1"
  shift
  local options=("$@")

  print_color "${COLOR_AMBER}" "$question"
  print_color "${COLOR_LILAC}" "(Enter numbers separated by spaces, e.g., '1 3 5')"
  echo ""

  # Display options
  for i in {1..${#options[@]}}; do
    print_color "${COLOR_BLUE}" "  $i) ${options[$i]}"
  done
  echo ""

  while true; do
    print_color "${COLOR_AMBER}" "Enter choices [1-${#options[@]}]:"
    read -r choices

    # Split choices into array
    local selected=()
    local valid=true

    for choice in ${(s: :)choices}; do
      if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#options[@]} ]; then
        selected+=($((choice - 1)))
      else
        print_error "Invalid choice: $choice"
        valid=false
        break
      fi
    done

    if [ "$valid" = true ] && [ ${#selected[@]} -gt 0 ]; then
      echo "${selected[@]}"
      return 0
    fi

    if [ ${#selected[@]} -eq 0 ]; then
      print_error "Please select at least one option"
    fi
  done
}

# ═══════════════════════════════════════════════════════════════════════════
# Status Display
# ═══════════════════════════════════════════════════════════════════════════

# Display installation status
# Usage: print_status <label> <status>
# Status can be: "ok", "missing", "installed", "skipped", "failed"
print_status() {
  local label="$1"
  local status_val="$2"
  local status_text=""
  local color=""

  case "$status_val" in
    ok|installed)
      status_text="✓ OK"
      color="${COLOR_SUCCESS}"
      ;;
    missing)
      status_text="✗ Missing"
      color="${COLOR_ERROR}"
      ;;
    skipped)
      status_text="○ Skipped"
      color="${COLOR_WARNING}"
      ;;
    failed)
      status_text="✗ Failed"
      color="${COLOR_ERROR}"
      ;;
    *)
      status_text="$status_val"
      color="${COLOR_INFO}"
      ;;
  esac

  printf "%-50s " "$label"
  print_color "$color" "$status_text"
}

# ═══════════════════════════════════════════════════════════════════════════
# Utility Functions
# ═══════════════════════════════════════════════════════════════════════════

# Press any key to continue
press_any_key() {
  local prompt="${1:-Press any key to continue...}"
  print_color "${COLOR_LILAC}" "$prompt"
  read -k1 -s
  echo ""
}

# Clear screen and show header
clear_screen() {
  clear
  print_header "AITEAMFORGE SETUP WIZARD"
}

# Display error and exit
die() {
  local message="$1"
  local exit_code="${2:-1}"

  echo ""
  print_error "$message"
  echo ""
  exit "$exit_code"
}

# Export functions for use in other scripts
# (This is a zsh-specific feature; for bash compatibility, you'd use 'export -f')
# In zsh, functions are automatically available to sourced scripts
