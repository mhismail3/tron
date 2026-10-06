import { randomUUID } from "node:crypto";
import { chmod, mkdir } from "node:fs/promises";
import { join } from "node:path";
import type { HomeDesignation, HomeStatus, ModelRef } from "../protocol/types.js";
import { GatewayError } from "../errors.js";
import type { TrustService } from "../admin/trust-service.js";
import { AsyncMutex } from "../util/async-mutex.js";
import { durableAtomicWriteJson } from "../util/durable-json.js";
import { boundedString, boundedTimestamp } from "../util/json.js";
import { readSecureJson, SecureJsonFileError } from "../util/secure-json.js";

/** One Gateway installation keeps at most one Home. */
const VERSION = 1;
const MAXIMUM_RECORD_BYTES = 16 * 1_024;
const MAXIMUM_PROVIDER_BYTES = 120;
const MAXIMUM_MODEL_ID_BYTES = 300;
/** The curated Home profile this build writes. A record written against a newer
 * revision is still this build's record to read: only `version` gates admission,
 * because a profile change is not a format change. */
const HOME_POLICY_REVISION = 1;

export interface HomeRecord {
  version: 1;
  homeId: string;
  sessionId: string;
  generation: number;
  policyRevision: number;
  enabled: boolean;
  model: ModelRef;
  createdAt: string;
  updatedAt: string;
}

/** What the Home record says about one session id. `unnamed` means the record
 * does not name that session, which is the only window in which a creation-time
 * profile argument applies. */
export type HomeSessionProfile = "home" | "ordinary" | "unnamed";

/** The session operations Home needs from the runtime owner. Kept narrow so the
 * Home record's authority is never a second session owner. */
export interface HomeSessionPort {
  /** Create one session whose very first runtime already has the Home profile. */
  createHomeSession(cwd: string): Promise<string>;
  /** Apply the recorded model to a live Home session through the slot's normal
   * `setModel` path, when the live model differs. */
  applySessionModel(sessionId: string, model: ModelRef): Promise<void>;
  /** Whether the session exists at all: a live runtime, or a canonical session
   * the catalog or disk still holds. */
  sessionPresent(sessionId: string): Promise<boolean>;
  /** Whether the session currently holds a live runtime. */
  hasLiveRuntime(sessionId: string): boolean;
  /** Replace the session's live runtime in place after `commit` changes the
   * profile decision for it, so the next prompt uses the new profile. A busy
   * session refuses retryably before `commit` runs. */
  replaceRuntimeForProfile(sessionId: string, commit: () => Promise<void>): Promise<void>;
}

export type HomeDiagnostic = (diagnostic: {
  outcome: "designated" | "enabled" | "disabled" | "refused" | "unavailable";
  reason?: string;
}) => void;

export interface HomeOwnerOptions {
  tronHome: string;
  trust: TrustService;
  sessions: HomeSessionPort;
  diagnostic?: HomeDiagnostic;
}

/**
 * The one owner of Tron Home's designation for this Gateway installation: the
 * durable record under `<tronHome>/gateway/home/home.json`, the neutral working
 * directory beside it, and the profile decision for every session id.
 *
 * Designation is keyed by session id, so a fork of the Home session is an
 * ordinary session with no further work. Nothing here builds memory, tasks or
 * request policy; those are later slices, and until they exist a designated
 * Home behaves as an ordinary session to clients.
 */
export class HomeOwner {
  private readonly directory: string;
  private readonly recordPath: string;
  private readonly workspacePath: string;
  private readonly mutex = new AsyncMutex();
  private record: HomeRecord | undefined;
  private unavailable: string | undefined;

  constructor(private readonly options: HomeOwnerOptions) {
    this.directory = join(options.tronHome, "gateway", "home");
    this.recordPath = join(this.directory, "home.json");
    this.workspacePath = join(this.directory, "workspace");
  }

  /** Load the durable record once, before any runtime can ask for a profile. */
  async initialize(): Promise<void> {
    await this.load();
  }

  async status(): Promise<HomeStatus> {
    if (this.unavailable) {
      return { available: false, reason: this.unavailable, enabled: false, live: false, sessionPresent: false };
    }
    const record = this.record;
    if (!record) return { available: true, enabled: false, live: false, sessionPresent: false };
    return {
      available: true,
      enabled: record.enabled,
      homeId: record.homeId,
      sessionId: record.sessionId,
      generation: record.generation,
      model: { ...record.model },
      live: this.options.sessions.hasLiveRuntime(record.sessionId),
      sessionPresent: await this.options.sessions.sessionPresent(record.sessionId),
    };
  }

