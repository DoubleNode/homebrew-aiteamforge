//
//  imessage-relay.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * imessage-relay.js — Mac relay agent for the Fleet Monitor iMessage sender
 * pool (XACA-1402-010, design §2.2).
 *
 * Runs on each consumer Mac under a LaunchAgent (GUI session, KeepAlive). It
 * long-polls Fleet Monitor for iMessage jobs, sends each one through
 * Messages.app via osascript, and acks the result.
 *
 *   run     long-running claim/send/ack loop (SIGTERM-graceful)
 *   probe   exit 0 if this Mac can send, 3 if not; prints a one-line reason
 *   --once  a single claim cycle (tests / diagnosis); implies `run`
 *
 * INVARIANTS
 *  - A machine that fails the capability probe NEVER claims a job.
 *  - The message text and recipient travel ONLY as separate argv entries to
 *    osascript (no shell, nothing interpolated into the AppleScript source).
 *  - The text, recipient, bearer token and osascript argv NEVER reach a log
 *    line, an ack body or an error string. A failed execFile error carries its
 *    argv (knowledge S007), so errors are reduced to a coarse class here and
 *    the original error object is never printed.
 *  - Semantics are at-least-once: we send, then ack. A send we cannot ack is
 *    resent by the server after the lease expires; a duplicate alert is
 *    acceptable, a lost one is not.
 *
 * Wire contract (pinned with the server side):
 *   POST {base}/api/notify/imessage/claim {machineId, waitSeconds:25}
 *        200 {jobId, recipient, text, attempt, leaseExpiresAt} | 204 no job
 *        400/401/5xx/network -> exponential backoff, never a tight loop
 *   POST {base}/api/notify/imessage/ack {machineId, jobId, ok, errorType?}
 *        200 ok; 409 lease_not_held / 404 unknown_job -> log job id, drop
 *   A lease the relay itself judges over (server lease length minus local
 *   elapsed time, never server-vs-local clock) is acked ok:false
 *   errorType 'lease_expired_local' so the server requeues immediately.
 *
 * Config/auth reuse msg-client.js's resolution (shared vault-keygen.js
 * helpers): base URL, Bearer token only over https/loopback, redirects
 * refused. Machine id comes from the reporter's source of truth.
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFile: realExecFile } = require('child_process');

const kg = require('./vault-keygen.js');

// ── Constants ────────────────────────────────────────────────────────────────

const OSASCRIPT = '/usr/bin/osascript';
const CLAIM_PATH = '/api/notify/imessage/claim';
const ACK_PATH = '/api/notify/imessage/ack';

const WAIT_SECONDS = 25;
const CLAIM_TIMEOUT_MS = (WAIT_SECONDS + 10) * 1000; // long-poll + margin
const ACK_TIMEOUT_MS = 15000;
const SEND_TIMEOUT_MS = 30000;
const PROBE_TIMEOUT_MS = 15000;

const PROBE_TTL_OK_MS = 5 * 60 * 1000;   // capable: re-check every ~5 min
const PROBE_TTL_BAD_MS = 60 * 1000;      // not capable: re-check sooner so a fixed Mac rejoins fast
const INCAPABLE_SLEEP_MS = 30 * 1000;

const BACKOFF_MIN_MS = 5000;
const BACKOFF_MAX_MS = 60000;

const ACK_RETRIES = 2;                   // retries after the first attempt
const ACK_RETRY_BASE_MS = 1000;

const ERROR_TYPE_RE = /^[A-Za-z0-9_.-]{1,64}$/;

/**
 * Send script. CONSTANT: never built from job data. The text and recipient
 * arrive as argv items. Property names verified against
 * `sdef /System/Applications/Messages.app` (account: "service type",
 * "enabled"; participant is an element of account).
 */
const SEND_SCRIPT = [
    'on run argv',
    '\tset theText to item 1 of argv',
    '\tset theHandle to item 2 of argv',
    '\ttell application "Messages"',
    '\t\tset theAccount to 1st account whose service type = iMessage and enabled is true',
    '\t\tsend theText to participant theHandle of theAccount',
    '\tend tell',
    'end run',
].join('\n');

