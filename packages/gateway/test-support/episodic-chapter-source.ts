import type { EpisodicSessionSource } from "../src/episodic/episodic-contract.js";
import { readCanonicalHomeDeltas, readCanonicalHomeIndex } from "../src/episodic/home-source.js";

/**
 * The production canonical source (`home-source.ts`) over one live session file,
 * as a Home with a single chapter. Episodic memory reads only through a source, so
 * tests of its checkpoint, recovery, scale and end-to-end paths use this exact
 * reader rather than a second, test-only path.
 */
export function singleChapterSource(sessionId: string, sessionFile: string): EpisodicSessionSource {
  const snapshot = { homeId: sessionId, ledgerRevision: 1, chapters: [{ sessionId, path: sessionFile, sealed: false }] };
  return {
    read: (cursor, limits) => readCanonicalHomeDeltas(snapshot, cursor, limits),
    branchAtCursor: (cursor, limits) => readCanonicalHomeIndex(snapshot, cursor, limits),
  };
}
