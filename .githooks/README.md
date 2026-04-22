# Git Hooks

Opt-in pre-commit hooks for this repository.

## Enable

From the repository root:

```bash
git config core.hooksPath homebrew-tap/.githooks
```

If your clone contains only `homebrew-tap/` as the root, use `.githooks` instead.

## What runs

- **pre-commit** — Setup-wizard drift guard (XACA-0173). Fails the commit if
  `libexec/aiteamforge-setup.sh` or `tests/test-setup-wizard.sh` reappears,
  or if `bin/aiteamforge-setup.sh` disappears. Only runs when the commit
  actually touches those paths; other commits pass through instantly.

## Why

The same check runs authoritatively in CI
(`.github/workflows/tests.yml` → `drift-guard` job). The pre-commit hook is
purely a convenience — it catches the mistake before you push.
