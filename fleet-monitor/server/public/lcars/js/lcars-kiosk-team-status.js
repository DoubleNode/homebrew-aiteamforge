//
//  lcars-kiosk-team-status.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

/**
 * lcars-kiosk-team-status.js
 * LCARS Fleet Monitor — Team Status Board (Kiosk-Only Page)
 *
 * Registers a kiosk-only analytics page that renders a full-screen grid of
 * team health cards. Each card shows:
 *   - Team name + status dot (colored by health status)
 *   - Large health score + letter grade
 *   - Compact metrics grid (total, completed, in-progress, completion %)
 *   - Recent activity indicator
 *
 * Cards are sorted by health score ascending (critical teams top-left)
 * so problem areas are immediately visible during a kiosk sweep.
 *
 * Registration: LCARSAnalyticsPages.registerKioskPage({ id: 'team-status', ... })
 * Data source:  LCARSHealthScores.getTeamScores()
 * CSS:          lcars-kiosk-health.css (all classes pre-defined)
 *
 * Dependencies (must be loaded before this script):
 *   - lcars-health-scores.js   (LCARSHealthScores)
 *   - lcars-analytics-pages.js (LCARSAnalyticsPages)
 *
 * Listens for:
 *   - lcars:healthScoresReady  — re-renders when fresh scores are available
 */

/* global LCARSHealthScores, LCARSAnalyticsPages */

