import { HOME_MAX_CHAPTERS } from "../home/home-chapter-state.js";
import { constants } from "node:fs";
import { lstat, mkdir, open, readdir, rename, rm, writeFile, type FileHandle } from "node:fs/promises";
import { dirname, join } from "node:path";
import { readSecureJson } from "../util/secure-json.js";
import { durableAtomicWriteJson, syncDurably, type DurableJsonFileSystem } from "../util/durable-json.js";
import type { TronWorkspace } from "../workspace/tron-workspace.js";
import {
  EpisodicMemoryError, EPISODIC_STORE_VERSION, EPISODIC_HOME_CURSOR_MAX_BYTES, EPISODIC_STATE_MAX_BYTES,
  type EpisodicContextRun, type EpisodicMessageRecord, type EpisodicNodeLogRecord, type EpisodicNodeRecord, type EpisodicStoreState,
} from "./episodic-contract.js";
import { decodeNodeCode, nodeAddress } from "./episodic-tree.js";

/*
 * Departure 4 of the brief: the memory persists under the Tron internal
 * workspace's capability state, `state/episodic/<sourceSessionId>/`, owned and
 * secured the way KnowledgeStore owns `state/knowledge/` (owner-only 0700
 * directory, created lazily, owner-only files, secure bounded reads, no-follow
 * opens with a dev/ino identity check).
 *
 * The catalog and the node log are append-only JSONL, and every record is
 * fsynced before it is used. A trailing partial line is a torn, unacknowledged
 * write (the record never became durable), so it is truncated away on load and
 * reported; any other unparsable record refuses the store visibly.
 *
 * The workspace marker is evidence that the shared `state/episodic` container
 * was initialized. A container that is now missing is lost state, not a new
 * installation: it refuses rather than restarting and re-spending every
 * compactor call. One session's namespace is created lazily inside the container,
 * and the marker carries no per-session evidence, so a session without one
 * starts fresh (#483), including one whose namespace was deleted (D5: repair).
 */

const SESSION_ID = /^[A-Za-z0-9._-]{1,160}$/u;
const BLOCKED_REASONS = new Set(["permanent-failure", "retries-exhausted", "source-unavailable"]);

export interface EpisodicStoreFileSystem extends DurableJsonFileSystem {
  lstat: typeof lstat;
  readdir: typeof readdir;
  writeFile: typeof writeFile;
  syncDurably(handle: { sync(): Promise<void> }): Promise<void>;
}

const productionFileSystem: EpisodicStoreFileSystem = { lstat, mkdir, open, readdir, rename, rm, writeFile, syncDurably };

interface StorePaths {
  root: string;
  initialized: string;
  catalog: string;
  nodes: string;
  state: string;
  checkpointPointer: string;
}

export interface EpisodicStoreSnapshot {
  present: boolean;
  messages: Map<number, EpisodicMessageRecord>;
  nodes: Map<string, EpisodicNodeRecord>;
  state: EpisodicStoreState | null;
  /** Bytes of torn trailing records discarded on load. */
  recoveredTornBytes: number;
  /** The highest generation any record in the node log names. */
  highestGeneration: number;
  /** The highest revision any record carries. */
  highestRevision: number;
}

export class EpisodicStore {
  constructor(
    private readonly workspace: TronWorkspace,
    private readonly sessionId: string,
    private readonly maxLineBytes: number,
    private readonly fileSystem: EpisodicStoreFileSystem = productionFileSystem,
  ) {
    if (!SESSION_ID.test(sessionId)) throw new EpisodicMemoryError("invalid-request", "Source session id cannot name a store directory");
  }

  private async paths(): Promise<StorePaths> {
    const root = join(await this.workspaceStateRoot(), "episodic", this.sessionId);
    return { root, initialized: join(root, "initialized.json"), catalog: join(root, "catalog.jsonl"), nodes: join(root, "nodes.jsonl"), state: join(root, "state.json"), checkpointPointer: join(root, "checkpoint.current.json") };
  }

  /** The workspace's `state/` root. The store never creates it here: creation
   * is lazy and happens on the first append. */
  private async workspaceStateRoot(): Promise<string> {
    const descriptor = await this.workspace.describe();
    if (!descriptor.available) throw new EpisodicMemoryError("unsafe-store", "Tron internal workspace is unavailable; episodic memory cannot be persisted");
    return join(descriptor.root, "state");
  }

