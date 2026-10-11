//
//  test-xaca-1406-notifications-helpers.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 DoubleNode.com. All rights reserved.
//

/**
 * XACA-1406-002 -- dependency-free coverage of the pure helpers exported by
 * lcars-ui/js/lcars-notifications.js (route toggling, config round-trip,
 * quiet-hours validation, error-code messages, test-send classification).
 * The DOM behaviour is covered by jsdom in
 * fleet-monitor/server/tests/xaca-1406-notifications-panel-jsdom.test.js
 * (jsdom is not installed for this suite's CI job).
 *
 * Usage: node lcars-ui/tests/test-xaca-1406-notifications-helpers.js
 */
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const N = require(path.join(__dirname, '..', 'js', 'lcars-notifications.js'));

test('errorMessage maps every documented code to its human message', () => {
    assert.equal(N.errorMessage('no-fm-url'), 'Fleet Monitor not configured');
    assert.equal(N.errorMessage('unauthorized'), 'team notify key rejected (401)');
    assert.equal(N.errorMessage('forbidden'), 'key belongs to another team (403)');
    assert.match(N.errorMessage('key-resolver-unavailable'), /Key resolver unavailable/);
    assert.match(N.errorMessage('no-key'), /No notify key/);
    assert.match(N.errorMessage('fm-unreachable'), /unreachable/);
    assert.match(N.errorMessage('fm-error'), /returned an error/);
});

test('errorMessage prefers the server message for unknown codes and never says undefined', () => {
    assert.equal(N.errorMessage('weird', 'server text'), 'server text');
    assert.equal(N.errorMessage('weird'), 'Error: weird');
    assert.equal(N.errorMessage(undefined), 'Unknown error');
    assert.equal(N.errorMessage('hasOwnProperty'), 'Error: hasOwnProperty');
});

test('toggleRoute adds, removes, and keeps [] only for keys that existed', () => {
    const base = { a: ['x'] };
    const m = { routes: { a: ['x'] } };
    assert.equal(N.toggleRoute(m, 'b', 'x', base), true);
    assert.deepEqual(m.routes, { a: ['x'], b: ['x'] });
    assert.equal(N.toggleRoute(m, 'b', 'x', base), false);
    assert.deepEqual(m.routes, { a: ['x'] }, 'new key dropped when emptied');
    assert.equal(N.toggleRoute(m, 'a', 'x', base), false);
    assert.deepEqual(m.routes, { a: [] }, 'pre-existing key becomes explicit route-nowhere');
});

test('unknownConnectionIds lists ids not returned by FM, deduped and sorted', () => {
    const routes = { a: ['x', 'ghost', 'ghost'], b: ['zed', 'x'] };
    assert.deepEqual(N.unknownConnectionIds(routes, ['x']), ['ghost', 'zed']);
    assert.deepEqual(N.unknownConnectionIds({}, ['x']), []);
});

test('buildConfig round-trips fields the panel does not edit', () => {
    const base = { $schema: 'release-notify/v2', version: 2, aliases: { k: { provider: 'slack' } }, dedupeWindow: 0, future: { z: 1 }, routes: { a: ['x'] } };
    const model = N.modelFromConfig(base);
    const out = N.buildConfig(base, model);
    assert.deepEqual(out.aliases, base.aliases);
    assert.equal(out.dedupeWindow, 0);
    assert.deepEqual(out.future, { z: 1 });
    assert.deepEqual(out.routes, { a: ['x'] });
    assert.notEqual(out.aliases, base.aliases, 'deep copy, not shared');
});

test('buildConfig: severity default removes the key; empty overrides are omitted; disabled quiet hours are omitted', () => {
    const base = { $schema: 'release-notify/v2', version: 2, routes: {}, severityOverrides: { a: 'high' }, quietHours: { start: '01:00', end: '02:00', timezone: 'UTC' } };
    const model = N.modelFromConfig(base);
    model.severityOverrides.a = '';
    model.quiet.enabled = false;
    const out = N.buildConfig(base, model);
    assert.equal('severityOverrides' in out, false);
    assert.equal('quietHours' in out, false);
});

test('modelFromConfig defaults quiet-hours timezone to the browser zone when none is configured', () => {
    const m = N.modelFromConfig(null);
    assert.equal(m.quiet.enabled, false);
    assert.equal(m.quiet.timezone, Intl.DateTimeFormat().resolvedOptions().timeZone);
});

