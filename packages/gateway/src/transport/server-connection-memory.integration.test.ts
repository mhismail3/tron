import { createServer } from "node:http";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import WebSocket from "ws";
import { afterEach, describe, expect, it, vi } from "vitest";
import { DeviceStore } from "../security/device-store.js";
import { GATEWAY_CONNECTION_POLICY } from "./connection-policy.js";
import { GatewayServer } from "./server.js";
import { StallSampler, type HostMemory } from "./stall-diagnostics.js";

// Failure modes this file exists to catch (real sockets, injected host probe):
// 1. A phone's `connection.closed` and `connection.opened` records say nothing
//    about the host, so the 2026-09-27 drop/reconnect cycles at 19.8 GB of swap
//    stay an unexplained transport fault.
// 2. Every boundary record probes the host for itself, so the reconnect storm
//    caused by paging adds a `sysctl` pair per record.
// 3. The host sample is taken once and never refreshed, so a drop hours later
//    reports the numbers captured before the squeeze.
// 4. The Mac app's constant local-probe records gain host facts, multiplying
//    them per probe instead of per phone connection.

/** The 2026-09-27 incident: swap nearly exhausted while phones reconnected. */
const DURING_SQUEEZE: HostMemory = {
  freeBytes: 1_240_000_000,
  totalBytes: 36_000_000_000,
  swapUsedBytes: 19_800_000_000,
  pressure: "critical",
};
/** The same Mac after the idle simulators were shut down. */
const AFTER_CLEANUP: HostMemory = {
  freeBytes: 30_400_000_000,
  totalBytes: 36_000_000_000,
  swapUsedBytes: 1_700_000_000,
  pressure: "normal",
};

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

async function waitUntil(predicate: () => boolean, label: string): Promise<void> {
  const deadline = Date.now() + 5_000;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error(`${label} timed out`);
    await new Promise((resolve) => setTimeout(resolve, 1));
  }
}

interface Harness {
  port: number;
  /** Counts every host probe and answers with what `sample` currently holds. */
  probe: ReturnType<typeof vi.fn>;
  /** Replaces what the next host probe answers. */
  sample: (next: HostMemory) => void;
  pairedToken: string;
  localToken: string;
  /** Opens one socket, sends hello and returns it once its open record landed. */
  connect: (token: string) => Promise<WebSocket>;
  records: (event: string) => Array<[string, string, Record<string, unknown>]>;
}

