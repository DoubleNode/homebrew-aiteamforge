//
//  lcars-notify-connections.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

// === XACA-1405: NOTIFICATION CONNECTIONS section (EPIC-0068 hub, operator side) ===
//
// Lists, creates, edits, tests and deletes the operator's notification
// connections (Teams / Slack / Email / Pushover / ntfy / SMS-iMessage) through
// the admin-tier /api/notify/* routes (XACA-1400) and shows each connection's
// last delivery (from /api/notify/receipts).
//
// Rules this file lives by:
//   1. SECRETS ARE WRITE-ONLY. The server only ever says a secret field is
//      'set'. This file renders the fixed words "set" / "not set" (never the
//      server's string), never prefills a secret input, uses type=password +
//      autocomplete=off, and empties every secret input as soon as a request
//      resolves. On edit a blank secret is OMITTED from the PUT body, which the
//      store reads as "keep the stored value"; an explicit CLEAR sends null.
//   2. ESCAPE EVERYTHING that came from the server or the operator (labels,
//      params, ids, error text). Every dynamic value goes through esc() or
//      textContent (EPIC-0023).
//   3. ALL calls go through window.fleetApiFetch. It only prompts to unlock on a
//      401 from a MUTATING call, so a 401 on a GET renders a LOCKED state with
//      an UNLOCK button (FleetApiAuth.unlock) instead of failing silently.
//   4. Poll only while the section is visible. The poll rebuilds the status line
//      and the list, never the open form, so typing is never clobbered.
//   5. NEVER THROW out of refresh()/render().

