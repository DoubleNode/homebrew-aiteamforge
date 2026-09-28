#!/usr/bin/env python3
"""
test_board_settings_1083.py — Tests for XACA-1083-001 board start-gate settings.

Covers:
  T1 — Module import sanity
  T2 — Schema / loader (11 teams, shipped-config validation, command seed)
  T3 — Fail-closed booleans (every malformed-input class from the task brief)
  T4 — Grandfather cutoff (fail-closed in BOTH directions, never "all exempt")
  T5 — Setter: atomic write success path, seeding, and every failure path
  T6 — CLI contract (`get` / `set` subprocess invocations)
  T20 — XACA-1083-020: single grandfatherCutoff validator, shared by the
        shell gate (real zsh subprocess), the CLI, and is_item_grandfathered()

Run:
    cd kanban-hooks && python3 test_board_settings_1083.py
"""
from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

_REPO_ROOT = Path(__file__).parent.parent
_KANBAN_HOOKS = Path(__file__).parent

EXPECTED_TEAMS = {
    "academy", "ios", "android", "firebase", "command",
    "dns", "freelance", "mainevent", "legal", "medical", "finance",
}


class _EnvOverride:
    """Context manager: set AITEAMFORGE_BOARD_SETTINGS_CONFIG to *path* for
    the duration of the block, restore the previous value on exit, and bust
    the loader cache on both entry and exit so no test leaks state into the
    next one."""

    def __init__(self, path: str | None):
        self.path = path
        self._old: str | None = None

    def __enter__(self):
        from aiteamforge_paths import bust_board_settings_cache

        self._old = os.environ.get("AITEAMFORGE_BOARD_SETTINGS_CONFIG")
        if self.path is None:
            os.environ.pop("AITEAMFORGE_BOARD_SETTINGS_CONFIG", None)
        else:
            os.environ["AITEAMFORGE_BOARD_SETTINGS_CONFIG"] = self.path
        bust_board_settings_cache()
        return self

    def __exit__(self, *exc):
        from aiteamforge_paths import bust_board_settings_cache

        if self._old is not None:
            os.environ["AITEAMFORGE_BOARD_SETTINGS_CONFIG"] = self._old
        else:
            os.environ.pop("AITEAMFORGE_BOARD_SETTINGS_CONFIG", None)
        bust_board_settings_cache()


def _write_json(path: Path, data) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data), encoding="utf-8")


# ─────────────────────────────────────────────────────────────────────────────
# T1 — Module import sanity
# ─────────────────────────────────────────────────────────────────────────────

def test_t1_import_aiteamforge_paths():
    import aiteamforge_paths  # noqa: F401
    print("PASS T1a: import aiteamforge_paths")


def test_t1_import_board_settings():
    import board_settings  # noqa: F401
    print("PASS T1b: import board_settings")


def test_t1_board_settings_py_syntax():
    import py_compile
    py_compile.compile(str(_KANBAN_HOOKS / "board_settings.py"), doraise=True)
    print("PASS T1c: board_settings.py py_compile clean")


def test_t1_aiteamforge_paths_py_syntax():
    import py_compile
    py_compile.compile(str(_KANBAN_HOOKS / "aiteamforge_paths.py"), doraise=True)
    print("PASS T1d: aiteamforge_paths.py py_compile clean")


# ─────────────────────────────────────────────────────────────────────────────
# T2 — Schema / loader
# ─────────────────────────────────────────────────────────────────────────────

def test_t2_shipped_config_has_11_teams():
    """T2a: the shipped board_settings.json declares exactly the 11 expected teams."""
    cfg_path = _KANBAN_HOOKS / "board_settings.json"
    with open(cfg_path, encoding="utf-8") as f:
        config = json.load(f)
    teams = set(config.get("teams", {}).keys())
    missing = EXPECTED_TEAMS - teams
    extra = teams - EXPECTED_TEAMS
    assert not missing, f"Missing teams: {missing}"
    assert not extra, f"Unexpected teams: {extra}"
    print("PASS T2a: shipped board_settings.json has all 11 expected teams")


def test_t2_shipped_config_validates_clean():
    """T2b: validate_board_settings() reports zero errors on the shipped JSON."""
    from aiteamforge_paths import validate_board_settings

    cfg_path = _KANBAN_HOOKS / "board_settings.json"
    with open(cfg_path, encoding="utf-8") as f:
        config = json.load(f)
    errors = validate_board_settings(config)
    assert errors == [], f"Shipped config validation errors: {errors}"
    print("PASS T2b: validate_board_settings passes on shipped JSON")


def test_t2_shipped_config_command_seeded_false():
    """T2c: 'command' ships both booleans False; every other team ships both True."""
    cfg_path = str(_KANBAN_HOOKS / "board_settings.json")
    with _EnvOverride(cfg_path):
        from aiteamforge_paths import is_epic_required_for_team, is_release_required_for_team

        assert is_epic_required_for_team("command") is False, "command epic gate must be OFF"
        assert is_release_required_for_team("command") is False, "command release gate must be OFF"
        for team in EXPECTED_TEAMS - {"command"}:
            assert is_epic_required_for_team(team) is True, f"{team} epic gate must default ON"
            assert is_release_required_for_team(team) is True, f"{team} release gate must default ON"
    print("PASS T2c: command seeded false/false, all other teams default true/true")


def test_t2_grandfather_cutoff_and_field_shipped():
    """T2d: the shipped config carries a parseable cutoff and creationTimestampField='addedAt'."""
    cfg_path = str(_KANBAN_HOOKS / "board_settings.json")
    with _EnvOverride(cfg_path):
        from aiteamforge_paths import (
            get_board_settings_creation_timestamp_field,
            get_board_settings_grandfather_cutoff,
        )

        cutoff = get_board_settings_grandfather_cutoff()
        assert cutoff, "shipped config must carry a grandfatherCutoff"
        field = get_board_settings_creation_timestamp_field()
        assert field == "addedAt", f"expected creationTimestampField='addedAt', got {field!r}"
    print("PASS T2d: shipped grandfatherCutoff present, creationTimestampField == 'addedAt'")


# ─────────────────────────────────────────────────────────────────────────────
# T3 — Fail-closed booleans: every malformed-input class from the task brief
# ─────────────────────────────────────────────────────────────────────────────

