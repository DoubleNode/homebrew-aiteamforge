"""Pre-export checklist emitter.

Renders PRE_EXPORT_CHECKLIST.md from a finalized Manifest object and writes it to
the given output path.

Stdlib-only. No third-party deps. All rendering is deterministic — same manifest
input produces byte-identical output.

Public API:
    emit_pre_export_checklist(manifest, team_config, manifest_path, output_path)
"""
from __future__ import annotations

import os
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from .manifest import Manifest

from . import channels as channels_mod

# ---------------------------------------------------------------------------
# Display metadata for each operator-action channel
# ---------------------------------------------------------------------------

_AUTO_CHANNELS = [
    (channels_mod.GIT,              "git clone / rsync (AITeamForge)"),
    (channels_mod.EXPORT_KANBAN,    "kb-team-export bundle (auto-packed)"),
    (channels_mod.AITEAMFORGE_PRODUCT, "AITeamForge installer on destination"),
    (channels_mod.ICLOUD_EXCLUDED,  "iCloud — files must NOT exist locally"),
]

_OPERATOR_ACTION_CHANNELS = [
    channels_mod.EXPORT_DATABASE,
    channels_mod.SECRETS_EXPORT,
    channels_mod.USER_STATE,
]

_DISPLAY_NAME = {
    channels_mod.USER_STATE:       "User State (Memory & Knowledge)",
    channels_mod.EXPORT_DATABASE:  "Database Export",
    channels_mod.SECRETS_EXPORT:   "Secrets Export",
}

_ONE_LINE_DESC = {
    channels_mod.USER_STATE: (
        "Claude agent memory, authored knowledge bases, and session logs "
        "— not transferred by AITeamForge."
    ),
    channels_mod.EXPORT_DATABASE: (
        "SQLite databases requiring explicit transfer and structural-integrity "
        "verification on the destination."
    ),
    channels_mod.SECRETS_EXPORT: (
        "Env files, credential stores, and the secrets/ directory "
        "— encrypted at pack time; distributed separately."
    ),
}


# ---------------------------------------------------------------------------
# Formatting helpers
# ---------------------------------------------------------------------------

def _fmt_bytes(n: int) -> str:
    """Return n formatted with thousands separators and ' bytes' suffix."""
    return f"{n:,} bytes"


def _collect_channel_files(manifest: "Manifest", channel: str) -> list:
    """Return all FileEntry objects for the given channel, across all domains."""
    entries = []
    for domain_block in manifest.domains.values():
        for fe in domain_block.files:
            if fe.channel == channel:
                entries.append(fe)
    return entries


def _sorted_paths(entries: list) -> list[str]:
    """Return absolute paths sorted by relpath (deterministic, portable key)."""
    return [fe.path for fe in sorted(entries, key=lambda fe: fe.relpath)]


def _format_paths_block(sorted_abs_paths: list[str]) -> str:
    """Render the representative-paths fenced block and optional 'and N more' suffix.

    Per CHECKLIST_FORMAT_SPEC.md §10 note 6, the suffix uses Unicode ellipsis (…),
    not three ASCII dots. The spec's worked examples and implementation notes are
    consistent on this point.
    """
    display = sorted_abs_paths[:5]
    lines = ["```"] + display + ["```"]
    if len(sorted_abs_paths) > 5:
        remaining = len(sorted_abs_paths) - 5
        lines.append(f"… and {remaining} more.")
    return "\n".join(lines)


def _compute_lcd(abs_paths: list[str]) -> str:
    """Compute the lowest common directory across abs_paths.

    Returns the directory containing all files. For a single path that is a
    file (not a directory), returns its parent directory.
    """
    if not abs_paths:
        raise ValueError("Cannot compute LCD of empty path list")
    common = os.path.commonpath(sorted(abs_paths))
    if not os.path.isdir(common):
        common = os.path.dirname(common)
    return common


# ---------------------------------------------------------------------------
# Header + footer
# ---------------------------------------------------------------------------

def _render_header(manifest: "Manifest", team_config: dict, manifest_path: Path) -> str:
    team_title = team_config["team"].title()
    lines = [
        f"# Pre-Export Checklist — {team_title} Team",
        "",
        f"Generated : {manifest.generated_at}",
        f"Manifest  : {manifest_path}",
        f"Source    : {manifest.source_user}@{manifest.source_hostname}",
        "",
        "> This file is generator-owned. Re-running the generator overwrites it.",
        "> Do NOT edit manually.",
    ]
    return "\n".join(lines)


