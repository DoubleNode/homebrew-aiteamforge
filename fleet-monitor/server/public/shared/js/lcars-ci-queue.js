//
//  lcars-ci-queue.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

// === XACA-1444-003 / -011: CI pool live queue view + no-capacity banner ===
//
// window.LCARSCIQueue.render(poolBody, containerEl, { document, now })
//   poolBody = parsed GET /api/ci-pool (contract: fleet-monitor/docs/CI-POOL-API-CONTRACT.md)
//   Idempotent and cheap: safe to call every 30 s.
//
// Rules (each one is a [UX]/[Review] gate item):
//   1. ESCAPE EVERYTHING. Only createElement + textContent; no innerHTML anywhere.
//      Repo/branch/job/machine/labels are attacker-influenceable. Links only for
//      https://github.com/ URLs, rel="noopener noreferrer".
//   2. ABSENT != ZERO. null / missing renders an em dash with aria-label
//      "not reported", never 0.
//   3. NO FOCUS THEFT, NO SCROLL RESET. Rows are patched in place by stable job
//      id; the table and scroll container are created once. Rows are only
//      moved when out of order.
//   4. ANNOUNCE ON FLIP ONLY. The banner is a persistent role="status" region.
//      Only its headline is announced, and the headline text is rewritten only
//      when the banner KIND changes (none / no-machine / waiting-too-long /
//      both). Changing counts live in an aria-live="off" detail line.
//   5. No looping animation (none at all; the CSS adds none).
//
// Server contract notes:
//   queue item  : { key, repo, jobId, name, branch, url, jobClass, waitingMs, noCapacityMs, noEligibleMachine, priority }  (QUEUED jobs only;
//                 noEligibleMachine is the server-gated flag the banner uses, noCapacityMs is raw and ignored;
//                 priority 'critical'|'high'|'normal' (XACA-1479, additive; absent/unknown = normal): critical/high rows get a
//                 text+glyph badge in the Status cell, normal rows none)
//   running[]   : { key, repo, jobId, name, branch, workflow, url, runnerName, machine|null, startedAt }  (picked up, JIT or persistent)
//   assignment  : { machine, repo, state, intendedJob, boundJob:{id,name,runId,branch,workflow,url}, boundAt, startedAt }
//   Running jobs are not in queue[]; they are the assignments with state 'running' and a boundJob, plus running[].
//   Rows are keyed by repo + jobId so a job moving queued -> running patches its row in place.
//   The Status column says "queued" / "running" in text; the time cell is labelled
//   "waiting <t>" or "running for <t>" so the two are never ambiguous.

