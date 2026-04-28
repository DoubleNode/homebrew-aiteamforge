---
name: code-graph-rag
description: Interact with Code-Graph-RAG engine for source code indexing, symbol querying, call graph analysis, and code-aware retrieval. SKELETON — awaiting package installation.
version: 0.1.0
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
  - Code-Graph-RAG server (port 9622) [NOT YET AVAILABLE]
tags:
  - rag
  - code-graph
  - source-code
  - knowledge-graph
  - symbol-analysis
  - call-graph
command_shortcut: /code-graph-rag
last_updated: 2026-04-07
status: skeleton
model: sonnet
---

# Code-Graph-RAG

## Skill Metadata

**Name:** Code-Graph-RAG
**Version:** 0.1.0 (Skeleton)
**Author:** Commander Jett Reno (Starfleet Academy)
**Command Shortcut:** `/code-graph-rag`
**Platforms:** All dev-team platforms
**Status:** SKELETON — package not yet installed
**Last Updated:** April 7, 2026

---

## WARNING: Engine Not Yet Available

```
+----------------------------------------------------------+
|  CODE-GRAPH-RAG ENGINE — NOT INSTALLED                   |
|                                                          |
|  Package:  code-graph-rag (pip)                          |
|  Port:     9622                                          |
|  Data Dir: ~/rag-data/code-graph                         |
|  Status:   SKELETON — API contracts documented as stubs  |
|                                                          |
|  All curl examples below are NON-FUNCTIONAL until the    |
|  package is installed and the server is running.         |
|                                                          |
|  See "When Available" section for installation steps.    |
+----------------------------------------------------------+
```

This skill documents the **planned API contract** for the Code-Graph-RAG engine. The API stubs represent a reasonable REST/JSON interface based on conventional code intelligence tooling. **Actual endpoints must be verified against the real package documentation once installed.**

---

## Purpose

Code-Graph-RAG is a source code intelligence RAG engine that builds knowledge graphs from source code. Unlike LightRAG (which indexes prose and documents), Code-Graph-RAG understands the **structure of code**: symbols, functions, classes, their relationships, call graphs, and inheritance hierarchies.

**Core capabilities (when operational):**

- **Repository Indexing** — Parse entire codebases into structured symbol graphs
- **Symbol Querying** — Find function definitions, class declarations, variable usages
- **Call Graph Analysis** — Trace who calls what, and what a function depends on
- **Inheritance Traversal** — Navigate class hierarchies and interface implementations
- **Cross-File Dependency Analysis** — Understand module dependencies and import graphs
- **Code-Aware Retrieval** — Answer "what does X do?", "who calls X?", "what does X import?"
- **Semantic Search** — Find code by description, not just by name

**Use Code-Graph-RAG when:** the question is about code structure, symbols, call flow, or dependencies.
**Use LightRAG when:** the question is about documentation, requirements, prose, or natural language content.

---

## Decision Tree: Code-Graph-RAG vs LightRAG

```
Is the question about...
        |
        +-- Code structure, symbols, functions, classes?
        |       --> Use Code-Graph-RAG (port 9622)
        |
        +-- Call graph: "who calls X?" / "what does X call?"
        |       --> Use Code-Graph-RAG (port 9622)
        |
        +-- Inheritance: "what implements X?" / "what extends X?"
        |       --> Use Code-Graph-RAG (port 9622)
        |
        +-- Documentation, requirements, design docs, prose?
        |       --> Use LightRAG (port 9621)
        |
        +-- Mixed: "what does the README say about the auth module?"
                --> Use BOTH: LightRAG for prose context,
                              Code-Graph-RAG for code structure
```

**Rule of thumb:** If it's in a `.swift`, `.kt`, `.ts`, `.py`, `.go`, `.java` file and you care about its *structure* — Code-Graph-RAG. If it's in a `.md`, `.txt`, `.pdf`, or any prose document — LightRAG.

---

## Configuration

| Setting | Value |
|---------|-------|
| Base URL | `http://localhost:9622` |
| Data directory | `~/rag-data/code-graph` |
| Package | `code-graph-rag` (pip) |
| Start command | `python -m code_graph_rag serve --port 9622 --data-dir ~/rag-data/code-graph` |
| Status check | `curl http://localhost:9622/health` |

---

## API Contract Stubs

> All examples below are **STUBS**. They document the expected/planned interface.
> None will work until the Code-Graph-RAG package is installed and the server is running.

---

### Health and Status

#### Health Check

```bash
# STUB — Code-Graph-RAG is not yet installed
curl http://localhost:9622/health
```

Expected response:
```json
{
  "status": "ok",
  "engine": "code-graph-rag",
  "version": "x.x.x",
  "repositories_indexed": 0,
  "total_symbols": 0
}
```

