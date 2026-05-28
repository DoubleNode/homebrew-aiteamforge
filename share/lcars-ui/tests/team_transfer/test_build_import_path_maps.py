"""XACA-0580: Regression tests for build_import_path_maps() — detection broadening
and per-team mapping derivation.

Background
----------
XACA-0579 introduced build_import_path_maps() with a heuristic that detected
tap-install by checking whether any team's working_dir started with ~/aiteamforge/.
This failed for M1Pro layouts where teams live at canonical home paths
(~/finance/personal, ~/academy) even though the machine has the tap installed.

Fix (XACA-0580)
---------------
Tap-install detection now checks for the presence of ~/aiteamforge/ directory
itself OR the ~/aiteamforge/.installed-version sentinel file — independent of
where team working_dirs are located.

Additionally, per-team mappings are now derived from manifest["teams"] (source
layout snapshot) vs local config (destination layout), handling scope-suffix drift.

Test coverage
-------------
1.  test_dev_team_to_dev_team_returns_empty
        Both machines dev-team layout; ~/aiteamforge absent → [].

2.  test_tap_install_detected_by_directory_existence
        ~/aiteamforge/ dir exists → shared-infra mapping emitted.

3.  test_tap_install_detected_by_installed_version_sentinel
        ~/aiteamforge/ not a dir, but .installed-version exists → mapping emitted.
        Asserts the OR branch of detection logic.

4.  test_per_team_mapping_scope_suffix_drift
        Headliner: finance src_wd=/Users/src/finance, dst_wd=/Users/dst/finance/personal.
        Expects both per-team AND shared-infra, sorted longest-src-prefix first.
        (dev-team=19 chars > finance=18 chars → shared-infra sorts first.)

5.  test_per_team_mapping_skips_equal_working_dirs
        src_wd == dst_wd → no per-team mapping, only shared-infra.

6.  test_per_team_mapping_skips_missing_src_or_dst
        Manifest team present but missing from local config → no per-team mapping.

7.  test_per_team_mapping_deduplicates
        Two teams with identical src_wd/dst_wd → one mapping, not two.

8.  test_per_team_mapping_omitted_when_no_tap_install
        ~/aiteamforge absent; rich manifest teams → [] (no detection, no mappings).

9.  test_missing_home_returns_empty
        Manifest with no home key or empty string → [].

10. test_exception_safety
        load_config() raises → [] (never raises itself).
"""
from __future__ import annotations

import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

# ---------------------------------------------------------------------------
# Ensure kanban-hooks/ is importable from this test file.
# conftest.py adds lcars-ui/ to sys.path; we add kanban-hooks/ here.
# ---------------------------------------------------------------------------

LCARS_UI_DIR = Path(__file__).resolve().parents[2]      # lcars-ui/
REPO_ROOT = LCARS_UI_DIR.parent                          # worktree root
KANBAN_HOOKS_DIR = REPO_ROOT / "kanban-hooks"

if str(KANBAN_HOOKS_DIR) not in sys.path:
    sys.path.insert(0, str(KANBAN_HOOKS_DIR))

import aiteamforge_paths as _ap                          # noqa: E402
from aiteamforge_paths import build_import_path_maps     # noqa: E402


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_tap_path_mock(dst_home: str, is_dir: bool = True, sentinel_exists: bool = False):
    """Return a side_effect for Path.is_dir() and Path.exists() that simulates
    tap-install detection for the given dst_home.

    Path.is_dir() returns True only for the aiteamforge dir path.
    Path.exists() returns True only for the .installed-version sentinel path.
    All other paths pass through to the real Path implementation.
    """
    aiteamforge_root = dst_home + "/aiteamforge"
    sentinel_path = aiteamforge_root + "/.installed-version"

    def is_dir_side_effect(self):
        if str(self) == aiteamforge_root:
            return is_dir
        return type(self).is_dir(self)  # real Path.is_dir for other paths

    def exists_side_effect(self):
        if str(self) == sentinel_path:
            return sentinel_exists
        return type(self).exists(self)  # real Path.exists for other paths

    return is_dir_side_effect, exists_side_effect


