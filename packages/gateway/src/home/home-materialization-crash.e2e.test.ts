import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";

const publication = vi.hoisted(() => ({ failAfterVisibleWrite: false }));
vi.mock("../util/durable-json.js", async importOriginal => {
  const actual = await importOriginal<typeof import("../util/durable-json.js")>();
  return {
    ...actual,
    durablePublishBoundedJson: async (...args: Parameters<typeof actual.durablePublishBoundedJson>) => {
      await actual.durablePublishBoundedJson(...args);
      if (publication.failAfterVisibleWrite) {
        publication.failAfterVisibleWrite = false;
        const error = new Error("injected directory synchronization failure") as Error & { publicationVisible?: true };
        error.publicationVisible = true;
        throw error;
      }
    },
  };
});

import { TrustService } from "../admin/trust-service.js";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { HomeOwner, type HomeSessionPort } from "./home-owner.js";

const roots: string[] = [];
const homeId = "materialization-crash-home";
const sessionId = "materialization-crash-session";
const attemptId = "materialization-crash-attempt";
const expectedPath = "/sessions/materialization-crash-session.jsonl";
const timestamp = "2026-10-07T00:00:00.000Z";

function record(state: "reserved" | "materializing" = "reserved", path?: string) {
  const chapter = {
    sessionId, ordinal: 2, state, createdAt: timestamp,
    ...(state === "materializing" ? { attemptId, ...(path ? { expectedPath: path } : {}) } : {}),
  };
  return {
    version: 2, homeId,
    chapters: [{ sessionId: "prior-session", ordinal: 1, state: "sealed", createdAt: timestamp, sealedAt: timestamp, sizeAtSeal: 1, entriesAtSeal: 1 }, chapter],
    bindingRevision: 1, generation: 2, policyRevision: 1, enabled: true,
    model: { provider: "faux", id: "chat" }, createdAt: timestamp, updatedAt: timestamp,
  };
}

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "tron-home-materialization-crash-"));
  roots.push(root);
  const tronHome = join(root, "tron");
  const directory = join(tronHome, "gateway", "home");
  await mkdir(directory, { recursive: true });
  const recordPath = join(directory, "home.json");
  await writeFile(recordPath, `${JSON.stringify(record(), null, 2)}\n`, { mode: 0o600 });
  let conversation = false;
  let dispatches = 0;
  const retired: boolean[] = [];
  const sessions: HomeSessionPort = {
    createHomeSession: async () => sessionId,
    applySessionModel: async () => {},
    sessionPresent: async () => true,
    sessionFile: async () => expectedPath,
    hasLiveRuntime: () => false,
    hasConversation: async (_id, path) => path === expectedPath && conversation,
    replaceRuntimeForProfile: async (_id, commit) => commit(),
    beginHomePublicationReconciliation: () => {},
    retireHomeRuntimes: async reloaded => { retired.push(reloaded); },
  };
  const makeOwner = async () => {
    const workspace = new TronWorkspace(join(root, "workspace"));
    const owner = new HomeOwner({ tronHome, trust: new TrustService(join(root, "agent")), workspace, sessions,
      memorySummarizer: () => ({ summarizer: async () => "summary" }) });
    await owner.initialize();
    return { owner, workspace };
  };
  return { root, tronHome, recordPath, sessions, makeOwner, get conversation() { return conversation; }, set conversation(value: boolean) { conversation = value; }, get dispatches() { return dispatches; }, dispatch() { dispatches += 1; }, retired };
}

afterEach(async () => {
  publication.failAfterVisibleWrite = false;
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })));
});

