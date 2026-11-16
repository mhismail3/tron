import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { mkdir, mkdtemp, readFile, rm, symlink, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it } from "vitest";
import { fauxAssistantMessage, type Message } from "@earendil-works/pi-ai";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import {
  EPISODIC_DEFAULTS,
  type EpisodicDiagnostic, type EpisodicLimits, type EpisodicSummarizer,
} from "./episodic-contract.js";
import { EpisodicMemory } from "./episodic-memory.js";
import { EpisodicStore } from "./episodic-store.js";
import { awaitsWithin, waitFor } from "../../test-support/wait-for.js";

import { singleChapterSource } from "../../test-support/episodic-chapter-source.js";
const EPISODIC_MEMORY_MODULE = fileURLToPath(new URL("./episodic-memory.ts", import.meta.url));
const WORKSPACE_MODULE = fileURLToPath(new URL("../workspace/tron-workspace.ts", import.meta.url));
const CHAPTER_SOURCE_MODULE = fileURLToPath(new URL("../../test-support/episodic-chapter-source.ts", import.meta.url));

const roots: string[] = [];
const owners: TronWorkspace[] = [];
const children: Array<ReturnType<typeof spawn>> = [];
afterEach(async () => {
  for (const child of children.splice(0)) child.kill("SIGKILL");
  await Promise.all(owners.splice(0).map(owner => owner.dispose()));
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })));
});

const stubSummarizer: EpisodicSummarizer = async (request) => {
  const last = request.turns.at(-1)!;
  return fauxAssistantMessage(last.text.replace(/\s+/gu, " ").trim().slice(-200));
};


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
    sessionSource: singleChapterSource(fx.sessionId, fx.sessionFile),
    summarizer,
    limits: { viewBytes: 4_096, jobs: 4, retryMs: 0, ...limits },
    diagnostic: record => fx.diagnostics.push(record),
  });
}

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

