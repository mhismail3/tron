import { createServer } from "node:http";
import { mkdtemp, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import WebSocket from "ws";
import { afterEach, describe, expect, it, vi } from "vitest";
import { DeviceStore } from "../security/device-store.js";
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

describe("WebSocket connection and outbound capacity", () => {
  it("serializes a legitimate burst above the retired 2 MiB ws pressure threshold", () => {
    const writes: string[] = [];
    const completions: Array<(error?: Error) => void> = [];
    const overflow = vi.fn();
    const writeFailed = vi.fn();
    const queue = new OrderedOutboundQueue(
      8 * 1_048_576,
      (encoded, completion) => {
        writes.push(encoded);
        completions.push(completion);
      },
      overflow,
      writeFailed,
    );
    const frames = Array.from({ length: 6 }, (_, index) => `${index}:${"x".repeat(512 * 1_024)}`);

    expect(frames.every((frame) => queue.enqueue(frame))).toBe(true);
    expect(queue.snapshot()).toMatchObject({ queuedFrames: 6, writeActive: true, acceptedFrames: 6, completedFrames: 0 });
    expect(queue.snapshot().queuedBytes).toBeGreaterThan(2 * 1_048_576);
    expect(writes).toEqual([frames[0]]);
    const drained = vi.fn();
    queue.whenIdle(drained);

    for (let index = 0; index < frames.length; index += 1) {
      completions[index]?.();
      expect(writes).toEqual(frames.slice(0, Math.min(index + 2, frames.length)));
    }
    expect(queue.snapshot()).toEqual({ queuedFrames: 0, queuedBytes: 0, writeActive: false, acceptedFrames: 6, completedFrames: 6 });
    expect(drained).toHaveBeenCalledTimes(1);
    expect(overflow).not.toHaveBeenCalled();
    expect(writeFailed).not.toHaveBeenCalled();
  });

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
