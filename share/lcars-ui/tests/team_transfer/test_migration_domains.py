"""Tests for the per-domain inventory modules — synthetic dirs, no production state."""
from __future__ import annotations

import json
from pathlib import Path

import pytest

from team_transfer import channels, domain_devteam, domain_kanban, domain_knowledge
from team_transfer.checksum import is_excluded
from team_transfer.manifest import EXACT, PRESENT, SCHEMA, new_manifest


# Synthetic team config used throughout; mirrors the finance.yaml defaults so that
# domain_kanban can populate board probes (ticket_prefix, board_filename).
_FINANCE_TEAM_CONFIG = channels.load_team_config("finance")


def test_excluded_paths_skipped():
    assert is_excluded(Path("/x/.venv/lib/foo.py"))
    assert is_excluded(Path("/x/__pycache__/y.pyc"))
    assert is_excluded(Path("/x/foo.pyc"))
    assert is_excluded(Path("/x/.DS_Store"))
    assert is_excluded(Path("/x/board.json.lock"))
    assert not is_excluded(Path("/x/CHANGELOG.md"))
    assert not is_excluded(Path("/x/src/y.py"))


def test_kanban_inventory_tags_board_as_schema(tmp_path, monkeypatch):
    # Synthetic repo with a kanban board containing a couple of items.
    repo = tmp_path / "repo"
    (repo / "kanban").mkdir(parents=True)
    # Use the board_filename from the finance team config as the canonical fixture name.
    board_filename = _FINANCE_TEAM_CONFIG["board_filename"]
    ticket_prefix = _FINANCE_TEAM_CONFIG["ticket_prefix"]
    board = {"items": [{"id": f"{ticket_prefix}0001"}, {"id": f"{ticket_prefix}0002"}]}
    (repo / "kanban" / board_filename).write_text(json.dumps(board))
    (repo / "kanban" / f"{ticket_prefix}0001_plan.md").write_text("# plan")

    cfg = channels.build_config(home=tmp_path)
    # Force kanban path to map to export by inserting a rule for the synthetic root.
    cfg.rules.append(channels.ChannelRule(f"{repo}/kanban/*", channels.EXPORT))
    cfg.rules.append(channels.ChannelRule(f"{repo}/kanban/**", channels.EXPORT))

    m = new_manifest()
    domain_kanban.inventory(repo, m, cfg, home=tmp_path, team_config=_FINANCE_TEAM_CONFIG)

    files = m.domains["kanban"].files
    board_entries = [fe for fe in files if fe.path.endswith("board.json")]
    assert len(board_entries) == 1
    assert board_entries[0].cls == SCHEMA
    assert board_entries[0].probe is not None
    assert f"{ticket_prefix}0001" in board_entries[0].probe["item_ids"]
    plan_entries = [fe for fe in files if fe.path.endswith(".md")]
    assert plan_entries[0].cls == EXACT


def test_devteam_inventory_walks_files(tmp_path):
    devteam = tmp_path / "dt"
    devteam.mkdir()
    (devteam / "personas").mkdir()
    (devteam / "personas" / "p.md").write_text("persona")
    (devteam / "scripts").mkdir()
    (devteam / "scripts" / "s.sh").write_text("#!/bin/sh\necho hi\n")

    cfg = channels.build_config(home=tmp_path)
    cfg.rules.append(channels.ChannelRule(f"{devteam}/*", channels.AITEAMFORGE))
    cfg.rules.append(channels.ChannelRule(f"{devteam}/**", channels.AITEAMFORGE))

    m = new_manifest()
    domain_devteam.inventory(m, cfg, root=devteam, home=tmp_path)

    files = m.domains["devteam"].files
    paths = {Path(fe.path).name for fe in files}
    assert paths == {"p.md", "s.sh"}
    for fe in files:
        assert fe.channel == channels.AITEAMFORGE
        assert fe.cls == EXACT
        assert fe.sha256 is not None


def test_devteam_handles_missing_root(tmp_path):
    cfg = channels.build_config(home=tmp_path)
    m = new_manifest()
    # Should not raise on missing dir
    domain_devteam.inventory(m, cfg, root=tmp_path / "does-not-exist", home=tmp_path)
    # Domain entry exists but is empty (or absent)
    assert "devteam" not in m.domains or m.domains["devteam"].files == []


def test_knowledge_inventory_picks_up_persona_dirs(tmp_path):
    home = tmp_path
    knowledge = home / "knowledge"
    (knowledge / "agents" / "quark").mkdir(parents=True)
    (knowledge / "agents" / "quark" / "k001-tip.md").write_text("# tip")
    (knowledge / "agents" / "rom").mkdir(parents=True)
    (knowledge / "agents" / "rom" / "k001-pattern.md").write_text("# pattern")

    cfg = channels.build_config(home=home)
    m = new_manifest()
    domain_knowledge.inventory(
        m, cfg,
        knowledge_root=knowledge,
        repo_root=home / "finance" / "personal",
        home=home,
    )

    files = m.domains["knowledge"].files
    paths = {fe.relpath for fe in files}
    assert any("knowledge/agents/quark/k001-tip.md" in p for p in paths)
    assert any("knowledge/agents/rom/k001-pattern.md" in p for p in paths)
