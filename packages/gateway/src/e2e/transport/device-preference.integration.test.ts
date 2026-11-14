import { displayOwnerOf, createTestRegistry } from "../../../test-support/gateway-registry.js";
import { TEST_SETTINGS_SCHEMA } from "../../../test-support/settings-schema.js";
import { mkdtemp, mkdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Readable } from "node:stream";
import WebSocket from "ws";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxProvider } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it, vi } from "vitest";
import { TrustService } from "../../kernel/resources/trust-service.js";
import { DeviceStore } from "../../security/device-store.js";
import { RuntimeRegistry } from "../../kernel/session/runtime-registry.js";
import { CommandReceiptStore } from "../../transport/command-receipts.js";
import { GatewayService } from "../../transport/gateway-service.js";
import { GatewayServer } from "../../transport/server.js";
import { DevicePreferenceBridge } from "../../transport/device-preference-bridge.js";
import { SettingsStoreAdapter } from "../../admin/settings-model.js";
import { SettingsModel } from "../../kernel/settings/settings-model.js";
import { SettingsChangePath } from "../../kernel/settings/settings-change.js";
import { SettingsChangeRecord } from "../../kernel/settings/settings-record.js";
import type { Resolution, ResolvedKey } from "../../kernel/settings/tool-contract.js";
import { waitFor } from "../../../test-support/wait-for.js";

const KEY = "experimental.swiftApps";
const HOME = { kind: "home" } as const;
const cleanup: Array<() => Promise<void>> = [];
afterEach(async () => {
  const results = await Promise.allSettled(cleanup.splice(0).map((dispose) => dispose()));
  vi.restoreAllMocks();
  const failures = results.filter((result) => result.status === "rejected");
  if (failures.length) throw new AggregateError(failures.map((result) => result.reason), "Device preference fixture cleanup failed");
});

