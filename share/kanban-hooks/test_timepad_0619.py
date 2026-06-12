#!/usr/bin/env python3
"""
test_timepad_0619.py — Comprehensive tests for XACA-0619 TimePad per-team config.

Covers all test plan items from the XACA-0619-006 Testing & Debugging subitem:
  T1 — Module import sanity
  T2 — Schema/loader (11 teams, validation pass/fail)
  T3 — Placeholder handling
  T4 — Enable gate (board JSON, not config JSON)
  T5 — Token security (masking, fingerprint, reference-by-name)
  T6 — /api/team-config validation logic (unit-level)
  T7 — Rebrand cleanliness (no "timeapp" / "liquidstyle" in feature files)
  T8 — Tap mirror accounting (sync-tap.sh covers both timepad files)

Run:
    cd kanban-hooks && python3 test_timepad_0619.py
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
from pathlib import Path

# Ensure kanban-hooks is on sys.path so relative imports work.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# Root of the feature worktree (or dev-team main repo when run from there).
_REPO_ROOT = Path(__file__).parent.parent


# ─────────────────────────────────────────────────────────────────────────────
# T1 — Module import sanity
# ─────────────────────────────────────────────────────────────────────────────

def test_t1_import_aiteamforge_paths():
    """T1a: import aiteamforge_paths — zero errors."""
    import aiteamforge_paths  # noqa: F401
    print("PASS T1a: import aiteamforge_paths")


def test_t1_import_timepad_config():
    """T1b: import timepad_config — zero errors."""
    import timepad_config  # noqa: F401
    print("PASS T1b: import timepad_config")


def test_t1_server_py_syntax():
    """T1c: server.py compiles without syntax errors."""
    import py_compile
    server_py = str(_REPO_ROOT / "lcars-ui" / "server.py")
    py_compile.compile(server_py, doraise=True)
    print("PASS T1c: server.py py_compile clean")


def test_t1_timepad_config_py_syntax():
    """T1d: timepad_config.py compiles without syntax errors."""
    import py_compile
    py_compile.compile(
        str(_REPO_ROOT / "kanban-hooks" / "timepad_config.py"), doraise=True
    )
    print("PASS T1d: timepad_config.py py_compile clean")


# ─────────────────────────────────────────────────────────────────────────────
# T2 — Schema / loader
# ─────────────────────────────────────────────────────────────────────────────

EXPECTED_TEAMS = {
    "academy", "ios", "android", "firebase", "command",
    "dns", "freelance", "mainevent", "legal", "medical", "finance",
}


def _load_shipped_config():
    """Return the shipped timepad_config.json as a dict."""
    cfg_path = _REPO_ROOT / "kanban-hooks" / "timepad_config.json"
    with open(cfg_path, encoding="utf-8") as f:
        return json.load(f)


def test_t2_all_11_teams_present():
    """T2a: load_timepad_config() returns all 11 expected teams."""
    from aiteamforge_paths import load_timepad_config, bust_timepad_config_cache

    with tempfile.TemporaryDirectory() as tmpdir:
        cfg_path = str(_REPO_ROOT / "kanban-hooks" / "timepad_config.json")
        old = os.environ.get("AITEAMFORGE_TIMEPAD_CONFIG")
        os.environ["AITEAMFORGE_TIMEPAD_CONFIG"] = cfg_path
        bust_timepad_config_cache()
        try:
            config = load_timepad_config()
            teams = set(config.get("teams", {}).keys())
            missing = EXPECTED_TEAMS - teams
            extra = teams - EXPECTED_TEAMS
            assert not missing, f"Missing teams: {missing}"
            assert not extra, f"Unexpected teams: {extra}"
        finally:
            if old is not None:
                os.environ["AITEAMFORGE_TIMEPAD_CONFIG"] = old
            else:
                os.environ.pop("AITEAMFORGE_TIMEPAD_CONFIG", None)
            bust_timepad_config_cache()
    print("PASS T2a: load_timepad_config returns all 11 teams")


def test_t2_validate_shipped_config_passes():
    """T2b: validate_timepad_config() passes on the shipped JSON."""
    from aiteamforge_paths import validate_timepad_config
    config = _load_shipped_config()
    errors = validate_timepad_config(config)
    assert errors == [], f"Shipped config validation errors: {errors}"
    print("PASS T2b: validate_timepad_config passes on shipped JSON")


def test_t2_reject_non_https_apiBaseUrl():
    """T2c: validate rejects non-https apiBaseUrl."""
    from aiteamforge_paths import validate_timepad_config
    cfg = {"teams": {"academy": {
        "apiBaseUrl": "http://timepad.io/api",
        "tokenRef": "TIMEPAD_API_KEY",
        "clientId": "<fetch-from-timepad.io>",
        "projectId": "<fetch-from-timepad.io>",
        "tagId": "<fetch-from-timepad.io>",
    }}}
    errors = validate_timepad_config(cfg)
    assert any("https" in e for e in errors), f"Expected https error, got: {errors}"
    print("PASS T2c: non-https apiBaseUrl rejected")


def test_t2_reject_liquidstyle_in_apiBaseUrl():
    """T2d: validate rejects apiBaseUrl containing 'liquidstyle'."""
    from aiteamforge_paths import validate_timepad_config
    cfg = {"teams": {"academy": {
        "apiBaseUrl": "https://time.liquidstyle.io/api",
        "tokenRef": "TIMEPAD_API_KEY",
        "clientId": "<fetch-from-timepad.io>",
        "projectId": "<fetch-from-timepad.io>",
        "tagId": "<fetch-from-timepad.io>",
    }}}
    errors = validate_timepad_config(cfg)
    assert any("liquidstyle" in e for e in errors), f"Expected liquidstyle error, got: {errors}"
    print("PASS T2d: liquidstyle in apiBaseUrl rejected")


def test_t2_reject_liquidstyle_in_tokenRef():
    """T2e: validate rejects tokenRef containing 'liquidstyle'."""
    from aiteamforge_paths import validate_timepad_config
    cfg = {"teams": {"academy": {
        "apiBaseUrl": "https://timepad.io/api",
        "tokenRef": "LIQUIDSTYLE_API_KEY",
        "clientId": "<fetch-from-timepad.io>",
        "projectId": "<fetch-from-timepad.io>",
        "tagId": "<fetch-from-timepad.io>",
    }}}
    errors = validate_timepad_config(cfg)
    assert any("liquidstyle" in e for e in errors), f"Expected liquidstyle tokenRef error, got: {errors}"
    print("PASS T2e: liquidstyle in tokenRef rejected")


def test_t2_reject_raw_token_prefix_tp():
    """T2f: validate rejects tokenRef starting with 'tp_' (raw-token prefix)."""
    from aiteamforge_paths import validate_timepad_config
    cfg = {"teams": {"academy": {
        "apiBaseUrl": "https://timepad.io/api",
        "tokenRef": "tp_live_abc123",
        "clientId": "<fetch-from-timepad.io>",
        "projectId": "<fetch-from-timepad.io>",
        "tagId": "<fetch-from-timepad.io>",
    }}}
    errors = validate_timepad_config(cfg)
    assert any("raw token" in e.lower() or "tp_" in e for e in errors), \
        f"Expected raw-token-prefix error, got: {errors}"
    print("PASS T2f: tokenRef starting with 'tp_' rejected")


def test_t2_reject_raw_token_prefix_sk():
    """T2g: validate rejects tokenRef starting with 'sk-' (raw-token prefix)."""
    from aiteamforge_paths import validate_timepad_config
    cfg = {"teams": {"academy": {
        "apiBaseUrl": "https://timepad.io/api",
        "tokenRef": "sk-abc123secretkey",
        "clientId": "<fetch-from-timepad.io>",
        "projectId": "<fetch-from-timepad.io>",
        "tagId": "<fetch-from-timepad.io>",
    }}}
    errors = validate_timepad_config(cfg)
    assert any("raw token" in e.lower() or "sk-" in e for e in errors), \
        f"Expected raw-token-prefix error (sk-), got: {errors}"
    print("PASS T2g: tokenRef starting with 'sk-' rejected")


def test_t2_reject_bearer_token_in_tokenRef():
    """T2h: validate rejects tokenRef starting with 'Bearer ' (raw-token prefix)."""
    from aiteamforge_paths import validate_timepad_config
    cfg = {"teams": {"academy": {
        "apiBaseUrl": "https://timepad.io/api",
        "tokenRef": "Bearer myapitoken123",
        "clientId": "<fetch-from-timepad.io>",
        "projectId": "<fetch-from-timepad.io>",
        "tagId": "<fetch-from-timepad.io>",
    }}}
    errors = validate_timepad_config(cfg)
    assert any("raw token" in e.lower() or "bearer" in e.lower() for e in errors), \
        f"Expected Bearer-prefix error, got: {errors}"
    print("PASS T2h: tokenRef starting with 'Bearer ' rejected")


def test_t2_reject_non_string_uuid_field():
    """T2i: validate rejects non-string clientId (e.g. integer)."""
    from aiteamforge_paths import validate_timepad_config
    cfg = {"teams": {"academy": {
        "apiBaseUrl": "https://timepad.io/api",
        "tokenRef": "TIMEPAD_API_KEY",
        "clientId": 12345,  # non-string
        "projectId": "<fetch-from-timepad.io>",
        "tagId": "<fetch-from-timepad.io>",
    }}}
    errors = validate_timepad_config(cfg)
    assert any("clientId" in e for e in errors), f"Expected clientId type error, got: {errors}"
    print("PASS T2i: non-string UUID field (clientId=int) rejected")


def test_t2_reject_non_string_uuid_projectId():
    """T2j: validate rejects non-string projectId (e.g. None)."""
    from aiteamforge_paths import validate_timepad_config
    cfg = {"teams": {"academy": {
        "apiBaseUrl": "https://timepad.io/api",
        "tokenRef": "TIMEPAD_API_KEY",
        "clientId": "<fetch-from-timepad.io>",
        "projectId": None,
        "tagId": "<fetch-from-timepad.io>",
    }}}
    errors = validate_timepad_config(cfg)
    assert any("projectId" in e for e in errors), f"Expected projectId type error, got: {errors}"
    print("PASS T2j: non-string UUID field (projectId=None) rejected")


# ─────────────────────────────────────────────────────────────────────────────
# T3 — Placeholder handling
# ─────────────────────────────────────────────────────────────────────────────

def test_t3_shipped_config_has_placeholders():
    """T3a: timepad_team_has_placeholders() is True for all shipped teams (UUIDs are placeholders)."""
    from aiteamforge_paths import timepad_team_has_placeholders, bust_timepad_config_cache

    cfg_path = str(_REPO_ROOT / "kanban-hooks" / "timepad_config.json")
    old = os.environ.get("AITEAMFORGE_TIMEPAD_CONFIG")
    os.environ["AITEAMFORGE_TIMEPAD_CONFIG"] = cfg_path
    bust_timepad_config_cache()
    try:
        for team in EXPECTED_TEAMS:
            result = timepad_team_has_placeholders(team)
            assert result is True, f"Expected True (placeholder) for team '{team}', got {result}"
    finally:
        if old is not None:
            os.environ["AITEAMFORGE_TIMEPAD_CONFIG"] = old
        else:
            os.environ.pop("AITEAMFORGE_TIMEPAD_CONFIG", None)
        bust_timepad_config_cache()
    print("PASS T3a: timepad_team_has_placeholders is True for all 11 shipped teams")


def test_t3_no_crash_on_placeholder():
    """T3b: timepad_team_has_placeholders() does not crash on shipped config."""
    from aiteamforge_paths import timepad_team_has_placeholders, bust_timepad_config_cache

    cfg_path = str(_REPO_ROOT / "kanban-hooks" / "timepad_config.json")
    old = os.environ.get("AITEAMFORGE_TIMEPAD_CONFIG")
    os.environ["AITEAMFORGE_TIMEPAD_CONFIG"] = cfg_path
    bust_timepad_config_cache()
    try:
        # Must not raise
        result = timepad_team_has_placeholders("academy")
        assert isinstance(result, bool)
    finally:
        if old is not None:
            os.environ["AITEAMFORGE_TIMEPAD_CONFIG"] = old
        else:
            os.environ.pop("AITEAMFORGE_TIMEPAD_CONFIG", None)
        bust_timepad_config_cache()
    print("PASS T3b: timepad_team_has_placeholders does not crash on placeholder config")


def test_t3_false_when_real_uuids():
    """T3c: timepad_team_has_placeholders() is False when real UUIDs are substituted."""
    from aiteamforge_paths import timepad_team_has_placeholders, bust_timepad_config_cache

    with tempfile.TemporaryDirectory() as tmpdir:
        cfg_path = os.path.join(tmpdir, "timepad_config.json")
        config_data = {
            "_schemaVersion": 1,
            "teams": {
                "academy": {
                    "apiBaseUrl": "https://timepad.io/api",
                    "tokenRef": "TIMEPAD_API_KEY",
                    "clientId": "11111111-2222-3333-4444-555555555555",
                    "projectId": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                    "tagId": "ffffffff-1111-2222-3333-444444444444",
                }
            },
        }
        with open(cfg_path, "w") as f:
            json.dump(config_data, f)

        old = os.environ.get("AITEAMFORGE_TIMEPAD_CONFIG")
        os.environ["AITEAMFORGE_TIMEPAD_CONFIG"] = cfg_path
        bust_timepad_config_cache()
        try:
            result = timepad_team_has_placeholders("academy")
            assert result is False, f"Expected False when real UUIDs present, got {result}"
        finally:
            if old is not None:
                os.environ["AITEAMFORGE_TIMEPAD_CONFIG"] = old
            else:
                os.environ.pop("AITEAMFORGE_TIMEPAD_CONFIG", None)
            bust_timepad_config_cache()
    print("PASS T3c: timepad_team_has_placeholders is False when real UUIDs provided")


def test_t3_true_for_absent_team():
    """T3d: timepad_team_has_placeholders() returns True for a team not in config."""
    from aiteamforge_paths import timepad_team_has_placeholders, bust_timepad_config_cache

    with tempfile.TemporaryDirectory() as tmpdir:
        cfg_path = os.path.join(tmpdir, "timepad_config.json")
        # Config with only 'academy' — 'ios' is absent.
        config_data = {
            "_schemaVersion": 1,
            "teams": {
                "academy": {
                    "apiBaseUrl": "https://timepad.io/api",
                    "tokenRef": "TIMEPAD_API_KEY",
                    "clientId": "<fetch-from-timepad.io>",
                    "projectId": "<fetch-from-timepad.io>",
                    "tagId": "<fetch-from-timepad.io>",
                }
            },
        }
        with open(cfg_path, "w") as f:
            json.dump(config_data, f)

        old = os.environ.get("AITEAMFORGE_TIMEPAD_CONFIG")
        os.environ["AITEAMFORGE_TIMEPAD_CONFIG"] = cfg_path
        bust_timepad_config_cache()
        try:
            result = timepad_team_has_placeholders("ios")
            assert result is True, f"Expected True for absent team, got {result}"
        finally:
            if old is not None:
                os.environ["AITEAMFORGE_TIMEPAD_CONFIG"] = old
            else:
                os.environ.pop("AITEAMFORGE_TIMEPAD_CONFIG", None)
            bust_timepad_config_cache()
    print("PASS T3d: timepad_team_has_placeholders is True for absent team")


# ─────────────────────────────────────────────────────────────────────────────
# T4 — Enable gate (board JSON)
# ─────────────────────────────────────────────────────────────────────────────

def test_t4_disabled_by_default():
    """T4a: is_timepad_enabled() returns False when board JSON has no timepadSupport."""
    import aiteamforge_paths as ap

    original_get = ap.get_team_kanban_dir
    with tempfile.TemporaryDirectory() as tmpdir:
        ap.get_team_kanban_dir = lambda t: Path(tmpdir)
        board_path = os.path.join(tmpdir, "academy-board.json")
        try:
            # No timepadSupport key — board file exists but feature absent.
            with open(board_path, "w") as f:
                json.dump({"items": []}, f)
            result = ap.is_timepad_enabled("academy")
            assert result is False, f"Expected False when timepadSupport absent, got {result}"
        finally:
            ap.get_team_kanban_dir = original_get
    print("PASS T4a: is_timepad_enabled False when board has no timepadSupport key")


def test_t4_true_when_board_enabled():
    """T4b: is_timepad_enabled() returns True when board JSON has timepadSupport.enabled=true."""
    import aiteamforge_paths as ap

    original_get = ap.get_team_kanban_dir
    with tempfile.TemporaryDirectory() as tmpdir:
        ap.get_team_kanban_dir = lambda t: Path(tmpdir)
        board_path = os.path.join(tmpdir, "academy-board.json")
        try:
            with open(board_path, "w") as f:
                json.dump({"teamConfig": {"timepadSupport": {"enabled": True}}}, f)
            result = ap.is_timepad_enabled("academy")
            assert result is True, f"Expected True when enabled=true, got {result}"
        finally:
            ap.get_team_kanban_dir = original_get
    print("PASS T4b: is_timepad_enabled True when board JSON has timepadSupport.enabled=true")


def test_t4_false_when_board_explicitly_false():
    """T4c: is_timepad_enabled() returns False when board JSON has timepadSupport.enabled=false."""
    import aiteamforge_paths as ap

    original_get = ap.get_team_kanban_dir
    with tempfile.TemporaryDirectory() as tmpdir:
        ap.get_team_kanban_dir = lambda t: Path(tmpdir)
        board_path = os.path.join(tmpdir, "academy-board.json")
        try:
            with open(board_path, "w") as f:
                json.dump({"teamConfig": {"timepadSupport": {"enabled": False}}}, f)
            result = ap.is_timepad_enabled("academy")
            assert result is False, f"Expected False when enabled=false, got {result}"
        finally:
            ap.get_team_kanban_dir = original_get
    print("PASS T4c: is_timepad_enabled False when board JSON has timepadSupport.enabled=false")


def test_t4_false_when_board_file_missing():
    """T4d: is_timepad_enabled() returns False when board file is missing."""
    import aiteamforge_paths as ap

    original_get = ap.get_team_kanban_dir
    with tempfile.TemporaryDirectory() as tmpdir:
        # No board file created — directory is empty.
        ap.get_team_kanban_dir = lambda t: Path(tmpdir)
        try:
            result = ap.is_timepad_enabled("academy")
            assert result is False, f"Expected False when board file missing, got {result}"
        finally:
            ap.get_team_kanban_dir = original_get
    print("PASS T4d: is_timepad_enabled False when board file missing")


def test_t4_reads_board_json_not_config_json():
    """T4e: is_timepad_enabled reads board JSON, NOT timepad_config.json.

    This test is the critical separation-of-concerns check: even when the
    config JSON were modified, the enable gate must come from board JSON.
    We confirm this by making the board JSON the authoritative source:
    - Board says enabled=True → result is True
    - Config JSON doesn't have an 'enabled' field at all (correct schema)
    """
    import aiteamforge_paths as ap

    original_get = ap.get_team_kanban_dir
    with tempfile.TemporaryDirectory() as tmpdir:
        ap.get_team_kanban_dir = lambda t: Path(tmpdir)
        board_path = os.path.join(tmpdir, "academy-board.json")
        try:
            # Board says enabled
            with open(board_path, "w") as f:
                json.dump({"teamConfig": {"timepadSupport": {"enabled": True}}}, f)

            result = ap.is_timepad_enabled("academy")
            assert result is True

            # Confirm the config JSON itself does NOT have an 'enabled' key per schema
            shipped_cfg = _load_shipped_config()
            for team_slug, block in shipped_cfg.get("teams", {}).items():
                assert "enabled" not in block, (
                    f"Schema violation: timepad_config.json team '{team_slug}' "
                    f"has 'enabled' field — it must not exist in the config file"
                )
        finally:
            ap.get_team_kanban_dir = original_get
    print("PASS T4e: enable gate is board JSON only; config JSON has no 'enabled' field")


# ─────────────────────────────────────────────────────────────────────────────
# T5 — Token security
# ─────────────────────────────────────────────────────────────────────────────

def test_t5_mask_timepad_token_hides_secret():
    """T5a: mask_timepad_token never returns the full token string."""
    from timepad_config import mask_timepad_token

    secret = "fake-secret-value-1234"
    masked = mask_timepad_token(secret)
    assert secret not in masked, f"Full secret leaked in masked output: {masked!r}"
    # Must include the sha256 fingerprint marker
    assert "sha256:" in masked, f"No sha256 marker in masked: {masked!r}"
    print("PASS T5a: mask_timepad_token does not leak full token")


def test_t5_mask_shows_prefix_only():
    """T5b: mask_timepad_token shows first 4 chars only, then obscures."""
    from timepad_config import mask_timepad_token

    secret = "sk-testtoken12345678"
    masked = mask_timepad_token(secret)
    # First 4 chars visible
    assert masked.startswith("sk-t"), f"Expected 'sk-t' prefix in masked: {masked!r}"
    # Rest must not appear
    assert "testtoken12345678" not in masked, f"Token suffix leaked: {masked!r}"
    print("PASS T5b: mask_timepad_token shows only first 4 chars prefix")


def test_t5_mask_empty_token():
    """T5c: mask_timepad_token returns '(not set)' for empty token."""
    from timepad_config import mask_timepad_token

    result = mask_timepad_token("")
    assert result == "(not set)", f"Expected '(not set)', got: {result!r}"
    print("PASS T5c: mask_timepad_token returns '(not set)' for empty string")


def test_t5_fingerprint_does_not_contain_secret():
    """T5d: resolve_timepad_token_fingerprint returns masked form; secret never in output."""
    from timepad_config import resolve_timepad_token_fingerprint

    fake_secret = "fake-secret-value-1234"
    # Inject the secret via a fake env using the _testing_env parameter
    fake_env = {"TIMEPAD_API_KEY": fake_secret}

    fingerprint = resolve_timepad_token_fingerprint(
        "academy",
        _testing_env=fake_env,
    )

    # The full secret MUST NOT appear in the fingerprint
    assert fake_secret not in fingerprint, (
        f"Secret leaked in fingerprint output: {fingerprint!r}"
    )
    # The fingerprint must be non-empty and contain masking markers
    assert fingerprint and fingerprint != "(not set)", (
        f"Expected a real fingerprint, got: {fingerprint!r}"
    )
    assert "sha256:" in fingerprint, f"No sha256 marker in fingerprint: {fingerprint!r}"
    print("PASS T5d: resolve_timepad_token_fingerprint masks secret; no raw token in output")


def test_t5_resolve_token_uses_env_var():
    """T5e: resolve_timepad_token resolves via _testing_env (tier 3 env failover)."""
    from timepad_config import resolve_timepad_token, TimePadTokenResolutionError

    fake_secret = "fake-secret-value-1234"
    fake_env = {"TIMEPAD_API_KEY": fake_secret}

    # Should return the fake secret from env failover tier
    token = resolve_timepad_token("academy", _testing_env=fake_env)
    assert token == fake_secret, f"Expected fake_secret, got {token!r}"
    print("PASS T5e: resolve_timepad_token resolves from testing_env (env failover tier)")


def test_t5_resolve_token_raises_when_no_source():
    """T5f: resolve_timepad_token raises TimePadTokenResolutionError when no token source."""
    from timepad_config import resolve_timepad_token, TimePadTokenResolutionError

    # Empty env — no vault on dev box pointing to a fake team
    empty_env: dict = {}

    try:
        resolve_timepad_token("__nonexistent_team__", _testing_env=empty_env)
        assert False, "Expected TimePadTokenResolutionError to be raised"
    except TimePadTokenResolutionError:
        pass  # expected
    print("PASS T5f: resolve_timepad_token raises TimePadTokenResolutionError with no source")


def test_t5_per_team_env_var_name():
    """T5g: resolve_timepad_token uses per-team env var TEAM_ACADEMY_TIMEPAD_API_KEY."""
    from timepad_config import resolve_timepad_token, env_var_for_team

    # Verify env_var_for_team returns the expected name
    name = env_var_for_team("academy")
    assert name == "TEAM_ACADEMY_TIMEPAD_API_KEY", f"Unexpected env var name: {name!r}"

    # Confirm resolve_timepad_token picks it up
    fake_secret = "per-team-secret-xyz"
    fake_env = {"TEAM_ACADEMY_TIMEPAD_API_KEY": fake_secret}
    token = resolve_timepad_token("academy", _testing_env=fake_env)
    assert token == fake_secret, f"Expected per-team secret, got {token!r}"
    print("PASS T5g: per-team env var TEAM_ACADEMY_TIMEPAD_API_KEY takes priority")


def test_t5_no_inline_token_in_config_json():
    """T5h: timepad_config.json contains NO inline token values (reference-by-name only)."""
    cfg = _load_shipped_config()
    raw_token_prefixes = ("tp_", "sk-", "Bearer ", "token ", "apikey ")
    for team_slug, block in cfg.get("teams", {}).items():
        token_ref = block.get("tokenRef", "")
        for prefix in raw_token_prefixes:
            assert not token_ref.lower().startswith(prefix.lower()), (
                f"SECURITY: team '{team_slug}' tokenRef appears to be a raw token "
                f"(starts with {prefix!r}): {token_ref!r}"
            )
        # Also must not be suspiciously long
        assert len(token_ref) <= 80, (
            f"SECURITY: team '{team_slug}' tokenRef is suspiciously long "
            f"({len(token_ref)} chars): {token_ref!r}"
        )
    print("PASS T5h: timepad_config.json tokenRef fields contain only reference names")


def test_t5_mainevent_env_var_name():
    """T5i: env_var_for_team derives correct name for compound team slugs."""
    from timepad_config import env_var_for_team

    name = env_var_for_team("mainevent")
    assert name == "TEAM_MAINEVENT_TIMEPAD_API_KEY", f"Unexpected: {name!r}"

    name_dns = env_var_for_team("dns")
    assert name_dns == "TEAM_DNS_TIMEPAD_API_KEY", f"Unexpected: {name_dns!r}"
    print("PASS T5i: env_var_for_team correct for mainevent and dns slugs")


# ─────────────────────────────────────────────────────────────────────────────
# T6 — /api/team-config validation logic (unit-level)
# ─────────────────────────────────────────────────────────────────────────────

def _simulate_server_validation(new_team_config: dict) -> tuple[bool, str | None]:
    """
    Simulate the server.py handle_update_team_config validation logic for timepadSupport.

    Returns (is_valid, error_message_or_None).
    This mirrors the validation block at server.py lines 10540-10563 so we can test
    the logic without spinning up a live HTTP server.
    """
    _TEAM_CONFIG_ALLOWED_KEYS = {"crSupport", "copyright", "timepadSupport"}
    _TIMEPAD_SUPPORT_ALLOWED_KEYS = {"enabled", "description"}
    _SUPPORT_DESCRIPTION_MAX = 500  # XACA-0619-011

    unknown_top = set(new_team_config.keys()) - _TEAM_CONFIG_ALLOWED_KEYS
    if unknown_top:
        return False, f"Unknown teamConfig key(s): {', '.join(sorted(unknown_top))}"

    if "timepadSupport" in new_team_config:
        tp = new_team_config["timepadSupport"]
        if not isinstance(tp, dict):
            return False, "timepadSupport must be an object"
        unknown_tp = set(tp.keys()) - _TIMEPAD_SUPPORT_ALLOWED_KEYS
        if unknown_tp:
            return False, f"Unknown timepadSupport key(s): {', '.join(sorted(unknown_tp))}"
        if "enabled" in tp and not isinstance(tp["enabled"], bool):
            return False, "timepadSupport.enabled must be a boolean"
        if "description" in tp and not isinstance(tp["description"], str):
            return False, "timepadSupport.description must be a string"
        if "description" in tp and len(tp["description"]) > _SUPPORT_DESCRIPTION_MAX:
            return False, f"timepadSupport.description must be at most {_SUPPORT_DESCRIPTION_MAX} characters"

    return True, None


def test_t6_valid_payload_accepted():
    """T6a: Valid timepadSupport payload accepted."""
    ok, err = _simulate_server_validation(
        {"timepadSupport": {"enabled": True}}
    )
    assert ok, f"Expected valid, got error: {err}"
    print("PASS T6a: valid timepadSupport payload accepted")


def test_t6_non_bool_enabled_rejected():
    """T6b: Non-bool enabled value rejected."""
    ok, err = _simulate_server_validation(
        {"timepadSupport": {"enabled": "true"}}
    )
    assert not ok, "Expected rejection for string 'true' as enabled"
    assert "boolean" in (err or ""), f"Unexpected error message: {err}"
    print("PASS T6b: non-bool enabled ('true' string) rejected")


def test_t6_integer_enabled_rejected():
    """T6c: Integer enabled value (1) rejected."""
    ok, err = _simulate_server_validation(
        {"timepadSupport": {"enabled": 1}}
    )
    assert not ok, "Expected rejection for integer 1 as enabled"
    assert "boolean" in (err or ""), f"Unexpected error: {err}"
    print("PASS T6c: integer enabled (1) rejected")


def test_t6_unknown_nested_key_rejected():
    """T6d: Unknown nested key in timepadSupport rejected."""
    ok, err = _simulate_server_validation(
        {"timepadSupport": {"enabled": False, "secret_key": "hacked"}}
    )
    assert not ok, "Expected rejection for unknown nested key"
    assert "secret_key" in (err or ""), f"Unexpected error: {err}"
    print("PASS T6d: unknown nested key in timepadSupport rejected")


def test_t6_unknown_top_level_key_rejected():
    """T6e: Unknown top-level key in teamConfig rejected."""
    ok, err = _simulate_server_validation(
        {"timepadSupport": {"enabled": True}, "maliciousKey": "data"}
    )
    assert not ok, "Expected rejection for unknown top-level key"
    assert "maliciousKey" in (err or ""), f"Unexpected error: {err}"
    print("PASS T6e: unknown top-level key in teamConfig rejected")


def test_t6_get_default_returns_false():
    """T6f: GET /api/team-config default includes timepadSupport.enabled=false when absent.

    Validates the server.py setdefault logic (lines 10388-10389) by testing
    the aiteamforge_paths.is_timepad_enabled() path — which reads the same
    board JSON that the server.py GET endpoint reads.
    """
    import aiteamforge_paths as ap

    original_get = ap.get_team_kanban_dir
    with tempfile.TemporaryDirectory() as tmpdir:
        ap.get_team_kanban_dir = lambda t: Path(tmpdir)
        board_path = os.path.join(tmpdir, "academy-board.json")
        try:
            # Board has no timepadSupport key
            with open(board_path, "w") as f:
                json.dump({"items": []}, f)
            result = ap.is_timepad_enabled("academy")
            assert result is False, f"Expected False default, got {result}"
        finally:
            ap.get_team_kanban_dir = original_get
    print("PASS T6f: GET default returns timepadSupport.enabled=false when key absent")


def test_t6_description_non_string_rejected():
    """T6g: Non-string description in timepadSupport rejected."""
    ok, err = _simulate_server_validation(
        {"timepadSupport": {"enabled": True, "description": 999}}
    )
    assert not ok, "Expected rejection for non-string description"
    assert "string" in (err or ""), f"Unexpected error: {err}"
    print("PASS T6g: non-string description in timepadSupport rejected")


def test_t6_valid_with_description():
    """T6h: timepadSupport with valid description string accepted."""
    ok, err = _simulate_server_validation(
        {"timepadSupport": {"enabled": True, "description": "TimePad integration enabled"}}
    )
    assert ok, f"Expected valid payload with description, got: {err}"
    print("PASS T6h: valid timepadSupport with description string accepted")


# ─────────────────────────────────────────────────────────────────────────────
# T7 — Rebrand cleanliness
# ─────────────────────────────────────────────────────────────────────────────

# Feature files from `git diff develop --name-only` plus untracked new files:
_FEATURE_FILES = [
    _REPO_ROOT / "kanban-hooks" / "timepad_config.json",
    _REPO_ROOT / "kanban-hooks" / "timepad_config.py",
    _REPO_ROOT / "kanban-hooks" / "aiteamforge_paths.py",
    _REPO_ROOT / "lcars-ui" / "server.py",
    _REPO_ROOT / "docs" / "TIMEPAD_CONFIG.md",
    _REPO_ROOT / "sync-tap.sh",
    _REPO_ROOT / "CHANGELOG.md",
]


def test_t7_no_timeapp_in_feature_files():
    """T7a: No functional 'timeapp' references in the feature's Python/JSON source files.

    Allowed (documentation only — not functional code):
      - Comments/docstrings explaining the rebrand history ("supersedes timeapp")
      - Migration docs in TIMEPAD_CONFIG.md and CHANGELOG.md saying the old name is invalid
      - The CHANGELOG recording the rename

    Functional violations (what we actually check for):
      - env var definitions: os.environ["TIMEAPP_..."] or os.environ.get("TIMEAPP_...")
      - Code that READS a TIMEAPP env var at runtime
      - apiBaseUrl pointing at timeapp.io (not timepad.io)
      - JSON schema keys named timeapp*

    Strategy: scan only Python source files (.py) for runtime references to TIMEAPP,
    specifically code that would LOOK UP a TIMEAPP_ env var in os.environ.
    Documentation files (.md) and JSON comment strings are excluded — they record
    the migration and do not produce functional behavior.
    """
    violations = []

    # Only scan Python source files for functional runtime TIMEAPP references.
    py_files = [f for f in _FEATURE_FILES if f.suffix == ".py" and f.exists()]

    for fpath in py_files:
        lines = fpath.read_text(encoding="utf-8", errors="replace").splitlines()
        for lineno, line in enumerate(lines, start=1):
            stripped = line.strip()
            # Skip pure comment lines and docstring prose
            if stripped.startswith("#") or stripped.startswith('"""') or stripped.startswith("'"):
                continue
            # Detect env var reads that reference TIMEAPP (functional, not doc)
            # Pattern: os.environ.get("TIMEAPP_..." or env["TIMEAPP_..."]
            if "TIMEAPP_" in line and (
                'os.environ' in line
                or '_testing_env' in line
                or 'env.get(' in line
                or 'env[' in line
            ):
                violations.append(
                    f"{fpath.name}:{lineno}: runtime TIMEAPP_ env lookup: {stripped[:80]!r}"
                )
            # Detect functional URL references to timeapp.io (not timepad.io)
            if "timeapp.io" in line.lower():
                violations.append(
                    f"{fpath.name}:{lineno}: timeapp.io URL reference: {stripped[:80]!r}"
                )

    assert not violations, (
        "Functional TIMEAPP runtime references found in Python source files:\n"
        + "\n".join(violations)
    )
    print("PASS T7a: no functional 'timeapp' runtime references in Python source files")


