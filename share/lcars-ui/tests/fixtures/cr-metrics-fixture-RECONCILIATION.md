<!--
  cr-metrics-fixture-RECONCILIATION.md
  DoubleNode Dev-Team Infrastructure (AITeamForge)

  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
-->

# CR Metrics Fixture Reconciliation — XACA-0293-006

**Gold Standard:** `cr-metrics-fixture.json`
**Module Under Test:** `lcars-ui/js/lcars-cr-metrics.js`
**Fixed Clock:** `2026-05-06T12:00:00Z` (epoch ms: `1778068800000`)
**Rolling Window:** 14 days (cutoff: `2026-04-22T12:00:00Z`)

---

## Epoch Correction Note

The task brief stated `now_ms = 1778414400000`. Verification via
`node -e "console.log(new Date('2026-05-06T12:00:00Z').getTime())"` returned
`1778068800000`. The brief value (`1778414400000`) maps to `2026-05-10T12:00:00Z`,
not May 6. The fixture uses the verified correct value: `1778068800000`. This
discrepancy has no impact on fixture correctness; it is documented here so future
readers do not use the brief's value directly.

---

## Fixture CR Scenarios

### CR-FIXTURE-001 — Happy Path

All nine lifecycle timestamps are present with exactly two days between each
consecutive pair. This makes hand verification trivial: every segment value is
`2.0`. The deployment window matches the actual production deploy time exactly,
so `deploy_estimate_delta_days = 0.0`, which classifies as a HIT (threshold:
`abs(delta) <= 1`). The completion anchor is `cr_completed_at = T-2d`
(`2026-05-04T12:00:00Z`), which falls inside the 14-day window. `cr_cycle_total_days`
is computed as `cr_completed_at - cr_created_at` = `T-2d - T-14d = 12.0 days`.

### CR-FIXTURE-002 — Missing-Timestamp Gap

`cr_dev_started_at` and `cr_testing_started_at` are deliberately null. This
causes three segments to be null: `cr_cycle_approve_to_dev_days` (needs
`cr_dev_started_at`), `cr_cycle_dev_to_test_days` (needs both), and
`cr_cycle_test_to_deploydev_days` (needs `cr_testing_started_at`). The remaining
four segments that do not depend on those timestamps are computable. The production
deploy occurred three days after the planned window, so
`deploy_estimate_delta_days = +3.0` (LATE). `cr_cycle_total_days` computes
normally because both `cr_created_at` and `cr_completed_at` are present.
Completion anchor: `cr_completed_at = T-5d`, inside window.

### CR-FIXTURE-003 — Emergency Path

The CR was emergency-deployed (`crState: "emergency-deployed"`) without going
through CAB approval or formal testing. Consequently `cr_approved_at`,
`cr_testing_started_at`, `cr_deployed_prod_at`, `cr_completed_at`, and
`deploy_window_planned` are all null. Only `cr_cycle_draft_to_submit_days` is
computable (1.0 day). All other segments are null. `cr_cycle_total_days` is null
because `cr_completed_at` is absent. `deploy_estimate_delta_days` is null because
neither endpoint (planned window nor actual prod deploy) exists. This CR is
included in the rolling-window set via the fallback anchor
`cr_emergency_deployed_at = T-7d`, but it contributes no values to the
`estimateDelta` rollup because its delta is null.

### CR-FIXTURE-004 — Out-of-Window

All timestamps are present and produce sensible numbers, but `cr_completed_at` is
30 days before `now`, placing it 16 days outside the 14-day window cutoff. The
`_filterToWindow` function in the module excludes this CR from every rollup.
`derivePerCR` still returns correct numeric values for the per-CR block because
derivation is window-independent. This CR exercises the test harness assertion that
`sampleCount` for each rollup segment does not count excluded CRs.

### CR-FIXTURE-005 — Early Delivery

A CR where the production deployment happened three days before the planned window.
`deploy_estimate_delta_days = deployed_prod - deploy_window_planned = T-4d - T-1d = -3.0`.
Negative values indicate early delivery. The threshold check: `delta < -1` →
classified as EARLY in the rollup. All lifecycle timestamps are present.
Completion anchor: `cr_completed_at = T-3d`, inside window.

### CR-FIXTURE-006 — Boundary Hit

Designed to verify that the hit-classification threshold (`abs(delta) <= 1`) is
applied correctly at a non-zero value. The production deploy occurred 12 hours
(0.5 days) after the planned window, giving `deploy_estimate_delta_days = +0.5`.
Since `abs(0.5) <= 1.0`, this classifies as a HIT (not LATE). The `deploydev_to_deployprod`
segment is also 0.5 days (12 hours), not a whole number, which exercises the
fractional-days path in the module. Completion anchor: `cr_completed_at = T-1d`,
inside window.

---

## Worked Examples

### Segment Math — CR-FIXTURE-001 (simple 2-day spacing)

Each timestamp is exactly 48 hours (2 × 86,400,000 ms = 172,800,000 ms) after
the prior one:

```
cr_created_at        = 2026-04-22T12:00:00Z   (epoch 1745323200000)
cr_submitted_at      = 2026-04-24T12:00:00Z   (+172800000 ms)
cr_approved_at       = 2026-04-26T12:00:00Z   (+172800000 ms)
cr_dev_started_at    = 2026-04-28T12:00:00Z   (+172800000 ms)
cr_testing_started_at= 2026-04-30T12:00:00Z   (+172800000 ms)
cr_deployed_dev_at   = 2026-05-02T12:00:00Z   (+172800000 ms)
cr_deployed_prod_at  = 2026-05-04T12:00:00Z   (+172800000 ms)
cr_completed_at      = 2026-05-04T12:00:00Z   (same as deployed_prod)

cr_cycle_draft_to_submit_days     = 172800000 / 86400000 = 2.0
cr_cycle_submit_to_approve_days   = 172800000 / 86400000 = 2.0
cr_cycle_approve_to_dev_days      = 172800000 / 86400000 = 2.0
cr_cycle_dev_to_test_days         = 172800000 / 86400000 = 2.0
cr_cycle_test_to_deploydev_days   = 172800000 / 86400000 = 2.0
cr_cycle_deploydev_to_deployprod_days = 172800000 / 86400000 = 2.0
cr_cycle_total_days               = (T-2d) - (T-14d) = 12.0

deploy_estimate_delta_days = deployed_prod - deploy_window_planned
                           = 2026-05-04T12:00:00Z - 2026-05-04T12:00:00Z
                           = 0 ms / 86400000 = 0.0
```

### Estimate-Delta Rollup — In-Window CRs with Non-Null Deltas

Of the five in-window CRs, CR-003 has a null delta (emergency path, no planned
window and no prod deploy). The remaining four contribute:

| CR | delta | abs(delta) | classification |
|---|---|---|---|
| CR-FIXTURE-001 | 0.0 | 0.0 | HIT (abs <= 1) |
| CR-FIXTURE-002 | +3.0 | 3.0 | LATE (delta > +1) |
| CR-FIXTURE-005 | -3.0 | 3.0 | EARLY (delta < -1) |
| CR-FIXTURE-006 | +0.5 | 0.5 | HIT (abs <= 1) |

```
sampleCount = 4
avg  = (-3.0 + 0.0 + 0.5 + 3.0) / 4 = 0.5 / 4 = 0.125
hits    = 2  (001 and 006)
earlies = 1  (005)
lates   = 1  (002)
```

**Largest-remainder (Hamilton) rounding** (XACA-0293-015):

`rollupEstimateDelta` uses the largest-remainder method instead of independent
`Math.round()` on each bucket. Independent rounding can produce sums of 99 or 101
when raw percentages are non-integer. Largest-remainder guarantees the three
percentages always sum to exactly 100 when `sampleCount > 0`.

Algorithm:
1. Compute exact float percentages: `hitRaw = hits/count × 100`, etc.
2. Floor each: `hitFloor`, `earlyFloor`, `lateFloor`. Their sum is ≤ 100.
3. Leftover = `100 − (hitFloor + earlyFloor + lateFloor)`.
4. Sort buckets descending by residual (raw − floor). Tie-break alphabetically
   by bucket name (`early < hit < late`) for deterministic results with equal residuals.
5. Add 1 to each of the top `leftover` buckets.

For this fixture the raw percentages happen to be exact (50.0, 25.0, 25.0), so
the floors are 50, 25, 25, leftover = 0, and no adjustment is needed. The
expected values are unchanged.

```
hitPct   = 50   (floor(50.0) + 0 adjustment)
earlyPct = 25   (floor(25.0) + 0 adjustment)
latePct  = 25   (floor(25.0) + 0 adjustment)
sum      = 100  ✓
```

### Median Computation — cr_cycle_deploydev_to_deployprod_days

Four non-null values (even count): `[0.5, 1.0, 2.0, 5.0]` (sorted ascending).
Middle two values are at positions 2 and 3 (1-indexed): `1.0` and `2.0`.
Median = `(1.0 + 2.0) / 2 = 1.5`.

---

## Window-Inclusion Anchor Selection

The module applies a three-level fallback to determine which timestamp anchors a
CR to the rolling window (`_completionAnchorMs` in `lcars-cr-metrics.js`):

1. `cr_completed_at` — preferred; CR is fully done.
2. `cr_deployed_prod_at` — fallback; prod deploy happened, may not be formally closed.
3. `cr_emergency_deployed_at` — fallback for emergency path that bypasses prod.

CRs with none of these three timestamps (e.g., still in-flight at approved or
implementing state) are excluded from all rollups.

Per-fixture anchor used:

| CR | Anchor timestamp | Anchor value | In window? |
|---|---|---|---|
| CR-FIXTURE-001 | `cr_completed_at` | `2026-05-04T12:00:00Z` (T-2d) | Yes |
| CR-FIXTURE-002 | `cr_completed_at` | `2026-05-01T12:00:00Z` (T-5d) | Yes |
| CR-FIXTURE-003 | `cr_emergency_deployed_at` | `2026-04-29T12:00:00Z` (T-7d) | Yes |
| CR-FIXTURE-004 | `cr_completed_at` | `2026-04-06T12:00:00Z` (T-30d) | No — before cutoff |
| CR-FIXTURE-005 | `cr_completed_at` | `2026-05-03T12:00:00Z` (T-3d) | Yes |
| CR-FIXTURE-006 | `cr_completed_at` | `2026-05-05T12:00:00Z` (T-1d) | Yes |

CR-003's `cr_completed_at` and `cr_deployed_prod_at` are both null; the module
correctly falls through to `cr_emergency_deployed_at`.

---

## Gold Standard Rule

This fixture represents the authoritative expected behavior for `lcars-cr-metrics.js`.
The hand-computed values in `expected_per_cr` and `expected_rollups` were derived
independently of the module and verified by running the smoke test in
`check-cr-metrics-fixture.js` (exit code 0 on first run — no module defects
detected).

**Do not modify expected values in `cr-metrics-fixture.json` without re-deriving
them by hand and documenting the reason in this file.** The smoke test and the
formal test suite (XACA-0293-011) both rely on this fixture as the source of truth.
If the module produces different output, the module has a bug — not the fixture.
