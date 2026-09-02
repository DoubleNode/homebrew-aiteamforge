//
//  lcars-sound.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

/**
 * LCARS Sound Manager
 * Procedural sound effects for LCARS UI interactions.
 * No external audio files required — tones are generated as WAV data URIs
 * and played via HTML5 Audio elements.
 *
 * Uses Audio elements instead of Web Audio API oscillators because
 * iTerm2's WKWebView (behind tmux) silently swallows AudioContext.destination
 * output while HTML5 <audio> playback works correctly. (XACA-1022-007
 * evaluated a Web Audio hybrid and deferred it — see the "Web Audio hybrid
 * evaluation" comment block below _playWav for the reasoning and the
 * trigger condition for revisiting.)
 *
 * Exposes global: LCARSSound
 *
 * Usage:
 *   LCARSSound.play('nav')    // sidebar navigation chirp
 *   LCARSSound.play('action') // card/button action beep
 *   LCARSSound.play('alert')  // confirmation/status alert tone
 *   LCARSSound.toggleMute()
 *   LCARSSound.isMuted()      // returns boolean
 */

(function () {
    'use strict';

    // -------------------------------------------------------------------------
    // WAV generation — builds PCM data URIs from tone definitions
    // -------------------------------------------------------------------------
    var SAMPLE_RATE = 44100;

    /**
     * Encode a Float32 sample buffer as a mono 16-bit WAV data URI.
     */
    function _encodeWav(samples) {
        var numSamples = samples.length;
        var bitsPerSample = 16;
        var blockAlign = bitsPerSample / 8;
        var byteRate = SAMPLE_RATE * blockAlign;
        var dataSize = numSamples * blockAlign;
        var buffer = new ArrayBuffer(44 + dataSize);
        var view = new DataView(buffer);

        // RIFF header
        _writeStr(view, 0, 'RIFF');
        view.setUint32(4, 36 + dataSize, true);
        _writeStr(view, 8, 'WAVE');
        _writeStr(view, 12, 'fmt ');
        view.setUint32(16, 16, true);            // chunk size
        view.setUint16(20, 1, true);             // PCM format
        view.setUint16(22, 1, true);             // mono
        view.setUint32(24, SAMPLE_RATE, true);
        view.setUint32(28, byteRate, true);
        view.setUint16(32, blockAlign, true);
        view.setUint16(34, bitsPerSample, true);
        _writeStr(view, 36, 'data');
        view.setUint32(40, dataSize, true);

        // PCM samples (clamped to [-1, 1])
        for (var i = 0; i < numSamples; i++) {
            var s = Math.max(-1, Math.min(1, samples[i]));
            view.setInt16(44 + i * 2, Math.floor(s * 32767), true);
        }

        // Base64 encode
        var bytes = new Uint8Array(buffer);
        var binary = '';
        for (var j = 0; j < bytes.length; j++) {
            binary += String.fromCharCode(bytes[j]);
        }
        return 'data:audio/wav;base64,' + btoa(binary);
    }

    function _writeStr(view, offset, str) {
        for (var i = 0; i < str.length; i++) {
            view.setUint8(offset + i, str.charCodeAt(i));
        }
    }

    /**
     * Generate samples for a sine tone with exponential decay.
     * Returns Float32 values added into the provided buffer at the given offset.
     */
    function _addTone(buf, offsetSamples, freq, durationSec, gain) {
        var count = Math.floor(durationSec * SAMPLE_RATE);
        // Exponential decay constant — hoisted out of the per-sample loop (XACA-0533 review).
        // Approximates Web Audio exponentialRampToValue(0.001, duration).
        var decayRate = -Math.log(0.001) / durationSec;
        for (var i = 0; i < count; i++) {
            var t = i / SAMPLE_RATE;
            var envelope = gain * Math.exp(-decayRate * t);
            var sample = Math.sin(2 * Math.PI * freq * t) * envelope;
            var idx = offsetSamples + i;
            if (idx < buf.length) {
                buf[idx] += sample;
            }
        }
    }

    /**
     * Generate samples for a frequency sweep with exponential decay.
     * Frequency ramps exponentially from freqStart to freqEnd over durationSec.
     */
    function _addSweep(buf, offsetSamples, freqStart, freqEnd, durationSec, gain) {
        var count = Math.floor(durationSec * SAMPLE_RATE);
        var logStart = Math.log(freqStart);
        var logEnd = Math.log(freqEnd);
        var decayRate = -Math.log(0.001) / durationSec;
        var phase = 0;

        for (var i = 0; i < count; i++) {
            var t = i / SAMPLE_RATE;
            var frac = t / durationSec;
            // Exponential frequency interpolation (matches Web Audio exponentialRamp)
            var freq = Math.exp(logStart + (logEnd - logStart) * frac);
            var envelope = gain * Math.exp(-decayRate * t);
            phase += (2 * Math.PI * freq) / SAMPLE_RATE;
            var sample = Math.sin(phase) * envelope;
            var idx = offsetSamples + i;
            if (idx < buf.length) {
                buf[idx] += sample;
            }
        }
    }

    // -------------------------------------------------------------------------
    // Sound definitions — modeled on TNG LCARS panel sounds
    // -------------------------------------------------------------------------

    /** Master volume applied during WAV generation (matches original 0.35 gain) */
    var MASTER_VOLUME = 0.35;

    /**
     * Nav chirp — TNG panel press.
     * Fast ascending frequency sweep (~1975→2600Hz in 60ms) with a softer
     * body tone underneath. The sweep is the signature "bip" heard when
     * officers touch LCARS panels on the Enterprise-D bridge.
     */
    function _generateNav() {
        var duration = 0.08; // longest component + margin
        var len = Math.ceil(duration * SAMPLE_RATE);
        var buf = new Float32Array(len);

        // Primary: fast ascending sweep — the characteristic LCARS chirp
        _addSweep(buf, 0, 1975, 2600, 0.06, 0.55);
        // Body: softer mid-range tone gives it weight
        _addTone(buf, 0, 1200, 0.04, 0.2);
        // Sparkle: faint high harmonic for that digital crispness
        _addSweep(buf, 0, 3950, 5200, 0.05, 0.08);

        // Apply master volume
        for (var i = 0; i < len; i++) buf[i] *= MASTER_VOLUME;
        return _encodeWav(buf);
    }

    /**
     * Action beep — TNG data acknowledgment / computer response.
     * Clean high-mid tone (~1500Hz) with sharp attack and quick decay,
     * plus a subtle 3rd harmonic. The classic "boop" when the computer
     * confirms a command or displays requested data.
     */
    function _generateAction() {
        var duration = 0.12;
        var len = Math.ceil(duration * SAMPLE_RATE);
        var buf = new Float32Array(len);

        // Primary: clean 1500Hz — the TNG acknowledgment pitch
        _addTone(buf, 0, 1500, 0.09, 0.5);
        // 3rd harmonic adds the subtle digital texture
        _addTone(buf, 0, 4500, 0.05, 0.07);
        // Sub-tone for body
        _addTone(buf, 0, 750, 0.06, 0.12);

        for (var i = 0; i < len; i++) buf[i] *= MASTER_VOLUME;
        return _encodeWav(buf);
    }

    /**
     * Alert tone — TNG comm chirp / confirmation.
     * Two-note ascending sequence (C6→E6, a major third interval)
     * with a brief gap between notes. Evokes the communicator chirp
     * and the "task complete" confirmation heard throughout TNG.
     */
    function _generateAlert() {
        var duration = 0.25; // two notes with gap
        var len = Math.ceil(duration * SAMPLE_RATE);
        var buf = new Float32Array(len);

        var noteOffset = Math.floor(0.12 * SAMPLE_RATE); // 120ms gap before second note

        // First note: C6 (1046.5 Hz)
        _addTone(buf, 0, 1047, 0.08, 0.5);
        _addTone(buf, 0, 2094, 0.06, 0.08);
        // Second note: E6 (1318.5 Hz) — major third above
        _addTone(buf, noteOffset, 1318, 0.10, 0.45);
        _addTone(buf, noteOffset, 2637, 0.07, 0.07);

        for (var i = 0; i < len; i++) buf[i] *= MASTER_VOLUME;
        return _encodeWav(buf);
    }

    // -------------------------------------------------------------------------
    // Pre-generated WAV cache — built lazily on first play
    // -------------------------------------------------------------------------
    var _wavCache = {};

    function _ensureWavCache() {
        if (_wavCache.nav) return;
        _wavCache.nav = _generateNav();
        _wavCache.action = _generateAction();
        _wavCache.alert = _generateAlert();
    }

    /**
     * Play a cached WAV via a fresh Audio element.
     * Each call creates a fresh Audio instance so overlapping plays work.
     * Returns the Audio element that was played, or null if nothing played
     * (unknown type, or a synchronous playback error). The returned handle
     * exists so a future change (tracked separately, NOT this subitem) can
     * silence an in-flight tone from a pointercancel handler.
     */
    function _playWav(type) {
        _ensureWavCache();
        var uri = _wavCache[type];
        if (!uri) return null;
        var audio;
        try {
            audio = new Audio(uri);
            audio.volume = 1.0;
            var p = audio.play();
            if (p && p.catch) {
                p.catch(function () {
                    // Autoplay blocked — silently ignore
                });
            }
        } catch (e) {
            console.warn('[LCARSSound] Audio playback error:', e);
            return null;
        }
        return audio;
    }

    // -------------------------------------------------------------------------
    // XACA-1022-007: Web Audio hybrid evaluation — EVALUATED AND DEFERRED,
    // not implemented. This block documents the decision so it isn't
    // re-litigated from scratch, and states the trigger condition for
    // revisiting it. No code below this comment executes.
    //
    // WHAT WAS ACTUALLY MEASURED (XACA-1022-006, on-device: iPhone, iOS 18.7,
    // Safari 27.0, via the A/B battery in probe/xaca-1022-audio-latency.html):
    //
    //   Decode cost is real and scales with size (construction-only batch,
    //   20 samples/tone): nav 9,490B -> 268.45ms; action 14,194B -> 282.75ms;
    //   alert 29,482B -> 337.25ms. `new Audio()` construction itself is
    //   ~0.1ms — the cost is decode-availability, not the constructor call.
    //   XACA-1022-006 pre-constructed and pooled Audio elements per sound
    //   type specifically to move that 268-337ms off the per-press hot path.
    //
    //   It did NOT make sound arrive sooner. Rounds 3-15 of the serialized
    //   A/B battery (warm-up rounds dropped): play()-promise resolution was
    //   ~100ms FASTER pooled (65ms vs 165ms), while `progress` — first
    //   observed currentTime > 0, the real end-to-end "is it audible yet"
    //   signal — was ~97ms SLOWER pooled (434ms vs 337ms). The probe's own
    //   headline delta was +3.8%: pooled was slower, not faster, end to end.
    //
    //   The gap between promise-resolution and actual audio progression was
    //   consistently ~369ms pooled vs ~172ms baseline across all 13 rounds.
    //   A `currentTime = 0` seek penalty on reused elements was considered
    //   and REJECTED by the data: the first four pooled draws are fresh,
    //   never-played elements, and the later reuses were *faster* (~439ms)
    //   than first-use (~590ms) — the opposite of a seek cost.
    //
    //   Reading: iOS audio-pipeline start latency dominates time-to-audible
    //   and is paid either way — pooling moved decode work off the critical
    //   path without moving the moment sound actually starts. XACA-1022-006
    //   was reverted on this evidence; the dispatch fix (pointerdown timing,
    //   001-004) shipped alone. Do not re-add pooling without a NEW number
    //   showing it moves the `progress` timestamp, not just promise
    //   resolution — promise resolution is not a proxy for audible sound on
    //   this platform, per the measurement above.
    //
    // WHAT A WEB AUDIO PATH WOULD STILL NEED TO PROVE:
    //   Decode each sound ONCE into an AudioBuffer (via
    //   AudioContext.decodeAudioData), then per press create a fresh
    //   BufferSource, connect it, and call start(0). BufferSource creation
    //   and scheduling are near-zero-cost compared to <audio> element
    //   playback-start, and start() can be scheduled against
    //   AudioContext.currentTime, a more precise clock than anything
    //   HTMLMediaElement exposes. But the measurement above already
    //   disproved the parallel claim for <audio> — "remove decode cost from
    //   the hot path" did not reduce time-to-audible there, because decode
    //   was never the bottleneck. The open question is therefore NOT "does
    //   Web Audio avoid decode cost" (it does) but whether iOS's underlying
    //   audio-pipeline start latency is beatable with `<audio>` at all, or
    //   is a floor that AudioContext's separate output path can actually
    //   sit below. That is unmeasured. Nothing here shows Web Audio wins —
    //   only that <audio> pooling, tried and measured, did not.
    //
    // WHAT IT COSTS:
    //   - A second playback code path to maintain alongside <audio> (this
    //     file already carries two sound-classification paths for
    //     pointerdown/click — a third dimension for playback itself is
    //     real, ongoing complexity, not a one-time cost).
    //   - The AudioContext resume()/user-gesture dance: a fresh
    //     AudioContext starts 'suspended' and must be resume()'d inside a
    //     user-gesture handler before it will produce output — the same
    //     class of unlock problem XACA-1022-006's (reverted) Audio pool had
    //     to solve for <audio> elements. The problem doesn't go away by
    //     switching APIs; it moves.
    //   - The WKWebView risk, which is the deciding factor: this file's own
    //     header documents that iTerm2's WKWebView (the lcars-ui cockpit
    //     surface) "silently swallows AudioContext.destination output" —
    //     resume() can report success, buffers can decode, start() can be
    //     called, and NOTHING is heard, with no error, no rejected promise,
    //     nothing to catch. That is a strictly worse failure mode than the
    //     current one: a working HTML5 <audio> engine replaced by a
    //     Web-Audio path that *looks* complete in code review and testing,
    //     then plays silently on the one desktop surface this app runs on
    //     unattended, in production, indefinitely.
    //
    // THE ASYMMETRY THAT MAKES A SINGLE VERDICT WRONG:
    //   The AudioContext-swallowing environment (iTerm2 WKWebView) and the
    //   iPhone-measured environment (mobile Safari, via Fleet Monitor) are
    //   DIFFERENT surfaces sharing this one file. Mobile Safari's
    //   AudioContext works correctly; iTerm2's WKWebView is exactly where
    //   it's unsafe. "Adopt everywhere" ignores the WKWebView risk. "Adopt
    //   nowhere, forever" forecloses a latency question that is still open
    //   on the surface this ticket was filed against — the <audio> pooling
    //   experiment ruled out decode cost as the cause, it did not rule out
    //   every possible Web Audio benefit. Both blanket answers are probably
    //   wrong; this file cannot safely tell surfaces apart today (no
    //   capability/output check exists here, and UA-sniffing "is this
    //   iTerm2" is explicitly rejected below).
    //
    // RECOMMENDATION: DEFER on both surfaces. Do not adopt unconditionally,
    // and do not build a speculative hybrid without a number that justifies
    // it. The on-device measurement that now exists (above) closed the
    // "decode cost is the bottleneck" theory for <audio> — it did not open
    // a case for Web Audio, because no one has yet instrumented an actual
    // AudioContext/BufferSource path on the target device to see whether
    // its start-to-audible latency differs from <audio>'s at all.
    //
    // TRIGGER CONDITION for revisiting — both of these, not either alone:
    //   1. A real AudioContext/BufferSource prototype (not the reverted
    //      <audio> pool — a different API) is instrumented with the same
    //      "first observed progress" methodology as the probe's A/B battery,
    //      on a real target device, and its time-to-audible is measurably
    //      lower than the pooled/baseline `<audio>` numbers above.
    //   2. That win is confirmed to survive the WKWebView environment, or
    //      the hybrid is scoped to exclude it via a genuine capability/
    //      output check (see below) — not shipped blind to both surfaces.
    //   If both hold, the recommended shape is: adopt Web Audio ONLY where
    //   proven, gated behind a genuine capability/output check (e.g.
    //   resume() the context, play a near-silent probe buffer, and verify
    //   currentTime actually advances / an audible-confirmation signal is
    //   observed — NOT navigator.userAgent string matching, which is
    //   fragile and was rejected here for the same reason the click handler
    //   above rejected MouseEvent.detail sniffing). HTML5 <audio> MUST
    //   remain the unconditional fallback — whenever the capability check
    //   does not PROVE the AudioContext path is working, fail safe to
    //   <audio>, never to silence. Never adopt Web Audio on lcars-ui at all
    //   unless this same proof is obtained for the iTerm2 WKWebView
    //   specifically (which today's evidence says it will not be).
    // -------------------------------------------------------------------------

    // -------------------------------------------------------------------------
    // Mute state — persisted to localStorage
    // -------------------------------------------------------------------------
    var STORAGE_KEY = 'lcars-sound-muted';

    // localStorage can throw (Private Browsing, disabled storage, SecurityError).
    // Guard every access so a throw never aborts engine init before
    // window.LCARSSound is exported. (XACA-0533 review)
    function _lsGet(key) {
        try { return localStorage.getItem(key); }
        catch (e) { return null; }
    }
    function _lsSet(key, val) {
        try { localStorage.setItem(key, val); }
        catch (e) { /* storage unavailable — mute pref won't persist; non-fatal */ }
    }

    var _muted = _lsGet(STORAGE_KEY) === 'true';

    function _updateToggleUI() {
        var pill = document.getElementById('sound-toggle');
        if (pill) {
            pill.classList.toggle('sound-muted', _muted);
            pill.setAttribute('aria-pressed', _muted ? 'true' : 'false'); // XACA-0533 review: expose mute state to screen readers
        }
        var label = document.getElementById('sound-status');
        if (label) {
            label.textContent = _muted ? 'MUTED' : 'SOUND';
        }
    }

    // -------------------------------------------------------------------------
    // Public API
    // -------------------------------------------------------------------------

    var SOUND_TYPES = { nav: true, action: true, alert: true };

    var LCARSSound = {

        /**
         * Play a sound by type: 'nav', 'action', or 'alert'.
         * Silently no-ops if muted.
         */
        play: function (type) {
            if (_muted) { return; }
            if (!SOUND_TYPES[type]) {
                console.warn('[LCARSSound] Unknown sound type:', type);
                return;
            }
            _playWav(type);
        },

        mute: function () {
            _muted = true;
            _lsSet(STORAGE_KEY, 'true');
            _updateToggleUI();
        },

        unmute: function () {
            _muted = false;
            _lsSet(STORAGE_KEY, 'false');
            _updateToggleUI();
        },

        toggleMute: function () {
            if (_muted) {
                LCARSSound.unmute();
                // Play a confirmation sound so user knows it's on
                LCARSSound.play('nav');
            } else {
                LCARSSound.mute();
            }
        },

        isMuted: function () {
            return _muted;
        },

        /**
         * Diagnostic: return system state for debugging.
         */
        debug: function () {
            _ensureWavCache();
            var info = {
                muted: _muted,
                wavCached: !!_wavCache.nav,
                navUriLen: _wavCache.nav ? _wavCache.nav.length : 0,
                actionUriLen: _wavCache.action ? _wavCache.action.length : 0,
                alertUriLen: _wavCache.alert ? _wavCache.alert.length : 0
            };
            console.log('[LCARSSound] Debug:', JSON.stringify(info));
            var label = document.getElementById('sound-status');
            if (label) {
                var orig = label.textContent;
                label.textContent = info.wavCached ? 'WAV-OK' : 'NO-WAV';
                setTimeout(function () { label.textContent = orig; }, 1500);
            }
            return info;
        }
    };

    // -------------------------------------------------------------------------
    // Global interaction interceptor
    // Classifies interaction targets and plays the appropriate sound.
    // Uses event delegation — does NOT attach to individual elements.
    // Does NOT interfere with existing click/pointer handlers.
    //
    // XACA-1022: sound now fires on `pointerdown` (press) instead of waiting
    // for `click` (release), so the tone starts at the moment of contact
    // instead of ~tens-to-hundreds of ms later. The trailing `click` that the
    // browser still fires for that same press is deduped below so it doesn't
    // play a second time. A `click` path is kept as a fallback for
    // activations that never produce a `pointerdown` at all — keyboard
    // Enter/Space on a focusable element, or a programmatic `.click()` call —
    // so non-pointer activation still gets sound (XACA-1022-002).
    // -------------------------------------------------------------------------

    /**
     * Classify an interaction target into a sound type ('nav' | 'alert' |
     * 'action') AND the matched container element, or null if it doesn't
     * map to a sound. Shared by the pointerdown, keydown, and click
     * delegates below so the closest() branches exist in exactly one place
     * instead of being duplicated per listener.
     *
     * Returning the container (not just the type) is what lets the dedupe
     * guard below compare "did this event resolve to the same LOGICAL
     * control" instead of raw e.target identity (XACA-1022-016/017): a DOM
     * mutation/retarget between pointerdown and its trailing click (a
     * hover-swapped icon, a node replaced under the pointer), or a `<label
     * for>` whose associated control click lands on a different node,
     * still resolves to the same container via closest(), so the guard
     * survives it instead of false-double-playing or wrongly swallowing.
     */
    function _classifyMatch(target) {
        var container;

        // Nav sounds — sidebar navigation
        container =
            target.closest('.sidebar-button') ||
            target.closest('.sidebar-submenu-item') ||
            target.closest('.analytics-page-pill') ||   // Fleet Monitor: analytics page-nav pills
            target.closest('.sidebar-link');             // Fleet Monitor: dashboard-switcher links
        if (container) {
            return { type: 'nav', container: container };
        }

        // Alert sounds — status changes and priority/category/tag clickables
        container =
            target.closest('.status-btn') ||
            target.closest('.status-indicator') ||
            target.closest('[data-priority]') ||
            target.closest('[data-category]') ||
            target.closest('[data-tag]') ||
            target.closest('.candy-pill:not([data-candy])') ||  // Fleet Monitor: interactive pills only — metric display pills carry data-candy (XACA-0533 review)
            // XACA-1022-016 (UX dissent): #fleet-offline-indicator is a `.legend-pill`, so the
            // normalization of `.legend-pill` to 'action' below would otherwise sweep it into the
            // general-button tone. It is not a button: its own markup comment in
            // lcars-dashboard.html describes it as a persistent OFFLINE cue "escalating to a red
            // alert state above zero", replacing the red-alert cue the removed OFFLINE candy pill
            // carried. That is alert-shaped by this group's own definition (status changes), so it
            // is matched HERE, ahead of the action branch, to keep its status semantics.
            // Inert on the lcars-ui cockpit (the id exists only in Fleet Monitor markup), which is
            // why both engine copies stay byte-identical.
            target.closest('#fleet-offline-indicator') ||
            target.closest('#sound-toggle');
        if (container) {
            // sound-toggle is handled by toggleMute directly; skip double-play
            if (target.closest('#sound-toggle')) {
                return null;
            }
            return { type: 'alert', container: container };
        }

        // Action sounds — cards, toggles, general buttons
        //
        // XACA-1022-015: `.legend-pill` is normalized to 'action' here for
        // BOTH engine copies. Fleet Monitor previously ALSO listed it in the
        // alert-group condition above (XACA-0963), which meant the SAME
        // visual pill sounded 'alert' on Fleet Monitor and 'action' on the
        // lcars-ui cockpit — a real cross-surface auditory inconsistency.
        // Per this file's own documented group semantics (alert = status
        // changes and priority/category/tag clickables; action = cards,
        // toggles, general buttons), the pills this affects (SETTINGS /
        // ADMIN / SOUND on Fleet Monitor; TEAM / KANBAN / DATA / VIEWSCREEN
        // on the cockpit) are general buttons, not status changes — so
        // 'action' is the correct target and the XACA-0963 alert-group line
        // is removed rather than kept. This is a user-perceptible behaviour
        // change on Fleet Monitor: those three pills go alert -> action.
        // This is also now the ONLY `.legend-pill` check in either file —
        // it was previously unreachable dead code in fleet-monitor because
        // the alert-group condition, evaluated first, always won.
        container =
            target.closest('.kanban-card') ||
            target.closest('.card') ||
            target.closest('.legend-pill') ||
            target.closest('.toggle-columns-btn') ||
            target.closest('.toast-close') ||
            target.closest('.summary-card') ||          // Fleet Monitor: overview summary cards
            target.closest('.btn-lcars') ||             // Fleet Monitor: LCARS-styled buttons
            target.closest('.lcars-button') ||          // Fleet Monitor: settings CLASSIC UI button
            target.closest('.kiosk-fab');                // Fleet Monitor: kiosk mode FAB
        if (container) {
            return { type: 'action', container: container };
        }

        return null;
    }

    /**
     * Thin wrapper over _classifyMatch for callers that only need the sound
     * type, not the matched container.
     */
    function _classifySound(target) {
        var match = _classifyMatch(target);
        return match ? match.type : null;
    }

    // XACA-1022: press/click dedupe guard.
    //
    // A single physical press produces `pointerdown` (immediate) followed,
    // after release, by `click` (0–300ms later depending on platform). We
    // play on `pointerdown` for latency, so the trailing `click` for that
    // *same* interaction must be skipped, not played again.
    //
    // Rejected: a bare boolean ("a pointerdown happened"). It can't tell "the
    // click I'm looking at IS the trailing click of that pointerdown" apart
    // from "some click arrived eventually" — if the pointerdown's own click
    // never fires (finger drags off and the gesture is cancelled/becomes a
    // scroll — see the pointercancel handler below), a plain flag is left
    // set and wrongly swallows the *next*, unrelated click on some other
    // element.
    //
    // Rejected: clearing the flag with setTimeout(). The delay is a guess —
    // too short and a legitimately slow click on a real device slips past it
    // and double-plays; too long and it risks swallowing a fast, deliberate
    // second press. Either way it's a race against real input timing, not a
    // deterministic fact about the DOM.
    //
    // XACA-1022-016/017: originally this guard compared raw `e.target`
    // IDENTITY between pointerdown and click. Two failure modes fall out of
    // that: (1) a DOM mutation/retarget between the two events (a
    // hover-swapped icon, a node replaced under the pointer) hands the click
    // a DIFFERENT target object for the SAME physical press, causing a false
    // double-play; (2) a mouse pointerdown followed by release OUTSIDE the
    // pressed element fires neither a matching click NOR pointercancel, so
    // the guard could stay armed on that element indefinitely and later
    // swallow an unrelated, real click on it (most concerningly a keyboard
    // activation, which never gets its sound as a result).
    //
    // Chosen: remember the matched CONTAINER — the element `_classifyMatch`'s
    // winning closest() call returned — not the raw event target. A click's
    // own container, computed the same way, only counts as "already played"
    // when it is IDENTICAL (===) to the pending container: this survives a
    // same-press retarget because both events resolve through the same
    // closest() selector to the same logical control. The guard is consumed
    // (cleared) the instant ANY click is evaluated against it, whether or
    // not it matched, so it can never persist forward to swallow a later,
    // unrelated click. `pointercancel` (browser takes the gesture over as a
    // scroll/pan) clears it directly for the case where no click ever
    // follows; `pointerup` landing on a DIFFERENT container closes the
    // remaining gap — a press that ends elsewhere, with neither a matching
    // click nor a pointercancel ever coming (XACA-1022-017).
    var _pendingPointerId = null;
    var _pendingContainer = null;

    document.addEventListener('pointerdown', function (e) {
        if (_muted) { return; }

        // XACA-1022-003: only the primary mouse button / primary touch or
        // pen contact triggers sound. Right-click, middle-click, and
        // secondary touch points (multi-touch) stay silent.
        if (e.button !== 0 || !e.isPrimary) { return; }

        var match = _classifyMatch(e.target);
        if (!match) { return; }

        // XACA-1022-003: fire immediately rather than waiting to see whether
        // the gesture turns into a scroll/pan — that wait IS the latency
        // this ticket removes, so we deliberately do not add one.
        //
        // Tradeoff this creates: on touch, a scroll gesture that STARTS with
        // a finger down directly on a sound-mapped element (e.g. beginning a
        // column-scroll drag on top of a kanban card) still produces one
        // chirp at the moment of contact, because by the time `pointercancel`
        // (below) tells us the gesture became a scroll, the tone has already
        // started. We accept this: it's strictly narrower than "any swipe
        // beeps" (a swipe starting on empty background never matches
        // _classifyMatch and stays silent, before and after this change),
        // and closing it fully would mean delaying every press to disambiguate
        // tap-from-scroll — defeating the point of this ticket.
        //
        // We can't cut an in-flight tone short from here either way: `_playWav()`
        // (subitems 006/007's audio pipeline, out of scope for this change)
        // creates a fire-and-forget Audio element and returns nothing, so
        // there's no handle to `.pause()` on cancel. A fast-follow could have
        // `_playWav` return its Audio element so a `pointercancel` handler
        // could silence it early, but that's a change to the audio pipeline
        // and belongs with 006/007, not here.
        _pendingPointerId = e.pointerId;
        _pendingContainer = match.container;

        LCARSSound.play(match.type);
    }, true); // capture phase — mirrors the click delegate below

    document.addEventListener('pointerup', function (e) {
        // XACA-1022-017: a mouse pointerdown followed by release OUTSIDE the
        // pressed element (drag-away) fires neither a matching `click` (the
        // browser only fires `click` when press and release resolve to the
        // same target, or a shared ancestor) NOR `pointercancel` (the
        // browser never took the gesture over as a scroll/pan). Left alone,
        // the guard armed by that pointerdown would stay set indefinitely
        // and could later swallow an unrelated, real click — most
        // concerningly a keyboard Enter/Space activation of that SAME
        // element, silently dropping a real keyboard sound.
        //
        // Only act if this pointerup belongs to the pointer that armed the
        // guard, and only clear when it resolves to a DIFFERENT container
        // than the one pending.
        //
        // Do NOT clear unconditionally here: `click` fires AFTER `pointerup`
        // for the SAME gesture (spec order is pointerdown -> pointerup ->
        // click), so an unconditional clear on every pointerup would erase
        // the guard before its own matching click ever arrives, defeating
        // the dedupe entirely and double-playing every normal press. This
        // ordering is reasoned from the event-order spec, not observed on a
        // real device in this environment — see the test suite's "what
        // remains unverified" note before "simplifying" this into an
        // unconditional clear.
        if (_pendingPointerId === null || e.pointerId !== _pendingPointerId) { return; }

        var match = _classifyMatch(e.target);
        var upContainer = match ? match.container : null;
        if (upContainer === _pendingContainer) { return; }

        _pendingPointerId = null;
        _pendingContainer = null;
    }, true);

    document.addEventListener('pointercancel', function (e) {
        // Gesture was taken over by the browser (scroll/pan) or otherwise
        // cancelled before a click could follow. Clear the guard so it can't
        // leak forward onto an unrelated future click (see the guard's
        // rationale comment above).
        if (e.pointerId === _pendingPointerId) {
            _pendingPointerId = null;
            _pendingContainer = null;
        }
    }, true);

    // XACA-1022-014: some role="button" elements invoke their handler
    // DIRECTLY from onkeydown and never produce a native `click` event at
    // all — lcars-ui's #usage-toggle (index.html, onkeydown calls
    // switchSection('usage') directly) and Fleet Monitor's
    // NAV_SELECTOR-bound settings/admin/offline pills (lcars-fleet-core.js
    // binds a keydown listener that calls self.switchSection(...) directly,
    // never .click()). The click fallback below never sees those
    // activations, so keyboard users get zero sound from them. This
    // listener plays directly on Enter/Space for anything that classifies,
    // closing that gap.
    //
    // Many SIBLING pills instead call `this.click()` from their own
    // onkeydown handler (verified in lcars-ui/index.html's mode-pill
    // markup), which DOES still dispatch a real `click` right after this
    // listener runs — capture-phase listeners registered on `document` run
    // before any bubble/target-phase handler on the event's target,
    // including an inline `onkeydown` attribute, so this listener always
    // sees the keydown first. Without a guard that would double-play
    // (keydown sound, then the resulting click's sound). This arms the SAME
    // container guard the pointerdown path uses, so the click delegate
    // below dedupes the trailing click exactly as it would a pointerdown's.
    document.addEventListener('keydown', function (e) {
        if (_muted) { return; }
        if (e.repeat) { return; } // ignore key-repeat while held
        if (e.key !== 'Enter' && e.key !== ' ' && e.key !== 'Spacebar') { return; }

        var match = _classifyMatch(e.target);
        if (!match) { return; }

        _pendingPointerId = null; // no pointer gesture is in flight — this IS the activation
        _pendingContainer = match.container;

        LCARSSound.play(match.type);
    }, true);

    document.addEventListener('click', function (e) {
        var target = e.target;

        // XACA-1022-019: consume the dedupe guard BEFORE the `_muted` early
        // return below, not after. The guard's rationale comment above
        // states the invariant as "consumed the instant ANY click is
        // evaluated against it, whether or not it matched" — that has to
        // include a click evaluated while muted, or the invariant is false
        // in code even though the comment states it. Previously `_muted`
        // was checked first, so a click evaluated while muted left the
        // guard armed, contradicting that invariant. Unreachable today (the
        // only mute-toggle path, #sound-toggle, never arms the guard —
        // `_classifyMatch` returns null for it) but fixed for
        // defense-in-depth in case a future mute-toggle path is added.
        var pendingContainer = _pendingContainer;
        _pendingPointerId = null;
        _pendingContainer = null;

        if (_muted) { return; }

        // XACA-1022-016: dedupe on the matched CONTAINER, not raw e.target
        // identity — see the guard's rationale comment above.
        var match = _classifyMatch(target);
        var wasPointerHandled = (pendingContainer !== null && match !== null && match.container === pendingContainer);
        if (wasPointerHandled) { return; }

        // XACA-1022-002: no matching pointerdown/keydown means this click
        // did not come from an activation we already sounded. The keydown
        // listener above already handles onkeydown-driven `.click()` calls
        // (and native <button> Enter/Space) by arming this same guard, so
        // this branch is left for anything that STILL only ever produces a
        // bare `click` with nothing preceding it — any other programmatic
        // `.click()` call being the main case. Play it here so that path
        // still gets sound.
        //
        // Note: MouseEvent.detail is 0 for a non-mouse-generated click per
        // spec, and could in principle distinguish "keyboard/synthetic" from
        // "real pointer click" without needing the guard above at all.
        // Deliberately NOT used here — it has a documented history of
        // inconsistent values across WebKit versions, and this codebase has
        // no automated cross-browser coverage to catch a regression in that
        // property. The pointerdown/click identity guard above already
        // solves the same problem without relying on it.
        if (!match) { return; }

        LCARSSound.play(match.type);
    }, true); // capture phase so it fires before stopPropagation in other handlers

    // -------------------------------------------------------------------------
    // Init — update UI to reflect persisted mute state on page load
    // -------------------------------------------------------------------------

    document.addEventListener('DOMContentLoaded', function () {
        _updateToggleUI();
        // Pre-warm the WAV cache so first click has no generation lag
        _ensureWavCache();
    });

    // Expose globally
    window.LCARSSound = LCARSSound;

}());
