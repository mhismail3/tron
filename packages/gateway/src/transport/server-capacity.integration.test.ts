import { createServer } from "node:http";
import { mkdtemp, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import WebSocket from "ws";
import { afterEach, describe, expect, it, vi } from "vitest";
import { DeviceStore } from "../security/device-store.js";
import { GatewayServer } from "./server.js";

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

describe("WebSocket connection and outbound capacity", () => {
  it("rejects connections at capacity and closes slow outbound clients without dropping events", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-server-capacity-"));
    const devices = new DeviceStore(root, "machine");
    await devices.initialize();
    const token = JSON.parse(await readFile(join(root, "gateway", "local-auth.json"), "utf8")).bearerToken;
    const port = await unusedPort();
    const service = {
      info: () => ({ gatewayVersion: "test", piVersion: "test", protocolVersion: 3, minProtocolVersion: 3, machineId: "machine", machineName: "test", capabilities: [] }),
      terminalBelongsToSession: () => false,
      releaseClient: vi.fn(),
      invoke: vi.fn(),
    };
    const gateway = new GatewayServer({
      host: "127.0.0.1",
      port,
      maxFrameBytes: 16_384,
      maximumConnections: 1,
      maximumConnectionsPerIdentity: 1,
      maximumOutboundFrames: 1,
      maximumOutboundBytes: 16_384,
      devices,
      uploads: {} as any,
      sessions: { unsubscribeClient: vi.fn() } as any,
      auth: { cancelClient: vi.fn() } as any,
      service: service as any,
      logger: { log: vi.fn() } as any,
    });
    await gateway.listen();
    cleanups.push(async () => { await gateway.close(); });

    const first = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${token}` } });
    const frames: any[] = [];
    first.on("message", (raw) => frames.push(JSON.parse(raw.toString())));
    await new Promise<void>((resolve) => first.once("open", () => resolve()));
    first.send(JSON.stringify({ type: "hello", protocolVersion: 3 }));
    await waitUntil(() => frames.some((frame) => frame.type === "hello"));

    const rejected = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${token}` } });
    const rejectedStatus = await new Promise<number>((resolve, reject) => {
      rejected.once("unexpected-response", (_request, response) => {
        response.resume();
        resolve(response.statusCode ?? 0);
      });
      rejected.once("error", reject);
    });
    expect(rejectedStatus).toBe(503);

    const closed = new Promise<number>((resolve) => first.once("close", (code) => resolve(code)));
    gateway.broadcast("test.event", { sequence: 1 });
    gateway.broadcast("test.event", { sequence: 2 });
    expect(await closed).toBe(1013);
  });
});
