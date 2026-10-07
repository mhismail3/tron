import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { constants, existsSync, readFileSync } from "node:fs";
import { appendFile, chmod, lstat, mkdir, mkdtemp, readFile, rm, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it } from "vitest";
import { fauxAssistantMessage, type Message } from "@earendil-works/pi-ai";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import {
  EpisodicMemoryError, EPISODIC_DEFAULTS,
  type EpisodicDiagnostic, type EpisodicLimits, type EpisodicSummarizer, type EpisodicMessageRecord, type EpisodicNodeRecord, type EpisodicInvalidationRecord,
} from "./episodic-contract.js";
import { decodeContextRuns } from "./episodic-tree.js";
import { EpisodicMemory, readEpisodicState } from "./episodic-memory.js";
import { EpisodicStore } from "./episodic-store.js";
import { awaitsWithin, waitFor } from "../../test-support/wait-for.js";

/*
 * Crash and store recovery: a child process is SIGKILLed while it is writing
 * nodes, and while it is inside the window between a catalog revision and the
 * invalidation that must follow it. The parent must be able to reopen the store,
 * prove it consistent, resume the pump and refold a valid view. The same file
 * covers the store boundaries that can be seen without a crash: a torn trailing
 * record (discarded, because it was never acknowledged), a corrupt record
 * (refused visibly, never skipped), a deleted container and a second opener.
 */

const EPISODIC_MEMORY_MODULE = fileURLToPath(new URL("./episodic-memory.ts", import.meta.url));
const CONTRACT_MODULE = fileURLToPath(new URL("./episodic-contract.ts", import.meta.url));
const WORKSPACE_MODULE = fileURLToPath(new URL("../workspace/tron-workspace.ts", import.meta.url));

const roots: string[] = [];
const owners: TronWorkspace[] = [];
const children: Array<ReturnType<typeof spawn>> = [];
afterEach(async () => {
  for (const child of children.splice(0)) child.kill("SIGKILL");
  await Promise.all(owners.splice(0).map(owner => owner.dispose()));
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })));
});

/** A deterministic compactor that never touches a model provider. */
const stubSummarizer: EpisodicSummarizer = async (request) => {
  const last = request.turns.at(-1)!;
  return fauxAssistantMessage(last.text.replace(/\s+/gu, " ").trim().slice(-200));
};

/** The same, reporting usage: spend is the state a restart must not hand back. */
const SPEND_USAGE = {
  input: 64, output: 16, cacheRead: 0, cacheWrite: 0, totalTokens: 80,
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
};
const chargedSummarizer: EpisodicSummarizer = async (request) => ({ ...await stubSummarizer(request), usage: SPEND_USAGE });

interface RecoveryFixture {
  root: string;
  home: string;
  sessionFile: string;
  sessionId: string;
  manager: SessionManager;
  workspace: TronWorkspace;
  storeRoot: string;
  nodesPath: string;
  catalogPath: string;
  diagnostics: EpisodicDiagnostic[];
}

async function fixture(label: string, messages: number): Promise<RecoveryFixture> {
  const root = await mkdtemp(join(tmpdir(), `tron-episodic-recovery-${label}-`));
  roots.push(root);
  const home = join(root, "home");
  const cwd = join(root, "project");
  const sessionDir = join(root, "sessions");
  await Promise.all([mkdir(cwd, { recursive: true }), mkdir(sessionDir, { recursive: true })]);
  const manager = SessionManager.create(cwd, sessionDir);
  for (let index = 0; index < messages; index += 1) {
    manager.appendMessage({ role: "user", content: `recovery prompt ${index} ${"r".repeat(700)}`, timestamp: Date.now() } satisfies Message);
    manager.appendMessage(fauxAssistantMessage([{ type: "text", text: `recovery reply ${index} ${"s".repeat(700)}` }]));
  }
  const sessionFile = manager.getSessionFile()!;
  const sessionId = manager.getSessionId();
  const workspace = new TronWorkspace(home);
  owners.push(workspace);
  const storeRoot = join(home, "workspace", "state", "episodic", sessionId);
  return {
    root, home, sessionFile, sessionId, manager, workspace, storeRoot,
    nodesPath: join(storeRoot, "nodes.jsonl"),
    catalogPath: join(storeRoot, "catalog.jsonl"),
    diagnostics: [],
  };
}

async function openMemory(
  fx: RecoveryFixture,
  summarizer: EpisodicSummarizer = stubSummarizer,
  limits: Partial<EpisodicLimits> = {},
): Promise<EpisodicMemory> {
  return EpisodicMemory.open({
    workspace: fx.workspace,
    sessionId: fx.sessionId,
    sessionFile: fx.sessionFile,
    summarizer,
    limits: { viewBytes: 4_096, jobs: 4, retryMs: 1, ...limits },
    diagnostic: record => fx.diagnostics.push(record),
    sleep: async () => {},
  });
}

/** Complete lines only: a torn trailing line is exactly what the store may leave
 * behind, and the test's own reader has to tolerate it. */
function records(text: string): Array<Record<string, unknown>> {
  const lines = text.split("\n");
  const complete = lines.slice(0, -1);
  return complete.filter(line => line.trim() !== "").map(line => JSON.parse(line) as Record<string, unknown>);
}

