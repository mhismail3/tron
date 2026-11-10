import { createHash } from "node:crypto";
import { open, stat } from "node:fs/promises";
import type { HomeChapterContents } from "../../protocol/types.js";

export const HOME_CHAPTER_TOPIC_COUNT = 8;
const HOME_CHAPTER_TOPIC_CHARACTERS = 1000;
export const HOME_CHAPTER_TOPIC_LIST_CHARACTERS = 96_000;

const CHUNK_BYTES = 1024 * 1024;
const PREFIX_WINDOW_BYTES = 4096;
const NEWLINE = 0x0a;

export function homeChapterTopic(summary: string): string {
  const text = summary.split("\n")
    .filter(line => !/^(?:echo|event):/u.test(line.trim()))
    .map(line => line.trimEnd().replace(/^(\s*)(?:user|talk|summary):\s*/u, "$1"))
    .join("\n").replace(/\n{3,}/gu, "\n\n").trim();
  if (!text || /^\[call\b/iu.test(text)) return "";
  if ([...text].length <= HOME_CHAPTER_TOPIC_CHARACTERS) return text;
  const prefix = [...text].slice(0, HOME_CHAPTER_TOPIC_CHARACTERS - 1).join("");
  const boundary = Math.max(prefix.lastIndexOf(" "), prefix.lastIndexOf("\n"));
  return boundary > 0 ? `${prefix.slice(0, boundary).replace(/[\s,;:.–-]+$/u, "")}…` : "";
}

type HomeChapterCounts = Omit<HomeChapterContents, "topics">;

interface CachedChapter {
  path: string;
  dev: number;
  ino: number;
  size: number;
  mtimeMs: number;
  offset: number;
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

export class HomeChapterContentsReader {
  private readonly chapters = new Map<string, CachedChapter>();

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
      this.chapters.delete(sessionId);
      return undefined;
    }
  }

  private async prefixMatches(path: string, cached: CachedChapter): Promise<boolean> {
    const window = await readRange(path, Math.max(0, cached.offset - PREFIX_WINDOW_BYTES), cached.offset);
    return digestPrefix(window) === cached.prefixDigest;
  }

  private async remember(sessionId: string, path: string, identity: { dev: number; ino: number; size: number; mtimeMs: number },
    counts: HomeChapterCounts, from: number, size: number): Promise<HomeChapterCounts> {
    const scanned = await scanLines(path, from, size, counts);
    const prefix = await readRange(path, Math.max(0, scanned.offset - PREFIX_WINDOW_BYTES), scanned.offset);
    this.chapters.set(sessionId, { path, dev: identity.dev, ino: identity.ino, size: identity.size, mtimeMs: identity.mtimeMs,
      offset: scanned.offset, prefixDigest: digestPrefix(prefix), counts: scanned.counts });
    return { ...scanned.counts };
  }
}

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

async function scanLines(path: string, from: number, size: number, start: HomeChapterCounts): Promise<{ counts: HomeChapterCounts; offset: number }> {
  const counts: HomeChapterCounts = { ...start };
  const handle = await open(path, "r");
  try {
    const chunk = Buffer.alloc(CHUNK_BYTES);
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
  else if (message.role === "assistant" && !hasToolCall(message.content)) counts.homeReplies += 1;
  else if (message.role === "toolResult" && message.toolName === "delegate" && message.isError !== true) counts.tasksDelegated += 1;
}
