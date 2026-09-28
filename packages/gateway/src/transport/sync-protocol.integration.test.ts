import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createServer } from "node:http";
import WebSocket from "ws";
import { afterEach, describe, expect, it, vi } from "vitest";
import { GatewayServer, MAXIMUM_REKEYED_SESSION_IDS } from "./server.js";
import { DeviceStore } from "../security/device-store.js";

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => { await Promise.all(cleanups.splice(0).map((cleanup) => cleanup())); });

describe("two-phase session synchronization protocol", () => {
  it("joins overlapping opens, preserves independent completion order, and cleans failed/oversized owners", async () => {
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
      info: () => ({ gatewayVersion: "test", piVersion: "test", protocolVersion: 6, minProtocolVersion: 6, machineId: "machine", machineName: "test", capabilities: [] }),
      terminalBelongsToSession: () => false,
      releaseClient: vi.fn(),
      releaseSessionProcessTranscripts: vi.fn(),
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
        if (method === "session.presentation.set") {
          return context.setPresentationVisibility(
            sessionId,
            params.subscriptionToken,
            params.revision,
            params.visible,
          );
        }
        throw new Error(`unexpected method ${method}`);
      },
    };
    const sessions = {
      subscribe: vi.fn(),
      setPresentationVisibility: vi.fn((input: { revision: number; visible: boolean }) => ({
        revision: input.revision,
        visible: input.visible,
      })),
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
      auth: { detachClient: vi.fn(), cancelOwner: vi.fn() } as any,
      service: service as any,
      logger: { log: vi.fn() } as any,
    });
    await gateway.listen();
    cleanups.push(async () => { await gateway.close(); });

    const socket = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${token}` } });
    const frames: any[] = [];
    socket.on("message", (raw) => frames.push(JSON.parse(raw.toString())));
    await new Promise<void>((resolve) => socket.once("open", () => resolve()));
    socket.send(JSON.stringify({ type: "hello", protocolVersion: 6 }));
    while (!frames.some((frame) => frame.type === "hello")) await new Promise((resolve) => setTimeout(resolve, 1));

    const request = (id: string, method: string, sessionId: string, extra: Record<string, unknown> = {}) => {
      socket.send(JSON.stringify({ type: "request", id, method, params: { sessionId, ...extra } }));
    };
    const waitStarted = async (sessionId: string, count: number): Promise<void> => {
      while ((startedCounts.get(sessionId) ?? 0) < count) await new Promise((resolve) => setTimeout(resolve, 1));
    };
    // Frames on one socket are admitted in order, so a later frame's answer
    // proves every frame before it was already admitted. The probe is a
    // `session.sync` for a token no synchronization owns, which fails closed.
    const awaitAdmitted = async (id: string): Promise<void> => {
      request(id, "session.sync", "same", { syncToken: "not-a-token" });
      while (!frames.some((frame) => frame.id === id)) await new Promise((resolve) => setTimeout(resolve, 1));
      expect(frames.find((frame) => frame.id === id).error.code).toBe("conflict");
    };
    request("open-1", "session.open", "same");
    await waitStarted("same", 1);
    // A retried open joins the attempt already in flight for this connection and
    // session: one invocation answers both requests with the same result instead
    // of failing the retry as a duplicate open (C-6).
    request("open-2", "session.open", "same");
    await awaitAdmitted("join-fence");
    openResolvers.get("same")?.();
    while (!frames.some((frame) => frame.id === "open-1")
      || !frames.some((frame) => frame.id === "open-2")) await new Promise((resolve) => setTimeout(resolve, 1));
    const first = frames.find((frame) => frame.id === "open-1");
    const joinedOpen = frames.find((frame) => frame.id === "open-2");
    expect(startedCounts.get("same")).toBe(1);
    expect(joinedOpen.error).toBeUndefined();
    expect(joinedOpen.result).toEqual(first.result);
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
    mobile.send(JSON.stringify({ type: "hello", protocolVersion: 6, clientRole: "mobile" }));
    while (!mobileFrames.some((frame) => frame.type === "hello")) await new Promise((resolve) => setTimeout(resolve, 1));
    const mobileOpenSync = async (prefix: string, sessionId: string) => {
      const expectedCount = (startedCounts.get(sessionId) ?? 0) + 1;
      mobile.send(JSON.stringify({ type: "request", id: `${prefix}-open`, method: "session.open", params: { sessionId } }));
      await waitStarted(sessionId, expectedCount);
      openResolvers.get(sessionId)?.();
      while (!mobileFrames.some((frame) => frame.id === `${prefix}-open`)) await new Promise((resolve) => setTimeout(resolve, 1));
      const opened = mobileFrames.find((frame) => frame.id === `${prefix}-open`);
      expect(opened.ok).toBe(true);
      if (prefix === "mobile-c") {
        mobile.send(JSON.stringify({ type: "request", id: "before-sync-visible", method: "session.presentation.set",
          params: { sessionId, subscriptionToken: opened.result.subscriptionToken, revision: 1, visible: true } }));
        await vi.waitFor(() => expect(mobileFrames.find((frame) => frame.id === "before-sync-visible")?.error?.code).toBe("conflict"));
        expect(sessions.setPresentationVisibility).not.toHaveBeenCalled();
      }
      mobile.send(JSON.stringify({ type: "request", id: `${prefix}-sync`, method: "session.sync", params: { sessionId, syncToken: opened.result.syncToken } }));
      while (!mobileFrames.some((frame) => frame.id === `${prefix}-sync`)) await new Promise((resolve) => setTimeout(resolve, 1));
      return opened.result.subscriptionToken;
    };
    await mobileOpenSync("mobile-a", "a");
    const mobileBToken = await mobileOpenSync("mobile-b", "b");
    const mobileCToken = await mobileOpenSync("mobile-c", "c");
    mobile.send(JSON.stringify({
      type: "request",
      id: "mobile-c-visible",
      method: "session.presentation.set",
      params: { sessionId: "c", subscriptionToken: mobileCToken, revision: 1, visible: true },
    }));
    while (!mobileFrames.some((frame) => frame.id === "mobile-c-visible")) await new Promise((resolve) => setTimeout(resolve, 1));
    expect(mobileFrames.find((frame) => frame.id === "mobile-c-visible").result).toEqual({ revision: 1, visible: true });
    expect(sessions.setPresentationVisibility).toHaveBeenCalledWith(expect.objectContaining({
      sessionId: "c",
      subscriptionToken: mobileCToken,
      revision: 1,
      visible: true,
    }));

    mobile.send(JSON.stringify({ type: "request", id: "stale-token-visible", method: "session.presentation.set",
      params: { sessionId: "c", subscriptionToken: mobileBToken, revision: 2, visible: true } }));
    await vi.waitFor(() => expect(mobileFrames.find((frame) => frame.id === "stale-token-visible")?.error?.code).toBe("conflict"));
    expect(sessions.setPresentationVisibility).toHaveBeenCalledOnce();

    request("technical-visible", "session.presentation.set", "a", {
      subscriptionToken: openA.result.subscriptionToken,
      revision: 1,
      visible: true,
    });
    while (!frames.some((frame) => frame.id === "technical-visible")) await new Promise((resolve) => setTimeout(resolve, 1));
    expect(frames.find((frame) => frame.id === "technical-visible").error.code).toBe("invalid_request");

const mobileEventStart = mobileFrames.length;
    gateway.broadcastSession("a", "session.progress", { runtimeGeneration: "generation-a", eventSequence: 200, revision: 200, data: { message: "a" } } as any);
    gateway.broadcastSession("b", "session.progress", { runtimeGeneration: "generation-b", eventSequence: 200, revision: 200, data: { message: "b" } } as any);
    gateway.broadcastSession("c", "session.progress", { runtimeGeneration: "generation-c", eventSequence: 200, revision: 200, data: { message: "c" } } as any);
    while (!mobileFrames.slice(mobileEventStart).some((frame) => frame.sessionId === "c")) await new Promise((resolve) => setTimeout(resolve, 1));
    expect(mobileFrames.slice(mobileEventStart).filter((frame) => frame.topic === "session.progress").map((frame) => frame.sessionId)).toEqual(["c"]);
    gateway.rekeySession("c", "canonical-c");
    mobile.send(JSON.stringify({ type: "request", id: "alias-visible", method: "session.presentation.set",
      params: { sessionId: "c", subscriptionToken: mobileCToken, revision: 2, visible: true } }));
    await vi.waitFor(() => expect(mobileFrames.find((frame) => frame.id === "alias-visible")?.ok).toBe(true));
    expect(sessions.setPresentationVisibility).toHaveBeenLastCalledWith(expect.objectContaining({
      sessionId: "canonical-c", subscriptionToken: mobileCToken, revision: 2, visible: true,
    }));
    mobile.close();
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
      info: () => ({ gatewayVersion: "test", piVersion: "test", protocolVersion: 6, minProtocolVersion: 6, machineId: "machine", machineName: "test", capabilities: [] }),
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
      auth: { detachClient: vi.fn(), cancelOwner: vi.fn() } as any,
      service: service as any,
      logger: { log: vi.fn() } as any,
    });
    await gateway.listen();
    cleanups.push(async () => { await gateway.close(); });

    const socket = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${token}` } });
    const frames: any[] = [];
    socket.on("message", (raw) => frames.push(JSON.parse(raw.toString())));
    await new Promise<void>((resolve) => socket.once("open", () => resolve()));
    socket.send(JSON.stringify({ type: "hello", protocolVersion: 6 }));
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
    // The recovered live event is written after the rebaseline frame; wait for
    // both so the ordering assertions below never race the socket.
    while (!frames.some((frame) => frame.topic === "session.rebaseline")
      || !frames.some((frame) => frame.topic === "session.progress" && frame.payload?.eventSequence === 100)) {
      if (Date.now() >= deadline) throw new Error("recovery snapshot or recovered event timed out");
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
      info: () => ({ gatewayVersion: "test", piVersion: "test", protocolVersion: 6, minProtocolVersion: 6, machineId: "machine", machineName: "test", capabilities: [] }),
      terminalBelongsToSession: (terminalId: string, sessionId: string) => terminalId === "terminal-before" && sessionId === "before",
      releaseClient: vi.fn(),
      releaseSessionProcessTranscripts: vi.fn(),
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
      devices, uploads: {} as any, sessions: sessions as any,
      auth: { detachClient: vi.fn(), cancelOwner: vi.fn() } as any,
      service: service as any, logger: { log: vi.fn() } as any,
    });
    await gateway.listen();
    cleanups.push(async () => { await gateway.close(); });

    const socket = new WebSocket(`ws://127.0.0.1:${address.port}/v1/socket`, { headers: { authorization: `Bearer ${token}` } });
    const frames: any[] = [];
    socket.on("message", (raw) => frames.push(JSON.parse(raw.toString())));
    await new Promise<void>((resolve) => socket.once("open", () => resolve()));
    socket.send(JSON.stringify({ type: "hello", protocolVersion: 6 }));
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

    // A replacement open rotates the carried fork token. A late close from the
    // retired parent view resolves through the alias but cannot revoke the
    // child's newer exact token.
    const staleSource = await request("open-stale-source", "session.open", "stale-source");
    await request("sync-stale-source", "session.sync", "stale-source", { syncToken: staleSource.result.syncToken });
    const staleFork = await request("fork-stale-source", "session.fork", "stale-source", { commandId: "command-fork-stale-source" });
    const staleChildID = staleFork.result.sessionId;
    const staleChild = await request("open-stale-child", "session.open", staleChildID);
    await request("sync-stale-child", "session.sync", staleChildID, { syncToken: staleChild.result.syncToken });
    const staleClose = await request("close-stale-parent", "session.close", "stale-source", {
      subscriptionToken: staleSource.result.subscriptionToken,
    });
    expect(staleClose.result).toEqual({ closed: false });
    const staleCloseEvents = frames.length;
    gateway.broadcastSession(staleChildID, "session.progress", event(staleChildID, 2) as any);
    await waitFor(() => frames.slice(staleCloseEvents).some((frame) =>
      frame.topic === "session.progress" && frame.sessionId === staleChildID));

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