describe("Home materialization crash recovery", () => {
  it("recovers the durable reservation claim without replaying input", async () => {
    const f = await fixture();
    const old = await f.makeOwner();
    await old.owner.claimReservedChapter(sessionId, attemptId);
    // Abandon the old owner here: no graceful disposal or post-cut work runs.
    const fresh = await f.makeOwner();
    try {
      expect(fresh.owner.reservedChapter(sessionId)).toMatchObject({ state: "materializing", attemptId });
      expect(f.dispatches).toBe(0);
    } finally { await Promise.all([old.workspace.dispose(), fresh.workspace.dispose()]); }
  });

  it("recovers the recorded path after the path-record cut and does not choose another", async () => {
    const f = await fixture();
    const old = await f.makeOwner();
    await old.owner.claimReservedChapter(sessionId, attemptId);
    await old.owner.recordReservedChapterPath(sessionId, attemptId, expectedPath);
    const fresh = await f.makeOwner();
    try {
      expect(fresh.owner.reservedChapter(sessionId)).toMatchObject({ state: "materializing", attemptId, expectedPath });
      expect(f.dispatches).toBe(0);
    } finally { await Promise.all([old.workspace.dispose(), fresh.workspace.dispose()]); }
  });

  it("keeps a flushed conversation reserved until exact evidence publishes it", async () => {
    const f = await fixture();
    const old = await f.makeOwner();
    await old.owner.claimReservedChapter(sessionId, attemptId);
    await old.owner.recordReservedChapterPath(sessionId, attemptId, expectedPath);
    // Model the canonical conversation flush at the cut; the old owner is abandoned.
    f.conversation = true;
    const fresh = await f.makeOwner();
    try {
      expect(fresh.owner.reservedChapter(sessionId)).toMatchObject({ state: "materializing", attemptId, expectedPath });
      expect(await fresh.owner.publishObservedMaterialization(sessionId, attemptId, expectedPath)).toBe(true);
      expect(fresh.owner.reservedChapter(sessionId)).toBeUndefined();
      expect(JSON.parse(await readFile(f.recordPath, "utf8")).chapters.at(-1)).toMatchObject({ state: "active", sessionId });
      expect(f.dispatches).toBe(0);
    } finally { await Promise.all([old.workspace.dispose(), fresh.workspace.dispose()]); }
  });

  it("recovers publication after rename without inventing a path or replaying input", async () => {
    const f = await fixture();
    const old = await f.makeOwner();
    await old.owner.claimReservedChapter(sessionId, attemptId);
    await old.owner.recordReservedChapterPath(sessionId, attemptId, expectedPath);
    f.conversation = true;
    // A visible rename has the next durable state even if the old writer never
    // observed its directory fsync. Simulate abandonment at that exact cut.
    const published = record("materializing", expectedPath);
    published.chapters[1] = { sessionId, ordinal: 2, state: "active", createdAt: timestamp };
    published.bindingRevision = 2;
    await writeFile(f.recordPath, `${JSON.stringify(published, null, 2)}\n`, { mode: 0o600 });
    const fresh = await f.makeOwner();
    try {
      expect(fresh.owner.reservedChapter(sessionId)).toBeUndefined();
      expect(JSON.parse(await readFile(f.recordPath, "utf8")).chapters.at(-1)).toMatchObject({ state: "active", sessionId });
      expect(f.dispatches).toBe(0);
    } finally { await Promise.all([old.workspace.dispose(), fresh.workspace.dispose()]); }
  });

  it("fences publication uncertainty until retirement settles, then reloads the visible record", async () => {
    const f = await fixture();
    await rm(f.recordPath, { force: true });
    const old = await f.makeOwner();
    await old.owner.designate({ model: { provider: "faux", id: "chat" } }, () => ({ provider: "faux", id: "chat" }));
    let release!: () => void;
    let retirementStarted!: () => void;
    const blocked = new Promise<void>(resolve => { release = resolve; });
    const started = new Promise<void>(resolve => { retirementStarted = resolve; });
    f.sessions.retireHomeRuntimes = async reloaded => { retirementStarted(); await blocked; f.retired.push(reloaded); };
    publication.failAfterVisibleWrite = true;
    const disabling = old.owner.disable();
    try {
      await started;
      expect(() => old.owner.routeBinding()).toThrow(/unavailable/);
      expect(f.retired).toEqual([]);
      release();
      await expect(disabling).rejects.toThrow("injected directory synchronization failure");
      expect(f.retired).toEqual([true]);
      expect(JSON.parse(await readFile(f.recordPath, "utf8"))).toMatchObject({ enabled: false });
      expect(await old.owner.status()).toMatchObject({ available: true, enabled: false });
      expect(() => old.owner.routeBinding()).toThrow(/not enabled/);
    } finally {
      release();
      await old.workspace.dispose();
    }
  });
});
