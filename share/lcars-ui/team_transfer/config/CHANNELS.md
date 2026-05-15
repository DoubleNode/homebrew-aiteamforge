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

## References

- **ADR:** [ADR Channel Split](../../../kanban/plans/XACA-0488/ADR-channel-split.md) — decision context and rationale
- **Implementation:** [channels.py](../channels.py) — channel constants and rule resolution
- **Exemplar:** [finance.yaml](finance.yaml) — production example with all channel types
- **Tests:** `tests/team_transfer/test_migration_channels.py` — channel resolution and verifier semantics
