#!/usr/bin/env bash
# aiteamforge-paths-init.sh — Bootstrap ~/.aiteamforge/team-paths.json from defaults
#
# XACA-0168-001 — Wave 1: Config schema + loader module
#
# Creates the canonical team-paths config file from the baked-in defaults
# defined in kanban-hooks/aiteamforge_paths.py.  Idempotent: refuses to
# overwrite an existing file unless --force is passed.
#
# This script is standalone — it can be called directly or will be wired into
# the interactive setup wizard (XACA-0168-002) later.
#
# USAGE:
#   bash scripts/aiteamforge-paths-init.sh [--force] [--config /path/to/file]
#   bash scripts/aiteamforge-paths-init.sh --help
#
# OPTIONS:
#   --force           Overwrite an existing config file
#   --config PATH     Write to PATH instead of ~/.aiteamforge/team-paths.json
#   --dry-run         Print the config that would be written without writing it
#   --help / -h       Show this message

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Argument parsing
# ─────────────────────────────────────────────────────────────────────────────

FORCE=0
DRY_RUN=0
CONFIG_PATH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)    FORCE=1; shift ;;
        --dry-run)  DRY_RUN=1; shift ;;
        --config)
            shift
            CONFIG_PATH="$1"
            shift
            ;;
        --help|-h)
            sed -n '/^# USAGE:/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Run with --help for usage." >&2
            exit 1
            ;;
    esac
done

# ─────────────────────────────────────────────────────────────────────────────
# Resolve config path
# ─────────────────────────────────────────────────────────────────────────────

if [[ -z "$CONFIG_PATH" ]]; then
    if [[ -n "${AITEAMFORGE_CONFIG:-}" ]]; then
        CONFIG_PATH="$AITEAMFORGE_CONFIG"
    else
        CONFIG_PATH="${HOME}/.aiteamforge/team-paths.json"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Guard: refuse to overwrite unless --force
# ─────────────────────────────────────────────────────────────────────────────

if [[ -f "$CONFIG_PATH" && "$FORCE" -eq 0 && "$DRY_RUN" -eq 0 ]]; then
    echo "Config already exists at: $CONFIG_PATH"
    echo "Use --force to overwrite, or --dry-run to preview the defaults."
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Locate the Python loader module
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Resolve relative to this script's location in ~/dev-team/scripts/
DEV_TEAM_DIR="$(dirname "$SCRIPT_DIR")"
PYTHON_LOADER="${DEV_TEAM_DIR}/kanban-hooks/aiteamforge_paths.py"

if [[ ! -f "$PYTHON_LOADER" ]]; then
    echo "ERROR: Python loader not found at: $PYTHON_LOADER" >&2
    echo "Make sure you are running from the dev-team repository." >&2
    exit 1
fi

if ! command -v python3 &>/dev/null; then
    echo "ERROR: python3 is required but not found in PATH." >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Generate config JSON via the Python loader's DEFAULT_TEAMS
# ─────────────────────────────────────────────────────────────────────────────

CONFIG_JSON=$(python3 - "$PYTHON_LOADER" <<'PYEOF'
import sys, json
from pathlib import Path
import importlib.util

loader_path = sys.argv[1]
spec = importlib.util.spec_from_file_location("aiteamforge_paths", loader_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

config = {
    "schema_version": mod.SUPPORTED_SCHEMA_VERSION,
    "teams": mod.DEFAULT_TEAMS,
}
print(json.dumps(config, indent=2))
PYEOF
)

# ─────────────────────────────────────────────────────────────────────────────
# Dry-run: just print
# ─────────────────────────────────────────────────────────────────────────────

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "Would write to: $CONFIG_PATH"
    echo "─────────────────────────────────────────────────────"
    echo "$CONFIG_JSON"
    exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# Write config
# ─────────────────────────────────────────────────────────────────────────────

CONFIG_DIR="$(dirname "$CONFIG_PATH")"
mkdir -p "$CONFIG_DIR"

printf '%s\n' "$CONFIG_JSON" > "$CONFIG_PATH"

echo "Created: $CONFIG_PATH"
echo "Teams:"
python3 -c "
import json, sys
config = json.loads(sys.stdin.read())
for team, entry in sorted(config['teams'].items()):
    port = entry.get('lcars_port')
    port_str = f'  (LCARS :{port})' if port else ''
    print(f'  {team:<45} {entry[\"kanban_dir\"]}{port_str}')
" <<< "$CONFIG_JSON"
