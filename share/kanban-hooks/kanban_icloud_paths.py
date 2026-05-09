#!/usr/bin/env python3
"""
kanban_icloud_paths.py — Canonical iCloud backup path resolver.

XACA-0466-001

Provides:
    local_kanban_root()   -> Path  — primary local backup root (source of truth)
    icloud_kanban_root()  -> Path  — iCloud backup parent (all hosts)
    icloud_host_dir()     -> Path  — per-host iCloud backup dir (collision-safe)
    check_icloud()        -> None  — raises ICloudUnavailableError if iCloud is absent/offloaded

Contract for subitems 002–005:
    - Always call check_icloud() before any iCloud write operation.
    - Never fall back to a non-iCloud path on iCloud errors — fail loudly instead.
    - Hostname is stripped of ".local" suffix so "Darren-M3Pro.local" == "Darren-M3Pro".
"""

from __future__ import annotations

import os
import socket
import subprocess
import sys
from pathlib import Path


# ---------------------------------------------------------------------------
# iCloud Drive root — the com.apple.CloudDocs path is the standard macOS
# iCloud Drive mount point. It exists on macOS 10.11+ regardless of whether
# iCloud Drive is enabled in System Preferences; the directory's _presence_
# alone doesn't confirm sync is active. check_icloud() validates further.
# ---------------------------------------------------------------------------
_ICLOUD_DRIVE = Path.home() / "Library" / "Mobile Documents" / "com~apple~CloudDocs"

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
# Local primary is the existing backup root — never changes, source of truth.
_LOCAL_KANBAN_ROOT = Path.home() / "aiteamforge-backups" / "kanban"

# Nest under AITeamForge/ (already exists in this iCloud account) rather than
# dropping kanban-backups/ at the Drive root, which would clutter it.
_ICLOUD_KANBAN_PARENT = _ICLOUD_DRIVE / "AITeamForge" / "kanban-backups"


class ICloudUnavailableError(RuntimeError):
    """Raised when iCloud Drive is absent, offloaded, or unwritable."""


def _hostname() -> str:
    """Return short hostname, stripping .local if present."""
    name = socket.gethostname()
    # socket.gethostname() may return 'Darren-M3Pro.local' on some macOS configs
    if name.endswith(".local"):
        name = name[: -len(".local")]
    return name


def local_kanban_root() -> Path:
    """Primary local backup root — ~/aiteamforge-backups/kanban/."""
    return _LOCAL_KANBAN_ROOT


def icloud_kanban_root() -> Path:
    """iCloud backup parent dir (all hosts) — .../AITeamForge/kanban-backups/."""
    return _ICLOUD_KANBAN_PARENT


def icloud_host_dir() -> Path:
    """Per-host iCloud backup dir — .../AITeamForge/kanban-backups/<hostname>/."""
    return _ICLOUD_KANBAN_PARENT / _hostname()


def check_icloud() -> None:
    """
    Raise ICloudUnavailableError if iCloud Drive is unavailable.

    Checks:
    1. The com.apple.CloudDocs directory exists (basic mount check).
    2. The AITeamForge parent is not offloaded (xattr suppressed check).
    3. We can actually write to it (permission check).

    Callers must invoke this before any iCloud write. Never silently fall back.
    """
    if not _ICLOUD_DRIVE.exists():
        raise ICloudUnavailableError(
            f"iCloud Drive root not found: {_ICLOUD_DRIVE}\n"
            "Sign in to iCloud Drive in System Settings → Apple ID."
        )

    # The AITeamForge parent directory already exists; check it isn't offloaded.
    aiforge_dir = _ICLOUD_DRIVE / "AITeamForge"
    if aiforge_dir.exists():
        try:
            result = subprocess.run(
                ["xattr", "-p", "com.apple.icloud.suppressedReason", str(aiforge_dir)],
                capture_output=True,
                text=True,
            )
            if result.returncode == 0 and result.stdout.strip():
                raise ICloudUnavailableError(
                    f"iCloud AITeamForge directory is offloaded (suppressed): "
                    f"{aiforge_dir}\n"
                    "Open Finder and let it download before running sync."
                )
        except FileNotFoundError:
            # xattr binary missing — unusual but not fatal; skip this check
            pass

    # Write-access probe: the kanban-backups dir may not exist yet (002 creates it),
    # so probe against the AITeamForge dir which already exists.
    probe_base = aiforge_dir if aiforge_dir.exists() else _ICLOUD_DRIVE
    if not os.access(probe_base, os.W_OK):
        raise ICloudUnavailableError(
            f"No write permission on iCloud path: {probe_base}"
        )


# ---------------------------------------------------------------------------
# CLI self-test: python3 kanban_icloud_paths.py --print
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    if "--print" in sys.argv:
        try:
            check_icloud()
            icloud_status = "available"
        except ICloudUnavailableError as e:
            icloud_status = f"UNAVAILABLE — {e}"

        print(f"LOCAL_KANBAN_ROOT   : {local_kanban_root()}")
        print(f"ICLOUD_KANBAN_ROOT  : {icloud_kanban_root()}")
        print(f"ICLOUD_HOST_DIR     : {icloud_host_dir()}")
        print(f"HOSTNAME            : {_hostname()}")
        print(f"ICLOUD_STATUS       : {icloud_status}")
    else:
        print("Usage: python3 kanban_icloud_paths.py --print", file=sys.stderr)
        sys.exit(1)
