//
//  helpers.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * Unit tests for pure helper functions in app-factory.js
 * These functions mirror server.js logic — no HTTP, no Express, no state.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { helpers } = require('./helpers/app-factory.js');

const { formatDuration, formatUptime, generateUUID, generateDashboardId, calcBoardStats } = helpers;

// ============================================================================
// formatDuration
// ============================================================================

test('formatDuration: less than 1 second returns "just now"', () => {
    assert.equal(formatDuration(0), 'just now');
    assert.equal(formatDuration(999), 'just now');
});

test('formatDuration: seconds range', () => {
    assert.equal(formatDuration(1000), '1s');
    assert.equal(formatDuration(59000), '59s');
});

test('formatDuration: minutes range', () => {
    assert.equal(formatDuration(60 * 1000), '1m');
    assert.equal(formatDuration(90 * 1000), '1m');
    assert.equal(formatDuration(59 * 60 * 1000), '59m');
});

test('formatDuration: hours range', () => {
    assert.equal(formatDuration(60 * 60 * 1000), '1h 0m');
    assert.equal(formatDuration(90 * 60 * 1000), '1h 30m');
    assert.equal(formatDuration(23 * 60 * 60 * 1000), '23h 0m');
});

test('formatDuration: days range', () => {
    assert.equal(formatDuration(24 * 60 * 60 * 1000), '1d 0h');
    assert.equal(formatDuration(2 * 24 * 60 * 60 * 1000), '2d 0h');
});

// ============================================================================
// formatUptime
// ============================================================================

test('formatUptime: minutes only', () => {
    assert.equal(formatUptime(0), '0m');
    assert.equal(formatUptime(59), '0m');
    assert.equal(formatUptime(60), '1m');
    assert.equal(formatUptime(3599), '59m');
});

test('formatUptime: hours and minutes', () => {
    assert.equal(formatUptime(3600), '1h 0m');
    assert.equal(formatUptime(3661), '1h 1m');
    assert.equal(formatUptime(86399), '23h 59m');
});

test('formatUptime: days hours and minutes', () => {
    assert.equal(formatUptime(86400), '1d 0h 0m');
    assert.equal(formatUptime(90061), '1d 1h 1m');
});

// ============================================================================
// generateUUID
// ============================================================================

test('generateUUID: returns UUID format string', () => {
    const uuid = generateUUID();
    assert.match(uuid, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
});

test('generateUUID: returns unique values', () => {
    const ids = new Set();
    for (let i = 0; i < 100; i++) ids.add(generateUUID());
    assert.equal(ids.size, 100);
});

test('generateUUID: UUID has version 4 in position', () => {
    const uuid = generateUUID();
    assert.equal(uuid[14], '4');
});

// ============================================================================
// generateDashboardId
// ============================================================================

test('generateDashboardId: lowercases and hyphenates', () => {
    assert.equal(generateDashboardId('My Dashboard'), 'my-dashboard');
});

test('generateDashboardId: removes leading/trailing hyphens', () => {
    const id = generateDashboardId('  Main Event  ');
    assert.ok(!id.startsWith('-'));
    assert.ok(!id.endsWith('-'));
});

test('generateDashboardId: replaces special chars with hyphens', () => {
    assert.equal(generateDashboardId('Alpha & Beta! Test'), 'alpha-beta-test');
});

test('generateDashboardId: truncates to 30 chars', () => {
    const longName = 'A Very Long Dashboard Name That Exceeds Thirty Characters';
    const id = generateDashboardId(longName);
    assert.ok(id.length <= 30, `Expected <= 30 chars, got ${id.length}`);
});

test('generateDashboardId: handles numbers', () => {
    assert.equal(generateDashboardId('Team 2024'), 'team-2024');
});

// ============================================================================
// calcBoardStats
// ============================================================================

test('calcBoardStats: empty board returns zeroed stats', () => {
    const stats = calcBoardStats('test', { backlog: [], epics: [] });
    assert.equal(stats.totalItems, 0);
    assert.equal(stats.completionRate, 0);
    assert.deepEqual(stats.statusCounts, {});
    assert.equal(stats.subitemStats.total, 0);
});

test('calcBoardStats: counts items by status correctly', () => {
    const board = {
        backlog: [
            { id: '1', status: 'completed' },
            { id: '2', status: 'completed' },
            { id: '3', status: 'in_progress' },
            { id: '4', status: 'todo' }
        ],
        epics: []
    };
    const stats = calcBoardStats('test', board);
    assert.equal(stats.totalItems, 4);
    assert.equal(stats.statusCounts['completed'], 2);
    assert.equal(stats.statusCounts['in_progress'], 1);
    assert.equal(stats.statusCounts['todo'], 1);
    assert.equal(stats.completionRate, 50.0);
});

test('calcBoardStats: completion rate is percentage with 1 decimal', () => {
    const board = {
        backlog: [
            { id: '1', status: 'completed' },
            { id: '2', status: 'todo' },
            { id: '3', status: 'todo' }
        ],
        epics: []
    };
    const stats = calcBoardStats('test', board);
    // 1/3 = 33.3...
    assert.ok(stats.completionRate >= 33.3 && stats.completionRate <= 33.4);
});

test('calcBoardStats: counts subitems correctly', () => {
    const board = {
        backlog: [
            {
                id: '1', status: 'in_progress',
                subitems: [
                    { id: 's1', status: 'completed' },
                    { id: 's2', status: 'in_progress' },
                    { id: 's3', status: 'todo' }
                ]
            }
        ],
        epics: []
    };
    const stats = calcBoardStats('test', board);
    assert.equal(stats.subitemStats.total, 3);
    assert.equal(stats.subitemStats.completed, 1);
    assert.equal(stats.subitemStats.pending, 2);
});

test('calcBoardStats: epic progress calculated from item ids', () => {
    const board = {
        backlog: [
            { id: 'ITEM-1', status: 'completed' },
            { id: 'ITEM-2', status: 'todo' }
        ],
        epics: [
            { id: 'E-001', title: 'Test Epic', status: 'active', itemIds: ['ITEM-1', 'ITEM-2'] }
        ]
    };
    const stats = calcBoardStats('test', board);
    assert.equal(stats.epics.length, 1);
    assert.equal(stats.epics[0].totalItems, 2);
    assert.equal(stats.epics[0].completedItems, 1);
    assert.equal(stats.epics[0].progress, 50.0);
});

test('calcBoardStats: uses teamId as displayName when no teamName on board', () => {
    const stats = calcBoardStats('academy', { backlog: [], epics: [] });
    assert.equal(stats.displayName, 'Academy');
});

test('calcBoardStats: uses board.teamName when present', () => {
    const stats = calcBoardStats('test', { teamName: 'Custom Name', backlog: [], epics: [] });
    assert.equal(stats.displayName, 'Custom Name');
});

test('calcBoardStats: items without status counted as undefined', () => {
    const board = { backlog: [{ id: '1' }], epics: [] };
    const stats = calcBoardStats('test', board);
    assert.equal(stats.statusCounts['undefined'], 1);
});
