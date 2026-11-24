//
//  ci-machine-aliases.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * CI pool machine renames (XACA-1937): old machine id / host label -> new one.
 *
 * DUAL-NAME WINDOW. Both names mean the same machine everywhere the server compares
 * machines or host labels: pool-store lookups, the telemetry key's body.machine check,
 * job host labels (a job still queued on `fleet-pool,m1mini` or `self-hosted,Linux,ARM64,m1mini`
 * is placed on romulus and minted a runner that carries the label the job named), runner-name
 * prefixes (`fcp-m1mini-*` minted before the deploy still map to romulus) and assignment
 * ownership. The pool store renames an old-name record to the new name when it loads.
 *
 * The window closes under XACA-1936: delete an entry here (and its tests) once no workflow,
 * reporter or persisted assignment uses the old name.
 */

const MACHINE_ALIASES = Object.freeze({
    m1mini: 'romulus',
    m4mini: 'vulcan',
});

const low = (s) => String(s).toLowerCase();   // no trim: "m1mini " is not a machine name

/** New id for an old one (case-insensitive, returned lowercased); anything else passes through unchanged. */
function canonicalMachine(id) {
    if (typeof id !== 'string' || !id) return id;
    const k = low(id);
    return Object.prototype.hasOwnProperty.call(MACHINE_ALIASES, k) ? MACHINE_ALIASES[k] : id;
}

/** Old names of a machine (lowercased). `aliasesOf('romulus')` -> ['m1mini']; an old or unknown id -> []. */
function aliasesOf(id) {
    if (typeof id !== 'string' || !id) return [];
    const k = low(id);
    return Object.keys(MACHINE_ALIASES).filter((old) => MACHINE_ALIASES[old] === k);
}

/** Every name of the machine `id` belongs to, lowercased, canonical first: 'm1mini' -> ['romulus', 'm1mini']. */
function namesOf(id) {
    if (typeof id !== 'string' || !id) return [];
    const c = low(canonicalMachine(id));
    return [c, ...aliasesOf(c)];
}

/**
 * Identity names of a machine id, EXACT case (machine-id checks have always been exact): an id spelled
 * exactly as in the table ('m1mini' or 'romulus') -> its whole group, new name first; anything else -> [id].
 */
function exactNamesOf(id) {
    if (typeof id !== 'string' || !id) return [];
    const c = Object.prototype.hasOwnProperty.call(MACHINE_ALIASES, id) ? MACHINE_ALIASES[id] : id;
    const group = [c, ...Object.keys(MACHINE_ALIASES).filter((old) => MACHINE_ALIASES[old] === c)];
    return group.length > 1 ? group : [id];
}

/**
 * True when a and b are the same machine: equal, or an old and a new name from the table spelled exactly
 * ('m1mini' / 'romulus'). Case variants ('M1MINI') do NOT match, so the telemetry key's body.machine check
 * stays exact.
 */
function sameMachine(a, b) {
    if (typeof a !== 'string' || typeof b !== 'string') return false;
    return a === b || exactNamesOf(a).includes(b);
}

/** Host label a runner minted on this machine carries: machine.hostLabel, else the lowercased id. */
function primaryHostLabel(machine) {
    if (!machine) return null;
    if (typeof machine.hostLabel === 'string' && machine.hostLabel) return machine.hostLabel.toLowerCase();
    return typeof machine.id === 'string' && machine.id ? machine.id.toLowerCase() : null;
}

/**
 * Every host label that targets this machine, lowercased, primary first: the primary label plus the other
 * names in its alias group. {id:'romulus'} -> ['romulus','m1mini']; {id:'m1mini'} -> ['m1mini','romulus'];
 * an unaliased machine -> [primary]; no usable label -> [].
 */
function hostLabelsOf(machine) {
    const primary = primaryHostLabel(machine);
    if (primary === null) return [];
    const out = [primary];
    for (const n of namesOf(primary)) if (!out.includes(n)) out.push(n);
    return out;
}

module.exports = {
    MACHINE_ALIASES, canonicalMachine, aliasesOf, namesOf, exactNamesOf, sameMachine, primaryHostLabel, hostLabelsOf,
};
