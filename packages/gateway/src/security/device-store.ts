import { createHash, randomBytes, randomUUID, timingSafeEqual } from "node:crypto";
import { chmod, mkdir, stat } from "node:fs/promises";
import { join } from "node:path";
import { AsyncMutex } from "../util/async-mutex.js";
import { atomicWriteJson, readJson, removeIfExists } from "../util/json.js";
import { GatewayError } from "../errors.js";

interface LocalAuthDocument {
  version: 2;
  bearerToken: string;
  purpose: "local-wrapper-health";
  lastUpdated: string;
}

export interface DeviceRecord {
  id: string;
  name: string;
  tokenHash: string;
  createdAt: string;
  lastSeenAt?: string;
}

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

function equalHash(token: string, encoded: string): boolean {
  let expected: Buffer;
  try {
    expected = Buffer.from(encoded, "base64url");
  } catch {
    return false;
  }
  const actual = tokenHash(token);
  return actual.length === expected.length && timingSafeEqual(actual, expected);
}

function makeToken(): string {
  return `trn_${randomBytes(32).toString("base64url")}`;
}

function makeEnrollmentCode(): string {
  const alphabet = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ";
  const bytes = randomBytes(10);
  return Array.from(bytes, (byte) => alphabet[byte % alphabet.length]).join("");
}

export class DeviceStore {
  private readonly gatewayDir: string;
  private readonly authPath: string;
  private readonly devicePath: string;
  private readonly enrollmentPath: string;
  private readonly mutex = new AsyncMutex();
  private localToken = "";

  constructor(
    tronHome: string,
    private readonly machineId: string,
  ) {
    this.gatewayDir = join(tronHome, "gateway");
    this.authPath = join(this.gatewayDir, "local-auth.json");
    this.devicePath = join(this.gatewayDir, "devices.json");
    this.enrollmentPath = join(this.gatewayDir, "enrollment.json");
  }

  async initialize(): Promise<void> {
    await mkdir(this.gatewayDir, { recursive: true, mode: 0o700 });
    const existing = await this.readSecureAuth();
    if (existing?.purpose === "local-wrapper-health" && existing.bearerToken.length >= 32) {
      this.localToken = existing.bearerToken;
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

  private async readSecureAuth(): Promise<LocalAuthDocument | null> {
    try {
      const metadata = await stat(this.authPath);
      if ((metadata.mode & 0o077) !== 0) return null;
      return await readJson<LocalAuthDocument | null>(this.authPath, null);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return null;
      throw error;
    }
  }

  async ensureEnrollment(now = new Date()): Promise<EnrollmentDocument> {
    return this.mutex.run(async () => {
      const current = await readJson<EnrollmentDocument | null>(this.enrollmentPath, null);
      if (current && current.machineId === this.machineId && Date.parse(current.expiresAt) > now.getTime()) {
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
    });
  }

  async pair(code: string, deviceName: string): Promise<PairingResult> {
    return this.mutex.run(async () => {
      const enrollment = await readJson<EnrollmentDocument | null>(this.enrollmentPath, null);
      if (!enrollment || Date.parse(enrollment.expiresAt) <= Date.now()) {
        await removeIfExists(this.enrollmentPath);
        throw new GatewayError("unauthenticated", "Pairing code expired");
      }
      const actual = Buffer.from(code.toUpperCase(), "utf8");
      const expected = Buffer.from(enrollment.code, "utf8");
      if (actual.length !== expected.length || !timingSafeEqual(actual, expected)) {
        throw new GatewayError("unauthenticated", "Pairing code is invalid");
      }

      const token = makeToken();
      const record: DeviceRecord = {
        id: randomUUID(),
        name: deviceName.trim().slice(0, 80) || "Mobile device",
        tokenHash: tokenHash(token).toString("base64url"),
        createdAt: new Date().toISOString(),
      };
      const document = await readJson<DeviceDocument>(this.devicePath, { version: 1, devices: [] });
      document.devices.push(record);
      await atomicWriteJson(this.devicePath, document);
      await removeIfExists(this.enrollmentPath);
      queueMicrotask(() => void this.ensureEnrollment());
      return { deviceId: record.id, token };
    });
  }

  async authenticate(token: string | undefined): Promise<{ kind: "local" } | { kind: "device"; device: DeviceRecord } | null> {
    if (!token) return null;
    const localActual = tokenHash(token);
    const localExpected = tokenHash(this.localToken);
    if (localActual.length === localExpected.length && timingSafeEqual(localActual, localExpected)) {
      return { kind: "local" };
    }
    const document = await readJson<DeviceDocument>(this.devicePath, { version: 1, devices: [] });
    const device = document.devices.find((candidate) => equalHash(token, candidate.tokenHash));
    return device ? { kind: "device", device } : null;
  }

  async listDevices(): Promise<Omit<DeviceRecord, "tokenHash">[]> {
    const document = await readJson<DeviceDocument>(this.devicePath, { version: 1, devices: [] });
    return document.devices.map(({ tokenHash: _tokenHash, ...device }) => device);
  }

  async revoke(deviceId: string): Promise<boolean> {
    return this.mutex.run(async () => {
      const document = await readJson<DeviceDocument>(this.devicePath, { version: 1, devices: [] });
      const next = document.devices.filter((device) => device.id !== deviceId);
      if (next.length === document.devices.length) return false;
      await atomicWriteJson(this.devicePath, { version: 1, devices: next });
      return true;
    });
  }
}
