//
//  index.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * Notification provider interface + registry (XACA-1400-005, EPIC-0068 D4).
 * Node mirror of the Python contract in kanban-hooks/release_notify.py.
 *
 * Provider shape:
 *   { name, paramFields: string[], secretFields: string[],
 *     validate(connection)            // sync, NO network, throws NotifyConfigError
 *     async send(connection, message, { signal })
 *                                     // ONE attempt, no retries,
 *                                     // resolves {providerMessageId?},
 *                                     // throws NotifySendError on failure }
 *
 *  - `signal` is an AbortSignal the dispatcher aborts when its send timeout
 *    fires. Providers MUST pass it to their HTTP/network calls
 *    (fetch(url, { signal }), request options, etc.) so a timed-out send is
 *    actually cancelled instead of continuing in the background. XACA-1401's
 *    real providers must honour this.
 *
 *  - Error messages NEVER carry destinations, params or secrets.
 *  - A FOREIGN exception's text may embed the target (a URL in a fetch error,
 *    a token in a library message): attemptSend records its TYPE only.
 *  - defaultRegistry() registers `test` plus the XACA-1401 channels (teams,
 *    slack, email, pushover, ntfy). SMS lands in XACA-1402.
 */

class NotifyError extends Error {
    constructor(message) { super(message); this.name = this.constructor.name; }
}
class NotifyConfigError extends NotifyError {}
class NotifySendError extends NotifyError {}

/**
 * Safe label for a FOREIGN error: its type name only if it looks like an
 * identifier. A thrown object's `name` is attacker/library controlled text and
 * may embed a URL or token in a derived (e.g. URL-encoded) form the dispatcher's
 * exact-match scrubber cannot catch (XACA-1401-006).
 */
function errorTypeName(err, preferCtor = false) {
    const ctor = err && err.constructor && err.constructor.name;
    const raw = preferCtor ? (ctor || (err && err.name)) : (err && (err.name || ctor));
    return typeof raw === 'string' && /^[A-Za-z][A-Za-z0-9_]{0,39}$/.test(raw) ? raw : 'Error';
}

const NAME_RE = /^[a-z][a-z0-9-]{0,31}$/;

function checkFieldList(list, what) {
    if (!Array.isArray(list) || !list.every((f) => typeof f === 'string' && f)) {
        throw new NotifyConfigError(`provider ${what} must be an array of non-empty strings`);
    }
}

function createProviderRegistry() {
    const providers = new Map();
    return {
        register(name, provider) {
            if (typeof name !== 'string' || !NAME_RE.test(name)) {
                throw new NotifyConfigError('invalid provider name');
            }
            if (!provider || typeof provider !== 'object') {
                throw new NotifyConfigError('provider must be an object');
            }
            if (provider.name !== name) throw new NotifyConfigError('provider name mismatch');
            checkFieldList(provider.paramFields, 'paramFields');
            checkFieldList(provider.secretFields, 'secretFields');
            if (typeof provider.validate !== 'function') throw new NotifyConfigError('provider.validate must be a function');
            if (typeof provider.send !== 'function') throw new NotifyConfigError('provider.send must be a function');
            if (providers.has(name)) throw new NotifyConfigError('provider already registered');
            providers.set(name, provider);
        },
        has(name) { return providers.has(name); },
        get(name) {
            const p = providers.get(name);
            if (!p) throw new NotifyConfigError('unknown provider');
            return p;
        },
        names() { return [...providers.keys()].sort(); },
    };
}

/**
 * Run validate + one send and normalize to {ok, error, providerMessageId?}.
 * NotifyError messages pass through; anything else becomes its type name only.
 * Never throws.
 */
async function attemptSend(provider, connection, message, signal) {
    try {
        provider.validate(connection);
        const res = await provider.send(connection, message, { signal });
        const out = { ok: true, error: '' };
        if (res && typeof res.providerMessageId === 'string' && res.providerMessageId) {
            out.providerMessageId = res.providerMessageId;
        }
        return out;
    } catch (err) {
        if (err instanceof NotifyError) return { ok: false, error: err.message };
        return { ok: false, error: `provider error (${errorTypeName(err, true)})` };
    }
}

/**
 * In-memory provider for tests and the hub's "send test" path. Records calls
 * (connection id + message only, never secrets); `failNext(n)` forces failures.
 */
function createTestProvider() {
    const calls = [];
    let failures = 0;
    let seq = 0;
    let hold = false;
    return {
        name: 'test',
        paramFields: [],
        secretFields: ['token'],
        calls,
        failNext(n = 1) { failures = n; },
        /** Make send() hang until its signal aborts (then it rejects, aborted:true on the call). */
        holdSends(on = true) { hold = !!on; },
        reset() { calls.length = 0; failures = 0; seq = 0; hold = false; },
        validate(connection) {
            const t = connection && connection.secrets && connection.secrets.token;
            if (typeof t !== 'string' || !t.trim()) throw new NotifyConfigError('test provider requires a token');
        },
        async send(connection, message, ctx) {
            const signal = ctx && ctx.signal;
            const call = { connectionId: connection.id, message: { ...message } };
            calls.push(call);
            if (signal && hold) {
                // Hung-send simulation that honours the contract: reject on abort.
                await new Promise((resolve, reject) => {
                    const onAbort = () => { call.aborted = true; reject(new NotifySendError('test provider send aborted')); };
                    if (signal.aborted) onAbort(); else signal.addEventListener('abort', onAbort, { once: true });
                });
            }
            if (failures > 0) {
                failures -= 1;
                throw new NotifySendError('test provider forced failure');
            }
            seq += 1;
            return { providerMessageId: `test-${seq}` };
        },
    };
}

function defaultRegistry() {
    // Required lazily: each provider module requires this file for the error
    // classes, so a top-level require here would be a cycle (XACA-1401-005).
    const { createTeamsProvider } = require('./teams');
    const { createSlackProvider } = require('./slack');
    const { createEmailProvider } = require('./email');
    const { createPushoverProvider } = require('./pushover');
    const { createNtfyProvider } = require('./ntfy');
    const reg = createProviderRegistry();
    reg.register('test', createTestProvider());
    reg.register('teams', createTeamsProvider());
    reg.register('slack', createSlackProvider());
    reg.register('email', createEmailProvider());
    reg.register('pushover', createPushoverProvider());
    reg.register('ntfy', createNtfyProvider());
    return reg;
}

module.exports = {
    NotifyError, NotifyConfigError, NotifySendError,
    createProviderRegistry, attemptSend, createTestProvider, defaultRegistry, errorTypeName,
};
