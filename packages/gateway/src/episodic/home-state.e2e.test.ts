import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it } from "vitest";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { EpisodicStore } from "./episodic-store.js";
import { HOME_MAX_CHAPTERS } from "../home/home-chapter-state.js";
import { EPISODIC_STORE_VERSION, EPISODIC_STATE_MAX_BYTES, type EpisodicStoreState } from "./episodic-contract.js";

// A state with the ledger's full chapter count must write and read back.
const maxChapters = HOME_MAX_CHAPTERS;
const maxStateBytes = EPISODIC_STATE_MAX_BYTES;
function state(chapters: number): EpisodicStoreState {
  const cursor = { dev: 1, ino: 1, size: 1, completeBytes: 1, leafEntryId: "entry", leafLineDigest: "a".repeat(64), completePrefixDigest: "b".repeat(64) };
  return { version: EPISODIC_STORE_VERSION, generation: 0, spend: 0, blocked: null, cursor: {
    ...cursor, home: { version: 2, ledgerRevision: 1, chapters: Array.from({ length: chapters }, (_, index) => ({ ...cursor, sessionId: `chapter-${index}`, mtimeMs: 1, ctimeMs: 1, sealed: true })) },
  } };
}
async function fixture(run: (store: EpisodicStore, statePath: string) => Promise<void>) {
  const root = await mkdtemp(join(tmpdir(), "tron-home-state-")); const workspace = new TronWorkspace(join(root, "home"));
  try { await run(new EpisodicStore(workspace, "home", 1024 * 1024), join(root, "home/workspace/state/episodic/home/state.json")); }
  finally { await workspace.dispose(); await rm(root, { recursive: true, force: true }); }
}

it("round-trips Home state at the ledger's maximum chapter count", async () => {
  await fixture(async store => {
    await store.saveState(state(maxChapters));
    const read = await store.readState();
    expect(read?.cursor?.home?.chapters.length).toBe(maxChapters);
    expect(read?.cursor?.home?.chapters.at(-1)?.sessionId).toBe(`chapter-${maxChapters - 1}`);
  });
}, 60000);

it.each(["live", "checkpoint"])("refuses an oversized %s state before publication and preserves the prior readable state", async kind => {
  await fixture(async (store, path) => {
    await store.saveState(state(1)); const prior = await readFile(path);
    const oversized = state(1); oversized.blocked = { reason: "permanent-failure", detail: "x".repeat(maxStateBytes + 1) };
    const publish = kind === "live" ? store.saveState(oversized)
      : store.checkpoint({ state: oversized, messages: [], nodes: [], watermark: 0 });
    await expect(publish).rejects.toThrow(/state exceeds/);
    expect(await readFile(path)).toEqual(prior);
    expect((await store.readState())?.cursor?.home?.chapters.length).toBe(1);
  });
}, 60000);

it("keeps small ordinary episodic states readable", async () => {
  await fixture(async store => {
    const small: EpisodicStoreState = { version: EPISODIC_STORE_VERSION, generation: 0, cursor: null, spend: 3, blocked: null };
    await store.saveState(small); expect(await store.readState()).toEqual(small);
  });
});
