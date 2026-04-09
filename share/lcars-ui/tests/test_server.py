#!/usr/bin/env python3
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
    format_bytes_archive,
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


if __name__ == "__main__":
    unittest.main(verbosity=2)
