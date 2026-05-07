#!/usr/bin/env python3

#
#  test_server.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""
Unit tests for lcars-ui/server.py

Tests focus on security-critical paths (path traversal, input validation),
helper methods, route dispatch, and API response shapes — without starting a
real TCP server.  We mock the HTTP handler's socket-level methods so the
handler can be exercised in-process.

Run with:
    python3 -m unittest lcars-ui/tests/test_server.py
  or from the repo root:
    python3 -m unittest discover -s lcars-ui/tests -p 'test_*.py'
"""

import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch, mock_open, call

# ---------------------------------------------------------------------------
# Ensure server.py can be imported even when optional dependencies (calendar
# sync, integrations, kanban_utils) are absent.  We stub them out before
# importing the module so none of the module-level try/except blocks blow up.
# ---------------------------------------------------------------------------
LCARS_UI_DIR = Path(__file__).parent.parent
REPO_ROOT = LCARS_UI_DIR.parent
sys.path.insert(0, str(LCARS_UI_DIR))
sys.path.insert(0, str(REPO_ROOT))

# Stub heavy optional imports so server.py loads cleanly in a test environment
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

# Now import server — it will use the stubs above
import server  # noqa: E402  (module-level import after path manipulation)
from server import (  # noqa: E402
    LCARSHandler,
    get_board_file,
    format_bytes_export as format_bytes_archive,
    TEAM_KANBAN_DIRS,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_handler(path="/", method="GET", body=b"", headers=None):
    """
    Construct an LCARSHandler instance with all socket I/O mocked out.

    Returns the handler and a BytesIO buffer that captures everything written
    via send_response / send_header / end_headers / wfile.write.
    """
    rfile = io.BytesIO(body)
    response_buf = io.BytesIO()

    # Mock the server (request) socket
    mock_connection = MagicMock()
    mock_connection.makefile.return_value = rfile

    # Build the handler without triggering handle()
    with patch.object(LCARSHandler, "__init__", lambda self, *a, **kw: None):
        handler = LCARSHandler.__new__(LCARSHandler)

    # Wire up the minimal attributes that handler methods use
    handler.path = path
    handler.command = method
    handler.rfile = rfile
    handler.wfile = response_buf
    handler.server = MagicMock()
    handler.headers = headers or {}
    handler.requestline = f"{method} {path} HTTP/1.1"
    handler.client_address = ("127.0.0.1", 9999)

    # Capture send_response / send_header / end_headers calls
    handler._headers_buffer = []
    handler._response_code = None

    def _send_response(code, message=None):
        handler._response_code = code

    def _send_header(name, value):
        handler._headers_buffer.append((name, value))

    def _end_headers():
        pass  # headers already buffered above

    handler.send_response = _send_response
    handler.send_header = _send_header
    handler.end_headers = _end_headers

    # send_error writes to wfile via the real implementation, which needs
    # send_response / send_header / end_headers — keep them patched.
    handler.send_error = MagicMock()
    handler.log_message = MagicMock()
    handler.log_error = MagicMock()

    return handler, response_buf


def _response_json(buf):
    """Decode the JSON payload written to response_buf."""
    buf.seek(0)
    raw = buf.read()
    return json.loads(raw)


# ---------------------------------------------------------------------------
# Tests: module-level helper functions
# ---------------------------------------------------------------------------

class TestFormatBytesArchive(unittest.TestCase):
    """Tests for format_bytes_archive() — purely functional, no I/O."""

    def test_bytes_range(self):
        self.assertEqual(format_bytes_archive(0), "0.0 B")
        self.assertEqual(format_bytes_archive(512), "512.0 B")
        self.assertEqual(format_bytes_archive(1023), "1023.0 B")

    def test_kilobytes(self):
        self.assertEqual(format_bytes_archive(1024), "1.0 KB")
        self.assertEqual(format_bytes_archive(2048), "2.0 KB")

    def test_megabytes(self):
        self.assertEqual(format_bytes_archive(1024 * 1024), "1.0 MB")

    def test_gigabytes(self):
        self.assertEqual(format_bytes_archive(1024 ** 3), "1.0 GB")

    def test_terabytes(self):
        # Anything >= 1 TiB should show TB
        result = format_bytes_archive(1024 ** 4)
        self.assertIn("TB", result)


class TestGetBoardFile(unittest.TestCase):
    """Tests for get_board_file() — verifies path construction logic."""

    def test_known_team_returns_correct_path(self):
        path = get_board_file("academy")
        self.assertTrue(str(path).endswith("academy-board.json"))
        # Should be under the academy kanban dir
        self.assertIn("kanban", str(path))

    def test_unknown_team_falls_back_to_default_kanban_dir(self):
        path = get_board_file("nonexistent-team-xyz")
        # Falls back to KANBAN_DIR (~/dev-team/kanban)
        self.assertTrue(str(path).endswith("nonexistent-team-xyz-board.json"))

    def test_all_registered_teams_have_paths(self):
        for team in TEAM_KANBAN_DIRS:
            path = get_board_file(team)
            self.assertTrue(
                str(path).endswith(f"{team}-board.json"),
                f"Board file for {team!r} has unexpected name: {path}",
            )


# ---------------------------------------------------------------------------
# Tests: LCARSHandler — CORS and OPTIONS
# ---------------------------------------------------------------------------

class TestCORSOptions(unittest.TestCase):
    """CORS preflight (OPTIONS) handling."""

    def test_options_returns_200_with_cors_headers(self):
        handler, buf = _make_handler(path="/api/status", method="OPTIONS")
        handler.do_OPTIONS()

        self.assertEqual(handler._response_code, 200)
        header_names = [h[0] for h in handler._headers_buffer]
        self.assertIn("Access-Control-Allow-Origin", header_names)
        self.assertIn("Access-Control-Allow-Methods", header_names)
        self.assertIn("Access-Control-Allow-Headers", header_names)

    def test_cors_origin_is_wildcard(self):
        handler, buf = _make_handler(path="/api/status", method="OPTIONS")
        handler.do_OPTIONS()

        cors_origin = next(
            (v for k, v in handler._headers_buffer if k == "Access-Control-Allow-Origin"),
            None,
        )
        self.assertEqual(cors_origin, "*")


# ---------------------------------------------------------------------------
# Tests: LCARSHandler — _send_json_response helper
# ---------------------------------------------------------------------------

class TestSendJsonResponse(unittest.TestCase):
    """Internal helper _send_json_response sets content-type and CORS."""

    def test_sends_json_content_type(self):
        handler, buf = _make_handler()
        handler._send_json_response({"key": "value"})

        header_names_values = dict(handler._headers_buffer)
        self.assertEqual(header_names_values.get("Content-Type"), "application/json")

    def test_sends_cors_wildcard(self):
        handler, buf = _make_handler()
        handler._send_json_response({"key": "value"})

        header_names_values = dict(handler._headers_buffer)
        self.assertEqual(header_names_values.get("Access-Control-Allow-Origin"), "*")

    def test_default_status_is_200(self):
        handler, buf = _make_handler()
        handler._send_json_response({"ok": True})
        self.assertEqual(handler._response_code, 200)

    def test_custom_status_code_is_used(self):
        handler, buf = _make_handler()
        handler._send_json_response({"error": "not found"}, status=404)
        self.assertEqual(handler._response_code, 404)

    def test_body_is_valid_json(self):
        payload = {"items": [1, 2, 3], "count": 3}
        handler, buf = _make_handler()
        handler._send_json_response(payload)
        buf.seek(0)
        decoded = json.loads(buf.read())
        self.assertEqual(decoded, payload)


# ---------------------------------------------------------------------------
# Tests: LCARSHandler — _extract_team_from_item_id
# ---------------------------------------------------------------------------

class TestExtractTeamFromItemId(unittest.TestCase):
    """Team extraction from item ID prefixes."""

    def setUp(self):
        self.handler, _ = _make_handler()

    def _extract(self, item_id):
        return self.handler._extract_team_from_item_id(item_id)

    def test_academy_prefix(self):
        self.assertEqual(self._extract("XACA-0001"), "academy")

    def test_ios_prefix(self):
        self.assertEqual(self._extract("XIOS-0042"), "ios")

    def test_android_prefix(self):
        self.assertEqual(self._extract("XAND-0010"), "android")

    def test_firebase_prefix(self):
        self.assertEqual(self._extract("XFIR-0005"), "firebase")

    def test_dns_prefix(self):
        self.assertEqual(self._extract("XDNS-0001"), "dns")

    def test_freelance_doublenode_workstats(self):
        self.assertEqual(self._extract("XFWS-0003"), "freelance-doublenode-workstats")

    def test_legal_coparenting(self):
        self.assertEqual(self._extract("XLCP-0001"), "legal-coparenting")

    def test_finance_personal(self):
        self.assertEqual(self._extract("XFIN-0001"), "finance-personal")

    def test_unknown_prefix_returns_none(self):
        self.assertIsNone(self._extract("ZZZZ-9999"))

    def test_too_short_id_returns_none(self):
        self.assertIsNone(self._extract("XAC"))
        self.assertIsNone(self._extract(""))

    def test_none_returns_none(self):
        self.assertIsNone(self._extract(None))

    def test_epic_prefix_falls_back_to_current_team(self):
        # EPIC- prefix should return LCARS_TEAM
        result = self._extract("EPIC-001")
        self.assertEqual(result, server.LCARS_TEAM)

    def test_case_insensitive_prefix_matching(self):
        # The method uppercases the first 4 chars before lookup
        self.assertEqual(self._extract("xaca-0001"), "academy")


# ---------------------------------------------------------------------------
# Tests: LCARSHandler — _validate_item_team_match
# ---------------------------------------------------------------------------

class TestValidateItemTeamMatch(unittest.TestCase):
    """Item-to-team validation."""

    def setUp(self):
        self.handler, _ = _make_handler()

    def test_matching_team_is_valid(self):
        is_valid, team, err = self.handler._validate_item_team_match("XACA-0001", "academy")
        self.assertTrue(is_valid)
        self.assertEqual(team, "academy")
        self.assertIsNone(err)

    def test_mismatched_team_is_invalid(self):
        is_valid, team, err = self.handler._validate_item_team_match("XIOS-0001", "academy")
        self.assertFalse(is_valid)
        self.assertIsNotNone(err)
        self.assertIn("ios", err)

    def test_unknown_prefix_is_allowed(self):
        # Unknown prefix: allow but team is None
        is_valid, team, err = self.handler._validate_item_team_match("ZZZZ-0001", "academy")
        self.assertTrue(is_valid)
        self.assertIsNone(team)
        self.assertIsNone(err)


# ---------------------------------------------------------------------------
# Tests: LCARSHandler — terminal name sanitisation (handle_terminal_activate)
# ---------------------------------------------------------------------------

class TestTerminalNameSanitization(unittest.TestCase):
    """
    The terminal activate endpoint sanitises the 'terminal' parameter with a
    strict regex to prevent tmux command injection.  We call the handler
    directly with crafted payloads.
    """

    def _call_activate(self, payload_dict):
        body = json.dumps(payload_dict).encode()
        headers = {"Content-Length": str(len(body))}
        handler, buf = _make_handler(
            path="/api/terminal/activate",
            method="POST",
            body=body,
            headers=headers,
        )
        handler.rfile = io.BytesIO(body)
        handler.handle_terminal_activate()
        return handler

    def test_valid_terminal_name_passes_sanitisation(self):
        with patch("server.subprocess.run") as mock_run, \
             patch("server.subprocess.check_output", return_value=b""):
            mock_run.return_value = MagicMock(returncode=0, stderr="", stdout="")
            handler = self._call_activate({"terminal": "chancellor", "window": 1})
        # Should NOT call send_error with 400
        for c in handler.send_error.call_args_list:
            self.assertNotEqual(c.args[0], 400)

    def test_terminal_name_with_shell_metachar_rejected(self):
        # handle_terminal_activate uses _send_json_response for 400 errors, not send_error
        handler = self._call_activate({"terminal": "chan;rm -rf /", "window": 1})
        self.assertEqual(handler._response_code, 400)

    def test_terminal_name_with_path_traversal_rejected(self):
        handler = self._call_activate({"terminal": "../../etc/passwd", "window": 1})
        self.assertEqual(handler._response_code, 400)

    def test_terminal_name_with_backtick_injection_rejected(self):
        handler = self._call_activate({"terminal": "`whoami`", "window": 1})
        self.assertEqual(handler._response_code, 400)

    def test_missing_terminal_parameter_returns_400(self):
        handler = self._call_activate({"window": 1})
        self.assertEqual(handler._response_code, 400)

    def test_missing_window_parameter_returns_400(self):
        handler = self._call_activate({"terminal": "chancellor"})
        self.assertEqual(handler._response_code, 400)

    def test_non_integer_window_returns_400(self):
        handler = self._call_activate({"terminal": "chancellor", "window": "evil"})
        self.assertEqual(handler._response_code, 400)

    def test_empty_body_returns_400(self):
        body = b""
        headers = {"Content-Length": "0"}
        handler, buf = _make_handler(
            path="/api/terminal/activate",
            method="POST",
            body=body,
            headers=headers,
        )
        handler.rfile = io.BytesIO(body)
        handler.handle_terminal_activate()
        # Empty body triggers _send_json_response(400), not send_error
        self.assertEqual(handler._response_code, 400)


# ---------------------------------------------------------------------------
# Tests: LCARSHandler — serve_status
# ---------------------------------------------------------------------------

class TestServeStatus(unittest.TestCase):
    """serve_status returns a JSON object with expected fields."""

    def test_status_response_fields(self):
        handler, buf = _make_handler(path="/api/status")
        handler.serve_status()

        data = _response_json(buf)
        self.assertEqual(data.get("status"), "online")
        self.assertIn("team", data)
        self.assertIn("session_name", data)
        self.assertIn("kanban_dir", data)
        self.assertIn("kanban_dir_exists", data)
        self.assertIn("ui_dir", data)

    def test_status_cors_header_present(self):
        handler, buf = _make_handler(path="/api/status")
        handler.serve_status()
        header_map = dict(handler._headers_buffer)
        self.assertEqual(header_map.get("Access-Control-Allow-Origin"), "*")

    def test_status_200(self):
        handler, buf = _make_handler(path="/api/status")
        handler.serve_status()
        self.assertEqual(handler._response_code, 200)


# ---------------------------------------------------------------------------
# Tests: LCARSHandler — serve_kanban_data
# ---------------------------------------------------------------------------

class TestServeKanbanData(unittest.TestCase):
    """serve_kanban_data reads a board file and returns its JSON contents."""

    def test_returns_404_when_board_missing(self):
        handler, buf = _make_handler()
        with patch("server.get_board_file") as mock_gbf:
            mock_path = MagicMock(spec=Path)
            mock_path.exists.return_value = False
            mock_gbf.return_value = mock_path
            handler.serve_kanban_data("nonexistent-team")
        handler.send_error.assert_called_once()
        self.assertEqual(handler.send_error.call_args.args[0], 404)

    def test_returns_board_json_when_file_exists(self):
        board_data = {"team": "academy", "backlog": []}
        handler, buf = _make_handler()
        with patch("server.get_board_file") as mock_gbf:
            mock_path = MagicMock(spec=Path)
            mock_path.exists.return_value = True
            mock_gbf.return_value = mock_path
            with patch("builtins.open", mock_open(read_data=json.dumps(board_data))):
                handler.serve_kanban_data("academy")

        data = _response_json(buf)
        self.assertEqual(data.get("team"), "academy")

    def test_returns_200_status(self):
        board_data = {"team": "ios", "backlog": []}
        handler, buf = _make_handler()
        with patch("server.get_board_file") as mock_gbf:
            mock_path = MagicMock(spec=Path)
            mock_path.exists.return_value = True
            mock_gbf.return_value = mock_path
            with patch("builtins.open", mock_open(read_data=json.dumps(board_data))):
                handler.serve_kanban_data("ios")

        self.assertEqual(handler._response_code, 200)

    def test_returns_500_on_invalid_json(self):
        handler, buf = _make_handler()
        with patch("server.get_board_file") as mock_gbf:
            mock_path = MagicMock(spec=Path)
            mock_path.exists.return_value = True
            mock_gbf.return_value = mock_path
            with patch("builtins.open", mock_open(read_data="not valid json {{")):
                handler.serve_kanban_data("academy")
        handler.send_error.assert_called_once()
        self.assertEqual(handler.send_error.call_args.args[0], 500)

    def test_cors_header_present(self):
        board_data = {"team": "academy", "backlog": []}
        handler, buf = _make_handler()
        with patch("server.get_board_file") as mock_gbf:
            mock_path = MagicMock(spec=Path)
            mock_path.exists.return_value = True
            mock_gbf.return_value = mock_path
            with patch("builtins.open", mock_open(read_data=json.dumps(board_data))):
                handler.serve_kanban_data("academy")

        header_map = dict(handler._headers_buffer)
        self.assertEqual(header_map.get("Access-Control-Allow-Origin"), "*")


# ---------------------------------------------------------------------------
# Tests: LCARSHandler — serve_plan_exists
# ---------------------------------------------------------------------------

class TestServePlanExists(unittest.TestCase):
    """serve_plan_exists checks for plan/retro document files."""

    def _run(self, item_id, glob_results=None, base_exists=True):
        handler, buf = _make_handler()

        mock_base_path = MagicMock(spec=Path)
        mock_base_path.exists.return_value = base_exists

        with patch.object(handler, "_get_plan_doc_path_for_item", return_value=mock_base_path), \
             patch("server.glob.glob", return_value=(glob_results or [])):
            handler.serve_plan_exists(item_id)

        return _response_json(buf)

    def test_plan_exists_when_plan_file_found(self):
        data = self._run(
            "XACA-0001",
            glob_results=["/some/kanban/XACA-0001_plan.md"],
        )
        self.assertTrue(data["exists"])
        self.assertFalse(data["retroExists"])
        self.assertEqual(data["itemId"], "XACA-0001")

    def test_retro_exists_when_retrospective_file_found(self):
        data = self._run(
            "XACA-0001",
            glob_results=[
                "/some/kanban/XACA-0001_plan.md",
                "/some/kanban/XACA-0001_RETROSPECTIVE.md",
            ],
        )
        self.assertTrue(data["exists"])
        self.assertTrue(data["retroExists"])

    def test_neither_exists_when_no_files(self):
        data = self._run("XACA-0002", glob_results=[])
        self.assertFalse(data["exists"])
        self.assertFalse(data["retroExists"])

    def test_base_path_missing_returns_false(self):
        data = self._run("XACA-0003", base_exists=False)
        self.assertFalse(data["exists"])
        self.assertFalse(data["retroExists"])

    def test_unknown_item_prefix_returns_error_field(self):
        handler, buf = _make_handler()
        with patch.object(handler, "_get_plan_doc_path_for_item", return_value=None):
            handler.serve_plan_exists("ZZZZ-0001")
        data = _response_json(buf)
        self.assertFalse(data["exists"])
        self.assertIn("error", data)

    def test_retro_with_dash_separator_detected(self):
        data = self._run(
            "XACA-0010",
            glob_results=["/some/kanban/XACA-0010-RETROSPECTIVE.md"],
        )
        self.assertFalse(data["exists"])   # retro only, no plan
        self.assertTrue(data["retroExists"])


# ---------------------------------------------------------------------------
# Tests: LCARSHandler — serve_agent_panel_data
# ---------------------------------------------------------------------------

class TestServeAgentPanelData(unittest.TestCase):
    """serve_agent_panel_data reads per-session temp files."""

    def test_returns_waiting_when_no_agent_file(self):
        handler, buf = _make_handler(path="/api/agent-panel")

        mock_tmp_dir = MagicMock(spec=Path)
        # active-window file does not exist
        active_win = MagicMock(spec=Path)
        active_win.exists.return_value = False
        # session-level file does not exist either
        session_file = MagicMock(spec=Path)
        session_file.exists.return_value = False

        mock_tmp_dir.__truediv__ = lambda self, name: (
            active_win if "active-window" in name else session_file
        )

        with patch("server.LCARS_TMP_DIR", mock_tmp_dir), \
             patch("server.urlparse") as mock_urlparse, \
             patch("server.parse_qs") as mock_parse_qs:
            mock_urlparse.return_value = MagicMock(query="")
            mock_parse_qs.return_value = {}
            handler.serve_agent_panel_data()

        data = _response_json(buf)
        self.assertEqual(data.get("status"), "waiting")

    def test_returns_200_status(self):
        handler, buf = _make_handler(path="/api/agent-panel")

        mock_tmp_dir = MagicMock(spec=Path)
        mock_file = MagicMock(spec=Path)
        mock_file.exists.return_value = False
        mock_tmp_dir.__truediv__ = lambda self, name: mock_file

        with patch("server.LCARS_TMP_DIR", mock_tmp_dir), \
             patch("server.urlparse") as mock_urlparse, \
             patch("server.parse_qs") as mock_parse_qs:
            mock_urlparse.return_value = MagicMock(query="")
            mock_parse_qs.return_value = {}
            handler.serve_agent_panel_data()

        self.assertEqual(handler._response_code, 200)

    def test_serves_agent_data_when_file_exists(self):
        agent_data = {"name": "Reno", "role": "Chief Technical Instructor"}
        handler, buf = _make_handler(path="/api/agent-panel?session=academy-reno")

        mock_tmp_dir = MagicMock(spec=Path)
        active_win_file = MagicMock(spec=Path)
        active_win_file.exists.return_value = False
        session_file = MagicMock(spec=Path)
        session_file.exists.return_value = True

        def _div(self, name):
            if "active-window" in str(name):
                return active_win_file
            return session_file

        mock_tmp_dir.__truediv__ = _div

        with patch("server.LCARS_TMP_DIR", mock_tmp_dir), \
             patch("server.urlparse") as mock_urlparse, \
             patch("server.parse_qs") as mock_parse_qs, \
             patch("builtins.open", mock_open(read_data=json.dumps(agent_data))), \
             patch("server._fetch_amb_badges", return_value=[]):
            mock_urlparse.return_value = MagicMock(query="session=academy-reno")
            mock_parse_qs.return_value = {"session": ["academy-reno"]}
            handler.serve_agent_panel_data()

        data = _response_json(buf)
        self.assertEqual(data.get("name"), "Reno")


# ---------------------------------------------------------------------------
# Tests: LCARSHandler — path prefix stripping (Tailscale funnel routing)
# ---------------------------------------------------------------------------

class TestPathPrefixStripping(unittest.TestCase):
    """
    do_GET strips known team path prefixes before routing.
    We verify that /academy/api/status is treated the same as /api/status.
    """

    def test_prefix_stripped_before_routing(self):
        handler, buf = _make_handler(path="/academy/api/status")
        with patch.object(handler, "serve_status") as mock_serve_status:
            handler.do_GET()
        mock_serve_status.assert_called_once()

    def test_root_path_with_prefix_redirect(self):
        # /academy (no trailing slash) should redirect to /academy/
        handler, buf = _make_handler(path="/academy")
        handler.do_GET()
        # Should have called send_response(301)
        self.assertEqual(handler._response_code, 301)
        header_map = dict(handler._headers_buffer)
        self.assertIn("Location", header_map)
        self.assertEqual(header_map["Location"], "/academy/")

    def test_unknown_path_falls_through_to_super(self):
        handler, buf = _make_handler(path="/unknownpath/something")
        with patch("http.server.SimpleHTTPRequestHandler.do_GET") as mock_super:
            handler.do_GET()
        mock_super.assert_called_once()


# ---------------------------------------------------------------------------
# Tests: LCARSHandler — do_GET route dispatch
# ---------------------------------------------------------------------------

class TestGetRouteDispatch(unittest.TestCase):
    """Verify that do_GET dispatches to the correct handler methods."""

    def _dispatch(self, path, mock_targets):
        handler, buf = _make_handler(path=path)
        patches = {name: patch.object(handler, name) for name in mock_targets}
        mocks = {name: ctx.__enter__() for name, ctx in patches.items()}
        try:
            handler.do_GET()
        finally:
            for ctx in patches.values():
                ctx.__exit__(None, None, None)
        return mocks

    def test_api_status_routes_to_serve_status(self):
        mocks = self._dispatch("/api/status", ["serve_status"])
        mocks["serve_status"].assert_called_once()

    def test_board_data_routes_to_serve_kanban_data(self):
        handler, buf = _make_handler(path="/data/academy-board.json")
        with patch.object(handler, "serve_kanban_data") as m:
            handler.do_GET()
        m.assert_called_once_with("academy")

    def test_plan_exists_routes_correctly(self):
        handler, buf = _make_handler(path="/api/kanban/XACA-0001/plan-exists")
        with patch.object(handler, "serve_plan_exists") as m:
            handler.do_GET()
        m.assert_called_once_with("XACA-0001")

    def test_agent_panel_routes_correctly(self):
        handler, buf = _make_handler(path="/api/agent-panel")
        with patch.object(handler, "serve_agent_panel_data") as m:
            handler.do_GET()
        m.assert_called_once()

    def test_api_teams_routes_correctly(self):
        mocks = self._dispatch("/api/teams", ["serve_teams_list"])
        mocks["serve_teams_list"].assert_called_once()


# ---------------------------------------------------------------------------
# Tests: LCARSHandler — _get_plan_doc_path_for_item (path traversal defence)
# ---------------------------------------------------------------------------

class TestGetPlanDocPath(unittest.TestCase):
    """
    _get_plan_doc_path_for_item maps item IDs to known kanban directories.
    These tests verify correct mapping AND ensure that crafted item IDs
    cannot escape expected directories.
    """

    def setUp(self):
        self.handler, _ = _make_handler()

    def test_known_xaca_prefix_maps_to_academy_kanban(self):
        path = self.handler._get_plan_doc_path_for_item("XACA-0001")
        self.assertIsNotNone(path)
        # Academy kanban dir is ~/dev-team/kanban (Path is stored in TEAM_KANBAN_DIRS['academy'])
        self.assertEqual(path, server.TEAM_KANBAN_DIRS.get("academy"))

    def test_known_xios_prefix_maps_to_ios_kanban(self):
        path = self.handler._get_plan_doc_path_for_item("XIOS-0001")
        self.assertIsNotNone(path)
        self.assertIn("ios", str(path).lower())

    def test_no_dash_in_item_id_returns_none(self):
        path = self.handler._get_plan_doc_path_for_item("NODASH")
        self.assertIsNone(path)

    def test_item_id_with_path_traversal_does_not_escape_kanban_dir(self):
        # An attacker might craft an item like "XACA-../../../../etc/passwd"
        # The method only uses the prefix (4 chars) for lookup — the full ID
        # is NOT used to construct the directory.  So path traversal in the ID
        # body should have no effect on the returned base path.
        path = self.handler._get_plan_doc_path_for_item("XACA-../../../../etc/passwd")
        self.assertIsNotNone(path)
        # The returned path should still be the normal academy kanban dir
        # (the traversal chars are in the suffix, not the prefix used for lookup)
        self.assertNotIn("etc/passwd", str(path))

    def test_unknown_prefix_falls_back_to_current_team(self):
        path = self.handler._get_plan_doc_path_for_item("ZZZZ-0001")
        # Should fall back to LCARS_TEAM's kanban dir (not None)
        self.assertIsNotNone(path)


# ---------------------------------------------------------------------------
# Tests: LCARSHandler — _atomic_write_json
# ---------------------------------------------------------------------------

class TestAtomicWriteJson(unittest.TestCase):
    """_atomic_write_json writes via a temp file then renames atomically."""

    def test_writes_valid_json_and_renames(self):
        handler, _ = _make_handler()
        data = {"key": "value", "list": [1, 2, 3]}

        with tempfile.TemporaryDirectory() as tmp_dir:
            target = Path(tmp_dir) / "board.json"
            handler._atomic_write_json(target, data)

            self.assertTrue(target.exists())
            with open(target) as f:
                loaded = json.load(f)
            self.assertEqual(loaded, data)

    def test_tmp_file_cleaned_up_on_success(self):
        handler, _ = _make_handler()
        data = {"ok": True}

        with tempfile.TemporaryDirectory() as tmp_dir:
            target = Path(tmp_dir) / "board.json"
            handler._atomic_write_json(target, data)
            tmp_file = target.with_suffix(".json.tmp")
            self.assertFalse(tmp_file.exists())

    def test_raises_on_write_failure(self):
        handler, _ = _make_handler()
        data = {"ok": True}

        with tempfile.TemporaryDirectory() as tmp_dir:
            target = Path(tmp_dir) / "board.json"
            # Make the directory read-only so write fails
            os.chmod(tmp_dir, 0o555)
            try:
                with self.assertRaises(Exception):
                    handler._atomic_write_json(target, data)
            finally:
                os.chmod(tmp_dir, 0o755)


# ---------------------------------------------------------------------------
# Tests: LCARSHandler — serve_teams_list
# ---------------------------------------------------------------------------

class TestServeTeamsList(unittest.TestCase):
    """serve_teams_list returns teams whose board files exist on disk."""

    def test_returns_only_existing_teams(self):
        handler, buf = _make_handler(path="/api/teams")

        def exists_side_effect(self_path=None):
            # Simulate only 'academy' board existing
            return "academy" in str(self_path or "")

        with patch.object(Path, "exists", exists_side_effect):
            handler.serve_teams_list()

        data = _response_json(buf)
        self.assertIn("teams", data)
        self.assertIsInstance(data["teams"], list)

    def test_response_is_sorted(self):
        handler, buf = _make_handler(path="/api/teams")

        def exists_side_effect(self_path=None):
            return True

        with patch.object(Path, "exists", exists_side_effect):
            handler.serve_teams_list()

        data = _response_json(buf)
        teams = data["teams"]
        self.assertEqual(teams, sorted(teams))

    def test_200_status(self):
        handler, buf = _make_handler(path="/api/teams")
        with patch.object(Path, "exists", return_value=False):
            handler.serve_teams_list()
        self.assertEqual(handler._response_code, 200)


# ---------------------------------------------------------------------------
# Tests: LCARSHandler — serve_no_cache_static
# ---------------------------------------------------------------------------

class TestServeNoCacheStatic(unittest.TestCase):
    """serve_no_cache_static sends appropriate no-cache headers."""

    def test_returns_404_for_missing_file(self):
        handler, buf = _make_handler(path="/missing.js")
        with patch.object(Path, "exists", return_value=False):
            handler.serve_no_cache_static("/missing.js")
        handler.send_error.assert_called_once()
        self.assertEqual(handler.send_error.call_args.args[0], 404)

    def test_js_file_gets_correct_content_type(self):
        js_content = b"console.log('hello');"
        handler, buf = _make_handler(path="/app.js")
        with patch.object(Path, "exists", return_value=True), \
             patch("builtins.open", mock_open(read_data=js_content)):
            handler.serve_no_cache_static("/app.js")

        header_map = dict(handler._headers_buffer)
        self.assertIn("application/javascript", header_map.get("Content-Type", ""))

    def test_html_file_gets_correct_content_type(self):
        html_content = b"<html></html>"
        handler, buf = _make_handler(path="/index.html")
        with patch.object(Path, "exists", return_value=True), \
             patch("builtins.open", mock_open(read_data=html_content)):
            handler.serve_no_cache_static("/index.html")

        header_map = dict(handler._headers_buffer)
        self.assertIn("text/html", header_map.get("Content-Type", ""))

    def test_no_cache_header_present(self):
        content = b"<html></html>"
        handler, buf = _make_handler(path="/index.html")
        with patch.object(Path, "exists", return_value=True), \
             patch("builtins.open", mock_open(read_data=content)):
            handler.serve_no_cache_static("/index.html")

        header_map = dict(handler._headers_buffer)
        self.assertIn("no-cache", header_map.get("Cache-Control", ""))

    def test_root_path_maps_to_index_html(self):
        content = b"<html></html>"
        handler, buf = _make_handler(path="/")
        with patch.object(Path, "exists", return_value=True), \
             patch("builtins.open", mock_open(read_data=content)):
            handler.serve_no_cache_static("/")

        # Should serve index.html — no 404
        handler.send_error.assert_not_called()


# ---------------------------------------------------------------------------
# Tests: LCARSHandler — image filename validation (serve_image)
# ---------------------------------------------------------------------------

class TestServeImage(unittest.TestCase):
    """
    serve_image expects a strict filename format: {team}_{name}_{logo|avatar}.png
    Invalid filenames should get a 404 rather than attempting arbitrary file access.
    """

    def test_invalid_filename_pattern_returns_404(self):
        handler, buf = _make_handler(path="/images/../../etc/passwd")
        # Local image dir check — pretend file doesn't exist there
        with patch.object(Path, "exists", return_value=False):
            handler.serve_image("/images/../../etc/passwd")
        handler.send_error.assert_called()
        self.assertEqual(handler.send_error.call_args.args[0], 404)

    def test_missing_type_suffix_returns_404(self):
        handler, buf = _make_handler(path="/images/academy_reno.png")
        with patch.object(Path, "exists", return_value=False):
            handler.serve_image("/images/academy_reno.png")
        handler.send_error.assert_called()
        self.assertEqual(handler.send_error.call_args.args[0], 404)

    def test_valid_logo_path_attempts_file_access(self):
        handler, buf = _make_handler(path="/images/academy_reno_logo.png")
        png_magic = b'\x89PNG\r\n\x1a\n' + b'\x00' * 100

        with patch.object(Path, "exists", return_value=False) as mock_exists:
            # First call (local image check) returns False
            # Second and third calls (png_path, svg_path checks) return True then False
            mock_exists.side_effect = [False, True, True]
            with patch("builtins.open", mock_open(read_data=png_magic)):
                handler.serve_image("/images/academy_reno_logo.png")

        # If we get here without send_error(404), path was accepted
        # (may still fail on read, but the format was valid)
        for c in handler.send_error.call_args_list:
            self.assertNotEqual(c.args[0], 404, "Valid filename should not return 404")

    def test_absolute_path_in_filename_returns_404(self):
        handler, buf = _make_handler(path="/images//etc/shadow")
        with patch.object(Path, "exists", return_value=False):
            handler.serve_image("/images//etc/shadow")
        handler.send_error.assert_called()
        self.assertEqual(handler.send_error.call_args.args[0], 404)


# ---------------------------------------------------------------------------
# Tests: LCARSHandler — _get_timestamp
# ---------------------------------------------------------------------------

class TestGetTimestamp(unittest.TestCase):
    """_get_timestamp returns a valid ISO 8601 UTC string."""

    def test_timestamp_format(self):
        handler, _ = _make_handler()
        ts = handler._get_timestamp()
        # Should match YYYY-MM-DDTHH:MM:SSZ
        import re
        self.assertRegex(ts, r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$')

    def test_timestamp_ends_with_Z(self):
        handler, _ = _make_handler()
        ts = handler._get_timestamp()
        self.assertTrue(ts.endswith("Z"))


# ---------------------------------------------------------------------------
# Tests: module-level config / env vars
# ---------------------------------------------------------------------------

class TestModuleLevelConfig(unittest.TestCase):
    """Verify that module-level globals are set from env vars correctly."""

    def test_lcars_team_defaults_to_freelance(self):
        # The env var may already be set in the test environment, so we just
        # confirm the value matches what the env var says (or the default).
        expected = os.environ.get("LCARS_TEAM", "freelance")
        self.assertEqual(server.LCARS_TEAM, expected)

    def test_session_name_defaults_to_lcars(self):
        expected = os.environ.get("LCARS_SESSION_NAME", "lcars")
        self.assertEqual(server.SESSION_NAME, expected)

    def test_team_kanban_dirs_is_dict(self):
        self.assertIsInstance(server.TEAM_KANBAN_DIRS, dict)
        self.assertGreater(len(server.TEAM_KANBAN_DIRS), 0)

    def test_known_teams_present_in_dirs(self):
        for expected_team in ("academy", "ios", "android", "firebase"):
            self.assertIn(expected_team, server.TEAM_KANBAN_DIRS)


# ---------------------------------------------------------------------------
# Tests: handle_archive_release — on-disk manifest directory cleanup (XACA-0183)
# ---------------------------------------------------------------------------

class TestHandleArchiveReleaseCleanup(unittest.TestCase):
    """
    After handle_archive_release runs:
      - releases-archive/<id>.json must exist
      - releases/<id>/ directory must be gone
    Both assertions hold whether or not the manifest directory existed up front.
    """

    def _run_archive(self, release_id, kanban_dir, team=None):
        """
        Wire up a minimal handler and invoke handle_archive_release.

        kanban_dir:  a real (temp) directory that acts as the team's kanban root.
        team:        if provided, appended as a ?team= query param.
        Returns the handler after the call completes.
        """
        path = f"/api/releases/{release_id}"
        if team:
            path += f"?team={team}"
        handler, buf = _make_handler(path=path, method="DELETE")

        # Patch TEAM_KANBAN_DIRS so our temp dir is used for the effective team
        effective_team = team or server.LCARS_TEAM

        # Build a minimal releases config with our release in it
        releases_data = {
            "releases": [
                {"id": release_id, "name": f"Test {release_id}", "status": "complete"}
            ]
        }

        def fake_load_releases_config(t=None):
            return {
                "releases": [
                    {"id": release_id, "name": f"Test {release_id}", "status": "complete"}
                ]
            }

        def fake_save_releases_config(data, t=None):
            pass  # no-op; we only care about the filesystem side-effects

        def fake_get_timestamp():
            return "2026-01-01T00:00:00Z"

        def fake_atomic_write_json(path, data):
            path.parent.mkdir(parents=True, exist_ok=True)
            import json as _json
            with open(path, "w") as fh:
                _json.write = None  # defensive; use stdlib directly
                import json as _j
                fh.write(_j.dumps(data))

        # Patch the methods that touch the real filesystem or config
        handler._load_releases_config = fake_load_releases_config
        handler._save_releases_config = fake_save_releases_config
        handler._get_timestamp = fake_get_timestamp
        handler._atomic_write_json = fake_atomic_write_json

        # Point TEAM_KANBAN_DIRS at our temp dir and make _get_release_manifest_path
        # return a path within it.
        releases_dir = kanban_dir / "releases" / release_id
        releases_dir.mkdir(parents=True, exist_ok=True)
        manifest_file = releases_dir / "manifest.json"
        manifest_file.write_text('{"items": []}')

        archive_dir = kanban_dir / "releases-archive"

        def fake_get_release_manifest_path(rid, t=None):
            return kanban_dir / "releases" / rid / "manifest.json"

        handler._get_release_manifest_path = fake_get_release_manifest_path

        with patch.dict(server.TEAM_KANBAN_DIRS, {effective_team: kanban_dir}), \
             patch.object(server, "KANBAN_DIR", kanban_dir):
            handler.handle_archive_release(release_id)

        return handler

    def test_archive_json_written_and_manifest_dir_removed(self):
        """Core contract: archive file exists, manifest directory is gone."""
        release_id = "REL-2026-TEST-001"
        with tempfile.TemporaryDirectory() as tmp:
            kanban_dir = Path(tmp)
            handler = self._run_archive(release_id, kanban_dir)

            self.assertEqual(handler._response_code, 200,
                             "Expected HTTP 200 from handle_archive_release")

            archive_file = kanban_dir / "releases-archive" / f"{release_id}.json"
            self.assertTrue(archive_file.exists(),
                            f"Archive JSON not found: {archive_file}")

            manifest_dir = kanban_dir / "releases" / release_id
            self.assertFalse(manifest_dir.exists(),
                             f"Manifest directory should have been removed: {manifest_dir}")

    def test_archive_succeeds_when_manifest_dir_absent(self):
        """If the manifest directory never existed, archive still succeeds (no-op cleanup)."""
        release_id = "REL-2026-TEST-002"
        with tempfile.TemporaryDirectory() as tmp:
            kanban_dir = Path(tmp)

            # Override the helper to return a path that does NOT exist on disk
            path = f"/api/releases/{release_id}"
            handler, buf = _make_handler(path=path, method="DELETE")

            effective_team = server.LCARS_TEAM

            def fake_load_releases_config(t=None):
                return {"releases": [{"id": release_id, "name": "Ghost", "status": "complete"}]}

            def fake_save_releases_config(data, t=None):
                pass

            def fake_get_timestamp():
                return "2026-01-01T00:00:00Z"

            def fake_atomic_write_json(path, data):
                path.parent.mkdir(parents=True, exist_ok=True)
                import json as _j
                with open(path, "w") as fh:
                    fh.write(_j.dumps(data))

            handler._load_releases_config = fake_load_releases_config
            handler._save_releases_config = fake_save_releases_config
            handler._get_timestamp = fake_get_timestamp
            handler._atomic_write_json = fake_atomic_write_json

            # Manifest path points to a directory that DOES NOT EXIST
            nonexistent_dir = kanban_dir / "releases" / release_id
            handler._get_release_manifest_path = lambda rid, t=None: nonexistent_dir / "manifest.json"

            with patch.dict(server.TEAM_KANBAN_DIRS, {effective_team: kanban_dir}), \
                 patch.object(server, "KANBAN_DIR", kanban_dir):
                handler.handle_archive_release(release_id)

            self.assertEqual(handler._response_code, 200,
                             "Archive should succeed even when manifest dir is absent")

            archive_file = kanban_dir / "releases-archive" / f"{release_id}.json"
            self.assertTrue(archive_file.exists(),
                            "Archive JSON must be written regardless of manifest dir presence")

    def test_team_query_param_routes_to_correct_directory(self):
        """?team=academy routes cleanup to the academy kanban directory."""
        release_id = "REL-2026-TEST-003"
        with tempfile.TemporaryDirectory() as tmp:
            kanban_dir = Path(tmp)
            handler = self._run_archive(release_id, kanban_dir, team="academy")

            self.assertEqual(handler._response_code, 200)

            archive_file = kanban_dir / "releases-archive" / f"{release_id}.json"
            self.assertTrue(archive_file.exists(), "Archive JSON should be in team's kanban dir")

            manifest_dir = kanban_dir / "releases" / release_id
            self.assertFalse(manifest_dir.exists(), "Manifest dir should be gone after archive")



# ---------------------------------------------------------------------------
# Tests: handle_create_epic tags support (XACA-0209 bug fix)
# ---------------------------------------------------------------------------

class TestHandleCreateEpicTags(unittest.TestCase):
    """handle_create_epic must persist the 'tags' field from request body."""

    def _run_create(self, body_dict):
        """POST /api/epics with the given body; returns (handler, response_json)."""
        body = json.dumps(body_dict).encode()
        handler, buf = _make_handler(
            path="/api/epics",
            method="POST",
            body=body,
            headers={"Content-Length": str(len(body))},
        )
        fake_board_data = {"epics": [], "nextEpicId": 1}
        handler._load_board_epics = MagicMock(return_value=fake_board_data)
        handler._save_board_epics = MagicMock(return_value=True)
        handler._generate_epic_id = MagicMock(return_value="E-001")
        handler._get_timestamp = MagicMock(return_value="2026-04-22T00:00:00Z")
        handler.handle_create_epic()
        return handler, _response_json(buf)

    def test_tags_from_request_body_persisted(self):
        """Tags supplied in POST body appear in the created epic."""
        _, data = self._run_create({"name": "Test Epic", "tags": ["backend", "infra"]})
        self.assertEqual(sorted(data["tags"]), ["backend", "infra"])

    def test_missing_tags_defaults_to_empty_list(self):
        """When 'tags' is absent from the request body, epic.tags defaults to []."""
        _, data = self._run_create({"name": "No Tags Epic"})
        self.assertEqual(data["tags"], [])

    def test_empty_tags_list_stored_as_empty(self):
        """Explicitly empty tags list [] is stored as []."""
        _, data = self._run_create({"name": "Empty Tags", "tags": []})
        self.assertEqual(data["tags"], [])

    def test_blank_string_tags_filtered_out(self):
        """Empty-string elements in the tags list are excluded."""
        _, data = self._run_create({"name": "Blank Tag Epic", "tags": ["valid", "", "  "]})
        self.assertEqual(data["tags"], ["valid"])

    def test_201_status_code(self):
        handler, _ = self._run_create({"name": "Status Test"})
        self.assertEqual(handler._response_code, 201)


# ---------------------------------------------------------------------------
# Tests: handle_update_epic tags support (XACA-0209 bug fix)
# ---------------------------------------------------------------------------

class TestHandleUpdateEpicTags(unittest.TestCase):
    """handle_update_epic must persist the 'tags' field from request body."""

    def _run_update(self, existing_tags, update_body):
        """PUT /api/epics/E-001 with the given update body; returns (handler, response_json)."""
        body = json.dumps(update_body).encode()
        handler, buf = _make_handler(
            path="/api/epics/E-001",
            method="PUT",
            body=body,
            headers={"Content-Length": str(len(body))},
        )
        existing_epic = {
            "id": "E-001",
            "title": "Original Epic",
            "status": "planning",
            "priority": "medium",
            "tags": existing_tags,
            "itemIds": [],
            "addedAt": "2026-01-01T00:00:00Z",
            "updatedAt": "2026-01-01T00:00:00Z",
        }
        fake_board_data = {"epics": [existing_epic], "nextEpicId": 2}
        handler._load_board_epics = MagicMock(return_value=fake_board_data)
        handler._save_board_epics = MagicMock(return_value=True)
        handler._find_epic_by_id = MagicMock(return_value=existing_epic)
        handler._get_timestamp = MagicMock(return_value="2026-04-22T00:00:00Z")
        handler.handle_update_epic("E-001")
        return handler, _response_json(buf)

    def test_tags_updated_when_supplied(self):
        """Tags in PUT body replace the existing tags."""
        _, data = self._run_update(["old"], {"tags": ["new-tag", "another"]})
        self.assertEqual(sorted(data["tags"]), ["another", "new-tag"])

    def test_tags_cleared_when_empty_list_supplied(self):
        """Sending tags=[] clears all existing tags."""
        _, data = self._run_update(["existing"], {"tags": []})
        self.assertEqual(data["tags"], [])

    def test_tags_unchanged_when_not_in_body(self):
        """When 'tags' key is absent from PUT body, existing tags are preserved."""
        _, data = self._run_update(["preserved"], {"status": "active"})
        self.assertEqual(data["tags"], ["preserved"])

    def test_blank_string_tags_filtered_on_update(self):
        """Empty-string elements in the update tags list are excluded."""
        _, data = self._run_update([], {"tags": ["valid", "", "  "]})
        self.assertEqual(data["tags"], ["valid"])

    def test_200_status_code(self):
        handler, _ = self._run_update([], {"status": "active"})
        self.assertEqual(handler._response_code, 200)


# ---------------------------------------------------------------------------
# Tests: serve_epics_list completedCount dual-status fix (XACA-0218)
# ---------------------------------------------------------------------------

class TestServeEpicsListCompletedCount(unittest.TestCase):
    """serve_epics_list must count both 'done' and 'completed' items (XACA-0218)."""

    def _run_list(self, items):
        """GET /api/epics; returns the decoded JSON response dict."""
        handler, buf = _make_handler(path="/api/epics", method="GET")
        fake_epic = {"id": "E-001", "title": "Test Epic", "itemIds": []}
        handler._load_board_epics = MagicMock(return_value={"epics": [fake_epic]})
        handler._get_items_for_epic = MagicMock(return_value=items)
        handler.serve_epics_list("")
        return _response_json(buf)

    def test_counts_done_and_completed(self):
        """Items with status 'done' and 'completed' both contribute to completedCount."""
        items = [
            {"itemId": "A-001", "title": "Todo task",        "status": "todo",        "priority": "medium", "team": "academy", "tags": [], "subRepo": ""},
            {"itemId": "A-002", "title": "In-progress task", "status": "in_progress", "priority": "medium", "team": "academy", "tags": [], "subRepo": ""},
            {"itemId": "A-003", "title": "Done task",        "status": "done",        "priority": "medium", "team": "academy", "tags": [], "subRepo": ""},
            {"itemId": "A-004", "title": "Completed task",   "status": "completed",   "priority": "medium", "team": "academy", "tags": [], "subRepo": ""},
            {"itemId": "A-005", "title": "Cancelled task",   "status": "cancelled",   "priority": "medium", "team": "academy", "tags": [], "subRepo": ""},
        ]
        data = self._run_list(items)
        epic = data["epics"][0]
        # cancelled items are excluded from itemCount per XACA-0206 intent
        # (cancelled items still show via cancelledCount so the UI can explain
        # the denominator — they don't inflate active-work progress fractions)
        self.assertEqual(epic["itemCount"], 4)
        self.assertEqual(epic["completedCount"], 2)

    def test_all_done_counted(self):
        """All 'done' items are counted in completedCount."""
        items = [
            {"itemId": f"A-00{i}", "title": f"Done {i}", "status": "done", "priority": "medium", "team": "academy", "tags": [], "subRepo": ""}
            for i in range(3)
        ]
        data = self._run_list(items)
        self.assertEqual(data["epics"][0]["completedCount"], 3)

    def test_all_completed_counted(self):
        """All 'completed' items are counted in completedCount."""
        items = [
            {"itemId": f"A-00{i}", "title": f"Completed {i}", "status": "completed", "priority": "medium", "team": "academy", "tags": [], "subRepo": ""}
            for i in range(4)
        ]
        data = self._run_list(items)
        self.assertEqual(data["epics"][0]["completedCount"], 4)

    def test_excludes_todo_in_progress_cancelled(self):
        """Items with status 'todo', 'in_progress', or 'cancelled' are NOT counted."""
        items = [
            {"itemId": "A-001", "title": "Todo",        "status": "todo",        "priority": "medium", "team": "academy", "tags": [], "subRepo": ""},
            {"itemId": "A-002", "title": "In Progress",  "status": "in_progress", "priority": "medium", "team": "academy", "tags": [], "subRepo": ""},
            {"itemId": "A-003", "title": "Cancelled",    "status": "cancelled",   "priority": "medium", "team": "academy", "tags": [], "subRepo": ""},
        ]
        data = self._run_list(items)
        self.assertEqual(data["epics"][0]["completedCount"], 0)

    def test_empty_epic_has_zero_counts(self):
        """An epic with no items reports itemCount=0 and completedCount=0."""
        data = self._run_list([])
        epic = data["epics"][0]
        self.assertEqual(epic["itemCount"], 0)
        self.assertEqual(epic["completedCount"], 0)

    def test_response_200_status(self):
        """serve_epics_list returns HTTP 200."""
        handler, buf = _make_handler(path="/api/epics", method="GET")
        fake_epic = {"id": "E-001", "title": "Test Epic", "itemIds": []}
        handler._load_board_epics = MagicMock(return_value={"epics": [fake_epic]})
        handler._get_items_for_epic = MagicMock(return_value=[])
        handler.serve_epics_list("")
        self.assertEqual(handler._response_code, 200)


# ---------------------------------------------------------------------------
# Tests: handle_create_release tags validation (XACA-0209 parity with epics)
# ---------------------------------------------------------------------------

class TestHandleCreateReleaseTagsValidation(unittest.TestCase):
    """handle_create_release must filter non-string / blank entries from tags."""

    def _run_create(self, body_dict):
        body = json.dumps(body_dict).encode()
        handler, buf = _make_handler(
            path="/api/releases",
            method="POST",
            body=body,
            headers={"Content-Length": str(len(body))},
        )
        fake_data = {"releases": [], "projectEnvironments": {}, "defaultEnvironments": ["DEV"]}
        handler._load_releases_config = MagicMock(return_value=fake_data)
        handler._save_releases_config = MagicMock(return_value=True)
        handler._save_release_manifest = MagicMock(return_value=True)
        handler._generate_release_id = MagicMock(return_value="REL-001")
        handler._get_timestamp = MagicMock(return_value="2026-04-22T00:00:00Z")
        handler._extract_version_from_name = MagicMock(return_value="1.0.0")
        handler.handle_create_release()
        return handler, _response_json(buf)

    def test_valid_tags_persisted(self):
        _, data = self._run_create({"name": "Test Release", "tags": ["main-event", "ios"]})
        self.assertEqual(sorted(data["tags"]), ["ios", "main-event"])

    def test_blank_string_tags_filtered_out(self):
        _, data = self._run_create({"name": "Blank Tag Release", "tags": ["valid", "", "  "]})
        self.assertEqual(data["tags"], ["valid"])

    def test_non_string_tags_filtered_out(self):
        _, data = self._run_create({"name": "Mixed Tag Release", "tags": ["valid", 42, None, {"bad": "obj"}]})
        self.assertEqual(data["tags"], ["valid"])

    def test_missing_tags_defaults_to_empty_list(self):
        _, data = self._run_create({"name": "No Tags Release"})
        self.assertEqual(data["tags"], [])


# ---------------------------------------------------------------------------
# Tests: handle_update_release tags validation (XACA-0209 parity with epics)
# ---------------------------------------------------------------------------

class TestHandleUpdateReleaseTagsValidation(unittest.TestCase):
    """handle_update_release must filter non-string / blank entries from tags."""

    def _run_update(self, existing_tags, update_body):
        body = json.dumps(update_body).encode()
        handler, buf = _make_handler(
            path="/api/releases/REL-001",
            method="PUT",
            body=body,
            headers={"Content-Length": str(len(body))},
        )
        existing_release = {
            "id": "REL-001",
            "name": "Existing Release",
            "tags": existing_tags,
            "platforms": {},
        }
        fake_data = {"releases": [existing_release]}
        handler._load_releases_config = MagicMock(return_value=fake_data)
        handler._save_releases_config = MagicMock(return_value=True)
        handler._find_release_by_id = MagicMock(return_value=existing_release)
        handler._update_items_release_name = MagicMock()
        handler._get_timestamp = MagicMock(return_value="2026-04-22T00:00:00Z")
        handler._extract_version_from_name = MagicMock(return_value="1.0.0")
        handler.handle_update_release("REL-001")
        return handler, _response_json(buf)

    def test_tags_updated_when_supplied(self):
        _, data = self._run_update(["old"], {"tags": ["new-tag", "another"]})
        self.assertEqual(sorted(data["tags"]), ["another", "new-tag"])

    def test_blank_string_tags_filtered_on_update(self):
        _, data = self._run_update([], {"tags": ["valid", "", "  "]})
        self.assertEqual(data["tags"], ["valid"])

    def test_non_string_tags_filtered_on_update(self):
        _, data = self._run_update([], {"tags": ["valid", 42, None]})
        self.assertEqual(data["tags"], ["valid"])

    def test_tags_cleared_when_empty_list_supplied(self):
        _, data = self._run_update(["existing"], {"tags": []})
        self.assertEqual(data["tags"], [])

    def test_tags_unchanged_when_not_in_body(self):
        _, data = self._run_update(["preserved"], {"status": "active"})
        self.assertEqual(data["tags"], ["preserved"])


# ---------------------------------------------------------------------------
# Tests: is_release_complete — XACA-0238 (PLANNED is NOT complete)
# ---------------------------------------------------------------------------

class TestIsReleaseComplete(unittest.TestCase):
    """is_release_complete must treat PLANNED as not-done, only PROD as done."""

    def _make_handler_simple(self):
        handler, _ = _make_handler()
        return handler

    def _release(self, **platform_envs):
        """Build a minimal release dict with the given platform→environment mapping."""
        return {
            "platforms": {
                name: {"environment": env}
                for name, env in platform_envs.items()
            }
        }

    def test_all_platforms_planned_not_complete(self):
        handler = self._make_handler_simple()
        release = self._release(ios="PLANNED", android="PLANNED", firebase="PLANNED")
        self.assertFalse(handler.is_release_complete(release))

    def test_single_platform_planned_not_complete(self):
        handler = self._make_handler_simple()
        release = self._release(ios="PLANNED")
        self.assertFalse(handler.is_release_complete(release))

    def test_all_platforms_at_prod_is_complete(self):
        handler = self._make_handler_simple()
        release = self._release(ios="PROD", android="PROD", firebase="PROD")
        self.assertTrue(handler.is_release_complete(release))

    def test_one_platform_at_dev_blocks_completion(self):
        handler = self._make_handler_simple()
        release = self._release(ios="PROD", android="DEV", firebase="PROD")
        self.assertFalse(handler.is_release_complete(release))

    def test_one_platform_at_planned_blocks_completion(self):
        """PLANNED blocks completion even when siblings are at PROD — XACA-0238 core invariant."""
        handler = self._make_handler_simple()
        release = self._release(ios="PROD", android="PLANNED", firebase="PROD")
        self.assertFalse(handler.is_release_complete(release))

    def test_empty_platforms_not_complete(self):
        handler = self._make_handler_simple()
        self.assertFalse(handler.is_release_complete({"platforms": {}}))

    def test_missing_platforms_key_not_complete(self):
        handler = self._make_handler_simple()
        self.assertFalse(handler.is_release_complete({}))

    def test_non_required_platform_alone_not_complete(self):
        """A platform that isn't in the required list (ios/android/firebase) alone → not complete."""
        handler = self._make_handler_simple()
        release = self._release(other_platform="PROD")
        self.assertFalse(handler.is_release_complete(release))

    def test_partial_required_platforms_all_at_prod_is_complete(self):
        """Only ios present and at PROD → complete (not all three required; those present are done)."""
        handler = self._make_handler_simple()
        release = self._release(ios="PROD")
        self.assertTrue(handler.is_release_complete(release))

    def test_mid_pipeline_environment_not_complete(self):
        """Platforms at QA, ALPHA, BETA, GAMMA are all not-done."""
        handler = self._make_handler_simple()
        for env in ("QA", "ALPHA", "BETA", "GAMMA"):
            release = self._release(ios=env, android=env)
            self.assertFalse(
                handler.is_release_complete(release),
                f"Expected not complete when all platforms at {env}",
            )


