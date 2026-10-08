//
//  lcars-accessories.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

// === XACA-1393-004: ACCESSORIES section (UPS) ===
//
// Renders the top-level `accessories[]` that GET /api/fleet already carries
// (XACA-1392) into #accessories-content. Data source = the /api/fleet payload
// the dashboard already polls (handed in via render()), NOT a second poll of
// GET /api/accessories: one request, one clock, and the machine list used for
// attach/detach is guaranteed to be from the same snapshot as the accessories.
//
// Rules:
//   1. D1: the SERVER derives state. This file renders `state` verbatim and
//      never infers on_battery from percent/charging/runtime.
//   2. ABSENT != ZERO. null/missing renders an em dash / UNKNOWN. Anything that
//      is not exactly 'ac' or 'on_battery' is UNKNOWN.
//   3. ESCAPE EVERYTHING from the payload (names are operator/reporter supplied).
//   4. Attach/detach go through window.fleetApiFetch (the same admin-key
//      mechanism engines/dashboards use); server 404/409 text is shown inline.
//   5. NEVER THROW from render(). A refresh must not clobber an open <select>
//      or an in-flight request: render is skipped while a control is busy.

(function() {
    'use strict';

    var ACCESSORIES_API = '/api/accessories';
    var CONTAINER_ID = 'accessories-content';
    var DASH = '—';

    var _busy = false;          // an attach/detach request is in flight
    var _lastData = null;       // last payload handed to render()
    var _errors = {};           // accessory id -> last server error text
    var _sel = {};              // accessory id -> machine id the operator picked

    function esc(v) {
        if (v === null || v === undefined) return '';
        return String(v)
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;')
            .replace(/'/g, '&#39;');
    }

    function isNum(v) {
        return typeof v === 'number' && isFinite(v);
    }

    function machineName(m) {
        return (m && (m.nickname || m.hostname)) || (m && m.machine_id) || DASH;
    }

    function machineIndex(data) {
        var idx = {};
        var list = (data && data.fleet && Array.isArray(data.fleet.machines)) ? data.fleet.machines : [];
        list.forEach(function(m) { if (m && m.machine_id) idx[m.machine_id] = m; });
        return { byId: idx, list: list };
    }

    // Closed set -> class/label; unknown input can never inject a class name.
    function stateInfo(state) {
        if (state === 'ac') return { cls: 'ac', label: 'AC' };
        if (state === 'on_battery') return { cls: 'on-battery', label: 'ON BATTERY' };
        return { cls: 'unknown', label: 'UNKNOWN' };
    }

    function fmtTime(ts) {
        var d = new Date(ts);
        if (isNaN(d.getTime())) return DASH;
        var p = function(n) { return String(n).padStart(2, '0'); };
        return p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
    }

    function readingHtml(acc) {
        var r = acc && acc.last_reading;
        if (!r || typeof r !== 'object') {
            return '<div class="accessory-reading"><span class="accessory-metric"><span class="accessory-metric-label">BATTERY</span><span class="accessory-metric-value">' + DASH + '</span></span></div>';
        }
        var pct = isNum(r.percent) ? Math.round(r.percent) + '%' : DASH;
        var charging = (r.charging === true && isNum(r.percent)) ? ' <span class="accessory-charging">CHARGING</span>' : '';
        var observed = r.observedAt ? fmtTime(r.observedAt) : DASH;
        var mins = isNum(r.minutes_remaining) ? '~' + Math.round(r.minutes_remaining) + ' MIN' : DASH;
        return '<div class="accessory-reading">' +
            '<span class="accessory-metric"><span class="accessory-metric-label">BATTERY</span><span class="accessory-metric-value">' + esc(pct) + charging + '</span></span>' +
            '<span class="accessory-metric"><span class="accessory-metric-label">RUNTIME</span><span class="accessory-metric-value">' + esc(mins) + '</span></span>' +
            '<span class="accessory-metric"><span class="accessory-metric-label">LAST OBSERVED</span><span class="accessory-metric-value">' + esc(observed) + '</span></span>' +
            '</div>';
    }

    function cardHtml(acc, idx) {
        var info = stateInfo(acc.state);
        var id = acc.id;
        var name = acc.display_name || acc.name || acc.id || 'UPS';
        var link = acc.data_link_machine_id;
        var linkHtml;
        if (!link) {
            linkHtml = DASH;
        } else if (idx.byId[link]) {
            linkHtml = esc(machineName(idx.byId[link]));
        } else {
            linkHtml = esc(link);   // unknown machine: show the raw id rather than hide it
        }

        var attached = Array.isArray(acc.attached_machine_ids) ? acc.attached_machine_ids : [];
        var attachedHtml = attached.length ? attached.map(function(mid) {
            var label = idx.byId[mid] ? machineName(idx.byId[mid]) : mid;
            return '<li class="accessory-attached-item"><span class="accessory-attached-name">' + esc(label) + '</span>' +
                '<button type="button" class="btn-lcars btn-lcars-danger accessory-detach-btn" data-accessory-id="' + esc(id) +
                '" data-machine-id="' + esc(mid) + '" aria-label="Detach ' + esc(label) + ' from ' + esc(name) + '">DETACH</button></li>';
        }).join('') : '<li class="accessory-attached-item accessory-none">' + DASH + ' none attached</li>';

        var options = idx.list.filter(function(m) {
            return m && m.machine_id && attached.indexOf(m.machine_id) === -1;
        }).map(function(m) {
            return '<option value="' + esc(m.machine_id) + '"' + (_sel[id] === m.machine_id ? ' selected' : '') + '>' + esc(machineName(m)) + '</option>';
        }).join('');
        var attachHtml = options ?
            '<div class="accessory-attach-row">' +
            '<select class="lcars-select accessory-attach-select" data-accessory-id="' + esc(id) + '" aria-label="Machine to attach to ' + esc(name) + '">' +
            '<option value="">SELECT MACHINE...</option>' + options + '</select>' +
            '<button type="button" class="btn-lcars btn-lcars-primary accessory-attach-btn" data-accessory-id="' + esc(id) + '" aria-label="Attach selected machine to ' + esc(name) + '">ATTACH</button>' +
            '</div>' : '';

        var err = _errors[id];
        var errHtml = err ? '<div class="accessory-error form-error" role="alert">' + esc(err) + '</div>' : '';

        return '<div class="accessory-card ' + info.cls + '" data-accessory-id="' + esc(id) + '">' +
            '<div class="accessory-header">' +
            '<span class="accessory-name">' + esc(name) + '</span>' +
            '<span class="accessory-type">' + esc(String(acc.type || 'ups').toUpperCase()) + '</span>' +
            '<span class="accessory-state accessory-state-' + info.cls + '">' + info.label + '</span>' +
            '</div>' +
            readingHtml(acc) +
            '<div class="accessory-link"><span class="accessory-metric-label">DATA LINK</span> <span class="accessory-link-host">' + linkHtml + '</span></div>' +
            '<div class="accessory-attached"><span class="accessory-metric-label">ATTACHED MACHINES</span><ul class="accessory-attached-list">' + attachedHtml + '</ul></div>' +
            attachHtml + errHtml +
            '</div>';
    }

    // Remember each card's picked machine before a rebuild; restored only if the
    // machine is still offered (cardHtml marks it selected).
    function captureSelections(container) {
        var sels = container.querySelectorAll('.accessory-attach-select');
        for (var i = 0; i < sels.length; i++) {
            var accId = sels[i].getAttribute('data-accessory-id');
            if (!accId) continue;
            if (sels[i].value) _sel[accId] = sels[i].value; else delete _sel[accId];
        }
    }

    function render(data, container) {
        try {
            container = container || document.getElementById(CONTAINER_ID);
            if (!container) return;
            _lastData = data;
            // Don't rebuild under an in-flight write (drops the pending row state).
            // An open dropdown no longer blocks the refresh: the operator's pick is
            // captured below and restored, so UPS readings stay live.
            if (_busy) return;
            captureSelections(container);

            var list = (data && Array.isArray(data.accessories)) ? data.accessories : [];
            if (!list.length) {
                container.innerHTML = '<div class="empty-state"><div class="empty-state-text">NO ACCESSORIES DETECTED</div></div>';
                return;
            }
            var idx = machineIndex(data);
            container.innerHTML = '<div class="accessory-grid">' +
                list.filter(function(a) { return a && typeof a === 'object' && a.id; })
                    .map(function(a) { return cardHtml(a, idx); }).join('') + '</div>';
        } catch (e) {
            if (typeof console !== 'undefined' && console.warn) console.warn('[ACCESSORIES] render failed:', e && e.message);
        }
    }

    async function mutate(method, accId, machineId) {
        _busy = true;
        delete _errors[accId];
        try {
            var resp = await window.fleetApiFetch(
                ACCESSORIES_API + '/' + encodeURIComponent(accId) + '/machines/' + encodeURIComponent(machineId),
                { method: method }
            );
            if (!resp.ok) {
                var msg = 'HTTP ' + resp.status;
                try {
                    var body = await resp.json();
                    if (body && body.error) msg = body.error;
                } catch (e) { /* non-JSON error body: keep HTTP status */ }
                _errors[accId] = msg;
                return false;
            }
            return true;
        } catch (e) {
            // fleetApiFetch surfaces the unlock dialog itself; a network failure lands here.
            _errors[accId] = (e && e.message) || 'Request failed';
            return false;
        } finally {
            _busy = false;
        }
    }

    // After a write, re-pull /api/fleet so state + attach lists are server truth.
    async function refreshAfterWrite() {
        try {
            var resp = await window.fetch('/api/fleet', { credentials: 'same-origin' });
            if (resp && resp.ok) _lastData = await resp.json();
        } catch (e) { /* fall through: re-render the last snapshot with any error text */ }
        render(_lastData);
    }

    // In-flight guard: a double-click must not send the write twice (the second
    // would 404/409 and paint a bogus error over a successful first write).
    function lockControls() {
        var c = document.getElementById(CONTAINER_ID);
        if (!c) return;
        var b = c.querySelectorAll('.accessory-detach-btn, .accessory-attach-btn, .accessory-attach-select');
        for (var i = 0; i < b.length; i++) b[i].disabled = true;
    }

    function onClick(e) {
        var t = e.target;
        if (!t || !t.closest || _busy) return;
        var detach = t.closest('.accessory-detach-btn');
        var attach = t.closest('.accessory-attach-btn');
        if (detach) {
            var p = mutate('DELETE', detach.getAttribute('data-accessory-id'), detach.getAttribute('data-machine-id'));
            lockControls();
            p.then(refreshAfterWrite);
        } else if (attach) {
            var card = attach.closest('.accessory-card');
            var sel = card && card.querySelector('.accessory-attach-select');
            var accId = attach.getAttribute('data-accessory-id');
            if (!sel || !sel.value) return;
            var p2 = mutate('PUT', accId, sel.value);
            lockControls();
            p2.then(refreshAfterWrite);
        }
    }

    window.LCARSAccessories = { render: render, stateInfo: stateInfo };

    function init() {
        var c = document.getElementById(CONTAINER_ID);
        if (c) c.addEventListener('click', onClick);
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }

})();

// === /XACA-1393-004 ===
