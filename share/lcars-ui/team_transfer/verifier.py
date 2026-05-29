"""Audit verifier CLI — stdlib-only.

  PYTHONPATH=lcars-ui python3 -m team_transfer.verifier --manifest migration-manifest.json

Runs on the destination machine BEFORE .venv is rebuilt. Imports nothing outside the
Python standard library.

Board filename detection: the verifier no longer hardcodes 'finance-personal-board.json'.
Instead it uses the file extension (.json) and the presence of a 'item_ids' key in the
probe payload to identify board entries — this works regardless of team.

Canonical layouts — path translation across machine types:

  The manifests are generated on whichever machine the user has run the manifest tool on
  (often M3Pro, the dev source-of-truth, but could be any user machine). The verifier then
  runs on the destination machine to audit whether the transferred files exist and match.
  These two machines have different directory layouts:

    M3Pro (dev source of truth):
      ~/dev-team/<team>/...               team-specific work (monorepo)
      ~/dev-team/lcars-ui/...             shared LCARS UI
      ~/dev-team/kanban/...               shared kanban infra
      ~/<team>/...                        optional personal/team data (e.g., ~/finance/)

    User machine (AITeamForge tap install):
      ~/aiteamforge/<team>/...            team work (equivalent to dev-team/<team>/)
      ~/aiteamforge/lcars-ui/...          shared LCARS UI
      ~/aiteamforge/kanban/...            shared kanban infra
      ~/<team>/personal/personas/...      personas (nested under in-project personal dir)

  When a manifest generated on M3Pro is verified on a user machine, absolute paths like
  /Users/developer/dev-team/finance/catalog.json do not exist at that literal path (user
  machine has ~/aiteamforge/finance/ instead). The --path-map flag bridges this gap.

  Example: A manifest from M3Pro (user 'developer', finance team) verified on user machine
  (user 'alice'). Two mappings are needed — one for the team data, one for personas:

    --path-map /Users/developer/dev-team=/Users/alice/aiteamforge \
    --path-map /Users/developer/finance/personal/personas=/Users/alice/finance/personal/personas

  The verifier applies mappings in order; the first match wins. If no mapping matches but
  the source and destination homes differ, the verifier falls back to simple home-prefix
  rewriting (src_home → dst_home). This handles the common case where the username changes
  but the relative directory structure is preserved.

Skipped channels (XACA-0581):

  The aiteamforge_product channel (installer-owned files: personas, terminal logos,
  zshrc profiles, team logos) is SKIPPED, not checked. On a tap install the destination
  lays these files down with its own directory layout — personas at
  ~/aiteamforge/<team>/personas/agents/*.md, the team logo at
  ~/aiteamforge/<team>/personas/avatars/<logo>.png — which differs structurally from the
  source (~/<team>/.claude/agents/* flattened, ~/dev-team/<team>/<logo>.png). They are not
  part of the migration transfer payload, so a flat prefix path-map cannot bridge the
  subdirectory reshape; FAILing on them is a false negative. Persona copies additionally
  carry a .synced-from-master marker (regenerated on the destination by kb-sync-personas).
  See _SKIP_CHANNELS below.

Phases and absent-file dispositions (XACA-0583):

  --phase {pre-import, post-restore}  (default: post-restore — legacy behavior)

  A file present in the manifest but absent on the destination is one of three things,
  and only one is a failure:

    EXPECTED-MISSING  Machine-local / ephemeral state (Claude session transcripts under
                      .claude/projects/*.jsonl). Per-machine; will NEVER match across
                      machines. Reported in ANY phase; never a FAIL. See _EPHEMERAL_GLOBS.
    PENDING-IMPORT    Carried payload (a real transfer channel) absent during a PRE-IMPORT
                      audit. The import will create it; FAILing here is a false negative
                      that makes the pre-import preflight untrustworthy. PRE-IMPORT only.
    FAIL              Carried payload absent POST-RESTORE — the import should have placed
                      it. This is the legacy "missing on destination" failure.

  Only FAIL sets the process exit code. A pre-import audit whose only absences are
  pending-import + expected-missing reports an honest EXIT 0.
"""
from __future__ import annotations

