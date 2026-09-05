//
//  app-factory.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * Test App Factory
 * Creates a fresh Express app with the same routes as server.js but with
 * injectable in-memory state (no file I/O, no server listen, no setInterval).
 *
 * This lets us test route handlers in isolation without touching real data files
 * or starting a server on a live port.
 */

const express = require('express');
const cors = require('cors');
const path = require('path');
const fs = require('fs');
const os = require('os');

// ============================================================================
// PURE HELPER FUNCTIONS (mirrored from server.js — must stay in sync)
// ============================================================================

const OFFLINE_THRESHOLD_MS = 180 * 1000;
const WARNING_THRESHOLD_MS = 120 * 1000;

function formatDuration(ms) {
    if (ms < 1000) return 'just now';
    const seconds = Math.floor(ms / 1000);
    if (seconds < 60) return `${seconds}s`;
    const minutes = Math.floor(seconds / 60);
    if (minutes < 60) return `${minutes}m`;
    const hours = Math.floor(minutes / 60);
    if (hours < 24) return `${hours}h ${minutes % 60}m`;
    const days = Math.floor(hours / 24);
    return `${days}d ${hours % 24}h`;
}

function formatUptime(seconds) {
    const days = Math.floor(seconds / 86400);
    const hours = Math.floor((seconds % 86400) / 3600);
    const minutes = Math.floor((seconds % 3600) / 60);
    if (days > 0) return `${days}d ${hours}h ${minutes}m`;
    if (hours > 0) return `${hours}h ${minutes}m`;
    return `${minutes}m`;
}

// Mirrored from server.js's resolveDivisionKey/ensureTeamBucket (XACA-0983
// fix (b)) -- MUST stay in sync with the real implementation, same as every
// other function in this section. See server.js for the full rationale
// comment; not repeated here to avoid drift between two copies of the same
// prose.
function resolveDivisionKey(division, project) {
    if (division === 'freelance' && project) {
        const projectSuffix = project.replace('doublenode-', '');
        const divisionKey = `freelance-${projectSuffix}`;
        return { divisionKey, divisionName: divisionKey };
    }
    return { divisionKey: division, divisionName: division };
}

function ensureTeamBucket(divisions, divisionKey, divisionName, projectKey, projectName, team) {
    if (!divisions[divisionKey]) {
        divisions[divisionKey] = { name: divisionName, total_sessions: 0, projects: {} };
    }
    if (!divisions[divisionKey].projects[projectKey]) {
        divisions[divisionKey].projects[projectKey] = { name: projectName, teams: {} };
    }
    if (!divisions[divisionKey].projects[projectKey].teams[team]) {
        divisions[divisionKey].projects[projectKey].teams[team] = { name: team, sessions: [] };
    }
    return divisions[divisionKey].projects[projectKey].teams[team];
}

// Mirrored from server.js's resolveRegistryKey (XACA-1002) -- MUST stay in
// sync with the real implementation, same discipline as resolveDivisionKey/
// ensureTeamBucket above. See server.js for the full rationale comment
// (registry-key -> {division, project} inversion, 4-tier precedence,
// `project === undefined` means `_default`); not repeated here to avoid
// drift between two copies of the same prose.
//
// `liveDivisions` MUST be a snapshot of the divisions that existed BEFORE
// any idle bucket was materialized -- see server.js's header comment on
// ensureRegisteredTeamBuckets for the Map-insertion-order hazard this
// guards against (tests/xaca-1002-registered-team-buckets.test.js's
// determinism test exercises this directly).
function resolveRegistryKey(registryKey, liveDivisions) {
    // 1. Exact division match -- the registry key already IS a live division key.
    if (liveDivisions[registryKey]) {
        const projects = liveDivisions[registryKey];
        let project; // undefined => projectKey resolves to '_default'
        if (projects.indexOf('_default') !== -1) {
            project = undefined;
        } else {
            project = projects.length === 1 ? projects[0] : undefined;
        }
        return { division: registryKey, project };
    }

    // 2. freelance-<project> -- e.g. "freelance-doublenode-starwords".
    // Division strips "doublenode-" (via resolveDivisionKey); project keeps it.
    if (registryKey.startsWith('freelance-')) {
        const rest = registryKey.slice('freelance-'.length);
        const { divisionKey } = resolveDivisionKey('freelance', rest);
        return { division: divisionKey, project: rest };
    }

    // 3. <div>-<project> -- split at the FIRST hyphen (e.g. "legal-coparenting").
    const hyphenIdx = registryKey.indexOf('-');
    if (hyphenIdx !== -1) {
        const div = registryKey.slice(0, hyphenIdx);
        const proj = registryKey.slice(hyphenIdx + 1);
        const { divisionKey } = resolveDivisionKey(div, proj);
        return { division: divisionKey, project: proj };
    }

    // 4. Bare key -- no hyphen at all (e.g. "dns", "academy").
    return { division: registryKey, project: undefined };
}

function generateUUID() {
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) {
        const r = Math.random() * 16 | 0;
        const v = c === 'x' ? r : (r & 0x3 | 0x8);
        return v.toString(16);
    });
}

function generateDashboardId(name) {
    return name.toLowerCase()
        .replace(/[^a-z0-9]+/g, '-')
        .replace(/^-|-$/g, '')
        .substring(0, 30);
}

function calcBoardStats(teamId, board) {
    const backlog = board.backlog || [];
    const epics = board.epics || [];
    const sevenDaysAgo = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000);

    const statusCounts = {};
    let totalCompleted = 0;

    for (const item of backlog) {
        const status = item.status || 'undefined';
        statusCounts[status] = (statusCounts[status] || 0) + 1;
        if (status === 'completed') totalCompleted++;
    }

    const totalItems = backlog.length;
    const completionRate = totalItems > 0
        ? Math.round((totalCompleted / totalItems) * 1000) / 10
        : 0;

    const epicStats = epics.map(epic => {
        const itemIds = new Set(epic.itemIds || []);
        const epicItems = backlog.filter(item => itemIds.has(item.id));
        const epicTotal = epicItems.length;
        const epicCompleted = epicItems.filter(i => i.status === 'completed').length;
        const epicProgress = epicTotal > 0
            ? Math.round((epicCompleted / epicTotal) * 1000) / 10
            : 0;
        return {
            id: epic.id,
            name: epic.shortTitle || epic.title || epic.id,
            status: epic.status || 'active',
            totalItems: epicTotal,
            completedItems: epicCompleted,
            progress: epicProgress
        };
    });

    let subTotal = 0;
    let subCompleted = 0;
    for (const item of backlog) {
        const subs = item.subitems || [];
        subTotal += subs.length;
        subCompleted += subs.filter(s => s.status === 'completed').length;
    }

    let completedLast7Days = 0;
    let createdLast7Days = 0;
    for (const item of backlog) {
        if (item.completedAt && new Date(item.completedAt) > sevenDaysAgo) completedLast7Days++;
        if (item.addedAt && new Date(item.addedAt) > sevenDaysAgo) createdLast7Days++;
    }

    return {
        teamId,
        displayName: board.teamName || teamId.charAt(0).toUpperCase() + teamId.slice(1),
        statusCounts,
        totalItems,
        completionRate,
        epics: epicStats,
        subitemStats: { total: subTotal, completed: subCompleted, pending: subTotal - subCompleted },
        recentActivity: { completedLast7Days, createdLast7Days }
    };
}

