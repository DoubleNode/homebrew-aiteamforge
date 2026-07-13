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
#
# XACA-0702: the config "version" value is stamped ONCE at install time and is
# never updated by `brew upgrade`, so `aiteamforge status` showed a stale version
# (e.g. 0.11.6) long after the box advanced. Prefer the freshest accurate source:
#   1. The live brew version when installed via brew (`brew list --versions`).
#   2. The working-dir .installed-version stamp written by the upgrade flow
#      (XACA-0578/0702) — accurate on non-brew installs and a fast brew fallback.
#   3. The legacy config "version" value.
# Each source is guarded (brew may be absent; files may not exist). Returns a
# single trimmed token; "unknown" only if every source fails.
#
# Shared lib consumed by aiteamforge-status.sh / aiteamforge-doctor.sh /
# aiteamforge-upgrade.sh — all callers expect a single version token on stdout,
# which this still returns; the change is purely which source wins.
get_installed_version() {
  local v=""

  # Source 1: live brew version (only meaningful if installed via brew).
  if command -v brew >/dev/null 2>&1; then
    if brew list aiteamforge >/dev/null 2>&1; then
      local brew_line
      brew_line="$(brew list --versions aiteamforge 2>/dev/null || true)"
      if [ -n "$brew_line" ]; then
        # Last whitespace-delimited field = installed version token.
        v="${brew_line##* }"
      fi
    fi
  fi

  # Source 2: working-dir .installed-version stamp.
  if [ -z "$v" ]; then
    local stamp_dir stamp_file
    stamp_dir="${AITEAMFORGE_DIR:-$HOME/aiteamforge}"
    stamp_file="${stamp_dir}/.installed-version"
    if [ -f "$stamp_file" ]; then
      v="$(tr -d '[:space:]' < "$stamp_file" 2>/dev/null || true)"
    fi
  fi

  # Source 3: legacy config value.
  if [ -z "$v" ]; then
    v="$(get_config_value "version" 2>/dev/null || true)"
  fi

  if [ -n "$v" ]; then
    echo "$v"
  else
    echo "unknown"
  fi
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

# Resolve a team's registry INSTANCE id from its configured BASE id.
#
# `.teams[]` stores base ids ("finance"), but the canonical port registry
# (team-paths.json) keys profile-scoped teams by instance id ("finance-personal").
# Callers that look a team up in the registry MUST map through this first, or those
# teams miss the registry entirely and get silently skipped (XACA-0792).
#
# SINGLE AUTHORITY (XACA-0792-003). `get_board_id()` in kanban-paths.sh is THE
# deterministic base→instance map and this helper DEFERS to it — it must never
# contradict it, and deliberately does not re-implement it. An earlier cut of this
# function derived the instance id from `.team_paths[<base>].project_id` alone,
# which made it a THIRD, competing mapper with a DIFFERENT derivation — and a wrong
# one: legal's TEAM_DEFAULT_PROJECT is "default", so it derived the non-existent
# "legal-default". finance ("personal") and medical ("general") only agreed with the
# registry by coincidence.
#
# What this helper adds ON TOP of the canonical map is the one thing a static map
# cannot know: an install whose instance suffix comes from the user's own config
# (e.g. a freelance team on a custom project → freelance-acme). That is the ONLY
# case the project_id derivation is authoritative for.
#
# Returns the base id unchanged for single-instance teams (academy, ios), and
# degrades to the base id — never to empty — when config or jq is unavailable.
get_team_instance_id() {
  local team="$1"
  [ -z "$team" ] && return 1

  # 1. Canonical deterministic map wins whenever it has an opinion.
  if type get_board_id >/dev/null 2>&1; then
    local mapped
    mapped=$(get_board_id "$team" 2>/dev/null || true)
    if [ -n "$mapped" ] && [ "$mapped" != "$team" ]; then
      echo "$mapped"
      return 0
    fi
  fi

  # 2. Otherwise fall back to the install's own project_id, which is the only
  #    source for custom project-scoped teams the static map cannot enumerate.
  local config_file
  config_file=$(get_config_file)

  # No config or no jq: base id is the best available answer.
  if [ ! -f "$config_file" ] || ! command -v jq &>/dev/null; then
    echo "$team"
    return 0
  fi

  local project_id
  project_id=$(jq -r --arg t "$team" '.team_paths[$t].project_id // empty' "$config_file" 2>/dev/null)

  if [ -n "$project_id" ]; then
    # Lowercased to match how the registry + team startup scripts derive the id.
    echo "${team}-$(echo "$project_id" | tr '[:upper:]' '[:lower:]')"
  else
    echo "$team"
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

# Get installed features (returns space-separated list of enabled feature names)
# Features are stored as a JSON array in "installed_features".
# Falls back to deriving the list from the boolean "features" map for configs
# written by older versions of setup that pre-date this field.
get_installed_features() {
  local config_file
  config_file=$(get_config_file)

  if [ ! -f "$config_file" ]; then
    return 1
  fi

  if command -v jq &>/dev/null; then
    # Prefer the explicit installed_features array
    local result
    result=$(jq -r '.installed_features[]? // empty' "$config_file" 2>/dev/null | tr '\n' ' ')
    if [ -n "$result" ]; then
      echo "$result"
      return 0
    fi

    # Fall back: derive from boolean features map (older config format)
    local derived=""
    for feature in shell_environment claude_code_config lcars_kanban fleet_monitor; do
      local val
      val=$(jq -r ".features.\"${feature}\" // false" "$config_file" 2>/dev/null)
      if [ "$val" = "true" ]; then
        derived="${derived}${feature} "
      fi
    done
    echo "${derived% }"
  fi
}

# Get fleet registration status
# Values: "registered" | "pending" | "not_configured"
# Returns "not_configured" if the field is absent (pre-dates this field).
get_fleet_registration_status() {
  local config_file
  config_file=$(get_config_file)

  if [ ! -f "$config_file" ]; then
    return 1
  fi

  if command -v jq &>/dev/null; then
    local reg_status
    reg_status=$(jq -r '.fleet_registration_status // empty' "$config_file" 2>/dev/null)
    if [ -n "$reg_status" ]; then
      echo "$reg_status"
      return 0
    fi

    # Derive from features: if fleet_monitor is true, assume pending (legacy config)
    local fleet_enabled
    fleet_enabled=$(jq -r '.features.fleet_monitor // false' "$config_file" 2>/dev/null)
    if [ "$fleet_enabled" = "true" ]; then
      echo "pending"
    else
      echo "not_configured"
    fi
  else
    # No jq: fall back to grep
    if grep -q '"fleet_registration_status"' "$config_file" 2>/dev/null; then
      grep '"fleet_registration_status"' "$config_file" | sed -E 's/.*"fleet_registration_status": *"([^"]+)".*/\1/' | head -n1
    else
      echo "not_configured"
    fi
  fi
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
