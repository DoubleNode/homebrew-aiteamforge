---
name: rag-orchestrator
description: Unified RAG routing skill — detects content type and intent, then delegates to the appropriate engine-specific skill (LightRAG, Code-Graph-RAG, or RAG-Anything).
version: 1.0.0
author: Commander Jett Reno (Chief Technical Instructor)
company: Starfleet Academy - Engineering Lab
project: Dev Team LCARS Infrastructure
terminals:
  - All terminals (auto-detects team)
supported_os:
  - macOS
  - Linux
dependencies:
  - Claude Code
  - At least one RAG engine skill installed
tags:
  - rag
  - orchestrator
  - routing
  - knowledge-graph
  - multimodal
  - code-intelligence
command_shortcut: /rag
last_updated: 2026-04-07
status: production-ready
model: sonnet
---

# RAG Orchestrator

## Skill Metadata

**Name:** RAG Orchestrator
**Version:** 1.0.0
**Author:** Commander Jett Reno (Chief Technical Instructor)
**Primary Terminals:** All terminals (auto-detects team)
**Platforms:** macOS, Linux
**Last Updated:** 2026-04-07
**Command:** `/rag`

---

## Purpose

This is the single entry point for all RAG operations on the dev team. Agents invoke `/rag` and the orchestrator handles everything else — checking which engines are alive, detecting what type of content you're working with, and routing to the right engine-specific skill.

The orchestrator does NOT call APIs directly. It is the front desk: triage and routing only. The actual work happens in:

- `/lightrag` — LightRAG skill (port 9621)
- `/code-graph-rag` — Code-Graph-RAG skill (port 9622)
- `/rag-anything` — RAG-Anything skill (port 9623)

If you know exactly what you want and which engine to use, you can invoke those skills directly. Otherwise, start here.

---

## Engine Roster

| Engine | Skill | Port | Status | Best For |
|--------|-------|------|--------|----------|
| LightRAG | /lightrag | 9621 | Running | Text documents, knowledge graphs |
| Code-Graph-RAG | /code-graph-rag | 9622 | Skeleton (not installed) | Source code, symbol analysis |
| RAG-Anything | /rag-anything | 9623 | Skeleton (not installed) | Multimodal — images, audio, tables |

LightRAG is the baseline. It should always be running. The other two engines are installed on demand.

---

## Step 1: Check Engine Availability

Before routing anything, verify which engines are online. Run all three checks simultaneously.

```bash
# LightRAG — check health and version
curl -s http://localhost:9621/health \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'LightRAG: {d[\"status\"]} v{d[\"core_version\"]}')" \
  2>/dev/null || echo "LightRAG: offline"

# Code-Graph-RAG
curl -s http://localhost:9622/health 2>/dev/null \
  && echo "Code-Graph-RAG: online" \
  || echo "Code-Graph-RAG: offline"

# RAG-Anything
curl -s http://localhost:9623/health 2>/dev/null \
  && echo "RAG-Anything: online" \
  || echo "RAG-Anything: offline"
```

Record which engines responded before proceeding. Engine availability determines the routing options for this session.

---

## Step 2: Content-Type Detection

Examine what the user wants to ingest or query. Classify it into one of these categories:

**Source Code** — Files with code extensions: `.swift`, `.py`, `.kt`, `.ts`, `.js`, `.go`, `.rs`, `.rb`, `.java`, `.cpp`, `.c`, `.h`, `.m`, `.sh`, or entire repositories.

**Multimodal** — Images (`.png`, `.jpg`, `.gif`, `.webp`), audio files (`.mp3`, `.wav`, `.m4a`), tables embedded in documents, PDFs that contain charts or screenshots.

**Pure Text** — Markdown (`.md`), plain text (`.txt`), meeting notes, documentation, prose content, structured data in text form (`.json`, `.yaml`, `.csv` without images).

**Unknown / Mixed** — Content that doesn't clearly fall into one category, or mixed documents with both code and prose.

