//
//  tap-lock-watcher.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * Stale tap-writer-lock watcher (XACA-1622-003).
 *
 * Background: a SIGKILLed publisher run left refs/locks/tap-writer held ~10 h with nobody
 * alerted. This module polls the READ-ONLY checker (`scripts/kb-tap-lock.sh status --check`)
 * and turns its verdict into fleet notices.
 *
 * STRICTLY READ-ONLY. The only argument vector this module ever hands the checker is
 * ['status', '--check']. It never takes, frees or forces the lock and never writes any ref; the
 * operator runs the checker-supplied command by hand after verifying the holder run is dead.
 * (A static test pins this.)
 *
 * SOURCES (FLEET_TAP_LOCK_SOURCE): the checker script where it exists, otherwise the native
 * GitHub REST reader in ./tap-lock-github.js (Fly.io has neither git nor scripts/). Both yield
 * the same result shape, so everything below the source is shared and untouched.
 *
 * Two layers, both injectable and free of server state:
 *   createTapLockTracker  pure state machine: observe(result) -> emits via injected emit/now.
 *   createTapLockWatcher  poller: runs the checker through an injected runner, classifies the
 *                         outcome (fail CLOSED: anything odd is "unreadable"), feeds the tracker.
 *
 * CHECKER CONTRACT: stdout is key=value lines (split on the FIRST '=', values may contain '=').
 * state=free|young|stale|unreadable; rc 0 free/young, 1 stale, 2 unreadable. Callers key on
 * state=. A missing/unknown state, timeout, spawn error or unexpected rc/state pairing is
 * treated as unreadable.
 *
 * NOTICES (types live in kanban-hooks/notice_types.json + the server mirror):
 *   tap-lock-stale   (high)  stale lock, or checker unreadable twice in a row
 *   tap-lock-cleared (info)  the condition that was alerted has gone away
 *   Every alert carries a sequence in its ref (tap-writer:<sha12>:<n>) because the notify hub
 *   dedupes on type+ref inside a ~300 s window; a re-alert interval (default 60 min) is far
 *   larger than that and the distinct ref keeps a legitimate re-alert from being swallowed.
 */

const path = require('path');
const { execFile } = require('child_process');
const github = require('./tap-lock-github');

const DEFAULT_URL = 'https://github.com/DoubleNode/homebrew-aiteamforge.git';
const DEFAULT_INTERVAL_MS = 5 * 60 * 1000;
const MIN_INTERVAL_MS = 30 * 1000;
const DEFAULT_REALERT_MS = 60 * 60 * 1000;
const MIN_REALERT_MS = 10 * 60 * 1000;      // must stay well above the hub's 300 s dedupe window
const DEFAULT_TIMEOUT_MS = 60 * 1000;
const FIRST_POLL_DELAY_MS = 15 * 1000;
const UNREADABLE_THRESHOLD = 2;             // consecutive unreadable polls before alerting
const NOTICE_TYPES = Object.freeze(['tap-lock-stale', 'tap-lock-cleared']);
const CHECKER_ARGS = Object.freeze(['status', '--check']);
const STATE_RC = Object.freeze({ free: 0, young: 0, stale: 1, unreadable: 2 });

function clean(v, max) {
    // eslint-disable-next-line no-control-regex
    return String(v === undefined || v === null ? '' : v).replace(/[\u0000-\u001f\u007f]/g, ' ').trim().slice(0, max);
}

function pad2(n) { return String(n).padStart(2, '0'); }

/**
 * ONE age format shared with render_contended in tap-publisher.yml (XACA-1622-014):
 * 39900 s -> "11h 05m"; under an hour "2m 05s"; under a minute "42s"; 48 h+ "2d 3h".
 */