# ---------------------------------------------------------------------------
# Test 1 — dev-team → dev-team: no tap install → []
# ---------------------------------------------------------------------------

def test_dev_team_to_dev_team_returns_empty():
    """Both src and dst are dev-team monorepos; ~/aiteamforge/ does not exist.
    No path-map needed — verifier's built-in home-prefix rewrite handles it.
    Expects [].
    """
    src_home = "/Users/src"
    dst_home = "/Users/dst"

    mock_config = {
        "teams": {
            "academy": {"working_dir": f"{dst_home}/dev-team/academy"},
            "finance": {"working_dir": f"{dst_home}/dev-team/finance/personal"},
        }
    }

    is_dir_se, exists_se = _make_tap_path_mock(dst_home, is_dir=False, sentinel_exists=False)

    with patch.object(_ap, "load_config", return_value=mock_config), \
         patch("aiteamforge_paths.Path.home", return_value=Path(dst_home)), \
         patch("pathlib.Path.is_dir", is_dir_se), \
         patch("pathlib.Path.exists", exists_se):

        result = build_import_path_maps({"home": src_home, "teams": {"academy": {"working_dir": f"{src_home}/dev-team/academy"}}})

    assert result == [], f"Dev-team dst must return []; got: {result}"


# ---------------------------------------------------------------------------
# Test 2 — tap detected by ~/aiteamforge/ directory existence
# ---------------------------------------------------------------------------

def test_tap_install_detected_by_directory_existence():
    """When ~/aiteamforge/ is a directory, tap-install is detected and the
    shared-infra mapping is emitted: <src_home>/dev-team=<dst_home>/aiteamforge.
    """
    src_home = "/Users/dev"
    dst_home = "/Users/m1pro"

    mock_config = {"teams": {}}

    is_dir_se, exists_se = _make_tap_path_mock(dst_home, is_dir=True, sentinel_exists=False)

    with patch.object(_ap, "load_config", return_value=mock_config), \
         patch("aiteamforge_paths.Path.home", return_value=Path(dst_home)), \
         patch("pathlib.Path.is_dir", is_dir_se), \
         patch("pathlib.Path.exists", exists_se):

        result = build_import_path_maps({"home": src_home})

    expected = f"{src_home}/dev-team={dst_home}/aiteamforge"
    assert result == [expected], (
        f"Expected [{expected!r}]; got: {result}"
    )


# ---------------------------------------------------------------------------
# Test 3 — tap detected by .installed-version sentinel (OR branch)
# ---------------------------------------------------------------------------

def test_tap_install_detected_by_installed_version_sentinel():
    """When ~/aiteamforge/ is NOT a directory but .installed-version exists inside
    it, the OR branch of tap-install detection fires and the mapping is emitted.
    """
    src_home = "/Users/srcuser"
    dst_home = "/Users/tapuser"

    mock_config = {"teams": {}}

    # is_dir=False forces Path(aiteamforge_root).is_dir() → False
    # sentinel_exists=True forces (aiteamforge_dir / ".installed-version").exists() → True
    is_dir_se, exists_se = _make_tap_path_mock(dst_home, is_dir=False, sentinel_exists=True)

    with patch.object(_ap, "load_config", return_value=mock_config), \
         patch("aiteamforge_paths.Path.home", return_value=Path(dst_home)), \
         patch("pathlib.Path.is_dir", is_dir_se), \
         patch("pathlib.Path.exists", exists_se):

        result = build_import_path_maps({"home": src_home})

    expected = f"{src_home}/dev-team={dst_home}/aiteamforge"
    assert result == [expected], (
        f"Sentinel-only detection must emit [{expected!r}]; got: {result}"
    )


# ---------------------------------------------------------------------------
# Test 4 — per-team mapping with scope-suffix drift (headliner)
# ---------------------------------------------------------------------------

