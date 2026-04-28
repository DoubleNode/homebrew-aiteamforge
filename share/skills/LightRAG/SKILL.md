---
name: lightrag
description: Interact with LightRAG knowledge graph engine for document ingestion, querying, graph management, and status monitoring.
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
  - LightRAG server (port 9621)
tags:
  - rag
  - lightrag
  - knowledge-graph
  - document-ingestion
  - query
  - retrieval
command_shortcut: /lightrag
last_updated: 2026-04-07
status: production-ready
model: sonnet
---

# LightRAG Skill

## Skill Metadata

**Name:** LightRAG
**Version:** 1.0.0
**Author:** Commander Jett Reno (Starfleet Academy)
**Command Shortcut:** `/lightrag`
**Platforms:** All dev-team platforms
**Last Updated:** April 7, 2026

---

## Purpose

LightRAG is a text knowledge graph RAG (Retrieval-Augmented Generation) engine that builds a knowledge graph from your documents and lets you query it with natural language. Unlike simple vector search, it extracts entities and relationships, enabling smarter retrieval across the document corpus.

**Use LightRAG when you need to:**
- Ingest documents (PDFs, text files, markdown) into a queryable knowledge base
- Ask questions that require reasoning across multiple documents
- Explore relationships between entities in your document corpus
- Manage a persistent knowledge graph for a project or domain

**Base URL:** `http://localhost:9621`

**Current config (verify with /health):**
- LLM: `ollama/mistral-nemo:latest`
- Embedding: `ollama`
- Storage: JsonKV + NanoVectorDB + NetworkX
- Core version: 1.4.13 | API version: 0281
- Data directory: `{team_kanban_dir}/rag-data/lightrag` (resolved per team)
- Input directory: `~/dev-team/lcars-ui/inputs`

---

## Prerequisites

The LightRAG server must be running on port 9621. Verify with:

```bash
curl -s http://localhost:9621/health | python3 -m json.tool
```

A healthy response returns `"status": "healthy"`. If the server is not running, start it before proceeding. Auth mode is currently disabled — no tokens needed.

---

## Decision Tree: What Do You Need to Do?

```
User wants to ask a question about existing documents
  -> Use: Query (POST /query)

User wants to add new documents to the knowledge graph
  -> Upload a file: POST /documents/upload
  -> Scan a directory: POST /documents/scan
  -> Insert raw text: POST /documents/text

User wants to check if documents are being processed
  -> Use: GET /documents/pipeline_status

User wants to see what's in the knowledge graph
  -> List documents: GET /documents
  -> List graph labels: GET /graph/label/list

User wants to explore or edit the graph structure
  -> Search labels: GET /graph/label/search?query=...
  -> Edit/create entities and relations: POST /graph/entity/edit, etc.

User wants to check server health or configuration
  -> Use: GET /health
```

---

## Query

### Query the Knowledge Graph

The main query endpoint. Always use this for natural language questions.

```bash
curl -s -X POST http://localhost:9621/query \
  -H "Content-Type: application/json" \
  -d '{
    "query": "What are the main features of the kanban system?",
    "mode": "hybrid",
    "stream": false
  }' | python3 -m json.tool
```

**Query Modes — Pick the Right One:**

| Mode | When to Use | How It Works |
|------|-------------|--------------|
| `hybrid` | Default, best for most questions | Combines local (entity-focused) and global (thematic) retrieval |
| `local` | Questions about specific entities, people, or components | Searches the knowledge graph neighborhood around matching entities |
| `global` | Big-picture or thematic questions | Searches across high-level concepts and document summaries |
| `naive` | Simple keyword/semantic search, no graph reasoning | Pure vector similarity, similar to traditional RAG |

**Rule of thumb:**
- "What does X do?" -> `local`
- "What are the main themes?" -> `global`
- "Tell me about X in relation to Y" -> `hybrid`
- "Find mentions of X" -> `naive`

