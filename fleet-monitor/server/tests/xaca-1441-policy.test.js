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

test('fork rule: same-repo events pass for every event type', () => {
  for (const event of ['push', 'pull_request', 'workflow_dispatch', 'schedule', 'workflow_run']) {
    const v = ev(rec({ run: { event } }));
    assert.deepStrictEqual(v, { accept: true, reason: 'ok', alert: false }, event);
  }
});

test('fork rule: fork jobs reject with alert for every event type, pool label present', () => {
  for (const event of ['pull_request', 'pull_request_target', 'workflow_run']) {
    const v = ev(rec({ run: { event, headRepoFullName: 'evil/dev-team' } }));
    assert.deepStrictEqual(v, { accept: false, reason: 'reject:fork', alert: true }, event);
  }
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
  assert.strictEqual(ok(['self-hosted', 'fleet-pool']), true);                       // minimal subset
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