#### Indexing Status

```bash
# STUB — Code-Graph-RAG is not yet installed
curl http://localhost:9622/status
```

Expected response:
```json
{
  "indexing": false,
  "last_indexed": null,
  "repositories": [],
  "symbol_count": 0,
  "graph_edges": 0
}
```

---

### Index Operations

#### Index a Repository

```bash
# STUB — Code-Graph-RAG is not yet installed
curl -X POST http://localhost:9622/index \
  -H "Content-Type: application/json" \
  -d '{
    "path": "/path/to/your/repo",
    "name": "my-project",
    "languages": ["swift", "python"],
    "exclude": ["**/Tests/**", "**/.build/**", "**/node_modules/**"]
  }'
```

Expected response:
```json
{
  "job_id": "idx-abc123",
  "status": "queued",
  "repository": "my-project",
  "estimated_duration_seconds": 30
}
```

#### Check Indexing Job Status

```bash
# STUB — Code-Graph-RAG is not yet installed
curl http://localhost:9622/index/status/idx-abc123
```

Expected response:
```json
{
  "job_id": "idx-abc123",
  "status": "complete",
  "symbols_indexed": 1247,
  "files_processed": 89,
  "duration_seconds": 22
}
```

#### List Indexed Repositories

```bash
# STUB — Code-Graph-RAG is not yet installed
curl http://localhost:9622/repositories
```

Expected response:
```json
{
  "repositories": [
    {
      "name": "my-project",
      "path": "/path/to/your/repo",
      "languages": ["swift"],
      "symbol_count": 1247,
      "last_indexed": "2026-04-07T12:00:00Z"
    }
  ]
}
```

#### Remove a Repository from Index

```bash
# STUB — Code-Graph-RAG is not yet installed
curl -X DELETE http://localhost:9622/repositories/my-project
```

---

### Symbol Management

#### Search Symbols by Name

```bash
# STUB — Code-Graph-RAG is not yet installed
curl -X POST http://localhost:9622/symbols/search \
  -H "Content-Type: application/json" \
  -d '{
    "query": "AuthManager",
    "type": "class",
    "repository": "my-project",
    "limit": 10
  }'
```

Expected `type` values: `function`, `class`, `struct`, `enum`, `protocol`, `interface`, `variable`, `constant`, `module`, `any`

Expected response:
```json
{
  "symbols": [
    {
      "name": "AuthManager",
      "type": "class",
      "file": "Sources/Auth/AuthManager.swift",
      "line": 12,
      "repository": "my-project",
      "signature": "class AuthManager: NSObject",
      "doc_comment": "Manages user authentication state and token lifecycle."
    }
  ],
  "total": 1
}
```

#### Get Symbol Details

```bash
# STUB — Code-Graph-RAG is not yet installed
curl "http://localhost:9622/symbols/my-project/AuthManager"
```

Expected response:
```json
{
  "name": "AuthManager",
  "type": "class",
  "file": "Sources/Auth/AuthManager.swift",
  "line": 12,
  "end_line": 87,
  "repository": "my-project",
  "signature": "class AuthManager: NSObject",
  "inherits_from": ["NSObject"],
  "conforms_to": ["AuthProviding", "Loggable"],
  "methods": ["login(email:password:)", "logout()", "refreshToken()"],
  "properties": ["currentUser", "isAuthenticated", "tokenExpiry"],
  "doc_comment": "Manages user authentication state and token lifecycle.",
  "source_snippet": "class AuthManager: NSObject {\n    ...\n}"
}
```

#### List All Symbols in a File

```bash
# STUB — Code-Graph-RAG is not yet installed
curl "http://localhost:9622/symbols/my-project/file?path=Sources/Auth/AuthManager.swift"
```

---

### Query Operations

#### Natural Language Code Query

Ask a question about the codebase in plain English:

```bash
# STUB — Code-Graph-RAG is not yet installed
curl -X POST http://localhost:9622/query \
  -H "Content-Type: application/json" \
  -d '{
    "query": "How does authentication work in this project?",
    "repository": "my-project",
    "mode": "semantic",
    "limit": 5
  }'
```

Expected `mode` values: `semantic` (meaning-based), `structural` (graph traversal), `hybrid` (both)

Expected response:
```json
{
  "answer": "Authentication is handled by AuthManager, which...",
  "sources": [
    {
      "file": "Sources/Auth/AuthManager.swift",
      "lines": "12-87",
      "symbol": "AuthManager",
      "relevance": 0.97
    }
  ],
  "query_mode": "semantic",
  "duration_ms": 145
}
```

#### Query with Repository Filter

