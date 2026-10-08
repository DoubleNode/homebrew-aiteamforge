//
//  accessories.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * Fleet Monitor accessory registry (XACA-1392, EPIC-0067 item 2/5).
 *
 * An ACCESSORY is a physical thing that feeds or affects several machines and is
 * not itself a machine. Today that is a UPS. The registry persists accessories to
 * data/accessories.json and derives their state; it has NO Express dependency so
 * the same code is exercised by the unit tests and shipped in server.js.
 *
 *   001  model + persistence (this file's store half)
 *   002  auto-discovery: upsertFromReport()
 *   004  derived state:  derive()
 *
 * DESIGN RULES (EPIC-0067 D1/D2/D6, XACA-1391 contract):
 *  - The SERVER derives state; clients only render it (D1).
 *  - Identity is computed server-side from (data-link machine id, UPS id). The
 *    reporter never names an accessory, and reporter-supplied strings are display
 *    text only (D6). The id is a hash so it is URL-safe whatever the machine id is.
 *  - Attachment is operator-declared. Only the data-link host is auto-attached,
 *    and only when the accessory is first created: a host the operator detached
 *    is never silently re-attached by the next report.
 *  - "Could not read" is never "on AC". `power` absent, a stale host, or a
 *    non-`ups`/`ac` source all derive to `unknown`.
 *  - A missing or corrupt file loads as an EMPTY registry. It never crashes boot,
 *    and a corrupt file is moved aside (".corrupt-<ts>") instead of overwritten.
 *  - Every write is temp-file + rename in the same directory (atomic on POSIX).
 */

const fs     = require('fs');
const path   = require('path');
const crypto = require('crypto');

const SCHEMA_VERSION = 1;

const DEFAULT_FILE = path.join(__dirname, '..', 'data', 'accessories.json');

// Bounds. An authenticated reporter can mint accessories by POSTing arbitrary UPS
// ids, so growth is capped; a cap hit is logged and the NEW accessory is dropped
// (existing ones keep updating).
const MAX_ACCESSORIES = 256;
const MAX_ATTACHED = 64;
const MAX_HISTORY = 50;          // state-transition entries kept per accessory
const NICKNAME_MAX = 64;
const NAME_MAX = 64;            // == server.js POWER_UPS_NAME_MAX; longer names are refused, never truncated

const ACCESSORY_ID_RE = /^acc_[0-9a-f]{16}$/;
// Same shape ci-pool-store.js uses for a machine id; also what a UUID satisfies.
const MACHINE_ID_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const CONTROL_RE = /[\u0000-\u001f\u007f]/;

const STATES = ['ac', 'on_battery', 'unknown'];

const isPlainObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const clone = (o) => JSON.parse(JSON.stringify(o));

/**
 * Deterministic, URL-safe accessory id for (data-link machine, UPS NAME).
 *
 * Identity is the UPS *name* (e.g. "CP1500PFCLCDa"), deliberately NOT `ups.id`.
 * The pmset HID id is not stable across reconnects: the same CP1500PFCLCDa on M1Mini
 * reported 19333121 on 2026-10-02 and 53280768 on 2026-10-08 (see the XACA-1392
 * ticket note from XACA-1391). Keying on it would register the same UPS twice after
 * every USB reconnect and strand the old record (and its attachments) as stale.
 * `ups.id` is kept as a volatile attribute (`upsId`, refreshed every report) only.
 *
 * ACCEPTED LIMIT: two identical-model UPSes on ONE data-link machine share a name
 * and therefore MERGE into one accessory. A hardware serial (ioreg
 * IOHIDDevice "SerialNumber") is the likely future key once its stability across a
 * reconnect is verified; changing the key means changing only this function.
 */
function accessoryId(dataLinkMachineId, upsName) {
    const h = crypto.createHash('sha256')
        .update(`${String(dataLinkMachineId)}\u0000${String(upsName)}`, 'utf8')
        .digest('hex');
    return `acc_${h.slice(0, 16)}`;
}

/** Validate a loaded/persisted accessory record. Returns a cleaned copy or null. */
function cleanRecord(id, r) {
    if (!ACCESSORY_ID_RE.test(id) || !isPlainObject(r)) return null;
    if (r.type !== 'ups') return null;
    if (typeof r.dataLinkMachineId !== 'string' || !r.dataLinkMachineId || r.dataLinkMachineId.length > 128) return null;
    if (typeof r.upsId !== 'string' || !r.upsId) return null;
    if (typeof r.name !== 'string' || !r.name || r.name.length > NAME_MAX) return null; // never truncate: the id hashes the FULL name
    if (accessoryId(r.dataLinkMachineId, r.name) !== id) return null; // id must match its identity (machine + name)

    const attached = Array.isArray(r.attachedMachineIds)
        ? Array.from(new Set(r.attachedMachineIds.filter((m) => typeof m === 'string' && MACHINE_ID_RE.test(m)))).slice(0, MAX_ATTACHED)
        : [];

    let lastReading = null;
    if (isPlainObject(r.lastReading)) {
        const l = r.lastReading;
        lastReading = {
            source: ['ac', 'ups', 'battery'].includes(l.source) ? l.source : null,
            percent: Number.isInteger(l.percent) ? l.percent : null,
            charging: typeof l.charging === 'boolean' ? l.charging : null,
            minutes_remaining: Number.isInteger(l.minutes_remaining) ? l.minutes_remaining : null,
            present: typeof l.present === 'boolean' ? l.present : null,
            observedAt: typeof l.observedAt === 'string' ? l.observedAt : null,
        };
    }

    const history = Array.isArray(r.history)
        ? r.history
            .filter((h) => isPlainObject(h) && typeof h.at === 'string' && STATES.includes(h.to)
                && (h.from === null || STATES.includes(h.from)))
            .slice(0, MAX_HISTORY)
            .map((h) => ({ at: h.at, from: h.from, to: h.to }))
        : [];

    return {
        id,
        type: 'ups',
        name: r.name,
        vendor: typeof r.vendor === 'string' ? r.vendor.slice(0, 64) : null,
        nickname: typeof r.nickname === 'string' && r.nickname ? r.nickname.slice(0, NICKNAME_MAX) : null,
        dataLinkMachineId: r.dataLinkMachineId,
        upsId: r.upsId,
        attachedMachineIds: attached,
        lastReading,
        state: STATES.includes(r.state) ? r.state : 'unknown',
        stateSince: typeof r.stateSince === 'string' ? r.stateSince : null,
        history,
        createdAt: typeof r.createdAt === 'string' ? r.createdAt : null,
        updatedAt: typeof r.updatedAt === 'string' ? r.updatedAt : null,
    };
}

/**
 * Create a registry bound to one file. `file` is injectable so tests never touch
 * the real data/accessories.json; server.js passes FLEET_ACCESSORIES_FILE when set.
 */
function createRegistry(opts) {
    const o = opts || {};
    const file = o.file || DEFAULT_FILE;
    const nowFn = typeof o.now === 'function' ? o.now : () => new Date();
    const log = typeof o.log === 'function' ? o.log : () => {};

    const records = new Map(); // id -> record
    let dirty = false;
    let tmpSeq = 0;

    // ------------------------------------------------------------ persistence

    /** Serialisable snapshot. */
    function toJSON() {
        return { schemaVersion: SCHEMA_VERSION, accessories: Object.fromEntries(records) };
    }

    /**
     * Atomic write: temp file in the SAME directory, then rename. A crash leaves the
     * old file or the new file, never a partial one (an orphaned ".tmp-*" is
     * possible and is gitignored / tap-excluded). Returns true on success. Never
     * throws: a failed write leaves the in-memory registry intact and `dirty` set
     * so the next flush retries.
     */
    function save() {
        const dir = path.dirname(file);
        const tmp = `${file}.tmp-${process.pid}-${++tmpSeq}`;
        try {
            fs.mkdirSync(dir, { recursive: true });
            fs.writeFileSync(tmp, JSON.stringify(toJSON(), null, 2));
            fs.renameSync(tmp, file);
            dirty = false;
            return true;
        } catch (err) {
            try { fs.unlinkSync(tmp); } catch (_) { /* nothing to clean */ }
            log(`accessories: save failed: ${err.message}`);
            return false;
        }
    }

    /** Persist now if anything changed since the last successful write. */
    function flushIfDirty() {
        return dirty ? save() : true;
    }

    /**
     * Load from disk. Missing file -> empty registry. Corrupt file (unparseable or
     * wrong shape) -> empty registry AND the bad file is moved aside so the next
     * save() cannot destroy it. Individually malformed records are skipped, the
     * rest are kept. Never throws.
     */
    function load() {
        records.clear();
        let raw;
        try {
            raw = fs.readFileSync(file, 'utf8');
        } catch (err) {
            if (err.code !== 'ENOENT') log(`accessories: cannot read ${file}: ${err.message}`);
            return { loaded: 0, status: err.code === 'ENOENT' ? 'missing' : 'unreadable' };
        }
        let parsed;
        try {
            parsed = JSON.parse(raw);
        } catch (_) {
            parsed = null;
        }
        if (!isPlainObject(parsed) || !isPlainObject(parsed.accessories)) {
            const aside = `${file}.corrupt-${Date.now()}`;
            try { fs.renameSync(file, aside); log(`accessories: corrupt registry moved to ${aside}; starting empty`); }
            catch (err) { log(`accessories: corrupt registry could not be moved aside: ${err.message}`); }
            return { loaded: 0, status: 'corrupt' };
        }
        let skipped = 0;
        for (const [id, rec] of Object.entries(parsed.accessories)) {
            const clean = cleanRecord(id, rec);
            if (clean) records.set(id, clean); else skipped++;
        }
        if (skipped) log(`accessories: skipped ${skipped} malformed record(s) while loading`);
        dirty = false;
        return { loaded: records.size, skipped, status: 'ok' };
    }

    // ------------------------------------------------------------------ reads

    function get(id) {
        const r = records.get(id);
        return r ? clone(r) : null;
    }

    function list() {
        return Array.from(records.values()).map(clone);
    }

    function size() { return records.size; }

    // ------------------------------------------------- 002 auto-discovery

    /**
     * Upsert a UPS accessory from a reporter's SANITIZED system.power (the output of
     * server.js sanitizePowerBlock, so field shapes are already validated).
     *
     *  - `power` absent / `ups` null  -> NO-OP. An unreadable cycle must neither
     *    create, detach, delete nor change the state of anything (contract 2, 4).
     *  - `source:"battery"` with no ups is a laptop, not an accessory (contract 5).
     *  - key = (data-link machineId, ups.name); ups.id is volatile (changes on USB reconnect),
     *    refreshed on every report, and never part of identity (see accessoryId).
     *  - The data-link host is auto-attached ONLY on creation.
     *  - lastReading is refreshed in memory every report; it is persisted lazily
     *    (dirty flag, flushIfDirty on the server's save interval) so a 60 s
     *    heartbeat does not become a 60 s disk write. Creation, an upsId change,
     *    attach/detach/nickname and derive() state transitions flush immediately;
     *    reads (derive with no transition) never write.
     *
     * Returns the accessory id, or null when nothing was upserted.
     */
    function upsertFromReport(machineId, power) {
        if (typeof machineId !== 'string' || !MACHINE_ID_RE.test(machineId)) return null;
        if (!isPlainObject(power) || !isPlainObject(power.ups)) return null;
        const u = power.ups;
        if (u.id === undefined || u.id === null || typeof u.name !== 'string' || !u.name || u.name.length > NAME_MAX) return null;
        const upsId = String(u.id); // volatile attribute, NOT identity (see accessoryId)
        const id = accessoryId(machineId, u.name);
        const observedAt = nowFn().toISOString();
        let rec = records.get(id);
        let flushNow = false;

        if (!rec) {
            if (records.size >= MAX_ACCESSORIES) {
                log(`accessories: registry full (${MAX_ACCESSORIES}); ignoring new UPS ${upsId} from ${machineId}`);
                return null;
            }
            rec = {
                id, type: 'ups', name: u.name, vendor: null, nickname: null,
                dataLinkMachineId: machineId, upsId,
                attachedMachineIds: [machineId],
                lastReading: null, state: 'unknown', stateSince: observedAt, history: [],
                createdAt: observedAt, updatedAt: observedAt,
            };
            records.set(id, rec);
            flushNow = true;
        } else if (rec.upsId !== upsId) {
            // Same UPS (same machine + name), new pmset HID id after a reconnect: update in
            // place. Attachments, nickname, state and history are preserved.
            rec.upsId = upsId;
            flushNow = true;
        }

        rec.lastReading = {
            source: ['ac', 'ups', 'battery'].includes(power.source) ? power.source : null,
            percent: u.percent, charging: u.charging,
            minutes_remaining: u.minutes_remaining, present: u.present,
            observedAt,
        };
        rec.updatedAt = observedAt;
        dirty = true;
        if (flushNow) save();
        return id;
    }

    // ------------------------------------------------- 003 attachment

    /** Idempotent. Returns {ok, changed} | {ok:false, code:'not_found'|'full'|'bad_id'}. */
    function attach(id, machineId) {
        if (!ACCESSORY_ID_RE.test(id) || typeof machineId !== 'string' || !MACHINE_ID_RE.test(machineId)) return { ok: false, code: 'bad_id' };
        const rec = records.get(id);
        if (!rec) return { ok: false, code: 'not_found' };
        if (rec.attachedMachineIds.includes(machineId)) return { ok: true, changed: false };
        if (rec.attachedMachineIds.length >= MAX_ATTACHED) return { ok: false, code: 'full' };
        rec.attachedMachineIds.push(machineId);
        rec.updatedAt = nowFn().toISOString();
        dirty = true; save();
        return { ok: true, changed: true };
    }

    /** Idempotent: detaching a machine that is not attached succeeds with changed:false. */
    function detach(id, machineId) {
        if (!ACCESSORY_ID_RE.test(id) || typeof machineId !== 'string' || !MACHINE_ID_RE.test(machineId)) return { ok: false, code: 'bad_id' };
        const rec = records.get(id);
        if (!rec) return { ok: false, code: 'not_found' };
        const i = rec.attachedMachineIds.indexOf(machineId);
        if (i < 0) return { ok: true, changed: false };
        rec.attachedMachineIds.splice(i, 1);
        rec.updatedAt = nowFn().toISOString();
        dirty = true; save();
        return { ok: true, changed: true };
    }

    /** nickname: string (trimmed, <=64, no control chars) or null/'' to clear. */
    function setNickname(id, nickname) {
        if (!ACCESSORY_ID_RE.test(id)) return { ok: false, code: 'bad_id' };
        const rec = records.get(id);
        if (!rec) return { ok: false, code: 'not_found' };
        let n = null;
        if (nickname !== null && nickname !== undefined && nickname !== '') {
            if (typeof nickname !== 'string') return { ok: false, code: 'bad_nickname' };
            n = nickname.trim();
            if (n.length > NICKNAME_MAX || CONTROL_RE.test(n)) return { ok: false, code: 'bad_nickname' };
            if (!n) n = null;
        }
        const changed = rec.nickname !== n;
        rec.nickname = n;
        if (changed) { rec.updatedAt = nowFn().toISOString(); dirty = true; save(); }
        return { ok: true, changed };
    }

    // ------------------------------------------------- 004 derived state

    /**
     * Accessory state from its data-link host's LATEST report (XACA-1392-012).
     *
     * `machine.status` is the value updateMachineStatuses() already set from
     * WARNING_THRESHOLD_MS / OFFLINE_THRESHOLD_MS -- no new threshold is invented
     * here. Anything but 'online' (missing, warning, offline) is stale => unknown.
     *
     * The host's `system.power` is replaced wholesale by every POST /api/status, so
     * the stored record IS the latest report; presence is read from it directly and
     * nothing extra is tracked or persisted. The report only counts when it still
     * contains THIS UPS (`power.ups.name === rec.name`, the accessory's identity).
     * Why: a Mac on a UPS outlet reads AC even while the UPS is on battery; only the
     * USB data link makes pmset say "UPS Power". When the link drops the reporter
     * sends `source:"ac", ups:null`, which says nothing about the UPS and must never
     * turn attached machines GREEN mid-outage (EPIC D6/D7a: "could not read" is never
     * AC). So a latest report with ups:null, power absent, or a DIFFERENT ups name
     * => unknown. (The upsert side stays a no-op for those: nothing is detached or
     * deleted; only the derived state degrades.)
     *
     * Restart: machines.json persists the host record, so a restart with no new report
     * re-derives from the persisted last report, and the host is `offline` (=> unknown)
     * once last_seen ages past the existing thresholds. Both outcomes are sane.
     *
     * With a matching UPS present: source 'ups' => on_battery, 'ac' => ac; any other
     * source (e.g. 'battery') => unknown. Never defaults to ac.
     */
    function stateFor(rec, machinesById) {
        const host = machinesById.get(rec.dataLinkMachineId);
        if (!host || host.status !== 'online') return 'unknown';
        const power = host.system && host.system.power;
        if (!power) return 'unknown';
        if (!power.ups || power.ups.name !== rec.name) return 'unknown';
        if (power.source === 'ups') return 'on_battery';
        if (power.source === 'ac') return 'ac';
        return 'unknown';
    }

    /**
     * Derive accessory + per-machine power state. Call AFTER updateMachineStatuses().
     *
     * `machinesById`: Map machineId -> record ({status, system, ...}).
     * `hooks.onTransition(rec, from, to, at)`: optional; fired once per change
     * (server.js uses it for the activity log + attached-machine history).
     *
     * Returns {
     *   accessories: [view...],
     *   machines: Map machineId -> {power_state, display_status, power_reason}
     * }
     *
     * display_status precedence (EPIC D2):  offline > on_battery > warning > online.
     * `status` keeps its heartbeat meaning; display_status is the additive field.
     * power_reason is the explicit reason a card is YELLOW for power (not heartbeat).
     */
    function derive(machinesById, hooks) {
        const onTransition = hooks && typeof hooks.onTransition === 'function' ? hooks.onTransition : null;
        const at = nowFn().toISOString();
        const perMachine = new Map(); // machineId -> accessory views attached

        const views = [];
        let transitioned = false;
        for (const rec of records.values()) {
            const next = stateFor(rec, machinesById);
            if (next !== rec.state) {
                const from = rec.state;
                rec.history.unshift({ at, from, to: next });
                if (rec.history.length > MAX_HISTORY) rec.history.length = MAX_HISTORY;
                rec.state = next;
                rec.stateSince = at;
                dirty = true;
                transitioned = true;
                if (onTransition) {
                    try { onTransition(clone(rec), from, next, at); } catch (e) { log(`accessories: onTransition failed: ${e.message}`); }
                }
            }
            const v = view(rec);
            views.push(v);
            for (const mid of rec.attachedMachineIds) {
                if (!perMachine.has(mid)) perMachine.set(mid, []);
                perMachine.get(mid).push(v);
            }
        }
        // XACA-1392-013: a READ must not write. Only a state transition flushes here (it
        // also carries any pending lastReading along); an unchanged state leaves the
        // dirty lastReading to the 30 s interval / shutdown flush, as documented.
        if (transitioned) save();

        const machines = new Map();
        for (const [mid, m] of machinesById.entries()) {
            const key = (m && m.machine_id) || mid;
            const attached = perMachine.get(key) || [];
            let power_state = null;
            let reasonAcc = null;
            if (attached.length) {
                reasonAcc = attached.find((a) => a.state === 'on_battery') || null;
                if (reasonAcc) power_state = 'on_battery';
                else if (attached.some((a) => a.state === 'unknown')) power_state = 'unknown';
                else power_state = 'ac';
            }
            const heartbeat = m && m.status;
            let display_status = heartbeat;
            if (heartbeat !== 'offline' && power_state === 'on_battery') display_status = 'on_battery';
            machines.set(key, {
                power_state,
                display_status,
                power_reason: display_status === 'on_battery' && reasonAcc ? {
                    accessory_id: reasonAcc.id,
                    accessory_name: reasonAcc.nickname || reasonAcc.name,
                    percent: reasonAcc.last_reading ? reasonAcc.last_reading.percent : null,
                    minutes_remaining: reasonAcc.last_reading ? reasonAcc.last_reading.minutes_remaining : null,
                } : null,
            });
        }
        return { accessories: views, machines };
    }

    /** Public projection of a record (explicit allowlist; no internals). */
    function view(rec) {
        return {
            id: rec.id,
            type: rec.type,
            name: rec.name,
            nickname: rec.nickname,
            display_name: rec.nickname || rec.name,
            data_link_machine_id: rec.dataLinkMachineId,
            attached_machine_ids: rec.attachedMachineIds.slice(),
            state: rec.state,
            state_since: rec.stateSince,
            last_reading: rec.lastReading ? Object.assign({}, rec.lastReading) : null,
            history: rec.history.map((h) => Object.assign({}, h)),
        };
    }

    return {
        file,
        load, save, flushIfDirty, toJSON,
        get, list, size,
        upsertFromReport, attach, detach, setNickname,
        derive, view,
        _records: records,
        _markDirty() { dirty = true; },
        _now: nowFn,
        _log: log,
    };
}

module.exports = {
    createRegistry,
    accessoryId,
    cleanRecord,
    SCHEMA_VERSION,
    DEFAULT_FILE,
    MAX_ACCESSORIES,
    MAX_ATTACHED,
    MAX_HISTORY,
    NICKNAME_MAX,
    ACCESSORY_ID_RE,
    MACHINE_ID_RE,
    CONTROL_RE,
    STATES,
};
