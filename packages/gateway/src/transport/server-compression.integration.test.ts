import { createServer } from "node:http";
import type { Socket } from "node:net";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { deflateRawSync } from "node:zlib";
import WebSocket from "ws";
import { afterEach, describe, expect, it, vi } from "vitest";
import { DeviceStore } from "../security/device-store.js";
import { GatewayServer } from "./server.js";

// permessage-deflate is negotiated only for paired devices (see
// packages/gateway/docs/connection-resilience.md#frame-compression).
// Failure modes these cases target:
// - a local-credential (Mac app, CLI) socket starts receiving compressed frames;
// - a paired phone's offer, including Apple's parameterless one, is not
//   negotiated, or a paired client that does not offer it breaks;
// - server options reject a legal offer (for example server_no_context_takeover)
//   with a handshake error instead of connecting;
// - a small compressed inbound frame inflates past maxFrameBytes and is
//   admitted, because only its wire size was bounded;
// - the connection-opened record cannot tell compressed and uncompressed apart;
// - some send path hands ws (and so zlib) a frame over maxFrameBytes. URLSession
//   bounds only compressed bytes, so the Gateway's decoded ceiling is what
//   bounds a phone's allocation.

const MAXIMUM_FRAME_BYTES = 16_384;
// Highly compressible producer content: deflated it would fit the ceiling many
// times over, so only a decoded-size check can refuse it.
const OVERSIZED_CONTENT = "producer-content-".repeat(4 * MAXIMUM_FRAME_BYTES / 16);
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

async function waitUntil(predicate: () => boolean, label: string): Promise<void> {
  const deadline = Date.now() + 5_000;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error(`${label} timed out`);
    await new Promise((resolve) => setTimeout(resolve, 1));
  }
}

async function startGateway() {
  const root = await mkdtemp(join(tmpdir(), "tron-server-compression-"));
  const devices = new DeviceStore(root, "machine");
  await devices.initialize();
  const localToken = JSON.parse(await readFile(join(root, "gateway", "local-auth.json"), "utf8")).bearerToken as string;
  const pairedToken = (await devices.pair((await devices.ensureEnrollment()).code, "Phone")).token;
  const port = await unusedPort();
  const logger = { log: vi.fn() };
  const invoke = vi.fn(async (context: any, method: string, params: any) => {
    if (method === "session.open") {
      const syncToken = context.beginSynchronization(params.sessionId);
      context.establishSynchronization(params.sessionId, { runtimeGeneration: "generation", eventSequence: 1 });
      return { session: { sessionId: params.sessionId }, syncToken, subscriptionToken: syncToken };
    }
    if (method === "session.sync") {
      context.completeSynchronization(params.sessionId, params.syncToken);
      return { synchronized: true };
    }
    if (method === "test.oversized") return { transcript: OVERSIZED_CONTENT };
    return { method, padBytes: params.pad?.length ?? 0 };
  });
  const gateway = new GatewayServer({
    host: "127.0.0.1", port, maxFrameBytes: MAXIMUM_FRAME_BYTES, devices, logger: logger as any,
    uploads: {} as any,
    sessions: { subscribe: vi.fn(), unsubscribe: vi.fn(), unsubscribeClient: vi.fn() } as any,
    auth: { detachClient: vi.fn(), cancelOwner: vi.fn() } as any,
    service: {
      info: () => ({ gatewayVersion: "test", piVersion: "test", protocolVersion: 5, minProtocolVersion: 5, machineId: "machine", machineName: "test", capabilities: [] }),
      terminalBelongsToSession: () => false, releaseClient: vi.fn(), invoke,
    } as any,
  });
  await gateway.listen();
  const sockets: WebSocket[] = [];
  cleanups.push(async () => {
    for (const socket of sockets) if (socket.readyState !== WebSocket.CLOSED) socket.terminate();
    await gateway.close();
    await rm(root, { recursive: true, force: true });
  });

  const connect = async (token: string, perMessageDeflate: WebSocket.ClientOptions["perMessageDeflate"]) => {
    const socket = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, {
      headers: { authorization: `Bearer ${token}` }, perMessageDeflate,
    });
    sockets.push(socket);
    let transport: Socket | undefined;
    let negotiated: string | undefined;
    socket.once("upgrade", (response) => {
      transport = response.socket as Socket;
      negotiated = response.headers["sec-websocket-extensions"];
    });
    const frames: any[] = [];
    socket.on("message", (raw) => frames.push(JSON.parse(raw.toString())));
    await new Promise<void>((resolve, reject) => { socket.once("open", resolve); socket.once("error", reject); });
    socket.send(JSON.stringify({ type: "hello", protocolVersion: 5, clientRole: "mobile" }));
    await waitUntil(() => frames.some((frame) => frame.type === "hello"), "hello");
    const openedRecords = logger.log.mock.calls.filter((call) => call[2]?.event === "connection.opened");
    return { socket, frames, transport: () => transport!, negotiated, opened: openedRecords.at(-1)?.[1] as string };
  };

  // A highly compressible event just under maxFrameBytes: uncompressed it
  // cannot arrive in fewer bytes; compressed it needs a small fraction.
  const deliverLargeEvent = async (client: Awaited<ReturnType<typeof connect>>) => {
    const before = client.transport().bytesRead;
    const text = "compressible transcript text ".repeat(1_000).slice(0, 12 * 1_024);
    gateway.emitToClient(
      (logger.log.mock.calls.filter((call) => call[2]?.event === "connection.opened").at(-1)![2] as { connectionId: string }).connectionId,
      "test.large",
      { text },
    );
    await waitUntil(() => client.frames.some((frame) => frame.topic === "test.large"), "large event");
    expect(client.frames.find((frame) => frame.topic === "test.large")?.payload.text).toBe(text);
    return { wireBytes: client.transport().bytesRead - before, textBytes: text.length };
  };

  return { gateway, logger, invoke, localToken, pairedToken, connect, deliverLargeEvent };
}

