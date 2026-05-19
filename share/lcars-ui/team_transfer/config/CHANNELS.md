# Channel Configuration Reference

**Location:** `lcars-ui/team_transfer/config/`
**Purpose:** Canonical reference for channel taxonomy, verifier semantics, and team config authoring.
**Related:** [ADR Channel Split](../../../kanban/plans/XACA-0488/ADR-channel-split.md) · [channels.py](../channels.py) · [finance.yaml](finance.yaml)

---

## Channel Taxonomy

| Channel | Verifier Class | AITeamForge Carries | Runbook Step | Description |
|---------|---|---|---|---|
| `git` | varies by .gitignore | Yes | auto rsync | VCS-tracked files; handled by `domain_git` (respects .gitignore) |
| `aiteamforge_product` | PRESENT | Yes | auto rsync | Installer-owned product files (`~/dev-team/{team}/`, `~/{team}/.claude/agents/`) — presence-only check |
| `user_state` | Mixed: EXACT / PRESENT | No | explicit rsync | Claude memory, authored knowledge, session logs — split by mutability |
| `export_kanban` | PRESENT / SCHEMA | No | auto rsync | Kanban tree (`kanban/`), worktrees listing, lock files |
| `export_database` | SCHEMA | No | explicit scp/rsync | SQLite databases (`data/*.db`) — structural-integrity verification |
| `secrets_export` | varies | No | explicit scp | Env files, credential stores, `secrets/` directory |
| `icloud_excluded` | PRESENT | No | skip | Files archived to iCloud; audit silently skips (should not exist locally) |

---

## Deprecated Aliases

| Old Name | New Name | Sunset |
|---|---|---|
| `aiteamforge` | `aiteamforge_product` | Next sprint (XACA-0489) |
| `export` | `export_kanban` | Next sprint (XACA-0489) |

**Deprecation behavior:** `channels.AITEAMFORGE` and `channels.EXPORT` emit a single `DeprecationWarning` on first access. Code that reads the alias resolves to the new constant value. Team YAML configs using old names still work but log a warning; they are NOT automatically upgraded.

---

## Per-Channel Verifier Semantics

### `aiteamforge_product`
- **Carried by AITeamForge installer:** Yes
- **Verifier class:** PRESENT
- **Logic:** Confirm file/directory exists at path. No SHA hash check.
- **Why no EXACT:** Installer mutates these files on destination after update; any hash mismatch would be a false-positive.
- **Probe:** File existence only.

### `user_state`
- **Carried by AITeamForge installer:** No
- **Verifier class:** Mixed — EXACT for authored content; PRESENT for session logs
- **Logic:**
  - `~/.claude/projects/<UUID>/memory/MEMORY.md` and `~/knowledge/agents/<persona>/` → EXACT (SHA in manifest)
  - Session `.jsonl` files → PRESENT (they churn during normal operation)
- **Why the split:** Authored memory is stable; session logs are ephemeral and always differ after re-run.
- **Probe:** SHA for memory files; existence check for session logs.
- **Runbook:** Requires explicit `rsync` after generator step (see below).

### `export_kanban`
- **Carried by AITeamForge installer:** No
- **Verifier class:** Mixed — PRESENT for lock files; SCHEMA for board JSON
- **Logic:**
  - `kanban/board.json` (and per-team variants) → SCHEMA (probe captures `item_ids`; verifier confirms all IDs present)
  - Lock files, worktrees listing → PRESENT (content churns; not portable)
- **Why mixed:** Board is a relational snapshot; locks are transient markers.
- **Probe:** Board SCHEMA (table structure + captured item IDs); lock file existence.

### `export_database`
- **Carried by AITeamForge installer:** No
- **Verifier class:** SCHEMA
- **Logic:** Run `probe_db()` / `compare_probes()` — confirm table names, row counts, column presence match manifest.
- **Why SCHEMA not EXACT:** Database binary format is platform-dependent; structural integrity is what matters.
- **Probe:** SQLite metadata (`.tables`, column schema, row counts).
- **Runbook:** Requires explicit `scp`/`rsync` before final verifier pass (see below).