(function(root) {
    'use strict';

    var DASH = '—';
    var TERMINAL = { completed: 1, failed: 1, expired: 1, cancelled: 1, lost: 1 };

    function isNum(v) { return typeof v === 'number' && isFinite(v); }
    function isStr(v) { return typeof v === 'string' && v !== ''; }

    function el(doc, tag, cls, text) {
        var n = doc.createElement(tag);
        if (cls) n.className = cls;
        if (text !== undefined && text !== null) n.textContent = String(text);
        return n;
    }

    function setText(node, text) {
        if (node.textContent !== text) node.textContent = text;
    }

    function setAttr(node, name, value) {
        if (node.getAttribute(name) !== value) node.setAttribute(name, value);
    }

    // Fill a cell with text, or an em dash that screen readers call "not reported".
    function fillCell(doc, cell, text) {
        if (text === null || text === undefined || text === '') {
            if (cell.getAttribute('data-ciq-null') === '1') return;
            cell.textContent = '';
            var d = el(doc, 'span', 'ciq-null', DASH);
            d.setAttribute('aria-label', 'not reported');
            cell.appendChild(d);
            cell.setAttribute('data-ciq-null', '1');
            return;
        }
        if (cell.getAttribute('data-ciq-null') === '1') { cell.textContent = ''; cell.removeAttribute('data-ciq-null'); }
        setText(cell, String(text));
    }

    function humanSec(sec) {
        if (!isNum(sec) || sec < 0) return null;
        sec = Math.floor(sec);
        if (sec < 60) return sec + 's';
        var m = Math.floor(sec / 60);
        if (m < 60) return m + ' min';
        var h = Math.floor(m / 60);
        return h + 'h ' + (m % 60) + 'm';
    }

    function clock(iso) {
        var t = isStr(iso) ? Date.parse(iso) : NaN;
        if (isNaN(t)) return null;
        return new Date(t).toISOString().slice(11, 16) + ' UTC';
    }

    function safeGithubUrl(u) {
        return typeof u === 'string' && u.indexOf('https://github.com/') === 0 ? u : null;
    }

    function pick(o, names) {
        for (var i = 0; i < names.length; i++) {
            if (o && o[names[i]] !== undefined && o[names[i]] !== null && o[names[i]] !== '') return o[names[i]];
        }
        return null;
    }

    // ---------------------------------------------------------------- model
    function machineFor(item, assignments) {
        for (var i = 0; i < assignments.length; i++) {
            var a = assignments[i];
            if (!a || typeof a !== 'object' || TERMINAL[a.state] || !isStr(a.machine)) continue;
            var jid = a.boundJob && a.boundJob.id !== null && a.boundJob.id !== undefined ? a.boundJob.id
                : (a.intendedJob ? a.intendedJob.id : null);
            if (jid === null || jid === undefined || jid !== item.jobId) continue;
            if (isStr(a.repo) && isStr(item.repo) && a.repo !== item.repo) continue;
            return a.machine;
        }
        return null;
    }

    function runningSec(a, ref) {
        var t = Date.parse(pick(a, ['boundAt', 'startedAt']) || '');
        if (isNaN(t) || ref === null) return null;
        return Math.max(0, (ref - t) / 1000);
    }

    // Running jobs, normalised to {repo, id, name, url, branch, machine, runnerName, at}:
    //   1. 'running' assignments that carry a bound job id (JIT runners);
    //   2. body.running[] (XACA-1444 PR #1101 r1): every picked-up pool job, incl. PERSISTENT runners.
    // De-duplicated by repo#jobId, assignments first, so a job is never shown twice.
    function runningRows(assignments, runningList) {
        var out = [], seen = {};
        assignments.forEach(function(a) {
            if (!a || typeof a !== 'object' || a.state !== 'running' || !a.boundJob || typeof a.boundJob !== 'object') return;
            if (!isNum(a.boundJob.id) || !isStr(a.repo)) return;
            var k = a.repo + '#' + a.boundJob.id;
            if (seen[k]) return;
            seen[k] = true;
            out.push({ repo: a.repo, id: a.boundJob.id, name: a.boundJob.name, url: a.boundJob.url, branch: a.boundJob.branch,
                machine: isStr(a.machine) ? a.machine : null, runnerName: null, at: pick(a, ['boundAt', 'startedAt']) });
        });
        (Array.isArray(runningList) ? runningList : []).forEach(function(j) {
            if (!j || typeof j !== 'object' || !isStr(j.repo) || !isNum(j.jobId)) return;
            var k = j.repo + '#' + j.jobId;
            if (seen[k]) return;
            seen[k] = true;
            out.push({ repo: j.repo, id: j.jobId, name: j.name, url: j.url, branch: j.branch,
                machine: isStr(j.machine) ? j.machine : null, runnerName: isStr(j.runnerName) ? j.runnerName : null, at: j.startedAt });
        });
        return out;
    }

    function waitingSec(item, ref) {
        if (isNum(item.waitingMs)) return Math.max(0, item.waitingMs / 1000);
        var q = pick(item, ['queuedAt', 'createdAt', 'firstSeenAt']);
        var t = isStr(q) ? Date.parse(q) : NaN;
        if (isNaN(t) || ref === null) return null;
        return Math.max(0, (ref - t) / 1000);
    }

    function bannerModel(body, queue) {
        var nc = body.noCapacity && typeof body.noCapacity === 'object' ? body.noCapacity : {};
        var groups = Array.isArray(body.queueAge) ? body.queueAge.filter(function(g) { return g && typeof g === 'object'; }) : [];
        var over = groups.filter(function(g) { return g.overThreshold === true; });
        // The server is the single authority on "no machine can take this job": noEligibleMachine uses the same
        // gate as noCapacity() (live mode, >= 120 s). The raw noCapacityMs is NOT used: it is set in shadow mode
        // and from the first tick (PR #1101 r1, XACA-1444-012). Older servers omit the flag; then only
        // noCapacity.active that is not explained by an aged group counts as "no machine".
        var hasFlag = queue.some(function(q) { return typeof q.noEligibleMachine === 'boolean'; });
        var noMachine = hasFlag && queue.some(function(q) { return q.noEligibleMachine === true; });
        var active = nc.active === true || over.length > 0;
        if (!active) return { kind: 'none' };
        // Active with neither per-job evidence nor an aged group: the server says no capacity.
        if (!noMachine && over.length === 0) noMachine = true;
        var kind = noMachine && over.length ? 'both' : (noMachine ? 'nomachine' : 'age');
        var oldest = null;
        over.forEach(function(g) {
            if (isNum(g.oldestWaitSec) && (oldest === null || g.oldestWaitSec > oldest.sec)) oldest = { sec: g.oldestWaitSec, labels: g.labels };
        });
        return { kind: kind, since: nc.since, queued: isNum(nc.queuedCount) ? nc.queuedCount : null, oldest: oldest };
    }

    // ---------------------------------------------------------------- DOM
    function build(doc, container) {
        container.textContent = '';
        var rootEl = el(doc, 'div', 'ciq');
        rootEl.setAttribute('data-ciq', 'root');

        var banner = el(doc, 'div', 'ciq-banner');
        banner.setAttribute('data-ciq-banner', '');
        banner.setAttribute('role', 'status');
        banner.setAttribute('aria-live', 'polite');
        banner.setAttribute('data-ciq-kind', 'none');
        banner.setAttribute('data-ciq-announce-seq', '0');
        banner.hidden = true;
        var head = el(doc, 'strong', 'ciq-banner-head');
        head.setAttribute('data-ciq-headline', '');
        var detail = el(doc, 'span', 'ciq-banner-detail');
        detail.setAttribute('data-ciq-detail', '');
        detail.setAttribute('aria-live', 'off');
        banner.appendChild(head);
        banner.appendChild(detail);

        var age = el(doc, 'div', 'ciq-age');
        age.setAttribute('data-ciq-age', '');
        age.appendChild(el(doc, 'h4', 'ciq-h', 'Queue age'));
        age.appendChild(el(doc, 'ul', 'ciq-age-list'));

        var empty = el(doc, 'p', 'ciq-empty', 'No queued or running jobs');
        empty.setAttribute('data-ciq-empty', '');

        var scroll = el(doc, 'div', 'ciq-scroll');
        scroll.setAttribute('data-ciq-scroll', '');
        scroll.setAttribute('tabindex', '0');
        scroll.setAttribute('role', 'region');
        scroll.setAttribute('aria-label', 'Queued and running CI jobs');
        var table = el(doc, 'table', 'ciq-table');
        table.appendChild(el(doc, 'caption', 'ciq-caption', 'Queued and running CI jobs and the machine that took each'));
        var thead = el(doc, 'thead');
        var tr = el(doc, 'tr');
        ['Repo', 'Workflow / job', 'Branch', 'Status', 'Waiting / running for', 'Machine'].forEach(function(t) {
            var th = el(doc, 'th', null, t);
            th.setAttribute('scope', 'col');
            tr.appendChild(th);
        });
        thead.appendChild(tr);
        table.appendChild(thead);
        table.appendChild(el(doc, 'tbody'));
        scroll.appendChild(table);

        rootEl.appendChild(banner);
        rootEl.appendChild(age);
        rootEl.appendChild(empty);
        rootEl.appendChild(scroll);
        container.appendChild(rootEl);
        return rootEl;
    }

    function renderBanner(rootEl, model) {
        var banner = rootEl.querySelector('[data-ciq-banner]');
        var head = banner.querySelector('[data-ciq-headline]');
        var detail = banner.querySelector('[data-ciq-detail]');
        if (banner.getAttribute('data-ciq-kind') !== model.kind) {
            var headline = '';
            if (model.kind === 'nomachine') headline = 'Jobs are waiting: no CI machine can take them.';
            else if (model.kind === 'age') headline = 'Jobs are waiting too long, even though CI machines may be busy.';
            else if (model.kind === 'both') headline = 'Jobs are waiting: no CI machine can take some, and others have waited too long.';
            setText(head, headline);
            banner.setAttribute('data-ciq-kind', model.kind);
            banner.setAttribute('data-ciq-announce-seq', String(parseInt(banner.getAttribute('data-ciq-announce-seq'), 10) + 1));
            banner.hidden = model.kind === 'none';
        }
        var parts = [];
        if (model.kind !== 'none') {
            if (model.queued !== null) parts.push(model.queued + ' queued');
            var s = clock(model.since);
            parts.push('waiting since ' + (s || DASH));
            if (model.oldest && humanSec(model.oldest.sec)) parts.push('oldest ' + humanSec(model.oldest.sec) + (isStr(model.oldest.labels) ? ' on ' + model.oldest.labels : ''));
        }
        setText(detail, parts.join(' · '));
    }

    function renderAge(doc, rootEl, body) {
        var wrap = rootEl.querySelector('[data-ciq-age]');
        var list = wrap.querySelector('ul');
        var groups = Array.isArray(body.queueAge) ? body.queueAge.filter(function(g) { return g && typeof g === 'object'; }) : [];
        wrap.hidden = groups.length === 0;
        var thr = isNum(body.queueAgeThresholdSec) ? body.queueAgeThresholdSec : null;
        var sig = JSON.stringify([thr, groups.map(function(g) { return [g.labels, g.host, g.depth, g.oldestWaitSec, g.overThreshold === true]; })]);
        if (list.getAttribute('data-ciq-sig') === sig) return;
        list.setAttribute('data-ciq-sig', sig);
        list.textContent = '';
        groups.forEach(function(g) {
            var over = g.overThreshold === true;
            var li = el(doc, 'li', 'ciq-age-item' + (over ? ' ciq-over' : ''));
            li.setAttribute('data-ciq-group', isStr(g.labels) ? g.labels : '');
            li.setAttribute('data-ciq-over', over ? '1' : '0');
            li.appendChild(el(doc, 'span', 'ciq-age-name', isStr(g.host) ? g.host : (isStr(g.labels) ? g.labels : DASH)));
            var depth = el(doc, 'span', 'ciq-age-depth');
            if (isNum(g.depth)) depth.textContent = g.depth + ' queued';
            else { depth.textContent = DASH; depth.setAttribute('aria-label', 'not reported'); }
            li.appendChild(depth);
            var w = humanSec(g.oldestWaitSec);
            var oldest = el(doc, 'span', 'ciq-age-oldest');
            if (w) oldest.textContent = 'oldest ' + w;
            else { oldest.textContent = 'oldest ' + DASH; oldest.setAttribute('aria-label', 'oldest wait not reported'); }
            li.appendChild(oldest);
            if (over) {
                li.appendChild(el(doc, 'span', 'ciq-flag', '▲ over the ' + (thr !== null ? humanSec(thr) : 'configured') + ' threshold'));
            }
            if (isStr(g.labels)) li.appendChild(el(doc, 'span', 'ciq-age-labels', g.labels));
            list.appendChild(li);
        });
    }

    function ensureRow(doc, tbody, id) {
        var rows = tbody.children;
        for (var i = 0; i < rows.length; i++) if (rows[i].getAttribute('data-ciq-job') === id) return rows[i];
        var tr = el(doc, 'tr', 'ciq-row');
        tr.setAttribute('data-ciq-job', id);
        for (var c = 0; c < 6; c++) tr.appendChild(el(doc, 'td'));
        return tr;
    }

    // XACA-1479-007: priority badge in the Status cell. Text AND glyph (never colour alone); the glyph is
    // aria-hidden and a visually-hidden word gives the accessible name. Unknown/absent priority = normal = no badge.
    var PRIO = { critical: { glyph: '\u25B2\u25B2', label: 'CRITICAL' }, high: { glyph: '\u25B2', label: 'HIGH' } };
    function fillStatus(doc, cell, text, priority) {
        if (cell.getAttribute('data-ciq-null') === '1') { cell.textContent = ''; cell.removeAttribute('data-ciq-null'); }
        var t = cell.firstChild;
        if (!t || t.nodeType !== 3) { cell.textContent = ''; t = doc.createTextNode(''); cell.appendChild(t); }
        var key = typeof priority === 'string' && Object.prototype.hasOwnProperty.call(PRIO, priority) ? priority : null;
        // XACA-1479-020: a real trailing space in the text node (only when badged) so the accessible text reads
        // 'queued CRITICAL priority', not 'queuedCRITICAL priority'. Trailing whitespace before the inline-block badge
        // collapses to one normal space; the badge's own margin-left is unchanged.
        var want = key === null ? text : text + ' ';
        if (t.nodeValue !== want) t.nodeValue = want;
        var badge = cell.querySelector('.ciq-prio');
        if (key === null) { if (badge) cell.removeChild(badge); return; }
        if (badge && badge.getAttribute('data-ciq-priority') === key) return;
        if (badge) cell.removeChild(badge);
        badge = el(doc, 'span', 'ciq-prio ciq-prio-' + key);
        badge.setAttribute('data-ciq-priority', key);
        var g = el(doc, 'span', 'ciq-prio-glyph', PRIO[key].glyph);
        g.setAttribute('aria-hidden', 'true');
        badge.appendChild(g);
        badge.appendChild(el(doc, 'span', 'ciq-prio-text', PRIO[key].label));
        badge.appendChild(el(doc, 'span', 'ciq-sr', ' priority'));
        cell.appendChild(badge);
    }

    function prioRank(p) {
        return typeof p === 'string' && Object.prototype.hasOwnProperty.call(PRIO, p) ? (p === 'critical' ? 0 : 1) : 2;
    }

    function fillJob(doc, cell, name, url) {
        var safe = safeGithubUrl(url);
        var a = cell.firstElementChild && cell.firstElementChild.tagName === 'A' ? cell.firstElementChild : null;
        if (safe) {
            if (!a) { cell.textContent = ''; cell.removeAttribute('data-ciq-null'); a = el(doc, 'a'); cell.appendChild(a); }
            setAttr(a, 'href', safe);
            setAttr(a, 'rel', 'noopener noreferrer');
            setAttr(a, 'target', '_blank');
            setText(a, isStr(name) ? name : safe);
        } else {
            if (a) cell.textContent = '';
            fillCell(doc, cell, isStr(name) ? name : null);
        }
    }

    function renderTable(doc, rootEl, body, ref) {
        var queue = Array.isArray(body.queue) ? body.queue.filter(function(q) { return q && typeof q === 'object'; }) : [];
        var assignments = Array.isArray(body.assignments) ? body.assignments : [];
        var running = runningRows(assignments, body.running);
        var tbody = rootEl.querySelector('tbody');

        // Stable id = repo + jobId (the queue's own key carries a run attempt the assignment does not know).
        var runIds = {};
        running.forEach(function(a) { runIds[a.repo + '#' + a.id] = true; });
        var shown = 0;
        var wanted = [];
        // XACA-1479-019: queued rows are shown in DISPATCH order (what ci-dispatcher decide() does): priority rank
        // (critical > high > normal; missing/unknown = normal) then the server's own queue[] order (its FIFO / first-seen
        // order), so a badged job never sits below normal jobs it is dispatched ahead of. Only queued rows are reordered;
        // running rows stay after them (they are not competing for a slot). The explicit index tiebreak keeps the sort
        // stable. Rows are still patched in place and moved by the insertBefore pass below (no rebuild, no focus theft).
        var order = queue.map(function(item, idx) { return { item: item, idx: idx }; });
        order.sort(function(x, y) { return (prioRank(x.item.priority) - prioRank(y.item.priority)) || (x.idx - y.idx); });
        order.forEach(function(o) {
            var item = o.item, idx = o.idx;
            var hasJob = isStr(item.repo) && isNum(item.jobId);
            var id = hasJob ? item.repo + '#' + item.jobId
                : (isStr(item.key) ? item.key : (isStr(item.repo) ? item.repo : '') + '#' + (item.jobId !== undefined ? item.jobId : idx));
            if (hasJob && runIds[id]) return;   // already running: the running row below wins
            shown++;
            var tr = ensureRow(doc, tbody, id);
            var cells = tr.children;
            fillCell(doc, cells[0], isStr(item.repo) ? item.repo : null);
            fillJob(doc, cells[1], isStr(item.name) ? item.name : null, pick(item, ['url', 'htmlUrl', 'html_url', 'jobUrl']));
            var br = pick(item, ['branch', 'headBranch']);
            fillCell(doc, cells[2], isStr(br) ? br : null);
            fillStatus(doc, cells[3], 'queued', item.priority);
            setAttr(tr, 'data-ciq-status', 'queued');
            var w = humanSec(waitingSec(item, ref));
            fillCell(doc, cells[4], w === null ? null : 'waiting ' + w);
            var m = machineFor(item, assignments);
            fillCell(doc, cells[5], m === null ? 'waiting' : m);
            setAttr(tr, 'data-ciq-machine', m === null ? '' : m);
            wanted.push(tr);
        });
        running.forEach(function(a) {
            var tr = ensureRow(doc, tbody, a.repo + '#' + a.id);
            var cells = tr.children;
            fillCell(doc, cells[0], a.repo);
            fillJob(doc, cells[1], isStr(a.name) ? a.name : null, a.url);
            fillCell(doc, cells[2], isStr(a.branch) ? a.branch : null);
            fillStatus(doc, cells[3], 'running', null);
            setAttr(tr, 'data-ciq-status', 'running');
            var r = humanSec(runningSec({ boundAt: a.at }, ref));
            fillCell(doc, cells[4], r === null ? null : 'running for ' + r);
            // No machine resolved (persistent runner of unknown host): show the runner name, never a blank.
            fillCell(doc, cells[5], a.machine !== null ? a.machine : (a.runnerName !== null ? 'runner ' + a.runnerName : null));
            setAttr(tr, 'data-ciq-machine', a.machine !== null ? a.machine : '');
            wanted.push(tr);
            shown++;
        });
        rootEl.querySelector('[data-ciq-empty]').hidden = shown > 0;
        rootEl.querySelector('[data-ciq-scroll]').hidden = shown === 0;

        // Drop stale rows, then place in order moving only what is out of place (keeps focus).
        Array.prototype.slice.call(tbody.children).forEach(function(r) { if (wanted.indexOf(r) < 0) tbody.removeChild(r); });
        for (var k = 0; k < wanted.length; k++) {
            if (tbody.children[k] !== wanted[k]) tbody.insertBefore(wanted[k], tbody.children[k] || null);
        }
        return queue;
    }

    function render(poolBody, containerEl, opts) {
        try {
            if (!poolBody || typeof poolBody !== 'object' || !containerEl) return;
            opts = opts || {};
            var doc = opts.document || containerEl.ownerDocument;
            // The dashboard ships the container `hidden` (lcars-cicd.js re-hides it on 404/failure); a valid body shows it.
            containerEl.hidden = false;
            var rootEl = containerEl.firstElementChild;
            if (!rootEl || rootEl.getAttribute('data-ciq') !== 'root' || containerEl.children.length !== 1) rootEl = build(doc, containerEl);

            var ref = null;
            if (isStr(poolBody.serverTime) && !isNaN(Date.parse(poolBody.serverTime))) ref = Date.parse(poolBody.serverTime);
            else if (isNum(opts.now)) ref = opts.now;
            else if (typeof opts.now === 'function') ref = opts.now();

            var queue = renderTable(doc, rootEl, poolBody, ref);
            renderAge(doc, rootEl, poolBody);
            renderBanner(rootEl, bannerModel(poolBody, queue));
        } catch (e) {
            if (root.console && root.console.warn) root.console.warn('[LCARSCIQueue] render failed', e && e.message);
        }
    }

    root.LCARSCIQueue = { render: render, humanSec: humanSec };
})(typeof window !== 'undefined' ? window : this);
