import { createHash, randomBytes, randomUUID } from "node:crypto";
import { constants, lstatSync } from "node:fs";
import { lstat, mkdir, open, readdir, realpath, rename, rm } from "node:fs/promises";
import { isAbsolute, join, resolve, sep } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { pathToFileURL } from "node:url";
import { GatewayError } from "../../errors.js";
import type { JsonValue } from "../../protocol/types.js";
import { AsyncMutex } from "../../util/async-mutex.js";
import { durableAtomicWriteJson, durableAtomicWriteText, syncDurably } from "../../util/durable-json.js";
import { readSecureJson, readSecureText, SecureJsonFileError } from "../../util/secure-json.js";
import type { TronWorkspace } from "../../workspace/tron-workspace.js";
import type { DisplayOwner } from "../../display/display-modules.js";
import { readSwiftDisplaySource } from "./swift-app-display.js";
import { admitDigest, admitFeeds, digest, MANIFEST_BYTES, offerIdentity, referenceKey, readSwiftAppManifest, readSwiftAppOffer,
  type SwiftAppActor, type SwiftAppDisplayReference, type SwiftAppManifest, type SwiftAppOffer, type SwiftAppRevision } from "./swift-app-format.js";
export type { SwiftAppManifest } from "./swift-app-format.js";

/** Installed single-file Swift apps (#1156). One owner for
 * `<workspace>/state/apps/<appId>/`: `app.json` (manifest), `App.swift` (source)
 * and `data.sqlite` (the app's key/value state). docs/swift-apps.md owns the
 * contract that #1158 persistence, #1159 feeds and #1161 the Apps sheet build on. */
export const SWIFT_APPS_CAPABILITY = "swift-apps.v1";

const SWIFT_APP_LIMITS = {
  /** Matches the iPhone's complete-text preview bound; a longer file could never run. */
  sourceBytes: 320_000,
  nameBytes: 80,
  iconBytes: 80,
  apps: 200,
  keyBytes: 256,
  valueBytes: 256 * 1_024,
  entries: 1_000,
  /** Keys plus encoded values; a full snapshot stays well inside one RPC frame. */
  stateBytes: 512 * 1_024,
  writesPerCommit: 256,
  valueDepth: 32,
} as const;

const APP_ID = /^[a-z0-9][a-z0-9-]{0,62}$/;
const SCHEMA_VERSION = 1;

export interface SwiftAppStateSnapshot {
  appId: string;
  revision: number;
  entries: Array<{ key: string; value: JsonValue }>;
}

export interface SwiftAppCommit {
  appId: string;
  expectedRevision: number;
  /** Interpreter writes must still belong to the source that produced them.
   * Agent data seeding does not execute source and does not supply this fence. */
  expectedSourceRevision?: number;
  expectedInstanceId?: string;
  set: Array<{ key: string; value: JsonValue }>;
  remove: string[];
}

export function admitSwiftAppId(value: unknown): string {
  if (typeof value !== "string" || !APP_ID.test(value)) {
    throw new GatewayError("invalid_request", "App id must be 1-63 lowercase letters, digits or hyphens, starting with a letter or digit");
  }
  return value;
}

function boundedLabel(value: unknown, label: string, maximumBytes: number): string {
  if (typeof value !== "string" || value.trim().length === 0 || Buffer.byteLength(value) > maximumBytes || /[\u0000-\u001f\u007f]/u.test(value)) {
    throw new GatewayError("invalid_request", `App ${label} must be 1-${maximumBytes} bytes of single-line text`);
  }
  return value;
}

function admitKey(value: unknown): string {
  if (typeof value !== "string" || value.length === 0 || Buffer.byteLength(value) > SWIFT_APP_LIMITS.keyBytes || /[\u0000-\u001f\u007f]/u.test(value)) {
    throw new GatewayError("invalid_request", `State keys must be 1-${SWIFT_APP_LIMITS.keyBytes} bytes without control characters`);
  }
  return value;
}

/** Plain JSON only: finite numbers, bounded depth, no prototypes or holes. */
function admitValue(value: unknown, depth = 0): void {
  if (depth > SWIFT_APP_LIMITS.valueDepth) throw new GatewayError("invalid_request", `State values may nest at most ${SWIFT_APP_LIMITS.valueDepth} levels`);
  if (value === null || typeof value === "string" || typeof value === "boolean") return;
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new GatewayError("invalid_request", "State numbers must be finite");
    return;
  }
  if (Array.isArray(value)) { for (const item of value) admitValue(item, depth + 1); return; }
  if (typeof value === "object" && Object.getPrototypeOf(value) === Object.prototype) {
    for (const item of Object.values(value as Record<string, unknown>)) admitValue(item, depth + 1);
    return;
  }
  throw new GatewayError("invalid_request", "State values must be JSON");
}

