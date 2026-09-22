# Knowledge Sync Daemon (XACA-0749 / XACA-0761 / XACA-1266 / XACA-1291)

Automated cross-machine sync for the shared `~/knowledge` git clone. Part of
EPIC-0047 (knowledge system fleet-wide).

## What it does

`kb-knowledge-sync.sh` keeps `~/knowledge` converged with the remote on a
timer, so knowledge entries authored on one fleet machine propagate to the
rest of the fleet without anyone remembering to pull, commit, or push. It is
a **best-effort background job**, not a guaranteed-consistency system.

**What "sync" means in practice today:** the daemon reliably brings *other
machines'* knowledge to yours (XACA-1266), **and** it now auto-commits and
sends your own authored entries out too (XACA-1291) — once an entry is
complete and has sat untouched for 15 minutes, the daemon commits it on
your behalf and pushes on the next tick where it's not behind upstream. See
"Outbound: what gets auto-committed" below for exactly which entries
qualify, and "Remaining limitation" for what still needs a manual commit.

## Design philosophy: degrade gracefully, and never touch uncommitted work

The script exits `0` in essentially every normal *and* degraded case, so
launchd never marks the job as failed and never leaves a wedged tree:

| Condition | Behaviour |
|-----------|-----------|
| `~/knowledge` is not a git repo (or missing) | Logged no-op, exit 0 |
| Another sync already running (lock held) | Skip, exit 0 |
| Mid-rebase / mid-merge | Skip entirely (no stash — a human is mid-edit), exit 0 |
| Working tree dirty, upstream has new commits | Fetches (always safe) and fast-forwards if it can; refuses without touching anything if it can't, exit 0 |
| Diverged and dirty, but the "ahead" commits are all the daemon's own unpushed auto-commits | Undoes just those auto-commits (worktree untouched), then integrates normally |
| After integration | Auto-commits any eligible entries (see "Outbound" below), then pushes whenever it has something to send and isn't behind — **dirty tree or clean** |
| Clean tree | Fetches, then `git pull --rebase`, as before |
| `pull --rebase` hits a conflict (clean tree) | `git rebase --abort` → tree restored to pre-sync HEAD, failure logged, exit 0 |
| `push` rejected / offline / no auth | Warning logged, exit 0 (retried next tick) |
| No upstream tracking branch | Logged no-op, exit 0 |
| Bad CLI usage (too many args) | **Non-zero** (the only failure exit) |

It never pushes with `--force`, never auto-resolves a conflict, and **never
stashes or otherwise touches a dirty working tree's files** — a fast-forward
either applies cleanly with your uncommitted content untouched, or it
refuses outright and leaves everything exactly as it was. Auto-commit
builds its commit in a private, disposable index and never runs `git add`,
so it can never sweep up a file you're still mid-edit on.

## Outbound: what gets auto-committed, and what never does

Not every uncommitted file in `~/knowledge` gets picked up. An entry is
only auto-committed if **all** of these hold:

- It's under `agents/`, `subjects/`, or `teams/` (or it's an `INDEX.md`) —
  nothing else in the repo is ever touched.
- It's **complete**: valid frontmatter (id/tier/date/tags, plus
  agent/team where required), the filename matches the frontmatter id, a
  real body, and none of the `kb-knowledge-add` template's placeholder
  markers still present.
- It's **quiescent**: untouched for at least 15 minutes, and no editor
  swap/backup file sitting next to it.
- It doesn't carry the opt-out marker `<!-- knowledge-sync: hold -->` —
  add that line to any entry to keep the daemon from touching it.
- It isn't currently quarantined (see below).
- For an `INDEX.md`: it only adds rows that point at entries which are
  already committed or are being committed in the same tick, and it
  doesn't drop any existing row.

