//
//  ci-dispatch-watcher.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1441-003 -- the CI dispatcher's queue watcher (plan D3, Req. 4).
 *
 * Polls GitHub through ci-dispatch-github.js, tracks every job's lifecycle and
 * emits the plain "inter-module job record" (plan, Spike amendments) to onJob.
 * It reports; it does not decide. Fork/allowlist/placement policy belongs to
 * the consumers, so a fork job is reported faithfully with its run.* fields.
 *
 * Cost control (D3 / A5):
 *   - every call is a conditional GET, and a 304 does not spend rate limit;
 *   - run jobs are fetched for a run first seen or whose updated_at moved, plus runs that left the
 *     run lists while still holding open jobs (so a completion is observed, cheaply), plus the
 *     XACA-1445-031 re-reads below;
 *   - cadence is 15 s while anything is queued/in_progress, else 60 s; the
 *     client's rate mode overrides: slow => 60 s, suspended/blocked => no calls
 *     until the reset / retry-after.
 *
 * A6: inProgressAt is the cycle time the watcher first OBSERVED
 * status:"in_progress". GitHub's started_at is populated on queued jobs and is
 * never read here.
 *
 * Pagination (XACA-1441-032): runs lists and job lists are fetched page by page (`&page=N`) while a
 * page holds exactly PAGE_SIZE items, up to MAX_PAGES (a warning is logged at the cap). Every page is
 * its own conditional GET. "Absent from a finished run" may only vanish a job when EVERY page of that
 * run's job list was a fresh 200 and the cap was not hit; a 304 page is a replay, never proof.
 *
 * Live allowlist (XACA-1441-029): `opts.getAllowlist` is read at the start of every cycle, so an added
 * repo is polled and a removed one is dropped (its open jobs are completed as `vanished`) without a
 * restart. The static `opts.allowlist` still works when no getter is given.
 *
 * Re-reads (XACA-1445-031). GitHub's run `updated_at` is a RUN-STATUS clock: it does NOT move when a
 * job is created, picked up, started or even completed while the run's status stays the same
 * (measured live 2026-10-19). Gating job reads on it alone hid queued jobs for minutes and kept
 * already-finished jobs "queued" (ghost JIT mints). So:
 *   F1 every run in the `status=queued` LIST has its jobs re-read EVERY cycle (GitHub keeps a run
 *      queued while any job is queued, so these are exactly the runs holding demand). A run listed
 *      only as in_progress is re-read every IN_PROGRESS_REREAD_CYCLES cycles (~60 s busy), so a
 *      persistent-runner pickup / completion is seen within a minute, not at the next status flip.
 *   F2 a run that leaves the lists, or whose last open job closes, enters a GRACE set and is re-read
 *      every cycle until a read made >= GRACE_MIN_MS after entry shows no open job (covers GitHub's
 *      `max-age=60` cache and the `always()` gate job created ~1 s after a cancel). Bounded: at most
 *      MAX_GRACE_RUNS entries (oldest evicted) and GRACE_MAX_MS each.
 *   F3 a run's read marker (updated_at / run_attempt) is recorded only after a successful jobs
 *      fetch, so a throwing fetch is retried next cycle instead of marking the run as read.
 * All of these are conditional GETs; an unchanged body is a 304 and costs no rate limit.
 *
 * Errors are logged by code/message only. The client's errors are already
 * secret-free; this module never touches a token.
 */

const BUSY_INTERVAL_MS = 15 * 1000;
const IDLE_INTERVAL_MS = 60 * 1000;
const MIN_RESUME_DELAY_MS = 1000;
const COMPLETED_RETENTION_MS = 60 * 60 * 1000;   // keep finished jobs this long for dedupe
const OPEN_JOB_MAX_AGE_MS = 24 * 60 * 60 * 1000; // an "open" job unseen this long is dropped
const MAX_TRACKED_JOBS = 5000;                   // hard cap; oldest completed evicted first
const PAGE_SIZE = 100;                           // per_page on every list call
const MAX_PAGES = 10;                            // XACA-1441-032: pagination cap per list (1000 items)
const IN_PROGRESS_REREAD_CYCLES = 4;             // XACA-1445-031 F1: in_progress-only run backstop (~60 s busy)
const GRACE_MIN_MS = 60 * 1000;                  // XACA-1445-031 F2: >= GitHub's jobs-list max-age=60
const GRACE_MAX_MS = 15 * 60 * 1000;             // XACA-1445-031 F2: a grace entry never outlives this
const MAX_GRACE_RUNS = 200;                      // XACA-1445-031 F2: grace set cap (oldest evicted)

