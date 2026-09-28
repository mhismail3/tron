import { createPrivateKey, createPublicKey, generateKeyPairSync, randomBytes, sign, X509Certificate, type KeyObject } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { hostname } from "node:os";
import { join } from "node:path";
import { createServer, type Server as SecureServer, type ServerOptions as HttpsServerOptions } from "node:https";
import type { IncomingMessage, ServerResponse } from "node:http";
import type { Duplex } from "node:stream";
import { resolveLanAddresses, type LanAddress } from "../config.js";
import type { GatewayLogger, LogLevel } from "./logger.js";

/**
 * The LAN endpoint (E-3a): a second, TLS-only listener on the Mac's private LAN
 * address, so a phone at home does not depend on Tailscale's path. It shares
 * its HTTP and WebSocket handling with the main listener — the same admission,
 * capacity, heartbeat, revocation and hello — and adds only what a second
 * address needs: a pinned certificate, a private-address-only bind, and a
 * rebind when that address changes.
 *
 * What this listener must never do: bind a wildcard or a public address, serve
 * `POST /v1/pair` or any unauthenticated route beyond a health check, or
 * regenerate its key under a certificate a paired phone already pinned.
 */

/** No portable event says a host's private address changed. One cheap
 * `getifaddrs` read per interval — the phone's own liveness interval is
 * independent of it — rebinds the listener and disables it when no private
 * address remains. */
export const LAN_ADDRESS_RECONCILE_MS = 15_000;
/** A LAN peer that has not retired within this bound after shutdown began is
 * destroyed: the phone falls back to its other leg, and transport shutdown
 * never waits on a silent socket. Matches the transport's own HTTP grace. */
const LAN_SHUTDOWN_GRACE_MS = 1_000;
const LAN_KEY_FILE = "tls-key.pem";
const LAN_CERTIFICATE_FILE = "tls-certificate.pem";
/** Ten years, inside the UTCTime range. The certificate is created once and
 * only an explicit rotation replaces it: every paired profile pins its public
 * key (E-3b), so a silent regeneration would break the pin rather than fix it. */
const LAN_CERTIFICATE_LIFETIME_DAYS = 3_650;

const OID_ECDSA_WITH_SHA256 = "1.2.840.10045.4.3.2";
const OID_COMMON_NAME = "2.5.4.3";
const OID_BASIC_CONSTRAINTS = "2.5.29.19";
const OID_KEY_USAGE = "2.5.29.15";

/** A `lan.listener` record names the state and, while bound, the address
 * family and port. Never the address: the record exists to say whether the LAN
 * leg is up, not to publish the home network. */
export type LanListenerReason = "setting_off" | "no_private_address" | "bind_failed" | "certificate_incomplete" | "certificate_unreadable" | "certificate_mismatched" | "certificate_generation_failed";

export interface LanEndpointConfig {
  readonly enabled: boolean;
  /** The Gateway's private state directory for the key and certificate. */
  readonly stateDirectory: string;
  /** Host facts: the private LAN addresses, most preferred first. A fixture
   * presents a loopback address here to be the LAN address under test. */
  readonly lanAddresses?: () => readonly LanAddress[];
  readonly reconcileIntervalMs?: number;
}

export interface LanEndpointHandlers {
  readonly onConnection: (socket: Duplex) => void;
  /** The TLS socket a completed handshake produced. The upgrade handler is
   * handed that same socket later, so the accept time the listener recorded at
   * `onConnection` is carried across here. */
  readonly onSecureConnection: (socket: Duplex) => void;
  readonly onRequest: (request: IncomingMessage, response: ServerResponse) => void;
  readonly onUpgrade: (request: IncomingMessage, socket: Duplex, head: Buffer) => void;
}

/** The bounds the transport applies to every HTTP listener it owns. The lane
 * serves the same routes to the same peers out of the same connection budget,
 * so it takes them from the transport rather than from Node's defaults: Node's
 * 60 s header and 120 s handshake allowances would let a peer that has not
 * signed in hold slots the phone's own leg needs. Every one is required, so a
 * listener cannot silently fall back to a Node default. `idleTimeout` is
 * `server.timeout`, which has no `createServer` option. */
