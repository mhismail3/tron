import { once } from "node:events";
import { createServer, type Server } from "node:http";
import { createConnection, type AddressInfo, type Socket } from "node:net";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { DeviceStore } from "../security/device-store.js";
import { GatewayServer } from "./server.js";
import { awaitsWithin, HOOK_HANG_BOUND_MS, waitFor } from "../../test-support/wait-for.js";

// Real-clock request deadlines of the primary listener. The idle bound closes a
// request whose body stops arriving; the whole-request deadline closes one that
// keeps trickling bytes, which outlive the idle bound. Both are read from the
// accepted TCP socket's own close, with no fake clock and no production hook.
// This file runs in the nested pass (vitest.nested.config.ts): the trickle
// journey takes about five minutes of wall time at a few bytes per minute.

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
});

const sleep = (milliseconds: number) => new Promise<void>((resolve) => setTimeout(resolve, milliseconds));

async function startGateway() {
  const root = await mkdtemp(join(tmpdir(), "tron-request-deadline-"));
  const devices = new DeviceStore(root, "machine");
  await devices.initialize();
  const probe = createServer();
  await new Promise<void>((resolve) => probe.listen(0, "127.0.0.1", resolve));
  const port = (probe.address() as AddressInfo).port;
  await new Promise<void>((resolve) => probe.close(() => resolve()));
  const gateway = new GatewayServer({
    host: "127.0.0.1", port, maxFrameBytes: 16_384, devices, uploads: {} as any, sessions: {} as any,
    auth: {} as any, service: {} as any, logger: { log: () => {} } as any,
  });
  const serverSockets: Socket[] = [];
  (gateway as unknown as { server: Server }).server.on("connection", (socket) => serverSockets.push(socket));
  const peers: Socket[] = [];
  cleanups.push(async () => {
    for (const peer of peers) peer.destroy();
    try { await awaitsWithin(gateway.close(), "request deadline gateway close", HOOK_HANG_BOUND_MS); }
    finally { await rm(root, { recursive: true, force: true }); }
  });
  await gateway.listen();
  return { port, serverSockets, peers };
}

/** Opens one body-bearing request on the pairing route: `/v1/pair` reads its
 * body with no timer of its own, so only the transport's deadlines can end it. */
async function openUnfinishedBody(f: Awaited<ReturnType<typeof startGateway>>) {
  const peer = createConnection({ host: "127.0.0.1", port: f.port });
  peer.on("error", () => {});
  peer.on("data", () => {});
  f.peers.push(peer);
  await awaitsWithin(once(peer, "connect"), "request peer connect");
  peer.write("POST /v1/pair HTTP/1.1\r\nHost: fixture\r\nContent-Type: application/json\r\nContent-Length: 8192\r\n\r\n");
  const server = await waitFor(() => f.serverSockets[0], "accepted request socket");
  const closedAt = new Promise<number>((resolve) => server.once("close", () => resolve(Date.now())));
  return { peer, server, closedAt };
}

describe("primary listener request deadlines on real sockets", () => {
  it("closes a request whose body stops arriving at the idle bound", async () => {
    const f = await startGateway();
    const { peer, closedAt } = await openUnfinishedBody(f);
    peer.write("{");
    const started = Date.now();
    const closed = await awaitsWithin(closedAt, "idle body socket close", 45_000);
    // The idle bound is 30 s of silence; the close must not come early or late.
    expect(closed - started).toBeGreaterThanOrEqual(25_000);
    expect(closed - started).toBeLessThanOrEqual(40_000);
  }, 60_000);

  it("keeps a trickling request alive past the idle bound and closes it at the whole-request deadline", async () => {
    const f = await startGateway();
    const { peer, closedAt } = await openUnfinishedBody(f);
    let closed: number | undefined;
    void closedAt.then((at) => { closed = at; });
    const started = Date.now();
    let outlivedIdle = false;
    // One byte every 10 s: each byte resets the idle timer, so only the
    // whole-request deadline can end this request.
    while (closed === undefined && Date.now() - started < 340_000) {
      await sleep(10_000);
      if (closed === undefined) peer.write("a");
      if (closed === undefined && Date.now() - started >= 45_000) outlivedIdle = true;
    }
    expect(outlivedIdle, "the trickle must still be open past the 30 s idle bound").toBe(true);
    expect(closed, "the whole-request deadline must close the trickling request").toBeDefined();
    // The deadline is 300 s from the request's start; Node checks it on a
    // one-second cadence, so the close lands within a few seconds after it.
    expect(closed! - started).toBeGreaterThanOrEqual(280_000);
    expect(closed! - started).toBeLessThanOrEqual(335_000);
  }, 350_000);
});
