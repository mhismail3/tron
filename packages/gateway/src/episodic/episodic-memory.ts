import { join } from "node:path";
import type { AssistantMessage } from "@earendil-works/pi-ai";
import { AsyncMutex } from "../util/async-mutex.js";
import {
  EpisodicMemoryError, EPISODIC_DEFAULTS, EPISODIC_INVALIDATION_CHUNK, EPISODIC_OMITTED_TEXT,
  EPISODIC_PLACEHOLDER, EPISODIC_SEARCH_HITS, EPISODIC_SEARCH_QUERY_CHARS, EPISODIC_SEARCH_SNIPPET_CHARS,
  EPISODIC_STATUS_PARTS, EPISODIC_STORE_VERSION, defaultSleep, resolveLimits,
  type EpisodicBlocked, type EpisodicBlockedReason, type EpisodicCompactorRequest, type EpisodicDiagnostic,
  type EpisodicInvalidationRecord, type EpisodicLimits, type EpisodicMemoryDependencies, type EpisodicMemoryStatus,
  type EpisodicMessageRecord, type EpisodicNodeRecord, type EpisodicSourceCursor, type EpisodicStoreState,
  type EpisodicSummarizer, type EpisodicTokenBudget, type EpisodicViewPartStatus,
} from "./episodic-contract.js";
import {
  EPISODIC_COMPACT_PROMPT, classifyReply, classifyThrown, compactorRequest, contextBlock,
  createModelRuntimeSummarizer, estimateCompactorReservation, leafStep, mergeStep, sizeFeedback,
  summarizerText, usageTokens, withFeedback,
} from "./episodic-compactor.js";
import {
  projectBranch, readCanonicalEntryInstants, readCanonicalSession, episodicDigest,
  type EpisodicCanonicalCut, type EpisodicCanonicalEntry,
} from "./episodic-source.js";
import { EpisodicStore, type EpisodicStoreSnapshot } from "./episodic-store.js";
import {
  EPISODIC_MAX_LEVEL, decodeContextRuns, encodeNodeCode, fitView, foldViewSliced, freeNodeText, mergedFreeText, nodeAddress,
  parseNodeAddress, placeholderBytes, snippetAround, utf8Bytes, viewContext,
  type EpisodicViewPart,
} from "./episodic-tree.js";

/*
 * The owner of one source session's memory: the projected catalog, the binary
 * summary tree, the view, and the pump that builds nodes (departures 3 and 5 of
 * the brief). It never subscribes to a session; `entriesCommitted` re-reads the
 * canonical file after its cursor and drains the pump, and `whenReady` is what a
 * request layer waits on.
 *
 * Ingestion, invalidation and `resume` are serialized behind one mutex. The pump
 * is not: it may still be building when the next commit invalidates nodes, so
 * every build carries the generation and the input revisions it started from and
 * discards its result when either changed.
 */

/** The pump stops on this signal: the memory is blocked and `resume()` restarts
 * it. It never escapes to a caller. */
class EpisodicBlockedSignal extends Error {
  constructor(readonly blocked: EpisodicBlocked) {
    super(blocked.detail ? `${blocked.reason}: ${blocked.detail}` : blocked.reason);
    this.name = "EpisodicBlockedSignal";
  }
}

/** One compactor call that overran its bound. Its own class, so the retry loop
 * classifies it as transient without reading its message. */
class EpisodicCallTimeout extends Error {
  constructor(readonly boundMs: number) {
    super(`the compactor call exceeded its ${boundMs}ms bound`);
    this.name = "EpisodicCallTimeout";
  }
}

/** The owner is closing; in-flight work ends without blocking. */
class EpisodicClosedSignal extends Error {
  constructor() { super("Episodic memory is closing"); this.name = "EpisodicClosedSignal"; }
}

interface Waiter {
  cut: number;
  resolve: () => void;
  reject: (error: Error) => void;
  signal?: AbortSignal;
  onAbort?: () => void;
}

/** One message's instant, as Home's `date` tool reports it. `unavailable` is the
 * source's own answer that it can no longer prove it: never a guessed time. */
export type EpisodicTimestampResult = { kind: "timestamp"; timestamp: string } | { kind: "unavailable" };

/** One search's outcome (`EPISODIC_SEARCH_HITS` lines, the whole range's match
 * count, and how much of the range could contribute no searchable text at all, so
 * an absence is never read as proof). */
export interface EpisodicSearchResult {
  /** At most `EPISODIC_SEARCH_HITS` lines, `id+0|kind: <snippet>`, in index order. */
  lines: string[];
  /** Messages in the range whose projected text contains the query. */
  matches: number;
  /** Messages in the range that are `[omitted]`. */
  omitted: number;
  /** Messages in the range whose projected text was capped. */
  capped: number;
  /** The range searched, after clamping to the messages this memory holds. */
  from: number;
  to: number;
}

/** What one build started from. A result is published only while the generation
 * and every input revision still match. */
interface BuildStamp {
  generation: number;
  inputs: Array<{ address: string; revision: number }>;
  messageIndex?: number;
  messageRevision?: number;
}

/**
 * The persisted state of one session's memory without opening it: the blocked
 * state and the spend a later open would restore. `home.status` reports both
 * while no activation has opened the store yet, and a session with no store at
 * all reads as undefined.
 */
export async function readEpisodicState(options: {
  workspace: import("../workspace/tron-workspace.js").TronWorkspace;
  sessionId: string;
  maxStoreLineBytes?: number;
}): Promise<EpisodicStoreState | undefined> {
  const store = new EpisodicStore(
    options.workspace,
    options.sessionId,
    options.maxStoreLineBytes ?? EPISODIC_DEFAULTS.maxStoreLineBytes,
  );
  const snapshot = await store.read();
  return snapshot.state ?? undefined;
}

export class EpisodicMemory {
  /** One in-process opener per store: two memories over one session would write
   * the same files without a lock between them. */
  private static readonly openStores = new Set<string>();

  private readonly limits: EpisodicLimits;
  private readonly store: EpisodicStore;
  private readonly summarizer: EpisodicSummarizer;
  private readonly budget: EpisodicTokenBudget;
  private readonly sleep: (ms: number, signal: AbortSignal) => Promise<void>;
  private readonly diagnostic: (record: EpisodicDiagnostic) => void;
  private readonly mutex = new AsyncMutex();
  private readonly abort = new AbortController();

