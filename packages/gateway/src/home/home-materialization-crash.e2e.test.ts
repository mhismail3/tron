import { mkdir, mkdtemp, open, readFile, readdir, realpath, rename, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { afterAll, afterEach, describe, expect, it, vi } from "vitest";
import { ModelRuntime, SessionManager } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider } from "@earendil-works/pi-ai";
import { awaitsWithin, waitFor } from "../../test-support/wait-for.js";

const publication = vi.hoisted(() => ({
  failAfterVisibleWrite: false,
  intercept: undefined as undefined | ((path: string, document: unknown, publish: () => Promise<void>) => Promise<void>),
}));
vi.mock("../util/durable-json.js", async importOriginal => {
  const actual = await importOriginal<typeof import("../util/durable-json.js")>();
  return {
    ...actual,
    durablePublishBoundedJson: async (...args: Parameters<typeof actual.durablePublishBoundedJson>) => {
      const publish = () => actual.durablePublishBoundedJson(...args);
      if (publication.intercept) return publication.intercept(args[0], args[1], publish);
      await publish();
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
import { RuntimeRegistry, type RuntimeLifecycleRecord } from "../sessions/runtime-registry.js";
import { durableAtomicWriteJson } from "../util/durable-json.js";

const roots: string[] = [];
const report: Array<{ cut: string; recovered: string; replayed: false }> = [];
const sessionId = "f31edbb7-f55b-4145-8017-2280890ef99c";
const attemptId = "materialization-crash-attempt";
const timestamp = "2026-10-07T00:00:00.000Z";
const model = { provider: "faux", id: "chat" };

function barrier() {
  let reached!: () => void;
  let reject!: (error: Error) => void;
  const started = new Promise<void>(resolve => { reached = resolve; });
  const held = new Promise<never>((_resolve, rejectPromise) => { reject = rejectPromise; });
  void held.catch(() => {});
  return { started, hold: () => { reached(); return held; }, release: () => reject(new Error("old owner abandoned at crash cut")) };
}

async function makeRegistry(root: string, lifecycle: RuntimeLifecycleRecord[] = []) {
  const packaged = fauxProvider({ provider: model.provider, models: [{ id: model.id, reasoning: false }] });
  packaged.setResponses([fauxAssistantMessage("canonical Home response")]);
  const agentDir = join(root, "agent");
  const registry = new RuntimeRegistry({
    agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000,
    modelRuntimeFactory: async () => {
      const runtime = await ModelRuntime.create({ authPath: join(root, "auth.json"), modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(packaged.provider);
      return runtime;
    },
    trust: new TrustService(agentDir), broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    runtimeLifecycleRecord: record => lifecycle.push(record),
    homeMemorySummarizer: () => ({ summarizer: async () => fauxAssistantMessage("summary") }),
  });
  try {
    await registry.initialize();
    // Initialization starts the catalog; cold acquisition requires its first
    // complete cut, as it does at Gateway startup before listener readiness.
    await waitFor(async () => {
      try { await registry.list(); return true; }
      catch (error) {
        if (error instanceof Error && /catalog has not been read yet/.test(error.message)) return false;
        throw error;
      }
    }, "initial catalog cut", { boundMs: 5_000, intervalMs: 25 });
  } catch (error) {
    await registry.dispose();
    throw error;
  }
  return { registry, get dispatches() { return packaged.state.callCount; } };
}

async function fixture() {
  const root = await realpath(await mkdtemp(join(tmpdir(), "tron-home-materialization-crash-")));
  roots.push(root);
  const tronHome = join(root, "tron");
  const directory = join(tronHome, "gateway", "home");
  const cwd = join(directory, "workspace");
  await mkdir(cwd, { recursive: true });
  await mkdir(join(root, "agent"), { recursive: true });
  // Use the same cwd-derived canonical directory as Registry, including realpath
  // normalization on hosts where the system temporary directory is a symlink.
  const trust = new TrustService(join(root, "agent"));
  const canonicalCwd = await trust.canonicalDirectory(cwd);
  const sessionDirectory = join(root, "agent", "sessions", `--${resolve(canonicalCwd).replace(/^[/\\]/, "").replace(/[/\\:]/g, "-")}--`);
  await mkdir(sessionDirectory, { recursive: true });
  const recordPath = join(directory, "home.json");
  await writeFile(recordPath, `${JSON.stringify({
    version: 2, homeId: "materialization-crash-home",
    chapters: [
      { sessionId: "prior-session", ordinal: 1, state: "sealed", createdAt: timestamp, sealedAt: timestamp, sizeAtSeal: 1, entriesAtSeal: 1 },
      { sessionId, ordinal: 2, state: "reserved", createdAt: timestamp },
    ],
    bindingRevision: 1, generation: 2, policyRevision: 1, enabled: true, model, createdAt: timestamp, updatedAt: timestamp,
  }, null, 2)}\n`, { mode: 0o600 });
  const manager = SessionManager.create(canonicalCwd, sessionDirectory);
  const expectedPath = manager.newSession({ id: sessionId })!;
  const workspace = new TronWorkspace(join(root, "workspace"));
  const sessions: HomeSessionPort = {
    createHomeSession: async () => sessionId,
    applySessionModel: async () => {},
    sessionPresent: async () => true,
    sessionFile: async () => expectedPath,
    hasLiveRuntime: () => false,
    hasConversation: async () => manager.getEntries().some(entry => entry.type === "message"),
    replaceRuntimeForProfile: async (_id, commit) => commit(),
    beginHomePublicationReconciliation: () => {},
    retireHomeRuntimes: async () => {},
  };
  const owner = new HomeOwner({ tronHome, trust, workspace, sessions, memorySummarizer: () => ({ summarizer: async () => "summary" }) });
  await owner.initialize();
  const flushConversation = () => {
    manager.appendThinkingLevelChange("off");
    manager.appendMessage({ role: "user", content: "input already flushed before crash", timestamp: Date.parse(timestamp) });
    manager.appendMessage(fauxAssistantMessage("canonical flushed response"));
  };
  return { root, recordPath, owner, workspace, expectedPath, sessionDirectory, flushConversation };
}

/** Freeze the *actual writer*, not a free-standing promise. The old owner never
 * reaches acknowledgement or disposal before the fresh Registry reads disk. */
function freezeWrite(recordPath: string, cut: "after-write" | "before-write" | "after-rename") {
  const frozen = barrier();
  publication.intercept = async (path, document, publish) => {
    if (path !== recordPath) return publish();
    publication.intercept = undefined;
    if (cut === "after-rename") {
      await durableAtomicWriteJson(path, document, 0o600, {
        mkdir, rename, rm,
        open: async (...args: Parameters<typeof open>) => {
          if (args[0] === dirname(path)) await frozen.hold();
          return open(...args);
        },
      });
    } else {
      if (cut === "after-write") await publish();
      await frozen.hold();
    }
  };
  return frozen;
}

async function ledger(path: string) { return JSON.parse(await readFile(path, "utf8")); }

async function noReplay(f: Awaited<ReturnType<typeof fixture>>, dispatches: number, messages: number) {
  expect(dispatches).toBe(0);
  const paths = (await readdir(f.sessionDirectory)).filter(path => path.endsWith(".jsonl"));
  expect(paths).toHaveLength(messages ? 1 : 0);
  if (messages) {
    expect(join(f.sessionDirectory, paths[0]!)).toBe(f.expectedPath);
    const entries = (await readFile(f.expectedPath, "utf8")).trim().split("\n").map(line => JSON.parse(line));
    expect(entries.filter(entry => entry.type === "message" && entry.message.role === "user")).toHaveLength(1);
  }
}

afterEach(async () => {
  publication.failAfterVisibleWrite = false;
  publication.intercept = undefined;
  vi.restoreAllMocks();
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })));
});
afterAll(async () => {
  const path = process.env.HOME_MATERIALIZATION_CRASH_REPORT;
  if (path) {
    await mkdir(dirname(path), { recursive: true });
    await writeFile(path, `${JSON.stringify({ cases: report }, null, 2)}\n`);
  }
});

describe("Home materialization crash recovery", () => {
  it("recovers the durable reservation claim without replaying input", async () => {
    const f = await fixture();
    const frozen = freezeWrite(f.recordPath, "after-write");
    const oldOperation = f.owner.claimReservedChapter(sessionId, attemptId);
    void oldOperation.catch(() => {});
    let fresh: Awaited<ReturnType<typeof makeRegistry>> | undefined;
    try {
      await awaitsWithin(frozen.started, "claim durably written");
      fresh = await makeRegistry(f.root);
      expect(fresh.registry.homeOwner().reservedChapter(sessionId)).toMatchObject({ state: "materializing", attemptId });
      expect((await ledger(f.recordPath)).chapters.at(-1).expectedPath).toBeUndefined();
      await noReplay(f, fresh.dispatches, 0);
      report.push({ cut: "claim", recovered: "materializing", replayed: false });
    } finally {
      frozen.release();
      try { await expect(oldOperation).rejects.toThrow("old owner abandoned"); }
      finally {
        await fresh?.registry.dispose();
        await f.workspace.dispose();
      }
    }
  });

  it("preserves and blocks the recorded absent path instead of choosing another", async () => {
    const f = await fixture();
    await f.owner.claimReservedChapter(sessionId, attemptId);
    const frozen = freezeWrite(f.recordPath, "after-write");
    const oldOperation = f.owner.recordReservedChapterPath(sessionId, attemptId, f.expectedPath);
    void oldOperation.catch(() => {});
    let fresh: Awaited<ReturnType<typeof makeRegistry>> | undefined;
    try {
      await awaitsWithin(frozen.started, "path durably recorded before flush");
      fresh = await makeRegistry(f.root);
      expect(fresh.registry.homeOwner().reservedChapter(sessionId)).toMatchObject({ state: "materializing", expectedPath: f.expectedPath });
      const recovery = await fresh.registry.materializeReservedHome(sessionId).then(
        slot => ({ blocked: false, reusedPath: slot.sessionFile === f.expectedPath }),
        error => ({ blocked: true, reason: error instanceof Error ? error.message : String(error) }),
      );
      expect(recovery).toMatchObject({ blocked: true, reason: "Home recovery is blocked because its recorded chapter path is absent" });
      expect((await ledger(f.recordPath)).chapters.at(-1)).toMatchObject({ state: "materializing", expectedPath: f.expectedPath });
      await noReplay(f, fresh.dispatches, 0);
      report.push({ cut: "path", recovered: "materializing-blocked", replayed: false });
    } finally {
      frozen.release();
      try { await expect(oldOperation).rejects.toThrow("old owner abandoned"); }
      finally {
        await fresh?.registry.dispose();
        await f.workspace.dispose();
      }
    }
  });

  it("adopts the first canonical conversation flush before publication without replay", async () => {
    const f = await fixture();
    await f.owner.claimReservedChapter(sessionId, attemptId);
    await f.owner.recordReservedChapterPath(sessionId, attemptId, f.expectedPath);
    f.flushConversation();
    const before = await readFile(f.expectedPath);
    const frozen = freezeWrite(f.recordPath, "before-write");
    const oldOperation = f.owner.publishObservedMaterialization(sessionId, attemptId, f.expectedPath);
    void oldOperation.catch(() => {});
    let fresh: Awaited<ReturnType<typeof makeRegistry>> | undefined;
    try {
      await awaitsWithin(frozen.started, "conversation flushed before publication");
      fresh = await makeRegistry(f.root);
      expect(fresh.registry.homeOwner().reservedChapter(sessionId)).toMatchObject({ state: "materializing", expectedPath: f.expectedPath });
      const rebuilt = await fresh.registry.materializeReservedHome(sessionId);
      expect(rebuilt.sessionFile).toBe(f.expectedPath);
      expect(fresh.registry.homeOwner().reservedChapter(sessionId)).toBeUndefined();
      expect((await ledger(f.recordPath)).chapters.at(-1)).toMatchObject({ state: "active", sessionId });
      expect(await readFile(f.expectedPath)).toEqual(before);
      await noReplay(f, fresh.dispatches, 1);
      report.push({ cut: "conversation-flush", recovered: "active-exact-path", replayed: false });
    } finally {
      frozen.release();
      try { await expect(oldOperation).rejects.toThrow("old owner abandoned"); }
      finally {
        await fresh?.registry.dispose();
        await f.workspace.dispose();
      }
    }
  });

  it("recovers publication after rename before directory fsync without replay", async () => {
    const f = await fixture();
    await f.owner.claimReservedChapter(sessionId, attemptId);
    await f.owner.recordReservedChapterPath(sessionId, attemptId, f.expectedPath);
    f.flushConversation();
    const frozen = freezeWrite(f.recordPath, "after-rename");
    const oldOperation = f.owner.publishObservedMaterialization(sessionId, attemptId, f.expectedPath);
    void oldOperation.catch(() => {});
    let fresh: Awaited<ReturnType<typeof makeRegistry>> | undefined;
    try {
      await awaitsWithin(frozen.started, "publication renamed before directory fsync");
      fresh = await makeRegistry(f.root);
      expect(fresh.registry.homeOwner().reservedChapter(sessionId)).toBeUndefined();
      expect((await ledger(f.recordPath)).chapters.at(-1)).toMatchObject({ state: "active", sessionId });
      const rebuilt = await fresh.registry.acquire(sessionId);
      expect(rebuilt.sessionFile).toBe(f.expectedPath);
      await noReplay(f, fresh.dispatches, 1);
      report.push({ cut: "publication-rename", recovered: "active-exact-path", replayed: false });
    } finally {
      frozen.release();
      try { await expect(oldOperation).rejects.toThrow("old owner abandoned"); }
      finally {
        await fresh?.registry.dispose();
        await f.workspace.dispose();
      }
    }
  });

  it("fences and retires a live Registry slot, then rebuilds from the reloaded ledger", async () => {
    const root = await realpath(await mkdtemp(join(tmpdir(), "tron-home-registry-publication-")));
    roots.push(root);
    await mkdir(join(root, "agent"), { recursive: true });
    const lifecycle: RuntimeLifecycleRecord[] = [];
    const liveRegistry = await makeRegistry(root, lifecycle);
    const { registry } = liveRegistry;
    let release!: () => void;
    const held = new Promise<void>(resolve => { release = resolve; });
    try {
      const designation = await registry.homeOwner().designate({ model }, () => model);
      await registry.homeOwner().configureMemory({ model });
      const live = await registry.acquire(designation.sessionId);
      await live.prompt("persist one canonical Home response");
      await waitFor(() => !live.isBusy, "canonical prompt settled", { boundMs: 5_000, intervalMs: 25 });
      expect(liveRegistry.dispatches).toBe(1);
      const retire = live.retireAfterSettled.bind(live);
      vi.spyOn(live, "retireAfterSettled").mockImplementation(async () => { await held; await retire(); });
      publication.failAfterVisibleWrite = true;
      await expect(awaitsWithin(registry.homeOwner().disable(), "disable settles without awaiting retirement", 5_000)).rejects.toThrow("injected directory synchronization failure");
      expect(await registry.homeOwner().status()).toMatchObject({ available: false, reason: "Home ledger publication is being reconciled" });
      expect(() => registry.homeOwner().routeBinding()).toThrow(/unavailable/);
      await expect(registry.acquire(designation.sessionId)).rejects.toThrow(/rebuilding/);
      expect(registry.retainLiveSession(designation.sessionId)).toBeUndefined();
      expect(lifecycle.filter(record => record.reason === "publication-uncertain")).toEqual([]);
      release();
      await waitFor(async () => {
        const status = await registry.homeOwner().status();
        return status.available ? status : undefined;
      }, "Home reloaded and all stale slots retired", { boundMs: 5_000, intervalMs: 25 });
      expect(await registry.homeOwner().status()).toMatchObject({ available: true, enabled: false });
      const rebuilt = await registry.acquire(designation.sessionId);
      // Compare identity as a scalar: failure reporting must not traverse an
      // obsolete slot's retired extension-host getters.
      expect(rebuilt !== live).toBe(true);
      expect(live.isDisposed).toBe(true);
      expect(lifecycle.filter(record => record.reason === "publication-uncertain")).toMatchObject([{ event: "runtime.evicted", sessionId: designation.sessionId }]);
      expect(rebuilt.sessionFile).toBe(live.sessionFile);
      expect((rebuilt as unknown as { liveProfile(): string }).liveProfile()).toBe("ordinary");
      expect(liveRegistry.dispatches).toBe(1);
      report.push({ cut: "live-post-rename-error", recovered: "disabled-fresh-ordinary-slot", replayed: false });
    } finally {
      release();
      await registry.dispose();
    }
  });
});
