//
//  notify-team-routes.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * Team route validation + catalog merge (XACA-1400-002, EPIC-0068 D2/D3/D6).
 *
 * A faithful JS port of the contract owned by XACA-1399:
 *   - scripts/release_config_schemas/notify-v2.schema.json   (structure)
 *   - kanban-hooks/release_notify_routing.py                 (merge_catalog,
 *     validate_team_override, validate_v2_semantics)
 * No ajv / no new dependency: the structural checks are hand-written.
 *
 * The canonical Academy catalog is bundled at config/notice_types.json (the Fly
 * build context is fleet-monitor/server/ only; a drift-guard test keeps it
 * byte-identical to kanban-hooks/notice_types.json).
 *
 * Error messages name field paths and ids only. They never echo whole values.
 */

const fs   = require('fs');
const path = require('path');
const { isValidTimeZone } = require('./notify-policies');

const SEVERITIES = ['info', 'warning', 'high', 'critical'];
const CATALOG_TAG = 'notice-types/v1';
const V2_TAG = 'release-notify/v2';
const MAX_ROUTE_TYPES = 64;
const MAX_CONNECTIONS_PER_TYPE = 16;
const MAX_CATALOG_TYPES = 64;
const MAX_ALIASES = 64;

const ID_RE = /^[a-z][a-z0-9-]{0,31}(?![\s\S])/;
const ALIAS_RE = /^[a-z][a-z0-9-]{0,31}(?![\s\S])/;
const HHMM_RE = /^([01][0-9]|2[0-3]):([0-5][0-9])(?![\s\S])/;
const TZ_RE = /^[A-Za-z][A-Za-z0-9_+-]*(\/[A-Za-z0-9_+-]+){0,2}(?![\s\S])/;
const SECRET_REF_RE = /^(vault:[a-z][a-z0-9-]{0,63}\/[a-z][a-z0-9-]{0,63}|env:RELEASE_[A-Z][A-Z0-9_]*)(?![\s\S])/;
const TEAM_RE = /^[a-z][a-z0-9-]{0,63}$/;
const TYPE_KEYS = new Set(['id', 'defaultSeverity', 'description']);
const ALIAS_PROVIDERS = ['teams', 'slack', 'sms', 'email'];
const TOP_KEYS = new Set(['$schema', 'version', 'aliases', 'routes', 'severityOverrides', 'quietHours', 'dedupeWindow']);

const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const safeId = (v) => (typeof v === 'string' && ID_RE.test(v) ? v : '<invalid-id>');

function defaultCatalogFile() {
    return path.join(__dirname, '..', 'config', 'notice_types.json');
}

// ---------------------------------------------------------------- catalog

function validateEntries(doc, full, label) {
    const errs = [];
    if (!isObj(doc)) return [`${label}: must be a JSON object`];
    for (const k of Object.keys(doc)) {
        if (!['$schema', 'schemaVersion', 'types'].includes(k)) { errs.push(`${label}: unexpected top-level field(s)`); break; }
    }
    if (doc.$schema !== CATALOG_TAG) errs.push(`${label}: $schema must be ${CATALOG_TAG}`);
    if (doc.schemaVersion !== 1) errs.push(`${label}: schemaVersion must be 1`);
    const types = doc.types;
    if (!Array.isArray(types) || types.length === 0) {
        errs.push(`${label}: types must be a non-empty list`);
        return errs;
    }
    const seen = new Set();
    types.forEach((ent, i) => {
        const where = `${label}.types[${i}]`;
        if (!isObj(ent)) { errs.push(`${where}: must be an object`); return; }
        const tid = ent.id;
        if (typeof tid !== 'string' || !ID_RE.test(tid)) { errs.push(`${where}: id missing or malformed`); return; }
        if (seen.has(tid)) errs.push(`${where}: duplicate id '${tid}'`);
        seen.add(tid);
        if (Object.keys(ent).some((k) => !TYPE_KEYS.has(k))) errs.push(`${where} '${tid}': unexpected field(s)`);
        if ('defaultSeverity' in ent && !SEVERITIES.includes(ent.defaultSeverity)) {
            errs.push(`${where} '${tid}': defaultSeverity is not one of ${SEVERITIES.join('|')}`);
        }
        if ('description' in ent) {
            const d = ent.description;
            if (typeof d !== 'string' || d.trim() === '' || d.length > 200) errs.push(`${where} '${tid}': description must be 1-200 chars`);
        }
        if (full) {
            for (const k of ['defaultSeverity', 'description']) {
                if (!(k in ent)) errs.push(`${where} '${tid}': ${k} is required`);
            }
        }
    });
    return errs;
}

function validateCatalog(doc) { return validateEntries(doc, true, 'catalog'); }
function validateTeamOverride(doc) { return validateEntries(doc, false, 'team notice_types.json'); }

