import { HOME_MAX_CHAPTERS } from "../home/home-chapter-state.js";
import type { HomeMemoryEvidence } from "../protocol/types.js";
import { constants, type Stats } from "node:fs";
import { lstat, open } from "node:fs/promises";
import {
  EpisodicMemoryError, type EpisodicChapterSourceCursor, type EpisodicLimits, type EpisodicSourceCursor,
} from "./episodic-contract.js";
import {
  COMPLETE_PREFIX_SEED, EpisodicSourceChangedError, episodicDigest, extendPrefixDigest, parseEntry, prefixLineDigest, projectBranch,
  type EpisodicCanonicalEntry, type EpisodicProjectedMessage, type EpisodicSourceDelta,
} from "./episodic-source.js";

export interface HomeSourceChapter { sessionId: string; path: string; sealed: boolean }
export interface HomeSourceSnapshot { homeId: string; ledgerRevision: number; chapters: readonly HomeSourceChapter[] }
interface CompactEntry {
  id: string;
  parentId: string | null;
  projected?: EpisodicProjectedMessage;
  /** Only presentation kind is needed to project a later context edit. */
  shape?: EpisodicCanonicalEntry;
  edit?: { targetId: string; projected: EpisodicProjectedMessage };
}

function unchanged(info: Stats, cursor: EpisodicChapterSourceCursor): boolean {
  return info.dev === cursor.dev && info.ino === cursor.ino && info.size === cursor.size
    && info.mtimeMs === cursor.mtimeMs && info.ctimeMs === cursor.ctimeMs;
}
function fail(message: string): never { throw new EpisodicMemoryError("source", message); }

function sameFile(a: Stats, b: Stats): boolean {
  return a.dev === b.dev && a.ino === b.ino && a.size === b.size && a.mtimeMs === b.mtimeMs && a.ctimeMs === b.ctimeMs;
}

/** One line at a time. No batch of raw strings survives a parse/project step. */
async function* lines(handle: Awaited<ReturnType<typeof open>>, start: number, end: number, maxLineBytes: number, signal?: AbortSignal) {
  const buffer = Buffer.alloc(64 * 1024);
  let pending = Buffer.alloc(0);
  let position = start;
  while (position < end) {
    signal?.throwIfAborted();
    const { bytesRead } = await handle.read(buffer, 0, Math.min(buffer.length, end - position), position);
    if (bytesRead === 0) throw new EpisodicSourceChangedError();
    position += bytesRead;
    let chunk = Buffer.concat([pending, buffer.subarray(0, bytesRead)]);
    let newline = chunk.indexOf(10);
    while (newline >= 0) {
      if (newline > maxLineBytes) fail("Home canonical line exceeds the source bound");
      yield chunk.subarray(0, newline);
      chunk = chunk.subarray(newline + 1);
      newline = chunk.indexOf(10);
    }
    if (chunk.length > maxLineBytes) fail("Home canonical line exceeds the source bound");
    // Copy the tail: it must not retain the reused read buffer.
    pending = Buffer.from(chunk);
  }
  // A trailing partial line is a live writer's append, or a crash's: it is not an
  // entry until its newline lands. It stays unread, so the next delta ingests it
  // once complete, as the episodic reader does.
}

function singleProjection(entry: EpisodicCanonicalEntry, limits: EpisodicLimits): EpisodicProjectedMessage | undefined {
  return projectBranch([entry], limits)[0];
}

/** Raw payloads are projected immediately. Retained state is ID/parent topology,
 * capped text, and the minimal role shape used by context edits, never JSONL. */
