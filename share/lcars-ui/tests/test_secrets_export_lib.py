#!/usr/bin/env python3

#
#  test_secrets_export_lib.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""
Unit tests for lcars-ui/secrets_export_lib.py

Covers: pyzipper_available, validate_secrets_manifest (schema cases),
discover_secrets_sources (manifest + auto-detect + empty), manifest constants.

Run with:
    python3 -m unittest discover -s lcars-ui/tests -p 'test_*.py'
  or directly:
    python3 -m unittest lcars-ui/tests/test_secrets_export_lib.py
"""

import json
import sys
import tempfile
import unittest
from pathlib import Path

# ---------------------------------------------------------------------------
# Path wiring — match test_server.py convention
# ---------------------------------------------------------------------------
LCARS_UI_DIR = Path(__file__).parent.parent
REPO_ROOT = LCARS_UI_DIR.parent
sys.path.insert(0, str(LCARS_UI_DIR))
sys.path.insert(0, str(REPO_ROOT))

from secrets_export_lib import (  # noqa: E402
    SECRETS_EXPORT_MANIFEST_KIND,
    SECRETS_EXPORT_MANIFEST_VERSION,
    discover_secrets_sources,
    pyzipper_available,
    validate_secrets_manifest,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _valid_manifest_dict():
    """Return a minimal valid secrets-manifest.json dict."""
    return {
        "version": "1.0",
        "kind": "lcars-team-secrets-source",
        "targetRoot": "secrets/",
        "sources": [
            {"src": "/tmp/fake-secret.env", "target": "env/.env"},
        ],
    }


def _write_manifest(directory: Path, data: dict) -> Path:
    """Write data as JSON to <directory>/secrets-manifest.json and return the path."""
    path = directory / "secrets-manifest.json"
    path.write_text(json.dumps(data), encoding="utf-8")
    return path


# ---------------------------------------------------------------------------
# Tests: pyzipper_available
# ---------------------------------------------------------------------------

class TestPyzipperAvailable(unittest.TestCase):

    def test_pyzipper_available(self):
        """pyzipper_available() returns True when pyzipper is installed."""
        result = pyzipper_available()
        self.assertIsInstance(result, bool)
        # pyzipper is required for the secrets flow — it must be present in CI/dev
        self.assertTrue(result, "pyzipper is not installed — install it with pip install pyzipper")


# ---------------------------------------------------------------------------
# Tests: validate_secrets_manifest
# ---------------------------------------------------------------------------

class TestValidateSecretsManifest(unittest.TestCase):

    def test_validate_secrets_manifest_valid(self):
        """A correct manifest parses without raising."""
        with tempfile.TemporaryDirectory() as tmpdir:
            path = _write_manifest(Path(tmpdir), _valid_manifest_dict())
            data = validate_secrets_manifest(path)
        self.assertEqual(data["kind"], "lcars-team-secrets-source")
        self.assertEqual(data["version"], "1.0")
        self.assertIsInstance(data["sources"], list)

    def test_validate_secrets_manifest_missing_kind(self):
        """Missing 'kind' key raises ValueError with helpful message."""
        bad = _valid_manifest_dict()
        del bad["kind"]
        with tempfile.TemporaryDirectory() as tmpdir:
            path = _write_manifest(Path(tmpdir), bad)
            with self.assertRaises(ValueError) as ctx:
                validate_secrets_manifest(path)
        self.assertIn("missing required keys", str(ctx.exception))
        self.assertIn("kind", str(ctx.exception))

    def test_validate_secrets_manifest_wrong_kind(self):
        """Wrong 'kind' value raises ValueError."""
        bad = _valid_manifest_dict()
        bad["kind"] = "totally-wrong-kind"
        with tempfile.TemporaryDirectory() as tmpdir:
            path = _write_manifest(Path(tmpdir), bad)
            with self.assertRaises(ValueError) as ctx:
                validate_secrets_manifest(path)
        self.assertIn("kind", str(ctx.exception))

    def test_validate_secrets_manifest_missing_version(self):
        """Missing 'version' key raises ValueError."""
        bad = _valid_manifest_dict()
        del bad["version"]
        with tempfile.TemporaryDirectory() as tmpdir:
            path = _write_manifest(Path(tmpdir), bad)
            with self.assertRaises(ValueError) as ctx:
                validate_secrets_manifest(path)
        self.assertIn("missing required keys", str(ctx.exception))

    def test_validate_secrets_manifest_missing_sources(self):
        """Missing 'sources' key raises ValueError."""
        bad = _valid_manifest_dict()
        del bad["sources"]
        with tempfile.TemporaryDirectory() as tmpdir:
            path = _write_manifest(Path(tmpdir), bad)
            with self.assertRaises(ValueError) as ctx:
                validate_secrets_manifest(path)
        self.assertIn("missing required keys", str(ctx.exception))

    def test_validate_secrets_manifest_invalid_source_entry(self):
        """A source entry missing 'src' raises ValueError."""
        bad = _valid_manifest_dict()
        bad["sources"] = [{"target": "env/.env"}]  # missing 'src'
        with tempfile.TemporaryDirectory() as tmpdir:
            path = _write_manifest(Path(tmpdir), bad)
            with self.assertRaises(ValueError) as ctx:
                validate_secrets_manifest(path)
        self.assertIn("src", str(ctx.exception))

    def test_validate_secrets_manifest_not_json(self):
        """Non-JSON content raises ValueError."""
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "secrets-manifest.json"
            path.write_text("this is not json {{{{", encoding="utf-8")
            with self.assertRaises(ValueError) as ctx:
                validate_secrets_manifest(path)
        self.assertIn("not valid JSON", str(ctx.exception))


# ---------------------------------------------------------------------------
# Tests: discover_secrets_sources
# ---------------------------------------------------------------------------

class TestDiscoverSecretsSources(unittest.TestCase):

    def _patch_project_root(self, fake_root: Path):
        """Monkeypatch both project-root resolvers to point at fake_root."""
        import secrets_export_lib as lib

        orig_get = lib._get_team_project_root
        orig_hard = lib._hardcoded_project_root

        lib._get_team_project_root = lambda team_id: fake_root
        lib._hardcoded_project_root = lambda team_id: None

        return orig_get, orig_hard

    def _restore_project_root(self, orig_get, orig_hard):
        import secrets_export_lib as lib
        lib._get_team_project_root = orig_get
        lib._hardcoded_project_root = orig_hard

    def test_discover_secrets_sources_with_manifest(self):
        """Manifest at kanban/<team>/secrets-manifest.json is picked up correctly."""
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            kanban_team = root / "kanban" / "testteam"
            kanban_team.mkdir(parents=True)

            # Create the actual source file so the path exists
            src_file = root / "mysecret.env"
            src_file.write_text("SECRET=value", encoding="utf-8")

            manifest_data = {
                "version": "1.0",
                "kind": "lcars-team-secrets-source",
                "targetRoot": "secrets/",
                "sources": [
                    {"src": str(src_file), "target": "env/.env"},
                ],
            }
            _write_manifest(kanban_team, manifest_data)

            orig_get, orig_hard = self._patch_project_root(root)
            try:
                result = discover_secrets_sources("testteam")
            finally:
                self._restore_project_root(orig_get, orig_hard)

        self.assertEqual(len(result["sources"]), 1)
        self.assertEqual(result["target_root"], "secrets/")
        self.assertIn("override:", result["manifest_used"])
        src = result["sources"][0]
        self.assertEqual(src["target"], "env/.env")

    def test_discover_secrets_sources_auto_detect(self):
        """Auto-detect finds <project_root>/secrets/ when no manifest is present."""
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            secrets_dir = root / "secrets"
            secrets_dir.mkdir()

            orig_get, orig_hard = self._patch_project_root(root)
            try:
                result = discover_secrets_sources("testteam")
            finally:
                self._restore_project_root(orig_get, orig_hard)

        self.assertEqual(len(result["sources"]), 1)
        src = result["sources"][0]
        self.assertEqual(src["kind"], "dir")
        self.assertEqual(src["target_root"] if "target_root" in src else result["target_root"], "secrets/")
        self.assertEqual(result["manifest_used"], "auto")

    def test_discover_secrets_sources_empty(self):
        """No manifest and no secrets dir → empty sources list."""
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            # No kanban dir, no secrets dir

            orig_get, orig_hard = self._patch_project_root(root)
            try:
                result = discover_secrets_sources("testteam")
            finally:
                self._restore_project_root(orig_get, orig_hard)

        self.assertEqual(result["sources"], [])


# ---------------------------------------------------------------------------
# Tests: manifest constants
# ---------------------------------------------------------------------------

class TestManifestConstants(unittest.TestCase):

    def test_manifest_kind_constant(self):
        """SECRETS_EXPORT_MANIFEST_KIND has the expected wire value."""
        self.assertEqual(SECRETS_EXPORT_MANIFEST_KIND, "lcars-team-secrets")

    def test_manifest_version_constant(self):
        """SECRETS_EXPORT_MANIFEST_VERSION is '1.0'."""
        self.assertEqual(SECRETS_EXPORT_MANIFEST_VERSION, "1.0")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    unittest.main()
