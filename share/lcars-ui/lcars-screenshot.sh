#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
#   LCARS Screenshot Display for iTerm2
#   Captures the LCARS web UI and displays it inline using imgcat
# ═══════════════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${1:-8080}"
SCREENSHOT="/tmp/lcars-screenshot.png"

# Check for required tools
if ! command -v /Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome &> /dev/null; then
    if ! command -v chromium &> /dev/null; then
        echo "Chrome or Chromium required for screenshots"
        exit 1
    fi
    CHROME="chromium"
else
    CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
fi

# Start server in background if not running
if ! curl -s "http://localhost:$PORT/api/status" > /dev/null 2>&1; then
    echo "Starting LCARS server..."
    python3 "$SCRIPT_DIR/server.py" "$PORT" > /dev/null 2>&1 &
    SERVER_PID=$!
    sleep 2
    STARTED_SERVER=true
else
    STARTED_SERVER=false
fi

# Capture screenshot using headless Chrome
echo "Capturing LCARS display..."
"$CHROME" --headless --disable-gpu --screenshot="$SCREENSHOT" \
    --window-size=1400,900 \
    --hide-scrollbars \
    "http://localhost:$PORT" 2>/dev/null

# Display in iTerm2 using imgcat
if [[ -f "$SCREENSHOT" ]]; then
    if command -v imgcat &> /dev/null; then
        clear
        imgcat "$SCREENSHOT"
    elif [[ -f /usr/local/bin/imgcat ]] || [[ -f ~/.iterm2/imgcat ]]; then
        clear
        ~/.iterm2/imgcat "$SCREENSHOT" 2>/dev/null || /usr/local/bin/imgcat "$SCREENSHOT"
    else
        echo "imgcat not found. Install iTerm2 shell integration:"
        echo "  curl -L https://iterm2.com/shell_integration/install_shell_integration.sh | bash"
        echo ""
        echo "Screenshot saved to: $SCREENSHOT"
    fi
else
    echo "Failed to capture screenshot"
fi

# Cleanup if we started the server
if $STARTED_SERVER; then
    kill $SERVER_PID 2>/dev/null
fi
