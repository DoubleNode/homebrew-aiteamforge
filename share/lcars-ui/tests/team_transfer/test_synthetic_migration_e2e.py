"""Synthetic end-to-end migration integration test.

Exercises the full round-trip: generator -> destructive move -> verifier.
Subitem 001 owns the fixture topology (conftest_synthetic_e2e.py).
Subitem 002 owns the actual round-trip assertions below the STUB marker.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

# Import the fixtures so pytest discovers them.  The conftest_synthetic_e2e
# module is NOT named conftest.py so pytest won't auto-load it — we import
# directly and let the module-level fixtures register via the normal mechanism.
from tests.team_transfer.conftest_synthetic_e2e import (  # noqa: F401 — fixture imports
    synthetic_destination,
    synthetic_repo,
    synthetic_source,
    synthetic_team_config,
)

# ---------------------------------------------------------------------------
# Helpers shared by the round-trip test
# ---------------------------------------------------------------------------

def _lcars_ui_dir() -> Path:
    """Return the lcars-ui/ directory (grandparent of this file's directory)."""
    return Path(__file__).resolve().parents[2]


def _make_env_with_home(home: Path) -> dict:
    """Build a subprocess env dict with HOME overridden to *home*.

    The generator calls Path.home() internally, which reads $HOME on macOS/Linux.
    Overriding $HOME is the cleanest way to point the generator at a synthetic
    source tree without monkeypatching the stdlib.
    """
    env = os.environ.copy()
    env["HOME"] = str(home)
    lcars_ui = str(_lcars_ui_dir())
    existing = env.get("PYTHONPATH", "")
    env["PYTHONPATH"] = (lcars_ui + ":" + existing) if existing else lcars_ui
    return env


def _write_synthetic_team_yaml(config_dir: Path, team_config: dict) -> None:
    """Write a minimal finance.yaml to *config_dir* that mirrors *team_config*.

    We write a custom yaml rather than using the packaged finance.yaml because
    the packaged file hardcodes claude_project_dir_name for the real developer
    machine user — the synthetic fixture uses a different project dir name.
    """
    cfg = team_config
    lines = [
        f'team: {cfg["team"]}',
        f'home_relative_root: "{cfg["home_relative_root"]}"',
        f'board_filename: "{cfg["board_filename"]}"',
        f'ticket_prefix: "{cfg["ticket_prefix"]}"',
        f'claude_project_dir_name: "{cfg["claude_project_dir_name"]}"',
        "databases:",
    ]
    for db in cfg.get("databases", []):
        lines.append(f'  - path: "{db["path"]}"')
        lines.append(f'    cls: {db["cls"]}')
    lines.append("defaults:")
    lines.append("  rules:")
    for rule in cfg.get("defaults", {}).get("rules", []):
        lines.append(f'    - pattern: "{rule["pattern"]}"')
        lines.append(f'      channel: {rule["channel"]}')
    lines.append("  icloud_excluded: []")
    lines.append("overrides: []")
    config_dir.mkdir(parents=True, exist_ok=True)
    (config_dir / "finance.yaml").write_text("\n".join(lines) + "\n", encoding="utf-8")


def _run_generator(src_home: Path, manifest_path: Path, config_dir: Path) -> tuple[int, str]:
    """Invoke the generator CLI via subprocess with HOME=src_home.

    Why subprocess and not in-process call to generator.main()?  The generator
    calls Path.home() at import-evaluation time via new_manifest(), and several
    domain modules also call Path.home() in their local scope.  Monkeypatching
    Path.home() mid-test is fragile against parallel test runs and threading.
    A subprocess with $HOME overridden is the robust, isolated alternative.
    """
    env = _make_env_with_home(src_home)
    proc = subprocess.run(
        [
            sys.executable, "-m", "team_transfer.generator",
            "--team", "finance",
            "--team-config-dir", str(config_dir),
            "--output", str(manifest_path),
            "--allow-untagged",
        ],
        env=env,
        capture_output=True,
        text=True,
    )
    return proc.returncode, proc.stdout + proc.stderr


def _destructive_move(src_home: Path, dst_home: Path) -> None:
    """Copy every child of src_home into dst_home, then remove the source.

    Why in-process shutil instead of a toolkit helper or subprocess?
    The toolkit has no move/apply function — the real transfer is operator-driven
    (scp, rsync). We simulate the same outcome (files present at destination,
    absent at source) using shutil.copytree per top-level entry + shutil.rmtree
    to clean up, which is race-free and does not depend on any external binary.
    """
    for child in src_home.iterdir():
        dst_child = dst_home / child.name
        if child.is_dir():
            shutil.copytree(str(child), str(dst_child), dirs_exist_ok=True)
        else:
            shutil.copy2(str(child), str(dst_child))
    # Destructive: remove source contents, leaving the directory itself
    # (the generator wrote the manifest there; we already captured it above).
    for child in list(src_home.iterdir()):
        if child.is_dir():
            shutil.rmtree(str(child))
        else:
            child.unlink()


def _assert_channels_in_output(output: str, channel_names: list[str]) -> None:
    for ch in channel_names:
        assert ch in output, (
            f"Expected channel {ch!r} to appear in verifier output.\n"
            f"Output:\n{output}"
        )


# ---------------------------------------------------------------------------
# Sanity: fixture topology exists and has the expected directories
# (subitem 001 gate — proves fixtures load and resolve without errors)
# ---------------------------------------------------------------------------

def test_synthetic_source_topology_exists(synthetic_source):
    """All channel-representative directories exist in the synthetic source tree."""
    src = synthetic_source

    # git channel
    assert (src / "finance" / "personal" / "src" / "main.py").exists()
    assert (src / "finance" / "personal" / "src" / "utils.py").exists()

    # export_kanban channel
    assert (src / "finance" / "personal" / "kanban").is_dir()
    assert (src / "finance" / "personal" / "kanban" / "finance-personal-board.json").exists()

    # export_database channel
    assert (src / "finance" / "personal" / "data" / "finance.db").exists()

    # secrets_export channel
    assert (src / "finance" / "personal" / ".env").exists()
    assert (src / "finance" / "personal" / "secrets" / "test-secrets.txt").exists()

    # icloud_excluded channel
    assert (src / "finance" / "personal" / "docs" / "statements" / "2026-01.pdf").exists()

    # aiteamforge_product channel
    assert (src / "dev-team" / "finance" / "personas" / "agents" / "quark.md").exists()
    assert (src / "dev-team" / "finance" / "scripts" / "setup.sh").exists()

    # user_state channel — claude memory
    project_dir = src / ".claude" / "projects" / "-Users-synth-finance-personal"
    assert (project_dir / "memory" / "MEMORY.md").exists()
    assert (project_dir / "session.jsonl").exists()

    # user_state channel — knowledge agents
    assert (src / "knowledge" / "agents" / "quark" / "INDEX.md").exists()
    assert (src / "knowledge" / "agents" / "nog" / "lessons.md").is_file() is False  # not created yet
    # nog/INDEX.md is what _make_knowledge_tree creates
    assert (src / "knowledge" / "agents" / "nog" / "INDEX.md").exists()


def test_synthetic_destination_is_empty(synthetic_destination):
    """Destination root exists and starts empty."""
    dst = synthetic_destination
    assert dst.is_dir()
    contents = list(dst.iterdir())
    assert contents == [], f"destination should start empty; found: {contents}"


def test_synthetic_team_config_has_required_keys(synthetic_team_config):
    """Team config dict contains the keys that domain modules and generator depend on."""
    cfg = synthetic_team_config
    for key in ("team", "home_relative_root", "board_filename",
                "ticket_prefix", "claude_project_dir_name", "personas", "databases"):
        assert key in cfg, f"synthetic_team_config is missing key: {key!r}"


def test_synthetic_repo_is_git_repo(synthetic_source, synthetic_repo):
    """synthetic_repo fixture creates a valid git repo that git ls-files can query."""
    result = subprocess.run(
        ["git", "-C", str(synthetic_repo), "ls-files"],
        capture_output=True, text=True,
    )
    # rc == 0 and at least some output (or empty — either is fine; just must not error)
    assert result.returncode == 0, (
        f"git ls-files failed in synthetic_repo: {result.stderr}"
    )


# ---------------------------------------------------------------------------
# Golden-path round-trip — subitem 002
# ---------------------------------------------------------------------------

def test_synthetic_e2e_golden_round_trip(
    synthetic_source,
    synthetic_destination,
    synthetic_team_config,
    synthetic_repo,
    tmp_path,
    capsys,
):
    """Full synthetic migration end-to-end: generator -> destructive move -> verifier.

    Golden path only — no fault injection (subitem 003 owns that).
    """
    src_home = synthetic_source
    dst_home = synthetic_destination

    # synthetic_repo must be created BEFORE the generator runs so that git ls-files
    # returns the tracked src/ files rather than falling back to the directory walker.
    # The synthetic_repo fixture is declared above and runs via its fixture dependency
    # on synthetic_source; we reference it here to ensure pytest orders correctly.
    _ = synthetic_repo

    # --- Step 1: write a synthetic team config yaml pointing at the correct
    # claude_project_dir_name for the synthetic source tree. ---
    config_dir = tmp_path / "team_config"
    _write_synthetic_team_yaml(config_dir, synthetic_team_config)

    manifest_path = tmp_path / "manifest.json"

    # --- Step 2: run the generator against the synthetic source. ---
    rc, gen_output = _run_generator(src_home, manifest_path, config_dir)
    assert rc == 0, (
        f"Generator exited {rc}.\nOutput:\n{gen_output}"
    )
    assert manifest_path.exists(), "Generator must write the manifest file."

    # --- Step 3: load the manifest and verify it covers all expected channels. ---
    manifest_text = manifest_path.read_text(encoding="utf-8")
    manifest_data = json.loads(manifest_text)

    all_entry_paths = [
        fe["path"]
        for d in manifest_data["domains"].values()
        for fe in d["files"]
    ]
    assert all_entry_paths, "Manifest must have at least one entry."

    channel_counts = _count_channels_in_manifest(manifest_data)
    _assert_all_non_icloud_channels_present(channel_counts, gen_output)

    # icloud_excluded entries must appear in the manifest so the verifier can skip them.
    assert channel_counts.get("icloud_excluded", 0) > 0, (
        "Manifest must include at least one icloud_excluded entry "
        f"(so the verifier skip counter is non-zero).\nGenerator output:\n{gen_output}"
    )

    # Board JSON must have a SCHEMA-class entry with item_ids probe.
    _assert_board_schema_probe(manifest_data, synthetic_team_config)

    # --- Step 4: destructive move — copy src_home -> dst_home, then delete src_home contents. ---
    _destructive_move(src_home, dst_home)

    # Verify the move was destructive: src_home should be empty.
    src_remaining = list(src_home.iterdir())
    assert src_remaining == [], (
        f"Source must be empty after destructive move; found: {src_remaining}"
    )

    # Spot-check that destination received expected files.
    assert (dst_home / "finance" / "personal" / "src" / "main.py").exists(), \
        "git channel file must be present at destination after move."
    assert (dst_home / "finance" / "personal" / "data" / "finance.db").exists(), \
        "export_database file must be present at destination after move."
    assert (dst_home / "dev-team" / "finance" / "personas" / "agents" / "quark.md").exists(), \
        "aiteamforge_product file must be present at destination after move."

    # --- Step 5: run the verifier in-process with --path-map src_home=dst_home. ---
    # We call verifier_main() directly (matching TestPathMap style) with --path-map
    # to translate all manifest paths from src_home to dst_home without needing to
    # monkeypatch Path.home() or spawn a second subprocess.
    from team_transfer.verifier import main as verifier_main

    verifier_argv = [
        "--manifest", str(manifest_path),
        "--path-map", f"{src_home}={dst_home}",
    ]
    rc_v = verifier_main(verifier_argv)
    verifier_output, _ = capsys.readouterr()

    assert rc_v == 0, (
        f"Verifier must exit 0 on golden path (FAIL: 0). Got rc={rc_v}.\n"
        f"Verifier output:\n{verifier_output}"
    )
    assert "FAIL: 0" in verifier_output, (
        f"Expected 'FAIL: 0' in verifier output.\n{verifier_output}"
    )

    # --- Step 6: assert per-channel report covers every expected channel. ---
    assert "PER-CHANNEL" in verifier_output, "Verifier must emit a per-channel section."
    _assert_channels_in_output(verifier_output, [
        "git",
        "export_kanban",
        "export_database",
        "secrets_export",
        "aiteamforge_product",
        "user_state",
        "icloud_excluded",
    ])

    # --- Step 7: icloud_excluded entries must be skipped (not failed). ---
    # The verifier output line for icloud_excluded must show skipped > 0.
    assert "skipped:   1" in verifier_output or _icloud_skip_count(verifier_output) >= 1, (
        f"icloud_excluded entries must be skipped (not failed).\n{verifier_output}"
    )

    # --- Step 8: no WARN lines about missing sha256 for EXACT entries. ---
    # On the golden path, every EXACT entry must have a sha256 in the manifest.
    # A WARN line here would indicate a generator bug, not a destination issue.
    assert "WARN: 0" in verifier_output, (
        f"Expected zero warnings on golden path.\n{verifier_output}"
    )


# ---------------------------------------------------------------------------
# Sub-assertion helpers (factored out to keep the main test body under 80 lines)
# ---------------------------------------------------------------------------

def _count_channels_in_manifest(manifest_data: dict) -> dict[str, int]:
    """Return a dict mapping channel name -> entry count from raw manifest JSON."""
    counts: dict[str, int] = {}
    for dblock in manifest_data["domains"].values():
        for fe in dblock["files"]:
            ch = fe.get("channel", "")
            counts[ch] = counts.get(ch, 0) + 1
    return counts


def _assert_all_non_icloud_channels_present(
    channel_counts: dict[str, int], gen_output: str
) -> None:
    """Every non-icloud channel must have at least one entry in the manifest."""
    required = [
        "git",
        "export_kanban",
        "export_database",
        "secrets_export",
        "aiteamforge_product",
        "user_state",
    ]
    for ch in required:
        assert channel_counts.get(ch, 0) > 0, (
            f"Channel {ch!r} has 0 entries in the manifest. "
            f"All channel counts: {channel_counts}.\n"
            f"Generator output:\n{gen_output}"
        )


def _assert_board_schema_probe(manifest_data: dict, team_config: dict) -> None:
    """The kanban board JSON entry must have cls=schema and an item_ids probe."""
    board_filename = team_config["board_filename"]
    ticket_prefix = team_config["ticket_prefix"]
    board_entries = [
        fe
        for dblock in manifest_data["domains"].values()
        for fe in dblock["files"]
        if fe["path"].endswith(board_filename)
    ]
    assert board_entries, f"No manifest entry found for board file {board_filename!r}."
    board_fe = board_entries[0]
    assert board_fe["cls"] == "schema", (
        f"Board JSON entry must have cls=schema; got {board_fe['cls']!r}."
    )
    probe = board_fe.get("probe") or {}
    assert "item_ids" in probe, (
        f"Board entry probe must contain 'item_ids'; got probe={probe!r}."
    )
    # Both synthetic items must be captured in the probe.
    expected_ids = {f"{ticket_prefix}0001", f"{ticket_prefix}0002"}
    captured_ids = set(probe["item_ids"])
    assert expected_ids <= captured_ids, (
        f"Board probe missing item IDs. Expected {expected_ids}, probe has {captured_ids}."
    )


def _icloud_skip_count(verifier_output: str) -> int:
    """Parse the icloud_excluded line from verifier output and return the skip count."""
    for line in verifier_output.splitlines():
        if "icloud_excluded" in line and "skipped:" in line:
            # Line format: "  v icloud_excluded      PASS:    0  WARN:   0  FAIL:   0  skipped:   1"
            parts = line.split("skipped:")
            if len(parts) == 2:
                try:
                    return int(parts[1].strip())
                except ValueError:
                    pass
    return 0


# ---------------------------------------------------------------------------
# Fault-injection helper — runs the golden flow up to (and including) the
# destructive move and returns (src_home, dst_home, manifest_path, verifier_argv).
#
# Each fault test calls this, injects its fault at dst_home, then runs the
# verifier and asserts it FAILed with the expected signal.
# ---------------------------------------------------------------------------

def _golden_flow_up_to_move(
    synthetic_source: "Path",
    synthetic_destination: "Path",
    synthetic_team_config: dict,
    synthetic_repo,           # noqa: ANN001 — fixture reference; forces ordering
    tmp_path: "Path",
) -> tuple["Path", "Path", "Path", list[str]]:
    """Run generator + destructive move; return (src_home, dst_home, manifest_path, base_argv).

    The returned *base_argv* already includes --manifest and --path-map so callers
    can call verifier_main(base_argv) without further modification.  Tests that
    want to omit --path-map (fault class 7) should build their own argv.
    """
    _ = synthetic_repo  # ensures synthetic_repo fixture runs first (git init)

    config_dir = tmp_path / "team_config"
    _write_synthetic_team_yaml(config_dir, synthetic_team_config)
    manifest_path = tmp_path / "manifest.json"

    rc, gen_output = _run_generator(synthetic_source, manifest_path, config_dir)
    assert rc == 0, f"Generator failed (fault test setup).\nOutput:\n{gen_output}"
    assert manifest_path.exists()

    _destructive_move(synthetic_source, synthetic_destination)

    base_argv = [
        "--manifest", str(manifest_path),
        "--path-map", f"{synthetic_source}={synthetic_destination}",
    ]
    return synthetic_source, synthetic_destination, manifest_path, base_argv


# ---------------------------------------------------------------------------
# Fault class 1a — missing EXACT-class file (git channel)
# ---------------------------------------------------------------------------

def test_synthetic_e2e_fault_missing_exact_file(
    synthetic_source,
    synthetic_destination,
    synthetic_team_config,
    synthetic_repo,
    tmp_path,
    capsys,
):
    """Verifier must FAIL when an EXACT-class git file is absent at destination."""
    src, dst, manifest_path, argv = _golden_flow_up_to_move(
        synthetic_source, synthetic_destination, synthetic_team_config,
        synthetic_repo, tmp_path,
    )

    # Inject fault: remove a tracked source file from the destination.
    missing = dst / "finance" / "personal" / "src" / "main.py"
    assert missing.exists(), "test setup: git file must exist after move"
    missing.unlink()

    from team_transfer.verifier import main as verifier_main
    rc = verifier_main(argv)
    out, _ = capsys.readouterr()

    assert rc != 0, f"Expected FAIL when EXACT git file missing; got rc={rc}.\n{out}"
    assert "FAIL" in out
    assert "missing" in out.lower() or "main.py" in out, (
        f"Expected 'missing' signal or filename in output; got:\n{out}"
    )


# ---------------------------------------------------------------------------
# Fault class 1b — missing SCHEMA-class file (board JSON)
# ---------------------------------------------------------------------------

def test_synthetic_e2e_fault_missing_schema_board_file(
    synthetic_source,
    synthetic_destination,
    synthetic_team_config,
    synthetic_repo,
    tmp_path,
    capsys,
):
    """Verifier must FAIL when the kanban board JSON is absent at destination."""
    src, dst, manifest_path, argv = _golden_flow_up_to_move(
        synthetic_source, synthetic_destination, synthetic_team_config,
        synthetic_repo, tmp_path,
    )

    board_filename = synthetic_team_config["board_filename"]
    missing = dst / "finance" / "personal" / "kanban" / board_filename
    assert missing.exists(), "test setup: board JSON must exist after move"
    missing.unlink()

    from team_transfer.verifier import main as verifier_main
    rc = verifier_main(argv)
    out, _ = capsys.readouterr()

    assert rc != 0, f"Expected FAIL when board JSON missing; got rc={rc}.\n{out}"
    assert "FAIL" in out
    # The verifier should emit either 'missing' text or reference the channel/file.
    assert "missing" in out.lower() or board_filename in out or "export_kanban" in out, (
        f"Expected 'missing' signal or board channel reference; got:\n{out}"
    )


# ---------------------------------------------------------------------------
# Fault class 2 — SHA mismatch (corrupted EXACT-class content)
# ---------------------------------------------------------------------------

def test_synthetic_e2e_fault_sha_mismatch(
    synthetic_source,
    synthetic_destination,
    synthetic_team_config,
    synthetic_repo,
    tmp_path,
    capsys,
):
    """Verifier must FAIL when an EXACT-class file is corrupted at destination."""
    src, dst, manifest_path, argv = _golden_flow_up_to_move(
        synthetic_source, synthetic_destination, synthetic_team_config,
        synthetic_repo, tmp_path,
    )

    corrupted = dst / "finance" / "personal" / "src" / "utils.py"
    assert corrupted.exists(), "test setup: utils.py must exist after move"
    # Append a byte to change the SHA without removing the file.
    with open(str(corrupted), "ab") as fh:
        fh.write(b"\x00")

    from team_transfer.verifier import main as verifier_main
    rc = verifier_main(argv)
    out, _ = capsys.readouterr()

    assert rc != 0, f"Expected FAIL on SHA mismatch; got rc={rc}.\n{out}"
    assert "sha256 mismatch" in out.lower() or "mismatch" in out.lower(), (
        f"Expected 'sha256 mismatch' in output; got:\n{out}"
    )


# ---------------------------------------------------------------------------
# Fault class 3 — layout drift (file moved to uncovered sibling path)
# ---------------------------------------------------------------------------

def test_synthetic_e2e_fault_layout_drift(
    synthetic_source,
    synthetic_destination,
    synthetic_team_config,
    synthetic_repo,
    tmp_path,
    capsys,
):
    """Verifier must FAIL when an EXACT file is at a path not covered by --path-map.

    Layout drift = file renamed/relocated at destination; the manifest still records
    the source path, and the --path-map rewrites to the ORIGINAL location.  If the
    file was moved to a sibling path, the translated path doesn't exist → FAIL.
    """
    src, dst, manifest_path, argv = _golden_flow_up_to_move(
        synthetic_source, synthetic_destination, synthetic_team_config,
        synthetic_repo, tmp_path,
    )

    # Move main.py to main_old.py — now it's at a path the verifier won't check.
    original = dst / "finance" / "personal" / "src" / "main.py"
    drifted = dst / "finance" / "personal" / "src" / "main_old.py"
    assert original.exists(), "test setup: main.py must exist"
    original.rename(drifted)

    from team_transfer.verifier import main as verifier_main
    rc = verifier_main(argv)
    out, _ = capsys.readouterr()

    assert rc != 0, f"Expected FAIL on layout drift; got rc={rc}.\n{out}"
    assert "FAIL" in out
    # The verifier checks the original translated path — it should report it missing.
    assert "missing" in out.lower() or "main.py" in out, (
        f"Expected 'missing' signal for drifted path; got:\n{out}"
    )


# ---------------------------------------------------------------------------
# Fault class 4 — schema-class probe drift (item removed from board JSON)
# ---------------------------------------------------------------------------

def test_synthetic_e2e_fault_schema_probe_drift(
    synthetic_source,
    synthetic_destination,
    synthetic_team_config,
    synthetic_repo,
    tmp_path,
    capsys,
):
    """Verifier must FAIL when an item is removed from the destination board JSON.

    The manifest captures item_ids at generation time.  Removing an item from the
    destination board causes the probe comparison to find missing IDs → FAIL.
    This exercises the _verify_board_schema path in verifier.py.
    """
    src, dst, manifest_path, argv = _golden_flow_up_to_move(
        synthetic_source, synthetic_destination, synthetic_team_config,
        synthetic_repo, tmp_path,
    )

    board_filename = synthetic_team_config["board_filename"]
    board_path = dst / "finance" / "personal" / "kanban" / board_filename
    assert board_path.exists(), "test setup: board JSON must exist after move"

    board_data = json.loads(board_path.read_text(encoding="utf-8"))
    # Remove the first item so the destination board has one fewer ID than the manifest probe.
    assert board_data["items"], "test setup: board must have items"
    board_data["items"] = board_data["items"][1:]
    board_path.write_text(json.dumps(board_data, indent=2), encoding="utf-8")

    from team_transfer.verifier import main as verifier_main
    rc = verifier_main(argv)
    out, _ = capsys.readouterr()

    assert rc != 0, f"Expected FAIL on schema probe drift; got rc={rc}.\n{out}"
    assert "FAIL" in out
    assert "missing" in out.lower() or "board" in out.lower() or "XFIN-" in out, (
        f"Expected missing-item signal or ticket prefix in output; got:\n{out}"
    )


# ---------------------------------------------------------------------------
# Fault class 5 — database probe drift (schema_version row modified)
# ---------------------------------------------------------------------------

def test_synthetic_e2e_fault_database_probe_drift(
    synthetic_source,
    synthetic_destination,
    synthetic_team_config,
    synthetic_repo,
    tmp_path,
    capsys,
):
    """Verifier must FAIL when the destination DB has a different structural probe than the manifest.

    The synthetic DB has a schema_info table with a row.  Dropping that table at
    the destination changes the tables list captured in the probe → FAIL.
    (probe_db queries SELECT version FROM schema_version, which will be None for our
    schema_info-based DB; the observable drift is the table list itself.)
    """
    import sqlite3

    src, dst, manifest_path, argv = _golden_flow_up_to_move(
        synthetic_source, synthetic_destination, synthetic_team_config,
        synthetic_repo, tmp_path,
    )

    db_path = dst / "finance" / "personal" / "data" / "finance.db"
    assert db_path.exists(), "test setup: finance.db must exist after move"

    # Drop the schema_info table so the destination DB differs from what the
    # manifest captured (table list no longer matches → compare_probes fails).
    conn = sqlite3.connect(str(db_path))
    conn.execute("DROP TABLE IF EXISTS schema_info")
    conn.commit()
    conn.close()

    from team_transfer.verifier import main as verifier_main
    rc = verifier_main(argv)
    out, _ = capsys.readouterr()

    assert rc != 0, f"Expected FAIL on DB probe drift; got rc={rc}.\n{out}"
    assert "FAIL" in out
    # compare_probes emits "Tables missing on destination" when tables list diverges.
    assert (
        "missing" in out.lower()
        or "table" in out.lower()
        or "export_database" in out
        or "schema" in out.lower()
    ), (
        f"Expected DB-probe failure signal in output; got:\n{out}"
    )


# ---------------------------------------------------------------------------
# Fault class 6 — secrets channel partial move (one secret file missing)
# ---------------------------------------------------------------------------

def test_synthetic_e2e_fault_secrets_partial_move(
    synthetic_source,
    synthetic_destination,
    synthetic_team_config,
    synthetic_repo,
    tmp_path,
    capsys,
):
    """Verifier must FAIL when a secrets_export file is absent at destination.

    Deleting .env at the destination simulates a partial secrets transfer.
    secrets_export files are PRESENT-class — the verifier confirms existence, not SHA.
    A missing file must still produce FAIL.
    """
    src, dst, manifest_path, argv = _golden_flow_up_to_move(
        synthetic_source, synthetic_destination, synthetic_team_config,
        synthetic_repo, tmp_path,
    )

    env_file = dst / "finance" / "personal" / ".env"
    assert env_file.exists(), "test setup: .env must exist after move"
    env_file.unlink()

    from team_transfer.verifier import main as verifier_main
    rc = verifier_main(argv)
    out, _ = capsys.readouterr()

    assert rc != 0, f"Expected FAIL on partial secrets move; got rc={rc}.\n{out}"
    assert "FAIL" in out
    assert "missing" in out.lower() or "secrets_export" in out or ".env" in out, (
        f"Expected 'missing' or secrets_export signal; got:\n{out}"
    )


# ---------------------------------------------------------------------------
# Fault class 7 — path-map omitted after destructive move (operator footgun)
#
# After a destructive move, all manifest paths still record the src_home prefix.
# The verifier must FAIL because src_home no longer exists and paths don't resolve.
# This is the XACA-0489 explicit handling for the "operator forgot --path-map" case.
# ---------------------------------------------------------------------------

def test_synthetic_e2e_fault_missing_path_map(
    synthetic_source,
    synthetic_destination,
    synthetic_team_config,
    synthetic_repo,
    tmp_path,
    capsys,
):
    """Verifier must FAIL when --path-map is omitted after a destructive move.

    The manifest records src_home paths.  The verifier's home-prefix rewrite only
    fires when src_home != dst_home on the SAME machine (same $HOME).  When running
    in-process in tests, both src_home and the real HOME differ, so neither the
    home-prefix rewrite nor a path-map applies — all entries come up missing → FAIL.
    """
    # Note: we do NOT pass --path-map in argv here.  This is the operator-footgun test.
    _ = synthetic_repo

    config_dir = tmp_path / "team_config"
    _write_synthetic_team_yaml(config_dir, synthetic_team_config)
    manifest_path = tmp_path / "manifest.json"

    rc_gen, gen_output = _run_generator(synthetic_source, manifest_path, config_dir)
    assert rc_gen == 0, f"Generator failed.\nOutput:\n{gen_output}"

    _destructive_move(synthetic_source, synthetic_destination)

    from team_transfer.verifier import main as verifier_main
    # Deliberately omit --path-map so the verifier checks paths at src_home,
    # which is now empty (destructive move removed everything there).
    rc = verifier_main(["--manifest", str(manifest_path)])
    out, _ = capsys.readouterr()

    assert rc != 0, (
        f"Expected FAIL when --path-map omitted after destructive move; got rc={rc}.\n{out}"
    )
    assert "FAIL" in out
    # At least one entry must report missing — the src_home tree is empty.
    fail_count = _parse_fail_count(out)
    assert fail_count > 0, (
        f"Expected >0 FAIL entries in summary; got fail_count={fail_count}.\n{out}"
    )


# ---------------------------------------------------------------------------
# Fault class 8 — session transcript removed (XACA-0583: EXPECTED-MISSING)
# ---------------------------------------------------------------------------

def test_synthetic_e2e_session_log_removed_is_expected_missing(
    synthetic_source,
    synthetic_destination,
    synthetic_team_config,
    synthetic_repo,
    tmp_path,
    capsys,
):
    """XACA-0583: a removed Claude session transcript (.claude/projects/*.jsonl) is
    machine-local / ephemeral — it must report EXPECTED-MISSING, NOT FAIL, in any phase.

    This was previously asserted as a FAIL (the only non-skipped PRESENT-class file the
    fixture offered). XACA-0583 reclassifies session transcripts: they cannot round-trip
    cross-machine, so FAILing on their absence is a false negative — the same class of
    false negative the XACA-0581 skip-channels eliminated. The 'missing PRESENT-class
    carried file = FAIL' contract is preserved at the unit level
    (test_present_class_non_ephemeral_absent_is_fail in test_migration_verifier.py).
    """
    src, dst, manifest_path, argv = _golden_flow_up_to_move(
        synthetic_source, synthetic_destination, synthetic_team_config,
        synthetic_repo, tmp_path,
    )

    session_log = dst / ".claude" / "projects" / "-Users-synth-finance-personal" / "session.jsonl"
    assert session_log.exists(), "test setup: session.jsonl must exist after move"
    session_log.unlink()

    from team_transfer.verifier import main as verifier_main
    rc = verifier_main(argv)
    out, _ = capsys.readouterr()

    assert rc == 0, f"Ephemeral session log absence must NOT FAIL (XACA-0583); got rc={rc}.\n{out}"
    assert "EXPECTED-MISSING: 1" in out, f"Expected the session log to be EXPECTED-MISSING; got:\n{out}"
    assert _parse_fail_count(out) == 0, f"Expected 0 FAILs; got:\n{out}"


# ---------------------------------------------------------------------------
# Summary helper
# ---------------------------------------------------------------------------

def _parse_fail_count(verifier_output: str) -> int:
    """Extract the FAIL count from the SUMMARY block of verifier output."""
    for line in verifier_output.splitlines():
        stripped = line.strip()
        if stripped.startswith("FAIL:"):
            try:
                return int(stripped.split(":", 1)[1].strip())
            except (ValueError, IndexError):
                pass
    return -1  # sentinel: summary block not found