export interface LanListenerLimits {
  readonly headersTimeout: number;
  readonly requestTimeout: number;
  readonly connectionsCheckingInterval: number;
  readonly handshakeTimeout: number;
  readonly idleTimeout: number;
}

/** The `createServer` subset of those bounds, so both listeners spell "which
 * field goes where" once. */
export function httpListenerOptions(limits: LanListenerLimits): HttpsServerOptions {
  return {
    headersTimeout: limits.headersTimeout,
    requestTimeout: limits.requestTimeout,
    connectionsCheckingInterval: limits.connectionsCheckingInterval,
    handshakeTimeout: limits.handshakeTimeout,
  };
}

export interface LanEndpointOptions extends LanEndpointConfig, LanEndpointHandlers {
  readonly logger: GatewayLogger;
  /** The listener's port. The LAN leg serves the same route surface as the main
   * listener, so it uses the same port on the other address. */
  readonly port: number;
  /** The main listener's HTTP and TLS bounds, which this lane shares. */
  readonly listenerLimits: LanListenerLimits;
}

interface LanCredentials {
  readonly key: string;
  readonly certificate: string;
}

class LanCredentialError extends Error {
  constructor(readonly reason: Extract<LanListenerReason, `certificate_${string}`>) {
    super(reason);
  }
}

function failureReason(error: unknown): LanListenerReason {
  return error instanceof LanCredentialError ? error.reason : "certificate_generation_failed";
}

function derLength(length: number): Buffer {
  if (length < 0x80) return Buffer.from([length]);
  const bytes: number[] = [];
  for (let remaining = length; remaining > 0; remaining = Math.floor(remaining / 256)) bytes.unshift(remaining % 256);
  return Buffer.from([0x80 | bytes.length, ...bytes]);
}

function der(tag: number, content: Buffer): Buffer {
  return Buffer.concat([Buffer.from([tag]), derLength(content.length), content]);
}

function derSequence(...items: Buffer[]): Buffer {
  return der(0x30, Buffer.concat(items));
}

function derSet(...items: Buffer[]): Buffer {
  return der(0x31, Buffer.concat(items));
}

function derInteger(bytes: Buffer): Buffer {
  // X.690 minimal form: no leading zero octet, and one added only where the
  // value's first octet has the high bit set and would otherwise read as
  // negative. OpenSSL refuses a certificate whose serial is not minimal — the
  // 16 random bytes a serial is drawn from carry a leading zero about one time
  // in 256 — so a pair that skipped this normalization could keep the Gateway
  // from starting or disable the lane for good.
  let first = 0;
  while (first < bytes.length - 1 && bytes[first] === 0) first += 1;
  const minimal = bytes.subarray(first);
  return der(0x02, minimal[0]! & 0x80 ? Buffer.concat([Buffer.from([0]), minimal]) : minimal);
}

function derOid(dotted: string): Buffer {
  const arcs = dotted.split(".").map(Number);
  const body: number[] = [arcs[0]! * 40 + arcs[1]!];
  for (const arc of arcs.slice(2)) {
    const encoded: number[] = [arc & 0x7f];
    for (let remaining = Math.floor(arc / 128); remaining > 0; remaining = Math.floor(remaining / 128)) {
      encoded.unshift((remaining & 0x7f) | 0x80);
    }
    body.push(...encoded);
  }
  return der(0x06, Buffer.from(body));
}

function derUtf8(value: string): Buffer {
  return der(0x0c, Buffer.from(value, "utf8"));
}

function derBoolean(value: boolean): Buffer {
  return der(0x01, Buffer.from([value ? 0xff : 0x00]));
}

function derOctetString(value: Buffer): Buffer {
  return der(0x04, value);
}

function derBitString(value: Buffer, unusedBits = 0): Buffer {
  return der(0x03, Buffer.concat([Buffer.from([unusedBits]), value]));
}

/** Context-specific, constructed: the `[0] EXPLICIT` version and `[3] EXPLICIT`
 * extensions fields of a v3 certificate. */
