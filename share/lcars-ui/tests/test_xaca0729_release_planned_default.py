#!/usr/bin/env python3

#
#  test_xaca0729_release_planned_default.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""
XACA-0729 — Release lifecycle: default new releases to PLANNED + add kb-release plan shortcut

Covers:
  A. handle_create_release defaultEnvironments derivation (three variants)
       A1: defaultEnvironments leads with PLANNED → platforms seeded at PLANNED  (happy path)
       A2: PLANNED present but NOT first (drifted board) → platforms STILL seeded at PLANNED
           (the core regression XACA-0729 fixes)
       A3: No PLANNED in list at all → fall back to environments[0]; don't break these boards
       A4: Empty environments list → fall back to "PLANNED" sentinel string
  B. handle_plan_release endpoint
       B1: Create a release, promote one platform to DEV, POST /plan → all platforms at PLANNED,
           environmentHistory appended, status == "in_progress"
       B2: Missing release → 404
       B3: Multi-platform release → all platforms reset
       B4: History entry schema matches environmentHistory convention
  C. Route dispatch: do_POST correctly extracts the release_id for /plan paths
  D. kb-release dispatcher: `plan` subcommand routes to kb-release-plan (grep/sanity)
     and `--help` documents it

Test strategy:
  - Python unit tests against monkeypatched LCARSHandler instances (no TCP socket)
  - Follows patterns established in test_server.py and test_xaca0659_release_metadata_sync.py

Run with:
    cd lcars-ui && python3 -m pytest tests/test_xaca0729_release_planned_default.py -v
  or from repo root:
    python3 -m unittest discover -s lcars-ui/tests -p 'test_xaca0729*.py'