def test_t3_missing_file_resolves_true():
    """T3a: a config path that does not exist -> both gates True for any team."""
    with tempfile.TemporaryDirectory() as tmpdir:
        missing_path = str(Path(tmpdir) / "does-not-exist.json")
        with _EnvOverride(missing_path):
            from aiteamforge_paths import is_epic_required_for_team, is_release_required_for_team

            assert is_epic_required_for_team("academy") is True
            assert is_release_required_for_team("academy") is True
    print("PASS T3a: missing config file -> required=true")


def test_t3_malformed_json_resolves_true():
    """T3b: unparseable JSON -> both gates True."""
    with tempfile.TemporaryDirectory() as tmpdir:
        bad_path = Path(tmpdir) / "bad.json"
        bad_path.write_text("{not valid json", encoding="utf-8")
        with _EnvOverride(str(bad_path)):
            from aiteamforge_paths import is_epic_required_for_team, is_release_required_for_team

            assert is_epic_required_for_team("academy") is True
            assert is_release_required_for_team("academy") is True
    print("PASS T3b: malformed JSON -> required=true")


def test_t3_non_dict_root_resolves_true():
    """T3c: a JSON root that is a list (not a dict) -> both gates True."""
    with tempfile.TemporaryDirectory() as tmpdir:
        list_path = Path(tmpdir) / "list_root.json"
        _write_json(list_path, ["not", "a", "dict"])
        with _EnvOverride(str(list_path)):
            from aiteamforge_paths import is_epic_required_for_team, is_release_required_for_team

            assert is_epic_required_for_team("academy") is True
            assert is_release_required_for_team("academy") is True
    print("PASS T3c: non-dict JSON root -> required=true")


def test_t3_unknown_team_resolves_true():
    """T3d: a team absent from 'teams' -> both gates True, even with a well-formed file."""
    with tempfile.TemporaryDirectory() as tmpdir:
        cfg_path = Path(tmpdir) / "cfg.json"
        _write_json(cfg_path, {"teams": {"academy": {"requireEpicOnStart": False, "requireReleaseOnStart": False}}})
        with _EnvOverride(str(cfg_path)):
            from aiteamforge_paths import is_epic_required_for_team, is_release_required_for_team

            assert is_epic_required_for_team("nonexistent-team") is True
            assert is_release_required_for_team("nonexistent-team") is True
            # Sanity: the known team's explicit False really is honoured.
            assert is_epic_required_for_team("academy") is False
    print("PASS T3d: unknown team -> required=true (known team's explicit false still honoured)")


def test_t3_team_block_not_dict_resolves_true():
    """T3e: a team block that is not itself a dict -> both gates True."""
    with tempfile.TemporaryDirectory() as tmpdir:
        cfg_path = Path(tmpdir) / "cfg.json"
        _write_json(cfg_path, {"teams": {"academy": "not-a-dict"}})
        with _EnvOverride(str(cfg_path)):
            from aiteamforge_paths import is_epic_required_for_team, is_release_required_for_team

            assert is_epic_required_for_team("academy") is True
            assert is_release_required_for_team("academy") is True
    print("PASS T3e: non-dict team block -> required=true")


def test_t3_non_dict_teams_resolves_true():
    """T3e2 (XACA-1083-015): a present-but-non-dict 'teams' value (null, list,
    string, or number) must fail closed to True/True for EVERY accessor
    without raising -- the loader's 'Never raises' contract held for a
    non-dict ROOT (T3c) but not for a non-dict 'teams' sitting inside an
    otherwise-valid dict root, which used to reach
    get_board_settings_team_config_raw() and raise AttributeError on
    `.get()`. Also covers get_board_settings_team_config_raw() directly,
    since is_epic_required_for_team()/is_release_required_for_team() alone
    would mask a raise inside a lower layer if a future refactor added a
    try/except at the wrong level."""
    from aiteamforge_paths import (
        is_epic_required_for_team,
        is_release_required_for_team,
        get_board_settings_team_config_raw,
    )

    for bad_teams in (None, [], "not-a-dict", 5, 3.14, True):
        with tempfile.TemporaryDirectory() as tmpdir:
            cfg_path = Path(tmpdir) / "cfg.json"
            _write_json(cfg_path, {"_schemaVersion": 1, "teams": bad_teams})
            with _EnvOverride(str(cfg_path)):
                assert is_epic_required_for_team("academy") is True, (
                    f"teams={bad_teams!r} must resolve requireEpicOnStart to True"
                )
                assert is_release_required_for_team("academy") is True, (
                    f"teams={bad_teams!r} must resolve requireReleaseOnStart to True"
                )
                assert get_board_settings_team_config_raw("academy") == {}, (
                    f"teams={bad_teams!r} must return {{}} from the raw accessor, not raise"
                )
    print("PASS T3e2: non-dict 'teams' (null/list/str/number/bool) -> required=true, never raises")


def test_t3_missing_key_resolves_true():
    """T3f: a team block missing one of the two keys -> that key resolves True; the
    present key is honoured normally."""
    with tempfile.TemporaryDirectory() as tmpdir:
        cfg_path = Path(tmpdir) / "cfg.json"
        _write_json(cfg_path, {"teams": {"academy": {"requireEpicOnStart": False}}})
        with _EnvOverride(str(cfg_path)):
            from aiteamforge_paths import is_epic_required_for_team, is_release_required_for_team

            assert is_epic_required_for_team("academy") is False, "present key must be honoured"
            assert is_release_required_for_team("academy") is True, "missing key must fail closed to true"
    print("PASS T3f: missing key -> required=true; sibling present key still honoured")


def test_t3_non_boolean_values_resolve_true():
    """T3g: every non-bool value class named in the task brief (string 'false', 0, 1,
    None) resolves to True -- never accepted as a boolean."""
    non_bool_values = ["false", "true", 0, 1, None, "0", "1", [], {}]
    with tempfile.TemporaryDirectory() as tmpdir:
        for i, bad_val in enumerate(non_bool_values):
            cfg_path = Path(tmpdir) / f"cfg_{i}.json"
            _write_json(cfg_path, {"teams": {"academy": {
                "requireEpicOnStart": bad_val,
                "requireReleaseOnStart": bad_val,
            }}})
            with _EnvOverride(str(cfg_path)):
                from aiteamforge_paths import is_epic_required_for_team, is_release_required_for_team

                assert is_epic_required_for_team("academy") is True, (
                    f"requireEpicOnStart={bad_val!r} must resolve to True"
                )
                assert is_release_required_for_team("academy") is True, (
                    f"requireReleaseOnStart={bad_val!r} must resolve to True"
                )
    print(f"PASS T3g: all {len(non_bool_values)} non-boolean value classes resolve to True")