function paddedRequest(id: string, totalBytes: number): string {
  const empty = JSON.stringify({ type: "request", id, method: "test.echo", params: { pad: "" } });
  const frame = JSON.stringify({ type: "request", id, method: "test.echo", params: { pad: "x".repeat(totalBytes - empty.length) } });
  expect(Buffer.byteLength(frame)).toBe(totalBytes);
  return frame;
}

describe("WebSocket frame compression", () => {
  it("keeps local-credential clients uncompressed even when they offer permessage-deflate", async () => {
    const fixture = await startGateway();
    const local = await fixture.connect(fixture.localToken, true);
    expect(local.socket.extensions).toBe("");
    expect(local.opened).toContain("(local, mobile role, compression=none)");
    const delivered = await fixture.deliverLargeEvent(local);
    expect(delivered.wireBytes).toBeGreaterThan(delivered.textBytes);
  });

  it("negotiates Apple's parameterless offer from a paired client and compresses its frames", async () => {
    const fixture = await startGateway();
    // clientMaxWindowBits false makes ws offer exactly `permessage-deflate`,
    // the header URLSessionWebSocketTask sends.
    const paired = await fixture.connect(fixture.pairedToken, { clientMaxWindowBits: false });
    expect(paired.negotiated).toBe("permessage-deflate");
    expect(paired.opened).toContain("(paired, mobile role, compression=permessage-deflate)");
    const delivered = await fixture.deliverLargeEvent(paired);
    expect(delivered.wireBytes).toBeLessThan(delivered.textBytes / 20);
  });

  it("keeps paired clients that do not offer the extension on uncompressed frames", async () => {
    const fixture = await startGateway();
    const paired = await fixture.connect(fixture.pairedToken, false);
    expect(paired.socket.extensions).toBe("");
    expect(paired.opened).toContain("(paired, mobile role, compression=none)");
    const delivered = await fixture.deliverLargeEvent(paired);
    expect(delivered.wireBytes).toBeGreaterThan(delivered.textBytes);
  });

  it("accepts a paired client's request for server_no_context_takeover instead of rejecting the upgrade", async () => {
    const fixture = await startGateway();
    const paired = await fixture.connect(fixture.pairedToken, { serverNoContextTakeover: true });
    expect(paired.negotiated).toBe("permessage-deflate; server_no_context_takeover");
    const delivered = await fixture.deliverLargeEvent(paired);
    expect(delivered.wireBytes).toBeLessThan(delivered.textBytes / 20);
  });

  it.each([
    ["local uncompressed", "local", false],
    ["paired compressed", "paired", { clientMaxWindowBits: false }],
  ] as const)("bounds a %s inbound message by its decoded size", async (_label, credential, perMessageDeflate) => {
    const fixture = await startGateway();
    const client = await fixture.connect(credential === "local" ? fixture.localToken : fixture.pairedToken, perMessageDeflate);
    expect(client.socket.extensions).toBe(credential === "local" ? "" : "permessage-deflate");

    client.socket.send(paddedRequest("at-limit", MAXIMUM_FRAME_BYTES));
    await waitUntil(() => client.frames.some((frame) => frame.id === "at-limit"), "at-limit response");
    expect(client.frames.find((frame) => frame.id === "at-limit")).toMatchObject({ ok: true });

    // Compressed, the over-limit message is a few dozen bytes on the wire, so
    // only a bound on its inflated size can reject it.
    const overLimit = paddedRequest("over-limit", MAXIMUM_FRAME_BYTES + 1);
    expect(deflateRawSync(overLimit).length).toBeLessThan(1_024);
    const closed = new Promise<number>((resolve) => client.socket.once("close", (code) => resolve(code)));
    client.socket.send(overLimit);
    expect(await closed).toBe(1009);
    expect(fixture.invoke.mock.calls.map((call) => call[1])).toEqual(["test.echo"]);
    expect(client.frames.some((frame) => frame.id === "over-limit")).toBe(false);
  });
});

