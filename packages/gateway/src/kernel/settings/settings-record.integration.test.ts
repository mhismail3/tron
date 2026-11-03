import { mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, it, vi } from "vitest";
import { awaitsWithin } from "../../../test-support/wait-for.js";
import { SettingsChangeRecord, type ChangeEntry } from "./settings-record.js";

/** One read of a record file held open at an exact point: after the reader has
 * opened it and before it reads its bytes. Every write still goes to disk for real. */
const hold = vi.hoisted(() => ({
  match: undefined as ((path: string) => boolean) | undefined,
  entered: undefined as (() => void) | undefined,
  release: undefined as Promise<void> | undefined,
}));

/** One atomic publish held just before its rename makes it visible. */
const holdRename = vi.hoisted(() => ({
  match: undefined as ((path: string) => boolean) | undefined,
  entered: undefined as (() => void) | undefined,
  release: undefined as Promise<void> | undefined,
}));

vi.mock("node:fs/promises", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:fs/promises")>();
  return {
    ...actual,
    rename: async (...args: Parameters<typeof actual.rename>) => {
      if (holdRename.match?.(String(args[1]))) {
        holdRename.match = undefined;
        holdRename.entered?.();
        await holdRename.release;
      }
      return actual.rename(...args);
    },
    open: async (...args: Parameters<typeof actual.open>) => {
      const handle = await actual.open(...args);
      const path = String(args[0]);
      if (!hold.match?.(path)) return handle;
      hold.match = undefined;
      const readFile = handle.readFile.bind(handle) as (...values: unknown[]) => Promise<unknown>;
      (handle as unknown as { readFile: (...values: unknown[]) => Promise<unknown> }).readFile = async (...values) => {
        hold.entered?.();
        await hold.release;
        return readFile(...values);
      };
      return handle;
    },
  };
});

const roots: string[] = [];
afterEach(async () => {
  hold.match = undefined;
  holdRename.match = undefined;
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })));
});

async function record(segmentEntries = 5): Promise<{ record: SettingsChangeRecord; directory: string }> {
  const root = await mkdtemp(join(tmpdir(), "tron-settings-record-"));
  roots.push(root);
  const value = new SettingsChangeRecord(root, segmentEntries);
  return { record: value, directory: value.path };
}

const entry = (index: number, group?: { id: string; size: number }): ChangeEntry => ({
  changeId: `change-${String(index).padStart(5, "0")}`, at: new Date(1_800_000_000_000 + index).toISOString(),
  actor: { kind: "ui", id: "device" }, target: { kind: "global" }, layer: "global", key: "run.retry.maxRetries",
  op: "set", before: index, after: index + 1, status: "applied", ...(group ? { group } : {}),
});
const sequence = (entry: ChangeEntry) => Number(entry.changeId.slice("change-".length));

/** Holds the next read of a file whose path `match` selects; resolves once the reader is inside it. */
function holdNextRead(match: (path: string) => boolean): { entered: Promise<void>; release: () => void } {
  let entered!: () => void;
  let release!: () => void;
  const reached = new Promise<void>(resolve => { entered = resolve; });
  hold.release = new Promise<void>(resolve => { release = resolve; });
  hold.entered = entered;
  hold.match = match;
  return { entered: reached, release };
}

/** Holds the next publish of `index.json`; resolves once the writer is inside it. */
function holdNextIndexPublish(): { entered: Promise<void>; release: () => void } {
  let entered!: () => void;
  let release!: () => void;
  const reached = new Promise<void>(resolve => { entered = resolve; });
  holdRename.release = new Promise<void>(resolve => { release = resolve; });
  holdRename.entered = entered;
  holdRename.match = path => path.endsWith("index.json");
  return { entered: reached, release };
}

