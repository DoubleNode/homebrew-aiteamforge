//
//  kanban-routes.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * Kanban Route Tests
 * Tests: POST /api/kanban-push, GET /api/kanban-stats,
 *        GET /api/working-items, GET /api/epics, GET /api/epics/:team,
 *        POST /api/knowledge-push, GET /api/knowledge-stats
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');
const { createApp } = require('./helpers/app-factory.js');

// Board with a mix of items for stats testing
function buildTestBoard(teamId, overrides = {}) {
    return {
        team: teamId,
        teamName: `${teamId} Team`,
        backlog: [
            { id: 'I-001', title: 'Item One', status: 'completed', completedAt: new Date().toISOString(), addedAt: new Date().toISOString() },
            { id: 'I-002', title: 'Item Two', status: 'in_progress', addedAt: new Date().toISOString() },
            { id: 'I-003', title: 'Item Three', status: 'todo', addedAt: new Date().toISOString() },
            {
                id: 'I-004', title: 'Active Item', status: 'actively-working', addedAt: new Date().toISOString(),
                subitems: [
                    { id: 'S-001', title: 'Sub one', status: 'completed' },
                    { id: 'S-002', title: 'Sub two', status: 'in_progress' }
                ]
            }
        ],
        epics: [
            { id: 'EACA-0001', title: 'Test Epic', status: 'active', itemIds: ['I-001', 'I-002'] }
        ],
        ...overrides
    };
}

// ============================================================================
// POST /api/kanban-push
// ============================================================================

test('POST /api/kanban-push stores board data', async () => {
    const pushedBoards = new Map();
    const { app } = createApp({ pushedBoards });
    const board = buildTestBoard('academy');
    const res = await request(app).post('/api/kanban-push').send(board);
    assert.equal(res.status, 200);
    assert.equal(res.body.success, true);
    assert.equal(res.body.team, 'academy');
    assert.ok(typeof res.body.pushedAt === 'string');
    assert.equal(pushedBoards.size, 1);
});

test('POST /api/kanban-push overwrites existing board for same team', async () => {
    const pushedBoards = new Map();
    const { app } = createApp({ pushedBoards });
    await request(app).post('/api/kanban-push').send(buildTestBoard('academy'));
    const updated = buildTestBoard('academy', { teamName: 'Updated Academy' });
    await request(app).post('/api/kanban-push').send(updated);
    assert.equal(pushedBoards.size, 1);
    assert.equal(pushedBoards.get('academy').board.teamName, 'Updated Academy');
});

test('POST /api/kanban-push returns 400 if team field is missing', async () => {
    const { app } = createApp();
    const res = await request(app).post('/api/kanban-push').send({ backlog: [] });
    assert.equal(res.status, 400);
    assert.ok(res.body.error);
    assert.ok(Array.isArray(res.body.required));
});

test('POST /api/kanban-push returns 400 for empty body', async () => {
    const { app } = createApp();
    const res = await request(app).post('/api/kanban-push').send({});
    assert.equal(res.status, 400);
});

test('POST /api/kanban-push stores multiple teams independently', async () => {
    const pushedBoards = new Map();
    const { app } = createApp({ pushedBoards });
    await request(app).post('/api/kanban-push').send(buildTestBoard('academy'));
    await request(app).post('/api/kanban-push').send(buildTestBoard('ios'));
    assert.equal(pushedBoards.size, 2);
});

// ============================================================================
// GET /api/kanban-stats
// ============================================================================

test('GET /api/kanban-stats returns empty overall when no boards', async () => {
    const { app } = createApp();
    const res = await request(app).get('/api/kanban-stats');
    assert.equal(res.status, 200);
    assert.deepEqual(res.body.teams, {});
    assert.equal(res.body.overall.totalTeams, 0);
    assert.equal(res.body.overall.totalItems, 0);
});

test('GET /api/kanban-stats returns stats for pushed board', async () => {
    const pushedBoards = new Map();
    const { app } = createApp({ pushedBoards });
    await request(app).post('/api/kanban-push').send(buildTestBoard('academy'));

    const res = await request(app).get('/api/kanban-stats');
    assert.equal(res.status, 200);
    assert.ok(res.body.teams['academy']);
    const stats = res.body.teams['academy'];
    assert.equal(stats.totalItems, 4);
    assert.ok(stats.statusCounts['completed'] === 1);
    assert.ok(stats.statusCounts['in_progress'] === 1);
    assert.ok(stats.statusCounts['todo'] === 1);
    assert.ok(stats.statusCounts['actively-working'] === 1);
});