describe("outbound queue coalescing across a synchronization barrier", () => {
  it("releases the quarantined suffix as one rebaseline instead of filling the queue with it", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-sync-coalesce-"));
    const devices = new DeviceStore(root, "machine");
    await devices.initialize();
    const token = JSON.parse(await (await import("node:fs/promises")).readFile(join(root, "gateway", "local-auth.json"), "utf8")).bearerToken;
    const probe = createServer();
    await new Promise<void>((resolve) => probe.listen(0, "127.0.0.1", resolve));
    const address = probe.address();
    if (!address || typeof address === "string") throw new Error("probe did not bind");
    const port = address.port;
    await new Promise<void>((resolve) => probe.close(() => resolve()));

    interface ClientContext {
      beginSynchronization(sessionId: string): string;
      establishSynchronization(sessionId: string, snapshot: unknown): void;
      completeSynchronization(sessionId: string, syncToken: string): void;
    }
    interface ClientRequest {
      sessionId: string;
      syncToken?: string;
    }
    let beganOpen!: () => void;
    const openBegan = new Promise<void>((resolve) => { beganOpen = resolve; });
    let releaseOpen!: () => void;
    const openGate = new Promise<void>((resolve) => { releaseOpen = resolve; });
    const service = {
      info: () => ({ gatewayVersion: "test", piVersion: "test", protocolVersion: 6, minProtocolVersion: 6, machineId: "machine", machineName: "test", capabilities: [] }),
      terminalBelongsToSession: () => false,
      releaseClient: vi.fn(),
      invoke: async (context: ClientContext, method: string, params: ClientRequest) => {
        const sessionId = params.sessionId;
        if (method === "session.open") {
          const syncToken = context.beginSynchronization(sessionId);
          beganOpen();
          await openGate;
          const snapshot = { sessionId, runtimeGeneration: "generation-barrier", eventSequence: 1, revision: 1 };
          context.establishSynchronization(sessionId, snapshot);
          return { session: snapshot, syncToken, subscriptionToken: syncToken };
        }
        if (method === "session.sync") {
          context.completeSynchronization(sessionId, params.syncToken!);
          return { synchronized: true };
        }
        throw new Error(`unexpected method ${method}`);
      },
    };
    const logger = { log: vi.fn() };
    const gateway = new GatewayServer({
      host: "127.0.0.1",
      port,
      maxFrameBytes: 512 * 1_024,
      maximumOutboundBytes: 48 * 1_024,
      devices,
      uploads: {} as never,
      sessions: { subscribe: vi.fn(), unsubscribeClient: vi.fn(), unsubscribe: vi.fn() } as never,
      auth: { detachClient: vi.fn(), cancelOwner: vi.fn() } as never,
      service: service as never,
      logger: logger as never,
    });
    await gateway.listen();
    cleanups.push(async () => { await gateway.close(); });

    const socket = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${token}` } });
    const frames: Array<{ type?: string }> = [];
    socket.on("message", (raw) => frames.push(JSON.parse(raw.toString())));
    await new Promise<void>((resolve) => socket.once("open", () => resolve()));
    socket.send(JSON.stringify({ type: "hello", protocolVersion: 6 }));
    while (!frames.some((frame) => frame.type === "hello")) await new Promise((resolve) => setTimeout(resolve, 1));

    const connection = [...(gateway as unknown as {
      clients: Map<string, {
        outbound: OrderedOutboundQueue;
        socket: WebSocket;
        synchronizations: Map<string, unknown>;
        synchronizationBytes: number;
      }>;
    }).clients.values()][0]!;
    // Hold every application write, so the baseline response and its
    // synchronization suffix stay in the queue the way a slow link leaves them.
    const held: Array<{ encoded: string; done: (error?: Error) => void }> = [];
    vi.spyOn(connection.socket, "send").mockImplementation(((encoded: string, done?: (error?: Error) => void) => {
      held.push({ encoded, done: done ?? (() => {}) });
    }) as never);
    const release = () => { for (let index = 0; index < held.length; index += 1) held[index]!.done(); };
    const snapshot = (eventSequence: number) => ({
      runtimeGeneration: "generation-barrier", eventSequence, revision: eventSequence,
      data: "x".repeat(24 * 1_024),
    });

    socket.send(JSON.stringify({ type: "request", id: "barrier-open", method: "session.open", params: { sessionId: "barrier-session" } }));
    await openBegan;
    // While the barrier is pending, this session's state is quarantined, not
    // queued: only the hello frame has been accepted so far.
    gateway.broadcastSession("barrier-session", "session.snapshot", snapshot(2));
    gateway.broadcastSession("barrier-session", "session.snapshot", snapshot(3));
    gateway.broadcastSession("barrier-session", "session.snapshot", snapshot(4));
    gateway.broadcastSession("barrier-session", "session.progress", { runtimeGeneration: "generation-barrier", eventSequence: 5, revision: 5, data: {} });
    expect(connection.outbound.snapshot()).toMatchObject({ queuedFrames: 0, acceptedFrames: 1 });
    expect(connection.synchronizations.has("barrier-session")).toBe(true);

    releaseOpen();
    await vi.waitFor(() => expect(held).toHaveLength(1)); // the open response
    const opened = JSON.parse(held[0]!.encoded) as { id: string; result: { syncToken: string } };
    expect(opened.id).toBe("barrier-open");
    socket.send(JSON.stringify({ type: "request", id: "barrier-sync", method: "session.sync", params: { sessionId: "barrier-session", syncToken: opened.result.syncToken } }));
    await vi.waitFor(() => expect(connection.synchronizations.has("barrier-session")).toBe(false));
    // Three quarantined 24 KiB snapshots exceed this connection's 48 KiB queue
    // once the responses ahead of them are counted; the suffix is released as
    // the one frame that carries the sequences it covers, and a later snapshot
    // then supersedes even that.
    gateway.broadcastSession("barrier-session", "session.snapshot", snapshot(6));
    expect(connection.outbound.snapshot()).toMatchObject({ queuedFrames: 3, acceptedFrames: 4, oldestTopic: "response" });
    expect(connection.synchronizationBytes).toBe(0);
    expect(logger.log.mock.calls.some((call) => call[2]?.event === "connection.outbound-capacity")).toBe(false);
    release();

    // Both responses precede the synchronization suffix, and the suffix is the
    // gap-tolerant form of the newest state: the phone installs it as fresh
    // authority instead of resynchronizing across the superseded sequences.
    expect(held).toHaveLength(3);
    const delivered = held.map((write) => JSON.parse(write.encoded) as {
      id?: string;
      topic?: string;
      sessionId?: string;
      payload: { eventSequence?: number; subscriptionToken?: string; snapshot?: { sessionId: string; eventSequence: number } };
    });
    expect(delivered[0]!.id).toBe("barrier-open");
    expect(delivered[1]!.id).toBe("barrier-sync");
    expect(delivered[2]).toMatchObject({ topic: "session.rebaseline", sessionId: "barrier-session" });
    expect(delivered[2]!.payload.subscriptionToken).toBe(opened.result.syncToken);
    expect(delivered[2]!.payload.snapshot).toMatchObject({ eventSequence: 6 });
    socket.close();
  });
});

describe("disposable read cancellation", () => {
  it("joins a retried open, revokes only an unclaimed barrier, and never cancels an owner", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-sync-cancel-"));
    const devices = new DeviceStore(root, "machine");
    await devices.initialize();
    const token = JSON.parse(await (await import("node:fs/promises")).readFile(join(root, "gateway", "local-auth.json"), "utf8")).bearerToken;
    const probe = createServer();
    await new Promise<void>((resolve) => probe.listen(0, "127.0.0.1", resolve));
    const address = probe.address();
    if (!address || typeof address === "string") throw new Error("probe did not bind");
    const port = address.port;
    await new Promise<void>((resolve) => probe.close(() => resolve()));

    // The fixture's open is the slow work the incident hit: it stays in flight
    // until its signal aborts, so the test can cancel it while it runs.
    const openStarts: string[] = [];
    const aborts: string[] = [];
    const promptStarts: string[] = [];
    let releaseOpen: (() => void) | undefined;
    let releasePrompt: (() => void) | undefined;
    let releaseGatedSync: (() => void) | undefined;
    const records: Array<{ level: string; message: string; metadata: Record<string, unknown> }> = [];
    const service = {
      info: () => ({ gatewayVersion: "test", piVersion: "test", protocolVersion: 6, minProtocolVersion: 6, machineId: "machine", machineName: "test", capabilities: [] }),
      terminalBelongsToSession: () => false,
      releaseClient: vi.fn(),
      releaseSessionProcessTranscripts: vi.fn(),
      invoke: async (context: any, method: string, params: any) => {
        const sessionId = params.sessionId as string;
        if (method === "session.sync") {
          // A synchronization acknowledgement is the owner's, not a read: the
          // fixture can hold one open to prove a cancel does not end it.
          if (params.syncToken === "gated") {
            await new Promise<void>((resolve) => { releaseGatedSync = resolve; });
            return { synchronized: true };
          }
          context.completeSynchronization(sessionId, params.syncToken);
          return { synchronized: true };
        }
        if (method === "session.prompt") {
          promptStarts.push(sessionId);
          await new Promise<void>((resolve) => { releasePrompt = resolve; });
          return { queued: true };
        }
        if (method !== "session.open") throw new Error(`unexpected method ${method}`);
        const syncToken = context.beginSynchronization(sessionId);
        openStarts.push(sessionId);
        // Only an abort while the attempt still computes is the shared work
        // being abandoned: releasing a finished flight also aborts its signal.
        let settled = false;
        await new Promise<void>((resolve, reject) => {
          releaseOpen = () => { settled = true; resolve(); };
          context.signal?.addEventListener("abort", () => {
            if (settled) return;
            aborts.push(sessionId);
            reject(context.signal.reason);
          }, { once: true });
        });
        const snapshot = { sessionId, runtimeGeneration: `generation-${sessionId}`, eventSequence: 1, revision: 1 };
        context.establishSynchronization(sessionId, snapshot);
        return { session: snapshot, syncToken, subscriptionToken: syncToken };
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
      auth: { detachClient: vi.fn(), cancelOwner: vi.fn() } as any,
      service: service as any,
      logger: { log: (level: string, message: string, metadata: Record<string, unknown>) => { records.push({ level, message, metadata }); } } as any,
    });
    await gateway.listen();
    cleanups.push(async () => { await gateway.close(); });

    const socket = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${token}` } });
    const frames: any[] = [];
    socket.on("message", (raw) => frames.push(JSON.parse(raw.toString())));
    await new Promise<void>((resolve) => socket.once("open", () => resolve()));
    socket.send(JSON.stringify({ type: "hello", protocolVersion: 6 }));
    while (!frames.some((frame) => frame.type === "hello")) await new Promise((resolve) => setTimeout(resolve, 1));

    const connection = [...(gateway as unknown as {
      clients: Map<string, { synchronizations: Map<string, unknown> }>;
    }).clients.values()][0]!;
    const tick = async (): Promise<void> => { await new Promise((resolve) => setTimeout(resolve, 1)); };
    const waitFor = async (predicate: () => boolean, what: string): Promise<void> => {
      const deadline = Date.now() + 5_000;
      while (!predicate()) {
        if (Date.now() >= deadline) throw new Error(`timed out waiting for ${what}`);
        await tick();
      }
    };
    const answered = (id: string): any => frames.find((frame) => frame.id === id);
    const open = (id: string, sessionId: string): void => {
      socket.send(JSON.stringify({ type: "request", id, method: "session.open", params: { sessionId } }));
    };
    const sync = (id: string, syncToken: string): void => {
      socket.send(JSON.stringify({ type: "request", id, method: "session.sync", params: { sessionId: "slow", syncToken } }));
    };
    const cancel = (id: string): void => { socket.send(JSON.stringify({ type: "cancel", id })); };
    const cancelled = () => records.filter((record) => record.metadata.event === "rpc.cancelled");
    // Frames on one socket are admitted in order, so a later frame's answer
    // proves every frame before it was already admitted. The probe is a
    // synchronization with a token this fixture refuses, which always answers.
    const awaitAdmitted = async (id: string): Promise<void> => {
      sync(id, "not-a-token");
      while (!answered(id)) await tick();
    };

    open("open-1", "slow");
    await waitFor(() => openStarts.length === 1, "the first open");
    // The retry joins the attempt in flight before it is released.
    open("open-2", "slow");
    await awaitAdmitted("join-fence");
    expect(openStarts).toEqual(["slow"]);
    expect(answered("open-2")).toBeUndefined();

    // A cancel for the first open leaves the retry's answer alone: the shared
    // attempt keeps running for the request that still waits for it, and the
    // synchronization it installed stays for the retry to deliver.
    cancel("open-1");
    await waitFor(() => cancelled().length === 1, "the first cancellation record");
    expect(answered("open-1")).toBeUndefined();
    expect(aborts).toEqual([]);
    expect(cancelled()[0]!.metadata).toMatchObject({ method: "session.open", requestID: "open-1", stage: "session.open.attempt" });

    releaseOpen?.();
    await waitFor(() => answered("open-2") !== undefined, "the joined retry's answer");
    expect(answered("open-2").ok).toBe(true);
    expect(answered("open-2").result.subscriptionToken).toBeTruthy();
    // The retry owns the barrier its answer installed: it can synchronize.
    sync("sync-1", answered("open-2").result.subscriptionToken);
    await waitFor(() => answered("sync-1") !== undefined, "the retry's synchronization");
    expect(answered("sync-1").ok).toBe(true);

    // Cancelling the last waiter stops the shared work: nothing computes an
    // answer nobody waits for, and the cancelled request is never answered.
    open("open-3", "slow");
    await waitFor(() => openStarts.length === 2, "the second attempt");
    open("open-4", "slow");
    await awaitAdmitted("join-fence-2");
    expect(openStarts).toHaveLength(2);
    cancel("open-3");
    await waitFor(() => cancelled().length === 2, "the third cancellation record");
    expect(aborts).toEqual([]);
    cancel("open-4");
    await waitFor(() => aborts.length === 1, "the shared attempt to abort");
    await waitFor(() => cancelled().length === 3, "the last cancellation record");
    expect(answered("open-3")).toBeUndefined();
    expect(answered("open-4")).toBeUndefined();
    expect(cancelled()[2]!.metadata).toMatchObject({ method: "session.open", requestID: "open-4", stage: "session.open.join" });

    // A cancel for an id this connection never admitted changes nothing.
    cancel("never-admitted");
    await tick();
    expect(cancelled()).toHaveLength(3);

    // An accepted prompt and a synchronization acknowledgement are their
    // owners', not disposable reads: a cancel for either changes nothing, and
    // both are still answered.
    socket.send(JSON.stringify({ type: "request", id: "prompt-1", method: "session.prompt", params: { sessionId: "slow" } }));
    await waitFor(() => promptStarts.length === 1, "the admitted prompt");
    cancel("prompt-1");
    await tick();
    expect(cancelled()).toHaveLength(3);
    releasePrompt?.();
    await waitFor(() => answered("prompt-1") !== undefined, "the prompt's answer");
    expect(answered("prompt-1").ok).toBe(true);
    sync("sync-gated", "gated");
    await waitFor(() => releaseGatedSync !== undefined, "the admitted synchronization");
    cancel("sync-gated");
    await tick();
    expect(cancelled()).toHaveLength(3);
    releaseGatedSync?.();
    await waitFor(() => answered("sync-gated") !== undefined, "the synchronization's answer");
    expect(answered("sync-gated").ok).toBe(true);

    // A cancel that crosses an answered open revokes the barrier that response
    // delivered, so the retry in that window is not a duplicate.
    open("open-5", "slow");
    await waitFor(() => openStarts.length === 3, "an answered open");
    releaseOpen?.();
    await waitFor(() => answered("open-5") !== undefined, "the answered open's response");
    expect(answered("open-5").ok).toBe(true);
    expect(connection.synchronizations.has("slow")).toBe(true);
    cancel("open-5");
    await waitFor(() => !connection.synchronizations.has("slow"), "the abandoned barrier to be revoked");
    open("open-6", "slow");
    await waitFor(() => openStarts.length === 4, "the retry after the revocation");
    releaseOpen?.();
    await waitFor(() => answered("open-6") !== undefined, "the retry's answer");
    expect(answered("open-6").ok).toBe(true);
    sync("sync-2", answered("open-6").result.subscriptionToken);
    await waitFor(() => answered("sync-2") !== undefined, "the retry's synchronization");
    expect(answered("sync-2").ok).toBe(true);
    expect(cancelled()).toHaveLength(3);

    // Two delivered answers carry the barrier's token, so a cancel for only one
    // of them leaves it: the phone may still accept the other. Once both are
    // abandoned the barrier goes, and the next open is not a duplicate.
    open("open-7", "slow");
    await waitFor(() => openStarts.length === 5, "the joined attempt");
    open("open-8", "slow");
    await awaitAdmitted("join-fence-3");
    expect(openStarts).toHaveLength(5);
    releaseOpen?.();
    await waitFor(() => answered("open-7") !== undefined && answered("open-8") !== undefined, "both joined answers");
    expect(answered("open-7").result.subscriptionToken).toBe(answered("open-8").result.subscriptionToken);
    cancel("open-7");
    await tick();
    expect(connection.synchronizations.has("slow")).toBe(true);
    cancel("open-8");
    await waitFor(() => !connection.synchronizations.has("slow"), "the barrier revoked with its last delivered response");
    open("open-9", "slow");
    await waitFor(() => openStarts.length === 6, "the retry after both cancellations");
    releaseOpen?.();
    await waitFor(() => answered("open-9") !== undefined, "the last retry's answer");
    expect(answered("open-9").ok).toBe(true);
    socket.close();
  });
});
