import { once } from "node:events";
import { createServer, request, type Server } from "node:http";
import { createConnection, type Socket } from "node:net";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import WebSocket from "ws";
import { afterEach, describe, expect, it, vi } from "vitest";
import { DeviceStore } from "../security/device-store.js";
import { AsyncMutex } from "../util/async-mutex.js";
import { BlobStore } from "../sessions/blob-store.js";
import { GatewayServer, HTTP_MAXIMUM_CONNECTIONS_PER_ADDRESS, HTTP_MAXIMUM_REQUESTS_PER_CONNECTION, HTTP_REQUEST_IDLE_TIMEOUT_MS, HTTP_REQUEST_TIMEOUT_MS, HTTP_HEADERS_TIMEOUT_MS } from "./server.js";

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => {
  const failures: unknown[] = [];
  for (const cleanup of cleanups.splice(0).reverse()) {
    try { await cleanup(); } catch (error) { failures.push(error); }
  }
  if (failures.length) throw new AggregateError(failures, "fixture cleanup failed");
});
function gate() {
  let resolve!: () => void;
  const promise = new Promise<void>(done => { resolve = done; });
  return { promise, resolve };
}
async function bounded<T>(promise: Promise<T>, label: string): Promise<T> {
  let timer!: NodeJS.Timeout;
  try {
    return await Promise.race([promise, new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new Error(`${label} timed out`)), 3_000);
    })]);
  } finally { clearTimeout(timer); }
}
async function fixture(maximumHttpRequests = 128) {
  const root = await mkdtemp(join(tmpdir(), "tron-http-lifecycle-"));
  const devices = new DeviceStore(root, "fixture-machine");
  await devices.initialize();
  const probe = createServer();
  await new Promise<void>(resolve => probe.listen(0, "127.0.0.1", resolve));
  const port = (probe.address() as { port: number }).port;
  await new Promise<void>(resolve => probe.close(() => resolve()));
  const acquireBlob = vi.fn();
  const gateway = new GatewayServer({
    host: "127.0.0.1", port, maxFrameBytes: 16_384, maximumHttpRequests,
    devices, uploads: {} as any, sessions: { acquireBlob, unsubscribeClient: vi.fn() } as any,
    auth: { detachClient: vi.fn() } as any,
    service: { info: () => ({ protocolVersion: 5 }), releaseClient: vi.fn() } as any,
    logger: { log: vi.fn() } as any,
  });
  const serverSockets: Socket[] = [];
  // Observe the actual transport terminal boundary, not a scheduling delay or
  // a private admission counter that could agree with its own broken helper.
  (gateway as unknown as { server: Server }).server.on("connection", socket => serverSockets.push(socket));
  const clientSockets: Socket[] = [];
  cleanups.push(async () => {
    for (const socket of clientSockets) socket.destroy();
    try { await bounded(gateway.close(), "fixture close"); }
    finally { await rm(root, { recursive: true, force: true }); }
  });
  await gateway.listen();
  return { root, gateway, devices, port, serverSockets, clientSockets, acquireBlob };
}
async function health(port: number): Promise<number> {
  return bounded(new Promise((resolve, reject) => {
    const outgoing = request({ host: "127.0.0.1", port, path: "/health", agent: false }, incoming => {
      incoming.resume();
      incoming.once("end", () => resolve(incoming.statusCode ?? 0));
      incoming.once("error", reject);
    });
    outgoing.once("error", reject);
    outgoing.end();
  }), "health response");
}
function capture(socket: Socket, responses = 1): Promise<string> {
  return bounded(new Promise((resolve, reject) => {
    let text = "";
    const data = (chunk: Buffer) => {
      text += chunk.toString("utf8");
      if (text.length > 65_536) { cleanup(); reject(new Error("fixture response exceeded bound")); }
      else if ((text.match(/HTTP\/1\.1 \d{3}/g) ?? []).length === responses) { cleanup(); resolve(text); }
    };
    const error = (failure: Error) => { cleanup(); reject(failure); };
    const cleanup = () => { socket.off("data", data); socket.off("error", error); };
    socket.on("data", data); socket.once("error", error);
  }), "raw HTTP response");
}

