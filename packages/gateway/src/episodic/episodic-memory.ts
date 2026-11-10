import { GatewayError } from "../errors.js";
import type { HomeMemoryEvidence, HomeMemoryView, HomeMemoryViewLine } from "../protocol/types.js";
import { HOME_MEMORY_PAGE_BYTES, HOME_MEMORY_DISPLAY_BYTES, encodeHomeMemoryCursor, homeMemoryLine, homeMemoryRevisionChanged, type HomeMemoryViewRequest } from "./home-memory-browser.js";
import type { AssistantMessage } from "../kernel/pi/ai.js";
import { AsyncMutex } from "../util/async-mutex.js";
import { EpisodicMemoryError } from "../errors.js";
import { EPISODIC_DEFAULTS, EPISODIC_INVALIDATION_CHUNK, EPISODIC_OMITTED_TEXT, EPISODIC_PLACEHOLDER, EPISODIC_SEARCH_HITS, EPISODIC_SEARCH_QUERY_CHARS, EPISODIC_SEARCH_SNIPPET_CHARS, EPISODIC_STATUS_PARTS, EPISODIC_STORE_VERSION, EPISODIC_TRIES, resolveLimits, type EpisodicBlocked, type EpisodicBlockedReason, type EpisodicCompactorRequest, type EpisodicDiagnostic, type EpisodicInvalidationRecord, type EpisodicLimits, type EpisodicMemoryDependencies, type EpisodicMemoryStatus, type EpisodicMessageRecord, type EpisodicNodeRecord, type EpisodicSourceCursor, type EpisodicStoreState, type EpisodicSummarizer, type EpisodicUsage, type EpisodicViewPartStatus } from "./episodic-contract.js";
import {
  EPISODIC_COMPACT_PROMPT, boundedSummary, classifyReply, classifyThrown, compactorRequest,
  emptyReplyDetail, leafStep, mergeStep, sizeFeedback, summarizerText, usageTokens, withFeedback,
} from "./episodic-compactor.js";
import { EpisodicSourceChangedError, episodicDigest } from "../kernel/session/canonical-reader.js";
import { type EpisodicSourceDelta } from "./episodic-projection.js";
import { EpisodicStore, type EpisodicStoreSnapshot } from "./episodic-store.js";
import {
  EPISODIC_MAX_LEVEL, decodeContextRuns, encodeNodeCode, foldViewSliced, freeNodeText, mergedFreeText, nodeAddress, rebalanceView,
  parseNodeAddress, placeholderBytes, snippetAround, utf8Bytes,
  type EpisodicViewPart,
} from "./episodic-tree.js";
import { tronWorkspacePath } from "../foundation/tron-home-layout.js";

class EpisodicBlockedSignal extends Error {
  constructor(readonly blocked: EpisodicBlocked) {
    super(blocked.detail ? `${blocked.reason}: ${blocked.detail}` : blocked.reason);
    this.name = "EpisodicBlockedSignal";
  }
}

class EpisodicCallTimeout extends Error {
  constructor(readonly boundMs: number) {
    super(`the compactor call exceeded its ${boundMs}ms bound`);
    this.name = "EpisodicCallTimeout";
  }
}

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

interface EpisodicSearchResult {
  lines: string[];
  matches: number;
  omitted: number;
  capped: number;
  from: number;
  to: number;
}

interface BuildStamp {
  generation: number;
  inputs: Array<{ address: string; revision: number }>;
  messageIndex?: number;
  messageRevision?: number;
}

export async function readEpisodicState(options: {
  workspace: import("../workspace/tron-workspace.js").TronWorkspace;
  sessionId: string;
}): Promise<EpisodicStoreState | undefined> {
  const store = new EpisodicStore(options.workspace, options.sessionId, EPISODIC_DEFAULTS.maxStoreLineBytes);
  return store.readState();
}

function sleepFor(ms: number, signal: AbortSignal): Promise<void> {
  if (signal.aborted) return Promise.reject(new EpisodicMemoryError("closed", "Episodic memory is closing"));
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      signal.removeEventListener("abort", onAbort);
      resolve();
    }, ms);
    const onAbort = () => {
      clearTimeout(timer);
      reject(new EpisodicMemoryError("closed", "Episodic memory is closing"));
    };
    signal.addEventListener("abort", onAbort, { once: true });
  });
}

type Draft<T extends { revision: number }> = Omit<T, "revision">;

export class EpisodicMemory {
  private static readonly openStores = new Set<string>();

