#!/usr/bin/env node
/**
 * Starfleet Operations Monitor - Central Server
 *
 * Receives status updates from distributed dev team machines
 * Serves LCARS-themed monitoring dashboard
 * Tracks session uptime and machine status
 *
 * Built by: Commander Jett Reno, Starfleet Academy Engineering
 *
 * Route modules:
 *   routes/fleet.js         - heartbeat, fleet status, machines, health, teams, backup
 *   routes/credentials.js   - credential CRUD (delegates to credential_cli.py)
 *   routes/dashboards.js    - dashboard CRUD, divisions, machine list
 *   routes/kanban.js        - kanban push/pull, knowledge push/stats, epics, team-config
 *
 * Shared state and helpers:
 *   lib/store.js            - in-memory Maps, persistence, board access helpers
 *   lib/history.js          - machine state history file I/O
 */

'use strict';

const express = require('express');
const cors    = require('cors');
const path    = require('path');

const store   = require('./lib/store');
const history = require('./lib/history');
const fleet   = require('./routes/fleet');

// ============================================================================
// CONFIGURATION
// ============================================================================

const PORT             = process.env.PORT || 3000;
const SAVE_INTERVAL_MS = 30 * 1000; // Save every 30 seconds

// ============================================================================
// DATA BOOTSTRAP
// ============================================================================

store.loadMachineData();
store.loadRegisteredTeams();
store.loadPushedBoards();
store.loadPushedKnowledge();

history.ensureHistoryDir();
history.purgeOldHistory();
setInterval(history.purgeOldHistory, history.HISTORY_PURGE_INTERVAL_MS);

fleet.cleanupLegacyMachines();

// ============================================================================
// EXPRESS APP
// ============================================================================

const app = express();

app.use(cors());
app.use(express.json({ limit: '10mb' }));
// Disable directory redirect to allow explicit route handlers for /lcars
app.use(express.static(path.join(__dirname, 'public'), { redirect: false }));

// Request logging
app.use((req, res, next) => {
    console.log(`[${new Date().toISOString()}] ${req.method} ${req.path} - ${req.ip}`);
    next();
});

// ============================================================================
// ROUTE MODULES
// ============================================================================

// All API routes are prefixed with /api in each router except dashboards
// (which registers full /api/* paths because it needs /api/dashboards/reorder
// before /api/dashboards/:id — Express router preserves definition order).
app.use('/api', fleet.router);
app.use('/api/credentials', require('./routes/credentials'));
app.use('/api', require('./routes/dashboards'));
app.use('/api', require('./routes/kanban'));

// ============================================================================
// PAGE ROUTES
// ============================================================================

app.get('/', (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

app.get('/all', (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'all.html'));
});

app.get('/mainevent', (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'mainevent.html'));
});

app.get('/doublenode', (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'doublenode.html'));
});

// ============================================================================
// LCARS DASHBOARD ROUTES
// ============================================================================

app.get('/lcars', (req, res, next) => {
    if (req.originalUrl === '/lcars') {
        return res.redirect(302, '/lcars/lcars-dashboard.html?dashboard=academy');
    }
    next();
});

app.get('/lcars/', (req, res) => {
    res.redirect(302, '/lcars/lcars-dashboard.html?dashboard=academy');
});

app.get('/lcars/mainevent', (req, res) => {
    res.redirect(302, '/lcars/lcars-dashboard.html?dashboard=mainevent');
});

app.get('/lcars/doublenode', (req, res) => {
    res.redirect(302, '/lcars/lcars-dashboard.html?dashboard=doublenode');
});

app.get('/lcars/all', (req, res) => {
    res.redirect(302, '/lcars/lcars-dashboard.html?dashboard=all');
});

// Serve LCARS static assets (CSS, JS, images)
// Must come AFTER explicit routes to prevent directory redirect on /lcars
app.use('/lcars', express.static(path.join(__dirname, 'public/lcars')));

// ============================================================================
// BACKGROUND TASKS
// ============================================================================

setInterval(() => { fleet.updateMachineStatuses(); }, 30 * 1000);
setInterval(() => { store.saveMachineData();     }, SAVE_INTERVAL_MS);
setInterval(() => { store.savePushedBoards();    }, SAVE_INTERVAL_MS);
setInterval(() => { store.savePushedKnowledge(); }, SAVE_INTERVAL_MS);

// ============================================================================
// START SERVER
// ============================================================================

app.listen(PORT, () => {
    console.log('');
    console.log('\u256C\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550');
    console.log('\u2551     STARFLEET OPERATIONS MONITOR - ONLINE                \u2551');
    console.log('\u255A\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550');
    console.log('');
    console.log(`  Server running on port ${PORT}`);
    console.log(`  API endpoint: http://localhost:${PORT}/api/status`);
    console.log('');
    console.log('  Classic Dashboards:');
    console.log(`    Academy (default): http://localhost:${PORT}/`);
    console.log(`    Main Event: http://localhost:${PORT}/mainevent`);
    console.log(`    DoubleNode: http://localhost:${PORT}/doublenode`);
    console.log(`    All Teams: http://localhost:${PORT}/all`);
    console.log('');
    console.log('  LCARS Unified Dashboard:');
    console.log(`    Academy: http://localhost:${PORT}/lcars/lcars-dashboard.html?dashboard=academy`);
    console.log(`    Main Event: http://localhost:${PORT}/lcars/lcars-dashboard.html?dashboard=mainevent`);
    console.log(`    DoubleNode: http://localhost:${PORT}/lcars/lcars-dashboard.html?dashboard=doublenode`);
    console.log(`    All Fleet: http://localhost:${PORT}/lcars/lcars-dashboard.html?dashboard=all`);
    console.log('');
    console.log('  LCARS Shortcuts (redirect to unified):');
    console.log(`    /lcars -> Academy  |  /lcars/mainevent  |  /lcars/doublenode  |  /lcars/all`);
    console.log('');
    console.log('  Configuration:');
    console.log(`    - Offline threshold: 180s`);
    console.log(`    - Warning threshold: 120s`);
    console.log('');
    console.log('  Ready to receive fleet status reports.');
    console.log('');
});

// Graceful shutdown - save data before exiting
process.on('SIGTERM', () => {
    console.log('Received SIGTERM, shutting down gracefully...');
    store.saveMachineData();
    store.savePushedKnowledge();
    process.exit(0);
});

process.on('SIGINT', () => {
    console.log('Received SIGINT, shutting down gracefully...');
    store.saveMachineData();
    store.savePushedKnowledge();
    process.exit(0);
});