"""

import io
import json
import os
import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

# ---------------------------------------------------------------------------
# Bootstrap — mirrors the path setup in test_server.py
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

import server  # noqa: E402
from server import LCARSHandler  # noqa: E402


# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

def _make_handler(path="/", method="GET", body=b"", headers=None):
    """Construct an LCARSHandler with all socket I/O mocked (mirrors test_server.py pattern)."""
    rfile = io.BytesIO(body)
    response_buf = io.BytesIO()

    with patch.object(LCARSHandler, "__init__", lambda self, *a, **kw: None):
        handler = LCARSHandler.__new__(LCARSHandler)

    handler.path = path
    handler.command = method
    handler.rfile = rfile
    handler.wfile = response_buf
    handler.server = MagicMock()
    handler.headers = headers or {}
    handler.requestline = f"{method} {path} HTTP/1.1"
    handler.client_address = ("127.0.0.1", 9999)
    handler._headers_buffer = []
    handler._response_code = None

    def _send_response(code, message=None):
        handler._response_code = code

    def _send_header(name, value):
        handler._headers_buffer.append((name, value))

    handler.send_response = _send_response
    handler.send_header = _send_header
    handler.end_headers = MagicMock()
    handler.send_error = MagicMock()
    handler.log_message = MagicMock()
    handler.log_error = MagicMock()

    return handler, response_buf


def _response_json(buf):
    buf.seek(0)
    return json.loads(buf.read())


def _run_create(default_environments, platforms=None):
    """
    Call handle_create_release with the given defaultEnvironments and optional platform list.
    Returns the decoded response dict.
    """
    if platforms is None:
        platforms = ["ios", "android"]
    body = json.dumps({"name": "XACA-0729 Release", "platforms": platforms}).encode()
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
    handler._generate_release_id = MagicMock(return_value="REL-0729-001")
    handler._get_timestamp = MagicMock(return_value="2026-06-16T00:00:00Z")
    handler._extract_version_from_name = MagicMock(return_value="1.0.0")
    handler.handle_create_release()
    return _response_json(buf)


# ---------------------------------------------------------------------------
# Section A — handle_create_release initial environment derivation (XACA-0729)
# ---------------------------------------------------------------------------

class TestHandleCreateReleasePlannedDerivation(unittest.TestCase):
    """
    handle_create_release must seed platforms at PLANNED whenever the board's
    defaultEnvironments contains PLANNED — regardless of its position in the list.
    """

    # A1 — happy path: PLANNED is already the first entry
    def test_a1_planned_leads_list_ios_seeded_at_planned(self):
        """PLANNED at index-0: ios platform must be born in PLANNED."""
        data = _run_create(["PLANNED", "DEV", "QA", "PROD"])
        self.assertEqual(data["platforms"]["ios"]["environment"], "PLANNED")

    def test_a1_planned_leads_list_android_seeded_at_planned(self):
        """PLANNED at index-0: android platform must be born in PLANNED."""
        data = _run_create(["PLANNED", "DEV", "QA", "PROD"])
        self.assertEqual(data["platforms"]["android"]["environment"], "PLANNED")

    def test_a1_full_pipeline_all_platforms_seeded_at_planned(self):
        """Standard 7-stage pipeline seeded from DEFAULT_RELEASE_CONFIG: all platforms at PLANNED."""
        data = _run_create(
            ["PLANNED", "DEV", "QA", "ALPHA", "BETA", "GAMMA", "PROD"],
            platforms=["ios", "android", "firebase"],
        )
        for platform, pdata in data["platforms"].items():
            self.assertEqual(
                pdata["environment"],
                "PLANNED",
                f"Expected PLANNED for {platform!r}, got {pdata['environment']!r}",
            )

    # A2 — regression case: drifted board where PLANNED is NOT the first entry
    def test_a2_planned_not_first_ios_still_seeded_at_planned(self):
        """
        Core XACA-0729 regression: board whose defaultEnvironments drifted to
        ["DEV", "QA", "PLANNED", "PROD"] previously caused platforms to be born
        in DEV.  The fix: PLANNED anywhere in the list forces initial_environment
        to PLANNED.
        """
        data = _run_create(["DEV", "QA", "PLANNED", "PROD"])
        self.assertEqual(
            data["platforms"]["ios"]["environment"],
            "PLANNED",
            "Platform born in DEV when PLANNED was not first — regression A2 not fixed",
        )

    def test_a2_planned_last_android_still_seeded_at_planned(self):
        """PLANNED is the LAST entry: platforms must still start at PLANNED."""
        data = _run_create(["DEV", "QA", "PROD", "PLANNED"])
        self.assertEqual(data["platforms"]["android"]["environment"], "PLANNED")

    def test_a2_planned_middle_multi_platform_all_at_planned(self):
        """PLANNED buried in the middle: every platform born in PLANNED."""
        envs = ["DEV", "PLANNED", "QA", "PROD"]
        data = _run_create(envs, platforms=["ios", "android", "firebase"])
        for platform, pdata in data["platforms"].items():
            self.assertEqual(
                pdata["environment"],
                "PLANNED",
                f"Platform {platform!r} not at PLANNED with drifted env list {envs!r}",
            )

    # A3 — intentional no-PLANNED board: fall back to environments[0]
    def test_a3_no_planned_falls_back_to_first_env(self):
        """
        Board that intentionally omits PLANNED (e.g. legacy DEV-first pipeline)
        should NOT be broken: fall back to environments[0].
        """
        data = _run_create(["DEV", "QA", "PROD"])
        # Must be DEV (first entry), NOT PLANNED
        self.assertEqual(
            data["platforms"]["ios"]["environment"],
            "DEV",
            "Legacy no-PLANNED board should seed platforms at environments[0]='DEV'",
        )

    def test_a3_no_planned_custom_first_env_used(self):
        """A custom pipeline starting with STAGING (no PLANNED): seed at STAGING."""
        data = _run_create(["STAGING", "PROD"])
        self.assertEqual(data["platforms"]["ios"]["environment"], "STAGING")

    # A4 — empty environments list
    def test_a4_empty_environments_falls_back_to_planned_string(self):
        """
        When environments is empty (edge case: board has no configured stages),
        the code falls back to the literal string 'PLANNED' as a safe sentinel.
        """
        data = _run_create([])
        self.assertEqual(
            data["platforms"]["ios"]["environment"],
            "PLANNED",
            "Empty environments should fall back to sentinel 'PLANNED'",
        )


# ---------------------------------------------------------------------------
# Section B — handle_plan_release endpoint (XACA-0729)
# ---------------------------------------------------------------------------

class TestHandlePlanRelease(unittest.TestCase):
    """
    POST /api/releases/<id>/plan must demote all platforms back to PLANNED,
    append an environmentHistory entry per platform, and set status=in_progress.
    """

    _ENVIRONMENTS = ["PLANNED", "DEV", "QA", "PROD"]
    _TS = "2026-06-16T12:00:00Z"

    def _run_plan(self, release_dict, fake_data=None):
        """
        Call handle_plan_release with the given release dict.

        Returns (handler, response_dict_or_None).
        response is None when send_error was called instead of a 200 body.
        """
        release_id = release_dict.get("id", "REL-0729-001")
        handler, buf = _make_handler(
            path=f"/api/releases/{release_id}/plan",
            method="POST",
            body=b"{}",
            headers={"Content-Length": "2"},
        )

        if fake_data is None:
            fake_data = {
                "releases": [release_dict],
                "defaultEnvironments": self._ENVIRONMENTS,
            }

        handler._load_releases_config = MagicMock(return_value=fake_data)
        handler._save_releases_config = MagicMock()
        handler._find_release_by_id = MagicMock(return_value=release_dict)
        handler._get_timestamp = MagicMock(return_value=self._TS)
        # Suppress manifest sync (same pattern as TestHandlePromoteRelease)
        handler._sync_release_metadata_to_manifest = MagicMock()

        handler.handle_plan_release(release_id)

        if handler.send_error.called:
            return handler, None

        try:
            result = _response_json(buf)
        except Exception:
            result = None
        return handler, result

    def _make_release(self, release_id="REL-0729-001", platforms=None):
        """Build a minimal release dict with optional platform mapping."""
        if platforms is None:
            platforms = {
                "ios": {"environment": "DEV", "environmentHistory": []},
            }
        return {
            "id": release_id,
            "name": "XACA-0729 Test Release",
            "status": "in_progress",
            "environments": self._ENVIRONMENTS,
            "platforms": platforms,
        }

    # B1 — core round-trip: create at DEV, plan it back to PLANNED
    def test_b1_single_platform_reset_to_planned(self):
        """Platform at DEV after promote: POST /plan must return it to PLANNED."""
        release = self._make_release(platforms={
            "ios": {"environment": "DEV", "environmentHistory": [
                {"from": "PLANNED", "to": "DEV", "promotedAt": "2026-06-15T00:00:00Z"}
            ]},
        })
        handler, result = self._run_plan(release)
        self.assertIsNotNone(result, "Expected 200 response, got send_error")
        self.assertEqual(result["resetEnvironment"], "PLANNED")

    def test_b1_platform_environment_in_saved_data_is_planned(self):
        """The release dict passed to _save_releases_config must have ios environment=PLANNED."""
        release = self._make_release(platforms={
            "ios": {"environment": "QA", "environmentHistory": []},
        })
        handler, result = self._run_plan(release)
        self.assertIsNotNone(result)

        # Inspect what was persisted
        saved = handler._save_releases_config.call_args[0][0]
        saved_release = saved["releases"][0]
        self.assertEqual(saved_release["platforms"]["ios"]["environment"], "PLANNED")

    def test_b1_status_reset_to_in_progress(self):
        """handle_plan_release must set release status='in_progress'."""
        release = self._make_release(platforms={
            "ios": {"environment": "BETA", "environmentHistory": []},
        })
        release["status"] = "active"
        handler, result = self._run_plan(release)
        self.assertIsNotNone(result)

        saved = handler._save_releases_config.call_args[0][0]
        saved_release = saved["releases"][0]
        self.assertEqual(saved_release["status"], "in_progress")

    # B2 — missing release → 404
    def test_b2_missing_release_returns_404(self):
        """Release not found: handle_plan_release must call send_error with 404."""
        handler, buf = _make_handler(
            path="/api/releases/REL-NONEXISTENT/plan",
            method="POST",
            body=b"{}",
            headers={"Content-Length": "2"},
        )
        fake_data = {"releases": [], "defaultEnvironments": self._ENVIRONMENTS}
        handler._load_releases_config = MagicMock(return_value=fake_data)
        handler._find_release_by_id = MagicMock(return_value=None)
        handler._save_releases_config = MagicMock()
        handler._get_timestamp = MagicMock(return_value=self._TS)
        handler._sync_release_metadata_to_manifest = MagicMock()

        handler.handle_plan_release("REL-NONEXISTENT")

        handler.send_error.assert_called_once()
        code = handler.send_error.call_args[0][0]
        self.assertEqual(code, 404)

    # B3 — multi-platform release: all platforms reset
    def test_b3_multi_platform_all_reset_to_planned(self):
        """With ios, android, firebase each at different envs: all must land at PLANNED."""
        release = self._make_release(platforms={
            "ios":      {"environment": "BETA",  "environmentHistory": []},
            "android":  {"environment": "QA",    "environmentHistory": []},
            "firebase": {"environment": "GAMMA", "environmentHistory": []},
        })
        handler, result = self._run_plan(release)
        self.assertIsNotNone(result)

        saved = handler._save_releases_config.call_args[0][0]
        saved_platforms = saved["releases"][0]["platforms"]
        for platform, pdata in saved_platforms.items():
            self.assertEqual(
                pdata["environment"],
                "PLANNED",
                f"Platform {platform!r} was not reset to PLANNED",
            )

    def test_b3_response_platforms_list_contains_all_platforms(self):
        """Response JSON 'platforms' key must list every platform that was reset."""
        release = self._make_release(platforms={
            "ios":      {"environment": "DEV", "environmentHistory": []},
            "android":  {"environment": "DEV", "environmentHistory": []},
            "firebase": {"environment": "DEV", "environmentHistory": []},
        })
        handler, result = self._run_plan(release)
        self.assertIsNotNone(result)
        self.assertCountEqual(result["platforms"], ["ios", "android", "firebase"])

    # B4 — environmentHistory entry schema
    def test_b4_history_entry_appended_with_correct_from_to(self):
        """
        Each platform must get a new environmentHistory entry with from=<current_env>,
        to='PLANNED', promotedAt=<timestamp>.  Schema matches handle_promote_release convention.
        """
        release = self._make_release(platforms={
            "ios": {"environment": "DEV", "environmentHistory": []},
        })
        handler, result = self._run_plan(release)
        self.assertIsNotNone(result)

        saved = handler._save_releases_config.call_args[0][0]
        history = saved["releases"][0]["platforms"]["ios"]["environmentHistory"]
        self.assertEqual(len(history), 1, "Expected exactly one history entry")
        entry = history[0]
        self.assertEqual(entry["from"], "DEV")
        self.assertEqual(entry["to"], "PLANNED")
        self.assertIn("promotedAt", entry)
        self.assertEqual(entry["promotedAt"], self._TS)

    def test_b4_history_appends_not_replaces_existing_entries(self):
        """
        A release that already has promotion history must APPEND the plan-reset
        entry — not overwrite the existing history.
        """
        prior_history = [
            {"from": "PLANNED", "to": "DEV", "promotedAt": "2026-06-10T00:00:00Z"},
            {"from": "DEV",     "to": "QA",  "promotedAt": "2026-06-12T00:00:00Z"},
        ]
        release = self._make_release(platforms={
            "ios": {"environment": "QA", "environmentHistory": list(prior_history)},
        })
        handler, result = self._run_plan(release)
        self.assertIsNotNone(result)

        saved = handler._save_releases_config.call_args[0][0]
        history = saved["releases"][0]["platforms"]["ios"]["environmentHistory"]
        # 2 prior + 1 new plan entry
        self.assertEqual(len(history), 3, "Expected 3 history entries (2 prior + plan-reset)")
        self.assertEqual(history[2]["from"], "QA")
        self.assertEqual(history[2]["to"], "PLANNED")

    def test_b4_platform_already_at_planned_still_gets_history_entry(self):
        """
        Calling plan on a release already at PLANNED must still append a history entry
        (from=PLANNED, to=PLANNED) — same audit convention as promote (no special-casing).
        """
        release = self._make_release(platforms={
            "ios": {"environment": "PLANNED", "environmentHistory": []},
        })
        handler, result = self._run_plan(release)
        self.assertIsNotNone(result)

        saved = handler._save_releases_config.call_args[0][0]
        history = saved["releases"][0]["platforms"]["ios"]["environmentHistory"]
        self.assertEqual(len(history), 1)
        self.assertEqual(history[0]["from"], "PLANNED")
        self.assertEqual(history[0]["to"], "PLANNED")

    def test_b4_release_id_in_response(self):
        """Response must include the releaseId that was reset."""
        release = self._make_release(release_id="REL-TEST-007", platforms={
            "ios": {"environment": "DEV", "environmentHistory": []},
        })
        handler, result = self._run_plan(release)
        self.assertIsNotNone(result)
        self.assertEqual(result["releaseId"], "REL-TEST-007")

    def test_b4_response_success_flag_true(self):
        """Response JSON must include success=true."""
        release = self._make_release(platforms={
            "ios": {"environment": "DEV", "environmentHistory": []},
        })
        handler, result = self._run_plan(release)
        self.assertIsNotNone(result)
        self.assertTrue(result.get("success"), "Response must include success=true")


# ---------------------------------------------------------------------------
# Section C — do_POST route dispatch for /plan endpoint
# ---------------------------------------------------------------------------

class TestDoPOSTRouteDispatchForPlan(unittest.TestCase):
    """
    do_POST must extract the release_id correctly from paths of the form
    /api/releases/<id>/plan and dispatch to handle_plan_release.
    """

    def _dispatch(self, path, release_id_for_handler="REL-ROUTE-001"):
        """
        Call do_POST for the given path, with handle_plan_release monkeypatched
        so we can assert it was called with the right release_id.
        """
        handler, buf = _make_handler(
            path=path,
            method="POST",
            body=b"{}",
            headers={"Content-Length": "2"},
        )
        # Monkeypatch handle_plan_release to capture what it was called with
        handler.handle_plan_release = MagicMock()

        # We need to prevent other branches from throwing; monkeypatch common methods
        # that get called by non-plan branches.
        handler.handle_create_release = MagicMock()
        handler.handle_promote_release = MagicMock()
        handler.handle_platform_gate_status = MagicMock()
        handler.handle_link_cr_to_release = MagicMock()

        # XACA-0952-002: _auth_gate() (XACA-0395) is the mandatory first
        # statement of do_POST and 401s before route dispatch whenever the
        # machine running the suite has a real resolvable API key (e.g.
        # ~/.aiteamforge/api-key) — this test predates that gate (PR #642
        # predates PR #748) and carries no credential. This class exists to
        # test route-dispatch/id-extraction, not auth, so bypass the gate
        # rather than depend on the machine's auth posture being "open".
        handler._auth_gate = lambda: True

        handler.do_POST()
        return handler

    def test_c1_plan_route_dispatches_to_handle_plan_release(self):
        """/api/releases/REL-001/plan must dispatch to handle_plan_release('REL-001')."""
        handler = self._dispatch("/api/releases/REL-001/plan")
        handler.handle_plan_release.assert_called_once_with("REL-001")

    def test_c2_promote_route_not_confused_with_plan(self):
        """/api/releases/REL-001/promote must NOT call handle_plan_release."""
        handler = self._dispatch("/api/releases/REL-001/promote")
        handler.handle_plan_release.assert_not_called()

    def test_c3_plan_route_extracts_id_with_hyphens(self):
        """Release IDs with multiple hyphens must be extracted correctly."""
        handler = self._dispatch("/api/releases/REL-2026-Q1-007/plan")
        handler.handle_plan_release.assert_called_once_with("REL-2026-Q1-007")


# ---------------------------------------------------------------------------
# Section D — kb-release dispatcher sanity checks (grep-based, no live server)
# ---------------------------------------------------------------------------

class TestKbReleasePlanDispatcher(unittest.TestCase):
    """
    Verify that the kb-release dispatcher and kb-release-plan helper are
    present in kanban-helpers.sh with the expected structure.

    These are static analysis checks — we do not source the file or spin a
    live server, because the helper requires a running LCARS instance and a
    real team context.
    """

    @classmethod
    def setUpClass(cls):
        cls.helpers_path = REPO_ROOT / "kanban-helpers.sh"
        if not cls.helpers_path.exists():
            raise unittest.SkipTest(
                f"kanban-helpers.sh not found at {cls.helpers_path} — skipping dispatcher checks"
            )
        cls.helpers_text = cls.helpers_path.read_text(encoding="utf-8")

    def test_d1_kb_release_plan_function_is_defined(self):
        """kanban-helpers.sh must define the kb-release-plan() function."""
        self.assertIn(
            "kb-release-plan()",
            self.helpers_text,
            "kb-release-plan() function not found in kanban-helpers.sh",
        )

    def test_d2_dispatcher_routes_plan_to_kb_release_plan(self):
        """The kb-release dispatcher must route 'plan)' to kb-release-plan."""
        # Look for the plan) case and the kb-release-plan call in proximity
        self.assertIn(
            "plan)",
            self.helpers_text,
            "'plan)' case not found in kb-release dispatcher",
        )
        self.assertIn(
            "kb-release-plan",
            self.helpers_text,
            "kb-release-plan invocation not found in kanban-helpers.sh",
        )

    def test_d3_help_text_documents_plan_subcommand(self):
        """kb-release --help output must mention 'plan' with a description."""
        # The help) branch must contain a line documenting the plan subcommand
        self.assertIn(
            "kb-release plan",
            self.helpers_text,
            "'kb-release plan' not documented in the help) branch",
        )
        self.assertIn(
            "PLANNED",
            self.helpers_text,
            "Help text for kb-release plan must mention PLANNED",
        )

    def test_d4_plan_function_hits_api_releases_plan_endpoint(self):
        """kb-release-plan must call the /api/releases/<id>/plan endpoint."""
        self.assertIn(
            "/api/releases/${release_id}/plan",
            self.helpers_text,
            "Expected /api/releases/${release_id}/plan endpoint call in kb-release-plan",
        )

    def test_d5_plan_function_handles_help_flag(self):
        """kb-release-plan must handle --help / -h / empty release_id gracefully."""
        self.assertIn(
            "--help",
            self.helpers_text,
            "kb-release-plan does not appear to handle --help flag",
        )

    def test_d6_plan_function_handles_404_response(self):
        """kb-release-plan must have a case arm for HTTP 404."""
        self.assertIn(
            "404)",
            self.helpers_text,
            "kb-release-plan does not appear to handle 404 response code",
        )


if __name__ == "__main__":
    unittest.main()