def test_per_team_mapping_scope_suffix_drift():
    """Headliner scenario: finance src_wd has no scope suffix; dst_wd has /personal.

    Manifest:  finance working_dir = /Users/src/finance
    Dst config: finance working_dir = /Users/dst/finance/personal

    Sort order (longest src prefix first):
        "/Users/src/dev-team" = 19 chars  → comes first
        "/Users/src/finance"  = 18 chars  → comes second

    Expected output:
        ["/Users/src/dev-team=/Users/dst/aiteamforge",        # shared-infra (19)
         "/Users/src/finance=/Users/dst/finance/personal"]    # per-team (18)
    """
    src_home = "/Users/src"
    dst_home = "/Users/dst"

    manifest = {
        "home": src_home,
        "teams": {
            "finance": {"working_dir": f"{src_home}/finance"},
        },
    }

    mock_config = {
        "teams": {
            "finance": {"working_dir": f"{dst_home}/finance/personal"},
        }
    }

    is_dir_se, exists_se = _make_tap_path_mock(dst_home, is_dir=True, sentinel_exists=False)

    with patch.object(_ap, "load_config", return_value=mock_config), \
         patch("aiteamforge_paths.Path.home", return_value=Path(dst_home)), \
         patch("pathlib.Path.is_dir", is_dir_se), \
         patch("pathlib.Path.exists", exists_se):

        result = build_import_path_maps(manifest)

    # Sort check: "/Users/src/dev-team" (19 chars) > "/Users/src/finance" (18 chars)
    # so shared-infra comes first in the longest-prefix-first sort.
    expected = [
        f"{src_home}/dev-team={dst_home}/aiteamforge",        # shared-infra, longer src (19)
        f"{src_home}/finance={dst_home}/finance/personal",   # per-team, shorter src (18)
    ]
    assert result == expected, (
        f"Scope-suffix drift must produce:\n  {expected}\ngot:\n  {result}"
    )


# ---------------------------------------------------------------------------
# Test 5 — per-team mapping skips equal working_dirs
# ---------------------------------------------------------------------------

def test_per_team_mapping_skips_equal_working_dirs():
    """When manifest team and local config team have the same working_dir,
    no per-team mapping is emitted — only the shared-infra mapping.
    """
    src_home = "/Users/src"
    dst_home = "/Users/dst"

    # Teams have same path in src manifest and dst config → skip
    shared_wd = f"{dst_home}/finance/personal"

    manifest = {
        "home": src_home,
        "teams": {
            "finance": {"working_dir": shared_wd},
        },
    }

    mock_config = {
        "teams": {
            "finance": {"working_dir": shared_wd},
        }
    }

    is_dir_se, exists_se = _make_tap_path_mock(dst_home, is_dir=True, sentinel_exists=False)

    with patch.object(_ap, "load_config", return_value=mock_config), \
         patch("aiteamforge_paths.Path.home", return_value=Path(dst_home)), \
         patch("pathlib.Path.is_dir", is_dir_se), \
         patch("pathlib.Path.exists", exists_se):

        result = build_import_path_maps(manifest)

    expected = [f"{src_home}/dev-team={dst_home}/aiteamforge"]
    assert result == expected, (
        f"Equal working_dirs must not produce per-team mapping; got: {result}"
    )


# ---------------------------------------------------------------------------
# Test 6 — per-team mapping skips missing src or dst
# ---------------------------------------------------------------------------

