import { homedir } from "node:os";
import { join } from "node:path";
import { ModelRuntime, SettingsManager, createAgentSessionServices } from "@earendil-works/pi-coding-agent";
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
import { LegacyImportService } from "./admin/legacy-import-service.js";
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
import { configureSupervisedNodeCommandEnvironment } from "./runtime/node-command-environment.js";
import { AutomationStore } from "./automations/automation-store.js";
import { AutomationScheduler } from "./automations/automation-scheduler.js";
import { AutomationService } from "./automations/automation-service.js";
import { GatewayAutomationExecutor } from "./automations/automation-executor.js";
import { GatewayScheduleToolOperations } from "./automations/automation-tool-operations.js";

const config = await loadConfig();
const configuredSessionDir = SettingsManager.create(process.cwd(), config.agentDir, { projectTrusted: false }).getSessionDir();
// Pi installs its private agent-bin projection while loading settings. Apply
// the supervised immutable command contract afterward, before extension or
// model discovery, so that mutable projection cannot precede bundled commands.
configureSupervisedNodeCommandEnvironment();
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

const logger = new GatewayLogger(join(config.tronHome, "logs", "gateway.jsonl"));
let transport: GatewayServer;
const devices = new DeviceStore(config.tronHome, config.machineId);
await devices.initialize();
const notifications = new NotificationService(
  new NotificationGrantStore(config.tronHome),
  new PushRelayClient(config.pushServiceOrigin),
  Date.now,
  undefined,
  () => transport?.broadcast("notification.inbox.changed", {}),
);
await notifications.initialize();

const modelRuntime = installKimiK3Policy(await ModelRuntime.create({
  authPath: join(config.agentDir, "auth.json"),
  modelsPath: join(config.agentDir, "models.json"),
  modelsStorePath: join(config.agentDir, "models-store.json"),
  refreshOnCreate: true,
  allowModelNetwork: false,
}));
// Compose global extension providers into the administration runtime used by
// onboarding. Project providers remain isolated in their RuntimeSlot runtime.
// Retain these services for the gateway lifetime. Their resource loader owns
// global extension runtime state used by administration model/auth operations;
// constructing and immediately discarding it can orphan that state.
const administrationServices = await createAgentSessionServices({
  cwd: homedir(),
  agentDir: config.agentDir,
  modelRuntime,
  resourceLoaderReloadOptions: { resolveProjectTrust: async () => false },
});
for (const diagnostic of administrationServices.diagnostics) {
  logger.log(
    diagnostic.type === "error" ? "error" : diagnostic.type === "warning" ? "warning" : "info",
    diagnostic.message,
    { event: "runtime.diagnostic", source: "resource-loader" }
  );
}
const trust = new TrustService(config.agentDir);
const filesystem = new FilesystemService();
const uploads = new UploadStore(config.tronHome, config.maxUploadBytes);
const settings = new SettingsService(config.agentDir, modelRuntime, false);
const modelConfig = new ModelConfigService(config.agentDir);
const receipts = new CommandReceiptStore(config.tronHome);
await receipts.prune();

const workRegistry = new GatewayWorkRegistry();
let automations!: AutomationService;
let automationToolOperations!: GatewayScheduleToolOperations;
const sessions = new RuntimeRegistry({
  agentDir: config.agentDir,
  tronHome: config.tronHome,
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
  machineId: config.machineId,
  notifications,
  workRegistry,
  scheduleToolOperations: {
    execute: (sessionId, toolCallId, request) => automationToolOperations.execute(sessionId, toolCallId, request),
  },
  extensionArtifactWarning: ({ reason, owner }) => logger.log(
    "warning",
    `Extension lifecycle artifact rejected (${reason}; owner ${owner})`,
    { event: "extension.artifact-rejected", source: "sessions" },
  ),
  stageTiming: (stage, durationMs, outcome) => {
    if (durationMs < 250 && outcome === "success") return;
    logger.log(
      durationMs >= 1_000 || outcome === "failure" ? "warning" : "info",
      `Session stage ${stage} completed in ${durationMs}ms (${outcome})`,
      { event: "session.stage", source: "sessions" },
    );
  },
});
const terminal = new TerminalService(
  config.terminalReplayBytes,
  (terminalId, topic, payload) => transport?.broadcastTerminal(terminalId, topic, payload),
);
const auth = new AuthBroker(
  modelRuntime,
  (clientId, topic, payload) => transport?.emitToClient(clientId, topic, payload),
  (topic, payload) => transport?.broadcast(topic, payload),
  { workRegistry },
);
const packages = new PackageService(
  config.agentDir,
  trust,
  (topic, payload) => transport?.broadcast(topic, payload),
  workRegistry,
);
const legacyImport = new LegacyImportService(config.tronHome);
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
    await automations.dispose();
    await sessions.dispose();
    // pi-coding-agent 0.84.1 exposes no disposal API on the retained
    // administration resource loader/model runtime. Admission closure and exact
    // operation settlement above are therefore its truthful teardown boundary.
    void administrationServices;
    await releaseRuntimeLock();
    clearTimeout(forced);
    process.exit(exitCode);
  } catch (error) {
    logger.log("error", error instanceof Error ? error.message : String(error), { event: "gateway.shutdown-failed", source: "lifecycle" });
    await releaseRuntimeLock();
    process.exit(1);
  }
}

