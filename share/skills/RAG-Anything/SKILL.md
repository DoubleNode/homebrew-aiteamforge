---
name: rag-anything
description: Interact with RAG-Anything engine for multimodal document ingestion (text, images, tables, audio), querying, and asset management. SKELETON — awaiting package installation.
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
  - RAG-Anything server (port 9623) [NOT YET AVAILABLE]
  - Optional: tesseract (OCR), ffmpeg (audio/video)
tags:
  - rag
  - multimodal
  - images
  - audio
  - tables
  - ocr
  - document-ingestion
command_shortcut: /rag-anything
last_updated: 2026-04-07
status: skeleton
model: sonnet
---

# RAG-Anything

## Skill Metadata

**Name:** RAG-Anything
**Version:** 0.1.0
**Author:** Commander Jett Reno (Starfleet Academy Engineering Lab)
**Command:** `/rag-anything`
**Platforms:** All terminals (auto-detects team)
**Last Updated:** April 7, 2026
**Status:** SKELETON — Engine not yet installed

---

## STATUS: NOT INSTALLED

> **WARNING: RAG-Anything is not yet installed on this system.**
>
> This skill is a skeleton with documented API contract stubs. All curl examples
> in this document are marked with `# STUB` — they will not work until the
> package is installed and the server is running.
>
> See the "When Available" section at the bottom for activation instructions.
>
> Do NOT attempt to use this skill against live data until installation is complete.

---

## Purpose

RAG-Anything is a multimodal Retrieval-Augmented Generation engine. Unlike text-only
RAG systems (such as LightRAG), RAG-Anything can ingest, index, and retrieve across
mixed-format content including:

- Plain text and Markdown documents
- PDF files (text extraction + optional OCR for scanned pages)
- Images (PNG, JPG, WEBP) — with optional OCR via tesseract
- Structured tables (CSV, Excel/XLSX)
- Audio files (MP3, WAV) — with optional transcription via ffmpeg
- Video keyframes (MP4, MOV) — frame extraction via ffmpeg

RAG-Anything is the right engine when your knowledge base contains more than just text.
If you're working purely with text documents, use LightRAG instead (it's lighter, faster,
and already installed).

---

## When to Use RAG-Anything vs LightRAG

| Need | Use |
|------|-----|
| Text documents only (markdown, plain text, PDF with clean text) | LightRAG |
| Images, diagrams, screenshots | RAG-Anything |
| Audio recordings, podcasts, transcripts | RAG-Anything |
| Mixed-format corpus (text + images + tables) | RAG-Anything |
| Scanned PDFs requiring OCR | RAG-Anything |
| Spreadsheets, CSV data with narrative questions | RAG-Anything |
| Graph-structured knowledge relationships | LightRAG |
| Speed-critical retrieval, simple text corpus | LightRAG |

Rule of thumb: if any asset in your corpus is not plain text, use RAG-Anything.

---

## Server Configuration

**Base URL:** `http://localhost:9623`
**Data directory:** `~/rag-data/rag-anything`
**Package:** `rag-anything` (pip)
**Start command:** `python -m rag_anything serve --port 9623 --data-dir ~/rag-data/rag-anything`

---

## Supported Modalities

| Modality | Formats | System Dep Required |
|----------|---------|---------------------|
| Plain text | .txt, .md, .rst | None |
| PDF | .pdf | None (text layer); tesseract for scanned |
| Images | .png, .jpg, .jpeg, .webp | tesseract (for text extraction from images) |
| Tables | .csv, .xlsx, .xls | None |
| Audio | .mp3, .wav, .m4a, .ogg | ffmpeg (transcription pipeline) |
| Video frames | .mp4, .mov, .avi | ffmpeg (keyframe extraction) |

### Graceful Degradation Without System Dependencies

- **Without tesseract:** Image files are still indexed by filename and metadata. OCR-based
  text extraction from images and scanned PDFs is skipped. Query results will not include
  image text content.

- **Without ffmpeg:** Audio and video files are still indexed by filename and metadata.
  Transcription and frame extraction are skipped. Query results will not include
  spoken or visual content from media files.

Install both for full multimodal capability:
```bash
# macOS
brew install tesseract ffmpeg

# Ubuntu/Debian
apt-get install tesseract-ocr ffmpeg
```

---

## Expected API Contract

All endpoints below are STUBS. The actual RAG-Anything package API may differ
once installed. These represent a reasonable conventional REST+JSON contract
inferred from package documentation.

