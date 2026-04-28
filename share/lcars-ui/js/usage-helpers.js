// Shared number-formatting helpers for the Claude Usage Monitor (XACA-0243).
// Used by both the compact agent-panel indicator and the full LCARS dashboard widget.
// Exposed on `window.UsageHelpers` since the LCARS UI does not use ES modules.
(function () {
    'use strict';

    const _compactFmt = new Intl.NumberFormat('en-US', {
        notation: 'compact',
        maximumFractionDigits: 1
    });

    function formatTokens(n) {
        if (n == null) return '--';
        return _compactFmt.format(n);
    }

    function formatCost(n) {
        if (n == null) return '--';
        if (n >= 1000) return '$' + _compactFmt.format(n);
        if (n >= 100)  return '$' + Math.round(n);
        return '$' + n.toFixed(2);
    }

    function formatMinutes(n) {
        if (n == null) return '--';
        const h = Math.floor(n / 60);
        const m = Math.round(n % 60);
        if (h === 0) return m + 'm';
        if (m === 0) return h + 'h';
        return h + 'h ' + m + 'm';
    }

    function formatPct(n) {
        if (n == null) return '--';
        return Math.round(n) + '%';
    }

    // Format an age-in-seconds for stale-data labels. Promotes to larger units
    // as the value grows so a 3-hour-old cache reads "3h 29m" instead of "209m".
    //   < 60s    → "Ns"
    //   < 60m    → "Nm" or "Nm Ss" (drop seconds when zero)
    //   < 24h    → "Nh" or "Nh Mm" (drop minutes when zero)
    //   >= 24h   → "Nd" or "Nd Hh" (drop hours when zero)
    function formatStaleAge(sec) {
        if (sec == null) return '--';
        sec = Math.max(0, Math.floor(sec));
        if (sec < 60) return sec + 's';
        const m = Math.floor(sec / 60);
        if (m < 60) {
            const s = sec % 60;
            return s ? m + 'm ' + s + 's' : m + 'm';
        }
        const h = Math.floor(m / 60);
        if (h < 24) {
            const mm = m % 60;
            return mm ? h + 'h ' + mm + 'm' : h + 'h';
        }
        const d  = Math.floor(h / 24);
        const hh = h % 24;
        return hh ? d + 'd ' + hh + 'h' : d + 'd';
    }

    window.UsageHelpers = { formatTokens, formatCost, formatMinutes, formatPct, formatStaleAge };
})();
