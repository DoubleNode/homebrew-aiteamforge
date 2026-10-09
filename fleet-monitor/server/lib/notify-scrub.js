//
//  notify-scrub.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * Shared error-text scrubber (XACA-1400-007 D2). A provider's error message may
 * echo a connection's own secret or a destination it was configured with. Every
 * path that turns such text into something an operator or caller can read
 * (validation errors on create/update, receipts + responses on send) runs it
 * through scrubText() so the redaction rule lives in one place.
 */

/** Every non-empty string value of the connection's secrets and params. */
function sensitiveValues(connection) {
    const out = [];
    const take = (o) => {
        if (!o || typeof o !== 'object') return;
        for (const v of Object.values(o)) if (typeof v === 'string' && v.length > 0) out.push(v);
    };
    take(connection && connection.secrets);
    take(connection && connection.params);
    return out;
}

/**
 * Replace every occurrence of each value with "[redacted]" (longest first, so a
 * value that contains another is not left half-visible), then bound the length.
 */
function scrubText(text, values, maxLen) {
    let msg = String(text == null ? '' : text);
    const list = [...new Set(values || [])].sort((a, b) => b.length - a.length);
    for (const v of list) msg = msg.split(v).join('[redacted]');
    return typeof maxLen === 'number' ? msg.slice(0, maxLen) : msg;
}

module.exports = { scrubText, sensitiveValues };