def test_t3_unreadable_file_resolves_true():
    """T3h: a config file with its read permission stripped -> both gates True.
    Skipped when running as root (root ignores unix permission bits)."""
    if os.geteuid() == 0:
        print("SKIP T3h: running as root, permission bits are not enforced")
        return
    with tempfile.TemporaryDirectory() as tmpdir:
        cfg_path = Path(tmpdir) / "cfg.json"
        _write_json(cfg_path, {"teams": {"academy": {"requireEpicOnStart": False, "requireReleaseOnStart": False}}})
        os.chmod(cfg_path, 0o000)
        try:
            with _EnvOverride(str(cfg_path)):
                from aiteamforge_paths import is_epic_required_for_team, is_release_required_for_team

                assert is_epic_required_for_team("academy") is True
                assert is_release_required_for_team("academy") is True
        finally:
            os.chmod(cfg_path, 0o644)  # restore so tempdir cleanup can delete it
    print("PASS T3h: unreadable file (mode 000) -> required=true")


# ─────────────────────────────────────────────────────────────────────────────
# T4 — Grandfather cutoff: fail-closed in BOTH directions
# ─────────────────────────────────────────────────────────────────────────────

def test_t4_missing_cutoff_never_grandfathers():
    """T4a: no grandfatherCutoff key at all -> is_item_grandfathered is False for
    every created_at, including one that is clearly ancient."""
    with tempfile.TemporaryDirectory() as tmpdir:
        cfg_path = Path(tmpdir) / "cfg.json"
        _write_json(cfg_path, {"teams": {}})  # no grandfatherCutoff key
        with _EnvOverride(str(cfg_path)):
            from aiteamforge_paths import is_item_grandfathered

            assert is_item_grandfathered("2000-01-01T00:00:00Z") is False
            assert is_item_grandfathered(None) is False
    print("PASS T4a: missing cutoff -> never grandfathered")


def test_t4_malformed_cutoff_never_grandfathers():
    """T4b: an unparseable grandfatherCutoff string -> is_item_grandfathered is False,
    even for a created_at that would otherwise clearly qualify."""
    with tempfile.TemporaryDirectory() as tmpdir:
        cfg_path = Path(tmpdir) / "cfg.json"
        _write_json(cfg_path, {"teams": {}, "grandfatherCutoff": "not-a-timestamp"})
        with _EnvOverride(str(cfg_path)):
            from aiteamforge_paths import is_item_grandfathered

            assert is_item_grandfathered("2000-01-01T00:00:00Z") is False
    print("PASS T4b: malformed cutoff -> never grandfathered")


def test_t4_valid_cutoff_exempts_earlier_items():
    """T4c: a real cutoff exempts an item created strictly before it."""
    with tempfile.TemporaryDirectory() as tmpdir:
        cfg_path = Path(tmpdir) / "cfg.json"
        _write_json(cfg_path, {"teams": {}, "grandfatherCutoff": "2026-09-25T00:00:00Z"})
        with _EnvOverride(str(cfg_path)):
            from aiteamforge_paths import is_item_grandfathered

            assert is_item_grandfathered("2026-01-01T00:00:00Z") is True
    print("PASS T4c: item created before cutoff -> grandfathered")


def test_t4_valid_cutoff_does_not_exempt_later_or_equal_items():
    """T4d: an item created at or after the cutoff is NOT exempt (strict '<')."""
    with tempfile.TemporaryDirectory() as tmpdir:
        cfg_path = Path(tmpdir) / "cfg.json"
        _write_json(cfg_path, {"teams": {}, "grandfatherCutoff": "2026-09-25T00:00:00Z"})
        with _EnvOverride(str(cfg_path)):
            from aiteamforge_paths import is_item_grandfathered

            assert is_item_grandfathered("2026-09-25T00:00:00Z") is False, "equal to cutoff must NOT be exempt"
            assert is_item_grandfathered("2026-12-01T00:00:00Z") is False, "after cutoff must NOT be exempt"
    print("PASS T4d: item created at/after cutoff -> not grandfathered (strict less-than)")


def test_t4_missing_or_malformed_created_at_never_grandfathers():
    """T4e: with a perfectly valid cutoff, a missing/malformed item timestamp still
    resolves to False -- an item this function can't place in time is never assumed
    exempt."""
    with tempfile.TemporaryDirectory() as tmpdir:
        cfg_path = Path(tmpdir) / "cfg.json"
        _write_json(cfg_path, {"teams": {}, "grandfatherCutoff": "2026-09-25T00:00:00Z"})
        with _EnvOverride(str(cfg_path)):
            from aiteamforge_paths import is_item_grandfathered

            assert is_item_grandfathered(None) is False
            assert is_item_grandfathered("") is False
            assert is_item_grandfathered("not-a-timestamp") is False
            assert is_item_grandfathered(12345) is False
    print("PASS T4e: missing/malformed created_at -> never grandfathered")


def test_t4_creation_timestamp_field_falls_back_to_addedAt():
    """T4f: an absent/malformed creationTimestampField falls back to the measured
    default 'addedAt'."""
    with tempfile.TemporaryDirectory() as tmpdir:
        cfg_path = Path(tmpdir) / "cfg.json"
        _write_json(cfg_path, {"teams": {}})  # no creationTimestampField key
        with _EnvOverride(str(cfg_path)):
            from aiteamforge_paths import get_board_settings_creation_timestamp_field

            assert get_board_settings_creation_timestamp_field() == "addedAt"

        _write_json(cfg_path, {"teams": {}, "creationTimestampField": ""})  # malformed: empty string
        with _EnvOverride(str(cfg_path)):
            from aiteamforge_paths import get_board_settings_creation_timestamp_field

            assert get_board_settings_creation_timestamp_field() == "addedAt"

        _write_json(cfg_path, {"teams": {}, "creationTimestampField": "customField"})
        with _EnvOverride(str(cfg_path)):
            from aiteamforge_paths import get_board_settings_creation_timestamp_field

            assert get_board_settings_creation_timestamp_field() == "customField"
    print("PASS T4f: creationTimestampField falls back to 'addedAt'; explicit override honoured")


