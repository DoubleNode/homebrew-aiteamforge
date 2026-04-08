/**
 * Fleet routes
 *
 * POST /api/status           - heartbeat from client machine
 * GET  /api/fleet            - current fleet status
 * PUT  /api/machine/:id/nickname
 * GET  /api/machine/:id/history
 * GET  /api/health
 * POST /api/team-register
 * GET  /api/registered-teams
 * GET  /api/backup-status
 */

'use strict';

const express = require('express');
const path    = require('path');
const fs      = require('fs');
const router  = express.Router();

const store   = require('../lib/store');
const history = require('../lib/history');

// ============================================================================
// CONFIGURATION (thresholds shared from server.js via module)
// ============================================================================

const OFFLINE_THRESHOLD_MS = 180 * 1000; // 3 minutes
const WARNING_THRESHOLD_MS = 120 * 1000; // 2 minutes

// ============================================================================
// HELPERS
// ============================================================================

/**
 * Format uptime seconds in human-readable form.
 */
function formatUptime(seconds) {
    const days    = Math.floor(seconds / 86400);
    const hours   = Math.floor((seconds % 86400) / 3600);
    const minutes = Math.floor((seconds % 3600) / 60);

    if (days > 0)  return `${days}d ${hours}h ${minutes}m`;
    if (hours > 0) return `${hours}h ${minutes}m`;
    return `${minutes}m`;
}

/**
 * Update machine status based on last heartbeat.
 * Also tracks offline status in uptime_history for sparkline.
 */
function updateMachineStatuses() {
    const now    = Date.now();
    const nowISO = new Date().toISOString();

    for (const [hostname, data] of store.machines.entries()) {
        const lastSeen         = new Date(data.last_seen).getTime();
        const timeSinceLastSeen = now - lastSeen;
        const previousStatus   = data.status;

        if (timeSinceLastSeen > OFFLINE_THRESHOLD_MS) {
            data.status = 'offline';
        } else if (timeSinceLastSeen > WARNING_THRESHOLD_MS) {
            data.status = 'warning';
        } else {
            data.status = 'online';
        }

        if (previousStatus !== data.status) {
            if (!data.uptime_history) data.uptime_history = [];
            data.uptime_history.push({ timestamp: nowISO, status: data.status, session_count: data.session_count });
            while (data.uptime_history.length > 48) data.uptime_history.shift();

            const downtime    = Math.floor(timeSinceLastSeen / 1000);
            const downtimeStr = downtime >= 60 ? `${Math.floor(downtime / 60)}m` : `${downtime}s`;
            const activityType = data.status.toUpperCase();
            store.logActivity(activityType, data.hostname, data.ip, data.session_count, `${previousStatus} \u2192 ${data.status} (no heartbeat ${downtimeStr})`);

            history.logHistoryEntry(
                data.machine_id,
                'status_change',
                previousStatus,
                data.status,
                `Status changed from ${previousStatus} to ${data.status} (no heartbeat for ${downtimeStr})`
            );
        }
    }
}

/**
 * Remove machines that don't have a proper GUID.
 */
function cleanupLegacyMachines() {
    const toRemove = [];
    for (const [key, machineData] of store.machines.entries()) {
        if (!machineData.machine_id || machineData.machine_id.length < 36) {
            toRemove.push(key);
        }
    }
    for (const key of toRemove) {
        store.machines.delete(key);
        console.log(`\u2713 Removed legacy machine entry: ${key}`);
    }
    if (toRemove.length > 0) store.saveMachineData();
}

/**
 * Parse sessions into hierarchical structure for fleet response.
 */