### Streaming Query

For long responses where you want output as it generates:

```bash
curl -s -X POST http://localhost:9621/query/stream \
  -H "Content-Type: application/json" \
  -d '{
    "query": "Summarize the architecture of the LCARS system",
    "mode": "hybrid"
  }'
```

Responses stream as Server-Sent Events. Each line is a chunk of the response.

### Query with Data Return

Returns the retrieved context chunks along with the answer — useful for debugging retrieval quality:

```bash
curl -s -X POST http://localhost:9621/query/data \
  -H "Content-Type: application/json" \
  -d '{
    "query": "What kanban states are available?",
    "mode": "local"
  }' | python3 -m json.tool
```

---

## Document Ingestion

### Upload a File

Upload a single file for ingestion into the knowledge graph:

```bash
curl -s -X POST http://localhost:9621/documents/upload \
  -F "file=@/path/to/your/document.txt" | python3 -m json.tool
```

Supported formats: `.txt`, `.md`, `.pdf` (check server capabilities). The server will return a `track_id` you can use to monitor processing status.

### Scan a Directory

Tell LightRAG to scan a directory and ingest all documents it finds there. The server's configured input directory is `~/dev-team/lcars-ui/inputs`.

```bash
curl -s -X POST http://localhost:9621/documents/scan \
  -H "Content-Type: application/json" \
  -d '{}' | python3 -m json.tool
```

To scan a specific directory (if server supports it):

```bash
curl -s -X POST http://localhost:9621/documents/scan \
  -H "Content-Type: application/json" \
  -d '{"directory": "/path/to/documents"}' | python3 -m json.tool
```

### Insert Text Directly

Insert a single block of text without a file:

```bash
curl -s -X POST http://localhost:9621/documents/text \
  -H "Content-Type: application/json" \
  -d '{
    "text": "The kanban system uses five workflow states: backlog, in-progress, review, done, and cancelled.",
    "description": "Kanban workflow states overview"
  }' | python3 -m json.tool
```

### Insert Multiple Texts

Insert several text blocks in one request:

```bash
curl -s -X POST http://localhost:9621/documents/texts \
  -H "Content-Type: application/json" \
  -d '{
    "texts": [
      {"text": "First document content here.", "description": "Doc 1"},
      {"text": "Second document content here.", "description": "Doc 2"}
    ]
  }' | python3 -m json.tool
```

---

## Document Management

### List Documents

```bash
curl -s http://localhost:9621/documents | python3 -m json.tool
```

### Paginated Document List

```bash
curl -s -X POST http://localhost:9621/documents/paginated \
  -H "Content-Type: application/json" \
  -d '{
    "page": 1,
    "page_size": 20
  }' | python3 -m json.tool
```

### Check Document Status Counts

Get a count of documents by processing status (pending, processing, done, failed):

```bash
curl -s http://localhost:9621/documents/status_counts | python3 -m json.tool
```

### Track a Specific Document

After uploading, use the returned `track_id` to check processing status:

```bash
curl -s http://localhost:9621/documents/track_status/YOUR_TRACK_ID | python3 -m json.tool
```

### Reprocess Failed Documents

If documents failed processing, retry them:

```bash
curl -s -X POST http://localhost:9621/documents/reprocess_failed \
  -H "Content-Type: application/json" \
  -d '{}' | python3 -m json.tool
```

### Delete a Specific Document

```bash
curl -s -X DELETE "http://localhost:9621/documents/delete_document?doc_id=YOUR_DOC_ID" \
  | python3 -m json.tool
```

### Delete All Documents

**Destructive — clears the entire document store:**

```bash
curl -s -X DELETE http://localhost:9621/documents | python3 -m json.tool
```

### Cancel Active Pipeline

If a processing pipeline is stuck or you want to stop it:

```bash
curl -s -X POST http://localhost:9621/documents/cancel_pipeline \
  -H "Content-Type: application/json" \
  -d '{}' | python3 -m json.tool
```

