'use strict';
// ============================================================================
// Per-machine dashboards overlay (XACA-1337-016)
// ============================================================================
//
// data/dashboards.json is SHIPPED (mirrored to the tap) and must not carry
// client-specific divisions (freelance-<client>-<project>). A machine that
// hosts client teams keeps them in a local overlay file, merged at load:
//
//   ~/.aiteamforge/dashboards.local.json   (override: $FLEET_DASHBOARDS_LOCAL_FILE)
//
//   {
//     "dashboards": [ { "id": "doublenode", "divisions": ["..."] } ],
//     "divisions":  [ { "id": "...", "name": "...", "description": "..." } ]
//   }
//
// Merge rules (by id, overlay wins):
//   - dashboards: an overlay entry whose id exists in the shipped file is a
//     PATCH (its fields override the shipped fields, shallow); an entry with a
//     new id is appended and must carry a name.
//   - divisions: same id -> replaced; new id -> appended.
//
// Absent overlay: the normal consumer case, merged == shipped.
// Malformed overlay: DashboardOverlayError — never silently ignored, because
// ignoring it renders the dashboard without the divisions it declares.
//
// WRITE-BACK: server.js CRUD routes write the config back to disk. They must
// never fold overlay content into the shipped file (that would re-leak client
// slugs into the tap mirror). splitForSave() separates a merged config back
// into its shipped part and its overlay part.

const fs = require('fs');
const os = require('os');
const path = require('path');

class DashboardOverlayError extends Error {
    constructor(message) {
        super(message);
        this.name = 'DashboardOverlayError';
    }
}

function overlayPath() {
    const override = (process.env.FLEET_DASHBOARDS_LOCAL_FILE || '').trim();
    if (override) return override;
    return path.join(os.homedir(), '.aiteamforge', 'dashboards.local.json');
}

function isPlainObject(v) {
    return v !== null && typeof v === 'object' && !Array.isArray(v);
}

function validateEntries(list, label, problems) {
    if (list === undefined) return;
    if (!Array.isArray(list)) {
        problems.push(`"${label}" must be an array`);
        return;
    }
    const seen = new Set();
    list.forEach((entry, i) => {
        if (!isPlainObject(entry)) {
            problems.push(`${label}[${i}] is not an object`);
            return;
        }
        if (typeof entry.id !== 'string' || entry.id.trim() === '') {
            problems.push(`${label}[${i}] has no string "id"`);
            return;
        }
        if (seen.has(entry.id)) problems.push(`duplicate ${label} id "${entry.id}"`);
        seen.add(entry.id);
        if (entry.divisions !== undefined
            && (!Array.isArray(entry.divisions) || entry.divisions.some((d) => typeof d !== 'string'))) {
            problems.push(`${label}[${i}] ("${entry.id}") "divisions" must be an array of strings`);
        }
    });
}

/**
 * Read and validate the overlay. Returns null when the file does not exist.
 * Throws DashboardOverlayError for anything else that is not a valid overlay.
 */
function readOverlay(file = overlayPath()) {
    let raw;
    try {
        raw = fs.readFileSync(file, 'utf8');
    } catch (err) {
        if (err && err.code === 'ENOENT') return null;
        throw new DashboardOverlayError(`cannot read dashboards overlay ${file}: ${err.message}`);
    }
    let parsed;
    try {
        parsed = JSON.parse(raw);
    } catch (err) {
        throw new DashboardOverlayError(`dashboards overlay ${file} is not valid JSON: ${err.message}`);
    }
    const problems = [];
    if (!isPlainObject(parsed)) {
        problems.push('root is not a JSON object');
    } else {
        validateEntries(parsed.dashboards, 'dashboards', problems);
        validateEntries(parsed.divisions, 'divisions', problems);
        if (parsed.dashboards === undefined && parsed.divisions === undefined) {
            problems.push('declares neither "dashboards" nor "divisions"');
        }
    }
    if (problems.length) {
        throw new DashboardOverlayError(`dashboards overlay ${file} is malformed: ${problems.join('; ')}`);
    }
    return parsed;
}

