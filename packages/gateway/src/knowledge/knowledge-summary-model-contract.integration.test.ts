import { createServer, type Server } from "node:http";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { afterAll, afterEach, describe, expect, it } from "vitest";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { KnowledgeObservationService } from "./knowledge-observation.js";
import { KnowledgeService, QueueKnowledgeModel } from "./knowledge-service.js";
import { knowledgeModelLimits } from "./knowledge-contract.js";
import { ModelQueueOwner } from "../providers/model-queue.js";
import { KnowledgeStore } from "./knowledge-store.js";
import { waitFor } from "../../test-support/wait-for.js";

/** #292: `openai/gpt-6-luna` answered the summary prompt with prose before the
 * JSON object (live diagnostic: stopReason=stop; parts=text; codeFence=false;
 * leadingProse=true). The prompt alone cannot hold that contract, so the
 * request must carry OpenAI's strict structured-output format. This drives the
 * real summary job, the real pi-ai OpenAI Responses adapter and a real socket
 * against a test-owned Responses endpoint that, like the provider, emits the
 * recorded prose-first shape unless the request constrains the output. */
const MODEL = "openai/gpt-6-luna";
const REPORT_PATH = "test-results/knowledge-summary-model-contract/report.json";
const SUMMARY = "A synthetic note about tide tables and their saved excerpt.";
// Synthetic text in the captured shape: a prose preamble that mentions the
// evidence pack's own bracketed markers, then one unfenced JSON object.
const LEADING_PROSE = "I reviewed the saved source evidence. The capture is partial and its uri is [unknown], so this summary covers only the saved excerpt.\n\n"
  + JSON.stringify({ text: SUMMARY });

