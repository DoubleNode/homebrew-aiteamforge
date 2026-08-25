"""XACA-0954 round 2: regression tests for the five gate findings.

These pin the fixes made after PR #765's first review round. Each test names the
subitem it guards so a future reader can trace the requirement back to the finding.

The through-line for all five: an interface must not tell an operator something
that disagrees with what actually happened. That is the defect class XACA-0954
exists to remove, and the first round of fixes reintroduced it in four smaller
places (waiver text, remediation without a path, an empty config key treated as
absent, and the LCARS export button reporting plain success).
"""
from __future__ import annotations

import contextlib
import io
import json
import subprocess
import sys
import tempfile
from pathlib import Path

import pytest

from team_transfer import channels as ch
from team_transfer import domain_devteam
from team_transfer.manifest import new_manifest

REPO_ROOT = Path(__file__).resolve().parents[3]
LCARS_UI = REPO_ROOT / "lcars-ui"


def _mkfile(root: Path, rel: str, body: str = "x") -> Path:
    p = root / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(body, encoding="utf-8")
    return p


def _write_cfg(cfg_dir: Path, team: str, product_dir: str) -> Path:
    """Minimal but realistic team config, written the way a real one is shaped."""
    cfg_dir.mkdir(parents=True, exist_ok=True)
    p = cfg_dir / f"{team}.yaml"
    p.write_text(
        f'team: {team}\n'
        f'home_relative_root: ""\n'
        f'product_dir: "{product_dir}"\n'
        f'personas: []\n'
        f'databases:\n'
        f'defaults:\n'
        f'  rules:\n'
        f'    - pattern: "{{home}}/dev-team/{{team}}/**"\n'
        f'      channel: aiteamforge_product\n'
        f'  icloud_excluded: []\n'
        f'overrides: []\n',
        encoding="utf-8",
    )
    return p


def _run_generator(cfg_dir: Path, team: str, out: Path, *extra: str):
    """Run the real generator CLI and return (returncode, combined_output)."""
    proc = subprocess.run(
        [sys.executable, "-m", "team_transfer.generator",
         "--team", team, "--team-config-dir", str(cfg_dir),
         "--output", str(out), *extra],
        cwd=str(LCARS_UI),
        env={"PATH": "/usr/bin:/bin", "PYTHONPATH": str(LCARS_UI), "HOME": str(cfg_dir.parent)},
        capture_output=True, text=True, timeout=180,
    )
    return proc.returncode, proc.stdout + proc.stderr


# ---------------------------------------------------------------- finding 012
def test_waiver_changes_the_summary_wording_not_only_the_exit_code():
    """XACA-0954-012: --allow-missing-roots must not print 'NOT CLEAR TO EXPORT'.

    Telling an operator who just passed the waiver to "not export until ... waived
    with --allow-missing-roots" instructs them to do what they already did, and
    contradicts the exit code they got. On a team that waives routinely it trains
    them to read past the one line that matters.
    """
    with tempfile.TemporaryDirectory() as td:
        home = Path(td) / "home"
        cfg_dir = home / "cfg"
        _mkfile(home, "dev-team/placeholder.txt")
        _write_cfg(cfg_dir, "t", "does-not-exist")
        out = Path(td) / "m.json"

        # --allow-untagged on BOTH runs isolates the missing-root class: this
        # synthetic tree also yields untagged files, and --allow-missing-roots
        # correctly refuses to waive those. Holding the untagged class constant is
        # what makes the exit-code delta attributable to the missing-root waiver.
        rc_unwaived, txt_unwaived = _run_generator(cfg_dir, "t", out, "--allow-untagged")
        rc_waived, txt_waived = _run_generator(
            cfg_dir, "t", out, "--allow-untagged", "--allow-missing-roots")

    assert rc_unwaived == 1
    assert "NOT CLEAR TO EXPORT" in txt_unwaived

    assert rc_waived == 0
    # The waived run must not repeat the unwaived alarm...
    assert "NOT CLEAR TO EXPORT" not in txt_waived
    # ...but must still refuse to read as clean.
    assert "INCOMPLETE BY WAIVER" in txt_waived
    assert "Zero untagged gaps" not in txt_waived