function derContext(tagNumber: number, content: Buffer): Buffer {
  return der(0xa0 | tagNumber, content);
}

function derUtcTime(value: Date): Buffer {
  const pad = (part: number): string => String(part).padStart(2, "0");
  const text = `${pad(value.getUTCFullYear() % 100)}${pad(value.getUTCMonth() + 1)}${pad(value.getUTCDate())}`
    + `${pad(value.getUTCHours())}${pad(value.getUTCMinutes())}${pad(value.getUTCSeconds())}Z`;
  return der(0x17, Buffer.from(text, "ascii"));
}

function toPem(label: string, derBytes: Buffer): string {
  const lines = derBytes.toString("base64").match(/.{1,64}/gu) ?? [];
  return `-----BEGIN ${label}-----\n${lines.join("\n")}\n-----END ${label}-----\n`;
}

/**
 * A self-signed v3 certificate for `privateKey`. It carries no subject
 * alternative name on purpose: the phone pins the key rather than validating
 * the address it dialled, and the address is exactly what changes when the Mac
 * joins another network.
 */
export function selfSignedCertificate(privateKey: KeyObject, commonName: string, now = new Date()): string {
  const algorithm = derSequence(derOid(OID_ECDSA_WITH_SHA256));
  const name = derSequence(derSet(derSequence(derOid(OID_COMMON_NAME), derUtf8(commonName))));
  const subjectPublicKeyInfo = createPublicKey(privateKey).export({ type: "spki", format: "der" });
  const extensions = derContext(3, derSequence(
    derSequence(derOid(OID_BASIC_CONSTRAINTS), derBoolean(true), derOctetString(derSequence(derBoolean(false)))),
    // digitalSignature(0) and keyEncipherment(2): three significant bits.
    derSequence(derOid(OID_KEY_USAGE), derBoolean(true), derOctetString(derBitString(Buffer.from([0xa0]), 5))),
  ));
  const tbsCertificate = derSequence(
    derContext(0, derInteger(Buffer.from([2]))),
    derInteger(randomBytes(16)),
    algorithm,
    name,
    derSequence(
      derUtcTime(new Date(now.getTime() - 24 * 3_600_000)),
      derUtcTime(new Date(now.getTime() + LAN_CERTIFICATE_LIFETIME_DAYS * 24 * 3_600_000)),
    ),
    name,
    subjectPublicKeyInfo as Buffer,
    extensions,
  );
  const signature = sign("sha256", tbsCertificate, privateKey);
  return toPem("CERTIFICATE", derSequence(tbsCertificate, algorithm, derBitString(signature)));
}

async function readOptional(path: string): Promise<string | null> {
  try {
    return await readFile(path, "utf8");
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return null;
    throw new LanCredentialError("certificate_unreadable");
  }
}

function validateCredentials(key: string, certificate: string): LanCredentials {
  let privateKey: KeyObject;
  let parsed: X509Certificate;
  try {
    privateKey = createPrivateKey(key);
    parsed = new X509Certificate(certificate);
  } catch {
    throw new LanCredentialError("certificate_unreadable");
  }
  const derived = createPublicKey(privateKey).export({ type: "spki", format: "der" });
  if (!derived.equals(parsed.publicKey.export({ type: "spki", format: "der" }))) {
    throw new LanCredentialError("certificate_mismatched");
  }
  return { key, certificate };
}

/** The stored key and certificate, created once when both are absent. A half
 * present, unreadable or mismatched pair is refused rather than overwritten. */
