import type { TaskWorkerControl, TaskControlRefusalReason } from "../../kernel/delegation/worker-contract.js";
import type { InputEnvelope, InputDelivery, InputTrigger, InputMessage, InputTriggerInbox } from "../../kernel/host/input-admission.js";
import type { ImageContent } from "../../kernel/pi/ai.js";
import { utf8Page } from "../../kernel/host/utf8-page.js";
import { isWakeEvidence, WakeInboxOwner, type HomeWakeEvidence, type HomeWakeEvidenceScope, type HomeWakeRoute, type HomeWakeTrigger } from "./home-wake-inbox.js";
import { parseEntry, readCanonicalSession, visitCanonicalSessionEntries } from "../../kernel/session/canonical-reader.js";
import { HOME_OBLIGATION, admitObligation, replayObligations, owed, type ObligationEvent, type ObligationRequest } from "./home-obligations.js";
import { createHash } from "node:crypto";
import type { NotificationService } from "../../notifications/notification-service.js";
import { randomUUID } from "node:crypto";
import type { SessionOperations } from "../../kernel/session/runtime-registry.js";
import type { HomeTaskPolicy } from "./home-task-worker-choice.js";
import { HomeChapterMaterializer } from "./home-chapter-materialization.js";
import { HomeTaskStore, HomeTaskStoreError } from "./home-task-store.js";
import { readHomeTaskMetrics } from "./home-task-metrics.js";
import { HomeTaskAuthorization } from "./home-task-authorization.js";
import { HomeTaskDispatcher, successorTaskId, type HomeTaskDiagnostic, type HomeTaskDispatchRequest, type HomeTaskGrantApproval, type HomeTaskResumeRequest } from "./home-task-dispatcher.js";
import type { ConfirmChange } from "../../kernel/settings/tool-contract.js";
import type { HomeTaskSubagents } from "../../kernel/delegation/task-subagents.js";
import { HOME_CHAPTER_TOPIC_COUNT, HOME_CHAPTER_TOPIC_LIST_CHARACTERS, HomeChapterContentsReader, homeChapterTopic } from "./home-chapter-contents.js";
import { chmod, mkdir, open, realpath, stat } from "node:fs/promises";
import { dirname, join } from "node:path";
import type { HomeChapterList, HomeProfileList, HomeChapterSummary, HomeContextProjection, HomeDesignation, HomeMemoryStatus, HomeOpen, HomeStatus, ModelRef, HomeMemoryView, HomeMemoryEvidence, HomeMemoryEvidencePage } from "../../protocol/types.js";
import { readHomeProfileIndex } from "./home-profile.js";
import { type SessionEntry } from "../../kernel/pi/coding-agent.js";
import { historyEntry } from "../../kernel/projection/history.js";
import type { EpisodicMemory } from "../../episodic/episodic-memory.js";
import { homeMemoryRevisionChanged, homeMemorySourceUnavailable, homeMemoryToolDisplay, type HomeMemoryViewRequest } from "../../episodic/home-memory-browser.js";
import { GatewayError } from "../../errors.js";
import type { TrustService } from "../../kernel/resources/trust-service.js";
import { projectBranch } from "../../episodic/episodic-projection.js";
import { HOME_MAX_CHAPTERS, EPISODIC_DEFAULTS, type EpisodicSummarizer } from "../../episodic/episodic-contract.js";
import { EpisodicMemoryError } from "../../errors.js";
import { EpisodicSourceChangedError } from "../../kernel/session/canonical-reader.js";
import { HomeSourceProofs, readCanonicalHomeDeltas, readCanonicalHomeIndex, readCanonicalHomeEvidence, type HomeSourceChapter, type HomeSourceSnapshot } from "../../episodic/home-source.js";
import type { TronWorkspace } from "../../workspace/tron-workspace.js";
import { AsyncMutex } from "../../util/async-mutex.js";
import { durablePublishBoundedJson, isDurablePublicationUncertain, syncDurably } from "../../foundation/durable-json.js";
import { boundedString, boundedTimestamp } from "../../foundation/json.js";
import { readSecureJson, SecureJsonFileError } from "../../foundation/secure-json.js";
import {
  HomeMemory, homeMemoryToolUnavailable,
  type HomeMemoryDiagnostic, type HomeMemoryToolAccess, type HomeMemoryToolResult,
} from "./home-memory.js";
import { HomeMemoryRefusal, HomeRequestPolicy, type HomeActivationIdentity, type HomeActivationView, type HomeRequestRecord } from "./home-request-policy.js";
import { HOME_HARD_BYTES, HOME_HARD_ENTRIES, HOME_SOFT_BYTES, HOME_SOFT_ENTRIES, unsealedHomeChapterState, type HomeChapterState } from "./home-chapter-state.js";
import type { HomeDiagnostic, HomeDiagnosticRecord } from "./home-diagnostic.js";
import { admitHomeTaskToolRequest, homeSystemPrompt } from "./tron-home-extension.js";
import { HOME_TASK_THINKING_LEVELS } from "./home-task-worker-choice.js";
import type { ProfileStore } from "./profile-store.js";
import { tronHomePath } from "../../foundation/tron-home-layout.js";
const VERSION = 2;
const MAXIMUM_RECORD_BYTES = 16 * 1_024 * 1_024;
const HOME_POLICY_REVISION = 3;

export interface HomeChapter {
  sessionId: string;
  ordinal: number;
  state: "active" | "sealed" | "reserved" | "materializing";
  createdAt: string;
  activationStarted: boolean;
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
  routeGeneration: number;
  policyRevision: number;
  enabled: boolean;
  createdAt: string;
  updatedAt: string;
  memory?: { paused?: true };
}

type HomeSessionProfile = "home" | "ordinary" | "unnamed";

export interface HomeSessionPort {
  createHomeSession(cwd: string): Promise<string>;
  homeModel(): Promise<ModelRef | undefined>;
  chooseHomeModel(sessionId: string, model: ModelRef): Promise<void>;
  chapterMetrics(sessionId: string): Promise<{ bytes: number; entries: number; quiescent: boolean }>;
  hasConversation(sessionId: string, expectedPath: string): Promise<boolean>;
  retireHomeRuntimes(): Promise<void>;
  wakeHome(sessionId: string): () => Promise<{ delivered: boolean }>;
}

export interface HomeOwnerOptions {
  tronHome: string;
  agentDir: string;
  trust: TrustService;
  sessions: HomeSessionPort;
  runtimes: SessionOperations;
  diagnostic?: HomeDiagnostic;
  workspace: TronWorkspace;
  memoryModels: () => Promise<readonly string[]>;
  memorySummarizer: () => EpisodicSummarizer;
  memoryDiagnostic?: (record: HomeMemoryDiagnostic) => void;
  requestDiagnostic?: (record: HomeRequestRecord) => void;
  taskPolicy: HomeTaskPolicy;
  notifications?: NotificationService;
  machineId?: string;
  taskDiagnostic?: (record: HomeTaskDiagnostic) => void;
  knowledge: () => ProfileStore | undefined;
  triggerSources?: () => readonly InputTriggerInbox[];
}

export function homeWorkspaceDirectory(tronHome: string): string {
  return tronHomePath(tronHome, "state/home/workspace");
}

export class HomeOwner {
  private readonly directory: string;
  private readonly recordPath: string;
  private workspacePath: string;
  private readonly mutex = new AsyncMutex();
  private readonly recordMutex = new AsyncMutex();
  private memory: { sessionId: string; owner: HomeMemory; proofs: HomeSourceProofs } | undefined;
  private readonly policies = new Map<string, HomeRequestPolicy>();
  private readonly chapterContents = new HomeChapterContentsReader();
  private designating = false;
  private record: HomeRecord | undefined;
  private unavailable: string | undefined;
  publicationUncertain = false;
  private readonly tasks: HomeTaskDispatcher;
  readonly materializer: HomeChapterMaterializer;
  private readonly inbox: WakeInboxOwner;
  private wakeRequested = false;
  private wakeDrain: Promise<void> | undefined;
  private lastWakeDelivered = false;

  constructor(private readonly options: HomeOwnerOptions) {
    this.directory = tronHomePath(options.tronHome, "state/home");
    this.recordPath = join(this.directory, "home.json");
    this.workspacePath = homeWorkspaceDirectory(options.tronHome);
    const store = new HomeTaskStore(options.tronHome, options.workspace, options.taskDiagnostic ? { diagnostic: options.taskDiagnostic } : {});
    const authorization = new HomeTaskAuthorization({ store: store.authorization,
      ...(options.taskDiagnostic ? { diagnostic: options.taskDiagnostic } : {}),
      resolveTrustedTarget: async target => {
        const inspection = await options.trust.inspect(target);
        return inspection.effectiveDecision === true ? inspection.cwd : undefined;
      } });
    this.inbox = new WakeInboxOwner(store, {
      notify: input => options.notifications?.enqueue(input) ?? Promise.resolve("unavailable"),
      pushSession: homeId => this.openableChapterSession(homeId),
      ...(options.machineId ? { machineId: options.machineId } : {}),
      ...(options.taskDiagnostic ? { diagnostic: options.taskDiagnostic } : {}),
      result: taskId => this.immutableTaskReport(taskId),
      evidence: scope => this.inboxEvidence(scope),
      wakeAvailable: homeId => this.wakeAvailable(homeId),
      wake: () => this.requestWake(),
    });
    this.materializer = new HomeChapterMaterializer(this, options.runtimes, options.trust, options.diagnostic);
    this.tasks = new HomeTaskDispatcher(store, authorization, options.runtimes, options.taskDiagnostic, this.inbox, options.taskPolicy);
  }

