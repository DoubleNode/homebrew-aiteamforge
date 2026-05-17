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

                let divisionKey = division;
                let divisionName = division;
                if (division === 'freelance' && project) {
                    const projectSuffix = project.replace('doublenode-', '');
                    divisionKey = `freelance-${projectSuffix}`;
                    divisionName = divisionKey;
                }

                if (!divisions[divisionKey]) {
                    divisions[divisionKey] = { name: divisionName, total_sessions: 0, projects: {} };
                }
                divisions[divisionKey].total_sessions++;

                const projectKey = project || '_default';
                if (!divisions[divisionKey].projects[projectKey]) {
                    divisions[divisionKey].projects[projectKey] = { name: project, teams: {} };
                }
                if (!divisions[divisionKey].projects[projectKey].teams[team]) {
                    divisions[divisionKey].projects[projectKey].teams[team] = { name: team, sessions: [] };
                }
                divisions[divisionKey].projects[projectKey].teams[team].sessions.push({
                    name, division, project, team,
                    hostname: machineData.hostname,
                    machine_status: machineData.status,
                    windows, attached, created, uptime_seconds,
                    uptime_display: formatUptime(uptime_seconds || 0),
                    lcars_port, theme_color, tab_order
                });
            }
        }

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
                uptime_history: m.uptime_history || []
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
            const { machine, sessions, backup_status } = req.body;
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
                backup_status: backup_status || null
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
        state: { machines, registeredTeams, pushedBoards, pushedKnowledge, activityLog },
        tmpDir
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
        calcBoardStats
    }
};
