"""Tests for the pre-export checklist emitter (checklist.py).

Spec oracle: kanban/plans/XACA-0490/CHECKLIST_FORMAT_SPEC.md
Implementation under test: lcars-ui/team_transfer/checklist.py
Caller wiring under test: lcars-ui/team_transfer/generator.py (generator-level tests)

All tests use stdlib + pytest only. No third-party dependencies.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

import pytest

from team_transfer import channels as channels_mod
from team_transfer.checklist import emit_pre_export_checklist
from team_transfer.manifest import EXACT, PRESENT, FileEntry, Manifest, new_manifest

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

HOME = "/Users/testoperator"
SOURCE_USER = "testoperator"
SOURCE_HOST = "test-host.local"
TEAM = "testteam"
ROOT_REL = "testteam/personal"
GENERATED_AT = "2026-05-13T18:42:00+00:00"

# Synthetic absolute root (under HOME)
ROOT = f"{HOME}/{ROOT_REL}"
MANIFEST_PATH = Path(f"{ROOT}/docs/migration/migration-manifest.json")


def _base_manifest() -> Manifest:
    """Return a Manifest with source metadata pre-populated but no files."""
    m = Manifest(
        schema_version=2,
        generated_at=GENERATED_AT,
        source_hostname=SOURCE_HOST,
        source_user=SOURCE_USER,
        home=HOME,
        channels=list(channels_mod.ALL_CHANNELS),
    )
    return m


def _team_config() -> dict:
    return {
        "team": TEAM,
        "home_relative_root": ROOT_REL,
    }


def _make_entry(
    relpath: str,
    channel: str,
    size: int = 100,
    domain: str = "git_repo",
) -> FileEntry:
    return FileEntry(
        path=f"{HOME}/{relpath}",
        relpath=relpath,
        sha256="a" * 64,
        size=size,
        mtime=1234567.0,
        cls=EXACT,
        channel=channel,
        domain=domain,
    )


def _emit_to_tempfile(manifest: Manifest, team_config: dict | None = None) -> str:
    """Emit the checklist to a tempfile and return its contents."""
    if team_config is None:
        team_config = _team_config()
    with tempfile.NamedTemporaryFile(suffix=".md", delete=False, mode="w") as f:
        tmppath = Path(f.name)
    try:
        emit_pre_export_checklist(manifest, team_config, MANIFEST_PATH, tmppath)
        return tmppath.read_text(encoding="utf-8")
    finally:
        tmppath.unlink(missing_ok=True)


# ---------------------------------------------------------------------------
# 1. Happy path
# ---------------------------------------------------------------------------

def test_happy_path_file_is_written():
    """Calling emit_pre_export_checklist creates the output file."""
    m = _build_full_manifest()
    with tempfile.NamedTemporaryFile(suffix=".md", delete=False) as f:
        tmppath = Path(f.name)
    try:
        emit_pre_export_checklist(m, _team_config(), MANIFEST_PATH, tmppath)
        assert tmppath.exists(), "Output file was not created"
        assert tmppath.stat().st_size > 0, "Output file is empty"
    finally:
        tmppath.unlink(missing_ok=True)


def test_happy_path_header_team_name():
    """Header contains the team name in title case."""
    m = _build_full_manifest()
    content = _emit_to_tempfile(m)
    assert f"# Pre-Export Checklist — {TEAM.title()} Team" in content


def test_happy_path_header_generated_at():
    """Header contains the generated_at timestamp from the manifest."""
    m = _build_full_manifest()
    content = _emit_to_tempfile(m)
    assert f"Generated : {GENERATED_AT}" in content


def test_happy_path_header_manifest_path():
    """Header contains the absolute manifest path."""
    m = _build_full_manifest()
    content = _emit_to_tempfile(m)
    assert f"Manifest  : {MANIFEST_PATH}" in content


def test_happy_path_header_source_identity():
    """Header contains source_user@source_hostname."""
    m = _build_full_manifest()
    content = _emit_to_tempfile(m)
    assert f"Source    : {SOURCE_USER}@{SOURCE_HOST}" in content


def test_happy_path_auto_channel_summary_table():
    """Auto-channel summary table lists all four automatic channels."""
    m = _build_full_manifest()
    content = _emit_to_tempfile(m)
    assert "## Automatic Channels (no operator action required)" in content
    assert "| git" in content
    assert "| aiteamforge_product" in content
    assert "| export_kanban" in content
    assert "| icloud_excluded" in content


def test_happy_path_operator_channels_present():
    """Sections for all operator-action channels with files appear in output."""
    m = _build_full_manifest()
    content = _emit_to_tempfile(m)
    assert "## Database Export" in content
    assert "## Secrets Export" in content
    assert "## User State (Memory & Knowledge)" in content


def _build_full_manifest() -> Manifest:
    """Build a manifest with at least one FileEntry in every channel."""
    m = _base_manifest()

    # Auto channels
    m.add_file("git_repo", _make_entry("README.md", channels_mod.GIT, size=1024))
    m.add_file("git_repo", _make_entry("scripts/run.sh", channels_mod.GIT, size=512))
    m.add_file("kanban", _make_entry(f"{ROOT_REL}/kanban/board.json", channels_mod.EXPORT_KANBAN, size=2000, domain="kanban"))
    m.add_file("git_repo", _make_entry(f"{ROOT_REL}/AITeamForge/binary", channels_mod.AITEAMFORGE_PRODUCT, size=5000))
    m.add_file("git_repo", _make_entry(f"{ROOT_REL}/iCloud/photo.jpg", channels_mod.ICLOUD_EXCLUDED, size=0))

    # Operator-action channels
    m.add_file("git_repo", _make_entry(f"{ROOT_REL}/data/finance.db", channels_mod.EXPORT_DATABASE, size=524288))
    m.add_file("git_repo", _make_entry(f"{ROOT_REL}/secrets/test-secrets.txt", channels_mod.SECRETS_EXPORT, size=128))
    m.add_file("claude", _make_entry(
        f".claude/projects/-Users-testoperator-{ROOT_REL.replace('/', '-')}/memory/MEMORY.md",
        channels_mod.USER_STATE, size=8192, domain="claude",
    ))
    m.add_file("knowledge", _make_entry(
        "knowledge/agents/soma/INDEX.md",
        channels_mod.USER_STATE, size=4096, domain="knowledge",
    ))

    m.recompute_channel_stats()
    return m


# ---------------------------------------------------------------------------
# 2. Channel inclusion policy
# ---------------------------------------------------------------------------

def test_user_state_empty_no_section_emitted():
    """When user_state has zero files, no User State section appears."""
    m = _base_manifest()
    # Add only non-user_state files so channel_stats for user_state stays 0
    m.add_file("git_repo", _make_entry(f"{ROOT_REL}/secrets/test-secrets.txt", channels_mod.SECRETS_EXPORT, size=128))
    m.recompute_channel_stats()

    content = _emit_to_tempfile(m)
    assert "## User State (Memory & Knowledge)" not in content


def test_export_database_empty_no_section_emitted():
    """When export_database has zero files, no Database Export section appears."""
    m = _base_manifest()
    m.add_file("git_repo", _make_entry(f"{ROOT_REL}/secrets/test-secrets.txt", channels_mod.SECRETS_EXPORT, size=128))
    m.recompute_channel_stats()

    content = _emit_to_tempfile(m)
    assert "## Database Export" not in content


def test_secrets_export_empty_section_still_emitted():
    """When secrets_export has zero files, the section IS still emitted (zero-file variant)."""
    m = _base_manifest()
    # No secrets_export files added — channel_stats will show file_count=0
    m.recompute_channel_stats()

    content = _emit_to_tempfile(m)
    assert "## Secrets Export" in content


def test_secrets_export_zero_file_variant_contains_scp():
    """Zero-file secrets_export section contains scp or seeding instructions."""
    m = _base_manifest()
    m.recompute_channel_stats()

    content = _emit_to_tempfile(m)
    # The zero-file variant must have seeding instructions with scp
    assert "scp" in content


def test_secrets_export_zero_file_variant_mentions_seeding():
    """Zero-file secrets_export section tells the operator to seed the channel."""
    m = _base_manifest()
    m.recompute_channel_stats()

    content = _emit_to_tempfile(m)
    # Must contain guidance about empty state and next steps
    assert "channel is empty" in content or "seed" in content.lower()


# ---------------------------------------------------------------------------
# 3. user_state two-tree split (spec §10 note 2)
# ---------------------------------------------------------------------------

def test_user_state_claude_only_emits_claude_rsync_not_knowledge():
    """All user_state files under .claude/ -> only .claude/ rsync command, no knowledge/ rsync."""
    m = _base_manifest()
    m.add_file("claude", _make_entry(
        f".claude/projects/-Users-testoperator-{ROOT_REL.replace('/', '-')}/memory/MEMORY.md",
        channels_mod.USER_STATE, size=1000, domain="claude",
    ))
    m.add_file("claude", _make_entry(
        f".claude/projects/-Users-testoperator-{ROOT_REL.replace('/', '-')}/memory/NOTES.md",
        channels_mod.USER_STATE, size=500, domain="claude",
    ))
    m.recompute_channel_stats()

    content = _emit_to_tempfile(m)
    assert "# Claude project memory" in content
    assert "# Authored knowledge agents" not in content


def test_user_state_knowledge_only_emits_knowledge_rsync_not_claude():
    """All user_state files under knowledge/ -> only knowledge/ rsync command, no .claude/ rsync."""
    m = _base_manifest()
    m.add_file("knowledge", _make_entry(
        "knowledge/agents/soma/INDEX.md",
        channels_mod.USER_STATE, size=1000, domain="knowledge",
    ))
    m.add_file("knowledge", _make_entry(
        "knowledge/agents/soma/lessons/XTEST-0001.md",
        channels_mod.USER_STATE, size=500, domain="knowledge",
    ))
    m.recompute_channel_stats()

    content = _emit_to_tempfile(m)
    assert "# Authored knowledge agents" in content
    assert "# Claude project memory" not in content


def test_user_state_mixed_emits_both_rsync_commands():
    """Mixed .claude/ and knowledge/ files -> both rsync commands appear."""
    m = _base_manifest()
    m.add_file("claude", _make_entry(
        f".claude/projects/-Users-testoperator-{ROOT_REL.replace('/', '-')}/memory/MEMORY.md",
        channels_mod.USER_STATE, size=1000, domain="claude",
    ))
    m.add_file("knowledge", _make_entry(
        "knowledge/agents/soma/INDEX.md",
        channels_mod.USER_STATE, size=500, domain="knowledge",
    ))
    m.recompute_channel_stats()

    content = _emit_to_tempfile(m)
    assert "# Claude project memory" in content
    assert "# Authored knowledge agents" in content


# ---------------------------------------------------------------------------
# 4. Deterministic output
# ---------------------------------------------------------------------------

def _build_manifest_with_multiple_entries() -> Manifest:
    """Build a manifest with multiple FileEntries to test ordering."""
    m = _base_manifest()
    # Add entries in a specific order
    m.add_file("git_repo", _make_entry(f"{ROOT_REL}/data/zoo.db", channels_mod.EXPORT_DATABASE, size=1000))
    m.add_file("git_repo", _make_entry(f"{ROOT_REL}/data/alpha.db", channels_mod.EXPORT_DATABASE, size=2000))
    m.add_file("git_repo", _make_entry(f"{ROOT_REL}/data/middle.db", channels_mod.EXPORT_DATABASE, size=3000))
    m.add_file("git_repo", _make_entry(f"{ROOT_REL}/secrets/zzz.env", channels_mod.SECRETS_EXPORT, size=100))
    m.add_file("git_repo", _make_entry(f"{ROOT_REL}/secrets/aaa.env", channels_mod.SECRETS_EXPORT, size=200))
    m.recompute_channel_stats()
    return m


def test_deterministic_output_same_manifest_same_content():
    """Two calls with the same manifest produce byte-identical output."""
    m = _build_manifest_with_multiple_entries()

    with tempfile.NamedTemporaryFile(suffix=".md", delete=False) as f1:
        path1 = Path(f1.name)
    with tempfile.NamedTemporaryFile(suffix=".md", delete=False) as f2:
        path2 = Path(f2.name)

    try:
        emit_pre_export_checklist(m, _team_config(), MANIFEST_PATH, path1)
        emit_pre_export_checklist(m, _team_config(), MANIFEST_PATH, path2)
        content1 = path1.read_bytes()
        content2 = path2.read_bytes()
        assert content1 == content2, "Two calls with identical manifest produced different output"
    finally:
        path1.unlink(missing_ok=True)
        path2.unlink(missing_ok=True)


def test_deterministic_output_different_add_order_same_content():
    """Adding entries in reverse order yields the same output (sort enforced)."""
    # Manifest A: add in alphabetical order
    m_a = _base_manifest()
    m_a.add_file("git_repo", _make_entry(f"{ROOT_REL}/data/alpha.db", channels_mod.EXPORT_DATABASE, size=1000))
    m_a.add_file("git_repo", _make_entry(f"{ROOT_REL}/data/middle.db", channels_mod.EXPORT_DATABASE, size=2000))
    m_a.add_file("git_repo", _make_entry(f"{ROOT_REL}/data/zoo.db", channels_mod.EXPORT_DATABASE, size=3000))
    m_a.recompute_channel_stats()

    # Manifest B: add in reverse order
    m_b = _base_manifest()
    m_b.add_file("git_repo", _make_entry(f"{ROOT_REL}/data/zoo.db", channels_mod.EXPORT_DATABASE, size=3000))
    m_b.add_file("git_repo", _make_entry(f"{ROOT_REL}/data/middle.db", channels_mod.EXPORT_DATABASE, size=2000))
    m_b.add_file("git_repo", _make_entry(f"{ROOT_REL}/data/alpha.db", channels_mod.EXPORT_DATABASE, size=1000))
    m_b.recompute_channel_stats()

    content_a = _emit_to_tempfile(m_a)
    content_b = _emit_to_tempfile(m_b)
    assert content_a == content_b, "Different insert orders produced non-identical output (sort not applied)"


# ---------------------------------------------------------------------------
# 5. Representative paths cap (top 5 + ellipsis)
# ---------------------------------------------------------------------------

def test_representative_paths_cap_shows_exactly_5():
    """A channel with > 5 files shows exactly 5 paths."""
    m = _base_manifest()
    for i in range(8):
        m.add_file("git_repo", _make_entry(
            f"{ROOT_REL}/data/db_{i:02d}.db",
            channels_mod.EXPORT_DATABASE,
            size=1000,
        ))
    m.recompute_channel_stats()

    content = _emit_to_tempfile(m)
    # Count path lines in the representative paths fenced block
    # The block starts with ``` and ends with ```; paths are between them
    in_paths_block = False
    path_lines = []
    for line in content.splitlines():
        if "**Representative paths" in line:
            in_paths_block = True
            continue
        if in_paths_block and line == "```":
            if not path_lines:
                # opening fence — skip
                continue
            else:
                # closing fence
                break
        if in_paths_block:
            path_lines.append(line)

    assert len(path_lines) == 5, f"Expected 5 representative paths, found {len(path_lines)}: {path_lines}"


def test_representative_paths_cap_shows_and_n_more():
    """A channel with > 5 files shows '… and N more.' marker with correct count."""
    m = _base_manifest()
    total = 8
    for i in range(total):
        m.add_file("git_repo", _make_entry(
            f"{ROOT_REL}/data/db_{i:02d}.db",
            channels_mod.EXPORT_DATABASE,
            size=1000,
        ))
    m.recompute_channel_stats()

    content = _emit_to_tempfile(m)
    remaining = total - 5
    assert f"… and {remaining} more." in content


def test_representative_paths_cap_ellipsis_is_unicode():
    """The ellipsis marker uses Unicode '…' per CHECKLIST_FORMAT_SPEC.md §10 note 6."""
    m = _base_manifest()
    for i in range(7):
        m.add_file("git_repo", _make_entry(
            f"{ROOT_REL}/data/db_{i:02d}.db",
            channels_mod.EXPORT_DATABASE,
            size=1000,
        ))
    m.recompute_channel_stats()

    content = _emit_to_tempfile(m)
    # Unicode ellipsis is required (matches the spec's worked examples)
    assert "… and" in content


def test_representative_paths_no_ellipsis_when_5_or_fewer():
    """A channel with exactly 5 files shows all 5, no '… and N more' marker."""
    m = _base_manifest()
    for i in range(5):
        m.add_file("git_repo", _make_entry(
            f"{ROOT_REL}/data/db_{i:02d}.db",
            channels_mod.EXPORT_DATABASE,
            size=1000,
        ))
    m.recompute_channel_stats()

    content = _emit_to_tempfile(m)
    assert "more." not in content


# ---------------------------------------------------------------------------
# 6. Byte formatting
# ---------------------------------------------------------------------------

def test_byte_formatting_thousands_separator():
    """Bytes are formatted with thousands separators (f'{n:,}') not KB/MB/GB."""
    m = _base_manifest()
    m.add_file("git_repo", _make_entry(
        f"{ROOT_REL}/data/finance.db",
        channels_mod.EXPORT_DATABASE,
        size=57886939,
    ))
    m.recompute_channel_stats()

    content = _emit_to_tempfile(m)
    assert "57,886,939" in content


def test_byte_formatting_no_kb_mb_gb():
    """Byte values are never rendered as KB, MB, or GB."""
    m = _base_manifest()
    m.add_file("git_repo", _make_entry(
        f"{ROOT_REL}/data/finance.db",
        channels_mod.EXPORT_DATABASE,
        size=57886939,
    ))
    m.recompute_channel_stats()

    content = _emit_to_tempfile(m)
    # Only check in the inventory line for this channel
    for line in content.splitlines():
        if "Inventory" in line and "57,886,939" in line:
            assert " KB" not in line
            assert " MB" not in line
            assert " GB" not in line


def test_byte_formatting_bytes_suffix():
    """Byte values carry the ' bytes' suffix."""
    m = _base_manifest()
    m.add_file("git_repo", _make_entry(
        f"{ROOT_REL}/data/finance.db",
        channels_mod.EXPORT_DATABASE,
        size=57886939,
    ))
    m.recompute_channel_stats()

    content = _emit_to_tempfile(m)
    assert "57,886,939 bytes" in content


# ---------------------------------------------------------------------------
# 7. Skip-when-output-outside-HOME (generator-level)
# ---------------------------------------------------------------------------

@pytest.mark.skipif(
    not (Path(__file__).parents[2] / "team_transfer" / "generator.py").exists(),
    reason="generator.py not found at expected path",
)
def test_generator_skips_checklist_when_output_outside_home(tmp_path):
    """Generator with --output /tmp/... writes manifest but NOT PRE_EXPORT_CHECKLIST.md."""
    lcars_ui = Path(__file__).resolve().parents[2]  # lcars-ui/

    manifest_out = tmp_path / "manifest.json"
    checklist_out = tmp_path / "PRE_EXPORT_CHECKLIST.md"

    env = os.environ.copy()
    env["PYTHONPATH"] = str(lcars_ui)

    result = subprocess.run(
        [
            sys.executable, "-m", "team_transfer.generator",
            "--team", "finance",
            "--output", str(manifest_out),
            "--allow-untagged",
        ],
        capture_output=True,
        text=True,
        env=env,
        cwd=str(lcars_ui.parent),
    )

    # Manifest must be written
    assert manifest_out.exists(), (
        f"Manifest was not written. stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
    )

    # Checklist must NOT be written
    assert not checklist_out.exists(), (
        f"PRE_EXPORT_CHECKLIST.md was written to /tmp when it should have been skipped"
    )

    # Stdout must contain the skip message
    combined = result.stdout + result.stderr
    assert "Skipping PRE_EXPORT_CHECKLIST.md emit" in combined, (
        f"Expected skip message not found in generator output:\n{combined}"
    )


# ---------------------------------------------------------------------------
# 8. Self-reference NOT added to manifest
# ---------------------------------------------------------------------------

@pytest.mark.skipif(
    not (Path(__file__).parents[2] / "team_transfer" / "generator.py").exists(),
    reason="generator.py not found at expected path",
)
def test_generator_checklist_not_in_manifest(tmp_path):
    """PRE_EXPORT_CHECKLIST.md does not appear as a FileEntry in the manifest."""
    lcars_ui = Path(__file__).resolve().parents[2]

    manifest_out = tmp_path / "manifest.json"

    env = os.environ.copy()
    env["PYTHONPATH"] = str(lcars_ui)

    result = subprocess.run(
        [
            sys.executable, "-m", "team_transfer.generator",
            "--team", "finance",
            "--output", str(manifest_out),
            "--allow-untagged",
        ],
        capture_output=True,
        text=True,
        env=env,
        cwd=str(lcars_ui.parent),
    )

    assert manifest_out.exists(), (
        f"Manifest was not written. stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
    )

    manifest_data = json.loads(manifest_out.read_text(encoding="utf-8"))
    all_relpaths = []
    for domain_block in manifest_data.get("domains", {}).values():
        for fe in domain_block.get("files", []):
            all_relpaths.append(fe.get("relpath", ""))

    checklist_relpaths = [rp for rp in all_relpaths if rp.endswith("PRE_EXPORT_CHECKLIST.md")]
    assert not checklist_relpaths, (
        f"PRE_EXPORT_CHECKLIST.md found as a manifest entry (relpath(s): {checklist_relpaths}). "
        "The checklist is generator output, not tracked user content."
    )


# ---------------------------------------------------------------------------
# 9. Encoding + trailing newline
# ---------------------------------------------------------------------------

def test_output_ends_with_newline():
    """Output file ends with a trailing newline character."""
    m = _build_full_manifest()
    with tempfile.NamedTemporaryFile(suffix=".md", delete=False) as f:
        tmppath = Path(f.name)
    try:
        emit_pre_export_checklist(m, _team_config(), MANIFEST_PATH, tmppath)
        raw = tmppath.read_bytes()
        assert raw.endswith(b"\n"), (
            f"File does not end with newline. Last 20 bytes: {raw[-20:]!r}"
        )
    finally:
        tmppath.unlink(missing_ok=True)


def test_output_is_valid_utf8():
    """Output file is valid UTF-8."""
    m = _build_full_manifest()
    with tempfile.NamedTemporaryFile(suffix=".md", delete=False) as f:
        tmppath = Path(f.name)
    try:
        emit_pre_export_checklist(m, _team_config(), MANIFEST_PATH, tmppath)
        raw = tmppath.read_bytes()
        # This will raise UnicodeDecodeError if not valid UTF-8
        decoded = raw.decode("utf-8")
        assert len(decoded) > 0
    finally:
        tmppath.unlink(missing_ok=True)


# ---------------------------------------------------------------------------
# Additional: content fidelity checks
# ---------------------------------------------------------------------------

def test_generator_owned_disclaimer_in_header():
    """Header contains the 'generator-owned' disclaimer."""
    m = _build_full_manifest()
    content = _emit_to_tempfile(m)
    assert "generator-owned" in content


def test_footer_contains_next_steps():
    """Footer block contains Next Steps with verifier command."""
    m = _build_full_manifest()
    content = _emit_to_tempfile(m)
    assert "## Next Steps" in content
    assert "team_transfer.verifier" in content
    assert "<TICKET_ID>" in content


def test_footer_ticket_id_is_literal_placeholder():
    """Footer renders <TICKET_ID> literally (spec: do not infer from manifest)."""
    m = _build_full_manifest()
    content = _emit_to_tempfile(m)
    assert "<TICKET_ID>" in content


def test_export_database_section_contains_checksum_flag():
    """Database Export transfer command includes the --checksum rsync flag (spec §5.2)."""
    m = _base_manifest()
    m.add_file("git_repo", _make_entry(
        f"{ROOT_REL}/data/finance.db",
        channels_mod.EXPORT_DATABASE,
        size=524288,
    ))
    m.recompute_channel_stats()

    content = _emit_to_tempfile(m)
    assert "--checksum" in content


def test_export_database_schema_check_note():
    """Database Export success criteria block contains the SCHEMA check note (spec §6)."""
    m = _base_manifest()
    m.add_file("git_repo", _make_entry(
        f"{ROOT_REL}/data/finance.db",
        channels_mod.EXPORT_DATABASE,
        size=524288,
    ))
    m.recompute_channel_stats()

    content = _emit_to_tempfile(m)
    assert "SCHEMA checks confirm" in content
    assert "sha256 mismatch" in content


def test_secrets_export_password_handoff_note():
    """Secrets Export success criteria block contains password handoff note (spec §6)."""
    m = _base_manifest()
    m.add_file("git_repo", _make_entry(
        f"{ROOT_REL}/secrets/api.env",
        channels_mod.SECRETS_EXPORT,
        size=256,
    ))
    m.recompute_channel_stats()

    content = _emit_to_tempfile(m)
    assert "Password handoff required" in content


def test_secrets_export_warns_no_secret_values_in_filenames():
    """Secrets Export section warns about filenames being unencrypted in ZIP metadata.

    XACA-0490 review subitem 009: the generated checklist must carry the guidance
    that ZIP central-directory entries (file names and sizes) are not encrypted,
    so operators must not embed secret values in filenames. Must appear in BOTH
    the non-zero variant (where the user is about to copy real secrets) AND the
    zero-file variant (where the user is about to seed the channel).
    """
    # Non-zero variant
    m = _base_manifest()
    m.add_file("git_repo", _make_entry(
        f"{ROOT_REL}/secrets/api.env",
        channels_mod.SECRETS_EXPORT,
        size=256,
    ))
    m.recompute_channel_stats()
    content = _emit_to_tempfile(m)
    assert "No secret values in filenames" in content

    # Zero-file variant
    m_empty = _base_manifest()
    m_empty.recompute_channel_stats()
    content_empty = _emit_to_tempfile(m_empty)
    assert "No secret values in filenames" in content_empty


def test_secrets_export_uses_scp_not_rsync():
    """Non-zero secrets_export channel uses per-file scp, not rsync (spec §5)."""
    m = _base_manifest()
    m.add_file("git_repo", _make_entry(
        f"{ROOT_REL}/secrets/api.env",
        channels_mod.SECRETS_EXPORT,
        size=256,
    ))
    m.recompute_channel_stats()

    content = _emit_to_tempfile(m)
    # Find the Secrets Export section
    in_transfer_block = False
    in_secrets_section = False
    for line in content.splitlines():
        if "## Secrets Export" in line:
            in_secrets_section = True
        if in_secrets_section and "**Transfer command:**" in line:
            in_transfer_block = True
            continue
        if in_transfer_block and line.startswith("```bash"):
            continue
        if in_transfer_block and line == "```":
            break
        if in_transfer_block:
            # Transfer lines must use scp
            if line.strip() and not line.startswith("#"):
                assert line.startswith("scp "), (
                    f"Expected scp in secrets transfer command, got: {line!r}"
                )


def test_secrets_export_more_than_5_files_has_note():
    """Secrets with > 5 files lists first 5 scp lines plus a NOTE comment (spec §5.2)."""
    m = _base_manifest()
    for i in range(7):
        m.add_file("git_repo", _make_entry(
            f"{ROOT_REL}/secrets/secret_{i:02d}.env",
            channels_mod.SECRETS_EXPORT,
            size=100,
        ))
    m.recompute_channel_stats()

    content = _emit_to_tempfile(m)
    # NOTE comment must appear
    assert "# NOTE:" in content
    remaining = 7 - 5
    assert f"{remaining} more files" in content


def test_auto_channel_summary_ordering():
    """Auto-channel table rows appear in the order: git, export_kanban, aiteamforge_product, icloud_excluded.

    This matches the spec §3 ordering: channels appear as in _AUTO_CHANNELS, which
    does NOT follow ALL_CHANNELS order — it's git, export_kanban, aiteamforge_product, icloud_excluded.
    """
    m = _build_full_manifest()
    content = _emit_to_tempfile(m)

    # Find the auto-channel table and extract row order.
    # State machine: locate the header, skip blank/header/separator lines,
    # collect data rows, stop when we leave the pipe-table.
    in_table = False
    past_header = False  # True once we've seen the | Channel | header row
    channel_order = []
    for line in content.splitlines():
        if "## Automatic Channels" in line:
            in_table = True
            continue
        if not in_table:
            continue
        if not line.strip():
            # Blank lines inside table section: skip until we've started collecting
            if channel_order:
                break
            continue
        if line.startswith("| Channel"):
            past_header = True
            continue  # header row
        if line.startswith("|---") or line.startswith("|-"):
            continue  # separator row
        if line.startswith("| ") and past_header:
            # Data row — extract channel name from first cell
            cell = line.split("|")[1].strip()
            channel_order.append(cell)
        elif not line.startswith("|"):
            if channel_order:
                break

    expected_order = ["git", "export_kanban", "aiteamforge_product", "icloud_excluded"]
    assert channel_order == expected_order, (
        f"Auto-channel table order mismatch.\n"
        f"Expected: {expected_order}\n"
        f"Got:      {channel_order}"
    )


def test_operator_section_ordering():
    """Operator-action sections appear in ALL_CHANNELS position order: export_database, secrets_export, user_state."""
    m = _build_full_manifest()
    content = _emit_to_tempfile(m)

    db_pos = content.find("## Database Export")
    secrets_pos = content.find("## Secrets Export")
    user_pos = content.find("## User State (Memory & Knowledge)")

    assert db_pos != -1, "Database Export section not found"
    assert secrets_pos != -1, "Secrets Export section not found"
    assert user_pos != -1, "User State section not found"

    assert db_pos < secrets_pos, "Database Export must appear before Secrets Export"
    assert secrets_pos < user_pos, "Secrets Export must appear before User State"


def test_single_file_database_lcd_is_parent_dir():
    """Single-file export_database channel: LCD is the file's parent directory (spec §10 note 1)."""
    m = _base_manifest()
    m.add_file("git_repo", _make_entry(
        f"{ROOT_REL}/data/finance.db",
        channels_mod.EXPORT_DATABASE,
        size=524288,
    ))
    m.recompute_channel_stats()

    content = _emit_to_tempfile(m)
    # The rsync command should use the data/ directory, not the file itself
    expected_lcd = f"{HOME}/{ROOT_REL}/data"
    assert f"{expected_lcd}/" in content, (
        f"Expected LCD directory {expected_lcd}/ in rsync command, not the file itself"
    )


def test_what_it_carries_display_name_strings():
    """Display names and one-line descriptions match spec §4.4 exactly."""
    m = _build_full_manifest()
    content = _emit_to_tempfile(m)

    # user_state
    assert "Claude agent memory, authored knowledge bases, and session logs" in content
    assert "not transferred by AITeamForge" in content

    # export_database
    assert "SQLite databases requiring explicit transfer" in content
    assert "structural-integrity verification" in content

    # secrets_export
    assert "Env files, credential stores, and the secrets/ directory" in content


def test_manifest_path_used_in_verify_command():
    """Success criteria verify commands reference the correct manifest path."""
    m = _base_manifest()
    m.add_file("git_repo", _make_entry(
        f"{ROOT_REL}/data/finance.db",
        channels_mod.EXPORT_DATABASE,
        size=1000,
    ))
    m.recompute_channel_stats()

    content = _emit_to_tempfile(m)
    assert f"--manifest {MANIFEST_PATH}" in content
