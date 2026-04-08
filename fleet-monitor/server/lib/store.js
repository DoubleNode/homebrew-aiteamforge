/**
 * Shared in-memory state and data access helpers
 *
 * All route modules import from here to share the same Map instances
 * and board-lookup utilities.
 */

'use strict';

const path = require('path');
const fs   = require('fs');

// ============================================================================
// FILE PATHS
// ============================================================================

const DATA_FILE      = path.join(__dirname, '..', 'data', 'machines.json');
const TEAMS_FILE     = path.join(__dirname, '..', 'data', 'registered-teams.json');
const BOARDS_FILE    = path.join(__dirname, '..', 'data', 'pushed-boards.json');
const KNOWLEDGE_FILE = path.join(__dirname, '..', 'data', 'pushed-knowledge.json');

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

// ============================================================================
// IN-MEMORY STORES
// ============================================================================

// Structure: { hostname: { hostname, ip, os, last_seen, status, sessions, session_count } }
const machines = new Map();

// Structure: { teamName: { team, teamName, subtitle, ship, series, organization, orgColor, kanbanDir, fleetMonitorUrl, terminals, registeredAt, lastSeen } }
const registeredTeams = new Map();

// Structure: { teamId: { teamId, board, pushedAt, pushedBy } }
const pushedBoards = new Map();

// Structure: { teamId: { teamId, knowledge, pushedAt } }
const pushedKnowledge = new Map();

// Activity log - last 20 status updates for live UI display
const activityLog = [];
const MAX_ACTIVITY_LOG_ENTRIES = 20;

// ============================================================================
// PERSISTENCE - LOAD
// ============================================================================

function loadMachineData() {
    try {
        if (fs.existsSync(DATA_FILE)) {
            const data = JSON.parse(fs.readFileSync(DATA_FILE, 'utf8'));
            for (const [hostname, machineData] of Object.entries(data)) {
                machines.set(hostname, machineData);
            }
            console.log(`\u2713 Loaded ${machines.size} machines from persistent storage`);
        } else {
            console.log('No persistent data file found, starting fresh');
        }
    } catch (error) {
        console.error('Error loading machine data:', error.message);
    }
}

function loadRegisteredTeams() {
    try {
        if (fs.existsSync(TEAMS_FILE)) {
            const data = JSON.parse(fs.readFileSync(TEAMS_FILE, 'utf8'));
            for (const [teamId, teamData] of Object.entries(data)) {
                registeredTeams.set(teamId, teamData);
            }
            console.log(`\u2713 Loaded ${registeredTeams.size} registered teams from persistent storage`);
        } else {
            console.log('No registered teams file found, starting fresh');
        }
    } catch (error) {
        console.error('Error loading registered teams:', error.message);
    }
}

function loadPushedBoards() {
    try {
        if (fs.existsSync(BOARDS_FILE)) {
            const data = JSON.parse(fs.readFileSync(BOARDS_FILE, 'utf8'));
            for (const [teamId, boardData] of Object.entries(data)) {
                pushedBoards.set(teamId, boardData);
            }
            console.log(`\u2713 Loaded ${pushedBoards.size} pushed boards from persistent storage`);
        } else {
            console.log('No pushed boards file found, starting fresh');
        }
    } catch (error) {
        console.error('Error loading pushed boards:', error.message);
    }
}

function loadPushedKnowledge() {
    try {
        if (fs.existsSync(KNOWLEDGE_FILE)) {
            const data = JSON.parse(fs.readFileSync(KNOWLEDGE_FILE, 'utf8'));
            for (const [teamId, knowledgeData] of Object.entries(data)) {
                pushedKnowledge.set(teamId, knowledgeData);
            }
            console.log(`\u2713 Loaded ${pushedKnowledge.size} pushed knowledge stats from persistent storage`);
        } else {
            console.log('No pushed knowledge file found, starting fresh');
        }
    } catch (error) {
        console.error('Error loading pushed knowledge:', error.message);
    }
}

// ============================================================================
// PERSISTENCE - SAVE
// ============================================================================

function saveMachineData() {
    try {
        const dataDir = path.dirname(DATA_FILE);
        if (!fs.existsSync(dataDir)) fs.mkdirSync(dataDir, { recursive: true });
        const data = Object.fromEntries(machines);
        fs.writeFileSync(DATA_FILE, JSON.stringify(data, null, 2));
        console.log(`\u2713 Saved ${machines.size} machines to persistent storage`);
    } catch (error) {
        console.error('Error saving machine data:', error.message);
    }
}

