import { randomUUID } from "node:crypto";
import { chmod, mkdir, realpath, stat } from "node:fs/promises";
import { join } from "node:path";
import type { HomeContextProjection, HomeDesignation, HomeMemoryStatus, HomeOpen, HomeStatus, ModelRef } from "../protocol/types.js";
import { GatewayError } from "../errors.js";
import type { TrustService } from "../admin/trust-service.js";
import { EpisodicMemoryError, type EpisodicDiagnostic } from "../episodic/episodic-contract.js";
import type { EpisodicCanonicalEntry } from "../episodic/episodic-source.js";
import { readCanonicalHomeDeltas, readCanonicalHomeIndex, type HomeSourceChapter, type HomeSourceSnapshot } from "../episodic/home-source.js";
import type { TronWorkspace } from "../workspace/tron-workspace.js";
import { AsyncMutex } from "../util/async-mutex.js";
import { durablePublishBoundedJson, isDurablePublicationUncertain } from "../util/durable-json.js";
import { boundedString, boundedTimestamp } from "../util/json.js";
import { readSecureJson, SecureJsonFileError } from "../util/secure-json.js";
import {
  HomeMemory, homeMemoryToolUnavailable,
  type HomeMemoryDiagnostic, type HomeMemoryModelResolution, type HomeMemoryToolAccess, type HomeMemoryToolResult,
} from "./home-memory.js";
import { HomeMemoryRefusal, HomeRequestPolicy, type HomeActivationIdentity, type HomeActivationView, type HomeRequestRecord } from "./home-request-policy.js";
import { HOME_MAX_CHAPTERS, HOME_HARD_BYTES, HOME_HARD_ENTRIES, unsealedHomeChapterState, type HomeChapterState } from "./home-chapter-state.js";
import type { HomeDiagnostic, HomeDiagnosticRecord } from "./home-diagnostic.js";

/** One Gateway installation keeps at most one Home. */
const VERSION = 2;
const MAXIMUM_RECORD_BYTES = 16 * 1_024 * 1_024;
const MAXIMUM_PROVIDER_BYTES = 120;
const MAXIMUM_MODEL_ID_BYTES = 300;
/** The curated Home profile this build writes. A record written against a newer
 * revision is still this build's record to read: only `version` gates admission,
 * because a profile change is not a format change. */
const HOME_POLICY_REVISION = 1;
const HOME_SOFT_BYTES = 24 * 1_024 * 1_024;
const HOME_SOFT_ENTRIES = 50_000;

export interface HomeChapter {
  sessionId: string;
  ordinal: number;
  state: "active" | "sealed" | "reserved" | "materializing";
  createdAt: string;
  sealedAt?: string;
  sizeAtSeal?: number;
  entriesAtSeal?: number;
  attemptId?: string;
  expectedPath?: string;
}

export interface HomeRecord {
  version: 2;
  homeId: string;
  chapters: HomeChapter[];
  bindingRevision: number;
  generation: number;
  policyRevision: number;
  enabled: boolean;
  model: ModelRef;
  createdAt: string;
  updatedAt: string;
  /** Home's memory model. Absent on a record written before
   * Home's memory existed, and absent until `home.configureMemory` records one:
   * there are no defaults (decision D4), so an unconfigured memory refuses. */
  memory?: { model: ModelRef };
}

/** What the Home record says about one session id. `unnamed` means the record
 * does not name that session, which is the only window in which a creation-time
 * profile argument applies. */
export type HomeSessionProfile = "home" | "ordinary" | "unnamed";

/** The session operations Home needs from the runtime owner. Kept narrow so the
 * Home record's authority is never a second session owner. */
export interface HomeSessionPort {
  /** Create one session whose very first runtime already has the Home profile. */
  createHomeSession(cwd: string): Promise<string>;
  /** Apply the recorded model to a live Home session through the slot's normal
   * `setModel` path, when the live model differs. */
  applySessionModel(sessionId: string, model: ModelRef): Promise<void>;
  /** Whether the session exists at all: a live runtime, or a canonical session
   * the catalog or disk still holds. */
  sessionPresent(sessionId: string): Promise<boolean>;
  /** The canonical session JSONL for one session id, when this installation can
   * name it. Resolved per memory open, because a session exists before its file
   * does and a runtime may be evicted while its memory stays open. */
  sessionFile(sessionId: string): Promise<string | undefined>;
  /** Whether the session currently holds a live runtime. */
  hasLiveRuntime(sessionId: string): boolean;
  /** Registry owns session mutation ordering. Seal enters it before taking the
   * Home recordMutex, so admitted attention/archive/delete work settles first. */
  serializeSessionMutation<T>(sessionId: string, commit: () => Promise<T>): Promise<T>;
  /** Quiescent canonical size used to seal a chapter at its soft boundary. */
  chapterMetrics?(sessionId: string): Promise<{ bytes: number; entries: number; quiescent: boolean }>;
  /** Whether the exact current SDK file has a complete durable conversation message. */
  hasConversation?(sessionId: string, expectedPath: string): Promise<boolean>;
  /** Replace the session's live runtime in place after `commit` changes the
   * profile decision for it, so the next prompt uses the new profile. A busy
   * session refuses retryably before `commit` runs. */
  replaceRuntimeForProfile(sessionId: string, commit: () => Promise<void>): Promise<void>;
  /** Synchronously stale-mark Home slots before any asynchronous reload work. */
  beginHomePublicationReconciliation(): void;
  /** Retire every live Home slot after uncertain publication; next admission
   * rebuilds from the record reloaded by this owner. */
  retireHomeRuntimes(reloaded: boolean): Promise<void>;
}

/** What the session runtime reports to Home's memory. Narrow on purpose: the
 * runtime knows that canonical entries changed; the memory owns what it reads,
 * how long it waits and how much it spends. */
export interface HomeMemoryPort {
  /** Canonical entries were committed. Fire and forget, never awaited inside
   * admission or a slot lane. */
  entriesCommitted(sessionId: string): void;
}

export interface HomeOwnerOptions {
  tronHome: string;
  trust: TrustService;
  sessions: HomeSessionPort;
  diagnostic?: HomeDiagnostic;
  /** The Tron internal workspace whose capability state holds Home's memory. */
  workspace: TronWorkspace;
  /** Resolves the compactor's model the way Knowledge resolves the model for its
   * own calls: from the Gateway's ModelRuntime, never a session's runtime. */
  memorySummarizer: (model: ModelRef) => HomeMemoryModelResolution;
  /** Where Home's memory reports its bounded records. */
  memoryDiagnostic?: (record: HomeMemoryDiagnostic) => void;
  /** Where Home's request seam reports one record per activation and per
   * refusal: the effective size of a turn and the readiness wait it took. */
  requestDiagnostic?: (record: HomeRequestRecord) => void;
}

