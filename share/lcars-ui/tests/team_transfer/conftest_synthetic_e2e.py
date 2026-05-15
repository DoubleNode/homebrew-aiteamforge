"""Fixture topology for the synthetic end-to-end migration integration test.

WHY THIS FILE EXISTS
--------------------
The 36 unit tests in this suite cover generator, verifier, and domain modules in
isolation.  None of them exercise the full round-trip: generator -> destructive
move (files removed from source) -> verifier against destination.  That gap is
exactly how the M3Pro->M1Pro design flaws survived to ship.

This file provides the shared fixture layer that the e2e test (subitem 002) will
drive.  Keeping fixtures separate from the test body makes them reusable if we
later add negative-path or path-map round-trip variants.

SYNTHETIC SOURCE TOPOLOGY
--------------------------
<src_home>/
  finance/personal/          # home_relative_root — exercises git + export channels
    src/
      main.py                 # git channel (EXACT)
      utils.py                # git channel (EXACT)
    kanban/
      finance-personal-board.json   # export_kanban / SCHEMA (board probe)
      XFIN-0001_plan.md             # export_kanban / EXACT
    data/
      finance.db              # export_database / SCHEMA (db probe)
    .env                      # secrets_export / PRESENT
    secrets/
      test-secrets.txt        # secrets_export / PRESENT
    docs/
      statements/             # icloud_excluded (silently skipped by verifier)
        2026-01.pdf
  dev-team/finance/           # aiteamforge_product channel (PRESENT)
    personas/agents/
      quark.md
    scripts/
      setup.sh
  .claude/
    projects/
      -Users-synth-finance-personal/    # user_state channel
        memory/
          MEMORY.md           # user_state / EXACT
        session.jsonl          # user_state / PRESENT
  knowledge/
    agents/
      quark/
        INDEX.md               # user_state / EXACT
      nog/
        lessons.md             # user_state / EXACT

CHANNELS EXERCISED
------------------
  git               — src/main.py, src/utils.py
  export_kanban     — kanban/finance-personal-board.json, kanban/XFIN-0001_plan.md
  export_database   — data/finance.db
  secrets_export    — .env, secrets/test-secrets.txt
  aiteamforge_product — dev-team/finance/**
  user_state        — .claude/projects/.../memory/MEMORY.md, session.jsonl,
                      knowledge/agents/quark/INDEX.md, knowledge/agents/nog/lessons.md
  icloud_excluded   — docs/statements/2026-01.pdf

WHY THIS SHAPE CATCHES DESIGN FLAWS
------------------------------------
1. Path-translation regression: manifests record absolute source paths.  If the
   verifier doesn't rewrite them (or rewrites them wrong), every check fails on
   the destination.  Using distinct src/dst tmp dirs forces path rewriting even
   on a single machine.

2. Channel-class invariant: aiteamforge_product files must be PRESENT, not EXACT.
   export_database files must be SCHEMA.  Including both in the synthetic source
   ensures the generator assigns correct cls values that the verifier then enforces.

3. Board schema probe: the kanban board carries a structured probe (item_ids).
   Omitting it from a round-trip test lets silent item-loss escape undetected.

4. icloud_excluded passthrough: files in docs/statements/ must not produce FAIL
   when absent on the destination.  The fixture includes one such file to verify
   the "skip" counter is non-zero after the verifier runs.

5. Secrets channel presence: the secrets_export channel must appear in stats even
   when nearly empty.  XACA-0491 found that the channel could silently disappear
   from stats if the source tree had no files matching the rule.
"""
from __future__ import annotations

import json
import subprocess
from pathlib import Path

import pytest


# ---------------------------------------------------------------------------
# Team config fixture
# ---------------------------------------------------------------------------

