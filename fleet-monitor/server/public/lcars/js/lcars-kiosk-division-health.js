//
//  lcars-kiosk-division-health.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

/**
 * lcars-kiosk-division-health.js
 * LCARS Kiosk Page — Division Health Summary
 *
 * Registers a kiosk-only analytics page that shows a high-level overview
 * of health scores across all divisions with fleet-wide rollup.
 *
 * Registration: LCARSAnalyticsPages.registerKioskPage()
 * Data source:  LCARSHealthScores.getDivisionScores() / getOverallScore()
 * Event:        lcars:healthScoresReady — triggers re-render when data updates
 *
 * Requires (load order):
 *   lcars-health-scores.js    — provides LCARSHealthScores
 *   lcars-analytics-pages.js  — provides LCARSAnalyticsPages.registerKioskPage()
 *   lcars-kiosk-health.css    — all CSS classes used here
 *
 * Exposes: nothing (self-registering IIFE)
 */

(function () {
    'use strict';

    // =========================================================================
    // CONSTANTS
    // =========================================================================

    var PAGE_ID    = 'division-health';
    var PAGE_LABEL = 'DIVISION HEALTH';

    /** Human-readable display names for known division IDs */
    var DIVISION_DISPLAY_NAMES = {
        academy:    'Academy',
        command:    'Command',
        mainevent:  'Main Event',
        dns:        'DNS',
        legal:      'Legal',
        medical:    'Medical'
    };

    // =========================================================================
    // HELPERS
    // =========================================================================

    /**
     * Return the display name for a division ID.
     * Falls back to title-casing the raw ID for unknown divisions.
     * @param {string} divisionId
     * @returns {string}
     */
    function getDivisionDisplayName(divisionId) {
        if (!divisionId) return 'Unknown';
        var id = divisionId.toLowerCase();

        // Freelance divisions follow the pattern "freelance-<name>"
        if (id.indexOf('freelance') === 0) {
            var suffix = id.replace(/^freelance[-_]?/, '').replace(/-/g, ' ').trim();
            return 'Freelance' + (suffix ? ' ' + suffix : '');
        }

        return DIVISION_DISPLAY_NAMES[id] || (id.charAt(0).toUpperCase() + id.slice(1));
    }

    /**
     * Map a health status to the appropriate pulse animation class.
     * @param {string} status  'healthy' | 'warning' | 'critical' | other
     * @returns {string}
     */
    function statusToPulseClass(status) {
        if (status === 'healthy')  return 'kiosk-health-pulse';
        if (status === 'warning')  return 'kiosk-health-warning-pulse';
        if (status === 'critical') return 'kiosk-health-critical-pulse';
        return '';
    }

    /**
     * Build a single .kiosk-metric element via DOM API.
     * @param {string|number} value
     * @param {string} label
     * @param {string} [colorStyle]  Optional inline color style for the value
     * @returns {HTMLElement}
     */
    function buildMetric(value, label, colorStyle) {
        var el = document.createElement('div');
        el.className = 'kiosk-metric';

        var valEl = document.createElement('span');
        valEl.className = 'kiosk-metric-value';
        valEl.textContent = String(value);
        if (colorStyle) valEl.style.color = colorStyle;

        var lblEl = document.createElement('span');
        lblEl.className = 'kiosk-metric-label';
        lblEl.textContent = label;

        el.appendChild(valEl);
        el.appendChild(lblEl);
        return el;
    }

    /**
     * Build a division card element using DOM API.
     * @param {string} divisionId
     * @param {Object} data  Division health score object from LCARSHealthScores
     * @returns {HTMLElement}
     */
    function buildDivisionCard(divisionId, data) {
        var displayName = getDivisionDisplayName(divisionId).toUpperCase();
        var score       = data.score  || 0;
        var grade       = data.grade  || 'N/A';
        var status      = data.status || 'unknown';
        var pulseClass  = statusToPulseClass(status);

        // Metrics
        var teamCount     = data.teamCount     || 0;
        var healthyCount  = data.healthyCount  || 0;
        var warningCount  = data.warningCount  || 0;
        var criticalCount = data.criticalCount || 0;

        // Completion % — derive from teams array if available
        var completionPct = 0;
        if (data.teams && data.teams.length > 0) {
            var teamsWithData = data.teams.filter(function (t) {
                return t.factors && t.factors.completionRate;
            });
            if (teamsWithData.length > 0) {
                var sumPct = teamsWithData.reduce(function (acc, t) {
                    return acc + (t.factors.completionRate.score || 0);
                }, 0);
                completionPct = Math.round(sumPct / teamsWithData.length);
            }
        }

        // --- Build card ---
        var card = document.createElement('div');
        card.className = 'kiosk-division-card health-' + status;
        if (pulseClass) card.classList.add(pulseClass);

        // Division name
        var nameEl = document.createElement('div');
        nameEl.className = 'kiosk-division-name';
        nameEl.textContent = displayName;
        card.appendChild(nameEl);

        // Score + grade
        var scoreEl = document.createElement('div');
        scoreEl.className = 'kiosk-health-score';

        var scoreNum = document.createElement('span');
        scoreNum.className = 'kiosk-health-score-number';
        scoreNum.textContent = score;

        var scoreGrade = document.createElement('span');
        scoreGrade.className = 'kiosk-health-score-grade';
        scoreGrade.textContent = grade;

        scoreEl.appendChild(scoreNum);
        scoreEl.appendChild(scoreGrade);
        card.appendChild(scoreEl);

        // Health bar
        var barEl = document.createElement('div');
        barEl.className = 'kiosk-health-bar';

        var barFill = document.createElement('div');
        barFill.className = 'kiosk-health-bar-fill';
        barFill.style.setProperty('--kiosk-bar-target', score + '%');

        barEl.appendChild(barFill);
        card.appendChild(barEl);

        // Status indicator badge
        var indicator = document.createElement('div');
        indicator.className = 'kiosk-health-indicator ' + status;
        if (pulseClass) indicator.classList.add(pulseClass);
        indicator.textContent = status.toUpperCase();
        card.appendChild(indicator);

        // Metrics grid
        var metricsEl = document.createElement('div');
        metricsEl.className = 'kiosk-division-metrics';

        metricsEl.appendChild(buildMetric(teamCount, 'Teams'));
        metricsEl.appendChild(buildMetric(healthyCount, 'Healthy', 'var(--kiosk-health-healthy)'));
        metricsEl.appendChild(buildMetric(warningCount, 'Warning', 'var(--kiosk-health-warning)'));
        metricsEl.appendChild(buildMetric(criticalCount, 'Critical', 'var(--kiosk-health-critical)'));
        metricsEl.appendChild(buildMetric(completionPct + '%', 'Completion'));
        // Filler metric for 3-column alignment
        metricsEl.appendChild(document.createElement('div'));

        card.appendChild(metricsEl);

        return card;
    }

    /**
     * Build the page header element with fleet-wide score using DOM API.
     * @param {Object|null} overall  Overall fleet health score object
     * @returns {HTMLElement}
     */
    function buildPageHeader(overall) {
        var fleetScore  = overall ? overall.score  : '--';
        var fleetGrade  = overall ? overall.grade  : '--';
        var fleetStatus = overall ? overall.status : 'unknown';

        var header = document.createElement('div');
        header.className = 'kiosk-health-summary-header';

        var title = document.createElement('div');
        title.className = 'kiosk-health-summary-title';
        title.textContent = 'Division Health Summary';

        var bar = document.createElement('div');
        bar.className = 'kiosk-health-summary-bar';

        // Fleet rollup badge — score + grade inline in header
        var badge = document.createElement('div');
        badge.className = 'kiosk-health-fleet-badge health-' + fleetStatus;

        var fleetLabel = document.createElement('span');
        fleetLabel.className = 'kiosk-health-score-label';
        fleetLabel.textContent = 'Fleet';

        var scoreNum = document.createElement('span');
        scoreNum.className = 'kiosk-health-score-number kiosk-health-fleet-score';
        scoreNum.textContent = fleetScore;

        var scoreGrade = document.createElement('span');
        scoreGrade.className = 'kiosk-health-score-grade kiosk-health-fleet-grade';
        scoreGrade.textContent = fleetGrade;

        badge.appendChild(fleetLabel);
        badge.appendChild(scoreNum);
        badge.appendChild(scoreGrade);

        header.appendChild(title);
        header.appendChild(bar);
        header.appendChild(badge);

        return header;
    }

    // =========================================================================
    // RENDER FUNCTION
    // =========================================================================

    /**
     * Render the Division Health Summary page into the given container.
     * Called by LCARSAnalyticsPages.renderKioskPage() when this page becomes active.
     *
     * @param {HTMLElement} container  The #analytics-content element
     */
    function renderPage(container) {
        // Clear existing content
        container.innerHTML = '';

        var divScores = (window.LCARSHealthScores && window.LCARSHealthScores.getDivisionScores())
            ? window.LCARSHealthScores.getDivisionScores()
            : {};

        var overall = window.LCARSHealthScores
            ? window.LCARSHealthScores.getOverallScore()
            : null;

        var divisionIds = Object.keys(divScores);

        // Build the outer grid wrapper
        var grid = document.createElement('div');
        grid.className = 'kiosk-health-summary';

        // Header spans all columns
        grid.appendChild(buildPageHeader(overall));

        // No data state
        if (divisionIds.length === 0) {
            var noData = document.createElement('div');
            noData.className = 'kiosk-health-no-data';
            var noDataLabel = document.createElement('span');
            noDataLabel.className = 'kiosk-health-no-data-label';
            noDataLabel.textContent = 'Awaiting Data';
            noData.appendChild(noDataLabel);
            grid.appendChild(noData);
            container.appendChild(grid);
            return;
        }

        // Sort: critical first, then warning, then healthy, then unknown
        var statusOrder = { critical: 0, warning: 1, healthy: 2, unknown: 3 };
        divisionIds.sort(function (a, b) {
            var sa = statusOrder[divScores[a].status] !== undefined ? statusOrder[divScores[a].status] : 99;
            var sb = statusOrder[divScores[b].status] !== undefined ? statusOrder[divScores[b].status] : 99;
            return sa - sb;
        });

        // Build and append each division card
        divisionIds.forEach(function (divId) {
            grid.appendChild(buildDivisionCard(divId, divScores[divId]));
        });

        container.appendChild(grid);
    }

    // =========================================================================
    // REFRESH INTEGRATION
    // =========================================================================

    /**
     * Re-render the page if it is currently the active kiosk page.
     * Called when lcars:healthScoresReady fires with fresh data.
     */
    function onHealthScoresReady() {
        if (!window.LCARSAnalyticsPages) return;

        var currentPage = window.LCARSAnalyticsPages.getCurrentPage();
        if (currentPage !== PAGE_ID) return;

        // Page is active — re-render with fresh data
        var container = document.getElementById('analytics-content');
        if (!container) return;

        renderPage(container);
    }

    // =========================================================================
    // INIT
    // =========================================================================

    /**
     * Register the kiosk page and wire up the health scores update listener.
     * Safe to call early (registerKioskPage handles pre-init timing).
     */
    function init() {
        // Guard: LCARSAnalyticsPages must be present
        if (!window.LCARSAnalyticsPages || typeof window.LCARSAnalyticsPages.registerKioskPage !== 'function') {
            console.warn('[LCARSKioskDivisionHealth] LCARSAnalyticsPages not available — cannot register page');
            return;
        }

        window.LCARSAnalyticsPages.registerKioskPage({
            id:       PAGE_ID,
            label:    PAGE_LABEL,
            renderFn: renderPage
        });

        // Listen for health score updates
        document.addEventListener('lcars:healthScoresReady', onHealthScoresReady);

        console.log('[LCARSKioskDivisionHealth] Registered kiosk page:', PAGE_ID);
    }

    // =========================================================================
    // ENTRY POINT
    // =========================================================================

    // Run after DOM is ready, ensuring both dependency scripts have executed.
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }

}());
