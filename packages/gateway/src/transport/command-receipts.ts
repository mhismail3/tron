import { lstat, mkdir, readdir, rm, stat } from "node:fs/promises";
import { createHash } from "node:crypto";
import { join } from "node:path";
import type { CommandReceiptRouteCategory, JsonValue } from "../protocol/types.js";
import { AsyncMutex } from "../util/async-mutex.js";
import { readJson } from "../foundation/json.js";
import { durableAtomicWriteJson } from "../foundation/durable-json.js";
import { GatewayError, isUncertainOutcome } from "../errors.js";
import { isGatewayTimestamp } from "../util/timestamp.js";
import { count, stage, wait } from "../util/request-span.js";
import { tronHomePath } from "../foundation/tron-home-layout.js";

const COMMAND_RECEIPT_MAX_BYTES = 1_048_576 + 4 * 1_024;
const COMMAND_RECEIPT_MAX_ENTRIES = 32_768;
const COMMAND_RECEIPT_MAX_AGGREGATE_BYTES = 64 * 1_048_576;
const COMMAND_RECEIPT_MAX_AGE_MS = 24 * 60 * 60_000;
export const COMMAND_RECEIPT_PRUNE_INTERVAL_MS = 60_000;
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

export interface CommandReceiptBinding {
  homeId: string;
  bindingRevision: number;
  physicalSessionId: string;
}

interface CommandReceiptExecutionOptions {
  onRouteBound?: (category: CommandReceiptRouteCategory) => void;
  resolveBinding?: () => CommandReceiptBinding | Promise<CommandReceiptBinding>;
  respondBeforeCompletion?: boolean;
  onCompletion?: (completion: Promise<void>) => void;
  onCompletionError?: (error: unknown) => void;
}

interface Receipt {
  version: 1 | 2;
  identityHash: string;
  binding?: CommandReceiptBinding;
  commandId: string;
  method: string;
  status: "pending" | "completed";
  createdAt: string;
  result?: JsonValue;
}

function outcomeUnknown(message: string): GatewayError {
  return new GatewayError("conflict", message, false, { outcomeUnknown: true });
}

function isReceiptBinding(value: unknown): value is CommandReceiptBinding {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const binding = value as Record<string, unknown>;
  return Object.keys(binding).length === 3
    && typeof binding.homeId === "string" && binding.homeId.length > 0 && binding.homeId.length <= 200
    && Number.isSafeInteger(binding.bindingRevision) && (binding.bindingRevision as number) > 0
    && typeof binding.physicalSessionId === "string" && binding.physicalSessionId.length > 0 && binding.physicalSessionId.length <= 200;
}

