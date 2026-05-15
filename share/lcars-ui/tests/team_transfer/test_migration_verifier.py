"""Tests for the verifier — synthetic missing/mismatched cases."""
from __future__ import annotations

import hashlib
import os
import subprocess
import sys
from pathlib import Path

import pytest

from team_transfer import channels
from team_transfer.manifest import EXACT, FileEntry, Manifest, PRESENT, new_manifest
from team_transfer.verifier import main as verifier_main


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _make_manifest_with_file(p: Path, channel: str = channels.GIT) -> Manifest:
    data = p.read_bytes()
    m = new_manifest()
    fe = FileEntry(
        path=str(p),
        relpath=p.name,
        sha256=_sha256(data),
        size=len(data),
        mtime=p.stat().st_mtime,
        cls=EXACT,
        channel=channel,
        domain="git_repo",
    )
    m.add_file("git_repo", fe)
    m.recompute_channel_stats()
    return m


def _lcars_ui_dir() -> Path:
    """Return the lcars-ui/ directory (grandparent of this file's directory)."""
    return Path(__file__).resolve().parents[2]


def _run_verifier(manifest_path: Path) -> tuple[int, str]:
    lcars_ui = _lcars_ui_dir()
    env = os.environ.copy()
    pythonpath = str(lcars_ui)
    if env.get("PYTHONPATH"):
        pythonpath = pythonpath + ":" + env["PYTHONPATH"]
    env["PYTHONPATH"] = pythonpath
    proc = subprocess.run(
        [sys.executable, "-m", "team_transfer.verifier", "--manifest", str(manifest_path)],
        env=env, capture_output=True, text=True,
    )
    return proc.returncode, proc.stdout + proc.stderr


def test_pass_when_file_matches(tmp_path):
    p = tmp_path / "foo.txt"
    p.write_bytes(b"hello")
    m = _make_manifest_with_file(p)
    mp = tmp_path / "manifest.json"
    mp.write_text(m.to_json())
    rc, out = _run_verifier(mp)
    assert rc == 0
    assert "FAIL: 0" in out


def test_fail_when_file_missing(tmp_path):
    p = tmp_path / "vanishes.txt"
    p.write_bytes(b"data")
    m = _make_manifest_with_file(p)
    mp = tmp_path / "manifest.json"
    mp.write_text(m.to_json())
    p.unlink()
    rc, out = _run_verifier(mp)
    assert rc == 1
    assert "FAIL: 1" in out
    assert "missing on destination" in out


def test_fail_when_sha256_mismatch(tmp_path):
    p = tmp_path / "mod.txt"
    p.write_bytes(b"original")
    m = _make_manifest_with_file(p)
    mp = tmp_path / "manifest.json"
    mp.write_text(m.to_json())
    p.write_bytes(b"modified")
    rc, out = _run_verifier(mp)
    assert rc == 1
    assert "sha256 mismatch" in out


def test_icloud_excluded_entries_skipped(tmp_path):
    p = tmp_path / "secret.pdf"
    p.write_bytes(b"x")
    m = _make_manifest_with_file(p, channel=channels.ICLOUD_EXCLUDED)
    mp = tmp_path / "manifest.json"
    mp.write_text(m.to_json())
    p.unlink()  # would normally fail, but icloud_excluded should be skipped
    rc, out = _run_verifier(mp)
    assert rc == 0
    assert "skipped:   1" in out


def test_present_class_passes_on_existence_alone(tmp_path):
    p = tmp_path / "logfile"
    p.write_bytes(b"original")
    m = new_manifest()
    fe = FileEntry(
        path=str(p), relpath=p.name, sha256=None, size=8, mtime=p.stat().st_mtime,
        cls=PRESENT, channel=channels.EXPORT_KANBAN, domain="kanban",
    )
    m.add_file("kanban", fe)
    m.recompute_channel_stats()
    mp = tmp_path / "manifest.json"
    mp.write_text(m.to_json())
    p.write_bytes(b"different content")  # PRESENT class doesn't care about content
    rc, out = _run_verifier(mp)
    assert rc == 0


