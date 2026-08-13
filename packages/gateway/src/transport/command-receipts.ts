import { mkdir, readdir, rm } from "node:fs/promises";
import { createHash } from "node:crypto";
import { join } from "node:path";
import type { JsonValue } from "../protocol/types.js";
import { AsyncMutex } from "../util/async-mutex.js";
import { atomicWriteJson, readJson } from "../util/json.js";
import { GatewayError } from "../errors.js";

interface Receipt {
  version: 1;
  identityHash: string;
  commandId: string;
  method: string;
  status: "pending" | "completed";
  createdAt: string;
  result?: JsonValue;
}

export class CommandReceiptStore {
  private readonly directory: string;
  private readonly lanes = new Map<string, { mutex: AsyncMutex; users: number }>();

  constructor(tronHome: string) {
    this.directory = join(tronHome, "gateway", "command-receipts");
  }

  async status(identity: string, method: string, commandId: string): Promise<{ status: "missing" | "pending" | "completed"; result?: JsonValue }> {
    const identityHash = createHash("sha256").update(identity).digest("base64url");
    const key = createHash("sha256").update(identityHash).update("\0").update(method).update("\0").update(commandId).digest("base64url");
    const receipt = await readJson<Receipt | null>(join(this.directory, `${key}.json`), null);
    if (!receipt) return { status: "missing" };
    if (receipt.identityHash !== identityHash || receipt.method !== method || receipt.commandId !== commandId) {
      throw new GatewayError("conflict", "Idempotency receipt identity mismatch");
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
      const existing = await readJson<Receipt | null>(path, null);
      if (existing) {
        if (existing.identityHash !== identityHash || existing.method !== method || existing.commandId !== commandId) {
          throw new GatewayError("conflict", "Idempotency receipt identity mismatch");
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
      await atomicWriteJson(path, pending);
      const result = await operation();
      await atomicWriteJson(path, { ...pending, status: "completed", result });
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
        const receipt = await readJson<Receipt | null>(path, null);
        if (receipt && Date.parse(receipt.createdAt) < cutoff) await rm(path, { force: true });
      }
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
  }
}
