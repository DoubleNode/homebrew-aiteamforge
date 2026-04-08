/**
 * lcars-health-scores.js
 * LCARS Health Score Computation Module
 *
 * Computes 0-100 health scores for teams and divisions based on kanban data.
 * Listens for the 'lcars:kanbanDataReady' event, recomputes all scores,
 * then dispatches 'lcars:healthScoresReady' with the computed data.
 *
 * Score Factors (Team):
 *   - Completion Rate  (35%) — completed / total items
 *   - Activity Recency (25%) — items completed in last 7 days
 *   - Blocked Ratio    (20%) — inverse of blocked / inProgress
 *   - WIP Balance      (20%) — inProgress relative to reasonable WIP limit
 *
 * Grade / Status thresholds:
 *   A: 90-100  B: 80-89  C: 70-79  D: 40-69  F: 0-39
 *   healthy: 70+   warning: 40-69   critical: 0-39
 *
 * Exposes: window.LCARSHealthScores
 */

window.LCARSHealthScores = (function () {
    'use strict';

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /** Reasonable WIP limit per team — teams above this start losing WIP score. */
    const WIP_IDEAL_MAX = 5;

    /** Full score if this many items were completed in the last 7 days. */
    const ACTIVITY_FULL_SCORE_THRESHOLD = 3;

    /** Score thresholds */
    const STATUS_HEALTHY  = 70;
    const STATUS_WARNING  = 40;

    /** LCARS-themed colors for each status */
    const STATUS_COLORS = {
        healthy:  '#27ae60',   // green
        warning:  '#f39c12',   // gold
        critical: '#cc4444',   // red
        unknown:  '#666666'    // neutral gray — matches CSS --kiosk-health-unknown
    };

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    /** Map of teamId -> team health score object */
    let teamScores = {};

    /** Map of divisionId -> division health score object */
    let divisionScores = {};

    /** Fleet-wide rolled-up score */
    let overallScore = null;

    let initialized = false;

    // -------------------------------------------------------------------------
    // Division mapping (mirrors lcars-analytics-kanban.js)
    // -------------------------------------------------------------------------

    const DIVISION_MAP = {
        academy:  'academy',
        command:  'mainevent',
        android:  'mainevent',
        firebase: 'mainevent',
        ios:      'mainevent',
        dns:      'dns'
    };

    function getTeamDivision(teamId) {
        var id = (teamId || '').toLowerCase();
        if (id.indexOf('freelance') === 0) return id;
        if (id.indexOf('legal') === 0)     return 'legal';
        if (id.indexOf('medical') === 0)   return 'medical';
        return DIVISION_MAP[id] || id;
    }

    // -------------------------------------------------------------------------
    // Score helpers
    // -------------------------------------------------------------------------

    /**
     * Clamp a value between min and max.
     */
    function clamp(value, min, max) {
        return Math.min(max, Math.max(min, value));
    }

    /**
     * Determine letter grade from numeric score.
     * A: 90-100, B: 80-89, C: 70-79, D: 40-69, F: 0-39
     */
    function scoreToGrade(score) {
        if (score >= 90) return 'A';
        if (score >= 80) return 'B';
        if (score >= 70) return 'C';
        if (score >= STATUS_WARNING) return 'D';
        return 'F';
    }

    /**
     * Determine status string from numeric score.
     */
    function scoreToStatus(score) {
        if (score >= STATUS_HEALTHY) return 'healthy';
        if (score >= STATUS_WARNING) return 'warning';
        return 'critical';
    }

    /**
     * Return the LCARS color for a given status string.
     */
    function statusToColor(status) {
        return STATUS_COLORS[status] || STATUS_COLORS.unknown;
    }

    // -------------------------------------------------------------------------
    // Factor computations
    // -------------------------------------------------------------------------

    /**
     * Completion Rate Factor (weight 0.35)
     * Score = (completed / total) * 100
     * If no items, score = 50 (neutral — not penalized for empty board).
     */
    function computeCompletionFactor(team) {
        var sc = team.statusCounts || {};
        var total = team.totalItems || 0;
        var completed = sc.completed || 0;

        if (total === 0) {
            return {
                score: 50,
                weight: 0.35,
                detail: 'no items'
            };
        }

        var score = Math.round((completed / total) * 100);
        return {
            score: clamp(score, 0, 100),
            weight: 0.35,
            detail: completed + '/' + total + ' items'
        };
    }

    /**
     * Activity Recency Factor (weight 0.25)
     * Full score if >= ACTIVITY_FULL_SCORE_THRESHOLD items done in last 7 days.
     * Linear degradation to 0 if no activity.
     */
    function computeActivityFactor(team) {
        var recent = team.recentActivity || {};
        var done7d = recent.completedLast7Days || 0;

        // Scale: 0 completions = 0, threshold completions = 100, linear between
        var score = Math.round(clamp(done7d / ACTIVITY_FULL_SCORE_THRESHOLD, 0, 1) * 100);

        return {
            score: score,
            weight: 0.25,
            detail: done7d + ' item' + (done7d !== 1 ? 's' : '') + ' this week'
        };
    }

    /**
     * Blocked Ratio Factor (weight 0.20)
     * Score = (1 - blocked / max(inProgress, 1)) * 100
     * No in-progress items and no blocked = neutral 80 (not penalized for idle).
     * All in-progress blocked = 0.
     */
    function computeBlockedFactor(team) {
        var sc = team.statusCounts || {};
        var blocked = sc.blocked || 0;
        var inProgress = (sc.in_progress || 0) + (sc.coding || 0) +
                         (sc.planning || 0) + (sc.review || 0);

        if (inProgress === 0 && blocked === 0) {
            return {
                score: 80,
                weight: 0.20,
                detail: 'no active work'
            };
        }

        // Use total of inProgress + blocked as the denominator so blocked items
        // that aren't in the in_progress bucket are still counted.
        var denominator = Math.max(inProgress + blocked, 1);
        var score = Math.round(clamp(1 - (blocked / denominator), 0, 1) * 100);

        return {
            score: score,
            weight: 0.20,
            detail: blocked + ' blocked'
        };
    }

    /**
     * WIP Balance Factor (weight 0.20)
     * Ideal: 1-WIP_IDEAL_MAX items in progress.
     * Zero in-progress = 50 (neutral — not penalized for being between sprints).
     * Over limit: linear penalty from 100 at limit to 0 at 2x limit.
     */
    function computeWIPFactor(team) {
        var sc = team.statusCounts || {};
        var inProgress = (sc.in_progress || 0) + (sc.coding || 0) +
                         (sc.planning || 0) + (sc.review || 0);

        if (inProgress === 0) {
            return {
                score: 50,
                weight: 0.20,
                detail: 'nothing in progress'
            };
        }

        var score;
        if (inProgress <= WIP_IDEAL_MAX) {
            // Within ideal range — full score
            score = 100;
        } else {
            // Over the limit — linear penalty
            var overage = inProgress - WIP_IDEAL_MAX;
            var penalty = overage / WIP_IDEAL_MAX;   // 0 at limit, 1 at 2x limit
            score = Math.round(clamp(1 - penalty, 0, 1) * 100);
        }

        return {
            score: score,
            weight: 0.20,
            detail: inProgress + ' in progress'
        };
    }

    // -------------------------------------------------------------------------
    // Public: computeTeamHealth
    // -------------------------------------------------------------------------

    /**
     * Compute a health score object for a single team.
     * Returns a health score object even if teamData is missing/invalid (unknown status).
     *
     * @param {Object} teamData  Team data object from kanban API.
     * @returns {Object} Health score object.
     */
    function computeTeamHealth(teamData) {
        if (!teamData || teamData.error) {
            var teamId = (teamData && teamData.teamId) || 'unknown';
            return {
                score: 0,
                grade: 'N/A',
                status: 'unknown',
                color: STATUS_COLORS.unknown,
                factors: {},
                teamName: (teamData && teamData.displayName) || teamId,
                teamId: teamId,
                computedAt: new Date().toISOString()
            };
        }

        var factors = {
            completionRate:  computeCompletionFactor(teamData),
            activityRecency: computeActivityFactor(teamData),
            blockedRatio:    computeBlockedFactor(teamData),
            wipBalance:      computeWIPFactor(teamData)
        };

        // Weighted sum
        var rawScore = 0;
        Object.keys(factors).forEach(function (key) {
            rawScore += factors[key].score * factors[key].weight;
        });

        var score = Math.round(clamp(rawScore, 0, 100));
        var status = scoreToStatus(score);

        return {
            score: score,
            grade: scoreToGrade(score),
            status: status,
            color: statusToColor(status),
            factors: factors,
            teamName: teamData.displayName || teamData.teamId || 'Unknown',
            teamId: teamData.teamId || 'unknown',
            computedAt: new Date().toISOString()
        };
    }

    // -------------------------------------------------------------------------
    // Public: computeDivisionHealth
    // -------------------------------------------------------------------------

    /**
     * Compute an aggregated health score for a division from its team scores.
     *
     * @param {Array} divisionTeams  Array of team health score objects.
     * @param {string} divisionId    Division identifier.
     * @returns {Object} Division health score object.
     */
    function computeDivisionHealth(divisionTeams, divisionId) {
        divisionId = divisionId || 'unknown';

        if (!divisionTeams || divisionTeams.length === 0) {
            return {
                score: 0,
                grade: 'N/A',
                status: 'unknown',
                color: STATUS_COLORS.unknown,
                divisionId: divisionId,
                teamCount: 0,
                healthyCount: 0,
                warningCount: 0,
                criticalCount: 0,
                unknownCount: 0,
                teams: [],
                computedAt: new Date().toISOString()
            };
        }

        // Only include teams with known status in the average
        var scoredTeams = divisionTeams.filter(function (t) {
            return t.status !== 'unknown';
        });

        var avgScore = 0;
        if (scoredTeams.length > 0) {
            var sum = scoredTeams.reduce(function (acc, t) { return acc + t.score; }, 0);
            avgScore = Math.round(sum / scoredTeams.length);
        }

        var healthyCount  = divisionTeams.filter(function (t) { return t.status === 'healthy'; }).length;
        var warningCount  = divisionTeams.filter(function (t) { return t.status === 'warning'; }).length;
        var criticalCount = divisionTeams.filter(function (t) { return t.status === 'critical'; }).length;
        var unknownCount  = divisionTeams.filter(function (t) { return t.status === 'unknown'; }).length;

        var status = scoredTeams.length === 0 ? 'unknown' : scoreToStatus(avgScore);

        return {
            score: avgScore,
            grade: scoredTeams.length === 0 ? 'N/A' : scoreToGrade(avgScore),
            status: status,
            color: statusToColor(status),
            divisionId: divisionId,
            teamCount: divisionTeams.length,
            healthyCount: healthyCount,
            warningCount: warningCount,
            criticalCount: criticalCount,
            unknownCount: unknownCount,
            teams: divisionTeams,
            computedAt: new Date().toISOString()
        };
    }

    // -------------------------------------------------------------------------
    // Internal: recompute all scores from event data
    // -------------------------------------------------------------------------

    /**
     * Recompute all team and division scores from a kanban data payload.
     * Populates module-level caches and dispatches 'lcars:healthScoresReady'.
     *
     * @param {Object} data  Payload from 'lcars:kanbanDataReady' — { teams, overall }.
     */
    function recomputeAll(data) {
        var teams   = data.teams   || {};
        var overall = data.overall || {};

        // --- Team scores ---
        var newTeamScores = {};
        Object.keys(teams).forEach(function (key) {
            var team = teams[key];
            var score = computeTeamHealth(team);
            newTeamScores[score.teamId] = score;
        });
        teamScores = newTeamScores;

        // --- Division scores ---
        var divisionBuckets = {};
        Object.keys(newTeamScores).forEach(function (teamId) {
            var divId = getTeamDivision(teamId);
            if (!divisionBuckets[divId]) {
                divisionBuckets[divId] = [];
            }
            divisionBuckets[divId].push(newTeamScores[teamId]);
        });

        var newDivisionScores = {};
        Object.keys(divisionBuckets).forEach(function (divId) {
            newDivisionScores[divId] = computeDivisionHealth(divisionBuckets[divId], divId);
        });
        divisionScores = newDivisionScores;

        // --- Overall fleet score ---
        var allTeamScoreList = Object.values(newTeamScores).filter(function (t) {
            return t.status !== 'unknown';
        });

        var overallScoreValue = 0;
        if (allTeamScoreList.length > 0) {
            var sum = allTeamScoreList.reduce(function (acc, t) { return acc + t.score; }, 0);
            overallScoreValue = Math.round(sum / allTeamScoreList.length);
        }

        var overallStatus = allTeamScoreList.length === 0 ? 'unknown' : scoreToStatus(overallScoreValue);

        overallScore = {
            score: overallScoreValue,
            grade: allTeamScoreList.length === 0 ? 'N/A' : scoreToGrade(overallScoreValue),
            status: overallStatus,
            color: statusToColor(overallStatus),
            teamCount: Object.keys(newTeamScores).length,
            divisionCount: Object.keys(newDivisionScores).length,
            healthyCount:  Object.values(newTeamScores).filter(function (t) { return t.status === 'healthy'; }).length,
            warningCount:  Object.values(newTeamScores).filter(function (t) { return t.status === 'warning'; }).length,
            criticalCount: Object.values(newTeamScores).filter(function (t) { return t.status === 'critical'; }).length,
            unknownCount:  Object.values(newTeamScores).filter(function (t) { return t.status === 'unknown'; }).length,
            computedAt: new Date().toISOString()
        };

        console.log('[LCARSHealthScores] Computed scores for', Object.keys(newTeamScores).length,
            'teams across', Object.keys(newDivisionScores).length,
            'divisions. Fleet score:', overallScoreValue);

        // Broadcast results
        document.dispatchEvent(new CustomEvent('lcars:healthScoresReady', {
            detail: {
                teams: teamScores,
                divisions: divisionScores,
                overall: overallScore
            }
        }));
    }

    // -------------------------------------------------------------------------
    // Public: init
    // -------------------------------------------------------------------------

    /**
     * Initialize the module and register event listeners.
     * Safe to call multiple times — registers listener only once.
     */
    function init() {
        if (initialized) return;
        initialized = true;

        document.addEventListener('lcars:kanbanDataReady', function (e) {
            if (!e.detail) return;
            try {
                recomputeAll(e.detail);
            } catch (err) {
                console.error('[LCARSHealthScores] Error recomputing scores:', err);
            }
        });

        console.log('[LCARSHealthScores] Initialized — listening for lcars:kanbanDataReady');
    }

    // -------------------------------------------------------------------------
    // Auto-init on DOMContentLoaded
    // Mirrors the self-contained initialization pattern used by other LCARS modules.
    // lcars-dashboard-app.js may also call init() explicitly — that is safe (idempotent).
    // -------------------------------------------------------------------------

    document.addEventListener('DOMContentLoaded', function () {
        init();
    });

    // -------------------------------------------------------------------------
    // Public API
    // -------------------------------------------------------------------------

    return {
        /** Initialize and register event listeners. */
        init: init,

        /**
         * Compute health score for a single team.
         * @param {Object} teamData  Team data from kanban API.
         * @returns {Object} Health score object.
         */
        computeTeamHealth: computeTeamHealth,

        /**
         * Compute aggregated health score for a division.
         * @param {Array} divisionTeams  Array of team health score objects.
         * @param {string} [divisionId]  Division identifier.
         * @returns {Object} Division health score object.
         */
        computeDivisionHealth: computeDivisionHealth,

        /**
         * Returns the cached map of all team health scores (teamId -> score object).
         * Empty until the first 'lcars:kanbanDataReady' event fires.
         */
        getTeamScores: function () { return teamScores; },

        /**
         * Returns the cached map of all division health scores (divisionId -> score object).
         * Empty until the first 'lcars:kanbanDataReady' event fires.
         */
        getDivisionScores: function () { return divisionScores; },

        /**
         * Returns the fleet-wide health score object.
         * Null until the first 'lcars:kanbanDataReady' event fires.
         */
        getOverallScore: function () { return overallScore; },

        /** Color constants — exposed for use by other modules rendering health indicators. */
        STATUS_COLORS: STATUS_COLORS
    };

}());
