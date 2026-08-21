import { createHash, randomBytes, randomUUID, timingSafeEqual } from "node:crypto";
import { mkdir } from "node:fs/promises";
import { join } from "node:path";
import { AsyncMutex } from "../util/async-mutex.js";
import { atomicWriteJson, removeIfExists } from "../util/json.js";
import { readSecureJson, SecureJsonFileError } from "../util/secure-json.js";
import { isGatewayTimestamp } from "../util/timestamp.js";
import { GatewayError } from "../errors.js";

interface LocalAuthDocument {
  version: 2;
  bearerToken: string;
  purpose: "local-wrapper-health";
  lastUpdated: string;
}

/** Internal credential-bearing record. Never expose this over RPC or auth context. */
export interface DeviceRecord {
  id: string;
  name: string;
  tokenHash: string;
  createdAt: string;
}

export interface DeviceIdentity {
  kind: "device";
  deviceId: string;
}

export type DeviceListEntry = Omit<DeviceRecord, "tokenHash">;

export const MAXIMUM_PAIRED_DEVICES = 256;
const MAXIMUM_DEVICE_DOCUMENT_BYTES = 1 * 1_024 * 1_024;
const MAXIMUM_LOCAL_AUTH_DOCUMENT_BYTES = 4 * 1_024;
const MAXIMUM_ENROLLMENT_DOCUMENT_BYTES = 16 * 1_024;

interface DeviceDocument {
  version: 1;
  devices: DeviceRecord[];
}

export interface EnrollmentDocument {
  version: 1;
  code: string;
  expiresAt: string;
  machineId: string;
}

export interface PairingResult {
  deviceId: string;
  token: string;
}

function tokenHash(token: string): Buffer {
  return createHash("sha256").update(token, "utf8").digest();
}

function canonicalTokenHash(encoded: string): Buffer | null {
  try {
    const decoded = Buffer.from(encoded, "base64url");
    return decoded.length === 32 && decoded.toString("base64url") === encoded ? decoded : null;
  } catch {
    return null;
  }
}

function equalHash(token: string, encoded: string): boolean {
  const expected = canonicalTokenHash(encoded);
  if (!expected) return false;
  const actual = tokenHash(token);
  return timingSafeEqual(actual, expected);
}

function makeToken(): string {
  return `trn_${randomBytes(32).toString("base64url")}`;
}

function hasOnlyKeys(value: Record<string, unknown>, keys: readonly string[]): boolean {
  const allowed = new Set(keys);
  return Object.keys(value).every((key) => allowed.has(key)) && Object.keys(value).length === keys.length;
}

function isLocalAuthDocument(value: unknown): value is LocalAuthDocument {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const document = value as Record<string, unknown>;
  if (!hasOnlyKeys(document, ["version", "bearerToken", "purpose", "lastUpdated"])) return false;
  return document.version === 2
    && document.purpose === "local-wrapper-health"
    && typeof document.bearerToken === "string"
    && Buffer.byteLength(document.bearerToken) >= 32
    && Buffer.byteLength(document.bearerToken) <= 256
    && typeof document.lastUpdated === "string" && isGatewayTimestamp(document.lastUpdated);
}

