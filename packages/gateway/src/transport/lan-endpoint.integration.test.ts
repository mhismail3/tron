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

// Failure modes this file exists to catch (real TCP, TLS and WebSocket sockets;
// the fixture's "LAN address" is a loopback address, because that is the only
// address a test may bind):
// 1. No private address: the endpoint must expose nothing and say so once,
//    rather than binding a wildcard or writing a record per reconcile interval.
// 2. Two private interfaces: exactly one address binds, and the record names
//    the family and port rather than which home address was chosen.
// 3. The address changes while sockets are open: the listener moves to the new
//    address, the address it left stops serving, and the sockets it accepted
//    retire instead of staying on a listener the host no longer offers.
// 4. Certificate handling: both files missing are created once at 0600 and
//    reused across a restart; a key left without its certificate is completed
//    from that key with the same pin; a certificate without its key, or an
//    unreadable or mismatched pair,
//    disables the endpoint and is never overwritten, because a paired phone
//    pins that public key.
// 5. A bind failure (an address this host cannot use) is one disable record.
// 6. The lane is TLS-only, and the setting off means no lane listener at all.
// 7. The lane serves the socket route and the authenticated HTTP routes through
//    the transport's shared admission, refuses `POST /v1/pair`, and answers
//    `/health` with its status alone.
// 8. Shutdown retires the lane listener and the sockets it accepted, including
//    a listener whose bind was still in flight when `stop` was called.
// 9. Two admission bounds a peer that has not signed in could otherwise hold a
//    slot with: the TLS handshake and an unfinished request line. The main
//    listener closes both within `HTTP_HEADERS_TIMEOUT_MS`; a lane that takes
//    Node's defaults holds them for 60-120 s out of the same capacity.
// 10. The serial of a generated certificate must be minimal DER: OpenSSL
//    refuses one that starts with a zero octet, which is what a serial drawn
//    from 16 random bytes is about one time in 512. Such a pair would either
//    stop the Gateway from starting or disable the lane for good.
// 11. The upgrade record's `acceptToUpgradeMs` must date from the TCP accept on
//    the lane too, where the upgrade handler is handed the TLS socket rather
//    than the accepted one.
// 12. The lane's endpoint and pin reach the phone only on the two channels a
//    paired device owns — the pairing response and hello — and nowhere an
//    unauthenticated peer can read them; the pin is the one the phone derives
//    from the served certificate (the shared `lan-endpoint-pin` fixture), and a
//    lane that is off advertises no endpoint rather than leaving the phone to
//    dial an address this Mac no longer serves.

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => {
  const failures: unknown[] = [];
  for (const cleanup of cleanups.splice(0).reverse()) {
    try { await cleanup(); } catch (error) { failures.push(error); }
  }
  if (failures.length) throw new AggregateError(failures, "fixture cleanup failed");
});

/** Several reconcile intervals at the fixture cadence, for the
 * one-record-per-condition assertions. */
const RECONCILE_SETTLE_MS = 150;

async function bounded<T>(promise: Promise<T>, label: string, timeoutMs = 3_000): Promise<T> {
  let timer!: NodeJS.Timeout;
  try {
    return await Promise.race([promise, new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new Error(`${label} timed out`)), timeoutMs);
    })]);
  } finally { clearTimeout(timer); }
}

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

/** The `key=value` tokens a Tron record puts in its message, read the way the
 * triage tool reads them. */
function messageFields(message: string): Record<string, string> {
  return Object.fromEntries([...message.matchAll(/([A-Za-z][A-Za-z0-9]*)=([^\s);]+)/gu)].map((match) => [match[1]!, match[2]!]));
}

function records(log: ReturnType<typeof vi.fn>, event: string): LoggedRecord[] {
  return log.mock.calls.flatMap((call) => call[2]?.event === event
    ? [{ level: call[0] as string, message: call[1] as string, fields: call[2] as Record<string, unknown> }]
    : []);
}

async function waitFor<T>(observe: () => T | undefined, label: string, timeoutMs = 5_000): Promise<T> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const value = observe();
    if (value !== undefined) return value;
    if (Date.now() >= deadline) throw new Error(`${label} timed out`);
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

