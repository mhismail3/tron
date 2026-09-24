import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { existsSync } from "node:fs";
import { ModelRuntime, SettingsManager } from "@earendil-works/pi-coding-agent";
import { loadConfig } from "./config.js";
import { DeviceStore } from "./security/device-store.js";
import { TrustService } from "./admin/trust-service.js";
import { FilesystemService } from "./machine/filesystem-service.js";
import { UploadStore } from "./machine/upload-store.js";
import { TerminalService } from "./machine/terminal-service.js";
import { SettingsService } from "./admin/settings-service.js";
import { ModelConfigService } from "./admin/model-config-service.js";
import { PackageService } from "./admin/package-service.js";
import { AuthBroker } from "./admin/auth-broker.js";
import { GlobalProviderResources } from "./admin/global-provider-resources.js";
import { RuntimeRegistry } from "./sessions/runtime-registry.js";
import { GatewayWorkRegistry } from "./sessions/gateway-work-registry.js";
import { acquireAgentRuntimeLocks } from "./sessions/agent-runtime-lock.js";
import type { JsonValue } from "./protocol/types.js";
import { GatewayLogger } from "./transport/logger.js";
import { CommandReceiptStore } from "./transport/command-receipts.js";
import { GatewayService } from "./transport/gateway-service.js";
import { GatewayServer } from "./transport/server.js";
import { installKimiK3Policy } from "./providers/kimi-k3-policy.js";
import { NotificationGrantStore } from "./notifications/grant-store.js";
import { PushRelayClient } from "./notifications/relay-client.js";
import { NotificationService } from "./notifications/notification-service.js";
import { handledSignalExitCode, SUPERVISOR_RELAUNCH_EXIT_CODE } from "./lifecycle/supervisor-exit-policy.js";
import { configureAgentBinEnvironment, configureSupervisedNodeCommandEnvironment } from "./runtime/node-command-environment.js";
import { AutomationStore } from "./automations/automation-store.js";
import { AutomationScheduler } from "./automations/automation-scheduler.js";
import { AutomationService } from "./automations/automation-service.js";
import { GatewayAutomationExecutor } from "./automations/automation-executor.js";
import { GatewayScheduleToolOperations } from "./automations/automation-tool-operations.js";
import { BrowserLiveViewRegistry } from "./display/browser-live-view.js";
import { KnowledgeStore } from "./knowledge/knowledge-store.js";
import { KnowledgeService, ModelRuntimeKnowledgeModel } from "./knowledge/knowledge-service.js";
import { KnowledgeObservationService, ModelRuntimeObservationModel, modelForConfig } from "./knowledge/knowledge-observation.js";
import { MacKeychainConnectorCredentialStore } from "./knowledge/connector-credentials.js";
import { JevSourceAssessmentModel } from "./knowledge/jev-assessment.js";
import { JevDecisionClient } from "./knowledge/jev-client.js";
import { SessionSearchIndex } from "./sessions/session-search-index.js";
import { SessionSearchAllowanceLedger } from "./sessions/session-search-allowance.js";
import { SessionSearchService } from "./sessions/session-search-service.js";
import { admitSearchEmbeddingHelper, NaturalLanguageEmbeddingClient } from "./sessions/session-search-embedding.js";
import { createKnowledgeConnectorExtension } from "./knowledge/connectors.js";
import { createKnowledgeImporter } from "./knowledge/legacy-import.js";
import { ConnectionOwner } from "./integrations/connection-owner.js";
import { createMcpAdapter } from "./integrations/mcp-adapter.js";
import { delegatedArtifactRoot, delegatedProviderEnvironment, ensureDelegatedArtifactRoot } from "./sessions/delegated-provider.js";
import { assertDelegatedRootCutoverReady } from "./sessions/delegated-root-migration.js";
import { runtimeIdentity } from "./transport/runtime-identity.js";