async function startGateway(): Promise<Harness> {
  const root = await mkdtemp(join(tmpdir(), "tron-connection-memory-"));
  const devices = new DeviceStore(root, "machine");
  await devices.initialize();
  const localToken = JSON.parse(await readFile(join(root, "gateway", "local-auth.json"), "utf8")).bearerToken as string;
  const pairedToken = (await devices.pair((await devices.ensureEnrollment()).code, "Phone")).token;
  const port = await unusedPort();
  let current = DURING_SQUEEZE;
  const probe = vi.fn(async () => current);
  const sampler = new StallSampler({ sampleHost: probe, observeGc: () => () => {} });
  const logger = { log: vi.fn() };
  // Only the heartbeat interval is virtual: socket I/O and waits stay real.
  vi.useFakeTimers({ toFake: ["setInterval", "clearInterval"] });
  const gateway = new GatewayServer({
    host: "127.0.0.1",
    port,
    maxFrameBytes: 16_384,
    devices,
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
    stallSampler: sampler,
  });
  await gateway.listen();
  const sockets: WebSocket[] = [];
  cleanups.push(async () => {
    for (const socket of sockets) socket.terminate();
    try {
      await gateway.close();
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  const records = (event: string): Array<[string, string, Record<string, unknown>]> => logger.log.mock.calls
    .filter((call) => call[2]?.event === event)
    .map((call) => call as [string, string, Record<string, unknown>]);
  return {
    port,
    probe,
    sample: (next) => { current = next; },
    pairedToken,
    localToken,
    records,
    connect: async (token) => {
      const before = records("connection.opened").length;
      const socket = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${token}` } });
      sockets.push(socket);
      await new Promise<void>((resolve, reject) => { socket.once("open", () => resolve()); socket.once("error", reject); });
      socket.send(JSON.stringify({ type: "hello", protocolVersion: 5 }));
      await waitUntil(() => records("connection.opened").length === before + 1, "connection opened record");
      return socket;
    },
  };
}

describe("host memory in connection records", () => {
  // Failure mode 1: the record an operator reads when the phone drops at high
  // swap must carry the host's memory pressure and swap, including the first
  // connection after a Gateway start.
  it("states the host's swap and memory pressure when a paired phone drops and reconnects", async () => {
    const harness = await startGateway();
    const socket = await harness.connect(harness.pairedToken);
    const opened = harness.records("connection.opened").at(-1)!;
    expect(opened[0]).toBe("info");
    expect(opened[1]).toContain("connection opened (paired");
    expect(opened[1]).toContain(`swapUsedBytes=${DURING_SQUEEZE.swapUsedBytes}`);
    expect(opened[1]).toContain(`memoryPressure=${DURING_SQUEEZE.pressure}`);

    socket.close();
    await waitUntil(() => harness.records("connection.closed").length === 1, "connection closed record");
    const closed = harness.records("connection.closed")[0]!;
    expect(closed[0]).toBe("info");
    expect(closed[1]).toContain(`hostFreeBytes=${DURING_SQUEEZE.freeBytes}`);
    expect(closed[1]).toContain(`swapUsedBytes=${DURING_SQUEEZE.swapUsedBytes}`);
    expect(closed[1]).toContain(`memoryPressure=${DURING_SQUEEZE.pressure}`);

    // The reconnect after the drop reports the same host state.
    const reconnect = await harness.connect(harness.pairedToken);
    expect(harness.records("connection.opened").at(-1)![1]).toContain(`swapUsedBytes=${DURING_SQUEEZE.swapUsedBytes}`);
    reconnect.close();
    await waitUntil(() => harness.records("connection.closed").length === 2, "second close record");
  });

  // Failure mode 2: four boundary records must not become four host probes.
  it("probes the host on a heartbeat cadence rather than once per connection record", async () => {
    const harness = await startGateway();
    const paired = await harness.connect(harness.pairedToken);
    paired.close();
    await waitUntil(() => harness.records("connection.closed").length === 1, "paired close");
    const local = await harness.connect(harness.localToken);
    local.close();
    await waitUntil(() => harness.records("connection.closed").length === 2, "local close");
    expect(harness.probe).toHaveBeenCalledTimes(1);
  });

  // Failure mode 3: a stale sample would report the pre-squeeze host forever.
  it("reports the host state sampled after the squeeze, not the state captured at startup", async () => {
    const harness = await startGateway();
    const during = await harness.connect(harness.pairedToken);
    expect(harness.records("connection.opened").at(-1)![1]).toContain(`memoryPressure=${DURING_SQUEEZE.pressure}`);
    during.close();
    await waitUntil(() => harness.records("connection.closed").length === 1, "close during the squeeze");

    harness.sample(AFTER_CLEANUP);
    await vi.advanceTimersByTimeAsync(GATEWAY_CONNECTION_POLICY.heartbeatIntervalMs);
    await vi.waitFor(() => expect(harness.probe).toHaveBeenCalledTimes(2));

    const after = await harness.connect(harness.pairedToken);
    const opened = harness.records("connection.opened").at(-1)!;
    expect(opened[1]).toContain(`swapUsedBytes=${AFTER_CLEANUP.swapUsedBytes}`);
    expect(opened[1]).toContain(`memoryPressure=${AFTER_CLEANUP.pressure}`);
    after.close();
    await waitUntil(() => harness.records("connection.closed").length === 2, "close after cleanup");
  });

  // Failure mode 4: the Mac app's local probes reconnect constantly; host facts
  // belong to the phone's boundary, not to every probe line. The paired socket
  // in the same run is the positive control for the absent fields.
  it("leaves the Mac app's local probe records free of host facts", async () => {
    const harness = await startGateway();
    const paired = await harness.connect(harness.pairedToken);
    const local = await harness.connect(harness.localToken);
    expect(harness.records("connection.opened").at(-1)![1]).toContain("connection opened (local");
    local.close();
    paired.close();
    await waitUntil(() => harness.records("connection.closed").length === 2, "both close records");
    expect(harness.records("connection.closed").find(([level]) => level === "info")![1]).toContain("swapUsedBytes=");
    const localMessages = harness.records("connection.opened")
      .concat(harness.records("connection.closed"))
      .filter(([level]) => level === "debug")
      .map(([, message]) => message);
    expect(localMessages.length).toBe(2);
    for (const message of localMessages) {
      expect(message).not.toContain("swapUsedBytes=");
      expect(message).not.toContain("memoryPressure=");
      expect(message).not.toContain("hostFreeBytes=");
    }
  });
});
