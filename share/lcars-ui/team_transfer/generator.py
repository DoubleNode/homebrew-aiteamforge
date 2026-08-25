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
from .checklist import emit_pre_export_checklist
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
    ap.add_argument("--allow-missing-roots", action="store_true",
                    help="Don't fail on missing domain roots (default: exit 1 if any). "
                         "Independent of --allow-untagged — a missing root is a different "
                         "failure class (unscanned territory) than an untagged file (scanned "
                         "but unrouted), and tolerating one is not consent for the other.")
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
    # XACA-0586-010: record the export team slug so the import preflight wrong-team gate
    # can compare source base against target base and block cross-team imports.
    manifest.source_team = args.team

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
    # XACA-0490: PRE_EXPORT_CHECKLIST.md is excluded via ALWAYS_EXCLUDE_GLOBS
    # in checksum.py — it's generator-owned output, not user content.
    checklist_path = out.parent / "PRE_EXPORT_CHECKLIST.md"

    print("[generator] Domain 1: git_repo ...", flush=True)
    domain_git.inventory(
        repo_root, manifest, channels,
        db_probe_fn=probe_db,
        skip_paths=skip_paths,
        team_config=team_config,
        home=home,
    )
    _print_domain_result(manifest, "git_repo")

    print("[generator] Domain 2: kanban ...", flush=True)
    domain_kanban.inventory(repo_root, manifest, channels, home=home, team_config=team_config)
    _print_domain_result(manifest, "kanban")

    print("[generator] Domain 3: devteam ...", flush=True)
    domain_devteam.inventory(manifest, channels, home=home, team_config=team_config)
    _print_domain_result(manifest, "devteam")

    print("[generator] Domain 4: knowledge ...", flush=True)
    domain_knowledge.inventory(manifest, channels, repo_root=repo_root, home=home, team_config=team_config)
    _print_domain_result(manifest, "knowledge")

    print("[generator] Domain 5: claude ...", flush=True)
    domain_claude.inventory(manifest, channels, home=home, team_config=team_config)
    _print_domain_result(manifest, "claude")

    # XACA-0496-012: Dedupe cross-domain duplicates. A file that's claimed by both
    # git_repo (broad sweep) and a more-specific domain (e.g. knowledge) used to
    # land in the manifest twice, producing a zipfile.UserWarning at package time.
    # Priority: most-specific wins. The broader git_repo is the fallback.
    removed = _dedupe_cross_domain(manifest)
    if removed:
        print(f"[generator] Deduped {removed} cross-domain duplicate entries.", flush=True)

    # Self-include: add a manifest entry for the manifest file itself.
    # XACA-0496-013: Skip the self-entry when --output is outside $HOME (typically
    # a temp file path like /tmp/foo). Such a path won't resolve to a portable
    # relpath, and the verifier — which checks files at the destination $HOME —
    # would always report a spurious FAIL because the temp file is gone by then.
    try:
        out.relative_to(home)
        out_under_home = True
    except ValueError:
        out_under_home = False

    if out_under_home:
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
    else:
        print(f"[generator] Skipping self-entry — output {out} is outside HOME {home} "
              f"(temp/CI path; would produce a spurious FAIL on verify).", flush=True)

    manifest.recompute_channel_stats()
    gaps = manifest.collect_untagged()
    missing_roots = manifest.collect_missing_roots()

    out.write_text(manifest.to_json(), encoding="utf-8")
    total = sum(len(d.files) for d in manifest.domains.values())
    print(f"\n[generator] Wrote {out} — {total} entries across {len(manifest.domains)} domains", flush=True)

    # Emit the pre-export checklist alongside the manifest.
    # XACA-0490: Skip when --output is outside $HOME (temp/CI path — same guard as self-entry above).
    # checklist_path was computed earlier (alongside skip_paths) so domain_git would
    # skip a prior run's checklist; re-use it here rather than recomputing.
    if out_under_home:
        emit_pre_export_checklist(manifest, team_config, out, checklist_path)
        print(f"[generator] Wrote {checklist_path}", flush=True)
    else:
        print(
            f"[generator] Skipping PRE_EXPORT_CHECKLIST.md emit — output {out} outside HOME "
            f"(temp/CI path).",
            flush=True,
        )

    print("\n=== CHANNEL STATS ===", flush=True)
    for ch in manifest.channels:
        s = manifest.channel_stats.get(ch, {"file_count": 0, "total_bytes": 0})
        print(f"  {ch:18s} {s['file_count']:>5d} files  {s['total_bytes']:>12,d} bytes", flush=True)

    # XACA-0954: missing-roots section prints BEFORE untagged gaps. An unscanned
    # root is the more severe condition — it means files were never even reached
    # by the scan, vs. untagged gaps which were reached but couldn't be routed.
    if missing_roots:
        print(f"\n=== x MISSING DOMAIN ROOTS ({len(missing_roots)}) ===", flush=True)
        for r in missing_roots:
            domain = r.get("domain", "?")
            path = r.get("path", "?")
            config_key = r.get("config_key") or "(unspecified)"
            reason = r.get("reason", "")
            print(f"  [{domain}] config_key={config_key}  path={path}", flush=True)
            print(f"      reason: {reason}", flush=True)
        print(
            "\nThese roots are configured in the team YAML but do not exist on this machine.\n"
            "The domain scan never reached them, so their files are ABSENT from this manifest\n"
            "— not counted as untagged, not counted anywhere. Fix the path for the config_key(s)\n"
            "above (or correct/remove the stale entry) in the team config, then re-run the\n"
            "generator before treating this export as complete.",
            flush=True,
        )

    if gaps:
        print(f"\n=== x UNTAGGED GAPS ({len(gaps)}) ===", flush=True)
        for g in gaps[:25]:
            print(f"  {g}", flush=True)
        if len(gaps) > 25:
            print(f"  ... and {len(gaps) - 25} more", flush=True)
        print("\nAdd matching rules to the 'overrides:' section of your team config and re-run.", flush=True)

    # THE CORE FIX (XACA-0954): the all-clear line must never print over an
    # unscanned root. collect_untagged() only counts files the scan actually
    # reached — a root that was never walked contributes zero untagged files
    # and used to read as perfect coverage. Print everything above first, THEN
    # decide what the summary line says and what the exit code is — an early
    # return here would skip whichever section renders second.
    if not gaps and not missing_roots:
        print("\n[generator] Zero untagged gaps — all files have a transfer channel.", flush=True)
    elif missing_roots:
        print(
            "\n[generator] NOT CLEAR TO EXPORT — missing domain root(s) above. This manifest is "
            "INCOMPLETE, not clean: a domain showing 0 (or few) files here may mean its root was "
            "never scanned, not that it was scanned and found empty. Do not export until resolved "
            "or explicitly waived with --allow-missing-roots.",
            flush=True,
        )
    # else: gaps-only case already has its own remediation text printed above.

    exit_code = 0
    # Two independent failure classes with two independent opt-outs. Tolerating
    # one (--allow-untagged) is not consent for the other — see the flag help text.
    if gaps and not args.allow_untagged:
        exit_code = 1
    if missing_roots and not args.allow_missing_roots:
        exit_code = 1
    return exit_code