/**
 * The one owner of Tron Home's designation for this Gateway installation: the
 * durable record under `<tronHome>/gateway/home/home.json`, the neutral working
 * directory beside it, and the profile decision for every session id.
 *
 * Designation is keyed by session id, so a fork of the Home session is an
 * ordinary session with no further work.
 *
 * Home also owns its memory (one `EpisodicMemory` over the Home session's
 * canonical entries) and the request seam that turns each activation into fresh
 * context plus the frozen memory view. The memory lives here rather than in a
 * session's runtime because a runtime is evicted, replaced and rebuilt while the
 * memory and its spend must outlive all of them.
 */
export class HomeOwner {
  private readonly directory: string;
  private readonly recordPath: string;
  private workspacePath: string;
  private readonly mutex = new AsyncMutex();
  /** Serializes durable record commits with model callbacks that arrive from a
   * slot lane while a Home lifecycle mutation owns `mutex`. */
  private readonly recordMutex = new AsyncMutex();
  /** One memory per Home session id, replacing the previous session's. */
  private memory: { sessionId: string; owner: HomeMemory } | undefined;
  /** One request seam per Home session id, so a runtime replacement reuses the
   * open activation rather than dropping it. A fork is a new id, hence a new
   * seam and no activation. */
  private readonly policies = new Map<string, HomeRequestPolicy>();
  /** True while a designation is creating its session. A brand-new Home
   * session's first runtime is built before the record can name it, so this
   * window is the only other reason a session id has a Home seam. */
  private designating = false;
  private record: HomeRecord | undefined;
  private unavailable: string | undefined;
  /** The fenced owner retains retirement work; a slot-lane writer must not await work queued on that same lane. */
  private publicationRetirement: Promise<void> | undefined;

  constructor(private readonly options: HomeOwnerOptions) {
    this.directory = join(options.tronHome, "gateway", "home");
    this.recordPath = join(this.directory, "home.json");
    this.workspacePath = join(this.directory, "workspace");
  }

  /** Load the durable record once, before any runtime can ask for a profile. */
  async initialize(): Promise<void> {
    // Runtime cwd is canonicalized by TrustService; match that identity even
    // when the installation path itself contains symlinks.
    try {
      this.workspacePath = await realpath(this.workspacePath);
    } catch {
      // A malformed record can still coexist with an uncreated workspace. Its
      // existing parent is enough to canonicalize the future child identity.
      try { this.workspacePath = join(await realpath(this.directory), "workspace"); } catch { /* no Home directory yet */ }
    }
    await this.load();
  }

  async status(): Promise<HomeStatus> {
    const memory = await this.memoryStatus();
    const activation = this.contextStatus();
    if (this.unavailable) {
      return {
        phase: "unavailable", activation, readiness: { ready: false, gaps: ["record-unavailable"] },
        recovery: { action: "inspect-record", reason: this.unavailable },
        available: false, reason: this.unavailable, enabled: false, live: false, sessionPresent: false, memory,
      };
    }
    const record = this.record;
    if (!record) return {
      phase: "undesignated", activation, readiness: { ready: false, gaps: ["not-designated"] },
      recovery: { action: "designate" },
      available: true, enabled: false, live: false, sessionPresent: false, memory,
    };
    const sessionId = homeSessionId(record);
    const currentChapter = record.chapters.at(-1)!;
    const live = this.options.sessions.hasLiveRuntime(sessionId);
    const sessionPresent = await this.options.sessions.sessionPresent(sessionId);
    // Missing-session recovery is a status, never zero-valued admission metrics.
    const activeMetrics = sessionPresent && currentChapter.state === "active" && this.options.sessions.chapterMetrics
      ? await this.options.sessions.chapterMetrics(currentChapter.sessionId)
      : undefined;
    const gaps: string[] = [];
    if (!record.enabled) gaps.push("disabled");
    if (!sessionPresent) gaps.push("session-missing");
    if (!memory.configured) gaps.push("memory-not-configured");
    if (memory.blocked) gaps.push(`memory-${memory.blocked}`);
    const recovery: HomeStatus["recovery"] = !record.enabled || !sessionPresent
      ? { action: "designate", ...(!sessionPresent ? { reason: "Home session is missing" } : {}) }
      : !memory.configured ? { action: "configure-memory" }
        : memory.blocked ? { action: "resume-memory", reason: memory.blocked }
          : { action: "none" };
    const ready = gaps.length === 0;
    const phase: HomeStatus["phase"] = !record.enabled ? "disabled"
      : record.chapters.at(-1)!.state === "reserved" || record.chapters.at(-1)!.state === "materializing" ? "rollover-pending"
        : !sessionPresent ? "missing-session"
          : memory.blocked || !memory.configured ? "blocked"
          : activation.available && activation.activationOpen ? "active" : "ready";
    return {
      phase, activation, readiness: { ready, gaps }, recovery,
      available: true,
      enabled: record.enabled,
      homeId: record.homeId,
      sessionId,
      bindingRevision: record.bindingRevision,
      generation: record.generation,
      model: { ...record.model },
      live,
      sessionPresent,
      memory,
      chapter: {
        count: record.chapters.length,
        ...((activeMetrics?.bytes ?? currentChapter.sizeAtSeal) === undefined ? {} : { currentBytes: activeMetrics?.bytes ?? currentChapter.sizeAtSeal }),
        ...((activeMetrics?.entries ?? currentChapter.entriesAtSeal) === undefined ? {} : { currentEntries: activeMetrics?.entries ?? currentChapter.entriesAtSeal }),
        recoveryDecision: currentChapter.state === "reserved" ? "reserved"
          : currentChapter.state === "materializing" ? "materializing" : "none",
      },
    };
  }

  /** The admitted model for the enabled Home at the runtime construction
   * boundary; ordinary sessions keep their transcript-selected model. */
  modelFor(sessionId: string): ModelRef | undefined {
    const record = this.record;
    return record?.enabled && record.chapters.some(chapter => chapter.sessionId === sessionId) ? { ...record.model } : undefined;
  }

  /** Only the current active chapter is writable; sealed and in-progress
   * successor entries fail closed until their owning lifecycle transition lands. */
  chapterStateFor(sessionId: string): HomeChapterState {
    const chapter = this.record?.chapters.find(candidate => candidate.sessionId === sessionId);
    if (chapter?.state === "materializing") return {
      sessionId, sealed: true, materializing: true, homeId: this.record!.homeId,
      ordinal: chapter.ordinal,
      ...(chapter.attemptId ? { attemptId: chapter.attemptId } : {}),
      ...(chapter.expectedPath ? { expectedPath: chapter.expectedPath } : {}),
    };
    if (chapter?.state === "sealed" || chapter?.state === "reserved") {
      return { sessionId, sealed: true, homeId: this.record!.homeId, ordinal: chapter.ordinal };
    }
    return chapter
      ? { sessionId, sealed: false, homeId: this.record!.homeId, ordinal: chapter.ordinal }
      : unsealedHomeChapterState(sessionId);
  }

