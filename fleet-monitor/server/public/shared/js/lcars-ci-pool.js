//
//  lcars-ci-pool.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

// === XACA-1444-002: per-machine CI pool cards + Enable/Pause/Resume controls ===
//
// window.LCARSCIPool.render(poolBody, containerEl, opts)
//   poolBody : parsed GET /api/ci-pool response (null/missing => renders nothing)
//   opts     : { fetch, document, now } -- all injectable for tests.
//              fetch defaults to window.fleetApiFetch (admin tier; a 401 flows
//              into its unlock dialog). `now` is accepted for contract parity;
//              ages are server-clock only (serverTime - lastPollAt).
//
// Rules this file lives by:
//   1. State is TEXT badge + glyph + token border, never colour alone.
//      draining/resuming use a static glyph -- no looping animation.
//   2. ABSENT != ZERO: null/missing capacity renders an em dash with
//      aria-label="not reported", never 0.
//   3. ESCAPE EVERYTHING from the payload (machine names / reasons are hostile).
//   4. Controls are native <button>s. A control that cannot act stays focusable
//      with aria-disabled="true" + aria-describedby (never the disabled attr).
//   5. Idempotent render: patches cards by machine id, leaves untouched cards
//      alone, and restores focus if the focused control had to be re-rendered.
//   6. Pause is never silent: a real role="dialog" confirm, then (on 409
//      wouldStrand) a second confirm before re-PUTting with confirm:true.
//   7. After a successful write the root dispatches a bubbling
//      `cicd-pool:changed` event; lcars-cicd.js answers with an immediate refresh.

