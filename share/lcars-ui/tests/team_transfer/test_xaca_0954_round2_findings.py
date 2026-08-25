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
import shutil
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
def _load_server_module():
    """Import server.py as a module. It has no import-time side effects beyond
    two optional-dependency warnings; it does not boot the HTTP server."""
    import importlib.util

    spec = importlib.util.spec_from_file_location("lcars_server_under_test", LCARS_UI / "server.py")
    mod = importlib.util.module_from_spec(spec)
    sys.modules["lcars_server_under_test"] = mod
    spec.loader.exec_module(mod)
    return mod


def test_export_read_missing_roots_returns_configured_gaps(tmp_path):
    """XACA-0954-019: behavioural, not a source guard."""
    srv = _load_server_module()
    m = new_manifest()
    m.add_missing_root("devteam", "/nope", "configured root does not exist", "product_dir")
    mf = tmp_path / "manifest.json"
    mf.write_text(m.to_json(), encoding="utf-8")

    got = srv._export_read_missing_roots(mf)
    assert len(got) == 1
    assert got[0]["config_key"] == "product_dir"


def test_export_read_missing_roots_is_empty_for_a_pre_ticket_manifest(tmp_path):
    """An archive generated before this ticket has no such key: nothing to report."""
    srv = _load_server_module()
    mf = tmp_path / "manifest.json"
    mf.write_text('{"schema_version": 2, "domains": {}}', encoding="utf-8")
    assert srv._export_read_missing_roots(mf) == []


@pytest.mark.parametrize("body", ["{not json", ""], ids=["corrupt", "empty"])
def test_export_read_missing_roots_fails_CLOSED_on_an_unreadable_manifest(tmp_path, body):
    """A manifest we cannot parse is NOT evidence of completeness.

    This is the ticket's own thesis applied to the reader: returning [] here would
    manufacture a reassuring answer from a check that never actually ran.
    """
    srv = _load_server_module()
    mf = tmp_path / "manifest.json"
    mf.write_text(body, encoding="utf-8")

    got = srv._export_read_missing_roots(mf)
    assert got, "unreadable manifest reported as 'no missing roots'"
    assert got[0]["config_key"] == "(unreadable)"


def test_export_read_missing_roots_fails_CLOSED_on_a_absent_manifest(tmp_path):
    srv = _load_server_module()
    got = srv._export_read_missing_roots(tmp_path / "does-not-exist.json")
    assert got and got[0]["config_key"] == "(unreadable)"


def test_export_completion_message_never_implies_completeness_wrongly():
    srv = _load_server_module()
    assert srv._export_completion_message([]) == "Export ready for download"

    msg = srv._export_completion_message([{"domain": "devteam", "path": "/nope"}])
    assert "INCOMPLETE" in msg
    assert "1 configured domain root(s) were never scanned" in msg


def test_export_missing_roots_summary_shape_is_renderable():
    srv = _load_server_module()
    clean = srv._export_missing_roots_summary([])
    assert clean == {"count": 0, "complete": True, "roots": []}

    dirty = srv._export_missing_roots_summary([
        {"domain": "devteam", "path": "/nope", "config_key": "product_dir", "reason": "gone"},
    ])
    assert dirty["count"] == 1 and dirty["complete"] is False
    assert dirty["roots"][0] == {
        "domain": "devteam", "path": "/nope", "configKey": "product_dir", "reason": "gone",
    }


def test_generate_export_is_actually_wired_to_those_helpers():
    """The helpers being correct is worthless if generate_export stopped calling them.

    Deliberately a source guard: this pins the WIRING, which the unit tests above
    cannot see. Driving generate_export() end to end needs a job, a staging dir and
    the packer.
    """
    src = (LCARS_UI / "server.py").read_text(encoding="utf-8")
    assert "_export_read_missing_roots(tt_manifest_path)" in src
    assert "_export_completion_message(missing_roots_detail)" in src
    assert "_export_missing_roots_summary(missing_roots_detail)" in src
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