  /** Claim a durable reserved successor for the Registry's single-flight owner.
   * Replacing an older attempt is recovery after the prior Gateway process exited. */
  /** Stable logical route target. A reserved successor's next binding revision
   * is fixed before it can receive a command. */
  noteRouteBound(category: Extract<HomeDiagnosticRecord, { outcome: "route-bound" }>["category"]): void {
    this.options.diagnostic?.({ outcome: "route-bound", category });
  }

  /** One admission policy for logical binding and serialized physical prompts.
   * A physical target cannot silently transfer to the successor. */
  assertChapterAdmission(sessionId: string, metrics: { bytes: number; entries: number }): void {
    const chapter = this.record?.chapters.find(candidate => candidate.sessionId === sessionId);
    if (!chapter) return;
    const reason = metrics.bytes >= HOME_HARD_BYTES ? "hard-bytes"
      : metrics.entries >= HOME_HARD_ENTRIES ? "hard-entries" : undefined;
    if (!reason) return;
    this.options.diagnostic?.({ outcome: "chapter-refused", chapterOrdinal: chapter.ordinal, reason });
    throw new GatewayError("conflict", "This Home chapter has reached its hard limit; continue through Home", true, { reason });
  }

  /** Hard admission is a durable chapter transition before the command receipt binds a target. */
  async ensureChapterBelowHardLimit(): Promise<void> {
    const chapter = this.record?.chapters.at(-1);
    if (!chapter || chapter.state !== "active" || !this.options.sessions.chapterMetrics) return;
    const metrics = await this.options.sessions.chapterMetrics(chapter.sessionId);
    try { this.assertChapterAdmission(chapter.sessionId, metrics); }
    catch (error) {
      if (!(error instanceof GatewayError) || error.code !== "conflict") throw error;
      if (!metrics.quiescent) {
        throw new GatewayError("busy", "Tron Home is stopping an activation at the chapter limit; retry after it settles", true);
      }
      await this.chapterQuiescent(chapter.sessionId);
    }
  }

  open(): HomeOpen {
    const binding = this.routeBinding();
    const record = this.record!;
    return {
      logicalSessionId: "home",
      homeId: binding.homeId,
      bindingRevision: binding.bindingRevision,
      sessionId: binding.physicalSessionId,
      generation: record.generation,
      chapterState: record.chapters.at(-1)!.state,
    };
  }

  routeBinding(): { homeId: string; bindingRevision: number; physicalSessionId: string } {
    this.assertAvailable();
    const record = this.record;
    if (!record || !record.enabled) throw new GatewayError("not_found", "Tron Home is not enabled");
    const chapter = record.chapters.at(-1)!;
    return {
      homeId: record.homeId,
      bindingRevision: chapter.state === "active" ? record.bindingRevision : record.bindingRevision + 1,
      physicalSessionId: chapter.sessionId,
    };
  }

  assertRouteBinding(binding: { homeId: string; bindingRevision: number; physicalSessionId: string }): void {
    const current = this.routeBinding();
    if (current.homeId !== binding.homeId || current.bindingRevision !== binding.bindingRevision
      || current.physicalSessionId !== binding.physicalSessionId) {
      throw new GatewayError("conflict", "The Home route binding is stale; open Home again before sending", false, {
        reason: "binding-stale", bindingRevision: binding.bindingRevision,
      });
    }
  }

  async assertReservedChapterAttempt(sessionId: string, attemptId: string, expectedPath: string): Promise<void> {
    await this.recordMutex.run(async () => {
      const chapter = this.record?.chapters.find(candidate => candidate.sessionId === sessionId);
      if (!chapter
        || (chapter.state !== "materializing" && chapter.state !== "active")
        || (chapter.state === "materializing" && (chapter.attemptId !== attemptId || chapter.expectedPath !== expectedPath))) {
        this.options.diagnostic?.({ outcome: "chapter-refused", reason: "ownership-changed" });
        throw new GatewayError("conflict", "Home materialization attempt no longer owns its reservation", true);
      }
      if (chapter.state === "active" && !(await this.options.sessions.hasConversation?.(sessionId, expectedPath))) {
        this.options.diagnostic?.({ outcome: "chapter-refused", reason: "missing-conversation-evidence" });
        throw new GatewayError("conflict", "Published Home chapter lacks durable conversation evidence", true);
      }
    });
  }

  async assertPublishedHomeChapter(sessionId: string, expectedPath: string): Promise<void> {
    await this.recordMutex.run(async () => {
      const chapter = this.record?.chapters.find(candidate => candidate.sessionId === sessionId);
      if (chapter?.state !== "active" || !(await this.options.sessions.hasConversation?.(sessionId, expectedPath))) {
        this.options.diagnostic?.({ outcome: "chapter-refused", reason: "published-evidence-missing" });
        throw new GatewayError("conflict", "Active Home chapter lacks durable conversation evidence", true);
      }
    });
  }

  async claimReservedChapter(sessionId: string, attemptId: string): Promise<HomeChapter> {
    return this.recordMutex.run(async () => {
      const current = this.record;
      const chapter = current?.chapters.find(candidate => candidate.sessionId === sessionId);
      if (!current || !chapter || (chapter.state !== "reserved" && chapter.state !== "materializing")) {
        throw new GatewayError("conflict", "Home chapter is not reserved for materialization");
      }
      const claimed: HomeChapter = { ...chapter, state: "materializing", attemptId };
      await this.writeLocked({
        ...current,
        chapters: current.chapters.map(candidate => candidate.sessionId === sessionId ? claimed : candidate),
        updatedAt: new Date().toISOString(),
      });
      return { ...claimed };
    });
  }

  /** Persist the exact SDK path before the caller can admit canonical input. */
  async recordReservedChapterPath(sessionId: string, attemptId: string, expectedPath: string): Promise<void> {
    await this.recordMutex.run(async () => {
      const current = this.record;
      const chapter = current?.chapters.find(candidate => candidate.sessionId === sessionId);
      if (!current || !chapter || chapter.state !== "materializing" || chapter.attemptId !== attemptId) {
        throw new GatewayError("conflict", "Home materialization attempt no longer owns its reservation");
      }
      await this.writeLocked({
        ...current,
        chapters: current.chapters.map(candidate => candidate.sessionId === sessionId
          ? { ...candidate, expectedPath }
          : candidate),
        updatedAt: new Date().toISOString(),
      });
    });
  }

  /** Bounded chapter metadata consumed by Registry recovery; never exposes mutable record state. */
  reservedChapter(sessionId: string): HomeChapter | undefined {
    const chapter = this.record?.chapters.find(candidate => candidate.sessionId === sessionId);
    return chapter && (chapter.state === "reserved" || chapter.state === "materializing") ? { ...chapter } : undefined;
  }

  /** The canonical cwd used to locate Home's physical session directory. */
  homeWorkspacePath(): string { return this.workspacePath; }

