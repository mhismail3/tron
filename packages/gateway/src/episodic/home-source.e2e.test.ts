import { appendFile, mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import fs from "node:fs/promises";
import { syncBuiltinESMExports } from "node:module";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, it, vi } from "vitest";
import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { EpisodicMemory } from "./episodic-memory.js";
import { resolveLimits, type EpisodicDiagnostic, type EpisodicSessionSource, type EpisodicSourceCursor, type EpisodicSummarizer } from "./episodic-contract.js";
import { EpisodicStore } from "./episodic-store.js";
import { readCanonicalHomeDeltas, readCanonicalHomeIndex } from "./home-source.js";
import type { EpisodicSourceDelta } from "./episodic-source.js";

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
const assistantEntry = (id: string, parentId: string | null, text: string) => JSON.stringify({
  id, parentId, timestamp: "2026-01-01T00:00:00.000Z", type: "message",
  message: { role: "assistant", content: text, timestamp: 0 },
}) + "\n";

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
  const diagnostics: EpisodicDiagnostic[] = [];
  const open = async (sessionSource = source, summarize: EpisodicSummarizer = async request => fauxAssistantMessage(request.turns.at(-1)!.text.slice(-200))) => {
    const memory = await EpisodicMemory.open({ workspace, sessionId: "home",       sessionSource,
      summarizer: summarize, diagnostic: record => diagnostics.push(record),
      limits: { viewBytes: 4096, jobs: 2, retryMs: 0 },
    }); memories.push(memory); return memory;
  };
  return { root, chapters, open, workspace, source, diagnostics };
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

it("labels an assistant summary from the canonical Home item kind", async () => {
  const fx = await fixture();
  await appendFile(fx.chapters[0]!.path, assistantEntry("assistant", "b", `Tron answered ${"detail ".repeat(500)}`));
  // The source projects this assistant message as talk; the model must not be
  // allowed to relabel its summary as user-authored.
  const memory = await fx.open(fx.source, async () => fauxAssistantMessage("faithfully summarized assistant content"));
  await memory.entriesCommitted("home");
  await memory.whenReady(3);
  const view = memory.renderView(3).text;
  expect(view).toContain("talk: faithfully summarized assistant content");
  expect(view).not.toContain("user: faithfully summarized assistant content");
  await memory.dispose(); memories.splice(memories.indexOf(memory), 1);
});

it("keeps legitimate byte-limit content instead of treating every size mention as a repair prompt", async () => {
  const fx = await fixture();
  await appendFile(fx.chapters[0]!.path, assistantEntry("assistant", "b", `The task requires short output. ${"detail ".repeat(500)}`));
  const memory = await fx.open(fx.source, async () => fauxAssistantMessage("Keep output at most 512 bytes"));
  await memory.entriesCommitted("home");
  await memory.whenReady(3);
  expect(memory.renderView(3).text).toContain("talk: Keep output at most 512 bytes");
});

// #880: OpenAI's prompt-safety flag on a summary request is intermittent, so it is
// retried within the bound; only a flag on every attempt stops memory.
const FLAGGED = "Invalid prompt: your prompt was flagged as potentially violating our usage policy. Please try again with a different prompt";
it.each([["thrown", true], ["returned", false]])("retries a %s prompt-safety flag and keeps memory running", async (_label, thrown) => {
  const fx = await fixture();
  await appendFile(fx.chapters[0]!.path, assistantEntry("assistant", "b", `Tron answered ${"detail ".repeat(500)}`));
  let flagged = 0;
  const memory = await fx.open(fx.source, async request => {
    if (flagged === 0) {
      flagged += 1;
      if (thrown) throw new Error(FLAGGED);
      return fauxAssistantMessage("", { stopReason: "error", errorMessage: FLAGGED });
    }
    return fauxAssistantMessage("Tron answered with details");
  });
  await memory.entriesCommitted("home");
  await memory.whenReady(3);
  expect(flagged).toBe(1);
  expect(memory.status().blocked).toBeNull();
  expect(memory.renderView(3).text).toContain("talk: Tron answered with details");
});

