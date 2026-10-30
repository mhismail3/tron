import { type ChangeStatus, type GitResult, type FixedSetting, type SettingsTarget, type LayerId, type Qualifiers } from "./tool-contract.js";
import { mkdir, open, readdir, rename, rm } from "node:fs/promises";
import { constants } from "node:fs";
import { join } from "node:path";
import { GatewayError } from "../../errors.js";
import { AsyncMutex } from "../../util/async-mutex.js";
import { createHash, randomUUID } from "node:crypto";
import { durableAtomicWriteText, durablePublishBoundedJson, syncDurably } from "../../foundation/durable-json.js";

/**
 * The settings change record (docs/settings-model.md 5.2, foundation F2).
 *
 * Audit and undo only: it is never consulted to compute a value. It is kept
 * forever (decision 12), append-only, in closed segments of at most
 * `SEGMENT_ENTRIES` lines named in `index.json`, so `settings.history` reads one
 * bounded segment per page (plus the newer segments' settling references). A
 * later fact about an entry (approved, expired, committed, outside) is a new
 * entry that refers to it; no line is rewritten.
 */

export type ActorKind = "ui" | "home" | "worker" | "agent" | "outside";
export interface Actor {
  kind: ActorKind;
  /** Paired device id, session id, or the file for an outside change. */
  id: string;
  sessionId?: string;
  toolCallId?: string;
  taskId?: string;
}




export interface ChangeEntry {
  changeId: string;
  at: string;
  commandId?: string;
  actor: Actor;
  target: SettingsTarget;
  layer: LayerId;
  key: string;
  qualifiers?: Qualifiers;
  op: "set" | "unset";
  /** Absent for redacted keys, which record only `changed`. */
  before?: unknown;
  after?: unknown;
  fixedAt?: FixedSetting;
  changed?: true;
  redacted?: true;
  /** A record subject that did not exist before (an MCP server or model provider added outside Tron). */
  added?: true;
  reason?: string;
  status: ChangeStatus;
  failure?: string;
  git?: GitResult;
  undoOf?: string;
  applyAgainOf?: string;
  /** A later fact about an earlier entry. */
  refersTo?: string;
  /** A typed action fact: `key` names its subject, `after` its preview. Never undoable. */
  action?: true;
  /** Entries one change wrote together and undo reverts together: both notes of a
   * profile supersede, or every item of a Confirm all (doc 6.4). */
  group?: { id: string; size: number };
}

const SEGMENT_ENTRIES = 500;
const SEGMENT_BYTES = 1024 * 1024;
const INDEX_BYTES = 16 * 1024 * 1024;
interface RecordIndex { version: 1; segments: Array<{ name: string; count: number; closed?: true }> }

function publication(entries: readonly ChangeEntry[]): { name: string; encoded: string; count: number } | undefined {
  if (!entries.length) return undefined;
  const group = entries[0]!.group;
  if (!group?.id || group.size !== entries.length || new Set(entries.map(entry => entry.changeId)).size !== entries.length
    || entries.some(entry => entry.group?.id !== group.id || entry.group.size !== group.size)) {
    throw new GatewayError("invalid_request", "A settings transfer audit must contain one complete group with unique entries");
  }
  const encoded = entries.map(entry => `${JSON.stringify(entry)}\n`).join("");
  if (Buffer.byteLength(encoded) > 1024 * 1024) throw new GatewayError("conflict", "The settings transfer audit exceeds its bound");
  return { name: `once-${createHash("sha256").update(group.id).digest("hex")}`, encoded, count: entries.length };
}

export class SettingsChangeRecord {
  private readonly mutex = new AsyncMutex();
  private readonly directory: string;

  constructor(tronHome: string, private readonly segmentEntries = SEGMENT_ENTRIES) {
    this.directory = join(tronHome, "gateway", "settings", "changes");
  }

  get path(): string { return this.directory; }

  /** Recover complete published bytes before effects, with no effect replay or new journal. */
  async recover(): Promise<void> {
    await this.mutex.run(async () => { await this.recoverIndex(); });
  }