function parseFleetData() {
    updateMachineStatuses();

    const divisions    = {};
    let totalSessions  = 0;
    let onlineMachines = 0;
    let offlineMachines = 0;

    for (const [key, machineData] of store.machines.entries()) {
        if (!machineData.machine_id || machineData.machine_id.length < 36) continue;

        if (machineData.status === 'online') {
            onlineMachines++;
            totalSessions += machineData.session_count;
        } else if (machineData.status === 'offline') {
            offlineMachines++;
        }

        if (machineData.status !== 'online') continue;

        for (const session of machineData.sessions) {
            const { division, project, team, name, windows, attached, created, uptime_seconds, lcars_port, theme_color, tab_order } = session;

            let divisionKey  = division;
            let divisionName = division;
            if (division === 'freelance' && project) {
                const projectSuffix = project.replace('doublenode-', '');
                divisionKey  = `freelance-${projectSuffix}`;
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
                uptime_display: formatUptime(uptime_seconds),
                lcars_port, theme_color, tab_order
            });
        }
    }

    const machineList = Array.from(store.machines.values())
        .filter(m => m.machine_id && m.machine_id.length >= 36)
        .map(m => ({
            machine_id: m.machine_id,
            hostname:   m.hostname,
            nickname:   m.nickname || null,
            ip:         m.ip,
            os:         m.os,
            status:     m.status,
            first_seen: m.first_seen,
            last_seen:  m.last_seen,
            session_count: m.session_count,
            sessions:   m.sessions,
            uptime_history: m.uptime_history || []
        }));

    return {
        fleet: {
            total_machines:   onlineMachines + offlineMachines,
            online_machines:  onlineMachines,
            offline_machines: offlineMachines,
            total_sessions:   totalSessions,
            divisions,
            machines: machineList
        },
        activityLog: store.activityLog,
        last_update: new Date().toISOString()
    };
}

// Export helpers needed by other modules or server.js
module.exports.cleanupLegacyMachines = cleanupLegacyMachines;
module.exports.updateMachineStatuses  = updateMachineStatuses;

// ============================================================================
// ROUTES
// ============================================================================

/**
 * POST /api/status
 * Receive status update from client machine.
 */
