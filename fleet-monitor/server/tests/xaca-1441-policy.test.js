//
//  xaca-1441-policy.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

// XACA-1441-006: safety policy truth tables. Offline, pure.

const test = require('node:test');
const assert = require('node:assert');
const { evaluateJob, isAllowlisted, isSameRepoRun } = require('../lib/ci-dispatch-policy');

const CTX = { allowlist: ['DoubleNode/dev-team'], poolLabel: 'fleet-pool', hostLabels: ['m4mini', 'm1mini'] };
const GOOD_LABELS = ['self-hosted', 'macOS', 'ARM64', 'fleet-pool', 'm4mini'];

function rec(over) {
  const o = over || {};
  const r = Object.assign({
    owner: 'DoubleNode', repo: 'dev-team', labels: GOOD_LABELS.slice(),
    run: { event: 'push', repoFullName: 'DoubleNode/dev-team', headRepoFullName: 'DoubleNode/dev-team' }
  }, o, { run: undefined });
  // `run` merges field-wise unless the caller passes an explicit null/undefined (own-key check).
  const baseRun = { event: 'push', repoFullName: 'DoubleNode/dev-team', headRepoFullName: 'DoubleNode/dev-team' };
  r.run = ('run' in o && !o.run) ? o.run : Object.assign(baseRun, o.run);
  return r;
}
const ev = (r, c) => evaluateJob(r, c || CTX);

test('fork rule: same-repo events whose head is meaningful pass', () => {
  for (const event of ['push', 'pull_request', 'workflow_dispatch', 'schedule']) {
    const v = ev(rec({ run: { event } }));
    assert.deepStrictEqual(v, { accept: true, reason: 'ok', alert: false }, event);
  }
});

// XACA-1441 PR #1083 review, BLOCKING 1. Each row is the RUN-LEVEL shape GitHub actually emits
// for a job triggered from a fork (measured on facebook/react, 2026-10-06). A workflow_run always
// runs in the base repo, so its own head_repository is the base repo even when a fork PR started
// the chain. The old fixture gave workflow_run a fork head, which GitHub never emits, so the defect
// was invisible.
const FORK = 'Irish-Joseph/dev-team';
const BASE = 'DoubleNode/dev-team';
const ORIGIN_TABLE = [
  // [description, run shape, expected reason, accept]
  ['pull_request from a fork', { event: 'pull_request', headRepoFullName: FORK }, 'reject:fork', false],
  ['pull_request_target from a fork', { event: 'pull_request_target', headRepoFullName: FORK }, 'reject:fork', false],
  ['pull_request_review on a fork PR', { event: 'pull_request_review', headRepoFullName: FORK }, 'reject:fork', false],
  ['pull_request_review_comment on a fork PR', { event: 'pull_request_review_comment', headRepoFullName: FORK }, 'reject:fork', false],
  ['workflow_run chained from a fork pull_request (head == base)', { event: 'workflow_run', headRepoFullName: BASE }, 'reject:fork-unverifiable', false],
  ['workflow_run chained from a workflow_run chained from a fork (same run-level shape)', { event: 'workflow_run', headRepoFullName: BASE }, 'reject:fork-unverifiable', false],
  ['workflow_run, any casing', { event: 'Workflow_Run', headRepoFullName: BASE }, 'reject:fork-unverifiable', false],
  ['workflow_run from a same-repo push: indistinguishable at run level, so also rejected', { event: 'workflow_run', headRepoFullName: BASE }, 'reject:fork-unverifiable', false],
  ['workflow_run with a fork head (not emitted by GitHub; still rejected)', { event: 'workflow_run', headRepoFullName: FORK }, 'reject:fork-unverifiable', false],
  // D7 DECISION: issue_comment runs the base repo's default-branch code (head == base). Accepted,
  // the same posture as the XACA-1442 job-started hook's PASS. Pinned so a change is deliberate.
  ['issue_comment on a fork PR (base default-branch code; D7 decision)', { event: 'issue_comment', headRepoFullName: BASE }, 'ok', true],
];

