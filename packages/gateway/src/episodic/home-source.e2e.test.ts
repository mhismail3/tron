import { appendFile, mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import fs from "node:fs/promises";
import { syncBuiltinESMExports } from "node:module";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, it, vi } from "vitest";
import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { EpisodicMemory } from "./episodic-memory.js";
import type { EpisodicSessionSource } from "./episodic-contract.js";
import { EpisodicStore } from "./episodic-store.js";
import { readCanonicalHomeDeltas, readCanonicalHomeIndex } from "./home-source.js";

const roots: string[] = [];
const memories: EpisodicMemory[] = [];
const workspaces: TronWorkspace[] = [];
afterEach(async () => {
  vi.restoreAllMocks(); syncBuiltinESMExports();
  await Promise.all(memories.splice(0).map(memory => memory.dispose()));
  await Promise.all(workspaces.splice(0).map(workspace => workspace.dispose()));
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })));
});
const entry = (id: string, parentId: string | null, text: string) => JSON.stringify({
  id, parentId, timestamp: "2026-01-01T00:00:00.000Z", type: "message",
  message: { role: "user", content: text, timestamp: 0 },
}) + "\n";
const boundary = (id: string, parentId: string) => JSON.stringify({ id, parentId,
  timestamp: "2026-01-01T00:00:00.000Z", type: "thinking_level_change", thinkingLevel: "off" }) + "\n";

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "tron-home-source-")); roots.push(root);
  const workspace = new TronWorkspace(join(root, "home")); workspaces.push(workspace);
  const chapters = ["one", "two"].map(sessionId => ({ sessionId, path: join(root, sessionId + ".jsonl"), sealed: sessionId === "one" }));
  for (const chapter of chapters) await writeFile(chapter.path, JSON.stringify({ type: "session", version: 3, id: chapter.sessionId, cwd: root, timestamp: "2026-01-01T00:00:00.000Z" }) + "\n");
  await appendFile(chapters[0]!.path, entry("a", null, "first chapter violet fact") + boundary("b", "a"));
  await appendFile(chapters[1]!.path, entry("c", null, "second chapter amber fact") + boundary("d", "c"));
  const source: EpisodicSessionSource = {
    read: (cursor, limits) => readCanonicalHomeDeltas({ homeId: "home", ledgerRevision: 2, chapters }, cursor, limits),
    branchAtCursor: (cursor, limits) => readCanonicalHomeIndex({ homeId: "home", ledgerRevision: 2, chapters }, cursor, limits),
  };
  const open = async (sessionSource = source) => {
    const memory = await EpisodicMemory.open({ workspace, sessionId: "home",       sessionSource,
      summarizer: async request => fauxAssistantMessage(request.turns.at(-1)!.text.slice(-200)),
      limits: { viewBytes: 4096, jobs: 2, retryMs: 1 }, sleep: async () => {},
    }); memories.push(memory); return memory;
  };
  return { root, chapters, open, workspace, source };
}

