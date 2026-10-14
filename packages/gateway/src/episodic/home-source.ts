import { HOME_MAX_CHAPTERS } from "../home/home-chapter-state.js";
import type { HomeMemoryEvidence } from "../protocol/types.js";
import { constants, type Stats } from "node:fs";
import { lstat, open } from "node:fs/promises";
import { abortableRead } from "../util/abortable-read.js";
import {
  EpisodicMemoryError, type EpisodicChapterSourceCursor, type EpisodicLimits, type EpisodicSourceCursor,
} from "./episodic-contract.js";
import {
  COMPLETE_PREFIX_SEED, EpisodicSourceChangedError, episodicDigest, extendPrefixDigest, parseEntry, prefixLineDigest, projectBranch, sameSnapshot,
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

/** One line at a time. No batch of raw strings survives a parse/project step. A
 * line can be tens of megabytes (an inline image), so its reads are kept as pieces
 * and joined once: joining each read onto the pending bytes copies the line once
 * per read. */
async function* lines(handle: Awaited<ReturnType<typeof open>>, start: number, end: number, maxLineBytes: number) {
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
    // Copy the tail: it must not retain the reused read buffer.
    if (from < bytesRead) {
      pieces.push(Buffer.from(chunk.subarray(from)));
      pendingBytes += bytesRead - from;
    }
  }
  // A trailing partial line is a live writer's append, or a crash's: it is not an
  // entry until its newline lands. It stays unread, so the next delta ingests it
  // once complete, as the episodic reader does.
}

function singleProjection(entry: EpisodicCanonicalEntry, limits: EpisodicLimits, sourceSessionId: string): EpisodicProjectedMessage | undefined {
  return projectBranch([entry], limits, sourceSessionId)[0];
}

/** Raw payloads are projected immediately. Retained state is ID/parent topology,
 * capped text, and the minimal role shape used by context edits, never JSONL. */
