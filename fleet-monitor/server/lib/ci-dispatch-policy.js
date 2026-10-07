//
//  ci-dispatch-policy.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * CI dispatcher safety policy (XACA-1441-006). Design: plan D6 (labels) + D7 (fork rule)
 * + Requirement 2 (own repos only). PURE: no I/O, no clock, no GitHub calls.
 *
 * evaluateJob(record, ctx) consumes the watcher's inter-module job record and answers
 * "may the dispatcher mint a runner for this job?". It FAILS CLOSED: any missing or
 * odd field is `malformed`, never an accept.
 *
 * Check order (first failure wins; the order is part of the contract):
 *   1. malformed        record/ctx shape, owner/repo vs run.repoFullName disagreement
 *   2. not-allowlisted  exact owner/repo, case-insensitive (GitHub names are)
 *   3. reject:fork      run.headRepoFullName must be present AND equal run.repoFullName,
 *                       for EVERY event type (D7). alert=true only when the job also
 *                       carries the pool label (a fork job aimed at the pool = misconfig).
 *   4. label:not-pool   must include `self-hosted` and the pool label
 *   5. label:unknown    labels must be a subset of {self-hosted, OS, ARM64, pool, <host>}
 *
 * Label comparison is case-insensitive (GitHub treats labels so). The canonical key
 * helper here is deliberately local and simple; the orchestrator reconciles it with
 * the placement module's helpers.
 */

const REASONS = Object.freeze([
  'ok', 'not-allowlisted', 'reject:fork', 'label:not-pool', 'label:unknown', 'malformed'
]);

const OS_LABELS = Object.freeze(['linux', 'macos']);
const BASE_LABELS = Object.freeze(['self-hosted', 'arm64']);

function isNonEmptyString(v) { return typeof v === 'string' && v.trim().length > 0; }

/** Canonical form of a label / repo name for comparison. */
function canonical(s) { return String(s).trim().toLowerCase(); }

function verdict(accept, reason, alert) {
  return { accept: accept, reason: reason, alert: alert === true };
}

/** Build the Set of canonical labels a pool job may carry. */
function allowedLabelSet(poolLabel, hostLabels) {
  const set = new Set(BASE_LABELS.concat(OS_LABELS));
  set.add(canonical(poolLabel));
  for (const h of hostLabels) set.add(canonical(h));
  return set;
}

/** Is `fullName` ("owner/repo") on the allowlist? Exact match, no wildcards, case-insensitive. */
function isAllowlisted(fullName, allowlist) {
  if (!isNonEmptyString(fullName) || !Array.isArray(allowlist)) return false;
  const want = canonical(fullName);
  return allowlist.some(function (a) { return isNonEmptyString(a) && canonical(a) === want; });
}

/**
 * D7. True only when the head repo is present and is the base repo. Missing/null/odd => false.
 * Pure over the two names so callers can reuse it on raw run payloads.
 */
function isSameRepoRun(repoFullName, headRepoFullName) {
  if (!isNonEmptyString(repoFullName) || !isNonEmptyString(headRepoFullName)) return false;
  return canonical(repoFullName) === canonical(headRepoFullName);
}

function evaluateJob(record, ctx) {
  // 1. shape. Anything unexpected is malformed (fail closed, alert=false: not a fork signal).
  if (!record || typeof record !== 'object' || !ctx || typeof ctx !== 'object') {
    return verdict(false, 'malformed');
  }
  const poolLabel = ctx.poolLabel;
  const hostLabels = ctx.hostLabels;
  if (!isNonEmptyString(poolLabel) || !Array.isArray(ctx.allowlist) ||
      !Array.isArray(hostLabels) || !hostLabels.every(isNonEmptyString)) {
    return verdict(false, 'malformed');
  }
  if (!isNonEmptyString(record.owner) || !isNonEmptyString(record.repo) ||
      !Array.isArray(record.labels) || !record.labels.every(isNonEmptyString) ||
      !record.run || typeof record.run !== 'object' || !isNonEmptyString(record.run.repoFullName)) {
    return verdict(false, 'malformed');
  }
  const fullName = record.owner + '/' + record.repo;
  // The record's own two descriptions of "which repo" must agree, or we cannot trust either.
  if (canonical(fullName) !== canonical(record.run.repoFullName)) {
    return verdict(false, 'malformed');
  }

  // 2. allowlist
  if (!isAllowlisted(fullName, ctx.allowlist)) return verdict(false, 'not-allowlisted');

  const labels = record.labels.map(canonical);
  const hasPool = labels.indexOf(canonical(poolLabel)) !== -1;

  // 3. fork rule (D7), every event type
  if (!isSameRepoRun(record.run.repoFullName, record.run.headRepoFullName)) {
    return verdict(false, 'reject:fork', hasPool);
  }

  // 4. + 5. labels (D6)
  if (labels.indexOf('self-hosted') === -1 || !hasPool) return verdict(false, 'label:not-pool');
  const allowed = allowedLabelSet(poolLabel, hostLabels);
  if (!labels.every(function (l) { return allowed.has(l); })) return verdict(false, 'label:unknown');

  return verdict(true, 'ok');
}

module.exports = {
  REASONS: REASONS,
  evaluateJob: evaluateJob,
  isAllowlisted: isAllowlisted,
  isSameRepoRun: isSameRepoRun,
  allowedLabelSet: allowedLabelSet,
  canonical: canonical
};
