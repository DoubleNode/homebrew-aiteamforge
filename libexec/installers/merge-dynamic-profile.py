#!/usr/bin/env python3
"""
merge-dynamic-profile.py — AITeamForge iTerm2 Dynamic Profile merge tool

Usage:
    merge-dynamic-profile.py <source_json> <live_json> [--dry-run]
    merge-dynamic-profile.py --self-test

Merges AITeamForge-owned keys from source into the live iTerm2 Dynamic Profile
file, preserving all user-owned keys. Handles per-Guid merge semantics:

  - Guid in source, not in live  → add profile as-is from source
  - Guid in live, not in source  → keep live profile untouched
  - Guid in both                 → overwrite owned keys from source; keep user keys

Writes atomically: source → .tmp → os.replace. Backs up live before writing.
On --dry-run: writes merged JSON to stdout only; no disk writes.

Exit codes:
  0 = success (or --dry-run success)
  1 = argument error
  2 = JSON parse error
  3 = I/O error
"""

import json
import os
import sys
import tempfile
from datetime import datetime

# ---------------------------------------------------------------------------
# Key ownership — the single source of truth for merge semantics
# ---------------------------------------------------------------------------

AITEAMFORGE_OWNED_KEYS: frozenset = frozenset({
    "Name",
    "Guid",
    "Tags",
    "Custom Command",
    "Mouse Reporting",
    "Dynamic Profile Parent Name",
    "Background Color",
    "Initial URL",
})

# ---------------------------------------------------------------------------
# Core merge logic
# ---------------------------------------------------------------------------

def merge_profiles(source_data: dict, live_data: dict) -> tuple[dict, int, int, int]:
    """
    Merge source profiles into live data in-place (modifies live_data).

    Returns: (merged_data, refreshed_count, added_count, preserved_count)
      - refreshed: profiles present in both — owned keys updated from source
      - added:     profiles in source but not in live — added as-is
      - preserved: profiles in live but not in source — kept untouched (not reported
                   separately in counts; only source-present profiles are counted)
    """
    live_by_guid: dict = {p["Guid"]: p for p in live_data["Profiles"]}

    refreshed = 0
    added = 0

    for src_profile in source_data["Profiles"]:
        guid = src_profile.get("Guid")
        if guid is None:
            print("WARNING: source profile missing Guid — skipped", file=sys.stderr)
            continue

        if guid not in live_by_guid:
            # New profile rule: add as-is from source
            live_data["Profiles"].append(src_profile)
            live_by_guid[guid] = src_profile
            added += 1
        else:
            # Key-level merge: source wins for owned keys
            live_profile = live_by_guid[guid]
            for key, value in src_profile.items():
                if key in AITEAMFORGE_OWNED_KEYS:
                    live_profile[key] = value
                # User-owned keys: leave live value untouched
            refreshed += 1

    # Preserved = live profiles not touched by source iteration
    source_guids = {p["Guid"] for p in source_data["Profiles"] if "Guid" in p}
    preserved = sum(1 for p in live_data["Profiles"] if p.get("Guid") not in source_guids)

    return live_data, refreshed, added, preserved


