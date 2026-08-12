import { randomUUID } from "node:crypto";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import type { ImageContent, Model } from "@earendil-works/pi-ai";
import {
  AgentSessionRuntime,
  createAgentSessionFromServices,
  createAgentSessionRuntime,
  createAgentSessionServices,
  type AgentSessionEvent,
  type CreateAgentSessionRuntimeFactory,
  type ExtensionCommandContextActions,
  type ModelRuntime,
  type SessionManager,
} from "@earendil-works/pi-coding-agent";
import { GatewayError } from "../errors.js";
import type {
  CommandInfo,
  JsonValue,
  RetryState,
  SessionOperationState,
  SessionPhase,
  SessionSnapshot,
  SessionTreeNode,
  ToolExecutionState,
} from "../protocol/types.js";
import { AsyncMutex } from "../util/async-mutex.js";
import type { TrustService } from "../admin/trust-service.js";
import type { BlobStore } from "./blob-store.js";
import { ExtensionUIBroker } from "./extension-ui.js";
import { projectMessage, projectTranscriptPage, projectTree, safeJson, type TranscriptPage } from "./projection.js";
import type { RunMarkerStore } from "./run-markers.js";

export type SessionBroadcast = (sessionId: string, topic: string, payload: JsonValue) => void;

export interface RuntimeSlotHooks {
  broadcast: SessionBroadcast;
  changed: (sessionId: string) => void;
  settled: (sessionId: string) => void;
  rekey: (previousId: string, nextId: string, slot: RuntimeSlot) => void;
}

export interface RuntimeSlotDependencies {
  agentDir: string;
  createModelRuntime: () => Promise<ModelRuntime>;
  trust: TrustService;
  blobs: BlobStore;
  markers: RunMarkerStore;
}

/**
 * Owns one live Pi runtime and the reconnect-safe mobile projection for its
 * canonical JSONL session. Every mutation runs through `lane`; distinct slots
 * remain concurrent.
 */
export class RuntimeSlot {
  private runtime!: AgentSessionRuntime;
  private unsubscribe: (() => void) | undefined;
  private readonly lane = new AsyncMutex();
  private readonly ui: ExtensionUIBroker;
  private readonly runtimeGeneration = randomUUID();
  private revision = 0;
  private eventSequence = 0;
  private phase: SessionPhase;
  private disposed = false;
  private snapshotTimer: NodeJS.Timeout | undefined;
  private activeOperationId: string | undefined;
  private operation: SessionOperationState | undefined;
  private retry: RetryState | undefined;
  private readonly toolExecutions = new Map<string, ToolExecutionState>();
  private lastTouchedAt = Date.now();

  private constructor(
    private sessionManager: SessionManager,
    private readonly dependencies: RuntimeSlotDependencies,
    private readonly hooks: RuntimeSlotHooks,
    interrupted: boolean,
  ) {
    this.phase = interrupted ? "interrupted" : "idle";
    this.ui = new ExtensionUIBroker((topic, payload) => {
      this.revision += 1;
      this.emit(topic, payload);
    });
  }

  static async create(
    sessionManager: SessionManager,
    dependencies: RuntimeSlotDependencies,
    hooks: RuntimeSlotHooks,
    interrupted: boolean,
  ): Promise<RuntimeSlot> {
    const slot = new RuntimeSlot(sessionManager, dependencies, hooks, interrupted);
    await slot.initialize();
    return slot;
  }

  get id(): string {
    return this.runtime?.session.sessionId ?? this.sessionManager.getSessionId();
  }

  get cwd(): string {
    return this.runtime?.cwd ?? this.sessionManager.getCwd();
  }

  get modelRuntime(): ModelRuntime {
    return this.runtime.session.modelRuntime;
  }

  get isBusy(): boolean {
    return this.phase === "running" || this.phase === "compacting" || this.phase === "retrying" || this.runtime?.session.isBashRunning === true;
  }

  get touchedAt(): number {
    return this.lastTouchedAt;
  }

  get sessionFile(): string | undefined {
    return this.runtime.session.sessionFile;
  }

  sessionEnvironment(): Record<string, string> {
    const session = this.runtime.session;
    return {
      PI_SESSION_ID: session.sessionId,
      ...(session.sessionFile ? { PI_SESSION_FILE: session.sessionFile } : {}),
      PI_CWD: this.cwd,
      ...(session.model ? { PI_PROVIDER: session.model.provider, PI_MODEL: session.model.id } : {}),
      PI_REASONING_LEVEL: session.thinkingLevel,
    };
  }

