import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it, vi } from "vitest";
import { TrustService } from "../admin/trust-service.js";
import { JevDecisionClient } from "../knowledge/jev-client.js";
import { EXTENSION_ACTIVITY_RECEIPT_TYPE } from "./extension-activity-history.js";
import { RuntimeRegistry } from "./runtime-registry.js";

const registries: RuntimeRegistry[] = [];
const roots: string[] = [];
afterEach(async () => {
  await Promise.all(registries.splice(0).map((registry) => registry.dispose().catch(() => {})));
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

async function waitUntil(predicate: () => boolean, timeoutMs = 5_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error("condition timed out");
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

describe("codemode nested Jev and subagent tools", () => {
  it("enforces Jev ceilings before concurrent HTTP dispatch and preserves subagent workspace and Stop ownership", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-codemode-nested-delegation-"));
    roots.push(root);
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await Promise.all([mkdir(agentDir, { recursive: true }), mkdir(extensionDir, { recursive: true })]);
    const sdkUrl = import.meta.resolve("@earendil-works/pi-coding-agent");
    const jevResponse = JSON.stringify({
      model: "jev-1.13.0",
      answers: { decision: { type: "choice", choice: "yes", probabilities: { yes: 1, no: 0 }, confidence: 1 } },
      usage: { input_tokens: 3, output_tokens: 2 },
    });
    let activeJevRequests = 0;
    let maximumConcurrentJevRequests = 0;
    const jevClient = new JevDecisionClient({ read: async () => "synthetic-test-credential" }, async (_url, init) => {
      jevRequests.push(JSON.parse(init.body) as Record<string, unknown>);
      activeJevRequests += 1;
      maximumConcurrentJevRequests = Math.max(maximumConcurrentJevRequests, activeJevRequests);
      try {
        await new Promise((resolve) => setTimeout(resolve, 25));
        return { status: 200, body: jevResponse };
      } finally { activeJevRequests -= 1; }
    });
    const workspaceMarker = join(root, "tron", "workspace");
    const handoffPath = join(root, "handoff.txt");
    const subagentExtension = `import { writeFile } from "node:fs/promises";
export default function(pi) {
      pi.registerTool({ name: "subagent", label: "Fake subagent", description: "Fixture foreground subagent", parameters: { type: "object", properties: { action: { type: "string" }, agent: { type: "string" }, task: { type: "string" }, id: { type: "string" }, childId: { type: "string" } } }, execute: async (_id, args, signal, update) => {
        if (args.action === "stop") return { content: [{ type: "text", text: "stopped" }], details: {} };
        await writeFile(${JSON.stringify(handoffPath)}, args.task);
        update({ content: [{ type: "text", text: "running" }], details: { mode: "single", runId: "fake-run", results: [{ index: 0, agent: "worker", status: "running" }], progress: [{ index: 0, agent: "worker", status: "running", currentTool: "read", toolCount: 1 }] } });
        await new Promise((resolve) => signal.addEventListener("abort", resolve, { once: true }));
        return { content: [{ type: "text", text: "stopped" }], details: { mode: "single", runId: "fake-run", results: [{ index: 0, agent: "worker", status: "stopped" }], progress: [{ index: 0, agent: "worker", status: "stopped", currentTool: "read", toolCount: 1 }] } };
      } });
    }`;
    await Promise.all([
      writeFile(join(agentDir, "settings.json"), JSON.stringify({ defaultTools: ["+codemode"] })),
      writeFile(join(extensionDir, "codemode.ts"), `import { createCodemodeExtension } from ${JSON.stringify(sdkUrl)}; export default createCodemodeExtension({ mode: "on" });\n`),
      writeFile(join(extensionDir, "fake-subagent.ts"), `${subagentExtension}\n`),
      writeFile(join(cwd, "README.md"), "fixture workspace\n"),
    ]);
    const jevRequests: Array<Record<string, unknown>> = [];
    const faux = fauxProvider({ provider: "tron-codemode-nested-delegation", tokensPerSecond: 10_000 });
    const request = (maxChargeCents: number, id: string) => ({
      state: { id }, maxChargeCents,
      questions: { decision: { type: "choice", instructions: "Evaluate", criteria: { yes: null, no: null } } },
    });
    const script = `const jev = await Promise.allSettled([
` +
      `  tools.jev(${JSON.stringify(request(0.2, "over-limit-a"))}),
` +
      `  tools.jev(${JSON.stringify(request(0.2, "over-limit-b"))}),
` +
      `  tools.jev(${JSON.stringify(request(0.3, "admitted-a"))}),
` +
      `  tools.jev(${JSON.stringify(request(0.3, "admitted-b"))}),
` +
      `]); const child = await tools.subagent({ agent: "worker", task: "inspect delegated task" }); return JSON.stringify({ jev: jev.map(item => item.status), child });`;
    faux.setResponses([
      fauxAssistantMessage([fauxToolCall("codemode", { code: script }, { id: "delegation-parent" })], { stopReason: "toolUse" }),
      fauxAssistantMessage("done"),
    ]);
    const modelRuntimeFactory = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, modelRuntimeFactory, trust,
      jev: jevClient, broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const internal = slot as unknown as {
      processSubagentAbortAuthority: (processId: string, runId: string) => { expectedOperationId?: string } | undefined;
      abortSubagentProcess: (processId: string, runId: string, operationId?: string) => Promise<void>;
      isForegroundSubagentTool: (toolName: string) => boolean;
      extensionToolOrigin: (toolName: string) => unknown;
      trustedSubagentController: () => unknown;
      processChildSessionBinding: (processId: string) => unknown;
      processOperationIDs: Map<string, string>;
      operation?: { id: string };
      runtime: { session: { sessionManager: { getEntries: () => Array<{ type: string; customType?: string }> } } };
    };
    const isForeground = vi.spyOn(internal, "isForegroundSubagentTool").mockReturnValue(true);
    const toolOrigin = vi.spyOn(internal, "extensionToolOrigin").mockReturnValue({ source: "local", owner: { id: "extension:fixture-subagent", title: "Fake subagents", source: "local" } });
    const trustedController = vi.spyOn(internal, "trustedSubagentController").mockReturnValue({ execute: vi.fn() });
    const childBinding = vi.spyOn(internal, "processChildSessionBinding").mockReturnValue({ ref: "fake-child-session", producerId: "foreground-index:0", runId: "fake-run" });
    const prompt = slot.prompt("Run nested Jev and subagent calls");
    await waitUntil(() => existsSync(handoffPath));
    const handedTask = await readFile(handoffPath, "utf8");
    await waitUntil(() => slot.snapshot().processActivities?.some((process) => process.kind === "subagent"));
    expect(jevRequests).toHaveLength(2);
    expect(maximumConcurrentJevRequests).toBe(2);
    expect(jevRequests.map((item) => (item.state as { id: string }).id).sort()).toEqual(["admitted-a", "admitted-b"]);
    expect(handedTask).toContain("[Tron workspace handoff]");
    expect(handedTask).toContain(workspaceMarker);
    expect(slot.snapshot().toolExecutions.map((tool) => tool.toolCallId)).toEqual(["delegation-parent"]);

    const process = slot.snapshot().processActivities?.find((item) => item.kind === "subagent");
    expect(process).toBeDefined();
    const authority = slot.processSubagentAbortAuthority(process!.processId, process!.runId!);
    expect(authority?.expectedOperationId).toBe(internal.operation?.id);
    expect(internal.processOperationIDs.get(process!.processId)).toBe(internal.operation?.id);
    await slot.abortSubagentProcess(process!.processId, process!.runId!, authority!.expectedOperationId);
    await prompt;
    await waitUntil(() => !slot.isBusy);
    isForeground.mockRestore();
    toolOrigin.mockRestore();
    trustedController.mockRestore();
    childBinding.mockRestore();
    expect(slot.snapshot().extensionPresentation.pendingInteractions).toEqual([]);
    expect(slot.snapshot().toolExecutions).toEqual([]);
    expect(slot.snapshot().transcript.filter((entry) => entry.kind === "message" && entry.role === "toolResult")).toHaveLength(1);
    expect(internal.runtime.session.sessionManager.getEntries().filter((entry) =>
      entry.type === "custom" && entry.customType === EXTENSION_ACTIVITY_RECEIPT_TYPE)).toEqual([]);

    const artifactPath = join(globalThis.process.cwd(), "test-results", "pi-sdk-099-nested-delegation.json");
    await mkdir(dirname(artifactPath), { recursive: true });
    await writeFile(artifactPath, `${JSON.stringify({ jev: { requests: jevRequests.map((item) => (item.state as { id: string }).id), rejectedBeforeDispatch: ["over-limit-a", "over-limit-b"], maximumConcurrentRequests: maximumConcurrentJevRequests }, subagent: { handoffIncluded: true, workspaceMarker, stoppedThroughForegroundOperation: true, processId: process!.processId } }, null, 2)}\n`);
  });
});
