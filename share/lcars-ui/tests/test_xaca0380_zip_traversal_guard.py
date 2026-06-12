#!/usr/bin/env python3

#
#  test_xaca0380_zip_traversal_guard.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""
Regression tests for XACA-0380 — kanban-import zip path-traversal guard.

Tests cover the `_assert_zip_entries_contained(names, dest_root)` helper
added to server.py.  The helper is pure and dependency-free; no HTTP server
or real network calls are required.

Test matrix:
  REJECT (ValueError):
    1. "../"-traversal escape                   e.g. ../../.ssh/authorized_keys
    2. Absolute-path entry                      e.g. /etc/passwd
    3. Mixed benign+escaping list               guard must be validate-all-first
  PASS (no exception):
    4. Normal relative paths                    kanban/board.json + knowledge/…
    5. Empty list                               edge case: no entries
    6. Nested benign path                       kanban/sub/dir/file.json

Run with:
    python3 -m unittest lcars-ui/tests/test_xaca0380_zip_traversal_guard.py -v
  or from the repo root:
    python3 -m unittest discover -s lcars-ui/tests -p 'test_*.py'
  or with pytest:
    python3 -m pytest lcars-ui/tests/test_xaca0380_zip_traversal_guard.py -q
"""

import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock

# ---------------------------------------------------------------------------
# Bootstrap: import server.py with heavy optional deps stubbed out, matching
# the pattern established in test_xaca0463_guard.py.
# ---------------------------------------------------------------------------

LCARS_UI_DIR = Path(__file__).parent.parent
REPO_ROOT = LCARS_UI_DIR.parent
sys.path.insert(0, str(LCARS_UI_DIR))
sys.path.insert(0, str(REPO_ROOT))

# Stub heavy optional imports before server.py is loaded
_stub_modules = {
    "kanban_utils": MagicMock(
        log_activity=MagicMock(),
        read_activity_log=MagicMock(return_value={"entries": [], "itemId": ""}),
        get_lcars_tmp_dir=MagicMock(return_value="/tmp/"),
    ),
    "integrations": MagicMock(),
    "calendar": MagicMock(),
    "calendar.sync_service": MagicMock(),
    "calendar.apple_provider": MagicMock(),
    "calendar.provider": MagicMock(),
}
for _mod_name, _stub in _stub_modules.items():
    if _mod_name not in sys.modules:
        sys.modules[_mod_name] = _stub

import server  # noqa: E402


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

class TestZipTraversalGuard(unittest.TestCase):
    """Unit tests for server._assert_zip_entries_contained."""

    def setUp(self):
        """Create a fresh temp directory as the extraction dest_root."""
        self._tmpdir_ctx = tempfile.TemporaryDirectory()
        self.dest_root = Path(self._tmpdir_ctx.name)

    def tearDown(self):
        self._tmpdir_ctx.cleanup()

    # ------------------------------------------------------------------
    # REJECT cases — must raise ValueError
    # ------------------------------------------------------------------

    def test_reject_dotdot_traversal(self):
        """../../ escape raises ValueError."""
        with self.assertRaises(ValueError) as ctx:
            server._assert_zip_entries_contained(
                ["../../.ssh/authorized_keys"],
                self.dest_root,
            )
        self.assertIn("escapes", str(ctx.exception))

    def test_reject_absolute_path_entry(self):
        """Absolute path entry raises ValueError."""
        with self.assertRaises(ValueError) as ctx:
            server._assert_zip_entries_contained(
                ["/etc/passwd"],
                self.dest_root,
            )
        self.assertIn("absolute", str(ctx.exception))

    def test_reject_mixed_list_validate_all_first(self):
        """Benign entry followed by escaping entry → raises (validate-all-first).

        Confirms the guard inspects the whole list before extraction —
        no partial write would occur even when the bad entry is not first.
        """
        names = [
            "kanban/board.json",          # benign — must NOT be extracted
            "../../.ssh/authorized_keys",  # escape — triggers rejection
        ]
        with self.assertRaises(ValueError):
            server._assert_zip_entries_contained(names, self.dest_root)

    # ------------------------------------------------------------------
    # PASS cases — must NOT raise
    # ------------------------------------------------------------------

    def test_pass_normal_relative_paths(self):
        """Typical kanban/knowledge relative paths pass without exception."""
        names = [
            "kanban/board.json",
            "knowledge/agents/INDEX.md",
        ]
        # Should not raise — no return value to check
        server._assert_zip_entries_contained(names, self.dest_root)

    def test_pass_empty_list(self):
        """Empty name list passes without exception."""
        server._assert_zip_entries_contained([], self.dest_root)

    def test_pass_nested_benign_path(self):
        """Deeply nested relative path within dest_root passes."""
        server._assert_zip_entries_contained(
            ["kanban/sub/dir/file.json"],
            self.dest_root,
        )


if __name__ == "__main__":
    unittest.main()