function formatAge(seconds) {
    const s = Math.max(0, Math.floor(Number(seconds)));
    if (!Number.isFinite(s)) return 'unknown age';
    if (s < 60) return `${s}s`;
    const m = Math.floor(s / 60);
    if (m < 60) return `${m}m ${pad2(s % 60)}s`;
    const h = Math.floor(m / 60);
    if (h < 48) return `${h}h ${pad2(m % 60)}m`;
    return `${Math.floor(h / 24)}d ${h % 24}h`;
}

/** key=value lines -> object. Splits on the FIRST '=' only. Lines without '=' are ignored. */
function parseKeyValue(stdout) {
    const out = {};
    for (const raw of String(stdout === undefined || stdout === null ? '' : stdout).split(/\r?\n/)) {
        const i = raw.indexOf('=');
        if (i <= 0) continue;
        const k = raw.slice(0, i).trim();
        if (!/^[a-z_][a-z0-9_]*$/.test(k)) continue;
        if (!(k in out)) out[k] = raw.slice(i + 1).trim();
    }
    return out;
}

/**
 * Checker outcome -> {state, ...fields}. Never throws. Anything not an exactly-matching
 * (state, rc) pair is unreadable (fail closed).
 * @param {{rc?:number|null, stdout?:string, timedOut?:boolean, error?:string}} run
 */
function classify(run) {
    const r = run && typeof run === 'object' ? run : {};
    if (r.timedOut) return { state: 'unreadable', reason: 'checker timed out' };
    if (r.error) return { state: 'unreadable', reason: `checker failed to run (${clean(r.error, 120)})` };
    const kv = parseKeyValue(r.stdout);
    const state = kv.state;
    if (!state) return { state: 'unreadable', reason: `checker printed no state= line (rc ${r.rc})` };
    if (!Object.prototype.hasOwnProperty.call(STATE_RC, state)) {
        return { state: 'unreadable', reason: `checker reported unknown state "${clean(state, 40)}" (rc ${r.rc})` };
    }
    if (r.rc !== STATE_RC[state]) {
        return { state: 'unreadable', reason: `checker rc ${r.rc} does not match state=${state}` };
    }
    return Object.assign({}, kv, { state });
}

/**
 * Pure alert state machine.
 * @param {object} o
 * @param {Function} o.emit                (notice) => any
 * @param {Function} [o.now]               () => epoch ms
 * @param {number}   [o.reAlertMs]         default 60 min (floored at MIN_REALERT_MS)
 * @param {object}   [o.logger]
 */