### `secrets_export`
- **Carried by AITeamForge installer:** No
- **Verifier class:** Varies (PRESENT for most; SCHEMA for sensitive structured files)
- **Logic:** Existence check. No hash; secrets are environment-specific and should never be identical across machines.
- **Probe:** File existence only.

### `icloud_excluded`
- **Carried by AITeamForge installer:** No
- **Verifier class:** PRESENT
- **Logic:** Confirm file DOES NOT exist (archived to iCloud). If found, log a debug note and skip.
- **Probe:** Explicit non-existence check (inverse of PRESENT).

---

## Authoring a Team YAML

### Required top-level keys

```yaml
team: "<team-name>"
home_relative_root: "<relative/path/from/home>"
board_filename: "<team>-board.json"
ticket_prefix: "XTEAM-"
claude_project_dir_name: "-Users-<user>-<relative-path-with-slashes-as-dashes>"
databases:
  - path: "{home}/{root}/data/<name>.db"
    cls: schema
defaults:
  rules:
    - pattern: "<glob>"
      channel: "<channel-name>"
  icloud_excluded:
    - "<glob>"
overrides: []
```

### MANDATORY: Claude auto-memory in every team YAML

Every team YAML **must** include the following two rules in its `defaults.rules`
list (under `# ----- USER_STATE ... -----`).  Replace `{claude_project_dir_name}`
with the team's actual encoded project dir name (see `claude_project_dir_name`
top-level key):

```yaml
- pattern: "{home}/.claude/projects/{claude_project_dir_name}/*"
  channel: user_state
- pattern: "{home}/.claude/projects/{claude_project_dir_name}/**"
  channel: user_state
```

`finance.yaml` is the canonical example — see lines 41-44.  If these rules are
omitted, the team's MEMORY.md and agent memory files are NOT captured in the
Export/Import manifest and will be lost on a machine transfer.

The backup side (kanban-backup.py, XACA-0207-002) discovers memory dirs
automatically via `get_team_memory_dir()` from `aiteamforge_paths.py` — no
YAML change is needed for backup coverage.  The YAML rules above are only
required for the Export/Import transfer pipeline.

---

### Channel selection decision tree

1. **Is the path carried by AITeamForge installer?** (e.g., `~/dev-team/{team}/`, `~/{team}/.claude/agents/`)
   → `aiteamforge_product`

2. **Is it Claude memory, authored knowledge, or session logs?** (e.g., `~/.claude/projects/<UUID>/memory/`, `~/knowledge/agents/<persona>/`, `.jsonl` session logs)
   → `user_state`

3. **Is it a SQLite database?** (e.g., `data/*.db`)
   → `export_database`

4. **Is it kanban/worktrees state?** (e.g., `kanban/`, `worktrees/`, lock files)
   → `export_kanban`

5. **Is it env files, credentials, or secrets?** (e.g., `.env`, `.env.*`, `secrets/`)
   → `secrets_export`

6. **Is it sensitive docs archived to iCloud?** (e.g., `docs/statements/`, `docs/paystubs/`)
   → `icloud_excluded`

7. **Otherwise** (code, config, documentation, project files)
   → `git` (respects .gitignore via `domain_git`)

### Token substitution

Pattern strings support four tokens (resolved at load time):

- `{home}` — User home directory (e.g., `/Users/darrenehlers`)
- `{root}` — `home_relative_root` value (e.g., `finance/personal`)
- `{team}` — Team name (e.g., `finance`)
- `{claude_project_dir_name}` — Claude project UUID slug (e.g., `-Users-darrenehlers-finance-personal`)

Example:
```yaml
- pattern: "{home}/{root}/kanban/*"
  channel: export_kanban
# Resolves to: /Users/darrenehlers/finance/personal/kanban/*
```

---

## Migration Path for Existing Configs

### Three-step recipe

**Step 1: Rename `aiteamforge` → `aiteamforge_product` + `user_state`**

For each rule with `channel: aiteamforge`:
- If the pattern matches installer-carried paths (`dev-team/{team}/`, `finance/.claude/agents/`) → rename to `aiteamforge_product`
- If the pattern matches user-authored paths (`~/.claude/projects/<UUID>/memory/`, `~/knowledge/agents/`) → rename to `user_state`