import argparse
import fnmatch
import os
import sys
from collections import defaultdict
from pathlib import Path

# stdlib-only imports above; the package modules below are also stdlib-only.
from .channels import AITEAMFORGE_PRODUCT, ALL_CHANNELS, ICLOUD_EXCLUDED
from .checksum import sha256_file
from .db_integrity import compare_probes, probe_db
from .manifest import EXACT, Manifest, PRESENT, SCHEMA


PASS, WARN, FAIL = "PASS", "WARN", "FAIL"
# XACA-0583: two informational dispositions for files that are absent on the
# destination but are NOT failures. Neither sets the process exit code.
#   - PENDING_IMPORT: a carried-payload entry (real transfer channel) that is absent
#     during a PRE-IMPORT audit. The import will create it; reporting FAIL here is a
#     false negative that makes the pre-import preflight untrustworthy. Becomes a
#     genuine FAIL in the POST-RESTORE phase (the import should have placed it).
#   - EXPECTED_MISSING: a machine-local / ephemeral file (e.g. per-machine Claude
#     session transcripts) that will NEVER match cross-machine. Expected-missing in
#     ANY phase — same class of false negative the XACA-0581 skip-channels eliminated.
PENDING_IMPORT, EXPECTED_MISSING = "PENDING-IMPORT", "EXPECTED-MISSING"
# XACA-0586: STALE_OK — a present-but-mismatched (EXACT sha differs, or SCHEMA board
# behind source) carried payload in PRE-IMPORT phase. The overwrite-import will refresh
# the file; reporting FAIL here is a false negative that blocks apply unnecessarily.
# Like PENDING_IMPORT this is informational: never sets the exit code, never folds into
# overall_state/FAIL. POST-RESTORE keeps the prior FAIL semantics (an import should have
# placed the correct content).
STALE_OK = "STALE-OK"

# Execution phases. Default is post-restore so existing callers (and the server's
# import-side verifier call) keep today's behavior with no change.
PRE_IMPORT, POST_RESTORE = "pre-import", "post-restore"

# Ephemeral / machine-local path globs (matched against the manifest relpath, which is
# relative-to-home). A carried file matching one of these is treated as EXPECTED_MISSING
# when absent, regardless of phase — it is per-machine state that cannot round-trip.
#   - .claude/projects/*.jsonl: Claude session transcripts (per-machine UUID-named).
# fnmatch '*' spans '/', so the glob matches nested UUID-dir layouts too.
# Extend this tuple (or the external override mechanism) for additional machine-local
# files; finance.db is intentionally NOT listed here pending the per-file field audit
# (XACA-0583 plan §3.2 / §6).
_EPHEMERAL_GLOBS = (
    ".claude/projects/*.jsonl",
)


def _is_ephemeral(fe) -> bool:
    """True if the entry is machine-local state that legitimately cannot exist here."""
    rel = getattr(fe, "relpath", "") or ""
    return any(fnmatch.fnmatchcase(rel, g) for g in _EPHEMERAL_GLOBS)

# Channels skipped entirely by the import preflight (counted as "skipped", never
# PASS/WARN/FAIL).
#   - icloud_excluded: not part of the transfer payload by design.
#   - aiteamforge_product (XACA-0581): installer-owned files. The tap install lays
#     these down on the destination with its OWN directory layout (e.g.
#     ~/aiteamforge/<team>/personas/agents/*.md, personas/avatars/<logo>.png), which
#     differs structurally from the source layout (~/<team>/.claude/agents/* flattened,
#     ~/dev-team/<team>/<logo>.png). They are NOT carried by the migration transfer, so
#     a flat prefix path-map cannot resolve them and FAILing on them is a false negative.
#     Persona copies additionally carry a .synced-from-master marker — regenerated on the
#     destination by kb-sync-personas. Their integrity is the installer's responsibility,
#     not the migration verifier's.
_SKIP_CHANNELS = frozenset({ICLOUD_EXCLUDED, AITEAMFORGE_PRODUCT})

