#!/usr/bin/env bun
/**
 * @fileoverview Backfill LEDGER.jsonl into Tron's memory system
 *
 * Reads ~/.claude/LEDGER.jsonl entries and inserts them as synthetic
 * memory.ledger events in the Tron database. The server's backfill
 * process will embed them into memory_vectors on next start.
 *
 * Usage:
 *   bun scripts/backfill-ledger.ts [--db beta|prod] [--dry-run]
 */

import { readFileSync, existsSync } from 'fs';
import { join } from 'path';
import { homedir } from 'os';
import { Database } from 'bun:sqlite';
import { randomUUID } from 'crypto';

// =============================================================================
// Config
// =============================================================================

const args = process.argv.slice(2);
const dryRun = args.includes('--dry-run');
const dbTarget = args.includes('--db') ? args[args.indexOf('--db') + 1] : 'beta';
const ledgerPath = join(homedir(), '.claude', 'LEDGER.jsonl');
const dbPath = join(homedir(), '.tron', 'database', `${dbTarget}.db`);

// =============================================================================
// Types
// =============================================================================

interface LedgerEntry {
  _meta: { id: string; ts: string; v: number };
  front: {
    project: string;
    path: string;
    title: string;
    type: string;
    status: string;
    tags: string[];
  };
  body: {
    input: string;
    actions: string[];
    files: Array<{ path: string; op: string; why: string }>;
    decisions: Array<{ choice: string; reason: string }>;
    lessons: string[];
  };
  history: { embedded: boolean };
}

// =============================================================================
// Main
// =============================================================================

