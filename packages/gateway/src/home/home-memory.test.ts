import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import type { EpisodicSessionSource, EpisodicSummarizer } from "../episodic/episodic-contract.js";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { HomeMemory } from "./home-memory.js";

/*
 * Home's memory owner without a running Gateway: the parts a session never
 * exercises. The lock that keeps #415's single-opener rule from being tripped by
 * a configuration racing an activation.
 */

const roots: string[] = [];
const owners: TronWorkspace[] = [];
afterEach(async () => {
  await Promise.all(owners.splice(0).map((owner) => owner.dispose()));
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

const summarizer: EpisodicSummarizer = async () => {
  throw new Error("this fixture never compacts");
};
/** These fixtures never open a store, so no chapter is read. */
const unreadSource: EpisodicSessionSource = {
  read: async function* () { throw new Error("this fixture never reads a chapter"); },
  branchAtCursor: async function* () { throw new Error("this fixture never reads a chapter"); },
};

/** A memory whose session file cannot be resolved, so `configure` records the
 * configuration and holds an open only when the test lets it. */
async function memory(sessionFile: () => Promise<string | undefined>): Promise<HomeMemory> {
  const root = await mkdtemp(join(tmpdir(), "tron-home-memory-"));
  roots.push(root);
  const workspace = new TronWorkspace(join(root, "tron"));
  owners.push(workspace);
  await mkdir(join(root, "sessions"), { recursive: true });
  return new HomeMemory({
    sessionId: "session-1",
    workspace,
    sessionFile,
    sessionSource: unreadSource,
    modelSummarizer: () => ({ summarizer }),
  });
}

describe("HomeMemory", () => {
  it("serializes its opens, so two configurations can never open one store", async () => {
    // #415's store allows one opener per process. An un-serialized
    // `configureMemory` racing an activation's first step could therefore open the
    // same store twice (`already-open`), or close a store the other is reading.
    // The observation point is the session-file lookup every open starts with:
    // while the first configuration is inside it, the second must not have
    // reached it.
    const lookups: number[] = [];
    let release!: () => void;
    const held = new Promise<void>((resolve) => { release = resolve; });
    const instance = await memory(async () => {
      lookups.push(performance.now());
      if (lookups.length === 1) await held;
      return undefined;
    });
    // Two different models: the second configuration must reopen the store.
    const first = instance.configure({ model: { provider: "p", id: "m" } });
    const second = instance.configure({ model: { provider: "p", id: "m2" } });
    // The first configuration is inside the open; the second has not started.
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(lookups.length).toBe(1);
    release();
    await Promise.all([first, second]);
    expect(lookups.length).toBe(2);
    await instance.dispose();
  });
});