const PRIORITY_LOOKUP_CONCURRENCY = 8;             // XACA-1479: max resolver calls in flight (rate-budget bound)
const FIELD_CAP = 200;                           // XACA-1444: cap on branch / workflow / url strings

/** Display string from untrusted GitHub data: string only, control chars dropped, length-capped, else null. */
function capStr(v, max = FIELD_CAP) {
    if (typeof v !== 'string') return null;
    const t = v.replace(/[\u0000-\u001f\u007f]/g, ' ').trim();
    return t === '' ? null : t.slice(0, max);
}

const SLUG_RE = /^([A-Za-z0-9](?:[A-Za-z0-9-]{0,38}))\/([A-Za-z0-9._-]{1,100})$/;

function normalizeStatus(s) {
    if (s === 'completed') return 'completed';
    if (s === 'in_progress') return 'in_progress';
    return 'queued'; // queued | waiting | pending | requested
}

function parseAllowlist(allowlist, log) {
    const out = [];
    for (const entry of Array.isArray(allowlist) ? allowlist : []) {
        const slug = typeof entry === 'string' ? entry : entry && `${entry.owner}/${entry.repo}`;
        const m = typeof slug === 'string' ? SLUG_RE.exec(slug) : null;
        if (!m) { log('warn', 'watcher: ignoring invalid allowlist entry'); continue; }
        out.push({ owner: m[1], repo: m[2], slug });
    }
    return out;
}

/**
 * @param {object} opts
 * @param {object}   opts.github     createGithubClient() result (conditionalGet, getRateState)
 * @param {string[]} [opts.allowlist]   'owner/repo' strings (static; used when no getAllowlist)
 * @param {Function} [opts.getAllowlist] () => 'owner/repo' strings, read every cycle (live config)
 * @param {Function} [opts.now]        ms clock
 * @param {Function} [opts.setTimer]   (fn, ms) => handle
 * @param {Function} [opts.clearTimer] (handle) => void
 * @param {Function} opts.onJob        (record, change) => void; change is one of
 *   'queued' | 'seen' | 'pickup' | 'in_progress' | 'completed' | 'priority'. 'priority' (XACA-1479-005)
 *   is emitted only when opts.resolvePriority is set and a still-queued job's resolved priority changed
 *   on a TTL refresh. 'seen' is a first
 *   sighting of a job that is already past queued; the catch-up changes follow.
 * @param {Function} [opts.log]        (level, msg) => void
 * @param {Function} [opts.resolvePriority] XACA-1479-005: ({owner, repo, branch, headOwner}) =>
 *   Promise<'critical'|'high'|'normal'> (createPriorityResolver().resolve). When set, every job record
 *   carries `priority`, resolved BEFORE its first emit and refreshed for still-queued jobs every cycle
 *   (the resolver's cache sets the real cadence). Any throw / rejection / unknown value => 'normal'.
 *   When unset the record shape is unchanged.
 */