async function syncDirectory(path: string): Promise<void> {
  const handle = await open(path, constants.O_RDONLY);
  try { await syncDurably(handle); } finally { await handle.close(); }
}

/** Present, owner-only and not a link; absent is `false`; anything else refuses. */
async function ownerDirectory(path: string): Promise<boolean> {
  let info;
  try { info = await lstat(path); } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return false;
    throw new GatewayError("conflict", "Swift app storage could not be inspected");
  }
  if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== process.getuid?.() || (info.mode & 0o777) !== 0o700) {
    throw new GatewayError("conflict", "Swift app storage must be owner-only directories; it was left unchanged");
  }
  return true;
}

async function ensureOwnerDirectory(path: string): Promise<boolean> {
  try { await mkdir(path, { mode: 0o700 }); } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
    await ownerDirectory(path);
    return false;
  }
  await ownerDirectory(path);
  return true;
}

/** Read the source an agent names: a visible relative path under `root`, no
 * links, a regular file within the source bound. */
export async function readSwiftAppSourceFile(root: string, requestedPath: string): Promise<string> {
  if (!requestedPath || isAbsolute(requestedPath) || requestedPath.includes("\0")
    || requestedPath.split(/[\\/]/).some(part => !part || part === "." || part === ".." || part.startsWith("."))) {
    throw new GatewayError("invalid_request", "The app source must be a visible relative path");
  }
  if (!requestedPath.endsWith(".swift")) throw new GatewayError("invalid_request", "The app source must be a .swift file");
  const base = await realpath(resolve(root));
  let path = base;
  for (const part of requestedPath.split(/[\\/]/)) {
    path = join(path, part);
    let info;
    try { info = await lstat(path); } catch { throw new GatewayError("not_found", `No file at ${requestedPath}`); }
    if (info.isSymbolicLink()) throw new GatewayError("invalid_request", "The app source path cannot contain symbolic links");
  }
  // A FIFO must reach descriptor validation without waiting for a writer.
  const handle = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const info = await handle.stat();
    if (!info.isFile() || info.size < 1 || info.size > SWIFT_APP_LIMITS.sourceBytes || !(await realpath(path)).startsWith(base + sep)) {
      throw new GatewayError("invalid_request", `The app source must be a file of 1-${SWIFT_APP_LIMITS.sourceBytes} bytes`);
    }
    const bytes = await handle.readFile();
    if (bytes.byteLength !== info.size) throw new GatewayError("conflict", "The app source changed while it was read", true);
    const text = bytes.toString("utf8");
    if (!Buffer.from(text, "utf8").equals(bytes)) throw new GatewayError("invalid_request", "The app source must be UTF-8 text");
    return text;
  } finally { await handle.close(); }
}

export class SwiftAppStore {
  private readonly mutex = new AsyncMutex();
  private initialized = false;

  constructor(private readonly workspace: TronWorkspace, private readonly display: () => DisplayOwner) {}

  private async appsRoot(create: boolean): Promise<string | undefined> {
    const descriptor = await this.workspace.describe();
    if (!descriptor.available) throw new GatewayError("conflict", "Tron internal workspace is unavailable; installed apps cannot be read");
    const state = join(descriptor.root, "state");
    const apps = join(state, "apps");
    const initialized = await this.workspace.featureInitialized("apps")
      .catch(() => { throw new GatewayError("conflict", "The installed-apps initialization record is unreadable; it was left unchanged"); });
    if (!create) {
      if (await ownerDirectory(apps)) return this.readyRoot(apps);
      // A recorded container that has gone is lost state, never a fresh start.
      if (initialized) throw new GatewayError("conflict", "Installed apps are missing after they were created; restore state/apps");
      return undefined;
    }
    if (!(await ownerDirectory(apps)) && initialized) {
      throw new GatewayError("conflict", "Installed apps are missing after they were created; restore state/apps");
    }
    const createdState = await ensureOwnerDirectory(state);
    const createdApps = await ensureOwnerDirectory(apps);
    if (createdState) await syncDirectory(descriptor.root);
    if (createdApps) await syncDirectory(state);
    if (!initialized) await this.workspace.markFeatureInitialized("apps");
    return this.readyRoot(apps);
  }

  private async readyRoot(root: string): Promise<string> {
    if (!this.initialized) {
      await this.cleanupUnpublished(root);
      await this.cleanupOffers(root);
      this.initialized = true;
    }
    return root;
  }

