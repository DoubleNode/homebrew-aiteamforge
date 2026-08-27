/*
 *  pwa.js
 *  DoubleNode Dev-Team Infrastructure (AITeamForge)
 *
 *  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
 */

/* XACA-0161-005 — PWA bootstrap for the cockpit route.
 *
 * WHAT THE COCKPIT VIEW (XACA-0161-004) HAS TO DO TO USE THIS
 * ===========================================================
 * Put the cockpit document at `lcars-ui/cockpit/index.html` and paste this
 * head block into it verbatim. The meta tags cannot be injected from
 * JavaScript -- iOS reads them when the document is parsed and again when the
 * user taps "Add to Home Screen", and a tag added later is not reliably seen:
 *
 *   <meta name="viewport"
 *         content="width=device-width, initial-scale=1, viewport-fit=cover">
 *   <meta name="theme-color" content="#000000">
 *   <link rel="manifest" href="./manifest.webmanifest">
 *
 *   <!-- iOS honours these, and they are NOT the same set as the spec's. -->
 *   <meta name="mobile-web-app-capable" content="yes">
 *   <meta name="apple-mobile-web-app-capable" content="yes">
 *   <meta name="apple-mobile-web-app-status-bar-style" content="black">
 *   <meta name="apple-mobile-web-app-title" content="Cockpit">
 *
 *   <link rel="apple-touch-icon" sizes="180x180"
 *         href="./icons/apple-touch-icon-180x180.png">
 *   <link rel="apple-touch-icon" sizes="167x167"
 *         href="./icons/apple-touch-icon-167x167.png">
 *   <link rel="apple-touch-icon" sizes="152x152"
 *         href="./icons/apple-touch-icon-152x152.png">
 *   <link rel="apple-touch-icon" sizes="120x120"
 *         href="./icons/apple-touch-icon-120x120.png">
 *
 *   <script src="./pwa.js" defer></script>
 *
 * Two of those choices are deliberate and worth not reverting:
 *
 *   `apple-mobile-web-app-status-bar-style: black`, not `black-translucent`.
 *   Translucent gives the edge-to-edge look, but it also puts the document
 *   UNDER the status bar, and the top ~20pt of a terminal pane disappearing
 *   behind the clock is a real defect on the one surface where every row of
 *   text matters. `viewport-fit=cover` is already set, so the upgrade to
 *   translucent is a one-word change once the layout handles
 *   `env(safe-area-inset-top)`.
 *
 *   BOTH `mobile-web-app-capable` and the `apple-` prefixed original. The
 *   unprefixed name is the current standard; the prefixed one is what
 *   shipping iPadOS still reads. Dropping either loses standalone mode on
 *   some version, and standalone mode is the entire point of the ticket.
 *
 * WHAT THIS FILE ACTUALLY DOES
 * ============================
 * 1. Registers the service worker -- but only over TLS. See the transport
 *    interlock below; that is the load-bearing part of this file.
 * 2. Marks the document with the current display mode so LCARS CSS can
 *    respond to standalone without any of it having to ask again.
 * 3. Publishes a `lcars-cockpit-transport` event so the cockpit view can
 *    render its own LCARS-correct warning rather than inheriting one from
 *    here.
 *
 * THE TRANSPORT INTERLOCK, AND WHY IT IS NOT MERELY HYGIENE
 * =========================================================
 * Apple bug FB21416603 (OPEN): iPadOS 26 FINs a WebSocket to a local-network
 * host about a second after handshake, specifically in `display: standalone`.
 * The 2026-08-26 device spike measured 90s+ survival over `wss://` against
 * that ~1s signature -- so on this route, plain http is not a lesser
 * configuration, it is the configuration in which the feature does not work
 * at all and fails in a way that looks like a bug in our code. This file
 * therefore refuses to install any offline capability outside TLS, and says
 * so out loud when it is running standalone, where there is no address bar to
 * reveal the scheme.
 */

