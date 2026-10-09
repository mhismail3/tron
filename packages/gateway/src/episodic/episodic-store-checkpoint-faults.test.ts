import { existsSync } from "node:fs";
import { lstat, mkdir, mkdtemp, open as realOpen, readFile, readdir, realpath, rename as realRename, rm, rm as realRm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { EPISODIC_DEFAULTS, EPISODIC_STORE_VERSION, type EpisodicMessageRecord, type EpisodicSummarizer } from "./episodic-contract.js";
import { EpisodicMemory, readEpisodicState } from "./episodic-memory.js";
import { EpisodicStore } from "./episodic-store.js";

import { singleChapterSource } from "../../test-support/episodic-chapter-source.js";
const roots: string[] = [];
const owners: TronWorkspace[] = [];
afterEach(async () => {
  await Promise.all(owners.splice(0).map(owner => owner.dispose()));
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })));
});

const summarize: EpisodicSummarizer = async request => fauxAssistantMessage(request.turns.at(-1)!.text.slice(-100));
const storeRecord = (sessionId: string): EpisodicMessageRecord => ({
  revision: 1, index: 0, entryId: "entry-0", kind: "user", text: "current", omitted: false, omissions: [],
  sourceDigest: "source", projectedDigest: "projection", timestamp: "2026-01-01T00:00:00.000Z", sessionId,
});

async function replaceCanonicalContent(fx: Awaited<ReturnType<typeof fixture>>, entryId: string, oldText: string, newText: string): Promise<void> {
  const source = await readFile(fx.sessionFile, "utf8");
  const lines = source.split("\n");
  const index = lines.findIndex(line => {
    try { return (JSON.parse(line) as { id?: string }).id === entryId; } catch { return false; }
  });
  if (index < 0) throw new Error(`Canonical entry ${entryId} is absent`);
  const entry = JSON.parse(lines[index]!) as unknown;
  let replacements = 0;
  const visit = (value: unknown): unknown => {
    if (value === oldText) { replacements += 1; return newText; }
    if (Array.isArray(value)) return value.map(visit);
    if (value && typeof value === "object") return Object.fromEntries(Object.entries(value).map(([key, child]) => [key, visit(child)]));
    return value;
  };
  const updated = JSON.stringify(visit(entry));
  if (replacements !== 1 || Buffer.byteLength(updated) !== Buffer.byteLength(lines[index]!)) throw new Error("Replacement must change one string without changing its byte length");
  lines[index] = updated;
  const replacement = join(fx.root, "same-size-source-replacement.jsonl");
  await writeFile(replacement, lines.join("\n"));
  await realRename(replacement, fx.sessionFile);
}