router.post('/status', (req, res) => {
    try {
        const { machine, sessions, backup_status } = req.body;

        if (!machine || !machine.hostname) {
            return res.status(400).json({ error: 'Missing required field: machine.hostname' });
        }

        const machineKey      = machine.machine_id || machine.hostname;
        const now             = machine.timestamp || new Date().toISOString();
        const existingMachine = store.machines.get(machineKey);
        const firstSeen       = existingMachine?.first_seen || now;

        const uptimeHistory = existingMachine?.uptime_history || [];
        uptimeHistory.push({ timestamp: now, status: 'online', session_count: (sessions || []).length });
        while (uptimeHistory.length > 48) uptimeHistory.shift();

        const sessionCount    = (sessions || []).length;
        let activityType  = 'STATUS';
        let activityExtra = '';

        if (!existingMachine) {
            activityType  = 'CONNECT';
            activityExtra = 'first seen';
        } else if (existingMachine.status === 'offline' || existingMachine.status === 'warning') {
            activityType  = 'RECONNECT';
            activityExtra = `${existingMachine.status} \u2192 online`;
        }

        const existingNickname = existingMachine?.nickname || null;

        const changes = history.detectChanges(
            existingMachine,
            { machine_id: machineKey, hostname: machine.hostname, ip: machine.ip },
            sessions
        );
        for (const change of changes) {
            history.logHistoryEntry(machineKey, change.type, change.previous, change.new, change.details);
        }

        store.machines.set(machineKey, {
            machine_id:     machineKey,
            hostname:       machine.hostname,
            nickname:       existingNickname,
            ip:             machine.ip || 'unknown',
            os:             machine.os || 'unknown',
            first_seen:     firstSeen,
            last_seen:      now,
            status:         'online',
            sessions:       sessions || [],
            session_count:  sessionCount,
            uptime_history: uptimeHistory,
            backup_status:  backup_status || null
        });

        store.logActivity(activityType, machine.hostname, machine.ip, sessionCount, activityExtra);

        console.log(`\u2713 Status update from ${machine.hostname} (${machineKey.substring(0, 8)}...): ${sessions.length} sessions`);

        res.status(200).json({ success: true, message: 'Status received', sessions_count: sessions.length });
    } catch (error) {
        console.error('Error processing status update:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * GET /api/fleet
 * Return current fleet status.
 */
router.get('/fleet', (req, res) => {
    try {
        res.json(parseFleetData());
    } catch (error) {
        console.error('Error getting fleet data:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * PUT /api/machine/:machineId/nickname
 * Set or clear a machine's nickname.
 */
router.put('/machine/:machineId/nickname', (req, res) => {
    try {
        const { machineId } = req.params;
        const { nickname }  = req.body;
        const machine = store.machines.get(machineId);

        if (!machine) return res.status(404).json({ error: 'Machine not found' });

        machine.nickname = nickname && nickname.trim() ? nickname.trim() : null;
        console.log(`\u2713 Nickname ${machine.nickname ? '"' + machine.nickname + '"' : 'cleared'} for ${machine.hostname}`);

        res.json({ success: true, machine_id: machineId, nickname: machine.nickname });
    } catch (error) {
        console.error('Error setting nickname:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * GET /api/machine/:machineId/history
 * Get state change history for a machine.
 */
router.get('/machine/:machineId/history', (req, res) => {
    try {
        const { machineId } = req.params;
        const limit    = parseInt(req.query.limit)  || 50;
        const offset   = parseInt(req.query.offset) || 0;
        const hist     = history.loadMachineHistory(machineId);
        const paginated = hist.slice(offset, offset + limit);

        res.json({ machine_id: machineId, total: hist.length, offset, limit, entries: paginated });
    } catch (error) {
        console.error('Error fetching history:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * GET /api/health
 * Health check endpoint.
 */
router.get('/health', (req, res) => {
    res.json({
        status:           'operational',
        uptime:           process.uptime(),
        timestamp:        new Date().toISOString(),
        machines_tracked: store.machines.size,
        registered_teams: store.registeredTeams.size
    });
});

/**
 * POST /api/team-register
 * Register or update a team's metadata (push-based registration).
 */
router.post('/team-register', (req, res) => {
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

        const now          = new Date().toISOString();
        const existingTeam = store.registeredTeams.get(team);
        const teamData     = {
            team,
            teamName:       teamName || team.toUpperCase(),
            subtitle:       subtitle || '',
            ship:           ship || '',
            series:         series || '',
            organization,
            orgColor:       orgColor || 'lavender',
            kanbanDir,
            fleetMonitorUrl: fleetMonitorUrl || 'http://localhost:3000',
            terminals,
            registeredAt:   existingTeam?.registeredAt || now,
            lastSeen:       now
        };

        store.registeredTeams.set(team, teamData);
        store.saveRegisteredTeams();

        const terminalCount = Object.keys(terminals).length;
        const action        = existingTeam ? 'updated' : 'registered';
        console.log(`[REGISTER] Team '${team}' ${action} (org: ${organization}, terminals: ${terminalCount})`);

        res.status(existingTeam ? 200 : 201).json({
            success:        true,
            message:        `Team '${team}' ${action}`,
            team:           teamData.team,
            organization:   teamData.organization,
            terminal_count: terminalCount
        });
    } catch (error) {
        console.error('Error processing team registration:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * GET /api/registered-teams
 * Return all currently registered teams.
 */
router.get('/registered-teams', (req, res) => {
    try {
        const teams = Array.from(store.registeredTeams.values()).map(team => ({
            team:          team.team,
            teamName:      team.teamName,
            subtitle:      team.subtitle,
            ship:          team.ship,
            series:        team.series,
            organization:  team.organization,
            orgColor:      team.orgColor,
            kanbanDir:     team.kanbanDir,
            fleetMonitorUrl: team.fleetMonitorUrl,
            terminalCount: Object.keys(team.terminals).length,
            terminals:     team.terminals,
            registeredAt:  team.registeredAt,
            lastSeen:      team.lastSeen
        })).sort((a, b) => a.team.localeCompare(b.team));

        res.json({ teams, total: teams.length, timestamp: new Date().toISOString() });
    } catch (error) {
        console.error('Error listing registered teams:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * GET /api/backup-status
 * Kanban backup system status - aggregates from reporting machines.
 */
router.get('/backup-status', (req, res) => {
    let status = {
        status: 'not_configured',
        lastRun: null,
        lastRunStatus: 'unknown',
        totalBackups: 0,
        storageUsed: '0 B',
        boards: {},
        sources: []
    };

    try {
        const machineBackups = [];
        for (const [machineKey, machineData] of store.machines) {
            if (machineData.backup_status && machineData.backup_status.boards) {
                machineBackups.push({
                    machine_id:    machineKey,
                    hostname:      machineData.hostname,
                    backup_status: machineData.backup_status,
                    last_seen:     machineData.last_seen
                });
            }
        }

        if (machineBackups.length > 0) {
            let mostRecentRun    = null;
            let mostRecentStatus = null;
            const mergedBoards   = {};

            for (const mb of machineBackups) {
                const bs = mb.backup_status;

                status.sources.push({
                    hostname:   mb.hostname,
                    lastRun:    bs.lastRun,
                    boardCount: Object.keys(bs.boards || {}).length
                });

                if (bs.boards) {
                    for (const [boardName, boardData] of Object.entries(bs.boards)) {
                        const existing = mergedBoards[boardName];
                        if (!existing || (boardData.lastCheck && (!existing.lastCheck || new Date(boardData.lastCheck) > new Date(existing.lastCheck)))) {
                            mergedBoards[boardName] = boardData;
                        }
                    }
                }

                if (bs.lastRun && (!mostRecentRun || new Date(bs.lastRun) > new Date(mostRecentRun))) {
                    mostRecentRun    = bs.lastRun;
                    mostRecentStatus = bs.lastRunStatus;
                }

                status.totalBackups += bs.totalBackups || 0;
            }

            status.boards         = mergedBoards;
            status.lastRun        = mostRecentRun;
            status.lastRunStatus  = mostRecentStatus || 'unknown';
            status.status         = 'configured';

            if (mostRecentRun) {
                const lastRun    = new Date(mostRecentRun);
                const minutesAgo = Math.floor((Date.now() - lastRun) / (1000 * 60));

                if (minutesAgo < 60)        status.lastRunAgo = `${minutesAgo}m ago`;
                else if (minutesAgo < 1440) status.lastRunAgo = `${Math.floor(minutesAgo / 60)}h ago`;
                else                        status.lastRunAgo = `${Math.floor(minutesAgo / 1440)}d ago`;

                if (minutesAgo > 30) status.status = 'stale';
            }
        } else {
            // Fallback: try to read from local file (for backwards compatibility)
            const backupStatusFile = path.join(process.env.HOME || '/Users/darrenehlers', 'dev-team-backups', 'kanban', 'backup-status.json');
            if (require('fs').existsSync(backupStatusFile)) {
                const stored = JSON.parse(require('fs').readFileSync(backupStatusFile, 'utf8'));
                status = { ...status, ...stored, status: 'configured', sources: [{ hostname: 'local', lastRun: stored.lastRun }] };

                if (stored.lastRun) {
                    const minutesAgo = Math.floor((Date.now() - new Date(stored.lastRun)) / (1000 * 60));
                    if (minutesAgo < 60)        status.lastRunAgo = `${minutesAgo}m ago`;
                    else if (minutesAgo < 1440) status.lastRunAgo = `${Math.floor(minutesAgo / 60)}h ago`;
                    else                        status.lastRunAgo = `${Math.floor(minutesAgo / 1440)}d ago`;
                    if (minutesAgo > 30) status.status = 'stale';
                }
            }
        }
    } catch (error) {
        status.status = 'error';
        status.error  = error.message;
    }

    res.json(status);
});

module.exports.router               = router;
module.exports.parseFleetData        = parseFleetData;
module.exports.cleanupLegacyMachines = cleanupLegacyMachines;
module.exports.updateMachineStatuses  = updateMachineStatuses;