function main() {
  // Validate paths
  if (!existsSync(ledgerPath)) {
    console.error(`LEDGER.jsonl not found at ${ledgerPath}`);
    process.exit(1);
  }
  if (!existsSync(dbPath)) {
    console.error(`Database not found at ${dbPath}`);
    process.exit(1);
  }

  console.log(`Source:  ${ledgerPath}`);
  console.log(`Target:  ${dbPath}`);
  console.log(`Mode:    ${dryRun ? 'DRY RUN' : 'LIVE'}`);
  console.log();

  // Parse LEDGER entries
  const raw = readFileSync(ledgerPath, 'utf-8');
  const entries: LedgerEntry[] = raw
    .split('\n')
    .filter(line => line.trim())
    .map(line => JSON.parse(line));

  console.log(`Parsed ${entries.length} ledger entries`);

  // Group by workspace path
  const byWorkspace = new Map<string, LedgerEntry[]>();
  for (const entry of entries) {
    const path = entry.front.path;
    if (!byWorkspace.has(path)) byWorkspace.set(path, []);
    byWorkspace.get(path)!.push(entry);
  }

  console.log(`Across ${byWorkspace.size} workspaces:`);
  for (const [path, group] of byWorkspace) {
    console.log(`  ${group.length.toString().padStart(3)}  ${path}`);
  }
  console.log();

  if (dryRun) {
    console.log('Dry run — not modifying database.');
    showSamplePayload(entries[0]!);
    return;
  }

  // Open database
  const db = new Database(dbPath);
  db.exec('PRAGMA journal_mode = WAL');
  db.exec('PRAGMA foreign_keys = ON');

  // Check for existing backfill (idempotent)
  const existingCount = (db.prepare(
    "SELECT COUNT(*) as count FROM sessions WHERE title = 'LEDGER.jsonl backfill'"
  ).get() as { count: number }).count;

  if (existingCount > 0) {
    console.log(`Found ${existingCount} existing backfill session(s). Checking for new entries...`);
  }

  // Get existing backfill event meta IDs to avoid duplicates
  const existingMetas = new Set<string>();
  const existingRows = db.prepare(`
    SELECT json_extract(payload, '$._meta.id') as meta_id
    FROM events
    WHERE type = 'memory.ledger'
      AND json_extract(payload, '$._meta.source') = 'ledger.jsonl'
  `).all() as Array<{ meta_id: string }>;
  for (const row of existingRows) {
    if (row.meta_id) existingMetas.add(row.meta_id);
  }

  // Prepare statements
  const insertWorkspace = db.prepare(`
    INSERT OR IGNORE INTO workspaces (id, path, name, created_at, last_activity_at)
    VALUES (?, ?, ?, ?, ?)
  `);
  const getWorkspace = db.prepare('SELECT id FROM workspaces WHERE path = ?');
  const insertSession = db.prepare(`
    INSERT OR IGNORE INTO sessions (
      id, workspace_id, title, latest_model, working_directory,
      created_at, last_activity_at, ended_at, event_count, turn_count
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `);
  const getSession = db.prepare(
    "SELECT id FROM sessions WHERE workspace_id = ? AND title = 'LEDGER.jsonl backfill'"
  );
  const insertEvent = db.prepare(`
    INSERT INTO events (
      id, session_id, parent_id, sequence, depth, type,
      timestamp, payload, workspace_id, turn
    ) VALUES (?, ?, NULL, ?, 0, ?, ?, ?, ?, 0)
  `);
  const updateSessionCount = db.prepare(`
    UPDATE sessions SET event_count = (
      SELECT COUNT(*) FROM events WHERE session_id = ?
    ) WHERE id = ?
  `);

  // Process each workspace
  let totalInserted = 0;
  let totalSkipped = 0;

  const transaction = db.transaction(() => {
    for (const [wsPath, group] of byWorkspace) {
      // Sort by timestamp
      group.sort((a, b) => a._meta.ts.localeCompare(b._meta.ts));

      const firstTs = group[0]!._meta.ts;
      const lastTs = group[group.length - 1]!._meta.ts;
      const wsName = wsPath.split('/').pop() ?? wsPath;

      // Create or get workspace
      let wsRow = getWorkspace.get(wsPath) as { id: string } | null;
      if (!wsRow) {
        const wsId = `ws_backfill_${randomUUID().slice(0, 8)}`;
        insertWorkspace.run(wsId, wsPath, wsName, firstTs, lastTs);
        wsRow = { id: wsId };
        console.log(`  Created workspace: ${wsId} → ${wsPath}`);
      } else {
        console.log(`  Existing workspace: ${wsRow.id} → ${wsPath}`);
      }

      // Create or get backfill session
      let sessRow = getSession.get(wsRow.id) as { id: string } | null;
      if (!sessRow) {
        const sessId = `sess_backfill_${randomUUID().slice(0, 8)}`;
        insertSession.run(
          sessId, wsRow.id, 'LEDGER.jsonl backfill', 'claude-code',
          wsPath, firstTs, lastTs, lastTs, 0, 0
        );
        sessRow = { id: sessId };
        console.log(`  Created session: ${sessId}`);
      } else {
        console.log(`  Existing session: ${sessRow.id}`);
      }

      // Insert events
      let seq = (db.prepare(
        'SELECT COALESCE(MAX(sequence), -1) + 1 as next_seq FROM events WHERE session_id = ?'
      ).get(sessRow.id) as { next_seq: number }).next_seq;

      let inserted = 0;
      let skipped = 0;

      for (const entry of group) {
        // Skip if already backfilled
        if (existingMetas.has(entry._meta.id)) {
          skipped++;
          continue;
        }

        const eventId = `evt_backfill_${randomUUID().slice(0, 8)}`;
        const payload = ledgerToPayload(entry);

        insertEvent.run(
          eventId,
          sessRow.id,
          seq++,
          'memory.ledger',
          entry._meta.ts,
          JSON.stringify(payload),
          wsRow.id,
        );

        inserted++;
      }

      // Update session event count
      updateSessionCount.run(sessRow.id, sessRow.id);

      totalInserted += inserted;
      totalSkipped += skipped;
      console.log(`  Events: ${inserted} inserted, ${skipped} skipped (already exist)`);
    }
  });

  transaction();
  db.close();

  console.log();
  console.log(`Done. ${totalInserted} events inserted, ${totalSkipped} skipped.`);
  if (totalInserted > 0) {
    console.log(`Restart the ${dbTarget} server — backfillMemoryVectors() will embed them automatically.`);
  }
}

// =============================================================================
// Helpers
// =============================================================================

/**
 * Convert a LEDGER.jsonl entry to a memory.ledger payload.
 * Preserves the original _meta.id for dedup, adds _meta.source marker.
 */
function ledgerToPayload(entry: LedgerEntry): Record<string, unknown> {
  return {
    // Standard memory.ledger fields
    title: entry.front.title,
    entryType: entry.front.type,
    status: entry.front.status,
    tags: entry.front.tags ?? [],
    input: entry.body.input,
    actions: entry.body.actions ?? [],
    files: entry.body.files ?? [],
    decisions: entry.body.decisions ?? [],
    lessons: entry.body.lessons ?? [],
    thinkingInsights: [],
    // Ranges don't apply — use placeholders
    eventRange: { firstEventId: 'backfill', lastEventId: 'backfill' },
    turnRange: { firstTurn: 0, lastTurn: 0 },
    tokenCost: { input: 0, output: 0 },
    model: 'claude-code',
    workingDirectory: entry.front.path,
    // Provenance — marks this as backfilled, enables dedup
    _meta: {
      id: entry._meta.id,
      ts: entry._meta.ts,
      source: 'ledger.jsonl',
    },
  };
}

function showSamplePayload(entry: LedgerEntry) {
  console.log('Sample payload that would be inserted:');
  console.log(JSON.stringify(ledgerToPayload(entry), null, 2));
}

// =============================================================================
// Run
// =============================================================================

main();