  /** What the record says about one session id. Runtime creation reads this for
   * every runtime it builds, so a replacement is never built from a stale
   * profile decision. */
  profileFor(sessionId: string, cwd?: string): HomeSessionProfile {
    const record = this.record;
    if (this.unavailable && cwd === this.workspacePath) {
      throw new GatewayError("conflict", `Tron Home is unavailable: ${this.unavailable}`);
    }
    if (!record || !record.chapters.some(chapter => chapter.sessionId === sessionId)) return "unnamed";
    return record.enabled ? "home" : "ordinary";
  }

  /**
   * The request seam for one session id, or undefined for every other session.
   * A runtime asks for it once per runtime creation, so a replacement (a reload,
   * a profile change) gets the same seam and keeps its open activation; only a
   * fork — a new session id — gets a fresh one.
   *
   * The caller has already decided the runtime is Home's. The only two sessions
   * that can be: the one the record names and enables, and the one a designation
   * in flight is creating (its first runtime is built before the record can name
   * it — the same window `isHomeProfile` covers with its explicit profile).
   */
  requestPolicyFor(sessionId: string): HomeRequestPolicy | undefined {
    const record = this.record;
    const designated = record !== undefined && record.enabled && record.chapters.some(chapter => chapter.sessionId === sessionId && (chapter.state === "active" || chapter.state === "materializing"));
    if (!designated && !this.designating) return undefined;
    let policy = this.policies.get(sessionId);
    if (!policy) {
      policy = new HomeRequestPolicy({
        prepareMemoryView: (activation: HomeActivationIdentity, signal: AbortSignal | undefined) => this.memoryView(activation, signal),
        ...(this.options.requestDiagnostic ? { onRecord: this.options.requestDiagnostic } : {}),
      });
      this.policies.set(sessionId, policy);
    }
    return policy;
  }

  /**
   * The canonical entries of one session changed (a persisted message, a context
   * edit, a navigation). Fire and forget: the memory re-reads the log after its
   * cursor and drains its pump under its own bounds, so no caller waits on it.
   *
   * A session whose memory is not open yet is not opened here: designation and
   * `home.configureMemory` decide when a memory starts spending.
   */
  noteEntriesCommitted(sessionId: string): void {
    const record = this.record;
    const chapter = record?.chapters.find(candidate => candidate.sessionId === sessionId);
    if (!record || !record.enabled || !chapter || (chapter.state !== "active" && chapter.state !== "materializing")) return;
    if (this.memory?.sessionId === record.homeId) this.memory.owner.noteEntriesCommitted();
    if (chapter.state === "materializing" && chapter.attemptId && chapter.expectedPath) {
      void this.publishObservedMaterialization(sessionId, chapter.attemptId, chapter.expectedPath).catch(() => {
        this.options.diagnostic?.({ outcome: "chapter-refused", reason: "publication-failed" });
      });
    }
  }

  /** Called by the Slot only after the completed turn has reached a quiescent boundary. */
  async chapterQuiescent(sessionId: string): Promise<void> {
    const record = this.record;
    const chapter = record?.chapters.find(candidate => candidate.sessionId === sessionId);
    if (!record || !record.enabled || !chapter) return;
    if (chapter.state === "materializing" && chapter.attemptId && chapter.expectedPath) {
      const published = await this.publishObservedMaterialization(sessionId, chapter.attemptId, chapter.expectedPath);
      if (!published) this.options.diagnostic?.({ outcome: "chapter-refused", reason: "conversation-not-durable" });
      return;
    }
    if (chapter.state !== "active" || !this.options.sessions.chapterMetrics) return;
    // Registry session ordering is outermost; remeasure after admitted
    // mutations settle, then take recordMutex only for the final ledger write.
    const rolled = await this.options.sessions.serializeSessionMutation(sessionId, async () => {
      const metrics = await this.options.sessions.chapterMetrics!(sessionId);
      if (!metrics.quiescent || (metrics.bytes < HOME_SOFT_BYTES && metrics.entries < HOME_SOFT_ENTRIES
        && metrics.bytes < HOME_HARD_BYTES && metrics.entries < HOME_HARD_ENTRIES)) return undefined;
      const sealed = await this.recordMutex.run(async () => {
        const current = this.record;
        const active = current?.chapters.find(candidate => candidate.sessionId === sessionId);
        if (!current || !active || active.state !== "active") return false;
        const now = new Date().toISOString();
        const successor: HomeChapter = {
          sessionId: randomUUID(), ordinal: active.ordinal + 1, state: "reserved", createdAt: now,
        };
        await this.writeLocked({
          ...current,
          chapters: current.chapters.map(candidate => candidate.sessionId === sessionId
            ? { ...candidate, state: "sealed" as const, sealedAt: now, sizeAtSeal: metrics.bytes, entriesAtSeal: metrics.entries }
            : candidate).concat(successor),
          updatedAt: now,
        });
        return true;
      });
      return sealed ? metrics : undefined;
    });
    if (rolled) this.options.diagnostic?.({
      outcome: "chapter-rollover", chapterOrdinal: chapter.ordinal,
      reason: rolled.bytes >= HOME_HARD_BYTES ? "hard-byte-limit"
        : rolled.entries >= HOME_HARD_ENTRIES ? "hard-entry-limit"
          : rolled.bytes >= HOME_SOFT_BYTES ? "soft-byte-limit" : "soft-entry-limit",
    });
  }

  async publishObservedMaterialization(sessionId: string, attemptId: string, expectedPath: string): Promise<boolean> {
    return this.recordMutex.run(async () => {
      const current = this.record;
      const chapter = current?.chapters.find(candidate => candidate.sessionId === sessionId);
      if (!current || !current.enabled || chapter?.state !== "materializing"
        || chapter.attemptId !== attemptId || chapter.expectedPath !== expectedPath) return false;
      const currentPath = await this.options.sessions.sessionFile(sessionId);
      const observed = currentPath === expectedPath && await this.options.sessions.hasConversation?.(sessionId, expectedPath);
      if (!currentPath || currentPath !== expectedPath || !observed) return false;
      const now = new Date().toISOString();
      await this.writeLocked({
        ...current,
        chapters: current.chapters.map(candidate => candidate.sessionId === sessionId
          ? { sessionId, ordinal: candidate.ordinal, state: "active", createdAt: candidate.createdAt }
          : candidate),
        bindingRevision: current.bindingRevision + 1,
        updatedAt: now,
      });
      this.options.diagnostic?.({ outcome: "chapter-recovery", reason: "conversation-published" });
      return true;
    });
  }

