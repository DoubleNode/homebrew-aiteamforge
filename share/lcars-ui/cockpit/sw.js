/*
 *  sw.js
 *  DoubleNode Dev-Team Infrastructure (AITeamForge)
 *
 *  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
 */

/* XACA-0161-005 — service worker for the iPad PWA cockpit route.
 *
 * READ THIS BEFORE CHANGING ANYTHING IN HERE.
 * ===========================================
 * Apple bug FB21416603 (OPEN, no fix): iPadOS 26 tears down a WebSocket to a
 * local-network host roughly one second after handshake, SPECIFICALLY in
 * `display: standalone` PWA mode -- exactly the mode this worker's manifest
 * turns on. The 2026-08-26 device spike (evaluation doc section 7.1) measured
 * 90s+ survival over `wss://` against a ~1s bug signature, so TLS is the
 * mitigation and it is the whole of the mitigation. The bug is still open
 * upstream; this is a posture to hold, not a problem that went away.
 *
 * A service worker is the single most dangerous place in this feature to get
 * that wrong, because a worker outlives the reasoning behind it. A cached
 * shell that opens a socket keeps opening that socket months after everyone
 * has forgotten why the scheme mattered. So this worker is built around three
 * structural guarantees rather than three conventions:
 *
 *   G1  IT DOES NOT RUN OUTSIDE TLS.
 *       A worker installed on `http://` is refused at install and any
 *       already-installed copy unregisters itself and deletes its caches.
 *       `http://localhost` is a secure context by spec and would otherwise
 *       register happily -- it is refused too, because a developer's
 *       localhost habits are how an http path gets normalised.
 *
 *   G2  IT NEVER CACHES THE COCKPIT DOCUMENT OR ANY SCRIPT.
 *       Caching is a fixed ALLOW-LIST of static assets authored by this
 *       subitem: the offline page, the manifest, the icons, the font. There
 *       is no runtime cache, no opportunistic `cache.put`, no stale-while-
 *       revalidate. Nothing the cockpit view loads can enter the cache, so no
 *       cached artefact can ever open a connection of any scheme.
 *
 *   G3  THE OFFLINE PAGE CANNOT CONNECT TO ANYTHING.
 *       `offline.html` ships zero JavaScript and carries a meta CSP of
 *       `script-src 'none'; connect-src 'none'`. It is not a degraded
 *       cockpit; it is a sign on a locked door.
 *
 * ON WEBSOCKETS AND SERVICE WORKERS, SO NOBODY RE-DERIVES IT:
 * a `ws:`/`wss:` handshake is NOT visible to `fetch` in a service worker --
 * the spec excludes it. This worker therefore cannot police the terminal
 * socket even if it wanted to. That is precisely why the guarantee above is
 * "the shell is never cached" rather than "the socket is checked": the only
 * enforceable control is refusing to serve the code that would open it.
 */

'use strict';

/* Bump on any change to PRECACHE. `activate` deletes every cache whose name
 * is not this one, so a bump is also the purge. */
const CACHE = 'lcars-cockpit-shell-v1';

/* G1. `self.location.protocol` is the worker script's own scheme, which is
 * always the registering page's origin scheme. */
const SECURE = self.location.protocol === 'https:';

/* G2. The complete set of URLs this worker may ever serve from cache.
 * Resolved to absolute at module scope so the fetch handler compares against
 * `request.url` without re-resolving per request.
 *
 * Deliberately absent, and it must stay that way:
 *   - the cockpit document (index.html) and every script it loads
 *   - anything under /terminal/ or /api/
 *   - the LCARS stylesheets, which change often and are not needed to render
 *     an offline sign
 * The font is here because the offline page is the one page that has to look
 * right with no network, and a fallback system font on an LCARS page reads as
 * a broken page rather than an intentional one. */
const PRECACHE = [
  './offline.html',
  './manifest.webmanifest',
  './icons/icon-192.png',
  './icons/apple-touch-icon-180x180.png',
  '/fonts/antonio/Antonio-Variable.woff2',
].map((p) => new URL(p, self.location).href);

const PRECACHE_SET = new Set(PRECACHE);
const OFFLINE_URL = new URL('./offline.html', self.location).href;

/* The worker's own scope, as an absolute URL prefix. Registration pins this
 * to /cockpit/ because the script lives at /cockpit/sw.js and no
 * `Service-Worker-Allowed` header widens it -- a worker cannot claim a scope
 * above its own path. That is a browser-enforced bound on the blast radius of
 * everything below, not a convention this file could get wrong. */
const SCOPE = self.registration ? self.registration.scope : self.location.href;

async function purgeEverything() {
  const names = await caches.keys();
  await Promise.all(names.map((n) => caches.delete(n)));
}

