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

## CLI Reference

Backfill is a subcommand of the main `tron` binary:

```bash
# Full help
tron backfill-ledger --help

# Import only (parse LEDGER.jsonl → memory.ledger events, idempotent)
tron backfill-ledger import --ledger-path ~/.claude/LEDGER.jsonl

# Import with project filter
tron backfill-ledger import --ledger-path ~/.claude/LEDGER.jsonl --project-filter /Users/moose/Workspace/tron

# Import dry run (no writes)
tron backfill-ledger import --ledger-path ~/.claude/LEDGER.jsonl --dry-run

# Embed only (embed unembedded memory.ledger events)
tron backfill-ledger embed

# Force re-embed (drop + recreate memory_vectors table)
tron backfill-ledger embed --force

# All-in-one: import then embed
tron backfill-ledger all --ledger-path ~/.claude/LEDGER.jsonl

# All-in-one with force re-embed
tron backfill-ledger all --ledger-path ~/.claude/LEDGER.jsonl --force

# Custom DB path
tron --db-path /path/to/tron.db backfill-ledger all --ledger-path ~/.claude/LEDGER.jsonl
```

When running from the workspace (not installed):

```bash
cd /Users/moose/Workspace/tron/packages/agent
cargo build --release
./target/release/tron backfill-ledger all --ledger-path ~/.claude/LEDGER.jsonl
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
cargo build --release
RUST_LOG=info,ort=warn ./target/release/tron backfill-ledger all \
  --ledger-path ~/.claude/LEDGER.jsonl --force
```

### 3. Incremental Ingest (Append New Entries Only)

Safe to run repeatedly — import is idempotent (skips entries already in DB):

```bash
RUST_LOG=info,ort=warn tron backfill-ledger all --ledger-path ~/.claude/LEDGER.jsonl
```

### 4. Re-Embed Only (No New Imports)

Re-generate vectors for existing memory.ledger events:

```bash
RUST_LOG=info,ort=warn tron backfill-ledger embed --force
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
```

## Key Behaviors

- **Idempotent import**: Entries matched by `_meta.id` — safe to re-run on the same LEDGER.jsonl
- **Auto-embed on server startup**: The server automatically embeds unembedded events on boot
- **Temporal decay**: Recall scores decay with `0.5^(age_days / 30)` half-life
- **Hybrid search**: Vector cosine + FTS5 BM25 fused via Reciprocal Rank Fusion (RRF, k=60)
