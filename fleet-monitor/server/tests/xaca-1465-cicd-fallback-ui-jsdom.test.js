//
//  xaca-1465-cicd-fallback-ui-jsdom.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1465-005 -- jsdom tests for the CI/CD fallback switch pills driven by
 * fallback.switches[]. Loads the REAL public/lcars/js/lcars-cicd.js.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');

const CICD_JS = path.join(__dirname, '..', 'public', 'lcars', 'js', 'lcars-cicd.js');
const FIXTURE = path.join(__dirname, 'fixtures', 'xaca-1388-ci-runners-healthy.json');

function render(fallback) {
    assert.ok(fs.existsSync(CICD_JS), 'MISSING IMPLEMENTATION');
    const dom = new JSDOM('<!doctype html><html><body><div id="cicd-content"></div></body></html>',
        { runScripts: 'outside-only', url: 'http://localhost/' });
    dom.window.eval(fs.readFileSync(CICD_JS, 'utf8'));
    const data = JSON.parse(fs.readFileSync(FIXTURE, 'utf8'));
    data.fallback = fallback;
    const el = dom.window.document.getElementById('cicd-content');
    dom.window.LCARSCICD.render(data, el);
    return el;
}

const sw = (variable, label, armed, extra) => Object.assign(
    { owner: 'DoubleNode', repo: 'dev-team', variable, label, armed, reason: null, error: null, checkedAt: null }, extra || {});
const pills = (el) => Array.from(el.querySelectorAll('[data-cicd-slot="pills"] .cicd-pill'));

test('3 dev-team switches: pills, states, classes, reason in tooltip', () => {
    const el = render({ linux: null, macos: null, checkedAt: null, switches: [
        sw('CI_LINUX_RUNNER', 'LINUX', true),
        sw('CI_MACOS_RUNNER', 'MACOS', false),
        sw('CI_EXTRA', 'EXTRA', null, { reason: 'value is not valid JSON' })
    ] });
    const p = pills(el);
    assert.equal(p.length, 3);
    assert.deepEqual(p.map(x => x.getAttribute('data-cicd-state')), ['SELF-HOSTED', 'HOSTED', 'UNKNOWN']);
    assert.deepEqual(p.map(x => x.className.replace('cicd-pill ', '')), ['selfhosted', 'fallback', 'unknown']);
    assert.equal(p[0].getAttribute('data-cicd-switch'), 'DoubleNode/dev-team/CI_LINUX_RUNNER');
    assert.match(p[2].getAttribute('title'), /value is not valid JSON/);
    assert.match(p[2].textContent, /value is not valid JSON/, 'sr-only text carries the reason too');
    assert.equal(el.querySelectorAll('.cicd-group-label').length, 0, 'single repo: no group label');
});

test('armed:true + error stays SELF-HOSTED and tooltip shows last read failed', () => {
    const el = render({ switches: [sw('CI_LINUX_RUNNER', 'LINUX', true, { error: 'HTTP 502' })] });
    const p = pills(el)[0];
    assert.equal(p.getAttribute('data-cicd-state'), 'SELF-HOSTED');
    assert.match(p.getAttribute('title'), /last read failed: HTTP 502/);
});

test('malicious label/reason/repo/error are escaped, nothing injected', () => {
    const bad = '<img src=x onerror=alert(1)>';
    const el = render({ switches: [
        sw('V"><b id=pwn>', bad, null, { reason: bad, error: bad, owner: bad, repo: bad })
    ] });
    assert.equal(el.querySelector('img'), null);
    assert.equal(el.querySelector('#pwn'), null);
    assert.equal(el.querySelector('b'), null);
    assert.ok(pills(el)[0].textContent.includes(bad), 'rendered as literal text');
});

test('non-boolean truthy armed renders UNKNOWN (strict === true)', () => {
    const el = render({ switches: [sw('A', 'A', 'true'), sw('B', 'B', 1)] });
    assert.deepEqual(pills(el).map(x => x.getAttribute('data-cicd-state')), ['UNKNOWN', 'UNKNOWN']);
    assert.equal(el.querySelectorAll('.cicd-pill.selfhosted').length, 0);
});

test('legacy payload without switches renders the two LINUX/MACOS pills', () => {
    const el = render({ linux: { armed: true, value: 'x' }, macos: { armed: false, value: null }, checkedAt: null });
    const p = pills(el);
    assert.equal(p.length, 2);
    assert.equal(el.querySelector('[data-cicd-fallback="linux"]').getAttribute('data-cicd-state'), 'SELF-HOSTED');
    assert.equal(el.querySelector('[data-cicd-fallback="macos"]').getAttribute('data-cicd-state'), 'HOSTED');
    assert.equal(el.querySelector('[data-cicd-switch]'), null);
});