async function fixture(label: string, content = "checkpoint review source") {
  const root = await mkdtemp(join(tmpdir(), `tron-episodic-faults-${label}-`));
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

describe("episodic store checkpoint faults and reconciliation", () => {
  it("preserves built nodes and ordered state transitions across checkpoint faults", async () => {
    const points = [
      "staging-catalog-write", "staging-catalog-sync", "staging-node-write", "staging-node-sync", "staging-state-write", "staging-state-sync",
      "staging-directory-sync", "checkpoint-directory-rename", "checkpoint-parent-sync",
      "pointer-write", "pointer-file-sync", "pointer-rename", "pointer-parent-sync",
      "catalog-log-create", "catalog-log-sync", "catalog-log-rename", "catalog-parent-sync",
      "nodes-log-create", "nodes-log-sync", "nodes-log-rename", "nodes-parent-sync", "old-checkpoint-removal",
    ];
    for (const point of points) {
      const fx = await fixture(`fault-${point}`, `node zero ${"x".repeat(900)}`);
      for (let index = 1; index < 8; index += 1) {
        fx.manager.appendMessage({ role: "user", content: `fault prompt ${index} ${"u".repeat(900)}`, timestamp: Date.now() });
        fx.manager.appendMessage(fauxAssistantMessage(`fault reply ${index} ${"a".repeat(900)}`));
      }
      const memory = await EpisodicMemory.open({
        workspace: fx.workspace, sessionId: fx.sessionId, sessionSource: singleChapterSource(fx.sessionId, fx.sessionFile), summarizer: summarize,
        limits: { nodeBytes: 512, viewBytes: 512, jobs: 4, retryMs: 0 },
      });
      await memory.entriesCommitted(fx.sessionId);
      await memory.whenReady(memory.status().messages);
      const initialStatus = memory.status();
      expect(initialStatus.nodes.byLevel.filter(level => level.count > 0).length).toBeGreaterThan(1);
      await memory.dispose();

      const baseStore = new EpisodicStore(fx.workspace, fx.sessionId, EPISODIC_DEFAULTS.maxStoreLineBytes);
      const before = await baseStore.read();
      const baseState = before.state!;
      const stateA = { ...baseState, spend: 41, blocked: null };
      await baseStore.saveState(stateA);
      await baseStore.checkpoint({ messages: before.messages.values(), nodes: before.nodes.values(), state: stateA, watermark: before.highestRevision });
      const tailRecord: EpisodicMessageRecord = {
        revision: before.highestRevision + 1, index: before.messages.size, entryId: "fault-tail", kind: "user",
        text: "acknowledged tail", omitted: false, omissions: [], sourceDigest: "tail-source", projectedDigest: "tail-projection", timestamp: "2026-01-01T00:00:00.000Z", sessionId: fx.sessionId,
      };
      await baseStore.appendCatalog(tailRecord);
      const stateB = {
        ...stateA,
        spend: 53,
        generation: Math.max(stateA.generation, before.highestGeneration) + 1,
        cursor: stateA.cursor ? { ...stateA.cursor, size: stateA.cursor.size + 1 } : null,
        blocked: { reason: "source-unavailable", detail: "checkpoint tail transition" },
      };
      await baseStore.saveState(stateB);
      const postWatermark = await baseStore.read();
      const expectedNodes = [...before.nodes.entries()].sort(([left], [right]) => left.localeCompare(right));
      expect([...before.nodes.values()].some(node => node.level > 0)).toBe(true);

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
          if (path.includes(".checkpoint-staging/state.json")) fail("staging-state-write");
          return (writeFile as (...values: unknown[]) => Promise<void>)(path, data, ...args);
        },
        open: async (path: string, ...args: unknown[]) => {
          if (path.includes(".checkpoint-staging/catalog.jsonl")) fail("staging-catalog-write");
          if (path.includes(".checkpoint-staging/nodes.jsonl")) fail("staging-node-write");
          if (path.includes(".checkpoint-log-") && !logKinds.has(path)) {
            logKinds.set(path, logCount++ === 0 ? "catalog" : "nodes");
            fail(`${logKinds.get(path)}-log-create`);
          }
          const handle = await (realOpen as (...values: unknown[]) => Promise<any>)(path, ...args);
          return new Proxy(handle, {
            get(target, key) {
              if (key === "writeFile") return async (...values: unknown[]) => {
                if (path.includes("checkpoint.current.json.") && path.endsWith(".tmp")) fail("pointer-write");
                if (logKinds.has(path)) fail(`${logKinds.get(path)}-log-create`);
                return target.writeFile(...values);
              };
              if (key === "sync") return async () => {
                if (path.includes(".checkpoint-staging/catalog.jsonl")) fail("staging-catalog-sync");
                if (path.includes(".checkpoint-staging/nodes.jsonl")) fail("staging-node-sync");
                if (path.includes(".checkpoint-staging/state.json")) fail("staging-state-sync");
                if (path.endsWith("/.checkpoint-staging")) fail("staging-directory-sync");
                if (path.includes("checkpoint.current.json.") && path.endsWith(".tmp")) fail("pointer-file-sync");
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
      try { await faultedStore.checkpoint({ messages: postWatermark.messages.values(), nodes: postWatermark.nodes.values(), state: stateB, watermark: postWatermark.highestRevision }); }
      catch { checkpointRejected = true; }
      expect(checkpointRejected, `${point} rejects checkpoint publication`).toBe(true);
      expect(injected, `${point} was actually injected`).toBe(true);
      const stateC = {
        ...stateB,
        spend: 61,
        generation: stateB.generation + 1,
        cursor: stateB.cursor ? { ...stateB.cursor, size: stateB.cursor.size + 1 } : null,
        blocked: null,
      };
      const expectedState = pointerVisible ? stateC : stateB;
      if (pointerVisible) await baseStore.saveState(stateC);

      const expectedMessages = new Map(before.messages);
      expectedMessages.set(tailRecord.index, tailRecord);
      const verifyStore = async (): Promise<void> => {
        const recovered = await baseStore.read();
        expect([...recovered.messages.entries()]).toEqual([...expectedMessages.entries()]);
        expect([...recovered.nodes.entries()].sort(([left], [right]) => left.localeCompare(right))).toEqual(expectedNodes);
        expect(recovered.state).toEqual(expectedState);
      };
      await verifyStore();
      for (let opener = 0; opener < 2; opener += 1) {
        const reopened = await EpisodicMemory.open({
          workspace: fx.workspace, sessionId: fx.sessionId, sessionSource: singleChapterSource(fx.sessionId, fx.sessionFile), summarizer: summarize,
          limits: { nodeBytes: 512, viewBytes: 512, jobs: 4, retryMs: 0 },
        });
        const status = reopened.status();
        expect(status.messages).toBe(expectedMessages.size);
        expect(status.nodes.total).toBe(expectedNodes.length);
        expect(status.generation).toBe(expectedState.generation);
        expect(status.tokens.used).toBe(expectedState.spend);
        expect(status.blocked).toEqual(expectedState.blocked);
        expect(reopened.searchMessages("acknowledged tail", tailRecord.index, tailRecord.index + 1).matches).toBe(1);
        await reopened.dispose();
        await verifyStore();
      }
    }
  }, 180_000);

  it("reads an aggregate live checkpoint larger than the JSON document limit", async () => {
    const fx = await fixture("aggregate-live-checkpoint");
    const store = new EpisodicStore(fx.workspace, fx.sessionId, EPISODIC_DEFAULTS.maxStoreLineBytes);
    const state = { version: EPISODIC_STORE_VERSION, generation: 0, cursor: null, blocked: null, spend: 0 } as const;
    const records: EpisodicMessageRecord[] = [];
    for (let index = 0; index < 76; index += 1) {
      records.push({
        revision: index + 1, index, entryId: `large-${index}`, kind: "user",
        text: `${String(index).padStart(3, "0")}${"x".repeat(899_997)}`, omitted: false, omissions: [],
        sourceDigest: `source-${index}`, projectedDigest: `projection-${index}`, timestamp: "2026-01-01T00:00:00.000Z", sessionId: fx.sessionId,
      });
    }
    await store.checkpoint({ messages: records, nodes: [], state, watermark: records.length });
    const namespace = join(fx.home, "workspace", "state", "episodic", fx.sessionId);
    const pointer = JSON.parse(await readFile(join(namespace, "checkpoint.current.json"), "utf8")) as { directory: string };
    const checkpointCatalog = join(namespace, pointer.directory, "catalog.jsonl");
    expect((await stat(checkpointCatalog)).size).toBeGreaterThan(64 * 1024 * 1024);

    const reopened = await store.read();

    expect(reopened.messages.size).toBe(records.length);
    expect(reopened.messages.get(records.length - 1)?.text).toBe(records.at(-1)!.text);
    expect(reopened.highestRevision).toBe(records.length);
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

  it("syncs the container's parent directories before recording the store as initialized", async () => {
    const fx = await fixture("container-parents");
    // The workspace reports its canonical root (macOS `/tmp` is a link to `/private/tmp`).
    const workspaceRoot = join(await realpath(fx.root), "home", "workspace");
    const stateRoot = join(workspaceRoot, "state");
    const marker = join(stateRoot, "episodic", fx.sessionId, "initialized.json");
    const synced: Array<{ path: string; markerPresent: boolean }> = [];
    const fileSystem = {
      mkdir, lstat, readdir, rename: realRename, rm: realRm, writeFile,
      syncDurably: async (handle: { sync(): Promise<void> }) => handle.sync(),
      open: async (path: string, ...args: unknown[]) => {
        const handle = await (realOpen as (...values: unknown[]) => Promise<any>)(path, ...args);
        return new Proxy(handle, {
          get(target, key) {
            if (key === "sync") return async () => {
              synced.push({ path, markerPresent: existsSync(marker) });
              return target.sync();
            };
            const value = Reflect.get(target, key, target);
            return typeof value === "function" ? value.bind(target) : value;
          },
        });
      },
    };
    const store = new EpisodicStore(fx.workspace, fx.sessionId, EPISODIC_DEFAULTS.maxStoreLineBytes, fileSystem as never);
    await store.appendCatalog(storeRecord(fx.sessionId));
    const beforeMarker = synced.filter(entry => !entry.markerPresent).map(entry => entry.path);
    expect(beforeMarker).toEqual(expect.arrayContaining([workspaceRoot, stateRoot, join(stateRoot, "episodic")]));
    expect(existsSync(marker)).toBe(true);
  });

  it("reconciles same-size source replacement before adopting a full-refresh cursor", async () => {
    const fx = await fixture("full-refresh-replacement", "same-size-old");
    fx.manager.appendMessage(fauxAssistantMessage("middle entry"));
    fx.manager.appendMessage({ role: "user", content: "last source entry", timestamp: Date.now() });
    const memory = await EpisodicMemory.open({ workspace: fx.workspace, sessionId: fx.sessionId, sessionSource: singleChapterSource(fx.sessionId, fx.sessionFile), summarizer: summarize });
    await memory.entriesCommitted(fx.sessionId);
    const target = fx.manager.getBranch().find(entry => entry.type === "message")!;
    expect(memory.zoomLines(0, 1)?.[0]).toContain("same-size-old");
    expect(memory.searchMessages("same-size-old", 0, 1).matches).toBe(1);
    await replaceCanonicalContent(fx, target.id, "same-size-old", "same-size-new");

    await memory.entriesCommitted(fx.sessionId);

    expect(memory.zoomLines(0, 1)?.[0]).toContain("same-size-new");
    expect(memory.zoomLines(0, 1)?.[0]).not.toContain("same-size-old");
    expect(memory.searchMessages("same-size-old", 0, 1).matches).toBe(0);
    expect(memory.searchMessages("same-size-new", 0, 1).matches).toBe(1);
    expect(await memory.cutAtEntry(target.id)).toBe(1);
    await memory.dispose();
  });

  it("refuses a cut after an earlier same-size source-prefix rewrite", async () => {
    const fx = await fixture("prefix-fence", "first prefix entry");
    fx.manager.appendMessage(fauxAssistantMessage("middle entry"));
    fx.manager.appendMessage({ role: "user", content: "last prefix entry", timestamp: Date.now() });
    const memory = await EpisodicMemory.open({ workspace: fx.workspace, sessionId: fx.sessionId, sessionSource: singleChapterSource(fx.sessionId, fx.sessionFile), summarizer: summarize });
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
      const liveBytes = Buffer.byteLength(`${original(record)}\n`);
      await expect(store.shouldCheckpoint(liveBytes)).resolves.toBe(false);
      expect(serializedLiveRecord).toBe(false);
    } finally { JSON.stringify = original; }
  });

  it("maintains live-byte estimates across message changes and node invalidation", async () => {
    const fx = await fixture("live-byte-estimate", `first message ${"x".repeat(400)}`);
    fx.manager.appendMessage(fauxAssistantMessage(`first reply ${"a".repeat(400)}`));
    fx.manager.appendMessage({ role: "user", content: `second message ${"y".repeat(400)}`, timestamp: Date.now() });
    fx.manager.appendMessage(fauxAssistantMessage(`second reply ${"b".repeat(400)}`));
    let gateReplacement = false;
    let enterReplacement!: () => void;
    const replacementStarted = new Promise<void>(resolve => { enterReplacement = resolve; });
    let releaseReplacement!: () => void;
    const replacementGate = new Promise<void>(resolve => { releaseReplacement = resolve; });
    const summarizer: EpisodicSummarizer = async request => {
      if (gateReplacement && request.turns.at(-1)!.text.includes("replacement-marker")) {
        enterReplacement();
        await replacementGate;
      }
      return summarize(request);
    };
    const memory = await EpisodicMemory.open({
      workspace: fx.workspace, sessionId: fx.sessionId, sessionSource: singleChapterSource(fx.sessionId, fx.sessionFile), summarizer,
      limits: { nodeBytes: 256, viewBytes: 256, jobs: 4, retryMs: 0 },
    });
    await memory.entriesCommitted(fx.sessionId);
    await memory.whenReady(memory.status().messages);
    const owner = memory as unknown as {
      liveBytes: number;
      messages: Map<number, EpisodicMessageRecord>;
      nodes: Map<string, { level: number; index: number }>;
      store: EpisodicStore;
      committedRevision: number;
    };
    const recomputeBytes = (): number => [...owner.messages.values(), ...owner.nodes.values()].reduce((bytes, record) => bytes + Buffer.byteLength(`${JSON.stringify(record)}\n`), 0);
    const assertEstimate = (): void => expect(owner.liveBytes).toBe(recomputeBytes());
    const initialNodeCount = owner.nodes.size;
    expect(initialNodeCount).toBeGreaterThan(0);
    assertEstimate();

    fx.manager.appendMessage({ role: "user", content: `inserted message ${"i".repeat(400)}`, timestamp: Date.now() });
    await memory.entriesCommitted(fx.sessionId);
    expect(owner.messages.size).toBe(5);
    assertEstimate();

    const nodesBeforeReplacement = owner.nodes.size;
    const targetId = fx.manager.getBranch().find(entry => entry.type === "message")!.id;
    gateReplacement = true;
    fx.manager.appendContextEdit(targetId, { content: `replacement-marker ${"r".repeat(400)}` });
    await memory.entriesIngested(fx.sessionId);
    await replacementStarted;
    expect(owner.nodes.size).toBeLessThan(nodesBeforeReplacement);
    assertEstimate();
    releaseReplacement();
    await memory.whenReady(memory.status().messages);
    assertEstimate();

    const namespace = join(fx.home, "workspace", "state", "episodic", fx.sessionId);
    const catalogPath = join(namespace, "catalog.jsonl");
    const nodesPath = join(namespace, "nodes.jsonl");
    let logBytes = (await stat(catalogPath).catch(() => ({ size: 0 }))).size + (await stat(nodesPath).catch(() => ({ size: 0 }))).size;
    const sample = owner.messages.values().next().value!;
    const estimatedThreshold = owner.liveBytes + 16_384;
    for (let index = 0; logBytes <= estimatedThreshold; index += 1) {
      if (index >= 80) throw new Error("Could not place the test log above the superseded-byte threshold");
      const record = { ...sample, revision: owner.committedRevision + index + 1, text: `history ${"h".repeat(280)}` };
      await owner.store.appendCatalog(record);
      logBytes += Buffer.byteLength(`${JSON.stringify(record)}\n`);
    }
    expect(logBytes).toBeGreaterThan(16_384);
    expect(logBytes).toBeLessThan(32_768);
    await expect(owner.store.shouldCheckpoint(owner.liveBytes)).resolves.toBe(true);
    await expect(owner.store.shouldCheckpoint(owner.liveBytes + 10_000)).resolves.toBe(false);
    await memory.dispose();
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
      workspace: fx.workspace, sessionId: fx.sessionId, sessionSource: singleChapterSource(fx.sessionId, fx.sessionFile), summarizer,
      limits: { ...EPISODIC_DEFAULTS, retryMs: 0, nodeBytes: 512 },
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
