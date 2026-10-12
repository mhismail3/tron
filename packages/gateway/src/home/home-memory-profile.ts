import { createHash } from "node:crypto";
import { join } from "node:path";
import type { ModelRef } from "../protocol/types.js";
import { GatewayError } from "../errors.js";
import { durablePublishBoundedJson, durableRemove } from "../util/durable-json.js";
import { readSecureJson } from "../util/secure-json.js";
import { updateJsonLocked } from "../util/json.js";
import { SettingsChangeRecord, type ChangeEntry } from "../admin/settings-record.js";

export const HOME_PROFILE_BYTES = 256 * 1024;
const HOME_BYTES = 16 * 1024 * 1024;
const TRANSFER_BYTES = HOME_BYTES + HOME_PROFILE_BYTES + 4096;
const digest = (value: unknown) => createHash("sha256").update(JSON.stringify(value)).digest("hex");
const object = (value: unknown): value is Record<string, unknown> => Boolean(value && typeof value === "object" && !Array.isArray(value));

function memoryModel(value: unknown): ModelRef | undefined {
  if (value === undefined) return undefined;
  if (!object(value) || Object.keys(value).some(key => !["provider", "id"].includes(key))
    || typeof value.provider !== "string" || !value.provider.trim() || Buffer.byteLength(value.provider) > 120
    || typeof value.id !== "string" || !value.id.trim() || Buffer.byteLength(value.id) > 300) {
    throw new GatewayError("conflict", "Home Profile memory model is invalid");
  }
  return { provider: value.provider, id: value.id };
}

async function profile(path: string): Promise<Record<string, unknown>> {
  const read = await readSecureJson<unknown>(path, HOME_PROFILE_BYTES);
  if (!read.present) return {};
  if (!object(read.value) || (read.value.memory !== undefined && !object(read.value.memory))) {
    throw new GatewayError("conflict", "Home Profile is invalid");
  }
  return read.value;
}

/** Home owns the memory configuration. Only Profile supplies the model; the
 * chapter ledger retains pause state, never a second model or a fallback. */
export class HomeMemoryProfile {
  readonly path: string;
  constructor(private readonly tronHome: string) { this.path = join(tronHome, "gateway", "home", "profile.json"); }

  async model(): Promise<ModelRef | undefined> {
    const document = await profile(this.path);
    return memoryModel((document.memory as Record<string, unknown> | undefined)?.model);
  }

  async setModel(model: ModelRef): Promise<void> {
    const value = memoryModel(model)!;
    // The same per-path lock as other Profile settings preserves worker values.
    await updateJsonLocked<Record<string, unknown>>(this.path, {}, document => {
      if (!object(document) || (document.memory !== undefined && !object(document.memory))) throw new GatewayError("conflict", "Home Profile is invalid");
      const next = { ...document, memory: { ...document.memory as Record<string, unknown> | undefined, model: value } };
      if (Buffer.byteLength(JSON.stringify(next)) > HOME_PROFILE_BYTES) throw new GatewayError("conflict", "Home Profile exceeds its byte limit");
      return next;
    }, HOME_PROFILE_BYTES);
  }

  /** Approved one-time transfer, before Home admission. The durable intent fences
   * all three publications: Profile, audit, then removal from home.json. Restart
   * finishes only this exact intent; conflicting bytes refuse without overwrite. */
  async transfer(admit: (value: unknown) => boolean): Promise<void> {
    const directory = join(this.tronHome, "gateway", "home");
    const homePath = join(directory, "home.json");
    const intentPath = join(directory, "memory-profile-transfer.json");
    const read = await readSecureJson<unknown>(intentPath, TRANSFER_BYTES);
    let intent: Transfer;
    if (read.present) {
      const value = read.value;
      if (!object(value) || value.version !== 1 || typeof value.beforeHome !== "string" || typeof value.beforeProfile !== "string"
        || !object(value.home) || !object(value.profile) || !object(value.audit) || !admit(value.home)) throw new GatewayError("conflict", "Home memory transfer intent is invalid");
      intent = value as unknown as Transfer;
      const model = memoryModel((intent.profile.memory as Record<string, unknown> | undefined)?.model);
      const expected = transferAudit(intent.home, model, intent.audit.at);
      if (!model || digest(intent.audit) !== digest(expected)) throw new GatewayError("conflict", "Home memory transfer audit is invalid");
    } else {
      const source = await readSecureJson<unknown>(homePath, HOME_BYTES);
      if (!source.present || !object(source.value) || !object(source.value.memory) || source.value.memory.model === undefined) return;
      const old = source.value;
      const memory = old.memory as Record<string, unknown>;
      if (Object.keys(memory).some(key => !["model", "paused"].includes(key))) throw new GatewayError("conflict", "Legacy Home memory configuration is invalid");
      const model = memoryModel(memory.model)!;
      const home = { ...old, memory: memory.paused === true ? { paused: true } : {} };
      if ((memory.paused !== undefined && memory.paused !== true) || !admit(home)) throw new GatewayError("conflict", "Legacy Home record is invalid");
      const original = await profile(this.path);
      const current = memoryModel((original.memory as Record<string, unknown> | undefined)?.model);
      if (current && digest(current) !== digest(model)) throw new GatewayError("conflict", "Home memory transfer conflicts with Profile");
      const next = { ...original, memory: { ...original.memory as Record<string, unknown> | undefined, model } };
      if (Buffer.byteLength(JSON.stringify(next)) > HOME_PROFILE_BYTES) throw new GatewayError("conflict", "Home Profile exceeds its byte limit");
      intent = { version: 1, beforeHome: digest(old), beforeProfile: digest(original), home, profile: next,
        audit: transferAudit(home, model, new Date().toISOString()) };
      await durablePublishBoundedJson(intentPath, intent, TRANSFER_BYTES);
    }
    const currentHome = await readSecureJson<unknown>(homePath, HOME_BYTES);
    const currentProfile = await profile(this.path);
    if (!currentHome.present || ![intent.beforeHome, digest(intent.home)].includes(digest(currentHome.value))
      || ![intent.beforeProfile, digest(intent.profile)].includes(digest(currentProfile))) {
      throw new GatewayError("conflict", "Home memory transfer stores changed; preserve the intent and inspect the conflict");
    }
    if (digest(currentProfile) !== digest(intent.profile)) await durablePublishBoundedJson(this.path, intent.profile, HOME_PROFILE_BYTES);
    await new SettingsChangeRecord(this.tronHome).appendOnce(intent.audit);
    if (digest(currentHome.value) !== digest(intent.home)) await durablePublishBoundedJson(homePath, intent.home, HOME_BYTES);
    await durableRemove(intentPath);
  }
}

interface Transfer {
  version: 1; beforeHome: string; beforeProfile: string;
  home: Record<string, unknown>; profile: Record<string, unknown>; audit: ChangeEntry;
}
function transferAudit(home: Record<string, unknown>, model: ModelRef | undefined, at: string): ChangeEntry {
  if (!model || typeof at !== "string" || !Number.isFinite(Date.parse(at))) throw new GatewayError("conflict", "Home memory transfer audit is invalid");
  return { changeId: `home-memory-profile-${digest(home.homeId)}`, at,
    actor: { kind: "home", id: "home-memory-profile-transfer" }, target: { kind: "home" }, layer: "profile",
    key: "model.ref[role=memory]", qualifiers: { role: "memory" }, op: "set", before: model, after: model,
    reason: "One-time Home memory model transfer to Profile", tier: "notify",
    tierBasis: { direction: "widen", floor: "notify", floorSource: "code", web: false, risk: null }, status: "applied" };
}
