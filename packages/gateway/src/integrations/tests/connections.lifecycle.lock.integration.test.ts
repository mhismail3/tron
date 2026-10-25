import { mkdtemp, mkdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxProvider } from "@earendil-works/pi-ai";
import WebSocket from "ws";
import { expect, it, vi } from "vitest";
import { createTestRegistry, displayOwnerOf } from "../../../test-support/gateway-registry.js";
import { normalizeTraceValue } from "../../../test-support/scenario-lock.js";
import { waitFor } from "../../../test-support/wait-for.js";
import { AuthBroker } from "../../admin/auth-broker.js";
import { DeviceStore } from "../../security/device-store.js";
import { UploadStore } from "../../machine/upload-store.js";
import { CommandReceiptStore } from "../../transport/command-receipts.js";
import { GatewayService, type GatewayServiceDependencies } from "../../transport/gateway-service.js";
import { GatewayServer } from "../../transport/server.js";
import { PROTOCOL_VERSION } from "../../version.js";
import { ConnectionOwner } from "../connection-owner.js";
import type { ConnectionOwnerSnapshot, ConnectionPolicy } from "../../modules/integrations/contract.js";

// Real loopback admission, command receipts and durable connection ownership.
// Nothing contacts a provider or resolves a credential: setup carries only a
// synthetic reference; the real auth owner stays idle and the model is offline.
async function start(root: string) {
  const tronHome = join(root, "tron");
  const agentDir = join(root, "agent");
  await mkdir(agentDir, { recursive: true });
  const faux = fauxProvider({ provider: "connections-lock" });
  const modelRuntime = await ModelRuntime.create({ authPath: join(agentDir, "auth.json"), modelsPath: null, refreshOnCreate: false, allowModelNetwork: false });
  modelRuntime.registerNativeProvider(faux.provider);
  const registry = await createTestRegistry({
    tronHome, agentDir, modelRuntimeFactory: async () => modelRuntime,
    broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
  });
  const receipts = new CommandReceiptStore(tronHome);
  const devices = new DeviceStore(tronHome, "connections-lock");
  const connections = new ConnectionOwner(tronHome);
  const auth = new AuthBroker(modelRuntime, () => {});
  const uploads = new UploadStore(tronHome, 1_048_576);
  let server: GatewayServer | undefined;
  let socket: WebSocket | undefined;
  const close = async () => {
    socket?.terminate();
    try { await server?.close(); } finally {
      try { await registry.dispose(); } finally { await receipts.dispose(); }
    }
  };
  try {
    await registry.initialize();
    await devices.initialize();
    const paired = await devices.pair((await devices.ensureEnrollment()).code, "Connections lock");
    const display = displayOwnerOf(registry);
    const service = new GatewayService({
      config: { machineId: "connections-lock", machineGroupID: "lock", machineName: "Lock", tronHome, agentDir },
      sessions: registry, display, modules: registry.moduleHost, devices, connections, receipts, modelRuntime, auth, uploads,
      broadcast: () => {},
    } as unknown as GatewayServiceDependencies);
    server = new GatewayServer({
      host: "127.0.0.1", port: 0, maxFrameBytes: 1_048_576,
      devices, sessions: registry, display, service, auth, uploads, logger: { log: () => {} } as never,
    });
    await server.listen();
    const port = (server as unknown as { server: { address(): { port: number } } }).server.address().port;
    socket = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${paired.token}` } });
    const frames: any[] = [];
    socket.on("message", raw => frames.push(JSON.parse(raw.toString())));
    await new Promise<void>((resolve, reject) => { socket!.once("open", resolve); socket!.once("error", reject); });
    socket.send(JSON.stringify({ type: "hello", protocolVersion: PROTOCOL_VERSION }));
    await waitFor(() => frames.some(frame => frame.type === "hello"), "connections hello");
    let counter = 0;
    const exchanges: unknown[] = [];
    const request = async (method: string, params: Record<string, unknown> = {}) => {
      const id = String(++counter);
      socket!.send(JSON.stringify({ type: "request", id, method, params }));
      const frame = await waitFor(() => frames.find(frame => frame.type === "response" && frame.id === id), method);
      exchanges.push({ method, params, ok: frame.ok, result: frame.result ?? null, error: frame.error ?? null });
      return { ok: frame.ok, result: frame.result, error: frame.error };
    };
    const snapshot = async (): Promise<ConnectionOwnerSnapshot> => {
      const response = await request("connections.list");
      expect(response.ok).toBe(true);
      return response.result;
    };
    return { tronHome, request, snapshot, exchanges, close };
  } catch (error) { await close(); throw error; }
}

it("keeps setup, policy fences, redaction and receipts across a loopback Gateway restart", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-connections-lock-"));
  vi.stubEnv("HOME", root);
  vi.stubEnv("TMPDIR", root);
  vi.stubEnv("PI_CODING_AGENT_DIR", join(root, "agent"));
  vi.stubEnv("PI_OFFLINE", "1");
  let gateway: Awaited<ReturnType<typeof start>> | undefined;
  const trace: unknown[] = [];
  const policy: ConnectionPolicy = { enabled: true, allowWrites: false, paidAccessApproved: false, paidBudgetCents: 0, recurringApproved: false };
  const credentialRef = "connector:raindrop:lock-only-reference";
  const instanceId = "lock-raindrop";
  try {
    gateway = await start(root);
    const statePath = join(gateway.tronHome, "state", "integrations", "connections.json");
    expect((await gateway.snapshot()).instances).toEqual([]);
    await expect(stat(join(gateway.tronHome, "state", "integrations"))).rejects.toMatchObject({ code: "ENOENT" });
    const begin = { commandId: "lock-begin-first", instanceId, definitionId: "knowledge.raindrop", method: "token" };
    const begun = await gateway.request("connections.setup.begin", begin);
    expect(begun.ok).toBe(true);
    expect(begun.result.status).toBe("pending");
    const complete = { commandId: "lock-complete-first", instanceId, operationId: begun.result.operationId, providerAccountId: "fixture-account", credentialRef, policy };
    const completed = await gateway.request("connections.setup.complete", complete);
    expect(completed.ok).toBe(true);
    const configured = await gateway.snapshot();
    expect(configured.instances[0]).toMatchObject({ id: instanceId, credentialConfigured: true, policy });
    expect(JSON.stringify(configured)).not.toContain(credentialRef);
    expect(configured.instances[0]).not.toHaveProperty("credentialRef");
    const persisted = await readFile(statePath, "utf8");
    expect(JSON.parse(persisted).instances[instanceId].credentialRef).toBe(credentialRef);
    // A read and an exact replay must leave the canonical bytes unchanged.
    expect(await gateway.request("connections.setup.complete", complete)).toEqual(completed);
    expect(await readFile(statePath, "utf8")).toBe(persisted);

    const updatedPolicy = { ...policy, enabled: false };
    const updated = await gateway.request("connections.policy.update", {
      commandId: "lock-policy-current", instanceId, expectedSetupRevision: configured.instances[0]!.setupRevision, policy: updatedPolicy,
    });
    expect(updated).toMatchObject({ ok: true, result: { policy: updatedPolicy } });
    expect((await gateway.snapshot()).instances.find(instance => instance.id === instanceId)?.policy).toEqual(updatedPolicy);
    const beforeRefusals = await readFile(statePath, "utf8");
    const stale = await gateway.request("connections.policy.update", {
      commandId: "lock-policy-stale", instanceId, expectedSetupRevision: configured.instances[0]!.setupRevision, policy,
    });
    expect(stale).toMatchObject({ ok: false, error: { code: "conflict" } });
    expect(await readFile(statePath, "utf8")).toBe(beforeRefusals);
    // Transport receipts key the original result by device/method/commandId,
    // not payload. Reusing that key must not execute the changed payload.
    const replay = await gateway.request("connections.setup.begin", { ...begin, instanceId: "different-instance" });
    expect(replay).toEqual(begun);
    expect(await readFile(statePath, "utf8")).toBe(beforeRefusals);

    const pending = await gateway.request("connections.setup.begin", { ...begin, commandId: "lock-begin-pending", instanceId: "cancelled-instance" });
    expect(pending.ok).toBe(true);
    expect((await gateway.request("connections.setup.cancel", { commandId: "lock-cancel-pending", instanceId: "cancelled-instance", operationId: pending.result.operationId })).ok).toBe(true);
    const beforeLateComplete = await readFile(statePath, "utf8");
    expect(await gateway.request("connections.setup.complete", { ...complete, commandId: "lock-complete-cancelled", instanceId: "cancelled-instance", operationId: pending.result.operationId })).toMatchObject({ ok: false, error: { code: "conflict" } });
    expect(await readFile(statePath, "utf8")).toBe(beforeLateComplete);
    const disconnected = await gateway.request("connections.disconnect", { commandId: "lock-disconnect", instanceId });
    expect(disconnected).toMatchObject({ ok: true, result: { health: "disconnected", policy: { enabled: false } } });
    const beforeRestart = await gateway.snapshot();
    expect(beforeRestart.instances).toHaveLength(1);
    expect(beforeRestart.setupOperations.find(operation => operation.operationId === pending.result.operationId)?.status).toBe("cancelled");
    const disconnectedCapabilities = beforeRestart.capabilities.filter(capability => capability.connectionId === instanceId);
    expect(disconnectedCapabilities.length).toBeGreaterThan(0);
    expect(disconnectedCapabilities.every(capability => capability.availability === "unavailable")).toBe(true);
    const bytesBeforeRestart = await readFile(statePath, "utf8");
    trace.push(...gateway.exchanges);
    await gateway.close();
    gateway = undefined;
    gateway = await start(root);
    expect(await gateway.snapshot()).toEqual(beforeRestart);
    expect(await readFile(statePath, "utf8")).toBe(bytesBeforeRestart);
    // start pairs a new device: its fresh transport receipt reaches the owner's
    // persisted command hash. A changed payload must refuse without mutation.
    expect(await gateway.request("connections.setup.complete", { ...complete, providerAccountId: "different-account" })).toMatchObject({ ok: false, error: { code: "conflict" } });
    expect(await readFile(statePath, "utf8")).toBe(bytesBeforeRestart);
    // The owner's exact replay still wins over the now-disconnected state.
    expect(await gateway.request("connections.setup.complete", complete)).toEqual(completed);
    expect(await readFile(statePath, "utf8")).toBe(bytesBeforeRestart);
    trace.push(...gateway.exchanges);
    const artifact = join(process.cwd(), "test-results", "connections-lifecycle");
    await mkdir(artifact, { recursive: true });
    await writeFile(join(artifact, "trace.json"), JSON.stringify(normalizeTraceValue(trace, { roots: [root] }), null, 2) + "\n");
  } finally {
    try { await gateway?.close(); } finally {
      vi.unstubAllEnvs();
      await rm(root, { recursive: true, force: true });
    }
  }
}, 30_000);
