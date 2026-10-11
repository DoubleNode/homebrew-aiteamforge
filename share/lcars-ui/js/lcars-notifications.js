/**
 * lcars-notifications.js
 * XACA-1406-002 / EPIC-0068 item 7 -- team LCARS Notifications panel.
 *
 * Notice-type x Fleet Monitor connection routing matrix, per-type severity
 * override, quiet hours, save (+ route push status) and per-type test send.
 *
 * Server contract (lcars-ui/server.py, XACA-1406 "LCARS server API"):
 *   GET  /api/notify-config?team=T              -> { exists, config|null, sourceVersion, catalog[], severities[] }
 *   GET  /api/notify-config/connections?team=T  -> { connections[{id,provider,label,enabled}] } | { error, message }
 *   POST /api/notify-config        {team,config} -> {ok,saved,push} | 400 {error:"invalid",details[]}
 *   POST /api/notify-config/test   {team,type}   -> {ok,deliveredVia,warning?,result}
 *
 * Depends on (all optional, injected in tests): apiUrl(), apiFetch() from lcars.js/api-auth.js.
 * Every dynamic string is written with textContent -- never innerHTML.
 * Exposes window.lcarsNotifications (browser) and module.exports (node tests).
 */
(function (global) {
    'use strict';

    // ---------------------------------------------------------------------
    // Messages
    // ---------------------------------------------------------------------
    var ERROR_MESSAGES = {
        'no-fm-url': 'Fleet Monitor not configured',
        'no-url': 'Fleet Monitor not configured',
        'no-key': 'No notify key found for this team',
        'key-resolver-unavailable': 'Key resolver unavailable on this machine',
        'unauthorized': 'team notify key rejected (401)',
        'forbidden': 'key belongs to another team (403)',
        'fm-unreachable': 'Fleet Monitor unreachable',
        'fm-error': 'Fleet Monitor returned an error',
        'invalid': 'Configuration rejected',
        'not_found': 'Not found'
    };

    var SUPPRESS_REASONS = {
        'dedupe': 'duplicate inside the dedupe window',
        'quiet-hours': 'quiet hours',
        'severity-gate': 'below the connection minimum severity',
        'rate-limit': 'rate limited'
    };

    function errorMessage(code, fallback) {
        if (code && Object.prototype.hasOwnProperty.call(ERROR_MESSAGES, code)) return ERROR_MESSAGES[code];
        if (fallback) return String(fallback);
        return code ? 'Error: ' + String(code) : 'Unknown error';
    }

    // ---------------------------------------------------------------------
    // Pure helpers (exported for tests)
    // ---------------------------------------------------------------------
    var HHMM = /^([01][0-9]|2[0-3]):[0-5][0-9]$/;
    var TZ_PATTERN = /^[A-Za-z][A-Za-z0-9_+-]*(\/[A-Za-z0-9_+-]+){0,2}$/;

    function browserTimeZone() {
        try { return Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC'; } catch (e) { return 'UTC'; }
    }

    function clone(v) { return v === undefined ? undefined : JSON.parse(JSON.stringify(v)); }
    function isObj(v) { return v !== null && typeof v === 'object' && !Array.isArray(v); }
    function has(o, k) { return Object.prototype.hasOwnProperty.call(o, k); }

    /** q = {enabled,start,end,timezone}. Returns {} when valid, else {start?,end?,timezone?}. */
    function validateQuietHours(q) {
        var errs = {};
        if (!q || !q.enabled) return errs;
        if (!HHMM.test(q.start || '')) errs.start = 'Enter a start time (HH:MM, 24-hour).';
        if (!HHMM.test(q.end || '')) errs.end = 'Enter an end time (HH:MM, 24-hour).';
        if (!errs.start && !errs.end && q.start === q.end) {
            errs.end = 'Start and end must be different times.';
        }
        var tz = q.timezone || '';
        if (!tz || tz.length > 64 || !TZ_PATTERN.test(tz)) {
            errs.timezone = 'Enter an IANA time zone, for example America/Chicago.';
        } else {
            try { new Intl.DateTimeFormat('en-US', { timeZone: tz }); }
            catch (e) { errs.timezone = 'Unknown time zone "' + tz + '".'; }
        }
        return errs;
    }

    /** Model from a loaded config (or null for none / v1). */
    function modelFromConfig(config) {
        var cfg = isObj(config) ? config : {};
        var qh = isObj(cfg.quietHours) ? cfg.quietHours : null;
        return {
            routes: isObj(cfg.routes) ? clone(cfg.routes) : {},
            severityOverrides: isObj(cfg.severityOverrides) ? clone(cfg.severityOverrides) : {},
            quiet: qh
                ? { enabled: true, start: qh.start, end: qh.end, timezone: qh.timezone }
                : { enabled: false, start: '22:00', end: '07:00', timezone: browserTimeZone() }
        };
    }

    /**
     * Round-trip the loaded config: every field the panel does not edit
     * (aliases, dedupeWindow, anything future) is carried through untouched.
     */
    function buildConfig(baseConfig, model) {
        var cfg = isObj(baseConfig) ? clone(baseConfig) : {};
        cfg.$schema = 'release-notify/v2';
        cfg.version = 2;
        var routes = {};
        Object.keys(model.routes).forEach(function (t) {
            var ids = model.routes[t];
            if (Array.isArray(ids)) routes[t] = ids.slice();
        });
        cfg.routes = routes;
        var sev = {};
        Object.keys(model.severityOverrides).forEach(function (t) {
            if (model.severityOverrides[t]) sev[t] = model.severityOverrides[t];
        });
        if (Object.keys(sev).length) cfg.severityOverrides = sev; else delete cfg.severityOverrides;
        if (model.quiet && model.quiet.enabled) {
            cfg.quietHours = { start: model.quiet.start, end: model.quiet.end, timezone: model.quiet.timezone };
        } else {
            delete cfg.quietHours;
        }
        return cfg;
    }

    /** Order-insensitive fingerprint used for the dirty indicator. */
    function snapshot(model) {
        var r = {};
        Object.keys(model.routes).sort().forEach(function (t) {
            r[t] = Array.isArray(model.routes[t]) ? model.routes[t].slice().sort() : model.routes[t];
        });
        var s = {};
        Object.keys(model.severityOverrides).sort().forEach(function (t) {
            if (model.severityOverrides[t]) s[t] = model.severityOverrides[t];
        });
        var q = model.quiet && model.quiet.enabled
            ? { start: model.quiet.start, end: model.quiet.end, timezone: model.quiet.timezone }
            : null;
        return JSON.stringify({ r: r, s: s, q: q });
    }

    /** Toggle a route in place. Returns the new on/off state. */
    function toggleRoute(model, typeId, connId, baseRoutes) {
        var list = Array.isArray(model.routes[typeId]) ? model.routes[typeId].slice() : [];
        var i = list.indexOf(connId);
        var on;
        if (i === -1) { list.push(connId); on = true; } else { list.splice(i, 1); on = false; }
        if (list.length === 0 && !(baseRoutes && has(baseRoutes, typeId))) {
            delete model.routes[typeId];
        } else {
            model.routes[typeId] = list;
        }
        return on;
    }

    /** Connection ids referenced by routes that FM did not return. */
    function unknownConnectionIds(routes, knownIds) {
        var seen = {};
        var out = [];
        Object.keys(routes).forEach(function (t) {
            (Array.isArray(routes[t]) ? routes[t] : []).forEach(function (id) {
                if (knownIds.indexOf(id) === -1 && !seen[id]) { seen[id] = true; out.push(id); }
            });
        });
        return out.sort();
    }

    function effectiveSeverity(entry, overrides) {
        if (entry && overrides && overrides[entry.id]) return overrides[entry.id];
        return entry ? entry.defaultSeverity : undefined;
    }

    /**
     * Turn a /api/notify-config/test response into a display model.
     * level: ok | warn | suppressed | error.
     */
    function classifyTestResult(resp, labelFor) {
        labelFor = labelFor || function (id) { return id; };
        var out = { level: 'error', headline: '', lines: [], warnings: [] };
        if (!isObj(resp)) { out.headline = 'No response from the LCARS server.'; return out; }
        var result = isObj(resp.result) ? resp.result : {};
        var receipts = Array.isArray(result.receipts) ? result.receipts : [];
        if (Array.isArray(result.warnings)) {
            result.warnings.forEach(function (w) { if (w) out.warnings.push(String(w)); });
        }
        if (resp.warning) out.warnings.push(String(resp.warning));

        receipts.forEach(function (r) {
            if (!isObj(r)) return;
            var line = { label: labelFor(r.connectionId), provider: r.provider || '' };
            if (r.suppressed) {
                line.status = 'suppressed';
                line.detail = has(SUPPRESS_REASONS, r.suppressed) ? SUPPRESS_REASONS[r.suppressed] : String(r.suppressed);
            } else if (r.ok) {
                line.status = 'delivered';
                line.detail = r.stage === 'accepted' ? 'accepted by provider' : '';
            } else {
                line.status = 'failed';
                line.detail = r.error ? String(r.error) : 'delivery failed';
            }
            out.lines.push(line);
        });

        var delivered = out.lines.filter(function (l) { return l.status === 'delivered'; }).length;
        var failed = out.lines.filter(function (l) { return l.status === 'failed'; }).length;
        var suppressed = out.lines.filter(function (l) { return l.status === 'suppressed'; }).length;

        if (resp.ok === true) {
            if (resp.deliveredVia === 'none') {
                out.level = 'suppressed';
                out.headline = 'Suppressed: nothing was sent (' + (suppressed ? 'see receipts below' : 'quiet hours, dedupe or severity gate') + ').';
            } else if (failed > 0 || resp.warning) {
                out.level = 'warn';
                out.headline = 'Partial delivery: ' + (out.lines.length
                    ? delivered + ' of ' + out.lines.length + ' connection(s) delivered.'
                    : 'Fleet Monitor reported a problem after delivering.');
            } else {
                out.level = 'ok';
                out.headline = 'Delivered via Fleet Monitor to ' + delivered + ' connection(s).';
            }
            return out;
        }

        if (resp.error) {
            out.level = 'error';
            out.headline = errorMessage(resp.error, resp.message);
            return out;
        }
        if (result.routed === false) {
            out.level = 'warn';
            out.headline = 'Not sent: ' + (result.reason === 'route-nowhere'
                ? 'this type is routed nowhere in the pushed routes.'
                : 'no route is pushed for this type.');
            return out;
        }
        if (suppressed > 0 && delivered === 0 && failed === 0) {
            out.level = 'suppressed';
            out.headline = 'Suppressed: nothing was sent (see receipts below).';
            return out;
        }
        out.level = 'error';
        out.headline = 'Delivery failed on every connection.';
        return out;
    }

    // ---------------------------------------------------------------------
    // DOM helpers
    // ---------------------------------------------------------------------
    function makeH(doc) {
        return function h(tag, attrs, kids) {
            var el = doc.createElement(tag);
            if (attrs) {
                Object.keys(attrs).forEach(function (k) {
                    var v = attrs[k];
                    if (v === undefined || v === null || v === false) return;
                    if (k === 'text') el.textContent = v;
                    else if (k === 'class') el.className = v;
                    else el.setAttribute(k, v === true ? '' : String(v));
                });
            }
            (kids || []).forEach(function (c) {
                if (c === null || c === undefined) return;
                el.appendChild(typeof c === 'string' ? doc.createTextNode(c) : c);
            });
            return el;
        };
    }

    // ---------------------------------------------------------------------
    // Panel controller
    // ---------------------------------------------------------------------
    function createPanel(opts) {
        opts = opts || {};
        var root = opts.root;
        var doc = root.ownerDocument;
        var h = makeH(doc);
        var doConfirm = opts.confirm || function (m) { return global.confirm(m); };
        var doFetch = opts.fetch || function () { return (global.apiFetch || global.fetch).apply(global, arguments); };
        var urlFor = opts.apiUrl || function (path, params) {
            if (typeof global.apiUrl === 'function') return global.apiUrl(path, params);
            if (!params) return path;
            var qs = Object.keys(params).map(function (k) {
                return encodeURIComponent(k) + '=' + encodeURIComponent(params[k]);
            }).join('&');
            return path + '?' + qs;
        };
        function getTeam() {
            if (opts.team) return opts.team;
            try { if (typeof CONFIG !== 'undefined' && CONFIG && CONFIG.team) return CONFIG.team; } catch (e) { /* none */ }
            return '';
        }

        var S = {
            status: 'idle',          // idle | loading | ready | error
            loadToken: 0,
            loadError: null,
            team: '',
            exists: false,
            sourceVersion: null,
            catalog: [],
            severities: ['info', 'warning', 'high', 'critical'],
            baseConfig: null,        // loaded v2 object, or a fresh skeleton
            baseRoutes: {},
            model: modelFromConfig(null),
            savedSnapshot: '',
            savedOverrides: {},
            conn: { list: [], error: null, loaded: false },
            saving: false,
            saveResult: null,        // {kind, message, details[]}
            pushResult: null,        // {kind, message}
            quietErrors: {},
            tests: {},               // typeId -> {pending, view}
            focusAfterRender: null
        };

        // ---- skeleton (built once) --------------------------------------
        var el = {};
        function buildSkeleton() {
            root.textContent = '';
            el.panel = h('div', { class: 'notif-panel' });
            el.banner = h('div', { class: 'notif-banner-slot' });
            el.dirty = h('span', { class: 'notif-dirty', role: 'status', 'aria-live': 'polite' });
            el.teamLabel = h('span', { class: 'notif-team' });
            el.saveBtn = h('button', { type: 'button', class: 'notif-btn notif-btn-primary', text: 'SAVE & PUSH' });
            el.revertBtn = h('button', { type: 'button', class: 'notif-btn', text: 'REVERT' });
            el.reloadBtn = h('button', { type: 'button', class: 'notif-btn', text: 'RELOAD' });
            el.bar = h('div', { class: 'notif-statusbar' }, [
                el.teamLabel, el.dirty,
                h('span', { class: 'notif-bar-spacer' }),
                el.reloadBtn, el.revertBtn, el.saveBtn
            ]);
            el.connNote = h('div', { class: 'notif-conn-note', role: 'status' });
            el.matrixScroll = h('div', {
                class: 'notif-matrix-scroll', role: 'region', tabindex: '0',
                'aria-label': 'Notice type routing matrix. Scroll horizontally for more connections.'
            });
            el.testNote = h('p', { class: 'notif-hint' });
            el.quiet = buildQuietFieldset();
            el.result = h('div', { class: 'notif-result', 'aria-live': 'polite' });
            el.panel.appendChild(el.banner);
            el.panel.appendChild(el.bar);
            el.panel.appendChild(el.connNote);
            el.panel.appendChild(el.matrixScroll);
            el.panel.appendChild(el.testNote);
            el.panel.appendChild(el.quiet);
            el.panel.appendChild(el.result);
            root.appendChild(el.panel);

            el.saveBtn.addEventListener('click', save);
            el.revertBtn.addEventListener('click', function () { discard(); renderAll(); });
            el.reloadBtn.addEventListener('click', function () {
                if (isDirty() && !doConfirm('Reload from disk and discard unsaved changes?')) return;
                load();
            });
        }

        function buildQuietFieldset() {
            el.qEnabled = h('input', { type: 'checkbox', id: 'notif-qh-enabled', class: 'notif-check' });
            el.qStart = h('input', { type: 'time', id: 'notif-qh-start', class: 'notif-input', 'aria-describedby': 'notif-qh-start-err' });
            el.qEnd = h('input', { type: 'time', id: 'notif-qh-end', class: 'notif-input', 'aria-describedby': 'notif-qh-end-err' });
            el.qTz = h('input', { type: 'text', id: 'notif-qh-tz', class: 'notif-input notif-input-wide', list: 'notif-tz-list', autocomplete: 'off', 'aria-describedby': 'notif-qh-tz-err' });
            el.qStartErr = h('span', { class: 'notif-field-err', id: 'notif-qh-start-err', role: 'alert' });
            el.qEndErr = h('span', { class: 'notif-field-err', id: 'notif-qh-end-err', role: 'alert' });
            el.qTzErr = h('span', { class: 'notif-field-err', id: 'notif-qh-tz-err', role: 'alert' });
            var dl = h('datalist', { id: 'notif-tz-list' });
            try {
                if (typeof Intl.supportedValuesOf === 'function') {
                    Intl.supportedValuesOf('timeZone').forEach(function (z) { dl.appendChild(h('option', { value: z })); });
                }
            } catch (e) { /* free text still works */ }
            el.qFields = h('div', { class: 'notif-qh-fields' }, [
                h('label', { for: 'notif-qh-start', text: 'Start' }), el.qStart, el.qStartErr,
                h('label', { for: 'notif-qh-end', text: 'End' }), el.qEnd, el.qEndErr,
                h('label', { for: 'notif-qh-tz', text: 'Time zone' }), el.qTz, el.qTzErr, dl
            ]);
            var fs = h('fieldset', { class: 'notif-quiet' }, [
                h('legend', { text: 'QUIET HOURS' }),
                h('label', { class: 'notif-check-label', for: 'notif-qh-enabled' }, [el.qEnabled, ' Enable quiet hours']),
                h('p', { class: 'notif-hint', text: 'Notices below critical are held inside [start, end) in the chosen zone; the window may span midnight. Critical notices always get through.' }),
                el.qFields
            ]);
            el.qEnabled.addEventListener('change', function () { S.model.quiet.enabled = el.qEnabled.checked; onModelChanged(); syncQuiet(); });
            el.qStart.addEventListener('input', function () { S.model.quiet.start = el.qStart.value; onModelChanged(); showQuietErrors(); });
            el.qEnd.addEventListener('input', function () { S.model.quiet.end = el.qEnd.value; onModelChanged(); showQuietErrors(); });
            el.qTz.addEventListener('input', function () { S.model.quiet.timezone = el.qTz.value.trim(); onModelChanged(); showQuietErrors(); });
            return fs;
        }

        function syncQuiet() {
            var q = S.model.quiet;
            el.qEnabled.checked = !!q.enabled;
            el.qStart.value = q.start || '';
            el.qEnd.value = q.end || '';
            el.qTz.value = q.timezone || '';
            el.qFields.style.display = q.enabled ? '' : 'none';
            showQuietErrors();
        }

        function showQuietErrors() {
            S.quietErrors = validateQuietHours(S.model.quiet);
            [['start', el.qStart, el.qStartErr], ['end', el.qEnd, el.qEndErr], ['timezone', el.qTz, el.qTzErr]].forEach(function (p) {
                var msg = S.quietErrors[p[0]] || '';
                p[2].textContent = msg;
                if (msg) p[1].setAttribute('aria-invalid', 'true'); else p[1].removeAttribute('aria-invalid');
            });
        }

        // ---- state helpers ----------------------------------------------
        function isDirty() {
            return S.status === 'ready' && snapshot(S.model) !== S.savedSnapshot;
        }

        function commitBaseline() {
            S.savedSnapshot = snapshot(S.model);
            S.savedOverrides = clone(S.model.severityOverrides);
            S.baseRoutes = clone(S.model.routes);
        }

        function discard() {
            if (S.status !== 'ready') return;
            S.model = modelFromConfig(S.baseConfig);
            S.saveResult = null;
            S.pushResult = null;
        }

        function onModelChanged() {
            S.saveResult = null;
            S.pushResult = null;
            updateChrome();
        }

        function updateChrome() {
            var dirty = isDirty();
            el.dirty.textContent = S.status !== 'ready' ? '' : (dirty ? 'UNSAVED CHANGES' : 'ALL CHANGES SAVED');
            el.dirty.setAttribute('data-dirty', dirty ? 'true' : 'false');
            var upgrade = S.status === 'ready' && (S.sourceVersion === 1 || !S.exists);
            el.saveBtn.disabled = S.status !== 'ready' || S.saving || !(dirty || upgrade);
            el.revertBtn.disabled = S.status !== 'ready' || !dirty || S.saving;
            el.saveBtn.textContent = S.saving ? 'SAVING...' : 'SAVE & PUSH';
            renderResult();
            renderTestNote();
        }

        // ---- network ----------------------------------------------------
        function readJson(res) {
            return res.json().catch(function () { return null; }).then(function (body) {
                return { status: res.status, ok: res.ok, body: body };
            });
        }

        function load() {
            var team = getTeam();
            S.team = team;
            var token = ++S.loadToken;
            S.status = 'loading';
            S.loadError = null;
            S.tests = {};
            S.saveResult = null;
            S.pushResult = null;
            renderAll();
            if (!team) {
                S.status = 'error';
                S.loadError = 'Team not resolved. Reload the page.';
                renderAll();
                return Promise.resolve();
            }
            var pConfig = doFetch(urlFor('/api/notify-config', { team: team }), { method: 'GET' })
                .then(readJson)
                .catch(function () { return { status: 0, ok: false, body: null }; });
            var pConn = doFetch(urlFor('/api/notify-config/connections', { team: team }), { method: 'GET' })
                .then(readJson)
                .catch(function () { return { status: 0, ok: false, body: { error: 'fm-unreachable' } }; });
            return Promise.all([pConfig, pConn]).then(function (rs) {
                if (token !== S.loadToken) return;   // a newer load superseded this one
                var cfg = rs[0], cn = rs[1];
                if (!cfg.ok || !cfg.body || cfg.body.error || !Array.isArray(cfg.body.catalog)) {
                    S.status = 'error';
                    var b = cfg.body || {};
                    S.loadError = cfg.status === 0
                        ? 'Could not reach the LCARS server.'
                        : errorMessage(b.error, b.message || ('Could not load notification settings (HTTP ' + cfg.status + ').'));
                    renderAll();
                    return;
                }
                var body = cfg.body;
                S.exists = !!body.exists;
                S.sourceVersion = body.sourceVersion === undefined ? null : body.sourceVersion;
                S.catalog = body.catalog;
                S.severities = Array.isArray(body.severities) && body.severities.length ? body.severities : S.severities;
                S.baseConfig = isObj(body.config) ? clone(body.config) : { $schema: 'release-notify/v2', version: 2, routes: {} };
                S.model = modelFromConfig(isObj(body.config) ? body.config : null);
                commitBaseline();
                var cb = cn.body || {};
                if (cn.ok && Array.isArray(cb.connections) && !cb.error) {
                    S.conn = { list: cb.connections, error: null, loaded: true };
                } else {
                    S.conn = {
                        list: [], loaded: false,
                        error: { code: cb.error || 'fm-error', message: errorMessage(cb.error || 'fm-error', cb.message) }
                    };
                }
                S.status = 'ready';
                renderAll();
            });
        }

        function save() {
            if (S.status !== 'ready' || S.saving) return;
            showQuietErrors();
            if (Object.keys(S.quietErrors).length) {
                S.saveResult = { kind: 'error', message: 'Fix the quiet hours fields before saving.', details: [] };
                S.pushResult = null;
                updateChrome();
                var first = !S.quietErrors.start ? (!S.quietErrors.end ? el.qTz : el.qEnd) : el.qStart;
                if (first && first.focus) first.focus();
                return;
            }
            var config = buildConfig(S.baseConfig, S.model);
            S.saving = true;
            S.saveResult = null;
            S.pushResult = null;
            updateChrome();
            doFetch(urlFor('/api/notify-config'), {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ team: S.team, config: config })
            }).then(readJson).catch(function () {
                return { status: 0, ok: false, body: null };
            }).then(function (r) {
                S.saving = false;
                var b = r.body || {};
                if (r.status === 0) {
                    S.saveResult = { kind: 'error', message: 'Could not reach the LCARS server. Nothing was saved.', details: [] };
                } else if (b.saved === true) {
                    S.baseConfig = clone(config);
                    S.sourceVersion = 2;
                    S.exists = true;
                    commitBaseline();
                    S.saveResult = { kind: 'ok', message: 'Saved.', details: [] };
                    renderBanner();
                    S.pushResult = pushView(b.push);
                } else {
                    var details = Array.isArray(b.details) ? b.details.map(String) : [];
                    S.saveResult = {
                        kind: 'error',
                        message: 'Not saved: ' + errorMessage(b.error, b.message || ('HTTP ' + r.status)) + '.',
                        details: details
                    };
                }
                updateChrome();
            });
        }

        function pushView(push) {
            if (!isObj(push)) {
                return { kind: 'warn', message: 'Saved, but the route push status was not reported.' };
            }
            if (push.ok === true) {
                if (push.action === 'skipped') {
                    return { kind: 'info', message: 'Routes already current on Fleet Monitor (push skipped' + (push.reason ? ': ' + push.reason : '') + ').' };
                }
                return { kind: 'ok', message: 'Routes pushed to Fleet Monitor.' };
            }
            return {
                kind: 'warn',
                message: 'Saved, but the route push failed: ' + errorMessage(push.error, push.message || 'push failed') +
                    '. The routes on Fleet Monitor are unchanged until a push succeeds.'
            };
        }

        function sendTest(typeId) {
            var t = S.tests[typeId];
            if (t && t.pending) return;
            S.tests[typeId] = { pending: true, view: null };
            renderMatrix();
            doFetch(urlFor('/api/notify-config/test'), {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ team: S.team, type: typeId })
            }).then(readJson).catch(function () {
                return { status: 0, ok: false, body: { ok: false, error: 'fm-unreachable', message: 'Could not reach the LCARS server.' } };
            }).then(function (r) {
                var body = r.body;
                if (!isObj(body)) body = { ok: false, error: 'fm-error', message: 'Unreadable response (HTTP ' + r.status + ').' };
                if (body.ok !== true && !body.error && !isObj(body.result)) body.error = 'fm-error';
                S.tests[typeId] = { pending: false, view: classifyTestResult(body, connLabel) };
                S.focusAfterRender = { test: typeId };
                renderMatrix();
            });
        }

        // ---- rendering --------------------------------------------------
        function connLabel(id) {
            for (var i = 0; i < S.conn.list.length; i++) {
                if (S.conn.list[i].id === id) return S.conn.list[i].label || id;
            }
            return id;
        }

        function renderAll() {
            el.teamLabel.textContent = S.team ? 'TEAM: ' + S.team.toUpperCase() : '';
            renderBanner();
            renderConnNote();
            renderMatrix();
            syncQuiet();
            updateChrome();
            el.quiet.style.display = S.status === 'ready' ? '' : 'none';
            el.bar.style.display = S.status === 'error' ? 'none' : '';
        }

        function renderBanner() {
            el.banner.textContent = '';
            if (S.status === 'loading') {
                el.banner.appendChild(h('div', { class: 'notif-msg notif-msg-info', role: 'status', text: 'Loading notification settings...' }));
            } else if (S.status === 'error') {
                var retry = h('button', { type: 'button', class: 'notif-btn', text: 'RETRY' });
                retry.addEventListener('click', load);
                el.banner.appendChild(h('div', { class: 'notif-msg notif-msg-error', role: 'alert' }, [
                    h('span', { text: S.loadError || 'Could not load notification settings.' }), ' ', retry
                ]));
            } else if (S.status === 'ready') {
                if (S.sourceVersion === 1) {
                    el.banner.appendChild(h('div', { class: 'notif-msg notif-msg-warn', 'data-notif': 'v1-notice', text:
                        'This team still uses the version 1 notify file. Saving upgrades it to version 2. Your existing aliases are kept.' }));
                } else if (!S.exists) {
                    el.banner.appendChild(h('div', { class: 'notif-msg notif-msg-info', 'data-notif': 'new-config', text:
                        'No notify configuration exists for this team yet. Saving creates one.' }));
                }
            }
        }

        function renderConnNote() {
            el.connNote.textContent = '';
            if (S.status !== 'ready') return;
            if (S.conn.error) {
                el.connNote.appendChild(h('div', { class: 'notif-msg notif-msg-warn', 'data-notif': 'conn-error', role: 'alert' }, [
                    h('strong', { text: 'Connections unavailable: ' }),
                    S.conn.error.message + '. ',
                    'Existing routes are kept as they are; you can still change severity and quiet hours, but routing cannot be edited until Fleet Monitor connections load.'
                ]));
            } else if (S.conn.list.length === 0) {
                el.connNote.appendChild(h('div', { class: 'notif-msg notif-msg-info', text:
                    'Fleet Monitor has no connections for this team yet. Add one on the Fleet Monitor Notification Connections screen.' }));
            }
        }

        function renderTestNote() {
            el.testNote.textContent = '';
            if (S.status !== 'ready') return;
            var text = 'SEND TEST sends a real notice through Fleet Monitor at the type\'s saved severity, so a high or critical type can page SMS. ' +
                'It uses the routes last pushed to Fleet Monitor.';
            if (isDirty()) text += ' You have unsaved changes: they are NOT used by the test. Save first.';
            el.testNote.textContent = text;
        }

        function renderResult() {
            el.result.textContent = '';
            if (S.saveResult) {
                var box = h('div', { class: 'notif-msg notif-msg-' + (S.saveResult.kind === 'ok' ? 'ok' : 'error'), 'data-notif': 'save-result', role: S.saveResult.kind === 'ok' ? 'status' : 'alert' }, [
                    h('span', { text: S.saveResult.message })
                ]);
                if (S.saveResult.details.length) {
                    var ul = h('ul', { class: 'notif-details' });
                    S.saveResult.details.forEach(function (d) { ul.appendChild(h('li', { text: d })); });
                    box.appendChild(ul);
                }
                el.result.appendChild(box);
            }
            if (S.pushResult) {
                el.result.appendChild(h('div', {
                    class: 'notif-msg notif-msg-' + (S.pushResult.kind === 'ok' ? 'ok' : (S.pushResult.kind === 'info' ? 'info' : 'warn')),
                    'data-notif': 'push-result', role: 'status', text: S.pushResult.message
                }));
            }
        }

        function renderMatrix() {
            var sc = el.matrixScroll;
            sc.textContent = '';
            sc.style.display = S.status === 'ready' ? '' : 'none';
            if (S.status !== 'ready') return;

            var known = S.conn.list.map(function (c) { return c.id; });
            var unknown = S.conn.loaded ? unknownConnectionIds(S.model.routes, known) : [];
            var cols = S.conn.list.map(function (c) { return { id: c.id, label: c.label || c.id, provider: c.provider, enabled: c.enabled !== false, unknown: false }; })
                .concat(unknown.map(function (id) { return { id: id, label: id, provider: 'unknown', enabled: true, unknown: true }; }));

            var table = h('table', { class: 'notif-matrix' });
            var thead = h('thead');
            var hr = h('tr');
            hr.appendChild(h('th', { scope: 'col', class: 'notif-col-type', text: 'NOTICE TYPE' }));
            hr.appendChild(h('th', { scope: 'col', class: 'notif-col-sev', text: 'SEVERITY' }));
            cols.forEach(function (c) {
                var th = h('th', { scope: 'col', class: 'notif-col-conn' + (c.enabled ? '' : ' notif-col-disabled') + (c.unknown ? ' notif-col-unknown' : ''), 'data-conn': c.id });
                th.appendChild(h('span', { class: 'notif-conn-label', text: c.label }));
                th.appendChild(h('span', { class: 'notif-conn-provider', text: c.provider }));
                if (!c.enabled) th.appendChild(h('span', { class: 'notif-conn-flag', text: 'DISABLED' }));
                if (c.unknown) {
                    th.appendChild(h('span', { class: 'notif-conn-flag notif-conn-warn', text: 'UNKNOWN CONNECTION' }));
                    var rm = h('button', { type: 'button', class: 'notif-btn notif-btn-small', 'data-remove-conn': c.id, 'aria-label': 'Remove unknown connection ' + c.id + ' from all routes', text: 'REMOVE' });
                    rm.addEventListener('click', function () { removeUnknown(c.id); });
                    th.appendChild(rm);
                }
                hr.appendChild(th);
            });
            hr.appendChild(h('th', { scope: 'col', class: 'notif-col-test', text: 'TEST' }));
            thead.appendChild(hr);
            table.appendChild(thead);

            var tbody = h('tbody');
            var span = 3 + cols.length;
            S.catalog.forEach(function (entry) {
                var tr = h('tr', { 'data-type': entry.id });
                var descId = 'notif-desc-' + entry.id;
                var th = h('th', { scope: 'row', class: 'notif-col-type', title: entry.description || '' }, [
                    h('span', { class: 'notif-type-label', text: entry.label || entry.id }),
                    h('span', { class: 'notif-type-id', text: entry.id }),
                    entry.description ? h('span', { class: 'notif-sr', id: descId, text: entry.description }) : null
                ]);
                tr.appendChild(th);

                // severity override select
                var sel = h('select', { class: 'notif-select', 'data-sev-for': entry.id, 'aria-label': 'Severity for ' + (entry.label || entry.id) });
                sel.appendChild(h('option', { value: '', text: 'Catalog default (' + entry.defaultSeverity + ')' }));
                S.severities.forEach(function (sv) { sel.appendChild(h('option', { value: sv, text: sv })); });
                sel.value = S.model.severityOverrides[entry.id] || '';
                sel.addEventListener('change', function () {
                    if (sel.value) S.model.severityOverrides[entry.id] = sel.value;
                    else delete S.model.severityOverrides[entry.id];
                    onModelChanged();
                });
                tr.appendChild(h('td', { class: 'notif-col-sev' }, [sel]));

                cols.forEach(function (c) {
                    var routed = Array.isArray(S.model.routes[entry.id]) && S.model.routes[entry.id].indexOf(c.id) !== -1;
                    var btn = h('button', {
                        type: 'button', class: 'notif-toggle' + (routed ? ' on' : ''),
                        'data-type': entry.id, 'data-conn': c.id,
                        'aria-pressed': routed ? 'true' : 'false',
                        'aria-label': 'Route ' + (entry.label || entry.id) + ' to ' + c.label,
                        text: routed ? 'ON' : 'OFF'
                    });
                    btn.addEventListener('click', function () {
                        var on = toggleRoute(S.model, entry.id, c.id, S.baseRoutes);
                        btn.setAttribute('aria-pressed', on ? 'true' : 'false');
                        btn.classList.toggle('on', on);
                        btn.textContent = on ? 'ON' : 'OFF';
                        onModelChanged();
                    });
                    tr.appendChild(h('td', { class: 'notif-col-conn' + (c.enabled ? '' : ' notif-col-disabled') }, [btn]));
                });

                var t = S.tests[entry.id] || {};
                var sendBtn = h('button', {
                    type: 'button', class: 'notif-btn notif-btn-small', 'data-test-for': entry.id,
                    'aria-label': 'Send test notice for ' + (entry.label || entry.id),
                    text: t.pending ? 'SENDING...' : 'SEND TEST'
                });
                if (t.pending) sendBtn.disabled = true;
                sendBtn.addEventListener('click', function () { sendTest(entry.id); });
                tr.appendChild(h('td', { class: 'notif-col-test' }, [sendBtn]));
                tbody.appendChild(tr);

                if (t.view || t.pending) {
                    var rtd = h('td', { colspan: String(span) });
                    rtd.appendChild(t.pending
                        ? h('div', { class: 'notif-msg notif-msg-info', role: 'status', text: 'Sending test notice...' })
                        : receiptNode(entry.id, t.view));
                    tbody.appendChild(h('tr', { class: 'notif-receipt-row', 'data-receipt-for': entry.id }, [rtd]));
                }
            });
            table.appendChild(tbody);
            sc.appendChild(table);

            if (S.catalog.length === 0) {
                sc.appendChild(h('p', { class: 'notif-hint', text: 'No notice types are defined in the catalog.' }));
            }
            if (cols.some(function (c) { return !c.enabled; })) {
                sc.appendChild(h('p', { class: 'notif-hint', 'data-notif': 'disabled-note', text:
                    'Dimmed columns are disabled connections. You can still route to them, but Fleet Monitor will not deliver until they are enabled.' }));
            }
            var orphanTypes = Object.keys(S.model.routes).filter(function (t) {
                return !S.catalog.some(function (e) { return e.id === t; });
            });
            if (orphanTypes.length) {
                sc.appendChild(h('p', { class: 'notif-hint', 'data-notif': 'orphan-types', text:
                    'Routes for notice types not in the catalog (' + orphanTypes.join(', ') + ') are kept unchanged.' }));
            }

            if (S.focusAfterRender && S.focusAfterRender.test) {
                var b = sc.querySelector('[data-test-for="' + S.focusAfterRender.test + '"]');
                if (b && b.focus) b.focus();
                S.focusAfterRender = null;
            }
        }

        function receiptNode(typeId, view) {
            var box = h('div', { class: 'notif-msg notif-receipt notif-msg-' + (view.level === 'ok' ? 'ok' : (view.level === 'error' ? 'error' : (view.level === 'suppressed' ? 'info' : 'warn'))), 'data-receipt-level': view.level, role: 'status' });
            box.appendChild(h('strong', { text: view.headline }));
            if (view.lines.length) {
                var ul = h('ul', { class: 'notif-details' });
                view.lines.forEach(function (l) {
                    ul.appendChild(h('li', { 'data-receipt-status': l.status, text:
                        l.label + (l.provider ? ' (' + l.provider + ')' : '') + ': ' + l.status + (l.detail ? ' - ' + l.detail : '') }));
                });
                box.appendChild(ul);
            }
            view.warnings.forEach(function (w) {
                box.appendChild(h('div', { class: 'notif-receipt-warning', text: 'Warning: ' + w }));
            });
            return box;
        }

        function removeUnknown(id) {
            Object.keys(S.model.routes).forEach(function (t) {
                if (Array.isArray(S.model.routes[t])) {
                    S.model.routes[t] = S.model.routes[t].filter(function (x) { return x !== id; });
                }
            });
            onModelChanged();
            renderMatrix();
            el.matrixScroll.focus();
        }

        // ---- public API -------------------------------------------------
        buildSkeleton();
        renderAll();

        return {
            load: load,
            isDirty: isDirty,
            discard: function () { discard(); renderAll(); },
            canLeave: function () {
                if (!isDirty()) return true;
                if (doConfirm('You have unsaved Notifications changes. Leave and discard them?')) {
                    discard(); renderAll();
                    return true;
                }
                return false;
            },
            save: save,
            _state: S
        };
    }

    // ---------------------------------------------------------------------
    // Browser wiring
    // ---------------------------------------------------------------------
    var api = {
        ERROR_MESSAGES: ERROR_MESSAGES,
        errorMessage: errorMessage,
        validateQuietHours: validateQuietHours,
        modelFromConfig: modelFromConfig,
        buildConfig: buildConfig,
        snapshot: snapshot,
        toggleRoute: toggleRoute,
        unknownConnectionIds: unknownConnectionIds,
        effectiveSeverity: effectiveSeverity,
        classifyTestResult: classifyTestResult,
        createPanel: createPanel
    };

    var panel = null;
    function ensurePanel() {
        if (panel) return panel;
        var root = global.document && global.document.getElementById('notifications-root');
        if (!root) return null;
        panel = createPanel({ root: root });
        return panel;
    }

    api.onSectionShown = function () {
        var p = ensurePanel();
        if (p) p.load();
    };
    api.canLeave = function () {
        return panel ? panel.canLeave() : true;
    };
    api.isDirty = function () {
        return panel ? panel.isDirty() : false;
    };

    if (typeof module !== 'undefined' && module.exports) module.exports = api;
    if (global) {
        global.lcarsNotifications = api;
        if (global.addEventListener) {
            global.addEventListener('beforeunload', function (e) {
                if (panel && panel.isDirty()) { e.preventDefault(); e.returnValue = ''; }
            });
        }
    }

})(typeof window !== 'undefined' ? window : (typeof globalThis !== 'undefined' ? globalThis : this));
