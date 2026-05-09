//
//  lcars-analytics-knowledge.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

/**
 * lcars-analytics-knowledge.js
 * LCARS Analytics - Knowledge Base Charts & Metrics
 *
 * Fetches knowledge base statistics from /api/knowledge-stats and renders
 * all knowledge-related charts and metrics into the ANALYTICS section:
 *
 *   - Overall summary metric cards  (#knowledge-overall-metrics)
 *   - Category doughnut chart       (#knowledge-category-doughnut)
 *   - Team entries bar chart        (#knowledge-team-bar)
 *   - Recent entries list           (#knowledge-recent-entries)
 *   - Top tags display              (#knowledge-top-tags)
 *
 * Dispatches lcars:knowledgeDataReady for team pages to consume.
 *
 * Requires: Chart.js 4.x, LCARSCharts (loaded before this script)
 */

/* global LCARSCharts */

// Assign to window — const/let don't create window properties.
window.LCARSAnalyticsKnowledge = (function () {
    'use strict';

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    const charts = {
        categoryDoughnut: null,
        teamBar: null
    };

    let lastData = null;
    let initialized = false;
    let currentAnalyticsPage = null;

    /** Dashboard division filter — set via setDivisions(). null = show all. */
    let activeDivisions = null;

    // -------------------------------------------------------------------------
    // Division filtering — mirrors lcars-analytics-kanban.js
    // -------------------------------------------------------------------------

    const DIVISION_MAP = {
        academy:    'academy',
        command:    'mainevent',
        android:    'mainevent',
        firebase:   'mainevent',
        ios:        'mainevent',
        dns:        'dns',
    };

    function getTeamDivision(teamId) {
        var id = teamId.toLowerCase();
        if (id.startsWith('freelance')) return id;
        if (id.startsWith('legal'))     return 'legal';
        if (id.startsWith('medical'))   return 'medical';
        return DIVISION_MAP[id] || id;
    }

    function filterTeamsByDivision(teams) {
        if (!activeDivisions || activeDivisions.length === 0) return teams;
        var filtered = {};
        Object.keys(teams).forEach(function (key) {
            var teamId = key.toLowerCase();
            if (activeDivisions.indexOf(teamId) !== -1 ||
                activeDivisions.indexOf(getTeamDivision(teamId)) !== -1) {
                filtered[key] = teams[key];
            }
        });
        return filtered;
    }

    // -------------------------------------------------------------------------
    // Team color palette — matches other analytics modules
    // -------------------------------------------------------------------------

    const TEAM_COLORS = [
        '#99CCFF', '#FFCC99', '#CC99CC', '#99CC99',
        '#FF9900', '#9999CC', '#FFFF99', '#CC6666'
    ];

    function teamColor(index) {
        return TEAM_COLORS[index % TEAM_COLORS.length];
    }

    // -------------------------------------------------------------------------
    // Data fetch
    // -------------------------------------------------------------------------

    async function fetchKnowledgeStats() {
        try {
            var response = await fetch('/api/knowledge-stats');
            if (!response.ok) {
                throw new Error('HTTP ' + response.status + ': ' + response.statusText);
            }
            return await response.json();
        } catch (error) {
            console.error('[LCARSAnalyticsKnowledge] Failed to fetch knowledge stats:', error);
            return null;
        }
    }

    // -------------------------------------------------------------------------
    // Render: Overall summary metrics
    // -------------------------------------------------------------------------

    function renderOverallMetrics(overall) {
        var container = document.getElementById('knowledge-overall-metrics');
        if (!container) return;

        if (!overall) {
            container.innerHTML = '<div style="color: #CC6666; font-family: \'Antonio\', sans-serif; padding: 10px;">NO DATA AVAILABLE</div>';
            return;
        }

        var metrics = [
            { label: 'TOTAL ENTRIES',        value: overall.totalEntries || 0,              color: '#CC99CC' },
            { label: 'CONTRIBUTING AGENTS',  value: overall.totalContributingAgents || 0,   color: '#99CCFF' },
            { label: 'TEAMS W/ ENTRIES',     value: overall.teamsWithEntries || 0,           color: '#99CC99' },
            { label: 'CATEGORIES',           value: overall.uniqueCategories || 0,           color: '#FFCC99' },
            { label: 'UNIQUE TAGS',          value: overall.uniqueTags || 0,                 color: '#FF9900' }
        ];

        container.innerHTML = metrics.map(function (m) {
            return '<div class="summary-card lcars-fade-in-up" style="background: rgba(0,0,0,0.3); border-radius: 8px; padding: 12px; text-align: center;">' +
                '<div class="summary-value" style="color: ' + m.color + '; font-family: \'Antonio\', sans-serif; font-size: 28px; font-weight: 600;">' + m.value + '</div>' +
                '<div class="summary-label" style="color: rgba(255,204,153,0.7); font-family: \'Antonio\', sans-serif; font-size: 11px; margin-top: 4px; letter-spacing: 0.05em;">' + m.label + '</div>' +
                '</div>';
        }).join('');
    }

    // -------------------------------------------------------------------------
    // Render: Category doughnut chart
    // -------------------------------------------------------------------------

    function renderCategoryDoughnut(overall) {
        var canvasId = 'knowledge-category-doughnut';
        var canvas = document.getElementById(canvasId);
        if (!canvas) return;

        var categories = overall ? (overall.categories || {}) : {};
        var labels = [];
        var values = [];
        var colors = [];

        // LCARS category color palette
        var catPalette = [
            '#CC99CC', '#99CCFF', '#FFCC99', '#99CC99',
            '#FF9900', '#9999CC', '#FFFF99', '#CC6666'
        ];

        var idx = 0;
        Object.keys(categories).sort().forEach(function (cat) {
            if (categories[cat] > 0) {
                labels.push(cat.toUpperCase());
                values.push(categories[cat]);
                colors.push(catPalette[idx % catPalette.length]);
                idx++;
            }
        });

        if (labels.length === 0) {
            labels.push('NO DATA');
            values.push(1);
            colors.push('rgba(255,204,153,0.15)');
        }

        var chartData = {
            labels: labels,
            datasets: [{
                data: values,
                backgroundColor: colors,
                borderColor: LCARSCharts.colors.background,
                borderWidth: 2,
                hoverBorderColor: LCARSCharts.colors.tan,
                hoverBorderWidth: 3
            }]
        };

        // Center text plugin — scoped to this chart instance only
        var totalEntries = overall ? (overall.totalEntries || 0) : 0;
        var centerTextPlugin = {
            id: 'knowledgeCenterText',
            afterDraw: function (chart) {
                var ctx = chart.ctx;
                var area = chart.chartArea;
                var centerX = (area.left + area.right) / 2;
                var centerY = (area.top + area.bottom) / 2;
                ctx.save();
                ctx.font = '600 22px "Antonio", sans-serif';
                ctx.fillStyle = LCARSCharts.colors.tan;
                ctx.textAlign = 'center';
                ctx.textBaseline = 'middle';
                ctx.fillText(totalEntries, centerX, centerY - 8);
                ctx.font = '400 11px "Antonio", sans-serif';
                ctx.fillStyle = LCARSCharts.colors.textDim;
                ctx.fillText('ENTRIES', centerX, centerY + 10);
                ctx.restore();
            }
        };

        if (charts.categoryDoughnut) {
            LCARSCharts.updateChart(charts.categoryDoughnut, chartData);
            var pluginIdx = charts.categoryDoughnut.config.plugins
                ? charts.categoryDoughnut.config.plugins.findIndex(function (p) { return p.id === 'knowledgeCenterText'; })
                : -1;
            if (pluginIdx !== -1) {
                charts.categoryDoughnut.config.plugins[pluginIdx] = centerTextPlugin;
            }
            charts.categoryDoughnut.update();
        } else {
            charts.categoryDoughnut = LCARSCharts.createDoughnut(canvasId, chartData, {
                plugins: {
                    legend: {
                        display: true,
                        position: 'bottom',
                        labels: {
                            color: LCARSCharts.colors.text,
                            font: { family: "'Antonio', sans-serif", size: 11 },
                            padding: 8,
                            boxWidth: 10,
                            boxHeight: 10,
                            usePointStyle: true,
                            pointStyle: 'rectRounded'
                        }
                    }
                }
            });

            if (charts.categoryDoughnut) {
                if (!charts.categoryDoughnut.config.plugins) {
                    charts.categoryDoughnut.config.plugins = [];
                }
                charts.categoryDoughnut.config.plugins.push(centerTextPlugin);
                charts.categoryDoughnut.update();
            }
        }
    }

    // -------------------------------------------------------------------------
    // Render: Team entries bar chart
    // -------------------------------------------------------------------------

    function renderTeamBar(teams) {
        var canvasId = 'knowledge-team-bar';
        var canvas = document.getElementById(canvasId);
        if (!canvas) return;

        if (!teams || Object.keys(teams).length === 0) return;

        // Sort teams by total entries descending
        var sortedTeams = Object.values(teams)
            .filter(function (t) { return (t.totalEntries || 0) > 0; })
            .sort(function (a, b) { return (b.totalEntries || 0) - (a.totalEntries || 0); });

        // Include teams with 0 entries at the end
        var zeroTeams = Object.values(teams)
            .filter(function (t) { return (t.totalEntries || 0) === 0; })
            .sort(function (a, b) { return (a.teamId || '').localeCompare(b.teamId || ''); });

        var allTeams = sortedTeams.concat(zeroTeams);

        var labels = allTeams.map(function (t) {
            return (t.teamId || 'UNKNOWN').toUpperCase();
        });

        var entriesData = allTeams.map(function (t) { return t.totalEntries || 0; });
        var agentsData = allTeams.map(function (t) { return t.contributingAgents || 0; });

        var chartData = {
            labels: labels,
            datasets: [
                {
                    label: 'ENTRIES',
                    data: entriesData,
                    backgroundColor: 'rgba(204, 153, 204, 0.6)',
                    borderColor: '#CC99CC',
                    borderWidth: 1,
                    borderRadius: 4,
                    borderSkipped: false
                },
                {
                    label: 'AGENTS',
                    data: agentsData,
                    backgroundColor: 'rgba(153, 204, 255, 0.6)',
                    borderColor: '#99CCFF',
                    borderWidth: 1,
                    borderRadius: 4,
                    borderSkipped: false
                }
            ]
        };

        if (charts.teamBar) {
            LCARSCharts.updateChart(charts.teamBar, chartData);
        } else {
            charts.teamBar = LCARSCharts.createBar(canvasId, chartData, {
                indexAxis: 'y',
                barPercentage: 0.5,
                plugins: {
                    legend: {
                        display: true,
                        position: 'top',
                        labels: {
                            color: LCARSCharts.colors.text,
                            font: { family: "'Antonio', sans-serif", size: 11 },
                            padding: 10,
                            boxWidth: 10,
                            boxHeight: 10
                        }
                    }
                },
                scales: {
                    x: {
                        grid: { color: LCARSCharts.colors.gridLine },
                        ticks: {
                            color: LCARSCharts.colors.textDim,
                            font: { family: "'Antonio', sans-serif", size: 10 },
                            stepSize: 1
                        },
                        beginAtZero: true
                    },
                    y: {
                        grid: { display: false },
                        ticks: {
                            color: LCARSCharts.colors.text,
                            font: { family: "'Antonio', sans-serif", size: 11 }
                        }
                    }
                }
            });
        }
    }

    // -------------------------------------------------------------------------
    // Render: Recent entries list
    // -------------------------------------------------------------------------

    function renderRecentEntries(entries) {
        var container = document.getElementById('knowledge-recent-entries');
        if (!container) return;

        if (!entries || entries.length === 0) {
            container.innerHTML = '<div style="color: rgba(255,204,153,0.4); font-family: \'Antonio\', sans-serif; font-size: 12px;">NO RECENT ENTRIES</div>';
            return;
        }

        var html = entries.map(function (entry) {
            var title = entry.title || 'Untitled';
            var agent = (entry.agent || '').toUpperCase();
            var team = (entry.teamId || '').toUpperCase();
            var date = entry.date || '';
            var category = (entry.category || '').toUpperCase();

            return '<div style="padding: 8px 0; border-bottom: 1px solid rgba(255,255,255,0.06);">' +
                '<div style="color: #FFCC99; font-family: \'Antonio\', sans-serif; font-size: 13px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">' + title + '</div>' +
                '<div style="display: flex; gap: 12px; margin-top: 3px;">' +
                    '<span style="color: #CC99CC; font-family: \'Antonio\', sans-serif; font-size: 11px;">' + agent + '</span>' +
                    '<span style="color: rgba(255,204,153,0.5); font-family: \'Antonio\', sans-serif; font-size: 11px;">' + team + '</span>' +
                    '<span style="color: rgba(255,204,153,0.5); font-family: \'Antonio\', sans-serif; font-size: 11px;">' + date + '</span>' +
                    (category ? '<span style="color: #99CC99; font-family: \'Antonio\', sans-serif; font-size: 10px; background: rgba(153,204,153,0.15); padding: 1px 6px; border-radius: 3px;">' + category + '</span>' : '') +
                '</div>' +
                '</div>';
        }).join('');

        container.innerHTML = html;
    }

    // -------------------------------------------------------------------------
    // Render: Top tags
    // -------------------------------------------------------------------------

    function renderTopTags(topTags) {
        var container = document.getElementById('knowledge-top-tags');
        if (!container) return;

        if (!topTags || topTags.length === 0) {
            container.innerHTML = '<div style="color: rgba(255,204,153,0.4); font-family: \'Antonio\', sans-serif; font-size: 12px;">NO TAGS</div>';
            return;
        }

        var html = '<div style="display: flex; flex-wrap: wrap; gap: 6px;">';
        topTags.forEach(function (tagObj) {
            var tag = tagObj.tag || '';
            var count = tagObj.count || 0;
            html += '<span style="display: inline-flex; align-items: center; gap: 4px; background: rgba(204,153,204,0.15); border: 1px solid rgba(204,153,204,0.3); border-radius: 12px; padding: 3px 10px; font-family: \'Antonio\', sans-serif; font-size: 12px;">' +
                '<span style="color: #FFCC99;">' + tag + '</span>' +
                '<span style="color: #CC99CC; font-weight: 600;">' + count + '</span>' +
                '</span>';
        });
        html += '</div>';

        container.innerHTML = html;
    }

    // -------------------------------------------------------------------------
    // Core: init & refresh
    // -------------------------------------------------------------------------

    async function init() {
        if (typeof LCARSCharts !== 'undefined') {
            LCARSCharts.init();
        }

        await refresh();
        initialized = true;
    }

    async function refresh() {
        var data = await fetchKnowledgeStats();

        if (!data) {
            _showErrorState();
            return;
        }

        lastData = data;

        var allTeams = data.teams || {};
        var teams = filterTeamsByDivision(allTeams);
        var overall = data.overall || {};

        // Recompute overall from filtered teams if division filter is active
        if (activeDivisions && activeDivisions.length > 0) {
            overall = _computeOverallFromFilteredTeams(teams);
        }

        try { renderOverallMetrics(overall); }
        catch (e) { console.error('[LCARSAnalyticsKnowledge] renderOverallMetrics error:', e); }

        // Charts are rendered lazily — only when the knowledge page is active.
        // Chart.js on an off-screen canvas (left: -9999px) produces zero-dimension
        // instances that never repaint.  _ensureChartsRendered() handles creation
        // via requestAnimationFrame after the page becomes visible.
        _ensureChartsRendered();

        try { renderRecentEntries(overall.recentEntries || []); }
        catch (e) { console.error('[LCARSAnalyticsKnowledge] renderRecentEntries error:', e); }

        try { renderTopTags(overall.topTags || []); }
        catch (e) { console.error('[LCARSAnalyticsKnowledge] renderTopTags error:', e); }

        // Dispatch knowledge data ready event for team pages module
        document.dispatchEvent(new CustomEvent('lcars:knowledgeDataReady', {
            detail: { teams: teams, overall: overall }
        }));

        console.log('[LCARSAnalyticsKnowledge] Rendered. Teams:', Object.keys(teams).length,
            'Total entries:', overall.totalEntries || 0);
    }

    /**
     * Recompute overall stats from a filtered subset of teams.
     */
    function _computeOverallFromFilteredTeams(teams) {
        var totalEntries = 0;
        var totalContributingAgents = 0;
        var teamsWithEntries = 0;
        var categories = {};
        var tags = {};
        var recentEntries = [];

        Object.values(teams).forEach(function (t) {
            totalEntries += t.totalEntries || 0;
            totalContributingAgents += t.contributingAgents || 0;
            if ((t.totalEntries || 0) > 0) teamsWithEntries++;

            if (t.categories) {
                Object.entries(t.categories).forEach(function (pair) {
                    categories[pair[0]] = (categories[pair[0]] || 0) + pair[1];
                });
            }
            if (t.tags) {
                Object.entries(t.tags).forEach(function (pair) {
                    tags[pair[0]] = (tags[pair[0]] || 0) + pair[1];
                });
            }
            if (t.recentEntries) {
                t.recentEntries.forEach(function (entry) {
                    recentEntries.push(entry);
                });
            }
        });

        recentEntries.sort(function (a, b) { return (b.date || '').localeCompare(a.date || ''); });

        var topTags = Object.entries(tags)
            .sort(function (a, b) { return b[1] - a[1]; })
            .slice(0, 20)
            .map(function (pair) { return { tag: pair[0], count: pair[1] }; });

        return {
            totalEntries: totalEntries,
            teamsWithEntries: teamsWithEntries,
            totalContributingAgents: totalContributingAgents,
            categories: categories,
            uniqueCategories: Object.keys(categories).length,
            topTags: topTags,
            uniqueTags: Object.keys(tags).length,
            recentEntries: recentEntries.slice(0, 10)
        };
    }

    /**
     * Render charts only when the knowledge page is the active analytics page.
     * Chart.js instances created on off-screen canvases (position: absolute;
     * left: -9999px) get zero dimensions and never repaint when the page
     * becomes visible.  This gates chart creation behind a visibility check
     * and uses requestAnimationFrame to ensure the DOM has updated.
     */
    function _ensureChartsRendered() {
        if (!lastData) return;
        if (currentAnalyticsPage !== 'knowledge') return;

        requestAnimationFrame(function () {
            // Destroy stale instances that may have been created off-screen
            if (charts.categoryDoughnut) {
                charts.categoryDoughnut.destroy();
                charts.categoryDoughnut = null;
            }
            if (charts.teamBar) {
                charts.teamBar.destroy();
                charts.teamBar = null;
            }

            var teams = filterTeamsByDivision(lastData.teams || {});
            var overall = lastData.overall || {};
            if (activeDivisions && activeDivisions.length > 0) {
                overall = _computeOverallFromFilteredTeams(teams);
            }

            try { renderCategoryDoughnut(overall); }
            catch (err) { console.error('[LCARSAnalyticsKnowledge] Chart render error:', err); }

            try { renderTeamBar(teams); }
            catch (err) { console.error('[LCARSAnalyticsKnowledge] Chart render error:', err); }
        });
    }

    function destroy() {
        if (charts.categoryDoughnut) { charts.categoryDoughnut.destroy(); charts.categoryDoughnut = null; }
        if (charts.teamBar)          { charts.teamBar.destroy();          charts.teamBar = null; }
        initialized = false;
        lastData = null;
        console.log('[LCARSAnalyticsKnowledge] Destroyed all chart instances');
    }

    function _showErrorState() {
        var ids = ['knowledge-overall-metrics', 'knowledge-recent-entries', 'knowledge-top-tags'];
        var errorHtml = '<div style="color: #CC6666; font-family: \'Antonio\', sans-serif; padding: 10px; font-size: 12px;">KNOWLEDGE DATA UNAVAILABLE</div>';
        ids.forEach(function (id) {
            var el = document.getElementById(id);
            if (el) el.innerHTML = errorHtml;
        });
    }

    // -------------------------------------------------------------------------
    // Event listeners — section & page change
    // -------------------------------------------------------------------------

    document.addEventListener('DOMContentLoaded', function () {
        // Initialize when analytics section becomes active
        document.addEventListener('lcars:sectionChange', function (e) {
            if (e.detail && e.detail.section === 'analytics') {
                if (!initialized) {
                    console.log('[LCARSAnalyticsKnowledge] Analytics section activated — initializing...');
                    init();
                }
            }
        });

        // Fallback: if analytics section is already active on load
        var analyticsSection = document.querySelector('.lcars-section[data-section="analytics"]');
        if (analyticsSection && analyticsSection.classList.contains('active')) {
            console.log('[LCARSAnalyticsKnowledge] Analytics already active on load — initializing...');
            init();
        }

        // Track active analytics page; render charts lazily when knowledge
        // page becomes visible.  No `initialized` guard — data may arrive
        // after the page change event, and _ensureChartsRendered handles that.
        document.addEventListener('lcars:analyticsPageChange', function (e) {
            currentAnalyticsPage = (e.detail && e.detail.page) || null;
            if (currentAnalyticsPage === 'knowledge') {
                _ensureChartsRendered();
            }
        });
    });

    // -------------------------------------------------------------------------
    // Public API
    // -------------------------------------------------------------------------

    return {
        init:    init,
        refresh: refresh,
        destroy: destroy,
        getLastData: function () { return lastData; },
        setDivisions: function (divisions) {
            activeDivisions = (divisions && divisions.length > 0) ? divisions : null;
        }
    };

}());
