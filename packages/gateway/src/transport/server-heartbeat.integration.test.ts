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
import { waitFor } from "../../test-support/wait-for.js";

const NO_TAILSCALE_PATH: PeerPathReader = { lookup: async (): Promise<PeerPathLookup> => ({ peerPath: "unknown", peerPathSource: "not-tailscale", peerRelay: "" }) };

const INTERVAL_MS = GATEWAY_CONNECTION_POLICY.heartbeatIntervalMs;
const TICK_SECONDS = INTERVAL_MS / 1_000;
const ROUND_TRIP_MS = 100;

const PEER_DIAGNOSTICS = { clientId: "client-heartbeat", attemptId: "initial", epoch: "1" };

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

interface ClientScript {
  autoPong: boolean;
  pingsAt?: (second: number) => boolean;
}

interface HarnessOptions {
  peerPathReader?: PeerPathReader;
  blackhole?: { from: number; to: number };
  messagesAt?: (second: number) => boolean;
  afterSecond?: (second: number) => void;
}

interface HoldProxy {
  port: number;
  holding(): boolean;
  setHolding(value: boolean): void;
  close(): Promise<void>;
}

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

async function observeHeartbeats(script: ClientScript, ticks: number, options: HarnessOptions = {}): Promise<TickObservation[]> {
  let now = 1_000_000;
  vi.spyOn(performance, "now").mockImplementation(() => now);
  vi.useFakeTimers({ toFake: ["setInterval", "clearInterval"] });
  const root = await mkdtemp(join(tmpdir(), "tron-server-heartbeat-"));
  const devices = new DeviceStore(root, "machine");
  await devices.initialize();
  const token = JSON.parse(await readFile(join(root, "state", "local-auth.json"), "utf8")).bearerToken;
  const port = await unusedPort();
  const logger = { log: vi.fn() };
  gatewayLog = logger.log;
  const gateway = new GatewayServer({ display: {} as never,
    host: "127.0.0.1", port, maxFrameBytes: 16_384, devices,
    uploads: {} as never,
    sessions: { unsubscribeClient: vi.fn() } as never,
    auth: { detachClient: vi.fn(), cancelOwner: vi.fn() } as never,
    service: {
      info: () => ({ protocolVersion: 8 }),

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
  socket.send(JSON.stringify({ type: "hello", protocolVersion: 8, diagnostics: PEER_DIAGNOSTICS }));
  await waitFor(() => logger.log.mock.calls.some((call) => call[2]?.event === "connection.opened"), "hello");
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
      now += ROUND_TRIP_MS;
      if (!closed && !blackholed) {
        const sequence = tick;
        gateway.broadcast("test.barrier", { sequence });
        await waitFor(() => barrier === sequence || closed, `tick ${tick} barrier`);
      }
      observations.push({ tick, serverPings, closed });
      const pingedThisTick = serverPings > (observations.at(-2)?.serverPings ?? 0);
      if (!closed && !blackholed && script.autoPong && pingedThisTick) {
        await waitFor(() => connection()?.unansweredHeartbeats === 0, `tick ${tick} pong`);
      }
    }
    if (!closed && script.pingsAt?.(second)) {
      const expected = clientPongs + 1;
      socket.ping();
      await waitFor(() => clientPongs === expected || closed, `second ${second} client ping`);
    }
    if (!closed && options.messagesAt?.(second) === true) {
      const before = connection()?.lastClientInitiatedInboundAt ?? null;
      socket.send(JSON.stringify({ type: "probe" }));
      await waitFor(() => (connection()?.lastClientInitiatedInboundAt ?? null) !== before, `second ${second} client message`);
    }
    options.afterSecond?.(second);
  }
  return observations;
}

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
    const lookup = vi.fn(async (): Promise<PeerPathLookup> => ({ peerPath: "unknown", peerPathSource: "not-tailscale", peerRelay: "" }));
    const observations = await observeHeartbeats({ autoPong: true }, 8, { peerPathReader: { lookup } });
    expect(pingedTicks(observations)).toEqual([1, 2, 3, 4, 5, 6, 7, 8]);
    expect(closedAtTick(observations)).toBeUndefined();
    expect(loggedRecords("connection.inbound-silent")).toEqual([]);
    expect(loggedRecords("connection.inbound-resumed")).toEqual([]);
    expect(lookup).not.toHaveBeenCalled();
  });

  it("never reports a pong-only client silent when its own frame lands mid-interval", async () => {
    const lookup = vi.fn(async (): Promise<PeerPathLookup> => ({ peerPath: "unknown", peerPathSource: "not-tailscale", peerRelay: "" }));
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
    const observations = await observeHeartbeats({
      autoPong: false,
      pingsAt: (second) => second <= 53 && second % 10 === 3,
    }, 8);
    expect(closedAtTick(observations)).toBe(6);
    expect(observations.filter((observation) => observation.tick < 6).every((observation) => !observation.closed)).toBe(true);
  });

  it("pings a client that goes quiet by the second tick and on every tick after", async () => {
    const observations = await observeHeartbeats({
      autoPong: true,
      pingsAt: (second) => second <= 53 && second % 10 === 3,
    }, 8);
    expect(pingedTicks(observations)).toEqual([4, 5, 6, 7, 8]);
    expect(closedAtTick(observations)).toBeUndefined();
  });

  it("records one silence episode with its peer path and a resume with its duration", async () => {
    let release!: () => void;
    const peerPathSettled = new Promise<void>((resolve) => { release = resolve; });
    const lookup = vi.fn(async (): Promise<PeerPathLookup> => {
      await peerPathSettled;
      return {
        peerPath: "relay", peerPathSource: "tailscale-status", peerRelay: "sfo",
        peerLastHandshake: "2026-02-01T00:00:00Z", peerRxBytes: 1234, peerTxBytes: 5678,
      };
    });
    const observations = await observeHeartbeats({
      autoPong: false,
      pingsAt: (second) => (second <= 53 && second % 10 === 3) || second === 80 || second === 95,
    }, 4, {
      peerPathReader: { lookup },
      afterSecond: (second) => { if (second === 80) release(); },
    });
    const silent = loggedRecords("connection.inbound-silent");
    const resumed = loggedRecords("connection.inbound-resumed");
    expect(lookup).toHaveBeenCalledTimes(1);
    expect(silent).toHaveLength(1);
    expect(silent[0]!.level).toBe("warning");
    expect(silent[0]!.message).toContain("22000ms");
    expect(silent[0]!.message).toContain("unansweredPingMs=none");
    expect(silent[0]!.fields).toMatchObject({
      peerClientId: "client-heartbeat", peerAttemptId: "initial", peerEpoch: "1",
      peerPath: "relay", peerPathSource: "tailscale-status", peerRelay: "sfo",
      peerLastHandshake: "2026-02-01T00:00:00Z", peerRxBytes: 1234, peerTxBytes: 5678,
    });
    expect(resumed).toHaveLength(1);
    expect(resumed[0]!.level).toBe("info");
    expect(resumed[0]!.message).toContain("27000ms");
    expect(resumed[0]!.fields).toMatchObject({
      connectionId: silent[0]!.fields.connectionId, peerClientId: "client-heartbeat", silentMs: 27_000,
    });
    expect(silent[0]!.index).toBeLessThan(resumed[0]!.index);
    expect(closedAtTick(observations)).toBeUndefined();
  });

  it("shows a blackholed path as silence and a resume, from the Gateway log alone", async () => {
    const lookup = vi.fn(async (): Promise<PeerPathLookup> => ({ peerPath: "relay", peerPathSource: "tailscale-status", peerRelay: "sfo" }));
    const observations = await observeHeartbeats({
      autoPong: false,
      pingsAt: (second) => (second <= 33 && second % 10 === 3) || second === 80 || second === 95,
    }, 4, { peerPathReader: { lookup }, blackhole: { from: 40, to: 72 } });
    const silent = loggedRecords("connection.inbound-silent");
    const resumed = loggedRecords("connection.inbound-resumed");
    expect(silent).toHaveLength(1);
    expect(silent[0]!.level).toBe("warning");
    expect(silent[0]!.message).toContain("17000ms");
    expect(silent[0]!.fields).toMatchObject({ peerPath: "relay", peerPathSource: "tailscale-status", peerRelay: "sfo" });
    expect(resumed).toHaveLength(1);
    expect(resumed[0]!.fields).toMatchObject({ silentMs: 47_000 });
    expect(silent[0]!.index).toBeLessThan(resumed[0]!.index);
    expect(closedAtTick(observations)).toBeUndefined();
  });

  it("shows a blackholed pong-only path once its ping goes unanswered", async () => {
    const lookup = vi.fn(async (): Promise<PeerPathLookup> => ({ peerPath: "relay", peerPathSource: "tailscale-status", peerRelay: "sfo" }));
    const observations = await observeHeartbeats({ autoPong: true }, 4, {
      peerPathReader: { lookup },
      blackhole: { from: 20, to: 60 },
    });
    const silent = loggedRecords("connection.inbound-silent");
    const resumed = loggedRecords("connection.inbound-resumed");
    expect(silent).toHaveLength(1);
    expect(silent[0]!.level).toBe("warning");
    expect(silent[0]!.message).toContain("50000ms");
    expect(silent[0]!.message).toContain("unansweredPingMs=25000");
    expect(silent[0]!.fields).toMatchObject({ peerPath: "relay", peerPathSource: "tailscale-status", peerRelay: "sfo" });
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
