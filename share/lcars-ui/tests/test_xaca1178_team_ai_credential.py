#!/usr/bin/env python3

#
#  test_xaca1178_team_ai_credential.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""
Unit tests for XACA-1178-007: the ai.credential shape in team-paths.json,
per the merged XACA-0282-012 decision (docs/xaca-0282/research/012-credential-
config-shape.md, PR #871).

That decision REPLACED this subitem's original plan ("write a flat
anthropic_auth_type field") with a nested shape: team-paths.json gets
teams.<team>.ai.credential, a whole-object snapshot of one Fleet Monitor
account (engine_slug, account_slug, account_id, nickname, auth_type,
env_var_name). There is never a flat anthropic_auth_type field.

The legacy anthropic_account_id / anthropic_account_nickname /
anthropic_api_key_env_var fields are FROZEN, not deleted: one helper
(_set_team_ai_credential) writes them as a derived projection of
ai.credential so the ~13 existing legacy readers keep working unmodified.
anthropic_account_ref is dropped -- nothing read it, and it went stale the
moment a save didn't also touch it (decision doc F5).

Covers:
  - _set_team_ai_credential() unit behavior (whole-object replace, legacy
    projection, ai.credential = null clearing, other ai keys preserved,
    anthropic_account_ref dropped).
  - handle_team_account_assign() writes the ai.credential snapshot + legacy
    projection from a matched Fleet Monitor account, auth_type included only
    when the registry account has one.
  - handle_team_account_save() (MANUAL path): builds ai.credential from the
    request body, validates auth_type, all-empty body clears to null.
  - serve_team_account_current(): returns the new shape; a team whose entry
    has no 'ai' key at all is read without crashing (config_source: legacy).
  - An invalid auth_type is rejected with 400 on save.

Run with:
    python3 -m unittest lcars-ui/tests/test_xaca1178_team_ai_credential.py
  or from the repo root:
    python3 -m unittest discover -s lcars-ui/tests -p 'test_*.py'
"""

import io
import json
import os
import sys
import tempfile
import shutil
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

# ---------------------------------------------------------------------------
# Same import-stubbing dance as test_xaca1178_fleet_monitor_url.py /
# test_xaca1178_test_connection_auth_scheme.py -- server.py has optional
# module-level imports (calendar sync, integrations, kanban_utils) that must
# be stubbed out before import so this file can be run standalone.
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

import server  # noqa: E402  (module-level import after path manipulation)
from server import LCARSHandler  # noqa: E402

TEST_TEAM = "xaca1178testteam"


def _make_handler(path="/", method="POST", body=b""):
    """Construct an LCARSHandler instance with all socket I/O mocked out.

    Mirrors test_xaca1178_test_connection_auth_scheme.py's _make_handler.
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
    handler.headers = {"Content-Length": str(len(body))}
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
    buf.seek(0)
    return json.loads(buf.read().decode())


class _TeamPathsFixtureMixin:
    """Sets HOME to a throwaway tempdir holding a real ~/.aiteamforge/team-paths.json
    with TEST_TEAM registered, and patches server.TEAM_KANBAN_DIRS so the handler's
    validation accepts it. Also resets LCARSHandler's mtime cache, which is a class
    attribute shared across tests.
    """

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp(prefix="xaca1178-ai-cred-")
        self.home = self.tmpdir
        (Path(self.home) / ".aiteamforge").mkdir(parents=True, exist_ok=True)
        self.team_paths_file = Path(self.home) / ".aiteamforge" / "team-paths.json"

        # Payload padded with extra unrelated teams so _write_team_paths_registry's
        # 200-byte plausibility floor (XACA-1059-006) is comfortably cleared, and to
        # verify a write to one team never disturbs another's block.
        self._write_team_paths({
            "teams": {
                TEST_TEAM: {
                    "team_code": "X1178",
                    "kanban_dir": "/tmp/x1178/kanban",
                    "working_dir": "/tmp/x1178",
                    "lcars_port": 8999,
                },
                "unrelated-sibling-team": {
                    "team_code": "SIB",
                    "kanban_dir": "/tmp/sibling/kanban",
                    "working_dir": "/tmp/sibling",
                    "lcars_port": 8998,
                },
            }
        })

        self._patches = []

        env_patch = patch.dict(os.environ, {"HOME": self.home}, clear=False)
        env_patch.start()
        self._patches.append(env_patch)

        team_dirs_patch = patch.dict(
            server.TEAM_KANBAN_DIRS,
            {TEST_TEAM: "/tmp/x1178/kanban", "unrelated-sibling-team": "/tmp/sibling/kanban"},
            clear=False,
        )
        team_dirs_patch.start()
        self._patches.append(team_dirs_patch)

        # LCARSHandler._TEAM_PATHS_CACHE is a class attribute keyed by mtime_ns
        # only (not by path) -- a stale entry from an earlier test/process would
        # make _read_team_paths_raw() return the WRONG file's content if the
        # mtime happened to collide, or just serve last test's now-stale cache.
        # Reset it before and after every test.
        with LCARSHandler._TEAM_PATHS_CACHE_LOCK:
            LCARSHandler._TEAM_PATHS_CACHE = {"mtime_ns": None, "data": None}

    def tearDown(self):
        for p in reversed(self._patches):
            p.stop()
        with LCARSHandler._TEAM_PATHS_CACHE_LOCK:
            LCARSHandler._TEAM_PATHS_CACHE = {"mtime_ns": None, "data": None}
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _write_team_paths(self, data):
        with open(self.team_paths_file, "w") as f:
            json.dump(data, f, indent=2)

    def _read_team_paths(self):
        with open(self.team_paths_file, "r") as f:
            return json.load(f)


class SetTeamAiCredentialHelperTests(unittest.TestCase):
    """Direct unit tests of _set_team_ai_credential(), no HTTP/handler involved."""

    def _handler(self):
        with patch.object(LCARSHandler, "__init__", lambda self, *a, **kw: None):
            return LCARSHandler.__new__(LCARSHandler)

    def test_whole_object_replace_writes_credential_and_projection(self):
        handler = self._handler()
        team_block = {"team_code": "ACA"}
        credential = {
            "engine_slug": "anthropic",
            "account_slug": "me-max",
            "account_id": "acct-me",
            "nickname": "ME (Max)",
            "auth_type": "oauth_token",
            "env_var_name": "CLAUDE_ACCT_ME_TOKEN",
        }

        handler._set_team_ai_credential(team_block, credential)

        self.assertEqual(team_block["ai"]["credential"], credential)
        self.assertEqual(team_block["anthropic_account_id"], "acct-me")
        self.assertEqual(team_block["anthropic_account_nickname"], "ME (Max)")
        self.assertEqual(team_block["anthropic_api_key_env_var"], "CLAUDE_ACCT_ME_TOKEN")
        self.assertNotIn("anthropic_account_ref", team_block)

    def test_none_credential_writes_null_and_clears_projection(self):
        handler = self._handler()
        team_block = {
            "team_code": "ACA",
            "ai": {"credential": {"engine_slug": "anthropic", "account_id": "old"}},
            "anthropic_account_id": "old",
            "anthropic_account_nickname": "Old Nick",
            "anthropic_api_key_env_var": "OLD_VAR",
            "anthropic_account_ref": "anthropic/old-slug",
        }

        handler._set_team_ai_credential(team_block, None)

        self.assertIsNone(team_block["ai"]["credential"])
        self.assertEqual(team_block["anthropic_account_id"], "")
        self.assertEqual(team_block["anthropic_account_nickname"], "")
        self.assertEqual(team_block["anthropic_api_key_env_var"], "")
        self.assertNotIn("anthropic_account_ref", team_block)

    def test_stale_account_ref_dropped_on_replace(self):
        handler = self._handler()
        team_block = {"anthropic_account_ref": "anthropic/stale-slug"}

        handler._set_team_ai_credential(team_block, {
            "engine_slug": "anthropic",
            "account_id": "new",
            "nickname": "New",
            "env_var_name": "NEW_VAR",
        })

        self.assertNotIn("anthropic_account_ref", team_block)

    def test_other_ai_keys_preserved(self):
        handler = self._handler()
        team_block = {"ai": {"cli": "claude", "provider_config": {"claude": {"foo": "bar"}}}}

        handler._set_team_ai_credential(team_block, {
            "engine_slug": "anthropic",
            "account_id": "acct-x",
            "nickname": "X",
            "env_var_name": "TEAM_X_API_KEY",
        })

        self.assertEqual(team_block["ai"]["cli"], "claude")
        self.assertEqual(team_block["ai"]["provider_config"], {"claude": {"foo": "bar"}})
        self.assertEqual(team_block["ai"]["credential"]["account_id"], "acct-x")

    def test_missing_optional_fields_project_as_empty_string_not_none(self):
        handler = self._handler()
        team_block = {}
        # A credential with no nickname/env_var_name at all (e.g. a bare manual
        # account_id save) must still project clean empty strings, not the
        # literal None, into the legacy trio -- some legacy readers do
        # `str(team_block.get('anthropic_account_nickname'))` without an
        # `or ''` guard of their own.
        handler._set_team_ai_credential(team_block, {"engine_slug": "anthropic", "account_id": "only-id"})

        self.assertEqual(team_block["anthropic_account_nickname"], "")
        self.assertEqual(team_block["anthropic_api_key_env_var"], "")

    def test_non_dict_ai_block_is_coerced_not_typeerror(self):
        """XACA-1178-017: a stray non-dict 'ai' key (hand-edited team-paths.json,
        a botched migration) must be replaced with a fresh dict, not raise
        TypeError on `ai_block['credential'] = credential` ('str' object does
        not support item assignment / list indices must be integers)."""
        handler = self._handler()
        for bogus_ai in ("not-a-dict", ["also", "not", "a", "dict"], 42, True):
            team_block = {"ai": bogus_ai}
            handler._set_team_ai_credential(team_block, {
                "engine_slug": "anthropic",
                "account_id": "acct-x",
                "nickname": "X",
                "env_var_name": "TEAM_X_API_KEY",
            })
            self.assertIsInstance(team_block["ai"], dict, f"bogus_ai={bogus_ai!r}")
            self.assertEqual(team_block["ai"]["credential"]["account_id"], "acct-x")


class HandleTeamAccountAssignAiCredentialTests(_TeamPathsFixtureMixin, unittest.TestCase):
    """handle_team_account_assign() end-to-end through the real file, mocking
    only the Fleet Monitor registry lookup."""

    def _post(self, body_dict):
        body = json.dumps(body_dict).encode()
        return _make_handler(path="/api/team-config/account/assign", body=body)

    def _reg_data(self, auth_type=None):
        account = {
            "slug": "me-max",
            "account_id": "acct-me",
            "nickname": "ME (Max)",
            "env_var_name": "CLAUDE_ACCT_ME_TOKEN",
        }
        if auth_type is not None:
            account["auth_type"] = auth_type
        return {"engines": [{"slug": "anthropic", "accounts": [account]}]}

    def test_assign_writes_ai_credential_snapshot_and_legacy_projection(self):
        handler, buf = self._post({
            "team": TEST_TEAM,
            "engine_slug": "anthropic",
            "account_slug": "me-max",
        })

        with patch.object(LCARSHandler, "_get_engines_registry",
                           return_value=(self._reg_data(auth_type="oauth_token"), "live", 0, None)):
            handler.handle_team_account_assign()

        resp = _response_json(buf)
        self.assertTrue(resp["success"], resp)
        self.assertEqual(resp["mirrored"]["auth_type"], "oauth_token")

        on_disk = self._read_team_paths()
        team_block = on_disk["teams"][TEST_TEAM]
        self.assertEqual(team_block["ai"]["credential"], {
            "engine_slug": "anthropic",
            "account_slug": "me-max",
            "account_id": "acct-me",
            "nickname": "ME (Max)",
            "env_var_name": "CLAUDE_ACCT_ME_TOKEN",
            "auth_type": "oauth_token",
        })
        self.assertEqual(team_block["anthropic_account_id"], "acct-me")
        self.assertEqual(team_block["anthropic_account_nickname"], "ME (Max)")
        self.assertEqual(team_block["anthropic_api_key_env_var"], "CLAUDE_ACCT_ME_TOKEN")
        self.assertNotIn("anthropic_account_ref", team_block)

        # The sibling team's block must be untouched.
        self.assertEqual(on_disk["teams"]["unrelated-sibling-team"]["team_code"], "SIB")

    def test_assign_omits_auth_type_when_registry_account_has_none(self):
        handler, buf = self._post({
            "team": TEST_TEAM,
            "engine_slug": "anthropic",
            "account_slug": "me-max",
        })

        with patch.object(LCARSHandler, "_get_engines_registry",
                           return_value=(self._reg_data(auth_type=None), "live", 0, None)):
            handler.handle_team_account_assign()

        on_disk = self._read_team_paths()
        credential = on_disk["teams"][TEST_TEAM]["ai"]["credential"]
        self.assertNotIn("auth_type", credential)

    def test_assign_then_save_without_type_leaves_no_stale_auth_type(self):
        """XACA-0282-012 F5's failure mode, made concrete: assign an
        oauth_token account, then MANUAL-save without a type. No oauth_token
        may survive -- the whole-object replace (invariant I2) must drop it,
        not merge over it."""
        handler, buf = self._post({
            "team": TEST_TEAM,
            "engine_slug": "anthropic",
            "account_slug": "me-max",
        })
        with patch.object(LCARSHandler, "_get_engines_registry",
                           return_value=(self._reg_data(auth_type="oauth_token"), "live", 0, None)):
            handler.handle_team_account_assign()

        on_disk = self._read_team_paths()
        self.assertEqual(on_disk["teams"][TEST_TEAM]["ai"]["credential"]["auth_type"], "oauth_token")

        save_body = json.dumps({
            "team": TEST_TEAM,
            "account_id": "acct-console",
            "account_nickname": "Console key",
            "env_var_name": "TEAM_X1178_API_KEY",
            # auth_type deliberately omitted
        }).encode()
        save_handler, save_buf = _make_handler(path="/api/team-config/account/save", body=save_body)
        save_handler.handle_team_account_save()

        resp = _response_json(save_buf)
        self.assertTrue(resp["success"], resp)

        on_disk = self._read_team_paths()
        credential = on_disk["teams"][TEST_TEAM]["ai"]["credential"]
        self.assertNotIn("auth_type", credential)
        self.assertEqual(credential["account_id"], "acct-console")

    def test_assign_then_manual_save_round_trips_engine_and_account_slug(self):
        """XACA-1178-016: the manual edit modal has no engine_slug/account_slug
        field at all, so a save from it never sends either. Before this fix,
        handle_team_account_save() unconditionally defaulted engine_slug to
        'anthropic' and never wrote account_slug at all, so a plain nickname
        edit AFTER a registry assign silently reset engine_slug and dropped
        account_slug -- the same "two write paths disagreeing about one
        object" shape as the anthropic_account_ref staleness bug (F5), just
        moved onto ai.credential's own slugs. Both must now survive a manual
        save that doesn't touch them."""
        handler, buf = self._post({
            "team": TEST_TEAM,
            "engine_slug": "anthropic",
            "account_slug": "me-max",
        })
        with patch.object(LCARSHandler, "_get_engines_registry",
                           return_value=(self._reg_data(auth_type="oauth_token"), "live", 0, None)):
            handler.handle_team_account_assign()

        on_disk = self._read_team_paths()
        credential = on_disk["teams"][TEST_TEAM]["ai"]["credential"]
        self.assertEqual(credential["engine_slug"], "anthropic")
        self.assertEqual(credential["account_slug"], "me-max")

        # MANUAL save: only the nickname changes. No engine_slug/account_slug
        # in the body at all -- exactly what the real modal sends.
        save_body = json.dumps({
            "team": TEST_TEAM,
            "account_id": "acct-me",
            "account_nickname": "ME (Max) — renamed",
            "env_var_name": "CLAUDE_ACCT_ME_TOKEN",
            "auth_type": "oauth_token",
        }).encode()
        save_handler, save_buf = _make_handler(path="/api/team-config/account/save", body=save_body)
        save_handler.handle_team_account_save()

        resp = _response_json(save_buf)
        self.assertTrue(resp["success"], resp)

        on_disk = self._read_team_paths()
        credential = on_disk["teams"][TEST_TEAM]["ai"]["credential"]
        self.assertEqual(credential["engine_slug"], "anthropic",
                          "engine_slug must survive a manual save that doesn't edit it")
        self.assertEqual(credential["account_slug"], "me-max",
                          "account_slug must survive a manual save that doesn't edit it "
                          "-- the manual modal has no field for it at all")
        self.assertEqual(credential["nickname"], "ME (Max) — renamed")


class HandleTeamAccountSaveAiCredentialTests(_TeamPathsFixtureMixin, unittest.TestCase):

    def _save(self, body_dict):
        body = json.dumps(body_dict).encode()
        handler, buf = _make_handler(path="/api/team-config/account/save", body=body)
        handler.handle_team_account_save()
        return handler, buf

    def test_save_validates_and_writes_credential_and_projection(self):
        handler, buf = self._save({
            "team": TEST_TEAM,
            "account_id": "acct-console",
            "account_nickname": "Console Key",
            "env_var_name": "TEAM_X1178_API_KEY",
            "auth_type": "api_key",
        })

        resp = _response_json(buf)
        self.assertTrue(resp["success"], resp)
        self.assertEqual(resp["auth_type"], "api_key")

        on_disk = self._read_team_paths()
        credential = on_disk["teams"][TEST_TEAM]["ai"]["credential"]
        self.assertEqual(credential, {
            "engine_slug": "anthropic",
            "account_id": "acct-console",
            "nickname": "Console Key",
            "env_var_name": "TEAM_X1178_API_KEY",
            "auth_type": "api_key",
        })
        self.assertEqual(on_disk["teams"][TEST_TEAM]["anthropic_api_key_env_var"], "TEAM_X1178_API_KEY")

    def test_save_defaults_engine_slug_to_anthropic(self):
        self._save({
            "team": TEST_TEAM,
            "account_id": "acct-console",
            "account_nickname": "",
            "env_var_name": "",
        })
        on_disk = self._read_team_paths()
        self.assertEqual(on_disk["teams"][TEST_TEAM]["ai"]["credential"]["engine_slug"], "anthropic")

    def test_save_honors_explicit_engine_slug(self):
        self._save({
            "team": TEST_TEAM,
            "account_id": "org-example",
            "account_nickname": "Freelance OpenAI",
            "env_var_name": "OPENAI_KEY_FREELANCE",
            "engine_slug": "openai",
        })
        on_disk = self._read_team_paths()
        self.assertEqual(on_disk["teams"][TEST_TEAM]["ai"]["credential"]["engine_slug"], "openai")

    def test_all_empty_body_writes_null_credential(self):
        # Seed a pre-existing credential first so clearing is observable.
        self._save({
            "team": TEST_TEAM,
            "account_id": "acct-console",
            "account_nickname": "Console Key",
            "env_var_name": "TEAM_X1178_API_KEY",
            "auth_type": "api_key",
        })

        handler, buf = self._save({
            "team": TEST_TEAM,
            "account_id": "",
            "account_nickname": "",
            "env_var_name": "",
        })

        resp = _response_json(buf)
        self.assertTrue(resp["success"], resp)

        on_disk = self._read_team_paths()
        team_block = on_disk["teams"][TEST_TEAM]
        self.assertIsNone(team_block["ai"]["credential"])
        self.assertEqual(team_block["anthropic_account_id"], "")
        self.assertEqual(team_block["anthropic_account_nickname"], "")
        self.assertEqual(team_block["anthropic_api_key_env_var"], "")

    def test_invalid_auth_type_rejected_with_400(self):
        handler, buf = self._save({
            "team": TEST_TEAM,
            "account_id": "acct-console",
            "account_nickname": "Console Key",
            "env_var_name": "TEAM_X1178_API_KEY",
            "auth_type": "bogus",
        })

        self.assertEqual(handler._response_code, 400)
        resp = _response_json(buf)
        self.assertFalse(resp["success"])

        # Nothing must have been written on a rejected request.
        on_disk = self._read_team_paths()
        self.assertNotIn("ai", on_disk["teams"][TEST_TEAM])

    def test_save_explicit_account_slug_overrides_existing(self):
        """An explicit account_slug in the body (future API callers -- the
        current modal never sends one) still wins over whatever was there
        before; preservation only fills in what's OMITTED."""
        self._save({
            "team": TEST_TEAM,
            "account_id": "acct-console",
            "account_nickname": "Console Key",
            "env_var_name": "TEAM_X1178_API_KEY",
            "account_slug": "first-slug",
        })
        self._save({
            "team": TEST_TEAM,
            "account_id": "acct-console",
            "account_nickname": "Console Key",
            "env_var_name": "TEAM_X1178_API_KEY",
            "account_slug": "second-slug",
        })
        on_disk = self._read_team_paths()
        self.assertEqual(on_disk["teams"][TEST_TEAM]["ai"]["credential"]["account_slug"], "second-slug")

    def test_save_after_clear_does_not_resurrect_old_slugs(self):
        """Clearing to ai.credential = null (all-empty body) must not leave a
        later save's preservation logic reaching past the null and reviving a
        slug from before the clear."""
        self._save({
            "team": TEST_TEAM,
            "account_id": "acct-console",
            "account_nickname": "Console Key",
            "env_var_name": "TEAM_X1178_API_KEY",
            "account_slug": "old-slug",
            "engine_slug": "openai",
        })
        self._save({"team": TEST_TEAM, "account_id": "", "account_nickname": "", "env_var_name": ""})
        self._save({
            "team": TEST_TEAM,
            "account_id": "new-acct",
            "account_nickname": "New",
            "env_var_name": "TEAM_X1178_NEW_KEY",
        })
        on_disk = self._read_team_paths()
        credential = on_disk["teams"][TEST_TEAM]["ai"]["credential"]
        self.assertEqual(credential["engine_slug"], "anthropic")
        self.assertNotIn("account_slug", credential)

    def test_none_reserved_auth_type_rejected(self):
        """'none' is reserved for XACA-0283 (keyless endpoints) and is
        deliberately not accepted yet (XACA-0282-012 §2.2)."""
        handler, buf = self._save({
            "team": TEST_TEAM,
            "account_id": "acct-console",
            "account_nickname": "Console Key",
            "env_var_name": "TEAM_X1178_API_KEY",
            "auth_type": "none",
        })
        self.assertEqual(handler._response_code, 400)

    def test_non_dict_ai_block_on_disk_does_not_crash_save(self):
        """XACA-1178-017 end-to-end: a non-dict 'ai' key on disk must not make
        a manual save 500 -- _set_team_ai_credential's coercion plus this
        handler's own defensive read of the existing credential
        (XACA-1178-016) must both survive it."""
        data = self._read_team_paths()
        data["teams"][TEST_TEAM]["ai"] = "not-a-dict-either"
        self._write_team_paths(data)
        with LCARSHandler._TEAM_PATHS_CACHE_LOCK:
            LCARSHandler._TEAM_PATHS_CACHE = {"mtime_ns": None, "data": None}

        handler, buf = self._save({
            "team": TEST_TEAM,
            "account_id": "acct-recovered",
            "account_nickname": "Recovered",
            "env_var_name": "TEAM_X1178_API_KEY",
        })
        self.assertNotEqual(handler._response_code, 500)
        resp = _response_json(buf)
        self.assertTrue(resp["success"], resp)

        on_disk = self._read_team_paths()
        self.assertEqual(on_disk["teams"][TEST_TEAM]["ai"]["credential"]["account_id"], "acct-recovered")


class ServeTeamAccountCurrentAiCredentialTests(_TeamPathsFixtureMixin, unittest.TestCase):

    def _get(self, team=TEST_TEAM):
        handler, buf = _make_handler(
            path=f"/api/team-config/account/current?team={team}", method="GET"
        )
        handler.serve_team_account_current(f"team={team}")
        return handler, buf

    def test_current_returns_ai_shape_after_save(self):
        save_handler, _ = _make_handler(
            path="/api/team-config/account/save",
            body=json.dumps({
                "team": TEST_TEAM,
                "account_id": "acct-console",
                "account_nickname": "Console Key",
                "env_var_name": "TEAM_X1178_API_KEY",
                "auth_type": "api_key",
                "engine_slug": "anthropic",
            }).encode(),
        )
        save_handler.handle_team_account_save()

        _, buf = self._get()
        resp = _response_json(buf)

        self.assertEqual(resp["config_source"], "ai")
        self.assertEqual(resp["account_id"], "acct-console")
        self.assertEqual(resp["account_nickname"], "Console Key")
        self.assertEqual(resp["env_var_name"], "TEAM_X1178_API_KEY")
        self.assertEqual(resp["auth_type"], "api_key")
        self.assertEqual(resp["engine_slug"], "anthropic")

    def test_team_with_no_ai_key_reads_as_legacy_without_crashing(self):
        """Every team today (27 of 27 per the decision doc's F1) has no 'ai'
        block at all. current() must read that team without crashing and
        report config_source: legacy."""
        data = self._read_team_paths()
        data["teams"][TEST_TEAM]["anthropic_account_id"] = "legacy-acct"
        data["teams"][TEST_TEAM]["anthropic_account_nickname"] = "Legacy Nick"
        data["teams"][TEST_TEAM]["anthropic_api_key_env_var"] = "TEAM_X1178_API_KEY"
        self._write_team_paths(data)
        with LCARSHandler._TEAM_PATHS_CACHE_LOCK:
            LCARSHandler._TEAM_PATHS_CACHE = {"mtime_ns": None, "data": None}

        _, buf = self._get()
        resp = _response_json(buf)

        self.assertEqual(resp["config_source"], "legacy")
        self.assertEqual(resp["account_id"], "legacy-acct")
        self.assertEqual(resp["account_nickname"], "Legacy Nick")
        self.assertEqual(resp["env_var_name"], "TEAM_X1178_API_KEY")
        self.assertEqual(resp["auth_type"], "")
        self.assertEqual(resp["engine_slug"], "")
        self.assertEqual(resp["account_slug"], "")

    def test_explicit_null_credential_reads_as_ai_source_with_empty_fields(self):
        data = self._read_team_paths()
        data["teams"][TEST_TEAM]["ai"] = {"credential": None}
        self._write_team_paths(data)
        with LCARSHandler._TEAM_PATHS_CACHE_LOCK:
            LCARSHandler._TEAM_PATHS_CACHE = {"mtime_ns": None, "data": None}

        _, buf = self._get()
        resp = _response_json(buf)

        self.assertEqual(resp["config_source"], "ai")
        self.assertEqual(resp["account_id"], "")
        self.assertFalse(resp["has_credentials"])

    def test_team_missing_entirely_from_registry_returns_400(self):
        _, buf = self._get(team="no-such-team-at-all")
        resp = _response_json(buf)
        self.assertIn("error", resp)

    def test_non_dict_credential_value_does_not_crash(self):
        """XACA-1178-017: teams.<t>.ai is a dict with a 'credential' key, but
        the value under it is a stray string (hand-edited file, a botched
        migration) instead of a dict. credential.get(...) on a str/list/int
        raises AttributeError -- must coerce to {} instead of 500ing."""
        data = self._read_team_paths()
        for bogus_credential in ("not-a-dict", ["also", "not"], 7):
            data["teams"][TEST_TEAM]["ai"] = {"credential": bogus_credential}
            self._write_team_paths(data)
            with LCARSHandler._TEAM_PATHS_CACHE_LOCK:
                LCARSHandler._TEAM_PATHS_CACHE = {"mtime_ns": None, "data": None}

            handler, buf = self._get()
            self.assertNotEqual(handler._response_code, 500, f"bogus_credential={bogus_credential!r}")
            resp = _response_json(buf)
            self.assertEqual(resp["config_source"], "ai")
            self.assertEqual(resp["account_id"], "")
            self.assertFalse(resp["has_credentials"])


if __name__ == "__main__":
    unittest.main()