def _empty():
    from .manifest import DomainBlock
    return DomainBlock()


def _print_domain_result(manifest: "Manifest", domain: str) -> None:
    """Print the '-> N files' progress line for a domain, plus a terse flag if
    that domain just recorded a missing root (XACA-0954). Without this, the
    only sign of trouble was a summary section 40+ lines later — this puts it
    right where the scan happened, in real time.
    """
    n = len(manifest.domains.get(domain, _empty()).files)
    mr = [r for r in manifest.missing_roots if r.get("domain") == domain]
    if mr:
        paths = ", ".join(r.get("path", "?") for r in mr)
        print(f"  -> {n} files  [!! MISSING ROOT x{len(mr)}: {paths}]", flush=True)
    else:
        print(f"  -> {n} files", flush=True)


def _dedupe_cross_domain(manifest) -> int:
    """Remove duplicate file entries that appear in multiple domains.

    Priority (most-specific first): claude > knowledge > kanban > devteam > git_repo.
    A file path seen first in the higher-priority domain is kept; later entries
    for the same path in lower-priority domains are dropped. Same-domain
    duplicates (rare) are also collapsed to the first occurrence.

    Returns the count of duplicates removed.
    """
    priority = ["claude", "knowledge", "kanban", "devteam", "git_repo"]
    seen: set[str] = set()
    removed = 0

    # Domains the caller created but that aren't in the priority list (forward-
    # compat for future domain modules) are processed last in alphabetical order.
    ordered = priority + sorted(d for d in manifest.domains if d not in priority)
    for domain in ordered:
        dblock = manifest.domains.get(domain)
        if not dblock:
            continue
        kept = []
        for fe in dblock.files:
            if fe.path in seen:
                removed += 1
                continue
            seen.add(fe.path)
            kept.append(fe)
        dblock.files = kept

    return removed


if __name__ == "__main__":
    sys.exit(main())
