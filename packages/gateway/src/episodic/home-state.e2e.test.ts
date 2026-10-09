import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
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
const chapterCursor = { dev: 1, ino: 1, size: 1, completeBytes: 1, leafEntryId: "entry", leafLineDigest: "a".repeat(64), completePrefixDigest: "b".repeat(64) };
function state(chapters: number): EpisodicStoreState {
  return { version: EPISODIC_STORE_VERSION, generation: 0, spend: 0, blocked: null, cursor: {
    completeBytes: 1, leafEntryId: "entry", completePrefixDigest: "b".repeat(64),
    home: { version: 2, ledgerRevision: 1, chapters: Array.from({ length: chapters }, (_, index) => ({ ...chapterCursor, sessionId: `chapter-${index}`, mtimeMs: 1, ctimeMs: 1, sealed: true })) },
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

// FM3: the aggregate cursor is strict. A deleted field is refused, and each required
// field is refused when absent. The file is rewritten directly: saveState validates too.
it("refuses an aggregate cursor that carries a deleted field or omits a required one", async () => {
  await fixture(async (store, path) => {
    await store.saveState(state(1));
    const valid = await readFile(path, "utf8");
    const current = JSON.parse(valid) as { cursor: Record<string, unknown> };
    const { home: _home, ...withoutHome } = current.cursor;
    const { completePrefixDigest: _digest, ...withoutDigest } = current.cursor;
    const broken: Array<[string, Record<string, unknown>]> = [
      ["dev", { ...current.cursor, dev: 1 }],
      ["ino", { ...current.cursor, ino: 1 }],
      ["size", { ...current.cursor, size: 1 }],
      ["leafLineDigest", { ...current.cursor, leafLineDigest: "a".repeat(64) }],
      ["home absent", withoutHome],
      ["completePrefixDigest absent", withoutDigest],
    ];
    for (const [name, cursor] of broken) {
      await writeFile(path, JSON.stringify({ ...current, cursor }), { mode: 0o600 });
      await expect(store.readState(), name).rejects.toMatchObject({ kind: "invalid-store" });
    }
    await writeFile(path, valid, { mode: 0o600 });
    expect((await store.readState())?.cursor?.home.chapters).toHaveLength(1);
  });
});
