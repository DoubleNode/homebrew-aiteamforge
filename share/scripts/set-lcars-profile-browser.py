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

Usage: python3 set-lcars-profile-browser.py [--verify] <url>
  e.g. python3 set-lcars-profile-browser.py http://localhost:8203
       python3 set-lcars-profile-browser.py --verify http://localhost:8203

--verify (XACA-1661): after the write and reload wait, read the 'LCARS Web'
profile's 'Initial URL' back out of the RUNNING iTerm2 via its Python API
and compare it with <url>. iTerm2 3.7 can keep serving a stale in-memory
copy of the profile even though the DynamicProfiles file is correct, which
opens another team's board in the LCARS tab. The file-level readback in
_update_dynamic_profile_url cannot see that; --verify can. The poll is
bounded by the (clamped) LCARS_PROFILE_RELOAD_WAIT value. Without --verify
nothing here imports iterm2 and behaviour/exit codes are unchanged.

Exit codes:
  0  success (with --verify: in-memory URL matches)
  1  write failure (profile JSON missing/corrupt/unwritable/readback bad)
  3  --verify: iTerm2 in-memory URL != requested URL (stale profile);
     stderr names the file URL, the in-memory URL and the repair command
  4  --verify: iTerm2 API unavailable (iterm2 module missing, connection
     refused/timed out, 'LCARS Web' profile or 'Initial URL' not found).
     Loud by design: an unverifiable result is never reported as a pass.

Environment:
  LCARS_PROFILE_RELOAD_WAIT  Override the post-write pause before iTerm2
                             has had time to rescan DynamicProfiles/.
                             Default 1.5s. Range [0.0, 10.0]. Set to 0
                             to skip the wait entirely (useful in tests).
                             Also the --verify poll timeout.
  Test overrides (XACA-1661):
  LCARS_DYNAMIC_PROFILE_FILE Path of the DynamicProfiles JSON to edit.
  LCARS_ITERM_PREFS_DOMAIN   `defaults` domain (or plist path without
                             .plist) for the legacy-entry cleanup.
                             Default com.googlecode.iterm2.
  LCARS_ITERM_RUNNING        1/0 forces the "iTerm2 is running" answer
                             instead of `pgrep -a -x iTerm2`.
  Tests can also place a fake `iterm2` module on PYTHONPATH for --verify.
"""

import asyncio
import json
import os
import plistlib
import subprocess
import sys
import time
from pathlib import Path

LCARS_WEB_GUID = "AITEAMFORGE-LCARS-WEB-0001-000000000001"
PROFILE_FILE = Path(
    os.environ.get("LCARS_DYNAMIC_PROFILE_FILE")
    or Path.home()
    / "Library/Application Support/iTerm2/DynamicProfiles/aiteamforge-lcars.json"
)
ITERM_PREFS_DOMAIN = (
    os.environ.get("LCARS_ITERM_PREFS_DOMAIN") or "com.googlecode.iterm2"
)

EXIT_OK = 0
EXIT_WRITE_FAILED = 1
EXIT_VERIFY_MISMATCH = 3
EXIT_VERIFY_UNAVAILABLE = 4

_VERIFY_POLL_INTERVAL = 0.25
_VERIFY_CONNECT_TIMEOUT = 5.0
_REPAIR_SCRIPT = "iterm2-lcars-profile-repair.sh"

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


def _iterm2_running() -> bool:
    """True if iTerm2 is running (or we cannot tell: fail safe).

    LCARS_ITERM_RUNNING=1/0 overrides for tests.
    """
    override = os.environ.get("LCARS_ITERM_RUNNING")
    if override is not None:
        return override.strip().lower() not in ("0", "", "false", "no")
    try:
        # -a: macOS pgrep excludes the caller's ancestors without it, and
        # this setter normally runs inside an iTerm2 pane (XACA-1341).
        rc = subprocess.run(
            ["pgrep", "-a", "-x", "iTerm2"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        ).returncode
    except Exception:
        return True  # cannot tell -> assume running -> do not touch prefs
    return rc != 1  # 0 = running, 1 = not running, anything else = unknown


def _strip_stale_plist_entry() -> None:
    """Remove any LCARS Web entry that a previous installer wrote
    directly into 'New Bookmarks'. Silent no-op if nothing to clean.

    XACA-1661: never touches iTerm2 prefs while iTerm2 is running. iTerm2
    owns that domain in memory and rewrites it on its own schedule, so an
    edit made behind its back is either clobbered or races the app. The
    old code also wrote the plist FILE directly and then ran
    `killall cfprefsd`; both bypass the preferences daemon and are gone.
    When iTerm2 is not running the edit goes through `defaults`
    export/import, i.e. through cfprefsd.
    """
    if _iterm2_running():
        print(
            "⚠️  iTerm2 is running: skipping legacy LCARS Web plist cleanup "
            "(prefs are not edited while iTerm2 is up)",
            file=sys.stderr,
        )
        return
    try:
        exported = subprocess.run(
            ["defaults", "export", ITERM_PREFS_DOMAIN, "-"],
            capture_output=True,
            check=True,
        ).stdout
        data = plistlib.loads(exported)
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
    try:
        subprocess.run(
            ["defaults", "import", ITERM_PREFS_DOMAIN, "-"],
            input=plistlib.dumps(data),
            capture_output=True,
            check=True,
        )
    except Exception as exc:
        print(
            f"⚠️  legacy LCARS Web plist cleanup failed via defaults: {exc}",
            file=sys.stderr,
        )
        return
    print("cleaned up stale LCARS Web from plist (legacy workaround)")


def _wait_for_iterm2_reload(reload_delay_seconds: float = _RELOAD_WAIT_DEFAULT) -> None:
    """Sleep briefly so iTerm2 has time to rescan DynamicProfiles/ and
    pick up the URL change before the caller creates a new tab.

    --- Why we can't do better than a fixed wait ---

    Option A: Poll the iTerm2 Python API for profile field changes.
    Corrected by XACA-1661-001 (measured on iTerm2 3.7.6): the
    PartialProfile from async_query() carries only Name/Guid, but
    `await partial.async_get_full_profile()` DOES expose 'Initial URL'
    via full.all_properties["Initial URL"]. That read-back is used by
    --verify (see _read_inmemory_url) as a post-hoc check. It is NOT
    used to replace this wait: the default no-flag path stays a cheap
    fixed sleep because 24 callers run it on every connect.

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

    Keep the no-flag path dependency-free (no iterm2 import, no venv
    re-exec); the API check lives behind --verify.

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


