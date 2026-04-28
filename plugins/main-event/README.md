# Main Event Entertainment Plugin

**Status:** Opt-in (disabled by default)
**Version:** 1.0.0
**Plugin slug:** `main-event`

## What this plugin provides

The Main Event plugin bundles the skills, templates, and integrations that
are only useful for Main Event Entertainment (a Dave & Buster's company)
deployments. Everything under this directory is **strictly opt-in** — a
vanilla `aiteamforge` install does not receive any of this content unless
the operator explicitly enables the plugin in their org configuration.

Planned skills (productization tracked under XACA-0139):

- **Main Event CR** — Confluence-published change requests for PROD
  deployments (iOS, Android, Firebase).
- **Main Event RELNOTES Manager** — full RELNOTES lifecycle across the
  six environments (DEV → QA → ALPHA → BETA → GAMMA → PROD).
- **Main Event Weekly Reports** — coordinator that orchestrates the
  five weekly stakeholder reports.
- **Weekly Email Newsletter** — marketing-tone summary for internal
  Main Event / Dave & Buster's staff.
- **Weekly Product Owner Report** — leadership briefing with platform
  status, metrics, and automated vulnerability scans.
- **Scrum of Scrums ME APP** — executive summary for cross-team SoS.
- **Marketing Summary** — offer analytics and campaign performance.
- **Center Management App Update** — guest-facing newsletter blurb
  for center GMs.
- **Create Center** — interactive Firestore workflow for provisioning a
  new Main Event entertainment center in DEV or PROD.
- **Bitrise Build Status** — CI status surface for the iOS/Android apps.

Integrations used by the above: Jira, Confluence, Bitrise.

## How to enable

The plugin is consumed from `~/.aiteamforge/organization.yaml` (or the
equivalent org-config file produced by `aiteamforge setup`). Add:

```yaml
plugins:
  enabled:
    - main-event
```

Then re-run `aiteamforge setup` (or the idempotent `refresh` command). The
installer will copy every skill listed in
[`plugin.yaml`](./plugin.yaml) `installs.skills` into
`${AITEAMFORGE_DIR}/skills/`, which `install-claude-config.sh` then
symlinks into `~/.claude/skills/` the same way it handles core skills.

Removing the plugin is symmetrical: delete the slug from the `enabled`
list, re-run setup, and the installer removes the corresponding skills.

## Why opt-in?

`aiteamforge` is the generic, org-agnostic framework. Main Event is one
(very important) consumer, but not the only one — DNS, Freelance, and
Personal teams all use the same toolkit without needing ME's CR
publishing, RELNOTES workflow, or Bitrise credentials. Keeping ME content
behind an explicit opt-in means:

- Non-ME installs stay lean and don't see irrelevant slash commands.
- ME-specific credentials (Confluence API tokens, Bitrise keys) are only
  requested from users who will actually use them.
- The default tap can be open-sourced without leaking Main Event internal
  process knowledge, even if the plugin itself ships in a separate,
  internal-only tap or private overlay.

## Status of the 1.0.0 manifest

This directory currently ships **no skills** in `skills/` — the ME-specific
skills listed above still live in `~/dev-team/skills/` (dev-team repo
root) for local development and have not been productized into the tap.
The scaffolding (this `plugin.yaml` + `README.md` + empty `skills/` dir)
establishes the plugin layer so that future work can drop skills in
without needing to re-argue the architecture.

See the TODO block at the bottom of `plugin.yaml` for the installer-side
edits that subitem XACA-0139-003 will land to make the plugin actually
load.

## Directory layout

```
plugins/main-event/
├── plugin.yaml      Manifest: slug, version, enabled skills, integrations
├── README.md        This file
└── skills/          Relocated ME-specific skill directories (empty in 1.0.0)
```

## Ownership

- **Owner:** Main Event Entertainment / Dave & Buster's
- **License:** Proprietary — internal use only
- **Source tracking:** `XACA-0139` (AITeamForge de-branding effort)
