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
    # XACA-0496: SQLite WAL/SHM sidecars must be excluded. They are transient
    # state regenerated when the database is reopened on the destination, and
    # they tripped XACA-0488's new export_database channel-class invariant
    # (which requires cls=schema) because they naturally fall into cls=present.
    assert is_excluded(Path("/x/data/finance.db-wal"))
    assert is_excluded(Path("/x/data/finance.db-shm"))
    assert not is_excluded(Path("/x/data/finance.db"))  # the db itself MUST stay
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
        # ADR §3.2: aiteamforge_product files must use PRESENT (installer mutates them
        # on destination; EXACT would produce false-FAILs after any update).
        assert fe.cls == PRESENT
        assert fe.sha256 is None


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
    # XACA-0954-003: personas must be explicit now — the legacy
    # _LEGACY_FINANCE_PERSONAS guess-fallback was removed.
    domain_knowledge.inventory(
        m, cfg,
        knowledge_root=knowledge,
        repo_root=home / "finance" / "personal",
        home=home,
        team_config={"team": "finance", "personas": ["quark", "rom"]},
    )

    files = m.domains["knowledge"].files
    paths = {fe.relpath for fe in files}
    assert any("knowledge/agents/quark/k001-tip.md" in p for p in paths)
    assert any("knowledge/agents/rom/k001-pattern.md" in p for p in paths)
    # No gap recorded — personas key was present and the (single, override)
    # knowledge_root existed.
    assert m.missing_roots == []


def test_knowledge_inventory_gaps_when_personas_key_absent(tmp_path):
    """No `personas` key in team_config -> fail loud, never guess a persona list."""
    home = tmp_path
    knowledge = home / "knowledge"
    (knowledge / "agents" / "quark").mkdir(parents=True)
    (knowledge / "agents" / "quark" / "k001-tip.md").write_text("# tip")

    cfg = channels.build_config(home=home)
    m = new_manifest()
    domain_knowledge.inventory(
        m, cfg,
        knowledge_root=knowledge,
        repo_root=home / "finance" / "personal",
        home=home,
        team_config={"team": "finance"},  # no "personas" key
    )

    # Nothing guessed/scanned for the agent tier.
    files = m.domains.get("knowledge")
    paths = {fe.relpath for fe in files.files} if files else set()
    assert not any("agents/quark" in p for p in paths)

    # A gap was recorded instead of silently returning an empty block.
    gap_domains = {g["domain"] for g in m.missing_roots}
    assert domain_knowledge.DOMAIN in gap_domains
    personas_gaps = [g for g in m.missing_roots if g["config_key"] == "personas"]
    assert len(personas_gaps) == 1


def test_knowledge_inventory_empty_personas_list_is_not_a_gap(tmp_path):
    """`personas: []` is a deliberate declaration of "no personas" — not a gap."""
    home = tmp_path
    knowledge = home / "knowledge"
    knowledge.mkdir(parents=True)

    cfg = channels.build_config(home=home)
    m = new_manifest()
    domain_knowledge.inventory(
        m, cfg,
        knowledge_root=knowledge,
        repo_root=home / "finance" / "personal",
        home=home,
        team_config={"team": "finance", "personas": []},
    )

    assert m.missing_roots == []
    blk = m.domains.get("knowledge")
    assert blk is not None
    assert blk.stats["personas_inventoried"] == []


# ── XACA-0954-007: devteam missing-root vs genuinely-empty distinction ───────

def test_devteam_missing_product_dir_via_team_config_records_gap(tmp_path):
    """A configured product_dir that does not exist must be recorded via
    add_missing_root with config_key="product_dir" -- this is the whole point
    of the fail-loud fix (previously indistinguishable from an empty domain).
    """
    home = tmp_path
    cfg = channels.build_config(home=home)
    m = new_manifest()
    team_config = {"team": "ghost", "product_dir": "ghost_team"}

    domain_devteam.inventory(m, cfg, home=home, team_config=team_config)

    assert m.domains["devteam"].files == []
    gaps = [g for g in m.missing_roots if g["domain"] == domain_devteam.DOMAIN]
    assert len(gaps) == 1
    assert gaps[0]["config_key"] == "product_dir"
    assert gaps[0]["path"] == str(home / "dev-team" / "ghost_team")