const config = await loadConfig();
const delegatedRoot = delegatedArtifactRoot(config.tronHome);
// Never switch the provider's root while retained artifacts are discoverable in
// its legacy roots. The operator cutover is explicit and runs before Pi loads
// the provider, so an old run cannot be silently stranded.
await assertDelegatedRootCutoverReady(config.tronHome);
await ensureDelegatedArtifactRoot(delegatedRoot);
// The installed provider receives its supported root before Pi loads any
// extensions. No source or installed package is rewritten at startup.
delegatedProviderEnvironment(delegatedRoot);
// Paid X access is only qualified when the host explicitly supplies the
// provider/account price and retry ceiling. Missing or malformed values keep
// the connector unavailable; no default price is inferred in production.
const xPricing = (() => {
  const accountId = process.env.TRON_X_ACCOUNT_ID?.trim();
  const costCentsPerAttempt = Number(process.env.TRON_X_COST_CENTS_PER_ATTEMPT);
  const maxAttempts = Number(process.env.TRON_X_MAX_ATTEMPTS);
  if (!accountId || !Number.isSafeInteger(costCentsPerAttempt) || costCentsPerAttempt < 1
    || !Number.isSafeInteger(maxAttempts) || maxAttempts < 1 || maxAttempts > 3) return undefined;
  return { accountId, costCentsPerAttempt, maxAttempts };
})();
const configuredSessionDir = SettingsManager.create(process.cwd(), config.agentDir, { projectTrusted: false }).getSessionDir();
// Pi installs its private agent-bin projection while loading settings. Apply
// the supervised immutable command contract afterward, before extension or
// model discovery, so that mutable projection cannot precede bundled commands.
configureSupervisedNodeCommandEnvironment();
configureAgentBinEnvironment(config.agentDir);
const releaseAgentRuntimeLock = await acquireAgentRuntimeLocks([
  config.agentDir,
  ...(configuredSessionDir ? [configuredSessionDir] : []),
]);
const releaseRuntimeLock = releaseAgentRuntimeLock;
// Keep the bootstrap transaction inside a top-level catch: composition or
// listen initialization failures must release locks immediately rather than
// relying on the stale-lock timeout or a later process signal.
try {
process.env.PI_CODING_AGENT_DIR = config.agentDir;
process.env.PI_CODING_AGENT ??= "true";
process.env.AI_AGENT ??= "pi";
process.env.PI_SKIP_VERSION_CHECK ??= "1";

/** Session stages under this bound are debug detail; slower ones warn. */
const SLOW_SESSION_STAGE_MS = 1_000;
const logger = new GatewayLogger(join(config.tronHome, "logs", "gateway.jsonl"), {
  runtimeEpoch: process.env.TRON_GATEWAY_RUNTIME_EPOCH,
  payloadVersion: process.env.TRON_GATEWAY_PAYLOAD_VERSION,
});
{
  const identity = runtimeIdentity();
  logger.log(
    "info",
    `Gateway started (pid ${process.pid}, Node ${process.version}${identity.sourceRevision ? `, source ${identity.sourceRevision}` : ""})`,
    { event: "gateway.started", source: "lifecycle" },
  );
}
let transport: GatewayServer;
const devices = new DeviceStore(config.tronHome, config.machineId);
await devices.initialize();
const notifications = new NotificationService(
  new NotificationGrantStore(config.tronHome),
  new PushRelayClient(config.pushServiceOrigin),
  Date.now,
  undefined,
  () => transport?.broadcast("notification.inbox.changed", {}),
  () => logger.log("warning", "Session notification read state could not be persisted; unread state is retained.", {
    event: "notification.inbox.read_failed", source: "notifications",
  }),
);
await notifications.initialize();

const modelRuntime = installKimiK3Policy(await ModelRuntime.create({
  authPath: join(config.agentDir, "auth.json"),
  modelsPath: join(config.agentDir, "models.json"),
  modelsStorePath: join(config.agentDir, "models-store.json"),
  refreshOnCreate: true,
  allowModelNetwork: false,
}));
const trust = new TrustService(config.agentDir);
const filesystem = new FilesystemService();
const uploads = new UploadStore(config.tronHome, config.maxUploadBytes);
const browserLiveViews = new BrowserLiveViewRegistry();
const settings = new SettingsService(config.agentDir, modelRuntime, false);
const modelConfig = new ModelConfigService(config.agentDir);
const receipts = new CommandReceiptStore(config.tronHome);
await receipts.prune();

const workRegistry = new GatewayWorkRegistry();
const auth = new AuthBroker(
  modelRuntime,
  (clientId, topic, payload) => transport?.emitToClient(clientId, topic, payload),
  (topic, payload) => transport?.broadcast(topic, payload),
  { workRegistry, log: (level, message, event) => logger.log(level, message, { event, source: "auth" }) },
);
const globalProviderResources = await GlobalProviderResources.create({
  cwd: homedir(),
  agentDir: config.agentDir,
  modelRuntime,
  auth,
  workRegistry,
  log: (level, message) => logger.log(level, message, { event: "runtime.diagnostic", source: "resource-loader" }),
  broadcast: () => transport?.broadcast("providers.changed", {}),
});
const connections = new ConnectionOwner(config.tronHome);
const knowledgeCredentials = new MacKeychainConnectorCredentialStore();
const jevClient = new JevDecisionClient(knowledgeCredentials);
const mcp = createMcpAdapter({ connections, credentials: knowledgeCredentials, workRegistry });
let automations!: AutomationService;
let automationToolOperations!: GatewayScheduleToolOperations;
const sessions = new RuntimeRegistry({
  agentDir: config.agentDir,
  tronHome: config.tronHome,
  delegatedArtifactRoot: delegatedRoot,
  idleRuntimeMs: config.idleRuntimeMs,
  maximumLiveRuntimes: config.maxLiveRuntimes,
  trust,
  broadcast: (sessionId, topic, payload) => transport?.broadcastSession(sessionId, topic, payload),
  sessionSummaryChanged: (summary) => transport?.broadcast("session.summary", summary as unknown as JsonValue),
  sessionListChanged: () => transport?.notifySessionListChanged(),
  sessionRekeyed: (previousId, nextId) => transport?.rekeySession(previousId, nextId),
  beforeSessionRekey: (previousId, nextId) => automations.rekeySessionTarget(previousId, nextId),
  beforeSessionDelete: (sessionId) => automations.blockSessionTarget(sessionId),
  sessionClosed: (sessionId) => transport?.revokeSessionTerminals(sessionId),
  persistenceDiagnostic: (sessionId, code) => logger.log("warning", "Session persistence diagnostic", {
    event: code, source: "session", sessionId,
  }),
  machineId: config.machineId,
  notifications,
  browserLiveViews,
  workRegistry,
  connections,
  mcp,
  jev: jevClient,
  scheduleToolOperations: {
    execute: (sessionId, toolCallId, request) => automationToolOperations.execute(sessionId, toolCallId, request),
  },
  extensionArtifactWarning: ({ reason, owner }) => logger.log(
    "warning",
    `Extension lifecycle artifact rejected (${reason}; owner ${owner})`,
    { event: "extension.artifact-rejected", source: "sessions" },
  ),
  stageTiming: (stage, durationMs, outcome, metadata) => {
    const context = [
      metadata?.workID ? `workID=${metadata.workID}` : undefined,
      metadata?.scope ? `scope=${metadata.scope}` : undefined,
    ].filter(Boolean).join(" ");
    logger.log(
      durationMs >= SLOW_SESSION_STAGE_MS || outcome === "failure" ? "warning" : "debug",
      `Session stage ${stage} completed in ${durationMs}ms (${outcome})${context ? ` ${context}` : ""}`,
      { event: "session.stage", source: "sessions" },
    );
  },
});
const bundledSearchHelper = join(dirname(dirname(process.execPath)), "TronSearchEmbeddingHelper");
const developmentHelperOverride = process.env.NODE_ENV === "development" ? process.env.TRON_SEARCH_EMBEDDING_HELPER : undefined;
const searchHelperCandidate = developmentHelperOverride ?? (existsSync(bundledSearchHelper) ? bundledSearchHelper : undefined);
let sessionSearch: SessionSearchService | undefined;
let sessionSearchIndex: SessionSearchIndex | undefined;
try {
  sessionSearchIndex = await SessionSearchIndex.open(join(config.tronHome, "gateway", "session-search.sqlite"));
  let sessionSearchAllowance: SessionSearchAllowanceLedger | undefined;
  try { sessionSearchAllowance = await SessionSearchAllowanceLedger.open(join(config.tronHome, "gateway", "session-search-jev-allowance.sqlite")); }
  catch (error) { logger.log("warning", "Optional Jev allowance is unavailable; remote ranking disabled", { event: "session-search.jev-ledger-unavailable", source: "search", error }); }
  sessionSearch = new SessionSearchService(sessions, sessionSearchIndex, jevClient, sessionSearchAllowance);
} catch (error) {
  sessionSearchIndex?.close();
  logger.log("warning", "Optional session search index is unavailable; chat remains available", { event: "session-search.index-unavailable", source: "search", error });
}
const knowledgeStore = new KnowledgeStore(
  sessions.knowledgeWorkspace(),
  () => transport?.broadcast("knowledge.changed", {}),
  async (connectionId) => connections.resolveInstance(connectionId).catch(() => undefined),
);
const knowledgeConnector = createKnowledgeConnectorExtension(knowledgeStore, {
  credentials: knowledgeCredentials,
  assessment: new JevSourceAssessmentModel(knowledgeCredentials),
  ...(xPricing ? { xPricing } : {}),
  connections,
});
const knowledge = new KnowledgeService(
  knowledgeStore,
  new KnowledgeObservationService(
    knowledgeStore,
    (knowledgeConfig) => {
      const model = modelForConfig(modelRuntime, knowledgeConfig.observation.model);
      return model ? new ModelRuntimeObservationModel(modelRuntime, model) : undefined;
    },
    workRegistry,
    ({ code, dropped, queued }) => logger.log(
      "warning",
      `Prospective knowledge observation cuts were not retained (${dropped} cut(s); ${queued} queued); no durable coverage is claimed`,
      { event: code, source: "knowledge" },
    ),
  ),
  {
    connector: (action, signal) => knowledgeConnector.invoke(action, signal),
    importer: createKnowledgeImporter(knowledgeStore, { roots: {
      ...(process.env.TRON_PERSONAL_OS_ROOT ? { "personal-os": process.env.TRON_PERSONAL_OS_ROOT } : {}),
      ...(process.env.TRON_LLM_WIKI_ROOT ? { "llm-wiki": process.env.TRON_LLM_WIKI_ROOT } : {}),
    } }),
  },
  (knowledgeConfig) => {
    const model = modelForConfig(modelRuntime, knowledgeConfig.observation.model);
    return model ? new ModelRuntimeKnowledgeModel(modelRuntime, model) : undefined;
  },
  workRegistry,
);
sessions.setKnowledgeService(knowledge);
const terminal = new TerminalService(
  config.terminalReplayBytes,
  (terminalId, topic, payload) => transport?.broadcastTerminal(terminalId, topic, payload),
);
const packages = new PackageService(
  config.agentDir,
  trust,
  (topic, payload) => transport?.broadcast(topic, payload),
  workRegistry,
);
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
  onDiagnostic: (message, automationId, runId) => logger.log(
    "warning",
    message,
    { event: "automation.dispatch-failed", source: "automations" },
  ),
  onBlocked: async (record, run) => {
    // Workspace targets have no stable session route until a run is created;
    // never fabricate one for a blocked definition. Existing targets retain
    // the established session notification route.
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
automations = new AutomationService(automationStore, automationScheduler, sessions);
automationToolOperations = new GatewayScheduleToolOperations(automations, receipts);

let stopping = false;
let sessionSearchWarmTask: Promise<void> | undefined;
let storageMaintenanceTimer: NodeJS.Timeout | undefined;
let uploadStoragePressure: "normal" | "low" | "exhausted" = "normal";
async function shutdown(reason: string, exitCode = 0): Promise<void> {
  if (stopping) return;
  stopping = true;
  logger.log("info", `Stopping gateway (${reason})`, { event: "gateway.stopping", source: "lifecycle" });
  const forced = setTimeout(() => process.exit(1), 15_000);
  forced.unref();
  try {
    automations.beginDrain();
    workRegistry.beginDrain();
    if (storageMaintenanceTimer) clearInterval(storageMaintenanceTimer);
    storageMaintenanceTimer = undefined;
    await transport.close();
    await Promise.allSettled([
      automations.requestShutdownCancellation(),
      workRegistry.requestCancellation(),
    ]);
    // Administrative restart already waited without a deadline. Signal/error
    // shutdown gets only a short cleanup grace; failure cannot reopen admission.
    let cleanupTimer!: NodeJS.Timeout;
    const cleanupGrace = new Promise<void>((resolve) => {
      cleanupTimer = setTimeout(resolve, 2_000);
      cleanupTimer.unref();
    });
    await Promise.race([workRegistry.waitUntilSettled(), cleanupGrace]);
    clearTimeout(cleanupTimer);
    if (workRegistry.size > 0) {
      logger.log(
        "warning",
        `Gateway shutdown cleanup grace expired with ${workRegistry.size} owned operation${workRegistry.size === 1 ? "" : "s"} still outstanding`,
        { event: "gateway.shutdown-cleanup-expired", source: "lifecycle" },
      );
    }
    terminal.dispose();
    notifications.dispose();
    knowledge.dispose();
    await automations.dispose();
    await sessionSearchWarmTask?.catch(() => {});
    sessionSearchWarmTask = undefined;
    await sessionSearch?.close();
    await sessions.dispose();
    await releaseRuntimeLock();
    clearTimeout(forced);
    process.exit(exitCode);
  } catch (error) {
    logger.log("error", "Gateway shutdown failed", { event: "gateway.shutdown-failed", source: "lifecycle", error });
    await releaseRuntimeLock();
    process.exit(1);
  }
}

const DRAIN_STALL_LIMIT_MS = 180_000; // Bounds accepted work that stops making drain progress.
const DRAIN_STALL_CHECK_INTERVAL_MS = 1_000; // Checks progress without relying on work completion callbacks.
const DRAIN_WAIT_LOG_INTERVAL_MS = 15_000; // Reports blockers periodically without filling the persistent log.
let requestedRestart: Promise<void> | undefined;
function requestRestart(restartNow = false): void {
  if (requestedRestart) {
    if (restartNow) {
      const snapshot = sessions.administrativeDrainSnapshot();
      logDrainBlockers(snapshot);
      void shutdown("restart drain stalled", SUPERVISOR_RELAUNCH_EXIT_CODE);
    }
    return;
  }
  logger.log("info", "Gateway restart scheduled after accepted agent runs settle", { event: "gateway.restart-drain", source: "lifecycle" });
  requestedRestart = (async () => {
    if (restartNow) {
      const snapshot = sessions.administrativeDrainSnapshot();
      logDrainBlockers(snapshot);
      logger.log("warning", "Gateway restart requested immediately during drain", { event: "gateway.restart-drain.stalled", source: "lifecycle" });
      await shutdown("restart drain stalled", SUPERVISOR_RELAUNCH_EXIT_CODE);
      return;
    }
    let stallTimer: NodeJS.Timeout | undefined;
    let waitingLog: NodeJS.Timeout | undefined;
    const stalled = new Promise<void>((resolve) => {
      let lastProgress = sessions.administrativeDrainSnapshot().lastProgressAt;
      stallTimer = setInterval(() => {
        const snapshot = sessions.administrativeDrainSnapshot();
        if (snapshot.lastProgressAt !== lastProgress) lastProgress = snapshot.lastProgressAt;
        if (!lastProgress || Date.now() - Date.parse(lastProgress) < DRAIN_STALL_LIMIT_MS) return;
        clearInterval(stallTimer);
        clearInterval(waitingLog);
        logDrainBlockers(snapshot);
        logger.log("warning", "Gateway restart drain stalled without progress", { event: "gateway.restart-drain.stalled", source: "lifecycle" });
        void shutdown("restart drain stalled", SUPERVISOR_RELAUNCH_EXIT_CODE).then(resolve);
      }, DRAIN_STALL_CHECK_INTERVAL_MS);
      stallTimer.unref();
      waitingLog = setInterval(() => logDrainBlockers(sessions.administrativeDrainSnapshot()), DRAIN_WAIT_LOG_INTERVAL_MS);
      waitingLog.unref();
    });
    try {
      await Promise.race([sessions.waitUntilIdle(), stalled]);
    } finally {
      if (stallTimer) clearInterval(stallTimer);
      if (waitingLog) clearInterval(waitingLog);
    }
    const snapshot = sessions.administrativeDrainSnapshot();
    if (snapshot.blockerCount > 0) return;
    logger.log("info", "Gateway restart drain completed", { event: "gateway.restart-drain.completed", source: "lifecycle" });
    await shutdown("requested restart", SUPERVISOR_RELAUNCH_EXIT_CODE);
  })().catch((error) => {
    logger.log("error", "Gateway restart drain failed", { event: "gateway.restart-drain-failed", source: "lifecycle", error });
    void shutdown("restart drain failed", 1);
  });
}

function logDrainBlockers(snapshot: ReturnType<typeof sessions.administrativeDrainSnapshot>): void {
  const blockers = snapshot.blockers.map(({ sessionId, category, method, state, ageMs }) => ({
    ...(sessionId ? { sessionId } : {}), category, ...(method ? { method } : {}), state, ageMs: ageMs ?? null,
  }));
  logger.log("info", `Gateway restart waiting on ${snapshot.blockerCount} operation(s): ${JSON.stringify(blockers)}`, {
    event: "gateway.restart-drain.waiting", source: "lifecycle",
  });
}

const service = new GatewayService({
  config,
  modelRuntime,
  devices,
  sessions,
  filesystem,
  uploads,
  terminals: terminal,
  trust,
  settings,
  modelConfig,
  packages,
  auth,
  globalProviderResources,
  logger,
  receipts,
  // LaunchAgent/supervisor restarts unsuccessful exits. Administrative
  // restart drains accepted agent work before using the deliberate restart code.
  requestRestart,
  sessionDeleted: (sessionId) => transport?.revokeSessionTerminals(sessionId),
  broadcast: (topic, payload) => transport?.broadcast(topic, payload),
  notifications,
  workRegistry,
  automations,
  knowledge,
  connections,
  ...(sessionSearch ? { sessionSearch } : {}),
});
transport = new GatewayServer({
  host: config.host,
  port: config.port,
  maxFrameBytes: config.maxFrameBytes,
  maximumConnections: config.maxConnections,
  maximumConnectionsPerIdentity: config.maxConnectionsPerIdentity,
  maximumSubscriptionsPerConnection: config.maxSubscriptionsPerConnection,
  maximumOutboundBytes: config.maxOutboundBytes,
  maximumSynchronizationBytes: config.maxSynchronizationBytes,
  devices,
  uploads,
  sessions,
  liveViews: browserLiveViews,
  auth,
  service,
  logger,
  authorizeBrowserLiveView: (sessionId, viewId, generation) => sessions.authorizeBrowserLiveView(sessionId, viewId, generation),
});

const supervised = process.env.TRON_GATEWAY_SUPERVISED === "1";
process.once("SIGTERM", () => void shutdown("SIGTERM", handledSignalExitCode(supervised, requestedRestart !== undefined)));
process.once("SIGINT", () => void shutdown("SIGINT", handledSignalExitCode(supervised, requestedRestart !== undefined)));
process.on("uncaughtException", (error) => {
  logger.log("error", "Uncaught exception", { event: "process.uncaught-exception", source: "process", error });
  void shutdown("uncaught exception", 1);
});
process.on("unhandledRejection", (error) => {
  logger.log("error", "Unhandled rejection", { event: "process.unhandled-rejection", source: "process", error });
});

const enrollmentTimer = setInterval(() => void devices.ensureEnrollment(), 60_000);
enrollmentTimer.unref();
await transport.listen(async () => {
  // This startup follows a user-initiated Gateway update. Keep Knowledge
  // unavailable on upgrade failure without disabling unrelated chat features.
  await knowledgeStore.upgradeStorage().catch((error: unknown) => {
    logger.log("warning", "Knowledge catalog upgrade reported an error; inspect Knowledge status. No reset was attempted.", { event: "knowledge.upgrade-failed", source: "knowledge", error });
  });
  await sessions.initialize((phase) => transport.setStartupPhase(phase));
  sessionSearchWarmTask = (async () => {
    if (stopping || !sessionSearch) return;
    if (searchHelperCandidate && await admitSearchEmbeddingHelper(searchHelperCandidate)) {
      if (stopping) return;
      sessionSearch.setSemanticClient(new NaturalLanguageEmbeddingClient(searchHelperCandidate));
    } else if (searchHelperCandidate) logger.log("warning", "Signed NaturalLanguage search helper admission failed; semantic search remains unavailable", { event: "session-search.helper-unavailable", source: "search" });
    if (!stopping) await sessionSearch.warm();
  })().catch((error) => logger.log("warning", "Session search warm-up failed; lexical search will recover on demand", { event: "session-search.warm-failed", source: "search", error }));
  transport.setStartupPhase("automation-recovery");
  await automations.initialize();
  transport.setStartupPhase("storage-warming");
  await sessions.initializeBlobStorage();
  await sessions.recoverKnowledgeObservation();
});
await sessions.recoverCanonicalAttention();
const maintainStorage = async (): Promise<void> => {
  try {
    const [status] = await Promise.all([
      uploads.maintain(() => sessions.sessionIDsForStorageMaintenance()),
      sessions.maintainDisplayArtifacts(),
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
storageMaintenanceTimer = setInterval(() => void maintainStorage(), 10 * 60_000);
storageMaintenanceTimer.unref();
} catch (error) {
  await releaseRuntimeLock();
  throw error;
}
