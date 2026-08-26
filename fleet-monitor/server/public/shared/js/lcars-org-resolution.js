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
 * The 5 reachable ones delegate here. Of the 9 dead, XACA-0971 removes SIX --
 * the remaining three are scoped to neither ticket and still carry the pre-fix
 * innerHTML sinks. Deadness here is a property of the DIRECTORY, not the
 * basename: `lcars2/*.html` loads `src="js/<name>.js"`, which resolves inside
 * lcars2/, so grepping for a basename reports the lcars/ twin as referenced
 * when nothing loads it. Resolve every script src before trusting either
 * answer.
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
     * Own-property test. Every map lookup in this module goes through it.
     *
     * Division codes arrive from the network, so `STATIC_ORGS['constructor']`
     * and friends are reachable input, not a theoretical concern: bare access
     * resolves up the prototype chain and yields a Function where the caller
     * expects a string.
     */
    function own(obj, key) {
        return !!obj && Object.prototype.hasOwnProperty.call(obj, key);
    }

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
        //
        //    own() rather than bare property access: a division code of
        //    "constructor" or "__proto__" hits Object.prototype and returns a
        //    Function or an Object, so resolve() would break its own
        //    @returns {string} contract and hand a non-string to className and
        //    to innerHTML — without tripping the tier-5 warn, because the
        //    truthiness test above would have "succeeded".
        if (own(teams, code) && teams[code] && teams[code].organization) {
            return teams[code].organization;
        }

        // 2. Registry PREFIX match — the division code is the first segment of a
        //    suffixed team id ("finance" -> "finance-personal"). This is the fix
        //    for the key mismatch described in the header; without it every
        //    suffixed team falls through to the hard-coded lists below.
        if (teams) {
            for (var id in teams) {
                // own(), not a second inline hasOwnProperty. This was the last
                // call site written by hand rather than routed through the
                // helper, which is why it read like the same guard as tiers 1
                // and 3 while being a separate implementation nothing tested.
                // for...in walks inherited enumerable keys, so without this a
                // prototype key with a dash suffix -- Object.prototype
                // ['finance-pwn'] = { organization: 'PWNED' } -- is matched by
                // the prefix test below and returned as a real organization.
                if (!own(teams, id)) { continue; }
                if (id.indexOf(code + '-') === 0 && teams[id] && teams[id].organization) {
                    return teams[id].organization;
                }
            }
        }

        // 3. Static map for teams that are not registered.
        //    own() proves the KEY is present, not that the VALUE is usable: a
        //    malformed entry would otherwise be returned as-is and break the
        //    @returns {string} contract the same way a prototype lookup did.
        //
        //    NOT reachable today, and the tests say so rather than implying
        //    otherwise: STATIC_ORGS is frozen with all-truthy values, so no
        //    test can construct a malformed entry to drive this branch. What
        //    IS tested is the precondition that makes it unreachable -- every
        //    value being a usable string -- so adding a malformed entry fails
        //    loudly instead of silently relying on this guard.
        if (own(STATIC_ORGS, code) && STATIC_ORGS[code]) {
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
        return (own(ORG_CLASSES, org) && ORG_CLASSES[org]) || fallback || 'org-academy';
    }

    /**
     * Operator-facing hint for an organization heading, or '' if none is needed.
     *
     * XACA-0970-012: the console.warn above names the unresolved division and the
     * exact remediation, but an operator looking at the dashboard sees only the
     * word UNKNOWN and has no reason to open the console. This surfaces the same
     * remediation as a tooltip on the heading.
     *
     * The heading is deliberately NOT renamed to 'UNREGISTERED'. Before this
     * ticket, a registered-but-suffixed team landed in this bucket, so
     * "unregistered" would have described most of its contents. The registry
     * prefix match now resolves those, so what remains here is genuinely
     * unresolvable -- a division code we cannot account for, which may well be a
     * typo rather than an unregistered team. Naming it UNREGISTERED would assert
     * a cause we have not established.
     */
    var UNKNOWN_HINT =
        'No organization could be resolved for these divisions. Each unresolved ' +
        'division code is named in the browser console, along with the file and ' +
        'the entry to add. Register the team, or add it to STATIC_ORGS in ' +
        'shared/js/lcars-org-resolution.js.';

    function remediationHint(org) {
        return org === 'UNKNOWN' ? UNKNOWN_HINT : '';
    }

    /**
     * Attach the remediation to an organization heading, or do nothing.
     *
     * Owns the whole presentation policy, not just the string. The first cut of
     * this set `el.title` from six lines pasted into each of the five pages —
     * the string and the condition were centralised but the *decision to render
     * it as a tooltip* was not, which is a smaller version of the duplication
     * this whole ticket exists to remove.
     *
     * `title` alone was also mouse-only: the heading is a plain <div>, so it
     * takes no focus, and a title on a non-interactive element is announced
     * inconsistently by screen readers. The remediation was therefore invisible
     * to exactly the operators least able to guess it. The heading now takes
     * focus and carries an aria-describedby pointing at the same text, so
     * keyboard and AT users reach it by the same route as everyone else.
     *
     * @param {Element} el   the .organization-header element
     * @param {string}  org  organization name as returned by resolve()
     * @returns {boolean} whether a hint was attached
     */
    function decorateHeading(el, org) {
        if (!el || typeof el.setAttribute !== 'function') { return false; }

        var hint = remediationHint(org);
        if (!hint) { return false; }

        el.title = hint;
        el.setAttribute('tabindex', '0');

        var doc = el.ownerDocument;
        if (doc && typeof doc.createElement === 'function') {
            var id = 'org-hint-' + String(org).toLowerCase().replace(/[^a-z0-9]+/g, '-');
            var note = doc.createElement('span');
            note.className = 'organization-hint';
            note.id = id;
            // textContent, never innerHTML: this string is a literal today, and
            // that is exactly the assumption that stops being true later.
            note.textContent = hint;
            el.appendChild(note);
            el.setAttribute('aria-describedby', id);
        }
        return true;
    }

    // Exported by reference, so without this any later script on the page could
    // rewrite org resolution for every dashboard. Frozen rather than copied so a
    // stray write fails loudly in strict mode instead of landing on a clone that
    // silently diverges from the map actually being consulted.
    if (Object.freeze) {
        Object.freeze(STATIC_ORGS);
        Object.freeze(ORG_CLASSES);
        Object.freeze(PREFIX_ORGS);
    }

    var API = {
        resolve: resolve,
        resolveColor: resolveColor,
        remediationHint: remediationHint,
        decorateHeading: decorateHeading,
        STATIC_ORGS: STATIC_ORGS,
        ORG_CLASSES: ORG_CLASSES,
        // Exposed for tests: lets a harness assert the warn-once behaviour.
        _resetWarnings: function () { warned = {}; }
    };

    // Freeze the namespace itself, not just the maps inside it. The first cut
    // froze STATIC_ORGS and ORG_CLASSES and left this object writable, so
    // `LCARS_ORG.resolve = function () { return 'DEVTEAM'; }` still succeeded --
    // the comment above described a threat the code only half-closed. Review
    // caught it; the maps were the harder-looking half and the easier half was
    // the one that mattered.
    if (Object.freeze) { Object.freeze(API); }

    global.LCARS_ORG = API;
})(typeof window !== 'undefined' ? window : this);