def test_devteam_existing_but_empty_product_dir_is_not_a_gap(tmp_path):
    """The DISTINCTION that is the entire fix: a product_dir that EXISTS but
    happens to hold zero files must produce the same "0 files" result as the
    missing-root case above, WITHOUT a missing_roots entry. Only absence of
    the directory itself is a gap; genuine emptiness is not.
    """
    home = tmp_path
    (home / "dev-team" / "real_but_empty").mkdir(parents=True)
    cfg = channels.build_config(home=home)
    m = new_manifest()
    team_config = {"team": "real", "product_dir": "real_but_empty"}

    domain_devteam.inventory(m, cfg, home=home, team_config=team_config)

    assert m.domains["devteam"].files == []
    gaps = [g for g in m.missing_roots if g["domain"] == domain_devteam.DOMAIN]
    assert gaps == [], "an existing-but-empty root must NOT be reported as a missing root"


def test_devteam_persona_dirs_are_walked_and_missing_entry_recorded(tmp_path):
    """persona_dirs entries are walked like the product root, and a missing
    persona_dirs entry is recorded with its own config_key="persona_dirs" --
    independent of whether the product root itself resolved fine.
    """
    home = tmp_path
    product_root = home / "dev-team" / "producty"
    product_root.mkdir(parents=True)

    persona_root = home / "producty_personas"
    persona_root.mkdir(parents=True)
    (persona_root / "avatar.png").write_bytes(b"fake-png")

    cfg = channels.build_config(home=home)
    m = new_manifest()
    team_config = {
        "team": "producty",
        "product_dir": "producty",
        "persona_dirs": [
            "{home}/producty_personas",
            "{home}/producty_personas_MISSING",
        ],
    }

    domain_devteam.inventory(m, cfg, home=home, team_config=team_config)

    files = m.domains["devteam"].files
    names = {Path(fe.path).name for fe in files}
    assert "avatar.png" in names, "existing persona_dirs entry must be walked"

    # product root resolved fine -- only the persona_dirs entry is missing.
    assert m.missing_roots == [
        {
            "domain": domain_devteam.DOMAIN,
            "path": str(home / "producty_personas_MISSING"),
            "reason": (
                "configured persona_dirs entry does not exist; nothing from "
                "this path will be exported"
            ),
            "config_key": "persona_dirs",
        }
    ]


def test_devteam_persona_dir_nested_in_product_root_not_double_counted(tmp_path):
    """A persona_dirs entry that IS the product root, or nested inside it,
    must be walked exactly once (product-root pass wins) -- not double-counted
    as a second pass over the same files.
    """
    home = tmp_path
    product_root = home / "dev-team" / "nested_team"
    (product_root / "personas").mkdir(parents=True)
    (product_root / "personas" / "p.md").write_text("persona")

    cfg = channels.build_config(home=home)
    m = new_manifest()
    team_config = {
        "team": "nested_team",
        "product_dir": "nested_team",
        # Both the product root itself AND a subdirectory nested inside it.
        "persona_dirs": [
            "{home}/dev-team/nested_team",
            "{home}/dev-team/nested_team/personas",
        ],
    }

    domain_devteam.inventory(m, cfg, home=home, team_config=team_config)

    files = m.domains["devteam"].files
    matching = [fe for fe in files if fe.path.endswith("p.md")]
    assert len(matching) == 1, "nested persona_dirs entry must not double-count files already walked"
    assert m.missing_roots == []


# ── XACA-0954-007: domain_knowledge legacy-list removal + multi-root coverage ─

def test_knowledge_legacy_persona_names_are_never_scanned_when_personas_empty(tmp_path):
    """Regression pin for the removed `_LEGACY_FINANCE_PERSONAS` fallback: even
    when directories named after the old hardcoded guesses (quark, nog, brunt,
    rom, zek) exist on disk, an explicit `personas: []` must scan NONE of them.
    """
    home = tmp_path
    knowledge = home / "knowledge"
    for legacy_name in ("quark", "nog", "brunt", "rom", "zek"):
        d = knowledge / "agents" / legacy_name
        d.mkdir(parents=True)
        (d / "k001-tip.md").write_text("# tip")

    cfg = channels.build_config(home=home)
    m = new_manifest()
    domain_knowledge.inventory(
        m, cfg,
        knowledge_root=knowledge,
        repo_root=home / "somewhere" / "personal",
        home=home,
        team_config={"team": "not-finance", "personas": []},
    )

    files = m.domains.get("knowledge")
    paths = {fe.relpath for fe in files.files} if files else set()
    for legacy_name in ("quark", "nog", "brunt", "rom", "zek"):
        assert not any(f"agents/{legacy_name}" in p for p in paths), (
            f"legacy persona {legacy_name!r} must never be scanned without an explicit personas entry"
        )
    assert m.missing_roots == []