def test_t4_trailing_z_and_naive_timestamps_normalize_to_utc():
    """T4g: a trailing 'Z' and a naive (no-offset) timestamp both parse, and are
    both treated as UTC."""
    with tempfile.TemporaryDirectory() as tmpdir:
        cfg_path = Path(tmpdir) / "cfg.json"
        _write_json(cfg_path, {"teams": {}, "grandfatherCutoff": "2026-09-25T00:00:00"})  # naive, no Z
        with _EnvOverride(str(cfg_path)):
            from aiteamforge_paths import is_item_grandfathered

            assert is_item_grandfathered("2026-01-01T00:00:00Z") is True
            assert is_item_grandfathered("2026-12-01T00:00:00") is False
    print("PASS T4g: naive and 'Z'-suffixed timestamps both parse and compare correctly")


# ─────────────────────────────────────────────────────────────────────────────
# T20 — XACA-1083-020: ONE grandfatherCutoff validator, shared by the shell
# gate, the CLI, and the LCARS API/UI.
#
# The matrix below was MEASURED against the REAL shell gate
# (_kb_board_settings_is_grandfathered in kanban-helpers.sh — a zsh function
# built on jq's fromdateiso8601) with a fixed created_at
# (_CREATED_AT_BEFORE_ALL, well before every cutoff below) BEFORE this
# ticket's validator was written; see docs/BOARD_SETTINGS.md § "Grandfather
# Cutoff Grammar" for the full recorded table. "accepted" means the shell
# grandfathers an item created at _CREATED_AT_BEFORE_ALL under that raw
# cutoff string.
#
# Prior to this ticket, get_board_settings_grandfather_cutoff() returned the
# RAW string and is_item_grandfathered() parsed it with
# datetime.fromisoformat (via _parse_iso8601_utc), which is MORE lenient
# than the shell: it accepted '+00:00'/other UTC offsets, date-only
# strings, a space instead of 'T', and lowercase 'z' — all of which the
# shell rejects. That divergence is the LCARS UI bug XACA-1083-020 closes.
# ─────────────────────────────────────────────────────────────────────────────

_CUTOFF_MATRIX: list[tuple[str, bool]] = [
    ("2026-09-26T22:02:39Z", True),          # canonical
    ("2026-09-26T22:02:39", True),           # naive -> treated as UTC
    ("2026-09-26T22:02:39.123Z", True),      # fractional seconds
    ("2026-09-26T22:02:39.123456Z", True),   # fractional, many digits
    ("2026-09-26T22:02:39.123", True),       # naive + fractional
    ("2026-09-26T22:02:39+00:00", False),    # UTC OFFSET form -- REJECTED (the headline divergence)
    ("2026-09-26", False),                   # date-only -- REJECTED
    ("2026-09-26 22:02:39Z", False),         # space instead of 'T' -- REJECTED
    ("2026-09-26T22:02:39z", False),         # lowercase 'z' -- REJECTED
    ("garbage", False),
    ("", False),
    ("2026-09-26T22:02:39.Z", False),        # empty fractional digits -- REJECTED
    ("2026-09-26T22:02:39+05:00", False),    # non-UTC offset -- REJECTED
    ("2026/09/26T22:02:39Z", False),         # wrong date separator
    ("2026-13-40T22:02:39Z", False),         # invalid calendar date (month 13)
]

#: Well before every VALID cutoff in the matrix above (all in 2026), so a
#: matrix cutoff that the validator/shell accepts always grandfathers an
#: item created at this instant.
_CREATED_AT_BEFORE_ALL = "2000-01-01T00:00:00Z"


def _shell_is_grandfathered(cutoff: str, created_at: str) -> bool:
    """Run the REAL _kb_board_settings_is_grandfathered in a REAL zsh
    subprocess, sourcing the REAL kanban-helpers.sh directly -- never a
    reimplementation of its jq expression. Returns True (exempt) iff the
    function's exit code is 0. cutoff/created_at are passed as positional
    shell args (never string-interpolated into the script) so no value in
    the matrix needs shell-quoting.
    """
    kanban_helpers = _REPO_ROOT / "kanban-helpers.sh"
    script = (
        'export KB_TEAM=academy KB_TERMINAL=agent SESSION_TYPE=agent\n'
        f'source "{kanban_helpers}" >/dev/null 2>&1\n'
        '_kb_board_settings_is_grandfathered "$1" "$2"\n'
        'echo $?\n'
    )
    env = dict(os.environ)
    # FORBIDDEN ACTIONS note (XACA-1083-020 task brief): strip TMUX/TMUX_PANE
    # in test envs -- this call never needs real-session context detection
    # (the function under test takes no team/session args), but a leaked
    # TMUX_PANE from the outer dev shell is exactly the kind of stray
    # ambient state this suite must not depend on.
    env.pop("TMUX", None)
    env.pop("TMUX_PANE", None)
    result = subprocess.run(
        ["zsh", "-c", script, "_", cutoff, created_at],
        capture_output=True, text=True, env=env, timeout=30,
    )
    rc = int(result.stdout.strip().splitlines()[-1])
    return rc == 0


def test_t20_normalize_grandfather_cutoff_matches_shell_matrix():
    """T20a: _normalize_grandfather_cutoff() accepts EXACTLY the strings the
    real shell gate accepts, per the measured matrix -- never a superset (a
    Python accept the shell rejects is the original bug this ticket
    closes); a subset is fine (see the function's own docstring)."""
    from aiteamforge_paths import _normalize_grandfather_cutoff

    for cutoff, shell_accepts in _CUTOFF_MATRIX:
        canonical = _normalize_grandfather_cutoff(cutoff)
        python_accepts = canonical is not None
        assert python_accepts == shell_accepts, (
            f"cutoff {cutoff!r}: python accepts={python_accepts} "
            f"shell accepts={shell_accepts} -- divergence!"
        )
        if python_accepts:
            assert canonical is not None and canonical.endswith("Z") and "T" in canonical
    print(f"PASS T20a: _normalize_grandfather_cutoff matches the shell matrix ({len(_CUTOFF_MATRIX)} cases)")