function createTapLockTracker(o = {}) {
    if (typeof o.emit !== 'function') throw new TypeError('createTapLockTracker: emit is required');
    const now = typeof o.now === 'function' ? o.now : Date.now;
    const reAlertMs = Number.isFinite(o.reAlertMs) && o.reAlertMs >= MIN_REALERT_MS ? o.reAlertMs : DEFAULT_REALERT_MS;
    const logger = o.logger || console;
    const intervalMs = Number.isFinite(o.intervalMs) && o.intervalMs > 0 ? o.intervalMs : DEFAULT_INTERVAL_MS;
    let alerted = null;      // null | {kind:'stale', sha, seq, lastAt} | {kind:'unreadable', id, seq, lastAt}
    let streak = 0;          // consecutive unreadable polls

    // An undelivered alert must not read as success: emitFleetNotice resolves {ok:false,
    // reason:'no-route'} when the operator's fleet route set lacks this type, which would
    // silently reproduce the XACA-1622 incident (stale lock, nobody told). Warn loudly.
    function reportUndelivered(notice, res) {
        if (!res || typeof res !== 'object' || res.ok !== false) return;
        const why = String(res.reason || (res.routed === false ? 'not-routed' : 'not-delivered')).slice(0, 64);
        try {
            (logger.warn || console.warn).call(logger,
                `[TAP-LOCK] notice NOT delivered (type=${notice.type} reason=${why}) - add ${notice.type} to the fleet routes (PUT /api/notify/fleet-routes): ${notice.title}`);
        } catch (_) { /* never throw */ }
    }

    function send(notice) {
        try {
            const r = o.emit(notice);
            if (r && typeof r.then === 'function') {
                r.then((res) => reportUndelivered(notice, res), () => {});
            } else {
                reportUndelivered(notice, r);
            }
        } catch (e) {
            try { (logger.warn || console.warn).call(logger, `[TAP-LOCK] emit failed (${String(e && e.name || 'Error')})`); } catch (_) { /* never throw */ }
        }
    }

    function staleNotice(r, sha, seq) {
        const holder = clean(r.holder, 120) || 'unknown holder';
        const ageTxt = formatAge(r.age);
        const host = clean(r.host, 120);
        const cmd = clean(r.break_cmd, 300);
        const lines = [
            `Holder: ${holder}`,
            ...(host ? [`Host: ${host}`] : []),
            `Run: ${clean(r.run_url, 250) || 'unknown'}`,
            `Acquired: ${clean(r.acquired_at, 60) || 'unknown'}`,
            `Age: ${ageTxt}${r.stale_after ? ` (stale threshold: ${formatAge(r.stale_after)})` : ''}`,
            'Verify that run is dead (check the run URL) before breaking.',
            'Nothing breaks this lock automatically.',
        ];
        // The command is the LAST thing in the body: fleet-notices.js flattens newlines to spaces
        // on delivery, so anything after it would be glued onto the copy-selected command.
        if (cmd) lines.push('From the dev-team repo root:', cmd);
        return {
            type: 'tap-lock-stale', severity: 'high',
            title: clean(`Tap publishing blocked: stale tap-writer lock held by ${holder} for ${ageTxt}`, 200),
            body: lines.join('\n'),
            ref: `tap-writer:${sha}:${seq}`,
        };
    }

    function unreadableNotice(r, id, seq) {
        const mins = Math.max(1, Math.round((intervalMs * UNREADABLE_THRESHOLD) / 60000));
        return {
            type: 'tap-lock-stale', severity: 'high',
            title: 'Tap publishing may be blocked: the tap-writer lock cannot be checked',
            body: [
                `The tap-writer lock watcher could not read the lock for about ${mins} minutes, so a stale lock would go unnoticed.`,
                `Detail: ${clean(r.reason, 400) || 'unknown'}`,
                'From the dev-team repo root, inspect with: scripts/kb-tap-lock.sh status',
                'Nothing breaks this lock automatically.',
            ].join('\n'),
            ref: `tap-writer:unreadable:${id}:${seq}`,
        };
    }

    function cleared(was) {
        const what = was.kind === 'stale' ? 'The stale tap-writer lock is gone' : 'The tap-writer lock is readable again';
        send({
            type: 'tap-lock-cleared', severity: 'info',
            title: 'Tap-writer lock cleared: tap publishing can resume',
            body: `${what}. Tap publishing can resume.`,
            ref: `tap-writer:cleared:${now().toString(36)}`,
        });
    }

    /** @param {{state:string}} r classified result. Returns a short label of what happened (tests/logs). */
    function observe(r) {
        try {
            const t = now();
            const state = r && r.state;
            if (state === 'free' || state === 'young') {
                streak = 0;
                if (alerted) { const was = alerted; alerted = null; cleared(was); return 'cleared'; }
                return null;
            }
            if (state === 'stale') {
                streak = 0;
                const sha = clean(r.lock_sha, 40).replace(/[^A-Za-z0-9]/g, '').slice(0, 12) || 'unknown';
                if (alerted && alerted.kind === 'stale' && alerted.sha === sha) {
                    if (t - alerted.lastAt < reAlertMs) return null;
                    alerted.seq += 1; alerted.lastAt = t;
                    send(staleNotice(r, sha, alerted.seq));
                    return 're-alert';
                }
                alerted = { kind: 'stale', sha, seq: 1, lastAt: t };
                send(staleNotice(r, sha, 1));
                return 'stale';
            }
            // anything else is unreadable (fail closed)
            streak += 1;
            if (streak < UNREADABLE_THRESHOLD) return null;
            if (alerted && alerted.kind === 'unreadable') {
                if (t - alerted.lastAt < reAlertMs) return null;
                alerted.seq += 1; alerted.lastAt = t;
                send(unreadableNotice(r || {}, alerted.id, alerted.seq));
                return 're-alert';
            }
            alerted = { kind: 'unreadable', id: t.toString(36), seq: 1, lastAt: t };
            send(unreadableNotice(r || {}, alerted.id, 1));
            return 'unreadable';
        } catch (e) {
            try { (logger.warn || console.warn).call(logger, `[TAP-LOCK] observe failed (${String(e && e.name || 'Error')})`); } catch (_) { /* never throw */ }
            return null;
        }
    }

    return { observe, reAlertMs };
}