  async readState(): Promise<EpisodicStoreState | undefined> {
    const paths = await this.paths();
    const initialized = await this.featureInitialized();
    if (!(await directoryExists(paths.root))) {
      if (initialized && !(await directoryExists(dirname(paths.root)))) {
        throw new EpisodicMemoryError("invalid-store", "Episodic memory container is missing after it was initialized");
      }
      return undefined;
    }
    await assertOwnerDirectory(paths.root);
    const marker = await readSecureJson<unknown>(paths.initialized, 256);
    if (!marker.present) throw new EpisodicMemoryError("invalid-store", "Episodic memory directory exists without initialization evidence");
    if (!marker.value || typeof marker.value !== "object" || Array.isArray(marker.value)
      || !hasOnlyKeys(marker.value as Record<string, unknown>, ["version"])
      || (marker.value as { version?: unknown }).version !== EPISODIC_STORE_VERSION) {
      throw new EpisodicMemoryError("invalid-store", "Episodic memory initialization record has an unknown version");
    }
    const stateRead = await readSecureJson<unknown>(paths.state, EPISODIC_STATE_MAX_BYTES);
    return stateRead.present ? validateState(stateRead.value) : undefined;
  }

  async read(): Promise<EpisodicStoreSnapshot> {
    const paths = await this.paths();
    const initialized = await this.featureInitialized();
    if (!(await directoryExists(paths.root))) {
      // The feature record describes the shared container, never one session:
      // reading it per session refused every Home after the first (#483).
      // Marker first: `ensureRoot` creates the container before it sets the
      // marker, so a set marker proves the container existed, and a container
      // created concurrently after a missing-container read cannot look lost.
      if (initialized && !(await directoryExists(dirname(paths.root)))) {
        throw new EpisodicMemoryError("invalid-store", "Episodic memory container is missing after it was initialized");
      }
      return { present: false, messages: new Map(), nodes: new Map(), state: null, recoveredTornBytes: 0, highestGeneration: 0, highestRevision: 0 };
    }
    await assertOwnerDirectory(paths.root);
    const marker = await readSecureJson<unknown>(paths.initialized, 256);
    if (!marker.present) throw new EpisodicMemoryError("invalid-store", "Episodic memory directory exists without initialization evidence");
    if (!marker.value || typeof marker.value !== "object" || Array.isArray(marker.value)
      || !hasOnlyKeys(marker.value as Record<string, unknown>, ["version"])
      || (marker.value as { version?: unknown }).version !== EPISODIC_STORE_VERSION) {
      throw new EpisodicMemoryError("invalid-store", "Episodic memory initialization record has an unknown version");
    }

    const stateRead = await readSecureJson<unknown>(paths.state, EPISODIC_STATE_MAX_BYTES);
    let state: EpisodicStoreState | null = null;
    if (stateRead.present) state = validateState(stateRead.value);
    const checkpoint = await readCheckpoint(paths, this.maxLineBytes);
    const messages = checkpoint.messages;
    const nodes = checkpoint.nodes;
    let highestGeneration = 0;
    let highestRevision = checkpoint.watermark;
    const catalogRead = await readJsonl<EpisodicMessageRecord>(paths.catalog, this.maxLineBytes, isCatalogRecord, record => {
      if (record.revision <= checkpoint.watermark) return;
      messages.set(record.index, record);
      highestRevision = Math.max(highestRevision, record.revision);
    });
    const nodesRead = await readJsonl<EpisodicNodeLogRecord>(paths.nodes, this.maxLineBytes, isNodeLogRecord, record => {
      if (record.revision <= checkpoint.watermark) return;
      if ("nodes" in record) {
        highestGeneration = Math.max(highestGeneration, record.generation);
        for (const code of record.nodes.split(" ")) if (code !== "") {
          const address = decodeNodeCode(code);
          if (address === undefined) throw new EpisodicMemoryError("invalid-store", "Episodic invalidation record names an address that cannot be decoded");
          nodes.delete(address);
        }
      } else nodes.set(nodeAddress(record.level, record.index), record);
      highestRevision = Math.max(highestRevision, record.revision);
    });
    return { present: true, messages, nodes, state, recoveredTornBytes: catalogRead.tornBytes + nodesRead.tornBytes, highestGeneration, highestRevision };
  }


