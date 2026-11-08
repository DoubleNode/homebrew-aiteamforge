#!/usr/bin/env node
//
//  test-xaca-1706-filter-bar-released.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright (c) 2026 DoubleNode.com. All rights reserved.
//

/**
 * XACA-1706 [Review]: the filter bar's release dropdown must not list status=released releases under
 * "Active" (the server's ?status=active returns them). They get their own "Released" group.
 * Extracts the real _populateReleaseOptions from lcars-filter-bar.js and runs it on stubs.
 *
 * Run: node lcars-ui/tests/test-xaca-1706-filter-bar-released.js
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const source = fs.readFileSync(path.join(__dirname, '..', 'js', 'lcars-filter-bar.js'), 'utf8');

let failures = 0;
function check(name, actual, expected) {
    const a = JSON.stringify(actual);
    const e = JSON.stringify(expected);
    if (a === e) {
        console.log('ok - ' + name);
    } else {
        failures += 1;
        console.error('FAIL: ' + name + '\n  expected ' + e + '\n  actual   ' + a);
    }
}

function extract(sig) {
    const start = source.indexOf(sig);
    if (start === -1) throw new Error('not found: ' + sig);
    const bodyStart = source.indexOf('{', source.indexOf(')', start));
    let depth = 0;
    for (let i = bodyStart; i < source.length; i++) {
        if (source[i] === '{') depth++;
        else if (source[i] === '}' && --depth === 0) return source.slice(start, i + 1);
    }
    throw new Error('unbalanced: ' + sig);
}

function makeSelect() {
    const options = [{ value: 'all' }, { value: 'assigned' }, { value: 'unassigned' }];
    return {
        options,
        value: 'all',
        remove(i) { options.splice(i, 1); },
        appendChild(o) { options.push(o); Object.defineProperty(options, 'length', { value: options.length, writable: true }); },
    };
}

async function run(active, archived) {
    const select = makeSelect();
    const ctx = {
        document: {
            getElementById: (id) => (id === 'release-filter-select' ? select : null),
            createElement: () => ({}),
        },
        releaseOptionsEndpoint: '/api/releases',
        apiUrl: (u) => u,
        state: { releaseFilter: 'all' },
        console,
        fetch: async (url) => ({
            ok: true,
            json: async () => ({ releases: url.indexOf('status=archived') !== -1 ? archived : active }),
        }),
    };
    vm.createContext(ctx);
    vm.runInContext(extract('async function _populateReleaseOptions') + '\n;this._run = _populateReleaseOptions;', ctx);
    await ctx._run();
    return select.options.slice(3).map((o) => (o.value === '---' ? '[' + o.textContent + ']' : o.value));
}

(async () => {
    const live = { id: 'LIVE', name: 'Live', status: 'in_progress', targetDate: '2026-03-01' };
    const live2 = { id: 'LIVE2', name: 'Live2', status: 'active', targetDate: '2026-02-01' };
    const shipped = { id: 'SHIP', name: 'Shipped', status: 'released', targetDate: '2026-01-01' };
    const arch = { id: 'ARCH', name: 'Arch', status: 'archived', archivedAt: '2026-01-01T00:00:00Z' };

    check('released releases get their own group, not Active',
        await run([live, shipped, live2], [arch]),
        ['[── Active ──]', 'LIVE2', 'LIVE', '[── Released ──]', 'SHIP', '[── Archived ──]', 'ARCH']);
    check('no released releases: no Released separator',
        await run([live], []), ['[── Active ──]', 'LIVE']);
    check('only released releases: no empty Active group',
        await run([shipped], []), ['[── Released ──]', 'SHIP']);

    if (failures > 0) {
        console.error('\n' + failures + ' test(s) failed.');
        process.exit(1);
    }
    console.log('All XACA-1706 filter-bar released tests passed.');
})();
