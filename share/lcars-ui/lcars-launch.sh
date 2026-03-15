#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
#   LCARS Launch Script
#   Starts server and opens browser
#
#   Usage: ./lcars-launch.sh [port] [team] [session_name]
#
#   Can be used as iTerm2 profile command:
#   Set profile command to: ~/aiteamforge/lcars-ui/lcars-launch.sh 8080 dns dns-lcars
#
#   The team determines which board to load (freelance, dns, ios, etc.)
#   The session_name is used to write a port file for fleet-monitor integration
# ═══════════════════════════════════════════════════════════════════════════════

PORT="${1:-8080}"
TEAM="${2:-freelance}"
SESSION_NAME="${3:-}"
URL="http://localhost:$PORT"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LCARS_PORTS_DIR="$HOME/aiteamforge/lcars-ports"

# Export team for server
export LCARS_TEAM="$TEAM"
export LCARS_SESSION_NAME="${SESSION_NAME:-$TEAM-lcars}"

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║              LCARS KANBAN MONITOR                             ║"
echo "╠═══════════════════════════════════════════════════════════════╣"
echo "║  Team: $TEAM                                                    "
echo "║  Port: $PORT                                                    ║"
echo "║  URL:  $URL                                      ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

# Check if server already running on this port
if curl -s "$URL/api/status" > /dev/null 2>&1; then
    echo "✅ Server already running on port $PORT"
else
    echo "🚀 Starting LCARS server on port $PORT..."
    cd "$SCRIPT_DIR"
    python3 server.py "$PORT" &
    sleep 2

    if curl -s "$URL/api/status" > /dev/null 2>&1; then
        echo "✅ Server started successfully"
    else
        echo "❌ Failed to start server"
        exit 1
    fi
fi

# Write port file for fleet-monitor integration
if [ -n "$SESSION_NAME" ]; then
    mkdir -p "$LCARS_PORTS_DIR"
    echo "$PORT" > "$LCARS_PORTS_DIR/${SESSION_NAME}.port"
    echo "📡 Port file written: ${SESSION_NAME}.port -> $PORT"
fi

echo ""
echo "🌐 Opening browser..."
open "$URL"

echo ""
echo "Server running. Press Ctrl+C to stop."
echo ""

# Keep the script running (so the tab stays open)
wait
