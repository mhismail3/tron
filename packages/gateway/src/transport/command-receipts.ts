import { lstat, mkdir, readdir, rm, stat } from "node:fs/promises";
import { createHash } from "node:crypto";
import { join } from "node:path";
import type { JsonValue } from "../protocol/types.js";
import { AsyncMutex } from "../util/async-mutex.js";
import { readJson } from "../util/json.js";
import { durableAtomicWriteJson } from "../util/durable-json.js";
import { GatewayError, isUncertainOutcome } from "../errors.js";
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
    /** True from the start of a receipt write until that write's accounting has
     * run, so a concurrent rebuild knows the disk state of this receipt is not
     * yet authoritative. */
    unaccountedWrite: boolean;
    /** Bytes this lane's receipt contributes to `inventory`; `undefined` until
     * the pending write's accounting has run. A rebuild credits this value
     * instead of the file while `unaccountedWrite` holds. */
    creditedBytes: number | undefined;
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
    private readonly writeReceipt: (path: string, value: unknown, mode?: number) => Promise<void> = durableAtomicWriteJson,
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
      // A receipt write runs outside the mutex, so the disk may already carry
      // its result while its accounting step has not run yet. Credit what that
      // step will account for instead of the file, so its change lands on a
      // total that has not counted the receipt yet: the pending size once the
      // lane has recorded one, and nothing at all before that (the pending
      // receipt, if already renamed, is not evidence the accounting has seen).
      // Reading the file here would count it twice, and discarding these totals
      // instead would make every writing command force the next admission to
      // rescan this directory. The first 43 characters are the command key both
      // receipt name patterns are built from (`isOwnedTemporaryReceiptName`).
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
        // A lane is registered before its command writes and removed only after
        // every user of that command finishes, so it is present for both the
        // pending and the completed write. A temporary whose lane still exists
        // is a publication in flight: removing it would fail that write with
        // ENOENT after its operation already ran. Only crash leftovers, whose
        // lane is gone, are scavenged. The first 43 characters are the command
        // key both receipt name patterns are built from
        // (`isOwnedTemporaryReceiptName`).
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
    // A prune may remove arbitrary pre-existing evidence. Rebuild once on the
    // next admission instead of carrying a potentially stale cached total. It
    // is the only step that invalidates the cache, so a rebuild can only be
    // caused by a prune that removed something, never by a write in flight.
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
      unaccountedWrite: false,
      creditedBytes: undefined,
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
        // Admission is accounting only. `inventoryMutex` guards the entry/byte
        // inventory and the inflight byte reservations; the durable write is a
        // per-command lane's own slow step and runs outside it. Holding the
        // process-wide mutex across the fsync serialized every other command's
        // receipt write behind one command's disk write.
        const admission = await this.inventoryMutex.run(async () => {
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
              // Completed receipts expire on their own, but an uncertain outcome is
              // a permanent replay fence by design. Name that distinction so an
              // operator can act on a genuinely exhausted store instead of waiting
              // for an expiry that never comes.
              throw new GatewayError("busy", "Command receipt capacity is full; completed receipts expire, but unresolved outcomes retain replay protection and require operator reconciliation", true);
            }
          }
          // The reservation covers this receipt's bytes until they are in the
          // inventory, so a concurrent admission still counts them. It is
          // released only with the completed receipt, which may be larger.
          this.reservedCompletionBytes += COMMAND_RECEIPT_MAX_BYTES;
          reserved = true;
          return { exists: false } as const;
        });
        if (admission.exists) return admission.result;
        // This write's accounting is the only step that adds its bytes to the
        // totals, so the lane reports it as unaccounted before the publication
        // can be seen by a concurrent admission's rebuild. A failed write
        // clears that again: whatever reached the disk is then the truth.
        lane.unaccountedWrite = true;
        try {
          await this.writeReceipt(path, pending);
        } catch (error) {
          await this.inventoryMutex.run(async () => {
            lane.unaccountedWrite = false;
            if (reserved) this.reservedCompletionBytes -= COMMAND_RECEIPT_MAX_BYTES;
            reserved = false;
          });
          throw error;
        }
        // A duplicate lane keeps its completed receipt until every duplicate
        // drains, so a concurrent prune cannot delete the fence the next
        // duplicate is about to read. Pending receipts are never pruned by age,
        // so the fence only has to exist once this command has a receipt to
        // preserve.
        lane.preserveReceiptUntilDrain = true;
        await this.inventoryMutex.run(async () => {
          lane.creditedBytes = pendingBytes;
          lane.unaccountedWrite = false;
          this.recordNewReceipt(pendingBytes);
        });

        let result: JsonValue;
        try {
          result = await operation();
        } catch (error) {
          // An owner that reports an uncertain outcome may already have applied its
          // effect (post-effect persistence or cleanup failure). Retain the pending
          // receipt so the identical command cannot replay: callers must
          // reconcile authoritative state before deciding on a new command. An observed
          // application rejection is definitive and remains retryable.
          const uncertain = isUncertainOutcome(error);
          await this.inventoryMutex.run(async () => {
            try {
              if (!uncertain) {
                await rm(path, { force: true });
                this.removeReceipt(pendingBytes);
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
        try {
          await this.writeReceipt(path, completed);
        } catch (error) {
          await this.inventoryMutex.run(async () => {
            lane.unaccountedWrite = false;
            if (reserved) this.reservedCompletionBytes -= COMMAND_RECEIPT_MAX_BYTES;
            reserved = false;
          });
          throw error;
        }
        await this.inventoryMutex.run(async () => {
          // The exact persisted size replaces the pending estimate in the same
          // step that releases the reservation that covered it. A rebuild that
          // landed during the write credited this lane's pending size rather
          // than the file (see `inventoryUsage`), so that difference is exactly
          // what is left to apply here.
          lane.creditedBytes = completedBytes;
          lane.unaccountedWrite = false;
          this.replaceReceiptBytes(pendingBytes, completedBytes);
          if (reserved) this.reservedCompletionBytes -= COMMAND_RECEIPT_MAX_BYTES;
          reserved = false;
        });
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
