//
//  lcars-cicd.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

// === XACA-1388: CI/CD self-hosted runner fleet section ===
//
// Renders GET /api/ci-runners into #cicd-content.
//   Data contract : kanban/plans/XACA-1388/XACA-1388_ci_runners_contract.md
//   UX spec       : kanban/plans/XACA-1388/XACA-1388_ux_design.md
//
// Rules this file lives by (each one is a [UX]/[Review] gate item):
//   1. SERVER CLOCK ONLY. Every age/elapsed value is Date.parse(payload string)
//      minus Date.parse(payload.generatedAt). There is no Date.now() and no
//      argument-less `new Date()` anywhere in this file, so a viewer whose
//      clock is wrong cannot flip a runner to OFFLINE.
//   2. ABSENT != ZERO. null / missing / non-numeric renders an em dash and
//      UNKNOWN, never 0 and never green. Fallback is SELF-HOSTED only when
//      armed === true (strict).
//   3. ESCAPE EVERYTHING that came from the payload. Runner/workflow/branch
//      names are attacker-influenceable (PR branch names). Links are rendered
//      only when the URL starts with https://github.com/.
//   4. NEVER THROW. refresh() always resolves; 404 -> "not available" state,
//      5xx/network -> keep the last good render + UPDATE FAILED badge.
//   5. Refresh must not steal focus or reset the jobs table scroll position.

