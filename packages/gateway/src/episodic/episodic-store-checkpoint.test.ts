import { appendFile, mkdtemp, mkdir, readFile, readdir, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { EPISODIC_DEFAULTS, EPISODIC_STORE_VERSION, type EpisodicMessageRecord, type EpisodicSummarizer } from "./episodic-contract.js";
import { EpisodicMemory } from "./episodic-memory.js";
import { EpisodicStore } from "./episodic-store.js";

import { singleChapterSource } from "../../test-support/episodic-chapter-source.js";
const roots: string[] = [];
const owners: TronWorkspace[] = [];
afterEach(async () => {
  await Promise.all(owners.splice(0).map(owner => owner.dispose()));
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })));
});

/** Publishes a checkpoint now, as the owner does once the log grows past its threshold. */
async function checkpointNow(memory: EpisodicMemory): Promise<void> {
  const owner = memory as unknown as { enqueueAppend: (operation: () => Promise<void>) => Promise<void>; publishCheckpoint: () => Promise<void> };
  await owner.enqueueAppend(() => owner.publishCheckpoint());
}

const summarizer: EpisodicSummarizer = async request => {
  const last = request.turns.at(-1)!;
  return { role: "assistant", content: [{ type: "text", text: last.text.slice(-120) }], api: "openai-completions", provider: "test", model: "test", usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, stopReason: "stop", timestamp: Date.now() } as never;
};

