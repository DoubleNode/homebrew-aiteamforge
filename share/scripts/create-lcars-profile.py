#!/usr/bin/env python3
"""Create the 'LCARS Web' iTerm2 profile if it doesn't exist.

This profile uses iTerm2's built-in browser mode to display web pages
inline in a tab (no external browser needed). Used by team startup
scripts to show the LCARS kanban dashboard.

Usage: python3 create-lcars-profile.py [url]
"""

import subprocess
import plistlib
import sys
import uuid


def profile_exists(name="LCARS Web"):
    """Check if an iTerm2 profile with the given name exists."""
    result = subprocess.run(
        ["defaults", "export", "com.googlecode.iterm2", "-"],
        capture_output=True
    )
    if result.returncode != 0:
        return False
    data = plistlib.loads(result.stdout)
    for bookmark in data.get("New Bookmarks", []):
        if bookmark.get("Name") == name:
            return True
    return False


def create_profile(name="LCARS Web", url="http://localhost:8080"):
    """Create a minimal LCARS Web browser profile in iTerm2."""
    result = subprocess.run(
        ["defaults", "export", "com.googlecode.iterm2", "-"],
        capture_output=True
    )
    if result.returncode != 0:
        print("Error: Could not read iTerm2 preferences", file=sys.stderr)
        return False

    data = plistlib.loads(result.stdout)
    bookmarks = data.get("New Bookmarks", [])

    # Use Default profile as base if available
    base = {}
    for bookmark in bookmarks:
        if bookmark.get("Name") == "Default":
            base = dict(bookmark)
            break

    # Override with LCARS Web settings
    base["Name"] = name
    base["Guid"] = str(uuid.uuid4()).upper()
    base["Custom Command"] = "Browser"
    base["Command"] = ""
    base["Initial Text"] = url
    base["Tags"] = ["aiteamforge"]

    # Dark background for LCARS theme
    black = {"Alpha Component": 1.0, "Blue Component": 0.0,
             "Color Space": "sRGB", "Green Component": 0.0,
             "Red Component": 0.0}
    base["Background Color"] = black
    base["Background Color (Dark)"] = black
    base["Background Color (Light)"] = black

    bookmarks.append(base)
    data["New Bookmarks"] = bookmarks

    # Write back
    plist_bytes = plistlib.dumps(data)
    result = subprocess.run(
        ["defaults", "import", "com.googlecode.iterm2", "-"],
        input=plist_bytes, capture_output=True
    )
    if result.returncode != 0:
        print(f"Error writing profile: {result.stderr.decode()}", file=sys.stderr)
        return False

    print(f"Created iTerm2 profile: {name}")
    return True


if __name__ == "__main__":
    url = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8080"

    if profile_exists():
        print("LCARS Web profile already exists")
    else:
        if create_profile(url=url):
            print("Note: Restart iTerm2 or open a new window for the profile to appear")
        else:
            sys.exit(1)
