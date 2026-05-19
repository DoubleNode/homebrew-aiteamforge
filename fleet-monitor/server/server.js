#!/usr/bin/env node

//
//  server.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

/**
 * Starfleet Operations Monitor - Central Server
 *
 * Receives status updates from distributed dev team machines
 * Serves LCARS-themed monitoring dashboard
 * Tracks session uptime and machine status
 *
 * Built by: Commander Jett Reno, Starfleet Academy Engineering
 */

const express = require('express');
const cors = require('cors');
const path = require('path');
const fs = require('fs');
const { spawn } = require('child_process');

// XACA-0281: AI engines registry store helpers
const enginesStore = require('./lib/engines-store');

// ============================================================================
// CONFIGURATION
// ============================================================================

const PORT = process.env.PORT || 3000;
const OFFLINE_THRESHOLD_MS = 180 * 1000; // 180 seconds (3 minutes) - allows for 2 missed heartbeats
const WARNING_THRESHOLD_MS = 120 * 1000; // 120 seconds (2 minutes) - early warning before offline
const DATA_FILE = path.join(__dirname, 'data', 'machines.json');
const TEAMS_FILE = path.join(__dirname, 'data', 'registered-teams.json');
const BOARDS_FILE = path.join(__dirname, 'data', 'pushed-boards.json');
const KNOWLEDGE_FILE = path.join(__dirname, 'data', 'pushed-knowledge.json');
const SAVE_INTERVAL_MS = 30 * 1000; // Save every 30 seconds

// Machine State History Configuration
const HISTORY_DIR = path.join(__dirname, 'data', 'history');
const HISTORY_RETENTION_DAYS = 7;
const HISTORY_PURGE_INTERVAL_MS = 60 * 60 * 1000; // Purge hourly

// Kanban Board Directories - DEPRECATED (backward compatibility only)
// Teams now register dynamically via POST /api/team-register
// This fallback will be removed once all teams are using push-based registration
const HOME_DIR = process.env.HOME || '/Users/darrenehlers';
const KANBAN_DIRS = [
    path.join(HOME_DIR, 'dev-team', 'kanban'),
    path.join('/Users/Shared/Development/Main Event/MainEventApp-iOS', 'kanban'),
    path.join('/Users/Shared/Development/Main Event/MainEventApp-Android', 'kanban'),
    path.join('/Users/Shared/Development/Main Event/MainEventApp-Functions', 'kanban'),
    path.join('/Users/Shared/Development/Main Event/dev-team', 'kanban'),
    path.join('/Users/Shared/Development/DNSFramework', 'kanban'),
    path.join('/Users/Shared/Development/DoubleNode/Starwords', 'kanban'),
    path.join('/Users/Shared/Development/DoubleNode/WorkStats', 'kanban'),
    path.join('/Users/Shared/Development/DoubleNode/appPlanning', 'kanban'),
    path.join(HOME_DIR, 'legal', 'coparenting', 'kanban'),
    path.join(HOME_DIR, 'medical', 'general', 'kanban'),
    path.join(HOME_DIR, 'finance', 'personal', 'kanban'),
];

/**
 * Find the board file path for a specific team
 * Uses registered team data first, falls back to KANBAN_DIRS for backward compatibility
 * @param {string} teamId - The team identifier
 * @returns {string|null} - The board file path or null if not found
 */
function findBoardPath(teamId) {
    // PREFERRED: Use registered team data
    const teamData = registeredTeams.get(teamId);
    if (teamData && teamData.kanbanDir) {
        try {
            const boardPath = path.join(teamData.kanbanDir, `${teamId}-board.json`);
            if (fs.existsSync(boardPath)) return boardPath;
        } catch (e) { /* skip */ }
    }

    // FALLBACK: Scan KANBAN_DIRS (backward compatibility during migration)
    for (const kanbanDir of KANBAN_DIRS) {
        try {
            const boardPath = path.join(kanbanDir, `${teamId}-board.json`);
            if (fs.existsSync(boardPath)) return boardPath;
        } catch (e) { /* skip */ }
    }
    return null;
}

/**
 * Get board data for a specific team.
 * Checks pushedBoards Map first (populated by POST /api/kanban-push).
 * Falls back to filesystem reads if no pushed data exists for the team.
 * @param {string} teamId - Team identifier
 * @returns {object|null} - Parsed board object, or null if not found
 */
function getBoardData(teamId) {
    // PRIMARY: Use pushed board data if available
    const pushed = pushedBoards.get(teamId);
    if (pushed && pushed.board) {
        return pushed.board;
    }

    // FALLBACK: Read from filesystem (local dev experience)
    const boardPath = findBoardPath(teamId);
    if (boardPath) {
        try {
            return JSON.parse(fs.readFileSync(boardPath, 'utf8'));
        } catch (e) {
            return null;
        }
    }

    return null;
}

/**
 * Get all team IDs from both pushedBoards and filesystem boards.
 * Pushed board team IDs take priority; filesystem supplements with any
 * teams not yet represented in pushedBoards.
 * @returns {string[]} - Deduplicated array of team IDs
 */
function getAllTeamIds() {
    const seen = new Set();

    // PRIMARY: Teams with pushed board data
    for (const teamId of pushedBoards.keys()) {
        seen.add(teamId);
    }

    // FALLBACK: Teams found on filesystem not already in pushedBoards
    for (const { teamId } of findAllBoardFiles()) {
        seen.add(teamId);
    }

    return Array.from(seen);
}

/**
 * Scan all kanban directories and return board file paths
 * Uses registered team data first, supplements with KANBAN_DIRS scan for backward compatibility
 * @returns {Array<{teamId: string, boardPath: string}>}
 */
function findAllBoardFiles() {
    const boards = [];
    const seen = new Set();

    // PREFERRED: Get boards from registered teams
    for (const [teamId, teamData] of registeredTeams.entries()) {
        if (teamData.kanbanDir) {
            try {
                const boardPath = path.join(teamData.kanbanDir, `${teamId}-board.json`);
                if (fs.existsSync(boardPath)) {
                    boards.push({ teamId, boardPath });
                    seen.add(teamId);
                }
            } catch (e) {
                // Skip boards that can't be accessed
            }
        }
    }

    // FALLBACK: Scan KANBAN_DIRS for boards not yet registered (backward compatibility)
    for (const kanbanDir of KANBAN_DIRS) {
        try {
            if (!fs.existsSync(kanbanDir)) continue;
            const files = fs.readdirSync(kanbanDir).filter(f => f.endsWith('-board.json'));
            for (const file of files) {
                const teamId = file.replace('-board.json', '');
                if (seen.has(teamId)) continue;
                seen.add(teamId);
                boards.push({ teamId, boardPath: path.join(kanbanDir, file) });
            }
        } catch (e) {
            // Skip inaccessible directories
        }
    }
    return boards;
}

// ============================================================================
// DATA STORAGE (In-Memory with File Persistence)
// ============================================================================

// Store machine status data
// Structure: { hostname: { hostname, ip, os, last_seen, status, sessions, session_count } }
const machines = new Map();

// Store registered teams (push-based registration from team terminals)
// Structure: { teamName: { team, teamName, subtitle, ship, series, organization, orgColor, kanbanDir, fleetMonitorUrl, terminals, registeredAt, lastSeen } }
const registeredTeams = new Map();

// Store kanban board data pushed from client terminals
// Structure: { teamId: { teamId, board, pushedAt, pushedBy } }
const pushedBoards = new Map();

// Store knowledge base stats pushed from client terminals
// Structure: { teamId: { teamId, knowledge, pushedAt } }
const pushedKnowledge = new Map();

// Activity log - last 20 status updates for live UI display
const activityLog = [];
const MAX_ACTIVITY_LOG_ENTRIES = 20;

/**
 * Load machine data from file on startup
 */
function loadMachineData() {
    try {
        if (fs.existsSync(DATA_FILE)) {
            const data = JSON.parse(fs.readFileSync(DATA_FILE, 'utf8'));
            for (const [hostname, machineData] of Object.entries(data)) {
                machines.set(hostname, machineData);
            }
            console.log(`✓ Loaded ${machines.size} machines from persistent storage`);
        } else {
            console.log('No persistent data file found, starting fresh');
        }
    } catch (error) {
        console.error('Error loading machine data:', error.message);
    }
}

/**
 * Save machine data to file
 */
function saveMachineData() {
    try {
        // Ensure data directory exists
        const dataDir = path.dirname(DATA_FILE);
        if (!fs.existsSync(dataDir)) {
            fs.mkdirSync(dataDir, { recursive: true });
        }

        // Convert Map to object for JSON serialization
        const data = Object.fromEntries(machines);
        fs.writeFileSync(DATA_FILE, JSON.stringify(data, null, 2));
        console.log(`✓ Saved ${machines.size} machines to persistent storage`);
    } catch (error) {
        console.error('Error saving machine data:', error.message);
    }
}

/**
 * Load registered teams from file on startup
 */
function loadRegisteredTeams() {
    try {
        if (fs.existsSync(TEAMS_FILE)) {
            const data = JSON.parse(fs.readFileSync(TEAMS_FILE, 'utf8'));
            for (const [teamId, teamData] of Object.entries(data)) {
                registeredTeams.set(teamId, teamData);
            }
            console.log(`✓ Loaded ${registeredTeams.size} registered teams from persistent storage`);
        } else {
            console.log('No registered teams file found, starting fresh');
        }
    } catch (error) {
        console.error('Error loading registered teams:', error.message);
    }
}

/**
 * Save registered teams to file
 */
function saveRegisteredTeams() {
    try {
        const dataDir = path.dirname(TEAMS_FILE);
        if (!fs.existsSync(dataDir)) {
            fs.mkdirSync(dataDir, { recursive: true });
        }

        const data = Object.fromEntries(registeredTeams);
        fs.writeFileSync(TEAMS_FILE, JSON.stringify(data, null, 2));
    } catch (error) {
        console.error('Error saving registered teams:', error.message);
    }
}

/**
 * Load pushed boards from file on startup
 */
