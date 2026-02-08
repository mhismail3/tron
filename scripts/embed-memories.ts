#!/usr/bin/env bun
/**
 * @fileoverview Embed memory.ledger events into memory_vectors
 *
 * Standalone script that loads the embedding model and sqlite-vec,
 * finds all memory.ledger events without vectors, and embeds them.
 *
 * Usage:
 *   bun scripts/embed-memories.ts [--db beta|prod] [--dry-run]
 */

import { existsSync } from 'fs';
import { join } from 'path';
import { homedir } from 'os';
import { Database } from 'bun:sqlite';
import { createRequire } from 'module';

// =============================================================================
// Config
// =============================================================================

const args = process.argv.slice(2);
const dryRun = args.includes('--dry-run');
const dbTarget = args.includes('--db') ? args[args.indexOf('--db') + 1] : 'beta';
const dbPath = join(homedir(), '.tron', 'database', `${dbTarget}.db`);
const modelCacheDir = join(homedir(), '.tron', 'mods', 'models');
const DIMENSIONS = 512;

// =============================================================================
// Main
// =============================================================================

async function main() {
  if (!existsSync(dbPath)) {
    console.error(`Database not found: ${dbPath}`);
    process.exit(1);
  }

  console.log(`Database:   ${dbPath}`);
  console.log(`Model cache: ${modelCacheDir}`);
  console.log(`Mode:        ${dryRun ? 'DRY RUN' : 'LIVE'}`);
  console.log();

  // --- Open DB + load sqlite-vec ---
  // Use Homebrew SQLite on macOS (Apple's disables extensions)
  const brewSqlite = '/opt/homebrew/opt/sqlite3/lib/libsqlite3.dylib';
  if (existsSync(brewSqlite)) {
    Database.setCustomSQLite(brewSqlite);
    console.log(`Using Homebrew SQLite: ${brewSqlite}`);
  }

  const db = new Database(dbPath);
  db.exec('PRAGMA journal_mode = WAL');

  // Load sqlite-vec (resolve from agent package where it's installed)
  const agentPkgPath = join(import.meta.dir, '..', 'packages', 'agent', 'package.json');
  const require = createRequire(agentPkgPath);
  const { getLoadablePath } = require('sqlite-vec');
  const vecPath = getLoadablePath();
  db.loadExtension(vecPath);
  console.log(`Loaded sqlite-vec: ${vecPath}`);

  // Ensure memory_vectors table exists
  db.exec(`
    CREATE VIRTUAL TABLE IF NOT EXISTS memory_vectors USING vec0(
      event_id TEXT PRIMARY KEY,
      workspace_id TEXT NOT NULL,
      embedding float[${DIMENSIONS}]
    )
  `);

  // Find unembedded memory.ledger events
  const unembedded = db.prepare(`
    SELECT e.id, e.workspace_id, e.payload
    FROM events e
    LEFT JOIN memory_vectors v ON e.id = v.event_id
    WHERE e.type = 'memory.ledger' AND v.event_id IS NULL
  `).all() as Array<{ id: string; workspace_id: string; payload: string }>;

  const totalVectors = (db.prepare('SELECT COUNT(*) as c FROM memory_vectors').get() as { c: number }).c;
  const totalEvents = (db.prepare("SELECT COUNT(*) as c FROM events WHERE type = 'memory.ledger'").get() as { c: number }).c;

  console.log(`\nTotal memory.ledger events: ${totalEvents}`);
  console.log(`Existing vectors:          ${totalVectors}`);
  console.log(`Unembedded events:         ${unembedded.length}`);

  if (unembedded.length === 0) {
    console.log('\nAll events already have vectors. Nothing to do.');
    db.close();
    return;
  }

  if (dryRun) {
    console.log('\nDry run — showing first 3 texts that would be embedded:');
    for (const event of unembedded.slice(0, 3)) {
      const text = buildEmbeddingText(JSON.parse(event.payload));
      console.log(`\n--- ${event.id} (${text.length} chars) ---`);
      console.log(text.slice(0, 200) + (text.length > 200 ? '...' : ''));
    }
    db.close();
    return;
  }

  // --- Load embedding model ---
  console.log('\nLoading embedding model...');
  // Resolve ESM entry from agent package where @huggingface/transformers is installed
  const transformersPkgDir = join(
    require.resolve('@huggingface/transformers').replace(/\/dist\/.*$/, ''),
  );
  const { pipeline, env } = await import(join(transformersPkgDir, 'dist', 'transformers.node.mjs'));
  env.cacheDir = modelCacheDir;
  env.allowLocalModels = true;

  const extractor = await pipeline('feature-extraction', 'onnx-community/Qwen3-Embedding-0.6B-ONNX', {
    dtype: 'q4' as any,
  });
  console.log('Model loaded.\n');

  // --- Embed and store ---
  const insertStmt = db.prepare(
    'INSERT INTO memory_vectors (event_id, workspace_id, embedding) VALUES (?, ?, ?)'
  );
  const deleteStmt = db.prepare('DELETE FROM memory_vectors WHERE event_id = ?');

  let embedded = 0;
  let failed = 0;
  const startTime = Date.now();

  for (let i = 0; i < unembedded.length; i++) {
    const event = unembedded[i]!;
    try {
      const payload = JSON.parse(event.payload);
      const text = buildEmbeddingText(payload);

      if (!text.trim()) {
        console.log(`  [${i + 1}/${unembedded.length}] SKIP (empty text) ${event.id}`);
        failed++;
        continue;
      }

      // Embed
      const output = await extractor([text], { pooling: 'last_token', normalize: true });
      const tensor = output as { data: Float32Array; dims: number[] };
      const fullDim = tensor.dims[tensor.dims.length - 1] ?? DIMENSIONS;

      // Truncate to 512d + re-normalize (Matryoshka)
      const truncated = new Float32Array(DIMENSIONS);
      for (let d = 0; d < DIMENSIONS; d++) {
        truncated[d] = tensor.data[d] ?? 0;
      }
      let norm = 0;
      for (let d = 0; d < DIMENSIONS; d++) {
        norm += truncated[d]! * truncated[d]!;
      }
      norm = Math.sqrt(norm);
      if (norm > 0) {
        for (let d = 0; d < DIMENSIONS; d++) {
          truncated[d] = truncated[d]! / norm;
        }
      }

      // Store
      const buffer = Buffer.from(truncated.buffer, truncated.byteOffset, truncated.byteLength);
      deleteStmt.run(event.id);
      insertStmt.run(event.id, event.workspace_id, buffer);

      embedded++;
      const elapsed = ((Date.now() - startTime) / 1000).toFixed(1);
      const rate = (embedded / parseFloat(elapsed)).toFixed(1);
      process.stdout.write(`\r  [${i + 1}/${unembedded.length}] ${embedded} embedded (${rate}/s, ${elapsed}s)`);
    } catch (err) {
      failed++;
      console.log(`\n  FAILED ${event.id}: ${(err as Error).message}`);
    }
  }

  const totalTime = ((Date.now() - startTime) / 1000).toFixed(1);
  const finalCount = (db.prepare('SELECT COUNT(*) as c FROM memory_vectors').get() as { c: number }).c;

  console.log(`\n\nDone in ${totalTime}s`);
  console.log(`  Embedded: ${embedded}`);
  console.log(`  Failed:   ${failed}`);
  console.log(`  Total vectors now: ${finalCount}`);

  // Quick sanity check — search for a query
  if (finalCount > 0) {
    console.log('\nSanity check — searching for "OAuth authentication"...');
    const queryOutput = await extractor(['OAuth authentication'], { pooling: 'last_token', normalize: true });
    const qTensor = queryOutput as { data: Float32Array; dims: number[] };
    const queryVec = new Float32Array(DIMENSIONS);
    for (let d = 0; d < DIMENSIONS; d++) queryVec[d] = qTensor.data[d] ?? 0;
    let qNorm = 0;
    for (let d = 0; d < DIMENSIONS; d++) qNorm += queryVec[d]! * queryVec[d]!;
    qNorm = Math.sqrt(qNorm);
    if (qNorm > 0) for (let d = 0; d < DIMENSIONS; d++) queryVec[d] = queryVec[d]! / qNorm;

    const queryBuf = Buffer.from(queryVec.buffer, queryVec.byteOffset, queryVec.byteLength);
    const results = db.prepare(`
      SELECT v.event_id, v.distance, json_extract(e.payload, '$.title') as title
      FROM memory_vectors v
      JOIN events e ON v.event_id = e.id
      WHERE v.embedding MATCH ? AND k = 5
      ORDER BY v.distance
    `).all(queryBuf) as Array<{ event_id: string; distance: number; title: string }>;

    for (const r of results) {
      const relevance = Math.round((1 - r.distance) * 100);
      console.log(`  ${relevance}% — ${r.title}`);
    }
  }

  db.close();
}

// =============================================================================
// Helpers
// =============================================================================

function buildEmbeddingText(payload: Record<string, unknown>): string {
  const parts: string[] = [];
  if (payload.title) parts.push(payload.title as string);
  if (payload.input) parts.push(payload.input as string);
  if (Array.isArray(payload.actions) && payload.actions.length) {
    parts.push(payload.actions.join('. '));
  }
  if (Array.isArray(payload.lessons) && payload.lessons.length) {
    parts.push(payload.lessons.join('. '));
  }
  if (Array.isArray(payload.decisions) && payload.decisions.length) {
    parts.push(
      payload.decisions
        .map((d: any) => `${d.choice}: ${d.reason}`)
        .join('. ')
    );
  }
  if (Array.isArray(payload.tags) && payload.tags.length) {
    parts.push(payload.tags.join(' '));
  }
  return parts.join('\n');
}

// =============================================================================
// Run
// =============================================================================

main().catch(err => {
  console.error('Fatal:', err);
  process.exit(1);
});