type Frame = Record<string, any>;

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "tron-device-preference-"));
  const agentDir = join(root, "agent");
  await mkdir(agentDir);
  let registry: RuntimeRegistry | undefined;
  const sockets: WebSocket[] = [];
  cleanup.push(async () => {
    sockets.forEach((socket) => socket.terminate());
    try { await server?.close(); } finally {
      try { await registry?.dispose(); } finally { await rm(root, { recursive: true, force: true }); }
    }
  });
  const faux = fauxProvider({ provider: "device-preference-fixture", tokensPerSecond: 100_000 });
  registry = await createTestRegistry({ agentDir, tronHome: root, idleRuntimeMs: 60_000,
    modelRuntimeFactory: async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    },
    trust: new TrustService(agentDir),
    broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
  });
  await registry.initialize();
  const devices = new DeviceStore(root, "fixture-machine");
  await devices.initialize();
  const pair = async (name: string) => {
    const invitation = await devices.ensureEnrollment();
    const paired = await devices.pair(invitation.code, name);
    await devices.ensureEnrollment();
    return paired;
  };
  const phone = await pair("Fixture iPhone");
  const other = await pair("Other iPhone");

  let server: GatewayServer | undefined;
  const bridge = new DevicePreferenceBridge({
    pairedDevices: async () => (await devices.listDevices()).map((device) => device.id),
    newestReadyConnection: (deviceId) => server!.newestReadyDeviceConnection(deviceId),
    send: (connectionId, topic, payload) => server!.emitToClient(connectionId, topic, payload as never),
  });
  const trust = new TrustService(agentDir);
  const settingsModel = new SettingsModel(new SettingsStoreAdapter({ schema: TEST_SETTINGS_SCHEMA, agentDir, tronHome: root, trust,
    modelRuntime: await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }), devicePreferences: bridge }));
  const settingsChanges = new SettingsChangePath(settingsModel, new SettingsChangeRecord(root), {
    setTrust: async () => { throw new Error("trust is not exercised here"); },
  });
  const service = new GatewayService({ display: displayOwnerOf(registry),
    config: { machineId: "machine", machineGroupID: "group", machineName: "Mac", tronHome: root, agentDir },
    devices, sessions: registry, receipts: new CommandReceiptStore(root), uploads: {} as never, trust,
    settingsModel, settingsChanges, devicePreferences: bridge, modelRuntime: settingsModel.owner.modelRuntime,
    broadcast: () => {}, globalProviderResources: { withStableSnapshot: async (operation: () => Promise<unknown>) => operation(), requestReload: () => {} },
  } as never);
  server = new GatewayServer({ display: displayOwnerOf(registry), host: "127.0.0.1", port: 0, maxFrameBytes: 1_048_576,
    devices, sessions: registry, service, uploads: {} as never,
    auth: { cancelOwner: () => {}, detachClient: () => {} } as never, logger: { log: () => {} } as never,
  });
  await server.listen();
  const port = (server as any).server.address().port as number;

  const connect = async (token: string) => {
    const socket = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${token}` } });
    sockets.push(socket);
    const frames: Frame[] = [];
    let opened = false;
    socket.on("open", () => { opened = true; });
    socket.on("message", (raw) => frames.push(JSON.parse(raw.toString())));
    await waitFor(() => opened, "the phone socket to open");
    socket.send(JSON.stringify({ type: "hello", protocolVersion: 8, clientRole: "mobile" }));
    await waitFor(() => frames.some((frame) => frame.type === "hello"), "the hello frame");
    let closedSeen = false;
    socket.on("close", () => { closedSeen = true; });
    const requests = () => frames.filter((frame) => frame.type === "event" && frame.topic === "device.preference.request").map((frame) => frame.payload as Frame);
    const reply = (id: string, method: string, params: Record<string, unknown>) => {
      socket.send(JSON.stringify({ type: "request", id, method, params }));
      return waitFor(() => frames.some((frame) => frame.id === id), "the phone reply response").then(() => frames.find((frame) => frame.id === id)!);
    };
    return { socket, requests, reply, frames, closed: () => closedSeen, close: () => socket.close() };
  };

  const home = (changes: Array<Record<string, unknown>>, extra: Record<string, unknown> = {}) =>
    settingsChanges.change(HOME, changes as never, { actor: { kind: "home", id: "home" }, reason: "Set Swift files", ...extra });
  const resolveKey = async (): Promise<ResolvedKey> => {
    const resolution = await service.invoke({ id: "test", identity: "local", isLocal: true } as never, "settings.resolve", { target: HOME, keys: [KEY] }) as unknown as Resolution;
    return resolution.keys.find((row) => row.key === KEY)!;
  };
  return { phone, other, connect, home, resolveKey, server: server!, service, settingsChanges, bridge, port };
}

describe("Run Swift files device preference over the real socket", () => {
  it("reads the explicit iPhone through its authenticated socket, changes it with CAS, audits and undoes", async () => {
    const f = await fixture();
    const iphone = await f.connect(f.phone.token);
    const resolving = f.resolveKey();
    await waitFor(() => iphone.requests().some((request) => request.action === "read"), "the read request");
    const read = iphone.requests().find((request) => request.action === "read")!;
    expect(read).toMatchObject({ key: KEY });
    await iphone.reply("read-1", "device.preference.respond", { commandId: "read-command-1", requestId: read.requestId, status: "value", value: true });
    expect(await resolving).toMatchObject({ value: true, qualifiers: { device: f.phone.deviceId } });

    const changing = f.home([{ key: KEY, layer: "global", op: "set", value: false, qualifiers: { device: f.phone.deviceId }, expected: true }]);
    await waitFor(() => iphone.requests().some((request) => request.action === "read" && request.requestId !== read.requestId), "the fresh read before the write");
    const fresh = iphone.requests().filter((request) => request.action === "read").at(-1)!;
    await iphone.reply("read-2", "device.preference.respond", { commandId: "read-command-2", requestId: fresh.requestId, status: "value", value: true });
    await waitFor(() => iphone.requests().some((request) => request.action === "set"), "the CAS write request");
    const write = iphone.requests().find((request) => request.action === "set")!;
    expect(write).toMatchObject({ key: KEY, expected: true, value: false });
    await iphone.reply("set-1", "device.preference.respond", { commandId: "set-command-1", requestId: write.requestId, status: "applied" });
    const applied = await changing;
    expect(applied.status).toBe("applied");

    const undoing = f.settingsChanges.undo(applied.changes[0]!.changeId, { actor: { kind: "home", id: "home" }, reason: "Undo Swift files" });
    await waitFor(() => iphone.requests().filter((request) => request.action === "read").length >= 3, "the undo fresh read");
    const undoRead = iphone.requests().filter((request) => request.action === "read").at(-1)!;
    await iphone.reply("read-3", "device.preference.respond", { commandId: "read-command-3", requestId: undoRead.requestId, status: "value", value: false });
    await waitFor(() => iphone.requests().filter((request) => request.action === "set").length === 2, "the undo CAS write");
    const undoWrite = iphone.requests().filter((request) => request.action === "set").at(-1)!;
    expect(undoWrite).toMatchObject({ expected: false, value: true });
    await iphone.reply("set-2", "device.preference.respond", { commandId: "set-command-2", requestId: undoWrite.requestId, status: "applied" });
    expect((await undoing).status).toBe("applied");
    iphone.close();
  });

  it("refuses an ordinary agent and an offline iPhone before any send, with no mutation", async () => {
    const f = await fixture();
    await expect(f.settingsChanges.change(HOME, [{ key: KEY, layer: "global", op: "set", value: false, qualifiers: { device: f.phone.deviceId }, expected: true }] as never,
      { actor: { kind: "agent", id: "chat" }, reason: "Turn off Swift files" })).rejects.toThrow("cannot be changed by agent");
    expect((await f.resolveKey()).value).toBeNull();
    await expect(f.home([{ key: KEY, layer: "global", op: "set", value: false, qualifiers: { device: f.phone.deviceId } }]))
      .rejects.toMatchObject({ code: "busy" });
  });

  it("reports a disconnect after the write was sent as unknown, sends exactly one CAS, and inspects instead of replaying", async () => {
    const f = await fixture();
    const iphone = await f.connect(f.phone.token);
    const resolving = f.resolveKey();
    await waitFor(() => iphone.requests().length >= 1, "the read request");
    await iphone.reply("read-u1", "device.preference.respond", { commandId: "read-u-command-1", requestId: iphone.requests()[0]!.requestId, status: "value", value: true });
    await resolving;
    const changing = f.home([{ key: KEY, layer: "global", op: "set", value: false, qualifiers: { device: f.phone.deviceId }, expected: true }]).then(() => undefined, (error: Error) => error);
    await waitFor(() => iphone.requests().length >= 2, "the fresh read before the write");
    const fresh = iphone.requests().at(-1)!;
    await iphone.reply("read-u2", "device.preference.respond", { commandId: "read-u-command-2", requestId: fresh.requestId, status: "value", value: true });
    await waitFor(() => iphone.requests().some((request) => request.action === "set"), "the CAS write request");
    iphone.close();
    const error = await changing;
    expect(error?.message).toContain("unknown outcome");
    expect(iphone.requests().filter((request) => request.action === "set")).toHaveLength(1);
    const reconnected = await f.connect(f.phone.token);
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(reconnected.requests().filter((request) => request.action === "set")).toHaveLength(0);
    const inspecting = f.resolveKey();
    await waitFor(() => reconnected.requests().some((request) => request.action === "read" && request.requestId !== fresh.requestId), "the inspection read");
    const inspect = reconnected.requests().at(-1)!;
    await reconnected.reply("read-u3", "device.preference.respond", { commandId: "read-u-command-3", requestId: inspect.requestId, status: "value", value: false });
    expect(await inspecting).toMatchObject({ value: false });
    reconnected.close();
  });

  it("refuses replies from another device, an older connection of the same device and a loopback caller, leaving the pending request intact", async () => {
    const f = await fixture();
    const older = await f.connect(f.phone.token);
    const newer = await f.connect(f.phone.token);
    const resolving = f.resolveKey();
    await waitFor(() => newer.requests().length >= 1, "the read request on the newest connection");
    expect(older.requests()).toHaveLength(0);
    const pending = newer.requests()[0]!;
    const impostor = await f.connect(f.other.token);
    expect(await impostor.reply("spoof-1", "device.preference.respond", { commandId: "spoof-command-1", requestId: pending.requestId, status: "value", value: false }))
      .toMatchObject({ ok: false, error: { code: "not_found" } });
    expect(await older.reply("stale-1", "device.preference.respond", { commandId: "stale-command-1", requestId: pending.requestId, status: "value", value: false }))
      .toMatchObject({ ok: false, error: { code: "not_found" } });
    await expect(f.service.invoke({ id: "loopback", identity: "local-wrapper", isLocal: true } as never, "device.preference.respond",
      { commandId: "loopback-command-1", requestId: pending.requestId, status: "value", value: false })).rejects.toMatchObject({ code: "auth_required" });
    expect(await newer.reply("live-1", "device.preference.respond", { commandId: "live-command-1", requestId: pending.requestId, status: "value", value: true }))
      .toMatchObject({ ok: true });
    expect(await resolving).toMatchObject({ value: true });
    older.close(); newer.close(); impostor.close();
  });
});
