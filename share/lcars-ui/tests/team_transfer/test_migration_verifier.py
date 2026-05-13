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
        cls=PRESENT, channel=channels.EXPORT, domain="kanban",
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


def test_generator_self_includes_manifest_in_output(tmp_path):
    """Generator output must contain an entry for the manifest path itself."""
    import json

    lcars_ui = _lcars_ui_dir()
    out_path = tmp_path / "manifest.json"

    env = os.environ.copy()
    pythonpath = str(lcars_ui)
    if env.get("PYTHONPATH"):
        pythonpath = pythonpath + ":" + env["PYTHONPATH"]
    env["PYTHONPATH"] = pythonpath
    proc = subprocess.run(
        [sys.executable, "-m", "team_transfer.generator",
         "--output", str(out_path), "--allow-untagged"],
        env=env, capture_output=True, text=True,
    )
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert out_path.exists()

    with open(out_path) as f:
        m = json.load(f)
    # The manifest must contain a self-entry for its own absolute path.
    all_paths = []
    for dname, dblock in m["domains"].items():
        for fe in dblock["files"]:
            all_paths.append(fe["path"])
    assert str(out_path.resolve()) in all_paths, "manifest must self-reference"

    # The self-entry must be class=present (avoids self-hash paradox).
    self_entries = [
        fe for d in m["domains"].values() for fe in d["files"]
        if fe["path"] == str(out_path.resolve())
    ]
    assert len(self_entries) == 1
    assert self_entries[0]["cls"] == "present"