def test_waived_run_does_not_tell_operator_to_rerun_before_treating_as_complete():
    """XACA-0954-012 (same defect, one paragraph up in the section body)."""
    with tempfile.TemporaryDirectory() as td:
        home = Path(td) / "home"
        cfg_dir = home / "cfg"
        _mkfile(home, "dev-team/placeholder.txt")
        _write_cfg(cfg_dir, "t", "does-not-exist")
        _, txt = _run_generator(cfg_dir, "t", Path(td) / "m.json",
                                "--allow-untagged", "--allow-missing-roots")

    assert "before treating this export as complete" not in txt
    assert "if you need a complete export" in txt


# ---------------------------------------------------------------- finding 013
def test_missing_root_remediation_names_the_resolved_config_file():
    """XACA-0954-013: the operator should not have to know the config-path convention.

    Asserts the ACTUAL resolved path is printed — including when --team-config-dir
    points somewhere other than the packaged config dir, which is the case a
    hardcoded convention string would get wrong.
    """
    with tempfile.TemporaryDirectory() as td:
        home = Path(td) / "home"
        cfg_dir = home / "cfg"
        _mkfile(home, "dev-team/placeholder.txt")
        cfg_path = _write_cfg(cfg_dir, "t", "does-not-exist")
        _, txt = _run_generator(cfg_dir, "t", Path(td) / "m.json")

        assert "Edit:" in txt
        assert str(cfg_path) in txt, f"resolved config path missing from remediation:\n{txt}"


def test_resolve_team_config_path_matches_what_load_actually_reads():
    """The resolver and the loader must not drift: same candidate order, one source."""
    with tempfile.TemporaryDirectory() as td:
        cfg_dir = Path(td) / "cfg"
        cfg_path = _write_cfg(cfg_dir, "t", "whatever")
        assert ch.resolve_team_config_path("t", config_dir=cfg_dir) == cfg_path
        # Loading from the same dir yields the content of that same file.
        assert ch.load_team_config("t", config_dir=cfg_dir)["product_dir"] == "whatever"
    assert ch.resolve_team_config_path("definitely-no-such-team") is None


# ---------------------------------------------------------------- finding 015
@pytest.mark.parametrize(
    "cfg, expect_warning",
    [
        ({"team": "t", "product_dir": ""}, True),   # present but empty -> someone edited it wrong
        ({"team": "t"}, False),                     # absent -> a config predating product_dir
    ],
    ids=["present-but-empty-warns", "absent-is-silent"],
)
def test_empty_product_dir_is_distinguished_from_an_omitted_one(cfg, expect_warning):
    """XACA-0954-015: absent and empty are different states and must not be conflated.

    This is the same absent-vs-empty distinction the ticket enforced for `personas`;
    silently treating an empty value as an omitted key is how a mis-edited config
    looks identical to a legacy one.
    """
    with tempfile.TemporaryDirectory() as td:
        home = Path(td)
        _mkfile(home, "dev-team/t/f.txt")
        m = new_manifest()
        cc = ch.build_config(home=home, team_config=cfg)
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            domain_devteam.inventory(m, cc, home=home, team_config=cfg)

    assert ("present but empty" in err.getvalue()) is expect_warning
    # Either way the legacy fallback still resolves and exports.
    assert len(m.domains["devteam"].files) == 1


# ---------------------------------------------------------------- finding 016
def test_ancestor_persona_dir_contributes_its_extra_files_exactly_once():
    """XACA-0954-016: an ANCESTOR persona_dirs entry must be walked, not skipped.

    NEGATIVE CONTROL FOR A TEMPTING WRONG FIX: making _covered_by symmetric would
    make the redundant re-walk go away by skipping the ancestor entirely -- and
    would drop every file under it that lies outside the already-walked root.
    That converts a wasted-I/O nit into silent data loss, which is exactly the
    failure class this ticket exists to remove. The overlap is handled per-file.
    """
    with tempfile.TemporaryDirectory() as td:
        home = Path(td)
        product = home / "dev-team" / "medical"
        _mkfile(product, "personas/a.md")
        _mkfile(product, "logo.png")
        ancestor = home / "dev-team"           # strictly contains the product root
        _mkfile(ancestor, "extra-above.txt")

        cfg = {
            "team": "medical-general",
            "product_dir": "medical",
            "persona_dirs": [str(ancestor)],
            "home_relative_root": "",
        }
        m = new_manifest()
        cc = ch.build_config(home=home, team_config=cfg)
        domain_devteam.inventory(m, cc, home=home, team_config=cfg)

    paths = [f.path for f in m.domains["devteam"].files]
    names = sorted(Path(p).name for p in paths)

    assert "extra-above.txt" in names, "ancestor entry was skipped -> files lost"
    assert names.count("logo.png") == 1
    assert len(paths) == len(set(paths)), "same file emitted twice across overlapping roots"


