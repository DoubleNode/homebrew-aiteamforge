"""
Shared pytest configuration for lcars-ui tests.

This directory has no pre-existing conftest.py -- individual test files
bootstrap their own sys.path (see e.g. test_xaca1221_image_roots.py's
"Bootstrap server.py imports" block) and this file does NOT change that;
it adds only the diagnostic below, nothing import-path-related.

XACA-1231-018: loud diagnostic for an uninitialized tap submodule.

QA ran `tests/` and `lcars-ui/tests/` from a worktree whose homebrew-tap
submodule was never `git submodule update --init`-ed and hit confusing
failures/skips scattered across many test files here (a fixture "not
available", a helper script "not found", etc.), each reporting its own
missing-file symptom with no single line explaining the common root cause.
This adds ONE loud, early warning naming the cause and the fix, without
changing what passes/fails/skips -- tests that need the tap still fail or
skip exactly as before; this only makes WHY visible.

tests/conftest.py (the sibling suite at the repo root) carries an identical
(independent, not shared -- "minimal and import-safe" per the ticket) copy
of this same check, because these are two SEPARATE pytest rootdir-adjacent
conftest files with no import path between them, and no reason to build one
for a five-line check.
"""
from pathlib import Path


# ── Git-env scrub: drop INHERITED repository-local git variables ─────────────
#
# With GIT_DIR / GIT_WORK_TREE / GIT_INDEX_FILE exported, git ignores both the
# cwd and an explicit path: a fixture's `git init <tmp>` / `git config user.*`
# / `git commit` (subprocess, cwd=tmp) lands in whatever REAL repo GIT_DIR
# names. That happened to the tap on 2026-09-08 (18 commits authored
# `Sandbox <test@example.com>`). Every test subprocess inherits os.environ,
# so popping the variables here, at conftest import, covers them all.
# Same list and rationale as scripts/tests/lib/git-env-hermetic.sh (the shell
# runners' copy) -- independent, not shared, like the tap-submodule check
# below. tests/conftest.py carries an identical copy; guarded by
# tests/test-git-env-hermetic-runners.sh.
_GIT_LOCAL_ENV_FALLBACK = (
    "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR",
    "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_CONFIG", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT",
    "GIT_IMPLICIT_WORK_TREE", "GIT_GRAFT_FILE", "GIT_NO_REPLACE_OBJECTS",
    "GIT_REPLACE_REF_BASE", "GIT_PREFIX", "GIT_SHALLOW_FILE",
)


def _scrub_inherited_git_env():
    import os
    import subprocess
    names = set(_GIT_LOCAL_ENV_FALLBACK)
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--local-env-vars"],
            capture_output=True, text=True, timeout=10,
        ).stdout
        names.update(out.split())
    except Exception:
        pass  # the fixed fallback list still applies
    for name in names:
        os.environ.pop(name, None)


_scrub_inherited_git_env()

# lcars-ui/tests/conftest.py -> lcars-ui/tests -> lcars-ui -> REPO ROOT.
# homebrew-tap (and .gitmodules) live at the repo root, a sibling of
# lcars-ui/, not under lcars-ui/ itself.
REPO_ROOT = Path(__file__).resolve().parent.parent.parent


def _tap_submodule_uninitialized(repo_root):
    """
    True only when repo_root is the MAIN repo layout (it declares homebrew-tap
    as a submodule via .gitmodules) and that submodule checkout is missing,
    empty, or lacks its own .git -- i.e. never initialized.

    False in every other case, INCLUDING the tap-mirror layout (where this
    repo root has no .gitmodules / no homebrew-tap concept at all -- e.g.
    this exact lcars-ui/tests directory, shipped under
    homebrew-tap/share/lcars-ui/tests/ in the tap's own clone, has no
    .gitmodules three levels up) and the normal CI/initialized-submodule
    case. Never guesses on an unreadable directory -- that reads as
    "initialized" (no warning), not as evidence either way.
    """
    if not (repo_root / ".gitmodules").is_file():
        return False  # not the main-repo layout at this root -- no-op
    tap_dir = repo_root / "homebrew-tap"
    if not tap_dir.is_dir():
        return True  # missing entirely
    try:
        is_empty = not any(tap_dir.iterdir())
    except OSError:
        return False  # unreadable -- don't guess
    if is_empty:
        return True
    return not (tap_dir / ".git").exists()  # present but never checked out