def test_per_channel_report_in_output(tmp_path):
    p = tmp_path / "x.txt"
    p.write_bytes(b"x")
    m = _make_manifest_with_file(p)
    mp = tmp_path / "manifest.json"
    mp.write_text(m.to_json())
    rc, out = _run_verifier(mp)
    # Per-channel block should be present and show all 5 channels.
    assert "PER-CHANNEL" in out
    for c in channels.ALL_CHANNELS:
        assert c in out


def _run_generator(out_path: Path) -> subprocess.CompletedProcess:
    """Shared helper — invoke generator with --output and return the completed process."""
    lcars_ui = _lcars_ui_dir()
    env = os.environ.copy()
    pythonpath = str(lcars_ui)
    if env.get("PYTHONPATH"):
        pythonpath = pythonpath + ":" + env["PYTHONPATH"]
    env["PYTHONPATH"] = pythonpath
    return subprocess.run(
        [sys.executable, "-m", "team_transfer.generator",
         "--output", str(out_path), "--allow-untagged"],
        env=env, capture_output=True, text=True,
    )


def test_generator_self_includes_manifest_in_output_when_under_home(tmp_path, monkeypatch):
    """Generator self-entry IS present when --output resolves under $HOME.

    XACA-0496-013: the self-entry is intentionally skipped when --output is
    outside $HOME (typically a temp/CI path) because the verifier could not
    locate it portably at destination $HOME. To test the in-home contract,
    pretend $HOME is the pytest tmp dir.
    """
    import json

    monkeypatch.setenv("HOME", str(tmp_path))
    out_path = tmp_path / "manifest.json"

    proc = _run_generator(out_path)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert out_path.exists()

    with open(out_path) as f:
        m = json.load(f)
    all_paths = [fe["path"] for d in m["domains"].values() for fe in d["files"]]
    assert str(out_path.resolve()) in all_paths, "manifest must self-reference when under HOME"

    self_entries = [
        fe for d in m["domains"].values() for fe in d["files"]
        if fe["path"] == str(out_path.resolve())
    ]
    assert len(self_entries) == 1
    assert self_entries[0]["cls"] == "present", "self-entry must be PRESENT-class (no self-hash paradox)"


def test_generator_skips_self_entry_when_output_outside_home(tmp_path):
    """XACA-0496-013: when --output is outside $HOME (e.g. /tmp/...), generator
    must NOT add a self-entry to the manifest. The entry would otherwise produce
    a spurious FAIL on every same-machine verify-only run because the temp file
    is gone before the verifier runs.
    """
    import json

    # tmp_path under pytest is /var/folders/... or /tmp/... — both outside $HOME.
    # Sanity-check that assumption before relying on it.
    home = Path(os.environ.get("HOME", "/"))
    try:
        tmp_path.relative_to(home)
        pytest.skip(f"pytest tmp_path {tmp_path} happens to be under HOME {home}; cannot exercise this branch")
    except ValueError:
        pass

    out_path = tmp_path / "manifest.json"
    proc = _run_generator(out_path)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert out_path.exists()
    assert "Skipping self-entry" in (proc.stdout + proc.stderr)

    with open(out_path) as f:
        m = json.load(f)
    all_paths = [fe["path"] for d in m["domains"].values() for fe in d["files"]]
    assert str(out_path.resolve()) not in all_paths, "self-entry must NOT appear when output is outside HOME"


def test_generator_dedupes_cross_domain_duplicates(tmp_path, monkeypatch):
    """XACA-0496-012: a file claimed by multiple domains must appear in the
    manifest exactly once, with priority going to the more-specific domain.
    """
    import json

    monkeypatch.setenv("HOME", str(tmp_path))
    out_path = tmp_path / "manifest.json"

    proc = _run_generator(out_path)
    assert proc.returncode == 0, proc.stdout + proc.stderr

    with open(out_path) as f:
        m = json.load(f)
    all_paths = [fe["path"] for d in m["domains"].values() for fe in d["files"]]
    duplicates = [p for p in set(all_paths) if all_paths.count(p) > 1]
    assert not duplicates, f"manifest has cross-domain duplicates: {duplicates[:5]}"