# Per-channel cls invariants (ADR §3.2).
# Keys are channel names; values are the *allowed* cls values for entries in that channel.
# Channels absent from this dict have no enforced constraint (git, secrets_export,
# icloud_excluded vary by per-entry logic and carry no blanket restriction).
_CHANNEL_CLASS_INVARIANTS: dict[str, frozenset[str]] = {
    # NOTE: aiteamforge_product has no entry here on purpose (XACA-0581). The channel
    # is now skipped entirely (see _SKIP_CHANNELS) before _check_one runs, so any
    # invariant listed here would be dead code. Do not re-add it.
    # user_state is intentionally mixed: EXACT for authored memory/knowledge,
    # PRESENT for ephemeral session logs.
    "user_state": frozenset({"exact", "present"}),
    # export_kanban allows exact for authored content (EPIC-*.md, retros, plan docs),
    # present for lock files, schema for the board JSON.
    "export_kanban": frozenset({"exact", "present", "schema"}),
    "export_database": frozenset({"schema"}),
}


def _check_channel_class_invariant(fe) -> tuple[str, str] | None:
    """Return (FAIL, message) if fe.cls violates the per-channel invariant; else None.

    Runs before SHA/SCHEMA validation so misclassified entries fail fast with a clear
    message rather than producing confusing sha256-mismatch reports downstream.
    """
    allowed = _CHANNEL_CLASS_INVARIANTS.get(fe.channel)
    if allowed is None:
        return None  # no constraint for this channel
    # cls is stored lowercase in the manifest (see manifest.py constants).
    if fe.cls not in allowed:
        allowed_str = " | ".join(sorted(allowed))
        return FAIL, (
            f"channel-class invariant violated: channel={fe.channel!r} "
            f"requires cls in {{{allowed_str}}}, got {fe.cls!r}"
        )
    return None


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Verify a migration manifest against the destination filesystem.")
    ap.add_argument("--manifest", "-m", required=True, help="Path to manifest JSON.")
    ap.add_argument("--quiet", action="store_true", help="Only print summary + failures.")
    ap.add_argument("--max-fail-display", type=int, default=50)
    ap.add_argument(
        "--phase",
        choices=[PRE_IMPORT, POST_RESTORE],
        default=POST_RESTORE,
        help=(
            "Execution phase (XACA-0583). 'post-restore' (default) is the legacy "
            "behavior: a carried-payload file absent on the destination is a FAIL. "
            "'pre-import' treats carried-payload-absent as PENDING-IMPORT (informational) "
            "— the import will create it — so a pre-import audit reports an honest "
            "0-FAIL when the only 'missing' files are pending-import or expected-missing."
        ),
    )
    ap.add_argument(
        "--path-map",
        action="append",
        default=[],
        metavar="SRC=DST",
        help=(
            "Prefix rewrite applied before any filesystem check. "
            "Format: SRC=DST where SRC is the path prefix on the source machine "
            "and DST is the corresponding prefix on the destination machine. "
            "May be specified multiple times; mappings are applied in order, "
            "first match wins."
        ),
    )
    args = ap.parse_args(argv)

    # Parse --path-map values into (src, dst) tuples.
    path_maps: list[tuple[str, str]] = []
    for raw in args.path_map:
        if "=" not in raw:
            print(
                f"[verifier] ERROR: --path-map value {raw!r} must be in SRC=DST format.",
                file=sys.stderr,
            )
            return 2
        src_prefix, dst_prefix = raw.split("=", 1)
        # Normalize: strip trailing slash so /foo/=/bar and /foo=/bar behave identically.
        path_maps.append((src_prefix.rstrip("/"), dst_prefix.rstrip("/")))

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
    overall = {PASS: 0, WARN: 0, FAIL: 0, PENDING_IMPORT: 0, EXPECTED_MISSING: 0, STALE_OK: 0}
    _zero = lambda: {PASS: 0, WARN: 0, FAIL: 0, PENDING_IMPORT: 0, EXPECTED_MISSING: 0, STALE_OK: 0, "skipped": 0}
    by_channel: dict[str, dict[str, int]] = defaultdict(_zero)
    by_domain: dict[str, dict[str, int]] = defaultdict(_zero)
    failures: list[str] = []
    warnings: list[str] = []
    pending: list[str] = []
    stale: list[str] = []

    for dname, dblock in manifest.domains.items():
        for fe in dblock.files:
            # Skipped channels (icloud_excluded, aiteamforge_product): not part of
            # the migration transfer payload — counted as skipped, never checked.
            if fe.channel in _SKIP_CHANNELS:
                by_channel[fe.channel]["skipped"] += 1
                by_domain[dname]["skipped"] += 1
                continue

            # Resolve destination path: apply --path-map rewrites first (first-match-wins),
            # then fall back to home-prefix rewrite if no mapping matched.
            dst_path_str = fe.path
            _mapped = False
            for _src, _dst in path_maps:
                if dst_path_str.startswith(_src):
                    dst_path_str = _dst + dst_path_str[len(_src):]
                    _mapped = True
                    break
            if not _mapped and rewrite and dst_path_str.startswith(src_home):
                dst_path_str = dst_home + dst_path_str[len(src_home):]
            dst_path = Path(dst_path_str)

            verdict, msg = _check_one(fe, dst_path, args.phase)
            overall[verdict] += 1
            by_channel[fe.channel][verdict] += 1
            by_domain[dname][verdict] += 1
            if verdict == FAIL:
                failures.append(f"  [FAIL] {dst_path}: {msg}")
            elif verdict == WARN:
                warnings.append(f"  [WARN] {dst_path}: {msg}")
            elif verdict == PENDING_IMPORT:
                pending.append(f"  [PENDING-IMPORT] {dst_path}: {msg}")
            elif verdict == STALE_OK:
                stale.append(f"  [STALE-OK] {dst_path}: {msg}")
            elif verdict == PASS and not args.quiet:
                pass  # don't spam PASS lines

    # Report
    print("=" * 72)
    print("MIGRATION AUDIT VERIFIER")
    print("=" * 72)
    print(f"Manifest: {args.manifest}")
    print(f"Source : {manifest.source_user}@{manifest.source_hostname} (HOME={src_home})")
    print(f"Dest   : {os.environ.get('USER','?')}@{os.uname().nodename} (HOME={dst_home})")
    if rewrite or path_maps:
        print("=== ACTIVE REWRITES ===")
        if rewrite:
            print(f"  home-prefix: {src_home} -> {dst_home}")
        for _src, _dst in path_maps:
            print(f"  path-map:    {_src} -> {_dst}")
        print()

    print(f"Phase  : {args.phase}")
    print("=== PER-CHANNEL ===")
    for ch in manifest.channels or list(by_channel.keys()):
        c = by_channel.get(ch) or _zero()
        marker = "v" if c[FAIL] == 0 else "x"
        print(f"  {marker} {ch:18s} PASS:{c[PASS]:5d}  WARN:{c[WARN]:4d}  FAIL:{c[FAIL]:4d}  "
              f"PENDING:{c[PENDING_IMPORT]:4d}  EXP-MISS:{c[EXPECTED_MISSING]:4d}  "
              f"STALE-OK:{c[STALE_OK]:4d}  skipped:{c['skipped']:4d}")

    print()
    print("=== PER-DOMAIN ===")
    for dname in sorted(by_domain):
        c = by_domain[dname]
        marker = "v" if c[FAIL] == 0 else "x"
        print(f"  {marker} {dname:14s} PASS:{c[PASS]:5d}  WARN:{c[WARN]:4d}  FAIL:{c[FAIL]:4d}  "
              f"PENDING:{c[PENDING_IMPORT]:4d}  EXP-MISS:{c[EXPECTED_MISSING]:4d}  "
              f"STALE-OK:{c[STALE_OK]:4d}  skipped:{c['skipped']:4d}")

    if warnings:
        print()
        print(f"=== WARNINGS ({len(warnings)}) ===")
        for w in warnings[: args.max_fail_display]:
            print(w)
        if len(warnings) > args.max_fail_display:
            print(f"  ... and {len(warnings) - args.max_fail_display} more")

    if pending:
        print()
        print(f"=== PENDING-IMPORT ({len(pending)}) — carried payload the import will create ===")
        for pline in pending[: args.max_fail_display]:
            print(pline)
        if len(pending) > args.max_fail_display:
            print(f"  ... and {len(pending) - args.max_fail_display} more")

    if stale:
        print()
        print(f"=== STALE-OK ({len(stale)}) — present-but-stale payload; overwrite-import will refresh ===")
        for sline in stale[: args.max_fail_display]:
            print(sline)
        if len(stale) > args.max_fail_display:
            print(f"  ... and {len(stale) - args.max_fail_display} more")

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
    print(f"  PENDING-IMPORT: {overall[PENDING_IMPORT]}")
    print(f"  EXPECTED-MISSING: {overall[EXPECTED_MISSING]}")
    print(f"  STALE-OK: {overall[STALE_OK]}")

    if manifest.untagged_gaps:
        print(f"\n  Warning: Manifest itself reports {len(manifest.untagged_gaps)} untagged gaps from generation.")

    exit_code = 1 if overall[FAIL] else 0
    print(f"  EXIT: {exit_code}")
    return exit_code


