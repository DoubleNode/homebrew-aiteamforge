'use strict';
// XACA-1393: the ACCESSORIES sidebar button must carry its own background (and
// an inverted .active rule) in BOTH dashboards. Without one it paints in the
// sidebar's own colour and reads as blank space -- the XACA-1474 defect. The
// XACA-1474 suite guards v1 only, so lcars2 is pinned here too.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const PUBLIC_ROOT = path.join(__dirname, '..', 'public');
const SHEETS = ['lcars/css/lcars-fleet.css', 'lcars2/css/lcars-fleet.css'];
const BASE = '.sidebar-button[data-section="accessories"]';

function ruleBody(css, selector) {
    const esc = selector.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const m = css.match(new RegExp(`(^|\\n)\\s*${esc}\\s*\\{([^}]*)\\}`));
    return m ? m[2] : null;
}

for (const rel of SHEETS) {
    const css = fs.readFileSync(path.join(PUBLIC_ROOT, rel), 'utf8');

    test(`${rel}: ACCESSORIES button has its own background`, () => {
        const body = ruleBody(css, BASE);
        assert.ok(body, `${BASE} has no rule in ${rel}`);
        assert.match(body, /background\s*:\s*var\(--lcars-[a-z-]+\)/);
    });

    test(`${rel}: ACCESSORIES .active state inverts`, () => {
        const body = ruleBody(css, `${BASE}.active`);
        assert.ok(body, `${BASE}.active has no rule in ${rel}`);
        assert.match(body, /background\s*:\s*var\(--lcars-black\)/);
    });
}