(function() {
    'use strict';

    // =========================================================================
    // CONFIG
    // =========================================================================

    var CI_RUNNERS_API = '/api/ci-runners';
    var CONTAINER_ID = 'cicd-content';
    var CI_POOL_API = '/api/ci-pool';
    var DEFAULT_STALE_AFTER = 180;
    var DEFAULT_OFFLINE_AFTER = 600;
    var MAX_JOBS_RENDERED = 50;
    var GITHUB_PREFIX = 'https://github.com/';
    var DASH = '—';
    var MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

    // =========================================================================
    // STATE
    // =========================================================================

    var _lastGood = null;        // last successfully rendered payload
    var _inflight = null;        // de-dupes overlapping refresh() calls
    var _loggedUnavailable = false;

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

    function isNum(v) {
        return typeof v === 'number' && isFinite(v);
    }

    // Date.parse of a payload string; NaN when absent/unparseable. Never reads the clock.
    function ts(v) {
        if (typeof v !== 'string' || !v) return NaN;
        return Date.parse(v);
    }

    function fmtInt(v) {
        if (!isNum(v)) return null;
        return String(Math.round(v)).replace(/\B(?=(\d{3})+(?!\d))/g, ',');
    }

    // Em dash for "not reported". The dash is aria-hidden and the meaning is
    // carried by visually hidden text: aria-label on a role-less <span> is
    // ignored by screen readers (XACA-1388-020).
    function dashHtml() {
        return '<span class="cicd-null"><span aria-hidden="true">' + DASH + '</span>' +
            '<span class="cicd-sr-only">not reported</span></span>';
    }

    function numOrDash(v) {
        var s = fmtInt(v);
        return s === null ? dashHtml() : esc(s);
    }

    // <60s "Ns", <1h "Nm SSs", <24h "Nh MMm", else "Nd Hh". null/negative/NaN -> null.
    function fmtDuration(sec) {
        if (!isNum(sec) || sec < 0) return null;
        sec = Math.floor(sec);
        if (sec < 60) return sec + 's';
        if (sec < 3600) return Math.floor(sec / 60) + 'm ' + pad2(sec % 60) + 's';
        if (sec < 86400) return Math.floor(sec / 3600) + 'h ' + pad2(Math.floor((sec % 3600) / 60)) + 'm';
        return Math.floor(sec / 86400) + 'd ' + Math.floor((sec % 86400) / 3600) + 'h';
    }

    function durHtml(sec) {
        var s = fmtDuration(sec);
        return s === null ? dashHtml() : esc(s);
    }

    function pad2(n) { return (n < 10 ? '0' : '') + n; }

    // Seconds between two payload timestamps (later - earlier); NaN if either is bad.
    function secondsBetween(laterIso, earlierIso) {
        var a = ts(laterIso);
        var b = ts(earlierIso);
        if (isNaN(a) || isNaN(b)) return NaN;
        return (a - b) / 1000;
    }

    // "30s ago" relative to the SERVER's generatedAt, wrapped in <time> carrying the absolute UTC value.
    function agoHtml(iso, generatedAt) {
        var age = secondsBetween(generatedAt, iso);
        var d = fmtDuration(age);
        if (d === null) return dashHtml();
        return '<time datetime="' + esc(iso) + '" title="' + esc(iso) + '">' + esc(d) + ' ago</time>';
    }

    function utcClock(iso) {
        var ms = ts(iso);
        if (isNaN(ms)) return null;
        return new Date(ms).toISOString().slice(11, 19) + ' UTC';
    }

    function utcStamp(iso) {
        var ms = ts(iso);
        if (isNaN(ms)) return null;
        return new Date(ms).toISOString().slice(5, 16).replace('T', ' ');
    }

    // YYYY-MM-DD -> "Oct 1" without going through the local-timezone Date.
    function fmtDay(s) {
        var m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(typeof s === 'string' ? s : '');
        if (!m) return null;
        var mon = parseInt(m[2], 10);
        if (mon < 1 || mon > 12) return null;
        return MONTHS[mon - 1] + ' ' + parseInt(m[3], 10);
    }

    function safeGithubUrl(u) {
        return (typeof u === 'string' && u.indexOf(GITHUB_PREFIX) === 0) ? u : null;
    }

    function pickLogUrl(job) {
        if (!job) return null;
        return safeGithubUrl(job.jobUrl) || safeGithubUrl(job.runUrl);
    }

    function logLinkHtml(job, label, text, focusKey) {
        var url = pickLogUrl(job);
        if (!url) return dashHtml();
        return '<a class="cicd-link" href="' + esc(url) + '" target="_blank" rel="noopener noreferrer"' +
            ' data-cicd-focus="' + esc(focusKey) + '"' +
            ' aria-label="Open GitHub log for ' + esc(label) + ' (opens in new tab)">' +
            esc(text) + ' <span aria-hidden="true">↗</span></a>';
    }

    // =========================================================================
    // STATUS DERIVATION (pure, server clock only)
    // =========================================================================

    /**
     * OFFLINE | STALE | DEGRADED | ONLINE, in priority order. Age is
     * generatedAt - lastReportAt and each threshold is strictly greater-than.
     */
    function deriveMachineStatus(machine, generatedAt, staleAfterSeconds, offlineAfterSeconds) {
        var stale = isNum(staleAfterSeconds) ? staleAfterSeconds : DEFAULT_STALE_AFTER;
        var offline = isNum(offlineAfterSeconds) ? offlineAfterSeconds : DEFAULT_OFFLINE_AFTER;
        var m = machine || {};
        var age = secondsBetween(generatedAt, m.lastReportAt);
        // A timestamp we cannot parse is missing evidence, not evidence of death:
        // UNKNOWN (neutral), never OFFLINE (red).
        if (isNaN(age)) return 'UNKNOWN';
        if (age > offline) return 'OFFLINE';
        if (age > stale) return 'STALE';
        if (degradedReasons(m).length) return 'DEGRADED';
        return 'ONLINE';
    }

    function degradedReasons(m) {
        var reasons = [];
        var runners = Array.isArray(m.runners) ? m.runners : [];
        var sawOffline = false;
        var sawUnknown = false;
        for (var i = 0; i < runners.length; i++) {
            var svc = runners[i] ? runners[i].service : undefined;
            if (svc === 'online') continue;
            if (svc === 'offline') sawOffline = true; else sawUnknown = true;
        }
        if (sawOffline) reasons.push('runner offline');
        if (sawUnknown) reasons.push('runner status unknown');
        if (m.vm && m.vm.status !== 'Running') reasons.push('VM stopped');
        return reasons;
    }

    /** OFFLINE | UNKNOWN | BUSY | IDLE. Service state outranks busy. */
    function deriveRunnerStatus(runner) {
        var r = runner || {};
        if (r.service === 'offline') return 'OFFLINE';
        if (r.service !== 'online') return 'UNKNOWN';
        if (r.busy) return 'BUSY';
        return 'IDLE';
    }

    function fallbackState(fallback, os) {
        var entry = fallback && typeof fallback === 'object' ? fallback[os] : null;
        if (entry && entry.armed === true) return 'SELF-HOSTED';
        if (entry && entry.armed === false) return 'HOSTED';
        return 'UNKNOWN';
    }

    // =========================================================================
    // HTML BUILDERS
    // =========================================================================

    function pillsHtml(fallback) {
        var out = '';
        ['linux', 'macos'].forEach(function(os) {
            var state = fallbackState(fallback, os);
            var cls = state === 'SELF-HOSTED' ? 'selfhosted' : (state === 'HOSTED' ? 'fallback' : 'unknown');
            var word = state === 'HOSTED' ? 'HOSTED FALLBACK' : state;
            var entry = fallback && fallback[os];
            var value = entry && typeof entry.value === 'string' ? entry.value : null;
            out += '<span class="cicd-pill ' + cls + '" data-cicd-fallback="' + os + '" data-cicd-state="' + state + '"' +
                (value ? ' title="' + esc(value) + '"' : '') + '>' +
                (state === 'SELF-HOSTED' ? '<span aria-hidden="true">●</span> ' : '') +
                esc(os.toUpperCase()) + ': ' + word +
                (value ? '<span class="cicd-sr-only"> (runner labels: ' + esc(value) + ')</span>' : '') +
                '</span>';
        });
        return out;
    }

    function checkedHtml(data) {
        var fb = data.fallback;
        if (!fb || typeof fb !== 'object' || !fb.checkedAt) return 'checked ' + dashHtml();
        var age = secondsBetween(data.generatedAt, fb.checkedAt);
        var stale = isNum(data.staleAfterSeconds) ? data.staleAfterSeconds : DEFAULT_STALE_AFTER;
        var s = 'checked ' + agoHtml(fb.checkedAt, data.generatedAt);
        if (!isNaN(age) && age > stale) s += ' (STALE)';
        return s;
    }

    function tileHtml(group, label, primary, sub) {
        return '<div class="summary-card cicd-tile">' +
            '<div class="summary-label">' + esc(group) + ' ' + esc(label) + '</div>' +
            '<div class="summary-value">' + primary + '</div>' +
            '<div class="cicd-sub">' + sub + '</div></div>';
    }

    function summaryGroup(key, label, s) {
        var has = s && typeof s === 'object';
        var jobs = has ? s.jobs : null;
        var runnerMin = has ? s.minutes : null;
        var hosted = has ? s.hostedEquivalentMinutes : null;
        var jobsSub;
        if (key === 'cycle') {
            var a = has ? fmtDay(s.start) : null;
            var b = has ? fmtDay(s.end) : null;
            jobsSub = (a && b) ? esc(a + ' – ' + b) : dashHtml();
        } else {
            jobsSub = 'UTC DAY';
        }
        var minSub = isNum(runnerMin) ? esc(fmtInt(runnerMin)) + ' runner min' : dashHtml();
        return '<div class="cicd-summary-group" data-cicd-summary="' + key + '">' +
            tileHtml(label, 'JOBS', numOrDash(jobs), jobsSub) +
            tileHtml(label, 'HOSTED MIN SAVED', numOrDash(hosted), minSub) +
            '</div>';
    }

    function summaryHtml(summary) {
        var s = summary && typeof summary === 'object' ? summary : null;
        return '<div class="summary-cards cicd-summary">' +
            summaryGroup('today', 'TODAY', s ? s.today : null) +
            summaryGroup('cycle', 'CYCLE', s ? s.cycle : null) +
            '</div>';
    }

    function diskHtml(disk) {
        if (!disk || !isNum(disk.freeBytes) || !isNum(disk.totalBytes) || disk.totalBytes <= 0) {
            return 'DISK ' + dashHtml();
        }
        var pct = (disk.freeBytes / disk.totalBytes) * 100;
        var flag = '';
        if (pct < 5) flag = ' <span class="cicd-flag critical">CRITICAL</span>';
        else if (pct < 10) flag = ' <span class="cicd-flag low">LOW</span>';
        return 'DISK <span class="cicd-val">' + Math.round(disk.freeBytes / 1e9) + ' GB free / ' +
            Math.round(disk.totalBytes / 1e9) + ' GB (' + Math.round(pct) + '%)</span>' + flag;
    }

    function runnerStatusHtml(status) {
        if (status === 'UNKNOWN') return '<span class="cicd-pill unknown">UNKNOWN</span>';
        var cls = status === 'BUSY' ? 'online' : (status === 'OFFLINE' ? 'offline' : 'idle');
        return '<span class="status-badge ' + cls + '">' + status + '</span>';
    }

    function runnerRowHtml(r, data, lastKnown, machine) {
        var name = r && r.name != null ? r.name : '';
        var machineName = machine && machine.machine != null ? machine.machine : '';
        var status = deriveRunnerStatus(r);
        var cj = r && r.currentJob;
        var anchor = lastKnown && machine ? machine.lastReportAt : data.generatedAt;

        var jobCell;
        if (status === 'BUSY' && cj) {
            // OFFLINE machine: the clock stopped at its last report; anchoring to
            // generatedAt would grow the "elapsed" forever. Negative -> dash.
            var elapsed = secondsBetween(anchor, cj.startedAt);
            var jobLabel = cj.job != null ? cj.job : cj.workflow;
            jobCell = esc(jobLabel) + ' <span class="cicd-sub">' + esc(cj.branch != null ? cj.branch : '') + '</span> ' +
                '<span class="cicd-val">' + durHtml(elapsed) + '</span> ' +
                logLinkHtml(cj, jobLabel, 'LOG', 'runner:' + machineName + ':' + name);
        } else {
            jobCell = dashHtml();
        }
        if (lastKnown) jobCell += ' <span class="cicd-sub">(last known)</span>';
        return '<div class="cicd-runner' + (lastKnown ? ' dimmed' : '') + '" role="row"' +
            ' data-cicd-runner="' + esc(name) + '" data-cicd-status="' + status + '"' +
            (lastKnown ? ' data-cicd-last-known="true"' : '') + '>' +
            '<div role="cell" class="cicd-runner-name" data-label="RUNNER">' + esc(name) + '</div>' +
            '<div role="cell" data-label="OS">' + esc(r && r.os != null ? r.os : '') + '</div>' +
            '<div role="cell" data-label="STATUS">' + runnerStatusHtml(status) + '</div>' +
            '<div role="cell" data-label="UPTIME">' + durHtml(r ? r.uptimeSeconds : null) + '</div>' +
            '<div role="cell" class="cicd-runner-job" data-label="CURRENT JOB / ELAPSED">' + jobCell + '</div>' +
            '</div>';
    }

    function machineHtml(m, data) {
        m = m || {};
        var status = deriveMachineStatus(m, data.generatedAt, data.staleAfterSeconds, data.offlineAfterSeconds);
        var badgeCls = { ONLINE: 'online', DEGRADED: 'warning', STALE: 'warning cicd-stale', OFFLINE: 'offline' }[status];
        var badgeHtml = status === 'UNKNOWN'
            ? '<span class="cicd-pill unknown">UNKNOWN</span>'
            : '<span class="status-badge ' + badgeCls + '">' + status + '</span>';
        var name = m.machine != null ? m.machine : '';
        var age = secondsBetween(data.generatedAt, m.lastReportAt);

        var note = '';
        if (status === 'DEGRADED') note = degradedReasons(m).join(', ');
        else if (status === 'UNKNOWN') note = 'Report time unavailable - state cannot be determined';
        else if (status === 'STALE' || status === 'OFFLINE') {
            var ageText = fmtDuration(age);
            note = ageText === null ? 'no report received' : 'Last known state - no report for ' + ageText;
        }

        var meta = '<span>HOST UP <span class="cicd-val">' + durHtml(m.uptimeSeconds) + '</span></span>';
        if (m.vm) {
            var running = m.vm.status === 'Running';
            meta += '<span>VM ' + esc(m.vm.name) + ' <span class="cicd-val' + (running ? '' : ' cicd-warn') + '">' +
                (running ? 'RUNNING ' + durHtml(m.vm.uptimeSeconds) : esc(String(m.vm.status == null ? 'UNKNOWN' : m.vm.status).toUpperCase())) +
                '</span></span>';
        }
        meta += '<span>' + diskHtml(m.disk) + '</span>';
        meta += '<span>LAST REPORT ' + agoHtml(m.lastReportAt, data.generatedAt) + '</span>';

        var runners = Array.isArray(m.runners) ? m.runners : [];
        var lastKnown = status === 'OFFLINE';
        var rows = '';
        for (var i = 0; i < runners.length; i++) rows += runnerRowHtml(runners[i], data, lastKnown, m);
        var runnersHtml = runners.length
            ? '<div class="cicd-runners" role="table" aria-label="Runners on ' + esc(name) + '">' +
              '<div class="cicd-runner cicd-runner-head" role="row">' +
              '<div role="columnheader">RUNNER</div><div role="columnheader">OS</div>' +
              '<div role="columnheader">STATUS</div><div role="columnheader">UPTIME</div>' +
              '<div role="columnheader">CURRENT JOB / ELAPSED</div></div>' + rows + '</div>'
            : '<div class="cicd-sub">No runners reported</div>';

        return '<div class="cicd-machine ' + status.toLowerCase() + '" data-cicd-machine="' + esc(name) +
            '" data-cicd-status="' + status + '">' +
            '<div class="cicd-machine-head"><span><strong>' + esc(name) + '</strong> <span class="cicd-host">' +
            esc(m.hostname) + '</span></span>' +
            badgeHtml + '</div>' +
            '<div class="cicd-machine-meta">' + meta + '</div>' +
            (note ? '<div class="cicd-stale-note">' + esc(note) + '</div>' : '') +
            runnersHtml + '</div>';
    }

    function resultHtml(result) {
        var known = { success: 1, failure: 1, cancelled: 1, skipped: 1 };
        var key = typeof result === 'string' && known[result] ? result : 'unknown';
        var text = key === 'unknown' ? (result == null || result === '' ? 'unknown' : result) : result;
        return '<span class="cicd-result ' + key + '">' + esc(text) + '</span>';
    }

    function collectJobs(machines) {
        var jobs = [];
        machines.forEach(function(m) {
            (m && Array.isArray(m.recentJobs) ? m.recentJobs : []).forEach(function(j) {
                if (j && typeof j === 'object') jobs.push(j);
            });
        });
        // Newest first; unparseable times sink to the bottom. Array.sort is stable.
        jobs.sort(function(a, b) {
            var x = ts(a.startedAt); var y = ts(b.startedAt);
            if (isNaN(x) && isNaN(y)) return 0;
            if (isNaN(x)) return 1;
            if (isNaN(y)) return -1;
            return y - x;
        });
        return jobs.slice(0, MAX_JOBS_RENDERED);
    }

    function jobRowHtml(j, idx) {
        var label = j.job != null ? j.job : j.workflow;
        var stamp = utcStamp(j.startedAt);
        return '<tr data-cicd-job="' + esc(j.id) + '">' +
            '<td>' + (stamp ? '<time datetime="' + esc(j.startedAt) + '" title="' + esc(j.startedAt) + '">' + esc(stamp) + '</time>' : dashHtml()) + '</td>' +
            '<td class="cicd-wrap">' + esc(j.runner) + '</td>' +
            '<td class="cicd-wrap">' + esc(j.workflow) + (j.job != null && j.job !== j.workflow ? ' / ' + esc(j.job) : '') + '</td>' +
            '<td class="cicd-wrap">' + esc(j.branch) + '</td>' +
            '<td class="cicd-num">' + durHtml(j.durationSeconds) + '</td>' +
            '<td class="cicd-num">' + numOrDash(j.minutes) + '</td>' +
            '<td>' + resultHtml(j.result) + '</td>' +
            '<td>' + logLinkHtml(j, label, 'LOG', 'job:' + (j.id != null ? j.id : 'idx' + idx)) + '</td></tr>';
    }

    function jobsHtml(jobs) {
        var rows = jobs.length
            ? jobs.map(jobRowHtml).join('')
            : '<tr><td colspan="8" class="cicd-sub">No recent jobs reported</td></tr>';
        return '<h3 class="cicd-subhead">RECENT JOBS</h3>' +
            '<div class="cicd-jobs-wrap" tabindex="0" role="region" aria-label="Recent CI jobs" data-cicd-focus="jobs-wrap">' +
            '<table class="cicd-jobs"><caption class="cicd-sr-only">Recent CI jobs, newest first</caption>' +
            '<thead><tr><th scope="col">TIME</th><th scope="col">RUNNER</th><th scope="col">WORKFLOW/JOB</th>' +
            '<th scope="col">BRANCH</th><th scope="col">DUR</th><th scope="col">MIN</th>' +
            '<th scope="col">RESULT</th><th scope="col">LOG</th></tr></thead><tbody>' + rows + '</tbody></table></div>';
    }

    function emptyStateHtml(title, text, attr) {
        return '<div class="empty-state"' + (attr ? ' ' + attr : '') + '>' +
            (title ? '<div class="empty-state-title">' + esc(title) + '</div>' : '') +
            '<div class="empty-state-text">' + esc(text) + '</div></div>';
    }

    function bodyHtml(data) {
        var machines = Array.isArray(data.machines) ? data.machines : [];
        var html = '';
        if (isNum(data.schemaVersion) && data.schemaVersion > 1) {
            html += '<div class="cicd-stale-note">Newer data format - some fields may not display</div>';
        }
        html += summaryHtml(data.summary);
        html += '<h3 class="cicd-subhead">MACHINES</h3>';
        if (!machines.length) {
            html += emptyStateHtml('NO CI RUNNERS REPORTING',
                'No machine has pushed runner telemetry yet. See docs/ci-runner-runbook.md (runbook) to enroll a runner.',
                'data-cicd-empty');
        } else {
            html += machines.map(function(m) { return machineHtml(m, data); }).join('');
            html += jobsHtml(collectJobs(machines));
        }
        return html;
    }

    // =========================================================================
    // DOM: skeleton + focus/scroll preservation
    // =========================================================================

    function slot(container, name) {
        return container.querySelector('[data-cicd-slot="' + name + '"]');
    }

    // The skeleton is built once. Its two live regions (fallback pills, failure
    // badge) persist across polls so they only announce when their content changes.
    function ensureSkeleton(container) {
        if (container.querySelector('[data-cicd-root]')) return;
        container.innerHTML =
            '<div class="cicd-root" data-cicd-root>' +
            '<div class="cicd-fallback-bar">' +
            '<span class="cicd-label">FALLBACK SWITCH</span>' +
            '<div class="cicd-pills" role="status" aria-live="polite" aria-atomic="true" data-cicd-slot="pills"></div>' +
            '<span class="cicd-sub" data-cicd-slot="checked"></span>' +
            '</div>' +
            '<div class="cicd-statusline">' +
            '<span class="cicd-sub" data-cicd-slot="updated"></span>' +
            '<span role="status" data-cicd-slot="status"></span>' +
            '</div>' +
            '<div data-cicd-slot="body"></div>' +
            '</div>';
    }

    function captureView(container) {
        var view = { scrollLeft: 0, scrollTop: 0, focusKey: null };
        var wrap = container.querySelector('.cicd-jobs-wrap');
        if (wrap) { view.scrollLeft = wrap.scrollLeft; view.scrollTop = wrap.scrollTop; }
        var active = container.ownerDocument.activeElement;
        if (active && container.contains(active) && active.getAttribute) {
            view.focusKey = active.getAttribute('data-cicd-focus');
        }
        return view;
    }

    function restoreView(container, view) {
        var wrap = container.querySelector('.cicd-jobs-wrap');
        if (wrap) { wrap.scrollLeft = view.scrollLeft; wrap.scrollTop = view.scrollTop; }
        if (view.focusKey) {
            var nodes = container.querySelectorAll('[data-cicd-focus]');
            for (var i = 0; i < nodes.length; i++) {
                if (nodes[i].getAttribute('data-cicd-focus') === view.focusKey) {
                    try { nodes[i].focus({ preventScroll: true }); } catch (e) { /* focus is best-effort */ }
                    break;
                }
            }
        }
    }

    function setStatus(container, failed) {
        var el = slot(container, 'status');
        if (!el) return;
        if (!failed) { el.innerHTML = ''; return; }
        var good = _lastGood ? utcClock(_lastGood.generatedAt) : null;
        el.innerHTML = '<span class="cicd-update-failed" data-cicd-update-failed>UPDATE FAILED</span>' +
            (good ? ' <span class="cicd-sub">last good: ' + esc(good) + '</span>' : '');
    }

    // =========================================================================
    // PUBLIC: render / renderUnavailable
    // =========================================================================

    function render(data, container) {
        if (!container || !data || typeof data !== 'object') return;
        var view = captureView(container);
        ensureSkeleton(container);

        // Fallback bar: only touch the live region when its content changes.
        var pills = slot(container, 'pills');
        var pillsMarkup = pillsHtml(data.fallback);
        if (pills.innerHTML !== pillsMarkup) pills.innerHTML = pillsMarkup;
        slot(container, 'checked').innerHTML = checkedHtml(data);
        var upd = utcClock(data.generatedAt);
        slot(container, 'updated').textContent = upd ? 'UPDATED ' + upd : '';

        slot(container, 'body').innerHTML = bodyHtml(data);
        _lastGood = data;
        setStatus(container, false);
        restoreView(container, view);
    }

    function renderUnavailable(container) {
        if (!container) return;
        _lastGood = null;
        container.innerHTML = emptyStateHtml('CI TELEMETRY NOT AVAILABLE',
            'CI telemetry not available on this server.', 'data-cicd-unavailable');
    }

    function renderFailure(container) {
        if (!container) return;
        if (_lastGood && container.querySelector('[data-cicd-root]')) {
            // Keep the last good render untouched (focus/scroll safe); just badge it.
            setStatus(container, true);
            return;
        }
        ensureSkeleton(container);
        slot(container, 'body').innerHTML = emptyStateHtml('CI DATA UNAVAILABLE', 'CI DATA UNAVAILABLE - retrying');
        setStatus(container, true);
    }

    // =========================================================================
    // PUBLIC: refresh
    // =========================================================================

    function validPayload(data) {
        return !!data && typeof data === 'object' && isNum(data.schemaVersion) && data.schemaVersion >= 1 &&
            !isNaN(ts(data.generatedAt));
    }

    function doRefresh() {
        var container = document.getElementById(CONTAINER_ID);
        if (!container) return Promise.resolve();
        // Resolve window.fetch at call time (tests and the auth wrapper both swap it).
        return Promise.resolve().then(function() {
            return window.fetch(CI_RUNNERS_API, { credentials: 'same-origin' });
        }).then(function(resp) {
            if (resp && resp.status === 404) {
                if (!_loggedUnavailable) {
                    _loggedUnavailable = true;
                    console.info('[CICD] /api/ci-runners not available on this server (404)');
                }
                renderUnavailable(container);
                return null;
            }
            if (!resp || !resp.ok) throw new Error('HTTP ' + (resp ? resp.status : '?'));
            return resp.json().then(function(data) {
                if (!validPayload(data)) throw new Error('unexpected payload');
                _loggedUnavailable = false;
                render(data, container);
                return null;
            });
        }).catch(function(err) {
            try {
                renderFailure(container);
            } catch (e) { /* never reject */ }
            if (typeof console !== 'undefined' && console.warn) {
                console.warn('[CICD] refresh failed:', err && err.message);
            }
            return null;
        });
    }

    // XACA-1444-002: pool cards + queue/banners, same cadence as the runners view.
    // Skipped entirely when neither module is loaded (keeps the XACA-1388 harness
    // and any page without the pool assets byte-identical in behaviour).
    function poolModules() {
        return [
            { mod: window.LCARSCIPool, el: document.getElementById('cicd-pool') },
            { mod: window.LCARSCIQueue, el: document.getElementById('cicd-queue') }
        ].filter(function(m) { return m.mod && typeof m.mod.render === 'function' && m.el; });
    }

    function hidePool(mods) {
        // XACA-1444-022: drop the pool's modal inert state BEFORE its container is cleared/hidden.
        try { if (window.LCARSCIPool && typeof window.LCARSCIPool.teardown === 'function') window.LCARSCIPool.teardown(); } catch (e) { /* never block the hide */ }
        mods.forEach(function(m) { m.el.innerHTML = ''; m.el.hidden = true; });
    }

    function doPoolRefresh() {
        var mods = poolModules();
        if (!mods.length) return Promise.resolve();
        return Promise.resolve().then(function() {
            return window.fetch(CI_POOL_API, { credentials: 'same-origin' });
        }).then(function(resp) {
            if (!resp || !resp.ok) { hidePool(mods); return null; }
            return resp.json().then(function(body) {
                if (!body || typeof body !== 'object' || !body.machines || typeof body.machines !== 'object') {
                    hidePool(mods);
                    return null;
                }
                mods.forEach(function(m) {
                    try { m.mod.render(body, m.el, { document: document }); } catch (e) {
                        try { if (m.mod.teardown) m.mod.teardown(); } catch (e2) { /* ignore */ }
                        m.el.hidden = true;
                    }
                });
                return null;
            });
        }).catch(function() {
            try { hidePool(mods); } catch (e) { /* never reject */ }
            return null;
        });
    }

    function refresh() {
        if (_inflight) return _inflight;
        _inflight = Promise.all([doRefresh(), doPoolRefresh()]).then(function() { _inflight = null; }, function() { _inflight = null; });
        return _inflight;
    }

    // =========================================================================
    // WIRING
    // =========================================================================

    window.LCARSCICD = {
        deriveMachineStatus: deriveMachineStatus,
        deriveRunnerStatus: deriveRunnerStatus,
        render: render,
        renderUnavailable: renderUnavailable,
        refresh: refresh
    };

    function init() {
        // One immediate fetch on activation. The periodic refresh is driven by
        // lcars-dashboard-app.js's existing cycle, only while this section is active.
        document.addEventListener('lcars:sectionChange', function(e) {
            if (e.detail && e.detail.section === 'cicd') refresh();
        });
        // A successful pool write (Enable/Pause/Resume) refreshes immediately.
        var poolEl = document.getElementById('cicd-pool');
        if (poolEl) poolEl.addEventListener('cicd-pool:changed', function() { refresh(); });
        if (document.querySelector('.lcars-section.active[data-section="cicd"]')) refresh();
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }

})();

// === /XACA-1388 ===