async function waitForRecord(log: ReturnType<typeof vi.fn>, event: string, field: string, value: string): Promise<LoggedRecord> {
  return waitFor(() => records(log, event).find((record) => messageFields(record.message)[field] === value),
    `${event} with ${field}=${value}`);
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

/** One request over TLS, authenticated by nothing but the served certificate
 * being the one on disk: `ca` is that certificate and the hostname check is
 * waived, so a served pair that differs from the file fails the chain. */
async function lanRequest(host: string, port: number, path: string, certificate: string, init: { method?: string; body?: string; bearer?: string } = {}): Promise<Response> {
  return bounded(new Promise((resolve, reject) => {
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

/** Whether a TLS client completes a handshake on this address and port. A plain
 * HTTP listener answers with a non-TLS response, which fails it. */
async function tlsReaches(host: string, port: number): Promise<boolean> {
  return bounded(new Promise<boolean>((resolve) => {
    const socket = tlsConnect({ host, port, rejectUnauthorized: false });
    socket.once("secureConnect", () => { socket.destroy(); resolve(true); });
    socket.once("error", () => resolve(false));
  }), "TLS probe");
}

async function openTls(host: string, port: number): Promise<TLSSocket> {
  const socket = tlsConnect({ host, port, rejectUnauthorized: false });
  await bounded(new Promise<void>((resolve, reject) => { socket.once("secureConnect", resolve); socket.once("error", reject); }), "TLS connect");
  return socket;
}

/** A plain HTTP response, or null when the request never got one: the contrast
 * that shows the lane is TLS-only. */
async function plainHttp(host: string, port: number, path: string, method = "GET", body?: string): Promise<Response | null> {
  return bounded(new Promise<Response | null>((resolve, reject) => {
    const outgoing = httpRequest({
      host, port, path, method, agent: false,
      ...(body === undefined ? {} : { headers: { "content-type": "application/json", "content-length": Buffer.byteLength(body) } }),
    }, (incoming) => receive(incoming, resolve, reject));
    outgoing.once("error", () => resolve(null));
    outgoing.end(body);
  }), `HTTP ${method} ${path}`);
}

/** A bare listener's route surface: this file tests the endpoint's binding,
 * certificate and lifecycle, not the routes (the Gateway case below covers
 * those through the real transport). */
const RESPONDING_HANDLERS = {
  onConnection: () => {},
  onSecureConnection: () => {},
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

/** A bare LAN endpoint on a free port. Its address list is injected, so the
 * "private interface" is whatever this fixture says it is. */
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

/** A Gateway whose LAN leg binds `::1`: the main listener holds `127.0.0.1` on
 * the same port, so the two real listeners coexist exactly as they do in
 * production, one address apart. */
async function gatewayFixture(options: { enabled?: boolean } = {}): Promise<GatewayFixture> {
  const home = await tempRoot("tron-lan-gateway-");
  const devices = new DeviceStore(home, "fixture-machine");
  await devices.initialize();
  const addresses: LanAddress[] = [{ address: "::1", family: "IPv6" }];
  const log = { log: vi.fn() };
  const port = await unusedPort();
  const gateway = new GatewayServer({
    host: "127.0.0.1", port, maxFrameBytes: 64 * 1_024, devices,
    uploads: {} as never,
    sessions: { unsubscribeClient: vi.fn() } as never,
    auth: { detachClient: vi.fn(), cancelOwner: vi.fn() } as never,
    service: { info: () => ({ protocolVersion: PROTOCOL_VERSION }), releaseClient: vi.fn(), terminalBelongsToSession: () => false } as never,
    logger: log as never,
    lanEndpoint: {
      enabled: options.enabled ?? true,
      stateDirectory: join(home, "gateway", "lan-endpoint"),
      lanAddresses: () => [...addresses],
      reconcileIntervalMs: 25,
    },
  });
  await gateway.listen();
  cleanups.push(() => gateway.close());
  return { root: home, log: log.log, stateDirectory: join(home, "gateway", "lan-endpoint"), addresses, gateway, devices, port };
}

/** The first frame the Gateway sends on an opened socket: its hello answer. */
function gatewayHello(socket: WebSocket): Promise<Record<string, unknown>> {
  return bounded(new Promise((resolve) => {
    socket.once("message", (data: Buffer) => resolve(JSON.parse(data.toString("utf8")) as Record<string, unknown>));
  }), "gateway hello frame");
}

async function localToken(home: string): Promise<string> {
  return (JSON.parse(await readFile(join(home, "gateway", "local-auth.json"), "utf8")) as { bearerToken: string }).bearerToken;
}

describe("LAN endpoint", () => {
  it("creates one key and certificate pair at 0600 and reuses it across a restart", async () => {
    const fixture = await endpointFixture("tron-lan-pair-", [{ address: "127.0.0.1", family: "IPv4" }]);
    const bound = messageFields((await waitForRecord(fixture.log, "lan.listener", "state", "bound")).message);
    expect(bound).toMatchObject({ family: "IPv4", port: String(fixture.port) });
    // The record names the family, never the address it bound.
    expect(records(fixture.log, "lan.listener")[0]!.message).not.toContain("127.0.0.1");

    const keyPath = join(fixture.stateDirectory, "tls-key.pem");
    const certificatePath = join(fixture.stateDirectory, "tls-certificate.pem");
    const [key, certificate] = await Promise.all([readFile(keyPath, "utf8"), readFile(certificatePath, "utf8")]);
    expect((await stat(keyPath)).mode & 0o777).toBe(0o600);
    expect((await stat(certificatePath)).mode & 0o777).toBe(0o600);
    expect(key).toContain("BEGIN PRIVATE KEY");
    expect(certificate).toContain("BEGIN CERTIFICATE");
    // The chain verifies against the certificate on disk, so the served pair is
    // this pair: the pin a paired phone stores.
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
    // A restart serves exactly the pair a paired phone pinned.
    expect(await readFile(keyPath, "utf8")).toBe(key);
    expect(await readFile(certificatePath, "utf8")).toBe(certificate);
    expect((await lanRequest("127.0.0.1", fixture.port, "/health", certificate)).status).toBe(200);
  });

  it("generates certificates OpenSSL reads back", async () => {
    // A serial drawn from 16 random bytes is non-minimal DER about one time in
    // 512 — a zero octet before a byte below 0x80 — and OpenSSL refuses the
    // certificate that carries it. 4096 draws catch that regression with
    // 99.97%; what each draw asserts is that the generated pair loads.
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
      // Nothing listens, and what a paired phone may have pinned is intact.
      expect(await tlsReaches("127.0.0.1", port)).toBe(false);
      expect(records(log.log, "lan.listener")).toHaveLength(1);
      if (testCase.files.key !== undefined) expect(await readFile(keyPath, "utf8")).toBe(testCase.files.key);
      if (testCase.files.certificate !== undefined) expect(await readFile(certificatePath, "utf8")).toBe(testCase.files.certificate);
    }
  });

  it("completes a key left without its certificate from that key, keeping the pin", async () => {
    // Creation writes the key, then the certificate; a crash between them left
    // a key no phone can have pinned (the pin is only advertised once both load).
    // The certificate is issued from the stored key, so the pin is the key's.
    const home = await tempRoot("tron-lan-key-only-");
    const stored = generateKeyPairSync("ec", { namedCurve: "prime256v1" }).privateKey;
    const storedKey = stored.export({ type: "pkcs8", format: "pem" }).toString();
    const stateDirectory = join(home, "gateway");
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
    // The second address is never bound while the first is available.
    expect(await tlsReaches("::1", fixture.port)).toBe(false);
    const held = await openTls("127.0.0.1", fixture.port);
    const observation = await waitFor(() => accepted.find((entry) => !entry.closed), "accepted LAN socket");

    fixture.addresses.shift();
    const rebound = await waitForRecord(fixture.log, "lan.listener", "state", "rebound");
    expect(messageFields(rebound.message)).toMatchObject({ family: "IPv6", port: String(fixture.port) });
    // The address the host left stops serving, and its socket is retired.
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
    // The lane is TLS-only, and the certificate on disk is the one it serves.
    expect(await lanRequest("::1", fixture.port, "/health", certificate)).toEqual({ status: 200, body: { status: "ok" } });
    expect(await plainHttp("::1", fixture.port, "/health")).toBeNull();
    // The main listener still answers its full health document.
    const primaryHealth = await plainHttp("127.0.0.1", fixture.port, "/health");
    expect(primaryHealth?.status).toBe(200);
    expect(primaryHealth?.body.protocolVersion).toBe(PROTOCOL_VERSION);

    // Pairing is first contact and stays on the main listener.
    expect((await plainHttp("127.0.0.1", fixture.port, "/v1/pair", "POST", "{}"))?.status).toBe(400);
    expect((await lanRequest("::1", fixture.port, "/v1/pair", certificate, { method: "POST", body: "{}" })).status).toBe(404);
    // An authenticated route exists on the lane and refuses an anonymous
    // caller through the same credential admission as the main listener.
    expect((await lanRequest("::1", fixture.port, "/v1/blobs/unknown", certificate)).status).toBe(401);

    const token = await localToken(fixture.root);
    const hello = JSON.stringify({ type: "hello", protocolVersion: PROTOCOL_VERSION, diagnostics: { clientId: "fixture", attemptId: "lan", epoch: "1" } });
    const socket = new WebSocket(`wss://[::1]:${fixture.port}/v1/socket`, { headers: { authorization: `Bearer ${token}` }, rejectUnauthorized: false });
    cleanups.push(async () => { socket.terminate(); });
    await bounded(new Promise<void>((resolve, reject) => { socket.once("open", resolve); socket.once("error", reject); }), "LAN socket open");
    socket.send(hello);
    const opened = await waitFor(() => records(fixture.log, "http.upgrade").find((record) => record.fields.outcome === "opened"), "lane upgrade opened");
    expect(opened.fields.transport).toBe("lan");
    // The shared transport admitted it: the lane has no admission of its own.
    await waitFor(() => records(fixture.log, "connection.opened").length === 1 ? true : undefined, "lane hello admitted");

    const primary = new WebSocket(`ws://127.0.0.1:${fixture.port}/v1/socket`, { headers: { authorization: `Bearer ${token}` } });
    cleanups.push(async () => { primary.terminate(); });
    await bounded(new Promise<void>((resolve, reject) => { primary.once("open", resolve); primary.once("error", reject); }), "primary socket open");
    primary.send(hello);
    const primaryOpened = await waitFor(() => records(fixture.log, "http.upgrade").filter((record) => record.fields.outcome === "opened")[1], "primary upgrade opened");
    expect(primaryOpened.fields.transport).toBe("primary");
  });

  it("advertises the lane's endpoint and pin over pairing and hello and nowhere else", async () => {
    const fixture = await gatewayFixture();
    await waitForRecord(fixture.log, "lan.listener", "state", "bound");
    const certificate = await readFile(join(fixture.stateDirectory, "tls-certificate.pem"), "utf8");
    // The pin is frozen by the shared fixture both platforms assert against, so
    // this Gateway and a paired phone hash the same bytes for the same key.
    const frozen = JSON.parse(await readFile(
      new URL("../../../protocol-fixtures/lan-endpoint-pin.json", import.meta.url), "utf8")) as { certificatePem: string; pin: string };
    expect(lanPin(frozen.certificatePem)).toBe(frozen.pin);
    const expectedPin = lanPin(certificate);
    const expectedEndpoints = [{ host: "::1", port: fixture.port }];

    // Pairing is first contact and already proves the one-time code, so the
    // response it answers with is where a phone learns the lane.
    const enrollment = await fixture.devices.ensureEnrollment();
    const paired = await plainHttp("127.0.0.1", fixture.port, "/v1/pair", "POST",
      JSON.stringify({ code: enrollment.code, deviceName: "fixture phone" }));
    expect(paired?.status).toBe(200);
    expect(paired?.body.lanEndpoints).toEqual(expectedEndpoints);
    expect(paired?.body.lanPin).toBe(expectedPin);

    // Nothing a peer without a credential can read names the lane: the main
    // health document, and the lane's own minimal one.
    const primaryHealth = await plainHttp("127.0.0.1", fixture.port, "/health");
    expect(primaryHealth?.status).toBe(200);
    expect(Object.keys(primaryHealth?.body ?? {})).not.toContain("lanEndpoints");
    expect(Object.keys(primaryHealth?.body ?? {})).not.toContain("lanPin");
    expect(await lanRequest("::1", fixture.port, "/health", certificate))
      .toEqual({ status: 200, body: { status: "ok" } });

    // Hello carries the same advertisement on either leg, so a paired phone
    // replaces what its profile holds on every connection.
    const token = await localToken(fixture.root);
    for (const url of [`wss://[::1]:${fixture.port}/v1/socket`, `ws://127.0.0.1:${fixture.port}/v1/socket`]) {
      const socket = new WebSocket(url, { headers: { authorization: `Bearer ${token}` }, rejectUnauthorized: false });
      cleanups.push(async () => { socket.terminate(); });
      await bounded(new Promise<void>((resolve, reject) => { socket.once("open", resolve); socket.once("error", reject); }), "socket open");
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
    await bounded(new Promise<void>((resolve, reject) => { socket.once("open", resolve); socket.once("error", reject); }), "primary socket open");
    socket.send(JSON.stringify({ type: "hello", protocolVersion: PROTOCOL_VERSION, diagnostics: { clientId: "fixture", attemptId: "off", epoch: "1" } }));
    const hello = await gatewayHello(socket);
    // An empty list is the lane's current truth: the phone replaces what it
    // stored and falls back to its other leg instead of an address that is
    // not served. Nothing was pinned, so there is no pin to send either.
    expect(hello.lanEndpoints).toEqual([]);
    expect(Object.keys(hello)).not.toContain("lanPin");
  });

  it("bounds a lane peer at the main listener's handshake and header limits", async () => {
    const fixture = await gatewayFixture();
    await waitForRecord(fixture.log, "lan.listener", "state", "bound");
    // Two ways a peer that has not signed in holds a slot: a handshake that
    // never completes, and a request line that never ends. The main listener
    // retires both at `HTTP_HEADERS_TIMEOUT_MS`; a lane left on Node's 60 s
    // header and 120 s handshake defaults holds them out of the same budget.
    const bare = createConnection({ host: "::1", port: fixture.port });
    cleanups.push(async () => { bare.destroy(); });
    const partial = await openTls("::1", fixture.port);
    cleanups.push(async () => { partial.destroy(); });
    // The client has to read to see the 408: a paused TLS socket never surfaces
    // the server's close at all, so the answer is this case's observable.
    const answered = new Promise<string>((resolve, reject) => {
      partial.once("data", (chunk: Buffer) => resolve(chunk.toString("utf8")));
      partial.once("error", reject);
    });
    partial.write("GET /health HTTP/1.1\r\nHost: localhost\r\n");
    // Node enforces both bounds on its own timers, so this wait is real; the
    // slack is for a machine that is busy with other sessions.
    await bounded(Promise.all([once(bare, "close"), answered]),
      "lane admission bound", HTTP_HEADERS_TIMEOUT_MS + 15_000);
    expect(await answered).toContain("408");
  }, 45_000);

  it("dates a lane upgrade from the TCP accept, so the record shows the TLS handshake", async () => {
    const fixture = await gatewayFixture();
    await waitForRecord(fixture.log, "lan.listener", "state", "bound");
    const token = await localToken(fixture.root);
    // The handshake is spent before the upgrade request is written, the way a
    // phone's own reconnect spends it: the field is zero only if the accept
    // time was looked up on the socket the handler was not given.
    const handed = await openTls("::1", fixture.port);
    cleanups.push(async () => { handed.destroy(); });
    await new Promise((resolve) => setTimeout(resolve, 300));
    const socket = new WebSocket(`wss://[::1]:${fixture.port}/v1/socket`, {
      headers: { authorization: `Bearer ${token}` },
      rejectUnauthorized: false,
      createConnection: () => handed,
    });
    cleanups.push(async () => { socket.terminate(); });
    await bounded(new Promise<void>((resolve, reject) => { socket.once("open", resolve); socket.once("error", reject); }), "handed lane upgrade open");
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
    // `stop` lands while the first pair is still being read from disk; the bind
    // that follows it must not outlive the stop, and neither must its interval.
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
    // The main listener is untouched by the lane leaving.
    expect((await plainHttp("127.0.0.1", on.port, "/health"))?.status).toBe(200);

    const rebound = await gatewayFixture();
    await waitForRecord(rebound.log, "lan.listener", "state", "bound");
    const duringShutdown = await openTls("::1", rebound.port);
    await rebound.gateway.close();
    await waitFor(() => duringShutdown.destroyed ? true : undefined, "socket retired by shutdown");
    expect(await tlsReaches("::1", rebound.port)).toBe(false);
  });
});
