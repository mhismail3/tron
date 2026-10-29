import { CHANGE_STATUSES, LAYERS, QUALIFIER_NAMES, TIERS, type ChangeStatus, type GitResult, type FixedSetting, type SettingsTarget, type LayerId, type Qualifiers, type Tier, type Direction } from "./tool-contract.js";
import { mkdir, open, rename, rm } from "node:fs/promises";
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
 * entry that refers to it. Facts are immutable; ordinary append atomically
 * replaces a bounded segment with its unchanged prefix and one complete group.
 */

const ACTOR_KINDS = ["ui", "home", "worker", "agent", "outside"] as const;
export type ActorKind = typeof ACTOR_KINDS[number];
export interface Actor {
  kind: ActorKind;
  /** Paired device id, session id, or the file for an outside change. */
  id: string;
  sessionId?: string;
  toolCallId?: string;
  taskId?: string;
}



export interface TierBasis {
  direction: Direction;
  floor: Tier;
  floorSource: "code" | "override";
  web: boolean;
  risk: Tier | null;
  riskEvaluation?: { status: "assessed" | "failed" | "timeout"; rationale: string };
  /** The requester asked for the maintainer's approval below this key's approve tier. */
  requested?: true;
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
  tier: Tier;
  tierBasis: TierBasis;
  status: ChangeStatus;
  failure?: string;
  git?: GitResult;
  undoOf?: string;
  applyAgainOf?: string;
  /** A later fact about an earlier entry. */
  refersTo?: string;
  /** The approval request a pending entry belongs to, and on a decision fact who decided. */
  requestId?: string;
  decidedBy?: Actor;
  /** An approval action fact (#1985): `key` names its subject, `after` its preview. Never undoable. */
  action?: true;
  /** Entries one change wrote together and undo reverts together: both notes of a
   * profile supersede, or every item of a Confirm all (doc 6.4). */
  group?: { id: string; size: number };
}

const object = (value: unknown): value is Record<string, unknown> => !!value && typeof value === "object" && !Array.isArray(value);
const text = (value: unknown): value is string => typeof value === "string" && value.length > 0 && value.length <= 4096;
const timestamp = (value: unknown): boolean => text(value) && Number.isFinite(Date.parse(value)) && new Date(value).toISOString() === value;
const member = (values: readonly string[], value: unknown): boolean => typeof value === "string" && values.includes(value);
function actor(value: unknown): boolean {
  return object(value) && member(ACTOR_KINDS, value.kind) && text(value.id)
    && Object.keys(value).every(key => ["kind", "id", "sessionId", "toolCallId", "taskId"].includes(key))
    && ["sessionId", "toolCallId", "taskId"].every(key => value[key] === undefined || text(value[key]));
}
function target(value: unknown): boolean {
  if (!object(value)) return false;
  if (value.kind === "global" || value.kind === "home") return Object.keys(value).length === 1;
  return Object.keys(value).length === 2 && (value.kind === "session" && text(value.sessionId) || value.kind === "project" && text(value.cwd));
}
function qualifiers(value: unknown): boolean {
  return object(value) && Object.entries(value).every(([key, value]) => member(QUALIFIER_NAMES, key) && text(value));
}
function validEntry(entry: unknown): entry is ChangeEntry {
  if (!object(entry) || !text(entry.changeId) || !timestamp(entry.at) || !actor(entry.actor) || !target(entry.target)
    || !text(entry.key) || !member(LAYERS, entry.layer) || !member(["set", "unset"], entry.op) || !member(CHANGE_STATUSES, entry.status)
    || !member(TIERS, entry.tier) || !object(entry.tierBasis)) return false;
  const basis = entry.tierBasis;
  if (!member(["widen", "narrow"], basis.direction) || !member(TIERS, basis.floor) || !member(["code", "override"], basis.floorSource)
    || typeof basis.web !== "boolean" || !(basis.risk === null || member(TIERS, basis.risk))) return false;
  if (basis.requested !== undefined && basis.requested !== true) return false;
  if (basis.riskEvaluation !== undefined && (!object(basis.riskEvaluation)
    || !member(["assessed", "failed", "timeout"], basis.riskEvaluation.status) || typeof basis.riskEvaluation.rationale !== "string")) return false;
  if (["commandId", "reason", "failure", "undoOf", "applyAgainOf", "refersTo", "requestId"].some(key => entry[key] !== undefined && typeof entry[key] !== "string")) return false;
  if (["changed", "redacted", "added", "action"].some(key => entry[key] !== undefined && entry[key] !== true)) return false;
  if (entry.redacted && (entry.before !== undefined || entry.after !== undefined)) return false;
  if (entry.decidedBy !== undefined && !actor(entry.decidedBy)) return false;
  if (entry.qualifiers !== undefined && !qualifiers(entry.qualifiers)) return false;
  if (entry.group !== undefined && (!object(entry.group) || !text(entry.group.id)
    || !Number.isSafeInteger(entry.group.size) || Number(entry.group.size) < 1 || Number(entry.group.size) > 500)) return false;
  if (entry.fixedAt !== undefined) {
    const fixed = entry.fixedAt;
    if (!object(fixed) || !member([...LAYERS, "delegate"], fixed.from) || !timestamp(fixed.at) || !text(fixed.ref)
      || fixed.qualifiers !== undefined && !qualifiers(fixed.qualifiers)
      || fixed.reason !== undefined && typeof fixed.reason !== "string"
      || fixed.via !== undefined && !member(["home-profile:sameAs:home", "home-profile", "home-explicit", "home-fallback"], fixed.via)) return false;
  }
  if (entry.git !== undefined) {
    const git = entry.git;
    if (!object(git) || !(git.root === null || typeof git.root === "string") || typeof git.path !== "string" || typeof git.staged !== "boolean"
      || ["reason", "blob", "warning", "head", "branch"].some(key => git[key] !== undefined && typeof git[key] !== "string")) return false;
  }
  return true;
}