  /**
   * The memory tools for one session id, or undefined for every session that is
   * not the enabled Home. The slot builds a Home runtime's extension factories
   * once, but the answer is resolved at each call: the record, the open store, a
   * block and a reconfiguration all change while a runtime is alive, and no tool
   * may read a superseded memory. A tool call is only reachable from an
   * activation, which has already opened the memory it runs on, so this accessor
   * never opens or configures one.
   */
  memoryToolsFor(sessionId: string): HomeMemoryToolAccess | undefined {
    const record = this.record;
    if (!record || !record.enabled || !record.chapters.some(chapter => chapter.sessionId === sessionId && (chapter.state === "active" || chapter.state === "materializing"))) return undefined;
    return {
      zoom: (id, n) => this.toolMemory(sessionId, memory => memory.zoom(id, n)),
      date: id => this.toolMemory(sessionId, memory => memory.date(id)),
      search: (query, from, to) => this.toolMemory(sessionId, memory => memory.search(query, from, to)),
    };
  }

  /**
   * `home.configureMemory`: record the model Home's memory runs its compactor
   * calls on. There is no budget to manage (#493): the memory's spend is bounded
   * by construction and grows only with the conversation. The memory is opened (or re-opened, when the model changed)
   * before the record is written, so a refused configuration changes nothing and
   * a different model resumes a blocked memory without losing the nodes it built.
   */
  async configureMemory(input: { model: ModelRef }): Promise<HomeMemoryStatus> {
    return this.mutex.run(async () => {
      this.assertAvailable();
      const record = this.record;
      if (!record) throw new GatewayError("not_found", "Tron Home is not designated");
      if (!record.enabled) {
        // A disabled Home runs no activations, so a memory configuration would
        // name spending nothing can use. Designate it first.
        throw new GatewayError("conflict", "Tron Home is disabled: designate it before configuring its memory");
      }
      const memory = { model: { ...input.model } };
      const owner = this.ownerFor(record.homeId);
      await owner.configure(memory);
      await this.recordMutex.run(async () => {
        const current = this.record;
        if (!current || current.homeId !== record.homeId || !current.enabled) {
          throw new GatewayError("conflict", "Tron Home changed while configuring its memory");
        }
        await this.writeLocked({ ...current, memory, updatedAt: new Date().toISOString() });
      });
      // No designation diagnostic: configuring the memory is not a Home
      // lifecycle outcome. The memory reports itself on its own channel.
      return owner.status();
    });
  }

  /**
   * `home.resumeMemory`: clear a block, re-read the source and restart the pump.
   * The operator's answer to a `permanent-failure` (a model that refused a whole
   * batch) or a `source-unavailable` block whose cause is gone. The memory resumes
   * a `retries-exhausted` block by itself on the next activation.
   */
  async resumeMemory(): Promise<HomeMemoryStatus> {
    return this.mutex.run(async () => {
      this.assertAvailable();
      const record = this.record;
      if (!record) throw new GatewayError("not_found", "Tron Home is not designated");
      if (!record.enabled) throw new GatewayError("conflict", "Tron Home is disabled: designate it before resuming its memory");
      if (!record.memory) throw new GatewayError("conflict", "Home memory is not configured: configure it with home.configureMemory");
      const owner = this.ownerFor(record.homeId);
      await owner.configure(record.memory);
      const blocked = owner.status().blocked;
      if (!blocked) {
        throw new GatewayError("conflict", "Home memory is not blocked");
      }
      try {
        await owner.resumeBlock();
      } catch (error) {
        if (error instanceof HomeMemoryRefusal) throw new GatewayError("conflict", error.message);
        throw error;
      }
      return owner.status();
    });
  }

  /**
   * The bounded memory status `home.status` reports. A memory whose store is not
   * open yet still reports what a restart would restore (its recorded spend and
   * the block that refuses every activation), read from the store's own state
   * document without opening it.
   */
  async memoryStatus(): Promise<HomeMemoryStatus> {
    const record = this.record;
    if (!record) return { configured: false, open: false };
    const sessionId = homeSessionId(record);
    const owner = this.memory?.sessionId === record.homeId ? this.memory.owner : undefined;
    if (owner?.open) return owner.status();
    const base: HomeMemoryStatus = record.memory
      ? { configured: true, open: false, model: { ...record.memory.model } }
      : { configured: false, open: false };
    const persisted = await (owner ?? this.ownerFor(record.homeId)).persistedState().catch(() => undefined);
    if (!persisted) return base;
    return {
      ...base,
      spentTokens: persisted.spend,
      ...(persisted.blocked ? { blocked: persisted.blocked.reason } : {}),
    };
  }

  /**
   * `home.context`: the bounded request context of Home's current or last
   * activation. Sizes and identifiers only, never a message body: the frozen
   * view text stays in the request that carried it.
   */
  contextStatus(): HomeContextProjection {
    const record = this.record;
    if (!record) return { available: false };
    const evidence = this.policies.get(homeSessionId(record))?.contextEvidence();
    if (!evidence) return { available: false };
    const step = evidence.step;
    return {
      available: true,
      activationStartEntryId: evidence.activationStartEntryId,
      activationOpen: evidence.activationOpen,
      // Absent until the activation prepared a request: an activation refused
      // before that has a start entry and a reason, and no sizes.
      ...(step ? {
        viewLines: step.viewLines,
        viewBytes: step.viewBytes,
        effectiveTokens: step.effectiveTokens,
        contextWindow: step.contextWindow,
      } : {}),
      ...(evidence.refusal ? { lastRefusalReason: evidence.refusal.reason, lastRefusalDetail: evidence.refusal.detail } : {}),
    };
  }

  /** The memory a tool read runs against, or the typed answer for why there is
   * none. A missing memory is `memory-not-configured` when the record holds no
   * configuration and `memory-unavailable` when it holds one the store has not
   * opened. */
  private toolMemory(sessionId: string, read: (memory: HomeMemory) => Promise<HomeMemoryToolResult>): Promise<HomeMemoryToolResult> {
    const record = this.record;
    const memory = record && record.enabled
      && record.chapters.some(chapter => chapter.sessionId === sessionId && (chapter.state === "active" || chapter.state === "materializing"))
      && this.memory?.sessionId === record.homeId
      ? this.memory.owner
      : undefined;
    if (memory) return read(memory);
    return Promise.resolve(homeMemoryToolUnavailable(record?.memory ? "memory-unavailable" : "memory-not-configured"));
  }

  /** Release the memory store and the request seams. */
  async dispose(): Promise<void> {
    this.policies.clear();
    const memory = this.memory;
    this.memory = undefined;
    await memory?.owner.dispose();
  }

  /**
   * The frozen memory view for one activation: the memory must be configured
   * (decision D4's no-defaults rule), must be able to place the activation's
   * start entry, and must be able to cover it before the request is built.
   */
  private async memoryView(activation: HomeActivationIdentity, signal: AbortSignal | undefined): Promise<HomeActivationView> {
    // Reachable only through a seam, which exists only for the enabled Home
    // session or for the session a designation in flight is creating.
    const record = this.record;
    if (!record || !record.enabled) {
      throw new HomeMemoryRefusal("memory-not-configured", "Tron Home is not enabled");
    }
    if (!record.memory) {
      throw new HomeMemoryRefusal("memory-not-configured", "Home memory is not configured");
    }
    const owner = this.ownerFor(record.homeId);
    // After a Gateway restart the record still holds the configuration; the
    // first activation opens the store from it.
    await owner.configure(record.memory);
    return owner.activationView(activation, signal);
  }