def test_t20_cross_layer_shell_parity():
    """T20b: the REAL shell gate (zsh subprocess, real kanban-helpers.sh)
    and the Python validator agree on every cutoff in the matrix -- the
    direct regression guard for the XACA-1083-020 finding: the LCARS UI
    stating an exemption the shell gate does not honour."""
    import shutil

    if shutil.which("zsh") is None:
        print("SKIP T20b: zsh not on PATH")
        return
    if not (_REPO_ROOT / "kanban-helpers.sh").is_file():
        print("SKIP T20b: kanban-helpers.sh not found")
        return
    from aiteamforge_paths import _normalize_grandfather_cutoff

    for cutoff, expected in _CUTOFF_MATRIX:
        shell_exempt = _shell_is_grandfathered(cutoff, _CREATED_AT_BEFORE_ALL)
        assert shell_exempt == expected, (
            f"cutoff {cutoff!r}: shell verdict={shell_exempt} expected={expected} -- "
            "the MEASURED matrix has drifted from the real shell gate's actual behavior"
        )
        python_accepts = _normalize_grandfather_cutoff(cutoff) is not None
        assert shell_exempt == python_accepts, (
            f"cutoff {cutoff!r}: shell exempt={shell_exempt} python validator "
            f"accepts={python_accepts} -- shell/python DIVERGE, exactly the bug "
            "XACA-1083-020 exists to close"
        )
    print(f"PASS T20b: shell gate and Python validator agree on every cutoff ({len(_CUTOFF_MATRIX)} cases)")


def test_t20_get_board_settings_grandfather_cutoff_returns_validated_value():
    """T20c: get_board_settings_grandfather_cutoff() returns exactly what
    _normalize_grandfather_cutoff() would, for every cutoff in the matrix --
    proving the accessor delegates instead of parsing separately."""
    from aiteamforge_paths import _normalize_grandfather_cutoff, get_board_settings_grandfather_cutoff

    for cutoff, _ in _CUTOFF_MATRIX:
        with tempfile.TemporaryDirectory() as tmpdir:
            cfg_path = Path(tmpdir) / "cfg.json"
            _write_json(cfg_path, {"teams": {}, "grandfatherCutoff": cutoff})
            with _EnvOverride(str(cfg_path)):
                resolved = get_board_settings_grandfather_cutoff()
            expected = _normalize_grandfather_cutoff(cutoff)
            assert resolved == expected, (
                f"cutoff {cutoff!r}: accessor returned {resolved!r}, validator says {expected!r}"
            )
    print("PASS T20c: get_board_settings_grandfather_cutoff() matches the validator for every matrix entry")


def test_t20_is_item_grandfathered_never_exempts_a_shell_rejected_cutoff():
    """T20d: for an item created well before every cutoff in the matrix,
    is_item_grandfathered() returns True iff the shared validator accepts
    the configured cutoff string -- it can never exempt an item under a
    cutoff the shell gate would reject."""
    from aiteamforge_paths import _normalize_grandfather_cutoff, is_item_grandfathered

    for cutoff, _ in _CUTOFF_MATRIX:
        with tempfile.TemporaryDirectory() as tmpdir:
            cfg_path = Path(tmpdir) / "cfg.json"
            _write_json(cfg_path, {"teams": {}, "grandfatherCutoff": cutoff})
            with _EnvOverride(str(cfg_path)):
                exempt = is_item_grandfathered(_CREATED_AT_BEFORE_ALL)
            expected = _normalize_grandfather_cutoff(cutoff) is not None
            assert exempt == expected, (
                f"cutoff {cutoff!r}: is_item_grandfathered={exempt} expected={expected}"
            )
    print("PASS T20d: is_item_grandfathered() agrees with the validator for every matrix entry")


def test_t20_cli_get_grandfather_cutoff_matches_validator():
    """T20e: the `get` CLI's grandfatherCutoff= line is the validated/
    canonical value (or empty for a rejected cutoff), never the raw config
    string."""
    from aiteamforge_paths import _normalize_grandfather_cutoff

    for cutoff, _ in _CUTOFF_MATRIX:
        with tempfile.TemporaryDirectory() as tmpdir:
            cfg_path = Path(tmpdir) / "cfg.json"
            _write_json(cfg_path, {
                "teams": {"academy": {"requireEpicOnStart": True, "requireReleaseOnStart": True}},
                "grandfatherCutoff": cutoff,
            })
            env = dict(os.environ)
            env["AITEAMFORGE_BOARD_SETTINGS_CONFIG"] = str(cfg_path)
            result = _run_cli(["get", "academy"], env)
            assert result.returncode == 0, f"stderr: {result.stderr}"
            lines = result.stdout.strip().splitlines()
            printed = next(ln for ln in lines if ln.startswith("grandfatherCutoff="))
            expected_val = _normalize_grandfather_cutoff(cutoff) or ""
            assert printed == f"grandfatherCutoff={expected_val}", (
                f"cutoff {cutoff!r}: CLI printed {printed!r}, expected grandfatherCutoff={expected_val!r}"
            )
    print("PASS T20e: CLI `get` grandfatherCutoff= line matches the validator for every matrix entry")


# ─────────────────────────────────────────────────────────────────────────────
# T5 — Setter: atomic write, seeding, and every failure path
# ─────────────────────────────────────────────────────────────────────────────

#: A multi-team fixture, deliberately large enough to clear
#: _atomic_write_json's write-side plausibility floor (200 bytes,
#: XACA-1059-006) — a single-team fixture serializes under that floor and
#: would make the setter refuse for a reason unrelated to what these tests
#: are actually checking. See _MIN_PLAUSIBLE_REGISTRY_BYTES.
_MULTI_TEAM_FIXTURE = {
    "teams": {
        "academy": {"requireEpicOnStart": True, "requireReleaseOnStart": True},
        "ios": {"requireEpicOnStart": True, "requireReleaseOnStart": True},
        "android": {"requireEpicOnStart": True, "requireReleaseOnStart": True},
        "command": {"requireEpicOnStart": False, "requireReleaseOnStart": False},
    }
}


def test_t5_setter_writes_and_is_readable_back():
    """T5a: a successful set() is immediately visible through the fail-closed
    getters (cache is busted by the setter itself)."""
    with tempfile.TemporaryDirectory() as tmpdir:
        cfg_path = Path(tmpdir) / "runtime.json"
        _write_json(cfg_path, _MULTI_TEAM_FIXTURE)
        with _EnvOverride(str(cfg_path)):
            from aiteamforge_paths import (
                is_epic_required_for_team,
                is_release_required_for_team,
                set_board_settings_for_team,
            )

            ok = set_board_settings_for_team("academy", require_epic_on_start=False)
            assert ok is True
            assert is_epic_required_for_team("academy") is False
            assert is_release_required_for_team("academy") is True, "untouched key must be unchanged"
    print("PASS T5a: setter writes atomically and is immediately readable back")


