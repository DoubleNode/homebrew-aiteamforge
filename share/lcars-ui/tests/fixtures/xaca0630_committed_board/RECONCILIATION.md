<!--
  RECONCILIATION.md
  DoubleNode Dev-Team Infrastructure (AITeamForge)

  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
-->

# XACA-0630 Committed Board Fixture Reconciliation — XACA-0952 Blocker A

**File:** `academy-board.json` (this directory)
**Consumer:** `lcars-ui/tests/test_xaca0630_parity.py` → `TestFixtureBoardParity`
**Replaces:** the former `TestLiveBoardParity`, which read
`kanban/academy-board.json` directly. That file is gitignored (see
`.gitignore`), so it never exists on a CI checkout — all 3 of that class's
tests were unconditionally red on GitHub Actions
(`RuntimeError: kb-variance failed (rc=1): 'Error: board file not found: ...'`),
run 32882458626.

---

## Design constraint: this fixture must not become a 5th instance of XACA-0968

The first draft of this fixture sampled real `(points, timeWorkedMs)` pairs
from the live board (32 items, 8 per spec §5 bucket, `random.seed(42)`) to
get non-round, realistic ratios. That draft was **rejected** after empirical
testing (see below) because it silently reproduced the separately-tracked
XACA-0968 jq `round2` bug across nearly every field, not just the 4 tests
XACA-0952 deliberately scoped that bug to.

**What XACA-0968 actually does, verified directly (not inferred):** on the
affected jq versions, `round2` is not "slightly wrong" — it's an *identity
function*. `. * 100 as $s | ($s | floor) as $f | ...` parses as
`. * (100 as $s | ($s | floor) as $f | ...)`, and the parenthesized
subexpression evaluates using only the literal `100` regardless of the real
input, always yielding `1` — so the outer multiplication returns the
*original, completely unrounded* value. That is invisible whenever the raw
value is already exact to ≤2 decimal digits (round2 doing nothing changes
nothing), and a real CLI/server mismatch whenever it isn't. A fixture built
from raw production timestamps has long, non-terminating decimal ratios on
almost every field — verified locally: it produced 15 field mismatches
(every `handicap`/`median`/`sumActualHours` in every bucket and globally),
not the 4 the real CI run reported for the *existing* tests this bug already
affects.

**Fix:** every eligible item in this fixture uses the **same fixed ratio,
`2.0`** (`timeWorkedMs = points * 2.0 * 3600000`), and `points` values are
chosen on a **0.25 (quarter-hour) grid**. This guarantees, by construction:

- `sumEstimatedHours` (= Σ points) stays on the 0.25 grid → ≤2 decimals.
- `sumActualHours` (= 2.0 × Σ points) stays on the (coarser) 0.5 grid → ≤1 decimal.
- `handicap` (= sumActual / sumEstimated) = `2.0` exactly, for every bucket
  and globally — the ratio cancels out of the weighted average by
  construction, regardless of how many items or what their individual
  `points` are.
- `median` = `2.0` exactly — every eligible item shares the identical ratio,
  so the sorted-ratios list is constant regardless of `n` being odd or even.

None of these values ever need real rounding, so `round2` being a no-op
under the XACA-0968 bug is indistinguishable from `round2` working
correctly. This fixture is fully decoupled from that bug: verified by
running the full suite with a jq binary that reproduces the bug (jq 1.7.1,
matching GitHub Actions' ubuntu-latest image) substituted on `PATH` —
`TestFixtureBoardParity` passes under BOTH jq 1.8.1 (this machine) and the
substituted buggy 1.7.1, while the 4 already-known XACA-0968 tests correctly
flip to `xfailed` under the latter and nothing else in the file changes
outcome. See the PR description for the exact substitution method.

## What this still preserves from the real board

`points` values (0.25 through 20.0, `FIX-CI-001`..`FIX-CI-032`) span all
four spec §5 buckets, INCLUDING the exact boundary values (`1.0`, `4.0`,
`8.0`) that separate them, and range across two orders of magnitude —
structurally the same shape a live board has (many items, wide magnitude
spread, all buckets populated), just without carrying real project content
(`id`/`title`/`description`/`epicName`/timestamps are all synthetic
`FIX-CI-NNN` / generic placeholders) or entangling this test with a
different, already-tracked bug.

## Exclusion + non-completed coverage

The live board's `TestLiveBoardParity` tests never asserted anything about
exclusion reasons or non-completed items — those are covered elsewhere by
`TestExcludedReasonClassification` against small synthetic fixtures. This
file adds a modest amount of that same variety (`FIX-CI-090`..`FIX-CI-099`:
2× `no_estimate`, 2× `no_time`, 2× `both_missing`, and 4 non-`completed`
items in various statuses) purely for structural realism — a live board
always has this mix. These items are excluded (or silently ignored) before
reaching `round2`, so they carry no cleanliness constraint of their own.
`TestFixtureBoardParity` asserts the same two things the live-board tests
asserted: CLI==server field-for-field parity, and the four buckets present
in order — not specific exclusion counts (that would duplicate
`TestExcludedReasonClassification`'s job).

## Measured output (informational, not asserted directly by the test)

Run directly with `kb-variance --json --board-file
lcars-ui/tests/fixtures/xaca0630_committed_board/academy-board.json`:

```
eligible: 32
excluded: {no_estimate: 2, no_time: 2, both_missing: 2, total: 6}
global: {handicap: 2, median: 2, sumEstimatedHours: 168, sumActualHours: 336}
buckets:
  <=1h  n=8  handicap=2  median=2  sumEstimatedHours=5      sumActualHours=10
  1-4h  n=8  handicap=2  median=2  sumEstimatedHours=19.5   sumActualHours=39
  4-8h  n=8  handicap=2  median=2  sumEstimatedHours=46.75  sumActualHours=93.5
  >8h   n=8  handicap=2  median=2  sumEstimatedHours=96.75  sumActualHours=193.5
```

These values are not hardcoded into the test (the test compares CLI output
to server output, not to a hardcoded expectation) — they're recorded here so
a future reader can sanity-check a fixture refresh against a known-good
baseline, and can see at a glance why every value is already exact to ≤2
decimals (the point of the ratio=2.0 / 0.25-grid design above).