def test_per_team_mapping_skips_missing_src_or_dst():
    """When manifest has a team entry but local config lacks it, no per-team
    mapping is emitted for that team. Only shared-infra mapping returned.
    """
    src_home = "/Users/src"
    dst_home = "/Users/dst"

    manifest = {
        "home": src_home,
        "teams": {
            "finance": {"working_dir": f"{src_home}/finance"},
            "legal": {"working_dir": f"{src_home}/legal"},
        },
    }

    # local config only has finance — legal is absent
    mock_config = {
        "teams": {
            "finance": {"working_dir": f"{dst_home}/finance/personal"},
        }
    }

    is_dir_se, exists_se = _make_tap_path_mock(dst_home, is_dir=True, sentinel_exists=False)

    with patch.object(_ap, "load_config", return_value=mock_config), \
         patch("aiteamforge_paths.Path.home", return_value=Path(dst_home)), \
         patch("pathlib.Path.is_dir", is_dir_se), \
         patch("pathlib.Path.exists", exists_se):

        result = build_import_path_maps(manifest)

    # Sort check: "/Users/src/dev-team" (19) > "/Users/src/finance" (18) > "/Users/src/legal" (16)
    # shared-infra comes first; legal is absent (not in dst config)
    expected_per_team = f"{src_home}/finance={dst_home}/finance/personal"
    expected_infra = f"{src_home}/dev-team={dst_home}/aiteamforge"
    expected = [expected_infra, expected_per_team]  # longest src prefix first
    assert result == expected, (
        f"Missing dst team must be skipped; got: {result}"
    )
    # Confirm no legal mapping present
    assert not any("legal" in m for m in result), (
        f"Legal team mapping must not appear; got: {result}"
    )


# ---------------------------------------------------------------------------
# Test 7 — per-team mapping deduplicates
# ---------------------------------------------------------------------------

def test_per_team_mapping_deduplicates():
    """When two teams produce identical src_wd=dst_wd strings (same paths),
    only one copy appears in the output.
    """
    src_home = "/Users/src"
    dst_home = "/Users/dst"

    # finance-personal and finance-legacy both map to the same directories
    manifest = {
        "home": src_home,
        "teams": {
            "finance-personal": {"working_dir": f"{src_home}/finance"},
            "finance-legacy": {"working_dir": f"{src_home}/finance"},  # same src
        },
    }

    mock_config = {
        "teams": {
            "finance-personal": {"working_dir": f"{dst_home}/finance/personal"},
            "finance-legacy": {"working_dir": f"{dst_home}/finance/personal"},  # same dst
        }
    }

    is_dir_se, exists_se = _make_tap_path_mock(dst_home, is_dir=True, sentinel_exists=False)

    with patch.object(_ap, "load_config", return_value=mock_config), \
         patch("aiteamforge_paths.Path.home", return_value=Path(dst_home)), \
         patch("pathlib.Path.is_dir", is_dir_se), \
         patch("pathlib.Path.exists", exists_se):

        result = build_import_path_maps(manifest)

    # Both teams produce the same mapping string — deduplicated to one
    duplicate_map = f"{src_home}/finance={dst_home}/finance/personal"
    count = result.count(duplicate_map)
    assert count == 1, (
        f"Duplicate mapping must appear exactly once; found {count} times in: {result}"
    )


# ---------------------------------------------------------------------------
# Test 8 — per-team mappings omitted when no tap install
# ---------------------------------------------------------------------------

def test_per_team_mapping_omitted_when_no_tap_install():
    """When ~/aiteamforge/ is absent (not a dir, no sentinel), no tap-install
    is detected. Even rich manifest teams data produces no mappings → [].
    """
    src_home = "/Users/src"
    dst_home = "/Users/dst"

    manifest = {
        "home": src_home,
        "teams": {
            "finance": {"working_dir": f"{src_home}/finance"},
            "academy": {"working_dir": f"{src_home}/dev-team/academy"},
        },
    }

    mock_config = {
        "teams": {
            "finance": {"working_dir": f"{dst_home}/dev-team/finance/personal"},
            "academy": {"working_dir": f"{dst_home}/dev-team/academy"},
        }
    }

    # Neither is_dir nor sentinel exists → tap_install_detected = False
    is_dir_se, exists_se = _make_tap_path_mock(dst_home, is_dir=False, sentinel_exists=False)

    with patch.object(_ap, "load_config", return_value=mock_config), \
         patch("aiteamforge_paths.Path.home", return_value=Path(dst_home)), \
         patch("pathlib.Path.is_dir", is_dir_se), \
         patch("pathlib.Path.exists", exists_se):

        result = build_import_path_maps(manifest)

    assert result == [], (
        f"No tap-install detected → must return []; got: {result}"
    )