function envInt(v, def, min) {
    const n = Number(v);
    return Number.isFinite(n) && n > 0 ? Math.max(min, Math.floor(n)) : def;
}

function envPosInt(v, def) {
    const s = String(v === undefined ? '' : v).trim();
    return /^[1-9][0-9]*$/.test(s) ? Number(s) : def;
}

/**
 * Resolve enablement, source and settings from the environment. Pure (exists is injectable).
 *
 * FLEET_TAP_LOCK_SOURCE = auto (default) | github | checker
 *   auto    = the checker script when it exists, else the native GitHub REST reader
 *             (Fly.io has no git and no scripts/, so production lands on github)
 *   checker = always the script (a missing script is then an unreadable alert)
 *   github  = always the REST reader
 * FLEET_TAP_LOCK_WATCH=0 disables; =1 forces on; unset enables only when the checker script
 * exists (consumer installs mirror fleet-monitor/server but not fly.toml, and stay quiet).
 * FLEET_TAP_LOCK_GITHUB_TOKEN (optional) lifts the anonymous 60 req/h limit.
 * KB_TAP_LOCK_STALE_AFTER / KB_TAP_LOCK_CHECK_SKEW are honoured by both sources.
 */
function resolveTapLockConfig(env = process.env, opts = {}) {
    const exists = typeof opts.exists === 'function' ? opts.exists : (p) => require('fs').existsSync(p);
    const repoRoot = opts.repoRoot || path.join(__dirname, '..', '..', '..');
    const checkerPath = env.FLEET_TAP_LOCK_CHECKER || path.join(repoRoot, 'scripts', 'kb-tap-lock.sh');
    const flag = String(env.FLEET_TAP_LOCK_WATCH === undefined ? '' : env.FLEET_TAP_LOCK_WATCH).trim().toLowerCase();
    const off = ['0', 'false', 'off', 'no'].includes(flag);
    const forced = ['1', 'true', 'on', 'yes'].includes(flag);
    const present = !!exists(checkerPath);
    const sourceSetting = String(env.FLEET_TAP_LOCK_SOURCE === undefined ? '' : env.FLEET_TAP_LOCK_SOURCE).trim().toLowerCase();
    const source = sourceSetting === 'checker' ? 'checker'
        : sourceSetting === 'github' ? 'github'
            : (present ? 'checker' : 'github');
    let enabled; let reason;
    if (off) { enabled = false; reason = 'disabled by FLEET_TAP_LOCK_WATCH=0'; }
    else if (forced) {
        enabled = true;
        reason = source === 'checker' && !present
            ? `forced on but checker missing at ${checkerPath} (will alert as unreadable)`
            : 'forced on by FLEET_TAP_LOCK_WATCH';
    }
    else if (present) { enabled = true; reason = `checker found at ${checkerPath}`; }
    else { enabled = false; reason = `checker not found at ${checkerPath} (not a tap-writer host; set FLEET_TAP_LOCK_WATCH=1 to poll via the GitHub API)`; }
    return {
        enabled, forced, reason, checkerPath, source, sourceSetting: sourceSetting || 'auto',
        url: env.FLEET_TAP_LOCK_URL || DEFAULT_URL,
        githubToken: env.FLEET_TAP_LOCK_GITHUB_TOKEN ? String(env.FLEET_TAP_LOCK_GITHUB_TOKEN).trim() : '',
        staleAfterSec: envPosInt(env.KB_TAP_LOCK_STALE_AFTER, github.DEFAULT_STALE_AFTER_SEC),
        skewSec: envPosInt(env.KB_TAP_LOCK_CHECK_SKEW, github.DEFAULT_SKEW_SEC),
        // 5 min default: the REST reader costs at most 2 req/poll uncached = 24 req/h, inside the
        // 60 req/h anonymous GitHub limit (a held lock is 1 req/poll thanks to the sha cache).
        intervalMs: envInt(env.FLEET_TAP_LOCK_INTERVAL_MS, DEFAULT_INTERVAL_MS, MIN_INTERVAL_MS),
        reAlertMs: envInt(env.FLEET_TAP_LOCK_REALERT_MS, DEFAULT_REALERT_MS, MIN_REALERT_MS),
        timeoutMs: DEFAULT_TIMEOUT_MS,
        githubTimeoutMs: github.DEFAULT_GITHUB_TIMEOUT_MS,
    };
}

