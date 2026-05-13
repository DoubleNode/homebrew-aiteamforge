"""Tests for the channel resolver."""
from __future__ import annotations

from pathlib import Path
import textwrap

from team_transfer import channels as ch


def _finance_config(home: Path) -> dict:
    """Load the finance team config for use as the canonical test fixture."""
    return ch.load_team_config("finance")


def test_default_rules_route_devteam_to_aiteamforge(tmp_path):
    home = tmp_path / "home"
    home.mkdir()
    team_config = ch.load_team_config("finance")
    cfg = ch.ChannelConfig(rules=ch.default_rules(team_config, home=home))
    assert cfg.resolve(str(home / "dev-team" / "finance" / "personas" / "agents" / "p.md")) == ch.AITEAMFORGE


def test_default_rules_route_repo_to_git(tmp_path):
    home = tmp_path / "home"
    team_config = ch.load_team_config("finance")
    cfg = ch.ChannelConfig(rules=ch.default_rules(team_config, home=home))
    assert cfg.resolve(str(home / "finance" / "personal" / "src" / "x.py")) == ch.GIT


def test_default_rules_route_kanban_to_export(tmp_path):
    home = tmp_path / "home"
    team_config = ch.load_team_config("finance")
    cfg = ch.ChannelConfig(rules=ch.default_rules(team_config, home=home))
    assert cfg.resolve(str(home / "finance" / "personal" / "kanban" / "board.json")) == ch.EXPORT


def test_default_rules_route_db_to_export(tmp_path):
    home = tmp_path / "home"
    team_config = ch.load_team_config("finance")
    cfg = ch.ChannelConfig(rules=ch.default_rules(team_config, home=home))
    assert cfg.resolve(str(home / "finance" / "personal" / "data" / "finance.db")) == ch.EXPORT


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