# ---------------------------------------------------------------------------
# Test 9 — missing/empty home returns []
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("manifest_arg", [
    {},
    {"home": ""},
    {"home": None},
    {"home": "   "},   # whitespace-only — .strip() drops to "" → early-return
])
def test_missing_home_returns_empty(manifest_arg):
    """Manifests with no home key, empty string, None, or whitespace-only home
    must return [] without raising. Early-return guard in the implementation.

    XACA-0580-012 hardening: implementation calls .strip() before .rstrip("/"),
    so whitespace-only home values collapse to "" and trip the guard. Without
    the .strip(), a real tap-install destination would silently emit a garbage
    path-map with whitespace-prefixed source paths.
    """
    try:
        result = build_import_path_maps(manifest_arg)
    except Exception as exc:  # noqa: BLE001
        pytest.fail(
            f"build_import_path_maps({manifest_arg!r}) raised unexpectedly: {exc!r}"
        )
    assert result == [], f"Expected []; got: {result!r}"


# ---------------------------------------------------------------------------
# Test 11 — src-under-dev-team layout (real M3Pro→M1Pro variant)
# ---------------------------------------------------------------------------

def test_per_team_mapping_src_under_dev_team_root():
    """XACA-0580-013: source machine is dev-team monorepo, so per-team src_wd
    lives UNDER /Users/<src>/dev-team. Destination is tap-install with team
    routed to canonical home path (no /dev-team prefix).

    Manifest:  finance working_dir = /Users/src/dev-team/finance/personal
    Dst config: finance working_dir = /Users/dst/finance/personal

    Both per-team AND shared-infra mappings fire. Sort by src-prefix length
    (longest first) — the per-team src "/Users/src/dev-team/finance/personal"
    is much longer than the shared-infra src "/Users/src/dev-team", so per-team
    sorts first. Verifier first-match-wins will correctly resolve a finance
    file via the per-team mapping (more specific) before the shared-infra one.

    De-dup check: the per-team mapping (43 chars src) and the shared-infra
    mapping (19 chars src) are distinct, so both appear in output.
    """
    src_home = "/Users/src"
    dst_home = "/Users/dst"

    manifest = {
        "home": src_home,
        "teams": {
            "finance": {"working_dir": f"{src_home}/dev-team/finance/personal"},
        },
    }

    mock_config = {
        "teams": {
            "finance": {"working_dir": f"{dst_home}/finance/personal"},
        }
    }

    is_dir_se, exists_se = _make_tap_path_mock(dst_home, is_dir=True, sentinel_exists=False)

    with patch.object(_ap, "load_config", return_value=mock_config), \
         patch("aiteamforge_paths.Path.home", return_value=Path(dst_home)), \
         patch("pathlib.Path.is_dir", is_dir_se), \
         patch("pathlib.Path.exists", exists_se):

        result = build_import_path_maps(manifest)

    # Per-team src is 37 chars ("/Users/src/dev-team/finance/personal"),
    # shared-infra src is 19 chars ("/Users/src/dev-team") — per-team sorts first.
    expected = [
        f"{src_home}/dev-team/finance/personal={dst_home}/finance/personal",  # per-team (longer src)
        f"{src_home}/dev-team={dst_home}/aiteamforge",                        # shared-infra (shorter)
    ]
    assert result == expected, (
        f"src-under-dev-team layout must produce:\n  {expected}\ngot:\n  {result}"
    )
    # Length-sort invariant
    src_lengths = [len(m.split("=", 1)[0]) for m in result]
    assert src_lengths == sorted(src_lengths, reverse=True), (
        f"Mappings not sorted longest-src-first: {src_lengths}"
    )


