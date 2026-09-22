#!/usr/bin/env bash

#
#  vault-fetch.sh
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

# Vault Secret Fetch+Decrypt Helper (thin wrapper)
# EPIC-0016 Phase A.4.2 / XACA-0538-004
#
# Fetches a sealed secret from the Fleet Monitor vault delivery endpoint,
# decrypts it locally with the machine's stored private key, and emits the
# plaintext to stdout. All real work lives in vault-fetch.js — this wrapper
# locates node, ensures deps are installed, and forwards arguments.
#
# Usage:
#   ./vault-fetch.sh <engine_slug> <account_slug> [options]
#
# Options (forwarded to vault-fetch.js):
#   --machine-id <slug>   Machine id (default: slugified hostname)
#   --server <url>        Vault base URL. Default: $FLEET_MONITOR_URL, else
#                         .centralServer.apiEndpoint from ~/.aiteamforge/fleet-config.json
#                         (both candidate config paths are tried in turn).
#                         No localhost fallback - unresolvable exits 8.
#                         Non-http(s) schemes and URLs with embedded userinfo are
#                         REJECTED, and also exit 8 (XACA-0972-022).
#   --cache-dir <dir>     Cache directory (default: ~/.aiteamforge/vault-cache)
#   --no-cache            Skip cache read and write; always fetch from server
#   -h, --help            Show help from vault-fetch.js
#
# Exit codes (propagated from vault-fetch.js):
#   0  ok              Plaintext on stdout
#   1  usage error     Bad arguments (incl. malformed engine/account slug)
#   3  not-configured  No keypair on this machine (run vault-keygen.sh first).
#                      This machine is NOT vault-provisioned; the legacy env-var
#                      model is the intended path. NON-retryable.
#   4  unreachable     Server unreachable, timeout, non-2xx other than 404, or
#                      non-JSON (RETRYABLE)
#   5  cache-hit       Fresh cached plaintext on stdout (treat as success)
#   6  decrypt-failed  Ciphertext can't be decrypted on this machine — wrong/rotated
#                      key or sealed to a different machine. NON-retryable: re-provision
#                      / re-seal. Do NOT retry-loop on this code.
#   7  not-found       Server returned HTTP 404 — the secret does NOT exist for this
#                      engine/account, or none is sealed for this machine. This is a
#                      definitive answer from a live server, NOT an unreachable one:
#                      contrast exit 4. NON-retryable: seal the secret first, then
#                      retry. Do NOT retry-loop on this code.
#                      A 404 WITHOUT one of the vault's own documented error codes
#                      is reported as exit 4, NOT 7: any captive portal or proxy
#                      can emit a 404, and only positive evidence that the answer
#                      came from our vault earns the downgrade (XACA-0972-021).
#   8  no-fleet-url    A keypair EXISTS, but no fleet server URL could be resolved
#                      from --server, $FLEET_MONITOR_URL or fleet-config.json (or
#                      the configured one was rejected as unsafe). NON-retryable
#                      until an operator fixes config.
#                      DISTINCT FROM 3 BY CONSTRUCTION: the keypair check runs
#                      BEFORE URL resolution, so reaching 8 proves a keypair is
#                      present. Folding it into 3 told cc-launch "no vault here"
#                      and dropped a vault-provisioned machine out of the
#                      stale-cache tier (XACA-0972-018). A consumer that does not
#                      know code 8 must treat it like 4, never like 3.
#
# IMPORTANT: stdout carries ONLY the plaintext. All diagnostics go to stderr.

# Ensure PATH includes common locations (cron/launchd have a minimal PATH).
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FETCH_JS="$SCRIPT_DIR/vault-fetch.js"

# ── Preconditions ────────────────────────────────────────────────────────────

if ! command -v node >/dev/null 2>&1; then
    echo "Error: node not found on PATH. Install Node.js >= 18 and retry." >&2
    exit 127
fi

if [ ! -f "$FETCH_JS" ]; then
    echo "Error: vault-fetch.js not found next to this wrapper ($FETCH_JS)." >&2
    exit 1
fi

# Ensure libsodium-wrappers is installed for the client. Install into the
# client dir's node_modules so we don't touch the server's dependency tree.
if [ ! -d "$SCRIPT_DIR/node_modules/libsodium-wrappers" ]; then
    if [ "${VAULT_FETCH_NO_AUTO_INSTALL:-0}" = "1" ]; then
        echo "Error: libsodium-wrappers not installed and auto-install disabled." >&2
        echo "       Run: (cd \"$SCRIPT_DIR\" && npm install)" >&2
        exit 1
    fi
    echo "Installing client dependencies (libsodium-wrappers) ..." >&2
    ( cd "$SCRIPT_DIR" && npm install --no-audit --no-fund --silent >&2 )
fi

# ── Run ─────────────────────────────────────────────────────────────────────

# exec replaces the shell process so the exit code from node is the exit code
# of this wrapper — no wrapping, no off-by-one.
exec node "$FETCH_JS" "$@"
