//
//  ci-dispatch-github.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * GitHub App client for the Fleet Monitor CI dispatcher (XACA-1441-002).
 * Design: kanban/plans/XACA-1441/XACA-1441_ci_dispatcher.md D2 + D3.
 *
 * Responsibilities, and nothing else (watcher, placement, routes are later phases):
 *   - RS256 App JWT with node:crypto (no dependency), iat = now-60s, exp = now+9m.
 *   - Installation-id lookup (cached) and installation access tokens, down-scoped
 *     per purpose: 'watcher' => {actions:read}; 'admin' => {administration:write}.
 *     Tokens live in memory until 5 min before expiry and are never persisted.
 *   - Conditional GET (ETag / If-None-Match) returning a 304 indicator.
 *   - Rate-limit tracking + the D3 self-protection thresholds, exposed as state.
 *   - generateJitConfig / deleteRunner.
 *
 * JWT issuer: GITHUB_APP_CLIENT_ID (preferred; GitHub's current recommendation) or
 * GITHUB_APP_ID (still accepted). Neither is secret; the private key is.
 *
 * SECRETS RULE (plan Requirement 11): GITHUB_APP_CLIENT_ID / GITHUB_APP_ID /
 * GITHUB_APP_PRIVATE_KEY are read ONLY here, via the injectable `config`. Every Error this module throws is a
 * GithubError whose message is built from fixed strings, the HTTP status and a
 * path TEMPLATE. Response bodies, the key, JWTs, installation tokens and JIT
 * configs are never copied into a message, and this module never logs.
 */

const crypto = require('crypto');

const API_BASE = 'https://api.github.com';
const API_VERSION = '2022-11-28';
const JWT_BACKDATE_S = 60;          // clock-skew allowance (GitHub's own advice)
const JWT_LIFETIME_S = 9 * 60;      // GitHub max is 10 min; stay under it
const TOKEN_REFRESH_MARGIN_MS = 5 * 60 * 1000;
const SLOW_BELOW = 0.20;            // D3: <20% remaining => slow cadence
const SUSPEND_BELOW = 0.05;         // D3: <5% remaining => suspend until reset
const MAX_ETAG_ENTRIES = 2000;
const DEFAULT_RUNNER_GROUP_ID = 1;

// Purpose -> installation-token permissions (least privilege per call).
const PURPOSE_PERMISSIONS = Object.freeze({
    watcher: Object.freeze({ actions: 'read' }),
    admin:   Object.freeze({ administration: 'write' }),
});

const OWNER_RE = /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$/;
const REPO_RE = /^[A-Za-z0-9._-]{1,100}$/;

class GithubError extends Error {
    /**
     * @param {string} code    stable machine code (e.g. 'RATE_LIMITED')
     * @param {string} message fixed-string message; MUST NOT contain secrets
     * @param {object} [extra] status / retryAfterMs
     */
    constructor(code, message, extra = {}) {
        super(message);
        this.name = 'GithubError';
        this.code = code;
        if (extra.status !== undefined) this.status = extra.status;
        if (extra.retryAfterMs !== undefined) this.retryAfterMs = extra.retryAfterMs;
    }
}

const b64url = (buf) => Buffer.from(buf).toString('base64')
    .replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');

/** A PEM pasted through a secret store often carries literal "\n" sequences. */
function normalizePem(raw) {
    return String(raw).replace(/\\n/g, '\n').trim() + '\n';
}

function checkRepo(owner, repo) {
    if (!OWNER_RE.test(String(owner)) || !REPO_RE.test(String(repo)) || repo === '.' || repo === '..') {
        throw new GithubError('BAD_REPO', 'invalid owner/repo');
    }
}

/**
 * @param {object} [opts]
 * @param {object}   [opts.config]   {GITHUB_APP_CLIENT_ID?, GITHUB_APP_ID?, GITHUB_APP_PRIVATE_KEY}; defaults to process.env
 * @param {Function} [opts.fetch]    defaults to global fetch
 * @param {Function} [opts.now]      ms clock, defaults to Date.now
 * @param {string}   [opts.apiBase]
 * @param {string}   [opts.userAgent]
 * @param {Function} [opts.onDegraded] called ONCE per suspend episode with
 *                                     {remaining, limit, resetAt}
 */
function createGithubClient(opts = {}) {
    const config = opts.config || process['env'];
    const doFetch = opts.fetch || ((...a) => globalThis.fetch(...a));
    const now = opts.now || Date.now;
    const apiBase = opts.apiBase || API_BASE;
    const userAgent = opts.userAgent || 'fleet-monitor-ci-dispatcher';
    const onDegraded = typeof opts.onDegraded === 'function' ? opts.onDegraded : null;

    const installationIds = new Map();   // "owner/repo" -> id
    const tokens = new Map();            // "id|purpose|repo" -> {token, expiresAtMs}
    const etags = new Map();             // "purpose|owner/repo|path" -> {etag, data}
    const rate = { limit: null, remaining: null, resetAtMs: null };
    let blockedUntilMs = 0;              // secondary-limit retry-after
    let degradedRaisedForReset = null;   // resetAtMs of the episode already signalled

    // ---- App JWT ----------------------------------------------------------
    function appJwt() {
        // Client ID is preferred; App ID is the fallback. Blank values count as unset.
        const clean = (v) => (v === undefined || v === null ? '' : String(v).trim());
        const issuer = clean(config.GITHUB_APP_CLIENT_ID) || clean(config.GITHUB_APP_ID);
        const key = config.GITHUB_APP_PRIVATE_KEY;
        if (!issuer || !key) {
            throw new GithubError('NOT_CONFIGURED',
                'GitHub App credentials are not configured (need GITHUB_APP_CLIENT_ID or GITHUB_APP_ID, and GITHUB_APP_PRIVATE_KEY)');
        }
        // Loose sanity check only: client ids look like "Iv23li...", app ids are numeric.
        // Reject whitespace/control/odd characters; never echo the value.
        if (!/^[A-Za-z0-9._-]+$/.test(issuer)) {
            throw new GithubError('NOT_CONFIGURED', 'GitHub App Client ID / App ID has an invalid format');
        }
        const nowS = Math.floor(now() / 1000);
        const header = b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
        const claims = b64url(JSON.stringify({
            iat: nowS - JWT_BACKDATE_S,
            exp: nowS + JWT_LIFETIME_S,
            iss: issuer,
        }));
        const signingInput = `${header}.${claims}`;
        let sig;
        try {
            const signer = crypto.createSign('RSA-SHA256');
            signer.update(signingInput);
            sig = signer.sign(normalizePem(key));
        } catch (_) {
            // Deliberately drop the underlying error: it is not allowed near key material.
            throw new GithubError('KEY_INVALID', 'GitHub App private key could not sign a JWT');
        }
        return `${signingInput}.${b64url(sig)}`;
    }

    // ---- rate-limit tracking ----------------------------------------------
    function recordRate(headers) {
        const get = (n) => (headers && typeof headers.get === 'function' ? headers.get(n) : null);
        if (get('x-ratelimit-limit') === null || get('x-ratelimit-remaining') === null) return;
        const limit = Number(get('x-ratelimit-limit'));
        const remaining = Number(get('x-ratelimit-remaining'));
        const reset = Number(get('x-ratelimit-reset'));
        if (!Number.isFinite(limit) || limit <= 0 || !Number.isFinite(remaining)) return;
        rate.limit = limit;
        rate.remaining = remaining;
        rate.resetAtMs = Number.isFinite(reset) && reset > 0 ? reset * 1000 : rate.resetAtMs;
        if (remaining / limit < SUSPEND_BELOW && rate.resetAtMs
            && degradedRaisedForReset !== rate.resetAtMs) {
            degradedRaisedForReset = rate.resetAtMs;
            if (onDegraded) {
                try { onDegraded({ remaining, limit, resetAt: rate.resetAtMs }); } catch (_) { /* alert hook must not break calls */ }
            }
        }
    }

    /**
     * mode: 'normal' | 'slow' (<20%) | 'suspended' (<5%, until reset) | 'blocked' (retry-after).
     * The watcher applies the cadence; this module only reports.
     */
    function getRateState() {
        const t = now();
        const base = {
            limit: rate.limit, remaining: rate.remaining, resetAt: rate.resetAtMs,
            fraction: rate.limit ? rate.remaining / rate.limit : null,
        };
        if (blockedUntilMs > t) return { ...base, mode: 'blocked', resumeAt: blockedUntilMs };
        const stale = rate.resetAtMs !== null && t >= rate.resetAtMs; // window rolled over
        if (rate.limit && !stale) {
            if (base.fraction < SUSPEND_BELOW) return { ...base, mode: 'suspended', resumeAt: rate.resetAtMs };
            if (base.fraction < SLOW_BELOW) return { ...base, mode: 'slow', resumeAt: null };
        }
        return { ...base, mode: 'normal', resumeAt: null };
    }

    // ---- transport ---------------------------------------------------------
    async function http(method, pathTemplate, urlPath, { bearer, body, headers } = {}) {
        const t = now();
        if (blockedUntilMs > t) {
            throw new GithubError('RATE_LIMITED', `GitHub secondary rate limit: retry after ${blockedUntilMs - t} ms`,
                { retryAfterMs: blockedUntilMs - t });
        }
        let res;
        try {
            res = await doFetch(apiBase + urlPath, {
                method,
                headers: {
                    Accept: 'application/vnd.github+json',
                    'X-GitHub-Api-Version': API_VERSION,
                    'User-Agent': userAgent,
                    Authorization: `Bearer ${bearer}`,
                    ...(body !== undefined ? { 'Content-Type': 'application/json' } : {}),
                    ...(headers || {}),
                },
                body: body !== undefined ? JSON.stringify(body) : undefined,
            });
        } catch (_) {
            throw new GithubError('NETWORK', `${method} ${pathTemplate} failed: network error`);
        }
        recordRate(res.headers);
        if (res.status === 403 || res.status === 429) {
            const raw = res.headers && res.headers.get('retry-after');
            const ra = Number(raw);
            if (raw !== null && raw !== undefined && Number.isFinite(ra) && ra >= 0) {
                blockedUntilMs = now() + ra * 1000;
                throw new GithubError('RATE_LIMITED', `${method} ${pathTemplate} rate limited (HTTP ${res.status}): retry after ${ra} s`,
                    { status: res.status, retryAfterMs: ra * 1000 });
            }
            if (rate.remaining === 0 && rate.resetAtMs) {
                throw new GithubError('RATE_LIMITED', `${method} ${pathTemplate} primary rate limit exhausted (HTTP ${res.status})`,
                    { status: res.status, retryAfterMs: Math.max(0, rate.resetAtMs - now()) });
            }
        }
        return res;
    }

    const parseBody = async (res) => {
        try { return await res.json(); } catch (_) { return null; }
    };

    // ---- installation + tokens ---------------------------------------------
    async function getInstallationId(owner, repo) {
        checkRepo(owner, repo);
        const key = `${owner}/${repo}`;
        if (installationIds.has(key)) return installationIds.get(key);
        const res = await http('GET', '/repos/{owner}/{repo}/installation',
            `/repos/${owner}/${repo}/installation`, { bearer: appJwt() });
        if (res.status === 404) throw new GithubError('NOT_INSTALLED', 'GitHub App is not installed on this repository', { status: 404 });
        if (res.status !== 200) throw new GithubError('HTTP', `GET /repos/{owner}/{repo}/installation failed: HTTP ${res.status}`, { status: res.status });
        const data = await parseBody(res);
        if (!data || !Number.isInteger(data.id)) throw new GithubError('BAD_RESPONSE', 'installation lookup returned no id');
        installationIds.set(key, data.id);
        return data.id;
    }

    async function getToken({ owner, repo, purpose }) {
        const perms = PURPOSE_PERMISSIONS[purpose];
        if (!perms) throw new GithubError('BAD_PURPOSE', 'unknown token purpose');
        const id = await getInstallationId(owner, repo);
        const cacheKey = `${id}|${purpose}|${repo}`;
        const hit = tokens.get(cacheKey);
        if (hit && now() < hit.expiresAtMs - TOKEN_REFRESH_MARGIN_MS) return hit.token;

        const res = await http('POST', '/app/installations/{id}/access_tokens',
            `/app/installations/${id}/access_tokens`,
            { bearer: appJwt(), body: { repositories: [repo], permissions: { ...perms } } });
        if (res.status !== 201) {
            if (res.status === 404 || res.status === 401) installationIds.delete(`${owner}/${repo}`);
            throw new GithubError('HTTP', `POST /app/installations/{id}/access_tokens failed: HTTP ${res.status}`, { status: res.status });
        }
        const data = await parseBody(res);
        const expiresAtMs = data ? Date.parse(data.expires_at) : NaN;
        if (!data || typeof data.token !== 'string' || !Number.isFinite(expiresAtMs)) {
            throw new GithubError('BAD_RESPONSE', 'access token response malformed');
        }
        tokens.set(cacheKey, { token: data.token, expiresAtMs });
        return data.token;
    }

    /** Authenticated call with one retry if GitHub rejects a (revoked/early-expired) cached token. */
    async function withToken(ctx, fn) {
        let res = await fn(await getToken(ctx));
        if (res.status === 401) {
            const id = await getInstallationId(ctx.owner, ctx.repo);
            tokens.delete(`${id}|${ctx.purpose}|${ctx.repo}`);
            res = await fn(await getToken(ctx));
        }
        return res;
    }

    // ---- conditional GET ----------------------------------------------------
    /**
     * @returns {Promise<{status:number, notModified:boolean, data:any, etag:string|null}>}
     * On 304, `data` is the cached body from the earlier 200.
     */
    async function conditionalGet({ owner, repo, path: urlPath, purpose = 'watcher' }) {
        if (typeof urlPath !== 'string' || !urlPath.startsWith('/')) throw new GithubError('BAD_PATH', 'path must start with /');
        const ek = `${purpose}|${owner}/${repo}|${urlPath}`;
        const res = await withToken({ owner, repo, purpose }, (token) => {
            const cached = etags.get(ek);
            return http('GET', 'conditional', urlPath, {
                bearer: token,
                headers: cached ? { 'If-None-Match': cached.etag } : undefined,
            });
        });
        if (res.status === 304) {
            const cached = etags.get(ek);
            return { status: 304, notModified: true, data: cached ? cached.data : null, etag: cached ? cached.etag : null };
        }
        if (res.status !== 200) {
            throw new GithubError('HTTP', `GET ${urlPath.split('?')[0].replace(/\d+/g, '{n}')} failed: HTTP ${res.status}`, { status: res.status });
        }
        const data = await parseBody(res);
        const etag = res.headers.get('etag');
        if (etag) {
            if (etags.size >= MAX_ETAG_ENTRIES && !etags.has(ek)) etags.delete(etags.keys().next().value);
            etags.set(ek, { etag, data });
        }
        return { status: 200, notModified: false, data, etag: etag || null };
    }

    // ---- runner admin --------------------------------------------------------
    /** The returned encodedJitConfig is a credential: callers must never log or persist it. */
    async function generateJitConfig({ owner, repo, name, labels, runnerGroupId = DEFAULT_RUNNER_GROUP_ID, workFolder = '_work' }) {
        checkRepo(owner, repo);
        if (typeof name !== 'string' || !name || !Array.isArray(labels) || labels.length === 0) {
            throw new GithubError('BAD_ARGS', 'generateJitConfig needs a name and a non-empty labels array');
        }
        const res = await withToken({ owner, repo, purpose: 'admin' }, (token) => http('POST',
            '/repos/{owner}/{repo}/actions/runners/generate-jitconfig',
            `/repos/${owner}/${repo}/actions/runners/generate-jitconfig`,
            { bearer: token, body: { name, runner_group_id: runnerGroupId, labels, work_folder: workFolder } }));
        if (res.status !== 201) {
            throw new GithubError('HTTP', `POST /repos/{owner}/{repo}/actions/runners/generate-jitconfig failed: HTTP ${res.status}`, { status: res.status });
        }
        const data = await parseBody(res);
        if (!data || !data.runner || !Number.isInteger(data.runner.id) || typeof data.encoded_jit_config !== 'string') {
            throw new GithubError('BAD_RESPONSE', 'generate-jitconfig response malformed');
        }
        return { runnerId: data.runner.id, encodedJitConfig: data.encoded_jit_config };
    }

    /** 404 counts as success: the registration is already gone (JIT runners self-delete after a job). */
    async function deleteRunner({ owner, repo, runnerId }) {
        checkRepo(owner, repo);
        if (!Number.isInteger(runnerId) || runnerId <= 0) throw new GithubError('BAD_ARGS', 'runnerId must be a positive integer');
        const res = await withToken({ owner, repo, purpose: 'admin' }, (token) => http('DELETE',
            '/repos/{owner}/{repo}/actions/runners/{id}',
            `/repos/${owner}/${repo}/actions/runners/${runnerId}`, { bearer: token }));
        if (res.status === 204) return { deleted: true };
        if (res.status === 404) return { deleted: false, alreadyGone: true };
        throw new GithubError('HTTP', `DELETE /repos/{owner}/{repo}/actions/runners/{id} failed: HTTP ${res.status}`, { status: res.status });
    }

    return { getInstallationId, getToken, conditionalGet, generateJitConfig, deleteRunner, getRateState };
}

module.exports = {
    createGithubClient, GithubError, PURPOSE_PERMISSIONS,
    TOKEN_REFRESH_MARGIN_MS, SLOW_BELOW, SUSPEND_BELOW, JWT_BACKDATE_S, JWT_LIFETIME_S,
};