  async dispatchTask(sessionId: string, request: HomeTaskDispatchRequest, signal?: AbortSignal, confirm?: ConfirmChange) {
    await this.taskOwner();
    const record = this.record;
    if (this.unavailable || !record?.enabled || homeSessionId(record) !== sessionId) {
      throw new GatewayError("conflict", "Task dispatch is unavailable for this Home");
    }
    const choice = request.model || request.provenance ? request : { ...request, ...await this.currentChatChoice(sessionId),
      ...(request.thinking === undefined ? {} : { thinking: request.thinking }) };
    if (this.record !== record) throw new GatewayError("conflict", "Home changed during task admission");
    return this.tasks.start({ homeId: record.homeId, generation: record.generation, routeGeneration: record.routeGeneration }, choice, signal, confirm ? { confirm } : undefined);
  }

  async obligationTool(sessionId: string, callId: string, request: ObligationRequest): Promise<unknown> {
    admitObligation(request);
    return this.recordMutex.run(async () => {
      const record = this.record;
      if (this.unavailable || !record?.enabled || homeSessionId(record) !== sessionId) throw new GatewayError("conflict", "Home obligations are unavailable");
      const slot = await this.options.runtimes.acquire(sessionId);
      const branch = slot.sessionManager.getBranch();
      const items = new Map<string, import("./home-obligations.js").ObligationItem>();
      let count = 0;
      for (const chapter of (await this.readHomeSource()).chapters) {
        const entries = chapter.sessionId === sessionId ? branch : (await readCanonicalSession(chapter)).branch.map(entry => entry.raw as unknown as SessionEntry);
        count += entries.filter(entry => entry.type === "custom" && entry.customType === HOME_OBLIGATION).length;
        if (count > 10000) throw new GatewayError("conflict", "Home obligation history exceeds 10000 events; no partial list is available");
        replayObligations(entries, chapter.sessionId, items);
      }
      if (request.action === "list") {
        const result = { items: [...items.values()].filter(owed), total: items.size };
        if (Buffer.byteLength(JSON.stringify(result)) > 128 * 1024) throw new GatewayError("conflict", "Home owed list exceeds 128 KiB; no partial list is available");
        return result;
      }
      const activation = this.policies.get(sessionId)?.contextEvidence();
      if (!activation?.activationOpen || activation.kind !== "user") throw new GatewayError("invalid_request", "Obligation writes require the current maintainer turn, not a worker, trigger or old message");
      const start = activation.activationStartEntryId === null ? 0 : branch.findIndex(entry => entry.id === activation.activationStartEntryId) + 1;
      const source = branch.slice(start).find(entry => entry.type === "message" && entry.message.role === "user");
      const textOf = (entry: SessionEntry | undefined): string => {
        if (entry?.type !== "message" || (entry.message.role !== "user" && entry.message.role !== "toolResult")) return "";
        const content = entry.message.content;
        return typeof content === "string" ? content : content.filter(block => block.type === "text").map(block => block.text).join("\n");
      };
      if (!source || !textOf(source).includes(request.quote!)) throw new GatewayError("invalid_request", "Quote must be verbatim in this activation's maintainer message");
      const receiptId = `obligation-${createHash("sha256").update(`${sessionId}\0${callId}`).digest("hex")}`;
      const existing = branch.find(entry => entry.type === "custom" && entry.customType === HOME_OBLIGATION && (entry.data as ObligationEvent).receiptId === receiptId);
      const before = items.get(request.id!);
      if (existing?.type === "custom") {
        const event = existing.data as ObligationEvent;
        if (event.id !== request.id || event.action !== request.action || event.source.entryId !== source.id || event.source.quote !== request.quote
          || event.text !== request.text || event.issue !== request.issue || event.evidence?.entryId !== request.evidenceEntryId || event.evidence?.quote !== request.evidenceQuote) {
          throw new GatewayError("conflict", "Obligation receipt identity has different input");
        }
        return { item: before, receiptId };
      }
      if (count >= 10000 || (request.action === "request" && items.size >= 1000)) throw new GatewayError("conflict", "Home obligation history is full; no event was appended");
      if (request.action === "request" ? !!before : !before) throw new GatewayError("conflict", "Obligation id already exists or is unavailable; never re-create a closed item");
      if (request.action === "reopened") {
        if (owed(before!) || before!.latest.source.entryId === source.id) throw new GatewayError("conflict", "Reopening requires a new maintainer message for a closed obligation");
      } else if (before && !owed(before) && !(request.action === "verified" && before.state === "reported-done")) {
        throw new GatewayError("conflict", "The human action is already closed; missing proof cannot reopen it");
      }
      let evidence: ObligationEvent["evidence"];
      if (request.action === "verified") {
        const entry = branch.slice(start).find(candidate => candidate.id === request.evidenceEntryId);
        if (entry?.type !== "message" || entry.message.role !== "toolResult" || entry.message.isError || !textOf(entry).includes(request.evidenceQuote!)) throw new GatewayError("invalid_request", "Verification requires a successful tool result and verbatim evidence from this activation");
        evidence = { sessionId, entryId: entry.id, quote: request.evidenceQuote! };
      }
      const event: ObligationEvent = { receiptId, id: request.id!, action: request.action, source: { sessionId, entryId: source.id, quote: request.quote! },
        ...(request.text ? { text: request.text } : {}), ...(request.issue ? { issue: request.issue } : {}), ...(evidence ? { evidence } : {}) };
      await slot.persistCanonicalCustomEntry(HOME_OBLIGATION, JSON.parse(JSON.stringify(event)), receiptId);
      return { item: { id: event.id, text: before?.text ?? event.text!, ...(before?.issue || event.issue ? { issue: before?.issue ?? event.issue } : {}),
        state: event.action, request: before?.request ?? event.source, latest: event }, receiptId };
    });
  }

  private async currentChatChoice(sessionId: string) {
    const snapshot = (await this.options.runtimes.acquire(sessionId)).snapshot();
    const thinking = HOME_TASK_THINKING_LEVELS.find(level => level === snapshot.thinkingLevel);
    if (!snapshot.model || thinking === undefined) throw new GatewayError("conflict", "Home chat model is unavailable");
    return { model: { provider: snapshot.model.provider, id: snapshot.model.id }, thinking };
  }

  async recoverTasks(): Promise<void> {
    await this.tasks.recover();
    this.requestWake();
  }

  private async taskOwner(): Promise<HomeTaskDispatcher> {
    await this.tasks.assertAvailable();
    return this.tasks;
  }

  async taskPermissions() {
    const owner = await this.taskOwner();
    try { return await owner.permissions(); }
    catch (error) {
      if (error instanceof HomeTaskStoreError) throw new GatewayError("conflict", "Home task permissions refused", false, { reason: error.code });
      throw error;
    }
  }
  async revokeTaskScope(scopeId: string): Promise<{ accepted: true }> {
    await (await this.taskOwner()).revokeScope(scopeId); return { accepted: true };
  }
  async revokeTaskGrant(grantId: string): Promise<{ accepted: true }> {
    await (await this.taskOwner()).revokeGrant(grantId); return { accepted: true };
  }

  async reconfirmTaskPermissions(): Promise<{ reconfirmed: true }> {
    await (await this.taskOwner()).reconfirmPermissions();
    return { reconfirmed: true };
  }

  async steerTask(sessionId: string, control: TaskWorkerControl & { text: string }): Promise<void> {
    await this.taskOwner().catch(error => {
      if (error instanceof GatewayError) throw this.tasks.controlRefusal("steer", control, error);
      throw error;
    });
    const record = this.record;
    if (this.unavailable || !record?.enabled || homeSessionId(record) !== sessionId) throw this.tasks.controlRefusal("steer", control, new GatewayError("conflict", "Home task steering is unavailable"));
    const task = await this.tasks.store.read(control.taskId);
    if (!task || task.homeId !== record.homeId || task.generation !== record.generation) throw this.tasks.controlRefusal("steer", control, new GatewayError("conflict", "Home task generation changed"), "home-generation-changed");
    await this.tasks.steer(control, "tron-home");
  }

