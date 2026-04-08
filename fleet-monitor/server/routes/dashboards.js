/**
 * Dashboard configuration routes
 *
 * GET    /api/dashboards                - list all dashboards
 * PUT    /api/dashboards/reorder        - reorder dashboards (must precede /:id)
 * GET    /api/dashboards/:id            - get single dashboard
 * POST   /api/dashboards               - create dashboard
 * PUT    /api/dashboards/:id            - update dashboard
 * DELETE /api/dashboards/:id            - delete dashboard
 * GET    /api/divisions                 - static division list from config
 * GET    /api/active-divisions          - divisions active in live fleet data
 * GET    /api/machines/list             - machine list for dashboard filtering
 */

'use strict';

const express = require('express');
const path    = require('path');
const fs      = require('fs');
const router  = express.Router();

const store   = require('../lib/store');

// parseFleetData is needed for /api/active-divisions and /api/machines/list.
// Required lazily (inside the route handlers) to avoid any load-time circular-require issues.
function getParseFleetData() {
    return require('./fleet').parseFleetData;
}

// ============================================================================
// DASHBOARD FILE HELPERS
// ============================================================================

const DASHBOARDS_FILE = path.join(__dirname, '..', 'data', 'dashboards.json');

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

function saveDashboardConfig(config) {
    try {
        const dataDir = path.dirname(DASHBOARDS_FILE);
        if (!fs.existsSync(dataDir)) fs.mkdirSync(dataDir, { recursive: true });
        config.meta.last_modified = new Date().toISOString();
        fs.writeFileSync(DASHBOARDS_FILE, JSON.stringify(config, null, 2));
        return true;
    } catch (error) {
        console.error('Error saving dashboard config:', error.message);
        return false;
    }
}

function generateDashboardId(name) {
    return name.toLowerCase()
        .replace(/[^a-z0-9]+/g, '-')
        .replace(/^-|-$/g, '')
        .substring(0, 30);
}

// ============================================================================
// ROUTES
// ============================================================================

/**
 * GET /api/dashboards
 */