  async append(entries: readonly ChangeEntry[]): Promise<void> {
    if (!entries.length) return;
    if (entries.length > SEGMENT_ENTRIES) throw new GatewayError("conflict", "The settings audit exceeds its row bound");
    const encoded = entries.map(entry => JSON.stringify(entry) + "\n");
    if (Buffer.byteLength(encoded.join("")) > SEGMENT_BYTES) throw new GatewayError("conflict", "The settings audit exceeds its byte bound");
    await this.mutex.run(async () => {
      const index = await this.recoverIndex();
      let segment = index.segments.at(-1);
      let text = segment && !segment.closed && segment.count < this.segmentEntries
        ? await boundedText(join(this.directory, segment.name + ".jsonl"), SEGMENT_BYTES) : "";
      if (!text) segment = undefined;
      const writes = new Map<string, string>();
      for (const row of encoded) {
        if (!segment || segment.count >= this.segmentEntries || Buffer.byteLength(text) + Buffer.byteLength(row) > SEGMENT_BYTES) {
          if (segment) segment.closed = true;
          segment = { name: String(index.segments.length).padStart(6, "0"), count: 0 };
          index.segments.push(segment);
          text = "";
        }
        text += row;
        segment.count += 1;
        writes.set(segment.name, text);
      }
      // Atomic replacement preserves the existing prefix byte-for-byte. A crash
      // cannot leave a partially appended row; index visibility follows durable bytes.
      for (const [name, content] of writes) await durableAtomicWriteText(join(this.directory, name + ".jsonl"), content);
      await this.publishIndex(index);
    });
  }

  private async publishIndex(index: RecordIndex): Promise<void> {
    const text = JSON.stringify(index) + "\n";
    if (Buffer.byteLength(text) > INDEX_BYTES) throw new GatewayError("conflict", "The settings audit index exceeds its byte bound");
    await durableAtomicWriteText(join(this.directory, "index.json"), text);
  }

  private async recoverIndex(): Promise<RecordIndex> {
    const index = await this.index();
    const files = await readdir(this.directory, { withFileTypes: true }).catch((error: NodeJS.ErrnoException) => {
      if (error.code === "ENOENT") return [];
      throw error;
    });
    if (files.length > 10_000) throw new GatewayError("conflict", "The settings audit directory exceeds its recovery bound");
    const names = new Set(index.segments.map(segment => segment.name));
    const orphans = files.filter(file => file.name.endsWith(".jsonl") && !names.has(file.name.slice(0, -6)));
    if (orphans.some(file => !file.isFile() || !segmentName(file.name.slice(0, -6)))) throw new GatewayError("conflict", "The settings audit contains an unknown segment");
    // An unindexed Home group is not ordinary append recovery. Only Home can
    // prove its domain committed and that Forget did not invalidate its envelope.
    // appendOnce publishes that exact group on the owner\'s explicit retry.
    const ordered = orphans.map(file => file.name.slice(0, -6)).filter(name => !name.startsWith("once-")).sort();
    const candidates: ChangeEntry[] = [];
    let changed = false;
    const tail = index.segments.at(-1);
    // A non-tail segment is immutable. A valid JSON newline truncation must not
    // turn a complete grouped Undo into a silently partial restoration.
    for (const segment of index.segments.slice(0, -1)) await this.indexedLines(segment);
    if (tail) {
      const rows = await this.segmentLines(tail.name);
      if (rows.length < tail.count || tail.closed && rows.length !== tail.count) throw new GatewayError("conflict", "The settings audit tail conflicts with its index");
      candidates.push(...rows.slice(tail.count));
      if (rows.length !== tail.count) { tail.count = rows.length; changed = true; }
    }
    for (const name of ordered) {
      const rows = await this.segmentLines(name);
      if (!rows.length) throw new GatewayError("conflict", "The settings audit contains an empty orphan");
      if (name !== String(index.segments.length).padStart(6, "0")) throw new GatewayError("conflict", "The settings audit contains an unordered orphan");
      index.segments.push({ name, count: rows.length });
      candidates.push(...rows);
      changed = true;
    }
    const groups = new Map<string, ChangeEntry[]>();
    const ids = new Set<string>();
    for (const row of candidates) {
      if (ids.has(row.changeId)) throw new GatewayError("conflict", "The settings audit contains duplicate recovered identities");
      ids.add(row.changeId);
      if (row.group) groups.set(row.group.id, [...(groups.get(row.group.id) ?? []), row]);
    }
    for (const [id, rows] of groups) if (rows.some(row => row.group?.id !== id || row.group.size !== rows.length)) {
      throw new GatewayError("conflict", "The settings audit recovery contains an incomplete group");
    }
    if (changed) {
      // Re-prove durability even when recovering a previous rename's visible bytes.
      for (const name of new Set([...(tail ? [tail.name] : []), ...ordered])) {
        const file = await open(join(this.directory, name + ".jsonl"), "r");
        try { await syncDurably(file); } finally { await file.close(); }
      }
      const directory = await open(this.directory, "r");
      try { await syncDurably(directory); } finally { await directory.close(); }
      await this.publishIndex(index);
    }
    return index;
  }

  /** Preflight before domain effects; publication enforces the same group/byte bound. */
  validateAppendOnce(entries: readonly ChangeEntry[]): void { publication(entries); }

