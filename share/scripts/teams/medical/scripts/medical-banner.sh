#!/bin/zsh
# Medical Team Terminal Banner Display Script
# Usage: medical-banner.sh '$SESSION_THEME' '$SESSION_TYPE' '$SESSION_NAME' '$TERMINAL_NUMBER' '$TERMINAL_NAME' '$SESSION_DESCRIPTION' '$SESSION_LOCATION' '$SESSION_DEVELOPER' '$SESSION_ROLE' '$TERMINAL_DESCRIPTION' '$SESSION_CODE'

SESSION_THEME="${1:-Medical Session Theme}"
SESSION_TYPE="${2:-Medical Session Type}"
SESSION_NAME="${3:-Medical Session Name}"
TERMINAL_NUMBER="${4:-Medical Terminal Number}"
TERMINAL_NAME="${5:-Medical Terminal Name}"
SESSION_DESCRIPTION="${6:-Medical Terminal Name}"
SESSION_LOCATION="${7:-MEDICAL SESSION_LOCATION}"
SESSION_DEVELOPER="${8:-Developer Name}"
SESSION_ROLE="${9:-Developer Role}"
TERMINAL_DESCRIPTION="${10:-Specialization Area}"
PASSED_SESSION_CODE="${11}"

# Use passed SESSION_CODE if provided, otherwise construct from type-name
if [ -n "$PASSED_SESSION_CODE" ]; then
    SESSION_CODE="$PASSED_SESSION_CODE"
else
    SESSION_CODE="${SESSION_TYPE}-${SESSION_NAME}"
fi
SESSION_PROMPT="${SESSION_TYPE}_${SESSION_NAME}"
# Simple shortcut code (without project info) for Claude Code command
SESSION_SHORTCUT="${SESSION_TYPE}-${SESSION_NAME}"

# Common colors
BLACK='%F{black}'
WHITE='%F{white}'
GRAY='%F{245}'
RESET='%f%b'
YELLOW='%F{yellow}'
CYAN='%F{cyan}'
GREEN='%F{green}'
RED='%F{red}'
MAGENTA='%F{magenta}'
BLUE='%F{blue}'
BOLD='%B'
DIM='%F{240}'

# Command Red (Diagnostics - Dr. House) - for medical-diagnostics
COMMAND_RED='%F{196}'              # Deep red
COMMAND_RED_BRIGHT='%F{202}'       # Brighter red for highlights

# Operations Gold (Clinical Work) - for medical-oncology, medical-surgery, medical-emergency
OPS_GOLD='%F{178}'                # Mustard gold
OPS_GOLD_DARK='%F{136}'           # Darker gold for contrast

# Sciences Blue (Research & Testing) - for medical-immunology, medical-neurology
SCIENCES_BLUE='%F{25}'             # Deep blue
SCIENCES_BLUE_BRIGHT='%F{33}'      # Brighter blue

if [[ $SESSION_THEME == "COMMAND" ]]
then
THEME_COLOR=$COMMAND_RED
THEME_COLOR_HIGHLIGHT=$COMMAND_RED_BRIGHT
fi
if [[ $SESSION_THEME == "OPERATIONS" ]]
then
THEME_COLOR=$OPS_GOLD
THEME_COLOR_HIGHLIGHT=$OPS_GOLD_DARK
fi
if [[ $SESSION_THEME == "SCIENCES" ]]
then
THEME_COLOR=$SCIENCES_BLUE
THEME_COLOR_HIGHLIGHT=$SCIENCES_BLUE_BRIGHT
fi

# Common strings
HOSTNAME="%m"
USERNAME="%n"
WORKING_PATH="%~"

source ~/dev-team/worktree-helpers.sh 2>/dev/null || true
clear
tmux clear-history -t $SESSION_CODE:$TERMINAL_NUMBER 2>/dev/null

# Terminal title
printf "\e]0;${SESSION_DESCRIPTION} [$SESSION_DEVELOPER]\a"

