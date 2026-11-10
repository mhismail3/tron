import { createTestRegistry } from "./gateway-registry.js";
import { mkdtemp, mkdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ModelRuntime, SessionManager } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { onTestFinished, vi } from "vitest";
import { TrustService } from "../src/kernel/resources/trust-service.js";
import type { NotificationService } from "../src/notifications/notification-service.js";
import type { SessionSummaryUpdate } from "../src/protocol/types.js";
import type { GatewayWorkRegistry } from "../src/kernel/run/gateway-work-registry.js";
import type { ResourceRecorder } from "../src/util/resource-recorder.js";
import type { SessionCatalog, SessionCatalogReconcileOutcome } from "../src/sessions/session-catalog.js";
import type { ExtensionArtifactDiscoveryCounts } from "../src/sessions/extension-artifact-discovery.js";
import { RuntimeRegistry, type CapacityShedRecord, type RuntimeLifecycleRecord } from "../src/kernel/session/runtime-registry.js";

export async function initializeRegistry(
  registry: RuntimeRegistry,
  phaseObserver?: (phase: "catalog-warming" | "attention-recovery") => void,
): Promise<void> {
  await registry.initialize(phaseObserver);
  await catalogOwner(registry).whenPublished();
}

export async function settleCatalog(registry: RuntimeRegistry): Promise<void> {
  await catalogOwner(registry).reconcile();
  await catalogOwner(registry).settled();
}

export function catalogOwner(registry: RuntimeRegistry): SessionCatalog {
  return (registry as unknown as { sessionCatalog: SessionCatalog }).sessionCatalog;
}

export async function temporaryRoot(prefix: string): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), prefix));
  onTestFinished(() => rm(root, { recursive: true, force: true }));
  return root;
}

export async function createColdRegistryFixture(registries: RuntimeRegistry[], label: string, options: {
  nested?: boolean;
  name?: string;
  maximumLiveRuntimes?: number;
  catalogDiscoveryLimits?: NonNullable<ConstructorParameters<typeof RuntimeRegistry>[0]["catalogDiscoveryLimits"]>;
  workRegistry?: GatewayWorkRegistry;
  phaseObserver?: (phase: "catalog-warming" | "attention-recovery") => void;
  sessionListChanged?: () => void;
  catalogIndexFailure?: NonNullable<ConstructorParameters<typeof RuntimeRegistry>[0]["catalogIndexFailure"]>;
  catalogReconciled?: (reconciled: SessionCatalogReconcileOutcome) => void;
  artifactDiscoveryTruncated?: (counts: ExtensionArtifactDiscoveryCounts) => void;
  runtimeDisposeTimeout?: (graceMs: number) => void;
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
  const registry = await createTestRegistry({
    agentDir,
    tronHome: join(root, "tron"),
    idleRuntimeMs: 60_000,
    ...(options.maximumLiveRuntimes !== undefined ? { maximumLiveRuntimes: options.maximumLiveRuntimes } : {}),
    ...(options.catalogDiscoveryLimits !== undefined ? { catalogDiscoveryLimits: options.catalogDiscoveryLimits } : {}),
    ...(options.workRegistry !== undefined ? { workRegistry: options.workRegistry } : {}),
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
