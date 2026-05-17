//
//  team-routes.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * Team Registration and Team Config Route Tests
 * Tests: POST /api/team-register, GET /api/registered-teams,
 *        GET /api/team-config, GET /api/team-config/:team/terminals
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');
const { createApp } = require('./helpers/app-factory.js');

// Minimal valid team registration payload
function validTeamPayload(overrides = {}) {
    return {
        team: 'academy',
        teamName: 'Academy Engineering',
        organization: 'starfleet',
        orgColor: 'operations-gold',
        kanbanDir: '/tmp/kanban',
        terminals: { reno: { persona: 'Jett Reno', role: 'Chief Engineer' } },
        ...overrides
    };
}

// ============================================================================
// POST /api/team-register — success cases
// ============================================================================

test('POST /api/team-register registers a new team with 201', async () => {
    const registeredTeams = new Map();
    const { app } = createApp({ registeredTeams });
    const res = await request(app).post('/api/team-register').send(validTeamPayload());
    assert.equal(res.status, 201);
    assert.equal(res.body.success, true);
    assert.equal(res.body.team, 'academy');
    assert.equal(res.body.organization, 'starfleet');
    assert.equal(res.body.terminal_count, 1);
    assert.equal(registeredTeams.size, 1);
});

test('POST /api/team-register updates existing team with 200', async () => {
    const registeredTeams = new Map();
    const { app } = createApp({ registeredTeams });
    // First registration
    await request(app).post('/api/team-register').send(validTeamPayload());
    // Update
    const res = await request(app).post('/api/team-register').send(validTeamPayload({ teamName: 'Updated Academy' }));
    assert.equal(res.status, 200);
    assert.equal(registeredTeams.size, 1);
    assert.equal(registeredTeams.get('academy').teamName, 'Updated Academy');
});

test('POST /api/team-register preserves registeredAt on updates', async () => {
    const registeredTeams = new Map();
    const { app } = createApp({ registeredTeams });

    await request(app).post('/api/team-register').send(validTeamPayload());
    const firstRegisteredAt = registeredTeams.get('academy').registeredAt;

    // Small delay to ensure timestamps differ
    await new Promise(r => setTimeout(r, 10));
    await request(app).post('/api/team-register').send(validTeamPayload({ teamName: 'Updated' }));

    assert.equal(registeredTeams.get('academy').registeredAt, firstRegisteredAt);
});

test('POST /api/team-register defaults teamName to uppercase team id', async () => {
    const registeredTeams = new Map();
    const { app } = createApp({ registeredTeams });
    await request(app).post('/api/team-register').send(validTeamPayload({ teamName: undefined }));
    assert.equal(registeredTeams.get('academy').teamName, 'ACADEMY');
});

test('POST /api/team-register defaults orgColor to lavender', async () => {
    const registeredTeams = new Map();
    const { app } = createApp({ registeredTeams });
    await request(app).post('/api/team-register').send(validTeamPayload({ orgColor: undefined }));
    assert.equal(registeredTeams.get('academy').orgColor, 'lavender');
});

test('POST /api/team-register counts multiple terminals', async () => {
    const { app } = createApp();
    const payload = validTeamPayload({
        terminals: {
            reno: { persona: 'Jett Reno' },
            nahla: { persona: 'Chancellor Nahla' },
            thok: { persona: 'Lt. Thok' }
        }
    });
    const res = await request(app).post('/api/team-register').send(payload);
    assert.equal(res.body.terminal_count, 3);
});

// ============================================================================
// POST /api/team-register — error cases
// ============================================================================

test('POST /api/team-register returns 400 if team is missing', async () => {
    const { app } = createApp();
    const res = await request(app).post('/api/team-register').send(validTeamPayload({ team: undefined }));
    assert.equal(res.status, 400);
    assert.ok(res.body.error);
    assert.ok(Array.isArray(res.body.required));
});

test('POST /api/team-register returns 400 if organization is missing', async () => {
    const { app } = createApp();
    const res = await request(app).post('/api/team-register').send(validTeamPayload({ organization: undefined }));
    assert.equal(res.status, 400);
    assert.ok(res.body.error);
});

test('POST /api/team-register returns 400 if kanbanDir is missing', async () => {
    const { app } = createApp();
    const res = await request(app).post('/api/team-register').send(validTeamPayload({ kanbanDir: undefined }));
    assert.equal(res.status, 400);
});

test('POST /api/team-register returns 400 if terminals is missing', async () => {
    const { app } = createApp();
    const res = await request(app).post('/api/team-register').send(validTeamPayload({ terminals: undefined }));
    assert.equal(res.status, 400);
});

test('POST /api/team-register returns 400 if terminals is an array', async () => {
    const { app } = createApp();
    const res = await request(app).post('/api/team-register').send(validTeamPayload({ terminals: ['reno', 'nahla'] }));
    assert.equal(res.status, 400);
    assert.match(res.body.error, /Invalid terminals/);
});