  private readonly limits: EpisodicLimits;
  private readonly store: EpisodicStore;
  private readonly summarizer: EpisodicSummarizer;
  private spend = 0;
  private readonly usageSinceOpen: EpisodicUsage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };
  private readonly diagnostic: (record: EpisodicDiagnostic) => void;
  private readonly mutex = new AsyncMutex();
  private readonly abort = new AbortController();

  private readonly messages = new Map<number, EpisodicMessageRecord>();
  private readonly nodes = new Map<string, EpisodicNodeRecord>();
  private readonly entryIndex = new Map<string, number>();
  private liveBytes = 0;
  private readonly building = new Set<string>();
  private view: EpisodicViewPart[] = [];
  private revision = 1;
  private committedRevision = 0;
  private generation = 0;
  private sourceCursor: EpisodicSourceCursor | null = null;
  private blocked: EpisodicBlocked | null = null;
  private waiters: Waiter[] = [];
  private draining: Promise<void> | null = null;
  private appending: Promise<void> = Promise.resolve();
  private storeKey: string | undefined;
  private closed = false;
  private checkpointFailure: Error | undefined;

  private constructor(private readonly dependencies: EpisodicMemoryDependencies, limits: EpisodicLimits) {
    this.limits = limits;
    this.store = new EpisodicStore(dependencies.workspace, dependencies.sessionId, limits.maxStoreLineBytes);
    this.summarizer = dependencies.summarizer;
    this.diagnostic = dependencies.diagnostic ?? (() => {});
  }

  static async open(dependencies: EpisodicMemoryDependencies): Promise<EpisodicMemory> {
    const limits = resolveLimits(dependencies.limits);
    const descriptor = await dependencies.workspace.describe();
    if (!descriptor.available) throw new EpisodicMemoryError("unsafe-store", "Tron internal workspace is unavailable; episodic memory cannot be opened");
    const storeKey = tronWorkspacePath(descriptor.root, "state/episodic", dependencies.sessionId);
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
        await memory.store.cleanupOrphans();
      } catch (error) {
        if (error instanceof EpisodicMemoryError && (error.kind === "invalid-store" || error.kind === "unsafe-store")) {
          memory.diagnostic({ event: "episodic.store-refused", level: "error", message: "Episodic memory store was refused", reason: error.kind });
        }
        throw error;
      }
      for (const record of snapshot.messages.values()) memory.setMessage(record);
      for (const record of snapshot.nodes.values()) memory.setNode(record);
      for (const record of memory.messages.values()) memory.entryIndex.set(record.entryId, record.index);
      memory.revision = snapshot.highestRevision + 1;
      memory.committedRevision = snapshot.highestRevision;
      memory.generation = Math.max(snapshot.state?.generation ?? 0, snapshot.highestGeneration);
      if (snapshot.state) {
        memory.sourceCursor = snapshot.state.cursor;
        memory.blocked = snapshot.state.blocked;
        memory.spend = snapshot.state.spend;
      }
      if (snapshot.recoveredTornBytes > 0) {
        memory.diagnostic({
          event: "episodic.store-recovered", level: "warning",
          message: "Discarded a torn trailing episodic record that was never acknowledged",
          counts: { bytes: snapshot.recoveredTornBytes },
        });
      }
      memory.view = await foldViewSliced(memory.messages.size, limits.viewBytes, part => memory.partBytes(part), address => memory.nodes.has(address));
      await memory.repairOrphanedDependencies();
      memory.assertConsistent();
      await memory.repairCatalogMismatch();
      return memory;
    } catch (error) {
      EpisodicMemory.openStores.delete(storeKey);
      throw error;
    }
  }

  async entriesCommitted(sessionId: string): Promise<void> {
    await this.entriesIngested(sessionId);
    await this.drain();
    await this.checkpointIfNeeded();
  }

  async entriesIngested(sessionId: string, signal?: AbortSignal): Promise<void> {
    await this.ingestForRead(sessionId, signal);
    void this.drain().catch(() => {});
  }

  async ingestForRead(sessionId: string, signal?: AbortSignal): Promise<void> {
    this.assertOpen();
    if (sessionId !== this.dependencies.sessionId) throw new EpisodicMemoryError("invalid-request", "entriesCommitted names a different session");
    await this.mutex.run(async () => {
      if (this.blocked) return;
      await this.ingest();
    }, signal);
  }

  async whenReady(cut: number, options: { signal?: AbortSignal } = {}): Promise<void> {
    this.assertOpen();
    if (!Number.isSafeInteger(cut) || cut < 0) throw new EpisodicMemoryError("invalid-request", "whenReady cut must be a non-negative integer");
    const signal = options.signal;
    if (signal?.aborted) throw new EpisodicMemoryError("closed", "whenReady wait was cancelled");
    if (this.dependencies.isPaused?.()) throw new EpisodicMemoryError("paused", "Episodic memory is paused");
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

  async cutAtEntry(entryId: string | null): Promise<number | undefined> {
    this.assertOpen();
    if (entryId === null) return 0;
    const cursor = this.sourceCursor;
    if (!cursor) return undefined;
    try {
      let result = 0;
      let found: number | undefined;
      for await (const entry of this.dependencies.sessionSource.branchAtCursor(cursor, this.limits)) {
        const index = this.entryIndex.get(entry.id);
        if (index !== undefined) {
          if (this.messages.get(index)?.sessionId !== entry.sourceSessionId) return undefined;
          result = Math.max(result, index + 1);
        }
        if (entry.id === entryId) found = result;
      }
      return found;
    } catch { return undefined; }
  }

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
    const lines = parts.map(part => `${nodeAddress(part.level, part.index)}|${this.attributedViewLine(part.start, part.span, this.nodes.get(nodeAddress(part.level, part.index))?.text)}`);
    const text = lines.join("\n");
    return { text, lines: lines.length, bytes: utf8Bytes(text) };
  }

  async withBrowserRead<T>(read: () => Promise<T>, signal?: AbortSignal): Promise<T> {
    return this.mutex.run(read, signal);
  }

  browserRevision(): string {
    this.assertOpen();
    return episodicDigest(JSON.stringify([
      this.dependencies.sessionId, this.generation, this.committedRevision, this.sourceCursor,
      this.view.map(({ level, index, start, span }) => [level, index, start, span]),
    ]));
  }

  browserCursor(): EpisodicSourceCursor | null {
    this.assertOpen();
    return this.sourceCursor ? structuredClone(this.sourceCursor) : null;
  }

  assertBrowserEvidence(evidence: HomeMemoryEvidence): void {
    this.assertOpen();
    const message = this.messages.get(evidence.index);
    if (!message || message.sessionId !== evidence.sessionId || message.entryId !== evidence.entryId
      || message.sourceDigest !== evidence.sourceDigest) throw homeMemoryRevisionChanged();
  }

  browserView(request: HomeMemoryViewRequest): HomeMemoryView {
    this.assertOpen();
    const chapter = request.sessionId;
    const addresses = new Set(this.view.map(part => `${part.start}+${part.span}`));
    let individualFrom = this.messages.size;
    for (let index = this.view.length - 1; index >= 0; index -= 1) {
      const part = this.view[index]!;
      if (part.span !== 1) break;
      individualFrom = part.start;
    }
    const lineFor = (part: EpisodicViewPart): HomeMemoryViewLine => homeMemoryLine(part, this.messages, this.nodes, nodeAddress, {
      inCurrentView: addresses.has(`${part.start}+${part.span}`),
      startsIndividualMessages: part.span === 1 && part.start === individualFrom && individualFrom > 0,
    });
    const baseRevision = this.browserRevision();
    const revision = chapter === undefined ? baseRevision : episodicDigest(JSON.stringify([baseRevision, chapter]));
    if (request.cursor && request.cursor.revision !== revision) throw homeMemoryRevisionChanged();
    const matches = (index: number): boolean => chapter === undefined || this.messages.get(index)?.sessionId === chapter;
    const ranges: EpisodicViewPart[] = [];
    const add = (part: EpisodicViewPart): void => {
      if (part.start >= this.messages.size) return;
      const end = Math.min(part.start + part.span, this.messages.size);
      let inside = 0;
      for (let i = part.start; i < end; i += 1) if (matches(i)) inside += 1;
      if (inside === 0) return;
      if (inside === end - part.start) { ranges.push(part); return; }
      if (part.span === 1) return;
      const half = part.span / 2;
      add({ level: part.level - 1, index: part.index * 2, start: part.start, span: half });
      add({ level: part.level - 1, index: part.index * 2 + 1, start: part.start + half, span: half });
    };
    if (request.part) {
      const { start, span } = request.part;
      if (start + span > this.messages.size) throw new GatewayError("invalid_request", "Home memory part is past the catalog end");
      const level = Math.log2(span), index = start / span;
      const half = span / 2;
      const parts = [
        { level: level - 1, index: index * 2, start, span: half },
        { level: level - 1, index: index * 2 + 1, start: start + half, span: half },
      ];
      const lines = parts.map(lineFor);
      return { homeId: this.dependencies.sessionId, revision, totalMessages: this.messages.size, lines };
    }
    for (const part of this.view) add(part);
    ranges.reverse();
    const offset = request.cursor?.offset ?? 0;
    if (offset > ranges.length || request.cursor && offset === ranges.length) throw homeMemoryRevisionChanged();
    const totalMessages = chapter === undefined ? this.messages.size : [...this.messages.values()].filter(m => m.sessionId === chapter).length;
    const result: HomeMemoryView = { homeId: this.dependencies.sessionId, revision, totalMessages, lines: [] };
    let position = offset;
    let bytes = Buffer.byteLength(JSON.stringify(result)) + 1024;
    for (; position < ranges.length && result.lines.length < request.limit; position += 1) {
      const line = lineFor(ranges[position]!);
      const size = Buffer.byteLength(JSON.stringify(line)) + 1 + (line.item ? HOME_MEMORY_DISPLAY_BYTES : 0);
      if (bytes + size > HOME_MEMORY_PAGE_BYTES) break;
      bytes += size;
      result.lines.push(line);
    }
    if (!result.lines.length && position < ranges.length) throw new GatewayError("unsupported", "Home memory line exceeds the browser bound");
    if (position < ranges.length) result.nextCursor = encodeHomeMemoryCursor({ revision, offset: position, limit: request.limit, ...(chapter === undefined ? {} : { sessionId: chapter }) });
    return result;
  }

  recentSummaries(sessionIds: readonly string[], limit: number): Map<string, string[]> {
    this.assertOpen();
    const result = new Map(sessionIds.map(sessionId => [sessionId, [] as string[]]));
    const catalog = new Map<string, number[]>();
    for (const message of this.messages.values()) {
      if (!result.has(message.sessionId)) continue;
      const indices = catalog.get(message.sessionId) ?? [];
      indices.push(message.index);
      catalog.set(message.sessionId, indices);
    }
    for (const [sessionId, summaries] of result) {
      const indices = catalog.get(sessionId) ?? [];
      if (!indices.length) continue;
      const start = indices[0]!, end = indices.at(-1)! + 1;
      const sources: string[] = [];
      let cursor = start;
      while (cursor < end) {
        let chosen: { span: number; text: string } | undefined;
        for (let span = 2 ** EPISODIC_MAX_LEVEL; span >= 1; span /= 2) {
          if (cursor % span || cursor + span > end) continue;
          const node = this.nodes.get(nodeAddress(Math.log2(span), cursor / span));
          if (node) { chosen = { span, text: node.text }; break; }
        }
        if (chosen) { sources.push(chosen.text); cursor += chosen.span; }
        else cursor += 1;
      }
      summaries.push(...sources.reverse().slice(0, limit));
    }
    return result;
  }

  zoomLines(id: number, n: number): string[] | undefined {
    this.assertOpen();
    if (!Number.isSafeInteger(id) || !Number.isSafeInteger(n) || n < 1) return undefined;
    const level = Math.log2(n);
    if (level % 1 !== 0 || level > EPISODIC_MAX_LEVEL) return undefined;
    if (id < 0 || id % n !== 0 || id + n > this.messages.size) return undefined;
    if (n === 1) {
      const message = this.messages.get(id);
      if (!message) return undefined;
      return [`${id}+0|${message.kind}: ${message.text}`];
    }
    const half = n / 2;
    return [id, id + half].map((start) => {
      const node = this.nodes.get(nodeAddress(level - 1, start / half));
      return `${start}+${half}|${node ? this.attributedViewLine(start, half, node.text) : EPISODIC_PLACEHOLDER}`;
    });
  }

  entryTimestamp(id: number): string | undefined {
    this.assertOpen();
    return this.messages.get(id)?.timestamp;
  }

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
      if (message.omitted) { omitted += 1; continue; }
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

  async resumeIngested(): Promise<void> {
    this.assertOpen();
    await this.mutex.run(async () => {
      await this.repairOrphanedDependencies();
      await this.repairCatalogMismatch();
      if (this.blocked) {
        this.blocked = null;
        await this.saveState();
      }
      await this.ingest();
    });
    void this.drain().catch(() => {});
  }

  notePause(): void { this.settleWaiters(); }

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
      tokens: { used: this.spend, sinceOpen: { ...this.usageSinceOpen } },
    };
  }

  async dispose(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    this.abort.abort();
    await this.mutex.run(async () => {});
    await this.draining?.catch(() => {});
    if (this.storeKey) EpisodicMemory.openStores.delete(this.storeKey);
    for (const waiter of this.waiters.splice(0)) {
      if (waiter.onAbort && waiter.signal) waiter.signal.removeEventListener("abort", waiter.onAbort);
      waiter.reject(new EpisodicMemoryError("closed", "Episodic memory was disposed"));
    }
  }

  private async ingest(): Promise<void> {
    try {
      for await (const delta of this.dependencies.sessionSource.read(this.sourceCursor, this.limits)) {
        await this.ingestCut(delta);
        if (this.blocked || this.closed) return;
      }
    } catch (error) {
      if (error instanceof EpisodicSourceChangedError) {
        this.diagnostic({
          event: "episodic.source-read-retried", level: "warning",
          message: "Canonical session changed during a failed read; ingestion will retry on the next source update",
        });
        return;
      }
      if (error instanceof EpisodicMemoryError && error.kind === "source") {
        await this.block("source-unavailable", error.message);
        return;
      }
      throw error;
    }
  }

  private async ingestCut(cut: EpisodicSourceDelta): Promise<void> {
    if (cut.sessionId !== this.dependencies.sessionId) {
      await this.block("source-unavailable", "Canonical source belongs to another memory owner");
      return;
    }
    if (this.sourceCursor && cut.incremental
      && cut.cursor.completeBytes === this.sourceCursor.completeBytes && cut.cursor.leafEntryId === this.sourceCursor.leafEntryId) {
      this.sourceCursor = cut.cursor;
      await this.saveState();
      return;
    }

    const projection = cut.projected;
    const changed: number[] = [];
    const seen = new Set<string>();
    try {
      for (const message of projection) {
        seen.add(message.entryId);
        const existing = this.entryIndex.get(message.entryId);
        if (existing === undefined) {
          const index = this.messages.size;
          await this.appendCatalog({ index, ...message, sessionId: message.sourceSessionId });
          this.entryIndex.set(message.entryId, index);
          this.view.push({ level: 0, index, start: index, span: 1 });
          this.fit();
          continue;
        }
        const current = this.messages.get(existing);
        if (current && current.sessionId !== message.sourceSessionId) {
          await this.block("source-unavailable", "Canonical entry ID belongs to another physical chapter");
          return;
        }
        const sameContent = current?.text === message.text && current.omitted === message.omitted && current.kind === message.kind;
        if (sameContent && current.sourceDigest === message.sourceDigest && current.timestamp === message.timestamp
          && JSON.stringify(current.omissions) === JSON.stringify(message.omissions)) continue;
        await this.appendCatalog({ index: existing, ...message, sessionId: message.sourceSessionId });
        if (!sameContent) changed.push(existing);
      }

      if (!cut.incremental) {
        for (const [entryId, index] of this.entryIndex) {
          if (seen.has(entryId)) continue;
          const current = this.messages.get(index);
          if (!current || current.omitted || (cut.scopeSessionId && current.sessionId !== cut.scopeSessionId)) continue;
          const { revision: _superseded, ...draft } = current;
          await this.appendCatalog({
            ...draft,
            text: EPISODIC_OMITTED_TEXT,
            omitted: true,
            projectedDigest: episodicDigest(EPISODIC_OMITTED_TEXT),
            omissions: [...new Set([...current.omissions, "off-branch"])],
          });
          changed.push(index);
        }
      }

      if (changed.length > 0) await this.invalidate(changed);
    } catch (error) {
      if (error instanceof EpisodicMemoryError && (error.kind === "invalid-store" || error.kind === "unsafe-store")) {
        await this.block("permanent-failure", error.message);
        return;
      }
      throw error;
    }
    this.sourceCursor = cut.cursor;
    await this.saveState();
  }

  private async checkpointIfNeeded(): Promise<void> {
    await this.mutex.run(async () => {
      if (this.closed) return;
      if (await this.store.shouldCheckpoint(this.liveBytes)) {
        await this.enqueueAppend(() => this.publishCheckpoint());
      }
    });
  }

  private async publishCheckpoint(): Promise<void> {
    try {
      await this.store.checkpoint({ messages: this.messages.values(), nodes: this.nodes.values(), state: this.currentStoreState(), watermark: this.committedRevision });
    } catch (error) {
      this.checkpointFailure = error instanceof Error ? error : new Error("Episodic checkpoint failed");
      throw this.checkpointFailure;
    }
  }

  private currentStoreState(): EpisodicStoreState {
    return { version: EPISODIC_STORE_VERSION, generation: this.generation, cursor: this.sourceCursor, blocked: this.blocked, spend: this.spend };
  }

  private setMessage(record: EpisodicMessageRecord): void {
    const previous = this.messages.get(record.index);
    if (previous) this.liveBytes -= Buffer.byteLength(`${JSON.stringify(previous)}\n`);
    this.messages.set(record.index, record);
    this.liveBytes += Buffer.byteLength(`${JSON.stringify(record)}\n`);
  }

  private attributedViewLine(start: number, span: number, text: string | undefined): string {
    if (text === undefined) return EPISODIC_PLACEHOLDER;
    const kind = span === 1 ? this.messages.get(start)?.kind : "summary";
    return `${kind ?? "summary"}: ${span === 1 ? viewLine(text) : text.replace(/\n+/gu, " ")}`;
  }

  private setNode(record: EpisodicNodeRecord): void {
    const address = nodeAddress(record.level, record.index);
    const previous = this.nodes.get(address);
    if (previous) this.liveBytes -= Buffer.byteLength(`${JSON.stringify(previous)}\n`);
    this.nodes.set(address, record);
    this.liveBytes += Buffer.byteLength(`${JSON.stringify(record)}\n`);
  }

  private deleteNode(address: string): void {
    const previous = this.nodes.get(address);
    if (!previous) return;
    this.nodes.delete(address);
    this.liveBytes -= Buffer.byteLength(`${JSON.stringify(previous)}\n`);
  }

  private async repairOrphanedDependencies(): Promise<void> {
    const orphaned = new Set<string>();
    for (const [address, node] of this.nodes) {
      if (decodeContextRuns(node.contextRuns).some(dependency => !this.nodes.has(dependency))) orphaned.add(address);
      if (node.level > 0) {
        const childA = this.nodes.get(nodeAddress(node.level - 1, node.index * 2));
        const childB = this.nodes.get(nodeAddress(node.level - 1, node.index * 2 + 1));
        if (!childA || !childB || !node.childRevisions
          || childA.revision !== node.childRevisions[0] || childB.revision !== node.childRevisions[1]) orphaned.add(address);
      }
    }
    if (orphaned.size > 0) await this.invalidateNodes(orphaned);
  }

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

  private async invalidate(changedIndices: readonly number[]): Promise<void> {
    await this.invalidateNodes(changedIndices.map(index => nodeAddress(0, index)));
  }

  private async invalidateNodes(seeds: Iterable<string>): Promise<void> {
    await this.enqueueAppend(async () => {
      const invalid = new Set<string>();
      const ancestorsOf = (address: string): string[] => {
        const parsed = parseNodeAddress(address);
        if (!parsed) return [];
        const ancestors: string[] = [];
        for (let level = parsed.level, i = parsed.index; level <= 63; level += 1, i = Math.floor(i / 2)) {
          const ancestor = nodeAddress(level, i);
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
      for (const seed of seeds) {
        if (this.nodes.has(seed)) add(seed);
        for (const ancestor of ancestorsOf(seed)) add(ancestor);
      }
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
          revision: this.revision++, generation, part, parts,
          nodes: chunk.map(address => {
            const parsed = parseNodeAddress(address)!;
            return encodeNodeCode(parsed.level, parsed.index);
          }).join(" "),
        };
        await this.store.appendNode(record);
        this.committedRevision = record.revision;
        for (const address of chunk) this.deleteNode(address);
        this.expandInvalidatedParts(new Set(chunk));
        this.fit();
      }
      this.diagnostic({
        event: "episodic.source-invalidated", level: "info",
        message: "A source revision invalidated summarized nodes",
        counts: { invalidated: invalid.size, generation },
      });
    });
  }

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

  private async drain(): Promise<void> {
    if (this.closed || this.blocked || this.dependencies.isPaused?.()) return;
    const draining = this.draining;
    if (draining) {
      await draining;
      if (!this.closed && !this.blocked && !this.dependencies.isPaused?.() && this.nextStartable()) await this.drain();
      return;
    }
    this.draining = (async () => {
      try {
        await this.pump();
      } catch (error) {
        try {
          await this.block("permanent-failure", error instanceof Error ? error.message : String(error));
        } finally {
          this.settleWaiters();
        }
      }
    })().finally(() => { this.draining = null; });
    await this.draining;
  }

  private async pump(): Promise<void> {
    const running = new Map<string, Promise<void>>();
    try {
      for (;;) {
        if (this.closed || this.blocked) break;
        while (!this.dependencies.isPaused?.() && running.size < this.limits.jobs) {
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

  private nextStartable(): { level: number; index: number } | undefined {
    const count = this.messages.size;
    const first = this.firstUnbuilt();
    const needsMerge = this.view.reduce((bytes, part) => bytes + this.partBytes(part).bytes, 0) > this.limits.viewBytes;
    for (let level = 0; 2 ** level <= count; level += 1) {
      const span = 2 ** level;
      for (let index = 0; (index + 1) * span <= count; index += 1) {
        const address = nodeAddress(level, index);
        if (this.nodes.has(address) || this.building.has(address)) continue;
        const end = level === 0 ? index : (index + 1) * span;
        if (end > first) continue;
        if (level > 0) {
          const childA = this.nodes.get(nodeAddress(level - 1, index * 2));
          const childB = this.nodes.get(nodeAddress(level - 1, index * 2 + 1));
          if (!childA || !childB) continue;
          if (!needsMerge && mergedFreeText(childA.text, childB.text, this.limits.nodeBytes) === undefined) continue;
        }
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
        await this.block("permanent-failure", `node ${address} has no source to summarize`);
        return;
      }
      const draft = await this.composeNode(level, index, stamp);
      if (!draft || this.stale(stamp)) return;
      await this.enqueueAppend(async () => {
        if (this.stale(stamp)) return;
        const record: EpisodicNodeRecord = { revision: this.revision++, ...draft };
        await this.store.appendNode(record);
        this.committedRevision = record.revision;
        this.setNode(record);
        this.fit();
      });
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

  private stale(stamp: BuildStamp): boolean {
    if (this.closed || this.blocked) return true;
    if (this.generation !== stamp.generation) return true;
    for (const input of stamp.inputs) if (this.nodes.get(input.address)?.revision !== input.revision) return true;
    if (stamp.messageIndex !== undefined && this.messages.get(stamp.messageIndex)?.revision !== stamp.messageRevision) return true;
    return false;
  }

  private async composeNode(level: number, index: number, stamp: BuildStamp): Promise<Draft<EpisodicNodeRecord> | undefined> {
    if (level === 0) {
      const message = this.messages.get(index);
      if (!message) return undefined;
      const source = `${message.kind}: ${message.text}`;
      if (message.omitted) {
        return this.freeNode(level, index, `${message.kind}: ${EPISODIC_OMITTED_TEXT}`, episodicDigest(source));
      }
      const free = freeNodeText(message.kind, message.text, this.limits.nodeBytes);
      if (free) return this.freeNode(level, index, free, episodicDigest(source));
      const text = await this.compact(leafStep(message.kind, message.text, this.limits.nodeBytes), stamp);
      return this.summaryNode(level, index, text, episodicDigest(source));
    }
    const childA = this.nodes.get(nodeAddress(level - 1, index * 2));
    const childB = this.nodes.get(nodeAddress(level - 1, index * 2 + 1));
    if (!childA || !childB) return undefined;
    const source = `${childA.text}\n${childB.text}`;
    const childRevisions: [number, number] = [childA.revision, childB.revision];
    const free = mergedFreeText(childA.text, childB.text, this.limits.nodeBytes);
    if (free) return { ...this.freeNode(level, index, free, episodicDigest(source)), childRevisions };
    const text = await this.compact(mergeStep(childA.text, childB.text, this.limits.nodeBytes), stamp);
    return { ...this.summaryNode(level, index, text, episodicDigest(source)), childRevisions };
  }

  private freeNode(level: number, index: number, text: string, sourceDigest: string): Draft<EpisodicNodeRecord> {
    return { level, index, kind: "free", text, contextRuns: [], textDigest: episodicDigest(text), sourceDigest };
  }

  private summaryNode(level: number, index: number, text: string, sourceDigest: string): Draft<EpisodicNodeRecord> {
    return { level, index, kind: "summary", text, contextRuns: [], textDigest: episodicDigest(text), sourceDigest };
  }

  private async compact(step: string, stamp: BuildStamp): Promise<string> {
    let request = compactorRequest(EPISODIC_COMPACT_PROMPT, step, this.abort.signal, `tron-episodic:${this.dependencies.sessionId}`);
    const tries: string[] = [];
    for (let attempt = 0; attempt < EPISODIC_TRIES; attempt += 1) {
      const reply = await this.compactCall(request, stamp);
      tries.push(reply);
      if (utf8Bytes(reply) <= this.limits.nodeBytes || attempt + 1 >= EPISODIC_TRIES) break;
      request = withFeedback(request, reply, sizeFeedback(reply, this.limits.nodeBytes));
    }
    const shortest = tries.reduce((best, line) => utf8Bytes(line) < utf8Bytes(best) ? line : best, tries[0]!);
    return boundedSummary(shortest, this.limits.nodeBytes);
  }

  private async compactCall(request: EpisodicCompactorRequest, stamp: BuildStamp): Promise<string> {
    for (let attempt = 0; ; attempt += 1) {
      if (this.stale(stamp)) throw new EpisodicClosedSignal();
      let message: AssistantMessage;
      try {
        message = await this.summarizerWithinBound(request);
      } catch (error) {
        if (this.closed || error instanceof EpisodicClosedSignal) throw new EpisodicClosedSignal();
        const verdict = error instanceof EpisodicCallTimeout ? "transient" : classifyThrown(error);
        const detail = error instanceof Error ? error.message : "the compactor call failed";
        if (verdict === "permanent") throw new EpisodicBlockedSignal({ reason: "permanent-failure", detail });
        if (verdict === "usage-limit") throw new EpisodicBlockedSignal({ reason: "usage-limit", detail });
        if (attempt >= this.limits.maxRetries) throw new EpisodicBlockedSignal({ reason: "retries-exhausted", detail });
        await this.wait(this.limits.retryMs);
        continue;
      }
      this.spend += usageTokens(message.usage);
      this.usageSinceOpen.input += message.usage?.input ?? 0;
      this.usageSinceOpen.output += message.usage?.output ?? 0;
      this.usageSinceOpen.cacheRead += message.usage?.cacheRead ?? 0;
      this.usageSinceOpen.cacheWrite += message.usage?.cacheWrite ?? 0;
      await this.saveState();
      const text = summarizerText(message);
      const verdict = classifyReply(message);
      if (verdict === "ok") return text;
      if (verdict === "permanent") {
        throw new EpisodicBlockedSignal({ reason: "permanent-failure", detail: message.errorMessage ?? emptyReplyDetail(message) });
      }
      if (verdict === "usage-limit") throw new EpisodicBlockedSignal({ reason: "usage-limit", detail: message.errorMessage ?? "the compactor's provider reported a usage limit" });
      if (attempt >= this.limits.maxRetries) {
        throw new EpisodicBlockedSignal({ reason: "retries-exhausted", detail: message.errorMessage ?? "the compactor call kept failing" });
      }
      await this.wait(this.limits.retryMs);
    }
  }

  private async summarizerWithinBound(request: EpisodicCompactorRequest): Promise<AssistantMessage> {
    const bound = this.limits.compactorTimeoutMs;
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
      await sleepFor(ms, this.abort.signal);
    } catch {
      throw new EpisodicClosedSignal();
    }
    if (this.closed) throw new EpisodicClosedSignal();
  }

  private fit(): void {
    rebalanceView(this.view, this.messages.size, this.limits.viewBytes, part => this.partBytes(part), address => this.nodes.has(address));
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
      if (this.dependencies.isPaused?.()) {
        if (waiter.onAbort && waiter.signal) waiter.signal.removeEventListener("abort", waiter.onAbort);
        waiter.reject(new EpisodicMemoryError("paused", "Episodic memory is paused"));
        continue;
      }
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

  private saveState(): Promise<void> {
    return this.enqueueAppend(() => this.store.saveState({
      version: EPISODIC_STORE_VERSION,
      generation: this.generation,
      cursor: this.sourceCursor,
      blocked: this.blocked,
      spend: this.spend,
    })).catch(error => {
      if (error instanceof EpisodicMemoryError && error.kind === "invalid-store") {
        this.blocked = { reason: "permanent-failure", detail: error.message };
        this.diagnostic({ event: "episodic.node-blocked", level: "warning", message: "Episodic state publication was refused", reason: "permanent-failure" });
        this.settleWaiters();
      }
      throw error;
    });
  }

  private appendCatalog(draft: Draft<EpisodicMessageRecord>): Promise<EpisodicMessageRecord> {
    return this.enqueueAppend(async () => {
      const record: EpisodicMessageRecord = { revision: this.revision++, ...draft };
      await this.store.appendCatalog(record);
      this.committedRevision = record.revision;
      this.setMessage(record);
      return record;
    });
  }

  private enqueueAppend<T>(operation: () => Promise<T>): Promise<T> {
    const next = this.appending.then(() => {
      if (this.checkpointFailure) throw new EpisodicMemoryError("invalid-store", "Episodic checkpoint failed; reopen is required before further writes");
      return operation();
    });
    this.appending = next.then(() => undefined, () => undefined);
    return next;
  }

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

function viewLine(text: string | undefined): string {
  return text === undefined ? EPISODIC_PLACEHOLDER : text.replace(/^(?:user|talk|echo|event|assistant|tool):\s/iu, "").replace(/\n+/gu, " ");
}