/** canonical + optional team layer -> {id: {id, defaultSeverity, description, source, severitySource}}. Throws Error on any invalid layer. */
function mergeCatalog(canonical, team) {
    let errs = validateCatalog(canonical);
    if (errs.length) throw new Error(`notice-type catalog invalid: ${errs.join('; ')}`);
    const merged = {};
    for (const ent of canonical.types) {
        merged[ent.id] = {
            id: ent.id, defaultSeverity: ent.defaultSeverity, description: ent.description,
            source: 'default', severitySource: 'catalog',
        };
    }
    if (team === null || team === undefined) return merged;
    errs = validateTeamOverride(team);
    if (errs.length) throw new Error(`team notice_types.json invalid: ${errs.join('; ')}`);
    for (const ent of team.types) {
        const tid = ent.id;
        if (Object.prototype.hasOwnProperty.call(merged, tid)) {
            if ('defaultSeverity' in ent && ent.defaultSeverity !== merged[tid].defaultSeverity) {
                merged[tid].severitySource = 'team-catalog';
            }
            for (const k of ['defaultSeverity', 'description']) if (k in ent) merged[tid][k] = ent[k];
            merged[tid].source = 'override';
        } else {
            const missing = ['defaultSeverity', 'description'].filter((k) => !(k in ent));
            if (missing.length) throw new Error(`team notice_types.json: new type '${tid}' must define ${missing.join(' and ')}`);
            merged[tid] = {
                id: tid, defaultSeverity: ent.defaultSeverity, description: ent.description,
                source: 'team', severitySource: 'team-catalog',
            };
        }
    }
    return merged;
}

/** Load + validate the bundled canonical catalog document. Throws on missing/invalid. */
function loadCanonicalCatalog(file) {
    const text = fs.readFileSync(file || defaultCatalogFile(), 'utf8');
    const doc = JSON.parse(text);
    const errs = validateCatalog(doc);
    if (errs.length) throw new Error(`notice-type catalog invalid: ${errs.join('; ')}`);
    return doc;
}

// ---------------------------------------------------------------- v2 config

// One validator shared with send-time quiet hours (notify-policies): a zone the
// push accepts is a zone quietHoursDecision honours.
function validZone(name) {
    return typeof name === 'string' && TZ_RE.test(name) && isValidTimeZone(name);
}

function minutes(hhmm) {
    const m = typeof hhmm === 'string' ? HHMM_RE.exec(hhmm) : null;
    return m ? (parseInt(m[1], 10) * 60 + parseInt(m[2], 10)) : null;
}

/** Structural checks == notify-v2.schema.json. Returns [] when valid. */
function validateV2Structure(config) {
    const errs = [];
    if (!isObj(config)) return ['$: config must be an object'];
    if (config.$schema === undefined) errs.push('$: $schema is required');
    else if (config.$schema !== V2_TAG) {
        errs.push(`$.$schema: must be ${V2_TAG} (v1 configs are not accepted by the hub)`);
        return errs;
    }
    if (config.version !== 2) errs.push('$.version: must be 2');
    if (!('routes' in config)) errs.push('$.routes: is required');
    for (const k of Object.keys(config)) if (!TOP_KEYS.has(k)) { errs.push('$: unexpected top-level field(s)'); break; }

    if ('aliases' in config) {
        const al = config.aliases;
        if (!isObj(al)) errs.push('$.aliases: must be an object');
        else {
            for (const [name, a] of Object.entries(al)) {
                const w = `$.aliases['${safeAlias(name)}']`;
                if (!ALIAS_RE.test(name)) errs.push(`$.aliases: alias name malformed`);
                if (!isObj(a)) { errs.push(`${w}: must be an object`); continue; }
                if (Object.keys(a).some((k) => !['provider', 'shape', 'target'].includes(k))) errs.push(`${w}: unexpected field(s)`);
                if (!ALIAS_PROVIDERS.includes(a.provider)) errs.push(`${w}.provider: must be one of ${ALIAS_PROVIDERS.join('|')}`);
                if ('shape' in a && !['flow', 'webhook'].includes(a.shape)) errs.push(`${w}.shape: must be flow|webhook`);
                const t = a.target;
                if (!isObj(t)) errs.push(`${w}.target: must be an object with secretRef`);
                else {
                    if (Object.keys(t).some((k) => k !== 'secretRef')) errs.push(`${w}.target: unexpected field(s)`);
                    if (typeof t.secretRef !== 'string' || !SECRET_REF_RE.test(t.secretRef)) {
                        errs.push(`${w}.target.secretRef: must be vault:<engine>/<account> or env:RELEASE_<NAME> (never a literal)`);
                    }
                }
            }
        }
    }

    if (isObj(config.routes)) {
        for (const [tid, conns] of Object.entries(config.routes)) {
            const w = `$.routes['${safeId(tid)}']`;
            if (!ID_RE.test(tid)) { errs.push('$.routes: notice type id malformed'); continue; }
            if (!Array.isArray(conns)) { errs.push(`${w}: must be a list of connection ids`); continue; }
            if (conns.length > MAX_CONNECTIONS_PER_TYPE) errs.push(`${w}: at most ${MAX_CONNECTIONS_PER_TYPE} connections`);
            if (new Set(conns).size !== conns.length) errs.push(`${w}: connection ids must be unique`);
            if (conns.some((c) => typeof c !== 'string' || !ID_RE.test(c))) errs.push(`${w}: connection id malformed`);
        }
    } else if ('routes' in config) errs.push('$.routes: must be an object');

    if ('severityOverrides' in config) {
        const so = config.severityOverrides;
        if (!isObj(so)) errs.push('$.severityOverrides: must be an object');
        else {
            for (const [tid, sev] of Object.entries(so)) {
                if (!ID_RE.test(tid)) errs.push('$.severityOverrides: notice type id malformed');
                else if (!SEVERITIES.includes(sev)) errs.push(`$.severityOverrides['${tid}']: must be one of ${SEVERITIES.join('|')}`);
            }
        }
    }

    if ('quietHours' in config) {
        const q = config.quietHours;
        if (!isObj(q)) errs.push('$.quietHours: must be an object');
        else {
            for (const k of ['start', 'end', 'timezone']) if (!(k in q)) errs.push(`$.quietHours.${k}: is required`);
            if (Object.keys(q).some((k) => !['start', 'end', 'timezone'].includes(k))) errs.push('$.quietHours: unexpected field(s)');
            for (const k of ['start', 'end']) {
                if (k in q && minutes(q[k]) === null) errs.push(`$.quietHours.${k}: must be HH:MM`);
            }
            if ('timezone' in q && (typeof q.timezone !== 'string' || !TZ_RE.test(q.timezone) || q.timezone.length > 64)) {
                errs.push('$.quietHours.timezone: malformed');
            }
        }
    }

    if ('dedupeWindow' in config) {
        const w = config.dedupeWindow;
        if (typeof w !== 'number' || !Number.isInteger(w) || w < 0 || w > 86400) {
            errs.push('$.dedupeWindow: must be an integer 0..86400');
        }
    }
    return errs;
}
function safeAlias(n) { return typeof n === 'string' && ALIAS_RE.test(n) ? n : '<invalid>'; }

