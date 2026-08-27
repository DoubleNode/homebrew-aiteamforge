//
//  lcars-terminal-card.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

/**
 * LCARS Fleet Monitor — LCARS-terminal card rendering + detection.
 *
 * THE SINGLE implementation. Before XACA-0990 `isLcarsTerminal()` (19 lines)
 * and `createServiceOnlyLcarsCard()` (53 lines) were byte-identical copies
 * pasted into FIVE client app files (md5 f8f39c4b8e953998cbc1cf3f6d5ba17b and
 * 8589317f7526bceafe0406c52a3f77a5, verified across all 5 before this module
 * was written). A characterization suite
 * (tests/xaca-0990-001-lcars-terminal-card-characterization.test.js) pinned
 * their exact current behavior, including one pre-existing quirk (see
 * createServiceOnlyLcarsCard's doc comment below), as the contract this
 * module must reproduce byte-for-byte.
 *
 * If you find yourself copying either function into an app file again, that
 * is the bug this module exists to prevent — add a `<script src=".../shared/
 * js/lcars-terminal-card.js">` tag and call LCARS_TERMINAL_CARD.* instead.
 *
 * ── The one behavioral change from the original copies ──────────────────
 * createServiceOnlyLcarsCard() calls escapeHtml() to sanitize name/hostname
 * before they reach innerHTML. In every original copy, escapeHtml was a
 * FREE VARIABLE resolved from that app file's own enclosing IIFE scope —
 * not passed in, not defined in the function itself. Lifted verbatim into
 * this standalone module, that free-variable reference would resolve to
 * nothing and throw a ReferenceError on every single call. escapeHtml is
 * therefore now the function's THIRD PARAMETER, injected by each caller.
 * escapeHtml() itself is NOT moved here — it has other call sites inside
 * each app file untouched by this ticket, so it stays defined there and
 * gets passed in. This is the only permitted deviation from a verbatim
 * copy; every comment and line of logic below is otherwise unchanged from
 * the original 5 copies, XACA-0983/-014/-015 rationale included.
 */