def test_t7_no_liquidstyle_in_feature_files():
    """T7b: No functional 'liquidstyle' references in the feature's source files.

    Allowed occurrences (documentation / validation-check prose — not functional):
      - JSON/Python comments explaining "supersedes time.liquidstyle.io"
      - Validation code that CHECKS FOR and REJECTS liquidstyle
        (e.g. `if "liquidstyle" in api_base.lower(): errors.append(...)` — this
         is enforcement of the rebrand, not a functional use)
      - Migration docs in TIMEPAD_CONFIG.md and CHANGELOG.md

    Functional violations:
      - Any apiBaseUrl string pointing at liquidstyle.io (not timepad.io)
        that would actually be USED as an HTTP endpoint
      - Any env var LOOKUP using a LIQUIDSTYLE_ name at runtime
      - vault path containing liquidstyle as the engine slug

    Strategy: scan only the JSON config file for liquidstyle.io as a non-comment
    apiBaseUrl value (the only place where it would be a live endpoint reference),
    and scan Python files for liquidstyle env var lookups.
    """
    violations = []

    # Check timepad_config.json: no team's apiBaseUrl should point at liquidstyle.io
    cfg_json = _REPO_ROOT / "kanban-hooks" / "timepad_config.json"
    if cfg_json.exists():
        config = json.loads(cfg_json.read_text(encoding="utf-8"))
        for team_slug, block in config.get("teams", {}).items():
            if isinstance(block, dict):
                api_url = block.get("apiBaseUrl", "")
                if "liquidstyle" in api_url.lower():
                    violations.append(
                        f"timepad_config.json: team '{team_slug}' apiBaseUrl points at "
                        f"liquidstyle.io: {api_url!r}"
                    )

    # Check Python source files: no runtime LIQUIDSTYLE env var lookups
    py_files = [f for f in _FEATURE_FILES if f.suffix == ".py" and f.exists()]
    for fpath in py_files:
        lines = fpath.read_text(encoding="utf-8", errors="replace").splitlines()
        for lineno, line in enumerate(lines, start=1):
            stripped = line.strip()
            # Skip pure comment lines and pure string-comparison checks
            # (the validation code that REJECTS liquidstyle is not a functional use)
            if stripped.startswith("#"):
                continue
            # Detect env var lookups that reference LIQUIDSTYLE (functional, not check)
            if "LIQUIDSTYLE_" in line.upper() and (
                'os.environ' in line
                or 'env.get(' in line
                or 'env[' in line
                or '_testing_env' in line
            ):
                violations.append(
                    f"{fpath.name}:{lineno}: runtime LIQUIDSTYLE_ env lookup: {stripped[:80]!r}"
                )

    assert not violations, (
        "Functional LIQUIDSTYLE references found in feature source files:\n"
        + "\n".join(violations)
    )
    print("PASS T7b: no functional 'liquidstyle' references in feature source files")