---

## Step 3: Routing Decision Tree

```
User wants to ingest or query something
│
├─ Is it SOURCE CODE? (.swift, .py, .kt, .ts, .js, entire repos, etc.)
│  ├─ Code-Graph-RAG ONLINE → delegate to /code-graph-rag
│  └─ Code-Graph-RAG OFFLINE → fallback to /lightrag
│     (LightRAG handles code text — less precise symbol analysis, but works)
│
├─ Is it MULTIMODAL? (images, audio, PDFs with figures, embedded tables)
│  ├─ RAG-Anything ONLINE → delegate to /rag-anything
│  └─ RAG-Anything OFFLINE → warn user, offer text extraction fallback
│     (offer to extract text content from the document if possible)
│
├─ Is it PURE TEXT? (.md, .txt, docs, meeting notes, prose)
│  └─ Always → delegate to /lightrag
│
└─ UNKNOWN or MIXED?
   └─ Default to /lightrag (most mature, always available)
      Explain the routing choice to the user
```

---

## Routing by Intent

The user's phrasing matters as much as the content type. Match these patterns:

| User Says | Route To | Notes |
|-----------|----------|-------|
| "ingest this document / file / notes" | Detect type → appropriate engine | Run content-type detection first |
| "query about X" / "what do we know about X" | Check all engines for relevant data | May query multiple engines |
| "what's indexed?" / "what's in the knowledge base?" | Check all engines for document counts | Status query |
| "status of RAG" / "which engines are running?" | Health check all engines | Availability report |
| "index this repo" / "add this codebase" | /code-graph-rag | Code indexing is its specialty |
| "ingest these images" / "add these screenshots" | /rag-anything | Multimodal only |
| "search knowledge base" / "find X in docs" | /lightrag (default) | Or multi-engine if available |
| "add meeting notes" / "index this doc" | /lightrag | Text → LightRAG |

---

## Multi-Engine Queries

When multiple engines are online and a query could have relevant results in more than one, query all of them and synthesize.

**Example flow — "What do we know about authentication?"**

```
1. Check availability: LightRAG online, Code-Graph-RAG online, RAG-Anything offline

2. Query LightRAG (text knowledge):
   → Invoke /lightrag with query "authentication"
   → Returns: documentation, meeting notes, design decisions

3. Query Code-Graph-RAG (symbol analysis):
   → Invoke /code-graph-rag with query "authentication"
   → Returns: Auth classes, functions, call graphs

4. Synthesize results:
   → Present findings from both engines
   → Label each result's source engine
   → Note RAG-Anything was offline (no image/audio results)
```

When synthesizing multi-engine results, always label which engine produced each result. The user needs to know whether they're looking at documentation knowledge or code structure.

---

## Fallback Behavior

These rules apply when the preferred engine is offline.

**Code-Graph-RAG offline:**
LightRAG handles code files as text. Symbol-level analysis and call graph traversal won't be available, but full-text search across code still works. Inform the user of this degradation and proceed with LightRAG.

```
"Code-Graph-RAG is offline. Routing to LightRAG instead.
 Note: symbol analysis and call graphs won't be available,
 but full-text code search will work."
```

**RAG-Anything offline:**
There is no fallback for true multimodal content. Offer these alternatives:
- Extract text from the document using available tools and ingest that via LightRAG
- Note that image/audio content cannot be indexed until RAG-Anything is running
- Provide instructions to start RAG-Anything if the user wants to proceed

```
"RAG-Anything is offline. Options:
 1. Extract text from your document and ingest via LightRAG
 2. Start RAG-Anything first (see /rag-anything for setup)
 Image and audio content cannot be indexed without it."
```

**LightRAG offline:**
This is a critical failure. LightRAG is the baseline engine that must always be running. Do not attempt to route around it.