/** Production runner: bash <checker> status --check, no shell, bounded. Resolves, never rejects. */
function defaultRunner({ file, args, env, timeoutMs }) {
    return new Promise((resolve) => {
        try {
            execFile('bash', [file, ...args], { env, timeout: timeoutMs, maxBuffer: 256 * 1024, windowsHide: true }, (err, stdout) => {
                if (!err) return resolve({ rc: 0, stdout: String(stdout || '') });
                if (err.killed || err.code === 'ETIMEDOUT') return resolve({ timedOut: true, stdout: String(stdout || '') });
                if (typeof err.code === 'number') return resolve({ rc: err.code, stdout: String(stdout || '') });
                return resolve({ error: String(err.code || err.name || 'spawn error'), stdout: String(stdout || '') });
            });
        } catch (e) {
            resolve({ error: String(e && e.name || 'spawn error') });
        }
    });
}

/**
 * @param {object} o
 * @param {Function} o.emit
 * @param {object}   [o.config]   resolveTapLockConfig() result (default: from process.env)
 * @param {Function} [o.runner]   ({file,args,env,timeoutMs}) => Promise<{rc,stdout,timedOut,error}>
 * @param {Function} [o.fetchImpl] fetch for the GitHub source (default globalThis.fetch)
 * @param {Function} [o.githubReader] (opts) => Promise<result>; default readTapLockViaGitHub
 * @param {Function} [o.exists]   (path) => bool, checked each poll
 * @param {Function} [o.now]
 * @param {object}   [o.logger]
 * @param {object}   [o.baseEnv]  environment inherited by the checker (default process.env)
 */
