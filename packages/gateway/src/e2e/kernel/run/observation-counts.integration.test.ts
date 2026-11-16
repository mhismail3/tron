import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { mkdir, mkdtemp, readdir, readFile, realpath, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { afterEach, expect, it, vi } from "vitest";
import { createTestRegistry } from "../../../../test-support/gateway-registry.js";
import { waitFor } from "../../../../test-support/wait-for.js";
import { TrustService } from "../../../kernel/resources/trust-service.js";
import { ObservationCounts } from "../../../transport/observation-counts.js";

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
  vi.unstubAllEnvs();
});

type Block = { type: "text"; text: string } | { type: "tool_use"; id: string; name: string; input: Record<string, unknown> };

const sse = (model: string, block: Block) => [
  { type: "message_start", message: { id: "msg_counts", type: "message", role: "assistant", model, content: [], stop_reason: null,
    usage: { input_tokens: 4, output_tokens: 0, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 } } },
  { type: "content_block_start", index: 0, content_block: block.type === "text" ? { type: "text", text: "" } : { ...block, input: {} } },
  { type: "content_block_delta", index: 0, delta: block.type === "text" ? { type: "text_delta", text: block.text } : { type: "input_json_delta", partial_json: JSON.stringify(block.input) } },
  { type: "content_block_stop", index: 0 },
  { type: "message_delta", delta: { stop_reason: block.type === "text" ? "end_turn" : "tool_use" }, usage: { output_tokens: 1 } },
  { type: "message_stop" },
].map(event => `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`).join("");

it("counts a session's requests, gaps, named tool calls and advertised-skill opens by role and day, content-free, across a restart", async () => {
  const root = await realpath(await mkdtemp(join(tmpdir(), "tron-counts-")));
  cleanups.push(() => rm(root, { recursive: true, force: true }));
  const agentDir = join(root, "agent");
  const project = join(root, "project");
  const skillPath = join(agentDir, "skills", "counted-skill", "SKILL.md");
  await mkdir(join(agentDir, "skills", "counted-skill"), { recursive: true });
  await mkdir(project);
  await writeFile(skillPath, "---\nname: counted-skill\ndescription: Counted skill\n---\nBody\n");
  await writeFile(join(project, "notes.txt"), "plain notes\n");
  vi.stubEnv("PI_CODING_AGENT_DIR", agentDir);
  vi.stubEnv("HOME", root);
  vi.stubEnv("PI_OFFLINE", "1");
  const replies: Block[] = [
    { type: "tool_use", id: "toolu_skill", name: "read", input: { path: "~/agent/skills/counted-skill/SKILL.md" } },
    { type: "tool_use", id: "toolu_notes", name: "read", input: { path: "notes.txt" } },
    { type: "text", text: "done" },
  ];
  const server = createServer((request, response) => {
    let text = "";
    request.on("data", chunk => { text += String(chunk); });
    request.on("end", () => response.writeHead(200, { "content-type": "text/event-stream" }).end(sse(String(JSON.parse(text).model), replies.shift()!)));
  });
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
  cleanups.push(() => new Promise<void>(resolve => server.close(() => resolve())));
  const model = { provider: "counts", id: "counts-model" };
  await writeFile(join(agentDir, "settings.json"), JSON.stringify({ retry: { enabled: false }, compaction: { enabled: false } }));
  await writeFile(join(agentDir, "models.json"), JSON.stringify({ providers: { [model.provider]: {
    baseUrl: `http://127.0.0.1:${(server.address() as AddressInfo).port}`, api: "anthropic-messages", apiKey: "fixture-only-not-a-credential",
    models: [{ id: model.id, name: "Counts fixture", reasoning: false, input: ["text"], contextWindow: 128000, maxTokens: 1024,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }],
  } } }));
  const trust = new TrustService(agentDir);
  await trust.set(project, true);
  const directory = join(root, "tron", "logs", "observations");
  await mkdir(directory, { recursive: true });
  for (let day = 1; day <= 31; day += 1) await writeFile(join(directory, `2000-01-${String(day).padStart(2, "0")}.json`), "{}\n");
  const counts = new ObservationCounts(directory);
  let requests = 0;
  const registry = await createTestRegistry({
    agentDir, tronHome: join(root, "tron"), trust, idleRuntimeMs: 60_000,
    requestRecord: record => { counts.request(record); requests += 1; },
    capabilityDiagnostic: aggregate => counts.call(aggregate),
    modelRuntimeFactory: () => ModelRuntime.create({ modelsPath: join(agentDir, "models.json"), refreshOnCreate: false }),
    broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
  });
  cleanups.push(() => registry.dispose());
  await registry.initialize();
  const slot = await registry.create(project);
  await slot.setModel(model.provider, model.id);
  await slot.prompt("open the skill, then the notes");
  await waitFor(() => !slot.isBusy && requests === 3, "the three requests of the turn");

  const today = new Date().toISOString().slice(0, 10);
  const files = (await readdir(directory)).sort();
  expect(files).toHaveLength(30);
  expect(files.at(-1)).toBe(`${today}.json`);
  expect(files[0]).toBe("2000-01-03.json");
  const text = await readFile(join(directory, `${today}.json`), "utf8");
  expect(JSON.parse(text)).toEqual({ day: today, since: expect.stringMatching(new RegExp(`^${today}T`, "u")), kinds: { ordinary: {
    requests: 3, skillIndexRequests: 3, gaps: { lt5m: 2, lt1h: 0, gte1h: 0 }, calls: { read: 2 }, skillOpens: { "counted-skill": 1 },
  } } });
  for (const content of [root, "notes.txt", "plain notes", "Body", "open the skill"]) expect(text).not.toContain(content);

  new ObservationCounts(directory).call({ name: "read", kind: "ordinary", status: "error", skill: "counted-skill" });
  expect(JSON.parse(await readFile(join(directory, `${today}.json`), "utf8")).kinds.ordinary).toMatchObject({
    requests: 3, calls: { read: 3 }, skillOpens: { "counted-skill": 1 },
  });
}, 30_000);
