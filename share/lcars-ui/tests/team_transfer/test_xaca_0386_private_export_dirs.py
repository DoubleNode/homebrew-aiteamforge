"""XACA-0386 (audit F-04-007): export/import staging dirs must be owner-only.

The LCARS server stages team-transfer artifacts — including encrypted and
transiently-decrypted secrets bundles — under shared /tmp directories. They must
be created mode 0o700 (owner read/write/traverse only), AND a pre-existing
world-readable directory (left by an older build or a wide umask) must be
tightened on the next ensure call. ``Path.mkdir(mode=0o700, exist_ok=True)``
alone does NOT do this: the mode is ignored when the directory already exists,
which is the common case for these long-lived /tmp dirs. The explicit chmod in
``_ensure_private_dir`` is what closes the gap — these tests guard it.
"""
import os
import stat
import sys
from pathlib import Path

import pytest

LCARS_UI_DIR = Path(__file__).resolve().parents[2]
if str(LCARS_UI_DIR) not in sys.path:
    sys.path.insert(0, str(LCARS_UI_DIR))

import server  # noqa: E402


def _mode(path: Path) -> int:
    return stat.S_IMODE(os.stat(path).st_mode)


def test_creates_new_dir_owner_only(tmp_path):
    """A freshly created staging dir is mode 0o700 regardless of umask."""
    target = tmp_path / "lcars-exports"
    # Force a permissive umask so a plain mkdir would otherwise be world-readable.
    old_umask = os.umask(0o022)
    try:
        server._ensure_private_dir(target)
    finally:
        os.umask(old_umask)
    assert target.is_dir()
    assert _mode(target) == 0o700, oct(_mode(target))


def test_tightens_preexisting_world_readable_dir(tmp_path):
    """The core regression: a dir that ALREADY exists loose must be tightened.

    mkdir(exist_ok=True) is a no-op when the dir exists, so without the explicit
    chmod a world-readable dir from an older server build would stay exposed.
    """
    target = tmp_path / "lcars-secrets-imports"
    target.mkdir(mode=0o755)
    os.chmod(target, 0o755)  # simulate a pre-existing world-readable staging dir
    assert _mode(target) == 0o755

    server._ensure_private_dir(target)

    assert _mode(target) == 0o700, oct(_mode(target))


def test_creates_parents(tmp_path):
    """Nested staging dirs (e.g. per-job scratch) are created with parents."""
    nested = tmp_path / "lcars-imports" / "extract-abc123"
    server._ensure_private_dir(nested.parent)
    server._ensure_private_dir(nested)
    assert nested.is_dir()
    assert _mode(nested) == 0o700, oct(_mode(nested))


def test_idempotent(tmp_path):
    """Calling twice leaves the dir 0o700 and does not raise."""
    target = tmp_path / "lcars-exports"
    server._ensure_private_dir(target)
    server._ensure_private_dir(target)
    assert _mode(target) == 0o700, oct(_mode(target))


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))