  async taskTool(sessionId: string, input: unknown, confirm?: ConfirmChange): Promise<unknown> {
    const request = admitHomeTaskToolRequest(input);
    const refuse = (error: GatewayError, reason?: TaskControlRefusalReason): GatewayError => {
      if ((request.action === "steer" || request.action === "interrupt" || request.action === "stop" || request.action === "rename") && request.taskId !== undefined) {
        this.tasks.controlRefusal(request.action, { taskId: request.taskId, ...(request.operationId === undefined ? {} : { operationId: request.operationId }) }, error, reason);
      }
      return error;
    };
    const owner = await this.taskOwner().catch(error => {
      if (error instanceof GatewayError) throw refuse(error);
      throw error;
    });
    const record = this.record;
    if (this.unavailable || !record?.enabled || homeSessionId(record) !== sessionId) throw refuse(new GatewayError("conflict", "Home task control is unavailable"));
    const { action } = request;
    if (action === "metrics") return readHomeTaskMetrics(this.tasks.store, record.homeId, request);
    if (action === "list" || (action === "status" && request.taskId === undefined)) {
      const catalog = await owner.controlCatalog(request.limit ?? 20).catch(error => {
        if (error instanceof HomeTaskStoreError && error.code === "not-initialized") return { tasks: [], counts: { active: 0, finished: 0 }, more: false };
        throw error;
      });
      return { ...catalog, workers: owner.workers(), host: owner.hostReading() };
    }
    const taskId = request.taskId!;
    const named = await this.tasks.store.read(taskId).catch(error => {
      if (error instanceof HomeTaskStoreError && error.code === "not-initialized") return undefined;
      throw error;
    });
    if (!named) {
      const similar = await owner.similarTaskIds(taskId).catch(() => []);
      throw refuse(new GatewayError("not_found", `task ${action}: no task "${taskId}". `
        + (similar.length ? `Close matches: ${similar.map(id => JSON.stringify(id)).join(", ")}. ` : "")
        + "Call {\"action\":\"list\"} for your tasks.", false, { taskId, similar }));
    }
    if (named.homeId !== record.homeId) throw refuse(new GatewayError("conflict", `task ${action}: "${taskId}" belongs to another Home`), "home-generation-changed");
    if (action === "status") return { control: await owner.controlRow(named, await this.continuation(named)), ...await this.taskStatus(taskId), host: owner.hostReading() };
    if (action === "transcript") {
      if (!named.sessionId) throw new GatewayError("not_found", "Task has no worker session");
      const binding = this.routeBinding();
      const source = await this.options.runtimes.readTaskWorkerTranscript(named.sessionId, request.subagentSessionId);
      this.assertRouteBinding(binding);
      const messages = projectBranch(source.entries.map(entry => parseEntry(JSON.stringify(entry))), EPISODIC_DEFAULTS, source.sessionId);
      const text = [...source.subagents.map(id => `subagentSessionId=${id}`), ...messages.map(message => `entry=${message.entryId} kind=${message.kind}\n${message.text}`)].join("\n\n");
      return { taskId: named.taskId, sessionId: source.sessionId, untrusted: true, thinking: "excluded", ...utf8Page(text, "task transcript", request.offset, request.limit) };
    }
    if (action === "report") {
      if (named.lifecycle !== "terminal") throw new GatewayError("conflict", `task report: "${taskId}" is ${named.lifecycle === "active" ? "still running" : "not started yet"}; it has no report until it settles`);
      const { text } = await this.immutableTaskReport(taskId);
      return { taskId: named.taskId, ...utf8Page(text, "task report", request.offset, request.limit) };
    }
    const continuedAs = await this.continuation(named);
    const task = continuedAs ? (await this.tasks.store.read(continuedAs)) ?? named : named;
    const row = await owner.controlRow(task);
    const resolved = task.taskId === named.taskId ? {} : { resolvedFrom: named.taskId };
    const state = `"${task.taskId}" is ${row.state}${row.outcome ? ` (${row.outcome}${row.reason ? `: ${row.reason}` : ""}${row.detail ? `, ${row.detail}` : ""})` : ""}`;
    if (!row.actions.includes(action)) {
      const hint = row.state === "running" ? "Use steer to message it, interrupt to cancel its current command, or stop to end it."
        : row.state === "settled" ? (row.actions.includes("resume") ? "Use resume to continue it in place." : "It never started a worker, so it cannot be resumed; delegate it again with a new taskId.")
        : "It is still starting; retry in a moment.";
      throw refuse(new GatewayError("conflict", `task ${action}: ${state}, so ${action} does not apply. ${hint}`, false, { ...row, ...resolved }), "action-unavailable");
    }
    if (request.operationId !== undefined && request.operationId !== row.operationId) {
      throw refuse(new GatewayError("conflict", `task ${action}: operationId guard ${JSON.stringify(request.operationId)} does not match ${state} with operation ${JSON.stringify(row.operationId)}. Omit operationId to act on the current operation.`, false, { ...row, ...resolved }), "operation-guard-mismatch");
    }
    const operationId = row.operationId!;
    try {
      if (action === "resume") {
        const resumed = await this.resumeTask({ taskId: task.taskId, operationId, ...(request.text === undefined ? {} : { text: request.text }) }, sessionId, undefined, [], confirm ? { confirm } : undefined);
        return { accepted: true, action, taskId: resumed.taskId, sessionId: resumed.sessionId, operationId: resumed.operationId,
          resumes: task.taskId, ...resolved };
      }
      if (task.generation !== record.generation) throw refuse(new GatewayError("conflict", "Home was re-designated after this task started; its controls belong to the earlier Home generation"), "home-generation-changed");
      if (action === "rename") {
        const renamed = await this.tasks.rename(task, request.title!);
        return { accepted: true, action, taskId: task.taskId, sessionId: task.sessionId, state: row.state, ...renamed, ...resolved };
      }
      if (action === "steer") await this.steerTask(sessionId, { taskId: task.taskId, operationId, text: request.text! });
      else if (action === "interrupt") {
        const { interrupted } = await this.tasks.interrupt({ taskId: task.taskId, operationId, ...(request.text === undefined ? {} : { text: request.text }) }, "tron-home");
        return { accepted: true, action, taskId: task.taskId, sessionId: task.sessionId, operationId, interrupted, ...resolved };
      }
      else await this.stopTask({ taskId: task.taskId, operationId });
    } catch (error) {
      if (!(error instanceof GatewayError)) throw error;
      const after = await this.tasks.store.read(task.taskId).catch(() => undefined);
      const now = after ? await owner.controlRow(after) : row;
      throw new GatewayError(error.code, `task ${action} "${task.taskId}" refused (${error.code}): ${error.message}. The task is now ${now.state}${now.reason ? ` (${now.reason})` : ""}.`, error.retryable, { ...now, ...resolved });
    }
    return { accepted: true, action, taskId: task.taskId, sessionId: task.sessionId, operationId, ...resolved };
  }

  async taskSettingsTarget(sessionId: string, taskId: string, purpose: "resolve" | "change"): Promise<{
    taskId: string; sessionId: string; operationId: string | null; state: string; resolvedFrom?: string;
  }> {
    await this.taskOwner();
    const record = this.record;
    if (this.unavailable || !record?.enabled || homeSessionId(record) !== sessionId) {
      throw new GatewayError("invalid_request", "settings: taskId targets a delegated worker and is available only in Tron Home");
    }
    const named = await this.tasks.store.read(taskId).catch(error => {
      if (error instanceof HomeTaskStoreError && error.code === "not-initialized") return undefined;
      throw error;
    });
    if (!named) {
      const similar = await this.tasks.similarTaskIds(taskId).catch(() => []);
      throw new GatewayError("not_found", `settings: no task "${taskId}". `
        + (similar.length ? `Close matches: ${similar.map(id => JSON.stringify(id)).join(", ")}. ` : "")
        + "Call task {\"action\":\"list\"} for your tasks.", false, { taskId, similar });
    }
    if (named.homeId !== record.homeId) throw new GatewayError("conflict", `settings: task "${taskId}" belongs to another Home`);
    const continuedAs = await this.continuation(named);
    const task = continuedAs ? (await this.tasks.store.read(continuedAs)) ?? named : named;
    if (purpose === "change" && task.generation !== record.generation) {
      throw new GatewayError("conflict", "settings: Home was re-designated after this task started; its worker belongs to the earlier Home generation");
    }
    if (!task.sessionId) throw new GatewayError("conflict", `settings: task "${task.taskId}" has not started a worker session yet; retry when task status shows its sessionId`, true);
    const row = await this.tasks.controlRow(task);
    return { taskId: task.taskId, sessionId: task.sessionId, operationId: task.operationId, state: row.state,
      ...(task.taskId === named.taskId ? {} : { resolvedFrom: named.taskId }) };
  }

  private async continuation(task: import("./home-task-store.js").HomeTaskRecord): Promise<string | undefined> {
    let current: string | undefined;
    for (let id = task.taskId; ;) {
      let next: string;
      try { next = successorTaskId(id); } catch { break; }
      const successor = await this.tasks.store.read(next);
      if (!successor?.resumes) break;
      if (successor.lifecycle !== "terminal" || successor.operationId !== null) current = successor.taskId;
      id = next;
    }
    return current;
  }

  async resumeTask(request: HomeTaskResumeRequest, sessionId?: string, workToken?: string, images: ImageContent[] = [], approval?: HomeTaskGrantApproval) {
    await this.taskOwner();
    const record = this.record;
    if (this.unavailable || !record?.enabled || (sessionId !== undefined && homeSessionId(record) !== sessionId)) {
      throw new GatewayError("conflict", "Task resume is unavailable for this Home");
    }
    return this.tasks.resume({ homeId: record.homeId, generation: record.generation, routeGeneration: record.routeGeneration }, request, { ...(workToken ? { exceptWorkToken: workToken } : {}), images, ...(approval ? { approval } : {}) });
  }

