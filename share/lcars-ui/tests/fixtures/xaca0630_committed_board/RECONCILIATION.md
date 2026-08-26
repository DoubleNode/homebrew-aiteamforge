<!--
  RECONCILIATION.md
  DoubleNode Dev-Team Infrastructure (AITeamForge)

  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
-->

# XACA-0630 Committed Board Fixture Reconciliation — XACA-0952 Blocker A

**File:** `academy-board.json` (this directory)
**Consumer:** `lcars-ui/tests/test_xaca0630_parity.py` → `TestFixtureBoardParity`, `TestFixtureDyadicity`
**Replaces:** the former `TestLiveBoardParity`, which read
`kanban/academy-board.json` directly. That file is gitignored (see
`.gitignore`), so it never exists on a CI checkout — all 3 of that class's
tests were unconditionally red on GitHub Actions
(`RuntimeError: kb-variance failed (rc=1): 'Error: board file not found: ...'`),
run 32882458626.

---

## Quick Reference

**If you're regenerating or extending this fixture, you want [Construction](#construction) below** — the current (round 3) recipe: fix `points` per bucket, choose per-item ratios as quarter-unit integers so every emitted `handicap`/`median`/`sumEstimatedHours`/`sumActualHours` lands exactly on the 0.25-hour grid.

**The operative invariant:** every value that crosses the `round2`/`round(x, 2)` boundary must be an exact multiple of `0.25` (`Fraction` denominator ∈ {1, 2, 4}). This is checked mechanically, every run, by `TestFixtureDyadicity` in `test_xaca0630_parity.py` — see "Fix, round 3 (current)" below for the derivation.

**Caveat you need if a value fails the quarter-grid check:** quarter-grid is *sufficient but not necessary* — it rejects some values that would actually be safe (e.g. `45.63`: `round(45.63, 2) == 45.63` is True, yet its `Fraction` denominator is `2**47`, off-grid). A failing value has not necessarily been proven unsafe; it's simply one this deliberately conservative fixture can't vouch for. Pick a different value rather than assume the check is wrong. Full reasoning: "Fix, round 3 (current)" below.

**Why three rounds of history precede this:** rounds 1 and 2 are not dead ends to skip past — they record two *different* ways a fixture verification for this exact bug can look green while proving nothing (round 1's uniform-ratio design hid a mean-vs-median server bug; round 2's "≤2 decimals" invariant and its own decoupling proof both tested already-rounded values). Both are why round 3 looks the way it does, and are the guardrail against a fourth attempt repeating either mistake.

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
*original, completely unrounded* value, for EVERY input, not just
already-rounded ones. That means: on affected jq, the CLI emits the raw,
full-precision computed double with **zero** rounding applied, while the
server (`round(x, 2)` in Python) always emits the correctly-rounded value.
For the two to agree, the raw double has to equal `round(raw, 2)`
bit-for-bit.

