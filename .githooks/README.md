# Git Hooks

Opt-in pre-commit hooks for this repository.

## Enable

From the repository root:

```bash
git config core.hooksPath homebrew-tap/.githooks
```

If your clone contains only `homebrew-tap/` as the root, use `.githooks` instead.

## What runs

- **pre-commit — Setup-wizard drift guard (XACA-0173).** Fails the commit if
  `libexec/aiteamforge-setup.sh` or `tests/test-setup-wizard.sh` reappears,
  or if `bin/aiteamforge-setup.sh` disappears. Only runs when the commit
  actually touches those paths; other commits pass through instantly.

- **pre-commit — Tap-hygiene guard (XACA-0361).** Fails the commit if any of:
  - An orphan `.rb` file appears in `Formula/` (only `aiteamforge.rb` is valid).
  - `VERSION`, `Formula/aiteamforge.rb`'s `version` field, and its `tag:` field
    disagree (all three must name the same version string).
  - A tracked filename matching `*doublenode*` (case-insensitive) is found outside
    the allow-list (stale rebrand artifacts from pre-AITeamForge era).

  Runs when the commit touches `Formula/`, `VERSION`, `fleet-monitor/`, or
  `scripts/check-tap-hygiene.sh`. Other commits pass through instantly.

## Why

The same checks run authoritatively in CI (`.github/workflows/tests.yml` →
`drift-guard` and `tap-hygiene-guard` jobs). The pre-commit hook is purely a
convenience — it catches mistakes before you push.