  /** Remove abandoned checkpoint artifacts only while the single memory opener owns this session. */
  async cleanupOrphans(): Promise<void> {
    const paths = await this.paths();
    if (!(await directoryExists(paths.root))) return;
    await assertOwnerDirectory(paths.root);
    const pointer = await readSecureJson<unknown>(paths.checkpointPointer, 4_096);
    let active: string | null = null;
    if (pointer.present) {
      const value = pointer.value as { version?: unknown; directory?: unknown; watermark?: unknown };
      if (!value || value.version !== 1 || typeof value.directory !== "string" || !/^checkpoint-[A-Za-z0-9.-]+$/u.test(value.directory)
        || typeof value.watermark !== "number" || !Number.isSafeInteger(value.watermark) || value.watermark < 0) {
        throw new EpisodicMemoryError("invalid-store", "Episodic checkpoint pointer is malformed");
      }
      active = value.directory;
    }
    await cleanupCheckpoints(paths, active, this.fileSystem);
  }

  async appendCatalog(record: EpisodicMessageRecord): Promise<void> {
    await this.append((await this.paths()).catalog, record);
  }

  async appendNode(record: EpisodicNodeLogRecord): Promise<void> {
    await this.append((await this.paths()).nodes, record);
  }

  async shouldCheckpoint(liveBytes: number): Promise<boolean> {
    const paths = await this.paths();
    const logBytes = (await fileSize(paths.catalog)) + (await fileSize(paths.nodes));
    if (logBytes <= 16_384) return false;
    if (logBytes >= 32_768) return true;
    return logBytes > liveBytes + 16_384;
  }

  async saveState(state: EpisodicStoreState): Promise<void> {
    validateStatePublication(state);
    await this.ensureRoot();
    await durableAtomicWriteJson((await this.paths()).state, state, 0o600, this.fileSystem);
  }

  /** Publish a bounded-line checkpoint before reclaiming append history. */
  async checkpoint(options: { messages: Iterable<EpisodicMessageRecord>; nodes: Iterable<EpisodicNodeRecord>; state: EpisodicStoreState; watermark: number }): Promise<void> {
    validateStatePublication(options.state);
    const paths = await this.ensureRoot();
    await durableAtomicWriteJson(paths.state, options.state, 0o600, this.fileSystem);
    const name = `checkpoint-${process.pid}-${Date.now()}-${Math.random().toString(36).slice(2)}`;
    const staging = join(paths.root, ".checkpoint-staging");
    const stagingInfo = await this.fileSystem.lstat(staging).catch((error: NodeJS.ErrnoException) => error.code === "ENOENT" ? undefined : Promise.reject(error));
    if (stagingInfo) {
      if (!stagingInfo.isDirectory() || stagingInfo.uid !== process.getuid?.() || (stagingInfo.mode & 0o077) !== 0) {
        throw new EpisodicMemoryError("unsafe-store", "Episodic checkpoint staging entry is unsafe");
      }
      await removeOwnedTree(staging, this.fileSystem);
    }
    await this.fileSystem.mkdir(staging, { mode: 0o700 });
    let pointerPublished = false;
    try {
      await writeCheckpointLines(join(staging, "catalog.jsonl"), options.messages, this.maxLineBytes, this.fileSystem);
      await writeCheckpointLines(join(staging, "nodes.jsonl"), options.nodes, this.maxLineBytes, this.fileSystem);
      await this.fileSystem.writeFile(join(staging, "state.json"), `${JSON.stringify(options.state)}\n`, { mode: 0o600 });
      const stateFile = await this.fileSystem.open(join(staging, "state.json"), constants.O_RDONLY);
      try { await this.fileSystem.syncDurably(stateFile); } finally { await stateFile.close(); }
      await syncDirectory(staging, this.fileSystem);
      const checkpoint = join(paths.root, name);
      await this.fileSystem.rename(staging, checkpoint);
      await syncDirectory(paths.root, this.fileSystem);
      await durableAtomicWriteJson(paths.checkpointPointer, { version: 1, directory: name, watermark: options.watermark }, 0o600, this.fileSystem);
      pointerPublished = true;
      await truncateLog(paths.catalog, paths.root, this.fileSystem);
      await truncateLog(paths.nodes, paths.root, this.fileSystem);
      await cleanupCheckpoints(paths, name, this.fileSystem);
    } catch (error) {
      const failure = new EpisodicMemoryError("invalid-store", `Episodic checkpoint could not be committed: ${(error as NodeJS.ErrnoException).code ?? "unknown"}`) as EpisodicMemoryError & { publicationUncertain: boolean };
      failure.publicationUncertain = pointerPublished || (typeof error === "object" && error !== null && (error as { publicationVisible?: unknown }).publicationVisible === true);
      throw failure;
    }
  }

