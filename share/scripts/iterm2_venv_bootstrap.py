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

Venv candidate probe order:
  1. brew --prefix aiteamforge / libexec/venv   — current Formula convention
  2. brew --prefix / var/aiteamforge/venv        — legacy location
  3. /opt/homebrew/var/aiteamforge/venv          — Apple-Silicon homebrew hardcode
  4. /usr/local/var/aiteamforge/venv             — Intel homebrew hardcode
  5. <repo_root>/.venv                           — repo-local dev venv (XACA-0690)

Candidate 5 exists for the dev-source machine (M3Pro) where the tap is NEVER
installed (CLAUDE.md hard rule) and iterm2 lives only in the repo-local dev venv.
After a homebrew python relink (e.g. Jun 2026) bare python3 loses the iterm2
package entirely — the repo-local .venv is the correct fallback.  On consumer
machines no repo .venv exists so the candidate is harmlessly skipped.

The repo root is resolved from `__file__`; if called from a git worktree (where
`<root>/.git` is a file, not a directory) we parse the gitdir pointer and walk up
to the main-checkout root so the correct `.venv` is found regardless of which
worktree the script lives in.

If no venv is found (e.g. a fresh install that hasn't run postinstall yet), the
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
      5. <repo_root>/.venv                           — repo-local dev venv (XACA-0690)

    Tap candidates come first so consumer machines always prefer the managed venv.
    The repo-local .venv is appended last as a dev-box fallback; on consumer
    machines it doesn't exist and is silently skipped.
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

    # Derive repo root from this file's location: <repo_root>/scripts/iterm2_venv_bootstrap.py
    # In a git worktree, <repo_root>/.git is a FILE pointing to the common git dir;
    # the actual dev venv lives in the main-checkout root, not the worktree root.
    # We resolve the common-dir parent so worktree invocations find ~/dev-team/.venv.
    _bootstrap_dir = os.path.dirname(os.path.abspath(__file__))  # .../scripts
    _nominal_root = os.path.dirname(_bootstrap_dir)              # worktree root OR main repo root
    _git_path = os.path.join(_nominal_root, ".git")
    _repo_root = _nominal_root  # default: assume main checkout
    if os.path.isfile(_git_path):
        # Worktree: .git is a file with "gitdir: <common-dir>/worktrees/<name>"
        # Walk up from that path to find the main repo root (the dir containing ".git/").
        try:
            with open(_git_path) as _f:
                _gitdir_line = _f.read().strip()  # e.g. "gitdir: /path/.git/worktrees/name"
            if _gitdir_line.startswith("gitdir:"):
                _gitdir = _gitdir_line[len("gitdir:"):].strip()
                # Navigate: .git/worktrees/<name> -> .git -> main-repo-root
                _repo_root = os.path.dirname(os.path.dirname(os.path.dirname(_gitdir)))
        except Exception:
            pass
    repo_venv = os.path.join(_repo_root, ".venv")                # repo-local dev venv (main checkout)

    return [
        os.path.join(brew_atf_prefix, "libexec/venv") if brew_atf_prefix else "",
        os.path.join(brew_prefix, "var/aiteamforge/venv") if brew_prefix else "",
        "/opt/homebrew/var/aiteamforge/venv",
        "/usr/local/var/aiteamforge/venv",
        repo_venv,  # dev-box fallback: tap is never installed on M3Pro (XACA-0690)
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