test('fork origin table: realistic run-level shapes, pool label present', () => {
  for (const [desc, run, reason, accept] of ORIGIN_TABLE) {
    const v = ev(rec({ run }));
    assert.deepStrictEqual(v, { accept, reason, alert: !accept }, desc);
  }
});

test('fork origin table: no pool label means reject without alert', () => {
  const labels = ['self-hosted', 'macOS', 'ARM64'];
  for (const [desc, run, reason, accept] of ORIGIN_TABLE) {
    if (accept) continue;
    assert.deepStrictEqual(ev(rec({ labels, run })), { accept: false, reason, alert: false }, desc);
  }
});

test('missing / empty / non-string run.event fails closed as malformed', () => {
  for (const event of [undefined, null, '', '  ', 42, {}]) {
    assert.deepStrictEqual(ev(rec({ run: { event } })), { accept: false, reason: 'malformed', alert: false }, String(event));
  }
  const r = rec(); delete r.run.event;
  assert.strictEqual(ev(r).reason, 'malformed');
});

test('fork rule: null / missing / empty / non-string head repo fails closed', () => {
  for (const head of [null, undefined, '', '  ', 42, {}]) {
    const v = ev(rec({ run: { headRepoFullName: head } }));
    assert.strictEqual(v.accept, false);
    assert.strictEqual(v.reason, 'reject:fork');
  }
  const r = rec(); delete r.run.headRepoFullName;
  assert.strictEqual(ev(r).reason, 'reject:fork');
});

test('fork rule: head repo comparison is case-insensitive', () => {
  assert.strictEqual(ev(rec({ run: { headRepoFullName: 'doublenode/DEV-TEAM' } })).accept, true);
  assert.strictEqual(isSameRepoRun('A/b', 'a/B'), true);
  assert.strictEqual(isSameRepoRun('A/b', null), false);
});

test('alert only for fork jobs that carry the pool label', () => {
  const noPool = ev(rec({ labels: ['self-hosted', 'macOS', 'ARM64'], run: { headRepoFullName: 'evil/dev-team' } }));
  assert.deepStrictEqual(noPool, { accept: false, reason: 'reject:fork', alert: false });
  const withPool = ev(rec({ run: { headRepoFullName: 'evil/dev-team' } }));
  assert.strictEqual(withPool.alert, true);
  // non-fork rejections never alert
  for (const r of [rec({ labels: ['ubuntu-latest'] }), rec({ repo: 'other', run: { repoFullName: 'DoubleNode/other' } })]) {
    assert.strictEqual(ev(r).alert, false);
  }
});

test('allowlist: exact owner/repo, case-insensitive, no wildcards or prefixes', () => {
  const lower = ev(rec({ owner: 'doublenode', repo: 'DEV-TEAM', run: { repoFullName: 'doublenode/dev-team', headRepoFullName: 'doublenode/dev-team' } }));
  assert.strictEqual(lower.accept, true);
  const other = ev(rec({ repo: 'other', run: { repoFullName: 'DoubleNode/other', headRepoFullName: 'DoubleNode/other' } }));
  assert.deepStrictEqual(other, { accept: false, reason: 'not-allowlisted', alert: false });
  for (const al of [[], ['DoubleNode/*'], ['DoubleNode/dev'], ['DoubleNode'], ['DoubleNode/dev-team-x']]) {
    assert.strictEqual(ev(rec(), Object.assign({}, CTX, { allowlist: al })).reason, 'not-allowlisted', JSON.stringify(al));
  }
  assert.strictEqual(isAllowlisted('X/y', [null, 7, 'x/Y']), true);
  assert.strictEqual(isAllowlisted(null, ['x/y']), false);
});

test('allowlist beats fork: a fork job in a non-allowlisted repo is not-allowlisted', () => {
  const v = ev(rec({ repo: 'other', run: { repoFullName: 'DoubleNode/other', headRepoFullName: 'evil/other' } }));
  assert.strictEqual(v.reason, 'not-allowlisted');
});