function isReceipt(value: unknown): value is Receipt {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const receipt = value as Record<string, unknown>;
  const keys = Object.keys(receipt);
  const expectedKeys = ["version", "identityHash", "commandId", "method", "status", "createdAt",
    ...(receipt.version === 2 ? ["binding"] : []), ...(receipt.result === undefined ? [] : ["result"])];
  const binding = receipt.binding;
  return keys.length === expectedKeys.length && keys.every((key) => expectedKeys.includes(key))
    && (receipt.version === 1 || receipt.version === 2)
    && (receipt.version === 1 ? binding === undefined : isReceiptBinding(binding))
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
    unaccountedWrite: boolean;
    creditedBytes: number | undefined;
  }>();
  private readonly inventoryMutex = new AsyncMutex();
  private readonly maximumEntries: number;
  private readonly maximumAggregateBytes: number;
  private readonly maximumAgeMs: number;
  private reservedCompletionBytes = 0;
  private inventory: CommandReceiptUsage | undefined;
  private closed = false;
  private disposalPromise: Promise<void> | undefined;
  private readonly persistence = new Set<Promise<unknown>>();

  private trackPersistence<T>(work: Promise<T>): Promise<T> {
    this.persistence.add(work);
    void work.then(
      () => this.persistence.delete(work),
      () => this.persistence.delete(work),
    );
    return work;
  }

  constructor(
    tronHome: string,
    private readonly writeReceipt: (path: string, value: unknown, mode?: number) => Promise<void> = durableAtomicWriteJson,
    capacity: CommandReceiptCapacity = {},
  ) {
    this.directory = tronHomePath(tronHome, "state/command-receipts");
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
      const lane = this.lanes.get(name.slice(0, 43));
      if (lane?.unaccountedWrite) {
        if (lane.creditedBytes !== undefined) {
          entries += 1;
          bytes += lane.creditedBytes;
        }
        continue;
      }
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

  private async pruneUnlocked(maxAgeMs: number): Promise<void> {
    const now = Date.now();
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
        if (this.lanes.has(name.slice(0, 43))) continue;
        await rm(path, { force: true });
        changed = true;
        continue;
      }
      if (!isCanonicalReceiptName(name)) continue;
      let receipt: Receipt | null;
      try { receipt = await this.readReceipt(path); }
      catch (error) {
        if (isUncertainOutcome(error)) continue;
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
    if (changed) this.inventory = undefined;
  }

  private releaseLane(key: string, lane: { users: number }): void {
    lane.users -= 1;
    if (lane.users === 0 && this.lanes.get(key) === lane) this.lanes.delete(key);
  }

  async execute(
    identity: string,
    method: string,
    commandId: string,
    operation: () => Promise<JsonValue>,
    options: CommandReceiptExecutionOptions = {},
  ): Promise<JsonValue> {
    if (this.closed) throw new GatewayError("conflict", "Command receipt store is shutting down", true);
    if (!/^[A-Za-z0-9._:-]{8,160}$/.test(commandId)) {
      throw new GatewayError("invalid_request", "Mutating requests require a stable commandId");
    }
    const identityHash = createHash("sha256").update(identity).digest("base64url");
    const key = createHash("sha256").update(identityHash).update("\0").update(method).update("\0").update(commandId).digest("base64url");
    if (options.respondBeforeCompletion && method !== "session.prompt" && method !== "home.prompt") {
      throw new Error("Early receipt responses are restricted to prompt methods");
    }
    const lane = this.lanes.get(key) ?? {
      mutex: new AsyncMutex(),
      users: 0,
      preserveReceiptUntilDrain: false,
      unaccountedWrite: false,
      creditedBytes: undefined,
    };
    lane.users += 1;
    this.lanes.set(key, lane);
    let resolveEarly!: (result: JsonValue) => void;
    let rejectEarly!: (error: unknown) => void;
    const earlyResult = options.respondBeforeCompletion
      ? new Promise<JsonValue>((resolve, reject) => { resolveEarly = resolve; rejectEarly = reject; })
      : undefined;
    let releaseLaneAfterExecution = false;
    try {
      const execution = wait("receipt.command-lane", (acquired) => lane.mutex.run(async () => {
        acquired();
        const path = join(this.directory, `${key}.json`);
        let pending: Receipt | undefined;
        let pendingBytes = 0;
        let reserved = false;
        const replay = await stage("receipt.inventory-admission", () => this.inventoryMutex.run(async () => {
          await mkdir(this.directory, { recursive: true, mode: 0o700 });
          const existing = await this.readReceipt(path);
          if (!existing) return undefined;
          if (existing.identityHash !== identityHash || existing.method !== method || existing.commandId !== commandId) {
            throw outcomeUnknown("Idempotency receipt identity mismatch; refresh authoritative state instead of replaying");
          }
          if (existing.status === "completed") {
            if (existing.binding) options.onRouteBound?.("replay");
            return { result: existing.result ?? null } as const;
          }
          throw new GatewayError("conflict", "Previous command outcome is uncertain; refresh authoritative state instead of replaying", false, { outcomeUnknown: true });
        }));
        if (replay) return replay.result;
        const binding = await options.resolveBinding?.();
        await stage("receipt.inventory-admission", () => this.inventoryMutex.run(async () => {
          pending = {
            version: binding ? 2 : 1,
            identityHash,
            ...(binding ? { binding } : {}),
            commandId,
            method,
            status: "pending",
            createdAt: new Date().toISOString(),
          };
          pendingBytes = persistedReceiptBytes(pending);
          let usage = await this.inventoryUsage();
          if (usage.entries >= this.maximumEntries
            || usage.bytes + this.reservedCompletionBytes + COMMAND_RECEIPT_MAX_BYTES > this.maximumAggregateBytes) {
            await this.pruneUnlocked(this.maximumAgeMs);
            usage = await this.inventoryUsage();
            if (usage.entries >= this.maximumEntries
              || usage.bytes + this.reservedCompletionBytes + COMMAND_RECEIPT_MAX_BYTES > this.maximumAggregateBytes) {
              throw new GatewayError("busy", "Command receipt capacity is full; completed receipts expire, but unresolved outcomes retain replay protection and require operator reconciliation", true);
            }
          }
          this.reservedCompletionBytes += COMMAND_RECEIPT_MAX_BYTES;
          reserved = true;
        }));
        if (!pending) throw new Error("Command receipt pending record was not prepared");
        lane.unaccountedWrite = true;
        try {
          await stage("receipt.pending-persist", () => this.trackPersistence(this.writeReceipt(path, pending)));
        } catch (error) {
          await this.inventoryMutex.run(async () => {
            lane.unaccountedWrite = false;
            if (reserved) this.reservedCompletionBytes -= COMMAND_RECEIPT_MAX_BYTES;
            reserved = false;
          });
          throw error;
        }
        lane.preserveReceiptUntilDrain = true;
        await this.inventoryMutex.run(async () => {
          lane.creditedBytes = pendingBytes;
          lane.unaccountedWrite = false;
          this.recordNewReceipt(pendingBytes);
        });

        let result: JsonValue;
        try {
          if (pending.binding) options.onRouteBound?.("fresh");
          result = await operation();
        } catch (error) {
          const uncertain = isUncertainOutcome(error);
          await this.inventoryMutex.run(async () => {
            try {
              if (!uncertain) {
                await this.trackPersistence(rm(path, { force: true }));
                this.removeReceipt(pendingBytes);
                lane.creditedBytes = undefined;
              }
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
        lane.unaccountedWrite = true;
        const persistCompletion = async (): Promise<void> => {
          try {
            if (options.respondBeforeCompletion) await this.trackPersistence(this.writeReceipt(path, completed));
            else await stage("receipt.completed-persist", () => this.trackPersistence(this.writeReceipt(path, completed)));
          } catch (error) {
            await this.inventoryMutex.run(async () => {
              lane.unaccountedWrite = false;
              if (reserved) this.reservedCompletionBytes -= COMMAND_RECEIPT_MAX_BYTES;
              reserved = false;
            });
            throw error;
          }
          await this.inventoryMutex.run(async () => {
            lane.creditedBytes = completedBytes;
            lane.unaccountedWrite = false;
            this.replaceReceiptBytes(pendingBytes, completedBytes);
            if (reserved) this.reservedCompletionBytes -= COMMAND_RECEIPT_MAX_BYTES;
            reserved = false;
          });
        };
        if (options.respondBeforeCompletion) {
          count("receipt.completed-persist");
          const completion = persistCompletion().catch((error: unknown) => {
            try { options.onCompletionError?.(error); } catch { }
          });
          options.onCompletion?.(completion);
          resolveEarly(result);
          await completion;
        } else {
          await persistCompletion();
        }
        return result;
      }));
      if (!earlyResult) return await execution;
      releaseLaneAfterExecution = true;
      void execution.then(resolveEarly, rejectEarly);
      void execution.then(() => this.releaseLane(key, lane), () => this.releaseLane(key, lane));
      return await earlyResult;
    } finally {
      if (!releaseLaneAfterExecution) this.releaseLane(key, lane);
    }
  }

  dispose(): Promise<void> {
    if (this.disposalPromise) return this.disposalPromise;
    this.closed = true;
    this.disposalPromise = (async () => {
      while (this.persistence.size > 0) {
        await Promise.allSettled([...this.persistence]);
      }
    })();
    return this.disposalPromise;
  }

  async prune(maxAgeMs = this.maximumAgeMs): Promise<void> {
    if (this.closed) return;
    await this.inventoryMutex.run(async () => {
      await this.pruneUnlocked(maxAgeMs);
    });
  }
}
