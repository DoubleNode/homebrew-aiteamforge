"""XACA-1337-016: per-machine team_transfer config overlay.

Client-specific team configs (freelance-<client>-<project>) no longer ship in
team_transfer/config/. A machine hosting such a team keeps its YAML in the
overlay dir ($AITEAMFORGE_TEAM_TRANSFER_CONFIG_DIR, default
~/.aiteamforge/team_transfer/config/). Both the generator (channels.load_team_config)
and the LCARS export button (server._resolve_team_transfer_team) must search it.

Every test points HOME and the overlay variable at tmp_path, so the real
~/.aiteamforge is never read or written.
"""
from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import pytest

from team_transfer import channels as ch
from team_transfer import generator

LCARS_UI = Path(__file__).resolve().parents[2]

# A synthetic team name that cannot collide with any packaged config.
SYNTH = "freelance-synthclient-widget"

VALID_YAML = f"""\
team: {SYNTH}
home_relative_root: "../Shared/Development/SynthClient/Widget"
product_dir: "freelance"
personas:
  - "archer"
persona_dirs:
  - "freelance"
"""


@pytest.fixture
def overlay(tmp_path, monkeypatch):
    home = tmp_path / "home"
    home.mkdir()
    d = tmp_path / "overlay"
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv(ch.OVERLAY_CONFIG_DIR_VAR, str(d))
    return d


def _load_server_module():
    spec = importlib.util.spec_from_file_location("lcars_server_xaca_1337_016", LCARS_UI / "server.py")
    mod = importlib.util.module_from_spec(spec)
    sys.modules["lcars_server_xaca_1337_016"] = mod
    spec.loader.exec_module(mod)
    return mod


# ------------------------------------------------------------------ absent
def test_absent_overlay_dir_is_normal(overlay):
    assert not overlay.exists()
    # generic packaged team still loads
    cfg = ch.load_team_config("academy")
    assert cfg["team"] == "academy"
    # client team is simply not found (FileNotFoundError, not a crash)
    with pytest.raises(FileNotFoundError):
        ch.load_team_config(SYNTH)
    assert ch.resolve_team_config_path(SYNTH) is None


