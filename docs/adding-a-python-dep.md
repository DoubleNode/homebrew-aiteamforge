# Adding a Python Dependency to AITeamForge

This guide explains how to add a new Python library so every `brew install`d
machine picks it up automatically.  It is the practical companion to the design
decision document; for the *why* behind each choice, read
[`docs/python-dep-channel-design.md`](python-dep-channel-design.md) first.

**Target audience:** An engineer who needs a third-party Python package available
to AITeamForge scripts and has never touched this part of the tap before.

---

## Quick Reference

Four steps, done in order:

1. Add `<package>==<version>` to `homebrew-tap/share/requirements.txt`
2. Bump the `VERSION` file and the two matching lines in
   `homebrew-tap/Formula/aiteamforge.rb` (`url tag:` and `version`)
3. In Python scripts that import the new library, invoke them via
   `$AITEAMFORGE_PYTHON` (not bare `python3`)
4. Smoke-test locally:
   ```bash
   bash homebrew-tap/tests/smoke-python-deps.sh
   ```

That is the complete flow. The sections below expand each step with concrete
before-and-after examples.

---

## Full Walkthrough

### Step 1 — Add the package to `requirements.txt`

**File:** `homebrew-tap/share/requirements.txt`

Pin to an exact version. No `~=`, no `>=`, no unpinned names. See
[Version pinning guidance](#version-pinning-guidance) for why.

**Before:**
```
# AITeamForge Python library dependencies
# Add deps as: <package>==<version>
# After adding, bump Formula version and run: brew reinstall aiteamforge

# AES-256 zip support (XACA-0172 secrets-zip workflow)
pyzipper==0.3.6
```

**After (adding `requests` as a worked hypothetical):**
```
# AITeamForge Python library dependencies
# Add deps as: <package>==<version>
# After adding, bump Formula version and run: brew reinstall aiteamforge

# AES-256 zip support (XACA-0172 secrets-zip workflow)
pyzipper==0.3.6

# HTTP client (XACA-NNNN brief description)
requests==2.32.3
```

`pyzipper==0.3.6` is the inaugural real dep that was added in XACA-0172; use
that pattern (package, exact version, ticket comment) for every new entry.

### Step 2 — Bump the Formula version

Users get the new dep only when `post_install` runs. `post_install` only runs
when the Formula version changes. You must bump the version even if no Formula
logic changed.

**File:** `homebrew-tap/Formula/aiteamforge.rb`

Two lines to update (keep them identical):

```ruby
  url "https://github.com/DoubleNode/homebrew-aiteamforge.git",
      tag: "v0.12.0"   # <-- bump this
  ...
  version "0.12.0"     # <-- and this
```

Also bump `homebrew-tap/VERSION` to match:

```
0.12.0
```

Incrementing the patch component is sufficient for a dep-only change.

### Step 3 — Call scripts through `$AITEAMFORGE_PYTHON`

Any shell script or Python script that `import`s the new library must be
invoked through the tap-owned venv Python. See
[How Python scripts invoke the venv](#how-python-scripts-invoke-the-venv) for
the two idiomatic patterns.

If you are writing a new shell script that calls a Python script using the new
library:

```bash
# Source the helper at the top of your shell script
. "$AITEAMFORGE_HOME/libexec/lib/python-env.sh"

# Then invoke Python through the resolved interpreter
"$AITEAMFORGE_PYTHON" "$AITEAMFORGE_HOME/libexec/my-script.py" "$@"
```

### Step 4 — Run the smoke test

```bash
bash homebrew-tap/tests/smoke-python-deps.sh
```

The test resolves `AITEAMFORGE_PYTHON` automatically from `python-env.sh` when
run from the repo. If the venv is not yet provisioned, the script exits with a
clear `RESULT: FAIL (venv not provisioned)` message — that is expected in a
bare repo clone. Either install via brew first, or extend the smoke test to
cover your new dep (see [Testing your new dep](#testing-your-new-dep)).

---

## Version Pinning Guidance

Always use exact-version pins (`==`). Never use:

- `~=` (compatible release) — patch-level drift across machines
- `>=` (minimum version) — PyPI can serve anything higher; installs diverge over time
- No pin at all — same problem, worse

**Why exact pins matter:**

- Every developer machine that runs `brew install aiteamforge` gets the same
  library version. Debugging "works on my machine" bugs disappears.
- Security audits can identify the exact package version in use without
  inspecting individual machines.
- `requirements.txt` becomes the audit trail: a git diff shows exactly what
  changed and when.

**Finding the right version to pin:**

```bash
pip index versions <package>      # list available versions
pip show <package>                # version of what is currently installed
```

Pin the latest stable release unless there is a documented reason to use an
older one (e.g., a known regression in a newer release). Document that reason
in a comment next to the pin.

---

## How Python Scripts Invoke the Venv

There are two idiomatic patterns depending on whether the caller is a shell
script or another Python script.

### Pattern A — Shell script calling a Python script

Source `python-env.sh` early in the shell script. This sets `AITEAMFORGE_PYTHON`
to the tap-owned interpreter (or falls back to bare `python3` with a warning if
the venv is absent).

```bash
#!/bin/bash
# my-command.sh

AITEAMFORGE_HOME="$(brew --prefix)/opt/aiteamforge/libexec"

# Source the env helper — this sets AITEAMFORGE_PYTHON
. "$AITEAMFORGE_HOME/libexec/lib/python-env.sh"

# Invoke the Python script through the venv interpreter
exec "$AITEAMFORGE_PYTHON" "$AITEAMFORGE_HOME/libexec/my-command.py" "$@"
```

The bin stubs generated by the Formula already do the equivalent via
`$HOMEBREW_PREFIX/var/aiteamforge/env.sh`, so any script launched through
those stubs inherits `AITEAMFORGE_PYTHON` automatically.

### Pattern B — Python script as the entry point

When `$AITEAMFORGE_PYTHON` calls a `.py` file directly, the interpreter is
already the venv Python, so third-party imports work as-is.

Keep the shebang as `#!/usr/bin/env python3` for compatibility when running
the file directly in a dev-mode repo clone (where the venv may not exist):

```python
#!/usr/bin/env python3
# my-command.py
import pyzipper  # works only when invoked via $AITEAMFORGE_PYTHON
```

The shebang is ignored when the file is passed as an argument to an explicit
interpreter (`"$AITEAMFORGE_PYTHON" my-command.py`), so there is no conflict.

**The rule:** Callers that depend on third-party libraries MUST go through
`$AITEAMFORGE_PYTHON`. Scripts that use only the Python standard library can
tolerate bare `python3`, but using `$AITEAMFORGE_PYTHON` consistently is
harmless and avoids surprises.

---

## Testing Your New Dep

The smoke test at `homebrew-tap/tests/smoke-python-deps.sh` is the canonical
validation pattern. It:

1. Resolves `AITEAMFORGE_PYTHON` from `python-env.sh`
2. Verifies the target package imports without error
3. Runs a functional roundtrip (e.g., for `pyzipper`: encrypt a string,
   decrypt it, assert the result matches)

**Adding coverage for a new dep — minimal approach:**

Extend `smoke-python-deps.sh` with a new section following the existing pattern:

```bash
# ------------------------------------------------------------------
# Step N: Verify <newpackage> import
# ------------------------------------------------------------------
echo "--- Step N: <newpackage> import ---"

PKG_VERSION=$("$AITEAMFORGE_PYTHON" -c "import newpackage; print(newpackage.__version__)" 2>&1)
IMPORT_EXIT=$?

if [ $IMPORT_EXIT -ne 0 ]; then
    _fail "<newpackage> import failed: $PKG_VERSION"
    echo "RESULT: FAIL"
    exit 1
fi

echo "<newpackage> version: $PKG_VERSION"
_pass "<newpackage> imports successfully (version $PKG_VERSION)"
echo ""
```

Add a functional roundtrip if the package does non-trivial I/O or crypto — a
pure import check misses corrupted installs.

**Alternative: dedicated smoke test per dep**

If the functional test is complex (more than ~20 lines), create a separate
file `homebrew-tap/tests/smoke-<package>.sh` rather than growing the main
smoke script. Use the same `_pass`/`_fail` pattern and the same
`AITEAMFORGE_PYTHON` resolution block from `smoke-python-deps.sh`.

---

## Updating Existing Dependencies

To upgrade a pinned version:

1. Update the version in `homebrew-tap/share/requirements.txt`:
   ```
   # was: pyzipper==0.3.6
   pyzipper==0.3.7
   ```
2. Bump the Formula version (same as Step 2 above)
3. Test the upgrade locally:
   ```bash
   brew reinstall aiteamforge
   bash homebrew-tap/tests/smoke-python-deps.sh
   ```

Users pick up the new version on their next `brew upgrade aiteamforge`. The
Formula's `post_install` unconditionally recreates the venv and runs
`pip install -r requirements.txt`, so the upgrade is automatic.

---

## Troubleshooting

### "ModuleNotFoundError" on a brew-installed machine

The venv is not provisioned or is stale.

1. Check that `AITEAMFORGE_PYTHON` points at the venv:
   ```bash
   echo "$AITEAMFORGE_PYTHON"
   # Expected: /opt/homebrew/var/aiteamforge/venv/bin/python3
   ```
2. If it is empty or shows bare `python3`, run:
   ```bash
   brew reinstall aiteamforge
   ```
   This re-runs `post_install`, recreates the venv, and reinstalls all deps.

### "error: externally-managed-environment" (PEP 668)

You are calling `pip install` against Homebrew's `python@3` directly, outside a
venv. This is blocked by macOS Sonoma+ and Homebrew's externally-managed
enforcement.

Do not use `--break-system-packages`. Instead:

- From shell: use `$AITEAMFORGE_PYTHON -m pip install ...` (only for local dev
  experimentation; never in installer code)
- In Formula: all `pip install` calls must go through `venv/bin/pip` inside
  `post_install`, never through the system interpreter

### "Wrong Python version after brew upgrade python@3"

Expected behavior. The venv is ABI-locked to the Python minor version it was
created with. When Homebrew upgrades `python@3` (e.g., 3.12 → 3.13), the venv's
interpreter is stale.

Fix: `brew reinstall aiteamforge`. The `post_install` unconditionally deletes
and recreates the venv, realigning it to the current `python@3`.

This is intentional — see the ABI Lock edge case in
[`docs/python-dep-channel-design.md`](python-dep-channel-design.md).

### "Running from a repo clone, no venv exists"

When running scripts directly from a repo clone (not a Homebrew install),
`AITEAMFORGE_PYTHON` falls back to bare `python3` from PATH. A warning is
printed to stderr:

```
aiteamforge: WARNING: tap-owned Python venv not found at .../var/aiteamforge/venv
             (run: brew reinstall aiteamforge)
```

Scripts that only use the Python standard library still work. Scripts that
import third-party deps (`pyzipper`, etc.) will fail with `ModuleNotFoundError`.

Options:
- Install via Homebrew and run scripts through the installed bin stubs
- Create a local dev venv manually:
  ```bash
  python3 -m venv /tmp/atf-dev-venv
  /tmp/atf-dev-venv/bin/pip install -r homebrew-tap/share/requirements.txt
  export AITEAMFORGE_PYTHON=/tmp/atf-dev-venv/bin/python3
  ```

### Smoke test fails with "venv not provisioned"

The smoke test detected that `AITEAMFORGE_PYTHON` resolved to bare `python3` or
is unset. Either install via brew and run the test again, or set
`AITEAMFORGE_PYTHON` explicitly:

```bash
AITEAMFORGE_PYTHON=/opt/homebrew/var/aiteamforge/venv/bin/python3 \
  bash homebrew-tap/tests/smoke-python-deps.sh
```

---

## What NOT to Do

- **Don't use `--break-system-packages`** — this flag bypasses PEP 668 by
  modifying the system Python; it can corrupt other tools and is irreversible
  without reinstalling Homebrew's Python.

- **Don't create per-user venvs** (`~/aiteamforge/.venv` and similar) — that
  pattern was used in older versions of the tap and is being removed. The
  tap-owned venv at `$HOMEBREW_PREFIX/var/aiteamforge/venv` is the single
  canonical location.

- **Don't call `pip install` from anywhere except `post_install`** — ad-hoc
  `pip install` calls in installer scripts or setup wizards create state that
  the Formula doesn't know about and can't clean up.

- **Don't invoke bare `python3` for scripts that import third-party libs** —
  bare `python3` resolves to the system interpreter, which does not have the
  tap deps installed. Use `$AITEAMFORGE_PYTHON`.

- **Don't commit `.venv/` or `venv/` directories** — these are
  machine-specific binary artifacts and are ignored by `.gitignore`. Verify
  with `git status` if you are unsure; neither should appear as untracked.

---

*For the full design rationale and candidate channel analysis, see
[`docs/python-dep-channel-design.md`](python-dep-channel-design.md).*
