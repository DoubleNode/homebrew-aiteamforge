#!/usr/bin/env python3

#
#  test_xaca1255_active_window_staleness.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""
Tests for XACA-1255: serve_agent_panel_data()'s active-window STALENESS GUARD.

── The defect ─────────────────────────────────────────────────────────────
`<kanban/tmp>/lcars-active-window-<session>` tells the LCARS server which
tmux window a session is showing, so /api/agent-panel can serve that
window's own `lcars-agent-<session>-w<N>.json` instead of the session-level
file. Before this ticket that index file was seeded only when ABSENT and
maintained by a GLOBAL tmux hook every session on a socket overwrote, so it
could sit arbitrarily stale — measured 2026-09-16: five `command-*` index
files frozen 23 days old while their panels were running. The endpoint
trusted it anyway and served one chat the agent data of a DIFFERENT window.

A stale index is worse than no index: it is a confident wrong answer. The
fix makes the panel heartbeat the file, so a stale mtime now unambiguously
means "no panel is maintaining this session" — and the server ignores the
index entirely and falls back to the session-level file.

── Why this file exists (read before editing) ─────────────────────────────
test_server.py::TestServeAgentPanelData has three tests over this same
endpoint, and NONE of them can reach the guard. All three build the tmp dir
as `MagicMock(spec=Path)` and set `active_win_file.exists.return_value =
False`, so `if active_window_file.exists():` is never entered and the mtime
arithmetic inside it never runs. Verified by negative control on
2026-09-16: disabling the guard (`if age <= ACTIVE_WINDOW_MAX_AGE_S` ->
`if True`) left that suite fully green.

Path mocking is precisely what made the branch unreachable, so this file
uses REAL temporary directories, REAL files and REAL `os.utime` mtimes.
There is no `Path` mock anywhere below, and none should be added: a mocked
`stat().st_mtime` would put this file back in the same blind spot it exists
to remove.

── Coverage ───────────────────────────────────────────────────────────────
  C1  fresh index + numeric + per-window JSON present -> serves the window file
  C2  STALE index (400s) -> must NOT serve the window file   [guard-critical]
  C3  fresh index but non-numeric (corrupt/partial write)    -> falls back
  C4  fresh numeric index but no matching per-window JSON    -> falls back
  C5  age 170s, just inside the 180s budget -> still serves the window file
  C6  age 190s, just outside it -> falls back                [guard-critical]

C2 and C6 are the two that flip when the guard is disabled; C1/C3/C4/C5
stay green, which is what makes them a control rather than noise. The 170s /
190s boundary cases deliberately sit 10s clear of the 180s threshold — an
exact-180 case would race the clock between `os.utime` and `time.time()`.

Run with:
    python3 -m pytest lcars-ui/tests/test_xaca1255_active_window_staleness.py -q
  or:
    python3 -m unittest lcars-ui/tests/test_xaca1255_active_window_staleness.py
