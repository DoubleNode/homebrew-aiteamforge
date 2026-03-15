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
- Themes

**Used by:** Setup wizard, team selection interface

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