test('fallback null renders UNKNOWN LINUX/MACOS as before', () => {
    const el = render(null);
    assert.deepEqual(pills(el).map(x => x.getAttribute('data-cicd-state')), ['UNKNOWN', 'UNKNOWN']);
});

test('switches: [] renders a single empty note, no pills', () => {
    const el = render({ switches: [] });
    assert.equal(pills(el).length, 0);
    assert.match(el.querySelector('[data-cicd-switches-empty]').textContent, /NO SWITCHES CONFIGURED/);
    // de-dupe: a bare attribute re-serializes as ="" and would rewrite (re-announce) every poll
    const data = JSON.parse(fs.readFileSync(FIXTURE, 'utf8'));
    data.fallback = { switches: [] };
    const node = el.querySelector('[data-cicd-switches-empty]');
    el.ownerDocument.defaultView.LCARSCICD.render(data, el);
    assert.equal(el.querySelector('[data-cicd-switches-empty]'), node, 'same node: markup unchanged => no churn');
});

test('two repos are grouped by repo with group labels', () => {
    const el = render({ switches: [
        sw('CI_LINUX_RUNNER', 'LINUX', true),
        sw('CI_X', 'X', false, { repo: 'other' }),
        sw('CI_MACOS_RUNNER', 'MACOS', false)
    ] });
    const groups = el.querySelectorAll('.cicd-pill-group');
    assert.equal(groups.length, 2);
    assert.equal(groups[0].getAttribute('data-cicd-repo'), 'DoubleNode/dev-team');
    assert.equal(groups[0].querySelectorAll('.cicd-pill').length, 2);
    assert.equal(groups[1].getAttribute('data-cicd-repo'), 'DoubleNode/other');
    assert.deepEqual(Array.from(el.querySelectorAll('.cicd-group-label')).map(x => x.textContent), ['dev-team', 'other']);
});

// ---- XACA-1465-019: visible reasons ------------------------------------------
test('UNKNOWN reason and last-read error are visible text, escaped, inside the live region', () => {
    const el = render({ switches: [
        sw('CI_LINUX_HEAVY_RUNNER', 'LINUX HEAVY', null, { reason: 'value is not valid JSON' }),
        sw('CI_MACOS_RUNNER', 'MACOS', true, { error: 'GitHub rate limit reached' }),
        sw('CI_X', 'X', null, { reason: '<img src=x onerror=1>' })
    ] });
    const line = el.querySelector('[data-cicd-slot="pills"] [data-cicd-switch-reasons]');
    assert.ok(line, 'reason line lives inside the pills live region');
    assert.match(line.textContent, /LINUX HEAVY: value is not valid JSON/);
    assert.match(line.textContent, /MACOS: last read failed \(GitHub rate limit reached\)/);
    assert.equal(line.querySelector('img'), null, 'escaped');
    assert.ok(line.classList.contains('cicd-sub'));
});

test('healthy switches render no reason line; unchanged re-render does not touch the live region', () => {
    const el = render({ switches: [sw('A', 'A', true), sw('B', 'B', false)] });
    assert.equal(el.querySelector('[data-cicd-switch-reasons]'), null);
    // de-dupe: identical bad payload re-rendered keeps the SAME node (no re-announcement)
    const dom = new JSDOM('<!doctype html><body><div id="cicd-content"></div></body>', { runScripts: 'outside-only', url: 'http://localhost/' });
    dom.window.eval(fs.readFileSync(CICD_JS, 'utf8'));
    const data = JSON.parse(fs.readFileSync(FIXTURE, 'utf8'));
    data.fallback = { switches: [sw('A', 'A', null, { reason: 'boom' })] };
    const host = dom.window.document.getElementById('cicd-content');
    dom.window.LCARSCICD.render(data, host);
    const node = host.querySelector('[data-cicd-switch-reasons]');
    dom.window.LCARSCICD.render(data, host);
    assert.equal(host.querySelector('[data-cicd-switch-reasons]'), node, 'same node: markup unchanged => no churn');
});

test('fallsBackTo shows in the tooltip when present and is tolerated when absent', () => {
    const el = render({ switches: [
        sw('CI_LINUX_HEAVY_RUNNER', 'LINUX HEAVY', true, { fallsBackTo: 'CI_LINUX_RUNNER', reason: 'unset: follows CI_LINUX_RUNNER' }),
        sw('CI_MACOS_RUNNER', 'MACOS', true)
    ] });
    const p = pills(el);
    assert.match(p[0].getAttribute('title'), /follows CI_LINUX_RUNNER/);
    assert.doesNotMatch(p[1].getAttribute('title'), /follows/);
});
