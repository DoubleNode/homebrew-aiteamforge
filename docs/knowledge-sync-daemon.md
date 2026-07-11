# Knowledge Sync Daemon (XACA-0749 / XACA-0761)

Automated cross-machine sync for the shared `~/knowledge` git clone. Part of
EPIC-0047 (knowledge system fleet-wide).

## What it does

`kb-knowledge-sync.sh` runs `git pull --rebase` then `git push` against
`~/knowledge` on a timer, so knowledge entries authored on one fleet machine
propagate to the rest of the fleet without anyone remembering to pull or
push. It is a **best-effort background job**, not a guaranteed-consistency
system.

## Design philosophy: degrade gracefully

The script exits `0` in essentially every normal *and* degraded case, so
launchd never marks the job as failed and never leaves a wedged tree:

| Condition | Behaviour |
|-----------|-----------|
| `~/knowledge` is not a git repo (or missing) | Logged no-op, exit 0 |
| Another sync already running (lock held) | Skip, exit 0 |
| Working tree dirty / mid-rebase / mid-merge | Skip (no stash — a human is mid-edit), exit 0 |
| `pull --rebase` hits a conflict | `git rebase --abort` → tree restored to pre-sync HEAD, failure logged, exit 0 |
| `push` rejected / offline / no auth | Warning logged, exit 0 (retried next tick) |
| No upstream tracking branch | Logged no-op, exit 0 |
| Bad CLI usage (too many args) | **Non-zero** (the only failure exit) |

It never `push --force`es and never auto-resolves a conflict.

This is why the daemon is safe to ship *ahead of* its preconditions (an
`~/knowledge` clone with fleet GitHub auth wired up — see
[MULTI_MACHINE.md](MULTI_MACHINE.md) and [SETUP_WIZARD.md](SETUP_WIZARD.md)):
on machines where `~/knowledge` is still a plain directory with no
credentials, it simply no-ops every tick and starts doing real work the
moment a real clone + auth appear.

## Configuration

Repo path resolves in this order:

1. First positional arg to the script
2. `$KB_KNOWLEDGE_REPO` env var
3. `$HOME/knowledge` (default)

Other env vars: `KB_KNOWLEDGE_SYNC_LOCK_DIR`,
`KB_KNOWLEDGE_SYNC_LOCK_STALE_SECONDS` (default 3600s — 2x the interval).

## Installation

The installer lays down the script under `$AITEAMFORGE_DIR/scripts/` (default
`$AITEAMFORGE_DIR` is `~/.aiteamforge`) and renders a LaunchAgent plist from
`share/templates/kanban/knowledge-sync-plist.template` — the same
`{{AITEAMFORGE_DIR}}`-substitution pattern used for the other kanban
LaunchAgent templates (`backup-plist.template`, `lcars-health-plist.template`).
This happens automatically as part of `brew install aiteamforge` /
`brew upgrade aiteamforge`; there is no separate command to run.

The rendered plist is installed at
`~/Library/LaunchAgents/com.aiteamforge.knowledge-sync.plist` with:

```xml
<key>Label</key>
<string>com.aiteamforge.knowledge-sync</string>
<key>ProgramArguments</key>
<array>
    <string>/bin/zsh</string>
    <string>{{AITEAMFORGE_DIR}}/scripts/kb-knowledge-sync.sh</string>
</array>
```

matching the `com.aiteamforge.*` label convention used by the other kanban
LaunchAgents (`com.aiteamforge.kanban-backup`, `com.aiteamforge.lcars-health`,
`com.aiteamforge.cr-confluence-poller.<team>` — see
[USER_GUIDE.md](USER_GUIDE.md) § "LaunchAgents (Background Services)").

> **Fleet status:** as of XACA-0761 the daemon script and plist template are
> mirrored into this tap and ship with the formula, but they have not yet
> been rolled out to consumer machines (M1Pro / M4Mini) — that fleet deploy
> + live round-trip verification is tracked separately (XACA-0761-007) and
> has not run yet. Until that deploy completes, cross-machine `~/knowledge`
> sync on fleet machines remains **manual** — run the same two commands the
> daemon automates by hand from `~/knowledge`:
> ```bash
> cd ~/knowledge && git pull --rebase && git push
> ```

## Operating

- **Interval:** every 1800s (30 min), plus once at load (login/reboot).
- **Logs:** `$AITEAMFORGE_DIR/logs/knowledge-sync.log` (each line tagged
  `[kb-knowledge-sync]` with a UTC timestamp and the run outcome). The plist's
  `StandardOutPath`/`StandardErrorPath` render from `{{LOG_DIR}}` →
  `$AITEAMFORGE_DIR/logs`.

  Log location & rotation: the installer (`install-kanban.sh`) runs
  `mkdir -p "$AITEAMFORGE_DIR/logs"` immediately before loading the agent, so
  the `StandardOutPath` parent always exists (launchd does not create parent
  dirs itself). This is the same `$AITEAMFORGE_DIR/logs/` directory the sibling
  `com.aiteamforge.auto-upgrade` and `com.aiteamforge.cellar-watch` agents log
  to. Per-run output is a handful of lines, so there is no size concern; the
  file is not auto-rotated — if you want it trimmed periodically, add a
  `newsyslog`/`logrotate` entry or clear it by hand.
- **Check status:** `launchctl list com.aiteamforge.knowledge-sync`
- **Run once by hand:** `bash $AITEAMFORGE_DIR/scripts/kb-knowledge-sync.sh`
- **Disable:**
  ```bash
  launchctl unload ~/Library/LaunchAgents/com.aiteamforge.knowledge-sync.plist
  rm ~/Library/LaunchAgents/com.aiteamforge.knowledge-sync.plist
  ```

## Conflict recovery

If the log shows `rebase-aborted`, the sync hit a conflict between local and
remote history and backed out cleanly — **your tree is at its pre-sync HEAD,
nothing is lost, and nothing was pushed**. Resolve it by hand from
`~/knowledge`:

```bash
cd ~/knowledge
git status                 # confirm clean, on your branch, at pre-sync HEAD
git pull --rebase          # rebase interactively, resolve conflicts
# ... fix conflicts, git add, git rebase --continue ...
git push
```

The daemon will resume clean syncing on the next tick once history is linear
again.

## See also

- [MULTI_MACHINE.md](MULTI_MACHINE.md) — general fleet topology and
  auto-discovery (kanban-board sync only today; does not yet cover
  `~/knowledge`).
- [USER_GUIDE.md](USER_GUIDE.md) § "LaunchAgents (Background Services)" —
  full list of installed LaunchAgents and their labels.
