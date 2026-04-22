# Python Dependency Install Channel — Design Decision

**XACA-0175-001 | Status: DECIDED**
**Author:** Captain Nahla Ake (Academy Chancellor)
**Date:** 2026-04-21

---

## Problem

AITeamForge ships 20+ Python scripts that currently invoke bare `python3` from PATH.
Two scripts (`bin/aiteamforge-setup.sh` and `libexec/lib/validate-install.sh`) already
ad-hoc-create per-user venvs at `~/aiteamforge/.venv` for the `iterm2` package.
The incoming `pyzipper` requirement (XACA-0172) forces us to stop treating Python
deps as afterthoughts and establish a single, tap-owned install channel.

**Goal:** Pick one channel. Document why. Specify the interface for implementers.

---

## Candidate Channels

### 1. Tap-Owned Venv at `$HOMEBREW_PREFIX/var/aiteamforge/venv`

Provisioned during Formula `post_install`. A single venv shared across all tap users on
the machine. Versions pinned via `share/requirements.txt`, which ships with the tap.

**Pros**
- Lives under `var/`, which Homebrew preserves across `brew upgrade` and `brew reinstall`
- Completely isolated from the system Python — PEP 668 irrelevant inside a venv
- Interpreter path is stable and predictable: `$HOMEBREW_PREFIX/var/aiteamforge/venv/bin/python3`
- `requirements.txt` means adding a new dep is one line; versions are pinned and reproducible
- Provisioned once at install time; every script invocation is zero-overhead after that
- `post_install` runs as the installing user — no sudo, no privilege escalation

**Cons**
- Multi-user machines share one venv — acceptable since all tap users get the same version
- Venv is ABI-locked to the Homebrew `python@3` it was created with; must rebuild when that
  Python is upgraded (see Edge Cases)
- `brew uninstall` removes `var/aiteamforge/` — venv is lost (but so is everything else;
  this is expected behavior)

---

### 2. `--user` Site-Packages (`pip install --user`)

Per-user install into `~/.local/lib/python3.x/site-packages/`.

**Pros**
- No venv overhead; simple `pip install --user pyzipper`
- Works without any Formula changes beyond the existing `depends_on "python@3"`

**Cons**
- Homebrew's `python@3` is marked externally-managed (PEP 668 enforcement). Direct `pip
  install` against it fails with `error: externally-managed-environment` on macOS Sonoma+
  without `--break-system-packages` — a flag we must never use in a tap installer
- Collides with other tools that use `--user` packages; version conflicts are undetectable
- No pinning mechanism — `pip install --user` installs whatever PyPI offers today
- `~/.local` paths differ across macOS versions and non-standard HOME configurations
- Cannot be used reliably from `post_install` (runs in a sandboxed env on some Homebrew
  configurations)

**Verdict:** Ruled out. PEP 668 blocks it without a system-packages override we cannot
legitimately use, and collision risk is unacceptable for a tap that may co-exist with
developer tooling.

---

### 3. pipx

Installs Python applications in isolated venvs, exposing their entry-point scripts on PATH.

**Pros**
- Excellent isolation and upgrade story for CLI tools
- Well-understood in the macOS dev community

**Cons**
- pipx installs CLI entry points, not importable libraries. `pyzipper`, `iterm2`, and
  future deps are libraries that scripts `import` — pipx cannot inject them into scripts
  that invoke `python3` directly
- Would require wrapping every Python script as a pipx "app", a fundamental architecture
  change for no benefit
- Adds a mandatory dependency not currently in the Formula

**Verdict:** Ruled out. Wrong abstraction level — we need importable libraries, not CLI
entry points.

---

### 4. Vendored Wheels

Ship pre-built `.whl` files inside the tap itself. `post_install` runs `pip install --no-index
--find-links=<wheels-dir> -r requirements.txt`.

**Pros**
- Fully offline — no network required at install time
- Reproducible: the exact wheel version is what users get

**Cons**
- Wheels are ABI and platform specific — separate wheels needed for each Python micro-version
  and macOS architecture (x86_64 vs arm64)
- Bloats the tap repository significantly (pyzipper alone is ~50KB; iterm2 + deps is ~2MB)
- Every dependency update requires re-vendoring binaries and a new tap release
- `git clone` of the tap becomes slow; homebrew formula audits flag binary blobs

**Verdict:** Ruled out. Maintenance cost and binary-in-git constraints outweigh the
offline install benefit for a tap that already requires network access to install.

---

## Decision

**Use a tap-owned venv at `$HOMEBREW_PREFIX/var/aiteamforge/venv`.**

This is the only channel that satisfies all constraints simultaneously: it bypasses PEP 668
cleanly (venvs are explicitly excluded from externally-managed restrictions), survives
`brew upgrade`, provides a stable interpreter path, and makes dependency management a
one-line change in `requirements.txt`.

It also consolidates the two ad-hoc per-user venvs already in the codebase (`~/aiteamforge/.venv`)
into a single tap-managed location. Those per-user venvs are a messy precedent we are
replacing, not extending.

---

## Interface Specification

The following contracts are established by this decision. Subitems 002–005 implement
against them; they must not deviate from paths or variable names below.

### Venv Location

```
$HOMEBREW_PREFIX/var/aiteamforge/venv
```

This is the canonical, single venv for all AITeamForge Python scripts. No other venvs
are created by the Formula or by any installer script after this change lands.

### Requirements File

```
homebrew-tap/share/requirements.txt
```

Shipped inside the tap. Read by `post_install` during Formula installation. Pinned to
exact versions (e.g. `pyzipper==0.3.6`, `iterm2==2.9`). Adding a new dep: one line here
plus a Formula version bump to trigger `post_install`.

### Environment Variable

```
AITEAMFORGE_PYTHON=$HOMEBREW_PREFIX/var/aiteamforge/venv/bin/python3
```

All bin stubs and libexec scripts use this variable to invoke Python. They must not call
bare `python3` for anything that requires a third-party library.

### env.sh Snippet

**Path:** `$HOMEBREW_PREFIX/var/aiteamforge/env.sh`

Written by `post_install` at install time (not shipped in the tap; generated from the
known `HOMEBREW_PREFIX`). Sourced by bin stubs and libexec scripts before invoking Python.

**Contents:**

```sh
# AITeamForge Python environment — generated by post_install, do not edit manually
# Sourced by bin stubs and libexec scripts. Safe to source multiple times.