router.get('/dashboards', (req, res) => {
    try {
        const config     = loadDashboardConfig();
        const dashboards = config.dashboards.sort((a, b) => (a.sort_order || 999) - (b.sort_order || 999));
        res.json({ dashboards, total: dashboards.length });
    } catch (error) {
        console.error('Error listing dashboards:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * PUT /api/dashboards/reorder
 * NOTE: must be defined before /api/dashboards/:id to avoid matching "reorder" as an ID.
 */
router.put('/dashboards/reorder', (req, res) => {
    try {
        const { order } = req.body;

        if (!order || !Array.isArray(order)) {
            return res.status(400).json({ error: 'Order must be an array of dashboard IDs' });
        }

        const config      = loadDashboardConfig();
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
            console.log(`\u2713 Dashboard order updated: ${order.join(', ')}`);
            res.json({ success: true, order: config.dashboards.map(d => d.id) });
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
 */
router.get('/dashboards/:id', (req, res) => {
    try {
        const { id }    = req.params;
        const config    = loadDashboardConfig();
        const dashboard = config.dashboards.find(d => d.id === id);

        if (!dashboard) return res.status(404).json({ error: 'Dashboard not found' });
        res.json(dashboard);
    } catch (error) {
        console.error('Error getting dashboard:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * POST /api/dashboards
 */
router.post('/dashboards', (req, res) => {
    try {
        const { name, title, subtitle, description, divisions, machines, org_color } = req.body;

        if (!name || !name.trim()) {
            return res.status(400).json({ error: 'Dashboard name is required' });
        }

        const config = loadDashboardConfig();
        let id       = generateDashboardId(name);

        if (config.dashboards.some(d => d.id === id)) {
            let suffix = 2;
            while (config.dashboards.some(d => d.id === `${id}-${suffix}`)) suffix++;
            id = `${id}-${suffix}`;
        }

        const maxOrder    = Math.max(0, ...config.dashboards.map(d => d.sort_order || 0));
        const now         = new Date().toISOString();
        const newDashboard = {
            id,
            name:        name.trim(),
            title:       (title || name).toUpperCase().trim(),
            subtitle:    (subtitle || 'OPERATIONS MONITOR').toUpperCase().trim(),
            description: description || '',
            url_path:    `/lcars/${id}`,
            html_file:   `lcars-${id}.html`,
            divisions:   divisions || [],
            machines:    machines  || [],
            org_color:   org_color || 'lavender',
            system:      false,
            sort_order:  maxOrder + 1,
            created_at:  now,
            updated_at:  now
        };

        config.dashboards.push(newDashboard);

        if (saveDashboardConfig(config)) {
            console.log(`\u2713 Created dashboard: ${newDashboard.name} (${id})`);
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
 */
router.put('/dashboards/:id', (req, res) => {
    try {
        const { id }    = req.params;
        const { name, title, subtitle, description, divisions, machines, org_color, sort_order, show_all_fleet_on, visible_dashboards } = req.body;

        const config = loadDashboardConfig();
        const index  = config.dashboards.findIndex(d => d.id === id);

        if (index === -1) return res.status(404).json({ error: 'Dashboard not found' });

        const dashboard = config.dashboards[index];

        if (name && name.trim())           dashboard.name        = name.trim();
        if (title)                         dashboard.title       = title.toUpperCase().trim();
        if (subtitle)                      dashboard.subtitle    = subtitle.toUpperCase().trim();
        if (description !== undefined)     dashboard.description = description;
        if (divisions   !== undefined)     dashboard.divisions   = divisions;
        if (machines    !== undefined)     dashboard.machines    = machines;
        if (org_color)                     dashboard.org_color   = org_color;
        if (sort_order  !== undefined)     dashboard.sort_order  = sort_order;
        if (show_all_fleet_on !== undefined) dashboard.show_all_fleet_on = show_all_fleet_on;
        if (visible_dashboards !== undefined) dashboard.visible_dashboards = visible_dashboards;
        dashboard.updated_at = new Date().toISOString();

        if (saveDashboardConfig(config)) {
            console.log(`\u2713 Updated dashboard: ${dashboard.name} (${id})`);
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
 * System dashboards cannot be deleted.
 */
router.delete('/dashboards/:id', (req, res) => {
    try {
        const { id }  = req.params;
        const config  = loadDashboardConfig();
        const index   = config.dashboards.findIndex(d => d.id === id);

        if (index === -1) return res.status(404).json({ error: 'Dashboard not found' });

        const dashboard = config.dashboards[index];
        if (dashboard.system) {
            return res.status(403).json({
                error:   'Cannot delete system dashboard',
                message: `The "${dashboard.name}" dashboard is a system dashboard and cannot be deleted.`
            });
        }

        config.dashboards.splice(index, 1);

        if (saveDashboardConfig(config)) {
            console.log(`\u2713 Deleted dashboard: ${dashboard.name} (${id})`);
            res.json({ success: true, message: `Dashboard "${dashboard.name}" deleted`, deleted_id: id });
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
 * List all available divisions for dashboard configuration (static from config).
 */
router.get('/divisions', (req, res) => {
    try {
        const config = loadDashboardConfig();
        res.json({ divisions: config.divisions || [], total: (config.divisions || []).length });
    } catch (error) {
        console.error('Error listing divisions:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * GET /api/active-divisions
 * List divisions currently active in fleet data (dynamic from live sessions).
 */
router.get('/active-divisions', (req, res) => {
    try {
        const parseFleetData   = getParseFleetData();
        const fleetData        = parseFleetData();
        const activeDivisions  = Object.keys(fleetData.fleet.divisions).map(divKey => {
            const divData = fleetData.fleet.divisions[divKey];
            return { id: divKey, name: divData.name, total_sessions: divData.total_sessions };
        }).sort((a, b) => a.name.localeCompare(b.name));

        res.json({ divisions: activeDivisions, total: activeDivisions.length, source: 'live_fleet_data' });
    } catch (error) {
        console.error('Error listing active divisions:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * GET /api/machines/list
 * List all machines for dashboard filtering.
 */
router.get('/machines/list', (req, res) => {
    try {
        const parseFleetData = getParseFleetData();
        const fleetData      = parseFleetData();
        const machineList    = fleetData.fleet.machines.map(m => ({
            machine_id:   m.machine_id,
            hostname:     m.hostname,
            nickname:     m.nickname,
            display_name: m.nickname || m.hostname,
            status:       m.status,
            session_count: m.session_count
        })).sort((a, b) => {
            if (a.status !== b.status) return a.status === 'online' ? -1 : 1;
            return a.display_name.localeCompare(b.display_name);
        });

        res.json({
            machines: machineList,
            total:    machineList.length,
            online:   machineList.filter(m => m.status === 'online').length,
            offline:  machineList.filter(m => m.status === 'offline').length
        });
    } catch (error) {
        console.error('Error listing machines:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

module.exports = router;
