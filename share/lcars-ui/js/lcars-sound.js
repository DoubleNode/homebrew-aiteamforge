/**
 * LCARS Sound Manager
 * Web Audio API-based procedural sound effects for LCARS UI interactions.
 * No external audio files required — all tones are generated via oscillators.
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
    // AudioContext — lazy init on first user gesture (Chrome autoplay policy)
    // -------------------------------------------------------------------------
    let audioCtx = null;
    let masterGain = null;

    function ensureAudioContext() {
        if (audioCtx) {
            // Resume if suspended (browser may suspend after inactivity).
            // resume() returns a Promise — we fire-and-forget here since tones
            // scheduled slightly ahead of currentTime will still play once the
            // context resumes (they are queued internally by the audio graph).
            if (audioCtx.state === 'suspended') {
                audioCtx.resume().catch(function (err) {
                    console.warn('[LCARSSound] AudioContext resume failed:', err);
                });
            }
            return audioCtx;
        }

        audioCtx = new (window.AudioContext || window.webkitAudioContext)();

        // Master gain node — muting routes through here
        masterGain = audioCtx.createGain();
        masterGain.gain.value = _muted ? 0 : 0.35;
        masterGain.connect(audioCtx.destination);

        return audioCtx;
    }

    // -------------------------------------------------------------------------
    // Mute state — persisted to localStorage
    // -------------------------------------------------------------------------
    const STORAGE_KEY = 'lcars-sound-muted';

    let _muted = localStorage.getItem(STORAGE_KEY) === 'true';

    function _applyMuteToGain() {
        if (masterGain) {
            masterGain.gain.value = _muted ? 0 : 0.35;
        }
    }

    function _updateToggleUI() {
        var pill = document.getElementById('sound-toggle');
        if (pill) {
            pill.classList.toggle('sound-muted', _muted);
        }
        var label = document.getElementById('sound-status');
        if (label) {
            label.textContent = _muted ? 'MUTED' : 'SOUND';
        }
    }

    // -------------------------------------------------------------------------
    // Tone primitives
    // -------------------------------------------------------------------------

    /**
     * Play a single oscillator tone.
     * @param {number} freq      - Frequency in Hz
     * @param {number} startTime - AudioContext time to start
     * @param {number} duration  - Duration in seconds
     * @param {string} type      - Oscillator type: 'sine'|'square'|'triangle'|'sawtooth'
     * @param {number} gain      - Relative gain 0–1
     */
    function _playTone(freq, startTime, duration, type, gain) {
        var ctx = ensureAudioContext();

        var osc = ctx.createOscillator();
        var gainNode = ctx.createGain();

        osc.type = type || 'sine';
        osc.frequency.setValueAtTime(freq, startTime);

        // Use nullish-style check: gain ?? 0.8 written as ternary for ES5 compat
        gainNode.gain.setValueAtTime(gain !== undefined ? gain : 0.8, startTime);
        // Quick attack, smooth decay
        gainNode.gain.exponentialRampToValueAtTime(0.001, startTime + duration);

        osc.connect(gainNode);
        gainNode.connect(masterGain);

        osc.start(startTime);
        osc.stop(startTime + duration);
    }

    /**
     * Play a frequency-sweep oscillator tone (for authentic LCARS chirps).
     * @param {number} freqStart - Starting frequency in Hz
     * @param {number} freqEnd   - Ending frequency in Hz
     * @param {number} startTime - AudioContext time to start
     * @param {number} duration  - Duration in seconds
     * @param {string} type      - Oscillator type
     * @param {number} gain      - Relative gain 0–1
     */
    function _playSweep(freqStart, freqEnd, startTime, duration, type, gain) {
        var ctx = ensureAudioContext();

        var osc = ctx.createOscillator();
        var gainNode = ctx.createGain();

        osc.type = type || 'sine';
        osc.frequency.setValueAtTime(freqStart, startTime);
        osc.frequency.exponentialRampToValueAtTime(freqEnd, startTime + duration);

        gainNode.gain.setValueAtTime(gain !== undefined ? gain : 0.8, startTime);
        gainNode.gain.exponentialRampToValueAtTime(0.001, startTime + duration);

        osc.connect(gainNode);
        gainNode.connect(masterGain);

        osc.start(startTime);
        osc.stop(startTime + duration);
    }

    // -------------------------------------------------------------------------
    // Sound definitions — modeled on TNG LCARS panel sounds
    // -------------------------------------------------------------------------

    /**
     * Nav chirp — TNG panel press.
     * Fast ascending frequency sweep (~1975→2600Hz in 60ms) with a softer
     * body tone underneath. The sweep is the signature "bip" heard when
     * officers touch LCARS panels on the Enterprise-D bridge.
     */
    function _playNav() {
        var ctx = ensureAudioContext();
        var now = ctx.currentTime;

        // Primary: fast ascending sweep — the characteristic LCARS chirp
        _playSweep(1975, 2600, now, 0.06, 'sine', 0.55);
        // Body: softer mid-range tone gives it weight
        _playTone(1200, now, 0.04, 'sine', 0.2);
        // Sparkle: faint high harmonic for that digital crispness
        _playSweep(3950, 5200, now, 0.05, 'sine', 0.08);
    }

    /**
     * Action beep — TNG data acknowledgment / computer response.
     * Clean high-mid tone (~1500Hz) with sharp attack and quick decay,
     * plus a subtle 3rd harmonic. The classic "boop" when the computer
     * confirms a command or displays requested data.
     */
    function _playAction() {
        var ctx = ensureAudioContext();
        var now = ctx.currentTime;

        // Primary: clean 1500Hz — the TNG acknowledgment pitch
        _playTone(1500, now, 0.09, 'sine', 0.5);
        // 3rd harmonic adds the subtle digital texture
        _playTone(4500, now, 0.05, 'sine', 0.07);
        // Sub-tone for body
        _playTone(750, now, 0.06, 'sine', 0.12);
    }

    /**
     * Alert tone — TNG comm chirp / confirmation.
     * Two-note ascending sequence (C6→E6, a major third interval)
     * with a brief gap between notes. Evokes the communicator chirp
     * and the "task complete" confirmation heard throughout TNG.
     */
    function _playAlert() {
        var ctx = ensureAudioContext();
        var now = ctx.currentTime;

        // First note: C6 (1046.5 Hz)
        _playTone(1047, now, 0.08, 'sine', 0.5);
        _playTone(2094, now, 0.06, 'sine', 0.08);
        // Gap: ~40ms silence between notes
        // Second note: E6 (1318.5 Hz) — major third above
        _playTone(1318, now + 0.12, 0.10, 'sine', 0.45);
        _playTone(2637, now + 0.12, 0.07, 'sine', 0.07);
    }

    // -------------------------------------------------------------------------
    // Public API
    // -------------------------------------------------------------------------

    var soundMap = {
        nav:    _playNav,
        action: _playAction,
        alert:  _playAlert
    };

    var LCARSSound = {

        /**
         * Play a sound by type: 'nav', 'action', or 'alert'.
         * Silently no-ops if muted or AudioContext unavailable.
         */
        play: function (type) {
            if (_muted) { return; }
            if (!soundMap[type]) {
                console.warn('[LCARSSound] Unknown sound type:', type);
                return;
            }
            try {
                soundMap[type]();
            } catch (e) {
                // Web Audio errors shouldn't break the UI
                console.warn('[LCARSSound] Audio error:', e);
            }
        },

        mute: function () {
            _muted = true;
            localStorage.setItem(STORAGE_KEY, 'true');
            _applyMuteToGain();
            _updateToggleUI();
        },

        unmute: function () {
            _muted = false;
            localStorage.setItem(STORAGE_KEY, 'false');
            _applyMuteToGain();
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
            target.closest('.sidebar-submenu-item')
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
            target.closest('.toast-close')
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
    });

    // Expose globally
    window.LCARSSound = LCARSSound;

}());