async function compactChapter(chapter: HomeSourceChapter, limits: EpisodicLimits, previous?: EpisodicChapterSourceCursor, exact = false,
  evidence?: HomeMemoryEvidence, signal?: AbortSignal): Promise<{
  branch: CompactEntry[]; cursor: EpisodicChapterSourceCursor; incremental: boolean; evidence?: EpisodicCanonicalEntry;
}> {
  const handle = await open(chapter.path, constants.O_RDONLY | constants.O_NOFOLLOW).catch(() => fail("Home canonical source cannot be opened"));
  try {
    const start = await handle.stat();
    if (!start.isFile()) fail("Home canonical source is not a regular file");
    if (previous && (start.dev !== previous.dev || start.ino !== previous.ino || start.size < previous.completeBytes)) {
      if (exact || chapter.sealed) fail("Home canonical source no longer matches its cursor");
      previous = undefined;
    }
    if (previous && !exact && (start.size === previous.size
      || await prefixLineDigest(handle, previous.completeBytes) !== previous.leafLineDigest)) previous = undefined;
    let incremental = Boolean(previous && !exact);
    const offset = incremental ? previous!.completeBytes : 0;
    const endBytes = exact ? previous!.completeBytes : start.size;
    const entries = new Map<string, CompactEntry>();
    let selected: EpisodicCanonicalEntry | undefined;
    let prefix = incremental ? previous!.completePrefixDigest! : COMPLETE_PREFIX_SEED;
    let completeBytes = offset;
    let leaf = incremental ? previous!.leafEntryId : null;
    let leafDigest = incremental ? previous!.leafLineDigest : null;
    let headerSeen = incremental;
    try {
      for await (const bytes of lines(handle, offset, endBytes, limits.maxSourceLineBytes, signal)) {
        prefix = extendPrefixDigest(prefix, bytes); completeBytes += bytes.length + 1;
        const line = bytes.toString("utf8");
        if (!headerSeen) {
          let header: Record<string, unknown>;
          try { header = JSON.parse(line); } catch { fail("Home canonical header is not JSON"); }
          if (!header || header.type !== "session" || header.version !== 3 || header.id !== chapter.sessionId) fail("Home canonical header does not match its chapter");
          headerSeen = true; continue;
        }
        if (!line.trim()) continue;
        const entry = parseEntry(line);
        if (evidence?.entryId === entry.id) {
          if (episodicDigest(line) !== evidence.sourceDigest) fail("Home evidence digest changed");
          selected = entry;
        }
        if (entries.has(entry.id)) fail("Home canonical source repeats an entry ID");
        // Navigation and edits require the compact branch of this chapter, not a
        // whole-Home refresh. Close this handle before opening that full cut.
        if (incremental && (entry.parentId !== leaf || entry.type === "context_edit")) {
          incremental = false;
          break;
        }
        leaf = entry.id; leafDigest = episodicDigest(line);
        const compact: CompactEntry = { id: entry.id, parentId: entry.parentId };
        if (!exact) {
          const projected = singleProjection(entry, limits);
          if (projected) {
            compact.projected = { ...projected, sourceSessionId: chapter.sessionId };
            const message = entry.raw.message as Record<string, unknown> | undefined;
            compact.shape = { ...entry, line: "", raw: entry.type === "message"
              ? { message: { role: message?.role, toolName: message?.toolName } }
              : { display: entry.raw.display } };
          }
          if (entry.type === "context_edit" && typeof entry.raw.targetId === "string") {
            const target = entries.get(entry.raw.targetId);
            if (target?.shape && target.projected) {
              const edited = projectBranch([target.shape, { ...entry, line: "" }], limits)[0];
              if (edited) compact.edit = { targetId: target.id, projected: { ...edited, sourceDigest: target.projected.sourceDigest, sourceSessionId: chapter.sessionId } };
            }
          }
        }
        entries.set(compact.id, compact);
      }
    } catch (error) {
      // A delta read of a source that changed while it was read can fail to parse
      // mid-write or mid-rewrite. That is a transient cut: the next ingestion reads
      // it again. Only a stable malformed chapter, or an exact cursor read, refuses.
      if (!exact && error instanceof EpisodicMemoryError && error.kind === "source") {
        const now = await handle.stat().catch(() => undefined);
        if (!now || !sameFile(start, now)) throw new EpisodicSourceChangedError();
      }
      throw error;
    }
    if (previous && !exact && !incremental) {
      // The partial delta holds no canonical payload by the time we recurse.
      await handle.close();
      return compactChapter(chapter, limits);
    }
    if (!headerSeen) fail("Home canonical source is empty");
    const end = await handle.stat();
    if (end.dev !== start.dev || end.ino !== start.ino || end.size < endBytes
      || end.size !== start.size || end.mtimeMs !== start.mtimeMs || end.ctimeMs !== start.ctimeMs) throw new EpisodicSourceChangedError();
    if (exact && (prefix !== previous!.completePrefixDigest || leaf !== previous!.leafEntryId)) fail("Home canonical prefix changed since ingestion");
    const branch: CompactEntry[] = [];
    if (incremental) for (const entry of entries.values()) branch.push(entry);
    else {
      const visited = new Set<string>();
      for (let id = leaf; id !== null;) {
        if (visited.has(id)) fail("Home canonical branch is cyclic");
        visited.add(id);
        const entry = entries.get(id);
        if (!entry) fail("Home canonical branch has a missing parent");
        branch.push(entry); id = entry.parentId;
      }
      branch.reverse();
    }
    return { branch, incremental, ...(selected ? { evidence: selected } : {}), cursor: {
      sessionId: chapter.sessionId, sealed: chapter.sealed, dev: end.dev, ino: end.ino, size: exact ? previous!.size : end.size,
      completeBytes, leafEntryId: leaf, leafLineDigest: leafDigest, completePrefixDigest: prefix,
      mtimeMs: exact ? previous!.mtimeMs : end.mtimeMs, ctimeMs: exact ? previous!.ctimeMs : end.ctimeMs,
    } };
  } finally { await handle.close(); }
}

