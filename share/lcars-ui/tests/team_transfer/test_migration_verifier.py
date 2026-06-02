"""Tests for the verifier — synthetic missing/mismatched cases."""
from __future__ import annotations

import hashlib
import os
import subprocess
import sys
from pathlib import Path

import pytest

from team_transfer import channels
from team_transfer.manifest import EXACT, FileEntry, Manifest, PRESENT, SCHEMA, new_manifest
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


def test_aiteamforge_product_entries_skipped_when_missing(tmp_path):
    """XACA-0581: aiteamforge_product is installer-owned and SKIPPED by the
    preflight — a missing file must not FAIL (it would be a false negative on a
    tap install, where these files live at a different subdirectory layout)."""
    p = tmp_path / "agent.sh"
    p.write_bytes(b"#!/bin/sh\n")
    m = _make_manifest_with_entry(p, channels.AITEAMFORGE_PRODUCT, PRESENT)
    mp = tmp_path / "manifest.json"
    mp.write_text(m.to_json())
    p.unlink()  # would normally FAIL, but aiteamforge_product is skipped
    rc, out = _run_verifier(mp)
    assert rc == 0, f"aiteamforge_product missing file must be skipped, not fail; got: {out}"
    assert "skipped:   1" in out
    assert "channel-class invariant violated" not in out


def test_aiteamforge_product_skipped_regardless_of_cls(tmp_path):
    """XACA-0581: because the channel is skipped before _check_one, the former
    cls invariant for aiteamforge_product is no longer enforced — an exact-class
    entry no longer raises a channel-class violation (it is simply skipped)."""
    p = tmp_path / "agent.sh"
    p.write_bytes(b"#!/bin/sh\n")
    m = _make_manifest_with_entry(p, channels.AITEAMFORGE_PRODUCT, EXACT,
                                  sha=_sha256(p.read_bytes()))
    mp = tmp_path / "manifest.json"
    mp.write_text(m.to_json())
    rc, out = _run_verifier(mp)
    assert rc == 0, f"skipped channel must not fail on cls; got: {out}"
    assert "channel-class invariant violated" not in out
    assert "skipped:   1" in out


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


# ---------------------------------------------------------------------------
# TestPhaseDispositions — XACA-0583: PENDING-IMPORT / EXPECTED-MISSING / --phase
# ---------------------------------------------------------------------------

def _manifest_with_custom_relpath(
    path: str, relpath: str, channel: str, cls: str, sha: str | None = None, size: int = 0,
) -> Manifest:
    """Build a single-entry manifest with an arbitrary (path, relpath) pair.

    relpath drives ephemeral detection (matched against _EPHEMERAL_GLOBS); path drives
    the filesystem existence check. Same-machine (home unchanged) so no path rewrite.
    """
    m = new_manifest()
    fe = FileEntry(
        path=path, relpath=relpath, sha256=sha, size=size, mtime=0.0,
        cls=cls, channel=channel, domain="git_repo",
    )
    m.add_file("git_repo", fe)
    m.recompute_channel_stats()
    return m


