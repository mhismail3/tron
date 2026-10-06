import { spawn } from "node:child_process";
import { constants, readFileSync } from "node:fs";
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
 * nodes, and while it is inside the window between a catalog revision and the
 * invalidation that must follow it. The parent must be able to reopen the store,
 * prove it consistent, resume the pump and refold a valid view. The same file
 * covers the store boundaries that can be seen without a crash: a torn trailing
 * record (discarded, because it was never acknowledged), a corrupt record
 * (refused visibly, never skipped), a deleted namespace and a second opener.
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

async function openMemory(fx: RecoveryFixture): Promise<EpisodicMemory> {
  return EpisodicMemory.open({
    workspace: fx.workspace,
    sessionId: fx.sessionId,
    sessionFile: fx.sessionFile,
    budget: createEpisodicTokenBudget(2_000_000_000),
    summarizer: stubSummarizer,
    limits: { viewBytes: 4_096, jobs: 4, retryMs: 1 },
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
  await writeFile(program, `import { existsSync } from "node:fs";\nimport { EpisodicMemory } from ${JSON.stringify(EPISODIC_MEMORY_MODULE)};\nimport { createEpisodicTokenBudget } from ${JSON.stringify(CONTRACT_MODULE)};\nimport { TronWorkspace } from ${JSON.stringify(WORKSPACE_MODULE)};\n\nconst [home, sessionFile, sessionId, marker] = process.argv.slice(2);\nconst zero = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };\nconst workspace = new TronWorkspace(home);\nconst memory = await EpisodicMemory.open({\n  workspace, sessionId, sessionFile,\n  budget: createEpisodicTokenBudget(2000000000),\n  limits: { viewBytes: 4096, jobs: 4, retryMs: 1 },\n  summarizer: async (request) => {\n    const last = request.turns[request.turns.length - 1].text.replace(/\\s+/g, " ").trim().slice(-200);\n    return { role: "assistant", content: [{ type: "text", text: last }], api: "faux", provider: "faux", model: "child", usage: zero, stopReason: "stop", timestamp: Date.now() };\n  },\n  sleep: async () => {},\n});\nawait memory.entriesCommitted(sessionId);\nprocess.stdout.write("ready\\n");\n// The parent appends the edit and then drops this marker; the window we are\n// testing is inside the commit that follows.\nfor (;;) {\n  if (existsSync(marker)) break;\n  await new Promise(resolve => setTimeout(resolve, 1));\n}\nawait memory.entriesCommitted(sessionId);\nprocess.stdout.write("done\\n");\n`, "utf8");
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
    const raw = await readFile(fx.nodesPath, "utf8");
    expect(raw.endsWith("\n")).toBe(true);
    const liveAfter = assertConsistentStore(await readRecords(fx.nodesPath), messages);
    expect(liveAfter.size).toBeGreaterThanOrEqual(liveBefore.size);
    // Every node whose whole range exists: one per level per full span.
    let expectedNodes = 0;
    for (let span = 1; span <= messages; span *= 2) expectedNodes += Math.floor(messages / span);
    expect(liveAfter.size).toBe(expectedNodes);
    await memory.dispose();
  }, 120_000);

  it("repairs a catalog revision whose invalidation a crash lost", async () => {
    // Enough nodes that the window between the catalog append and the
    // invalidation is comfortably wider than the parent's poll interval.
    const fx = await fixture("window", 600);
    const marker = join(fx.root, "commit-marker");
    const { program, hook } = await writeChildProgram(fx, marker);
    const target = fx.manager.getBranch().filter(entry => entry.type === "message")[2]!;
    const editedText = "edited in the crash window";
    let hit = false;

    for (let attempt = 0; attempt < 3 && !hit; attempt += 1) {
      const child = spawn(process.execPath, ["--experimental-transform-types", "--import", hook, program, fx.home, fx.sessionFile, fx.sessionId, marker], { stdio: ["ignore", "pipe", "pipe"] });
      children.push(child);
      let output = "";
      child.stdout.on("data", (chunk: Buffer) => { output += chunk.toString(); });
      child.stderr.on("data", (chunk: Buffer) => { output += chunk.toString(); });
      const deadline = Date.now() + 60_000;
      while (!output.includes("ready")) {
        if (Date.now() > deadline) throw new Error(`child never became ready: ${output}`);
        await new Promise(resolve => setTimeout(resolve, 5));
      }
      if (attempt === 0) fx.manager.appendContextEdit(target.id, { content: editedText });
      await writeFile(marker, "go", "utf8");
      // Kill exactly inside the window: the catalog holds the new text and no
      // invalidation record exists yet.
      while (Date.now() < deadline) {
        const catalog = readFileSync(fx.catalogPath, "utf8");
        const nodes = readFileSync(fx.nodesPath, "utf8");
        if (catalog.includes(editedText) && !nodes.includes("\"nodes\":")) {
          child.kill("SIGKILL");
          await new Promise(resolve => child.once("exit", resolve));
          hit = !readFileSync(fx.nodesPath, "utf8").includes("\"nodes\":");
          break;
        }
        await new Promise(resolve => setTimeout(resolve, 1));
      }
      if (!hit) {
        child.kill("SIGKILL");
        await new Promise(resolve => child.once("exit", resolve));
      }
    }
    expect(hit, "the child was never killed inside the catalog/invalidation window").toBe(true);

    // The window really is the inconsistent state: the live leaf's recorded
    // source digest no longer matches the catalog record it summarizes.
    const editedRecord = [...new Map(records(await readFile(fx.catalogPath, "utf8")).map(record => [record.index as number, record])).values()]
      .find(record => record.text === editedText)!;
    expect(editedRecord).toBeDefined();
    const before = liveNodes(await readRecords(fx.nodesPath));
    const leafBefore = before.get(`${editedRecord.index}+1`)!;
    expect(leafBefore).toBeDefined();
    expect(leafBefore.kind).not.toBe("free");

    const lock = join(fx.home, "gateway", "workspace-state.lock");
    const past = new Date(Date.now() - 120_000);
    await utimes(lock, past, past);
    const memory = await openMemory(fx);
    // open() repaired it: the generation moved and the stale leaf is revoked
    // before the pump rebuilds it.
    expect(memory.status().generation).toBeGreaterThan(0);
    expect(liveNodes(await readRecords(fx.nodesPath)).get(`${editedRecord.index}+1`)).toBeUndefined();
    await memory.entriesCommitted(fx.sessionId);
    const leafAfter = liveNodes(await readRecords(fx.nodesPath)).get(`${editedRecord.index}+1`)!;
    expect(leafAfter).toBeDefined();
    expect(leafAfter.sourceDigest).not.toBe(leafBefore.sourceDigest);
    expect(memory.status().blocked).toBeNull();
    expect(memory.status().view.unbuilt).toBe(0);
    assertConsistentStore(await readRecords(fx.nodesPath), memory.status().messages);
    await memory.dispose();
  }, 180_000);

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
    expect(reopened.status().nodes.total).toBe(complete.filter(record => typeof record.nodes !== "string").length);
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

  it("refuses a deleted namespace, an unknown version and a second opener, and keeps every store path owner-only", async () => {
    const fx = await fixture("version", 2);
    const memory = await openMemory(fx);
    await memory.entriesCommitted(fx.sessionId);
    // A second in-process opener would write the same files without a lock.
    await expect(openMemory(fx)).rejects.toThrowError(/already open/u);
    await memory.dispose();
    // The marker is what makes a deleted namespace lost state rather than a
    // fresh installation that re-spends every compactor call.
    const reopened = await openMemory(fx);
    await reopened.dispose();
    await rm(fx.storeRoot, { recursive: true });
    await expect(openMemory(fx)).rejects.toThrowError(/namespace is missing/u);

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
