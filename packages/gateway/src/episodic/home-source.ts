import type { HomeMemoryEvidence } from "../protocol/types.js";
import { constants, type Stats } from "node:fs";
import { lstat, open } from "node:fs/promises";
import { abortableRead } from "../util/abortable-read.js";
import { EpisodicMemoryError } from "../errors.js";
import { HOME_MAX_CHAPTERS, type EpisodicChapterSourceCursor, type EpisodicLimits, type EpisodicSourceCursor } from "./episodic-contract.js";
import { COMPLETE_PREFIX_SEED, EpisodicSourceChangedError, episodicDigest, extendPrefixDigest, parseEntry, prefixLineDigest, sameSnapshot, type EpisodicCanonicalEntry } from "../kernel/session/canonical-reader.js";
import { projectBranch, type EpisodicProjectedMessage, type EpisodicSourceDelta } from "./episodic-projection.js";

export interface HomeSourceChapter { sessionId: string; path: string; sealed: boolean }
export interface HomeSourceSnapshot { homeId: string; ledgerRevision: number; chapters: readonly HomeSourceChapter[] }
interface CompactEntry {
  id: string;
  parentId: string | null;
  projected?: EpisodicProjectedMessage;
  shape?: EpisodicCanonicalEntry;
  edit?: { targetId: string; projected: EpisodicProjectedMessage };
}

function unchanged(info: Stats, cursor: EpisodicChapterSourceCursor): boolean {
  return info.ino === cursor.ino && info.size === cursor.size
    && info.mtimeMs === cursor.mtimeMs && info.ctimeMs === cursor.ctimeMs;
}
function fail(message: string): never { throw new EpisodicMemoryError("source", message); }

export async function* homeSourceLines(handle: Awaited<ReturnType<typeof open>>, start: number, end: number, maxLineBytes: number) {
  const buffer = Buffer.alloc(64 * 1024);
  let pieces: Buffer[] = [];
  let pendingBytes = 0;
  let position = start;
  while (position < end) {
    const { bytesRead } = await handle.read(buffer, 0, Math.min(buffer.length, end - position), position);
    if (bytesRead === 0) throw new EpisodicSourceChangedError();
    position += bytesRead;
    const chunk = buffer.subarray(0, bytesRead);
    let from = 0;
    let newline = chunk.indexOf(10);
    while (newline >= 0) {
      if (pendingBytes + newline - from > maxLineBytes) fail("Home canonical line exceeds the source bound");
      yield Buffer.concat([...pieces, chunk.subarray(from, newline)]);
      pieces = []; pendingBytes = 0;
      from = newline + 1;
      newline = chunk.indexOf(10, from);
    }
    if (pendingBytes + bytesRead - from > maxLineBytes) fail("Home canonical line exceeds the source bound");
    if (from < bytesRead) {
      pieces.push(Buffer.from(chunk.subarray(from)));
      pendingBytes += bytesRead - from;
    }
  }
}

async function holdsAdmittedPrefix(handle: Awaited<ReturnType<typeof open>>, cursor: EpisodicChapterSourceCursor, size: number, maxLineBytes: number): Promise<boolean> {
  if (size < cursor.completeBytes) return false;
  let prefix = COMPLETE_PREFIX_SEED;
  for await (const bytes of homeSourceLines(handle, 0, cursor.completeBytes, maxLineBytes)) prefix = extendPrefixDigest(prefix, bytes);
  return prefix === cursor.completePrefixDigest;
}

async function rekeyedCursor(chapter: HomeSourceChapter, cursor: EpisodicChapterSourceCursor, limits: EpisodicLimits): Promise<EpisodicChapterSourceCursor | undefined> {
  const handle = await open(chapter.path, constants.O_RDONLY | constants.O_NOFOLLOW).catch(() => fail("Home canonical source cannot be opened"));
  try {
    const start = await handle.stat();
    if (!start.isFile()) fail("Home canonical source is not a regular file");
    if (start.size !== cursor.size) return undefined;
    let held: boolean;
    try { held = await holdsAdmittedPrefix(handle, cursor, start.size, limits.maxSourceLineBytes); } catch (error) {
      if (error instanceof EpisodicMemoryError && error.kind === "source") held = false; else throw error;
    }
    const end = await handle.stat();
    if (!sameSnapshot(start, end)) throw new EpisodicSourceChangedError();
    return held ? { ...cursor, sealed: chapter.sealed, dev: end.dev, ino: end.ino, mtimeMs: end.mtimeMs, ctimeMs: end.ctimeMs } : undefined;
  } finally { await handle.close(); }
}