```bash
# STUB — Code-Graph-RAG is not yet installed
curl -X POST http://localhost:9622/query \
  -H "Content-Type: application/json" \
  -d '{
    "query": "What classes handle network requests?",
    "repository": "my-project",
    "mode": "hybrid",
    "filters": {
      "file_pattern": "Sources/**",
      "symbol_types": ["class", "struct"]
    },
    "limit": 10
  }'
```

---

### Call Graph Operations

#### Find Callers (Who Calls This Function?)

```bash
# STUB — Code-Graph-RAG is not yet installed
curl -X POST http://localhost:9622/graph/callers \
  -H "Content-Type: application/json" \
  -d '{
    "symbol": "AuthManager.login(email:password:)",
    "repository": "my-project",
    "depth": 2
  }'
```

Expected response:
```json
{
  "symbol": "AuthManager.login(email:password:)",
  "callers": [
    {
      "symbol": "LoginViewModel.submitCredentials()",
      "file": "Sources/Login/LoginViewModel.swift",
      "line": 45,
      "call_site_line": 48
    },
    {
      "symbol": "BiometricAuthCoordinator.authenticateWithBiometrics()",
      "file": "Sources/Auth/BiometricAuthCoordinator.swift",
      "line": 23,
      "call_site_line": 31
    }
  ],
  "depth_searched": 2,
  "total_callers": 2
}
```

#### Find Callees (What Does This Function Call?)

```bash
# STUB — Code-Graph-RAG is not yet installed
curl -X POST http://localhost:9622/graph/callees \
  -H "Content-Type: application/json" \
  -d '{
    "symbol": "AuthManager.login(email:password:)",
    "repository": "my-project",
    "depth": 1
  }'
```

Expected response:
```json
{
  "symbol": "AuthManager.login(email:password:)",
  "callees": [
    {
      "symbol": "NetworkClient.post(endpoint:body:)",
      "file": "Sources/Network/NetworkClient.swift",
      "line": 12
    },
    {
      "symbol": "TokenStore.save(token:)",
      "file": "Sources/Storage/TokenStore.swift",
      "line": 34
    }
  ],
  "depth_searched": 1,
  "total_callees": 2
}
```

#### Get Full Call Graph for a Symbol

```bash
# STUB — Code-Graph-RAG is not yet installed
curl -X POST http://localhost:9622/graph/subgraph \
  -H "Content-Type: application/json" \
  -d '{
    "symbol": "AuthManager",
    "repository": "my-project",
    "direction": "both",
    "depth": 3,
    "format": "json"
  }'
```

Expected `direction` values: `callers`, `callees`, `both`
Expected `format` values: `json`, `dot` (Graphviz), `mermaid`

---

### Inheritance and Interface Operations

#### Find Implementors of a Protocol/Interface

```bash
# STUB — Code-Graph-RAG is not yet installed
curl -X POST http://localhost:9622/graph/implementors \
  -H "Content-Type: application/json" \
  -d '{
    "symbol": "AuthProviding",
    "repository": "my-project"
  }'
```

Expected response:
```json
{
  "protocol": "AuthProviding",
  "implementors": [
    {
      "name": "AuthManager",
      "type": "class",
      "file": "Sources/Auth/AuthManager.swift",
      "line": 12
    },
    {
      "name": "MockAuthManager",
      "type": "class",
      "file": "Tests/Mocks/MockAuthManager.swift",
      "line": 5
    }
  ],
  "total": 2
}
```

#### Find Subclasses

```bash
# STUB — Code-Graph-RAG is not yet installed
curl -X POST http://localhost:9622/graph/subclasses \
  -H "Content-Type: application/json" \
  -d '{
    "symbol": "BaseViewController",
    "repository": "my-project",
    "depth": 2
  }'
```

#### Get Full Inheritance Hierarchy

```bash
# STUB — Code-Graph-RAG is not yet installed
curl "http://localhost:9622/graph/hierarchy/my-project/AuthManager"
```

---

### Dependency Analysis

#### Module/File Dependencies

What does a file import, and what imports it?

```bash
# STUB — Code-Graph-RAG is not yet installed
curl -X POST http://localhost:9622/dependencies \
  -H "Content-Type: application/json" \
  -d '{
    "file": "Sources/Auth/AuthManager.swift",
    "repository": "my-project",
    "direction": "both"
  }'
```

Expected response:
```json
{
  "file": "Sources/Auth/AuthManager.swift",
  "imports": ["Foundation", "Combine", "Sources/Network/NetworkClient"],
  "imported_by": [
    "Sources/Login/LoginViewModel.swift",
    "Sources/Profile/ProfileCoordinator.swift"
  ]
}
```

#### Find Circular Dependencies

```bash
# STUB — Code-Graph-RAG is not yet installed
curl -X POST http://localhost:9622/dependencies/cycles \
  -H "Content-Type: application/json" \
  -d '{
    "repository": "my-project"
  }'
```