### Clear Document Cache

```bash
curl -s -X POST http://localhost:9621/documents/clear_cache \
  -H "Content-Type: application/json" \
  -d '{}' | python3 -m json.tool
```

### Delete an Entity

Remove a specific entity from the knowledge graph:

```bash
curl -s -X DELETE http://localhost:9621/documents/delete_entity \
  -H "Content-Type: application/json" \
  -d '{"entity_name": "EntityNameHere"}' | python3 -m json.tool
```

### Delete a Relation

Remove a specific relation from the knowledge graph:

```bash
curl -s -X DELETE http://localhost:9621/documents/delete_relation \
  -H "Content-Type: application/json" \
  -d '{"source": "EntityA", "target": "EntityB"}' | python3 -m json.tool
```

---

## Pipeline Status

Check if the processing pipeline is currently active:

```bash
curl -s http://localhost:9621/documents/pipeline_status | python3 -m json.tool
```

**Key fields in the response:**
- `busy` — `true` if currently processing documents
- `job_name` — Name of the current job (or `-` if idle)
- `docs` — Total documents in the current job
- `cur_batch` / `batchs` — Current batch out of total batches
- `latest_message` — Most recent status message
- `history_messages` — Log of processing messages

**Workflow for ingesting and verifying documents:**
1. Upload or scan documents
2. Poll `GET /documents/pipeline_status` until `busy` is `false`
3. Check `GET /documents/status_counts` to confirm all docs are `done`
4. If any are `failed`, call `POST /documents/reprocess_failed`

---

## Graph Management

### List All Graph Labels

Labels are entity types in the knowledge graph:

```bash
curl -s http://localhost:9621/graph/label/list | python3 -m json.tool
```

### Get Popular Labels

```bash
curl -s http://localhost:9621/graph/label/popular | python3 -m json.tool
```

### Search Labels

```bash
curl -s "http://localhost:9621/graph/label/search?query=kanban" | python3 -m json.tool
```

### Get Graph Data

Retrieve graph nodes and edges (use carefully — can be large):

```bash
curl -s http://localhost:9621/graphs | python3 -m json.tool
```

### Check If Entity Exists

```bash
curl -s "http://localhost:9621/graph/entity/exists?entity_name=LCARS" | python3 -m json.tool
```

### Create an Entity

```bash
curl -s -X POST http://localhost:9621/graph/entity/create \
  -H "Content-Type: application/json" \
  -d '{
    "entity_name": "NewEntityName",
    "entity_type": "SYSTEM",
    "description": "Description of this entity",
    "source_id": "manual"
  }' | python3 -m json.tool
```

### Edit an Entity

```bash
curl -s -X POST http://localhost:9621/graph/entity/edit \
  -H "Content-Type: application/json" \
  -d '{
    "entity_name": "ExistingEntityName",
    "description": "Updated description for this entity"
  }' | python3 -m json.tool
```

### Merge Entities

Merge duplicate or related entities into one:

```bash
curl -s -X POST http://localhost:9621/graph/entities/merge \
  -H "Content-Type: application/json" \
  -d '{
    "source_entities": ["EntityA", "EntityB"],
    "target_entity": "MergedEntity"
  }' | python3 -m json.tool
```

### Create a Relation

```bash
curl -s -X POST http://localhost:9621/graph/relation/create \
  -H "Content-Type: application/json" \
  -d '{
    "src_id": "SourceEntity",
    "tgt_id": "TargetEntity",
    "description": "SourceEntity connects to TargetEntity because...",
    "keywords": "connection, integration",
    "weight": 1.0,
    "source_id": "manual"
  }' | python3 -m json.tool
```

### Edit a Relation

```bash
curl -s -X POST http://localhost:9621/graph/relation/edit \
  -H "Content-Type: application/json" \
  -d '{
    "src_id": "SourceEntity",
    "tgt_id": "TargetEntity",
    "description": "Updated relation description"
  }' | python3 -m json.tool
```

