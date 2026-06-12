#!/usr/bin/env python3

#
#  test_secrets_workers.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""
Unit tests for the secrets export/import WORKER functions in server.py:
  - generate_secrets_export()
  - apply_secrets_import()

These tests exercise the workers directly without spinning up the HTTP server.
They use temp dirs and small manifests for isolation.

Run with:
    python3 -m unittest discover -s lcars-ui/tests -p 'test_*.py'
  or directly:
    python3 -m unittest lcars-ui/tests/test_secrets_workers.py
"""

import json
import sys
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest.mock import MagicMock, patch

# ---------------------------------------------------------------------------
# Path wiring — match test_server.py convention
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
import threading
import time

from server import (  # noqa: E402
    SECRETS_EXPORT_JOBS,
    SECRETS_IMPORT_JOBS,
    IMPORT_JOBS,
    EXPORT_JOBS,
    generate_secrets_export,
    apply_secrets_import,
    _prune_old_secrets_jobs,
    _prune_old_export_jobs,
    _import_job_create,
    _import_job_get,
    _import_job_update,
    _import_job_snapshot,
    _import_job_compare_and_set_status,
    _secrets_job_create,
    _secrets_job_update,
    _secrets_job_snapshot,
    _secrets_job_compare_and_set_status,
    _export_job_create,
    _export_job_update,
    _export_job_snapshot,
)
import pyzipper  # noqa: E402  (required dependency — must be present)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_PASSWORD = "test-password-1234"
_WRONG_PW = "absolutely-wrong-password"


def _new_job_id() -> str:
    return str(uuid.uuid4())


def _make_export_job(job_id: str) -> dict:
    job = {
        "status": "running",
        "progress": 0,
        "message": "",
        "filename": None,
        "fileSize": None,
        "error": None,
        "manifestUsed": None,
    }
    SECRETS_EXPORT_JOBS[job_id] = job
    return job


def _make_import_job(job_id: str, staged_path: str, target_team: str = "academy") -> dict:
    job = {
        "status": "running",
        "progress": 0,
        "message": "",
        "stagedPath": staged_path,
        "targetTeam": target_team,
        "manifest": None,
        "fileCount": 0,
        "error": None,
    }
    SECRETS_IMPORT_JOBS[job_id] = job
    return job


def _build_valid_zip(zip_path: Path, password: str, files: dict[str, bytes],
                     team: str = "academy",
                     target_root: str = "secrets/") -> None:
    """Build a valid AES-encrypted zip at zip_path with the given files and manifest.

    files: arc_name → content bytes (arc_names are stored literally in the zip)
    A secrets-manifest.json is automatically appended.
    """
    manifest = {
        "version": "1.0",
        "kind": "lcars-team-secrets",
        "team": team,
        "baseTeam": team,
        "sourceHost": "test-host",
        "exportId": "test-export-id",
        "pairedExportId": None,
        "createdAt": "2026-05-05T00:00:00+00:00",
        "targetRoot": target_root,
        "manifestUsed": "auto",
        "fileCount": len(files),
        "sources": [
            {"target": name, "kind": "file", "fileCount": 1}
            for name in files
        ],
    }
    with pyzipper.AESZipFile(zip_path, "w",
                              compression=pyzipper.ZIP_DEFLATED,
                              encryption=pyzipper.WZ_AES) as zf:
        zf.setpassword(password.encode("utf-8"))
        for arc_name, content in files.items():
            zf.writestr(arc_name, content)
        zf.writestr("secrets-manifest.json", json.dumps(manifest).encode("utf-8"))


# ---------------------------------------------------------------------------
# Test: generate_secrets_export — skipped (no secrets dir)
# ---------------------------------------------------------------------------

class TestExportSkipped(unittest.TestCase):

    def test_export_skipped_no_secrets_dir(self):
        """When discover_secrets_sources returns empty sources, status becomes 'skipped'."""
        job_id = _new_job_id()
        _make_export_job(job_id)

        empty_discovery = {"sources": [], "target_root": "secrets/", "manifest_used": "auto"}

        with patch("server.discover_secrets_sources", return_value=empty_discovery):
            generate_secrets_export(job_id, "academy", _PASSWORD)

        job = SECRETS_EXPORT_JOBS[job_id]
        self.assertEqual(job["status"], "skipped")
        self.assertIsNone(job.get("filename"))


# ---------------------------------------------------------------------------
# Test: generate_secrets_export — happy path
# ---------------------------------------------------------------------------

class TestExportHappyPath(unittest.TestCase):

    def test_export_happy_path(self):
        """1-2 small files → status=completed, zip exists, manifest included, readable with correct password."""
        with tempfile.TemporaryDirectory() as tmpdir:
            src_dir = Path(tmpdir) / "secrets"
            src_dir.mkdir()
            (src_dir / "api.key").write_text("SUPERSECRET=abc123", encoding="utf-8")
            (src_dir / "db.env").write_text("DB_PASS=hunter2", encoding="utf-8")

            discovery = {
                "sources": [
                    {"src": str(src_dir), "target": "secrets", "kind": "dir"},
                ],
                "target_root": "secrets/",
                "manifest_used": "auto",
            }

            export_dir = Path(tmpdir) / "exports"
            export_dir.mkdir()

            job_id = _new_job_id()
            _make_export_job(job_id)

            with patch("server.discover_secrets_sources", return_value=discovery), \
                 patch("server.EXPORT_DIR", export_dir):
                generate_secrets_export(job_id, "academy", _PASSWORD)

            job = SECRETS_EXPORT_JOBS[job_id]
            self.assertEqual(job["status"], "completed",
                             f"Unexpected status. Error: {job.get('error')}")
            self.assertIsNotNone(job.get("filename"))

            zip_path = export_dir / job["filename"]
            self.assertTrue(zip_path.exists(), "Zip file was not created")

            # Verify zip is readable with correct password and contains manifest
            with pyzipper.AESZipFile(zip_path, "r") as zf:
                zf.setpassword(_PASSWORD.encode("utf-8"))
                names = zf.namelist()
                self.assertIn("secrets-manifest.json", names)
                manifest_bytes = zf.read("secrets-manifest.json")
                manifest = json.loads(manifest_bytes)
                self.assertEqual(manifest["kind"], "lcars-team-secrets")
                self.assertEqual(manifest["version"], "1.0")
                self.assertGreater(manifest["fileCount"], 0)


# ---------------------------------------------------------------------------
# Test: wrong password makes zip unreadable
# ---------------------------------------------------------------------------

class TestExportWrongPassword(unittest.TestCase):

    def test_export_wrong_password_zip_unreadable(self):
        """An AES zip opened with the wrong password raises RuntimeError on content read."""
        with tempfile.TemporaryDirectory() as tmpdir:
            zip_path = Path(tmpdir) / "secrets.zip"
            _build_valid_zip(zip_path, _PASSWORD,
                             {"secrets/mysecret.env": b"SECRET=value"})

            with pyzipper.AESZipFile(zip_path, "r") as zf:
                zf.setpassword(_WRONG_PW.encode("utf-8"))
                with self.assertRaises(RuntimeError):
                    zf.read("secrets/mysecret.env")


# ---------------------------------------------------------------------------
# Tests: apply_secrets_import
# ---------------------------------------------------------------------------

class TestApplyImportWrongPassword(unittest.TestCase):

    def test_apply_import_wrong_password_message(self):
        """Wrong password sets status=failed with exact error string the UI depends on."""
        with tempfile.TemporaryDirectory() as tmpdir:
            zip_path = Path(tmpdir) / "secrets.zip"
            _build_valid_zip(zip_path, _PASSWORD,
                             {"secrets/api.key": b"APIKEY=abc"})

            job_id = _new_job_id()
            _make_import_job(job_id, str(zip_path), "academy")

            # Patch project root resolver to avoid aiteamforge_paths dependency
            with patch("secrets_export_lib._get_team_project_root", return_value=Path(tmpdir)), \
                 patch("secrets_export_lib._hardcoded_project_root", return_value=None):
                apply_secrets_import(job_id, _WRONG_PW)

        job = SECRETS_IMPORT_JOBS[job_id]
        self.assertEqual(job["status"], "failed")
        # Exact string match — the JS UI checks for this literal message
        self.assertEqual(job["error"], "Wrong password — please try again.")


class TestApplyImportCorruptZip(unittest.TestCase):

    def test_apply_import_corrupt_zip(self):
        """A non-zip file produces a friendly error message about corrupt zip."""
        with tempfile.TemporaryDirectory() as tmpdir:
            bad_zip = Path(tmpdir) / "notazip.zip"
            bad_zip.write_bytes(b"this is not a zip file at all")

            job_id = _new_job_id()
            _make_import_job(job_id, str(bad_zip), "academy")

            apply_secrets_import(job_id, _PASSWORD)

        job = SECRETS_IMPORT_JOBS[job_id]
        self.assertEqual(job["status"], "failed")
        self.assertIn("Invalid or corrupt secrets zip", job["error"])
        self.assertIn("re-export and try again", job["error"])


class TestApplyImportNoClobber(unittest.TestCase):

    def test_apply_import_no_clobber(self):
        """Pre-existing target file causes hard fail; no other files are extracted."""
        # Use a manually-managed temp dir so assertions can inspect it after the worker runs
        tmp_obj = tempfile.TemporaryDirectory()
        try:
            tmpdir = Path(tmp_obj.name)
            target_root = tmpdir

            # Create the colliding file at the arc-name path under project root
            arc_name = "secrets/existing.env"
            existing = target_root / arc_name
            existing.parent.mkdir(parents=True)
            existing.write_text("DO NOT OVERWRITE", encoding="utf-8")

            # Zip contains the colliding file plus a second innocent file
            zip_path = tmpdir / "secrets.zip"
            _build_valid_zip(zip_path, _PASSWORD, {
                arc_name: b"REPLACEMENT=bad",
                "secrets/innocent.env": b"INNOCENT=value",
            }, target_root="secrets/")

            job_id = _new_job_id()
            _make_import_job(job_id, str(zip_path), "academy")

            with patch("secrets_export_lib._get_team_project_root", return_value=target_root), \
                 patch("secrets_export_lib._hardcoded_project_root", return_value=None):
                apply_secrets_import(job_id, _PASSWORD)

            job = SECRETS_IMPORT_JOBS[job_id]
            self.assertEqual(job["status"], "failed")
            self.assertIn("File already exists at", job["error"])
            # The innocent file must NOT have been extracted (atomic — nothing extracted)
            innocent_path = target_root / "secrets" / "innocent.env"
            self.assertFalse(innocent_path.exists(),
                             "innocent.env should NOT be extracted when collision detected")
            # Existing file must be untouched
            self.assertEqual(existing.read_text(encoding="utf-8"), "DO NOT OVERWRITE")
        finally:
            tmp_obj.cleanup()


class TestApplyImportPathTraversalAbsolute(unittest.TestCase):

    def test_apply_import_path_traversal_absolute(self):
        """Arc entries with absolute paths are refused with 'absolute path entry' message."""
        with tempfile.TemporaryDirectory() as tmpdir:
            zip_path = Path(tmpdir) / "malicious.zip"

            # Craft a malicious zip with an absolute arc name
            manifest = {
                "version": "1.0",
                "kind": "lcars-team-secrets",
                "team": "academy",
                "baseTeam": "academy",
                "sourceHost": "attacker",
                "exportId": "evil",
                "pairedExportId": None,
                "createdAt": "2026-05-05T00:00:00+00:00",
                "targetRoot": "secrets/",
                "manifestUsed": "auto",
                "fileCount": 1,
                "sources": [],
            }
            with pyzipper.AESZipFile(zip_path, "w",
                                      compression=pyzipper.ZIP_DEFLATED,
                                      encryption=pyzipper.WZ_AES) as zf:
                zf.setpassword(_PASSWORD.encode("utf-8"))
                # Absolute path arc name — the key attack vector
                zf.writestr("/tmp/evil-absolute-target", b"malicious content")
                zf.writestr("secrets-manifest.json", json.dumps(manifest).encode("utf-8"))

            project_root = Path(tmpdir) / "project"
            project_root.mkdir()

            job_id = _new_job_id()
            _make_import_job(job_id, str(zip_path), "academy")

            with patch("secrets_export_lib._get_team_project_root", return_value=project_root), \
                 patch("secrets_export_lib._hardcoded_project_root", return_value=None):
                apply_secrets_import(job_id, _PASSWORD)

        job = SECRETS_IMPORT_JOBS[job_id]
        self.assertEqual(job["status"], "failed")
        self.assertIn("absolute path entry", job["error"],
                      f"Expected 'absolute path entry' in error, got: {job['error']!r}")
        # Ensure nothing was written outside project root
        evil_target = Path("/tmp/evil-absolute-target")
        self.assertFalse(evil_target.exists(),
                         "Malicious absolute-path file must not be created")


class TestApplyImportPathTraversalRelative(unittest.TestCase):

    def test_apply_import_path_traversal_relative(self):
        """Arc entries with ../ sequences that escape project_root are refused."""
        with tempfile.TemporaryDirectory() as tmpdir:
            zip_path = Path(tmpdir) / "traversal.zip"

            manifest = {
                "version": "1.0",
                "kind": "lcars-team-secrets",
                "team": "academy",
                "baseTeam": "academy",
                "sourceHost": "attacker",
                "exportId": "evil",
                "pairedExportId": None,
                "createdAt": "2026-05-05T00:00:00+00:00",
                "targetRoot": "secrets/",
                "manifestUsed": "auto",
                "fileCount": 1,
                "sources": [],
            }
            with pyzipper.AESZipFile(zip_path, "w",
                                      compression=pyzipper.ZIP_DEFLATED,
                                      encryption=pyzipper.WZ_AES) as zf:
                zf.setpassword(_PASSWORD.encode("utf-8"))
                # Classic path traversal — would write outside project_root
                zf.writestr("../../etc/passwd_attempt", b"malicious content")
                zf.writestr("secrets-manifest.json", json.dumps(manifest).encode("utf-8"))

            project_root = Path(tmpdir) / "project"
            project_root.mkdir()

            job_id = _new_job_id()
            _make_import_job(job_id, str(zip_path), "academy")

            with patch("secrets_export_lib._get_team_project_root", return_value=project_root), \
                 patch("secrets_export_lib._hardcoded_project_root", return_value=None):
                apply_secrets_import(job_id, _PASSWORD)

        job = SECRETS_IMPORT_JOBS[job_id]
        self.assertEqual(job["status"], "failed")
        self.assertIn("escapes the target directory", job["error"],
                      f"Expected traversal rejection message, got: {job['error']!r}")
        # Verify nothing was written to the escape location
        escape_target = Path(tmpdir) / "etc" / "passwd_attempt"
        self.assertFalse(escape_target.exists(),
                         "Path-traversal target must not be created")


# ---------------------------------------------------------------------------
# Test: retry budget (preflight handler, not worker)
# ---------------------------------------------------------------------------

class TestRetryBudget(unittest.TestCase):

    def test_apply_import_retry_budget_exhaustion(self):
        # TODO: integration test — the retry budget (_SECRETS_IMPORT_MAX_PASSWORD_ATTEMPTS = 5)
        # is enforced in the HTTP preflight handler route (server.py ~line 9344), not inside
        # apply_secrets_import() itself. The worker always processes a single attempt and
        # returns 'failed' with "Wrong password — please try again." on bad password.
        # Testing the budget exhaustion requires either:
        #   a) Spinning up the full HTTP server and making 5+ preflight POST requests, or
        #   b) Calling the preflight handler's inner logic directly (currently inline, not extracted).
        # Skipping until the preflight counter logic is extracted into a testable helper function.
        # See XACA-0172 backlog for follow-up: "[Test] Extract preflight retry counter into unit-testable helper"
        pass


# ---------------------------------------------------------------------------
# Test: XACA-0491 — double-prefix regression (secrets/secrets/ bug)
# ---------------------------------------------------------------------------

class TestExportImportNoDoublePrefix(unittest.TestCase):
    """Regression test for XACA-0491.

    Before the fix, the auto-detect branch of discover_secrets_sources() returned
    target="secrets" AND target_root="secrets/", causing the arc-name builder to
    produce "secrets/secrets/<rel>" instead of "secrets/<rel>".  The importer
    then extracted to <project_root>/secrets/secrets/* instead of
    <project_root>/secrets/*.

    This test exercises the full export->import round-trip and asserts the
    extracted files land at the CORRECT single-nested path.

    On pre-fix code this test fails because:
    - arc names inside the zip are "secrets/secrets/foo.txt", not "secrets/foo.txt"
    - imported files appear at <import_root>/secrets/secrets/foo.txt
    - <import_root>/secrets/secrets/ exists (our explicit assertion catches it)
    """

    def test_round_trip_no_double_prefix(self):
        """Export + import of a real secrets/ dir lands files at ./secrets/* only."""
        with tempfile.TemporaryDirectory() as export_tmpdir, \
             tempfile.TemporaryDirectory() as import_tmpdir:

            # ----------------------------------------------------------------
            # 1. Build a source project with secrets/ content
            # ----------------------------------------------------------------
            src_project = Path(export_tmpdir) / "project"
            secrets_dir = src_project / "secrets"
            secrets_dir.mkdir(parents=True)
            (secrets_dir / "foo.txt").write_text("SOME_SECRET=abc", encoding="utf-8")
            sub = secrets_dir / "sub"
            sub.mkdir()
            (sub / "bar.txt").write_text("NESTED_SECRET=xyz", encoding="utf-8")

            export_dir = Path(export_tmpdir) / "exports"
            export_dir.mkdir()

            # ----------------------------------------------------------------
            # 2. Export — wire discovery to the real secrets/ dir via auto-detect
            # ----------------------------------------------------------------
            export_job_id = _new_job_id()
            _make_export_job(export_job_id)

            with patch("server.discover_secrets_sources") as mock_discover, \
                 patch("server.EXPORT_DIR", export_dir):
                mock_discover.return_value = {
                    "sources": [
                        {"src": str(secrets_dir), "target": "", "kind": "dir"},
                    ],
                    "target_root": "secrets/",
                    "manifest_used": "auto",
                }
                generate_secrets_export(export_job_id, "academy", _PASSWORD)

            export_job = SECRETS_EXPORT_JOBS[export_job_id]
            self.assertEqual(export_job["status"], "completed",
                             f"Export failed: {export_job.get('error')}")
            zip_path = export_dir / export_job["filename"]
            self.assertTrue(zip_path.exists())

            # ----------------------------------------------------------------
            # 3. Verify arc names inside the zip — must be "secrets/…", NOT "secrets/secrets/…"
            # ----------------------------------------------------------------
            with pyzipper.AESZipFile(zip_path, "r") as zf:
                zf.setpassword(_PASSWORD.encode("utf-8"))
                arc_names = [n for n in zf.namelist() if n != "secrets-manifest.json"]

            for arc_name in arc_names:
                self.assertFalse(
                    arc_name.startswith("secrets/secrets/"),
                    f"Double-prefix bug present: arc_name={arc_name!r} starts with "
                    f"'secrets/secrets/' — expected 'secrets/<file>'",
                )
                self.assertTrue(
                    arc_name.startswith("secrets/"),
                    f"Unexpected arc_name prefix: {arc_name!r}",
                )

            # ----------------------------------------------------------------
            # 4. Import into a fresh project root
            # ----------------------------------------------------------------
            import_project = Path(import_tmpdir) / "project"
            import_project.mkdir()

            import_job_id = _new_job_id()
            _make_import_job(import_job_id, str(zip_path), "academy")

            with patch("secrets_export_lib._get_team_project_root", return_value=import_project), \
                 patch("secrets_export_lib._hardcoded_project_root", return_value=None):
                apply_secrets_import(import_job_id, _PASSWORD)

            import_job = SECRETS_IMPORT_JOBS[import_job_id]
            self.assertEqual(import_job["status"], "completed",
                             f"Import failed: {import_job.get('error')}")

            # ----------------------------------------------------------------
            # 5. Assert correct single-nested extraction paths
            # ----------------------------------------------------------------
            expected_foo = import_project / "secrets" / "foo.txt"
            expected_bar = import_project / "secrets" / "sub" / "bar.txt"
            double_prefix_dir = import_project / "secrets" / "secrets"

            self.assertTrue(expected_foo.exists(),
                            f"Missing: {expected_foo} — import landed in wrong location")
            self.assertTrue(expected_bar.exists(),
                            f"Missing: {expected_bar} — import landed in wrong location")
            self.assertFalse(double_prefix_dir.exists(),
                             f"Double-prefix bug: {double_prefix_dir} should NOT exist "
                             f"(files extracted to secrets/secrets/ instead of secrets/)")


# ---------------------------------------------------------------------------
# Tests: XACA-0381 — thread-lock regression tests (F-04-003)
# ---------------------------------------------------------------------------

class TestPruneRaceCondition(unittest.TestCase):
    """Concurrency regression for _prune_old_secrets_jobs + concurrent writers.

    Without _SECRETS_JOBS_LOCK this test reliably produces:
        RuntimeError: dictionary changed size during iteration

    With the lock it must complete silently with no exception.
    """

    def setUp(self):
        # Clear dicts so jobs from other tests don't leak in
        SECRETS_IMPORT_JOBS.clear()
        SECRETS_EXPORT_JOBS.clear()

    def tearDown(self):
        SECRETS_IMPORT_JOBS.clear()
        SECRETS_EXPORT_JOBS.clear()

    def test_prune_concurrent_create_no_race(self):
        """Prune + concurrent creates must not raise RuntimeError."""
        errors = []
        stop_event = threading.Event()

        # Two-hour-old ISO string so entries are eligible for pruning
        from datetime import datetime, timezone, timedelta
        old_ts = (datetime.now(timezone.utc) - timedelta(hours=2)).isoformat()

        N_THREADS = 8
        N_ITERS = 200

        def writer():
            for _ in range(N_ITERS):
                if stop_event.is_set():
                    break
                jid = str(uuid.uuid4())
                try:
                    _secrets_job_create(SECRETS_IMPORT_JOBS, jid, {
                        'status': 'completed',
                        'createdAt': old_ts,
                        'message': '',
                        'progress': 100,
                    })
                    _secrets_job_update(SECRETS_IMPORT_JOBS, jid, {'message': 'updated'})
                except Exception as exc:
                    errors.append(exc)
                    stop_event.set()

        def pruner():
            for _ in range(N_ITERS):
                if stop_event.is_set():
                    break
                try:
                    _prune_old_secrets_jobs()
                except Exception as exc:
                    errors.append(exc)
                    stop_event.set()

        threads = [threading.Thread(target=writer) for _ in range(N_THREADS)]
        threads.append(threading.Thread(target=pruner))
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=10)

        stop_event.set()
        self.assertEqual(
            errors, [],
            f"Concurrency errors: {errors[:3]!r} (showing first 3)"
        )


class TestImportJobHelpers(unittest.TestCase):
    """Unit tests for _import_job_* helpers (XACA-0381)."""

    def setUp(self):
        IMPORT_JOBS.clear()

    def tearDown(self):
        IMPORT_JOBS.clear()

    def test_update_missing_job_is_noop(self):
        """_import_job_update on a nonexistent job must not raise and must not create the key."""
        _import_job_update('nonexistent-id', {'status': 'failed'})
        self.assertNotIn('nonexistent-id', IMPORT_JOBS)

    def test_snapshot_returns_independent_copy(self):
        """Mutating the snapshot dict must not affect the registry."""
        jid = _new_job_id()
        _import_job_create(jid, {'status': 'staged', 'progress': 0, 'message': 'ok'})
        snap = _import_job_snapshot(jid)
        self.assertIsNotNone(snap)
        # Mutate the snapshot
        snap['status'] = 'MUTATED'
        snap['extra_key'] = 'injected'
        # Registry must be unchanged
        live = _import_job_get(jid)
        self.assertEqual(live['status'], 'staged', "Snapshot mutation leaked into registry")
        self.assertNotIn('extra_key', live, "Extra key from snapshot leak found in registry")

    def test_snapshot_returns_none_for_missing(self):
        """_import_job_snapshot must return None for an unknown job_id."""
        result = _import_job_snapshot('no-such-job')
        self.assertIsNone(result)

    def test_secrets_snapshot_returns_independent_copy(self):
        """Mutating the secrets snapshot must not affect the registry."""
        SECRETS_IMPORT_JOBS.clear()
        try:
            jid = _new_job_id()
            _secrets_job_create(SECRETS_IMPORT_JOBS, jid, {
                'status': 'ready',
                'progress': 15,
                'message': 'verified',
            })
            snap = _secrets_job_snapshot(SECRETS_IMPORT_JOBS, jid)
            self.assertIsNotNone(snap)
            snap['status'] = 'MUTATED'
            live = SECRETS_IMPORT_JOBS.get(jid)
            self.assertEqual(live['status'], 'ready',
                             "Snapshot mutation leaked into SECRETS_IMPORT_JOBS registry")
        finally:
            SECRETS_IMPORT_JOBS.clear()


# ---------------------------------------------------------------------------
# Tests: XACA-0381-002 — EXPORT_JOBS concurrency + snapshot
# ---------------------------------------------------------------------------

class TestExportPruneRaceCondition(unittest.TestCase):
    """Concurrency regression for _prune_old_export_jobs + concurrent writers.

    Without _EXPORT_JOBS_LOCK the prune loop (dict scan+delete while a worker
    thread calls _export_job_create / _export_job_update) reliably produces:
        RuntimeError: dictionary changed size during iteration

    With the lock it must complete silently with no exception.
    """

    def setUp(self):
        EXPORT_JOBS.clear()

    def tearDown(self):
        EXPORT_JOBS.clear()

    def test_export_prune_concurrent_create_no_race(self):
        """_prune_old_export_jobs + concurrent _export_job_create/update must not raise."""
        errors = []
        stop_event = threading.Event()

        from datetime import datetime, timezone, timedelta
        old_ts = (datetime.now(timezone.utc) - timedelta(hours=2)).isoformat()

        N_THREADS = 8
        N_ITERS = 200

        def writer():
            for _ in range(N_ITERS):
                if stop_event.is_set():
                    break
                jid = str(uuid.uuid4())
                try:
                    _export_job_create(jid, {
                        'status': 'completed',
                        'createdAt': old_ts,
                        'message': '',
                        'progress': 100,
                    })
                    _export_job_update(jid, {'message': 'updated'})
                except Exception as exc:
                    errors.append(exc)
                    stop_event.set()

        def pruner():
            for _ in range(N_ITERS):
                if stop_event.is_set():
                    break
                try:
                    _prune_old_export_jobs()
                except Exception as exc:
                    errors.append(exc)
                    stop_event.set()

        threads = [threading.Thread(target=writer) for _ in range(N_THREADS)]
        threads.append(threading.Thread(target=pruner))
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=10)

        stop_event.set()
        self.assertEqual(
            errors, [],
            f"Concurrency errors: {errors[:3]!r} (showing first 3)"
        )


class TestExportSnapshotIndependentCopy(unittest.TestCase):
    """_export_job_snapshot must return a copy that is independent from the registry."""

    def setUp(self):
        EXPORT_JOBS.clear()

    def tearDown(self):
        EXPORT_JOBS.clear()

    def test_export_snapshot_independent_copy(self):
        jid = str(uuid.uuid4())
        _export_job_create(jid, {'status': 'generating', 'progress': 0, 'message': 'init'})
        snap = _export_job_snapshot(jid)
        self.assertIsNotNone(snap)
        # Mutating the snapshot must not affect the live registry
        snap['status'] = 'MUTATED'
        snap['injected'] = 'bad'
        live = EXPORT_JOBS.get(jid)
        self.assertEqual(live['status'], 'generating',
                         "Snapshot mutation leaked into EXPORT_JOBS registry")
        self.assertNotIn('injected', live,
                         "Extra key from snapshot mutation found in registry")

    def test_export_snapshot_returns_none_for_missing(self):
        result = _export_job_snapshot('no-such-job')
        self.assertIsNone(result)


# ---------------------------------------------------------------------------
# Tests: XACA-0381-001 — CAS helpers (staged→applying TOCTOU)
# ---------------------------------------------------------------------------

class TestImportCasSingleWinner(unittest.TestCase):
    """Only one of N concurrent apply-callers may transition the job to 'applying'."""

    def setUp(self):
        IMPORT_JOBS.clear()

    def tearDown(self):
        IMPORT_JOBS.clear()

    def test_import_cas_single_winner(self):
        jid = str(uuid.uuid4())
        _import_job_create(jid, {'status': 'staged', 'progress': 0, 'message': 'ready'})

        results = []

        def try_apply():
            won = _import_job_compare_and_set_status(
                jid, ('staged',), {'status': 'applying', 'progress': 5})
            results.append(won)

        N = 10
        threads = [threading.Thread(target=try_apply) for _ in range(N)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=5)

        winners = [r for r in results if r is True]
        self.assertEqual(len(winners), 1,
                         f"Expected exactly 1 CAS winner, got {len(winners)}: {results}")
        # Final state must be 'applying'
        live = IMPORT_JOBS.get(jid)
        self.assertEqual(live['status'], 'applying')

    def test_import_cas_returns_false_for_wrong_status(self):
        jid = str(uuid.uuid4())
        _import_job_create(jid, {'status': 'completed', 'progress': 100, 'message': 'done'})
        won = _import_job_compare_and_set_status(jid, ('staged',), {'status': 'applying'})
        self.assertFalse(won)
        # Status must be unchanged
        self.assertEqual(IMPORT_JOBS[jid]['status'], 'completed')

    def test_import_cas_returns_false_for_missing_job(self):
        won = _import_job_compare_and_set_status('no-such-id', ('staged',), {'status': 'applying'})
        self.assertFalse(won)


class TestSecretsCasSingleWinner(unittest.TestCase):
    """Only one of N concurrent apply-callers may win the secrets CAS."""

    def setUp(self):
        SECRETS_IMPORT_JOBS.clear()

    def tearDown(self):
        SECRETS_IMPORT_JOBS.clear()

    def test_secrets_cas_single_winner(self):
        jid = str(uuid.uuid4())
        _secrets_job_create(SECRETS_IMPORT_JOBS, jid, {
            'status': 'awaiting-password', 'progress': 0, 'message': 'waiting',
        })

        results = []

        def try_apply():
            won = _secrets_job_compare_and_set_status(
                SECRETS_IMPORT_JOBS, jid,
                ('awaiting-password', 'ready'),
                {'status': 'applying', 'progress': 0, 'message': 'Starting...', 'error': None})
            results.append(won)

        N = 10
        threads = [threading.Thread(target=try_apply) for _ in range(N)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=5)

        winners = [r for r in results if r is True]
        self.assertEqual(len(winners), 1,
                         f"Expected exactly 1 CAS winner, got {len(winners)}: {results}")
        live = SECRETS_IMPORT_JOBS.get(jid)
        self.assertEqual(live['status'], 'applying')

    def test_secrets_cas_accepts_ready_status(self):
        """CAS must also accept 'ready' as the starting state (not just 'awaiting-password')."""
        jid = str(uuid.uuid4())
        _secrets_job_create(SECRETS_IMPORT_JOBS, jid, {
            'status': 'ready', 'progress': 0, 'message': 'verified',
        })
        won = _secrets_job_compare_and_set_status(
            SECRETS_IMPORT_JOBS, jid,
            ('awaiting-password', 'ready'),
            {'status': 'applying', 'progress': 0, 'message': 'Starting...', 'error': None})
        self.assertTrue(won)
        self.assertEqual(SECRETS_IMPORT_JOBS[jid]['status'], 'applying')

    def test_secrets_cas_returns_false_for_wrong_status(self):
        jid = str(uuid.uuid4())
        _secrets_job_create(SECRETS_IMPORT_JOBS, jid, {
            'status': 'applying', 'progress': 10, 'message': 'in progress',
        })
        won = _secrets_job_compare_and_set_status(
            SECRETS_IMPORT_JOBS, jid,
            ('awaiting-password', 'ready'),
            {'status': 'applying', 'progress': 0})
        self.assertFalse(won)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    unittest.main()