  /** What the record says about one session id. Runtime creation reads this for
   * every runtime it builds, so a replacement is never built from a stale
   * profile decision. */
  profileFor(sessionId: string): HomeSessionProfile {
    const record = this.record;
    if (!record || record.sessionId !== sessionId) return "unnamed";
    return record.enabled ? "home" : "ordinary";
  }

  /**
   * `home.designate`. Idempotent for an enabled record whose session still
   * exists. A disabled record is re-enabled on the same session. A record whose
   * session is gone is kept and given a fresh session, because the record is the
   * only evidence of the designation.
   */
  async designate(input: { model?: ModelRef }, defaultModel: () => ModelRef): Promise<HomeDesignation> {
    return this.mutex.run(async () => {
      this.assertAvailable();
      const existing = this.record;
      if (existing && await this.options.sessions.sessionPresent(existing.sessionId)) {
        if (existing.enabled) return designation(existing);
        // The model is the request's, else the one the record was last
        // designated with; both were admitted before they were recorded.
        const model = input.model ?? existing.model;
        const next: HomeRecord = {
          ...existing,
          enabled: true,
          generation: existing.generation + 1,
          // Re-enabling applies this build's profile, so the record states the
          // revision that is now in force rather than a superseded one.
          policyRevision: HOME_POLICY_REVISION,
          model: { ...model },
          updatedAt: new Date().toISOString(),
        };
        await this.commitProfileChange(next.sessionId, next);
        // A recorded session that is not live needs no runtime work; the next
        // runtime creation reads the record and the model with it.
        if (this.options.sessions.hasLiveRuntime(next.sessionId)) {
          await this.options.sessions.applySessionModel(next.sessionId, model);
        }
        this.options.diagnostic?.({ outcome: "enabled" });
        return designation(next);
      }

      const cwd = await this.ensureWorkspace();
      // An explicit decision, so `requireResolved` never blocks on the neutral
      // directory and no project resource can load from it.
      await this.options.trust.set(cwd, false);
      const model = input.model ?? defaultModel();
      const sessionId = await this.options.sessions.createHomeSession(cwd);
      try {
        await this.options.sessions.applySessionModel(sessionId, model);
        const now = new Date().toISOString();
        const record: HomeRecord = {
          version: VERSION,
          homeId: existing?.homeId ?? randomUUID(),
          sessionId,
          generation: existing ? existing.generation + 1 : 1,
          policyRevision: HOME_POLICY_REVISION,
          enabled: true,
          model: { ...model },
          createdAt: existing?.createdAt ?? now,
          updatedAt: now,
        };
        await this.write(record);
        this.options.diagnostic?.({ outcome: "designated" });
        return designation(record);
      } catch (error) {
        // No record names this session, so it must not keep the creation-time
        // Home profile: replace its runtime with what the record now says.
        await this.options.sessions.replaceRuntimeForProfile(sessionId, async () => {}).catch(() => {});
        throw error;
      }
    });
  }

  /** `home.disable`. The session stays an ordinary session afterwards. */
  async disable(): Promise<HomeDesignation> {
    return this.mutex.run(async () => {
      this.assertAvailable();
      const existing = this.record;
      if (!existing) throw new GatewayError("not_found", "Tron Home is not designated");
      if (!existing.enabled) return designation(existing);
      const next: HomeRecord = {
        ...existing,
        enabled: false,
        generation: existing.generation + 1,
        updatedAt: new Date().toISOString(),
      };
      // A session that is gone needs no runtime work; a live one is rebuilt in
      // place, which is also where a running session is refused.
      if (await this.options.sessions.sessionPresent(next.sessionId)) {
        await this.commitProfileChange(next.sessionId, next);
      } else {
        await this.write(next);
      }
      this.options.diagnostic?.({ outcome: "disabled" });
      return designation(next);
    });
  }

