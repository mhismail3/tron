import type { EpisodicSessionSource } from "../src/episodic/episodic-contract.js";
import { episodicDigest } from "../src/kernel/session/canonical-reader.js";
import { readCanonicalHomeDeltas, readCanonicalHomeIndex } from "../src/episodic/home-source.js";

export function singleChapterSource(sessionId: string, sessionFile: string): EpisodicSessionSource {
  const snapshot = { homeId: sessionId, ledgerRevision: 1, chapters: [{ sessionId, path: sessionFile, sealed: false }] };
  return {
    read: (cursor, limits) => readCanonicalHomeDeltas(snapshot, cursor, limits),
    branchAtCursor: (cursor, limits) => readCanonicalHomeIndex(snapshot, cursor, limits),
  };
}

export function episodicHostAssigned(path: string, text: string): string {
  if (!path.endsWith("/state.json")) return text;
  const state = JSON.parse(text) as { cursor?: { completePrefixDigest: string; home: { chapters: Array<Record<string, unknown>> } } };
  const cursor = state.cursor;
  if (!cursor) return text;
  if (cursor.completePrefixDigest === episodicDigest(JSON.stringify(cursor.home.chapters))) cursor.completePrefixDigest = "<digest of the chapter cursors>";
  for (const chapter of cursor.home.chapters) for (const key of ["dev", "ino", "mtimeMs", "ctimeMs"]) {
    const value = chapter[key];
    if (typeof value === "number" && Number.isFinite(value) && value >= 0) chapter[key] = `<host ${key}>`;
  }
  return `${JSON.stringify(state, null, 2)}\n`;
}
