import { appendFile, mkdir, open, readFile, rename, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { GatewayError } from "../errors.js";
import { AsyncMutex } from "../util/async-mutex.js";
import { createHash, randomUUID } from "node:crypto";
import { durablePublishBoundedJson, syncDurably } from "../util/durable-json.js";
import type { FixedSetting, SettingsTarget } from "./settings-resolver.js";
import type { Direction, LayerId, Qualifiers, Tier } from "./settings-types.js";

/**
 * The settings change record (docs/settings-model.md 5.2, foundation F2).
 *
 * Audit and undo only: it is never consulted to compute a value. It is kept
 * forever (decision 12), append-only, in closed segments of at most
 * `SEGMENT_ENTRIES` lines named in `index.json`, so `settings.history` reads one
 * bounded segment per page. A later fact about an entry (approved, expired,
 * committed, outside) is a new entry that refers to it; no line is rewritten.
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

export type ChangeStatus = "applied" | "pending" | "approved" | "declined" | "expired" | "superseded" | "failed" | "outside" | "committed";

export interface TierBasis {
  direction: Direction;
  floor: Tier;
  floorSource: "code" | "override";
  web: boolean;
  risk: Tier | null;
  riskEvaluation?: { status: "assessed" | "failed" | "timeout"; rationale: string };
}

export interface GitResult {
  root: string | null;
  path: string;
  staged: boolean;
  reason?: string;
  blob?: string;
  warning?: string;
  /** An outside change or commit fact: the repository's `HEAD` commit and branch then. */
  head?: string;
  branch?: string;
}

export interface ChangeEntry {
  changeId: string;
  at: string;
  commandId?: string;
  actor: Actor;
  target: SettingsTarget;
  layer: Exclude<LayerId, "builtin">;
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
  /** Entries one change wrote together and undo reverts together: both notes of a
   * profile supersede, or every item of a Confirm all (doc 6.4). */
  group?: { id: string; size: number };
}

export const SEGMENT_ENTRIES = 500;
interface RecordIndex { version: 1; segments: Array<{ name: string; count: number; closed?: true }> }

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
      const index = await this.index();
      for (const entry of entries) {
        let segment = index.segments[index.segments.length - 1];
        if (!segment || segment.closed || segment.count >= this.segmentEntries) {
          segment = { name: String(index.segments.length).padStart(6, "0"), count: 0 };
          index.segments.push(segment);
        }
        await appendFile(join(this.directory, `${segment.name}.jsonl`), `${JSON.stringify(entry)}\n`, "utf8");
        segment.count += 1;
      }
      const temporary = join(this.directory, "index.json.tmp");
      await writeFile(temporary, `${JSON.stringify(index)}\n`, "utf8");
      await rename(temporary, join(this.directory, "index.json"));
    });
  }

  /** Startup transfers publish one immutable, identity-addressed segment. A crash
   * between segment and index publication can be completed without duplicating the
   * audit or consulting it as settings truth. Call before ordinary writers start. */
  async appendOnce(entry: ChangeEntry): Promise<void> {
    await this.mutex.run(async () => {
      const name = `once-${createHash("sha256").update(entry.changeId).digest("hex")}`;
      const path = join(this.directory, `${name}.jsonl`);
      const index = await this.index();
      const existing = await this.segmentLines(name);
      if (existing.length && (existing.length !== 1 || JSON.stringify(existing[0]) !== JSON.stringify(entry))) {
        throw new GatewayError("conflict", "The settings transfer audit conflicts with its intent");
      }
      if (!existing.length) {
        const encoded = `${JSON.stringify(entry)}\n`;
        if (Buffer.byteLength(encoded) > 1024 * 1024) throw new GatewayError("conflict", "The settings transfer audit exceeds its bound");
        await mkdir(this.directory, { recursive: true, mode: 0o700 });
        const temporary = `${path}.${randomUUID()}.tmp`;
        try {
          const file = await open(temporary, "wx", 0o600);
          try { await file.writeFile(encoded); await syncDurably(file); } finally { await file.close(); }
          await rename(temporary, path);
          const directory = await open(this.directory, "r");
          try { await syncDurably(directory); } finally { await directory.close(); }
        } finally { await rm(temporary, { force: true }); }
      }
      if (!index.segments.some(segment => segment.name === name)) {
        index.segments.push({ name, count: 1, closed: true });
        await durablePublishBoundedJson(join(this.directory, "index.json"), index, 16 * 1024 * 1024);
      }
    });
  }

  /** Newest first. The cursor names a segment and how many of its lines remain. */
  async page(input: { cursor?: string; limit?: number; filter?: (entry: ChangeEntry) => boolean }): Promise<{ entries: ChangeEntry[]; nextCursor?: string }> {
    const limit = Math.min(Math.max(input.limit ?? 50, 1), 200);
    const index = await this.index();
    const [segmentIndex, remaining] = input.cursor ? parseCursor(input.cursor) : [index.segments.length - 1, Number.POSITIVE_INFINITY];
    const entries: ChangeEntry[] = [];
    const segment = index.segments[segmentIndex];
    if (!segment) return { entries };
    // Bound scanned work, not just returned matches: a sparse filter over the
    // permanent audit must yield an empty page + cursor instead of a full scan.
    const lines = await this.segmentLines(segment.name);
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

  private async segmentLines(name: string): Promise<ChangeEntry[]> {
    const text = await readFile(join(this.directory, `${name}.jsonl`), "utf8").catch((error: NodeJS.ErrnoException) => {
      if (error.code === "ENOENT") return "";
      throw error;
    });
    return text.split("\n").filter(Boolean).map(line => JSON.parse(line) as ChangeEntry);
  }

  private async index(): Promise<RecordIndex> {
    try {
      const value = JSON.parse(await readFile(join(this.directory, "index.json"), "utf8")) as RecordIndex;
      if (value.version !== 1 || !Array.isArray(value.segments)) throw new Error("bad index");
      return value;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return { version: 1, segments: [] };
      throw new GatewayError("conflict", "The settings change record index could not be read");
    }
  }
}

function parseCursor(cursor: string): [number, number] {
  const match = /^(\d{1,9}):(\d{1,16})$/u.exec(cursor);
  if (!match) throw new GatewayError("invalid_request", "Invalid settings history cursor");
  return [Number(match[1]), Number(match[2])];
}