function createWatcher(opts = {}) {
    const github = opts.github;
    if (!github || typeof github.conditionalGet !== 'function' || typeof github.getRateState !== 'function') {
        throw new TypeError('createWatcher: github client required');
    }
    if (typeof opts.onJob !== 'function') throw new TypeError('createWatcher: onJob required');
    const now = opts.now || Date.now;
    const setTimer = opts.setTimer || ((fn, ms) => { const h = setTimeout(fn, ms); if (h.unref) h.unref(); return h; });
    const clearTimer = opts.clearTimer || clearTimeout;
    const log = typeof opts.log === 'function' ? opts.log : () => {};
    const onJob = opts.onJob;
    const getAllowlist = typeof opts.getAllowlist === 'function' ? opts.getAllowlist : null;
    const resolvePriority = typeof opts.resolvePriority === 'function' ? opts.resolvePriority : null;
    // With a live getter the first cycle's read is the source; parsing the static list too would warn
    // about an invalid entry twice at boot (PR #1086 advisory).
    let repos = getAllowlist ? [] : parseAllowlist(opts.allowlist, log);
    let allowlistKey = getAllowlist ? null : JSON.stringify(opts.allowlist === undefined ? null : opts.allowlist);
    const retentionMs = opts.completedRetentionMs ?? COMPLETED_RETENTION_MS;
    const maxJobs = opts.maxTrackedJobs ?? MAX_TRACKED_JOBS;

    const jobs = new Map(); // key -> { rec, lastSeenMs, completedSeenMs|null }
    // "owner/repo#runId" -> { id, readOk, updatedAt, runAttempt, listedCycle, lastReadCycle, inLists, meta }.
    // readOk/updatedAt/runAttempt/lastReadCycle are the READ MARKER, written only after a successful
    // jobs fetch (XACA-1445-031 F3); listedCycle/inLists/meta are presence, written on every listing.
    const runs = new Map();
    // XACA-1445-031 F2: "owner/repo#runId" -> { owner, repo, slug, id, meta, since, firstAt }
    const grace = new Map();
    let cycle = 0;
    let timer = null;
    let running = false;
    let started = false;
    let inFlight = null;
    const last = { at: null, ok: null, error: null, calls: 0, nextDelayMs: null, mode: 'normal' };

    const iso = (ms) => new Date(ms).toISOString();

    function emit(rec, change) {
        const copy = { ...rec, labels: rec.labels.slice(), run: { ...rec.run } };
        try { onJob(copy, change); } catch (e) { log('error', `watcher: onJob threw (${e && e.message})`); }
    }

    /** Fold one GitHub job into the lifecycle table, emitting changes in order. */
    /** XACA-1479-005: never throws, never blocks past the resolver's own timeout, unknown => 'normal'. */
    // XACA-1479-017: lookups for one cycle are memoised by (owner, repo, headOwner, branch) so distinct
    // entries can be started together (prefetchPriorities / refreshPriorities) and a repeat inside the
    // cycle shares the one promise. Cleared when pollRepo ends; the resolver's own cache spans cycles.
    const prioMemo = new Map();
    // At most PRIORITY_LOOKUP_CONCURRENCY resolver calls in flight across the watcher, so a cold cache or a
    // large queue cannot fire one GitHub request per distinct branch at once against the rate budget. With a
    // hung GitHub, a cycle then costs ceil(N / limit) resolver timeouts, still bounded, and the resolver's
    // timeout cache makes the following cycles immediate.
    let prioActive = 0;
    const prioWaiting = [];
    const prioAcquire = () => (prioActive < PRIORITY_LOOKUP_CONCURRENCY
        ? (prioActive++, Promise.resolve())
        : new Promise((res) => prioWaiting.push(res)));
    const prioRelease = () => { const next = prioWaiting.shift(); if (next) next(); else prioActive--; };

    function priorityFor(owner, repo, branch, headRepoFullName) {
        if (!resolvePriority) return Promise.resolve(null);
        const headOwner = typeof headRepoFullName === 'string' && headRepoFullName.includes('/') ? headRepoFullName.split('/')[0] : owner;
        const mk = `${owner}/${repo}|${headOwner}:${branch}`;
        let p = prioMemo.get(mk);
        if (!p) {
            p = (async () => {
                await prioAcquire();
                try {
                    const v = await resolvePriority({ owner, repo, branch, headOwner });
                    return v === 'critical' || v === 'high' ? v : 'normal';
                } catch (e) {
                    log('warn', `watcher: priority resolver threw (${(e && (e.code || e.message)) || 'error'}); NORMAL`);
                    return 'normal';
                } finally {
                    prioRelease();
                }
            })();
            prioMemo.set(mk, p);
        }
        return p;
    }

    /**
     * XACA-1479-017: start every distinct queued run's lookup at once and wait for them together, so a
     * hung GitHub costs one resolver timeout per cycle, not one per branch. Never throws.
     */
    async function prefetchPriorities(r, listed) {
        if (!resolvePriority) return;
        const work = [];
        for (const wr of listed.values()) {
            if (wr && wr.status === 'queued' && typeof wr.head_branch === 'string') {
                work.push(priorityFor(r.owner, r.repo, capStr(wr.head_branch), (wr.head_repository && wr.head_repository.full_name) ?? null));
            }
        }
        await Promise.allSettled(work);
    }

    function observeJob(owner, repo, run, j, nowMs, touch, priority) {
        const runAttempt = j.run_attempt ?? run.runAttempt ?? 1;
        const key = `${owner}/${repo}#${j.id}#${runAttempt}`;
        const status = normalizeStatus(j.status);
        const runnerName = j.runner_name || null;
        let entry = jobs.get(key);
        const firstSight = !entry;
        if (firstSight) {
            entry = {
                lastSeenMs: nowMs, completedSeenMs: null,
                rec: {
                    key, owner, repo,
                    runId: run.id, runAttempt, jobId: j.id,
                    name: j.name,
                    branch: capStr(run.branch), workflow: capStr(run.workflow), url: capStr(j.html_url, 500),
                    labels: Array.isArray(j.labels) ? j.labels.slice() : [],
                    status: 'queued', conclusion: null, runnerName: null,
                    createdAt: j.created_at || null,
                    firstSeenAt: iso(nowMs), inProgressAt: null, completedAt: null,
                    run: { event: run.event, repoFullName: run.repoFullName, headRepoFullName: run.headRepoFullName },
                },
            };
            if (resolvePriority) entry.rec.priority = priority || 'normal';
            jobs.set(key, entry);
        }
        // A 304 replay of a gone run's cached body is not a sighting: it must not keep the job
        // alive past the prune bound (a run parked in `waiting` returns the same body forever).
        if (touch !== false) entry.lastSeenMs = nowMs;
        const rec = entry.rec;
        if (rec.status === 'completed') return; // terminal; a later re-sighting is not news

        if (firstSight) {
            rec.status = status; rec.runnerName = runnerName;
            if (status === 'queued' && !runnerName) { emit(rec, 'queued'); return; }
            emit(rec, 'seen');
            if (runnerName) emit(rec, 'pickup');
            if (status === 'in_progress' || status === 'completed') { rec.inProgressAt = status === 'in_progress' ? iso(nowMs) : null; }
            if (status === 'in_progress') emit(rec, 'in_progress');
            if (status === 'completed') finish(entry, j, nowMs);
            return;
        }
        if (runnerName && !rec.runnerName) { rec.runnerName = runnerName; emit(rec, 'pickup'); }
        if (status === 'in_progress' && rec.status === 'queued') {
            rec.status = 'in_progress'; rec.inProgressAt = iso(nowMs); emit(rec, 'in_progress');
        }
        if (status === 'completed') finish(entry, j, nowMs);
    }

    function finish(entry, j, nowMs) {
        const rec = entry.rec;
        rec.status = 'completed';
        rec.conclusion = j.conclusion || null;
        rec.completedAt = j.completed_at || iso(nowMs);
        if (j.runner_name && !rec.runnerName) rec.runnerName = j.runner_name;
        entry.completedSeenMs = nowMs;
        emit(rec, 'completed');
    }

    /**
     * An open job left GitHub's view without a completion we could observe (run deleted:
     * 404/410; superseded by a re-run attempt; missing from its run's job list; or unseen for
     * OPEN_JOB_MAX_AGE_MS). Emit a terminal `completed` with conclusion `vanished` so every
     * consumer stops treating it as demand. Without this the dispatcher kept a ghost job and
     * re-minted runners for it on every assignment expiry (XACA-1441 PR #1083 review).
     */
    function vanish(entry, nowMs, why) {
        const rec = entry.rec;
        if (rec.status === 'completed') return;
        rec.status = 'completed';
        rec.conclusion = 'vanished';
        rec.completedAt = iso(nowMs);
        entry.completedSeenMs = nowMs;
        log('warn', `watcher: job ${rec.owner}/${rec.repo}#${rec.jobId} attempt ${rec.runAttempt} vanished (${why})`);
        emit(rec, 'completed');
    }

    /** Open job entries of one run. */
    function openEntriesFor(owner, repo, runId) {
        const out = [];
        for (const e of jobs.values()) {
            const rec = e.rec;
            if (rec.owner === owner && rec.repo === repo && rec.runId === runId && rec.status !== 'completed') out.push(e);
        }
        return out;
    }

    function openJobsFor(owner, repo, runId) {
        for (const { rec } of jobs.values()) {
            if (rec.owner === owner && rec.repo === repo && rec.runId === runId && rec.status !== 'completed') return true;
        }
        return false;
    }

    /**
     * GET a list endpoint page by page (XACA-1441-032). Page 1 is `basePath`; later pages append
     * `&page=N`. Continues while a page holds exactly PAGE_SIZE items, up to MAX_PAGES. Each page is
     * its own conditional GET (a 304 replays the cached body, so its length still steers paging).
     * @returns {{items: object[], allFresh: boolean, capped: boolean}} allFresh: every page was a 200
     */
    async function getPaged(r, basePath, itemsKey) {
        const items = [];
        let allFresh = true;
        let capped = false;
        for (let page = 1; page <= MAX_PAGES; page++) {
            const res = await github.conditionalGet({
                owner: r.owner, repo: r.repo, purpose: 'watcher',
                path: page === 1 ? basePath : `${basePath}&page=${page}`,
            });
            last.calls++;
            const list = res && res.data && Array.isArray(res.data[itemsKey]) ? res.data[itemsKey] : null;
            if (!(res && res.status === 200 && list)) allFresh = false;
            const n = list ? list.length : 0;
            if (list) for (const it of list) items.push(it);
            if (n !== PAGE_SIZE) break;
            if (page === MAX_PAGES) {
                capped = true;
                log('warn', `watcher: ${r.slug} ${itemsKey} list hit the ${MAX_PAGES}-page cap (${PAGE_SIZE * MAX_PAGES}+ items); later pages are not read`);
            }
        }
        return { items, allFresh, capped };
    }

    /**
     * Fetch one run's latest-attempt jobs and fold them in.
     * `gone` = the run has left the queued/in_progress lists, so its job list is final: an open
     * job of ours that a fresh response does not contain has vanished. Fresh means EVERY page was a
     * 200 and the page cap was not hit (XACA-1441-032). For a still-listed run a missing job may just
     * be past the pages we read, so it is left alone. A 304 page replays a cached body, so it never
     * vanishes anything.
     */
    async function fetchJobs(r, run, nowMs, gone) {
        const hadOpen = openJobsFor(r.owner, r.repo, run.id);
        const { items: list, allFresh, capped } = await getPaged(r, `/repos/${r.owner}/${r.repo}/actions/runs/${run.id}/jobs?filter=latest&per_page=${PAGE_SIZE}`, 'jobs');
        // Fresh = every page was a 200 (a 304 page is a replay). A capped list may be missing jobs.
        const fresh = allFresh && !capped;
        const seen = new Set();
        // XACA-1479-005: resolve once per run (cached per branch) and only when a NEW queued job would be
        // emitted, so the dispatcher sees rec.priority on first sight.
        let priority = null;
        if (resolvePriority && list.some((j) => j && normalizeStatus(j.status) === 'queued'
            && !jobs.has(`${r.owner}/${r.repo}#${j.id}#${j.run_attempt ?? run.runAttempt ?? 1}`))) {
            priority = await priorityFor(r.owner, r.repo, capStr(run.branch), run.headRepoFullName);   // same capped value refresh uses
        }
        for (const j of list) {
            observeJob(r.owner, r.repo, run, j, nowMs, fresh || !gone, priority);
            seen.add(`${r.owner}/${r.repo}#${j.id}#${j.run_attempt ?? run.runAttempt ?? 1}`);
        }
        const attempt = Number.isInteger(run.runAttempt) ? run.runAttempt : null;
        for (const e of openEntriesFor(r.owner, r.repo, run.id)) {
            // filter=latest hides an older attempt's jobs: a re-run supersedes them.
            if (attempt !== null && e.rec.runAttempt < attempt) vanish(e, nowMs, `superseded by attempt ${attempt}`);
            else if (gone && fresh && !seen.has(e.rec.key)) vanish(e, nowMs, 'absent from its finished run');
        }
        // F2: our last open job of this run just closed. A follow-on job (an `always()` gate after a
        // cancel, a `needs:` successor) may not be listed yet, and nothing moves updated_at for it.
        if (hadOpen && !openJobsFor(r.owner, r.repo, run.id)) enterGrace(r, run, nowMs);
        return { anyOpen: list.some((j) => j && normalizeStatus(j.status) !== 'completed') };
    }

    /** XACA-1445-031 F2: start a run's grace re-reads, or restart the min window of one already in grace. */
    function enterGrace(r, meta, nowMs) {
        if (!meta || !Number.isInteger(meta.id)) return;
        const rk = `${r.slug}#${meta.id}`;
        const g = grace.get(rk);
        if (g) { g.since = nowMs; g.meta = meta; return; }
        grace.set(rk, { owner: r.owner, repo: r.repo, slug: r.slug, id: meta.id, meta, since: nowMs, firstAt: nowMs });
        while (grace.size > MAX_GRACE_RUNS) {
            let oldestK = null; let oldest = Infinity;
            for (const [k, v] of grace) if (v.firstAt < oldest) { oldest = v.firstAt; oldestK = k; }
            grace.delete(oldestK);
            log('warn', `watcher: grace set full (${MAX_GRACE_RUNS}); evicted the oldest run`);
        }
    }

    /**
     * F2: after a successful grace read, drop the run once a read made >= GRACE_MIN_MS after entry
     * shows no open job (and we hold none). A 304 at that point is proof too: the conditional is
     * evaluated against GitHub's current body, and the cache window has passed.
     */
    function settleGrace(rk, res, nowMs) {
        const g = grace.get(rk);
        if (!g) return;
        if (nowMs - g.firstAt >= GRACE_MAX_MS) { grace.delete(rk); return; }
        if (!res.anyOpen && !openJobsFor(g.owner, g.repo, g.id) && nowMs - g.since >= GRACE_MIN_MS) grace.delete(rk);
    }

    /** A gone run's job fetch failed. 404/410 = the run no longer exists. Rate limits propagate. */
    function onGoneFetchError(r, id, e, nowMs) {
        const status = e && e.status;
        if (status === 404 || status === 410) {
            for (const entry of openEntriesFor(r.owner, r.repo, id)) vanish(entry, nowMs, `run ${status}`);
            return;
        }
        if (e && e.code === 'RATE_LIMITED') throw e;
        // Anything else: skip this run for this cycle, keep checking the others.
        log('warn', `watcher: ${r.slug} run ${id} jobs fetch failed (${(e && (e.code || e.message)) || 'error'}); retrying next cycle`);
    }

    async function pollRepo(r, nowMs) {
        const listed = new Map();
        const queuedIds = new Set(); // F1: membership of the status=queued LIST (wr.status may be absent or lag)
        for (const status of ['queued', 'in_progress']) {
            const { items } = await getPaged(r, `/repos/${r.owner}/${r.repo}/actions/runs?status=${status}&per_page=${PAGE_SIZE}`, 'workflow_runs');
            for (const wr of items) {
                if (!(wr && Number.isInteger(wr.id))) continue;
                listed.set(wr.id, wr);
                if (status === 'queued') queuedIds.add(wr.id);
            }
        }

        try {
            await prefetchPriorities(r, listed);
            return await pollListed(r, nowMs, listed, queuedIds);
        } finally {
            prioMemo.clear();
        }
    }

    async function pollListed(r, nowMs, listed, queuedIds = new Set()) {
        let active = listed.size > 0;
        for (const [id, wr] of listed) {
            const rk = `${r.slug}#${id}`;
            const prev = runs.get(rk);
            const changed = !prev || !prev.readOk || prev.updatedAt !== wr.updated_at || prev.runAttempt !== wr.run_attempt;
            const meta = {
                id, runAttempt: wr.run_attempt, event: wr.event,
                branch: wr.head_branch, workflow: wr.name,
                repoFullName: (wr.repository && wr.repository.full_name) || r.slug,
                headRepoFullName: (wr.head_repository && wr.head_repository.full_name) ?? null,
            };
            // Presence only. The read marker (readOk/updatedAt/runAttempt/lastReadCycle) is written after a
            // successful fetch (F3): a throw leaves it untouched, so the run is re-read next cycle.
            const entry = { readOk: false, lastReadCycle: cycle, ...prev, id, listedCycle: cycle, inLists: true, meta };
            runs.set(rk, entry);
            // A still-listed run is still visible: its open jobs are not "unseen" (prune bound).
            for (const e of openEntriesFor(r.owner, r.repo, id)) e.lastSeenMs = nowMs;
            const queuedListed = queuedIds.has(id);                                                            // F1
            const inProgressDue = !queuedListed && cycle - entry.lastReadCycle >= IN_PROGRESS_REREAD_CYCLES;   // F1 backstop
            const inGrace = grace.has(rk);                                                                     // F2
            if (!(changed || queuedListed || inProgressDue || inGrace)) continue;
            const res = await fetchJobs(r, meta, nowMs);
            entry.readOk = true; entry.updatedAt = wr.updated_at; entry.runAttempt = wr.run_attempt; entry.lastReadCycle = cycle;
            if (inGrace) settleGrace(rk, res, nowMs);
        }

        // F2: a run that just left the lists starts its grace re-reads, whether or not we hold a job of it
        // (shape A: an `always()` gate created ~1 s after a cancel is in none of our earlier reads).
        for (const [rk, e] of runs) {
            if (!e.inLists || listed.has(e.id) || rk !== `${r.slug}#${e.id}`) continue;
            e.inLists = false;
            enterGrace(r, e.meta, nowMs);
        }

        // Runs that left the lists but still hold open jobs, plus grace runs: look again so a completion
        // (or a late-created job) is observed. Conditional, so an unchanged run costs nothing.
        const gone = new Set();
        for (const { rec } of jobs.values()) {
            if (rec.owner === r.owner && rec.repo === r.repo && rec.status !== 'completed' && !listed.has(rec.runId)) gone.add(rec.runId);
        }
        for (const g of grace.values()) if (g.slug === r.slug && !listed.has(g.id)) gone.add(g.id);
        for (const id of gone) {
            const rk = `${r.slug}#${id}`;
            const prev = runs.get(rk);
            const g = grace.get(rk);
            const sample = [...jobs.values()].find((e) => e.rec.owner === r.owner && e.rec.repo === r.repo && e.rec.runId === id);
            let meta = null;
            if (sample) {
                meta = {
                    id, runAttempt: (prev && prev.runAttempt) || sample.rec.runAttempt,
                    branch: sample.rec.branch, workflow: sample.rec.workflow,
                    event: sample.rec.run.event, repoFullName: sample.rec.run.repoFullName,
                    headRepoFullName: sample.rec.run.headRepoFullName,
                };
            } else if (g) {
                meta = g.meta;
            }
            if (!meta) continue;
            try {
                const res = await fetchJobs(r, meta, nowMs, true);
                if (g) settleGrace(rk, res, nowMs);
            } catch (e) {
                // A deleted run has nothing left to show: stop its grace re-reads.
                if (e && (e.status === 404 || e.status === 410)) grace.delete(rk);
                // One deleted run must not abort the loop and hide every other run's completion.
                onGoneFetchError(r, id, e, nowMs);
            }
            if (openJobsFor(r.owner, r.repo, id)) active = true;
        }
        await refreshPriorities(r);
        return active;
    }

    /**
     * XACA-1479-005: re-resolve still-queued jobs' priority (the resolver cache makes this a lookup per
     * branch per TTL, not per cycle) and emit 'priority' on a change. Never throws.
     */
    async function refreshPriorities(r) {
        if (!resolvePriority) return;
        const byBranch = new Map();
        for (const e of jobs.values()) {
            const rec = e.rec;
            if (rec.owner !== r.owner || rec.repo !== r.repo || rec.status !== 'queued' || rec.runnerName || !rec.branch) continue;
            const k = `${rec.branch}\u0000${rec.run.headRepoFullName || ''}`;
            if (!byBranch.has(k)) byBranch.set(k, []);
            byBranch.get(k).push(rec);
        }
        // XACA-1479-017: distinct branches concurrently (each already bounded by the resolver timeout).
        const groups = [...byBranch.values()];
        const answers = await Promise.all(groups.map((recs) => priorityFor(r.owner, r.repo, recs[0].branch, recs[0].run.headRepoFullName)));
        for (let i = 0; i < groups.length; i++) {
            const p = answers[i];
            for (const rec of groups[i]) {
                if (rec.priority === p) continue;
                rec.priority = p;
                emit(rec, 'priority');
            }
        }
    }

    function prune(nowMs) {
        for (const [key, e] of jobs) {
            const doneAged = e.completedSeenMs !== null && nowMs - e.completedSeenMs > retentionMs;
            const openStale = e.completedSeenMs === null && nowMs - e.lastSeenMs > OPEN_JOB_MAX_AGE_MS;
            // Never drop an open job silently: consumers would keep it as demand forever.
            // It is kept (completed/vanished) for the normal retention window, for dedupe.
            if (openStale) { vanish(e, nowMs, 'unseen for 24 h'); continue; }
            if (doneAged) jobs.delete(key);
        }
        if (jobs.size > maxJobs) {
            const done = [...jobs.entries()].filter(([, e]) => e.completedSeenMs !== null)
                .sort((a, b) => a[1].completedSeenMs - b[1].completedSeenMs);
            for (const [key] of done) { if (jobs.size <= maxJobs) break; jobs.delete(key); }
        }
        for (const [rk, g] of grace) if (nowMs - g.firstAt >= GRACE_MAX_MS) grace.delete(rk); // F2 bound
        const live = new Set();
        for (const { rec } of jobs.values()) live.add(`${rec.owner}/${rec.repo}#${rec.runId}`);
        // inLists: kept until pollListed has seen it leave (F2 needs that transition; a failed repo poll
        // would otherwise prune the entry first and the run would never get its grace re-reads).
        for (const [rk, r] of runs) if (r.listedCycle !== cycle && !r.inLists && !live.has(rk)) runs.delete(rk);
    }

    function hasOpenJobs() {
        for (const { rec } of jobs.values()) if (rec.status !== 'completed') return true;
        return false;
    }

    /**
     * XACA-1441-029: re-read the allowlist (when a getter was given). Re-parsed only when it changed,
     * so an invalid entry is warned about once, not every cycle. A repo that left the list has its
     * open jobs completed as `vanished` so no consumer keeps them as demand. A throwing getter keeps
     * the previous list.
     */
    function refreshRepos(nowMs) {
        if (!getAllowlist) return;
        let raw;
        try { raw = getAllowlist(); } catch (e) {
            log('warn', `watcher: allowlist getter threw (${(e && e.message) || 'error'}); keeping the previous list`);
            return;
        }
        const key = JSON.stringify(raw === undefined ? null : raw);
        if (key === allowlistKey) return;
        const firstRead = allowlistKey === null;
        allowlistKey = key;
        repos = parseAllowlist(raw, log);
        const keep = new Set(repos.map((r) => r.slug.toLowerCase()));
        // A removal is NOT a terminal sighting (PR #1086 review). Emit `completed` so consumers stop
        // treating the open jobs as demand, then FORGET the repo entirely: its job entries (else a
        // re-add within the dedupe retention ignores the still-queued job as already terminal) and its
        // run entries (else an unchanged run is never re-fetched). A re-add then sees every job afresh.
        for (const [jk, e] of jobs) {
            if (keep.has(`${e.rec.owner}/${e.rec.repo}`.toLowerCase())) continue;
            if (e.rec.status !== 'completed') vanish(e, nowMs, 'repo removed from the allowlist');
            jobs.delete(jk);
        }
        for (const rk of runs.keys()) {
            const slug = rk.slice(0, rk.lastIndexOf('#')).toLowerCase();
            if (!keep.has(slug)) runs.delete(rk);
        }
        for (const [rk, g] of grace) if (!keep.has(g.slug.toLowerCase())) grace.delete(rk);
        if (!firstRead) log('log', `watcher: allowlist now ${repos.length} repo(s)`);
    }

    /** One polling cycle; resolves to the delay (ms) before the next one. Never throws. */
    async function runCycle() {
        const nowMs = now();
        cycle++;
        refreshRepos(nowMs);
        last.at = iso(nowMs); last.calls = 0; last.error = null;
        const rate = github.getRateState();
        last.mode = rate.mode;
        if (rate.mode === 'suspended' || rate.mode === 'blocked') {
            const until = rate.resumeAt ? rate.resumeAt - nowMs : IDLE_INTERVAL_MS;
            last.ok = false; last.error = `rate ${rate.mode}`;
            last.nextDelayMs = Math.max(MIN_RESUME_DELAY_MS, until);
            return last.nextDelayMs;
        }
        let active = false;
        let failed = false;
        for (const r of repos) {
            try {
                if (await pollRepo(r, nowMs)) active = true;
            } catch (e) {
                failed = true;
                last.error = `${(e && e.code) || 'ERROR'}: ${(e && e.message) || 'unknown'}`;
                log('warn', `watcher: ${r.slug} poll failed (${last.error})`);
                if (e && e.code === 'RATE_LIMITED') break; // the rest would only be refused too
            }
        }
        prune(nowMs);
        if (hasOpenJobs()) active = true; // judged after the polls: a completion seen this cycle is not busy
        last.ok = !failed;
        const rateNow = github.getRateState();
        last.mode = rateNow.mode;
        let delay = active ? BUSY_INTERVAL_MS : IDLE_INTERVAL_MS;
        if (rateNow.mode === 'slow') delay = IDLE_INTERVAL_MS;
        if (rateNow.mode === 'suspended' || rateNow.mode === 'blocked') {
            delay = Math.max(MIN_RESUME_DELAY_MS, rateNow.resumeAt ? rateNow.resumeAt - now() : IDLE_INTERVAL_MS);
        }
        last.nextDelayMs = delay;
        return delay;
    }

    function schedule(ms) {
        if (!started) return;
        timer = setTimer(tick, ms);
    }

    async function tick() {
        timer = null;
        if (!started || running) return;
        running = true;
        let delay = IDLE_INTERVAL_MS;
        try {
            inFlight = runCycle();
            delay = await inFlight;
        } catch (e) { // runCycle should not throw; stay alive regardless
            log('error', `watcher: cycle crashed (${e && e.message})`);
        } finally {
            running = false; inFlight = null;
        }
        schedule(delay);
    }

    function start() {
        if (started) return;
        started = true;
        schedule(0);
    }

    function stop() {
        started = false;
        if (timer !== null) { clearTimer(timer); timer = null; }
    }

    function snapshot() {
        let queued = 0, inProgress = 0, completed = 0;
        for (const { rec } of jobs.values()) {
            if (rec.status === 'queued') queued++;
            else if (rec.status === 'in_progress') inProgress++;
            else completed++;
        }
        return {
            running: started,
            repos: repos.map((r) => r.slug),
            jobs: { queued, inProgress, completed, tracked: jobs.size },
            runsTracked: runs.size,
            runsInGrace: grace.size,
            lastCycle: { at: last.at, ok: last.ok, error: last.error, calls: last.calls, nextDelayMs: last.nextDelayMs },
            rateMode: last.mode,
        };
    }

    return { start, stop, snapshot, runCycle };
}

module.exports = {
    createWatcher, BUSY_INTERVAL_MS, IDLE_INTERVAL_MS, COMPLETED_RETENTION_MS, MAX_TRACKED_JOBS,
    PRIORITY_LOOKUP_CONCURRENCY, IN_PROGRESS_REREAD_CYCLES, GRACE_MIN_MS, GRACE_MAX_MS, MAX_GRACE_RUNS,
};
