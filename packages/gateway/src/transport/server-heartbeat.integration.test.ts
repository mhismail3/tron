import { createServer } from "node:http";
import { connect, createServer as createTcpServer, type AddressInfo, type Socket } from "node:net";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import WebSocket from "ws";
import { afterEach, describe, expect, it, vi } from "vitest";
import { DeviceStore } from "../security/device-store.js";
import { GATEWAY_CONNECTION_POLICY } from "./connection-policy.js";
import { GatewayServer } from "./server.js";
import type { PeerPathLookup, PeerPathReader } from "./tailscale-peer.js";

// Failure modes this file exists to catch (real sockets, fake heartbeat clock):
// 1. Skipping pings delays dead-client retirement past today's fourth tick.
// 2. A pong suppresses the next ping, so a pong-only client is pinged only
//    every other tick and loses a third of its pong-latency tolerance.
// 3. A client that proves liveness with its own pings is still server-pinged
//    (the wakeup this rule removes) or, worse, is falsely retired.
// 4. A client that goes quiet is never pinged again and is retired while alive.
// 5. The retirement record cannot be joined to the phone's own records because
//    it lacks the connection ID or the peer's hello correlation key.
// 6. Inbound silence is reported every tick instead of once per episode, is
//    reported for a phone that pings every ten seconds, or is reported at all
//    for a healthy client that only answers the Gateway's own pings — including
//    when a skipped ping (the client spoke mid-interval) is miscounted as an
//    unanswered one.
// 7. A silence episode that ends before the Tailscale read settles loses its
//    resume record or its duration, or reports the resume before the silence.
// 8. A blackholed path (no bytes in either direction, socket still open) is not
//    visible as silence plus a resume in the Gateway log alone.

/** Tests never run the host's Tailscale CLI: the path is injected everywhere. */
const NO_TAILSCALE_PATH: PeerPathReader = { lookup: async (): Promise<PeerPathLookup> => ({ peerPath: "unknown", peerRelay: "" }) };

const INTERVAL_MS = GATEWAY_CONNECTION_POLICY.heartbeatIntervalMs;
const TICK_SECONDS = INTERVAL_MS / 1_000;
const ROUND_TRIP_MS = 100;

const PEER_DIAGNOSTICS = { clientId: "client-heartbeat", attemptId: "initial", epoch: "1" };

/** The latest run's Gateway log calls. */
let gatewayLog: ReturnType<typeof vi.fn> | undefined;

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => {
  try {
    await Promise.all(cleanups.splice(0).map((cleanup) => cleanup()));
  } finally {
    vi.useRealTimers();
    vi.restoreAllMocks();
  }
});

async function unusedPort(): Promise<number> {
  const probe = createServer();
  await new Promise<void>((resolve) => probe.listen(0, "127.0.0.1", resolve));
  const address = probe.address();
  if (!address || typeof address === "string") throw new Error("probe did not bind");
  await new Promise<void>((resolve) => probe.close(() => resolve()));
  return address.port;
}

async function realWait(predicate: () => boolean, label: string): Promise<void> {
  const deadline = Date.now() + 5_000;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error(`${label} timed out`);
    await new Promise((resolve) => setImmediate(resolve));
  }
}

interface ClientScript {
  /** Whether the client's WebSocket stack answers server pings. */
  autoPong: boolean;
  /** Virtual seconds at which the client sends its own ping. */
  pingsAt?: (second: number) => boolean;
}

interface HarnessOptions {
  /** The Tailscale path reader the transport uses; never the host's CLI. */
  peerPathReader?: PeerPathReader;
  /** Virtual seconds between which the client's path carries no bytes. */
  blackhole?: { from: number; to: number };
  /** Virtual seconds at which the client sends one application frame. */
  messagesAt?: (second: number) => boolean;
  /** Runs at the end of each virtual second, after that second's client ping. */
  afterSecond?: (second: number) => void;
}

interface HoldProxy {
  port: number;
  holding(): boolean;
  setHolding(value: boolean): void;
  close(): Promise<void>;
}

/** A path blackhole for the client's socket. Bytes are held and released in
 * order instead of dropped: dropping part of a WebSocket frame would
 * desynchronize the stream both ends share, while holding them looks exactly
 * like a Tailscale blackhole — nothing arrives in either direction and the
 * socket stays open. */