  /** One immutable group, one index visibility cut. The existing mutex also
   * serializes ordinary writers; replay re-proves file and parent durability. */
  async appendOnce(entries: readonly ChangeEntry[]): Promise<void> {
    const intent = publication(entries);
    if (!intent) return;
    await this.mutex.run(async () => {
      const { name, encoded, count } = intent;
      const path = join(this.directory, `${name}.jsonl`);
      const index = await this.recoverIndex();
      const file = await open(path, "r").catch((error: NodeJS.ErrnoException) => { if (error.code === "ENOENT") return undefined; throw error; });
      if (file) {
        try {
          if ((await file.stat()).size > 1024 * 1024 || !(await file.readFile()).equals(Buffer.from(encoded))) {
            throw new GatewayError("conflict", "The settings transfer audit conflicts with its intent");
          }
          await syncDurably(file);
        } finally { await file.close(); }
      } else {
        await mkdir(this.directory, { recursive: true, mode: 0o700 });
        const temporary = `${path}.${randomUUID()}.tmp`;
        try {
          const created = await open(temporary, "wx", 0o600);
          try { await created.writeFile(encoded); await syncDurably(created); } finally { await created.close(); }
          await rename(temporary, path);
        } finally { await rm(temporary, { force: true }); }
      }
      const directory = await open(this.directory, "r");
      try { await syncDurably(directory); } finally { await directory.close(); }
      const indexed = index.segments.find(segment => segment.name === name);
      if (indexed && (indexed.count !== count || !indexed.closed)) throw new GatewayError("conflict", "The settings transfer index conflicts with its intent");
      if (!indexed) index.segments.push({ name, count, closed: true });
      // Even an indexed retry must re-prove the publication's durability.
      await durablePublishBoundedJson(join(this.directory, "index.json"), index, 16 * 1024 * 1024);
    });
  }

  /** Newest first. The cursor names a segment and how many of its lines remain.
   * Audit keeps every fact; presentation never folds retired approval outcomes. */
  async page(input: { cursor?: string; limit?: number; filter?: (entry: ChangeEntry) => boolean }): Promise<{ entries: ChangeEntry[]; nextCursor?: string }> {
    const limit = Math.min(Math.max(input.limit ?? 50, 1), 200);
    await this.recover();
    const index = await this.index();
    const [segmentIndex, remaining] = input.cursor ? parseCursor(input.cursor) : [index.segments.length - 1, Number.POSITIVE_INFINITY];
    const entries: ChangeEntry[] = [];
    const segment = index.segments[segmentIndex];
    if (!segment) return { entries };
    // Bound scanned work, not just returned matches: a sparse filter over the
    // permanent audit must yield an empty page + cursor instead of a full scan.
    const lines = await this.indexedLines(segment);
    let end = Math.min(remaining, lines.length);
    while (end > 0 && entries.length < limit) {
      end -= 1;
      const entry = lines[end]!;
      if (!input.filter || input.filter(entry)) entries.push(entry);
    }
    if (end > 0) return { entries, nextCursor: `${segmentIndex}:${end}` };
    return { entries, ...(segmentIndex > 0 ? { nextCursor: `${segmentIndex - 1}:${Number.MAX_SAFE_INTEGER}` } : {}) };
  }

  /** An entry and every later fact that refers to it, oldest first. */
  async entry(changeId: string): Promise<{ entry: ChangeEntry; facts: ChangeEntry[]; undone?: true } | undefined> {
    const index = await this.index();
    const facts: ChangeEntry[] = [];
    let undone = false;
    for (let segmentIndex = index.segments.length - 1; segmentIndex >= 0; segmentIndex -= 1) {
      const lines = await this.indexedLines(index.segments[segmentIndex]!);
      for (let line = lines.length - 1; line >= 0; line -= 1) {
        const entry = lines[line]!;
        if (entry.undoOf === changeId && entry.status === "applied") undone = true;
        if (entry.refersTo === changeId) facts.unshift(entry);
        else if (entry.changeId === changeId && !entry.refersTo) return { entry, facts, ...(undone ? { undone: true as const } : {}) };
      }
    }
    return undefined;
  }

  /** Exact complete group, oldest first. Corrupt history never authorizes a partial Undo. */
  async group(groupId: string, size: number): Promise<ChangeEntry[]> {
    const index = await this.index();
    const found: ChangeEntry[] = [];
    for (let segmentIndex = index.segments.length - 1; segmentIndex >= 0; segmentIndex -= 1) {
      const lines = await this.indexedLines(index.segments[segmentIndex]!);
      for (let line = lines.length - 1; line >= 0; line -= 1) {
        const entry = lines[line]!;
        if (entry.group?.id !== groupId) continue;
        if (entry.group.size !== size || found.some(prior => prior.changeId === entry.changeId)) throw new GatewayError("conflict", "The settings audit group conflicts with its identity");
        found.unshift(entry);
      }
    }
    if (found.length !== size) throw new GatewayError("conflict", "The settings audit group is incomplete");
    return found;
  }

