# Organization Identity Configuration

**XACA-0139 — Per-install organization identity for the AITeamForge framework**

---

## What This Is and Why It Exists

Before XACA-0139, the AITeamForge framework had the client organization name baked into shipped code, doc strings, and default paths. That meant the same tap could not be cleanly installed for a different client without forking. XACA-0139 extracts organization identity into a per-install YAML file — `~/.aiteamforge/organization.yaml` — and introduces a small resolver library (shell + Python) that every shipped script consults to answer the question *"whose install is this?"*. This is the implicit fourth axis of the [Three-Axis Configuration Model (XACA-0130)](ARCHITECTURE.md): **Machine → Team → Role → Organization**. The organization axis is the outermost; every other axis lives *inside* an organization.

---

## Setup

### Fresh Install

`aiteamforge setup` (XACA-0139-003, landing after this foundation) will prompt for the organization's slug, name, and optional short label, then write `~/.aiteamforge/organization.yaml` from the shipped template.

### Manual Setup

If you are bootstrapping by hand, or need to change identity on an existing install:

```bash
# Copy the template to the canonical location
cp "$(brew --prefix)/opt/aiteamforge/share/config/organization.yaml.example" \
   ~/.aiteamforge/organization.yaml

# Edit the fields for your org
$EDITOR ~/.aiteamforge/organization.yaml
```

The shipped `organization.yaml.example` documents every field inline; the sections below summarize each one.

### Resolution Order

Callers (both the shell resolver and the Python resolver) search for an active config in this order; the first hit wins:

1. `$AITEAMFORGE_ORG_CONFIG` — env override, used by tests and CI
2. `$AITEAMFORGE_DIR/organization.yaml` — working-dir override (for multi-install hosts)
3. `$HOME/.aiteamforge/organization.yaml` — canonical per-user location
4. `<framework>/share/config/organization.yaml.example` — shipped fallback (keeps a fresh tap usable before `setup` runs)

---

## Field Reference

### `organization` (required)

| Field | Type | Purpose |
|---|---|---|
| `slug` | `string` (lowercase-kebab) | Filesystem-safe identifier. Used in paths, log tags, plugin enable-lists. Keep stable — renaming orphans per-org state. |
| `name` | `string` (UTF-8) | Human-readable org name. Appears in agent prompts, LCARS headers, generated docs. |
| `display_short` | `string` (≤ 12 chars, optional) | Compact label for statuslines and narrow UI. Defaults to `name`. |
| `domain` | `string` (optional) | Primary DNS domain. Integrations use it as a URL hint. |

### `paths` (optional)

| Field | Type | Purpose |
|---|---|---|
| `projects_root` | `string` (with `${HOME}` expansion) | Where this org's project repos live under single-user setups. Default: `${HOME}/projects`. |
| `shared_dev_root` | `string` (optional) | Top-level shared-Mac dir (e.g. `/Users/Shared/Development`). Leave unset for single-user installs. |

### `plugins`

| Field | Type | Purpose |
|---|---|---|
| `enabled` | `list[string]` | Slugs of opt-in plugin layers to activate. Empty by default. |

### `integrations` (optional)

A container for per-service configuration blocks. Each block (e.g. `jira`, `confluence`, `bitrise`) is optional; absence means the integration is disabled and downstream commands skip it. See the shipped example for documented patterns. **Secrets never live in this file** — use Keychain, env vars, or a separate untracked file referenced by path.

---

## Enabling Plugins

Plugins are opt-in bundles of org-specific assets (kanban teams, personas, skills, integration hooks). They live in `homebrew-tap/plugins/<slug>/` and are introduced by XACA-0139-005.

To enable a plugin, add its slug to `plugins.enabled`:

```yaml
plugins:
  enabled:
    - "main-event"     # example: primary org plugin (ios/android/firebase/command/mainevent teams)
    - "doublenode"     # example: DoubleNode freelance project family plugin
```

A fresh install with `plugins.enabled: []` is a **clean vanilla framework** with no org-specific content — that's the state new clients start from. They layer in the plugins they need.

---

## Shell API Reference

Source `libexec/lib/aiteamforge-org-paths.sh` (via `$AITEAMFORGE_LIB_DIR` or direct path) and call:

| Function | Args | Returns (stdout) | Notes |
|---|---|---|---|
| `_aiteamforge_org_config_path` | — | Absolute path to the active `organization.yaml` | Non-zero exit if no file found anywhere |
| `_aiteamforge_org_slug` | — | `organization.slug` (default `example-org`) | |
| `_aiteamforge_org_name` | — | `organization.name` (default `Example Organization`) | |
| `_aiteamforge_org_display_short` | — | `organization.display_short` (falls back to `name`) | |
| `_aiteamforge_org_domain` | — | `organization.domain` or empty | |
| `_aiteamforge_org_projects_root` | — | Expanded `paths.projects_root` (default `$HOME/projects`) | |
| `_aiteamforge_org_shared_dev_root` | — | `paths.shared_dev_root` or empty | |
| `_aiteamforge_org_plugin_enabled` | `$1` = slug | — (exit 0/1) | Exit 0 if slug in `plugins.enabled`, 1 otherwise |
| `_aiteamforge_org_integration_get` | `$1` = integration, `$2` = key | Scalar value or newline-joined list | Empty string if absent |