function loadPushedBoards() {
    try {
        if (fs.existsSync(BOARDS_FILE)) {
            const data = JSON.parse(fs.readFileSync(BOARDS_FILE, 'utf8'));
            for (const [teamId, boardData] of Object.entries(data)) {
                pushedBoards.set(teamId, boardData);
            }
            console.log(`✓ Loaded ${pushedBoards.size} pushed boards from persistent storage`);
        } else {
            console.log('No pushed boards file found, starting fresh');
        }
    } catch (error) {
        console.error('Error loading pushed boards:', error.message);
    }
}

/**
 * Save pushed boards to file
 */
function savePushedBoards() {
    try {
        const dataDir = path.dirname(BOARDS_FILE);
        if (!fs.existsSync(dataDir)) {
            fs.mkdirSync(dataDir, { recursive: true });
        }

        const data = Object.fromEntries(pushedBoards);
        fs.writeFileSync(BOARDS_FILE, JSON.stringify(data, null, 2));
    } catch (error) {
        console.error('Error saving pushed boards:', error.message);
    }
}

/**
 * Load pushed knowledge stats from file on startup
 */
function loadPushedKnowledge() {
    try {
        if (fs.existsSync(KNOWLEDGE_FILE)) {
            const data = JSON.parse(fs.readFileSync(KNOWLEDGE_FILE, 'utf8'));
            for (const [teamId, knowledgeData] of Object.entries(data)) {
                pushedKnowledge.set(teamId, knowledgeData);
            }
            console.log(`✓ Loaded ${pushedKnowledge.size} pushed knowledge stats from persistent storage`);
        } else {
            console.log('No pushed knowledge file found, starting fresh');
        }
    } catch (error) {
        console.error('Error loading pushed knowledge:', error.message);
    }
}

/**
 * Save pushed knowledge stats to file
 */
function savePushedKnowledge() {
    try {
        const dataDir = path.dirname(KNOWLEDGE_FILE);
        if (!fs.existsSync(dataDir)) {
            fs.mkdirSync(dataDir, { recursive: true });
        }

        const data = Object.fromEntries(pushedKnowledge);
        fs.writeFileSync(KNOWLEDGE_FILE, JSON.stringify(data, null, 2));
    } catch (error) {
        console.error('Error saving pushed knowledge:', error.message);
    }
}

// Load data on startup
loadMachineData();
loadRegisteredTeams();
loadPushedBoards();
loadPushedKnowledge();

// ============================================================================
// MACHINE STATE HISTORY FUNCTIONS
// ============================================================================

/**
 * Generate a unique ID for history entries
 */
function generateUUID() {
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) {
        const r = Math.random() * 16 | 0;
        const v = c === 'x' ? r : (r & 0x3 | 0x8);
        return v.toString(16);
    });
}

/**
 * Format duration in human-readable form
 */
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

/**
 * Ensure history directory exists
 */
function ensureHistoryDir() {
    if (!fs.existsSync(HISTORY_DIR)) {
        fs.mkdirSync(HISTORY_DIR, { recursive: true });
        console.log('✓ Created history directory:', HISTORY_DIR);
    }
}

/**
 * Load history for a specific machine
 */
function loadMachineHistory(machineId) {
    try {
        const historyFile = path.join(HISTORY_DIR, `${machineId}.json`);
        if (fs.existsSync(historyFile)) {
            return JSON.parse(fs.readFileSync(historyFile, 'utf8'));
        }
    } catch (error) {
        console.error(`Error loading history for ${machineId}:`, error.message);
    }
    return [];
}

/**
 * Save history for a specific machine
 */
function saveMachineHistory(machineId, history) {
    try {
        ensureHistoryDir();
        const historyFile = path.join(HISTORY_DIR, `${machineId}.json`);
        fs.writeFileSync(historyFile, JSON.stringify(history, null, 2));
    } catch (error) {
        console.error(`Error saving history for ${machineId}:`, error.message);
    }
}

/**
 * Log a history entry for a machine
 */
function logHistoryEntry(machineId, eventType, previousValue, newValue, details) {
    const entry = {
        id: generateUUID(),
        timestamp: new Date().toISOString(),
        event_type: eventType,
        previous_value: previousValue,
        new_value: newValue,
        details: details
    };

    const history = loadMachineHistory(machineId);
    history.unshift(entry);  // Add to front (newest first)
    saveMachineHistory(machineId, history);

    console.log(`[HISTORY] ${machineId}: ${eventType} - ${details}`);
    return entry;
}

/**
 * Detect changes between existing machine state and new data
 * Returns array of change objects to log
 */
function detectChanges(existingMachine, newData, newSessions) {
    const changes = [];
    const machineId = newData.machine_id;

    // First-seen detection
    if (!existingMachine) {
        changes.push({
            type: 'first_seen',
            previous: null,
            new: { hostname: newData.hostname, ip: newData.ip },
            details: `First connection from ${newData.hostname} (${newData.ip})`
        });
        return changes;  // No other changes to detect for new machines
    }

    // Status change detection (was offline or warning, now sending heartbeat)
    if (existingMachine.status === 'offline' || existingMachine.status === 'warning') {
        const downDuration = Date.now() - new Date(existingMachine.last_seen).getTime();
        changes.push({
            type: 'status_change',
            previous: existingMachine.status,
            new: 'online',
            details: `Status changed from ${existingMachine.status} to online (back after ${formatDuration(downDuration)})`
        });
    }

    // IP change detection
    if (existingMachine.ip && newData.ip && existingMachine.ip !== newData.ip) {
        changes.push({
            type: 'ip_change',
            previous: existingMachine.ip,
            new: newData.ip,
            details: `IP changed from ${existingMachine.ip} to ${newData.ip}`
        });
    }

    // Session changes detection
    const existingSessions = new Set((existingMachine.sessions || []).map(s => s.session_name));
    const newSessionSet = new Set((newSessions || []).map(s => s.session_name));

    // Session starts (in new but not in existing)
    for (const sessionName of newSessionSet) {
        if (!existingSessions.has(sessionName)) {
            changes.push({
                type: 'session_start',
                previous: null,
                new: sessionName,
                details: `Session started: ${sessionName}`
            });
        }
    }

    // Session stops (in existing but not in new)
    for (const sessionName of existingSessions) {
        if (!newSessionSet.has(sessionName)) {
            changes.push({
                type: 'session_stop',
                previous: sessionName,
                new: null,
                details: `Session ended: ${sessionName}`
            });
        }
    }

    return changes;
}

/**
 * Purge old history entries (older than HISTORY_RETENTION_DAYS)
 */
function purgeOldHistory() {
    try {
        ensureHistoryDir();
        const cutoff = Date.now() - (HISTORY_RETENTION_DAYS * 24 * 60 * 60 * 1000);
        const files = fs.readdirSync(HISTORY_DIR).filter(f => f.endsWith('.json'));
        let totalPurged = 0;

        for (const file of files) {
            const filePath = path.join(HISTORY_DIR, file);
            const history = JSON.parse(fs.readFileSync(filePath, 'utf8'));
            const originalLength = history.length;

            const filtered = history.filter(entry => {
                return new Date(entry.timestamp).getTime() > cutoff;
            });

            if (filtered.length < originalLength) {
                const purged = originalLength - filtered.length;
                totalPurged += purged;

                if (filtered.length === 0) {
                    // Delete empty history files
                    fs.unlinkSync(filePath);
                } else {
                    fs.writeFileSync(filePath, JSON.stringify(filtered, null, 2));
                }
            }
        }

        if (totalPurged > 0) {
            console.log(`✓ Purged ${totalPurged} old history entries`);
        }
    } catch (error) {
        console.error('Error purging old history:', error.message);
    }
}

// Initialize history directory and run initial purge
ensureHistoryDir();
purgeOldHistory();

// Schedule periodic history purge
setInterval(purgeOldHistory, HISTORY_PURGE_INTERVAL_MS);

// ============================================================================
// EXPRESS APP SETUP
// ============================================================================

const app = express();

// Middleware
app.use(cors());
app.use(express.json({ limit: '10mb' }));
// Disable directory redirect to allow explicit route handlers for /lcars
app.use(express.static(path.join(__dirname, 'public'), { redirect: false }));

// Request logging
app.use((req, res, next) => {
    const timestamp = new Date().toISOString();
    console.log(`[${timestamp}] ${req.method} ${req.path} - ${req.ip}`);
    next();
});

// ============================================================================
// HELPER FUNCTIONS
// ============================================================================

/**
 * Log activity for the live activity log display
 * @param {string} type - 'STATUS' | 'CONNECT' | 'OFFLINE' | 'RECONNECT'
 * @param {string} hostname - Machine hostname
 * @param {string} ip - Machine IP address
 * @param {number} sessionCount - Number of active sessions
 * @param {string} extra - Additional info (optional)
 */
function logActivity(type, hostname, ip, sessionCount, extra = '') {
    const now = new Date();
    const timeStr = now.toLocaleTimeString('en-US', { hour12: false, hour: '2-digit', minute: '2-digit', second: '2-digit' });

    // Build compact message for single-line display
    let message = `[${timeStr}] ${type.padEnd(8)} ${hostname}`;
    if (ip && ip !== 'unknown') {
        message += ` (${ip})`;
    }
    if (type === 'STATUS') {
        message += ` ${sessionCount} session${sessionCount !== 1 ? 's' : ''}`;
    }
    if (extra) {
        message += ` ${extra}`;
    }

    // Add to front (newest first)
    activityLog.unshift({
        timestamp: now.toISOString(),
        type,
        hostname,
        ip,
        session_count: sessionCount,
        message
    });

    // Trim to max entries
    while (activityLog.length > MAX_ACTIVITY_LOG_ENTRIES) {
        activityLog.pop();
    }
}

/**
 * Update machine status based on last heartbeat
 * Also tracks offline status in uptime_history for sparkline
 */
