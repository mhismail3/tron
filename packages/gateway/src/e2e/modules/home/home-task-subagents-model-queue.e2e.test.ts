import { createServer, type Server } from "node:http";
import { createHash } from "node:crypto";
import { mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import type { AddressInfo } from "node:net";
import { join } from "node:path";
import { fauxAssistantMessage, fauxToolCall } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { dispatch, fixture, reportCall } from "../../../../test-support/home-task-fixture.js";
import { setModelQueue } from "../../../../test-support/settings-dependencies.js";
import { waitFor } from "../../../../test-support/wait-for.js";
import { closeSubagentFixtures, launchResults } from "../../../../test-support/home-task-subagents-support.js";
import { modelQueueProjectionPath } from "../../../providers/model-queue.js";
import { homeOwnerOf, queueOwnerOf } from "../../../../test-support/gateway-registry.js";

async function queueProvider(): Promise<{ port: number; requests: Record<string, number>; close: () => Promise<void> }> {
  const requests: Record<string, number> = {};
  const server: Server = createServer(async (request, response) => {
    let body = "";
    for await (const chunk of request) body += chunk;
    const model = String((JSON.parse(body) as { model?: unknown }).model);
    requests[model] = (requests[model] ?? 0) + 1;
    if (model === "limited") {
      response.writeHead(429, { "content-type": "application/json" });
      response.end(JSON.stringify({ error: { type: "GoUsageLimitError", message: "Monthly usage limit reached" } }));
      return;
    }
    response.writeHead(200, { "content-type": "text/event-stream" });
    for (const [index, delta] of [{ role: "assistant", content: "CHILD-DONE" }, {}].entries()) {
      response.write(`data: ${JSON.stringify({ id: "queue-child", object: "chat.completion.chunk", created: 1, model,
        choices: [{ index: 0, delta, finish_reason: index === 1 ? "stop" : null }] })}\n\n`);
    }
    response.end("data: [DONE]\n\n");
  });
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
  const port = (server.address() as AddressInfo).port;
  return { port, requests, close: async () => {
    server.closeAllConnections();
    await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
  } };
}

const servers: Array<{ close: () => Promise<void> }> = [];
const blockedProjections: string[] = [];
afterEach(async () => {
  for (const server of servers.splice(0)) await server.close();
  for (const path of blockedProjections.splice(0)) await rm(path, { recursive: true, force: true });
  await closeSubagentFixtures();
});

describe("Home task subagents: the subagent model queue", () => {
  it("keeps Anthropic task-worker writes one-hour across cold resume while subagents and ordinary chats stay short", async () => {
    const requests: Array<{ model: string; marks: Array<{ ttl?: string }> }> = [];
    let workerCalls = 0;
    const server = createServer(async (request, response) => {
      let text = "";
      for await (const chunk of request) text += chunk;
      const body = JSON.parse(text) as Record<string, unknown>;
      const marks: Array<{ ttl?: string }> = [];
      const visit = (value: unknown) => {
        if (!value || typeof value !== "object") return;
        for (const [key, field] of Object.entries(value)) {
          if (key === "cache_control") marks.push(field as { ttl?: string });
          else visit(field);
        }
      };
      visit(body);
      const worker = body.model === "retention-worker";
      requests.push({ model: String(body.model), marks });
      const call = worker ? ++workerCalls === 1
        ? { id: "retention-launch", name: "subagent", input: { agent: "retention-child", task: "Check retention", async: false } }
        : { id: `retention-report-${workerCalls}`, name: "report", input: { resultId: `retention-${workerCalls}`, outcome: "final", text: "Checked", evidence: ["local fixture"] } }
        : undefined;
      const events = [
        { type: "message_start", message: { id: `retention-${requests.length}`, type: "message", role: "assistant", model: body.model, content: [],
          stop_reason: null, usage: { input_tokens: 4, output_tokens: 0 } } },
        { type: "content_block_start", index: 0, content_block: call ? { type: "tool_use", ...call, input: {} } : { type: "text", text: "" } },
        { type: "content_block_delta", index: 0, delta: call ? { type: "input_json_delta", partial_json: JSON.stringify(call.input) } : { type: "text_delta", text: "CHILD-DONE" } },
        { type: "content_block_stop", index: 0 },
        { type: "message_delta", delta: { stop_reason: call ? "tool_use" : "end_turn" }, usage: { output_tokens: 1 } },
        { type: "message_stop" },
      ];
      response.writeHead(200, { "content-type": "text/event-stream" });
      response.end(events.map(event => `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`).join(""));
    });
    await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
    servers.push({ close: async () => { server.closeAllConnections(); await new Promise<void>(resolve => server.close(() => resolve())); } });
    const model = (id: string) => ({ id, name: id, reasoning: false, input: ["text"], contextWindow: 128000, maxTokens: 4096,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } });
    const f = await fixture(false, false, undefined, true, { providers: { anthropic: {
      baseUrl: `http://127.0.0.1:${(server.address() as AddressInfo).port}`, api: "anthropic-messages", apiKey: "fixture-only",
      models: [model("retention-worker"), model("retention-child")] } } });
    await mkdir(join(f.cwd, ".pi", "agents"), { recursive: true });
    await writeFile(join(f.cwd, ".pi", "agents", "retention-child.md"),
      "---\nname: retention-child\ndescription: Local retention witness\nmodel: anthropic/retention-child\ntools: read\n---\nReturn the fixture answer.\n");
    const run = await homeOwnerOf(f.registry).dispatchTask(f.home.sessionId, { taskId: "retention", intent: "Check cache retention with a child", target: f.cwd,
      model: { provider: "anthropic", id: "retention-worker" }, reason: "Local wire witness" });
    expect((await run.completion).terminalEvidence?.outcome).toBe("final");
    const cold = await f.restart();
    const resumed = await homeOwnerOf(cold).taskTool(f.home.sessionId, { action: "resume", taskId: run.taskId }) as { taskId: string; sessionId: string };
    expect(resumed.sessionId).toBe(run.sessionId);
    await waitFor(async () => (await homeOwnerOf(cold).taskStatus(resumed.taskId)).lifecycle === "terminal", "cold resumed retention worker settles");
    expect((await homeOwnerOf(cold).taskResult(resumed.taskId)).terminalEvidence?.outcome).toBe("final");
    const ordinary = await cold.create(f.cwd);
    await ordinary.setModel("anthropic", "retention-child");
    await ordinary.prompt("Ordinary retention control");
    await waitFor(() => ordinary.snapshot().configurationBlocker === null, "ordinary retention control settles");
    expect(requests.map(request => request.model)).toEqual(["retention-worker", "retention-child", "retention-worker", "retention-worker", "retention-child"]);
    for (const request of requests) {
      expect(request.marks.length).toBeGreaterThan(0);
      expect(request.marks.map(mark => mark.ttl ?? "5m"), request.model).toEqual(
        request.marks.map(() => request.model === "retention-worker" ? "1h" : "5m"));
    }
  }, 120_000);

  it.each([
    { explicit: false, detached: false, blocked: false },
    { explicit: true, detached: false, blocked: false },
    { explicit: false, detached: true, blocked: false },
    { explicit: false, detached: false, blocked: true },
  ])("isolates child launch queues ($explicit explicit, $detached detached, $blocked publication failure)", async ({ explicit, detached, blocked }) => {
    const provider = await queueProvider();
    servers.push(provider);
    const model = (id: string) => ({ id, name: id, reasoning: false, input: ["text"], contextWindow: 128000, maxTokens: 4096,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } });
    const f = await fixture(false, false, undefined, true, { providers: { "queue-child": {
      baseUrl: `http://127.0.0.1:${provider.port}/v1`, api: "openai-completions", apiKey: "fixture-only",
      models: [model("limited"), model("fallback"), model("mac")] } } });
    await mkdir(join(f.cwd, ".pi", "agents"), { recursive: true });
    await writeFile(join(f.cwd, ".pi", "agents", "queue-child.md"),
      "---\nname: queue-child\ndescription: Scripted queue child\nmodel: tron/subagent\ntools: read\n---\nComplete the scripted task.\n");
    const settings = f.settings;
    await setModelQueue({ registry: f.registry, agentDir: f.agentDir, tronHome: f.tronHome, trust: f.trust, modelRuntime: f.gateway },
      "subagent", ["queue-child/limited", "queue-child/fallback"]);
    await settings.settingsChanges.change({ kind: "global" }, [{ key: "model.queue[role=subagent]", layer: "global", op: "set", value: ["queue-child/mac"] }],
      { actor: { kind: "ui", id: "fixture" }, commandId: "mac-subagent-queue" });
    let blockedProjection: string | undefined;
    const projectionDirectory = join(f.tronHome, "gateway", "model-queue-sessions");
    f.faux.setResponses([
      async () => {
        const profile = JSON.parse(readFileSync(settings.settingsModel.owner.profilePath, "utf8"));
        profile.modelQueue.subagent = ["queue-child/mac"];
        writeFileSync(settings.settingsModel.owner.profilePath, JSON.stringify(profile));
        if (blocked) {
          const task = await homeOwnerOf(f.registry).taskStatus("task-one");
          if (!task.sessionId) throw new Error("Worker must be admitted before its first request");
          blockedProjection = join(projectionDirectory, `${createHash("sha256").update(task.sessionId).digest("hex")}.json`);
          blockedProjections.push(blockedProjection);
          mkdirSync(blockedProjection, { recursive: true });
        }
        return fauxAssistantMessage([fauxToolCall("subagent", { agent: "queue-child", task: "queue search", async: detached, ...(explicit ? { model: "queue-child/fallback" } : {}) }, { id: "queue-launch" })], { stopReason: "toolUse" });
      },
      ...(detached ? [fauxAssistantMessage([fauxToolCall("bg_wait", { all: true }, { id: "queue-join" })], { stopReason: "toolUse" })] : []),
      fauxAssistantMessage([reportCall()], { stopReason: "toolUse" }),
    ]);
    const run = await dispatch(f);
    const result = await run.completion;
    const providerErrors = (await f.registry.readTaskEvidence(run.sessionId)).flatMap(entry => entry.type === "message"
      && entry.message.role === "assistant" && entry.message.errorMessage ? [entry.message.errorMessage] : []);
    expect(result.terminalEvidence?.outcome, JSON.stringify({ result, providerErrors })).toBe("final");
    const launch = (await launchResults(f.registry, run.sessionId)).find(item => item.toolCallId === "queue-launch");
    if (blocked) {
      try {
        expect(launch?.isError).toBe(true);
        expect(JSON.stringify(launch)).toContain("Cannot publish this session");
        expect(provider.requests).toEqual({});
        expect(f.queueDiagnostics).toContainEqual(expect.objectContaining({ event: "model-queue.projection",
          scope: "task-launch", sessionId: run.sessionId, status: "failed", reason: "EISDIR" }));
        expect((await readdir(projectionDirectory)).filter(name => name.endsWith(".tmp"))).toEqual([]);
      } finally { if (blockedProjection) await rm(blockedProjection, { recursive: true, force: true }); }
      await f.registry.dispose();
      expect(await readdir(projectionDirectory)).toEqual([]);
      return;
    }
    expect(launch?.isError, JSON.stringify(launch).slice(0, 3000)).toBe(false);
    if (!detached) expect(JSON.stringify((launch as unknown as { content: unknown }).content)).toContain("CHILD-DONE");
    expect(provider.requests).toEqual(explicit ? { fallback: 1 } : { limited: 1, fallback: 1 });
    const worker = await f.registry.acquire(run.sessionId);
    const resolution = await settings.settingsModel.resolve({ kind: "session", sessionId: run.sessionId }, {
      cwd: f.cwd, home: false, session: worker.settingsSessionLayer(), modelRuntime: worker.modelRuntime,
    }, ["model.queue[role=subagent]"]);
    expect(resolution.keys[0]).toMatchObject({ value: ["queue-child/limited", "queue-child/fallback"], layer: "session", fixedAt: { from: "delegate", via: "home-profile" } });
    expect(f.queueDiagnostics).toContainEqual({ event: "model-queue.projection", role: "subagent",
      scope: "task-launch", sessionId: run.sessionId, status: "published", models: ["queue-child/limited", "queue-child/fallback"] });
    await expect(f.registry.importFromJsonl(worker.sessionFile!, f.cwd)).rejects.toThrow("Invalid task marker");
    let activeRegistry = f.registry;
    if (!explicit && !detached) {
      activeRegistry = await f.restart();
      const reopened = await activeRegistry.acquire(run.sessionId);
      f.faux.setResponses([
        fauxAssistantMessage([fauxToolCall("subagent", { agent: "queue-child", task: "retained queue search", async: false }, { id: "cold-queue-launch" })], { stopReason: "toolUse" }),
        fauxAssistantMessage("cold child done"),
      ]);
      await reopened.prompt("Continue this session using its retained launch policy");
      await waitFor(() => reopened.snapshot().configurationBlocker === null, "cold child settlement");
      const coldLaunch = reopened.canonicalSessionEntries().flatMap(entry =>
        entry.type === "message" && entry.message.role === "toolResult" ? [entry.message] : [])
        .find(item => item.toolCallId === "cold-queue-launch");
      expect(coldLaunch?.isError, JSON.stringify(coldLaunch)).toBe(false);
      expect(JSON.stringify(coldLaunch)).toContain("CHILD-DONE");
      expect(provider.requests.mac, "cold-opened launch evidence must still control actual child requests").toBeUndefined();
      expect(provider.requests.fallback).toBe(2);
    }
    const unrelated = `${f.model.provider}/${f.model.id}`;
    queueOwnerOf(activeRegistry)!.recordUsageLimit("worker", unrelated, "fixture plan limit");
    await queueOwnerOf(activeRegistry)!.publishProjection();
    const projection = JSON.parse(await readFile(modelQueueProjectionPath(f.tronHome), "utf8"));
    expect(projection.queues.subagent).toEqual(["queue-child/mac"]);
    expect(projection.unavailable).not.toHaveProperty(unrelated);
    const beforeOrdinary = { ...provider.requests };
    const ordinary = await activeRegistry.create(f.cwd);
    f.faux.setResponses([
      fauxAssistantMessage([fauxToolCall("subagent", { agent: "queue-child", task: "ordinary queue search", async: false }, { id: "ordinary-queue-launch" })], { stopReason: "toolUse" }),
      fauxAssistantMessage("ordinary done"),
    ]);
    await ordinary.prompt("Run the ordinary child");
    await waitFor(() => ordinary.snapshot().configurationBlocker === null, "ordinary child terminal settlement");
    const ordinaryLaunch = ordinary.canonicalSessionEntries().flatMap(entry =>
      entry.type === "message" && entry.message.role === "toolResult" ? [entry.message] : [])
      .find(item => item.toolCallId === "ordinary-queue-launch");
    expect(ordinaryLaunch?.isError, JSON.stringify(ordinaryLaunch ?? ordinary.canonicalSessionEntries()).slice(0, 4000)).toBe(false);
    expect(JSON.stringify(ordinaryLaunch)).toContain("CHILD-DONE");
    expect(provider.requests).toEqual({ ...beforeOrdinary, mac: 1 });
    expect(f.queueDiagnostics).toContainEqual({ event: "model-queue.projection", role: "subagent",
      scope: "global", status: "published", models: ["queue-child/mac"] });
    await activeRegistry.dispose();
    expect(await readdir(join(f.tronHome, "gateway", "model-queue-sessions"))).toEqual([]);
  }, 120_000);
});
