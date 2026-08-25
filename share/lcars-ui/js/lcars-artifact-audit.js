//
//  lcars-artifact-audit.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

/**
 * lcars-artifact-audit.js — XACA-0220 Phase 3b
 *
 * Polls /api/artifact-audit for the current team and injects a dismissable
 * warning banner into the HOME section when misplaced kanban artifacts are
 * detected.  Clears the banner automatically when the team is clean.
 *
 * Security: all dynamic text is inserted via textContent (never innerHTML
 * with untrusted data).  The banner skeleton is static HTML with no user
 * or server strings embedded directly.
 *
 * Integration: loaded alongside lcars.js in index.html.  No dependency on
 * the rest of lcars.js — uses only the shared `apiUrl()` helper (or falls
 * back to a local equivalent).
 */

(function (global) {
    'use strict';

    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------
    var POLL_INTERVAL_MS  = 5 * 60 * 1000;  // 5-minute poll — audit runs daily
    var BANNER_ID         = 'xaca-0220-audit-banner';
    var API_PATH          = '/api/artifact-audit';

    // ------------------------------------------------------------------
    // Bootstrap — wire up after DOM is ready
    // ------------------------------------------------------------------
    function init() {
        _poll();
        setInterval(_poll, POLL_INTERVAL_MS);
    }

    // ------------------------------------------------------------------
    // Poll /api/artifact-audit and update the banner
    // ------------------------------------------------------------------
    function _poll() {
        var url = (typeof apiUrl === 'function') ? apiUrl(API_PATH) : API_PATH;
        fetch(url)
            .then(function (resp) {
                if (!resp.ok) {
                    // API not available yet (server restart, first deploy) — hide
                    _hideBanner();
                    return null;
                }
                return resp.json();
            })
            .then(function (data) {
                if (!data) return;
                if (data.clean) {
                    _hideBanner();
                } else {
                    _showBanner(data);
                }
            })
            .catch(function (err) {
                // Network error — stay quiet, don't spam the console
                console.debug('[artifact-audit] poll error:', err.message || err);
            });
    }

    // ------------------------------------------------------------------
    // DOM element builders (textContent-safe — no innerHTML with data)
    // ------------------------------------------------------------------

    /** Create a DOM element with optional className and inline style. */
    function _el(tag, opts) {
        var el = document.createElement(tag || 'div');
        if (opts) {
            if (opts.className) el.className = opts.className;
            if (opts.style)     el.style.cssText = opts.style;
            if (opts.text)      el.textContent = opts.text;
            if (opts.title)     el.title = opts.title;
            if (opts.id)        el.id = opts.id;
        }
        return el;
    }

    /** Append multiple children to a parent. */
    function _append(parent) {
        var children = Array.prototype.slice.call(arguments, 1);
        children.forEach(function (c) { if (c) parent.appendChild(c); });
        return parent;
    }

    // ------------------------------------------------------------------
    // Show (or update) the banner in the HOME section
    // ------------------------------------------------------------------
    function _showBanner(data) {
        // Remove stale version first so we re-render with fresh data
        _hideBanner();
        var banner = _buildBanner(data);

        // Inject into the HOME section, or prepend to body as fallback
        var target = (
            document.getElementById('home-section') ||
            document.getElementById('queue-container') ||
            document.querySelector('.lcars-main-content') ||
            document.body
        );
        if (target.firstChild) {
            target.insertBefore(banner, target.firstChild);
        } else {
            target.appendChild(banner);
        }
    }

    function _hideBanner() {
        var banner = document.getElementById(BANNER_ID);
        if (banner && banner.parentNode) {
            banner.parentNode.removeChild(banner);
        }
    }

    // ------------------------------------------------------------------
    // Build the banner DOM tree using safe DOM methods only
    // ------------------------------------------------------------------
    function _buildBanner(data) {
        var team      = String(data.team || 'unknown');
        var scanTime  = data.scan_time ? _relativeTime(data.scan_time) : 'recently';

        // XACA-0951: the audit reports TWO finding kinds and `clean` is false when
        // EITHER is non-empty. Counting only `violations` made a run with 7 real
        // historical findings render as "0 VIOLATIONS" above an empty list — a
        // banner that announces its own findings as nothing found. Any future
        // finding kind must be added here too, or it inherits that same silence.
        var misplaced  = data.violations || [];
        var historical = data.historical_subitem_violations || [];

        // Normalise both shapes to a single display line. Misplaced-artifact
        // records carry `path`; historical-subitem records carry `plan_doc`
        // plus the item id and row count, which is the useful part for a reader.
        var violations = misplaced.map(function (v) {
            return { line: v.path || '' };
        }).concat(historical.map(function (h) {
            var rows = (h.row_count === 1) ? '1 row' : String(h.row_count || 0) + ' rows';
            return { line: String(h.item_id || '?') + ' — ' + rows +
                           ' promised, never tracked (' + (h.plan_doc || '') + ')' };
        }));

        var count = violations.length;

        // Outer wrapper
        var banner = _el('div', {
            id: BANNER_ID,
            style: [
                'display:flex',
                'align-items:flex-start',
                'gap:12px',
                'padding:10px 16px',
                'margin:8px 0',
                'background:rgba(255,180,0,0.12)',
                'border:1px solid rgba(255,180,0,0.45)',
                'border-left:4px solid #ffb400',
                'border-radius:3px',
                'font-family:monospace',
                'font-size:12px',
                'color:#ffcc66',
                'position:relative',
                'z-index:10',
            ].join(';')
        });

        // Warning icon
        var icon = _el('span', {
            text: '⚠',
            style: 'font-size:18px;line-height:1;flex-shrink:0'
        });

        // Content column
        var content = _el('div', { style: 'flex:1' });

        // Headline row
        var headline = _el('div');
        var strong = _el('strong', {
            style: 'color:#ffcc00',
            text: 'ARTIFACT AUDIT — ' + count + ' VIOLATION' + (count === 1 ? '' : 'S')
        });
        var meta = _el('span', {
            style: 'opacity:0.65;font-size:11px;margin-left:6px',
            text: '(' + team + ', scanned ' + scanTime + ')'
        });
        _append(headline, strong, meta);

        // Violations list (up to 5)
        var list = _el('ul', {
            style: 'margin:6px 0 0 14px;padding:0;list-style:disc'
        });
        var shown = Math.min(violations.length, 5);
        for (var i = 0; i < shown; i++) {
            var li = _el('li', {
                style: 'margin:2px 0;opacity:0.85',
                text: violations[i].line || ''
            });
            list.appendChild(li);
        }
        if (violations.length > 5) {
            var more = _el('li', {
                style: 'opacity:0.65',
                text: '… and ' + (violations.length - 5) + ' more'
            });
            list.appendChild(more);
        }

        // Hint paragraph — build with text nodes to avoid injecting team name via innerHTML
        var hint = _el('p', {
            style: 'margin:6px 0 0;opacity:0.7;font-size:11px'
        });
        hint.appendChild(document.createTextNode('Run '));
        var code = _el('code', {
            text: 'python3 ~/dev-team/scripts/daily-artifact-audit.py --team ' + team
        });
        hint.appendChild(code);
        hint.appendChild(document.createTextNode(' locally, then move files to their kanban/ path.'));

        _append(content, headline, list, hint);

        // Dismiss button
        var dismissBtn = _el('button', {
            title: 'Dismiss (reappears on next poll)',
            style: 'background:none;border:none;cursor:pointer;color:#ffcc00;font-size:16px;line-height:1;flex-shrink:0',
            text: '✕'
        });
        dismissBtn.addEventListener('click', function () {
            var el = document.getElementById(BANNER_ID);
            if (el) el.style.display = 'none';
        });

        _append(banner, icon, content, dismissBtn);
        return banner;
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------
    function _relativeTime(isoStr) {
        try {
            var then   = new Date(isoStr);
            var diffMs = Date.now() - then.getTime();
            var diffH  = Math.floor(diffMs / 3600000);
            if (diffH < 1)  return 'less than 1h ago';
            if (diffH < 24) return diffH + 'h ago';
            var diffD  = Math.floor(diffH / 24);
            return diffD + 'd ago';
        } catch (_) {
            return isoStr;
        }
    }

    // ------------------------------------------------------------------
    // Expose for manual triggering from the browser console
    // ------------------------------------------------------------------
    global.ArtifactAudit = {
        poll:       _poll,
        showBanner: _showBanner,
        hideBanner: _hideBanner,
    };

    // ------------------------------------------------------------------
    // Auto-start when DOM is ready
    // ------------------------------------------------------------------
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }

}(window));