/** Probe script: counts enabled iMessage accounts. Takes no job data. */
const PROBE_SCRIPT = [
    'tell application "Messages"',
    '\tset matches to (every account whose service type = iMessage and enabled is true)',
    '\treturn (count of matches) as text',
    'end tell',
].join('\n');

// ── Identity / config ────────────────────────────────────────────────────────

/**
 * Machine id, same sources and priority as fleet-reporter.sh get_machine_id():
 *   1. $AITEAMFORGE_DIR/config/machine-identity.json .machineId
 *      (AITEAMFORGE_DIR defaults to $HOME/aiteamforge)
 *   2. ~/.fleet-machine-id
 * Unlike the reporter we never GENERATE one: a made-up id would diverge from
 * the id the reporter registers and would corrupt the pool view.
 * @returns {string} id, or '' when neither source has one
 */
function resolveMachineId(env, fsImpl) {
    env = env || process.env;
    fsImpl = fsImpl || fs;
    const home = env.HOME || os.homedir();
    const dir = env.AITEAMFORGE_DIR || path.join(home, 'aiteamforge');
    try {
        const j = JSON.parse(fsImpl.readFileSync(path.join(dir, 'config', 'machine-identity.json'), 'utf8'));
        if (j && typeof j.machineId === 'string' && j.machineId.trim()) return j.machineId.trim();
    } catch (_) { /* fall through */ }
    try {
        const v = String(fsImpl.readFileSync(path.join(home, '.fleet-machine-id'), 'utf8')).trim();
        if (v) return v;
    } catch (_) { /* fall through */ }
    return '';
}

/**
 * Fleet base URL. msg-client's resolution (FLEET_MONITOR_URL, else
 * fleet-config centralServer.apiEndpoint with /api... stripped), then the
 * reporter's FLEET_MONITOR_API env (an `.../api/status` endpoint) with the
 * same stripping. Always validated; never localhost-guessed.
 * @throws {Error} .code FLEET_URL_UNRESOLVED
 */
function resolveBase(env) {
    env = env || process.env;
    let base = kg.resolveFleetUrl();
    if (!base && env.FLEET_MONITOR_API) {
        let b = String(env.FLEET_MONITOR_API);
        const i = b.lastIndexOf('/api/');
        if (i !== -1) b = b.slice(0, i);
        b = b.replace(/\/api$/, '').replace(/\/+$/, '');
        base = b ? kg.acceptFleetUrl(b, '$FLEET_MONITOR_API') : null;
    }
    if (!base) {
        const err = new Error(kg.unresolvedFleetUrlMessage('imessage-relay'));
        err.code = 'FLEET_URL_UNRESOLVED';
        throw err;
    }
    return base.replace(/\/+$/, '');
}

// ── Error reduction ──────────────────────────────────────────────────────────

/**
 * Reduce an execFile failure to a coarse, argv-free class. We look at
 * err.stderr ONLY for the -1743 (Automation not authorised) marker; err.message
 * is never inspected because it embeds the argv (and so the text), and the
 * original error is never returned.
 * @returns {string} matches ERROR_TYPE_RE
 */
function classifyExecError(err) {
    if (!err || typeof err !== 'object') return 'osascript_error';
    if (err.code === 'ENOENT') return 'osascript_missing';
    if (err.code === 'ETIMEDOUT' || err.killed === true) return 'osascript_timeout';
    const stderr = typeof err.stderr === 'string' ? err.stderr
        : (err.stderr && typeof err.stderr.toString === 'function' ? err.stderr.toString() : '');
    if (stderr.includes('-1743')) return 'not_authorized';
    if (typeof err.code === 'number') return `osascript_exit_${err.code}`;
    if (typeof err.signal === 'string' && err.signal) return 'osascript_signal';
    return 'osascript_error';
}