  private async append(path: string, record: unknown): Promise<void> {
    const paths = await this.ensureRoot();
    const line = `${JSON.stringify(record)}\n`;
    if (Buffer.byteLength(line, "utf8") > this.maxLineBytes) throw new EpisodicMemoryError("invalid-store", "Episodic record exceeds the store's line bound");
    const opened = await openOwnerFile(path, constants.O_WRONLY | constants.O_APPEND | constants.O_CREAT, 0o600);
    if (!opened) throw new EpisodicMemoryError("invalid-store", "Episodic store file could not be created");
    const { handle, created } = opened;
    try {
      await handle.writeFile(line, "utf8");
      // Durable before use: the recipe fsyncs every node, and a record a caller
      // has observed must survive a crash.
      await syncDurably(handle);
    } finally {
      await handle.close();
    }
    // A new file's directory entry needs its own sync, or a crash can lose the
    // file that already holds acknowledged records.
    if (created) await syncDirectory(paths.root);
  }

  private async featureInitialized(): Promise<boolean> {
    try { return await this.workspace.featureInitialized("episodic"); }
    catch { throw new EpisodicMemoryError("invalid-store", "Episodic memory initialization record is invalid"); }
  }

  private async ensureRoot(): Promise<StorePaths> {
    await this.featureInitialized();
    const paths = await this.paths();
    const stateRoot = await this.workspaceStateRoot();
    await assertOwnerDirectory(stateRoot, true);
    await assertOwnerDirectory(join(stateRoot, "episodic"), true);
    await assertOwnerDirectory(paths.root, true);
    if (!(await fileExists(paths.initialized))) {
      // The marker turns a later missing container into lost state, so each
      // directory entry on its path must be durable first. This call may have
      // just created `state/` and `episodic/`, so their parents are synced too.
      for (const directory of [dirname(stateRoot), stateRoot, join(stateRoot, "episodic")]) {
        await syncDirectory(directory, this.fileSystem);
      }
      await durableAtomicWriteJson(paths.initialized, { version: EPISODIC_STORE_VERSION }, 0o600);
      // The feature record tells a later start that a missing shared container
      // is lost state rather than a fresh installation.
      try { await this.workspace.markFeatureInitialized("episodic"); }
      catch { throw new EpisodicMemoryError("invalid-store", "Episodic memory initialization record could not be recorded"); }
    }
    return paths;
  }
}

async function readCheckpoint(paths: StorePaths, maxLineBytes: number): Promise<{ messages: Map<number, EpisodicMessageRecord>; nodes: Map<string, EpisodicNodeRecord>; watermark: number; directory: string | null }> {
  const pointer = await readSecureJson<unknown>(paths.checkpointPointer, 4_096);
  if (!pointer.present) return { messages: new Map(), nodes: new Map(), watermark: 0, directory: null };
  const value = pointer.value as { version?: unknown; directory?: unknown; watermark?: unknown };
  if (!value || value.version !== 1 || typeof value.directory !== "string" || !/^checkpoint-[A-Za-z0-9.-]+$/u.test(value.directory)
    || typeof value.watermark !== "number" || !Number.isSafeInteger(value.watermark) || value.watermark < 0) {
    throw new EpisodicMemoryError("invalid-store", "Episodic checkpoint pointer is malformed");
  }
  const watermark = value.watermark as number;
  const directory = join(paths.root, value.directory);
  await assertOwnerDirectory(directory);
  const checkpointState = await readSecureJson<unknown>(join(directory, "state.json"), EPISODIC_STATE_MAX_BYTES);
  if (!checkpointState.present) throw new EpisodicMemoryError("invalid-store", "Episodic checkpoint state is missing");
  validateState(checkpointState.value);
  // state.json is the authority and can advance independently of catalog/node
  // revisions (for example, a spend or blocked-state update after publication).
  const messages = new Map<number, EpisodicMessageRecord>();
  const entryIds = new Set<string>();
  const nodes = new Map<string, EpisodicNodeRecord>();
  await readJsonl<EpisodicMessageRecord>(join(directory, "catalog.jsonl"), maxLineBytes, isCatalogRecord, record => {
    if (record.revision > watermark || messages.has(record.index) || entryIds.has(record.entryId)) {
      throw new EpisodicMemoryError("invalid-store", "Episodic checkpoint catalog is inconsistent with its watermark");
    }
    messages.set(record.index, record);
    entryIds.add(record.entryId);
  }, true);
  await readJsonl<EpisodicNodeLogRecord>(join(directory, "nodes.jsonl"), maxLineBytes, isNodeLogRecord, record => {
    if ("nodes" in record) throw new EpisodicMemoryError("invalid-store", "Episodic checkpoint contains an invalidation record");
    const address = nodeAddress(record.level, record.index);
    if (record.revision > watermark || nodes.has(address)) throw new EpisodicMemoryError("invalid-store", "Episodic checkpoint nodes are inconsistent with their watermark");
    nodes.set(address, record);
  }, true);
  return { messages, nodes, watermark, directory: value.directory };
}