def test_t5_setter_preserves_other_teams():
    """T5b: setting one team's booleans does not disturb any other team's block."""
    with tempfile.TemporaryDirectory() as tmpdir:
        cfg_path = Path(tmpdir) / "runtime.json"
        _write_json(cfg_path, _MULTI_TEAM_FIXTURE)
        with _EnvOverride(str(cfg_path)):
            from aiteamforge_paths import is_epic_required_for_team, set_board_settings_for_team

            ok = set_board_settings_for_team("academy", require_epic_on_start=False, require_release_on_start=False)
            assert ok is True
            assert is_epic_required_for_team("command") is False, "unrelated team must be unchanged"
    print("PASS T5b: setter leaves every other team's settings unchanged")


def test_t5_setter_seeds_from_committed_source_when_runtime_copy_absent():
    """T5c: when the target path does not exist yet, the setter seeds from the
    committed kanban-hooks/board_settings.json rather than dropping every other
    team's defaults."""
    with tempfile.TemporaryDirectory() as tmpdir:
        cfg_path = Path(tmpdir) / "does-not-exist-yet.json"  # no file written
        with _EnvOverride(str(cfg_path)):
            from aiteamforge_paths import is_epic_required_for_team, set_board_settings_for_team

            ok = set_board_settings_for_team("academy", require_epic_on_start=False)
            assert ok is True
            assert cfg_path.exists(), "setter must create the runtime file"
            # A team never touched by this call should still carry the shipped
            # default (true), proving the seed included the whole committed file.
            assert is_epic_required_for_team("ios") is True
            assert is_epic_required_for_team("command") is False, "shipped command seed must survive"
    print("PASS T5c: first-ever write seeds from the committed source, not from an empty skeleton")


def test_t5_setter_rejects_no_args():
    """T5d: calling set() with both booleans None fails (nothing to set) -> False,
    no exception."""
    with tempfile.TemporaryDirectory() as tmpdir:
        cfg_path = Path(tmpdir) / "runtime.json"
        with _EnvOverride(str(cfg_path)):
            from aiteamforge_paths import set_board_settings_for_team

            ok = set_board_settings_for_team("academy")
            assert ok is False
            assert not cfg_path.exists(), "a rejected no-op set() must not create a file"
    print("PASS T5d: set() with neither boolean provided -> False, no file created")


def test_t5_setter_rejects_empty_team_slug():
    """T5e: an empty/invalid team_slug -> False, no exception, no file written."""
    with tempfile.TemporaryDirectory() as tmpdir:
        cfg_path = Path(tmpdir) / "runtime.json"
        with _EnvOverride(str(cfg_path)):
            from aiteamforge_paths import set_board_settings_for_team

            assert set_board_settings_for_team("", require_epic_on_start=True) is False
            assert set_board_settings_for_team(None, require_epic_on_start=True) is False  # type: ignore[arg-type]
            assert not cfg_path.exists()
    print("PASS T5e: empty/None team_slug -> False, no file created")


def test_t5_setter_rejects_non_bool_value():
    """T5f: passing a non-bool value for either argument (e.g. the string 'true')
    -> False, no exception, no file written."""
    with tempfile.TemporaryDirectory() as tmpdir:
        cfg_path = Path(tmpdir) / "runtime.json"
        with _EnvOverride(str(cfg_path)):
            from aiteamforge_paths import set_board_settings_for_team

            assert set_board_settings_for_team("academy", require_epic_on_start="true") is False  # type: ignore[arg-type]
            assert not cfg_path.exists()
    print("PASS T5f: non-bool argument value -> False, no file created")


def test_t5_setter_write_failure_leaves_existing_file_untouched():
    """T5g: a write that fails (target directory not writable) returns False and
    the pre-existing file's content is byte-for-byte untouched. Skipped when
    running as root (root ignores unix permission bits)."""
    if os.geteuid() == 0:
        print("SKIP T5g: running as root, permission bits are not enforced")
        return
    with tempfile.TemporaryDirectory() as tmpdir:
        locked_dir = Path(tmpdir) / "locked"
        locked_dir.mkdir()
        cfg_path = locked_dir / "runtime.json"
        # Multi-team fixture (see _MULTI_TEAM_FIXTURE) so this failure is
        # actually caused by the permission block being asserted below, not
        # by the unrelated write-side plausibility floor tripping first on a
        # too-small payload.
        _write_json(cfg_path, _MULTI_TEAM_FIXTURE)
        before_bytes = cfg_path.read_bytes()
        os.chmod(locked_dir, 0o500)  # read+execute, no write -> can't create the tmp file for replace
        try:
            with _EnvOverride(str(cfg_path)):
                from aiteamforge_paths import set_board_settings_for_team

                ok = set_board_settings_for_team("academy", require_epic_on_start=False)
                assert ok is False, "a write blocked by permissions must report False, never True"
        finally:
            os.chmod(locked_dir, 0o700)  # restore so tempdir cleanup can delete it
        after_bytes = cfg_path.read_bytes()
        assert before_bytes == after_bytes, "a failed write must never partially modify the existing file"
    print("PASS T5g: write failure -> False, pre-existing file byte-for-byte untouched")


def test_t5_setter_lock_held_times_out():
    """T5h (XACA-1083-016): when the write lock is already held by another
    owner, set_board_settings_for_team() must time out and return False --
    never block forever, never write unlocked. Deterministic: the lock is
    held via a second, independent open() + flock() on the same lock path
    (a distinct lock owner even within this one process -- flock()
    contends per open-file-description, not per-process), and the setter's
    lock timeout is dialed down to a couple hundred ms so this test doesn't
    pay the production 5s timeout."""
    import fcntl

    import aiteamforge_paths as ap

    with tempfile.TemporaryDirectory() as tmpdir:
        cfg_path = Path(tmpdir) / "runtime.json"
        _write_json(cfg_path, _MULTI_TEAM_FIXTURE)
        before_bytes = cfg_path.read_bytes()
        lock_path = cfg_path.with_name(f"{cfg_path.name}.lock")

        holder = open(lock_path, "a")
        fcntl.flock(holder.fileno(), fcntl.LOCK_EX)
        old_timeout = ap._BOARD_SETTINGS_LOCK_TIMEOUT_SECONDS
        try:
            with _EnvOverride(str(cfg_path)):
                ap._BOARD_SETTINGS_LOCK_TIMEOUT_SECONDS = 0.2
                ok = ap.set_board_settings_for_team("academy", require_epic_on_start=False)
                assert ok is False, "a held lock must make the setter fail, not write unlocked"
                assert cfg_path.read_bytes() == before_bytes, (
                    "file must be byte-for-byte untouched when the lock could not be acquired"
                )
        finally:
            ap._BOARD_SETTINGS_LOCK_TIMEOUT_SECONDS = old_timeout
            fcntl.flock(holder.fileno(), fcntl.LOCK_UN)
            holder.close()
    print("PASS T5h: a held lock makes the setter time out and return False; file untouched")