(function () {
  'use strict';

  var doc = document;
  var root = doc.documentElement;

  var STANDALONE =
    (window.matchMedia && window.matchMedia('(display-mode: standalone)').matches) ||
    window.navigator.standalone === true;

  var SECURE = window.location.protocol === 'https:';

  root.classList.toggle('lcars-standalone', STANDALONE);
  root.dataset.lcarsDisplayMode = STANDALONE ? 'standalone' : 'browser';
  root.dataset.lcarsTransport = SECURE ? 'tls' : 'insecure';

  function announce(detail) {
    try {
      window.dispatchEvent(new CustomEvent('lcars-cockpit-transport', {
        detail: detail,
      }));
    } catch (err) {
      /* CustomEvent is universally available on any browser that has a
       * service worker; swallowing here only guards a truly ancient engine,
       * and a failed announcement must never take the page down. */
    }
  }

  /* An LCARS-red bar, injected only in the one case where the user has no
   * other way to find out: standalone mode has no address bar, so an
   * http:// cockpit looks identical to an https:// one right up until the
   * terminal socket dies after a second and the fault gets filed against the
   * bridge. Deliberately not shown in a normal browser tab, where the scheme
   * is visible and the cockpit view owns the chrome. */
  function insecureBanner() {
    if (!STANDALONE) return;
    var bar = doc.createElement('div');
    bar.setAttribute('role', 'alert');
    bar.setAttribute('data-lcars-transport-warning', '');
    bar.textContent =
      'INSECURE TRANSPORT — this cockpit was opened over ' +
      window.location.protocol +
      '. Terminal panes will be disconnected by iPadOS. Reopen over https.';
    bar.style.cssText = [
      'position:fixed', 'inset:0 0 auto 0', 'z-index:2147483647',
      'background:#ff6666', 'color:#000',
      'font:600 14px/1.35 Antonio,"Helvetica Neue",Arial,sans-serif',
      'letter-spacing:.06em', 'text-transform:uppercase',
      'padding:10px 14px', 'text-align:center',
    ].join(';');
    function attach() { (doc.body || root).appendChild(bar); }
    if (doc.body) attach();
    else doc.addEventListener('DOMContentLoaded', attach, { once: true });
  }

  if (!SECURE) {
    announce({ secure: false, standalone: STANDALONE, serviceWorker: 'refused' });
    insecureBanner();

    /* Do not merely skip registration -- actively tear down anything a
     * previous build (or a previous scheme) left installed. A worker that
     * survives the switch from https to http is the exact "cached shell that
     * outlives its reasoning" failure this subitem exists to prevent. */
    if ('serviceWorker' in window.navigator) {
      window.navigator.serviceWorker.getRegistrations().then(function (regs) {
        regs.forEach(function (reg) { reg.unregister(); });
      }).catch(function () { /* nothing actionable; never block the page */ });
    }
    if (window.caches && window.caches.keys) {
      window.caches.keys().then(function (names) {
        names.forEach(function (n) { window.caches.delete(n); });
      }).catch(function () { /* see above */ });
    }
    return;
  }

  if (!('serviceWorker' in window.navigator)) {
    announce({ secure: true, standalone: STANDALONE, serviceWorker: 'unsupported' });
    return;
  }

  /* Scope is pinned to this directory. The browser refuses a scope above the
   * worker script's own path unless the server sends `Service-Worker-Allowed`,
   * which it does not -- so /cockpit/ is enforced by the browser, not by this
   * argument. Passing it explicitly documents the intent and makes a future
   * move of the file an immediate, loud failure instead of a silent widening. */
  window.navigator.serviceWorker
    .register('./sw.js', { scope: './' })
    .then(function (reg) {
      announce({
        secure: true,
        standalone: STANDALONE,
        serviceWorker: 'registered',
        scope: reg.scope,
      });
    })
    .catch(function (err) {
      /* Registration failure costs the offline sign, nothing else: the
       * cockpit itself is network-only by design and works without a worker.
       * Report it and carry on. */
      announce({
        secure: true,
        standalone: STANDALONE,
        serviceWorker: 'failed',
        error: String(err && err.message ? err.message : err),
      });
    });
})();