it("makes a read that arrives while a write is pending wait for that write and observe it", async () => {
  const { record } = await record_(10);
  await record.append([entry(0)]);
  const held = holdNextIndexPublish();
  const write = record.append([entry(1)]);
  await awaitsWithin(held.entered, "the write holds its index publication");
  // The published index still names only entry 0: a read that did not wait would return it.
  const reads = Promise.all([record.page({ limit: 50 }), record.find("change-00001")]);
  held.release();
  await write;
  const [page, found] = await reads;
  expect(page.entries.map(sequence)).toEqual([1, 0]);
  expect(found?.changeId).toBe("change-00001");
});

it("never makes a read wait for a write that started after it", async () => {
  const { record } = await record_(10);
  await record.append([entry(0)]);
  const first = holdNextIndexPublish();
  const write1 = record.append([entry(1)]);
  await awaitsWithin(first.entered, "the first write holds its index publication");
  const read = record.page({ limit: 50 });
  const write2 = record.append([entry(2)]);
  // Hold the later write at its own publication, then let the first one finish.
  const second = holdNextIndexPublish();
  first.release();
  await awaitsWithin(second.entered, "the later write holds its index publication");
  try {
    // The read waited for entry 1 only; the held later write cannot delay it.
    expect((await awaitsWithin(read, "read admitted behind the earlier write alone")).entries.map(sequence)).toEqual([1, 0]);
  } finally { second.release(); }
  await Promise.all([write1, write2]);
  expect((await record.page({ limit: 50 })).entries.map(sequence)).toEqual([2, 1, 0]);
});

it("lets an append publish while a history read is held inside its segment read", async () => {
  const { record } = await record_(10);
  await record.append([entry(0)]);
  const held = holdNextRead(path => path.endsWith(".jsonl"));
  const page = record.page({ limit: 50 });
  await awaitsWithin(held.entered, "history read holds its segment open");
  try {
    // A reader never owns the record: the writer publishes without waiting for it.
    await awaitsWithin(record.append([entry(1)]), "append while a history read is in flight");
  } finally { held.release(); }
  // The held read returns the cut it began with; the next read sees the new entry.
  expect((await page).entries.map(sequence)).toEqual([0]);
  expect((await record.page({ limit: 50 })).entries.map(sequence)).toEqual([1, 0]);
});

it("reads the published cut when a whole-file tail swap and index publish land between its index and segment reads", async () => {
  const { record } = await record_(10);
  await record.append([entry(0), entry(1)]);
  // Mid-swap: the reader has read index.json (count 2) and is about to read the tail.
  const held = holdNextRead(path => path.endsWith("000000.jsonl"));
  const reads = Promise.all([record.page({ limit: 50 }), record.find("change-00001"), record.entry("change-00000")]);
  await awaitsWithin(held.entered, "history read holds the tail between index and segment");
  try {
    await awaitsWithin(record.append([entry(2), entry(3)]), "tail swapped and index republished under the reader");
  } finally { held.release(); }
  const [page, found, single] = await reads;
  // Exactly the indexed prefix of the grown tail: no extra rows, no refusal.
  expect(page.entries.map(sequence)).toEqual([1, 0]);
  expect(found?.changeId).toBe("change-00001");
  expect(single?.entry.changeId).toBe("change-00000");
  expect((await record.page({ limit: 50 })).entries.map(sequence)).toEqual([3, 2, 1, 0]);
});