(function() {
    'use strict';

    var API = '/api/notify';
    var SECTION = 'notifications';
    var POLL_MS = 15000;
    var RECEIPT_LIMIT = 200;
    var DASH = '—';
    var ID_RE = /^[a-z][a-z0-9-]{0,31}$/;
    var SEVERITIES = ['info', 'warning', 'high', 'critical'];

    // Client-side mirror of each provider's paramFields/secretFields and validate()
    // (lib/notify-providers/*.js). These tables are NOT exposed over HTTP, so the UI
    // carries its own; the server stays the authority and its 400 text is shown inline.
    // kind: text | number | select | list.  required: must be non-empty.
    var PROVIDERS = {
        teams: {
            label: 'Teams',
            params: [{ name: 'shape', label: 'Shape', kind: 'select', options: ['flow', 'webhook'], def: 'flow' }],
            secrets: [{ name: 'webhookUrl', label: 'Webhook URL', required: true }]
        },
        slack: {
            label: 'Slack',
            params: [],
            secrets: [{ name: 'webhookUrl', label: 'Webhook URL', required: true }]
        },
        email: {
            label: 'Email (SMTP)',
            params: [
                { name: 'host', label: 'SMTP host', kind: 'text', required: true },
                { name: 'port', label: 'Port', kind: 'number', required: true, def: '587' },
                { name: 'from', label: 'From address', kind: 'text', required: true },
                { name: 'to', label: 'To (comma separated, up to 20)', kind: 'text', required: true },
                { name: 'secure', label: 'TLS mode', kind: 'select', options: ['starttls', 'implicit'], def: 'starttls' }
            ],
            secrets: [
                { name: 'user', label: 'SMTP user (with password, or neither)' },
                { name: 'pass', label: 'SMTP password (with user, or neither)' }
            ]
        },
        pushover: {
            label: 'Pushover',
            params: [{ name: 'device', label: 'Device (optional, comma separated)', kind: 'text' }],
            secrets: [
                { name: 'appToken', label: 'App token', required: true },
                { name: 'userKey', label: 'User key', required: true }
            ]
        },
        ntfy: {
            label: 'ntfy',
            params: [{ name: 'server', label: 'Server (https, blank = ntfy.sh)', kind: 'text' }],
            secrets: [
                { name: 'topic', label: 'Topic', required: true },
                { name: 'token', label: 'Access token (optional)' }
            ]
        },
        imessage: {
            label: 'SMS / iMessage',
            params: [
                { name: 'recipient', label: 'Recipient (+E.164 number or Apple ID email)', kind: 'text', required: true },
                { name: 'minSeverity', label: 'Minimum severity', kind: 'select', options: SEVERITIES, def: 'high' },
                { name: 'pool', label: 'Sender pool machine ids (optional, comma separated, up to 32)', kind: 'list' }
            ],
            secrets: []
        }
    };
    var PROVIDER_ORDER = ['teams', 'slack', 'email', 'pushover', 'ntfy', 'imessage'];

    // =========================================================================
    // STATE
    // =========================================================================

    var _view = 'loading';       // loading | locked | disabled | error | ready
    var _reason = '';
    var _recovered = null;
    var _providers = [];         // provider names the server registered
    var _conns = [];
    var _receipts = [];
    var _receiptsOk = true;
    var _updateFailed = false;
    var _form = null;            // open add/edit form, or null
    var _confirm = {};           // connection id -> 'delete' | 'send'
    var _results = {};           // connection id -> { ok, text }
    var _busy = false;           // a write is in flight: the poll must not rebuild under it
    var _inflight = null;
    var _stale = false;          // a write landed while a refresh was in flight: that refresh's data predates it
    var _timer = null;
    var _focusAfterDelete = null;
    var _pendingOpen = null;     // action waiting on the "Discard unsaved changes?" answer

    // =========================================================================
    // HELPERS (pure)
    // =========================================================================

    function esc(v) {
        if (v === null || v === undefined) return '';
        return String(v)
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;')
            .replace(/'/g, '&#39;');
    }

    function $(id) { return document.getElementById(id); }

    function isObj(v) { return v !== null && typeof v === 'object' && !Array.isArray(v); }

    function providerLabel(name) {
        return PROVIDERS[name] ? PROVIDERS[name].label : String(name);
    }

    function paramText(v) {
        if (Array.isArray(v)) return v.join(', ');
        if (v === null || v === undefined) return '';
        if (typeof v === 'object') return '';
        return String(v);
    }

    function ago(iso) {
        var t = Date.parse(iso);
        if (isNaN(t)) return DASH;
        var s = Math.floor((Date.now() - t) / 1000);
        if (s < 45) return 'just now';
        if (s < 3600) return Math.round(s / 60) + 'm ago';
        if (s < 86400) return Math.round(s / 3600) + 'h ago';
        return Math.round(s / 86400) + 'd ago';
    }

    // Newest receipt per connection id. For an async-delivery provider (imessage) the
    // 'accepted' receipt and the later 'delivered'/'failed' receipt share a
    // providerMessageId; prefer the settled one over the acceptance stub.
    function lastDeliveryMap(receipts) {
        var newest = {};
        var list = Array.isArray(receipts) ? receipts : [];
        list.forEach(function(r) {
            if (!isObj(r) || typeof r.connectionId !== 'string') return;
            var t = Date.parse(r.ts);
            var cur = newest[r.connectionId];
            if (!cur || (!isNaN(t) && (isNaN(cur.t) || t > cur.t))) newest[r.connectionId] = { r: r, t: t };
        });
        var out = {};
        Object.keys(newest).forEach(function(id) {
            var pick = newest[id].r;
            if (pick.stage === 'accepted' && typeof pick.providerMessageId === 'string' && pick.providerMessageId) {
                list.forEach(function(o) {
                    if (isObj(o) && o.connectionId === id && o.providerMessageId === pick.providerMessageId &&
                        (o.stage === 'delivered' || o.stage === 'failed')) pick = o;
                });
            }
            out[id] = pick;
        });
        return out;
    }

    function deliveryHtml(r) {
        if (!r) return '<span class="notify-muted">no deliveries yet</span>';
        var cls, text;
        if (typeof r.suppressed === 'string' && r.suppressed) {
            cls = 'suppressed';
            text = 'SUPPRESSED (' + r.suppressed + ')';
        } else if (r.ok === true && r.stage === 'accepted') {
            cls = 'pending';
            text = 'ACCEPTED, AWAITING RELAY';
        } else if (r.ok === true) {
            cls = 'ok';
            text = 'DELIVERED';
        } else {
            cls = 'failed';
            text = 'FAILED';
        }
        var err = (r.ok !== true && !r.suppressed && r.error) ? ' <span class="notify-delivery-error">' + esc(String(r.error).slice(0, 160)) + '</span>' : '';
        var test = r.type === 'test' ? ' <span class="notify-muted">(test)</span>' : '';
        return '<span class="notify-delivery notify-delivery-' + cls + '">' + esc(text) + '</span>' + test + err +
            ' <time class="notify-muted" title="' + esc(r.ts) + '">' + esc(ago(r.ts)) + '</time>';
    }

    function paramsHtml(c) {
        var params = isObj(c.params) ? c.params : {};
        var parts = Object.keys(params).map(function(k) {
            var v = paramText(params[k]);
            return v === '' ? '' : '<span class="notify-param"><span class="notify-param-key">' + esc(k) + '</span> ' + esc(v) + '</span>';
        }).filter(Boolean);
        return parts.length ? parts.join('') : '<span class="notify-muted">' + DASH + '</span>';
    }

    // Fixed words only: the server's value is compared, never rendered.
    function secretsHtml(c) {
        var held = isObj(c.secrets) ? c.secrets : {};
        var names = PROVIDERS[c.provider] ? PROVIDERS[c.provider].secrets.map(function(s) { return s.name; }) : Object.keys(held);
        if (!names.length) return '<span class="notify-muted">none</span>';
        return names.map(function(n) {
            var isSet = held[n] === 'set';
            return '<span class="notify-secret notify-secret-' + (isSet ? 'set' : 'unset') + '">' + esc(n) + ': ' + (isSet ? 'set' : 'not set') + '</span>';
        }).join('');
    }

    // WCAG 2.5.3 Label-in-Name: every aria-label below STARTS with the button's visible words
    // (the decorative leading "+" of "+ ADD CONNECTION" is not a word), so a voice-control user
    // saying what they see activates the button. tests/xaca-1405-r1-gate-jsdom.test.js pins it.
    function btn(act, id, label, cls, aria) {
        return '<button type="button" class="btn-lcars ' + cls + ' notify-btn" data-act="' + act + '" data-id="' + esc(id) +
            '" aria-label="' + esc(aria) + '">' + esc(label) + '</button>';
    }

    function actionsHtml(c) {
        var id = c.id;
        var name = c.label;
        var mode = _confirm[id];
        var res = _results[id];
        var resHtml = res ? '<div class="notify-result notify-result-' + (res.ok ? 'ok' : 'fail') + '" role="status">' + esc(res.text) + '</div>' : '';
        if (mode === 'delete') {
            return '<div class="notify-confirm">Delete connection <strong>' + esc(name) + '</strong>? This cannot be undone.</div>' +
                btn('delete-confirm', id, 'CONFIRM DELETE', 'btn-lcars-danger', 'Confirm delete of ' + name) +
                btn('cancel', id, 'CANCEL', 'btn-lcars-secondary', 'Cancel delete of ' + name) + resHtml;
        }
        if (mode === 'send') {
            return '<div class="notify-confirm">Send a REAL test notification through <strong>' + esc(name) + '</strong>?</div>' +
                btn('send-confirm', id, 'CONFIRM SEND', 'btn-lcars-primary', 'Confirm send: ' + name) +
                btn('cancel', id, 'CANCEL', 'btn-lcars-secondary', 'Cancel send: ' + name) + resHtml;
        }
        return btn('edit', id, 'EDIT', 'btn-lcars-secondary', 'Edit ' + name) +
            btn('test', id, 'VALIDATE', 'btn-lcars-secondary', 'Validate: ' + name) +
            btn('send', id, 'SEND TEST', 'btn-lcars-primary', 'Send test: ' + name) +
            btn('delete', id, 'DELETE', 'btn-lcars-danger', 'Delete ' + name) + resHtml;
    }

    function rowHtml(c, last) {
        return '<tr data-id="' + esc(c.id) + '">' +
            '<td data-label="Label" class="notify-label">' + esc(c.label) + '</td>' +
            '<td data-label="Provider">' + esc(providerLabel(c.provider)) + '</td>' +
            '<td data-label="Id"><code>' + esc(c.id) + '</code></td>' +
            '<td data-label="Parameters">' + paramsHtml(c) + '</td>' +
            '<td data-label="Secrets">' + secretsHtml(c) + '</td>' +
            '<td data-label="Last delivery">' + deliveryHtml(last[c.id]) + '</td>' +
            '<td data-label="Actions" class="notify-actions">' + actionsHtml(c) + '</td>' +
            '</tr>';
    }

    // =========================================================================
    // NETWORK
    // =========================================================================

    function call(method, path, body) {
        var f = window.fleetApiFetch || window.fetch;
        var init = { method: method, credentials: 'same-origin' };
        if (body !== undefined) {
            init.headers = { 'Content-Type': 'application/json' };
            init.body = JSON.stringify(body);
        }
        return f(API + path, init).then(function(resp) {
            return Promise.resolve(resp.json()).catch(function() { return null; }).then(function(data) {
                return { status: resp.status, ok: !!resp.ok, data: data };
            });
        });
    }

    function errText(res, fallback) {
        var d = res && res.data;
        if (d && typeof d.message === 'string' && d.message) return d.message;
        if (d && typeof d.error === 'string' && d.error) return d.error;
        return fallback || ('HTTP ' + (res ? res.status : '?'));
    }

    // =========================================================================
    // RENDER
    // =========================================================================

    function liveRegion() { return $('notify-live'); }

    function announce(text) {
        var live = liveRegion();
        if (!live) return;
        live.textContent = '';
        live.textContent = text;
    }

    function captureFocus(container) {
        var a = document.activeElement;
        if (!a || !container.contains(a) || !a.getAttribute) return null;
        var act = a.getAttribute('data-act');
        var id = a.getAttribute('data-id');
        return act && id ? { act: act, id: id } : null;
    }

    function restoreFocus(container, f) {
        if (!f) return;
        var els = container.querySelectorAll('button[data-act]');
        for (var i = 0; i < els.length; i++) {
            if (els[i].getAttribute('data-act') === f.act && els[i].getAttribute('data-id') === f.id) { els[i].focus(); return; }
        }
        // The control that had focus is gone (e.g. EDIT replaced by confirm buttons): land on the row's first button.
        var row = container.querySelectorAll('tr[data-id]');
        for (var j = 0; j < row.length; j++) {
            if (row[j].getAttribute('data-id') === f.id) {
                var first = row[j].querySelector('button');
                if (first) first.focus();
                return;
            }
        }
    }

    function renderStatus() {
        var el = $('notify-status');
        if (!el) return;
        var html = '';
        if (_updateFailed && _view === 'ready') html += '<span class="notify-badge notify-badge-warn">UPDATE FAILED — SHOWING LAST GOOD DATA</span> ';
        if (_recovered) {
            var q = typeof _recovered.quarantined === 'number' ? _recovered.quarantined : 0;
            html += '<span class="notify-badge notify-badge-warn">STORE RECOVERED' + (q > 0 ? ' — ' + esc(q) + ' CONNECTION(S) QUARANTINED' : '') + '</span> ';
        }
        if (_view === 'ready' && !_receiptsOk) html += '<span class="notify-badge notify-badge-warn">LAST-DELIVERY DATA UNAVAILABLE</span> ';
        el.innerHTML = html;
    }

    function renderToolbar() {
        var el = $('notify-toolbar');
        if (!el) return;
        // The rebuild below replaces the button: keep keyboard focus on it if it had it.
        var hadFocus = !!(document.activeElement && el.contains(document.activeElement));
        if (_view !== 'ready') { el.innerHTML = ''; return; }
        el.innerHTML = '<button type="button" class="btn-lcars btn-lcars-primary" data-act="add" aria-label="Add connection">+ ADD CONNECTION</button>';
        if (hadFocus) { var again = el.querySelector('button'); if (again) again.focus(); }
    }

    function render() {
        try {
            renderStatus();
            renderToolbar();
            var c = $('notify-content');
            if (!c) return;
            var focused = captureFocus(c);
            if (_view === 'loading') {
                c.innerHTML = '<div class="empty-state"><div class="empty-state-text">LOADING CONNECTIONS...</div></div>';
            } else if (_view === 'locked') {
                c.innerHTML = '<div class="notify-locked" role="alert"><div class="empty-state-text">LOCKED — ADMIN KEY REQUIRED</div>' +
                    '<p>Notification connections hold credentials, so this screen needs the admin key.</p>' +
                    '<button type="button" class="btn-lcars btn-lcars-primary" data-act="unlock" aria-label="Unlock admin actions">UNLOCK</button></div>';
            } else if (_view === 'disabled') {
                c.innerHTML = '<div class="notify-disabled" role="alert"><div class="empty-state-text">NOTIFICATION STORE DISABLED</div>' +
                    '<p>' + esc(_reason || 'The hub store is not enabled.') + '</p>' +
                    '<p>Set the <code>NOTIFY_STORE_KEY</code> secret on the Fleet Monitor server (32 bytes, base64 or 64 hex chars) and restart it.</p></div>';
            } else if (_view === 'error') {
                c.innerHTML = '<div class="notify-disabled" role="alert"><div class="empty-state-text">CONNECTIONS UNAVAILABLE</div><p>' + esc(_reason) + '</p></div>';
            } else if (!_conns.length) {
                c.innerHTML = '<div class="empty-state"><div class="empty-state-text">NO CONNECTIONS CONFIGURED</div></div>';
            } else {
                var last = lastDeliveryMap(_receipts);
                c.innerHTML = '<div class="notify-table-wrap" role="region" aria-label="Notification connections" tabindex="0">' +
                    '<table class="notify-table"><thead><tr><th>Label</th><th>Provider</th><th>Id</th><th>Parameters</th><th>Secrets</th><th>Last delivery</th><th>Actions</th></tr></thead><tbody>' +
                    _conns.map(function(x) { return rowHtml(x, last); }).join('') + '</tbody></table></div>';
            }
            restoreFocus(c, focused);
        } catch (e) {
            if (typeof console !== 'undefined' && console.warn) console.warn('[NOTIFY] render failed:', e && e.message);
        }
    }

    // =========================================================================
    // REFRESH
    // =========================================================================

    function doRefresh() {
        return call('GET', '/status').then(function(st) {
            if (st.status === 401) { _view = 'locked'; return; }
            if (!st.ok || !isObj(st.data)) {
                if (_view === 'ready') { _updateFailed = true; return; }
                _view = 'error';
                _reason = errText(st, 'Could not read hub status.');
                return;
            }
            _providers = Array.isArray(st.data.providers) ? st.data.providers.filter(function(p) { return typeof p === 'string'; }) : [];
            _recovered = isObj(st.data.recovered) ? st.data.recovered : null;
            if (st.data.enabled !== true) {
                _view = 'disabled';
                _reason = typeof st.data.reason === 'string' ? st.data.reason : '';
                _conns = [];
                return;
            }
            return Promise.all([call('GET', '/connections'), call('GET', '/receipts?limit=' + RECEIPT_LIMIT)]).then(function(rs) {
                var cr = rs[0];
                var rr = rs[1];
                if (cr.status === 401 || rr.status === 401) { _view = 'locked'; return; }
                if (cr.status === 503 && cr.data && cr.data.error === 'store_disabled') {
                    _view = 'disabled';
                    _reason = typeof cr.data.message === 'string' ? cr.data.message : '';
                    return;
                }
                if (!cr.ok || !isObj(cr.data) || !Array.isArray(cr.data.connections)) {
                    if (_view === 'ready') { _updateFailed = true; return; }
                    _view = 'error';
                    _reason = errText(cr, 'Could not load connections.');
                    return;
                }
                _conns = cr.data.connections.filter(isObj);
                _receiptsOk = rr.ok && isObj(rr.data) && Array.isArray(rr.data.receipts);
                if (_receiptsOk) _receipts = rr.data.receipts;
                _updateFailed = false;
                _view = 'ready';
            });
        });
    }

    function refresh() {
        if (_inflight) return _inflight;
        _inflight = doRefresh().catch(function(e) {
            if (_view === 'ready') _updateFailed = true;
            else { _view = 'error'; _reason = 'Network error — could not reach the server.'; }
            if (typeof console !== 'undefined' && console.warn) console.warn('[NOTIFY] refresh failed:', e && e.message);
        }).then(function() {
            _inflight = null;
            // A refresh that started before a write finished carries pre-write data (a deleted row
            // would reappear, a fresh test receipt would be missing): drop it and read again.
            if (_stale) { _stale = false; return refresh(); }
            if (!_busy) render();
        });
        return _inflight;
    }

    // Refresh after a write (save / delete / test send). Never trusts an in-flight read that began before the write.
    function refreshAfterWrite() {
        if (_inflight) { _stale = true; return _inflight; }
        return refresh();
    }

    function startPolling() {
        stopPolling();
        refresh();
        _timer = setInterval(function() { refresh(); }, POLL_MS);
    }

    function stopPolling() {
        if (_timer) { clearInterval(_timer); _timer = null; }
    }

    // =========================================================================
    // ADD / EDIT FORM  (client-side validation mirrors lib/notify-providers/*.js;
    // the server is still the authority and its 400 text is shown inline)
    // =========================================================================

    var ADDR_RE = /^[^\s\x00-\x1f\x7f@<>,;"'\\]+@[^\s\x00-\x1f\x7f@<>,;"'\\.]+(\.[^\s\x00-\x1f\x7f@<>,;"'\\.]+)+$/;
    var HOST_RE = /^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$/;
    var TOPIC_RE = /^[A-Za-z0-9_-]{1,64}$/;
    var DEVICE_RE = /^[A-Za-z0-9_-]{1,25}(,[A-Za-z0-9_-]{1,25})*$/;
    var E164_RE = /^\+[1-9]\d{7,14}$/;
    var APPLE_ID_RE = /^[A-Za-z0-9._%+'-]{1,64}@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,24}$/;
    var MACHINE_ID_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
    var TEAMS_HOST_SUFFIXES = ['.logic.azure.com', '.webhook.office.com', '.powerplatform.com', '.powerautomate.com'];
    var MAX_LABEL = 200;

    function findConn(id) {
        for (var i = 0; i < _conns.length; i++) if (_conns[i].id === id) return _conns[i];
        return null;
    }

    function availableProviders() {
        return PROVIDER_ORDER.filter(function(p) { return _providers.indexOf(p) !== -1; });
    }

    function defaultValues(provider) {
        var v = {};
        var def = PROVIDERS[provider];
        if (def) def.params.forEach(function(p) { v[p.name] = p.def !== undefined ? p.def : ''; });
        return v;
    }

    function openForm(mode, conn) {
        var provider = conn ? conn.provider : (availableProviders()[0] || '');
        var values = defaultValues(provider);
        var held = {};
        if (conn) {
            var def = PROVIDERS[conn.provider];
            if (def) def.params.forEach(function(p) {
                var raw = isObj(conn.params) ? conn.params[p.name] : undefined;
                var t = paramText(raw);
                if (t !== '') values[p.name] = t;
                else if (p.kind !== 'select') values[p.name] = '';
            });
            Object.keys(isObj(conn.secrets) ? conn.secrets : {}).forEach(function(k) { held[k] = conn.secrets[k] === 'set'; });
        }
        _form = {
            mode: mode, id: conn ? conn.id : '', provider: provider, label: conn ? conn.label : '',
            values: values, held: held, errors: [], fieldErrors: [], serverError: '', busy: false, baseline: ''
        };
        renderForm(true);
        // Snapshot AFTER the DOM has normalised the values (e.g. a select showing its first option),
        // so only what the operator changes counts as dirty.
        readForm();
        _form.baseline = formSnapshot(_form);
    }

    function formSnapshot(f) {
        return JSON.stringify([f.id, f.provider, f.label, f.values]);
    }

    // Unsaved input: any non-secret field changed since the form opened, or any secret typed /
    // clear ticked (a typed secret is the one thing the operator cannot get back from the screen).
    function formDirty() {
        if (!_form) return false;
        readForm();
        if (formSnapshot(_form) !== _form.baseline) return true;
        var sec = readSecrets();
        return Object.keys(sec).some(function(n) { return sec[n].typed !== '' || sec[n].clear; });
    }

    // Run `go` now if no dirty form is open; otherwise ask first (inline, no modal) and run it on DISCARD.
    function guardDirty(go) {
        if (!_form || !formDirty()) { go(); return; }
        var p = $('notify-form-panel');
        var form = p && p.querySelector('form');
        if (!form) { go(); return; }
        _pendingOpen = go;
        clearDiscardBox();
        var box = document.createElement('div');
        box.id = 'nf-discard';
        box.className = 'notify-confirm notify-discard';
        box.setAttribute('role', 'alert');
        box.innerHTML = '<span>Discard unsaved changes?</span> ' +
            '<button type="button" class="btn-lcars btn-lcars-danger notify-btn" data-act="discard-confirm">DISCARD</button>' +
            '<button type="button" class="btn-lcars btn-lcars-secondary notify-btn" data-act="discard-cancel">KEEP EDITING</button>';
        form.insertBefore(box, form.querySelector('.notify-form-actions'));
        var keep = box.querySelector('[data-act="discard-cancel"]');
        if (keep) keep.focus();
    }

    function clearDiscardBox() {
        var box = $('nf-discard');
        if (box && box.parentNode) box.parentNode.removeChild(box);
    }

    function closeForm() {
        _form = null;
        _pendingOpen = null;
        var p = $('notify-form-panel');
        if (p) { p.innerHTML = ''; p.hidden = true; }
        var add = document.querySelector('#notify-toolbar [data-act="add"]');
        if (add) add.focus();
    }

    function inputHtml(id, value, extra) {
        return '<input class="form-input" type="text" id="' + id + '" value="' + esc(value) + '" autocomplete="off" spellcheck="false"' + (extra || '') + '>';
    }

    function paramFieldHtml(p, value) {
        var id = 'nf-p-' + p.name;
        var input;
        if (p.kind === 'select') {
            input = '<select class="form-select" id="' + id + '">' + p.options.map(function(o) {
                return '<option value="' + esc(o) + '"' + (o === value ? ' selected' : '') + '>' + esc(o) + '</option>';
            }).join('') + '</select>';
        } else if (p.kind === 'number') {
            input = inputHtml(id, value, ' inputmode="numeric"');
        } else {
            input = inputHtml(id, value);
        }
        return '<div class="form-group"><label class="form-label" for="' + id + '">' + esc(p.label) + (p.required ? ' *' : '') + '</label>' + input + '</div>';
    }

    function secretFieldHtml(s, f) {
        var id = 'nf-s-' + s.name;
        var held = f.mode === 'edit' && f.held[s.name] === true;
        var ph = f.mode === 'edit' ? (held ? 'set — leave blank to keep' : 'not set') : '';
        var clear = held
            ? '<label class="notify-clear"><input type="checkbox" id="nf-c-' + s.name + '"> Clear the stored value</label>'
            : '';
        // Never a value attribute: a secret is never prefilled, not even a mask.
        return '<div class="form-group"><label class="form-label" for="' + id + '">' + esc(s.label) + (s.required ? ' *' : '') + '</label>' +
            '<input class="form-input" type="password" id="' + id + '" autocomplete="off" spellcheck="false" placeholder="' + esc(ph) + '">' +
            clear + '</div>';
    }

    function formHtml(f) {
        var def = PROVIDERS[f.provider];
        var providers = availableProviders();
        var head;
        if (f.mode === 'create') {
            head = '<div class="form-group"><label class="form-label" for="nf-id">Connection id *</label>' + inputHtml('nf-id', f.id, ' maxlength="32"') +
                '</div><div class="form-group"><label class="form-label" for="nf-provider">Provider *</label>' +
                (providers.length
                    ? '<select class="form-select" id="nf-provider">' + providers.map(function(p) {
                        return '<option value="' + esc(p) + '"' + (p === f.provider ? ' selected' : '') + '>' + esc(providerLabel(p)) + '</option>';
                    }).join('') + '</select>'
                    : '<div class="form-error">The server reports no supported providers.</div>') + '</div>';
        } else {
            head = '<div class="notify-fixed"><span class="form-label">Connection id</span> <code>' + esc(f.id) + '</code> ' +
                '<span class="form-label">Provider</span> ' + esc(providerLabel(f.provider)) + ' <span class="notify-muted">(fixed — delete and recreate to change)</span></div>';
        }
        var body = '';
        if (!def) {
            body = '<p class="notify-muted notify-unknown-provider">Parameters for provider <code>' + esc(f.provider) + '</code> are not editable here. Only the label can be changed.</p>';
        } else {
            body = def.params.map(function(p) { return paramFieldHtml(p, f.values[p.name] === undefined ? '' : f.values[p.name]); }).join('');
            if (def.secrets.length) {
                body += '<fieldset class="notify-secrets"><legend>Secrets (write-only)</legend>' +
                    '<p class="notify-muted">Stored secrets are never shown again.' + (f.mode === 'edit' ? ' Leave a field blank to keep what is stored.' : '') + '</p>' +
                    def.secrets.map(function(s) { return secretFieldHtml(s, f); }).join('') + '</fieldset>';
            }
        }
        return '<form class="notify-form" novalidate aria-labelledby="nf-title">' +
            '<h3 id="nf-title" class="notify-form-title">' + (f.mode === 'create' ? 'ADD CONNECTION' : 'EDIT CONNECTION') + '</h3>' +
            head +
            '<div class="form-group"><label class="form-label" for="nf-label">Label *</label>' + inputHtml('nf-label', f.label, ' maxlength="200"') + '</div>' +
            body +
            '<div id="nf-errors" class="form-error notify-form-errors" role="alert"></div>' +
            '<div class="notify-form-actions">' +
            '<button type="submit" class="btn-lcars btn-lcars-primary" id="nf-save">SAVE</button>' +
            '<button type="button" class="btn-lcars btn-lcars-secondary" data-act="form-cancel">CANCEL</button></div></form>';
    }

    function renderForm(focusFirst) {
        var p = $('notify-form-panel');
        if (!p || !_form) return;
        p.hidden = false;
        p.innerHTML = formHtml(_form);
        showFormErrors();
        if (focusFirst) {
            var first = p.querySelector(_form.mode === 'create' ? '#nf-id' : '#nf-label');
            if (first) first.focus();
        }
    }

    function showFormErrors() {
        var el = $('nf-errors');
        if (!el || !_form) return;
        var lines = _form.errors.slice();
        if (_form.serverError) lines.push(_form.serverError);
        el.innerHTML = lines.map(function(l) { return '<div>' + esc(l) + '</div>'; }).join('');
        markFieldErrors();
    }

    // Per-field errors (WCAG 3.3.1): each failing input gets aria-invalid + aria-describedby pointing at
    // its own message. The #nf-errors summary stays. Always clears the previous marks first.
    function markFieldErrors() {
        var panel = $('notify-form-panel');
        if (!panel || !_form) return;
        var olds = panel.querySelectorAll('[aria-invalid]');
        for (var i = 0; i < olds.length; i++) { olds[i].removeAttribute('aria-invalid'); olds[i].removeAttribute('aria-describedby'); }
        var msgs = panel.querySelectorAll('.notify-field-error');
        for (var j = 0; j < msgs.length; j++) msgs[j].parentNode.removeChild(msgs[j]);
        var byId = {};
        (_form.fieldErrors || []).forEach(function(fe) { (byId[fe.id] = byId[fe.id] || []).push(fe.msg); });
        Object.keys(byId).forEach(function(id) {
            var input = $(id);
            if (!input) return;
            var m = document.createElement('div');
            m.id = id + '-err';
            m.className = 'form-error notify-field-error';
            m.textContent = byId[id].join(' ');
            input.parentNode.appendChild(m);
            input.setAttribute('aria-invalid', 'true');
            input.setAttribute('aria-describedby', m.id);
        });
    }

    function val(id) {
        var el = $(id);
        return el ? el.value : '';
    }

    // Copy the non-secret fields from the DOM into _form so a provider switch or a
    // failed submit keeps what the operator typed.
    function readForm() {
        if (!_form) return;
        if (_form.mode === 'create') {
            if ($('nf-id')) _form.id = val('nf-id');
            if ($('nf-provider')) _form.provider = val('nf-provider');
        }
        if ($('nf-label')) _form.label = val('nf-label');
        var def = PROVIDERS[_form.provider];
        if (def) def.params.forEach(function(p) { if ($('nf-p-' + p.name)) _form.values[p.name] = val('nf-p-' + p.name); });
    }

    function readSecrets() {
        var out = {};
        var def = PROVIDERS[_form.provider];
        if (!def) return out;
        def.secrets.forEach(function(s) {
            var cb = $('nf-c-' + s.name);
            out[s.name] = { typed: val('nf-s-' + s.name), clear: !!(cb && cb.checked) };
        });
        return out;
    }

    function wipeSecretInputs() {
        var p = $('notify-form-panel');
        if (!p) return;
        var els = p.querySelectorAll('input[type="password"]');
        for (var i = 0; i < els.length; i++) els[i].value = '';
    }

    function splitList(s) {
        return String(s).split(/[,\s]+/).map(function(x) { return x.trim(); }).filter(Boolean);
    }

    function httpsUrl(raw) {
        var u;
        try { u = new URL(raw.trim()); } catch (e) { return null; }
        if (u.protocol !== 'https:' || !u.hostname || u.username || u.password) return null;
        return u;
    }

    // errs is the list of messages (the #nf-errors summary); errs.fields pairs each message with the
    // id of the input it is about, so the form can mark that input aria-invalid (WCAG 3.3.1).
    function validateForm(f, secrets) {
        var errs = [];
        errs.fields = [];
        var bad = function(msg, id) { errs.push(msg); errs.fields.push({ id: id, msg: msg }); };
        var def = PROVIDERS[f.provider];
        if (f.mode === 'create') {
            if (!ID_RE.test(f.id)) bad('Id must start with a lowercase letter and use only lowercase letters, digits and - (32 characters max).', 'nf-id');
            if (!def) { bad('Choose a provider.', 'nf-provider'); return errs; }
        }
        if (!f.label.trim() || f.label.length > MAX_LABEL) bad('Label is required (up to ' + MAX_LABEL + ' characters).', 'nf-label');
        if (!def) return errs;     // an edit of a provider this UI has no table for: label only
        var v = function(n) { return String(f.values[n] === undefined ? '' : f.values[n]).trim(); };
        var typed = function(n) { return secrets[n] ? secrets[n].typed.trim() : ''; };
        // Will this secret hold a value once the request lands?
        var after = function(n) {
            if (typed(n) !== '') return true;
            return f.mode === 'edit' && f.held[n] === true && !(secrets[n] && secrets[n].clear);
        };
        def.secrets.forEach(function(s) {
            if (secrets[s.name] && secrets[s.name].clear && typed(s.name) !== '') bad(s.label + ': enter a new value or tick clear, not both.', 'nf-s-' + s.name);
            if (s.required && !after(s.name)) bad(s.label + ' is required.', 'nf-s-' + s.name);
        });

        switch (f.provider) {
        case 'teams': {
            if (typed('webhookUrl')) {
                var tp = httpsUrl(typed('webhookUrl'));
                if (!tp || tp.port) bad('Webhook URL must be an https URL without credentials or a port.', 'nf-s-webhookUrl');
                else if (!TEAMS_HOST_SUFFIXES.some(function(x) { return tp.hostname.length > x.length && tp.hostname.slice(-x.length) === x; })) {
                    bad('Webhook URL must be a Microsoft Teams / Power Automate URL.', 'nf-s-webhookUrl');
                }
            }
            break;
        }
        case 'slack': {
            if (typed('webhookUrl')) {
                var sp = httpsUrl(typed('webhookUrl'));
                if (!sp || sp.hostname !== 'hooks.slack.com' || sp.port || sp.pathname.indexOf('/services/') !== 0 || sp.pathname.length <= '/services/'.length) {
                    bad('Webhook URL must be a Slack incoming-webhook URL (https://hooks.slack.com/services/...).', 'nf-s-webhookUrl');
                }
            }
            break;
        }
        case 'email': {
            if (!v('host') || v('host').length > 253 || !HOST_RE.test(v('host'))) bad('SMTP host is required (a hostname).', 'nf-p-host');
            if (!/^\d{1,5}$/.test(v('port')) || +v('port') < 1 || +v('port') > 65535) bad('Port must be a number from 1 to 65535.', 'nf-p-port');
            if (!ADDR_RE.test(v('from'))) bad('From must be an email address.', 'nf-p-from');
            var to = v('to').split(',').map(function(x) { return x.trim(); });
            if (!v('to') || to.length > 20 || !to.every(function(a) { return ADDR_RE.test(a); })) bad('To must be 1 to 20 comma-separated email addresses.', 'nf-p-to');
            if (after('user') !== after('pass')) bad('SMTP user and password must be set together (or neither).', 'nf-s-user');
            break;
        }
        case 'pushover': {
            if (v('device') && !DEVICE_RE.test(v('device'))) bad('Device must be comma-separated names of letters, digits, _ or - (25 characters each).', 'nf-p-device');
            break;
        }
        case 'ntfy': {
            if (v('server')) {
                var np = httpsUrl(v('server'));
                if (!np || np.search || np.hash) bad('Server must be an https URL without credentials, query or fragment.', 'nf-p-server');
            }
            if (typed('topic') && !TOPIC_RE.test(typed('topic'))) bad('Topic may use letters, digits, - and _ only (64 characters max).', 'nf-s-topic');
            if (typed('token') && /[^\x21-\x7e]/.test(typed('token'))) bad('Access token has invalid characters.', 'nf-s-token');
            break;
        }
        case 'imessage': {
            var rcpt = v('recipient');
            if (!(E164_RE.test(rcpt) || (rcpt.length <= 254 && APPLE_ID_RE.test(rcpt)))) bad('Recipient must be an E.164 number (+15551234567) or an Apple ID email.', 'nf-p-recipient');
            if (SEVERITIES.indexOf(v('minSeverity')) === -1) bad('Minimum severity must be one of ' + SEVERITIES.join(', ') + '.', 'nf-p-minSeverity');
            var pool = splitList(f.values.pool || '');
            if (pool.length > 32 || !pool.every(function(m) { return MACHINE_ID_RE.test(m); })) bad('Pool must be up to 32 machine ids (letters, digits, . _ -).', 'nf-p-pool');
            break;
        }
        }
        return errs;
    }

    function buildPayload(f, secrets) {
        var def = PROVIDERS[f.provider];
        // A provider this UI has no table for can only have its label edited; params and secrets
        // are left to the store (a PUT without them keeps what is stored).
        if (!def) return { label: f.label.trim() };
        var params = {};
        def.params.forEach(function(p) {
            var raw = String(f.values[p.name] === undefined ? '' : f.values[p.name]).trim();
            if (p.kind === 'list') { var l = splitList(raw); if (l.length) params[p.name] = l; return; }
            if (raw === '') return;
            params[p.name] = p.kind === 'number' ? parseInt(raw, 10) : raw;
        });
        var sec = {};
        var any = false;
        def.secrets.forEach(function(s) {
            var sv = secrets[s.name];
            if (!sv) return;
            if (sv.typed.trim() !== '') { sec[s.name] = sv.typed; any = true; }
            else if (sv.clear) { sec[s.name] = null; any = true; }   // explicit clear: the store reads null as "remove"
        });
        if (f.mode === 'create') return { id: f.id, provider: f.provider, label: f.label.trim(), params: params, secrets: sec };
        var body = { label: f.label.trim(), params: params };
        if (any) body.secrets = sec;     // blank secrets are OMITTED: the store keeps the stored value
        return body;
    }

    function onFormChange(e) {
        if (!_form || !e.target) return;
        if (e.target.id === 'nf-provider') {
            readForm();
            _form.values = defaultValues(_form.provider);
            _form.errors = [];
            _form.fieldErrors = [];
            _form.serverError = '';
            renderForm(false);
            var sel = $('nf-provider');
            if (sel) sel.focus();
        }
    }

    function onSubmit(e) {
        e.preventDefault();
        if (!_form || _form.busy) return;
        readForm();
        var secrets = readSecrets();
        var payload;
        try {
            _form.errors = validateForm(_form, secrets);
            _form.fieldErrors = _form.errors.fields || [];
            _form.serverError = '';
            if (!_form.errors.length) payload = buildPayload(_form, secrets);
        } catch (err) {
            // Never an uncaught throw out of a submit: say so inline instead of failing silently.
            _form.errors = ['This connection could not be validated in this screen.'];
            _form.fieldErrors = [];
            payload = undefined;
        }
        if (_form.errors.length || !payload) {
            if (!_form.errors.length) _form.errors = ['This connection could not be saved from this screen.'];
            showFormErrors();
            var firstBad = $('notify-form-panel').querySelector('[aria-invalid="true"]');
            if (firstBad) firstBad.focus();
            return;
        }
        var creating = _form.mode === 'create';
        var typedAny = Object.keys(secrets).some(function(k) { return secrets[k].typed !== ''; });
        var form = _form;
        form.busy = true;
        _busy = true;
        var save = $('nf-save');
        if (save) save.disabled = true;
        // The payload now holds the only copy of the typed secrets: empty the inputs
        // before the request is even answered.
        wipeSecretInputs();
        var req = creating
            ? call('POST', '/connections', payload)
            : call('PUT', '/connections/' + encodeURIComponent(form.id), payload);
        payload = null;
        req.then(function(res) {
            if (res.ok) return { ok: true };
            var msg = res.status === 401 ? 'Locked — unlock admin actions and try again.' : errText(res);
            return { ok: false, msg: msg + (typedAny || creating || res.status === 401 ? ' Secret fields were cleared; re-enter them to retry.' : '') };
        }, function() {
            return { ok: false, msg: 'Request failed — could not reach the server.' };
        }).then(function(out) {
            _busy = false;
            wipeSecretInputs();
            form.busy = false;
            if (out.ok) {
                if (_form === form) closeForm();
                announce((creating ? 'Created connection ' : 'Saved connection ') + form.label.trim());
                return refreshAfterWrite();
            }
            form.serverError = out.msg;
            if (_form === form) {
                var s2 = $('nf-save');
                if (s2) s2.disabled = false;
                showFormErrors();
            }
        });
    }

    // =========================================================================
    // TEST / SEND TEST / DELETE
    // =========================================================================

    function runTest(id, send) {
        _busy = true;
        _results[id] = { ok: true, text: send ? 'Sending test notification...' : 'Validating configuration...' };
        render();
        var text = '';
        var ok = false;
        call('POST', '/connections/' + encodeURIComponent(id) + '/test', { send: send === true }).then(function(res) {
            var d = res.data;
            if (res.ok && isObj(d)) {
                ok = d.ok === true;
                if (send) text = ok && d.sent === true ? 'TEST SENT — the provider accepted it. Check the destination.' : 'SEND FAILED: ' + (d.error || 'the provider rejected it');
                else text = ok ? 'VALID — the configuration passes the provider checks.' : 'INVALID: ' + (d.error || 'configuration rejected');
            } else {
                text = res.status === 401 ? 'Locked — unlock admin actions and try again.' : 'TEST FAILED: ' + errText(res);
            }
        }, function() {
            text = 'TEST FAILED: could not reach the server.';
        }).then(function() {
            _busy = false;
            _results[id] = { ok: ok, text: text };
            render();
            announce(text);
            if (send) return refreshAfterWrite();
        });
    }

    function runDelete(id) {
        var conn = findConn(id);
        var name = conn ? conn.label : id;
        _busy = true;
        call('DELETE', '/connections/' + encodeURIComponent(id)).then(function(res) {
            if (res.ok) {
                delete _results[id];
                if (_form && _form.id === id) closeForm();
                announce('Deleted connection ' + name);
                // Drop the row now (the confirmed delete is authoritative) so focus can move to a row
                // that will still exist after the follow-up refresh.
                var at = -1;
                for (var i = 0; i < _conns.length; i++) if (_conns[i].id === id) { at = i; break; }
                var rest = _conns.filter(function(x) { return x.id !== id; });
                var nextConn = at >= 0 ? (rest[at] || rest[at - 1] || null) : null;
                _conns = rest;
                _focusAfterDelete = { id: nextConn ? nextConn.id : null };
                return true;
            }
            _results[id] = { ok: false, text: 'DELETE FAILED: ' + (res.status === 401 ? 'Locked — unlock admin actions and try again.' : errText(res)) };
            return false;
        }, function() {
            _results[id] = { ok: false, text: 'DELETE FAILED: could not reach the server.' };
            return false;
        }).then(function() {
            _busy = false;
            render();
            if (_focusAfterDelete) {
                var fd = _focusAfterDelete;
                _focusAfterDelete = null;
                focusAfterDelete(fd.id);
            }
            return refreshAfterWrite();
        });
    }

    // After a delete, keyboard focus must not fall to <body>: next row's first button, else the previous
    // row's (the target is computed that way), else + ADD CONNECTION when the list is now empty.
    function focusAfterDelete(rowId) {
        var c = $('notify-content');
        var target = null;
        if (rowId && c) {
            var rows = c.querySelectorAll('tr[data-id]');
            for (var i = 0; i < rows.length; i++) {
                if (rows[i].getAttribute('data-id') === rowId) { target = rows[i].querySelector('button'); break; }
            }
        }
        if (!target) target = document.querySelector('#notify-toolbar [data-act="add"]');
        if (target) target.focus();
    }

    function unlock() {
        var a = window.FleetApiAuth;
        if (!a || typeof a.unlock !== 'function') return;
        Promise.resolve(a.unlock()).then(function(ok) { if (ok) refresh(); }, function() { /* dialog failures surface in the dialog */ });
    }

    function onClick(e) {
        var t = e.target && e.target.closest ? e.target.closest('button[data-act]') : null;
        if (!t || t.disabled) return;
        var act = t.getAttribute('data-act');
        var id = t.getAttribute('data-id');
        if (act === 'add') { if (!_busy) guardDirty(function() { openForm('create'); }); return; }
        if (act === 'unlock') { unlock(); return; }
        if (act === 'form-cancel') { closeForm(); return; }
        if (act === 'discard-confirm') { var go = _pendingOpen; _pendingOpen = null; clearDiscardBox(); if (go) go(); return; }
        if (act === 'discard-cancel') {
            _pendingOpen = null;
            clearDiscardBox();
            var back = $('notify-form-panel') && $('notify-form-panel').querySelector('input, select');
            if (back) back.focus();
            return;
        }
        if (!id || _busy) return;
        switch (act) {
        case 'edit': { var c = findConn(id); if (c) guardDirty(function() { openForm('edit', c); }); break; }
        case 'test': runTest(id, false); break;
        case 'send': _confirm = {}; _confirm[id] = 'send'; delete _results[id]; render(); break;
        case 'delete': _confirm = {}; _confirm[id] = 'delete'; delete _results[id]; render(); break;
        case 'cancel': delete _confirm[id]; render(); break;
        case 'send-confirm': delete _confirm[id]; runTest(id, true); break;
        case 'delete-confirm': delete _confirm[id]; runDelete(id); break;
        }
    }

    // =========================================================================
    // WIRING
    // =========================================================================

    window.LCARSNotifyConnections = {
        refresh: refresh,
        render: render,
        stop: stopPolling,
        polling: function() { return _timer !== null; },
        lastDeliveryMap: lastDeliveryMap
    };

    function init() {
        var c = $('notify-content');
        var t = $('notify-toolbar');
        if (c) c.addEventListener('click', onClick);
        if (t) t.addEventListener('click', onClick);
        var fp = $('notify-form-panel');
        if (fp) {
            fp.addEventListener('click', onClick);
            fp.addEventListener('change', onFormChange);
            fp.addEventListener('submit', onSubmit);
        }
        document.addEventListener('lcars:sectionChange', function(e) {
            if (!e.detail) return;
            // lcars2's event carries no previousSection, so any other section stops the poll.
            if (e.detail.section === SECTION) startPolling();
            else stopPolling();
        });
        render();
        if (document.querySelector('.lcars-section.active[data-section="' + SECTION + '"]')) startPolling();
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }

})();

// === /XACA-1405 ===