def _render_missing_roots_warning(manifest: "Manifest") -> str:
    """Render a blocking warning block for domain roots that were configured
    but did not exist on the source machine when the generator ran.

    XACA-0954: this is the human-facing counterpart to the generator's CLI
    warning. Without it, an operator working ONLY from this checklist (not
    watching the generator's console output) had no way to know a domain was
    never scanned — a domain showing zero files here looked identical to a
    domain that was scanned and genuinely found empty. Placed immediately
    after the header, before the operator reaches a single checkbox, so it
    cannot be skipped by reading top-to-bottom.
    """
    rows = []
    for r in sorted(manifest.missing_roots, key=lambda r: (r.get("domain", ""), r.get("path", ""))):
        domain = r.get("domain", "?")
        path = r.get("path", "?")
        config_key = r.get("config_key") or "(unspecified)"
        reason = r.get("reason", "")
        rows.append(f"- **{domain}** — `{path}` (config key: `{config_key}`)\n  reason: {reason}")

    lines = [
        "---",
        "",
        "## :warning: STOP — MISSING DOMAIN ROOTS — DO NOT EXPORT YET",
        "",
        "One or more domain roots configured in the team YAML did **not exist** on this "
        "machine when the generator ran. The scan **never reached** these paths — this is "
        "not the same as a domain being scanned and found empty. Any files under these "
        "roots are **absent from this manifest and from the export**, silently.",
        "",
    ] + rows + [
        "",
        "**Before you proceed with ANY channel below:**",
        "1. Fix the path for the `config_key`(s) above in the team YAML config "
        "(or confirm the root is genuinely gone and remove the stale entry).",
        "2. Re-run the generator:",
        "   ```bash",
        "   PYTHONPATH=lcars-ui python -m team_transfer.generator --team <team>",
        "   ```",
        "3. Confirm this section is gone from the regenerated checklist before exporting.",
        "",
        "Checking off items below while this section is present means shipping an "
        "**incomplete** export.",
    ]
    return "\n".join(lines)


def _render_auto_summary(manifest: "Manifest") -> str:
    rows = []
    for channel, mechanism in _AUTO_CHANNELS:
        stats = manifest.channel_stats.get(channel, {"file_count": 0, "total_bytes": 0})
        count = stats["file_count"]
        total = _fmt_bytes(stats["total_bytes"])
        rows.append(f"| {channel:<19} | {count:<5} | {total:<14} | {mechanism:<38} |")

    lines = [
        "## Automatic Channels (no operator action required)",
        "",
        "| Channel             | Files | Bytes          | Mechanism                              |",
        "|---------------------|-------|----------------|----------------------------------------|",
    ] + rows
    return "\n".join(lines)


def _render_footer(manifest_path: Path) -> str:
    lines = [
        "---",
        "",
        "## Next Steps",
        "",
        "1. Run the verifier on the **destination** machine after transfer:",
        "   ```bash",
        f"   python3 -m team_transfer.verifier --manifest {manifest_path}",
        "   ```",
        "2. See the full runbook for failure patterns and remediation:",
        "   `docs/team-transfer/RUNBOOK.md`",
        "3. After successful verification, complete the kanban item:",
        "   ```bash",
        "   source ~/dev-team/kanban-helpers.sh && kb-done <TICKET_ID>",
        "   ```",
        "",
        "> This file was generated by `python -m team_transfer.generator` and will be",
        "> **overwritten on the next run**. Do not edit manually.",
    ]
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Per-channel section renderers
# ---------------------------------------------------------------------------

def _render_section_export_database(
    entries: list,
    manifest: "Manifest",
    manifest_path: Path,
) -> str:
    stats = manifest.channel_stats.get(channels_mod.EXPORT_DATABASE, {"file_count": 0, "total_bytes": 0})
    file_count = stats["file_count"]
    total_bytes = stats["total_bytes"]

    abs_paths = _sorted_paths(entries)
    paths_block = _format_paths_block(abs_paths)

    lcd = _compute_lcd(abs_paths)
    src_user = manifest.source_user
    src_host = manifest.source_hostname

    transfer_cmd = (
        f"rsync -avz --checksum \\\n"
        f"  {src_user}@{src_host}:{lcd}/ \\\n"
        f"  {lcd}/"
    )
    verify_cmd = (
        f"python3 -m team_transfer.verifier \\\n"
        f"  --manifest {manifest_path} \\\n"
        f"  --channel {channels_mod.EXPORT_DATABASE}\n"
        f"# All entries must show: PASS"
    )
    extra = (
        "SCHEMA checks confirm table structure and row counts. "
        "A `sha256 mismatch` on a DB file is expected and correct "
        "— SCHEMA is the authoritative check, not byte equality."
    )

    lines = [
        "---",
        "",
        f"## {_DISPLAY_NAME[channels_mod.EXPORT_DATABASE]}",
        "",
        f"**What it carries:** {_ONE_LINE_DESC[channels_mod.EXPORT_DATABASE]}",
        "",
        f"**Inventory:** {file_count} files — {_fmt_bytes(total_bytes)}",
        "",
        "**Representative paths (top 5):**",
        paths_block,
        "",
        "**Transfer command:**",
        "```bash",
        transfer_cmd,
        "```",
        "",
        "**Success criteria:**",
        "```bash",
        verify_cmd,
        "```",
        extra,
    ]
    return "\n".join(lines)