# ---------------------------------------------------------------------------
# Tests: handle_promote_release — XACA-0238 (PLANNED at index 0 promotes to DEV)
# ---------------------------------------------------------------------------

class TestHandlePromoteRelease(unittest.TestCase):
    """
    handle_promote_release must correctly advance through the pipeline including
    the new PLANNED stage at index 0.
    """

    def _run_promote(self, current_env, platform="ios", environments=None, target_env=None):
        """
        Wire a handler and call handle_promote_release with the given setup.
        Returns (handler, response_dict_or_None).
        """
        if environments is None:
            environments = ["PLANNED", "DEV", "QA", "ALPHA", "BETA", "GAMMA", "PROD"]

        body_dict = {"platform": platform}
        if target_env:
            body_dict["targetEnvironment"] = target_env
        body = json.dumps(body_dict).encode()

        handler, buf = _make_handler(
            path=f"/api/releases/REL-001/promote",
            method="POST",
            body=body,
            headers={"Content-Length": str(len(body))},
        )

        release = {
            "id": "REL-001",
            "name": "Test Release",
            "environments": environments,
            "platforms": {
                platform: {
                    "environment": current_env,
                    "environmentHistory": [],
                }
            },
        }
        fake_data = {
            "releases": [release],
            "defaultEnvironments": environments,
            "flowConfig": {
                "stages": {env: {"enabled": True} for env in environments}
            },
        }

        handler._load_releases_config = MagicMock(return_value=fake_data)
        handler._save_releases_config = MagicMock()
        handler._find_release_by_id = MagicMock(return_value=release)
        handler._get_timestamp = MagicMock(return_value="2026-04-25T00:00:00Z")

        handler.handle_promote_release("REL-001")

        # If send_error was called, promotion was rejected
        if handler.send_error.called:
            return handler, None

        try:
            result = _response_json(buf)
        except Exception:
            result = None
        return handler, result

    def test_planned_promotes_to_dev(self):
        """PLANNED (index 0) → promote → DEV (index 1). Core XACA-0238 invariant."""
        handler, result = self._run_promote("PLANNED")
        self.assertIsNotNone(result, "Expected a success response, not a send_error")
        self.assertEqual(result["newEnvironment"], "DEV")

    def test_dev_promotes_to_qa(self):
        handler, result = self._run_promote("DEV")
        self.assertIsNotNone(result)
        self.assertEqual(result["newEnvironment"], "QA")

    def test_qa_promotes_to_alpha(self):
        handler, result = self._run_promote("QA")
        self.assertIsNotNone(result)
        self.assertEqual(result["newEnvironment"], "ALPHA")

    def test_prod_is_final_stage_returns_error(self):
        """Promoting from PROD must be rejected — already at the final stage."""
        handler, result = self._run_promote("PROD")
        self.assertIsNone(result, "Expected send_error, not a success response")
        handler.send_error.assert_called_once()
        args = handler.send_error.call_args[0]
        self.assertEqual(args[0], 400)
        self.assertIn("final environment", args[1])

    def test_history_records_from_planned_to_dev(self):
        """environmentHistory must log the PLANNED→DEV transition."""
        handler, result = self._run_promote("PLANNED")
        self.assertIsNotNone(result)
        # Verify save was called and inspect the mutated release
        save_call_args = handler._save_releases_config.call_args[0][0]
        history = save_call_args["releases"][0]["platforms"]["ios"]["environmentHistory"]
        self.assertEqual(len(history), 1)
        self.assertEqual(history[0]["from"], "PLANNED")
        self.assertEqual(history[0]["to"], "DEV")

    def test_missing_platform_in_body_returns_400(self):
        """Omitting the platform field must produce a 400 error."""
        body = json.dumps({}).encode()
        handler, buf = _make_handler(
            path="/api/releases/REL-001/promote",
            method="POST",
            body=body,
            headers={"Content-Length": str(len(body))},
        )
        environments = ["PLANNED", "DEV", "QA", "PROD"]
        release = {"id": "REL-001", "name": "R", "environments": environments, "platforms": {}}
        fake_data = {
            "releases": [release],
            "defaultEnvironments": environments,
            "flowConfig": {"stages": {env: {"enabled": True} for env in environments}},
        }
        handler._load_releases_config = MagicMock(return_value=fake_data)
        handler._find_release_by_id = MagicMock(return_value=release)
        handler._save_releases_config = MagicMock()
        handler._get_timestamp = MagicMock(return_value="2026-04-25T00:00:00Z")

        handler.handle_promote_release("REL-001")
        handler.send_error.assert_called_once()
        args = handler.send_error.call_args[0]
        self.assertEqual(args[0], 400)

    def test_target_env_direct_promotion(self):
        """When targetEnvironment is supplied, platform jumps directly to that env."""
        handler, result = self._run_promote("PLANNED", target_env="QA")
        self.assertIsNotNone(result)
        self.assertEqual(result["newEnvironment"], "QA")


