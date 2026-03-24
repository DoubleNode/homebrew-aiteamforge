/**
 * lcars-charts.js
 * LCARS Chart.js Theming Module
 *
 * Configures Chart.js with LCARS aesthetics: Antonio font, LCARS color palette,
 * rounded shapes, subtle grids, and smooth animations.
 *
 * Usage:
 *   LCARSCharts.init();                                          // Call once on page load
 *   const chart = LCARSCharts.createDoughnut('myCanvas', data); // Create a chart
 *   LCARSCharts.updateChart(chart, newData);                     // Update with animation
 *
 * Requires: Chart.js 4.x (loaded via CDN before this script)
 */

// CANONICAL SOURCE: This file is the single source of truth for LCARS chart theming.
// Fleet Monitor references this via symlink at fleet-monitor/server/public/lcars/js/lcars-charts.js
// Do NOT create copies — edit this file only.

/* global Chart */

const LCARSCharts = (function () {
    'use strict';

    // -------------------------------------------------------------------------
    // Color Palette
    // -------------------------------------------------------------------------

    /** Core LCARS color palette. */
    const colors = {
        tan:    '#FFCC99',
        orange: '#FF9900',
        red:    '#CC6666',
        blue:   '#9999CC',
        cyan:   '#99CCFF',
        purple: '#CC99CC',
        green:  '#99CC99',
        yellow: '#FFFF99',

        // Semi-transparent variants for fills
        tanAlpha:    'rgba(255, 204, 153, 0.25)',
        orangeAlpha: 'rgba(255, 153,   0, 0.25)',
        redAlpha:    'rgba(204, 102, 102, 0.25)',
        blueAlpha:   'rgba(153, 153, 204, 0.25)',
        cyanAlpha:   'rgba(153, 204, 255, 0.25)',
        purpleAlpha: 'rgba(204, 153, 204, 0.25)',
        greenAlpha:  'rgba(153, 204, 153, 0.25)',
        yellowAlpha: 'rgba(255, 255, 153, 0.25)',

        // UI support colors
        background: '#0A0A1A',
        surface:    '#111124',
        text:       '#FFCC99',
        textDim:    'rgba(255, 204, 153, 0.55)',
        gridLine:   'rgba(255, 204, 153, 0.10)',
        tooltipBg:  'rgba(10, 10, 26, 0.92)',
    };

    // -------------------------------------------------------------------------
    // Status Color Mapping
    // -------------------------------------------------------------------------

    /**
     * Maps kanban workflow statuses to LCARS colors.
     * Used to color-code doughnut/bar slices by status.
     */
    const statusColors = {
        backlog:     colors.tan,
        todo:        colors.orange,
        in_progress: colors.cyan,
        review:      colors.purple,
        done:        colors.green,
        cancelled:   colors.red,

        // Aliases for extended status sets
        ready:       colors.orange,
        planning:    colors.yellow,
        coding:      colors.cyan,
        testing:     colors.blue,
        commit:      colors.purple,
        pr_review:   colors.purple,
        paused:      colors.tan,
        blocked:     colors.red,
        completed:   colors.green,
    };

    // -------------------------------------------------------------------------
    // Private helpers
    // -------------------------------------------------------------------------

    /** Returns the ordered LCARS palette as an array, cycling if more are needed. */
    function _palette(count) {
        const base = [
            colors.cyan,
            colors.orange,
            colors.purple,
            colors.green,
            colors.tan,
            colors.blue,
            colors.yellow,
            colors.red,
        ];
        const result = [];
        for (let i = 0; i < count; i++) {
            result.push(base[i % base.length]);
        }
        return result;
    }

    /** Returns semi-transparent versions of the same palette. */
    function _paletteAlpha(count, opacity) {
        const op = opacity !== undefined ? opacity : 0.25;
        return _palette(count).map(function (hex) {
            const r = parseInt(hex.slice(1, 3), 16);
            const g = parseInt(hex.slice(3, 5), 16);
            const b = parseInt(hex.slice(5, 7), 16);
            return 'rgba(' + r + ', ' + g + ', ' + b + ', ' + op + ')';
        });
    }

    /** Shared tooltip configuration. */
    function _tooltipConfig() {
        return {
            backgroundColor: colors.tooltipBg,
            titleColor:      colors.tan,
            bodyColor:       colors.text,
            borderColor:     colors.tan,
            borderWidth:     1,
            cornerRadius:    8,
            padding:         10,
            titleFont: {
                family: "'Antonio', sans-serif",
                size:   13,
                weight: '600',
            },
            bodyFont: {
                family: "'Antonio', sans-serif",
                size:   12,
            },
            displayColors: true,
            boxWidth:        10,
            boxHeight:       10,
        };
    }

    /** Shared legend configuration. */
    function _legendConfig() {
        return {
            display: true,
            labels: {
                color:     colors.text,
                font: {
                    family: "'Antonio', sans-serif",
                    size:   12,
                },
                padding:    16,
                boxWidth:   12,
                boxHeight:  12,
                usePointStyle: true,
                pointStyle:    'rectRounded',
            },
        };
    }

    /** Shared animation configuration. */
    function _animationConfig() {
        return {
            duration: 600,
            easing:   'easeInOutQuart',
        };
    }

    // -------------------------------------------------------------------------
    // Public: init
    // -------------------------------------------------------------------------

    /**
     * Sets Chart.js global defaults to match LCARS aesthetics.
     * Call once after Chart.js has loaded, before creating any charts.
     *
     * IMPORTANT: Only sets leaf-level scalar properties on Chart.defaults.
     * Never replace objects wholesale (Object.assign / direct assignment on
     * plugin configs) — that destroys internal Chart.js properties such as
     * labels.generateLabels, tooltip callbacks, and animation resolvers.
     * Per-chart theming is handled by the create* helpers instead.
     */
    function init() {
        if (typeof Chart === 'undefined') {
            console.warn('[LCARSCharts] Chart.js not loaded. Call init() after Chart.js.');
            return;
        }

        // Global font
        Chart.defaults.font.family = "'Antonio', sans-serif";
        Chart.defaults.font.size   = 12;
        Chart.defaults.color       = colors.text;

        // Responsive behavior
        Chart.defaults.responsive         = true;
        Chart.defaults.maintainAspectRatio = true;

        // Animation timing (set individual properties, don't replace the object)
        Chart.defaults.animation.duration = 600;
        Chart.defaults.animation.easing   = 'easeInOutQuart';
    }

    // -------------------------------------------------------------------------
    // Public: createDoughnut
    // -------------------------------------------------------------------------

    /**
     * Creates an LCARS-styled doughnut chart.
     *
     * @param {string} canvasId - ID of the <canvas> element.
     * @param {Object} data - Chart.js data object: { labels, datasets }
     *   If datasets[0].backgroundColor is not set, LCARS palette is applied.
     * @param {Object} [options] - Additional Chart.js options (merged/overriding defaults).
     * @returns {Chart} The Chart.js instance.
     */
    function createDoughnut(canvasId, data, options) {
        const canvas = document.getElementById(canvasId);
        if (!canvas) {
            console.error('[LCARSCharts] Canvas not found: #' + canvasId);
            return null;
        }

        // Apply LCARS palette if no colors provided
        if (data.datasets && data.datasets[0] && !data.datasets[0].backgroundColor) {
            const count = (data.labels || []).length;
            data.datasets[0].backgroundColor = _palette(count);
            data.datasets[0].borderColor     = colors.background;
            data.datasets[0].borderWidth     = 2;
            data.datasets[0].hoverBorderColor = colors.tan;
            data.datasets[0].hoverBorderWidth = 3;
        }

        const defaultOpts = {
            cutout: '65%',
            borderRadius: 4,
            plugins: {
                legend:  _legendConfig(),
                tooltip: _tooltipConfig(),
            },
            animation: _animationConfig(),
        };

        const mergedOpts = _deepMerge(defaultOpts, options || {});

        return new Chart(canvas, {
            type: 'doughnut',
            data: data,
            options: mergedOpts,
        });
    }

    // -------------------------------------------------------------------------
    // Public: createBar
    // -------------------------------------------------------------------------

    /**
     * Creates an LCARS-styled bar chart.
     *
     * @param {string} canvasId - ID of the <canvas> element.
     * @param {Object} data - Chart.js data object: { labels, datasets }
     * @param {Object} [options] - Additional Chart.js options.
     * @returns {Chart} The Chart.js instance.
     */
    function createBar(canvasId, data, options) {
        const canvas = document.getElementById(canvasId);
        if (!canvas) {
            console.error('[LCARSCharts] Canvas not found: #' + canvasId);
            return null;
        }

        // Apply palette and styling per dataset
        if (data.datasets) {
            data.datasets.forEach(function (ds, idx) {
                if (!ds.backgroundColor) {
                    const baseColor = _palette(data.datasets.length)[idx];
                    const r = parseInt(baseColor.slice(1, 3), 16);
                    const g = parseInt(baseColor.slice(3, 5), 16);
                    const b = parseInt(baseColor.slice(5, 7), 16);
                    ds.backgroundColor = 'rgba(' + r + ', ' + g + ', ' + b + ', 0.75)';
                    ds.borderColor     = baseColor;
                    ds.borderWidth     = 1;
                    ds.hoverBackgroundColor = baseColor;
                    ds.borderRadius         = 4;
                    ds.borderSkipped        = false;
                }
            });
        }

        const defaultOpts = {
            plugins: {
                legend:  _legendConfig(),
                tooltip: _tooltipConfig(),
            },
            animation: _animationConfig(),
            scales: {
                x: {
                    grid: {
                        color:     colors.gridLine,
                        lineWidth: 1,
                    },
                    ticks: {
                        color: colors.textDim,
                        font: { family: "'Antonio', sans-serif", size: 11 },
                    },
                },
                y: {
                    grid: {
                        color:     colors.gridLine,
                        lineWidth: 1,
                    },
                    ticks: {
                        color: colors.textDim,
                        font: { family: "'Antonio', sans-serif", size: 11 },
                    },
                    beginAtZero: true,
                },
            },
        };

        const mergedOpts = _deepMerge(defaultOpts, options || {});

        return new Chart(canvas, {
            type: 'bar',
            data: data,
            options: mergedOpts,
        });
    }

    // -------------------------------------------------------------------------
    // Public: createLine
    // -------------------------------------------------------------------------

    /**
     * Creates an LCARS-styled line chart.
     *
     * @param {string} canvasId - ID of the <canvas> element.
     * @param {Object} data - Chart.js data object: { labels, datasets }
     * @param {Object} [options] - Additional Chart.js options.
     * @returns {Chart} The Chart.js instance.
     */
    function createLine(canvasId, data, options) {
        const canvas = document.getElementById(canvasId);
        if (!canvas) {
            console.error('[LCARSCharts] Canvas not found: #' + canvasId);
            return null;
        }

        // Apply palette and styling per dataset
        if (data.datasets) {
            data.datasets.forEach(function (ds, idx) {
                if (!ds.borderColor) {
                    const baseColor = _palette(data.datasets.length)[idx];
                    const r = parseInt(baseColor.slice(1, 3), 16);
                    const g = parseInt(baseColor.slice(3, 5), 16);
                    const b = parseInt(baseColor.slice(5, 7), 16);
                    ds.borderColor           = baseColor;
                    ds.backgroundColor       = 'rgba(' + r + ', ' + g + ', ' + b + ', 0.15)';
                    ds.borderWidth           = 2;
                    ds.pointBackgroundColor  = baseColor;
                    ds.pointBorderColor      = colors.background;
                    ds.pointBorderWidth      = 2;
                    ds.pointRadius           = 4;
                    ds.pointHoverRadius      = 6;
                    ds.tension               = 0.35;
                    ds.fill                  = ds.fill !== undefined ? ds.fill : false;
                }
            });
        }

        const defaultOpts = {
            plugins: {
                legend:  _legendConfig(),
                tooltip: _tooltipConfig(),
            },
            animation: _animationConfig(),
            scales: {
                x: {
                    grid: {
                        color:     colors.gridLine,
                        lineWidth: 1,
                    },
                    ticks: {
                        color: colors.textDim,
                        font: { family: "'Antonio', sans-serif", size: 11 },
                    },
                },
                y: {
                    grid: {
                        color:     colors.gridLine,
                        lineWidth: 1,
                    },
                    ticks: {
                        color: colors.textDim,
                        font: { family: "'Antonio', sans-serif", size: 11 },
                    },
                    beginAtZero: true,
                },
            },
        };

        const mergedOpts = _deepMerge(defaultOpts, options || {});

        return new Chart(canvas, {
            type: 'line',
            data: data,
            options: mergedOpts,
        });
    }

    // -------------------------------------------------------------------------
    // Public: updateChart
    // -------------------------------------------------------------------------

    /**
     * Updates an existing chart's data with a smooth animation.
     *
     * @param {Chart} chart - A Chart.js instance returned by one of the create* helpers.
     * @param {Object} newData - New Chart.js data object: { labels, datasets }
     *   Partial updates are fine — only provided fields are replaced.
     */
    function updateChart(chart, newData) {
        if (!chart || typeof chart.update !== 'function') {
            console.error('[LCARSCharts] updateChart: invalid Chart instance.');
            return;
        }

        if (newData.labels !== undefined) {
            chart.data.labels = newData.labels;
        }

        if (newData.datasets !== undefined) {
            newData.datasets.forEach(function (ds, idx) {
                if (chart.data.datasets[idx]) {
                    Object.assign(chart.data.datasets[idx], ds);
                } else {
                    chart.data.datasets.push(ds);
                }
            });

            // Remove excess datasets if newData has fewer
            if (chart.data.datasets.length > newData.datasets.length) {
                chart.data.datasets.splice(newData.datasets.length);
            }
        }

        chart.update('active'); // 'active' uses the configured animation
    }

    // -------------------------------------------------------------------------
    // Private: _deepMerge
    // -------------------------------------------------------------------------

    /**
     * Simple recursive merge of plain objects.
     * Arrays are replaced (not merged) — this is intentional for Chart.js options.
     */
    function _deepMerge(target, source) {
        const result = Object.assign({}, target);
        Object.keys(source).forEach(function (key) {
            if (
                source[key] !== null &&
                typeof source[key] === 'object' &&
                !Array.isArray(source[key]) &&
                typeof target[key] === 'object' &&
                !Array.isArray(target[key])
            ) {
                result[key] = _deepMerge(target[key] || {}, source[key]);
            } else {
                result[key] = source[key];
            }
        });
        return result;
    }

    // -------------------------------------------------------------------------
    // Public API
    // -------------------------------------------------------------------------

    return {
        init:          init,
        colors:        colors,
        statusColors:  statusColors,
        createDoughnut: createDoughnut,
        createBar:     createBar,
        createLine:    createLine,
        updateChart:   updateChart,

        // Expose internal helpers for advanced users who want raw palettes
        _palette:      _palette,
        _paletteAlpha: _paletteAlpha,
    };

}());