// XACA-1031-007: mirrored VERBATIM from server.js's isVersionOutdated() and
// normalizeSystemBlock() (both pure, module-level -- no closure state) --
// MUST stay in sync with the real implementation, same discipline as every
// other function in this section. server.js's own doc comments (search
// "isVersionOutdated" / "normalizeSystemBlock" there) carry the full
// contract rationale; not repeated here to avoid drift between two copies
// of the same prose. This pair, plus projectSystemBlock() (defined inside
// createApp() below -- it is NOT pure, it reads the injectable
// latest-tap-version cache), were absent from this mirror when XACA-1031
// shipped server.js's real changes -- see the XACA-1031-007 test suite for
// the regression coverage that gap would otherwise have left unexercised.
function isVersionOutdated(current, latest) {
    if (typeof current !== 'string' || typeof latest !== 'string' || !current.trim() || !latest.trim()) return null;

    const parse = (v) => {
        const stripped = v.trim().replace(/^v/i, '');
        if (!stripped) return null;
        const parts = stripped.split('.');
        const nums = parts.map((p) => (/^\d+$/.test(p) ? Number(p) : NaN));
        if (nums.some((n) => Number.isNaN(n))) return null;
        return nums;
    };

    const currentParts = parse(current);
    const latestParts = parse(latest);
    if (!currentParts || !latestParts) return null;

    const len = Math.max(currentParts.length, latestParts.length);
    for (let i = 0; i < len; i++) {
        const c = currentParts[i] || 0;
        const l = latestParts[i] || 0;
        if (c < l) return true;
        if (c > l) return false;
    }
    return false; // equal versions -- not outdated
}

// XACA-1091-018/019 review: mirrored VERBATIM from server.js -- see that
// file's comment above these same four functions for the full rationale
// (Number.isFinite alone admits negatives/absurd magnitudes; range checks
// are the only numeric-leaf validation used below; out-of-range values are
// OMITTED, never clamped; explicit >=/<= comparisons so a collected zero
// survives).
function isValidByteCount(n) {
    return Number.isFinite(n) && n >= 0;
}

function isValidPercent(n) {
    return Number.isFinite(n) && n >= 0 && n <= 100;
}

function isValidLoadAverageComponent(n) {
    return Number.isFinite(n) && n >= 0;
}

function isValidPositiveInteger(n) {
    return Number.isInteger(n) && n > 0;
}

// XACA-1091-005: telemetry leaves mirrored VERBATIM from server.js's own
// extension of this function -- same drift-guard discipline as the
// pre-existing pair above.
function normalizeSystemBlock(system) {
    if (!system || typeof system !== 'object' || Array.isArray(system)) return {}; // whole block absent (an array is not a valid system block, even though typeof [] === 'object')

    const out = {};
    if (Number.isInteger(system.schema_version)) {
        out.schema_version = system.schema_version;
    }

    const inVersions = (system.versions && typeof system.versions === 'object') ? system.versions : {};
    const versions = {};
    if (typeof inVersions.aiteamforge === 'string' && inVersions.aiteamforge) {
        versions.aiteamforge = inVersions.aiteamforge; // omitted entirely otherwise
    }
    out.versions = versions;

    if (typeof system.os_version === 'string' && system.os_version) out.os_version = system.os_version;
    if (typeof system.os_build === 'string' && system.os_build) out.os_build = system.os_build;
    if (typeof system.os_name === 'string' && system.os_name) out.os_name = system.os_name;
    if (typeof system.model === 'string' && system.model) out.model = system.model;
    if (typeof system.arch === 'string' && system.arch) out.arch = system.arch;
    if (isValidPositiveInteger(system.cores)) out.cores = system.cores;
    if (isValidByteCount(system.total_ram)) out.total_ram = system.total_ram;
    if (isValidPositiveInteger(system.boot_time)) out.boot_time = system.boot_time;

    if (system.memory && typeof system.memory === 'object') {
        const memory = {};
        if (isValidByteCount(system.memory.used)) memory.used = system.memory.used;
        if (isValidByteCount(system.memory.total)) memory.total = system.memory.total;
        if (isValidPercent(system.memory.pressure_percent)) memory.pressure_percent = system.memory.pressure_percent;
        if (Object.keys(memory).length > 0) out.memory = memory;
    }

    if (isValidByteCount(system.swap_used_bytes)) out.swap_used_bytes = system.swap_used_bytes;

    if (system.disk && typeof system.disk === 'object') {
        const disk = {};
        if (isValidByteCount(system.disk.used)) disk.used = system.disk.used;
        if (isValidByteCount(system.disk.free)) disk.free = system.disk.free;
        if (isValidPercent(system.disk.percent)) disk.percent = system.disk.percent;
        if (Object.keys(disk).length > 0) out.disk = disk;
    }

    if (Array.isArray(system.load_average) && system.load_average.length === 3 && system.load_average.every((n) => isValidLoadAverageComponent(n))) {
        out.load_average = system.load_average.slice();
    }

    return out;
}

// ============================================================================
// APP FACTORY
// ============================================================================

/**
 * Create a test Express app.
 *
 * @param {object} opts
 * @param {Map}    opts.machines        - Pre-populated machine state (optional)
 * @param {Map}    opts.registeredTeams - Pre-populated team state (optional)
 * @param {Map}    opts.pushedBoards    - Pre-populated board state (optional)
 * @param {Map}    opts.pushedKnowledge - Pre-populated knowledge state (optional)
 * @param {string} opts.tmpDir          - Temp dir for dashboard config files (optional)
 * @returns {{ app, state, tmpDir }} - Express app + mutable state references + temp dir path
 */