### Ingest

#### Upload a File (any type)

```bash
# STUB — Upload a single file for ingestion
curl -X POST http://localhost:9623/ingest/file \
  -F "file=@/path/to/document.pdf" \
  -F "collection=my-collection" \
  -F "metadata={\"source\":\"manual\",\"tags\":[\"docs\"]}"
```

Expected response:
```json
{
  "asset_id": "asset_abc123",
  "filename": "document.pdf",
  "modality": "pdf",
  "status": "queued",
  "estimated_processing_seconds": 12
}
```

#### Scan a Directory

```bash
# STUB — Recursively ingest all supported files from a directory
curl -X POST http://localhost:9623/ingest/directory \
  -H "Content-Type: application/json" \
  -d '{
    "path": "/Users/me/documents/project-assets",
    "collection": "my-collection",
    "recursive": true,
    "extensions": [".pdf", ".png", ".csv", ".mp3"]
  }'
```

Expected response:
```json
{
  "job_id": "job_xyz789",
  "queued_count": 47,
  "skipped_count": 3,
  "status": "processing"
}
```

#### Insert Raw Text

```bash
# STUB — Insert plain text directly without a file
curl -X POST http://localhost:9623/ingest/text \
  -H "Content-Type: application/json" \
  -d '{
    "content": "The warp core requires dilithium crystals operating at 95% efficiency...",
    "collection": "my-collection",
    "title": "Warp Core Operations Note",
    "metadata": {"source": "manual-entry", "author": "reno"}
  }'
```

Expected response:
```json
{
  "asset_id": "asset_text_def456",
  "modality": "text",
  "status": "indexed",
  "chunk_count": 3
}
```

#### Upload an Image

```bash
# STUB — Upload image for visual indexing (with OCR if tesseract available)
curl -X POST http://localhost:9623/ingest/image \
  -F "file=@/path/to/diagram.png" \
  -F "collection=my-collection" \
  -F "description=System architecture diagram showing warp field geometry" \
  -F "ocr=true"
```

Expected response:
```json
{
  "asset_id": "asset_img_ghi789",
  "filename": "diagram.png",
  "modality": "image",
  "ocr_performed": true,
  "ocr_text_extracted": "WARP FIELD GEOMETRY\nLayer 1: Primary coil...",
  "status": "indexed"
}
```

#### Upload Audio

```bash
# STUB — Upload audio file for transcription and indexing (requires ffmpeg)
curl -X POST http://localhost:9623/ingest/audio \
  -F "file=@/path/to/recording.mp3" \
  -F "collection=my-collection" \
  -F "language=en"
```

Expected response:
```json
{
  "asset_id": "asset_audio_jkl012",
  "filename": "recording.mp3",
  "modality": "audio",
  "duration_seconds": 342,
  "transcription_status": "processing",
  "status": "queued"
}
```

---

### Query

#### Query Across All Modalities

```bash
# STUB — Query the collection using natural language
curl -X POST http://localhost:9623/query \
  -H "Content-Type: application/json" \
  -d '{
    "query": "What are the startup procedures for the warp core?",
    "collection": "my-collection",
    "top_k": 5
  }'
```

Expected response:
```json
{
  "query": "What are the startup procedures for the warp core?",
  "results": [
    {
      "asset_id": "asset_abc123",
      "filename": "warp-manual.pdf",
      "modality": "pdf",
      "score": 0.94,
      "excerpt": "Step 1: Initialize dilithium matrix...",
      "page": 12
    },
    {
      "asset_id": "asset_img_ghi789",
      "filename": "startup-checklist.png",
      "modality": "image",
      "score": 0.87,
      "excerpt": "STARTUP CHECKLIST\n1. Verify plasma flow...",
      "ocr_source": true
    }
  ],
  "total_results": 2
}
```

#### Query with Modality Filter

```bash
# STUB — Restrict query to specific content types
curl -X POST http://localhost:9623/query \
  -H "Content-Type: application/json" \
  -d '{
    "query": "plasma conduit diagrams",
    "collection": "my-collection",
    "modalities": ["image", "pdf"],
    "top_k": 10
  }'
```

Expected response structure is identical to the unfiltered query above.

---

### Asset Management

#### List Assets by Type

```bash
# STUB — List all assets in a collection, optionally filtered by modality
curl "http://localhost:9623/assets?collection=my-collection&modality=image&limit=50&offset=0"
```

