#!/bin/bash
# config.sh
# Shared configuration loader for aiteamforge lifecycle commands
# Provides helpers to read and validate config.json

# Config file location
get_config_file() {
  local dev_team_dir="${AITEAMFORGE_DIR:-$HOME/aiteamforge}"
  echo "${dev_team_dir}/.aiteamforge-config"
}

# Check if aiteamforge is configured
is_configured() {
  local config_file
  config_file=$(get_config_file)
  [ -f "$config_file" ]
}

# Read config value
# Usage: get_config_value <key>
get_config_value() {
  local key="$1"
  local config_file
  config_file=$(get_config_file)

  if [ ! -f "$config_file" ]; then
    return 1
  fi

  if command -v jq &>/dev/null; then
    jq -r ".${key} // empty" "$config_file" 2>/dev/null
  else
    # Fallback if jq not available
    grep "\"${key}\"" "$config_file" | sed -E 's/.*"'${key}'": *"?([^",}]+)"?.*/\1/' | head -n1
  fi
}

# Get installed version
get_installed_version() {
  get_config_value "version"
}

# Get installation date
# Supports both "install_date" (bin/aiteamforge-setup.sh) and "installed_at" (wizard) formats
get_install_date() {
  local result
  result=$(get_config_value "install_date")
  if [ -z "$result" ]; then
    result=$(get_config_value "installed_at")
  fi
  echo "$result"
}

# Get configured teams (returns space-separated list)
get_configured_teams() {
  local config_file
  config_file=$(get_config_file)

  if [ ! -f "$config_file" ]; then
    return 1
  fi

  if command -v jq &>/dev/null; then
    jq -r '.teams[]? // empty' "$config_file" 2>/dev/null | tr '\n' ' '
  else
    # Fallback: extract array values
    grep -A 100 '"teams"' "$config_file" | grep -v '"teams"' | grep '"' | sed 's/.*"\([^"]*\)".*/\1/' | tr '\n' ' '
  fi
}

# Get machine name
# Supports both "machine_name" (bin/aiteamforge-setup.sh) and "machine.name" (wizard) formats
get_machine_name() {
  local result
  result=$(get_config_value "machine_name")
  if [ -z "$result" ]; then
    result=$(get_config_value "machine.name")
  fi
  if [ -z "$result" ]; then
    # Fallback to hostname
    hostname -s 2>/dev/null
  else
    echo "$result"
  fi
}

# Get machine ID
# Falls back to hostname if not set in config
get_machine_id() {
  local result
  result=$(get_config_value "machine_id")
  if [ -z "$result" ]; then
    result=$(get_config_value "machine.id")
  fi
  if [ -z "$result" ]; then
    # Fallback: generate from hostname
    hostname -s 2>/dev/null
  else
    echo "$result"
  fi
}

# Validate config structure
validate_config() {
  local config_file
  config_file=$(get_config_file)

  if [ ! -f "$config_file" ]; then
    echo "Config file not found: $config_file"
    return 1
  fi

  # Check if valid JSON (if jq available)
  if command -v jq &>/dev/null; then
    if ! jq empty "$config_file" 2>/dev/null; then
      echo "Invalid JSON in config file"
      return 1
    fi
  fi

  return 0
}

# Get working directory
get_working_dir() {
  echo "${AITEAMFORGE_DIR:-$HOME/aiteamforge}"
}

# Get framework directory
get_framework_dir() {
  if [ -n "$AITEAMFORGE_HOME" ]; then
    echo "$AITEAMFORGE_HOME"
  elif command -v brew &>/dev/null; then
    echo "$(brew --prefix 2>/dev/null || echo '/opt/homebrew')/opt/aiteamforge/libexec"
  else
    echo "$HOME/aiteamforge-framework"
  fi
}
