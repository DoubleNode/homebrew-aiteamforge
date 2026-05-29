#!/usr/bin/env python3

#
#  test_xaca0582_preflight_delta_override.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""XACA-0582 — Backend tests for the ``acknowledgePreflightDeltas`` gate override.

Tests the ``handle_import_apply`` method of ``LCARSHandler`` in-process using
the ``_make_handler`` pattern from ``test_server.py``: all socket I/O is mocked
and ``server.IMPORT_JOBS`` is injected directly so the test controls ``baseMatch``
without requiring a subprocess server or a verifier-failing zip.

Coverage:
  1. baseMatch=False, no override flag  → HTTP 400 with override_flag in body
  2. baseMatch=False + acknowledgePreflightDeltas=true (bool)  → gate bypassed, apply proceeds
  3. Type coercion — string "false"  → must still block (HTTP 400)
  4. Type coercion — string "true"   → gate bypassed (positive coercion)
  5. Type coercion — int 1           → gate bypassed (positive coercion)
  6. baseMatch=True (PASS state)     → apply proceeds without any override flag
"""

from __future__ import annotations

import io
import json
import sys
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest.mock import MagicMock, patch

# ---------------------------------------------------------------------------
# Path wiring — mirrors test_server.py
# ---------------------------------------------------------------------------
LCARS_UI_DIR = Path(__file__).parent.parent
REPO_ROOT = LCARS_UI_DIR.parent
sys.path.insert(0, str(LCARS_UI_DIR))
sys.path.insert(0, str(REPO_ROOT))

# Stub heavy optional imports so server.py loads cleanly
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
from server import IMPORT_JOBS, LCARSHandler  # noqa: E402


# ---------------------------------------------------------------------------
# Handler construction helper (mirrors test_server.py::_make_handler exactly)
# ---------------------------------------------------------------------------

def _make_handler(path="/", method="POST", body=b"", headers=None):
    """Construct an LCARSHandler instance with all socket I/O mocked out.

    Returns (handler, response_buf).  The response_buf is a BytesIO that
    captures everything written via wfile.write / _send_json_response.
    """
    rfile = io.BytesIO(body)
    response_buf = io.BytesIO()

    mock_connection = MagicMock()
    mock_connection.makefile.return_value = rfile

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

    def _end_headers():
        pass

    handler.send_response = _send_response
    handler.send_header = _send_header
    handler.end_headers = _end_headers
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
# Fixtures: pre-built staged job entries
# ---------------------------------------------------------------------------

def _new_job_id():
    return str(uuid.uuid4())


def _staged_job(base_match: bool, job_id: str | None = None) -> tuple[str, dict]:
    """Return (job_id, job_dict) for a staged import job with the given baseMatch."""
    jid = job_id or _new_job_id()
    # Use a real temp dir for stagedPath so apply_import doesn't crash on open()
    # before reaching the secrets gate — but we never let it get that far in
    # the baseMatch=False tests (the gate returns before touching the file).
    job = {
        "status": "staged",
        "progress": 0,
        "message": "Archive staged. Review pre-flight and apply.",
        "manifest": {
            "schema_version": "1",
            "kind": "team_transfer-manifest-v1",
            "secrets_summary": {
                "expected": 0,
                "discovered": 0,
                "paired_status": "none",
                "paired_job_id": None,
            },
            "domains": {},
        },
        "importFormat": "new",
        "stagedPath": "/tmp/synthetic_staged.zip",
        "targetTeam": "academy",
        "targetBase": "academy",
        "baseMatch": base_match,
        "verifierState": "FAIL" if not base_match else "PASS",
        "sourceIdentity": {"hostname": "synthetic-source.local"},
        "totalFileCount": 0,
        "idRenameRequired": False,
        "createdAt": "2026-05-28T00:00:00+00:00",
        "verifierSummary": {
            "present": True,
            "overall": "FAIL" if not base_match else "PASS",
            "pass": 0,
            "warn": 0,
            "fail": 1 if not base_match else 0,
            "phase": "preflight",
        },
    }
    IMPORT_JOBS[jid] = job
    return jid, job


def _make_apply_handler(job_id: str, body_dict: dict) -> tuple:
    """Build a handler targeting /api/import/apply/<job_id> with JSON body."""
    body_bytes = json.dumps(body_dict).encode("utf-8")
    headers = {
        "Content-Type": "application/json",
        "Content-Length": str(len(body_bytes)),
    }
    return _make_handler(
        path=f"/api/import/apply/{job_id}",
        method="POST",
        body=body_bytes,
        headers=headers,
    )


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

class TestAcknowledgePreflightDeltasGate(unittest.TestCase):
    """Tests for the acknowledgePreflightDeltas operator override in handle_import_apply."""

    def setUp(self):
        # Ensure a clean IMPORT_JOBS slate for each test (module-global dict).
        IMPORT_JOBS.clear()

    def tearDown(self):
        IMPORT_JOBS.clear()

    # ------------------------------------------------------------------
    # Test 1: baseMatch=False, no flag → HTTP 400 with override_flag
    # ------------------------------------------------------------------

    def test_base_match_false_no_flag_returns_400_with_override_flag(self):
        """baseMatch=False and no acknowledgePreflightDeltas → HTTP 400.

        The response body must include override_flag='acknowledgePreflightDeltas'
        and apply must NOT proceed (job status stays 'staged').
        """
        job_id, job = _staged_job(base_match=False)
        handler, buf = _make_apply_handler(job_id, {})

        handler.handle_import_apply(job_id)

        # Assert HTTP 400
        self.assertEqual(handler._response_code, 400,
                         "Expected HTTP 400 when baseMatch=False and no override flag")

        # Assert response body contains override_flag
        resp = _response_json(buf)
        self.assertEqual(
            resp.get("override_flag"), "acknowledgePreflightDeltas",
            f"Response body must carry override_flag='acknowledgePreflightDeltas'; got: {resp}"
        )
        self.assertIn("error", resp, "Response body must include 'error' key")

        # Assert apply did NOT proceed: job status must remain 'staged'
        self.assertEqual(
            IMPORT_JOBS[job_id]["status"], "staged",
            "Job status must remain 'staged' when the baseMatch gate fires"
        )

    # ------------------------------------------------------------------
    # Test 2: baseMatch=False + acknowledgePreflightDeltas=True → proceeds
    # ------------------------------------------------------------------

    def test_base_match_false_with_bool_true_flag_proceeds(self):
        """baseMatch=False + acknowledgePreflightDeltas=True (bool) → gate bypassed.

        The gate must NOT return 400; apply must proceed (job transitions away
        from 'staged' — either to 'applying' or the apply_import worker starts).
        """
        job_id, job = _staged_job(base_match=False)
        handler, buf = _make_apply_handler(job_id, {"acknowledgePreflightDeltas": True})

        # Stub apply_import to avoid real filesystem work; we only care that the
        # gate itself lets through, not the full extract path.
        with patch.object(server, "apply_import", MagicMock()):
            handler.handle_import_apply(job_id)

        # Must NOT return 400 (gate must not fire)
        self.assertNotEqual(
            handler._response_code, 400,
            "acknowledgePreflightDeltas=True (bool) must bypass the baseMatch gate"
        )
        # Must not be a 409 secrets gate either (discovered=0 in our fixture)
        self.assertNotEqual(
            handler._response_code, 409,
            "Unexpected 409 — secrets gate should not fire when discovered=0"
        )

    # ------------------------------------------------------------------
    # Test 3: Type coercion — string "false" → still blocks (HTTP 400)
    # ------------------------------------------------------------------

    def test_type_coercion_string_false_still_blocks(self):
        """acknowledgePreflightDeltas='false' (string) → must still return HTTP 400.

        Python's bool('false') is True — a naïve cast would silently bypass the
        gate.  The implementation must reject the string 'false'.
        """
        job_id, job = _staged_job(base_match=False)
        handler, buf = _make_apply_handler(job_id, {"acknowledgePreflightDeltas": "false"})

        handler.handle_import_apply(job_id)

        self.assertEqual(
            handler._response_code, 400,
            "acknowledgePreflightDeltas='false' (string) must NOT bypass the gate"
        )
        resp = _response_json(buf)
        self.assertEqual(
            resp.get("override_flag"), "acknowledgePreflightDeltas",
            f"Response must still carry override_flag; got: {resp}"
        )

    # ------------------------------------------------------------------
    # Test 4: Type coercion — string "true" → gate bypassed
    # ------------------------------------------------------------------

    def test_type_coercion_string_true_proceeds(self):
        """acknowledgePreflightDeltas='true' (string, case-insensitive) → gate bypassed."""
        job_id, job = _staged_job(base_match=False)
        handler, buf = _make_apply_handler(job_id, {"acknowledgePreflightDeltas": "true"})

        with patch.object(server, "apply_import", MagicMock()):
            handler.handle_import_apply(job_id)

        self.assertNotEqual(
            handler._response_code, 400,
            "acknowledgePreflightDeltas='true' (string) must bypass the gate"
        )

    # ------------------------------------------------------------------
    # Test 5: Type coercion — int 1 → gate bypassed
    # ------------------------------------------------------------------

    def test_type_coercion_int_1_proceeds(self):
        """acknowledgePreflightDeltas=1 (int) → gate bypassed."""
        job_id, job = _staged_job(base_match=False)
        handler, buf = _make_apply_handler(job_id, {"acknowledgePreflightDeltas": 1})

        with patch.object(server, "apply_import", MagicMock()):
            handler.handle_import_apply(job_id)

        self.assertNotEqual(
            handler._response_code, 400,
            "acknowledgePreflightDeltas=1 (int) must bypass the gate"
        )

    # ------------------------------------------------------------------
    # Test 6: baseMatch=True (PASS state) → apply proceeds without any flag
    # ------------------------------------------------------------------

    def test_base_match_true_proceeds_without_override(self):
        """baseMatch=True (verifierState=PASS) → apply proceeds normally without flag.

        This validates the happy path: a clean preflight does not require the
        operator override and must not trigger the 400 gate.
        """
        job_id, job = _staged_job(base_match=True)
        handler, buf = _make_apply_handler(job_id, {})

        with patch.object(server, "apply_import", MagicMock()):
            handler.handle_import_apply(job_id)

        self.assertNotEqual(
            handler._response_code, 400,
            "baseMatch=True must NOT trigger the preflight-delta gate"
        )


if __name__ == "__main__":
    unittest.main()
