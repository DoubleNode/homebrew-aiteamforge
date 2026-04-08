#!/usr/bin/env python3
"""Create the 'LCARS Web' iTerm2 profile if it doesn't exist.

This profile uses iTerm2's built-in browser mode to display web pages
inline in a tab (no external browser needed). Used by team startup
scripts to show the LCARS kanban dashboard.

Uses the Dynamic Profile mechanism (JSON file in DynamicProfiles/) which
is hot-loaded by iTerm2 — no restart required, no plist corruption risk.
The correct key for browser-mode tab URLs is 'Initial URL' (not
'Initial Text', which is for shell-session keystroke injection).

Usage: python3 create-lcars-profile.py [url]
"""

import json
import os
import sys
from pathlib import Path

DYNAMIC_PROFILES_DIR = Path.home() / "Library" / "Application Support" / "iTerm2" / "DynamicProfiles"
PROFILE_FILE = DYNAMIC_PROFILES_DIR / "aiteamforge-lcars.json"

LCARS_WEB_GUID = "AITEAMFORGE-LCARS-WEB-0001-000000000001"
AGENT_PANEL_GUID = "AITEAMFORGE-AGENT-PANEL-0001-000000000001"


def create_profiles(url: str) -> bool:
    """Create or update the LCARS Web Dynamic Profile with the given URL.

    Writes to ~/Library/Application Support/iTerm2/DynamicProfiles/ which
    iTerm2 hot-loads automatically — no restart required.
    """
    DYNAMIC_PROFILES_DIR.mkdir(parents=True, exist_ok=True)

    # Load existing file if present, otherwise start fresh
    if PROFILE_FILE.exists():
        with open(PROFILE_FILE) as f:
            try:
                data = json.load(f)
            except json.JSONDecodeError:
                data = {"Profiles": []}
    else:
        data = {"Profiles": []}

    profiles = data.get("Profiles", [])

    # Update LCARS Web profile if it exists, otherwise create it
    lcars_profile = None
    for p in profiles:
        if p.get("Guid") == LCARS_WEB_GUID or p.get("Name") == "LCARS Web":
            lcars_profile = p
            break

    if lcars_profile is not None:
        lcars_profile["Initial URL"] = url
        lcars_profile["Custom Command"] = "Browser"
        lcars_profile["Guid"] = LCARS_WEB_GUID
        # Remove parent profile reference — causes errors on clean installs
        lcars_profile.pop("Dynamic Profile Parent Name", None)
        print(f"Updated LCARS Web profile: Initial URL={url}")
    else:
        lcars_profile = {
            "Name": "LCARS Web",
            "Guid": LCARS_WEB_GUID,
            "Custom Command": "Browser",
            "Initial URL": url,
            "Tags": ["aiteamforge"],
            "Background Color": {
                "Alpha Component": 1.0,
                "Blue Component": 0.0,
                "Color Space": "sRGB",
                "Green Component": 0.0,
                "Red Component": 0.0,
            },
        }
        profiles.append(lcars_profile)
        print(f"Created LCARS Web profile: Initial URL={url}")

    # Ensure Agent Panel profile exists (no URL update — it has its own router)
    agent_profile_exists = any(
        p.get("Guid") == AGENT_PANEL_GUID or p.get("Name") == "Agent Panel"
        for p in profiles
    )
    if not agent_profile_exists:
        profiles.append({
            "Name": "Agent Panel",
            "Guid": AGENT_PANEL_GUID,
            "Tags": ["aiteamforge"],
        })

    # Strip parent profile references from ALL profiles (causes errors on clean installs)
    for p in profiles:
        p.pop("Dynamic Profile Parent Name", None)

    data["Profiles"] = profiles

    with open(PROFILE_FILE, "w") as f:
        json.dump(data, f, indent=2)

    return True


if __name__ == "__main__":
    url = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8080"

    if create_profiles(url=url):
        print(f"Dynamic profile written: {PROFILE_FILE}")
    else:
        sys.exit(1)
