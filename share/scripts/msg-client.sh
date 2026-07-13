#!/usr/bin/env bash

#
#  msg-client.sh
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

# Tier-2 sealed cross-machine transport for kb-msg (XACA-0777) — thin wrapper.
#
# All real work lives in msg-client.js; this wrapper locates node, ensures the
# client's libsodium-wrappers dependency is installed (into the client dir's own
# node_modules — never the server's), and forwards arguments.
#
# Usage:
#   ./msg-client.sh send --to <team[:terminal]> --machine <slug> \
#                        --from-team <t> --from-terminal <t> --body <text> [--server <url>]
#   ./msg-client.sh pull [--machine <slug>] [--server <url>]

# Ensure PATH includes common locations (cron/launchd have a minimal PATH).
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_JS="$SCRIPT_DIR/msg-client.js"

if ! command -v node >/dev/null 2>&1; then
    echo "Error: node not found on PATH. Install Node.js >= 18 and retry." >&2
    exit 127
fi

if [ ! -f "$CLIENT_JS" ]; then
    echo "Error: msg-client.js not found next to this wrapper ($CLIENT_JS)." >&2
    exit 1
fi

# Ensure libsodium-wrappers is installed for the client (same policy as
# vault-fetch.sh — install into the client dir, not the server's tree).
if [ ! -d "$SCRIPT_DIR/node_modules/libsodium-wrappers" ]; then
    if [ "${MSG_CLIENT_NO_AUTO_INSTALL:-0}" = "1" ]; then
        echo "Error: libsodium-wrappers not installed and auto-install disabled." >&2
        echo "       Run: (cd \"$SCRIPT_DIR\" && npm install)" >&2
        exit 1
    fi
    echo "Installing client dependencies (libsodium-wrappers) ..." >&2
    ( cd "$SCRIPT_DIR" && npm install --no-audit --no-fund --silent >&2 )
fi

exec node "$CLIENT_JS" "$@"