  /** Reconcile against canonical session retention through its existing display
   * owner. No second session catalog, expiry clock or background sweeper. */
  private async cleanupOffers(root: string): Promise<void> {
    const offers = join(root, ".offers");
    if (!await ownerDirectory(offers)) return;
    const display = this.display();
    // Failure to prove canonical membership must not authorize deletion.
    await display.maintainArtifacts();
    for (const name of await readdir(offers)) {
      if (!/^[a-f0-9]{64}$/.test(name)) continue;
      const directory = join(offers, name);
      if (!await ownerDirectory(directory)) continue;
      let offer: SwiftAppOffer;
      try {
        const raw = await readSecureJson<unknown>(join(directory, "offer.json"), 4_096);
        if (!raw.present) continue;
        offer = readSwiftAppOffer(raw.value);
      } catch {
        // Unreadable or corrupt metadata is not proof of an unowned offer.
        continue;
      }
      if (referenceKey(offer.reference) !== name || display.artifacts.hasOwner(offer.reference.artifactId, offer.reference.sessionId)) continue;
      await rm(directory, { recursive: true });
    }
    await syncDirectory(offers);
  }

  /** Called once under the store mutex by a new owner. Only unreachable
   * publication staging is retired; current heads, history and v1 backups stay. */
  private async cleanupUnpublished(root: string): Promise<void> {
    for (const name of await readdir(root)) {
      const directory = join(root, name);
      if (/^\.install-[a-f0-9-]{36}$/.test(name) || /^\.removed-[a-z0-9][a-z0-9-]{0,62}-[a-f0-9]{12}$/.test(name)) {
        if (await ownerDirectory(directory)) await rm(directory, { recursive: true });
        continue;
      }
      if (!APP_ID.test(name) || !await ownerDirectory(directory)) continue;
      const app = await this.readManifest(directory, name);
      if (app.version === 2 && (await readSecureText(join(directory, "App.swift"), SWIFT_APP_LIMITS.sourceBytes)).present) {
        await rm(join(directory, "App.swift"));
        await syncDirectory(directory);
      }
      const sources = join(directory, "sources");
      if (await ownerDirectory(sources)) {
        const retained = new Set((app.version === 2 ? app.history : [app]).map(item => `${item.sourceSha256}.swift`));
        for (const file of await readdir(sources)) {
          if (/^[a-f0-9]{64}\.swift\.[0-9]+\.[a-f0-9]{12}\.tmp$/.test(file)
            || /^[a-f0-9]{64}\.swift$/.test(file) && !retained.has(file)) await rm(join(sources, file));
        }
        await syncDirectory(sources);
      }
      for (const file of await readdir(directory)) {
        if (/^app\.json\.[0-9]+\.[a-f0-9]{12}\.tmp$/.test(file)) await rm(join(directory, file));
      }
      const backups = join(directory, "backups");
      if (await ownerDirectory(backups)) {
        for (const file of await readdir(backups)) {
          if (/^\.backup-[a-f0-9-]{36}$/.test(file) && await ownerDirectory(join(backups, file))) await rm(join(backups, file), { recursive: true });
        }
      }
    }
    await syncDirectory(root);
  }

  private async appDirectory(appId: string): Promise<string> {
    const apps = await this.appsRoot(false);
    const directory = apps ? join(apps, appId) : undefined;
    if (!directory || !(await ownerDirectory(directory))) throw new GatewayError("not_found", `No installed app ${appId}`);
    return directory;
  }

  private async readManifest(directory: string, appId: string): Promise<SwiftAppManifest> {
    let read;
    try { read = await readSecureJson<unknown>(join(directory, "app.json"), MANIFEST_BYTES); }
    catch { throw new GatewayError("conflict", `App ${appId} has an unreadable manifest; it was left unchanged`); }
    if (!read.present) throw new GatewayError("conflict", `App ${appId} has no manifest; it was left unchanged`);
    return readSwiftAppManifest(read.value, appId);
  }

  async list(): Promise<SwiftAppManifest[]> {
    return this.mutex.run(async () => {
      const apps = await this.appsRoot(false);
      if (!apps) return [];
      await this.cleanupOffers(apps);
      const manifests: SwiftAppManifest[] = [];
      for (const name of (await readdir(apps)).sort()) {
        if (!APP_ID.test(name)) continue;
        if (!(await ownerDirectory(join(apps, name)))) continue;
        manifests.push(await this.readManifest(join(apps, name), name));
      }
      return manifests;
    });
  }