  async resumeWorkerSession(workerSessionId: string, text: string, workToken?: string, images: ImageContent[] = [], maintainerCommand?: string) {
    const task = await (await this.taskOwner()).latestTaskForSession(workerSessionId);
    if (!task) throw new GatewayError("conflict", "This session runs no Home task");
    if (task.lifecycle !== "terminal" || !task.operationId) {
      throw new GatewayError("busy", "The worker's task is still settling; send the message again in a moment", true);
    }
    return this.resumeTask({ taskId: task.taskId, operationId: task.operationId, text }, undefined, workToken, images, maintainerCommand ? { maintainerCommand } : undefined);
  }

  async latestWorkerTask(sessionId: string): Promise<{ taskId: string; lifecycle: string; operationId: string | null } | undefined> {
    const task = await (await this.taskOwner()).latestTaskForSession(sessionId);
    return task ? { taskId: task.taskId, lifecycle: task.lifecycle, operationId: task.operationId } : undefined;
  }

  async maintainTask(control: TaskWorkerControl & { text: string }): Promise<void> {
    await this.tasks.steer(control, "maintainer");
  }

  async interruptTask(control: TaskWorkerControl & { text?: string }): Promise<{ interrupted: string[] }> {
    return await this.tasks.interrupt(control, "maintainer");
  }

  async stopTask(control: TaskWorkerControl): Promise<void> {
    await this.tasks.stop(control);
  }

  async validateTaskMarker(sessionId: string, marker: unknown): Promise<void> {
    await (await this.taskOwner()).validateWorkerMarker(sessionId, marker);
  }

  private async immutableTaskReport(taskId: string): Promise<{ task: import("./home-task-store.js").HomeTaskRecord; title: string; text: string; subagents: HomeTaskSubagents }> {
    const task = await this.tasks.result(taskId);
    const report = task.reportRef;
    const entries = report && task.sessionId ? await this.options.runtimes.readTaskEvidence(task.sessionId, { appendStable: true }) : [];
    const entry = report && entries.find(entry => entry.id === report.entryId);
    return { task, title: (await this.tasks.display(task)).title, subagents: await this.tasks.subagents(task),
      text: entry?.type === "custom" ? JSON.stringify(entry.data) : JSON.stringify({ evidence: task.terminalEvidence, spend: task.spend }) };
  }

  async taskList(input: { limit?: number; cursor?: string; filter?: "all" | "open" | "finished" }, signal?: AbortSignal) {
    const owner = await this.taskOwner();
    if (this.unavailable) throw new GatewayError("conflict", "Home is unavailable", false, { reason: this.unavailable });
    try { return await owner.list(input, signal); }
    catch (error) {
      if (error instanceof HomeTaskStoreError) throw new GatewayError("conflict", "Home task list refused", false, { reason: error.code });
      throw error;
    }
  }

  async activeTaskTargets(signal?: AbortSignal): Promise<string[]> {
    const owner = await this.taskOwner();
    if (this.unavailable) throw new GatewayError("conflict", "Home is unavailable", false, { reason: this.unavailable });
    try { return await owner.activeTargets(signal); }
    catch (error) {
      if (error instanceof HomeTaskStoreError) throw new GatewayError("conflict", "Home task list refused", false, { reason: error.code });
      throw error;
    }
  }

  async taskHistory(input: { taskId: string; limit?: number; cursor?: string }, signal?: AbortSignal) {
    return (await this.taskOwner()).history(input, signal);
  }

  async taskResult(taskId: string) {
    return (await this.taskOwner()).result(taskId);
  }

  async taskStatus(taskId: string) {
    return (await this.taskOwner()).status(taskId);
  }

  private wakeRoute(sessionId?: string): HomeWakeRoute | undefined {
    const record = this.record;
    if (this.unavailable || !record || (sessionId && homeSessionId(record) !== sessionId)) return undefined;
    return { homeId: record.homeId, routeGeneration: record.routeGeneration, generation: record.generation,
      enabled: record.enabled, sessionId: homeSessionId(record) };
  }

  private async inboxAvailable(): Promise<boolean> {
    return (await this.tasks.recoveryStatus()).available;
  }

  triggerRoute() { return this.wakeRoute(); }
  notifyTrigger(): void { this.requestWake(); }
  async commitTriggerSources(sessionId: string, operationId: string): Promise<void> {
    for (const source of this.options.triggerSources?.() ?? []) await source.committed(sessionId, operationId);
  }

  async admitTaskResults(sessionId: string, operationId: string, delivery: InputDelivery, append: (message: InputMessage) => Promise<void>, envelope: () => Promise<InputEnvelope>): Promise<HomeWakeTrigger | InputTrigger | undefined> {
    const route = this.wakeRoute(sessionId);
    if (!route?.enabled) return undefined;
    let trigger: HomeWakeTrigger | undefined;
    if (await this.inboxAvailable()) {
      await this.inbox.recover(route);
      trigger = await this.inbox.admit(route, operationId, delivery, append, envelope);
    }
    if (trigger) return trigger;
    for (const source of this.options.triggerSources?.() ?? []) {
      if (!source.pending(route, delivery)) continue;
      const external = await source.admit(route, operationId, delivery, append, envelope);
      if (external) return external;
    }
    return undefined;
  }

  async releaseWakeTrigger(taskId: string, operationId: string, eventId: string): Promise<void> {
    for (const source of this.options.triggerSources?.() ?? []) await source.release(eventId, operationId);
    await this.inbox.releaseTrigger(taskId, operationId, eventId);
  }

  async settleTaskResults(sessionId: string, operationId: string): Promise<void> {
    await this.commitTriggerSources(sessionId, operationId);
    const route = this.wakeRoute(sessionId);
    if (route && await this.inboxAvailable()) await this.inbox.settle(route, operationId);
  }

  noteHomeIdle(sessionId: string, by: "user" | "wake"): void {
    if (!this.wakeRoute(sessionId)?.enabled) return;
    if (by === "user" || this.lastWakeDelivered) this.requestWake();
  }

  private requestWake(): void {
    this.wakeRequested = true;
    this.wakeDrain ??= this.drainWakes().catch(() => {
      this.wakeRequested = false;
      this.options.diagnostic?.({ outcome: "wake", decision: "refused", reason: "failed" });
    });
  }

  private async drainWakes(): Promise<void> {
    try {
      while (this.wakeRequested) {
        this.wakeRequested = false;
        if (await this.wakeOnce() === "busy") return;
      }
    } finally {
      this.wakeDrain = undefined;
    }
  }

  private async wakeOnce(): Promise<"busy" | "done"> {
    const record = this.record;
    if (this.unavailable || !record) return "done";
    const sessionId = homeSessionId(record);
    const wake = this.options.sessions.wakeHome(sessionId);
    const tasks = await this.inboxAvailable() && (await this.inbox.pendingTasks(record.homeId)).length > 0;
    const route = this.wakeRoute();
    const triggers = route && this.options.triggerSources?.().some(source => source.pending(route, "wake"));
    if (!tasks && !triggers) {
      this.lastWakeDelivered = false; return "done";
    }
    const refusal = this.reservedChapter(sessionId) === undefined && !(await this.options.runtimes.sessionPresent(sessionId)) ? "unavailable" : await this.homeRefusal(record);
    if (refusal) {
      this.lastWakeDelivered = false;
      this.options.diagnostic?.({ outcome: "wake", decision: "refused", reason: refusal });
      if (tasks) await this.inbox.pushPending(record.homeId, "task");
      return "done";
    }
    let delivered: boolean;
    try {
      if (this.reservedChapter(sessionId)) { await this.materializer.materialize(sessionId); await this.materializer.assertAttempt(sessionId); }
      ({ delivered } = await wake());
    } catch (error) {
      if (error instanceof GatewayError && error.code === "busy") {
        this.options.diagnostic?.({ outcome: "wake", decision: "deferred", reason: "busy" });
        return "busy";
      }
      this.lastWakeDelivered = false;
      this.options.diagnostic?.({ outcome: "wake", decision: "refused", reason: "failed" });
      if (tasks) await this.inbox.pushPending(record.homeId, "waiting");
      return "done";
    }
    this.lastWakeDelivered = delivered;
    if (!delivered) {
      this.options.diagnostic?.({ outcome: "wake", decision: "refused", reason: "nothing-deliverable" });
      if (tasks) await this.inbox.pushPending(record.homeId, "waiting");
    } else {
      this.options.diagnostic?.({ outcome: "wake", decision: "admitted", reason: "delivered" });
    }
    return "done";
  }

  private async homeRefusal(record: HomeRecord): Promise<"disabled" | "paused" | "blocked" | undefined> {
    if (!record.enabled) return "disabled";
    const memory = await this.memoryStatus();
    if (!memory.configured) return "blocked";
    if (memory.paused) return "paused";
    return undefined;
  }

  private async wakeAvailable(homeId: string): Promise<boolean> {
    const record = this.record;
    return record?.homeId === homeId && (await this.homeRefusal(record)) === undefined;
  }