it("continues two chapters across replay/restart and freezes exact message and non-message cuts before later navigation", async () => {
  const fx = await fixture(); const memory = await fx.open();
  await memory.entriesCommitted("home");
  expect(memory.status().messages).toBe(2);
  expect(await memory.cutAtEntry("b")).toBe(1);
  expect(await memory.cutAtEntry("d")).toBe(2);
  await appendFile(fx.chapters[1]!.path, entry("e", "d", "not yet ingested silver fact"));
  // A frozen request cannot see even a valid later append.
  expect(await memory.cutAtEntry("e")).toBeUndefined();
  expect(await memory.cutAtEntry("d")).toBe(2);
  await memory.entriesCommitted("home");
  await appendFile(fx.chapters[1]!.path, entry("f", "c", "navigated bronze fact"));
  // The source moved but the memory's last cursor still contains e.
  expect(await memory.cutAtEntry("e")).toBe(3);
  await memory.entriesCommitted("home");
  expect(await memory.cutAtEntry("e")).toBeUndefined();
  expect(await memory.cutAtEntry("f")).toBe(4);
  expect(memory.searchMessages("violet", 0, 10).matches).toBe(1);
  expect(memory.searchMessages("silver", 0, 10).matches).toBe(0);
  expect(memory.zoomLines(0, 1)?.join("\n")).toContain("violet");
  await memory.dispose(); memories.splice(memories.indexOf(memory), 1);
  const restarted = await fx.open(); await restarted.entriesCommitted("home");
  expect(restarted.status().messages).toBe(4);
  expect(await restarted.cutAtEntry("b")).toBe(1);
  expect(await restarted.cutAtEntry("f")).toBe(4);
  const catalog = await new EpisodicStore(fx.workspace, "home", 1024 * 1024).read();
  expect([...catalog.messages.values()].map(message => message.sessionId)).toEqual(["one", "two", "two", "two"]);
  const report = { chapters: 2, messages: restarted.status().messages, frozenCut: 3, replay: "idempotent", provenance: ["one", "two"] };
  await mkdir("test-results/home-memory", { recursive: true });
  await writeFile("test-results/home-memory/continuity.json", JSON.stringify(report, null, 2) + "\n");
});

it("does not reopen sealed raw history during delta ingestion", async () => {
  const fx = await fixture(); const memory = await fx.open(); await memory.entriesCommitted("home");
  const original = fs.open; const reads: string[] = [];
  vi.spyOn(fs, "open").mockImplementation(async (...args) => { reads.push(String(args[0])); return original(...args); }); syncBuiltinESMExports();
  await appendFile(fx.chapters[1]!.path, entry("e", "d", "next fact"));
  await memory.entriesCommitted("home");
  expect(memory.status().messages).toBe(3);
  expect(reads.filter(path => path === fx.chapters[0]!.path)).toHaveLength(0);
});

it.each(["changed", "missing"])("blocks %s sealed evidence without changing prior projected facts", async mode => {
  const fx = await fixture(); const memory = await fx.open(); await memory.entriesCommitted("home");
  if (mode === "missing") await rm(fx.chapters[0]!.path);
  else { const text = await readFile(fx.chapters[0]!.path, "utf8"); await writeFile(fx.chapters[0]!.path, text.replace("violet", "orange")); }
  await memory.entriesCommitted("home");
  expect(memory.status().blocked?.reason).toBe("source-unavailable");
  expect(memory.searchMessages("violet", 0, 10).matches).toBe(1);
  expect(memory.searchMessages("orange", 0, 10).matches).toBe(0);
});

it("preserves and refuses an older Home cursor format instead of rebuilding it", async () => {
  const fx = await fixture(); const memory = await fx.open(); await memory.entriesCommitted("home");
  await memory.dispose(); memories.splice(memories.indexOf(memory), 1);
  const namespace = join(fx.root, "home/workspace/state/episodic/home");
  const statePath = join(namespace, "state.json");
  const state = JSON.parse(await readFile(statePath, "utf8"));
  delete state.cursor.home.version;
  const oldBytes = JSON.stringify(state) + "\n"; await writeFile(statePath, oldBytes);
  const orphan = join(namespace, ".checkpoint-staging");
  await mkdir(orphan, { mode: 0o700 });
  await writeFile(join(orphan, "state.json"), "preserved old evidence", { mode: 0o600 });
  const names = await readdir(namespace);
  await expect(fx.open()).rejects.toThrow(/Home source cursor/);
  expect(await readFile(statePath, "utf8")).toBe(oldBytes);
  expect(await readdir(namespace)).toEqual(names);
  expect(await readFile(join(orphan, "state.json"), "utf8")).toBe("preserved old evidence");
});