  /** A disposable projection of canonical offers, not another catalog. Even a
   * retained artifact must still be referenced by its producing session. */
  async pending(): Promise<SwiftAppOffer[]> {
    return this.mutex.run(async () => {
      const apps = await this.appsRoot(false);
      if (!apps) return [];
      await this.cleanupOffers(apps);
      const root = join(apps, ".offers");
      if (!await ownerDirectory(root)) return [];
      const offers: SwiftAppOffer[] = [];
      for (const name of (await readdir(root)).sort()) {
        if (!/^[a-f0-9]{64}$/.test(name)) continue;
        try {
          if (!await ownerDirectory(join(root, name))) continue;
          const raw = await readSecureJson<unknown>(join(root, name, "offer.json"), 4_096);
          if (!raw.present) continue;
          const candidate = readSwiftAppOffer(raw.value);
          if (referenceKey(candidate.reference) !== name || await ownerDirectory(join(apps, candidate.appId))) continue;
          const { offer } = await this.readOffer(candidate.reference);
          const displayed = await readSwiftDisplaySource(await this.display().acquireArtifact(offer.reference.sessionId, offer.reference.artifactId));
          if (digest(displayed) === offer.sourceSha256) offers.push(offer);
        } catch (error) {
          // Invalid or no-longer-owned offers are not installable rows. An
          // unavailable owner/store is not evidence of a successful empty list.
          if (error instanceof SecureJsonFileError
            || error instanceof GatewayError && ["not_found", "conflict", "invalid_request"].includes(error.code) && !error.retryable) continue;
          throw error;
        }
      }
      return offers.sort((a, b) => a.appId.localeCompare(b.appId) || a.id.localeCompare(b.id));
    });
  }

  async get(appId: string): Promise<{ app: SwiftAppManifest; source: string }> {
    admitSwiftAppId(appId);
    return this.mutex.run(async () => {
      const directory = await this.appDirectory(appId);
      const app = await this.readManifest(directory, appId);
      return { app, source: await this.readSource(directory, app) };
    });
  }

  /** One coherent launch snapshot; install/commit/remove cannot interleave. */
  async open(appId: string): Promise<{ app: SwiftAppManifest; source: string; state: SwiftAppStateSnapshot }> {
    admitSwiftAppId(appId);
    return this.mutex.run(async () => {
      const directory = await this.appDirectory(appId);
      const app = await this.readManifest(directory, appId);
      const source = await this.readSource(directory, app);
      const state = this.withDatabase(directory, database => this.snapshot(database, appId));
      return { app, source, state };
    });
  }

  private async readSource(directory: string, app: SwiftAppManifest): Promise<string> {
    let read;
    try { read = await readSecureText(app.version === 1 ? join(directory, "App.swift") : join(directory, "sources", `${app.sourceSha256}.swift`), SWIFT_APP_LIMITS.sourceBytes); }
    catch { read = { present: false as const }; }
    // Source precedes its manifest: a torn reinstall must never execute.
    if (!read.present || createHash("sha256").update(read.value).digest("hex") !== app.sourceSha256) {
      throw new GatewayError("conflict", `App ${app.id}'s source does not match its manifest; reinstall it`);
    }
    return read.value;
  }

  private requireInstance(app: SwiftAppManifest, expected: unknown): void {
    if (app.version === 2 && expected !== app.instanceId) throw new GatewayError("conflict", "This app was removed or replaced; reopen its current identity");
  }

  /** Explicitly offers immutable source/config to paired devices, without installing.
   * Replacing an offer invalidates the old config digest, never changes its meaning. */
  async offer(input: { appId: string; name: string; icon?: string; source: string; feeds: unknown; reference: SwiftAppDisplayReference }, actor: SwiftAppActor): Promise<{ offer: SwiftAppOffer }> {
    const appId = admitSwiftAppId(input.appId);
    const name = boundedLabel(input.name, "name", 80);
    const icon = input.icon === undefined ? undefined : boundedLabel(input.icon, "icon", 80);
    const sourceBytes = Buffer.byteLength(input.source);
    if (sourceBytes < 1 || sourceBytes > SWIFT_APP_LIMITS.sourceBytes) throw new GatewayError("invalid_request", "App source exceeds its bounds");
    const fields = { appId, name, reference: input.reference, ...(icon ? { icon } : {}), sourceSha256: digest(input.source), sourceBytes, feeds: admitFeeds(input.feeds) };
    const offer: SwiftAppOffer = { version: 1, id: offerIdentity(fields), ...fields, actor };
    return this.mutex.run(async () => {
      const apps = (await this.appsRoot(true))!;
      const root = join(apps, ".offers");
      await ensureOwnerDirectory(root);
      const directory = join(root, referenceKey(offer.reference));
      if (!(await ownerDirectory(directory))) {
        const count = async () => (await readdir(root)).filter(name => /^[a-f0-9]{64}$/.test(name)).length;
        if (await count() >= 200) await this.cleanupOffers(apps);
        if (await count() >= 200) throw new GatewayError("conflict", "At most 200 app offers may be retained; discard an unused offer first");
        await ensureOwnerDirectory(directory);
      }
      await durableAtomicWriteText(join(directory, "App.swift"), input.source);
      await durableAtomicWriteJson(join(directory, "offer.json"), offer);
      return { offer };
    });
  }

