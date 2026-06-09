#!/usr/bin/env python3
"""Shared iTerm2 venv probe/re-exec bootstrap for AITeamForge cockpit scripts.

USAGE — place this at the TOP of any script that needs `import iterm2`, BEFORE
the first `import iterm2` statement:

    # Bootstrap: ensure we are running under the venv that has iterm2 installed.
    import _bootstrap  # noqa — side-effect: re-exec under venv python if needed
    # ... then safely import iterm2

    # If you prefer an in-file import:
    from iterm2_venv_bootstrap import ensure_iterm2_venv  # noqa
    ensure_iterm2_venv()
    import iterm2

HOW IT WORKS
------------
The `iterm2` Python package is provisioned in the tap-owned venv at
  $HOMEBREW_PREFIX/var/aiteamforge/venv
by `brew postinstall aiteamforge`.

When a cockpit script is called with the system `python3` (e.g. from a shell
startup script via `python3 set-lcars-profile-browser.py`) the system python3
does NOT have the `iterm2` package.  This module detects that condition and
re-executes the current script under the venv python3 that DOES have it.

If no venv is found (e.g. on the dev source machine where the package is
installed globally, or a fresh install that hasn't run postinstall yet), the
function returns normally and lets the caller's own `import iterm2` produce an
informative ImportError.

CANONICAL SOURCE (XACA-0652)
-----------------------------
Canonical:  dev-team/scripts/iterm2_venv_bootstrap.py
Tap mirror: homebrew-tap/share/scripts/iterm2_venv_bootstrap.py   (via sync-tap.sh)

Every script that does `import iterm2` must use this module instead of
copy-pasting the venv probe — avoiding k501 sibling drift.
"""

from __future__ import annotations

import os
import subprocess
import sys


def _get_tap_venv_candidates() -> list[str]:
    """Return venv candidate paths, probing brew only when necessary.

    Probe order (mirrors iterm2_window_manager.py XACA-0650 logic):
      1. brew --prefix aiteamforge / libexec/venv   — current Formula convention
      2. brew --prefix / var/aiteamforge/venv        — legacy location
      3. /opt/homebrew/var/aiteamforge/venv          — Apple-Silicon homebrew hardcode
      4. /usr/local/var/aiteamforge/venv             — Intel homebrew hardcode
    """
    brew_prefix = ""
    try:
        brew_prefix = subprocess.check_output(
            ["brew", "--prefix"], text=True, timeout=5
        ).strip()
    except Exception:
        pass

    brew_atf_prefix = ""
    try:
        brew_atf_prefix = subprocess.check_output(
            ["brew", "--prefix", "aiteamforge"], text=True, timeout=5
        ).strip()
    except Exception:
        pass

    return [
        os.path.join(brew_atf_prefix, "libexec/venv") if brew_atf_prefix else "",
        os.path.join(brew_prefix, "var/aiteamforge/venv") if brew_prefix else "",
        "/opt/homebrew/var/aiteamforge/venv",
        "/usr/local/var/aiteamforge/venv",
    ]


def ensure_iterm2_venv() -> None:
    """Re-exec the current script under the tap-owned venv python3 if iterm2 is missing.

    Must be called BEFORE `import iterm2`.  If iterm2 is already importable
    (e.g. on the dev source machine or after a successful re-exec) this is a
    no-op.  If re-exec succeeds this function never returns — os.execv() replaces
    the current process.  If no usable venv is found, returns normally so the
    caller's own import produces an informative error.
    """
    # Fast path: iterm2 is already available — zero subprocess calls, return immediately.
    # This is the common case: running under the tap venv after a successful re-exec,
    # or on the dev-source machine where iterm2 is installed globally.
    # The execv infinite-loop guard is implicit: after re-exec the new python3 has
    # iterm2, so find_spec succeeds and we return before touching the venv candidates.
    try:
        import importlib.util  # noqa: PLC0415 — lazy, intentional
        if importlib.util.find_spec("iterm2") is not None:
            return
    except Exception:
        pass

    # iterm2 is not importable — probe venv candidates (incurs brew subprocess calls).
    for _venv_dir in _get_tap_venv_candidates():
        if not _venv_dir:
            continue
        venv_python = os.path.join(_venv_dir, "bin/python3")
        if os.path.isfile(venv_python) and sys.executable != venv_python:
            # os.execv replaces the current process — the caller never returns here.
            os.execv(venv_python, [venv_python] + sys.argv)

    # No venv found — caller's `import iterm2` will produce an informative error.


# Module-level side-effect: auto-invoke when the module is imported directly.
# Scripts that do `import iterm2_venv_bootstrap` get the probe for free without
# a second call.
ensure_iterm2_venv()
