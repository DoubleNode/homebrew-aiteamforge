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
 *   1. malformed        record/ctx shape (incl. a missing run.event), owner/repo vs
 *                       run.repoFullName disagreement
 *   2. not-allowlisted  exact owner/repo, case-insensitive (GitHub names are)
 *   3. reject:fork-unverifiable
 *                       run.event is one whose run-level head repo CANNOT show a fork
 *                       origin (UNVERIFIABLE_EVENTS). A `workflow_run` always runs in the
 *                       base repo, so its own head_repository is the base repo even when it
 *                       was chained from a fork PR (measured on live GitHub, XACA-1441
 *                       PR #1083 review). Rejected outright: the upstream run is not linked
 *                       from the run object, and resolving it is easy to get wrong.
 *   4. reject:fork      run.headRepoFullName must be present AND equal run.repoFullName
 *                       (D7). Checked for every event that reaches this step.
 *      Both fork reasons set alert=true only when the job also carries the pool label
 *      (a fork-origin job aimed at the pool = workflow misconfiguration).
 *   5. label:not-pool   must include `self-hosted` and the pool label
 *   6. label:unknown    labels must be a subset of {self-hosted, OS, ARM64, pool, <host>}
 *   7. label:ambiguous  a pool job must carry EXACTLY ONE OS label (linux|macos) and AT MOST ONE
 *                       host label (XACA-1441-031). Zero or two OS labels, or two host labels,
 *                       can never be satisfied by a single minted runner: that is a workflow
 *                       misconfiguration to alert on, not a capacity outage to wait out.
 *
 * DECISION (D7): `issue_comment` and other events that run the BASE repo's default-branch
 * code report head == base and are accepted. That is the same posture as the XACA-1442
 * job-started hook's PASS. A workflow that then checks out fork code on the pool is a
 * workflow misconfiguration this module cannot see; the hook remains defence in depth.
 *
 * Label comparison is case-insensitive (GitHub treats labels so). The canonical key
 * helper here is deliberately local and simple; the orchestrator reconciles it with
 * the placement module's helpers.
 */

const REASONS = Object.freeze([
  'ok', 'not-allowlisted', 'reject:fork-unverifiable', 'reject:fork', 'label:not-pool',
  'label:unknown', 'label:ambiguous', 'malformed'
]);

/** Events whose run-level head repo cannot show a fork origin (step 3). Canonical form. */
const UNVERIFIABLE_EVENTS = Object.freeze(['workflow_run']);

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
      !record.run || typeof record.run !== 'object' || !isNonEmptyString(record.run.repoFullName) ||
      !isNonEmptyString(record.run.event)) {
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

  // 3. events whose run-level head cannot reveal a fork origin: never trust head == base
  if (UNVERIFIABLE_EVENTS.indexOf(canonical(record.run.event)) !== -1) {
    return verdict(false, 'reject:fork-unverifiable', hasPool);
  }

  // 4. fork rule (D7)
  if (!isSameRepoRun(record.run.repoFullName, record.run.headRepoFullName)) {
    return verdict(false, 'reject:fork', hasPool);
  }

  // 5. + 6. labels (D6)
  if (labels.indexOf('self-hosted') === -1 || !hasPool) return verdict(false, 'label:not-pool');
  const allowed = allowedLabelSet(poolLabel, hostLabels);
  if (!labels.every(function (l) { return allowed.has(l); })) return verdict(false, 'label:unknown');

  // 7. ambiguity (XACA-1441-031). Distinct canonical labels, so `Linux` + `linux` is one OS label.
  const osCount = new Set(labels.filter(function (l) { return OS_LABELS.indexOf(l) !== -1; })).size;
  const hostSet = new Set(hostLabels.map(canonical));
  const hostCount = new Set(labels.filter(function (l) { return hostSet.has(l); })).size;
  if (osCount !== 1 || hostCount > 1) return verdict(false, 'label:ambiguous');

  return verdict(true, 'ok');
}

module.exports = {
  REASONS: REASONS,
  UNVERIFIABLE_EVENTS: UNVERIFIABLE_EVENTS,
  evaluateJob: evaluateJob,
  isAllowlisted: isAllowlisted,
  isSameRepoRun: isSameRepoRun,
  allowedLabelSet: allowedLabelSet,
  canonical: canonical
};