class TestPhaseDispositions:
    """The XACA-0583 verdict matrix: carried-payload-absent and machine-local-absent
    must NOT be lumped into FAIL, and the discriminator is execution phase.

    Calls verifier_main() directly with capsys for speed (no subprocess round-trip).
    """

    # -- PENDING-IMPORT: carried payload, absent, pre-import -----------------
    def test_carried_payload_absent_pre_import_is_pending_not_fail(self, tmp_path, capsys):
        ghost = str(tmp_path / "ghost" / "MEMORY.md")  # never created
        m = _manifest_with_custom_relpath(ghost, "MEMORY.md", channels.USER_STATE, EXACT, sha="deadbeef")
        mp = tmp_path / "manifest.json"
        mp.write_text(m.to_json())
        rc = verifier_main(["--manifest", str(mp), "--phase", "pre-import"])
        out, _ = capsys.readouterr()
        assert rc == 0, f"pending-import must not set exit code. Output:\n{out}"
        assert "FAIL: 0" in out
        assert "PENDING-IMPORT: 1" in out
        assert "the import will create it" in out

    # -- FAIL: same entry, post-restore --------------------------------------
    def test_carried_payload_absent_post_restore_is_fail(self, tmp_path, capsys):
        ghost = str(tmp_path / "ghost" / "MEMORY.md")
        m = _manifest_with_custom_relpath(ghost, "MEMORY.md", channels.USER_STATE, EXACT, sha="deadbeef")
        mp = tmp_path / "manifest.json"
        mp.write_text(m.to_json())
        rc = verifier_main(["--manifest", str(mp), "--phase", "post-restore"])
        out, _ = capsys.readouterr()
        assert rc == 1, f"post-restore absent carried payload must FAIL. Output:\n{out}"
        assert "FAIL: 1" in out
        assert "missing on destination" in out
        assert "PENDING-IMPORT: 0" in out

    # -- default phase is post-restore (no behavior change for legacy callers)
    def test_default_phase_is_post_restore(self, tmp_path, capsys):
        ghost = str(tmp_path / "ghost" / "MEMORY.md")
        m = _manifest_with_custom_relpath(ghost, "MEMORY.md", channels.USER_STATE, EXACT, sha="deadbeef")
        mp = tmp_path / "manifest.json"
        mp.write_text(m.to_json())
        rc = verifier_main(["--manifest", str(mp)])  # no --phase
        out, _ = capsys.readouterr()
        assert rc == 1, f"default phase must be post-restore (legacy FAIL). Output:\n{out}"
        assert "FAIL: 1" in out

    # -- EXPECTED-MISSING: ephemeral session log, absent, BOTH phases --------
    @pytest.mark.parametrize("phase", ["pre-import", "post-restore"])
    def test_ephemeral_session_log_absent_is_expected_missing(self, tmp_path, capsys, phase):
        ghost = str(tmp_path / "ghost" / "abc.jsonl")  # never created
        relpath = ".claude/projects/-Users-x-finance-personal/abc.jsonl"
        m = _manifest_with_custom_relpath(ghost, relpath, channels.USER_STATE, PRESENT)
        mp = tmp_path / "manifest.json"
        mp.write_text(m.to_json())
        rc = verifier_main(["--manifest", str(mp), "--phase", phase])
        out, _ = capsys.readouterr()
        assert rc == 0, f"ephemeral absent must never FAIL (phase={phase}). Output:\n{out}"
        assert "FAIL: 0" in out
        assert "EXPECTED-MISSING: 1" in out
        assert "PENDING-IMPORT: 0" in out, "ephemeral must NOT be counted as pending"

    # -- ephemeral that DOES exist still passes normally ---------------------
    def test_ephemeral_present_passes(self, tmp_path, capsys):
        f = tmp_path / "abc.jsonl"
        f.write_bytes(b"{}")
        relpath = ".claude/projects/proj/abc.jsonl"
        m = _manifest_with_custom_relpath(str(f), relpath, channels.USER_STATE, PRESENT)
        mp = tmp_path / "manifest.json"
        mp.write_text(m.to_json())
        rc = verifier_main(["--manifest", str(mp), "--phase", "pre-import"])
        out, _ = capsys.readouterr()
        assert rc == 0
        assert "EXPECTED-MISSING: 0" in out, "present ephemeral is a normal PASS, not expected-missing"

    # -- XACA-0586-002: a present-but-mismatched carried file in PRE-IMPORT is STALE-OK
    #    (the overwrite-import will refresh it — reporting FAIL is a false negative that
    #    blocks apply unnecessarily). POST-RESTORE still FAILs (the import should have
    #    placed the correct content).
    def test_sha_mismatch_pre_import_is_stale_ok(self, tmp_path, capsys):
        f = tmp_path / "code.py"
        f.write_bytes(b"actual")
        m = _manifest_with_custom_relpath(str(f), "code.py", channels.GIT, EXACT,
                                          sha=_sha256(b"expected-different"), size=6)
        mp = tmp_path / "manifest.json"
        mp.write_text(m.to_json())
        rc = verifier_main(["--manifest", str(mp), "--phase", "pre-import"])
        out, _ = capsys.readouterr()
        assert rc == 0, "pre-import sha mismatch is STALE-OK (informational) — must not set exit code"
        assert "FAIL: 0" in out
        assert "STALE-OK: 1" in out
        assert "sha differs pre-import" in out
        assert "PENDING-IMPORT: 0" in out

    def test_sha_mismatch_post_restore_is_fail(self, tmp_path, capsys):
        f = tmp_path / "code.py"
        f.write_bytes(b"actual")
        m = _manifest_with_custom_relpath(str(f), "code.py", channels.GIT, EXACT,
                                          sha=_sha256(b"expected-different"), size=6)
        mp = tmp_path / "manifest.json"
        mp.write_text(m.to_json())
        rc = verifier_main(["--manifest", str(mp), "--phase", "post-restore"])
        out, _ = capsys.readouterr()
        assert rc == 1, "post-restore sha mismatch must FAIL (import should have placed correct content)"
        assert "sha256 mismatch" in out
        assert "STALE-OK: 0" in out

    # -- a present carried file passes pre-import (no spurious pending) -------
    def test_present_carried_file_passes_pre_import(self, tmp_path, capsys):
        f = tmp_path / "code.py"
        f.write_bytes(b"matched")
        m = _manifest_with_custom_relpath(str(f), "code.py", channels.GIT, EXACT,
                                          sha=_sha256(b"matched"), size=7)
        mp = tmp_path / "manifest.json"
        mp.write_text(m.to_json())
        rc = verifier_main(["--manifest", str(mp), "--phase", "pre-import"])
        out, _ = capsys.readouterr()
        assert rc == 0
        assert "FAIL: 0" in out
        assert "PENDING-IMPORT: 0" in out

    # -- summary always reports the two informational lines ------------------
    def test_summary_includes_pending_and_expected_lines(self, tmp_path, capsys):
        f = tmp_path / "ok.txt"
        f.write_bytes(b"x")
        m = _make_manifest_with_file(f)
        mp = tmp_path / "manifest.json"
        mp.write_text(m.to_json())
        rc = verifier_main(["--manifest", str(mp)])
        out, _ = capsys.readouterr()
        assert rc == 0
        assert "PENDING-IMPORT: 0" in out
        assert "EXPECTED-MISSING: 0" in out
        assert "Phase  : post-restore" in out

    # -- a NON-ephemeral PRESENT-class carried file absent post-restore FAILs -
    #    (preserves the contract the synthetic-E2E test used to cover via session.jsonl)
    def test_present_class_non_ephemeral_absent_is_fail(self, tmp_path, capsys):
        ghost = str(tmp_path / "ghost" / "kanban.lock")  # never created
        m = _manifest_with_custom_relpath(ghost, "kanban/kanban.lock", channels.EXPORT_KANBAN, PRESENT)
        mp = tmp_path / "manifest.json"
        mp.write_text(m.to_json())
        rc = verifier_main(["--manifest", str(mp), "--phase", "post-restore"])
        out, _ = capsys.readouterr()
        assert rc == 1, f"non-ephemeral PRESENT carried file absent post-restore must FAIL.\n{out}"
        assert "FAIL: 1" in out
        assert "EXPECTED-MISSING: 0" in out

    # -- upload-time import-preflight gate scenario (server.py:12878) ---------
    #    At upload time nothing is imported yet, so ALL carried payload is absent
    #    plus the ephemeral session logs. The server gates apply on FAIL==0
    #    (baseMatch). pre-import MUST yield exit 0 (apply allowed); the same manifest
    #    in post-restore MUST yield exit 1 (a real post-restore failure that blocks).
    #    This is the regression guarding the XACA-0583 server wiring.
    def test_import_preflight_all_carried_absent_pre_import_allows_apply(self, tmp_path, capsys):
        m = new_manifest()
        for rel in ("MEMORY.md", "knowledge/quark/INDEX.md", "uv.lock"):
            m.add_file("git_repo", FileEntry(
                path=str(tmp_path / "ghost" / rel), relpath=rel, sha256="dead", size=0,
                mtime=0.0, cls=EXACT, channel=channels.USER_STATE, domain="git_repo"))
        m.add_file("git_repo", FileEntry(
            path=str(tmp_path / "ghost" / "s.jsonl"),
            relpath=".claude/projects/-Users-x-finance/s.jsonl", sha256=None, size=0,
            mtime=0.0, cls=PRESENT, channel=channels.USER_STATE, domain="git_repo"))
        m.recompute_channel_stats()
        mp = tmp_path / "manifest.json"
        mp.write_text(m.to_json())

        rc_pre = verifier_main(["--manifest", str(mp), "--phase", "pre-import"])
        out_pre, _ = capsys.readouterr()
        assert rc_pre == 0, f"pre-import must allow apply (FAIL=0). Output:\n{out_pre}"
        assert "FAIL: 0" in out_pre
        assert "PENDING-IMPORT: 3" in out_pre
        assert "EXPECTED-MISSING: 1" in out_pre

        rc_post = verifier_main(["--manifest", str(mp), "--phase", "post-restore"])
        out_post, _ = capsys.readouterr()
        assert rc_post == 1, f"post-restore with absent carried payload must FAIL. Output:\n{out_post}"
        assert "FAIL: 3" in out_post
        assert "EXPECTED-MISSING: 1" in out_post

    # -- invalid --phase value is rejected by argparse -----------------------
    def test_invalid_phase_rejected(self, tmp_path, capsys):
        f = tmp_path / "ok.txt"
        f.write_bytes(b"x")
        m = _make_manifest_with_file(f)
        mp = tmp_path / "manifest.json"
        mp.write_text(m.to_json())
        with pytest.raises(SystemExit):
            verifier_main(["--manifest", str(mp), "--phase", "bogus"])