function saveRegisteredTeams() {
    try {
        const dataDir = path.dirname(TEAMS_FILE);
        if (!fs.existsSync(dataDir)) fs.mkdirSync(dataDir, { recursive: true });
        const data = Object.fromEntries(registeredTeams);
        fs.writeFileSync(TEAMS_FILE, JSON.stringify(data, null, 2));
    } catch (error) {
        console.error('Error saving registered teams:', error.message);
    }
}

function savePushedBoards() {
    try {
        const dataDir = path.dirname(BOARDS_FILE);
        if (!fs.existsSync(dataDir)) fs.mkdirSync(dataDir, { recursive: true });
        const data = Object.fromEntries(pushedBoards);
        fs.writeFileSync(BOARDS_FILE, JSON.stringify(data, null, 2));
    } catch (error) {
        console.error('Error saving pushed boards:', error.message);
    }
}

function savePushedKnowledge() {
    try {
        const dataDir = path.dirname(KNOWLEDGE_FILE);
        if (!fs.existsSync(dataDir)) fs.mkdirSync(dataDir, { recursive: true });
        const data = Object.fromEntries(pushedKnowledge);
        fs.writeFileSync(KNOWLEDGE_FILE, JSON.stringify(data, null, 2));
    } catch (error) {
        console.error('Error saving pushed knowledge:', error.message);
    }
}

// ============================================================================
// BOARD ACCESS HELPERS
// ============================================================================

/**
 * Find the board file path for a specific team.
 * Uses registered team data first, falls back to KANBAN_DIRS for backward compatibility.
 * @param {string} teamId
 * @returns {string|null}
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
 * @param {string} teamId
 * @returns {object|null}
 */
function getBoardData(teamId) {
    // PRIMARY: Use pushed board data if available
    const pushed = pushedBoards.get(teamId);
    if (pushed && pushed.board) return pushed.board;

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
 * Scan all kanban directories and return board file paths.
 * Uses registered team data first, supplements with KANBAN_DIRS scan for backward compatibility.
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

/**
 * Get all team IDs from both pushedBoards and filesystem boards.
 * Pushed board team IDs take priority; filesystem supplements with any
 * teams not yet represented in pushedBoards.
 * @returns {string[]}
 */
function getAllTeamIds() {
    const seen = new Set();
    for (const teamId of pushedBoards.keys()) seen.add(teamId);
    for (const { teamId } of findAllBoardFiles()) seen.add(teamId);
    return Array.from(seen);
}

// ============================================================================
// ACTIVITY LOG HELPER
// ============================================================================

/**
 * Log activity for the live activity log display.
 * @param {string} type   - 'STATUS' | 'CONNECT' | 'OFFLINE' | 'RECONNECT'
 * @param {string} hostname
 * @param {string} ip
 * @param {number} sessionCount
 * @param {string} [extra]
 */
function logActivity(type, hostname, ip, sessionCount, extra = '') {
    const now     = new Date();
    const timeStr = now.toLocaleTimeString('en-US', { hour12: false, hour: '2-digit', minute: '2-digit', second: '2-digit' });

    let message = `[${timeStr}] ${type.padEnd(8)} ${hostname}`;
    if (ip && ip !== 'unknown') message += ` (${ip})`;
    if (type === 'STATUS') message += ` ${sessionCount} session${sessionCount !== 1 ? 's' : ''}`;
    if (extra) message += ` ${extra}`;

    activityLog.unshift({ timestamp: now.toISOString(), type, hostname, ip, session_count: sessionCount, message });
    while (activityLog.length > MAX_ACTIVITY_LOG_ENTRIES) activityLog.pop();
}

// ============================================================================
// EXPORTS
// ============================================================================

module.exports = {
    // Data file paths (needed by some routes that write directly)
    DATA_FILE,
    TEAMS_FILE,
    BOARDS_FILE,
    KNOWLEDGE_FILE,
    KANBAN_DIRS,

    // In-memory stores
    machines,
    registeredTeams,
    pushedBoards,
    pushedKnowledge,
    activityLog,

    // Load/save
    loadMachineData,
    loadRegisteredTeams,
    loadPushedBoards,
    loadPushedKnowledge,
    saveMachineData,
    saveRegisteredTeams,
    savePushedBoards,
    savePushedKnowledge,

    // Board access
    findBoardPath,
    getBoardData,
    findAllBoardFiles,
    getAllTeamIds,

    // Activity log
    logActivity,
};
