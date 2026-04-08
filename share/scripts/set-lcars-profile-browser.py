#!/usr/bin/env python3
"""Set the LCARS Web profile URL for the inline browser tab.

Updates the Dynamic Profile JSON's 'Initial URL' field so the next
LCARS tab created with this profile navigates to the correct URL.

Browser-mode iTerm2 profiles use 'Initial URL' (not 'Initial Text',
not 'Command') to set the page shown in the tab. iTerm2 hot-loads
the DynamicProfiles directory — no restart required after update.

Usage: python3 set-lcars-profile-browser.py <url>
  e.g. python3 set-lcars-profile-browser.py http://localhost:8203
"""
import json
import os
import sys

url = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8080"

PROFILE_FILE = os.path.expanduser(
    "~/Library/Application Support/iTerm2/DynamicProfiles/aiteamforge-lcars.json"
)

if not os.path.isfile(PROFILE_FILE):
    # Profile file missing — create it via create-lcars-profile.py if available
    script_dir = os.path.dirname(os.path.abspath(__file__))
    create_script = os.path.join(script_dir, "create-lcars-profile.py")
    if os.path.isfile(create_script):
        import subprocess
        result = subprocess.run(
            [sys.executable, create_script, url],
            capture_output=True, text=True
        )
        if result.returncode == 0:
            print(result.stdout.strip())
            sys.exit(0)
    print(f"Dynamic profile not found: {PROFILE_FILE}", file=sys.stderr)
    sys.exit(1)

with open(PROFILE_FILE) as f:
    data = json.load(f)

updated = False
for profile in data.get("Profiles", []):
    if profile.get("Name") == "LCARS Web":
        profile["Initial URL"] = url
        updated = True
        break

if not updated:
    print("LCARS Web profile not found in Dynamic Profile file", file=sys.stderr)
    sys.exit(1)

with open(PROFILE_FILE, "w") as f:
    json.dump(data, f, indent=2)

print(f"LCARS Web profile: url={url}")