it("stops memory as retries-exhausted only when every attempt is flagged", async () => {
  const fx = await fixture();
  await appendFile(fx.chapters[0]!.path, assistantEntry("assistant", "b", `Tron answered ${"detail ".repeat(500)}`));
  let calls = 0;
  const memory = await fx.open(fx.source, async () => { calls += 1; return fauxAssistantMessage("", { stopReason: "error", errorMessage: FLAGGED }); });
  await memory.entriesCommitted("home");
  await expect.poll(() => memory.status().blocked?.reason).toBe("retries-exhausted");
  expect(memory.status().blocked?.detail).toContain("flagged as potentially violating");
  expect(calls).toBe(resolveLimits({}).maxRetries + 1);
});

// #1279: Tron stores short messages as kind-labelled free lines ("echo: tool task: ...")
// and feeds them back when two lines merge, so a model naturally keeps the label.
// That is summary content, never a reason to stop Home's memory.
it("keeps memory running when every summary carries Tron's own role labels", async () => {
  const fx = await fixture();
  for (let index = 0; index < 6; index += 1) {
    await appendFile(fx.chapters[1]!.path, assistantEntry(`tool-${index}`, index === 0 ? "d" : `tool-${index - 1}`,
      `{"accepted":true,"action":"steer","taskId":"worker-${index}","operationId":"task-${"x".repeat(160)}"}`));
  }
  const canonical = await readFile(fx.chapters[1]!.path, "utf8");
  let calls = 0;
  const memory = await fx.open(fx.source, async () => {
    calls += 1;
    return fauxAssistantMessage(`echo: tool task: steered workers; user: kept the labels ${calls}`);
  });
  await memory.entriesCommitted("home");
  const messages = memory.status().messages;
  await memory.whenReady(messages);
  const row = {
    calls,
    blocked: memory.status().blocked,
    // Home opens merged lines through its memory tools; zoom reads the same nodes.
    summaries: memory.zoomLines(0, 8) ?? [],
    blocks: fx.diagnostics.filter(record => record.event === "episodic.node-blocked").length,
  };
  expect(row.calls).toBeGreaterThan(0);
  expect(row.blocked).toBeNull();
  expect(row.blocks).toBe(0);
  // Attribution stays Tron's: a merged line is a summary, whatever words the model wrote.
  expect(row.summaries).toHaveLength(2);
  for (const line of row.summaries) expect(line).toMatch(/^\d\+4\|summary: echo: tool task: steered workers/u);
  expect(await readFile(fx.chapters[1]!.path, "utf8")).toBe(canonical);
  await mkdir("test-results/home-memory", { recursive: true });
  await writeFile("test-results/home-memory/labelled-summaries.json", JSON.stringify(row, null, 2) + "\n");
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

it("keeps the next delta incremental when the chapter's last line is longer than the cursor's prefix window", async () => {
  // The cursor proves the previous prefix by its last line. A line longer than the
  // proof window must still be proven whole, or every later delta rereads the chapter.
  const { chapters } = await fixture();
  const snapshot = { homeId: "home", ledgerRevision: 2, chapters };
  const limits = resolveLimits();
  const deltas = async (cursor: EpisodicSourceCursor | null) => {
    const out: EpisodicSourceDelta[] = [];
    for await (const delta of readCanonicalHomeDeltas(snapshot, cursor, limits)) out.push(delta);
    return out;
  };
  await appendFile(chapters[1]!.path, entry("long", "d", "long ".repeat(4_096)));
  const cursor = (await deltas(null)).at(-1)!.cursor;
  await appendFile(chapters[1]!.path, entry("after", "long", "after the long line"));
  const next = (await deltas(cursor)).find(delta => delta.scopeSessionId === "two");
  expect(next?.incremental).toBe(true);
  expect(next?.projected.map(message => message.text).join("\n")).toContain("after the long line");
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
