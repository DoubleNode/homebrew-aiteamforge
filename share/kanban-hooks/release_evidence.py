"""
release_evidence.py -- walkthrough evidence attachments (XACA-1512-001).

Stdlib only, py3.9-safe. A MANUAL test record may carry an optional `evidence` list:

    [{"file": "<path relative to the release evidence dir>", "sha256": "<64 lowercase hex>",
      "caption": "<text, <= 300 chars; defaults to the file basename>"}]

THE release evidence directory (defined here, once):

    <kanban_dir>/release-evidence/<RELEASE-ID>/

release_evidence_dir() is the only place that spelling exists. Every `file` is relative to it.

Split: the STRING-level shape rules are pure and live in release_schema (evidence_file_problem /
validate_evidence, which the server also runs on every post). This module is the filesystem edge:
realpath containment (symlinks followed, same _under pattern the runner uses for `cases`),
existence, sha256 computation / verification. Everything FAILS CLOSED: a bad entry raises
EvidenceError; nothing is dropped.

Public API for readers (the wiki publisher):
    release_evidence_dir(kanban_dir, release_id) -> str
    resolve_evidence_file(evidence_dir, rel)     -> absolute realpath of a contained regular file
    build_evidence(evidence_dir, entries)        -> normalized, verified list (computes sha / caption)
    parse_evidence_input(text)                   -> list of items from "a.png, b.png=Caption"
    split_evidence_item(item) / default_caption(test, k, n)   (XACA-1512-013)
    verify_record_evidence(evidence_dir, record) -> the record's evidence list, re-verified on disk
"""
import hashlib
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from release_runner import RunnerError, _under  # noqa: E402
from release_wiki import MAX_ATTACHMENT_BYTES  # noqa: E402  (one cap: record time == publish time)
from release_schema import (EVIDENCE_MAX_CAPTION, EVIDENCE_MAX_ENTRIES, evidence_file_problem,  # noqa: E402
                            validate_evidence)

EVIDENCE_SUBDIR = "release-evidence"
_RELEASE_ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*\Z")
_SHA_RE = re.compile(r"[0-9a-f]{64}\Z")


class EvidenceError(RunnerError):
    """Any invalid evidence entry (a RunnerError subclass so existing CLI boundaries catch it)."""


def release_evidence_dir(kanban_dir, release_id):
    """The release evidence directory path (not created, not checked)."""
    if not isinstance(release_id, str) or not _RELEASE_ID_RE.match(release_id) or ".." in release_id:
        raise EvidenceError("invalid release id for an evidence directory: %r" % (release_id,))
    return os.path.join(str(kanban_dir), EVIDENCE_SUBDIR, release_id)


def resolve_evidence_file(evidence_dir, rel):
    """Absolute realpath of `rel` under `evidence_dir`; must be an existing regular file that does
    not resolve (symlinks followed) outside the directory."""
    problem = evidence_file_problem(rel)
    if problem:
        raise EvidenceError("evidence %r: %s" % (rel, problem))
    try:
        full = _under(evidence_dir, rel, "evidence file")
    except RunnerError as e:
        raise EvidenceError(str(e))
    if not os.path.isfile(full):
        raise EvidenceError("evidence file %r does not exist (or is not a regular file) in %s"
                            % (rel, evidence_dir))
    # A 0-byte screenshot is a failed capture, not proof (XACA-1512).
    size = os.path.getsize(full)
    if size == 0:
        raise EvidenceError("evidence file %r is empty (0 bytes) -- re-capture it" % (rel,))
    # The publish-time attachment cap, enforced when the answer is recorded so it fails NOW, not at CR.
    if size > MAX_ATTACHMENT_BYTES:
        raise EvidenceError("evidence file %r is %d bytes; the attachment limit is %d"
                            % (rel, size, MAX_ATTACHMENT_BYTES))
    return full


def sha256_file(path, chunk=1 << 20):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(chunk), b""):
            h.update(block)
    return h.hexdigest()


