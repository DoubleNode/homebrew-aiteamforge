# Team Definitions Directory

This directory contains team configuration files and the team registry.

## Files

### Team Configuration Files (*.conf)

Each `.conf` file defines a team's properties:
- Metadata (name, description, category, color)
- Repository associations
- Homebrew dependencies
- Agent personas
- Startup/shutdown scripts
- LCARS port assignments
- Star Trek theme

**Format:** Shell-sourceable key-value pairs

**Current Teams:**
- `academy.conf` - Starfleet Academy (infrastructure)
- `android.conf` - Android Development (platform)
- `command.conf` - Starfleet Command (strategic)
- `dns.conf` - DNS Framework (infrastructure)
- `firebase.conf` - Firebase Development (platform)
- `freelance.conf` - Freelance Projects (project)
- `ios.conf` - iOS Development (platform)
- `legal.conf` - JAG Legal (strategic)
- `mainevent.conf` - MainEvent Coordination (coordination)
- `medical.conf` - Starfleet Medical (strategic)

### Team Registry (registry.json)

JSON metadata for team selection UI:
- Display order
- Categories
- Icons
- Recommendations
- Mandatory-install flag
- Themes

**Used by:** Setup wizard, team selection interface

#### The `"mandatory"` flag (XACA-1070)

Each entry in `.teams[]` may carry an optional boolean `"mandatory"` key:

```json
{
  "id": "example-team",
  "...": "...",
  "mandatory": true
}
```

- **Omitting the key defaults to `false`.** Only a team explicitly marked
  `"mandatory": true` is treated as mandatory — there is no implicit
  mandatory team. `spacedock` is the first team to carry the flag, as of
  XACA-1070's activation commit. An empty mandatory-teams list remains a
  normal, expected state rather than an error — reachable on any consumer
  whose registry declares none.
- **A mandatory team is suppressed from the wizard's selectable list and
  force-installed instead.** The install wizard (`bin/aiteamforge-setup.sh`)
  does not present it as a checkbox choice — it is force-appended to every
  install's selection regardless of what the user picks.
- **It is backfilled on upgrade.** `aiteamforge upgrade`
  (`libexec/commands/aiteamforge-upgrade.sh`) installs any mandatory team
  that is missing from an already-provisioned machine, so existing installs
  converge onto the same mandatory set as fresh ones.
- **Its absence is a fault.** `aiteamforge doctor`
  (`libexec/commands/aiteamforge-doctor.sh`) reports a mandatory team that
  is not provisioned on the current host as a failing check, not a warning.
- **Do not confuse this with `"recommended"`.** `"recommended"` is a
  wizard-UI-only hint (pre-ticks a checkbox the user can still uncheck) with
  no enforcement anywhere in the installer — confirmed by
  `grep -rn "recommended" libexec/ bin/` returning zero functional
  consumers (XACA-1070-001). `"mandatory"` is enforced: it removes the
  choice rather than merely suggesting one.

**Single source of truth for reading this flag:**
`libexec/lib/mandatory-teams.sh` — every consumer (wizard, upgrade backfill,
doctor check) sources this lib rather than re-parsing `registry.json`
independently, so they cannot silently disagree about which teams are
mandatory or what "provisioned on this host" means. See that file's header
comment for the full contract (`atf_mandatory_teams`, `atf_is_mandatory_team`,
`atf_team_provisioned`).

**Adding a mandatory team:** set `"mandatory": true` on its `registry.json`
entry. Do not hard-code the team's id anywhere else — every consumer of the
mandatory set is expected to go through `mandatory-teams.sh` and treat the
list as data, not as a known, enumerable set of ids.

## Usage

### Install a Team

```bash
../../libexec/installers/install-team.sh <team-id>
```

### List Available Teams

```bash
../../libexec/installers/install-team.sh
```

### Validate Team Definitions

```bash
../../libexec/installers/test-install-team.sh
```

## Adding a New Team

See: `../../docs/ADDING_A_TEAM.md`

**Quick Steps:**
1. Create `<team-id>.conf` in this directory
2. Add entry to `registry.json`
3. Run `test-install-team.sh`
4. Install with `install-team.sh <team-id>`

## Team Categories

| Category | Description |
|----------|-------------|
| `platform` | Platform-specific dev teams (iOS, Android, Firebase) |
| `infrastructure` | Infrastructure and frameworks (Academy, DNS) |
| `project` | Project-based full-stack teams (Freelance) |
| `coordination` | Cross-platform coordination (MainEvent) |
| `strategic` | Planning, legal, research (Command, Legal, Medical) |

## Design Principles

- **Data-driven**: Teams are configuration, not code
- **Simple format**: Shell-sourceable .conf files
- **Generic installer**: Same logic for all teams
- **Easy to add**: Just create a .conf file and registry entry
- **Testable**: Validate all teams without installing

---

For detailed documentation, see `../../docs/TEAM_CONFIGURATION.md`
