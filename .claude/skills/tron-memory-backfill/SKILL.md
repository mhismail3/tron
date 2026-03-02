---
name: Tron Memory Backfill
description: Reset database tables, back up the DB, and re-ingest LEDGER.jsonl into semantic memory with vector embeddings
autoInject: false
version: "1.0.0"
tools:
  - Bash
tags:
  - memory
  - tron
  - embeddings
  - maintenance
---

Manage the Tron semantic memory system: back up the database, reset tables, and re-ingest LEDGER.jsonl entries as vector embeddings for recall.

## Database Location

```bash
DB="$HOME/.tron/database/tron.db"
```

## Backfill Binary

The `tron-backfill` crate is NOT in workspace `default-members` — must be built explicitly:

```bash
cd /Users/moose/Workspace/tron/packages/agent
cargo build --release -p tron-backfill
```

Binary: `./target/release/tron-backfill`

## CLI Reference

```bash
# Full help
./target/release/tron-backfill --help

# Import only (parse LEDGER.jsonl → memory.ledger events, idempotent)
./target/release/tron-backfill import --ledger-path ~/.claude/LEDGER.jsonl

# Import with project filter
./target/release/tron-backfill import --ledger-path ~/.claude/LEDGER.jsonl --project-filter /Users/moose/Workspace/tron

# Import dry run (no writes)
./target/release/tron-backfill import --ledger-path ~/.claude/LEDGER.jsonl --dry-run

# Embed only (embed unembedded memory.ledger events)
./target/release/tron-backfill embed

# Force re-embed (drop + recreate memory_vectors table)
./target/release/tron-backfill embed --force

# All-in-one: import then embed
./target/release/tron-backfill all --ledger-path ~/.claude/LEDGER.jsonl

# All-in-one with force re-embed
./target/release/tron-backfill all --ledger-path ~/.claude/LEDGER.jsonl --force

# Custom DB path
./target/release/tron-backfill --db-path /path/to/tron.db all --ledger-path ~/.claude/LEDGER.jsonl
```

## Common Workflows

### 1. Back Up Database

Always back up before destructive operations:

```bash
cp ~/.tron/database/tron.db ~/.tron/database/tron.db.backup-$(date +%Y%m%d-%H%M%S)
```

### 2. Full Reset + Re-Ingest

Clear sessions, events, logs, and memory vectors, then re-ingest from LEDGER.jsonl:

```bash
# Back up first
cp ~/.tron/database/tron.db ~/.tron/database/tron.db.backup-$(date +%Y%m%d-%H%M%S)

# Clear tables (preserves workspaces and tasks)
sqlite3 ~/.tron/database/tron.db <<'SQL'
PRAGMA foreign_keys = OFF;
DELETE FROM events_fts;
DELETE FROM logs_fts;
DELETE FROM branches;
DELETE FROM events;
DELETE FROM logs;
DELETE FROM sessions;
DELETE FROM memory_vectors;
PRAGMA foreign_keys = ON;
VACUUM;
SQL

# Build and run backfill
cd /Users/moose/Workspace/tron/packages/agent
cargo build --release -p tron-backfill
RUST_LOG=info,ort=warn ./target/release/tron-backfill all \
  --ledger-path ~/.claude/LEDGER.jsonl --force
```

### 3. Incremental Ingest (Append New Entries Only)

Safe to run repeatedly — import is idempotent (skips entries already in DB):

```bash
cd /Users/moose/Workspace/tron/packages/agent
RUST_LOG=info,ort=warn ./target/release/tron-backfill all \
  --ledger-path ~/.claude/LEDGER.jsonl
```

### 4. Re-Embed Only (No New Imports)

Re-generate vectors for existing memory.ledger events:

```bash
cd /Users/moose/Workspace/tron/packages/agent
RUST_LOG=info,ort=warn ./target/release/tron-backfill embed --force
```

### 5. Reset Sessions/Events/Logs Only (Keep Memory)

```bash
cp ~/.tron/database/tron.db ~/.tron/database/tron.db.backup-$(date +%Y%m%d-%H%M%S)

sqlite3 ~/.tron/database/tron.db <<'SQL'
PRAGMA foreign_keys = OFF;
DELETE FROM events_fts;
DELETE FROM logs_fts;
DELETE FROM branches;
DELETE FROM events;
DELETE FROM logs;
DELETE FROM sessions;
PRAGMA foreign_keys = ON;
VACUUM;
SQL
```