  touch(): void {
    this.lastTouchedAt = Date.now();
  }

  private runtimeFactory(): CreateAgentSessionRuntimeFactory {
    return async ({ cwd, sessionManager, sessionStartEvent }) => {
      const trust = await this.dependencies.trust.requireResolved(cwd);
      // A ModelRuntime is scoped to one Pi session runtime. Extension provider
      // registration is mutable, so sharing one instance across projects would
      // leak project providers between concurrent Tron sessions. Credentials and
      // model files remain canonical through their shared file paths.
      const modelRuntime = await this.dependencies.createModelRuntime();
      const services = await createAgentSessionServices({
        cwd: trust.cwd,
        agentDir: this.dependencies.agentDir,
        modelRuntime,
        resourceLoaderReloadOptions: { resolveProjectTrust: async () => trust.trusted },
      });
      const created = await createAgentSessionFromServices({
        services,
        sessionManager,
        ...(sessionStartEvent ? { sessionStartEvent } : {}),
      });
      return { ...created, services, diagnostics: services.diagnostics };
    };
  }

  private async initialize(): Promise<void> {
    this.runtime = await createAgentSessionRuntime(this.runtimeFactory(), {
      cwd: this.sessionManager.getCwd(),
      agentDir: this.dependencies.agentDir,
      sessionManager: this.sessionManager,
      sessionStartEvent: { type: "session_start", reason: "resume" },
    });
    this.runtime.setRebindSession(async () => this.bindSession());
    await this.bindSession();
  }

  private commandActions(): ExtensionCommandContextActions {
    return {
      waitForIdle: () => this.runtime.session.waitForIdle(),
      newSession: (options) => this.runtime.newSession(options),
      fork: (entryId, options) => this.runtime.fork(entryId, options),
      navigateTree: (targetId, options) => this.runtime.session.navigateTree(targetId, options),
      switchSession: (sessionPath, options) => this.runtime.switchSession(sessionPath, options),
      reload: () => this.runtime.session.reload(),
    };
  }

  private async bindSession(): Promise<void> {
    const previousId = this.runtime?.session.sessionId ?? this.sessionManager.getSessionId();
    this.unsubscribe?.();
    const session = this.runtime.session;
    this.sessionManager = session.sessionManager;
    await session.bindExtensions({
      uiContext: this.ui.context(),
      mode: "rpc",
      commandContextActions: this.commandActions(),
      abortHandler: () => void this.abort(),
      shutdownHandler: () => this.emit("session.notification", { type: "warning", message: "An extension requested shutdown; Tron kept running" }),
      onError: (error) => this.emit("session.extensionError", safeJson(error)),
    });
    this.unsubscribe = session.subscribe((event) => this.onEvent(event));
    const nextId = session.sessionId;
    if (previousId !== nextId) this.hooks.rekey(previousId, nextId, this);
    this.revision += 1;
    this.publishSnapshot();
  }

  private emit(topic: string, data: JsonValue): void {
    this.eventSequence += 1;
    this.hooks.broadcast(this.id, topic, {
      runtimeGeneration: this.runtimeGeneration,
      eventSequence: this.eventSequence,
      revision: this.revision,
      data,
    });
  }

