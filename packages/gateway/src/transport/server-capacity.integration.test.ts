import { createServer, request } from "node:http";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import WebSocket from "ws";
import { afterEach, describe, expect, it, vi } from "vitest";
import { DeviceStore } from "../security/device-store.js";
import { CommandReceiptStore } from "./command-receipts.js";
import { GatewayService } from "./gateway-service.js";
import { DISPOSABLE_READ_DEADLINES_MS, GatewayServer, OrderedOutboundQueue, SUPERSEDED_CLOSE_CODE, type OutboundFrame } from "./server.js";
import { ResourceSampler } from "./stall-diagnostics.js";

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

/** One encoded frame for the queue-level cases: a byte-counted payload with the
 * wire topic it carries and, when a newer frame of the same state can replace
 * it, that state's coalescing key (a `session.summary`). */
function queuedFrame(encoded: string, topic = "test.frame", key?: string): OutboundFrame {
  return { encoded, bytes: Buffer.byteLength(encoded, "utf8"), topic, ...(key === undefined ? {} : { key }) };
}

/** One sequenced session frame for the queue-level cases, optionally with the
 * gap-tolerant replacement a superseding snapshot has to carry. */
function sequencedFrame(
  encoded: string,
  sessionId: string,
  sequence: number,
  topic = "session.snapshot",
  rebaseline?: () => OutboundFrame | undefined,
): OutboundFrame {
  return {
    encoded, bytes: Buffer.byteLength(encoded, "utf8"), topic, sessionId, sequence,
    ...(rebaseline === undefined ? {} : { rebaseline }),
  };
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

    expect(queue.enqueue(queuedFrame("a".repeat(600)))).toBe(true);
    expect(queue.enqueue(queuedFrame("b".repeat(500)))).toBe(false);
    expect(queue.enqueue(queuedFrame("c"))).toBe(false);
    expect(writes).toEqual(["a".repeat(600)]);
    expect(overflow).toHaveBeenCalledTimes(1);
    expect(overflow.mock.calls[0]?.[0]).toMatchObject({ queuedFrames: 1, queuedBytes: 600, writeActive: true, oldestTopic: "test.frame" });
    expect(overflow.mock.calls[0]?.[1]).toBe(500);
    expect(overflow.mock.calls[0]?.[2]).toBe("test.frame");
    expect(writeFailed).not.toHaveBeenCalled();
  });

  it("releases completed payloads with their byte reservations while the writer stays busy", () => {
    const completions: Array<(error?: Error) => void> = [];
    const queue = new OrderedOutboundQueue(4_096, (_encoded, done) => { completions.push(done); }, vi.fn(), vi.fn());
    expect(queue.enqueue(queuedFrame("a".repeat(1_024)))).toBe(true);
    expect(queue.enqueue(queuedFrame("b".repeat(1_024)))).toBe(true);
    // The independent oracle measures actual retained payloads, not the very
    // byte counter whose reservation used to be released prematurely.
    const retained = queue as unknown as { frames: Array<{ encoded: string } | undefined> };
    for (let index = 0; index < 2_050; index += 1) {
      completions.shift()!();
      expect(queue.enqueue(queuedFrame(String(index).padEnd(1_024, "x")))).toBe(true);
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
    for (let index = 0; index < 4_096; index += 1) expect(queue.enqueue(queuedFrame("{}"))).toBe(true);
    expect(queue.enqueue(queuedFrame("{}"))).toBe(false);
    expect(queue.enqueue(queuedFrame("{}"))).toBe(false);
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

    expect(queue.enqueue(queuedFrame("first"))).toBe(true);
    expect(queue.enqueue(queuedFrame("second"))).toBe(true);
    completion?.(new Error("socket write failed"));
    completion?.(new Error("duplicate callback"));
    expect(writeFailed).toHaveBeenCalledTimes(1);
    expect(writeFailed.mock.calls[0]?.[0]).toMatchObject({ message: "socket write failed" });
    expect(queue.enqueue(queuedFrame("third"))).toBe(false);
    expect(overflow).not.toHaveBeenCalled();
  });

  // G-4 failure modes, queue level: a superseded frame that is already being
  // written cannot be recalled; a replacement larger than the remaining budget
  // must not evict the state it supersedes on its way to the backstop; and
  // replacement must not disturb the order of frames with other keys.
  it("replaces the newest unsent summary and never the frame being written", () => {
    const writes: string[] = [];
    const completions: Array<(error?: Error) => void> = [];
    const overflow = vi.fn();
    const coalesced = vi.fn();
    const queue = new OrderedOutboundQueue(
      4_096,
      (encoded, done) => { writes.push(encoded); completions.push(done); },
      overflow,
      vi.fn(),
      vi.fn(),
      coalesced,
    );

    // Written and still in flight: it is past recall.
    expect(queue.enqueue(queuedFrame("in-flight", "session.summary", "session.summary:s1"))).toBe(true);
    // Unsent state, then a frame with another key, then two supersessions of it.
    expect(queue.enqueue(queuedFrame("old", "session.summary", "session.summary:s1"))).toBe(true);
    expect(queue.enqueue(queuedFrame("progress", "session.progress"))).toBe(true);
    expect(queue.enqueue(queuedFrame("newer", "session.summary", "session.summary:s1"))).toBe(true);
    expect(queue.enqueue(queuedFrame("newest", "session.summary", "session.summary:s1"))).toBe(true);

    expect(writes).toEqual(["in-flight"]);
    // Five enqueues, two of them superseded before they were written: the
    // counters describe the frames this connection still owes its peer.
    expect(queue.snapshot()).toMatchObject({ queuedFrames: 3, acceptedFrames: 3, writeActive: true, oldestTopic: "session.summary" });
    expect(queue.snapshot().queuedBytes).toBe(Buffer.byteLength("in-flight") + Buffer.byteLength("progress") + Buffer.byteLength("newest"));
    expect(coalesced.mock.calls.map((call) => call[0])).toEqual([Buffer.byteLength("old"), Buffer.byteLength("newer")]);
    expect(overflow).not.toHaveBeenCalled();

    // What is delivered is a subsequence of what was enqueued: the superseded
    // frames are gone and the survivor keeps its own place behind them.
    completions.shift()!();
    expect(writes).toEqual(["in-flight", "progress"]);
    completions.shift()!();
    expect(writes).toEqual(["in-flight", "progress", "newest"]);
    completions.shift()!();
    expect(queue.snapshot()).toMatchObject({ queuedFrames: 0, queuedBytes: 0 });
  });

  it("supersedes every unsent sequenced frame a session snapshot covers, and only with a rebaseline", () => {
    const writes: string[] = [];
    const completions: Array<(error?: Error) => void> = [];
    const overflow = vi.fn();
    const coalesced = vi.fn();
    const queue = new OrderedOutboundQueue(
      4_096,
      (encoded, done) => { writes.push(encoded); completions.push(done); },
      overflow,
      vi.fn(),
      vi.fn(),
      coalesced,
    );

    // In flight, past recall; then this session's unsent state, another
    // session's state, and a frame with no sequence at all.
    expect(queue.enqueue(sequencedFrame("in-flight", "s1", 1))).toBe(true);
    expect(queue.enqueue(sequencedFrame("progress", "s1", 2, "session.progress"))).toBe(true);
    expect(queue.enqueue(sequencedFrame("other", "s2", 2))).toBe(true);
    expect(queue.enqueue(sequencedFrame("activity", "s1", 3, "session.processActivity"))).toBe(true);
    expect(queue.enqueue(queuedFrame("notice"))).toBe(true);
    // A sequenced frame with no replacement supersedes nothing: dropping its
    // session's predecessors would leave the client a sequence it cannot accept.
    expect(queue.enqueue(sequencedFrame("plain", "s1", 4))).toBe(true);
    expect(queue.snapshot()).toMatchObject({ queuedFrames: 6, acceptedFrames: 6 });
    expect(coalesced).not.toHaveBeenCalled();

    const rebaseline = sequencedFrame("rebaseline", "s1", 5, "session.rebaseline");
    expect(queue.enqueue(sequencedFrame("newest", "s1", 5, "session.snapshot", () => rebaseline))).toBe(true);
    // Only this session's frames up to the surviving sequence are gone; the
    // replacement is what the client is handed, in the position the survivor
    // was enqueued in.
    expect(queue.snapshot()).toMatchObject({ queuedFrames: 4, acceptedFrames: 4, oldestTopic: "session.snapshot" });
    expect(coalesced.mock.calls.map((call) => call[0])).toEqual([
      Buffer.byteLength("progress"), Buffer.byteLength("activity"), Buffer.byteLength("plain"),
    ]);
    completions.shift()!();
    completions.shift()!();
    completions.shift()!();
    completions.shift()!();
    expect(writes).toEqual(["in-flight", "other", "notice", "rebaseline"]);
    expect(queue.snapshot()).toMatchObject({ queuedFrames: 0, queuedBytes: 0 });
    expect(overflow).not.toHaveBeenCalled();
  });

  it("accepts a replacement that fits the queue only because the state it supersedes is dropped", () => {
    const completions: Array<(error?: Error) => void> = [];
    const overflow = vi.fn();
    const queue = new OrderedOutboundQueue(1_000, (_encoded, done) => { completions.push(done); }, overflow, vi.fn());

    expect(queue.enqueue(queuedFrame("a".repeat(200)))).toBe(true); // in flight, past recall
    expect(queue.enqueue(queuedFrame("s".repeat(600), "session.summary", "session.summary:s1"))).toBe(true);
    expect(queue.enqueue(queuedFrame("p".repeat(100), "session.progress"))).toBe(true);
    expect(queue.snapshot()).toMatchObject({ queuedFrames: 3, queuedBytes: 900 });
    // A 200-byte sibling of 900 queued bytes exceeds the backstop unless the
    // 600 bytes it supersedes are dropped first.
    expect(queue.enqueue(queuedFrame("n".repeat(200), "session.summary", "session.summary:s1"))).toBe(true);
    expect(overflow).not.toHaveBeenCalled();
    expect(queue.snapshot()).toMatchObject({ queuedFrames: 3, queuedBytes: 500, maximumBytes: 1_000 });
    expect(completions.length).toBe(1);
  });

  it("keeps the backstop for a frame that supersedes nothing queued", () => {
    const overflow = vi.fn();
    const queue = new OrderedOutboundQueue(1_000, () => {}, overflow, vi.fn());

    expect(queue.enqueue(queuedFrame("a".repeat(200)))).toBe(true);
    expect(queue.enqueue(queuedFrame("s".repeat(600), "session.summary", "session.summary:s1"))).toBe(true);
    expect(queue.enqueue(queuedFrame("p".repeat(100), "session.progress"))).toBe(true);
    // The same bytes as the coalescing case, but the new summary is another
    // session's: it replaces nothing, so the queue's 8 MiB-scale bound holds.
    expect(queue.enqueue(queuedFrame("n".repeat(200), "session.summary", "session.summary:s2"))).toBe(false);
    expect(overflow).toHaveBeenCalledTimes(1);
    expect(overflow.mock.calls[0]?.[2]).toBe("session.summary");
  });

  it("fails closed on a replacement larger than the queue", () => {
    const writes: string[] = [];
    const overflow = vi.fn();
    const queue = new OrderedOutboundQueue(1_000, (encoded) => { writes.push(encoded); }, overflow, vi.fn());

    expect(queue.enqueue(queuedFrame("old", "session.summary", "session.summary:s1"))).toBe(true);
    expect(queue.enqueue(queuedFrame("p".repeat(400), "session.progress"))).toBe(true);
    expect(queue.enqueue(queuedFrame("x".repeat(1_100), "session.summary", "session.summary:s1"))).toBe(false);
    expect(overflow).toHaveBeenCalledTimes(1);
    // The record names what the socket was waiting on and what could not fit.
    expect(overflow.mock.calls[0]?.[0]).toMatchObject({ queuedFrames: 2, queuedBytes: 403, oldestTopic: "session.summary", maximumBytes: 1_000 });
    expect(overflow.mock.calls[0]?.[1]).toBe(1_100);
    expect(overflow.mock.calls[0]?.[2]).toBe("session.summary");
    expect(queue.enqueue(queuedFrame("after"))).toBe(false);
  });

  // Paired clients negotiate permessage-deflate, so their frames finish
  // asynchronous compression before the write callback; order, completion and
  // byte accounting (uncompressed, as queued) must match the local path.
  it.each(["local", "paired"] as const)("delivers a real same-turn burst above the retired 2 MiB threshold in exact order to a %s client", async (credential) => {
    const root = await mkdtemp(join(tmpdir(), "tron-server-large-burst-"));
    const devices = new DeviceStore(root, "machine");
    await devices.initialize();
    const token = credential === "local"
      ? JSON.parse(await readFile(join(root, "gateway", "local-auth.json"), "utf8")).bearerToken
      : (await devices.pair((await devices.ensureEnrollment()).code, "Phone")).token;
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
        info: () => ({ gatewayVersion: "test", piVersion: "test", protocolVersion: 6, minProtocolVersion: 6, machineId: "machine", machineName: "test", capabilities: [] }),
        terminalBelongsToSession: () => false,
        releaseClient: vi.fn(),
        invoke: vi.fn(),
      } as any,
      logger: logger as any,
    });
    await gateway.listen();
    cleanups.push(async () => { await gateway.close(); });

    const socket = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${token}` } });
    const sequences: string[] = [];
    socket.on("message", (raw) => {
      const frame = JSON.parse(raw.toString());
      if (frame.topic?.startsWith("test.")) sequences.push(`${frame.topic}:${frame.payload.sequence}`);
    });
    await new Promise<void>((resolve) => socket.once("open", () => resolve()));
    expect(socket.extensions).toBe(credential === "local" ? "" : "permessage-deflate");
    socket.send(JSON.stringify({ type: "hello", protocolVersion: 6 }));
    await waitUntil(() => logger.log.mock.calls.some((call) => call[2]?.event === "connection.opened"));
    const connection = [...(gateway as any).clients.values()][0];
    await waitUntil(() => connection.outbound.snapshot().completedFrames === 1); // hello

    const prepareBroadcastFrame = vi.spyOn(gateway as any, "prepareBroadcastFrame");
    const sendOutcome = vi.spyOn(gateway as any, "sendOutcome");
    const payload = "x".repeat(512 * 1_024);
    const expected: string[] = [];
    for (let sequence = 1; sequence <= 6; sequence += 1) {
      // A small frame behind each large one must not overtake it while the
      // large frame is still being compressed.
      gateway.broadcast("test.large", { sequence, payload });
      gateway.broadcast("test.small", { sequence });
      expected.push(`test.large:${sequence}`, `test.small:${sequence}`);
    }
    const queuedBytes = prepareBroadcastFrame.mock.results
      .reduce((sum, result) => sum + (result.value as { outputBytes: number }).outputBytes, 0);
    expect(connection.outbound.snapshot()).toMatchObject({ acceptedFrames: 13, completedFrames: 1, byteHighWater: queuedBytes });
    await waitUntil(() => sequences.length === 12);
    expect(sequences).toEqual(expected);
    expect(prepareBroadcastFrame).toHaveBeenCalledTimes(12);
    const broadcastFrames = sendOutcome.mock.calls
      .filter(([, value]) => (value as { topic?: string })?.topic?.startsWith("test."))
      .map(([, , prepared]) => prepared);
    expect(broadcastFrames).toHaveLength(12);
    expect(broadcastFrames).toEqual(prepareBroadcastFrame.mock.results.map((result) => result.value));
    await waitUntil(() => connection.outbound.snapshot().completedFrames === 13);
    expect(connection.outbound.snapshot()).toMatchObject({ queuedFrames: 0, queuedBytes: 0, writeActive: false, byteHighWater: queuedBytes });
    expect(connection.lastWriteProgressAt).not.toBeNull();
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
        info: () => ({ protocolVersion: 6 }), invoke, releaseClient: vi.fn(),
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
      peer.send(JSON.stringify({ type: "hello", protocolVersion: 6 }));
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
    // The command finished; only its response was undeliverable. The log must
    // not report the accepted work itself as failed.
    const completion = () => logger.log.mock.calls.find((call) =>
      call[2]?.event === "rpc.completed" && call[2]?.method === "accepted-command");
    await bounded(waitUntil(() => completion() !== undefined), "accepted command completion log");
    expect(completion()?.[2]).toMatchObject({ outcome: "connectionClosed" });
    expect(completion()?.[1]).toContain("(connectionClosed)");
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
    socket.send(JSON.stringify({ type: "hello", protocolVersion: 6 }));
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
    target.send(JSON.stringify({ type: "hello", protocolVersion: 6 }));
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
      info: () => ({ gatewayVersion: "test", piVersion: "test", protocolVersion: 6, minProtocolVersion: 6, machineId: "machine", machineName: "test", capabilities: [] }),
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
    target.send(JSON.stringify({ type: "hello", protocolVersion: 6 }));
    local.send(JSON.stringify({ type: "hello", protocolVersion: 6 }));
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

  it.each([undefined, "mobile"])("admits the exact node ceiling and bounds node- and byte-oversized responses for role %s without disconnecting or leaking contents", async (clientRole) => {
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
    // 32,759 leaf values fill the response wrapper to exactly the 32,768-node
    // ceiling; one element more must be replaced.
    const maximumNodes = Array.from({ length: 4 }, (_, index) => Array(index === 3 ? 8_189 : 8_190).fill(0));
    expect(Buffer.byteLength(JSON.stringify(maximumNodes))).toBeLessThan(1_048_576);
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
        info: () => ({ gatewayVersion: "test", piVersion: "test", protocolVersion: 6, minProtocolVersion: 6,
          machineId: "machine", machineName: "test", capabilities: [] }),
        terminalBelongsToSession: () => false, releaseClient: vi.fn(),
        invoke: async (context: any, method: string, params: any) => {
          if (method === "session.open") {
            const syncToken = context.beginSynchronization(params.sessionId);
            context.establishSynchronization(params.sessionId, { runtimeGeneration: "generation", eventSequence: 1 });
            return { session: params.dense ? dense : { healthy: true }, syncToken, subscriptionToken: syncToken };
          }
          if (method === "session.sync") {
            context.completeSynchronization(params.sessionId, params.syncToken);
            return { synchronized: true };
          }
          if (method === "test.nodes") return maximumNodes;
          if (method === "test.bytes") return { transcript: "x".repeat(1_100_000) };
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
    socket.send(JSON.stringify({ type: "hello", protocolVersion: 6, clientRole }));
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
    const opened = frames.find(frame => frame.id === "open-small");
    expect(opened).toMatchObject({ ok: true, result: { session: { healthy: true } } });
    expect(subscriptions.has("session")).toBe(true);
    expect(socket.readyState).toBe(WebSocket.OPEN);

    // A response that is under the node ceiling but over the frame byte limit is
    // replaced by the same correlated error, and the connection stays usable.
    socket.send(JSON.stringify({ type: "request", id: "bytes", method: "test.bytes", params: {} }));
    await waitUntil(() => frames.some(frame => frame.id === "bytes"));
    expect(frames.find(frame => frame.id === "bytes")).toMatchObject({
      ok: false, error: { code: "response_too_large", retryable: false, details: { maximum: 1_048_576 } },
    });
    socket.send(JSON.stringify({ type: "request", id: "after-bytes", method: "test.small", params: {} }));
    await waitUntil(() => frames.some(frame => frame.id === "after-bytes"));
    expect(frames.find(frame => frame.id === "after-bytes")).toMatchObject({ ok: true, result: { healthy: true } });
    expect(socket.readyState).toBe(WebSocket.OPEN);

    // Exactly the native node ceiling is delivered unchanged; one node more is
    // the dense case above.
    socket.send(JSON.stringify({ type: "request", id: "ceiling", method: "test.nodes", params: {} }));
    await waitUntil(() => frames.some(frame => frame.id === "ceiling"));
    expect(frames.find(frame => frame.id === "ceiling"))
      .toEqual({ type: "response", id: "ceiling", ok: true, result: maximumNodes });

    // A session-scoped oversized snapshot keeps its session identity so the
    // client can route the resync hint, and leaks no producer content.
    socket.send(JSON.stringify({ type: "request", id: "open-small-sync", method: "session.sync",
      params: { sessionId: "session", syncToken: opened.result.syncToken } }));
    await waitUntil(() => frames.some(frame => frame.id === "open-small-sync"));
    gateway.broadcastSession("session", "session.snapshot", { transcript: "x".repeat(1_100_000) });
    await waitUntil(() => frames.some(frame => frame.topic === "transport.resyncRequired" && frame.sessionId === "session"));
    expect(frames.find(frame => frame.topic === "transport.resyncRequired" && frame.sessionId === "session")).toMatchObject({
      type: "event", topic: "transport.resyncRequired", sessionId: "session",
      payload: { reason: "oversized projection" },
    });
    expect(socket.readyState).toBe(WebSocket.OPEN);
  });

  it("delivers the config-admitted machine identity maxima in the hello frame", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-hello-identity-"));
    let gateway: GatewayServer | undefined;
    let socket: WebSocket | undefined;
    cleanups.push(async () => {
      if (socket && socket.readyState !== WebSocket.CLOSED) socket.terminate();
      if (gateway) await bounded(gateway.close(), "hello fixture disposal");
      await rm(root, { recursive: true, force: true });
    });
    const devices = new DeviceStore(root, "machine");
    await devices.initialize();
    const token = JSON.parse(await readFile(join(root, "gateway", "local-auth.json"), "utf8")).bearerToken;
    const port = await unusedPort();
    // The largest identity the Gateway config admits: machineId <= 256 bytes and
    // machineName <= 1,024 bytes.
    const info = {
      gatewayVersion: "test", piVersion: "test", protocolVersion: 6, minProtocolVersion: 6,
      machineId: "i".repeat(256), machineName: "n".repeat(1_024), capabilities: ["sessions.v1"],
    };
    gateway = new GatewayServer({
      host: "127.0.0.1", port, maxFrameBytes: 1_048_576, devices, uploads: {} as any,
      sessions: { unsubscribeClient: vi.fn() } as any,
      auth: { detachClient: vi.fn(), cancelOwner: vi.fn() } as any,
      service: { info: () => info, releaseClient: vi.fn() } as any,
      logger: { log: vi.fn() } as any,
    });
    await gateway.listen();
    socket = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${token}` } });
    const frames: any[] = [];
    socket.on("message", raw => frames.push(JSON.parse(raw.toString())));
    await bounded(new Promise<void>(resolve => socket!.once("open", resolve)), "hello socket open");
    socket.send(JSON.stringify({ type: "hello", protocolVersion: 6 }));
    await waitUntil(() => frames.some(frame => frame.type === "hello"));
    expect(frames.find(frame => frame.type === "hello")).toEqual({ type: "hello", ...info, connectionId: expect.any(String) });
  });

  // Failure modes (O-1 correlation key): a malformed diagnostics object rejects
  // the hello; an unsafe value reaches a record; a connection record lacks the
  // peer key; the hello's connectionId differs from the records'; a superseded
  // record carries the newcomer's key instead of the displaced connection's.
  it("keys every connection record to the peer's hello diagnostics and returns the connection ID", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-server-correlation-"));
    const sockets: WebSocket[] = [];
    let gateway: GatewayServer | undefined;
    cleanups.push(async () => {
      for (const socket of sockets) if (socket.readyState !== WebSocket.CLOSED) socket.terminate();
      await bounded(gateway?.close() ?? Promise.resolve(), "correlation fixture close");
      await rm(root, { recursive: true, force: true });
    });
    const devices = new DeviceStore(root, "machine");
    await devices.initialize();
    const phone = await devices.pair((await devices.ensureEnrollment()).code, "Phone");
    const port = await unusedPort();
    const logger = { log: vi.fn() };
    gateway = new GatewayServer({
      host: "127.0.0.1", port, maxFrameBytes: 16_384, maximumConnections: 8, maximumConnectionsPerIdentity: 2,
      devices, uploads: {} as any, sessions: { unsubscribeClient: vi.fn() } as any,
      auth: { detachClient: vi.fn(), cancelOwner: vi.fn() } as any,
      service: { info: () => ({ protocolVersion: 6 }), terminalBelongsToSession: () => false, releaseClient: vi.fn(), invoke: vi.fn() } as any,
      logger: logger as any,
    });
    await gateway.listen();
    const connect = async (label: string, diagnostics: unknown) => {
      const socket = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${phone.token}` } });
      sockets.push(socket);
      const frames: any[] = [];
      socket.on("message", (raw) => frames.push(JSON.parse(raw.toString())));
      socket.on("error", () => {});
      await bounded(new Promise<void>((resolve) => socket.once("open", () => resolve())), `${label} open`);
      socket.send(JSON.stringify({ type: "hello", protocolVersion: 6, clientRole: "mobile", diagnostics }));
      await bounded(waitUntil(() => frames.some((frame) => frame.type === "hello")), `${label} hello`);
      const connectionId = frames.find((frame) => frame.type === "hello").connectionId as string;
      expect(connectionId).toMatch(/^[0-9a-f-]{36}$/u);
      return { socket, connectionId };
    };
    const recordFor = (event: string, connectionId: string) => logger.log.mock.calls
      .find((call) => call[2]?.event === event && call[2]?.connectionId === connectionId)?.[2];
    const staleKey = { peerClientId: "client-A", peerAttemptId: "initial", peerEpoch: "1" };

    const stale = await connect("stale", { clientId: "client-A", attemptId: "initial", epoch: "1" });
    // Each invalid token is dropped on its own; the hello is still admitted.
    const invalid = await connect("invalid", { clientId: "c".repeat(65), attemptId: "loop/../x", epoch: "2" });
    const unkeyed = await connect("not an object", ["client-A"]);
    expect(recordFor("connection.opened", unkeyed.connectionId))
      .toEqual({ event: "connection.opened", source: "transport", connectionId: unkeyed.connectionId });
    expect(recordFor("connection.opened", stale.connectionId))
      .toEqual({ event: "connection.opened", source: "transport", connectionId: stale.connectionId, ...staleKey });
    expect(recordFor("connection.opened", invalid.connectionId))
      .toEqual({ event: "connection.opened", source: "transport", connectionId: invalid.connectionId, peerEpoch: "2" });

    // The third socket superseded the least recently active one: stale.
    await waitUntil(() => recordFor("connection.closed", stale.connectionId) !== undefined);
    expect(recordFor("connection.superseded", stale.connectionId))
      .toEqual({ event: "connection.superseded", source: "transport", connectionId: stale.connectionId, ...staleKey });
    expect(recordFor("connection.closed", stale.connectionId)).toMatchObject(staleKey);

    const writer = [...(gateway as any).clients.values()].find((client: any) => client.id === invalid.connectionId);
    vi.spyOn(writer.socket, "send").mockImplementation(((_data: unknown, callback: (error?: Error) => void) => {
      queueMicrotask(() => callback(new Error("fixture write failure")));
    }) as any);
    gateway.broadcast("test.event", { sequence: 1 });
    await waitUntil(() => recordFor("connection.write-error", invalid.connectionId) !== undefined);
    expect(recordFor("connection.write-error", invalid.connectionId)).toMatchObject({ peerEpoch: "2" });
    expect(recordFor("connection.write-error", invalid.connectionId)).not.toHaveProperty("peerClientId");
  });

  it.each([{ sessions: 1, peers: 1 }, { sessions: 4, peers: 4 }, { sessions: 16, peers: 16 }, { sessions: 16, peers: 32 }])(
    "drops superseded summaries without reordering or losing capacity across $sessions sessions / $peers peers", async ({ sessions: sessionCount, peers: peerCount }) => {
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
        service: { info: () => ({ protocolVersion: 6 }), releaseClient: vi.fn(), invoke: async () => ({ ready: true }) } as any,
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
            if (frame.type === "hello" && frame.protocolVersion === 6) ready();
            if (frame.topic === "session.summary") {
              if (events.length >= 128) { socket.terminate(); return; }
              events.push([frame.payload.sessionId, frame.payload.summaryRevision]);
            }
            if (frame.type === "response" && frame.id === "fence" && frame.ok) fenced();
          });
          socket.on("error", () => {});
          await bounded(new Promise<void>(resolve => socket.once("open", resolve)), "fanout socket open");
          socket.send(JSON.stringify({ type: "hello", protocolVersion: 6, clientRole: "mobile" }));
          await bounded(hello, "fanout hello");
          return { socket, events, fence };
        }));
        const broadcast: Array<[string, number]> = [];
        for (let revision = 1; revision <= 8; revision++) {
          for (let session = 0; session < sessionCount; session++) {
            const sessionId = `fixture-session-${session}`;
            broadcast.push([sessionId, revision]);
            gateway.broadcast("session.summary", { sessionId, summaryRevision: revision, phase: "idle" });
          }
        }
        // A real response follows every already-enqueued global summary on
        // each socket. It proves ordering/drain without a timing sleep.
        for (const client of clients) client.socket.send(JSON.stringify({ type: "request", id: "fence", method: "test.fence", params: {} }));
        await bounded(Promise.all(clients.map(client => client.fence)), "fanout fences");
        for (const client of clients) {
          // G-4: a frame whose state a newer frame replaces is dropped unsent,
          // so what a client receives is the broadcast order with superseded
          // revisions removed — never reordered, and never a revision behind
          // one it already saw for that session.
          const revisionsBySession = new Map<string, number>();
          let cursor = 0;
          for (const [sessionId, revision] of client.events) {
            const at = broadcast.findIndex((entry, index) => index >= cursor && entry[0] === sessionId && entry[1] === revision);
            expect(at, `${sessionId}@${revision} did not follow the frames before it in broadcast order`).toBeGreaterThanOrEqual(0);
            cursor = at + 1;
            const seen = revisionsBySession.get(sessionId) ?? 0;
            expect(revision, `${sessionId} went backwards to revision ${revision}`).toBeGreaterThan(seen);
            revisionsBySession.set(sessionId, revision);
          }
          // The last broadcast frame of a session can only be superseded by a
          // later one, and there is none: every subscriber ends up current
          // however much of the middle the link dropped.
          expect([...revisionsBySession.keys()].sort()).toEqual(
            Array.from({ length: sessionCount }, (_, index) => `fixture-session-${index}`).sort());
          expect([...revisionsBySession.values()]).toEqual(new Array(sessionCount).fill(8));
          expect(client.socket.readyState).toBe(WebSocket.OPEN);
        }
        const closed = Promise.all(physicalSockets.slice(physicalStart).map(socket => new Promise<void>(resolve => socket.once("close", resolve))));
        for (const client of clients) client.socket.close(1000);
        await bounded(closed, "fanout physical retirement");
      }
    },
  );

  // G-4: the queue a slow link fills is bounded by the state still worth
  // sending, not by how long the link took. These cases drive real broadcast
  // paths (superseding session snapshots and summaries) into a real connection
  // whose writes are held, which is the shape O-6b's bandwidth-cap case
  // produces: without coalescing the same bytes reach the connection's own
  // backstop (64 KiB in these fixtures) and the peer is closed for capacity.
  interface StalledConnection {
    deliveryWindowBytes: number;
    outbound: OrderedOutboundQueue;
    socket: WebSocket;
    subscriptionTokens: Map<string, string>;
  }

  interface StalledLink {
    gateway: GatewayServer;
    socket: WebSocket;
    connection: StalledConnection;
    /** Every encoded frame this link was handed, in order. */
    held: Array<{ encoded: string; done: (error?: Error) => void }>;
    release: () => void;
    sampler: ResourceSampler;
  }

  /** The Gateway's live connections, which the transport owns privately. */
  const connections = (gateway: GatewayServer): StalledConnection[] =>
    [...(gateway as unknown as { clients: Map<string, StalledConnection> }).clients.values()];

  /** One delivered frame, decoded only for the fields these cases assert. */
  const delivered = (held: StalledLink["held"]): Array<{
    id?: string;
    topic: string;
    sessionId?: string;
    payload: {
      eventSequence?: number;
      subscriptionToken?: string;
      snapshot?: { sessionId: string; eventSequence: number; revision: number };
      sessionId?: string;
      summaryRevision?: number;
      data?: { activity?: { processId: string; marker: string }; removedProcessIds?: string[] };
    };
  }> => held.map((write) => JSON.parse(write.encoded));

  const stalledLink = async (maximumOutboundBytes: number, logger: { log: ReturnType<typeof vi.fn> }): Promise<StalledLink> => {
    const root = await mkdtemp(join(tmpdir(), "tron-server-coalesce-"));
    const devices = new DeviceStore(root, "machine");
    await devices.initialize();
    const token = JSON.parse(await readFile(join(root, "gateway", "local-auth.json"), "utf8")).bearerToken;
    const port = await unusedPort();
    const sampler = new ResourceSampler({
      readRuntimes: async () => [], durableWrites: () => ({ count: 0, ms: 0 }),
      memoryUsage: () => ({ heapUsed: 1_024, rss: 2_048 }), heapLimitBytes: () => 1_048_576,
      eventLoopDelay: () => ({ p50Ms: 0, p99Ms: 0, maxMs: 0 }),
    });
    const gateway = new GatewayServer({
      host: "127.0.0.1", port, maxFrameBytes: 512 * 1_024, maximumOutboundBytes,
      devices, uploads: {} as never, sessions: { unsubscribeClient: vi.fn() } as never,
      auth: { detachClient: vi.fn() } as never, service: {
        info: () => ({ protocolVersion: 6 }), releaseClient: vi.fn(),
        terminalBelongsToSession: () => false, invoke: async () => ({ ok: true }),
      } as never,
      logger: logger as never, resourceSampler: sampler,
    });
    await gateway.listen();
    const socket = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${token}` } });
    const frames: Array<{ type?: string }> = [];
    socket.on("message", (raw) => frames.push(JSON.parse(raw.toString())));
    socket.on("error", () => {});
    cleanups.push(async () => {
      if (socket.readyState !== WebSocket.CLOSED) socket.terminate();
      await bounded(gateway.close(), "coalescing fixture close");
      await rm(root, { recursive: true, force: true });
    });
    await bounded(new Promise<void>((resolve, reject) => {
      socket.once("open", () => resolve());
      socket.once("error", reject);
    }), "coalescing socket open");
    socket.send(JSON.stringify({ type: "hello", protocolVersion: 6 }));
    await bounded(waitUntil(() => frames.some((frame) => frame.type === "hello")), "coalescing hello");
    const connection = connections(gateway)[0]!;
    // These queue-coalescing cases isolate ordering/coverage from the separate
    // delivery-window liveness cases below.
    connection.deliveryWindowBytes = Number.MAX_SAFE_INTEGER;
    // Hold every application write: the link is as slow as the peer's socket
    // is, and the queue is where the Gateway's next frames wait.
    const held: StalledLink["held"] = [];
    vi.spyOn(connection.socket, "send").mockImplementation(((encoded: string, done?: (error?: Error) => void) => {
      held.push({ encoded, done: done ?? (() => {}) });
    }) as never);
    // Consume by index: each completion hands the next queued frame to the same
    // stub, so the array keeps every frame this link was handed, in order.
    const release = () => { for (let index = 0; index < held.length; index += 1) held[index]!.done(); };
    return { gateway, socket, connection, held, release, sampler };
  };

  it("bounds unacknowledged stream bytes and delivers control responses ahead of coalesced state", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-delivery-window-"));
    const devices = new DeviceStore(root, "machine");
    await devices.initialize();
    const token = JSON.parse(await readFile(join(root, "gateway", "local-auth.json"), "utf8")).bearerToken;
    const port = await unusedPort();
    const logger = { log: vi.fn() };
    const gateway = new GatewayServer({
      host: "127.0.0.1", port, maxFrameBytes: 512 * 1_024, maximumOutboundBytes: 2 * 1_048_576,
      devices, uploads: {} as never, sessions: { unsubscribeClient: vi.fn() } as never,
      auth: { detachClient: vi.fn() } as never, service: {
        info: () => ({ protocolVersion: 6 }), releaseClient: vi.fn(),
        terminalBelongsToSession: () => false, invoke: async () => ({ pong: true }),
      } as never,
      logger: logger as never,
    });
    await gateway.listen();
    const socket = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${token}` } });
    type WireFrame = { type?: string; id?: string; topic?: string; payload?: { snapshot?: { eventSequence?: number } } };
    const received: WireFrame[] = [];
    let deliveryPings = 0;
    let applicationPongAt: number | null = null;
    socket.on("message", (raw) => received.push(JSON.parse(raw.toString())));
    socket.on("ping", () => { deliveryPings += 1; });
    socket.on("pong", (payload) => {
      if (payload.toString() === "application-ping") applicationPongAt = Date.now();
    });
    socket.on("error", () => {});
    cleanups.push(async () => {
      if (socket.readyState !== WebSocket.CLOSED) socket.terminate();
      await bounded(gateway.close(), "delivery-window fixture close");
      await rm(root, { recursive: true, force: true });
    });
    await bounded(new Promise<void>((resolve, reject) => {
      socket.once("open", resolve);
      socket.once("error", reject);
    }), "delivery-window socket open");
    socket.send(JSON.stringify({ type: "hello", protocolVersion: 6 }));
    await bounded(waitUntil(() => received.some((frame) => frame.type === "hello")), "delivery-window hello");

    const connection = connections(gateway)[0]! as StalledConnection & {
      deliveryWindowBytes: number;
      deliveryUnacknowledgedBytes: number;
      deliveryPingSentAt: number | null;
      outbound: OrderedOutboundQueue & { resume(): void };
    };
    const reader = (socket as unknown as { _socket: import("node:net").Socket })._socket;
    reader.pause();
    const drainTimer = setInterval(() => {
      reader.resume();
      setTimeout(() => reader.pause(), 15);
    }, 100);
    cleanups.push(async () => clearInterval(drainTimer));

    connection.subscriptionTokens.set("stream-session", "token");
    const snapshot = (eventSequence: number) => ({
      runtimeGeneration: "generation", eventSequence, revision: eventSequence, data: "s".repeat(24 * 1_024),
    });
    gateway.broadcastSession("stream-session", "session.snapshot", snapshot(1));
    for (let sequence = 2; sequence <= 12; sequence += 1) {
      gateway.broadcastSession("stream-session", "session.snapshot", snapshot(sequence));
    }
    await waitUntil(() => connection.deliveryPingSentAt !== null
      && connection.deliveryPingSentAt !== undefined);
    expect(connection.deliveryUnacknowledgedBytes).toBeLessThanOrEqual(connection.deliveryWindowBytes + 24 * 1_024 + 512);
    expect(connection.outbound.snapshot().queuedFrames).toBeGreaterThan(0);
    const sentAt = Date.now();
    socket.ping(Buffer.from("application-ping"));
    socket.send(JSON.stringify({ type: "request", id: "priority-pong", method: "test.ping", params: {} }));
    await bounded(waitUntil(() => applicationPongAt !== null), "application ping response behind stream");
    expect(applicationPongAt! - sentAt).toBeLessThan(1_000);
    await bounded(waitUntil(() => received.some((frame) => frame.type === "response" && frame.id === "priority-pong")), "priority response behind stream");
    expect(Date.now() - sentAt).toBeLessThan(1_000);
    await bounded(waitUntil(() => received.some((frame) => frame.topic === "session.rebaseline")), "coalesced stream rebaseline");
    expect(Date.now() - sentAt).toBeLessThan(1_000);
    const survivor = received.find((frame) => frame.topic === "session.rebaseline");
    expect(survivor?.payload?.snapshot?.eventSequence).toBe(12);
    expect(received.findIndex((frame) => frame.type === "response" && frame.id === "priority-pong"))
      .toBeLessThan(received.findIndex((frame) => frame.topic === "session.rebaseline"));
    expect(deliveryPings).toBeGreaterThan(0);
    expect(connection.deliveryWindowBytes).toBe(32 * 1_024);
    expect(socket.readyState).toBe(WebSocket.OPEN);
  });

  it("keeps unthrottled delivery throughput close to the window gate being disabled", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-window-throughput-"));
    const devices = new DeviceStore(root, "machine");
    await devices.initialize();
    const token = JSON.parse(await readFile(join(root, "gateway", "local-auth.json"), "utf8")).bearerToken;
    const port = await unusedPort();
    const gateway = new GatewayServer({
      host: "127.0.0.1", port, maxFrameBytes: 512 * 1_024,
      devices, uploads: {} as never, sessions: { unsubscribeClient: vi.fn() } as never,
      auth: { detachClient: vi.fn() } as never, service: {
        info: () => ({ protocolVersion: 6 }), releaseClient: vi.fn(),
        terminalBelongsToSession: () => false, invoke: async () => ({ ok: true }),
      } as never,
      logger: { log: vi.fn() } as never,
    });
    await gateway.listen();
    const open = async () => {
      const socket = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${token}` } });
      let bytes = 0;
      let hello = false;
      socket.on("message", (raw) => {
        bytes += Buffer.byteLength(raw.toString());
        if (JSON.parse(raw.toString()).type === "hello") hello = true;
      });
      socket.on("error", () => {});
      await bounded(new Promise<void>((resolve, reject) => {
        socket.once("open", resolve);
        socket.once("error", reject);
      }), "throughput socket open");
      socket.send(JSON.stringify({ type: "hello", protocolVersion: 6 }));
      await bounded(waitUntil(() => socket.readyState === WebSocket.OPEN
        && connections(gateway).length >= 1), "throughput connection admission");
      return { socket, get bytes() { return bytes; }, get hello() { return hello; } };
    };
    const gated = await open();
    const ungated = await open();
    cleanups.push(async () => {
      for (const socket of [gated.socket, ungated.socket]) if (socket.readyState !== WebSocket.CLOSED) socket.terminate();
      await bounded(gateway.close(), "throughput fixture close");
      await rm(root, { recursive: true, force: true });
    });
    await bounded(waitUntil(() => connections(gateway).length === 2 && gated.hello && ungated.hello), "throughput hello frames");
    const live = connections(gateway);
    const [gatedConnection, ungatedConnection] = live;
    ungatedConnection.deliveryWindowBytes = Number.MAX_SAFE_INTEGER;
    gatedConnection.subscriptionTokens.set("throughput-gated", "token");
    ungatedConnection.subscriptionTokens.set("throughput-ungated", "token");
    let sequence = 0;
    const ticker = setInterval(() => {
      for (const sessionId of ["throughput-gated", "throughput-ungated"]) {
        sequence += 1;
        gateway.broadcastSession(sessionId, "session.progress", {
          runtimeGeneration: "generation", eventSequence: sequence, revision: sequence, data: "x".repeat(1_024),
        });
      }
    }, 10);
    cleanups.push(async () => clearInterval(ticker));
    await new Promise((resolve) => setTimeout(resolve, 2_000));
    const firstTwoSeconds = { gated: gated.bytes, ungated: ungated.bytes };
    await new Promise((resolve) => setTimeout(resolve, 2_000));
    clearInterval(ticker);
    await bounded(waitUntil(() => gatedConnection.outbound.snapshot().queuedFrames === 0
      && ungatedConnection.outbound.snapshot().queuedFrames === 0), "throughput queues drain");
    const total = { gated: gated.bytes, ungated: ungated.bytes };
    expect(firstTwoSeconds.ungated).toBeGreaterThan(0);
    expect(total.ungated).toBeGreaterThan(firstTwoSeconds.ungated);
    expect(firstTwoSeconds.gated).toBeGreaterThanOrEqual(firstTwoSeconds.ungated * 0.8);
    expect(total.gated).toBeGreaterThanOrEqual(total.ungated * 0.8);
  });

  it("replaces superseded session state with one rebaseline the client can admit", async () => {
    const logger = { log: vi.fn() };
    const maximumOutboundBytes = 64 * 1_024;
    const { gateway, socket, connection, release, sampler, held } = await stalledLink(maximumOutboundBytes, logger);
    connection.subscriptionTokens.set("coalesce-session", "token");
    const snapshot = (eventSequence: number) => ({
      runtimeGeneration: "generation", eventSequence, revision: eventSequence, data: "x".repeat(24 * 1_024),
    });
    const activity = (eventSequence: number, processId: string) => ({
      runtimeGeneration: "generation", eventSequence, revision: eventSequence,
      data: { activity: { processId, marker: `${processId}-v1` }, processRevision: eventSequence, overview: {} },
    });

    gateway.broadcastSession("coalesce-session", "session.snapshot", snapshot(1));
    gateway.broadcastSession("coalesce-session", "session.progress", { runtimeGeneration: "generation", eventSequence: 2, data: {} });
    gateway.broadcastSession("coalesce-session", "session.processActivity", activity(3, "p1"));
    for (let eventSequence = 4; eventSequence <= 8; eventSequence += 1) {
      gateway.broadcastSession("coalesce-session", "session.snapshot", snapshot(eventSequence));
    }
    // Seven 24 KiB snapshots, a progress frame and an activity against a 64 KiB
    // backstop: without coalescing the fourth snapshot would close this peer for
    // capacity. The in-flight snapshot stays, and the newest state survives as
    // the one frame that carries every sequence the queue dropped with it.
    const afterBroadcasts = connection.outbound.snapshot();
    expect(afterBroadcasts).toMatchObject({ queuedFrames: 2, acceptedFrames: 3, completedFrames: 1, oldestTopic: "session.snapshot" });
    expect(afterBroadcasts.queuedBytes).toBeLessThanOrEqual(maximumOutboundBytes);
    expect(socket.readyState).toBe(WebSocket.OPEN);
    expect(logger.log.mock.calls.some((call) => call[2]?.event === "connection.outbound-capacity")).toBe(false);

    release();
    await bounded(waitUntil(() => connection.outbound.snapshot().queuedFrames === 0), "coalesced frame drain");
    expect(held).toHaveLength(2);
    const [first, survivor] = delivered(held);
    // The frame the socket was already writing is never recalled.
    expect(first).toMatchObject({ topic: "session.snapshot", sessionId: "coalesce-session" });
    expect(first!.payload.eventSequence).toBe(1);
    // The survivor is the gap-tolerant form, carrying the subscription
    // credential the phone installed: the sequences the queue dropped arrive
    // covered instead of as a gap the phone has to resynchronize.
    expect(survivor).toMatchObject({ topic: "session.rebaseline", sessionId: "coalesce-session" });
    expect(survivor!.payload.subscriptionToken).toBe("token");
    expect(survivor!.payload.snapshot).toMatchObject({ eventSequence: 8, revision: 8 });
    expect(socket.readyState).toBe(WebSocket.OPEN);
    const sample = await sampler.sample();
    // The progress frame, the activity and four superseded rebaselines: 6 frames.
    expect(sample).toMatchObject({ outboundCoalescedFrames: 6, snapshotBuilds: 6 });
    expect(sample.outboundCoalescedBytes).toBeGreaterThan(4 * Buffer.byteLength(JSON.stringify(snapshot(8))));
  });

  it("keeps a one-shot receipt and everything behind it when its snapshot covers the run after it", async () => {
    const logger = { log: vi.fn() };
    const maximumOutboundBytes = 64 * 1_024;
    const { gateway, socket, connection, release, sampler, held } = await stalledLink(maximumOutboundBytes, logger);
    connection.subscriptionTokens.set("fenced-session", "token");
    const snapshot = (eventSequence: number) => ({
      runtimeGeneration: "generation", eventSequence, revision: eventSequence, data: "x".repeat(24 * 1_024),
    });
    const progress = (eventSequence: number) => ({
      runtimeGeneration: "generation", eventSequence, revision: eventSequence, data: {},
    });
    // Close the hello frame into its own window, so the sample below covers
    // exactly the broadcasts this case measures.
    await sampler.sample();

    gateway.broadcastSession("fenced-session", "session.snapshot", snapshot(1));
    gateway.broadcastSession("fenced-session", "session.progress", progress(2));
    // The failure receipt the phone turns into a restored draft and a retired
    // submission. No snapshot installation does that, so nothing may drop it
    // or the frames behind it.
    gateway.broadcastSession("fenced-session", "session.operationFailed", {
      runtimeGeneration: "generation", eventSequence: 3, revision: 3,
      data: { message: "the submission failed", operationId: "operation-1" },
    });
    gateway.broadcastSession("fenced-session", "session.progress", progress(4));
    gateway.broadcastSession("fenced-session", "session.snapshot", snapshot(5));

    expect(connection.outbound.snapshot()).toMatchObject({ queuedFrames: 4, oldestTopic: "session.snapshot" });
    expect(socket.readyState).toBe(WebSocket.OPEN);
    expect(logger.log.mock.calls.some((call) => call[2]?.event === "connection.outbound-capacity")).toBe(false);

    release();
    await bounded(waitUntil(() => connection.outbound.snapshot().queuedFrames === 0), "fenced frame drain");
    const frames = delivered(held);
    // Nothing is lost and nothing overtakes: the receipt and the frame before
    // it are delivered where they were enqueued, and the rebaseline covers the
    // sequence the queue dropped after the receipt instead of the receipt.
    expect(frames.map((frame) => frame.topic === "session.rebaseline"
      ? `rebaseline:${frame.payload.snapshot?.eventSequence}`
      : `${frame.topic}:${frame.payload.eventSequence}`)).toEqual([
      "session.snapshot:1",
      "session.progress:2",
      "session.operationFailed:3",
      "rebaseline:5",
    ]);
    expect(JSON.parse(held[2]!.encoded).payload.data.message).toBe("the submission failed");
    expect(frames[3]!.payload.subscriptionToken).toBe("token");
    expect(frames[3]!.payload.snapshot).toMatchObject({ eventSequence: 5 });
    // Accepted bytes are the frames this queue queued, the rebaseline included:
    // what it accepted minus what it coalesced is exactly what it handed to the
    // socket. The hello frame closed in its own window before the broadcasts.
    const sample = await sampler.sample();
    expect(sample.outboundCoalescedFrames).toBe(1);
    const handedToSocket = held.reduce((total, write) => total + Buffer.byteLength(write.encoded), 0);
    expect(sample.outboundBytes - sample.outboundCoalescedBytes).toBe(handedToSocket);
  });

  it("supersedes only the frames of the surviving snapshot's own runtime generation", async () => {
    const logger = { log: vi.fn() };
    const { gateway, socket, connection, release, held } = await stalledLink(64 * 1_024, logger);
    connection.subscriptionTokens.set("generation-session", "token");
    const state = (runtimeGeneration: string, eventSequence: number) => ({
      runtimeGeneration, eventSequence, revision: eventSequence, data: {},
    });

    gateway.broadcastSession("generation-session", "session.snapshot", state("generation-1", 1));
    gateway.broadcastSession("generation-session", "session.progress", state("generation-1", 2));
    gateway.broadcastSession("generation-session", "session.toolProgress", state("generation-1", 3));
    // A replacement RuntimeSlot restarts `eventSequence` at zero, so this
    // generation-2 snapshot's own sequence covers nothing of generation 1: the
    // frames the phone is still applying must arrive, in order, before it.
    gateway.broadcastSession("generation-session", "session.snapshot", state("generation-2", 4));

    release();
    await bounded(waitUntil(() => connection.outbound.snapshot().queuedFrames === 0), "generation frame drain");
    const described = delivered(held).map((frame) => frame.topic === "session.rebaseline"
      ? `rebaseline:${frame.payload.snapshot?.eventSequence}`
      : `${frame.topic}:${frame.payload.eventSequence}`);
    expect(described).toEqual([
      "session.snapshot:1",
      "session.progress:2",
      "session.toolProgress:3",
      "session.snapshot:4",
    ]);
    expect(socket.readyState).toBe(WebSocket.OPEN);
  });

  it("supersedes unsent summaries by key and delivers sequenced frames no snapshot covers", async () => {
    const logger = { log: vi.fn() };
    const { gateway, connection, release, sampler, held } = await stalledLink(64 * 1_024, logger);
    connection.subscriptionTokens.set("keyed-session", "token");
    const summary = (sessionId: string, summaryRevision: number) => ({ sessionId, summaryRevision, phase: "idle" });
    const activity = (eventSequence: number, processId: string) => ({
      runtimeGeneration: "generation", eventSequence, revision: eventSequence,
      data: { activity: { processId, marker: `${processId}-v1` }, processRevision: eventSequence, overview: {} },
    });

    gateway.broadcastSession("keyed-session", "session.progress", { runtimeGeneration: "generation", eventSequence: 2, data: {} });
    gateway.broadcast("session.summary", summary("summary-a", 1));
    gateway.broadcast("session.summary", summary("summary-b", 1));
    gateway.broadcastSession("keyed-session", "session.processActivity", activity(3, "p1"));
    gateway.broadcast("session.summary", summary("summary-a", 2));
    // One frame carries a tool call's removals beside its activity. It states no
    // key, and nothing may drop it while no snapshot covers its sequence.
    gateway.broadcastSession("keyed-session", "session.processActivity", {
      runtimeGeneration: "generation", eventSequence: 4, revision: 4,
      data: {
        activity: { processId: "p2", marker: "p2-v1" },
        removedProcessIds: ["gone-1", "gone-2"], processRevision: 4, overview: {},
      },
    });
    gateway.broadcast("session.summary", summary("summary-a", 3));

    release();
    await bounded(waitUntil(() => connection.outbound.snapshot().queuedFrames === 0), "keyed frame drain");
    // The revision of summary-a that was superseded while still unsent is gone;
    // every sequenced frame keeps its place, because nothing queued here covers
    // the sequences they carry.
    const described = delivered(held).map((frame) => {
      if (frame.topic === "session.summary") return `summary:${frame.payload.sessionId}:${frame.payload.summaryRevision}`;
      const data = frame.payload.data ?? {};
      if (data.removedProcessIds !== undefined) return `process-removal:${frame.topic}:${data.removedProcessIds.join(",")}`;
      if (data.activity !== undefined) return `process:${frame.topic}:${data.activity.marker}`;
      return `${frame.topic}:${frame.payload.eventSequence}`;
    });
    expect(described).toEqual([
      "session.progress:2",
      "summary:summary-b:1",
      "process:session.processActivity:p1-v1",
      "process-removal:session.processActivity:gone-1,gone-2",
      "summary:summary-a:3",
    ]);
    const sample = await sampler.sample();
    expect(sample.outboundCoalescedFrames).toBe(2);
    expect(sample.outboundCoalescedBytes).toBeGreaterThan(0);
  });

  it("still closes a stalled link whose queued state no newer frame supersedes", async () => {
    const logger = { log: vi.fn() };
    const maximumOutboundBytes = 64 * 1_024;
    const { gateway, socket, connection } = await stalledLink(maximumOutboundBytes, logger);
    const closed = new Promise<number>((resolve) => socket.once("close", (code) => resolve(code)));
    for (const sessionId of ["distinct-1", "distinct-2", "distinct-3"]) {
      connection.subscriptionTokens.set(sessionId, "token");
      gateway.broadcastSession(sessionId, "session.snapshot", {
        runtimeGeneration: "generation", eventSequence: 1, revision: 1, data: "x".repeat(24 * 1_024),
      });
    }
    // Three sessions' state is 72 KiB of the same bytes the coalescing case
    // dropped; nothing supersedes it, so the backstop closes the peer and the
    // record names the frame it was waiting on and the one that did not fit.
    await bounded(waitUntil(() => logger.log.mock.calls.some((call) => call[2]?.event === "connection.outbound-capacity")), "capacity record");
    const record = logger.log.mock.calls.find((call) => call[2]?.event === "connection.outbound-capacity");
    expect(record?.[1]).toMatch(/oldestTopic=session\.snapshot nextTopic=session\.snapshot nextBytes=\d+/u);
    expect(connection.closeInitiated).toBe(true);
    expect(await bounded(closed, "capacity close")).toBe(1013);
  });

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
        info: () => ({ protocolVersion: 6 }),
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
      socket.send(JSON.stringify({ type: "hello", protocolVersion: 6, clientRole: "mobile" }));
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
    // Superseding an identity's stale socket is not a capacity refusal.
    expect(logger.log.mock.calls.some((call) => call[2]?.reason === "connection_capacity")).toBe(false);
    replacement.socket.send(JSON.stringify({ type: "request", id: "usable", method: "test.usable", params: {} }));
    await bounded(waitUntil(() => replacement.frames.some((frame) => frame.id === "usable" && frame.ok)), "replacement request");
  });

  it("records a pre-hello socket the Gateway supersedes as the Gateway's ending", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-server-supersede-before-hello-"));
    const sockets: WebSocket[] = [];
    let gateway: GatewayServer | undefined;
    cleanups.push(async () => {
      for (const socket of sockets) if (socket.readyState !== WebSocket.CLOSED) socket.terminate();
      await bounded(gateway?.close() ?? Promise.resolve(), "supersede pre-hello fixture close");
      await rm(root, { recursive: true, force: true });
    });
    const devices = new DeviceStore(root, "machine");
    await devices.initialize();
    const phone = await devices.pair((await devices.ensureEnrollment()).code, "Phone");
    const port = await unusedPort();
    const logger = { log: vi.fn() };
    gateway = new GatewayServer({
      host: "127.0.0.1", port, maxFrameBytes: 16_384, maximumConnectionsPerIdentity: 1,
      devices, uploads: {} as any, sessions: { unsubscribeClient: vi.fn() } as any,
      auth: { detachClient: vi.fn(), cancelOwner: vi.fn() } as any,
      service: { info: () => ({ protocolVersion: 6 }), terminalBelongsToSession: () => false, releaseClient: vi.fn(), invoke: vi.fn() } as any,
      logger: logger as any,
    });
    await gateway.listen();
    const silent = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${phone.token}` } });
    sockets.push(silent);
    silent.on("error", () => {});
    await bounded(new Promise<void>((resolve) => silent.once("open", () => resolve())), "silent socket open");
    const closed = new Promise<number>((resolve) => silent.once("close", (code) => resolve(code)));
    // The newcomer takes the identity's only slot before either has said hello:
    // the Gateway ends the silent socket, so its record must not say the peer
    // left.
    const newcomer = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${phone.token}` } });
    sockets.push(newcomer);
    newcomer.on("error", () => {});
    await bounded(new Promise<void>((resolve) => newcomer.once("open", () => resolve())), "newcomer open");
    expect(await bounded(closed, "superseded pre-hello close")).toBe(SUPERSEDED_CLOSE_CODE);
    await bounded(waitUntil(() => logger.log.mock.calls.some((call) => call[2]?.event === "http.upgrade")), "superseded upgrade record");
    const record = logger.log.mock.calls.find((call) => call[2]?.event === "http.upgrade")!;
    expect(record[0]).toBe("warning");
    expect(record[2]).toMatchObject({ outcome: "abandoned", phaseReached: "handshake", reason: "superseded" });
    expect(record[1]).toContain("superseded by a newer connection");
  });

  it.each(["local", "paired"] as const)("admits same-turn ordered bursts, rejects connection overflow, and closes byte-oversized output for a %s client", async (credential) => {
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
      info: () => ({ gatewayVersion: "test", piVersion: "test", protocolVersion: 6, minProtocolVersion: 6, machineId: "machine", machineName: "test", capabilities: [] }),
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

    const [firstToken, otherToken] = credential === "local" ? [token, paired.token] : [paired.token, token];
    const first = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${firstToken}` } });
    const frames: any[] = [];
    first.on("message", (raw) => frames.push(JSON.parse(raw.toString())));
    await new Promise<void>((resolve) => first.once("open", () => resolve()));
    expect(first.extensions).toBe(credential === "local" ? "" : "permessage-deflate");
    first.send(JSON.stringify({ type: "hello", protocolVersion: 6, diagnostics: { clientId: "client-B", attemptId: "initial", epoch: "7" } }));
    await waitUntil(() => frames.some((frame) => frame.type === "hello"));

    // Global capacity never displaces another identity's live connection.
    const rejected = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${otherToken}` } });
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
      {
        event: "connection.outbound-capacity", source: "transport", connectionId: correlation,
        peerClientId: "client-B", peerAttemptId: "initial", peerEpoch: "7",
      },
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

  it("sheds a disposable read at its deadline, releases the subscription it committed, and never sheds an admitted mutation", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-server-deadline-shed-"));
    let gateway: GatewayServer | undefined;
    let socket: WebSocket | undefined;
    const gates = new Map<string, { promise: Promise<void>; release: () => void }>();
    cleanups.push(async () => {
      for (const gate of gates.values()) gate.release();
      if (socket && socket.readyState !== WebSocket.CLOSED) {
        const closed = new Promise<void>((resolve) => socket!.once("close", () => resolve()));
        socket.terminate();
        await bounded(closed, "shed socket disposal");
      }
      if (gateway) await bounded(gateway.close(), "shed fixture disposal");
      await rm(root, { recursive: true, force: true });
    });
    const devices = new DeviceStore(root, "machine");
    await devices.initialize();
    const token = JSON.parse(await readFile(join(root, "gateway", "local-auth.json"), "utf8")).bearerToken;
    const port = await unusedPort();
    const logger = { log: vi.fn() };
    const subscriptions = new Set<string>();
    // A held read is the load that made it slow: its deadline is what ends the
    // request, not the work behind it. The fixture cannot wait a production
    // bound, so the table is overridden the way the other named bounds are —
    // over the production table's own keys, so a read the Gateway deliberately
    // leaves out of it stays out of this case too.
    const held = (method: string): { promise: Promise<void>; release: () => void } => {
      const existing = gates.get(method);
      if (existing) return existing;
      let release = (): void => {};
      const entry = { promise: new Promise<void>((resolve) => { release = resolve; }), release: () => release() };
      gates.set(method, entry);
      return entry;
    };
    gateway = new GatewayServer({
      host: "127.0.0.1", port, maxFrameBytes: 1_048_576,
      devices, logger: logger as any, uploads: {} as any,
      disposableReadDeadlinesMs: new Map([...DISPOSABLE_READ_DEADLINES_MS.keys()].map((method) => [method, 80])),
      sessions: {
        subscribe: (_client: string, session: string) => subscriptions.add(session),
        unsubscribe: (_client: string, session: string) => subscriptions.delete(session),
        unsubscribeClient: () => subscriptions.clear(),
      } as any,
      auth: { detachClient: vi.fn(), cancelOwner: vi.fn() } as any,
      service: {
        info: () => ({ gatewayVersion: "test", piVersion: "test", protocolVersion: 6, minProtocolVersion: 6,
          machineId: "machine", machineName: "test", capabilities: [] }),
        terminalBelongsToSession: () => false, releaseClient: vi.fn(),
        invoke: async (context: any, method: string, params: any) => {
          const gate = held(method).promise;
          if (method === "session.open") {
            // The subscription commits before the response is written, so the
            // deadline fires with a committed barrier in place.
            const syncToken = context.beginSynchronization(params.sessionId);
            context.establishSynchronization(params.sessionId, { runtimeGeneration: "generation", eventSequence: 1 });
            await gate;
            return { session: { healthy: true }, syncToken, subscriptionToken: syncToken };
          }
          await gate;
          return { method };
        },
      } as any,
    });
    await gateway.listen();
    socket = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${token}` } });
    const frames: any[] = [];
    socket.on("message", (raw) => frames.push(JSON.parse(raw.toString())));
    await bounded(new Promise<void>((resolve) => socket!.once("open", () => resolve())), "shed socket open");
    socket.send(JSON.stringify({ type: "hello", protocolVersion: 6 }));
    await waitUntil(() => frames.some((frame) => frame.type === "hello"));

    // The open's subscription is committed while its response is still pending;
    // the deadline answers the request anyway and gives the barrier back.
    socket.send(JSON.stringify({ type: "request", id: "shed-open", method: "session.open", params: { sessionId: "session" } }));
    await waitUntil(() => frames.some((frame) => frame.id === "shed-open"));
    expect(frames.find((frame) => frame.id === "shed-open")).toMatchObject({
      ok: false, error: { code: "busy", retryable: true, details: { retryAfterMs: 1_000 } },
    });
    await waitUntil(() => subscriptions.size === 0);
    const shed = () => logger.log.mock.calls.find((call) => call[2]?.event === "gateway.shed" && call[2]?.method === "session.open");
    expect(shed()?.[2]).toMatchObject({ reason: "deadline", source: "transport", counts: { retryAfterMs: 1_000 } });
    expect(shed()?.[1]).toContain("Shed session.open");

    // The same deadline covers the projection reads, and a retry of the shed
    // open is answered normally: nothing it installed leaked.
    socket.send(JSON.stringify({ type: "request", id: "shed-list", method: "session.list", params: {} }));
    await waitUntil(() => frames.some((frame) => frame.id === "shed-list"));
    expect(frames.find((frame) => frame.id === "shed-list")).toMatchObject({
      ok: false, error: { code: "busy", details: { retryAfterMs: 1_000 } },
    });

    // An admitted mutation has no entry in the table: it is never shed, and its
    // response is the work's own answer.
    socket.send(JSON.stringify({ type: "request", id: "held-command", method: "accepted-command", params: {} }));
    // A read the table deliberately leaves out is never shed either: a
    // remote-ranked `session.search` spends up to Jev's 20 s on an evaluation the
    // user paid for, so shedding it would have the phone pay for it twice.
    socket.send(JSON.stringify({ type: "request", id: "held-search", method: "session.search", params: { query: "x", remoteRanking: true } }));
    // Longer than the deadline: a mutation that were in the table would have
    // been shed by now.
    await new Promise((resolve) => setTimeout(resolve, 300));
    expect(frames.some((frame) => frame.id === "held-command")).toBe(false);
    expect(frames.some((frame) => frame.id === "held-search")).toBe(false);
    expect(logger.log.mock.calls.some((call) => call[2]?.event === "gateway.shed" && call[2]?.method === "accepted-command")).toBe(false);
    expect(logger.log.mock.calls.some((call) => call[2]?.event === "gateway.shed" && call[2]?.method === "session.search")).toBe(false);
    gates.get("accepted-command")?.release();
    gates.get("session.search")?.release();
    await waitUntil(() => frames.some((frame) => frame.id === "held-command"));
    expect(frames.find((frame) => frame.id === "held-command")).toMatchObject({ ok: true, result: { method: "accepted-command" } });
    await waitUntil(() => frames.some((frame) => frame.id === "held-search"));
    expect(frames.find((frame) => frame.id === "held-search")).toMatchObject({ ok: true, result: { method: "session.search" } });

    gates.get("session.open")?.release();
    socket.send(JSON.stringify({ type: "request", id: "retry-open", method: "session.open", params: { sessionId: "session" } }));
    await waitUntil(() => frames.some((frame) => frame.id === "retry-open"));
    expect(frames.find((frame) => frame.id === "retry-open")).toMatchObject({ ok: true, result: { session: { healthy: true } } });
    expect(subscriptions.has("session")).toBe(true);
    expect(socket.readyState).toBe(WebSocket.OPEN);
  });
});
