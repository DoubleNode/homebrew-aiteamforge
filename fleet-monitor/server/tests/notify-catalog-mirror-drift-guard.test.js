//
//  notify-catalog-mirror-drift-guard.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1400-002: the Fly image only contains fleet-monitor/server/, so the
 * canonical notice-type catalog (kanban-hooks/notice_types.json) is bundled at
 * config/notice_types.json. The two files must stay byte-identical.
 * Fix drift by re-copying the canonical file, never by editing the mirror.
 */

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const CANON = path.join(__dirname, '..', '..', '..', 'kanban-hooks', 'notice_types.json');
const MIRROR = path.join(__dirname, '..', 'config', 'notice_types.json');

test('bundled catalog mirror is byte-identical to the canonical catalog', () => {
    assert.ok(fs.existsSync(MIRROR), 'config/notice_types.json must exist');
    if (!fs.existsSync(CANON)) return; // image/checkouts without kanban-hooks/: nothing to compare
    assert.ok(
        fs.readFileSync(CANON).equals(fs.readFileSync(MIRROR)),
        'fleet-monitor/server/config/notice_types.json drifted from kanban-hooks/notice_types.json; re-copy the canonical file'
    );
});

test('negative control: the comparison flips when the mirror differs', () => {
    const a = fs.readFileSync(MIRROR);
    const b = Buffer.concat([a, Buffer.from(' ')]);
    assert.equal(a.equals(b), false);
});

test('bundled catalog validates as a canonical catalog', () => {
    const { loadCanonicalCatalog } = require('../lib/notify-team-routes');
    const doc = loadCanonicalCatalog(MIRROR);
    assert.ok(doc.types.length > 0);
});
