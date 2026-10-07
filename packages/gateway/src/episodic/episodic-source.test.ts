import { createHash } from "node:crypto";
import { appendFile, mkdir, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { fauxAssistantMessage, type Message } from "@earendil-works/pi-ai";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { EpisodicMemoryError, type EpisodicSummarizer } from "./episodic-contract.js";
import { EpisodicMemory } from "./episodic-memory.js";
import { readCanonicalSession } from "./episodic-source.js";

/*
 * The read-only canonical reader (departure 2): it must never repair, migrate
 * or rewrite the file, must not parse a trailing partial line, must follow the
 * branch from the last complete entry, and must refuse a file it cannot read
 * whole rather than silently dropping data.
 */

const roots: string[] = [];
const owners: TronWorkspace[] = [];
afterEach(async () => {
  await Promise.all(owners.splice(0).map(owner => owner.dispose()));
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })));
});

/** A deterministic compactor that never touches a model provider. */
const stubSummarizer: EpisodicSummarizer = async (request) => {
  const last = request.turns.at(-1)!;
  return fauxAssistantMessage(last.text.replace(/\s+/gu, " ").trim().slice(-200));
};

interface SourceFixture {
  root: string;
  home: string;
  sessionFile: string;
  sessionId: string;
  manager: SessionManager;
  workspace: TronWorkspace;
  catalogPath: string;
}

async function fixture(label: string): Promise<SourceFixture> {
  const root = await mkdtemp(join(tmpdir(), `tron-episodic-source-${label}-`));
  roots.push(root);
  const home = join(root, "home");
  const cwd = join(root, "project");
  const sessionDir = join(root, "sessions");
  await Promise.all([mkdir(cwd, { recursive: true }), mkdir(sessionDir, { recursive: true })]);
  const manager = SessionManager.create(cwd, sessionDir);
  manager.appendMessage({ role: "user", content: "first prompt", timestamp: Date.now() });
  const sessionFile = manager.getSessionFile()!;
  const sessionId = manager.getSessionId();
  const workspace = new TronWorkspace(home);
  owners.push(workspace);
  return { root, home, sessionFile, sessionId, manager, workspace, catalogPath: join(home, "workspace", "state", "episodic", sessionId, "catalog.jsonl") };
}

function memoryFor(fx: SourceFixture, limits: { maxSourceLineBytes?: number } = {}): Promise<EpisodicMemory> {
  return EpisodicMemory.open({
    workspace: fx.workspace,
    sessionId: fx.sessionId,
    sessionFile: fx.sessionFile,
    summarizer: stubSummarizer,
    limits: { viewBytes: 4_096, jobs: 2, retryMs: 1, ...limits },
    sleep: async () => {},
  });
}

function userMessage(text: string): Message {
  return { role: "user", content: text, timestamp: Date.now() };
}

async function sha256(path: string): Promise<string> {
  return createHash("sha256").update(await readFile(path)).digest("hex");
}

function catalogRecords(text: string): Array<Record<string, unknown>> {
  return text.split("\n").filter(line => line.trim() !== "").map(line => JSON.parse(line) as Record<string, unknown>);
}

