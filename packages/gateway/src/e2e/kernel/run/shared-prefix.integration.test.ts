import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { mkdir, mkdtemp, realpath, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { afterEach, expect, it, vi } from "vitest";
import { createTestRegistry } from "../../../../test-support/gateway-registry.js";
import { waitFor } from "../../../../test-support/wait-for.js";
import { TrustService } from "../../../kernel/resources/trust-service.js";
import type { RequestRecord } from "../../../kernel/run/request-record.js";
import type { RuntimeRegistry } from "../../../kernel/session/runtime-registry.js";

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
  vi.unstubAllEnvs();
});

const sse = (model: string) => [
  { type: "message_start", message: { id: "msg_prefix", type: "message", role: "assistant", model, content: [], stop_reason: null,
    usage: { input_tokens: 4, output_tokens: 0, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 } } },
  { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } },
  { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "ok" } },
  { type: "content_block_stop", index: 0 },
  { type: "message_delta", delta: { stop_reason: "end_turn" }, usage: { output_tokens: 1 } },
  { type: "message_stop" },
].map(event => `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`).join("");

it("gives two projects of the same role and tools one request prefix up to the shared system mark", async () => {
  const root = await realpath(await mkdtemp(join(tmpdir(), "tron-shared-prefix-")));
  cleanups.push(() => rm(root, { recursive: true, force: true }));
  const agentDir = join(root, "agent");
  await mkdir(join(agentDir, "skills", "global-skill"), { recursive: true });
  await writeFile(join(agentDir, "AGENTS.md"), "Global rule: shared by every project.");
  await writeFile(join(agentDir, "skills", "global-skill", "SKILL.md"), "---\nname: global-skill\ndescription: Shared skill\n---\nBody\n");
  const projects = ["alpha", "beta"].map(name => join(root, name));
  for (const project of projects) {
    await mkdir(join(project, ".pi", "skills", "project-skill"), { recursive: true });
    await writeFile(join(project, "AGENTS.md"), `Project rule for ${project}.`);
    await writeFile(join(project, ".pi", "skills", "project-skill", "SKILL.md"), "---\nname: project-skill\ndescription: Project skill\n---\nBody\n");
  }
  vi.stubEnv("PI_CODING_AGENT_DIR", agentDir);
  vi.stubEnv("HOME", root);
  vi.stubEnv("PI_OFFLINE", "1");
  const bodies: Array<{ system: Array<{ text: string; cache_control?: unknown }> }> = [];
  const server = createServer((request, response) => {
    let text = "";
    request.on("data", chunk => { text += String(chunk); });
    request.on("end", () => {
      const body = JSON.parse(text);
      bodies.push(body);
      response.writeHead(200, { "content-type": "text/event-stream" }).end(sse(String(body.model)));
    });
  });
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
  cleanups.push(() => new Promise<void>(resolve => server.close(() => resolve())));
  const model = { provider: "shared-prefix", id: "prefix-model" };
  await writeFile(join(agentDir, "settings.json"), JSON.stringify({ retry: { enabled: false }, compaction: { enabled: false } }));
  await writeFile(join(agentDir, "models.json"), JSON.stringify({ providers: { [model.provider]: {
    baseUrl: `http://127.0.0.1:${(server.address() as AddressInfo).port}`, api: "anthropic-messages", apiKey: "fixture-only-not-a-credential",
    models: [{ id: model.id, name: "Prefix fixture", reasoning: false, input: ["text"], contextWindow: 128000, maxTokens: 1024,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }],
  } } }));
  const trust = new TrustService(agentDir);
  for (const project of projects) await trust.set(project, true);
  const records: RequestRecord[] = [];
  const registry: RuntimeRegistry = await createTestRegistry({
    agentDir, tronHome: join(root, "tron"), trust, idleRuntimeMs: 60_000, requestRecord: record => records.push(record),
    modelRuntimeFactory: () => ModelRuntime.create({ modelsPath: join(agentDir, "models.json"), refreshOnCreate: false }),
    broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
  });
  cleanups.push(() => registry.dispose());
  await registry.initialize();
  for (const project of projects) {
    const slot = await registry.create(project);
    await slot.setModel(model.provider, model.id);
    await slot.prompt("hello");
    await waitFor(() => !slot.isBusy, `the ${project} turn`);
  }
  await waitFor(() => records.length === 2, "both request records");

  for (const body of bodies) {
    expect(body.system).toHaveLength(2);
    expect(body.system[0]!.cache_control).toBeDefined();
    expect(body.system[1]!.cache_control).toBeUndefined();
    expect(body.system[0]!.text).toContain("Global rule: shared by every project.");
    expect(body.system[0]!.text).toContain("<name>global-skill</name>");
    expect(body.system[1]!.text.startsWith("<project_context>")).toBe(true);
  }
  expect(bodies[1]!.system[0]!.text).toBe(bodies[0]!.system[0]!.text);
  for (const [index, project] of projects.entries()) {
    expect(bodies[index]!.system[0]!.text).not.toContain(project);
    expect(bodies[index]!.system[1]!.text).toContain(project);
  }
  const [first, second] = records;
  expect(first!.system).toHaveLength(2);
  expect(first!.marks.some(mark => mark.at === ".system[0]")).toBe(true);
  expect(second!.system[0]).toEqual(first!.system[0]);
  expect(second!.system[1]!.hash).not.toBe(first!.system[1]!.hash);
}, 30_000);
