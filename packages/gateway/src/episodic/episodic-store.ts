import { constants } from "node:fs";
import { lstat, mkdir, open } from "node:fs/promises";
import { join } from "node:path";
import { readSecureJson } from "../util/secure-json.js";
import { durableAtomicWriteJson, syncDurably } from "../util/durable-json.js";
import type { TronWorkspace } from "../workspace/tron-workspace.js";
import {
  EpisodicMemoryError, EPISODIC_STORE_VERSION,
  type EpisodicInvalidationRecord, type EpisodicMessageRecord, type EpisodicNodeLogRecord, type EpisodicNodeRecord, type EpisodicStoreState,
} from "./episodic-contract.js";
import { nodeAddress } from "./episodic-tree.js";

/*
 * Departure 4 of the brief: the memory persists under the Tron internal
 * workspace's capability state, `state/episodic/<sourceSessionId>/`, owned and
 * secured the way KnowledgeStore owns `state/knowledge/` (owner-only 0700
 * directory, created lazily, owner-only files, secure bounded reads).
 *
 * The catalog and the node log are append-only JSONL, and every record is
 * fsynced before it is used. A trailing partial line is a torn, unacknowledged
 * write (the record never became durable), so it is truncated away on load and
 * reported; any other unparsable record refuses the store visibly.
 */

const SESSION_ID = /^[A-Za-z0-9._-]{1,160}$/u;
const STATE_MAX_BYTES = 64 * 1_024;

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
      return { present: false, messages: [], nodes: [], state: null, recoveredTornBytes: 0 };
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
    return {
      present: true,
      messages: catalogRead.records,
      nodes: nodesRead.records,
      state,
      recoveredTornBytes: catalogRead.tornBytes + nodesRead.tornBytes,
    };
  }

  /** The latest record per message index, and per node address, in log order. */
  static replay(snapshot: EpisodicStoreSnapshot): { messages: Map<number, EpisodicMessageRecord>; nodes: Map<string, EpisodicNodeRecord> } {
    const messages = new Map<number, EpisodicMessageRecord>();
    for (const record of snapshot.messages) messages.set(record.index, record);
    const nodes = new Map<string, EpisodicNodeRecord>();
    for (const record of snapshot.nodes) {
      if ("addresses" in record) {
        for (const address of record.addresses) nodes.delete(address);
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
    await this.ensureRoot();
    const line = `${JSON.stringify(record)}\n`;
    if (Buffer.byteLength(line, "utf8") > this.maxLineBytes) throw new EpisodicMemoryError("invalid-store", "Episodic record exceeds the store's line bound");
    const handle = await open(path, constants.O_WRONLY | constants.O_APPEND | constants.O_CREAT, 0o600);
    try {
      await handle.writeFile(line, "utf8");
      // Durable before use: the recipe fsyncs every node, and a record a caller
      // has observed must survive a crash.
      await syncDurably(handle);
    } finally {
      await handle.close();
    }
  }

  private async ensureRoot(): Promise<void> {
    const paths = await this.paths();
    const stateRoot = await this.workspaceStateRoot();
    await assertOwnerDirectory(stateRoot, true);
    await assertOwnerDirectory(join(stateRoot, "episodic"), true);
    await assertOwnerDirectory(paths.root, true);
    if (!(await fileExists(paths.initialized))) await durableAtomicWriteJson(paths.initialized, { version: EPISODIC_STORE_VERSION }, 0o600);
  }
}

function validateState(value: unknown): EpisodicStoreState {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new EpisodicMemoryError("invalid-store", "Episodic memory state is not an object");
  const state = value as Partial<EpisodicStoreState>;
  if (state.version !== EPISODIC_STORE_VERSION) throw new EpisodicMemoryError("invalid-store", "Episodic memory state has an unknown version");
  if (typeof state.generation !== "number" || !Number.isSafeInteger(state.generation) || state.generation < 0) throw new EpisodicMemoryError("invalid-store", "Episodic memory state has no generation");
  if (state.cursor !== null && state.cursor !== undefined
    && (typeof state.cursor !== "object" || typeof state.cursor.completeBytes !== "number" || !Number.isSafeInteger(state.cursor.completeBytes))) {
    throw new EpisodicMemoryError("invalid-store", "Episodic memory state has an invalid cursor");
  }
  return {
    version: EPISODIC_STORE_VERSION,
    generation: state.generation,
    cursor: state.cursor ? { completeBytes: state.cursor.completeBytes, leafEntryId: typeof state.cursor.leafEntryId === "string" ? state.cursor.leafEntryId : null } : null,
    blocked: state.blocked ?? null,
  };
}

async function readJsonl<T>(path: string, maxLineBytes: number, isRecord: (value: Record<string, unknown>) => boolean): Promise<{ records: T[]; tornBytes: number }> {
  let handle;
  try {
    handle = await open(path, constants.O_RDONLY);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return { records: [], tornBytes: 0 };
    throw new EpisodicMemoryError("invalid-store", `Episodic store file cannot be opened: ${(error as NodeJS.ErrnoException).code ?? "unknown"}`);
  }
  const records: T[] = [];
  let completeBytes = 0;
  let tornBytes = 0;
  try {
    const info = await handle.stat();
    if (!info.isFile() || info.uid !== process.getuid?.() || (info.mode & 0o077) !== 0) throw new EpisodicMemoryError("unsafe-store", "Episodic store file is not a bounded owner-only regular file");
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
    const writer = await open(path, "r+");
    try {
      await writer.truncate(completeBytes);
      await syncDurably(writer);
    } finally {
      await writer.close();
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

function isCatalogRecord(value: Record<string, unknown>): boolean {
  return isRevision(value.revision) && isRevision(value.index) && typeof value.entryId === "string"
    && (value.kind === "user" || value.kind === "talk" || value.kind === "echo" || value.kind === "event")
    && typeof value.text === "string" && typeof value.omitted === "boolean" && isStringArray(value.omissions)
    && typeof value.sourceDigest === "string" && typeof value.projectedDigest === "string" && typeof value.sessionId === "string";
}

function isNodeLogRecord(value: Record<string, unknown>): boolean {
  if (isStringArray(value.addresses)) return isRevision(value.revision) && isRevision(value.generation);
  const childRevisions = value.childRevisions;
  return isRevision(value.revision) && isRevision(value.level) && isRevision(value.index)
    && (value.kind === "free" || value.kind === "summary") && typeof value.text === "string"
    && isStringArray(value.contextDependencies) && typeof value.textDigest === "string" && typeof value.sourceDigest === "string"
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
