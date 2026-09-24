import { createServer, request } from "node:http";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import WebSocket from "ws";
import { afterEach, describe, expect, it, vi } from "vitest";
import { DeviceStore } from "../security/device-store.js";
import { CommandReceiptStore } from "./command-receipts.js";
import { GatewayService } from "./gateway-service.js";
import { GatewayServer, OrderedOutboundQueue } from "./server.js";

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => { await Promise.all(cleanups.splice(0).map((cleanup) => cleanup())); });

async function unusedPort(): Promise<number> {
  const probe = createServer();
  await new Promise<void>((resolve) => probe.listen(0, "127.0.0.1", resolve));
  const address = probe.address();
  if (!address || typeof address === "string") throw new Error("probe did not bind");
  await new Promise<void>((resolve) => probe.close(() => resolve()));
  return address.port;
}

async function waitUntil(predicate: () => boolean): Promise<void> {
  const deadline = Date.now() + 5_000;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error("condition timed out");
    await new Promise((resolve) => setTimeout(resolve, 1));
  }
}

async function bounded<T>(promise: Promise<T>, label: string): Promise<T> {
  let timer!: NodeJS.Timeout;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(`${label} timed out`)), 5_000);
    timer.unref();
  });
  try {
    return await Promise.race([promise, timeout]);
  } finally {
    clearTimeout(timer);
  }
}