function singleProjection(entry: EpisodicCanonicalEntry, limits: EpisodicLimits, sourceSessionId: string): EpisodicProjectedMessage | undefined {
  return projectBranch([entry], limits, sourceSessionId)[0];
}

async function compactChapter(chapter: HomeSourceChapter, limits: EpisodicLimits, previous?: EpisodicChapterSourceCursor): Promise<{
  branch: CompactEntry[]; cursor: EpisodicChapterSourceCursor; incremental: boolean;
}> {
  const handle = await open(chapter.path, constants.O_RDONLY | constants.O_NOFOLLOW).catch(() => fail("Home canonical source cannot be opened"));
  try {
    const start = await handle.stat();
    if (!start.isFile()) fail("Home canonical source is not a regular file");
    if (previous && (start.size < previous.completeBytes
      || (start.ino !== previous.ino && !await holdsAdmittedPrefix(handle, previous, start.size, limits.maxSourceLineBytes)))) {
      if (chapter.sealed) fail("Home canonical source no longer matches its cursor");
      previous = undefined;
    }
    if (previous && (start.size === previous.size
      || await prefixLineDigest(handle, previous.completeBytes, limits.maxSourceLineBytes) !== previous.leafLineDigest)) previous = undefined;
    let incremental = Boolean(previous);
    const offset = incremental ? previous!.completeBytes : 0;
    const endBytes = start.size;
    const entries = new Map<string, CompactEntry>();
    let prefix = incremental ? previous!.completePrefixDigest : COMPLETE_PREFIX_SEED;
    let completeBytes = offset;
    let leaf = incremental ? previous!.leafEntryId : null;
    let leafDigest = incremental ? previous!.leafLineDigest : null;
    let headerSeen = incremental;
    try {
      for await (const bytes of homeSourceLines(handle, offset, endBytes, limits.maxSourceLineBytes)) {
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
        if (entries.has(entry.id)) fail("Home canonical source repeats an entry ID");
        if (incremental && (entry.parentId !== leaf || entry.type === "context_edit")) {
          incremental = false;
          break;
        }
        leaf = entry.id; leafDigest = episodicDigest(line);
        const compact: CompactEntry = { id: entry.id, parentId: entry.parentId };
        const projected = singleProjection(entry, limits, chapter.sessionId);
        if (projected) {
          compact.projected = projected;
          const message = entry.raw.message as Record<string, unknown> | undefined;
          compact.shape = { ...entry, line: "", raw: entry.type === "message"
            ? { message: { role: message?.role, toolName: message?.toolName } }
            : { display: entry.raw.display } };
        }
        if (entry.type === "context_edit" && typeof entry.raw.targetId === "string") {
          const target = entries.get(entry.raw.targetId);
          if (target?.shape && target.projected) {
            const edited = projectBranch([target.shape, { ...entry, line: "" }], limits, chapter.sessionId)[0];
            if (edited) compact.edit = { targetId: target.id, projected: { ...edited, sourceDigest: target.projected.sourceDigest } };
          }
        }
        entries.set(compact.id, compact);
      }
    } catch (error) {
      if (error instanceof EpisodicMemoryError && error.kind === "source") {
        const now = await handle.stat().catch(() => undefined);
        if (!now || !sameSnapshot(start, now)) throw new EpisodicSourceChangedError();
      }
      throw error;
    }
    if (previous && !incremental) {
      await handle.close();
      return compactChapter(chapter, limits);
    }
    if (!headerSeen) fail("Home canonical source is empty");
    const end = await handle.stat();
    if (!sameSnapshot(start, end) || end.size < endBytes) throw new EpisodicSourceChangedError();
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
    return { branch, incremental, cursor: {
      sessionId: chapter.sessionId, sealed: chapter.sealed, dev: end.dev, ino: end.ino, size: end.size,
      completeBytes, leafEntryId: leaf, leafLineDigest: leafDigest, completePrefixDigest: prefix,
      mtimeMs: end.mtimeMs, ctimeMs: end.ctimeMs,
    } };
  } finally { await handle.close(); }
}

