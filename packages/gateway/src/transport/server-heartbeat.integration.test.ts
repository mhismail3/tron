import { createServer } from "node:http";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import WebSocket from "ws";
import { afterEach, describe, expect, it, vi } from "vitest";
import { DeviceStore } from "../security/device-store.js";
import { GATEWAY_CONNECTION_POLICY } from "./connection-policy.js";
import { GatewayServer } from "./server.js";

// Failure modes this file exists to catch (real sockets, fake heartbeat clock):
// 1. Skipping pings delays dead-client retirement past today's fourth tick.
// 2. A pong suppresses the next ping, so a pong-only client is pinged only
//    every other tick and loses a third of its pong-latency tolerance.
// 3. A client that proves liveness with its own pings is still server-pinged
//    (the wakeup this rule removes) or, worse, is falsely retired.
// 4. A client that goes quiet is never pinged again and is retired while alive.
// 5. The retirement record cannot be joined to the phone's own records because
//    it lacks the connection ID or the peer's hello correlation key.

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

interface TickObservation {
  tick: number;
  serverPings: number;
  closed: boolean;
}

/** Runs one client against a real Gateway socket for `ticks` heartbeat ticks
 * on a virtual clock that drives both the heartbeat interval and
 * `performance.now()`, and reports what the client observed after each tick. */
async function observeHeartbeats(script: ClientScript, ticks: number): Promise<TickObservation[]> {
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
      info: () => ({ protocolVersion: 5 }),
      terminalBelongsToSession: () => false,
      releaseClient: vi.fn(),
      invoke: vi.fn(),
    } as never,
    logger: logger as never,
  });
  await gateway.listen();
  const socket = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, {
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
  socket.send(JSON.stringify({ type: "hello", protocolVersion: 5, diagnostics: PEER_DIAGNOSTICS }));
  await realWait(() => logger.log.mock.calls.some((call) => call[2]?.event === "connection.opened"), "hello");
  const connection = () => [...(gateway as unknown as { clients: Map<string, { unansweredHeartbeats: number }> }).clients.values()][0];

  const observations: TickObservation[] = [];
  const start = now;
  for (let second = 1; second <= ticks * TICK_SECONDS; second += 1) {
    now = start + second * 1_000;
    await vi.advanceTimersByTimeAsync(1_000);
    if (second % TICK_SECONDS === 0) {
      const tick = second / TICK_SECONDS;
      // Everything the client sends in reply to this tick arrives one round
      // trip after it, never on the tick's own instant.
      now += ROUND_TRIP_MS;
      if (!closed) {
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
      if (!closed && script.autoPong && pingedThisTick) {
        await realWait(() => connection()?.unansweredHeartbeats === 0, `tick ${tick} pong`);
      }
    }
    if (!closed && script.pingsAt?.(second)) {
      const expected = clientPongs + 1;
      socket.ping();
      // The Gateway handles the ping in the same callback that answers it.
      await realWait(() => clientPongs === expected || closed, `second ${second} client ping`);
    }
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

describe("Gateway heartbeat pings", () => {
  it("never pings or retires a phone that pings every ten seconds", async () => {
    const observations = await observeHeartbeats({ autoPong: true, pingsAt: (second) => second % 10 === 3 }, 8);
    expect(pingedTicks(observations)).toEqual([]);
    expect(closedAtTick(observations)).toBeUndefined();
  });

  it("pings a pong-only client on every tick and never retires it", async () => {
    const observations = await observeHeartbeats({ autoPong: true }, 8);
    expect(pingedTicks(observations)).toEqual([1, 2, 3, 4, 5, 6, 7, 8]);
    expect(closedAtTick(observations)).toBeUndefined();
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
});