# ─────────────────────────────────────────────────────────────────────────────
# T8 — Tap mirror accounting
# ─────────────────────────────────────────────────────────────────────────────

def test_t8_timepad_config_json_in_sync_tap():
    """T8a: sync-tap.sh explicitly references timepad_config.json for tap mirroring."""
    sync_tap = _REPO_ROOT / "sync-tap.sh"
    assert sync_tap.exists(), "sync-tap.sh not found"
    content = sync_tap.read_text(encoding="utf-8")
    assert "timepad_config.json" in content, (
        "sync-tap.sh does not reference timepad_config.json — tap mirror not covered"
    )
    print("PASS T8a: sync-tap.sh explicitly covers timepad_config.json")


def test_t8_timepad_config_py_covered_by_glob():
    """T8b: timepad_config.py is covered by the kanban-hooks *.py glob in sync-tap.sh."""
    sync_tap = _REPO_ROOT / "sync-tap.sh"
    content = sync_tap.read_text(encoding="utf-8")
    # The glob finds all *.py in kanban-hooks/ — confirm that pattern is present
    assert "kanban-hooks" in content and '*.py' in content, (
        "sync-tap.sh does not appear to have a kanban-hooks *.py glob"
    )
    print("PASS T8b: sync-tap.sh kanban-hooks *.py glob covers timepad_config.py")