async function validateSnapshot(snapshot: HomeSourceSnapshot, cursor: EpisodicSourceCursor | null) {
  if (!snapshot.chapters.length || snapshot.chapters.length > HOME_MAX_CHAPTERS
    || !Number.isSafeInteger(snapshot.ledgerRevision) || snapshot.ledgerRevision < 1) fail("Home source has no admitted ledger");
  const ids = new Set<string>();
  const prior = cursor?.home.chapters ?? [];
  if (cursor && cursor.home.version !== 2) fail("Home source cursor format is unsupported");
  if (prior.length > snapshot.chapters.length) fail("Home source lost an ingested chapter");
  const stats: Stats[] = [];
  for (const [index, chapter] of snapshot.chapters.entries()) {
    if (ids.has(chapter.sessionId)) fail("Home source repeats a chapter ID"); ids.add(chapter.sessionId);
    if (prior[index] && prior[index]!.sessionId !== chapter.sessionId) fail("Home source chapter order changed");
    const info = await lstat(chapter.path).catch(() => fail("Home canonical source is unavailable"));
    if (!info.isFile()) fail("Home canonical source is not a regular file");
    if (prior[index]?.sealed && (!chapter.sealed || info.size !== prior[index]!.size)) fail("Sealed Home source changed since ingestion");
    stats.push(info);
  }
  return stats;
}

function aggregate(snapshot: HomeSourceSnapshot, chapters: EpisodicChapterSourceCursor[]): EpisodicSourceCursor {
  const last = chapters.at(-1)!;
  const completeBytes = chapters.reduce((sum, chapter) => sum + chapter.completeBytes, 0);
  return { completeBytes, leafEntryId: last.leafEntryId,
    completePrefixDigest: episodicDigest(JSON.stringify(chapters)),
    home: { version: 2, ledgerRevision: snapshot.ledgerRevision, chapters: [...chapters] },
  };
}

export async function* readCanonicalHomeDeltas(snapshot: HomeSourceSnapshot, cursor: EpisodicSourceCursor | null, limits: EpisodicLimits): AsyncIterable<EpisodicSourceDelta> {
  const stats = await validateSnapshot(snapshot, cursor);
  const chapters = [...(cursor?.home.chapters ?? [])];
  let acknowledged = cursor;
  for (const [index, chapter] of snapshot.chapters.entries()) {
    const previous = chapters[index];
    if (previous && unchanged(stats[index]!, previous)) {
      chapters[index] = { ...previous, sealed: chapter.sealed };
      continue;
    }
    const rekeyed = previous && stats[index]!.size === previous.size && await rekeyedCursor(chapter, previous, limits);
    if (rekeyed) {
      chapters[index] = rekeyed;
      continue;
    }
    if (previous?.sealed) fail("Sealed Home source changed since ingestion");
    const cut = await compactChapter(chapter, limits, previous);
    chapters[index] = cut.cursor;
    const branchIds = new Set(cut.branch.map(entry => entry.id));
    const projected = new Map(cut.branch.flatMap(entry => entry.projected ? [[entry.id, entry.projected] as const] : []));
    for (const entry of cut.branch) if (entry.edit && branchIds.has(entry.edit.targetId)) projected.set(entry.edit.targetId, entry.edit.projected);
    const next = aggregate(snapshot, chapters);
    acknowledged = next;
    yield { sessionId: snapshot.homeId, projected: [...projected.values()],
      scopeSessionId: chapter.sessionId, cursor: next, incremental: cut.incremental };
  }
  const next = aggregate(snapshot, chapters);
  if (acknowledged?.completePrefixDigest === next.completePrefixDigest
    && acknowledged?.home.ledgerRevision === next.home.ledgerRevision) return;
  yield { sessionId: snapshot.homeId, projected: [], cursor: next, incremental: true };
}

interface ChapterProof {
  stat: Pick<Stats, "dev" | "ino" | "size" | "mtimeMs" | "ctimeMs">;
  completeBytes: number;
  completePrefixDigest: string;
  leafEntryId: string | null;
  leafLineDigest: string | null;
  lines: ReadonlyMap<string, { offset: number; bytes: number }>;
  branch: readonly string[];
}