def parse_profile_file(path: str, label: str) -> dict:
    """Load and validate a profile JSON file. Exits on error."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except json.JSONDecodeError as e:
        print(f"ERROR: {label} file is not valid JSON: {path}", file=sys.stderr)
        print(f"  {e}", file=sys.stderr)
        sys.exit(2)
    except OSError as e:
        print(f"ERROR: Cannot read {label} file: {path}", file=sys.stderr)
        print(f"  {e}", file=sys.stderr)
        sys.exit(3)

    if not isinstance(data, dict) or "Profiles" not in data:
        print(f"ERROR: {label} file is missing top-level 'Profiles' key: {path}", file=sys.stderr)
        sys.exit(2)

    if not isinstance(data["Profiles"], list):
        print(f"ERROR: {label} file 'Profiles' is not an array: {path}", file=sys.stderr)
        sys.exit(2)

    return data


def write_atomically(path: str, data: dict) -> None:
    """Write JSON to path atomically via a temp file + os.replace."""
    dir_name = os.path.dirname(os.path.abspath(path))
    try:
        fd, tmp_path = tempfile.mkstemp(dir=dir_name, suffix=".tmp")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(data, f, indent=4, ensure_ascii=False)
                f.write("\n")
        except Exception:
            os.unlink(tmp_path)
            raise
        os.replace(tmp_path, path)
    except OSError as e:
        print(f"ERROR: Failed to write to {path}", file=sys.stderr)
        print(f"  {e}", file=sys.stderr)
        sys.exit(3)


def backup_live_file(live_path: str) -> str:
    """Copy live file to <live_path>.bak-<timestamp>. Returns backup path."""
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    backup_path = f"{live_path}.bak-{timestamp}"
    try:
        with open(live_path, "r", encoding="utf-8") as src:
            content = src.read()
        with open(backup_path, "w", encoding="utf-8") as dst:
            dst.write(content)
    except OSError as e:
        print(f"ERROR: Failed to create backup at {backup_path}", file=sys.stderr)
        print(f"  {e}", file=sys.stderr)
        sys.exit(3)
    return backup_path


# ---------------------------------------------------------------------------
# Main entrypoint
# ---------------------------------------------------------------------------

def main() -> None:
    args = sys.argv[1:]

    if "--self-test" in args:
        run_self_tests()
        return

    dry_run = "--dry-run" in args
    positional = [a for a in args if not a.startswith("--")]

    if len(positional) != 2:
        print("Usage: merge-dynamic-profile.py <source_json> <live_json> [--dry-run]", file=sys.stderr)
        print("       merge-dynamic-profile.py --self-test", file=sys.stderr)
        sys.exit(1)

    source_path, live_path = positional

    # Validate source file
    source_data = parse_profile_file(source_path, "source")

    # Handle missing live file (fresh install)
    if not os.path.exists(live_path):
        if dry_run:
            print(json.dumps(source_data, indent=4, ensure_ascii=False))
            print()
            return
        write_atomically(live_path, source_data)
        count = len(source_data.get("Profiles", []))
        print(f"Merged {count} profiles: 0 refreshed, {count} added, 0 preserved as-is.",
              file=sys.stderr)
        return

    # Validate live file
    live_data = parse_profile_file(live_path, "live")

    # Run merge
    merged_data, refreshed, added, preserved = merge_profiles(source_data, live_data)

    total = refreshed + added + preserved

    if dry_run:
        print(json.dumps(merged_data, indent=4, ensure_ascii=False))
        print()
        return

    # Backup then write
    backup_path = backup_live_file(live_path)
    write_atomically(live_path, merged_data)

    print(
        f"Merged {total} profiles: {refreshed} refreshed, {added} added, {preserved} preserved as-is.",
        file=sys.stderr,
    )
    print(f"Backup written to: {backup_path}", file=sys.stderr)


# ---------------------------------------------------------------------------
# Self-tests — invoked with --self-test
# ---------------------------------------------------------------------------

def run_self_tests() -> None:
    import traceback

    passed = 0
    failed = 0

    def assert_equal(label: str, actual, expected) -> None:
        nonlocal passed, failed
        if actual == expected:
            print(f"  PASS  {label}")
            passed += 1
        else:
            print(f"  FAIL  {label}")
            print(f"        expected: {expected!r}")
            print(f"        actual:   {actual!r}")
            failed += 1

    def assert_true(label: str, value: bool) -> None:
        assert_equal(label, value, True)

    def write_json(path: str, data: dict) -> None:
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=4, ensure_ascii=False)
            f.write("\n")

    def read_json(path: str) -> dict:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)

    print("Running self-tests for merge-dynamic-profile.py")
    print("=" * 56)

    with tempfile.TemporaryDirectory() as tmpdir:

        # ------------------------------------------------------------------
        # Test 1: Live file missing → source is copied verbatim
        # ------------------------------------------------------------------
        print("\nTest 1: Live file missing → source copied verbatim")

        source_data_1 = {
            "Profiles": [
                {
                    "Guid": "TEST-GUID-0001",
                    "Name": "TestProfile",
                    "Mouse Reporting": True,
                    "Tags": ["aiteamforge"],
                }
            ]
        }
        source_path_1 = os.path.join(tmpdir, "source1.json")
        live_path_1 = os.path.join(tmpdir, "live1.json")  # does not exist yet

        write_json(source_path_1, source_data_1)

        # Simulate main() logic for missing live file
        live_data_result_1 = source_data_1  # fresh install copies source
        write_atomically(live_path_1, live_data_result_1)

        result_1 = read_json(live_path_1)
        assert_equal(
            "profile count matches source",
            len(result_1["Profiles"]),
            len(source_data_1["Profiles"]),
        )
        assert_equal(
            "profile Guid preserved",
            result_1["Profiles"][0]["Guid"],
            "TEST-GUID-0001",
        )
        assert_equal(
            "profile Name preserved",
            result_1["Profiles"][0]["Name"],
            "TestProfile",
        )

        # ------------------------------------------------------------------
        # Test 2: User changed Normal Font + Foreground Color → preserved;
        #         Mouse Reporting gets refreshed from source
        # ------------------------------------------------------------------
        print("\nTest 2: User-owned keys preserved; AITeamForge-owned keys refreshed")

        source_data_2 = {
            "Profiles": [
                {
                    "Guid": "TEST-GUID-0002",
                    "Name": "Agent Panel",
                    "Mouse Reporting": True,
                    "Tags": ["aiteamforge"],
                    "Dynamic Profile Parent Name": "Default",
                }
            ]
        }
        live_data_2 = {
            "Profiles": [
                {
                    "Guid": "TEST-GUID-0002",
                    "Name": "Agent Panel",
                    "Mouse Reporting": False,           # bug — should be refreshed
                    "Normal Font": "JetBrainsMonoNF-Light 9",   # user preference — preserve
                    "Foreground Color": {               # user preference — preserve
                        "Alpha Component": 1.0,
                        "Blue Component": 0.8,
                        "Color Space": "sRGB",
                        "Green Component": 0.9,
                        "Red Component": 1.0,
                    },
                    "Tags": ["aiteamforge"],
                }
            ]
        }

        source_path_2 = os.path.join(tmpdir, "source2.json")
        live_path_2 = os.path.join(tmpdir, "live2.json")
        write_json(source_path_2, source_data_2)
        write_json(live_path_2, live_data_2)

        src = parse_profile_file(source_path_2, "source")
        live = parse_profile_file(live_path_2, "live")
        merged, refreshed, added, preserved = merge_profiles(src, live)

        profile = merged["Profiles"][0]
        assert_equal("Mouse Reporting refreshed to True",  profile.get("Mouse Reporting"), True)
        assert_equal("Normal Font preserved",              profile.get("Normal Font"), "JetBrainsMonoNF-Light 9")
        assert_true( "Foreground Color preserved",         profile.get("Foreground Color") is not None)
        assert_equal("Foreground Color Blue unchanged",    profile["Foreground Color"]["Blue Component"], 0.8)
        assert_equal("Dynamic Profile Parent Name added",  profile.get("Dynamic Profile Parent Name"), "Default")
        assert_equal("refreshed count", refreshed, 1)
        assert_equal("added count",     added, 0)

        # ------------------------------------------------------------------
        # Test 3: Source adds a new Guid not in live → appears in result
        # ------------------------------------------------------------------
        print("\nTest 3: New source Guid not in live → profile added")

        source_data_3 = {
            "Profiles": [
                {"Guid": "EXISTING-GUID", "Name": "Existing",    "Mouse Reporting": True, "Tags": ["aiteamforge"]},
                {"Guid": "NEW-GUID-0003", "Name": "Brand New",   "Mouse Reporting": True, "Tags": ["aiteamforge"]},
            ]
        }
        live_data_3 = {
            "Profiles": [
                {"Guid": "EXISTING-GUID", "Name": "Existing",    "Mouse Reporting": True, "Tags": ["aiteamforge"]},
            ]
        }

        src3 = json.loads(json.dumps(source_data_3))
        live3 = json.loads(json.dumps(live_data_3))
        merged3, refreshed3, added3, preserved3 = merge_profiles(src3, live3)

        result_guids = [p["Guid"] for p in merged3["Profiles"]]
        assert_true( "existing Guid retained",   "EXISTING-GUID" in result_guids)
        assert_true( "new Guid added",            "NEW-GUID-0003" in result_guids)
        assert_equal("total profiles",            len(merged3["Profiles"]), 2)
        assert_equal("added count",               added3, 1)
        assert_equal("refreshed count",           refreshed3, 1)

        # ------------------------------------------------------------------
        # Test 4: Live has a custom Guid not in source → preserved
        # ------------------------------------------------------------------
        print("\nTest 4: Live-only Guid not in source → preserved")

        source_data_4 = {
            "Profiles": [
                {"Guid": "SOURCE-GUID", "Name": "Source Profile", "Tags": ["aiteamforge"]},
            ]
        }
        live_data_4 = {
            "Profiles": [
                {"Guid": "SOURCE-GUID",  "Name": "Source Profile",  "Tags": ["aiteamforge"]},
                {"Guid": "USER-CUSTOM",  "Name": "My Custom Profile"},
            ]
        }

        src4 = json.loads(json.dumps(source_data_4))
        live4 = json.loads(json.dumps(live_data_4))
        merged4, refreshed4, added4, preserved4 = merge_profiles(src4, live4)

        result_guids4 = [p["Guid"] for p in merged4["Profiles"]]
        assert_true( "source Guid retained",     "SOURCE-GUID" in result_guids4)
        assert_true( "user custom Guid retained", "USER-CUSTOM" in result_guids4)
        assert_equal("total profiles",            len(merged4["Profiles"]), 2)
        assert_equal("preserved count",           preserved4, 1)

        # ------------------------------------------------------------------
        # Test 5: Malformed live file → script exits nonzero, no clobber
        # ------------------------------------------------------------------
        print("\nTest 5: Malformed live JSON → exits nonzero, no clobber")

        source_path_5 = os.path.join(tmpdir, "source5.json")
        live_path_5   = os.path.join(tmpdir, "live5.json")
        write_json(source_path_5, {"Profiles": [{"Guid": "X", "Name": "X"}]})

        malformed = '{"Profiles": [{"Guid": "broken"'
        with open(live_path_5, "w") as f:
            f.write(malformed)

        # Capture the before-state of the live file
        with open(live_path_5, "r") as f:
            live_before = f.read()

        # Attempt parse — should raise SystemExit(2)
        caught_exit = None
        try:
            parse_profile_file(live_path_5, "live")
        except SystemExit as e:
            caught_exit = e.code

        assert_equal("exits with code 2 on malformed JSON", caught_exit, 2)

        # Confirm live file was NOT clobbered
        with open(live_path_5, "r") as f:
            live_after = f.read()
        assert_equal("live file content unchanged after parse error", live_after, live_before)

    # ------------------------------------------------------------------
    # Summary
    # ------------------------------------------------------------------
    print()
    print("=" * 56)
    total_tests = passed + failed
    print(f"Results: {passed}/{total_tests} passed", end="")
    if failed:
        print(f"  ({failed} FAILED)")
        sys.exit(1)
    else:
        print()


if __name__ == "__main__":
    main()
