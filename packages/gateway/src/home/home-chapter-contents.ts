import { createHash } from "node:crypto";
import { open, stat } from "node:fs/promises";
import type { HomeChapterContents } from "../protocol/types.js";

/** Bounds of a chapter's topics (`home.chapterList`). */
export const HOME_CHAPTER_TOPIC_COUNT = 5;
export const HOME_CHAPTER_TOPIC_CHARACTERS = 120;

/** Bytes read per chunk while a chapter's canonical file is scanned. */
const CHUNK_BYTES = 1024 * 1024;
/** The bytes before a scan's end that identify the file's prefix on the next read. */
const PREFIX_WINDOW_BYTES = 4096;
const NEWLINE = 0x0a;

/** One memory summary as a topic: a single line, cut to the topic bound in code points. */
export function homeChapterTopic(summary: string): string {
  return [...summary.replace(/\s+/gu, " ").trim()].slice(0, HOME_CHAPTER_TOPIC_CHARACTERS).join("");
}

/** The counts one canonical chapter file holds, before topics are attached. */
export type HomeChapterCounts = Omit<HomeChapterContents, "topics">;

interface CachedChapter {
  path: string;
  dev: number;
  ino: number;
  size: number;
  mtimeMs: number;
  /** The byte offset the counts cover: always just after a newline. */
  offset: number;
  /** SHA-256 of the bytes ending at `offset`: proof the prefix was not rewritten. */
  prefixDigest: string;
  counts: HomeChapterCounts;
}

class ChapterUnreadable extends Error {}

function emptyCounts(): HomeChapterCounts {
  return { userMessages: 0, homeReplies: 0, tasksDelegated: 0 };
}

function digestPrefix(bytes: Buffer): string {
  return createHash("sha256").update(bytes).digest("hex");
}

/**
 * Derives each chapter's counts from its canonical JSONL, kept as a cache of the last
 * scan per chapter. The cache is memory only: it is never persisted and never replaces
 * the canonical file. A scan extends the cached counts by the bytes appended since, when
 * the prefix it covered is unchanged; a changed, replaced or shrunken file is scanned
 * again from its start. Unchanged files cost one `stat`.
 *
 * Cost: an unchanged chapter costs one stat; an appended chapter parses only its new
 * bytes; the first scan after a Gateway start parses the whole chapter once. Parsing is
 * bounded by the chapter's own size, which the rollover limits bound.
 */
export class HomeChapterContentsReader {
  private readonly chapters = new Map<string, CachedChapter>();

  /**
   * The counts of one chapter's canonical file. A missing file is zero counts only for a
   * `reserved` chapter, which has no file until it materializes; for any other state a
   * missing file, or one that cannot be read or parsed, is `undefined`: unmeasured, never
   * an empty chapter.
   */
  async counts(sessionId: string, path: string | undefined, reserved: boolean): Promise<HomeChapterCounts | undefined> {
    if (path === undefined) return reserved ? emptyCounts() : undefined;
    let before;
    try {
      before = await stat(path);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return reserved ? emptyCounts() : undefined;
      return undefined;
    }
    if (!before.isFile()) return undefined;
    const cached = this.chapters.get(sessionId);
    try {
      if (cached && cached.path === path && cached.dev === before.dev && cached.ino === before.ino) {
        if (cached.size === before.size && cached.mtimeMs === before.mtimeMs) return { ...cached.counts };
        if (before.size >= cached.offset && await this.prefixMatches(path, cached)) {
          return await this.remember(sessionId, path, before, cached.counts, cached.offset, before.size);
        }
      }
      return await this.remember(sessionId, path, before, emptyCounts(), 0, before.size);
    } catch {
      // Any read or parse failure, including a file that changed or vanished during the scan, leaves
      // this chapter unmeasured and drops its cache entry: the list still answers for every other chapter.
      this.chapters.delete(sessionId);
      return undefined;
    }
  }

  private async prefixMatches(path: string, cached: CachedChapter): Promise<boolean> {
    const window = await readRange(path, Math.max(0, cached.offset - PREFIX_WINDOW_BYTES), cached.offset);
    return digestPrefix(window) === cached.prefixDigest;
  }

