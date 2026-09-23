import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { createAgentSessionFromServices, createAgentSessionServices, ModelRuntime, SessionManager, type AgentSession } from "@earendil-works/pi-coding-agent";
import { contentText, fauxAssistantMessage, fauxProvider, getCurrentSystemPrompt, type TranscriptContext } from "@earendil-works/pi-ai";

const cleanup: Array<() => Promise<void>> = [];
afterEach(async () => { for (const dispose of cleanup.splice(0).reverse()) await dispose(); });

async function fixture(label: string, manager: SessionManager, options: { compact?: boolean } = {}) {
  const root = await mkdtemp(join(tmpdir(), `tron-context-edit-${label}-`));
  const cwd = manager.getCwd();
  const agentDir = join(root, "agent");
  await Promise.all([mkdir(cwd, { recursive: true }), mkdir(agentDir)]);
  if (options.compact) {
    await writeFile(join(agentDir, "settings.json"), JSON.stringify({ compaction: {
      enabled: true, reserveTokens: 4_096, keepRecentTokens: 100,
    } }));
  }
  const faux = fauxProvider({ provider: `tron-context-edit-${label}`, models: [{ id: "fixture", reasoning: false }], tokensPerSecond: 1_000_000, tokenSize: { min: 100_000, max: 100_000 } });
  const modelRuntime = await ModelRuntime.create({ authPath: join(root, "auth.json"), modelsPath: null, refreshOnCreate: false });
  modelRuntime.registerNativeProvider(faux.provider);
  const services = await createAgentSessionServices({ cwd, agentDir, modelRuntime, resourceLoaderOptions: {
    noExtensions: true, noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true,
  } });
  const { session } = await createAgentSessionFromServices({ services, sessionManager: manager, model: faux.getModel(), noTools: true });
  let disposed = false;
  const dispose = async () => {
    if (disposed) return;
    disposed = true;
    await session.dispose();
  };
  cleanup.push(async () => { await dispose(); await rm(root, { recursive: true, force: true }); });
  return { session, faux, root, cwd, dispose };
}

function userText(context: TranscriptContext): string[] {
  return context.messages.filter(message => message.role === "user").map(message =>
    message.role === "user" ? typeof message.content === "string" ? message.content : contentText(message.content) : "");
}

describe("Pi 0.87 canonical context edits", () => {
  it("reopens and forks edited history while a sibling branch retains the original provider context", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-context-edit-persisted-"));
    const cwd = join(root, "project");
    const sessions = join(root, "sessions");
    await Promise.all([mkdir(cwd), mkdir(sessions)]);
    cleanup.push(async () => { await rm(root, { recursive: true, force: true }); });
    const manager = SessionManager.create(cwd, sessions);
    const prompt = manager.appendMessage({ role: "user", content: "original request", timestamp: 1 });
    const answer = manager.appendMessage(fauxAssistantMessage("prior answer", { timestamp: 2 }));
    const edit = manager.appendContextEdit(prompt, { content: "replacement request" });
    const file = manager.getSessionFile()!;
    const raw = await readFile(file, "utf8");
    expect(raw).toContain(`"type":"context_edit","id":"${edit}"`);
    expect(manager.buildSessionProjection().messages.map(message => message.role === "user" ? contentText(message.content) : message.role))
      .toEqual(["replacement request", "assistant"]);

    // Close the only runtime client before opening the canonical file again.
    const first = await fixture("resume", manager);
    const firstContexts: TranscriptContext[] = [];
    first.faux.setResponses([(context) => {
      firstContexts.push(context);
      return fauxAssistantMessage("resumed answer");
    }]);
    await first.session.prompt("after restart");
    expect(userText(firstContexts[0]!)).toEqual(["replacement request", "after restart"]);
    expect(getCurrentSystemPrompt(firstContexts[0]!.messages)).toEqual(getCurrentSystemPrompt(manager.buildSessionContext().messages));
    await first.dispose();

    const reopened = SessionManager.open(file, sessions, cwd);
    expect(reopened.getBranch().some(entry => entry.type === "context_edit" && entry.id === edit)).toBe(true);
    const childDir = join(root, "forks");
    const fork = SessionManager.forkFrom(file, cwd, childDir);
    const forkSession = await fixture("fork", fork);
    const forkContexts: TranscriptContext[] = [];
    forkSession.faux.setResponses([(context) => {
      forkContexts.push(context);
      return fauxAssistantMessage("fork answer");
    }]);
    await forkSession.session.prompt("fork followup");
    expect(userText(forkContexts[0]!)).toEqual(["replacement request", "after restart", "fork followup"]);
    await forkSession.dispose();

    const branch = await fixture("branch", reopened);
    const branchContexts: TranscriptContext[] = [];
    branch.faux.setResponses([(context) => {
      branchContexts.push(context);
      return fauxAssistantMessage("alternate answer");
    }]);
    reopened.branch(answer);
    await branch.session.prompt("alternate branch");
    expect(userText(branchContexts[0]!)).toEqual(["original request", "alternate branch"]);
    await branch.dispose();

    const importedPath = join(root, "imported.jsonl");
    await writeFile(importedPath, raw);
    const imported = SessionManager.open(importedPath, join(root, "imports"), cwd);
    expect(imported.getBranch().some(entry => entry.type === "context_edit" && entry.id === edit)).toBe(true);
    expect(imported.buildSessionContext().messages.filter(message => message.role === "user").map(message =>
      message.role === "user" ? contentText(message.content) : "")).toEqual(["replacement request"]);
  });

  it("sends the edited context, not the superseded raw content, to compaction", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-context-edit-compaction-"));
    const cwd = join(root, "project");
    const sessions = join(root, "sessions");
    await Promise.all([mkdir(cwd), mkdir(sessions)]);
    cleanup.push(async () => { await rm(root, { recursive: true, force: true }); });
    const manager = SessionManager.create(cwd, sessions);
    const prompt = manager.appendMessage({ role: "user", content: "raw-old-context ".repeat(4_000), timestamp: 1 });
    manager.appendMessage(fauxAssistantMessage("prior response", { timestamp: 2 }));
    manager.appendContextEdit(prompt, { content: "edited-context only" });
    manager.appendMessage({ role: "user", content: "recent-work ".repeat(600), timestamp: 3 });
    manager.appendMessage(fauxAssistantMessage("recent response ".repeat(150), { timestamp: 4 }));
    const setup = await fixture("compaction", manager, { compact: true });
    const contexts: TranscriptContext[] = [];
    setup.faux.setResponses(Array.from({ length: 4 }, () => (context: TranscriptContext) => {
      contexts.push(context);
      return fauxAssistantMessage("summary");
    }));
    await setup.session.compact();
    expect(contexts.length).toBeGreaterThan(0);
    const summaryInput = contexts.flatMap(context => context.messages.filter(message => message.role === "user")
      .map(message => message.role === "user" ? contentText(message.content) : "")).join("\n");
    expect(summaryInput).toContain("edited-context only");
    expect(summaryInput).not.toContain("raw-old-context");
    expect(setup.session.sessionManager.getBranch().some(entry => entry.type === "context_edit" && entry.targetId === prompt)).toBe(true);
  });
});