function isEnrollmentDocument(value: unknown, machineId: string): value is EnrollmentDocument {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const document = value as Record<string, unknown>;
  if (!hasOnlyKeys(document, ["version", "code", "expiresAt", "machineId"])) return false;
  return document.version === 1
    && typeof document.code === "string" && /^[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{10}$/.test(document.code)
    && document.machineId === machineId
    && typeof document.expiresAt === "string" && isGatewayTimestamp(document.expiresAt);
}

function makeEnrollmentCode(): string {
  const alphabet = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ";
  const bytes = randomBytes(10);
  return Array.from(bytes, (byte) => alphabet[byte % alphabet.length]).join("");
}

interface OwnedDocument<T> {
  present: boolean;
  value?: T;
}

async function readOwnedDocument<T>(path: string, maximumBytes: number, description: string): Promise<OwnedDocument<T>> {
  try {
    const result = await readSecureJson<T>(path, maximumBytes);
    return result.present ? { present: true, value: result.value } : { present: false };
  } catch (error) {
    if (error instanceof SecureJsonFileError || error instanceof RangeError || error instanceof SyntaxError) {
      throw new GatewayError("conflict", `${description} is unsafe, malformed, or oversized`);
    }
    throw error;
  }
}

export class DeviceStore {
  private readonly gatewayDir: string;
  private readonly authPath: string;
  private readonly devicePath: string;
  private readonly enrollmentPath: string;
  private readonly mutex = new AsyncMutex();
  private readonly maximumDevices: number;
  private localToken = "";

  constructor(
    tronHome: string,
    private readonly machineId: string,
    options: { maximumDevices?: number } = {},
  ) {
    this.gatewayDir = join(tronHome, "gateway");
    this.authPath = join(this.gatewayDir, "local-auth.json");
    this.devicePath = join(this.gatewayDir, "devices.json");
    this.enrollmentPath = join(this.gatewayDir, "enrollment.json");
    this.maximumDevices = options.maximumDevices ?? MAXIMUM_PAIRED_DEVICES;
    if (typeof machineId !== "string" || Buffer.byteLength(machineId) < 1 || Buffer.byteLength(machineId) > 256) {
      throw new Error("Machine identity is invalid");
    }
    if (!Number.isSafeInteger(this.maximumDevices) || this.maximumDevices < 1) {
      throw new Error("Paired device bounds are invalid");
    }
  }

  private async readDevices(): Promise<DeviceDocument> {
    const result = await readOwnedDocument<DeviceDocument>(
      this.devicePath,
      MAXIMUM_DEVICE_DOCUMENT_BYTES,
      "Paired device storage",
    );
    const document = result.present ? result.value : { version: 1 as const, devices: [] };
    if (!document || typeof document !== "object"
      || !hasOnlyKeys(document as unknown as Record<string, unknown>, ["version", "devices"])
      || document.version !== 1 || !Array.isArray(document.devices)
      || document.devices.length > this.maximumDevices) {
      throw new GatewayError("conflict", "Paired device storage exceeds its bounded catalog");
    }
    const ids = new Set<string>();
    const hashes = new Set<string>();
    for (const device of document.devices) {
      const legacy = device as DeviceRecord & { lastSeenAt?: unknown };
      if (!device || typeof device !== "object" || Array.isArray(device)
        || !hasOnlyKeys(device as unknown as Record<string, unknown>, [
          "id", "name", "tokenHash", "createdAt", ...(legacy.lastSeenAt === undefined ? [] : ["lastSeenAt"]),
        ])
        || typeof device.id !== "string" || device.id.length === 0 || Buffer.byteLength(device.id) > 100
        || typeof device.name !== "string" || device.name.length === 0 || Buffer.byteLength(device.name) > 320
        || /[\u0000-\u001f\u007f]/.test(device.name)
        || typeof device.tokenHash !== "string" || canonicalTokenHash(device.tokenHash) === null
        || typeof device.createdAt !== "string" || !isGatewayTimestamp(device.createdAt)
        || (legacy.lastSeenAt !== undefined && (typeof legacy.lastSeenAt !== "string" || !isGatewayTimestamp(legacy.lastSeenAt)))
        || ids.has(device.id) || hashes.has(device.tokenHash)) {
        throw new GatewayError("conflict", "Paired device storage is malformed or ambiguous");
      }
      ids.add(device.id);
      hashes.add(device.tokenHash);
    }
    // Legacy lastSeenAt is accepted for migration, but is deliberately not part
    // of the current in-memory or persisted projection.
    return {
      version: 1,
      devices: document.devices.map(({ id, name, tokenHash, createdAt }) => ({ id, name, tokenHash, createdAt })),
    };
  }

  async initialize(): Promise<void> {
    await mkdir(this.gatewayDir, { recursive: true, mode: 0o700 });
    const existing = await this.readSecureAuth();
    if (existing.present) {
      if (!isLocalAuthDocument(existing.value)) {
        throw new GatewayError("conflict", "Local Gateway credential storage is malformed or has the wrong purpose");
      }
      this.localToken = existing.value.bearerToken;
    } else {
      this.localToken = makeToken();
      const document: LocalAuthDocument = {
        version: 2,
        bearerToken: this.localToken,
        purpose: "local-wrapper-health",
        lastUpdated: new Date().toISOString(),
      };
      await atomicWriteJson(this.authPath, document);
    }
    await this.ensureEnrollment();
  }

  private async readSecureAuth(): Promise<OwnedDocument<LocalAuthDocument>> {
    return readOwnedDocument(this.authPath, MAXIMUM_LOCAL_AUTH_DOCUMENT_BYTES, "Local Gateway credential storage");
  }

  private async ensureEnrollmentLocked(now: Date): Promise<EnrollmentDocument> {
    const current = (await readOwnedDocument<EnrollmentDocument>(
      this.enrollmentPath,
      MAXIMUM_ENROLLMENT_DOCUMENT_BYTES,
      "Pairing invitation storage",
    )).value ?? null;
    if (isEnrollmentDocument(current, this.machineId) && Date.parse(current.expiresAt) > now.getTime()) {
      return current;
    }
    const enrollment: EnrollmentDocument = {
      version: 1,
      code: makeEnrollmentCode(),
      expiresAt: new Date(now.getTime() + 10 * 60_000).toISOString(),
      machineId: this.machineId,
    };
    await atomicWriteJson(this.enrollmentPath, enrollment);
    return enrollment;
  }

  async ensureEnrollment(now = new Date()): Promise<EnrollmentDocument> {
    return this.mutex.run(() => this.ensureEnrollmentLocked(now));
  }

  async pair(code: string, deviceName: string): Promise<PairingResult> {
    return this.mutex.run(async () => {
      const enrollment = (await readOwnedDocument<EnrollmentDocument>(
        this.enrollmentPath,
        MAXIMUM_ENROLLMENT_DOCUMENT_BYTES,
        "Pairing invitation storage",
      )).value ?? null;
      if (!isEnrollmentDocument(enrollment, this.machineId) || Date.parse(enrollment.expiresAt) <= Date.now()) {
        await removeIfExists(this.enrollmentPath);
        throw new GatewayError("unauthenticated", "Pairing code expired");
      }
      const actual = Buffer.from(code.toUpperCase(), "utf8");
      const expected = Buffer.from(enrollment.code, "utf8");
      if (actual.length !== expected.length || !timingSafeEqual(actual, expected)) {
        throw new GatewayError("unauthenticated", "Pairing code is invalid");
      }

      const token = makeToken();
      const safeDeviceName = deviceName.replace(/[\u0000-\u001f\u007f]/g, "").trim().slice(0, 80);
      const record: DeviceRecord = {
        id: randomUUID(),
        name: safeDeviceName || "Mobile device",
        tokenHash: tokenHash(token).toString("base64url"),
        createdAt: new Date().toISOString(),
      };
      const document = await this.readDevices();
      if (document.devices.length >= this.maximumDevices) {
        throw new GatewayError("conflict", "Paired device capacity is full; revoke an old device before pairing another");
      }
      document.devices.push(record);
      // Consume first: once pairing has been accepted, a persistence failure
      // must not leave the invitation reusable. Regenerate explicitly while
      // still holding the mutex if the device write fails.
      await removeIfExists(this.enrollmentPath);
      try {
        await atomicWriteJson(this.devicePath, document);
      } catch (error) {
        await this.ensureEnrollmentLocked(new Date()).catch(() => {});
        throw error;
      }
      queueMicrotask(() => void this.ensureEnrollment());
      return { deviceId: record.id, token };
    });
  }

  async authenticate(token: string | undefined): Promise<{ kind: "local" } | DeviceIdentity | null> {
    if (!token) return null;
    const localActual = tokenHash(token);
    const localExpected = tokenHash(this.localToken);
    if (localActual.length === localExpected.length && timingSafeEqual(localActual, localExpected)) {
      return { kind: "local" };
    }
    const document = await this.readDevices();
    const device = document.devices.find((candidate) => equalHash(token, candidate.tokenHash));
    return device ? { kind: "device", deviceId: device.id } : null;
  }

  async listDevices(): Promise<DeviceListEntry[]> {
    const document = await this.readDevices();
    return document.devices.map(({ tokenHash: _tokenHash, ...device }) => device);
  }

  async revoke(deviceId: string): Promise<boolean> {
    return this.mutex.run(async () => {
      const document = await this.readDevices();
      const next = document.devices.filter((device) => device.id !== deviceId);
      if (next.length === document.devices.length) return false;
      await atomicWriteJson(this.devicePath, { version: 1, devices: next });
      return true;
    });
  }
}