---

## Planned Query Types

When operational, Code-Graph-RAG will support these query patterns:

### Symbol Lookup
- "Find the definition of `AuthManager`"
- "Where is `login(email:password:)` defined?"
- "What classes conform to `AuthProviding`?"
- "Show me all enums in the Auth module"

### Call Graph Traversal
- "Who calls `logout()`?"
- "What does `fetchUserProfile()` call?"
- "Trace the full call chain from `LoginViewController` to the network layer"
- "Find all entry points that eventually call `TokenStore.save()`"

### Dependency Analysis
- "What does `AuthManager.swift` depend on?"
- "Which files import `NetworkClient`?"
- "Are there any circular dependencies in the project?"
- "What would break if I changed `UserSession`?"

### Inheritance and Protocols
- "What implements `AuthProviding`?"
- "What does `BaseCoordinator` extend?"
- "Show the full class hierarchy for `UIViewController` subclasses"
- "Which classes override `viewDidLoad()`?"

### Impact Analysis
- "If I refactor `NetworkClient`, what else is affected?"
- "What's the blast radius of changing `UserSession.id`?"
- "Which modules would need to change if I rename `AuthManager`?"

---

## Integration Patterns

### Using Code-Graph-RAG in a Development Workflow

1. **Before refactoring a symbol** — query callers/callees to understand impact
2. **When onboarding to a new codebase** — index the repo, then query for high-level structure
3. **Debugging a crash** — trace call graph from the crash site back to the entry point
4. **Architecture review** — check for circular dependencies, find god classes, map inheritance depth
5. **Code review** — verify that a changed function's call sites are updated appropriately

### Combining with LightRAG

For full-context answers, query both engines:

```bash
# STUB — Code-Graph-RAG is not yet installed

# 1. Get prose context from LightRAG (port 9621)
curl -X POST http://localhost:9621/query \
  -H "Content-Type: application/json" \
  -d '{"query": "authentication design decisions", "mode": "hybrid"}'

# 2. Get code structure from Code-Graph-RAG (port 9622)
curl -X POST http://localhost:9622/query \
  -H "Content-Type: application/json" \
  -d '{"query": "authentication classes and their relationships", "repository": "my-project"}'

# Synthesize both responses to give a complete answer
```

---

## When Available: Installation and Setup

When the `code-graph-rag` package becomes available, follow these steps:

### 1. Install the Package

```bash
# Install in the RAG engines venv
source ~/rag-data/.venv/bin/activate
pip install code-graph-rag
```

Or with extras if the package supports them:

```bash
pip install "code-graph-rag[server,all]"
```

### 2. Create Data Directory

```bash
mkdir -p ~/rag-data/code-graph
```

### 3. Start the Server

```bash
python -m code_graph_rag serve \
  --port 9622 \
  --data-dir ~/rag-data/code-graph
```

Or via the LCARS engine manager if integrated:

```bash
# Through LCARS UI engine panel — select Code-Graph-RAG and click Start
```

### 4. Verify Installation

```bash
curl http://localhost:9622/health
# Should return: {"status": "ok", ...}
```

### 5. Update This Skill

Once the real API is confirmed, update this SKILL.md to:
- Replace all `# STUB — Code-Graph-RAG is not yet installed` comments with actual working examples
- Correct any endpoint paths or request/response shapes that differ from the stubs
- Update `status: skeleton` to `status: production-ready` in the frontmatter
- Bump version from `0.1.0` to `1.0.0`

### 6. Integrate with LCARS

Add Code-Graph-RAG to the LCARS RAG engine registry so it appears in the engine dropdown and management UI. See `lcars-ui/rag_engines/` for the engine plugin pattern.

---

## Error Handling

When Code-Graph-RAG is not running, expect connection refused:

```
curl: (7) Failed to connect to localhost port 9622 after 0 ms: Connection refused
```

Check if the server is running:

```bash
pgrep -f "code_graph_rag serve" || echo "Server not running"
```

Start it if needed (once installed):

```bash
python -m code_graph_rag serve --port 9622 --data-dir ~/rag-data/code-graph &
```

---

## Notes for Future Implementation

- The API contract above is based on conventional REST patterns for code intelligence servers. The actual `code-graph-rag` package may use different endpoint names, request shapes, or response formats.
- If the package uses GraphQL instead of REST, the skill will need significant revision.
- If the package has a Python SDK in addition to HTTP endpoints, prefer the SDK for complex traversals.
- Consider streaming responses for large call graph queries — deep traversals on big codebases can be slow.
- Index storage at `~/rag-data/code-graph` should be treated as ephemeral — the index can be rebuilt from source at any time. Don't back it up; back up the source instead.