(function(root) {
    'use strict';

    var API = '/api/ci-pool/machines/';
    var DASH = '—';
    var ENABLE_CMD = 'aiteamforge ci enable';
    var STATES = {
        enabled:  { label: 'ENABLED',  glyph: '●' },
        disabled: { label: 'DISABLED', glyph: '○' },
        draining: { label: 'DRAINING', glyph: '◐' },
        paused:   { label: 'PAUSED',   glyph: '❚❚' },
        resuming: { label: 'RESUMING', glyph: '◑' },
        unknown:  { label: 'UNKNOWN',  glyph: '?' }
    };

    function esc(v) {
        return String(v === null || v === undefined ? '' : v)
            .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
    }
    function isNum(v) { return typeof v === 'number' && isFinite(v); }
    function safeId(s) {
        var str = String(s), h = 0, i;
        for (i = 0; i < str.length; i++) h = (h * 31 + str.charCodeAt(i)) | 0;
        return str.replace(/[^A-Za-z0-9_-]/g, '_') + '-' + (h >>> 0).toString(36);
    }
    function dash() { return '<span aria-label="not reported">' + DASH + '</span>'; }
    function gib(b) { return (b / 1073741824).toFixed(1) + ' GiB'; }
    function num2(n) { return (Math.round(n * 100) / 100).toString(); }

    function capacityRows(m, serverTime) {
        var c = m.capacity && typeof m.capacity === 'object' ? m.capacity : null;
        var g = function(k) { return c && isNum(c[k]) ? c[k] : null; };
        var rows = [];
        var rec = g('memReclaimableBytes'), free = g('memFreePct');
        rows.push(['Reclaimable memory', rec === null ? dash() :
            esc(gib(rec)) + (free === null ? '' : ' (' + esc(Math.round(free)) + '% free)')]);
        var su = g('swapUsedBytes'), st = g('swapTotalBytes');
        rows.push(['Swap used / total', su === null || st === null ? dash() : esc(gib(su) + ' / ' + gib(st))]);
        var l1 = g('load1'), l5 = g('load5'), l15 = g('load15');
        rows.push(['Load (1m / 5m / 15m)', l1 === null ? dash() :
            esc(num2(l1) + (l5 === null ? '' : ' / ' + num2(l5)) + (l15 === null ? '' : ' / ' + num2(l15)))]);
        var nc = g('ncpu');
        rows.push(['VM CPUs', nc === null ? dash() : esc(nc + ' CPUs')]);
        var mt = g('memTotalBytes');
        rows.push(['VM memory', mt === null ? dash() : esc(gib(mt))]);
        var slots = Array.isArray(m.slots) ? m.slots : null;
        var slotHtml = dash();
        if (slots) {
            var busy = slots.filter(function(s) { return s && s.state === 'busy'; }).length;
            var idle = slots.filter(function(s) { return s && s.state === 'idle'; }).length;
            slotHtml = esc(busy + ' busy / ' + idle + ' idle');
        }
        rows.push(['Slots', slotHtml]);
        var ageText = DASH;
        var lp = Date.parse(m.lastPollAt), sv = Date.parse(serverTime);
        if (!isNaN(lp) && !isNaN(sv)) {
            var s = Math.max(0, Math.round((sv - lp) / 1000));
            ageText = s < 90 ? s + ' s ago' : Math.round(s / 60) + ' min ago';
        }
        // A bare text span: render() patches it in place so the ticking "N s ago" never rebuilds the card.
        rows.push(['Last poll', '<span data-cicd-pool-age' + (ageText === DASH ? ' aria-label="not reported"' : '') + '>' + esc(ageText) + '</span>']);
        return rows;
    }

    // ---- which control a card gets ---------------------------------------
    function controlFor(id, m) {
        // Controls follow the RAW flags, never the derived state: an enabled, unpaused machine always
        // offers Pause, even while it reads resuming / unknown (PR #1101 round 1).
        if (m.enabled !== true) {
            var c = { action: 'enable', label: 'Enable' };
            if (m.capability === 'dormant') {
                c.block = 'CI capability is dormant on this machine. Run the command below on the machine itself (needs sudo); a browser cannot do it.';
                c.command = ENABLE_CMD;
            }
            return c;
        }
        if (m.paused === true) return { action: 'resume', label: 'Resume' };
        return { action: 'pause', label: 'Pause' };
    }

    function cardHtml(id, m, serverTime) {
        var state = STATES[m.state] ? m.state : 'unknown';
        var st = STATES[state], key = safeId(id);
        var h = '<div class="cicd-pool-head">' +
            '<h4 class="cicd-pool-name" id="cicd-pool-name-' + esc(key) + '">' + esc(id) + '</h4>' +
            '<span class="cicd-pool-badge" data-cicd-pool-state="' + esc(state) + '">' +
            '<span aria-hidden="true" class="cicd-pool-glyph">' + st.glyph + '</span> ' + esc(st.label) + '</span></div>';
        if (m.stateReason) h += '<p class="cicd-pool-reason" data-cicd-pool-reason>' + esc(m.stateReason) + '</p>';
        if (m.paused === true || m.pauseReason) {
            h += '<p class="cicd-pool-pause" data-cicd-pool-pause>Paused' +
                (m.pausedBy ? ' by ' + esc(m.pausedBy) : '') + (m.pauseReason ? ': ' + esc(m.pauseReason) : '') + '</p>';
        }
        if (m.pauseDrift === true) {
            h += '<p class="cicd-pool-drift" data-cicd-pool-drift>Pause marker on the machine disagrees with the server.</p>';
        }
        h += '<dl class="cicd-pool-cap" data-cicd-pool-capacity>';
        capacityRows(m, serverTime).forEach(function(r) {
            h += '<div><dt>' + esc(r[0]) + '</dt><dd>' + r[1] + '</dd></div>';
        });
        h += '<div><dt>CI capability</dt><dd data-cicd-pool-capability>' + esc(m.capability || 'unknown') + '</dd></div></dl>';
        var c = controlFor(id, m);
        var why = 'cicd-pool-why-' + key + '-' + c.action;
        h += '<div class="cicd-pool-controls">' +
            '<button type="button" class="cicd-pool-btn" data-cicd-pool-action="' + c.action + '" data-cicd-pool-machine="' + esc(id) + '"' +
            ' data-cicd-pool-control="' + esc(id) + ':' + (c.block ? c.action + '-blocked' : c.action) + '"' +
            (c.block ? ' aria-disabled="true" aria-describedby="' + esc(why) + '"' : '') + '>' + esc(c.label) + '</button>';
        if (c.block) h += '<p class="cicd-pool-why" id="' + esc(why) + '" data-cicd-pool-why>' + esc(c.block) + '</p>';
        if (c.command) {
            h += '<p class="cicd-pool-cmd"><code data-cicd-pool-command>' + esc(c.command) + '</code> ' +
                '<button type="button" class="cicd-pool-btn cicd-pool-copy" data-cicd-pool-copy="' + esc(c.command) + '" data-cicd-pool-control="' + esc(id) + ':copy">Copy command</button></p>';
        }
        return h + '</div>';
    }

    // ---- skeleton / lookup ------------------------------------------------
    function ensureRoot(container, doc) {
        var r = container.querySelector('[data-cicd-pool-root]');
        if (r) return r;
        container.innerHTML = '';
        r = doc.createElement('section');
        r.setAttribute('data-cicd-pool-root', '');
        r.setAttribute('aria-labelledby', 'cicd-pool-heading');
        r.className = 'cicd-pool';
        r.innerHTML = '<h3 class="cicd-pool-title" id="cicd-pool-heading">CI POOL MACHINES</h3>' +
            '<ul class="cicd-pool-list" data-cicd-pool-list></ul>' +
            '<div class="cicd-pool-status" role="status" aria-live="polite" data-cicd-pool-status></div>' +
            '<div data-cicd-pool-dialog-host></div>';
        container.appendChild(r);
        r.addEventListener('click', function(e) { onClick(r, e); });
        r.addEventListener('keydown', function(e) { onKey(r, e); });
        return r;
    }

    function announce(r, msg) { var s = r.querySelector('[data-cicd-pool-status]'); if (s) s.textContent = msg; }

    function findCard(list, id) {
        var items = list.children;
        for (var i = 0; i < items.length; i++) {
            if (items[i].getAttribute('data-cicd-pool-machine-card') === id) return items[i];
        }
        return null;
    }
    function findByControl(r, key) {
        var els = r.querySelectorAll('[data-cicd-pool-control]');
        for (var i = 0; i < els.length; i++) {
            if (els[i].getAttribute('data-cicd-pool-control') === key) return els[i];
        }
        return null;
    }
    var AGE_RE = /<span data-cicd-pool-age[^>]*>[^<]*<\/span>/;
    function patchAge(card, html) {
        var m = AGE_RE.exec(html), span = card.querySelector('[data-cicd-pool-age]');
        if (!m || !span) return;
        var t = m[0].replace(/^<[^>]*>/, '').replace(/<\/span>$/, '').replace(/&amp;/g, '&');
        if (span.textContent !== t) span.textContent = t;
        if (t === DASH) span.setAttribute('aria-label', 'not reported'); else span.removeAttribute('aria-label');
    }
    function findControl(r, action, id) {
        var els = r.querySelectorAll('[data-cicd-pool-action]');
        for (var i = 0; i < els.length; i++) {
            if (els[i].getAttribute('data-cicd-pool-action') === action && els[i].getAttribute('data-cicd-pool-machine') === id) return els[i];
        }
        return null;
    }

    function render(body, container, opts) {
        try {
            renderInner(body, container, opts);
        } catch (e) {
            teardown();
            throw e;
        }
    }
    function renderInner(body, container, opts) {
        if (!container) return;
        opts = opts || {};
        var doc = opts.document || container.ownerDocument || root.document;
        if (!body || typeof body !== 'object' || !body.machines || typeof body.machines !== 'object') {
            teardown();
            container.innerHTML = '';
            container.hidden = true;
            return;
        }
        // Belt-and-braces: inert recorded but no dialog open in this container's DOM -> release.
        if (held.length && !container.querySelector('[data-cicd-pool-dialog]')) releaseInert();
        container.hidden = false;
        var r = ensureRoot(container, doc);
        r._ctx = { opts: opts, body: body };
        var list = r.querySelector('[data-cicd-pool-list]');
        var ids = Object.keys(body.machines).sort();
        var active = doc.activeElement, refocus = null, seen = {}, pos = 0;
        ids.forEach(function(id) {
            var m = body.machines[id];
            if (!m || typeof m !== 'object') return;
            seen[id] = true;
            var html = cardHtml(id, m, body.serverTime);
            var card = findCard(list, id);
            if (!card) {
                card = doc.createElement('li');
                card.setAttribute('data-cicd-pool-machine-card', id);
                card.className = 'cicd-pool-card';
                card.setAttribute('aria-labelledby', 'cicd-pool-name-' + safeId(id));
            }
            var sig = html.replace(AGE_RE, '');
            if (card._sig !== sig) {
                if (active && card.contains(active)) {
                    refocus = [active.getAttribute('data-cicd-pool-control'), id];
                }
                card.innerHTML = html;
                card._sig = sig;
            } else {
                patchAge(card, html);   // only the relative poll time moved: no rebuild, focus untouched
            }
            card.setAttribute('data-cicd-pool-state', STATES[m.state] ? m.state : 'unknown');
            if (list.children[pos] !== card) list.insertBefore(card, list.children[pos] || null);
            pos++;
        });
        Array.prototype.slice.call(list.children).forEach(function(c) {
            if (!seen[c.getAttribute('data-cicd-pool-machine-card')]) list.removeChild(c);
        });
        if (refocus && refocus[0]) {
            var el = findByControl(r, refocus[0]);
            if (!el) {   // the control itself changed (e.g. Pause -> Resume): land on the card's first control
                var rc = findCard(list, refocus[1]);
                el = rc && rc.querySelector('[data-cicd-pool-control]');
            }
            if (el && doc.activeElement !== el) el.focus();
        } else if (r._pendingFocus && (!doc.activeElement || doc.activeElement === doc.body)) {
            // The control that opened a dialog was replaced by the refresh that
            // followed a successful write; land on the card's new control.
            var card2 = findCard(list, r._pendingFocus);
            var b = card2 && card2.querySelector('[data-cicd-pool-action]');
            if (b) b.focus();
            r._pendingFocus = null;
        }
    }

    // ---- writes -------------------------------------------------------------
    function put(r, id, body) {
        var o = (r._ctx && r._ctx.opts) || {};
        // Tests inject opts.fetch; production always goes through the admin
        // wrapper (a 401 opens the unlock dialog). Keep the literal
        // window.fleetApiFetch call here: xaca-0398-003 statically scans for it.
        var transport = o.fetch || function(u, i) {
            if (typeof window.fleetApiFetch !== 'function') return Promise.reject(new Error('admin fetch unavailable'));
            return window.fleetApiFetch(u, i);
        };
        return Promise.resolve(transport(API + encodeURIComponent(id), {
            method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body)
        })).then(function(resp) {
            var p = resp && resp.json ? resp.json().catch(function() { return null; }) : null;
            return Promise.resolve(p).then(function(data) {
                return { ok: !!(resp && resp.ok), status: resp ? resp.status : 0, data: data };
            });
        });
    }

    function changed(r) {
        try { r.dispatchEvent(new r.ownerDocument.defaultView.CustomEvent('cicd-pool:changed', { bubbles: true })); } catch (e) { /* ignore */ }
    }

    function finish(r, id, verb, res) {
        r._busy = false;
        if (res.ok) {
            announce(r, id + ': ' + verb + ' applied.');
            changed(r);
        } else if (res.status === 401) {
            announce(r, id + ': ' + verb + ' needs admin unlock (HTTP 401).');
        } else {
            announce(r, id + ': ' + verb + ' failed (HTTP ' + res.status + ')' +
                (res.data && res.data.error ? ': ' + String(res.data.error).slice(0, 200) : '') + '.');
        }
    }
    function fail(r, id, verb, err) {
        r._busy = false;
        announce(r, id + ': ' + verb + ' failed (' + String((err && err.message) || err).slice(0, 120) + ').');
    }

    function simple(r, id, verb, body) {
        if (r._busy) return;
        r._busy = true;
        announce(r, id + ': ' + verb + ' in progress.');
        r._pendingFocus = id;
        put(r, id, body).then(function(res) { finish(r, id, verb, res); }, function(err) { fail(r, id, verb, err); });
    }

    // ---- confirm dialog -----------------------------------------------------
    // Everything outside the dialog host becomes inert (attribute + aria-hidden fallback) while it is open.
    // ONE release function (XACA-1444-022). Every element the module makes inert is recorded here with the
    // aria-hidden value it had BEFORE, so release restores exactly that (a pre-existing aria-hidden survives).
    // Every teardown path funnels into releaseInert(): close, Escape, dialog node removed, render(null/malformed),
    // a throwing render, teardown(), and the start of every render().
    var held = [];
    var observed = null;
    function releaseInert() {
        var list = held;
        held = [];
        list.forEach(function(h) {
            try {
                h.el.removeAttribute('inert');
                if (h.prior === null) h.el.removeAttribute('aria-hidden'); else h.el.setAttribute('aria-hidden', h.prior);
            } catch (e) { /* element gone: nothing to restore */ }
        });
        if (observed) { try { observed.disconnect(); } catch (e) { /* ignore */ } observed = null; }
    }
    function setBackgroundInert(r, host) {
        var doc = r.ownerDocument, node = host;
        releaseInert();
        while (node && node !== doc.documentElement && node.parentNode) {
            Array.prototype.slice.call(node.parentNode.children).forEach(function(sib) {
                if (sib === node || sib.hasAttribute('inert') || sib.tagName === 'SCRIPT' || sib.tagName === 'STYLE') return;
                if (sib.hasAttribute('data-cicd-pool-status')) return;   // the live region must keep announcing
                held.push({ el: sib, prior: sib.hasAttribute('aria-hidden') ? sib.getAttribute('aria-hidden') : null });
                sib.setAttribute('inert', '');
                sib.setAttribute('aria-hidden', 'true');
            });
            node = node.parentNode;
        }
        // The dialog node leaving the DOM for ANY reason (container cleared, tab hid and rebuilt it) releases.
        var View = doc.defaultView, MO = View && View.MutationObserver;
        if (MO) {
            observed = new MO(function() { if (!r.isConnected || !r.querySelector('[data-cicd-pool-dialog]')) releaseInert(); });
            observed.observe(doc.documentElement, { childList: true, subtree: true });
        }
    }

    function closeDialog(r, restore) {
        var host = r.querySelector('[data-cicd-pool-dialog-host]');
        var d = host && host.firstChild, inv = d && d._invoker;
        releaseInert();
        if (host) host.innerHTML = '';
        if (restore && inv) {
            var el = findControl(r, inv[0], inv[1]);
            if (el) el.focus(); else r._pendingFocus = inv[1];
        }
    }
    // Public: the host page calls this before it clears/hides the container.
    function teardown() {
        releaseInert();
        try {
            var hosts = root.document ? root.document.querySelectorAll('[data-cicd-pool-dialog-host]') : [];
            for (var i = 0; i < hosts.length; i++) hosts[i].innerHTML = '';
        } catch (e) { /* best effort */ }
    }
    function openDialog(r, id, invoker) {
        var host = r.querySelector('[data-cicd-pool-dialog-host]');
        host.innerHTML = '';
        var d = r.ownerDocument.createElement('div');
        d.setAttribute('role', 'dialog');
        d.setAttribute('aria-modal', 'true');
        d.setAttribute('aria-labelledby', 'cicd-pool-dlg-title');
        d.setAttribute('aria-describedby', 'cicd-pool-dlg-desc');
        d.setAttribute('data-cicd-pool-dialog', '');
        d.className = 'cicd-pool-dialog';
        d._invoker = [invoker.getAttribute('data-cicd-pool-action'), id];
        d._id = id;
        host.appendChild(d);
        setBackgroundInert(r, host);
        setStep(d, 1);
    }
    function setStep(d, step) {
        var id = d._id, k = esc(safeId(id));
        d._step = step;
        if (step === 1) {
            d.innerHTML = '<h4 id="cicd-pool-dlg-title">Pause ' + esc(id) + '?</h4>' +
                '<p id="cicd-pool-dlg-desc">Jobs in progress finish; none are cancelled. The machine stops accepting new jobs until resumed.</p>' +
                '<label for="cicd-pool-reason-' + k + '">Reason (optional)</label> ' +
                '<input type="text" maxlength="200" id="cicd-pool-reason-' + k + '" data-cicd-pool-reason-input>' +
                '<div class="cicd-pool-dlg-actions">' +
                '<button type="button" class="cicd-pool-btn" data-cicd-pool-dlg="cancel">Cancel</button> ' +
                '<button type="button" class="cicd-pool-btn cicd-pool-btn-caution" data-cicd-pool-dlg="confirm"><span aria-hidden="true">❚❚ </span>Pause ' + esc(id) + '</button></div>';
        } else {
            d.innerHTML = '<h4 id="cicd-pool-dlg-title">' + esc(id) + ' is the last available machine</h4>' +
                '<p id="cicd-pool-dlg-desc">With no CI machine available, queued jobs will wait until one is resumed. Pause anyway?</p>' +
                '<div class="cicd-pool-dlg-actions">' +
                '<button type="button" class="cicd-pool-btn" data-cicd-pool-dlg="cancel">Cancel</button> ' +
                '<button type="button" class="cicd-pool-btn cicd-pool-btn-caution" data-cicd-pool-dlg="strand"><span aria-hidden="true">▲ </span>Pause anyway</button></div>';
        }
        var first = d.querySelector('[data-cicd-pool-dlg="cancel"]');
        if (first) first.focus();
    }

    function dialogConfirm(r, d, confirm) {
        var id = d._id;
        var inp = d.querySelector('[data-cicd-pool-reason-input]');
        if (inp) d._reason = inp.value;
        var body = { paused: true };
        if (d._reason) body.reason = d._reason;
        if (confirm) body.confirm = true;
        if (r._busy) return;
        r._busy = true;
        announce(r, id + ': pause in progress.');
        put(r, id, body).then(function(res) {
            if (res.status === 409 && res.data && res.data.wouldStrand === true && !confirm) {
                r._busy = false;
                announce(r, id + ' is the last available machine; confirm to pause anyway.');
                setStep(d, 2);
                return;
            }
            r._pendingFocus = id;
            closeDialog(r, true);
            finish(r, id, 'pause', res);
        }, function(err) { closeDialog(r, true); fail(r, id, 'pause', err); });
    }

    // ---- delegated events -------------------------------------------------
    function onClick(r, e) {
        var t = e.target && e.target.closest ? e.target.closest('button') : null;
        if (!t || !r.contains(t)) return;
        if (r.querySelector('[data-cicd-pool-dialog]') && !t.closest('[data-cicd-pool-dialog]')) { e.preventDefault(); return; }
        var dlg = t.getAttribute('data-cicd-pool-dlg');
        if (dlg) {
            var d = t.closest('[data-cicd-pool-dialog]');
            if (dlg === 'cancel') closeDialog(r, true);
            else if (dlg === 'confirm') dialogConfirm(r, d, false);
            else if (dlg === 'strand') dialogConfirm(r, d, true);
            return;
        }
        var cmd = t.getAttribute('data-cicd-pool-copy');
        if (cmd) {
            var nav = r.ownerDocument.defaultView.navigator;
            if (nav && nav.clipboard && nav.clipboard.writeText) {
                nav.clipboard.writeText(cmd).then(function() { announce(r, 'Command copied.'); },
                    function() { announce(r, 'Copy failed; select the command text and copy it manually.'); });
            } else {
                announce(r, 'Copy unavailable; select the command text and copy it manually.');
            }
            return;
        }
        var action = t.getAttribute('data-cicd-pool-action');
        if (!action) return;
        if (t.getAttribute('aria-disabled') === 'true') { e.preventDefault(); return; }
        var id = t.getAttribute('data-cicd-pool-machine');
        if (action === 'pause') {
            if (!r.querySelector('[data-cicd-pool-dialog]')) openDialog(r, id, t);
        } else if (action === 'resume') {
            simple(r, id, 'resume', { paused: false });
        } else if (action === 'enable') {
            simple(r, id, 'enable', { enabled: true });
        }
    }

    function onKey(r, e) {
        var d = e.target && e.target.closest ? e.target.closest('[data-cicd-pool-dialog]') : null;
        if (!d) return;
        if (e.key === 'Escape') { e.preventDefault(); closeDialog(r, true); return; }
        if (e.key === 'Tab') {
            var f = d.querySelectorAll('button, input');
            if (!f.length) return;
            var first = f[0], last = f[f.length - 1], cur = r.ownerDocument.activeElement;
            if (e.shiftKey && cur === first) { e.preventDefault(); last.focus(); }
            else if (!e.shiftKey && cur === last) { e.preventDefault(); first.focus(); }
        }
    }

    root.LCARSCIPool = { render: render, teardown: teardown };

})(typeof window !== 'undefined' ? window : this);

// === /XACA-1444-002 ===
