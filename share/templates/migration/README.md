# Migration Templates

This directory contains templates and reference data used by the aiteamforge migration system.

## Files

### `path-mappings.json`

Defines the mapping between old manual installation paths and new Homebrew-managed paths.

**Structure:**
- `mappings`: Old → new path mappings for different components
- `preserve`: Lists of files/directories that MUST be preserved during migration
- `skip_migration`: Lists of files that should NOT be migrated (will be replaced)
- `launchagents`: LaunchAgent files that need path updates
- `shell_integration`: Shell config patterns that need updating

**Usage:**

The migration scripts use this template to:
1. Identify what user data to preserve
2. Determine what framework files to skip
3. Update paths in LaunchAgents and shell configs
4. Validate migration completeness

**Critical Data:**

The following are considered CRITICAL and must never be lost:
- `kanban/*-board.json` - Kanban board data
- `kanban/*.md` - Plan documents
- `config/secrets.env` - User secrets
- `config/machine.json` - Machine configuration
- `claude/settings.json` - Claude Code settings
- `claude/agents/` - Agent configurations

**Modification:**

If you add new components that need migration:
1. Add the path mapping to `mappings`
2. Add critical files to `preserve.critical_data`
3. Add framework files to `skip_migration.framework_files`
4. Update `aiteamforge-migrate.sh` to handle the new component

## Migration Workflow

1. **Check**: `aiteamforge migrate --check`
   - Analyzes current installation
   - Identifies components
   - Calculates risk score
   - Recommends proceed/review/fix

2. **Dry Run**: `aiteamforge migrate --dry-run`
   - Shows what would be migrated
   - No changes made
   - Safe preview

3. **Migrate**: `aiteamforge migrate`
   - Creates backup
   - Migrates user data
   - Updates paths
   - Validates installation

4. **Rollback**: `aiteamforge migrate --rollback`
   - Restores from backup
   - Reverses migration
   - Safe undo

## Safety Features

- **Full Backup**: Entire installation backed up before migration
- **Verification**: File counts compared before/after
- **Dry Run**: Preview changes without making them
- **Rollback**: Undo migration from backup
- **Preserve Original**: Never deletes ~/aiteamforge (user decides when safe)
- **Logging**: Complete log at ~/.aiteamforge/migration.log

## Exit Codes

### migrate --check
- `0`: Safe to migrate
- `1`: Issues found (review recommended)
- `2`: Critical issues (not recommended)
- `3`: Invalid installation

### migrate
- `0`: Migration successful
- `1`: Migration failed
- `2`: Pre-migration check failed
- `3`: Rollback successful

## Example Usage

```bash
# Check if migration is safe
aiteamforge migrate --check

# Preview migration
aiteamforge migrate --dry-run

# Perform migration
aiteamforge migrate

# Verify migration
aiteamforge doctor

# Rollback if needed
aiteamforge migrate --rollback
```

## Troubleshooting

### "No aiteamforge installation found"
Use `--old-dir` to specify custom location:
```bash
aiteamforge migrate --old-dir /path/to/aiteamforge
```

### "Insufficient disk space"
Migration requires ~3x the installation size (original + backup + new).
Consider using `--skip-backup` (not recommended) or free up space.

### "Migration check found critical issues"
Fix the issues reported by `migrate --check`, then run check again.
Or use `--force` to proceed anyway (use with caution).

### "Validation failed"
Run `aiteamforge doctor` to see specific issues.
Some issues may require manual configuration.

### "Need to rollback"
```bash
# Rollback to most recent backup
aiteamforge migrate --rollback

# Rollback to specific backup
aiteamforge migrate --rollback-from ~/.aiteamforge/migration-backups/2026-02-17_103045
```

## Post-Migration

After successful migration:

1. **Restart terminal** (new shell integration)
2. **Run `aiteamforge doctor`** (verify installation)
3. **Run `aiteamforge start`** (start services)
4. **Test kanban boards** (verify data intact)
5. **Test agent workflows** (verify configs work)

Only after verification:
6. **Manually delete** `~/aiteamforge/` (if desired)
7. **Keep backup** in `~/.aiteamforge/migration-backups/` (just in case)

## Architecture

### Before Migration (Manual)
```
~/aiteamforge/                  (git repo with everything)
  kanban/                    (user data)
  config/                    (user configs)
  claude/                    (agent configs)
  kanban-helpers.sh          (framework script)
  academy-startup.sh         (framework script)
  lcars-ui/                  (framework code)
  ... (everything mixed together)
```

### After Migration (Homebrew)
```
/opt/homebrew/opt/aiteamforge/  (framework code - Homebrew-managed)
  libexec/
    commands/                (aiteamforge commands)
    lib/                     (shared libraries)
  share/                     (templates, assets)

~/.aiteamforge/                 (user data - persists across updates)
  kanban/                    (preserved)
  config/                    (preserved)
  claude/                    (preserved)
  teams/                     (preserved)
  migration-backups/         (safety backups)
```

### Benefits
- **Framework updates** via `brew upgrade aiteamforge`
- **User data preserved** across updates
- **Clean separation** of framework vs user data
- **Multi-machine** easier with Homebrew
- **Rollback** support if migration fails

---

**Last Updated:** 2026-02-17
**Version:** 1.0.0
