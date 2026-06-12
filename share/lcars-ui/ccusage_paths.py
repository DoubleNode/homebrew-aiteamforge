#!/usr/bin/env python3

#
#  ccusage_paths.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""
ccusage_paths.py — Shared runtime-path constants for the Claude Usage Monitor (XACA-0385).

Single source of truth for the four runtime files used by the ccusage subsystem:
  - lcars-ccusage-cache.json     (cache written atomically by the collector)
  - lcars-ccusage-cache.tmp.json (atomic-write staging file)
  - lcars-ccusage-collector.pid  (PID lock written by the collector daemon)
  - lcars-ccusage-collector.log  (collector stdout/stderr from server respawn)

All files live under ~/.aiteamforge/run/ (mode 0700, owner-only) instead of the
world-writable /tmp/ directory that was used before XACA-0385.

Both the producer (ccusage_collector.py) and consumer (server.py) import from this
module — path literals are NOT duplicated anywhere else.

Usage:
    from ccusage_paths import CACHE_PATH, CACHE_TMP_PATH, PID_PATH, COLLECTOR_LOG
    from ccusage_paths import ensure_runtime_dir
"""

import os
import stat
from pathlib import Path

# ---------------------------------------------------------------------------
# Runtime directory
# ---------------------------------------------------------------------------

RUNTIME_DIR: Path = Path("~/.aiteamforge/run").expanduser()

# ---------------------------------------------------------------------------
# Per-file constants (pathlib.Path objects)
# ---------------------------------------------------------------------------

CACHE_PATH: Path = RUNTIME_DIR / "lcars-ccusage-cache.json"
CACHE_TMP_PATH: Path = RUNTIME_DIR / "lcars-ccusage-cache.tmp.json"
PID_PATH: Path = RUNTIME_DIR / "lcars-ccusage-collector.pid"
COLLECTOR_LOG: Path = RUNTIME_DIR / "lcars-ccusage-collector.log"


# ---------------------------------------------------------------------------
# Runtime directory guard
# ---------------------------------------------------------------------------

def ensure_runtime_dir() -> None:
    """Create ~/.aiteamforge/run/ with mode 0700 if it does not exist.

    Security contract:
      - Creates both ~/.aiteamforge/ (if absent) and ~/.aiteamforge/run/ with
        mode 0o700 so only the owning user can read, write, or list the dir.
      - If the path already exists, verifies it is NOT a symlink and IS owned
        by the current uid.  Either violation raises RuntimeError — it is safer
        to fail loudly than write to an attacker-controlled path.
      - Defensively tightens permissions to 0o700 when the dir is owned by us
        but has looser permissions (e.g. inherited umask-relaxed creation).
      - Idempotent: safe to call on every process start.

    Raises:
        RuntimeError: if the runtime dir is a symlink or owned by another user.
    """
    parent = RUNTIME_DIR.parent  # ~/.aiteamforge

    # Create ~/.aiteamforge if absent (lenient mode — other tools own this dir).
    if not parent.exists():
        parent.mkdir(mode=0o700, parents=True, exist_ok=True)

    run_dir_str = str(RUNTIME_DIR)

    if RUNTIME_DIR.exists():
        # Security: reject symlinks.
        if os.path.islink(run_dir_str):
            raise RuntimeError(
                f"[ccusage_paths] SECURITY: {run_dir_str!r} is a symlink. "
                "Refusing to use a symlinked runtime directory."
            )
        # Security: reject dirs not owned by the current user.
        st = os.stat(run_dir_str)
        if st.st_uid != os.getuid():
            raise RuntimeError(
                f"[ccusage_paths] SECURITY: {run_dir_str!r} is owned by uid "
                f"{st.st_uid} but current uid is {os.getuid()}. "
                "Refusing to use a runtime directory we do not own."
            )
        # Defensively enforce 0o700 if permissions are looser.
        current_mode = stat.S_IMODE(st.st_mode)
        if current_mode != 0o700:
            os.chmod(run_dir_str, 0o700)
    else:
        RUNTIME_DIR.mkdir(mode=0o700, parents=False, exist_ok=True)
        # Explicitly set mode in case umask relaxed it.
        os.chmod(run_dir_str, 0o700)
