import { workspaceModule } from "./workspace/workspace-module.js";
import { MacTerminalService } from "./security/mac-terminal-service.js";
import { ManagedSubagents } from "./kernel/delegation/managed-subagents.js";
import { homedir } from "node:os";
import { existsSync, renameSync, writeFileSync, rmSync } from "node:fs";
import { SettingsManager } from "./kernel/pi/coding-agent.js";
import { piCliBundle } from "./kernel/pi/packages.js";
import { loadConfig, resolveAgentDir } from "./config.js";
import { resolveTronHome } from "./tron-home.js";
import { GatewayError } from "./errors.js";
import { DeviceStore } from "./security/device-store.js";
import { TrustService } from "./kernel/resources/trust-service.js";
import { FilesystemService } from "./machine/filesystem-service.js";
import { UploadStore } from "./machine/upload-store.js";
import { createGatewaySettingsSchema } from "./main/settings-schema.js";
import { SettingsStoreAdapter } from "./admin/settings-model.js";
import { SettingsChangePath } from "./kernel/settings/settings-change.js";
import { SettingsModel } from "./kernel/settings/settings-model.js";
import { SettingsChangeRecord } from "./kernel/settings/settings-record.js";
import { OutsideChanges } from "./admin/settings-outside.js";
import { ModelConfigService } from "./admin/model-config-service.js";
import { PackageService } from "./admin/package-service.js";
import { ScopeToolCatalog } from "./admin/tool-catalog.js";
import { HookResources } from "./admin/hook-resources.js";
import { AuthBroker } from "./admin/auth-broker.js";
import { MacKeychainMcpCredentialOwner, McpAdminService } from "./admin/mcp-admin-service.js";
import { GlobalProviderResources } from "./admin/global-provider-resources.js";
import { RuntimeRegistry } from "./kernel/session/runtime-registry.js";
import { startGatewayModules } from "./main/modules.js";
import { GatewayWorkRegistry } from "./kernel/run/gateway-work-registry.js";
import { DRAIN_WAIT_LOG_INTERVAL_MS, logDrainBlockers, logUnresolvedDrainOwners, RestartDrainProgress, waitForStopDrain } from "./sessions/restart-drain.js";
import { acquireAgentRuntimeLocks } from "./sessions/agent-runtime-lock.js";
import type { JsonValue } from "./protocol/types.js";
import { GatewayLogger } from "./transport/logger.js";
import { RotatingJsonl } from "./transport/rotating-jsonl.js";
import { logHomeDiagnostic } from "./modules/home/home-diagnostic.js";
import { homeToolCatalog } from "./modules/home/home-runtime-policy.js";
import type { HomeComposition } from "./modules/home/home-module.js";
import { applyHomeCacheRetention } from "./modules/home/home-request-policy.js";
import { sessionRuntimeView } from "./providers/openai-model-eligibility.js";
import type { HomeTaskDiagnostic } from "./modules/home/home-task-dispatcher.js";
import { homeWorkspaceDirectory } from "./modules/home/home-owner.js";
import { CommandReceiptStore, COMMAND_RECEIPT_PRUNE_INTERVAL_MS } from "./transport/command-receipts.js";
import { GatewayService } from "./transport/gateway-service.js";
import { GatewayServer } from "./transport/server.js";
import { ResourceSampler } from "./transport/stall-diagnostics.js";
import type { ResourceRuntimeEntry } from "./util/resource-recorder.js";
import { requestsCompetingForLoop } from "./util/request-span.js";
import { backgroundWork } from "./background-work.js";
import { createProviderModelRuntime } from "./providers/provider-runtime.js";
import { OpenAIModelEligibility } from "./providers/openai-model-eligibility.js";
import { NotificationGrantStore } from "./notifications/grant-store.js";
import { PushRelayClient } from "./notifications/relay-client.js";
import { NotificationService } from "./notifications/notification-service.js";
import { handledSignalExitCode, SUPERVISOR_RELAUNCH_EXIT_CODE } from "./lifecycle/supervisor-exit-policy.js";
import { shutdownStep } from "./lifecycle/shutdown-step.js";
import { exitAfterShutdown } from "./lifecycle/exit-after-shutdown.js";
import { STARTUP_LISTEN_BUDGET_MS, startupBudget, type StartupStepTiming } from "./lifecycle/startup-budget.js";
import { configureAgentBinEnvironment, configureHomebrewPath, configureSupervisedNodeCommandEnvironment } from "./runtime/node-command-environment.js";
import { AutomationStore } from "./automations/automation-store.js";
import { AutomationScheduler } from "./automations/automation-scheduler.js";
import { logAutomationDiagnostic } from "./automations/automation-diagnostic.js";
import { AutomationService } from "./automations/automation-service.js";
import type { AutomationHomeTrigger } from "./automations/automation-home-trigger.js";
import { GatewayAutomationExecutor } from "./automations/automation-executor.js";
import { GatewayScheduleToolOperations } from "./automations/automation-tool-operations.js";
import type { ScheduleToolOperations } from "./automations/tron-schedule-extension.js";
import { DisplayArtifactStore } from "./display/display-artifact-store.js";
import { DisplayOwner } from "./display/display-modules.js";
import { BrowserLiveViewRegistry } from "./display/browser-live-view.js";

import { HomeProfileItems } from "./modules/home/home-profile.js";
import { ProfileStore } from "./modules/home/profile-store.js";
import { MODEL_QUEUE_PROJECTION_ENV } from "./providers/model-queue-extension.js";
import { ModelQueueOwner, modelQueueProjectionPath } from "./providers/model-queue.js";
import { ProviderUsageOwner } from "./providers/provider-usage.js";
import { SessionSearchIndex } from "./sessions/session-search-index.js";
import { SessionSearchService } from "./sessions/session-search-service.js";
import { admitSearchEmbeddingHelper, NaturalLanguageEmbeddingClient } from "./sessions/session-search-embedding.js";
import { ConnectionOwner } from "./integrations/connection-owner.js";
import { delegatedArtifactRoot, delegatedProviderEnvironment, ensureDelegatedArtifactRoot } from "./kernel/delegation/delegated-provider.js";
import { runtimeIdentity } from "./transport/runtime-identity.js";
import { assertHomeLayout, tronHomePath } from "./foundation/tron-home-layout.js";

