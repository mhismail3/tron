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
import { waitFor } from "../../test-support/wait-for.js";

const DURING_SQUEEZE: HostMemory = {
  freeBytes: 1_240_000_000,
  totalBytes: 36_000_000_000,
  swapUsedBytes: 19_800_000_000,
  swapTotalBytes: 20_480_000_000,
  pressure: "critical",
  memoryAvailablePercent: 4,
};
const AFTER_CLEANUP: HostMemory = {
  freeBytes: 30_400_000_000,
  totalBytes: 36_000_000_000,
  swapUsedBytes: 1_700_000_000,
  swapTotalBytes: 2_048_000_000,
  pressure: "normal",
  memoryAvailablePercent: 62,
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

interface Harness {
  port: number;
  probe: ReturnType<typeof vi.fn>;
  sample: (next: HostMemory) => void;
  pairedToken: string;
  localToken: string;
  connect: (token: string) => Promise<WebSocket>;
  records: (event: string) => Array<[string, string, Record<string, unknown>]>;
}

async function startGateway(): Promise<Harness> {
  const root = await mkdtemp(join(tmpdir(), "tron-connection-memory-"));
  const devices = new DeviceStore(root, "machine");
  await devices.initialize();
  const localToken = JSON.parse(await readFile(join(root, "state", "local-auth.json"), "utf8")).bearerToken as string;
  const pairedToken = (await devices.pair((await devices.ensureEnrollment()).code, "Phone")).token;
  const port = await unusedPort();
  let current = DURING_SQUEEZE;
  const probe = vi.fn(async () => current);
  const sampler = new StallSampler({ sampleHost: probe, observeGc: () => () => {} });
  const logger = { log: vi.fn() };
  vi.useFakeTimers({ toFake: ["setInterval", "clearInterval"] });
  const gateway = new GatewayServer({ display: {} as never,
    host: "127.0.0.1",
    port,
    maxFrameBytes: 16_384,
    devices,
    uploads: {} as never,
    sessions: { unsubscribeClient: vi.fn() } as never,
    auth: { detachClient: vi.fn(), cancelOwner: vi.fn() } as never,
    service: {
      info: () => ({ protocolVersion: 8 }),

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
      socket.send(JSON.stringify({ type: "hello", protocolVersion: 8 }));
      await waitFor(() => records("connection.opened").length === before + 1, "connection opened record");
      return socket;
    },
  };
}

describe("host memory in connection records", () => {
  it("states the host's swap and memory pressure when a paired phone drops and reconnects", async () => {
    const harness = await startGateway();
    const socket = await harness.connect(harness.pairedToken);
    const opened = harness.records("connection.opened").at(-1)!;
    expect(opened[0]).toBe("info");
    expect(opened[1]).toContain("connection opened (paired");
    expect(opened[1]).toContain(`swapUsedBytes=${DURING_SQUEEZE.swapUsedBytes}`);
    expect(opened[1]).toContain(`memoryPressure=${DURING_SQUEEZE.pressure}`);

    socket.close();
    await waitFor(() => harness.records("connection.closed").length === 1, "connection closed record");
    const closed = harness.records("connection.closed")[0]!;
    expect(closed[0]).toBe("info");
    expect(closed[1]).toContain(`hostFreeBytes=${DURING_SQUEEZE.freeBytes}`);
    expect(closed[1]).toContain(`swapUsedBytes=${DURING_SQUEEZE.swapUsedBytes}`);
    expect(closed[1]).toContain(`memoryPressure=${DURING_SQUEEZE.pressure}`);

    const reconnect = await harness.connect(harness.pairedToken);
    expect(harness.records("connection.opened").at(-1)![1]).toContain(`swapUsedBytes=${DURING_SQUEEZE.swapUsedBytes}`);
    reconnect.close();
    await waitFor(() => harness.records("connection.closed").length === 2, "second close record");
  });

  it("probes the host on a heartbeat cadence rather than once per connection record", async () => {
    const harness = await startGateway();
    const paired = await harness.connect(harness.pairedToken);
    paired.close();
    await waitFor(() => harness.records("connection.closed").length === 1, "paired close");
    const local = await harness.connect(harness.localToken);
    local.close();
    await waitFor(() => harness.records("connection.closed").length === 2, "local close");
    expect(harness.probe).toHaveBeenCalledTimes(1);
  });

  it("reports the host state sampled after the squeeze, not the state captured at startup", async () => {
    const harness = await startGateway();
    const during = await harness.connect(harness.pairedToken);
    expect(harness.records("connection.opened").at(-1)![1]).toContain(`memoryPressure=${DURING_SQUEEZE.pressure}`);
    during.close();
    await waitFor(() => harness.records("connection.closed").length === 1, "close during the squeeze");

    harness.sample(AFTER_CLEANUP);
    await vi.advanceTimersByTimeAsync(GATEWAY_CONNECTION_POLICY.heartbeatIntervalMs);
    await waitFor(() => harness.probe.mock.calls.length === 2, "the second host probe after the heartbeat");

    const after = await harness.connect(harness.pairedToken);
    const opened = harness.records("connection.opened").at(-1)!;
    expect(opened[1]).toContain(`swapUsedBytes=${AFTER_CLEANUP.swapUsedBytes}`);
    expect(opened[1]).toContain(`memoryPressure=${AFTER_CLEANUP.pressure}`);
    after.close();
    await waitFor(() => harness.records("connection.closed").length === 2, "close after cleanup");
  });

  it("states the sample's age, the swap total and the kernel's memory level", async () => {
    const harness = await startGateway();
    const during = await harness.connect(harness.pairedToken);
    during.close();
    await waitFor(() => harness.records("connection.closed").length === 1, "close during the squeeze");

    harness.sample(AFTER_CLEANUP);
    await new Promise((resolve) => setTimeout(resolve, 20));
    const after = await harness.connect(harness.pairedToken);
    const opened = harness.records("connection.opened").at(-1)!;
    expect(opened[1]).toContain(`swapUsedBytes=${DURING_SQUEEZE.swapUsedBytes}`);
    expect(opened[1]).toContain(`swapTotalBytes=${DURING_SQUEEZE.swapTotalBytes}`);
    expect(opened[1]).toContain(`memoryPressure=${DURING_SQUEEZE.pressure}`);
    expect(opened[1]).toContain(`hostMemoryAvailablePercent=${DURING_SQUEEZE.memoryAvailablePercent}`);
    const ageMs = Number(/hostSampleAgeMs=(\d+)/u.exec(opened[1])?.[1]);
    expect(ageMs).toBeGreaterThanOrEqual(20);
    after.close();
    await waitFor(() => harness.records("connection.closed").length === 2, "second close record");
  });

  it("leaves the Mac app's local probe records free of host facts", async () => {
    const harness = await startGateway();
    const paired = await harness.connect(harness.pairedToken);
    const local = await harness.connect(harness.localToken);
    expect(harness.records("connection.opened").at(-1)![1]).toContain("connection opened (local");
    local.close();
    paired.close();
    await waitFor(() => harness.records("connection.closed").length === 2, "both close records");
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