(function (global) {
    'use strict';

    /**
     * Detect whether a team's data represents an LCARS terminal.
     *
     * Verbatim from the 5 original copies (md5 f8f39c4b8e953998cbc1cf3f6d5ba17b)
     * — no parameters changed, no logic changed.
     *
     * @param {object} teamData  a team's entry from the fleet-monitor payload
     * @returns {boolean}
     */
    function isLcarsTerminal(teamData) {
        if (!teamData) {
            return false;
        }
        if (teamData.sessions && teamData.sessions.some(function(session) {
            return session.name && session.name.toLowerCase().includes('lcars');
        })) {
            return true;
        }
        // XACA-0983 fix (b): a team can be a known LCARS terminal via a
        // reported service record (data.lcars_service -- see server.js's
        // parseFleetData / fleet-reporter.sh's get_lcars_services()) even
        // with NO live tmux session, e.g. a health-check self-heal killed
        // the session and nothing recreated it. Gating solely on a session
        // NAME substring (the original bug) makes a healthy-or-even-known-
        // down backend invisible; checking lcars_service too closes that
        // gap without requiring a session to exist at all.
        return !!(teamData.lcars_service);
    }

    /**
     * Render a card for a team known to be an LCARS terminal via reported
     * service data (data.lcars_service) but with NO live tmux session.
     *
     * Verbatim body from the 5 original copies
     * (md5 8589317f7526bceafe0406c52a3f77a5), with exactly ONE change:
     * `escapeHtml` is now the third parameter instead of a free variable
     * resolved from the caller's enclosing IIFE scope. Every other line,
     * including the comments below, is unchanged.
     *
     * escapeHtml is REQUIRED, not optional, and is validated up front: a
     * missing/invalid escapeHtml is a caller programming error, not a
     * degraded-but-safe runtime state. Defaulting it to a no-op (or to
     * identity) would silently reintroduce the exact unescaped-innerHTML
     * hazard XACA-0983-015 closed, just one call deeper and harder to spot.
     * Throwing loudly here means that mistake fails at the call site
     * instead of shipping a card that renders raw markup.
     *
     * PRE-EXISTING QUIRK, preserved on purpose (do not "fix" here — it is
     * out of scope for this refactor and changing it would break the
     * behavior-identical contract the characterization suite enforces):
     * when svc.reachable === true but svc.hostname is missing, the card's
     * className/status text report REACHABLE, yet the `if (reachable &&
     * svc.hostname)` guard below still takes the else branch — no
     * tabindex/role/click-or-keydown listeners, and the "not reachable"
     * title. That mismatch predates this module.
     *
     * @param {string} name         team name
     * @param {object} svc          data.lcars_service record (hostname, port, reachable)
     * @param {function} escapeHtml HTML-escaping function; same contract as
     *                              the escapeHtml() defined in each app file
     *                              (div.textContent = x; return div.innerHTML).
     *                              REQUIRED — see rationale above.
     * @returns {HTMLElement}
     */
    function createServiceOnlyLcarsCard(name, svc, escapeHtml) {
        if (typeof escapeHtml !== 'function') {
            throw new TypeError(
                'LCARS_TERMINAL_CARD.createServiceOnlyLcarsCard: escapeHtml must be a function ' +
                '(the caller\'s own HTML-escaping helper). Refusing to render unescaped markup ' +
                'into innerHTML instead of silently skipping escaping.'
            );
        }

        const card = document.createElement('div');
        const reachable = svc.reachable === true;
        // reachable === false OR null (curl unavailable, or the probe was
        // skipped on the reporting host) both render as unreachable -- this
        // UI never claims health it did not actually observe.
        card.className = 'team-card lcars-terminal' + (reachable ? '' : ' lcars-offline');

        const statusClass = reachable ? 'online' : 'offline';
        const statusText = reachable ? 'REACHABLE' : 'UNREACHABLE';

        // XACA-0983-015: name/hostname come from fleet-reporter data, not a
        // user text field, but they still flow into innerHTML unescaped --
        // escape them. svc.port is excluded: server.js's parseFleetData
        // gates it through Number.isFinite before it ever reaches this card,
        // so it can never carry markup -- do not remove that gate.
        card.innerHTML =
            '<div class="team-header">' +
                '<div class="team-name">' + escapeHtml(name) + '<span class="lcars-badge">LCARS</span></div>' +
                '<span class="status-indicator ' + statusClass + '"></span>' +
            '</div>' +
            '<div class="session-info">' +
                '<div class="session-detail"><span class="session-label">Session:</span><span class="session-value text-offline">NO ACTIVE SESSION</span></div>' +
                '<div class="session-detail"><span class="session-label">Machine:</span><span class="session-value">' + escapeHtml(svc.hostname || 'unknown') + '</span></div>' +
                '<div class="session-detail"><span class="session-label">Port:</span><span class="session-value">' + svc.port + '</span></div>' +
                '<div class="session-detail"><span class="session-label">Status:</span><span class="session-value text-' + statusClass + '">' + statusText + '</span></div>' +
            '</div>';

        if (reachable && svc.hostname) {
            const lcarsUrl = 'http://' + svc.hostname + ':' + svc.port;
            card.classList.add('lcars-clickable');
            card.title = 'Click to open LCARS terminal: ' + lcarsUrl;
            // XACA-0983-014: keyboard-only users need the same path mouse
            // users get. The UNREACHABLE branch below (the `else`) never
            // reaches this code -- it stays a plain non-focusable div, since
            // it is not actionable and must not claim to be.
            card.setAttribute('tabindex', '0');
            card.setAttribute('role', 'button');
            card.addEventListener('click', function() {
                window.open(lcarsUrl, '_blank');
            });
            card.addEventListener('keydown', function(evt) {
                if (evt.key === 'Enter' || evt.key === ' ' || evt.key === 'Spacebar' || evt.keyCode === 13 || evt.keyCode === 32) {
                    evt.preventDefault();
                    window.open(lcarsUrl, '_blank');
                }
            });
        } else {
            card.title = 'LCARS terminal service is reported but not reachable';
        }

        return card;
    }

    var API = {
        isLcarsTerminal: isLcarsTerminal,
        createServiceOnlyLcarsCard: createServiceOnlyLcarsCard
    };

    // Freeze the namespace itself, not just leave its methods writable —
    // matching lcars-org-resolution.js's precedent, whose header notes
    // review caught exactly this half-closed gap on an earlier module: a
    // frozen-contents-but-writable-object still lets a later script replace
    // `LCARS_TERMINAL_CARD.isLcarsTerminal` for every dashboard that loads
    // this file.
    if (Object.freeze) { Object.freeze(API); }

    global.LCARS_TERMINAL_CARD = API;
})(typeof window !== 'undefined' ? window : this);
