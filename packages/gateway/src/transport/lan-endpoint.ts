import { createHash, createPrivateKey, createPublicKey, generateKeyPairSync, randomBytes, sign, X509Certificate, type KeyObject } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { hostname } from "node:os";
import { join } from "node:path";
import { createServer, type Server as SecureServer, type ServerOptions as HttpsServerOptions } from "node:https";
import type { IncomingMessage, ServerResponse } from "node:http";
import type { Duplex } from "node:stream";
import { resolveLanAddresses, type LanAddress } from "../config.js";
import type { GatewayLogger, LogLevel } from "./logger.js";

const LAN_ADDRESS_RECONCILE_MS = 15_000;
const LAN_SHUTDOWN_GRACE_MS = 1_000;
const LAN_KEY_FILE = "tls-key.pem";
const LAN_CERTIFICATE_FILE = "tls-certificate.pem";
const LAN_CERTIFICATE_LIFETIME_DAYS = 3_650;

const OID_ECDSA_WITH_SHA256 = "1.2.840.10045.4.3.2";
const OID_COMMON_NAME = "2.5.4.3";
const OID_BASIC_CONSTRAINTS = "2.5.29.19";
const OID_KEY_USAGE = "2.5.29.15";

type LanListenerReason = "setting_off" | "no_private_address" | "bind_failed" | "certificate_incomplete" | "certificate_unreadable" | "certificate_mismatched" | "certificate_generation_failed";

export interface LanEndpointConfig {
  readonly enabled: boolean;
  readonly stateDirectory: string;
  readonly lanAddresses?: () => readonly LanAddress[];
  readonly reconcileIntervalMs?: number;
}

interface LanEndpointHandlers {
  readonly onConnection: (socket: Duplex) => void;
  readonly onSecureConnection: (socket: Duplex) => void;
  readonly onClientError: (error: Error, socket: Duplex) => void;
  readonly onTlsClientError: (error: Error, socket: Duplex) => void;
  readonly onRequest: (request: IncomingMessage, response: ServerResponse) => void;
  readonly onUpgrade: (request: IncomingMessage, socket: Duplex, head: Buffer) => void;
}

export interface LanListenerLimits {
  readonly headersTimeout: number;
  readonly requestTimeout: number;
  readonly connectionsCheckingInterval: number;
  readonly handshakeTimeout: number;
  readonly idleTimeout: number;
}

export function httpListenerOptions(limits: LanListenerLimits): HttpsServerOptions {
  return {
    headersTimeout: limits.headersTimeout,
    requestTimeout: limits.requestTimeout,
    connectionsCheckingInterval: limits.connectionsCheckingInterval,
    handshakeTimeout: limits.handshakeTimeout,
  };
}

interface LanEndpointOptions extends LanEndpointConfig, LanEndpointHandlers {
  readonly logger: GatewayLogger;
  readonly port: number;
  readonly listenerLimits: LanListenerLimits;
}

interface LanCredentials {
  readonly key: string;
  readonly certificate: string;
}

export interface LanAdvertisement {
  readonly endpoints: readonly { readonly host: string; readonly port: number }[];
  readonly pin?: string;
}

export function lanPin(certificate: string): string {
  let publicKey: KeyObject;
  try {
    publicKey = new X509Certificate(certificate).publicKey;
  } catch {
    throw new LanCredentialError("certificate_unreadable");
  }
  return createHash("sha256").update(publicKeyPoint(publicKey)).digest("base64");
}

function publicKeyPoint(publicKey: KeyObject): Buffer {
  const exported: unknown = publicKey.export({ format: "jwk" });
  if (!isEcPublicJwk(exported)) throw new LanCredentialError("certificate_unreadable");
  return Buffer.concat([
    Buffer.from([0x04]),
    Buffer.from(exported.x, "base64url"),
    Buffer.from(exported.y, "base64url"),
  ]);
}

