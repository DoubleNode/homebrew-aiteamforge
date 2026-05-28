"""XACA-0579: Regression tests for domain_claude ghost UUID directory entries.

Background
----------
domain_claude.inventory() used to emit one PRESENT-class FileEntry per UUID-named
subdirectory inside ~/.claude/projects/<project>/ via a `for d in croot.iterdir()`
block (lines 58-73, deleted in XACA-0579-003).  These directory-typed entries could
not round-trip through the file-based zip pipeline: zipfile.write(dir, arcname) stores
arcname/ (trailing slash), but the import loop checks relpath (no slash) → SKIP → dir
never created on the destination.  The pre-flight verifier then reported FAIL for every
such entry because Path.exists() on the destination returned False.

Fix (XACA-0579-003)
-------------------
The iterdir block was deleted entirely.  inventory() now emits only:
  1.  memory/MEMORY.md (and all files under memory/) — cls=EXACT
  2.  *.jsonl session transcripts at the croot level — cls=PRESENT

Subagent transcript directories (<UUID>/subagents/agent-*.jsonl) are intentionally
omitted; they are ephemeral debug content that need not survive migration.

Test coverage in this file
--------------------------
1.  test_inventory_does_not_emit_directory_entries
        Core regression: UUID dirs must produce zero manifest entries.

2.  test_inventory_handles_uuid_dirs_with_jsonl_inside
        Defensive: inner agent-*.jsonl files are also omitted; the outer
        <UUID>.jsonl at root level IS included.

3.  test_inventory_no_uuid_dirs_at_all
        Baseline: no UUID dirs → inventory still works (no crash).

4.  test_build_import_path_maps_returns_empty_for_dev_team_dst
        Same-layout (both dev-team) → empty path-map list.

5.  test_build_import_path_maps_returns_mapping_for_tap_dst
        M1Pro tap-install destination (~/aiteamforge/ dir present) → mapping emitted.
        Updated XACA-0580: detection now uses dir presence, not working_dir prefix.

6.  test_build_import_path_maps_handles_cross_user
        Username differs between source and destination → correct src home used.
        Updated XACA-0580: mock simulates ~/aiteamforge/ dir existence for dst.

7.  test_build_import_path_maps_empty_manifest
        Defensive: empty / missing "home" key → returns [] without raising.

Regression guard (test 1)
-------------------------
If the iterdir block is reintroduced, test 1 fails because UUID-dir path
segments will appear in manifest entries' paths.  Do NOT relax this assertion.
"""
from __future__ import annotations

import sys
import tempfile
from pathlib import Path
from unittest.mock import patch

import pytest

# ---------------------------------------------------------------------------
# Ensure lcars-ui/ and kanban-hooks/ are importable.
# conftest.py already adds lcars-ui/; we add kanban-hooks/ here so that
# build_import_path_maps is importable in all test variants.
# ---------------------------------------------------------------------------

LCARS_UI_DIR = Path(__file__).resolve().parents[2]          # lcars-ui/
REPO_ROOT = LCARS_UI_DIR.parent                              # worktree root
KANBAN_HOOKS_DIR = REPO_ROOT / "kanban-hooks"

if str(KANBAN_HOOKS_DIR) not in sys.path:
    sys.path.insert(0, str(KANBAN_HOOKS_DIR))

# Domain module under test
from team_transfer import domain_claude                       # noqa: E402
from team_transfer.manifest import Manifest, EXACT, PRESENT  # noqa: E402
from team_transfer.channels import ChannelConfig             # noqa: E402

# Path-map helper under test
import aiteamforge_paths as _ap                              # noqa: E402
from aiteamforge_paths import build_import_path_maps         # noqa: E402


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_manifest() -> Manifest:
    return Manifest(home="")


def _empty_channel_config() -> ChannelConfig:
    """A ChannelConfig with no rules — everything resolves to UNTAGGED,
    which domain_claude._emit() maps to USER_STATE."""
    return ChannelConfig(rules=[])


def _team_config(tmpdir: Path, project_dir_name: str) -> dict:
    """Minimal team_config dict pointing at *tmpdir* for the claude project root."""
    return {
        "claude_project_dir_name": project_dir_name,
        "home_relative_root": "",  # keep froot pointing at /nonexistent
    }


def _claude_root(tmpdir: Path, project_dir_name: str) -> Path:
    """Returns the path that domain_claude.inventory() will use as croot."""
    return tmpdir / ".claude" / "projects" / project_dir_name


# ---------------------------------------------------------------------------
# Test 1 — Core regression: UUID dirs must NOT appear in the manifest
# ---------------------------------------------------------------------------