const SEGMENT_ENTRIES = 500;
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

  async append(entries: readonly ChangeEntry[]): Promise<void> {
    if (entries.length === 0) return;
    await this.mutex.run(async () => {
      await mkdir(this.directory, { recursive: true });
      const index = await this.recoveredIndex();
      const group = entries[0]!.group ?? { id: createHash("sha256").update(JSON.stringify(entries.map(entry => entry.changeId))).digest("hex"), size: entries.length };
      const batch = entries.map(entry => ({ ...entry, group: entry.group ?? group }));
      this.completeGroups(batch);
      const encoded = batch.map(entry => `${JSON.stringify(entry)}\n`).join("");
      if (batch.length > this.segmentEntries || Buffer.byteLength(encoded) > 1024 * 1024) {
        throw new GatewayError("conflict", "The settings audit publication exceeds its bound");
      }
      let segment = index.segments[index.segments.length - 1];
      let previous = segment && !segment.closed ? await this.segmentLines(segment.name) : [];
      if (!segment || segment.closed || previous.length + batch.length > this.segmentEntries
        || Buffer.byteLength(previous.map(entry => `${JSON.stringify(entry)}\n`).join("") + encoded) > 1024 * 1024) {
        segment = { name: String(index.segments.length).padStart(6, "0"), count: 0 };
        index.segments.push(segment);
        previous = [];
      }
      // The whole group replaces the segment in one cut. The segment is durable
      // before its index projection; recovery never replays a setting effect.
      await durableAtomicWriteText(join(this.directory, `${segment.name}.jsonl`), previous.map(entry => `${JSON.stringify(entry)}\n`).join("") + encoded);
      segment.count = previous.length + batch.length;
      await durablePublishBoundedJson(join(this.directory, "index.json"), index, 16 * 1024 * 1024);
    });
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
      const index = await this.index();
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
   * `settled` names the page's pending facts a later fact already settles, so a
   * presentation can show the outcome row alone (#2050); audit keeps every fact. */
  async page(input: { cursor?: string; limit?: number; filter?: (entry: ChangeEntry) => boolean }): Promise<{ entries: ChangeEntry[]; settled: string[]; nextCursor?: string }> {
    const limit = Math.min(Math.max(input.limit ?? 50, 1), 200);
    const index = await this.index();
    const [segmentIndex, remaining] = input.cursor ? parseCursor(input.cursor) : [index.segments.length - 1, Number.POSITIVE_INFINITY];
    const entries: ChangeEntry[] = [];
    const segment = index.segments[segmentIndex];
    if (!segment) return { entries, settled: [] };
    // Bound scanned work, not just returned matches: a sparse filter over the
    // permanent audit must yield an empty page + cursor instead of a full scan.
    const lines = await this.segmentLines(segment.name);
    // Settling facts are newer than their pending fact: this segment and later ones.
    const settled = new Set<string>();
    for (const line of lines) if (line.refersTo) settled.add(line.refersTo);
    for (let newer = segmentIndex + 1; newer < index.segments.length; newer += 1) {
      for (const line of await this.segmentLines(index.segments[newer]!.name)) if (line.refersTo) settled.add(line.refersTo);
    }
    let end = Math.min(remaining, lines.length);
    while (end > 0 && entries.length < limit) {
      end -= 1;
      const entry = lines[end]!;
      if (!input.filter || input.filter(entry)) entries.push(entry);
    }
    const settledPending = entries.filter(entry => entry.status === "pending" && settled.has(entry.changeId)).map(entry => entry.changeId);
    if (end > 0) return { entries, settled: settledPending, nextCursor: `${segmentIndex}:${end}` };
    return { entries, settled: settledPending, ...(segmentIndex > 0 ? { nextCursor: `${segmentIndex - 1}:${Number.MAX_SAFE_INTEGER}` } : {}) };
  }

  /** An entry and every later fact that refers to it, oldest first. */
  async entry(changeId: string): Promise<{ entry: ChangeEntry; facts: ChangeEntry[] } | undefined> {
    const index = await this.index();
    const facts: ChangeEntry[] = [];
    for (let segmentIndex = index.segments.length - 1; segmentIndex >= 0; segmentIndex -= 1) {
      const lines = await this.segmentLines(index.segments[segmentIndex]!.name);
      for (let line = lines.length - 1; line >= 0; line -= 1) {
        const entry = lines[line]!;
        if (entry.refersTo === changeId) facts.unshift(entry);
        else if (entry.changeId === changeId && !entry.refersTo) return { entry, facts };
      }
    }
    return undefined;
  }

  /** The entries of one group, oldest first. A group is appended in one write, so the
   * scan stops at the segment that holds its first entry. */
  async group(groupId: string, size: number): Promise<ChangeEntry[]> {
    const index = await this.index();
    const found: ChangeEntry[] = [];
    for (let segmentIndex = index.segments.length - 1; segmentIndex >= 0 && found.length < size; segmentIndex -= 1) {
      const lines = await this.segmentLines(index.segments[segmentIndex]!.name);
      for (let line = lines.length - 1; line >= 0 && found.length < size; line -= 1) {
        if (lines[line]!.group?.id === groupId) found.unshift(lines[line]!);
      }
    }
    return found;
  }

  /** Any entry by its own id, a later fact included (an outside change refers to the value it replaced). */
  async find(changeId: string): Promise<ChangeEntry | undefined> {
    const index = await this.index();
    for (let segmentIndex = index.segments.length - 1; segmentIndex >= 0; segmentIndex -= 1) {
      const found = (await this.segmentLines(index.segments[segmentIndex]!.name)).find(entry => entry.changeId === changeId);
      if (found) return found;
    }
    return undefined;
  }

  async segmentCount(): Promise<number> {
    return (await this.index()).segments.length;
  }

  /** Startup and ordinary append share the record mutex. Only the numeric tail
   * can have been replaced before its index cut; earlier immutable groups retain
   * their existing domain publication/recovery owner. */
  async recover(): Promise<void> { await this.mutex.run(async () => { await this.recoveredIndex(); }); }

  private completeGroups(entries: readonly ChangeEntry[]): void {
    const groups = new Map<string, ChangeEntry[]>();
    for (const entry of entries) {
      if (!entry.group || !text(entry.group.id) || !Number.isSafeInteger(entry.group.size) || entry.group.size < 1) {
        throw new GatewayError("conflict", "An unpublished settings audit has no complete group");
      }
      const found = groups.get(entry.group.id) ?? [];
      found.push(entry); groups.set(entry.group.id, found);
    }
    for (const entries of groups.values()) {
      if (entries.some(entry => entry.group!.size !== entries.length) || new Set(entries.map(entry => entry.changeId)).size !== entries.length) {
        throw new GatewayError("conflict", "An unpublished settings audit group is incomplete");
      }
    }
  }

  private async recoveredIndex(): Promise<RecordIndex> {
    const index = await this.index();
    let changed = false;
    const tail = index.segments[index.segments.length - 1];
    if (tail && !tail.closed) {
      const entries = await this.segmentLines(tail.name);
      if (entries.length < tail.count) throw new GatewayError("conflict", "The settings audit tail lost indexed entries");
      if (entries.length > tail.count) {
        this.completeGroups(entries.slice(tail.count));
        tail.count = entries.length; changed = true;
      }
    }
    const name = String(index.segments.length).padStart(6, "0");
    const path = join(this.directory, `${name}.jsonl`);
    const orphan = await this.boundedText(path, 1024 * 1024, true);
    if (orphan !== undefined) {
      const entries = this.decodeEntries(orphan);
      if (!entries.length) throw new GatewayError("conflict", "The unpublished settings audit is empty");
      this.completeGroups(entries);
      index.segments.push({ name, count: entries.length }); changed = true;
    }
    if (changed) {
      // Re-prove both bytes and namespace durability before publishing visibility.
      for (const segment of index.segments.slice(-2)) {
        const file = await open(join(this.directory, `${segment.name}.jsonl`), "r");
        try { await syncDurably(file); } finally { await file.close(); }
      }
      const directory = await open(this.directory, "r");
      try { await syncDurably(directory); } finally { await directory.close(); }
      await durablePublishBoundedJson(join(this.directory, "index.json"), index, 16 * 1024 * 1024);
    }
    return index;
  }

  private decodeEntries(text: string): ChangeEntry[] {
    try {
      if (text && !text.endsWith("\n")) throw new Error("incomplete line");
      const entries = text.split("\n").filter(Boolean).map(line => JSON.parse(line) as ChangeEntry);
      if (entries.length > 500 || new Set(entries.map(entry => entry?.changeId)).size !== entries.length || entries.some(entry => !validEntry(entry))) throw new Error("invalid entries");
      return entries;
    } catch { throw new GatewayError("conflict", "The settings audit segment is malformed or exceeds its bound"); }
  }

  private async boundedText(path: string, bound: number, missing = false): Promise<string | undefined> {
    const file = await open(path, "r").catch((error: NodeJS.ErrnoException) => {
      if (missing && error.code === "ENOENT") return undefined;
      throw new GatewayError("conflict", "The settings audit file is unavailable");
    });
    if (!file) return undefined;
    try {
      const info = await file.stat();
      if (!info.isFile() || info.size > bound) throw new Error("file bound");
      const buffer = Buffer.alloc(bound + 1);
      let bytes = 0;
      while (bytes < buffer.length) {
        const read = await file.read(buffer, bytes, buffer.length - bytes, bytes);
        if (!read.bytesRead) break;
        bytes += read.bytesRead;
      }
      if (bytes > bound) throw new Error("file grew beyond bound");
      return buffer.toString("utf8", 0, bytes);
    } catch { throw new GatewayError("conflict", "The settings audit file could not be read within its bound"); }
    finally { await file.close(); }
  }

  private async segmentLines(name: string): Promise<ChangeEntry[]> {
    return this.decodeEntries((await this.boundedText(join(this.directory, `${name}.jsonl`), 1024 * 1024))!);
  }

  private async index(): Promise<RecordIndex> {
    try {
      const text = await this.boundedText(join(this.directory, "index.json"), 16 * 1024 * 1024, true);
      if (text === undefined) return { version: 1, segments: [] };
      const value = JSON.parse(text) as RecordIndex;
      if (value.version !== 1 || !Array.isArray(value.segments) || new Set(value.segments.map(segment => segment.name)).size !== value.segments.length
        || value.segments.some(segment => !/^(?:[0-9]{6,9}|once-[a-f0-9]{64})$/.test(segment.name)
          || !Number.isSafeInteger(segment.count) || segment.count < 0 || segment.count > 500
          || segment.closed !== undefined && segment.closed !== true)) throw new Error("bad index");
      return value;
    } catch { throw new GatewayError("conflict", "The settings change record index could not be read"); }
  }
}

function parseCursor(cursor: string): [number, number] {
  const match = /^(\d{1,9}):(\d{1,16})$/u.exec(cursor);
  if (!match) throw new GatewayError("invalid_request", "Invalid settings history cursor");
  return [Number(match[1]), Number(match[2])];
}
