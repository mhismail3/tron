import { createServer } from "node:http";
import { mkdtemp, mkdir, rm, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AddressInfo } from "node:net";
import { ModelRuntime, SessionManager } from "@earendil-works/pi-coding-agent";
import { expect, it } from "vitest";
import { createTestRegistry } from "../../test-support/gateway-registry.js";
import { waitFor } from "../../test-support/wait-for.js";
import { TrustService } from "../kernel/resources/trust-service.js";
import { ManagedSubagents } from "../kernel/delegation/managed-subagents.js";
import { delegatedArtifactRoot, delegatedProviderEnvironment, DELEGATED_PROVIDER_ROOT_ENV } from "../kernel/delegation/delegated-provider.js";
import type { RuntimeRegistry } from "../kernel/session/runtime-registry.js";

/** Real retained research role, parent resource reload, and detached Pi resume.
 * The socket model is available to both processes; an in-memory faux provider
 * cannot establish detached-child model admission. No external endpoint runs. */
it("a retained research child keeps its scoped evidence and web access across parent reload and resume", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-web-resume-"));
  const agentDir = join(root, "agent"); const cwd = join(root, "project"); const tronHome = join(root, "tron");
  const envKeys = ["PI_CODING_AGENT_DIR", DELEGATED_PROVIDER_ROOT_ENV, "PI_SUBAGENTS_PI_CODING_AGENT_PACKAGE_ROOT", "PI_SUBAGENT_CHILD"];
  const previous = new Map(envKeys.map(key => [key, process.env[key]]));
  let registry: RuntimeRegistry | undefined;
  let providerCalls = 0; let modelCalls = 0; let passed = false; let resultId = ""; let runId = "";
  const schemas: unknown[] = []; const routes: unknown[] = []; const receipts: unknown[] = [];
  let resumeTrace: unknown;
  let releaseRead!: () => void;
  const heldRead = new Promise<void>(resolve => { releaseRead = resolve; });
  const model = { provider: "tron-web-resume", id: "fixture" };
  const server = createServer(async (request, response) => {
    let bytes = "";
    for await (const chunk of request) { bytes += chunk; if (bytes.length > 2 * 1024 * 1024) { response.writeHead(413).end(); return; } }
    if (request.url === "/origin") { response.writeHead(200, { "content-type": "text/html" }).end("<article>Public fixture article.</article>"); return; }
    if (request.url === "/api") {
      providerCalls++;
      if (providerCalls === 1) await heldRead;
      response.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ success: true, data: { markdown: "# Durable evidence\nThe shared source survives parent extension reload.", metadata: { sourceURL: "https://example.org/evidence", title: "Durable evidence", statusCode: 200 } } })); return;
    }
    const body = JSON.parse(bytes); const last = body.messages.at(-1);
    const parent = body.tools.some((tool: any) => tool.function.name === "subagent");
    const input = typeof last.content === "string" ? last.content : JSON.stringify(last.content);
    let answer: string | { name: string; id: string; args: Record<string, unknown> };
    if (parent) {
      if (last.role === "user" && input.includes("LAUNCH_WEB_PROBE")) answer = { name: "subagent", id: "initial-web-child", args: { agent: "researcher", model: `${model.provider}/${model.id}`, task: "INITIAL_WEB_READ: Read the public evidence page without writing files.", async: false, mission: false, acceptance: { level: "none", reason: "Read-only web resume regression" } } };
      else if (last.role === "user" && input.includes("RESUME_WEB_PROBE")) answer = { name: "subagent", id: "resume-web-child", args: { action: "resume", id: runId, message: "RETAINED_WEB_READ: Read the retained source and then read the public page again." } };
      else answer = "PARENT_SETTLED";
    } else {
      schemas.push(body.tools.find((tool: any) => tool.function.name === "web_search"));
      if (last.role === "tool" && last.tool_call_id === "initial-read") { resultId = JSON.parse(input).resultId; answer = "INITIAL_WEB_CHILD_COMPLETE"; }
      else if (last.role === "tool" && last.tool_call_id === "retained-content") answer = { name: "web_search", id: "resumed-read", args: { op: "read", url: "https://example.org/evidence", freshness: "fresh" } };
      else if (last.role === "tool" && last.tool_call_id === "resumed-read") answer = "RESUMED_WEB_CHILD_COMPLETE";
      else if (input.includes("RETAINED_WEB_READ")) answer = { name: "web_search", id: "retained-content", args: { op: "content", resultId, limitBytes: 512 } };
      else answer = { name: "web_search", id: "initial-read", args: { op: "read", url: "https://example.org/evidence" } };
    }
    routes.push({ parent, role: last.role, toolCallId: last.tool_call_id, answer });
    if (++modelCalls > 24 || request.url !== "/v1/chat/completions") { response.writeHead(500).end("Unexpected model request"); return; }
    const delta = typeof answer === "string" ? { content: answer } : { tool_calls: [{ index: 0, id: answer.id, type: "function", function: { name: answer.name, arguments: JSON.stringify(answer.args) } }] };
    response.writeHead(200, { "content-type": "text/event-stream" });
    for (const [value, finish] of [[{ role: "assistant", ...delta }, null], [{}, typeof answer === "string" ? "stop" : "tool_calls"]]) response.write(`data: ${JSON.stringify({ id: `probe-${modelCalls}`, object: "chat.completion.chunk", created: 1, model: model.id, choices: [{ index: 0, delta: value, finish_reason: finish }] })}\n\n`);
    response.end("data: [DONE]\n\n");
  });
  try {
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    process.env.PI_CODING_AGENT_DIR = agentDir; delete process.env.PI_SUBAGENT_CHILD;
    delegatedProviderEnvironment(delegatedArtifactRoot(tronHome));
    await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
    const endpoint = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
    await writeFile(join(agentDir, "models.json"), JSON.stringify({ providers: { [model.provider]: {
      baseUrl: `${endpoint}/v1`, api: "openai-completions", apiKey: "fixture-only-not-a-credential",
      models: [{ id: model.id, name: "Resume fixture", reasoning: false, input: ["text"], contextWindow: 128000, maxTokens: 1024, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }],
    } } }));
    const managedSubagents = ManagedSubagents.activateForStartup(tronHome);
    const trust = new TrustService(agentDir); await trust.set(cwd, true);
    registry = await createTestRegistry({ agentDir, tronHome, trust, managedSubagents,
      modelRuntimeFactory: () => ModelRuntime.create({ modelsPath: join(agentDir, "models.json"), refreshOnCreate: false }),
      idleRuntimeMs: 60000, broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
      homeWebTransport: { resolveHost: async () => ["93.184.216.34"], fetcher: (_input, init) => fetch(`${endpoint}/origin`, init), providerFetcher: (_input, init) => fetch(`${endpoint}/api`, init) },
    });
    await registry.initialize(); const slot = await registry.create(cwd); await slot.setModel(model.provider, model.id);
    await slot.prompt("LAUNCH_WEB_PROBE");
    await waitFor(() => providerCalls === 1, "live child admitted its first web read");
    await expect(slot.reload(true, true, true)).rejects.toMatchObject({ code: "busy" });
    releaseRead(); await waitFor(() => !slot.isBusy, "initial child and parent settlement");
    const launch = SessionManager.open(slot.sessionFile!).getEntries().find(entry => entry.type === "message" && entry.message.role === "toolResult" && entry.message.toolCallId === "initial-web-child");
    receipts.push(launch); expect(launch).toMatchObject({ message: { isError: false } }); expect(resultId).toBeTruthy();
    if (!launch || launch.type !== "message" || launch.message.role !== "toolResult") throw new Error("Missing initial launch");
    const details = launch.message.details as { runId: string; results: Array<{ sessionFile: string; exitCode: number }> };
    expect(details.results[0]!.exitCode).toBe(0); runId = details.runId;
    const childFile = details.results[0]!.sessionFile; const childId = SessionManager.open(childFile).getSessionId();
    await slot.reload(true, true, true);
    await slot.prompt("RESUME_WEB_PROBE"); await waitFor(() => !slot.isBusy, "parent resume admission settlement");
    const resume = SessionManager.open(slot.sessionFile!).getEntries().find(entry => entry.type === "message" && entry.message.role === "toolResult" && entry.message.toolCallId === "resume-web-child");
    receipts.push(resume); expect(resume).toMatchObject({ message: { isError: false } });
    const asyncDir = ((resume as any).message.details as { asyncDir: string }).asyncDir;
    await waitFor(async () => { try { return JSON.parse(await readFile(join(asyncDir, "process-terminal.json"), "utf8")).state === "observed"; } catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return false; throw error; } }, "resumed child observed process exit");
    resumeTrace = JSON.parse(await readFile(join(asyncDir, "status.json"), "utf8"));
    expect(resumeTrace).toMatchObject({ state: "complete", steps: [{ status: "complete", exitCode: 0 }] });
    expect(await readFile(childFile, "utf8")).toContain("RESUMED_WEB_CHILD_COMPLETE");
    await waitFor(() => !slot.isBusy && !slot.catalogHasActiveSubagents, "resumed child and parent settlement");
    expect(SessionManager.open(childFile).getSessionId()).toBe(childId);
    expect(schemas.length).toBeGreaterThanOrEqual(3); for (const schema of schemas) expect(schema).toEqual(schemas[0]);
    const results = SessionManager.open(childFile).getEntries().filter(entry => entry.type === "message" && entry.message.role === "toolResult" && entry.message.toolName === "web_search");
    expect(results).toHaveLength(3);
    for (const result of results) {
      expect(result).toMatchObject({ message: { isError: false, details: { status: "ok" } } });
      expect(JSON.stringify(result)).toContain("shared source survives parent extension reload");
    }
    expect(providerCalls).toBe(2); passed = true;
  } finally {
    releaseRead(); await registry?.dispose(); await new Promise<void>(resolve => { server.close(() => resolve()); server.closeAllConnections(); });
    for (const [key, value] of previous) { if (value === undefined) delete process.env[key]; else process.env[key] = value; }
    await rm(root, { recursive: true, force: true });
    const output = join(process.cwd(), "test-results", "web-research-resume"); await mkdir(output, { recursive: true });
    await writeFile(join(output, "report.json"), JSON.stringify({ passed, providerCalls, modelCalls, receipts, resumeTrace, schemas, routes }, null, 2));
  }
});