def test_inventory_does_not_emit_directory_entries():
    """REGRESSION GUARD (XACA-0579).

    Plant memory/MEMORY.md, root-level *.jsonl files, and several UUID-named
    directories (each containing nested subagents/agent-*.jsonl).  Assert:

      - NO FileEntry has a path matching a UUID directory name.
      - The memory file IS emitted with cls=EXACT.
      - The *.jsonl files at root ARE emitted with cls=PRESENT.
      - NO FileEntry carries probe={"kind": "session_subdir"} (old marker gone).

    If the iterdir block is reintroduced this test will fail because UUID-dir
    path segments will appear in entries' paths.
    """
    uuid_dirs = [
        "add396ed-1902-4c5c-8669-52d351704099",
        "c2f0a120-dead-beef-cafe-0123456789ab",
        "fe0987bb-4000-1234-5678-111111111111",
    ]

    with tempfile.TemporaryDirectory(prefix="xaca0579_test1_") as tmp_str:
        tmpdir = Path(tmp_str)

        project_dir = "test-project"
        croot = _claude_root(tmpdir, project_dir)
        croot.mkdir(parents=True)

        # Plant memory/MEMORY.md (should appear as EXACT)
        mem_dir = croot / "memory"
        mem_dir.mkdir()
        memory_file = mem_dir / "MEMORY.md"
        memory_file.write_text("# Test memory\nSome content.\n", encoding="utf-8")

        # Plant *.jsonl files at croot (should appear as PRESENT)
        jsonl_files = []
        for i in range(3):
            fname = f"session-{i:04d}.jsonl"
            p = croot / fname
            p.write_text(f'{{"turn": {i}}}\n', encoding="utf-8")
            jsonl_files.append(fname)

        # Plant UUID-named subdirs with nested subagent transcripts
        # These MUST NOT appear in the manifest after the fix.
        for uuid_name in uuid_dirs:
            uuid_dir = croot / uuid_name
            uuid_dir.mkdir()
            subagents_dir = uuid_dir / "subagents"
            subagents_dir.mkdir()
            (subagents_dir / "agent-000.jsonl").write_text(
                '{"role": "subagent"}\n', encoding="utf-8"
            )

        manifest = _make_manifest()
        channels = _empty_channel_config()
        tc = _team_config(tmpdir, project_dir)

        domain_claude.inventory(
            manifest, channels,
            home=tmpdir,
            team_config=tc,
        )

        claude_block = manifest.domains.get("claude")
        assert claude_block is not None, "claude domain block must exist after inventory"

        entries = claude_block.files
        entry_paths = [fe.path for fe in entries]

        # No entry path should contain a UUID dir name
        for uuid_name in uuid_dirs:
            for ep in entry_paths:
                assert uuid_name not in ep, (
                    f"UUID dir {uuid_name!r} appeared in manifest entry path {ep!r}. "
                    "The iterdir block must be removed (XACA-0579 regression)."
                )

        # No entry should carry the old probe marker
        for fe in entries:
            assert not (fe.probe and fe.probe.get("kind") == "session_subdir"), (
                f"Old probe marker 'session_subdir' found in entry {fe.path!r}. "
                "This should have been deleted with the iterdir block."
            )

        # Memory file MUST be emitted as EXACT
        exact_paths = [fe.path for fe in entries if fe.cls == EXACT]
        assert any("MEMORY.md" in p for p in exact_paths), (
            f"memory/MEMORY.md must be emitted with cls=EXACT. "
            f"EXACT entries: {exact_paths}"
        )

        # *.jsonl files at croot MUST be emitted as PRESENT
        present_paths = [fe.path for fe in entries if fe.cls == PRESENT]
        for fname in jsonl_files:
            assert any(fname in p for p in present_paths), (
                f"Session file {fname!r} must be emitted with cls=PRESENT. "
                f"PRESENT entries: {present_paths}"
            )


# ---------------------------------------------------------------------------
# Test 2 — Defensive: inner agent-*.jsonl files are also omitted
# ---------------------------------------------------------------------------