# Source avatar display helper
source ~/dev-team/scripts/display-agent-avatar.sh

# Display agent avatar
display_agent_avatar "medical" "$SESSION_DEVELOPER"

# Welcome message
print -P "${THEME_COLOR}═══════════════════════════════════════════════════════════${RESET}"
print -P "${WHITE}${BOLD}    ${SESSION_DESCRIPTION}${RESET}"
print -P "${GRAY}    ${SESSION_LOCATION}${RESET}"
print -P "${GRAY}    ${SESSION_DEVELOPER}${RESET}"
print -P "${WHITE}${BOLD}    Role: ${SESSION_ROLE}${RESET}"
_saved=$(_cc_saved_session_label 2>/dev/null)
[[ -n "$_saved" ]] && print -P "${WHITE}${BOLD}    Saved Session: ${RESET}${WHITE}${_saved}${RESET}"
unset _saved
print -P "${WHITE}${BOLD}    Worktree: $(wt-project status-name) - $(wt-project status-code)${RESET}"
print -P "${WHITE}${BOLD}              $(wt-current short)${RESET}"
print -P "${WHITE}              $(wt-project status-short)${RESET}"
print -P "${THEME_COLOR}═══════════════════════════════════════════════════════════${RESET}"
print -P "${GRAY}    Prompt Commands:${RESET}"
print -P "${WHITE}${BOLD}      show_${SESSION_PROMPT}_prompt${RESET}  ${DIM}- Display the full prompt${RESET}"
print -P "${WHITE}${BOLD}      copy_${SESSION_PROMPT}_prompt${RESET}  ${DIM}- Copy prompt to clipboard${RESET}"
print -P "${THEME_COLOR}───────────────────────────────────────────────────────────${RESET}"
print -P ""
print -P "${WHITE}[${THEME_COLOR_HIGHLIGHT}${BOLD}${TERMINAL_NAME}${RESET}${WHITE}] ${TERMINAL_DESCRIPTION}${RESET}"
print -P ""

# Store banner parameters for on-demand redisplay
# These persist in the shell environment after sourcing
_BANNER_SCRIPT="${0:A}"

# XACA-0223: opportunistic self-heal for a stale iTerm2 "C " tab prefix.
# Sourced once at banner init so _onscreen_heal is defined by the time
# onscreen() is invoked. Silent no-op if the helper is missing or we are
# not inside a tmux+iTerm2 context.
if [ -f "${HOME}/dev-team/scripts/onscreen-heal.sh" ]; then
	source "${HOME}/dev-team/scripts/onscreen-heal.sh"
elif [ -f "${HOME}/aiteamforge/scripts/onscreen-heal.sh" ]; then
	source "${HOME}/aiteamforge/scripts/onscreen-heal.sh"
fi
_BANNER_THEME="$SESSION_THEME"
_BANNER_TYPE="$SESSION_TYPE"
_BANNER_NAME="$SESSION_NAME"
_BANNER_NUM="$TERMINAL_NUMBER"
_BANNER_TERM="$TERMINAL_NAME"
_BANNER_DESC="$SESSION_DESCRIPTION"
_BANNER_LOC="$SESSION_LOCATION"
_BANNER_DEV="$SESSION_DEVELOPER"
_BANNER_ROLE="$SESSION_ROLE"
_BANNER_TDESC="$TERMINAL_DESCRIPTION"
_BANNER_CODE="$SESSION_CODE"

# Define onscreen function for on-demand redisplay
onscreen() {
	source "$_BANNER_SCRIPT" "$_BANNER_THEME" "$_BANNER_TYPE" "$_BANNER_NAME" "$_BANNER_NUM" "$_BANNER_TERM" "$_BANNER_DESC" "$_BANNER_LOC" "$_BANNER_DEV" "$_BANNER_ROLE" "$_BANNER_TDESC" "$_BANNER_CODE"
	command -v _onscreen_heal >/dev/null 2>&1 && _onscreen_heal
}