test('GET /api/kanban-stats?team=<id> returns single team stats', async () => {
    const pushedBoards = new Map();
    const { app } = createApp({ pushedBoards });
    await request(app).post('/api/kanban-push').send(buildTestBoard('academy'));
    await request(app).post('/api/kanban-push').send(buildTestBoard('ios'));

    const res = await request(app).get('/api/kanban-stats?team=academy');
    assert.equal(res.status, 200);
    assert.ok(res.body.teams['academy']);
    assert.ok(!res.body.teams['ios']);
});

test('GET /api/kanban-stats?team=<unknown> returns 404', async () => {
    const { app } = createApp();
    const res = await request(app).get('/api/kanban-stats?team=ghost');
    assert.equal(res.status, 404);
    assert.ok(res.body.error);
});

test('GET /api/kanban-stats calculates completion rate correctly', async () => {
    const pushedBoards = new Map();
    const { app } = createApp({ pushedBoards });
    // 2 completed out of 4 = 50%
    await request(app).post('/api/kanban-push').send(buildTestBoard('academy'));

    const res = await request(app).get('/api/kanban-stats');
    const stats = res.body.teams['academy'];
    assert.equal(stats.completionRate, 25.0); // only I-001 is completed out of 4
});

test('GET /api/kanban-stats aggregates overall across teams', async () => {
    const pushedBoards = new Map();
    const { app } = createApp({ pushedBoards });
    await request(app).post('/api/kanban-push').send(buildTestBoard('academy'));
    await request(app).post('/api/kanban-push').send(buildTestBoard('ios'));

    const res = await request(app).get('/api/kanban-stats');
    assert.equal(res.body.overall.totalTeams, 2);
    assert.equal(res.body.overall.totalItems, 8); // 4 items x 2 teams
    assert.equal(res.body.overall.totalCompleted, 2); // 1 completed x 2 teams
});

test('GET /api/kanban-stats includes subitem stats', async () => {
    const pushedBoards = new Map();
    const { app } = createApp({ pushedBoards });
    await request(app).post('/api/kanban-push').send(buildTestBoard('academy'));

    const res = await request(app).get('/api/kanban-stats?team=academy');
    const stats = res.body.teams['academy'];
    assert.equal(stats.subitemStats.total, 2);
    assert.equal(stats.subitemStats.completed, 1);
    assert.equal(stats.subitemStats.pending, 1);
});

// ============================================================================
// GET /api/working-items
// ============================================================================

test('GET /api/working-items returns empty when no boards', async () => {
    const { app } = createApp();
    const res = await request(app).get('/api/working-items');
    assert.equal(res.status, 200);
    assert.deepEqual(res.body, {});
});

test('GET /api/working-items returns active item per team', async () => {
    const pushedBoards = new Map();
    const { app } = createApp({ pushedBoards });
    await request(app).post('/api/kanban-push').send(buildTestBoard('academy'));

    const res = await request(app).get('/api/working-items');
    assert.equal(res.status, 200);
    assert.ok(res.body['academy']);
    assert.equal(res.body['academy'].id, 'I-004');
    assert.equal(res.body['academy'].status, 'actively-working');
});

test('GET /api/working-items includes active subitem', async () => {
    const pushedBoards = new Map();
    const { app } = createApp({ pushedBoards });
    await request(app).post('/api/kanban-push').send(buildTestBoard('academy'));

    const res = await request(app).get('/api/working-items');
    assert.ok(res.body['academy'].subitem);
    assert.equal(res.body['academy'].subitem.id, 'S-002');
    assert.equal(res.body['academy'].subitem.status, 'in_progress');
});

test('GET /api/working-items returns null subitem when none active', async () => {
    const pushedBoards = new Map();
    const { app } = createApp({ pushedBoards });
    const boardNoActiveSub = buildTestBoard('ios', {
        backlog: [
            {
                id: 'I-001', title: 'Working', status: 'actively-working',
                subitems: [{ id: 'S-001', title: 'Done sub', status: 'completed' }]
            }
        ]
    });
    await request(app).post('/api/kanban-push').send(boardNoActiveSub);

    const res = await request(app).get('/api/working-items');
    assert.equal(res.body['ios'].subitem, null);
});