async function loadOrCreateLanCredentials(stateDirectory: string): Promise<LanCredentials> {
  const keyPath = join(stateDirectory, LAN_KEY_FILE);
  const certificatePath = join(stateDirectory, LAN_CERTIFICATE_FILE);
  const [key, certificate] = await Promise.all([readOptional(keyPath), readOptional(certificatePath)]);
  if (key !== null && certificate !== null) return validateCredentials(key, certificate);
  if (key !== null || certificate !== null) throw new LanCredentialError("certificate_incomplete");
  await mkdir(stateDirectory, { recursive: true, mode: 0o700 });
  const { privateKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  // A new pair is read back before it is written: a certificate this Gateway
  // cannot load would otherwise be stored, pinned by a phone, and disable the
  // lane on every later start. A refused pair writes nothing, so the next
  // start draws a new one.
  const created = validateCredentials(
    privateKey.export({ type: "pkcs8", format: "pem" }).toString(),
    selfSignedCertificate(privateKey, hostname()),
  );
  try {
    // `wx` keeps the create-once invariant: a key that appeared between the
    // read above and this write is validated, never replaced.
    await writeFile(keyPath, created.key, { mode: 0o600, flag: "wx" });
    await writeFile(certificatePath, created.certificate, { mode: 0o600, flag: "wx" });
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
    const [existingKey, existingCertificate] = await Promise.all([readOptional(keyPath), readOptional(certificatePath)]);
    if (existingKey === null || existingCertificate === null) throw new LanCredentialError("certificate_incomplete");
    return validateCredentials(existingKey, existingCertificate);
  }
  return created;
}

export class LanEndpoint {
  private credentials: LanCredentials | undefined;
  private listener: SecureServer | undefined;
  private bound: (LanAddress & { readonly port: number }) | undefined;
  private timer: NodeJS.Timeout | undefined;
  /** Set by `stop`: a reconcile that is already past its checks closes what it
   * bound instead of publishing it, and no new interval starts. */
  private stopped = false;
  /** The reconcile in flight, so an interval tick joins it rather than starting
   * a second bind, and `stop` can wait for the one that is running. */
  private reconcileInFlight: Promise<void> | undefined;
  /** The sockets this listener accepted, so a rebind or a shutdown retires
   * exactly the LAN leg: `server.close()` waits for an upgraded socket forever,
   * because Node stops tracking it as an HTTP connection. */
  private readonly acceptedSockets = new Set<Duplex>();
  /** The disabled reason already written, so a reconcile that keeps finding the
   * same condition does not repeat the record every interval. */
  private disabledReason: LanListenerReason | undefined;

  constructor(private readonly options: LanEndpointOptions) {}

  /** Start the listener if the setting is on. Never throws: a LAN endpoint that
   * cannot come up must not stop the Gateway or its main listener. */
  async start(): Promise<void> {
    if (!this.options.enabled) {
      this.recordDisabled("setting_off", "info");
      return;
    }
    try {
      this.credentials = await loadOrCreateLanCredentials(this.options.stateDirectory);
    } catch (error) {
      // A malformed or half-present pair is not retried: only the explicit
      // rotation replaces an existing certificate.
      this.recordDisabled(failureReason(error), "warning");
      return;
    }
    await this.reconcile();
    // A `stop` that landed while the first pair was loading owns the endpoint
    // now: an interval started here would outlive it.
    if (this.stopped) return;
    // Keep reconciling even while disabled for want of a private address: a Mac
    // that starts with Wi-Fi off must expose the LAN leg once it associates.
    this.timer = setInterval(() => void this.reconcile(), this.options.reconcileIntervalMs ?? LAN_ADDRESS_RECONCILE_MS);
    this.timer.unref();
  }

  /** Stop listening. Sockets this listener accepted keep their own bounded
   * retirement: a peer that does not leave within the grace is destroyed. A
   * bind still in flight is joined first, so nothing this endpoint bound is
   * left listening once this promise settles. */
  async stop(): Promise<void> {
    this.stopped = true;
    clearInterval(this.timer);
    this.timer = undefined;
    await this.reconcileInFlight;
    await this.retireListener(false);
  }

  /** One reconcile at a time: a tick that arrives while a bind is in flight
   * joins it, and `stop` waits on the same promise. */
  private reconcile(): Promise<void> {
    if (this.reconcileInFlight !== undefined) return this.reconcileInFlight;
    const running = this.reconcileOnce().finally(() => {
      if (this.reconcileInFlight === running) this.reconcileInFlight = undefined;
    });
    this.reconcileInFlight = running;
    return running;
  }

  private async reconcileOnce(): Promise<void> {
    if (this.stopped || !this.credentials) return;
    const next = (this.options.lanAddresses ?? resolveLanAddresses)()[0];
    if (next !== undefined && this.listener && this.bound?.address === next.address) return;
    // Retire before the new bind: the address this listener served is no longer
    // the preferred one, so a socket on it cannot reach the phone anyway. A
    // failed bind is retried on the next interval, because the port or the
    // address may be transient.
    const rebound = this.listener !== undefined;
    await this.retireListener(true);
    if (this.stopped) return;
    if (next === undefined) {
      this.recordDisabled("no_private_address", "info");
      return;
    }
    const listener = await this.bind(next);
    if (this.stopped) {
      // `stop` returned while this bind was still in flight. The listener it
      // could not see is this pass's own, so this pass closes it.
      if (listener) await this.closeListener(listener, true);
      return;
    }
    if (!listener) {
      this.recordDisabled("bind_failed", "warning");
      return;
    }
    this.listener = listener;
    this.bound = { ...next, port: this.options.port };
    this.disabledReason = undefined;
    this.options.logger.log("info",
      // The details ride in the message, like every other bounded diagnostic
      // record: the family and port say the LAN leg is up without publishing
      // which address on the home network it is.
      `LAN endpoint ${rebound ? "rebound" : "bound"} (state=${rebound ? "rebound" : "bound"} family=${next.family} port=${this.options.port})`,
      { event: "lan.listener", source: "transport" });
  }

  private async bind(address: LanAddress): Promise<SecureServer | undefined> {
    const credentials = this.credentials!;
    const limits = this.options.listenerLimits;
    let listener: SecureServer;
    try {
      // The TLS context is part of the bind: a credential the platform refuses
      // disables this listener rather than reaching `start`, which must never
      // throw (the Gateway would fail to start with it).
      listener = createServer({
        ...httpListenerOptions(limits),
        key: credentials.key,
        cert: credentials.certificate,
        minVersion: "TLSv1.2",
      }, (request, response) => this.options.onRequest(request, response));
    } catch {
      return undefined;
    }
    listener.timeout = limits.idleTimeout;
    listener.on("connection", (socket) => {
      this.acceptedSockets.add(socket);
      socket.once("close", () => this.acceptedSockets.delete(socket));
      this.options.onConnection(socket);
    });
    listener.on("secureConnection", (socket) => this.options.onSecureConnection(socket));
    listener.on("upgrade", (request, socket, head) => this.options.onUpgrade(request, socket, head));
    try {
      await new Promise<void>((resolve, reject) => {
        listener.once("error", reject);
        listener.listen(this.options.port, address.address, () => {
          listener.off("error", reject);
          resolve();
        });
      });
    } catch {
      // Only the state reaches the log: the `lan.listener` record the caller
      // writes names the family and the retry, never the refused address.
      listener.close(() => {});
      return undefined;
    }
    return listener;
  }

  private async retireListener(immediately: boolean): Promise<void> {
    const listener = this.listener;
    this.listener = undefined;
    this.bound = undefined;
    if (!listener) return;
    await this.closeListener(listener, immediately);
  }

  private async closeListener(listener: SecureServer, immediately: boolean): Promise<void> {
    const closed = new Promise<void>((resolve) => listener.close(() => resolve()));
    listener.closeIdleConnections();
    if (immediately) {
      for (const socket of [...this.acceptedSockets]) socket.destroy();
      await closed;
      return;
    }
    const grace = setTimeout(() => {
      for (const socket of [...this.acceptedSockets]) socket.destroy();
    }, LAN_SHUTDOWN_GRACE_MS);
    grace.unref();
    await closed;
    clearTimeout(grace);
  }

  private recordDisabled(reason: LanListenerReason, level: LogLevel): void {
    if (this.disabledReason === reason) return;
    this.disabledReason = reason;
    this.options.logger.log(level, `LAN endpoint disabled (state=disabled reason=${reason})`, {
      event: "lan.listener", source: "transport", reason,
    });
  }
}