# ---------------------------------------------------------------------------
# TestPathMap — coverage for the --path-map SRC=DST flag
# ---------------------------------------------------------------------------

def _make_manifest_with_path(
    logical_path: str,
    actual_file: Path,
    src_home: str = "",
    channel: str = channels.GIT,
) -> Manifest:
    """Build a manifest whose FileEntry.path is *logical_path* but the actual
    bytes come from *actual_file*.  Used to simulate manifests produced on a
    different machine with a different directory layout.
    """
    data = actual_file.read_bytes()
    m = Manifest(
        schema_version=2,
        generated_at="2026-01-01T00:00:00+00:00",
        source_hostname="src-host",
        source_user="srcuser",
        home=src_home or str(Path.home()),
        channels=list(channels.ALL_CHANNELS),
    )
    fe = FileEntry(
        path=logical_path,
        relpath=Path(logical_path).name,
        sha256=_sha256(data),
        size=len(data),
        mtime=actual_file.stat().st_mtime,
        cls=EXACT,
        channel=channel,
        domain="git_repo",
    )
    m.add_file("git_repo", fe)
    m.recompute_channel_stats()
    return m


# ── Per-channel class invariant guard (XACA-0488-006) ─────────────────────────

def _make_manifest_with_entry(p: Path, channel: str, cls: str, sha: str | None = None) -> "Manifest":
    from team_transfer.manifest import new_manifest
    m = new_manifest()
    fe = FileEntry(
        path=str(p),
        relpath=p.name,
        sha256=sha,
        size=p.stat().st_size if p.exists() else 0,
        mtime=p.stat().st_mtime if p.exists() else 0.0,
        cls=cls,
        channel=channel,
        domain="git_repo",
    )
    m.add_file("git_repo", fe)
    m.recompute_channel_stats()
    return m