  private async readOffer(reference: SwiftAppDisplayReference): Promise<{ offer: SwiftAppOffer; source: string }> {
    const root = await this.appsRoot(false);
    if (!root) throw new GatewayError("not_found", "No app offer matches this source; ask Tron to prepare it");
    const directory = join(root, ".offers", referenceKey(reference));
    if (!(await ownerDirectory(directory))) throw new GatewayError("not_found", "No app offer matches this source; ask Tron to prepare it");
    const raw = await readSecureJson<unknown>(join(directory, "offer.json"), 4_096);
    const text = await readSecureText(join(directory, "App.swift"), SWIFT_APP_LIMITS.sourceBytes);
    if (!raw.present || !text.present) throw new GatewayError("conflict", "The app offer is incomplete; ask Tron to prepare it again");
    const offer = readSwiftAppOffer(raw.value);
    if (offer.reference.sessionId !== reference.sessionId || offer.reference.artifactId !== reference.artifactId
      || digest(text.value) !== offer.sourceSha256 || Buffer.byteLength(text.value) !== offer.sourceBytes) {
      throw new GatewayError("conflict", "The app offer's source changed; ask Tron to prepare it again");
    }
    return { offer, source: text.value };
  }

  async review(reference: SwiftAppDisplayReference, sourceSha256: string): Promise<{ offer: SwiftAppOffer; installed: SwiftAppManifest | null }> {
    return this.mutex.run(async () => {
      const { offer } = await this.readOffer(reference);
      if (offer.sourceSha256 !== sourceSha256) throw new GatewayError("conflict", "The granted artifact does not match this offer's source");
      const root = (await this.appsRoot(false))!;
      const directory = join(root, offer.appId);
      const installed = await ownerDirectory(directory) ? await this.readManifest(directory, offer.appId) : null;
      return { offer, installed };
    });
  }

  async discardOffer(reference: SwiftAppDisplayReference): Promise<void> {
    return this.mutex.run(async () => {
      await this.readOffer(reference);
      const root = (await this.appsRoot(false))!;
      await rm(join(root, ".offers", referenceKey(reference)), { recursive: true });
      await syncDirectory(join(root, ".offers"));
    });
  }

  /** Source/config publication has one atomic manifest cut. Pending transport
   * receipts already fence interrupted apply; Apps never owns a second receipt. */
  async installOffer(input: { offerId: unknown; reference: SwiftAppDisplayReference; sourceSha256: string; expectedRevision: unknown; expectedSourceSha256: unknown; expectedInstanceId: unknown; upgradeToV2: unknown }, actor: SwiftAppActor): Promise<{ app: SwiftAppManifest; created: boolean }> {
    const offerId = admitDigest(input.offerId);
    if (typeof input.upgradeToV2 !== "boolean") throw new GatewayError("invalid_request", "upgradeToV2 must explicitly be true or false");
    return this.mutex.run(async () => {
      const root = (await this.appsRoot(true))!;
      const offers = join(root, ".offers");
      if (!(await ownerDirectory(offers))) throw new GatewayError("not_found", "This app offer is no longer available");
      const { offer, source } = await this.readOffer(input.reference);
      if (offer.id !== offerId || offer.sourceSha256 !== input.sourceSha256) {
        throw new GatewayError("conflict", "The app offer changed after review; review its exact source and access again");
      }
      const directory = join(root, offer.appId);
      const existing = await ownerDirectory(directory) ? await this.readManifest(directory, offer.appId) : null;
      if ((existing?.revision ?? null) !== input.expectedRevision || (existing?.sourceSha256 ?? null) !== input.expectedSourceSha256
        || (existing?.version === 2 ? existing.instanceId : null) !== input.expectedInstanceId) {
        throw new GatewayError("conflict", "The installed app changed after review; reopen the review before updating");
      }
      if (existing?.version === 1 && !input.upgradeToV2) throw new GatewayError("conflict", "Updating this v1 app requires explicit opt-in to a backed-up manifest v2 upgrade");
      if (!existing && (await readdir(root)).filter(name => APP_ID.test(name)).length >= 200) throw new GatewayError("conflict", "At most 200 apps can be installed");
      const staging = existing ? directory : join(root, `.install-${randomUUID()}`);
      let published = false;
      try {
        if (!existing) await ensureOwnerDirectory(staging);
        this.withDatabase(staging, () => undefined, !existing);
        if (existing?.version === 1) await this.backupV1(directory, existing);
        const sources = join(staging, "sources");
        await ensureOwnerDirectory(sources);
        if (existing?.version === 1) await durableAtomicWriteText(join(sources, `${existing.sourceSha256}.swift`), await this.readSource(directory, existing));
        await durableAtomicWriteText(join(sources, `${offer.sourceSha256}.swift`), source);
        const fields = { id: offer.appId, name: offer.name, ...(offer.icon ? { icon: offer.icon } : {}), revision: (existing?.revision ?? 0) + 1,
          sourceSha256: offer.sourceSha256, sourceBytes: offer.sourceBytes, updatedAt: new Date().toISOString() };
        const previous: SwiftAppRevision[] = existing?.version === 2 ? existing.history : existing ? [{ ...existing, feeds: [], actor: { kind: "unknown" as const } }].map(({ version: _version, ...revision }) => revision) : [];
        const history = [...previous, { ...fields, feeds: offer.feeds, actor }].slice(-20);
        const app: SwiftAppManifest = { version: 2, ...fields, instanceId: existing?.version === 2 ? existing.instanceId : randomUUID(), feeds: offer.feeds, history };
        // Validate the exact same contract readers use before publishing it.
        readSwiftAppManifest(app, offer.appId);
        await durableAtomicWriteJson(join(staging, "app.json"), app);
        if (!existing) { await rename(staging, directory); published = true; await syncDirectory(root); }
        else published = true;
        // Only unreachable immutable sources are retired, after the new head is durable.
        // Publication is committed. Cleanup belongs to the next bounded root
        // read, never to this already-published command's success receipt.
        this.initialized = false;
        return { app, created: !existing };
      } finally {
        if (!existing && !published) await rm(staging, { recursive: true, force: true });
      }
    });
  }