  /** Any entry by its own id, a later fact included (an outside change refers to the value it replaced). */
  async find(changeId: string): Promise<ChangeEntry | undefined> {
    const index = await this.index();
    for (let segmentIndex = index.segments.length - 1; segmentIndex >= 0; segmentIndex -= 1) {
      const found = (await this.indexedLines(index.segments[segmentIndex]!)).find(entry => entry.changeId === changeId);
      if (found) return found;
    }
    return undefined;
  }

  async segmentCount(): Promise<number> {
    return (await this.index()).segments.length;
  }

  private async indexedLines(segment: RecordIndex["segments"][number]): Promise<ChangeEntry[]> {
    const rows = await this.segmentLines(segment.name);
    if (rows.length !== segment.count) throw new GatewayError("conflict", "The settings audit segment conflicts with its indexed row count");
    return rows;
  }

  private async segmentLines(name: string): Promise<ChangeEntry[]> {
    const text = await boundedText(join(this.directory, name + ".jsonl"), SEGMENT_BYTES);
    if (text && !text.endsWith("\n")) throw new GatewayError("conflict", "The settings audit contains an incomplete row");
    try {
      const rows = text.trimEnd() ? text.trimEnd().split("\n").map(line => JSON.parse(line)) : [];
      if (rows.length > SEGMENT_ENTRIES || rows.some(row => !validEntry(row))) throw new Error("invalid rows");
      return rows as ChangeEntry[];
    } catch { throw new GatewayError("conflict", "The settings audit segment is malformed"); }
  }

  private async index(): Promise<RecordIndex> {
    const text = await boundedText(join(this.directory, "index.json"), INDEX_BYTES, true);
    if (!text) return { version: 1, segments: [] };
    try {
      const value = JSON.parse(text) as RecordIndex;
      if (value.version !== 1 || !Array.isArray(value.segments) || value.segments.length > 10_000
        || new Set(value.segments.map(segment => segment.name)).size !== value.segments.length
        || value.segments.some(segment => !segmentName(segment.name) || !Number.isSafeInteger(segment.count)
          || segment.count < 1 || segment.count > SEGMENT_ENTRIES || segment.closed !== undefined && segment.closed !== true)) throw new Error("bad index");
      return value;
    } catch { throw new GatewayError("conflict", "The settings change record index could not be read"); }
  }
}

function segmentName(value: unknown): value is string {
  return typeof value === "string" && /^(?:\d{6}|once-[a-f0-9]{64})$/.test(value);
}

function validEntry(row: unknown): boolean {
  const object = (value: unknown): value is Record<string, unknown> => !!value && typeof value === "object" && !Array.isArray(value);
  return object(row) && typeof row.changeId === "string" && !!row.changeId && typeof row.at === "string" && Number.isFinite(Date.parse(row.at))
    && object(row.actor) && ["ui", "home", "worker", "agent", "outside"].includes(String(row.actor.kind)) && typeof row.actor.id === "string"
    && object(row.target) && (row.target.kind === "global" || row.target.kind === "home"
      || row.target.kind === "project" && typeof row.target.cwd === "string"
      || row.target.kind === "session" && typeof row.target.sessionId === "string")
    && ["global", "home", "project", "session"].includes(String(row.layer)) && typeof row.key === "string" && !!row.key
    && ["set", "unset"].includes(String(row.op)) && typeof row.status === "string"
    && (row.qualifiers === undefined || object(row.qualifiers) && Object.values(row.qualifiers).every(value => typeof value === "string"))
    && (row.group === undefined || object(row.group) && typeof row.group.id === "string" && !!row.group.id
      && typeof row.group.size === "number" && Number.isSafeInteger(row.group.size) && row.group.size >= 1 && row.group.size <= SEGMENT_ENTRIES);
}

async function boundedText(path: string, maximum: number, missing = false): Promise<string> {
  let file;
  try { file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW); }
  catch (error) {
    if (missing && (error as NodeJS.ErrnoException).code === "ENOENT") return "";
    throw new GatewayError("conflict", "The settings audit file could not be opened");
  }
  try {
    const stat = await file.stat();
    if (!stat.isFile() || stat.size > maximum) throw new GatewayError("conflict", "The settings audit file exceeds its bound");
    return await file.readFile("utf8");
  } finally { await file.close(); }
}

function parseCursor(cursor: string): [number, number] {
  const match = /^(\d{1,9}):(\d{1,16})$/u.exec(cursor);
  if (!match) throw new GatewayError("invalid_request", "Invalid settings history cursor");
  return [Number(match[1]), Number(match[2])];
}