class TestPathMap:
    """Unit tests for the --path-map SRC=DST flag.

    All tests call verifier_main() directly with a synthesised argv list so
    that CI can exercise path-rewriting logic without a subprocess round-trip.
    Filesystem scenarios use the pytest *tmp_path* fixture; rewrite-only
    scenarios assert on the FAIL output line, which reveals the resolved path.
    """

    # ------------------------------------------------------------------
    # 1. Single map applies before the filesystem check
    # ------------------------------------------------------------------
    def test_single_map_rewrites_before_fs_check(self, tmp_path, capsys):
        """--path-map /SRC=<tmp_path> causes verifier to look under tmp_path."""
        actual = tmp_path / "hello.txt"
        actual.write_bytes(b"content")

        # Manifest path uses a fake /SRC prefix; actual file lives under tmp_path.
        logical = "/SRC/hello.txt"
        m = _make_manifest_with_path(logical, actual)
        manifest_path = tmp_path / "manifest.json"
        manifest_path.write_text(m.to_json())

        rc = verifier_main([
            "--manifest", str(manifest_path),
            "--path-map", f"/SRC={tmp_path}",
        ])
        out, _ = capsys.readouterr()
        assert rc == 0, f"Expected pass but got rc={rc}. Output:\n{out}"
        assert "FAIL: 0" in out

    # ------------------------------------------------------------------
    # 2. First-match-wins ordering
    # ------------------------------------------------------------------
    def test_first_match_wins(self, tmp_path, capsys):
        """/a/b/c should rewrite via /a (first), not /a/b (second)."""
        # Create the file at tmp_path/x/b/c (the first-map destination).
        dest_x = tmp_path / "x" / "b" / "c"
        dest_x.parent.mkdir(parents=True)
        dest_x.write_bytes(b"first-match")

        logical = "/a/b/c"
        m = _make_manifest_with_path(logical, dest_x)
        manifest_path = tmp_path / "manifest.json"
        manifest_path.write_text(m.to_json())

        rc = verifier_main([
            "--manifest", str(manifest_path),
            "--path-map", f"/a={tmp_path}/x",    # first map: /a -> tmp/x
            "--path-map", f"/a/b={tmp_path}/y",  # second map: would give tmp/y/c (no file there)
        ])
        out, _ = capsys.readouterr()
        assert rc == 0, f"Expected first-match to win. rc={rc}. Output:\n{out}"
        assert "FAIL: 0" in out

    # ------------------------------------------------------------------
    # 3. No-match passthrough
    # ------------------------------------------------------------------
    def test_no_match_passthrough(self, tmp_path, capsys):
        """--path-map with an unrelated SRC leaves the manifest path unchanged."""
        actual = tmp_path / "untouched.txt"
        actual.write_bytes(b"data")

        # Manifest records the real tmp_path location; map points elsewhere.
        m = _make_manifest_with_path(str(actual), actual)
        manifest_path = tmp_path / "manifest.json"
        manifest_path.write_text(m.to_json())

        rc = verifier_main([
            "--manifest", str(manifest_path),
            "--path-map", "/UNRELATED=/whatever",
        ])
        out, _ = capsys.readouterr()
        # The path was not rewritten so the file is still found.
        assert rc == 0, f"Expected pass when no map matches. rc={rc}. Output:\n{out}"
        assert "FAIL: 0" in out

    # ------------------------------------------------------------------
    # 4. Malformed --path-map (no '=') exits 2 with helpful stderr
    # ------------------------------------------------------------------
    def test_malformed_path_map_exits_2(self, tmp_path, capsys):
        """--path-map without '=' must exit 2 and emit an error to stderr."""
        actual = tmp_path / "any.txt"
        actual.write_bytes(b"x")
        m = _make_manifest_with_path(str(actual), actual)
        manifest_path = tmp_path / "manifest.json"
        manifest_path.write_text(m.to_json())

        rc = verifier_main([
            "--manifest", str(manifest_path),
            "--path-map", "foobar",   # missing '='
        ])
        _, err = capsys.readouterr()
        assert rc == 2, f"Expected exit 2 for malformed --path-map, got {rc}"
        assert "SRC=DST" in err or "foobar" in err, (
            f"Expected helpful error in stderr. Got: {err!r}"
        )

    # ------------------------------------------------------------------
    # 5. DST containing '=' (split on first '=' only)
    # ------------------------------------------------------------------
    def test_dst_containing_equals(self, tmp_path, capsys):
        """/SRC=/DST=tag correctly splits to src=/SRC, dst=/DST=tag."""
        dest_dir = tmp_path / "DST=tag"
        dest_dir.mkdir()
        actual = dest_dir / "file.txt"
        actual.write_bytes(b"eq-test")

        logical = "/SRC/file.txt"
        m = _make_manifest_with_path(logical, actual)
        manifest_path = tmp_path / "manifest.json"
        manifest_path.write_text(m.to_json())

        rc = verifier_main([
            "--manifest", str(manifest_path),
            "--path-map", f"/SRC={dest_dir}",  # DST contains no '=' but path itself might
        ])
        out, _ = capsys.readouterr()
        assert rc == 0, f"Expected pass. rc={rc}. Output:\n{out}"
        assert "FAIL: 0" in out

    def test_dst_equals_in_raw_value(self, tmp_path, capsys):
        """Raw --path-map /SRC=/path/DST=extra correctly parses via split('=', 1)."""
        # The destination directory name contains a literal '='
        dest_dir = tmp_path / "DST=extra"
        dest_dir.mkdir()
        actual = dest_dir / "data.txt"
        actual.write_bytes(b"split-test")

        logical = "/SRC/data.txt"
        m = _make_manifest_with_path(logical, actual)
        manifest_path = tmp_path / "manifest.json"
        manifest_path.write_text(m.to_json())

        # Pass the raw string as the CLI would receive it.
        raw_map = f"/SRC={dest_dir}"  # e.g. /SRC=/tmp/pytest-xxx/DST=extra
        rc = verifier_main([
            "--manifest", str(manifest_path),
            "--path-map", raw_map,
        ])
        out, _ = capsys.readouterr()
        assert rc == 0, f"split-on-first-= failed. rc={rc}. Output:\n{out}"
        assert "FAIL: 0" in out

    # ------------------------------------------------------------------
    # 6. Fallback to home-prefix rewrite when no path-map matches
    # ------------------------------------------------------------------
    def test_fallback_home_rewrite_when_no_map_matches(self, tmp_path, capsys):
        """When --path-map is present but doesn't match, home-prefix rewrite still fires."""
        # Simulate: source HOME=/Users/src, dst HOME=tmp_path.
        # The file lives at <tmp_path>/testfile.txt on this (destination) machine.
        actual = tmp_path / "testfile.txt"
        actual.write_bytes(b"home-fallback")

        fake_src_home = "/Users/src"
        logical = f"{fake_src_home}/testfile.txt"

        m = Manifest(
            schema_version=2,
            generated_at="2026-01-01T00:00:00+00:00",
            source_hostname="src-host",
            source_user="srcuser",
            home=fake_src_home,
            channels=list(channels.ALL_CHANNELS),
        )
        fe = FileEntry(
            path=logical,
            relpath="testfile.txt",
            sha256=_sha256(actual.read_bytes()),
            size=len(actual.read_bytes()),
            mtime=actual.stat().st_mtime,
            cls=EXACT,
            channel=channels.GIT,
            domain="git_repo",
        )
        m.add_file("git_repo", fe)
        m.recompute_channel_stats()
        manifest_path = tmp_path / "manifest.json"
        manifest_path.write_text(m.to_json())

        # Monkeypatch Path.home() to return tmp_path for this call.
        import team_transfer.verifier as verifier_mod
        original_home = Path.home

        class _FakeHome:
            @staticmethod
            def __str__():
                return str(tmp_path)

        # We patch the dst_home derivation by monkey-patching the stdlib call.
        original_path_home = Path.home

        def fake_home():
            return tmp_path

        Path.home = staticmethod(fake_home)  # type: ignore[assignment]
        try:
            rc = verifier_main([
                "--manifest", str(manifest_path),
                "--path-map", "/UNRELATED=/whatever",
            ])
        finally:
            Path.home = staticmethod(original_path_home)  # type: ignore[assignment]

        out, _ = capsys.readouterr()
        assert rc == 0, (
            f"Expected home-prefix fallback to succeed when no map matches. "
            f"rc={rc}. Output:\n{out}"
        )
        assert "FAIL: 0" in out

    # ------------------------------------------------------------------
    # 7. Multiple non-overlapping mappings both apply (separate entries)
    # ------------------------------------------------------------------
    def test_multiple_non_overlapping_maps(self, tmp_path, capsys):
        """Two entries with distinct SRC prefixes both rewrite to their DSTs."""
        dir_a = tmp_path / "dest_a"
        dir_b = tmp_path / "dest_b"
        dir_a.mkdir()
        dir_b.mkdir()
        file_a = dir_a / "alpha.txt"
        file_b = dir_b / "beta.txt"
        file_a.write_bytes(b"alpha")
        file_b.write_bytes(b"beta")

        m = Manifest(
            schema_version=2,
            generated_at="2026-01-01T00:00:00+00:00",
            source_hostname="src-host",
            source_user="srcuser",
            home=str(Path.home()),
            channels=list(channels.ALL_CHANNELS),
        )
        for logical, actual in [("/SRC_A/alpha.txt", file_a), ("/SRC_B/beta.txt", file_b)]:
            data = actual.read_bytes()
            fe = FileEntry(
                path=logical,
                relpath=actual.name,
                sha256=_sha256(data),
                size=len(data),
                mtime=actual.stat().st_mtime,
                cls=EXACT,
                channel=channels.GIT,
                domain="git_repo",
            )
            m.add_file("git_repo", fe)
        m.recompute_channel_stats()
        manifest_path = tmp_path / "manifest.json"
        manifest_path.write_text(m.to_json())

        rc = verifier_main([
            "--manifest", str(manifest_path),
            "--path-map", f"/SRC_A={dir_a}",
            "--path-map", f"/SRC_B={dir_b}",
        ])
        out, _ = capsys.readouterr()
        assert rc == 0, f"Both non-overlapping maps should apply. rc={rc}. Output:\n{out}"
        assert "FAIL: 0" in out

    # ------------------------------------------------------------------
    # 8. Empty path_maps list == flag omitted
    # ------------------------------------------------------------------
    def test_no_path_map_flag_matches_empty_list(self, tmp_path, capsys):
        """Running without --path-map produces the same outcome as --path-map list empty."""
        actual = tmp_path / "same.txt"
        actual.write_bytes(b"identical")
        m = _make_manifest_with_path(str(actual), actual)
        manifest_path = tmp_path / "manifest.json"
        manifest_path.write_text(m.to_json())

        rc_no_flag = verifier_main(["--manifest", str(manifest_path)])
        out_no_flag, _ = capsys.readouterr()

        # Passing zero --path-map entries explicitly is the same as omitting the flag.
        # argparse accumulates append-action args; passing none leaves the list empty.
        rc_empty = verifier_main(["--manifest", str(manifest_path)])
        out_empty, _ = capsys.readouterr()

        assert rc_no_flag == rc_empty == 0
        # Both runs should report zero failures.
        assert "FAIL: 0" in out_no_flag
        assert "FAIL: 0" in out_empty

    # ------------------------------------------------------------------
    # 9. Trailing slashes on SRC or DST are normalized (gated on XACA-0489-009)
    # ------------------------------------------------------------------
    def test_trailing_slash_normalization(self, tmp_path, capsys):
        """--path-map /SRC/=/DST, /SRC=/DST/, and /SRC/=/DST/ all rewrite correctly."""
        actual = tmp_path / "file.txt"
        actual.write_bytes(b"normalize-me")

        logical = "/SRC/file.txt"
        m = _make_manifest_with_path(logical, actual)
        manifest_path = tmp_path / "manifest.json"
        manifest_path.write_text(m.to_json())

        variants = [
            f"/SRC/={tmp_path}",     # trailing slash on SRC only
            f"/SRC={tmp_path}/",     # trailing slash on DST only
            f"/SRC/={tmp_path}/",    # trailing slash on both
        ]
        for raw_map in variants:
            rc = verifier_main([
                "--manifest", str(manifest_path),
                "--path-map", raw_map,
            ])
            out, _ = capsys.readouterr()
            assert rc == 0, (
                f"Trailing-slash variant {raw_map!r} failed. rc={rc}. Output:\n{out}"
            )
            assert "FAIL: 0" in out, (
                f"Expected FAIL: 0 for variant {raw_map!r}. Output:\n{out}"
            )