def test_knowledge_persona_only_in_knowledge_local_is_inventoried(tmp_path):
    """XACA-0754: PII-scoped personas live in ~/knowledge-local, not the
    shared ~/knowledge tree. With NO explicit knowledge_root/knowledge_roots
    override (default multi-root behavior), a persona present ONLY in
    knowledge-local must still be found -- and its absence from the default
    ~/knowledge root must NOT be reported as a gap (default roots that don't
    exist are expected, not a failure).
    """
    home = tmp_path
    local = home / "knowledge-local"
    (local / "agents" / "quark-fin").mkdir(parents=True)
    (local / "agents" / "quark-fin" / "k001-tip.md").write_text("# tip")
    # NOTE: home / "knowledge" (the shared default root) is intentionally NOT created.

    cfg = channels.build_config(home=home)
    m = new_manifest()
    domain_knowledge.inventory(
        m, cfg,
        repo_root=home / "finance" / "personal",
        home=home,
        team_config={"team": "finance", "personas": ["quark-fin"]},
        # knowledge_root / knowledge_roots both omitted -> default [~/knowledge, ~/knowledge-local]
    )

    files = m.domains["knowledge"].files
    paths = {fe.relpath for fe in files}
    assert any("knowledge-local/agents/quark-fin/k001-tip.md" in p for p in paths)
    assert m.missing_roots == [], "a missing DEFAULT root (~/knowledge) must not be reported as a gap"
    blk = m.domains["knowledge"]
    assert blk.stats["personas_not_found"] == []


def test_knowledge_exact_same_path_scanned_twice_is_not_duplicated(tmp_path):
    """The dedup guard (_emit_dedup) exists specifically to catch the SAME
    absolute path being walked twice (e.g. overlapping root configuration) --
    as opposed to two DISTINCT files that merely share a persona name across
    roots, which legitimately both get emitted (see domain_knowledge.py's
    _emit_dedup docstring). Pass the same root twice via knowledge_roots to
    force the overlap and confirm no duplicate FileEntry results.
    """
    home = tmp_path
    knowledge = home / "knowledge"
    (knowledge / "agents" / "dup-persona").mkdir(parents=True)
    (knowledge / "agents" / "dup-persona" / "k001-tip.md").write_text("# tip")

    cfg = channels.build_config(home=home)
    m = new_manifest()
    domain_knowledge.inventory(
        m, cfg,
        knowledge_roots=[knowledge, knowledge],  # deliberately overlapping
        repo_root=home / "finance" / "personal",
        home=home,
        team_config={"team": "finance", "personas": ["dup-persona"]},
    )

    files = m.domains["knowledge"].files
    matching = [fe for fe in files if fe.path.endswith("k001-tip.md")]
    assert len(matching) == 1, "the same absolute path scanned via two overlapping roots must not duplicate"


def test_knowledge_distinct_persona_dirs_in_both_roots_both_inventoried(tmp_path):
    """Two roots independently holding a same-named persona directory are
    DISTINCT files at distinct absolute paths -- both must be emitted (this is
    NOT a duplicate; see domain_knowledge.py's _emit_dedup docstring). Guards
    against an overzealous future dedup that collapses by persona name instead
    of by absolute path.
    """
    home = tmp_path
    shared = home / "knowledge"
    local = home / "knowledge-local"
    (shared / "agents" / "quark").mkdir(parents=True)
    (shared / "agents" / "quark" / "shared-note.md").write_text("# shared")
    (local / "agents" / "quark").mkdir(parents=True)
    (local / "agents" / "quark" / "local-note.md").write_text("# local")

    cfg = channels.build_config(home=home)
    m = new_manifest()
    domain_knowledge.inventory(
        m, cfg,
        repo_root=home / "finance" / "personal",
        home=home,
        team_config={"team": "finance", "personas": ["quark"]},
    )

    files = m.domains["knowledge"].files
    names = {Path(fe.path).name for fe in files}
    assert "shared-note.md" in names
    assert "local-note.md" in names
