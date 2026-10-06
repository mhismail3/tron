import type { AssistantMessage } from "@earendil-works/pi-ai";
import {
  EpisodicMemoryError, EPISODIC_OMITTED_TEXT, EPISODIC_PLACEHOLDER, EPISODIC_STATUS_PARTS, EPISODIC_STORE_VERSION,
  defaultSleep, resolveLimits,
  type EpisodicBlocked, type EpisodicBlockedReason, type EpisodicCompactorRequest, type EpisodicDiagnostic,
  type EpisodicInvalidationRecord, type EpisodicLimits, type EpisodicMemoryDependencies, type EpisodicMemoryStatus,
  type EpisodicMessageRecord, type EpisodicNodeRecord, type EpisodicSummarizer, type EpisodicTokenBudget,
  type EpisodicViewPartStatus,
} from "./episodic-contract.js";
import {
  EPISODIC_COMPACT_PROMPT, classifyReply, compactorRequest, contextBlock, createModelRuntimeSummarizer,
  estimateCompactorTokens, leafStep, mergeStep, sizeFeedback, summarizerText, withFeedback,
} from "./episodic-compactor.js";
import { projectBranch, readCanonicalSession, episodicDigest, type EpisodicCanonicalCut } from "./episodic-source.js";
import { EpisodicStore, type EpisodicStoreSnapshot } from "./episodic-store.js";
import {
  fitView, foldView, freeNodeText, mergedFreeText, nodeAddress, parseNodeAddress, placeholderBytes, utf8Bytes, viewLineTexts,
  type EpisodicViewPart,
} from "./episodic-tree.js";

/*
 * The owner of one source session's memory: the projected catalog, the binary
 * summary tree, the view, and the pump that builds nodes (departures 3 and 5 of
 * the brief). It never subscribes to a session; `entriesCommitted` re-reads the
 * canonical file after its cursor and drains the pump, and `whenReady` is what a
 * request layer waits on.
 */

/** The pump stops on this signal: the memory is blocked and `resume()` restarts
 * it. It never escapes to a caller. */
