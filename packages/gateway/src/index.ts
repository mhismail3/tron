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
import { acquireAgentRuntimeLocks } from "./sessions/agent-runtime-lock.js";
import type { JsonValue } from "./protocol/types.js";
import { GatewayLogger } from "./transport/logger.js";
import { CommandReceiptStore } from "./transport/command-receipts.js";
import { GatewayService } from "./transport/gateway-service.js";
import { GatewayServer } from "./transport/server.js";
import { installKimiK3Policy } from "./providers/kimi-k3-policy.js";

const config = await loadConfig();
const configuredSessionDir = SettingsManager.create(process.cwd(), config.agentDir, { projectTrusted: false }).getSessionDir();
const releaseAgentRuntimeLock = await acquireAgentRuntimeLocks([
  config.agentDir,
  ...(configuredSessionDir ? [configuredSessionDir] : []),
]);
let agentRuntimeLockReleased = false;
async function releaseRuntimeLock(): Promise<void> {
  if (agentRuntimeLockReleased) return;
  agentRuntimeLockReleased = true;
  await releaseAgentRuntimeLock();
}
process.env.PI_CODING_AGENT_DIR = config.agentDir;
process.env.PI_CODING_AGENT ??= "true";
process.env.AI_AGENT ??= "pi";
process.env.PI_SKIP_VERSION_CHECK ??= "1";

const logger = new GatewayLogger();
const devices = new DeviceStore(config.tronHome, config.machineId);
await devices.initialize();

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
  logger.log(diagnostic.type === "error" ? "error" : diagnostic.type === "warning" ? "warning" : "info", diagnostic.message);
}
const trust = new TrustService(config.agentDir);
const filesystem = new FilesystemService();
const uploads = new UploadStore(config.tronHome, config.maxUploadBytes);
const settings = new SettingsService(config.agentDir, modelRuntime, false);
const modelConfig = new ModelConfigService(config.agentDir);
const receipts = new CommandReceiptStore(config.tronHome);
await receipts.prune();

let transport: GatewayServer;
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
  sessionClosed: (sessionId) => transport?.revokeSessionTerminals(sessionId),
});
await sessions.initialize();

const terminal = new TerminalService(
  config.terminalReplayBytes,
  (terminalId, topic, payload) => transport?.broadcastTerminal(terminalId, topic, payload),
);
const auth = new AuthBroker(
  modelRuntime,
  (clientId, topic, payload) => transport?.emitToClient(clientId, topic, payload),
  (topic, payload) => transport?.broadcast(topic, payload),
);
const packages = new PackageService(config.agentDir, trust, (topic, payload) => transport?.broadcast(topic, payload));
const legacyImport = new LegacyImportService(config.tronHome);

let stopping = false;
async function shutdown(reason: string, exitCode = 0): Promise<void> {
  if (stopping) return;
  stopping = true;
  logger.log("info", `Stopping gateway (${reason})`);
  const forced = setTimeout(() => process.exit(1), 15_000);
  forced.unref();
  try {
    await transport.close();
    terminal.dispose();
    await sessions.dispose();
    await releaseRuntimeLock();
    clearTimeout(forced);
    process.exit(exitCode);
  } catch (error) {
    logger.log("error", error instanceof Error ? error.message : String(error));
    await releaseRuntimeLock();
    process.exit(1);
  }
}

let requestedRestart: Promise<void> | undefined;
function requestRestart(): void {
  if (requestedRestart) return;
  logger.log("info", "Gateway restart scheduled after accepted agent runs settle");
  requestedRestart = (async () => {
    await sessions.waitUntilIdle();
    await shutdown("requested restart", 75);
  })().catch((error) => {
    logger.log("error", error instanceof Error ? error.message : String(error));
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
});
transport = new GatewayServer({
  host: config.host,
  port: config.port,
  maxFrameBytes: config.maxFrameBytes,
  maximumConnections: config.maxConnections,
  maximumConnectionsPerIdentity: config.maxConnectionsPerIdentity,
  maximumSubscriptionsPerConnection: config.maxSubscriptionsPerConnection,
  maximumOutboundFrames: config.maxOutboundFrames,
  maximumOutboundBytes: config.maxOutboundBytes,
  maximumSynchronizationBytes: config.maxSynchronizationBytes,
  devices,
  uploads,
  sessions,
  auth,
  service,
  logger,
});

process.once("SIGTERM", () => void shutdown("SIGTERM"));
process.once("SIGINT", () => void shutdown("SIGINT"));
process.on("uncaughtException", (error) => {
  logger.log("error", `Uncaught exception: ${error.message}`);
  void shutdown("uncaught exception", 1);
});
process.on("unhandledRejection", (error) => {
  logger.log("error", `Unhandled rejection: ${error instanceof Error ? error.message : String(error)}`);
});

const enrollmentTimer = setInterval(() => void devices.ensureEnrollment(), 60_000);
enrollmentTimer.unref();
await transport.listen(() => sessions.initializeBlobStorage());