async function validateSnapshot(snapshot: HomeSourceSnapshot, cursor: EpisodicSourceCursor | null) {
  if (!snapshot.chapters.length || snapshot.chapters.length > HOME_MAX_CHAPTERS
    || !Number.isSafeInteger(snapshot.ledgerRevision) || snapshot.ledgerRevision < 1) fail("Home source has no admitted ledger");
  const ids = new Set<string>();
  const prior = cursor?.home?.chapters ?? [];
  if (cursor && (!cursor.home || cursor.home.version !== 2)) fail("Home source cursor format is unsupported");
  if (prior.length > snapshot.chapters.length) fail("Home source lost an ingested chapter");
  const stats: Stats[] = [];
  for (const [index, chapter] of snapshot.chapters.entries()) {
    if (ids.has(chapter.sessionId)) fail("Home source repeats a chapter ID"); ids.add(chapter.sessionId);
    if (prior[index] && prior[index]!.sessionId !== chapter.sessionId) fail("Home source chapter order changed");
    const info = await lstat(chapter.path).catch(() => fail("Home canonical source is unavailable"));
    if (!info.isFile()) fail("Home canonical source is not a regular file");
    if (prior[index]?.sealed && (!chapter.sealed || !unchanged(info, prior[index]!))) fail("Sealed Home source changed since ingestion");
    stats.push(info);
  }
  return stats;
}

function aggregate(snapshot: HomeSourceSnapshot, chapters: EpisodicChapterSourceCursor[]): EpisodicSourceCursor {
  const last = chapters.at(-1)!;
  const completeBytes = chapters.reduce((sum, chapter) => sum + chapter.completeBytes, 0);
  return { dev: last.dev, ino: last.ino, size: completeBytes, completeBytes,
    leafEntryId: last.leafEntryId, leafLineDigest: last.leafLineDigest,
    completePrefixDigest: episodicDigest(JSON.stringify(chapters)),
    home: { version: 2, ledgerRevision: snapshot.ledgerRevision, chapters: [...chapters] },
  };
}

/** Consume/commit one chapter before reading the next. Only capped projections
 * cross the await into EpisodicMemory; old sealed JSONL is never reopened. */
