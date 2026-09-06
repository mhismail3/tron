import { request } from "node:http";
import { mkdtemp, mkdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Readable } from "node:stream";
import WebSocket from "ws";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it, vi } from "vitest";
import { TrustService } from "../admin/trust-service.js";
import { DeviceStore } from "../security/device-store.js";
import { RuntimeRegistry } from "../sessions/runtime-registry.js";
import { CommandReceiptStore } from "./command-receipts.js";
import { GatewayService } from "./gateway-service.js";
import { GatewayServer } from "./server.js";
import type { AsyncMutex } from "../util/async-mutex.js";

function gate() {
  let resolve!: () => void;
  let released = false;
  const promise = new Promise<void>((done) => { resolve = done; });
  return { promise, release: () => { released = true; resolve(); }, get released() { return released; } };
}

async function until(predicate: () => boolean | Promise<boolean>) {
  const end = Date.now() + 5_000;
  while (!await predicate()) {
    if (Date.now() >= end) throw new Error("Revocation observation timed out");
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}

const cleanup: Array<() => Promise<void>> = [];
afterEach(async () => {
  // Drain every owner even when an earlier fixture's disposal fails.
  const results = await Promise.allSettled(cleanup.splice(0).map((dispose) => dispose()));
  vi.restoreAllMocks();
  const failures = results.filter((result) => result.status === "rejected");
  if (failures.length) throw new AggregateError(failures.map((result) => result.reason), "Revocation fixture cleanup failed");
});

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "tron-revocation-boundary-"));
  const agentDir = join(root, "agent");
  const cwd = join(root, "project");
  let registry: RuntimeRegistry | undefined;
  let server: GatewayServer | undefined;
  let devices: DeviceStore | undefined;
  const sockets: WebSocket[] = [];
  const http: ReturnType<typeof request>[] = [];
  const releases: Array<() => void> = [];
  const pending = new Set<Promise<unknown>>();
  cleanup.push(async () => {
    releases.forEach((release) => release());
    sockets.forEach((socket) => socket.terminate());
    http.forEach((outgoing) => outgoing.destroy());
    // RPC rejection is observed by GatewayServer; it is not a disposal error.
    await Promise.allSettled([...pending]);
    try {
      await server?.close();
    } finally {
      try {
        await registry?.dispose();
        // Pairing queues invitation regeneration on this same store mutex.
        await devices?.ensureEnrollment();
      } finally {
        await rm(root, { recursive: true, force: true });
      }
    }
  });
  await Promise.all([mkdir(agentDir), mkdir(cwd)]);
  const faux = fauxProvider({ provider: "revocation-fixture", tokensPerSecond: 100_000 });
  faux.setResponses([fauxAssistantMessage("one accepted response")]);
  registry = new RuntimeRegistry({
    agentDir, tronHome: root, idleRuntimeMs: 60_000,
    modelRuntimeFactory: async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    },
    trust: new TrustService(agentDir),
    broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
  });
  await registry.initialize();
  devices = new DeviceStore(root, "fixture-machine");
  await devices.initialize();
  const pair = async () => {
    const invitation = await devices!.ensureEnrollment();
    const paired = await devices!.pair(invitation.code, "Fixture phone");
    await devices!.ensureEnrollment();
    return paired;
  };
  const paired = await pair();
  const receipts = new CommandReceiptStore(root);
  const uploads = {
    acquire: vi.fn(async () => ({ mimeType: "text/plain", size: 2, name: "fixture", stream: Readable.from(["ok"]), release: async () => {} })),
    materialize: vi.fn(async () => ({ envelope: "", images: [], attachments: [], photoCount: 0, fileAttachmentCount: 0 })),
  };
  const install = { isUsable: false, removeDevice: vi.fn(async () => {}) };
  let terminal: { id: string; sessionId: string; state: string } | undefined;
  // Only the PTY effect is synthetic; transport ownership and receipts are real.
  const terminals = {
    open: vi.fn((sessionId: string) => (terminal = { id: "fixture-terminal", sessionId, state: "running" })),
    attach: () => ({ terminal, chunks: [], reset: false }),
    belongsToSession: (id: string, sessionId: string) => terminal?.id === id && terminal.sessionId === sessionId,
  };
  const service = new GatewayService({
    config: { tronHome: root }, devices, sessions: registry, receipts, uploads, terminals,
    logger: { log: () => {} }, iosDeviceInstallService: install,
  } as never);
  const invoke = service.invoke.bind(service);
  vi.spyOn(service, "invoke").mockImplementation((...args) => {
    const task = invoke(...args);
    pending.add(task);
    void task.then(() => pending.delete(task), () => pending.delete(task));
    return task;
  });
  server = new GatewayServer({
    host: "127.0.0.1", port: 0, maxFrameBytes: 1_048_576,
    devices, sessions: registry, service, uploads: uploads as never,
    auth: { cancelOwner: () => {}, detachClient: () => {} } as never,
    logger: { log: () => {} } as never,
  });
  await server.listen();
  const port = (server as any).server.address().port as number;
  const connect = async (token = paired.token) => {
    const socket = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${token}` } });
    sockets.push(socket);
    const frames: any[] = [];
    let opened = false;
    let closed: number | undefined;
    let error: Error | undefined;
    socket.on("open", () => { opened = true; });
    socket.on("error", (value) => { error = value; });
    socket.on("close", (code) => { closed = code; });
    socket.on("message", (raw) => frames.push(JSON.parse(raw.toString())));
    await until(() => opened || error !== undefined);
    if (error) throw error;
    socket.send(JSON.stringify({ type: "hello", protocolVersion: 4 }));
    await until(() => frames.some((frame) => frame.type === "hello"));
    return {
      socket, frames, closed: () => closed,
      send: (id: string, method: string, params: object) => socket.send(JSON.stringify({ type: "request", id, method, params })),
      response: async (id: string) => {
        await until(() => frames.some((frame) => frame.id === id));
        return frames.find((frame) => frame.id === id);
      },
    };
  };
  const hold = () => { const value = gate(); releases.push(value.release); return value; };
  return { root, cwd, registry, devices, paired, pair, receipts, uploads, install, terminals, service, server, port, connect, hold, sockets, http, pending, faux };
}

describe("device revocation at real ownership boundaries", () => {
  it.each(["http", "websocket"] as const)("does not publish stale %s admission after a captured credential read", async (transport) => {
    const f = await fixture();
    const captured = gate();
    const resume = f.hold();
    const order: string[] = [];
    const internals = f.devices as unknown as { mutex: AsyncMutex; authenticateLocked: (token: string) => Promise<unknown> };
    const originalRun = internals.mutex.run.bind(internals.mutex);
    let mutexActive = false;
    vi.spyOn(internals.mutex, "run").mockImplementation((operation) => originalRun(async () => {
      mutexActive = true;
      try { return await operation(); } finally { mutexActive = false; }
    }));
    const authenticate = internals.authenticateLocked.bind(internals);
    let capturedUnderMutex = false;
    vi.spyOn(internals, "authenticateLocked").mockImplementation(async (token) => {
      const identity = await authenticate(token); // The real durable credential result, not a pre-read gate.
      capturedUnderMutex = mutexActive;
      captured.release();
      await resume.promise;
      return identity;
    });
    let finished = false;
    let requestError: Error | undefined;
    let status: number | undefined;
    let outgoing: ReturnType<typeof request> | undefined;
    const acquire = f.uploads.acquire.getMockImplementation()!;
    f.uploads.acquire.mockImplementation(async () => { order.push("admitted"); return acquire(); });
    const admit = (f.server as any).admit.bind(f.server);
    vi.spyOn(f.server as any, "admit").mockImplementation((...args: any[]) => { order.push("admitted"); return admit(...args); });
    if (transport === "http") {
      outgoing = request({ host: "127.0.0.1", port: f.port, path: "/v1/uploads/fixture", headers: { authorization: `Bearer ${f.paired.token}` } }, (response) => {
        status = response.statusCode;
        response.resume();
        response.on("end", () => { finished = true; });
      });
      outgoing.on("error", (error) => { requestError = error; finished = true; });
      outgoing.end();
    } else {
      const socket = new WebSocket(`ws://127.0.0.1:${f.port}/v1/socket`, { headers: { authorization: `Bearer ${f.paired.token}` } });
      f.sockets.push(socket);
      socket.on("error", () => {}); // A legal revocation-first ordering rejects the upgrade.
      socket.on("close", () => { finished = true; });
    }
    let revocation: Promise<boolean> | undefined;
    try {
      await until(() => captured.released);
      revocation = f.devices.revoke(f.paired.deviceId, () => {
        order.push("retired");
        f.server.disconnectDevice(f.paired.deviceId);
      });
      // Instrumentation controls scheduling only. If the credential read has
      // escaped serialization, let the real durable revoke finish before its
      // captured result resumes. The oracle below is observable publication.
      if (!capturedUnderMutex) await revocation;
      resume.release();
      await revocation;
      await until(() => finished || order.includes("admitted"));
      // Admission may win, or revalidation may reject after revocation wins;
      // only publishing an admitted effect AFTER retirement is illegal.
      expect([["admitted", "retired"], ["retired"]]).toContainEqual(order);
      await until(() => finished);
      if (requestError) throw requestError;
      if (transport === "http") expect(status).toBe(order.includes("admitted") ? 200 : 401);
    } finally {
      resume.release();
      outgoing?.destroy();
      await revocation;
    }
  });

  it("does not retain the credential mutex while an admitted HTTP read waits", async () => {
    const f = await fixture();
    const entered = gate();
    const resume = f.hold();
    const acquire = f.uploads.acquire.getMockImplementation()!;
    f.uploads.acquire.mockImplementation(async () => { entered.release(); await resume.promise; return acquire(); });
    let status: number | undefined;
    let finished = false;
    let error: Error | undefined;
    const outgoing = request({ host: "127.0.0.1", port: f.port, path: "/v1/uploads/fixture", headers: { authorization: `Bearer ${f.paired.token}` } }, (response) => {
      status = response.statusCode;
      response.resume();
      response.on("end", () => { finished = true; });
    });
    f.http.push(outgoing);
    outgoing.on("error", (value) => { error = value; finished = true; });
    outgoing.end();
    await until(() => entered.released);
    let retired = false;
    const revocation = f.devices.revoke(f.paired.deviceId, () => { retired = true; f.server.disconnectDevice(f.paired.deviceId); });
    f.pending.add(revocation);
    await until(() => retired);
    expect(finished).toBe(false);
    resume.release();
    await until(() => finished);
    expect(error).toBeUndefined();
    expect(status).toBe(200);
  });

  it.each(["receipt", "materialization"] as const)("preserves an actual accepted prompt across revocation during %s", async (stage) => {
    const f = await fixture();
    const slot = await f.registry.create(f.cwd);
    const model = f.faux.getModel();
    await slot.setModel(model.provider, model.id);
    const peer = await f.connect();
    peer.send("open", "session.open", { sessionId: slot.id });
    const opened = await peer.response("open");
    expect(opened.ok).toBe(true);
    peer.send("sync", "session.sync", { sessionId: slot.id, syncToken: opened.result.syncToken });
    expect((await peer.response("sync")).ok).toBe(true);
    const entered = gate();
    const resume = f.hold();
    const execute = f.receipts.execute.bind(f.receipts);
    vi.spyOn(f.receipts, "execute").mockImplementation(async (...args) => {
      if (stage === "receipt" && args[1] === "session.prompt") { entered.release(); await resume.promise; }
      return execute(...args);
    });
    if (stage === "materialization") {
      const materialize = f.uploads.materialize.getMockImplementation()!;
      f.uploads.materialize.mockImplementation(async () => { entered.release(); await resume.promise; return materialize(); });
    }
    peer.send("prompt", "session.prompt", { sessionId: slot.id, text: "exactly once", commandId: "revocation-prompt-command" });
    await until(() => entered.released);
    await f.devices.revoke(f.paired.deviceId, () => f.server.disconnectDevice(f.paired.deviceId));
    await until(() => peer.closed() !== undefined);
    (slot as any).lastTouchedAt = 0;
    await (f.registry as any).evictIdle();
    expect(slot.isDisposed).toBe(false);
    expect(slot.isEvictionProtected).toBe(true);
    resume.release();
    // Observe service settlement before reading durable evidence. A status
    // read racing initial receipt creation can conservatively report unknown.
    await until(() => f.pending.size === 0);
    expect(await f.receipts.status(f.paired.deviceId, "session.prompt", "revocation-prompt-command")).toMatchObject({ status: "completed" });
    await until(() => !slot.isBusy);
    expect(peer.frames.some((frame) => frame.id === "prompt")).toBe(false);
    // Replay through the durable owner must return its result without invoking
    // the operation again, even though the originating socket is gone.
    const repeat = vi.fn(async () => ({}));
    await new CommandReceiptStore(f.root).execute(f.paired.deviceId, "session.prompt", "revocation-prompt-command", repeat);
    expect(repeat).not.toHaveBeenCalled();
    const messages = slot.snapshot().transcript.filter((item) => item.kind === "message");
    expect(messages.filter((item) => item.role === "user")).toHaveLength(1);
    expect(messages.filter((item) => item.role === "assistant")).toHaveLength(1);
  });

  it.each(["receipt", "acquisition"] as const)("preserves terminal creation without attaching a revoked observer during %s", async (stage) => {
    const f = await fixture();
    const slot = await f.registry.create(f.cwd);
    const peer = await f.connect();
    peer.send("open", "session.open", { sessionId: slot.id });
    const opened = await peer.response("open");
    peer.send("sync", "session.sync", { sessionId: slot.id, syncToken: opened.result.syncToken });
    await peer.response("sync");
    const connection = [...(f.server as any).clients.values()][0] as any;
    const entered = gate();
    const resume = f.hold();
    const execute = f.receipts.execute.bind(f.receipts);
    const acquire = f.registry.acquire.bind(f.registry);
    if (stage === "receipt") vi.spyOn(f.receipts, "execute").mockImplementation(async (...args) => {
      if (args[1] === "terminal.open") { entered.release(); await resume.promise; }
      return execute(...args);
    });
    else vi.spyOn(f.registry, "acquire").mockImplementation(async (...args) => {
      entered.release(); await resume.promise; return acquire(...args);
    });
    peer.send("terminal", "terminal.open", { sessionId: slot.id, commandId: "retired-terminal-command" });
    await until(() => entered.released);
    await f.devices.revoke(f.paired.deviceId, () => f.server.disconnectDevice(f.paired.deviceId));
    await until(() => peer.closed() !== undefined);
    (slot as any).lastTouchedAt = 0;
    await (f.registry as any).evictIdle();
    expect(slot.isDisposed).toBe(false);
    resume.release();
    await until(() => f.pending.size === 0);
    expect(f.terminals.open).toHaveBeenCalledOnce();
    expect(connection.terminals.size).toBe(0);
    expect(slot.isBusy).toBe(false);
    expect(await f.receipts.status(f.paired.deviceId, "terminal.open", "retired-terminal-command")).toMatchObject({ status: "completed" });
    expect(peer.frames.some((frame) => frame.id === "terminal")).toBe(false);
  });

  it("releases prompt retention when validation rejects before an effect", async () => {
    const f = await fixture();
    const slot = await f.registry.create(f.cwd);
    const peer = await f.connect();
    peer.send("open", "session.open", { sessionId: slot.id });
    await peer.response("open");
    peer.send("invalid", "session.prompt", { sessionId: slot.id, text: 42, commandId: "invalid-prompt-command" });
    expect(await peer.response("invalid")).toMatchObject({ ok: false, error: { code: "invalid_request" } });
    expect(slot.isBusy).toBe(false);
    expect(slot.isEvictionProtected).toBe(false);
  });

  it("retires a catalog lease installed after its revoked socket has closed", async () => {
    const f = await fixture();
    await f.registry.create(f.cwd);
    await f.registry.create(f.cwd);
    const peer = await f.connect();
    const entered = gate();
    const resume = f.hold();
    const source = await f.registry.pageSource("user");
    vi.spyOn(f.registry, "pageSource").mockResolvedValue({ ...source, page: async (...args) => {
      entered.release();
      await resume.promise;
      return source.page(...args);
    } });
    peer.send("list", "session.list", { limit: 1 });
    await until(() => entered.released);
    await f.devices.revoke(f.paired.deviceId, () => f.server.disconnectDevice(f.paired.deviceId));
    await until(() => peer.closed() !== undefined);
    resume.release();
    await until(() => f.pending.size === 0);
    expect((f.service as any).sessionListPages.activeLeaseCount).toBe(0);
    expect(peer.frames.some((frame) => frame.id === "list")).toBe(false);
  });

  it("releases observers immediately while the exact self acknowledgement waits behind an earlier write", async () => {
    const f = await fixture();
    await f.registry.create(f.cwd);
    await f.registry.create(f.cwd);
    const peer = await f.connect();
    peer.send("list", "session.list", { limit: 1 });
    expect((await peer.response("list")).result.nextCursor).toBeTypeOf("string");
    expect((f.service as any).sessionListPages.activeLeaseCount).toBe(1);
    const connection = [...(f.server as any).clients.values()][0] as any;
    const resume = f.hold();
    const originalSend = connection.socket.send.bind(connection.socket);
    vi.spyOn(connection.socket, "send").mockImplementationOnce((...args: any[]) => {
      const write = resume.promise.then(() => originalSend(...args));
      f.pending.add(write);
      void write.then(() => f.pending.delete(write), () => f.pending.delete(write));
    });
    f.server.broadcast("test.earlier", {});
    peer.send("self", "device.revoke", { deviceId: f.paired.deviceId, commandId: "ordered-self-revoke-command" });
    await until(() => connection.outbound.snapshot().queuedFrames === 2);
    expect((f.service as any).sessionListPages.activeLeaseCount).toBe(0);
    expect(peer.closed()).toBeUndefined();
    f.server.broadcast("test.retired", {});
    expect(connection.outbound.snapshot().queuedFrames).toBe(2);
    resume.release();
    expect(await peer.response("self")).toMatchObject({ ok: true, result: { revoked: true } });
    await until(() => peer.closed() !== undefined);
    expect(peer.frames.findIndex((frame) => frame.topic === "test.earlier"))
      .toBeLessThan(peer.frames.findIndex((frame) => frame.id === "self"));
    expect(peer.frames.some((frame) => frame.topic === "test.retired")).toBe(false);
  });

  it("returns an existing prompt receipt after ordinary reconnect without reacquiring the session", async () => {
    const f = await fixture();
    const slot = await f.registry.create(f.cwd);
    const model = f.faux.getModel();
    await slot.setModel(model.provider, model.id);
    const peer = await f.connect();
    peer.send("open", "session.open", { sessionId: slot.id });
    const opened = await peer.response("open");
    peer.send("sync", "session.sync", { sessionId: slot.id, syncToken: opened.result.syncToken });
    await peer.response("sync");
    const params = { sessionId: slot.id, text: "only once", commandId: "reconnected-prompt-command" };
    peer.send("prompt", "session.prompt", params);
    const first = await peer.response("prompt");
    expect(first.ok).toBe(true);
    await until(() => !slot.isBusy);
    peer.socket.terminate();
    await until(() => (f.server as any).clients.size === 0);
    (slot as any).lastTouchedAt = 0;
    await (f.registry as any).evictIdle();
    expect(slot.isDisposed).toBe(true);
    const replacement = await f.connect();
    replacement.send("repeated", "session.prompt", params);
    expect(await replacement.response("repeated")).toMatchObject({ ok: true, result: first.result });
    expect((f.registry as any).slots.size).toBe(0);
  });

  it.each([
    { target: "same", requester: "origin" },
    { target: "other", requester: "origin" },
    { target: "same", requester: "observer" },
  ])("keeps the exact self acknowledgement with $target target and $requester requester", async ({ target, requester }) => {
    const f = await fixture();
    const other = await f.pair();
    const peer = await f.connect();
    const observer = await f.connect();
    const unrelated = await f.connect(other.token);
    const waiting = f.hold();
    const bothAdmitted = f.hold();
    const acknowledgement = f.hold();
    const execute = f.receipts.execute.bind(f.receipts);
    let selfCompleted = false;
    vi.spyOn(f.receipts, "execute").mockImplementation(async (...args) => {
      if (args[2] === "other-revoke-command") { bothAdmitted.release(); await waiting.promise; }
      if (args[2] === "self-revoke-command") await bothAdmitted.promise;
      const result = await execute(...args);
      if (args[2] === "self-revoke-command") { selfCompleted = true; await acknowledgement.promise; }
      return result;
    });
    peer.send("self", "device.revoke", { deviceId: f.paired.deviceId, commandId: "self-revoke-command" });
    (requester === "origin" ? peer : observer).send("other", "device.revoke", { deviceId: target === "same" ? f.paired.deviceId : other.deviceId, commandId: "other-revoke-command" });
    await until(() => selfCompleted && observer.closed() !== undefined);
    expect(peer.closed()).toBeUndefined();
    expect(observer.closed()).toBe(1008);
    waiting.release();
    await until(() => f.pending.size === 1);
    expect(await f.receipts.status(f.paired.deviceId, "device.revoke", "other-revoke-command")).toMatchObject({ status: "completed" });
    acknowledgement.release();
    expect(await peer.response("self")).toMatchObject({ ok: true, result: { revoked: true } });
    await until(() => peer.closed() !== undefined && f.pending.size === 0);
    expect(peer.frames.filter((frame) => frame.type === "response").map((frame) => frame.id)).toEqual(["self"]);
    if (target === "other") await until(() => unrelated.closed() === 1008);
    else expect(unrelated.closed()).toBeUndefined();
    expect(await f.receipts.status(f.paired.deviceId, "device.revoke", "other-revoke-command")).toMatchObject({ status: "completed" });
  });
});
