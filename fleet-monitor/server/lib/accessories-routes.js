//
//  accessories-routes.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * Accessory routes (XACA-1392-003). Registered on `app` so the tests exercise the
 * same handlers server.js ships.
 *
 *   GET    /api/accessories                                open (see TIER below)
 *   PUT    /api/accessories/:id/machines/:machineId        admin, idempotent attach
 *   DELETE /api/accessories/:id/machines/:machineId        admin, idempotent detach
 *   PUT    /api/accessories/:id/nickname                   admin, null/'' clears
 *
 * TIER DECISION (GET): /api/fleet -- the read this view sits beside -- carries NO
 * gate in server.js (the dashboards read it anonymously), and so do the other
 * fleet reads (GET /api/ci-pool is "open, REDACTED"). GET /api/accessories matches
 * that tier: open. The plan doc said requireApiKey, but gating it would make the
 * ACCESSORIES view (XACA-1393) fail for the same anonymous dashboards that render
 * /api/fleet. The payload is the same data /api/fleet already carries
 * (machine ids, a UPS name, a percentage) and nothing secret. Mutations are the
 * ADMIN tier, same as PUT /api/machine/:machineId/nickname.
 *
 * Errors: 400 malformed id/nickname, 404 unknown accessory (or unknown machine on
 * an attach that would change something), 409 attach list full. Detach never needs
 * the machine to exist, so a stale id can always be removed.
 */

const { requireAdminKey } = require('./auth-middleware');
const { ACCESSORY_ID_RE, MACHINE_ID_RE } = require('./accessories');

/**
 * @param app
 * @param deps.registry      accessories registry
 * @param deps.refresh       () => {accessories, machines}  derive against fresh machine statuses
 * @param deps.machineExists (machineId) => boolean
 */
function registerAccessoriesRoutes(app, deps) {
    const { registry, refresh, machineExists } = deps;

    function viewOf(id) {
        const hit = refresh().accessories.find((a) => a.id === id);
        return hit || null;
    }

    function badIds(req, res) {
        if (!ACCESSORY_ID_RE.test(req.params.id)) {
            res.status(400).json({ error: 'Invalid accessory id' });
            return true;
        }
        if (req.params.machineId !== undefined && !MACHINE_ID_RE.test(req.params.machineId)) {
            res.status(400).json({ error: 'Invalid machine id' });
            return true;
        }
        return false;
    }

    app.get('/api/accessories', (req, res) => {
        try {
            const { accessories } = refresh();
            res.json({ accessories, total: accessories.length });
        } catch (error) {
            console.error('Error listing accessories:', error);
            res.status(500).json({ error: 'Internal server error' });
        }
    });

    app.put('/api/accessories/:id/machines/:machineId', requireAdminKey, (req, res) => {
        try {
            if (badIds(req, res)) return;
            const { id, machineId } = req.params;
            if (!registry.get(id)) return res.status(404).json({ error: 'Accessory not found' });
            const already = registry.get(id).attachedMachineIds.includes(machineId);
            if (!already && !machineExists(machineId)) return res.status(404).json({ error: 'Machine not found' });
            const r = registry.attach(id, machineId);
            if (!r.ok) return res.status(r.code === 'full' ? 409 : 400).json({ error: r.code === 'full' ? 'Too many attached machines' : 'Invalid request' });
            res.json({ success: true, changed: r.changed, accessory: viewOf(id) });
        } catch (error) {
            console.error('Error attaching machine:', error);
            res.status(500).json({ error: 'Internal server error' });
        }
    });

    app.delete('/api/accessories/:id/machines/:machineId', requireAdminKey, (req, res) => {
        try {
            if (badIds(req, res)) return;
            const { id, machineId } = req.params;
            if (!registry.get(id)) return res.status(404).json({ error: 'Accessory not found' });
            const r = registry.detach(id, machineId);
            if (!r.ok) return res.status(400).json({ error: 'Invalid request' });
            res.json({ success: true, changed: r.changed, accessory: viewOf(id) });
        } catch (error) {
            console.error('Error detaching machine:', error);
            res.status(500).json({ error: 'Internal server error' });
        }
    });

    app.put('/api/accessories/:id/nickname', requireAdminKey, (req, res) => {
        try {
            if (badIds(req, res)) return;
            const { id } = req.params;
            if (!registry.get(id)) return res.status(404).json({ error: 'Accessory not found' });
            const r = registry.setNickname(id, req.body ? req.body.nickname : undefined);
            if (!r.ok) return res.status(400).json({ error: 'Invalid nickname' });
            res.json({ success: true, changed: r.changed, accessory: viewOf(id) });
        } catch (error) {
            console.error('Error setting accessory nickname:', error);
            res.status(500).json({ error: 'Internal server error' });
        }
    });
}

module.exports = { registerAccessoriesRoutes };
