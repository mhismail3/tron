import { lstat, mkdir, readdir, rm, stat } from "node:fs/promises";
import { createHash } from "node:crypto";
import { join } from "node:path";
import type { JsonValue } from "../protocol/types.js";
import { AsyncMutex } from "../util/async-mutex.js";
import { atomicWriteJson, readJson } from "../util/json.js";
import { GatewayError } from "../errors.js";
import { isGatewayTimestamp } from "../util/timestamp.js";

const COMMAND_RECEIPT_MAX_BYTES = 1_048_576 + 4 * 1_024;
// High-frequency revisioned UI updates are still idempotent mutations. Keep a
// generous entry ceiling so normal sustained editing cannot block unrelated
// commands; aggregate bytes remain the primary disk safety bound.
const COMMAND_RECEIPT_MAX_ENTRIES = 32_768;
const COMMAND_RECEIPT_MAX_AGGREGATE_BYTES = 64 * 1_048_576;
const COMMAND_RECEIPT_MAX_AGE_MS = 24 * 60 * 60_000;
const COMMAND_RECEIPT_PRUNE_INTERVAL_MS = 60_000;
// Editor changes are superseded by their revisioned successors. Retain their
// idempotency response long enough to cover reconnect/retry, but not for the
// full command window: sustained typing otherwise exhausts shared capacity.
const EDITOR_UPDATE_RECEIPT_MAX_AGE_MS = 10 * 60_000;

interface CommandReceiptCapacity {
  maximumEntries?: number;
  maximumAggregateBytes?: number;
  maximumAgeMs?: number;
}

interface CommandReceiptUsage {
  entries: number;
  bytes: number;
}

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

function isCanonicalReceiptName(name: string): boolean {
  return /^[A-Za-z0-9_-]{43}\.json$/.test(name);
}

function isOwnedTemporaryReceiptName(name: string): boolean {
  return /^[A-Za-z0-9_-]{43}\.json\.\d+\.[0-9a-f]{12}\.tmp$/.test(name);
}

export class CommandReceiptStore {
  private readonly directory: string;
  private readonly lanes = new Map<string, {
    mutex: AsyncMutex;
    users: number;
    preserveReceiptUntilDrain: boolean;
  }>();
  private readonly inventoryMutex = new AsyncMutex();
  private readonly maximumEntries: number;
  private readonly maximumAggregateBytes: number;
  private readonly maximumAgeMs: number;
  private reservedCompletionBytes = 0;
  private inventory: CommandReceiptUsage | undefined;
  private nextPruneAt = 0;

