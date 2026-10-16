"""Pytest configuration for team_transfer tests.

Adds lcars-ui/ to sys.path so that ``from team_transfer.X import ...`` works
without a package install. The lcars-ui directory name contains a hyphen and
is therefore not importable as a Python package; sys.path manipulation is the
correct pattern here.
"""
import sys
from pathlib import Path

# lcars-ui/ is the grandparent of this file:
#   lcars-ui/tests/team_transfer/conftest.py  ->  lcars-ui/
LCARS_UI = Path(__file__).resolve().parents[2]

if str(LCARS_UI) not in sys.path:
    sys.path.insert(0, str(LCARS_UI))


import pytest


@pytest.fixture(autouse=True)
def _isolate_team_transfer_overlay(tmp_path_factory, monkeypatch):
    """XACA-1337-016: channels.load_team_config() searches a per-machine overlay
    dir (default ~/.aiteamforge/team_transfer/config/). Point it at a path that
    does not exist so no test reads the developer's real overlay. Tests that
    exercise the overlay override this with their own monkeypatch.setenv."""
    missing = tmp_path_factory.mktemp("no-tt-overlay") / "absent"
    monkeypatch.setenv("AITEAMFORGE_TEAM_TRANSFER_CONFIG_DIR", str(missing))