  private readonly messages = new Map<number, EpisodicMessageRecord>();
  private readonly nodes = new Map<string, EpisodicNodeRecord>();
  private readonly entryIndex = new Map<string, number>();
  private readonly building = new Set<string>();
  private view: EpisodicViewPart[] = [];
  private revision = 1;
  private generation = 0;
  private sourceCursor: EpisodicSourceCursor | null = null;
  private sourceBranch: EpisodicCanonicalEntry[] = [];
  private blocked: EpisodicBlocked | null = null;
  private waiters: Waiter[] = [];
  private draining: Promise<void> | null = null;
  private appending: Promise<void> = Promise.resolve();
  private storeKey: string | undefined;
  /** Instants read from the canonical source for catalog records written before
   * the optional `timestamp` existed. Read at most once per memory: an entry's
   * instant never changes. */
  private legacyTimestamps: Promise<Map<string, string>> | undefined;
  private closed = false;

  private constructor(private readonly dependencies: EpisodicMemoryDependencies, limits: EpisodicLimits) {
    this.limits = limits;
    this.store = new EpisodicStore(dependencies.workspace, dependencies.sessionId, limits.maxStoreLineBytes);
    this.budget = dependencies.budget;
    this.summarizer = dependencies.summarizer ?? createModelRuntimeSummarizer(dependencies.modelRuntime, dependencies.model);
    this.sleep = dependencies.sleep ?? defaultSleep;
    this.diagnostic = dependencies.diagnostic ?? (() => {});
  }

  /** Open (or start) the memory for one source session: load the persisted
   * catalog and nodes, replay them, fold the view from message 0 (sliced, so a
   * long history never blocks the loop for the whole fold), and repair a
   * catalog revision whose invalidation a crash lost. */
  static async open(dependencies: EpisodicMemoryDependencies): Promise<EpisodicMemory> {
    const limits = resolveLimits(dependencies.limits);
    const descriptor = await dependencies.workspace.describe();
    if (!descriptor.available) throw new EpisodicMemoryError("unsafe-store", "Tron internal workspace is unavailable; episodic memory cannot be opened");
    const storeKey = join(descriptor.root, "state", "episodic", dependencies.sessionId);
    if (EpisodicMemory.openStores.has(storeKey)) {
      throw new EpisodicMemoryError("already-open", `Episodic memory for session ${dependencies.sessionId} is already open in this process`);
    }
    EpisodicMemory.openStores.add(storeKey);
    const memory = new EpisodicMemory(dependencies, limits);
    memory.storeKey = storeKey;
    try {
      let snapshot: EpisodicStoreSnapshot;
      try {
        snapshot = await memory.store.read();
      } catch (error) {
        if (error instanceof EpisodicMemoryError && (error.kind === "invalid-store" || error.kind === "unsafe-store")) {
          memory.diagnostic({ event: "episodic.store-refused", level: "error", message: "Episodic memory store was refused", reason: error.kind });
        }
        throw error;
      }
      const replayed = EpisodicStore.replay(snapshot);
      for (const [index, record] of replayed.messages) memory.messages.set(index, record);
      for (const [address, record] of replayed.nodes) memory.nodes.set(address, record);
      for (const record of replayed.messages.values()) memory.entryIndex.set(record.entryId, record.index);
      memory.revision = snapshot.highestRevision + 1;
      memory.generation = Math.max(snapshot.state?.generation ?? 0, snapshot.highestGeneration);
      if (snapshot.state) {
        memory.sourceCursor = snapshot.state.cursor;
        memory.blocked = snapshot.state.blocked;
        // Spend is restored before any compactor call, so a restarted Gateway
        // cannot spend a second budget on the same history.
        memory.budget.restore(snapshot.state.spend);
      }
      if (snapshot.recoveredTornBytes > 0) {
        memory.diagnostic({
          event: "episodic.store-recovered", level: "warning",
          message: "Discarded a torn trailing episodic record that was never acknowledged",
          counts: { bytes: snapshot.recoveredTornBytes },
        });
      }
      memory.assertConsistent();
      memory.view = await foldViewSliced(memory.messages.size, limits.viewBytes, part => memory.partBytes(part), address => memory.nodes.has(address));
      await memory.repairCatalogMismatch();
      return memory;
    } catch (error) {
      EpisodicMemory.openStores.delete(storeKey);
      throw error;
    }
  }

  /** Re-read the canonical session, ingest what the cursor has not seen, and
   * drain the pump. A source read failure blocks with `source-unavailable`. */
  async entriesCommitted(sessionId: string): Promise<void> {
    await this.entriesIngested(sessionId);
    await this.drain();
  }

  /**
   * Re-read the canonical session and ingest what the cursor has not seen,
   * WITHOUT waiting for the pump: the pump is started, not awaited. A turn loop
   * waits only for the lines it will send (`whenReady`), never for summaries of
   * messages that come after them, so a request's latency cannot depend on
   * summarizing its own input and a slow compactor cannot stall a turn that does
   * not need its output.
   */
  async entriesIngested(sessionId: string): Promise<void> {
    this.assertOpen();
    if (sessionId !== this.dependencies.sessionId) throw new EpisodicMemoryError("invalid-request", "entriesCommitted names a different session");
    await this.mutex.run(async () => {
      if (this.blocked) return;
      await this.ingest();
    });
    void this.drain().catch(() => {});
  }

  /** Resolves when every part of the view covering messages before `cut` is a
   * built summary (gist §6). The view is soft-budgeted, so this is not a hard
   * window check. It rejects a cut beyond the message count, a blocked memory,
   * and an already-aborted wait. */
  async whenReady(cut: number, options: { signal?: AbortSignal } = {}): Promise<void> {
    this.assertOpen();
    if (!Number.isSafeInteger(cut) || cut < 0) throw new EpisodicMemoryError("invalid-request", "whenReady cut must be a non-negative integer");
    const signal = options.signal;
    if (signal?.aborted) throw new EpisodicMemoryError("closed", "whenReady wait was cancelled");
    if (this.blocked) throw this.blockedError();
    if (cut > this.messages.size) throw new EpisodicMemoryError("invalid-request", `whenReady cut ${cut} is beyond the ${this.messages.size} messages this memory holds`);
    if (this.viewReady(cut)) return;
    return new Promise<void>((resolve, reject) => {
      const waiter: Waiter = { cut, resolve, reject, ...(signal ? { signal } : {}) };
      if (signal) {
        waiter.onAbort = () => { this.removeWaiter(waiter); reject(new EpisodicMemoryError("closed", "whenReady wait was cancelled")); };
        signal.addEventListener("abort", waiter.onAbort, { once: true });
      }
      this.waiters.push(waiter);
    });
  }