(function () {
    'use strict';

    // =========================================================================
    // RENDER HELPERS
    // =========================================================================

    /**
     * Determine the CSS animation class to apply to a team card
     * based on health status.
     *
     * @param {string} status - 'healthy' | 'warning' | 'critical' | 'unknown'
     * @returns {string} CSS class name (may be empty string)
     */
    function pulseClassFor(status) {
        if (status === 'critical') return 'kiosk-health-critical-pulse';
        if (status === 'warning')  return 'kiosk-health-warning-pulse';
        if (status === 'healthy')  return 'kiosk-health-pulse';
        return '';
    }

    /**
     * Build the activity indicator element for a team card.
     * Shows a ping animation ring for active teams; idle state for inactive.
     *
     * "Active" is defined as activityRecency factor score > 0,
     * which means at least one item was completed in the last 7 days.
     *
     * @param {object} teamScore - Team health score object from LCARSHealthScores
     * @returns {HTMLElement} .kiosk-team-activity element
     */
    function buildActivityIndicator(teamScore) {
        var factors = teamScore.factors || {};
        var activityFactor = factors.activityRecency || {};
        var hasActivity = (activityFactor.score || 0) > 0;
        var detail = activityFactor.detail || 'no recent activity';

        var el = document.createElement('div');
        el.className = 'kiosk-team-activity' + (hasActivity ? '' : ' idle');

        // Container for the ping ring + dot
        var dotWrapper = document.createElement('div');
        dotWrapper.style.cssText = 'position: relative; width: 12px; height: 12px; flex-shrink: 0;';

        if (hasActivity) {
            // Ping ring expands outward from behind the dot
            var ring = document.createElement('div');
            ring.className = 'kiosk-team-activity-ring';
            dotWrapper.appendChild(ring);
        }

        var dot = document.createElement('div');
        dot.className = 'kiosk-team-activity-dot';
        dotWrapper.appendChild(dot);

        var label = document.createElement('span');
        label.className = 'kiosk-team-activity-label';
        label.textContent = hasActivity ? detail : 'NO RECENT ACTIVITY';

        el.appendChild(dotWrapper);
        el.appendChild(label);

        return el;
    }

    /**
     * Build a single .kiosk-metric element.
     *
     * @param {string|number} value - The numeric value to display
     * @param {string} label        - The metric label (will be uppercased)
     * @returns {HTMLElement}
     */
    function buildMetric(value, label) {
        var el = document.createElement('div');
        el.className = 'kiosk-metric';

        var valEl = document.createElement('div');
        valEl.className = 'kiosk-metric-value';
        valEl.textContent = String(value);

        var lblEl = document.createElement('div');
        lblEl.className = 'kiosk-metric-label';
        lblEl.textContent = label.toUpperCase();

        el.appendChild(valEl);
        el.appendChild(lblEl);
        return el;
    }

    /**
     * Build a team card element from a health score object.
     *
     * @param {object} teamScore - Health score object: { score, grade, status,
     *   color, factors, teamName, teamId, computedAt }
     * @returns {HTMLElement} .kiosk-team-card element
     */
    function buildTeamCard(teamScore) {
        var status = teamScore.status || 'unknown';
        var score  = teamScore.score  || 0;
        var grade  = teamScore.grade  || 'N/A';
        var name   = (teamScore.teamName || teamScore.teamId || 'UNKNOWN').toUpperCase();

        // Extract factor details for metrics
        var factors     = teamScore.factors || {};
        var compFactor  = factors.completionRate  || {};
        var wipFactor   = factors.wipBalance       || {};

        // Parse "completed/total items" from completionRate detail string
        // Format: "3/10 items" or "no items"
        var totalItems     = 0;
        var completedItems = 0;
        var inProgressItems = 0;
        var completionPct  = 0;

        var compDetail = compFactor.detail || '';
        var matchCounts = compDetail.match(/^(\d+)\/(\d+)/);
        if (matchCounts) {
            completedItems = parseInt(matchCounts[1], 10);
            totalItems     = parseInt(matchCounts[2], 10);
            completionPct  = totalItems > 0 ? Math.round((completedItems / totalItems) * 100) : 0;
        }

        // Parse in-progress count from WIP factor detail: "N in progress"
        var wipDetail = wipFactor.detail || '';
        var matchWip = wipDetail.match(/^(\d+)\s+in\s+progress/);
        if (matchWip) {
            inProgressItems = parseInt(matchWip[1], 10);
        }

        // --- Build card ---
        var card = document.createElement('div');
        card.className = 'kiosk-team-card health-' + status;

        // Left border color comes from the CSS health-status class.
        // We also apply pulse animation class directly to the card for critical/warning.
        var pulse = pulseClassFor(status);
        if (pulse) {
            // The CSS already has kiosk-health-critical-pulse on .health-critical cards,
            // but add the general warning pulse here since CSS only covers critical.
            if (status === 'warning') {
                card.classList.add(pulse);
            }
            // critical pulse is handled by CSS selector .kiosk-team-card.health-critical
        }

        // ---- HEADER: avatar + name group + status dot ----
        var header = document.createElement('div');
        header.className = 'kiosk-team-header';

        var avatar = document.createElement('div');
        avatar.className = 'kiosk-team-avatar';
        // Use first letter of team name as avatar initial — works without images
        avatar.textContent = name.charAt(0);
        avatar.style.borderColor = teamScore.color || 'var(--lcars-tan)';

        var nameGroup = document.createElement('div');
        nameGroup.className = 'kiosk-team-name-group';

        var nameEl = document.createElement('div');
        nameEl.className = 'kiosk-team-name';
        nameEl.textContent = name;
        nameEl.title = name;   // tooltip for truncated names

        var orgEl = document.createElement('div');
        orgEl.className = 'kiosk-team-org';
        orgEl.textContent = teamScore.teamId || '';

        nameGroup.appendChild(nameEl);
        nameGroup.appendChild(orgEl);

        var statusDot = document.createElement('div');
        statusDot.className = 'kiosk-team-status-dot ' + status;

        header.appendChild(avatar);
        header.appendChild(nameGroup);
        header.appendChild(statusDot);

        // ---- SCORE: large number + grade ----
        var scoreEl = document.createElement('div');
        scoreEl.className = 'kiosk-team-score';

        var scoreNum = document.createElement('div');
        scoreNum.className = 'kiosk-team-score-number';
        scoreNum.textContent = score;

        var scoreGrade = document.createElement('div');
        scoreGrade.className = 'kiosk-team-score-grade';
        scoreGrade.textContent = grade;

        scoreEl.appendChild(scoreNum);
        scoreEl.appendChild(scoreGrade);

        // ---- METRICS: 4-item grid ----
        var metricsEl = document.createElement('div');
        metricsEl.className = 'kiosk-team-metrics';

        metricsEl.appendChild(buildMetric(totalItems,       'TOTAL'));
        metricsEl.appendChild(buildMetric(completedItems,   'DONE'));
        metricsEl.appendChild(buildMetric(inProgressItems,  'IN PROG'));
        metricsEl.appendChild(buildMetric(completionPct + '%', 'COMPLETE'));

        // ---- ACTIVITY INDICATOR ----
        var activityEl = buildActivityIndicator(teamScore);

        // ---- Assemble card ----
        card.appendChild(header);
        card.appendChild(scoreEl);
        card.appendChild(metricsEl);
        card.appendChild(activityEl);

        return card;
    }

    /**
     * Build the "awaiting data" placeholder when no scores are available.
     *
     * @returns {HTMLElement} A centered message element
     */
    function buildNoDataState() {
        var el = document.createElement('div');
        el.className = 'kiosk-health-no-data';
        var label = document.createElement('span');
        label.className = 'kiosk-health-no-data-label';
        label.textContent = 'AWAITING TEAM DATA';
        el.appendChild(label);
        return el;
    }

    // =========================================================================
    // RENDER FUNCTION
    // =========================================================================

    /**
     * Main render function. Called by LCARSAnalyticsPages when switching to
     * this kiosk page. Also called on healthScoresReady re-render.
     *
     * @param {HTMLElement} container - The #analytics-content element
     */
    function render(container) {
        // Wipe previous content
        container.innerHTML = '';

        // Build the outer grid
        var board = document.createElement('div');
        board.className = 'kiosk-status-board';

        // --- Page header (spans all columns) ---
        var headerRow = document.createElement('div');
        headerRow.className = 'kiosk-status-board-header';

        var titleEl = document.createElement('div');
        titleEl.className = 'kiosk-status-board-title';
        titleEl.textContent = 'TEAM STATUS BOARD';

        var barEl = document.createElement('div');
        barEl.className = 'kiosk-status-board-bar';

        headerRow.appendChild(titleEl);
        headerRow.appendChild(barEl);
        board.appendChild(headerRow);

        // --- Get team scores ---
        var teamScores = {};
        if (window.LCARSHealthScores) {
            teamScores = LCARSHealthScores.getTeamScores() || {};
        }

        var scoreList = Object.values(teamScores);

        if (scoreList.length === 0) {
            board.appendChild(buildNoDataState());
        } else {
            // Sort ascending by score — critical teams first (top-left on screen)
            scoreList.sort(function (a, b) { return a.score - b.score; });

            scoreList.forEach(function (teamScore) {
                board.appendChild(buildTeamCard(teamScore));
            });
        }

        container.appendChild(board);
    }

    // =========================================================================
    // REGISTRATION & INIT
    // =========================================================================

    /**
     * Register the page and wire up the healthScoresReady listener.
     * Safe to call before or after LCARSAnalyticsPages.init().
     */
    function init() {
        // Guard: LCARSAnalyticsPages must exist
        if (!window.LCARSAnalyticsPages) {
            console.warn('[LCARSKioskTeamStatus] LCARSAnalyticsPages not found — cannot register page.');
            return;
        }

        // Register the kiosk-only page
        LCARSAnalyticsPages.registerKioskPage({
            id:       'team-status',
            label:    'TEAM STATUS',
            renderFn: render
        });

        // Re-render when fresh scores arrive (if the page is currently shown)
        document.addEventListener('lcars:healthScoresReady', function () {
            // Only re-render if we are the currently active kiosk page.
            // Checking via LCARSAnalyticsPages.getCurrentPage() avoids a blind
            // re-render that would interfere with other pages.
            if (LCARSAnalyticsPages.getCurrentPage() === 'team-status') {
                var contentEl = document.getElementById('analytics-content');
                if (contentEl) {
                    render(contentEl);
                }
            }
        });

        console.log('[LCARSKioskTeamStatus] Registered kiosk page: team-status');
    }

    // =========================================================================
    // AUTO-INIT
    // =========================================================================

    // Use DOMContentLoaded so LCARSAnalyticsPages is guaranteed to be defined.
    // If the DOM is already ready (deferred scripts), call immediately.
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }

}());