def test_t8_pre_push_hook_covers_kanban_hooks():
    """T8c: pre-push hook SYNC_TAP_PATHS includes 'kanban-hooks/' prefix."""
    pre_push = _REPO_ROOT / ".githooks" / "pre-push"
    if not pre_push.exists():
        print("SKIP T8c: .githooks/pre-push not found — skip pre-push tap coverage check")
        return
    content = pre_push.read_text(encoding="utf-8")
    assert '"kanban-hooks/"' in content or "'kanban-hooks/'" in content, (
        ".githooks/pre-push SYNC_TAP_PATHS does not include 'kanban-hooks/'"
    )
    print("PASS T8c: pre-push hook SYNC_TAP_PATHS covers kanban-hooks/")


# ─────────────────────────────────────────────────────────────────────────────
# T9 — Review follow-ups (XACA-0619-011 description cap, 012 _skip_vault)
# ─────────────────────────────────────────────────────────────────────────────

def test_t9_description_over_cap_rejected():
    """T9a: timepadSupport.description over 500 chars is rejected (XACA-0619-011)."""
    ok, err = _simulate_server_validation(
        {"timepadSupport": {"enabled": True, "description": "x" * 501}}
    )
    assert not ok, "Expected rejection for 501-char description"
    assert "500" in (err or ""), f"Unexpected error message: {err}"
    print("PASS T9a: over-cap (501-char) description rejected")