async function writeChildProgram(fx: RecoveryFixture): Promise<{ program: string; hook: string }> {
  const program = join(fx.root, "child.mjs");
  const hook = join(fx.root, "hook.mjs");
  await writeFile(hook, `import { registerHooks } from "node:module";\nimport { pathToFileURL } from "node:url";\nregisterHooks({\n  resolve(specifier, context, nextResolve) {\n    try { return nextResolve(specifier, context); }\n    catch (error) {\n      if (specifier.endsWith(".js")) return nextResolve(specifier.slice(0, -3) + ".ts", context);\n      throw error;\n    }\n  },\n});\nawait import(pathToFileURL(process.argv[1]).href);\n`, "utf8");
  await writeFile(program, `import { existsSync } from "node:fs";\nimport { EpisodicMemory } from ${JSON.stringify(EPISODIC_MEMORY_MODULE)};\nimport { singleChapterSource } from ${JSON.stringify(CHAPTER_SOURCE_MODULE)};\nimport { TronWorkspace } from ${JSON.stringify(WORKSPACE_MODULE)};\n\nconst [home, sessionFile, sessionId, marker] = process.argv.slice(2);\nconst zero = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };\nconst workspace = new TronWorkspace(home);\nconst memory = await EpisodicMemory.open({\n  workspace, sessionId, sessionSource: singleChapterSource(sessionId, sessionFile),\n  limits: { viewBytes: 4096, jobs: 4, retryMs: 0 },\n  summarizer: async (request) => {\n    const last = request.turns[request.turns.length - 1].text.replace(/\\s+/g, " ").trim().slice(-200);\n    return { role: "assistant", content: [{ type: "text", text: last }], api: "faux", provider: "faux", model: "child", usage: zero, stopReason: "stop", timestamp: Date.now() };\n  },\n  \n});\nawait memory.entriesCommitted(sessionId);\nprocess.stdout.write("ready\\n");\n// The parent appends the edit and then drops this marker. Intercept the exact\n// invalidation append, after the catalog revision is durable and before it lands.\nfor (;;) {\n  if (existsSync(marker)) break;\n  await new Promise(resolve => setTimeout(resolve, 1));\n}\nconst owner = memory;\nconst append = owner.store.appendNode.bind(owner.store);\nowner.store.appendNode = async record => {\n  if (record.nodes) {\n    process.stdout.write("invalidation-window\\n");\n    // The unresolved await alone does not keep Node alive; retain a live handle\n    // so the parent can observe the exact crash window even when descheduled.\n    setInterval(() => {}, 1_000);\n    await new Promise(() => {});\n  }\n  await append(record);\n};\nawait memory.entriesCommitted(sessionId);\nprocess.stdout.write("done\\n");\n`, "utf8");
  return { program, hook };
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
  it("keeps the token spend a killed child had already recorded", async () => {
    const fx = await fixture("spend-crash", 12);
    const hook = join(fx.root, "hook.mjs");
    const program = join(fx.root, "spend-child.mjs");
    await writeFile(hook, `import { registerHooks } from "node:module";\nimport { pathToFileURL } from "node:url";\nregisterHooks({\n  resolve(specifier, context, nextResolve) {\n    try { return nextResolve(specifier, context); }\n    catch (error) {\n      if (specifier.endsWith(".js")) return nextResolve(specifier.slice(0, -3) + ".ts", context);\n      throw error;\n    }\n  },\n});\nawait import(pathToFileURL(process.argv[1]).href);\n`, "utf8");
    await writeFile(program, `import { EpisodicMemory } from ${JSON.stringify(EPISODIC_MEMORY_MODULE)};\nimport { singleChapterSource } from ${JSON.stringify(CHAPTER_SOURCE_MODULE)};\nimport { TronWorkspace } from ${JSON.stringify(WORKSPACE_MODULE)};\n\nconst [home, sessionFile, sessionId] = process.argv.slice(2);\nconst usage = { input: 80, output: 20, cacheRead: 0, cacheWrite: 0, totalTokens: 100, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };\nconst workspace = new TronWorkspace(home);\nconst memory = await EpisodicMemory.open({\n  workspace, sessionId, sessionSource: singleChapterSource(sessionId, sessionFile),\n  limits: { viewBytes: 4096, jobs: 1, retryMs: 0 },\n  summarizer: async (request) => ({\n    role: "assistant", content: [{ type: "text", text: \`spend line \${request.turns.length}\` }],\n    api: "faux", provider: "faux", model: "child", usage, stopReason: "stop", timestamp: Date.now(),\n  }),\n  \n});\nprocess.stdout.write("opened\\n");\nawait memory.entriesCommitted(sessionId);\nprocess.stdout.write(\`spent \${memory.status().tokens.used}\\n\`);\nfor (;;) await new Promise(resolve => setTimeout(resolve, 5));\n`, "utf8");
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
    const lock = join(fx.home, "state", "workspace-state.lock");
    const past = new Date(Date.now() - 120_000);
    await utimes(lock, past, past);

    const reopened = await EpisodicMemory.open({
      workspace: fx.workspace,
      sessionId: fx.sessionId,
      sessionSource: singleChapterSource(fx.sessionId, fx.sessionFile),
      summarizer: stubSummarizer,
      limits: { viewBytes: 4_096, jobs: 4, retryMs: 0 },
    });
    const reopenedUsed = reopened.status().tokens.used;
    expect(durableSpend).toBeGreaterThanOrEqual(100);
    expect(reopenedUsed).toBeGreaterThanOrEqual(durableSpend);
    await reopened.dispose();

    const again = await EpisodicMemory.open({
      workspace: fx.workspace,
      sessionId: fx.sessionId,
      sessionSource: singleChapterSource(fx.sessionId, fx.sessionFile),
      summarizer: stubSummarizer,
      limits: { viewBytes: 4_096, jobs: 4, retryMs: 0 },
    });
    expect(again.status().tokens.used).toBe(reopenedUsed);
    expect(again.status().blocked).toBeNull();
    await again.dispose();
  }, 120_000);

  it("reopens a store a killed child was writing, proves it consistent, and refolds a valid view", async () => {
    const fx = await fixture("sigkill", 60);
    const marker = join(fx.root, "commit-marker");
    const { program, hook } = await writeChildProgram(fx);
    const child = spawn(process.execPath, ["--experimental-transform-types", "--import", hook, program, fx.home, fx.sessionFile, fx.sessionId, marker], { stdio: ["ignore", "pipe", "pipe"] });
    children.push(child);
    let output = "";
    child.stdout.on("data", (chunk: Buffer) => { output += chunk.toString(); });
    child.stderr.on("data", (chunk: Buffer) => { output += chunk.toString(); });
    try {
      await waitForFileGrowth(fx.nodesPath, 8, 30_000);
    } catch (error) {
      throw new Error(`${(error as Error).message}; child output: ${output}`);
    }
    child.kill("SIGKILL");
    await new Promise(resolve => child.once("exit", resolve));
    expect(output).not.toContain("done");
    expect(output).not.toContain("Error");
    const lock = join(fx.home, "state", "workspace-state.lock");
    const past = new Date(Date.now() - 120_000);
    await utimes(lock, past, past);

    const persistedBefore = await readPersistedState(fx);
    const messages = persistedBefore.catalog.length;
    expect(messages).toBe(120);
    const liveBefore = assertConsistentStore(persistedBefore.nodes, messages);

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
    const liveAfter = assertConsistentStore((await readPersistedState(fx)).nodes, messages);
    expect(liveAfter.size).toBeGreaterThanOrEqual(liveBefore.size);
    await memory.dispose();
  }, 120_000);

  it("repairs a catalog revision whose invalidation a crash lost", async () => {
    const fx = await fixture("window", 24);
    const prebuild = new TronWorkspace(fx.home);
    owners.push(prebuild);
    const prebuilt = await EpisodicMemory.open({
      workspace: prebuild,
      sessionId: fx.sessionId,
      sessionSource: singleChapterSource(fx.sessionId, fx.sessionFile),
      summarizer: stubSummarizer,
      limits: { viewBytes: 4_096, jobs: 4, retryMs: 0 },
    });
    await prebuilt.entriesCommitted(fx.sessionId);
    expect(prebuilt.status().view.unbuilt).toBe(0);
    await prebuilt.dispose();
    await prebuild.dispose();

    const marker = join(fx.root, "commit-marker");
    const { program, hook } = await writeChildProgram(fx);
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
    await new Promise(resolve => setTimeout(resolve, 100));
    expect(child.exitCode, "child exited before the parent could kill it").toBeNull();
    expect(readFileSync(fx.catalogPath, "utf8")).toContain(editedText);
    expect(readFileSync(fx.nodesPath, "utf8")).not.toContain("\"nodes\":");
    expect(child.kill("SIGKILL")).toBe(true);
    const exit = await awaitsWithin(exited, "crash-window child to exit after SIGKILL");
    expect(exit.signal).toBe("SIGKILL");

    const editedRecord = [...new Map(records(await readFile(fx.catalogPath, "utf8")).map(record => [record.index as number, record])).values()]
      .find(record => record.text === editedText)!;
    expect(editedRecord).toBeDefined();
    const lock = join(fx.home, "state", "workspace-state.lock");
    const past = new Date(Date.now() - 120_000);
    await utimes(lock, past, past);
    const before = liveNodes((await readPersistedState(fx)).nodes);
    const leafBefore = before.get(`${editedRecord.index}+1`)!;
    expect(leafBefore).toBeDefined();
    expect(leafBefore.kind).not.toBe("free");

    const memory = await openMemory(fx);
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
});

const FROZEN_LIMITS = { viewBytes: 4_096, jobs: 4, retryMs: 0 };
const KILL_POINTS = [
  "catalog:before", "catalog:after", "node:before", "node:after", "invalidation:before", "invalidation:after",
  "state:before", "layout:before", "layout:after", "checkpoint:before", "checkpoint:after",
] as const;

async function frozenRecoveryFixture(label: string, pairs: number): Promise<RecoveryFixture> {
  const fx = await fixture(label, 1);
  const prebuild = new TronWorkspace(fx.home);
  const memory = await openMemory({ ...fx, workspace: prebuild }, stubSummarizer, FROZEN_LIMITS);
  try { await memory.entriesCommitted(fx.sessionId); } finally { await memory.dispose(); await prebuild.dispose(); }
  await writeFile(join(fx.storeRoot, "layout.json"), `${JSON.stringify({ lines: [] })}\n`, { mode: 0o600, flag: "wx" });
  for (let index = 1; index < pairs; index += 1) {
    fx.manager.appendMessage({ role: "user", content: `recovery prompt ${index} ${"r".repeat(700)}`, timestamp: Date.now() } satisfies Message);
    fx.manager.appendMessage(fauxAssistantMessage([{ type: "text", text: `recovery reply ${index} ${"s".repeat(700)}` }]));
  }
  return fx;
}

async function layoutLines(fx: RecoveryFixture): Promise<Array<[number, number, string]>> {
  return (JSON.parse(await readFile(join(fx.storeRoot, "layout.json"), "utf8")) as { lines: Array<[number, number, string]> }).lines;
}

async function sha256File(path: string): Promise<string> {
  return createHash("sha256").update(await readFile(path)).digest("hex");
}

async function releaseCrashedLock(fx: RecoveryFixture): Promise<void> {
  const past = new Date(Date.now() - 120_000);
  await utimes(join(fx.home, "state", "workspace-state.lock"), past, past);
}

async function assertRecoveredView(fx: RecoveryFixture, memory: EpisodicMemory, messages: number): Promise<string> {
  await memory.entriesCommitted(fx.sessionId);
  await memory.whenReady(messages);
  const status = memory.status();
  expect(status.blocked).toBeNull();
  expect(status.messages).toBe(messages);
  expect(status.view.unbuilt).toBe(0);
  let cursor = 0;
  for (const part of status.view.parts) {
    expect(part.start, "the view covers every message once, in order").toBe(cursor);
    cursor += part.messages;
  }
  expect(cursor).toBe(messages);
  const nodes = (await readPersistedState(fx)).nodes;
  assertConsistentStore(nodes, messages);
  const live = liveNodes(nodes) as unknown as Map<string, { text: string }>;
  const rendered = memory.renderView(messages).text;
  for (const part of status.view.parts) if (part.messages > 1) expect(rendered).toContain(live.get(part.address)!.text.replace(/\n+/gu, " "));
  return rendered;
}

async function writeFrozenChildProgram(fx: RecoveryFixture): Promise<{ program: string; hook: string }> {
  const { hook } = await writeChildProgram(fx);
  const program = join(fx.root, "frozen-child.mjs");
  await writeFile(program, `import { existsSync } from "node:fs";
import { EpisodicMemory } from ${JSON.stringify(EPISODIC_MEMORY_MODULE)};
import { singleChapterSource } from ${JSON.stringify(CHAPTER_SOURCE_MODULE)};
import { TronWorkspace } from ${JSON.stringify(WORKSPACE_MODULE)};
const [home, sessionFile, sessionId, marker, point] = process.argv.slice(2);
const zero = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
const memory = await EpisodicMemory.open({
  workspace: new TronWorkspace(home), sessionId, sessionSource: singleChapterSource(sessionId, sessionFile),
  limits: ${JSON.stringify(FROZEN_LIMITS)},
  summarizer: async (request) => {
    const last = request.turns[request.turns.length - 1].text.replace(/\\s+/g, " ").trim().slice(-200);
    return { role: "assistant", content: [{ type: "text", text: last }], api: "faux", provider: "faux", model: "child", usage: zero, stopReason: "stop", timestamp: Date.now() };
  },
});
await memory.entriesCommitted(sessionId);
await memory.whenReady(memory.status().messages);
process.stdout.write("ready\\n");
while (!existsSync(marker)) await new Promise(resolve => setTimeout(resolve, 1));
const [kind, when] = point.split(":");
const store = memory.store;
const kill = () => { process.stdout.write("killed\\n"); process.kill(process.pid, "SIGKILL"); };
const wrap = (name, matches) => {
  const original = store[name].bind(store);
  store[name] = async (...args) => {
    const hit = matches(...args);
    if (hit && when === "before") kill();
    const result = await original(...args);
    if (hit && when === "after") kill();
    return result;
  };
};
if (kind === "catalog") wrap("appendCatalog", () => true);
if (kind === "node") wrap("appendNode", record => !("nodes" in record));
if (kind === "invalidation") wrap("appendNode", record => "nodes" in record);
const target = { state: "state.json", layout: "layout.json", checkpoint: "checkpoint.current.json" }[kind];
if (target) {
  const fileSystem = { ...store.fileSystem };
  const rename = fileSystem.rename;
  fileSystem.rename = async (from, to) => {
    const hit = String(to).endsWith("/" + target);
    if (hit && when === "before") kill();
    await rename(from, to);
    if (hit && when === "after") kill();
  };
  store.fileSystem = fileSystem;
  if (kind === "checkpoint") store.shouldCheckpoint = async () => true;
}
await memory.entriesCommitted(sessionId);
process.stdout.write("done\\n");
`, "utf8");
  return { program, hook };
}

describe("frozen layout recovery", () => {
  it.each(KILL_POINTS)("kills a frozen memory at %s and reopens it with history intact and a valid view", async (point) => {
    const fx = await frozenRecoveryFixture(`kill-${point.replace(":", "-")}`, 70);
    const marker = join(fx.root, "commit-marker");
    const { program, hook } = await writeFrozenChildProgram(fx);
    const child = spawn(process.execPath, ["--experimental-transform-types", "--import", hook, program, fx.home, fx.sessionFile, fx.sessionId, marker, point], { stdio: ["ignore", "pipe", "pipe"] });
    children.push(child);
    const exited = new Promise<{ code: number | null; signal: NodeJS.Signals | null }>(resolve => child.once("exit", (code, signal) => resolve({ code, signal })));
    let output = "";
    child.stdout.on("data", (chunk: Buffer) => { output += chunk.toString(); });
    child.stderr.on("data", (chunk: Buffer) => { output += chunk.toString(); });
    await waitForChildLine(child, "ready", () => output);

    const before = await layoutLines(fx);
    const frozen = before.find(([, span]) => span >= 64);
    expect(frozen, "the base view holds a settled line").toBeDefined();
    const editedIndex = frozen![0] + 2;
    const target = fx.manager.getBranch().filter(entry => entry.type === "message")[editedIndex]!;
    const editedText = `edited inside a frozen line at ${point}`;
    fx.manager.appendContextEdit(target.id, { content: editedText });
    for (let index = 0; index < 3; index += 1) {
      fx.manager.appendMessage({ role: "user", content: `after crash ${index} ${"a".repeat(700)}`, timestamp: Date.now() } satisfies Message);
      fx.manager.appendMessage(fauxAssistantMessage([{ type: "text", text: `after reply ${index} ${"b".repeat(700)}` }]));
    }
    const history = await sha256File(fx.sessionFile);
    await writeFile(marker, "go", "utf8");
    const exit = await awaitsWithin(exited, `child to reach ${point}`);
    expect(output, `the kill point ${point} was reached`).toContain("killed");
    expect(output).not.toContain("done");
    expect(exit.signal).toBe("SIGKILL");
    await releaseCrashedLock(fx);

    const messages = 146;
    const memory = await openMemory(fx, stubSummarizer, FROZEN_LIMITS);
    let rendered: string;
    try {
      rendered = await assertRecoveredView(fx, memory, messages);
      expect(memory.zoomLines(editedIndex, 1)![0]).toContain(editedText);
    } finally { await memory.dispose(); }
    expect(await sha256File(fx.sessionFile), "memory never writes canonical history").toBe(history);
    const saved = await layoutLines(fx);
    expect(saved.reduce((cursor, [start, span]) => { expect(start).toBe(cursor); return cursor + span; }, 0)).toBe(messages);
    for (const [start, span] of before) {
      if (span >= 64 && (editedIndex < start || editedIndex >= start + span)) expect(saved.some(line => line[0] === start && line[1] === span), `frozen line ${start}+${span} survives`).toBe(true);
    }

    fx.diagnostics.length = 0;
    const again = await openMemory(fx, stubSummarizer, FROZEN_LIMITS);
    try {
      expect(again.renderView(messages).text, "the saved layout reopens byte-identically").toBe(rendered);
      expect(fx.diagnostics.filter(record => record.event === "episodic.layout-rebuilt")).toEqual([]);
    } finally { await again.dispose(); }
  }, 180_000);

  it("rebuilds a corrupt, truncated, oversized or misshapen layout from history without touching it", async () => {
    const fx = await frozenRecoveryFixture("corrupt", 70);
    const built = await openMemory(fx, stubSummarizer, FROZEN_LIMITS);
    let original: string;
    try { original = await assertRecoveredView(fx, built, 140); } finally { await built.dispose(); }
    const layoutPath = join(fx.storeRoot, "layout.json");
    const text = await readFile(layoutPath, "utf8");
    const lines = (JSON.parse(text) as { lines: Array<[number, number, string]> }).lines;
    const settled = lines.findIndex(([, span]) => span >= 64);
    expect(settled).toBeGreaterThanOrEqual(0);
    const history = await sha256File(fx.sessionFile);
    const catalog = JSON.stringify((await readPersistedState(fx)).catalog);
    const variants: Array<{ name: string; text: string; reason: string; keptPrefix: number }> = [
      { name: "garbage", text: "{", reason: "unreadable", keptPrefix: 0 },
      { name: "truncated", text: text.slice(0, Math.floor(text.length / 2)), reason: "unreadable", keptPrefix: 0 },
      { name: "empty", text: "", reason: "unreadable", keptPrefix: 0 },
      { name: "oversized", text: " ".repeat(16 * 1024 * 1024 + 1), reason: "unreadable", keptPrefix: 0 },
      { name: "unknown field", text: JSON.stringify({ version: 2, lines }), reason: "unreadable", keptPrefix: 0 },
      { name: "gap", text: JSON.stringify({ lines: lines.filter((_, index) => index !== settled + 1) }), reason: "structure", keptPrefix: settled + 1 },
      { name: "overlap", text: JSON.stringify({ lines: [...lines.slice(0, settled + 1), lines[settled]!, ...lines.slice(settled + 1)] }), reason: "structure", keptPrefix: settled + 1 },
      { name: "misaligned", text: JSON.stringify({ lines: [...lines.slice(0, settled), [lines[settled]![0], 3, lines[settled]![2]], ...lines.slice(settled + 1)] }), reason: "structure", keptPrefix: settled },
      { name: "past the catalog", text: JSON.stringify({ lines: [...lines, [140, 1, "0".repeat(64)]] }), reason: "past-catalog", keptPrefix: lines.length },
      { name: "stale content", text: JSON.stringify({ lines: lines.map((line, index) => index === settled ? [line[0], line[1], "0".repeat(64)] : line) }), reason: "content", keptPrefix: settled },
    ];
    for (const variant of variants) {
      await writeFile(layoutPath, variant.text, { mode: 0o600 });
      fx.diagnostics.length = 0;
      const memory = await openMemory(fx, stubSummarizer, FROZEN_LIMITS);
      try {
        const rebuilt = fx.diagnostics.filter(record => record.event === "episodic.layout-rebuilt");
        expect(rebuilt.map(record => record.reason), variant.name).toEqual([variant.reason]);
        const rendered = await assertRecoveredView(fx, memory, 140);
        const keptLines = original.split("\n").slice(0, variant.keptPrefix);
        expect(rendered.split("\n").slice(0, keptLines.length), `${variant.name} keeps the lines before the damage`).toEqual(keptLines);
      } finally { await memory.dispose(); }
      expect(await sha256File(fx.sessionFile)).toBe(history);
      expect(JSON.stringify((await readPersistedState(fx)).catalog), `${variant.name} leaves the catalog alone`).toBe(catalog);
      expect(await layoutLines(fx)).not.toHaveLength(0);
    }

    await rm(layoutPath);
    await writeFile(join(fx.root, "elsewhere.json"), text, { mode: 0o600 });
    await symlink(join(fx.root, "elsewhere.json"), layoutPath);
    await expect(openMemory(fx, stubSummarizer, FROZEN_LIMITS)).rejects.toMatchObject({ kind: "unsafe-store" });
  }, 300_000);

  it("keeps memory running when the layout cannot be saved, and validates the older layout on reopen", async () => {
    const fx = await frozenRecoveryFixture("unsaved", 70);
    const memory = await openMemory(fx, stubSummarizer, FROZEN_LIMITS);
    let older: string;
    try {
      await assertRecoveredView(fx, memory, 140);
      older = await readFile(join(fx.storeRoot, "layout.json"), "utf8");
      (memory as unknown as { store: { saveLayout(text: string): Promise<void> } }).store.saveLayout = async () => {
        throw Object.assign(new Error("ENOSPC: no space left on device"), { code: "ENOSPC" });
      };
      for (let index = 0; index < 8; index += 1) {
        fx.manager.appendMessage({ role: "user", content: `unsaved ${index} ${"u".repeat(700)}`, timestamp: Date.now() } satisfies Message);
      }
      await assertRecoveredView(fx, memory, 148);
      expect(fx.diagnostics.some(record => record.event === "episodic.layout-unsaved")).toBe(true);
    } finally { await memory.dispose(); }
    expect(await readFile(join(fx.storeRoot, "layout.json"), "utf8"), "a failed save leaves the last saved layout").toBe(older);
    const reopened = await openMemory(fx, stubSummarizer, FROZEN_LIMITS);
    try { await assertRecoveredView(fx, reopened, 148); } finally { await reopened.dispose(); }
  }, 180_000);
});