  /**
   * How many of the messages this memory holds are at or before one canonical
   * entry of the branch it last read: gist §6's cut, the number of view lines a
   * request that starts at that entry covers. `null` is an empty history, so the
   * cut is 0.
   *
   * Undefined when the entry is not on the branch this memory last read, or when
   * it has not read the source at all: a cut cannot be guessed, because a wrong
   * cut would render a view that does not stop where the activation starts.
   */
  cutAtEntry(entryId: string | null): number | undefined {
    this.assertOpen();
    if (entryId === null) return 0;
    const position = this.sourceBranch.findIndex(entry => entry.id === entryId);
    if (position < 0 || this.sourceCursor === null) return undefined;
    let cut = 0;
    for (let index = 0; index <= position; index += 1) {
      const messageIndex = this.entryIndex.get(this.sourceBranch[index]!.id);
      if (messageIndex !== undefined && messageIndex + 1 > cut) cut = messageIndex + 1;
    }
    return cut;
  }

  /**
   * The agent-facing view up to `cut` (gist §5.1): one `id+n|text` line per
   * part, oldest first, newlines flattened to single spaces. It covers the
   * whole history before the cut, so a request that starts there never sends a
   * message it does not own.
   *
   * A part that straddles the cut is expanded into the children under it: those
   * are built whenever their parent is (a parent is composed from its children
   * and revoked with them), so the expansion cannot render a placeholder. The
   * placeholder is still the value for a part `whenReady` did not cover, which
   * is display state, never a served request (the request layer waits first).
   */
  renderView(cut: number): { text: string; lines: number; bytes: number } {
    this.assertOpen();
    const parts: EpisodicViewPart[] = [];
    const add = (part: EpisodicViewPart): void => {
      if (part.start >= cut) return;
      if (part.level === 0 || part.start + part.span <= cut) { parts.push(part); return; }
      const half = part.span / 2;
      add({ level: part.level - 1, index: part.index * 2, start: part.start, span: half });
      add({ level: part.level - 1, index: part.index * 2 + 1, start: part.start + half, span: half });
    };
    for (const part of this.view) add(part);
    const lines = parts.map(part => `${nodeAddress(part.level, part.index)}|${viewLine(this.nodes.get(nodeAddress(part.level, part.index))?.text)}`);
    const text = lines.join("\n");
    return { text, lines: lines.length, bytes: utf8Bytes(text) };
  }

  /**
   * The recipe's zoom (gist §7.1): line `id+n` opened into the two lines of
   * `id+n/2` under it, or — at n = 1 — the message itself, from the catalog's
   * current projection, so a redaction, an exclusion or an `[omitted]` slot is
   * exactly what the caller reads. `undefined` when `id+n` is not a line of this
   * memory: n is not a power of two, id is not a multiple of n, or the line runs
   * past the last message.
   *
   * A child that is not built right now — never built, or invalidated and not yet
   * rebuilt — renders the placeholder, never the text it held before (gist §6): a
   * revoked node is deleted, so stale text cannot survive here. The caller
   * ingests the canonical commits first, and never awaits the pump for them.
   */
  zoomLines(id: number, n: number): string[] | undefined {
    this.assertOpen();
    if (!Number.isSafeInteger(id) || !Number.isSafeInteger(n) || n < 1) return undefined;
    const level = Math.log2(n);
    if (level % 1 !== 0 || level > EPISODIC_MAX_LEVEL) return undefined;
    if (id < 0 || id % n !== 0 || id + n > this.messages.size) return undefined;
    if (n === 1) {
      const message = this.messages.get(id);
      if (!message) return undefined;
      // The recipe's `id+0|`: the logged message, not the summarized node.
      return [`${id}+0|${message.kind}: ${message.text}`];
    }
    const half = n / 2;
    return [id, id + half].map((start) => {
      const node = this.nodes.get(nodeAddress(level - 1, start / half));
      return `${start}+${half}|${node ? viewLine(node.text) : EPISODIC_PLACEHOLDER}`;
    });
  }

  /**
   * The canonical instant of one message: the catalog record's own field, or —
   * for a record written before that field existed — the instant the source proves
   * for that entry id. That proof covers every parsed entry of the file, not only
   * the branch the last entry follows, so an entry that has left the branch is
   * still dated; the read is the bounded canonical reader the owner already uses,
   * it is not `SessionManager`, and it happens at most once per memory because an
   * entry's instant never changes. `unavailable` is the source's answer that it
   * holds no such entry (or that it cannot read the file at all): the memory never
   * invents a time. `undefined` means this memory holds no such message.
   */
  async entryTimestamp(id: number): Promise<EpisodicTimestampResult | undefined> {
    this.assertOpen();
    const message = this.messages.get(id);
    if (!message) return undefined;
    if (message.timestamp !== undefined) return { kind: "timestamp", timestamp: message.timestamp };
    const timestamps = await this.canonicalTimestamps();
    const timestamp = timestamps.get(message.entryId);
    return timestamp === undefined ? { kind: "unavailable" } : { kind: "timestamp", timestamp };
  }

