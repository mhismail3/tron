import { createServer } from "node:http";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import WebSocket from "ws";
import { afterEach, describe, expect, it, vi } from "vitest";
import { DeviceStore } from "../security/device-store.js";
import { GatewayServer } from "./server.js";
import type { PeerPathLookup, PeerPathReader } from "./tailscale-peer.js";
import { waitFor } from "../../test-support/wait-for.js";

// Failure mode this file exists to catch (real loopback socket, real clock):
// the Gateway's pong to a client ping is written behind stream frames that are
// still queued in the OrderedOutboundQueue, not yet handed to the socket. A
// phone whose probe then waits behind the whole backlog misses its 8-second
// pong deadline on a healthy link (#700, #186). Frames already handed to the
// socket may legitimately precede the pong; frames still queued must not.

const NO_TAILSCALE_PATH: PeerPathReader = { lookup: async (): Promise<PeerPathLookup> => ({ peerPath: "unknown", peerRelay: "" }) };

const BACKLOG_TOPIC = "test.backlog";
const BACKLOG_FRAMES = 12;
const BACKLOG_PAD_BYTES = 256 * 1024;
const MINIMUM_PENDING_FRAMES = 4;

type OutboundInternals = {
  clients: Map<string, { ready: boolean; socket: WebSocket; outbound: { snapshot(): { queuedFrames: number; writeActive: boolean } } }>;
  send(connection: unknown, value: unknown): boolean;
};

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => {
  await Promise.all(cleanups.splice(0).map((cleanup) => cleanup()));
});

async function unusedPort(): Promise<number> {
  const probe = createServer();
  await new Promise<void>((resolve) => probe.listen(0, "127.0.0.1", resolve));
  const address = probe.address();
  if (!address || typeof address === "string") throw new Error("probe did not bind");
  await new Promise<void>((resolve) => probe.close(() => resolve()));
  return address.port;
}

/** Connects one local client, fills the Gateway's outbound queue while the
 * client stops reading, pings, then resumes reading and reports the order in
 * which the backlog frames and the pong arrived. */
async function pongAgainstBacklog(): Promise<{ backlogBeforePong: number; pendingAtPing: number }> {
  const root = await mkdtemp(join(tmpdir(), "tron-server-pong-backlog-"));
  const devices = new DeviceStore(root, "machine");
  await devices.initialize();
  const token = JSON.parse(await readFile(join(root, "gateway", "local-auth.json"), "utf8")).bearerToken;
  const port = await unusedPort();
  const logger = { log: vi.fn() };
  const gateway = new GatewayServer({
    host: "127.0.0.1", port, maxFrameBytes: BACKLOG_PAD_BYTES * 4, devices,
    uploads: {} as never,
    sessions: { unsubscribeClient: vi.fn() } as never,
    auth: { detachClient: vi.fn(), cancelOwner: vi.fn() } as never,
    service: {
      info: () => ({ protocolVersion: 7 }),
      terminalBelongsToSession: () => false,
      releaseClient: vi.fn(),
      invoke: vi.fn(),
    } as never,
    logger: logger as never,
    peerPathReader: NO_TAILSCALE_PATH,
  });
  await gateway.listen();
  const socket = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${token}` } });
  cleanups.push(async () => {
    socket.terminate();
    try { await gateway.close(); } finally { await rm(root, { recursive: true, force: true }); }
  });
  const internals = gateway as unknown as OutboundInternals;
  const connection = () => [...internals.clients.values()][0];

  const backlogTopicsInOrder: string[] = [];
  let backlogBeforePong: number | undefined;
  socket.on("message", (raw) => {
    const frame = JSON.parse(raw.toString());
    if (frame.topic === BACKLOG_TOPIC) backlogTopicsInOrder.push(frame.topic);
  });
  socket.on("pong", () => { backlogBeforePong = backlogTopicsInOrder.length; });
  await new Promise<void>((resolve, reject) => { socket.once("open", () => resolve()); socket.once("error", reject); });
  socket.send(JSON.stringify({ type: "hello", protocolVersion: 7, diagnostics: { clientId: "client-pong", attemptId: "initial", epoch: "1" } }));
  await waitFor(() => connection()?.ready === true, "hello");

  // Stop reading: the kernel buffers fill and the Gateway's writes stall, so
  // every later stream frame stays in the OrderedOutboundQueue.
  const transport = (socket as unknown as { _socket: { pause(): void; resume(): void } })._socket;
  transport.pause();
  const pad = "x".repeat(BACKLOG_PAD_BYTES);
  for (let index = 0; index < BACKLOG_FRAMES; index += 1) {
    internals.send(connection(), { type: "event", topic: BACKLOG_TOPIC, payload: { index, pad } });
  }
  const pendingBeforePing = () => {
    const snapshot = connection().outbound.snapshot();
    return snapshot.queuedFrames - (snapshot.writeActive ? 1 : 0);
  };
  await waitFor(() => pendingBeforePing() >= MINIMUM_PENDING_FRAMES, "queued backlog");

  // Sampled at the Gateway's own ping event, before ws writes the automatic
  // pong, so the count is the queue as the ping found it.
  let pendingAtPing: number | undefined;
  connection().socket.once("ping", () => { pendingAtPing = pendingBeforePing(); });
  socket.ping();
  await waitFor(() => pendingAtPing !== undefined, "gateway ping");
  transport.resume();
  await waitFor(() => backlogBeforePong !== undefined, "pong");
  await waitFor(() => backlogTopicsInOrder.length === BACKLOG_FRAMES, "full backlog");

  return { backlogBeforePong: backlogBeforePong ?? -1, pendingAtPing: pendingAtPing ?? -1 };
}

describe("Gateway pong against a queued stream backlog", () => {
  it("answers a client ping before frames still queued in the outbound queue", async () => {
    const { backlogBeforePong, pendingAtPing } = await pongAgainstBacklog();
    // Every backlog frame that was still queued when the ping arrived must come
    // after the pong: the pong may follow only the frames already handed to the
    // socket (the rest of the total minus the pending ones).
    expect(pendingAtPing).toBeGreaterThanOrEqual(MINIMUM_PENDING_FRAMES);
    expect(backlogBeforePong).toBeLessThanOrEqual(BACKLOG_FRAMES - pendingAtPing);
  });
});