function createApp(opts = {}) {
    const machines = opts.machines || new Map();
    const registeredTeams = opts.registeredTeams || new Map();
    const pushedBoards = opts.pushedBoards || new Map();
    const pushedKnowledge = opts.pushedKnowledge || new Map();
    const tmpDir = opts.tmpDir || fs.mkdtempSync(path.join(os.tmpdir(), 'fleet-test-'));

    // XACA-1031-007: mirrors server.js's `latestTapVersion` module-level
    // cache variable, but WITHOUT the real network fetch/TTL machinery --
    // getLatestTapVersion() in server.js resolves from a background-refreshed
    // cache and is deliberately fire-and-forget/never-throws, which makes its
    // FAILURE mode (cache never populated, or last fetch failed) impossible
    // to drive deterministically through a real network call in a test.
    // This mutable box is that cache's test seam: seed it via
    // opts.latestTapVersion (default null, matching the real cache's
    // pre-first-fetch state), or mutate `state.latestTapVersionState.value`
    // after createApp() to simulate a resolve/fail transition mid-test.
    const latestTapVersionState = { value: opts.latestTapVersion !== undefined ? opts.latestTapVersion : null };
    function getLatestTapVersion() {
        return latestTapVersionState.value;
    }

    // Mirrored VERBATIM from server.js's projectSystemBlock() -- see
    // server.js for the full contract rationale comment. Defined INSIDE
    // createApp() (unlike isVersionOutdated/normalizeSystemBlock above,
    // which are pure and module-level) because it closes over this
    // factory instance's own getLatestTapVersion(), same reasoning as
    // ensureRegisteredTeamBuckets closing over `registeredTeams` above.
    // XACA-1091-006: telemetry leaves + early-return fix mirrored VERBATIM
    // from server.js's own extension of this function.
    function projectSystemBlock(storedSystem) {
        const out = {};
        if (!storedSystem || typeof storedSystem !== 'object' || Array.isArray(storedSystem)) return out; // whole-block-absent / pre-XACA-1031 record / corrupted non-object record

        if (Number.isInteger(storedSystem.schema_version)) {
            out.schema_version = storedSystem.schema_version;
        }

        const hasStoredVersions = !!(storedSystem.versions && typeof storedSystem.versions === 'object');
        if (hasStoredVersions) {
            const storedAiteamforge = (typeof storedSystem.versions.aiteamforge === 'string' && storedSystem.versions.aiteamforge)
                ? storedSystem.versions.aiteamforge
                : null;

            const versions = {};
            if (storedAiteamforge) {
                versions.aiteamforge = storedAiteamforge;
                const latest = getLatestTapVersion(); // string or null; never throws, never blocks
                if (latest) {
                    versions.latest = latest;
                    const outdated = isVersionOutdated(storedAiteamforge, latest);
                    if (outdated !== null) {
                        versions.outdated = outdated; // explicit true/false -- a collected fact, not an absence
                    }
                }
            }
            out.versions = versions;
        }

        if (typeof storedSystem.os_version === 'string' && storedSystem.os_version) out.os_version = storedSystem.os_version;
        if (typeof storedSystem.os_build === 'string' && storedSystem.os_build) out.os_build = storedSystem.os_build;
        if (typeof storedSystem.os_name === 'string' && storedSystem.os_name) out.os_name = storedSystem.os_name;
        if (typeof storedSystem.model === 'string' && storedSystem.model) out.model = storedSystem.model;
        if (typeof storedSystem.arch === 'string' && storedSystem.arch) out.arch = storedSystem.arch;
        if (isValidPositiveInteger(storedSystem.cores)) out.cores = storedSystem.cores;
        if (isValidByteCount(storedSystem.total_ram)) out.total_ram = storedSystem.total_ram;
        if (isValidPositiveInteger(storedSystem.boot_time)) out.boot_time = storedSystem.boot_time;

        if (storedSystem.memory && typeof storedSystem.memory === 'object') {
            const memory = {};
            if (isValidByteCount(storedSystem.memory.used)) memory.used = storedSystem.memory.used;
            if (isValidByteCount(storedSystem.memory.total)) memory.total = storedSystem.memory.total;
            if (isValidPercent(storedSystem.memory.pressure_percent)) memory.pressure_percent = storedSystem.memory.pressure_percent;
            if (Object.keys(memory).length > 0) out.memory = memory;
        }

        if (isValidByteCount(storedSystem.swap_used_bytes)) out.swap_used_bytes = storedSystem.swap_used_bytes;

        if (storedSystem.disk && typeof storedSystem.disk === 'object') {
            const disk = {};
            if (isValidByteCount(storedSystem.disk.used)) disk.used = storedSystem.disk.used;
            if (isValidByteCount(storedSystem.disk.free)) disk.free = storedSystem.disk.free;
            if (isValidPercent(storedSystem.disk.percent)) disk.percent = storedSystem.disk.percent;
            if (Object.keys(disk).length > 0) out.disk = disk;
        }

        if (Array.isArray(storedSystem.load_average) && storedSystem.load_average.length === 3 && storedSystem.load_average.every((n) => isValidLoadAverageComponent(n))) {
            out.load_average = storedSystem.load_average.slice();
        }

        return out;
    }

    const activityLog = [];
    const MAX_ACTIVITY_LOG_ENTRIES = 20;

    // Dashboard file in temp dir
    const DASHBOARDS_FILE = path.join(tmpDir, 'dashboards.json');

    // -------------------------------------------------------------------------
    // Internal helpers (use injected state)
    // -------------------------------------------------------------------------

    function getBoardData(teamId) {
        const pushed = pushedBoards.get(teamId);
        if (pushed && pushed.board) return pushed.board;
        return null;
    }

    function getAllTeamIds() {
        return Array.from(pushedBoards.keys());
    }

    function updateMachineStatuses() {
        const now = Date.now();
        for (const [, data] of machines.entries()) {
            const lastSeen = new Date(data.last_seen).getTime();
            const elapsed = now - lastSeen;
            if (elapsed > OFFLINE_THRESHOLD_MS) data.status = 'offline';
            else if (elapsed > WARNING_THRESHOLD_MS) data.status = 'warning';
            else data.status = 'online';
        }
    }

    // Mirrored from server.js's ensureRegisteredTeamBuckets (XACA-1002) --
    // MUST stay in sync with the real implementation. Defined INSIDE
    // createApp() (unlike resolveDivisionKey/ensureTeamBucket/
    // resolveRegistryKey above, which are pure and module-level) because the
    // real server.js version reads the module-scoped `registeredTeams` Map
    // as a free variable rather than a parameter -- mirroring that exactly
    // means this must close over this factory instance's own `registeredTeams`
    // binding (the same one `opts.registeredTeams` seeds and the
    // POST /api/team-register route above mutates), not a copy of it.
    //
    // Returned from createApp() below so tests can call it directly against
    // a hand-built or fixture-derived `divisions` object without going
    // through the full machine/session parsing pipeline -- see server.js for
    // the full rationale comment (never-overwrite, roster-bounded,
    // snapshot-before-mutating-liveDivisions determinism).
    function ensureRegisteredTeamBuckets(divisions) {
        const liveDivisions = {};
        for (const divisionKey of Object.getOwnPropertyNames(divisions)) {
            const projects = (divisions[divisionKey] && divisions[divisionKey].projects) || {};
            liveDivisions[divisionKey] = Object.getOwnPropertyNames(projects);
        }

        for (const [registryKey, teamData] of registeredTeams.entries()) {
            if (!teamData || typeof teamData !== 'object') continue;

            const terminals = teamData.terminals;
            if (!terminals || typeof terminals !== 'object' || Array.isArray(terminals)) continue;

            let division, project;
            try {
                ({ division, project } = resolveRegistryKey(registryKey, liveDivisions));
            } catch (e) {
                // Mirrors server.js: resilient but never silent -- a swallowed
                // failure here makes a registered team's terminals invisible,
                // which is the very defect XACA-1002 fixes.
                console.error(`[XACA-1002] resolveRegistryKey failed for registry key '${registryKey}' -- its terminals will not be rendered:`, e && e.message);
                continue;
            }
            if (!division) {
                console.error(`[XACA-1002] resolveRegistryKey returned no division for registry key '${registryKey}' -- its terminals will not be rendered.`);
                continue;
            }

            const projectKey = project || '_default';

            for (const terminalName of Object.keys(terminals)) {
                if (!terminalName) continue;

                const existingProject = divisions[division] && divisions[division].projects
                    ? divisions[division].projects[projectKey]
                    : null;
                if (existingProject && existingProject.teams && existingProject.teams[terminalName]) {
                    continue;
                }

                const teamBucket = ensureTeamBucket(divisions, division, division, projectKey, project, terminalName);
                teamBucket.idle_registered = {
                    team: registryKey,
                    teamName: teamData.teamName,
                    terminal: terminalName,
                    registeredAt: teamData.registeredAt,
                    lastSeen: teamData.lastSeen
                };
            }
        }
    }

    function parseFleetData() {
        updateMachineStatuses();

        const divisions = {};
        let totalSessions = 0;
        let onlineMachines = 0;
        let offlineMachines = 0;

        for (const [, machineData] of machines.entries()) {
            if (!machineData.machine_id || machineData.machine_id.length < 36) continue;

            if (machineData.status === 'online') {
                onlineMachines++;
                totalSessions += machineData.session_count;
            } else if (machineData.status === 'offline') {
                offlineMachines++;
            }

            if (machineData.status !== 'online') continue;

            for (const session of machineData.sessions || []) {
                const { division, project, team, name, windows, attached, created, uptime_seconds, lcars_port, theme_color, tab_order } = session;

                const { divisionKey, divisionName } = resolveDivisionKey(division, project);
                const projectKey = project || '_default';
                const teamBucket = ensureTeamBucket(divisions, divisionKey, divisionName, projectKey, project, team);

                divisions[divisionKey].total_sessions++;

                teamBucket.sessions.push({
                    name, division, project, team,
                    hostname: machineData.hostname,
                    machine_status: machineData.status,
                    windows, attached, created, uptime_seconds,
                    uptime_display: formatUptime(uptime_seconds || 0),
                    lcars_port, theme_color, tab_order
                });
            }

            // XACA-0983 fix (b) -- mirrors server.js's parseFleetData lcars_services
            // loop. See server.js for the full rationale comment.
            const lcarsServices = Array.isArray(machineData.lcars_services) ? machineData.lcars_services : [];
            for (const svc of lcarsServices) {
                if (!svc || typeof svc !== 'object') continue;
                const { division, project, team, port, reachable, session_name, source } = svc;
                if (!division || !team || !Number.isFinite(Number(port))) continue;

                const { divisionKey, divisionName } = resolveDivisionKey(division, project);
                const projectKey = project || '_default';
                const teamBucket = ensureTeamBucket(divisions, divisionKey, divisionName, projectKey, project, team);

                const existing = teamBucket.lcars_service;
                if (!existing || reachable === true || existing.reachable !== true) {
                    teamBucket.lcars_service = {
                        port: Number(port),
                        reachable: reachable === true ? true : (reachable === false ? false : null),
                        session_name: session_name || null,
                        source: source || 'portfile',
                        hostname: machineData.hostname
                    };
                }
            }
        }

        // XACA-1002 -- mirrors server.js's parseFleetData call site: runs
        // AFTER the machine loop above (so every live session/lcars_service
        // has already claimed its bucket) and BEFORE machineList is built.
        ensureRegisteredTeamBuckets(divisions);

        const machineList = Array.from(machines.values())
            .filter(m => m.machine_id && m.machine_id.length >= 36)
            .map(m => ({
                machine_id: m.machine_id,
                hostname: m.hostname,
                nickname: m.nickname || null,
                ip: m.ip,
                os: m.os,
                status: m.status,
                first_seen: m.first_seen,
                last_seen: m.last_seen,
                session_count: m.session_count,
                sessions: m.sessions,
                uptime_history: m.uptime_history || [],
                // XACA-1031-007: mirrors server.js's machineList allowlist
                // entry `system: projectSystemBlock(m.system)`. This is the
                // step the shipped commit's real allowlist comment calls out
                // as highest-risk -- a field stored via machines.set() but
                // missing from THIS map() silently never reaches /api/fleet.
                system: projectSystemBlock(m.system)
            }));

        return {
            fleet: {
                total_machines: onlineMachines + offlineMachines,
                online_machines: onlineMachines,
                offline_machines: offlineMachines,
                total_sessions: totalSessions,
                divisions,
                machines: machineList
            },
            activityLog,
            last_update: new Date().toISOString()
        };
    }

    function loadDashboardConfig() {
        try {
            if (fs.existsSync(DASHBOARDS_FILE)) {
                return JSON.parse(fs.readFileSync(DASHBOARDS_FILE, 'utf8'));
            }
        } catch (e) { /* fall through */ }
        return { dashboards: [], divisions: [], meta: { version: '1.0.0' } };
    }

    function saveDashboardConfig(config) {
        try {
            config.meta.last_modified = new Date().toISOString();
            fs.writeFileSync(DASHBOARDS_FILE, JSON.stringify(config, null, 2));
            return true;
        } catch (e) {
            return false;
        }
    }

    // -------------------------------------------------------------------------
    // Express app
    // -------------------------------------------------------------------------

    const app = express();
    app.use(cors());
    app.use(express.json({ limit: '10mb' }));

    // Health
    app.get('/api/health', (req, res) => {
        res.json({
            status: 'operational',
            uptime: process.uptime(),
            timestamp: new Date().toISOString(),
            machines_tracked: machines.size,
            registered_teams: registeredTeams.size
        });
    });

    // POST /api/status
    app.post('/api/status', (req, res) => {
        try {
            const { machine, sessions, backup_status, lcars_services, system } = req.body;
            if (!machine || !machine.hostname) {
                return res.status(400).json({ error: 'Missing required field: machine.hostname' });
            }

            const machineKey = machine.machine_id || machine.hostname;
            const now = machine.timestamp || new Date().toISOString();
            const existingMachine = machines.get(machineKey);
            const firstSeen = existingMachine?.first_seen || now;

            const uptimeHistory = existingMachine?.uptime_history || [];
            uptimeHistory.push({ timestamp: now, status: 'online', session_count: (sessions || []).length });
            while (uptimeHistory.length > 48) uptimeHistory.shift();

            const sessionCount = (sessions || []).length;
            const existingNickname = existingMachine?.nickname || null;

            machines.set(machineKey, {
                machine_id: machineKey,
                hostname: machine.hostname,
                nickname: existingNickname,
                ip: machine.ip || 'unknown',
                os: machine.os || 'unknown',
                first_seen: firstSeen,
                last_seen: now,
                status: 'online',
                sessions: sessions || [],
                session_count: sessionCount,
                uptime_history: uptimeHistory,
                backup_status: backup_status || null,
                lcars_services: Array.isArray(lcars_services) ? lcars_services : [],
                // XACA-1031-007: mirrors server.js's POST /api/status
                // `system: normalizeSystemBlock(system)`.
                system: normalizeSystemBlock(system)
            });

            res.status(200).json({
                success: true,
                message: 'Status received',
                sessions_count: sessions.length
            });
        } catch (error) {
            res.status(500).json({ error: 'Internal server error' });
        }
    });

    // GET /api/fleet
    app.get('/api/fleet', (req, res) => {
        try {
            res.json(parseFleetData());
        } catch (error) {
            res.status(500).json({ error: 'Internal server error' });
        }
    });

    // PUT /api/machine/:machineId/nickname
    app.put('/api/machine/:machineId/nickname', (req, res) => {
        try {
            const { machineId } = req.params;
            const { nickname } = req.body;
            const machine = machines.get(machineId);
            if (!machine) return res.status(404).json({ error: 'Machine not found' });
            machine.nickname = nickname && nickname.trim() ? nickname.trim() : null;
            res.json({ success: true, machine_id: machineId, nickname: machine.nickname });
        } catch (error) {
            res.status(500).json({ error: 'Internal server error' });
        }
    });

    // GET /api/machine/:machineId/history — returns empty (no file I/O in tests)
    app.get('/api/machine/:machineId/history', (req, res) => {
        const { machineId } = req.params;
        const limit = parseInt(req.query.limit) || 50;
        const offset = parseInt(req.query.offset) || 0;
        res.json({ machine_id: machineId, total: 0, offset, limit, entries: [] });
    });

    // POST /api/team-register
    app.post('/api/team-register', (req, res) => {
        try {
            const { team, teamName, subtitle, ship, series, organization, orgColor, kanbanDir, fleetMonitorUrl, terminals } = req.body;

            if (!team || !organization || !kanbanDir || !terminals) {
                return res.status(400).json({
                    error: 'Missing required fields',
                    required: ['team', 'organization', 'kanbanDir', 'terminals'],
                    received: { team, organization, kanbanDir, terminals: !!terminals }
                });
            }

            if (typeof terminals !== 'object' || Array.isArray(terminals)) {
                return res.status(400).json({
                    error: 'Invalid terminals field',
                    message: 'terminals must be an object mapping terminal names to metadata'
                });
            }

            const now = new Date().toISOString();
            const existingTeam = registeredTeams.get(team);
            const teamData = {
                team,
                teamName: teamName || team.toUpperCase(),
                subtitle: subtitle || '',
                ship: ship || '',
                series: series || '',
                organization,
                orgColor: orgColor || 'lavender',
                kanbanDir,
                fleetMonitorUrl: fleetMonitorUrl || 'http://localhost:3000',
                terminals,
                registeredAt: existingTeam?.registeredAt || now,
                lastSeen: now
            };

            registeredTeams.set(team, teamData);
            const terminalCount = Object.keys(terminals).length;
            const action = existingTeam ? 'updated' : 'registered';

            res.status(existingTeam ? 200 : 201).json({
                success: true,
                message: `Team '${team}' ${action}`,
                team: teamData.team,
                organization: teamData.organization,
                terminal_count: terminalCount
            });
        } catch (error) {
            res.status(500).json({ error: 'Internal server error' });
        }
    });

    // GET /api/registered-teams
    app.get('/api/registered-teams', (req, res) => {
        try {
            const teams = Array.from(registeredTeams.values()).map(team => ({
                team: team.team,
                teamName: team.teamName,
                subtitle: team.subtitle,
                ship: team.ship,
                series: team.series,
                organization: team.organization,
                orgColor: team.orgColor,
                kanbanDir: team.kanbanDir,
                fleetMonitorUrl: team.fleetMonitorUrl,
                terminalCount: Object.keys(team.terminals).length,
                terminals: team.terminals,
                registeredAt: team.registeredAt,
                lastSeen: team.lastSeen
            })).sort((a, b) => a.team.localeCompare(b.team));
            res.json({ teams, total: teams.length, timestamp: new Date().toISOString() });
        } catch (error) {
            res.status(500).json({ error: 'Internal server error' });
        }
    });

    // POST /api/kanban-push
    app.post('/api/kanban-push', (req, res) => {
        try {
            const body = req.body;
            if (!body || !body.team) {
                return res.status(400).json({ error: 'Missing required field: team', required: ['team'] });
            }
            const teamId = body.team;
            const now = new Date().toISOString();
            pushedBoards.set(teamId, { board: body, pushedAt: now, teamId });
            res.status(200).json({ success: true, team: teamId, pushedAt: now });
        } catch (error) {
            res.status(500).json({ error: 'Internal server error' });
        }
    });

    // POST /api/knowledge-push
    app.post('/api/knowledge-push', (req, res) => {
        try {
            const body = req.body;
            if (!body || !body.team) {
                return res.status(400).json({ error: 'Missing required field: team', required: ['team'] });
            }
            const teamId = body.team;
            const now = new Date().toISOString();
            pushedKnowledge.set(teamId, { knowledge: body.knowledge || {}, pushedAt: now, teamId });
            res.status(200).json({ success: true, team: teamId, pushedAt: now });
        } catch (error) {
            res.status(500).json({ error: 'Internal server error' });
        }
    });

    // GET /api/knowledge-stats
    app.get('/api/knowledge-stats', (req, res) => {
        try {
            const teams = {};
            let totalEntries = 0;
            let totalContributingAgents = 0;
            let teamsWithEntries = 0;
            const allCategories = {};
            const allTags = {};
            const allRecentEntries = [];

            for (const [teamId, data] of pushedKnowledge) {
                const k = data.knowledge || {};
                teams[teamId] = { teamId, ...k, pushedAt: data.pushedAt };
                totalEntries += k.totalEntries || 0;
                totalContributingAgents += k.contributingAgents || 0;
                if ((k.totalEntries || 0) > 0) teamsWithEntries++;

                if (k.categories) {
                    for (const [cat, count] of Object.entries(k.categories)) {
                        allCategories[cat] = (allCategories[cat] || 0) + count;
                    }
                }
                if (k.tags) {
                    for (const [tag, count] of Object.entries(k.tags)) {
                        allTags[tag] = (allTags[tag] || 0) + count;
                    }
                }
                if (k.recentEntries && Array.isArray(k.recentEntries)) {
                    k.recentEntries.forEach(entry => allRecentEntries.push({ ...entry, teamId }));
                }
            }

            allRecentEntries.sort((a, b) => (b.date || '').localeCompare(a.date || ''));
            const topRecentEntries = allRecentEntries.slice(0, 10);
            const topTags = Object.entries(allTags)
                .sort((a, b) => b[1] - a[1])
                .slice(0, 20)
                .map(([tag, count]) => ({ tag, count }));

            res.json({
                teams,
                overall: {
                    totalEntries,
                    teamsWithEntries,
                    totalContributingAgents,
                    categories: allCategories,
                    uniqueCategories: Object.keys(allCategories).length,
                    topTags,
                    uniqueTags: Object.keys(allTags).length,
                    recentEntries: topRecentEntries
                },
                timestamp: new Date().toISOString()
            });
        } catch (error) {
            res.status(500).json({ error: 'Internal server error' });
        }
    });

    // GET /api/kanban-stats
    app.get('/api/kanban-stats', (req, res) => {
        const { team } = req.query;
        try {
            const teamStats = {};
            let teamsToProcess = [];

            if (team) {
                const board = getBoardData(team);
                if (!board) return res.status(404).json({ error: `Team '${team}' not found` });
                teamsToProcess = [team];
            } else {
                teamsToProcess = getAllTeamIds();
            }

            for (const teamId of teamsToProcess) {
                const board = getBoardData(teamId);
                if (!board) {
                    teamStats[teamId] = { teamId, error: 'Board data not available' };
                    continue;
                }
                teamStats[teamId] = calcBoardStats(teamId, board);
            }

            const validTeams = Object.values(teamStats).filter(s => !s.error);
            const overallStatusCounts = {};
            let overallTotal = 0;
            let overallCompleted = 0;

            for (const stats of validTeams) {
                overallTotal += stats.totalItems;
                overallCompleted += stats.statusCounts['completed'] || 0;
                for (const [status, count] of Object.entries(stats.statusCounts)) {
                    overallStatusCounts[status] = (overallStatusCounts[status] || 0) + count;
                }
            }

            const overallCompletionRate = overallTotal > 0
                ? Math.round((overallCompleted / overallTotal) * 1000) / 10
                : 0;

            res.json({
                teams: teamStats,
                overall: {
                    totalTeams: Object.keys(teamStats).length,
                    validTeams: validTeams.length,
                    totalItems: overallTotal,
                    totalCompleted: overallCompleted,
                    overallCompletionRate,
                    statusCounts: overallStatusCounts
                },
                timestamp: new Date().toISOString()
            });
        } catch (error) {
            res.status(500).json({ error: 'Internal server error' });
        }
    });

    // GET /api/working-items
    app.get('/api/working-items', (req, res) => {
        const workingItems = {};
        for (const team of getAllTeamIds()) {
            const board = getBoardData(team);
            if (!board) continue;
            const backlog = board.backlog || [];
            const activeItem = backlog.find(item => item.status === 'actively-working');
            if (activeItem) {
                let activeSubitem = null;
                if (activeItem.subitems && activeItem.subitems.length > 0) {
                    activeSubitem = activeItem.subitems.find(sub => sub.status === 'in_progress');
                }
                workingItems[team] = {
                    id: activeItem.id,
                    title: activeItem.title,
                    status: activeItem.status,
                    subitem: activeSubitem ? {
                        id: activeSubitem.id,
                        title: activeSubitem.title,
                        status: activeSubitem.status
                    } : null
                };
            }
        }
        res.json(workingItems);
    });

    // GET /api/team-config
    app.get('/api/team-config', (req, res) => {
        const { team } = req.query;
        try {
            if (team) {
                const teamData = registeredTeams.get(team);
                if (!teamData) return res.status(404).json({ error: `Team '${team}' not found` });
                return res.json({
                    team: teamData.team,
                    teamName: teamData.teamName,
                    subtitle: teamData.subtitle,
                    ship: teamData.ship,
                    series: teamData.series,
                    organization: teamData.organization,
                    orgColor: teamData.orgColor,
                    terminals: teamData.terminals,
                    registeredAt: teamData.registeredAt,
                    lastSeen: teamData.lastSeen
                });
            }

            const teams = {};
            const organizations = {};
            for (const [teamId, teamData] of registeredTeams.entries()) {
                teams[teamId] = {
                    team: teamData.team,
                    teamName: teamData.teamName,
                    organization: teamData.organization,
                    orgColor: teamData.orgColor,
                    ship: teamData.ship,
                    series: teamData.series,
                    terminals: teamData.terminals,
                    registeredAt: teamData.registeredAt,
                    lastSeen: teamData.lastSeen
                };
                if (!organizations[teamData.organization]) {
                    organizations[teamData.organization] = { color: teamData.orgColor, teams: [] };
                }
                organizations[teamData.organization].teams.push(teamId);
            }
            res.json({ teams, organizations, timestamp: new Date().toISOString() });
        } catch (error) {
            res.status(500).json({ error: 'Internal server error' });
        }
    });

    // GET /api/team-config/:team/terminals
    app.get('/api/team-config/:team/terminals', (req, res) => {
        const { team } = req.params;
        try {
            const teamData = registeredTeams.get(team);
            if (!teamData) return res.status(404).json({ error: `Team '${team}' not found` });
            res.json({ team: teamData.team, terminals: teamData.terminals });
        } catch (error) {
            res.status(500).json({ error: 'Internal server error' });
        }
    });

    // GET /api/epics
    app.get('/api/epics', (req, res) => {
        const allEpics = {};
        for (const team of getAllTeamIds()) {
            const board = getBoardData(team);
            if (!board) continue;
            const epics = board.epics || [];
            const backlog = board.backlog || [];
            if (epics.length > 0) {
                allEpics[team] = epics.map(epic => {
                    const itemIds = epic.itemIds || [];
                    const items = backlog.filter(item => itemIds.includes(item.id));
                    const totalItems = items.length;
                    const completedItems = items.filter(i => i.status === 'completed').length;
                    const cancelledItems = items.filter(i => i.status === 'cancelled').length;
                    const resolvedItems = completedItems + cancelledItems;
                    const percentComplete = totalItems > 0 ? Math.floor((resolvedItems * 100) / totalItems) : 0;
                    return {
                        ...epic,
                        progress: {
                            totalItems, completedItems, cancelledItems, resolvedItems,
                            inProgressItems: items.filter(i => i.status === 'in_progress').length,
                            blockedItems: items.filter(i => i.status === 'blocked').length,
                            todoItems: items.filter(i => i.status === 'todo').length,
                            percentComplete
                        },
                        items: items.map(item => ({
                            id: item.id, title: item.title, status: item.status, priority: item.priority
                        }))
                    };
                });
            }
        }
        res.json(allEpics);
    });

    // GET /api/epics/:team
    app.get('/api/epics/:team', (req, res) => {
        const { team } = req.params;
        try {
            const board = getBoardData(team);
            if (!board) return res.status(404).json({ error: `Team '${team}' not found` });
            const epics = board.epics || [];
            const backlog = board.backlog || [];
            const epicsWithProgress = epics.map(epic => {
                const itemIds = epic.itemIds || [];
                const items = backlog.filter(item => itemIds.includes(item.id));
                const totalItems = items.length;
                const completedItems = items.filter(i => i.status === 'completed').length;
                const cancelledItems = items.filter(i => i.status === 'cancelled').length;
                const resolvedItems = completedItems + cancelledItems;
                const percentComplete = totalItems > 0 ? Math.floor((resolvedItems * 100) / totalItems) : 0;
                return {
                    ...epic,
                    progress: {
                        totalItems, completedItems, cancelledItems, resolvedItems,
                        inProgressItems: items.filter(i => i.status === 'in_progress').length,
                        blockedItems: items.filter(i => i.status === 'blocked').length,
                        todoItems: items.filter(i => i.status === 'todo').length,
                        percentComplete
                    },
                    items: items.map(item => ({
                        id: item.id, title: item.title, status: item.status, priority: item.priority,
                        subitems: (item.subitems || []).map(sub => ({ id: sub.id, title: sub.title, status: sub.status }))
                    }))
                };
            });
            res.json({ team, epics: epicsWithProgress, total: epicsWithProgress.length });
        } catch (error) {
            res.status(500).json({ error: 'Internal server error' });
        }
    });

    // Dashboard routes
    app.get('/api/dashboards', (req, res) => {
        try {
            const config = loadDashboardConfig();
            const dashboards = config.dashboards.sort((a, b) => (a.sort_order || 999) - (b.sort_order || 999));
            res.json({ dashboards, total: dashboards.length });
        } catch (error) {
            res.status(500).json({ error: 'Internal server error' });
        }
    });

    app.put('/api/dashboards/reorder', (req, res) => {
        try {
            const { order } = req.body;
            if (!order || !Array.isArray(order)) {
                return res.status(400).json({ error: 'Order must be an array of dashboard IDs' });
            }
            const config = loadDashboardConfig();
            const existingIds = new Set(config.dashboards.map(d => d.id));
            for (const id of order) {
                if (!existingIds.has(id)) {
                    return res.status(400).json({ error: `Dashboard "${id}" not found` });
                }
            }
            order.forEach((id, index) => {
                const dashboard = config.dashboards.find(d => d.id === id);
                if (dashboard) {
                    dashboard.sort_order = index + 1;
                    dashboard.updated_at = new Date().toISOString();
                }
            });
            config.dashboards.sort((a, b) => (a.sort_order || 999) - (b.sort_order || 999));
            if (saveDashboardConfig(config)) {
                res.json({ success: true, order: config.dashboards.map(d => d.id) });
            } else {
                res.status(500).json({ error: 'Failed to save dashboard configuration' });
            }
        } catch (error) {
            res.status(500).json({ error: 'Internal server error' });
        }
    });

    app.get('/api/dashboards/:id', (req, res) => {
        try {
            const { id } = req.params;
            const config = loadDashboardConfig();
            const dashboard = config.dashboards.find(d => d.id === id);
            if (!dashboard) return res.status(404).json({ error: 'Dashboard not found' });
            res.json(dashboard);
        } catch (error) {
            res.status(500).json({ error: 'Internal server error' });
        }
    });

    app.post('/api/dashboards', (req, res) => {
        try {
            const { name, title, subtitle, description, divisions, machines: dashMachines, org_color } = req.body;
            if (!name || !name.trim()) {
                return res.status(400).json({ error: 'Dashboard name is required' });
            }
            const config = loadDashboardConfig();
            let id = generateDashboardId(name);
            if (config.dashboards.some(d => d.id === id)) {
                let suffix = 2;
                while (config.dashboards.some(d => d.id === `${id}-${suffix}`)) suffix++;
                id = `${id}-${suffix}`;
            }
            const maxOrder = Math.max(0, ...config.dashboards.map(d => d.sort_order || 0));
            const now = new Date().toISOString();
            const newDashboard = {
                id,
                name: name.trim(),
                title: (title || name).toUpperCase().trim(),
                subtitle: (subtitle || 'OPERATIONS MONITOR').toUpperCase().trim(),
                description: description || '',
                url_path: `/lcars/${id}`,
                html_file: `lcars-${id}.html`,
                divisions: divisions || [],
                machines: dashMachines || [],
                org_color: org_color || 'lavender',
                system: false,
                sort_order: maxOrder + 1,
                created_at: now,
                updated_at: now
            };
            config.dashboards.push(newDashboard);
            if (saveDashboardConfig(config)) {
                res.status(201).json(newDashboard);
            } else {
                res.status(500).json({ error: 'Failed to save dashboard configuration' });
            }
        } catch (error) {
            res.status(500).json({ error: 'Internal server error' });
        }
    });

    app.put('/api/dashboards/:id', (req, res) => {
        try {
            const { id } = req.params;
            const { name, title, subtitle, description, divisions, machines: dashMachines, org_color, sort_order, show_all_fleet_on, visible_dashboards } = req.body;
            const config = loadDashboardConfig();
            const index = config.dashboards.findIndex(d => d.id === id);
            if (index === -1) return res.status(404).json({ error: 'Dashboard not found' });
            const dashboard = config.dashboards[index];
            if (name && name.trim()) dashboard.name = name.trim();
            if (title) dashboard.title = title.toUpperCase().trim();
            if (subtitle) dashboard.subtitle = subtitle.toUpperCase().trim();
            if (description !== undefined) dashboard.description = description;
            if (divisions !== undefined) dashboard.divisions = divisions;
            if (dashMachines !== undefined) dashboard.machines = dashMachines;
            if (org_color) dashboard.org_color = org_color;
            if (sort_order !== undefined) dashboard.sort_order = sort_order;
            if (show_all_fleet_on !== undefined) dashboard.show_all_fleet_on = show_all_fleet_on;
            if (visible_dashboards !== undefined) dashboard.visible_dashboards = visible_dashboards;
            dashboard.updated_at = new Date().toISOString();
            if (saveDashboardConfig(config)) {
                res.json(dashboard);
            } else {
                res.status(500).json({ error: 'Failed to save dashboard configuration' });
            }
        } catch (error) {
            res.status(500).json({ error: 'Internal server error' });
        }
    });

    app.delete('/api/dashboards/:id', (req, res) => {
        try {
            const { id } = req.params;
            const config = loadDashboardConfig();
            const index = config.dashboards.findIndex(d => d.id === id);
            if (index === -1) return res.status(404).json({ error: 'Dashboard not found' });
            const dashboard = config.dashboards[index];
            if (dashboard.system) {
                return res.status(403).json({
                    error: 'Cannot delete system dashboard',
                    message: `The "${dashboard.name}" dashboard is a system dashboard and cannot be deleted.`
                });
            }
            config.dashboards.splice(index, 1);
            if (saveDashboardConfig(config)) {
                res.json({ success: true, message: `Dashboard "${dashboard.name}" deleted`, deleted_id: id });
            } else {
                res.status(500).json({ error: 'Failed to save dashboard configuration' });
            }
        } catch (error) {
            res.status(500).json({ error: 'Internal server error' });
        }
    });

    app.get('/api/divisions', (req, res) => {
        try {
            const config = loadDashboardConfig();
            res.json({ divisions: config.divisions || [], total: (config.divisions || []).length });
        } catch (error) {
            res.status(500).json({ error: 'Internal server error' });
        }
    });

    app.get('/api/active-divisions', (req, res) => {
        try {
            const fleetData = parseFleetData();
            const activeDivisions = Object.keys(fleetData.fleet.divisions).map(divKey => {
                const divData = fleetData.fleet.divisions[divKey];
                return { id: divKey, name: divData.name, total_sessions: divData.total_sessions };
            }).sort((a, b) => a.name.localeCompare(b.name));
            res.json({ divisions: activeDivisions, total: activeDivisions.length, source: 'live_fleet_data' });
        } catch (error) {
            res.status(500).json({ error: 'Internal server error' });
        }
    });

    app.get('/api/machines/list', (req, res) => {
        try {
            const fleetData = parseFleetData();
            const machineList = fleetData.fleet.machines.map(m => ({
                machine_id: m.machine_id,
                hostname: m.hostname,
                nickname: m.nickname,
                display_name: m.nickname || m.hostname,
                status: m.status,
                session_count: m.session_count
            })).sort((a, b) => {
                if (a.status !== b.status) return a.status === 'online' ? -1 : 1;
                return a.display_name.localeCompare(b.display_name);
            });
            res.json({
                machines: machineList,
                total: machineList.length,
                online: machineList.filter(m => m.status === 'online').length,
                offline: machineList.filter(m => m.status === 'offline').length
            });
        } catch (error) {
            res.status(500).json({ error: 'Internal server error' });
        }
    });

    // GET /api/backup-status — simplified test version
    app.get('/api/backup-status', (req, res) => {
        const backupMachines = [];
        for (const [machineKey, machineData] of machines) {
            if (machineData.backup_status && machineData.backup_status.boards) {
                backupMachines.push({ machine_id: machineKey, hostname: machineData.hostname, backup_status: machineData.backup_status });
            }
        }

        if (backupMachines.length === 0) {
            return res.json({ status: 'not_configured', lastRun: null, lastRunStatus: 'unknown', totalBackups: 0, boards: {}, sources: [] });
        }

        res.json({ status: 'configured', sources: backupMachines.map(m => ({ hostname: m.hostname })) });
    });

    // Credential routes — not tested (depend on external python CLI)
    // Return 503 to indicate not available in test environment
    app.all('/api/credentials*', (req, res) => {
        res.status(503).json({ error: 'Credential CLI not available in test environment' });
    });

    return {
        app,
        state: { machines, registeredTeams, pushedBoards, pushedKnowledge, activityLog, latestTapVersionState },
        tmpDir,
        // XACA-1002: exposed so a test can call the idle-bucket materializer
        // directly against a hand-built or fixture-derived `divisions` object
        // (this instance's own `registeredTeams` Map is what it reads --
        // seed it via opts.registeredTeams or state.registeredTeams before
        // calling this) without needing a full machine/session round trip.
        ensureRegisteredTeamBuckets,
        parseFleetData,
        // XACA-1031-007: exposed for the same reason -- call directly
        // against a hand-built `storedSystem` object without a full
        // POST+GET round trip. state.latestTapVersionState.value is the
        // deterministic test seam for the cache projectSystemBlock() reads.
        projectSystemBlock
    };
}

// ============================================================================
// EXPORTED PURE FUNCTIONS (testable without HTTP)
// ============================================================================

module.exports = {
    createApp,
    // Export pure functions for unit testing
    helpers: {
        formatDuration,
        formatUptime,
        generateUUID,
        generateDashboardId,
        calcBoardStats,
        // XACA-1002 + XACA-0983: pure, module-level, no registeredTeams
        // closure needed -- safe to export directly (unlike
        // ensureRegisteredTeamBuckets, which is per-createApp()-instance;
        // see createApp()'s return value for that one).
        resolveDivisionKey,
        ensureTeamBucket,
        resolveRegistryKey,
        // XACA-1031-007: pure, module-level, no closure needed -- safe to
        // export directly (unlike projectSystemBlock, which is
        // per-createApp()-instance; see createApp()'s return value for that
        // one).
        isVersionOutdated,
        normalizeSystemBlock
    }
};