export class HomeSourceProofs {
  private readonly chapters = new Map<string, ChapterProof>();
  private readonly running = new Map<string, Promise<ChapterProof>>();

  async prove(chapter: HomeSourceChapter, admitted: EpisodicChapterSourceCursor, limits: EpisodicLimits, signal?: AbortSignal): Promise<ChapterProof> {
    for (;;) {
      signal?.throwIfAborted();
      const running = this.running.get(chapter.sessionId);
      if (running) {
        await abortableRead(signal, () => running.then(() => undefined, () => undefined));
        continue;
      }
      const work = proveChapter(chapter, admitted, limits, this.chapters.get(chapter.sessionId))
        .then(proof => { this.chapters.set(chapter.sessionId, proof); return proof; })
        .finally(() => { this.running.delete(chapter.sessionId); });
      work.catch(() => {});
      this.running.set(chapter.sessionId, work);
      return await abortableRead(signal, () => work);
    }
  }

  retain(sessionIds: ReadonlySet<string>): void {
    for (const sessionId of this.chapters.keys()) if (!sessionIds.has(sessionId)) this.chapters.delete(sessionId);
  }
}

function sameStat(a: ChapterProof["stat"], b: ChapterProof["stat"]): boolean {
  return a.dev === b.dev && a.ino === b.ino && a.size === b.size && a.mtimeMs === b.mtimeMs && a.ctimeMs === b.ctimeMs;
}

function provenAt(proof: ChapterProof, admitted: EpisodicChapterSourceCursor): boolean {
  return proof.completeBytes === admitted.completeBytes && proof.completePrefixDigest === admitted.completePrefixDigest
    && proof.leafEntryId === admitted.leafEntryId;
}

async function proveChapter(chapter: HomeSourceChapter, admitted: EpisodicChapterSourceCursor, limits: EpisodicLimits,
  cached: ChapterProof | undefined): Promise<ChapterProof> {
  const handle = await open(chapter.path, constants.O_RDONLY | constants.O_NOFOLLOW).catch(() => fail("Home canonical source cannot be opened"));
  try {
    const start = await handle.stat();
    if (!start.isFile()) fail("Home canonical source is not a regular file");
    if (start.size < admitted.completeBytes) fail("Home canonical source no longer matches its cursor");
    if (cached && sameStat(cached.stat, start) && provenAt(cached, admitted)) return cached;
    const base = cached && !chapter.sealed && cached.stat.dev === start.dev && cached.stat.ino === start.ino
      && cached.completeBytes > 0 && cached.completeBytes <= admitted.completeBytes && cached.leafLineDigest !== null
      && await prefixLineDigest(handle, cached.completeBytes, limits.maxSourceLineBytes) === cached.leafLineDigest ? cached : undefined;
    const lineIndex = new Map(base?.lines);
    const parents = new Map<string, string | null>();
    let prefix = base ? base.completePrefixDigest : COMPLETE_PREFIX_SEED;
    let position = base ? base.completeBytes : 0;
    let leaf = base ? base.leafEntryId : null;
    let leafDigest = base ? base.leafLineDigest : null;
    let headerSeen = Boolean(base);
    const appended: string[] = [];
    let diverged = false;
    for await (const bytes of homeSourceLines(handle, position, admitted.completeBytes, limits.maxSourceLineBytes)) {
      const offset = position;
      prefix = extendPrefixDigest(prefix, bytes); position += bytes.length + 1;
      const line = bytes.toString("utf8");
      if (!headerSeen) {
        let header: Record<string, unknown>;
        try { header = JSON.parse(line); } catch { fail("Home canonical header is not JSON"); }
        if (!header || header.type !== "session" || header.version !== 3 || header.id !== chapter.sessionId) fail("Home canonical header does not match its chapter");
        headerSeen = true; continue;
      }
      if (!line.trim()) continue;
      const entry = parseEntry(line);
      if (lineIndex.has(entry.id)) fail("Home canonical source repeats an entry ID");
      if (base && entry.parentId !== leaf) {
        diverged = true;
        break;
      }
      lineIndex.set(entry.id, { offset, bytes: bytes.length });
      if (base) appended.push(entry.id); else parents.set(entry.id, entry.parentId);
      leaf = entry.id; leafDigest = episodicDigest(line);
    }
    if (diverged || (base && (prefix !== admitted.completePrefixDigest || leaf !== admitted.leafEntryId))) {
      await handle.close();
      return await proveChapter(chapter, admitted, limits, undefined);
    }
    if (!headerSeen) fail("Home canonical source is empty");
    if (prefix !== admitted.completePrefixDigest || leaf !== admitted.leafEntryId) {
      const end = await handle.stat();
      if (!sameSnapshot(start, end)) throw new EpisodicSourceChangedError();
      fail("Home canonical prefix changed since ingestion");
    }
    let branch: string[];
    if (base) branch = [...base.branch, ...appended];
    else {
      branch = [];
      const visited = new Set<string>();
      for (let id = leaf; id !== null;) {
        if (visited.has(id)) fail("Home canonical branch is cyclic");
        visited.add(id);
        const parent = parents.get(id);
        if (parent === undefined) fail("Home canonical branch has a missing parent");
        branch.push(id); id = parent;
      }
      branch.reverse();
    }
    return {
      stat: { dev: start.dev, ino: start.ino, size: start.size, mtimeMs: start.mtimeMs, ctimeMs: start.ctimeMs },
      completeBytes: position, completePrefixDigest: prefix, leafEntryId: leaf, leafLineDigest: leafDigest,
      lines: lineIndex, branch,
    };
  } finally { await handle.close().catch(() => {}); }
}

