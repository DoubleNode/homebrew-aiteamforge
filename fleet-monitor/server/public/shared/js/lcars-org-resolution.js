//
//  lcars-org-resolution.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

/**
 * LCARS Fleet Monitor — division → organization resolution.
 *
 * THE SINGLE implementation. Before XACA-0970 this logic was copy-pasted into
 * FOURTEEN files that had drifted into multiple variants — and `finance` support
 * existed in exactly ONE of them, a file loaded by no page at all. The result was
 * that different dashboards resolved organizations differently, and `finance`
 * rendered under UNKNOWN everywhere it mattered.
 *
 * Reachability of those 14, measured by parsing every <script src> in public/:
 *   1  on the routed path      lcars/js/lcars-dashboard-app.js
 *   4  served but unrouted     lcars2/js/*-app.js (pages return 200 by direct
 *                              URL; no route or link points at them)
 *   9  dead, zero pages        app.js, {academy,mainevent,doublenode}-app.js,
 *                              lcars/js/lcars-{academy,all,doublenode,finance,
 *                              mainevent}-app.js
 * The 5 reachable ones delegate here; the 9 dead are removed under XACA-0971.
 *
 * If you are adding a team, add it HERE and nowhere else. If you find yourself
 * copying this function into an app file, that is the bug this module exists to
 * prevent.
 *
 * ── The key mismatch this fixes ──────────────────────────────────────────────
 * Callers pass a DIVISION CODE (`session.division`, set by fleet-reporter — e.g.
 * "finance", "legal"). The team registry is keyed by TEAM ID (e.g.
 * "finance-personal", "legal-coparenting"). For every suffixed team those differ,
 * so a plain `teams[code]` lookup can never match and the team silently lands in
 * UNKNOWN. `legal` only ever displayed correctly because someone hard-coded a
 * prefix fallback for it; its registry entry was never consulted.
 *
 * Hence step 2 below: match a division code against a registered id by prefix.
 * That makes the registry authoritative again, so a newly-registered team
 * resolves with NO code change here.
 */