"""

import io
import json
import os
import shutil
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

# ---------------------------------------------------------------------------
# Bootstrap server.py imports (stub optional heavy dependencies) — mirrors
# the convention established in test_server.py / test_xaca1221_image_roots.py.
# ---------------------------------------------------------------------------
LCARS_UI_DIR = Path(__file__).parent.parent
REPO_ROOT = LCARS_UI_DIR.parent
sys.path.insert(0, str(LCARS_UI_DIR))
sys.path.insert(0, str(REPO_ROOT))

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

_lcars_team_env_was_set = 'LCARS_TEAM' in os.environ
os.environ.setdefault('LCARS_TEAM', 'academy')
import server  # noqa: E402
if not _lcars_team_env_was_set:
    os.environ.pop('LCARS_TEAM', None)
    # Popping the variable is NOT enough. server.LCARS_TEAM is resolved from
    # the process environment ONCE, at import time, so the module attribute
    # keeps the synthetic 'academy' value and leaks into every other test
    # module sharing this pytest process. test_server.py's
    # TestModuleLevelConfig::test_lcars_team_defaults_to_empty_string asserts
    # server.LCARS_TEAM equals the variable's own value (or '' when it is
    # unset), so the two files pass individually (7/7 and 200/200) and fail
    # together -- MEASURED 2026-09-16: 1 failed, 206 passed. That is the worst
    # shape for a test defect: invisible per-file, visible only in the
    # full-suite run CI actually performs. Restore the ATTRIBUTE too.
    server.LCARS_TEAM = ''


# The guard's budget, restated here because it is a method-local constant in
# server.py and cannot be imported. If server.py's value changes, C5/C6 below
# stop straddling the real threshold — so assert the relationship explicitly
# rather than letting the cases quietly drift to the same side of it.
EXPECTED_MAX_AGE_S = 180

# A synthetic session. Never a real team: these tests write agent JSON and an
# active-window index, and a real session name could collide with a live
# panel's files if LCARS_TMP_DIR were ever not patched.
SESSION = "x1255probe-alpha"


def _make_handler(path):
    """Construct an LCARSHandler with all socket I/O mocked out.

    Note what is NOT mocked: the filesystem. Only the HTTP plumbing is faked.
    """
    response_buf = io.BytesIO()

    with patch.object(server.LCARSHandler, "__init__", lambda self, *a, **kw: None):
        handler = server.LCARSHandler.__new__(server.LCARSHandler)

    handler.path = path
    handler.command = "GET"
    handler.rfile = io.BytesIO(b"")
    handler.wfile = response_buf
    handler.server = MagicMock()
    handler.headers = {}
    handler.requestline = f"GET {path} HTTP/1.1"
    handler.client_address = ("127.0.0.1", 9999)
    handler._response_code = None
    handler._headers_sent = []

    handler.send_response = lambda code, message=None: setattr(
        handler, "_response_code", code)
    handler.send_header = lambda name, value: handler._headers_sent.append(
        (name, value))
    handler.end_headers = lambda: None
    handler.send_error = MagicMock(
        side_effect=lambda code, msg=None: setattr(handler, "_response_code", code))
    handler.log_message = MagicMock()
    handler.log_error = MagicMock()
    return handler, response_buf


class ActiveWindowStalenessTests(unittest.TestCase):
    """serve_agent_panel_data() must ignore a stale active-window index."""

    def setUp(self):
        self.tmp_dir = Path(tempfile.mkdtemp(prefix="x1255stale-"))
        # Session-level fallback: always present, so "fell back" is observable
        # as a specific served payload rather than as an absence.
        (self.tmp_dir / f"lcars-agent-{SESSION}.json").write_text(
            json.dumps({"name": "SESSION_LEVEL"}))

    def tearDown(self):
        shutil.rmtree(self.tmp_dir, ignore_errors=True)

    # -- fixture helpers ---------------------------------------------------

    def _write_window_json(self, index=3):
        (self.tmp_dir / f"lcars-agent-{SESSION}-w{index}.json").write_text(
            json.dumps({"name": "WINDOW_3"}))

    def _write_active_window(self, content, age_s=0):
        """Write the index file and age it with a REAL mtime."""
        target = self.tmp_dir / f"lcars-active-window-{SESSION}"
        target.write_text(content)
        if age_s:
            past = time.time() - age_s
            os.utime(target, (past, past))
        return target

    def _serve(self):
        """Call the real endpoint against the real temp dir; return the JSON."""
        handler, buf = _make_handler(f"/api/agent-panel?session={SESSION}")
        with patch("server.LCARS_TMP_DIR", self.tmp_dir), \
             patch("server._fetch_amb_badges", return_value=[]):
            handler.serve_agent_panel_data()
        buf.seek(0)
        body = buf.read()
        # The response is headers-then-body only in a real socket; here
        # end_headers is a no-op, so wfile holds the JSON body alone.
        return json.loads(body)

    def _assert_served(self, expected_name, msg):
        data = self._serve()
        self.assertEqual(data.get("name"), expected_name, msg)

    # -- the guard's own premise ------------------------------------------

    def test_c0_boundary_cases_straddle_the_real_threshold(self):
        """C5 (170s) and C6 (190s) must sit on opposite sides of the budget.

        If server.py's ACTIVE_WINDOW_MAX_AGE_S is retuned, both boundary cases
        could land on the same side and keep passing while testing nothing.
        Pin the assumption where it will fail loudly instead.
        """
        source = (LCARS_UI_DIR / "server.py").read_text()
        self.assertIn(
            f"ACTIVE_WINDOW_MAX_AGE_S = {EXPECTED_MAX_AGE_S}", source,
            "server.py's staleness budget changed; retune C5/C6 (170s/190s) so "
            "they still straddle it, then update EXPECTED_MAX_AGE_S here.")
        self.assertLess(170, EXPECTED_MAX_AGE_S)
        self.assertGreater(190, EXPECTED_MAX_AGE_S)

    # -- C1: the index is trusted when it is fresh and coherent ------------

    def test_c1_fresh_numeric_index_serves_the_window_file(self):
        """Positive control: without this, a guard stuck permanently ON would
        pass every case below while breaking per-window routing entirely."""
        self._write_window_json()
        self._write_active_window("3", age_s=0)
        self._assert_served(
            "WINDOW_3",
            "a fresh, numeric index pointing at an existing per-window JSON "
            "must be honoured")

    # -- C2: the defect ----------------------------------------------------

    def test_c2_stale_index_must_not_serve_the_window_file(self):
        """GUARD-CRITICAL. A 400s-old index means no panel is maintaining this
        session, so the index cannot be trusted to describe the current window.
        Serving w3 here is the original bug: another window's agent data."""
        self._write_window_json()
        self._write_active_window("3", age_s=400)
        self._assert_served(
            "SESSION_LEVEL",
            "a stale active-window index was trusted — this serves one chat "
            "the agent data of a DIFFERENT window (the XACA-1255 defect)")

    # -- C3/C4: unrelated fall-through paths stay intact --------------------

    def test_c3_non_numeric_index_falls_back(self):
        """A corrupt or partially-written index is not a window."""
        self._write_window_json()
        self._write_active_window("abc", age_s=0)
        self._assert_served(
            "SESSION_LEVEL", "a non-numeric index must not be dereferenced")

    def test_c4_missing_window_json_falls_back(self):
        """A fresh, valid index pointing at a window with no agent JSON yet."""
        self._write_active_window("3", age_s=0)  # no _write_window_json()
        self._assert_served(
            "SESSION_LEVEL",
            "with no per-window JSON there is nothing to serve but the "
            "session-level file")

    # -- C5/C6: the threshold ----------------------------------------------

    def test_c5_age_inside_budget_still_serves_the_window_file(self):
        """170s < 180s: the panel's 60s heartbeat has simply not landed yet."""
        self._write_window_json()
        self._write_active_window("3", age_s=170)
        self._assert_served(
            "WINDOW_3",
            "an index within the staleness budget must still be honoured — "
            "the guard must not be so tight that it breaks live panels")

    def test_c6_age_outside_budget_falls_back(self):
        """GUARD-CRITICAL. 190s > 180s: three missed heartbeats."""
        self._write_window_json()
        self._write_active_window("3", age_s=190)
        self._assert_served(
            "SESSION_LEVEL",
            "an index past the staleness budget was trusted — the guard is "
            "not enforcing its own threshold")


if __name__ == "__main__":
    unittest.main(verbosity=2)
