import { createServer, type Server } from "node:http";
import { mkdir, writeFile } from "node:fs/promises";
import type { AddressInfo } from "node:net";
import { join } from "node:path";
import { fauxAssistantMessage, fauxToolCall } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { dispatch, fixture, reportCall } from "../../test-support/home-task-fixture.js";
import { setModelQueue } from "../../test-support/settings-dependencies.js";
import { closeSubagentFixtures, launchResults } from "../../test-support/home-task-subagents-support.js";

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
afterEach(async () => {
  for (const server of servers.splice(0)) await server.close();
  await closeSubagentFixtures();
});

describe("Home task subagents: the subagent model queue", () => {
  it("moves a managed subagent child to the next queue model on a usage-limit error and retries its request there", async () => {
    const provider = await queueProvider();
    servers.push(provider);
    const model = (id: string) => ({ id, name: id, reasoning: false, input: ["text"], contextWindow: 128000, maxTokens: 4096,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } });
    // Registered before any runtime starts, so the Gateway's queue sees both models.
    const f = await fixture(false, false, undefined, true, { providers: { "queue-child": {
      baseUrl: `http://127.0.0.1:${provider.port}/v1`, api: "openai-completions", apiKey: "fixture-only",
      models: [model("limited"), model("fallback")] } } });
    await mkdir(join(f.cwd, ".pi", "agents"), { recursive: true });
    await writeFile(join(f.cwd, ".pi", "agents", "queue-child.md"),
      "---\nname: queue-child\ndescription: Scripted queue child\nmodel: queue-child/limited\ntools: read\n---\nComplete the scripted task.\n");
    await setModelQueue({ registry: f.registry, agentDir: f.agentDir, tronHome: f.tronHome, trust: f.trust, modelRuntime: f.gateway },
      "subagent", ["queue-child/limited", "queue-child/fallback"]);
    f.faux.setResponses([
      fauxAssistantMessage([fauxToolCall("subagent", { agent: "queue-child", task: "queue search", async: false }, { id: "queue-launch" })], { stopReason: "toolUse" }),
      fauxAssistantMessage([reportCall()], { stopReason: "toolUse" }),
    ]);
    const run = await dispatch(f);
    const result = await run.completion;
    expect(result.terminalEvidence?.outcome).toBe("final");
    // The child's one request failed on its plan limit and ran again on the next model.
    expect(provider.requests).toEqual({ limited: 1, fallback: 1 });
    const launch = (await launchResults(f.registry, run.sessionId)).find(item => item.toolCallId === "queue-launch");
    expect(launch?.isError).toBe(false);
    expect(JSON.stringify((launch as unknown as { content: unknown }).content)).toContain("CHILD-DONE");
  }, 120_000);
});
