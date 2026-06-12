#!/usr/bin/env python3
"""Quick smoke tests for XACA-0619-005 accessor API."""
import sys
import json
import tempfile
import os

sys.path.insert(0, os.path.dirname(__file__))

from aiteamforge_paths import validate_timepad_config, is_timepad_enabled, get_timepad_team_config
from pathlib import Path


def write_json(path, data):
    with open(path, "w") as f:
        json.dump(data, f)


def test_validate_no_enabled():
    """validate_timepad_config no longer requires 'enabled' field."""
    cfg = {
        "teams": {
            "academy": {
                "apiBaseUrl": "https://timepad.io/api",
                "tokenRef": "TIMEPAD_API_KEY",
                "clientId": "<fetch-from-timepad.io>",
                "projectId": "<fetch-from-timepad.io>",
                "tagId": "<fetch-from-timepad.io>",
            }
        }
    }
    errors = validate_timepad_config(cfg)
    assert errors == [], f"Expected no errors, got: {errors}"
    print("PASS: validate_timepad_config accepts block without 'enabled'")


def test_validate_stale_enabled_ignored():
    """A stale 'enabled' field in a config block is silently ignored."""
    cfg = {
        "teams": {
            "academy": {
                "enabled": False,  # stale — should be ignored, not an error
                "apiBaseUrl": "https://timepad.io/api",
                "tokenRef": "TIMEPAD_API_KEY",
                "clientId": "<fetch-from-timepad.io>",
                "projectId": "<fetch-from-timepad.io>",
                "tagId": "<fetch-from-timepad.io>",
            }
        }
    }
    errors = validate_timepad_config(cfg)
    assert errors == [], f"Expected no errors (stale enabled ignored), got: {errors}"
    print("PASS: validate_timepad_config silently ignores stale 'enabled' field")


def test_is_timepad_enabled_board_json():
    """is_timepad_enabled reads teamConfig.timepadSupport.enabled from board JSON."""
    import aiteamforge_paths as ap

    original_get = ap.get_team_kanban_dir
    team_slug = "academy"

    with tempfile.TemporaryDirectory() as tmpdir:
        board_path = os.path.join(tmpdir, f"{team_slug}-board.json")
        ap.get_team_kanban_dir = lambda t: Path(tmpdir)

        try:
            # enabled = True
            write_json(board_path, {"teamConfig": {"timepadSupport": {"enabled": True}}})
            assert is_timepad_enabled(team_slug) is True, "Expected True when board has enabled=true"
            print("PASS: is_timepad_enabled returns True when board JSON has enabled=true")

            # enabled = False
            write_json(board_path, {"teamConfig": {"timepadSupport": {"enabled": False}}})
            assert is_timepad_enabled(team_slug) is False, "Expected False when board has enabled=false"
            print("PASS: is_timepad_enabled returns False when board JSON has enabled=false")

            # timepadSupport key absent
            write_json(board_path, {"teamConfig": {"crSupport": {"enabled": True}}})
            assert is_timepad_enabled(team_slug) is False, "Expected False when timepadSupport absent"
            print("PASS: is_timepad_enabled returns False when timepadSupport key absent")

            # teamConfig key absent
            write_json(board_path, {"items": []})
            assert is_timepad_enabled(team_slug) is False, "Expected False when teamConfig absent"
            print("PASS: is_timepad_enabled returns False when teamConfig absent")

            # board file missing
            os.remove(board_path)
            assert is_timepad_enabled(team_slug) is False, "Expected False when board file missing"
            print("PASS: is_timepad_enabled returns False when board file missing")

        finally:
            ap.get_team_kanban_dir = original_get


def test_get_timepad_team_config_returns_no_enabled():
    """get_timepad_team_config returns connection config without 'enabled' key."""
    import os as _os

    with tempfile.TemporaryDirectory() as tmpdir:
        # Write a minimal valid config (no enabled field)
        cfg_path = os.path.join(tmpdir, "timepad_config.json")
        config_data = {
            "_schemaVersion": 1,
            "teams": {
                "academy": {
                    "apiBaseUrl": "https://timepad.io/api",
                    "tokenRef": "TIMEPAD_API_KEY",
                    "clientId": "real-client-id",
                    "projectId": "real-project-id",
                    "tagId": "real-tag-id",
                }
            },
        }
        write_json(cfg_path, config_data)

        orig_env = _os.environ.get("AITEAMFORGE_TIMEPAD_CONFIG")
        _os.environ["AITEAMFORGE_TIMEPAD_CONFIG"] = cfg_path

        import aiteamforge_paths as ap
        ap.bust_timepad_config_cache()  # force reload with new path

        try:
            result = get_timepad_team_config("academy")
            assert "enabled" not in result, f"'enabled' must not be in config dict, got: {result}"
            assert result.get("apiBaseUrl") == "https://timepad.io/api"
            assert result.get("tokenRef") == "TIMEPAD_API_KEY"
            assert result.get("clientId") == "real-client-id"
            print("PASS: get_timepad_team_config returns connection config without 'enabled'")
        finally:
            if orig_env is not None:
                _os.environ["AITEAMFORGE_TIMEPAD_CONFIG"] = orig_env
            else:
                _os.environ.pop("AITEAMFORGE_TIMEPAD_CONFIG", None)
            ap.bust_timepad_config_cache()


if __name__ == "__main__":
    test_validate_no_enabled()
    test_validate_stale_enabled_ignored()
    test_is_timepad_enabled_board_json()
    test_get_timepad_team_config_returns_no_enabled()
    print("\nAll XACA-0619-005 smoke tests passed.")
