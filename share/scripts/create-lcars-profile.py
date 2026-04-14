#!/usr/bin/env python3
"""Create the 'LCARS Web' iTerm2 profile if it doesn't exist.

This profile uses iTerm2's built-in browser mode to display web pages
inline in a tab (no external browser needed). Used by team startup
scripts to show the LCARS kanban dashboard.

PREREQUISITE: THE iTerm2 BROWSER PLUGIN
---------------------------------------
iTerm2 3.5+ ships the browser feature as a separately-downloaded
plugin (a WebKit helper component). On a fresh install the plugin is
not present, and iTerm2's Dynamic Profile loader silently drops any
profile declaring 'Custom Command': 'Browser' — the profile appears
tagged internally as 'Profile Type (Phony)' in iTerm2 logs because
no browser handler is loaded. Symptoms: the profile does not appear
in Profiles > Open Profiles, even though the Dynamic Profile JSON is
valid and iTerm2 loads other profiles from the same file.

Fix: install the iTerm2 browser plugin. In the iTerm2 app, look for
the prompt on first use of a Web Browser profile type, or check
iTerm2 Settings for an "Install Browser Plugin" option. Once
installed, this script's Dynamic Profile works on its own — no plist
manipulation or special preferences required.

The aiteamforge-setup.sh installer attempts to warn if the plugin
appears to be missing.

Usage: python3 create-lcars-profile.py [url]
"""

import json
import sys
from pathlib import Path

DYNAMIC_PROFILES_DIR = Path.home() / "Library" / "Application Support" / "iTerm2" / "DynamicProfiles"
PROFILE_FILE = DYNAMIC_PROFILES_DIR / "aiteamforge-lcars.json"

LCARS_WEB_GUID = "AITEAMFORGE-LCARS-WEB-0001-000000000001"
AGENT_PANEL_GUID = "AITEAMFORGE-AGENT-PANEL-0001-000000000001"


def create_profiles(url: str) -> bool:
    """Write LCARS Web + Agent Panel as Dynamic Profiles.

    Minimal delta-key form: iTerm2 merges parent defaults automatically
    at load time. This matches the shape that works on production
    installs (verified against M1Pro and M3Pro setups).
    """
    DYNAMIC_PROFILES_DIR.mkdir(parents=True, exist_ok=True)

    data = {
        "Profiles": [
            {
                "Name": "LCARS Web",
                "Guid": LCARS_WEB_GUID,
                "Custom Command": "Browser",
                "Initial URL": url,
                "Mouse Reporting": True,
                "Tags": ["aiteamforge"],
                "Background Color": {
                    "Alpha Component": 1.0,
                    "Blue Component": 0.0,
                    "Color Space": "sRGB",
                    "Green Component": 0.0,
                    "Red Component": 0.0,
                },
            },
            {
                "Name": "Agent Panel",
                "Guid": AGENT_PANEL_GUID,
                "Mouse Reporting": True,
                "Tags": ["aiteamforge"],
            },
        ]
    }

    PROFILE_FILE.write_text(json.dumps(data, indent=2))
    print(f"Wrote LCARS Web profile: Initial URL={url}")
    print(f"Wrote Agent Panel profile")
    return True


if __name__ == "__main__":
    url = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8080"
    sys.exit(0 if create_profiles(url=url) else 1)