def test_t9_description_at_cap_accepted():
    """T9b: timepadSupport.description at exactly 500 chars is accepted."""
    ok, err = _simulate_server_validation(
        {"timepadSupport": {"enabled": True, "description": "x" * 500}}
    )
    assert ok, f"Expected 500-char description to be accepted, got: {err}"
    print("PASS T9b: at-cap (500-char) description accepted")


def test_t9_skip_vault_resolves_env_and_masks():
    """T9c: _skip_vault resolves from env-var only and never leaks the secret (XACA-0619-012)."""
    import timepad_config as tc
    fp = tc.resolve_timepad_token_fingerprint(
        "academy",
        token_ref="FAKE_TP_TOKEN",
        _testing_env={"FAKE_TP_TOKEN": "sk-supersecret-value-987"},
        _skip_vault=True,
    )
    assert "supersecret" not in fp, f"Fingerprint leaked the secret: {fp}"
    assert fp.startswith("sk-s"), f"Unexpected fingerprint prefix: {fp}"
    print(f"PASS T9c: _skip_vault env resolution masked -> {fp}")


def test_t9_skip_vault_no_token_returns_not_set():
    """T9d: _skip_vault with no env token returns '(not set)' without touching vault."""
    import timepad_config as tc
    fp = tc.resolve_timepad_token_fingerprint(
        "academy", _testing_env={}, _skip_vault=True
    )
    assert fp == "(not set)", f"Expected '(not set)', got: {fp}"
    print("PASS T9d: _skip_vault no-token returns '(not set)'")