_TAP_UNINITIALIZED_WARNING = (
    "homebrew-tap submodule NOT initialized at {tap_dir} -- some tests below "
    "may fail or skip with confusing, unrelated-looking errors (missing "
    "fixtures, missing helper scripts, etc.). "
    "Fix: git submodule update --init homebrew-tap"
)


def pytest_report_header(config):
    if _tap_submodule_uninitialized(REPO_ROOT):
        return [
            "*" * 78,
            "WARNING: " + _TAP_UNINITIALIZED_WARNING.format(tap_dir=REPO_ROOT / "homebrew-tap"),
            "*" * 78,
        ]
    return None


def pytest_terminal_summary(terminalreporter, exitstatus, config):
    if _tap_submodule_uninitialized(REPO_ROOT):
        terminalreporter.write_sep(
            "*",
            "WARNING: " + _TAP_UNINITIALIZED_WARNING.format(tap_dir=REPO_ROOT / "homebrew-tap"),
            red=True,
            bold=True,
        )


# ── XACA-1382-015: reset the process-level parsed-board cache per test ──────
#
# server._cached_board() keys entries on str(path). A test that hands a bare
# MagicMock in as a board path gets a key derived from the mock's repr (its
# memory address); a later mock that reuses the address could be served an
# earlier test's board. Clearing around every test removes that cross-test
# coupling. Import-safe: it never imports server -- it only clears the cache
# when some test already has (`sys.modules`). Identical copy in the sibling
# conftest (tests/ <-> lcars-ui/tests/), independent like the checks above.
# XACA-1386: the import is guarded because plain python3 (no pytest)
# also loads this file -- tests/test-git-env-hermetic-runners.sh imports
# it to prove the git-env scrub runs, on runners without pytest installed.
try:
    import pytest as _pytest_xaca1382
except ImportError:  # pragma: no cover
    _pytest_xaca1382 = None

if _pytest_xaca1382 is not None:
    @_pytest_xaca1382.fixture(autouse=True)
    def _xaca1382_clear_board_cache():
        import sys

        def _clear():
            mod = sys.modules.get("server")
            clear = getattr(mod, "_board_cache_clear", None)
            if callable(clear):
                clear()

        _clear()
        yield
        _clear()


# Guarded like the XACA-1382 fixture above: harnesses that load this conftest
# without pytest installed (e.g. test-git-env-hermetic-runners.sh) must not crash.
if _pytest_xaca1382 is not None:
    @_pytest_xaca1382.fixture(autouse=True)
    def _xaca1397_no_lazy_reconcile_refresher(monkeypatch):
        """XACA-1397-001: board GETs lazily start a background reconcile refresher
        that would run the REAL zsh helper. Two layers, both per test:

        1. LCARS_RECONCILE_REFRESHER_DISABLED=1 -- server.py checks it on the lazy
           start path on every call, so it covers EVERY module object loaded from
           server.py, whatever name it was imported under (lcars_server,
           lcars_server_x1239, ...) and including modules loaded mid-test, which a
           sys.modules["server"] lookup can never see.
        2. stop the canonical `server` module's refresher (also kills a thread a
           previous test started explicitly).

        The XACA-1397 suite re-enables lazy start with a stubbed compute."""
        import sys

        def _off():
            mod = sys.modules.get("server")
            stop = getattr(mod, "stop_reconcile_refresher", None)
            if callable(stop):
                stop()

        monkeypatch.setenv("LCARS_RECONCILE_REFRESHER_DISABLED", "1")
        _off()
        yield
        _off()