# ---------------------------------------------------------------------------
# TestBoardSchemaPhaseDispositions — XACA-0586: STALE-OK for board-schema entries
#
# The M1Pro field scenario: a board manifest whose captured item set is a SUPERSET
# of the on-disk board (board behind source, e.g. missing XFIN-0027-005..012) must
# yield STALE-OK + exit 0 under --phase pre-import, and FAIL + exit 1 under the
# default (post-restore) phase.  DATA-LOSS direction (destination board has items
# not in the manifest) must FAIL in BOTH phases.
# ---------------------------------------------------------------------------

import json as _json


def _make_board_manifest(
    tmp_path: Path,
    board_items: list[str],
    cap_item_ids: list[str],
    name: str = "board.json",
) -> Path:
    """Write a board JSON to disk + a single-entry SCHEMA manifest with the given probe."""
    board_path = tmp_path / name
    board_data = {"items": [{"id": i} for i in board_items]}
    board_path.write_text(_json.dumps(board_data))
    m = new_manifest()
    fe = FileEntry(
        path=str(board_path),
        relpath=f"kanban/{name}",
        sha256=None,
        size=board_path.stat().st_size,
        mtime=board_path.stat().st_mtime,
        cls=SCHEMA,
        channel=channels.EXPORT_KANBAN,
        domain="kanban",
        probe={"item_ids": cap_item_ids},
    )
    m.add_file("kanban", fe)
    m.recompute_channel_stats()
    mp = tmp_path / f"manifest_{name}.json"
    mp.write_text(m.to_json())
    return mp