const moduleGraphLoadedAt = performance.now();
const tronHome = resolveTronHome();
const agentDir = resolveAgentDir(tronHome);
await assertHomeLayout(tronHome);
const releaseRuntimeLock = await acquireAgentRuntimeLocks([agentDir]);
try {
const config = await loadConfig();
const delegatedRoot = delegatedArtifactRoot(config.tronHome);
await ensureDelegatedArtifactRoot(delegatedRoot);
delegatedProviderEnvironment(delegatedRoot);
process.env[MODEL_QUEUE_PROJECTION_ENV] = modelQueueProjectionPath(config.tronHome);
configureSupervisedNodeCommandEnvironment();
configureAgentBinEnvironment(config.agentDir);
configureHomebrewPath();
process.env.PI_CODING_AGENT_DIR = config.agentDir;
process.env.PI_CODING_AGENT ??= "true";
process.env.AI_AGENT ??= "pi";
process.env.PI_SKIP_VERSION_CHECK ??= "1";

const gatewayLogPath = tronHomePath(config.tronHome, "logs", "gateway.jsonl");
const logger = new GatewayLogger(gatewayLogPath, {
  runtimeEpoch: process.env.TRON_GATEWAY_RUNTIME_EPOCH,
  payloadVersion: process.env.TRON_GATEWAY_PAYLOAD_VERSION,
});
const requestLog = new RotatingJsonl(tronHomePath(config.tronHome, "logs", "requests.jsonl"), 5 * 1_024 * 1_024, 16);
const managedSubagents = ManagedSubagents.activateForStartup(config.tronHome, logger);
{
  const identity = runtimeIdentity();
  logger.log(
    "info",
    `Gateway started (pid ${process.pid}, Node ${process.version}${identity.sourceRevision ? `, source ${identity.sourceRevision}` : ""})`,
    { event: "gateway.started", source: "lifecycle", durationMs: performance.now() },
  );
}

let startupCheckpointAt = 0;
const startupSteps: StartupStepTiming[] = [];
function startupCheckpoint(step: string, at = performance.now()): void {
  const durationMs = at - startupCheckpointAt;
  startupSteps.push({ step, durationMs });
  logger.log("info", `Gateway startup step ${step} took ${Math.round(durationMs)} ms`, {
    event: "gateway.startup-step", source: "lifecycle", step, durationMs,
  });
  startupCheckpointAt = at;
}
startupCheckpoint("modules", moduleGraphLoadedAt);
startupCheckpoint("config-and-locks");
let transport: GatewayServer;
const devices = new DeviceStore(config.tronHome, config.machineId);
await devices.initialize();
startupCheckpoint("devices");
const notifications: NotificationService = new NotificationService(
  new NotificationGrantStore(config.tronHome),
  new PushRelayClient(config.pushServiceOrigin),
  Date.now,
  (payload) => transport?.broadcast("notification.inbox.changed", payload),
  () => logger.log("warning", "Session notification read state could not be persisted; unread state is retained.", {
    event: "notification.inbox.read_failed", source: "notifications",
  }),
  ({ kind, outcome, relayReason }) => logger.log(
    outcome === "failed" || outcome === "refused" ? "warning" : "info",
    `Push notification ${outcome}`,
    { event: `notification.push.${outcome.replaceAll("_", "-")}`, source: "notifications", kind, outcome, reason: relayReason },
  ),
  (sessionId) => home().chapterStateFor(sessionId).homeId !== undefined,
);
await notifications.initialize();
startupCheckpoint("notifications");

const openAIModelEligibility = new OpenAIModelEligibility();
const providerUsage = new ProviderUsageOwner();
const modelRuntime = await createProviderModelRuntime(config.agentDir);
openAIModelEligibility.attachRuntime(modelRuntime);
startupCheckpoint("model-runtime");
const globalSettingsManager = SettingsManager.create(homedir(), config.agentDir, { projectTrusted: false });
const trust = new TrustService(config.agentDir, { standaloneDirectories: [homeWorkspaceDirectory(config.tronHome)] });
const filesystem = new FilesystemService();
const uploads = new UploadStore(config.tronHome, config.maxUploadBytes);
const browserLiveViews = new BrowserLiveViewRegistry();
const displayArtifacts = new DisplayArtifactStore(config.tronHome);
const display = new DisplayOwner(displayArtifacts, browserLiveViews, () => sessions);
const macTerminalKeys = new MacTerminalService({ root: tronHomePath(config.tronHome, "state/mac-terminal") });
await macTerminalKeys.restore().catch(error => {
  logger.log("warning", "Private SSH startup failed", { event: "mac-terminal.startup-failed", error: String(error) });
});
const settingsSchema = createGatewaySettingsSchema();
const settingsModel = new SettingsModel(new SettingsStoreAdapter({
  schema: settingsSchema,
  macTerminalKeys,
  agentDir: config.agentDir,
  tronHome: config.tronHome,
  trust,
  modelRuntime,
  toolCatalog: async (target) => target.kind === "session"
    ? sessions.liveToolCatalog(target.sessionId)
    : target.kind === "home" ? homeToolCatalog(sessions.runtimeEntries(), id => sessions.isLineageMember(id))
    : scopeToolCatalog.list(target.kind === "project" ? target.cwd : undefined),
}));
let settingsChanges: SettingsChangePath;
const settingsRecord = new SettingsChangeRecord(config.tronHome);
const outsideSettings = new OutsideChanges(settingsSchema, config.tronHome, config.agentDir, settingsRecord, settingsModel.owner.observedReaders);
settingsModel.owner.observeOutside(outsideSettings);
const modelConfig = new ModelConfigService(config.agentDir);
const receipts = new CommandReceiptStore(config.tronHome);
await receipts.prune();
startupCheckpoint("command-receipts");

const workRegistry = new GatewayWorkRegistry();
const auth = new AuthBroker(
  modelRuntime,
  (clientId, topic, payload) => transport?.emitToClient(clientId, topic, payload),
  (topic, payload) => transport?.broadcast(topic, payload),
  {
    workRegistry,
    getDeviceId: () => globalSettingsManager.getOrCreateDeviceId(),
    log: (level, message, event) => logger.log(level, message, { event, source: "auth" }),
  },
);
const homeTaskDiagnostic = (record: HomeTaskDiagnostic) => logger.log(record.event === "home.task.runaway-stop" || record.event === "home.task.detached-work"
    || record.event === "home.task.producer-refused" || record.event === "home.task.store-refused" || record.event === "home.inbox.admission-slow"
    || record.event === "home.task.dispatch-stage" || record.event === "host.load.non-task" || (record.event === "home.task.command-scope-refused" && record.reason === "bind-failed")
    || (record.event === "home.task.command-reap" && (record.outcome === "refused" || record.action === "sweep")) || (record.event === "host.pressure" && record.state === "critical")
    || (record.event === "home.task.authorization" && record.outcome === "refused") ? "warning" : "info",
    "Home task lifecycle", { source: "home", ...record });
const modelQueue = new ModelQueueOwner({
  tronHome: config.tronHome,
  runtime: modelRuntime,
  usage: providerUsage,
  queue: role => sessions.modelQueueOf(role),
  projectionPath: modelQueueProjectionPath(config.tronHome),
  log: (record) => {
    if (record.event === "model-queue.usage-failed") logger.log("error", `Model usage ledger ${record.code}`, { event: record.event, source: "models", code: record.code });
    else if (record.event === "model-queue.skip") logger.log("warning", `The ${record.role} model queue skipped ${record.model}: ${record.reason}`, {
      event: record.event, source: "models", code: record.role,
    });
    else logger.log(record.status === "failed" ? "warning" : "info",
      `Child model queue from ${record.scope}: ${record.status === "published" ? record.models.join(", ") || "empty" : `publication failed (${record.reason})`}`,
      { event: record.event, source: "models", code: record.role, ...(record.sessionId ? { sessionId: record.sessionId } : {}) });
  },
});
await modelQueue.initialize();
let automationHomeTrigger: AutomationHomeTrigger | undefined;
const homeComposition: HomeComposition = {
  triggerSources: () => automationHomeTrigger ? [automationHomeTrigger] : [],
  modelQueue, modelRuntime,
  settings: () => settingsChanges === undefined ? undefined : { model: settingsModel, changes: settingsChanges },
  knowledge: () => knowledge,
  runtime: async () => ({
    runtime: applyHomeCacheRetention(sessionRuntimeView(modelRuntime)),
    ownership: "borrowed",
  }),
  tronHome: config.tronHome, agentDir: config.agentDir, trust, notifications, machineId: config.machineId,
  homeDiagnostic: diagnostic => logHomeDiagnostic(logger, diagnostic),
  homeMemoryDiagnostic: (record) => {
    if (record.event === "home.memory-ingest") {
      logger.log("warning", "Home memory could not ingest committed entries", {
        event: "home.memory-ingest", source: "home", reason: record.reason,
      });
      return;
    }
    logger.log(record.level, "Tron Home memory diagnostic", {
      event: record.event, source: "home",
      ...(record.reason === undefined ? {} : { reason: record.reason }),
      ...(record.counts === undefined ? {} : { counts: record.counts }),
    });
  },
  homeRequestDiagnostic: (record) => {
    if (record.event === "response-timing") {
      logger.log("info", "Tron Home response timing", {
        event: "home.response-timing", source: "home", outcome: record.outcome,
        counts: { calls: record.count, complete: Number(record.complete), terminalMs: record.terminalMs,
          modelMs: record.modelMs, toolMs: record.toolMs,
          ...(record.firstVisibleMs === null ? {} : { firstVisibleMs: record.firstVisibleMs }),
          ...(record.queueMs === null ? {} : { queueMs: record.queueMs }) },
      });
      return;
    }
    if (record.event === "usage") {
      logger.log("info", "Tron Home activation usage", {
        event: "home.activation-usage", source: "home",
        counts: { estimatedTokens: record.estimatedTokens, providerTokens: record.providerTokens },
      });
      return;
    }
    if (record.event === "activation") {
      logger.log("info", "Tron Home activation", {
        event: "home.activation", source: "home",
        counts: {
          effectiveTokens: record.effectiveTokens,
          contextWindow: record.contextWindow,
          viewLines: record.viewLines,
          viewBytes: record.viewBytes,
          excludedMessages: record.excludedMessages,
        },
        durationMs: record.waitedMs,
      });
      return;
    }
    logger.log("warning", "Tron Home activation refused", {
      event: "home.activation-refused", source: "home", reason: record.reason,
      ...(record.detail.length > 200 ? { detail: `${record.detail.slice(0, 200)}…` } : { detail: record.detail }),
      ...(record.effectiveTokens === undefined ? {} : { counts: { effectiveTokens: record.effectiveTokens, contextWindow: record.contextWindow ?? 0 } }),
    });
  },
  homeTaskDiagnostic,
};
const { modules, home, projects } = await startGatewayModules({ tronHome: config.tronHome, log: logger },
  () => ({ registry: sessions, home: homeComposition, openAIModelEligibility, connections, scheduleToolOperations, sessionSearch,
    display,
    recentModelsChanged: () => transport?.broadcast("models.recentChanged", {}), persistenceDiagnostic }));
const globalProviderResources = await GlobalProviderResources.create({
  cwd: homedir(),
  agentDir: config.agentDir,
  modelRuntime,
  auth,
  workRegistry,
  log: (level, message) => logger.log(level, message, { event: "runtime.diagnostic", source: "resource-loader" }),
  broadcast: () => transport?.broadcast("providers.changed", {}),
});
startupCheckpoint("global-provider-resources");
const connections = new ConnectionOwner(config.tronHome);

let automations!: AutomationService;
let automationToolOperations!: GatewayScheduleToolOperations;
const scheduleToolOperations: ScheduleToolOperations = {
  execute: (sessionId, toolCallId, request) => automationToolOperations.execute(sessionId, toolCallId, request),
};
const resourceSampler: ResourceSampler = new ResourceSampler({
  readRuntimes: (): Promise<readonly ResourceRuntimeEntry[]> => sessions.resourceInventory(),
});
let automationSchedulerForArchive: Pick<AutomationScheduler, "hasSessionRun"> | undefined;
const persistenceDiagnostic = (sessionId: string, code: string) => logger.log("warning", "Session persistence diagnostic", {
  event: code, source: "session", sessionId,
});
const sessions: RuntimeRegistry = new RuntimeRegistry({
  modules, agentDir: config.agentDir,
  createModelRuntime: () => createProviderModelRuntime(config.agentDir),
  gatewayModelRuntime: modelRuntime,
  tronHome: config.tronHome,
  resources: resourceSampler,
  delegatedArtifactRoot: delegatedRoot,
  managedSubagents,
  mcpAuth: { openUrl: (operationId, url, sessionId, server) => auth.openMcpAuthorizationUrl(operationId, url, sessionId, server) },
  idleRuntimeMs: config.idleRuntimeMs,
  maximumLiveRuntimes: config.maxLiveRuntimes,
  trust,
  broadcast: (sessionId, topic, payload) => transport?.broadcastSession(sessionId, topic, payload),
  sessionSummaryChanged: (summary) => transport?.broadcast("session.summary", summary as unknown as JsonValue),
  sessionListChanged: () => transport?.notifySessionListChanged(),
  sessionRekeyed: (previousId, nextId) => transport?.rekeySession(previousId, nextId),
  beforeSessionRekey: async (previousId, nextId, runtime) => {
    await display.grantReferences(previousId, nextId, runtime);
    await automations.rekeySessionTarget(previousId, nextId);
  },
  beforeSessionDelete: (sessionId) => automations.blockSessionTarget(sessionId),
  sessionClosed: (sessionId) => {
    auth.cancelSession(sessionId);
  },
  persistenceDiagnostic,
  archiveDiagnostic: (diagnostic) => diagnostic.outcome === "failure"
    ? logger.log("warning", `Session archive state was not persisted (${diagnostic.stage})`, {
      event: "sessions.archive.persist-failed", source: "sessions", outcome: diagnostic.outcome, code: diagnostic.stage,
    })
    : logger.log("info", `Archived session returned to the dashboard on new work (${diagnostic.trigger})`, {
      event: "sessions.archive.auto-unarchived", source: "sessions", outcome: diagnostic.outcome, reason: diagnostic.trigger,
    }),
  sessionAutomationReserved: (sessionId) => automationSchedulerForArchive?.hasSessionRun(sessionId) ?? false,
  resourceFreshnessDiagnostic: record => logger.log(record.reason === "failed" || record.reason === "watch-failed" ? "warning" : "info",
    `Session resource refresh ${record.reason}`, { event: "session.resources-reload", source: "sessions", ...record }),
  runtimeLifecycleRecord: (record) => logger.log("info",
    `Session runtime ${record.event === "runtime.loaded" ? "loaded" : "evicted"} (${record.reason})`, {
      event: record.event,
      source: "sessions",
      sessionId: record.sessionId,
      reason: record.reason,
      counts: {
        transcriptBytes: record.transcriptBytes,
        estimatedHeapBytes: record.estimatedHeapBytes,
        ...(record.overBudget === true ? { overBudget: 1 } : {}),
      },
    }),
  capacityShedRecord: (record) => logger.log("warning",
    `Shed a cold load (${record.admission}) under heap pressure (${Math.round(record.heapUsedBytes / 1_048_576)} MiB of ${Math.round(record.heapLimitBytes / 1_048_576)} MiB)`, {
      event: "gateway.shed",
      source: "sessions",
      reason: record.reason,
      admission: record.admission,
      counts: {
        heapUsedBytes: record.heapUsedBytes,
        heapLimitBytes: record.heapLimitBytes,
        retryAfterMs: record.retryAfterMs,
      },
    }),
  compactionDiagnostic: (diagnostic) => logger.log(
    diagnostic.outcome === "failure" ? "error" : "info",
    `Session compaction ${diagnostic.outcome}`,
    { event: "session.compaction.completed", source: "session", ...diagnostic },
  ),
  stopSteeringDiagnostic: (diagnostic) => logger.log(
    diagnostic.outcome === "failed" ? "warning" : "info",
    `Stop continuation ${diagnostic.outcome}`,
    { event: "session.stop-steering-continuation", source: "session", ...diagnostic },
  ),
  manualCompactionAdopted: (diagnostic) => logger.log(
    "info",
    "Queued manual compaction adopted by an active compaction",
    { event: "session.compaction.manual-adopted", source: "session", ...diagnostic },
  ),
  requestRecord: record => requestLog.append({ timestamp: new Date().toISOString(), ...record }),
  capabilityDiagnostic: aggregate => logger.log("info", "Capability usage aggregate", {
    event: "capability.usage", source: "runtime", step: aggregate.name, outcome: aggregate.status,
    stage: aggregate.latencyBucket, counts: { calls: aggregate.count },
  }),
  codemodeDiagnostic: (diagnostic) => logger.log(
    diagnostic.outcome === "completed" ? "info" : "warning",
    `Codemode execution ${diagnostic.outcome}`,
    { event: "codemode.execution.completed", source: "session", ...diagnostic },
  ),
  homeTaskDiagnostic,
  machineId: config.machineId,
  settingsSchema,
  workRegistry,
  extensionArtifactWarning: ({ reason, owner }) => logger.log(
    "warning",
    `Extension lifecycle artifact rejected (${reason}; owner ${owner})`,
    { event: "extension.artifact-rejected", source: "sessions" },
  ),
  artifactDiscoveryTruncated: ({ entries, statusReads, work, dropped }) => logger.log(
    "warning",
    `Extension artifact discovery stopped early after ${entries} root entries, ${statusReads} artifact reads, ${work} routed reads and ${dropped} candidates its routing budget cut`,
    { event: "extension.discovery-truncated", source: "sessions", counts: { entries, statusReads, work, dropped } },
  ),
  catalogIndexFailure: (stage, durationMs, detail) => logger.log(
    "warning",
    `Catalog metadata index ${stage} failed${detail ? ` (${detail.reason}${detail.shard ? ` shard ${detail.shard}` : ""}${detail.bytes !== undefined ? `: ${detail.bytes} of ${detail.limit} bytes` : detail.limit !== undefined ? `: ${detail.rows} of ${detail.limit} rows` : ""})` : ""}; rows remain unproven until canonical metadata can be read`,
    {
      event: "catalog-index.failure", source: "sessions", step: stage, durationMs,
      ...(detail ? { reason: detail.reason, counts: {
        ...(detail.shard ? { shard: Number.parseInt(detail.shard, 16) } : {}),
        ...(detail.rows !== undefined ? { rows: detail.rows } : {}),
        ...(detail.bytes !== undefined ? { bytes: detail.bytes } : {}),
        ...(detail.limit !== undefined ? { limit: detail.limit } : {}),
      } } : {}),
    },
  ),
  catalogIndexPressure: ({ shard, rows, bytes, limit }) => logger.log(
    "warning",
    `Catalog metadata index ${shard ? `shard ${shard} holds ${bytes} of ${limit} bytes` : `holds ${rows} of ${limit} rows`}; saves still succeed, and are refused past the limit`,
    { event: "catalog-index.pressure", source: "sessions", counts: { ...(shard ? { shard: Number.parseInt(shard, 16) } : {}), rows, ...(bytes !== undefined ? { bytes } : {}), limit } },
  ),
  catalogReconciled: ({ outcome, files, added, removed, modified, unproven, durationMs, trigger }) => logger.log(
    outcome === "reconciled" ? "info" : "warning",
    `Session catalog ${outcome}${trigger ? ` (${trigger})` : ""}: ${added} added, ${removed} removed, ${modified} modified, ${unproven} unproven over ${files} files in ${durationMs}ms`,
    { event: "catalog.reconciled", source: "sessions", outcome, ...(trigger ? { trigger } : {}), durationMs, counts: { files, added, removed, modified, unproven } },
  ),
  catalogChanged: ({ sessionId, outcome, durationMs }) => logger.log(
    "debug",
    `Catalog row ${outcome} for ${sessionId} in ${durationMs}ms`,
    { event: "catalog.changed", source: "sessions", sessionId, outcome, durationMs },
  ),
  catalogWatcherReset: ({ reason }) => logger.log(
    "warning",
    `Catalog folder watcher reset (${reason}); the index is re-derived from canonical files once a watcher is attached`,
    { event: "catalog.watcher-reset", source: "sessions", reason },
  ),
  runtimeDisposeTimeout: (graceMs) => logger.log(
    "warning",
    `Extension runtime shutdown overran its ${graceMs}ms disposal grace and was forced`,
    { event: "runtime.dispose-timeout", source: "sessions", durationMs: graceMs },
  ),
});
const developmentHelperOverride = process.env.NODE_ENV === "development" ? process.env.TRON_SEARCH_EMBEDDING_HELPER : undefined;
const bundledSearchHelper = process.env.TRON_GATEWAY_SEARCH_EMBEDDING_HELPER;
const searchHelperCandidate = developmentHelperOverride ?? (bundledSearchHelper && existsSync(bundledSearchHelper) ? bundledSearchHelper : undefined);
let sessionSearch: SessionSearchService | undefined;
let sessionSearchIndex: SessionSearchIndex | undefined;
try {
  sessionSearchIndex = await SessionSearchIndex.open(tronHomePath(config.tronHome, "cache/session-search.sqlite"));
  sessionSearch = new SessionSearchService(sessions, sessionSearchIndex);
} catch (error) {
  sessionSearchIndex?.close();
  logger.log("warning", "Optional session search index is unavailable; chat remains available", { event: "session-search.index-unavailable", source: "search", error });
}
startupCheckpoint("session-search-index");
const knowledgeStore = new ProfileStore(
  modules.contract(workspaceModule));
const knowledge = knowledgeStore;
const packages = new PackageService(
  config.agentDir,
  trust,
  (topic, payload) => transport?.broadcast(topic, payload),
  workRegistry,
  managedSubagents,
  outsideSettings,
);
const hookResources = new HookResources(config.agentDir, trust, workRegistry, managedSubagents);
const scopeToolCatalog = new ScopeToolCatalog(config.agentDir, trust, workRegistry, managedSubagents);
const automationStore = new AutomationStore(config.tronHome, {
  changed: (automationId) => transport?.broadcast("automation.changed", {
    catalogRevision: automationStore.status().catalogRevision,
    ...(automationId === undefined ? {} : { automationId }),
  }),
});
const automationExecutor = new GatewayAutomationExecutor(
  sessions,
  workRegistry,
  notifications,
  config.machineId,
);
const automationScheduler = new AutomationScheduler(automationStore, automationExecutor, {
  hostEpoch: workRegistry.runtimeEpoch,
  onHomePending: () => home().notifyTrigger(),
  onDiagnostic: (message, automationId, runId) => logAutomationDiagnostic(logger, message, automationId, runId),
  onBlocked: async (record, run) => {
    if (record.target.kind !== "existingSession") return;
    await notifications.enqueue({
      sessionId: record.target.sessionId,
      sourceId: `automation-blocked:${run.runId}`,
      kind: "explicit",
      title: "Automation needs attention",
      message: run.state === "outcomeUnknown"
        ? "An automation stopped because its last outcome could not be confirmed."
        : "An automation paused after repeated failures.",
      route: { sessionId: record.target.sessionId, machineId: config.machineId },
    });
  },
});
automationSchedulerForArchive = automationScheduler;
automations = new AutomationService(automationStore, automationScheduler, sessions, (step, durationMs, detail) => {
  logger.log("info", `Automation recovery ${step} took ${Math.round(durationMs)} ms${detail ? ` (${detail})` : ""}`, {
    event: "automation.recovery-step", source: "automations", step, durationMs,
  });
}, () => home().triggerRoute());
automationHomeTrigger = automations.homeTrigger;
automationToolOperations = new GatewayScheduleToolOperations(automations, receipts);

let stopping = false;
let sessionSearchWarmTask: Promise<void> | undefined;
let uploadStoragePressure: "normal" | "low" | "exhausted" = "normal";
const STORAGE_MAINTENANCE_INTERVAL_MS = 10 * 60_000;
function recordShutdownStep(step: string, durationMs: number): void {
  logger.log("info", `Gateway shutdown step ${step} took ${Math.round(durationMs)} ms`, {
    event: "gateway.shutdown-step", source: "lifecycle", step, durationMs,
  });
}

async function shutdown(reason: string, exitCode = 0, drainAcceptedWork = false): Promise<void> {
  if (stopping) return;
  stopping = true;
  const stopDrainId = drainAcceptedWork ? sessions.administrativeDrainSnapshot().drainId : undefined;
  service.dispose();
  const stoppingAt = performance.now();
  const recordStopped = (code: number): void => logger.log(code === 0 ? "info" : "warning", `Gateway stopped (exit ${code}) after ${Math.round(performance.now() - stoppingAt)} ms of shutdown`, {
    event: "gateway.stopped", source: "lifecycle", code: String(code), pid: process.pid, durationMs: performance.now() - stoppingAt,
  });
  logger.log("info", `Stopping gateway (${reason})`, { event: "gateway.stopping", source: "lifecycle" });
  const forced = drainAcceptedWork ? undefined : setTimeout(() => { recordStopped(1); exitAfterShutdown(1, gatewayLogPath); }, 15_000);
  forced?.unref();
  try {
    automations.beginDrain();
    workRegistry.beginDrain();
    sessionSearch?.cancelWarmup();
    backgroundWork.stop();
    await shutdownStep("transport-close", () => transport.close(), recordShutdownStep);
    if (!drainAcceptedWork) {
      await shutdownStep("cancellation", async () => { await Promise.allSettled([
        automations.requestShutdownCancellation(),
        workRegistry.requestCancellation(),
      ]); }, recordShutdownStep);
    }
    if (drainAcceptedWork) {
      await shutdownStep("work-settle", () => workRegistry.waitUntilSettled(), recordShutdownStep);
    } else {
      let cleanupTimer!: NodeJS.Timeout;
      const cleanupGrace = new Promise<void>((resolve) => {
        cleanupTimer = setTimeout(resolve, 2_000);
        cleanupTimer.unref();
      });
      await shutdownStep("work-settle", () => Promise.race([workRegistry.waitUntilSettled(), cleanupGrace]), recordShutdownStep);
      clearTimeout(cleanupTimer);
    }
    if (workRegistry.size > 0) {
      logger.log(
        "warning",
        `Gateway shutdown cleanup grace expired with ${workRegistry.size} owned operation${workRegistry.size === 1 ? "" : "s"} still outstanding`,
        { event: "gateway.shutdown-cleanup-expired", source: "lifecycle" },
      );
    }
    await shutdownStep("outside-settings-dispose", () => outsideSettings.dispose(), recordShutdownStep);
    await shutdownStep("notifications-dispose", async () => { notifications.dispose(); }, recordShutdownStep);
    await shutdownStep("automations-dispose", () => automations.dispose(), recordShutdownStep);
    await shutdownStep("search-warm-settle", async () => { await sessionSearchWarmTask?.catch(() => {}); }, recordShutdownStep);
    sessionSearchWarmTask = undefined;
    await shutdownStep("search-close", async () => { await sessionSearch?.close(); }, recordShutdownStep);
    await shutdownStep("sessions-dispose", () => sessions.dispose(), recordShutdownStep);
    await shutdownStep("modules-stop", () => modules.stop(), recordShutdownStep);
    await shutdownStep("command-receipts-dispose", () => receipts.dispose(), recordShutdownStep);
    await shutdownStep("runtime-lock-release", () => releaseRuntimeLock(), recordShutdownStep);
    if (forced) clearTimeout(forced);
    if (exitCode === 0 && stopDrainId) {
      const path = tronHomePath(config.tronHome, "state/stop-completed.json");
      const temporary = `${path}.${process.pid}.tmp`;
      try {
        writeFileSync(temporary, JSON.stringify({ version: 1, pid: process.pid, drainId: stopDrainId }), { mode: 0o600 });
        renameSync(temporary, path);
      } catch (error) {
        try { rmSync(temporary, { force: true }); } catch {}
        logger.log("error", "Could not publish intentional-stop completion; wrapper must report observation uncertainty", {
          event: "gateway.stop-completion.failed", source: "lifecycle", error,
        });
      }
    }
    recordStopped(exitCode);
    exitAfterShutdown(exitCode, gatewayLogPath);
  } catch (error) {
    logger.log("error", "Gateway shutdown failed", { event: "gateway.shutdown-failed", source: "lifecycle", error });
    await releaseRuntimeLock();
    recordStopped(1);
    exitAfterShutdown(1, gatewayLogPath);
  }
}

const DRAIN_STALL_LIMIT_MS = 180_000;
type AdministrativeExitMode = "restart" | "stop";
interface AdministrativeExitOwner {
  mode: AdministrativeExitMode;
  task: Promise<void>;
}
let administrativeExitOwner: AdministrativeExitOwner | undefined;

function requestRestart(restartNow = false): void {
  requestAdministrativeExit("restart", restartNow);
}

function requestStop(): void {
  requestAdministrativeExit("stop");
}

function requestAdministrativeExit(mode: AdministrativeExitMode, restartNow = false): void {
  if (administrativeExitOwner) {
    if (mode === "restart" && restartNow) {
      const supersedesStop = administrativeExitOwner.mode === "stop";
      administrativeExitOwner.mode = "restart";
      const snapshot = sessions.administrativeDrainSnapshot();
      logDrainBlockers(logger, "restart", snapshot);
      logger.log("warning", supersedesStop
        ? "Gateway restart requested immediately during intentional stop"
        : "Gateway restart requested immediately during drain", { event: "gateway.restart-drain.stalled", source: "lifecycle" });
      void shutdown("restart drain stalled", SUPERVISOR_RELAUNCH_EXIT_CODE);
    }
    return;
  }

  const owner: AdministrativeExitOwner = { mode, task: Promise.resolve() };
  administrativeExitOwner = owner;
  owner.task = mode === "restart" ? runRestartDrain(restartNow) : runStopDrain();
  void owner.task.finally(() => {
    if (administrativeExitOwner === owner && !stopping) administrativeExitOwner = undefined;
  }).catch(() => {});
}

async function runRestartDrain(restartNow: boolean): Promise<void> {
  logger.log("info", "Gateway restart scheduled after accepted agent runs settle", { event: "gateway.restart-drain", source: "lifecycle" });
  try {
    if (restartNow) {
      const snapshot = sessions.administrativeDrainSnapshot();
      logDrainBlockers(logger, "restart", snapshot);
      logger.log("warning", "Gateway restart requested immediately during drain", { event: "gateway.restart-drain.stalled", source: "lifecycle" });
      await shutdown("restart drain stalled", SUPERVISOR_RELAUNCH_EXIT_CODE);
      return;
    }
    const progress = new RestartDrainProgress();
    let decision: ReturnType<RestartDrainProgress["evaluate"]> | undefined;
    let lastWaitLogAt = Number.NEGATIVE_INFINITY;
    const completed = await sessions.waitUntilIdle((snapshot) => {
      decision = progress.evaluate(snapshot, Date.now(), DRAIN_STALL_LIMIT_MS);
      if (decision.outcome === "stalled" || decision.outcome === "unresolved-owners") {
        if (decision.outcome === "stalled") {
          logDrainBlockers(logger, "restart", snapshot);
          logger.log("warning", `Gateway restart drain stalled: category=${decision.blocker.category} method=${decision.blocker.method ?? "none"} ageMs=${decision.ageMs}`, {
            event: "gateway.restart-drain.stalled", source: "lifecycle",
          });
        } else if (decision.outcome === "unresolved-owners") {
          logUnresolvedDrainOwners(decision.owners, (sessionId, category) => {
            logger.log("error", `Gateway restart proceeding with unresolved owner category=${category}`, {
              event: "gateway.restart-drain.unresolved-owner", source: "lifecycle", sessionId,
            });
          });
        }
        return false;
      }
      const now = Date.now();
      if (now - lastWaitLogAt >= DRAIN_WAIT_LOG_INTERVAL_MS) {
        lastWaitLogAt = now;
        logDrainBlockers(logger, "restart", snapshot);
      }
      return true;
    });
    if (completed) {
      logger.log("info", "Gateway restart drain completed", { event: "gateway.restart-drain.completed", source: "lifecycle" });
      await shutdown("requested restart", SUPERVISOR_RELAUNCH_EXIT_CODE);
      return;
    }
    if (decision?.outcome === "stalled" || decision?.outcome === "unresolved-owners") {
      await shutdown(decision.outcome === "stalled" ? "restart drain stalled" : "restart drain has unresolved owners", SUPERVISOR_RELAUNCH_EXIT_CODE);
    }
  } catch (error) {
    logger.log("error", "Gateway restart drain failed", { event: "gateway.restart-drain-failed", source: "lifecycle", error });
    await shutdown("restart drain failed", 1);
  }
}

async function runStopDrain(): Promise<void> {
  logger.log("info", "Gateway stop scheduled after accepted work settles", { event: "gateway.stop-drain", source: "lifecycle" });
  try {
    const finalSnapshot = await waitForStopDrain(sessions, logger);
    if (finalSnapshot.phase === "complete" && finalSnapshot.blockerCount === 0) {
      logger.log("info", "Gateway stop drain completed", { event: "gateway.stop-drain.completed", source: "lifecycle" });
      await shutdown("requested stop", 0, true);
      return;
    }
    sessions.failAdministrativeDrain();
    logger.log("error", `Gateway stop refused: final drain phase=${finalSnapshot.phase} blockers=${finalSnapshot.blockerCount}`, {
      event: "gateway.stop-drain.failed", source: "lifecycle",
    });
  } catch (error) {
    logger.log("error", "Gateway stop drain failed; process remains available for recovery", {
      event: "gateway.stop-drain.failed", source: "lifecycle", error,
    });
  }
}

settingsChanges = new SettingsChangePath(settingsModel, settingsRecord, {
  setTrust: async (project, decision) => trust.setAndApply(
    project,
    decision,
    async (inspection) => sessions.reloadProject(inspection.projectDir, inspection.effectiveDecision === true, false),
    async (inspection) => sessions.commitProjectReload(inspection.projectDir),
    async (inspection) => sessions.abortProjectReload(inspection.projectDir),
  ),
  undoSubject: (entry, context) => new HomeProfileItems(() => knowledge).undo(settingsChanges, entry, context),
});
sessions.setSettings(settingsModel, settingsChanges);
projects.register(settingsChanges);

const service = new GatewayService({
  config,
  providerUsage,
  modelRuntime,
  devices,
  sessions, display,
  filesystem,
  uploads,
  trust,
  settingsModel,
  settingsChanges,
  macTerminal: macTerminalKeys,
  modelConfig,
  packages,
  hookResources,
  auth,
  globalProviderResources,
  logger,
  receipts,
  requestRestart,
  requestStop,
  broadcast: (topic, payload) => transport?.broadcast(topic, payload),
  notifications,
  workRegistry,
  automations,
  knowledge,
  home: home(),
  mcpAdmin: new McpAdminService(
    config.agentDir,
    piCliBundle(),
    new MacKeychainMcpCredentialOwner(),
    (level, message, event, fields) => logger.log(level, message, { event, source: "mcp", ...fields }),
  ),
});
outsideSettings.startWatching(error => logger.log("warning", "Outside settings comparison failed", {
  event: "settings.outside.failed", source: "settings", error: error instanceof Error ? error.message : String(error),
}));
transport = new GatewayServer({
  host: config.host,
  port: config.port,
  maxFrameBytes: config.maxFrameBytes,
  maximumConnections: config.maxConnections,
  maximumConnectionsPerIdentity: config.maxConnectionsPerIdentity,
  maximumSubscriptionsPerConnection: config.maxSubscriptionsPerConnection,
  maximumOutboundBytes: config.maxOutboundBytes,
  maximumSynchronizationBytes: config.maxSynchronizationBytes,
  lanEndpoint: config.lanEndpoint,
  devices,
  uploads,
  sessions, display,
  liveViews: browserLiveViews,
  auth,
  service,
  logger,
  resourceSampler,
  authorizeBrowserLiveView: (sessionId, viewId, generation) => display.authorizeLiveView(sessionId, viewId, generation),
});

const supervised = process.env.TRON_GATEWAY_SUPERVISED === "1";
process.once("SIGTERM", () => void shutdown("SIGTERM", handledSignalExitCode(supervised, administrativeExitOwner?.mode === "restart")));
process.once("SIGINT", () => void shutdown("SIGINT", handledSignalExitCode(supervised, administrativeExitOwner?.mode === "restart")));
process.on("uncaughtException", (error) => {
  logger.log("error", "Uncaught exception", { event: "process.uncaught-exception", source: "process", error });
  void shutdown("uncaught exception", 1);
});
process.on("unhandledRejection", (error) => {
  logger.log("error", "Unhandled rejection", { event: "process.unhandled-rejection", source: "process", error });
});

const enrollmentTimer = setInterval(() => void devices.ensureEnrollment(), 60_000);
enrollmentTimer.unref();
startupCheckpoint("composition");
await transport.listen(async () => {
  service.startModelReleaseDateRefresh();
  startupCheckpoint("listener-bind");
  await sessions.initialize((phase) => transport.setStartupPhase(phase));
  startupCheckpoint("session-registry");
  await settingsChanges.start();
  sessionSearchWarmTask = (async () => {
    if (stopping || !sessionSearch) return;
    const warmStartedAt = performance.now();
    if (searchHelperCandidate && await admitSearchEmbeddingHelper(searchHelperCandidate)) {
      if (stopping) return;
      sessionSearch.setSemanticClient(new NaturalLanguageEmbeddingClient(searchHelperCandidate));
    } else {
      logger.log("warning", searchHelperCandidate
        ? "Signed NaturalLanguage search helper admission failed; semantic search remains unavailable"
        : "NaturalLanguage search helper is unavailable; semantic search remains unavailable",
      { event: "session-search.helper-unavailable", source: "search" });
    }
    if (!stopping) {
      await sessionSearch.warm();
      const durationMs = performance.now() - warmStartedAt;
      const { reusedSessions, parsedSessions } = sessionSearch.indexPassStats();
      logger.log("info", `Session search warm-up took ${Math.round(durationMs)} ms (${reusedSessions} reused, ${parsedSessions} reparsed)`, {
        event: "session-search.warm", source: "search", durationMs, counts: { reusedSessions, parsedSessions },
      });
    }
  })().catch((error) => {
    if (!stopping) logger.log("warning", "Session search warm-up failed; lexical search will recover on demand", { event: "session-search.warm-failed", source: "search", error });
  });
  transport.setStartupPhase("automation-recovery");
  await automations.initialize().catch((error) => {
    if (!(error instanceof GatewayError) || !error.retryable || error.diagnosticReason !== "catalog_not_ready") throw error;
    logger.log("warning", "Automation recovery deferred: the session catalog is not ready", {
      event: "automation.recovery-deferred", source: "automations", reason: error.diagnosticReason,
    });
  });
  startupCheckpoint("automation-recovery");
  transport.setStartupPhase("storage-warming");
  await sessions.initializeBlobStorage();
  startupCheckpoint("blob-storage");
});
{
  const budget = startupBudget(performance.now(), startupSteps);
  logger.log(
    budget.withinBudget ? "info" : "warning",
    `Gateway startup budget ${budget.withinBudget ? "met" : "missed"}: listening after ${Math.round(budget.listeningMs)} ms of ${STARTUP_LISTEN_BUDGET_MS} ms (slowest step ${budget.slowestStep} at ${budget.slowestStepMs} ms)`,
    {
      event: "gateway.startup-budget", source: "lifecycle", durationMs: budget.listeningMs, step: budget.slowestStep,
      counts: { budgetMs: STARTUP_LISTEN_BUDGET_MS, stepMs: budget.slowestStepMs, overBudgetMs: budget.overBudgetMs },
    },
  );
}
await sessions.recoverCanonicalAttention();
startupCheckpoint("attention-recovery");
await home().recoverTasks();
startupCheckpoint("home-task-recovery");
void managedSubagents.prepareSessionTransforms().then((prepared) => { if (prepared) startupCheckpoint("subagent-transforms"); });
const maintainStorage = async (): Promise<void> => {
  try {
    const [status] = await Promise.all([
      uploads.maintain(() => sessions.sessionIDsForStorageMaintenance()),
      display.maintainArtifacts(),
    ]);
    if (status.storagePressure !== uploadStoragePressure) {
      logger.log(
        status.storagePressure === "normal" ? "info" : "warning",
        status.storagePressure === "normal"
          ? `Attachment storage pressure recovered (${status.diskAvailableBytes} bytes free)`
          : `Attachment storage pressure ${status.storagePressure} (${status.diskAvailableBytes} bytes free; ${status.minimumFreeBytes} byte floor)`,
        { event: "uploads.storage-pressure", source: "uploads" },
      );
      uploadStoragePressure = status.storagePressure;
    }
  } catch (error) {
    logger.log(
      "warning",
      "Bounded artifact maintenance failed and will retry",
      { event: "storage.maintenance-failed", source: "storage", error },
    );
  }
};
await maintainStorage();
backgroundWork.register({
  name: "command-receipts.prune",
  intervalMs: COMMAND_RECEIPT_PRUNE_INTERVAL_MS,
  slice: () => receipts.prune(),
});
backgroundWork.register({
  name: "storage.maintain",
  intervalMs: STORAGE_MAINTENANCE_INTERVAL_MS,
  slice: () => maintainStorage(),
});
if (!stopping) backgroundWork.start({
  requestsInFlight: requestsCompetingForLoop,
  onSlice: ({ job, outcome, durationMs, waitedMs, error }) => logger.log(
    outcome === "failed" ? "warning" : "debug",
    `Background slice ${job} ${outcome} in ${Math.round(durationMs)}ms after waiting ${Math.round(waitedMs)}ms`,
    {
      event: "background.slice", source: "background", step: job, outcome, durationMs,
      counts: { waitedMs: Math.round(waitedMs) },
      ...(error === undefined ? {} : { error }),
    },
  ),
  onBacklog: ({ job, waitedMs, reason, jobs, due }) => logger.log(
    "warning",
    `Background job ${job} has been due for ${Math.round(waitedMs)}ms; the scheduler is paused (${reason})`,
    {
      event: "background.backlog", source: "background", step: job, reason,
      counts: { waitedMs: Math.round(waitedMs), jobs, due },
    },
  ),
});
} catch (error) {
  await releaseRuntimeLock();
  throw error;
}