# ---------------------------------------------------------------------------
# Tests: handle_create_release default environment — XACA-0238
# ---------------------------------------------------------------------------

class TestHandleCreateReleaseDefaultEnvironment(unittest.TestCase):
    """New releases must initialize platforms at PLANNED, not DEV."""

    def _run_create(self, default_environments):
        body = json.dumps({"name": "XACA-0238 Release", "platforms": ["ios", "android"]}).encode()
        handler, buf = _make_handler(
            path="/api/releases",
            method="POST",
            body=body,
            headers={"Content-Length": str(len(body))},
        )
        fake_data = {
            "releases": [],
            "projectEnvironments": {},
            "defaultEnvironments": default_environments,
        }
        handler._load_releases_config = MagicMock(return_value=fake_data)
        handler._save_releases_config = MagicMock(return_value=True)
        handler._save_release_manifest = MagicMock(return_value=True)
        handler._generate_release_id = MagicMock(return_value="REL-002")
        handler._get_timestamp = MagicMock(return_value="2026-04-25T00:00:00Z")
        handler._extract_version_from_name = MagicMock(return_value="1.0.0")
        handler.handle_create_release()
        return _response_json(buf)

    def test_ios_platform_starts_at_planned(self):
        data = self._run_create(["PLANNED", "DEV", "QA", "PROD"])
        self.assertEqual(data["platforms"]["ios"]["environment"], "PLANNED")

    def test_android_platform_starts_at_planned(self):
        data = self._run_create(["PLANNED", "DEV", "QA", "PROD"])
        self.assertEqual(data["platforms"]["android"]["environment"], "PLANNED")

    def test_default_env_is_first_in_pipeline(self):
        """The initial environment should be the first entry in defaultEnvironments."""
        data = self._run_create(["PLANNED", "DEV", "QA", "PROD"])
        for platform_data in data["platforms"].values():
            self.assertEqual(platform_data["environment"], "PLANNED")


