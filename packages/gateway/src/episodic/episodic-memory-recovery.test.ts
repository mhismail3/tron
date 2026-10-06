import { spawn } from "node:child_process";
import { constants } from "node:fs";
import { appendFile, lstat, mkdir, mkdtemp, readFile, rm, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it } from "vitest";
import { fauxAssistantMessage, type Message } from "@earendil-works/pi-ai";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { createEpisodicTokenBudget, EpisodicMemoryError, type EpisodicDiagnostic, type EpisodicSummarizer } from "./episodic-contract.js";
import { EpisodicMemory } from "./episodic-memory.js";

/*
 * Crash and store recovery: a child process is SIGKILLed while it is writing
 * nodes, and the parent must be able to reopen the store, prove it is
 * consistent, resume the pump and refold a valid view. The same test covers the
 * two store boundaries that can be seen without a crash: a torn trailing record
 * (discarded, because it was never acknowledged) and a corrupt record (refused
 * visibly, never skipped).
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

interface RecoveryFixture {
  root: string;
  home: string;
  sessionFile: string;
  sessionId: string;
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
    root, home, sessionFile, sessionId, workspace, storeRoot,
    nodesPath: join(storeRoot, "nodes.jsonl"),
    catalogPath: join(storeRoot, "catalog.jsonl"),
    diagnostics: [],
  };
}

async function openMemory(fx: RecoveryFixture): Promise<EpisodicMemory> {
  return EpisodicMemory.open({
    workspace: fx.workspace,
    sessionId: fx.sessionId,
    sessionFile: fx.sessionFile,
    budget: createEpisodicTokenBudget(500_000_000),
    summarizer: stubSummarizer,
    limits: { viewBytes: 4_096, jobs: 4, retryMs: 1 },
    diagnostic: record => fx.diagnostics.push(record),
    sleep: async () => {},
  });
}

function records(text: string): Array<Record<string, unknown>> {
  return text.split("\n").filter(line => line.trim() !== "").map(line => JSON.parse(line) as Record<string, unknown>);
}

async function readRecords(path: string): Promise<Array<Record<string, unknown>>> {
  try {
    return records(await readFile(path, "utf8"));
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return [];
    throw error;
  }
}

interface LiveNode { revision: number; level: number; index: number; kind: string; childRevisions?: [number, number] }

function liveNodes(log: Array<Record<string, unknown>>): Map<string, LiveNode> {
  const live = new Map<string, LiveNode>();
  for (const record of log) {
    if (Array.isArray(record.addresses)) {
      for (const address of record.addresses as string[]) live.delete(address);
      continue;
    }
    live.set(`${(record.index as number) * 2 ** (record.level as number)}+${2 ** (record.level as number)}`, record as unknown as LiveNode);
  }
  return live;
}

function assertConsistentStore(log: Array<Record<string, unknown>>, messages: number): Map<string, LiveNode> {
  const revisions = log.filter(record => !Array.isArray(record.addresses)).map(record => record.revision as number);
  expect(new Set(revisions).size).toBe(revisions.length);
  const live = liveNodes(log);
  for (const [address, node] of live) {
    const span = 2 ** node.level;
    if (node.level === 0) {
      expect(node.index).toBeLessThan(messages);
      continue;
    }
    expect((node.index + 1) * span).toBeLessThanOrEqual(messages);
    const childA = live.get(`${node.index * 2 * 2 ** (node.level - 1)}+${2 ** (node.level - 1)}`)!;
    const childB = live.get(`${(node.index * 2 + 1) * 2 ** (node.level - 1)}+${2 ** (node.level - 1)}`)!;
    expect(childA, `${address} has no first child`).toBeDefined();
    expect(childB, `${address} has no second child`).toBeDefined();
    expect(node.childRevisions).toEqual([childA.revision, childB.revision]);
  }
  return live;
}

async function writeChildProgram(fx: RecoveryFixture): Promise<{ program: string; hook: string }> {
  const program = join(fx.root, "child.mjs");
  const hook = join(fx.root, "hook.mjs");
  await writeFile(hook, `import { registerHooks } from "node:module";\nimport { pathToFileURL } from "node:url";\nregisterHooks({\n  resolve(specifier, context, nextResolve) {\n    try { return nextResolve(specifier, context); }\n    catch (error) {\n      if (specifier.endsWith(".js")) return nextResolve(specifier.slice(0, -3) + ".ts", context);\n      throw error;\n    }\n  },\n});\nawait import(pathToFileURL(process.argv[1]).href);\n`, "utf8");
  await writeFile(program, `import { EpisodicMemory } from ${JSON.stringify(EPISODIC_MEMORY_MODULE)};\nimport { createEpisodicTokenBudget } from ${JSON.stringify(CONTRACT_MODULE)};\nimport { TronWorkspace } from ${JSON.stringify(WORKSPACE_MODULE)};\n\nconst [home, sessionFile, sessionId] = process.argv.slice(2);\nconst zero = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };\nconst workspace = new TronWorkspace(home);\nconst memory = await EpisodicMemory.open({\n  workspace, sessionId, sessionFile,\n  budget: createEpisodicTokenBudget(500000000),\n  limits: { viewBytes: 4096, jobs: 4, retryMs: 1 },\n  summarizer: async (request) => {\n    await new Promise(resolve => setTimeout(resolve, 20));\n    const last = request.turns[request.turns.length - 1].text.replace(/\\s+/g, " ").trim().slice(-200);\n    return { role: "assistant", content: [{ type: "text", text: last }], api: "faux", provider: "faux", model: "child", usage: zero, stopReason: "stop", timestamp: Date.now() };\n  },\n  sleep: async () => {},\n});\nprocess.stdout.write("ready\\n");\nawait memory.entriesCommitted(sessionId);\nprocess.stdout.write("done\\n");\n`, "utf8");
  return { program, hook };
}

async function waitForFileGrowth(path: string, lines: number, timeoutMs: number): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    if ((await readRecords(path)).length >= lines) return;
    if (Date.now() > deadline) throw new Error(`store did not reach ${lines} records`);
    await new Promise(resolve => setTimeout(resolve, 10));
  }
}

describe("episodic memory crash recovery", () => {
  it("reopens a store a killed child was writing, proves it consistent, and refolds a valid view", async () => {
    const fx = await fixture("sigkill", 60);
    const { program, hook } = await writeChildProgram(fx);
    const child = spawn(process.execPath, ["--experimental-transform-types", "--import", hook, program, fx.home, fx.sessionFile, fx.sessionId], { stdio: ["ignore", "pipe", "pipe"] });
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
    expect(output).toContain("ready");
    // The killed owner's workspace lock is only taken over once it is stale;
    // age it instead of waiting out the 60 s staleness window.
    const lock = join(fx.home, "gateway", "workspace-state.lock");
    const past = new Date(Date.now() - 120_000);
    await utimes(lock, past, past);

    const catalog = await readRecords(fx.catalogPath);
    const messages = catalog.length;
    expect(messages).toBe(120);
    const log = await readRecords(fx.nodesPath);
    expect(log.length).toBeGreaterThan(0);
    const liveBefore = assertConsistentStore(log, messages);

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
    const liveAfter = assertConsistentStore(await readRecords(fx.nodesPath), messages);
    expect(liveAfter.size).toBeGreaterThanOrEqual(liveBefore.size);
    // Every node whose whole range exists: one per level per full span.
    let expectedNodes = 0;
    for (let span = 1; span <= messages; span *= 2) expectedNodes += Math.floor(messages / span);
    expect(liveAfter.size).toBe(expectedNodes);
    await memory.dispose();
  }, 120_000);

  it("discards a torn trailing record, truncates it, and appends the next record on its own line", async () => {
    const fx = await fixture("torn", 4);
    const first = await openMemory(fx);
    await first.entriesCommitted(fx.sessionId);
    const complete = await readRecords(fx.nodesPath);
    await first.dispose();

    // A crash mid-write leaves a partial line. It was never acknowledged, so it
    // is discarded; it must never be concatenated with the next append.
    const torn = `{"revision": 99999, "level": 0, "index": 0, "kind": "summary", "text": "partial`;
    await appendFile(fx.nodesPath, torn);
    const reopened = await openMemory(fx);
    expect(reopened.status().nodes.total).toBe(complete.filter(record => !Array.isArray(record.addresses)).length);
    expect(fx.diagnostics.some(record => record.event === "episodic.store-recovered" && record.counts?.bytes === torn.length)).toBe(true);
    const raw = await readFile(fx.nodesPath, "utf8");
    expect(raw.endsWith("\n")).toBe(true);
    expect(raw).not.toContain("partial");
    expect(raw).not.toContain("99999");
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

  it("refuses an unknown store version and keeps every store path owner-only", async () => {
    const fx = await fixture("version", 2);
    const memory = await openMemory(fx);
    await memory.entriesCommitted(fx.sessionId);
    await memory.dispose();
    const statePath = join(fx.storeRoot, "state.json");
    const state = JSON.parse(await readFile(statePath, "utf8")) as Record<string, unknown>;
    await writeFile(statePath, JSON.stringify({ ...state, version: 99 }), { mode: 0o600 });
    await expect(openMemory(fx)).rejects.toThrowError(/unknown version/u);

    for (const path of [fx.storeRoot, join(fx.home, "workspace", "state"), join(fx.home, "workspace", "state", "episodic")]) {
      expect((await lstat(path)).mode & 0o777).toBe(0o700);
    }
    for (const path of [fx.nodesPath, fx.catalogPath, statePath, join(fx.storeRoot, "initialized.json")]) {
      const info = await lstat(path);
      expect(info.mode & 0o077, `${path} must be owner-only`).toBe(0);
      expect((info.mode & constants.S_IFMT) === constants.S_IFREG).toBe(true);
    }
  }, 120_000);
});