```
"LightRAG is offline — this is the baseline RAG engine and must be running.
 Check: lightrag-server --port 9621 --working-dir ~/rag-data/lightrag
 No RAG operations can proceed until LightRAG is restored."
```

---

## Quick Reference: Content Type to Engine

| Content Type | Primary Engine | Fallback |
|--------------|---------------|----------|
| Source code files (.swift, .py, .ts, etc.) | Code-Graph-RAG | LightRAG |
| Entire repositories | Code-Graph-RAG | LightRAG |
| Images (.png, .jpg, .gif, .webp) | RAG-Anything | None (warn user) |
| Audio files (.mp3, .wav, .m4a) | RAG-Anything | None (warn user) |
| PDFs with figures/screenshots | RAG-Anything | LightRAG (text only) |
| Markdown files (.md) | LightRAG | — |
| Plain text (.txt) | LightRAG | — |
| Meeting notes | LightRAG | — |
| JSON / YAML / CSV (text) | LightRAG | — |
| Mixed / unknown | LightRAG | — |

---

## Example Orchestration Flows

### Flow 1: Ingest Meeting Notes

```
User: "ingest my meeting notes from today"

Orchestrator:
1. Check engines → LightRAG: online
2. Detect content type → .md or .txt → pure text
3. Route → /lightrag
4. Delegate: invoke /lightrag skill with ingest intent
```

### Flow 2: Index the iOS Codebase

```
User: "index the iOS codebase"

Orchestrator:
1. Check engines → LightRAG: online, Code-Graph-RAG: offline
2. Detect content type → source code (.swift files, Xcode project)
3. Preferred engine: Code-Graph-RAG → offline
4. Fallback: /lightrag
5. Inform user of degraded mode, then delegate to /lightrag
```

### Flow 3: Add Screenshots to Knowledge Base

```
User: "add these screenshots to the knowledge base"

Orchestrator:
1. Check engines → LightRAG: online, RAG-Anything: offline
2. Detect content type → images (.png) → multimodal
3. Preferred engine: RAG-Anything → offline
4. No fallback for images
5. Inform user:
   "RAG-Anything is offline. Cannot index images without it.
    Options: start RAG-Anything, or describe the screenshots
    as text and ingest that via LightRAG."
```

### Flow 4: Cross-Engine Knowledge Query

```
User: "what do we know about the authentication flow?"

Orchestrator:
1. Check engines → LightRAG: online, Code-Graph-RAG: online
2. Intent: query (not ingest)
3. Both engines may have relevant data
4. Query LightRAG → returns docs, design notes, meeting decisions
5. Query Code-Graph-RAG → returns Auth classes, token handling functions
6. Synthesize → present labeled results from both engines
   [LightRAG] Authentication design doc, sprint notes...
   [Code-Graph-RAG] AuthManager.swift, TokenService.kt...
```

### Flow 5: Status Check

```
User: "status of RAG system" or "which engines are running?"

Orchestrator:
1. Run health checks on all three engines
2. Report availability and version info
3. Show document/asset counts if APIs support it
4. List which content types are serviceable vs degraded
```

---

## When to Use This Skill vs. Engine-Specific Skills

**Use `/rag` (this skill) when:**
- You don't know which engine to use
- You want the system to figure out the right engine for you
- You're doing a broad knowledge query across multiple sources
- You want a status overview of all RAG infrastructure

**Use engine-specific skills directly when:**
- You know exactly what engine you need
- You're doing engine-specific operations (reindex, clear index, configure)
- You need engine-specific options not exposed through the orchestrator

---

## Notes for Agents

The orchestrator is the recommended entry point for all RAG operations. Agents should default to `/rag` and let it route, unless they have a specific reason to invoke an engine skill directly.

Always surface the routing decision to the user. They should know which engine handled their request and why. If fallback routing was used, say so clearly — the user may want to bring the preferred engine online before proceeding.

When in doubt about content type, ask the user one clarifying question rather than guessing wrong and ingesting into the wrong engine.