async function writeCheckpointLines<T>(path: string, records: Iterable<T>, maxLineBytes: number, fileSystem: EpisodicStoreFileSystem): Promise<void> {
  const handle = await fileSystem.open(path, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
  try {
    for (const record of records) {
      const line = `${JSON.stringify(record)}\n`;
      if (Buffer.byteLength(line, "utf8") > maxLineBytes) throw new EpisodicMemoryError("invalid-store", "Episodic checkpoint record exceeds the store's line bound");
      await handle.writeFile(line, "utf8");
    }
    await fileSystem.syncDurably(handle);
  } finally { await handle.close(); }
}

async function truncateLog(path: string, root: string, fileSystem: EpisodicStoreFileSystem): Promise<void> {
  const temp = join(root, `.checkpoint-log-${Math.random().toString(36).slice(2)}`);
  const handle = await fileSystem.open(temp, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
  try { await fileSystem.syncDurably(handle); } finally { await handle.close(); }
  await fileSystem.rename(temp, path);
  await syncDirectory(root, fileSystem);
}

async function cleanupCheckpoints(paths: StorePaths, active: string | null, fileSystem: EpisodicStoreFileSystem): Promise<void> {
  const names = await fileSystem.readdir(paths.root);
  for (const name of names) {
    if (name === active || name === "checkpoint.current.json" || name === "catalog.jsonl" || name === "nodes.jsonl" || name === "state.json" || name === "initialized.json") continue;
    const directory = name === ".checkpoint-staging" || /^checkpoint-[A-Za-z0-9.-]+$/u.test(name);
    const temporaryFile = /^\.checkpoint-log-[a-z0-9]+$/u.test(name)
      || /^checkpoint\.current\.json\.[0-9]+\.[a-f0-9]{12}\.tmp$/u.test(name);
    if (!directory && !temporaryFile) continue;
    const path = join(paths.root, name);
    const info = await fileSystem.lstat(path);
    if (info.uid !== process.getuid?.() || (directory ? !info.isDirectory() || (info.mode & 0o777) !== 0o700 : !info.isFile() || (info.mode & 0o777) !== 0o600)) {
      throw new EpisodicMemoryError("unsafe-store", "Episodic checkpoint cleanup encountered an unsafe entry");
    }
    await removeOwnedTree(path, fileSystem);
  }
}

async function removeOwnedTree(path: string, fileSystem: EpisodicStoreFileSystem): Promise<void> {
  const info = await fileSystem.lstat(path);
  if (info.uid !== process.getuid?.() || (!info.isFile() && !info.isDirectory())
    || (info.mode & 0o777) !== (info.isDirectory() ? 0o700 : 0o600)) {
    throw new EpisodicMemoryError("unsafe-store", "Episodic cleanup encountered an unsafe entry");
  }
  if (info.isDirectory()) {
    for (const name of await fileSystem.readdir(path)) await removeOwnedTree(join(path, name), fileSystem);
  }
  await fileSystem.rm(path, { recursive: info.isDirectory(), force: false });
}

function hasOnlyKeys(record: Record<string, unknown>, keys: readonly string[]): boolean {
  return Object.keys(record).every(key => keys.includes(key));
}

function validateStatePublication(state: EpisodicStoreState): void {
  // Check the exact encoding used by durableAtomicWriteJson before any effect.
  if (Buffer.byteLength(`${JSON.stringify(state, null, 2)}\n`) > EPISODIC_STATE_MAX_BYTES) {
    throw new EpisodicMemoryError("invalid-store", "Episodic state exceeds its byte limit");
  }
  validateState(state);
}

function validateState(value: unknown): EpisodicStoreState {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new EpisodicMemoryError("invalid-store", "Episodic memory state is not an object");
  const state = value as Partial<EpisodicStoreState>;
  if (!hasOnlyKeys(value as Record<string, unknown>, ["version", "generation", "cursor", "blocked", "spend"])
    || state.version !== EPISODIC_STORE_VERSION) throw new EpisodicMemoryError("invalid-store", "Episodic memory state has an unknown version or fields");
  if (typeof state.generation !== "number" || !Number.isSafeInteger(state.generation) || state.generation < 0) throw new EpisodicMemoryError("invalid-store", "Episodic memory state has no generation");
  if (!("cursor" in state) || !("blocked" in state) || !("spend" in state)) throw new EpisodicMemoryError("invalid-store", "Episodic memory state is missing required fields");
  const cursor = state.cursor;
  if (cursor !== null) {
    if (typeof cursor !== "object" || Array.isArray(cursor)
      || !hasOnlyKeys(cursor as unknown as Record<string, unknown>, ["dev", "ino", "size", "completeBytes", "leafEntryId", "completePrefixDigest", "leafLineDigest", "home"])) throw new EpisodicMemoryError("invalid-store", "Episodic memory state has an invalid cursor");
    for (const field of ["dev", "ino", "size", "completeBytes"] as const) {
      if (typeof cursor[field] !== "number" || !Number.isSafeInteger(cursor[field]) || cursor[field] < 0) {
        throw new EpisodicMemoryError("invalid-store", `Episodic memory state cursor has no ${field}`);
      }
    }
    if (cursor.leafEntryId !== null && typeof cursor.leafEntryId !== "string") throw new EpisodicMemoryError("invalid-store", "Episodic memory state cursor has an invalid leaf");
    if (cursor.leafLineDigest !== null && typeof cursor.leafLineDigest !== "string") throw new EpisodicMemoryError("invalid-store", "Episodic memory state cursor has an invalid line digest");
    if (cursor.completePrefixDigest !== undefined && cursor.completePrefixDigest !== null
      && (typeof cursor.completePrefixDigest !== "string" || !/^[a-f0-9]{64}$/u.test(cursor.completePrefixDigest))) {
      throw new EpisodicMemoryError("invalid-store", "Episodic memory state cursor has an invalid prefix digest");
    }
    if (cursor.home !== undefined) {
      const home = cursor.home as unknown as Record<string, unknown>;
      if (!home || typeof home !== "object" || Array.isArray(home)
        || !hasOnlyKeys(home, ["version", "ledgerRevision", "chapters"])
        || home.version !== 2
        || !Number.isSafeInteger(home.ledgerRevision) || (home.ledgerRevision as number) < 1
        || !Array.isArray(home.chapters) || home.chapters.length === 0 || home.chapters.length > HOME_MAX_CHAPTERS) {
        throw new EpisodicMemoryError("invalid-store", "Episodic memory state has an invalid Home source cursor");
      }
      for (const value of home.chapters) {
        if (!value || typeof value !== "object" || Array.isArray(value)) throw new EpisodicMemoryError("invalid-store", "Episodic memory state has an invalid Home chapter cursor");
        const chapter = value as Record<string, unknown>;
        // Include the actual nested indentation in the per-cursor bound.
        if (Buffer.byteLength(JSON.stringify({ cursor: { home: { chapters: [chapter] } } }, null, 2)) > EPISODIC_HOME_CURSOR_MAX_BYTES) {
          throw new EpisodicMemoryError("invalid-store", "Home chapter cursor exceeds its byte limit");
        }
        if (!hasOnlyKeys(chapter, ["sessionId", "dev", "ino", "size", "completeBytes", "leafEntryId", "leafLineDigest", "completePrefixDigest", "mtimeMs", "ctimeMs", "sealed"])
          || typeof chapter.sealed !== "boolean"
          || ["mtimeMs", "ctimeMs"].some(field => typeof chapter[field] !== "number" || !Number.isFinite(chapter[field]) || (chapter[field] as number) < 0)
          || typeof chapter.sessionId !== "string" || chapter.sessionId.length < 1 || chapter.sessionId.length > 200
          || ["dev", "ino", "size", "completeBytes"].some(field => !Number.isSafeInteger(chapter[field]) || (chapter[field] as number) < 0)
          || (chapter.leafEntryId !== null && typeof chapter.leafEntryId !== "string")
          || (chapter.leafLineDigest !== null && (typeof chapter.leafLineDigest !== "string" || !/^[a-f0-9]{64}$/u.test(chapter.leafLineDigest)))
          || typeof chapter.completePrefixDigest !== "string" || !/^[a-f0-9]{64}$/u.test(chapter.completePrefixDigest)) {
          throw new EpisodicMemoryError("invalid-store", "Episodic memory state has an invalid Home chapter cursor");
        }
      }
    }
  }
  const blocked = state.blocked;
  if (blocked !== null) {
    if (typeof blocked !== "object" || Array.isArray(blocked)
      || !hasOnlyKeys(blocked as unknown as Record<string, unknown>, ["reason", "detail"])
      || typeof blocked.reason !== "string" || !BLOCKED_REASONS.has(blocked.reason)
      || (blocked.detail !== undefined && typeof blocked.detail !== "string")) {
      throw new EpisodicMemoryError("invalid-store", "Episodic memory state has an invalid blocked state");
    }
  }
  const spend = state.spend;
  if (typeof spend !== "number" || !Number.isSafeInteger(spend) || spend < 0) {
    throw new EpisodicMemoryError("invalid-store", "Episodic memory state has an invalid token spend");
  }
  return {
    version: EPISODIC_STORE_VERSION,
    generation: state.generation,
    cursor: cursor ? { ...cursor } : null,
    blocked: blocked ? { ...blocked } : null,
    // A state written before spend was recorded reads as zero spend: the tokens
    // already spent are unknown, and inventing a number would be worse than
    // starting the ceiling again from a known point.
    spend,
  };
}

/** Open one store file without following a symlink, verify it is an owner-only
 * regular file, and prove the path was not replaced between the check and the
 * open. Returns whether this call created the file. */
async function openOwnerFile(path: string, flags: number, mode?: number): Promise<{ handle: FileHandle; created: boolean } | undefined> {
  const before = await lstat(path).catch((error: NodeJS.ErrnoException) => {
    if (error.code === "ENOENT") return undefined;
    throw new EpisodicMemoryError("unsafe-store", "Episodic store file could not be inspected");
  });
  let handle: FileHandle;
  try {
    handle = await open(path, flags | constants.O_NOFOLLOW, mode);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
    throw new EpisodicMemoryError("invalid-store", `Episodic store file cannot be opened: ${(error as NodeJS.ErrnoException).code ?? "unknown"}`);
  }
  try {
    const info = await handle.stat();
    if (!info.isFile() || info.uid !== process.getuid?.() || (info.mode & 0o077) !== 0) {
      throw new EpisodicMemoryError("unsafe-store", "Episodic store file is not a bounded owner-only regular file");
    }
    if (before && (before.dev !== info.dev || before.ino !== info.ino)) {
      throw new EpisodicMemoryError("unsafe-store", "Episodic store file changed its identity while opening");
    }
    return { handle, created: before === undefined };
  } catch (error) {
    await handle.close();
    throw error;
  }
}

async function fileSize(path: string): Promise<number> {
  const info = await lstat(path).catch((error: NodeJS.ErrnoException) => error.code === "ENOENT" ? undefined : Promise.reject(error));
  if (!info) return 0;
  if (!info.isFile() || info.uid !== process.getuid?.() || (info.mode & 0o077) !== 0) throw new EpisodicMemoryError("unsafe-store", "Episodic log file is unsafe");
  return info.size;
}

async function syncDirectory(path: string, fileSystem: EpisodicStoreFileSystem = productionFileSystem): Promise<void> {
  const handle = await fileSystem.open(path, constants.O_RDONLY);
  try {
    await fileSystem.syncDurably(handle);
  } finally {
    await handle.close();
  }
}

async function readJsonl<T>(path: string, maxLineBytes: number, isRecord: (value: Record<string, unknown>) => boolean, consume: (record: T) => void, strict = false): Promise<{ tornBytes: number }> {
  const opened = await openOwnerFile(path, constants.O_RDONLY);
  if (!opened) {
    if (strict) throw new EpisodicMemoryError("invalid-store", "Episodic checkpoint file is missing");
    return { tornBytes: 0 };
  }
  const { handle } = opened;
  let completeBytes = 0;
  let tornBytes = 0;
  try {
    const buffer = Buffer.alloc(1_024 * 1_024);
    let pending = Buffer.alloc(0);
    let offset = 0;
    for (;;) {
      const read = await handle.read(buffer, 0, buffer.length, offset);
      if (read.bytesRead === 0) break;
      offset += read.bytesRead;
      let chunk = Buffer.concat([pending, buffer.subarray(0, read.bytesRead)]);
      let newline = chunk.indexOf(0x0a);
      while (newline >= 0) {
        const line = chunk.subarray(0, newline).toString("utf8");
        if (line.trim() === "") {
          if (strict) throw new EpisodicMemoryError("invalid-store", "Episodic checkpoint contains an empty record");
        } else consume(parseRecord<T>(line, isRecord));
        completeBytes += newline + 1;
        chunk = chunk.subarray(newline + 1);
        newline = chunk.indexOf(0x0a);
      }
      if (chunk.length > maxLineBytes) throw new EpisodicMemoryError("invalid-store", `Episodic store record exceeds ${maxLineBytes} bytes`);
      pending = chunk;
    }
    tornBytes = pending.length;
  } finally {
    await handle.close();
  }
  if (tornBytes > 0) {
    if (strict) throw new EpisodicMemoryError("invalid-store", "Episodic checkpoint contains a torn record");
    // The partial line was never a durable record; leaving it would let the
    // next append concatenate onto it.
    const writer = await openOwnerFile(path, constants.O_RDWR);
    if (writer) {
      try {
        await writer.handle.truncate(completeBytes);
        await syncDurably(writer.handle);
      } finally {
        await writer.handle.close();
      }
    }
  }
  return { tornBytes };
}

function isRevision(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

function isStringArray(value: unknown): value is string[] {
  return Array.isArray(value) && value.every(entry => typeof entry === "string");
}

function isContextRuns(value: unknown): boolean {
  return Array.isArray(value) && value.every(run => Array.isArray(run) && run.length === 2 && isRevision(run[0]) && isRevision(run[1]) && run[1] > 0);
}

function isCatalogRecord(value: Record<string, unknown>): boolean {
  return isRevision(value.revision) && isRevision(value.index) && typeof value.entryId === "string"
    && (value.kind === "user" || value.kind === "talk" || value.kind === "echo" || value.kind === "event")
    && typeof value.text === "string" && typeof value.omitted === "boolean" && isStringArray(value.omissions)
    // Every catalog record carries its entry's instant. Its text is not parsed
    // here: `date` reports an instant it cannot read as unavailable.
    && typeof value.timestamp === "string"
    && typeof value.sourceDigest === "string" && typeof value.projectedDigest === "string" && typeof value.sessionId === "string";
}

function isNodeLogRecord(value: Record<string, unknown>): boolean {
  if (typeof value.nodes === "string") {
    return isRevision(value.revision) && isRevision(value.generation) && isRevision(value.part) && isRevision(value.parts)
      && value.part < value.parts && value.nodes.split(" ").every(code => code === "" || decodeNodeCode(code) !== undefined);
  }
  const childRevisions = value.childRevisions;
  const shape = isRevision(value.revision) && isRevision(value.level) && isRevision(value.index)
    && (value.kind === "free" || value.kind === "summary") && typeof value.text === "string"
    && isContextRuns(value.contextRuns) && typeof value.textDigest === "string" && typeof value.sourceDigest === "string"
    && (childRevisions === undefined || (Array.isArray(childRevisions) && childRevisions.length === 2 && childRevisions.every(isRevision)));
  if (!shape) return false;
  // A free node made no call and holds no context; a summary's runs must cover
  // exactly the messages before its end, or the dependents it implies are wrong.
  const runs = value.contextRuns as EpisodicContextRun[];
  if (value.kind === "free") return runs.length === 0;
  const end = (value.level as number) === 0 ? value.index as number : ((value.index as number) + 1) * 2 ** (value.level as number);
  return runs.reduce((total, run) => total + run[1] * 2 ** run[0], 0) === end;
}

function parseRecord<T>(line: string, isRecord: (value: Record<string, unknown>) => boolean): T {
  try {
    const value = JSON.parse(line) as unknown;
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("not an object");
    if (!isRecord(value as Record<string, unknown>)) throw new Error("not a record of this store");
    return value as T;
  } catch {
    throw new EpisodicMemoryError("invalid-store", "Episodic store holds a record that is not a valid record");
  }
}

async function directoryExists(path: string): Promise<boolean> {
  try {
    return (await lstat(path)).isDirectory();
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return false;
    throw new EpisodicMemoryError("unsafe-store", "Episodic store directory could not be inspected");
  }
}

async function fileExists(path: string): Promise<boolean> {
  try {
    return (await lstat(path)).isFile();
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return false;
    throw new EpisodicMemoryError("unsafe-store", "Episodic store file could not be inspected");
  }
}

/** Create (when asked) and verify one owner-only directory. */
async function assertOwnerDirectory(path: string, create = false): Promise<void> {
  if (create) {
    try {
      await mkdir(path, { mode: 0o700 });
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw new EpisodicMemoryError("unsafe-store", "Episodic store directory could not be created");
    }
  }
  let info;
  try {
    info = await lstat(path);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") throw new EpisodicMemoryError("unsafe-store", "Episodic store directory is missing");
    throw new EpisodicMemoryError("unsafe-store", "Episodic store directory could not be inspected");
  }
  if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== process.getuid?.() || (info.mode & 0o777) !== 0o700) {
    throw new EpisodicMemoryError("unsafe-store", "Episodic store directory must be an owner-only directory");
  }
}