async function compactChapter(chapter: HomeSourceChapter, limits: EpisodicLimits, previous?: EpisodicChapterSourceCursor): Promise<{
  branch: CompactEntry[]; cursor: EpisodicChapterSourceCursor; incremental: boolean;
}> {
  const handle = await open(chapter.path, constants.O_RDONLY | constants.O_NOFOLLOW).catch(() => fail("Home canonical source cannot be opened"));
  try {
    const start = await handle.stat();
    if (!start.isFile()) fail("Home canonical source is not a regular file");
    if (previous && (start.dev !== previous.dev || start.ino !== previous.ino || start.size < previous.completeBytes)) {
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
      for await (const bytes of lines(handle, offset, endBytes, limits.maxSourceLineBytes)) {
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
        // Navigation and edits require the compact branch of this chapter, not a
        // whole-Home refresh. Close this handle before opening that full cut.
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
      // A delta read of a source that changed while it was read can fail to parse
      // mid-write or mid-rewrite. That is a transient cut: the next ingestion reads
      // it again. Only a stable malformed chapter refuses.
      if (error instanceof EpisodicMemoryError && error.kind === "source") {
        const now = await handle.stat().catch(() => undefined);
        if (!now || !sameSnapshot(start, now)) throw new EpisodicSourceChangedError();
      }
      throw error;
    }
    if (previous && !incremental) {
      // The partial delta holds no canonical payload by the time we recurse.
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
    if (prior[index]?.sealed && (!chapter.sealed || !unchanged(info, prior[index]!))) fail("Sealed Home source changed since ingestion");
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

/** Consume/commit one chapter before reading the next. Only capped projections
 * cross the await into EpisodicMemory; old sealed JSONL is never reopened. */
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
  // Even no-op ingestion acknowledges a ledger-only transition (seal/roll).
  const next = aggregate(snapshot, chapters);
  if (acknowledged?.completePrefixDigest === next.completePrefixDigest
    && acknowledged?.home.ledgerRevision === next.home.ledgerRevision) return;
  yield { sessionId: snapshot.homeId, projected: [], cursor: next, incremental: true };
}

/** One chapter's exact proof: the admitted prefix's digest and leaf re-derived
 * from its bytes, the file stat it was read under, and where each entry's line
 * sits in that prefix. Positions only; no canonical text is retained. */
interface ChapterProof {
  stat: Pick<Stats, "dev" | "ino" | "size" | "mtimeMs" | "ctimeMs">;
  completeBytes: number;
  completePrefixDigest: string;
  leafEntryId: string | null;
  leafLineDigest: string | null;
  /** Every entry of the prefix, on the branch or not: evidence may name either. */
  lines: ReadonlyMap<string, { offset: number; bytes: number }>;
  /** The branch through the leaf, oldest first. */
  branch: readonly string[];
}

/**
 * Proofs of admitted chapter prefixes, owned by one Home memory owner (#940).
 * Every memory read proves every admitted chapter against canonical bytes, and
 * re-deriving that digest from all of Home's history on each read made a read's
 * cost grow with every byte Home ever wrote (tens of megabytes; past the browser's
 * 5 s read deadline on a busy Gateway). A proof is reused only while its file's
 * stat is identical, which is the same unchanged-file test sealed chapters are
 * held to. An appended active chapter is extended from its last proof: the line
 * ending at the proven boundary must still hash to the proven leaf (ingestion's
 * own append test), and only the new bytes are read; any other change, a
 * non-linear entry included, re-proves the whole chapter.
 */
export class HomeSourceProofs {
  private readonly chapters = new Map<string, ChapterProof>();
  /** One proof per chapter at a time. A cancelled read abandons only its wait:
   * the bounded pass completes for the next read, so a cold proof slower than the
   * read deadline still converges instead of restarting on every retry. */
  private readonly running = new Map<string, Promise<ChapterProof>>();

  async prove(chapter: HomeSourceChapter, admitted: EpisodicChapterSourceCursor, limits: EpisodicLimits, signal?: AbortSignal): Promise<ChapterProof> {
    for (;;) {
      signal?.throwIfAborted();
      const running = this.running.get(chapter.sessionId);
      if (running) {
        // Joined work proved some admitted cut; re-check this one against it.
        await abortableRead(signal, () => running.then(() => undefined, () => undefined));
        continue;
      }
      const work = proveChapter(chapter, admitted, limits, this.chapters.get(chapter.sessionId))
        .then(proof => { this.chapters.set(chapter.sessionId, proof); return proof; })
        .finally(() => { this.running.delete(chapter.sessionId); });
      work.catch(() => {}); // An abandoned failure is observed by the next read, not unhandled.
      this.running.set(chapter.sessionId, work);
      return await abortableRead(signal, () => work);
    }
  }

  /** Forget chapters the ledger no longer admits. */
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
    if (start.dev !== admitted.dev || start.ino !== admitted.ino || start.size < admitted.completeBytes) fail("Home canonical source no longer matches its cursor");
    if (cached && sameStat(cached.stat, start) && provenAt(cached, admitted)) return cached;
    // Only an appended active chapter extends; a sealed one must be unchanged.
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
    for await (const bytes of lines(handle, position, admitted.completeBytes, limits.maxSourceLineBytes)) {
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
        // Navigation since the last proof: the branch must be walked again.
        diverged = true;
        break;
      }
      lineIndex.set(entry.id, { offset, bytes: bytes.length });
      if (base) appended.push(entry.id); else parents.set(entry.id, entry.parentId);
      leaf = entry.id; leafDigest = episodicDigest(line);
    }
    // A base the admitted cut does not extend (navigation, or a rewrite that a
    // full ingestion read) is stale, not a refusal: prove from the first byte.
    if (diverged || (base && (prefix !== admitted.completePrefixDigest || leaf !== admitted.leafEntryId))) {
      await handle.close();
      return await proveChapter(chapter, admitted, limits, undefined);
    }
    if (!headerSeen) fail("Home canonical source is empty");
    if (prefix !== admitted.completePrefixDigest || leaf !== admitted.leafEntryId) {
      const end = await handle.stat();
      // A rewrite while it was read is transient; a stable mismatch is a refusal.
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

/** Exact frozen cuts are not delta reads. Stream the branch index of each
 * admitted prefix, proving its digest, with no raw text retained or later tail.
 * Without an owner's proofs the read proves every chapter from its first byte. */
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

/** Read one original entry through its admitted physical prefix. Unlike the
 * projection, this retains only the selected bounded raw line. It never opens
 * SessionManager (which may migrate/repair files). All-chapter proof is the
 * caller's read boundary; this read proves the chapter and then the selected
 * line's own digest at use. */
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