  /**
   * One case-insensitive substring pass over the projected catalog (Tron's
   * addition to the recipe's tools). Bounded: a hit line per match up to
   * `EPISODIC_SEARCH_HITS`, each snippet bounded to
   * `EPISODIC_SEARCH_SNIPPET_CHARS`, and the range's `[omitted]` and capped counts,
   * so a message that cannot be searched is named rather than silently absent.
   * `undefined` for an empty query or one over `EPISODIC_SEARCH_QUERY_CHARS`.
   * Omitted bounds default to the whole memory and are clamped to it.
   */
  searchMessages(query: string, from?: number, to?: number): EpisodicSearchResult | undefined {
    this.assertOpen();
    if (query.length === 0 || query.length > EPISODIC_SEARCH_QUERY_CHARS) return undefined;
    const count = this.messages.size;
    const start = Math.min(Math.max(from ?? 0, 0), count);
    const end = Math.min(Math.max(to ?? count, start), count);
    const needle = query.toLowerCase();
    const lines: string[] = [];
    let matches = 0;
    let omitted = 0;
    let capped = 0;
    for (let index = start; index < end; index += 1) {
      const message = this.messages.get(index);
      if (!message) continue;
      if (message.omitted) omitted += 1;
      if (message.omissions.includes("capped")) capped += 1;
      const at = message.text.toLowerCase().indexOf(needle);
      if (at < 0) continue;
      matches += 1;
      if (lines.length < EPISODIC_SEARCH_HITS) {
        lines.push(`${index}+0|${message.kind}: ${snippetAround(message.text, at, query.length, EPISODIC_SEARCH_SNIPPET_CHARS)}`);
      }
    }
    return { lines, matches, omitted, capped, from: start, to: end };
  }

  /** Clear the blocked state, re-read the source and restart the pump
   * (departure 5). The cause must have been fixed by the caller: a larger budget,
   * a different model, a reachable source. */
  async resume(): Promise<void> {
    await this.resumeIngested();
    await this.drain();
  }

  /**
   * The same, WITHOUT waiting for the pump: the block is cleared and the source
   * re-read under the lock, and the pump is started, not awaited. An operator
   * command (a raised budget, `home.resumeMemory`) must return once the memory is
   * unblocked, not after the whole summary backlog; a caller that needs the lines
   * it will send waits on `whenReady` as a turn does.
   */
  async resumeIngested(): Promise<void> {
    this.assertOpen();
    await this.mutex.run(async () => {
      if (this.blocked) {
        this.blocked = null;
        await this.saveState();
        await this.ingest();
      }
    });
    void this.drain().catch(() => {});
  }

  status(): EpisodicMemoryStatus {
    const byLevel = new Map<number, number>();
    let free = 0;
    let summary = 0;
    let summarized = 0;
    for (const node of this.nodes.values()) {
      byLevel.set(node.level, (byLevel.get(node.level) ?? 0) + 1);
      if (node.kind === "free") free += 1; else summary += 1;
      if (node.level === 0) summarized += 1;
    }
    const listed = this.view.slice(0, EPISODIC_STATUS_PARTS);
    let built = 0;
    let bytes = 0;
    const parts: EpisodicViewPartStatus[] = [];
    for (const part of this.view) {
      const state = this.partBytes(part);
      if (state.built) built += 1;
      bytes += state.bytes;
    }
    for (const part of listed) {
      const state = this.partBytes(part);
      parts.push({ address: nodeAddress(part.level, part.index), start: part.start, messages: part.span, bytes: state.bytes, built: state.built });
    }
    const tokens = this.budget.snapshot();
    return {
      sourceSessionId: this.dependencies.sessionId,
      generation: this.generation,
      messages: this.messages.size,
      nodes: {
        total: this.nodes.size,
        free,
        summary,
        byLevel: [...byLevel.entries()].sort((a, b) => a[0] - b[0]).map(([level, count]) => ({ level, count })),
      },
      view: {
        parts,
        truncatedParts: Math.max(0, this.view.length - listed.length),
        bytes,
        budgetBytes: this.limits.viewBytes,
        built,
        unbuilt: this.view.length - built,
      },
      coverage: { admitted: this.messages.size, summarized },
      pump: { busy: this.building.size },
      blocked: this.blocked,
      tokens,
    };
  }

  /** Stop the pump, abort in-flight compactor calls and release every waiter. */
  async dispose(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    this.abort.abort();
    // An ingest in flight holds the mutex and is still appending to this store, and
    // the opener is what keeps a second writer out: releasing it before that ingest
    // finishes would both let a second opener take a store that is still being
    // written and leave records landing after the store was closed. Everything this
    // memory owed is durable before the opener goes.
    await this.mutex.run(async () => {});
    await this.draining?.catch(() => {});
    if (this.storeKey) EpisodicMemory.openStores.delete(this.storeKey);
    for (const waiter of this.waiters.splice(0)) {
      if (waiter.onAbort && waiter.signal) waiter.signal.removeEventListener("abort", waiter.onAbort);
      waiter.reject(new EpisodicMemoryError("closed", "Episodic memory was disposed"));
    }
  }

  // ---- ingestion -----------------------------------------------------------------

  private async ingest(): Promise<void> {
    let cut: EpisodicCanonicalCut;
    const previous = this.sourceCursor && this.sourceBranch.length > 0 ? { cursor: this.sourceCursor, branch: this.sourceBranch } : undefined;
    try {
      cut = await readCanonicalSession({
        path: this.dependencies.sessionFile,
        sessionId: this.dependencies.sessionId,
        maxLineBytes: this.limits.maxSourceLineBytes,
        ...(previous ? { previous } : {}),
      });
    } catch (error) {
      if (error instanceof EpisodicMemoryError && error.kind === "source") {
        await this.block("source-unavailable", error.message);
        return;
      }
      throw error;
    }
    if (previous && cut.completeBytes === previous.cursor.completeBytes && cut.leafEntryId === previous.cursor.leafEntryId) {
      this.sourceCursor = cut.cursor;
      this.sourceBranch = cut.branch;
      return;
    }

    const projection = projectBranch(cut, this.limits);
    const changed: number[] = [];
    const seen = new Set<string>();
    try {
      for (const message of projection) {
        seen.add(message.entryId);
        const existing = this.entryIndex.get(message.entryId);
        if (existing === undefined) {
          const index = this.messages.size;
          const record: EpisodicMessageRecord = { revision: this.takeRevision(), index, ...message, sessionId: this.dependencies.sessionId };
          await this.appendCatalog(record);
          this.entryIndex.set(message.entryId, index);
          this.messages.set(index, record);
          // A new message appends one part to the view; nothing is invalidated.
          this.view.push({ level: 0, index, start: index, span: 1 });
          this.fit();
          continue;
        }
        const current = this.messages.get(existing);
        if (current && current.text === message.text && current.omitted === message.omitted && current.kind === message.kind) continue;
        const record: EpisodicMessageRecord = { revision: this.takeRevision(), index: existing, ...message, sessionId: this.dependencies.sessionId };
        await this.appendCatalog(record);
        this.messages.set(existing, record);
        changed.push(existing);
      }

      // Navigation: an entry the branch no longer holds keeps its index and
      // becomes `[omitted]`, so no later message is ever renumbered.
      for (const [entryId, index] of this.entryIndex) {
        if (seen.has(entryId)) continue;
        const current = this.messages.get(index);
        if (!current || current.omitted) continue;
        const record: EpisodicMessageRecord = {
          ...current,
          revision: this.takeRevision(),
          text: EPISODIC_OMITTED_TEXT,
          omitted: true,
          projectedDigest: episodicDigest(EPISODIC_OMITTED_TEXT),
          omissions: [...new Set([...current.omissions, "off-branch"])],
        };
        await this.appendCatalog(record);
        this.messages.set(index, record);
        changed.push(index);
      }

      if (changed.length > 0) await this.invalidate(changed);
    } catch (error) {
      // A record the store refuses is a visible blocked state, never a silent
      // throw that leaves the cursor stalled.
      if (error instanceof EpisodicMemoryError && (error.kind === "invalid-store" || error.kind === "unsafe-store")) {
        await this.block("permanent-failure", error.message);
        return;
      }
      throw error;
    }
    this.sourceCursor = cut.cursor;
    this.sourceBranch = cut.branch;
    await this.saveState();
  }

