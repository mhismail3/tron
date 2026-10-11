import { appendFile, mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { GatewayError } from "../errors.js";
import { AsyncMutex } from "../util/async-mutex.js";
import type { SettingsTarget } from "./settings-resolver.js";
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

export type ChangeStatus = "applied" | "pending" | "approved" | "declined" | "expired" | "failed" | "outside" | "committed";

export interface TierBasis {
  direction: Direction;
  floor: Tier;
  floorSource: "code" | "override";
  web: boolean;
  risk: Tier | null;
}

export interface GitResult {
  root: string | null;
  path: string;
  staged: boolean;
  reason?: string;
  blob?: string;
  warning?: string;
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
  changed?: true;
  redacted?: true;
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
}

export const SEGMENT_ENTRIES = 500;
interface RecordIndex { version: 1; segments: Array<{ name: string; count: number }> }

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
        if (!segment || segment.count >= this.segmentEntries) {
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

  /** Newest first. The cursor names a segment and how many of its lines remain. */
  async page(input: { cursor?: string; limit?: number; filter?: (entry: ChangeEntry) => boolean }): Promise<{ entries: ChangeEntry[]; nextCursor?: string }> {
    const limit = Math.min(Math.max(input.limit ?? 50, 1), 200);
    const index = await this.index();
    let [segmentIndex, remaining] = input.cursor ? parseCursor(input.cursor) : [index.segments.length - 1, Number.POSITIVE_INFINITY];
    const entries: ChangeEntry[] = [];
    // One page reads at most the segments needed to fill it, each bounded.
    while (segmentIndex >= 0 && entries.length < limit) {
      const segment = index.segments[segmentIndex];
      if (!segment) break;
      const lines = await this.segmentLines(segment.name);
      let end = Math.min(remaining, lines.length);
      while (end > 0 && entries.length < limit) {
        end -= 1;
        const entry = lines[end]!;
        if (!input.filter || input.filter(entry)) entries.push(entry);
      }
      if (end > 0) return { entries, nextCursor: `${segmentIndex}:${end}` };
      segmentIndex -= 1;
      remaining = Number.POSITIVE_INFINITY;
    }
    return { entries, ...(segmentIndex >= 0 ? { nextCursor: `${segmentIndex}:${Number.MAX_SAFE_INTEGER}` } : {}) };
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