@pytest.fixture()
def synthetic_team_config(tmp_path) -> dict:
    """Minimal team config dict matching the synthetic source topology.

    Uses the packaged finance.yaml as a structural template but overrides tokens
    so that all paths resolve into tmp_path rather than the real $HOME.  This
    means build_config() and the domain modules work against tmp_path without
    any monkeypatching of Path.home().
    """
    src_home = tmp_path / "src_home"
    # claude_project_dir_name must match the subdirectory we create under
    # <src_home>/.claude/projects/ — see make_claude_dir below.
    return {
        "team": "finance",
        "home_relative_root": "finance/personal",
        "board_filename": "finance-personal-board.json",
        "ticket_prefix": "XFIN-",
        "claude_project_dir_name": "-Users-synth-finance-personal",
        "personas": ["quark", "nog"],
        # databases list: path token {home}/{root}/data/finance.db
        # We don't expand tokens here — the domain modules do that.
        "databases": [
            {"path": "{home}/{root}/data/finance.db", "cls": "schema"}
        ],
        # Inline defaults that mirror finance.yaml channel rules, resolved lazily
        # by channels.default_rules(team_config, home=src_home).
        "defaults": {
            "rules": [
                {"pattern": "{home}/dev-team/{team}/*", "channel": "aiteamforge_product"},
                {"pattern": "{home}/dev-team/{team}/**", "channel": "aiteamforge_product"},
                {"pattern": "{home}/finance/.claude/agents/*", "channel": "aiteamforge_product"},
                {"pattern": "{home}/finance/.claude/agents/**", "channel": "aiteamforge_product"},
                {"pattern": "{home}/.claude/projects/{claude_project_dir_name}/*", "channel": "user_state"},
                {"pattern": "{home}/.claude/projects/{claude_project_dir_name}/**", "channel": "user_state"},
                {"pattern": "{home}/knowledge/agents/quark/*", "channel": "user_state"},
                {"pattern": "{home}/knowledge/agents/quark/**", "channel": "user_state"},
                {"pattern": "{home}/knowledge/agents/nog/*", "channel": "user_state"},
                {"pattern": "{home}/knowledge/agents/nog/**", "channel": "user_state"},
                {"pattern": "{home}/{root}/*", "channel": "git"},
                {"pattern": "{home}/{root}/**", "channel": "git"},
                {"pattern": "{home}/{root}/kanban/*", "channel": "export_kanban"},
                {"pattern": "{home}/{root}/kanban/**", "channel": "export_kanban"},
                {"pattern": "{home}/{root}/data/*", "channel": "export_database"},
                {"pattern": "{home}/{root}/data/**", "channel": "export_database"},
                {"pattern": "{home}/{root}/.env", "channel": "secrets_export"},
                {"pattern": "{home}/{root}/.env.*", "channel": "secrets_export"},
                {"pattern": "{home}/{root}/secrets/*", "channel": "secrets_export"},
                {"pattern": "{home}/{root}/secrets/**", "channel": "secrets_export"},
                {"pattern": "{home}/{root}/docs/statements/**", "channel": "icloud_excluded"},
            ],
            "icloud_excluded": [],
        },
        "overrides": [],
    }


# ---------------------------------------------------------------------------
# Source home fixture
# ---------------------------------------------------------------------------

@pytest.fixture()
def synthetic_source(tmp_path, synthetic_team_config) -> Path:
    """Build a fake $HOME-shaped source tree with mock files for every channel.

    Returns the root path (acts as the source $HOME).
    """
    src = tmp_path / "src_home"
    src.mkdir()

    _make_git_repo_dir(src, synthetic_team_config)
    _make_kanban_dir(src, synthetic_team_config)
    _make_database_dir(src, synthetic_team_config)
    _make_secrets_dir(src, synthetic_team_config)
    _make_icloud_excluded_dir(src, synthetic_team_config)
    _make_aiteamforge_dir(src, synthetic_team_config)
    _make_claude_dir(src, synthetic_team_config)
    _make_knowledge_tree(src, synthetic_team_config)

    return src


# ---------------------------------------------------------------------------
# Destination home fixture
# ---------------------------------------------------------------------------