def build_evidence(evidence_dir, entries):
    """Normalize + verify `entries` (dicts with `file`; optional `sha256`, `caption`) against disk.
    Computes sha256 when absent, REJECTS a supplied sha256 that does not match, defaults caption to
    the file basename. Returns a NEW list; raises EvidenceError on the first bad entry."""
    if not isinstance(entries, (list, tuple)):
        raise EvidenceError("evidence must be a list")
    if len(entries) > EVIDENCE_MAX_ENTRIES:
        raise EvidenceError("evidence has %d entries (max %d)" % (len(entries), EVIDENCE_MAX_ENTRIES))
    out = []
    for i, e in enumerate(entries):
        if not isinstance(e, dict):
            raise EvidenceError("evidence[%d] must be an object" % i)
        for k in e:
            if k not in ("file", "sha256", "caption"):
                raise EvidenceError("evidence[%d]: unknown field %s" % (i, k))
        rel = e.get("file")
        full = resolve_evidence_file(evidence_dir, rel)
        actual = sha256_file(full)
        given = e.get("sha256")
        if given is not None:
            if not isinstance(given, str) or not _SHA_RE.match(given):
                raise EvidenceError("evidence %r: sha256 must be 64 lowercase hex characters" % rel)
            if given != actual:
                raise EvidenceError("evidence %r: sha256 mismatch (given %s, file is %s)" % (rel, given, actual))
        cap = e.get("caption")
        if cap is None:
            cap = os.path.basename(rel)
        if not isinstance(cap, str) or not cap.strip():
            raise EvidenceError("evidence %r: caption must be a non-empty string" % rel)
        if len(cap) > EVIDENCE_MAX_CAPTION:
            raise EvidenceError("evidence %r: caption longer than %d characters" % (rel, EVIDENCE_MAX_CAPTION))
        out.append({"file": rel, "sha256": actual, "caption": cap})
    return out


def parse_evidence_input(text):
    """'a.png, b.png' -> ['a.png', 'b.png']; blank -> []. An empty item ('a.png,,b.png') is kept as
    '' so build_evidence rejects it rather than it being silently dropped. Each item may still carry
    its '=caption' suffix; split_evidence_item() takes that apart (XACA-1512-013)."""
    text = (text or "").strip()
    return [p.strip() for p in text.split(",")] if text else []


def split_evidence_item(item):
    """'file.png=Login screen' -> ('file.png', 'Login screen'); no '=' or a blank caption -> (item, None).
    Splits on the FIRST '=', so a literal '=' in a FILE NAME cannot be attached this way (accepted loss),
    while a caption may contain '='. A caption cannot contain a comma (the entry separator)."""
    name, eq, cap = item.partition("=")
    name = name.strip()
    cap = cap.strip()
    return (name, cap) if eq and cap else (name if eq else item, None)


def default_caption(test_name, k, n):
    """'<test name> - screenshot k of n', bounded to EVIDENCE_MAX_CAPTION (the test name gives way, never
    the suffix). Meaningful alt text instead of a camera file name like IMG_4021.png (WCAG 1.1.1)."""
    suffix = " - screenshot %d of %d" % (k, n)
    name = " ".join(str(test_name or "").split())[:max(EVIDENCE_MAX_CAPTION - len(suffix), 0)].rstrip()
    return (name + suffix).strip()[:EVIDENCE_MAX_CAPTION]


def verify_record_evidence(evidence_dir, record):
    """Re-verify a STORED record's evidence on disk (file still contained, present, sha matches).
    Returns the normalized list ([] when the record has none). Raises EvidenceError otherwise.
    Also runs the pure schema validator first so a malformed stored value fails closed."""
    ev = record.get("evidence") if isinstance(record, dict) else None
    if ev is None:
        return []
    problems = validate_evidence(ev)
    if problems:
        raise EvidenceError("; ".join(problems))
    return build_evidence(evidence_dir, ev)