def test_invariant_aiteamforge_product_rejects_exact(tmp_path):
    """aiteamforge_product entries with cls=exact must fail the invariant check."""
    p = tmp_path / "agent.sh"
    p.write_bytes(b"#!/bin/sh\n")
    m = _make_manifest_with_entry(p, channels.AITEAMFORGE_PRODUCT, EXACT,
                                  sha=_sha256(p.read_bytes()))
    mp = tmp_path / "manifest.json"
    mp.write_text(m.to_json())
    rc, out = _run_verifier(mp)
    assert rc == 1
    assert "channel-class invariant violated" in out
    assert "aiteamforge_product" in out


def test_invariant_aiteamforge_product_passes_present(tmp_path):
    """aiteamforge_product entries with cls=present must pass the invariant check."""
    p = tmp_path / "agent.sh"
    p.write_bytes(b"#!/bin/sh\n")
    m = _make_manifest_with_entry(p, channels.AITEAMFORGE_PRODUCT, PRESENT)
    mp = tmp_path / "manifest.json"
    mp.write_text(m.to_json())
    rc, out = _run_verifier(mp)
    assert rc == 0
    assert "channel-class invariant violated" not in out


def test_invariant_export_database_rejects_present(tmp_path):
    """export_database entries with cls=present must fail the invariant check."""
    p = tmp_path / "fin.db"
    p.write_bytes(b"SQLite")
    m = _make_manifest_with_entry(p, channels.EXPORT_DATABASE, PRESENT)
    mp = tmp_path / "manifest.json"
    mp.write_text(m.to_json())
    rc, out = _run_verifier(mp)
    assert rc == 1
    assert "channel-class invariant violated" in out
    assert "export_database" in out


