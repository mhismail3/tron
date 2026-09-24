import { createServer, request, type IncomingMessage } from "node:http";
import { PassThrough } from "node:stream";
import { createConnection } from "node:net";
import WebSocket from "ws";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
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

function responseStatus(outgoing: ReturnType<typeof request>): Promise<{ response: IncomingMessage; status: number }> {
  return new Promise((resolve, reject) => {
    outgoing.once("response", (response) => resolve({ response, status: response.statusCode ?? 0 }));
    outgoing.once("error", reject);
  });
}

async function bounded<T>(promise: Promise<T>, label: string): Promise<T> {
  let timer!: NodeJS.Timeout;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(`${label} timed out`)), 2_500);
    timer.unref();
  });
  try { return await Promise.race([promise, timeout]); }
  finally { clearTimeout(timer); }
}

describe("Gateway HTTP admission and retirement", () => {
  it("rejects non-object pairing JSON with bounded invalid_request responses", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-pair-body-"));
    const devices = new DeviceStore(root, "machine");
    await devices.initialize();
    const port = await unusedPort();
    const gateway = new GatewayServer({
      host: "127.0.0.1", port, maxFrameBytes: 16_384, devices, uploads: {} as any, sessions: {} as any,
      auth: {} as any, service: { info: () => ({ protocolVersion: 5 }) } as any, logger: { log: () => {} } as any,
    });
    await gateway.listen();
    cleanups.push(async () => { await bounded(gateway.close(), "pair gateway close"); await rm(root, { recursive: true, force: true }); });
    for (const body of ["null", "[]", JSON.stringify("x"), "123"]) {
      const outgoing = request({ host: "127.0.0.1", port, method: "POST", path: "/v1/pair", headers: { "content-type": "application/json" } });
      outgoing.end(body);
      const result = await bounded(responseStatus(outgoing), "pair invalid body");
      const chunks: Buffer[] = [];
      for await (const chunk of result.response) chunks.push(Buffer.from(chunk));
      expect(result.status).toBe(400);
      expect(JSON.parse(Buffer.concat(chunks).toString("utf8"))).toMatchObject({ error: { code: "invalid_request" } });
    }
  });

  it("uses the same bounded retirement when startup fails with an incomplete HTTP peer", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-startup-retirement-"));
    const devices = new DeviceStore(root, "fixture-machine");
    await devices.initialize();
    const port = await unusedPort();
    let began!: () => void, fail!: () => void, received!: () => void;
    const bound = new Promise<void>(resolve => { began = resolve; });
    const warmup = new Promise<void>(resolve => { fail = resolve; });
    const headers = new Promise<void>(resolve => { received = resolve; });
    const gateway = new GatewayServer({
      host: "127.0.0.1", port, maxFrameBytes: 16_384, devices, uploads: {} as any, sessions: {} as any,
      auth: {} as any, service: { info: () => ({ protocolVersion: 5 }) } as any, logger: { log: () => {} } as any,
    });
    (gateway as unknown as { server: import("node:http").Server }).server.once("connection", socket => socket.once("data", received));
    let peer: ReturnType<typeof createConnection> | undefined;
    const starting = gateway.listen(async () => { began(); await warmup; throw new Error("fixture warmup failed"); });
    void starting.catch(() => {});
    cleanups.push(async () => {
      fail(); peer?.destroy();
      await starting.catch(() => {});
      try { await bounded(gateway.close(), "failed-startup cleanup"); }
      finally { await rm(root, { recursive: true, force: true }); }
    });
    await bounded(bound, "startup listener");
    peer = createConnection({ host: "127.0.0.1", port });
    peer.on("error", () => {});
    const closed = new Promise<void>(resolve => peer!.once("close", resolve));
    peer.write("GET /health HTTP/1.1\r\nHost: fixture");
    await bounded(headers, "partial header receipt");
    fail();
    await expect(bounded(starting, "bounded startup failure")).rejects.toThrow("fixture warmup failed");
    await bounded(closed, "failed-startup peer close");
    expect(gateway.close()).toBe(gateway.close());
  });
  it("rechecks shutdown after asynchronous upgrade authentication", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-http-upgrade-admission-"));
    const devices = new DeviceStore(root, "machine");
    await devices.initialize();
    const token = JSON.parse(await readFile(join(root, "gateway", "local-auth.json"), "utf8")).bearerToken;
    const port = await unusedPort();
    let authenticateStarted!: () => void;
    let releaseAuthentication!: () => void;
    const authenticationStarted = new Promise<void>((resolve) => { authenticateStarted = resolve; });
    const authenticationGate = new Promise<void>((resolve) => { releaseAuthentication = resolve; });
    vi.spyOn(devices, "authenticateAndAdmit").mockImplementation(async (_token, register) => {
      authenticateStarted();
      await authenticationGate;
      return register({ kind: "local" });
    });
    const logger = { log: vi.fn() };
    const invoke = vi.fn();
    const gateway = new GatewayServer({
      host: "127.0.0.1", port, maxFrameBytes: 16_384, devices, uploads: {} as any,
      sessions: { unsubscribeClient: vi.fn() } as any, auth: { detachClient: vi.fn() } as any,
      service: { info: () => ({ protocolVersion: 5 }), releaseClient: vi.fn(), invoke } as any,
      logger: logger as any,
    });
    await gateway.listen();
    cleanups.push(async () => {
      releaseAuthentication();
      await bounded(gateway.close(), "upgrade gateway close");
      await rm(root, { recursive: true, force: true });
    });

    const socket = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${token}` } });
    socket.on("error", () => {});
    await bounded(authenticationStarted, "upgrade authentication");
    const closing = gateway.close();
    releaseAuthentication();
    await bounded(closing, "pending upgrade close");
    expect(invoke).not.toHaveBeenCalled();
    expect(logger.log.mock.calls.some((call) => call[2]?.event === "connection.opened")).toBe(false);
    socket.terminate();
  });

  it("keeps a healthy request beside a saturated slow stream and bounds fixture close", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-http-admission-"));
    const devices = new DeviceStore(root, "machine");
    await devices.initialize();
    const token = JSON.parse(await readFile(join(root, "gateway", "local-auth.json"), "utf8")).bearerToken;
    const port = await unusedPort();
    const logger = { log: vi.fn() };
    const stream = new PassThrough();
    let acquired = false;
    const released = vi.fn();
    const sessions = {
      acquireBlob: vi.fn(async () => {
        acquired = true;
        return {
          mimeType: "application/octet-stream", size: 1, totalSize: 1, rangeStart: 0, rangeEnd: 0,
          stream,
          release: async () => { released(); },
        };
      }),
    };
    const gateway = new GatewayServer({
      host: "127.0.0.1", port, maxFrameBytes: 16_384,
      maximumHttpRequests: 2, maximumHttpRequestsPerIdentity: 1,
      devices, uploads: {} as any, sessions: sessions as any,
      auth: { detachClient: vi.fn() } as any,
      service: {
        info: () => ({ protocolVersion: 5 }), releaseClient: vi.fn(),
      } as any,
      logger: logger as any,
    });
    await gateway.listen();
    cleanups.push(async () => {
      stream.destroy();
      await bounded(gateway.close(), "HTTP gateway close");
      await rm(root, { recursive: true, force: true });
    });

    const slow = request({ host: "127.0.0.1", port, path: "/v1/blobs/slow", headers: { authorization: `Bearer ${token}` } });
    slow.on("error", () => {});
    slow.end();
    const slowResponse = await bounded(responseStatus(slow), "slow response headers");
    await bounded((async () => { while (!acquired) await new Promise((resolve) => setImmediate(resolve)); })(), "slow lease admission");
    expect(slowResponse.status).toBe(200);

    const healthy = request({ host: "127.0.0.1", port, path: "/health" });
    healthy.end();
    const healthyResponse = await bounded(responseStatus(healthy), "healthy response");
    healthyResponse.response.resume();
    expect(healthyResponse.status).toBe(200);

    const saturated = request({ host: "127.0.0.1", port, path: "/v1/blobs/other", headers: { authorization: `Bearer ${token}` } });
    saturated.end();
    const saturatedResponse = await bounded(responseStatus(saturated), "saturated response");
    saturatedResponse.response.resume();
    expect(saturatedResponse.status).toBe(503);
    expect(sessions.acquireBlob).toHaveBeenCalledTimes(1);

    const started = Date.now();
    await bounded(gateway.close(), "stalled HTTP close");
    expect(Date.now() - started).toBeLessThan(2_000);
    await bounded(new Promise<void>((resolve) => {
      if (released.mock.calls.length > 0) resolve();
      else released.mockImplementation(() => resolve());
    }), "blob lease release");
  });
});