describe("WebSocket connection and outbound capacity", () => {
  it("fails closed once on true aggregate queue overflow", () => {
    const writes: string[] = [];
    const overflow = vi.fn();
    const writeFailed = vi.fn();
    const queue = new OrderedOutboundQueue(
      1_024,
      (encoded) => { writes.push(encoded); },
      overflow,
      writeFailed,
    );

    expect(queue.enqueue("a".repeat(600))).toBe(true);
    expect(queue.enqueue("b".repeat(500))).toBe(false);
    expect(queue.enqueue("c")).toBe(false);
    expect(writes).toEqual(["a".repeat(600)]);
    expect(overflow).toHaveBeenCalledTimes(1);
    expect(overflow.mock.calls[0]?.[0]).toMatchObject({ queuedFrames: 1, queuedBytes: 600, writeActive: true });
    expect(overflow.mock.calls[0]?.[1]).toBe(500);
    expect(writeFailed).not.toHaveBeenCalled();
  });

  it("releases completed payloads with their byte reservations while the writer stays busy", () => {
    const completions: Array<(error?: Error) => void> = [];
    const queue = new OrderedOutboundQueue(4_096, (_encoded, done) => { completions.push(done); }, vi.fn(), vi.fn());
    expect(queue.enqueue("a".repeat(1_024))).toBe(true);
    expect(queue.enqueue("b".repeat(1_024))).toBe(true);
    // The independent oracle measures actual retained payloads, not the very
    // byte counter whose reservation used to be released prematurely.
    const retained = queue as unknown as { frames: Array<{ encoded: string } | undefined> };
    for (let index = 0; index < 2_050; index += 1) {
      completions.shift()!();
      expect(queue.enqueue(String(index).padEnd(1_024, "x"))).toBe(true);
      const actualBytes = retained.frames.reduce((sum, frame) => sum + (frame ? Buffer.byteLength(frame.encoded) : 0), 0);
      expect(actualBytes).toBe(2_048);
      expect(queue.snapshot().queuedBytes).toBe(actualBytes);
    }
    queue.retire();
    expect(retained.frames).toEqual([]);
    completions.shift()!(); // A late callback cannot resurrect the retired queue.
    expect(queue.snapshot().queuedBytes).toBe(0);
  });

  it("bounds tiny-frame bursts by count as well as encoded bytes", () => {
    const overflow = vi.fn();
    const write = vi.fn();
    const queue = new OrderedOutboundQueue(8 * 1_048_576, write, overflow, vi.fn());
    for (let index = 0; index < 4_096; index += 1) expect(queue.enqueue("{}")).toBe(true);
    expect(queue.enqueue("{}")).toBe(false);
    expect(queue.enqueue("{}")).toBe(false);
    expect(write).toHaveBeenCalledTimes(1);
    expect(overflow).toHaveBeenCalledTimes(1);
    expect(overflow.mock.calls[0]?.[0]).toMatchObject({
      queuedFrames: 4_096, queuedBytes: 8_192, maximumFrames: 4_096,
      maximumBytes: 8 * 1_048_576, frameHighWater: 4_096, byteHighWater: 8_192,
    });
  });

  it("reports an asynchronous write failure once and retires queued frames", () => {
    let completion: ((error?: Error) => void) | undefined;
    const overflow = vi.fn();
    const writeFailed = vi.fn();
    const queue = new OrderedOutboundQueue(
      4_096,
      (_encoded, callback) => { completion = callback; },
      overflow,
      writeFailed,
    );

    expect(queue.enqueue("first")).toBe(true);
    expect(queue.enqueue("second")).toBe(true);
    completion?.(new Error("socket write failed"));
    completion?.(new Error("duplicate callback"));
    expect(writeFailed).toHaveBeenCalledTimes(1);
    expect(writeFailed.mock.calls[0]?.[0]).toMatchObject({ message: "socket write failed" });
    expect(queue.enqueue("third")).toBe(false);
    expect(overflow).not.toHaveBeenCalled();
  });

  it("delivers a real same-turn burst above the retired 2 MiB threshold in exact order", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-server-large-burst-"));
    const devices = new DeviceStore(root, "machine");
    await devices.initialize();
    const token = JSON.parse(await readFile(join(root, "gateway", "local-auth.json"), "utf8")).bearerToken;
    const port = await unusedPort();
    const logger = { log: vi.fn() };
    const gateway = new GatewayServer({
      host: "127.0.0.1",
      port,
      maxFrameBytes: 1_048_576,
      maximumOutboundBytes: 8 * 1_048_576,
      devices,
      uploads: {} as any,
      sessions: { unsubscribeClient: vi.fn() } as any,
      auth: { detachClient: vi.fn(), cancelOwner: vi.fn() } as any,
      service: {
        info: () => ({ gatewayVersion: "test", piVersion: "test", protocolVersion: 5, minProtocolVersion: 5, machineId: "machine", machineName: "test", capabilities: [] }),
        terminalBelongsToSession: () => false,
        releaseClient: vi.fn(),
        invoke: vi.fn(),
      } as any,
      logger: logger as any,
    });
    await gateway.listen();
    cleanups.push(async () => { await gateway.close(); });

    const socket = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${token}` } });
    const sequences: number[] = [];
    socket.on("message", (raw) => {
      const frame = JSON.parse(raw.toString());
      if (frame.topic === "test.large") sequences.push(frame.payload.sequence);
    });
    await new Promise<void>((resolve) => socket.once("open", () => resolve()));
    socket.send(JSON.stringify({ type: "hello", protocolVersion: 5 }));
    await waitUntil(() => logger.log.mock.calls.some((call) => call[2]?.event === "connection.opened"));

    const prepareBroadcastFrame = vi.spyOn(gateway as any, "prepareBroadcastFrame");
    const sendOutcome = vi.spyOn(gateway as any, "sendOutcome");
    const payload = "x".repeat(512 * 1_024);
    for (let sequence = 1; sequence <= 6; sequence += 1) {
      gateway.broadcast("test.large", { sequence, payload });
    }
    await waitUntil(() => sequences.length === 6);
    expect(sequences).toEqual([1, 2, 3, 4, 5, 6]);
    expect(prepareBroadcastFrame).toHaveBeenCalledTimes(6);
    const broadcastFrames = sendOutcome.mock.calls
      .filter(([, value]) => (value as { topic?: string })?.topic === "test.large")
      .map(([, , prepared]) => prepared);
    expect(broadcastFrames).toHaveLength(6);
    expect(broadcastFrames).toEqual(prepareBroadcastFrame.mock.results.map((result) => result.value));
    expect(socket.readyState).toBe(WebSocket.OPEN);
    expect(logger.log.mock.calls.some((call) => call[2]?.event === "connection.outbound-capacity")).toBe(false);
    socket.close(1000);
  });

  it("retires an overloaded peer before close completes, without cancelling accepted commands or another peer", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-server-overload-retirement-"));
    let gateway: GatewayServer | undefined;
    const peers: WebSocket[] = [];
    let finishCommand = () => {};
    const commandGate = new Promise<void>((resolve) => { finishCommand = resolve; });
    cleanups.push(async () => {
      finishCommand();
      for (const peer of peers) if (peer.readyState !== WebSocket.CLOSED) peer.terminate();
      try { await bounded(gateway?.close() ?? Promise.resolve(), "overload gateway disposal"); }
      finally { await rm(root, { recursive: true, force: true }); }
    });
    const devices = new DeviceStore(root, "machine");
    await devices.initialize();
    const token = JSON.parse(await readFile(join(root, "gateway", "local-auth.json"), "utf8")).bearerToken;
    const port = await unusedPort();
    const logger = { log: vi.fn() };
    const sessions = { unsubscribeClient: vi.fn(), subscribe: vi.fn() };
    let acceptedContext: any;
    let completedCommands = 0;
    const invoke = vi.fn(async (context: any, method: string) => {
      if (method === "accepted-command") {
        acceptedContext = context;
        await commandGate; // Domain-command lifetime deliberately does not use socket cancellation.
        completedCommands += 1;
      }
      return { method };
    });
    gateway = new GatewayServer({
      host: "127.0.0.1", port, maxFrameBytes: 16_384, maximumOutboundBytes: 8_192,
      maximumConnections: 2, devices, logger: logger as any, sessions: sessions as any,
      uploads: {} as any, auth: { detachClient: vi.fn() } as any,
      service: {
        info: () => ({ protocolVersion: 5 }), invoke, releaseClient: vi.fn(),
        terminalBelongsToSession: () => false,
      } as any,
    });
    await gateway.listen();
    const open = async () => {
      const peer = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${token}` } });
      peers.push(peer);
      const frames: any[] = [];
      peer.on("message", (raw) => frames.push(JSON.parse(raw.toString())));
      await bounded(new Promise<void>((resolve, reject) => { peer.once("open", resolve); peer.once("error", reject); }), "overload peer open");
      peer.send(JSON.stringify({ type: "hello", protocolVersion: 5 }));
      await bounded(waitUntil(() => frames.some((frame) => frame.type === "hello")), "overload peer hello");
      return { peer, frames };
    };
    const target = await open();
    const healthy = await open();
    target.peer.send(JSON.stringify({ type: "request", id: "accepted", method: "accepted-command", params: {} }));
    await bounded(waitUntil(() => acceptedContext !== undefined), "command admission");
    const connection = (gateway as any).clients.get(acceptedContext.id);
    // Leave a real socket OPEN but suppress close progress. New messages can
    // still arrive; the transport admission fence, not ws.readyState, must win.
    vi.spyOn(connection.socket, "close").mockImplementation(() => {});
    const closed = new Promise<void>((resolve) => target.peer.once("close", () => resolve()));
    gateway.emitToClient(connection.id, "test.overflow", { text: "x".repeat(9_000) });
    expect(connection.closeInitiated).toBe(true);
    expect(acceptedContext.signal.aborted).toBe(true);
    expect(sessions.unsubscribeClient).toHaveBeenCalledExactlyOnceWith(connection.id);
    expect((gateway as any).clients.size).toBe(2); // Retiring sockets still consume admission capacity.
    expect(() => acceptedContext.beginSynchronization("late-session")).toThrow("Connection is closed");
    expect(sessions.subscribe).not.toHaveBeenCalled();
    target.peer.send(JSON.stringify({ type: "request", id: "late", method: "late-command", params: {} }));
    healthy.peer.send(JSON.stringify({ type: "request", id: "healthy", method: "system.info", params: {} }));
    await bounded(waitUntil(() => healthy.frames.some((frame) => frame.id === "healthy")), "unrelated peer response");
    finishCommand();
    await bounded(waitUntil(() => completedCommands === 1), "accepted command settlement");
    await bounded(closed, "bounded stalled close");
    await bounded(waitUntil(() => (gateway as any).clients.size === 1), "overload capacity release");
    expect(invoke.mock.calls.map((call) => call[1])).toEqual(["accepted-command", "system.info"]);
    expect(completedCommands).toBe(1);
    expect(sessions.unsubscribeClient).toHaveBeenCalledExactlyOnceWith(connection.id);
    expect(healthy.peer.readyState).toBe(WebSocket.OPEN);
    await open(); // Capacity can be used again without a Gateway restart.
    const diagnostic = logger.log.mock.calls.find((call) => call[2]?.event === "connection.outbound-capacity")?.[1];
    expect(diagnostic).toContain("maximumBytes=8192");
    expect(diagnostic).toMatch(/rssBytes=\d+ heapUsedBytes=\d+ externalBytes=\d+/u);
    expect(diagnostic).not.toContain("xxxx");
  });

  it("queues a paired self-revoke response before closing its socket", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-server-self-revoke-"));
    let gateway: GatewayServer | undefined;
    let releaseCleanup = () => {};
    cleanups.push(async () => {
      // Release a blocked install cleanup before attempting transport teardown;
      // failed assertions must not strand the service behind this gate.
      releaseCleanup();
      try {
        await bounded(gateway?.close() ?? Promise.resolve(), "self-revoke gateway close");
      } finally {
        await rm(root, { recursive: true, force: true });
      }
    });
    const devices = new DeviceStore(root, "machine");
    await devices.initialize();
    const enrollment = await devices.ensureEnrollment();
    const paired = await devices.pair(enrollment.code, "Phone");
    const port = await unusedPort();
    const logger = { log: vi.fn() };
    const frames: any[] = [];
    const cleanupGate = new Promise<void>((resolve) => { releaseCleanup = resolve; });
    const removeDevice = vi.fn(async () => cleanupGate);
    const service = new GatewayService({
      config: { tronHome: root },
      devices,
      sessions: {},
      receipts: new CommandReceiptStore(root),
      iosDeviceInstallService: { removeDevice, isUsable: false } as never,
    } as never);
    gateway = new GatewayServer({
      host: "127.0.0.1",
      port,
      maxFrameBytes: 16_384,
      devices,
      uploads: {} as any,
      sessions: { unsubscribeClient: vi.fn(), unsubscribe: vi.fn() } as any,
      auth: { detachClient: vi.fn(), cancelOwner: vi.fn() } as any,
      service: service as any,
      logger: logger as any,
    });
    await gateway.listen();

    const socket = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${paired.token}` } });
    socket.on("message", (raw) => frames.push(JSON.parse(raw.toString())));
    await new Promise<void>((resolve) => socket.once("open", () => resolve()));
    socket.send(JSON.stringify({ type: "hello", protocolVersion: 5 }));
    await waitUntil(() => frames.some((frame) => frame.type === "hello"));
    const response = new Promise<Record<string, unknown>>((resolve) => socket.on("message", (raw) => {
      const frame = JSON.parse(raw.toString()) as Record<string, unknown>;
      if (frame.type === "response" && frame.id === "self-revoke") resolve(frame);
    }));
    const closed = new Promise<number>((resolve) => socket.once("close", (code) => resolve(code)));
    socket.send(JSON.stringify({
      type: "request",
      id: "self-revoke",
      method: "device.revoke",
      params: { deviceId: paired.deviceId, commandId: "self-revoke-command" },
    }));
    await waitUntil(() => removeDevice.mock.calls.length === 1);
    expect(frames.some((frame) => frame.id === "self-revoke")).toBe(false);
    // A post-cut request is handled by the revoked fence, not by GatewayService;
    // its response must not be admitted alongside the exact self acknowledgement.
    socket.send(JSON.stringify({ type: "request", id: "late-after-revoke", method: "system.info", params: {} }));
    await new Promise((resolve) => setImmediate(resolve));
    expect(frames.some((frame) => frame.id === "late-after-revoke")).toBe(false);
    releaseCleanup();
    await expect(bounded(response, "self-revoke response")).resolves.toMatchObject({ ok: true, result: { revoked: true } });
    expect(await bounded(closed, "self-revoke close")).toBe(1008);
    expect(frames.findIndex((frame) => frame.id === "self-revoke")).toBeGreaterThan(-1);
  });

  it.each(["OPEN", "CLOSING"] as const)("terminates a stalled self-revoke writer in %s state and releases capacity", async (state) => {
    const root = await mkdtemp(join(tmpdir(), "tron-server-self-revoke-stalled-"));
    let gateway: GatewayServer | undefined;
    let target: WebSocket | undefined;
    let replacement: WebSocket | undefined;
    cleanups.push(async () => {
      for (const socket of [target, replacement]) {
        if (socket && socket.readyState !== WebSocket.CLOSED) socket.terminate();
      }
      try {
        await bounded(gateway?.close() ?? Promise.resolve(), "stalled self-revoke gateway close");
      } finally {
        await rm(root, { recursive: true, force: true });
      }
    });
    const devices = new DeviceStore(root, "machine");
    await devices.initialize();
    const enrollment = await devices.ensureEnrollment();
    const paired = await devices.pair(enrollment.code, "Phone");
    const port = await unusedPort();
    const logger = { log: vi.fn() };
    const service = new GatewayService({
      config: { tronHome: root },
      devices,
      sessions: {},
      receipts: new CommandReceiptStore(root),
      iosDeviceInstallService: { isUsable: false, removeDevice: async () => {} } as never,
    } as never);
    gateway = new GatewayServer({
      host: "127.0.0.1",
      port,
      maxFrameBytes: 16_384,
      maximumConnections: 1,
      maximumConnectionsPerIdentity: 1,
      devices,
      uploads: {} as any,
      sessions: { unsubscribeClient: vi.fn() } as any,
      auth: { detachClient: vi.fn(), cancelOwner: vi.fn() } as any,
      service: service as any,
      logger: logger as any,
    });
    await gateway.listen();
    target = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${paired.token}` } });
    const frames: any[] = [];
    target.on("message", (raw) => frames.push(JSON.parse(raw.toString())));
    await bounded(new Promise<void>((resolve) => target?.once("open", () => resolve())), "stalled self-revoke open");
    target.send(JSON.stringify({ type: "hello", protocolVersion: 5 }));
    await bounded(waitUntil(() => frames.some((frame) => frame.type === "hello")), "stalled self-revoke hello");

    // Keep one earlier frame permanently in the real connection-local queue.
    // The self-revoke response must not overtake it, but the bounded fallback
    // must still retire this socket and remove it from capacity accounting.
    const connection = [...(gateway as any).clients.values()][0] as {
      outbound: OrderedOutboundQueue;
      socket: WebSocket;
      revokeCloseScheduled: boolean;
    };
    connection.outbound = new OrderedOutboundQueue(16_384, () => {}, vi.fn(), vi.fn());
    gateway.broadcast("test.stalled", { sequence: 1 });
    const closed = new Promise<number>((resolve) => target?.once("close", (code) => resolve(code)));
    target.send(JSON.stringify({
      type: "request",
      id: "stalled-self-revoke",
      method: "device.revoke",
      params: { deviceId: paired.deviceId, commandId: "stalled-self-revoke-command" },
    }));
    if (state === "CLOSING") {
      await waitUntil(() => connection.revokeCloseScheduled);
      // Receive the close frame but deliberately omit the peer's reply. The
      // revocation deadline must not fall back to ws's longer close timeout.
      vi.spyOn(target, "close").mockImplementation(() => {});
      connection.socket.close(1008, "stalled close handshake");
      expect(connection.socket.readyState).toBe(WebSocket.CLOSING);
    }
    await expect(bounded(closed, "stalled self-revoke close")).resolves.toBe(state === "OPEN" ? 1006 : 1008);
    await bounded(waitUntil(() => (gateway as any).clients.size === 0), "stalled self-revoke capacity release");
    expect(frames.some((frame) => frame.topic === "test.stalled")).toBe(false);
    expect(frames.some((frame) => frame.id === "stalled-self-revoke")).toBe(false);

    const replacementEnrollment = await devices.ensureEnrollment();
    const replacementPaired = await devices.pair(replacementEnrollment.code, "Replacement");
    replacement = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${replacementPaired.token}` } });
    await bounded(new Promise<void>((resolve, reject) => {
      replacement?.once("open", () => resolve());
      replacement?.once("error", reject);
    }), "replacement connection open");
    replacement.terminate();
  });

  it("fences only the revoked paired device while preserving the local wrapper", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-server-revocation-"));
    let gateway: GatewayServer | undefined;
    cleanups.push(async () => { await gateway?.close(); await rm(root, { recursive: true, force: true }); });
    const devices = new DeviceStore(root, "machine");
    await devices.initialize();
    const enrollment = await devices.ensureEnrollment();
    const paired = await devices.pair(enrollment.code, "Phone");
    const localToken = JSON.parse(await readFile(join(root, "gateway", "local-auth.json"), "utf8")).bearerToken;
    const port = await unusedPort();
    const logger = { log: vi.fn() };
    const service = {
      info: () => ({ gatewayVersion: "test", piVersion: "test", protocolVersion: 5, minProtocolVersion: 5, machineId: "machine", machineName: "test", capabilities: [] }),
      terminalBelongsToSession: () => false,
      releaseClient: vi.fn(),
      invoke: vi.fn(async (_client: unknown, method: string) => ({ method })),
    };
    gateway = new GatewayServer({
      host: "127.0.0.1",
      port,
      maxFrameBytes: 16_384,
      devices,
      uploads: { acquire: vi.fn() } as any,
      sessions: { unsubscribeClient: vi.fn(), unsubscribe: vi.fn() } as any,
      auth: { detachClient: vi.fn(), cancelOwner: vi.fn() } as any,
      service: service as any,
      logger: logger as any,
    });
    await gateway.listen();

    const target = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${paired.token}` } });
    const local = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${localToken}` } });
    const localFrames: any[] = [];
    local.on("message", (raw) => localFrames.push(JSON.parse(raw.toString())));
    await Promise.all([
      new Promise<void>((resolve) => target.once("open", () => resolve())),
      new Promise<void>((resolve) => local.once("open", () => resolve())),
    ]);
    target.send(JSON.stringify({ type: "hello", protocolVersion: 5 }));
    local.send(JSON.stringify({ type: "hello", protocolVersion: 5 }));
    await waitUntil(() => localFrames.some((frame) => frame.type === "hello")
      && logger.log.mock.calls.filter((call) => call[2]?.event === "connection.opened").length === 2);

    const closed = new Promise<number>((resolve) => target.once("close", (code) => resolve(code)));
    await devices.revoke(paired.deviceId, () => gateway.disconnectDevice(paired.deviceId));
    expect(await closed).toBe(1008);
    const rejectedHttp = await new Promise<number>((resolve, reject) => {
      const outgoing = request({ host: "127.0.0.1", port, path: "/v1/uploads/missing", headers: { authorization: `Bearer ${paired.token}` } }, (response) => {
        response.resume();
        response.once("end", () => resolve(response.statusCode ?? 0));
      });
      outgoing.once("error", reject);
      outgoing.end();
    });
    expect(rejectedHttp).toBe(401);
    expect(local.readyState).toBe(WebSocket.OPEN);
    local.send(JSON.stringify({ type: "request", id: "local-info", method: "system.info", params: {} }));
    await waitUntil(() => localFrames.some((frame) => frame.type === "response" && frame.id === "local-info"));
    expect(service.invoke).toHaveBeenCalledWith(expect.objectContaining({ isLocal: true }), "system.info", {});
    target.close();
    local.close();
  });

  it("distinguishes no application write from inbound ping progress before hello", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-server-progress-"));
    const sockets: WebSocket[] = [];
    let gateway: GatewayServer | undefined;
    const now = vi.spyOn(performance, "now").mockReturnValue(1_000);
    cleanups.push(async () => {
      try {
        for (const socket of sockets) if (socket.readyState !== WebSocket.CLOSED) socket.terminate();
        if (gateway) await bounded(gateway.close(), "progress fixture disposal");
        await rm(root, { recursive: true, force: true });
      } finally { now.mockRestore(); }
    });
    const devices = new DeviceStore(root, "machine");
    await devices.initialize();
    const token = JSON.parse(await readFile(join(root, "gateway", "local-auth.json"), "utf8")).bearerToken;
    const port = await unusedPort();
    const logger = { log: vi.fn() };
    gateway = new GatewayServer({
      host: "127.0.0.1", port, devices, logger: logger as any,
      uploads: {} as any,
      sessions: { unsubscribeClient: vi.fn() } as any,
      auth: { detachClient: vi.fn(), cancelOwner: vi.fn() } as any,
      service: { releaseClient: vi.fn() } as any,
    });
    await gateway.listen();
    const open = async () => {
      const socket = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${token}` } });
      sockets.push(socket);
      await bounded(new Promise<void>((resolve, reject) => {
        socket.once("open", resolve);
        socket.once("error", reject);
      }), "progress socket open");
      return socket;
    };
    const close = async (socket: WebSocket) => {
      const closed = new Promise<void>((resolve) => socket.once("close", () => resolve()));
      socket.close();
      await bounded(closed, "progress socket close");
    };
    await close(await open());
    await waitUntil(() => logger.log.mock.calls.some((call) => call[2]?.event === "connection.closed"));
    expect(logger.log.mock.calls.find((call) => call[2]?.event === "connection.closed")?.[1])
      .toContain("lastInboundAgeMs=unknown lastWriteProgressAgeMs=unknown queuedFrames=0 queuedBytes=0 completedFrames=0");
    const live = await open();
    now.mockReturnValue(2_000);
    const pong = new Promise<void>((resolve) => live.once("pong", () => resolve()));
    live.ping();
    await bounded(pong, "progress ping round trip");
    now.mockReturnValue(2_600);
    await close(live);
    await waitUntil(() => logger.log.mock.calls.filter((call) => call[2]?.event === "connection.closed").length === 2);
    expect(logger.log.mock.calls.filter((call) => call[2]?.event === "connection.closed")[1]?.[1])
      .toContain("lastInboundAgeMs=600 lastWriteProgressAgeMs=unknown queuedFrames=0 queuedBytes=0 completedFrames=0");
  });

  it.each([undefined, "mobile"])("rejects a sub-megabyte dense response for role %s without disconnecting or leaking contents", async (clientRole) => {
    const root = await mkdtemp(join(tmpdir(), "tron-structural-capacity-"));
    let gateway: GatewayServer | undefined;
    let socket: WebSocket | undefined;
    cleanups.push(async () => {
      if (socket && socket.readyState !== WebSocket.CLOSED) {
        const closed = new Promise<void>(resolve => socket!.once("close", () => resolve()));
        socket.terminate();
        await bounded(closed, "structural socket disposal");
      }
      if (gateway) await bounded(gateway.close(), "structural fixture disposal");
      await rm(root, { recursive: true, force: true });
    });
    const devices = new DeviceStore(root, "machine");
    await devices.initialize();
    const token = JSON.parse(await readFile(join(root, "gateway", "local-auth.json"), "utf8")).bearerToken;
    const port = await unusedPort();
    const logger = { log: vi.fn() };
    const dense = { private: "not-for-logs", rows: Array.from({ length: 8 }, () =>
      Array.from({ length: 1_000 }, () => ({ a: 0, b: 1, c: 2, d: 3 }))) };
    expect(Buffer.byteLength(JSON.stringify(dense))).toBeLessThan(1_048_576);
    const subscriptions = new Set<string>();
    gateway = new GatewayServer({
      host: "127.0.0.1", port, maxFrameBytes: 1_048_576,
      devices, uploads: {} as any,
      sessions: {
        subscribe: (_client: string, session: string) => subscriptions.add(session),
        unsubscribe: (_client: string, session: string) => subscriptions.delete(session),
        unsubscribeClient: () => subscriptions.clear(),
      } as any,
      auth: { detachClient: vi.fn(), cancelOwner: vi.fn() } as any,
      service: {
        info: () => ({ gatewayVersion: "test", piVersion: "test", protocolVersion: 5, minProtocolVersion: 5,
          machineId: "machine", machineName: "test", capabilities: [] }),
        terminalBelongsToSession: () => false, releaseClient: vi.fn(),
        invoke: async (context: any, method: string, params: any) => {
          if (method === "session.open") {
            const syncToken = context.beginSynchronization(params.sessionId);
            context.establishSynchronization(params.sessionId, { runtimeGeneration: "generation", eventSequence: 1 });
            return { session: params.dense ? dense : { healthy: true }, syncToken, subscriptionToken: syncToken };
          }
          return method === "test.dense" ? dense : { healthy: true };
        },
      } as any,
      logger: logger as any,
    });
    await gateway.listen();
    socket = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${token}` } });
    const frames: any[] = [];
    socket.on("message", raw => frames.push(JSON.parse(raw.toString())));
    await bounded(new Promise<void>(resolve => socket!.once("open", resolve)), "structural socket open");
    socket.send(JSON.stringify({ type: "hello", protocolVersion: 5, clientRole }));
    await waitUntil(() => frames.some(frame => frame.type === "hello"));
    socket.send(JSON.stringify({ type: "request", id: "dense", method: "test.dense", params: {} }));
    await waitUntil(() => frames.some(frame => frame.id === "dense"));
    expect(frames.find(frame => frame.id === "dense")).toMatchObject({
      ok: false, error: { code: "response_too_large", details: { maximumNodes: 32_768 } },
    });
    socket.send(JSON.stringify({ type: "request", id: "small", method: "test.small", params: {} }));
    await waitUntil(() => frames.some(frame => frame.id === "small"));
    expect(frames.find(frame => frame.id === "small")).toMatchObject({ ok: true, result: { healthy: true } });
    expect(socket.readyState).toBe(WebSocket.OPEN);
    const rejection = logger.log.mock.calls.find(call => call[2]?.event === "connection.projection-rejected")?.[1];
    expect(rejection).toContain("maximumNodes=32768");
    expect(rejection).toContain("nodeCountAtLeast=32769");
    expect(rejection).not.toContain("not-for-logs");

    socket.send(JSON.stringify({ type: "request", id: "open-dense", method: "session.open", params: { sessionId: "session", dense: true } }));
    await waitUntil(() => frames.some(frame => frame.id === "open-dense"));
    expect(frames.find(frame => frame.id === "open-dense")).toMatchObject({ ok: false, error: { code: "response_too_large" } });
    expect(subscriptions.size).toBe(0);
    socket.send(JSON.stringify({ type: "request", id: "open-small", method: "session.open", params: { sessionId: "session" } }));
    await waitUntil(() => frames.some(frame => frame.id === "open-small"));
    expect(frames.find(frame => frame.id === "open-small")).toMatchObject({ ok: true, result: { session: { healthy: true } } });
    expect(subscriptions.has("session")).toBe(true);
    expect(socket.readyState).toBe(WebSocket.OPEN);
  });

  it.each([{ sessions: 1, peers: 1 }, { sessions: 4, peers: 4 }, { sessions: 16, peers: 16 }, { sessions: 16, peers: 32 }])(
    "preserves global summary order and reusable capacity across $sessions sessions / $peers peers", async ({ sessions: sessionCount, peers: peerCount }) => {
      const root = await mkdtemp(join(tmpdir(), "tron-fanout-qualification-"));
      const devices = new DeviceStore(root, "fixture-machine");
      await devices.initialize();
      const token = JSON.parse(await readFile(join(root, "gateway", "local-auth.json"), "utf8")).bearerToken;
      const port = await unusedPort();
      const peers: WebSocket[] = [];
      const physicalSockets: import("node:net").Socket[] = [];
      const gateway = new GatewayServer({
        host: "127.0.0.1", port, maxFrameBytes: 1_048_576,
        maximumConnections: peerCount, maximumConnectionsPerIdentity: peerCount,
        devices, uploads: {} as any, sessions: { unsubscribeClient: vi.fn() } as any,
        auth: { detachClient: vi.fn() } as any,
        service: { info: () => ({ protocolVersion: 5 }), releaseClient: vi.fn(), invoke: async () => ({ ready: true }) } as any,
        logger: { log: () => {} } as any,
      });
      (gateway as unknown as { server: import("node:http").Server }).server.on("connection", socket => physicalSockets.push(socket));
      cleanups.push(async () => {
        for (const peer of peers) if (peer.readyState !== WebSocket.CLOSED) peer.terminate();
        await bounded(gateway.close(), "fanout fixture close");
        await rm(root, { recursive: true, force: true });
      });
      await gateway.listen();
      for (let wave = 0; wave < 3; wave++) {
        const physicalStart = physicalSockets.length;
        const clients = await Promise.all(Array.from({ length: peerCount }, async () => {
          const socket = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${token}` } });
          peers.push(socket);
          const events: Array<[string, number]> = [];
          let ready!: () => void, fenced!: () => void;
          const hello = new Promise<void>(resolve => { ready = resolve; });
          const fence = new Promise<void>(resolve => { fenced = resolve; });
          socket.on("message", bytes => {
            const frame = JSON.parse(bytes.toString());
            if (frame.type === "hello" && frame.protocolVersion === 5) ready();
            if (frame.topic === "session.summary") {
              if (events.length >= 128) { socket.terminate(); return; }
              events.push([frame.payload.sessionId, frame.payload.summaryRevision]);
            }
            if (frame.type === "response" && frame.id === "fence" && frame.ok) fenced();
          });
          socket.on("error", () => {});
          await bounded(new Promise<void>(resolve => socket.once("open", resolve)), "fanout socket open");
          socket.send(JSON.stringify({ type: "hello", protocolVersion: 5, clientRole: "mobile" }));
          await bounded(hello, "fanout hello");
          return { socket, events, fence };
        }));
        const expected: Array<[string, number]> = [];
        for (let revision = 1; revision <= 8; revision++) {
          for (let session = 0; session < sessionCount; session++) {
            const sessionId = `fixture-session-${session}`;
            expected.push([sessionId, revision]);
            gateway.broadcast("session.summary", { sessionId, summaryRevision: revision, phase: "idle" });
          }
        }
        // A real response follows every already-enqueued global summary on
        // each socket. It proves ordering/drain without a timing sleep.
        for (const client of clients) client.socket.send(JSON.stringify({ type: "request", id: "fence", method: "test.fence", params: {} }));
        await bounded(Promise.all(clients.map(client => client.fence)), "fanout fences");
        for (const client of clients) {
          expect(client.events).toEqual(expected);
          expect(client.socket.readyState).toBe(WebSocket.OPEN);
        }
        const closed = Promise.all(physicalSockets.slice(physicalStart).map(socket => new Promise<void>(resolve => socket.once("close", resolve))));
        for (const client of clients) client.socket.close(1000);
        await bounded(closed, "fanout physical retirement");
      }
    },
  );

  it("supersedes an identity's least recently active socket instead of rejecting its reconnect", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-server-supersede-"));
    const sockets: WebSocket[] = [];
    let gateway: GatewayServer | undefined;
    cleanups.push(async () => {
      for (const socket of sockets) if (socket.readyState !== WebSocket.CLOSED) socket.terminate();
      await bounded(gateway?.close() ?? Promise.resolve(), "supersede fixture close");
      await rm(root, { recursive: true, force: true });
    });
    const devices = new DeviceStore(root, "machine");
    await devices.initialize();
    const phone = await devices.pair((await devices.ensureEnrollment()).code, "Phone");
    const port = await unusedPort();
    const logger = { log: vi.fn() };
    gateway = new GatewayServer({
      host: "127.0.0.1",
      port,
      maxFrameBytes: 16_384,
      maximumConnections: 8,
      maximumConnectionsPerIdentity: 2,
      devices,
      uploads: {} as any,
      sessions: { unsubscribeClient: vi.fn() } as any,
      auth: { detachClient: vi.fn(), cancelOwner: vi.fn() } as any,
      service: {
        info: () => ({ protocolVersion: 5 }),
        terminalBelongsToSession: () => false,
        releaseClient: vi.fn(),
        invoke: async () => ({ ok: true }),
      } as any,
      logger: logger as any,
    });
    await gateway.listen();
    const connect = async (label: string) => {
      const socket = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${phone.token}` } });
      sockets.push(socket);
      const frames: any[] = [];
      socket.on("message", (raw) => frames.push(JSON.parse(raw.toString())));
      socket.on("error", () => {});
      await bounded(new Promise<void>((resolve, reject) => {
        socket.once("open", () => resolve());
        socket.once("unexpected-response", () => reject(new Error(`${label} was rejected`)));
      }), `${label} open`);
      socket.send(JSON.stringify({ type: "hello", protocolVersion: 5, clientRole: "mobile" }));
      await bounded(waitUntil(() => frames.some((frame) => frame.type === "hello")), `${label} hello`);
      return { socket, frames };
    };

    const active = await connect("active");
    const stale = await connect("stale");
    const staleClosed = new Promise<number>((resolve) => stale.socket.once("close", (code) => resolve(code)));
    // The older socket is the more recently active one; admission must retire
    // by activity rather than connection age.
    active.socket.send(JSON.stringify({ type: "request", id: "progress", method: "test.progress", params: {} }));
    await bounded(waitUntil(() => active.frames.some((frame) => frame.id === "progress")), "active progress");

    const replacement = await connect("replacement");
    expect(await bounded(staleClosed, "stale supersession")).toBe(4000);
    expect(active.socket.readyState).toBe(WebSocket.OPEN);
    expect(replacement.socket.readyState).toBe(WebSocket.OPEN);
    expect(logger.log.mock.calls.filter((call) => call[2]?.event === "connection.superseded")).toHaveLength(1);
    expect(logger.log.mock.calls.some((call) => call[2]?.event === "connection.capacity")).toBe(false);
    replacement.socket.send(JSON.stringify({ type: "request", id: "usable", method: "test.usable", params: {} }));
    await bounded(waitUntil(() => replacement.frames.some((frame) => frame.id === "usable" && frame.ok)), "replacement request");
  });

  it("admits same-turn ordered bursts, rejects connection overflow, and closes byte-oversized output", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-server-capacity-"));
    let gateway: GatewayServer | undefined;
    cleanups.push(async () => {
      if (gateway) await bounded(gateway.close(), "capacity fixture disposal");
      await rm(root, { recursive: true, force: true });
    });
    const devices = new DeviceStore(root, "machine");
    await devices.initialize();
    const token = JSON.parse(await readFile(join(root, "gateway", "local-auth.json"), "utf8")).bearerToken;
    const paired = await devices.pair((await devices.ensureEnrollment()).code, "Phone");
    const port = await unusedPort();
    const logger = { log: vi.fn() };
    const service = {
      info: () => ({ gatewayVersion: "test", piVersion: "test", protocolVersion: 5, minProtocolVersion: 5, machineId: "machine", machineName: "test", capabilities: [] }),
      terminalBelongsToSession: () => false,
      releaseClient: vi.fn(),
      invoke: vi.fn(),
    };
    gateway = new GatewayServer({
      host: "127.0.0.1",
      port,
      maxFrameBytes: 16_384,
      maximumConnections: 1,
      maximumConnectionsPerIdentity: 1,
      maximumOutboundBytes: 8 * 1_024,
      devices,
      uploads: {} as any,
      sessions: { unsubscribeClient: vi.fn() } as any,
      auth: { detachClient: vi.fn(), cancelOwner: vi.fn() } as any,
      service: service as any,
      logger: logger as any,
    });
    await gateway.listen();

    const first = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${token}` } });
    const frames: any[] = [];
    first.on("message", (raw) => frames.push(JSON.parse(raw.toString())));
    await new Promise<void>((resolve) => first.once("open", () => resolve()));
    first.send(JSON.stringify({ type: "hello", protocolVersion: 5 }));
    await waitUntil(() => frames.some((frame) => frame.type === "hello"));

    // Global capacity never displaces another identity's live connection.
    const rejected = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${paired.token}` } });
    const rejectedStatus = await new Promise<number>((resolve, reject) => {
      rejected.once("unexpected-response", (_request, response) => {
        response.resume();
        resolve(response.statusCode ?? 0);
      });
      rejected.once("error", reject);
    });
    expect(rejectedStatus).toBe(503);
    expect(first.readyState).toBe(WebSocket.OPEN);

    for (let sequence = 1; sequence <= 64; sequence += 1) {
      gateway.broadcast("test.event", { sequence });
    }
    await waitUntil(() => frames.filter((frame) => frame.topic === "test.event").length === 64);
    expect(first.readyState).toBe(WebSocket.OPEN);

    gateway.broadcast("session.snapshot", { text: "private-producer-content".repeat(1_000) });
    await waitUntil(() => frames.some((frame) => frame.topic === "transport.resyncRequired"));
    const oversized = logger.log.mock.calls.find((call) => call[2]?.event === "connection.projection-rejected")?.[1];
    expect(oversized).toContain("type=event topic=session.snapshot");
    expect(oversized).toContain("maximumBytes=16384");
    expect(oversized).not.toContain("private-producer-content");
    const malformed: any = {};
    malformed.self = malformed;
    gateway.broadcast("test.malformed", malformed);
    expect(logger.log.mock.calls).toContainEqual([
      "error", "Outbound projection encoding failed",
      { event: "connection.projection-rejected", source: "transport" },
    ]);
    expect(first.readyState).toBe(WebSocket.OPEN);

    const closed = new Promise<number>((resolve) => first.once("close", (code) => resolve(code)));
    gateway.broadcast("test.event", { oversized: "x".repeat(10_000) });
    expect(await closed).toBe(1013);
    await waitUntil(() => logger.log.mock.calls.some((call) => call[2]?.event === "connection.closed"));
    const opened = logger.log.mock.calls.find((call) => call[2]?.event === "connection.opened");
    const correlation = opened?.[2]?.connectionId as string | undefined;
    expect(correlation).toBeTruthy();
    expect(logger.log.mock.calls).toContainEqual([
      "warning",
      expect.stringContaining(`Closing client ${correlation} at outbound queue capacity`),
      { event: "connection.outbound-capacity", source: "transport", connectionId: correlation },
    ]);
    expect(logger.log.mock.calls).toContainEqual([
      expect.stringMatching(/^(?:info|debug)$/u),
      expect.stringContaining(`Client ${correlation} connection closed`),
      expect.objectContaining({ event: "connection.closed", source: "transport", connectionId: correlation }),
    ]);
    const closeMessage = logger.log.mock.calls.find((call) => call[2]?.event === "connection.closed")?.[1] as string;
    expect(closeMessage).toContain("WebSocket close 1013: client outbound capacity exceeded");
    expect(closeMessage).toMatch(/lastInboundAgeMs=\d+ lastWriteProgressAgeMs=\d+ queuedFrames=\d+ queuedBytes=\d+ completedFrames=\d+/u);
  });
});