test('POST /api/team-register returns 400 if terminals is a string', async () => {
    const { app } = createApp();
    const res = await request(app).post('/api/team-register').send(validTeamPayload({ terminals: 'reno' }));
    assert.equal(res.status, 400);
});

// ============================================================================
// GET /api/registered-teams
// ============================================================================

test('GET /api/registered-teams returns empty list initially', async () => {
    const { app } = createApp();
    const res = await request(app).get('/api/registered-teams');
    assert.equal(res.status, 200);
    assert.deepEqual(res.body.teams, []);
    assert.equal(res.body.total, 0);
});

test('GET /api/registered-teams returns all registered teams', async () => {
    const registeredTeams = new Map();
    const { app } = createApp({ registeredTeams });

    await request(app).post('/api/team-register').send(validTeamPayload({ team: 'academy' }));
    await request(app).post('/api/team-register').send(validTeamPayload({ team: 'ios' }));

    const res = await request(app).get('/api/registered-teams');
    assert.equal(res.status, 200);
    assert.equal(res.body.total, 2);
    assert.equal(res.body.teams.length, 2);
});

test('GET /api/registered-teams sorts teams alphabetically', async () => {
    const { app } = createApp();
    await request(app).post('/api/team-register').send(validTeamPayload({ team: 'ios' }));
    await request(app).post('/api/team-register').send(validTeamPayload({ team: 'academy' }));

    const res = await request(app).get('/api/registered-teams');
    assert.equal(res.body.teams[0].team, 'academy');
    assert.equal(res.body.teams[1].team, 'ios');
});

test('GET /api/registered-teams includes terminalCount', async () => {
    const { app } = createApp();
    await request(app).post('/api/team-register').send(validTeamPayload({
        terminals: { a: {}, b: {}, c: {} }
    }));
    const res = await request(app).get('/api/registered-teams');
    assert.equal(res.body.teams[0].terminalCount, 3);
});

test('GET /api/registered-teams includes timestamp', async () => {
    const { app } = createApp();
    const res = await request(app).get('/api/registered-teams');
    assert.ok(typeof res.body.timestamp === 'string');
});

// ============================================================================
// GET /api/team-config
// ============================================================================

test('GET /api/team-config returns empty when no teams registered', async () => {
    const { app } = createApp();
    const res = await request(app).get('/api/team-config');
    assert.equal(res.status, 200);
    assert.deepEqual(res.body.teams, {});
    assert.deepEqual(res.body.organizations, {});
});

test('GET /api/team-config returns all teams with org grouping', async () => {
    const { app } = createApp();
    await request(app).post('/api/team-register').send(validTeamPayload({ team: 'academy', organization: 'starfleet' }));
    await request(app).post('/api/team-register').send(validTeamPayload({ team: 'ios', organization: 'mainevent' }));

    const res = await request(app).get('/api/team-config');
    assert.equal(res.status, 200);
    assert.ok(res.body.teams['academy']);
    assert.ok(res.body.teams['ios']);
    assert.ok(res.body.organizations['starfleet']);
    assert.ok(res.body.organizations['mainevent']);
    assert.ok(res.body.organizations['starfleet'].teams.includes('academy'));
});

test('GET /api/team-config?team=<id> returns specific team', async () => {
    const { app } = createApp();
    await request(app).post('/api/team-register').send(validTeamPayload({ team: 'academy', ship: 'USS Discovery' }));

    const res = await request(app).get('/api/team-config?team=academy');
    assert.equal(res.status, 200);
    assert.equal(res.body.team, 'academy');
    assert.equal(res.body.ship, 'USS Discovery');
});

test('GET /api/team-config?team=<unknown> returns 404', async () => {
    const { app } = createApp();
    const res = await request(app).get('/api/team-config?team=doesnotexist');
    assert.equal(res.status, 404);
    assert.ok(res.body.error);
});

// ============================================================================
// GET /api/team-config/:team/terminals
// ============================================================================

test('GET /api/team-config/:team/terminals returns terminals for registered team', async () => {
    const { app } = createApp();
    await request(app).post('/api/team-register').send(validTeamPayload({
        team: 'academy',
        terminals: { reno: { persona: 'Jett Reno', role: 'Chief Engineer' } }
    }));

    const res = await request(app).get('/api/team-config/academy/terminals');
    assert.equal(res.status, 200);
    assert.equal(res.body.team, 'academy');
    assert.ok(res.body.terminals.reno);
    assert.equal(res.body.terminals.reno.persona, 'Jett Reno');
});

test('GET /api/team-config/:team/terminals returns 404 for unknown team', async () => {
    const { app } = createApp();
    const res = await request(app).get('/api/team-config/ghost/terminals');
    assert.equal(res.status, 404);
    assert.ok(res.body.error);
});