---

## Health and System Status

### Full Health Check

Returns server status, configuration, pipeline state, and version info:

```bash
curl -s http://localhost:9621/health | python3 -m json.tool
```

**Key fields to check:**
- `status` — Should be `"healthy"`
- `pipeline_busy` — `true` if currently processing
- `configuration.llm_model` — Which LLM is in use
- `configuration.embedding_model` — Which embedding model is in use
- `core_version` / `api_version` — LightRAG version info

### Version Info

```bash
curl -s http://localhost:9621/api/version | python3 -m json.tool
```

### List Available Models (Ollama-Compatible)

```bash
curl -s http://localhost:9621/api/tags | python3 -m json.tool
```

### Show Running Models

```bash
curl -s http://localhost:9621/api/ps | python3 -m json.tool
```

---

## Error Handling

**If the server is not reachable:**
- Verify the LightRAG server process is running
- Check that nothing else is occupying port 9621
- Run `curl -s http://localhost:9621/health` — if this fails, the server is down

**If documents are stuck in "processing":**
1. Check `GET /documents/pipeline_status` — look at `history_messages` for clues
2. If the pipeline appears stuck (busy but no progress), cancel it: `POST /documents/cancel_pipeline`
3. Retry failed documents: `POST /documents/reprocess_failed`
4. Check the LightRAG server logs for underlying errors (LLM timeouts, embedding failures)

**If queries return poor results:**
- Try a different query mode (`local` vs `global` vs `hybrid`)
- Verify documents have been fully processed (`status_counts` should show all as `done`)
- Use `POST /query/data` to inspect what context is actually being retrieved
- If the graph is sparse, ingest more related documents

**If the LLM is slow or timing out:**
- Check `GET /health` to confirm `llm_binding_host` is reachable (default: `http://localhost:11434`)
- Verify Ollama is running: `curl -s http://localhost:11434/api/tags`
- The `max_async` config (currently 4) limits concurrent LLM calls — high-volume ingestion may queue

**Common HTTP status codes:**
- `200` — Success
- `400` — Bad request (check your JSON body)
- `404` — Endpoint not found (check the URL)
- `500` — Server error (check server logs)

---

## Complete Ingestion Workflow Example

Here's the full workflow for ingesting a document and querying it:

```bash
# Step 1: Verify server is healthy
curl -s http://localhost:9621/health | python3 -m json.tool

# Step 2: Upload a document (save the track_id from the response)
curl -s -X POST http://localhost:9621/documents/upload \
  -F "file=@/path/to/my-document.md"

# Step 3: Check pipeline is processing
curl -s http://localhost:9621/documents/pipeline_status \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('busy:', d['busy'], '| docs:', d['docs'], '| batch:', d['cur_batch'], '/', d['batchs'])"

# Step 4: Wait for pipeline to finish (busy becomes false)
# Repeat step 3 until busy=false

# Step 5: Confirm document status
curl -s http://localhost:9621/documents/status_counts | python3 -m json.tool

# Step 6: Query the knowledge graph
curl -s -X POST http://localhost:9621/query \
  -H "Content-Type: application/json" \
  -d '{
    "query": "What is the main topic of this document?",
    "mode": "hybrid",
    "stream": false
  }' | python3 -m json.tool
```

---

## Notes on the Current Configuration

- **Auth is disabled** — No Authorization headers needed
- **LLM caching is enabled** — Repeated identical queries may return faster from cache
- **Max parallel insert is 2** — Ingesting large batches will queue automatically
- **Cosine threshold is 0.2** — Fairly permissive similarity matching
- **Max graph nodes is 1000** — Large corpora may hit this limit; monitor with `/graphs`
- **Input directory** for scans: `~/dev-team/lcars-ui/inputs` — drop files here before scanning