  /** The only v1 upgrade step. Snapshot before publication, no SQLite migration. */
  private async backupV1(directory: string, app: SwiftAppManifest): Promise<void> {
    const backups = join(directory, "backups");
    await ensureOwnerDirectory(backups);
    if ((await readdir(backups)).filter(name => /^v1-[1-9][0-9]*(?:-[a-f0-9-]{36})?$/.test(name)).length >= 20) {
      throw new GatewayError("conflict", "At most 20 explicit v1 upgrade backups can be retained; existing backups were not changed");
    }
    const original = join(backups, `v1-${app.revision}`);
    // A failed upgrade can leave a valid but now stale backup at this source
    // revision. Preserve it, and snapshot this attempt's current SQLite bytes.
    const destination = await ownerDirectory(original) ? `${original}-${randomUUID()}` : original;
    const temporary = join(backups, `.backup-${randomUUID()}`);
    await ensureOwnerDirectory(temporary);
    try {
      await durableAtomicWriteJson(join(temporary, "app.json"), app);
      await durableAtomicWriteText(join(temporary, "App.swift"), await this.readSource(directory, app));
      const input = await open(join(directory, "data.sqlite"), constants.O_RDONLY | constants.O_NOFOLLOW);
      try {
        const info = await input.stat();
        if (!info.isFile() || info.size > 4 * 1_024 * 1_024) throw new GatewayError("conflict", "App state cannot be safely backed up");
        const output = await open(join(temporary, "data.sqlite"), "wx", 0o600);
        try { await output.writeFile(await input.readFile()); await syncDurably(output); } finally { await output.close(); }
      } finally { await input.close(); }
      await syncDirectory(temporary);
      await rename(temporary, destination);
      await syncDirectory(backups);
    } finally { await rm(temporary, { recursive: true, force: true }); }
  }

  /** Named v1 tool contract. New installs through review use installOffer. */
  async install(input: { appId: string; name: string; icon?: string; source: string }): Promise<{ app: SwiftAppManifest; created: boolean }> {
    const appId = admitSwiftAppId(input.appId);
    const name = boundedLabel(input.name, "name", SWIFT_APP_LIMITS.nameBytes);
    const icon = input.icon === undefined ? undefined : boundedLabel(input.icon, "icon", SWIFT_APP_LIMITS.iconBytes);
    const sourceBytes = Buffer.byteLength(input.source);
    if (sourceBytes < 1 || sourceBytes > SWIFT_APP_LIMITS.sourceBytes) {
      throw new GatewayError("invalid_request", `App source must be 1-${SWIFT_APP_LIMITS.sourceBytes} bytes`);
    }
    return this.mutex.run(async () => {
      const apps = (await this.appsRoot(true))!;
      const directory = join(apps, appId);
      const existing = await ownerDirectory(directory) ? await this.readManifest(directory, appId) : undefined;
      if (existing?.version === 2) throw new GatewayError("conflict", "Update this v2 app through an explicit Install App review; it cannot be downgraded to v1");
      if (!existing) {
        const count = (await readdir(apps)).filter(entry => APP_ID.test(entry)).length;
        if (count >= SWIFT_APP_LIMITS.apps) throw new GatewayError("conflict", `At most ${SWIFT_APP_LIMITS.apps} apps can be installed`);
        if (await ensureOwnerDirectory(directory)) await syncDirectory(apps);
      }
      // A new app's state database exists before its manifest, so a listed app always has state.
      this.withDatabase(directory, () => undefined, !existing);
      await durableAtomicWriteText(join(directory, "App.swift"), input.source);
      const app: SwiftAppManifest = {
        version: 1, id: appId, name, ...(icon ? { icon } : {}),
        revision: (existing?.revision ?? 0) + 1,
        sourceSha256: createHash("sha256").update(input.source).digest("hex"),
        sourceBytes, updatedAt: new Date().toISOString(),
      };
      await durableAtomicWriteJson(join(directory, "app.json"), app);
      return { app, created: !existing };
    });
  }