function mergeById(shippedList, overlayList, patch) {
    const out = (shippedList || []).map((e) => ({ ...e }));
    const index = new Map(out.map((e, i) => [e.id, i]));
    for (const o of overlayList || []) {
        if (index.has(o.id)) {
            const i = index.get(o.id);
            out[i] = patch ? { ...out[i], ...o } : { ...o };
        } else {
            out.push({ ...o });
            index.set(o.id, out.length - 1);
        }
    }
    return out;
}

/**
 * Merge an overlay (or null) onto a shipped config. Pure; never mutates inputs.
 */
function mergeDashboardConfig(shipped, overlay) {
    const base = shipped || {};
    if (!overlay) return base;
    const appended = (overlay.dashboards || []).filter(
        (o) => !(base.dashboards || []).some((d) => d.id === o.id)
            && (typeof o.name !== 'string' || o.name.trim() === ''));
    if (appended.length) {
        throw new DashboardOverlayError(
            `dashboards overlay adds dashboard(s) without a "name": ${appended.map((o) => o.id).join(', ')} `
            + '(a new dashboard needs a full definition; only a patch of an existing id may be partial)');
    }
    return {
        ...base,
        dashboards: mergeById(base.dashboards, overlay.dashboards, true),
        divisions: mergeById(base.divisions, overlay.divisions, false),
    };
}

function splitList(mergedList, shippedList, overlayList, patch) {
    const shippedById = new Map((shippedList || []).map((e) => [e.id, e]));
    const overlayById = new Map((overlayList || []).map((e) => [e.id, e]));
    const shippedOut = [];
    const overlayOut = [];
    for (const entry of mergedList || []) {
        const ov = overlayById.get(entry.id);
        const sh = shippedById.get(entry.id);
        if (!ov) {
            shippedOut.push(entry);
            continue;
        }
        if (!sh) {
            // Overlay-only entry: lives entirely in the overlay.
            overlayOut.push(entry);
            continue;
        }
        if (!patch) {
            // Replaced entry: the overlay owns the whole thing; shipped keeps its own.
            overlayOut.push(entry);
            shippedOut.push(sh);
            continue;
        }
        // Patched entry: overlay-owned fields go back to the overlay, every other
        // field (e.g. sort_order after a reorder) stays with the shipped entry.
        const ovOut = { id: entry.id };
        const shOut = { ...entry };
        for (const key of Object.keys(ov)) {
            if (key === 'id') continue;
            if (Object.prototype.hasOwnProperty.call(entry, key)) ovOut[key] = entry[key];
            if (Object.prototype.hasOwnProperty.call(sh, key)) shOut[key] = sh[key];
            else delete shOut[key];
        }
        overlayOut.push(ovOut);
        shippedOut.push(shOut);
    }
    // Keep the overlay file's own entry order stable across writes (the merged
    // view interleaves overlay entries into shipped positions).
    const order = new Map((overlayList || []).map((e, i) => [e.id, i]));
    overlayOut.sort((a, b) => order.get(a.id) - order.get(b.id));
    return { shippedOut, overlayOut };
}

/**
 * Split a merged config into { shipped, overlay } for writing. `shippedRaw` and
 * `overlay` are the files as they were loaded. When overlay is null the merged
 * config IS the shipped config.
 */
function splitForSave(merged, shippedRaw, overlay) {
    if (!overlay) return { shipped: merged, overlay: null };
    const d = splitList(merged.dashboards, (shippedRaw || {}).dashboards, overlay.dashboards, true);
    const v = splitList(merged.divisions, (shippedRaw || {}).divisions, overlay.divisions, false);
    const shipped = { ...merged, dashboards: d.shippedOut, divisions: v.shippedOut };
    const overlayOut = { ...overlay };
    if (overlay.dashboards !== undefined || d.overlayOut.length) overlayOut.dashboards = d.overlayOut;
    if (overlay.divisions !== undefined || v.overlayOut.length) overlayOut.divisions = v.overlayOut;
    return { shipped, overlay: overlayOut };
}

module.exports = {
    DashboardOverlayError,
    overlayPath,
    readOverlay,
    mergeDashboardConfig,
    splitForSave,
};
