import { displayOwnerOf, createTestRegistry } from "../../../test-support/gateway-registry.js";
import { TEST_SETTINGS_SCHEMA } from "../../../test-support/settings-schema.js";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
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
import { SettingsChangeRecord, type ChangeEntry } from "../../kernel/settings/settings-record.js";
import type { Resolution, ResolvedKey } from "../../kernel/settings/tool-contract.js";
import { waitFor } from "../../../test-support/wait-for.js";

const KEY = "experimental.swiftApps";
const HOME = { kind: "home" } as const;
const HOME_ACTOR = { kind: "home", id: "home" } as const;
const WORKER_KEY = "model.thinking[role=worker]";

const cleanup: Array<() => Promise<void>> = [];
afterEach(async () => {
  const results = await Promise.allSettled(cleanup.splice(0).map((dispose) => dispose()));
  vi.restoreAllMocks();
  const failures = results.filter((result) => result.status === "rejected");
  if (failures.length) throw new AggregateError(failures.map((result) => result.reason), "Device preference fixture cleanup failed");
});

type Frame = Record<string, any>;
type PhoneRequest = Record<string, any>;

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "tron-device-preference-"));
  const agentDir = join(root, "agent");
  const profilePath = join(root, "state", "home", "profile.json");
  await mkdir(agentDir);
  await mkdir(join(root, "state", "home"), { recursive: true });
  await writeFile(profilePath, "{}");
  const sockets: WebSocket[] = [];
  let server: GatewayServer | undefined;
  let registry: RuntimeRegistry | undefined;
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

  const bridge = new DevicePreferenceBridge({
    pairedDevices: async () => (await devices.listDevices()).map((device) => device.id),
    newestReadyConnection: (deviceId, capability) => server!.newestReadyDeviceConnection(deviceId, capability),
    send: (connectionId, topic, payload) => server!.emitToClient(connectionId, topic, payload as never),
  });
  const trust = new TrustService(agentDir);
  const settingsModel = new SettingsModel(new SettingsStoreAdapter({ schema: TEST_SETTINGS_SCHEMA, agentDir, tronHome: root, trust,
    modelRuntime: await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }) }));
  const settingsChanges = new SettingsChangePath(settingsModel, new SettingsChangeRecord(root), {
    setTrust: async () => { throw new Error("trust is not exercised here"); },
  });
  const service = new GatewayService({ display: displayOwnerOf(registry),
    config: { machineId: "machine", machineGroupID: "group", machineName: "Mac", tronHome: root, agentDir },
    devices, sessions: registry, receipts: new CommandReceiptStore(root), uploads: {} as never, trust,
    settingsModel, settingsChanges, modelRuntime: settingsModel.owner.modelRuntime,
    broadcast: () => {}, globalProviderResources: { withStableSnapshot: async (operation: () => Promise<unknown>) => operation(), requestReload: () => {} },
  } as never);
  server = new GatewayServer({ display: displayOwnerOf(registry), host: "127.0.0.1", port: 0, maxFrameBytes: 1_048_576,
    devices, sessions: registry, service, uploads: {} as never,
    auth: { cancelOwner: () => {}, detachClient: () => {} } as never, logger: { log: () => {} } as never,
  });
  await server.listen();
  const port = (server as any).server.address().port as number;

  const connect = async (token: string, capabilities: string[] = ["device-preference"]) => {
    const socket = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${token}` } });
    sockets.push(socket);
    const frames: Frame[] = [];
    let opened = false;
    socket.on("open", () => { opened = true; });
    socket.on("message", (raw) => frames.push(JSON.parse(raw.toString())));
    await waitFor(() => opened, "the phone socket to open");
    socket.send(JSON.stringify({ type: "hello", protocolVersion: 8, clientRole: "mobile", capabilities }));
    await waitFor(() => frames.some((frame) => frame.type === "hello"), "the hello frame");
    let ids = 0;
    const requests = (action?: string): PhoneRequest[] => frames
      .filter((frame) => frame.type === "event" && frame.topic === "device.preference.request")
      .map((frame) => frame.payload as PhoneRequest)
      .filter((request) => action === undefined || request.action === action);
    const send = (method: string, params: object) => {
      const id = `phone-${++ids}`;
      socket.send(JSON.stringify({ type: "request", id, method, params }));
      return waitFor(() => frames.some((frame) => frame.id === id), "the phone reply response").then(() => frames.find((frame) => frame.id === id)!);
    };
    return {
      socket, frames, requests,
      answer: (request: PhoneRequest, body: Record<string, unknown>) => send("device.preference.respond",
        { commandId: randomUUID(), requestId: request.requestId, ...body }),
      waitFor: (action: string, count: number) => waitFor(() => requests(action).length >= count, `${action} request ${count}`),
      close: () => socket.close(),
    };
  };
  const device = { device: phone.deviceId };
  const home = (changes: Array<Record<string, unknown>>, reason = "Set Swift files") =>
    settingsChanges.change(HOME, changes as never, { actor: HOME_ACTOR, reason });
  const resolveKey = async (): Promise<ResolvedKey> => {
    const resolution = await service.invoke({ id: "test", identity: "local", isLocal: true } as never, "settings.resolve", { target: HOME, keys: [KEY] }) as unknown as Resolution;
    return resolution.keys.find((row) => row.key === KEY)!;
  };
  const history = async (key: string): Promise<ChangeEntry[]> => (await settingsChanges.history({ key, limit: 50 }, HOME_ACTOR)).entries;
  return { root, profilePath, phone, other, device, connect, home, resolveKey, history, settingsChanges, server, service, bridge, port };
}

describe("Run Swift files device preference over the real socket (Gateway service and settings change path; phone scripted; the Home tool and the iOS owner are not exercised here)", () => {
  it("changes the explicit iPhone with CAS, records one applied history entry, and undoes it through a fresh read", async () => {
    const f = await fixture();
    const iphone = await f.connect(f.phone.token);
    const resolving = f.resolveKey();
    await iphone.waitFor("read", 1);
    expect(await iphone.answer(iphone.requests("read")[0]!, { status: "value", value: true })).toMatchObject({ ok: true });
    expect(await resolving).toMatchObject({ value: true, qualifiers: f.device });

    const changing = f.home([{ key: KEY, layer: "global", op: "set", value: false, qualifiers: f.device, expected: true }]);
    await iphone.waitFor("read", 2);
    await iphone.answer(iphone.requests("read")[1]!, { status: "value", value: true });
    await iphone.waitFor("set", 1);
    expect(iphone.requests("set")[0]).toMatchObject({ key: KEY, expected: true, value: false });
    expect(await iphone.answer(iphone.requests("set")[0]!, { status: "applied" })).toMatchObject({ ok: true });
    const applied = await changing;
    expect(applied).toMatchObject({ status: "applied" });

    const afterApply = await f.history(KEY);
    expect(afterApply).toHaveLength(1);
    expect(afterApply[0]).toMatchObject({ status: "applied", actor: HOME_ACTOR, layer: "global", op: "set", before: true, after: false, qualifiers: f.device, changeId: applied.changes[0]!.changeId });

    const undoing = f.settingsChanges.undo(applied.changes[0]!.changeId, { actor: HOME_ACTOR, reason: "Undo Swift files" });
    await iphone.waitFor("read", 3);
    await iphone.answer(iphone.requests("read")[2]!, { status: "value", value: false });
    await iphone.waitFor("set", 2);
    expect(iphone.requests("set")[1]).toMatchObject({ key: KEY, expected: false, value: true });
    await iphone.answer(iphone.requests("set")[1]!, { status: "applied" });
    expect(await undoing).toMatchObject({ status: "applied" });

    const afterUndo = await f.history(KEY);
    expect(afterUndo).toHaveLength(2);
    expect(afterUndo[0]).toMatchObject({ status: "applied", before: false, after: true, undoOf: applied.changes[0]!.changeId, actor: HOME_ACTOR, qualifiers: f.device });
    expect(iphone.requests("set")).toHaveLength(2);
    iphone.close();
  });

  it("after a later store fails, restores the iPhone with the reverse CAS on the value it actually holds", async () => {
    const f = await fixture();
    const iphone = await f.connect(f.phone.token);
    const resolving = f.resolveKey();
    await iphone.waitFor("read", 1);
    await iphone.answer(iphone.requests("read")[0]!, { status: "value", value: true });
    await resolving;

    const failing = f.home([
      { key: KEY, layer: "global", op: "set", value: false, qualifiers: f.device, expected: true },
      { key: WORKER_KEY, layer: "session", op: "set", value: "high" },
    ]).then(() => undefined, (error: Error & { details?: unknown }) => error);
    await iphone.waitFor("read", 2);
    await iphone.answer(iphone.requests("read")[1]!, { status: "value", value: true });
    await iphone.waitFor("set", 1);
    expect(iphone.requests("set")[0]).toMatchObject({ expected: true, value: false });
    await rm(f.profilePath);
    await mkdir(f.profilePath);
    await iphone.answer(iphone.requests("set")[0]!, { status: "applied" });
    await iphone.waitFor("set", 2);
    expect(iphone.requests("set")[1]).toMatchObject({ key: KEY, expected: false, value: true });
    await iphone.answer(iphone.requests("set")[1]!, { status: "applied" });

    const error = await failing;
    expect(error).toBeInstanceOf(Error);
    expect(iphone.requests("set")).toHaveLength(2);
    const entries = await f.history(KEY);
    expect(entries.map((entry) => entry.status)).toEqual(["failed"]);
    expect(entries[0]!.failure).toContain("Rolled back");
    iphone.close();
  });

  it("refuses a compensation after a subsequent iPhone edit, never overwrites it, and records the honest unrestored state", async () => {
    const f = await fixture();
    const iphone = await f.connect(f.phone.token);
    const resolving = f.resolveKey();
    await iphone.waitFor("read", 1);
    await iphone.answer(iphone.requests("read")[0]!, { status: "value", value: true });
    await resolving;

    const failing = f.home([
      { key: KEY, layer: "global", op: "set", value: false, qualifiers: f.device, expected: true },
      { key: WORKER_KEY, layer: "session", op: "set", value: "high" },
    ]).then(() => undefined, (error: Error) => error);
    await iphone.waitFor("read", 2);
    await iphone.answer(iphone.requests("read")[1]!, { status: "value", value: true });
    await iphone.waitFor("set", 1);
    await rm(f.profilePath);
    await mkdir(f.profilePath);
    await iphone.answer(iphone.requests("set")[0]!, { status: "applied" });
    await iphone.waitFor("set", 2);
    expect(iphone.requests("set")[1]).toMatchObject({ expected: false, value: true });
    expect(await iphone.answer(iphone.requests("set")[1]!, { status: "conflict", current: true })).toMatchObject({ ok: true });

    expect(await failing).toBeInstanceOf(Error);
    expect(iphone.requests("set")).toHaveLength(2);
    const entries = await f.history(KEY);
    expect(entries).toHaveLength(1);
    expect(entries[0]).toMatchObject({ status: "failed" });
    expect(entries[0]!.failure).toContain("Not rolled back");
    expect(entries[0]!.failure).toContain("refused its compensating write");
    iphone.close();
  });

  it("reports a disconnect after the write was sent as unknown, sends exactly one CAS, and inspects instead of replaying", async () => {
    const f = await fixture();
    const iphone = await f.connect(f.phone.token);
    const resolving = f.resolveKey();
    await iphone.waitFor("read", 1);
    await iphone.answer(iphone.requests("read")[0]!, { status: "value", value: true });
    await resolving;

    const changing = f.home([{ key: KEY, layer: "global", op: "set", value: false, qualifiers: f.device, expected: true }]).then(() => undefined, (error: Error) => error);
    await iphone.waitFor("read", 2);
    await iphone.answer(iphone.requests("read")[1]!, { status: "value", value: true });
    await iphone.waitFor("set", 1);
    iphone.close();
    expect((await changing)?.message).toContain("unknown outcome");
    expect(iphone.requests("set")).toHaveLength(1);

    const successor = await f.connect(f.phone.token);
    const inspecting = f.resolveKey();
    await successor.waitFor("read", 1);
    expect(successor.requests("set")).toHaveLength(0);
    await successor.answer(successor.requests("read")[0]!, { status: "value", value: false });
    expect(await inspecting).toMatchObject({ value: false });
    expect(await f.history(KEY)).toEqual([expect.objectContaining({ status: "failed" })]);
    successor.close();
  });

  it("fences an in-flight read: a successor connection cannot answer the superseded request, which settles unavailable", async () => {
    const f = await fixture();
    const older = await f.connect(f.phone.token);
    const resolving = f.resolveKey();
    await older.waitFor("read", 1);
    const superseded = older.requests("read")[0]!;
    older.close();
    expect(await resolving).toMatchObject({ value: null });
    const successor = await f.connect(f.phone.token);
    expect(await successor.answer(superseded, { status: "value", value: true })).toMatchObject({ ok: false, error: { code: "not_found" } });
    expect(successor.requests("read")).toHaveLength(0);
    successor.close();
  });

  it("is unavailable before any send to a ready paired iPhone that did not advertise the handler, and to an offline iPhone", async () => {
    const f = await fixture();
    const legacy = await f.connect(f.phone.token, []);
    expect(await f.resolveKey()).toMatchObject({ value: null });
    await expect(f.home([{ key: KEY, layer: "global", op: "set", value: false, qualifiers: f.device }])).rejects.toMatchObject({ code: "busy" });
    expect(legacy.requests()).toHaveLength(0);
    await expect(f.home([{ key: KEY, layer: "global", op: "set", value: false, qualifiers: { device: f.other.deviceId } }])).rejects.toMatchObject({ code: "busy" });
    expect(await f.history(KEY)).toEqual([]);
    legacy.close();
  });

  it("refuses an ordinary agent before any phone request", async () => {
    const f = await fixture();
    const iphone = await f.connect(f.phone.token);
    const refused = f.settingsChanges.change(HOME, [{ key: KEY, layer: "global", op: "set", value: false, qualifiers: f.device, expected: true }] as never,
      { actor: { kind: "agent", id: "chat" }, reason: "Turn off Swift files" }).then(() => undefined, (error: Error) => error);
    await iphone.waitFor("read", 1);
    await iphone.answer(iphone.requests("read")[0]!, { status: "value", value: true });
    expect((await refused)?.message).toContain("cannot be changed by agent");
    expect(iphone.requests("set")).toHaveLength(0);
    expect(await f.history(KEY)).toEqual([]);
    iphone.close();
  });

  it("refuses replies from another device, an older connection of the same device, and a loopback caller, leaving the pending request intact", async () => {
    const f = await fixture();
    const older = await f.connect(f.phone.token);
    const newer = await f.connect(f.phone.token);
    const resolving = f.resolveKey();
    await newer.waitFor("read", 1);
    expect(older.requests()).toHaveLength(0);
    const pending = newer.requests("read")[0]!;
    const impostor = await f.connect(f.other.token);
    expect(await impostor.answer(pending, { status: "value", value: false })).toMatchObject({ ok: false, error: { code: "not_found" } });
    expect(await older.answer(pending, { status: "value", value: false })).toMatchObject({ ok: false, error: { code: "not_found" } });
    await expect(f.service.invoke({ id: "loopback", identity: "local-wrapper", isLocal: true } as never, "device.preference.respond",
      { commandId: randomUUID(), requestId: pending.requestId, status: "value", value: false })).rejects.toMatchObject({ code: "auth_required" });
    expect(await newer.answer(pending, { status: "value", value: true })).toMatchObject({ ok: true });
    expect(await resolving).toMatchObject({ value: true });
    older.close(); newer.close(); impostor.close();
  });
});