def _render_section_secrets_export_zero(manifest: "Manifest", team_config: dict) -> str:
    home = manifest.home
    root = team_config.get("home_relative_root", "")
    team = team_config.get("team", "")
    root_path = f"{home}/{root}" if root else home

    lines = [
        "---",
        "",
        f"## {_DISPLAY_NAME[channels_mod.SECRETS_EXPORT]}",
        "",
        f"**What it carries:** {_ONE_LINE_DESC[channels_mod.SECRETS_EXPORT]}",
        "",
        "**Inventory:** 0 files — channel is empty.",
        "",
        "**Action required — seed the channel before exporting:**",
        "",
        "The secrets channel is empty. If this team has real secrets (`.env`, credential files,",
        f"API keys), transfer them into `{root_path}/secrets/` on this machine NOW, then",
        "re-run the generator so they are cataloged in the manifest before you export.",
        "",
        "```bash",
        "# Pull secrets from wherever they are currently stored (adjust path as needed)",
        f"scp -r <secrets-source-host>:<remote-secrets-path>/ {root_path}/secrets/",
        "```",
        "",
        "Re-run generator after seeding:",
        "```bash",
        f"PYTHONPATH=lcars-ui python -m team_transfer.generator --team {team}",
        "```",
        "",
        "If this team genuinely has no secrets, no action is required. "
        "The `secrets/test-secrets.txt`",
        "placeholder exists to exercise the pack/unpack path and will be cataloged automatically.",
        "",
        "**No secret values in filenames:** When you seed the channel, do NOT put secret values "
        "in file NAMES — ZIP central-directory entries (file names and sizes) are NOT encrypted. "
        "Secret values belong only in file CONTENTS.",
    ]
    return "\n".join(lines)


def _render_section_secrets_export(
    entries: list,
    manifest: "Manifest",
    team_config: dict,
    manifest_path: Path,
) -> str:
    stats = manifest.channel_stats.get(channels_mod.SECRETS_EXPORT, {"file_count": 0, "total_bytes": 0})
    file_count = stats["file_count"]
    total_bytes = stats["total_bytes"]

    if file_count == 0:
        return _render_section_secrets_export_zero(manifest, team_config)

    abs_paths = _sorted_paths(entries)
    paths_block = _format_paths_block(abs_paths)

    src_user = manifest.source_user
    src_host = manifest.source_hostname

    # Per-file scp for up to 5 files
    scp_paths = abs_paths[:5]
    scp_lines = [
        f"scp {src_user}@{src_host}:{p} {p}"
        for p in scp_paths
    ]
    if len(abs_paths) > 5:
        remaining = len(abs_paths) - 5
        scp_lines.append(
            f"# NOTE: {remaining} more files in this channel -- check the manifest for full list:"
        )
        scp_lines.append(f"# {manifest_path}")

    transfer_cmd = "\n".join(scp_lines)

    verify_cmd = (
        f"python3 -m team_transfer.verifier \\\n"
        f"  --manifest {manifest_path} \\\n"
        f"  --channel {channels_mod.SECRETS_EXPORT}\n"
        f"# All entries must show: PASS"
    )
    extra = (
        "**Password handoff required:** The secrets bundle is AES-256 encrypted. "
        "Transmit the export password to the destination operator via a separate secure channel "
        "(Signal, 1Password share, in-person). "
        "Do NOT put the password in any file, git commit, or message thread.\n\n"
        "**No secret values in filenames:** ZIP central-directory entries (file names and sizes) "
        "are NOT encrypted. Before transfer, verify no secret VALUES appear in any file NAME "
        "under `secrets/` — only in file CONTENTS. Rename any offenders before re-running the "
        "generator."
    )

    lines = [
        "---",
        "",
        f"## {_DISPLAY_NAME[channels_mod.SECRETS_EXPORT]}",
        "",
        f"**What it carries:** {_ONE_LINE_DESC[channels_mod.SECRETS_EXPORT]}",
        "",
        f"**Inventory:** {file_count} files — {_fmt_bytes(total_bytes)}",
        "",
        "**Representative paths (top 5):**",
        paths_block,
        "",
        "**Transfer command:**",
        "```bash",
        transfer_cmd,
        "```",
        "",
        "**Success criteria:**",
        "```bash",
        verify_cmd,
        "```",
        extra,
    ]
    return "\n".join(lines)


