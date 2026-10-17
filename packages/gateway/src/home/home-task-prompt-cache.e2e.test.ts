/**
 * A Home task worker's prompt cache, proved on the wire (#1250). The worker runs in a real
 * RuntimeRegistry on a local OpenAI Responses endpoint, so every request crosses pi-ai's real
 * request builder and usage parser. The endpoint records each body and reports usage the way
 * OpenAI does: `input_tokens` includes `input_tokens_details.cached_tokens`.
 *
 * It proves the two things a cache regression needs: across the worker's turns the request
 * prefix (instructions, tools, earlier input items) is byte-stable and carries one
 * `prompt_cache_key`; and the task's published spend keeps fresh input apart from cache reads,
 * so a cache-read token is never counted as fresh input.
 */
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { mkdir, readFile, readdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { afterAll, afterEach, describe, expect, it } from "vitest";
import { disposeFixtures, fixture } from "../../test-support/home-task-fixture.js";

const PROVIDER = "local-openai";
const MODEL_ID = "worker-wire";
const REPORT = "test-results/home-task-prompt-cache.json";
const evidence: Array<Record<string, unknown>> = [];
const servers: Server[] = [];
afterEach(async () => {
  await disposeFixtures();
  for (const server of servers.splice(0)) await new Promise<void>(resolve => server.close(() => resolve()));
});
afterAll(async () => {
  await mkdir("test-results", { recursive: true });
  await writeFile(REPORT, `${JSON.stringify({ suite: "home-task-prompt-cache", evidence }, null, 2)}\n`);
});

type Body = { model: string; input: unknown[]; tools?: unknown[]; prompt_cache_key?: string; [key: string]: unknown };
interface Usage { input: number; cached: number; output: number }

/** The worker's script: two tool turns, then the sealed report. Each response reports the
 * previous request's whole prompt as cached, the way a warm prefix cache answers. */
async function responsesEndpoint() {
  const requests: Body[] = [];
  const usages: Usage[] = [];
  const script = [
    { name: "bash", arguments: { command: "echo cache-one" } },
    { name: "bash", arguments: { command: "echo cache-two" } },
    { name: "report", arguments: { resultId: "cache-report", outcome: "final", text: "Cache verified", evidence: ["wire requests recorded"] } },
  ];
  const server = createServer((request, response) => {
    let raw = "";
    request.on("data", chunk => { raw += chunk; });
    request.on("end", () => {
      const body = JSON.parse(raw) as Body;
      requests.push(body);
      const n = requests.length;
      const step = script[Math.min(n - 1, script.length - 1)]!;
      const input = Buffer.byteLength(JSON.stringify(body.input)) + Buffer.byteLength(JSON.stringify(body.tools ?? []));
      const cached = n === 1 ? 0 : Math.min(input, usages.at(-1)!.input);
      const usage = { input, cached, output: 11 + n };
      usages.push(usage);
      const item = { type: "function_call", id: `fc_${n}`, call_id: `call_${n}`, name: step.name, arguments: JSON.stringify(step.arguments), status: "completed" };
      const event = (type: string, data: Record<string, unknown>) => `event: ${type}\ndata: ${JSON.stringify({ type, ...data })}\n\n`;
      response.writeHead(200, { "content-type": "text/event-stream" });
      response.end(
        event("response.output_item.added", { output_index: 0, item })
        + event("response.output_item.done", { output_index: 0, item })
        + event("response.completed", { response: { id: `resp_${n}`, status: "completed", output: [item], usage: {
          input_tokens: usage.input, output_tokens: usage.output, total_tokens: usage.input + usage.output,
          input_tokens_details: { cached_tokens: usage.cached } } } }),
      );
    });
  });
  servers.push(server);
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
  return { port: (server.address() as AddressInfo).port, requests, usages };
}

describe("Home task worker prompt cache on the wire", { concurrent: false }, () => {
  it("keeps a stable prefix and one cache key across turns, and records cache reads apart from fresh input", async () => {
    const wire = await responsesEndpoint();
    const f = await fixture(false, false, undefined, false, { providers: { [PROVIDER]: {
      baseUrl: `http://127.0.0.1:${wire.port}`, api: "openai-responses", apiKey: "local-test-key",
      models: [{ id: MODEL_ID, name: "Worker (local wire)", reasoning: false, input: ["text"], contextWindow: 1_000_000, maxTokens: 4_096 }],
    } } });
    const run = await f.registry.homeOwner().dispatchTask(f.home.sessionId, {
      taskId: "cache-worker", intent: "Finite work", target: f.cwd, model: { provider: PROVIDER, id: MODEL_ID } });
    const final = await run.completion;
    expect(final.terminalEvidence?.outcome).toBe("final");
    expect(wire.requests).toHaveLength(3);

    // One cache key, the worker's own session, on every request.
    const keys = wire.requests.map(body => body.prompt_cache_key);
    expect(keys.every(key => key === run.sessionId)).toBe(true);
    // Each request extends the previous one: the same tools in the same order and every
    // earlier input item byte-identical (system/developer text included), so no per-turn
    // nonce, timestamp or rebuilt prompt invalidates the cached prefix.
    for (let i = 1; i < wire.requests.length; i++) {
      const previous = wire.requests[i - 1]!, next = wire.requests[i]!;
      expect(JSON.stringify(next.tools)).toBe(JSON.stringify(previous.tools));
      expect(next.input.length).toBeGreaterThan(previous.input.length);
      expect(JSON.stringify(next.input.slice(0, previous.input.length))).toBe(JSON.stringify(previous.input));
    }

    // Spend keeps fresh input, cache read and cache write apart; OpenAI's input_tokens
    // includes the cached tokens, which must not reappear as fresh input.
    const fresh = wire.usages.reduce((sum, usage) => sum + usage.input - usage.cached, 0);
    const cacheRead = wire.usages.reduce((sum, usage) => sum + usage.cached, 0);
    const output = wire.usages.reduce((sum, usage) => sum + usage.output, 0);
    expect(cacheRead).toBeGreaterThan(fresh);
    const expected = { inputTokens: fresh, cacheReadTokens: cacheRead, cacheWriteTokens: 0, outputTokens: output };
    expect(final.spend).toMatchObject(expected);
    // The durable record carries the same split, and the diagnostic reports it.
    const tasks = join(f.tronHome, "gateway/home/tasks");
    const file = (await readdir(tasks)).find(name => name.endsWith("cache-worker.json"))!;
    expect(JSON.parse(await readFile(join(tasks, file), "utf8")).spend).toMatchObject(expected);
    expect(f.signals.filter(signal => signal.event === "home.task.spend").at(-1)).toMatchObject(expected);
    evidence.push({ case: "worker-openai-responses", cacheKeys: keys, inputItems: wire.requests.map(body => body.input.length), usages: wire.usages, spend: final.spend });
  }, 30_000);
});
