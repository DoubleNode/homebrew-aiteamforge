# Knowledge Sync Daemon (XACA-0749 / XACA-0761 / XACA-1266)

Automated cross-machine sync for the shared `~/knowledge` git clone. Part of
EPIC-0047 (knowledge system fleet-wide).

## What it does

`kb-knowledge-sync.sh` keeps `~/knowledge` converged with the remote on a
timer, so knowledge entries authored on one fleet machine propagate to the
rest of the fleet without anyone remembering to pull or push. It is a
**best-effort background job**, not a guaranteed-consistency system.

**What "sync" means in practice today:** the daemon reliably brings *other
machines'* knowledge to yours. It does not yet reliably send *your own*
authored entries out — see "Known limitation" below before relying on this
for anything you need shared urgently.

## Design philosophy: degrade gracefully, and never touch uncommitted work

The script exits `0` in essentially every normal *and* degraded case, so
launchd never marks the job as failed and never leaves a wedged tree:

| Condition | Behaviour |
|-----------|-----------|
| `~/knowledge` is not a git repo (or missing) | Logged no-op, exit 0 |
| Another sync already running (lock held) | Skip, exit 0 |
| Mid-rebase / mid-merge | Skip entirely (no stash — a human is mid-edit), exit 0 |
| Working tree dirty, upstream has new commits | Fetches (always safe) and fast-forwards if it can; refuses without touching anything if it can't, exit 0 |
| Dirty tree, fast-forward succeeded | Push is still withheld — push always requires a clean tree |
| Clean tree | Fetches, then `git pull --rebase`, as before |
| `pull --rebase` hits a conflict (clean tree) | `git rebase --abort` → tree restored to pre-sync HEAD, failure logged, exit 0 |
| `push` rejected / offline / no auth | Warning logged, exit 0 (retried next tick) |
| No upstream tracking branch | Logged no-op, exit 0 |
| Bad CLI usage (too many args) | **Non-zero** (the only failure exit) |

It never pushes with `--force`, never auto-resolves a conflict, and **never
stashes or otherwise touches a dirty working tree's files** — a fast-forward
either applies cleanly with your uncommitted content untouched, or it
refuses outright and leaves everything exactly as it was.

## Log output reference

Each run logs one or more lines tagged `[kb-knowledge-sync]`, greppable as
`<token>: <detail>`. The tokens you're most likely to see day-to-day:

| Token | What it means for you |
|---|---|
| `converged-ff` | You had uncommitted changes, and the daemon still pulled in new fleet knowledge cleanly — your own changes are untouched. |
| `fetch-only-dirty` | You had uncommitted changes; there was nothing new to pull in anyway. |
| `blocked-ff-conflict` | You had uncommitted changes that collide with something new coming in. Nothing was touched — see "Troubleshooting" below. |
| `blocked-ff-diverged` | You have local commits **and** uncommitted changes, and upstream has moved — the daemon can't reconcile this automatically. See "Troubleshooting" below. |
| `rebased-advanced` | Clean tree — pulled in new fleet knowledge. |
| `already-current` | Clean tree — already up to date, nothing to do. |
| `push-withheld-dirty` | Nothing was pushed this tick because the tree was dirty. **This is normal and expected on a machine where you're actively authoring entries** — see "Known limitation." |
| `synced` | Pushed your locally committed changes successfully. |
| `push-failed` | Push was rejected, or you're offline / not authenticated. Retried automatically next tick. |

> **Version check:** if your log ever shows `skipped-dirty` instead of any
> of the tokens above, this machine is still running a daemon version from
> before XACA-1266 and has not yet received the current release — check for
> a pending `brew upgrade aiteamforge`.

## Troubleshooting

**Log shows `blocked-ff-conflict`:** you have an uncommitted change that
collides with new fleet knowledge (either you both touched the same file,
or you have an untracked file that a new upstream entry also wants to add
at that path). Nothing was changed — your content is intact and HEAD is
unchanged. This clears itself automatically on a later tick once you commit,
move, or remove the local content that's in the way; the daemon will not do
this for you.

**Log shows `blocked-ff-diverged`:** you have local commits ahead of
upstream *and* an uncommitted change, so the daemon can't fast-forward.
Resolve it by hand from `~/knowledge`:

```bash
cd ~/knowledge
git status                 # see what's local vs. what's incoming
git pull --rebase          # reconcile, resolve any conflicts
# ... fix conflicts, git add, git rebase --continue ...
git push
```

**Log shows `rebase-aborted` / `rebase-conflict-aborted`:** the sync hit a
conflict between local and remote history on a clean tree and backed out
cleanly — **your tree is at its pre-sync HEAD, nothing is lost, and nothing
was pushed**. Resolve it the same way as `blocked-ff-diverged` above.

**Log is full of `push-withheld-dirty`:** expected, not a bug — see "Known
limitation" directly below.

## Known limitation: your own entries may not be leaving this machine

Today, authoring a knowledge entry (`kb-knowledge-add` and similar commands)
does not commit it — it lands as an untracked file. The daemon only ever
pushes from a clean tree, so on a machine where you're actively authoring,
the tree is rarely clean and pushes are mostly skipped
(`push-withheld-dirty`). **Pulling other machines' knowledge into yours is
reliable; pushing your own out is not, yet.** Until this is addressed,
periodically commit and push your own authored entries by hand if you need
them to reach the rest of the fleet promptly:

```bash
cd ~/knowledge
git add <your new/changed files>
git commit -m "..."
git push
```

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
> sync on fleet machines remains **manual** — run the same commands the
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

## See also

- [MULTI_MACHINE.md](MULTI_MACHINE.md) — general fleet topology and
  auto-discovery (kanban-board sync only today; does not yet cover
  `~/knowledge`).
- [USER_GUIDE.md](USER_GUIDE.md) § "LaunchAgents (Background Services)" —
  full list of installed LaunchAgents and their labels.