def test_default_overlay_location_is_under_home(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.delenv(ch.OVERLAY_CONFIG_DIR_VAR, raising=False)
    assert ch.overlay_config_dir() == tmp_path / ".aiteamforge" / "team_transfer" / "config"
    monkeypatch.setenv(ch.OVERLAY_CONFIG_DIR_VAR, "")  # empty == unset
    assert ch.overlay_config_dir() == tmp_path / ".aiteamforge" / "team_transfer" / "config"


def test_client_configs_no_longer_packaged():
    # Client-project form freelance-<client>-<project>.yaml must not be packaged
    # (generic on purpose: no client names in shipped test code).
    names = {p.name for p in (LCARS_UI / "team_transfer" / "config").glob("*.yaml")}
    leaked = sorted(n for n in names if n.startswith("freelance-") and n[len("freelance-"):].count("-") >= 1)
    assert leaked == [], f"client team_transfer configs still packaged: {leaked}"


# ------------------------------------------------------------------- valid
def test_valid_overlay_team_loads(overlay):
    overlay.mkdir()
    (overlay / f"{SYNTH}.yaml").write_text(VALID_YAML, encoding="utf-8")
    cfg = ch.load_team_config(SYNTH)
    assert cfg["team"] == SYNTH
    assert ch.resolve_team_config_path(SYNTH) == overlay / f"{SYNTH}.yaml"
    # packaged generic teams still resolve while an overlay dir exists
    assert ch.load_team_config("academy")["team"] == "academy"


def test_generator_reads_overlay(overlay, tmp_path):
    overlay.mkdir()
    (overlay / f"{SYNTH}.yaml").write_text(VALID_YAML, encoding="utf-8")
    out = tmp_path / "out" / "manifest.json"
    out.parent.mkdir()
    rc = generator.main(["--team", SYNTH, "--output", str(out),
                         "--repo-root", str(tmp_path / "nope"),
                         "--allow-untagged", "--allow-missing-roots"])
    # Not exit 2 (config error): the overlay config was found and parsed.
    assert rc in (0, 1), rc
    assert out.exists()


def test_server_export_resolver_finds_overlay_team(overlay):
    overlay.mkdir()
    (overlay / f"{SYNTH}.yaml").write_text(VALID_YAML, encoding="utf-8")
    srv = _load_server_module()
    assert srv._resolve_team_transfer_team(SYNTH, "freelance") == SYNTH
    # base_team fallback still works for a derived id with no config of its own
    assert srv._resolve_team_transfer_team("academy-derivedxyz", "academy") == "academy"
    assert srv._resolve_team_transfer_team("nosuchteam-x", "nosuchteam") is None


def test_overlay_with_empty_home_relative_root_is_valid(overlay):
    """Option B configs (absolute paths outside $HOME) use home_relative_root: "" --
    the shipped freelance-liquidstyle-* configs did. Empty must not be read as absent."""
    overlay.mkdir()
    body = VALID_YAML.replace('home_relative_root: "../Shared/Development/SynthClient/Widget"', 'home_relative_root: ""')
    (overlay / f"{SYNTH}.yaml").write_text(body, encoding="utf-8")
    assert ch.load_team_config(SYNTH)["home_relative_root"] == ""


def test_overlay_missing_home_relative_root_fails(overlay):
    overlay.mkdir()
    body = VALID_YAML.replace('home_relative_root: "../Shared/Development/SynthClient/Widget"\n', "")
    (overlay / f"{SYNTH}.yaml").write_text(body, encoding="utf-8")
    with pytest.raises(ch.TeamConfigError, match="home_relative_root"):
        ch.load_team_config(SYNTH)


# --------------------------------------------------------------- collision
def test_overlay_wins_on_name_collision(overlay):
    overlay.mkdir()
    body = (ch._PACKAGE_CONFIG_DIR / "academy.yaml").read_text(encoding="utf-8")
    body = body.replace('product_dir: "academy"', 'product_dir: "overlay-marker"')
    assert "overlay-marker" in body, "fixture assumption: academy.yaml has product_dir: \"academy\""
    (overlay / "academy.yaml").write_text(body, encoding="utf-8")
    assert ch.load_team_config("academy")["product_dir"] == "overlay-marker"
    assert ch.resolve_team_config_path("academy") == overlay / "academy.yaml"


def test_explicit_config_dir_still_beats_overlay(overlay, tmp_path):
    overlay.mkdir()
    (overlay / f"{SYNTH}.yaml").write_text(VALID_YAML, encoding="utf-8")
    explicit = tmp_path / "explicit"
    explicit.mkdir()
    (explicit / f"{SYNTH}.yaml").write_text(VALID_YAML.replace('"freelance"\npersonas', '"explicit"\npersonas'),
                                             encoding="utf-8")
    assert ch.load_team_config(SYNTH, config_dir=explicit)["product_dir"] == "explicit"


# --------------------------------------------------------------- malformed
@pytest.mark.parametrize("body,needle", [
    ("garbage: [unclosed\n", "missing 'team'"),
    (VALID_YAML.replace(f"team: {SYNTH}", "team: some-other-team"), "does not match"),
    (VALID_YAML.replace('product_dir: "freelance"\n', ""), "product_dir"),
    (VALID_YAML.replace('personas:\n  - "archer"\n', ""), "personas"),
])
def test_malformed_overlay_fails_loudly(overlay, body, needle):
    overlay.mkdir()
    (overlay / f"{SYNTH}.yaml").write_text(body, encoding="utf-8")
    with pytest.raises(ch.TeamConfigError, match=needle):
        ch.load_team_config(SYNTH)


def test_malformed_overlay_does_not_fall_back_to_packaged(overlay):
    """A broken overlay copy of a packaged team must not be silently replaced by
    the packaged config."""
    overlay.mkdir()
    (overlay / "academy.yaml").write_text("not: a team config\n", encoding="utf-8")
    with pytest.raises(ch.TeamConfigError):
        ch.load_team_config("academy")


def test_overlay_path_that_is_a_file_fails_loudly(overlay):
    overlay.write_text("i am a file", encoding="utf-8")
    with pytest.raises(ch.TeamConfigError, match="not a directory"):
        ch.load_team_config("academy")


def test_generator_exits_2_on_malformed_overlay(overlay, tmp_path, capsys):
    overlay.mkdir()
    (overlay / f"{SYNTH}.yaml").write_text("garbage\n", encoding="utf-8")
    rc = generator.main(["--team", SYNTH, "--output", str(tmp_path / "m.json")])
    assert rc == 2
    assert "malformed team_transfer overlay" in capsys.readouterr().err


def test_server_export_resolver_raises_on_malformed_overlay(overlay):
    overlay.mkdir()
    (overlay / f"{SYNTH}.yaml").write_text("garbage\n", encoding="utf-8")
    srv = _load_server_module()
    with pytest.raises(ValueError, match="malformed"):
        srv._resolve_team_transfer_team(SYNTH, "freelance")