def test_invariant_export_database_rejects_exact(tmp_path):
    """export_database entries with cls=exact must fail the invariant check."""
    p = tmp_path / "fin.db"
    p.write_bytes(b"SQLite")
    m = _make_manifest_with_entry(p, channels.EXPORT_DATABASE, EXACT,
                                  sha=_sha256(p.read_bytes()))
    mp = tmp_path / "manifest.json"
    mp.write_text(m.to_json())
    rc, out = _run_verifier(mp)
    assert rc == 1
    assert "channel-class invariant violated" in out


def test_invariant_user_state_allows_exact_and_present(tmp_path):
    """user_state allows both exact (memory) and present (session logs)."""
    p = tmp_path / "MEMORY.md"
    p.write_bytes(b"# memory")
    # exact for authored files
    m = _make_manifest_with_entry(p, channels.USER_STATE, EXACT,
                                  sha=_sha256(p.read_bytes()))
    mp = tmp_path / "manifest.json"
    mp.write_text(m.to_json())
    rc, out = _run_verifier(mp)
    assert rc == 0, f"user_state+exact should pass; got: {out}"

    q = tmp_path / "session.jsonl"
    q.write_bytes(b"{}")
    m2 = _make_manifest_with_entry(q, channels.USER_STATE, PRESENT)
    mp2 = tmp_path / "manifest2.json"
    mp2.write_text(m2.to_json())
    rc2, out2 = _run_verifier(mp2)
    assert rc2 == 0, f"user_state+present should pass; got: {out2}"