  private onEvent(event: AgentSessionEvent): void {
    this.revision += 1;
    this.touch();
    switch (event.type) {
      case "agent_start":
        this.phase = "running";
        this.activeOperationId ??= randomUUID();
        this.operation ??= { id: this.activeOperationId, kind: "prompt", startedAt: new Date().toISOString() };
        void this.dependencies.markers.mark(this.id, this.activeOperationId);
        this.publishSnapshot();
        break;
      case "agent_settled":
        this.phase = "idle";
        this.activeOperationId = undefined;
        this.operation = undefined;
        this.retry = undefined;
        this.toolExecutions.clear();
        void this.dependencies.markers.clear(this.id);
        this.hooks.settled(this.id);
        this.publishSnapshot();
        this.hooks.changed(this.id);
        break;
      case "compaction_start":
        this.phase = "compacting";
        this.operation = { kind: "compaction", startedAt: new Date().toISOString(), reason: event.reason };
        this.publishSnapshot();
        break;
      case "compaction_end":
        this.retry = undefined;
        this.emit("session.compaction", safeJson(event));
        this.scheduleSnapshot();
        break;
      case "auto_retry_start":
        this.phase = "retrying";
        this.retry = {
          source: "agent",
          attempt: event.attempt,
          maxAttempts: event.maxAttempts,
          delayMs: event.delayMs,
          errorMessage: event.errorMessage,
        };
        this.operation = { kind: "retry", startedAt: new Date().toISOString() };
        this.publishSnapshot();
        break;
      case "summarization_retry_scheduled":
        this.phase = "retrying";
        this.retry = {
          source: this.operation?.kind === "branchSummary" ? "branchSummary" : "compaction",
          attempt: event.attempt,
          maxAttempts: event.maxAttempts,
          delayMs: event.delayMs,
          errorMessage: event.errorMessage,
        };
        this.publishSnapshot();
        break;
      case "summarization_retry_attempt_start":
        this.retry = this.retry ? { ...this.retry, source: event.source } : { source: event.source, attempt: 1 };
        this.publishSnapshot();
        break;
      case "summarization_retry_finished":
        this.retry = undefined;
        this.scheduleSnapshot();
        break;
      case "auto_retry_end":
        this.emit("session.retry", safeJson(event));
        if (!event.success) {
          this.phase = "idle";
          this.operation = undefined;
        }
        this.retry = undefined;
        this.scheduleSnapshot();
        break;
      case "message_update": {
        const message = projectMessage("streaming", null, new Date().toISOString(), event.message, this.dependencies.blobs);
        this.emit("session.progress", safeJson({ message }));
        break;
      }
      case "tool_execution_start": {
        const now = new Date().toISOString();
        const state: ToolExecutionState = {
          toolCallId: event.toolCallId,
          toolName: event.toolName,
          status: "running",
          arguments: safeJson(event.args),
          isError: false,
          startedAt: now,
          updatedAt: now,
        };
        this.toolExecutions.set(event.toolCallId, state);
        this.emit("session.toolProgress", safeJson(state));
        this.scheduleSnapshot();
        break;
      }
      case "tool_execution_update": {
        const now = new Date().toISOString();
        const existing = this.toolExecutions.get(event.toolCallId);
        const state: ToolExecutionState = {
          toolCallId: event.toolCallId,
          toolName: event.toolName,
          status: "running",
          arguments: safeJson(event.args),
          partialResult: safeJson(event.partialResult),
          isError: false,
          startedAt: existing?.startedAt ?? now,
          updatedAt: now,
        };
        this.toolExecutions.set(event.toolCallId, state);
        this.emit("session.toolProgress", safeJson(state));
        break;
      }
      case "tool_execution_end": {
        const now = new Date().toISOString();
        const existing = this.toolExecutions.get(event.toolCallId);
        const state: ToolExecutionState = {
          toolCallId: event.toolCallId,
          toolName: event.toolName,
          status: event.isError ? "failed" : "completed",
          arguments: existing?.arguments ?? null,
          ...(existing?.partialResult === undefined ? {} : { partialResult: existing.partialResult }),
          result: safeJson(event.result),
          isError: event.isError,
          startedAt: existing?.startedAt ?? now,
          updatedAt: now,
        };
        this.toolExecutions.set(event.toolCallId, state);
        this.emit("session.toolProgress", safeJson(state));
        this.scheduleSnapshot();
        break;
      }
      case "bash_execution_update":
        this.emit("session.bashProgress", safeJson(event));
        break;
      case "entry_appended":
      case "message_end":
      case "queue_update":
      case "thinking_level_changed":
      case "session_info_changed":
        this.scheduleSnapshot();
        break;
      default:
        break;
    }
  }

  private scheduleSnapshot(): void {
    if (this.snapshotTimer) return;
    this.snapshotTimer = setTimeout(() => {
      this.snapshotTimer = undefined;
      this.publishSnapshot();
    }, 20);
  }