describe("episodic store checkpoint", () => {
  it("reopening a store below the checkpoint threshold writes no checkpoint", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-episodic-checkpoint-"));
    roots.push(root);
    const cwd = join(root, "project");
    const sessionDir = join(root, "sessions");
    await Promise.all([mkdir(cwd, { recursive: true }), mkdir(sessionDir, { recursive: true })]);
    const manager = SessionManager.create(cwd, sessionDir);
    manager.appendMessage({ role: "user", content: "checkpoint message", timestamp: Date.now() });
    const workspace = new TronWorkspace(join(root, "home"));
    owners.push(workspace);
    const options = { workspace, sessionId: manager.getSessionId(), sessionSource: singleChapterSource(manager.getSessionId(), manager.getSessionFile()!), summarizer, limits: { retryMs: 0 } };
    const namespace = join(root, "home", "workspace", "state", "episodic", manager.getSessionId());
    const memory = await EpisodicMemory.open(options);
    await memory.entriesCommitted(manager.getSessionId());
    expect(memory.status().messages).toBe(1);
    expect((await readdir(namespace)).some(name => /^checkpoint-/u.test(name))).toBe(false);
    await memory.dispose();
    // The log is far below the checkpoint threshold, so an open replays it and
    // publishes nothing: a checkpoint is written by growth, never by an open.
    const reopened = await EpisodicMemory.open(options);
    expect(reopened.status().messages).toBe(1);
    const names = await readdir(namespace);
    expect(names.some(name => name.startsWith("checkpoint-"))).toBe(false);
    expect(names).not.toContain("checkpoint.current.json");
    await reopened.dispose();
  });

  it("streams a long catalog log larger than the aggregate JSON limit into live maps", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-episodic-stream-replay-"));
    roots.push(root);
    const workspace = new TronWorkspace(join(root, "home"));
    owners.push(workspace);
    const sessionId = "stream-replay-session";
    const store = new EpisodicStore(workspace, sessionId, EPISODIC_DEFAULTS.maxStoreLineBytes);
    const base: EpisodicMessageRecord = {
      revision: 1, index: 0, entryId: "entry-0", kind: "user", text: "x".repeat(900), omitted: false, omissions: [],
      sourceDigest: "source", projectedDigest: "projection", timestamp: "2026-01-01T00:00:00.000Z", sessionId,
    };
    await store.appendCatalog(base);
    await store.saveState({ version: EPISODIC_STORE_VERSION, generation: 0, cursor: null, blocked: null, spend: 0 });
    const lineBytes = Buffer.byteLength(`${JSON.stringify(base)}\n`);
    const repetitions = Math.ceil((64 * 1024 * 1024 + 1) / lineBytes);
    let log = "";
    for (let index = 0; index < repetitions; index += 1) log += `${JSON.stringify({ ...base, revision: index + 1 })}\n`;
    const catalogPath = join(root, "home", "workspace", "state", "episodic", sessionId, "catalog.jsonl");
    await writeFile(catalogPath, log, { mode: 0o600 });
    expect(Buffer.byteLength(log)).toBeGreaterThan(64 * 1024 * 1024);
    log = "";
    const snapshot = await store.read();
    expect(snapshot.messages.size).toBe(1);
    expect(snapshot.messages.get(0)?.revision).toBe(repetitions);
    expect(snapshot.highestRevision).toBe(repetitions);
  }, 120_000);

  it("keeps a composed node published after a checkpoint watermark", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-episodic-watermark-"));
    roots.push(root);
    const cwd = join(root, "project");
    const sessionDir = join(root, "sessions");
    await Promise.all([mkdir(cwd, { recursive: true }), mkdir(sessionDir, { recursive: true })]);
    const manager = SessionManager.create(cwd, sessionDir);
    manager.appendMessage({ role: "user", content: "compose gate " + "x".repeat(700), timestamp: Date.now() });
    const workspace = new TronWorkspace(join(root, "home"));
    owners.push(workspace);
    let calls = 0;
    const controlled: EpisodicSummarizer = async request => { calls += 1; return fauxAssistantMessage(request.turns.at(-1)!.text.slice(-100)); };
    const options = { workspace, sessionId: manager.getSessionId(), sessionSource: singleChapterSource(manager.getSessionId(), manager.getSessionFile()!), summarizer: controlled, limits: { nodeBytes: 512, retryMs: 0 } };
    const memory = await EpisodicMemory.open(options);
    const owner = memory as unknown as {
      composeNode: (...args: any[]) => Promise<any>;
      enqueueAppend: (operation: () => Promise<void>) => Promise<void>;
      publishCheckpoint: () => Promise<void>;
      drain: () => Promise<void>;
      nodes: Map<string, { revision: number; level: number; index: number }>;
    };
    let composed!: () => void;
    const isComposed = new Promise<void>(resolve => { composed = resolve; });
    let release!: () => void;
    const held = new Promise<void>(resolve => { release = resolve; });
    const originalCompose = owner.composeNode.bind(owner);
    owner.composeNode = async (...args: any[]) => {
      const record = await originalCompose(...args);
      if (record && record.level === 0) { composed(); await held; }
      return record;
    };
    await memory.entriesIngested(manager.getSessionId());
    await isComposed;
    await owner.enqueueAppend(() => owner.publishCheckpoint());
    const namespace = join(root, "home", "workspace", "state", "episodic", manager.getSessionId());
    const pointer = JSON.parse(await readFile(join(namespace, "checkpoint.current.json"), "utf8")) as { watermark: number };
    release();
    owner.composeNode = originalCompose;
    await owner.drain();
    const leaf = owner.nodes.get("0+1");
    expect(leaf).toBeDefined();
    expect(leaf!.revision).toBeGreaterThan(pointer.watermark);
    const committedRevision = leaf!.revision;
    await memory.dispose();
    const reopened = await EpisodicMemory.open(options);
    expect(reopened.status().view.unbuilt).toBe(0);
    expect((reopened as unknown as { nodes: Map<string, { revision: number }> }).nodes.get("0+1")?.revision).toBe(committedRevision);
    expect(calls).toBe(1);
    await reopened.dispose();
    const reopenedAgain = await EpisodicMemory.open(options);
    expect((reopenedAgain as unknown as { nodes: Map<string, { revision: number }> }).nodes.get("0+1")?.revision).toBe(committedRevision);
    await reopenedAgain.dispose();
  });

  it("gives every durable record the next revision in append order, with no gaps", async () => {
    // The watermark and the browser revision fence both read revisions, so a
    // revision that is burned or reassigned after it is assigned would make the
    // log disagree with the number it reports. Only the queued append assigns one.
    const root = await mkdtemp(join(tmpdir(), "tron-episodic-revisions-"));
    roots.push(root);
    const cwd = join(root, "project");
    const sessionDir = join(root, "sessions");
    await Promise.all([mkdir(cwd, { recursive: true }), mkdir(sessionDir, { recursive: true })]);
    const manager = SessionManager.create(cwd, sessionDir);
    for (let index = 0; index < 3; index += 1) manager.appendMessage({ role: "user", content: `revision message ${index} ${"r".repeat(600)}`, timestamp: Date.now() });
    const workspace = new TronWorkspace(join(root, "home"));
    owners.push(workspace);
    const memory = await EpisodicMemory.open({ workspace, sessionId: manager.getSessionId(), sessionSource: singleChapterSource(manager.getSessionId(), manager.getSessionFile()!), summarizer, limits: { nodeBytes: 512, retryMs: 0 } });
    await memory.entriesCommitted(manager.getSessionId());
    await memory.dispose();
    const namespace = join(root, "home", "workspace", "state", "episodic", manager.getSessionId());
    const revisions: number[] = [];
    for (const file of ["catalog.jsonl", "nodes.jsonl"]) {
      for (const line of (await readFile(join(namespace, file), "utf8")).split("\n")) {
        if (line.trim() !== "") revisions.push((JSON.parse(line) as { revision: number }).revision);
      }
    }
    revisions.sort((left, right) => left - right);
    expect(revisions.length).toBeGreaterThan(3);
    expect(revisions).toEqual(revisions.map((_, index) => index + 1));
  });

  it("refuses a symlinked staging entry without touching its target", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-episodic-checkpoint-symlink-"));
    roots.push(root);
    const cwd = join(root, "project");
    const sessionDir = join(root, "sessions");
    await Promise.all([mkdir(cwd, { recursive: true }), mkdir(sessionDir, { recursive: true })]);
    const manager = SessionManager.create(cwd, sessionDir);
    manager.appendMessage({ role: "user", content: "safe cleanup target", timestamp: Date.now() });
    const workspace = new TronWorkspace(join(root, "home"));
    owners.push(workspace);
    const options = { workspace, sessionId: manager.getSessionId(), sessionSource: singleChapterSource(manager.getSessionId(), manager.getSessionFile()!), summarizer, limits: { retryMs: 0 } };
    const first = await EpisodicMemory.open(options);
    await first.entriesCommitted(manager.getSessionId());
    await checkpointNow(first);
    await first.dispose();
    const namespace = join(root, "home", "workspace", "state", "episodic", manager.getSessionId());
    const outside = join(root, "outside");
    await mkdir(outside, { mode: 0o700 });
    await writeFile(join(outside, "keep"), "untouched", { mode: 0o600 });
    await symlink(outside, join(namespace, ".checkpoint-staging"));
    await expect(EpisodicMemory.open(options)).rejects.toThrow(/unsafe entry/u);
    expect(await readFile(join(outside, "keep"), "utf8")).toBe("untouched");
  });

  it("folds post-watermark tails across interrupted log reclamation and successive opens", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-episodic-fold-tail-"));
    roots.push(root);
    const cwd = join(root, "project");
    const sessionDir = join(root, "sessions");
    await Promise.all([mkdir(cwd, { recursive: true }), mkdir(sessionDir, { recursive: true })]);
    const manager = SessionManager.create(cwd, sessionDir);
    manager.appendMessage({ role: "user", content: "fold tail message", timestamp: Date.now() });
    const workspace = new TronWorkspace(join(root, "home"));
    owners.push(workspace);
    const options = { workspace, sessionId: manager.getSessionId(), sessionSource: singleChapterSource(manager.getSessionId(), manager.getSessionFile()!), summarizer, limits: { retryMs: 0 } };
    const first = await EpisodicMemory.open(options);
    await first.entriesCommitted(manager.getSessionId());
    await checkpointNow(first);
    await first.dispose();
    const store = new EpisodicStore(workspace, manager.getSessionId(), EPISODIC_DEFAULTS.maxStoreLineBytes);
    const snapshot = await store.read();
    const previous = snapshot.messages.get(0)!;
    const watermark = snapshot.highestRevision;
    const namespace = join(root, "home", "workspace", "state", "episodic", manager.getSessionId());
    const catalogPath = join(namespace, "catalog.jsonl");
    const nodesPath = join(namespace, "nodes.jsonl");
    const tail = { ...previous, revision: watermark + 1, text: "acknowledged after checkpoint", projectedDigest: "tail-digest" };
    // Simulate death after pointer publication but before catalog replacement:
    // the old acknowledged line is filtered, while the newer tail remains live.
    await writeFile(catalogPath, `${JSON.stringify(previous)}\n${JSON.stringify(tail)}\n`, { mode: 0o600 });
    await writeFile(nodesPath, "", { mode: 0o600 });
    const withTail = await store.read();
    expect(withTail.messages.size).toBe(1);
    expect(withTail.messages.get(0)?.text).toBe(tail.text);
    expect(withTail.highestRevision).toBe(watermark + 1);
    await store.checkpoint({ messages: withTail.messages.values(), nodes: withTail.nodes.values(), state: withTail.state!, watermark: withTail.highestRevision });
    const afterFold = await store.read();
    expect(afterFold.messages.get(0)?.text).toBe(tail.text);
    expect((await store.read()).messages.get(0)?.text).toBe(tail.text);
  });

  it("holds disposal until an already queued checkpoint and reclamation settle", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-episodic-checkpoint-dispose-"));
    roots.push(root);
    const cwd = join(root, "project");
    const sessionDir = join(root, "sessions");
    await Promise.all([mkdir(cwd, { recursive: true }), mkdir(sessionDir, { recursive: true })]);
    const manager = SessionManager.create(cwd, sessionDir);
    manager.appendMessage({ role: "user", content: "checkpoint disposal ordering", timestamp: Date.now() });
    const workspace = new TronWorkspace(join(root, "home"));
    owners.push(workspace);
    const memory = await EpisodicMemory.open({ workspace, sessionId: manager.getSessionId(), sessionSource: singleChapterSource(manager.getSessionId(), manager.getSessionFile()!), summarizer, limits: { retryMs: 0 } });
    await memory.entriesCommitted(manager.getSessionId());
    const owner = memory as unknown as {
      store: { shouldCheckpoint: (...args: any[]) => Promise<boolean>; checkpoint: (...args: any[]) => Promise<void> };
      checkpointIfNeeded: () => Promise<void>;
    };
    const shouldCheckpoint = owner.store.shouldCheckpoint;
    const checkpoint = owner.store.checkpoint.bind(owner.store);
    owner.store.shouldCheckpoint = async () => true;
    let entered!: () => void;
    const inside = new Promise<void>(resolve => { entered = resolve; });
    let release!: () => void;
    const held = new Promise<void>(resolve => { release = resolve; });
    owner.store.checkpoint = async (...args: any[]) => { entered(); await held; await checkpoint(...args); };
    const queued = owner.checkpointIfNeeded();
    await inside;
    let disposed = false;
    const closing = memory.dispose().then(() => { disposed = true; });
    await Promise.resolve();
    try { expect(disposed).toBe(false); }
    finally { release(); }
    await Promise.all([queued, closing]);
    owner.store.shouldCheckpoint = shouldCheckpoint;
  });

  it("latches a checkpoint failure and refuses subsequent store writes", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-episodic-checkpoint-failure-"));
    roots.push(root);
    const cwd = join(root, "project");
    const sessionDir = join(root, "sessions");
    await Promise.all([mkdir(cwd, { recursive: true }), mkdir(sessionDir, { recursive: true })]);
    const manager = SessionManager.create(cwd, sessionDir);
    manager.appendMessage({ role: "user", content: "before checkpoint failure", timestamp: Date.now() });
    const workspace = new TronWorkspace(join(root, "home"));
    owners.push(workspace);
    const memory = await EpisodicMemory.open({ workspace, sessionId: manager.getSessionId(), sessionSource: singleChapterSource(manager.getSessionId(), manager.getSessionFile()!), summarizer, limits: { retryMs: 0 } });
    await memory.entriesCommitted(manager.getSessionId());
    const owner = memory as unknown as { store: { checkpoint: (...args: any[]) => Promise<void> }; enqueueAppend: (operation: () => Promise<void>) => Promise<void>; publishCheckpoint: () => Promise<void> };
    owner.store.checkpoint = async () => { throw new Error("injected checkpoint reclamation failure"); };
    await expect(owner.enqueueAppend(() => owner.publishCheckpoint())).rejects.toThrow(/injected checkpoint reclamation failure/u);
    manager.appendMessage({ role: "user", content: "must not be acknowledged", timestamp: Date.now() });
    await expect(memory.entriesIngested(manager.getSessionId())).rejects.toThrow(/reopen is required/u);
    expect(memory.status().messages).toBe(1);
    await memory.dispose();
  });

  it("refuses missing or torn immutable checkpoint data and cleans owned interrupted temps", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-episodic-checkpoint-corrupt-"));
    roots.push(root);
    const cwd = join(root, "project");
    const sessionDir = join(root, "sessions");
    await Promise.all([mkdir(cwd, { recursive: true }), mkdir(sessionDir, { recursive: true })]);
    const manager = SessionManager.create(cwd, sessionDir);
    manager.appendMessage({ role: "user", content: "durable checkpoint entry", timestamp: Date.now() });
    const workspace = new TronWorkspace(join(root, "home"));
    owners.push(workspace);
    const options = { workspace, sessionId: manager.getSessionId(), sessionSource: singleChapterSource(manager.getSessionId(), manager.getSessionFile()!), summarizer, limits: { retryMs: 0 } };
    const initial = await EpisodicMemory.open(options);
    await initial.entriesCommitted(manager.getSessionId());
    await checkpointNow(initial);
    await initial.dispose();
    const namespace = join(root, "home", "workspace", "state", "episodic", manager.getSessionId());
    const checkpoint = (await readdir(namespace)).find(name => /^checkpoint-[A-Za-z0-9.-]+$/u.test(name))!;
    const nodesPath = join(namespace, checkpoint, "nodes.jsonl");
    const originalNodes = await readFile(nodesPath);
    await rm(nodesPath);
    await expect(EpisodicMemory.open(options)).rejects.toThrow(/checkpoint file is missing/u);
    await writeFile(nodesPath, originalNodes, { mode: 0o600 });
    const activeNodes = nodesPath;
    await appendFile(activeNodes, "{torn");
    await expect(EpisodicMemory.open(options)).rejects.toThrow(/checkpoint contains a torn record/u);
    expect(await readFile(activeNodes, "utf8")).toContain("{torn");

    const temporary = join(namespace, ".checkpoint-log-ab12cd");
    const pointerTemporary = join(namespace, "checkpoint.current.json.123.0123456789ab.tmp");
    const staging = join(namespace, ".checkpoint-staging");
    const orphanCheckpoint = join(namespace, "checkpoint-orphan-123");
    await mkdir(orphanCheckpoint, { mode: 0o700 });
    await writeFile(join(orphanCheckpoint, "catalog.jsonl"), "", { mode: 0o600 });
    await mkdir(staging, { mode: 0o700 });
    await writeFile(join(staging, "catalog.jsonl"), "partial", { mode: 0o600 });
    await writeFile(temporary, "orphan", { mode: 0o600 });
    await writeFile(pointerTemporary, "orphan", { mode: 0o600 });
    // Restore the valid immutable file, then open: cleanup removes only the exact
    // owner-created temp pattern and leaves the pointed-to checkpoint authoritative.
    await writeFile(activeNodes, originalNodes, { mode: 0o600 });
    const cleaned = await EpisodicMemory.open(options);
    const namesAfterCleanup = await readdir(namespace);
    expect(namesAfterCleanup).not.toContain(".checkpoint-log-ab12cd");
    expect(namesAfterCleanup).not.toContain("checkpoint.current.json.123.0123456789ab.tmp");
    expect(namesAfterCleanup).not.toContain(".checkpoint-staging");
    expect(namesAfterCleanup).not.toContain("checkpoint-orphan-123");
    expect(cleaned.status().messages).toBe(1);
    await cleaned.dispose();
  });
});