# ---------------------------------------------------------------- finding 018
def _extract_js_functions(src: str, names: list[str]) -> str:
    """Pull named top-level `function foo(...) { ... }` blocks out of lcars.js.

    lcars.js is ~18k lines of browser globals and cannot be imported standalone,
    but the export-panel logic is self-contained. Extracting just those functions
    lets us drive the REAL shipped code against a stub DOM instead of settling for
    a source guard — the finding here was precisely that correct backend data was
    never rendered, which a source guard proves poorly.
    """
    out = []
    for name in names:
        start = src.index(f"function {name}(")
        depth, i, seen = 0, src.index("{", start), False
        while i < len(src):
            if src[i] == "{":
                depth += 1
                seen = True
            elif src[i] == "}":
                depth -= 1
                if seen and depth == 0:
                    break
            i += 1
        out.append(src[start:i + 1])
    return "\n\n".join(out)


NODE = shutil.which("node")
_encode = json.JSONEncoder().encode


@pytest.mark.skipif(NODE is None, reason="node not available")
@pytest.mark.parametrize(
    "summary, expect_status, expect_label, expect_box",
    [
        (None,                                          "READY",      "COMPLETE",   False),
        ({"count": 0, "complete": True, "roots": []},    "READY",      "COMPLETE",   False),
        ({"count": 1, "complete": False,
          "roots": [{"domain": "devteam", "path": "/nope",
                     "configKey": "product_dir", "reason": "gone"}]},
                                                        "INCOMPLETE", "INCOMPLETE", True),
    ],
    ids=["no-summary", "complete", "one-missing-root"],
)
def test_export_panel_never_reads_READY_over_an_unscanned_root(
    summary, expect_status, expect_label, expect_box, tmp_path
):
    """XACA-0954-018: the LCARS export panel must not render READY over a partial export.

    The backend was fixed to emit missingRootsSummary, but the frontend referenced
    it nowhere: onExportComplete() set '#export-status-label' to 'READY'
    unconditionally, and the only signal reaching the DOM was data.message as plain
    text, positioned AFTER the phrase "Export ready for download". Correct data that
    nothing renders is not a fixed interface — this is XACA-0954's own defect one
    layer above the backend fix.

    Drives the real shipped functions against a stub DOM.
    """
    src = (LCARS_UI / "js" / "lcars.js").read_text(encoding="utf-8")
    js = _extract_js_functions(src, ["updateExportProgress", "renderExportMissingRoots",
                                     "onExportComplete"])

    harness = tmp_path / "h.js"
    harness.write_text(
        """
const els = {};
function mk(id) {
  return { id, textContent: '', style: { cssText: '', width: '', display: '' },
           children: [], className: '', disabled: false,
           appendChild(c) { this.children.push(c); c.parent = this; },
           remove() { if (this.parent) this.parent.children =
                        this.parent.children.filter(x => x !== this); delete els[this.id]; } };
}
for (const id of ['export-progress-bar','export-progress-percent','export-progress-label',
                  'export-progress-message','export-btn','export-download','export-status-label',
                  'export-download-filename','export-download-size','export-download-files']) {
  els[id] = mk(id);
}
global.document = {
  getElementById: (id) => els[id] || null,
  createElement: (tag) => mk('__' + tag),
};
"""
        + js
        + """
const SUMMARY = JSON.parse(process.argv[2]);
const data = { filename: 'x.zip', fileSize: '1 MB', totalFiles: 3,
               message: 'Export ready for download' };
if (SUMMARY !== null) data.missingRootsSummary = SUMMARY;
onExportComplete(data);
function findBox(node) {
  if (!node || !node.children) return null;
  for (const c of node.children) {
    if (c.id === 'export-missing-roots') return c;
    const f = findBox(c); if (f) return f;
  }
  return null;
}
console.log(JSON.stringify({
  status: els['export-status-label'].textContent,
  label: els['export-progress-label'].textContent,
  box: !!findBox(els['export-download']),
}));
""",
        encoding="utf-8",
    )

    proc = subprocess.run([NODE, str(harness), _encode(summary)],
                          capture_output=True, text=True, timeout=60)
    assert proc.returncode == 0, f"harness failed:\n{proc.stdout}\n{proc.stderr}"
    got = json.loads(proc.stdout.strip().splitlines()[-1])

    assert got["status"] == expect_status, f"status label wrong: {got}"
    assert got["label"] == expect_label, f"progress label wrong: {got}"
    assert got["box"] is expect_box, f"missing-roots box presence wrong: {got}"
