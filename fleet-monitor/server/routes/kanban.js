/**
 * Kanban routes
 *
 * POST /api/kanban-push             - receive full board from client
 * POST /api/knowledge-push          - receive knowledge stats from client
 * GET  /api/knowledge-stats         - aggregated knowledge stats for all teams
 * GET  /api/working-items           - current working items from all boards
 * GET  /api/kanban-stats            - kanban statistics (all or single team)
 * GET  /api/epics                   - all epics from all team boards
 * GET  /api/epics/:team             - epics for a specific team
 * POST /api/epics/:team             - create epic for a team
 * PUT  /api/epics/:team/:epicId     - update epic
 * DELETE /api/epics/:team/:epicId   - delete epic
 * GET  /api/team-config             - all registered teams with metadata
 * GET  /api/team-config/:team/terminals - terminal-to-persona mapping
 */

'use strict';

const express = require('express');
const fs      = require('fs');
const router  = express.Router();

const store   = require('../lib/store');

// ============================================================================
// KANBAN PUSH
// ============================================================================

/**
 * POST /api/kanban-push
 * Receive full kanban board data from a client team.
 * Body: { team, ...boardData }
 */
router.post('/kanban-push', (req, res) => {
    try {
        const body = req.body;

        if (!body || !body.team) {
            return res.status(400).json({ error: 'Missing required field: team', required: ['team'] });
        }

        const teamId = body.team;
        const now    = new Date().toISOString();

        store.pushedBoards.set(teamId, { board: body, pushedAt: now, teamId });
        console.log(`[KANBAN-PUSH] Board data received from team '${teamId}'`);

        res.status(200).json({ success: true, team: teamId, pushedAt: now });
    } catch (error) {
        console.error('Error processing kanban push:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

// ============================================================================
// KNOWLEDGE PUSH / STATS
// ============================================================================

/**
 * POST /api/knowledge-push
 * Receive knowledge base stats from a client team.
 * Body: { team: "academy", knowledge: { totalEntries, agents, categories, tags, ... } }
 */
router.post('/knowledge-push', (req, res) => {
    try {
        const body = req.body;

        if (!body || !body.team) {
            return res.status(400).json({ error: 'Missing required field: team', required: ['team'] });
        }

        const teamId = body.team;
        const now    = new Date().toISOString();

        store.pushedKnowledge.set(teamId, { knowledge: body.knowledge || {}, pushedAt: now, teamId });
        console.log(`[KNOWLEDGE-PUSH] Knowledge stats received from team '${teamId}'`);

        res.status(200).json({ success: true, team: teamId, pushedAt: now });
    } catch (error) {
        console.error('Error processing knowledge push:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * GET /api/knowledge-stats
 * Returns aggregated knowledge base statistics for all teams.
 */
router.get('/knowledge-stats', (req, res) => {
    try {
        const teams                = {};
        let totalEntries           = 0;
        let totalContributingAgents = 0;
        let teamsWithEntries       = 0;
        const allCategories        = {};
        const allTags              = {};
        const allRecentEntries     = [];

        for (const [teamId, data] of store.pushedKnowledge) {
            const k        = data.knowledge || {};
            teams[teamId]  = { teamId, ...k, pushedAt: data.pushedAt };

            totalEntries           += k.totalEntries || 0;
            totalContributingAgents += k.contributingAgents || 0;
            if ((k.totalEntries || 0) > 0) teamsWithEntries++;

            if (k.categories) {
                for (const [cat, count] of Object.entries(k.categories)) {
                    allCategories[cat] = (allCategories[cat] || 0) + count;
                }
            }
            if (k.tags) {
                for (const [tag, count] of Object.entries(k.tags)) {
                    allTags[tag] = (allTags[tag] || 0) + count;
                }
            }
            if (k.recentEntries && Array.isArray(k.recentEntries)) {
                k.recentEntries.forEach(entry => allRecentEntries.push({ ...entry, teamId }));
            }
        }

        allRecentEntries.sort((a, b) => (b.date || '').localeCompare(a.date || ''));
        const topRecentEntries = allRecentEntries.slice(0, 10);

        const topTags = Object.entries(allTags)
            .sort((a, b) => b[1] - a[1])
            .slice(0, 20)
            .map(([tag, count]) => ({ tag, count }));

        res.json({
            teams,
            overall: {
                totalEntries,
                teamsWithEntries,
                totalContributingAgents,
                categories:       allCategories,
                uniqueCategories: Object.keys(allCategories).length,
                topTags,
                uniqueTags:       Object.keys(allTags).length,
                recentEntries:    topRecentEntries
            },
            timestamp: new Date().toISOString()
        });
    } catch (error) {
        console.error('Error calculating knowledge stats:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

// ============================================================================
// WORKING ITEMS
// ============================================================================

/**
 * GET /api/working-items
 * Current working items from kanban boards.
 */
router.get('/working-items', (req, res) => {
    const workingItems = {};

    try {
        for (const team of store.getAllTeamIds()) {
            try {
                const board = store.getBoardData(team);
                if (!board) continue;

                const backlog    = board.backlog || [];
                const activeItem = backlog.find(item => item.status === 'actively-working');

                if (activeItem) {
                    let activeSubitem = null;
                    if (activeItem.subitems && activeItem.subitems.length > 0) {
                        activeSubitem = activeItem.subitems.find(sub => sub.status === 'in_progress');
                    }

                    workingItems[team] = {
                        id:      activeItem.id,
                        title:   activeItem.title,
                        status:  activeItem.status,
                        subitem: activeSubitem ? {
                            id:     activeSubitem.id,
                            title:  activeSubitem.title,
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
// KANBAN STATS
// ============================================================================

/**
 * Calculate kanban statistics for a single board.
 */
function calcBoardStats(teamId, board) {
    const backlog      = board.backlog || [];
    const epics        = board.epics   || [];
    const sevenDaysAgo = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000);

    const statusCounts = {};
    let totalCompleted = 0;
    for (const item of backlog) {
        const status = item.status || 'undefined';
        statusCounts[status] = (statusCounts[status] || 0) + 1;
        if (status === 'completed') totalCompleted++;
    }

    const totalItems      = backlog.length;
    const completionRate  = totalItems > 0 ? Math.round((totalCompleted / totalItems) * 1000) / 10 : 0;

    const epicStats = epics.map(epic => {
        const itemIds       = new Set(epic.itemIds || []);
        const epicItems     = backlog.filter(item => itemIds.has(item.id));
        const epicTotal     = epicItems.length;
        const epicCompleted = epicItems.filter(i => i.status === 'completed').length;
        const epicProgress  = epicTotal > 0 ? Math.round((epicCompleted / epicTotal) * 1000) / 10 : 0;
        return {
            id:             epic.id,
            name:           epic.shortTitle || epic.title || epic.id,
            status:         epic.status || 'active',
            totalItems:     epicTotal,
            completedItems: epicCompleted,
            progress:       epicProgress
        };
    });

    let subTotal     = 0;
    let subCompleted = 0;
    for (const item of backlog) {
        const subs    = item.subitems || [];
        subTotal     += subs.length;
        subCompleted += subs.filter(s => s.status === 'completed').length;
    }

    let completedLast7Days = 0;
    let createdLast7Days   = 0;
    for (const item of backlog) {
        if (item.completedAt && new Date(item.completedAt) > sevenDaysAgo) completedLast7Days++;
        if (item.addedAt     && new Date(item.addedAt)     > sevenDaysAgo) createdLast7Days++;
    }

    return {
        teamId,
        displayName:   board.teamName || teamId.charAt(0).toUpperCase() + teamId.slice(1),
        statusCounts,
        totalItems,
        completionRate,
        epics: epicStats,
        subitemStats:   { total: subTotal, completed: subCompleted, pending: subTotal - subCompleted },
        recentActivity: { completedLast7Days, createdLast7Days }
    };
}

/**
 * GET /api/kanban-stats
 * Returns kanban statistics for all teams or a specific team.
 * Query params: team=<teamId>
 */
router.get('/kanban-stats', (req, res) => {
    const { team } = req.query;

    try {
        const teamStats        = {};
        let teamsToProcess     = [];

        if (team) {
            const board = store.getBoardData(team);
            if (!board) return res.status(404).json({ error: `Team '${team}' not found` });
            teamsToProcess = [team];
        } else {
            teamsToProcess = store.getAllTeamIds();
        }

        for (const teamId of teamsToProcess) {
            try {
                const board = store.getBoardData(teamId);
                if (!board) {
                    teamStats[teamId] = { teamId, error: 'Board data not available' };
                    continue;
                }
                teamStats[teamId] = calcBoardStats(teamId, board);
            } catch (e) {
                console.error(`[kanban-stats] Could not process board for ${teamId}:`, e.message);
                teamStats[teamId] = { teamId, error: `Could not read board: ${e.message}` };
            }
        }

        const validTeams           = Object.values(teamStats).filter(s => !s.error);
        const overallStatusCounts  = {};
        let overallTotal           = 0;
        let overallCompleted       = 0;

        for (const stats of validTeams) {
            overallTotal     += stats.totalItems;
            overallCompleted += stats.statusCounts['completed'] || 0;
            for (const [status, count] of Object.entries(stats.statusCounts)) {
                overallStatusCounts[status] = (overallStatusCounts[status] || 0) + count;
            }
        }

        const overallCompletionRate = overallTotal > 0
            ? Math.round((overallCompleted / overallTotal) * 1000) / 10
            : 0;

        res.json({
            teams: teamStats,
            overall: {
                totalTeams:            Object.keys(teamStats).length,
                validTeams:            validTeams.length,
                totalItems:            overallTotal,
                totalCompleted:        overallCompleted,
                overallCompletionRate,
                statusCounts:          overallStatusCounts
            },
            timestamp: new Date().toISOString()
        });
    } catch (error) {
        console.error('Error calculating kanban stats:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

// ============================================================================
// EPICS
// ============================================================================

/**
 * Build epic objects with progress stats from a board.
 */
function buildEpicsWithProgress(board, includeSubitems = false) {
    const epics   = board.epics   || [];
    const backlog = board.backlog || [];

    return epics.map(epic => {
        const itemIds         = epic.itemIds || [];
        const items           = backlog.filter(item => itemIds.includes(item.id));
        const totalItems      = items.length;
        const completedItems  = items.filter(i => i.status === 'completed').length;
        const cancelledItems  = items.filter(i => i.status === 'cancelled').length;
        const inProgressItems = items.filter(i => i.status === 'in_progress').length;
        const blockedItems    = items.filter(i => i.status === 'blocked').length;
        const todoItems       = items.filter(i => i.status === 'todo').length;
        const resolvedItems   = completedItems + cancelledItems;
        const percentComplete = totalItems > 0 ? Math.floor((resolvedItems * 100) / totalItems) : 0;

        const mappedItems = items.map(item => {
            const mapped = { id: item.id, title: item.title, status: item.status, priority: item.priority };
            if (includeSubitems) {
                mapped.subitems = (item.subitems || []).map(sub => ({ id: sub.id, title: sub.title, status: sub.status }));
            }
            return mapped;
        });

        return {
            ...epic,
            progress: { totalItems, completedItems, cancelledItems, resolvedItems, inProgressItems, blockedItems, todoItems, percentComplete },
            items: mappedItems
        };
    });
}

/**
 * GET /api/epics
 * Get all Epics from all team boards.
 */
router.get('/epics', (req, res) => {
    const allEpics = {};

    try {
        for (const team of store.getAllTeamIds()) {
            try {
                const board = store.getBoardData(team);
                if (!board || !(board.epics || []).length) continue;
                allEpics[team] = buildEpicsWithProgress(board, false);
            } catch (e) {
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
 * Get Epics for a specific team.
 */
router.get('/epics/:team', (req, res) => {
    const { team } = req.params;

    try {
        const board = store.getBoardData(team);
        if (!board) return res.status(404).json({ error: `Team '${team}' not found` });

        const epicsWithProgress = buildEpicsWithProgress(board, true);
        res.json({ team, epics: epicsWithProgress, total: epicsWithProgress.length });
    } catch (error) {
        console.error(`Error reading epics for team ${team}:`, error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * POST /api/epics/:team
 * Create a new Epic for a team.
 */
router.post('/epics/:team', (req, res) => {
    const { team }    = req.params;
    const { title, description, priority, category, dueDate } = req.body;
    const boardPath   = store.findBoardPath(team);

    if (!title) return res.status(400).json({ error: 'Title is required' });

    try {
        if (!boardPath) return res.status(404).json({ error: `Team '${team}' not found` });

        const board = JSON.parse(fs.readFileSync(boardPath, 'utf8'));
        if (!board.epics)      board.epics      = [];
        if (!board.nextEpicId) board.nextEpicId = 1;

        const teamCodes = {
            'academy': 'ACA', 'ios': 'IOS', 'android': 'AND', 'firebase': 'FIR',
            'freelance': 'FRE', 'dns': 'DNS', 'command': 'CMD', 'mainevent': 'MEV'
        };
        const teamCode = teamCodes[team.toLowerCase()] || team.slice(0, 3).toUpperCase();
        const epicId   = `E${teamCode}-${String(board.nextEpicId).padStart(4, '0')}`;

        const timestamp = new Date().toISOString();
        const newEpic   = {
            id:          epicId,
            title,
            description: description || '',
            status:      'planning',
            priority:    priority || 'medium',
            itemIds:     [],
            addedAt:     timestamp,
            updatedAt:   timestamp,
            tags:        [],
            collapsed:   false
        };
        if (category) newEpic.category = category;
        if (dueDate)  newEpic.dueDate  = dueDate;

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
 * Update an existing Epic.
 */
router.put('/epics/:team/:epicId', (req, res) => {
    const { team, epicId } = req.params;
    const updates          = req.body;
    const boardPath        = store.findBoardPath(team);

    try {
        if (!boardPath) return res.status(404).json({ error: `Team '${team}' not found` });

        const board     = JSON.parse(fs.readFileSync(boardPath, 'utf8'));
        const epicIndex = (board.epics || []).findIndex(e => e.id === epicId);

        if (epicIndex === -1) return res.status(404).json({ error: `Epic '${epicId}' not found` });

        const timestamp     = new Date().toISOString();
        const allowedFields = ['title', 'description', 'status', 'priority', 'category', 'dueDate', 'collapsed'];
        for (const field of allowedFields) {
            if (updates[field] !== undefined) board.epics[epicIndex][field] = updates[field];
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
 * Delete an Epic.
 */
router.delete('/epics/:team/:epicId', (req, res) => {
    const { team, epicId } = req.params;
    const boardPath        = store.findBoardPath(team);

    try {
        if (!boardPath) return res.status(404).json({ error: `Team '${team}' not found` });

        const board     = JSON.parse(fs.readFileSync(boardPath, 'utf8'));
        const epicIndex = (board.epics || []).findIndex(e => e.id === epicId);

        if (epicIndex === -1) return res.status(404).json({ error: `Epic '${epicId}' not found` });

        const itemIds = board.epics[epicIndex].itemIds || [];
        for (const item of board.backlog || []) {
            if (itemIds.includes(item.id)) delete item.epicId;
        }

        board.epics.splice(epicIndex, 1);
        board.lastUpdated = new Date().toISOString();

        fs.writeFileSync(boardPath, JSON.stringify(board, null, 2));
        res.json({ message: 'Epic deleted', deletedId: epicId });
    } catch (error) {
        console.error(`Error deleting epic ${epicId}:`, error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

// ============================================================================
// TEAM CONFIG
// ============================================================================

/**
 * GET /api/team-config
 * Returns comprehensive team configuration including terminal/persona metadata.
 * ?team=<teamId> returns just that team's configuration.
 */
router.get('/team-config', (req, res) => {
    const { team } = req.query;

    try {
        if (team) {
            const teamData = store.registeredTeams.get(team);
            if (!teamData) return res.status(404).json({ error: `Team '${team}' not found` });

            return res.json({
                team:         teamData.team,
                teamName:     teamData.teamName,
                subtitle:     teamData.subtitle,
                ship:         teamData.ship,
                series:       teamData.series,
                organization: teamData.organization,
                orgColor:     teamData.orgColor,
                terminals:    teamData.terminals,
                registeredAt: teamData.registeredAt,
                lastSeen:     teamData.lastSeen
            });
        }

        const teams         = {};
        const organizations = {};

        for (const [teamId, teamData] of store.registeredTeams.entries()) {
            teams[teamId] = {
                team:         teamData.team,
                teamName:     teamData.teamName,
                organization: teamData.organization,
                orgColor:     teamData.orgColor,
                ship:         teamData.ship,
                series:       teamData.series,
                terminals:    teamData.terminals,
                registeredAt: teamData.registeredAt,
                lastSeen:     teamData.lastSeen
            };

            if (!organizations[teamData.organization]) {
                organizations[teamData.organization] = { color: teamData.orgColor, teams: [] };
            }
            organizations[teamData.organization].teams.push(teamId);
        }

        res.json({ teams, organizations, timestamp: new Date().toISOString() });
    } catch (error) {
        console.error('Error reading team config:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * GET /api/team-config/:team/terminals
 * Returns terminal-to-persona mapping for a specific team.
 */
router.get('/team-config/:team/terminals', (req, res) => {
    const { team } = req.params;

    try {
        const teamData = store.registeredTeams.get(team);
        if (!teamData) return res.status(404).json({ error: `Team '${team}' not found` });

        res.json({ team: teamData.team, terminals: teamData.terminals });
    } catch (error) {
        console.error(`Error reading terminals for team ${team}:`, error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

module.exports = router;
