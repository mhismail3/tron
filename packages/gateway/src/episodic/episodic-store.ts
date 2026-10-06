import { constants } from "node:fs";
import { lstat, mkdir, open, type FileHandle } from "node:fs/promises";
import { join } from "node:path";
import { readSecureJson } from "../util/secure-json.js";
import { durableAtomicWriteJson, syncDurably } from "../util/durable-json.js";
import type { TronWorkspace } from "../workspace/tron-workspace.js";
import {
  EpisodicMemoryError, EPISODIC_STORE_VERSION,
  type EpisodicMessageRecord, type EpisodicNodeLogRecord, type EpisodicNodeRecord, type EpisodicStoreState,
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
 * A namespace that the workspace marker says was initialized but that is now
 * missing is lost state, not a new installation: it refuses rather than
 * restarting and re-spending every compactor call.
 */

const SESSION_ID = /^[A-Za-z0-9._-]{1,160}$/u;
const STATE_MAX_BYTES = 64 * 1_024;
const BLOCKED_REASONS = new Set(["permanent-failure", "retries-exhausted", "budget-exhausted", "source-unavailable"]);

interface StorePaths {
  root: string;
  initialized: string;
  catalog: string;
  nodes: string;
  state: string;
}

export interface EpisodicStoreSnapshot {
  present: boolean;
  messages: EpisodicMessageRecord[];
  nodes: EpisodicNodeLogRecord[];
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
  ) {
    if (!SESSION_ID.test(sessionId)) throw new EpisodicMemoryError("invalid-request", "Source session id cannot name a store directory");
  }

  private async paths(): Promise<StorePaths> {
    const root = join(await this.workspaceStateRoot(), "episodic", this.sessionId);
    return { root, initialized: join(root, "initialized.json"), catalog: join(root, "catalog.jsonl"), nodes: join(root, "nodes.jsonl"), state: join(root, "state.json") };
  }

  /** The workspace's `state/` root. The store never creates it here: creation
   * is lazy and happens on the first append. */
  private async workspaceStateRoot(): Promise<string> {
    const descriptor = await this.workspace.describe();
    if (!descriptor.available) throw new EpisodicMemoryError("unsafe-store", "Tron internal workspace is unavailable; episodic memory cannot be persisted");
    return join(descriptor.root, "state");
  }

  async read(): Promise<EpisodicStoreSnapshot> {
    const paths = await this.paths();
    if (!(await directoryExists(paths.root))) {
      // The workspace marker is the evidence that this namespace once existed.
      if (await this.workspace.featureInitialized("episodic")) {
        throw new EpisodicMemoryError("invalid-store", "Episodic memory namespace is missing after it was initialized");
      }
      return { present: false, messages: [], nodes: [], state: null, recoveredTornBytes: 0, highestGeneration: 0, highestRevision: 0 };
    }
    await assertOwnerDirectory(paths.root);
    const marker = await readSecureJson<unknown>(paths.initialized, 256);
    if (!marker.present) throw new EpisodicMemoryError("invalid-store", "Episodic memory directory exists without initialization evidence");
    if (!marker.value || typeof marker.value !== "object" || Array.isArray(marker.value)
      || (marker.value as { version?: unknown }).version !== EPISODIC_STORE_VERSION) {
      throw new EpisodicMemoryError("invalid-store", "Episodic memory initialization record has an unknown version");
    }

    const catalogRead = await readJsonl<EpisodicMessageRecord>(paths.catalog, this.maxLineBytes, isCatalogRecord);
    const nodesRead = await readJsonl<EpisodicNodeLogRecord>(paths.nodes, this.maxLineBytes, isNodeLogRecord);
    const stateRead = await readSecureJson<unknown>(paths.state, STATE_MAX_BYTES);
    let state: EpisodicStoreState | null = null;
    if (stateRead.present) state = validateState(stateRead.value);
    let highestGeneration = 0;
    let highestRevision = 0;
    for (const record of nodesRead.records) {
      if ("nodes" in record && record.generation > highestGeneration) highestGeneration = record.generation;
      if (record.revision > highestRevision) highestRevision = record.revision;
    }
    for (const record of catalogRead.records) if (record.revision > highestRevision) highestRevision = record.revision;
    return {
      present: true,
      messages: catalogRead.records,
      nodes: nodesRead.records,
      state,
      recoveredTornBytes: catalogRead.tornBytes + nodesRead.tornBytes,
      highestGeneration,
      highestRevision,
    };
  }

  /** The latest record per message index, and per node address, in log order.
   * Invalidation chunks revoke the addresses they name. */
  static replay(snapshot: EpisodicStoreSnapshot): { messages: Map<number, EpisodicMessageRecord>; nodes: Map<string, EpisodicNodeRecord> } {
    const messages = new Map<number, EpisodicMessageRecord>();
    for (const record of snapshot.messages) messages.set(record.index, record);
    const nodes = new Map<string, EpisodicNodeRecord>();
    for (const record of snapshot.nodes) {
      if ("nodes" in record) {
        for (const code of record.nodes.split(" ")) {
          if (code === "") continue;
          const address = decodeNodeCode(code);
          if (address === undefined) throw new EpisodicMemoryError("invalid-store", "Episodic invalidation record names an address that cannot be decoded");
          nodes.delete(address);
        }
      } else nodes.set(nodeAddress(record.level, record.index), record);
    }
    return { messages, nodes };
  }

  async appendCatalog(record: EpisodicMessageRecord): Promise<void> {
    await this.append((await this.paths()).catalog, record);
  }

  async appendNode(record: EpisodicNodeLogRecord): Promise<void> {
    await this.append((await this.paths()).nodes, record);
  }

  async saveState(state: EpisodicStoreState): Promise<void> {
    await this.ensureRoot();
    await durableAtomicWriteJson((await this.paths()).state, state, 0o600);
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

  private async ensureRoot(): Promise<StorePaths> {
    const paths = await this.paths();
    const stateRoot = await this.workspaceStateRoot();
    await assertOwnerDirectory(stateRoot, true);
    await assertOwnerDirectory(join(stateRoot, "episodic"), true);
    await assertOwnerDirectory(paths.root, true);
    if (!(await fileExists(paths.initialized))) {
      await durableAtomicWriteJson(paths.initialized, { version: EPISODIC_STORE_VERSION }, 0o600);
      // The workspace marker is what tells a later start that this namespace is
      // lost state rather than a fresh installation.
      await this.workspace.markFeatureInitialized("episodic");
    }
    return paths;
  }
}

function validateState(value: unknown): EpisodicStoreState {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new EpisodicMemoryError("invalid-store", "Episodic memory state is not an object");
  const state = value as Partial<EpisodicStoreState>;
  if (state.version !== EPISODIC_STORE_VERSION) throw new EpisodicMemoryError("invalid-store", "Episodic memory state has an unknown version");
  if (typeof state.generation !== "number" || !Number.isSafeInteger(state.generation) || state.generation < 0) throw new EpisodicMemoryError("invalid-store", "Episodic memory state has no generation");
  const cursor = state.cursor;
  if (cursor !== null && cursor !== undefined) {
    if (typeof cursor !== "object" || Array.isArray(cursor)) throw new EpisodicMemoryError("invalid-store", "Episodic memory state has an invalid cursor");
    for (const field of ["dev", "ino", "size", "completeBytes"] as const) {
      if (typeof cursor[field] !== "number" || !Number.isSafeInteger(cursor[field]) || cursor[field] < 0) {
        throw new EpisodicMemoryError("invalid-store", `Episodic memory state cursor has no ${field}`);
      }
    }
    if (cursor.leafEntryId !== null && typeof cursor.leafEntryId !== "string") throw new EpisodicMemoryError("invalid-store", "Episodic memory state cursor has an invalid leaf");
    if (cursor.leafLineDigest !== null && typeof cursor.leafLineDigest !== "string") throw new EpisodicMemoryError("invalid-store", "Episodic memory state cursor has an invalid line digest");
  }
  const blocked = state.blocked;
  if (blocked !== null && blocked !== undefined) {
    if (typeof blocked !== "object" || Array.isArray(blocked) || typeof blocked.reason !== "string" || !BLOCKED_REASONS.has(blocked.reason)
      || (blocked.detail !== undefined && typeof blocked.detail !== "string")) {
      throw new EpisodicMemoryError("invalid-store", "Episodic memory state has an invalid blocked state");
    }
  }
  return {
    version: EPISODIC_STORE_VERSION,
    generation: state.generation,
    cursor: cursor ? { ...cursor } : null,
    blocked: blocked ? { ...blocked } : null,
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

async function syncDirectory(path: string): Promise<void> {
  const handle = await open(path, constants.O_RDONLY);
  try {
    await syncDurably(handle);
  } finally {
    await handle.close();
  }
}

async function readJsonl<T>(path: string, maxLineBytes: number, isRecord: (value: Record<string, unknown>) => boolean): Promise<{ records: T[]; tornBytes: number }> {
  const opened = await openOwnerFile(path, constants.O_RDONLY);
  if (!opened) return { records: [], tornBytes: 0 };
  const { handle } = opened;
  const records: T[] = [];
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
        if (line.trim() !== "") records.push(parseRecord<T>(line, isRecord));
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
  return { records, tornBytes };
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
    && typeof value.sourceDigest === "string" && typeof value.projectedDigest === "string" && typeof value.sessionId === "string";
}

function isNodeLogRecord(value: Record<string, unknown>): boolean {
  if (typeof value.nodes === "string") {
    return isRevision(value.revision) && isRevision(value.generation) && isRevision(value.part) && isRevision(value.parts)
      && value.part < value.parts && value.nodes.split(" ").every(code => code === "" || decodeNodeCode(code) !== undefined);
  }
  const childRevisions = value.childRevisions;
  return isRevision(value.revision) && isRevision(value.level) && isRevision(value.index)
    && (value.kind === "free" || value.kind === "summary") && typeof value.text === "string"
    && isContextRuns(value.contextRuns) && typeof value.textDigest === "string" && typeof value.sourceDigest === "string"
    && (childRevisions === undefined || (Array.isArray(childRevisions) && childRevisions.length === 2 && childRevisions.every(isRevision)));
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