def _check_one(fe, dst_path: Path, phase: str = POST_RESTORE) -> tuple[str, str]:
    # Enforce per-channel cls invariants early — misclassified entries fail fast with
    # a clear channel-class message rather than producing confusing SHA-mismatch reports.
    # A misclassification is a real defect, so it FAILs even pre-import (not "pending").
    inv = _check_channel_class_invariant(fe)
    if inv is not None:
        return inv

    if not dst_path.exists():
        # XACA-0583: three distinct kinds of "absent" — only one is a failure.
        #   1. Ephemeral / machine-local (session transcripts): will NEVER exist here.
        #   2. Carried payload absent during a PRE-IMPORT audit: the import will create
        #      it — reporting FAIL is a false negative. (Skip-channels never reach here;
        #      they are filtered before _check_one, so any entry here is real payload.)
        #   3. Carried payload absent POST-RESTORE: the import should have placed it → FAIL.
        if _is_ephemeral(fe):
            return EXPECTED_MISSING, "machine-local/ephemeral; expected-missing cross-machine"
        if phase == PRE_IMPORT:
            return PENDING_IMPORT, "carried payload absent pre-import; the import will create it"
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
            if phase == PRE_IMPORT:
                return STALE_OK, f"sha differs pre-import; overwrite-import will refresh (manifest={fe.size} disk={st.st_size})"
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
            return _verify_board_schema(fe, dst_path, phase)
        # Unknown schema-class — fall back to existence check.
        return PASS, ""

    return WARN, f"unknown class {fe.cls!r}"


def _verify_board_schema(fe, dst_path: Path, phase: str = POST_RESTORE) -> tuple[str, str]:
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

    missing = cap_ids - cur_ids   # destination BEHIND source — normal staleness
    extra   = cur_ids - cap_ids   # destination-only items — overwrite would DELETE → DATA-LOSS

    if extra:
        # DATA-LOSS blocks in EVERY phase: an overwrite-import deletes these
        # destination-only items. Message starts with "DATA-LOSS:" so it is
        # distinguishable in the failures/tail list.
        return FAIL, f"DATA-LOSS: destination board has {len(extra)} item(s) absent from source; overwrite would DELETE: {sorted(extra)[:10]}"
    if missing:
        if phase == PRE_IMPORT:
            return STALE_OK, f"board behind source by {len(missing)} item(s); overwrite-import will add them: {sorted(missing)[:10]}"
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
