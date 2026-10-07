import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { EpisodicMemoryError, type EpisodicSummarizer } from "../episodic/episodic-contract.js";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { HomeMemory, homeMemoryIngestFailure } from "./home-memory.js";

/*
 * Home's memory owner without a running Gateway: the parts a session never
 * exercises. The lock that keeps #415's single-opener rule from being tripped by
 * a configuration racing an activation, and the failure vocabulary the Gateway
 * log depends on (a code, because an episodic failure's own message can carry the
 * canonical session path).
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

  it("codes an ingest failure, and treats a store a reconfiguration closed as no failure", () => {
    // The Gateway log records the reason, never the error: an episodic failure's
    // message names the canonical session path.
    expect(homeMemoryIngestFailure(new EpisodicMemoryError("source", "Canonical session /Users/someone/.tron/agent/sessions/x.jsonl cannot be read: ENOENT"))).toBe("source-unavailable");
    expect(homeMemoryIngestFailure(new EpisodicMemoryError("invalid-store", "Episodic memory state has an unknown version"))).toBe("store-refused");
    expect(homeMemoryIngestFailure(new EpisodicMemoryError("unsafe-store", "Episodic store file could not be inspected"))).toBe("store-refused");
    expect(homeMemoryIngestFailure(new EpisodicMemoryError("blocked", "Episodic memory is blocked"))).toBe("blocked");
    expect(homeMemoryIngestFailure(new EpisodicMemoryError("invalid-request", "entriesCommitted names a different session"))).toBe("invalid-request");
    expect(homeMemoryIngestFailure(new EpisodicMemoryError("already-open", "Episodic memory for session x is already open in this process"))).toBe("already-open");
    expect(homeMemoryIngestFailure(new Error("raw fs failure"))).toBe("unknown");
    // A reconfiguration closes the store in flight; that race is written nowhere.
    expect(homeMemoryIngestFailure(new EpisodicMemoryError("closed", "Episodic memory was disposed"))).toBeUndefined();
  });
});
