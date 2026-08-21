import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createServer } from "node:http";
import WebSocket, { WebSocketServer } from "ws";
import { afterEach, describe, expect, it, vi } from "vitest";
import { GatewayServer, MAXIMUM_REKEYED_SESSION_IDS } from "./server.js";
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
        if (method === "session.close") {
          return { closed: context.unsubscribe(sessionId, params.subscriptionToken as string | undefined) };
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

    // A sequential re-open replaces the installed subscription instead of
    // conflicting, so a reconnecting client always converges on one owner. The
    // revoked token can no longer close the replacement, and the replacement
    // synchronizes normally.
    request("open-3", "session.open", "same");
    await waitStarted("same", 2);
    openResolvers.get("same")?.();
    while (!frames.some((frame) => frame.id === "open-3")) await new Promise((resolve) => setTimeout(resolve, 1));
    const replaced = frames.find((frame) => frame.id === "open-3");
    expect(replaced.error).toBeUndefined();
    expect(replaced.result.syncToken).not.toBe(first.result.syncToken);
    request("close-stale", "session.close", "same", { subscriptionToken: first.result.subscriptionToken });
    while (!frames.some((frame) => frame.id === "close-stale")) await new Promise((resolve) => setTimeout(resolve, 1));
    expect(frames.find((frame) => frame.id === "close-stale").result).toEqual({ closed: false });
    request("sync-3", "session.sync", "same", { syncToken: replaced.result.syncToken });
    while (!frames.some((frame) => frame.id === "sync-3")) await new Promise((resolve) => setTimeout(resolve, 1));
    expect(frames.find((frame) => frame.id === "sync-3").result).toEqual({ synchronized: true });

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

    // Technical clients may keep independent subscriptions, but a mobile
    // presentation connection is explicitly one-slot: A -> B -> C revokes
    // every prior exact owner before installing the next one.
    const mobile = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${token}` } });
    const mobileFrames: any[] = [];
    mobile.on("message", (raw) => mobileFrames.push(JSON.parse(raw.toString())));
    await new Promise<void>((resolve) => mobile.once("open", () => resolve()));
    mobile.send(JSON.stringify({ type: "hello", protocolVersion: 3, clientRole: "mobile" }));
    while (!mobileFrames.some((frame) => frame.type === "hello")) await new Promise((resolve) => setTimeout(resolve, 1));
    const mobileOpenSync = async (prefix: string, sessionId: string) => {
      const expectedCount = (startedCounts.get(sessionId) ?? 0) + 1;
      mobile.send(JSON.stringify({ type: "request", id: `${prefix}-open`, method: "session.open", params: { sessionId } }));
      await waitStarted(sessionId, expectedCount);
      openResolvers.get(sessionId)?.();
      while (!mobileFrames.some((frame) => frame.id === `${prefix}-open`)) await new Promise((resolve) => setTimeout(resolve, 1));
      const opened = mobileFrames.find((frame) => frame.id === `${prefix}-open`);
      expect(opened.ok).toBe(true);
      mobile.send(JSON.stringify({ type: "request", id: `${prefix}-sync`, method: "session.sync", params: { sessionId, syncToken: opened.result.syncToken } }));
      while (!mobileFrames.some((frame) => frame.id === `${prefix}-sync`)) await new Promise((resolve) => setTimeout(resolve, 1));
      return opened.result.subscriptionToken;
    };
    await mobileOpenSync("mobile-a", "a");
    await mobileOpenSync("mobile-b", "b");
    await mobileOpenSync("mobile-c", "c");
    const mobileEventStart = mobileFrames.length;
    gateway.broadcastSession("a", "session.progress", { runtimeGeneration: "generation-a", eventSequence: 200, revision: 200, data: { message: "a" } } as any);
    gateway.broadcastSession("b", "session.progress", { runtimeGeneration: "generation-b", eventSequence: 200, revision: 200, data: { message: "b" } } as any);
    gateway.broadcastSession("c", "session.progress", { runtimeGeneration: "generation-c", eventSequence: 200, revision: 200, data: { message: "c" } } as any);
    while (!mobileFrames.slice(mobileEventStart).some((frame) => frame.sessionId === "c")) await new Promise((resolve) => setTimeout(resolve, 1));
    expect(mobileFrames.slice(mobileEventStart).filter((frame) => frame.topic === "session.progress").map((frame) => frame.sessionId)).toEqual(["c"]);
    mobile.close();
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

describe("synchronization catch-up overflow recovery", () => {
  it("converges an overflowed catch-up with the authoritative snapshot and falls back to resyncRequired", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-sync-overflow-"));
    const devices = new DeviceStore(root, "machine");
    await devices.initialize();
    const token = JSON.parse(await (await import("node:fs/promises")).readFile(join(root, "gateway", "local-auth.json"), "utf8")).bearerToken;
    const probe = createServer();
    await new Promise<void>((resolve) => probe.listen(0, "127.0.0.1", resolve));
    const address = probe.address();
    if (!address || typeof address === "string") throw new Error("probe did not bind");
    const port = address.port;
    await new Promise<void>((resolve) => probe.close(() => resolve()));

    let gateway!: GatewayServer;
    let recoveryStartedResolve: (() => void) | undefined;
    let releaseRecovery: (() => void) | undefined;
    let releaseTimedOutOpen: (() => void) | undefined;
    const openCounts = new Map<string, number>();
    const recoveryStarted = new Promise<void>((resolve) => { recoveryStartedResolve = resolve; });
    const service = {
      info: () => ({ gatewayVersion: "test", piVersion: "test", protocolVersion: 3, minProtocolVersion: 3, machineId: "machine", machineName: "test", capabilities: [] }),
      terminalBelongsToSession: () => false,
      releaseClient: vi.fn(),
      recoverySnapshot: async (sessionId: string) => {
        if (sessionId === "gone") return undefined;
        if (sessionId === "live") {
          recoveryStartedResolve?.();
          await new Promise<void>((resolve) => { releaseRecovery = resolve; });
        }
        if (sessionId === "oversized") {
          return { sessionId, runtimeGeneration: `generation-${sessionId}`, eventSequence: 99, revision: 99, data: "x".repeat(1_100_000) };
        }
        return { sessionId, runtimeGeneration: `generation-${sessionId}`, eventSequence: 99, revision: 99 };
      },
      invoke: async (context: any, method: string, params: any) => {
        const sessionId = params.sessionId as string;
        if (method === "session.open") {
          const openCount = (openCounts.get(sessionId) ?? 0) + 1;
          openCounts.set(sessionId, openCount);
          const syncToken = context.beginSynchronization(sessionId);
          if (sessionId === "timeout") {
            await new Promise<void>((resolve) => { releaseTimedOutOpen = resolve; });
          }
          if (sessionId === "ordered") {
            // In-window events quarantine and flush exactly once after the ack.
            gateway.broadcastSession(sessionId, "session.progress", {
              runtimeGeneration: `generation-${sessionId}`,
              eventSequence: 2,
              revision: 2,
              data: { message: "buffered" },
            } as any);
          } else if (!(sessionId === "gone" && openCount > 1)) {
            // One frame larger than the quarantine byte budget forces overflow.
            gateway.broadcastSession(sessionId, "session.progress", {
              runtimeGeneration: `generation-${sessionId}`,
              eventSequence: 2,
              revision: 2,
              data: { message: "x".repeat(1_100_000) },
            } as any);
          }
          const snapshot = { sessionId, runtimeGeneration: `generation-${sessionId}`, eventSequence: 1, revision: 1 };
          context.establishSynchronization(sessionId, snapshot);
          return { session: snapshot, syncToken, subscriptionToken: syncToken };
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
    gateway = new GatewayServer({
      host: "127.0.0.1",
      port,
      maxFrameBytes: 1_048_576,
      synchronizationTimeoutMs: 250,
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

    const openAndSync = async (idPrefix: string, sessionId: string) => {
      socket.send(JSON.stringify({ type: "request", id: `${idPrefix}-open`, method: "session.open", params: { sessionId } }));
      while (!frames.some((frame) => frame.id === `${idPrefix}-open`)) await new Promise((resolve) => setTimeout(resolve, 1));
      const opened = frames.find((frame) => frame.id === `${idPrefix}-open`);
      expect(opened.ok).toBe(true);
      socket.send(JSON.stringify({ type: "request", id: `${idPrefix}-sync`, method: "session.sync", params: { sessionId, syncToken: opened.result.syncToken } }));
      while (!frames.some((frame) => frame.id === `${idPrefix}-sync`)) await new Promise((resolve) => setTimeout(resolve, 1));
    };

    await openAndSync("ordered", "ordered");
    const orderedDeadline = Date.now() + 5_000;
    while (!frames.some((frame) => frame.topic === "session.progress")) {
      if (Date.now() >= orderedDeadline) throw new Error("quarantined flush timed out");
      await new Promise((resolve) => setTimeout(resolve, 1));
    }
    const progressFrames = frames.filter((frame) => frame.topic === "session.progress");
    expect(progressFrames).toHaveLength(1);
    expect(progressFrames[0].payload).toMatchObject({ eventSequence: 2, data: { message: "buffered" } });
    expect(frames.findIndex((frame) => frame.id === "ordered-sync"))
      .toBeLessThan(frames.findIndex((frame) => frame.topic === "session.progress"));

    const liveSync = openAndSync("recover", "live");
    await recoveryStarted;
    gateway.broadcastSession("live", "session.progress", {
      runtimeGeneration: "generation-live",
      eventSequence: 100,
      revision: 100,
      data: { message: "arrived during recovery" },
    } as any);
    releaseRecovery?.();
    await liveSync;
    const deadline = Date.now() + 5_000;
    while (!frames.some((frame) => frame.topic === "session.rebaseline")) {
      if (Date.now() >= deadline) throw new Error("recovery snapshot timed out");
      await new Promise((resolve) => setTimeout(resolve, 1));
    }
    const recovery = frames.find((frame) => frame.topic === "session.rebaseline");
    expect(recovery.sessionId).toBe("live");
    expect(recovery.payload).toMatchObject({
      reason: "subscription catch-up overflow",
      subscriptionToken: expect.any(String),
      snapshot: { sessionId: "live", runtimeGeneration: "generation-live", eventSequence: 99 },
    });
    expect(frames.some((frame) => frame.topic === "transport.resyncRequired")).toBe(false);
    const syncIndex = frames.findIndex((frame) => frame.id === "recover-sync");
    const recoveryIndex = frames.findIndex((frame) => frame.topic === "session.rebaseline" && frame.sessionId === "live");
    expect(recoveryIndex).toBeGreaterThan(syncIndex);
    const recoveredEventIndex = frames.findIndex((frame) => frame.topic === "session.progress" && frame.payload.eventSequence === 100);
    expect(recoveredEventIndex).toBeGreaterThan(recoveryIndex);

    await openAndSync("missing", "gone");
    while (!frames.some((frame) => frame.topic === "transport.resyncRequired")) {
      if (Date.now() >= deadline) throw new Error("resyncRequired timed out");
      await new Promise((resolve) => setTimeout(resolve, 1));
    }
    const resync = frames.find((frame) => frame.topic === "transport.resyncRequired");
    expect(resync.sessionId).toBe("gone");
    expect(resync.payload).toMatchObject({ reason: "subscription catch-up overflow" });
    expect(sessions.unsubscribe).toHaveBeenCalledWith(expect.any(String), "gone");
    const goneResyncIndex = frames.indexOf(resync);
    gateway.broadcastSession("gone", "session.progress", {
      runtimeGeneration: "generation-gone", eventSequence: 500, revision: 500,
    } as any);
    await new Promise((resolve) => setTimeout(resolve, 25));
    expect(frames.slice(goneResyncIndex + 1).some((frame) => frame.topic === "session.progress" && frame.sessionId === "gone")).toBe(false);
    await openAndSync("gone-again", "gone");
    gateway.broadcastSession("gone", "session.progress", {
      runtimeGeneration: "generation-gone", eventSequence: 501, revision: 501,
    } as any);
    const reopenedDeadline = Date.now() + 5_000;
    while (!frames.some((frame) => frame.topic === "session.progress" && frame.sessionId === "gone" && frame.payload.eventSequence === 501)) {
      if (Date.now() >= reopenedDeadline) throw new Error("authoritative reopen did not restore event delivery");
      await new Promise((resolve) => setTimeout(resolve, 1));
    }

    await openAndSync("oversized", "oversized");
    const oversizedResyncDeadline = Date.now() + 5_000;
    while (!frames.some((frame) => frame.topic === "transport.resyncRequired" && frame.sessionId === "oversized")) {
      if (Date.now() >= oversizedResyncDeadline) throw new Error("oversized recovery resync timed out");
      await new Promise((resolve) => setTimeout(resolve, 1));
    }
    expect(frames.filter((frame) => frame.topic === "transport.resyncRequired" && frame.sessionId === "oversized")).toHaveLength(1);
    expect(frames.some((frame) => frame.topic === "session.rebaseline" && frame.sessionId === "oversized")).toBe(false);
    const fallbackEnd = frames.length;
    gateway.broadcastSession("oversized", "session.progress", {
      runtimeGeneration: "generation-oversized", eventSequence: 500, revision: 500,
    } as any);
    await new Promise((resolve) => setTimeout(resolve, 25));
    expect(frames.slice(fallbackEnd).some((frame) => frame.topic === "session.progress" && frame.sessionId === "oversized")).toBe(false);

    socket.send(JSON.stringify({ type: "request", id: "open-timeout", method: "session.open", params: { sessionId: "timeout" } }));
    const timeoutDeadline = Date.now() + 5_000;
    while (!frames.some((frame) => frame.topic === "transport.resyncRequired" && frame.sessionId === "timeout")) {
      if (Date.now() >= timeoutDeadline) throw new Error("synchronization timeout did not fire");
      await new Promise((resolve) => setTimeout(resolve, 1));
    }
    releaseTimedOutOpen?.();
    while (!frames.some((frame) => frame.id === "open-timeout")) await new Promise((resolve) => setTimeout(resolve, 1));
    expect(frames.find((frame) => frame.id === "open-timeout").ok).toBe(false);
    socket.close();
  });
});

describe("connection-wide synchronization ownership", () => {
  it("bounds concurrent quarantine bytes, releases them after every sync, and carries ownership across a rekey", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-sync-ownership-"));
    const devices = new DeviceStore(root, "machine");
    await devices.initialize();
    const token = JSON.parse(await (await import("node:fs/promises")).readFile(join(root, "gateway", "local-auth.json"), "utf8")).bearerToken;
    const probe = createServer();
    await new Promise<void>((resolve) => probe.listen(0, "127.0.0.1", resolve));
    const address = probe.address();
    if (!address || typeof address === "string") throw new Error("probe did not bind");
    await new Promise<void>((resolve) => probe.close(() => resolve()));

    let gateway!: GatewayServer;
    let releasePendingOpen: (() => void) | undefined;
    let pendingOpenBlocked = false;
    let pendingOpenStartedResolve: (() => void) | undefined;
    const pendingOpenStarted = new Promise<void>((resolve) => { pendingOpenStartedResolve = resolve; });
    const service = {
      info: () => ({ gatewayVersion: "test", piVersion: "test", protocolVersion: 3, minProtocolVersion: 3, machineId: "machine", machineName: "test", capabilities: [] }),
      terminalBelongsToSession: (terminalId: string, sessionId: string) => terminalId === "terminal-before" && sessionId === "before",
      releaseClient: vi.fn(),
      recoverySnapshot: async (sessionId: string) => ({ sessionId, runtimeGeneration: `generation-${sessionId}`, eventSequence: 99, revision: 99 }),
      invoke: async (context: any, method: string, params: any) => {
        const sessionId = params.sessionId as string;
        if (method === "session.open") {
          if (sessionId === "pending-before" && !pendingOpenBlocked) {
            pendingOpenBlocked = true;
            pendingOpenStartedResolve?.();
            await new Promise<void>((resolve) => { releasePendingOpen = resolve; });
          }
          const syncToken = context.beginSynchronization(sessionId);
          const session = { sessionId, runtimeGeneration: `generation-${sessionId}`, eventSequence: 1, revision: 1 };
          context.establishSynchronization(sessionId, session);
          return { session, syncToken, subscriptionToken: syncToken };
        }
        if (method === "session.sync") {
          context.completeSynchronization(sessionId, params.syncToken);
          return { synchronized: true };
        }
        if (method === "session.close") return { closed: context.unsubscribe(sessionId, params.subscriptionToken) };
        if (method === "terminal.attach") {
          context.attachTerminal(params.terminalId);
          return { attached: true };
        }
        if (method === "session.fork") {
          const nextSessionId = sessionId === "before" ? "after" : `${sessionId}-after`;
          gateway.rekeySession(sessionId, nextSessionId);
          return { sessionId: nextSessionId };
        }
        throw new Error(`unexpected method ${method}`);
      },
    };
    const sessions = { subscribe: vi.fn(), unsubscribe: vi.fn(), unsubscribeClient: vi.fn() };
    gateway = new GatewayServer({
      host: "127.0.0.1", port: address.port, maxFrameBytes: 1_048_576,
      maximumSynchronizationBytes: 1_000,
      devices, uploads: {} as any, sessions: sessions as any, auth: { cancelClient: vi.fn() } as any,
      service: service as any, logger: { log: vi.fn() } as any,
    });
    await gateway.listen();
    cleanups.push(async () => { await gateway.close(); });

    const socket = new WebSocket(`ws://127.0.0.1:${address.port}/v1/socket`, { headers: { authorization: `Bearer ${token}` } });
    const frames: any[] = [];
    socket.on("message", (raw) => frames.push(JSON.parse(raw.toString())));
    await new Promise<void>((resolve) => socket.once("open", () => resolve()));
    socket.send(JSON.stringify({ type: "hello", protocolVersion: 3 }));
    const waitFor = async (predicate: () => boolean) => {
      const deadline = Date.now() + 5_000;
      while (!predicate()) {
        if (Date.now() >= deadline) throw new Error("frame timed out");
        await new Promise((resolve) => setTimeout(resolve, 1));
      }
    };
    await waitFor(() => frames.some((frame) => frame.type === "hello"));
    const request = async (id: string, method: string, sessionId: string, extra: Record<string, unknown> = {}) => {
      socket.send(JSON.stringify({ type: "request", id, method, params: { sessionId, ...extra } }));
      await waitFor(() => frames.some((frame) => frame.id === id));
      return frames.find((frame) => frame.id === id);
    };
    const event = (sessionId: string, sequence: number) => ({
      runtimeGeneration: `generation-${sessionId}`, eventSequence: sequence, revision: sequence,
      data: "x".repeat(500),
    });

    socket.send(JSON.stringify({ type: "request", id: "pending-open", method: "session.open", params: { sessionId: "pending-before" } }));
    await pendingOpenStarted;
    gateway.rekeySession("pending-before", "pending-after");
    releasePendingOpen?.();
    await waitFor(() => frames.some((frame) => frame.id === "pending-open"));
    const pendingOpened = frames.find((frame) => frame.id === "pending-open");
    expect(pendingOpened.ok).toBe(true);
    expect(sessions.subscribe).toHaveBeenCalledWith(expect.any(String), "pending-after");
    await request("pending-sync", "session.sync", "pending-before", { syncToken: pendingOpened.result.syncToken });

    const openedA = await request("open-a", "session.open", "a");
    gateway.broadcastSession("a", "session.progress", event("a", 2) as any);
    const openedB = await request("open-b", "session.open", "b");
    gateway.broadcastSession("b", "session.progress", event("b", 2) as any);
    await request("sync-b", "session.sync", "b", { syncToken: openedB.result.syncToken });
    await waitFor(() => frames.some((frame) => frame.topic === "session.rebaseline" && frame.sessionId === "b"));
    expect(frames.filter((frame) => frame.topic === "transport.resyncRequired" && frame.sessionId === "b")).toHaveLength(0);
    await request("sync-a", "session.sync", "a", { syncToken: openedA.result.syncToken });
    await waitFor(() => frames.some((frame) => frame.topic === "session.progress" && frame.sessionId === "a"));

    // The first commit releases its exact admission, so a new same-sized
    // quarantine succeeds instead of inheriting b's aggregate overflow.
    const openedC = await request("open-c", "session.open", "c");
    gateway.broadcastSession("c", "session.progress", event("c", 2) as any);
    await request("sync-c", "session.sync", "c", { syncToken: openedC.result.syncToken });
    await waitFor(() => frames.some((frame) => frame.topic === "session.progress" && frame.sessionId === "c"));
    expect(frames.some((frame) => frame.topic === "session.rebaseline" && frame.sessionId === "c")).toBe(false);

    const openedBefore = await request("open-before", "session.open", "before");
    await request("sync-before", "session.sync", "before", { syncToken: openedBefore.result.syncToken });
    await request("attach-before", "terminal.attach", "before", { terminalId: "terminal-before" });
    await request("fork", "session.fork", "before", { commandId: "command-fork" });
    const afterEvents = frames.length;
    gateway.broadcastSession("before", "session.progress", event("before", 2) as any);
    gateway.broadcastSession("after", "session.progress", event("after", 2) as any);
    gateway.broadcastTerminal("terminal-before", "terminal.output", { data: "must be detached" } as any);
    await waitFor(() => frames.slice(afterEvents).some((frame) => frame.topic === "session.progress" && frame.sessionId === "after"));
    expect(frames.slice(afterEvents).filter((frame) => frame.topic === "session.progress").map((frame) => frame.sessionId)).toEqual(["after"]);
    expect(frames.slice(afterEvents).some((frame) => frame.topic === "terminal.output")).toBe(false);

    // Repeated forks retain only a bounded recent alias window. The immediate
    // predecessor must still route close controls to the current runtime.
    let currentSessionId = "after";
    let previousSessionId = "before";
    for (let index = 0; index <= MAXIMUM_REKEYED_SESSION_IDS; index += 1) {
      previousSessionId = currentSessionId;
      const forked = await request(`fork-${index}`, "session.fork", currentSessionId, { commandId: `command-fork-${index}` });
      currentSessionId = forked.result.sessionId;
    }
    const connection = [...(gateway as unknown as {
      clients: Map<string, { rekeyedSessionIds: Map<string, string> }>;
    }).clients.values()][0]!;
    expect(connection.rekeyedSessionIds.size).toBeLessThanOrEqual(MAXIMUM_REKEYED_SESSION_IDS);
    const repeatedForkEvents = frames.length;
    gateway.broadcastSession(currentSessionId, "session.progress", event(currentSessionId, 3) as any);
    await waitFor(() => frames.slice(repeatedForkEvents).some((frame) => frame.topic === "session.progress" && frame.sessionId === currentSessionId));
    const closed = await request("close-current-rekey", "session.close", previousSessionId, { subscriptionToken: openedBefore.result.subscriptionToken });
    expect(closed.result).toEqual({ closed: true });
    const closedEvents = frames.length;
    gateway.broadcastSession(currentSessionId, "session.progress", event(currentSessionId, 4) as any);
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(frames.slice(closedEvents).some((frame) => frame.sessionId === currentSessionId && frame.topic === "session.progress")).toBe(false);

    // Forking between open and sync moves the in-flight barrier and token;
    // the carried former ID still commits exactly once to the new session.
    const openedPending = await request("open-pending", "session.open", "pending");
    await request("fork-pending", "session.fork", "pending", { commandId: "command-fork-pending" });
    const pendingStart = frames.length;
    gateway.broadcastSession("pending-after", "session.progress", event("pending-after", 2) as any);
    await request("sync-pending", "session.sync", "pending", { syncToken: openedPending.result.syncToken });
    await waitFor(() => frames.slice(pendingStart).some((frame) => frame.topic === "session.progress" && frame.sessionId === "pending-after"));
    expect(frames.slice(pendingStart).filter((frame) => frame.topic === "session.progress" && frame.sessionId === "pending-after")).toHaveLength(1);
    socket.close();
  });
});