  /**
   * The record is the single source of truth for Home's model, so a model
   * applied to the enabled Home session is recorded. A model applied to the same
   * session while it is disabled is an ordinary session's change and is not.
   */
  async noteModelApplied(sessionId: string, model: ModelRef): Promise<void> {
    const record = this.record;
    if (!record || !record.enabled || record.sessionId !== sessionId) return;
    if (record.model.provider === model.provider && record.model.id === model.id) return;
    await this.write({ ...record, model: { ...model }, updatedAt: new Date().toISOString() });
  }

  private assertAvailable(): void {
    if (!this.unavailable) return;
    this.options.diagnostic?.({ outcome: "unavailable", reason: this.unavailable });
    throw new GatewayError("conflict", `Tron Home is unavailable: ${this.unavailable}. The existing record was preserved.`);
  }

  /** Commit the record and rebuild the live runtime in one serialized step, so a
   * prompt cannot be admitted between the idle check, the write and the rebuild. */
  private async commitProfileChange(sessionId: string, record: HomeRecord): Promise<void> {
    try {
      await this.options.sessions.replaceRuntimeForProfile(sessionId, async () => { await this.write(record); });
    } catch (error) {
      if (error instanceof GatewayError && error.code === "busy") {
        this.options.diagnostic?.({ outcome: "refused", reason: "session-busy" });
      }
      throw error;
    }
  }

  /** Create the neutral working directory owner-only, and resolve it the way
   * the trust store does so the recorded decision is the one sessions see. */
  private async ensureWorkspace(): Promise<string> {
    await mkdir(this.workspacePath, { recursive: true, mode: 0o700 });
    await chmod(this.workspacePath, 0o700);
    return this.options.trust.canonicalDirectory(this.workspacePath);
  }

  private async write(record: HomeRecord): Promise<void> {
    await durableAtomicWriteJson(this.recordPath, record);
    this.record = record;
  }

  private async load(): Promise<void> {
    let loaded: unknown;
    try {
      const read = await readSecureJson<unknown>(this.recordPath, MAXIMUM_RECORD_BYTES);
      if (!read.present) {
        this.record = undefined;
        this.unavailable = undefined;
        return;
      }
      loaded = read.value;
    } catch (error) {
      // An empty, symlinked or permissively-readable file is not an absent one:
      // it is preserved and reported, never replaced.
      this.record = undefined;
      this.unavailable = error instanceof SecureJsonFileError && error.kind === "invalid"
        ? "The Home record is malformed"
        : "The Home record is not a bounded owner-only regular file";
      this.options.diagnostic?.({ outcome: "unavailable", reason: "unreadable" });
      return;
    }
    const admitted = admitRecord(loaded);
    if (!admitted) {
      this.record = undefined;
      this.unavailable = "The Home record has an unsupported shape or version";
      this.options.diagnostic?.({ outcome: "unavailable", reason: "unsupported-record" });
      return;
    }
    this.record = admitted;
    this.unavailable = undefined;
  }
}

function designation(record: HomeRecord): HomeDesignation {
  return { homeId: record.homeId, sessionId: record.sessionId, generation: record.generation };
}

/** Admit one stored record, or undefined for anything this build cannot use.
 * Only the format version gates admission: a newer `policyRevision` is still a
 * record this build can read, preserve and re-enable. */
function admitRecord(value: unknown): HomeRecord | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const root = value as Record<string, unknown>;
  const model = root.model;
  if (root.version !== VERSION
    || !boundedString(root.homeId, 200)
    || !boundedString(root.sessionId, 200)
    || !Number.isSafeInteger(root.generation) || (root.generation as number) < 1
    || !Number.isSafeInteger(root.policyRevision) || (root.policyRevision as number) < 1
    || typeof root.enabled !== "boolean"
    || !boundedTimestamp(root.createdAt)
    || !boundedTimestamp(root.updatedAt)
    || !model || typeof model !== "object" || Array.isArray(model)) return undefined;
  const modelRecord = model as Record<string, unknown>;
  if (!boundedString(modelRecord.provider, MAXIMUM_PROVIDER_BYTES)
    || !boundedString(modelRecord.id, MAXIMUM_MODEL_ID_BYTES)) return undefined;
  return {
    version: VERSION,
    homeId: root.homeId,
    sessionId: root.sessionId,
    generation: root.generation as number,
    policyRevision: root.policyRevision as number,
    enabled: root.enabled,
    model: { provider: modelRecord.provider, id: modelRecord.id },
    createdAt: root.createdAt,
    updatedAt: root.updatedAt,
  };
}