Example (finance.yaml lines 30–64):
```yaml
# Before:
- pattern: "{home}/dev-team/{team}/*"
  channel: aiteamforge      # ← old
- pattern: "{home}/.claude/projects/{claude_project_dir_name}/*"
  channel: aiteamforge      # ← old

# After:
- pattern: "{home}/dev-team/{team}/*"
  channel: aiteamforge_product  # ← new
- pattern: "{home}/.claude/projects/{claude_project_dir_name}/*"
  channel: user_state           # ← new
```

**Step 2: Rename `export` → `export_kanban` + `export_database`**

For each rule with `channel: export`:
- If the pattern matches kanban/worktrees paths (`kanban/`, `worktrees/`) → rename to `export_kanban`
- If the pattern matches database paths (`data/*.db`) → rename to `export_database`

Example:
```yaml
# Before:
- pattern: "{home}/{root}/kanban/*"
  channel: export      # ← old
- pattern: "{home}/{root}/data/*"
  channel: export      # ← old

# After:
- pattern: "{home}/{root}/kanban/*"
  channel: export_kanban      # ← new
- pattern: "{home}/{root}/data/*"
  channel: export_database    # ← new
```

**Step 3: Verify and test**

```bash
# Verify the YAML parses
python3 -c "from team_transfer import channels; cfg = channels.load_team_config('<team>'); print('✓ Config parsed')"

# Run the test suite
python3 -m pytest tests/team_transfer/test_migration_channels.py -v
```

---

## Runbook Operator Deltas

When migrating with the new channels, two manual steps are added. Run these **after** the standard `python3 -m team_transfer.generator` step but **before** the final verifier pass.

### Step 1: `user_state` channel — explicit rsync of authored files

After the generator step creates the destination structure, manually transfer authored memory and knowledge. Session logs (`.jsonl`) are excluded because they churn during normal operation.

```bash
# Sync authored memory (exclude ephemeral session logs)
rsync -avz --include='*/' \
  --include='memory/MEMORY.md' \
  --include='memory/*.md' \
  --exclude='*.jsonl' \
  --exclude='*' \
  <user>@<old-host>:~/.claude/projects/<UUID>/ \
  ~/.claude/projects/<UUID>/

# Sync authored knowledge agents (all files)
rsync -avz \
  <user>@<old-host>:~/knowledge/agents/<persona>/ \
  ~/knowledge/agents/<persona>/
```

**Verification:** After rsync, the verifier confirms `user_state` EXACT hashes match for memory files.

### Step 2: `export_database` channel — explicit transfer of SQLite files

Before running the final verifier, manually transfer the live database files. The verifier's SCHEMA probe confirms structural integrity on destination.

```bash
# Option A: scp (single file)
scp <user>@<old-host>:~/<root>/data/finance.db ~/<root>/data/finance.db

# Option B: rsync (all data/ files with checksum verification)
rsync -avz --checksum \
  <user>@<old-host>:~/<root>/data/ \
  ~/<root>/data/
```

**Verification:** After transfer, run the verifier's SCHEMA pass:
```bash
python3 -m team_transfer.verifier --manifest migration-manifest.json --channel export_database
```

Confirm all `export_database` entries pass SCHEMA.

---

## Per-Team Config Catalog

The transfer toolkit ships one YAML per canonical team plus alias symlinks where two team names share a working_dir.

### Canonical configs (17)

