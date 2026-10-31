#!/usr/bin/env node
/** Offline admission using only the candidate's shipped read owners. No Gateway,
 * registry initialization, locks, timers, model calls, or persistence is started. */
import { createReadStream } from 'node:fs';
import { readFile, readdir } from 'node:fs/promises';
import { createInterface } from 'node:readline';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const [payload, home, exports, expectedText] = process.argv.slice(2);
const expected = JSON.parse(expectedText);
const shipped = path => import(pathToFileURL(join(payload, 'app/dist', path)).href);
const { TronWorkspace } = await shipped('workspace/tron-workspace.js');
const { ProfileStore } = await shipped('modules/home/profile-store.js');
const { admitHomeRecord } = await shipped('modules/home/home-owner.js');
const { HomeChapterContentsReader } = await shipped('modules/home/home-chapter-contents.js');
const { EpisodicStore } = await shipped('episodic/episodic-store.js');
const { readCanonicalSession } = await shipped('kernel/session/canonical-reader.js');
const { CANONICAL_SOURCE_MAX_LINE_BYTES } = await shipped('kernel/resources/prompt-bounds.js');
const { readSecureJson } = await shipped('foundation/secure-json.js');
const workspace = {
  describe: () => TronWorkspace.describeExisting(home),
  featureInitialized: feature => TronWorkspace.featureInitializedExisting(home, feature),
  markFeatureInitialized: () => { throw new Error('Offline verification attempted a write'); },
};
const profile = new ProfileStore(workspace);
let cursor, notes = 0;
do {
  const page = await profile.list({ includeSuppressed: true, limit: 50, ...(cursor ? { cursor } : {}) });
  for (const record of page.records) {
    if (record.kind !== 'note') throw new Error('Non-note in Profile');
    if (!await profile.read(record.id, record.revisionId, true)) throw new Error('Profile note is unreadable');
    notes++;
  }
  cursor = page.nextCursor;
} while (cursor);
if (notes !== expected.notes) throw new Error(`Profile note count ${notes} differs from ${expected.notes}`);
const read = await readSecureJson(join(home, 'gateway/home/home.json'), 16 * 1024 * 1024);
const ledger = read.present ? admitHomeRecord(read.value) : undefined;
if (read.present && !ledger) throw new Error('Home chapter ledger is invalid');
const sessions = new Map();
const sessionRoot = join(home, 'agent/sessions');
let chats = 0, entries = 0;
for (const directory of await readdir(sessionRoot, { withFileTypes: true }).catch(error => {
  if (error.code === 'ENOENT' && !ledger) return [];
  throw error;
})) {
  if (!directory.isDirectory()) continue;
  for (const file of await readdir(join(sessionRoot, directory.name), { withFileTypes: true })) {
    if (!file.isFile() || !file.name.endsWith('.jsonl')) continue;
    const path = join(sessionRoot, directory.name, file.name);
    const stream = createReadStream(path);
    const lines = createInterface({ input: stream, crlfDelay: Infinity });
    let header;
    try { for await (const line of lines) { header = JSON.parse(line); break; } }
    finally { lines.close(); stream.destroy(); }
    if (!header || header.type !== 'session' || typeof header.id !== 'string') throw new Error('Invalid canonical chat header');
    const history = await readCanonicalSession({ path, sessionId: header.id, maxLineBytes: CANONICAL_SOURCE_MAX_LINE_BYTES });
    entries += history.branch.length;
    if (sessions.has(header.id)) throw new Error('Duplicate canonical chat identity');
    sessions.set(header.id, path);
    chats++;
  }
}
const chapters = new HomeChapterContentsReader();
for (const chapter of ledger?.chapters ?? []) {
  if (!await chapters.counts(chapter.sessionId, sessions.get(chapter.sessionId), chapter.state === 'reserved')) {
    throw new Error(`Home chapter ${chapter.ordinal} cannot open`);
  }
}
let memories = 0, summaries = 0;
const memoryIds = new Set();
const memoryRoot = join(home, 'workspace/state/episodic');
for (const entry of await readdir(memoryRoot, { withFileTypes: true }).catch(async error => {
  if (error.code === 'ENOENT' && !await workspace.featureInitialized('episodic')) return [];
  throw error;
})) {
  if (!entry.isDirectory() || entry.name.startsWith('.')) throw new Error('Unexpected Home memory namespace');
  const memory = await new EpisodicStore(workspace, entry.name, CANONICAL_SOURCE_MAX_LINE_BYTES).read();
  if (!memory.present || memory.recoveredTornBytes) throw new Error('Home memory is missing or torn');
  memories++;
  memoryIds.add(entry.name);
  summaries += memory.nodes.size;
}
if (ledger?.memory && !memoryIds.has(ledger.homeId)) throw new Error('Configured Home memory cannot open');
// Knowledge has no runtime loader after retirement: sources are ordinary files.
// Exercise the candidate's actual pinned read tool, not a replacement algorithm.
const { createReadTool } = await import(import.meta.resolve('@earendil-works/pi-coding-agent', pathToFileURL(join(payload, 'app/package.json')).href));
const manifest = JSON.parse(await readFile(join(exports, 'MANIFEST.json'), 'utf8'));
if (manifest.counts.sources !== expected.sources) throw new Error('Source export count mismatch');
if (manifest.sources.length) {
  const result = await createReadTool(exports).execute('offline-cutover', { path: join(exports, manifest.sources[0].markdown), limit: 10 });
  if (!result.content.some(block => block.type === 'text' && block.text.length)) throw new Error('Ordinary source reader failed');
}
process.stdout.write(JSON.stringify({ verified: true, notes, chats, chatEntries: entries, chapters: ledger?.chapters.length ?? 0, memories, summaries,
  sourceRevisions: manifest.sources.length, serverStarted: false, writesStarted: false }) + '\n');