let requestedRestart: Promise<void> | undefined;
function requestRestart(): void {
  if (requestedRestart) return;
  logger.log("info", "Gateway restart scheduled after accepted agent runs settle", { event: "gateway.restart-drain", source: "lifecycle" });
  requestedRestart = (async () => {
    const waitingLog = setInterval(() => {
      const snapshot = sessions.administrativeDrainSnapshot();
      const categories = Object.entries(snapshot.blockerCounts)
        .sort(([left], [right]) => left.localeCompare(right))
        .map(([category, count]) => `${category}=${count}`)
        .join(", ");
      logger.log(
        "info",
        `Gateway restart is waiting for ${snapshot.blockerCount} admitted operation${snapshot.blockerCount === 1 ? "" : "s"} to settle${categories ? ` (${categories})` : ""}`,
        { event: "gateway.restart-drain.waiting", source: "lifecycle" },
      );
    }, 15_000);
    waitingLog.unref();
    try {
      await sessions.waitUntilIdle();
    } finally {
      clearInterval(waitingLog);
    }
    logger.log("info", "Gateway restart drain completed", { event: "gateway.restart-drain.completed", source: "lifecycle" });
    await shutdown("requested restart", SUPERVISOR_RELAUNCH_EXIT_CODE);
  })().catch((error) => {
    logger.log("error", error instanceof Error ? error.message : String(error), { event: "gateway.restart-drain-failed", source: "lifecycle" });
    void shutdown("restart drain failed", 1);
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
  legacyImport,
  logger,
  receipts,
  // LaunchAgent/supervisor restarts unsuccessful exits. Administrative
  // restart drains accepted agent work before using the deliberate restart code.
  requestRestart,
  deviceRevoked: (deviceId) => transport?.disconnectDevice(deviceId),
  sessionDeleted: (sessionId) => transport?.revokeSessionTerminals(sessionId),
  broadcast: (topic, payload) => transport?.broadcast(topic, payload),
  notifications,
  workRegistry,
  automations,
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
  auth,
  service,
  logger,
});

const supervised = process.env.TRON_GATEWAY_SUPERVISED === "1";
process.once("SIGTERM", () => void shutdown("SIGTERM", handledSignalExitCode(supervised, requestedRestart !== undefined)));
process.once("SIGINT", () => void shutdown("SIGINT", handledSignalExitCode(supervised, requestedRestart !== undefined)));
process.on("uncaughtException", (error) => {
  logger.log("error", `Uncaught exception: ${error.message}`, { event: "process.uncaught-exception", source: "process" });
  void shutdown("uncaught exception", 1);
});
process.on("unhandledRejection", (error) => {
  logger.log("error", `Unhandled rejection: ${error instanceof Error ? error.message : String(error)}`, { event: "process.unhandled-rejection", source: "process" });
});

const enrollmentTimer = setInterval(() => void devices.ensureEnrollment(), 60_000);
enrollmentTimer.unref();
await transport.listen(async () => {
  await sessions.initialize((phase) => transport.setStartupPhase(phase));
  transport.setStartupPhase("automation-recovery");
  await automations.initialize();
  transport.setStartupPhase("storage-warming");
  await sessions.initializeBlobStorage();
});
const maintainStorage = async (): Promise<void> => {
  try {
    const liveSessionIds = new Set((await sessions.list("all")).map((session) => session.id));
    const [status] = await Promise.all([
      uploads.maintain(liveSessionIds),
      sessions.maintainDisplayArtifacts(liveSessionIds),
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
  } catch {
    logger.log(
      "warning",
      "Bounded artifact maintenance failed and will retry",
      { event: "storage.maintenance-failed", source: "storage" },
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