# ---------------------------------------------------------------------------
# Test 10 — exception safety: load_config() raises → returns []
# ---------------------------------------------------------------------------

def test_exception_safety():
    """When load_config() raises, build_import_path_maps() must catch the
    exception and return [] — never propagate. Server.py calls this at import
    preflight time; an unhandled exception would abort the flow.
    """
    src_home = "/Users/src"
    dst_home = "/Users/dst"

    is_dir_se, exists_se = _make_tap_path_mock(dst_home, is_dir=True, sentinel_exists=False)

    with patch.object(_ap, "load_config", side_effect=RuntimeError("config unavailable")), \
         patch("aiteamforge_paths.Path.home", return_value=Path(dst_home)), \
         patch("pathlib.Path.is_dir", is_dir_se), \
         patch("pathlib.Path.exists", exists_se):

        try:
            result = build_import_path_maps({"home": src_home})
        except Exception as exc:  # noqa: BLE001
            pytest.fail(
                f"build_import_path_maps() raised when load_config() errored: {exc!r}"
            )

    assert result == [], (
        f"Exception in load_config() must produce []; got: {result}"
    )


# ---------------------------------------------------------------------------
# Test 11 — XACA-0581: dev-team-root teams must not emit a colliding per-team map
# ---------------------------------------------------------------------------

def test_dev_team_root_teams_skip_per_team_mapping():
    """Teams whose source working_dir IS the dev-team root (academy, freelance)
    must NOT emit a per-team map. Such a map would be keyed on the same
    ``<src_home>/dev-team`` prefix as shared_infra_map; with an identical prefix
    length the verifier's longest-first sort falls back to stable insertion order,
    and the per-team map (e.g. dev-team -> ~/academy) would shadow / mis-route the
    correct shared-infra map (dev-team -> ~/aiteamforge).

    Reproduces the M1Pro field collision: academy AND freelance both report
    working_dir == ~/dev-team in the manifest teams snapshot.
    """
    src_home = "/Users/src"
    dst_home = "/Users/dst"

    manifest = {
        "home": src_home,
        "teams": {
            "academy": {"working_dir": f"{src_home}/dev-team"},
            "freelance": {"working_dir": f"{src_home}/dev-team"},
            # A normal scope-suffix team to prove non-colliding teams still map.
            "finance": {"working_dir": f"{src_home}/finance"},
        },
    }

    mock_config = {
        "teams": {
            "academy": {"working_dir": f"{dst_home}/academy"},
            "freelance": {"working_dir": f"{dst_home}/freelance"},
            "finance": {"working_dir": f"{dst_home}/finance/personal"},
        }
    }

    is_dir_se, exists_se = _make_tap_path_mock(dst_home, is_dir=True, sentinel_exists=False)

    with patch.object(_ap, "load_config", return_value=mock_config), \
         patch("aiteamforge_paths.Path.home", return_value=Path(dst_home)), \
         patch("pathlib.Path.is_dir", is_dir_se), \
         patch("pathlib.Path.exists", exists_se):

        result = build_import_path_maps(manifest)

    shared_infra = f"{src_home}/dev-team={dst_home}/aiteamforge"
    finance_map = f"{src_home}/finance={dst_home}/finance/personal"

    # Exactly one mapping is keyed on the bare dev-team root — the shared-infra map.
    devteam_keyed = [m for m in result if m.split("=", 1)[0] == f"{src_home}/dev-team"]
    assert devteam_keyed == [shared_infra], (
        "Only the shared-infra map may be keyed on the dev-team root; "
        f"academy/freelance must be skipped. got dev-team-keyed: {devteam_keyed}"
    )
    # The colliding team destinations must never appear.
    assert not any(f"{dst_home}/academy" in m for m in result), f"academy collision present: {result}"
    assert not any(f"{dst_home}/freelance" in m for m in result), f"freelance collision present: {result}"
    # Non-colliding scope-suffix team still maps normally.
    assert finance_map in result, f"finance per-team map missing: {result}"
