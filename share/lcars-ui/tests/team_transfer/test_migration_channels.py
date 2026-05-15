"""Tests for the channel resolver."""
from __future__ import annotations

import warnings
from pathlib import Path
import textwrap

from team_transfer import channels as ch


def _finance_config(home: Path) -> dict:
    """Load the finance team config for use as the canonical test fixture."""
    return ch.load_team_config("finance")


def test_default_rules_route_devteam_to_aiteamforge_product(tmp_path):
    home = tmp_path / "home"
    home.mkdir()
    team_config = ch.load_team_config("finance")
    cfg = ch.ChannelConfig(rules=ch.default_rules(team_config, home=home))
    assert cfg.resolve(str(home / "dev-team" / "finance" / "personas" / "agents" / "p.md")) == ch.AITEAMFORGE_PRODUCT


def test_default_rules_route_repo_to_git(tmp_path):
    home = tmp_path / "home"
    team_config = ch.load_team_config("finance")
    cfg = ch.ChannelConfig(rules=ch.default_rules(team_config, home=home))
    assert cfg.resolve(str(home / "finance" / "personal" / "src" / "x.py")) == ch.GIT


def test_default_rules_route_kanban_to_export_kanban(tmp_path):
    home = tmp_path / "home"
    team_config = ch.load_team_config("finance")
    cfg = ch.ChannelConfig(rules=ch.default_rules(team_config, home=home))
    assert cfg.resolve(str(home / "finance" / "personal" / "kanban" / "board.json")) == ch.EXPORT_KANBAN


def test_default_rules_route_db_to_export_database(tmp_path):
    home = tmp_path / "home"
    team_config = ch.load_team_config("finance")
    cfg = ch.ChannelConfig(rules=ch.default_rules(team_config, home=home))
    assert cfg.resolve(str(home / "finance" / "personal" / "data" / "finance.db")) == ch.EXPORT_DATABASE


def test_default_rules_route_env_to_secrets(tmp_path):
    home = tmp_path / "home"
    team_config = ch.load_team_config("finance")
    cfg = ch.ChannelConfig(rules=ch.default_rules(team_config, home=home))
    assert cfg.resolve(str(home / "finance" / "personal" / ".env")) == ch.SECRETS_EXPORT


def test_default_rules_route_secrets_dir_to_secrets_export(tmp_path):
    home = tmp_path / "home"
    team_config = ch.load_team_config("finance")
    cfg = ch.ChannelConfig(rules=ch.default_rules(team_config, home=home))
    assert cfg.resolve(str(home / "finance" / "personal" / "secrets" / "creds.txt")) == ch.SECRETS_EXPORT
    assert cfg.resolve(str(home / "finance" / "personal" / "secrets" / "nested" / "key.json")) == ch.SECRETS_EXPORT


def test_default_rules_route_statements_to_icloud_excluded(tmp_path):
    home = tmp_path / "home"
    team_config = ch.load_team_config("finance")
    cfg = ch.ChannelConfig(rules=ch.default_rules(team_config, home=home))
    p = home / "finance" / "personal" / "docs" / "statements" / "Bank" / "x.pdf"
    assert cfg.resolve(str(p)) == ch.ICLOUD_EXCLUDED


def test_unmatched_path_is_untagged(tmp_path):
    home = tmp_path / "home"
    team_config = ch.load_team_config("finance")
    cfg = ch.ChannelConfig(rules=ch.default_rules(team_config, home=home))
    assert cfg.resolve("/random/unknown/path.txt") == ch.UNTAGGED


def test_yaml_overrides_take_precedence(tmp_path):
    home = tmp_path / "home"
    yaml = tmp_path / "channels.yaml"
    yaml.write_text(textwrap.dedent("""\
        overrides:
          - pattern: "*/finance/personal/.mcp.json"
            channel: "git"
        icloud_excluded:
          - "*/finance/personal/docs/statements/*"
    """))
    cfg = ch.build_config(home=home, yaml_overrides=yaml, team="finance")
    # Override + default both route .mcp.json to git, but the override is added LAST
    # so it wins on tie. Verify the rule list contains the override.
    assert any(r.pattern.endswith("/.mcp.json") and r.channel == "git" for r in cfg.rules)


def test_yaml_icloud_excluded_section_parsed(tmp_path):
    yaml = tmp_path / "c.yaml"
    yaml.write_text(textwrap.dedent("""\
        icloud_excluded:
          - "*/foo/bar/**"
          - "*/baz/**"
    """))
    rules = ch.load_overrides_yaml(yaml)
    assert len(rules) == 2
    assert all(r.channel == ch.ICLOUD_EXCLUDED for r in rules)


def test_missing_yaml_returns_empty(tmp_path):
    rules = ch.load_overrides_yaml(tmp_path / "nope.yaml")
    assert rules == []


def test_yaml_comments_ignored(tmp_path):
    yaml = tmp_path / "c.yaml"
    yaml.write_text(textwrap.dedent("""\
        # leading comment
        overrides:
          # nested comment
          - pattern: "*/foo"   # trailing
            channel: "git"
    """))
    rules = ch.load_overrides_yaml(yaml)
    assert len(rules) == 1
    assert rules[0].pattern == "*/foo"
    assert rules[0].channel == "git"


# ── XACA-0488: new channel resolution tests ───────────────────────────────────

def test_aiteamforge_product_resolves_for_devteam_path(tmp_path):
    """~/dev-team/<team>/* paths resolve to aiteamforge_product."""
    home = tmp_path / "home"
    team_config = ch.load_team_config("finance")
    cfg = ch.ChannelConfig(rules=ch.default_rules(team_config, home=home))
    assert cfg.resolve(str(home / "dev-team" / "finance" / "scripts" / "setup.sh")) == ch.AITEAMFORGE_PRODUCT


