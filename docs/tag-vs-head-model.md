# Tag-vs-HEAD Model — Decision Note

**Status:** Decided 2026-05-14 · **Origin:** XACA-0506 (follow-up to XACA-0499) · **Recommendation:** Adopt Option 2 (add `head:` block) in a follow-up PR; keep Option 1 (manual `tag:` bump per release) as the stable install path

---

## Problem Statement

`Formula/aiteamforge.rb` installs from a pinned tag (`url …, tag: "vX.Y.Z"`).
`brew install aiteamforge` and `brew test aiteamforge` therefore exercise the
tarball produced from that tag — **never** what's on tap HEAD (`origin/main`).

Tap HEAD routinely drifts past the pinned tag:

| Snapshot | Tap HEAD distance from `tag:` in formula |
|---|---|
| XACA-0499 close (~2026-05-04) | 10 commits past `v0.11.10` |
| XACA-0506 open (2026-05-14) | 10 commits past `v0.11.11` |

When the drift includes new files (e.g. XACA-0494 shipped
`share/scripts/worktree-helpers.sh` *after* v0.11.10), the formula's `test do`
block can't validate them — adding the assertion to the formula on `main`
makes `brew test` fail against `v0.11.10`'s tarball even though the file is
"shipped" in the repo. XACA-0499 worked around this by commenting the
assertion out with a TODO; XACA-0506 was filed to restore it once a tag
bump caught up. That cycle is the symptom.

The general problem: **the formula's stable install path can't see "I'm
on tap HEAD" state**, so new scripts/files added between tags get an
invisible test-coverage gap until the next manual bump.

---

## Options

### Option 1 — Status quo: manual `tag:`/`version:` bump per release

The current cadence. Each release-engineer (or whoever cuts a tag) bumps
`Formula/aiteamforge.rb` `tag:`/`version:` and `VERSION` to match the new tag
in a separate "chore: Release …" commit.

**Pros:**
- No formula churn. Stable install path stays deterministic.
- Zero new infrastructure.
- Easy to reason about — what's installed is exactly what the tag says.

**Cons:**
- Manual step. Forgetting it (which is what happened between v0.11.10 and
  v0.11.11 — tag was cut but VERSION was never bumped, and the formula
  stayed at v0.11.10 for 10 commits) creates exactly the XACA-0506 wart
  this note is about.
- New files shipped on `main` between tags have zero `brew test` coverage
  until the next bump. Authors writing those files have no signal that
  their assertion would fail today.
- Doesn't surface drift — you only notice when a follow-up ticket
  (like XACA-0499 → XACA-0506) is filed against it.

### Option 2 — Add a `head:` block to the formula

Add ~3 lines to `Formula/aiteamforge.rb`:

```ruby
head do
  url "https://github.com/DoubleNode/homebrew-aiteamforge.git", branch: "main"
end
```

Developers can then `brew install --HEAD aiteamforge` to install from tap
HEAD. Critically, this also enables `brew test --HEAD aiteamforge` against
the same target — so the `test do` block exercises files that ship on
`main` even before the next tag.

**Pros:**
- Zero CI work. Pure formula edit.
- Stable install path (`brew install aiteamforge`) is unchanged — the
  pinned tag still wins for production users and for `aiteamforge-doctor`
  consumers on the M3Pro dev box (which per CLAUDE.md must never install
  from the live tap anyway).
- Catches "ships on main but not in last tag" gaps for developers who opt
  in to `--HEAD`. Reviewers of formula-test changes can run
  `brew test --HEAD aiteamforge` locally on a sandbox to verify a new
  assertion before merging.
- Aligns with Homebrew's documented model — `head:` blocks are explicitly
  for "track the trunk branch."

**Cons:**
- Slightly bigger formula. One more thing for new contributors to scan past.
- `--HEAD` installs aren't auto-updated on `brew upgrade` unless the user
  also passes `--HEAD` — so adoption is opt-in and won't naturally close
  the gap for everyone.
- Doesn't *prevent* the v0.11.10→v0.11.11 wart (someone still has to bump
  `tag:` for stable users) — it just makes the test-coverage gap visible
  earlier to whoever's doing the formula-test work.

### Option 3 — CI auto-bump on tag push

GitHub Action in `homebrew-aiteamforge` that fires on `push: tags: ['v*']`:
- Sed-edit `Formula/aiteamforge.rb` `tag:`/`version:` lines to match the
  new tag.
- Sed-edit `VERSION` to match.
- Open a PR titled `chore: Release AITeamForge X.Y.Z` against `main`.

**Pros:**
- Closes the drift completely. Cutting a tag and forgetting to bump the
  formula becomes impossible.
- Self-documenting (every release has a corresponding bump PR).

**Cons:**
- Real CI work — needs a workflow, a bot token with PR-write scope, and
  ongoing maintenance for the workflow itself.
- Doesn't help with the *test-coverage* gap (Option 2's value) — a tag
  is only created *after* the work is committed, so the brew-test gap
  between commit-on-main and tag-push still exists.
- Auto-merge of release PRs is a separate decision (and a separate risk —
  release PRs that auto-merge could break consumers if the tag was cut
  prematurely).

---

## Recommendation

**Adopt Option 2 (add `head:` block) as a follow-up PR; keep Option 1
(manual bump) as the production install path.**

Reasoning:
- The two real costs of the status quo are (a) the test-coverage gap for
  files added between tags, and (b) drift visibility. Option 2 closes (a)
  for developers willing to run `--HEAD`, and the act of `brew install
  --HEAD aiteamforge && brew test --HEAD aiteamforge` becomes a natural
  pre-commit step for anyone editing `test do` — which is what XACA-0506's
  retrospective will recommend anyway.
- Option 3 is correct but expensive — it closes drift entirely but
  requires CI infrastructure we don't have today and doesn't address (a).
  Defer until we accumulate more "we forgot to bump" incidents that aren't
  already caught by the tap-hygiene guard's version-consistency check.

**Scope discipline:** Option 2's `head:` block is **not** part of XACA-0506.
This PR (formula v0.11.10→v0.11.11 + restored assertion) keeps the
assertion-restoration scope tight. A separate follow-up ticket should land
the `head:` block — see "Follow-up Tickets" below.

**Tap-hygiene guard already does some of this work:** The pre-commit
`tap-hygiene-guard` hook now enforces `VERSION == Formula version == Formula
tag` (visible in the XACA-0506 commit output). That's why bumping VERSION
to 0.11.11 alongside the formula tag was *required* for the commit to
land — drift between those three is no longer possible at commit time.
The remaining drift surface is between tap HEAD and the pinned tag,
which is what Option 2 addresses.

---

## Follow-up Tickets

- **XACA-0508**: Add `head:` block to `Formula/aiteamforge.rb` per Option 2.
  Filed as a separate ticket because (a) it's a small formula change
  scoped well outside XACA-0506's "restore assertion" framing, and (b) it
  needs a quick `brew install --HEAD ./Formula/aiteamforge.rb` smoke test
  on a clean sandbox before landing.
- **No ticket needed for Option 3** at this time. Re-evaluate if the
  tap-hygiene guard's version-consistency check ever gets bypassed in a
  way that re-creates the XACA-0506 drift pattern.

---

*Decision note authored under XACA-0506 by the implementing agent.*
