//
//  generate-xaca-0990-001-baseline.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * One-time (or deliberate re-run) generator for the XACA-0990-001 golden
 * baseline. NOT part of the automated `npm test` run -- invoke manually:
 *
 *   node tests/scripts/generate-xaca-0990-001-baseline.js
 *
 * Uses the exact same matrix/capture/serialize code
 * (tests/helpers/lcars-terminal-card-matrix.js) that the characterization
 * test replays every run, so the baseline and the replay can never drift
 * apart by using two hand-written copies of the same logic.
 *
 * Only re-run this deliberately (e.g. after a proven, intentional behavior
 * change) -- regenerating it to make a failing test pass defeats the whole
 * point of a characterization baseline.
 */
const fs = require('node:fs');
const path = require('node:path');
const { computeAllResults, stableStringify } = require('../helpers/lcars-terminal-card-matrix.js');

const OUT_PATH = path.join(__dirname, '..', 'xaca-0990-001-lcars-terminal-card-baseline.json');

const results = computeAllResults();
const json = stableStringify(results);
fs.writeFileSync(OUT_PATH, json, 'utf8');
console.log('Wrote baseline to ' + OUT_PATH + ' (' + json.length + ' bytes)');
