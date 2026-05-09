//
//  lcars-analytics-fleet.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

/**
 * LCARS Analytics - Fleet & Session Charts
 * Renders session activity into the Fleet Monitor ANALYTICS section.
 *
 * Target canvas: #analytics-session-line
 *
 * Data source: GET /api/fleet
 *   Response: {
 *     fleet: {
 *       total_machines, online_machines, offline_machines, total_sessions,
 *       machines: [
 *         {
 *           machine_id, hostname, nickname, status, session_count, sessions,
 *           uptime_history: [ { timestamp, status, session_count }, ... ]
 *         }, ...
 *       ]
 *     }
 *   }
 *
 * The uptime_history array holds up to 48 entries, each with a session_count
 * snapshot at that timestamp. We aggregate across all machines per time bucket
 * to produce a "total active sessions over time" line chart.
 *
 * Requires: Chart.js 4.x, lcars-charts.js (LCARSCharts)
 */

/* global LCARSCharts */

// Assign to window — const/let don't create window properties.
window.LCARSAnalyticsFleet = (function () {
    'use strict';

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    /** @type {Chart|null} Chart.js instance for #analytics-session-line */
    let sessionChart = null;

    /** @type {object|null} Last successfully fetched fleet data */
    let lastData = null;

    /** @type {boolean} Whether this module has been initialized */
    let initialized = false;

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /** ID of the target canvas element */
    const SESSION_CANVAS_ID = 'analytics-session-line';

    /** Max time-bucket labels to show on the chart (avoids label crowding) */
    const MAX_LABELS = 24;

    /** LCARS color for the session line */
    const SESSION_COLOR = '#99CCFF'; // LCARSCharts.colors.cyan

    /** LCARS color for the online machine count line */
    const ONLINE_COLOR = '#99CC99'; // LCARSCharts.colors.green

    // -------------------------------------------------------------------------
    // Data fetching
    // -------------------------------------------------------------------------

    /**
     * Fetch current fleet data from the server.
     * @returns {Promise<object|null>} Parsed JSON or null on failure.
     */
    async function fetchFleetData() {
        try {
            const response = await fetch('/api/fleet');
            if (!response.ok) {
                console.error('[LCARSAnalyticsFleet] /api/fleet returned', response.status);
                return null;
            }
            return await response.json();
        } catch (err) {
            console.error('[LCARSAnalyticsFleet] Failed to fetch fleet data:', err);
            return null;
        }
    }

    // -------------------------------------------------------------------------
    // Data processing
    // -------------------------------------------------------------------------

    /**
     * Build chart datasets from fleet data.
     *
     * Strategy:
     *   1. Collect all uptime_history timestamps across all machines.
     *   2. Sort and bucket into MAX_LABELS time slots.
     *   3. For each bucket, sum session_counts from all machines that have
     *      a history entry near that time.
     *   4. Fall back to a single "current snapshot" point if no history exists.
     *
     * @param {object} fleetData - Response from /api/fleet.
     * @returns {{ labels: string[], sessionData: number[], onlineData: number[] }}
     */
    function processFleetData(fleetData) {
        const machines = (fleetData && fleetData.fleet && fleetData.fleet.machines) || [];

        // Gather all history entries across machines
        // Each entry: { timestamp, status, session_count, hostname }
        const allEntries = [];
        for (const machine of machines) {
            const history = machine.uptime_history || [];
            for (const entry of history) {
                if (entry.timestamp) {
                    allEntries.push({
                        ts: new Date(entry.timestamp).getTime(),
                        timestamp: entry.timestamp,
                        status: entry.status || 'online',
                        session_count: typeof entry.session_count === 'number' ? entry.session_count : 0,
                        machine_id: machine.machine_id
                    });
                }
            }
        }

        // If we have no history at all, fall back to current snapshot
        if (allEntries.length === 0) {
            return buildCurrentSnapshot(fleetData);
        }

        // Determine time range
        allEntries.sort(function (a, b) { return a.ts - b.ts; });
        const minTs = allEntries[0].ts;
        const maxTs = allEntries[allEntries.length - 1].ts;

        // Add the current state as a synthetic "now" entry for each machine
        const now = Date.now();
        for (const machine of machines) {
            allEntries.push({
                ts: now,
                status: machine.status || 'online',
                session_count: typeof machine.session_count === 'number' ? machine.session_count : 0,
                machine_id: machine.machine_id,
                isCurrent: true
            });
        }

        // Build time buckets
        const effectiveMax = Math.max(maxTs, now);
        const range = effectiveMax - minTs;
        const bucketSize = range > 0 ? range / Math.min(MAX_LABELS, allEntries.length) : 3600000;
        const numBuckets = Math.min(MAX_LABELS, Math.ceil(range / bucketSize) + 1);

        // For each bucket: aggregate session counts and online machine count
        // We want: total sessions = sum of session_count for machines that were online
        // in that bucket (using their most recent history entry <= bucket end time)
        const bucketLabels = [];
        const bucketSessions = [];
        const bucketOnline = [];

        for (let i = 0; i < numBuckets; i++) {
            const bucketStart = minTs + i * bucketSize;
            const bucketEnd = bucketStart + bucketSize;
            const bucketMid = (bucketStart + bucketEnd) / 2;

            // Label: show HH:MM
            bucketLabels.push(formatTime(new Date(bucketMid)));

            // For each machine, find the most recent history entry <= bucketEnd
            let totalSessions = 0;
            let onlineCount = 0;

            for (const machine of machines) {
                const history = machine.uptime_history || [];

                // Find best matching entry for this machine in this bucket
                // "best" = latest entry with ts <= bucketEnd
                let bestEntry = null;
                for (const entry of history) {
                    const entryTs = new Date(entry.timestamp).getTime();
                    if (entryTs <= bucketEnd) {
                        if (!bestEntry || entryTs > new Date(bestEntry.timestamp).getTime()) {
                            bestEntry = entry;
                        }
                    }
                }

                // If this bucket is close to "now", use current machine state
                if (bucketEnd >= now - bucketSize) {
                    bestEntry = {
                        status: machine.status || 'online',
                        session_count: typeof machine.session_count === 'number' ? machine.session_count : 0
                    };
                }

                if (bestEntry) {
                    if (bestEntry.status === 'online') {
                        totalSessions += bestEntry.session_count;
                        onlineCount++;
                    }
                }
            }

            bucketSessions.push(totalSessions);
            bucketOnline.push(onlineCount);
        }

        return {
            labels: bucketLabels,
            sessionData: bucketSessions,
            onlineData: bucketOnline
        };
    }

    /**
     * Build a simple current-state snapshot when no history is available.
     * Returns data for a single-point chart showing current session counts per machine.
     *
     * @param {object} fleetData
     * @returns {{ labels: string[], sessionData: number[], onlineData: number[] }}
     */
    function buildCurrentSnapshot(fleetData) {
        const machines = (fleetData && fleetData.fleet && fleetData.fleet.machines) || [];

        if (machines.length === 0) {
            return { labels: [], sessionData: [], onlineData: [] };
        }

        // Sort machines: online first, then by session count descending
        const sorted = machines.slice().sort(function (a, b) {
            if (a.status === 'online' && b.status !== 'online') return -1;
            if (a.status !== 'online' && b.status === 'online') return 1;
            return (b.session_count || 0) - (a.session_count || 0);
        });

        const labels = sorted.map(function (m) {
            return m.nickname || m.hostname || 'UNKNOWN';
        });

        const sessionData = sorted.map(function (m) {
            return m.status === 'online' ? (m.session_count || 0) : 0;
        });

        // onlineData: 1 = online, 0 = offline (for stacked view)
        const onlineData = sorted.map(function (m) {
            return m.status === 'online' ? 1 : 0;
        });

        return {
            labels: labels,
            sessionData: sessionData,
            onlineData: onlineData,
            isSnapshot: true
        };
    }

    // -------------------------------------------------------------------------
    // Formatting helpers
    // -------------------------------------------------------------------------

    /**
     * Format a Date object as HH:MM (24h).
     * @param {Date} date
     * @returns {string}
     */
    function formatTime(date) {
        const h = date.getHours().toString().padStart(2, '0');
        const m = date.getMinutes().toString().padStart(2, '0');
        return h + ':' + m;
    }

    // -------------------------------------------------------------------------
    // No-data display
    // -------------------------------------------------------------------------

    /**
     * Renders a "NO DATA" overlay on the canvas when fleet data is unavailable.
     * @param {string} message - Optional custom message.
     */
    function showNoData(message) {
        const canvas = document.getElementById(SESSION_CANVAS_ID);
        if (!canvas) return;

        const ctx = canvas.getContext('2d');
        const w = canvas.width || canvas.clientWidth || 300;
        const h = canvas.height || canvas.clientHeight || 200;

        // Set canvas dimensions if not set
        if (!canvas.width) canvas.width = w;
        if (!canvas.height) canvas.height = h;

        ctx.clearRect(0, 0, w, h);

        // Background
        ctx.fillStyle = 'rgba(0, 0, 0, 0.2)';
        ctx.fillRect(0, 0, w, h);

        // Decorative LCARS line
        ctx.strokeStyle = 'rgba(153, 204, 255, 0.3)';
        ctx.lineWidth = 1;
        ctx.beginPath();
        ctx.moveTo(w * 0.15, h / 2);
        ctx.lineTo(w * 0.85, h / 2);
        ctx.stroke();

        // Primary message
        ctx.fillStyle = SESSION_COLOR;
        ctx.font = "700 16px 'Antonio', sans-serif";
        ctx.textAlign = 'center';
        ctx.textBaseline = 'middle';
        ctx.fillText(message || 'NO DATA', w / 2, h / 2 - 12);

        // Secondary label
        ctx.fillStyle = 'rgba(153, 204, 255, 0.5)';
        ctx.font = "400 11px 'Antonio', sans-serif";
        ctx.fillText('AWAITING FLEET TELEMETRY', w / 2, h / 2 + 12);
    }

    // -------------------------------------------------------------------------
    // Chart rendering
    // -------------------------------------------------------------------------

    /**
     * Create or update the session activity line chart.
     * @param {{ labels, sessionData, onlineData, isSnapshot }} chartData
     */
    function renderSessionChart(chartData) {
        if (!chartData || chartData.labels.length === 0) {
            // Destroy existing chart if any, then show no-data
            if (sessionChart) {
                sessionChart.destroy();
                sessionChart = null;
            }
            showNoData('NO SESSION DATA');
            return;
        }

        const data = {
            labels: chartData.labels,
            datasets: [
                {
                    label: 'ACTIVE SESSIONS',
                    data: chartData.sessionData,
                    borderColor: SESSION_COLOR,
                    backgroundColor: 'rgba(153, 204, 255, 0.15)',
                    borderWidth: 2,
                    pointBackgroundColor: SESSION_COLOR,
                    pointBorderColor: '#0A0A1A',
                    pointBorderWidth: 2,
                    pointRadius: chartData.isSnapshot ? 5 : 3,
                    pointHoverRadius: 6,
                    tension: chartData.isSnapshot ? 0 : 0.35,
                    fill: true,
                    yAxisID: 'ySessions'
                },
                {
                    label: chartData.isSnapshot ? 'ONLINE' : 'MACHINES ONLINE',
                    data: chartData.onlineData,
                    borderColor: ONLINE_COLOR,
                    backgroundColor: 'rgba(153, 204, 153, 0.10)',
                    borderWidth: 1.5,
                    pointBackgroundColor: ONLINE_COLOR,
                    pointBorderColor: '#0A0A1A',
                    pointBorderWidth: 2,
                    pointRadius: chartData.isSnapshot ? 5 : 3,
                    pointHoverRadius: 5,
                    tension: chartData.isSnapshot ? 0 : 0.35,
                    fill: false,
                    yAxisID: 'yMachines'
                }
            ]
        };

        const options = {
            responsive: true,
            maintainAspectRatio: true,
            plugins: {
                legend: {
                    display: true,
                    labels: {
                        color: '#FFCC99',
                        font: { family: "'Antonio', sans-serif", size: 11 },
                        padding: 12,
                        boxWidth: 10,
                        boxHeight: 10,
                        usePointStyle: true,
                        pointStyle: 'circle'
                    }
                },
                tooltip: {
                    backgroundColor: 'rgba(10, 10, 26, 0.92)',
                    titleColor: '#FFCC99',
                    bodyColor: '#FFCC99',
                    borderColor: '#FFCC99',
                    borderWidth: 1,
                    cornerRadius: 8,
                    padding: 10,
                    titleFont: { family: "'Antonio', sans-serif", size: 12, weight: '600' },
                    bodyFont: { family: "'Antonio', sans-serif", size: 11 },
                    callbacks: {
                        title: function (items) {
                            return chartData.isSnapshot
                                ? 'MACHINE: ' + items[0].label
                                : 'TIME: ' + items[0].label;
                        },
                        label: function (item) {
                            if (item.datasetIndex === 0) {
                                return '  SESSIONS: ' + item.parsed.y;
                            }
                            if (chartData.isSnapshot) {
                                return '  STATUS: ' + (item.parsed.y > 0 ? 'ONLINE' : 'OFFLINE');
                            }
                            return '  ONLINE: ' + item.parsed.y + ' machines';
                        }
                    }
                }
            },
            scales: {
                x: {
                    grid: { color: 'rgba(255, 204, 153, 0.10)', lineWidth: 1 },
                    ticks: {
                        color: 'rgba(255, 204, 153, 0.55)',
                        font: { family: "'Antonio', sans-serif", size: 10 },
                        maxRotation: 0,
                        autoSkip: true,
                        maxTicksLimit: 8
                    }
                },
                ySessions: {
                    type: 'linear',
                    position: 'left',
                    grid: { color: 'rgba(255, 204, 153, 0.10)', lineWidth: 1 },
                    ticks: {
                        color: SESSION_COLOR,
                        font: { family: "'Antonio', sans-serif", size: 10 },
                        stepSize: 1,
                        precision: 0
                    },
                    beginAtZero: true,
                    title: {
                        display: true,
                        text: 'SESSIONS',
                        color: SESSION_COLOR,
                        font: { family: "'Antonio', sans-serif", size: 10 }
                    }
                },
                yMachines: {
                    type: 'linear',
                    position: 'right',
                    grid: { drawOnChartArea: false },
                    ticks: {
                        color: ONLINE_COLOR,
                        font: { family: "'Antonio', sans-serif", size: 10 },
                        stepSize: 1,
                        precision: 0
                    },
                    beginAtZero: true,
                    title: {
                        display: true,
                        text: chartData.isSnapshot ? 'STATUS' : 'MACHINES',
                        color: ONLINE_COLOR,
                        font: { family: "'Antonio', sans-serif", size: 10 }
                    }
                }
            },
            animation: { duration: 600, easing: 'easeInOutQuart' }
        };

        if (sessionChart) {
            // Update existing chart in place
            LCARSCharts.updateChart(sessionChart, data);
        } else {
            // Create new chart (LCARSCharts.createLine auto-applies palette,
            // but we've already set colors explicitly so pass data as-is)
            const canvas = document.getElementById(SESSION_CANVAS_ID);
            if (!canvas) {
                console.error('[LCARSAnalyticsFleet] Canvas not found: #' + SESSION_CANVAS_ID);
                return;
            }
            sessionChart = new Chart(canvas, { // eslint-disable-line no-undef
                type: 'line',
                data: data,
                options: options
            });
        }
    }

    // -------------------------------------------------------------------------
    // Public: init
    // -------------------------------------------------------------------------

    /**
     * Initialize the fleet analytics module.
     * Fetches data and renders the session chart.
     * Safe to call multiple times — re-renders with fresh data each time.
     */
    async function init() {
        console.log('[LCARSAnalyticsFleet] Initializing...');

        // Make sure LCARSCharts is ready
        if (typeof LCARSCharts !== 'undefined') {
            LCARSCharts.init();
        }

        const raw = await fetchFleetData();
        lastData = raw;

        if (!raw || !raw.fleet) {
            console.warn('[LCARSAnalyticsFleet] No fleet data available.');
            showNoData('NO FLEET DATA');
            initialized = true;
            return;
        }

        const chartData = processFleetData(raw);
        renderSessionChart(chartData);
        initialized = true;
        console.log('[LCARSAnalyticsFleet] Session chart rendered.');
    }

    // -------------------------------------------------------------------------
    // Public: refresh
    // -------------------------------------------------------------------------

    /**
     * Refresh the chart with the latest fleet data.
     * Re-fetches from the API and updates the chart in place.
     */
    async function refresh() {
        if (!initialized) {
            return init();
        }

        const raw = await fetchFleetData();
        if (!raw || !raw.fleet) {
            console.warn('[LCARSAnalyticsFleet] Refresh: no fleet data.');
            return;
        }

        lastData = raw;
        const chartData = processFleetData(raw);
        renderSessionChart(chartData);
        console.log('[LCARSAnalyticsFleet] Session chart refreshed.');
    }

    // -------------------------------------------------------------------------
    // Public: destroy
    // -------------------------------------------------------------------------

    /**
     * Destroy the chart and reset state.
     * Call when navigating away from the analytics section if needed.
     */
    function destroy() {
        if (sessionChart) {
            sessionChart.destroy();
            sessionChart = null;
        }
        initialized = false;
        lastData = null;
        console.log('[LCARSAnalyticsFleet] Destroyed.');
    }

    // -------------------------------------------------------------------------
    // Section change listener
    // -------------------------------------------------------------------------

    /**
     * Listen for the lcars:sectionChange event dispatched by lcars-fleet-core.js.
     * Initialize when the analytics section becomes active.
     */
    document.addEventListener('DOMContentLoaded', function () {
        document.addEventListener('lcars:sectionChange', function (e) {
            if (e.detail && e.detail.section === 'analytics') {
                // Small delay to let the section animation complete
                setTimeout(function () {
                    if (!initialized) {
                        init();
                    } else {
                        refresh();
                    }
                }, 150);
            }
        });

        // Also handle the case where the page loads directly on the analytics section
        const analyticsSection = document.querySelector('[data-section="analytics"].active');
        if (analyticsSection) {
            setTimeout(init, 300);
        }

        // Recreate session chart when the Charts page becomes visible.
        // Chart.js doesn't repaint content drawn at an off-screen position.
        document.addEventListener('lcars:analyticsPageChange', function (e) {
            if (e.detail && e.detail.page === 'charts' && initialized && lastData) {
                requestAnimationFrame(function () {
                    if (sessionChart) {
                        sessionChart.destroy();
                        sessionChart = null;
                    }
                    try {
                        var chartData = processFleetData(lastData);
                        renderSessionChart(chartData);
                    } catch (err) {
                        console.error('[LCARSAnalyticsFleet] Chart recreate error:', err);
                    }
                });
            }
        });
    });

    // -------------------------------------------------------------------------
    // Public API
    // -------------------------------------------------------------------------

    return {
        init: init,
        refresh: refresh,
        destroy: destroy
    };

}());
