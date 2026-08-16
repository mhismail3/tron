import { mkdir, readdir, rm, stat } from "node:fs/promises";
import { createHash } from "node:crypto";
import { join } from "node:path";
import type { JsonValue } from "../protocol/types.js";
import { AsyncMutex } from "../util/async-mutex.js";
import { atomicWriteJson, readJson } from "../util/json.js";
import { GatewayError } from "../errors.js";
import { isGatewayTimestamp } from "../util/timestamp.js";

const COMMAND_RECEIPT_MAX_BYTES = 1_048_576 + 4 * 1_024;

interface Receipt {
  version: 1;
  identityHash: string;
  commandId: string;
  method: string;
  status: "pending" | "completed";
  createdAt: string;
  result?: JsonValue;
}

function outcomeUnknown(message: string): GatewayError {
  return new GatewayError("conflict", message, false, { outcomeUnknown: true });
}

function isOutcomeUnknown(error: unknown): error is GatewayError {
  return error instanceof GatewayError
    && !!error.details && typeof error.details === "object"
    && (error.details as Record<string, unknown>).outcomeUnknown === true;
}

function isReceipt(value: unknown): value is Receipt {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const receipt = value as Record<string, unknown>;
  const keys = Object.keys(receipt);
  const expectedKeys = receipt.result === undefined
    ? ["version", "identityHash", "commandId", "method", "status", "createdAt"]
    : ["version", "identityHash", "commandId", "method", "status", "createdAt", "result"];
  return keys.length === expectedKeys.length && keys.every((key) => expectedKeys.includes(key))
    && receipt.version === 1
    && typeof receipt.identityHash === "string" && /^[A-Za-z0-9_-]{43}$/.test(receipt.identityHash)
    && typeof receipt.commandId === "string" && /^[A-Za-z0-9._:-]{8,160}$/.test(receipt.commandId)
    && typeof receipt.method === "string" && Buffer.byteLength(receipt.method) > 0 && Buffer.byteLength(receipt.method) <= 160
    && (receipt.status === "pending" || receipt.status === "completed")
    && typeof receipt.createdAt === "string" && isGatewayTimestamp(receipt.createdAt)
    && (receipt.status === "completed" ? receipt.result !== undefined : receipt.result === undefined);
}

function persistedReceiptBytes(value: unknown): number {
  return Buffer.byteLength(`${JSON.stringify(value, null, 2)}\n`);
}

export class CommandReceiptStore {
  private readonly directory: string;
  private readonly lanes = new Map<string, { mutex: AsyncMutex; users: number }>();

  constructor(
    tronHome: string,
    private readonly writeReceipt: (path: string, value: unknown, mode?: number) => Promise<void> = atomicWriteJson,
  ) {
    this.directory = join(tronHome, "gateway", "command-receipts");
  }

  private async readReceipt(path: string): Promise<Receipt | null> {
    const missing = {};
    let receipt: unknown;
    try { receipt = await readJson<unknown>(path, missing, COMMAND_RECEIPT_MAX_BYTES); }
    catch (error) {
      if (error instanceof RangeError || error instanceof SyntaxError) {
        throw outcomeUnknown("Idempotency receipt is malformed or oversized; refresh authoritative state instead of replaying");
      }
      throw error;
    }
    if (receipt === missing) {
      try {
        await stat(path);
        throw outcomeUnknown("Idempotency receipt is empty; refresh authoritative state instead of replaying");
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code === "ENOENT") return null;
        throw error;
      }
    }
    if (!isReceipt(receipt)) {
      throw outcomeUnknown("Idempotency receipt is malformed; refresh authoritative state instead of replaying");
    }
    return receipt;
  }

  async status(identity: string, method: string, commandId: string): Promise<{ status: "missing" | "pending" | "completed"; result?: JsonValue }> {
    const identityHash = createHash("sha256").update(identity).digest("base64url");
    const key = createHash("sha256").update(identityHash).update("\0").update(method).update("\0").update(commandId).digest("base64url");
    const receipt = await this.readReceipt(join(this.directory, `${key}.json`));
    if (!receipt) return { status: "missing" };
    if (receipt.identityHash !== identityHash || receipt.method !== method || receipt.commandId !== commandId) {
      throw outcomeUnknown("Idempotency receipt identity mismatch; refresh authoritative state instead of replaying");
    }
    return receipt.status === "completed"
      ? { status: "completed", ...(receipt.result === undefined ? {} : { result: receipt.result }) }
      : { status: "pending" };
  }

  async execute(
    identity: string,
    method: string,
    commandId: string,
    operation: () => Promise<JsonValue>,
  ): Promise<JsonValue> {
    if (!/^[A-Za-z0-9._:-]{8,160}$/.test(commandId)) {
      throw new GatewayError("invalid_request", "Mutating requests require a stable commandId");
    }
    const identityHash = createHash("sha256").update(identity).digest("base64url");
    const key = createHash("sha256").update(identityHash).update("\0").update(method).update("\0").update(commandId).digest("base64url");
    const lane = this.lanes.get(key) ?? { mutex: new AsyncMutex(), users: 0 };
    lane.users += 1;
    this.lanes.set(key, lane);
    try {
      return await lane.mutex.run(async () => {
      await mkdir(this.directory, { recursive: true, mode: 0o700 });
      const path = join(this.directory, `${key}.json`);
      const existing = await this.readReceipt(path);
      if (existing) {
        if (existing.identityHash !== identityHash || existing.method !== method || existing.commandId !== commandId) {
          throw outcomeUnknown("Idempotency receipt identity mismatch; refresh authoritative state instead of replaying");
        }
        if (existing.status === "completed") return existing.result ?? null;
        throw new GatewayError("conflict", "Previous command outcome is uncertain; refresh authoritative state instead of replaying", false, { outcomeUnknown: true });
      }
      const pending: Receipt = {
        version: 1,
        identityHash,
        commandId,
        method,
        status: "pending",
        createdAt: new Date().toISOString(),
      };
      await this.writeReceipt(path, pending);
      let result: JsonValue;
      try {
        result = await operation();
      } catch (error) {
        // An observed application rejection is definitive. Only process/transport
        // loss may leave a pending receipt as an uncertain outcome.
        await rm(path, { force: true });
        throw error;
      }
      const completed: Receipt = { ...pending, status: "completed", result };
      if (persistedReceiptBytes(completed) > COMMAND_RECEIPT_MAX_BYTES) {
        throw outcomeUnknown("Successful command receipt exceeds its bounded capacity; refresh authoritative state instead of replaying");
      }
      await this.writeReceipt(path, completed);
      return result;
      });
    } finally {
      lane.users -= 1;
      if (lane.users === 0 && this.lanes.get(key) === lane) this.lanes.delete(key);
    }
  }

  async prune(maxAgeMs = 24 * 60 * 60_000): Promise<void> {
    try {
      const cutoff = Date.now() - maxAgeMs;
      for (const name of await readdir(this.directory)) {
        if (!name.endsWith(".json")) continue;
        const path = join(this.directory, name);
        let receipt: Receipt | null;
        try { receipt = await this.readReceipt(path); }
        catch (error) {
          if (isOutcomeUnknown(error)) continue;
          throw error;
        }
        if (receipt) {
          const expectedName = `${createHash("sha256")
            .update(receipt.identityHash).update("\0").update(receipt.method).update("\0").update(receipt.commandId)
            .digest("base64url")}.json`;
          if (name !== expectedName) continue;
          if (Date.parse(receipt.createdAt) < cutoff) await rm(path, { force: true });
        }
      }
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
  }
}