@pytest.fixture()
def synthetic_destination(tmp_path) -> Path:
    """Empty destination tree ready to receive a move.

    Returns the root path (acts as the destination $HOME).
    The directory exists but is empty — the e2e test populates it by copying
    the source tree contents before running the verifier.
    """
    dst = tmp_path / "dst_home"
    dst.mkdir()
    return dst


# ---------------------------------------------------------------------------
# Minimal git repo fixture
# ---------------------------------------------------------------------------

@pytest.fixture()
def synthetic_repo(tmp_path, synthetic_team_config) -> Path:
    """Minimal git repo rooted at <tmp_path>/src_home/finance/personal.

    domain_git calls `git ls-files` to enumerate tracked files; without an
    actual git repo it falls back to walking the directory tree.  The fixture
    creates a real repo with one commit so that the git-tracked path is
    exercised, not just the fallback walker.

    Returns the repo root path.
    """
    src = tmp_path / "src_home"
    root_rel = synthetic_team_config["home_relative_root"]
    repo = src / root_rel
    repo.mkdir(parents=True, exist_ok=True)

    _git_init_and_commit(repo)
    return repo


# ---------------------------------------------------------------------------
# Helper builders (factored out so the e2e test can re-use them selectively)
# ---------------------------------------------------------------------------

def _make_git_repo_dir(src: Path, team_config: dict) -> None:
    """Populate the git-tracked source files (git channel)."""
    root_rel = team_config["home_relative_root"]
    repo = src / root_rel
    src_code = repo / "src"
    src_code.mkdir(parents=True, exist_ok=True)
    (src_code / "main.py").write_text("# synthetic main\nprint('hello')\n")
    (src_code / "utils.py").write_text("# synthetic utils\ndef noop(): pass\n")


def _make_kanban_dir(src: Path, team_config: dict) -> None:
    """Populate kanban tree (export_kanban channel, SCHEMA for board JSON)."""
    root_rel = team_config["home_relative_root"]
    board_filename = team_config["board_filename"]
    ticket_prefix = team_config["ticket_prefix"]

    kanban = src / root_rel / "kanban"
    kanban.mkdir(parents=True, exist_ok=True)

    board_data = {
        "items": [
            {"id": f"{ticket_prefix}0001", "title": "Synthetic item 1", "status": "done"},
            {"id": f"{ticket_prefix}0002", "title": "Synthetic item 2", "status": "in_progress"},
        ]
    }
    (kanban / board_filename).write_text(json.dumps(board_data, indent=2))
    (kanban / f"{ticket_prefix}0001_plan.md").write_text("# Plan\nSynthetic plan doc.\n")


def _make_database_dir(src: Path, team_config: dict) -> None:
    """Populate data dir with a minimal SQLite-like db file (export_database / SCHEMA).

    We write a valid SQLite header so that db_integrity.probe_db can open it.
    An empty SQLite db created via the stdlib sqlite3 module is the simplest
    approach — no external binary needed.
    """
    import sqlite3

    root_rel = team_config["home_relative_root"]
    data_dir = src / root_rel / "data"
    data_dir.mkdir(parents=True, exist_ok=True)

    db_path = data_dir / "finance.db"
    conn = sqlite3.connect(str(db_path))
    conn.execute(
        "CREATE TABLE IF NOT EXISTS schema_info "
        "(key TEXT PRIMARY KEY, value TEXT)"
    )
    conn.execute(
        "INSERT OR REPLACE INTO schema_info VALUES ('schema_version', '1')"
    )
    conn.commit()
    conn.close()


def _make_secrets_dir(src: Path, team_config: dict) -> None:
    """Populate secrets-related paths (secrets_export channel)."""
    root_rel = team_config["home_relative_root"]
    repo = src / root_rel
    (repo / ".env").write_text("API_KEY=synthetic_key_not_real\nDEBUG=true\n")

    secrets = repo / "secrets"
    secrets.mkdir(parents=True, exist_ok=True)
    # test-secrets.txt mirrors the real secrets/test-secrets.txt that exercises
    # the full pack/unpack path without real credentials (see channels.py comment).
    (secrets / "test-secrets.txt").write_text("synthetic-secret-value\n")