def _render_section_user_state(
    entries: list,
    manifest: "Manifest",
    manifest_path: Path,
) -> str:
    stats = manifest.channel_stats.get(channels_mod.USER_STATE, {"file_count": 0, "total_bytes": 0})
    file_count = stats["file_count"]
    total_bytes = stats["total_bytes"]

    abs_paths = _sorted_paths(entries)
    paths_block = _format_paths_block(abs_paths)

    src_user = manifest.source_user
    src_host = manifest.source_hostname

    # Split files into two groups by relpath prefix
    claude_entries = [fe for fe in entries if fe.relpath.startswith(".claude/")]
    knowledge_entries = [fe for fe in entries if fe.relpath.startswith("knowledge/")]

    transfer_lines = []
    if claude_entries:
        claude_paths = [fe.path for fe in claude_entries]
        lcd_claude = _compute_lcd(claude_paths)
        transfer_lines += [
            "# Claude project memory (excludes ephemeral session logs)",
            "rsync -avz --include='*/' \\",
            "  --include='memory/*.md' \\",
            "  --exclude='*.jsonl' \\",
            "  --exclude='*' \\",
            f"  {src_user}@{src_host}:{lcd_claude}/ \\",
            f"  {lcd_claude}/",
        ]
    if knowledge_entries and claude_entries:
        transfer_lines.append("")
    if knowledge_entries:
        knowledge_paths = [fe.path for fe in knowledge_entries]
        lcd_knowledge = _compute_lcd(knowledge_paths)
        transfer_lines += [
            "# Authored knowledge agents",
            "rsync -avz \\",
            f"  {src_user}@{src_host}:{lcd_knowledge}/ \\",
            f"  {lcd_knowledge}/",
        ]

    transfer_cmd = "\n".join(transfer_lines)

    verify_cmd = (
        f"python3 -m team_transfer.verifier \\\n"
        f"  --manifest {manifest_path} \\\n"
        f"  --channel {channels_mod.USER_STATE}\n"
        f"# All entries must show: PASS"
    )

    lines = [
        "---",
        "",
        f"## {_DISPLAY_NAME[channels_mod.USER_STATE]}",
        "",
        f"**What it carries:** {_ONE_LINE_DESC[channels_mod.USER_STATE]}",
        "",
        f"**Inventory:** {file_count} files — {_fmt_bytes(total_bytes)}",
        "",
        "**Representative paths (top 5):**",
        paths_block,
        "",
        "**Transfer command:**",
        "```bash",
        transfer_cmd,
        "```",
        "",
        "**Success criteria:**",
        "```bash",
        verify_cmd,
        "```",
    ]
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def emit_pre_export_checklist(
    manifest: "Manifest",
    team_config: dict,
    manifest_path: Path,
    output_path: Path,
) -> None:
    """Render PRE_EXPORT_CHECKLIST.md from the manifest and write to output_path.

    output_path is the .md file's absolute path (the caller decides where --
    typically <manifest_dir>/PRE_EXPORT_CHECKLIST.md).

    Raises:
        ValueError: If a required field is missing from manifest or team_config.
        OSError: If output_path cannot be written.
    """
    sections: list[str] = []

    # 1. Header
    sections.append(_render_header(manifest, team_config, manifest_path))
    sections.append("")

    # 1b. Missing-roots warning (XACA-0954) — before ANY checklist content, so
    # an operator reading only this file cannot miss it and cannot reach a
    # single checkbox without seeing it first.
    if manifest.missing_roots:
        sections.append(_render_missing_roots_warning(manifest))
        sections.append("")

    # 2. Auto-channel summary
    sections.append(_render_auto_summary(manifest))
    sections.append("")

    # 3. Per-channel sections for operator-action channels, in ALL_CHANNELS order
    for channel in channels_mod.ALL_CHANNELS:
        if channel not in _OPERATOR_ACTION_CHANNELS:
            continue

        stats = manifest.channel_stats.get(channel, {"file_count": 0, "total_bytes": 0})
        file_count = stats["file_count"]
        entries = _collect_channel_files(manifest, channel)

        if channel == channels_mod.EXPORT_DATABASE:
            if file_count == 0:
                continue  # skip entirely when empty
            sections.append(
                _render_section_export_database(entries, manifest, manifest_path)
            )

        elif channel == channels_mod.SECRETS_EXPORT:
            # Always emit — zero-file variant if empty
            sections.append(
                _render_section_secrets_export(entries, manifest, team_config, manifest_path)
            )

        elif channel == channels_mod.USER_STATE:
            if file_count == 0:
                continue  # skip entirely when empty
            sections.append(
                _render_section_user_state(entries, manifest, manifest_path)
            )

        sections.append("")

    # 4. Footer
    sections.append(_render_footer(manifest_path))
    sections.append("")  # trailing newline

    content = "\n".join(sections)
    output_path.write_text(content, encoding="utf-8")