test('GET /api/working-items skips teams without actively-working item', async () => {
    const pushedBoards = new Map();
    const { app } = createApp({ pushedBoards });
    const quietBoard = buildTestBoard('ios', {
        backlog: [{ id: 'I-001', title: 'Idle', status: 'todo' }]
    });
    await request(app).post('/api/kanban-push').send(quietBoard);

    const res = await request(app).get('/api/working-items');
    assert.ok(!res.body['ios'], 'ios team should not appear — no active item');
});

// ============================================================================
// GET /api/epics
// ============================================================================

test('GET /api/epics returns empty object when no boards', async () => {
    const { app } = createApp();
    const res = await request(app).get('/api/epics');
    assert.equal(res.status, 200);
    assert.deepEqual(res.body, {});
});

test('GET /api/epics returns epics with progress for pushed board', async () => {
    const pushedBoards = new Map();
    const { app } = createApp({ pushedBoards });
    await request(app).post('/api/kanban-push').send(buildTestBoard('academy'));

    const res = await request(app).get('/api/epics');
    assert.equal(res.status, 200);
    assert.ok(res.body['academy']);
    assert.equal(res.body['academy'].length, 1);
    const epic = res.body['academy'][0];
    assert.equal(epic.id, 'EACA-0001');
    assert.ok(epic.progress);
    assert.equal(epic.progress.totalItems, 2);
    assert.equal(epic.progress.completedItems, 1);
    assert.equal(epic.progress.percentComplete, 50);
});

test('GET /api/epics omits teams with no epics', async () => {
    const pushedBoards = new Map();
    const { app } = createApp({ pushedBoards });
    // Board with no epics
    await request(app).post('/api/kanban-push').send({ team: 'ios', backlog: [], epics: [] });

    const res = await request(app).get('/api/epics');
    assert.ok(!res.body['ios'], 'Team with no epics should not appear in response');
});

// ============================================================================
// GET /api/epics/:team
// ============================================================================

test('GET /api/epics/:team returns epics for specific team', async () => {
    const pushedBoards = new Map();
    const { app } = createApp({ pushedBoards });
    await request(app).post('/api/kanban-push').send(buildTestBoard('academy'));

    const res = await request(app).get('/api/epics/academy');
    assert.equal(res.status, 200);
    assert.equal(res.body.team, 'academy');
    assert.equal(res.body.total, 1);
    assert.ok(Array.isArray(res.body.epics));
});

test('GET /api/epics/:team returns 404 for unknown team', async () => {
    const { app } = createApp();
    const res = await request(app).get('/api/epics/ghost');
    assert.equal(res.status, 404);
    assert.ok(res.body.error);
});

test('GET /api/epics/:team progress includes all status categories', async () => {
    const pushedBoards = new Map();
    const { app } = createApp({ pushedBoards });
    const board = {
        team: 'academy',
        backlog: [
            { id: 'I-001', status: 'completed' },
            { id: 'I-002', status: 'cancelled' },
            { id: 'I-003', status: 'in_progress' },
            { id: 'I-004', status: 'blocked' },
            { id: 'I-005', status: 'todo' }
        ],
        epics: [
            { id: 'EACA-0001', title: 'Full Epic', status: 'active', itemIds: ['I-001', 'I-002', 'I-003', 'I-004', 'I-005'] }
        ]
    };
    await request(app).post('/api/kanban-push').send(board);

    const res = await request(app).get('/api/epics/academy');
    const progress = res.body.epics[0].progress;
    assert.equal(progress.completedItems, 1);
    assert.equal(progress.cancelledItems, 1);
    assert.equal(progress.resolvedItems, 2);
    assert.equal(progress.inProgressItems, 1);
    assert.equal(progress.blockedItems, 1);
    assert.equal(progress.todoItems, 1);
    assert.equal(progress.percentComplete, 40); // 2/5 resolved
});

// ============================================================================
// POST /api/knowledge-push
// ============================================================================

test('POST /api/knowledge-push stores knowledge data', async () => {
    const pushedKnowledge = new Map();
    const { app } = createApp({ pushedKnowledge });
    const res = await request(app).post('/api/knowledge-push').send({
        team: 'academy',
        knowledge: { totalEntries: 25, contributingAgents: 3, categories: { engineering: 10 }, tags: { bash: 5 }, recentEntries: [] }
    });
    assert.equal(res.status, 200);
    assert.equal(res.body.success, true);
    assert.equal(res.body.team, 'academy');
    assert.equal(pushedKnowledge.size, 1);
    assert.equal(pushedKnowledge.get('academy').knowledge.totalEntries, 25);
});

