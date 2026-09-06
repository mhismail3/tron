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
        info: () => ({ gatewayVersion: "test", piVersion: "test", protocolVersion: 4, minProtocolVersion: 4, machineId: "machine", machineName: "test", capabilities: [] }),
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
    socket.send(JSON.stringify({ type: "hello", protocolVersion: 4 }));
    await waitUntil(() => logger.log.mock.calls.some((call) => call[2]?.event === "connection.handshake"));

    const payload = "x".repeat(512 * 1_024);
    for (let sequence = 1; sequence <= 6; sequence += 1) {
      gateway.broadcast("test.large", { sequence, payload });
    }
    await waitUntil(() => sequences.length === 6);
    expect(sequences).toEqual([1, 2, 3, 4, 5, 6]);
    expect(socket.readyState).toBe(WebSocket.OPEN);
    expect(logger.log.mock.calls.some((call) => call[2]?.event === "connection.outbound-capacity")).toBe(false);
    socket.close(1000);
  });

  it("queues a paired self-revoke response before closing its socket", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-server-self-revoke-"));
    let gateway: GatewayServer | undefined;
    cleanups.push(async () => { await gateway?.close(); await rm(root, { recursive: true, force: true }); });
    const devices = new DeviceStore(root, "machine");
    await devices.initialize();
    const enrollment = await devices.ensureEnrollment();
    const paired = await devices.pair(enrollment.code, "Phone");
    const port = await unusedPort();
    const logger = { log: vi.fn() };
    const frames: any[] = [];
    let releaseCleanup!: () => void;
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
    socket.send(JSON.stringify({ type: "hello", protocolVersion: 4 }));
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
    releaseCleanup();
    await expect(bounded(response, "self-revoke response")).resolves.toMatchObject({ ok: true, result: { revoked: true } });
    expect(await bounded(closed, "self-revoke close")).toBe(1008);
    expect(frames.findIndex((frame) => frame.id === "self-revoke")).toBeGreaterThan(-1);
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
      info: () => ({ gatewayVersion: "test", piVersion: "test", protocolVersion: 4, minProtocolVersion: 4, machineId: "machine", machineName: "test", capabilities: [] }),
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
    target.send(JSON.stringify({ type: "hello", protocolVersion: 4 }));
    local.send(JSON.stringify({ type: "hello", protocolVersion: 4 }));
    await waitUntil(() => localFrames.some((frame) => frame.type === "hello")
      && logger.log.mock.calls.filter((call) => call[2]?.event === "connection.handshake").length === 2);

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

  it("admits same-turn ordered bursts, rejects connection overflow, and closes byte-oversized output", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-server-capacity-"));
    const devices = new DeviceStore(root, "machine");
    await devices.initialize();
    const token = JSON.parse(await readFile(join(root, "gateway", "local-auth.json"), "utf8")).bearerToken;
    const port = await unusedPort();
    const logger = { log: vi.fn() };
    const service = {
      info: () => ({ gatewayVersion: "test", piVersion: "test", protocolVersion: 4, minProtocolVersion: 4, machineId: "machine", machineName: "test", capabilities: [] }),
      terminalBelongsToSession: () => false,
      releaseClient: vi.fn(),
      invoke: vi.fn(),
    };
    const gateway = new GatewayServer({
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
    cleanups.push(async () => { await gateway.close(); });

    const first = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${token}` } });
    const frames: any[] = [];
    first.on("message", (raw) => frames.push(JSON.parse(raw.toString())));
    await new Promise<void>((resolve) => first.once("open", () => resolve()));
    first.send(JSON.stringify({ type: "hello", protocolVersion: 4 }));
    await waitUntil(() => frames.some((frame) => frame.type === "hello"));

    const rejected = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${token}` } });
    const rejectedStatus = await new Promise<number>((resolve, reject) => {
      rejected.once("unexpected-response", (_request, response) => {
        response.resume();
        resolve(response.statusCode ?? 0);
      });
      rejected.once("error", reject);
    });
    expect(rejectedStatus).toBe(503);

    for (let sequence = 1; sequence <= 64; sequence += 1) {
      gateway.broadcast("test.event", { sequence });
    }
    await waitUntil(() => frames.filter((frame) => frame.topic === "test.event").length === 64);
    expect(first.readyState).toBe(WebSocket.OPEN);

    const closed = new Promise<number>((resolve) => first.once("close", (code) => resolve(code)));
    gateway.broadcast("test.event", { oversized: "x".repeat(10_000) });
    expect(await closed).toBe(1013);
    await waitUntil(() => logger.log.mock.calls.some((call) => call[2]?.event === "connection.closed"));
    const admission = logger.log.mock.calls.find((call) => call[2]?.event === "connection.admitted");
    const correlation = /Client ([0-9a-f-]+) connection admitted/u.exec(admission?.[1])?.[1];
    expect(correlation).toBeTruthy();
    expect(logger.log.mock.calls).toContainEqual([
      "warning",
      expect.stringContaining(`Closing client ${correlation} at outbound queue capacity`),
      { event: "connection.outbound-capacity", source: "transport" },
    ]);
    expect(logger.log.mock.calls).toContainEqual([
      "info",
      expect.stringContaining(`Client ${correlation} connection closed`),
      { event: "connection.closed", source: "transport" },
    ]);
    expect(logger.log.mock.calls.find((call) => call[2]?.event === "connection.closed")?.[1])
      .toContain("WebSocket close 1013: client outbound capacity exceeded");
  });
});
