"""XACA-0954-007: structural contract test over the 17 canonical team-transfer
YAML configs.

CRITICAL CI CONSTRAINT: this test MUST NEVER assert that ~/dev-team/<product_dir>
or ~/knowledge*/agents/<persona> exist on disk. Those directories exist on this
developer's machine but not on CI runners or other developers' machines -- a
test asserting on-disk existence of those paths would be a machine-specific
false failure (see the PR prompt's explicit warning). This test asserts
STRUCTURE only (keys present, correct types) via channels.load_team_config(),
which is a pure YAML parse with no filesystem existence checks of its own.
"""
from __future__ import annotations

from pathlib import Path

import pytest

from team_transfer import channels as ch

_CONFIG_DIR = Path(__file__).resolve().parents[2] / "team_transfer" / "config"

# Symlinked aliases (a team shares config + working_dir with another team --
# see the "Freelance alias" / "Command alias" comments inside the target
# files). Intentional, not accidental duplication -- excluded from the
# "17 canonical configs" count and separately pinned as symlinks below.
_SYMLINK_ALIASES = {"command.yaml", "freelance.yaml", "medical.yaml"}


def _canonical_config_files() -> list[Path]:
    """Return the REAL (non-symlink) yaml config files -- the 17 canonical configs."""
    return sorted(p for p in _CONFIG_DIR.glob("*.yaml") if not p.is_symlink())


def test_seventeen_canonical_configs_present():
    """Pins the count itself via a command that was actually run (Path.glob +
    is_symlink filter), not asserted from memory -- a config silently added or
    removed should be a visible test failure.
    """
    files = _canonical_config_files()
    assert len(files) == 17, (
        f"expected 17 canonical (non-symlink) team-transfer configs, found "
        f"{len(files)}: {[p.name for p in files]}"
    )


@pytest.mark.parametrize(
    "config_path",
    _canonical_config_files(),
    ids=lambda p: p.stem,
)
def test_config_has_product_dir_and_personas(config_path):
    team = config_path.stem
    cfg = ch.load_team_config(team)

    assert "product_dir" in cfg, f"{team}.yaml missing required 'product_dir' key"
    product_dir = cfg["product_dir"]
    assert isinstance(product_dir, str) and product_dir.strip(), (
        f"{team}.yaml product_dir must be a non-empty string, got {product_dir!r}"
    )

    assert "personas" in cfg, f"{team}.yaml missing required 'personas' key"
    personas = cfg["personas"]
    assert isinstance(personas, list), (
        f"{team}.yaml personas must be a list, got {type(personas).__name__}"
    )
    for p in personas:
        assert isinstance(p, str) and p.strip(), (
            f"{team}.yaml has a non-string/empty persona entry: {p!r}"
        )


def test_symlink_aliases_remain_symlinks():
    """command.yaml / freelance.yaml / medical.yaml are intentional symlink
    aliases pointing at another team's canonical config (shared working_dir in
    team-paths.json). A future edit that accidentally materializes one of
    these into an independent file copy would silently fork config that is
    supposed to stay unified between the two teams -- pin the symlink-ness
    itself, not just its resolved content.
    """
    for name in sorted(_SYMLINK_ALIASES):
        p = _CONFIG_DIR / name
        assert p.exists(), f"{name} should exist (as a symlink)"
        assert p.is_symlink(), f"{name} is expected to be a symlink alias, but is a regular file"
        # The alias must still resolve to one of the 17 canonical configs, not
        # to another symlink or a dangling target.
        target = p.resolve()
        assert target.is_file() and not target.is_symlink(), (
            f"{name} symlink target {target} must be a real canonical config file"
        )
