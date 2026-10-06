import { randomUUID } from "node:crypto";
import { chmod, mkdir } from "node:fs/promises";
import { join } from "node:path";
import type { HomeDesignation, HomeStatus, ModelRef } from "../protocol/types.js";
import { GatewayError } from "../errors.js";
import type { TrustService } from "../admin/trust-service.js";
import { AsyncMutex } from "../util/async-mutex.js";
import { durableAtomicWriteJson } from "../util/durable-json.js";
import { boundedString, boundedTimestamp, readJson } from "../util/json.js";

/** One Gateway installation keeps at most one Home. */
const VERSION = 1;
const MAXIMUM_RECORD_BYTES = 16 * 1_024;
const MAXIMUM_PROVIDER_BYTES = 120;
const MAXIMUM_MODEL_ID_BYTES = 300;
/** The curated Home profile this record was written against. A profile change
 * that alters the runtime contract bumps it, so the record states which one
 * produced the designation. */
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

/** The session operations Home needs from the runtime owner. Kept narrow so the
 * Home record's authority is never a second session owner. */
export interface HomeSessionPort {
  /** Create one session whose very first runtime already has the Home profile. */
  createHomeSession(cwd: string): Promise<string>;
  /** Apply the recorded model to a live, idle Home session. */
  applySessionModel(sessionId: string, model: ModelRef): Promise<void>;
  /** Whether the session currently holds a live runtime. */
  hasLiveRuntime(sessionId: string): boolean;
  /** Whether the session is running admitted work. */
  isBusy(sessionId: string): boolean;
  /** Retire the session's live runtime when it is idle. False when it is busy
   * or a concurrent admission kept it live. */
  retireIdleRuntime(sessionId: string): Promise<boolean>;
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
 * directory beside it, and whether a session id is the enabled Home.
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

  status(): HomeStatus {
    if (this.unavailable) return { available: false, reason: this.unavailable, enabled: false, live: false };
    const record = this.record;
    if (!record) return { available: true, enabled: false, live: false };
    return {
      available: true,
      enabled: record.enabled,
      homeId: record.homeId,
      sessionId: record.sessionId,
      generation: record.generation,
      model: { ...record.model },
      live: this.options.sessions.hasLiveRuntime(record.sessionId),
    };
  }

  /** Whether this exact session id is the enabled Home right now. Runtime
   * creation reads this for every runtime it builds, so a retired runtime is
   * rebuilt with the profile the record currently names. */
  isEnabledHome(sessionId: string): boolean {
    return this.record?.enabled === true && this.record.sessionId === sessionId;
  }

  /** `home.designate`. Idempotent for an enabled record; a disabled record is
   * re-enabled on the same session with the next generation. */
  async designate(model: ModelRef): Promise<HomeDesignation> {
    return this.mutex.run(async () => {
      this.assertAvailable();
      const existing = this.record;
      if (existing?.enabled) return designation(existing);
      if (existing) {
        // Refuse before writing, so a busy session leaves the record untouched.
        this.assertProfileChangePossible(existing.sessionId);
        const next: HomeRecord = {
          ...existing,
          enabled: true,
          generation: existing.generation + 1,
          updatedAt: new Date().toISOString(),
        };
        await this.write(next);
        await this.retireProfileRuntime(next.sessionId);
        this.options.diagnostic?.({ outcome: "enabled" });
        return designation(next);
      }
      const cwd = await this.ensureWorkspace();
      // An explicit decision, so `requireResolved` never blocks on the neutral
      // directory and no project resource can load from it.
      await this.options.trust.set(cwd, false);
      const sessionId = await this.options.sessions.createHomeSession(cwd);
      try {
        await this.options.sessions.applySessionModel(sessionId, model);
        const now = new Date().toISOString();
        const record: HomeRecord = {
          version: VERSION,
          homeId: randomUUID(),
          sessionId,
          generation: 1,
          policyRevision: HOME_POLICY_REVISION,
          enabled: true,
          model: { ...model },
          createdAt: now,
          updatedAt: now,
        };
        await this.write(record);
        this.options.diagnostic?.({ outcome: "designated" });
        return designation(record);
      } catch (error) {
        // No record means no Home: retire the profile-carrying runtime so the
        // unrecorded session cannot keep the curated profile.
        await this.options.sessions.retireIdleRuntime(sessionId).catch(() => false);
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
      this.assertProfileChangePossible(existing.sessionId);
      const next: HomeRecord = {
        ...existing,
        enabled: false,
        generation: existing.generation + 1,
        updatedAt: new Date().toISOString(),
      };
      await this.write(next);
      await this.retireProfileRuntime(next.sessionId);
      this.options.diagnostic?.({ outcome: "disabled" });
      return designation(next);
    });
  }

  private assertAvailable(): void {
    if (!this.unavailable) return;
    this.options.diagnostic?.({ outcome: "unavailable", reason: this.unavailable });
    throw new GatewayError("conflict", `Tron Home is unavailable: ${this.unavailable}. The existing record was preserved.`);
  }

  private assertProfileChangePossible(sessionId: string): void {
    if (!this.options.sessions.isBusy(sessionId)) return;
    this.options.diagnostic?.({ outcome: "refused", reason: "session-busy" });
    throw new GatewayError("busy", "Tron Home's session is running; retry when it is idle", true);
  }

  /** A profile change takes effect at the next runtime creation, so the live
   * runtime must go. The session was proven idle immediately before the record
   * write; a run admitted in that window keeps the previous profile until its
   * next reload. */
  private async retireProfileRuntime(sessionId: string): Promise<void> {
    await this.options.sessions.retireIdleRuntime(sessionId);
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
      loaded = await readJson<unknown | undefined>(this.recordPath, undefined, MAXIMUM_RECORD_BYTES);
    } catch {
      this.record = undefined;
      this.unavailable = "The Home record could not be read";
      this.options.diagnostic?.({ outcome: "unavailable", reason: "unreadable" });
      return;
    }
    if (loaded === undefined) {
      this.record = undefined;
      this.unavailable = undefined;
      return;
    }
    const admitted = admitRecord(loaded);
    if (!admitted) {
      // Preserved, never replaced: an unrecognized record is not evidence that
      // the user did not designate a Home.
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

/** Admit one stored record, or undefined for anything this build cannot use. */
function admitRecord(value: unknown): HomeRecord | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const root = value as Record<string, unknown>;
  const model = root.model;
  if (root.version !== VERSION
    || !boundedString(root.homeId, 200)
    || !boundedString(root.sessionId, 200)
    || !Number.isSafeInteger(root.generation) || (root.generation as number) < 1
    || root.policyRevision !== HOME_POLICY_REVISION
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
    policyRevision: HOME_POLICY_REVISION,
    enabled: root.enabled,
    model: { provider: modelRecord.provider, id: modelRecord.id },
    createdAt: root.createdAt,
    updatedAt: root.updatedAt,
  };
}
