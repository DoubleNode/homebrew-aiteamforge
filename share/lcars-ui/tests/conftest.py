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