test('POST /api/knowledge-push returns 400 if team missing', async () => {
    const { app } = createApp();
    const res = await request(app).post('/api/knowledge-push').send({ knowledge: {} });
    assert.equal(res.status, 400);
    assert.ok(res.body.error);
});

test('POST /api/knowledge-push handles missing knowledge field gracefully', async () => {
    const pushedKnowledge = new Map();
    const { app } = createApp({ pushedKnowledge });
    const res = await request(app).post('/api/knowledge-push').send({ team: 'ios' });
    assert.equal(res.status, 200);
    assert.deepEqual(pushedKnowledge.get('ios').knowledge, {});
});

// ============================================================================
// GET /api/knowledge-stats
// ============================================================================

test('GET /api/knowledge-stats returns empty overall when no knowledge pushed', async () => {
    const { app } = createApp();
    const res = await request(app).get('/api/knowledge-stats');
    assert.equal(res.status, 200);
    assert.equal(res.body.overall.totalEntries, 0);
    assert.equal(res.body.overall.teamsWithEntries, 0);
    assert.deepEqual(res.body.teams, {});
});

test('GET /api/knowledge-stats aggregates entries across teams', async () => {
    const { app } = createApp();
    await request(app).post('/api/knowledge-push').send({ team: 'academy', knowledge: { totalEntries: 10, contributingAgents: 2 } });
    await request(app).post('/api/knowledge-push').send({ team: 'ios', knowledge: { totalEntries: 5, contributingAgents: 1 } });

    const res = await request(app).get('/api/knowledge-stats');
    assert.equal(res.body.overall.totalEntries, 15);
    assert.equal(res.body.overall.totalContributingAgents, 3);
    assert.equal(res.body.overall.teamsWithEntries, 2);
});

test('GET /api/knowledge-stats merges categories across teams', async () => {
    const { app } = createApp();
    await request(app).post('/api/knowledge-push').send({
        team: 'academy',
        knowledge: { totalEntries: 5, categories: { bash: 3, git: 2 } }
    });
    await request(app).post('/api/knowledge-push').send({
        team: 'ios',
        knowledge: { totalEntries: 4, categories: { bash: 2, swift: 4 } }
    });

    const res = await request(app).get('/api/knowledge-stats');
    assert.equal(res.body.overall.categories['bash'], 5);
    assert.equal(res.body.overall.categories['git'], 2);
    assert.equal(res.body.overall.categories['swift'], 4);
});

test('GET /api/knowledge-stats returns top tags sorted by count', async () => {
    const { app } = createApp();
    await request(app).post('/api/knowledge-push').send({
        team: 'academy',
        knowledge: { totalEntries: 5, tags: { bash: 10, git: 3, docker: 7 } }
    });

    const res = await request(app).get('/api/knowledge-stats');
    const tags = res.body.overall.topTags;
    assert.equal(tags[0].tag, 'bash');
    assert.equal(tags[0].count, 10);
    assert.equal(tags[1].tag, 'docker');
});

test('GET /api/knowledge-stats collects recentEntries with teamId attribution', async () => {
    const { app } = createApp();
    await request(app).post('/api/knowledge-push').send({
        team: 'academy',
        knowledge: {
            totalEntries: 2,
            recentEntries: [{ title: 'Lesson A', date: '2026-03-01' }]
        }
    });

    const res = await request(app).get('/api/knowledge-stats');
    const entries = res.body.overall.recentEntries;
    assert.equal(entries.length, 1);
    assert.equal(entries[0].teamId, 'academy');
    assert.equal(entries[0].title, 'Lesson A');
});

test('GET /api/knowledge-stats limits recentEntries to top 10', async () => {
    const { app } = createApp();
    const manyEntries = Array.from({ length: 15 }, (_, i) => ({
        title: `Entry ${i}`,
        date: `2026-03-${String(i + 1).padStart(2, '0')}`
    }));
    await request(app).post('/api/knowledge-push').send({
        team: 'academy',
        knowledge: { totalEntries: 15, recentEntries: manyEntries }
    });

    const res = await request(app).get('/api/knowledge-stats');
    assert.ok(res.body.overall.recentEntries.length <= 10);
});
