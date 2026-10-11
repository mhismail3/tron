import { spawn } from "node:child_process";
import { readFileSync } from "node:fs";
import { mkdir, mkdtemp, readFile, rm, utimes, writeFile } from "node:fs/promises";
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

/*
 * Crash and store recovery: a child process is SIGKILLed while it is writing
 * nodes, and while it is inside the window between a catalog revision and the
 * invalidation that must follow it. The parent must be able to reopen the store,
 * prove it consistent, resume the pump and refold a valid view.
 */

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
    // Spend is the one piece of a memory that no restart may hand back: a crash
    // must not reset the record of what was spent. The child is killed mid-pump,
    // and the parent's reopen must restore the spend.
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
    const lock = join(fx.home, "gateway", "workspace-state.lock");
    const past = new Date(Date.now() - 120_000);
    await utimes(lock, past, past);

    // Reopened, the memory starts from what the child spent.
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

    // #493: spend is reported, never a ceiling: a reopened memory keeps it and is
    // not blocked by it.
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
      sessionSource: singleChapterSource(fx.sessionId, fx.sessionFile),
      summarizer: stubSummarizer,
      limits: { viewBytes: 4_096, jobs: 4, retryMs: 0 },
    });
    await prebuilt.entriesCommitted(fx.sessionId);
    expect(prebuilt.status().view.unbuilt).toBe(0);
    await prebuilt.dispose();
    // Release the workspace lock the pre-build took: the child owns this
    // installation while it runs.
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
});
