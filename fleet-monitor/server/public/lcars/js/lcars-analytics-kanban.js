//
//  lcars-analytics-kanban.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

/**
 * lcars-analytics-kanban.js
 * LCARS Analytics - Kanban Data Charts
 *
 * Fetches kanban board statistics from /api/kanban-stats and renders
 * all kanban-related charts and metrics into the ANALYTICS section:
 *
 *   - Overall summary metric cards  (#analytics-overall-metrics)
 *   - Combined status doughnut      (#analytics-combined-doughnut)
 *   - Team comparison bar chart     (#analytics-team-comparison-bar)
 *   - Per-team analytics cards      (#analytics-team-cards)
 *   - Epic progress bars            (#analytics-all-epics)
 *   - Division summary cards        (#analytics-division-summary)
 *
 * NOTE: #analytics-session-line is intentionally NOT touched here.
 *       That canvas is managed by a separate module.
 *
 * Requires: Chart.js 4.x, LCARSCharts (loaded before this script)
 */

/* global LCARSCharts, Chart */

// Assign to window — const/let don't create window properties.
window.LCARSAnalyticsKanban = (function () {
    'use strict';

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    // Chart instances — kept so we can update them on refresh without recreating
    const charts = {
        combinedDoughnut: null,
        teamComparisonBar: null,
        teamDoughnuts: {}   // keyed by teamId
    };

    let lastData = null;    // Most recent API response for reference
    let initialized = false;

    /** Dashboard division filter — set via setDivisions(). null = show all. */
    let activeDivisions = null;

    // -------------------------------------------------------------------------
    // Team color palette — one distinct LCARS color per team slot
    // Cycles if more than 8 teams are present.
    // -------------------------------------------------------------------------

    const TEAM_COLORS = [
        '#99CCFF',  // cyan
        '#FFCC99',  // tan
        '#CC99CC',  // purple
        '#99CC99',  // green
        '#FF9900',  // orange
        '#9999CC',  // blue
        '#FFFF99',  // yellow
        '#CC6666',  // red
    ];

    function teamColor(index) {
        return TEAM_COLORS[index % TEAM_COLORS.length];
    }

    // -------------------------------------------------------------------------
    // Division mapping — maps team IDs to dashboard division IDs
    // Used for both display grouping and dashboard filtering.
    // Dashboard configs (dashboards.json) use IDs like "mainevent", "academy".
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
        const id = teamId.toLowerCase();
        if (id.startsWith('freelance')) return id;
        if (id.startsWith('legal'))     return 'legal';
        if (id.startsWith('medical'))   return 'medical';
        return DIVISION_MAP[id] || id;
    }

    /** Legacy display-name grouping (used by renderDivisionSummary) */
    const DIVISION_DISPLAY = {
        academy: 'DEVTEAM', mainevent: 'MAIN EVENT',
        dns: 'DOUBLENODE', legal: 'LEGAL', medical: 'MEDICAL'
    };

    function getDivisionGroup(teamId) {
        const div = getTeamDivision(teamId);
        return DIVISION_DISPLAY[div] || div.toUpperCase();
    }

    /**
     * Filter a teams object to only include teams matching activeDivisions.
     * Returns a new object. If activeDivisions is null, returns all teams.
     */
    function filterTeamsByDivision(teams) {
        if (!activeDivisions || activeDivisions.length === 0) return teams;
        var filtered = {};
        Object.keys(teams).forEach(function (key) {
            var team = teams[key];
            if (team.error) return;
            var teamId = (team.teamId || key).toLowerCase();
            // Match either: direct team ID in divisions OR mapped division group.
            // Dashboard configs may contain team IDs ("android") or group IDs ("mainevent").
            if (activeDivisions.indexOf(teamId) !== -1 ||
                activeDivisions.indexOf(getTeamDivision(teamId)) !== -1) {
                filtered[key] = team;
            }
        });
        return filtered;
    }

    /**
     * Compute an "overall" aggregate from a filtered set of teams.
     * Mirrors the structure the API returns in data.overall.
     */
    function computeOverallFromTeams(teams) {
        var totalItems = 0, totalCompleted = 0, validTeams = 0;
        var statusCounts = {};

        Object.values(teams).forEach(function (team) {
            if (team.error) return;
            validTeams++;
            totalItems += (team.totalItems || 0);
            var sc = team.statusCounts || {};
            Object.keys(sc).forEach(function (status) {
                statusCounts[status] = (statusCounts[status] || 0) + sc[status];
            });
        });

        totalCompleted = statusCounts.completed || 0;
        var rate = totalItems > 0 ? Math.round((totalCompleted / totalItems) * 100) : 0;

        return {
            totalItems: totalItems,
            totalCompleted: totalCompleted,
            overallCompletionRate: rate,
            validTeams: validTeams,
            totalTeams: validTeams,
            statusCounts: statusCounts
        };
    }

    // -------------------------------------------------------------------------
    // Data fetch
    // -------------------------------------------------------------------------

    async function fetchKanbanStats() {
        try {
            const response = await fetch('/api/kanban-stats');
            if (!response.ok) {
                throw new Error('HTTP ' + response.status + ': ' + response.statusText);
            }
            return await response.json();
        } catch (error) {
            console.error('[LCARSAnalyticsKanban] Failed to fetch kanban stats:', error);
            return null;
        }
    }

    // -------------------------------------------------------------------------
    // Render: Overall summary metrics
    // -------------------------------------------------------------------------

    function renderOverallMetrics(overall) {
        const container = document.getElementById('analytics-overall-metrics');
        if (!container) return;

        if (!overall) {
            container.innerHTML = '<div style="color: #CC6666; font-family: \'Antonio\', sans-serif; padding: 10px;">NO DATA AVAILABLE</div>';
            return;
        }

        // Derive in-progress count from statusCounts
        const sc = overall.statusCounts || {};
        const inProgress = (sc.in_progress || 0) + (sc.coding || 0) + (sc.planning || 0) + (sc.review || 0);

        // Note on label distinction:
        //   'IN PROGRESS' = count of items currently in an active work status
        //                   (in_progress + coding + planning + review).
        //   'ACTIVE TEAMS' = count of teams that have valid/responding data feeds.
        //   These are different metrics and intentionally use different labels.
        const metrics = [
            { label: 'TOTAL ITEMS',    value: overall.totalItems || 0,        color: '#99CCFF' },
            { label: 'COMPLETED',      value: overall.totalCompleted || 0,     color: '#99CC99' },
            { label: 'IN PROGRESS',    value: inProgress,                      color: '#FF9900' },
            { label: 'COMPLETION RATE',value: (overall.overallCompletionRate || 0) + '%', color: '#CC99CC' },
            { label: 'ACTIVE TEAMS',   value: overall.validTeams || overall.totalTeams || 0, color: '#FFCC99' },
        ];

        container.innerHTML = metrics.map(function (m) {
            return '<div class="summary-card lcars-fade-in-up" style="background: rgba(0,0,0,0.3); border-radius: 8px; padding: 12px; text-align: center;">' +
                '<div class="summary-value" style="color: ' + m.color + '; font-family: \'Antonio\', sans-serif; font-size: 28px; font-weight: 600;">' + m.value + '</div>' +
                '<div class="summary-label" style="color: rgba(255,204,153,0.7); font-family: \'Antonio\', sans-serif; font-size: 11px; margin-top: 4px; letter-spacing: 0.05em;">' + m.label + '</div>' +
                '</div>';
        }).join('');
    }

    // -------------------------------------------------------------------------
    // Render: Combined status doughnut
    // -------------------------------------------------------------------------

    function renderCombinedDoughnut(overall) {
        const canvasId = 'analytics-combined-doughnut';
        const canvas = document.getElementById(canvasId);
        if (!canvas) return;

        const sc = overall ? (overall.statusCounts || {}) : {};
        const statusOrder = ['completed', 'in_progress', 'todo', 'backlog', 'review', 'cancelled', 'blocked', 'paused', 'coding', 'planning', 'testing'];
        const labels = [];
        const values = [];
        const colors = [];

        statusOrder.forEach(function (status) {
            if (sc[status] && sc[status] > 0) {
                labels.push(status.replace(/_/g, ' ').toUpperCase());
                values.push(sc[status]);
                colors.push(LCARSCharts.statusColors[status] || LCARSCharts.colors.tan);
            }
        });

        // Include any statuses not in our predefined order
        Object.keys(sc).forEach(function (status) {
            if (statusOrder.indexOf(status) === -1 && sc[status] > 0) {
                labels.push(status.replace(/_/g, ' ').toUpperCase());
                values.push(sc[status]);
                colors.push(LCARSCharts.statusColors[status] || LCARSCharts.colors.tan);
            }
        });

        const chartData = {
            labels: labels,
            datasets: [{
                data: values,
                backgroundColor: colors,
                borderColor: LCARSCharts.colors.background,
                borderWidth: 2,
                hoverBorderColor: LCARSCharts.colors.tan,
                hoverBorderWidth: 3,
            }]
        };

        // Total items center text plugin — scoped to this chart instance only.
        // Do NOT use Chart.register() which would apply the plugin globally to all charts.
        // Instead, pass it via the chart-level 'plugins' array so it only runs on this canvas.
        const totalItems = overall ? (overall.totalItems || 0) : 0;
        const centerTextPlugin = {
            id: 'kanbanCenterText',
            afterDraw: function (chart) {
                const ctx = chart.ctx;
                const area = chart.chartArea;
                const centerX = (area.left + area.right) / 2;
                const centerY = (area.top + area.bottom) / 2;
                ctx.save();
                ctx.font = '600 22px "Antonio", sans-serif';
                ctx.fillStyle = LCARSCharts.colors.tan;
                ctx.textAlign = 'center';
                ctx.textBaseline = 'middle';
                ctx.fillText(totalItems, centerX, centerY - 8);
                ctx.font = '400 11px "Antonio", sans-serif';
                ctx.fillStyle = LCARSCharts.colors.textDim;
                ctx.fillText('TOTAL', centerX, centerY + 10);
                ctx.restore();
            }
        };

        if (charts.combinedDoughnut) {
            // Update data and refresh the center text by replacing the per-chart plugin
            // so the new totalItems value is reflected on next draw.
            LCARSCharts.updateChart(charts.combinedDoughnut, chartData);
            // Replace the stored plugin so the updated closure is used on the next draw
            const pluginIdx = charts.combinedDoughnut.config.plugins
                ? charts.combinedDoughnut.config.plugins.findIndex(function (p) { return p.id === 'kanbanCenterText'; })
                : -1;
            if (pluginIdx !== -1) {
                charts.combinedDoughnut.config.plugins[pluginIdx] = centerTextPlugin;
            }
            charts.combinedDoughnut.update();
        } else {
            charts.combinedDoughnut = LCARSCharts.createDoughnut(canvasId, chartData, {
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
                            pointStyle: 'rectRounded',
                        }
                    }
                }
            });

            // Manually attach the plugin to this chart instance's plugin list
            // (Chart.js 4.x allows per-chart plugins via chart.config.plugins array)
            if (charts.combinedDoughnut) {
                if (!charts.combinedDoughnut.config.plugins) {
                    charts.combinedDoughnut.config.plugins = [];
                }
                charts.combinedDoughnut.config.plugins.push(centerTextPlugin);
                charts.combinedDoughnut.update();
            }
        }
    }

    // -------------------------------------------------------------------------
    // Render: Team comparison bar chart
    // -------------------------------------------------------------------------

    function renderTeamComparisonBar(teams) {
        const canvasId = 'analytics-team-comparison-bar';
        const canvas = document.getElementById(canvasId);
        if (!canvas) return;

        if (!teams || Object.keys(teams).length === 0) return;

        // Sort teams by total items descending
        const sortedTeams = Object.values(teams)
            .filter(function (t) { return !t.error; })
            .sort(function (a, b) { return (b.totalItems || 0) - (a.totalItems || 0); });

        const labels = sortedTeams.map(function (t) {
            return (t.displayName || t.teamId || 'UNKNOWN').toUpperCase();
        });

        const totalData = sortedTeams.map(function (t) { return t.totalItems || 0; });
        const completedData = sortedTeams.map(function (t) {
            return (t.statusCounts && t.statusCounts.completed) || 0;
        });
        const inProgressData = sortedTeams.map(function (t) {
            const sc = t.statusCounts || {};
            return (sc.in_progress || 0) + (sc.coding || 0) + (sc.planning || 0);
        });

        const chartData = {
            labels: labels,
            datasets: [
                {
                    label: 'TOTAL',
                    data: totalData,
                    backgroundColor: 'rgba(153, 204, 255, 0.6)',
                    borderColor: '#99CCFF',
                    borderWidth: 1,
                    borderRadius: 4,
                    borderSkipped: false,
                },
                {
                    label: 'COMPLETED',
                    data: completedData,
                    backgroundColor: 'rgba(153, 204, 153, 0.75)',
                    borderColor: '#99CC99',
                    borderWidth: 1,
                    borderRadius: 4,
                    borderSkipped: false,
                },
                {
                    label: 'IN PROGRESS',
                    data: inProgressData,
                    backgroundColor: 'rgba(255, 153, 0, 0.6)',
                    borderColor: '#FF9900',
                    borderWidth: 1,
                    borderRadius: 4,
                    borderSkipped: false,
                }
            ]
        };

        if (charts.teamComparisonBar) {
            LCARSCharts.updateChart(charts.teamComparisonBar, chartData);
        } else {
            charts.teamComparisonBar = LCARSCharts.createBar(canvasId, chartData, {
                indexAxis: 'y',  // Horizontal bars — fits team names better
                plugins: {
                    legend: {
                        display: true,
                        position: 'top',
                        labels: {
                            color: LCARSCharts.colors.text,
                            font: { family: "'Antonio', sans-serif", size: 11 },
                            padding: 10,
                            boxWidth: 10,
                            boxHeight: 10,
                        }
                    }
                },
                scales: {
                    x: {
                        grid: { color: LCARSCharts.colors.gridLine },
                        ticks: {
                            color: LCARSCharts.colors.textDim,
                            font: { family: "'Antonio', sans-serif", size: 10 },
                        },
                        beginAtZero: true,
                    },
                    y: {
                        grid: { display: false },
                        ticks: {
                            color: LCARSCharts.colors.text,
                            font: { family: "'Antonio', sans-serif", size: 11 },
                        },
                    }
                }
            });
        }
    }

    // -------------------------------------------------------------------------
    // Render: Per-team analytics cards
    // -------------------------------------------------------------------------

    function renderTeamCards(teams) {
        const container = document.getElementById('analytics-team-cards');
        if (!container) return;

        if (!teams || Object.keys(teams).length === 0) {
            container.innerHTML = '<div style="color: #FFCC99; font-family: \'Antonio\', sans-serif; padding: 20px;">NO TEAM DATA AVAILABLE</div>';
            return;
        }

        // Sort teams by total items descending
        const sortedTeams = Object.values(teams)
            .filter(function (t) { return !t.error; })
            .sort(function (a, b) { return (b.totalItems || 0) - (a.totalItems || 0); });

        // Clear stale mini-doughnut instances
        Object.keys(charts.teamDoughnuts).forEach(function (id) {
            if (charts.teamDoughnuts[id]) {
                charts.teamDoughnuts[id].destroy();
                delete charts.teamDoughnuts[id];
            }
        });

        container.innerHTML = sortedTeams.map(function (team, idx) {
            const color = teamColor(idx);
            const sc = team.statusCounts || {};
            const totalItems = team.totalItems || 0;
            const completed = sc.completed || 0;
            const todo = sc.todo || 0;
            const rate = team.completionRate || 0;
            const inProgress = (sc.in_progress || 0) + (sc.coding || 0) + (sc.planning || 0);
            const recent = team.recentActivity || {};
            const subitems = team.subitemStats || {};

            const teamId = team.teamId || 'unknown';
            const canvasId = 'team-doughnut-' + teamId;
            const displayName = (team.displayName || teamId).toUpperCase();

            return '<div class="analytics-team-card" style="background: rgba(0,0,0,0.3); border-radius: 8px; padding: 15px; border-left: 3px solid ' + color + ';">' +
                '<div style="color: ' + color + '; font-family: \'Antonio\', sans-serif; font-size: 16px; font-weight: 600; margin-bottom: 12px; letter-spacing: 0.05em;">' + displayName + '</div>' +
                '<div style="display: grid; grid-template-columns: 1fr 1fr; gap: 8px; margin-bottom: 12px;">' +
                    _metricCell(totalItems, 'TOTAL', '#99CCFF') +
                    _metricCell(completed, 'DONE', '#99CC99') +
                    _metricCell(todo, 'TODO', '#FF9900') +
                    _metricCell(rate + '%', 'RATE', '#CC99CC') +
                '</div>' +
                '<div style="display: grid; grid-template-columns: 1fr 1fr; gap: 8px; margin-bottom: 12px;">' +
                    _metricCell(inProgress, 'IN PROGRESS', '#FFCC99') +
                    _metricCell(recent.completedLast7Days || 0, 'DONE/7D', '#99CC99') +
                    _metricCell(subitems.total || 0, 'SUBITEMS', '#9999CC') +
                    _metricCell(subitems.pending || 0, 'PENDING', '#FFFF99') +
                '</div>' +
                '<canvas id="' + canvasId + '" width="160" height="160"></canvas>' +
                '</div>';
        }).join('');

        // Render mini doughnuts for each team card
        sortedTeams.forEach(function (team) {
            const teamId = team.teamId || 'unknown';
            const canvasId = 'team-doughnut-' + teamId;
            const sc = team.statusCounts || {};

            const statusOrder = ['completed', 'in_progress', 'coding', 'planning', 'todo', 'review', 'backlog', 'cancelled', 'blocked'];
            const labels = [];
            const values = [];
            const colors = [];

            statusOrder.forEach(function (status) {
                if (sc[status] && sc[status] > 0) {
                    labels.push(status.replace(/_/g, ' ').toUpperCase());
                    values.push(sc[status]);
                    colors.push(LCARSCharts.statusColors[status] || LCARSCharts.colors.tan);
                }
            });

            // Catch any remaining statuses not in our order
            Object.keys(sc).forEach(function (status) {
                if (statusOrder.indexOf(status) === -1 && sc[status] > 0) {
                    labels.push(status.replace(/_/g, ' ').toUpperCase());
                    values.push(sc[status]);
                    colors.push(LCARSCharts.statusColors[status] || LCARSCharts.colors.tan);
                }
            });

            if (labels.length === 0) return; // No data for this team

            const miniData = {
                labels: labels,
                datasets: [{
                    data: values,
                    backgroundColor: colors,
                    borderColor: LCARSCharts.colors.background,
                    borderWidth: 1,
                    hoverBorderColor: LCARSCharts.colors.tan,
                    hoverBorderWidth: 2,
                }]
            };

            charts.teamDoughnuts[teamId] = LCARSCharts.createDoughnut(canvasId, miniData, {
                cutout: '60%',
                plugins: {
                    legend: {
                        display: true,
                        position: 'bottom',
                        labels: {
                            color: LCARSCharts.colors.textDim,
                            font: { family: "'Antonio', sans-serif", size: 10 },
                            padding: 6,
                            boxWidth: 8,
                            boxHeight: 8,
                            usePointStyle: true,
                            pointStyle: 'rectRounded',
                        }
                    },
                    tooltip: {
                        callbacks: {
                            label: function (ctx) {
                                return ' ' + ctx.label + ': ' + ctx.parsed;
                            }
                        }
                    }
                },
                animation: { duration: 800, easing: 'easeInOutQuart' }
            });
        });
    }

    // Helper: one metric cell for the team card grid
    function _metricCell(value, label, color) {
        return '<div style="text-align: center;">' +
            '<span style="color: ' + color + '; font-family: \'Antonio\', sans-serif; font-size: 20px; font-weight: 600;">' + value + '</span>' +
            '<br><span style="color: rgba(153,153,153,0.8); font-family: \'Antonio\', sans-serif; font-size: 10px; letter-spacing: 0.05em;">' + label + '</span>' +
            '</div>';
    }

    // -------------------------------------------------------------------------
    // Render: Epic progress bars (all teams)
    // -------------------------------------------------------------------------

    function renderEpicProgress(teams) {
        const container = document.getElementById('analytics-all-epics');
        if (!container) return;

        if (!teams || Object.keys(teams).length === 0) {
            container.innerHTML = '<div style="color: #FFCC99; font-family: \'Antonio\', sans-serif; padding: 10px;">NO EPIC DATA AVAILABLE</div>';
            return;
        }

        const sortedTeams = Object.values(teams)
            .filter(function (t) { return !t.error && t.epics && t.epics.length > 0; })
            .sort(function (a, b) { return (b.totalItems || 0) - (a.totalItems || 0); });

        if (sortedTeams.length === 0) {
            container.innerHTML = '<div style="color: rgba(255,204,153,0.6); font-family: \'Antonio\', sans-serif; padding: 10px; font-size: 13px;">NO EPICS DEFINED ACROSS ANY TEAM</div>';
            return;
        }

        const html = sortedTeams.map(function (team, teamIdx) {
            const color = teamColor(teamIdx);
            const displayName = (team.displayName || team.teamId || 'UNKNOWN').toUpperCase();

            const epicBars = team.epics.map(function (epic) {
                const progress = Math.min(100, Math.max(0, epic.progress || 0));
                const totalItems = epic.totalItems || 0;
                const completedItems = epic.completedItems || 0;
                const epicName = (epic.name || 'Unnamed Epic').toUpperCase();

                // Gradient color based on progress
                const barColor = progress >= 80 ? '#99CC99'
                    : progress >= 40 ? '#FFCC99'
                    : '#9999CC';

                return '<div style="margin-bottom: 10px;">' +
                    '<div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 3px;">' +
                        '<span style="color: #FFCC99; font-family: \'Antonio\', sans-serif; font-size: 12px; flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; padding-right: 8px;">' + epicName + '</span>' +
                        '<span style="color: rgba(255,204,153,0.7); font-family: \'Antonio\', sans-serif; font-size: 11px; white-space: nowrap;">' +
                            completedItems + '/' + totalItems + ' — ' + progress + '%' +
                        '</span>' +
                    '</div>' +
                    '<div style="background: rgba(255,255,255,0.08); border-radius: 4px; height: 10px; overflow: hidden;">' +
                        '<div class="lcars-epic-bar" data-progress="' + progress + '" style="background: linear-gradient(90deg, ' + barColor + ', rgba(' + _hexToRgb(barColor) + ',0.6)); height: 100%; width: 0%; border-radius: 4px; transition: width 1.2s ease;"></div>' +
                    '</div>' +
                    '</div>';
            }).join('');

            return '<div style="background: rgba(0,0,0,0.2); border-radius: 6px; padding: 14px; border-left: 3px solid ' + color + ';">' +
                '<div style="color: ' + color + '; font-family: \'Antonio\', sans-serif; font-size: 13px; font-weight: 600; margin-bottom: 10px; letter-spacing: 0.08em;">' + displayName + '</div>' +
                epicBars +
                '</div>';
        }).join('');

        container.innerHTML = html;

        // Animate bars after a short delay to allow the browser to paint the 0% state first
        setTimeout(function () {
            container.querySelectorAll('.lcars-epic-bar').forEach(function (bar) {
                const progress = bar.getAttribute('data-progress');
                if (progress !== null) {
                    bar.style.width = progress + '%';
                }
            });
        }, 80);
    }

    // Helper: convert hex color to "r, g, b" string for rgba()
    function _hexToRgb(hex) {
        const r = parseInt(hex.slice(1, 3), 16);
        const g = parseInt(hex.slice(3, 5), 16);
        const b = parseInt(hex.slice(5, 7), 16);
        return r + ', ' + g + ', ' + b;
    }

    // -------------------------------------------------------------------------
    // Render: Division summary cards
    // -------------------------------------------------------------------------

    function renderDivisionSummary(teams) {
        const container = document.getElementById('analytics-division-summary');
        if (!container) return;

        if (!teams || Object.keys(teams).length === 0) {
            container.innerHTML = '<div style="color: #FFCC99; font-family: \'Antonio\', sans-serif; padding: 10px;">NO DIVISION DATA</div>';
            return;
        }

        // Group valid teams by division
        const divisions = {};
        Object.values(teams)
            .filter(function (t) { return !t.error; })
            .forEach(function (team) {
                const div = getDivisionGroup(team.teamId || '');
                if (!divisions[div]) {
                    divisions[div] = { totalItems: 0, totalCompleted: 0, teamCount: 0, teams: [] };
                }
                divisions[div].totalItems += team.totalItems || 0;
                divisions[div].totalCompleted += (team.statusCounts && team.statusCounts.completed) || 0;
                divisions[div].teamCount += 1;
                divisions[div].teams.push(team.displayName || team.teamId || 'Unknown');
            });

        // Division accent colors
        const DIVISION_COLORS = {
            'DEVTEAM':    '#99CCFF',
            'MAIN EVENT': '#FF9900',
            'DOUBLENODE': '#CC99CC',
            'LEGAL':      '#FFCC99',
            'MEDICAL':    '#99CC99',
            'OTHER':      '#9999CC',
        };

        const html = Object.keys(divisions)
            .sort()
            .map(function (divName) {
                const d = divisions[divName];
                const rate = d.totalItems > 0 ? Math.round((d.totalCompleted / d.totalItems) * 1000) / 10 : 0;
                const color = DIVISION_COLORS[divName] || '#FFCC99';
                const teamList = d.teams.join(', ');

                return '<div style="background: rgba(0,0,0,0.3); border-radius: 8px; padding: 14px; border-top: 3px solid ' + color + ';">' +
                    '<div style="color: ' + color + '; font-family: \'Antonio\', sans-serif; font-size: 15px; font-weight: 600; margin-bottom: 10px; letter-spacing: 0.05em;">' + divName + '</div>' +
                    '<div style="display: grid; grid-template-columns: 1fr 1fr; gap: 8px; margin-bottom: 10px;">' +
                        _metricCell(d.totalItems, 'TOTAL', '#99CCFF') +
                        _metricCell(d.totalCompleted, 'DONE', '#99CC99') +
                        _metricCell(rate + '%', 'RATE', '#CC99CC') +
                        _metricCell(d.teamCount, 'TEAMS', '#FFCC99') +
                    '</div>' +
                    '<div style="color: rgba(153,153,153,0.7); font-family: \'Antonio\', sans-serif; font-size: 10px; border-top: 1px solid rgba(255,255,255,0.08); padding-top: 8px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">' +
                        teamList +
                    '</div>' +
                    '</div>';
            }).join('');

        container.innerHTML = html;
    }

    // -------------------------------------------------------------------------
    // Core: init & refresh
    // -------------------------------------------------------------------------

    /**
     * Initialize the analytics module.
     * Fetches data and renders all kanban charts.
     * Safe to call multiple times — will refresh data if already initialized.
     */
    async function init() {
        // Ensure LCARSCharts is initialized (idempotent)
        if (typeof LCARSCharts !== 'undefined') {
            LCARSCharts.init();
        } else {
            console.warn('[LCARSAnalyticsKanban] LCARSCharts not available — charts may not render correctly');
        }

        await refresh();
        initialized = true;
    }

    /**
     * Refresh all kanban analytics by re-fetching from the API.
     */
    async function refresh() {
        const data = await fetchKanbanStats();

        if (!data) {
            // Show an error state in the containers
            _showErrorState();
            return;
        }

        lastData = data;

        const allTeams = data.teams || {};

        // Filter teams by dashboard divisions (if set)
        const teams = filterTeamsByDivision(allTeams);

        // Compute overview from filtered teams (not the API's global aggregate)
        const overall = computeOverallFromTeams(teams);

        // Render each section independently so one failure doesn't block others
        try { renderOverallMetrics(overall); }
        catch (e) { console.error('[LCARSAnalyticsKanban] renderOverallMetrics error:', e); }

        try { renderCombinedDoughnut(overall); }
        catch (e) { console.error('[LCARSAnalyticsKanban] renderCombinedDoughnut error:', e); }

        try { renderTeamComparisonBar(teams); }
        catch (e) { console.error('[LCARSAnalyticsKanban] renderTeamComparisonBar error:', e); }

        // Note: Per-team analytics cards (#analytics-team-cards) removed from HTML.
        // Individual team pages are now generated by LCARSAnalyticsPages.buildTeamPages().

        try { renderEpicProgress(teams); }
        catch (e) { console.error('[LCARSAnalyticsKanban] renderEpicProgress error:', e); }

        try { renderDivisionSummary(teams); }
        catch (e) { console.error('[LCARSAnalyticsKanban] renderDivisionSummary error:', e); }

        // Dispatch kanban data ready event for analytics pages module
        document.dispatchEvent(new CustomEvent('lcars:kanbanDataReady', {
            detail: { teams: teams, overall: overall }
        }));

        console.log('[LCARSAnalyticsKanban] Analytics rendered. Teams:', Object.keys(teams).length,
            'Total items:', overall ? overall.totalItems : 'N/A');
    }

    /**
     * Destroy all chart instances (for clean teardown if needed).
     */
    function destroy() {
        if (charts.combinedDoughnut)  { charts.combinedDoughnut.destroy();  charts.combinedDoughnut  = null; }
        if (charts.teamComparisonBar) { charts.teamComparisonBar.destroy(); charts.teamComparisonBar = null; }

        Object.keys(charts.teamDoughnuts).forEach(function (id) {
            if (charts.teamDoughnuts[id]) {
                charts.teamDoughnuts[id].destroy();
            }
        });
        charts.teamDoughnuts = {};
        initialized = false;
        lastData = null;
        console.log('[LCARSAnalyticsKanban] Destroyed all chart instances');
    }

    function _showErrorState() {
        const ids = [
            'analytics-overall-metrics',
            'analytics-team-cards',
            'analytics-all-epics',
            'analytics-division-summary'
        ];
        const errorHtml = '<div style="color: #CC6666; font-family: \'Antonio\', sans-serif; padding: 10px; font-size: 12px;">KANBAN DATA UNAVAILABLE</div>';
        ids.forEach(function (id) {
            const el = document.getElementById(id);
            if (el) el.innerHTML = errorHtml;
        });
    }

    // -------------------------------------------------------------------------
    // Section change listener — initialize when ANALYTICS becomes active
    // -------------------------------------------------------------------------

    document.addEventListener('DOMContentLoaded', function () {
        // Listen for section change events dispatched by lcars-fleet-core.js
        document.addEventListener('lcars:sectionChange', function (e) {
            if (e.detail && e.detail.section === 'analytics') {
                if (!initialized) {
                    console.log('[LCARSAnalyticsKanban] Analytics section activated — initializing...');
                    init();
                } else {
                    // Re-render epic bars in case they were reset (e.g. section hidden/shown)
                    // A full refresh on every section switch is intentionally avoided for perf;
                    // use the explicit refresh interval from the dashboard or call refresh() manually.
                    if (lastData && lastData.teams) {
                        try { renderEpicProgress(filterTeamsByDivision(lastData.teams)); }
                        catch (e) { console.warn('[LCARSAnalyticsKanban] Epic re-render on section switch failed:', e); }
                    }
                }
            }
        });

        // Fallback: if analytics section is already active on load (e.g. localStorage remembered it)
        const analyticsSection = document.querySelector('.lcars-section[data-section="analytics"]');
        if (analyticsSection && analyticsSection.classList.contains('active')) {
            console.log('[LCARSAnalyticsKanban] Analytics already active on load — initializing...');
            init();
        }

        // Recreate/resize charts when analytics page changes.
        // Charts created off-screen need destroy+recreate to render correctly.
        document.addEventListener('lcars:analyticsPageChange', function (e) {
            if (!initialized || !lastData) return;
            var page = e.detail && e.detail.page;
            requestAnimationFrame(function () {
                if (page === 'charts') {
                    // Destroy and recreate — Chart.js doesn't repaint content
                    // that was originally drawn at an off-screen position.
                    if (charts.teamComparisonBar) {
                        charts.teamComparisonBar.destroy();
                        charts.teamComparisonBar = null;
                    }
                    var teams = filterTeamsByDivision(lastData.teams || {});
                    try { renderTeamComparisonBar(teams); }
                    catch (err) { console.error('[LCARSAnalyticsKanban] Chart recreate error:', err); }
                }
                if (page === 'overview' && charts.combinedDoughnut) {
                    charts.combinedDoughnut.resize();
                }
                // Team pages — resize that team's doughnut if it exists
                if (page && page.startsWith('team-')) {
                    var teamId = page.replace('team-', '');
                    if (charts.teamDoughnuts[teamId]) {
                        charts.teamDoughnuts[teamId].resize();
                    }
                }
                if (page === 'epics' && lastData.teams) {
                    try { renderEpicProgress(filterTeamsByDivision(lastData.teams)); }
                    catch (err) { /* ignore */ }
                }
            });
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
        /** Set dashboard division filter. Call before init(). null = show all. */
        setDivisions: function (divisions) {
            activeDivisions = (divisions && divisions.length > 0) ? divisions : null;
        },
    };

}());