  async redeliverTaskResult(taskId: string, expected: { homeId: string; routeGeneration: number }): Promise<{ accepted: true }> {
    await this.taskOwner();
    return this.recordMutex.run(async () => {
      const route = this.wakeRoute();
      if (!route || expected.homeId !== route.homeId || expected.routeGeneration !== route.routeGeneration) throw new GatewayError("conflict", "Home inbox route is unavailable or stale");
      await this.inbox.redeliver(taskId, route);
      return { accepted: true };
    });
  }

  private async inboxEvidence(scope: HomeWakeEvidenceScope): Promise<HomeWakeEvidence[]> {
    if (!this.record?.chapters.some(chapter => chapter.sessionId === scope.sessionId)) return [];
    const path = await this.options.runtimes.sessionFile(scope.sessionId);
    if (!path) return [];
    for (const durablePath of [path, dirname(path)]) {
      const handle = await open(durablePath, "r");
      try { await syncDurably(handle); } finally { await handle.close(); }
    }
    const entries: HomeWakeEvidence[] = [];
    await visitCanonicalSessionEntries({ path, sessionId: scope.sessionId, visit: entry => {
      const evidence = { ...entry.raw, type: entry.type, id: entry.id, sessionId: scope.sessionId } as HomeWakeEvidence;
      if (isWakeEvidence(scope, evidence)) entries.push(evidence);
    } });
    return entries;
  }

  async initialize(): Promise<void> {
    try {
      this.workspacePath = await realpath(this.workspacePath);
    } catch {
      try { this.workspacePath = join(await realpath(this.directory), "workspace"); } catch { }
    }
    await this.load();
  }

  async status(): Promise<HomeStatus> {
    const taskRecovery = await this.tasks.recoveryStatus();
    const hostPressure = this.tasks.hostPressure();
    const workers = this.tasks.workers();
    const memory = await this.memoryStatus();
    const activation = this.contextStatus();
    if (this.unavailable) {
      return {
        taskRecovery, hostPressure, workers, phase: "unavailable", activation, readiness: { ready: false, gaps: ["record-unavailable"] },
        recovery: { action: "inspect-record", reason: this.unavailable },
        available: false, reason: this.unavailable, enabled: false, live: false, sessionPresent: false, memory,
      };
    }
    const record = this.record;
    if (!record) return {
      taskRecovery, hostPressure, workers, phase: "undesignated", activation, readiness: { ready: false, gaps: ["not-designated"] },
      recovery: { action: "designate" },
      available: true, enabled: false, live: false, sessionPresent: false, memory,
    };
    const sessionId = homeSessionId(record);
    const currentChapter = record.chapters.at(-1)!;
    const live = this.options.runtimes.liveRuntime(sessionId) !== undefined;
    const sessionPresent = await this.options.runtimes.sessionPresent(sessionId);
    const openable = openableChapter(record);
    const openSessionPresent = openable === undefined ? false
      : openable === currentChapter ? sessionPresent : await this.options.runtimes.sessionPresent(openable.sessionId);
    const openSessionId = openable !== undefined && openSessionPresent ? openable.sessionId : undefined;
    const activeMetrics = sessionPresent && currentChapter.state === "active"
      ? await this.options.sessions.chapterMetrics(currentChapter.sessionId)
      : undefined;
    const gaps: string[] = [];
    if (!record.enabled) gaps.push("disabled");
    if (!sessionPresent) gaps.push("session-missing");
    if (!memory.configured) gaps.push("memory-not-configured");
    if (memory.blocked) gaps.push(`memory-${memory.blocked}`);
    if (memory.paused) gaps.push("memory-paused");
    const recovery: HomeStatus["recovery"] = !record.enabled || !sessionPresent
      ? { action: "designate", ...(!sessionPresent ? { reason: "Home session is missing" } : {}) }
      : !memory.configured ? { action: "configure-memory" }
        : memory.paused || memory.blocked ? { action: "resume-memory", reason: memory.paused ? "memory-paused" : memory.blocked! }
          : { action: "none" };
    const ready = gaps.length === 0;
    const phase: HomeStatus["phase"] = !record.enabled ? "disabled"
      : record.chapters.at(-1)!.state === "reserved" || record.chapters.at(-1)!.state === "materializing" ? "rollover-pending"
        : !sessionPresent ? "missing-session"
          : memory.blocked || !memory.configured ? "blocked"
          : activation.available && activation.activationOpen ? "active" : memory.paused ? "paused" : "ready";
    return {
      taskRecovery, hostPressure, workers, phase, activation, readiness: { ready, gaps }, recovery,
      available: true,
      enabled: record.enabled,
      homeId: record.homeId,
      sessionId,
      ...(openSessionId === undefined ? {} : { openSessionId }),
      bindingRevision: record.bindingRevision,
      generation: record.generation,
      routeGeneration: record.routeGeneration,
      live,
      sessionPresent,
      waitingForUser: openSessionId !== undefined && (this.options.runtimes.liveRuntime(openSessionId)?.catalogWaitingForUser ?? false),
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

  async profileList(): Promise<HomeProfileList> {
    const knowledge = this.options.knowledge();
    if (!knowledge) throw new GatewayError("unsupported", "Knowledge is not available on this Gateway");
    const read = await readHomeProfileIndex(knowledge);
    return {
      items: read.items,
      unclassified: read.unclassified,
    };
  }

  async chapterList(): Promise<HomeChapterList> {
    this.assertAvailable();
    const record = this.record;
    if (!record) throw new GatewayError("not_found", "Tron Home is not designated");
    const topics = await this.chapterTopics(record);
    const chapters: HomeChapterSummary[] = [];
    for (const chapter of record.chapters) {
      const sessionPresent = await this.options.runtimes.sessionPresent(chapter.sessionId);
      let bytes = chapter.sizeAtSeal;
      let entries = chapter.entriesAtSeal;
      if (chapter.state === "active" && sessionPresent) {
        const metrics = await this.options.sessions.chapterMetrics(chapter.sessionId);
        bytes = metrics.bytes;
        entries = metrics.entries;
      }
      const counts = await this.chapterContents.counts(chapter.sessionId,
        await this.options.runtimes.sessionFile(chapter.sessionId), chapter.state === "reserved");
      chapters.push({
        sessionId: chapter.sessionId,
        ordinal: chapter.ordinal,
        state: chapter.state,
        createdAt: chapter.createdAt,
        activationStarted: chapter.activationStarted,
        sessionPresent,
        ...(chapter.sealedAt === undefined ? {} : { sealedAt: chapter.sealedAt }),
        ...(bytes === undefined ? {} : { bytes }),
        ...(entries === undefined ? {} : { entries }),
        ...(counts === undefined ? {} : { contents: { ...counts, topics: topics.get(chapter.sessionId) ?? [] } }),
      });
    }
    return {
      homeId: record.homeId,
      generation: record.generation,
      enabled: record.enabled,
      limits: { softBytes: HOME_SOFT_BYTES, softEntries: HOME_SOFT_ENTRIES, hardBytes: HOME_HARD_BYTES, hardEntries: HOME_HARD_ENTRIES },
      chapters,
    };
  }

  private async chapterTopics(record: HomeRecord): Promise<Map<string, string[]>> {
    const memory = this.memory?.sessionId === record.homeId ? this.memory.owner : undefined;
    if (!memory) return new Map();
    try {
      const recent = await memory.browserRead(async episodic => episodic.recentSummaries(
        record.chapters.map(chapter => chapter.sessionId), HOME_CHAPTER_TOPIC_COUNT * 3));
      let budget = HOME_CHAPTER_TOPIC_LIST_CHARACTERS;
      const topics = new Map<string, string[]>();
      for (const chapter of [...record.chapters].reverse()) {
        const chosen = [...new Set((recent.get(chapter.sessionId) ?? []).map(homeChapterTopic).filter(Boolean))]
          .slice(0, HOME_CHAPTER_TOPIC_COUNT);
        const characters = chosen.reduce((sum, topic) => sum + topic.length, 0);
        if (characters > budget) break;
        budget -= characters;
        topics.set(chapter.sessionId, chosen);
      }
      return topics;
    } catch (error) {
      if (error instanceof GatewayError || error instanceof EpisodicMemoryError || error instanceof HomeMemoryRefusal) return new Map();
      throw error;
    }
  }

  isHomeChapter(sessionId: string): boolean {
    return this.record?.chapters.some(chapter => chapter.sessionId === sessionId) ?? false;
  }

  settingsPredecessor(sessionId: string): string | undefined {
    this.assertAvailable();
    const chapter = this.record?.chapters.find(candidate => candidate.sessionId === sessionId);
    if (!chapter || chapter.state !== "materializing") throw new GatewayError("conflict", "Home chapter is not materializing");
    if (chapter.ordinal === 1) return undefined;
    const previous = this.record?.chapters.find(candidate => candidate.ordinal === chapter.ordinal - 1);
    if (!previous || previous.state !== "sealed") throw new GatewayError("conflict", "Home settings predecessor is unavailable");
    return previous.sessionId;
  }

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

  noteRouteBound(category: Extract<HomeDiagnosticRecord, { outcome: "route-bound" }>["category"]): void {
    this.options.diagnostic?.({ outcome: "route-bound", category });
  }

  assertChapterAdmission(sessionId: string, metrics: { bytes: number; entries: number }): void {
    const chapter = this.record?.chapters.find(candidate => candidate.sessionId === sessionId);
    if (!chapter) return;
    const reason = metrics.bytes >= HOME_HARD_BYTES ? "hard-bytes"
      : metrics.entries >= HOME_HARD_ENTRIES ? "hard-entries" : undefined;
    if (!reason) return;
    this.options.diagnostic?.({ outcome: "chapter-refused", chapterOrdinal: chapter.ordinal, reason });
    throw new GatewayError("conflict", "This Home chapter has reached its hard limit; continue through Home", true, { reason });
  }

  async ensureChapterBelowHardLimit(): Promise<void> {
    const chapter = this.record?.chapters.at(-1);
    if (!chapter || chapter.state !== "active") return;
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
      if (chapter.state === "active" && !(await this.options.sessions.hasConversation(sessionId, expectedPath))) {
        this.options.diagnostic?.({ outcome: "chapter-refused", reason: "missing-conversation-evidence" });
        throw new GatewayError("conflict", "Published Home chapter lacks durable conversation evidence", true);
      }
    });
  }