/** Cross-checks the schema cannot express == validate_v2_semantics. Run AFTER structure passes. */
function validateV2Semantics(config, catalog) {
    const errs = [];
    for (const section of ['routes', 'severityOverrides']) {
        const block = config[section];
        if (isObj(block)) {
            for (const tid of Object.keys(block).sort()) {
                if (!Object.prototype.hasOwnProperty.call(catalog, tid)) errs.push(`$.${section}: unknown notice type '${safeId(tid)}'`);
            }
        }
    }
    const qh = config.quietHours;
    if (isObj(qh)) {
        const s = minutes(qh.start), e = minutes(qh.end);
        if (s !== null && e !== null && s === e) errs.push('$.quietHours: start and end must differ');
        if (!validZone(qh.timezone)) errs.push('$.quietHours: timezone is not a known IANA zone');
    }
    return errs;
}

/**
 * Validate a pushed {config, catalog}. Returns {ok:true, config, catalog(merged)}
 * or {ok:false, errors:[...]}. `canonical` is the parsed canonical catalog document.
 */
function validateTeamPush(body, canonical) {
    if (!isObj(body)) return { ok: false, errors: ['body must be an object {config, catalog?}'] };
    const config = body.config;
    const errors = validateV2Structure(config);
    if (errors.length) return { ok: false, errors };
    if (Object.keys(config.routes).length > MAX_ROUTE_TYPES) {
        return { ok: false, errors: [`$.routes: at most ${MAX_ROUTE_TYPES} notice types`] };
    }
    // Bound what a team can make the store hold (every mutation clones + rewrites the whole store).
    const layer = body.catalog;
    if (isObj(layer) && Array.isArray(layer.types) && layer.types.length > MAX_CATALOG_TYPES) {
        return { ok: false, errors: [`catalog.types: at most ${MAX_CATALOG_TYPES} entries`] };
    }
    if (isObj(config.aliases) && Object.keys(config.aliases).length > MAX_ALIASES) {
        return { ok: false, errors: [`$.aliases: at most ${MAX_ALIASES} entries`] };
    }
    let merged;
    try {
        merged = mergeCatalog(canonical, body.catalog === undefined ? null : body.catalog);
    } catch (e) {
        return { ok: false, errors: [String(e.message).slice(0, 500)] };
    }
    const sem = validateV2Semantics(config, merged);
    if (sem.length) return { ok: false, errors: sem };
    return { ok: true, config, catalog: merged };
}

module.exports = {
    SEVERITIES, TEAM_RE, ID_RE, MAX_ROUTE_TYPES, MAX_CATALOG_TYPES, MAX_ALIASES,
    validateCatalog, validateTeamOverride, mergeCatalog, loadCanonicalCatalog, defaultCatalogFile,
    validateV2Structure, validateV2Semantics, validateTeamPush, validZone,
};