Anything that doesn't qualify yet is logged as `autocommit-held: <path>
(<reason>)` and simply re-checked on the next tick — nothing is lost or
skipped forever except a quarantined or hold-marked entry, and both of
those clear as soon as you edit the file.

**If the pre-commit hook refuses an entry** (`autocommit-refused`), that
specific entry is quarantined by its content hash until you change it —
edit the file (any change releases it) and it will be picked up again. If
the hook refuses without naming which entry, that's `autocommit-hook-error`
— a hook/environment problem, not a bad entry — and the daemon backs off
for 24h.

**Kill switch:** set `KB_KNOWLEDGE_SYNC_AUTOCOMMIT=0`, or create
`~/.aiteamforge/knowledge-sync-autocommit.off`. Either disables auto-commit
(inbound sync keeps working); the sentinel file exists because a
LaunchAgent's environment can't be set with a shell `export`.

## Log output reference

Each run logs one or more lines tagged `[kb-knowledge-sync]`, greppable as
`<token>: <detail>`. The tokens you're most likely to see day-to-day:

| Token | What it means for you |
|---|---|
| `converged-ff` | You had uncommitted changes, and the daemon still pulled in new fleet knowledge cleanly — your own changes are untouched. |
| `fetch-only-dirty` | You had uncommitted changes; there was nothing new to pull in anyway. |
| `blocked-ff-conflict` | You had uncommitted changes that collide with something new coming in. Nothing was touched — see "Troubleshooting" below. |
| `blocked-ff-diverged` | You have local commits (not the daemon's own auto-commits) **and** uncommitted changes, and upstream has moved — the daemon can't reconcile this automatically. See "Troubleshooting" below. |
| `rebased-advanced` | Clean tree — pulled in new fleet knowledge. |
| `already-current` | Clean tree — already up to date, nothing to do. |
| `autocommit: <subject> as <sha>` | The daemon committed one or more of your eligible entries on your behalf. |
| `autocommit-held: <path> (<reason>)` | That entry wasn't committed this tick yet — see "Outbound" above for why. |
| `autocommit-refused` / `autocommit-hook-error` | The pre-commit hook rejected an entry (quarantined) or failed outright (backed off) — see "Outbound" above. |
| `synced` | Pushed your locally committed (including auto-committed) changes successfully. |
| `push-failed` | Push was rejected, or you're offline / not authenticated. Retried automatically next tick. |

> **Version check:** if your log ever shows `skipped-dirty` or
> `push-withheld-dirty` instead of the tokens above, this machine is still
> running a daemon version from before XACA-1266 / XACA-1291 respectively
> and has not yet received the current release — check for a pending
> `brew upgrade aiteamforge`.

## Troubleshooting

**Log shows `blocked-ff-conflict`:** you have an uncommitted change that
collides with new fleet knowledge (either you both touched the same file,
or you have an untracked file that a new upstream entry also wants to add
at that path). Nothing was changed — your content is intact and HEAD is
unchanged. This clears itself automatically on a later tick once you commit,
move, or remove the local content that's in the way; the daemon will not do
this for you.

**Log shows `blocked-ff-diverged`:** you have local commits ahead of
upstream (and they're not just the daemon's own not-yet-pushed
auto-commits — if they were, the daemon would have unwound them itself)
*and* an uncommitted change, so the daemon can't fast-forward. Resolve it
by hand from `~/knowledge`:

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

**Log shows `autocommit-held: <path> (<reason>)`:** that entry isn't
eligible for auto-commit yet — see "Outbound" above for what each reason
means. Most clear themselves automatically (finish editing, wait out the
15-minute quiescence window); a `hold-marker` reason means the entry has
`<!-- knowledge-sync: hold -->` in it and stays local until you remove that
line yourself.

**Log shows `autocommit-refused`:** the pre-commit hook rejected a specific
entry; it's quarantined by content hash until you edit the file (any change
releases it). **`autocommit-hook-error`** means the hook failed without
naming an entry — a broken hook/environment, not a bad entry — and the
daemon backs off 24h; fix the hook rather than the file.

## Remaining limitation: not every entry is auto-committed

Auto-commit only covers `agents/`, `subjects/`, `teams/`, and `INDEX.md`
files that are complete and quiescent (see "Outbound" above) — it will
never touch anything outside that allowlist, or an entry you've marked
`<!-- knowledge-sync: hold -->`. For those, commit and push by hand if you
need them to reach the fleet:

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
