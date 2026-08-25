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

**Fix, round 1 (superseded — see "Round 2" below):** every eligible item
originally used the **same fixed ratio, `2.0`**
(`timeWorkedMs = points * 2.0 * 3600000`), with `points` on a 0.25-hour grid.
That decoupled the fixture from XACA-0968 (every value already exact to
≤2 decimals), but XACA-0952-034 (PR #767) flagged a second problem with it:
a uniform ratio makes `handicap` (weighted mean) and `median` identical —
`2.0` — in every bucket and globally. A server-side formula bug (e.g.
computing a mean where the spec requires a median) is invisible against
constant input: mean and median of a constant list are the same number by
definition, so `TestFixtureBoardParity` would pass over that bug rather than
catch it.

**Fix, round 2 (current):** `points` stay unchanged (still the 0.25 grid,
still spanning all four buckets and their exact boundaries), but each
item's `timeWorkedMs` now encodes a **distinct, hand-solved per-item ratio**
— 7 chosen values plus one back-solved value per bucket — engineered so
that, simultaneously, for **every** bucket and the global aggregate:

- `handicap` (weighted mean, weighted by `points`) and `median` (of the
  unweighted per-item ratios) are **different exact values**, so a
  mean-vs-median mix-up is observable.
- Neither equals any individual item's own ratio.
- `sumEstimatedHours`, `sumActualHours`, `handicap`, and `median` are all
  *already* exact to ≤2 decimal places — no field depends on `round2`
  actually rounding anything, preserving the original XACA-0968 decoupling
  goal in full (see "Verified decoupled from XACA-0968" below).

The construction: within a bucket, 6 ratios are chosen directly (in
ascending order, r0..r5), a 7th (r6) is chosen above them, and the 8th
(r7, on the item with the largest `points` in the bucket) is solved
algebraically so `Σ(points·ratio) / Σ(points)` lands exactly on a chosen
2-decimal target `handicap`, subject to `r7 > r6` so it doesn't disturb
sort order — which keeps `median = (r3 + r4) / 2` (the two middle values by
position) independent of the solved value, letting `handicap` and `median`
be engineered as two separate, non-interacting knobs. `handicap` targets
were further restricted to multiples that keep the *pre-rounding*
`sumActualHours` exact too (not just the post-`round2` `handicap`) — the
bucket sums have denominators with prime factors (11, 17, 43) that make an
arbitrary 2-decimal `handicap` produce a `sumActualHours` needing real
rounding; the fix is to choose only `handicap` values whose hundredths are
a multiple of the bucket's `sumEstimatedHours` denominator (worked out per
bucket; see `scripts` referenced below). The resulting per-bucket and
global values:

| | handicap | median | sumEstimatedHours | sumActualHours |
|---|---|---|---|---|
| `<=1h` | 2.18 | 2.00 | 5 | 10.9 |
| `1-4h` | 2.34 | 2.20 | 19.5 | 45.63 |
| `4-8h` | 2.48 | 2.40 | 46.75 | 115.94 |
| `>8h`  | 2.68 | 2.20 | 96.75 | 259.29 |
| global | 2.57 | 2.20 | 168 | 431.76 |

All 20 values above were produced by exact `fractions.Fraction` arithmetic
(never floats) while solving for the per-item ratios, then independently
confirmed by running the real CLI (`kb-variance --json --board-file …`)
against the committed fixture and reading its output back — the table
matches that run byte-for-byte.

### Mutation proof (XACA-0952-034)

Directly demonstrates the round-1 fixture's blind spot and round-2's fix,
by mutating `_build_estimates_payload`'s `_compute_aggregate` in
`lcars-ui/server.py` to compute a **mean** instead of the spec's median
(`median = sum(ratios) / n` for both odd and even `n`, replacing the
correct sort-and-middle logic) and re-running `TestFixtureBoardParity`:

- **Against the round-1 (uniform ratio=2.0) fixture:** `test_parity`
  **PASSES** — mean and median of a constant list are identical, so the
  bug produces no observable diff.
- **Against the round-2 (current, varied-ratio) fixture:** `test_parity`
  **FAILS**, with a diff in all 4 buckets and the global block, e.g.
  `buckets[0].median: CLI=2 vs server=2.02`,
  `buckets[1].median: CLI=2.2 vs server=2.15`,
  `buckets[2].median: CLI=2.4 vs server=2.37`,
  `buckets[3].median: CLI=2.2 vs server=2.39`,
  `global.median: CLI=2.2 vs server=2.23`.

The mutation was reverted immediately after this check (never committed);
`lcars-ui/server.py` in this PR is byte-identical to `develop` on this
function.

### Verified decoupled from XACA-0968 (round 2)

No jq 1.7.1 binary was available in this environment to re-run the original
substituted-`PATH` method, so decoupling was instead verified by
implementing both the correct `round2` filter and the exact buggy
operator-precedence parse XACA-0968 describes (`. * (100 as $s | …)`,
literal-`100`-only, per the bug's own root-cause writeup above) as two `jq`
functions, then applying both to every one of the 20 payload values in the
table above: `correct == buggy` for all 20, because every one is already
exact to ≤2 decimals and both implementations are true no-ops on such
input. This is the same decoupling property round 1 had, now proven to
still hold under a fixture whose values are no longer uniform.

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
global: {handicap: 2.57, median: 2.2, sumEstimatedHours: 168, sumActualHours: 431.76}
buckets:
  <=1h  n=8  handicap=2.18  median=2    sumEstimatedHours=5      sumActualHours=10.9
  1-4h  n=8  handicap=2.34  median=2.2  sumEstimatedHours=19.5   sumActualHours=45.63
  4-8h  n=8  handicap=2.48  median=2.4  sumEstimatedHours=46.75  sumActualHours=115.94
  >8h   n=8  handicap=2.68  median=2.2  sumEstimatedHours=96.75  sumActualHours=259.29
```

These values are not hardcoded into the test (the test compares CLI output
to server output, not to a hardcoded expectation) — they're recorded here so
a future reader can sanity-check a fixture refresh against a known-good
baseline, and can see at a glance why every value is already exact to ≤2
decimals (the point of the round-2 varied-ratio design above) despite no
longer being uniform. Round 1's `handicap == median == 2` in every row is
exactly the blind spot round 2 exists to close — see "Mutation proof" above.