it("restarts an interrupted per-chapter ingest at its last acknowledged cursor", async () => {
  const fx = await fixture();
  let interrupt = true;
  const memory = await fx.open({ ...fx.source, read: async function* (cursor, limits) {
    for await (const cut of fx.source.read(cursor, limits)) {
      yield cut;
      if (interrupt) { interrupt = false; throw new Error("ingest abandoned between chapters"); }
    }
  } });
  await expect(memory.entriesIngested("home")).rejects.toThrow("ingest abandoned");
  const state = await new EpisodicStore(fx.workspace, "home", 1024 * 1024).readState();
  expect(state?.cursor?.home?.chapters.map(chapter => chapter.sessionId)).toEqual(["one"]);
  await memory.dispose(); memories.splice(memories.indexOf(memory), 1);
  const resumed = await fx.open(); await resumed.entriesCommitted("home");
  expect(resumed.status().messages).toBe(2);
  expect(resumed.searchMessages("violet")?.matches).toBe(1);
  expect(resumed.searchMessages("amber")?.matches).toBe(1);
});

it("ingests a chapter's last writes when it first seals, then freezes that evidence", async () => {
  const fx = await fixture(); const successor = fx.chapters.pop()!;
  fx.chapters[0]!.sealed = false;
  const memory = await fx.open(); await memory.entriesCommitted("home");
  await appendFile(fx.chapters[0]!.path, entry("last", "b", "last settled indigo fact"));
  fx.chapters[0]!.sealed = true; fx.chapters.push(successor);
  await memory.entriesCommitted("home");
  expect(memory.status().blocked).toBeNull(); expect(memory.status().messages).toBe(3);
  expect(await memory.cutAtEntry("last")).toBe(2);
  expect(await memory.cutAtEntry("d")).toBe(3);
  expect(memory.searchMessages("indigo")?.matches).toBe(1);
});

it("applies only selected-branch context edits without retaining raw content or editing prior chapters", async () => {
  const fx = await fixture(); const memory = await fx.open(); await memory.entriesCommitted("home");
  const edit = (id: string, parentId: string, replacement: unknown) => JSON.stringify({ id, parentId, type: "context_edit", targetId: "c", replacement, timestamp: "2026-01-01T00:00:00.000Z" }) + "\n";
  await appendFile(fx.chapters[1]!.path, edit("edited", "d", { content: "edited turquoise fact" }));
  await memory.entriesCommitted("home");
  expect(memory.searchMessages("turquoise")?.matches).toBe(1);
  expect(memory.searchMessages("violet")?.matches).toBe(1);
  expect(await memory.cutAtEntry("edited")).toBe(2);
  await appendFile(fx.chapters[1]!.path, entry("nav", "c", "branch copper fact"));
  await memory.entriesCommitted("home");
  expect(memory.searchMessages("turquoise")?.matches).toBe(0);
  expect(memory.searchMessages("amber")?.matches).toBe(1);
  expect(await memory.cutAtEntry("edited")).toBeUndefined();
  await appendFile(fx.chapters[1]!.path, edit("omitted", "nav", null));
  await memory.entriesCommitted("home");
  expect(memory.searchMessages("amber")?.matches).toBe(0);
  expect(memory.searchMessages("violet")?.matches).toBe(1);
  expect(memory.status().messages).toBe(3);
});

it("refuses a frozen cut after an earlier active prefix is rewritten at the same size", async () => {
  const fx = await fixture(); const memory = await fx.open(); await memory.entriesCommitted("home");
  const path = fx.chapters[1]!.path;
  await writeFile(path, (await readFile(path, "utf8")).replace("amber", "green"));
  expect(await memory.cutAtEntry("d")).toBeUndefined();
  await memory.entriesCommitted("home");
  expect(memory.searchMessages("green")?.matches).toBe(1);
  expect(memory.searchMessages("violet")?.matches).toBe(1);
  expect(await memory.cutAtEntry("d")).toBe(2);
});

it("refuses a source snapshot belonging to another Home before projecting it", async () => {
  const fx = await fixture();
  const memory = await fx.open({ ...fx.source, read: async function* (cursor, limits) {
    for await (const cut of fx.source.read(cursor, limits)) yield { ...cut, sessionId: "different-home" };
  } });
  await memory.entriesCommitted("home");
  expect(memory.status().blocked?.reason).toBe("source-unavailable");
  expect(memory.status().messages).toBe(0);
});