  /** One memory owner and persisted namespace for the stable installation Home. */
  private async readHomeSource(): Promise<HomeSourceSnapshot> {
    const record = this.record;
    if (!record) throw new GatewayError("conflict", "Tron Home is unavailable");
    const chapters: HomeSourceChapter[] = [];
    for (const chapter of record.chapters) {
      if (chapter.state !== "sealed" && chapter.state !== "active" && chapter.state !== "materializing") continue;
      let path: string | undefined;
      try { path = await this.options.sessions.sessionFile(chapter.sessionId); }
      catch (error) {
        if (chapter.state === "sealed") throw new EpisodicMemoryError("source", `Sealed Home chapter ${chapter.sessionId} cannot be resolved: ${String(error)}`);
        throw error;
      }
      if (!path) {
        if (chapter.state === "sealed") throw new EpisodicMemoryError("source", `Sealed Home chapter ${chapter.sessionId} has no catalog path`);
        continue;
      }
      const info = await stat(path).catch(error => {
        if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
        throw error;
      });
      if (!info?.isFile()) {
        if (chapter.state === "sealed") throw new EpisodicMemoryError("source", `Sealed Home chapter ${chapter.sessionId} is unavailable`);
        continue;
      }
      chapters.push({ sessionId: chapter.sessionId, path, sealed: chapter.state === "sealed" });
    }
    if (chapters.length === 0) throw new GatewayError("conflict", "Home has no canonical chapter file to read");
    return {
      homeId: record.homeId,
      ledgerRevision: record.bindingRevision,
      chapters,
    };
  }

  private ownerFor(homeId: string): HomeMemory {
    const current = this.memory;
    if (current && current.sessionId === homeId) return current.owner;
    if (current) void current.owner.dispose();
    const source = () => this.readHomeSource();
    const owner = new HomeMemory({
      workspace: this.options.workspace,
      sessionId: homeId,
      sessionFile: async () => {
        const record = this.record;
        return record ? this.options.sessions.sessionFile(homeSessionId(record)) : undefined;
      },
      sessionSource: {
        read: async function* (cursor, limits) { yield* readCanonicalHomeDeltas(await source(), cursor, limits); },
        branchAtCursor: async function* (cursor, limits) { yield* readCanonicalHomeIndex(await source(), cursor, limits); },
      },
      modelSummarizer: this.options.memorySummarizer,
      ...(this.options.memoryDiagnostic ? { diagnostic: this.options.memoryDiagnostic } : {}),
    });
    this.memory = { sessionId: homeId, owner };
    return owner;
  }

  /** Drop the memory a record no longer owns: the session changed, or Home is
   * disabled and its session is ordinary again. */
  private async releaseMemory(): Promise<void> {
    const memory = this.memory;
    this.memory = undefined;
    await memory?.owner.dispose().catch(() => {});
  }

  /**
   * `home.designate`. An enabled record whose session still exists is idempotent,
   * but cannot change the session-owned model; callers use `session.setModel` for
   * that. A disabled record is re-enabled on the same session. A record whose
   * session is gone is kept and given a fresh session, because the record is the
   * only evidence of the designation.
   */
  async designate(input: { model?: ModelRef }, defaultModel: () => ModelRef): Promise<HomeDesignation> {
    return this.mutex.run(async () => {
      this.assertAvailable();
      const existing = this.record;
      const pendingChapter = existing?.chapters.find(chapter => chapter.state === "reserved" || chapter.state === "materializing");
      if (pendingChapter && existing?.enabled) {
        throw new GatewayError("conflict", "Tron Home has an unresolved chapter reservation; recover that chapter before designation");
      }
      const existingSessionId = existing ? homeSessionId(existing) : undefined;
      if (existing && existingSessionId && (
        (pendingChapter !== undefined && !existing.enabled)
        || await this.options.sessions.sessionPresent(existingSessionId)
      )) {
        if (existing.enabled) {
          if (input.model && (input.model.provider !== existing.model.provider || input.model.id !== existing.model.id)) {
            this.options.diagnostic?.({ outcome: "refused", reason: "model-change-requires-session-set-model" });
            throw new GatewayError("conflict", "Tron Home is already enabled with a different model; use session.setModel to change its model");
          }
          return designation(existing);
        }
        // The model is the request's, else the one the record was last
        // designated with; both were admitted before they were recorded.
        const model = input.model ?? existing.model;
        let next: HomeRecord | undefined;
        await this.commitProfileChange(existingSessionId!, current => {
          next = {
            ...current,
            enabled: true,
            generation: current.generation + 1,
            policyRevision: HOME_POLICY_REVISION,
            model: { ...model },
            updatedAt: new Date().toISOString(),
          };
          return next;
        });
        if (!next) throw new Error("Home re-enable did not commit its record");
        const nextSessionId = homeSessionId(next);
        if (this.options.sessions.hasLiveRuntime(nextSessionId)) {
          await this.options.sessions.applySessionModel(nextSessionId, model);
        }
        this.options.diagnostic?.({ outcome: "enabled" });
        return designation(next);
      }

      const cwd = await this.ensureWorkspace();
      // An explicit decision, so `requireResolved` never blocks on the neutral
      // directory and no project resource can load from it.
      await this.options.trust.set(cwd, false);
      const model = input.model ?? defaultModel();
      // A different session means the previous one is no longer Home's, so its
      // memory is released before the new session takes the designation.
      await this.releaseMemory();
      let sessionId: string;
      this.designating = true;
      try {
        sessionId = await this.options.sessions.createHomeSession(cwd);
      } finally {
        this.designating = false;
      }
      try {
        await this.options.sessions.applySessionModel(sessionId, model);
        const now = new Date().toISOString();
        const record: HomeRecord = {
          version: VERSION,
          homeId: existing?.homeId ?? randomUUID(),
          chapters: [
            ...(existing?.chapters.map(chapter => chapter.state === "active" ? { ...chapter, state: "sealed" as const, sealedAt: now } : chapter) ?? []),
            { sessionId, ordinal: (existing?.chapters.at(-1)?.ordinal ?? 0) + 1, state: "active", createdAt: now },
          ],
          bindingRevision: (existing?.bindingRevision ?? 0) + 1,
          generation: existing ? existing.generation + 1 : 1,
          policyRevision: HOME_POLICY_REVISION,
          enabled: true,
          model: { ...model },
          // The memory's configuration is the user's decision about *how* Home
          // remembers, so a replacement session keeps it; the spend is the old
          // session's, and a new store starts its own (docs/home.md).
          ...(existing?.memory ? { memory: { model: { ...existing.memory.model } } } : {}),
          createdAt: existing?.createdAt ?? now,
          updatedAt: now,
        };
        await this.write(record);
        this.options.diagnostic?.({ outcome: "designated" });
        return designation(record);
      } catch (error) {
        // No record names this session, so it must not keep the creation-time
        // Home profile: replace its runtime with what the record now says.
        await this.options.sessions.replaceRuntimeForProfile(sessionId, async () => {}).catch(() => {});
        throw error;
      }
    });
  }

