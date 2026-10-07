import { lstat, mkdir, mkdtemp, open as realOpen, readFile, readdir, rename as realRename, rm, rm as realRm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { EPISODIC_DEFAULTS, EPISODIC_STORE_VERSION, type EpisodicMessageRecord, type EpisodicSummarizer } from "./episodic-contract.js";
import { EpisodicMemory, readEpisodicState } from "./episodic-memory.js";
import { EpisodicStore } from "./episodic-store.js";

const roots: string[] = [];
const owners: TronWorkspace[] = [];
afterEach(async () => {
  await Promise.all(owners.splice(0).map(owner => owner.dispose()));
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })));
});

const summarize: EpisodicSummarizer = async request => fauxAssistantMessage(request.turns.at(-1)!.text.slice(-100));
const storeRecord = (sessionId: string): EpisodicMessageRecord => ({
  revision: 1, index: 0, entryId: "entry-0", kind: "user", text: "current", omitted: false, omissions: [],
  sourceDigest: "source", projectedDigest: "projection", sessionId,
});

async function fixture(label: string, content = "checkpoint review source") {
  const root = await mkdtemp(join(tmpdir(), `tron-episodic-review-${label}-`));
  roots.push(root);
  const cwd = join(root, "project");
  const sessions = join(root, "sessions");
  await Promise.all([mkdir(cwd, { recursive: true }), mkdir(sessions, { recursive: true })]);
  const manager = SessionManager.create(cwd, sessions);
  manager.appendMessage({ role: "user", content, timestamp: Date.now() });
  const workspace = new TronWorkspace(join(root, "home"));
  owners.push(workspace);
  return { root, manager, workspace, sessionFile: manager.getSessionFile()!, sessionId: manager.getSessionId(), home: join(root, "home") };
}