Expected response:
```json
{
  "collection": "my-collection",
  "modality_filter": "image",
  "total": 23,
  "assets": [
    {
      "asset_id": "asset_img_ghi789",
      "filename": "diagram.png",
      "modality": "image",
      "status": "indexed",
      "ingested_at": "2026-04-07T10:32:11Z",
      "size_bytes": 204800
    }
  ]
}
```

#### Check Processing Status

```bash
# STUB — Check the status of an ingested asset or batch job
curl "http://localhost:9623/assets/asset_audio_jkl012/status"
```

Expected response:
```json
{
  "asset_id": "asset_audio_jkl012",
  "filename": "recording.mp3",
  "modality": "audio",
  "status": "indexed",
  "processing_steps": {
    "upload": "complete",
    "transcription": "complete",
    "chunking": "complete",
    "embedding": "complete"
  },
  "indexed_at": "2026-04-07T10:45:00Z"
}
```

#### Delete an Asset

```bash
# STUB — Remove an asset from the collection and index
curl -X DELETE "http://localhost:9623/assets/asset_abc123?collection=my-collection"
```

Expected response:
```json
{
  "asset_id": "asset_abc123",
  "deleted": true,
  "collection": "my-collection"
}
```

---

### Status and Health

#### Health Check

```bash
# STUB — Verify the server is running and responsive
curl http://localhost:9623/health
```

Expected response:
```json
{
  "status": "ok",
  "version": "0.x.x",
  "port": 9623,
  "data_dir": "/Users/me/rag-data/rag-anything",
  "collections": ["my-collection"],
  "uptime_seconds": 3600
}
```

#### Supported Modalities and System Dep Status

```bash
# STUB — Check which modalities are active based on installed system deps
curl http://localhost:9623/capabilities
```

Expected response:
```json
{
  "modalities": {
    "text": {"supported": true, "notes": "Always available"},
    "pdf": {"supported": true, "notes": "Text layer extraction"},
    "pdf_ocr": {"supported": true, "notes": "tesseract found at /usr/local/bin/tesseract"},
    "image": {"supported": true, "notes": "tesseract available — OCR enabled"},
    "table": {"supported": true, "notes": "CSV and Excel via pandas"},
    "audio": {"supported": true, "notes": "ffmpeg found at /usr/local/bin/ffmpeg"},
    "video": {"supported": true, "notes": "ffmpeg available — keyframe extraction enabled"}
  },
  "system_deps": {
    "tesseract": {"installed": true, "version": "5.3.0", "path": "/usr/local/bin/tesseract"},
    "ffmpeg": {"installed": true, "version": "6.0", "path": "/usr/local/bin/ffmpeg"}
  }
}
```

If tesseract is missing, `image.supported` will be `false` and `pdf_ocr.supported` will be `false`.
If ffmpeg is missing, `audio.supported` and `video.supported` will be `false`.

---

## When Available — Activation Instructions

Once the package is ready to install, follow these steps:

### 1. Install System Dependencies (Optional but Recommended)

```bash
brew install tesseract ffmpeg
```

### 2. Create the Data Directory

```bash
mkdir -p ~/rag-data/rag-anything
```

### 3. Install the Python Package

```bash
pip install rag-anything
# Or with optional extras if the package supports them:
pip install "rag-anything[ocr,audio]"
```

### 4. Verify Installation

```bash
python -m rag_anything --version
```

### 5. Start the Server

```bash
python -m rag_anything serve --port 9623 --data-dir ~/rag-data/rag-anything
```

### 6. Confirm Health

```bash
curl http://localhost:9623/health
```

### 7. Update This Skill

Change `status` in the YAML front matter from `skeleton` to `production-ready`
and remove the STATUS: NOT INSTALLED banner at the top. Verify all API contract
stubs against the actual installed API and correct any endpoint or payload
differences.

---

## Error Handling Notes

When the server is not running, all curl commands will return a connection refused
error. Before diagnosing query or ingest issues, always verify the server is up
with the health check endpoint.

If a file fails to ingest, check the asset status endpoint for processing step
details. Most failures will be in the transcription or OCR step when system
dependencies are missing or the file is corrupt.

---

## Related Skills

- **LightRAG** — Text-only RAG engine (faster, already installed, use for pure-text corpora)

---

*Skeleton skill authored by Commander Jett Reno. When the package is installed,
verify every API stub against the real server and update accordingly. Don't come
find me because the endpoints changed — that's what the health check is for.*
