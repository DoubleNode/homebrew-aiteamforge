"""Audit verifier CLI — stdlib-only.

  PYTHONPATH=lcars-ui python3 -m team_transfer.verifier --manifest migration-manifest.json

Runs on the destination machine BEFORE .venv is rebuilt. Imports nothing outside the
Python standard library.

Board filename detection: the verifier no longer hardcodes 'finance-personal-board.json'.
Instead it uses the file extension (.json) and the presence of a 'item_ids' key in the
probe payload to identify board entries — this works regardless of team.
"""
from __future__ import annotations

import argparse
import os
import sys
from collections import defaultdict
from pathlib import Path

# stdlib-only imports above; the package modules below are also stdlib-only.
from .channels import ALL_CHANNELS, ICLOUD_EXCLUDED
from .checksum import sha256_file
from .db_integrity import compare_probes, probe_db
from .manifest import EXACT, Manifest, PRESENT, SCHEMA


PASS, WARN, FAIL = "PASS", "WARN", "FAIL"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Verify a migration manifest against the destination filesystem.")
    ap.add_argument("--manifest", "-m", required=True, help="Path to manifest JSON.")
    ap.add_argument("--quiet", action="store_true", help="Only print summary + failures.")
    ap.add_argument("--max-fail-display", type=int, default=50)
    args = ap.parse_args(argv)

    try:
        text = Path(args.manifest).read_text(encoding="utf-8")
    except FileNotFoundError as e:
        print(f"[verifier] ERROR: manifest not found: {e.filename}", file=sys.stderr)
        return 2
    manifest = Manifest.from_json(text)

    src_home = manifest.home or str(Path.home())
    dst_home = str(Path.home())
    rewrite = src_home != dst_home

    # Counters
    overall = {PASS: 0, WARN: 0, FAIL: 0}
    by_channel: dict[str, dict[str, int]] = defaultdict(lambda: {PASS: 0, WARN: 0, FAIL: 0, "skipped": 0})
    by_domain: dict[str, dict[str, int]] = defaultdict(lambda: {PASS: 0, WARN: 0, FAIL: 0, "skipped": 0})
    failures: list[str] = []
    warnings: list[str] = []

    for dname, dblock in manifest.domains.items():
        for fe in dblock.files:
            # iCloud-excluded entries: silently skip.
            if fe.channel == ICLOUD_EXCLUDED:
                by_channel[fe.channel]["skipped"] += 1
                by_domain[dname]["skipped"] += 1
                continue

            # Resolve destination path: rewrite home if needed.
            dst_path_str = fe.path
            if rewrite and dst_path_str.startswith(src_home):
                dst_path_str = dst_home + dst_path_str[len(src_home):]
            dst_path = Path(dst_path_str)

            verdict, msg = _check_one(fe, dst_path)
            overall[verdict] += 1
            by_channel[fe.channel][verdict] += 1
            by_domain[dname][verdict] += 1
            if verdict == FAIL:
                failures.append(f"  [FAIL] {dst_path}: {msg}")
            elif verdict == WARN:
                warnings.append(f"  [WARN] {dst_path}: {msg}")
            elif verdict == PASS and not args.quiet:
                pass  # don't spam PASS lines

    # Report
    print("=" * 72)
    print("MIGRATION AUDIT VERIFIER")
    print("=" * 72)
    print(f"Manifest: {args.manifest}")
    print(f"Source : {manifest.source_user}@{manifest.source_hostname} (HOME={src_home})")
    print(f"Dest   : {os.environ.get('USER','?')}@{os.uname().nodename} (HOME={dst_home})")
    if rewrite:
        print(f"Note: rewriting paths from {src_home} -> {dst_home}")
    print()

    print("=== PER-CHANNEL ===")
    for ch in manifest.channels or list(by_channel.keys()):
        c = by_channel.get(ch, {PASS: 0, WARN: 0, FAIL: 0, "skipped": 0})
        marker = "v" if c[FAIL] == 0 else "x"
        print(f"  {marker} {ch:18s} PASS:{c[PASS]:5d}  WARN:{c[WARN]:4d}  FAIL:{c[FAIL]:4d}  skipped:{c['skipped']:4d}")

    print()
    print("=== PER-DOMAIN ===")
    for dname in sorted(by_domain):
        c = by_domain[dname]
        marker = "v" if c[FAIL] == 0 else "x"
        print(f"  {marker} {dname:14s} PASS:{c[PASS]:5d}  WARN:{c[WARN]:4d}  FAIL:{c[FAIL]:4d}  skipped:{c['skipped']:4d}")

    if warnings:
        print()
        print(f"=== WARNINGS ({len(warnings)}) ===")
        for w in warnings[: args.max_fail_display]:
            print(w)
        if len(warnings) > args.max_fail_display:
            print(f"  ... and {len(warnings) - args.max_fail_display} more")

    if failures:
        print()
        print(f"=== FAILURES ({len(failures)}) ===")
        for fline in failures[: args.max_fail_display]:
            print(fline)
        if len(failures) > args.max_fail_display:
            print(f"  ... and {len(failures) - args.max_fail_display} more")

    print()
    print(f"=== SUMMARY ===")
    print(f"  PASS: {overall[PASS]}")
    print(f"  WARN: {overall[WARN]}")
    print(f"  FAIL: {overall[FAIL]}")

    if manifest.untagged_gaps:
        print(f"\n  Warning: Manifest itself reports {len(manifest.untagged_gaps)} untagged gaps from generation.")

    exit_code = 1 if overall[FAIL] else 0
    print(f"  EXIT: {exit_code}")
    return exit_code


