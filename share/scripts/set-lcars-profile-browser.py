#!/usr/bin/env python3
"""Set the LCARS Web profile URL for the inline browser tab.

Updates the Dynamic Profile JSON's 'Initial URL' field so the next
LCARS tab created with this profile navigates to the correct URL.

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
    print(f"Dynamic profile not found: {PROFILE_FILE}", file=sys.stderr)
    sys.exit(1)

with open(PROFILE_FILE) as f:
    data = json.load(f)

for profile in data.get("Profiles", []):
    if profile.get("Name") == "LCARS Web":
        profile["Initial URL"] = url
        break

with open(PROFILE_FILE, "w") as f:
    json.dump(data, f, indent=2)

print(f"LCARS Web profile: url={url}")