/** Reduce a fetch/transport failure to a loggable token (no URL, no body). */
function describeNetError(err) {
    if (!err || typeof err !== 'object') return 'net_error';
    if (err.name === 'AbortError' || err.name === 'TimeoutError') return 'timeout';
    if (typeof err.code === 'string' && /^[A-Z0-9_]{1,40}$/.test(err.code)) return err.code;
    const cc = err.cause && err.cause.code;
    if (typeof cc === 'string' && /^[A-Z0-9_]{1,40}$/.test(cc)) return cc;
    return 'net_error';
}

// ── osascript wrappers ───────────────────────────────────────────────────────

/** Promise wrapper around execFile. Resolves {ok, stdout} or {ok:false, errorType}; never rejects. */
function runOsascript(execFile, args, timeoutMs) {
    return new Promise((resolve) => {
        try {
            execFile(OSASCRIPT, args, { timeout: timeoutMs }, (err, stdout) => {
                if (err) return resolve({ ok: false, errorType: classifyExecError(err) });
                resolve({ ok: true, stdout: typeof stdout === 'string' ? stdout : String(stdout || '') });
            });
        } catch (_) {
            resolve({ ok: false, errorType: 'osascript_error' });
        }
    });
}

/**
 * Send one message. argv form: `-e SCRIPT -- text recipient`.
 *
 * The `--` is load-bearing and a deliberate deviation from the bare
 * `-e SCRIPT text recipient` form: osascript runs getopt over the whole
 * argument list, so a message beginning with "-" (e.g. "-l oops") is parsed as
 * an osascript OPTION and the send fails (measured on macOS: "illegal option").
 * `--` ends option parsing; the script still sees argv = [text, recipient].
 *
 * @returns {Promise<{ok:boolean, errorType?:string}>}
 */
async function sendMessage(execFile, text, recipient) {
    const r = await runOsascript(execFile, ['-e', SEND_SCRIPT, '--', text, recipient], SEND_TIMEOUT_MS);
    return r.ok ? { ok: true } : { ok: false, errorType: r.errorType };
}

/**
 * Capability probe: does Messages have >= 1 enabled iMessage account?
 * @returns {Promise<{capable:boolean, reason:string}>}
 */
async function probeCapability(execFile, platform) {
    if ((platform || process.platform) !== 'darwin') return { capable: false, reason: 'not_macos' };
    const r = await runOsascript(execFile, ['-e', PROBE_SCRIPT], PROBE_TIMEOUT_MS);
    if (!r.ok) return { capable: false, reason: `probe_failed:${r.errorType}` };
    const n = parseInt(String(r.stdout).trim(), 10);
    if (Number.isFinite(n) && n > 0) return { capable: true, reason: `imessage_accounts=${n}` };
    return { capable: false, reason: 'no_enabled_imessage_account' };
}

// ── HTTP ─────────────────────────────────────────────────────────────────────

async function relayPost(deps, url, payload, timeoutMs, signal) {
    const headers = Object.assign({ 'Content-Type': 'application/json' }, await kg.fleetRequestHeaders(url));
    const ac = new AbortController();
    const onAbort = () => ac.abort();
    if (signal) {
        if (signal.aborted) ac.abort(); else signal.addEventListener('abort', onAbort, { once: true });
    }
    const timer = setTimeout(() => ac.abort(), timeoutMs);
    try {
        // fleetFetchInit() LAST so a caller can never re-enable redirect following.
        const res = await deps.fetch(url, {
            method: 'POST',
            headers,
            body: JSON.stringify(payload),
            signal: ac.signal,
            ...kg.fleetFetchInit(),
        });
        return kg.assertNoRedirect(res, url);
    } finally {
        clearTimeout(timer);
        if (signal) signal.removeEventListener('abort', onAbort);
    }
}

/** Parse a lease expiry (ISO string or epoch ms) to epoch ms, or NaN. */
function parseLease(v) {
    if (typeof v === 'number') return v;
    if (typeof v === 'string' && v) return Date.parse(v);
    return NaN;
}

/** Server time (epoch ms) from the HTTP Date header, or NaN when absent/unusable. */
function parseServerDate(res) {
    try {
        const h = res && res.headers && typeof res.headers.get === 'function' ? res.headers.get('date') : null;
        return typeof h === 'string' && h ? Date.parse(h) : NaN;
    } catch (_) { return NaN; }
}