test('snapshot ignores connection order and disabled quiet-hours fields', () => {
    const a = N.modelFromConfig({ routes: { t: ['x', 'y'] } });
    const b = N.modelFromConfig({ routes: { t: ['y', 'x'] } });
    assert.equal(N.snapshot(a), N.snapshot(b));
    b.quiet.start = '03:33';
    assert.equal(N.snapshot(a), N.snapshot(b), 'disabled quiet hours do not make the form dirty');
    b.quiet.enabled = true;
    assert.notEqual(N.snapshot(a), N.snapshot(b));
});

test('validateQuietHours', () => {
    const ok = { enabled: true, start: '22:00', end: '07:00', timezone: 'America/Chicago' };
    assert.deepEqual(N.validateQuietHours(ok), {});
    assert.deepEqual(N.validateQuietHours({ enabled: false, start: '', end: '', timezone: '' }), {}, 'disabled is never invalid');
    assert.ok(N.validateQuietHours(Object.assign({}, ok, { end: '22:00' })).end, 'start == end');
    assert.ok(N.validateQuietHours(Object.assign({}, ok, { start: '' })).start);
    assert.ok(N.validateQuietHours(Object.assign({}, ok, { start: '24:00' })).start);
    assert.ok(N.validateQuietHours(Object.assign({}, ok, { end: '7:00' })).end);
    assert.ok(N.validateQuietHours(Object.assign({}, ok, { timezone: '' })).timezone);
    assert.ok(N.validateQuietHours(Object.assign({}, ok, { timezone: 'Mars/Base' })).timezone);
    assert.ok(N.validateQuietHours(Object.assign({}, ok, { timezone: 'x'.repeat(65) })).timezone);
    assert.deepEqual(N.validateQuietHours(Object.assign({}, ok, { timezone: 'UTC' })), {});
    // a window spanning midnight is valid
    assert.deepEqual(N.validateQuietHours(Object.assign({}, ok, { start: '23:59', end: '00:00' })), {});
});

test('effectiveSeverity: override wins, else the catalog default', () => {
    const e = { id: 't', defaultSeverity: 'info' };
    assert.equal(N.effectiveSeverity(e, { t: 'high' }), 'high');
    assert.equal(N.effectiveSeverity(e, {}), 'info');
});

test('classifyTestResult: ok / suppressed / partial / not-routed / error', () => {
    const label = (id) => id.toUpperCase();
    const rcpt = (id, extra) => Object.assign({ connectionId: id, provider: 'slack', ok: true }, extra);

    let v = N.classifyTestResult({ ok: true, deliveredVia: 'hub', result: { receipts: [rcpt('a')] } }, label);
    assert.equal(v.level, 'ok');
    assert.equal(v.lines[0].label, 'A');

    v = N.classifyTestResult({ ok: true, deliveredVia: 'none', result: { receipts: [rcpt('a', { ok: false, suppressed: 'quiet-hours' })] } }, label);
    assert.equal(v.level, 'suppressed');
    assert.equal(v.lines[0].detail, 'quiet hours');

    v = N.classifyTestResult({ ok: true, deliveredVia: 'hub', warning: 'w', result: { receipts: [rcpt('a'), rcpt('b', { ok: false, error: 'boom' })] } }, label);
    assert.equal(v.level, 'warn');
    assert.match(v.headline, /1 of 2/);
    assert.ok(v.warnings.includes('w'));

    v = N.classifyTestResult({ ok: false, result: { routed: false, reason: 'route-nowhere', receipts: [] } }, label);
    assert.equal(v.level, 'warn');
    assert.match(v.headline, /routed nowhere/);

    v = N.classifyTestResult({ ok: false, error: 'forbidden' }, label);
    assert.equal(v.level, 'error');
    assert.equal(v.headline, 'key belongs to another team (403)');

    v = N.classifyTestResult({ ok: false, result: { receipts: [rcpt('a', { ok: false, error: 'x' })] } }, label);
    assert.equal(v.level, 'error');
    assert.equal(v.headline, 'Delivery failed on every connection.');

    // 1 failed + 1 suppressed must not claim every connection failed (PR #1135 tester observation)
    v = N.classifyTestResult({ ok: false, result: { receipts: [rcpt('a', { ok: false, error: 'x' }), rcpt('b', { ok: false, suppressed: 'dedupe' })] } }, label);
    assert.equal(v.level, 'error');
    assert.equal(v.headline, 'Not delivered: 1 connection(s) failed, 1 suppressed.');

    v = N.classifyTestResult(null, label);
    assert.equal(v.level, 'error');
});
