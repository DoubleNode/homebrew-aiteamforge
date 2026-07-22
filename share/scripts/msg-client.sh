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
#
# XACA-0796: this runs under fleet-reporter.sh, which a LaunchAgent fires every
# 60s, and whose caller swallows our stderr and exit code entirely
# (`2>/dev/null || true`). So an un-guarded bootstrap failure is invisible AND
# repeats 1440 times a day. Two guards, both cheap:
#   1. npm must actually exist — otherwise fail fast instead of letting the
#      shell emit "npm: command not found" into a void once a minute.
#   2. A failed install writes a cooldown sentinel; subsequent invocations
#      short-circuit until it expires. Without this, a box with no network
#      re-runs a full npm resolution every cycle forever.
# Both are overridable: MSG_CLIENT_NO_AUTO_INSTALL=1 skips the attempt outright,
# and removing the sentinel (or MSG_CLIENT_BOOTSTRAP_COOLDOWN=0) forces a retry.
BOOTSTRAP_SENTINEL="$SCRIPT_DIR/.msg-client-bootstrap-failed"
BOOTSTRAP_COOLDOWN="${MSG_CLIENT_BOOTSTRAP_COOLDOWN:-3600}"

if [ ! -d "$SCRIPT_DIR/node_modules/libsodium-wrappers" ]; then
    if [ "${MSG_CLIENT_NO_AUTO_INSTALL:-0}" = "1" ]; then
        echo "Error: libsodium-wrappers not installed and auto-install disabled." >&2
        echo "       Run: (cd \"$SCRIPT_DIR\" && npm install)" >&2
        exit 1
    fi

    if ! command -v npm >/dev/null 2>&1; then
        echo "Error: npm not found on PATH — cannot bootstrap libsodium-wrappers." >&2
        echo "       Install Node.js/npm, or pre-install deps:" >&2
        echo "       (cd \"$SCRIPT_DIR\" && npm install)" >&2
        exit 127
    fi

    # Honour an unexpired failure sentinel: stay quiet rather than retrying.
    if [ "$BOOTSTRAP_COOLDOWN" -gt 0 ] 2>/dev/null && [ -f "$BOOTSTRAP_SENTINEL" ]; then
        _now=$(date +%s)
        # Portable mtime: BSD stat -f %m, GNU stat -c %Y.
        _stamp=$(stat -f %m "$BOOTSTRAP_SENTINEL" 2>/dev/null \
                 || stat -c %Y "$BOOTSTRAP_SENTINEL" 2>/dev/null \
                 || echo 0)
        if [ $(( _now - _stamp )) -lt "$BOOTSTRAP_COOLDOWN" ]; then
            echo "Error: libsodium-wrappers bootstrap failed recently; in cooldown." >&2
            echo "       Retry sooner: rm '$BOOTSTRAP_SENTINEL'" >&2
            exit 1
        fi
    fi

    echo "Installing client dependencies (libsodium-wrappers) ..." >&2
    if ( cd "$SCRIPT_DIR" && npm install --no-audit --no-fund --silent >&2 ); then
        rm -f "$BOOTSTRAP_SENTINEL"
    else
        # Record the failure so the next cycle backs off instead of retrying.
        : > "$BOOTSTRAP_SENTINEL" 2>/dev/null || true
        echo "Error: npm install failed; backing off for ${BOOTSTRAP_COOLDOWN}s." >&2
        exit 1
    fi
fi

exec node "$CLIENT_JS" "$@"