def _t5i_worker(cfg_path_str: str, barrier, team_slug: str, key: str, value: bool, result_queue) -> None:
    """Child-process target for test_t5_setter_concurrent_writers_no_lost_update.
    Module-level (not a closure) so it is picklable for multiprocessing's
    'spawn' start method."""
    sys.path.insert(0, str(_KANBAN_HOOKS))
    os.environ["AITEAMFORGE_BOARD_SETTINGS_CONFIG"] = cfg_path_str
    from aiteamforge_paths import bust_board_settings_cache, set_board_settings_for_team

    bust_board_settings_cache()
    barrier.wait()  # release every worker at (as close as the OS allows to) the same instant
    ok = set_board_settings_for_team(team_slug, **{key: value})
    result_queue.put((team_slug, key, value, ok))


def test_t5_setter_concurrent_writers_no_lost_update():
    """T5i (XACA-1083-016): several OS processes toggle DIFFERENT teams'/
    keys' settings against the SAME shared board_settings.json at (as
    close as multiprocessing.Barrier can make it) the same instant. Every
    writer's update must land -- none may be lost to an unlocked
    read-modify-write race. Synchronized with a Barrier, not a sleep, so
    this is deterministic rather than a timing-dependent race for the test
    itself to win."""
    import multiprocessing

    with tempfile.TemporaryDirectory() as tmpdir:
        cfg_path = Path(tmpdir) / "runtime.json"
        # Seed from the real committed schema (11 teams + comments), not a
        # bare skeleton -- _atomic_write_json's XACA-1059-006 plausibility
        # floor refuses to write anything under 200 bytes, and a
        # few-teams-only skeleton is too small to survive that floor once
        # only ONE team's block has been toggled by a given worker.
        shipped = json.loads((_KANBAN_HOOKS / "board_settings.json").read_text(
            encoding="utf-8"
        ))
        # Strip the (irrelevant, purely descriptive) "_comment" key so the
        # fixture isn't accidentally coupled to its prose changing later;
        # the 11-team "teams" block alone is already well over the floor.
        shipped.pop("_comment", None)
        _write_json(cfg_path, shipped)

        jobs = [
            ("academy", "require_epic_on_start", False),
            ("ios", "require_release_on_start", False),
            ("android", "require_epic_on_start", False),
            ("firebase", "require_release_on_start", False),
            ("command", "require_epic_on_start", False),
            ("dns", "require_release_on_start", False),
        ]
        _KEY_TO_JSON_FIELD = {
            "require_epic_on_start": "requireEpicOnStart",
            "require_release_on_start": "requireReleaseOnStart",
        }

        ctx = multiprocessing.get_context("spawn")
        barrier = ctx.Barrier(len(jobs))
        result_queue = ctx.Queue()
        procs = [
            ctx.Process(target=_t5i_worker, args=(str(cfg_path), barrier, team, key, value, result_queue))
            for team, key, value in jobs
        ]
        for p in procs:
            p.start()
        for p in procs:
            p.join(timeout=30)
            assert not p.is_alive(), f"worker for {p} did not finish within 30s"
            assert p.exitcode == 0, f"worker process exited abnormally: {p.exitcode}"

        results = [result_queue.get_nowait() for _ in jobs]
        for team, key, value, ok in results:
            assert ok is True, f"{team}.{key} write reported failure"

        final = json.loads(cfg_path.read_text(encoding="utf-8"))
        for team, key, value in jobs:
            json_field = _KEY_TO_JSON_FIELD[key]
            got = final.get("teams", {}).get(team, {}).get(json_field)
            assert got == value, f"lost update: {team}.{json_field} expected {value!r}, got {got!r}"
    print(f"PASS T5i: {len(jobs)} concurrent cross-process writers to different teams/keys -- no lost update")


# ─────────────────────────────────────────────────────────────────────────────
# T6 — CLI contract
# ─────────────────────────────────────────────────────────────────────────────

def _run_cli(args: list[str], env: dict) -> subprocess.CompletedProcess:
    cli_path = str(_KANBAN_HOOKS / "board_settings.py")
    return subprocess.run(
        [sys.executable, cli_path, *args],
        capture_output=True,
        text=True,
        env=env,
        timeout=30,
    )


def test_t6_cli_get_prints_expected_lines_and_exits_0():
    """T6a: `get <team>` prints the 5 documented key=value lines, in order, exit 0."""
    with tempfile.TemporaryDirectory() as tmpdir:
        cfg_path = Path(tmpdir) / "cfg.json"
        _write_json(cfg_path, {
            "teams": {"academy": {"requireEpicOnStart": True, "requireReleaseOnStart": False}},
            "grandfatherCutoff": "2026-09-25T00:00:00Z",
            "creationTimestampField": "addedAt",
        })
        env = dict(os.environ)
        env["AITEAMFORGE_BOARD_SETTINGS_CONFIG"] = str(cfg_path)
        result = _run_cli(["get", "academy"], env)
        assert result.returncode == 0, f"stderr: {result.stderr}"
        lines = result.stdout.strip().splitlines()
        assert lines == [
            "team=academy",
            "requireEpicOnStart=true",
            "requireReleaseOnStart=false",
            "grandfatherCutoff=2026-09-25T00:00:00Z",
            "creationTimestampField=addedAt",
        ], f"unexpected output: {lines}"
    print("PASS T6a: `get` CLI output matches the documented contract exactly")