  async assertPublishedHomeChapter(sessionId: string, expectedPath: string): Promise<void> {
    await this.recordMutex.run(async () => {
      const chapter = this.record?.chapters.find(candidate => candidate.sessionId === sessionId);
      if (chapter?.state !== "active" || !(await this.options.sessions.hasConversation(sessionId, expectedPath))) {
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

  reservedChapter(sessionId: string): HomeChapter | undefined {
    const chapter = this.record?.chapters.find(candidate => candidate.sessionId === sessionId);
    return chapter && (chapter.state === "reserved" || chapter.state === "materializing") ? { ...chapter } : undefined;
  }

  homeWorkspacePath(): string { return this.workspacePath; }

  private openableChapterSession(homeId: string): string | undefined {
    const record = this.record;
    return record?.homeId === homeId ? openableChapter(record)?.sessionId : undefined;
  }

  profileFor(sessionId: string, cwd?: string): HomeSessionProfile {
    const record = this.record;
    if (this.unavailable && cwd === this.workspacePath) {
      throw new GatewayError("conflict", `Tron Home is unavailable: ${this.unavailable}`);
    }
    if (!record || !record.chapters.some(chapter => chapter.sessionId === sessionId)) return "unnamed";
    return record.enabled ? "home" : "ordinary";
  }

  requestPolicyFor(sessionId: string): HomeRequestPolicy | undefined {
    const record = this.record;
    const designated = record !== undefined && record.enabled && record.chapters.some(chapter => chapter.sessionId === sessionId && (chapter.state === "active" || chapter.state === "materializing" || (chapter.state === "reserved" && chapter === record.chapters.at(-1))));
    if (!designated && !this.designating) return undefined;
    let policy = this.policies.get(sessionId);
    if (!policy) {
      policy = new HomeRequestPolicy({
        prepareMemoryView: (activation: HomeActivationIdentity, signal: AbortSignal | undefined) => this.memoryView(activation, signal),
        prepareSystemPrompt: async (base, activation) => homeSystemPrompt(base, this.options.knowledge, await this.currentChatChoice(sessionId), activation),
        ...(this.options.requestDiagnostic ? { onRecord: this.options.requestDiagnostic } : {}),
      });
      this.policies.set(sessionId, policy);
    }
    return policy;
  }

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

  async chapterQuiescent(sessionId: string): Promise<void> {
    const record = this.record;
    const chapter = record?.chapters.find(candidate => candidate.sessionId === sessionId);
    if (!record || !record.enabled || !chapter) return;
    if (chapter.state === "materializing" && chapter.attemptId && chapter.expectedPath) {
      const published = await this.publishObservedMaterialization(sessionId, chapter.attemptId, chapter.expectedPath);
      if (!published) this.options.diagnostic?.({ outcome: "chapter-refused", reason: "conversation-not-durable" });
      return;
    }
    if (chapter.state !== "active") return;
    const rolled = await this.options.runtimes.serializeSessionMutation(sessionId, async () => {
      const metrics = await this.options.sessions.chapterMetrics(sessionId);
      if (!metrics.quiescent || (metrics.bytes < HOME_SOFT_BYTES && metrics.entries < HOME_SOFT_ENTRIES
        && metrics.bytes < HOME_HARD_BYTES && metrics.entries < HOME_HARD_ENTRIES)) return undefined;
      const sealed = await this.recordMutex.run(async () => {
        const current = this.record;
        const active = current?.chapters.find(candidate => candidate.sessionId === sessionId);
        if (!current || !active || active.state !== "active") return false;
        const now = new Date().toISOString();
        const successor: HomeChapter = {
          sessionId: randomUUID(), ordinal: active.ordinal + 1, state: "reserved", createdAt: now, activationStarted: false,
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
    if (rolled) {
      this.options.diagnostic?.({
        outcome: "chapter-rollover", chapterOrdinal: chapter.ordinal,
        reason: rolled.bytes >= HOME_HARD_BYTES ? "hard-byte-limit"
          : rolled.entries >= HOME_HARD_ENTRIES ? "hard-entry-limit"
            : rolled.bytes >= HOME_SOFT_BYTES ? "soft-byte-limit" : "soft-entry-limit",
      });
      this.requestWake();
    }
  }

  async publishObservedMaterialization(sessionId: string, attemptId: string, expectedPath: string): Promise<boolean> {
    return this.recordMutex.run(async () => {
      const current = this.record;
      const chapter = current?.chapters.find(candidate => candidate.sessionId === sessionId);
      if (!current || !current.enabled || chapter?.state !== "materializing"
        || chapter.attemptId !== attemptId || chapter.expectedPath !== expectedPath) return false;
      const currentPath = await this.options.runtimes.sessionFile(sessionId);
      const observed = currentPath === expectedPath && await this.options.sessions.hasConversation(sessionId, expectedPath);
      if (!currentPath || currentPath !== expectedPath || !observed) return false;
      const now = new Date().toISOString();
      await this.writeLocked({
        ...current,
        chapters: current.chapters.map(candidate => candidate.sessionId === sessionId
          ? { sessionId, ordinal: candidate.ordinal, state: "active", createdAt: candidate.createdAt, activationStarted: candidate.activationStarted }
          : candidate),
        bindingRevision: current.bindingRevision + 1,
        updatedAt: now,
      });
      this.options.diagnostic?.({ outcome: "chapter-recovery", reason: "conversation-published" });
      return true;
    });
  }

  memoryToolsFor(sessionId: string): HomeMemoryToolAccess | undefined {
    const record = this.record;
    if (!record || !record.enabled || !record.chapters.some(chapter => chapter.sessionId === sessionId && (chapter.state === "active" || chapter.state === "materializing"))) return undefined;
    return {
      zoom: (id, n, signal) => this.toolMemory(sessionId, memory => memory.zoom(id, n, signal)),
      date: (id, signal) => this.toolMemory(sessionId, memory => memory.date(id, signal)),
      search: (query, from, to, signal) => this.toolMemory(sessionId, memory => memory.search(query, from, to, signal)),
    };
  }

  async pauseMemory(): Promise<HomeMemoryStatus> {
    return this.clientControl("pauseMemory", () => this.mutex.run(async () => {
      const record = await this.requireEnabledMemory();
      await this.commitMemoryPause(record, true);
      this.memory?.owner.notePause();
      return this.memoryStatus();
    }));
  }

  async resumeMemory(): Promise<HomeMemoryStatus> {
    return this.clientControl("resumeMemory", () => this.mutex.run(async () => {
      const record = await this.requireEnabledMemory();
      const owner = this.ownerFor(record.homeId);
      await owner.configure({ models: (await this.memoryModels())! });
      if (!record.memory?.paused && !owner.status().blocked) {
        throw new GatewayError("conflict", "Home memory is neither paused nor blocked");
      }
      await this.commitMemoryPause(record, false);
      try { await owner.resume(); }
      catch (error) {
        if (error instanceof HomeMemoryRefusal) throw new GatewayError("conflict", error.message);
        throw error;
      }
      this.requestWake();
      return this.memoryStatus();
    }));
  }

  private async requireEnabledMemory(): Promise<HomeRecord> {
    this.assertAvailable();
    const record = this.record;
    if (!record) throw new GatewayError("not_found", "Tron Home is not designated");
    if (!record.enabled) throw new GatewayError("conflict", "Tron Home is disabled: designate it before controlling its memory");
    if (!await this.memoryModels()) throw new GatewayError("conflict", "Home memory is not configured: set the background or subagent models (model.queue[role=background] or model.queue[role=subagent]) with settings.change");
    return record;
  }

  private async commitMemoryPause(record: HomeRecord, paused: boolean): Promise<void> {
    await this.options.runtimes.serializeSessionMutation(homeSessionId(record), () => this.recordMutex.run(async () => {
      const current = await this.requireEnabledMemory();
      if (current.homeId !== record.homeId) throw new GatewayError("conflict", "Tron Home changed during memory control");
      if (Boolean(current.memory?.paused) === paused) return;
      await this.writeLocked({
        ...current,
        memory: paused ? { paused: true } : {},
        updatedAt: new Date().toISOString(),
      });
    }));
  }

  private async memoryModels(): Promise<readonly string[] | undefined> {
    const models = await this.options.memoryModels();
    return models.length > 0 ? models : undefined;
  }

  private async clientControl<T>(operation: "pauseMemory" | "resumeMemory", run: () => Promise<T>): Promise<T> {
    try {
      const result = await run();
      this.options.diagnostic?.({ outcome: "client-control", operation, reason: "completed" });
      return result;
    } catch (error) {
      this.options.diagnostic?.({ outcome: "client-control", operation, reason: error instanceof GatewayError ? error.code : "failed" });
      throw error;
    }
  }

  async memoryStatus(): Promise<HomeMemoryStatus> {
    const record = this.record;
    if (!record) return { configured: false, open: false, paused: false };
    const paused = Boolean(record.memory?.paused);
    const models = await this.memoryModels();
    const owner = this.memory?.sessionId === record.homeId ? this.memory.owner : undefined;
    if (owner?.open && models) return { ...owner.status(), models: [...models], paused };
    const base: HomeMemoryStatus = models
      ? { configured: true, open: false, models: [...models] }
      : { configured: false, open: false };
    base.paused = paused;
    const persisted = await (owner ?? this.ownerFor(record.homeId)).persistedState().catch(() => undefined);
    if (!persisted) return base;
    return {
      ...base,
      spentTokens: persisted.spend,
      ...(persisted.blocked ? { blocked: persisted.blocked.reason } : {}),
    };
  }

  async readMemoryView(request: HomeMemoryViewRequest, signal?: AbortSignal): Promise<HomeMemoryView> {
    if (request.sessionId !== undefined && !this.record?.chapters.some(chapter => chapter.sessionId === request.sessionId)) {
      throw new GatewayError("not_found", "Session is not a chapter of Tron Home");
    }
    return this.browserRead(async (memory, source, proofs) => {
      const view = memory.browserView(request);
      const cursor = memory.browserCursor();
      if (!cursor) throw homeMemorySourceUnavailable("no-cursor");
      for (const line of view.lines) {
        if (!line.item) continue;
        const entry = await readCanonicalHomeEvidence(source, cursor, line.item.evidence, EPISODIC_DEFAULTS, signal, proofs);
        const display = homeMemoryToolDisplay(entry, line.item);
        if (display) line.item.display = display;
      }
      return view;
    }, signal);
  }

  async memoryEvidence(evidence: HomeMemoryEvidence, offset: number, signal?: AbortSignal): Promise<HomeMemoryEvidencePage> {
    return this.browserRead(async (memory, source, proofs) => {
      memory.assertBrowserEvidence(evidence);
      const cursor = memory.browserCursor();
      if (!cursor) throw homeMemorySourceUnavailable("no-cursor");
      const entry = await readCanonicalHomeEvidence(source, cursor, evidence, EPISODIC_DEFAULTS, signal, proofs);
      signal?.throwIfAborted();
      const { runtimeGeneration: _generation, entryId: _entryId, ...content } = historyEntry(
        { getEntry: id => id === entry.id ? entry.raw as unknown as SessionEntry : undefined },
        memory.browserRevision(), evidence.entryId, offset,
      );
      return { format: "canonical-history", evidence: { ...evidence }, ...content };
    }, signal);
  }

  private async browserRead<T>(read: (memory: EpisodicMemory, source: HomeSourceSnapshot, proofs: HomeSourceProofs) => Promise<T>, signal?: AbortSignal): Promise<T> {
    return this.mutex.run(async () => {
      signal?.throwIfAborted();
      this.assertAvailable();
      const record = this.record;
      const models = await this.memoryModels();
      if (!record || !models) throw new GatewayError("conflict", "Home memory is not configured");
      const owner = this.ownerFor(record.homeId);
      const proofs = this.memory!.proofs;
      try {
        await owner.configure({ models });
        signal?.throwIfAborted();
        return await owner.browserRead(async memory => {
          const cursor = memory.browserCursor();
          if (!cursor) throw homeMemorySourceUnavailable("no-cursor");
          const source = await this.readHomeSource();
          signal?.throwIfAborted();
          for await (const _entry of readCanonicalHomeIndex(source, cursor, EPISODIC_DEFAULTS, signal, proofs)) { }
          signal?.throwIfAborted();
          const result = await read(memory, source, proofs);
          signal?.throwIfAborted();
          if (this.record !== record || this.memory?.owner !== owner) throw homeMemoryRevisionChanged();
          return result;
        }, signal);
      } catch (error) {
        signal?.throwIfAborted();
        if (error instanceof GatewayError) throw error;
        if (error instanceof EpisodicMemoryError) throw homeMemorySourceUnavailable(`episodic-${error.kind}`);
        if (error instanceof EpisodicSourceChangedError) throw homeMemorySourceUnavailable("source-changed");
        if (error instanceof HomeMemoryRefusal) throw homeMemorySourceUnavailable(`refusal-${error.reason}`);
        throw error;
      }
    }, signal);
  }

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
      ...(step ? {
        viewLines: step.viewLines,
        viewBytes: step.viewBytes,
        effectiveTokens: step.effectiveTokens,
        contextWindow: step.contextWindow,
        breakdown: {
          activation: { state: evidence.activationOpen ? "running" : "settled", kind: evidence.kind, startedAt: evidence.startedAt },
          contextWindow: step.contextWindow,
          effectiveTokens: step.effectiveTokens,
          sections: step.sections.map(section => ({ ...section })),
        },
      } : {}),
      ...(evidence.refusal ? { lastRefusalReason: evidence.refusal.reason, lastRefusalDetail: evidence.refusal.detail } : {}),
    };
  }

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

  async dispose(): Promise<void> {
    this.policies.clear();
    await this.tasks.commands.dispose();
    const memory = this.memory;
    this.memory = undefined;
    await memory?.owner.dispose();
  }

  private async memoryView(activation: HomeActivationIdentity, signal: AbortSignal | undefined): Promise<HomeActivationView> {
    const record = this.record;
    if (!record || !record.enabled) {
      throw new HomeMemoryRefusal("memory-not-configured", "Tron Home is not enabled");
    }
    const models = await this.memoryModels();
    if (!models) {
      throw new HomeMemoryRefusal("memory-not-configured", "Home memory is not configured");
    }
    if (record.memory?.paused) {
      throw new HomeMemoryRefusal("memory-paused", "Home memory is paused; resume memory before sending another input");
    }
    const owner = this.ownerFor(record.homeId);
    const chapter = record.chapters.at(-1)!;
    const path = await this.options.runtimes.sessionFile(chapter.sessionId);
    const present = path ? await stat(path).then(() => true, error => { if ((error as NodeJS.ErrnoException).code === "ENOENT") return false; throw error; }) : false;
    if (!present && chapter.activationStarted) throw new HomeMemoryRefusal("memory-unavailable", "A started Home chapter has lost its canonical file");
    await owner.configure({ models });
    let view: HomeActivationView;
    if (!present && chapter.ordinal === 1) {
      view = owner.emptyChapterView(signal);
    } else if (!present) {
      view = await owner.precedingChapterView(signal);
    } else {
      view = await owner.activationView(activation, signal);
    }
    if (!chapter.activationStarted) await this.recordMutex.run(async () => {
      const current = this.record;
      if (!current || current.generation !== record.generation || current.chapters.at(-1)?.sessionId !== chapter.sessionId) throw new HomeMemoryRefusal("memory-unavailable", "Home chapter changed during activation admission");
      if (!current.chapters.at(-1)!.activationStarted) await this.writeLocked({ ...current,
        chapters: current.chapters.map(candidate => candidate.sessionId === chapter.sessionId ? { ...candidate, activationStarted: true } : candidate), updatedAt: new Date().toISOString() });
    });
    return view;
  }

  private async readHomeSource(): Promise<HomeSourceSnapshot> {
    const record = this.record;
    if (!record) throw new GatewayError("conflict", "Tron Home is unavailable");
    const chapters: HomeSourceChapter[] = [];
    for (const chapter of record.chapters) {
      if (chapter.state !== "sealed" && chapter.state !== "active" && chapter.state !== "materializing") continue;
      let path: string | undefined;
      try { path = await this.options.runtimes.sessionFile(chapter.sessionId); }
      catch (error) {
        if (chapter.state === "sealed" && !(error instanceof GatewayError)) throw new EpisodicMemoryError("source", `Sealed Home chapter ${chapter.sessionId} cannot be resolved: ${String(error)}`);
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
    const proofs = new HomeSourceProofs();
    const owner = new HomeMemory({
      workspace: this.options.workspace,
      sessionId: homeId,
      sessionFile: async () => {
        const chapters = this.record?.chapters ?? [];
        for (let i = chapters.length - 1; i >= 0; i--) {
          const chapter = chapters[i]!;
          const path = await this.options.runtimes.sessionFile(chapter.sessionId);
          if (path && await stat(path).then(info => info.isFile(), error => { if ((error as NodeJS.ErrnoException).code === "ENOENT") return false; throw error; })) return path;
        }
        return undefined;
      },
      sessionSource: {
        read: async function* (cursor, limits) { yield* readCanonicalHomeDeltas(await source(), cursor, limits); },
        branchAtCursor: async function* (cursor, limits) { yield* readCanonicalHomeIndex(await source(), cursor, limits, undefined, proofs); },
      },
      modelSummarizer: this.options.memorySummarizer,
      isPaused: () => Boolean(this.record?.memory?.paused),
      ...(this.options.memoryDiagnostic ? { diagnostic: this.options.memoryDiagnostic } : {}),
    });
    this.memory = { sessionId: homeId, owner, proofs };
    return owner;
  }

  private async releaseMemory(): Promise<void> {
    const memory = this.memory;
    this.memory = undefined;
    await memory?.owner.dispose().catch(() => {});
  }

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
        || await this.options.runtimes.sessionPresent(existingSessionId)
      )) {
        if (existing.enabled) {
          const current = input.model ? await this.options.sessions.homeModel() : undefined;
          if (input.model && current && (input.model.provider !== current.provider || input.model.id !== current.id)) {
            this.options.diagnostic?.({ outcome: "refused", reason: "model-change-requires-session-set-model" });
            throw new GatewayError("conflict", "Tron Home is already enabled with a different model; change its model through settings.change");
          }
          return designation(existing);
        }
        if (input.model) await this.options.sessions.chooseHomeModel(existingSessionId!, input.model);
        let next: HomeRecord | undefined;
        await this.commitProfileChange(existingSessionId!, current => {
          next = {
            ...current,
            enabled: true,
            generation: current.generation + 1,
            policyRevision: HOME_POLICY_REVISION,
            updatedAt: new Date().toISOString(),
          };
          return next;
        });
        if (!next) throw new Error("Home re-enable did not commit its record");
        this.options.diagnostic?.({ outcome: "enabled" });
        return designation(next);
      }

      const cwd = await this.ensureWorkspace();
      await this.options.trust.set(cwd, false);
      await this.releaseMemory();
      let sessionId: string;
      this.designating = true;
      try {
        sessionId = await this.options.sessions.createHomeSession(cwd);
      } finally {
        this.designating = false;
      }
      try {
        const startupModel = this.options.runtimes.liveRuntime(sessionId)?.snapshot().model ?? null;
        if (input.model || !startupModel) await this.options.sessions.chooseHomeModel(sessionId, input.model ?? defaultModel());
        const now = new Date().toISOString();
        const record: HomeRecord = {
          version: VERSION,
          homeId: existing?.homeId ?? randomUUID(),
          chapters: [
            ...(existing?.chapters.map(chapter => chapter.state === "active" ? { ...chapter, state: "sealed" as const, sealedAt: now } : chapter) ?? []),
            { sessionId, ordinal: (existing?.chapters.at(-1)?.ordinal ?? 0) + 1, state: "active", createdAt: now, activationStarted: false },
          ],
          bindingRevision: (existing?.bindingRevision ?? 0) + 1,
          generation: existing ? existing.generation + 1 : 1,
          routeGeneration: existing ? existing.routeGeneration + 1 : 1,
          policyRevision: HOME_POLICY_REVISION,
          enabled: true,
          ...(existing?.memory ? { memory: { ...existing.memory } } : {}),
          createdAt: existing?.createdAt ?? now,
          updatedAt: now,
        };
        await this.write(record);
        this.options.diagnostic?.({ outcome: "designated" });
        return designation(record);
      } catch (error) {
        await this.options.runtimes.replaceRuntimeForProfile(sessionId, async () => {}).catch(() => {});
        throw error;
      }
    });
  }

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
      await this.commitProfileChange(homeSessionId(existing), update);
      if (!next) throw new Error("Home disable did not commit its record");
      await this.releaseMemory();
      this.options.diagnostic?.({ outcome: "disabled" });
      return designation(next);
    });
  }

  private assertAvailable(): void {
    if (!this.unavailable) return;
    this.options.diagnostic?.({ outcome: "unavailable", reason: "owner-fenced" });
    throw new GatewayError("conflict", `Tron Home is unavailable: ${this.unavailable}. The existing record was preserved.`);
  }

  private async commitProfileChange(sessionId: string, update: (current: HomeRecord) => HomeRecord): Promise<void> {
    try {
      await this.options.runtimes.replaceRuntimeForProfile(sessionId, async () => {
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
    if (!admitHomeRecord(record)) throw new GatewayError("conflict", "The Home record is invalid or exceeds its chapter bounds");
    const chaptersBefore = chapterIdentities(this.record);
    try {
      await durablePublishBoundedJson(this.recordPath, record, MAXIMUM_RECORD_BYTES);
    } catch (error) {
      if (isDurablePublicationUncertain(error)) {
        this.unavailable = "Home ledger publication is being reconciled";
        this.publicationUncertain = true;
        const reloaded = await this.load(false);
        this.options.runtimes.noteSessionListChanged();
        const retirement = Promise.resolve()
          .then(() => this.options.sessions.retireHomeRuntimes())
          .then(() => {
            this.publicationUncertain = !reloaded;
            if (reloaded) this.unavailable = undefined;
          })
          .catch(error => {
            this.unavailable = "Home runtime retirement failed after ledger publication uncertainty";
            this.options.diagnostic?.({ outcome: "unavailable", reason: "publication-retirement-failed" });
            throw error;
          });
        void retirement.catch(() => {});
      }
      if (error instanceof Error && error.message === "JSON document exceeds its byte limit") {
        throw new GatewayError("conflict", "The Home chapter ledger exceeds its persisted size limit");
      }
      throw error;
    }
    this.record = record;
    if (chapterIdentities(record) !== chaptersBefore) this.options.runtimes.noteSessionListChanged();
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
      if (clearAvailability) this.record = undefined;
      this.unavailable = error instanceof SecureJsonFileError && error.kind === "invalid"
        ? "The Home record is malformed"
        : "The Home record is not a bounded owner-only regular file";
      this.options.diagnostic?.({ outcome: "unavailable", reason: "unreadable" });
      return false;
    }
    const admitted = admitHomeRecord(loaded);
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

function openableChapter(record: HomeRecord): HomeChapter | undefined {
  const current = record.chapters.at(-1);
  return current?.state === "reserved" || current?.state === "materializing" ? record.chapters.at(-2) : current;
}

function chapterIdentities(record: HomeRecord | undefined): string {
  return record?.chapters.map(chapter => chapter.sessionId).join("\n") ?? "";
}

function homeSessionId(record: HomeRecord): string {
  return record.chapters.find(chapter => chapter.state === "active")?.sessionId
    ?? record.chapters.at(-1)!.sessionId;
}

function designation(record: HomeRecord): HomeDesignation {
  return { homeId: record.homeId, sessionId: homeSessionId(record), generation: record.generation };
}

function admitHomeRecord(value: unknown): HomeRecord | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const root = value as Record<string, unknown>;
  if (!hasOnlyKeys(root, ["version", "homeId", "chapters", "bindingRevision", "generation", "routeGeneration", "policyRevision", "enabled", "createdAt", "updatedAt", "memory"])
    || root.version !== VERSION
    || !boundedString(root.homeId, 200)
    || !Number.isSafeInteger(root.bindingRevision) || (root.bindingRevision as number) < 1
    || !Number.isSafeInteger(root.generation) || (root.generation as number) < 1
    || !Number.isSafeInteger(root.routeGeneration) || (root.routeGeneration as number) < 1
    || !Number.isSafeInteger(root.policyRevision) || (root.policyRevision as number) < 1
    || typeof root.enabled !== "boolean"
    || !boundedTimestamp(root.createdAt)
    || !boundedTimestamp(root.updatedAt)
    || !Array.isArray(root.chapters) || root.chapters.length === 0 || root.chapters.length > HOME_MAX_CHAPTERS) return undefined;
  const chapters = admitChapters(root.chapters);
  if (!chapters) return undefined;
  const memory = admitMemory(root.memory);
  if (memory === null) return undefined;
  return {
    version: VERSION,
    homeId: root.homeId,
    chapters,
    bindingRevision: root.bindingRevision as number,
    generation: root.generation as number,
    routeGeneration: root.routeGeneration as number,
    policyRevision: root.policyRevision as number,
    enabled: root.enabled,
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
    if (typeof chapter.activationStarted !== "boolean" || !hasOnlyKeys(chapter, ["sessionId", "ordinal", "state", "createdAt", "activationStarted", "sealedAt", "sizeAtSeal", "entriesAtSeal", "attemptId", "expectedPath"])
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
      createdAt: chapter.createdAt as string, activationStarted: chapter.activationStarted as boolean,
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

function admitMemory(value: unknown): HomeRecord["memory"] | null {
  if (value === undefined) return undefined;
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const record = value as Record<string, unknown>;
  if (!hasOnlyKeys(record, ["paused"]) || (record.paused !== undefined && record.paused !== true)) return null;
  return record.paused === true ? { paused: true } : {};
}
