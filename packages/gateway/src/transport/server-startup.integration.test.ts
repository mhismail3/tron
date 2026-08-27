import { request } from "node:http";
import { connect } from "node:net";
import type { AddressInfo } from "node:net";
import { afterEach, describe, expect, it, vi } from "vitest";
import { GatewayServer } from "./server.js";

const servers: GatewayServer[] = [];
afterEach(async () => {
  await Promise.all(servers.splice(0).map((server) => server.close()));
});

function makeServer(overrides: {
  authenticate?: () => Promise<unknown>;
  invoke?: ReturnType<typeof vi.fn>;
} = {}): GatewayServer {
  return new GatewayServer({
    host: "127.0.0.1",
    port: 0,
    maxFrameBytes: 64 * 1_024,
    devices: { authenticate: overrides.authenticate ?? (async () => ({ id: "device" })) } as never,
    uploads: {} as never,
    sessions: { acquireBlob: async () => undefined } as never,
    auth: {} as never,
    service: {
      info: () => ({ gatewayVersion: "test", protocolVersion: 1, minProtocolVersion: 1 }),
      invoke: overrides.invoke ?? vi.fn(),
    } as never,
    logger: { log: () => {} } as never,
  });
}

async function portOf(server: GatewayServer): Promise<number> {
  const address = (server as unknown as { server: { address(): AddressInfo | null } }).server.address();
  if (!address) throw new Error("Gateway did not bind");
  return address.port;
}

function httpGet(port: number, path: string): Promise<{ status: number; body: Record<string, unknown> }> {
  return new Promise((resolve, reject) => {
    const outgoing = request({ host: "127.0.0.1", port, path }, (response) => {
      const chunks: Buffer[] = [];
      response.on("data", (chunk: Buffer) => chunks.push(chunk));
      response.on("end", () => resolve({
        status: response.statusCode ?? 0,
        body: JSON.parse(Buffer.concat(chunks).toString("utf8")) as Record<string, unknown>,
      }));
      response.on("error", reject);
    });
    outgoing.on("error", reject);
    outgoing.end();
  });
}

function httpPost(port: number, path: string): Promise<number> {
  return new Promise((resolve, reject) => {
    const outgoing = request({ host: "127.0.0.1", port, path, method: "POST" }, (response) => {
      response.resume();
      response.on("end", () => resolve(response.statusCode ?? 0));
      response.on("error", reject);
    });
    outgoing.on("error", reject);
    outgoing.end("{}");
  });
}

function websocketUpgrade(port: number): Promise<string> {
  return new Promise((resolve, reject) => {
    const socket = connect(port, "127.0.0.1", () => {
      socket.write("GET /v1/socket HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n");
    });
    let data = "";
    socket.on("data", (chunk) => {
      data += chunk.toString("utf8");
      if (data.includes("\r\n\r\n")) {
        socket.destroy();
        resolve(data);
      }
    });
    socket.on("error", reject);
  });
}

describe("Gateway startup readiness", () => {
  it("binds before warmup and exposes truthful phase transitions while APIs remain closed", async () => {
    const invoke = vi.fn();
    const authenticated = vi.fn(async () => ({ id: "device" }));
    const gateway = makeServer({ authenticate: authenticated, invoke });
    servers.push(gateway);
    let enteredCatalog!: () => void;
    let releaseCatalog!: () => void;
    let enteredAttention!: () => void;
    let releaseAttention!: () => void;
    let enteredStorage!: () => void;
    let releaseStorage!: () => void;
    const catalogEntered = new Promise<void>((resolve) => { enteredCatalog = resolve; });
    const catalog = new Promise<void>((resolve) => { releaseCatalog = resolve; });
    const attentionEntered = new Promise<void>((resolve) => { enteredAttention = resolve; });
    const attention = new Promise<void>((resolve) => { releaseAttention = resolve; });
    const storageEntered = new Promise<void>((resolve) => { enteredStorage = resolve; });
    const storage = new Promise<void>((resolve) => { releaseStorage = resolve; });
    const listening = gateway.listen(async () => {
      gateway.setStartupPhase("catalog-warming");
      enteredCatalog();
      await catalog;
      gateway.setStartupPhase("attention-recovery");
      enteredAttention();
      await attention;
      gateway.setStartupPhase("storage-warming");
      enteredStorage();
      await storage;
    });
    await catalogEntered;
    const port = await portOf(gateway);
    await expect(httpGet(port, "/health")).resolves.toMatchObject({ status: 503, body: { status: "catalog-warming" } });
    await expect(httpGet(port, "/v1/does-not-enter")).resolves.toMatchObject({ status: 503, body: { error: { code: "busy" } } });
    expect(await httpPost(port, "/v1/rpc")).toBe(503);
    expect(await websocketUpgrade(port)).toMatch(/^HTTP\/1\.1 503 Service Unavailable/);
    expect(authenticated).not.toHaveBeenCalled();
    expect(invoke).not.toHaveBeenCalled();
    releaseCatalog();
    await attentionEntered;
    await expect(httpGet(port, "/health")).resolves.toMatchObject({ status: 503, body: { status: "attention-recovery" } });
    releaseAttention();
    await storageEntered;
    await expect(httpGet(port, "/health")).resolves.toMatchObject({ status: 503, body: { status: "storage-warming" } });
    releaseStorage();
    await expect(listening).resolves.toBeUndefined();
    await expect(httpGet(port, "/health")).resolves.toMatchObject({ status: 200, body: { status: "ok" } });
  });

  it("closes the bound listener and never publishes ok when warmup fails", async () => {
    const gateway = makeServer();
    servers.push(gateway);
    let entered!: () => void;
    let release!: () => void;
    const warmupEntered = new Promise<void>((resolve) => { entered = resolve; });
    const failureGate = new Promise<void>((resolve) => { release = resolve; });
    const listening = gateway.listen(async () => {
      gateway.setStartupPhase("catalog-warming");
      entered();
      await failureGate;
      throw new Error("warmup failed");
    });
    await warmupEntered;
    const port = await portOf(gateway);
    await expect(httpGet(port, "/health")).resolves.toMatchObject({ status: 503, body: { status: "catalog-warming" } });
    release();
    await expect(listening).rejects.toThrow("warmup failed");
    await expect(httpGet(port, "/health")).rejects.toThrow();
  });
});