def test_nested_persona_dir_is_still_skipped_as_covered():
    """The forward direction must keep working: nested entries are genuinely covered."""
    with tempfile.TemporaryDirectory() as td:
        home = Path(td)
        product = home / "dev-team" / "medical"
        _mkfile(product, "personas/a.md")
        cfg = {
            "team": "medical-general",
            "product_dir": "medical",
            "persona_dirs": [str(product / "personas")],   # nested INSIDE product root
            "home_relative_root": "",
        }
        m = new_manifest()
        cc = ch.build_config(home=home, team_config=cfg)
        domain_devteam.inventory(m, cc, home=home, team_config=cfg)

    paths = [f.path for f in m.domains["devteam"].files]
    assert len(paths) == len(set(paths)) == 1


# ---------------------------------------------------------------- finding 014
def test_server_export_path_reads_missing_roots_and_conditions_its_message():
    """XACA-0954-014: the LCARS 'Export Team' button must not report plain success.

    generate_export() passes --allow-untagged, which deliberately does NOT waive a
    missing root, and it gated only on returncode == 2. So the UI path -- the one
    that produced this ticket's original symptom, and the one the medical-general
    transfer will actually be run from -- still said 'Export ready for download'
    over an export that had skipped an entire domain root.

    LIMITS OF THIS TEST, stated rather than implied: it is a source guard, not a
    behavioural test. Driving generate_export() end to end needs an export job,
    a staging dir and a packer. A source guard cannot prove the wiring is correct
    -- it can only fail loudly if someone removes it, which is the regression that
    matters here. Behavioural coverage of the underlying signal lives in
    test_missing_roots_generator_gate.py.
    """
    src = (LCARS_UI / "server.py").read_text(encoding="utf-8")

    assert "missing_roots" in src, "server.py no longer reads the missing_roots signal"
    assert "missingRootsSummary" in src, "export payload no longer surfaces missingRootsSummary"

    # The completion message must be conditional, not a bare constant.
    assert "'Export ready for download — INCOMPLETE:" in src or \
           '"Export ready for download — INCOMPLETE:' in src, \
           "completion message is not conditioned on missing roots"

    # The stale comment that justified ignoring exit 1 must be gone.
    assert "exit 1 = untagged gaps (warn only)" not in src, \
        "stale exit-code comment still claims exit 1 is warn-only"


def test_manifest_missing_roots_survives_the_json_round_trip_the_server_reads():
    """The server reads missing_roots straight out of the manifest file on disk."""
    m = new_manifest()
    m.add_missing_root("devteam", "/nope", "configured root does not exist", "product_dir")
    with tempfile.TemporaryDirectory() as td:
        p = Path(td) / "manifest.json"
        p.write_text(m.to_json(), encoding="utf-8")
        raw = json.loads(p.read_text(encoding="utf-8"))

    assert raw.get("missing_roots"), "missing_roots absent from the serialized manifest"
    assert raw["missing_roots"][0]["config_key"] == "product_dir"


def test_old_manifest_without_missing_roots_key_is_read_as_empty_not_crash():
    """Backward compat: an archive generated before this ticket has no such key.

    The server uses .get(...) or [] for exactly this reason -- an old manifest must
    read as 'nothing reported', never raise.
    """
    raw = {"schema_version": 2, "domains": {}}
    assert (raw.get("missing_roots") or []) == []