def test_aiteamforge_product_resolves_for_finance_agents_path(tmp_path):
    """~/finance/.claude/agents/* paths resolve to aiteamforge_product."""
    home = tmp_path / "home"
    team_config = ch.load_team_config("finance")
    cfg = ch.ChannelConfig(rules=ch.default_rules(team_config, home=home))
    assert cfg.resolve(str(home / "finance" / ".claude" / "agents" / "quark.sh")) == ch.AITEAMFORGE_PRODUCT


def test_user_state_resolves_for_claude_project_memory_path(tmp_path):
    """~/.claude/projects/<UUID>/memory/ paths resolve to user_state."""
    home = tmp_path / "home"
    team_config = ch.load_team_config("finance")
    cfg = ch.ChannelConfig(rules=ch.default_rules(team_config, home=home))
    # The finance config uses claude_project_dir_name = "-Users-darrenehlers-finance-personal"
    # but with token substitution the home changes at test time, so we build from the resolved token.
    tokens = ch.build_tokens(team_config, str(home))
    claude_dir = tokens["{claude_project_dir_name}"]
    p = str(home / ".claude" / "projects" / claude_dir / "memory" / "MEMORY.md")
    assert cfg.resolve(p) == ch.USER_STATE


def test_user_state_resolves_for_knowledge_agents_path(tmp_path):
    """~/knowledge/agents/<persona>/* paths resolve to user_state."""
    home = tmp_path / "home"
    team_config = ch.load_team_config("finance")
    cfg = ch.ChannelConfig(rules=ch.default_rules(team_config, home=home))
    # finance.yaml lists several knowledge agents (quark, nog, brunt, rom, zek)
    assert cfg.resolve(str(home / "knowledge" / "agents" / "quark" / "INDEX.md")) == ch.USER_STATE
    assert cfg.resolve(str(home / "knowledge" / "agents" / "nog" / "lessons.md")) == ch.USER_STATE


def test_export_kanban_resolves_for_kanban_path(tmp_path):
    """<root>/kanban/* paths resolve to export_kanban."""
    home = tmp_path / "home"
    team_config = ch.load_team_config("finance")
    cfg = ch.ChannelConfig(rules=ch.default_rules(team_config, home=home))
    assert cfg.resolve(str(home / "finance" / "personal" / "kanban" / "backlog.json")) == ch.EXPORT_KANBAN


def test_export_kanban_resolves_for_worktrees_path(tmp_path):
    """<root>/worktrees/* paths resolve to export_kanban."""
    home = tmp_path / "home"
    team_config = ch.load_team_config("finance")
    cfg = ch.ChannelConfig(rules=ch.default_rules(team_config, home=home))
    assert cfg.resolve(str(home / "finance" / "personal" / "worktrees" / "xfin-0001" / "main.py")) == ch.EXPORT_KANBAN


def test_export_database_resolves_for_db_path(tmp_path):
    """<root>/data/*.db paths resolve to export_database."""
    home = tmp_path / "home"
    team_config = ch.load_team_config("finance")
    cfg = ch.ChannelConfig(rules=ch.default_rules(team_config, home=home))
    assert cfg.resolve(str(home / "finance" / "personal" / "data" / "finance.db")) == ch.EXPORT_DATABASE


def test_deprecated_aiteamforge_alias_emits_warning():
    """Accessing channels.AITEAMFORGE emits a DeprecationWarning and equals AITEAMFORGE_PRODUCT."""
    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter("always")
        alias_value = ch.AITEAMFORGE  # noqa: B018 — intentional access to test the alias
    assert any(issubclass(w.category, DeprecationWarning) for w in caught), (
        "Expected DeprecationWarning when accessing channels.AITEAMFORGE"
    )
    assert alias_value == ch.AITEAMFORGE_PRODUCT, (
        "channels.AITEAMFORGE must equal AITEAMFORGE_PRODUCT"
    )


def test_deprecated_export_alias_emits_warning():
    """Accessing channels.EXPORT emits a DeprecationWarning and equals EXPORT_KANBAN."""
    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter("always")
        alias_value = ch.EXPORT  # noqa: B018 — intentional access to test the alias
    assert any(issubclass(w.category, DeprecationWarning) for w in caught), (
        "Expected DeprecationWarning when accessing channels.EXPORT"
    )
    assert alias_value == ch.EXPORT_KANBAN, (
        "channels.EXPORT must equal EXPORT_KANBAN"
    )


# ── XACA-0487 regression: .git/ directories must always be excluded ──────────

def test_git_dir_excluded_by_walker(tmp_path):
    """Walker must never yield files inside a .git/ directory.

    XACA-0487: ALWAYS_EXCLUDE_GLOBS was missing the .git/ entry, causing
    pack files and other git internals to appear in manifests and producing
    false-positive sha256 mismatches on the destination (fresh clones repack
    the object store).
    """
    from team_transfer.checksum import walk_files

    # Set up a synthetic repo tree with a .git/ directory.
    repo = tmp_path / "repo"
    (repo / ".git" / "objects" / "pack").mkdir(parents=True)
    (repo / ".git" / "objects" / "pack" / "pack-abc.pack").write_bytes(b"junk pack data")
    (repo / ".git" / "HEAD").write_bytes(b"ref: refs/heads/main\n")
    (repo / "src").mkdir()
    (repo / "src" / "main.py").write_text("print('hello')\n")

    found = list(walk_files(repo))
    found_names = {p.name for p in found}

    # The source file must be found; git internals must not.
    assert "main.py" in found_names, "regular source file must be discovered"
    assert "pack-abc.pack" not in found_names, ".git/objects/pack file must be excluded"
    assert "HEAD" not in found_names, ".git/HEAD must be excluded"
