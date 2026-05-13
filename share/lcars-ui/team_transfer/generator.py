"""Inventory generator CLI.

  PYTHONPATH=lcars-ui python -m team_transfer.generator \\
      --team finance \\
      --output migration-manifest.json
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

from . import channels as channels_mod
from . import domain_claude, domain_devteam, domain_git, domain_kanban, domain_knowledge
from .channels import load_team_config
from .checksum import safe_relpath
from .db_integrity import probe_db
from .manifest import FileEntry, Manifest, PRESENT, new_manifest


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description="Generate migration audit manifest.",
        epilog=(
            "Run with lcars-ui/ on sys.path:\n"
            "  PYTHONPATH=lcars-ui python -m team_transfer.generator --team finance"
        ),
    )
    ap.add_argument("--team", "-t", default="finance",
                    help="Team name — selects the per-team YAML config (default: finance)")
    ap.add_argument("--team-config-dir", default=None,
                    help="Override directory to search for <team>.yaml before package defaults")
    ap.add_argument("--output", "-o", default=None,
                    help="Output JSON manifest path (default: <home>/<root>/docs/migration/migration-manifest.json)")
    ap.add_argument("--repo-root", default=None,
                    help="Git repo root (default: <home>/<home_relative_root> from team config)")
    ap.add_argument("--channels-config", default=None,
                    help="User-facing YAML override file with an 'overrides:' section (default: none — use the team config's built-in overrides: slot)")
    ap.add_argument("--allow-untagged", action="store_true",
                    help="Don't fail on untagged files (default: exit 1 if any)")
    args = ap.parse_args(argv)

    home = Path.home()
    team_cfg_dir = Path(args.team_config_dir) if args.team_config_dir else None

    try:
        team_config = load_team_config(args.team, config_dir=team_cfg_dir)
    except FileNotFoundError as e:
        print(f"[generator] ERROR: {e}", file=sys.stderr)
        return 2

    root_rel = team_config.get("home_relative_root", "")
    repo_root = Path(args.repo_root).resolve() if args.repo_root else (home / root_rel)

    default_output = home / root_rel / "docs" / "migration" / "migration-manifest.json"
    out = Path(args.output).resolve() if args.output else default_output
    out.parent.mkdir(parents=True, exist_ok=True)

    channels_yaml = Path(args.channels_config) if args.channels_config else None

    channels = channels_mod.build_config(
        home=home,
        yaml_overrides=channels_yaml,
        team_config=team_config,
    )
    manifest = new_manifest()

    print(f"[generator] Team: {args.team}", flush=True)
    print(f"[generator] Repo root: {repo_root}", flush=True)
    if channels_yaml is not None:
        _cfg_status = "present" if channels_yaml.exists() else "missing — defaults only"
        print(f"[generator] Channels config: {channels_yaml} ({_cfg_status})", flush=True)
    else:
        print("[generator] Channels config: none — using team config defaults only", flush=True)

    # The manifest file itself is added once below as a PRESENT-class self-entry.
    # Tell domain_git to skip it so we don't end up with a stale EXACT duplicate.
    skip_paths = {out}

    print("[generator] Domain 1: git_repo ...", flush=True)
    domain_git.inventory(
        repo_root, manifest, channels,
        db_probe_fn=probe_db,
        skip_paths=skip_paths,
        team_config=team_config,
        home=home,
    )
    print(f"  -> {len(manifest.domains.get('git_repo', _empty()).files)} files", flush=True)

    print("[generator] Domain 2: kanban ...", flush=True)
    domain_kanban.inventory(repo_root, manifest, channels, home=home, team_config=team_config)
    print(f"  -> {len(manifest.domains.get('kanban', _empty()).files)} files", flush=True)

    print("[generator] Domain 3: devteam ...", flush=True)
    domain_devteam.inventory(manifest, channels, home=home, team_config=team_config)
    print(f"  -> {len(manifest.domains.get('devteam', _empty()).files)} files", flush=True)

    print("[generator] Domain 4: knowledge ...", flush=True)
    domain_knowledge.inventory(manifest, channels, repo_root=repo_root, home=home, team_config=team_config)
    print(f"  -> {len(manifest.domains.get('knowledge', _empty()).files)} files", flush=True)

    print("[generator] Domain 5: claude ...", flush=True)
    domain_claude.inventory(manifest, channels, home=home, team_config=team_config)
    print(f"  -> {len(manifest.domains.get('claude', _empty()).files)} files", flush=True)

    # Self-include: add a manifest entry for the manifest file itself.
    self_channel = channels.resolve(str(out))
    if self_channel == channels_mod.UNTAGGED:
        self_channel = channels_mod.GIT
    self_entry = FileEntry(
        path=str(out),
        relpath=safe_relpath(out, home),
        sha256=None,
        size=0,
        mtime=0.0,
        cls=PRESENT,
        channel=self_channel,
        domain="git_repo",
        probe={"kind": "self_reference", "note": "manifest references itself; verifier checks existence only"},
    )
    manifest.add_file("git_repo", self_entry)

    manifest.recompute_channel_stats()
    gaps = manifest.collect_untagged()

    out.write_text(manifest.to_json(), encoding="utf-8")
    total = sum(len(d.files) for d in manifest.domains.values())
    print(f"\n[generator] Wrote {out} — {total} entries across {len(manifest.domains)} domains", flush=True)

    print("\n=== CHANNEL STATS ===", flush=True)
    for ch in manifest.channels:
        s = manifest.channel_stats.get(ch, {"file_count": 0, "total_bytes": 0})
        print(f"  {ch:18s} {s['file_count']:>5d} files  {s['total_bytes']:>12,d} bytes", flush=True)

    if gaps:
        print(f"\n=== x UNTAGGED GAPS ({len(gaps)}) ===", flush=True)
        for g in gaps[:25]:
            print(f"  {g}", flush=True)
        if len(gaps) > 25:
            print(f"  ... and {len(gaps) - 25} more", flush=True)
        print("\nAdd matching rules to the 'overrides:' section of your team config and re-run.", flush=True)
        if not args.allow_untagged:
            return 1
    else:
        print("\n[generator] Zero untagged gaps — all files have a transfer channel.", flush=True)

    return 0


def _empty():
    from .manifest import DomainBlock
    return DomainBlock()


if __name__ == "__main__":
    sys.exit(main())
