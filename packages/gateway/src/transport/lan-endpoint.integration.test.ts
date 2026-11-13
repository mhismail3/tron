import { once } from "node:events";
import { request as httpsRequest } from "node:https";
import { request as httpRequest } from "node:http";
import { createConnection, createServer as createTcpServer } from "node:net";
import { connect as tlsConnect, type TLSSocket } from "node:tls";
import type { Duplex } from "node:stream";
import type { IncomingMessage, ServerResponse } from "node:http";
import { stat, mkdtemp, readFile, rm, writeFile, mkdir } from "node:fs/promises";
import { generateKeyPairSync, X509Certificate } from "node:crypto";
import { tmpdir } from "node:os";
import { join } from "node:path";
import WebSocket from "ws";
import { afterEach, describe, expect, it, vi } from "vitest";
import { DeviceStore } from "../security/device-store.js";
import { GatewayServer, HTTP_HEADERS_TIMEOUT_MS, HTTP_LISTENER_LIMITS } from "./server.js";
import { LanEndpoint, lanPin, selfSignedCertificate } from "./lan-endpoint.js";
import type { LanAddress } from "../config.js";
import { PROTOCOL_VERSION } from "../version.js";
import { awaitsWithin, waitFor } from "../../test-support/wait-for.js";

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => {
  const failures: unknown[] = [];
  for (const cleanup of cleanups.splice(0).reverse()) {
    try { await cleanup(); } catch (error) { failures.push(error); }
  }
  if (failures.length) throw new AggregateError(failures, "fixture cleanup failed");
});

const RECONCILE_SETTLE_MS = 150;

async function unusedPort(): Promise<number> {
  const probe = createTcpServer();
  await new Promise<void>((resolve) => probe.listen(0, "127.0.0.1", resolve));
  const address = probe.address();
  if (address === null || typeof address === "string") throw new Error("probe did not bind");
  await new Promise<void>((resolve) => probe.close(() => resolve()));
  return address.port;
}

async function tempRoot(prefix: string): Promise<string> {
  const created = await mkdtemp(join(tmpdir(), prefix));
  cleanups.push(() => rm(created, { recursive: true, force: true }));
  return created;
}

interface LoggedRecord {
  level: string;
  message: string;
  fields: Record<string, unknown>;
}

function messageFields(message: string): Record<string, string> {
  return Object.fromEntries([...message.matchAll(/([A-Za-z][A-Za-z0-9]*)=([^\s);]+)/gu)].map((match) => [match[1]!, match[2]!]));
}

function records(log: ReturnType<typeof vi.fn>, event: string): LoggedRecord[] {
  return log.mock.calls.flatMap((call) => call[2]?.event === event
    ? [{ level: call[0] as string, message: call[1] as string, fields: call[2] as Record<string, unknown> }]
    : []);
}

async function waitForRecord(log: ReturnType<typeof vi.fn>, event: string, field: string, value: string): Promise<LoggedRecord> {
  return waitFor(() => records(log, event).find((record) => messageFields(record.message)[field] === value), `${event} with ${field}=${value}`);
}

interface Response {
  status: number;
  body: Record<string, unknown>;
}

function receive(incoming: IncomingMessage, resolve: (response: Response) => void, reject: (error: unknown) => void): void {
  const chunks: Buffer[] = [];
  incoming.on("data", (chunk: Buffer) => chunks.push(chunk));
  incoming.once("error", reject);
  incoming.once("end", () => {
    const text = Buffer.concat(chunks).toString("utf8");
    resolve({ status: incoming.statusCode ?? 0, body: text === "" ? {} : JSON.parse(text) as Record<string, unknown> });
  });
}

async function lanRequest(host: string, port: number, path: string, certificate: string, init: { method?: string; body?: string; bearer?: string } = {}): Promise<Response> {
  return awaitsWithin(new Promise((resolve, reject) => {
    const outgoing = httpsRequest({
      host, port, path, method: init.method ?? "GET", agent: false,
      ca: certificate, checkServerIdentity: () => undefined,
      headers: {
        ...(init.body === undefined ? {} : { "content-type": "application/json", "content-length": Buffer.byteLength(init.body) }),
        ...(init.bearer === undefined ? {} : { authorization: `Bearer ${init.bearer}` }),
      },
    }, (incoming) => receive(incoming, resolve, reject));
    outgoing.once("error", reject);
    outgoing.end(init.body);
  }), `LAN request ${path}`);
}