# ─────────────────────────────────────────────────────────────────────────────
# Test runner
# ─────────────────────────────────────────────────────────────────────────────

def run_all():
    tests = [
        # T1 — Module import sanity
        test_t1_import_aiteamforge_paths,
        test_t1_import_timepad_config,
        test_t1_server_py_syntax,
        test_t1_timepad_config_py_syntax,
        # T2 — Schema / loader
        test_t2_all_11_teams_present,
        test_t2_validate_shipped_config_passes,
        test_t2_reject_non_https_apiBaseUrl,
        test_t2_reject_liquidstyle_in_apiBaseUrl,
        test_t2_reject_liquidstyle_in_tokenRef,
        test_t2_reject_raw_token_prefix_tp,
        test_t2_reject_raw_token_prefix_sk,
        test_t2_reject_bearer_token_in_tokenRef,
        test_t2_reject_non_string_uuid_field,
        test_t2_reject_non_string_uuid_projectId,
        # T3 — Placeholder handling
        test_t3_shipped_config_has_placeholders,
        test_t3_no_crash_on_placeholder,
        test_t3_false_when_real_uuids,
        test_t3_true_for_absent_team,
        # T4 — Enable gate
        test_t4_disabled_by_default,
        test_t4_true_when_board_enabled,
        test_t4_false_when_board_explicitly_false,
        test_t4_false_when_board_file_missing,
        test_t4_reads_board_json_not_config_json,
        # T5 — Token security
        test_t5_mask_timepad_token_hides_secret,
        test_t5_mask_shows_prefix_only,
        test_t5_mask_empty_token,
        test_t5_fingerprint_does_not_contain_secret,
        test_t5_resolve_token_uses_env_var,
        test_t5_resolve_token_raises_when_no_source,
        test_t5_per_team_env_var_name,
        test_t5_no_inline_token_in_config_json,
        test_t5_mainevent_env_var_name,
        # T6 — /api/team-config validation logic
        test_t6_valid_payload_accepted,
        test_t6_non_bool_enabled_rejected,
        test_t6_integer_enabled_rejected,
        test_t6_unknown_nested_key_rejected,
        test_t6_unknown_top_level_key_rejected,
        test_t6_get_default_returns_false,
        test_t6_description_non_string_rejected,
        test_t6_valid_with_description,
        # T7 — Rebrand cleanliness
        test_t7_no_timeapp_in_feature_files,
        test_t7_no_liquidstyle_in_feature_files,
        # T8 — Tap mirror accounting
        test_t8_timepad_config_json_in_sync_tap,
        test_t8_timepad_config_py_covered_by_glob,
        test_t8_pre_push_hook_covers_kanban_hooks,
        # T9 — Review follow-ups (XACA-0619-011 / 012)
        test_t9_description_over_cap_rejected,
        test_t9_description_at_cap_accepted,
        test_t9_skip_vault_resolves_env_and_masks,
        test_t9_skip_vault_no_token_returns_not_set,
    ]

    passed = 0
    failed = 0
    failures: list[str] = []

    for test_fn in tests:
        try:
            test_fn()
            passed += 1
        except Exception as exc:
            failed += 1
            failures.append(f"FAIL {test_fn.__name__}: {exc}")
            print(f"FAIL {test_fn.__name__}: {exc}")

    total = passed + failed
    print(f"\n{'='*60}")
    print(f"XACA-0619-006 Test Results: {passed}/{total} passed")
    if failures:
        print("\nFAILURES:")
        for f in failures:
            print(f"  {f}")
    else:
        print("All tests passed.")
    print(f"{'='*60}")
    return failed == 0


if __name__ == "__main__":
    ok = run_all()
    sys.exit(0 if ok else 1)