  constructor(
    tronHome: string,
    private readonly writeReceipt: (path: string, value: unknown, mode?: number) => Promise<void> = atomicWriteJson,
    capacity: CommandReceiptCapacity = {},
  ) {
    this.directory = join(tronHome, "gateway", "command-receipts");
    this.maximumEntries = capacity.maximumEntries ?? COMMAND_RECEIPT_MAX_ENTRIES;
    this.maximumAggregateBytes = capacity.maximumAggregateBytes ?? COMMAND_RECEIPT_MAX_AGGREGATE_BYTES;
    this.maximumAgeMs = capacity.maximumAgeMs ?? COMMAND_RECEIPT_MAX_AGE_MS;
    if (!Number.isSafeInteger(this.maximumEntries) || this.maximumEntries <= 0
      || !Number.isSafeInteger(this.maximumAggregateBytes) || this.maximumAggregateBytes < COMMAND_RECEIPT_MAX_BYTES
      || !Number.isSafeInteger(this.maximumAgeMs) || this.maximumAgeMs < 0) {
      throw new Error("Invalid command receipt capacity");
    }
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

  private async inventoryUsage(): Promise<CommandReceiptUsage> {
    if (this.inventory) return this.inventory;
    let names: string[];
    try { names = await readdir(this.directory); }
    catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") {
        return { entries: 0, bytes: 0 };
      }
      throw error;
    }
    let bytes = 0;
    let entries = 0;
    for (const name of names) {
      if (!isCanonicalReceiptName(name)) continue;
      try {
        const metadata = await lstat(join(this.directory, name));
        if (!metadata.isFile()) continue;
        entries += 1;
        bytes += metadata.size;
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
      }
    }
    this.inventory = { entries, bytes };
    return this.inventory;
  }

  private recordNewReceipt(bytes: number): void {
    if (!this.inventory) return;
    this.inventory.entries += 1;
    this.inventory.bytes += bytes;
  }

  private replaceReceiptBytes(previousBytes: number, nextBytes: number): void {
    if (!this.inventory) return;
    this.inventory.bytes += nextBytes - previousBytes;
  }

  private removeReceipt(bytes: number): void {
    if (!this.inventory) return;
    this.inventory.entries -= 1;
    this.inventory.bytes -= bytes;
  }

  private async pruneUnlocked(maxAgeMs: number, force = false): Promise<void> {
    const now = Date.now();
    if (!force && now < this.nextPruneAt) return;
    this.nextPruneAt = now + COMMAND_RECEIPT_PRUNE_INTERVAL_MS;
    let names: string[];
    try { names = await readdir(this.directory); }
    catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return;
      throw error;
    }
    let changed = false;
    for (const name of names) {
      const path = join(this.directory, name);
      if (isOwnedTemporaryReceiptName(name)) {
        await rm(path, { force: true });
        changed = true;
        continue;
      }
      if (!isCanonicalReceiptName(name)) continue;
      let receipt: Receipt | null;
      try { receipt = await this.readReceipt(path); }
      catch (error) {
        if (isOutcomeUnknown(error)) continue;
        throw error;
      }
      if (!receipt || receipt.status !== "completed") continue;
      const expectedKey = createHash("sha256")
        .update(receipt.identityHash).update("\0").update(receipt.method).update("\0").update(receipt.commandId)
        .digest("base64url");
      const expectedName = `${expectedKey}.json`;
      if (this.lanes.get(expectedKey)?.preserveReceiptUntilDrain) continue;
      const receiptMaxAgeMs = receipt.method === "extension.editor.update"
        ? Math.min(maxAgeMs, EDITOR_UPDATE_RECEIPT_MAX_AGE_MS)
        : maxAgeMs;
      if (name === expectedName && Date.parse(receipt.createdAt) < now - receiptMaxAgeMs) {
        await rm(path, { force: true });
        changed = true;
      }
    }
    // A prune may remove arbitrary pre-existing evidence. Rebuild once on the
    // next admission instead of carrying a potentially stale cached total.
    if (changed) this.inventory = undefined;
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
    const lane = this.lanes.get(key) ?? {
      mutex: new AsyncMutex(),
      users: 0,
      preserveReceiptUntilDrain: false,
    };
    lane.users += 1;
    this.lanes.set(key, lane);
    try {
      return await lane.mutex.run(async () => {
        const path = join(this.directory, `${key}.json`);
        const pending: Receipt = {
          version: 1,
          identityHash,
          commandId,
          method,
          status: "pending",
          createdAt: new Date().toISOString(),
        };
        const pendingBytes = persistedReceiptBytes(pending);
        let reserved = false;
        const recorded = await this.inventoryMutex.run(async () => {
          await mkdir(this.directory, { recursive: true, mode: 0o700 });
          await this.pruneUnlocked(this.maximumAgeMs, this.maximumAgeMs === 0);
          const existing = await this.readReceipt(path);
          if (existing) {
            if (existing.identityHash !== identityHash || existing.method !== method || existing.commandId !== commandId) {
              throw outcomeUnknown("Idempotency receipt identity mismatch; refresh authoritative state instead of replaying");
            }
            if (existing.status === "completed") return { exists: true, result: existing.result ?? null } as const;
            throw new GatewayError("conflict", "Previous command outcome is uncertain; refresh authoritative state instead of replaying", false, { outcomeUnknown: true });
          }
          let usage = await this.inventoryUsage();
          if (usage.entries >= this.maximumEntries
            || usage.bytes + this.reservedCompletionBytes + COMMAND_RECEIPT_MAX_BYTES > this.maximumAggregateBytes) {
            // A capacity boundary is also an admission boundary: force one
            // exact cleanup pass before rejecting, so a just-expired
            // high-frequency receipt cannot unnecessarily block the command.
            await this.pruneUnlocked(this.maximumAgeMs, true);
            usage = await this.inventoryUsage();
            if (usage.entries >= this.maximumEntries
              || usage.bytes + this.reservedCompletionBytes + COMMAND_RECEIPT_MAX_BYTES > this.maximumAggregateBytes) {
              throw new GatewayError("busy", "Command receipt capacity is full; retry after completed receipts expire", true);
            }
          }
          this.reservedCompletionBytes += COMMAND_RECEIPT_MAX_BYTES;
          reserved = true;
          try {
            await this.writeReceipt(path, pending);
            this.recordNewReceipt(pendingBytes);
            lane.preserveReceiptUntilDrain = true;
          } catch (error) {
            this.reservedCompletionBytes -= COMMAND_RECEIPT_MAX_BYTES;
            reserved = false;
            throw error;
          }
          return { exists: false } as const;
        });
        if (recorded.exists) return recorded.result;

        let result: JsonValue;
        try {
          result = await operation();
        } catch (error) {
          // An observed application rejection is definitive. Only process/transport
          // loss may leave a pending receipt as an uncertain outcome.
          await this.inventoryMutex.run(async () => {
            try {
              await rm(path, { force: true });
              this.removeReceipt(pendingBytes);
            } finally {
              if (reserved) this.reservedCompletionBytes -= COMMAND_RECEIPT_MAX_BYTES;
              reserved = false;
            }
          });
          throw error;
        }
        const completed: Receipt = { ...pending, status: "completed", result };
        const completedBytes = persistedReceiptBytes(completed);
        if (completedBytes > COMMAND_RECEIPT_MAX_BYTES) {
          await this.inventoryMutex.run(async () => {
            if (reserved) this.reservedCompletionBytes -= COMMAND_RECEIPT_MAX_BYTES;
            reserved = false;
          });
          throw outcomeUnknown("Successful command receipt exceeds its bounded capacity; refresh authoritative state instead of replaying");
        }
        try {
          await this.inventoryMutex.run(async () => {
            await this.writeReceipt(path, completed);
            this.replaceReceiptBytes(pendingBytes, completedBytes);
            if (reserved) this.reservedCompletionBytes -= COMMAND_RECEIPT_MAX_BYTES;
            reserved = false;
          });
        } catch (error) {
          await this.inventoryMutex.run(async () => {
            if (reserved) this.reservedCompletionBytes -= COMMAND_RECEIPT_MAX_BYTES;
            reserved = false;
          });
          throw error;
        }
        return result;
      });
    } finally {
      lane.users -= 1;
      if (lane.users === 0 && this.lanes.get(key) === lane) this.lanes.delete(key);
    }
  }

  async prune(maxAgeMs = this.maximumAgeMs): Promise<void> {
    await this.inventoryMutex.run(async () => {
      await this.pruneUnlocked(maxAgeMs, true);
    });
  }
}
