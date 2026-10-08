//
//  xaca-1393-003-lcars2-on-battery-card.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1393-003 (D2): the lcars2 machine card renders the SERVER-derived
 * display_status. on_battery -> its own `.on-battery` class + a mandatory
 * "ON UPS BATTERY · nn% · ~nn MIN" label (null parts omitted), distinct from
 * the heartbeat `.warning`. Missing display_status falls back to `status`;
 * a hostile display_status can never become a class name or markup.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');

const CORE = path.join(__dirname, '..', 'public', 'lcars2', 'js', 'lcars-fleet-core.js');
const THEME = path.join(__dirname, '..', 'public', 'lcars2', 'css', 'lcars-fleet-theme.css');

function loadCore() {
    const dom = new JSDOM('<!doctype html><body></body>', { runScripts: 'outside-only' });
    dom.window.eval(fs.readFileSync(CORE, 'utf8'));
    const LCARS = dom.window.LCARS_CORE || dom.window.LCARS;
    assert.ok(LCARS && LCARS.machines && LCARS.machines.createMachineItem, 'core exposes machines.createMachineItem');
    return { dom, LCARS };
}

const deps = {
    machineSystemToHealthInput: function () { return {}; },
    healthBadgeSpec: function () { return null; },
    buildSystemSectionHtml: function () { return ''; },
    toggleSystemPanel: function () {}
};

function render(machine) {
    const { dom, LCARS } = loadCore();
    const frag = LCARS.machines.createMachineItem(Object.assign({
        hostname: 'host-a', machine_id: 'm1', session_count: 2
    }, machine), deps);
    const row = frag.firstElementChild;
    // Detached nodes stay queryable after close(); closing stops core timers
    // so the test process can exit.
    dom.window.close();
    return row;
}

test('online / warning / offline keep their classes and carry no power label', () => {
    for (const s of ['online', 'warning', 'offline']) {
        const row = render({ status: s, display_status: s });
        assert.equal(row.className, 'status-row ' + s);
        assert.equal(row.querySelector('.status-indicator').className, 'status-indicator ' + s);
        assert.equal(row.querySelector('.status-row-power-label'), null);
    }
});

test('on_battery full power_reason: class, dot and exact label', () => {
    const row = render({ status: 'online', display_status: 'on_battery',
        power_reason: { accessory_id: 'u1', accessory_name: 'UPS', percent: 85, minutes_remaining: 40 } });
    assert.equal(row.className, 'status-row on-battery');
    assert.equal(row.querySelector('.status-indicator').className, 'status-indicator on-battery');
    const label = row.querySelector('.status-row-power-label');
    assert.equal(label.textContent, 'ON UPS BATTERY · 85% · ~40 MIN');
    assert.equal(label.getAttribute('role'), null, 'no live region: cards rebuild every poll');
    assert.ok(!/\bwarning\b/.test(row.className));
});

test('on_battery label keeps heartbeat-late warning machines distinguishable and omits null parts', () => {
    const none = render({ status: 'warning', display_status: 'on_battery', power_reason: null });
    assert.equal(none.querySelector('.status-row-power-label').textContent, 'ON UPS BATTERY');
    const pctOnly = render({ status: 'online', display_status: 'on_battery',
        power_reason: { percent: 61.6, minutes_remaining: null } });
    assert.equal(pctOnly.querySelector('.status-row-power-label').textContent, 'ON UPS BATTERY · 62%');
    const minOnly = render({ status: 'online', display_status: 'on_battery',
        power_reason: { percent: null, minutes_remaining: 12 } });
    assert.equal(minOnly.querySelector('.status-row-power-label').textContent, 'ON UPS BATTERY · ~12 MIN');
});

test('label sits between hostname and version/session spans; session count stays last', () => {
    const row = render({ status: 'online', display_status: 'on_battery', power_reason: { percent: 50 },
        system: { versions: { aiteamforge: '1.2.3', outdated: false } } });
    const kids = Array.from(row.children).map(c => c.className.split(' ').find(x => /^(status-row-|lcars-text-xs$)/.test(x)) || c.className);
    assert.equal(row.children[1].classList.contains('status-row-hostname'), true);
    assert.equal(row.children[2].classList.contains('status-row-power-label'), true);
    assert.equal(row.children[3].classList.contains('status-row-version'), true);
    assert.match(row.lastElementChild.textContent, /sessions$/, kids.join(','));
});

test('missing display_status falls back to heartbeat status (old server)', () => {
    assert.equal(render({ status: 'warning' }).className, 'status-row warning');
    assert.equal(render({ status: 'online' }).className, 'status-row online');
    assert.equal(render({ status: 'offline', power_state: 'on_battery' }).className, 'status-row offline');
});

test('hostile display_status / power_reason never becomes a class or markup', () => {
    const row = render({ status: 'online', display_status: '"><img src=x onerror=alert(1)>' });
    assert.equal(row.className, 'status-row online');
    assert.equal(row.querySelector('img'), null);
    const row2 = render({ status: 'online', display_status: 'on_battery',
        power_reason: { percent: '<img src=x onerror=1>', minutes_remaining: { toString: 'x' } } });
    assert.equal(row2.querySelector('img'), null);
    assert.equal(row2.querySelector('.status-row-power-label').textContent, 'ON UPS BATTERY');
});

test('CSS: on-battery stripe/label rules exist and come after every .status-row block', () => {
    const css = fs.readFileSync(THEME, 'utf8');
    const iBat = css.indexOf('.status-row.on-battery {');
    assert.ok(iBat > 0);
    assert.equal(css.lastIndexOf('.status-row:hover {') < iBat, true, 'on-battery must follow the last .status-row:hover');
    assert.equal(css.lastIndexOf('.status-row.warning {') < iBat, true);
    assert.match(css, /\.status-row-power-label\s*\{/);
    assert.match(css, /\.status-indicator\.on-battery\s*\{[^}]*animation:\s*none/);
});