  /** A catalog revision whose invalidation a crash lost: a live leaf whose
   * recorded source digest disagrees with the message it summarizes is a leaf
   * whose summary is stale, so the closure runs again at load. */
  private async repairCatalogMismatch(): Promise<void> {
    const changed: number[] = [];
    for (const node of this.nodes.values()) {
      if (node.level !== 0) continue;
      const message = this.messages.get(node.index);
      if (!message) continue;
      if (node.sourceDigest !== episodicDigest(`${message.kind}: ${message.text}`)) changed.push(node.index);
    }
    if (changed.length > 0) await this.invalidate(changed);
  }

  /**
   * The instants of every entry the canonical file holds, keyed by entry id, for
   * catalog records written before the optional `timestamp` existed. One bounded
   * read (the reader the owner already uses, which never repairs or migrates),
   * remembered for the life of this memory. A read that fails is not remembered:
   * the next question asks the source again, and the answer in the meantime is
   * `unavailable` rather than a guess.
   */
  private canonicalTimestamps(): Promise<Map<string, string>> {
    this.legacyTimestamps ??= readCanonicalEntryInstants({
      path: this.dependencies.sessionFile,
      sessionId: this.dependencies.sessionId,
      maxLineBytes: this.limits.maxSourceLineBytes,
    }).catch(() => {
      this.legacyTimestamps = undefined;
      return new Map<string, string>();
    });
    return this.legacyTimestamps;
  }

  /** Invalidate exactly the affected leaves, their ancestors, and every node
   * whose recorded summarizer context included any invalidated node,
   * transitively (departure 3). A node added by the closure brings its own
   * ancestors with it: a parent stands in for its children, so a revoked child
   * under a live parent would be an inconsistent store.
   *
   * The revocation is written in ancestor-first chunks. Any prefix of that order
   * leaves every live parent with live children, so a crash between chunks is a
   * consistent (if under-invalidated) store, and `repairCatalogMismatch` finds
   * the changed leaf again on the next open. */
  private async invalidate(changedIndices: readonly number[]): Promise<void> {
    const invalid = new Set<string>();
    const ancestorsOf = (address: string): string[] => {
      const parsed = parseNodeAddress(address);
      if (!parsed) return [];
      const ancestors: string[] = [];
      for (let level = parsed.level, i = parsed.index; level <= 63; level += 1, i = Math.floor(i / 2)) {
        const ancestor = nodeAddress(level, i);
        // Children are written before their parents, so an absent ancestor means
        // every ancestor above it is absent too.
        if (!this.nodes.has(ancestor)) break;
        ancestors.push(ancestor);
      }
      return ancestors;
    };
    const dependents = new Map<string, string[]>();
    for (const [address, node] of this.nodes) {
      for (const dependency of decodeContextRuns(node.contextRuns)) {
        const list = dependents.get(dependency);
        if (list) list.push(address); else dependents.set(dependency, [address]);
      }
    }
    const queue: string[] = [];
    const add = (address: string): void => {
      if (invalid.has(address)) return;
      invalid.add(address);
      queue.push(address);
    };
    for (const index of changedIndices) for (const ancestor of ancestorsOf(nodeAddress(0, index))) add(ancestor);
    while (queue.length > 0) {
      const address = queue.pop()!;
      for (const ancestor of ancestorsOf(address)) add(ancestor);
      for (const dependent of dependents.get(address) ?? []) add(dependent);
    }
    if (invalid.size === 0) return;
    this.generation += 1;
    const generation = this.generation;
    const ordered = [...invalid].sort((left, right) => {
      const a = parseNodeAddress(left)!;
      const b = parseNodeAddress(right)!;
      return b.level - a.level || a.index - b.index;
    });
    const parts = Math.ceil(ordered.length / EPISODIC_INVALIDATION_CHUNK);
    for (let part = 0; part < parts; part += 1) {
      const chunk = ordered.slice(part * EPISODIC_INVALIDATION_CHUNK, (part + 1) * EPISODIC_INVALIDATION_CHUNK);
      const record: EpisodicInvalidationRecord = {
        revision: this.takeRevision(), generation, part, parts,
        nodes: chunk.map(address => {
          const parsed = parseNodeAddress(address)!;
          return encodeNodeCode(parsed.level, parsed.index);
        }).join(" "),
      };
      // Durable before use: a crash between revoking and rebuilding must not
      // leave a revoked child under a live parent.
      await this.appendNode(record);
      for (const address of chunk) this.nodes.delete(address);
      this.expandInvalidatedParts(new Set(chunk));
      this.fit();
    }
    this.diagnostic({
      event: "episodic.source-invalidated", level: "info",
      message: "A source revision invalidated summarized nodes",
      counts: { invalidated: invalid.size, generation },
    });
  }