(function (global) {
    'use strict';

    /**
     * Teams whose organization is known without a registry entry.
     *
     * This is a FALLBACK, not the source of truth — it exists for teams that are
     * not (or not yet) registered with the fleet monitor. `finance` is here
     * because it runs on M4Mini and does not currently register from any machine
     * that reaches this registry; once it does, step 2 resolves it and this entry
     * becomes redundant rather than wrong.
     */
    var STATIC_ORGS = {
        'academy':  'DEVTEAM',
        'android':  'MAIN EVENT',
        'command':  'MAIN EVENT',
        'dns':      'DOUBLENODE',
        'firebase': 'MAIN EVENT',
        'ios':      'MAIN EVENT',
        'finance':  'FINANCE',
        'legal':    'LEGAL',
        'medical':  'MEDICAL'
    };

    /**
     * Prefix fallbacks for division codes that carry a qualifier the static map
     * cannot enumerate — notably freelance, which the server splits per project
     * (`freelance-doublenode-starwords` and friends).
     */
    var PREFIX_ORGS = [
        ['freelance', 'DOUBLENODE'],
        ['legal',     'LEGAL'],
        ['medical',   'MEDICAL'],
        ['finance',   'FINANCE']
    ];

    /** Codes already warned about, so a render loop cannot flood the console. */
    var warned = {};

    /**
     * Resolve a division code to an organization name.
     *
     * @param {string} divisionCode  e.g. "finance", "legal", "freelance-doublenode-starwords"
     * @param {object} [teamConfig]  the /api/team-config payload, if loaded
     * @returns {string} organization name, or 'UNKNOWN' if nothing matched
     */
    function resolve(divisionCode, teamConfig) {
        if (!divisionCode) { return 'UNKNOWN'; }
        var code = String(divisionCode).toLowerCase();
        var teams = (teamConfig && teamConfig.teams) || null;

        // 1. Exact registry match — the division code IS the team id.
        //    True for academy/android/command/dns/firebase/ios and for each
        //    freelance-<project> division.
        if (teams && teams[code] && teams[code].organization) {
            return teams[code].organization;
        }

        // 2. Registry PREFIX match — the division code is the first segment of a
        //    suffixed team id ("finance" -> "finance-personal"). This is the fix
        //    for the key mismatch described in the header; without it every
        //    suffixed team falls through to the hard-coded lists below.
        if (teams) {
            for (var id in teams) {
                if (!Object.prototype.hasOwnProperty.call(teams, id)) { continue; }
                if (id.indexOf(code + '-') === 0 && teams[id].organization) {
                    return teams[id].organization;
                }
            }
        }

        // 3. Static map for teams that are not registered.
        if (STATIC_ORGS[code]) {
            return STATIC_ORGS[code];
        }

        // 4. Prefix fallbacks for qualifier-bearing codes (freelance-<project>).
        for (var i = 0; i < PREFIX_ORGS.length; i++) {
            var pfx = PREFIX_ORGS[i][0];
            // Require a DASH BOUNDARY, matching step 2. A bare indexOf()===0
            // would let "financex" resolve as "finance"; the exact-equal case is
            // already handled by STATIC_ORGS above but is kept here so this tier
            // is correct standalone.
            if (code === pfx || code.indexOf(pfx + '-') === 0) {
                return PREFIX_ORGS[i][1];
            }
        }

        // 5. Nothing matched. WARN rather than fail silently: every fault this
        //    module was written to fix survived for months because `|| 'UNKNOWN'`
        //    said nothing. If this fires, a team is missing from the registry or
        //    from STATIC_ORGS above.
        if (!warned[code]) {
            warned[code] = true;
            if (global.console && global.console.warn) {
                global.console.warn(
                    '[LCARS][org] No organization for division "' + code + '" — ' +
                    'showing UNKNOWN. Register the team, or add it to STATIC_ORGS ' +
                    'in shared/js/lcars-org-resolution.js.'
                );
            }
        }
        return 'UNKNOWN';
    }

    /**
     * Organization -> CSS class carrying its identity colour.
     *
     * Lives here for the same reason `resolve` does: getGroupColor() is
     * duplicated across the same 14 files, and FINANCE was missing from every
     * one of them. Note `.org-medical` has never existed either — MEDICAL has
     * silently fallen back for as long as it has been mapped (tracked
     * separately; not introduced here).
     *
     * MEDICAL uses teal, not cyan: cyan is already ACADEMY (routed theme) and
     * DEVTEAM, so sharing it made two org groups render identically. Teal is
     * also what the team registry itself declares for MEDICAL.
     */
    var ORG_CLASSES = {
        'DEVTEAM':    'org-academy',
        'DOUBLENODE': 'org-doublenode',
        'MAIN EVENT': 'org-mainevent',
        'LEGAL':      'org-legal',
        'MEDICAL':    'org-medical',
        'FINANCE':    'org-finance'
    };

    /**
     * @param {string} org        organization name as returned by resolve()
     * @param {string} [fallback] class to use when the org is unmapped.
     *   Callers MUST pass their own previous default. Before centralising, each
     *   copy of getGroupColor() had its own: most used 'org-academy' but the
     *   doublenode and mainevent pages used 'org-doublenode'/'org-mainevent'.
     *   Hard-coding one default here silently changed those two pages' unmapped
     *   rendering — caught in review. The parameter keeps per-page behaviour
     *   identical while still sharing the map.
     * @returns {string} CSS class name
     */
    function resolveColor(org, fallback) {
        return ORG_CLASSES[org] || fallback || 'org-academy';
    }

    global.LCARS_ORG = {
        resolve: resolve,
        resolveColor: resolveColor,
        STATIC_ORGS: STATIC_ORGS,
        ORG_CLASSES: ORG_CLASSES,
        // Exposed for tests: lets a harness assert the warn-once behaviour.
        _resetWarnings: function () { warned = {}; }
    };
})(typeof window !== 'undefined' ? window : this);