**Fix, round 1 (superseded):** every eligible item used the **same fixed
ratio, `2.0`** (`timeWorkedMs = points * 2.0 * 3600000`), with `points` on a
0.25-hour grid. XACA-0952-034 (PR #767) flagged the problem: a uniform ratio
makes `handicap` (weighted mean) and `median` identical — `2.0` — in every
bucket and globally, so a server bug that computes a mean where the spec
requires a median is invisible against constant input.

**Fix, round 2 (superseded):** `points` stayed on the 0.25 grid; each item's
`timeWorkedMs` was hand-solved to a distinct per-item ratio, engineered so
`handicap != median` in every bucket and globally, while every emitted field
was **"exact to ≤2 decimal places."** That framing turned out to be **wrong**
— restated below — and reproduced XACA-0968 on the real CI runner (jq 1.7.1,
run 32882458626):

```
CLI=45.629999999999995 vs server=45.63     (buckets[1].sumActualHours)
CLI=2.6799999999999997 vs server=2.68      (buckets[3].handicap)
... 6 field mismatches total; reconciliation 1058+4=1062 != 1063
```

**Why round 2's own decoupling proof missed this — and why it was malformed,
not just unlucky.** Round 2's "Verified decoupled from XACA-0968" section
(reproduced unchanged in this file's git history) applied the correct and
buggy `round2` filters to the **20 numbers in its results table** —
`2.18`, `2.34`, `45.63`, etc. Those are the ALREADY-ROUNDED, hand-typed
decimal literals a human read off a CLI run and pasted into a markdown
table. Both filters are trivial no-ops on a value that's already been
rounded once (there's nothing left to round). The proof tested the *output*
of rounding, not the *input* to it, so it could only ever return the
reassuring answer — it never had the power to catch the bug it was meant to
catch. See `feedback_malformed_check_returns_reassuring_result.md` in the
Academy knowledge base for the general pattern.

**Why "exact to ≤2 decimals" was the wrong invariant.** `2.34`, `2.57`,
`431.76` are exact *decimal* literals — but the fixture doesn't emit decimal
literals, it emits IEEE-754 doubles that survive a chain of jq/Python
divisions and additions over `(points, timeWorkedMs)` pairs. "Looks like
2 decimal digits when printed" and "is bit-identical to `round(x, 2)`" are
different properties that happen to coincide for round 1's fixture (by
accident — see below) and silently diverged for round 2's.

## Fix, round 3 (current): dyadic, not merely "≤2 decimals"

The COMPLETE condition for the buggy jq round2's raw-value-passthrough to
match Python's `round(x, 2)` is simply `round(raw, 2) == raw`. **The raw
double's exact binary value already sitting on the quarter-hour grid**
(i.e. being an exact multiple of `0.25`) is a SUFFICIENT, deliberately
stricter-than-necessary way to guarantee that — not an iff. A counterexample
proves the gap: the double nearest the decimal literal `45.63` satisfies
`round(x, 2) == x` (so it's safe) but has a `Fraction` denominator of `2^47`,
nowhere near the quarter grid — `2.34`, `2.57`, and `0.07` behave the same
way. Quarter-grid is *stricter* than "dyadic" in the loose sense (any
power-of-2 denominator): **every finite IEEE-754 double is dyadic**
(mantissa/2^k by construction), including `45.629999999999995` itself, so
"is the denominator a power of 2" is true for literally any float and proves
nothing on its own. The discriminating test is whether that power is small
enough — specifically ≤2 (denominator ∈ {1, 2, 4}) — for `round(x, 2)` to be
a no-op. A genuinely dyadic eighth like `0.125` **fails** this:
`round(0.125, 2) == 0.12 != 0.125`.

Quarter-grid is the right design choice for *this* fixture — it's tractable
to solve for by hand/script over integer quarter-units, and it can never
admit an unsafe value — but it is an over-approximation, not a
characterization: it rejects some legitimate `round(x, 2) == x` values (like
`45.63`) along with the unsafe ones. A future fixture author choosing a
value that fails the quarter-grid check has not necessarily chosen an unsafe
one; they've chosen one this deliberately conservative test can't vouch for.

Round 1's uniform `ratio=2.0` fixture happened to satisfy this (every sum,
handicap, and median came out to a whole number or a simple half/quarter),
but nothing in its design *named* that property — "0.25-grid points,
ratio=2.0" was reasoned about as "keeps everything simple," not as "keeps
every OUTPUT on the quarter grid specifically." Round 2 varied the ratios
without re-deriving what made round 1 safe, so it silently dropped the
property while satisfying a superficially similar one ("≤2 decimals") that
doesn't actually guarantee it.

### Construction

Every eligible item's `points` is now **fixed per bucket** at that bucket's
own upper boundary — `1.0`, `4.0`, `8.0`, `16.0` for `<=1h`/`1-4h`/`4-8h`/
`>8h` respectively (the first three land exactly on the spec's own boundary
values). Fixing `points` within a bucket turns
`handicap = Σ(actual)/Σ(points)` into a **plain arithmetic mean of the
per-item ratios** (the constant `points` factors out of both sums), which
makes the arithmetic tractable: choosing `n` per-item ratios as
quarter-unit integers `m_i/4` with `Σm_i` divisible by `n` puts the mean
exactly on the quarter grid by construction.

Bucket sizes are **odd** (`<=1h`, `1-4h`, `4-8h`: n=7) wherever possible, so
the bucket's median is simply one of the `n` chosen ratios — already on the
quarter grid, no extra constraint needed. The one **even**-sized bucket
(`>8h`, n=8) additionally requires its two middle sorted ratios (in
quarter-units) to share parity, so their average also lands on the grid.
The **global** item count (7+7+7+8 = 29) is kept odd for the same
trivial-median reason — the global median is just one of the 29 chosen
ratios. The global **handicap**, however, is a real constraint: it's
`Σ(all actual)/Σ(all points)`, and `Σ(all points)` is fixed at `219`
(7·1 + 7·4 + 7·8 + 8·16) regardless of ratio choices, so one bucket's mean
(here, `<=1h`) was solved algebraically — via the small modular system
`7a + 28b + 56c + 128d ≡ 0 (mod 219·4)` for the bucket-mean numerators
`a,b,c,d` — to make the global handicap land on the quarter grid too, while
every per-bucket target stayed independently satisfiable.

All values below were produced and verified by exact `fractions.Fraction`
arithmetic (never floats) in the generation script, then independently
confirmed by running the real CLI (`kb-variance --json --board-file …`)
and the real server function (`_build_estimates_payload`) against the
committed fixture — CLI and server outputs matched field-for-field, and the
table below matches both runs byte-for-byte:

| | handicap | median | sumEstimatedHours | sumActualHours | n |
|---|---|---|---|---|---|
| `<=1h` (points=1.0) | 3.25 | 2.75 | 7 | 22.75 | 7 |
| `1-4h` (points=4.0) | 1.5  | 1.25 | 28 | 42 | 7 |
| `4-8h` (points=8.0) | 2.5  | 2.25 | 56 | 140 | 7 |
| `>8h`  (points=16.0)| 2.25 | 2.0  | 128 | 288 | 8 |
| global | 2.25 | 2.0 | 219 | 492.75 | 29 |

Per-item ratios (actual hours ÷ points), by bucket, in fixture order:

- `<=1h`: 1.25, 1.75, 2.25, 2.75, 3.25, 3.75, 7.75
- `1-4h`: 0.25, 0.5, 1.0, 1.25, 1.75, 2.0, 3.75
- `4-8h`: 0.75, 1.25, 1.75, 2.25, 2.75, 3.25, 5.5
- `>8h`: 0.25, 0.75, 1.25, 1.75, 2.25, 2.75, 3.25, 5.75

Every one of these 29 ratios, every bucket's 4 emitted fields, and the 4
global fields — 20 values that cross the round2/`round(x, 2)` boundary in
total — are on the quarter-hour grid. `TestFixtureDyadicity` in
`test_xaca0630_parity.py` checks this mechanically against the RAW,
pre-rounding computed values (via `run_server_raw()`, which patches `round`
to identity — see its docstring; XACA-0952-041) on every test run (not just
once, by hand, at fixture-authoring time), using `fractions.Fraction` on the
real float (exact — no decimal string parsing) rather than eyeballing
decimal digit counts. It deliberately does NOT assert on the normal
`run_server()` payload, which has already had `round(x, 2)` applied and
would snap any near-miss raw value onto the grid before the check could see
it.

### Proof 1 — Dyadicity, mechanically verified

`TestFixtureDyadicity.test_global_fields_are_quarter_grid` and
`test_bucket_fields_are_quarter_grid` assert, for all 20 crossing values,
that `Fraction(value)`'s denominator is a power of 2 **and** that
`(Fraction(4) * Fraction(value)).denominator == 1` (i.e. the value survives
multiplication by 4 with no remaining fractional part — equivalent to
"exact multiple of 0.25"). The first check alone is not diagnostic (every
finite float passes it); the second is the one that matters and is the one
enforced as a standing regression guard, not a one-time hand check.

An equivalent, throwaway verification was run directly against the exact
computed doubles before committing the fixture (both jq and Python floats,
not `Fraction`-of-a-decimal-literal): all 20 values had `round(raw, 2) ==
raw` bit-for-bit, and a faithful re-implementation of the buggy
identity-round2 (`buggy(x) = x`) trivially agreed too.

### Proof 2 — Decoupling, tested on the RIGHT input

Round 2's mistake was applying correct-vs-buggy `round2` to the
**already-rounded table literals** — where both filters are no-ops by
construction and the check can't fail regardless of what the fixture
actually does. This round applies both filters to the **raw pre-rounding
computed values** — the actual floats returned by `sum_act/sum_est` and the
median selection, *before* any rounding step — for all 20 crossing fields:

```
field                        raw (repr)      fraction   dyadic  round(raw,2)  buggy_identity(raw)==raw
global.handicap               2.25            9/4        True    2.25          True
global.median                 2.0             2          True    2.0           True
global.sumEstimatedHours      219.0           219        True    219.0         True
global.sumActualHours         492.75          1971/4     True    492.75        True
<=1h.handicap                 3.25            13/4       True    3.25          True
<=1h.median                   2.75            11/4       True    2.75          True
<=1h.sumEstimatedHours        7.0             7          True    7.0           True
<=1h.sumActualHours           22.75           91/4       True    22.75         True
1-4h.handicap                 1.5             3/2        True    1.5           True
1-4h.median                   1.25            5/4        True    1.25          True
1-4h.sumEstimatedHours        28.0            28         True    28.0          True
1-4h.sumActualHours           42.0            42         True    42.0          True
4-8h.handicap                 2.5             5/2        True    2.5           True
4-8h.median                   2.25            9/4        True    2.25          True
4-8h.sumEstimatedHours        56.0            56         True    56.0          True
4-8h.sumActualHours           140.0           140        True    140.0         True
>8h.handicap                  2.25            9/4        True    2.25          True
>8h.median                    2.0             2          True    2.0           True
>8h.sumEstimatedHours         128.0           128        True    128.0         True
>8h.sumActualHours            288.0           288        True    288.0         True
```

`round(raw, 2) == raw` and `buggy_identity(raw) == raw` for all 20 — this
time proven on the values that actually flow through the pipeline, not on
literals copy-pasted after the fact.

No jq 1.7.1 binary was available in this environment to re-run the original
substituted-`PATH` method (same limitation round 2 noted); the buggy filter
was instead exercised as the faithful `x -> x` reimplementation the
XACA-0968 root-cause analysis above derives (not assumed — derived from the
actual operator-precedence parse), which is a strictly *more* direct proof
than re-running a substituted jq binary through the real `round2` filter
text, since it eliminates any risk of the jq text itself being transcribed
wrong.

### Proof 3 — Non-vacuity, by mutation (re-run for round 3)

Repeats XACA-0952-034's original demonstration against the round-3 fixture:
`_compute_aggregate` in `lcars-ui/server.py` was temporarily patched to
compute a **mean** instead of the spec's median
(`median = sum(ratios) / n` unconditionally, replacing the sort-and-middle
logic for both odd and even `n`), and `TestFixtureBoardParity::test_parity`
was re-run:

```
buckets[0].median: CLI=2.75 vs server=3.25
buckets[1].median: CLI=1.25 vs server=1.5
buckets[2].median: CLI=2.25 vs server=2.5
buckets[3].median: CLI=2 vs server=2.25
global.median: CLI=2 vs server=2.37
```

**FAILS in all 4 buckets and the global block** — the fixture still has
full detection power. Three of the four bucket mismatches land exactly on
that bucket's own `handicap` value (3.25, 1.5, 2.5) — expected, since fixing
`points` per bucket makes the weighted mean (handicap) and the unweighted
mean (what the mutation computes) the same number when every item in the
bucket shares one `points` value. The global mismatch (`2.37`) does **not**
coincide with the global `handicap` (`2.25`): globally, `points` varies
across buckets, so the *points-weighted* mean (the real handicap) and the
*unweighted* mean of all 29 ratios (what the mutation computes,
`68.75/29 = 2.3706...` → `2.37`) are genuinely different quantities — this
is a stronger check than round 2's, which never separated those two cases.

The mutation was reverted immediately after this check (never committed);
`git diff lcars-ui/server.py` is empty in this PR for that function.

## What this still preserves from the real board

`points` values (`1.0`/`4.0`/`8.0`/`16.0` — the exact spec §5 boundaries for
three of the four buckets) span all four buckets, and the 29 per-item
ratios (`0.25` through `7.75`) give real numeric variety — structurally the
same shape a live board has (multiple items per bucket, a spread of
over/under-estimates, all buckets populated), just without carrying real
project content (`id`/`title`/`description`/`epicName`/timestamps are all
synthetic `FIX-CI-NNN` / generic placeholders) or entangling this test with
a different, already-tracked bug. Round 3 trades varied `points` *within* a
bucket (round 1 and 2's `0.25`-through-`20.0` spread) for varied *ratios*
within a bucket at fixed `points` — a deliberate simplification that makes
the quarter-grid arithmetic tractable by hand/script; `points` boundary
coverage (`points==1`, `points==4`, `points==8` landing in the correct
bucket) is independently covered by `TestBoundaryAndEdgeCases` against its
own small, dedicated fixtures, so this fixture doesn't need to re-prove it.

## Exclusion + non-completed coverage

Unchanged from round 2: `FIX-CI-090`..`FIX-CI-099` — 2× `no_estimate`, 2×
`no_time`, 2× `both_missing`, and 4 non-`completed` items in various
statuses — purely for structural realism. These items are excluded (or
silently ignored) before reaching `round2`, so they carry no dyadicity
constraint of their own. `TestFixtureBoardParity` asserts the same two
things it always has: CLI==server field-for-field parity, and the four
buckets present in order — not specific exclusion counts (that would
duplicate `TestExcludedReasonClassification`'s job).

## Measured output (informational, not asserted directly by the test)

Run directly with `kb-variance --json --board-file
lcars-ui/tests/fixtures/xaca0630_committed_board/academy-board.json`
(jq 1.8.1, this machine):

```
eligible: 29
excluded: {no_estimate: 2, no_time: 2, both_missing: 2, total: 6}
global: {handicap: 2.25, median: 2, sumEstimatedHours: 219, sumActualHours: 492.75}
buckets:
  <=1h  n=7  handicap=3.25  median=2.75  sumEstimatedHours=7    sumActualHours=22.75
  1-4h  n=7  handicap=1.5   median=1.25  sumEstimatedHours=28   sumActualHours=42
  4-8h  n=7  handicap=2.5   median=2.25  sumEstimatedHours=56   sumActualHours=140
  >8h   n=8  handicap=2.25  median=2     sumEstimatedHours=128  sumActualHours=288
```

These values are not hardcoded into `test_parity` (it compares CLI output to
server output, not to a hardcoded expectation) — they're recorded here so a
future reader can sanity-check a fixture refresh against a known-good
baseline. Because every crossing value in this fixture is already on the
quarter-hour grid, these rounded display values are numerically identical to
the raw pre-rounding values `TestFixtureDyadicity` actually asserts on (see
above) — the guard checks the raw computation, not this rounded display
table, but for this fixture the two happen to coincide. `TestFixtureDyadicity`
DOES assert structurally on that raw computation (quarter-grid +
`handicap != median`), so a future edit that breaks either property fails
loudly instead of waiting for the next CI run on affected jq to notice.

## Verification status: what is confirmed here vs. what needs CI

This machine runs jq 1.8.1 (unaffected by XACA-0968) — `test_parity` and
`TestFixtureDyadicity` passing here proves the fixture is internally
consistent (CLI==server, correct quarter-grid values) but does **not**, by
itself, prove the *original* CI failure (jq 1.7.1) is fixed, since jq 1.8.1
never exhibited the bug in the first place. The proof that this fixture is
now safe under jq 1.7.1 rests on: (a) the derivation above — dyadic
quarter-grid values make round2's proven identity-under-the-bug behavior a
no-op, so CLI==server regardless of which jq is used — and (b) Proof 2's
direct application of the faithful buggy-filter reimplementation to the
raw computed values. **Confirm on the actual CI runner (jq 1.7.1,
`.github/workflows/lcars-ui-pytest-suite.yml`) before treating this as
closed**: the workflow run for this PR is the first real test against the
affected jq version.