def test_t6_cli_get_unknown_team_still_exits_0_fail_closed():
    """T6b: `get` on an unknown team still exits 0 and reports both gates true
    (fail-closed never surfaces as a CLI error)."""
    with tempfile.TemporaryDirectory() as tmpdir:
        cfg_path = Path(tmpdir) / "cfg.json"
        _write_json(cfg_path, {"teams": {}})
        env = dict(os.environ)
        env["AITEAMFORGE_BOARD_SETTINGS_CONFIG"] = str(cfg_path)
        result = _run_cli(["get", "totally-unknown-team"], env)
        assert result.returncode == 0, f"stderr: {result.stderr}"
        assert "requireEpicOnStart=true" in result.stdout
        assert "requireReleaseOnStart=true" in result.stdout
    print("PASS T6b: `get` on unknown team exits 0 with fail-closed true/true")


def test_t6_cli_set_success_exits_0():
    """T6c: `set <team> --require-epic false` exits 0, prints OK, and the change
    is durable (readable back via a fresh `get` subprocess)."""
    with tempfile.TemporaryDirectory() as tmpdir:
        cfg_path = Path(tmpdir) / "runtime.json"
        _write_json(cfg_path, _MULTI_TEAM_FIXTURE)
        env = dict(os.environ)
        env["AITEAMFORGE_BOARD_SETTINGS_CONFIG"] = str(cfg_path)

        set_result = _run_cli(["set", "academy", "--require-epic", "false"], env)
        assert set_result.returncode == 0, f"stderr: {set_result.stderr}"
        assert "OK team=academy" in set_result.stdout

        get_result = _run_cli(["get", "academy"], env)
        assert "requireEpicOnStart=false" in get_result.stdout
    print("PASS T6c: `set` CLI writes durably; a fresh `get` subprocess sees the change")


def test_t6_cli_set_no_flags_exits_2():
    """T6d: `set <team>` with neither flag is a usage error, exit 2, nothing written."""
    with tempfile.TemporaryDirectory() as tmpdir:
        cfg_path = Path(tmpdir) / "runtime.json"
        env = dict(os.environ)
        env["AITEAMFORGE_BOARD_SETTINGS_CONFIG"] = str(cfg_path)
        result = _run_cli(["set", "academy"], env)
        assert result.returncode == 2, f"expected exit 2, got {result.returncode}: {result.stderr}"
        assert not cfg_path.exists()
    print("PASS T6d: `set` with no flags -> exit 2, no file created")


def test_t6_cli_set_bad_bool_value_exits_2():
    """T6e: `set <team> --require-epic maybe` (unrecognized value) -> exit 2."""
    with tempfile.TemporaryDirectory() as tmpdir:
        cfg_path = Path(tmpdir) / "runtime.json"
        env = dict(os.environ)
        env["AITEAMFORGE_BOARD_SETTINGS_CONFIG"] = str(cfg_path)
        result = _run_cli(["set", "academy", "--require-epic", "maybe"], env)
        assert result.returncode == 2, f"expected exit 2, got {result.returncode}: {result.stderr}"
        assert not cfg_path.exists()
    print("PASS T6e: `set` with an unrecognized boolean spelling -> exit 2, no file created")


def test_t6_cli_missing_team_arg_is_usage_error():
    """T6f: `get` with no team argument is an argparse usage error (exit 2)."""
    env = dict(os.environ)
    result = _run_cli(["get"], env)
    assert result.returncode == 2, f"expected exit 2, got {result.returncode}"
    print("PASS T6f: `get` with no team argument -> exit 2 (argparse usage error)")


# ─────────────────────────────────────────────────────────────────────────────
# Test runner
# ─────────────────────────────────────────────────────────────────────────────

def run_all() -> bool:
    tests = [
        # T1
        test_t1_import_aiteamforge_paths,
        test_t1_import_board_settings,
        test_t1_board_settings_py_syntax,
        test_t1_aiteamforge_paths_py_syntax,
        # T2
        test_t2_shipped_config_has_11_teams,
        test_t2_shipped_config_validates_clean,
        test_t2_shipped_config_command_seeded_false,
        test_t2_grandfather_cutoff_and_field_shipped,
        # T3
        test_t3_missing_file_resolves_true,
        test_t3_malformed_json_resolves_true,
        test_t3_non_dict_root_resolves_true,
        test_t3_unknown_team_resolves_true,
        test_t3_team_block_not_dict_resolves_true,
        test_t3_non_dict_teams_resolves_true,
        test_t3_missing_key_resolves_true,
        test_t3_non_boolean_values_resolve_true,
        test_t3_unreadable_file_resolves_true,
        # T4
        test_t4_missing_cutoff_never_grandfathers,
        test_t4_malformed_cutoff_never_grandfathers,
        test_t4_valid_cutoff_exempts_earlier_items,
        test_t4_valid_cutoff_does_not_exempt_later_or_equal_items,
        test_t4_missing_or_malformed_created_at_never_grandfathers,
        test_t4_creation_timestamp_field_falls_back_to_addedAt,
        test_t4_trailing_z_and_naive_timestamps_normalize_to_utc,
        # T20
        test_t20_normalize_grandfather_cutoff_matches_shell_matrix,
        test_t20_cross_layer_shell_parity,
        test_t20_get_board_settings_grandfather_cutoff_returns_validated_value,
        test_t20_is_item_grandfathered_never_exempts_a_shell_rejected_cutoff,
        test_t20_cli_get_grandfather_cutoff_matches_validator,
        # T5
        test_t5_setter_writes_and_is_readable_back,
        test_t5_setter_preserves_other_teams,
        test_t5_setter_seeds_from_committed_source_when_runtime_copy_absent,
        test_t5_setter_rejects_no_args,
        test_t5_setter_rejects_empty_team_slug,
        test_t5_setter_rejects_non_bool_value,
        test_t5_setter_write_failure_leaves_existing_file_untouched,
        test_t5_setter_lock_held_times_out,
        test_t5_setter_concurrent_writers_no_lost_update,
        # T6
        test_t6_cli_get_prints_expected_lines_and_exits_0,
        test_t6_cli_get_unknown_team_still_exits_0_fail_closed,
        test_t6_cli_set_success_exits_0,
        test_t6_cli_set_no_flags_exits_2,
        test_t6_cli_set_bad_bool_value_exits_2,
        test_t6_cli_missing_team_arg_is_usage_error,
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
    print(f"XACA-1083-001 Test Results: {passed}/{total} passed")
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