  /** Delete the app folder (manifest, source and data). The folder is first
   * renamed aside so a crash can never leave a half-removed app listed. */
  async remove(appId: string, expectedInstanceId?: unknown): Promise<{ appId: string; removed: true }> {
    admitSwiftAppId(appId);
    return this.mutex.run(async () => {
      const directory = await this.appDirectory(appId);
      this.requireInstance(await this.readManifest(directory, appId), expectedInstanceId);
      const apps = join(directory, "..");
      const retired = join(apps, `.removed-${appId}-${randomBytes(6).toString("hex")}`);
      await rename(directory, retired);
      await syncDirectory(apps);
      await rm(retired, { recursive: true, force: true });
      return { appId, removed: true };
    });
  }

  /** Rename only. The source revision is the program identity that open runners
   * fence their writes on, so a label change must not invalidate them. */
  async rename(appId: string, rawName: unknown): Promise<{ app: SwiftAppManifest }> {
    admitSwiftAppId(appId);
    const name = boundedLabel(rawName, "name", SWIFT_APP_LIMITS.nameBytes);
    return this.mutex.run(async () => {
      const directory = await this.appDirectory(appId);
      const existing = await this.readManifest(directory, appId);
      const app: SwiftAppManifest = { ...existing, name, updatedAt: new Date().toISOString() };
      await durableAtomicWriteJson(join(directory, "app.json"), app);
      return { app };
    });
  }

  /** Clear every stored key in one transaction and advance the state revision,
   * so a runner holding the previous state cannot write it back. */
  async resetState(appId: string, expectedRevision: number): Promise<{ appId: string; revision: number }> {
    admitSwiftAppId(appId);
    if (!Number.isSafeInteger(expectedRevision) || expectedRevision < 0) throw new GatewayError("invalid_request", "expectedRevision must be a non-negative integer");
    return this.mutex.run(async () => {
      const directory = await this.appDirectory(appId);
      return this.withDatabase(directory, database => {
        database.exec("BEGIN IMMEDIATE");
        try {
          const revision = this.revision(database);
          if (revision !== expectedRevision) {
            throw new GatewayError("conflict", `App ${appId}'s state is at revision ${revision}, not ${expectedRevision}; reload it`, false, { revision });
          }
          database.exec("DELETE FROM state");
          database.prepare("UPDATE meta SET value = ? WHERE name = 'revision'").run(revision + 1);
          database.exec("COMMIT");
          return { appId, revision: revision + 1 };
        } catch (error) {
          database.exec("ROLLBACK");
          throw error;
        }
      });
    });
  }

  async state(appId: string): Promise<SwiftAppStateSnapshot> {
    admitSwiftAppId(appId);
    return this.mutex.run(async () => {
      const directory = await this.appDirectory(appId);
      return this.withDatabase(directory, database => this.snapshot(database, appId));
    });
  }