function isEcPublicJwk(value: unknown): value is { readonly kty: string; readonly x: string; readonly y: string } {
  if (value === null || typeof value !== "object") return false;
  const candidate = value as { kty?: unknown; x?: unknown; y?: unknown };
  return candidate.kty === "EC" && typeof candidate.x === "string" && typeof candidate.y === "string";
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

export function selfSignedCertificate(privateKey: KeyObject, commonName: string, now = new Date()): string {
  const algorithm = derSequence(derOid(OID_ECDSA_WITH_SHA256));
  const name = derSequence(derSet(derSequence(derOid(OID_COMMON_NAME), derUtf8(commonName))));
  const subjectPublicKeyInfo = createPublicKey(privateKey).export({ type: "spki", format: "der" });
  const extensions = derContext(3, derSequence(
    derSequence(derOid(OID_BASIC_CONSTRAINTS), derBoolean(true), derOctetString(derSequence(derBoolean(false)))),
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

async function loadOrCreateLanCredentials(stateDirectory: string): Promise<LanCredentials> {
  const keyPath = join(stateDirectory, LAN_KEY_FILE);
  const certificatePath = join(stateDirectory, LAN_CERTIFICATE_FILE);
  const [key, certificate] = await Promise.all([readOptional(keyPath), readOptional(certificatePath)]);
  if (key !== null && certificate !== null) return validateCredentials(key, certificate);
  if (key !== null) return completeLanCredentials(key, certificatePath);
  if (certificate !== null) throw new LanCredentialError("certificate_incomplete");
  await mkdir(stateDirectory, { recursive: true, mode: 0o700 });
  const { privateKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  const created = validateCredentials(
    privateKey.export({ type: "pkcs8", format: "pem" }).toString(),
    selfSignedCertificate(privateKey, hostname()),
  );
  try {
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

async function completeLanCredentials(key: string, certificatePath: string): Promise<LanCredentials> {
  let privateKey: KeyObject;
  try {
    privateKey = createPrivateKey(key);
  } catch {
    throw new LanCredentialError("certificate_unreadable");
  }
  const completed = validateCredentials(key, selfSignedCertificate(privateKey, hostname()));
  try {
    await writeFile(certificatePath, completed.certificate, { mode: 0o600, flag: "wx" });
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
    const existing = await readOptional(certificatePath);
    if (existing === null) throw new LanCredentialError("certificate_incomplete");
    return validateCredentials(key, existing);
  }
  return completed;
}

export class LanEndpoint {
  private credentials: LanCredentials | undefined;
  private pin: string | undefined;
  private listener: SecureServer | undefined;
  private bound: (LanAddress & { readonly port: number }) | undefined;
  private timer: NodeJS.Timeout | undefined;
  private stopped = false;
  private reconcileInFlight: Promise<void> | undefined;
  private readonly acceptedSockets = new Set<Duplex>();
  private disabledReason: LanListenerReason | undefined;

  constructor(private readonly options: LanEndpointOptions) {}

  async start(): Promise<void> {
    if (!this.options.enabled) {
      this.recordDisabled("setting_off", "info");
      return;
    }
    try {
      this.credentials = await loadOrCreateLanCredentials(this.options.stateDirectory);
      this.pin = lanPin(this.credentials.certificate);
    } catch (error) {
      this.recordDisabled(failureReason(error), "warning");
      return;
    }
    await this.reconcile();
    if (this.stopped) return;
    this.timer = setInterval(() => void this.reconcile(), this.options.reconcileIntervalMs ?? LAN_ADDRESS_RECONCILE_MS);
    this.timer.unref();
  }

  advertisement(): LanAdvertisement {
    return {
      endpoints: this.bound === undefined ? [] : [{ host: this.bound.address, port: this.bound.port }],
      ...(this.pin === undefined ? {} : { pin: this.pin }),
    };
  }

  async stop(): Promise<void> {
    this.stopped = true;
    clearInterval(this.timer);
    this.timer = undefined;
    await this.reconcileInFlight;
    await this.retireListener(false);
  }

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
    const rebound = this.listener !== undefined;
    await this.retireListener(true);
    if (this.stopped) return;
    if (next === undefined) {
      this.recordDisabled("no_private_address", "info");
      return;
    }
    const listener = await this.bind(next);
    if (this.stopped) {
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
      `LAN endpoint ${rebound ? "rebound" : "bound"} (state=${rebound ? "rebound" : "bound"} family=${next.family} port=${this.options.port})`,
      { event: "lan.listener", source: "transport" });
  }

  private async bind(address: LanAddress): Promise<SecureServer | undefined> {
    const credentials = this.credentials!;
    const limits = this.options.listenerLimits;
    let listener: SecureServer;
    try {
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
    listener.on("clientError", (error, socket) => this.options.onClientError(error, socket));
    listener.prependListener("tlsClientError", (error, socket) => this.options.onTlsClientError(error, socket));
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
