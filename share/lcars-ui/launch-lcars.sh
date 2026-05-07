#!/bin/bash

#
#  launch-lcars.sh
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

# ═══════════════════════════════════════════════════════════════════════════════
#   LCARS - Library Computer Access/Retrieval System
#   Kanban Workflow Monitor - Launch Script
#
#   Usage:
#       ./launch-lcars.sh           # Start server and open browser
#       ./launch-lcars.sh --no-open # Start server only
#       ./launch-lcars.sh 9000      # Use custom port
# ═══════════════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${1:-8080}"
OPEN_BROWSER=true

# Check for --no-open flag
if [[ "$1" == "--no-open" ]]; then
    OPEN_BROWSER=false
    PORT="${2:-8080}"
elif [[ "$2" == "--no-open" ]]; then
    OPEN_BROWSER=false
fi

# Check if port is a number
if [[ "$PORT" =~ ^[0-9]+$ ]]; then
    :
else
    PORT=8080
fi

echo ""
echo "  ╔═══════════════════════════════════════════╗"
echo "  ║   LCARS KANBAN MONITOR                    ║"
echo "  ║   Launching on port $PORT                    ║"
echo "  ╚═══════════════════════════════════════════╝"
echo ""

cd "$SCRIPT_DIR"

# Start the ccusage cache collector daemon (foreground mode, in background process).
# Provides /api/usage/current with cached data so heavy ccusage scans don't run on every poll.
COLLECTOR_PID=""
if command -v ccusage >/dev/null 2>&1; then
    python3 ccusage_collector.py --foreground >/dev/null 2>&1 &
    COLLECTOR_PID=$!
    echo "  Usage collector started (PID $COLLECTOR_PID)"
fi

# Tear down the collector on exit so the LCARS server and its monitor stop together.
cleanup() {
    if [[ -n "$COLLECTOR_PID" ]] && kill -0 "$COLLECTOR_PID" 2>/dev/null; then
        kill "$COLLECTOR_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# Open browser after a short delay
if $OPEN_BROWSER; then
    (sleep 1 && open "http://localhost:$PORT") &
fi

# Start the server (foreground)
python3 server.py "$PORT"