async function readRecords(path: string): Promise<Array<Record<string, unknown>>> {
  try {
    return records(await readFile(path, "utf8"));
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return [];
    throw error;
  }
}

async function readPersistedState(fx: RecoveryFixture): Promise<{ catalog: Array<Record<string, unknown>>; nodes: Array<Record<string, unknown>> }> {
  const snapshot = await new EpisodicStore(fx.workspace, fx.sessionId, EPISODIC_DEFAULTS.maxStoreLineBytes).read();
  return { catalog: [...snapshot.messages.values()], nodes: [...snapshot.nodes.values()] };
}

interface LiveNode { revision: number; level: number; index: number; kind: string; childRevisions?: [number, number] }

function liveNodes(log: Array<Record<string, unknown>>): Map<string, LiveNode> {
  const live = new Map<string, LiveNode>();
  for (const record of log) {
    if (typeof record.nodes === "string") {
      for (const code of (record.nodes as string).split(" ")) {
        if (code === "") continue;
        const packed = Number.parseInt(code, 36);
        const level = packed % 32;
        const start = (packed - level) / 32;
        live.delete(`${start}+${2 ** level}`);
      }
      continue;
    }
    live.set(`${(record.index as number) * 2 ** (record.level as number)}+${2 ** (record.level as number)}`, record as unknown as LiveNode);
  }
  return live;
}

function assertConsistentStore(log: Array<Record<string, unknown>>, messages: number): Map<string, LiveNode> {
  const nodeRecords = log.filter(record => typeof record.nodes !== "string");
  const revisions = nodeRecords.map(record => record.revision as number);
  expect(new Set(revisions).size).toBe(revisions.length);
  const live = liveNodes(log);
  // The live record for an address is the highest revision written for it, so a
  // crash cannot leave two live records for one node.
  const highest = new Map<string, number>();
  for (const record of nodeRecords) {
    const key = `${(record.index as number) * 2 ** (record.level as number)}+${2 ** (record.level as number)}`;
    highest.set(key, Math.max(highest.get(key) ?? -1, record.revision as number));
  }
  for (const [address, node] of live) expect(node.revision).toBe(highest.get(address));
  for (const [address, node] of live) {
    const span = 2 ** node.level;
    if (node.level === 0) {
      expect(node.index).toBeLessThan(messages);
      continue;
    }
    expect((node.index + 1) * span).toBeLessThanOrEqual(messages);
    const childSpan = 2 ** (node.level - 1);
    const childA = live.get(`${node.index * 2 * childSpan}+${childSpan}`)!;
    const childB = live.get(`${(node.index * 2 + 1) * childSpan}+${childSpan}`)!;
    expect(childA, `${address} has no first child`).toBeDefined();
    expect(childB, `${address} has no second child`).toBeDefined();
    expect(node.childRevisions).toEqual([childA.revision, childB.revision]);
  }
  return live;
}

async function writeChildProgram(fx: RecoveryFixture, readyMarker: string): Promise<{ program: string; hook: string }> {
  const program = join(fx.root, "child.mjs");
  const hook = join(fx.root, "hook.mjs");
  await writeFile(hook, `import { registerHooks } from "node:module";\nimport { pathToFileURL } from "node:url";\nregisterHooks({\n  resolve(specifier, context, nextResolve) {\n    try { return nextResolve(specifier, context); }\n    catch (error) {\n      if (specifier.endsWith(".js")) return nextResolve(specifier.slice(0, -3) + ".ts", context);\n      throw error;\n    }\n  },\n});\nawait import(pathToFileURL(process.argv[1]).href);\n`, "utf8");
  await writeFile(program, `import { existsSync } from "node:fs";\nimport { EpisodicMemory } from ${JSON.stringify(EPISODIC_MEMORY_MODULE)};\nimport { TronWorkspace } from ${JSON.stringify(WORKSPACE_MODULE)};\n\nconst [home, sessionFile, sessionId, marker] = process.argv.slice(2);\nconst zero = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };\nconst workspace = new TronWorkspace(home);\nconst memory = await EpisodicMemory.open({\n  workspace, sessionId, sessionFile,\n  limits: { viewBytes: 4096, jobs: 4, retryMs: 1 },\n  summarizer: async (request) => {\n    const last = request.turns[request.turns.length - 1].text.replace(/\\s+/g, " ").trim().slice(-200);\n    return { role: "assistant", content: [{ type: "text", text: last }], api: "faux", provider: "faux", model: "child", usage: zero, stopReason: "stop", timestamp: Date.now() };\n  },\n  sleep: async () => {},\n});\nawait memory.entriesCommitted(sessionId);\nprocess.stdout.write("ready\\n");\n// The parent appends the edit and then drops this marker. Intercept the exact\n// invalidation append, after the catalog revision is durable and before it lands.\nfor (;;) {\n  if (existsSync(marker)) break;\n  await new Promise(resolve => setTimeout(resolve, 1));\n}\nconst owner = memory;\nconst append = owner.store.appendNode.bind(owner.store);\nowner.store.appendNode = async record => {\n  if (record.nodes) {\n    process.stdout.write("invalidation-window\\n");\n    // The unresolved await alone does not keep Node alive; retain a live handle\n    // so the parent can observe the exact crash window even when descheduled.\n    setInterval(() => {}, 1_000);\n    await new Promise(() => {});\n  }\n  await append(record);\n};\nawait memory.entriesCommitted(sessionId);\nprocess.stdout.write("done\\n");\n`, "utf8");
  return { program, hook };
}