it("never shows a torn or inconsistent history to readers racing appends, segment rollover and grouped writes", async () => {
  const { record } = await record_(5);
  const total = 120;
  let written = 0, writing = true;
  const writer = (async () => {
    try {
      while (written < total) {
        const size = written % 7 === 0 ? 3 : 1;
        const group = size > 1 ? { id: `group-${written}`, size } : undefined;
        await record.append(Array.from({ length: size }, (_, offset) => entry(written + offset, group)));
        written += size;
      }
    } finally { writing = false; }
  })();
  const observations: string[] = [];
  const reader = async (id: number) => {
    let newest = -1, reads = 0;
    while (writing || reads === 0) {
      reads += 1;
      const committed = written;
      const page = await record.page({ limit: 200 });
      const ids = page.entries.map(sequence);
      // One segment, newest first, contiguous: never a hole, a duplicate or a partial row.
      for (let index = 1; index < ids.length; index += 1) {
        if (ids[index] !== ids[index - 1]! - 1) observations.push(`reader ${id}: non-contiguous ${ids.join(",")}`);
      }
      // Every finished append is visible, and history never moves backwards.
      if (ids.length && ids[0]! < committed - 1) observations.push(`reader ${id}: missed published ${committed - 1}, newest ${ids[0]}`);
      if (ids.length && ids[0]! < newest) observations.push(`reader ${id}: went backwards ${newest} -> ${ids[0]}`);
      newest = Math.max(newest, ids[0] ?? -1);
      // Older pages are closed segments read in full.
      if (page.nextCursor) {
        const older = await record.page({ cursor: page.nextCursor, limit: 200 });
        if (older.entries.length !== 5) observations.push(`reader ${id}: closed segment had ${older.entries.length} rows`);
      }
      if (committed > 0 && (await record.find(entry(committed - 1).changeId))?.changeId !== entry(committed - 1).changeId) {
        observations.push(`reader ${id}: find missed ${committed - 1}`);
      }
      // The newest group whose three members were all published before this read.
      const grouped = Math.floor((committed - 3) / 7) * 7;
      if (committed >= 3) {
        const members = await record.group(`group-${grouped}`, 3);
        if (members.map(sequence).join() !== [grouped, grouped + 1, grouped + 2].join()) observations.push(`reader ${id}: group ${grouped} ${members.map(sequence)}`);
      }
    }
    return reads;
  };
  const reads = await Promise.all([writer, ...Array.from({ length: 4 }, (_, id) => reader(id))]);
  expect(observations).toEqual([]);
  expect(reads.slice(1).every(count => (count as number) > 0)).toBe(true);
  expect((await record.page({ limit: 200 })).entries.length).toBeGreaterThan(0);
  expect((await record.find(entry(total - 1).changeId))?.changeId).toBe(entry(total - 1).changeId);
});

it("shows only finished entries after a crash between the tail swap and its index publication, until recovery publishes them", async () => {
  const { record, directory } = await record_(10);
  await record.append([entry(0), entry(1)]);
  // A crash after the atomic tail swap but before index.json: the tail holds a
  // row the index never named. A partial temporary file is left beside it.
  const tail = join(directory, "000000.jsonl");
  const bytes = await readFile(tail, "utf8");
  await writeFile(tail, bytes + JSON.stringify(entry(2)) + "\n");
  await writeFile(`${tail}.4242.deadbeef.tmp`, bytes + JSON.stringify(entry(3)).slice(0, 20));
  expect((await record.page({ limit: 50 })).entries.map(sequence)).toEqual([1, 0]);
  expect(await record.find("change-00002")).toBeUndefined();
  expect(await record.entry("change-00002")).toBeUndefined();
  // Startup recovery is the only owner that publishes the unindexed row.
  await record.recover();
  expect((await record.page({ limit: 50 })).entries.map(sequence)).toEqual([2, 1, 0]);
  expect((await readdir(directory)).filter(name => name.endsWith(".tmp"))).toHaveLength(1);
});

it("still refuses an indexed segment that lost rows or a closed segment that changed", async () => {
  const { record, directory } = await record_(2);
  await record.append([entry(0), entry(1), entry(2)]);
  const closed = join(directory, "000000.jsonl");
  const original = await readFile(closed, "utf8");
  await writeFile(closed, original + JSON.stringify(entry(9)) + "\n");
  await expect(record.page({ cursor: "0:99", limit: 50 })).rejects.toMatchObject({ code: "conflict" });
  await writeFile(closed, original);
  const tail = join(directory, "000001.jsonl");
  await writeFile(tail, "");
  await expect(record.page({ limit: 50 })).rejects.toMatchObject({ code: "conflict" });
});

async function record_(segmentEntries: number) { return record(segmentEntries); }