export async function* readCanonicalHomeDeltas(snapshot: HomeSourceSnapshot, cursor: EpisodicSourceCursor | null, limits: EpisodicLimits): AsyncIterable<EpisodicSourceDelta> {
  const stats = await validateSnapshot(snapshot, cursor);
  const chapters = [...(cursor?.home?.chapters ?? [])];
  let acknowledged = cursor;
  for (const [index, chapter] of snapshot.chapters.entries()) {
    const previous = chapters[index];
    if (previous && unchanged(stats[index]!, previous)) {
      chapters[index] = { ...previous, sealed: chapter.sealed };
      continue;
    }
    const cut = await compactChapter(chapter, limits, previous);
    chapters[index] = cut.cursor;
    const branchIds = new Set(cut.branch.map(entry => entry.id));
    const projected = new Map(cut.branch.flatMap(entry => entry.projected ? [[entry.id, entry.projected] as const] : []));
    for (const entry of cut.branch) if (entry.edit && branchIds.has(entry.edit.targetId)) projected.set(entry.edit.targetId, entry.edit.projected);
    const next = aggregate(snapshot, chapters);
    acknowledged = next;
    yield { sessionId: snapshot.homeId, projected: [...projected.values()],
      scopeSessionId: chapter.sessionId, completeBytes: next.completeBytes,
      leafEntryId: next.leafEntryId, cursor: next, incremental: cut.incremental };
  }
  // Even no-op ingestion acknowledges a ledger-only transition (seal/roll).
  const next = aggregate(snapshot, chapters);
  if (acknowledged?.completePrefixDigest === next.completePrefixDigest
    && acknowledged?.home?.ledgerRevision === next.home!.ledgerRevision) return;
  yield { sessionId: snapshot.homeId, projected: [], completeBytes: next.completeBytes,
    leafEntryId: next.leafEntryId, cursor: next, incremental: true };
}

/** Exact frozen cuts are not delta reads. Stream a compact index through each
 * admitted prefix, proving its digest, with no raw text retained or later tail. */
export async function* readCanonicalHomeIndex(snapshot: HomeSourceSnapshot, cursor: EpisodicSourceCursor, limits: EpisodicLimits, signal?: AbortSignal): AsyncIterable<{ id: string; sourceSessionId: string }> {
  await validateSnapshot(snapshot, cursor);
  const ids = new Set<string>();
  for (const [index, chapterCursor] of cursor.home!.chapters.entries()) {
    const chapter = snapshot.chapters[index]!;
    signal?.throwIfAborted();
    const cut = await compactChapter(chapter, limits, chapterCursor, true, undefined, signal);
    for (const entry of cut.branch) {
      if (ids.has(entry.id)) fail("Home source repeats a canonical entry ID across chapters");
      ids.add(entry.id);
      yield { id: entry.id, sourceSessionId: chapter.sessionId };
    }
  }
}

/** Read one original entry through its admitted physical prefix. Unlike the
 * projection, this retains only the selected bounded raw line. It never opens
 * SessionManager (which may migrate/repair files). All-chapter proof is the
 * caller's read boundary; this second pass proves the selected line at use. */
export async function readCanonicalHomeEvidence(snapshot: HomeSourceSnapshot, cursor: EpisodicSourceCursor,
  evidence: HomeMemoryEvidence, limits: EpisodicLimits, signal?: AbortSignal): Promise<EpisodicCanonicalEntry> {
  const index = cursor.home?.chapters.findIndex(chapter => chapter.sessionId === evidence.sessionId) ?? -1;
  const chapter = snapshot.chapters[index];
  const admitted = cursor.home?.chapters[index];
  if (!chapter || !admitted || chapter.sessionId !== evidence.sessionId) fail("Home evidence has no admitted chapter");
  const cut = await compactChapter(chapter, limits, admitted, true, evidence, signal);
  if (!cut.evidence) fail("Home evidence entry is unavailable");
  return cut.evidence;
}