  /** A revoked merged part cannot stay in the view: only level-0 parts may be
   * unbuilt (gist §6), so the tiling expands it into the two lines under it. */
  private expandInvalidatedParts(invalid: ReadonlySet<string>): void {
    for (;;) {
      let expanded = false;
      const next: EpisodicViewPart[] = [];
      for (const part of this.view) {
        if (part.level > 0 && invalid.has(nodeAddress(part.level, part.index))) {
          const half = part.span / 2;
          next.push({ level: part.level - 1, index: part.index * 2, start: part.start, span: half });
          next.push({ level: part.level - 1, index: part.index * 2 + 1, start: part.start + half, span: half });
          expanded = true;
        } else next.push(part);
      }
      this.view = next;
      if (!expanded) break;
    }
  }

  // ---- the pump (gist §4.1) ------------------------------------------------------

  private async drain(): Promise<void> {
    if (this.closed || this.blocked) return;
    if (!this.draining) {
      this.draining = (async () => {
        try {
          await this.pump();
        } catch (error) {
          // The pump handles every failure it can classify; anything that
          // escapes it (a store append that fails on I/O, say) would otherwise
          // leave the pump dead, the memory unblocked and every waiter waiting
          // for a node that can never come. For a caller that never awaits the
          // drain — the turn loop, which only waits on `whenReady` — an
          // unexpected failure of the owner's own loop is a permanent failure,
          // so it blocks with the reason and releases the waiters. The
          // settlement runs in a `finally`: a block that cannot be persisted
          // still must not strand a waiter.
          try {
            await this.block("permanent-failure", error instanceof Error ? error.message : String(error));
          } finally {
            this.settleWaiters();
          }
        }
      })().finally(() => { this.draining = null; });
    }
    await this.draining;
  }

  /** The recipe's pump: fill the JOBS slots, and re-pump after **each**
   * completion, so a finished merge never waits behind a slow sibling. Every
   * published node fits the view first. */
  private async pump(): Promise<void> {
    const running = new Map<string, Promise<void>>();
    try {
      for (;;) {
        if (this.closed || this.blocked) break;
        while (running.size < this.limits.jobs) {
          const next = this.nextStartable();
          if (!next) break;
          const key = nodeAddress(next.level, next.index);
          const task = this.buildNode(next.level, next.index).finally(() => { running.delete(key); });
          running.set(key, task);
        }
        if (running.size === 0) break;
        await Promise.race(running.values());
      }
    } finally {
      await Promise.allSettled([...running.values()]);
      this.settleWaiters();
    }
  }

  /** Rule 3 of gist §4.1: a node builds only when its whole context is
   * summarized (`end <= first(view)`), which is what keeps leaves in order. */
  private nextStartable(): { level: number; index: number } | undefined {
    const count = this.messages.size;
    const first = this.firstUnbuilt();
    for (let level = 0; 2 ** level <= count; level += 1) {
      const span = 2 ** level;
      for (let index = 0; (index + 1) * span <= count; index += 1) {
        const address = nodeAddress(level, index);
        if (this.nodes.has(address) || this.building.has(address)) continue;
        const end = level === 0 ? index : (index + 1) * span;
        if (end > first) continue;
        if (level > 0 && (!this.nodes.has(nodeAddress(level - 1, index * 2)) || !this.nodes.has(nodeAddress(level - 1, index * 2 + 1)))) continue;
        return { level, index };
      }
    }
    return undefined;
  }

  private firstUnbuilt(): number {
    for (const part of this.view) if (!this.nodes.has(nodeAddress(part.level, part.index))) return part.start;
    return this.messages.size;
  }

  private async buildNode(level: number, index: number): Promise<void> {
    const address = nodeAddress(level, index);
    if (this.closed || this.blocked) return;
    this.building.add(address);
    try {
      const stamp = this.buildStamp(level, index);
      if (!stamp) {
        // The node's source is gone, so it can never be composed. That is a
        // stopped pump with a reason, never a busy loop.
        await this.block("permanent-failure", `node ${address} has no source to summarize`);
        return;
      }
      const record = await this.composeNode(level, index, stamp);
      if (!record || this.stale(stamp)) return;
      // The append is serialized, so the durable order is the publication order
      // and the view fits the same sequence the log replays.
      await this.appendNode(record);
      if (this.stale(stamp)) return;
      this.nodes.set(address, record);
      this.fit();
    } catch (error) {
      if (error instanceof EpisodicBlockedSignal) await this.block(error.blocked.reason, error.blocked.detail);
      else if (error instanceof EpisodicClosedSignal) return;
      else if (error instanceof EpisodicMemoryError && (error.kind === "invalid-store" || error.kind === "unsafe-store")) {
        await this.block("permanent-failure", error.message);
      } else throw error;
    } finally {
      this.building.delete(address);
    }
  }

  private buildStamp(level: number, index: number): BuildStamp | undefined {
    if (level === 0) {
      const message = this.messages.get(index);
      if (!message) return undefined;
      return { generation: this.generation, inputs: [], messageIndex: index, messageRevision: message.revision };
    }
    const childA = this.nodes.get(nodeAddress(level - 1, index * 2));
    const childB = this.nodes.get(nodeAddress(level - 1, index * 2 + 1));
    if (!childA || !childB) return undefined;
    return {
      generation: this.generation,
      inputs: [
        { address: nodeAddress(level - 1, index * 2), revision: childA.revision },
        { address: nodeAddress(level - 1, index * 2 + 1), revision: childB.revision },
      ],
    };
  }

  /** True when this build's result must not be published: the memory closed or
   * blocked, an invalidation bumped the generation, or one of its inputs was
   * revoked or rebuilt while the compactor call ran. */
  private stale(stamp: BuildStamp): boolean {
    if (this.closed || this.blocked) return true;
    if (this.generation !== stamp.generation) return true;
    for (const input of stamp.inputs) if (this.nodes.get(input.address)?.revision !== input.revision) return true;
    if (stamp.messageIndex !== undefined && this.messages.get(stamp.messageIndex)?.revision !== stamp.messageRevision) return true;
    return false;
  }