  /** Scans `[from, size)` and caches the counts through the last complete line. */
  private async remember(sessionId: string, path: string, identity: { dev: number; ino: number; size: number; mtimeMs: number },
    counts: HomeChapterCounts, from: number, size: number): Promise<HomeChapterCounts> {
    const scanned = await scanLines(path, from, size, counts);
    const prefix = await readRange(path, Math.max(0, scanned.offset - PREFIX_WINDOW_BYTES), scanned.offset);
    this.chapters.set(sessionId, { path, dev: identity.dev, ino: identity.ino, size: identity.size, mtimeMs: identity.mtimeMs,
      offset: scanned.offset, prefixDigest: digestPrefix(prefix), counts: scanned.counts });
    return { ...scanned.counts };
  }
}

/** Reads `[start, end)` of a file. Callers pass bounds the file has, so a short read is a change. */
async function readRange(path: string, start: number, end: number): Promise<Buffer> {
  const handle = await open(path, "r");
  try {
    const buffer = Buffer.alloc(end - start);
    const { bytesRead } = await handle.read(buffer, 0, buffer.length, start);
    if (bytesRead !== buffer.length) throw new ChapterUnreadable("chapter changed during its read");
    return buffer;
  } finally {
    await handle.close();
  }
}

/**
 * Streams `[from, size)` in chunks and applies every complete line. The returned offset is
 * just after the last newline; a trailing partial line is left for the next scan, so an
 * entry being appended is never counted half-written. A long line is joined once, at its
 * newline, so its cost is linear in its length.
 */
async function scanLines(path: string, from: number, size: number, start: HomeChapterCounts): Promise<{ counts: HomeChapterCounts; offset: number }> {
  const counts: HomeChapterCounts = { ...start };
  const handle = await open(path, "r");
  try {
    const chunk = Buffer.alloc(CHUNK_BYTES);
    // The absolute offset of the next byte to read, and of the first byte of the pending line.
    let position = from;
    let lineStart = from;
    let pending: Buffer[] = [];
    while (position < size) {
      const length = Math.min(CHUNK_BYTES, size - position);
      const { bytesRead } = await handle.read(chunk, 0, length, position);
      if (bytesRead !== length) throw new ChapterUnreadable("chapter changed during its scan");
      const piece = chunk.subarray(0, bytesRead);
      let cursor = 0;
      for (let at = piece.indexOf(NEWLINE); at !== -1; at = piece.indexOf(NEWLINE, cursor)) {
        pending.push(piece.subarray(cursor, at));
        applyLine(counts, Buffer.concat(pending).toString("utf8"));
        pending = [];
        cursor = at + 1;
        lineStart = position + cursor;
      }
      // The chunk is reused by the next read, so a pending remainder is copied.
      if (cursor < piece.length) pending.push(Buffer.from(piece.subarray(cursor)));
      position += bytesRead;
    }
    return { counts, offset: lineStart };
  } finally {
    await handle.close();
  }
}

function hasToolCall(content: unknown): boolean {
  return Array.isArray(content) && content.some(block => (block as { type?: unknown } | null)?.type === "toolCall");
}

/** Applies one canonical JSONL line. The header (`session`) is not an entry; a malformed
 * line makes the whole chapter unreadable rather than a miscounted one. */
function applyLine(counts: HomeChapterCounts, line: string): void {
  if (line.trim() === "") return;
  let entry: { type?: unknown; timestamp?: unknown; message?: { role?: unknown; content?: unknown; toolName?: unknown; isError?: unknown } };
  try {
    entry = JSON.parse(line);
  } catch {
    throw new ChapterUnreadable("chapter has a malformed line");
  }
  if (entry.type === "session") return;
  if (typeof entry.timestamp === "string") {
    counts.firstAt ??= entry.timestamp;
    counts.lastAt = entry.timestamp;
  }
  if (entry.type !== "message" || !entry.message) return;
  const message = entry.message;
  if (message.role === "user") counts.userMessages += 1;
  // A reply is an assistant message without a tool call: a tool-calling message is part of the work, not an answer.
  else if (message.role === "assistant" && !hasToolCall(message.content)) counts.homeReplies += 1;
  else if (message.role === "toolResult" && message.toolName === "delegate" && message.isError !== true) counts.tasksDelegated += 1;
}
