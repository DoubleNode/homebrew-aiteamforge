#!/usr/bin/env python3
"""
LCARS iTerm2 Browser Integration

Opens the LCARS Kanban Monitor in iTerm2's built-in browser panel.

Usage:
    python3 iterm-browser.py [port]
"""

import iterm2
import sys
import subprocess
import time
import urllib.request

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
URL = f"http://localhost:{PORT}"

def is_server_running():
    """Check if the LCARS server is running"""
    try:
        urllib.request.urlopen(f"{URL}/api/status", timeout=1)
        return True
    except:
        return False

def start_server():
    """Start the LCARS server in the background"""
    import os
    script_dir = os.path.dirname(os.path.abspath(__file__))
    server_path = os.path.join(script_dir, "server.py")

    subprocess.Popen(
        ["python3", server_path, str(PORT)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True
    )
    time.sleep(2)

async def main(connection):
    """Open LCARS in iTerm2 browser"""
    app = await iterm2.async_get_app(connection)
    window = app.current_terminal_window

    if window is not None:
        # Open the browser tool
        await window.async_open_browser(URL)
        print(f"✅ LCARS opened in iTerm2 browser: {URL}")
    else:
        print("❌ No iTerm2 window found")

if __name__ == "__main__":
    print("🖥️  LCARS iTerm2 Browser Integration")
    print("=" * 50)

    # Ensure server is running
    if not is_server_running():
        print(f"Starting LCARS server on port {PORT}...")
        start_server()

        if is_server_running():
            print("✅ Server started")
        else:
            print("❌ Failed to start server")
            sys.exit(1)
    else:
        print(f"✅ Server already running on port {PORT}")

    # Open in iTerm2 browser
    print(f"Opening {URL} in iTerm2 browser...")
    try:
        iterm2.run_until_complete(main)
    except Exception as e:
        print(f"Note: {e}")
        print(f"\nManual steps:")
        print(f"1. In iTerm2: View → Browser (or press the browser toolbar button)")
        print(f"2. Navigate to: {URL}")
