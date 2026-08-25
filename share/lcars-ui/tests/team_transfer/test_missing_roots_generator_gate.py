"""XACA-0954-007: regression coverage for the generator's missing-roots gate.

Pins the exact exit-code / output-section matrix the orchestrator verified by
hand during XACA-0954 (medical-general export + broken-config repro):

  broken config, no waiver           -> exit 1, "MISSING DOMAIN ROOTS" section
  broken config, --allow-untagged    -> exit 1 (untagged waiver does NOT cover
                                         the missing-roots failure class)
  broken config, --allow-missing-roots -> exit 0
  fixed config,  no waiver           -> exit 0, "Zero untagged gaps" line

None of this exercises production code — these tests build a throwaway
synthetic team config via --team-config-dir and drive the real generator CLI
end to end, the same pattern test_migration_verifier.py and
test_synthetic_migration_e2e.py already use.
"""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import pytest


def _lcars_ui_dir() -> Path:
    """Return the lcars-ui/ directory (grandparent of this file's directory)."""
    return Path(__file__).resolve().parents[2]


_TEAM_YAML_TEMPLATE = """\
team: synthgen
home_relative_root: "synthrepo"
product_dir: "synthgen_root"
personas: []
board_filename: "synthgen-board.json"
ticket_prefix: "XSYN-"
claude_project_dir_name: "-synthgen-project"
databases:
defaults:
  rules:
{rules}
  icloud_excluded: []
overrides: []
"""

_GIT_RULES = (
    '    - pattern: "{home}/{root}/*"\n'
    "      channel: git\n"
    '    - pattern: "{home}/{root}/**"\n'
    "      channel: git\n"
)


def _write_synthgen_config(config_dir: Path, *, route_git: bool) -> None:
    """Write a minimal synthgen.yaml.

    route_git=True adds a catch-all git rule so files under the repo root are
    NOT untagged. route_git=False omits all rules so any file placed under the
    repo root is untagged — a controlled way to trigger the untagged-gaps
    failure class independently of the missing-roots failure class.
    """
    rules = _GIT_RULES if route_git else ""
    text = _TEAM_YAML_TEMPLATE.format(rules=rules)
    config_dir.mkdir(parents=True, exist_ok=True)
    (config_dir / "synthgen.yaml").write_text(text, encoding="utf-8")


def _run_generator(home: Path, config_dir: Path, out_path: Path, extra_args: list[str] | None = None) -> tuple[int, str]:
    env = os.environ.copy()
    env["HOME"] = str(home)
    lcars_ui = str(_lcars_ui_dir())
    existing = env.get("PYTHONPATH", "")
    env["PYTHONPATH"] = (lcars_ui + ":" + existing) if existing else lcars_ui
    proc = subprocess.run(
        [
            sys.executable, "-m", "team_transfer.generator",
            "--team", "synthgen",
            "--team-config-dir", str(config_dir),
            "--output", str(out_path),
            *(extra_args or []),
        ],
        env=env, capture_output=True, text=True,
    )
    return proc.returncode, proc.stdout + proc.stderr


def _setup_home(tmp_path: Path, *, route_git: bool, product_dir_exists: bool) -> tuple[Path, Path, Path]:
    """Build a synthetic $HOME with a repo + optional product_dir. Returns (home, config_dir, out_path)."""
    home = tmp_path
    config_dir = home / "team_config"
    _write_synthgen_config(config_dir, route_git=route_git)

    repo = home / "synthrepo"
    repo.mkdir(parents=True)
    (repo / "hello.txt").write_text("hello", encoding="utf-8")

    if product_dir_exists:
        (home / "dev-team" / "synthgen_root").mkdir(parents=True)

    out_path = home / "manifest.json"
    return home, config_dir, out_path


def test_missing_roots_only_suppresses_all_clear_and_exits_1(tmp_path):
    """Broken product_dir, everything else routed -> no untagged gaps, but the
    missing-roots gate must still block: no 'Zero untagged gaps' line, the
    'MISSING DOMAIN ROOTS' section prints, exit code is 1.
    """
    home, config_dir, out_path = _setup_home(tmp_path, route_git=True, product_dir_exists=False)
    rc, output = _run_generator(home, config_dir, out_path)

    assert rc == 1, output
    assert "MISSING DOMAIN ROOTS (1)" in output, output
    assert "config_key=product_dir" in output, output
    assert "Zero untagged gaps" not in output, output
    assert "NOT CLEAR TO EXPORT" in output, output
    # No untagged files were ever created in this scenario -- confirm the
    # untagged-gaps section genuinely did not fire (it's a distinct failure class).
    assert "UNTAGGED GAPS" not in output, output


def test_allow_untagged_does_not_suppress_missing_roots_failure(tmp_path):
    """Highest-value assertion in this file: an operator who waived untagged
    gaps must NOT silently also waive missing roots. Both failure classes are
    present here (no git rule -> hello.txt is untagged; product_dir missing);
    --allow-untagged alone must still leave the process exiting 1.
    """
    home, config_dir, out_path = _setup_home(tmp_path, route_git=False, product_dir_exists=False)
    rc, output = _run_generator(home, config_dir, out_path, extra_args=["--allow-untagged"])

    assert rc == 1, output
    assert "MISSING DOMAIN ROOTS (1)" in output, output
    assert "UNTAGGED GAPS (1)" in output, output


def test_allow_missing_roots_waives_missing_root_failure(tmp_path):
    """--allow-missing-roots waives ONLY the missing-roots failure class. With
    no untagged files in play, this must bring the exit code down to 0.
    """
    home, config_dir, out_path = _setup_home(tmp_path, route_git=True, product_dir_exists=False)
    rc, output = _run_generator(home, config_dir, out_path, extra_args=["--allow-missing-roots"])

    assert rc == 0, output
    # Still informational -- the waiver suppresses the exit code, not the report.
    assert "MISSING DOMAIN ROOTS (1)" in output, output


def test_both_failure_classes_present_both_sections_print_and_exit_1(tmp_path):
    home, config_dir, out_path = _setup_home(tmp_path, route_git=False, product_dir_exists=False)
    rc, output = _run_generator(home, config_dir, out_path)

    assert rc == 1, output
    assert "MISSING DOMAIN ROOTS (1)" in output, output
    assert "UNTAGGED GAPS (1)" in output, output


def test_fixed_config_no_waiver_exits_0_with_all_clear(tmp_path):
    """Baseline positive case: product_dir exists, everything routed -> the
    all-clear line prints and exit code is 0. This is the counterpart the
    other cases in this file are contrasted against.
    """
    home, config_dir, out_path = _setup_home(tmp_path, route_git=True, product_dir_exists=True)
    rc, output = _run_generator(home, config_dir, out_path)

    assert rc == 0, output
    assert "Zero untagged gaps" in output, output
    assert "MISSING DOMAIN ROOTS" not in output, output