/** Polling is test-owned, but every child observation has a local hang bound. */
async function waitUntil(predicate: () => boolean | Promise<boolean>, label = "recovery condition"): Promise<void> {
  await waitFor(async () => (await predicate()) || undefined, label);
}

async function waitForChildLine(child: ReturnType<typeof spawn>, text: string, output: () => string): Promise<void> {
  await waitFor(() => {
    if (output().includes(text)) return true;
    if (child.exitCode !== null || child.signalCode !== null) throw new Error(`child exited before printing ${text}: ${output()}`);
    return undefined;
  }, `child output line ${text}`);
}

async function waitForFileGrowth(path: string, lines: number, timeoutMs: number): Promise<void> {
  await waitFor(async () => (await readRecords(path)).length >= lines || undefined,
    `store to reach ${lines} records`, { boundMs: timeoutMs });
}

describe("episodic memory crash recovery", () => {
  it("completes an interrupted chunked invalidation before serving memory", async () => {
    const fx = await fixture("chunk-boundary", 0);
    // Persist a realistic-sized dependency fanout directly through the store's
    // durable append API; exercising chunk recovery does not need 2,100 real
    // session messages or compactor/view work.
    const initial = await openMemory(fx);
    await initial.dispose();
    const seedStore = new EpisodicStore(fx.workspace, fx.sessionId, EPISODIC_DEFAULTS.maxStoreLineBytes);
    const digest = (value: string) => createHash("sha256").update(value).digest("hex");
    const messages: EpisodicMessageRecord[] = [];
    const nodes: EpisodicNodeRecord[] = [];
    for (let index = 0; index < 2_100; index += 1) {
      const text = `seed ${index}`;
      messages.push({
        revision: index + 1,
        index,
        sessionId: fx.sessionId,
        entryId: `seed-${index}`,
        kind: "user",
        text,
        sourceDigest: digest(text),
        projectedDigest: digest(text),
        omissions: [],
        omitted: false,
      });
      nodes.push({
        revision: index + 2_101,
        level: 0,
        index,
        kind: "summary",
        text,
        contextRuns: index === 0 ? [] : [[0, index]],
        textDigest: digest(text),
        sourceDigest: digest(`user: ${text}`),
      });
    }
    await seedStore.checkpoint({
      messages,
      nodes,
      state: { version: 1, generation: 0, cursor: null, blocked: null, spend: 0 },
      watermark: 4_200,
    });
    const memory = await openMemory(fx);
    const owner = memory as unknown as {
      invalidate: (indices: number[]) => Promise<void>;
      store: { appendNode: (record: EpisodicNodeRecord | EpisodicInvalidationRecord) => Promise<void> };
    };
    const append = owner.store.appendNode.bind(owner.store);
    let chunks = 0;
    owner.store.appendNode = async record => {
      if ("nodes" in record && ++chunks === 2) throw new Error("test crash at chunk boundary");
      await append(record);
    };
    try {
      await expect(owner.invalidate([0])).rejects.toThrow("test crash");
      expect(chunks).toBe(2);
    } finally {
      owner.store.appendNode = append;
      await memory.dispose();
    }
    const beforeState = await readPersistedState(fx);
    const before = liveNodes(beforeState.nodes);
    expect(before.size).toBeGreaterThan(0);
    expect([...before.values()].some(node =>
      decodeContextRuns((node as unknown as EpisodicNodeRecord).contextRuns).some(dependency => !before.has(dependency)),
    )).toBe(true);
    let calls = 0;
    const reopened = await openMemory(fx, async request => { calls++; return stubSummarizer(request); });
    try {
      const live = assertConsistentStore((await readPersistedState(fx)).nodes, 2_100);
      for (const node of live.values()) {
        for (const dependency of decodeContextRuns((node as unknown as EpisodicNodeRecord).contextRuns)) {
          expect(live.has(dependency), `surviving context references revoked ${dependency}`).toBe(true);
        }
      }
      expect(calls).toBe(0);
    } finally { await reopened.dispose(); }
    const repaired = await readPersistedState(fx);
    const again = await openMemory(fx);
    await again.dispose();
    expect(await readPersistedState(fx)).toEqual(repaired);
  }, 180_000);

  it("serializes durable parent publication with child invalidation", async () => {
    const fx = await fixture("publication-race", 1);
    const memory = await openMemory(fx);
    const owner = memory as unknown as {
      pump: () => Promise<void>;
      buildNode: (level: number, index: number) => Promise<void>;
      invalidate: (indices: number[]) => Promise<void>;
      store: { appendNode: (record: EpisodicNodeRecord | EpisodicInvalidationRecord) => Promise<void> };
    };
    owner.pump = async () => {};
    await memory.entriesCommitted(fx.sessionId);
    await owner.buildNode(0, 0);
    await owner.buildNode(0, 1);
    const append = owner.store.appendNode.bind(owner.store);
    let entered!: () => void;
    const inside = new Promise<void>(resolve => { entered = resolve; });
    let release!: () => void;
    const held = new Promise<void>(resolve => { release = resolve; });
    owner.store.appendNode = async record => {
      await append(record);
      if (!("nodes" in record) && record.level === 1) { entered(); await held; }
    };
    const build = owner.buildNode(1, 0);
    try {
      await inside;
      const invalidation = owner.invalidate([0]);
      release();
      await Promise.all([build, invalidation]);
    } finally {
      release();
      await build;
      owner.store.appendNode = append;
      await memory.dispose();
    }
    // Inspect before open: recovery must not mask a broken publication boundary.
    const live = liveNodes((await readPersistedState(fx)).nodes);
    const reopened = await openMemory(fx);
    await reopened.dispose();
    expect(live.has("0+2")).toBe(false);
    assertConsistentStore((await readPersistedState(fx)).nodes, 2);
  }, 120_000);

  it("refuses a waiter instead of stranding it when the pump dies unexpectedly", async () => {
    // The pump classifies every failure it can name, but an unexpected one (a
    // store write the filesystem refuses, say) escapes it. Without the owner's
    // own settlement the pump would be dead, the memory unblocked and every
    // waiter waiting for a node that can never come — and a turn loop only waits
    // on `whenReady`, so that is a Home turn that hangs until the user stops it.
    const fx = await fixture("pump-death", 4);
    const memory = await openMemory(fx);
    let fail!: (error: unknown) => void;
    const dying = new Promise<void>((_resolve, reject) => { fail = reject; });
    // The one failure the owner cannot classify. Reached here by injecting it at
    // the pump boundary rather than by breaking a real filesystem, because every
    // store boundary this module owns classifies its own failures by design.
    (memory as unknown as { pump: () => Promise<void> }).pump = () => dying;
    await memory.entriesIngested(fx.sessionId);
    const cut = memory.status().messages;
    expect(cut).toBeGreaterThan(0);
    const waiting = memory.whenReady(cut).then(() => "resolved", (error: unknown) => `rejected: ${error instanceof Error ? error.message : String(error)}`);
    fail(new Error("store write failed"));
    expect(await waiting).toContain("rejected");
    expect(memory.status().blocked?.reason).toBe("permanent-failure");
    await memory.dispose();
  }, 120_000);

  it("keeps the token spend a killed child had already recorded", async () => {
    // Spend is the one piece of a memory that no restart may hand back: a crash
    // must not reset the record of what was spent. The child is killed mid-pump,
    // and the parent's reopen must restore the spend.
    const fx = await fixture("spend-crash", 12);
    const hook = join(fx.root, "hook.mjs");
    const program = join(fx.root, "spend-child.mjs");
    await writeFile(hook, `import { registerHooks } from "node:module";\nimport { pathToFileURL } from "node:url";\nregisterHooks({\n  resolve(specifier, context, nextResolve) {\n    try { return nextResolve(specifier, context); }\n    catch (error) {\n      if (specifier.endsWith(".js")) return nextResolve(specifier.slice(0, -3) + ".ts", context);\n      throw error;\n    }\n  },\n});\nawait import(pathToFileURL(process.argv[1]).href);\n`, "utf8");
    await writeFile(program, `import { EpisodicMemory } from ${JSON.stringify(EPISODIC_MEMORY_MODULE)};\nimport { TronWorkspace } from ${JSON.stringify(WORKSPACE_MODULE)};\n\nconst [home, sessionFile, sessionId] = process.argv.slice(2);\nconst usage = { input: 80, output: 20, cacheRead: 0, cacheWrite: 0, totalTokens: 100, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };\nconst workspace = new TronWorkspace(home);\nconst memory = await EpisodicMemory.open({\n  workspace, sessionId, sessionFile,\n  limits: { viewBytes: 4096, jobs: 1, retryMs: 1 },\n  summarizer: async (request) => ({\n    role: "assistant", content: [{ type: "text", text: \`spend line \${request.turns.length}\` }],\n    api: "faux", provider: "faux", model: "child", usage, stopReason: "stop", timestamp: Date.now(),\n  }),\n  sleep: async () => {},\n});\nprocess.stdout.write("opened\\n");\nawait memory.entriesCommitted(sessionId);\nprocess.stdout.write(\`spent \${memory.status().tokens.used}\\n\`);\nfor (;;) await new Promise(resolve => setTimeout(resolve, 5));\n`, "utf8");
    const child = spawn(process.execPath, ["--experimental-transform-types", "--import", hook, program, fx.home, fx.sessionFile, fx.sessionId], { stdio: ["ignore", "pipe", "pipe"] });
    children.push(child);
    let output = "";
    child.stdout.on("data", (chunk: Buffer) => { output += chunk.toString(); });
    child.stderr.on("data", (chunk: Buffer) => { output += chunk.toString(); });
    const statePath = join(fx.storeRoot, "state.json");
    const spendOf = async (): Promise<number> => {
      try {
        const state = JSON.parse(await readFile(statePath, "utf8")) as { spend?: number };
        return state.spend ?? 0;
      } catch { return 0; }
    };
    await waitFor(async () => {
      const spend = await spendOf();
      if (spend > 0) return spend;
      if (child.exitCode !== null || child.signalCode !== null) throw new Error(`child exited before recording spend; output: ${output}`);
      return undefined;
    }, "child to durably record token spend", { boundMs: 30_000 });
    const durableSpend = await spendOf();
    child.kill("SIGKILL");
    await new Promise(resolve => child.once("exit", resolve));
    const lock = join(fx.home, "gateway", "workspace-state.lock");
    const past = new Date(Date.now() - 120_000);
    await utimes(lock, past, past);

    // Reopened, the memory starts from what the child spent.
    const reopened = await EpisodicMemory.open({
      workspace: fx.workspace,
      sessionId: fx.sessionId,
      sessionFile: fx.sessionFile,
      summarizer: stubSummarizer,
      limits: { viewBytes: 4_096, jobs: 4, retryMs: 1 },
      sleep: async () => {},
    });
    const reopenedUsed = reopened.status().tokens.used;
    expect(durableSpend).toBeGreaterThanOrEqual(100);
    expect(reopenedUsed).toBeGreaterThanOrEqual(durableSpend);
    await reopened.dispose();

    // #493: spend is reported, never a ceiling: a reopened memory keeps it and is
    // not blocked by it.
    const again = await EpisodicMemory.open({
      workspace: fx.workspace,
      sessionId: fx.sessionId,
      sessionFile: fx.sessionFile,
      summarizer: stubSummarizer,
      limits: { viewBytes: 4_096, jobs: 4, retryMs: 1 },
      sleep: async () => {},
    });
    expect(again.status().tokens.used).toBe(reopenedUsed);
    expect(again.status().blocked).toBeNull();
    await again.dispose();
  }, 120_000);

  it("serializes state writes and snapshots them inside the serialized step", async () => {
    // The store document must describe the memory as it is now. An un-serialized
    // `saveState` takes its snapshot when it is *called* and awaits an atomic
    // rename, so two concurrent callers can both be in flight and the older
    // snapshot can land last: spend goes backwards, or a block written by one
    // path is overwritten by another path's earlier, unblocked state. Reached
    // here by holding the first write inside the store, which is the only
    // observation point a test can own: the assertion is that the owner does not
    // even *ask* the store for the second write while the first is unfinished.
    const fx = await fixture("state-order", 12);
    const memory = await openMemory(fx, chargedSummarizer);
    await memory.entriesCommitted(fx.sessionId);
    const store = (memory as unknown as { store: { saveState: (state: unknown) => Promise<void> } }).store;
    const write = store.saveState.bind(store);
    let release!: () => void;
    const held = new Promise<void>((resolve) => { release = resolve; });
    const writes: number[] = [];
    store.saveState = async (state: unknown) => {
      const index = writes.length;
      writes.push(index);
      if (index === 0) await held;
      await write(state);
    };
    const owner = memory as unknown as { saveState: () => Promise<void> };
    const first = owner.saveState();
    const second = owner.saveState();
    // The first write is inside the store and held there; the second has not
    // reached it, because the owner chains it behind the first and snapshots
    // then, not now.
    await waitUntil(() => writes.length >= 1);
    expect(writes.length).toBe(1);
    release();
    await Promise.all([first, second]);
    expect(writes.length).toBe(2);
    const durable = JSON.parse(await readFile(join(fx.storeRoot, "state.json"), "utf8")) as { spend?: number; blocked?: unknown };
    expect(durable.spend).toBe(memory.status().tokens.used);
    expect(durable.blocked).toEqual(memory.status().blocked);
    await memory.dispose();
  }, 120_000);

  it("keeps the persisted state equal to the live state while concurrent jobs settle", async () => {
    // `saveState` takes its snapshot when it is called. Concurrent jobs settle at
    // once, so an un-serialized save lets an older snapshot land last: spend goes
    // backwards, or a block written by one path is overwritten by another path's
    // earlier, unblocked state. The store document is the only durable record of
    // both, so a restart reads whichever write landed last.
    const fx = await fixture("state-order", 40);
    const memory = await openMemory(fx, chargedSummarizer);
    const statePath = join(fx.storeRoot, "state.json");
    const persisted = async (): Promise<{ spend?: number; blocked?: unknown }> => JSON.parse(await readFile(statePath, "utf8")) as { spend?: number; blocked?: unknown };
    for (let round = 0; round < 25; round += 1) {
      fx.manager.appendMessage({ role: "user", content: `round ${round} ${"w".repeat(700)}`, timestamp: Date.now() });
      await memory.entriesCommitted(fx.sessionId);
      const live = memory.status();
      const durable = await persisted();
      expect(live.tokens.used).toBeGreaterThan(0);
      expect(durable.spend).toBe(live.tokens.used);
      expect(durable.blocked).toEqual(live.blocked);
    }
    await memory.dispose();
  }, 120_000);

  it("resumes without waiting for the pump backlog", async () => {
    // Clearing a block is an operator command: it must return
    // once the memory is unblocked and re-read, not after the whole summary
    // catch-up, or the RPC holds the Home mutex for the entire pump.
    const fx = await fixture("resume-ingested", 12);
    let calls = 0;
    let release!: () => void;
    const parked = new Promise<void>((resolve) => { release = resolve; });
    const summarizer: EpisodicSummarizer = async (request) => {
      calls += 1;
      // The first node's bounded retries fail, which blocks the memory; the
      // pump after the resume then parks, so an awaited drain would hang here.
      if (calls <= 4) return fauxAssistantMessage("", { stopReason: "error", errorMessage: "503 service unavailable" });
      await parked;
      return await stubSummarizer(request);
    };
    const memory = await openMemory(fx, summarizer, { maxRetries: 3 });
    await memory.entriesCommitted(fx.sessionId);
    expect(memory.status().blocked?.reason).toBe("retries-exhausted");

    await memory.resumeIngested();
    expect(memory.status().blocked).toBeNull();
    expect(memory.status().view.unbuilt).toBeGreaterThan(0);
    release();
    await memory.dispose();
  }, 120_000);

  it("bounds one compactor call by a timeout, classified transient", async () => {
    // A compactor call that never returns holds its build slot forever: the pump
    // neither blocks nor retries, and every turn that waits on that node waits
    // for the life of the process. The bound is injectable so a test never waits
    // out the production one.
    const fx = await fixture("call-timeout", 2);
    const slow: EpisodicSummarizer = async (request) => {
      await new Promise((resolve) => setTimeout(resolve, 3_000));
      return await stubSummarizer(request);
    };
    const memory = await openMemory(fx, slow, { compactorTimeoutMs: 20, maxRetries: 1 });
    await memory.entriesCommitted(fx.sessionId);
    expect(memory.status().blocked?.reason).toBe("retries-exhausted");
    await memory.dispose();
  }, 120_000);

  it("reads the persisted blocked state and spend without opening the memory", async () => {
    // `home.status` has to report what a restart would restore before any
    // activation opens the store: its recorded spend, and the
    // block that refuses every activation.
    const fx = await fixture("state-peek", 6);
    const memory = await openMemory(fx, chargedSummarizer);
    await memory.entriesCommitted(fx.sessionId);
    const used = memory.status().tokens.used;
    expect(used).toBeGreaterThan(0);
    await memory.dispose();

    const peeked = await readEpisodicState({ workspace: fx.workspace, sessionId: fx.sessionId });
    expect(peeked?.spend).toBe(used);
    expect(peeked?.blocked).toBeNull();
    // A workspace that never initialized its episodic state has nothing to
    // report; a namespace that was initialized and is now missing is a store
    // refusal the reader sees, not an empty answer.
    const fresh = new TronWorkspace(join(fx.root, "never-opened"));
    owners.push(fresh);
    expect(await readEpisodicState({ workspace: fresh, sessionId: "session-with-no-store" })).toBeUndefined();
  }, 120_000);

  it("reopens a store a killed child was writing, proves it consistent, and refolds a valid view", async () => {
    const fx = await fixture("sigkill", 60);
    const marker = join(fx.root, "commit-marker");
    const { program, hook } = await writeChildProgram(fx, marker);
    const child = spawn(process.execPath, ["--experimental-transform-types", "--import", hook, program, fx.home, fx.sessionFile, fx.sessionId, marker], { stdio: ["ignore", "pipe", "pipe"] });
    children.push(child);
    let output = "";
    child.stdout.on("data", (chunk: Buffer) => { output += chunk.toString(); });
    child.stderr.on("data", (chunk: Buffer) => { output += chunk.toString(); });
    // Kill it once it is demonstrably writing nodes: the pump is mid-build.
    try {
      await waitForFileGrowth(fx.nodesPath, 8, 30_000);
    } catch (error) {
      throw new Error(`${(error as Error).message}; child output: ${output}`);
    }
    child.kill("SIGKILL");
    await new Promise(resolve => child.once("exit", resolve));
    // The kill landed while the first commit was still writing nodes, so the
    // child never reported completion.
    expect(output).not.toContain("done");
    expect(output).not.toContain("Error");
    // The killed owner's workspace lock is only taken over once it is stale;
    // age it instead of waiting out the 60 s staleness window.
    const lock = join(fx.home, "gateway", "workspace-state.lock");
    const past = new Date(Date.now() - 120_000);
    await utimes(lock, past, past);

    const persistedBefore = await readPersistedState(fx);
    const messages = persistedBefore.catalog.length;
    expect(messages).toBe(120);
    const liveBefore = assertConsistentStore(persistedBefore.nodes, messages);

    // Reopen: the store loads, the torn tail (if the kill produced one) is gone,
    // and the pump resumes to a complete tree.
    const memory = await openMemory(fx);
    await memory.entriesCommitted(fx.sessionId);
    const status = memory.status();
    expect(status.blocked).toBeNull();
    expect(status.messages).toBe(messages);
    expect(status.view.unbuilt).toBe(0);
    expect(status.view.parts.length).toBeGreaterThan(0);
    let cursor = 0;
    for (const part of status.view.parts) {
      expect(part.start).toBe(cursor);
      cursor += part.messages;
    }
    expect(cursor).toBe(messages);
    // Every node of the full tree exists, so the crash lost no acknowledged work
    // and produced no duplicate or orphaned node.
    const liveAfter = assertConsistentStore((await readPersistedState(fx)).nodes, messages);
    expect(liveAfter.size).toBeGreaterThanOrEqual(liveBefore.size);
    // Every node whose whole range exists: one per level per full span.
    let expectedNodes = 0;
    for (let span = 1; span <= messages; span *= 2) expectedNodes += Math.floor(messages / span);
    expect(liveAfter.size).toBe(expectedNodes);
    await memory.dispose();
  }, 120_000);

  it("repairs a catalog revision whose invalidation a crash lost", async () => {
    // Build once so the child reaches only the edit's invalidation. The exact
    // append hook below, rather than tree size or a polling race, owns the crash.
    const fx = await fixture("window", 600);
    const prebuild = new TronWorkspace(fx.home);
    owners.push(prebuild);
    const prebuilt = await EpisodicMemory.open({
      workspace: prebuild,
      sessionId: fx.sessionId,
      sessionFile: fx.sessionFile,
      summarizer: stubSummarizer,
      limits: { viewBytes: 4_096, jobs: 4, retryMs: 1 },
      sleep: async () => {},
    });
    await prebuilt.entriesCommitted(fx.sessionId);
    expect(prebuilt.status().view.unbuilt).toBe(0);
    await prebuilt.dispose();
    // Release the workspace lock the pre-build took: the child owns this
    // installation while it runs.
    await prebuild.dispose();

    const marker = join(fx.root, "commit-marker");
    const { program, hook } = await writeChildProgram(fx, marker);
    const editedText = "edited in the crash window";
    const target = fx.manager.getBranch().filter(entry => entry.type === "message")[2]!;
    const child = spawn(process.execPath, ["--experimental-transform-types", "--import", hook, program, fx.home, fx.sessionFile, fx.sessionId, marker], { stdio: ["ignore", "pipe", "pipe"] });
    children.push(child);
    const exited = new Promise<{ code: number | null; signal: NodeJS.Signals | null }>(resolve => {
      child.once("exit", (code, signal) => resolve({ code, signal }));
    });
    let output = "";
    child.stdout.on("data", (chunk: Buffer) => { output += chunk.toString(); });
    child.stderr.on("data", (chunk: Buffer) => { output += chunk.toString(); });
    await waitForChildLine(child, "ready", () => output);
    fx.manager.appendContextEdit(target.id, { content: editedText });
    await writeFile(marker, "go", "utf8");
    await waitForChildLine(child, "invalidation-window", () => output);
    // Deliberately delay the observer: the child must remain parked, not exit
    // naturally while the parent is descheduled after receiving its signal.
    await new Promise(resolve => setTimeout(resolve, 100));
    expect(child.exitCode, "child exited before the parent could kill it").toBeNull();
    expect(readFileSync(fx.catalogPath, "utf8")).toContain(editedText);
    expect(readFileSync(fx.nodesPath, "utf8")).not.toContain("\"nodes\":");
    expect(child.kill("SIGKILL")).toBe(true);
    const exit = await awaitsWithin(exited, "crash-window child to exit after SIGKILL");
    expect(exit.signal).toBe("SIGKILL");

    // The window really is the inconsistent state: the live leaf's recorded
    // source digest no longer matches the catalog record it summarizes.
    const editedRecord = [...new Map(records(await readFile(fx.catalogPath, "utf8")).map(record => [record.index as number, record])).values()]
      .find(record => record.text === editedText)!;
    expect(editedRecord).toBeDefined();
    const lock = join(fx.home, "gateway", "workspace-state.lock");
    const past = new Date(Date.now() - 120_000);
    await utimes(lock, past, past);
    const before = liveNodes((await readPersistedState(fx)).nodes);
    const leafBefore = before.get(`${editedRecord.index}+1`)!;
    expect(leafBefore).toBeDefined();
    expect(leafBefore.kind).not.toBe("free");

    const memory = await openMemory(fx);
    // open() repaired it: the generation moved and the stale leaf is revoked
    // before the pump rebuilds it.
    expect(memory.status().generation).toBeGreaterThan(0);
    const liveMemoryNodes = (): Array<Record<string, unknown>> => [...(memory as unknown as { nodes: Map<string, Record<string, unknown>> }).nodes.values()];
    expect(liveNodes(liveMemoryNodes()).get(`${editedRecord.index}+1`)).toBeUndefined();
    await memory.entriesCommitted(fx.sessionId);
    const leafAfter = liveNodes(liveMemoryNodes()).get(`${editedRecord.index}+1`)!;
    expect(leafAfter).toBeDefined();
    expect(leafAfter.sourceDigest).not.toBe(leafBefore.sourceDigest);
    expect(memory.status().blocked).toBeNull();
    expect(memory.status().view.unbuilt).toBe(0);
    assertConsistentStore(liveMemoryNodes(), memory.status().messages);
    await memory.dispose();
  }, 180_000);

  it("discards a torn trailing record, truncates it, and appends the next record on its own line", async () => {
    const fx = await fixture("torn", 4);
    const first = await openMemory(fx);
    await first.entriesCommitted(fx.sessionId);
    const complete = (await readPersistedState(fx)).nodes;
    await first.dispose();

    // A crash mid-write leaves a partial line. It was never acknowledged, so it
    // is discarded; it must never be concatenated with the next append.
    const torn = `{"revision": 99999, "level": 0, "index": 0, "kind": "summary", "text": "partial`;
    await appendFile(fx.nodesPath, torn);
    const reopened = await openMemory(fx);
    expect(reopened.status().nodes.total).toBe(complete.length);
    expect(fx.diagnostics.some(record => record.event === "episodic.store-recovered" && record.counts?.bytes === torn.length)).toBe(true);
    const recovered = await readPersistedState(fx);
    expect(recovered.nodes).toHaveLength(complete.length);
    expect(JSON.stringify(recovered)).not.toContain("partial");
    expect(JSON.stringify(recovered)).not.toContain("99999");
    // The store continues to work after the torn record was dropped.
    await reopened.entriesCommitted(fx.sessionId);
    expect(reopened.status().blocked).toBeNull();
    expect(reopened.status().view.unbuilt).toBe(0);
    await reopened.dispose();
  }, 120_000);

  it("refuses a corrupt record visibly instead of skipping it", async () => {
    const fx = await fixture("corrupt", 2);
    const memory = await openMemory(fx);
    await memory.entriesCommitted(fx.sessionId);
    await memory.dispose();
    await appendFile(fx.nodesPath, `{"revision": 424242, "level": 0}\n`);
    await expect(openMemory(fx)).rejects.toBeInstanceOf(EpisodicMemoryError);
    expect(fx.diagnostics.some(record => record.event === "episodic.store-refused")).toBe(true);
  }, 120_000);

  it("waits for an ingest that is still writing before it releases the store", async () => {
    // A commit's ingest holds the memory's mutex while it appends and fsyncs one
    // catalog record per message. A reconfiguration closes that store, so dispose
    // must not release the opener until the ingest has finished: a second opener
    // over a store that is still being written is the one thing it cannot survive,
    // and a closed store must never be written after it was closed.
    const fx = await fixture("dispose-ingest", 0);
    const memory = await openMemory(fx);
    for (let index = 0; index < 300; index += 1) {
      fx.manager.appendMessage({ role: "user", content: `pending ${index}`, timestamp: Date.now() } satisfies Message);
    }
    // Not awaited: the ingest is inside the mutex when dispose runs.
    const ingest = memory.entriesIngested(fx.sessionId);
    await memory.dispose();
    const atDispose = (await readPersistedState(fx)).catalog.length;
    await ingest.catch(() => {});
    // Nothing was appended after the store was closed...
    expect((await readPersistedState(fx)).catalog.length).toBe(atDispose);
    // ...because the ingest it owed had already finished when dispose returned.
    expect(atDispose).toBe(300);
    // The opener is released, so the next owner reads the store it closed.
    const reopened = await openMemory(fx);
    await reopened.entriesCommitted(fx.sessionId);
    expect(reopened.status().messages).toBe(300);
    await reopened.dispose();
  }, 180_000);

  it("refuses a deleted container, an unknown version and a second opener, and keeps every store path owner-only", async () => {
    const fx = await fixture("version", 2);
    const memory = await openMemory(fx);
    await memory.entriesCommitted(fx.sessionId);
    // A second in-process opener would write the same files without a lock.
    await expect(openMemory(fx)).rejects.toThrowError(/already open/u);
    await memory.dispose();
    // The marker is what makes a deleted container lost state rather than a
    // fresh installation that re-spends every compactor call.
    const reopened = await openMemory(fx);
    await reopened.dispose();
    const featureRecord = join(fx.home, "gateway/workspace-state/episodic-initialized.json");
    await writeFile(featureRecord, '{"version":2}', { mode: 0o600 });
    await expect(openMemory(fx)).rejects.toMatchObject({ kind: "invalid-store" });
    await rm(dirname(fx.storeRoot), { recursive: true });
    await expect(openMemory(fx)).rejects.toMatchObject({ kind: "invalid-store" });
    await writeFile(featureRecord, '{"version":1}', { mode: 0o600 });
    await expect(openMemory(fx)).rejects.toThrowError(/container is missing/u);

    const fresh = await fixture("version-2", 2);
    const freshMemory = await openMemory(fresh);
    await freshMemory.entriesCommitted(fresh.sessionId);
    await freshMemory.dispose();
    const statePath = join(fresh.storeRoot, "state.json");
    const state = JSON.parse(await readFile(statePath, "utf8")) as Record<string, unknown>;
    await writeFile(statePath, JSON.stringify({ ...state, version: 99 }), { mode: 0o600 });
    await expect(openMemory(fresh)).rejects.toThrowError(/unknown version/u);
    await writeFile(statePath, JSON.stringify({ ...state, blocked: { reason: "not-a-reason" } }), { mode: 0o600 });
    await expect(openMemory(fresh)).rejects.toThrowError(/invalid blocked state/u);
    await writeFile(statePath, JSON.stringify(state), { mode: 0o600 });

    for (const path of [fresh.storeRoot, join(fresh.home, "workspace", "state"), join(fresh.home, "workspace", "state", "episodic")]) {
      expect((await lstat(path)).mode & 0o777).toBe(0o700);
    }
    for (const path of [fresh.nodesPath, fresh.catalogPath, statePath, join(fresh.storeRoot, "initialized.json")]) {
      const info = await lstat(path);
      expect(info.mode & 0o077, `${path} must be owner-only`).toBe(0);
      expect((info.mode & constants.S_IFMT) === constants.S_IFREG).toBe(true);
    }
  }, 120_000);
});