def _check_one(fe, dst_path: Path) -> tuple[str, str]:
    if not dst_path.exists():
        return FAIL, "missing on destination"

    try:
        st = dst_path.stat()
    except OSError as e:
        return FAIL, f"stat error: {e}"

    if fe.cls == EXACT:
        if not fe.sha256:
            return WARN, "manifest has no sha256 for an exact-class entry"
        if dst_path.is_dir():
            return FAIL, "expected file, found directory"
        try:
            current = sha256_file(dst_path)
        except OSError as e:
            return FAIL, f"hash error: {e}"
        if current != fe.sha256:
            return FAIL, f"sha256 mismatch (size: manifest={fe.size} disk={st.st_size})"
        return PASS, ""

    if fe.cls == PRESENT:
        # Just confirm it exists. Optionally sanity-check size for jsonl/db.
        return PASS, ""

    if fe.cls == SCHEMA:
        # DB files: identified by .db extension.
        if fe.path.endswith(".db"):
            cur = probe_db(dst_path)
            issues = compare_probes(fe.probe or {}, cur)
            if issues:
                return FAIL, "; ".join(issues)
            return PASS, ""
        # Board JSON files: identified by probe payload containing 'item_ids'.
        # This is team-agnostic — no hardcoded filename needed.
        if fe.path.endswith(".json") and fe.probe and "item_ids" in fe.probe:
            return _verify_board_schema(fe, dst_path)
        # Unknown schema-class — fall back to existence check.
        return PASS, ""

    return WARN, f"unknown class {fe.cls!r}"


def _verify_board_schema(fe, dst_path: Path) -> tuple[str, str]:
    import json
    try:
        with open(dst_path, "r", encoding="utf-8") as f:
            board = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        return FAIL, f"board JSON parse error: {e}"
    captured = fe.probe or {}
    cap_ids = set(captured.get("item_ids", []))

    # Recompute current item ids by looking for any string "id" value that matches
    # what was captured. We use the captured ID set as the pattern: if any ID starts
    # with a prefix character sequence, infer the ticket prefix. Fall back to checking
    # all string "id" values if the prefix can't be inferred.
    cur_ids: set[str] = set()
    prefix = _infer_prefix(cap_ids)

    def _walk(o):
        if isinstance(o, dict):
            i = o.get("id")
            if isinstance(i, str) and (not prefix or i.startswith(prefix)):
                cur_ids.add(i)
            for v in o.values():
                _walk(v)
        elif isinstance(o, list):
            for v in o:
                _walk(v)
    _walk(board)

    missing = cap_ids - cur_ids
    if missing:
        return FAIL, f"board missing items: {sorted(missing)[:10]}"
    return PASS, ""


def _infer_prefix(ids: set[str]) -> str:
    """Infer ticket prefix (e.g. 'XFIN-') from a set of IDs. Returns '' if ambiguous."""
    if not ids:
        return ""
    for sample in sorted(ids)[:5]:
        dash = sample.find("-")
        if dash > 0:
            return sample[:dash + 1]
    return ""


if __name__ == "__main__":
    sys.exit(main())