/** Next backoff delay: 5s doubling, capped at 60s. */
function nextBackoff(prevMs) {
    return prevMs ? Math.min(prevMs * 2, BACKOFF_MAX_MS) : BACKOFF_MIN_MS;
}

// ── Ack ──────────────────────────────────────────────────────────────────────

/**
 * Ack a job. 200 ok. 409/404: logged by job id and dropped (never retry the
 * send). Transient failure (5xx / network): a couple of short retries, then
 * give up and let the lease expire (at-least-once).
 * @returns {Promise<string>} 'acked' | 'dropped' | 'failed'
 */
async function ackJob(deps, state, jobId, result) {
    const body = { machineId: state.machineId, jobId, ok: !!result.ok };
    if (!result.ok && result.errorType && ERROR_TYPE_RE.test(result.errorType)) body.errorType = result.errorType;
    const url = `${state.base}${ACK_PATH}`;

    for (let attempt = 0; attempt <= ACK_RETRIES; attempt++) {
        try {
            const res = await relayPost(deps, url, body, ACK_TIMEOUT_MS, null);
            if (res.status === 200) return 'acked';
            if (res.status === 409 || res.status === 404) {
                deps.log(`ack dropped job=${jobId} http=${res.status} (${res.status === 409 ? 'lease_not_held' : 'unknown_job'})`);
                return 'dropped';
            }
            deps.log(`ack http=${res.status} job=${jobId} attempt=${attempt + 1}`);
            if (res.status >= 400 && res.status < 500) return 'failed'; // not retryable
        } catch (err) {
            deps.log(`ack error=${describeNetError(err)} job=${jobId} attempt=${attempt + 1}`);
        }
        if (attempt < ACK_RETRIES) await deps.sleep(ACK_RETRY_BASE_MS * (attempt + 1), deps.signal);
    }
    deps.log(`ack gave up job=${jobId}; lease will expire and the server may resend`);
    return 'failed';
}

// ── One claim cycle ──────────────────────────────────────────────────────────

/**
 * Capability gate with a cache. Mutates state.probe = {capable, reason, at}.
 */
async function ensureCapable(deps, state) {
    const now = deps.now();
    const p = state.probe;
    if (p && now - p.at < (p.capable ? PROBE_TTL_OK_MS : PROBE_TTL_BAD_MS)) return p;
    const r = await probeCapability(deps.execFile, deps.platform);
    if (!p || p.capable !== r.capable || p.reason !== r.reason) deps.log(`probe capable=${r.capable} reason=${r.reason}`);
    state.probe = { capable: r.capable, reason: r.reason, at: now };
    return state.probe;
}

/**
 * One claim cycle. Never throws.
 * @returns {Promise<{outcome:string, jobId?:string}>}
 *   outcome: incapable | idle | sent | send_failed | expired | invalid_job |
 *            error (backoff-worthy)
 */