function createTapLockWatcher(o = {}) {
    const config = o.config || resolveTapLockConfig();
    const logger = o.logger || console;
    const runner = typeof o.runner === 'function' ? o.runner : defaultRunner;
    const exists = typeof o.exists === 'function' ? o.exists : (p) => require('fs').existsSync(p);
    const githubReader = typeof o.githubReader === 'function' ? o.githubReader : github.readTapLockViaGitHub;
    const tracker = createTapLockTracker({ emit: o.emit, now: o.now, reAlertMs: config.reAlertMs, intervalMs: config.intervalMs, logger });
    let inFlight = false;
    let timer = null;
    let stopped = false;
    let routesChecked = false;
    const routeCoverage = typeof o.routeCoverage === 'function' ? o.routeCoverage
        : (types) => require('./fleet-notices').fleetRouteCoverage(types);

    function log(msg) { try { (logger.log || console.log).call(logger, `[TAP-LOCK] ${msg}`); } catch (_) { /* never throw */ } }

    /**
     * XACA-1622-015: warn LOUDLY, once, when the notice types this watcher emits are not in the
     * fleet route set (an unrouted alert is silently dropped - the XACA-1622 incident again).
     * If the hub is not wired yet (coverage null) the check is deferred to the next poll.
     * Never throws.
     */
    function checkRoutes() {
        if (routesChecked) return;
        try {
            const cov = routeCoverage(NOTICE_TYPES.slice());
            if (!cov || typeof cov !== 'object') return;      // not configured yet: retry next poll
            routesChecked = true;
            const missing = Array.isArray(cov.missing) ? cov.missing : [];
            if (missing.length > 0) {
                (logger.warn || console.warn).call(logger,
                    `[TAP-LOCK] WARNING: ${missing.join(', ')} not routed in the fleet routes${cov.configured ? '' : ' (no fleet routes are set at all)'} - stale tap-writer lock alerts will be DROPPED. Add them via PUT /api/notify/fleet-routes`);
            }
        } catch (_) { /* never throw */ }
    }

    async function pollOnce() {
        if (!config.enabled) return 'disabled';
        checkRoutes();
        if (inFlight) return 'busy';
        inFlight = true;
        try {
            let result;
            if (config.source === 'github') {
                result = await githubReader({
                    fetchImpl: o.fetchImpl, token: config.githubToken, now: o.now,
                    staleAfterSec: config.staleAfterSec, skewSec: config.skewSec, timeoutMs: config.githubTimeoutMs,
                });
            } else if (!exists(config.checkerPath)) {
                result = { state: 'unreadable', reason: `checker script missing at ${clean(config.checkerPath, 200)}` };
            } else {
                const env = Object.assign({}, o.baseEnv || process.env, { KB_TAP_LOCK_URL: config.url, GIT_TERMINAL_PROMPT: '0' });
                let run;
                try {
                    run = await runner({ file: config.checkerPath, args: CHECKER_ARGS.slice(), env, timeoutMs: config.timeoutMs });
                } catch (e) {
                    run = { error: String(e && e.name || 'runner error') };
                }
                result = classify(run);
            }
            return tracker.observe(result) || result.state;
        } catch (e) {
            const name = String(e && e.name || 'Error');
            try { (logger.warn || console.warn).call(logger, `[TAP-LOCK] poll failed (${name})`); } catch (_) { /* never throw */ }
            // XACA-1622-016: a throwing source is an unreadable lock; count it toward the streak.
            try { tracker.observe({ state: 'unreadable', reason: `watcher error: ${clean(name, 60)}` }); } catch (_) { /* never throw */ }
            return 'error';
        } finally {
            inFlight = false;
        }
    }

    function start() {
        log(`${config.enabled ? 'enabled' : 'disabled'}: ${config.reason}; source=${config.source || 'checker'}${config.enabled ? `; polling every ${Math.round(config.intervalMs / 1000)}s` : ''}`);
        if (!config.enabled || timer) return;
        checkRoutes();
        stopped = false;
        const schedule = (ms) => {
            if (stopped) return;
            timer = setTimeout(async () => {
                await pollOnce();
                schedule(config.intervalMs);
            }, ms);
            if (timer && typeof timer.unref === 'function') timer.unref();
        };
        schedule(Math.min(FIRST_POLL_DELAY_MS, config.intervalMs));
    }

    function stop() { stopped = true; if (timer) { clearTimeout(timer); timer = null; } }

    return { start, stop, pollOnce, config, tracker };
}

module.exports = {
    createTapLockTracker, createTapLockWatcher, resolveTapLockConfig, classify, parseKeyValue, formatAge,
    readTapLockViaGitHub: github.readTapLockViaGitHub,
    CHECKER_ARGS, DEFAULT_URL, DEFAULT_INTERVAL_MS, DEFAULT_REALERT_MS, UNREADABLE_THRESHOLD,
};
