import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createServer } from "node:http";
import WebSocket, { WebSocketServer } from "ws";
import { afterEach, describe, expect, it, vi } from "vitest";
import { GatewayServer } from "./server.js";
import { DeviceStore } from "../security/device-store.js";
import { SessionSyncBarrier } from "./session-sync.js";

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => { await Promise.all(cleanups.splice(0).map((cleanup) => cleanup())); });

describe("two-phase session synchronization protocol", () => {
  it("rejects overlapping opens, preserves independent completion order, and cleans failed/oversized owners", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-sync-race-"));
    const devices = new DeviceStore(root, "machine");
    await devices.initialize();
    const token = JSON.parse(await (await import("node:fs/promises")).readFile(join(root, "gateway", "local-auth.json"), "utf8")).bearerToken;
    const probe = createServer();
    await new Promise<void>((resolve) => probe.listen(0, "127.0.0.1", resolve));
    const address = probe.address();
    if (!address || typeof address === "string") throw new Error("probe did not bind");
    const port = address.port;
    await new Promise<void>((resolve) => probe.close(() => resolve()));

    const openResolvers = new Map<string, () => void>();
    const startedCounts = new Map<string, number>();
    const failNext = { value: false };
    const oversizedNext = { value: false };
    const service = {
      info: () => ({ gatewayVersion: "test", piVersion: "test", protocolVersion: 3, minProtocolVersion: 3, machineId: "machine", machineName: "test", capabilities: [] }),
      terminalBelongsToSession: () => false,
      releaseClient: vi.fn(),
      invoke: async (context: any, method: string, params: any) => {
        const sessionId = params.sessionId as string;
        if (method === "session.open") {
          const syncToken = context.beginSynchronization(sessionId);
          startedCounts.set(sessionId, (startedCounts.get(sessionId) ?? 0) + 1);
          await new Promise<void>((resolve) => openResolvers.set(sessionId, resolve));
          if (failNext.value) {
            failNext.value = false;
            throw new Error("planned open failure");
          }
          const result: Record<string, unknown> = {
            session: { sessionId, runtimeGeneration: "generation-" + sessionId, eventSequence: 1 },
            syncToken,
            subscriptionToken: syncToken,
          };
          if (oversizedNext.value) {
            oversizedNext.value = false;
            result.padding = "x".repeat(10_000);
          }
          context.establishSynchronization(sessionId, result.session);
          return result;
        }
        if (method === "session.sync") {
          context.completeSynchronization(sessionId, params.syncToken as string);
          return { synchronized: true };
        }
        throw new Error(`unexpected method ${method}`);
      },
    };
    const sessions = {
      subscribe: vi.fn(),
      unsubscribe: vi.fn(),
      unsubscribeClient: vi.fn(),
    };
    const gateway = new GatewayServer({
      host: "127.0.0.1",
      port,
      maxFrameBytes: 1_024,
      devices,
      uploads: {} as any,
      sessions: sessions as any,
      auth: { cancelClient: vi.fn() } as any,
      service: service as any,
      logger: { log: vi.fn() } as any,
    });
    await gateway.listen();
    cleanups.push(async () => { await gateway.close(); });

    const socket = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${token}` } });
    const frames: any[] = [];
    socket.on("message", (raw) => frames.push(JSON.parse(raw.toString())));
    await new Promise<void>((resolve) => socket.once("open", () => resolve()));
    socket.send(JSON.stringify({ type: "hello", protocolVersion: 3 }));
    while (!frames.some((frame) => frame.type === "hello")) await new Promise((resolve) => setTimeout(resolve, 1));

    const request = (id: string, method: string, sessionId: string, extra: Record<string, unknown> = {}) => {
      socket.send(JSON.stringify({ type: "request", id, method, params: { sessionId, ...extra } }));
    };
    const waitStarted = async (sessionId: string, count: number): Promise<void> => {
      while ((startedCounts.get(sessionId) ?? 0) < count) await new Promise((resolve) => setTimeout(resolve, 1));
    };
    request("open-1", "session.open", "same");
    await waitStarted("same", 1);
    request("open-2", "session.open", "same");
    while (!frames.some((frame) => frame.id === "open-2")) await new Promise((resolve) => setTimeout(resolve, 1));
    expect(frames.find((frame) => frame.id === "open-2").error.code).toBe("conflict");
    openResolvers.get("same")?.();
    while (!frames.some((frame) => frame.id === "open-1")) await new Promise((resolve) => setTimeout(resolve, 1));
    const first = frames.find((frame) => frame.id === "open-1");
    request("sync-1", "session.sync", "same", { syncToken: first.result.syncToken });
    while (!frames.some((frame) => frame.id === "sync-1")) await new Promise((resolve) => setTimeout(resolve, 1));
    request("open-3", "session.open", "same");
    while (!frames.some((frame) => frame.id === "open-3")) await new Promise((resolve) => setTimeout(resolve, 1));
    expect(frames.find((frame) => frame.id === "open-3").error.code).toBe("conflict");

    request("open-a", "session.open", "a");
    request("open-b", "session.open", "b");
    await waitStarted("a", 1);
    await waitStarted("b", 1);
    openResolvers.get("b")?.();
    openResolvers.get("a")?.();
    while (!frames.some((frame) => frame.id === "open-a") && !frames.some((frame) => frame.id === "open-b")) await new Promise((resolve) => setTimeout(resolve, 1));
    while (!frames.some((frame) => frame.id === "open-a") || !frames.some((frame) => frame.id === "open-b")) await new Promise((resolve) => setTimeout(resolve, 1));
    const openA = frames.find((frame) => frame.id === "open-a");
    const openB = frames.find((frame) => frame.id === "open-b");
    request("sync-b", "session.sync", "b", { syncToken: openB.result.syncToken });
    request("sync-a", "session.sync", "a", { syncToken: openA.result.syncToken });
    while (!frames.some((frame) => frame.id === "sync-a") || !frames.some((frame) => frame.id === "sync-b")) await new Promise((resolve) => setTimeout(resolve, 1));
    expect(frames.filter((frame) => frame.id === "sync-a")).toHaveLength(1);
    expect(frames.filter((frame) => frame.id === "sync-b")).toHaveLength(1);

    failNext.value = true;
    request("open-fail", "session.open", "failure");
    await waitStarted("failure", 1);
    openResolvers.get("failure")?.();
    while (!frames.some((frame) => frame.id === "open-fail")) await new Promise((resolve) => setTimeout(resolve, 1));
    request("open-after-fail", "session.open", "failure");
    await waitStarted("failure", 2);
    openResolvers.get("failure")?.();
    while (!frames.some((frame) => frame.id === "open-after-fail")) await new Promise((resolve) => setTimeout(resolve, 1));

    oversizedNext.value = true;
    request("open-large", "session.open", "large");
    await waitStarted("large", 1);
    openResolvers.get("large")?.();
    while (!frames.some((frame) => frame.id === "open-large")) await new Promise((resolve) => setTimeout(resolve, 1));
    expect(frames.find((frame) => frame.id === "open-large").error.code).toBe("response_too_large");
    request("open-after-large", "session.open", "large");
    await waitStarted("large", 2);
    openResolvers.get("large")?.();
    while (!frames.some((frame) => frame.id === "open-after-large")) await new Promise((resolve) => setTimeout(resolve, 1));
    expect(frames.filter((frame) => frame.id).map((frame) => frame.id).length).toBe(new Set(frames.filter((frame) => frame.id).map((frame) => frame.id)).size);
    socket.close();
  });

  it("uses the owner-only local credential and orders acknowledgement before catch-up", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-sync-protocol-"));
    const devices = new DeviceStore(root, "machine");
    await devices.initialize();
    const token = JSON.parse(await (await import("node:fs/promises")).readFile(join(root, "gateway", "local-auth.json"), "utf8")).bearerToken;

    const http = createServer();
    const sockets = new WebSocketServer({ server: http });
    await new Promise<void>((resolve) => http.listen(0, "127.0.0.1", resolve));
    const address = http.address();
    if (!address || typeof address === "string") throw new Error("test server did not bind");
    cleanups.push(async () => {
      for (const socket of sockets.clients) socket.terminate();
      await new Promise<void>((resolve) => sockets.close(() => resolve()));
      await new Promise<void>((resolve) => http.close(() => resolve()));
    });

    sockets.on("connection", (socket, request) => {
      expect(request.headers.authorization).toBe(`Bearer ${token}`);
      const barrier = new SessionSyncBarrier();
      socket.on("message", (raw) => {
        const frame = JSON.parse(raw.toString()) as any;
        if (frame.type === "hello") socket.send(JSON.stringify({ type: "hello", protocolVersion: 3, minProtocolVersion: 3 }));
        if (frame.method === "session.open") {
          barrier.begin("token");
          barrier.offer({ type: "event", topic: "session.progress", sessionId: "session", payload: { runtimeGeneration: "generation", eventSequence: 2, revision: 2, data: {} } });
          barrier.establish({ runtimeGeneration: "generation", eventSequence: 1 } as any);
          socket.send(JSON.stringify({ type: "response", id: frame.id, ok: true, result: { session: { runtimeGeneration: "generation", eventSequence: 1 }, syncToken: "token", subscriptionToken: "subscription" } }));
        }
        if (frame.method === "session.sync") {
          const completed = barrier.commit(frame.params.syncToken);
          socket.send(JSON.stringify({ type: "response", id: frame.id, ok: true, result: { synchronized: true } }));
          for (const event of completed.events) socket.send(JSON.stringify(event));
        }
      });
    });

    const socket = new WebSocket(`ws://127.0.0.1:${address.port}`, { headers: { authorization: `Bearer ${token}` } });
    const frames: any[] = [];
    socket.on("message", (raw) => frames.push(JSON.parse(raw.toString())));
    await new Promise<void>((resolve) => socket.once("open", () => resolve()));
    socket.send(JSON.stringify({ type: "hello", protocolVersion: 3 }));
    while (!frames.some((frame) => frame.type === "hello")) await new Promise((resolve) => setTimeout(resolve, 1));
    socket.send(JSON.stringify({ type: "request", id: "open", method: "session.open", params: { sessionId: "session" } }));
    while (!frames.some((frame) => frame.id === "open")) await new Promise((resolve) => setTimeout(resolve, 1));
    const open = frames.find((frame) => frame.id === "open");
    expect(open.result.subscriptionToken).toBe("subscription");
    expect(open.result.syncToken).toBe("token");
    socket.send(JSON.stringify({ type: "request", id: "sync", method: "session.sync", params: { sessionId: "session", syncToken: "token", subscriptionToken: "subscription" } }));
    while (!frames.some((frame) => frame.topic === "session.progress")) await new Promise((resolve) => setTimeout(resolve, 1));

    expect(frames.findIndex((frame) => frame.id === "open")).toBeLessThan(frames.findIndex((frame) => frame.id === "sync"));
    expect(frames.findIndex((frame) => frame.id === "sync")).toBeLessThan(frames.findIndex((frame) => frame.topic === "session.progress"));
    socket.close();
  });
});