class EpisodicBlockedSignal extends Error {
  constructor(readonly blocked: EpisodicBlocked) {
    super(blocked.detail ? `${blocked.reason}: ${blocked.detail}` : blocked.reason);
    this.name = "EpisodicBlockedSignal";
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

export class EpisodicMemory {
  private readonly limits: EpisodicLimits;
  private readonly store: EpisodicStore;
  private readonly summarizer: EpisodicSummarizer;
  private readonly budget: EpisodicTokenBudget;
  private readonly sleep: (ms: number, signal: AbortSignal) => Promise<void>;
  private readonly diagnostic: (record: EpisodicDiagnostic) => void;
  private readonly abort = new AbortController();

  private readonly messages = new Map<number, EpisodicMessageRecord>();
  private readonly nodes = new Map<string, EpisodicNodeRecord>();
  private readonly entryIndex = new Map<string, number>();
  private readonly building = new Set<string>();
  private view: EpisodicViewPart[] = [];
  private revision = 1;
  private generation = 0;
  private cursor: { completeBytes: number; leafEntryId: string | null } | null = null;
  private blocked: EpisodicBlocked | null = null;
  private waiters: Waiter[] = [];
  private draining: Promise<void> | null = null;
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
   * catalog and nodes, replay them, and fold the view from message 0. */
  static async open(dependencies: EpisodicMemoryDependencies): Promise<EpisodicMemory> {
    const limits = resolveLimits(dependencies.limits);
    const memory = new EpisodicMemory(dependencies, limits);
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
    memory.revision = memory.highestRevision(snapshot) + 1;
    if (snapshot.state) {
      memory.generation = snapshot.state.generation;
      memory.cursor = snapshot.state.cursor;
      memory.blocked = snapshot.state.blocked;
    }
    if (snapshot.recoveredTornBytes > 0) {
      memory.diagnostic({
        event: "episodic.store-recovered", level: "warning",
        message: "Discarded a torn trailing episodic record that was never acknowledged",
        counts: { bytes: snapshot.recoveredTornBytes },
      });
    }
    memory.assertConsistent();
    memory.view = foldView(memory.messages.size, limits.viewBytes, part => memory.partBytes(part), address => memory.nodes.has(address));
    return memory;
  }

  /** Re-read the canonical session, ingest what the cursor has not seen, and
   * drain the pump. A source read failure blocks with `source-unavailable`. */
  async entriesCommitted(sessionId: string): Promise<void> {
    this.assertOpen();
    if (sessionId !== this.dependencies.sessionId) throw new EpisodicMemoryError("invalid-request", "entriesCommitted names a different session");
    if (this.blocked) return;
    await this.ingest();
    await this.drain();
  }

  /** Resolves when every part of the view covering messages before `cut` is a
   * built summary (gist §6). The view is soft-budgeted, so this is not a hard
   * window check. A blocked memory rejects instead of waiting forever. */
  async whenReady(cut: number, options: { signal?: AbortSignal } = {}): Promise<void> {
    this.assertOpen();
    if (!Number.isSafeInteger(cut) || cut < 0) throw new EpisodicMemoryError("invalid-request", "whenReady cut must be a non-negative integer");
    if (this.blocked) throw this.blockedError();
    if (this.viewReady(cut)) return;
    const signal = options.signal;
    return new Promise<void>((resolve, reject) => {
      const waiter: Waiter = { cut, resolve, reject, ...(signal ? { signal } : {}) };
      if (signal) {
        waiter.onAbort = () => { this.removeWaiter(waiter); reject(new EpisodicMemoryError("closed", "whenReady wait was cancelled")); };
        signal.addEventListener("abort", waiter.onAbort, { once: true });
      }
      this.waiters.push(waiter);
    });
  }

  /** Clear the blocked state and restart the pump (departure 5). The cause must
   * have been fixed by the caller: a larger budget, a reachable source. */
  async resume(): Promise<void> {
    this.assertOpen();
    if (this.blocked) {
      this.blocked = null;
      await this.saveState();
      await this.ingest();
    }
    await this.drain();
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
    await this.draining?.catch(() => {});
    for (const waiter of this.waiters.splice(0)) {
      if (waiter.onAbort && waiter.signal) waiter.signal.removeEventListener("abort", waiter.onAbort);
      waiter.reject(new EpisodicMemoryError("closed", "Episodic memory was disposed"));
    }
  }

  // ---- ingestion -----------------------------------------------------------------

  private async ingest(): Promise<void> {
    let cut: EpisodicCanonicalCut;
    try {
      cut = await readCanonicalSession({ path: this.dependencies.sessionFile, sessionId: this.dependencies.sessionId, maxLineBytes: this.limits.maxSourceLineBytes });
    } catch (error) {
      if (error instanceof EpisodicMemoryError && error.kind === "source") {
        await this.block("source-unavailable", error.message);
        return;
      }
      throw error;
    }
    if (this.cursor && this.cursor.completeBytes === cut.completeBytes && this.cursor.leafEntryId === cut.leafEntryId) return;

    const projection = projectBranch(cut, this.limits);
    const changed: number[] = [];
    const seen = new Set<string>();
    for (const message of projection) {
      seen.add(message.entryId);
      const existing = this.entryIndex.get(message.entryId);
      if (existing === undefined) {
        const index = this.messages.size;
        this.entryIndex.set(message.entryId, index);
        const record: EpisodicMessageRecord = { revision: this.takeRevision(), index, ...message, sessionId: this.dependencies.sessionId };
        await this.store.appendCatalog(record);
        this.messages.set(index, record);
        // A new message appends one part to the view; nothing is invalidated.
        this.view.push({ level: 0, index, start: index, span: 1 });
        this.fit();
        continue;
      }
      const current = this.messages.get(existing);
      if (current && current.text === message.text && current.omitted === message.omitted && current.kind === message.kind) continue;
      const record: EpisodicMessageRecord = { revision: this.takeRevision(), index: existing, ...message, sessionId: this.dependencies.sessionId };
      await this.store.appendCatalog(record);
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
      await this.store.appendCatalog(record);
      this.messages.set(index, record);
      changed.push(index);
    }

    if (changed.length > 0) await this.invalidate(changed);
    this.cursor = { completeBytes: cut.completeBytes, leafEntryId: cut.leafEntryId };
    await this.saveState();
  }

  /** Invalidate exactly the affected leaves, their ancestors, and every node
   * whose recorded summarizer context included any invalidated node,
   * transitively (departure 3). A node added by the closure brings its own
   * ancestors with it: a parent stands in for its children, so a revoked child
   * under a live parent would be an inconsistent store. */
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
      for (const dependency of node.contextDependencies) {
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
    const record: EpisodicInvalidationRecord = { revision: this.takeRevision(), generation: this.generation, addresses: [...invalid].sort() };
    // Durable before use: a crash between revoking and rebuilding must not leave
    // a revoked child under a live parent.
    await this.store.appendNode(record);
    for (const address of invalid) this.nodes.delete(address);
    this.expandInvalidatedParts(invalid);
    this.fit();
    this.diagnostic({
      event: "episodic.source-invalidated", level: "info",
      message: "A source revision invalidated summarized nodes",
      counts: { invalidated: invalid.size, generation: this.generation },
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
      this.draining = this.drainLoop().finally(() => { this.draining = null; });
    }
    await this.draining;
  }

  private async drainLoop(): Promise<void> {
    try {
      while (!this.closed && !this.blocked) {
        const batch = this.startableNodes();
        if (batch.length === 0) break;
        await Promise.all(batch.map(node => this.buildNode(node.level, node.index)));
        this.settleWaiters();
      }
    } finally {
      // One fit at quiescence, with the drained node set: the view is then a
      // function of (message count, built nodes) at this point, not of the order
      // builds happened to finish in.
      this.fit();
      this.settleWaiters();
    }
  }

  /** Rule 3 of gist §4.1: a node builds only when its whole context is
   * summarized (`end <= first(view)`), which is what keeps leaves in order. */
  private startableNodes(): Array<{ level: number; index: number }> {
    const count = this.messages.size;
    const first = this.firstUnbuilt();
    const batch: Array<{ level: number; index: number }> = [];
    for (let level = 0; 2 ** level <= count; level += 1) {
      const span = 2 ** level;
      for (let index = 0; (index + 1) * span <= count; index += 1) {
        if (batch.length >= this.limits.jobs) return batch;
        const address = nodeAddress(level, index);
        if (this.nodes.has(address) || this.building.has(address)) continue;
        const end = level === 0 ? index : (index + 1) * span;
        if (end > first) continue;
        if (level > 0 && (!this.nodes.has(nodeAddress(level - 1, index * 2)) || !this.nodes.has(nodeAddress(level - 1, index * 2 + 1)))) continue;
        batch.push({ level, index });
      }
    }
    return batch;
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
      const record = await this.composeNode(level, index);
      if (!record) return;
      // Durable before use: the record is written and fsynced, then published.
      await this.store.appendNode(record);
      this.nodes.set(address, record);
    } catch (error) {
      if (error instanceof EpisodicBlockedSignal) await this.block(error.blocked.reason, error.blocked.detail);
      else if (error instanceof EpisodicClosedSignal) return;
      else throw error;
    } finally {
      this.building.delete(address);
    }
  }

  private async composeNode(level: number, index: number): Promise<EpisodicNodeRecord | undefined> {
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
      const lines = this.contextLines(index);
      const text = await this.compact(lines, leafStep(message.kind, message.text, this.limits.nodeBytes));
      return this.summaryNode(level, index, text, lines, episodicDigest(source));
    }
    const childA = this.nodes.get(nodeAddress(level - 1, index * 2));
    const childB = this.nodes.get(nodeAddress(level - 1, index * 2 + 1));
    if (!childA || !childB) return undefined;
    const source = `${childA.text}\n${childB.text}`;
    const childRevisions: [number, number] = [childA.revision, childB.revision];
    const free = mergedFreeText(childA.text, childB.text, this.limits.nodeBytes);
    if (free) return { ...this.freeNode(level, index, free, episodicDigest(source)), childRevisions };
    const lines = this.contextLines((index + 1) * span);
    const text = await this.compact(lines, mergeStep(childA.text, childB.text, this.limits.nodeBytes));
    return { ...this.summaryNode(level, index, text, lines, episodicDigest(source)), childRevisions };
  }

  private freeNode(level: number, index: number, text: string, sourceDigest: string): EpisodicNodeRecord {
    return { revision: this.takeRevision(), level, index, kind: "free", text, contextDependencies: [], textDigest: episodicDigest(text), sourceDigest };
  }

  private summaryNode(level: number, index: number, text: string, lines: readonly { address: string }[], sourceDigest: string): EpisodicNodeRecord {
    return {
      revision: this.takeRevision(), level, index, kind: "summary", text,
      contextDependencies: lines.map(line => line.address), textDigest: episodicDigest(text), sourceDigest,
    };
  }

  /** The context block's lines: the view up to the node's end, bare, no ids. */
  private contextLines(end: number): Array<{ address: string; text: string }> {
    return viewLineTexts(this.view, end, part => this.nodes.get(nodeAddress(part.level, part.index))?.text);
  }

  // ---- one compactor call, the size loop, retries and the budget ---------------

  private async compact(lines: readonly { text: string }[], step: string): Promise<string> {
    let request = compactorRequest(EPISODIC_COMPACT_PROMPT, contextBlock(lines.map(line => line.text)), step, this.abort.signal);
    const tries: string[] = [];
    for (let attempt = 0; attempt < this.limits.tries; attempt += 1) {
      const reply = await this.compactCall(request);
      tries.push(reply);
      if (utf8Bytes(reply) <= this.limits.nodeBytes || attempt + 1 >= this.limits.tries) break;
      request = withFeedback(request, reply, sizeFeedback(reply, this.limits.nodeBytes));
    }
    // Keep the shortest try (gist §4.3): a stubborn node keeps a line a few
    // bytes over, which is fine because the view measures real sizes.
    return tries.reduce((shortest, line) => utf8Bytes(line) < utf8Bytes(shortest) ? line : shortest, tries[0]!);
  }

  private async compactCall(request: EpisodicCompactorRequest): Promise<string> {
    for (let attempt = 0; ; attempt += 1) {
      const estimate = estimateCompactorTokens(request);
      if (!this.budget.reserve(estimate)) {
        throw new EpisodicBlockedSignal({ reason: "budget-exhausted", detail: `A compactor call estimated at ${estimate} tokens does not fit the remaining budget` });
      }
      let message: AssistantMessage;
      try {
        message = await this.summarizer(request);
      } catch (error) {
        this.budget.settle(estimate, 0);
        if (this.closed || error instanceof EpisodicClosedSignal) throw new EpisodicClosedSignal();
        if (attempt >= this.limits.maxRetries) {
          throw new EpisodicBlockedSignal({ reason: "retries-exhausted", detail: error instanceof Error ? error.message : "the compactor call failed" });
        }
        await this.wait(this.limits.retryMs);
        continue;
      }
      const usage = message.usage;
      this.budget.settle(estimate, (usage?.input ?? 0) + (usage?.output ?? 0));
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

  private async saveState(): Promise<void> {
    await this.store.saveState({ version: EPISODIC_STORE_VERSION, generation: this.generation, cursor: this.cursor, blocked: this.blocked });
  }

  private takeRevision(): number {
    const revision = this.revision;
    this.revision += 1;
    return revision;
  }

  private highestRevision(snapshot: EpisodicStoreSnapshot): number {
    let highest = 0;
    for (const record of [...snapshot.messages, ...snapshot.nodes]) if (record.revision > highest) highest = record.revision;
    return highest;
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
