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
 * output while HTML5 <audio> playback works correctly.
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
     * Play a cached WAV via a new Audio element.
     * Each call creates a fresh Audio instance so overlapping plays work.
     */
    function _playWav(type) {
        _ensureWavCache();
        var uri = _wavCache[type];
        if (!uri) return;
        try {
            var audio = new Audio(uri);
            audio.volume = 1.0;
            var p = audio.play();
            if (p && p.catch) {
                p.catch(function () {
                    // Autoplay blocked — silently ignore
                });
            }
        } catch (e) {
            console.warn('[LCARSSound] Audio playback error:', e);
        }
    }

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
    // Global click interceptor
    // Classifies click targets and plays the appropriate sound.
    // Uses event delegation — does NOT attach to individual elements.
    // Does NOT interfere with existing click handlers.
    // -------------------------------------------------------------------------

    document.addEventListener('click', function (e) {
        if (_muted) { return; }

        var target = e.target;

        // Nav sounds — sidebar navigation
        if (
            target.closest('.sidebar-button') ||
            target.closest('.sidebar-submenu-item') ||
            target.closest('.analytics-page-pill') ||   // Fleet Monitor: analytics page-nav pills
            target.closest('.sidebar-link')             // Fleet Monitor: dashboard-switcher links
        ) {
            LCARSSound.play('nav');
            return;
        }

        // Alert sounds — status changes and priority/category/tag clickables
        if (
            target.closest('.status-btn') ||
            target.closest('.status-indicator') ||
            target.closest('[data-priority]') ||
            target.closest('[data-category]') ||
            target.closest('[data-tag]') ||
            target.closest('.candy-pill:not([data-candy])') ||  // Fleet Monitor: interactive pills only — metric display pills carry data-candy (XACA-0533 review)
            target.closest('.legend-pill') ||                   // XACA-0963: utility-bar pills (SETTINGS/ADMIN/SOUND) are .legend-pill, not .candy-pill
            target.closest('#sound-toggle')
        ) {
            // sound-toggle is handled by toggleMute directly; skip double-play
            if (!target.closest('#sound-toggle')) {
                LCARSSound.play('alert');
            }
            return;
        }

        // Action sounds — cards, toggles, general buttons
        if (
            target.closest('.kanban-card') ||
            target.closest('.card') ||
            target.closest('.legend-pill') ||
            target.closest('.toggle-columns-btn') ||
            target.closest('.toast-close') ||
            target.closest('.summary-card') ||          // Fleet Monitor: overview summary cards
            target.closest('.btn-lcars') ||             // Fleet Monitor: LCARS-styled buttons
            target.closest('.lcars-button') ||          // Fleet Monitor: settings CLASSIC UI button
            target.closest('.kiosk-fab')                // Fleet Monitor: kiosk mode FAB
        ) {
            LCARSSound.play('action');
            return;
        }

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