self.addEventListener('install', (event) => {
  if (!SECURE) {
    /* G1. Refuse to become the active worker on a non-TLS origin. Failing the
     * install event is what keeps a half-populated cache from existing at
     * all; the unregister below cleans up a worker installed by an older
     * build that did not have this guard. */
    event.waitUntil((async () => {
      await purgeEverything();
      if (self.registration && self.registration.unregister) {
        await self.registration.unregister();
      }
      throw new Error(
        'LCARS cockpit SW refuses to install over ' + self.location.protocol +
        ' -- TLS is the FB21416603 mitigation (evaluation doc section 7.1).'
      );
    })());
    return;
  }

  event.waitUntil((async () => {
    const cache = await caches.open(CACHE);
    /* Individual `add` calls rather than `addAll`, so one missing asset is a
     * named failure instead of an opaque rejection. Install still fails --
     * a partially populated shell cache is worse than none, because it
     * produces an offline page with a missing icon and no explanation. */
    for (const url of PRECACHE) {
      const response = await fetch(url, { cache: 'reload' });
      if (!response.ok) {
        throw new Error('precache failed (' + response.status + '): ' + url);
      }
      await cache.put(url, response);
    }
    await self.skipWaiting();
  })());
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    if (!SECURE) {
      await purgeEverything();
      if (self.registration && self.registration.unregister) {
        await self.registration.unregister();
      }
      return;
    }
    const names = await caches.keys();
    await Promise.all(
      names.filter((n) => n !== CACHE).map((n) => caches.delete(n))
    );
    /* Drop any cache entry that is no longer on the allow-list. Belt and
     * braces against a future edit that shrinks PRECACHE without bumping
     * CACHE: without this, a removed asset would keep being served. */
    const cache = await caches.open(CACHE);
    const entries = await cache.keys();
    await Promise.all(
      entries.filter((req) => !PRECACHE_SET.has(req.url))
             .map((req) => cache.delete(req))
    );
    await self.clients.claim();
  })());
});

self.addEventListener('fetch', (event) => {
  const request = event.request;

  /* Everything below is a decision to NOT call respondWith, which hands the
   * request straight to the network exactly as if no worker existed. That is
   * the default for every case this worker does not have an explicit reason
   * to touch. */
  if (!SECURE) return;
  if (request.method !== 'GET') return;

  let url;
  try {
    url = new URL(request.url);
  } catch (err) {
    return;
  }

  /* Same-origin https only. `ws:`/`wss:` never reach here (see the header
   * note) but the scheme check is kept so the invariant is readable at the
   * point it matters rather than only in a comment. */
  if (url.protocol !== 'https:') return;
  if (url.origin !== self.location.origin) return;

  /* The terminal proxy and the LCARS API are never mediated by this worker.
   * They are outside the /cockpit/ scope anyway, so this is redundant with a
   * browser-enforced bound -- it is here because "redundant with a rule you
   * have to go and read" is not the same as visible. */
  if (url.pathname.startsWith('/terminal/') || url.pathname.startsWith('/api/')) {
    return;
  }

  /* Navigations: network-first, and the ONLY fallback is the offline sign.
   * The response is never cached, so there is no version of the cockpit
   * document that can be served without a live server behind it. */
  if (request.mode === 'navigate') {
    event.respondWith((async () => {
      try {
        return await fetch(request);
      } catch (err) {
        const cached = await caches.match(OFFLINE_URL);
        if (cached) return cached;
        /* Cache miss on the offline page means the worker installed and then
         * had its storage evicted. Answer honestly rather than with a blank
         * page or a browser error the user will read as "the fleet is fine,
         * the app is broken". */
        return new Response(
          'NO ROUTE TO THE FLEET, and the offline shell is not cached.\n' +
          'Reconnect to the tailnet and reload.\n',
          {
            status: 503,
            headers: {
              'Content-Type': 'text/plain; charset=utf-8',
              'Cache-Control': 'no-store',
            },
          }
        );
      }
    })());
    return;
  }

  /* G2. Sub-resources: cache-first for allow-listed assets ONLY. Anything
   * else -- including every script and stylesheet the cockpit loads -- falls
   * through to the network untouched and is never written to the cache. */
  if (!PRECACHE_SET.has(url.href)) return;
  if (!url.href.startsWith(SCOPE) && !url.pathname.startsWith('/fonts/')) return;

  event.respondWith((async () => {
    const cached = await caches.match(url.href);
    if (cached) return cached;
    return fetch(request);
  })());
});

/* Kill switch. A worker is the hardest thing in a web app to get rid of once
 * it is wrong, so it ships with the means of its own removal:
 *   navigator.serviceWorker.controller.postMessage({type:'LCARS_COCKPIT_SW_KILL'})
 * Also reachable from `pwa.js`, which sends it automatically whenever it
 * finds a worker running on a non-TLS origin. */
self.addEventListener('message', (event) => {
  const data = event.data;
  if (!data || data.type !== 'LCARS_COCKPIT_SW_KILL') return;
  event.waitUntil((async () => {
    await purgeEverything();
    if (self.registration && self.registration.unregister) {
      await self.registration.unregister();
    }
    const windows = await self.clients.matchAll({ type: 'window' });
    windows.forEach((client) => client.postMessage({ type: 'LCARS_COCKPIT_SW_KILLED' }));
  })());
});