  snapshot(sequence = this.eventSequence): SessionSnapshot {
    const session = this.runtime.session;
    const contextUsage = session.getContextUsage();
    const stats = session.getSessionStats();
    const streaming = session.state.streamingMessage
      ? projectMessage("streaming", null, new Date().toISOString(), session.state.streamingMessage, this.dependencies.blobs)
      : undefined;
    const transcriptPage = this.transcriptPage();
    return {
      sessionId: session.sessionId,
      runtimeGeneration: this.runtimeGeneration,
      revision: this.revision,
      eventSequence: sequence,
      phase: this.phase,
      ...(session.sessionName ? { name: session.sessionName } : {}),
      cwd: session.sessionManager.getCwd(),
      ...(session.sessionManager.getHeader()?.parentSession ? { parentSessionId: session.sessionManager.getHeader()!.parentSession } : {}),
      ...(session.model ? { model: { provider: session.model.provider, id: session.model.id } } : {}),
      thinkingLevel: session.thinkingLevel,
      availableThinkingLevels: session.getAvailableThinkingLevels(),
      ...(contextUsage ? { contextUsage } : {}),
      stats: {
        userMessages: stats.userMessages,
        assistantMessages: stats.assistantMessages,
        toolCalls: stats.toolCalls,
        toolResults: stats.toolResults,
        totalMessages: stats.totalMessages,
        tokens: stats.tokens,
        cost: stats.cost,
      },
      queued: { steering: [...session.getSteeringMessages()], followUp: [...session.getFollowUpMessages()] },
      transcript: transcriptPage.items,
      transcriptStart: transcriptPage.start,
      transcriptTotal: transcriptPage.total,
      ...(streaming ? { streaming } : {}),
      ...(session.sessionManager.getLeafId() ? { leafEntryId: session.sessionManager.getLeafId()! } : {}),
      ...(this.operation ? { operation: this.operation } : {}),
      ...(this.retry ? { retry: this.retry } : {}),
      toolExecutions: [...this.toolExecutions.values()],
      extensionUI: this.ui.state(),
      diagnostics: this.runtime.diagnostics.map((diagnostic) => ({ type: diagnostic.type, message: diagnostic.message })),
    };
  }

  transcriptPage(before?: number): TranscriptPage {
    return projectTranscriptPage(this.runtime.session.sessionManager, this.dependencies.blobs, before);
  }

  publishSnapshot(): void {
    if (this.disposed) return;
    this.eventSequence += 1;
    this.hooks.broadcast(this.id, "session.snapshot", this.snapshot(this.eventSequence) as unknown as JsonValue);
  }

  async prompt(text: string, images: ImageContent[] = [], behavior?: "steer" | "followUp"): Promise<{ operationId: string }> {
    return this.lane.run(async () => {
      this.assertUsable();
      const session = this.runtime.session;
      if (session.isStreaming && !behavior) throw new GatewayError("busy", "Session is running; choose steer or follow-up");
      const operationId = randomUUID();
      this.activeOperationId = operationId;
      this.operation = { id: operationId, kind: "prompt", startedAt: new Date().toISOString() };
      let acceptedResolve!: (accepted: boolean) => void;
      const accepted = new Promise<boolean>((resolve) => { acceptedResolve = resolve; });
      const run = session.prompt(text, {
        images,
        ...(behavior ? { streamingBehavior: behavior } : {}),
        source: "rpc",
        preflightResult: acceptedResolve,
      });
      void run.catch((error) => {
        this.emit("session.operationFailed", safeJson({ operationId, message: error instanceof Error ? error.message : String(error) }));
        if (!session.isStreaming) {
          this.phase = "idle";
          this.activeOperationId = undefined;
          this.operation = undefined;
          void this.dependencies.markers.clear(this.id);
          this.hooks.settled(this.id);
          this.publishSnapshot();
        }
      });
      const admitted = await Promise.race([
        accepted,
        new Promise<boolean>((_, reject) => setTimeout(() => reject(new GatewayError("internal", "The agent runtime did not complete prompt preflight")), 5_000)),
      ]);
      if (!admitted) {
        this.operation = undefined;
        throw new GatewayError("invalid_request", "The agent runtime rejected the prompt before admission");
      }
      await this.dependencies.markers.mark(this.id, operationId);
      this.revision += 1;
      this.publishSnapshot();
      return { operationId };
    });
  }

  async abort(kind: "agent" | "compaction" | "retry" | "branchSummary" | "bash" = "agent"): Promise<void> {
    this.assertUsable();
    const session = this.runtime.session;
    switch (kind) {
      case "compaction": session.abortCompaction(); break;
      case "retry": session.abortRetry(); break;
      case "branchSummary": session.abortBranchSummary(); break;
      case "bash": session.abortBash(); break;
      case "agent": await session.abort(); break;
    }
    this.revision += 1;
    this.publishSnapshot();
  }

  clearQueue(): { steering: string[]; followUp: string[] } {
    this.assertUsable();
    const cleared = this.runtime.session.clearQueue();
    this.revision += 1;
    this.publishSnapshot();
    return { steering: [...cleared.steering], followUp: [...cleared.followUp] };
  }

