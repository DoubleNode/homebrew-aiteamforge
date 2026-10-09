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
 *     async send(connection, message) // ONE attempt, no retries,
 *                                     // resolves {providerMessageId?},
 *                                     // throws NotifySendError on failure }
 *
 *  - Error messages NEVER carry destinations, params or secrets.
 *  - A FOREIGN exception's text may embed the target (a URL in a fetch error,
 *    a token in a library message): attemptSend records its TYPE only.
 *  - Only the `test` provider is registered by default. Real channels land in
 *    XACA-1401 (Teams/Slack/email/push) and XACA-1402 (SMS).
 */

class NotifyError extends Error {
    constructor(message) { super(message); this.name = this.constructor.name; }
}
class NotifyConfigError extends NotifyError {}
class NotifySendError extends NotifyError {}

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
async function attemptSend(provider, connection, message) {
    try {
        provider.validate(connection);
        const res = await provider.send(connection, message);
        const out = { ok: true, error: '' };
        if (res && typeof res.providerMessageId === 'string' && res.providerMessageId) {
            out.providerMessageId = res.providerMessageId;
        }
        return out;
    } catch (err) {
        if (err instanceof NotifyError) return { ok: false, error: err.message };
        const type = (err && err.constructor && err.constructor.name) || 'Error';
        return { ok: false, error: `provider error (${type})` };
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
    return {
        name: 'test',
        paramFields: [],
        secretFields: ['token'],
        calls,
        failNext(n = 1) { failures = n; },
        reset() { calls.length = 0; failures = 0; seq = 0; },
        validate(connection) {
            const t = connection && connection.secrets && connection.secrets.token;
            if (typeof t !== 'string' || !t.trim()) throw new NotifyConfigError('test provider requires a token');
        },
        async send(connection, message) {
            calls.push({ connectionId: connection.id, message: { ...message } });
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
    const reg = createProviderRegistry();
    reg.register('test', createTestProvider());
    return reg;
}

module.exports = {
    NotifyError, NotifyConfigError, NotifySendError,
    createProviderRegistry, attemptSend, createTestProvider, defaultRegistry,
};
