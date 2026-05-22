//
//  engines-store.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * engines-store.js
 * XACA-0281: AI engines registry — persistent store helpers.
 *
 * Exports: readEngines(), writeEngines(data), findEngine(slug), findAccount(engineSlug, accountSlug)
 *
 * File: fleet-monitor/server/data/engines.json
 * Schema version: 1
 *
 * Pattern: matches existing fleet-monitor stores (fs.writeFileSync, auto-create on missing).
 */

const fs   = require('fs');
const path = require('path');

// Default path is unchanged production behavior. FLEET_ENGINES_FILE is an ADDITIVE
// test seam (XACA-0537-006): when set, the store reads/writes that path instead,
// letting tests point at isolated temp files so they never touch the real
// data/engines.json. Default (env unset) is byte-identical to prior behavior.
const ENGINES_FILE = process.env.FLEET_ENGINES_FILE || path.join(__dirname, '..', 'data', 'engines.json');

/** Seed shape written when engines.json does not yet exist. */
const SEED = {
    version: 1,
    updated_at: new Date().toISOString(),
    engines: [
        {
            slug: 'anthropic',
            name: 'Anthropic',
            auth_header: 'x-api-key',
            auth_header_extra: { 'anthropic-version': '2023-06-01' },
            base_url: 'https://api.anthropic.com',
            probe_endpoint: '/v1/messages',
            probe_model: 'claude-haiku-4-5',
            created_at: new Date().toISOString(),
            updated_at: new Date().toISOString(),
            accounts: []
        }
    ]
};

/**
 * Read the engines registry from disk.
 * Auto-creates engines.json with the seed shape if it does not exist.
 * @returns {{ version: number, updated_at: string, engines: Array }}
 */
function readEngines() {
    try {
        if (fs.existsSync(ENGINES_FILE)) {
            return JSON.parse(fs.readFileSync(ENGINES_FILE, 'utf8'));
        }
    } catch (err) {
        console.error('[engines-store] Error reading engines.json:', err.message);
    }

    // File missing or unreadable — seed it
    const seed = JSON.parse(JSON.stringify(SEED)); // deep copy
    seed.updated_at = new Date().toISOString();
    seed.engines[0].created_at = seed.updated_at;
    seed.engines[0].updated_at = seed.updated_at;
    writeEngines(seed);
    return seed;
}

/**
 * Persist the engines registry to disk.
 * @param {{ version: number, updated_at: string, engines: Array }} data
 * @returns {boolean} true on success
 */
function writeEngines(data) {
    const dir = path.dirname(ENGINES_FILE);
    const tmp = `${ENGINES_FILE}.tmp.${process.pid}`;
    try {
        if (!fs.existsSync(dir)) {
            fs.mkdirSync(dir, { recursive: true });
        }
        // Write to a temp file then rename — atomic on POSIX; avoids torn writes on crash.
        fs.writeFileSync(tmp, JSON.stringify(data, null, 2));
        fs.renameSync(tmp, ENGINES_FILE);
        return true;
    } catch (err) {
        console.error('[engines-store] Error writing engines.json:', err.message);
        // Best-effort cleanup of the temp file.
        try { fs.unlinkSync(tmp); } catch (_) {}
        return false;
    }
}

/**
 * Find a single engine by slug.
 * @param {string} slug
 * @returns {object|null}
 */
function findEngine(slug) {
    const registry = readEngines();
    return registry.engines.find(e => e.slug === slug) || null;
}

/**
 * Find a single account within an engine by engine slug + account slug.
 * @param {string} engineSlug
 * @param {string} accountSlug
 * @returns {object|null}
 */
function findAccount(engineSlug, accountSlug) {
    const engine = findEngine(engineSlug);
    if (!engine) return null;
    return engine.accounts.find(a => a.slug === accountSlug) || null;
}

module.exports = { readEngines, writeEngines, findEngine, findAccount };