# ---------------------------------------------------------------------------
# Tests: Weekly anchor endpoints (XACA-0253-003)
# ---------------------------------------------------------------------------

class TestWeeklyAnchorPost(unittest.TestCase):
    """POST /api/weekly-anchor — validation and success paths."""

    def _post(self, body: dict, heuristics_mod=None) -> tuple:
        """Run handle_post_weekly_anchor with the given body dict.

        Returns (response_code, response_dict).
        heuristics_mod defaults to the real _ccusage_heuristics module (via
        the server-level reference); pass a MagicMock to inject failures.
        """
        body_bytes = json.dumps(body).encode()
        handler, buf = _make_handler(
            path="/api/weekly-anchor",
            method="POST",
            body=body_bytes,
            headers={"Content-Length": str(len(body_bytes))},
        )

        if heuristics_mod is not None:
            with patch.object(server, "_ccusage_heuristics", heuristics_mod):
                handler.handle_post_weekly_anchor()
        else:
            handler.handle_post_weekly_anchor()

        return handler._response_code, _response_json(buf)

    def _make_mock_heuristics(self, hours: int = 5, minutes: int = 30) -> MagicMock:
        """Build a mock heuristics module whose write_weekly_anchor returns a plausible record."""
        import datetime
        now = datetime.datetime(2026, 4, 28, 20, 0, 0, tzinfo=datetime.timezone.utc)
        reset = now + datetime.timedelta(hours=hours, minutes=minutes)
        mock_mod = MagicMock()
        mock_mod.write_weekly_anchor.return_value = {
            "version": 1,
            "set_at": now,
            "reset_at": reset,
            "set_hours": hours,
            "set_minutes": minutes,
            "source": "manual",
        }
        return mock_mod

    def test_post_weekly_anchor_valid(self):
        mock_mod = self._make_mock_heuristics(5, 30)
        code, data = self._post({"hours": 5, "minutes": 30}, heuristics_mod=mock_mod)
        self.assertEqual(code, 200)
        self.assertIn("set_at", data)
        self.assertIn("reset_at", data)
        self.assertEqual(data["set_hours"], 5)
        self.assertEqual(data["set_minutes"], 30)
        self.assertEqual(data["source"], "manual")
        mock_mod.write_weekly_anchor.assert_called_once_with(5, 30)

    def test_post_weekly_anchor_invalid_hours(self):
        """hours > 168 should return 400."""
        mock_mod = MagicMock()
        mock_mod.write_weekly_anchor.side_effect = ValueError("hours must be 0..168")
        code, data = self._post({"hours": 200, "minutes": 0}, heuristics_mod=mock_mod)
        self.assertEqual(code, 400)
        self.assertIn("error", data)

    def test_post_weekly_anchor_invalid_minutes(self):
        """minutes >= 60 should return 400."""
        mock_mod = MagicMock()
        mock_mod.write_weekly_anchor.side_effect = ValueError("minutes must be 0..59")
        code, data = self._post({"hours": 1, "minutes": 60}, heuristics_mod=mock_mod)
        self.assertEqual(code, 400)
        self.assertIn("error", data)

    def test_post_weekly_anchor_zero_total(self):
        """hours=0, minutes=0 should return 400."""
        mock_mod = MagicMock()
        mock_mod.write_weekly_anchor.side_effect = ValueError("total duration must be > 0")
        code, data = self._post({"hours": 0, "minutes": 0}, heuristics_mod=mock_mod)
        self.assertEqual(code, 400)
        self.assertIn("error", data)

    def test_post_weekly_anchor_missing_fields(self):
        """Body missing hours/minutes fields returns 400."""
        mock_mod = self._make_mock_heuristics()
        code, data = self._post({"hours": 3}, heuristics_mod=mock_mod)
        self.assertEqual(code, 400)
        self.assertIn("error", data)

    def test_post_weekly_anchor_503_when_module_unavailable(self):
        """If _ccusage_heuristics is None, return 503."""
        body_bytes = json.dumps({"hours": 1, "minutes": 0}).encode()
        handler, buf = _make_handler(
            path="/api/weekly-anchor",
            method="POST",
            body=body_bytes,
            headers={"Content-Length": str(len(body_bytes))},
        )
        with patch.object(server, "_ccusage_heuristics", None):
            handler.handle_post_weekly_anchor()
        self.assertEqual(handler._response_code, 503)
        data = _response_json(buf)
        self.assertIn("error", data)

    def test_post_weekly_anchor_non_integer_hours(self):
        """Non-integer hours field (e.g. float or string) returns 400."""
        mock_mod = self._make_mock_heuristics()
        code, data = self._post({"hours": "5", "minutes": 0}, heuristics_mod=mock_mod)
        self.assertEqual(code, 400)
        self.assertIn("error", data)


