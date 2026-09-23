import { randomUUID } from "node:crypto";
import { mkdir, mkdtemp, readFile, realpath, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall, getCurrentSystemPrompt, type TranscriptContext } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it, vi } from "vitest";
import { RuntimeRegistry } from "../sessions/runtime-registry.js";
import { TrustService } from "../admin/trust-service.js";

const registries: RuntimeRegistry[] = [];
const roots: string[] = [];
afterEach(async () => {
  await Promise.all(registries.splice(0).map(value => value.dispose()));
  await Promise.all(roots.splice(0).map(path => rm(path, { recursive: true, force: true })));
  vi.unstubAllEnvs();
});
async function fixture(extension?: string) {
  const root = await realpath(await mkdtemp(join(tmpdir(), "tron-workspace-integration-")));
  roots.push(root);
  const agentDir = join(root, "agent");
  const cwd = join(root, "project");
  const tronHome = join(root, "tron");
  await Promise.all([mkdir(agentDir), mkdir(cwd)]);
  vi.stubEnv("PI_CODING_AGENT_DIR", agentDir);
  vi.stubEnv("HOME", root);
  vi.stubEnv("PI_OFFLINE", "1");
  await writeFile(join(agentDir, "settings.json"), JSON.stringify({ retry: { enabled: false }, compaction: { enabled: false, keepRecentTokens: 1 } }));
  await writeFile(join(cwd, "AGENTS.md"), "Project boundary fixture: retain this rule.");
  if (extension) {
    await mkdir(join(agentDir, "extensions"));
    await writeFile(join(agentDir, "extensions", "fixture.ts"), extension);
  }
  const faux = fauxProvider({ provider: "workspace-fixture", tokensPerSecond: 100_000 });
  const contexts: TranscriptContext[] = [];
  const response = (text = "Done") => (context: TranscriptContext) => {
    contexts.push(context);
    return fauxAssistantMessage(text);
  };
  const registry = new RuntimeRegistry({
    agentDir, tronHome, idleRuntimeMs: 60_000,
    trust: new TrustService(agentDir),
    modelRuntimeFactory: async () => {
      const runtime = await ModelRuntime.create({ authPath: join(agentDir, "auth.json"), modelsPath: null, refreshOnCreate: false, allowModelNetwork: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    },
    broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
  });
  registries.push(registry);
  await registry.initialize();
  const slot = await registry.create(cwd);
  const model = faux.getModel();
  await slot.setModel(model.provider, model.id);
  return { root, agentDir, cwd, tronHome, registry, slot, faux, contexts, response };
}
async function settle(slot: { isBusy: boolean }) {
  await vi.waitFor(() => expect(slot.isBusy).toBe(false), { timeout: 5_000, interval: 10 });
}

describe("Tron workspace through the pinned runtime", () => {
  it("keeps project context, cwd and JSONL canonical across turns, reload, fork, resume and scheduled execution", async () => {
    const f = await fixture();
    const internal = join(f.tronHome, "workspace");
    await writeFile(join(internal, "AGENTS.md"), "GLOBAL CONTENT MUST NOT LEAK");
    f.faux.setResponses(Array.from({ length: 12 }, () => f.response()));
    await f.slot.prompt("first"); await settle(f.slot);
    const file = f.slot.sessionFile!;
    const originalId = f.slot.id;
    await f.slot.prompt("second"); await settle(f.slot);
    await f.slot.reload();
    await f.slot.prompt("after reload"); await settle(f.slot);
    const firstUser = f.slot.snapshot().transcript.find(entry => entry.role === "user")!;
    await f.slot.compact("Retain task facts."); await settle(f.slot);
    await f.slot.prompt("after compaction"); await settle(f.slot);
    await f.slot.fork(firstUser.id, "at");
    await f.slot.prompt("after fork"); await settle(f.slot);
    // Reacquire the original canonical session, not a second runtime client.
    const resumed = await f.registry.acquire(originalId);
    await resumed.prompt("after resume"); await settle(resumed);
    const runId = randomUUID();
    const generated = await f.registry.createAutomationSession(f.cwd, randomUUID(), `automation:${runId}`, randomUUID());
    try {
      await generated.slot.setModel(f.faux.getModel().provider, f.faux.getModel().id);
      await generated.slot.prompt("scheduled execution context");
    } finally { generated.release(); }
    await settle(generated.slot);
    const agentContexts = f.contexts.map(context => getCurrentSystemPrompt(context.messages))
      .filter(systemPrompt => systemPrompt.includes("## Tron operating context"));
    for (const text of agentContexts) {
      expect(text.match(/## Tron operating context/g)).toHaveLength(1);
      expect(text).toContain(JSON.stringify(f.cwd));
      expect(text).toContain(JSON.stringify(internal));
      expect(text).toContain("Project boundary fixture");
      expect(text).not.toContain("GLOBAL CONTENT MUST NOT LEAK");
    }
    expect(agentContexts).toHaveLength(7);
    expect(f.slot.cwd).toBe(f.cwd);
    expect(file.startsWith(join(f.agentDir, "sessions"))).toBe(true);
    expect(await readFile(file, "utf8")).not.toContain("## Tron operating context");
    await rm(internal, { recursive: true });
    await resumed.prompt("unrelated work still works"); await settle(resumed);
    expect(getCurrentSystemPrompt(f.contexts.at(-1)!.messages)).toContain("(unavailable)");
    expect(resumed.cwd).toBe(f.cwd);
  }, 30_000);

  it("passes actual direct delegated task arguments without broadening child tools", async () => {
    const f = await fixture(`export default function(pi) {
      pi.registerTool({name:"subagent", label:"Child", description:"fixture", parameters:{type:"object",properties:{agent:{type:"string"},task:{type:"string"}},required:["agent","task"]},
      execute: async (_id, args) => ({content:[{type:"text",text:args.task}],details:{received:args}})});
    }`);
    f.faux.setResponses([
      fauxAssistantMessage([fauxToolCall("subagent", { agent: "worker", task: "Read only" })], { stopReason: "toolUse" }),
      f.response(),
    ]);
    await f.slot.prompt("delegate"); await settle(f.slot);
    const tool = f.contexts[0]?.messages.find(message => message.role === "toolResult");
    expect(JSON.stringify(tool)).toContain("Tron workspace handoff");
    expect(JSON.stringify(tool)).toContain(join(f.tronHome, "workspace"));
    expect(JSON.stringify(tool)).toContain("Read only");
    expect(f.slot.cwd).toBe(f.cwd);
  }, 15_000);

  it("presents an internal document from a different cwd using unchanged artifact results", async () => {
    const f = await fixture();
    await f.registry.initializeBlobStorage();
    const files = join(f.tronHome, "workspace/files");
    await mkdir(files);
    await writeFile(join(files, "report.md"), "# Internal report\nOriginal content");
    f.faux.setResponses([
      fauxAssistantMessage([fauxToolCall("display", {
        title: "Report", altText: "Internal document", source: { kind: "internal_file", path: "report.md" },
      })], { stopReason: "toolUse" }), f.response(),
    ]);
    await f.slot.prompt("present report"); await settle(f.slot);
    const tool = f.contexts[0]?.messages.find(message => message.role === "toolResult");
    expect(tool?.role === "toolResult" && tool.isError).toBe(false);
    const canonical = await readFile(f.slot.sessionFile!, "utf8");
    expect(canonical).toContain('"schema":"tron.display.v1"');
    expect(canonical).toContain('"name":"report.md"');
    const artifactId = JSON.parse(canonical.split("\n").find(line => line.includes('"schema":"tron.display.v1"'))!).message.details.display.artifact.id;
    await writeFile(join(files, "report.md"), "Changed original");
    const lease = await f.registry.acquireDisplayArtifact(f.slot.id, artifactId);
    const chunks: Buffer[] = [];
    for await (const chunk of lease.stream) chunks.push(Buffer.from(chunk));
    await lease.release();
    expect(Buffer.concat(chunks).toString()).toBe("# Internal report\nOriginal content");
    await mkdir(join(f.tronHome, "workspace/state/demo"), { recursive: true });
    await writeFile(join(f.tronHome, "workspace/state/demo/data.json"), "{}");
    await writeFile(join(files, ".hidden.md"), "hidden");
    await symlink(join(files, "report.md"), join(files, "link.md"));
    const denied = ["../state/demo/data.json", join(files, "report.md"), ".hidden.md", "link.md", "."];
    f.faux.setResponses([
      fauxAssistantMessage(denied.map(path => fauxToolCall("display", {
        title: "Denied", altText: "Boundary fixture", source: { kind: "internal_file", path },
      })), { stopReason: "toolUse" }), f.response(),
    ]);
    await f.slot.prompt("verify boundaries"); await settle(f.slot);
    const rejected = f.contexts.at(-1)!.messages.filter(message => message.role === "toolResult").slice(-denied.length);
    expect(rejected).toHaveLength(denied.length);
    expect(rejected.every(message => message.isError)).toBe(true);
    expect(f.slot.cwd).toBe(f.cwd);
    await expect(readFile(join(f.cwd, "report.md"))).rejects.toMatchObject({ code: "ENOENT" });
  }, 15_000);
});
