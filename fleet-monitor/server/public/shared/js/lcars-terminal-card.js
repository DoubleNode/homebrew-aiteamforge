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
     * Render a card for a team that is REGISTERED (present in the team
     * registry / port map) but has never reported a live session AND has
     * no lcars_service record either -- i.e. server.js's parseFleetData
     * synthesized a session-less "idle" bucket for it (XACA-1002). Until
     * XACA-1002 this bucket type did not exist in the payload at all, so
     * this is new render surface, not an extracted copy.
     *
     * escapeHtml is REQUIRED for the same reason as createServiceOnlyLcarsCard
     * above: a missing/invalid escapeHtml is a caller programming error, not
     * a degraded-but-safe runtime state, so this throws loudly instead of
     * defaulting to a no-op/identity function that would silently reintroduce
     * the unescaped-innerHTML hazard XACA-0983-015 closed.
     *
     * No Port/Machine row: an idle-registered team has neither -- inventing
     * "unknown" placeholders for both would make the card read as a broken
     * live card instead of a deliberately idle one. No tabindex/role/click-
     * or-keydown listeners either -- there is nothing to open, and an
     * element must not claim to be actionable when it is not (same
     * principle as the UNREACHABLE branch of createServiceOnlyLcarsCard).
     *
     * Built entirely from CSS classes that already exist in both
     * lcars/css/lcars-fleet-theme.css and lcars2/css/lcars-fleet-theme.css
     * (.team-card, .team-header, .team-name, .status-indicator.idle,
     * .session-info, .session-detail, .session-label, .session-value,
     * .text-status-idle) -- this ticket adds zero new CSS.
     *
     * TEXT COLOUR IS .text-status-idle, NOT .text-offline (XACA-1002-012).
     * .text-offline resolves to --lcars-alert-red, the same red used for a
     * genuine UNREACHABLE service failure. Idle is a normal resting state,
     * not a fault, so painting these rows red contradicted the deliberately
     * muted tan .status-indicator.idle dot in the header -- the card said
     * "calm" with its dot and "alarm" with its text. .text-status-idle
     * (--lcars-tan) already existed in both theme sheets and was referenced
     * by no JS at all, so this agreement costs no new CSS. Do not "restore"
     * .text-offline here for consistency with createServiceOnlyLcarsCard:
     * that card IS reporting a failure, and this one is not.
     *
     * THE TIMESTAMP ROW IS LABELLED "Last Registered", NOT "Last Seen"
     * (XACA-1002-013). idle.lastSeen comes from the team registry, and
     * server.js only ever writes that field in POST /api/team-register --
     * it tracks registration recency, never session activity. A team that
     * has NEVER had a live session still shows a recent value every time
     * its startup script re-registers. Labelling that "Last Seen" invites
     * an operator to read activity into a number that does not measure it.
     *
     * @param {string} name          team/terminal name
     * @param {object} idle          data.idle_registered record: { team,
     *                               teamName, terminal, registeredAt, lastSeen }
     * @param {function} escapeHtml  HTML-escaping function; same contract as
     *                               createServiceOnlyLcarsCard's escapeHtml
     *                               param. REQUIRED -- see rationale above.
     * @returns {HTMLElement}
     */
    function createIdleTeamCard(name, idle, escapeHtml) {
        if (typeof escapeHtml !== 'function') {
            throw new TypeError(
                'LCARS_TERMINAL_CARD.createIdleTeamCard: escapeHtml must be a function ' +
                '(the caller\'s own HTML-escaping helper). Refusing to render unescaped markup ' +
                'into innerHTML instead of silently skipping escaping.'
            );
        }

        const card = document.createElement('div');
        card.className = 'team-card';

        const teamName = (idle && idle.teamName) || '';
        const lastSeenDisplay = formatIdleTimestamp(idle && idle.lastSeen);

        card.innerHTML =
            '<div class="team-header">' +
                '<div class="team-name">' + escapeHtml(name) + '</div>' +
                '<span class="status-indicator idle"></span>' +
            '</div>' +
            '<div class="session-info">' +
                '<div class="session-detail"><span class="session-label">Session:</span><span class="session-value text-status-idle">NO ACTIVE SESSION</span></div>' +
                '<div class="session-detail"><span class="session-label">Team:</span><span class="session-value">' + escapeHtml(teamName) + '</span></div>' +
                '<div class="session-detail"><span class="session-label">Status:</span><span class="session-value text-status-idle">IDLE (REGISTERED)</span></div>' +
                '<div class="session-detail"><span class="session-label">Last Registered:</span><span class="session-value">' + escapeHtml(lastSeenDisplay) + '</span></div>' +
            '</div>';

        card.title = 'Registered team with no active session';

        return card;
    }

    /**
     * Render idle.lastSeen (an ISO timestamp string from the team registry)
     * readably. Falls back to the raw string -- never to a fabricated
     * "unknown" value -- so a malformed timestamp is visibly malformed
     * instead of silently laundered into a normal-looking placeholder.
     *
     * @param {string} isoString
     * @returns {string}
     */
    function formatIdleTimestamp(isoString) {
        if (!isoString) {
            return 'unknown';
        }
        const d = new Date(isoString);
        if (isNaN(d.getTime())) {
            return String(isoString);
        }
        return d.toLocaleString('en-US', {
            year: 'numeric', month: 'short', day: 'numeric',
            hour: '2-digit', minute: '2-digit'
        });
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

    /**
     * Build the comparator used to order team names within one project panel.
     *
     * XACA-1002-014. Before this, the comparator was written inline in each of
     * the FIVE app files -- the exact copy-paste shape this module exists to
     * prevent. They were NOT all identical: the four lcars2 skins shared one
     * byte-identical body (LCARS-first, then localeCompare) while
     * lcars/js/lcars-dashboard-app.js carried an extra tab_order tier between
     * the two. Extracting them to a single body that "looked right" would have
     * silently dropped that tier and reordered every card in the dashboard
     * skin, so the tier is preserved behind `options.useTabOrder` and each
     * caller keeps the semantics it already had.
     *
     * Tiers, in order:
     *   1. LCARS terminals first (both skins, unchanged).
     *   2. Live before idle-registered (NEW). 28 idle cards arriving at once
     *      -- 7 in dns and 7 in each of three freelance divisions -- otherwise
     *      interleave alphabetically with live ones, so answering "what is
     *      actually running right now" means reading every card in the panel.
     *      An idle bucket can never be an LCARS terminal (it has neither a
     *      session nor an lcars_service, the only two things isLcarsTerminal
     *      looks at), so tiers 1 and 2 cannot contradict each other.
     *   3. tab_order, dashboard skin only (`useTabOrder`), unchanged there and
     *      still absent from lcars2. Idle teams have no session and so always
     *      scored the 999 sentinel here; tier 2 now states that intent
     *      directly instead of relying on a sentinel comparison to imply it.
     *   4. localeCompare on the team name (both skins, unchanged).
     *
     * @param {object} teams    projectData.teams -- name -> team bucket
     * @param {object} [options] { useTabOrder: boolean }
     * @returns {function(string, string): number}
     */
    function createTeamNameComparator(teams, options) {
        var useTabOrder = !!(options && options.useTabOrder);

        return function (a, b) {
            var aData = teams[a];
            var bData = teams[b];

            var aIsLcars = isLcarsTerminal(aData);
            var bIsLcars = isLcarsTerminal(bData);
            if (aIsLcars && !bIsLcars) { return -1; }
            if (!aIsLcars && bIsLcars) { return 1; }

            var aIdle = !!(aData && aData.idle_registered);
            var bIdle = !!(bData && bData.idle_registered);
            if (aIdle !== bIdle) { return aIdle ? 1 : -1; }

            if (useTabOrder) {
                var aSession = aData && aData.sessions && aData.sessions[0];
                var bSession = bData && bData.sessions && bData.sessions[0];
                var aOrder = aSession && typeof aSession.tab_order === 'number' ? aSession.tab_order : 999;
                var bOrder = bSession && typeof bSession.tab_order === 'number' ? bSession.tab_order : 999;
                if (aOrder !== bOrder) { return aOrder - bOrder; }
            }

            return a.localeCompare(b);
        };
    }

    var API = {
        isLcarsTerminal: isLcarsTerminal,
        createServiceOnlyLcarsCard: createServiceOnlyLcarsCard,
        createTeamNameComparator: createTeamNameComparator,
        createIdleTeamCard: createIdleTeamCard
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