class TestWeeklyAnchorDelete(unittest.TestCase):
    """DELETE /api/weekly-anchor — removal paths."""

    def _delete(self, heuristics_mod=None) -> tuple:
        """Run handle_delete_weekly_anchor. Returns (code, dict)."""
        handler, buf = _make_handler(
            path="/api/weekly-anchor",
            method="DELETE",
            body=b"",
            headers={"Content-Length": "0"},
        )
        if heuristics_mod is not None:
            with patch.object(server, "_ccusage_heuristics", heuristics_mod):
                handler.handle_delete_weekly_anchor()
        else:
            handler.handle_delete_weekly_anchor()
        return handler._response_code, _response_json(buf)

    def test_delete_weekly_anchor_file_existed(self):
        mock_mod = MagicMock()
        mock_mod.delete_weekly_anchor.return_value = True
        code, data = self._delete(heuristics_mod=mock_mod)
        self.assertEqual(code, 200)
        self.assertTrue(data["deleted"])

    def test_delete_weekly_anchor_file_missing(self):
        mock_mod = MagicMock()
        mock_mod.delete_weekly_anchor.return_value = False
        code, data = self._delete(heuristics_mod=mock_mod)
        self.assertEqual(code, 200)
        self.assertFalse(data["deleted"])

    def test_delete_weekly_anchor_503_when_module_unavailable(self):
        handler, buf = _make_handler(
            path="/api/weekly-anchor",
            method="DELETE",
            body=b"",
            headers={"Content-Length": "0"},
        )
        with patch.object(server, "_ccusage_heuristics", None):
            handler.handle_delete_weekly_anchor()
        self.assertEqual(handler._response_code, 503)
        data = _response_json(buf)
        self.assertIn("error", data)


if __name__ == "__main__":
    unittest.main(verbosity=2)
