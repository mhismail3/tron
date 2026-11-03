import { mkdtemp, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it } from "vitest";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { EpisodicStore } from "./episodic-store.js";
import { EPISODIC_STORE_VERSION, type EpisodicMessageRecord, type EpisodicStoreState } from "./episodic-contract.js";

const state: EpisodicStoreState = { version: EPISODIC_STORE_VERSION, generation: 0, spend: 0, blocked: null, cursor: null };
function message(index: number, text: string): EpisodicMessageRecord {
  return { index, revision: index + 1, entryId: `entry-${index}`, sessionId: "home", kind: "user", text, omitted: false, omissions: [],
    timestamp: new Date(0).toISOString(), sourceDigest: "a".repeat(64), projectedDigest: "b".repeat(64) };
}
const lineBytes = (record: unknown) => Buffer.byteLength(`${JSON.stringify(record)}\n`);

// A checkpoint rewrites the whole live catalog. A large Home memory (Stable: 15k
// messages, 68 MB) must not be rewritten after every few appended records, or each
// small append costs a full rewrite while the memory's mutex holds every tool read.
it("checkpoints a large memory only once its append logs outgrow the live catalog", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-episodic-amortized-"));
  const workspace = new TronWorkspace(join(root, "home"));
  try {
    const store = new EpisodicStore(workspace, "home", 1024 * 1024);
    await store.saveState(state);
    const live = Array.from({ length: 400 }, (_, index) => message(index, "x".repeat(2_000)));
    const liveBytes = live.reduce((total, record) => total + lineBytes(record), 0);
    await store.checkpoint({ messages: live, nodes: [], state, watermark: live.length });

    let appended = 0;
    let index = live.length;
    while (appended < 64 * 1024) {
      const record = message(index, "y".repeat(2_000));
      await store.appendCatalog({ ...record, revision: index + 1 });
      appended += lineBytes(record);
      index += 1;
    }
    expect(liveBytes).toBeGreaterThan(appended * 8);
    expect(await store.shouldCheckpoint(liveBytes)).toBe(false);

    while (appended <= liveBytes) {
      const record = message(index, "z".repeat(2_000));
      await store.appendCatalog({ ...record, revision: index + 1 });
      appended += lineBytes(record);
      index += 1;
    }
    expect(await store.shouldCheckpoint(liveBytes)).toBe(true);

    // The batched checkpoint writer still publishes every record readably.
    await store.checkpoint({ messages: live, nodes: [], state, watermark: index });
    const read = await store.read();
    expect(read.present && read.messages.size).toBe(live.length);
    const entries = await readdir(join(root, "home/workspace/state/episodic/home"));
    expect(entries.filter(name => name.startsWith("checkpoint-"))).toHaveLength(1);
  } finally {
    await workspace.dispose();
    await rm(root, { recursive: true, force: true });
  }
}, 60_000);