export async function* readCanonicalHomeIndex(snapshot: HomeSourceSnapshot, cursor: EpisodicSourceCursor, limits: EpisodicLimits,
  signal?: AbortSignal, proofs = new HomeSourceProofs()): AsyncIterable<{ id: string; sourceSessionId: string }> {
  await validateSnapshot(snapshot, cursor);
  proofs.retain(new Set(snapshot.chapters.map(chapter => chapter.sessionId)));
  const ids = new Set<string>();
  for (const [index, chapterCursor] of cursor.home.chapters.entries()) {
    const chapter = snapshot.chapters[index]!;
    signal?.throwIfAborted();
    const proof = await proofs.prove(chapter, chapterCursor, limits, signal);
    for (const id of proof.branch) {
      if (ids.has(id)) fail("Home source repeats a canonical entry ID across chapters");
      ids.add(id);
      yield { id, sourceSessionId: chapter.sessionId };
    }
  }
}

export async function readCanonicalHomeEvidence(snapshot: HomeSourceSnapshot, cursor: EpisodicSourceCursor,
  evidence: HomeMemoryEvidence, limits: EpisodicLimits, signal?: AbortSignal, proofs = new HomeSourceProofs()): Promise<EpisodicCanonicalEntry> {
  const index = cursor.home.chapters.findIndex(chapter => chapter.sessionId === evidence.sessionId);
  const chapter = snapshot.chapters[index];
  const admitted = cursor.home.chapters[index];
  if (!chapter || !admitted || chapter.sessionId !== evidence.sessionId) fail("Home evidence has no admitted chapter");
  const proof = await proofs.prove(chapter, admitted, limits, signal);
  const position = proof.lines.get(evidence.entryId);
  if (!position) fail("Home evidence entry is unavailable");
  const handle = await open(chapter.path, constants.O_RDONLY | constants.O_NOFOLLOW).catch(() => fail("Home canonical source cannot be opened"));
  try {
    const bytes = Buffer.alloc(position.bytes);
    for (let filled = 0; filled < bytes.length;) {
      signal?.throwIfAborted();
      const { bytesRead } = await handle.read(bytes, filled, bytes.length - filled, position.offset + filled);
      if (bytesRead === 0) throw new EpisodicSourceChangedError();
      filled += bytesRead;
    }
    const line = bytes.toString("utf8");
    if (episodicDigest(line) !== evidence.sourceDigest) fail("Home evidence digest changed");
    const entry = parseEntry(line);
    if (entry.id !== evidence.entryId) fail("Home evidence entry is unavailable");
    return entry;
  } finally { await handle.close().catch(() => {}); }
}