class _VerifyUnavailable(Exception):
    """iTerm2 API could not give us an answer (distinct from a mismatch)."""


async def _read_inmemory_url_async(iterm2) -> str:
    conn = await asyncio.wait_for(
        iterm2.Connection.async_create(), timeout=_VERIFY_CONNECT_TIMEOUT
    )
    profs = await asyncio.wait_for(
        iterm2.PartialProfile.async_query(conn), timeout=_VERIFY_CONNECT_TIMEOUT
    )
    partial = next((p for p in profs if p.name == "LCARS Web"), None)
    if partial is None:
        raise _VerifyUnavailable('"LCARS Web" profile not found in iTerm2')
    full = await asyncio.wait_for(
        partial.async_get_full_profile(), timeout=_VERIFY_CONNECT_TIMEOUT
    )
    url = full.all_properties.get("Initial URL")
    if url is None:
        raise _VerifyUnavailable('"LCARS Web" has no "Initial URL" in iTerm2')
    return url


def _read_inmemory_url() -> str:
    """Return the running iTerm2's in-memory 'Initial URL' for LCARS Web.

    Raises _VerifyUnavailable for every way the API can fail. Tests can
    inject a fake `iterm2` module via PYTHONPATH (the venv bootstrap is a
    no-op when `iterm2` is already importable).
    """
    try:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import iterm2_venv_bootstrap  # noqa: F401 — re-execs under venv if needed
    except ImportError:
        pass
    try:
        import iterm2
    except ImportError as exc:
        raise _VerifyUnavailable(f"iterm2 Python module not importable: {exc}")
    try:
        return asyncio.run(_read_inmemory_url_async(iterm2))
    except _VerifyUnavailable:
        raise
    except Exception as exc:
        raise _VerifyUnavailable(
            f"iTerm2 API call failed ({type(exc).__name__}: {exc})"
        )


def _file_url() -> str:
    try:
        for p in json.loads(PROFILE_FILE.read_text()).get("Profiles", []):
            if p.get("Name") == "LCARS Web":
                return str(p.get("Initial URL"))
    except Exception:
        pass
    return "<unreadable>"


def _verify(url: str, timeout: float) -> int:
    """Poll iTerm2's in-memory profile until it matches url or timeout."""
    deadline = time.monotonic() + timeout
    last = None
    while True:
        try:
            last = _read_inmemory_url()
        except _VerifyUnavailable as exc:
            print(
                f"🚨 VERIFY UNAVAILABLE: cannot confirm iTerm2 loaded {url}: {exc}\n"
                "   The LCARS tab URL is UNVERIFIED. Not reporting success.",
                file=sys.stderr,
            )
            return EXIT_VERIFY_UNAVAILABLE
        if last == url:
            print(f"verified: iTerm2 in-memory LCARS Web Initial URL = {url}")
            return EXIT_OK
        if time.monotonic() >= deadline:
            break
        time.sleep(_VERIFY_POLL_INTERVAL)
    repair = Path(__file__).resolve().parent / _REPAIR_SCRIPT
    print(
        "🚨 VERIFY MISMATCH: iTerm2 is serving a stale LCARS Web profile.\n"
        f"   DynamicProfiles file URL : {_file_url()}\n"
        f"   iTerm2 in-memory URL     : {last}\n"
        f"   expected                 : {url}\n"
        f"   Repair: {repair} --apply\n"
        "   (--apply requires quitting iTerm2; run it without --apply first "
        "to preview.)",
        file=sys.stderr,
    )
    return EXIT_VERIFY_MISMATCH


def main(url: str, verify: bool = False) -> int:
    _strip_stale_plist_entry()
    if not _update_dynamic_profile_url(url):
        return EXIT_WRITE_FAILED
    delay = _get_reload_delay()
    _wait_for_iterm2_reload(delay)
    print(f"LCARS Web profile: url={url}")
    if verify:
        return _verify(url, delay)
    return EXIT_OK


if __name__ == "__main__":
    args = sys.argv[1:]
    verify = "--verify" in args
    args = [a for a in args if a != "--verify"]
    url = args[0] if args else "http://localhost:8080"
    if verify:
        # XACA-1661-015: under system python3 the bootstrap re-execs this whole
        # script into the venv that has iterm2. Do it BEFORE main() so the
        # re-exec happens ahead of any side effect (write, reload wait, output)
        # instead of repeating them. Without --verify nothing is imported.
        try:
            sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
            import iterm2_venv_bootstrap  # noqa: F401
        except ImportError:
            pass
    sys.exit(main(url, verify))