| Team | YAML | Working dir | Board | Prefix |
|---|---|---|---|---|
| finance | finance.yaml | ~/finance/personal | finance-personal-board.json | XFIN- |
| academy | academy.yaml | ~/dev-team | academy-board.json | XACA- |
| mainevent | mainevent.yaml | /Users/Shared/Development/Main Event/dev-team | command-board.json | XCMD- |
| ios | ios.yaml | /Users/Shared/Development/Main Event/MainEventApp-iOS | ios-board.json | XIOS- |
| android | android.yaml | /Users/Shared/Development/Main Event/MainEventApp-Android | android-board.json | XAND- |
| firebase | firebase.yaml | /Users/Shared/Development/Main Event/MainEventApp-Functions | firebase-board.json | XFIR- |
| dns | dns.yaml | /Users/Shared/Development/DNSFramework | dns-board.json | XDNS- |
| legal-coparenting | legal-coparenting.yaml | ~/legal/coparenting | legal-coparenting-board.json | XLCP- |
| medical-general | medical-general.yaml | ~/medical/general | medical-general-board.json | XMED- |
| freelance-doublenode-starwords | freelance-doublenode-starwords.yaml | /Users/Shared/Development/DoubleNode/Starwords | freelance-doublenode-starwords-board.json | XFSW- |
| freelance-doublenode-caravan | freelance-doublenode-caravan.yaml | /Users/Shared/Development/DoubleNode/Caravan | freelance-doublenode-caravan-board.json | XVAN- |
| freelance-doublenode-awaysentry | freelance-doublenode-awaysentry.yaml | /Users/Shared/Development/DoubleNode/AwaySentry | freelance-doublenode-awaysentry-board.json | XFAS- |
| freelance-doublenode-appplanning | freelance-doublenode-appplanning.yaml | /Users/Shared/Development/DoubleNode/appPlanning | freelance-doublenode-appplanning-board.json | XFAP- |
| freelance-doublenode-workstats | freelance-doublenode-workstats.yaml | /Users/Shared/Development/DoubleNode/WorkStats | freelance-doublenode-workstats-board.json | XFWS- |
| freelance-doublenode-lifeboard | freelance-doublenode-lifeboard.yaml | /Users/Shared/Development/DoubleNode/LifeBoard | freelance-doublenode-lifeboard-board.json | XFLB- |
| freelance-liquidstyle-agentbadges-app | freelance-liquidstyle-agentbadges-app.yaml | /Users/Shared/Development/Liquidstyle/AgentBadges-APP | freelance-liquidstyle-agentbadges-app-board.json | XFLA- |
| freelance-liquidstyle-agentbadges-ios | freelance-liquidstyle-agentbadges-ios.yaml | /Users/Shared/Development/Liquidstyle/AgentBadges-IOS | freelance-liquidstyle-agentbadges-ios-board.json | XFLI- |

### Alias symlinks

- `freelance.yaml` → `academy.yaml`
- `command.yaml` → `mainevent.yaml`
- `medical.yaml` → `medical-general.yaml`

---

### Parser quirks

**`databases: []` does NOT work.** The hand-rolled YAML parser in `channels.py::_parse_team_yaml` treats inline `[]` as the literal string `"[]"`, not an empty list. Downstream code calls `.get()` on entries and crashes. Use a bare `databases:` header (no value) — the parser's default `[]` survives. Same quirk applies to `overrides: []` for some code paths.

**Shared-path teams (under /Users/Shared/) need one of two approaches.** The `{home}/{root}` substitution is pure string replacement (no `Path.resolve`), so a `root` like `"../Shared/..."` produces a literal-with-double-dot pattern. Two approaches both work today (chosen per-team during XACA-0521):

- Option A: `home_relative_root: "../Shared/Development/Main Event/..."` — patterns retain `{home}/{root}` tokens; both the file walk and the matcher use the literal `..` form, so they line up. Used by dns and 6 doublenode-freelance.
- Option B: `home_relative_root: ""` — patterns spelled as absolute paths (`/Users/Shared/Development/Main Event/...`). Used by mainevent, ios, android, firebase, and 2 liquidstyle-freelance.

Both approaches validate. Inconsistency is acknowledged; standardization deferred to a follow-up ticket.

**Shared-path teams require explicit `--repo-root` to the generator** because the default falls back to `{home}/{home_relative_root}` and Path.home() != /Users/Shared.

---

## References

- **ADR:** [ADR Channel Split](../../../kanban/plans/XACA-0488/ADR-channel-split.md) — decision context and rationale
- **Implementation:** [channels.py](../channels.py) — channel constants and rule resolution
- **Exemplar:** [finance.yaml](finance.yaml) — production example with all channel types
- **Tests:** `tests/team_transfer/test_migration_channels.py` — channel resolution and verifier semantics
