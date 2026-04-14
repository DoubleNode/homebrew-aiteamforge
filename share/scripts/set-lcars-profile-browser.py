#!/usr/bin/env python3
"""Set the LCARS Web profile URL for the inline browser tab.

Called by team startup scripts to point the LCARS Web iTerm2 profile
at the correct LCARS server port for the team being started.

Updates the Dynamic Profile JSON's 'Initial URL' field so the next
LCARS tab created with this profile navigates to the correct URL.

Also strips any stale LCARS Web entry that may exist in the plist's
'New Bookmarks' — earlier installer versions injected LCARS Web
directly into the plist as a workaround for a suspected Dynamic
Profile loader bug. Having the same GUID in both locations raises an
iTerm2 "GUID collision" error dialog on every team startup, so we
clean up the plist copy here to self-heal affected installs.

Usage: python3 set-lcars-profile-browser.py <url>
  e.g. python3 set-lcars-profile-browser.py http://localhost:8203
"""

import json
import plistlib
import subprocess
import sys
from pathlib import Path

LCARS_WEB_GUID = "AITEAMFORGE-LCARS-WEB-0001-000000000001"
PROFILE_FILE = (
    Path.home()
    / "Library/Application Support/iTerm2/DynamicProfiles/aiteamforge-lcars.json"
)
ITERM_PLIST = Path.home() / "Library/Preferences/com.googlecode.iterm2.plist"


def _update_dynamic_profile_url(url: str) -> bool:
    if not PROFILE_FILE.is_file():
        print(f"Dynamic profile not found: {PROFILE_FILE}", file=sys.stderr)
        return False
    data = json.loads(PROFILE_FILE.read_text())
    for profile in data.get("Profiles", []):
        if profile.get("Name") == "LCARS Web":
            profile["Initial URL"] = url
            break
    else:
        return False
    PROFILE_FILE.write_text(json.dumps(data, indent=2))
    return True


def _strip_stale_plist_entry() -> None:
    """Remove any LCARS Web entry that a previous installer wrote
    directly into 'New Bookmarks'. Silent no-op if nothing to clean."""
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


def main(url: str) -> int:
    _strip_stale_plist_entry()
    if _update_dynamic_profile_url(url):
        print(f"LCARS Web profile: url={url}")
        return 0
    return 1


if __name__ == "__main__":
    url = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8080"
    sys.exit(main(url))
