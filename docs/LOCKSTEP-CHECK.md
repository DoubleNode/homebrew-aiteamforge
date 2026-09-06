# Homebrew Tap Mirror Gates

**Which gate blocked your PR, what its verdict actually means, and what to do about it.**

> **This file used to document a single CI job called `tap-lockstep-check`. That job was retired in XACA-0848** because it had been structurally incapable of failing since the XACA-0300 submodule migration. It no longer runs, and nothing you do can make it report. The property it was supposed to enforce is still enforced — from a different place, described below. See [Why `tap-lockstep-check` was retired](#why-tap-lockstep-check-was-retired) for the mechanism.
>
> The filename is retained for now because `docs/homebrew-tap/**` is tap-mirrored and renaming a mirrored file complicates the mirror. The content is current.

---

## Table of Contents

- [Blocked right now? Start here](#blocked-right-now-start-here)
- [The one thing worth knowing: INHERITED is not a block](#the-one-thing-worth-knowing-inherited-is-not-a-block)
- [FAULT is not DIRECTION](#fault-is-not-direction-xaca-1112)
- [The five enforcement points](#the-five-enforcement-points)
- [Bypasses — the complete list](#bypasses--the-complete-list)
- [The ordering rule: mirroring ahead of canonical](#the-ordering-rule-mirroring-ahead-of-canonical)
- [Why `tap-lockstep-check` was retired](#why-tap-lockstep-check-was-retired)
- [Why "matching canonical" is byte equality](#why-matching-canonical-is-byte-equality)
- [Known gaps — do not assume coverage](#known-gaps--do-not-assume-coverage)
- [What has a canonical source](#what-has-a-canonical-source)
- [Running the gates locally](#running-the-gates-locally)

---

## Blocked right now? Start here

Find the line in your CI log that matches, then do the thing in the last column. Nothing else on this page is urgent.

| What the log says | What it means | What you do |
|---|---|---|
| `VERDICT: PASS — owned=0 unattributed=0 inherited=N` | Another ticket mirrored ahead of you. **You are not blocked.** | Nothing. The job passed. |
| `INHERITED  <file>  tap <sha> XACA-NNNN` | That file's drift belongs to **XACA-NNNN**, not you. | Nothing to fix. If the job still failed, it failed on a *different* line — look for `OWNED` or `UNATTRIBUTED`. |
| `INHERITED  <file>  XACA-NNNN declared mirror-ahead, canonical in PR #N` | Same, and the responsible author told you which PR clears it. | **Wait on PR #N**, or merge it first. Do not re-mirror. |
| `FAIL: N drifted file(s) are OWNED by this PR` | You edited a mirrored canonical file and did not mirror it, or you hand-edited the tap copy. | Run `./sync-tap.sh`, commit **inside** `homebrew-tap/` and push it, then commit the outer gitlink bump. Two steps — both required. |
| `FAIL: N drifted file(s) COULD NOT BE ATTRIBUTED` | A drifted file's introducing tap commit has no `XACA-NNNN` in its **subject line**. | Fix that commit's subject if it is yours, or apply the `Tap-Only-Edit: intentional` bypass. This is fail-closed on purpose. |
| `attribute-tap-drift.sh exited 2` | **Environment problem, not a claim about your mirror.** Unresolvable base ref, uninitialized tap checkout, or no `XACA-NNNN` on your branch name or any commit subject. | Read the specific cause in the job log. Usually: put the ticket id in your branch name or a commit subject. |
| `gitlink <sha> is NOT reachable from the tap's origin/main` | Your `homebrew-tap` pointer is on an unmerged side branch. Merging would pin `develop` to a commit consumers cannot fetch. | Merge that tap branch into tap `main` and push, re-run `./sync-tap.sh`, bump the gitlink to the merged SHA. The error names the containing branches for you. |
| `gitlink <sha> does not exist in the tap remote` | Step 1 of the two-step cycle was skipped — the inner commit was never pushed. | `cd homebrew-tap && git push origin main`, then re-push the outer pointer commit. |
| `tap-changelog-completeness` exited 2, "Cannot resolve the inner-tap commit range" | The gate could not see the commits it validates. It refuses to report "nothing to check". | Re-run the job. If it persists, the tap checkout is shallow or the fetch is stale. |
| `[tap-pre-push] ... REFUSED` on `git push` inside `homebrew-tap/` | You are pushing mirrored content to tap `main` whose canonical is not yet on `develop`, and you did not declare it. | Add the trailer: `git commit --amend --trailer 'Tap-Mirror-Ahead: XACA-NNNN (PR #N)'`. See [the ordering rule](#the-ordering-rule-mirroring-ahead-of-canonical). |
| `sync-tap drift on the mainline (CANONICAL-AHEAD / DIVERGED / unmirrored)` on a `push: [develop]` | A push landed drift where canonical moved and the tap did not, a file is unmirrored, or the two sides share no derivable history. | Run `./sync-tap.sh`, commit **inside** `homebrew-tap/` and push it, then commit the outer gitlink bump — correct/safe for these three shapes specifically. |
| `sync-tap drift gate PASSED (tap is ahead of canonical, not behind)` on `push: [develop]` | Drift on the mainline is all `TAP-AHEAD` — a sibling's sanctioned mirror-ahead push whose canonical half has not merged yet. **You are not blocked; this is a `::notice`, not an error.** | Nothing. Self-heals when the named PR merges. **Do not run `./sync-tap.sh`** — see below. |
| `homebrew-tap gitlink is ... BEHIND the latest release` (`tap-gitlink-recency`) | Your gitlink pins a tap commit that predates a release consumers already received. Merging would roll `develop`'s own pointer backward. | `cd homebrew-tap && git checkout main && git pull origin main`, then re-commit the outer gitlink bump at the new tip. |
| `sync-tap drift is TAP-AHEAD only — WAIVED` / preflight #9 blocks with "Releasing NOW would ship that still-open PR's content" | You are cutting a release (`kb-tap-release`) while the tap mirror carries a still-open PR's content. | Wait for that PR to merge (self-heals), or re-run with `--tap-ahead-release="<reason>"` if the pre-merge release is deliberate. **Not the same bypass as the push gate** — see [the five enforcement points](#the-five-enforcement-points). |

**Never "fix" INHERITED or TAP-AHEAD drift by running `./sync-tap.sh`.** That copies your *older* canonical over the sibling's *newer* tap content and destroys their in-flight work to satisfy a gate that already passed (INHERITED, the PR-gate case) or is deliberately not treated as an error on the mainline (TAP-AHEAD, the push-gate case — XACA-1112).

---

## The one thing worth knowing: INHERITED is not a block

The two-step tap workflow lets a session push its inner `homebrew-tap` commit to tap `main` **before** its canonical dev-team change merges to `develop`. From that instant, the tap is legitimately ahead of canonical.

Before XACA-0848, that made every other open PR that advanced the submodule pointer fail `sync-tap-drift` — naming files the PR never touched, with no self-remedy available. The gate detected a real symptom and blamed the wrong PR.

`scripts/attribute-tap-drift.sh` now classifies each drifted file:

| Class | Meaning | Verdict |
|---|---|---|
| `OWNED` | This PR caused it — either it edited the canonical (**rule a**) or the introducing tap commit carries this PR's own ticket id (**rule b**). | **exit 1** — hard fail, as before. |
| `INHERITED` | The introducing tap commit belongs to a *different* ticket. | **exit 0** — pass, with the SHA and ticket named per file. |
| `UNATTRIBUTED` | No introducing commit found, or it carries no `XACA-NNNN` id. | **exit 1** — fail-closed. |

The classifier keys on **ticket identity, not reachability**. Reachability cannot separate the cases: when a sibling pushes to tap `main`, your PR bumps its pointer by committing *on top of* that tip, so the sibling's commit is an ancestor of your `HEAD_TAP_SHA` and sits squarely inside your own pointer range. Both are on `main`; both are in range. Ticket ids separate them; ancestry does not. This is recorded here so nobody re-derives the reachability version and ships it.

**Both rules are load-bearing.** Rule (a) alone misses the tap-only edit (a PR hand-edits the mirror under its own ticket with no canonical change). Rule (b) alone lets "edited canonical, forgot to mirror" pass as INHERITED, because the mirror's last-touching commit belongs to some unrelated older ticket.

Ticket ids for your PR come from the **branch name** and **commit subjects only** — never commit bodies. Bodies routinely cite sibling tickets ("unblocks XACA-0838"), and scanning them would mark a sibling's file OWNED, silently re-blocking the exact innocent PR this exists to unblock.

---

## FAULT is not DIRECTION (XACA-1112)

OWNED/INHERITED/UNATTRIBUTED (above) answer **whose fault** a drifted file is. That is a different question from **which side moved**, and "not my fault" alone is not enough for two consumers that have no PR to blame:

- The mainline `push: [develop]` gate has **no PR at all** to attribute against — `github.base_ref` is empty on a push, so the ticket-id scan that OWNED/INHERITED needs always comes back empty there.
- `kb-tap-release`'s preflight cares about **shipping risk**, not fault. A file can be correctly INHERITED (this release didn't cause it) and still be exactly what must not ship — a still-open PR's mirrored-ahead content, cut into a release before its canonical half merged.

`scripts/attribute-tap-drift.sh --classify-direction` answers the direction question instead, using **blob identity + reachability, never commit dates** (dates are rewritten by rebases and by the tap mirror's own commit timestamps — proven unreliable on the incident that motivated this: a tap commit postdated its canonical counterpart by a day and pointed the wrong way under naive date logic):

| Direction | Meaning | Verdict |
|---|---|---|
| `CANONICAL-AHEAD` | Canonical's own history contains a revision whose blob equals the tap's current blob — canonical moved on, the tap did not catch up. | Blocks. `./sync-tap.sh` is the correct, safe remedy for this direction. |
| `TAP-AHEAD` | The tap's own history (from the pinned gitlink) contains a revision whose blob equals canonical's current blob — the tap moved on (a sanctioned mirror-ahead push), canonical has not caught up yet. | Self-healing. Consumer-dependent whether it blocks — see below. |
| `DIVERGED` | Neither side's current blob is derivable from the other's history (or, ambiguously, both are) — independent edits, or a rewrite severed the lineage. | Blocks. Needs a human; do not assume `./sync-tap.sh` is safe. |
| `NEW` | No tap copy exists at all — direction does not apply. | Blocks. `./sync-tap.sh` is safe here too (nothing to overwrite). |

Unlike the OWNED/INHERITED mode, `--classify-direction` needs **no PR ticket id and no resolvable base ref** — it is a fact about two blobs and two histories, not about whose branch is asking. That is what makes it usable on a `push` event.

**The two consumers route differently on the same classification, and that is deliberate:**

- The **push gate** cannot un-ship a push that already happened, so blocking on TAP-AHEAD there accomplishes nothing but noise — it passes with a `::notice` instead.
- The **release preflight** runs *before* the tag is cut and can actually prevent shipping a still-open PR's content, so it still blocks on TAP-AHEAD by default (waivable — see [bypasses](#bypasses--the-complete-list)).

---

## The five enforcement points

Four CI jobs in `.github/workflows/sync-tap-check.yml`, plus one local hook.

### 1. `sync-tap-drift` (CI) — is the mirror consistent, and whose fault (or direction) is it?

Runs `zsh sync-tap.sh --check`. Clean → pass. Otherwise the verdict depends on the trigger:

- **`pull_request` events** run `scripts/attribute-tap-drift.sh` (no flag) — the OWNED/INHERITED/UNATTRIBUTED fault attribution described above.
- **`push: [develop]` events** run `scripts/attribute-tap-drift.sh --classify-direction` instead (XACA-1112) — the CANONICAL-AHEAD/TAP-AHEAD/DIVERGED/NEW direction classification described in [FAULT is not DIRECTION](#fault-is-not-direction-xaca-1112). Before XACA-1112 this job kept an unconditional hard-fail on push, with no distinction — that is what produced 7 red mainline runs out of 12 over one real incident, all of them TAP-AHEAD and none of them an actual defect.
- The per-file table is published to the job summary **regardless of verdict**, including on a pass. A silent pass would cost the ability to notice the ordering hazard is happening at all.
- Any exit code other than 0, 1, or 2 fails the job. A `case` whose default falls through to success is exactly how this repo has shipped silent-pass gates before.

### 2. `tap-gitlink-reachable` (CI) — is the pointer fetchable by consumers?

`scripts/check-tap-gitlink-reachable.sh` fails any commit whose `homebrew-tap` gitlink is not an ancestor of the tap's `origin/main`.

A gitlink (mode `160000`) is a promise that consumers can fetch that tap commit. The promise is void if the commit lives only on an unmerged side branch. **Originating incident:** PR #711 merged with its gitlink at a tap commit that existed only on `origin/xaca-0803-tap`. `develop` briefly pinned a submodule commit outside the tap mainline; unwinding it needed a manual "reunite forked tap history" merge, and a later pointer bump came within one commit of rolling back XACA-0803's command-injection hardening.

- **Runs on both `pull_request` and `push: [develop]`** — it reads the gitlink from HEAD's own tree, so it needs no base branch. The push trigger is the safety net for the Academy direct-commit-to-`develop` path, which bypasses PR gates entirely.
- **Skips when the pointer is unchanged**, so PRs that merely touch a mirrored canonical file are never affected.
- **Exit codes:** `0` pass or bypassed · `1` verdict FAIL (unreachable, or absent from the tap remote after a proven-complete fetch) · `2` cannot render a verdict (tap uninitialized, no gitlink at that path, fetch failed). `2` is deliberately distinct from `1` so "could not judge" is never mistaken for "judged bad". All three are non-zero in CI.
- The two failure modes are never conflated: *present but off-mainline* names the containing side branches; *absent entirely* gets its own wording, because that means the inner half of the two-step cycle was never pushed.

### 3. `tap-gitlink-recency` (CI) — is the pointer at or ahead of the last release? (XACA-1112)

`scripts/check-tap-gitlink-recency.sh` fails any commit whose `homebrew-tap` gitlink is **behind** the tap's latest semver release tag (`v*.*.*`, compared by tag name via `sort -V` — never by date, for the same reason direction classification avoids dates above). Sibling to `tap-gitlink-reachable`, and neither subsumes the other: **reachable-from-main is not the same question as at-or-ahead-of-the-last-release.** Every ancestor of tap `main` is, trivially, also reachable — including commits from *before* a release that has since shipped.

**Originating incident:** 2026-09-06, four open PRs (#821, #823, #824, #825) each pinned a gitlink whose `VERSION` read `0.20.4` — an ancestor of the `v0.20.5` release commit cut the same day. `tap-gitlink-reachable` passed all four (every one of those commits IS reachable from tap main). Merging any of them as-is would have silently rolled `develop`'s own tap pointer **backward** from `0.20.5` to `0.20.4`.

- **Runs on both `pull_request` and `push: [develop]`**, same rationale as `tap-gitlink-reachable` — it reads the gitlink from HEAD's own tree and the tap's own tags, no base branch needed.
- **No release tags yet** (a fresh tap) passes — nothing to be behind of.
- **Exit codes:** `0` pass, at-or-ahead, or bypassed · `1` verdict FAIL (behind, or diverged from the release tag entirely) · `2` cannot render a verdict. Same three-way discipline as `tap-gitlink-reachable`.

### 4. `tap-changelog-completeness` (CI) — does every tap commit name its ticket?

Every inner-tap commit in the PR's submodule-pointer range must have a matching `XACA-\d+` id listed under `[Unreleased]` in `homebrew-tap/CHANGELOG.md`. Release-cut commits, `Tap-Only-Edit: intentional` commits, pure-CHANGELOG/docs/VERSION edits and empty diffs are auto-skipped.

**Hardened in XACA-0848.** An unresolvable commit range — from a shallow clone, a stale fetch, or a missing object — used to print `no inner-tap commits in range — nothing to check` and **exit 0**, silently disabling the gate. It now validates both range endpoints as real commit objects first and **exits 2** when the range cannot be resolved, distinguishing that from a range that genuinely resolved to zero commits.

This matters beyond its own job: `attribute-tap-drift.sh` rule (b) *consumes* the ticket-id-on-every-tap-commit invariant that this gate enforces. A silently-disabled changelog gate degrades drift attribution into `UNATTRIBUTED`.

### 5. `.githooks/tap-pre-push` (LOCAL hook) — the ordering guard

Refuses a push to tap `main` carrying mirrored content that has no byte-matching canonical on `dev-team/develop`, unless the ahead-mirroring is declared. See [the ordering rule](#the-ordering-rule-mirroring-ahead-of-canonical) for the full contract, and [known gaps](#known-gaps--do-not-assume-coverage) for its coverage limits.

### Also worth knowing about, but not a gate on your PR's own changes

- **`sync-tap-paths-coverage` (CI)** — a structural linter over `sync-tap.sh` itself. Not something a normal PR trips.
- **`kb-tap-release` preflight #9 (LOCAL, release-time only, XACA-1112)** — the release-cut command runs the *same* direction classification as the mainline push gate, but routes it differently: `CANONICAL-AHEAD`/`DIVERGED` block unconditionally (`./sync-tap.sh` is the correct remedy), and `TAP-AHEAD` **also blocks by default** — unlike the push gate, this check runs *before* the tag is cut and can actually prevent shipping a still-open PR's content. Waivable only via `--tap-ahead-release="<reason>"`, which records a `Tap-Ahead-Release: <reason>` trailer on both release commits (auditable) rather than a bare label. See [FAULT is not DIRECTION](#fault-is-not-direction-xaca-1112) for why the two consumers route the same classification differently.

---

## Bypasses — the complete list

Each gate has its own bypass vocabulary. **They are not interchangeable** — the wrong trailer is not a bypass at all.

| Gate | Commit trailer | PR label | Notes |
|---|---|---|---|
| `sync-tap-drift` (attribution, PR path) | `Tap-Only-Edit: intentional` | `tap-only-intentional` | Carried over verbatim from the retired `tap-lockstep-check`, so previously-documented instructions stay valid. Also honoured by `--classify-direction` on the push path. |
| `tap-gitlink-reachable` | `Tap-Gitlink-Skip: <reason>` | `tap-gitlink-skip` | Requires a **written reason**, not a bare "intentional" — bypassing this gate is exactly how the originating incident happened. |
| `tap-gitlink-recency` | `Tap-Gitlink-Behind: <reason>` | `tap-gitlink-behind-intentional` | XACA-1112. Written reason required, same discipline as `tap-gitlink-reachable`'s trailer. |
| `tap-changelog-completeness` | `Changelog-Skip: <reason>` | `changelog-skip` | For genuine no-op tap edits. |
| `tap-pre-push` (local) | `Tap-Mirror-Ahead: XACA-NNNN (PR #N)` | — | Not strictly a bypass; see below. Emergency override: `TAP_MIRROR_ALLOW_AHEAD=1 git push`. |
| `kb-tap-release` preflight #9, TAP-AHEAD only (local, release-time) | N/A — CLI flag, not a commit trailer | — | `--tap-ahead-release="<reason>"`. Recorded as a `Tap-Ahead-Release: <reason>` trailer on both release commits (audit trail), not applied as a bypass to the drift check itself. Does NOT waive CANONICAL-AHEAD or DIVERGED. |

**Trailer matching is exact by design.** Markers are anchored at start-of-line and shape-validated. A misspelling (`Tap-Only-Edits:`, `Tap-Mirror-Aheads:`) does **not** bypass, and a bare `Tap-Mirror-Ahead:` with no ticket and no PR number does not either. A bypass that matches loosely is a universal bypass.

Trailers must sit on their own line, after the commit body:

```
fix: XACA-1234 — short summary

Body paragraph with details.

Tap-Only-Edit: intentional

Co-Authored-By: Claude <noreply@anthropic.com>
```

The **label** paths work only inside GitHub Actions (they read `GITHUB_EVENT_PATH`). If you run a check locally, use the trailer.

---

## The ordering rule: mirroring ahead of canonical

**Mirroring tap content ahead of its canonical source is permitted. It must be declared.**

### The rule

If you push mirrored content to tap `main` before the matching canonical change has merged to `dev-team/develop`, put this trailer on the **inner tap commit**:

```
Tap-Mirror-Ahead: XACA-0838 (PR #716)
```

Both parts are required and both are validated: an `XACA-NNNN` ticket id **and** a `#NNN` PR number, on a line anchored at start-of-line.

```bash
# inside homebrew-tap/
git commit --amend --trailer 'Tap-Mirror-Ahead: XACA-0838 (PR #716)'
git push origin main
```

### What the trailer buys — and who it buys it for

It is **not** a bypass and it does not change any classification. It is machine-readable input to `attribute-tap-drift.sh`.

Without it, a sibling author blocked by your mirror sees:

```
INHERITED    scripts/kb-port-reconcile    tap 233a3320c XACA-0838 — share/scripts/kb-port-reconcile
```

With it, they see:

```
INHERITED    scripts/kb-port-reconcile    XACA-0838 declared mirror-ahead, canonical in PR #716 (tap 233a3320c) — share/scripts/kb-port-reconcile
```

The second version tells them **exactly which PR to wait on** instead of leaving them to go find it at 2am. That is the entire reason declared-ahead mode was chosen: the trailer turns the guard from pure friction into the thing that makes the drift report actionable.

The declaration is strictly additive. Absent or malformed, the report reads exactly as it did before; it can never turn an `OWNED` or `UNATTRIBUTED` file into a pass.

### The override, and when it is legitimate

```bash
TAP_MIRROR_ALLOW_AHEAD=1 git push
```

Precedent: `SKIP_SYNC_TAP_CHECK=1` on the outer hook. It prints a loud warning.

Legitimate uses are narrow:

- The guard cannot verify rather than having found a violation — you are offline, the outer repo is not locatable from this clone, or `develop` is unfetchable. The guard refuses in these cases (exit 2) on purpose, because a guard that allows on "I could not check" is not a guard.
- A genuine emergency where amending the commit is not available.

**Do not use `--no-verify`** — it disables every hook, including unrelated ones.

### The honest cost of declared-ahead mode

Declared-ahead is a **convention enforced at push time**. It prevents *undeclared* ahead-mirroring. **It does not prevent ahead-mirroring itself**, and it is not designed to.

That residual is acceptable for exactly one reason: **attribution already makes ahead-mirroring non-blocking for siblings.** The guard's job is therefore reduced from "prevent the hazard" to "label it". If attribution did not exist, this reduction would be unsafe, and the mode choice would have to be revisited.

Do not read this guard as a guarantee that the tap is never ahead of canonical. It guarantees only that when the tap *is* ahead, a compliant author left a note saying so.

### Why strict mode was rejected as the default

Strict mode — refuse the inner push outright until canonical is already on `develop` — was considered and deliberately not made the default:

1. **It inverts the documented workflow and doubles the PR count.** Today: edit canonical → `sync-tap.sh` → commit and push inner → commit outer pointer → one PR → merge. Under strict, the inner push is refused until canonical merges, forcing: open a canonical PR → merge it → *then* sync and push inner → *then* a **second** outer PR to bump the pointer. That is **two PRs for every tap-touching ticket**.
2. **It turns `develop`'s own CI red.** Strict creates a transient window where `develop` has canonical *ahead of* the tap mirror. During that window `sync-tap-drift`'s `push: develop` trigger fails **on `develop` itself**. Strict trades a cross-PR block for a red mainline, which is not obviously a better trade.

Strict remains available as an opt-in, but enabling it is a separate decision, not a default to drift into.

---

## Why `tap-lockstep-check` was retired

**It could not fail. Not "rarely failed" — could not.**

The mechanism, re-verified before removal:

1. Since the XACA-0300 submodule migration, `homebrew-tap` is a **pure gitlink**. The outer repo tracks zero files beneath it (`git ls-files -s homebrew-tap` → mode `160000`; `git ls-files homebrew-tap/share` → 0 entries).
2. An outer diff of a submodule change therefore lists the **bare path** `homebrew-tap` and never `homebrew-tap/share/...`. Across all 460 commits since the migration, the only `homebrew-tap` path ever appearing in an outer diff is the bare gitlink.
3. `scripts/check-tap-only-edits.sh` built its file list from that outer diff, then opened its main loop with `[[ "$f" != homebrew-tap/* ]] && continue`.
4. The bare token `homebrew-tap` does not match the glob `homebrew-tap/*`, which requires a `/` plus a remainder. **Every iteration `continue`d.** Its entire `FILE_MAP` and `DIR_MIRROR_PREFIXES` machinery was keyed on paths that could no longer occur.
5. The CI job did not even check out the submodule, so it could not have inspected tap content had it wanted to.

It had been vacuously green for its entire post-migration life while appearing, to every reader of every PR, to be enforcing something.

### Why retired rather than rewritten

A range-walking rewrite would need a **fourth** hand-maintained copy of the mirror map — after `sync-tap.sh`, this script's `FILE_MAP`, and `.githooks/pre-push` — which is the exact drift pattern that already required a dedicated structural linter (`check-sync-tap-paths-coverage.sh`) to police the existing three. It would also re-derive, less accurately, what `sync-tap.sh --check` already computes exactly.

A path map answers *"were both sides edited?"*. Byte comparison answers *"are they consistent?"*. The second is the question that matters.

### Where the enforcement reappears

The property at risk was: *a tap-side edit to a mirrored file whose canonical counterpart was not edited in the same PR.*

Under attribution, that scenario produces drift by definition — only one side moved — and the tap commit that last touched the mirror path carries **this PR's own ticket id**. That is **rule (b) → `OWNED` → exit 1**. Same violation, same blocking outcome, derived from the tap's own history rather than a static path map.

The only case genuinely lost is a tap-side edit that leaves the file byte-identical to canonical, which is a no-op and not a violation.

The retirement was gated on proving this: a fixture that hand-edits a mirrored tap file under the PR's own ticket, with the canonical untouched (so rule (a) is false), must exit 1 via rule (b). It does. **A green-but-dead gate is worse than no gate**, so the replacement was demonstrated before the deletion, not after.

### Migration checks that were done

- Both documented bypasses (`Tap-Only-Edit: intentional` trailer, `tap-only-intentional` label) were verified working in `attribute-tap-drift.sh` **before** the job was deleted, so nobody is stranded mid-PR.
- Branch protection was checked, not assumed. Deleting a job that is still a *required* status check leaves every PR permanently stuck on "Expected — waiting for status to be reported". On `DoubleNode/dev-team`, `required_status_checks` is absent from the `develop` protection object entirely and there are no rulesets, so `tap-lockstep-check` was never required and its deletion cannot strand a PR.
- `scripts/check-tap-only-edits.sh` was **deleted**, not left dormant. A dead script invites someone to "fix" it later and reintroduce the duplicate map.

---

## Why "matching canonical" is byte equality

The ordering guard compares git blob object ids — hashes of content alone, so equal ids mean byte-identical files.

**This deliberately contradicts the guidance that a co-change guard beats body-equality for long-diverged mirrors.** Recorded here so a future reviewer does not "correct" it back:

That guidance concerns **long-diverged** mirrors, where equality is permanently false and therefore useless as a signal. These mirrors are **equality-maintained by construction** — `sync-tap.sh` copies bytes, and `sync-tap-drift` already gates on byte equality. Using anything weaker here (co-change presence) would let a mirror push through whose content does not match what `sync-tap-drift` will later *demand*, i.e. the guard and the gate would disagree with each other.

**Equality makes the guard and the gate agree by construction. Co-change would not.**

---

## Known gaps — do not assume coverage

### The ordering guard is per-clone and opt-in

A submodule's hooks live in its own git directory, which **git never transports as content**. There is no commit that installs a hook into someone else's clone. `homebrew-tap/.git` is a gitfile pointing into `.git/modules/homebrew-tap/`, and hooks placed there ship nowhere.

**A machine that has never run `scripts/install-tap-hooks.sh` has no guard, and its pushes look identical to guarded ones.** This is a real coverage gap, not a rounding error.

```bash
bash ~/dev-team/scripts/install-tap-hooks.sh            # install / update
bash ~/dev-team/scripts/install-tap-hooks.sh --check    # report only, writes nothing
```

It is wired into `docs/install-on-new-mac.sh` beside the existing `core.hooksPath` bootstrap, so new machines get it by default. Existing machines must be done by hand.

*(Note: the tap clone sets `core.hooksPath = .githooks`, a git-tracked directory in the tap's own working tree. The installer honours that and adds the installed file to the tap clone's `.git/info/exclude` before writing, so it cannot be swept into a commit by a stray `git add -A`.)*

**Two required follow-ups after XACA-0848 merges:**

1. **Commit the hook into the tap's own tracked `.githooks/`** — where the tap's `core.hooksPath` already points. This is the durable fix: it would ship the guard to every clone and close the gap properly.
2. **Add a report-only CI job in the tap repo on `push: main`** as the backstop for clones that never ran the installer.

Neither was built inside XACA-0848 itself, and the reason is not laziness: creating them means committing into tap `main` while their canonical is still unmerged — precisely the defect this ticket exists to prevent. They land after the PR merges.

### The workflow YAML lint was not run

`actionlint` was not available in the environment where XACA-0848 was implemented, so `.github/workflows/sync-tap-check.yml` has **not** been linted by it. The file does parse successfully via `yaml.safe_load`, and the modified job bodies were exercised with stubbed exit codes, but that is structural validation and not an `actionlint` pass. Treat the YAML as unlinted until someone runs it.

---

## What has a canonical source

**Do not maintain a list here.** This document previously carried a hand-written table of mirror/canonical pairs; it was a fourth copy of a map that already drifts between its existing copies, and it went stale.

The authoritative pairing is defined by the `sync_file` / `sync_dir` calls in `sync-tap.sh`, and it is queryable:

```bash
# Human-readable: what is synced, and what currently drifts
zsh sync-tap.sh --check

# Machine-readable pairing: <STATUS>\t<canonical_repo_rel>\t<tap_rel>
# STATUS ∈ {OK, DRIFT, NEW, MISSING}
zsh sync-tap.sh --check --porcelain
```

Broad strokes, for orientation only — `--porcelain` is the truth:

- `lcars-ui/`, `kanban-hooks/`, `fleet-monitor/server/` — directory mirrors
- `docs/homebrew-tap/` → `homebrew-tap/docs/` — **including this file**
- `scripts/` — mirrored **file-by-file**, not as a tree. A new `scripts/*.sh` is *not* automatically mirrored and needs no two-step tap commit.
- `iterm2_window_manager.py`, `kanban-backup.py`, `claude/tmux.conf` — individual files

`sync-tap.sh` itself is **not** mirrored into the tap.

---

## Running the gates locally

This repo's outer remote is **`dev-team`**, not `origin`. CI uses `origin` for both. Pass `REMOTE_NAME` accordingly.

```bash
REMOTE_NAME=dev-team bash scripts/check-tap-gitlink-reachable.sh
REMOTE_NAME=dev-team bash scripts/check-tap-gitlink-recency.sh
REMOTE_NAME=dev-team bash scripts/attribute-tap-drift.sh                    # fault (OWNED/INHERITED)
REMOTE_NAME=dev-team bash scripts/attribute-tap-drift.sh --classify-direction   # direction (CANONICAL-AHEAD/TAP-AHEAD)
```

From a **worktree** whose tap submodule is uninitialized (common here — worktree submodule init wedges frequently), borrow the main repo's tap object database. The gitlink is still read from *this* worktree's HEAD, and both scripts verify the borrowed checkout actually contains it:

```bash
REMOTE_NAME=dev-team TAP_DIR=~/dev-team/homebrew-tap \
  bash scripts/check-tap-gitlink-reachable.sh

REMOTE_NAME=dev-team TAP_DIR=~/dev-team/homebrew-tap \
  SYNC_TAP_SOURCE_DIR="$PWD" SYNC_TAP_REFERENCE_DIR=~/dev-team \
  bash scripts/attribute-tap-drift.sh
```

**A caution about `sync-tap.sh` from a worktree:** with no flags it references the *main* repo's tap and can report a false green. Always pass `--source-dir` / `--reference-dir` (or the `SYNC_TAP_*` equivalents) when checking a worktree's content.

---

## Related documentation

- **`CONTRIBUTING.md` § "Shared scripts and the canonical source"** — the canonical-source rule, the two-step tap cycle, and the ordering rule in workflow form
- **`docs/homebrew-tap/EDIT-SHARED-WORKFLOW.md`** — `kb-edit-shared`, which makes the correct workflow the easy one
- **`sync-tap.sh`** — the authoritative mirror map and the differ
- **`scripts/attribute-tap-drift.sh`**, **`scripts/check-tap-gitlink-reachable.sh`**, **`scripts/check-tap-gitlink-recency.sh`**, **`.githooks/tap-pre-push`** — each carries a long header explaining its own reasoning and failure modes
- **XACA-0340** — the original lockstep-drift regression class
- **XACA-0300** — the submodule migration that made `tap-lockstep-check` vacuous
- **XACA-0848** — attribution, the reachability gate, the changelog-gate hardening, the retirement, and the ordering guard
- **XACA-1112** — direction classification, the direction-aware push gate and release preflight, and the gitlink-recency gate

---

**Last Updated:** 2026-07-24 (XACA-0848 — rewritten: `tap-lockstep-check` retired, replaced by drift attribution, gitlink reachability, and the ordering guard)