  /** `home.disable`. The session stays an ordinary session afterwards. */
  async disable(): Promise<HomeDesignation> {
    return this.mutex.run(async () => {
      this.assertAvailable();
      const existing = this.record;
      if (!existing) throw new GatewayError("not_found", "Tron Home is not designated");
      if (!existing.enabled) return designation(existing);
      let next: HomeRecord | undefined;
      const update = (current: HomeRecord): HomeRecord => {
        next = { ...current, enabled: false, generation: current.generation + 1, updatedAt: new Date().toISOString() };
        return next;
      };
      // Registry owns both constructing and published runtimes. Catalog
      // absence is not absence of an in-flight writer/profile owner.
      await this.commitProfileChange(homeSessionId(existing), update);
      if (!next) throw new Error("Home disable did not commit its record");
      // Only once the change is committed: a refused (busy) disable must leave
      // the memory and the activation waiting in it exactly as they were.
      // Re-enabling re-opens the memory from the record and the store keeps every
      // node, so nothing is re-spent.
      await this.releaseMemory();
      this.options.diagnostic?.({ outcome: "disabled" });
      return designation(next);
    });
  }

  /**
   * The record is the single source of truth for Home's model, so a model
   * applied to the enabled Home session is recorded. A model applied to the same
   * session while it is disabled is an ordinary session's change and is not.
   */
  async noteModelApplied(sessionId: string, model: ModelRef): Promise<void> {
    await this.recordMutex.run(async () => {
      const record = this.record;
      if (!record || !record.enabled || !record.chapters.some(chapter => chapter.sessionId === sessionId && chapter.state === "active")) return;
      if (record.model.provider === model.provider && record.model.id === model.id) return;
      await this.writeLocked({ ...record, model: { ...model }, updatedAt: new Date().toISOString() });
    });
  }

  private assertAvailable(): void {
    if (!this.unavailable) return;
    this.options.diagnostic?.({ outcome: "unavailable", reason: "owner-fenced" });
    throw new GatewayError("conflict", `Tron Home is unavailable: ${this.unavailable}. The existing record was preserved.`);
  }

  /** Commit the record and rebuild the live runtime in one serialized step, so a
   * prompt cannot be admitted between the idle check, the write and the rebuild. */
  private async commitProfileChange(sessionId: string, update: (current: HomeRecord) => HomeRecord): Promise<void> {
    try {
      await this.options.sessions.replaceRuntimeForProfile(sessionId, async () => {
        await this.recordMutex.run(async () => {
          const current = this.record;
          if (!current || homeSessionId(current) !== sessionId) throw new GatewayError("conflict", "Tron Home changed during profile update");
          await this.writeLocked(update(current));
        });
      });
    } catch (error) {
      if (error instanceof GatewayError && error.code === "busy") {
        this.options.diagnostic?.({ outcome: "refused", reason: "session-busy" });
      }
      throw error;
    }
  }

  /** Create the neutral working directory owner-only, and resolve it the way
   * the trust store does so the recorded decision is the one sessions see. */
  private async ensureWorkspace(): Promise<string> {
    await mkdir(this.workspacePath, { recursive: true, mode: 0o700 });
    await chmod(this.workspacePath, 0o700);
    this.workspacePath = await this.options.trust.canonicalDirectory(this.workspacePath);
    return this.workspacePath;
  }

  private async write(record: HomeRecord): Promise<void> {
    await this.recordMutex.run(() => this.writeLocked(record));
  }

  private async writeLocked(record: HomeRecord): Promise<void> {
    this.assertAvailable();
    if (!admitRecord(record)) throw new GatewayError("conflict", "The Home record is invalid or exceeds its chapter bounds");
    try {
      await durablePublishBoundedJson(this.recordPath, record, MAXIMUM_RECORD_BYTES);
    } catch (error) {
      if (isDurablePublicationUncertain(error)) {
        // A visible replacement makes the caller's prior in-memory record
        // untrustworthy. Fence synchronous route readers before reloading.
        this.unavailable = "Home ledger publication is being reconciled";
        this.options.sessions.beginHomePublicationReconciliation();
        const reloaded = await this.load(false);
        // Do not await this here: writeLocked may be running inside a slot lane,
        // and Registry retirement queues behind that lane. Keep the owner fenced
        // until the retained retirement completes successfully.
        const retirement = Promise.resolve()
          .then(() => this.options.sessions.retireHomeRuntimes(reloaded))
          .then(() => {
            if (reloaded) this.unavailable = undefined;
          })
          .catch(error => {
            this.unavailable = "Home runtime retirement failed after ledger publication uncertainty";
            this.options.diagnostic?.({ outcome: "unavailable", reason: "publication-retirement-failed" });
            throw error;
          });
        this.publicationRetirement = retirement;
        void retirement.catch(() => {});
      }
      if (error instanceof Error && error.message === "JSON document exceeds its byte limit") {
        throw new GatewayError("conflict", "The Home chapter ledger exceeds its persisted size limit");
      }
      throw error;
    }
    this.record = record;
  }

  private async load(clearAvailability = true): Promise<boolean> {
    let loaded: unknown;
    try {
      const read = await readSecureJson<unknown>(this.recordPath, MAXIMUM_RECORD_BYTES);
      if (!read.present) {
        this.record = undefined;
        if (clearAvailability) this.unavailable = undefined;
        return true;
      }
      loaded = read.value;
    } catch (error) {
      // An empty, symlinked or permissively-readable file is not an absent one:
      // it is preserved and reported, never replaced.
      if (clearAvailability) this.record = undefined;
      this.unavailable = error instanceof SecureJsonFileError && error.kind === "invalid"
        ? "The Home record is malformed"
        : "The Home record is not a bounded owner-only regular file";
      this.options.diagnostic?.({ outcome: "unavailable", reason: "unreadable" });
      return false;
    }
    const admitted = admitRecord(loaded);
    if (!admitted) {
      if (clearAvailability) this.record = undefined;
      this.unavailable = "The Home record has an unsupported shape or version";
      this.options.diagnostic?.({ outcome: "unavailable", reason: "unsupported-record" });
      return false;
    }
    this.record = admitted;
    if (clearAvailability) this.unavailable = undefined;
    return true;
  }
}

function homeSessionId(record: HomeRecord): string {
  return record.chapters.find(chapter => chapter.state === "active")?.sessionId
    ?? record.chapters.at(-1)!.sessionId;
}