async function tlsReaches(host: string, port: number): Promise<boolean> {
  return awaitsWithin(new Promise<boolean>((resolve) => {
    const socket = tlsConnect({ host, port, rejectUnauthorized: false });
    socket.once("secureConnect", () => { socket.destroy(); resolve(true); });
    socket.once("error", () => resolve(false));
  }), "TLS probe");
}

async function openTls(host: string, port: number): Promise<TLSSocket> {
  const socket = tlsConnect({ host, port, rejectUnauthorized: false });
  await awaitsWithin(new Promise<void>((resolve, reject) => { socket.once("secureConnect", resolve); socket.once("error", reject); }), "TLS connect");
  return socket;
}

async function plainHttp(host: string, port: number, path: string, method = "GET", body?: string): Promise<Response | null> {
  return awaitsWithin(new Promise<Response | null>((resolve, reject) => {
    const outgoing = httpRequest({
      host, port, path, method, agent: false,
      ...(body === undefined ? {} : { headers: { "content-type": "application/json", "content-length": Buffer.byteLength(body) } }),
    }, (incoming) => receive(incoming, resolve, reject));
    outgoing.once("error", () => resolve(null));
    outgoing.end(body);
  }), `HTTP ${method} ${path}`);
}

const RESPONDING_HANDLERS = {
  onConnection: () => {},
  onSecureConnection: () => {},
  onClientError: (_error: Error, socket: Duplex) => { socket.destroy(); },
  onTlsClientError: () => {},
  onRequest: (_request: IncomingMessage, response: ServerResponse) => {
    response.writeHead(200, { "content-type": "application/json" });
    response.end("{}");
  },
  onUpgrade: () => {},
};

interface EndpointFixture {
  log: ReturnType<typeof vi.fn>;
  stateDirectory: string;
  port: number;
}

async function endpointFixture(prefix: string, addresses: LanAddress[], handlers: { onConnection?: (socket: Duplex) => void } = {}): Promise<EndpointFixture & { endpoint: LanEndpoint; addresses: LanAddress[] }> {
  const home = await tempRoot(prefix);
  const stateDirectory = join(home, "lan-endpoint");
  const port = await unusedPort();
  const log = { log: vi.fn() };
  const endpoint = new LanEndpoint({
    enabled: true, stateDirectory, port, logger: log as never,
    listenerLimits: HTTP_LISTENER_LIMITS,
    lanAddresses: () => [...addresses],
    reconcileIntervalMs: 25,
    ...RESPONDING_HANDLERS,
    ...(handlers.onConnection === undefined ? {} : { onConnection: handlers.onConnection }),
  });
  await endpoint.start();
  cleanups.push(() => endpoint.stop());
  return { log: log.log, stateDirectory, port, endpoint, addresses };
}

interface GatewayFixture {
  root: string;
  log: ReturnType<typeof vi.fn>;
  stateDirectory: string;
  addresses: LanAddress[];
  gateway: GatewayServer;
  devices: DeviceStore;
  port: number;
}

async function gatewayFixture(options: { enabled?: boolean } = {}): Promise<GatewayFixture> {
  const home = await tempRoot("tron-lan-gateway-");
  const devices = new DeviceStore(home, "fixture-machine");
  await devices.initialize();
  const addresses: LanAddress[] = [{ address: "::1", family: "IPv6" }];
  const log = { log: vi.fn() };
  const port = await unusedPort();
  const gateway = new GatewayServer({ display: {} as never,
    host: "127.0.0.1", port, maxFrameBytes: 64 * 1_024, devices,
    uploads: {} as never,
    sessions: { unsubscribeClient: vi.fn() } as never,
    auth: { detachClient: vi.fn(), cancelOwner: vi.fn() } as never,
    service: { info: () => ({ protocolVersion: PROTOCOL_VERSION }), releaseClient: vi.fn() } as never,
    logger: log as never,
    lanEndpoint: {
      enabled: options.enabled ?? true,
      stateDirectory: join(home, "state", "lan-endpoint"),
      lanAddresses: () => [...addresses],
      reconcileIntervalMs: 25,
    },
  });
  await gateway.listen();
  cleanups.push(() => gateway.close());
  return { root: home, log: log.log, stateDirectory: join(home, "state", "lan-endpoint"), addresses, gateway, devices, port };
}