test('labels: exact set, subsets and case', () => {
  const ok = (labels) => ev(rec({ labels })).accept;
  assert.strictEqual(ok(['self-hosted', 'fleet-pool', 'macOS']), true);              // minimal: pool + exactly one OS
  assert.strictEqual(ok(['Self-Hosted', 'FLEET-POOL', 'linux', 'arm64', 'M1Mini']), true);
  assert.strictEqual(ok(['self-hosted', 'Linux', 'ARM64', 'fleet-pool', 'm1mini']), true);
});

test('labels: missing self-hosted or pool label -> label:not-pool', () => {
  for (const labels of [['fleet-pool'], ['self-hosted'], ['self-hosted', 'macOS', 'ARM64'], ['ubuntu-latest'], []]) {
    assert.strictEqual(ev(rec({ labels })).reason, 'label:not-pool', JSON.stringify(labels));
  }
});

test('labels: any label outside the allowed set -> label:unknown (superset rejected)', () => {
  for (const extra of ['gpu', 'm9mini', 'windows', 'x64', 'dev-team-ci']) {
    const v = ev(rec({ labels: GOOD_LABELS.concat(extra) }));
    assert.deepStrictEqual(v, { accept: false, reason: 'label:unknown', alert: false }, extra);
  }
});

// XACA-1441-031: a pool job that no single runner can satisfy is a misconfiguration, not a capacity outage.
const AMBIGUITY_TABLE = [
  // [description, labels, accept, reason]
  ['one OS label', ['self-hosted', 'fleet-pool', 'macOS'], true, 'ok'],
  ['one OS label and one host label', ['self-hosted', 'fleet-pool', 'Linux', 'm1mini'], true, 'ok'],
  ['one OS label, any casing, repeated', ['self-hosted', 'fleet-pool', 'Linux', 'linux'], true, 'ok'],
  ['two OS labels', ['self-hosted', 'fleet-pool', 'Linux', 'macOS'], false, 'label:ambiguous'],
  ['no OS label', ['self-hosted', 'fleet-pool', 'ARM64'], false, 'label:ambiguous'],
  ['no OS label, minimal set', ['self-hosted', 'fleet-pool'], false, 'label:ambiguous'],
  ['two host labels', ['self-hosted', 'fleet-pool', 'macOS', 'm4mini', 'm1mini'], false, 'label:ambiguous'],
  ['two OS and two host labels', ['self-hosted', 'fleet-pool', 'macOS', 'Linux', 'm4mini', 'm1mini'], false, 'label:ambiguous'],
  ['an unknown label still reports label:unknown first', ['self-hosted', 'fleet-pool', 'macOS', 'Linux', 'gpu'], false, 'label:unknown'],
];
for (const [name, labels, accept, reason] of AMBIGUITY_TABLE) {
  test(`ambiguity (031): ${name} -> ${reason}`, () => {
    assert.deepStrictEqual(ev(rec({ labels })), { accept, reason, alert: false });
  });
}

test('malformed inputs fail closed and never throw', () => {
  const bad = [
    null, undefined, 'x', 5, {},
    rec({ owner: '' }), rec({ repo: null }), rec({ labels: 'self-hosted' }), rec({ labels: [1, 2] }),
    rec({ run: null }), Object.assign(rec(), { run: undefined }),
    rec({ run: { repoFullName: 'DoubleNode/other' } })       // disagrees with owner/repo
  ];
  for (const r of bad) {
    const v = ev(r);
    assert.deepStrictEqual(v, { accept: false, reason: 'malformed', alert: false }, JSON.stringify(r));
  }
  for (const c of [null, {}, { allowlist: 'x', poolLabel: 'p', hostLabels: [] }, { allowlist: [], poolLabel: '', hostLabels: [] },
                   { allowlist: [], poolLabel: 'p', hostLabels: null }, { allowlist: [], poolLabel: 'p', hostLabels: [3] }]) {
    assert.strictEqual(evaluateJob(rec(), c).reason, 'malformed');
  }
});

test('evaluateJob is pure: does not mutate its inputs', () => {
  const r = rec(); const c = JSON.parse(JSON.stringify(CTX));
  const before = JSON.stringify([r, c]);
  evaluateJob(r, c);
  assert.strictEqual(JSON.stringify([r, c]), before);
});