Note: this orphans memory_vectors (their event_ids no longer exist). Run a full re-ingest afterward if recall is needed.

### 6. Reset Memory Only

```bash
sqlite3 ~/.tron/database/tron.db "DELETE FROM memory_vectors; VACUUM;"

# Then re-embed from existing events
RUST_LOG=info,ort=warn ./target/release/tron-backfill embed --force
```

## Verification Queries

```bash
# Table counts
sqlite3 ~/.tron/database/tron.db -header -column \
  "SELECT 'sessions' as tbl, COUNT(*) as cnt FROM sessions
   UNION ALL SELECT 'events', COUNT(*) FROM events
   UNION ALL SELECT 'logs', COUNT(*) FROM logs
   UNION ALL SELECT 'memory_vectors', COUNT(*) FROM memory_vectors
   UNION ALL SELECT 'workspaces', COUNT(*) FROM workspaces;"

# Memory vector breakdown
sqlite3 ~/.tron/database/tron.db -header -column \
  "SELECT chunk_type, COUNT(*) as cnt FROM memory_vectors GROUP BY chunk_type;"

# Database file size
ls -lh ~/.tron/database/tron.db

# List backups
ls -lh ~/.tron/database/tron.db.backup-*
```

## Schema: memory_vectors

| Column | Type | Purpose |
|--------|------|---------|
| `id` | TEXT PK | `{event_id}-summary` or `{event_id}-lesson-{N}` |
| `event_id` | TEXT | Links to events.id of the memory.ledger event |
| `workspace_id` | TEXT | Workspace scope for recall queries |
| `chunk_type` | TEXT | `summary` (full payload) or `lesson` (per-lesson) |
| `chunk_index` | INTEGER | 0 for summary, 1..N for lessons |
| `entry_type` | TEXT | From ledger `front.type` (feature, bugfix, etc.) |
| `created_at` | TEXT | ISO8601 timestamp for temporal decay |
| `embedding` | BLOB | L2-normalized 512-dim f32 vector (2048 bytes) |

## Embedding Model

- **Model**: EmbeddingGemma-300M-ONNX (q4 quantization)
- **Dimensions**: 768 → Matryoshka truncated to 512
- **Cache**: `~/.tron/mods/models/`
- **Multi-vector**: 1 summary + N lesson vectors per event (lessons only if 2+)
- **Text prefixes**: `"title: none | text: {content}"` for documents

## LEDGER.jsonl Format

Each line is a JSON object:

```json
{
  "_meta": { "id": "uuid", "ts": "ISO8601", "v": 1 },
  "front": {
    "project": "name", "path": "/absolute/path",
    "title": "one-line", "type": "feature|bugfix|refactor|docs|config|research",
    "status": "completed|partial|failed", "tags": []
  },
  "body": {
    "input": "user request", "actions": ["what was done"],
    "files": [{"path": "file", "op": "C|M|D", "why": "purpose"}],
    "decisions": [{"choice": "what", "reason": "why"}],
    "lessons": ["patterns for future"]
  }
}
```

## Key Behaviors

- **Idempotent import**: Entries matched by `_meta.id` — safe to re-run on the same LEDGER.jsonl
- **Backfill sessions are ended**: They don't appear in the session list, but events retain workspace_id
- **Temporal decay**: Recall scores decay with `0.5^(age_days / 30)` half-life
- **Hybrid search**: Vector cosine + FTS5 BM25 fused via Reciprocal Rank Fusion (RRF, k=60)
- **Empty text skipped**: Entries with no content produce no vectors

## Table Deletion Order (FK Safety)

When clearing tables manually, delete in this order to respect foreign keys:

1. `events_fts`, `logs_fts` (FTS indexes)
2. `branches` (references sessions + events)
3. `events` (references sessions)
4. `logs` (references sessions)
5. `sessions` (references workspaces)
6. `memory_vectors` (references events by convention, no FK constraint)

Always wrap with `PRAGMA foreign_keys = OFF` / `ON` or follow the order above.
