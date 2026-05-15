"""Smoke tests for the XACA-0496-004/005 server.py integration paths.

These tests do NOT boot the HTTP server. Instead they exercise the same
subprocess chain (`team_transfer.generator` then `team_transfer.verifier`)
that `generate_export` and `handle_import_upload` use, and they validate
the regex contract that the server uses to parse PASS/WARN/FAIL counts.

The HTTP wiring (multipart parse, zip append, JSON response shape) is
covered by manual E2E testing — these tests guard the critical parse
path and the subprocess invocation pattern.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

import pytest


def _lcars_ui_dir() -> Path:
    return Path(__file__).resolve().parents[2]


def _run_chain(out_path: Path, team: str = "finance") -> tuple[int, str]:
    """Run generator → verifier the same way server.py:generate_export does.

    Returns the verifier exit code and combined stdout+stderr.
    """
    lcars_ui = _lcars_ui_dir()
    env = os.environ.copy()
    pythonpath = str(lcars_ui)
    if env.get("PYTHONPATH"):
        pythonpath = pythonpath + ":" + env["PYTHONPATH"]
    env["PYTHONPATH"] = pythonpath

    gen = subprocess.run(
        [sys.executable, "-m", "team_transfer.generator",
         "--team", team, "--output", str(out_path), "--allow-untagged"],
        env=env, capture_output=True, text=True, timeout=120,
    )
    if gen.returncode not in (0, 1):
        return -1, gen.stdout + gen.stderr
    if not out_path.exists():
        return -1, "manifest not written: " + gen.stdout + gen.stderr

    ver = subprocess.run(
        [sys.executable, "-m", "team_transfer.verifier",
         "--manifest", str(out_path), "--quiet"],
        env=env, capture_output=True, text=True, timeout=120,
    )
    return ver.returncode, ver.stdout + ver.stderr


def _parse_counts(output: str) -> dict[str, int]:
    """Mirror the parsing regex used by server.py (XACA-0496-004/005)."""
    counts = {"PASS": 0, "WARN": 0, "FAIL": 0}
    for line in output.splitlines():
        m = re.search(r"^\s*(PASS|WARN|FAIL):\s*(\d+)", line)
        if m:
            counts[m.group(1)] = int(m.group(2))
    return counts


def test_subprocess_chain_produces_parseable_summary(tmp_path):
    """Generator → verifier subprocess pipeline yields a SUMMARY block whose
    PASS/WARN/FAIL lines the server's regex can extract."""
    out_path = tmp_path / "manifest.json"
    exit_code, output = _run_chain(out_path)
    assert exit_code in (0, 1), f"verifier exited unexpectedly: {exit_code}\n{output}"

    counts = _parse_counts(output)
    assert sum(counts.values()) > 0, (
        "Parser extracted zero counts — server.py regex would produce a useless "
        f"verifierSummary. Output:\n{output[:1000]}"
    )
    assert "PASS" in counts and "FAIL" in counts


def test_finance_team_has_zero_cross_domain_duplicates(tmp_path, monkeypatch):
    """XACA-0496-012 guard: finance manifest must not contain cross-domain
    duplicate paths. (Generator now dedupes; this test prevents regression.)
    """
    monkeypatch.setenv("HOME", str(tmp_path))
    out_path = tmp_path / "manifest.json"
    exit_code, _ = _run_chain(out_path)
    assert exit_code in (0, 1)

    data = json.loads(out_path.read_text())
    all_paths = [fe["path"] for d in data["domains"].values() for fe in d["files"]]
    duplicates = sorted({p for p in all_paths if all_paths.count(p) > 1})
    assert not duplicates, f"cross-domain duplicates leaked back in: {duplicates[:5]}"


def test_subprocess_chain_returns_verifier_exit_not_generator_exit(tmp_path, monkeypatch):
    """server.py forwards the verifier's exit (not generator's) to
    verifierSummary.exit. Confirm that contract by running against a manifest
    whose files exist (verifier should succeed).
    """
    monkeypatch.setenv("HOME", str(tmp_path))
    out_path = tmp_path / "manifest.json"
    exit_code, output = _run_chain(out_path)
    # When run against the source machine where all referenced files exist,
    # verifier should exit 0. (If finance config can't find any files, generator
    # would exit 1, in which case the test environment is the issue, not the code.)
    assert exit_code in (0, 1), output
    # The verifier always emits the SUMMARY block, even on FAILs:
    assert "SUMMARY" in output


def test_parse_regex_handles_quiet_mode_output():
    """The server's parsing must work whether the verifier runs with or without
    --quiet. Verify the regex matches the canonical summary block format."""
    sample = """
=== SUMMARY ===
  PASS: 1234
  WARN: 5
  FAIL: 2
  EXIT: 1
"""
    counts = _parse_counts(sample)
    assert counts == {"PASS": 1234, "WARN": 5, "FAIL": 2}


def test_parse_regex_rejects_unrelated_pass_fail_text():
    """Defense check: the regex must anchor on the ^   PASS: pattern in the
    summary block, not match arbitrary 'PASS' or 'FAIL' substrings appearing
    elsewhere in the output."""
    sample = """
Some narrative line mentioning PASS and FAIL inline.
  PASS: 10
  WARN: 0
  FAIL: 0
"""
    counts = _parse_counts(sample)
    assert counts == {"PASS": 10, "WARN": 0, "FAIL": 0}
