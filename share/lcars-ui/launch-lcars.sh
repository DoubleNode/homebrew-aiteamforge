#!/bin/bash
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

# Open browser after a short delay
if $OPEN_BROWSER; then
    (sleep 1 && open "http://localhost:$PORT") &
fi

# Start the server
cd "$SCRIPT_DIR"
python3 server.py "$PORT"