class TestBoardSchemaPhaseDispositions:
    """_verify_board_schema: STALE-OK (board behind source, pre-import),
    FAIL (board behind source, post-restore), DATA-LOSS (board ahead of
    source, any phase), and the combined-direction edge case."""

    # -- board behind source: pre-import must be STALE-OK, exit 0 ------------
    def test_board_behind_pre_import_is_stale_ok(self, tmp_path, capsys):
        """Destination board has fewer items than manifest captured (board behind source).
        Pre-import: STALE-OK + exit 0 — overwrite-import will add the missing items."""
        disk_items = [f"XFIN-{i:04d}" for i in range(1, 4)]
        cap_items = [f"XFIN-{i:04d}" for i in range(1, 13)]
        mp = _make_board_manifest(tmp_path, disk_items, cap_items, "board_behind.json")
        rc = verifier_main(["--manifest", str(mp), "--phase", "pre-import"])
        out, _ = capsys.readouterr()
        assert rc == 0, f"board-behind pre-import must be STALE-OK (exit 0), got rc={rc}\n{out}"
        assert "STALE-OK: 1" in out
        assert "FAIL: 0" in out
        assert "board behind source" in out

    # -- board behind source: post-restore must FAIL, exit 1 -----------------
    def test_board_behind_post_restore_is_fail(self, tmp_path, capsys):
        """Same scenario post-restore: the import should have added the items → FAIL."""
        disk_items = [f"XFIN-{i:04d}" for i in range(1, 4)]
        cap_items = [f"XFIN-{i:04d}" for i in range(1, 13)]
        mp = _make_board_manifest(tmp_path, disk_items, cap_items, "board_behind_post.json")
        rc = verifier_main(["--manifest", str(mp), "--phase", "post-restore"])
        out, _ = capsys.readouterr()
        assert rc == 1, f"board-behind post-restore must FAIL (exit 1), got rc={rc}\n{out}"
        assert "FAIL: 1" in out
        assert "STALE-OK: 0" in out

    # -- DATA-LOSS direction: pre-import must FAIL (blocks apply) -------------
    def test_board_data_loss_pre_import_is_fail(self, tmp_path, capsys):
        """Destination board has items the manifest does NOT capture (cur_ids - cap_ids).
        An overwrite-import would DELETE these items.  Must FAIL with 'DATA-LOSS:' prefix
        message in pre-import phase — this is the real blocking signal."""
        disk_items = ["XFIN-0001", "XFIN-0002", "XFIN-0003", "XFIN-0004", "XFIN-0005"]
        cap_items = ["XFIN-0001", "XFIN-0002", "XFIN-0003"]
        mp = _make_board_manifest(tmp_path, disk_items, cap_items, "board_dataloss_pre.json")
        rc = verifier_main(["--manifest", str(mp), "--phase", "pre-import"])
        out, _ = capsys.readouterr()
        assert rc == 1, f"DATA-LOSS pre-import must FAIL (exit 1), got rc={rc}\n{out}"
        assert "FAIL: 1" in out
        assert "DATA-LOSS:" in out, "Failure message must start with 'DATA-LOSS:' prefix"

    # -- DATA-LOSS direction: post-restore must also FAIL ---------------------
    def test_board_data_loss_post_restore_is_fail(self, tmp_path, capsys):
        """DATA-LOSS blocks in post-restore phase too — the missing items are a real defect."""
        disk_items = ["XFIN-0001", "XFIN-0002", "XFIN-0003", "XFIN-0004", "XFIN-0005"]
        cap_items = ["XFIN-0001", "XFIN-0002", "XFIN-0003"]
        mp = _make_board_manifest(tmp_path, disk_items, cap_items, "board_dataloss_post.json")
        rc = verifier_main(["--manifest", str(mp), "--phase", "post-restore"])
        out, _ = capsys.readouterr()
        assert rc == 1, f"DATA-LOSS post-restore must FAIL (exit 1), got rc={rc}\n{out}"
        assert "FAIL: 1" in out
        assert "DATA-LOSS:" in out

    # -- both behind AND ahead: DATA-LOSS wins over STALE-OK ------------------
    def test_board_both_behind_and_ahead_data_loss_wins(self, tmp_path, capsys):
        """Destination board has BOTH: items the manifest does not list (ahead, DATA-LOSS)
        AND is missing items the manifest captured (behind, STALE-OK candidate).
        DATA-LOSS must take priority — result is FAIL, not STALE-OK."""
        disk_items = ["XFIN-0001", "XFIN-0002", "XFIN-0003", "XFIN-9999"]  # 9999 is extra
        cap_items = [f"XFIN-{i:04d}" for i in range(1, 6)]  # missing 0004, 0005 on disk
        mp = _make_board_manifest(tmp_path, disk_items, cap_items, "board_mixed.json")
        for phase in ("pre-import", "post-restore"):
            rc = verifier_main(["--manifest", str(mp), "--phase", phase])
            out, _ = capsys.readouterr()
            assert rc == 1, (
                f"Mixed behind+ahead ({phase}): DATA-LOSS must win → FAIL (exit 1), "
                f"got rc={rc}\n{out}"
            )
            assert "DATA-LOSS:" in out, f"Expected DATA-LOSS: prefix ({phase})\n{out}"
            assert "STALE-OK: 0" in out, (
                f"STALE-OK must be 0 when DATA-LOSS is present ({phase})\n{out}"
            )

    # -- board exactly matches: PASS in both phases ---------------------------
    def test_board_exact_match_passes_both_phases(self, tmp_path, capsys):
        """Board on disk matches captured probe exactly: PASS + exit 0 in both phases."""
        items = ["XFIN-0001", "XFIN-0002", "XFIN-0003"]
        mp = _make_board_manifest(tmp_path, items, items, "board_exact.json")
        for phase in ("pre-import", "post-restore"):
            rc = verifier_main(["--manifest", str(mp), "--phase", phase])
            out, _ = capsys.readouterr()
            assert rc == 0, f"Exact board match must PASS in {phase}, got rc={rc}\n{out}"
            assert "FAIL: 0" in out
            assert "STALE-OK: 0" in out

    # -- XACA-0601: probe must NOT cap item_ids at 200 -----------------------
    def test_probe_item_ids_not_capped_at_200(self, tmp_path, capsys):
        """XACA-0601 regression: _probe_for must return ALL item ids, not [:200].

        Root cause: domain_kanban.py returned {"item_count": len(ids),
        "item_ids": ids[:200]}, so boards with >200 items fed a truncated
        cap_ids set into the verifier.  Any live-board item beyond position 200
        (alphabetically) appeared in cur_ids - cap_ids → DATA-LOSS false-positive
        that blocked every UI import.

        Test plan:
        - Build a board with 210 synthetic XACA-NNNN items (parents) plus 10
          subitems each for items 001-010, pushing late-alphabet subitems
          (XACA-0001-001 … XACA-0010-010) past sorted position 200.
        - Verify _probe_for captures ALL ids (len == item_count).
        - Run the verifier in pre-import phase with the same board as both
          source-probe and live destination → must PASS (no DATA-LOSS FAIL).

        This test FAILS against the old [:200] code and PASSES with the fix.
        """
        import json as _json
        from team_transfer.domain_kanban import _probe_for, _walk_ids

        # Build a board with 210 top-level items + 10 subitems each for
        # items 001-010, giving 310 total IDs.  After sorting alphabetically,
        # the subitem IDs (XACA-0001-001 … XACA-0010-010) sort BEFORE the
        # corresponding parent IDs, so the parents at position 200+ land in
        # cur_ids but NOT in the old [:200] cap_ids → false DATA-LOSS.
        prefix = "XACA-"
        parent_ids = [f"XACA-{i:04d}" for i in range(1, 211)]
        subitem_ids = [
            f"XACA-{i:04d}-{j:03d}"
            for i in range(1, 11)
            for j in range(1, 11)
        ]
        all_ids = sorted(parent_ids + subitem_ids)
        assert len(all_ids) == 310, "Sanity: 210 parents + 100 subitems"

        # Write a board JSON that contains all items (flat list of {id: ...})
        board_path = tmp_path / "board.json"
        board_data = {"items": [{"id": i} for i in all_ids]}
        board_path.write_text(_json.dumps(board_data))

        # --- Part 1: probe completeness ---
        probe = _probe_for(board_path, ticket_prefix=prefix)
        assert probe is not None
        assert probe["item_count"] == 310, (
            f"item_count must reflect ALL 310 ids, got {probe['item_count']}"
        )
        assert len(probe["item_ids"]) == 310, (
            f"item_ids must contain ALL 310 ids (old code capped at 200), "
            f"got {len(probe['item_ids'])}"
        )
        assert sorted(probe["item_ids"]) == all_ids, (
            "probe item_ids must match the full sorted id list"
        )

        # --- Part 2: verifier does NOT false-positive DATA-LOSS ---
        # Build a manifest whose probe contains ALL ids, and whose board file
        # IS the same board (source == destination → identical import).
        from team_transfer.manifest import SCHEMA, FileEntry, new_manifest
        from team_transfer import channels

        m = new_manifest()
        fe = FileEntry(
            path=str(board_path),
            relpath="kanban/board.json",
            sha256=None,
            size=board_path.stat().st_size,
            mtime=board_path.stat().st_mtime,
            cls=SCHEMA,
            channel=channels.EXPORT_KANBAN,
            domain="kanban",
            probe=probe,  # full probe from _probe_for
        )
        m.add_file("kanban", fe)
        m.recompute_channel_stats()
        mp = tmp_path / "manifest.json"
        mp.write_text(m.to_json())

        rc = verifier_main(["--manifest", str(mp), "--phase", "pre-import"])
        out, _ = capsys.readouterr()
        assert rc == 0, (
            f"XACA-0601 regression: board with 310 items must NOT produce DATA-LOSS "
            f"false-positive in pre-import when source==destination. "
            f"rc={rc}\n{out}"
        )
        assert "DATA-LOSS" not in out, (
            f"DATA-LOSS must not appear when source and destination boards are identical.\n{out}"
        )
        assert "FAIL: 0" in out, (
            f"Expected FAIL: 0 for identical source/destination boards.\n{out}"
        )

    # -- server.py STALE-OK regex smoke-test ----------------------------------
    def test_stale_ok_summary_line_matches_server_regex(self, tmp_path, capsys):
        """The '  STALE-OK: N' summary line must match server.py's parsing regex
        r'^\\s*STALE-OK:\\s*(\\d+)$' so verifierSummary.staleOk is populated."""
        import re
        disk_items = ["XFIN-0001"]
        cap_items = ["XFIN-0001", "XFIN-0002", "XFIN-0003"]  # board behind by 2
        mp = _make_board_manifest(tmp_path, disk_items, cap_items, "board_regex_check.json")
        rc = verifier_main(["--manifest", str(mp), "--phase", "pre-import"])
        out, _ = capsys.readouterr()
        assert rc == 0
        server_re = re.compile(r"^\s*STALE-OK:\s*(\d+)$", re.MULTILINE)
        mo = server_re.search(out)
        assert mo is not None, (
            f"Server regex r'^\\s*STALE-OK:\\s*(\\d+)$' did not match verifier output.\n"
            f"Output:\n{out}"
        )
        assert int(mo.group(1)) == 1, f"Expected STALE-OK count=1, got {mo.group(1)}"
