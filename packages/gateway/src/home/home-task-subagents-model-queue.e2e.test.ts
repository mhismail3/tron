import { createServer, type Server } from "node:http";
import { createHash } from "node:crypto";
import { mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import type { AddressInfo } from "node:net";
import { join } from "node:path";
import { fauxAssistantMessage, fauxToolCall } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { dispatch, fixture, reportCall } from "../../test-support/home-task-fixture.js";
import { setModelQueue, settingsDependencies } from "../../test-support/settings-dependencies.js";
import { waitFor } from "../../test-support/wait-for.js";
import { closeSubagentFixtures, launchResults } from "../../test-support/home-task-subagents-support.js";
import { modelQueueProjectionPath } from "../providers/model-queue.js";

/** A scripted OpenAI-compatible provider with two models: `limited` answers every
 * request with OpenCode Go's plan-limit 429, `fallback` answers `CHILD-DONE`. */
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
    // Registered before any runtime starts, so the Gateway's queue sees both models.
    const f = await fixture(false, false, undefined, true, { providers: { "queue-child": {
      baseUrl: `http://127.0.0.1:${provider.port}/v1`, api: "openai-completions", apiKey: "fixture-only",
      models: [model("limited"), model("fallback"), model("mac")] } } });
    await mkdir(join(f.cwd, ".pi", "agents"), { recursive: true });
    await writeFile(join(f.cwd, ".pi", "agents", "queue-child.md"),
      "---\nname: queue-child\ndescription: Scripted queue child\nmodel: tron/subagent\ntools: read\n---\nComplete the scripted task.\n");
    const settings = settingsDependencies({ ...f, modelRuntime: f.gateway, home: () => f.registry.homeOwner() });
    await setModelQueue({ registry: f.registry, agentDir: f.agentDir, tronHome: f.tronHome, trust: f.trust, modelRuntime: f.gateway },
      "subagent", ["queue-child/limited", "queue-child/fallback"]);
    await settings.settingsChanges.change({ kind: "mac" }, [{ key: "model.queue[role=subagent]", layer: "mac", op: "set", value: ["queue-child/mac"] }],
      { actor: { kind: "ui", id: "fixture" }, commandId: "mac-subagent-queue" });
    let blockedProjection: string | undefined;
    const projectionDirectory = join(f.tronHome, "gateway", "model-queue-sessions");
    f.faux.setResponses([
      async () => {
        // The worker launch snapshot already exists. A subsequent Home edit must
        // neither retarget its child nor change ordinary Mac-derived subagents.
        const profile = JSON.parse(readFileSync(settings.settingsModel.profilePath, "utf8"));
        profile.modelQueue.subagent = ["queue-child/mac"];
        writeFileSync(settings.settingsModel.profilePath, JSON.stringify(profile));
        if (blocked) {
          const task = await f.registry.homeOwner().taskStatus("task-one");
          if (!task.sessionId) throw new Error("Worker must be admitted before its first request");
          blockedProjection = join(projectionDirectory, `${createHash("sha256").update(task.sessionId).digest("hex")}.json`);
          blockedProjections.push(blockedProjection);
          mkdirSync(blockedProjection, { recursive: true }); // force the real atomic rename to fail
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
    // Explicit physical selection never touches the first queue model. Without
    // it, the virtual selection retries the failed request on the fallback.
    const launch = (await launchResults(f.registry, run.sessionId)).find(item => item.toolCallId === "queue-launch");
    if (blocked) {
      try {
        expect(launch?.isError).toBe(true);
        expect(JSON.stringify(launch)).toContain("Cannot publish this session");
        expect(provider.requests).toEqual({}); // no stale/default child was launched
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
      cwd: f.cwd, home: false, chat: worker.settingsChatLayer(), modelRuntime: worker.modelRuntime,
    }, ["model.queue[role=subagent]"]);
    expect(resolution.keys[0]).toMatchObject({ value: ["queue-child/limited", "queue-child/fallback"], origin: "launch", layer: "chat" });
    expect(f.queueDiagnostics).toContainEqual({ event: "model-queue.projection", role: "subagent",
      scope: "task-launch", sessionId: run.sessionId, status: "published", models: ["queue-child/limited", "queue-child/fallback"] });
    // A generic import must not transfer Home task identity into a different
    // canonical session. Refusal leaves the existing worker and queues intact.
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
    // Shared usage failures remain useful, but a Mac child must not receive
    // unrelated model identities from Home/worker queue failure history.
    const unrelated = `${f.model.provider}/${f.model.id}`;
    activeRegistry.modelQueue!.recordUsageLimit("worker", unrelated, "fixture plan limit");
    await activeRegistry.modelQueue!.publishProjection();
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
      scope: "mac", status: "published", models: ["queue-child/mac"] });
    await activeRegistry.dispose();
    expect(await readdir(join(f.tronHome, "gateway", "model-queue-sessions"))).toEqual([]);
  }, 120_000);
});