  /** Optimistic: a commit names the state revision it was computed from, and
   * a stale one is refused so the caller reloads instead of overwriting. */
  async commit(input: SwiftAppCommit): Promise<{ appId: string; revision: number }> {
    const appId = admitSwiftAppId(input.appId);
    if (!Number.isSafeInteger(input.expectedRevision) || input.expectedRevision < 0) throw new GatewayError("invalid_request", "expectedRevision must be a non-negative integer");
    if (input.expectedSourceRevision !== undefined && (!Number.isSafeInteger(input.expectedSourceRevision) || input.expectedSourceRevision < 1)) {
      throw new GatewayError("invalid_request", "expectedSourceRevision must be a positive integer");
    }
    if (!Array.isArray(input.set) || !Array.isArray(input.remove) || input.set.length + input.remove.length === 0
      || input.set.length + input.remove.length > SWIFT_APP_LIMITS.writesPerCommit) {
      throw new GatewayError("invalid_request", `A commit carries 1-${SWIFT_APP_LIMITS.writesPerCommit} writes`);
    }
    const touched = new Set<string>();
    const sets = input.set.map(write => {
      if (!write || typeof write !== "object" || Array.isArray(write) || Object.keys(write).some(key => key !== "key" && key !== "value") || !("value" in write)) {
        throw new GatewayError("invalid_request", "Each set write is {key, value}");
      }
      const key = admitKey(write.key);
      admitValue(write.value);
      const encoded = JSON.stringify(write.value);
      if (Buffer.byteLength(encoded) > SWIFT_APP_LIMITS.valueBytes) throw new GatewayError("invalid_request", `A state value may be at most ${SWIFT_APP_LIMITS.valueBytes} bytes`);
      if (touched.has(key)) throw new GatewayError("invalid_request", `State key ${JSON.stringify(key)} is written twice`);
      touched.add(key);
      return { key, encoded };
    });
    const removes = input.remove.map(raw => {
      const key = admitKey(raw);
      if (touched.has(key)) throw new GatewayError("invalid_request", `State key ${JSON.stringify(key)} is written twice`);
      touched.add(key);
      return key;
    });
    return this.mutex.run(async () => {
      const directory = await this.appDirectory(appId);
      if (input.expectedSourceRevision !== undefined) {
        const app = await this.readManifest(directory, appId);
        this.requireInstance(app, input.expectedInstanceId);
        if (app.revision !== input.expectedSourceRevision) {
          throw new GatewayError("conflict", `App ${appId}'s source is at revision ${app.revision}, not ${input.expectedSourceRevision}; reopen it`);
        }
      }
      return this.withDatabase(directory, database => {
        database.exec("BEGIN IMMEDIATE");
        try {
          const revision = this.revision(database);
          if (revision !== input.expectedRevision) {
            throw new GatewayError("conflict", `App ${appId}'s state is at revision ${revision}, not ${input.expectedRevision}; reload it`, false, { revision });
          }
          const upsert = database.prepare("INSERT INTO state(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value");
          for (const write of sets) upsert.run(write.key, write.encoded);
          const remove = database.prepare("DELETE FROM state WHERE key = ?");
          for (const key of removes) remove.run(key);
          const totals = database.prepare("SELECT COUNT(*) AS entries, COALESCE(SUM(LENGTH(CAST(key AS BLOB)) + LENGTH(CAST(value AS BLOB))), 0) AS bytes FROM state").get() as { entries: number; bytes: number };
          if (totals.entries > SWIFT_APP_LIMITS.entries || totals.bytes > SWIFT_APP_LIMITS.stateBytes) {
            throw new GatewayError("conflict", `App state is limited to ${SWIFT_APP_LIMITS.entries} keys and ${SWIFT_APP_LIMITS.stateBytes} bytes`);
          }
          database.prepare("UPDATE meta SET value = ? WHERE name = 'revision'").run(revision + 1);
          database.exec("COMMIT");
          return { appId, revision: revision + 1 };
        } catch (error) {
          database.exec("ROLLBACK");
          throw error;
        }
      });
    });
  }

  private revision(database: DatabaseSync): number {
    const row = database.prepare("SELECT value FROM meta WHERE name = 'revision'").get() as { value: number } | undefined;
    if (!row || !Number.isSafeInteger(row.value) || row.value < 0) throw new GatewayError("conflict", "App state has no valid revision; it was left unchanged");
    return row.value;
  }

  private snapshot(database: DatabaseSync, appId: string): SwiftAppStateSnapshot {
    const rows = database.prepare("SELECT key, value FROM state ORDER BY key").all() as Array<{ key: string; value: string }>;
    return { appId, revision: this.revision(database), entries: rows.map(row => ({ key: row.key, value: JSON.parse(row.value) as JsonValue })) };
  }

  /** One short-lived connection per operation under the store mutex. Only a
   * first install may create state; an existing manifest is not a fresh start. */
  private withDatabase<T>(directory: string, operation: (database: DatabaseSync) => T, create = false): T {
    const path = join(directory, "data.sqlite");
    let database: DatabaseSync;
    try {
      if (!create) {
        const entry = lstatSync(path);
        if (!entry.isFile() || entry.uid !== process.getuid?.()) throw new Error("Unsafe app database");
      }
      // SQLite's no-create mode also protects deletion between inspection and
      // open. Escape the path as a URI so workspace names cannot change its mode.
      database = new DatabaseSync(`${pathToFileURL(path).href}?mode=${create ? "rwc" : "rw"}`, { allowExtension: false });
    } catch {
      throw new GatewayError("conflict", "App state is missing or unsafe; restore its data.sqlite");
    }
    try {
      database.exec("PRAGMA trusted_schema = OFF; PRAGMA busy_timeout = 1000;");
      const version = (database.prepare("PRAGMA user_version").get() as { user_version: number }).user_version;
      if (version !== SCHEMA_VERSION && !(create && version === 0)) {
        throw new GatewayError("conflict", "App state has an unsupported schema; it was left unchanged");
      }
      database.exec("PRAGMA journal_mode = DELETE; PRAGMA synchronous = EXTRA; PRAGMA secure_delete = ON;");
      if (create && version === 0) {
        database.exec(`BEGIN IMMEDIATE;
          CREATE TABLE meta(name TEXT PRIMARY KEY, value INTEGER NOT NULL) STRICT;
          CREATE TABLE state(key TEXT PRIMARY KEY, value TEXT NOT NULL) STRICT;
          INSERT INTO meta(name, value) VALUES ('revision', 0);
          PRAGMA user_version = ${SCHEMA_VERSION};
          COMMIT;`);
      }
      return operation(database);
    } finally {
      database.close();
    }
  }
}