function gatewayHello(socket: WebSocket): Promise<Record<string, unknown>> {
  return awaitsWithin(new Promise((resolve) => {
    socket.once("message", (data: Buffer) => resolve(JSON.parse(data.toString("utf8")) as Record<string, unknown>));
  }), "gateway hello frame");
}

async function localToken(home: string): Promise<string> {
  return (JSON.parse(await readFile(join(home, "state", "local-auth.json"), "utf8")) as { bearerToken: string }).bearerToken;
}

describe("LAN endpoint", () => {
  it("creates one key and certificate pair at 0600 and reuses it across a restart", async () => {
    const fixture = await endpointFixture("tron-lan-pair-", [{ address: "127.0.0.1", family: "IPv4" }]);
    const bound = messageFields((await waitForRecord(fixture.log, "lan.listener", "state", "bound")).message);
    expect(bound).toMatchObject({ family: "IPv4", port: String(fixture.port) });
    expect(records(fixture.log, "lan.listener")[0]!.message).not.toContain("127.0.0.1");

    const keyPath = join(fixture.stateDirectory, "tls-key.pem");
    const certificatePath = join(fixture.stateDirectory, "tls-certificate.pem");
    const [key, certificate] = await Promise.all([readFile(keyPath, "utf8"), readFile(certificatePath, "utf8")]);
    expect((await stat(keyPath)).mode & 0o777).toBe(0o600);
    expect((await stat(certificatePath)).mode & 0o777).toBe(0o600);
    expect(key).toContain("BEGIN PRIVATE KEY");
    expect(certificate).toContain("BEGIN CERTIFICATE");
    expect((await lanRequest("127.0.0.1", fixture.port, "/health", certificate)).status).toBe(200);

    await fixture.endpoint.stop();
    const restarted = new LanEndpoint({
      enabled: true, stateDirectory: fixture.stateDirectory, port: fixture.port, logger: { log: vi.fn() } as never,
      listenerLimits: HTTP_LISTENER_LIMITS,
      lanAddresses: () => [{ address: "127.0.0.1", family: "IPv4" }],
      ...RESPONDING_HANDLERS,
    });
    await restarted.start();
    cleanups.push(() => restarted.stop());
    expect(await readFile(keyPath, "utf8")).toBe(key);
    expect(await readFile(certificatePath, "utf8")).toBe(certificate);
    expect((await lanRequest("127.0.0.1", fixture.port, "/health", certificate)).status).toBe(200);
  });

  it("generates certificates OpenSSL reads back", async () => {
    const { privateKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
    for (let index = 0; index < 4096; index++) {
      expect(() => new X509Certificate(selfSignedCertificate(privateKey, "fixture"))).not.toThrow();
    }
  });

  it("refuses a half-present, unreadable or mismatched pair without overwriting it", async () => {
    const home = await tempRoot("tron-lan-bad-pair-");
    const pinned = generateKeyPairSync("ec", { namedCurve: "prime256v1" }).privateKey;
    const other = generateKeyPairSync("ec", { namedCurve: "prime256v1" }).privateKey;
    const cases = [
      {
        reason: "certificate_incomplete",
        files: { certificate: selfSignedCertificate(pinned, "fixture") },
      },
      {
        reason: "certificate_unreadable",
        files: {
          key: pinned.export({ type: "pkcs8", format: "pem" }).toString(),
          certificate: "-----BEGIN CERTIFICATE-----\nnot base64\n-----END CERTIFICATE-----\n",
        },
      },
      {
        reason: "certificate_mismatched",
        files: {
          key: pinned.export({ type: "pkcs8", format: "pem" }).toString(),
          certificate: selfSignedCertificate(other, "fixture"),
        },
      },
    ];
    for (const testCase of cases) {
      const stateDirectory = join(home, testCase.reason);
      await mkdir(stateDirectory, { recursive: true, mode: 0o700 });
      const keyPath = join(stateDirectory, "tls-key.pem");
      const certificatePath = join(stateDirectory, "tls-certificate.pem");
      if (testCase.files.key !== undefined) await writeFile(keyPath, testCase.files.key, { mode: 0o600 });
      if (testCase.files.certificate !== undefined) await writeFile(certificatePath, testCase.files.certificate, { mode: 0o600 });
      const port = await unusedPort();
      const log = { log: vi.fn() };
      const endpoint = new LanEndpoint({
        enabled: true, stateDirectory, port, logger: log as never,
        listenerLimits: HTTP_LISTENER_LIMITS,
        ...RESPONDING_HANDLERS,
        lanAddresses: () => [{ address: "127.0.0.1", family: "IPv4" }],
      });
      await endpoint.start();
      cleanups.push(() => endpoint.stop());
      const disabled = await waitForRecord(log.log, "lan.listener", "state", "disabled");
      expect(disabled.fields.reason).toBe(testCase.reason);
      expect(disabled.level).toBe("warning");
      expect(await tlsReaches("127.0.0.1", port)).toBe(false);
      expect(records(log.log, "lan.listener")).toHaveLength(1);
      if (testCase.files.key !== undefined) expect(await readFile(keyPath, "utf8")).toBe(testCase.files.key);
      if (testCase.files.certificate !== undefined) expect(await readFile(certificatePath, "utf8")).toBe(testCase.files.certificate);
    }
  });

  it("completes a key left without its certificate from that key, keeping the pin", async () => {
    const home = await tempRoot("tron-lan-key-only-");
    const stored = generateKeyPairSync("ec", { namedCurve: "prime256v1" }).privateKey;
    const storedKey = stored.export({ type: "pkcs8", format: "pem" }).toString();
    const stateDirectory = join(home, "state");
    await mkdir(stateDirectory, { recursive: true, mode: 0o700 });
    const keyPath = join(stateDirectory, "tls-key.pem");
    const certificatePath = join(stateDirectory, "tls-certificate.pem");
    await writeFile(keyPath, storedKey, { mode: 0o600 });
    const port = await unusedPort();
    const log = { log: vi.fn() };
    const endpoint = new LanEndpoint({
      enabled: true, stateDirectory, port, logger: log as never,
      listenerLimits: HTTP_LISTENER_LIMITS,
      ...RESPONDING_HANDLERS,
      lanAddresses: () => [{ address: "127.0.0.1", family: "IPv4" }],
    });
    await endpoint.start();
    cleanups.push(() => endpoint.stop());
    await waitForRecord(log.log, "lan.listener", "state", "bound");
    expect(await readFile(keyPath, "utf8")).toBe(storedKey);
    const certificate = await readFile(certificatePath, "utf8");
    expect(lanPin(certificate)).toBe(lanPin(selfSignedCertificate(stored, "fixture")));
    expect(await tlsReaches("127.0.0.1", port)).toBe(true);
  });

  it("binds only the first of two private addresses, moves when it changes, and disables once when none is left", async () => {
    const accepted: Array<{ closed: boolean }> = [];
    const fixture = await endpointFixture("tron-lan-rebind-", [
      { address: "127.0.0.1", family: "IPv4" },
      { address: "::1", family: "IPv6" },
    ], {
      onConnection: (socket) => {
        const observation = { closed: false };
        accepted.push(observation);
        socket.once("close", () => { observation.closed = true; });
      },
    });
    expect(messageFields((await waitForRecord(fixture.log, "lan.listener", "state", "bound")).message))
      .toMatchObject({ family: "IPv4", port: String(fixture.port) });
    expect(await tlsReaches("127.0.0.1", fixture.port)).toBe(true);
    expect(await tlsReaches("::1", fixture.port)).toBe(false);
    const held = await openTls("127.0.0.1", fixture.port);
    const observation = await waitFor(() => accepted.find((entry) => !entry.closed), "accepted LAN socket");

    fixture.addresses.shift();
    const rebound = await waitForRecord(fixture.log, "lan.listener", "state", "rebound");
    expect(messageFields(rebound.message)).toMatchObject({ family: "IPv6", port: String(fixture.port) });
    await waitFor(() => observation.closed ? true : undefined, "retired LAN socket");
    expect(held.destroyed).toBe(true);
    expect(await tlsReaches("127.0.0.1", fixture.port)).toBe(false);
    expect(await tlsReaches("::1", fixture.port)).toBe(true);

    fixture.addresses.length = 0;
    expect((await waitForRecord(fixture.log, "lan.listener", "state", "disabled")).fields.reason).toBe("no_private_address");
    await new Promise((resolve) => setTimeout(resolve, RECONCILE_SETTLE_MS));
    expect(records(fixture.log, "lan.listener").filter((record) => record.fields.reason === "no_private_address")).toHaveLength(1);
  });

  it("records one disable for an address this host cannot bind", async () => {
    const fixture = await endpointFixture("tron-lan-bind-failure-", [{ address: "10.255.255.1", family: "IPv4" }]);
    const disabled = await waitForRecord(fixture.log, "lan.listener", "state", "disabled");
    expect(disabled.fields.reason).toBe("bind_failed");
    expect(disabled.level).toBe("warning");
    await new Promise((resolve) => setTimeout(resolve, RECONCILE_SETTLE_MS));
    expect(records(fixture.log, "lan.listener").filter((record) => record.fields.reason === "bind_failed")).toHaveLength(1);
  });

  it("serves the lane's socket and health routes through the transport and never pairing", async () => {
    const fixture = await gatewayFixture();
    expect(messageFields((await waitForRecord(fixture.log, "lan.listener", "state", "bound")).message))
      .toMatchObject({ family: "IPv6", port: String(fixture.port) });
    const certificate = await readFile(join(fixture.stateDirectory, "tls-certificate.pem"), "utf8");
    expect(await lanRequest("::1", fixture.port, "/health", certificate)).toEqual({ status: 200, body: { status: "ok" } });
    expect(await plainHttp("::1", fixture.port, "/health")).toBeNull();
    const primaryHealth = await plainHttp("127.0.0.1", fixture.port, "/health");
    expect(primaryHealth?.status).toBe(200);
    expect(primaryHealth?.body.protocolVersion).toBe(PROTOCOL_VERSION);

    expect((await plainHttp("127.0.0.1", fixture.port, "/v1/pair", "POST", "{}"))?.status).toBe(400);
    expect((await lanRequest("::1", fixture.port, "/v1/pair", certificate, { method: "POST", body: "{}" })).status).toBe(404);
    expect((await lanRequest("::1", fixture.port, "/v1/blobs/unknown", certificate)).status).toBe(401);

    const token = await localToken(fixture.root);
    const hello = JSON.stringify({ type: "hello", protocolVersion: PROTOCOL_VERSION, diagnostics: { clientId: "fixture", attemptId: "lan", epoch: "1" } });
    const socket = new WebSocket(`wss://[::1]:${fixture.port}/v1/socket`, { headers: { authorization: `Bearer ${token}` }, rejectUnauthorized: false });
    cleanups.push(async () => { socket.terminate(); });
    await awaitsWithin(new Promise<void>((resolve, reject) => { socket.once("open", resolve); socket.once("error", reject); }), "LAN socket open");
    socket.send(hello);
    const opened = await waitFor(() => records(fixture.log, "http.upgrade").find((record) => record.fields.outcome === "opened"), "lane upgrade opened");
    expect(opened.fields.transport).toBe("lan");
    await waitFor(() => records(fixture.log, "connection.opened").length === 1 ? true : undefined, "lane hello admitted");

    const primary = new WebSocket(`ws://127.0.0.1:${fixture.port}/v1/socket`, { headers: { authorization: `Bearer ${token}` } });
    cleanups.push(async () => { primary.terminate(); });
    await awaitsWithin(new Promise<void>((resolve, reject) => { primary.once("open", resolve); primary.once("error", reject); }), "primary socket open");
    primary.send(hello);
    const primaryOpened = await waitFor(() => records(fixture.log, "http.upgrade").filter((record) => record.fields.outcome === "opened")[1], "primary upgrade opened");
    expect(primaryOpened.fields.transport).toBe("primary");
  });

  it("advertises the lane's endpoint and pin over pairing and hello and nowhere else", async () => {
    const fixture = await gatewayFixture();
    await waitForRecord(fixture.log, "lan.listener", "state", "bound");
    const certificate = await readFile(join(fixture.stateDirectory, "tls-certificate.pem"), "utf8");
    const frozen = JSON.parse(await readFile(
      new URL("../../../protocol-fixtures/lan-endpoint-pin.json", import.meta.url), "utf8")) as { certificatePem: string; pin: string };
    expect(lanPin(frozen.certificatePem)).toBe(frozen.pin);
    const expectedPin = lanPin(certificate);
    const expectedEndpoints = [{ host: "::1", port: fixture.port }];

    const enrollment = await fixture.devices.ensureEnrollment();
    const paired = await plainHttp("127.0.0.1", fixture.port, "/v1/pair", "POST",
      JSON.stringify({ code: enrollment.code, deviceName: "fixture phone" }));
    expect(paired?.status).toBe(200);
    expect(paired?.body.lanEndpoints).toEqual(expectedEndpoints);
    expect(paired?.body.lanPin).toBe(expectedPin);

    const primaryHealth = await plainHttp("127.0.0.1", fixture.port, "/health");
    expect(primaryHealth?.status).toBe(200);
    expect(Object.keys(primaryHealth?.body ?? {})).not.toContain("lanEndpoints");
    expect(Object.keys(primaryHealth?.body ?? {})).not.toContain("lanPin");
    expect(await lanRequest("::1", fixture.port, "/health", certificate))
      .toEqual({ status: 200, body: { status: "ok" } });

    const token = await localToken(fixture.root);
    for (const url of [`wss://[::1]:${fixture.port}/v1/socket`, `ws://127.0.0.1:${fixture.port}/v1/socket`]) {
      const socket = new WebSocket(url, { headers: { authorization: `Bearer ${token}` }, rejectUnauthorized: false });
      cleanups.push(async () => { socket.terminate(); });
      await awaitsWithin(new Promise<void>((resolve, reject) => { socket.once("open", resolve); socket.once("error", reject); }), "socket open");
      socket.send(JSON.stringify({ type: "hello", protocolVersion: PROTOCOL_VERSION, diagnostics: { clientId: "fixture", attemptId: "advertise", epoch: "1" } }));
      expect(await gatewayHello(socket)).toMatchObject({
        type: "hello", lanEndpoints: expectedEndpoints, lanPin: expectedPin,
      });
      socket.terminate();
    }
  });

  it("advertises no endpoint while the setting is off, so a phone stops dialling the lane", async () => {
    const fixture = await gatewayFixture({ enabled: false });
    expect((await waitForRecord(fixture.log, "lan.listener", "state", "disabled")).fields.reason).toBe("setting_off");
    const token = await localToken(fixture.root);
    const socket = new WebSocket(`ws://127.0.0.1:${fixture.port}/v1/socket`, { headers: { authorization: `Bearer ${token}` } });
    cleanups.push(async () => { socket.terminate(); });
    await awaitsWithin(new Promise<void>((resolve, reject) => { socket.once("open", resolve); socket.once("error", reject); }), "primary socket open");
    socket.send(JSON.stringify({ type: "hello", protocolVersion: PROTOCOL_VERSION, diagnostics: { clientId: "fixture", attemptId: "off", epoch: "1" } }));
    const hello = await gatewayHello(socket);
    expect(hello.lanEndpoints).toEqual([]);
    expect(Object.keys(hello)).not.toContain("lanPin");
  });

  it("records one failed TLS connection and no unused record for a healthy LAN probe", async () => {
    const fixture = await gatewayFixture();
    await waitForRecord(fixture.log, "lan.listener", "state", "bound");
    expect(await plainHttp("::1", fixture.port, "/private-fixture-content")).toBeNull();
    await waitFor(() => records(fixture.log, "http.connection-unused")[0], "failed TLS record");
    const unused = records(fixture.log, "http.connection-unused");
    expect(unused).toHaveLength(1);
    expect(unused[0]!.fields).toMatchObject({ transport: "lan", reason: "tls_error", code: "ERR_SSL_HTTP_REQUEST" });
    expect(JSON.stringify(unused)).not.toContain("private-fixture-content");
    const certificate = await readFile(join(fixture.stateDirectory, "tls-certificate.pem"), "utf8");
    expect((await lanRequest("::1", fixture.port, "/health", certificate)).status).toBe(200);
    await fixture.gateway.close();
    expect(records(fixture.log, "http.connection-unused")).toHaveLength(1);
  });

  it("bounds a lane peer at the main listener's handshake and header limits", async () => {
    const fixture = await gatewayFixture();
    await waitForRecord(fixture.log, "lan.listener", "state", "bound");
    const bare = createConnection({ host: "::1", port: fixture.port });
    cleanups.push(async () => { bare.destroy(); });
    const partial = await openTls("::1", fixture.port);
    cleanups.push(async () => { partial.destroy(); });
    const answered = new Promise<string>((resolve, reject) => {
      partial.once("data", (chunk: Buffer) => resolve(chunk.toString("utf8")));
      partial.once("error", reject);
    });
    partial.write("GET /health HTTP/1.1\r\nHost: localhost\r\n");
    await awaitsWithin(Promise.all([once(bare, "close"), answered]),
      "lane admission bound", HTTP_HEADERS_TIMEOUT_MS + 15_000);
    expect(await answered).toContain("408");
    await waitFor(() => records(fixture.log, "http.connection-unused").length === 2, "both unused LAN peers recorded");
    const unused = records(fixture.log, "http.connection-unused");
    expect(unused.map(record => record.fields.code).sort()).toEqual(["ERR_HTTP_REQUEST_TIMEOUT", "ERR_TLS_HANDSHAKE_TIMEOUT"]);
    expect(unused.every(record => record.fields.transportEnd === "timeout")).toBe(true);
  }, 45_000);

  it("dates a lane upgrade from the TCP accept, so the record shows the TLS handshake", async () => {
    const fixture = await gatewayFixture();
    await waitForRecord(fixture.log, "lan.listener", "state", "bound");
    const token = await localToken(fixture.root);
    const handed = await openTls("::1", fixture.port);
    cleanups.push(async () => { handed.destroy(); });
    await new Promise((resolve) => setTimeout(resolve, 300));
    const socket = new WebSocket(`wss://[::1]:${fixture.port}/v1/socket`, {
      headers: { authorization: `Bearer ${token}` },
      rejectUnauthorized: false,
      createConnection: () => handed,
    });
    cleanups.push(async () => { socket.terminate(); });
    await awaitsWithin(new Promise<void>((resolve, reject) => { socket.once("open", resolve); socket.once("error", reject); }), "handed lane upgrade open");
    socket.send(JSON.stringify({ type: "hello", protocolVersion: PROTOCOL_VERSION, diagnostics: { clientId: "fixture", attemptId: "accept", epoch: "1" } }));
    const opened = await waitFor(() => records(fixture.log, "http.upgrade")
      .find((record) => record.fields.transport === "lan" && record.fields.outcome === "opened"), "lane upgrade opened");
    expect(Number(opened.fields.acceptToUpgradeMs)).toBeGreaterThanOrEqual(250);
  });

  it("stops a bind that was still in flight instead of leaving it listening", async () => {
    const home = await tempRoot("tron-lan-stop-");
    const port = await unusedPort();
    const log = { log: vi.fn() };
    const endpoint = new LanEndpoint({
      enabled: true, stateDirectory: join(home, "lan-endpoint"), port, logger: log as never,
      listenerLimits: HTTP_LISTENER_LIMITS,
      lanAddresses: () => [{ address: "127.0.0.1", family: "IPv4" }],
      ...RESPONDING_HANDLERS,
    });
    const starting = endpoint.start();
    await endpoint.stop();
    await starting;
    expect(await tlsReaches("127.0.0.1", port)).toBe(false);
    await new Promise((resolve) => setTimeout(resolve, RECONCILE_SETTLE_MS));
    expect(await tlsReaches("127.0.0.1", port)).toBe(false);
  });

  it("binds nothing while the setting is off, and retires the lane and its sockets on shutdown", async () => {
    const off = await gatewayFixture({ enabled: false });
    expect((await waitForRecord(off.log, "lan.listener", "state", "disabled")).fields.reason).toBe("setting_off");
    expect(await tlsReaches("::1", off.port)).toBe(false);
    expect((await plainHttp("127.0.0.1", off.port, "/health"))?.status).toBe(200);

    const on = await gatewayFixture();
    await waitForRecord(on.log, "lan.listener", "state", "bound");
    const held = await openTls("::1", on.port);
    on.addresses.length = 0;
    expect((await waitForRecord(on.log, "lan.listener", "state", "disabled")).fields.reason).toBe("no_private_address");
    await waitFor(() => held.destroyed ? true : undefined, "retired lane socket");
    expect((await plainHttp("127.0.0.1", on.port, "/health"))?.status).toBe(200);

    const rebound = await gatewayFixture();
    await waitForRecord(rebound.log, "lan.listener", "state", "bound");
    const duringShutdown = await openTls("::1", rebound.port);
    await rebound.gateway.close();
    await waitFor(() => duringShutdown.destroyed ? true : undefined, "socket retired by shutdown");
    expect(await tlsReaches("::1", rebound.port)).toBe(false);
  });
});