def _make_icloud_excluded_dir(src: Path, team_config: dict) -> None:
    """Populate icloud_excluded paths so the verifier can exercise the skip path."""
    root_rel = team_config["home_relative_root"]
    statements = src / root_rel / "docs" / "statements"
    statements.mkdir(parents=True, exist_ok=True)
    (statements / "2026-01.pdf").write_bytes(b"%PDF-1.4 synthetic")


def _make_aiteamforge_dir(src: Path, team_config: dict) -> None:
    """Populate ~/dev-team/<team>/ tree (aiteamforge_product channel, PRESENT)."""
    team = team_config["team"]
    devteam = src / "dev-team" / team

    personas_agents = devteam / "personas" / "agents"
    personas_agents.mkdir(parents=True, exist_ok=True)
    # Reference a subject in the persona file so domain_knowledge._scan_referenced_subjects
    # can discover it (exercises the subject-scan heuristic).
    (personas_agents / "quark.md").write_text(
        "# Quark\nKnowledge: ~/knowledge/subjects/trading/INDEX.md\n"
    )

    scripts = devteam / "scripts"
    scripts.mkdir(parents=True, exist_ok=True)
    (scripts / "setup.sh").write_text("#!/bin/sh\necho 'synthetic setup'\n")


def _make_claude_dir(src: Path, team_config: dict) -> None:
    """Populate ~/.claude/projects/<project_dir>/ (user_state channel)."""
    project_dir_name = team_config["claude_project_dir_name"]
    project_root = src / ".claude" / "projects" / project_dir_name

    memory = project_root / "memory"
    memory.mkdir(parents=True, exist_ok=True)
    (memory / "MEMORY.md").write_text("# Synthetic memory\nLast updated: synthetic.\n")

    (project_root / "session.jsonl").write_text('{"role":"user","content":"hi"}\n')


def _make_knowledge_tree(src: Path, team_config: dict) -> None:
    """Populate ~/knowledge/agents/<persona>/ dirs (user_state channel)."""
    personas = team_config.get("personas", ["quark", "nog"])
    for persona in personas:
        agent_dir = src / "knowledge" / "agents" / persona
        agent_dir.mkdir(parents=True, exist_ok=True)
        (agent_dir / "INDEX.md").write_text(f"# {persona.capitalize()} knowledge index\n")

    # Subject tier dir (referenced by quark.md via the scan heuristic).
    subject_dir = src / "knowledge" / "subjects" / "trading"
    subject_dir.mkdir(parents=True, exist_ok=True)
    (subject_dir / "INDEX.md").write_text("# Trading subject knowledge\n")


def _git_init_and_commit(repo: Path) -> None:
    """Initialize a git repo and create one commit so git ls-files works."""
    # Some CI environments have a safe.directory mismatch; configure locally.
    env_overrides = {"GIT_CONFIG_NOSYSTEM": "1", "HOME": str(repo)}
    import os
    env = {**os.environ, **env_overrides}

    subprocess.run(
        ["git", "-C", str(repo), "init"],
        check=True, capture_output=True, env=env,
    )
    subprocess.run(
        ["git", "-C", str(repo), "config", "user.email", "test@synthetic.local"],
        check=True, capture_output=True, env=env,
    )
    subprocess.run(
        ["git", "-C", str(repo), "config", "user.name", "Synthetic"],
        check=True, capture_output=True, env=env,
    )
    # Stage whatever src/ contains at this point (may be empty if called before
    # _make_git_repo_dir; that's fine — an empty initial commit works too).
    subprocess.run(
        ["git", "-C", str(repo), "add", "-A"],
        capture_output=True, env=env,
    )
    subprocess.run(
        ["git", "-C", str(repo), "commit", "--allow-empty", "-m", "synthetic initial commit"],
        check=True, capture_output=True, env=env,
    )
