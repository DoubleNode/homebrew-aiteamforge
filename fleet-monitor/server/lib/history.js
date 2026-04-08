/**
 * Machine state history helpers
 *
 * Handles per-machine history files in data/history/, including logging
 * state changes, detecting diffs between heartbeats, and purging old entries.
 */

'use strict';

const path = require('path');
const fs   = require('fs');

const HISTORY_DIR            = path.join(__dirname, '..', 'data', 'history');
const HISTORY_RETENTION_DAYS = 7;
const HISTORY_PURGE_INTERVAL_MS = 60 * 60 * 1000; // hourly

// ============================================================================
// UTILITY
// ============================================================================

function generateUUID() {
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) {
        const r = Math.random() * 16 | 0;
        const v = c === 'x' ? r : (r & 0x3 | 0x8);
        return v.toString(16);
    });
}

/**
 * Format a millisecond duration in human-readable form.
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

// ============================================================================
// HISTORY FILE I/O
// ============================================================================

function ensureHistoryDir() {
    if (!fs.existsSync(HISTORY_DIR)) {
        fs.mkdirSync(HISTORY_DIR, { recursive: true });
        console.log('\u2713 Created history directory:', HISTORY_DIR);
    }
}

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

function saveMachineHistory(machineId, history) {
    try {
        ensureHistoryDir();
        const historyFile = path.join(HISTORY_DIR, `${machineId}.json`);
        fs.writeFileSync(historyFile, JSON.stringify(history, null, 2));
    } catch (error) {
        console.error(`Error saving history for ${machineId}:`, error.message);
    }
}

// ============================================================================
// LOGGING & CHANGE DETECTION
// ============================================================================

/**
 * Append a history entry for a machine.
 */
function logHistoryEntry(machineId, eventType, previousValue, newValue, details) {
    const entry = {
        id: generateUUID(),
        timestamp: new Date().toISOString(),
        event_type: eventType,
        previous_value: previousValue,
        new_value: newValue,
        details
    };

    const history = loadMachineHistory(machineId);
    history.unshift(entry); // newest first
    saveMachineHistory(machineId, history);

    console.log(`[HISTORY] ${machineId}: ${eventType} - ${details}`);
    return entry;
}

/**
 * Detect changes between existing machine state and new heartbeat data.
 * Returns an array of change objects to log.
 */
function detectChanges(existingMachine, newData, newSessions) {
    const changes   = [];
    const machineId = newData.machine_id;

    // First-seen detection
    if (!existingMachine) {
        changes.push({
            type: 'first_seen',
            previous: null,
            new: { hostname: newData.hostname, ip: newData.ip },
            details: `First connection from ${newData.hostname} (${newData.ip})`
        });
        return changes; // No other changes to detect for new machines
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
    const newSessionSet    = new Set((newSessions || []).map(s => s.session_name));

    for (const sessionName of newSessionSet) {
        if (!existingSessions.has(sessionName)) {
            changes.push({ type: 'session_start', previous: null, new: sessionName, details: `Session started: ${sessionName}` });
        }
    }
    for (const sessionName of existingSessions) {
        if (!newSessionSet.has(sessionName)) {
            changes.push({ type: 'session_stop', previous: sessionName, new: null, details: `Session ended: ${sessionName}` });
        }
    }

    return changes;
}

/**
 * Purge history entries older than HISTORY_RETENTION_DAYS.
 */
function purgeOldHistory() {
    try {
        ensureHistoryDir();
        const cutoff = Date.now() - (HISTORY_RETENTION_DAYS * 24 * 60 * 60 * 1000);
        const files  = fs.readdirSync(HISTORY_DIR).filter(f => f.endsWith('.json'));
        let totalPurged = 0;

        for (const file of files) {
            const filePath = path.join(HISTORY_DIR, file);
            const history  = JSON.parse(fs.readFileSync(filePath, 'utf8'));
            const filtered = history.filter(entry => new Date(entry.timestamp).getTime() > cutoff);

            if (filtered.length < history.length) {
                totalPurged += history.length - filtered.length;
                if (filtered.length === 0) {
                    fs.unlinkSync(filePath);
                } else {
                    fs.writeFileSync(filePath, JSON.stringify(filtered, null, 2));
                }
            }
        }

        if (totalPurged > 0) console.log(`\u2713 Purged ${totalPurged} old history entries`);
    } catch (error) {
        console.error('Error purging old history:', error.message);
    }
}

module.exports = {
    HISTORY_DIR,
    HISTORY_PURGE_INTERVAL_MS,
    generateUUID,
    formatDuration,
    ensureHistoryDir,
    loadMachineHistory,
    saveMachineHistory,
    logHistoryEntry,
    detectChanges,
    purgeOldHistory,
};