  async setModel(provider: string, modelId: string): Promise<void> {
    await this.lane.run(async () => {
      this.assertIdle();
      const model = this.runtime.session.modelRuntime.getModel(provider, modelId);
      if (!model) throw new GatewayError("not_found", "Model is not registered in Tron");
      await this.runtime.session.setModel(model as Model<never>);
      this.revision += 1;
      this.publishSnapshot();
    });
  }

  async setThinking(level: "off" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max"): Promise<void> {
    await this.lane.run(() => {
      this.assertIdle();
      this.runtime.session.setThinkingLevel(level);
      this.revision += 1;
      this.publishSnapshot();
    });
  }

  async setTools(toolNames: string[]): Promise<void> {
    await this.lane.run(() => {
      this.assertIdle();
      const known = new Set(this.runtime.session.getAllTools().map((tool) => tool.name));
      const unknown = toolNames.filter((name) => !known.has(name));
      if (unknown.length > 0) throw new GatewayError("invalid_request", `Unknown agent tools: ${unknown.join(", ")}`);
      this.runtime.session.setActiveToolsByName(toolNames);
      this.revision += 1;
      this.publishSnapshot();
    });
  }

  async compact(instructions?: string): Promise<void> {
    await this.lane.run(async () => {
      this.assertIdle();
      this.phase = "compacting";
      this.operation = { kind: "compaction", startedAt: new Date().toISOString(), reason: "manual" };
      this.revision += 1;
      this.publishSnapshot();
      try {
        await this.runtime.session.compact(instructions);
      } finally {
        this.phase = "idle";
        this.operation = undefined;
        this.retry = undefined;
        this.revision += 1;
        this.publishSnapshot();
      }
    });
  }

  async executeBash(command: string, excludeFromContext: boolean): Promise<JsonValue> {
    return this.lane.run(async () => {
      this.assertIdle();
      const operationId = randomUUID();
      this.phase = "running";
      this.operation = { id: operationId, kind: "bash", startedAt: new Date().toISOString() };
      this.revision += 1;
      this.publishSnapshot();
      try {
        return safeJson(await this.runtime.session.executeBash(command, undefined, { excludeFromContext, id: operationId }));
      } finally {
        this.phase = "idle";
        this.operation = undefined;
        this.revision += 1;
        this.publishSnapshot();
      }
    });
  }

  async rename(name: string): Promise<void> {
    await this.lane.run(() => {
      this.assertUsable();
      this.runtime.session.setSessionName(name);
      this.revision += 1;
      this.publishSnapshot();
      this.hooks.changed(this.id);
    });
  }

  async setLabel(entryId: string, label?: string): Promise<void> {
    await this.lane.run(() => {
      this.assertIdle();
      if (!this.sessionManager.getEntry(entryId)) throw new GatewayError("not_found", "Session entry was not found");
      this.sessionManager.appendLabelChange(entryId, label?.trim() || undefined);
      this.revision += 1;
      this.publishSnapshot();
    });
  }

  async fork(entryId: string, position: "before" | "at" = "at"): Promise<{ sessionId: string; selectedText?: string }> {
    return this.lane.run(async () => {
      this.assertIdle();
      const previous = this.id;
      const result = await this.runtime.fork(entryId, { position });
      if (result.cancelled) throw new GatewayError("cancelled", "Fork was cancelled by an extension");
      const next = this.id;
      if (previous !== next) this.hooks.rekey(previous, next, this);
      this.revision += 1;
      this.publishSnapshot();
      return { sessionId: next, ...(result.selectedText ? { selectedText: result.selectedText } : {}) };
    });
  }

  async navigate(
    targetId: string,
    options: { summarize: boolean; instructions?: string; replaceInstructions?: boolean; label?: string },
  ): Promise<{ editorText?: string }> {
    return this.lane.run(async () => {
      this.assertIdle();
      this.operation = options.summarize ? { kind: "branchSummary", startedAt: new Date().toISOString() } : undefined;
      const result = await this.runtime.session.navigateTree(targetId, {
        summarize: options.summarize,
        ...(options.instructions ? { customInstructions: options.instructions } : {}),
        ...(options.replaceInstructions === undefined ? {} : { replaceInstructions: options.replaceInstructions }),
        ...(options.label ? { label: options.label } : {}),
      });
      this.operation = undefined;
      if (result.cancelled) throw new GatewayError("cancelled", "Tree navigation was cancelled by an extension");
      this.revision += 1;
      this.publishSnapshot();
      return result.editorText ? { editorText: result.editorText } : {};
    });
  }