describe("episodic canonical source reader", () => {
  it("treats a SessionManager-created header-only session as an empty history", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-episodic-source-header-only-"));
    roots.push(root);
    const sessionDir = join(root, "sessions");
    const projectDir = join(root, "project");
    await Promise.all([mkdir(sessionDir, { recursive: true }), mkdir(projectDir, { recursive: true })]);
    const sessionFile = join(sessionDir, "header-only.jsonl");
    await writeFile(sessionFile, "");
    // Opening the empty file makes Pi's SessionManager initialize it with its
    // canonical session header and no entries.
    const manager = SessionManager.open(sessionFile, sessionDir, projectDir);
    const sessionId = manager.getSessionId();
    const cut = await readCanonicalSession({ path: sessionFile, sessionId, maxLineBytes: 1_024 * 1_024 });
    expect(cut.branch).toEqual([]);
    expect(cut.leafEntryId).toBeNull();

    const workspace = new TronWorkspace(join(root, "home"));
    owners.push(workspace);
    const memory = await EpisodicMemory.open({
      workspace, sessionId, sessionFile, summarizer: stubSummarizer,
      limits: { viewBytes: 4_096, jobs: 2, retryMs: 1 }, sleep: async () => {},
    });
    await memory.entriesCommitted(sessionId);
    expect(memory.status().messages).toBe(0);
    expect(memory.status().blocked).toBeNull();
    await memory.dispose();
  });

  it("ignores a trailing partial line, leaves the file byte-identical, and ingests it once completed", async () => {
    const fx = await fixture("partial");
    fx.manager.appendMessage(fauxAssistantMessage([{ type: "text", text: "second reply" }]));
    const lines = (await readFile(fx.sessionFile, "utf8")).split("\n").filter(line => line !== "");
    const whole = JSON.stringify({
      type: "message", id: "partial-entry", parentId: JSON.parse(lines.at(-1)!).id, timestamp: new Date().toISOString(),
      message: { role: "user", content: "completed later", timestamp: Date.now() },
    });
    const cut = Math.floor(whole.length / 2);
    await appendFile(fx.sessionFile, whole.slice(0, cut));
    const before = await sha256(fx.sessionFile);

    const memory = await memoryFor(fx);
    await memory.entriesCommitted(fx.sessionId);
    expect(memory.status().messages).toBe(2);
    // A partial line is not parsed, and the reader never writes to the file.
    expect(await sha256(fx.sessionFile)).toBe(before);
    const cut2 = await stat(fx.sessionFile);

    // Completing the line makes the entry visible; the file still grows only by
    // what the session's own writer appended.
    await appendFile(fx.sessionFile, `${whole.slice(cut)}\n`);
    await memory.entriesCommitted(fx.sessionId);
    expect(memory.status().messages).toBe(3);
    const catalog = catalogRecords(await readFile(fx.catalogPath, "utf8"));
    expect(catalog.some(record => record.entryId === "partial-entry" && record.text === "completed later")).toBe(true);
    expect((await stat(fx.sessionFile)).size).toBeGreaterThan(cut2.size);
    await memory.dispose();
  });

  it("refuses a header that names another session, an unparsable line, and an oversized line", async () => {
    const fx = await fixture("refuse");
    const raw = await readFile(fx.sessionFile, "utf8");
    await expect(readCanonicalSession({ path: fx.sessionFile, sessionId: "another-session", maxLineBytes: 1_024 }))
      .rejects.toThrowError(/different session/u);
    expect(await readFile(fx.sessionFile, "utf8")).toBe(raw);

    const broken = join(fx.root, "broken.jsonl");
    const header = raw.split("\n")[0]!;
    await appendFile(broken, `${header}\nnot json\n`);
    await expect(readCanonicalSession({ path: broken, sessionId: fx.sessionId, maxLineBytes: 1_024 })).rejects.toThrowError(/not JSON/u);

    const oversized = join(fx.root, "oversized.jsonl");
    await appendFile(oversized, `${header}\n${JSON.stringify({ type: "message", id: "big", parentId: null, timestamp: new Date().toISOString(), message: { role: "user", content: "x".repeat(4_000), timestamp: Date.now() } })}\n`);
    await expect(readCanonicalSession({ path: oversized, sessionId: fx.sessionId, maxLineBytes: 1_024 })).rejects.toThrowError(/exceeds/u);
    // The refusal is visible to the memory as a blocked source, not a silent skip.
    const memory = await EpisodicMemory.open({
      workspace: fx.workspace, sessionId: fx.sessionId, sessionFile: oversized,
      summarizer: stubSummarizer,
      limits: { viewBytes: 4_096, jobs: 2, retryMs: 1, maxSourceLineBytes: 1_024 }, sleep: async () => {},
    });
    await memory.entriesCommitted(fx.sessionId);
    expect(memory.status().blocked?.reason).toBe("source-unavailable");
    expect(memory.status().messages).toBe(0);
    await memory.dispose();
  });

  it("follows the branch from the last complete entry and keeps off-branch indices", async () => {
    const fx = await fixture("branch");
    const kept: string[] = [];
    for (let index = 0; index < 6; index += 1) {
      kept.push(fx.manager.appendMessage(userMessage(`branch prompt ${index} ${"b".repeat(700)}`)));
      fx.manager.appendMessage(fauxAssistantMessage([{ type: "text", text: `branch reply ${index} ${"a".repeat(700)}` }]));
    }
    const memory = await memoryFor(fx);
    await memory.entriesCommitted(fx.sessionId);
    expect(memory.status().messages).toBe(13);

    // Navigate back and append a new child: the abandoned entries stay in the
    // memory at their index as `[omitted]`, and nothing is renumbered.
    fx.manager.branch(kept[2]!);
    fx.manager.appendMessage(userMessage("navigated prompt"));
    await memory.entriesCommitted(fx.sessionId);
    expect(memory.status().messages).toBe(14);
    const catalog = catalogRecords(await readFile(fx.catalogPath, "utf8"));
    const latest = new Map<number, Record<string, unknown>>();
    for (const record of catalog) latest.set(record.index as number, record);
    const navigated = [...latest.values()].find(record => record.text === "navigated prompt")!;
    expect(navigated.index).toBe(13);
    // The seven entries the branch left behind keep their index and become
    // `[omitted]`; nothing is renumbered.
    const omitted = [...latest.values()].filter(record => record.omitted === true);
    expect(omitted.length).toBe(7);
    for (const record of omitted) {
      expect(record.text).toBe("[omitted]");
      expect(record.omissions as string[]).toContain("off-branch");
      expect(record.index as number).toBeLessThan(13);
    }
    expect(latest.get(0)!.text).toBe("first prompt");
    await memory.dispose();
  });

  it("uses the edited content of a context edit, and a free [omitted] node for a null replacement", async () => {
    const fx = await fixture("edits");
    const target = fx.manager.appendMessage(userMessage(`original ${"o".repeat(900)}`));
    const other = fx.manager.appendMessage(userMessage(`second ${"s".repeat(900)}`));
    fx.manager.appendContextEdit(target, { content: "replacement from an edit" });
    fx.manager.appendContextEdit(other, null);
    const memory = await memoryFor(fx);
    await memory.entriesCommitted(fx.sessionId);
    const catalog = catalogRecords(await readFile(fx.catalogPath, "utf8"));
    const latest = new Map<number, Record<string, unknown>>();
    for (const record of catalog) latest.set(record.index as number, record);
    const edited = [...latest.values()].find(record => record.entryId === target)!;
    const dropped = [...latest.values()].find(record => record.entryId === other)!;
    expect(edited.text).toBe("replacement from an edit");
    expect(edited.index).toBe(1);
    expect(dropped.omitted).toBe(true);
    expect(dropped.text).toBe("[omitted]");
    expect(dropped.omissions as string[]).toContain("context-edit");
    expect(dropped.index).toBe(2);
    // Both messages are level-0 nodes, and the omitted one is free: no
    // compactor call was needed for it.
    expect(memory.status().nodes.byLevel.find(entry => entry.level === 0)?.count).toBe(3);
    await memory.dispose();
  });

  it("records a read failure of a missing file as a blocked source", async () => {
    const fx = await fixture("missing");
    const memory = await EpisodicMemory.open({
      workspace: fx.workspace, sessionId: fx.sessionId, sessionFile: join(fx.root, "absent.jsonl"),
      summarizer: stubSummarizer,
      limits: { viewBytes: 4_096, jobs: 2, retryMs: 1 }, sleep: async () => {},
    });
    await memory.entriesCommitted(fx.sessionId);
    expect(memory.status().blocked?.reason).toBe("source-unavailable");
    await expect(memory.whenReady(1)).rejects.toBeInstanceOf(EpisodicMemoryError);
    await memory.dispose();
  });

  it("never gives a hidden custom message or a state entry a slot, even for a null edit", async () => {
    const fx = await fixture("hidden");
    const hidden = fx.manager.appendCustomMessageEntry("tron.receipt", "hidden receipt", false);
    const displayed = fx.manager.appendCustomMessageEntry("tron.receipt", "displayed receipt", true);
    fx.manager.appendCustomEntry("tron.bookkeeping", { private: true });
    fx.manager.appendContextEdit(hidden, null);
    fx.manager.appendContextEdit(displayed, null);
    const memory = await memoryFor(fx);
    await memory.entriesCommitted(fx.sessionId);
    const latest = new Map<number, Record<string, unknown>>();
    for (const record of catalogRecords(await readFile(fx.catalogPath, "utf8"))) latest.set(record.index as number, record);
    // Only the seed message and the displayed event hold slots; the hidden
    // custom message and the state entry never had one to omit.
    expect(memory.status().messages).toBe(2);
    expect(latest.get(0)!.text).toBe("first prompt");
    expect(latest.get(1)!.omitted).toBe(true);
    expect(latest.get(1)!.kind).toBe("event");
    expect(latest.get(1)!.text).toBe("[omitted]");
    await memory.dispose();
  });

  it("answers whenReady for cut 0 on an empty memory and refuses an impossible or aborted wait", async () => {
    const fx = await fixture("ready");
    fx.manager.appendMessage(userMessage("second prompt"));
    const memory = await memoryFor(fx);
    // Nothing is ingested yet: cut 0 is trivially ready, a cut beyond the
    // message count is not answerable, and an aborted wait rejects at once.
    await memory.whenReady(0);
    await expect(memory.whenReady(1)).rejects.toThrowError(/beyond/u);
    const aborted = new AbortController();
    aborted.abort();
    await expect(memory.whenReady(1, { signal: aborted.signal })).rejects.toBeInstanceOf(EpisodicMemoryError);
    await memory.entriesCommitted(fx.sessionId);
    expect(memory.status().messages).toBe(2);
    await memory.whenReady(2);
    await expect(memory.whenReady(3)).rejects.toThrowError(/beyond/u);
    await memory.dispose();
  });

  it("continues at the cursor when the file only grew", async () => {
    const fx = await fixture("incremental");
    const first = await readCanonicalSession({ path: fx.sessionFile, sessionId: fx.sessionId, maxLineBytes: 1_024 * 1_024 });
    expect(first.incremental).toBe(false);
    fx.manager.appendMessage(userMessage("appended after the first read"));
    const second = await readCanonicalSession({
      path: fx.sessionFile, sessionId: fx.sessionId, maxLineBytes: 1_024 * 1_024,
      previous: { cursor: first.cursor, branch: first.branch },
    });
    expect(second.incremental).toBe(true);
    expect(second.branch.map(entry => entry.id)).toEqual(fx.manager.getBranch().map(entry => entry.id));
    expect(second.completeBytes).toBeGreaterThan(first.completeBytes);
    // A rewrite that changes the line before the offset falls back to the whole
    // file rather than extending a prefix that is no longer there.
    const rewritten = join(fx.root, "rewritten.jsonl");
    const raw = await readFile(fx.sessionFile, "utf8");
    const lines = raw.split("\n").filter(line => line !== "");
    lines[lines.length - 1] = lines[lines.length - 1]!.replace("appended after the first read", "rewritten later on");
    await writeFile(rewritten, `${lines.join("\n")}\n`);
    const reread = await readCanonicalSession({
      path: rewritten, sessionId: fx.sessionId, maxLineBytes: 1_024 * 1_024,
      previous: { cursor: second.cursor, branch: second.branch },
    });
    expect(reread.incremental).toBe(false);
    expect(reread.branch.at(-1)!.id).toBe(second.branch.at(-1)!.id);
  });
});