async function runCycle(deps, state) {
    const probe = await ensureCapable(deps, state);
    if (!probe.capable) return { outcome: 'incapable' };

    let res;
    try {
        res = await relayPost(deps, `${state.base}${CLAIM_PATH}`,
            { machineId: state.machineId, waitSeconds: WAIT_SECONDS }, CLAIM_TIMEOUT_MS, deps.signal);
    } catch (err) {
        if (deps.signal && deps.signal.aborted) return { outcome: 'idle' }; // shutting down
        deps.log(`claim error=${err && err.code === 'FLEET_REDIRECT_REFUSED' ? 'redirect_refused' : describeNetError(err)}`);
        return { outcome: 'error' };
    }

    if (res.status === 204) return { outcome: 'idle' };
    if (res.status !== 200) {
        deps.log(`claim http=${res.status}`);
        return { outcome: 'error' };
    }

    // Local receipt time for the lease check below. The lease is only ever
    // measured against this machine's OWN elapsed time since the response.
    const t0 = deps.now();
    let job;
    try { job = await res.json(); } catch (_) { job = null; }
    if (!job || typeof job.jobId !== 'string' || !job.jobId) {
        deps.log('claim returned an unparseable job');
        return { outcome: 'error' };
    }
    const jobId = job.jobId;

    if (typeof job.text !== 'string' || typeof job.recipient !== 'string' || !job.text || !job.recipient) {
        deps.log(`job=${jobId} invalid payload; acking failure`);
        await ackJob(deps, state, jobId, { ok: false, errorType: 'invalid_job' });
        return { outcome: 'invalid_job', jobId };
    }

    // Lease check WITHOUT comparing the server's clock to ours (a Mac a minute
    // ahead would otherwise skip, and burn an attempt on, every job). The lease
    // length is leaseExpiresAt minus the server's own time (HTTP Date header),
    // and what has elapsed is measured on our clock since t0. No usable server
    // time -> send anyway: the server is the authority and at-least-once
    // delivery tolerates a duplicate. When we do decide the lease is gone, ack
    // the failure so the server requeues at once instead of waiting it out.
    const lease = parseLease(job.leaseExpiresAt);
    const serverNow = parseServerDate(res);
    if (Number.isFinite(lease) && Number.isFinite(serverNow) && (lease - serverNow) - (deps.now() - t0) <= 0) {
        deps.log(`job=${jobId} lease already expired; acking lease_expired_local`);
        await ackJob(deps, state, jobId, { ok: false, errorType: 'lease_expired_local' });
        return { outcome: 'expired', jobId };
    }

    const sent = await sendMessage(deps.execFile, job.text, job.recipient);
    if (!sent.ok) {
        deps.log(`job=${jobId} send failed errorType=${sent.errorType}`);
        state.probe = null; // a broken Messages setup should be re-probed, not trusted for 5 min
        await ackJob(deps, state, jobId, { ok: false, errorType: sent.errorType });
        return { outcome: 'send_failed', jobId };
    }
    deps.log(`job=${jobId} sent`);
    await ackJob(deps, state, jobId, { ok: true });
    return { outcome: 'sent', jobId };
}

// ── Loop ─────────────────────────────────────────────────────────────────────

/**
 * Build the effective dependency set. Everything with a side effect is
 * injectable (execFile, fetch, now, sleep, log, platform).
 */
function makeDeps(overrides) {
    const o = overrides || {};
    return {
        execFile: o.execFile || realExecFile,
        fetch: o.fetch || ((...a) => fetch(...a)),
        now: o.now || (() => Date.now()),
        sleep: o.sleep || defaultSleep,
        log: o.log || ((line) => process.stderr.write(`${new Date().toISOString()} imessage-relay: ${line}\n`)),
        platform: o.platform || process.platform,
        signal: o.signal || null,
    };
}

/** Sleep that wakes early when `signal` aborts. */
function defaultSleep(ms, signal) {
    return new Promise((resolve) => {
        if (signal && signal.aborted) return resolve();
        const t = setTimeout(done, ms);
        function done() { clearTimeout(t); if (signal) signal.removeEventListener('abort', done); resolve(); }
        if (signal) signal.addEventListener('abort', done, { once: true });
    });
}

/**
 * The long-running loop. Returns when deps.signal aborts.
 * Config problems (no URL / no machine id) back off like any other error so a
 * KeepAlive agent never spins.
 */
async function runLoop(deps, opts) {
    const o = opts || {};
    const resolveBaseFn = o.resolveBase || resolveBase;
    const resolveIdFn = o.resolveMachineId || resolveMachineId;
    const state = { base: null, machineId: null, probe: null };
    let backoff = 0;
    const stopped = () => !!(deps.signal && deps.signal.aborted);

    while (!stopped()) {
        let delay = 0;
        try {
            state.base = resolveBaseFn();
            state.machineId = resolveIdFn();
            if (!state.machineId) {
                const e = new Error('no machine id (expected machine-identity.json or ~/.fleet-machine-id)');
                e.code = 'NO_MACHINE_ID';
                throw e;
            }
        } catch (err) {
            // Messages here are our own config diagnostics (no job data in scope).
            deps.log(`config error: ${err && err.message ? err.message : 'unresolved'}`);
            if (o.once) return { outcome: 'error' };
            backoff = nextBackoff(backoff);
            await deps.sleep(backoff, deps.signal);
            continue;
        }

        const r = await runCycle(deps, state);
        if (o.onCycle) o.onCycle(r);
        switch (r.outcome) {
            case 'error':
                backoff = nextBackoff(backoff);
                delay = backoff;
                break;
            case 'incapable':
                delay = INCAPABLE_SLEEP_MS;
                break;
            default: // idle (204 -> loop at once), sent, send_failed, expired, invalid_job
                backoff = 0;
        }
        if (o.once) return r;
        if (delay) await deps.sleep(delay, deps.signal);
    }
    return { outcome: 'stopped' };
}

