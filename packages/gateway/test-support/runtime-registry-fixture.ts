import { mkdtemp, mkdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ModelRuntime, SessionManager } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { onTestFinished, vi } from "vitest";
import { TrustService } from "../src/admin/trust-service.js";
import type { NotificationService } from "../src/notifications/notification-service.js";
import type { SessionSummaryUpdate } from "../src/protocol/types.js";
import { GatewayWorkRegistry } from "../src/sessions/gateway-work-registry.js";
import type { ResourceRecorder } from "../src/transport/stall-diagnostics.js";
import { type SessionCatalog, type SessionCatalogReconcileOutcome } from "../src/sessions/session-catalog.js";
import type { ExtensionArtifactDiscoveryCounts } from "../src/sessions/extension-artifact-discovery.js";
import { RuntimeRegistry, type CapacityShedRecord, type RuntimeLifecycleRecord } from "../src/sessions/runtime-registry.js";

/** Shared cold-start RuntimeRegistry fixture for the runtime-registry journeys. Each caller owns
 * the registry array it passes in: disposal and PI_CODING_AGENT_DIR restoration stay in that
 * caller's afterEach, and the fixture root is removed when its test finishes. */

/** Initialize a registry and wait for the catalog owner's first published cut.
 * A read that lands before that cut refuses retryably (G-1c), and no reader
 * walks the folder any more, so a test lets the owner publish one first. */
export async function initializeRegistry(
  registry: RuntimeRegistry,
  phaseObserver?: (phase: "catalog-warming" | "attention-recovery") => void,
): Promise<void> {
  await registry.initialize(phaseObserver);
  await catalogOwner(registry).whenPublished();
}

/** A test that writes canonical files itself is an external writer: the folder
 * watcher observes it, but no reader polls for it. Forcing one owner reconcile
 * is the deterministic equivalent of waiting the watcher out, and settling the
 * owner then makes its rows and the durable document current without waiting
 * out the persist debounce. */
export async function settleCatalog(registry: RuntimeRegistry): Promise<void> {
  await catalogOwner(registry).reconcile();
  await catalogOwner(registry).settled();
}

/** The registry's catalog owner: the index every read path serves from (G-1c). */
export function catalogOwner(registry: RuntimeRegistry): SessionCatalog {
  return (registry as unknown as { sessionCatalog: SessionCatalog }).sessionCatalog;
}

/** A fixture root that is removed when its test finishes. `onTestFinished` runs on pass, failure
 * and timeout, so the directory is owned by the test that created it, including roots created
 * inside shared fixture helpers. */
export async function temporaryRoot(prefix: string): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), prefix));
  onTestFinished(() => rm(root, { recursive: true, force: true }));
  return root;
}

export async function createColdRegistryFixture(registries: RuntimeRegistry[], label: string, options: {
  nested?: boolean;
  name?: string;
  maximumLiveRuntimes?: number;
  catalogDiscoveryLimits?: { maximumHeaderBytes: number };
  workRegistry?: GatewayWorkRegistry;
  phaseObserver?: (phase: "catalog-warming" | "attention-recovery") => void;
  sessionListChanged?: () => void;
  catalogIndexFailure?: (stage: "save" | "rebuild" | "append", durationMs: number) => void;
  catalogReconciled?: (reconciled: SessionCatalogReconcileOutcome) => void;
  artifactDiscoveryTruncated?: (counts: ExtensionArtifactDiscoveryCounts) => void;
  runtimeDisposeTimeout?: (graceMs: number) => void;
  /** Admit one explicit delegated artifact root, as the production cutover
   * does, so ambient discovery scans exactly that root. */
  delegatedRoot?: string;
  beforeInitialize?: (sessionFile: string, registry: RuntimeRegistry) => Promise<void>;
  notifications?: NotificationService;
  resources?: ResourceRecorder;
  runtimeLifecycleRecord?: (record: RuntimeLifecycleRecord) => void;
  heapSample?: () => { usedBytes: number; limitBytes: number };
  capacityShedRecord?: (record: CapacityShedRecord) => void;
} = {}) {
  const root = await temporaryRoot(`tron-cold-acquire-${label}-`);
  const agentDir = join(root, "agent");
  const cwd = join(root, "workspace");
  const sessionDirectory = options.nested
    ? join(agentDir, "sessions", "workspace", "child")
    : join(agentDir, "sessions", "workspace");
  await Promise.all([mkdir(sessionDirectory, { recursive: true }), mkdir(cwd, { recursive: true })]);
  process.env.PI_CODING_AGENT_DIR = agentDir;
  const manager = SessionManager.create(cwd, sessionDirectory);
  manager.appendMessage(fauxAssistantMessage(`cold acquisition ${label}`));
  if (options.name) manager.appendSessionInfo(options.name);
  const runtimeFactory = vi.fn(async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }));
  const events: Array<{ topic: string; payload: any }> = [];
  const summaries: SessionSummaryUpdate[] = [];
  const delegatedRoot = options.delegatedRoot;
  const registry = new RuntimeRegistry({
    agentDir,
    tronHome: join(root, "tron"),
    idleRuntimeMs: 60_000,
    maximumLiveRuntimes: options.maximumLiveRuntimes,
    catalogDiscoveryLimits: options.catalogDiscoveryLimits,
    workRegistry: options.workRegistry,
    modelRuntimeFactory: runtimeFactory,
    ...(delegatedRoot ? { delegatedArtifactRoot: delegatedRoot } : {}),
    ...(options.artifactDiscoveryTruncated ? { artifactDiscoveryTruncated: options.artifactDiscoveryTruncated } : {}),
    trust: new TrustService(agentDir),
    broadcast: (_sessionId, topic, payload) => events.push({ topic, payload }),
    sessionSummaryChanged: (summary) => summaries.push(summary),
    sessionListChanged: options.sessionListChanged ?? (() => {}),
    ...(options.notifications ? { notifications: options.notifications } : {}),
    ...(options.catalogIndexFailure ? { catalogIndexFailure: options.catalogIndexFailure } : {}),
    ...(options.catalogReconciled ? { catalogReconciled: options.catalogReconciled } : {}),
    ...(options.runtimeDisposeTimeout ? { runtimeDisposeTimeout: options.runtimeDisposeTimeout } : {}),
    ...(options.resources ? { resources: options.resources } : {}),
    ...(options.runtimeLifecycleRecord ? { runtimeLifecycleRecord: options.runtimeLifecycleRecord } : {}),
    ...(options.heapSample ? { heapSample: options.heapSample } : {}),
    ...(options.capacityShedRecord ? { capacityShedRecord: options.capacityShedRecord } : {}),
  });
  registries.push(registry);
  if (options.beforeInitialize) await options.beforeInitialize(manager.getSessionFile()!, registry);
  await initializeRegistry(registry, options.phaseObserver);
  await registry.recoverCanonicalAttention();
  return {
    root,
    delegatedRoot,
    agentDir,
    cwd,
    manager,
    registry,
    runtimeFactory,
    events,
    summaries,
    sessionFile: manager.getSessionFile()!,
  };
}