function updateMachineStatuses() {
    const now = Date.now();
    const nowISO = new Date().toISOString();

    for (const [hostname, data] of machines.entries()) {
        const lastSeen = new Date(data.last_seen).getTime();
        const timeSinceLastSeen = now - lastSeen;
        const previousStatus = data.status;

        if (timeSinceLastSeen > OFFLINE_THRESHOLD_MS) {
            data.status = 'offline';
        } else if (timeSinceLastSeen > WARNING_THRESHOLD_MS) {
            data.status = 'warning';
        } else {
            data.status = 'online';
        }

        // If status changed, add to history and log
        if (previousStatus !== data.status) {
            if (!data.uptime_history) data.uptime_history = [];
            data.uptime_history.push({
                timestamp: nowISO,
                status: data.status,
                session_count: data.session_count
            });
            // Keep only the last 48 entries
            while (data.uptime_history.length > 48) {
                data.uptime_history.shift();
            }

            // Log to activity log
            const downtime = Math.floor(timeSinceLastSeen / 1000);
            const downtimeStr = downtime >= 60 ? `${Math.floor(downtime / 60)}m` : `${downtime}s`;
            const activityType = data.status.toUpperCase();
            logActivity(activityType, data.hostname, data.ip, data.session_count, `${previousStatus} → ${data.status} (no heartbeat ${downtimeStr})`);

            // Log status change to history
            logHistoryEntry(
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
 * Remove machines that don't have a proper GUID
 * These are legacy entries from before the machine_id system
 */
function cleanupLegacyMachines() {
    const toRemove = [];
    for (const [key, machineData] of machines.entries()) {
        // A proper GUID is a UUID format (36 chars with dashes)
        // Legacy entries used hostname as the key and may not have machine_id
        if (!machineData.machine_id || machineData.machine_id.length < 36) {
            toRemove.push(key);
        }
    }
    for (const key of toRemove) {
        machines.delete(key);
        console.log(`✓ Removed legacy machine entry: ${key}`);
    }
    if (toRemove.length > 0) {
        saveMachineData();
    }
}

// Clean up legacy machines on startup
cleanupLegacyMachines();

/**
 * Parse sessions into hierarchical structure
 */
function parseFleetData() {
    updateMachineStatuses();

    const divisions = {};
    let totalSessions = 0;
    let onlineMachines = 0;
    let offlineMachines = 0;

    // Iterate through all machines (only those with valid GUIDs)
    for (const [key, machineData] of machines.entries()) {
        // Skip machines without proper GUID
        if (!machineData.machine_id || machineData.machine_id.length < 36) {
            continue;
        }

        if (machineData.status === 'online') {
            onlineMachines++;
            totalSessions += machineData.session_count;
        } else if (machineData.status === 'offline') {
            offlineMachines++;
        }

        // Only include sessions from online machines in division data
        if (machineData.status !== 'online') {
            continue;
        }

        // Parse each session
        for (const session of machineData.sessions) {
            const { division, project, team, name, windows, attached, created, uptime_seconds, lcars_port, theme_color, tab_order } = session;

            // For freelance division, split by project name (e.g., "doublenode-starwords" -> "freelance-doublenode-starwords")
            let divisionKey = division;
            let divisionName = division;
            if (division === 'freelance' && project) {
                const projectSuffix = project.replace('doublenode-', '');
                divisionKey = `freelance-${projectSuffix}`;
                divisionName = divisionKey;
            }

            // Initialize division if needed
            if (!divisions[divisionKey]) {
                divisions[divisionKey] = {
                    name: divisionName,
                    total_sessions: 0,
                    projects: {}
                };
            }

            divisions[divisionKey].total_sessions++;

            // Handle projects (if exists)
            const projectKey = project || '_default';

            if (!divisions[divisionKey].projects[projectKey]) {
                divisions[divisionKey].projects[projectKey] = {
                    name: project,
                    teams: {}
                };
            }

            // Initialize team if needed
            if (!divisions[divisionKey].projects[projectKey].teams[team]) {
                divisions[divisionKey].projects[projectKey].teams[team] = {
                    name: team,
                    sessions: []
                };
            }

            // Add session to team
            divisions[divisionKey].projects[projectKey].teams[team].sessions.push({
                name,
                division,
                project,
                team,
                hostname: machineData.hostname,
                machine_status: machineData.status,
                windows,
                attached,
                created,
                uptime_seconds,
                uptime_display: formatUptime(uptime_seconds),
                lcars_port,
                theme_color,
                tab_order
            });
        }
    }

    // Build machine list (only machines with valid GUIDs)
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
        activityLog: activityLog,
        last_update: new Date().toISOString()
    };
}

/**
 * Format uptime in human-readable form
 */
function formatUptime(seconds) {
    const days = Math.floor(seconds / 86400);
    const hours = Math.floor((seconds % 86400) / 3600);
    const minutes = Math.floor((seconds % 3600) / 60);

    if (days > 0) {
        return `${days}d ${hours}h ${minutes}m`;
    } else if (hours > 0) {
        return `${hours}h ${minutes}m`;
    } else {
        return `${minutes}m`;
    }
}

// ============================================================================
// API ROUTES
// ============================================================================

/**
 * POST /api/status
 * Receive status update from client machine
 */
app.post('/api/status', (req, res) => {
    try {
        const { machine, sessions, backup_status } = req.body;

        if (!machine || !machine.hostname) {
            return res.status(400).json({ error: 'Missing required field: machine.hostname' });
        }

        // Use machine_id as the unique key (falls back to hostname for backwards compatibility)
        const machineKey = machine.machine_id || machine.hostname;
        const now = machine.timestamp || new Date().toISOString();

        // Get existing machine data (if any) to preserve history
        const existingMachine = machines.get(machineKey);

        // Preserve first_seen from existing data, or set it now
        const firstSeen = existingMachine?.first_seen || now;

        // Build uptime history (keep last 48 entries = 48 hours at 1/hour or 4 hours at 5-min)
        const uptimeHistory = existingMachine?.uptime_history || [];
        uptimeHistory.push({
            timestamp: now,
            status: 'online',
            session_count: (sessions || []).length
        });
        // Keep only the last 48 entries
        while (uptimeHistory.length > 48) {
            uptimeHistory.shift();
        }

        // Determine activity log event type
        const sessionCount = (sessions || []).length;
        let activityType = 'STATUS';
        let activityExtra = '';

        if (!existingMachine) {
            // First time seeing this machine
            activityType = 'CONNECT';
            activityExtra = 'first seen';
        } else if (existingMachine.status === 'offline' || existingMachine.status === 'warning') {
            // Machine was offline/warning, now back online
            activityType = 'RECONNECT';
            activityExtra = `${existingMachine.status} → online`;
        }

        // Preserve existing nickname (if any)
        const existingNickname = existingMachine?.nickname || null;

        // Detect and log state changes (before updating machine data)
        const changes = detectChanges(existingMachine, { machine_id: machineKey, hostname: machine.hostname, ip: machine.ip }, sessions);
        for (const change of changes) {
            logHistoryEntry(machineKey, change.type, change.previous, change.new, change.details);
        }

        // Store/update machine data
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

        // Log to activity log
        logActivity(activityType, machine.hostname, machine.ip, sessionCount, activityExtra);

        console.log(`✓ Status update from ${machine.hostname} (${machineKey.substring(0, 8)}...): ${sessions.length} sessions`);

        res.status(200).json({
            success: true,
            message: 'Status received',
            sessions_count: sessions.length
        });
    } catch (error) {
        console.error('Error processing status update:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * GET /api/fleet
 * Return current fleet status
 */
app.get('/api/fleet', (req, res) => {
    try {
        const fleetData = parseFleetData();
        res.json(fleetData);
    } catch (error) {
        console.error('Error getting fleet data:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * PUT /api/machine/:machineId/nickname
 * Set or clear a machine's nickname
 */
app.put('/api/machine/:machineId/nickname', (req, res) => {
    try {
        const { machineId } = req.params;
        const { nickname } = req.body;

        // Find the machine
        const machine = machines.get(machineId);
        if (!machine) {
            return res.status(404).json({ error: 'Machine not found' });
        }

        // Update nickname (null or empty string clears it)
        machine.nickname = nickname && nickname.trim() ? nickname.trim() : null;

        console.log(`✓ Nickname ${machine.nickname ? 'set to "' + machine.nickname + '"' : 'cleared'} for ${machine.hostname}`);

        res.json({
            success: true,
            machine_id: machineId,
            nickname: machine.nickname
        });
    } catch (error) {
        console.error('Error setting nickname:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * GET /api/machine/:machineId/history
 * Get state change history for a machine
 */
app.get('/api/machine/:machineId/history', (req, res) => {
    try {
        const { machineId } = req.params;
        const limit = parseInt(req.query.limit) || 50;
        const offset = parseInt(req.query.offset) || 0;

        // Load history for this machine
        const history = loadMachineHistory(machineId);

        // Apply pagination
        const paginatedHistory = history.slice(offset, offset + limit);

        res.json({
            machine_id: machineId,
            total: history.length,
            offset: offset,
            limit: limit,
            entries: paginatedHistory
        });
    } catch (error) {
        console.error('Error fetching history:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * GET /api/health
 * Health check endpoint
 */
app.get('/api/health', (req, res) => {
    res.json({
        status: 'operational',
        uptime: process.uptime(),
        timestamp: new Date().toISOString(),
        machines_tracked: machines.size,
        registered_teams: registeredTeams.size
    });
});

/**
 * POST /api/team-register
 * Register or update a team's metadata (push-based registration)
 * Teams POST their config when they start up or when board data changes
 * Body: { team, teamName, subtitle, ship, series, organization, orgColor, kanbanDir, fleetMonitorUrl, terminals }
 */
app.post('/api/team-register', (req, res) => {
    try {
        const { team, teamName, subtitle, ship, series, organization, orgColor, kanbanDir, fleetMonitorUrl, terminals } = req.body;

        // Validate required fields
        if (!team || !organization || !kanbanDir || !terminals) {
            return res.status(400).json({
                error: 'Missing required fields',
                required: ['team', 'organization', 'kanbanDir', 'terminals'],
                received: { team, organization, kanbanDir, terminals: !!terminals }
            });
        }

        // Validate terminals is an object
        if (typeof terminals !== 'object' || Array.isArray(terminals)) {
            return res.status(400).json({
                error: 'Invalid terminals field',
                message: 'terminals must be an object mapping terminal names to metadata'
            });
        }

        const now = new Date().toISOString();
        const existingTeam = registeredTeams.get(team);

        // Build team registration data
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

        // Store team data (idempotent - updates if already exists)
        registeredTeams.set(team, teamData);
        saveRegisteredTeams();

        const terminalCount = Object.keys(terminals).length;
        const action = existingTeam ? 'updated' : 'registered';

        console.log(`[REGISTER] Team '${team}' ${action} (org: ${organization}, terminals: ${terminalCount})`);

        res.status(existingTeam ? 200 : 201).json({
            success: true,
            message: `Team '${team}' ${action}`,
            team: teamData.team,
            organization: teamData.organization,
            terminal_count: terminalCount
        });
    } catch (error) {
        console.error('Error processing team registration:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * POST /api/kanban-push
 * Receive full kanban board data from a client team
 * Body: { team, ...boardData } — team field identifies the source team
 */
app.post('/api/kanban-push', (req, res) => {
    try {
        const body = req.body;

        if (!body || !body.team) {
            return res.status(400).json({
                error: 'Missing required field: team',
                required: ['team']
            });
        }

        const teamId = body.team;
        const now = new Date().toISOString();

        // Store board data with metadata
        // Persistence handled by periodic save interval (every 30s)
        pushedBoards.set(teamId, {
            board: body,
            pushedAt: now,
            teamId
        });

        console.log(`[KANBAN-PUSH] Board data received from team '${teamId}'`);

        res.status(200).json({
            success: true,
            team: teamId,
            pushedAt: now
        });
    } catch (error) {
        console.error('Error processing kanban push:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * POST /api/knowledge-push
 * Receive knowledge base stats from a client team
 * Body: { team: "academy", knowledge: { totalEntries, agents, categories, tags, ... } }
 */
app.post('/api/knowledge-push', (req, res) => {
    try {
        const body = req.body;

        if (!body || !body.team) {
            return res.status(400).json({
                error: 'Missing required field: team',
                required: ['team']
            });
        }

        const teamId = body.team;
        const now = new Date().toISOString();

        // Store knowledge data with metadata
        // Persistence handled by periodic save interval (every 30s)
        pushedKnowledge.set(teamId, {
            knowledge: body.knowledge || {},
            pushedAt: now,
            teamId
        });

        console.log(`[KNOWLEDGE-PUSH] Knowledge stats received from team '${teamId}'`);

        res.status(200).json({
            success: true,
            team: teamId,
            pushedAt: now
        });
    } catch (error) {
        console.error('Error processing knowledge push:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * GET /api/knowledge-stats
 * Returns aggregated knowledge base statistics for all teams
 */
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
            teams[teamId] = {
                teamId,
                ...k,
                pushedAt: data.pushedAt
            };

            totalEntries += k.totalEntries || 0;
            totalContributingAgents += k.contributingAgents || 0;
            if ((k.totalEntries || 0) > 0) teamsWithEntries++;

            // Merge categories
            if (k.categories) {
                for (const [cat, count] of Object.entries(k.categories)) {
                    allCategories[cat] = (allCategories[cat] || 0) + count;
                }
            }

            // Merge tags
            if (k.tags) {
                for (const [tag, count] of Object.entries(k.tags)) {
                    allTags[tag] = (allTags[tag] || 0) + count;
                }
            }

            // Collect recent entries (with team attribution)
            if (k.recentEntries && Array.isArray(k.recentEntries)) {
                k.recentEntries.forEach(entry => {
                    allRecentEntries.push({ ...entry, teamId });
                });
            }
        }

        // Sort recent entries by date descending, take top 10
        allRecentEntries.sort((a, b) => (b.date || '').localeCompare(a.date || ''));
        const topRecentEntries = allRecentEntries.slice(0, 10);

        // Sort tags by count descending
        const topTags = Object.entries(allTags)
            .sort((a, b) => b[1] - a[1])
            .slice(0, 20)
            .map(([tag, count]) => ({ tag, count }));

        const uniqueCategories = Object.keys(allCategories).length;
        const uniqueTags = Object.keys(allTags).length;

        res.json({
            teams,
            overall: {
                totalEntries,
                teamsWithEntries,
                totalContributingAgents,
                categories: allCategories,
                uniqueCategories,
                topTags,
                uniqueTags,
                recentEntries: topRecentEntries
            },
            timestamp: new Date().toISOString()
        });
    } catch (error) {
        console.error('Error calculating knowledge stats:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * GET /api/registered-teams
 * Return all currently registered teams
 */
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

        res.json({
            teams,
            total: teams.length,
            timestamp: new Date().toISOString()
        });
    } catch (error) {
        console.error('Error listing registered teams:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * GET /api/backup-status
 * Kanban backup system status - aggregates from reporting machines
 */
app.get('/api/backup-status', (req, res) => {
    // Default status
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
        // Aggregate backup status from all reporting machines
        const machineBackups = [];
        for (const [machineKey, machineData] of machines) {
            if (machineData.backup_status && machineData.backup_status.boards) {
                machineBackups.push({
                    machine_id: machineKey,
                    hostname: machineData.hostname,
                    backup_status: machineData.backup_status,
                    last_seen: machineData.last_seen
                });
            }
        }

        if (machineBackups.length > 0) {
            // Use the most recent backup status (by lastRun timestamp)
            // and merge boards from all machines
            let mostRecentRun = null;
            let mostRecentStatus = null;
            const mergedBoards = {};

            for (const mb of machineBackups) {
                const bs = mb.backup_status;

                // Track source machines
                status.sources.push({
                    hostname: mb.hostname,
                    lastRun: bs.lastRun,
                    boardCount: Object.keys(bs.boards || {}).length
                });

                // Merge boards - use most recent data for each board
                if (bs.boards) {
                    for (const [boardName, boardData] of Object.entries(bs.boards)) {
                        const existing = mergedBoards[boardName];
                        if (!existing || (boardData.lastCheck && (!existing.lastCheck || new Date(boardData.lastCheck) > new Date(existing.lastCheck)))) {
                            mergedBoards[boardName] = boardData;
                        }
                    }
                }

                // Track most recent run
                if (bs.lastRun && (!mostRecentRun || new Date(bs.lastRun) > new Date(mostRecentRun))) {
                    mostRecentRun = bs.lastRun;
                    mostRecentStatus = bs.lastRunStatus;
                }

                // Accumulate totals
                status.totalBackups += bs.totalBackups || 0;
            }

            status.boards = mergedBoards;
            status.lastRun = mostRecentRun;
            status.lastRunStatus = mostRecentStatus || 'unknown';
            status.status = 'configured';

            // Calculate time since last run
            if (mostRecentRun) {
                const lastRun = new Date(mostRecentRun);
                const now = new Date();
                const minutesAgo = Math.floor((now - lastRun) / (1000 * 60));

                if (minutesAgo < 60) {
                    status.lastRunAgo = `${minutesAgo}m ago`;
                } else if (minutesAgo < 1440) {
                    status.lastRunAgo = `${Math.floor(minutesAgo / 60)}h ago`;
                } else {
                    status.lastRunAgo = `${Math.floor(minutesAgo / 1440)}d ago`;
                }

                // Check if backup is stale (no run in 30+ minutes)
                if (minutesAgo > 30) {
                    status.status = 'stale';
                }
            }
        } else {
            // Fallback: try to read from local file (for backwards compatibility)
            const backupStatusFile = path.join(process.env.HOME || '/Users/darrenehlers', 'aiteamforge-backups', 'kanban', 'backup-status.json');
            if (fs.existsSync(backupStatusFile)) {
                const stored = JSON.parse(fs.readFileSync(backupStatusFile, 'utf8'));
                status = { ...status, ...stored, status: 'configured', sources: [{ hostname: 'local', lastRun: stored.lastRun }] };

                // Calculate time since last run
                if (stored.lastRun) {
                    const lastRun = new Date(stored.lastRun);
                    const now = new Date();
                    const minutesAgo = Math.floor((now - lastRun) / (1000 * 60));

                    if (minutesAgo < 60) {
                        status.lastRunAgo = `${minutesAgo}m ago`;
                    } else if (minutesAgo < 1440) {
                        status.lastRunAgo = `${Math.floor(minutesAgo / 60)}h ago`;
                    } else {
                        status.lastRunAgo = `${Math.floor(minutesAgo / 1440)}d ago`;
                    }

                    if (minutesAgo > 30) {
                        status.status = 'stale';
                    }
                }
            }
        }
    } catch (error) {
        status.status = 'error';
        status.error = error.message;
    }

    res.json(status);
});

// ============================================================================
// CREDENTIAL API (Secure Storage Integration)
// ============================================================================

// Path to credential CLI
const CREDENTIAL_CLI = path.join(process.env.HOME || '/Users/darrenehlers', 'dev-team', 'kanban-hooks', 'integrations', 'credential_cli.py');

/**
 * Execute credential CLI command
 * @param {string} command - Command to execute
 * @param {string|null} integrationId - Integration ID (if required)
 * @param {object|null} inputData - Data to pass via stdin (for set command)
 * @returns {Promise<object>} - Parsed JSON response
 */
function execCredentialCli(command, integrationId = null, inputData = null) {
    return new Promise((resolve, reject) => {
        const args = [CREDENTIAL_CLI, command];
        if (integrationId) {
            args.push(integrationId);
        }

        const proc = spawn('python3', args, {
            stdio: ['pipe', 'pipe', 'pipe']
        });

        let stdout = '';
        let stderr = '';

        proc.stdout.on('data', (data) => {
            stdout += data.toString();
        });

        proc.stderr.on('data', (data) => {
            stderr += data.toString();
        });

        proc.on('close', (code) => {
            try {
                const result = JSON.parse(stdout);
                resolve(result);
            } catch (e) {
                reject(new Error(stderr || stdout || `Process exited with code ${code}`));
            }
        });

        proc.on('error', (err) => {
            reject(err);
        });

        // Send input data if provided
        if (inputData) {
            proc.stdin.write(JSON.stringify(inputData));
        }
        proc.stdin.end();
    });
}

/**
 * POST /api/credentials/:integration
 * Store credential for an integration
 * Body: { type: "jira", endpoint: "...", user: "...", token: "..." }
 * NEVER returns credential values
 */
app.post('/api/credentials/:integration', async (req, res) => {
    try {
        const { integration } = req.params;
        const credData = req.body;

        if (!credData.type) {
            return res.status(400).json({ error: 'Missing required field: type' });
        }

        // Validate integration ID format (alphanumeric, 2-20 chars)
        if (!/^[A-Za-z0-9_-]{2,20}$/.test(integration)) {
            return res.status(400).json({ error: 'Invalid integration ID format' });
        }

        const result = await execCredentialCli('set', integration, credData);

        if (result.success) {
            console.log(`✓ Credential stored for integration: ${integration}`);
            res.status(201).json({
                success: true,
                message: `Credential stored for ${integration}`
            });
        } else {
            res.status(500).json({ error: result.error || 'Failed to store credential' });
        }
    } catch (error) {
        console.error('Error storing credential:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * DELETE /api/credentials/:integration
 * Delete credential for an integration
 */
app.delete('/api/credentials/:integration', async (req, res) => {
    try {
        const { integration } = req.params;

        const result = await execCredentialCli('delete', integration);

        if (result.success) {
            console.log(`✓ Credential deleted for integration: ${integration}`);
            res.json({
                success: true,
                message: `Credential deleted for ${integration}`
            });
        } else {
            if (result.error && result.error.includes('not found')) {
                res.status(404).json({ error: result.error });
            } else {
                res.status(500).json({ error: result.error || 'Failed to delete credential' });
            }
        }
    } catch (error) {
        console.error('Error deleting credential:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * GET /api/credentials/:integration/verify
 * Verify credential exists (NEVER returns actual values)
 */
app.get('/api/credentials/:integration/verify', async (req, res) => {
    try {
        const { integration } = req.params;

        const result = await execCredentialCli('verify', integration);

        if (result.success) {
            res.json({
                integration_id: integration,
                exists: result.data.exists
            });
        } else {
            res.status(500).json({ error: result.error || 'Failed to verify credential' });
        }
    } catch (error) {
        console.error('Error verifying credential:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * GET /api/credentials/:integration/info
 * Get non-sensitive info about credential (type, dates, field presence)
 */
app.get('/api/credentials/:integration/info', async (req, res) => {
    try {
        const { integration } = req.params;

        const result = await execCredentialCli('info', integration);

        if (result.success) {
            res.json({
                integration_id: integration,
                ...result.data
            });
        } else {
            if (result.error && result.error.includes('not found')) {
                res.status(404).json({ error: result.error });
            } else {
                res.status(500).json({ error: result.error || 'Failed to get credential info' });
            }
        }
    } catch (error) {
        console.error('Error getting credential info:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * GET /api/credentials
 * List all integration IDs (no values)
 */
app.get('/api/credentials', async (req, res) => {
    try {
        const result = await execCredentialCli('list');

        if (result.success) {
            res.json({
                integrations: result.data.integrations
            });
        } else {
            res.status(500).json({ error: result.error || 'Failed to list credentials' });
        }
    } catch (error) {
        console.error('Error listing credentials:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

// ============================================================================
// DASHBOARD CONFIGURATION API (CRUD)
// ============================================================================

const DASHBOARDS_FILE = path.join(__dirname, 'data', 'dashboards.json');

/**
 * Load dashboard configuration from file
 */
function loadDashboardConfig() {
    try {
        if (fs.existsSync(DASHBOARDS_FILE)) {
            return JSON.parse(fs.readFileSync(DASHBOARDS_FILE, 'utf8'));
        }
    } catch (error) {
        console.error('Error loading dashboard config:', error.message);
    }
    return { dashboards: [], divisions: [], meta: { version: '1.0.0' } };
}

/**
 * Save dashboard configuration to file
 */
function saveDashboardConfig(config) {
    try {
        const dataDir = path.dirname(DASHBOARDS_FILE);
        if (!fs.existsSync(dataDir)) {
            fs.mkdirSync(dataDir, { recursive: true });
        }
        config.meta.last_modified = new Date().toISOString();
        fs.writeFileSync(DASHBOARDS_FILE, JSON.stringify(config, null, 2));
        return true;
    } catch (error) {
        console.error('Error saving dashboard config:', error.message);
        return false;
    }
}

/**
 * Generate a URL-safe ID from a name
 */
function generateDashboardId(name) {
    return name.toLowerCase()
        .replace(/[^a-z0-9]+/g, '-')
        .replace(/^-|-$/g, '')
        .substring(0, 30);
}

/**
 * GET /api/dashboards
 * List all dashboard configurations
 */
app.get('/api/dashboards', (req, res) => {
    try {
        const config = loadDashboardConfig();
        const dashboards = config.dashboards.sort((a, b) => (a.sort_order || 999) - (b.sort_order || 999));
        res.json({
            dashboards,
            total: dashboards.length
        });
    } catch (error) {
        console.error('Error listing dashboards:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * PUT /api/dashboards/reorder
 * Reorder dashboards by providing an array of IDs in the desired order
 * NOTE: This route MUST be defined before /api/dashboards/:id to avoid matching "reorder" as an ID
 */
app.put('/api/dashboards/reorder', (req, res) => {
    try {
        const { order } = req.body;

        if (!order || !Array.isArray(order)) {
            return res.status(400).json({ error: 'Order must be an array of dashboard IDs' });
        }

        const config = loadDashboardConfig();

        // Validate all IDs exist
        const existingIds = new Set(config.dashboards.map(d => d.id));
        for (const id of order) {
            if (!existingIds.has(id)) {
                return res.status(400).json({ error: `Dashboard "${id}" not found` });
            }
        }

        // Update sort_order for each dashboard
        order.forEach((id, index) => {
            const dashboard = config.dashboards.find(d => d.id === id);
            if (dashboard) {
                dashboard.sort_order = index + 1;
                dashboard.updated_at = new Date().toISOString();
            }
        });

        // Sort dashboards array by new sort_order
        config.dashboards.sort((a, b) => (a.sort_order || 999) - (b.sort_order || 999));

        if (saveDashboardConfig(config)) {
            console.log(`✓ Dashboard order updated: ${order.join(', ')}`);
            res.json({
                success: true,
                order: config.dashboards.map(d => d.id)
            });
        } else {
            res.status(500).json({ error: 'Failed to save dashboard configuration' });
        }
    } catch (error) {
        console.error('Error reordering dashboards:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * GET /api/dashboards/:id
 * Get a single dashboard by ID
 */
app.get('/api/dashboards/:id', (req, res) => {
    try {
        const { id } = req.params;
        const config = loadDashboardConfig();
        const dashboard = config.dashboards.find(d => d.id === id);

        if (!dashboard) {
            return res.status(404).json({ error: 'Dashboard not found' });
        }

        res.json(dashboard);
    } catch (error) {
        console.error('Error getting dashboard:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * POST /api/dashboards
 * Create a new dashboard configuration
 */
app.post('/api/dashboards', (req, res) => {
    try {
        const { name, title, subtitle, description, divisions, machines, org_color } = req.body;

        // Validation
        if (!name || !name.trim()) {
            return res.status(400).json({ error: 'Dashboard name is required' });
        }

        const config = loadDashboardConfig();

        // Generate ID from name
        let id = generateDashboardId(name);

        // Check for duplicate ID
        if (config.dashboards.some(d => d.id === id)) {
            // Add numeric suffix
            let suffix = 2;
            while (config.dashboards.some(d => d.id === `${id}-${suffix}`)) {
                suffix++;
            }
            id = `${id}-${suffix}`;
        }

        // Calculate next sort order
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
            machines: machines || [],
            org_color: org_color || 'lavender',
            system: false,
            sort_order: maxOrder + 1,
            created_at: now,
            updated_at: now
        };

        config.dashboards.push(newDashboard);

        if (saveDashboardConfig(config)) {
            console.log(`✓ Created dashboard: ${newDashboard.name} (${id})`);
            res.status(201).json(newDashboard);
        } else {
            res.status(500).json({ error: 'Failed to save dashboard configuration' });
        }
    } catch (error) {
        console.error('Error creating dashboard:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * PUT /api/dashboards/:id
 * Update an existing dashboard configuration
 */
app.put('/api/dashboards/:id', (req, res) => {
    try {
        const { id } = req.params;
        const { name, title, subtitle, description, divisions, machines, org_color, sort_order, show_all_fleet_on, visible_dashboards } = req.body;

        const config = loadDashboardConfig();
        const index = config.dashboards.findIndex(d => d.id === id);

        if (index === -1) {
            return res.status(404).json({ error: 'Dashboard not found' });
        }

        const dashboard = config.dashboards[index];

        // Update fields (preserve system-protected fields)
        if (name && name.trim()) dashboard.name = name.trim();
        if (title) dashboard.title = title.toUpperCase().trim();
        if (subtitle) dashboard.subtitle = subtitle.toUpperCase().trim();
        if (description !== undefined) dashboard.description = description;
        if (divisions !== undefined) dashboard.divisions = divisions;
        if (machines !== undefined) dashboard.machines = machines;
        if (org_color) dashboard.org_color = org_color;
        if (sort_order !== undefined) dashboard.sort_order = sort_order;
        if (show_all_fleet_on !== undefined) dashboard.show_all_fleet_on = show_all_fleet_on;
        if (visible_dashboards !== undefined) dashboard.visible_dashboards = visible_dashboards;
        dashboard.updated_at = new Date().toISOString();

        if (saveDashboardConfig(config)) {
            console.log(`✓ Updated dashboard: ${dashboard.name} (${id})`);
            res.json(dashboard);
        } else {
            res.status(500).json({ error: 'Failed to save dashboard configuration' });
        }
    } catch (error) {
        console.error('Error updating dashboard:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * DELETE /api/dashboards/:id
 * Delete a dashboard configuration (system dashboards cannot be deleted)
 */
app.delete('/api/dashboards/:id', (req, res) => {
    try {
        const { id } = req.params;
        const config = loadDashboardConfig();
        const index = config.dashboards.findIndex(d => d.id === id);

        if (index === -1) {
            return res.status(404).json({ error: 'Dashboard not found' });
        }

        const dashboard = config.dashboards[index];

        // Prevent deletion of system dashboards
        if (dashboard.system) {
            return res.status(403).json({
                error: 'Cannot delete system dashboard',
                message: `The "${dashboard.name}" dashboard is a system dashboard and cannot be deleted.`
            });
        }

        // Remove the dashboard
        config.dashboards.splice(index, 1);

        if (saveDashboardConfig(config)) {
            console.log(`✓ Deleted dashboard: ${dashboard.name} (${id})`);
            res.json({
                success: true,
                message: `Dashboard "${dashboard.name}" deleted`,
                deleted_id: id
            });
        } else {
            res.status(500).json({ error: 'Failed to save dashboard configuration' });
        }
    } catch (error) {
        console.error('Error deleting dashboard:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * GET /api/divisions
 * List all available divisions for dashboard configuration (static from config)
 */
app.get('/api/divisions', (req, res) => {
    try {
        const config = loadDashboardConfig();
        res.json({
            divisions: config.divisions || [],
            total: (config.divisions || []).length
        });
    } catch (error) {
        console.error('Error listing divisions:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * GET /api/active-divisions
 * List divisions currently active in fleet data (dynamic from live sessions)
 */
app.get('/api/active-divisions', (req, res) => {
    try {
        const fleetData = parseFleetData();
        const activeDivisions = Object.keys(fleetData.fleet.divisions).map(divKey => {
            const divData = fleetData.fleet.divisions[divKey];
            return {
                id: divKey,
                name: divData.name,
                total_sessions: divData.total_sessions
            };
        }).sort((a, b) => a.name.localeCompare(b.name));

        res.json({
            divisions: activeDivisions,
            total: activeDivisions.length,
            source: 'live_fleet_data'
        });
    } catch (error) {
        console.error('Error listing active divisions:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * GET /api/machines/list
 * List all machines for dashboard filtering
 */
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
            // Sort: online first, then by display name
            if (a.status !== b.status) {
                return a.status === 'online' ? -1 : 1;
            }
            return a.display_name.localeCompare(b.display_name);
        });

        res.json({
            machines: machineList,
            total: machineList.length,
            online: machineList.filter(m => m.status === 'online').length,
            offline: machineList.filter(m => m.status === 'offline').length
        });
    } catch (error) {
        console.error('Error listing machines:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

// ============================================================================
// XACA-0281: AI ENGINES REGISTRY API
// Generic, multi-engine ready registry (Anthropic today; OpenAI/Ollama/etc. later).
// Accounts carry only metadata — never actual key values.
// ============================================================================

/**
 * Validation helpers for engines routes.
 */
const ACCOUNT_SLUG_RE    = /^[a-z][a-z0-9-]*$/;
const ENV_VAR_NAME_RE    = /^[A-Z][A-Z0-9_]*$/;
const MAX_FIELD_LEN      = 200;
const MAX_SLUG_LEN       = 64;

function validateAccountBody(body) {
    const errors = [];
    const { slug, account_id, nickname, env_var_name } = body;

    if (!slug || typeof slug !== 'string') {
        errors.push('slug is required');
    } else if (!ACCOUNT_SLUG_RE.test(slug)) {
        errors.push('slug must match ^[a-z][a-z0-9-]*$');
    } else if (slug.length > MAX_SLUG_LEN) {
        errors.push(`slug max length is ${MAX_SLUG_LEN}`);
    }

    if (!account_id || typeof account_id !== 'string' || !account_id.trim()) {
        errors.push('account_id is required and must be non-empty');
    } else if (account_id.trim().length > MAX_FIELD_LEN) {
        errors.push(`account_id max length is ${MAX_FIELD_LEN}`);
    }

    if (!nickname || typeof nickname !== 'string' || !nickname.trim()) {
        errors.push('nickname is required and must be non-empty');
    } else if (nickname.trim().length > MAX_FIELD_LEN) {
        errors.push(`nickname max length is ${MAX_FIELD_LEN}`);
    }

    if (!env_var_name || typeof env_var_name !== 'string') {
        errors.push('env_var_name is required');
    } else if (!ENV_VAR_NAME_RE.test(env_var_name)) {
        errors.push('env_var_name must match ^[A-Z][A-Z0-9_]*$');
    } else if (env_var_name.length > MAX_FIELD_LEN) {
        errors.push(`env_var_name max length is ${MAX_FIELD_LEN}`);
    }

    return errors;
}

/**
 * GET /api/engines
 * Return the full engines registry (version, updated_at, engines with accounts).
 */
app.get('/api/engines', (req, res) => {
    try {
        const registry = enginesStore.readEngines();
        res.json({
            version: registry.version,
            updated_at: registry.updated_at,
            engines: registry.engines
        });
    } catch (error) {
        console.error('Error reading engines registry:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * GET /api/engines/:engineSlug
 * Return a single engine with its accounts.
 */
app.get('/api/engines/:engineSlug', (req, res) => {
    try {
        const { engineSlug } = req.params;
        const engine = enginesStore.findEngine(engineSlug);
        if (!engine) {
            return res.status(404).json({ error: `Engine '${engineSlug}' not found` });
        }
        res.json(engine);
    } catch (error) {
        console.error('Error reading engine:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * POST /api/engines/:engineSlug/accounts
 * Add a new account to an engine.
 * Body: { slug, account_id, nickname, env_var_name }
 * Returns 201 + new account on success.
 * Returns 404 if engineSlug unknown, 409 on slug collision, 400 on validation failure.
 */
app.post('/api/engines/:engineSlug/accounts', (req, res) => {
    try {
        const { engineSlug } = req.params;
        const registry = enginesStore.readEngines();
        const engineIdx = registry.engines.findIndex(e => e.slug === engineSlug);
        if (engineIdx === -1) {
            return res.status(404).json({ error: `Engine '${engineSlug}' not found` });
        }

        const errors = validateAccountBody(req.body);
        if (errors.length > 0) {
            return res.status(400).json({ error: 'Validation failed', details: errors });
        }

        const { slug, account_id, nickname, env_var_name } = req.body;
        const engine = registry.engines[engineIdx];

        // 409 on slug collision
        if (engine.accounts.some(a => a.slug === slug)) {
            return res.status(409).json({ error: `Account slug '${slug}' already exists in engine '${engineSlug}'` });
        }

        const now = new Date().toISOString();
        const newAccount = {
            slug,
            account_id: account_id.trim(),
            nickname: nickname.trim(),
            env_var_name,
            created_at: now,
            updated_at: now,
            last_validated_at: null
        };

        engine.accounts.push(newAccount);
        engine.updated_at = now;
        registry.updated_at = now;

        if (!enginesStore.writeEngines(registry)) {
            return res.status(500).json({ error: 'Failed to save engines registry' });
        }

        console.log(`✓ Added account '${slug}' to engine '${engineSlug}'`);
        res.status(201).json(newAccount);
    } catch (error) {
        console.error('Error adding account:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * PUT /api/engines/:engineSlug/accounts/:accountSlug
 * Update an existing account (account_id, nickname, env_var_name are mutable; slug is immutable).
 * Returns the updated account; 404 if engine or account missing; 400 on validation failure.
 */
app.put('/api/engines/:engineSlug/accounts/:accountSlug', (req, res) => {
    try {
        const { engineSlug, accountSlug } = req.params;
        const registry = enginesStore.readEngines();
        const engineIdx = registry.engines.findIndex(e => e.slug === engineSlug);
        if (engineIdx === -1) {
            return res.status(404).json({ error: `Engine '${engineSlug}' not found` });
        }

        const engine = registry.engines[engineIdx];
        const accountIdx = engine.accounts.findIndex(a => a.slug === accountSlug);
        if (accountIdx === -1) {
            return res.status(404).json({ error: `Account '${accountSlug}' not found in engine '${engineSlug}'` });
        }

        // Validate only the fields provided — build a merged candidate for validation
        const existing = engine.accounts[accountIdx];
        const candidate = {
            slug: accountSlug, // slug is immutable
            account_id:   req.body.account_id  !== undefined ? req.body.account_id  : existing.account_id,
            nickname:     req.body.nickname     !== undefined ? req.body.nickname     : existing.nickname,
            env_var_name: req.body.env_var_name !== undefined ? req.body.env_var_name : existing.env_var_name
        };

        const errors = validateAccountBody(candidate);
        if (errors.length > 0) {
            return res.status(400).json({ error: 'Validation failed', details: errors });
        }

        const now = new Date().toISOString();
        engine.accounts[accountIdx] = {
            ...existing,
            account_id:   candidate.account_id.trim(),
            nickname:     candidate.nickname.trim(),
            env_var_name: candidate.env_var_name,
            updated_at:   now
        };
        engine.updated_at = now;
        registry.updated_at = now;

        if (!enginesStore.writeEngines(registry)) {
            return res.status(500).json({ error: 'Failed to save engines registry' });
        }

        console.log(`✓ Updated account '${accountSlug}' in engine '${engineSlug}'`);
        res.json(engine.accounts[accountIdx]);
    } catch (error) {
        console.error('Error updating account:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * DELETE /api/engines/:engineSlug/accounts/:accountSlug
 * Remove an account from an engine.
 * Requires ?confirm=true to execute; without it returns usage info for a confirmation prompt.
 * Response always includes a `usage` field listing teams currently referencing this account
 * (populated in a future phase when machines push team-paths attribution data).
 * Returns { deleted: true, slug, usage } on success; 404 if engine or account missing.
 */
app.delete('/api/engines/:engineSlug/accounts/:accountSlug', (req, res) => {
    try {
        const { engineSlug, accountSlug } = req.params;
        const { confirm } = req.query;

        const registry = enginesStore.readEngines();
        const engineIdx = registry.engines.findIndex(e => e.slug === engineSlug);
        if (engineIdx === -1) {
            return res.status(404).json({ error: `Engine '${engineSlug}' not found` });
        }

        const engine = registry.engines[engineIdx];
        const accountIdx = engine.accounts.findIndex(a => a.slug === accountSlug);
        if (accountIdx === -1) {
            return res.status(404).json({ error: `Account '${accountSlug}' not found in engine '${engineSlug}'` });
        }

        // Build usage list: teams referencing this account.
        // Phase A.3+ will populate this from machine-pushed attribution data.
        // For now returns empty array — the shape is established for forward compatibility.
        const usage = [];

        if (confirm !== 'true') {
            // Dry-run: return usage info without deleting, so the UI can prompt the user
            return res.status(200).json({
                deleted: false,
                slug: accountSlug,
                message: 'Send ?confirm=true to execute deletion',
                usage
            });
        }

        engine.accounts.splice(accountIdx, 1);
        const now = new Date().toISOString();
        engine.updated_at = now;
        registry.updated_at = now;

        if (!enginesStore.writeEngines(registry)) {
            return res.status(500).json({ error: 'Failed to save engines registry' });
        }

        console.log(`✓ Deleted account '${accountSlug}' from engine '${engineSlug}'`);
        res.json({ deleted: true, slug: accountSlug, usage });
    } catch (error) {
        console.error('Error deleting account:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

// ============================================================================
// TEAM CONFIGURATION API (Auto-Discovery)
// ============================================================================

/**
 * GET /api/team-config
 * Returns comprehensive team configuration including terminal/persona metadata
 * If called without parameters: returns ALL registered teams with full metadata
 * If called with ?team=<teamId>: returns just that team's configuration
 */
app.get('/api/team-config', (req, res) => {
    const { team } = req.query;

    try {
        // If specific team requested, return just that team
        if (team) {
            const teamData = registeredTeams.get(team);
            if (!teamData) {
                return res.status(404).json({ error: `Team '${team}' not found` });
            }

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

        // Return all registered teams with full metadata
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

            // Group teams by organization
            if (!organizations[teamData.organization]) {
                organizations[teamData.organization] = {
                    color: teamData.orgColor,
                    teams: []
                };
            }
            organizations[teamData.organization].teams.push(teamId);
        }

        // If no teams are registered yet, return empty but valid structure
        res.json({
            teams,
            organizations,
            timestamp: new Date().toISOString()
        });
    } catch (error) {
        console.error('Error reading team config:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * GET /api/team-config/:team/terminals
 * Returns terminal-to-persona mapping for a specific team
 * This is what clients use to look up avatar/developer info for a terminal
 */
app.get('/api/team-config/:team/terminals', (req, res) => {
    const { team } = req.params;

    try {
        const teamData = registeredTeams.get(team);
        if (!teamData) {
            return res.status(404).json({ error: `Team '${team}' not found` });
        }

        res.json({
            team: teamData.team,
            terminals: teamData.terminals
        });
    } catch (error) {
        console.error(`Error reading terminals for team ${team}:`, error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

// ============================================================================
// KANBAN WORKING ITEMS API
// ============================================================================

/**
 * GET /api/working-items
 * Current working items from kanban boards
 */
app.get('/api/working-items', (req, res) => {
    const workingItems = {};

    try {
        for (const team of getAllTeamIds()) {
            try {
                const board = getBoardData(team);
                if (!board) continue;

                const backlog = board.backlog || [];

                // Find items in "actively-working" status
                const activeItem = backlog.find(item => item.status === 'actively-working');

                if (activeItem) {
                    // Check for active subitems
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
            } catch (e) {
                // Skip boards that can't be read
            }
        }
    } catch (error) {
        console.error('Error reading kanban boards:', error);
    }

    res.json(workingItems);
});

// ============================================================================
// KANBAN STATS API
// ============================================================================

/**
 * Calculate kanban statistics for a single board
 * @param {string} teamId - Team identifier
 * @param {object} board - Parsed board JSON object
 * @returns {object} - Stats for this team
 */
function calcBoardStats(teamId, board) {
    const backlog = board.backlog || [];
    const epics = board.epics || [];
    const sevenDaysAgo = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000);

    // Count items by status (dynamic - all statuses, not just predefined ones)
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

    // Epic stats - epics reference items via itemIds array
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

    // Subitem stats
    let subTotal = 0;
    let subCompleted = 0;
    for (const item of backlog) {
        const subs = item.subitems || [];
        subTotal += subs.length;
        subCompleted += subs.filter(s => s.status === 'completed').length;
    }

    // Recent activity - items completed or added in last 7 days
    let completedLast7Days = 0;
    let createdLast7Days = 0;
    for (const item of backlog) {
        if (item.completedAt && new Date(item.completedAt) > sevenDaysAgo) {
            completedLast7Days++;
        }
        if (item.addedAt && new Date(item.addedAt) > sevenDaysAgo) {
            createdLast7Days++;
        }
    }

    return {
        teamId,
        displayName: board.teamName || teamId.charAt(0).toUpperCase() + teamId.slice(1),
        statusCounts,
        totalItems,
        completionRate,
        epics: epicStats,
        subitemStats: {
            total: subTotal,
            completed: subCompleted,
            pending: subTotal - subCompleted
        },
        recentActivity: {
            completedLast7Days,
            createdLast7Days
        }
    };
}

/**
 * GET /api/kanban-stats
 * Returns kanban statistics for all teams or a specific team
 * Query params:
 *   team=<teamId> - Filter to a single team (optional)
 */
app.get('/api/kanban-stats', (req, res) => {
    const { team } = req.query;

    try {
        const teamStats = {};
        let teamsToProcess = [];

        if (team) {
            // Single team request — check pushed boards first, then filesystem
            const board = getBoardData(team);
            if (!board) {
                return res.status(404).json({ error: `Team '${team}' not found` });
            }
            teamsToProcess = [team];
        } else {
            // All teams — merge pushed board team IDs with filesystem team IDs
            teamsToProcess = getAllTeamIds();
        }

        // Process each board
        for (const teamId of teamsToProcess) {
            try {
                const board = getBoardData(teamId);
                if (!board) {
                    teamStats[teamId] = {
                        teamId,
                        error: 'Board data not available'
                    };
                    continue;
                }
                teamStats[teamId] = calcBoardStats(teamId, board);
            } catch (e) {
                // Board data unreadable or invalid - report error for this team
                console.error(`[kanban-stats] Could not process board for ${teamId}:`, e.message);
                teamStats[teamId] = {
                    teamId,
                    error: `Could not read board: ${e.message}`
                };
            }
        }

        // Aggregate overall stats across all teams (skip teams with errors)
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

        const overall = {
            totalTeams: Object.keys(teamStats).length,
            validTeams: validTeams.length,
            totalItems: overallTotal,
            totalCompleted: overallCompleted,
            overallCompletionRate,
            statusCounts: overallStatusCounts
        };

        res.json({
            teams: teamStats,
            overall,
            timestamp: new Date().toISOString()
        });
    } catch (error) {
        console.error('Error calculating kanban stats:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * GET /api/epics
 * Get all Epics from all team boards
 * Returns: { team: [ { epic data with calculated progress } ] }
 */
app.get('/api/epics', (req, res) => {
    const allEpics = {};

    try {
        for (const team of getAllTeamIds()) {
            try {
                const board = getBoardData(team);
                if (!board) continue;

                const epics = board.epics || [];
                const backlog = board.backlog || [];

                if (epics.length > 0) {
                    // Calculate progress for each Epic
                    allEpics[team] = epics.map(epic => {
                        const itemIds = epic.itemIds || [];
                        const items = backlog.filter(item => itemIds.includes(item.id));

                        const totalItems = items.length;
                        const completedItems = items.filter(i => i.status === 'completed').length;
                        const cancelledItems = items.filter(i => i.status === 'cancelled').length;
                        const inProgressItems = items.filter(i => i.status === 'in_progress').length;
                        const blockedItems = items.filter(i => i.status === 'blocked').length;
                        const todoItems = items.filter(i => i.status === 'todo').length;
                        const resolvedItems = completedItems + cancelledItems;

                        const percentComplete = totalItems > 0 ? Math.floor((resolvedItems * 100) / totalItems) : 0;

                        return {
                            ...epic,
                            progress: {
                                totalItems,
                                completedItems,
                                cancelledItems,
                                resolvedItems,
                                inProgressItems,
                                blockedItems,
                                todoItems,
                                percentComplete
                            },
                            items: items.map(item => ({
                                id: item.id,
                                title: item.title,
                                status: item.status,
                                priority: item.priority
                            }))
                        };
                    });
                }
            } catch (e) {
                // Skip boards that can't be read
                console.log(`[Epics] Could not read ${team}:`, e.message);
            }
        }
    } catch (error) {
        console.error('Error reading epic data:', error);
    }

    res.json(allEpics);
});

/**
 * GET /api/epics/:team
 * Get Epics for a specific team
 */
app.get('/api/epics/:team', (req, res) => {
    const { team } = req.params;

    try {
        const board = getBoardData(team);
        if (!board) {
            return res.status(404).json({ error: `Team '${team}' not found` });
        }

        const epics = board.epics || [];
        const backlog = board.backlog || [];

        // Calculate progress for each Epic
        const epicsWithProgress = epics.map(epic => {
            const itemIds = epic.itemIds || [];
            const items = backlog.filter(item => itemIds.includes(item.id));

            const totalItems = items.length;
            const completedItems = items.filter(i => i.status === 'completed').length;
            const cancelledItems = items.filter(i => i.status === 'cancelled').length;
            const inProgressItems = items.filter(i => i.status === 'in_progress').length;
            const blockedItems = items.filter(i => i.status === 'blocked').length;
            const todoItems = items.filter(i => i.status === 'todo').length;
            const resolvedItems = completedItems + cancelledItems;

            const percentComplete = totalItems > 0 ? Math.floor((resolvedItems * 100) / totalItems) : 0;

            return {
                ...epic,
                progress: {
                    totalItems,
                    completedItems,
                    cancelledItems,
                    resolvedItems,
                    inProgressItems,
                    blockedItems,
                    todoItems,
                    percentComplete
                },
                items: items.map(item => ({
                    id: item.id,
                    title: item.title,
                    status: item.status,
                    priority: item.priority,
                    subitems: (item.subitems || []).map(sub => ({
                        id: sub.id,
                        title: sub.title,
                        status: sub.status
                    }))
                }))
            };
        });

        res.json({
            team,
            epics: epicsWithProgress,
            total: epicsWithProgress.length
        });
    } catch (error) {
        console.error(`Error reading epics for team ${team}:`, error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * POST /api/epics/:team
 * Create a new Epic for a team
 */
app.post('/api/epics/:team', (req, res) => {
    const { team } = req.params;
    const { title, description, priority, category, dueDate } = req.body;
    const boardPath = findBoardPath(team);

    if (!title) {
        return res.status(400).json({ error: 'Title is required' });
    }

    try {
        if (!boardPath) {
            return res.status(404).json({ error: `Team '${team}' not found` });
        }

        const board = JSON.parse(fs.readFileSync(boardPath, 'utf8'));

        // Ensure epics support
        if (!board.epics) board.epics = [];
        if (!board.nextEpicId) board.nextEpicId = 1;

        // Get team code for Epic ID
        const teamCodes = {
            'academy': 'ACA', 'ios': 'IOS', 'android': 'AND', 'firebase': 'FIR',
            'freelance': 'FRE', 'dns': 'DNS', 'command': 'CMD', 'mainevent': 'MEV'
        };
        const teamCode = teamCodes[team.toLowerCase()] || team.slice(0, 3).toUpperCase();
        const epicId = `E${teamCode}-${String(board.nextEpicId).padStart(4, '0')}`;

        const timestamp = new Date().toISOString();
        const newEpic = {
            id: epicId,
            title,
            description: description || '',
            status: 'planning',
            priority: priority || 'medium',
            itemIds: [],
            addedAt: timestamp,
            updatedAt: timestamp,
            tags: [],
            collapsed: false
        };

        if (category) newEpic.category = category;
        if (dueDate) newEpic.dueDate = dueDate;

        board.epics.push(newEpic);
        board.nextEpicId++;
        board.lastUpdated = timestamp;

        fs.writeFileSync(boardPath, JSON.stringify(board, null, 2));

        res.status(201).json({ message: 'Epic created', epic: newEpic });
    } catch (error) {
        console.error(`Error creating epic for team ${team}:`, error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * PUT /api/epics/:team/:epicId
 * Update an existing Epic
 */
app.put('/api/epics/:team/:epicId', (req, res) => {
    const { team, epicId } = req.params;
    const updates = req.body;
    const boardPath = findBoardPath(team);

    try {
        if (!boardPath) {
            return res.status(404).json({ error: `Team '${team}' not found` });
        }

        const board = JSON.parse(fs.readFileSync(boardPath, 'utf8'));
        const epicIndex = (board.epics || []).findIndex(e => e.id === epicId);

        if (epicIndex === -1) {
            return res.status(404).json({ error: `Epic '${epicId}' not found` });
        }

        const timestamp = new Date().toISOString();

        // Update allowed fields
        const allowedFields = ['title', 'description', 'status', 'priority', 'category', 'dueDate', 'collapsed'];
        for (const field of allowedFields) {
            if (updates[field] !== undefined) {
                board.epics[epicIndex][field] = updates[field];
            }
        }

        board.epics[epicIndex].updatedAt = timestamp;
        board.lastUpdated = timestamp;

        fs.writeFileSync(boardPath, JSON.stringify(board, null, 2));

        res.json({ message: 'Epic updated', epic: board.epics[epicIndex] });
    } catch (error) {
        console.error(`Error updating epic ${epicId}:`, error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * DELETE /api/epics/:team/:epicId
 * Delete an Epic
 */
app.delete('/api/epics/:team/:epicId', (req, res) => {
    const { team, epicId } = req.params;
    const boardPath = findBoardPath(team);

    try {
        if (!boardPath) {
            return res.status(404).json({ error: `Team '${team}' not found` });
        }

        const board = JSON.parse(fs.readFileSync(boardPath, 'utf8'));
        const epicIndex = (board.epics || []).findIndex(e => e.id === epicId);

        if (epicIndex === -1) {
            return res.status(404).json({ error: `Epic '${epicId}' not found` });
        }

        // Get the Epic's itemIds to clear epicId from those items
        const itemIds = board.epics[epicIndex].itemIds || [];

        // Remove epicId from items
        for (const item of board.backlog || []) {
            if (itemIds.includes(item.id)) {
                delete item.epicId;
            }
        }

        // Remove the Epic
        board.epics.splice(epicIndex, 1);
        board.lastUpdated = new Date().toISOString();

        fs.writeFileSync(boardPath, JSON.stringify(board, null, 2));

        res.json({ message: 'Epic deleted', deletedId: epicId });
    } catch (error) {
        console.error(`Error deleting epic ${epicId}:`, error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * GET /
 * Serve dashboard
 */
app.get('/', (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

/**
 * GET /all
 * Serve full fleet dashboard (all teams)
 */
app.get('/all', (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'all.html'));
});

/**
 * GET /mainevent
 * Serve Main Event filtered dashboard
 */
app.get('/mainevent', (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'mainevent.html'));
});

/**
 * GET /doublenode
 * Serve DoubleNode filtered dashboard (includes Academy)
 */
app.get('/doublenode', (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'doublenode.html'));
});

// ============================================================================
// LCARS DASHBOARD ROUTES
// ============================================================================

/**
 * GET /lcars or /lcars/
 * Redirect to unified dashboard (Academy is the default)
 */
app.get('/lcars', (req, res, next) => {
    if (req.originalUrl === '/lcars') {
        return res.redirect(302, '/lcars/lcars-dashboard.html?dashboard=academy');
    }
    next();
});

app.get('/lcars/', (req, res) => {
    res.redirect(302, '/lcars/lcars-dashboard.html?dashboard=academy');
});

/**
 * GET /lcars/mainevent
 * Redirect to unified Main Event dashboard
 */
app.get('/lcars/mainevent', (req, res) => {
    res.redirect(302, '/lcars/lcars-dashboard.html?dashboard=mainevent');
});

/**
 * GET /lcars/doublenode
 * Redirect to unified DoubleNode dashboard
 */
app.get('/lcars/doublenode', (req, res) => {
    res.redirect(302, '/lcars/lcars-dashboard.html?dashboard=doublenode');
});

/**
 * GET /lcars/all
 * Redirect to unified All Fleet dashboard
 */
app.get('/lcars/all', (req, res) => {
    res.redirect(302, '/lcars/lcars-dashboard.html?dashboard=all');
});

/**
 * Serve LCARS static assets (CSS, JS, images)
 * Must come AFTER explicit routes to prevent directory redirect on /lcars
 */
app.use('/lcars', express.static(path.join(__dirname, 'public/lcars')));

// ============================================================================
// BACKGROUND TASKS
// ============================================================================

// Periodically update machine statuses
setInterval(() => {
    updateMachineStatuses();
}, 30 * 1000); // Every 30 seconds

// Periodically save machine data to file
setInterval(() => {
    saveMachineData();
}, SAVE_INTERVAL_MS);

// Periodically save pushed boards to file
setInterval(() => {
    savePushedBoards();
}, SAVE_INTERVAL_MS);

// Periodically save pushed knowledge stats to file
setInterval(() => {
    savePushedKnowledge();
}, SAVE_INTERVAL_MS);

// ============================================================================
// START SERVER
// ============================================================================

app.listen(PORT, () => {
    console.log('');
    console.log('╔══════════════════════════════════════════════════════════╗');
    console.log('║     STARFLEET OPERATIONS MONITOR - ONLINE                ║');
    console.log('╚══════════════════════════════════════════════════════════╝');
    console.log('');
    console.log(`  🖖  Server running on port ${PORT}`);
    console.log(`  📡  API endpoint: http://localhost:${PORT}/api/status`);
    console.log('');
    console.log('  Classic Dashboards:');
    console.log(`    🎓  Academy (default): http://localhost:${PORT}/`);
    console.log(`    🎯  Main Event: http://localhost:${PORT}/mainevent`);
    console.log(`    🔷  DoubleNode: http://localhost:${PORT}/doublenode`);
    console.log(`    🌐  All Teams: http://localhost:${PORT}/all`);
    console.log('');
    console.log('  LCARS Unified Dashboard:');
    console.log(`    🖖  Academy: http://localhost:${PORT}/lcars/lcars-dashboard.html?dashboard=academy`);
    console.log(`    🎯  Main Event: http://localhost:${PORT}/lcars/lcars-dashboard.html?dashboard=mainevent`);
    console.log(`    🔷  DoubleNode: http://localhost:${PORT}/lcars/lcars-dashboard.html?dashboard=doublenode`);
    console.log(`    🌐  All Fleet: http://localhost:${PORT}/lcars/lcars-dashboard.html?dashboard=all`);
    console.log('');
    console.log('  LCARS Shortcuts (redirect to unified):');
    console.log(`    /lcars → Academy  |  /lcars/mainevent  |  /lcars/doublenode  |  /lcars/all`);
    console.log('');
    console.log('  Configuration:');
    console.log(`    - Offline threshold: ${OFFLINE_THRESHOLD_MS / 1000}s`);
    console.log(`    - Warning threshold: ${WARNING_THRESHOLD_MS / 1000}s`);
    console.log('');
    console.log('  Ready to receive fleet status reports.');
    console.log('');
});

// Graceful shutdown - save data before exiting
process.on('SIGTERM', () => {
    console.log('Received SIGTERM, shutting down gracefully...');
    saveMachineData();
    savePushedKnowledge();
    process.exit(0);
});

process.on('SIGINT', () => {
    console.log('Received SIGINT, shutting down gracefully...');
    saveMachineData();
    savePushedKnowledge();
    process.exit(0);
});
