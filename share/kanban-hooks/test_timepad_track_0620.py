#!/usr/bin/env python3
"""
test_timepad_track_0620.py — Unit tests for the XACA-0620 TimePad dispatcher.

Covers the dormant code path that XACA-0623 will eventually flip live:
  D1 — team resolution (longest-prefix match against working_dir)
  D2 — enable-gate short-circuit (disabled team -> no resolution, no API)
  D3 — placeholder no-op (config still <fetch-from-timepad.io> -> no token call)
  D4 — kanban item resolution (padding-insensitive _parse_ticket + describe)
  D5 — classifier names (timepad_tags)

The dispatcher lives at timepad-track.py (hyphenated -> loaded via importlib).
It binds its accessor functions with `from aiteamforge_paths import ...`, so the
tests monkeypatch the names ON THE DISPATCHER MODULE to inject hermetic doubles
(no live board, no vault, no network).

Run:
    cd kanban-hooks && python3 test_timepad_track_0620.py
"""
from __future__ import annotations

import importlib.util
import json
import os
import sys
import tempfile
from pathlib import Path

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)


def _load_dispatcher():
    """Load timepad-track.py as a module without firing main() (it is __main__-guarded)."""
    spec = importlib.util.spec_from_file_location("tt", os.path.join(_HERE, "timepad-track.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


tt = _load_dispatcher()


class _Restore:
    """Context manager that monkeypatches tt attributes and restores them after."""

    def __init__(self, **overrides):
        self.overrides = overrides
        self.saved = {}

    def __enter__(self):
        for k, v in self.overrides.items():
            self.saved[k] = getattr(tt, k)
            setattr(tt, k, v)
        return self

    def __exit__(self, *exc):
        for k, v in self.saved.items():
            setattr(tt, k, v)
        return False


# ─────────────────────────────────────────────────────────────────────────────
# D1 — team resolution (longest-prefix)
# ─────────────────────────────────────────────────────────────────────────────

def test_d1_longest_prefix_wins():
    """A nested working_dir beats a shorter ancestor when both are enabled."""
    with tempfile.TemporaryDirectory() as root:
        outer = os.path.join(root, "outer")
        inner = os.path.join(root, "outer", "inner")
        os.makedirs(inner)
        repo = os.path.join(inner, "repo")
        os.makedirs(repo)
        wd = {"outer_team": outer, "inner_team": inner}
        with _Restore(
            list_teams=lambda: list(wd.keys()),
            get_team_working_dir=lambda t: wd[t],
            is_timepad_enabled=lambda t: True,
        ):
            assert tt.resolve_team(repo) == "inner_team"
    print("PASS D1a: longest-prefix working_dir wins")


def test_d1_no_match_returns_none():
    """A repo under no team's working_dir resolves to None."""
    with tempfile.TemporaryDirectory() as root:
        wd = {"team_a": os.path.join(root, "a")}
        os.makedirs(wd["team_a"])
        other = os.path.join(root, "elsewhere")
        os.makedirs(other)
        with _Restore(
            list_teams=lambda: list(wd.keys()),
            get_team_working_dir=lambda t: wd[t],
            is_timepad_enabled=lambda t: True,
        ):
            assert tt.resolve_team(other) is None
    print("PASS D1b: no working_dir prefix -> None")


def test_d1_empty_repo_root_returns_none():
    """An empty repo root (not a git repo) resolves to None without raising."""
    assert tt.resolve_team("") is None
    print("PASS D1c: empty repo root -> None")


# ─────────────────────────────────────────────────────────────────────────────
# D2 — enable-gate short-circuit
# ─────────────────────────────────────────────────────────────────────────────

def test_d2_disabled_team_skipped_in_resolution():
    """A disabled team is never returned even when its working_dir matches."""
    with tempfile.TemporaryDirectory() as root:
        wd = {"only_team": os.path.join(root, "w")}
        os.makedirs(wd["only_team"])
        repo = os.path.join(wd["only_team"], "repo")
        os.makedirs(repo)
        with _Restore(
            list_teams=lambda: list(wd.keys()),
            get_team_working_dir=lambda t: wd[t],
            is_timepad_enabled=lambda t: False,  # disabled
        ):
            assert tt.resolve_team(repo) is None
    print("PASS D2a: disabled team skipped -> None")


def test_d2_main_noop_when_no_enabled_team():
    """main() returns BEFORE touching config/token when no enabled team owns the repo."""
    calls = {"cfg": 0, "token": 0}

    def _cfg(_t):
        calls["cfg"] += 1
        return {}

    def _token(*a, **k):
        calls["token"] += 1
        raise AssertionError("token resolution must not run when no team is enabled")

    with _Restore(
        ACTION="start",
        resolve_repo_root=lambda: "/tmp/does-not-matter",
        resolve_team=lambda _r: None,
        get_timepad_team_config=_cfg,
        resolve_timepad_token=_token,
    ):
        tt.main()  # must not raise
    assert calls == {"cfg": 0, "token": 0}, calls
    print("PASS D2b: main() no-ops (no config/token) when no enabled team")


# ─────────────────────────────────────────────────────────────────────────────
# D3 — placeholder no-op
# ─────────────────────────────────────────────────────────────────────────────

def test_d3_placeholder_blocks_token_and_api():
    """An enabled team whose config still has placeholders must NOT resolve a token."""
    token_called = {"n": 0}

    def _token(*a, **k):
        token_called["n"] += 1
        raise AssertionError("token resolution must not run while placeholders remain")

    with _Restore(
        ACTION="start",
        resolve_repo_root=lambda: "/tmp/repo",
        resolve_team=lambda _r: "academy",
        get_timepad_team_config=lambda _t: {
            "apiBaseUrl": "https://timepad.io/api",
            "tokenRef": "TIMEPAD_API_KEY",
            "projectId": "<fetch-from-timepad.io>",
            "tagId": "<fetch-from-timepad.io>",
        },
        timepad_team_has_placeholders=lambda _t: True,  # not configured yet
        resolve_timepad_token=_token,
    ):
        tt.main()  # must not raise
    assert token_called["n"] == 0
    print("PASS D3a: placeholder config -> no token resolution / no API call")


# ─────────────────────────────────────────────────────────────────────────────
# D4 — kanban item resolution
# ─────────────────────────────────────────────────────────────────────────────

def test_d4_parse_ticket_padding_insensitive():
    assert tt._parse_ticket("feature/xaca-620") == ("XACA", 620)
    assert tt._parse_ticket("feature/XACA-0620") == ("XACA", 620)
    assert tt._parse_ticket("bugfix/xbwa-7") == ("XBWA", 7)
    assert tt._parse_ticket("develop") is None
    print("PASS D4a: _parse_ticket is padding-insensitive, None on no match")


def test_d4_describe_resolves_board_title():
    """describe() reads <kanban_dir>/<team>-board.json and returns '[ID] title'."""
    with tempfile.TemporaryDirectory() as kd:
        board = {"backlog": [{"id": "FOO-0042", "title": "The Answer"}]}
        with open(os.path.join(kd, "demo-board.json"), "w") as f:
            json.dump(board, f)
        os.environ["TT_BRANCH"] = "feature/foo-42"
        with _Restore(get_team_kanban_dir=lambda _t: kd):
            desc, coordination = tt.describe("demo")
        assert desc == "[FOO-0042] The Answer", desc
        assert coordination is False
    print("PASS D4b: describe() resolves real board title, coordination=False")


def test_d4_describe_bare_branch_is_coordination():
    """A bare branch with no ticket -> '<team> — <branch>' and coordination=True."""
    os.environ["TT_BRANCH"] = "develop"
    desc, coordination = tt.describe("demo")
    assert desc == "demo — develop", desc
    assert coordination is True
    print("PASS D4c: bare branch -> coordination=True")


# ─────────────────────────────────────────────────────────────────────────────
# D5 — classifier
# ─────────────────────────────────────────────────────────────────────────────

def test_d5_classifier_names():
    import timepad_tags
    assert "Development" in timepad_tags.classify_names("refactor the dispatcher hook")
    assert timepad_tags.classify_names("coordinate planning", coordination=True) == ["Admin"]
    # default fallback (no keyword, not coordination) -> Development
    assert timepad_tags.classify_names("zzz", coordination=False) == ["Development"]
    print("PASS D5a: classifier returns expected category names")


def run_all():
    tests = [
        test_d1_longest_prefix_wins,
        test_d1_no_match_returns_none,
        test_d1_empty_repo_root_returns_none,
        test_d2_disabled_team_skipped_in_resolution,
        test_d2_main_noop_when_no_enabled_team,
        test_d3_placeholder_blocks_token_and_api,
        test_d4_parse_ticket_padding_insensitive,
        test_d4_describe_resolves_board_title,
        test_d4_describe_bare_branch_is_coordination,
        test_d5_classifier_names,
    ]
    passed = failed = 0
    failures: list[str] = []
    for fn in tests:
        try:
            fn()
            passed += 1
        except Exception as exc:
            failed += 1
            failures.append(f"FAIL {fn.__name__}: {exc}")
            print(f"FAIL {fn.__name__}: {exc}")
    total = passed + failed
    print(f"\n{'='*60}")
    print(f"XACA-0620 dispatcher Test Results: {passed}/{total} passed")
    if failures:
        print("\nFAILURES:")
        for f in failures:
            print(f"  {f}")
    else:
        print("All tests passed.")
    print(f"{'='*60}")
    return failed == 0


if __name__ == "__main__":
    sys.exit(0 if run_all() else 1)