  private async composeNode(level: number, index: number, stamp: BuildStamp): Promise<EpisodicNodeRecord | undefined> {
    const span = 2 ** level;
    if (level === 0) {
      const message = this.messages.get(index);
      if (!message) return undefined;
      const source = `${message.kind}: ${message.text}`;
      if (message.omitted) {
        // `[omitted]` is never sent to the model; it is a free node whatever the
        // limit, so an edit or a navigation costs nothing.
        return this.freeNode(level, index, `${message.kind}: ${EPISODIC_OMITTED_TEXT}`, episodicDigest(source));
      }
      const free = freeNodeText(message.kind, message.text, this.limits.nodeBytes);
      if (free) return this.freeNode(level, index, free, episodicDigest(source));
      const context = this.context(index);
      const text = await this.compact(context.lines, leafStep(message.kind, message.text, this.limits.nodeBytes), stamp);
      return this.summaryNode(level, index, text, context.runs, episodicDigest(source));
    }
    const childA = this.nodes.get(nodeAddress(level - 1, index * 2));
    const childB = this.nodes.get(nodeAddress(level - 1, index * 2 + 1));
    if (!childA || !childB) return undefined;
    const source = `${childA.text}\n${childB.text}`;
    const childRevisions: [number, number] = [childA.revision, childB.revision];
    const free = mergedFreeText(childA.text, childB.text, this.limits.nodeBytes);
    if (free) return { ...this.freeNode(level, index, free, episodicDigest(source)), childRevisions };
    const context = this.context((index + 1) * span);
    const text = await this.compact(context.lines, mergeStep(childA.text, childB.text, this.limits.nodeBytes), stamp);
    return { ...this.summaryNode(level, index, text, context.runs, episodicDigest(source)), childRevisions };
  }

  private freeNode(level: number, index: number, text: string, sourceDigest: string): EpisodicNodeRecord {
    return { revision: this.takeRevision(), level, index, kind: "free", text, contextRuns: [], textDigest: episodicDigest(text), sourceDigest };
  }

  private summaryNode(level: number, index: number, text: string, runs: EpisodicNodeRecord["contextRuns"], sourceDigest: string): EpisodicNodeRecord {
    return {
      revision: this.takeRevision(), level, index, kind: "summary", text,
      contextRuns: runs, textDigest: episodicDigest(text), sourceDigest,
    };
  }

  /** The context block's lines and level runs: the view up to the node's end,
   * bare, no ids, one line per part. */
  private context(end: number): { lines: string[]; runs: EpisodicNodeRecord["contextRuns"] } {
    return viewContext(this.view, end, part => this.nodes.get(nodeAddress(part.level, part.index))?.text);
  }

  // ---- one compactor call, the size loop, retries and the budget ---------------

  private async compact(lines: readonly string[], step: string, stamp: BuildStamp): Promise<string> {
    let request = compactorRequest(EPISODIC_COMPACT_PROMPT, contextBlock(lines), step, this.abort.signal);
    const tries: string[] = [];
    for (let attempt = 0; attempt < this.limits.tries; attempt += 1) {
      const reply = await this.compactCall(request, stamp);
      tries.push(reply);
      if (utf8Bytes(reply) <= this.limits.nodeBytes || attempt + 1 >= this.limits.tries) break;
      request = withFeedback(request, reply, sizeFeedback(reply, this.limits.nodeBytes));
    }
    // Keep the shortest try (gist §4.3): a stubborn node keeps a line a few
    // bytes over, which is fine because the view measures real sizes.
    return tries.reduce((shortest, line) => utf8Bytes(line) < utf8Bytes(shortest) ? line : shortest, tries[0]!);
  }

  private async compactCall(request: EpisodicCompactorRequest, stamp: BuildStamp): Promise<string> {
    for (let attempt = 0; ; attempt += 1) {
      if (this.stale(stamp)) throw new EpisodicClosedSignal();
      const estimate = estimateCompactorReservation(request);
      if (!this.budget.reserve(estimate)) {
        throw new EpisodicBlockedSignal({ reason: "budget-exhausted", detail: `A compactor call estimated at ${estimate} tokens does not fit the remaining budget` });
      }
      let message: AssistantMessage;
      try {
        message = await this.summarizerWithinBound(request);
      } catch (error) {
        this.budget.settle(estimate, 0);
        if (this.closed || error instanceof EpisodicClosedSignal) throw new EpisodicClosedSignal();
        // A call that overran its bound answered too late to be used, so it is a
        // transient failure and its reservation was released above.
        const verdict = error instanceof EpisodicCallTimeout ? "transient" : classifyThrown(error);
        const detail = error instanceof Error ? error.message : "the compactor call failed";
        if (verdict === "permanent") throw new EpisodicBlockedSignal({ reason: "permanent-failure", detail });
        if (attempt >= this.limits.maxRetries) throw new EpisodicBlockedSignal({ reason: "retries-exhausted", detail });
        await this.wait(this.limits.retryMs);
        continue;
      }
      this.budget.settle(estimate, usageTokens(message.usage));
      // Durable before the next call: a crash must not hand the budget back.
      await this.saveState();
      const verdict = classifyReply(message);
      if (verdict === "ok") return summarizerText(message);
      if (verdict === "permanent") {
        throw new EpisodicBlockedSignal({ reason: "permanent-failure", detail: message.errorMessage ?? "the compactor returned no line" });
      }
      if (attempt >= this.limits.maxRetries) {
        throw new EpisodicBlockedSignal({ reason: "retries-exhausted", detail: message.errorMessage ?? "the compactor call kept failing" });
      }
      await this.wait(this.limits.retryMs);
    }
  }

  /**
   * One compactor call under its own bound, injectable through the limits. The
   * call's signal is aborted at the bound so a real provider stops reading, the
   * late promise is neutralized (its rejection must not surface unhandled and its
   * answer is never used), and the caller sees a transient failure.
   */
  private async summarizerWithinBound(request: EpisodicCompactorRequest): Promise<AssistantMessage> {
    const bound = this.limits.compactorTimeoutMs;
    if (bound <= 0) return await this.summarizer(request);
    const controller = new AbortController();
    const forward = () => controller.abort();
    this.abort.signal.addEventListener("abort", forward, { once: true });
    let timer: NodeJS.Timeout | undefined;
    const expired = new Promise<"timeout">((resolve) => {
      timer = setTimeout(() => { controller.abort(); resolve("timeout"); }, bound);
      timer.unref();
    });
    const call = this.summarizer({ ...request, signal: controller.signal });
    call.catch(() => {});
    try {
      const settled = await Promise.race([call.then(value => ({ message: value }) as const), expired]);
      if (settled === "timeout") throw new EpisodicCallTimeout(bound);
      return settled.message;
    } finally {
      if (timer) clearTimeout(timer);
      this.abort.signal.removeEventListener("abort", forward);
    }
  }

