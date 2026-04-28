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

Environment:
  LCARS_PROFILE_RELOAD_WAIT  Override the post-write pause before iTerm2
                             has had time to rescan DynamicProfiles/.
                             Default 1.5s. Range [0.0, 10.0]. Set to 0
                             to skip the wait entirely (useful in tests).
"""

import json
import os
import plistlib
import subprocess
import sys
import time
from pathlib import Path

LCARS_WEB_GUID = "AITEAMFORGE-LCARS-WEB-0001-000000000001"
PROFILE_FILE = (
    Path.home()
    / "Library/Application Support/iTerm2/DynamicProfiles/aiteamforge-lcars.json"
)
ITERM_PLIST = Path.home() / "Library/Preferences/com.googlecode.iterm2.plist"

_RELOAD_WAIT_DEFAULT = 1.5
_RELOAD_WAIT_MIN = 0.0
_RELOAD_WAIT_MAX = 10.0


def _update_dynamic_profile_url(url: str) -> bool:
    """Update the 'Initial URL' field of the 'LCARS Web' Dynamic Profile.

    Returns True on success, False on any failure (with a 🚨-prefixed
    message written to stderr for every distinct failure mode so callers
    and users can diagnose without guessing).

    Write is atomic: we write to a .aiteamforge.tmp sibling and rename
    over the target so iTerm2 never reads a half-written file.

    After the atomic rename we re-read the file and verify the URL
    landed correctly.  If the readback doesn't match we report a loud
    error and return False rather than silently continuing.
    """
    if not PROFILE_FILE.is_file():
        print(
            f"🚨 Dynamic profile JSON missing: {PROFILE_FILE}",
            file=sys.stderr,
        )
        return False

    try:
        data = json.loads(PROFILE_FILE.read_text())
    except json.JSONDecodeError as exc:
        print(
            f"🚨 Dynamic profile JSON corrupt: {PROFILE_FILE}: {exc}",
            file=sys.stderr,
        )
        return False

    for profile in data.get("Profiles", []):
        if profile.get("Name") == "LCARS Web":
            profile["Initial URL"] = url
            break
    else:
        print(
            f'🚨 "LCARS Web" profile missing from {PROFILE_FILE}',
            file=sys.stderr,
        )
        return False

    # Atomic write: temp file + rename so iTerm2 never reads a partial file.
    tmp = PROFILE_FILE.with_suffix(PROFILE_FILE.suffix + ".aiteamforge.tmp")
    try:
        tmp.write_text(json.dumps(data, indent=2))
        tmp.replace(PROFILE_FILE)  # atomic on POSIX
    except Exception as exc:
        print(
            f"🚨 Failed to write Dynamic profile JSON: {exc}",
            file=sys.stderr,
        )
        tmp.unlink(missing_ok=True)
        return False

    # Readback verification: confirm our write landed correctly.
    try:
        written = json.loads(PROFILE_FILE.read_text())
    except Exception as exc:
        print(
            f"🚨 Failed to read back Dynamic profile JSON after write: {exc}",
            file=sys.stderr,
        )
        return False

    actual_url = None
    for profile in written.get("Profiles", []):
        if profile.get("Name") == "LCARS Web":
            actual_url = profile.get("Initial URL")
            break

    if actual_url != url:
        print(
            f"🚨 Readback mismatch after write — expected {url!r}, got {actual_url!r}",
            file=sys.stderr,
        )
        return False

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


def _wait_for_iterm2_reload(reload_delay_seconds: float = _RELOAD_WAIT_DEFAULT) -> None:
    """Sleep briefly so iTerm2 has time to rescan DynamicProfiles/ and
    pick up the URL change before the caller creates a new tab.

    --- Why we can't do better than a fixed wait ---

    Option A: Poll the iTerm2 Python API for profile field changes.
    DEAD END. iterm2.PartialProfile.async_query() returns all profiles
    but NEVER exposes the 'Initial URL' field — it is a Dynamic-Profile-
    only field that is not reflected in the API. There is nothing to poll.

    Option B: Watch DynamicProfiles/ with FSEvents for an iTerm2 touch.
    DEAD END. iTerm2 reads the file silently; it does not write any
    observable file-system signal on reload. FSEvents on the directory
    would only see the write WE just did, not any iTerm2 response.

    Option C: Fixed wait calibrated to iTerm2's rescan interval.
    CHOSEN. iTerm2 rescans DynamicProfiles/ on an undocumented internal
    timer. Community observations (iTerm2 GitHub issues, forum posts)
    place the interval at 0.5–2 seconds. 1.5 seconds sits in the middle
    of that band and gives a comfortable margin without making startup
    feel sluggish.

    This is a CONSTRAINT, not laziness. If you are tempted to replace
    this with an iTerm2 API poll, read the XACA-0225-001 research notes
    first — they document why the API cannot satisfy this requirement.

    The wait can be tuned via the LCARS_PROFILE_RELOAD_WAIT env var
    (float seconds, clamped to [0.0, 10.0]). Setting it to exactly 0
    skips the sleep entirely, which is useful in automated tests.
    """
    if reload_delay_seconds == 0.0:
        print("reload wait skipped (delay=0.0s)")
        return
    time.sleep(reload_delay_seconds)
    print(f"waited {reload_delay_seconds}s for iTerm2 Dynamic Profile reload")


def _get_reload_delay() -> float:
    """Read LCARS_PROFILE_RELOAD_WAIT env var and return clamped float."""
    raw = os.environ.get("LCARS_PROFILE_RELOAD_WAIT")
    if raw is None:
        return _RELOAD_WAIT_DEFAULT
    try:
        val = float(raw)
    except ValueError:
        return _RELOAD_WAIT_DEFAULT
    return max(_RELOAD_WAIT_MIN, min(_RELOAD_WAIT_MAX, val))


def main(url: str) -> int:
    _strip_stale_plist_entry()
    if not _update_dynamic_profile_url(url):
        return 1
    _wait_for_iterm2_reload(_get_reload_delay())
    print(f"LCARS Web profile: url={url}")
    return 0


if __name__ == "__main__":
    url = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8080"
    sys.exit(main(url))