describe("episodic checkpoint review regressions", () => {
  it("preserves acknowledged live state after faults at every checkpoint step", async () => {
    const points = [
      "staging-write", "staging-file-sync", "staging-directory-sync", "checkpoint-directory-rename", "checkpoint-parent-sync",
      "pointer-write", "pointer-file-sync", "pointer-rename", "pointer-parent-sync",
      "catalog-log-write", "catalog-log-sync", "catalog-log-rename", "catalog-parent-sync",
      "nodes-log-write", "nodes-log-sync", "nodes-log-rename", "nodes-parent-sync", "old-checkpoint-removal",
    ];
    for (const point of points) {
      const fx = await fixture(`fault-${point}`);
      const state = { version: EPISODIC_STORE_VERSION, generation: 0, cursor: null, blocked: null, spend: 41 } as const;
      const record0 = storeRecord(fx.sessionId);
      const record1 = { ...record0, revision: 2, index: 1, entryId: "entry-1", text: "acknowledged tail" };
      const baseStore = new EpisodicStore(fx.workspace, fx.sessionId, EPISODIC_DEFAULTS.maxStoreLineBytes);
      await baseStore.appendCatalog(record0);
      await baseStore.saveState(state);
      await baseStore.checkpoint({ messages: [record0], nodes: [], state, watermark: 1 });
      await baseStore.appendCatalog(record1);
      const before = await baseStore.read();
      let checkpointDir: string | undefined;
      let pointerVisible = false;
      let catalogVisible = false;
      let nodesVisible = false;
      let injected = false;
      let logCount = 0;
      const logKinds = new Map<string, "catalog" | "nodes">();
      const fail = (candidate: string): void => {
        if (!injected && candidate === point) { injected = true; throw new Error(`fault at ${point}`); }
      };
      const fs = {
        mkdir: async (...args: Parameters<typeof mkdir>) => mkdir(...args),
        syncDurably: async (handle: { sync(): Promise<void> }) => handle.sync(),
        lstat: async (...args: Parameters<typeof lstat>) => lstat(...args),
        readdir: async (...args: Parameters<typeof readdir>) => readdir(...args),
        writeFile: async (path: string, data: unknown, ...args: unknown[]) => {
          if (path.includes(".checkpoint-staging/state.json")) fail("staging-write");
          return (writeFile as (...values: unknown[]) => Promise<void>)(path, data, ...args);
        },
        open: async (path: string, ...args: unknown[]) => {
          if (path.includes(".checkpoint-log-") && !logKinds.has(path)) {
            logKinds.set(path, logCount++ === 0 ? "catalog" : "nodes");
            fail(`${logKinds.get(path)}-log-write`);
          }
          const handle = await (realOpen as (...values: unknown[]) => Promise<any>)(path, ...args);
          return new Proxy(handle, {
            get(target, key) {
              if (key === "writeFile") return async (...values: unknown[]) => {
                if (typeof path === "string" && path.includes(".checkpoint-staging/catalog.jsonl")) fail("staging-write");
                if (typeof path === "string" && path.includes(".checkpoint-staging/nodes.jsonl")) fail("staging-write");
                if (typeof path === "string" && path.includes("checkpoint.current.json.") && path.endsWith(".tmp")) fail("pointer-write");
                if (logKinds.has(path)) fail(`${logKinds.get(path)}-log-write`);
                return target.writeFile(...values);
              };
              if (key === "sync") return async () => {
                if (typeof path === "string" && path.includes(".checkpoint-staging/catalog.jsonl")) fail("staging-file-sync");
                if (path.endsWith("/.checkpoint-staging")) fail("staging-directory-sync");
                if (typeof path === "string" && path.includes("checkpoint.current.json.") && path.endsWith(".tmp")) fail("pointer-file-sync");
                if (logKinds.has(path)) fail(`${logKinds.get(path)}-log-sync`);
                const storeRoot = checkpointDir?.slice(0, checkpointDir.lastIndexOf("/"));
                if (storeRoot && path === storeRoot) {
                  if (nodesVisible) fail("nodes-parent-sync");
                  else if (catalogVisible) fail("catalog-parent-sync");
                  else if (pointerVisible) fail("pointer-parent-sync");
                  else if (checkpointDir) fail("checkpoint-parent-sync");
                }
                return target.sync();
              };
              const value = Reflect.get(target, key, target);
              return typeof value === "function" ? value.bind(target) : value;
            },
          });
        },
        rename: async (source: string, destination: string) => {
          if (source.endsWith(".checkpoint-staging") && destination.includes("/checkpoint-")) {
            fail("checkpoint-directory-rename");
            checkpointDir = destination;
          }
          if (destination.endsWith("/checkpoint.current.json")) fail("pointer-rename");
          if (destination.endsWith("/catalog.jsonl")) { fail("catalog-log-rename"); catalogVisible = true; }
          if (destination.endsWith("/nodes.jsonl")) { fail("nodes-log-rename"); nodesVisible = true; }
          if (destination.endsWith("/checkpoint.current.json")) pointerVisible = true;
          return realRename(source, destination);
        },
        rm: async (path: string, ...args: unknown[]) => {
          const storeRoot = checkpointDir?.slice(0, checkpointDir.lastIndexOf("/"));
          if (storeRoot && path.startsWith(storeRoot + "/checkpoint-") && !path.startsWith(checkpointDir ?? "")) fail("old-checkpoint-removal");
          return (realRm as (...values: unknown[]) => Promise<void>)(path, ...args);
        },
      };
      const faultedStore = new EpisodicStore(fx.workspace, fx.sessionId, EPISODIC_DEFAULTS.maxStoreLineBytes, fs as never);
      let checkpointRejected = false;
      try { await faultedStore.checkpoint({ messages: before.messages.values(), nodes: before.nodes.values(), state: before.state!, watermark: before.highestRevision }); }
      catch { checkpointRejected = true; }
      expect(checkpointRejected, `${point} rejects checkpoint publication`).toBe(true);
      expect(injected, `${point} was actually injected`).toBe(true);
      const recovered = await new EpisodicStore(fx.workspace, fx.sessionId, EPISODIC_DEFAULTS.maxStoreLineBytes).read();
      expect([...recovered.messages.values()].map(record => record.entryId).sort()).toEqual(["entry-0", "entry-1"]);
      expect(recovered.state?.spend).toBe(41);
      expect(recovered.messages.size).toBe(2);
      const reopened = await EpisodicMemory.open({ workspace: fx.workspace, sessionId: fx.sessionId, sessionFile: fx.sessionFile, summarizer: summarize });
      expect(reopened.status().messages).toBe(2);
      expect(reopened.searchMessages("current", 0, 2).matches).toBe(1);
      expect(reopened.searchMessages("acknowledged tail", 0, 2).matches).toBe(1);
      await reopened.dispose();
    }
  }, 120_000);

  it("does not reclaim a live checkpoint staging directory during persisted-state reads", async () => {
    const fx = await fixture("readonly-cleanup");
    const state = { version: EPISODIC_STORE_VERSION, generation: 0, cursor: null, blocked: null, spend: 0 } as const;
    const store = new EpisodicStore(fx.workspace, fx.sessionId, EPISODIC_DEFAULTS.maxStoreLineBytes);
    const record = storeRecord(fx.sessionId);
    await store.appendCatalog(record);
    await store.saveState(state);
    await store.checkpoint({ messages: [record], nodes: [], state, watermark: 1 });
    const snapshot = await store.read();
    let enterWrite!: () => void;
    const writeEntered = new Promise<void>(resolve => { enterWrite = resolve; });
    let releaseWrite!: () => void;
    const writeGate = new Promise<void>(resolve => { releaseWrite = resolve; });
    const fileSystem = {
      mkdir, lstat, readdir, rename: realRename, rm: realRm, writeFile,
      syncDurably: async (handle: { sync(): Promise<void> }) => handle.sync(),
      open: async (path: string, ...args: unknown[]) => {
        const handle = await (realOpen as (...values: unknown[]) => Promise<any>)(path, ...args);
        if (!path.endsWith("/.checkpoint-staging/catalog.jsonl")) return handle;
        return new Proxy(handle, {
          get(target, key) {
            if (key === "writeFile") return async (...values: unknown[]) => {
              enterWrite();
              await writeGate;
              return target.writeFile(...values);
            };
            const value = Reflect.get(target, key, target);
            return typeof value === "function" ? value.bind(target) : value;
          },
        });
      },
    };
    const activeWriter = new EpisodicStore(fx.workspace, fx.sessionId, EPISODIC_DEFAULTS.maxStoreLineBytes, fileSystem as never);
    const checkpoint = activeWriter.checkpoint({ messages: snapshot.messages.values(), nodes: snapshot.nodes.values(), state: snapshot.state!, watermark: snapshot.highestRevision });
    await writeEntered;
    let names: string[] = [];
    try {
      await store.read();
      await readEpisodicState({ workspace: fx.workspace, sessionId: fx.sessionId });
      names = await readdir(join(fx.home, "workspace", "state", "episodic", fx.sessionId));
    } finally {
      releaseWrite();
      await checkpoint.catch(() => {});
    }
    expect(names).toContain(".checkpoint-staging");
  });

  it("refuses a cut after an earlier same-size source-prefix rewrite", async () => {
    const fx = await fixture("prefix-fence", "first prefix entry");
    fx.manager.appendMessage(fauxAssistantMessage("middle entry"));
    fx.manager.appendMessage({ role: "user", content: "last prefix entry", timestamp: Date.now() });
    const memory = await EpisodicMemory.open({ workspace: fx.workspace, sessionId: fx.sessionId, sessionFile: fx.sessionFile, summarizer: summarize });
    await memory.entriesCommitted(fx.sessionId);
    const target = fx.manager.getBranch().find(entry => entry.type === "message")!;
    const originalCut = await memory.cutAtEntry(target.id);
    expect(originalCut).toBe(1);
    const before = await stat(fx.sessionFile);
    const source = await readFile(fx.sessionFile, "utf8");
    const lines = source.split("\n");
    const index = lines.findIndex(line => {
      try { return (JSON.parse(line) as { id?: string }).id === target.id; } catch { return false; }
    });
    expect(index).toBeGreaterThan(0);
    const entry = JSON.parse(lines[index]!) as { timestamp: string };
    entry.timestamp = `${entry.timestamp.slice(0, -1)}${entry.timestamp.endsWith("0") ? "1" : "0"}`;
    lines[index] = JSON.stringify(entry);
    await writeFile(fx.sessionFile, lines.join("\n"));
    const after = await stat(fx.sessionFile);
    expect(after.ino).toBe(before.ino);
    expect(after.size).toBe(before.size);

    await expect(memory.cutAtEntry(target.id)).resolves.toBeUndefined();
    await memory.dispose();
  });

  it("skips live-record serialization when the superseded-byte threshold is impossible", async () => {
    const fx = await fixture("threshold-cost");
    const store = new EpisodicStore(fx.workspace, fx.sessionId, EPISODIC_DEFAULTS.maxStoreLineBytes);
    const record = storeRecord(fx.sessionId);
    const original = JSON.stringify;
    let serializedLiveRecord = false;
    JSON.stringify = ((value: unknown, ...args: Parameters<typeof JSON.stringify> extends [unknown, ...infer Rest] ? Rest : never[]) => {
      if (value === record) { serializedLiveRecord = true; throw new Error("serialized the whole live record"); }
      return original(value, ...(args as []));
    }) as typeof JSON.stringify;
    try {
      await expect(store.shouldCheckpoint([record], [])).resolves.toBe(false);
      expect(serializedLiveRecord).toBe(false);
    } finally { JSON.stringify = original; }
  });

  it("does not begin an automatic checkpoint after disposal starts during drain", async () => {
    const fx = await fixture("dispose-during-drain", "source that requires a summary " + "x".repeat(700));
    let enterSummary!: () => void;
    const summaryEntered = new Promise<void>(resolve => { enterSummary = resolve; });
    let releaseSummary!: () => void;
    const summaryGate = new Promise<void>(resolve => { releaseSummary = resolve; });
    const summarizer: EpisodicSummarizer = async request => {
      enterSummary();
      await summaryGate;
      return fauxAssistantMessage(request.turns.at(-1)!.text.slice(-100));
    };
    const memory = await EpisodicMemory.open({
      workspace: fx.workspace, sessionId: fx.sessionId, sessionFile: fx.sessionFile, summarizer,
      limits: { ...EPISODIC_DEFAULTS, retryMs: 1, nodeBytes: 512 }, sleep: async () => {},
    });
    const owner = memory as unknown as {
      store: { shouldCheckpoint: (...args: unknown[]) => Promise<boolean> };
      draining: Promise<void> | null;
      closed: boolean;
    };
    let thresholdChecks = 0;
    owner.store.shouldCheckpoint = async () => { thresholdChecks += 1; return false; };
    await memory.entriesIngested(fx.sessionId);
    await summaryEntered;
    const checksBeforeClose = thresholdChecks;
    const closing = memory.dispose();
    expect(owner.closed).toBe(true);
    releaseSummary();
    await closing;
    await owner.draining;
    await new Promise(resolve => setTimeout(resolve, 0));
    expect(thresholdChecks).toBe(checksBeforeClose);
  });
});