_ATF_VENV="${HOMEBREW_PREFIX:-/opt/homebrew}/var/aiteamforge/venv"

if [ -d "$_ATF_VENV" ]; then
  export AITEAMFORGE_PYTHON="$_ATF_VENV/bin/python3"
else
  # Fallback: venv missing (dev mode, non-brew install, or post_install not yet run)
  export AITEAMFORGE_PYTHON="${AITEAMFORGE_PYTHON:-python3}"
  [ "${_ATF_VENV_WARNED:-}" != "1" ] && \
    echo "aiteamforge: WARNING: Python venv not found at $_ATF_VENV" \
         "(run: brew reinstall aiteamforge)" >&2
  export _ATF_VENV_WARNED=1
fi

unset _ATF_VENV
```

The warning is printed at most once per shell session (guarded by `_ATF_VENV_WARNED`).
Hard-fail (`exit 1`) is intentionally omitted — scripts that do not use third-party
libraries (stdlib-only) will still work correctly with system `python3`.

### Fallback Behavior

When `HOMEBREW_PREFIX/var/aiteamforge/venv` is absent:

1. `AITEAMFORGE_PYTHON` falls back to bare `python3`
2. A one-time warning is printed to stderr
3. Scripts continue — stdlib-only scripts work; scripts requiring third-party libraries
   will fail with a standard `ModuleNotFoundError`, which is acceptable because the user
   is already in a broken-install state

This covers: development mode (running scripts directly from a repo clone), non-Homebrew
installs, and the narrow window between `brew install` and first `post_install` run.

---

## Edge Cases for Implementers (Subitems 002–003)

### 1. `post_install` Must Be Idempotent

`var/` survives `brew reinstall` but `post_install` is called again. Creating the venv
must use `python3 -m venv --upgrade-deps "$venv"` (or check existence first). Installing
requirements must be `pip install --upgrade -r requirements.txt` — safe to run multiple
times.

### 2. ABI Lock and Python Upgrades

The venv is built against whichever `python@3` minor version Homebrew provides at install
time. When Homebrew upgrades `python@3` (e.g. 3.12 → 3.13), the venv's interpreter is
stale and most packages fail with `import` errors.

**Recommended approach in `post_install`:** Unconditionally recreate the venv on each
`post_install` run. This costs ~3 seconds but guarantees ABI alignment. Implementation:

```ruby
# In post_install
venv = HOMEBREW_PREFIX/"var/aiteamforge/venv"
venv.rmtree if venv.exist?
system python3, "-m", "venv", venv
system venv/"bin/pip", "install", "--upgrade", "pip"
system venv/"bin/pip", "install", "-r", libexec/"share/requirements.txt"
```

Unconditional recreation is simpler than ABI-version detection and has no meaningful
downside — `brew upgrade aiteamforge` is not a hot path.

### 3. PEP 668: Never `pip install` Against Brew Python Directly

`python3 -m venv <path>` is always the first step. Only after the venv exists should
`pip` be invoked — and always via `venv/bin/pip`, never `python3 -m pip` against the
system interpreter.

### 4. pip Freshness

Before installing requirements, run:

```
venv/bin/python3 -m ensurepip --upgrade
venv/bin/pip install --upgrade pip
```

This is cheap (<1s on a warm network) and prevents `pip` from complaining about its own
version during the requirements install.

### 5. Launchers Sourced Before Homebrew Is on PATH

Some users source shell init files early (before `/opt/homebrew/bin` is on `PATH`).
`env.sh` uses `${HOMEBREW_PREFIX:-/opt/homebrew}` as a fallback, covering Apple Silicon
default installs. For Intel Macs (`/usr/local`) and non-standard installs, the fallback
may miss — the warning path handles that gracefully. Do NOT hard-code `/opt/homebrew` in
any script other than `env.sh`.

### 6. Existing Per-User Venvs (`~/aiteamforge/.venv`)

After this change, `bin/aiteamforge-setup.sh` line 862 and
`libexec/lib/validate-install.sh` line 373 must stop creating `~/aiteamforge/.venv`.
Subitem 003 owns that cleanup. Leave the old paths in place until subitem 003 explicitly
removes them — do not touch those files in subitems 001 or 002.

---

## Out of Scope for This Document

- The contents of `share/requirements.txt` (subitem 002)
- Formula `post_install` implementation (subitem 002)
- `env.sh` generation in `post_install` (subitem 002)
- Migration of existing scripts from bare `python3` to `$AITEAMFORGE_PYTHON` (subitem 003)
- Removal of the old `~/aiteamforge/.venv` creation paths (subitem 003)
- Testing and validation plan (subitem 004 / 005)