  private async wait(ms: number): Promise<void> {
    if (this.closed) throw new EpisodicClosedSignal();
    try {
      await this.sleep(ms, this.abort.signal);
    } catch {
      throw new EpisodicClosedSignal();
    }
    if (this.closed) throw new EpisodicClosedSignal();
  }

  // ---- view, waiters, blocked state --------------------------------------------

  private fit(): void {
    fitView(this.view, this.messages.size, this.limits.viewBytes, part => this.partBytes(part), address => this.nodes.has(address));
    this.settleWaiters();
  }

  private partBytes(part: EpisodicViewPart): { built: boolean; bytes: number } {
    const node = this.nodes.get(nodeAddress(part.level, part.index));
    return node ? { built: true, bytes: utf8Bytes(node.text) } : { built: false, bytes: placeholderBytes() };
  }

  private viewReady(cut: number): boolean {
    if (cut <= 0) return true;
    for (const part of this.view) {
      if (part.start >= cut) return true;
      if (!this.nodes.has(nodeAddress(part.level, part.index))) return false;
      if (part.start + part.span >= cut) return true;
    }
    return false;
  }

  private settleWaiters(): void {
    if (this.waiters.length === 0) return;
    const remaining: Waiter[] = [];
    for (const waiter of this.waiters) {
      if (this.blocked) {
        if (waiter.onAbort && waiter.signal) waiter.signal.removeEventListener("abort", waiter.onAbort);
        waiter.reject(this.blockedError());
        continue;
      }
      if (this.closed) {
        if (waiter.onAbort && waiter.signal) waiter.signal.removeEventListener("abort", waiter.onAbort);
        waiter.reject(new EpisodicMemoryError("closed", "Episodic memory was disposed"));
        continue;
      }
      if (this.viewReady(waiter.cut)) {
        if (waiter.onAbort && waiter.signal) waiter.signal.removeEventListener("abort", waiter.onAbort);
        waiter.resolve();
        continue;
      }
      remaining.push(waiter);
    }
    this.waiters = remaining;
  }

  private removeWaiter(waiter: Waiter): void {
    this.waiters = this.waiters.filter(candidate => candidate !== waiter);
  }

  private blockedError(): EpisodicMemoryError {
    const blocked = this.blocked;
    return new EpisodicMemoryError("blocked", blocked
      ? `Episodic memory is blocked (${blocked.reason})${blocked.detail ? `: ${blocked.detail}` : ""}`
      : "Episodic memory is blocked");
  }

  private async block(reason: EpisodicBlockedReason, detail?: string): Promise<void> {
    if (this.closed || this.blocked) return;
    this.blocked = detail === undefined ? { reason } : { reason, detail };
    await this.saveState();
    this.diagnostic({ event: "episodic.node-blocked", level: "warning", message: "Episodic memory stopped its pump", reason });
    this.settleWaiters();
  }

  /**
   * Persist the memory's state, chained behind every earlier append and state
   * write and with its snapshot taken *inside* that step. Two concurrent savers
   * would otherwise both be in flight with snapshots taken at call time, and the
   * older one could land last: spend would go backwards, and a block written by
   * one path could be overwritten by another path's earlier, unblocked state.
   */
  private saveState(): Promise<void> {
    return this.enqueueAppend(() => this.store.saveState({
      version: EPISODIC_STORE_VERSION,
      generation: this.generation,
      cursor: this.sourceCursor,
      blocked: this.blocked,
      spend: this.budget.snapshot().used,
    }));
  }

  /** Every append is chained, so the durable order equals the request order and
   * a concurrent build can never interleave a line. */
  private appendCatalog(record: EpisodicMessageRecord): Promise<void> {
    return this.enqueueAppend(() => this.store.appendCatalog(record));
  }

  private appendNode(record: EpisodicNodeRecord | EpisodicInvalidationRecord): Promise<void> {
    return this.enqueueAppend(() => this.store.appendNode(record));
  }

  private enqueueAppend(operation: () => Promise<void>): Promise<void> {
    const next = this.appending.then(operation);
    this.appending = next.catch(() => {});
    return next;
  }

  private takeRevision(): number {
    const revision = this.revision;
    this.revision += 1;
    return revision;
  }

  /** A loaded store must be internally consistent; a live parent whose child is
   * missing or rebuilt is corruption, not something to guess at. */
  private assertConsistent(): void {
    for (const node of this.nodes.values()) {
      if (node.level === 0) {
        if (!this.messages.has(node.index)) throw new EpisodicMemoryError("invalid-store", `Episodic node ${nodeAddress(node.level, node.index)} has no message`);
        continue;
      }
      const span = 2 ** node.level;
      if ((node.index + 1) * span > this.messages.size) throw new EpisodicMemoryError("invalid-store", `Episodic node ${nodeAddress(node.level, node.index)} covers messages this memory does not hold`);
      const childA = this.nodes.get(nodeAddress(node.level - 1, node.index * 2));
      const childB = this.nodes.get(nodeAddress(node.level - 1, node.index * 2 + 1));
      if (!childA || !childB || !node.childRevisions
        || childA.revision !== node.childRevisions[0] || childB.revision !== node.childRevisions[1]) {
        throw new EpisodicMemoryError("invalid-store", `Episodic node ${nodeAddress(node.level, node.index)} is not consistent with its children`);
      }
    }
  }

  private assertOpen(): void {
    if (this.closed) throw new EpisodicMemoryError("closed", "Episodic memory was disposed");
  }
}

/** One view line's text: newlines flattened to single spaces (gist §5.1), and
 * the placeholder for a part whose node is not built. */
function viewLine(text: string | undefined): string {
  return text === undefined ? EPISODIC_PLACEHOLDER : text.replace(/\n+/gu, " ");
}