// ── CLI ──────────────────────────────────────────────────────────────────────

const HELP = `imessage-relay — Mac relay for the Fleet Monitor iMessage sender pool.

Usage:
  node imessage-relay.js run [--once]   claim/send/ack loop (LaunchAgent)
  node imessage-relay.js probe          exit 0 capable, 3 not capable
  node imessage-relay.js --once         one claim cycle, then exit

Exit codes: 0 ok, 1 error / send failed, 2 usage, 3 not capable (probe, --once).
Must run in the logged-in GUI session (LaunchAgent), never a LaunchDaemon.
`;

function parseArgs(argv) {
    const out = { cmd: null, once: false, help: false };
    for (const a of argv) {
        if (a === 'run' || a === 'probe') { if (out.cmd) throw new Error('only one command allowed'); out.cmd = a; }
        else if (a === '--once') out.once = true;
        else if (a === '-h' || a === '--help') out.help = true;
        else throw new Error(`Unknown argument: ${a}`);
    }
    if (!out.cmd && out.once) out.cmd = 'run';
    return out;
}

async function main(argv, overrides) {
    let args;
    try { args = parseArgs(argv); } catch (err) {
        process.stderr.write(`${err.message}\n\n${HELP}`);
        return 2;
    }
    if (args.help || !args.cmd) { process.stdout.write(HELP); return args.help ? 0 : 2; }

    const ac = new AbortController();
    const deps = makeDeps(Object.assign({ signal: ac.signal }, overrides || {}));
    const out = (overrides && overrides.out) || ((l) => process.stdout.write(l));

    if (args.cmd === 'probe') {
        const r = await probeCapability(deps.execFile, deps.platform);
        out(`${r.capable ? 'capable' : 'not capable'}: ${r.reason}\n`);
        return r.capable ? 0 : 3;
    }

    // run
    const onSig = () => { deps.log('signal received; finishing the current job then exiting'); ac.abort(); };
    if (!overrides || !overrides.signal) { process.once('SIGTERM', onSig); process.once('SIGINT', onSig); }
    try {
        const r = await runLoop(deps, { once: args.once });
        if (!args.once) return 0;
        out(`outcome: ${r.outcome}${r.jobId ? ` job=${r.jobId}` : ''}\n`);
        if (r.outcome === 'incapable') return 3;
        return (r.outcome === 'error' || r.outcome === 'send_failed' || r.outcome === 'invalid_job') ? 1 : 0;
    } finally {
        process.removeListener('SIGTERM', onSig);
        process.removeListener('SIGINT', onSig);
    }
}

if (require.main === module) {
    main(process.argv.slice(2)).then((code) => process.exit(code), () => process.exit(1));
}

module.exports = {
    SEND_SCRIPT,
    PROBE_SCRIPT,
    OSASCRIPT,
    CLAIM_PATH,
    ACK_PATH,
    SEND_TIMEOUT_MS,
    WAIT_SECONDS,
    CLAIM_TIMEOUT_MS,
    BACKOFF_MIN_MS,
    BACKOFF_MAX_MS,
    PROBE_TTL_OK_MS,
    INCAPABLE_SLEEP_MS,
    resolveMachineId,
    resolveBase,
    classifyExecError,
    describeNetError,
    sendMessage,
    probeCapability,
    ackJob,
    ensureCapable,
    runCycle,
    runLoop,
    makeDeps,
    nextBackoff,
    parseLease,
    parseArgs,
    main,
};