async function holdProxy(upstreamPort: number): Promise<HoldProxy> {
  let holding = false;
  const held: Array<() => void> = [];
  const sockets = new Set<Socket>();
  const server = createTcpServer((client) => {
    const upstream = connect({ host: "127.0.0.1", port: upstreamPort });
    sockets.add(client).add(upstream);
    client.on("error", () => upstream.destroy());
    upstream.on("error", () => client.destroy());
    client.on("close", () => upstream.destroy());
    upstream.on("close", () => client.destroy());
    const forward = (to: Socket) => (chunk: Buffer): void => {
      if (!holding) {
        to.write(chunk);
        return;
      }
      const copy = Buffer.from(chunk);
      held.push(() => to.write(copy));
    };
    client.on("data", forward(upstream));
    upstream.on("data", forward(client));
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return {
    port: (server.address() as AddressInfo).port,
    holding: () => holding,
    setHolding(value) {
      holding = value;
      if (!value) for (const flush of held.splice(0)) flush();
    },
    close: () => new Promise<void>((resolve) => {
      for (const socket of sockets) socket.destroy();
      server.close(() => resolve());
    }),
  };
}

interface TickObservation {
  tick: number;
  serverPings: number;
  closed: boolean;
}

/** Runs one client against a real Gateway socket for `ticks` heartbeat ticks
 * on a virtual clock that drives both the heartbeat interval and
 * `performance.now()`, and reports what the client observed after each tick. */
async function observeHeartbeats(script: ClientScript, ticks: number, options: HarnessOptions = {}): Promise<TickObservation[]> {
  let now = 1_000_000;
  vi.spyOn(performance, "now").mockImplementation(() => now);
  vi.useFakeTimers({ toFake: ["setInterval", "clearInterval"] });
  const root = await mkdtemp(join(tmpdir(), "tron-server-heartbeat-"));
  const devices = new DeviceStore(root, "machine");
  await devices.initialize();
  const token = JSON.parse(await readFile(join(root, "gateway", "local-auth.json"), "utf8")).bearerToken;
  const port = await unusedPort();
  const logger = { log: vi.fn() };
  gatewayLog = logger.log;
  const gateway = new GatewayServer({
    host: "127.0.0.1", port, maxFrameBytes: 16_384, devices,
    uploads: {} as never,
    sessions: { unsubscribeClient: vi.fn() } as never,
    auth: { detachClient: vi.fn(), cancelOwner: vi.fn() } as never,
    service: {
      info: () => ({ protocolVersion: 6 }),
      terminalBelongsToSession: () => false,
      releaseClient: vi.fn(),
      invoke: vi.fn(),
    } as never,
    logger: logger as never,
    peerPathReader: options.peerPathReader ?? NO_TAILSCALE_PATH,
  });
  await gateway.listen();
  const proxy = options.blackhole === undefined ? undefined : await holdProxy(port);
  if (proxy) cleanups.push(() => proxy.close());
  const socket = new WebSocket(`ws://127.0.0.1:${proxy?.port ?? port}/v1/socket`, {
    headers: { authorization: `Bearer ${token}` },
    autoPong: script.autoPong,
  });
  cleanups.push(async () => {
    socket.terminate();
    try { await gateway.close(); } finally { await rm(root, { recursive: true, force: true }); }
  });

  let serverPings = 0;
  let clientPongs = 0;
  let closed = false;
  let barrier = 0;
  socket.on("ping", () => { serverPings += 1; });
  socket.on("pong", () => { clientPongs += 1; });
  socket.on("close", () => { closed = true; });
  socket.on("message", (raw) => {
    const frame = JSON.parse(raw.toString());
    if (frame.topic === "test.barrier") barrier = frame.payload.sequence;
  });
  await new Promise<void>((resolve, reject) => { socket.once("open", () => resolve()); socket.once("error", reject); });
  // The hello is client-initiated inbound at virtual second 0.
  socket.send(JSON.stringify({ type: "hello", protocolVersion: 6, diagnostics: PEER_DIAGNOSTICS }));
  await realWait(() => logger.log.mock.calls.some((call) => call[2]?.event === "connection.opened"), "hello");
  const connection = () => [...(gateway as unknown as { clients: Map<string, { unansweredHeartbeats: number; lastClientInitiatedInboundAt: number | null }> }).clients.values()][0];

  const observations: TickObservation[] = [];
  const start = now;
  for (let second = 1; second <= ticks * TICK_SECONDS; second += 1) {
    now = start + second * 1_000;
    await vi.advanceTimersByTimeAsync(1_000);
    if (proxy !== undefined && options.blackhole !== undefined) {
      if (second === options.blackhole.from) proxy.setHolding(true);
      if (second === options.blackhole.to) proxy.setHolding(false);
    }
    const blackholed = proxy?.holding() === true;
    if (second % TICK_SECONDS === 0) {
      const tick = second / TICK_SECONDS;
      // Everything the client sends in reply to this tick arrives one round
      // trip after it, never on the tick's own instant.
      now += ROUND_TRIP_MS;
      if (!closed && !blackholed) {
        // An ordered application frame after the tick proves the client has
        // received any ping that tick wrote to the same socket, or the close.
        const sequence = tick;
        gateway.broadcast("test.barrier", { sequence });
        await realWait(() => barrier === sequence || closed, `tick ${tick} barrier`);
      }
      observations.push({ tick, serverPings, closed });
      // Let the Gateway observe an automatic pong before the next tick, as a
      // live peer's pong would arrive well within one interval.
      const pingedThisTick = serverPings > (observations.at(-2)?.serverPings ?? 0);
      if (!closed && !blackholed && script.autoPong && pingedThisTick) {
        await realWait(() => connection()?.unansweredHeartbeats === 0, `tick ${tick} pong`);
      }
    }
    if (!closed && script.pingsAt?.(second)) {
      const expected = clientPongs + 1;
      socket.ping();
      // The Gateway handles the ping in the same callback that answers it.
      await realWait(() => clientPongs === expected || closed, `second ${second} client ping`);
    }
    if (!closed && options.messagesAt?.(second) === true) {
      const before = connection()?.lastClientInitiatedInboundAt ?? null;
      // An application frame, not a ping: it makes the next tick skip its ping
      // without arming the client's own-ping liveness signal.
      socket.send(JSON.stringify({ type: "probe" }));
      await realWait(() => (connection()?.lastClientInitiatedInboundAt ?? null) !== before, `second ${second} client message`);
    }
    options.afterSecond?.(second);
  }
  return observations;
}

/** Ticks on which a new server ping reached the client. */
function pingedTicks(observations: TickObservation[]): number[] {
  return observations
    .filter((observation, index) => observation.serverPings > (observations[index - 1]?.serverPings ?? 0))
    .map((observation) => observation.tick);
}

function closedAtTick(observations: TickObservation[]): number | undefined {
  return observations.find((observation) => observation.closed)?.tick;
}

interface LoggedRecord {
  index: number;
  level: string;
  message: string;
  fields: Record<string, unknown>;
}

/** The run's log calls for one event, in the order the Gateway wrote them. */
function loggedRecords(event: string): LoggedRecord[] {
  const calls = gatewayLog?.mock.calls ?? [];
  return calls.flatMap((call, index) => call[2]?.event === event
    ? [{ index, level: call[0] as string, message: call[1] as string, fields: call[2] as Record<string, unknown> }]
    : []);
}

describe("Gateway heartbeat pings", () => {
  it("never pings or retires a phone that pings every ten seconds", async () => {
    const observations = await observeHeartbeats({ autoPong: true, pingsAt: (second) => second % 10 === 3 }, 8);
    expect(pingedTicks(observations)).toEqual([]);
    expect(closedAtTick(observations)).toBeUndefined();
    expect(loggedRecords("connection.inbound-silent")).toEqual([]);
  });

  it("pings a pong-only client on every tick, never retires it and never reports it silent", async () => {
    // A client that only answers the Gateway's pings is idle between them, not
    // cut off: its silence says nothing until a ping goes unanswered, and every
    // tick's ping is answered well inside the next interval. This is the phone
    // as C-4 leaves it — a receiver that answers pings and sends nothing else —
    // over 200 virtual seconds, well past the 60 s silence threshold: no
    // `connection.inbound-silent` record and no Tailscale lookup at all.
    const lookup = vi.fn(async (): Promise<PeerPathLookup> => ({ peerPath: "unknown", peerRelay: "" }));
    const observations = await observeHeartbeats({ autoPong: true }, 8, { peerPathReader: { lookup } });
    expect(pingedTicks(observations)).toEqual([1, 2, 3, 4, 5, 6, 7, 8]);
    expect(closedAtTick(observations)).toBeUndefined();
    expect(loggedRecords("connection.inbound-silent")).toEqual([]);
    expect(loggedRecords("connection.inbound-resumed")).toEqual([]);
    expect(lookup).not.toHaveBeenCalled();
  });

  it("never reports a pong-only client silent when its own frame lands mid-interval", async () => {
    // Hello at second 0, one application frame at second 7, then pong-only. The
    // tick at 25 s skips its ping (18 s of client-initiated quiet) but the tick
    // at 50 s finds no unanswered ping, so nothing was ever asked and nothing
    // is reported: the tick counts a miss for bookkeeping, not for silence.
    const lookup = vi.fn(async (): Promise<PeerPathLookup> => ({ peerPath: "unknown", peerRelay: "" }));
    const observations = await observeHeartbeats({ autoPong: true }, 8, {
      peerPathReader: { lookup },
      messagesAt: (second) => second === 7,
    });
    expect(pingedTicks(observations)).toEqual([2, 3, 4, 5, 6, 7, 8]);
    expect(closedAtTick(observations)).toBeUndefined();
    expect(loggedRecords("connection.inbound-silent")).toEqual([]);
    expect(loggedRecords("connection.inbound-resumed")).toEqual([]);
    expect(lookup).not.toHaveBeenCalled();
  });

  it("retires a silent dead client on the fourth tick, as before", async () => {
    const observations = await observeHeartbeats({ autoPong: false }, 6);
    expect(pingedTicks(observations)).toEqual([1, 2, 3]);
    expect(closedAtTick(observations)).toBe(4);
    const opened = gatewayLog?.mock.calls.find((call) => call[2]?.event === "connection.opened");
    const timeout = gatewayLog?.mock.calls.find((call) => call[2]?.event === "connection.heartbeat-timeout");
    expect(timeout?.[2]).toEqual({
      event: "connection.heartbeat-timeout", source: "transport", connectionId: opened?.[2]?.connectionId,
      peerClientId: "client-heartbeat", peerAttemptId: "initial", peerEpoch: "1",
    });
  });

  it("retires a phone that dies on the fourth tick after its last frame", async () => {
    // Last client ping at second 53; ticks at 75, 100 and 125 each count a
    // miss and the tick at 150 retires it, exactly as when every tick pinged.
    const observations = await observeHeartbeats({
      autoPong: false,
      pingsAt: (second) => second <= 53 && second % 10 === 3,
    }, 8);
    expect(closedAtTick(observations)).toBe(6);
    expect(observations.filter((observation) => observation.tick < 6).every((observation) => !observation.closed)).toBe(true);
  });

  it("pings a client that goes quiet by the second tick and on every tick after", async () => {
    // The last client ping lands 22 s before tick 3, which it therefore still
    // covers; tick 4 is the second tick after the client went quiet.
    const observations = await observeHeartbeats({
      autoPong: true,
      pingsAt: (second) => second <= 53 && second % 10 === 3,
    }, 8);
    expect(pingedTicks(observations)).toEqual([4, 5, 6, 7, 8]);
    expect(closedAtTick(observations)).toBeUndefined();
  });

  it("records one silence episode with its peer path and a resume with its duration", async () => {
    // The phone pings every ten seconds up to second 53, goes quiet, speaks at
    // 80 and at 95; the last tick sees only 5 s of silence, so one episode.
    let release!: () => void;
    const peerPathSettled = new Promise<void>((resolve) => { release = resolve; });
    const lookup = vi.fn(async (): Promise<PeerPathLookup> => {
      await peerPathSettled;
      return { peerPath: "relay", peerRelay: "sfo" };
    });
    const observations = await observeHeartbeats({
      autoPong: false,
      pingsAt: (second) => (second <= 53 && second % 10 === 3) || second === 80 || second === 95,
    }, 4, {
      peerPathReader: { lookup },
      // The socket speaks again before the Tailscale read settles.
      afterSecond: (second) => { if (second === 80) release(); },
    });
    const silent = loggedRecords("connection.inbound-silent");
    const resumed = loggedRecords("connection.inbound-resumed");
    expect(lookup).toHaveBeenCalledTimes(1);
    expect(silent).toHaveLength(1);
    expect(silent[0]!.level).toBe("warning");
    expect(silent[0]!.message).toContain("22000ms");
    // No ping was outstanding: the client's own pings were the liveness signal
    // that stopped, so the record names no unanswered ping.
    expect(silent[0]!.message).toContain("unansweredPingMs=none");
    expect(silent[0]!.fields).toMatchObject({
      peerClientId: "client-heartbeat", peerAttemptId: "initial", peerEpoch: "1",
      peerPath: "relay", peerRelay: "sfo",
    });
    expect(resumed).toHaveLength(1);
    expect(resumed[0]!.level).toBe("info");
    expect(resumed[0]!.message).toContain("27000ms");
    expect(resumed[0]!.fields).toMatchObject({
      connectionId: silent[0]!.fields.connectionId, peerClientId: "client-heartbeat", silentMs: 27_000,
    });
    // A silence that ends before the Tailscale read settles is still reported
    // as silence first and resume second.
    expect(silent[0]!.index).toBeLessThan(resumed[0]!.index);
    expect(closedAtTick(observations)).toBeUndefined();
  });

  it("shows a blackholed path as silence and a resume, from the Gateway log alone", async () => {
    // The path carries nothing between seconds 40 and 72, while the socket
    // stays open: tick 2 lands inside it, and the phone speaks again at 80.
    const lookup = vi.fn(async (): Promise<PeerPathLookup> => ({ peerPath: "relay", peerRelay: "sfo" }));
    const observations = await observeHeartbeats({
      autoPong: false,
      pingsAt: (second) => (second <= 33 && second % 10 === 3) || second === 80 || second === 95,
    }, 4, { peerPathReader: { lookup }, blackhole: { from: 40, to: 72 } });
    const silent = loggedRecords("connection.inbound-silent");
    const resumed = loggedRecords("connection.inbound-resumed");
    expect(silent).toHaveLength(1);
    expect(silent[0]!.level).toBe("warning");
    expect(silent[0]!.message).toContain("17000ms");
    expect(silent[0]!.fields).toMatchObject({ peerPath: "relay", peerRelay: "sfo" });
    expect(resumed).toHaveLength(1);
    expect(resumed[0]!.fields).toMatchObject({ silentMs: 47_000 });
    expect(silent[0]!.index).toBeLessThan(resumed[0]!.index);
    expect(closedAtTick(observations)).toBeUndefined();
  });

  it("shows a blackholed pong-only path once its ping goes unanswered", async () => {
    // The path carries nothing between seconds 20 and 60, so the tick at 25 s
    // pings into it and the tick at 50 s reports that unanswered ping; the
    // pongs released at 60 s end the episode without closing the socket. A
    // client that only answers pings is therefore still detected when its path
    // is genuinely down.
    const lookup = vi.fn(async (): Promise<PeerPathLookup> => ({ peerPath: "relay", peerRelay: "sfo" }));
    const observations = await observeHeartbeats({ autoPong: true }, 4, {
      peerPathReader: { lookup },
      blackhole: { from: 20, to: 60 },
    });
    const silent = loggedRecords("connection.inbound-silent");
    const resumed = loggedRecords("connection.inbound-resumed");
    expect(silent).toHaveLength(1);
    expect(silent[0]!.level).toBe("warning");
    expect(silent[0]!.message).toContain("50000ms");
    // The tick at 50 s reported the ping sent into the blackhole at 25 s.
    expect(silent[0]!.message).toContain("unansweredPingMs=25000");
    expect(silent[0]!.fields).toMatchObject({ peerPath: "relay", peerRelay: "sfo" });
    expect(resumed).toHaveLength(1);
    expect(resumed[0]!.fields.silentMs).toBeGreaterThanOrEqual(50_000);
    expect(silent[0]!.index).toBeLessThan(resumed[0]!.index);
    expect(lookup).toHaveBeenCalledTimes(1);
    expect(closedAtTick(observations)).toBeUndefined();
  });

  it("writes one http.upgrade per upgrade with its phase durations and the peer key", async () => {
    await observeHeartbeats({ autoPong: true }, 2);
    const upgrades = loggedRecords("http.upgrade");
    expect(upgrades).toHaveLength(1);
    expect(upgrades[0]!.level).toBe("debug");
    expect(upgrades[0]!.fields).toMatchObject({
      outcome: "opened", phaseReached: "hello",
      peerClientId: "client-heartbeat", peerAttemptId: "initial", peerEpoch: "1",
    });
    for (const field of ["acceptToUpgradeMs", "authMs", "handshakeMs", "helloMs"]) {
      expect(typeof upgrades[0]!.fields[field]).toBe("number");
    }
  });
});