def test_inventory_handles_uuid_dirs_with_jsonl_inside():
    """Defensive coverage: agent-*.jsonl inside UUID dirs must NOT appear.

    Additionally, if a <UUID>.jsonl file exists at the croot root level, it
    MUST be included (glob("*.jsonl") picks it up).  The inner
    <UUID>/subagents/agent-abc.jsonl must not appear.
    """
    uuid_str = "dead0000-0000-0000-0000-000000000000"

    with tempfile.TemporaryDirectory(prefix="xaca0579_test2_") as tmp_str:
        tmpdir = Path(tmp_str)

        project_dir = "inner-jsonl-project"
        croot = _claude_root(tmpdir, project_dir)
        croot.mkdir(parents=True)

        # Outer UUID.jsonl at croot level — should be emitted
        outer_jsonl = croot / f"{uuid_str}.jsonl"
        outer_jsonl.write_text('{"session": true}\n', encoding="utf-8")

        # UUID dir with inner agent file — should NOT be emitted at all
        uuid_dir = croot / uuid_str
        uuid_dir.mkdir()
        subagents_dir = uuid_dir / "subagents"
        subagents_dir.mkdir()
        inner_jsonl = subagents_dir / "agent-abc.jsonl"
        inner_jsonl.write_text('{"role": "subagent"}\n', encoding="utf-8")

        manifest = _make_manifest()
        channels = _empty_channel_config()
        tc = _team_config(tmpdir, project_dir)

        domain_claude.inventory(
            manifest, channels,
            home=tmpdir,
            team_config=tc,
        )

        claude_block = manifest.domains.get("claude")
        assert claude_block is not None, "claude domain block must exist"

        entries = claude_block.files
        entry_paths = [fe.path for fe in entries]

        # Inner agent file must NOT appear
        for ep in entry_paths:
            assert "agent-abc.jsonl" not in ep, (
                f"Inner subagent transcript appeared in manifest: {ep!r}. "
                "Subagent transcripts are intentionally omitted (XACA-0579)."
            )

        # The UUID dir itself must NOT appear
        for ep in entry_paths:
            assert str(uuid_dir) not in ep or ep.endswith(".jsonl"), (
                f"UUID directory path appeared as non-jsonl entry: {ep!r}"
            )

        # Outer <UUID>.jsonl at croot MUST appear
        outer_str = str(outer_jsonl)
        assert any(outer_str == ep for ep in entry_paths), (
            f"Outer {uuid_str}.jsonl must be in manifest (it's at croot level). "
            f"All entry paths: {entry_paths}"
        )


# ---------------------------------------------------------------------------
# Test 3 — Baseline: no UUID dirs present; inventory works normally
# ---------------------------------------------------------------------------

def test_inventory_no_uuid_dirs_at_all():
    """Baseline: when no UUID dirs exist, inventory emits memory + jsonl normally.

    Confirms the deleted iterdir block is not load-bearing for the common case.
    """
    with tempfile.TemporaryDirectory(prefix="xaca0579_test3_") as tmp_str:
        tmpdir = Path(tmp_str)

        project_dir = "clean-project"
        croot = _claude_root(tmpdir, project_dir)
        croot.mkdir(parents=True)

        # Only memory + jsonl, no UUID dirs at all
        mem_dir = croot / "memory"
        mem_dir.mkdir()
        (mem_dir / "MEMORY.md").write_text("# Clean\n", encoding="utf-8")

        jsonl_names = ["abc.jsonl", "def.jsonl"]
        for name in jsonl_names:
            (croot / name).write_text("{}\n", encoding="utf-8")

        manifest = _make_manifest()
        channels = _empty_channel_config()
        tc = _team_config(tmpdir, project_dir)

        # Must not raise
        domain_claude.inventory(
            manifest, channels,
            home=tmpdir,
            team_config=tc,
        )

        claude_block = manifest.domains.get("claude")
        assert claude_block is not None

        entries = claude_block.files
        assert len(entries) >= 3, (
            f"Expected at least 3 entries (1 memory file + 2 jsonl); got {len(entries)}. "
            f"Entries: {[fe.path for fe in entries]}"
        )

        # Memory file present as EXACT
        assert any(fe.cls == EXACT and "MEMORY.md" in fe.path for fe in entries), (
            "memory/MEMORY.md not found as EXACT entry."
        )

        # Both jsonl files present as PRESENT
        for name in jsonl_names:
            assert any(fe.cls == PRESENT and name in fe.path for fe in entries), (
                f"{name!r} not found as PRESENT entry."
            )


# ---------------------------------------------------------------------------
# Test 4 — build_import_path_maps: same layout (dev-team dst) → []
# ---------------------------------------------------------------------------

