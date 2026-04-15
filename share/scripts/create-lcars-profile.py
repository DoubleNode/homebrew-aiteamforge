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
import plistlib
import subprocess
import sys
from pathlib import Path

DYNAMIC_PROFILES_DIR = Path.home() / "Library" / "Application Support" / "iTerm2" / "DynamicProfiles"
PROFILE_FILE = DYNAMIC_PROFILES_DIR / "aiteamforge-lcars.json"
ITERM_PLIST = Path.home() / "Library" / "Preferences" / "com.googlecode.iterm2.plist"

LCARS_WEB_GUID = "AITEAMFORGE-LCARS-WEB-0001-000000000001"
AGENT_PANEL_GUID = "AITEAMFORGE-AGENT-PANEL-0001-000000000001"


def _quarantine_stale_dynamic_profile_backups() -> None:
    """iTerm2's Dynamic Profile loader scans every file in the
    DynamicProfiles directory, regardless of extension, and parses
    anything that looks like valid JSON. If the user (or a previous
    installer version, or a backup tool) leaves a file named
    'aiteamforge-lcars.json.bak-<timestamp>' alongside the live file,
    iTerm2 loads BOTH, finds the same GUID declared twice, and raises
    a 'Dynamic Profiles Error — GUID collision' dialog on every start.

    Move any aiteamforge-lcars.json.* sibling out of the scan path into
    ~/Documents, preserving the original filename so the user can
    inspect or restore it later. Silent no-op if no backups found.
    """
    if not DYNAMIC_PROFILES_DIR.exists():
        return
    backups = [
        p for p in DYNAMIC_PROFILES_DIR.iterdir()
        if p.name.startswith("aiteamforge-lcars.json.") and p.is_file()
    ]
    if not backups:
        return
    quarantine_dir = Path.home() / "Documents"
    quarantine_dir.mkdir(parents=True, exist_ok=True)
    for b in backups:
        target = quarantine_dir / b.name
        # Avoid clobbering an existing quarantined copy
        counter = 1
        while target.exists():
            target = quarantine_dir / f"{b.name}.{counter}"
            counter += 1
        try:
            b.rename(target)
            print(f"quarantined stale dynamic profile backup: {b.name} → {target}")
        except OSError:
            pass


def _strip_stale_plist_entry() -> None:
    """Self-heal installs that were hit by an earlier workaround which
    injected LCARS Web directly into the plist's 'New Bookmarks'. If the
    GUID exists in both the plist and the Dynamic Profile file, iTerm2
    pops a 'Dynamic Profiles Error — GUID collision' dialog on every
    team startup. Strip the plist copy here so the installer alone can
    clean up, without requiring a team startup to trigger it.
    """
    if not ITERM_PLIST.exists():
        return
    try:
        data = plistlib.loads(ITERM_PLIST.read_bytes())
    except Exception:
        return
    bookmarks = data.get("New Bookmarks", []) or []
    filtered = [
        b for b in bookmarks
        if b.get("Guid") != LCARS_WEB_GUID and b.get("Name") != "LCARS Web"
    ]
    if len(filtered) == len(bookmarks):
        return
    data["New Bookmarks"] = filtered
    tmp = ITERM_PLIST.with_suffix(ITERM_PLIST.suffix + ".aiteamforge.tmp")
    tmp.write_bytes(plistlib.dumps(data))
    tmp.replace(ITERM_PLIST)
    subprocess.run(["killall", "cfprefsd"], check=False, stderr=subprocess.DEVNULL)
    print("cleaned up stale LCARS Web from plist (legacy workaround)")


def create_profiles(url: str) -> bool:
    """Write LCARS Web + Agent Panel as Dynamic Profiles.

    Minimal delta-key form: iTerm2 merges parent defaults automatically
    at load time. This matches the shape that works on production
    installs (verified against M1Pro and M3Pro setups).
    """
    DYNAMIC_PROFILES_DIR.mkdir(parents=True, exist_ok=True)
    _quarantine_stale_dynamic_profile_backups()
    _strip_stale_plist_entry()

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