function designation(record: HomeRecord): HomeDesignation {
  return { homeId: record.homeId, sessionId: homeSessionId(record), generation: record.generation };
}

/** Admit one stored record, or undefined for anything this build cannot use.
 * Only the format version gates admission: a newer `policyRevision` is still a
 * record this build can read, preserve and re-enable. */
function admitRecord(value: unknown): HomeRecord | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const root = value as Record<string, unknown>;
  const model = root.model;
  if (!hasOnlyKeys(root, ["version", "homeId", "chapters", "bindingRevision", "generation", "policyRevision", "enabled", "model", "createdAt", "updatedAt", "memory"])
    || root.version !== VERSION
    || !boundedString(root.homeId, 200)
    || !Number.isSafeInteger(root.bindingRevision) || (root.bindingRevision as number) < 1
    || !Number.isSafeInteger(root.generation) || (root.generation as number) < 1
    || !Number.isSafeInteger(root.policyRevision) || (root.policyRevision as number) < 1
    || typeof root.enabled !== "boolean"
    || !boundedTimestamp(root.createdAt)
    || !boundedTimestamp(root.updatedAt)
    || !Array.isArray(root.chapters) || root.chapters.length === 0 || root.chapters.length > HOME_MAX_CHAPTERS
    || !model || typeof model !== "object" || Array.isArray(model)) return undefined;
  const modelRecord = model as Record<string, unknown>;
  if (!hasOnlyKeys(modelRecord, ["provider", "id"])
    || !boundedString(modelRecord.provider, MAXIMUM_PROVIDER_BYTES)
    || !boundedString(modelRecord.id, MAXIMUM_MODEL_ID_BYTES)) return undefined;
  const chapters = admitChapters(root.chapters);
  if (!chapters) return undefined;
  // A pre-memory chapter record has no `memory` field; malformed memory is
  // preserved and refused instead of silently dropping the user's projection.
  const memory = admitMemory(root.memory);
  if (memory === null) return undefined;
  return {
    version: VERSION,
    homeId: root.homeId,
    chapters,
    bindingRevision: root.bindingRevision as number,
    generation: root.generation as number,
    policyRevision: root.policyRevision as number,
    enabled: root.enabled,
    model: { provider: modelRecord.provider, id: modelRecord.id },
    createdAt: root.createdAt,
    updatedAt: root.updatedAt,
    ...(memory ? { memory } : {}),
  };
}

function admitChapters(value: unknown[]): HomeChapter[] | undefined {
  const chapters: HomeChapter[] = [];
  const sessionIds = new Set<string>();
  let activeCount = 0;
  for (let index = 0; index < value.length; index += 1) {
    const candidate = value[index];
    if (!candidate || typeof candidate !== "object" || Array.isArray(candidate)) return undefined;
    const chapter = candidate as Record<string, unknown>;
    if (!hasOnlyKeys(chapter, ["sessionId", "ordinal", "state", "createdAt", "sealedAt", "sizeAtSeal", "entriesAtSeal", "attemptId", "expectedPath"])
      || !boundedString(chapter.sessionId, 200)
      || sessionIds.has(chapter.sessionId)
      || chapter.ordinal !== index + 1
      || !["active", "sealed", "reserved", "materializing"].includes(String(chapter.state))
      || !boundedTimestamp(chapter.createdAt)) return undefined;
    const state = chapter.state as HomeChapter["state"];
    if (state === "active") activeCount += 1;
    if (state === "sealed" && !boundedTimestamp(chapter.sealedAt)) return undefined;
    if (chapter.sealedAt !== undefined && !boundedTimestamp(chapter.sealedAt)) return undefined;
    for (const field of ["sizeAtSeal", "entriesAtSeal"] as const) {
      const amount = chapter[field];
      if (amount !== undefined && (typeof amount !== "number" || !Number.isSafeInteger(amount) || amount < 0)) return undefined;
    }
    if (state === "materializing" && !boundedString(chapter.attemptId, 200)) return undefined;
    if (chapter.attemptId !== undefined && !boundedString(chapter.attemptId, 200)) return undefined;
    if (chapter.expectedPath !== undefined && !boundedString(chapter.expectedPath, 4_096)) return undefined;
    if (state !== "sealed" && (chapter.sealedAt !== undefined || chapter.sizeAtSeal !== undefined || chapter.entriesAtSeal !== undefined)) return undefined;
    if (state !== "materializing" && (chapter.attemptId !== undefined || chapter.expectedPath !== undefined)) return undefined;
    sessionIds.add(chapter.sessionId);
    chapters.push({
      sessionId: chapter.sessionId, ordinal: chapter.ordinal as number, state,
      createdAt: chapter.createdAt as string,
      ...(chapter.sealedAt === undefined ? {} : { sealedAt: chapter.sealedAt as string }),
      ...(chapter.sizeAtSeal === undefined ? {} : { sizeAtSeal: chapter.sizeAtSeal as number }),
      ...(chapter.entriesAtSeal === undefined ? {} : { entriesAtSeal: chapter.entriesAtSeal as number }),
      ...(chapter.attemptId === undefined ? {} : { attemptId: chapter.attemptId as string }),
      ...(chapter.expectedPath === undefined ? {} : { expectedPath: chapter.expectedPath as string }),
    });
  }
  if (activeCount > 1) return undefined;
  const materializing = chapters.filter(chapter => chapter.state === "materializing");
  const reserved = chapters.filter(chapter => chapter.state === "reserved");
  if (materializing.length > 1 || reserved.length > 1 || (materializing.length > 0 && reserved.length > 0)) return undefined;
  if (activeCount === 1 && chapters.at(-1)?.state !== "active") return undefined;
  if (activeCount === 0 && chapters.at(-1)?.state !== "reserved" && chapters.at(-1)?.state !== "materializing") return undefined;
  if (chapters.slice(0, -1).some(chapter => chapter.state !== "sealed")) return undefined;
  return chapters;
}

function hasOnlyKeys(record: Record<string, unknown>, keys: readonly string[]): boolean {
  return Object.keys(record).every(key => keys.includes(key));
}

/** `undefined` for an absent field, the admitted value for a valid one, and
 * `null` for a field this build cannot use. */
function admitMemory(value: unknown): { model: ModelRef } | null | undefined {
  if (value === undefined) return undefined;
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const record = value as Record<string, unknown>;
  const model = record.model;
  if (!hasOnlyKeys(record, ["model"]) || !model || typeof model !== "object" || Array.isArray(model)) return null;
  const modelRecord = model as Record<string, unknown>;
  if (!hasOnlyKeys(modelRecord, ["provider", "id"])
    || !boundedString(modelRecord.provider, MAXIMUM_PROVIDER_BYTES)
    || !boundedString(modelRecord.id, MAXIMUM_MODEL_ID_BYTES)) return null;
  return { model: { provider: modelRecord.provider, id: modelRecord.id } };
}