describe("decoded outbound ceiling on every send path", () => {
  it.each([
    ["local uncompressed", "local", false],
    ["paired compressed", "paired", { clientMaxWindowBits: false }],
  ] as const)("refuses an over-ceiling payload before ws sees it for a %s client", async (_label, credential, perMessageDeflate) => {
    const fixture = await startGateway();
    const client = await fixture.connect(credential === "local" ? fixture.localToken : fixture.pairedToken, perMessageDeflate);
    expect(client.socket.extensions).toBe(credential === "local" ? "" : "permessage-deflate");
    const connection = [...(fixture.gateway as any).clients.values()][0];
    // Every string handed to ws is what zlib would deflate for this socket.
    const handedToWs: string[] = [];
    const send = connection.socket.send.bind(connection.socket);
    vi.spyOn(connection.socket, "send").mockImplementation((data: any, ...rest: any[]) => {
      handedToWs.push(String(data));
      return send(data, ...rest);
    });
    const request = async (id: string, method: string, params: Record<string, unknown>) => {
      client.socket.send(JSON.stringify({ type: "request", id, method, params }));
      await waitUntil(() => client.frames.some((frame) => frame.id === id), id);
      return client.frames.find((frame) => frame.id === id);
    };
    const resyncs = () => client.frames.filter((frame) => frame.topic === "transport.resyncRequired");

    // Direct response.
    expect(await request("response", "test.oversized", {})).toMatchObject({ ok: false, error: { code: "response_too_large" } });
    // emitToClient.
    fixture.gateway.emitToClient(connection.id, "test.direct", { transcript: OVERSIZED_CONTENT });
    await waitUntil(() => resyncs().length === 1, "direct event fallback");
    // Global broadcast (one prepared frame shared by every client).
    fixture.gateway.broadcast("test.global", { transcript: OVERSIZED_CONTENT });
    await waitUntil(() => resyncs().length === 2, "global broadcast fallback");
    // Session broadcast buffered by the synchronization barrier, then replayed.
    const opened = await request("open", "session.open", { sessionId: "session" });
    fixture.gateway.broadcastSession("session", "session.snapshot", { transcript: OVERSIZED_CONTENT });
    expect(resyncs()).toHaveLength(2);
    await request("sync", "session.sync", { sessionId: "session", syncToken: opened.result.syncToken });
    await waitUntil(() => resyncs().length === 3, "barrier replay fallback");
    // Session broadcast to a synchronized subscriber.
    fixture.gateway.broadcastSession("session", "session.snapshot", { transcript: OVERSIZED_CONTENT });
    await waitUntil(() => resyncs().length === 4, "session broadcast fallback");

    expect(resyncs().map((frame) => frame.sessionId)).toEqual([undefined, undefined, "session", "session"]);
    expect(client.socket.readyState).toBe(WebSocket.OPEN);
    expect(handedToWs).toHaveLength(7); // two responses to open/sync plus the five refused payloads
    expect(Math.max(...handedToWs.map((frame) => Buffer.byteLength(frame)))).toBeLessThanOrEqual(MAXIMUM_FRAME_BYTES);
    expect(handedToWs.some((frame) => frame.includes("producer-content"))).toBe(false);
  });
});
