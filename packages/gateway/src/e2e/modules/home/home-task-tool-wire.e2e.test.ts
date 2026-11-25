import { execFileSync } from "node:child_process";
import { createServer, type Server } from "node:http";
import { setHomeMemoryModels } from "../../../../test-support/settings-dependencies.js";
import type { AddressInfo } from "node:net";
import { mkdir, readFile, readdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { fauxAssistantMessage, fauxToolCall, type Context } from "@earendil-works/pi-ai";
import { afterAll, afterEach, describe, expect, it } from "vitest";
import { waitFor } from "../../../../test-support/wait-for.js";
import type { RuntimeSlot } from "../../../kernel/run/runtime-slot.js";
import { disposeFixtures, fixture, reportCall } from "../../../../test-support/home-task-fixture.js";
import { homeOwnerOf } from "../../../../test-support/gateway-registry.js";
import type { HomeTaskDispatcher } from "../../../modules/home/home-task-dispatcher.js";
import { droppingAnyTurnFrame } from "../../../../test-support/turn-frame.js";

const PROVIDER = "local-anthropic";
const MODEL_ID = "home-wire";
const REPORT = "test-results/home-task-tool-wire.json";
const evidence: Array<Record<string, unknown>> = [];
const servers: Server[] = [];
afterEach(async () => {
  await disposeFixtures();
  for (const server of servers.splice(0)) await new Promise<void>(resolve => server.close(() => resolve()));
});
afterAll(async () => {
  await mkdir("test-results", { recursive: true });
  await writeFile(REPORT, `${JSON.stringify({ suite: "home-task-tool-wire", evidence }, null, 2)}\n`);
});

type Body = { tools?: Array<{ name: string; description: string; input_schema: Record<string, unknown> }>; messages: Array<{ role: string; content: string | Array<ToolResult | { type: "text"; text: string } | { type: "tool_use"; id: string }> }> };
type ToolResult = { type: "tool_result"; tool_use_id: string; content: Array<{ type: string; text?: string }> | string; is_error?: boolean };

async function homeEndpoint() {
  const requests: Body[] = [];
  const calls: Array<{ id: string; prompt: string; name: string; input: unknown }> = [];
  const server = createServer((request, response) => {
    let raw = "";
    request.setEncoding("utf8");
    request.on("data", chunk => { raw += chunk; });
    request.on("end", () => {
      const body = JSON.parse(raw) as Body;
      requests.push(body);
      const last = droppingAnyTurnFrame(body.messages).at(-1);
      const answersTool = Array.isArray(last?.content) && last.content.some(block => block.type === "tool_result");
      const text = typeof last?.content === "string" ? last.content : (last?.content ?? []).map(block => block.type === "text" ? block.text : "").join("\n");
      const index = answersTool ? -1 : calls.findIndex(call => text.includes(call.prompt));
      const tool = index < 0 ? undefined : calls.splice(index, 1)[0];
      const event = (type: string, data: Record<string, unknown>) => `event: ${type}\ndata: ${JSON.stringify({ type, ...data })}\n\n`;
      const n = requests.length;
      const block = tool
        ? event("content_block_start", { index: 0, content_block: { type: "tool_use", id: tool.id, name: tool.name, input: {} } })
          + event("content_block_delta", { index: 0, delta: { type: "input_json_delta", partial_json: JSON.stringify(tool.input) } })
        : event("content_block_start", { index: 0, content_block: { type: "text", text: "" } })
          + event("content_block_delta", { index: 0, delta: { type: "text_delta", text: `done ${n}` } });
      response.writeHead(200, { "content-type": "text/event-stream" });
      response.end(event("message_start", { message: { id: `msg_${n}`, type: "message", role: "assistant", model: MODEL_ID, content: [],
        stop_reason: null, stop_sequence: null, usage: { input_tokens: 10, output_tokens: 5 } } })
        + block + event("content_block_stop", { index: 0 })
        + event("message_delta", { delta: { stop_reason: tool ? "tool_use" : "end_turn", stop_sequence: null }, usage: { output_tokens: 5 } })
        + event("message_stop", {}));
    });
  });
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
  servers.push(server);
  return { port: (server.address() as AddressInfo).port, requests, calls };
}

const lastUser = (context: Context) => {
  const content = droppingAnyTurnFrame(context.messages).findLast(message => message.role === "user")?.content;
  return typeof content === "string" ? content : (content ?? []).map(part => part.type === "text" ? part.text : "").join("");
};
function gate() {
  let open!: () => void;
  const opened = new Promise<void>(resolve => { open = resolve; });
  return { open, wait: (signal?: AbortSignal) => new Promise<void>((resolve, reject) => {
    void opened.then(resolve);
    signal?.addEventListener("abort", () => reject(new Error("stopped")), { once: true });
  }) };
}
const alive = (pid: number) => { try { process.kill(pid, 0); return true; } catch { return false; } };
const argsOf = (pid: number) => { try { return execFileSync("ps", ["-o", "args=", "-p", String(pid)], { encoding: "utf8" }).trim(); } catch { return ""; } };

async function promptHomeControl(home: RuntimeSlot, text: string, afterIdle?: () => Promise<void>) {
  await waitFor(() => !home.isBusy && home.snapshot().configurationBlocker === null, "Home idle");
  await afterIdle?.();
  return home.prompt(text, [], "followUp");
}

describe("Home's task tool on the wire (#961)", () => {
  it("lists, steers, stops a worker stuck in a long command, resumes it in place and steers it again with minimal calls", async () => {
    const wire = await homeEndpoint();
    const f = await fixture(false, false, undefined, false, { providers: { [PROVIDER]: {
      baseUrl: `http://127.0.0.1:${wire.port}`, api: "anthropic-messages", apiKey: "local-test-key",
      models: [{ id: MODEL_ID, name: "Home (local wire)", reasoning: false, input: ["text"], contextWindow: 1_000_000, maxTokens: 4_096 }],
    } } });
    const home = await f.registry.acquire(f.home.sessionId);
    await setHomeMemoryModels(f.registry, [{ provider: f.model.provider, id: f.model.id }]);
    await home.setModel(PROVIDER, MODEL_ID);

    const homeCalls = async (name: string, input: Record<string, unknown>) => {
      const before = wire.requests.length;
      const id = `control_${before}`;
      const prompt = `${id}: call ${name} ${JSON.stringify(input)}`;
      wire.calls.push({ id, prompt, name, input });
      const readResult = () => wire.requests.slice(before).flatMap(body => {
        const content = droppingAnyTurnFrame(body.messages).at(-1)?.content;
        return Array.isArray(content) ? content.filter((block): block is ToolResult => block.type === "tool_result" && block.tool_use_id === id) : [];
      })[0];
      await promptHomeControl(home, prompt);
      await waitFor(() => !home.isBusy && home.snapshot().configurationBlocker === null && readResult() !== undefined, `Home's ${name} turn`).catch(error => {
        throw new Error(`${error.message}; requests=${wire.requests.length - before}; blocker=${home.snapshot().configurationBlocker}; tail=${JSON.stringify(home.canonicalSessionEntries().slice(-4)).slice(0, 3000)}`);
      });
      const result = readResult()!;
      const text = typeof result.content === "string" ? result.content : result.content.map(part => part.text ?? "").join("");
      evidence.push({ call: { name, input }, isError: result.is_error === true, result: text.slice(0, 600) });
      return { isError: result.is_error === true, text, json: () => JSON.parse(text) as Record<string, any> };
    };

    expect((await homeCalls("task", { action: "list" })).json().host).toBe("unavailable");
    const sweep = (homeOwnerOf(f.registry) as unknown as { tasks: HomeTaskDispatcher }).tasks.commands;
    await sweep.dispose();
    const definition = wire.requests[0]!.tools!.find(tool => tool.name === "task")!;
    const schema = definition.input_schema as { type: string; properties: Record<string, { description?: string; enum?: string[] }>; required: string[] };
    expect(schema.type).toBe("object");
    expect(Object.keys(schema.properties).sort()).toEqual(["action", "from", "limit", "offset", "operationId", "subagentSessionId", "taskId", "text", "title", "to"]);
    expect(schema.properties.action!.enum).toEqual(["list", "status", "report", "transcript", "metrics", "steer", "interrupt", "stop", "resume", "rename"]);
    expect(schema.required).toEqual(["action"]);
    for (const [field, property] of Object.entries(schema.properties)) expect(property.description, field).toBeTruthy();
    expect(definition.description).toMatch(/stop \{taskId\}/u);
    const settingsDefinition = wire.requests[0]!.tools!.find(tool => tool.name === "settings")!;
    const settingsSchema = settingsDefinition.input_schema as { properties: Record<string, { description?: string; enum?: string[] }>; required: string[] };
    expect(Object.keys(settingsSchema.properties).sort()).toEqual(["action", "actor", "changeId", "changes", "cursor", "dryRun", "key", "keys", "layer", "limit", "reason", "section", "source", "status", "taskId", "version"]);
    expect(settingsSchema.properties.action!.enum).toEqual(["resolve", "change", "history", "undo", "applyAgain", "inventory", "update"]);
    expect(settingsSchema.required).toEqual(["action"]);
    for (const [field, property] of Object.entries(settingsSchema.properties)) expect(property.description, field).toBeTruthy();
    evidence.push({ definition, settingsDefinition });

    const pidFile = join(f.cwd, "stuck.pid");
    const simulatorPidFile = join(f.cwd, "simulator.pid");
    const firstTurn = gate(), resumedTurn = gate();
    const seen: string[] = [];
    let turns = 0;
    f.faux.setResponses(Array.from({ length: 12 }, () => async (context: Context, options?: { signal?: AbortSignal }) => {
      turns += 1;
      const text = lastUser(context);
      seen.push(text.slice(0, 200));
      const lastMessage = droppingAnyTurnFrame(context.messages).at(-1);
      if (lastMessage?.role === "toolResult") return fauxAssistantMessage("command finished");
      if (text.includes("STEER-TWO")) return fauxAssistantMessage([reportCall("tool-journey", "Resumed and steered")], { stopReason: "toolUse" });
      if (text.includes("STEER-ONE")) {
        return fauxAssistantMessage([fauxToolCall("bash", { command: `bash -c 'ln -s /bin/sleep "$TMPDIR/launchd_sim"; "$TMPDIR/launchd_sim" 600 & echo $! > ${simulatorPidFile}; echo $$ > ${pidFile}; trap "" TERM; exec -a /usr/bin/xcodebuild sleep 600'` }, { id: "stuck" })], { stopReason: "toolUse" });
      }
      if (text.includes("Continue Home task")) { await resumedTurn.wait(options?.signal); return fauxAssistantMessage("resumed, waiting"); }
      await firstTurn.wait(options?.signal);
      return fauxAssistantMessage("working");
    }));

    await sweep.sweep();
    const delegated = await homeCalls("delegate", { taskId: "wire-worker", title: "Wire worker", intent: "Finite work", target: f.cwd,
      model: { provider: f.model.provider, id: f.model.id }, reason: "The scripted worker model" });
    expect(delegated.isError, delegated.text).toBe(false);
    const listed = await homeCalls("task", { action: "status" });
    expect(listed.isError, listed.text).toBe(false);
    const row = listed.json().tasks.find((task: { taskId: string }) => task.taskId === "wire-worker");
    expect(row).toMatchObject({ state: "running", title: "Wire worker", actions: ["status", "steer", "interrupt", "stop", "rename"] });
    expect(row.sessionId).toEqual(expect.any(String));
    expect(row.operationId).toMatch(/^task-/u);
    expect(listed.json().host.heavy).toEqual({ "wire-worker": "unavailable" });
    const early = await homeCalls("task", { action: "report", taskId: "wire-worker" });
    expect(early.isError, early.text).toBe(false);
    expect(early.json()).toMatchObject({ taskId: "wire-worker", settled: false, control: { state: "running" }, next: expect.stringMatching(/wakes Home by itself: end this turn now/u) });
    const earlyStatus = await homeCalls("task", { action: "status", taskId: "wire-worker" });
    expect(earlyStatus.isError, earlyStatus.text).toBe(false);
    expect(earlyStatus.json()).toMatchObject({ taskId: "wire-worker", control: { state: "running" }, next: expect.stringMatching(/wakes Home by itself: end this turn now/u) });
    await sweep.sweep();
    expect((await homeCalls("task", { action: "list" })).json().host.heavy).toEqual({ "wire-worker": [] });
    const workerSession = row.sessionId as string;

    const worker = await f.registry.acquire(workerSession);
    const sessionName = async () => (await f.registry.catalog("all")).sessions.find(session => session.id === workerSession)?.name;
    expect(await sessionName()).toBe("Wire worker");
    const renamed = await homeCalls("task", { action: "rename", taskId: "wire-worker", title: "Renamed wire worker" });
    expect(renamed.isError, renamed.text).toBe(false);
    expect(renamed.json()).toMatchObject({ accepted: true, action: "rename", taskId: "wire-worker", sessionId: workerSession, state: "running",
      title: "Renamed wire worker", previousTitle: "Wire worker" });
    expect((await homeCalls("task", { action: "status" })).json().tasks.find((task: { taskId: string }) => task.taskId === "wire-worker"))
      .toMatchObject({ state: "running", title: "Renamed wire worker", sessionId: workerSession, operationId: row.operationId });
    await waitFor(async () => await sessionName() === "Renamed wire worker" || undefined, "the session list showing the new title");
    expect(worker.snapshot().phase).toBe("running");
    expect(worker.canonicalSessionEntries().filter(entry => entry.type === "session_info").map(entry => (entry as { name?: string }).name))
      .toEqual(["Wire worker", "Renamed wire worker"]);
    expect((await homeOwnerOf(f.registry).taskStatus("wire-worker")).intent.text).toContain("Finite work");
    const blank = await homeCalls("task", { action: "rename", taskId: "wire-worker", title: "   " });
    expect(blank.isError).toBe(true);
    expect(blank.text).toMatch(/"title" must be 1 to 80 characters on one line/u);
    const noTitle = await homeCalls("task", { action: "rename", taskId: "wire-worker", name: "Other" });
    expect(noTitle.isError).toBe(true);
    expect(noTitle.text).toMatch(/field "name" is unknown; rename takes action, taskId, title\. Put the new title in "title"/u);
    const unknownTask = await homeCalls("task", { action: "rename", taskId: "wire-wroker", title: "Other" });
    expect(unknownTask.isError).toBe(true);
    expect(unknownTask.text).toMatch(/no task "wire-wroker"/u);
    await expect(homeOwnerOf(f.registry).taskTool(workerSession, { action: "rename", taskId: "wire-worker", title: "Hijacked" }))
      .rejects.toThrow(/Home task control is unavailable/u);
    expect(await sessionName()).toBe("Renamed wire worker");
    expect(f.signals).toContainEqual(expect.objectContaining({ event: "home.task.control", action: "rename", disposition: "accepted" }));
    expect(f.signals).toContainEqual(expect.objectContaining({ event: "home.task.control", action: "rename", disposition: "refused", reason: "invalid_request" }));

    const steered = await homeCalls("task", { action: "steer", taskId: "wire-worker", text: "STEER-ONE" });
    expect(steered.isError, steered.text).toBe(false);
    expect(steered.json()).toMatchObject({ accepted: true, taskId: "wire-worker", operationId: row.operationId });
    firstTurn.open();
    await waitFor(async () => { try { return alive(Number(await readFile(pidFile, "utf8"))); } catch { return false; } }, "the stuck command running");
    const stuckPid = Number(await readFile(pidFile, "utf8"));
    const simulatorPid = Number(await readFile(simulatorPidFile, "utf8"));
    await waitFor(() => argsOf(stuckPid).startsWith("/usr/bin/xcodebuild ") && argsOf(simulatorPid).endsWith("/launchd_sim 600"), "the stuck command's heavy process and simulator stand-in");
    await sweep.sweep();
    const reading = (await homeCalls("task", { action: "status" })).json().host;
    expect(reading).toEqual({ sampledAt: expect.any(String), cpuBusyPercent: expect.any(Number), memoryFreePercent: expect.any(Number),
      simulatorsBooted: expect.any(Number), heavy: { "wire-worker": ["xcodebuild"] } });
    expect(Date.parse(reading.sampledAt)).toBeGreaterThan(Date.now() - 60_000);
    for (const percent of [reading.cpuBusyPercent, reading.memoryFreePercent]) expect(percent >= 0 && percent <= 100, String(percent)).toBe(true);
    expect(reading.simulatorsBooted).toBeGreaterThanOrEqual(1);
    expect((await homeCalls("task", { action: "status", taskId: "wire-worker" })).json().host).toEqual(reading);
    evidence.push({ host: reading });
    expect(seen.some(text => text.includes("STEER-ONE"))).toBe(true);
    expect((await homeOwnerOf(f.registry).taskStatus("wire-worker")).lifecycle).toBe("active");

    const stopStarted = Date.now();
    const stopped = await homeCalls("task", { action: "stop", taskId: "wire-worker" });
    expect(stopped.isError, stopped.text).toBe(false);
    await waitFor(async () => (await homeOwnerOf(f.registry).taskStatus("wire-worker")).lifecycle === "terminal", "the stopped task settling");
    const stopMs = Date.now() - stopStarted;
    expect((await homeOwnerOf(f.registry).taskStatus("wire-worker")).terminalEvidence).toMatchObject({ outcome: "interrupted", reason: "task-stop" });
    await waitFor(() => !alive(stuckPid) && !alive(simulatorPid), "the stuck command's processes to end");
    await sweep.sweep();
    expect((await homeCalls("task", { action: "list" })).json().host.heavy).toEqual({});
    expect(stopMs).toBeLessThan(30_000);
    evidence.push({ stuckPid, stopMs });

    const late = await homeCalls("task", { action: "steer", taskId: "wire-worker", text: "too late" });
    expect(late.isError).toBe(true);
    expect(late.text).toMatch(/"wire-worker" is settled \(interrupted: task-stop\), so steer does not apply\. Use resume/u);

    const resumed = await homeCalls("task", { action: "resume", taskId: "wire-worker" });
    expect(resumed.isError, resumed.text).toBe(false);
    expect(resumed.json()).toMatchObject({ accepted: true, taskId: "wire-worker.resume-1", sessionId: workerSession, resumes: "wire-worker" });
    await waitFor(() => turns > 0 && seen.at(-1)!.includes("Continue Home task"), "the resumed worker's turn");
    expect(await sessionName()).toBe("Renamed wire worker");
    expect((await homeOwnerOf(f.registry).taskStatus("wire-worker.resume-1")).title).toBe("Renamed wire worker");

    const again = await homeCalls("task", { action: "steer", taskId: "wire-worker", text: "STEER-TWO" });
    expect(again.isError, again.text).toBe(false);
    expect(again.json()).toMatchObject({ accepted: true, taskId: "wire-worker.resume-1", resolvedFrom: "wire-worker", sessionId: workerSession });
    resumedTurn.open();
    await waitFor(async () => (await homeOwnerOf(f.registry).taskStatus("wire-worker.resume-1")).lifecycle === "terminal", "the resumed task reporting");
    expect((await homeOwnerOf(f.registry).taskStatus("wire-worker.resume-1")).terminalEvidence).toMatchObject({ outcome: "final" });
    const file = (await readdir(join(f.agentDir, "sessions"), { recursive: true })).map(String).find(name => name.endsWith(".jsonl") && name.includes(workerSession));
    const persisted = (await readFile(join(f.agentDir, "sessions", file!), "utf8")).split("\n").filter(Boolean).map(line => JSON.parse(line) as { type: string; name?: string })
      .filter(entry => entry.type === "session_info").map(entry => entry.name);
    expect(persisted).toEqual(["Wire worker", "Renamed wire worker"]);
    evidence.push({ renamed: renamed.json(), persisted });

    const missing = await homeCalls("task", { action: "status", taskId: "wire-wroker" });
    expect(missing.isError).toBe(true);
    expect(missing.text).toMatch(/no task "wire-wroker"\. Close matches: "wire-worker"/u);
    const guessed = await homeCalls("task", { action: "stop", taskId: "wire-worker", generation: 1 });
    expect(guessed.isError).toBe(true);
    expect(guessed.text).toMatch(/field "generation" is unknown; stop takes action, taskId, operationId\?/u);
    const stale = await homeCalls("task", { action: "resume", taskId: "wire-worker", operationId: row.operationId });
    expect(stale.isError).toBe(true);
    expect(stale.text).toMatch(/operationId guard .* does not match "wire-worker\.resume-1"/u);
    const report = await homeCalls("task", { action: "report", taskId: "wire-worker" });
    expect(report.isError, report.text).toBe(false);
    expect(report.json()).toMatchObject({ taskId: "wire-worker", offset: 0 });

    const taskDirectory = join(f.tronHome, "state", "home", "tasks");
    const files = (await readdir(taskDirectory)).sort();
    const beforeMetrics = await Promise.all(files.map(file => readFile(join(taskDirectory, file), "utf8")));
    const metricsCall = await homeCalls("task", { action: "metrics", taskId: "wire-worker" });
    expect(metricsCall.isError, metricsCall.text).toBe(false);
    const metrics = metricsCall.json();
    expect(metrics.coverage).toMatchObject({ matchedLineages: 1, returnedLineages: 1, more: false, checkins: "retained-only" });
    expect(metrics.tasks).toHaveLength(1);
    expect(metrics.tasks[0]).toMatchObject({ taskId: "wire-worker", resumes: 1, delegateToLandedMs: null,
      steerCount: null, waitingMs: { fullSuite: null, lock: null, reviewer: null }, spendUsd: null,
      tokens: { status: "recorded", recordedOperations: 2, admittedOperations: 2 } });
    const firstRecord = await homeOwnerOf(f.registry).taskStatus("wire-worker");
    const resumedRecord = await homeOwnerOf(f.registry).taskStatus("wire-worker.resume-1");
    const promptTokens = (spend: NonNullable<typeof firstRecord.spend>) => spend.inputTokens + (spend.cacheReadTokens ?? 0) + (spend.cacheWriteTokens ?? 0);
    expect(metrics.tasks[0].tokens.prompt).toBe(promptTokens(firstRecord.spend!) + promptTokens(resumedRecord.spend!));
    expect(metrics.scorecard.resumesPerTask).toMatchObject({ status: "partial", value: 1, denominator: 1, admittedResumes: 1 });
    for (const field of ["approvalToMain", "deployLag", "mainReds", "flakeRate"])
      expect(metrics.scorecard[field]).toMatchObject({ status: "unavailable", value: null });
    for (const field of ["deployLag", "mainReds", "flakeRate"])
      expect(metrics.scorecard[field]).toMatchObject({ reason: "unavailable in this record-only view" });
    expect(JSON.stringify(metrics)).not.toContain("Finite work");
    expect(JSON.stringify(metrics)).not.toContain(f.cwd);
    expect(await Promise.all(files.map(file => readFile(join(taskDirectory, file), "utf8")))).toEqual(beforeMetrics);
    expect((await readdir(taskDirectory)).sort()).toEqual(files);
    await expect(homeOwnerOf(f.registry).taskTool(workerSession, { action: "metrics" })).rejects.toThrow(/Home task control is unavailable/u);
    const from = new Date(firstRecord.createdAt).toISOString();
    const to = new Date(firstRecord.createdAt + 1).toISOString();
    const included = await homeCalls("task", { action: "metrics", from, to, limit: 1 });
    expect(included.json().tasks.map((task: { taskId: string }) => task.taskId)).toEqual(["wire-worker"]);
    const excluded = await homeCalls("task", { action: "metrics", from: new Date(firstRecord.createdAt - 1).toISOString(), to: from });
    expect(excluded.json()).toMatchObject({ tasks: [], scorecard: { resumesPerTask: { value: null, denominator: 0 } } });
    for (const input of [{ from: to, to: from }, { from: "invalid" }, { limit: 51 }, { taskId: "missing" },
      { from: "2026-01-01T00:00:00Z", to: "2026-03-01T00:00:00Z" }]) {
      expect((await homeCalls("task", { action: "metrics", ...input })).isError, JSON.stringify(input)).toBe(true);
    }
    evidence.push({ metrics: metricsCall.json(), boundaryWindow: included.json() });
  }, 120_000);
});