describe("HTTP pending-work ownership", () => {
  it("keeps complete-body, header and inactivity bounds distinct", async () => {
    const f = await fixture();
    const server = (f.gateway as unknown as { server: Server }).server;
    expect(server.requestTimeout).toBe(HTTP_REQUEST_TIMEOUT_MS);
    expect(server.requestTimeout).toBe(300_000);
    expect(server.headersTimeout).toBe(HTTP_HEADERS_TIMEOUT_MS);
    expect(server.headersTimeout).toBe(15_000);
    expect(server.timeout).toBe(HTTP_REQUEST_IDLE_TIMEOUT_MS);
    expect(server.timeout).toBe(30_000);
  });
  it.each(["http", "upgrade"])("keeps %s authentication charged after peer close and rejects late admission", async kind => {
    const f = await fixture(1);
    const entered = gate(), release = gate(), returned = gate();
    cleanups.push(async () => { release.resolve(); });
    vi.spyOn(f.devices, "authenticateAndAdmit").mockImplementation(async (_token, admit) => {
      entered.resolve(); await release.promise;
      const result = admit({ kind: "local" });
      returned.resolve();
      return result;
    });
    const peer = kind === "http"
      ? request({ host: "127.0.0.1", port: f.port, path: "/v1/blobs/fixture", agent: false, headers: { authorization: "Bearer fixture" } })
      : new WebSocket(`ws://127.0.0.1:${f.port}/v1/socket`, { headers: { authorization: "Bearer fixture" } });
    peer.on("error", () => {});
    if (!(peer instanceof WebSocket)) peer.end();
    await bounded(entered.promise, "authentication entry");
    const physicallyClosed = once(f.serverSockets[0]!, "close");
    if (peer instanceof WebSocket) peer.terminate(); else peer.destroy();
    await bounded(physicallyClosed, "exact server socket close");
    expect(await health(f.port)).toBe(503);
    release.resolve();
    await bounded(returned.promise, "authentication return");
    expect(await health(f.port)).toBe(200);
    expect(f.acquireBlob).not.toHaveBeenCalled();
  });

  it.each(["http", "upgrade", "upgrade-deadline"])("releases an abandoned %s auth wait while its credential owner remains blocked", async kind => {
    const f = await fixture(1);
    const ownerEntered = gate(), ownerRelease = gate(), authEntered = gate();
    const mutex = (f.devices as unknown as { mutex: AsyncMutex }).mutex;
    const owner = mutex.run(async () => { ownerEntered.resolve(); await ownerRelease.promise; });
    cleanups.push(async () => { ownerRelease.resolve(); await owner; });
    await bounded(ownerEntered.promise, "credential owner entry");
    let expireDeadline: (() => void) | undefined;
    if (kind === "upgrade-deadline") {
      const original = globalThis.setTimeout;
      const timer = vi.spyOn(globalThis, "setTimeout").mockImplementation(((callback: (...args: any[]) => void, delay: number, ...args: any[]) => {
        if (delay === HTTP_REQUEST_IDLE_TIMEOUT_MS) expireDeadline = () => callback(...args);
        return original(callback, delay, ...args);
      }) as typeof setTimeout);
      cleanups.push(async () => { timer.mockRestore(); });
    }
    const authenticate = f.devices.authenticateAndAdmit.bind(f.devices);
    vi.spyOn(f.devices, "authenticateAndAdmit").mockImplementation((...args) => {
      const result = authenticate(...args);
      authEntered.resolve();
      return result;
    });
    const peer = kind === "http"
      ? request({ host: "127.0.0.1", port: f.port, path: "/v1/blobs/fixture", agent: false, headers: { authorization: "Bearer fixture" } })
      : new WebSocket(`ws://127.0.0.1:${f.port}/v1/socket`, { headers: { authorization: "Bearer fixture" } });
    peer.on("error", () => {});
    if (!(peer instanceof WebSocket)) peer.end();
    await bounded(authEntered.promise, "queued authentication");
    const physicallyClosed = once(f.serverSockets[0]!, "close");
    if (kind === "upgrade-deadline") {
      expect(expireDeadline).toBeTypeOf("function");
      expireDeadline!();
    } else if (peer instanceof WebSocket) peer.terminate(); else peer.destroy();
    await bounded(physicallyClosed, "cancelled socket close");
    expect(await health(f.port)).toBe(200);
    expect((mutex as unknown as { waiting: Set<unknown> }).waiting.size).toBe(0);
    expect(f.acquireBlob).not.toHaveBeenCalled();
    ownerRelease.resolve();
    await owner;
    expect(f.acquireBlob).not.toHaveBeenCalled();
  });

  it("returns HTTP capacity while a bounded file acquire is held and releases its late lease", async () => {
    const f = await fixture(1);
    vi.spyOn(f.devices, "authenticateAndAdmit").mockImplementation(async (_token, admit) => admit({ kind: "local" }));
    const blobs = new BlobStore({ maximumItemBytes: 1_024, maximumItems: 2, maximumTotalBytes: 2_048, maximumReaders: 1 }, Date.now, join(f.root, "blobs"));
    await blobs.initialize();
    const source = join(f.root, "source.txt");
    await writeFile(source, "fixture");
    const id = await blobs.registerFile(source, "text/plain");
    const acquired = gate(), producerRelease = gate(), physicalRelease = gate();
    let didAcquire = false;
    const physical = blobs as unknown as { acquireOwned: BlobStore["acquire"] };
    const acquire = physical.acquireOwned.bind(blobs);
    vi.spyOn(physical, "acquireOwned").mockImplementation(async (...args) => {
      const lease = await acquire(...args);
      const release = lease.release;
      lease.release = async () => { await release(); physicalRelease.resolve(); };
      didAcquire = true;
      acquired.resolve();
      await producerRelease.promise;
      return lease;
    });
    f.acquireBlob.mockImplementation((id, range, signal) => blobs.acquire(id, range, signal));
    const peer = request({ host: "127.0.0.1", port: f.port, path: `/v1/blobs/${id}`, agent: false, headers: { authorization: "Bearer fixture" } });
    peer.on("error", () => {});
    cleanups.push(async () => {
      peer.destroy(); producerRelease.resolve();
      if (didAcquire) await bounded(physicalRelease.promise, "late physical lease cleanup");
      await blobs.dispose();
    });
    peer.end();
    await bounded(acquired.promise, "physical acquire entry");
    const closed = once(f.serverSockets[0]!, "close");
    peer.destroy();
    await bounded(closed, "abandoned response close");
    expect(await health(f.port)).toBe(200);
    await expect(blobs.acquire(id)).rejects.toMatchObject({ code: "busy" });
    producerRelease.resolve();
    await bounded(physicalRelease.promise, "late resource release");
    const next = await blobs.acquire(id);
    expect(next.size).toBe(7);
    await next.release();
  });

  it("bounds a pipelined pre-auth peer without starving another connection", async () => {
    const f = await fixture();
    const entered = gate(), release = gate();
    cleanups.push(async () => { release.resolve(); });
    const authenticate = vi.spyOn(f.devices, "authenticateAndAdmit").mockImplementation(async () => {
      if (authenticate.mock.calls.length === HTTP_MAXIMUM_REQUESTS_PER_CONNECTION) entered.resolve();
      await release.promise;
      return null;
    });
    const socket = createConnection({ host: "127.0.0.1", port: f.port });
    f.clientSockets.push(socket); socket.on("error", () => {});
    await bounded(once(socket, "connect"), "pipeline connect");
    const count = HTTP_MAXIMUM_REQUESTS_PER_CONNECTION + 1;
    const received = capture(socket, count);
    socket.write("GET /v1/blobs/fixture HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer fixture\r\n\r\n".repeat(count));
    await bounded(entered.promise, "bounded pipeline admission");
    expect(authenticate).toHaveBeenCalledTimes(HTTP_MAXIMUM_REQUESTS_PER_CONNECTION);
    expect(await health(f.port)).toBe(200);
    release.resolve();
    const wire = await received;
    expect(wire.match(/HTTP\/1\.1 401/g)).toHaveLength(HTTP_MAXIMUM_REQUESTS_PER_CONNECTION);
    expect(wire.match(/HTTP\/1\.1 503/g)).toHaveLength(1);
  });

  it("bounds unparsed sockets by source address and reuses physically released capacity", async () => {
    const f = await fixture();
    for (let index = 0; index < HTTP_MAXIMUM_CONNECTIONS_PER_ADDRESS; index++) {
      const socket = createConnection({ host: "127.0.0.1", port: f.port });
      f.clientSockets.push(socket); socket.on("error", () => {});
      await bounded(once(socket, "connect"), "held header connect");
    }
    const rejected = createConnection({ host: "127.0.0.1", port: f.port });
    f.clientSockets.push(rejected); rejected.on("error", () => {});
    await bounded(once(rejected, "close"), "one-over-address rejection");
    const first = f.clientSockets[0]!;
    const released = once(f.serverSockets[0]!, "close");
    const response = capture(first);
    first.write("GET /health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    expect(await response).toContain("HTTP/1.1 200");
    await bounded(released, "held socket release");
    expect(await health(f.port)).toBe(200);
  });
});