All functions are `set -u`-safe and print nothing to stdout other than the requested value. Errors go to stderr.

**Example:**

```bash
source "$AITEAMFORGE_LIB_DIR/aiteamforge-org-paths.sh"

slug=$(_aiteamforge_org_slug)                              # e.g. "main-event"
if _aiteamforge_org_plugin_enabled "main-event"; then
    echo "ME plugin active"
fi
jira_url=$(_aiteamforge_org_integration_get jira base_url)
```

### Parser Requirements

The shell resolver uses `yq` if available, falling back to `python3` + PyYAML (installed in the tap's venv). If neither can parse YAML the first call that needs parsed data returns non-zero with a clear error on stderr.

---

## Python API Reference

`import aiteamforge_org_paths` (from `share/kanban-hooks/`) and call:

| Function | Signature | Notes |
|---|---|---|
| `org_config_path()` | `() -> pathlib.Path` | Raises `FileNotFoundError` if no config is found |
| `org_slug()` | `() -> str` | Default `"example-org"` |
| `org_name()` | `() -> str` | Default `"Example Organization"` |
| `org_display_short()` | `() -> str` | Falls back to `org_name()` |
| `org_domain()` | `() -> str` | Empty if unset |
| `org_projects_root()` | `() -> pathlib.Path` | `${HOME}` expanded |
| `org_shared_dev_root()` | `() -> Optional[pathlib.Path]` | `None` if unset |
| `org_plugin_enabled(slug)` | `(str) -> bool` | |
| `org_integration_get(integration, key)` | `(str, str) -> Optional[str]` | List values joined with `\n`; dict values return `None` |
| `_load_org_config(force_reload=False)` | `(bool) -> dict` | Module-level cached loader. Pass `force_reload=True` to invalidate. |

PyYAML is a hard dependency (shipped in `share/requirements.txt`). If PyYAML cannot be imported, `_load_org_config` raises `RuntimeError` — this indicates a broken install, not a runtime condition.

**Example:**

```python
from aiteamforge_org_paths import org_slug, org_plugin_enabled, org_integration_get

if org_plugin_enabled("main-event"):
    configure_main_event_teams()

jira_base = org_integration_get("jira", "base_url")
```

---

## Migration Note for Existing Installs

When upgrading from a pre-XACA-0139 install, `aiteamforge setup` (in its idempotent re-run mode) detects a missing `~/.aiteamforge/organization.yaml` and prompts to create one. The setup wizard suggests defaults based on your existing install configuration.

**Example** — for an org named "Acme Corp" with slug `acme-corp`:

```yaml
organization:
  slug: "acme-corp"
  name: "Acme Corp"
  display_short: "Acme"
paths:
  shared_dev_root: "/Users/Shared/Development"
plugins:
  enabled:
    - "acme-corp"   # your org's plugin slug
```

Users can accept the suggested defaults (one keystroke) or edit before saving. Until the upgrade is run, the shipped `organization.yaml.example` keeps every resolver call returning the safe `example-org` defaults — no existing command breaks, they just stop showing the legacy org name in UI strings until the real config lands.

The migration is entirely additive: no existing file is renamed or removed, and `team-paths.json` (the team axis from XACA-0168) is untouched. Organization identity layers *above* team identity; the two configs never overlap.

---

## Verification

XACA-0139-008 introduced a BATS guard test (`tests/xaca-0139-debrand-guard.bats`) that
enforces the de-branding contract in CI. The test scans all shipped live-code paths
(`libexec/`, `share/kanban-hooks/`, `share/scripts/`, `share/templates/`, `bin/`) for
occurrences of the forbidden client-brand pattern:

```
[Mm]ain ?[Ee]vent|MainEvent|[Dd]ouble[Nn]ode|doublenode
```

Every hit must be annotated with an `# xaca-0139:allowed — <reason>` marker on the same
line or the line immediately above it. Unannotated hits fail the test with a precise
list of violating file:line references.

To run the guard locally:

```bash
cd "$(brew --prefix)/opt/aiteamforge"   # or your tap dev tree
bats tests/xaca-0139-debrand-guard.bats
```

Justified survivors (backward-compat default paths, stable team-slug constants,
ImportError fallback dicts) all carry inline `xaca-0139:allowed` markers. New code that
genuinely needs to reference a client name must add an explicit marker with a brief
justification — this makes the exception intentional and reviewable rather than silent.

---

**Related design docs:**

- [XACA-0130 — Three-Axis Configuration Model](ARCHITECTURE.md)
- [XACA-0168 — Team-paths resolver](../libexec/lib/aiteamforge-paths.sh)
- [XACA-0139 — This work](../share/config/organization.yaml.example)
- [XACA-0139-008 — De-brand guard test](../tests/xaca-0139-debrand-guard.bats)