def test_invariant_export_kanban_accepts_exact_for_authored(tmp_path):
    """export_kanban accepts cls=exact for authored content (EPIC-*.md, retros, plan docs).

    Lock files use PRESENT and the board JSON uses SCHEMA, but authored markdown under
    kanban/ benefits from SHA verification — the invariant must permit it.
    """
    p = tmp_path / "EPIC-0001.md"
    p.write_bytes(b"# epic body\n")
    m = _make_manifest_with_entry(p, channels.EXPORT_KANBAN, EXACT,
                                  sha=_sha256(p.read_bytes()))
    mp = tmp_path / "manifest.json"
    mp.write_text(m.to_json())
    rc, out = _run_verifier(mp)
    assert rc == 0, f"export_kanban+exact should pass; got: {out}"
    assert "channel-class invariant violated" not in out


def test_invariant_git_channel_has_no_constraint(tmp_path):
    """git channel has no cls invariant — any cls value should pass the guard."""
    p = tmp_path / "main.py"
    p.write_bytes(b"print('hi')")
    # git channel with exact — normal case, should never hit an invariant error
    m = _make_manifest_with_entry(p, channels.GIT, EXACT,
                                  sha=_sha256(p.read_bytes()))
    mp = tmp_path / "manifest.json"
    mp.write_text(m.to_json())
    rc, out = _run_verifier(mp)
    assert rc == 0
    assert "channel-class invariant violated" not in out