type Reply = { text: string } | { status: number };
const report: Array<Record<string, unknown>> = [];
const disposals: Array<() => Promise<void>> = [];
const originalAgentDir = process.env.PI_CODING_AGENT_DIR;
afterEach(async () => {
  for (const dispose of disposals.splice(0).reverse()) await dispose();
  if (originalAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
  else process.env.PI_CODING_AGENT_DIR = originalAgentDir;
});
afterAll(async () => {
  await mkdir(join(process.cwd(), "test-results", "knowledge-summary-model-contract"), { recursive: true });
  await writeFile(join(process.cwd(), REPORT_PATH), `${JSON.stringify({ model: MODEL, cases: report }, null, 2)}\n`);
});

/** A minimal OpenAI Responses endpoint. `reply` sees the request body, so a
 * case can answer the way the provider does with and without a format. */
async function endpoint(reply: (body: Record<string, unknown>) => Reply) {
  const requests: Array<Record<string, unknown>> = [];
  const server: Server = createServer((request, response) => {
    let raw = "";
    request.on("data", chunk => { raw += chunk; });
    request.on("end", () => {
      const body = JSON.parse(raw) as Record<string, unknown>;
      requests.push(body);
      const answer = reply(body);
      if ("status" in answer) {
        response.writeHead(answer.status, { "content-type": "application/json" });
        response.end(JSON.stringify({ error: { message: "synthetic provider failure", type: "server_error" } }));
        return;
      }
      const event = (type: string, data: Record<string, unknown>) => `event: ${type}\ndata: ${JSON.stringify({ type, ...data })}\n\n`;
      const item = { type: "message", id: "msg_1", role: "assistant", status: "completed", phase: "final_answer", content: [{ type: "output_text", text: answer.text, annotations: [] }] };
      response.writeHead(200, { "content-type": "text/event-stream" });
      response.end(
        event("response.created", { response: { id: "resp_1", status: "in_progress" } })
        + event("response.output_item.added", { output_index: 0, item: { ...item, status: "in_progress", content: [] } })
        + event("response.output_item.done", { output_index: 0, item })
        + event("response.completed", { response: { id: "resp_1", status: "completed", output: [item], usage: { input_tokens: 10, output_tokens: 5, total_tokens: 15, input_tokens_details: { cached_tokens: 0 } } } }),
      );
    });
  });
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
  return { server, port: (server.address() as AddressInfo).port, requests };
}

/** The production wiring: the background model queue resolves through the
 * Gateway's ModelRuntime (built-in `openai` provider, endpoint overridden to the
 * local socket) into the production QueueKnowledgeModel. */
async function summarize(reply: (body: Record<string, unknown>) => Reply) {
  const root = await mkdtemp(join(tmpdir(), "tron-knowledge-contract-"));
  const local = await endpoint(reply);
  disposals.push(async () => {
    await new Promise<void>(resolve => local.server.close(() => resolve()));
    await rm(root, { recursive: true, force: true });
  });
  const agentDir = join(root, "agent");
  await mkdir(agentDir, { recursive: true });
  process.env.PI_CODING_AGENT_DIR = agentDir;
  await writeFile(join(agentDir, "models.json"), JSON.stringify({ providers: { openai: { baseUrl: `http://127.0.0.1:${local.port}/v1`, apiKey: "local-test-key" } } }));
  const runtime = await ModelRuntime.create({ authPath: join(root, "auth.json"), modelsPath: join(agentDir, "models.json"), refreshOnCreate: false });
  const store = new KnowledgeStore(new TronWorkspace(join(root, "tron")));
  const config = await store.config();
  await store.configure("contract-knowledge-model", { ...config, knowledgeModel: { maxInputChars: 8_000, maxOutputChars: 2_000 } });
  const source = await store.captureSource({ commandId: "contract-capture", record: { kind: "source", scope: "research",
    provenance: { actor: "user", evidence: [] }, relations: [],
    content: { title: "Tide tables", text: "A synthetic saved excerpt about tide tables.", captureDisposition: "partial", capturedAt: "2026-01-01T00:00:00Z" } } });
  const queue = new ModelQueueOwner({ runtime, usage: { read: async () => ({ providers: [] }) }, queue: async () => [MODEL] });
  const service = new KnowledgeService(store, new KnowledgeObservationService(store, undefined), {},
    knowledgeConfig => new QueueKnowledgeModel(queue, knowledgeModelLimits(knowledgeConfig)));
  const commandId = "contract-summary";
  await service.invoke({ operation: "knowledge.source.summarize", request: { commandId, sourceId: source.record.id, expectedRevision: source.record.revisionId } });
  const job = await waitFor(async () => {
    const listed = await service.invoke({ operation: "knowledge.curation.jobs", request: { commandId } }) as { jobs: Array<{ status: string; code?: string; reason?: string }> };
    const settled = listed.jobs[0];
    return settled && settled.status !== "running" ? settled : undefined;
  }, "the summary job to settle");
  const summary = (await store.read(source.record.id))?.content;
  return { job, summary: summary && "summary" in summary ? summary.summary : undefined, requests: local.requests };
}

/** The provider's documented behavior: a strict json_schema format constrains
 * the answer to the schema; without it, Luna answers in the recorded shape. */
function luna(constrained: string): (body: Record<string, unknown>) => Reply {
  return body => ((body.text as { format?: { type?: string } } | undefined)?.format?.type === "json_schema" ? { text: constrained } : { text: LEADING_PROSE });
}

describe("Knowledge summary model JSON contract (#292)", () => {
  it("generates a summary for the recorded prose-first Luna reply shape", async () => {
    const result = await summarize(luna(JSON.stringify({ text: SUMMARY })));
    report.push({ case: "recorded-leading-prose", job: result.job, format: (result.requests[0]?.text as { format?: unknown } | undefined)?.format });
    expect(result.job).toMatchObject({ status: "done" });
    expect(result.summary?.text).toBe(SUMMARY);
    expect(result.requests).toHaveLength(1);
    expect(result.requests[0]!.text).toMatchObject({ format: { type: "json_schema", strict: true,
      schema: { type: "object", required: ["text"], additionalProperties: false } } });
  });

  // Output the contract does not admit still fails loudly as invalid model
  // output, never as a partial or silently chosen summary.
  it.each([
    ["prose before the object", LEADING_PROSE],
    ["two objects", `${JSON.stringify({ text: "first" })}\n${JSON.stringify({ text: "second" })}`],
    ["an object inside an array", JSON.stringify([{ text: SUMMARY }])],
    ["a truncated object", JSON.stringify({ text: SUMMARY }).slice(0, 20)],
    ["the wrong schema", JSON.stringify({ summary: SUMMARY })],
    ["an empty summary", JSON.stringify({ text: "  " })],
  ])("rejects %s as model-output-invalid", async (label, text) => {
    const result = await summarize(() => ({ text }));
    report.push({ case: label, job: result.job });
    expect(result.job).toMatchObject({ status: "failed", code: "model-output-invalid" });
    expect(result.job.reason).toContain(`${MODEL}: Model ${MODEL} returned invalid output (stopReason=stop; parts=text;`);
    expect(result.summary).toBeUndefined();
  });

  it("keeps a provider failure distinct from invalid output", async () => {
    const result = await summarize(() => ({ status: 400 }));
    report.push({ case: "provider-error", job: result.job });
    expect(result.job).toMatchObject({ status: "failed", code: "model-error" });
    expect(result.summary).toBeUndefined();
  });
});
