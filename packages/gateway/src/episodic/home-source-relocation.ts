import { createHash } from "node:crypto";
import { constants } from "node:fs";
import { open } from "node:fs/promises";
import { COMPLETE_PREFIX_SEED, extendPrefixDigest, sameSnapshot } from "../kernel/session/canonical-reader.js";
import { EPISODIC_DEFAULTS, type EpisodicChapterSourceCursor, type EpisodicSourceCursor } from "./episodic-contract.js";
import { homeSourceLines } from "./home-source.js";

const digest = (bytes: Buffer | string) => createHash("sha256").update(bytes).digest("hex");

export async function relocateHomeSourceCursor(path: string, originalHeader: Buffer, cursor: EpisodicChapterSourceCursor): Promise<EpisodicChapterSourceCursor> {
  const handle = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const start = await handle.stat();
    if (!start.isFile() || start.uid !== process.getuid?.()) throw new Error("Home source is not an owned regular file");
    const headerBuffer = Buffer.alloc(65_537);
    const { bytesRead } = await handle.read(headerBuffer, 0, headerBuffer.length, 0);
    const newline = headerBuffer.subarray(0, bytesRead).indexOf(10);
    if (newline < 0 || originalHeader.length > 65_536 || !originalHeader.length || originalHeader.at(-1) !== 10) throw new Error("Invalid relocation header");
    const currentHeader = headerBuffer.subarray(0, newline + 1);
    const before = JSON.parse(originalHeader.toString("utf8"));
    const after = JSON.parse(currentHeader.toString("utf8"));
    if (before.type !== "session" || before.version !== 3 || before.id !== cursor.sessionId || typeof before.cwd !== "string" || typeof after.cwd !== "string"
      || JSON.stringify({ ...before, cwd: null }) !== JSON.stringify({ ...after, cwd: null })) throw new Error("Relocation changed more than the session cwd");
    const delta = currentHeader.length - originalHeader.length;
    const completeBytes = cursor.completeBytes + delta;
    if (cursor.completeBytes < originalHeader.length || completeBytes > start.size || (cursor.sealed && start.size !== cursor.size + delta)) throw new Error("Relocation source size does not match its cursor");
    let previousPrefix = extendPrefixDigest(COMPLETE_PREFIX_SEED, originalHeader.subarray(0, -1));
    let nextPrefix = extendPrefixDigest(COMPLETE_PREFIX_SEED, currentHeader.subarray(0, -1));
    let leafDigest: string | null = null;
    let leafId: string | null = null;
    let provenBytes = currentHeader.length;
    for await (const line of homeSourceLines(handle, currentHeader.length, completeBytes, EPISODIC_DEFAULTS.maxSourceLineBytes)) {
      provenBytes += line.length + 1;
      previousPrefix = extendPrefixDigest(previousPrefix, line);
      nextPrefix = extendPrefixDigest(nextPrefix, line);
      if (line.toString("utf8").trim()) {
        const entry = JSON.parse(line.toString("utf8"));
        leafDigest = digest(line);
        leafId = entry.id;
      }
    }
    if (provenBytes !== completeBytes || previousPrefix !== cursor.completePrefixDigest || leafDigest !== cursor.leafLineDigest || leafId !== cursor.leafEntryId) throw new Error("Relocation did not preserve the exact ingested session body");
    const end = await handle.stat();
    if (!sameSnapshot(start, end)) throw new Error("Relocation source changed during proof");
    return { ...cursor, dev: end.dev, ino: end.ino, size: cursor.size + delta, completeBytes, completePrefixDigest: nextPrefix, mtimeMs: end.mtimeMs, ctimeMs: end.ctimeMs };
  } finally { await handle.close(); }
}

export function relocatedHomeCursor(cursor: EpisodicSourceCursor, chapters: EpisodicChapterSourceCursor[]): EpisodicSourceCursor {
  return { ...cursor, completeBytes: chapters.reduce((sum, chapter) => sum + chapter.completeBytes, 0),
    completePrefixDigest: digest(JSON.stringify(chapters)), home: { ...cursor.home, chapters } };
}