  tree(): SessionTreeNode[] {
    return projectTree(this.runtime.session.sessionManager, this.dependencies.blobs);
  }

  commands(): CommandInfo[] {
    const session = this.runtime.session;
    const extension: CommandInfo[] = session.extensionRunner.getRegisteredCommands().map((command) => ({
      name: command.invocationName,
      ...(command.description ? { description: command.description } : {}),
      source: "extension",
      sourcePath: command.sourceInfo.path,
    }));
    const prompts: CommandInfo[] = session.promptTemplates.map((prompt) => ({
      name: prompt.name,
      ...(prompt.description ? { description: prompt.description } : {}),
      ...(prompt.argumentHint ? { argumentHint: prompt.argumentHint } : {}),
      source: "prompt",
      sourcePath: prompt.filePath,
    }));
    const skills: CommandInfo[] = session.resourceLoader.getSkills().skills.map((skill) => ({
      name: `skill:${skill.name}`,
      ...(skill.description ? { description: skill.description } : {}),
      source: "skill",
      sourcePath: skill.filePath,
    }));
    return [...extension, ...prompts, ...skills].sort((a, b) => a.name.localeCompare(b.name));
  }

  context(): JsonValue {
    const session = this.runtime.session;
    return safeJson({
      systemPrompt: session.systemPrompt,
      contextUsage: session.getContextUsage(),
      stats: session.getSessionStats(),
      activeTools: session.getActiveToolNames(),
      availableTools: session.getAllTools(),
      commands: this.commands(),
      ...this.resourcesValue(),
      diagnostics: this.runtime.diagnostics,
    });
  }

  resources(): JsonValue {
    return safeJson({ commands: this.commands(), ...this.resourcesValue() });
  }

  private resourcesValue(): Record<string, unknown> {
    const session = this.runtime.session;
    const loader = session.resourceLoader;
    return {
      tools: session.getAllTools(),
      skills: loader.getSkills(),
      prompts: loader.getPrompts(),
      extensions: loader.getExtensions().extensions.map((extension) => ({ path: extension.path, source: extension.sourceInfo })),
      contextFiles: loader.getAgentsFiles().agentsFiles.map((file) => ({ path: file.path })),
    };
  }

  respondToInteraction(id: string, value: unknown, cancelled: boolean): void {
    this.ui.respond(id, value, cancelled);
  }

  async reload(): Promise<void> {
    await this.lane.run(async () => {
      this.assertIdle();
      await this.runtime.session.reload();
      this.revision += 1;
      this.publishSnapshot();
    });
  }

  async importFromJsonl(path: string, cwdOverride?: string): Promise<void> {
    await this.lane.run(async () => {
      this.assertIdle();
      const result = await this.runtime.importFromJsonl(path, cwdOverride);
      if (result.cancelled) throw new GatewayError("cancelled", "Session import was cancelled by an extension");
      this.revision += 1;
      this.publishSnapshot();
      this.hooks.changed(this.id);
    });
  }

  async export(format: "html" | "jsonl"): Promise<{ blobId: string; name: string; mimeType: string }> {
    this.assertUsable();
    const directory = await mkdtemp(join(tmpdir(), "tron-session-export-"));
    try {
      const output = join(directory, `session.${format}`);
      const path = format === "html"
        ? await this.runtime.session.exportToHtml(output)
        : this.runtime.session.exportToJsonl(output);
      const mimeType = format === "html" ? "text/html; charset=utf-8" : "application/x-ndjson";
      const name = `${basename(this.runtime.session.sessionName ?? this.id).replace(/[^A-Za-z0-9._-]+/g, "-")}.${format}`;
      return { blobId: this.dependencies.blobs.registerData(await readFile(path), mimeType), name, mimeType };
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  }

  async dispose(): Promise<void> {
    if (this.disposed) return;
    if (this.isBusy) throw new GatewayError("busy", "Cannot evict a busy session runtime");
    this.disposed = true;
    if (this.snapshotTimer) clearTimeout(this.snapshotTimer);
    this.unsubscribe?.();
    this.ui.cancelAll();
    await this.runtime.dispose();
  }

  private assertUsable(): void {
    if (this.disposed) throw new GatewayError("conflict", "Session runtime was disposed", true);
    this.touch();
  }

  private assertIdle(): void {
    this.assertUsable();
    if (this.runtime.session.isStreaming || this.isBusy) throw new GatewayError("busy", "Session must be idle for this operation");
  }
}