def test_build_import_path_maps_returns_empty_for_dev_team_dst():
    """When destination is a dev-team monorepo (all working_dirs under ~/dev-team/),
    no path-map is needed and the function returns [].
    """
    fake_home = "/Users/testuser"
    mock_config = {
        "schema_version": 1,
        "teams": {
            "academy": {"working_dir": f"{fake_home}/dev-team/academy"},
            "finance": {"working_dir": f"{fake_home}/dev-team/finance/personal"},
        },
    }

    with patch.object(_ap, "load_config", return_value=mock_config), \
         patch("aiteamforge_paths.Path") as mock_path_cls:

        # Make Path.home() return fake_home
        mock_path_cls.home.return_value = Path(fake_home)
        # Passthrough for Path() construction inside the function
        mock_path_cls.side_effect = lambda *args, **kwargs: Path(*args, **kwargs)

        result = build_import_path_maps({"home": fake_home})

    assert result == [], (
        f"Dev-team dst must return empty path-map list; got: {result}"
    )


# ---------------------------------------------------------------------------
# Test 5 — build_import_path_maps: tap-install dst → single mapping
# ---------------------------------------------------------------------------

def test_build_import_path_maps_returns_mapping_for_tap_dst():
    """When destination is a tap install (~/aiteamforge/ exists as a directory),
    the function returns the shared-infra SRC=DST mapping string.

    Concrete case: M3Pro → M1Pro, same username (darrenehlers).

    Updated (XACA-0580): tap-install is now detected by ~/aiteamforge/ directory
    presence, NOT by inspecting team working_dir prefixes. The mock must
    simulate is_dir()=True on the aiteamforge root path.
    """
    fake_home = "/Users/darrenehlers"
    aiteamforge_root = f"{fake_home}/aiteamforge"
    mock_config = {
        "schema_version": 1,
        "teams": {},
    }

    def _is_dir(self):
        if str(self) == aiteamforge_root:
            return True
        return type(self).is_dir(self)

    def _exists(self):
        return type(self).exists(self)

    with patch.object(_ap, "load_config", return_value=mock_config), \
         patch("aiteamforge_paths.Path.home", return_value=Path(fake_home)), \
         patch("pathlib.Path.is_dir", _is_dir), \
         patch("pathlib.Path.exists", _exists):

        result = build_import_path_maps({"home": fake_home})

    expected = f"{fake_home}/dev-team={fake_home}/aiteamforge"
    assert result == [expected], (
        f"Tap-install dst must return [{expected!r}]; got: {result}"
    )


# ---------------------------------------------------------------------------
# Test 6 — build_import_path_maps: cross-user (different src and dst usernames)
# ---------------------------------------------------------------------------

def test_build_import_path_maps_handles_cross_user():
    """When src and dst machines have different usernames, the src prefix
    in the path-map comes from manifest["home"] (the source machine's home),
    while the dst prefix comes from the destination's aiteamforge root.

    Scenario:
      Destination: tap install at /Users/alice/aiteamforge/ (directory exists)
      Source manifest home: /Users/developer
    Expected mapping: /Users/developer/dev-team=/Users/alice/aiteamforge

    Updated (XACA-0580): tap-install now detected by ~/aiteamforge/ dir presence.
    """
    dst_home = "/Users/alice"
    src_home = "/Users/developer"
    aiteamforge_root = f"{dst_home}/aiteamforge"
    mock_config = {
        "schema_version": 1,
        "teams": {},
    }

    def _is_dir(self):
        if str(self) == aiteamforge_root:
            return True
        return type(self).is_dir(self)

    def _exists(self):
        return type(self).exists(self)

    with patch.object(_ap, "load_config", return_value=mock_config), \
         patch("aiteamforge_paths.Path.home", return_value=Path(dst_home)), \
         patch("pathlib.Path.is_dir", _is_dir), \
         patch("pathlib.Path.exists", _exists):

        result = build_import_path_maps({"home": src_home})

    expected = f"{src_home}/dev-team={dst_home}/aiteamforge"
    assert result == [expected], (
        f"Cross-user case must produce [{expected!r}]; got: {result}"
    )


# ---------------------------------------------------------------------------
# Test 7 — build_import_path_maps: defensive (empty/missing manifest)
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("manifest_arg", [
    {},
    {"home": ""},
    {"home": None},
])
def test_build_import_path_maps_empty_manifest(manifest_arg):
    """build_import_path_maps must return [] for empty or malformed manifests,
    never raising.

    Defensive guard: server.py calls this at import preflight time; an exception
    here would bubble up and abort the preflight flow.
    """
    # No mocking needed — load_config may legitimately be called but the early
    # return on empty src_home short-circuits before that.
    try:
        result = build_import_path_maps(manifest_arg)
    except Exception as exc:  # noqa: BLE001
        pytest.fail(
            f"build_import_path_maps({manifest_arg!r}) raised unexpectedly: {exc!r}"
        )

    assert result == [], (
        f"Empty/missing home must return []; got: {result}"
    )
