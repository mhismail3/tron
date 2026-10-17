/**
 * Home controls the workers it starts through its `task` tool with the smallest calls a model
 * makes first try (#961). Home runs on a local Anthropic Messages endpoint, so every definition
 * and call crosses pi-ai's real request builder and response parser: the test reads the tool
 * definition the model actually receives and the tool results it actually reads back. Workers run
 * on the faux model in a real RuntimeRegistry, and their stuck command is a real bash process.
 */
import { createServer, type Server } from "node:http";
import { setHomeMemoryModels } from "../../test-support/settings-dependencies.js";
import type { AddressInfo } from "node:net";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { fauxAssistantMessage, fauxToolCall, type Context } from "@earendil-works/pi-ai";
import { afterAll, afterEach, describe, expect, it } from "vitest";
import { waitFor } from "../../test-support/wait-for.js";
import type { RuntimeSlot } from "../sessions/runtime-slot.js";
import { disposeFixtures, fixture, reportCall } from "../../test-support/home-task-fixture.js";

const PROVIDER = "local-anthropic";
const MODEL_ID = "home-wire";
const REPORT = "test-results/home-task-tool.json";
const evidence: Array<Record<string, unknown>> = [];
const servers: Server[] = [];
afterEach(async () => {
  await disposeFixtures();
  for (const server of servers.splice(0)) await new Promise<void>(resolve => server.close(() => resolve()));
});
afterAll(async () => {
  await mkdir("test-results", { recursive: true });
  await writeFile(REPORT, `${JSON.stringify({ suite: "home-task-tool", evidence }, null, 2)}\n`);
});

type Body = { tools?: Array<{ name: string; description: string; input_schema: Record<string, unknown> }>; messages: Array<{ role: string; content: unknown }> };
type ToolResult = { type: "tool_result"; tool_use_id: string; content: Array<{ type: string; text?: string }> | string; is_error?: boolean };

/** A minimal Anthropic Messages endpoint for Home: each request is recorded; a queued tool call
 * answers a request that does not already carry a tool result, and text answers every other. */
async function homeEndpoint() {
  const requests: Body[] = [];
  const calls: Array<{ name: string; input: unknown }> = [];
  const server = createServer((request, response) => {
    let raw = "";
    request.on("data", chunk => { raw += chunk; });
    request.on("end", () => {
      const body = JSON.parse(raw) as Body;
      requests.push(body);
      const last = body.messages.at(-1);
      const answersTool = Array.isArray(last?.content) && (last.content as Array<{ type: string }>).some(block => block.type === "tool_result");
      const tool = answersTool ? undefined : calls.shift();
      const event = (type: string, data: Record<string, unknown>) => `event: ${type}\ndata: ${JSON.stringify({ type, ...data })}\n\n`;
      const n = requests.length;
      const block = tool
        ? event("content_block_start", { index: 0, content_block: { type: "tool_use", id: `toolu_${n}`, name: tool.name, input: {} } })
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

/** The newest user message text a faux worker turn saw. */
const lastUser = (context: Context) => {
  const content = context.messages.findLast(message => message.role === "user")?.content;
  return typeof content === "string" ? content : (content ?? []).map(part => part.type === "text" ? part.text : "").join("");
};
/** A gate a held worker provider turn waits on; Stop's abort also ends it. */
function gate() {
  let open!: () => void;
  const opened = new Promise<void>(resolve => { open = resolve; });
  return { open, wait: (signal?: AbortSignal) => new Promise<void>((resolve, reject) => {
    void opened.then(resolve);
    signal?.addEventListener("abort", () => reject(new Error("stopped")), { once: true });
  }) };
}
const alive = (pid: number) => { try { process.kill(pid, 0); return true; } catch { return false; } };

/** The scripted caller's idle observation is not an admission reservation: a task
 * result can wake Home before prompt reaches the session lane. The optional fixture
 * barrier forces exactly that interleaving without delaying or mocking the runtime. */
async function promptHomeControl(home: RuntimeSlot, text: string, afterIdle?: () => Promise<void>) {
  await waitFor(() => !home.isBusy && home.snapshot().configurationBlocker === null, "Home idle");
  await afterIdle?.();
  return home.prompt(text);
}

describe("Home's task tool on the wire (#961)", () => {
  it("admits a control exactly once when a task-result wake wins the idle-to-prompt race (#1231)", async () => {
    const f = await fixture();
    await setHomeMemoryModels(f.registry, [{ provider: f.model.provider, id: f.model.id }]);
    const home = await f.registry.acquire(f.home.sessionId);
    const finishWorker = gate(), finishWake = gate();
    let wakeStarted = false;
    const inputs: string[] = [];
    const results: unknown[] = [];
    f.faux.setResponses([
      async (_context, options) => {
        await finishWorker.wait(options?.signal);
        return fauxAssistantMessage([reportCall("race-result", "Ready")], { stopReason: "toolUse" });
      },
      async (_context, options) => {
        wakeStarted = true;
        await finishWake.wait(options?.signal);
        return fauxAssistantMessage("Wake handled");
      },
      context => {
        inputs.push(lastUser(context));
        return fauxAssistantMessage([fauxToolCall("task", { action: "status", taskId: "race-worker" })], { stopReason: "toolUse" });
      },
      context => {
        results.push(context.messages.at(-1));
        return fauxAssistantMessage("Control handled");
      },
    ]);
    const run = await f.registry.homeOwner().dispatchTask(f.home.sessionId, { taskId: "race-worker", intent: "Finite work", target: f.cwd });
    try {
      await promptHomeControl(home, "Inspect race-worker", async () => {
        finishWorker.open();
        await run.completion;
        await waitFor(() => wakeStarted, "real task-result wake owns Home");
        expect(home.isBusy).toBe(true);
      });
    } finally {
      finishWorker.open();
      finishWake.open();
    }
    await waitFor(() => results.length === 1 && !home.isBusy, "queued control and wake settle");
    expect(inputs).toEqual(["Inspect race-worker"]);
    expect(results).toEqual([expect.objectContaining({ role: "toolResult", toolName: "task", isError: false })]);
    const entries = home.canonicalSessionEntries();
    expect(entries.filter(entry => entry.type === "message" && entry.message.role === "user")).toHaveLength(1);
    expect(entries.filter(entry => entry.type === "custom_message" && entry.customType === "tron.home-task-result.v1")).toHaveLength(1);
    expect((await f.registry.homeOwner().taskResult("race-worker")).wake?.state).toBe("acknowledged");
    evidence.push({ case: "idle-to-prompt-wake-race", inputs, results });
  });
  it("lists, steers, stops a worker stuck in a long command, resumes it in place and steers it again with minimal calls", async () => {
    const wire = await homeEndpoint();
    const f = await fixture(false, false, undefined, false, { providers: { [PROVIDER]: {
      baseUrl: `http://127.0.0.1:${wire.port}`, api: "anthropic-messages", apiKey: "local-test-key",
      models: [{ id: MODEL_ID, name: "Home (local wire)", reasoning: false, input: ["text"], contextWindow: 1_000_000, maxTokens: 4_096 }],
    } } });
    const home = await f.registry.acquire(f.home.sessionId);
    await home.setModel(PROVIDER, MODEL_ID);
    // The memory summarizer is the fixture's stub; Home only needs a configured memory model.
    await setHomeMemoryModels(f.registry, [{ provider: f.model.provider, id: f.model.id }]);

    /** One Home turn in which the model makes exactly `input` as its `task` call; returns the
     * tool result the model reads back on the wire. */
    const homeCalls = async (name: string, input: Record<string, unknown>) => {
      const before = wire.requests.length;
      wire.calls.push({ name, input });
      await promptHomeControl(home, `call ${name} ${JSON.stringify(input)}`);
      await waitFor(() => !home.isBusy && home.snapshot().configurationBlocker === null && wire.requests.length >= before + 2, `Home's ${name} turn`).catch(error => {
        throw new Error(`${error.message}; requests=${wire.requests.length - before}; blocker=${home.snapshot().configurationBlocker}; tail=${JSON.stringify(home.canonicalSessionEntries().slice(-4)).slice(0, 3000)}`);
      });
      const answer = wire.requests.slice(before).find(body => JSON.stringify(body.messages.at(-1)).includes("tool_result"))!;
      const result = (answer.messages.at(-1)!.content as ToolResult[]).find(block => block.type === "tool_result")!;
      const text = typeof result.content === "string" ? result.content : result.content.map(part => part.text ?? "").join("");
      evidence.push({ call: { name, input }, isError: result.is_error === true, result: text.slice(0, 600) });
      return { isError: result.is_error === true, text, json: () => JSON.parse(text) as Record<string, any> };
    };

    // 1. The definition the model receives: one flat object, every field named and described.
    await homeCalls("task", { action: "list" });
    const definition = wire.requests[0]!.tools!.find(tool => tool.name === "task")!;
    const schema = definition.input_schema as { type: string; properties: Record<string, { description?: string; enum?: string[] }>; required: string[] };
    expect(schema.type).toBe("object");
    expect(Object.keys(schema.properties).sort()).toEqual(["action", "limit", "offset", "operationId", "taskId", "text"]);
    expect(schema.properties.action!.enum).toEqual(["list", "status", "report", "steer", "interrupt", "stop", "resume"]);
    expect(schema.required).toEqual(["action"]);
    for (const [field, property] of Object.entries(schema.properties)) expect(property.description, field).toBeTruthy();
    expect(definition.description).toMatch(/stop \{taskId\}/u);
    evidence.push({ definition });

    // The worker: its first turn holds until Home steers it; the steer arrives in its next turn,
    // which runs a command that ignores SIGTERM and would sleep for ten minutes.
    const pidFile = join(f.cwd, "stuck.pid");
    const firstTurn = gate(), resumedTurn = gate();
    const seen: string[] = [];
    let turns = 0;
    f.faux.setResponses(Array.from({ length: 12 }, () => async (context: Context, options?: { signal?: AbortSignal }) => {
      turns += 1;
      const text = lastUser(context);
      seen.push(text.slice(0, 200));
      const lastMessage = context.messages.at(-1);
      if (lastMessage?.role === "toolResult") return fauxAssistantMessage("command finished");
      if (text.includes("STEER-TWO")) return fauxAssistantMessage([reportCall("tool-journey", "Resumed and steered")], { stopReason: "toolUse" });
      if (text.includes("STEER-ONE")) {
        return fauxAssistantMessage([fauxToolCall("bash", { command: `bash -c 'echo $$ > ${pidFile}; trap "" TERM; exec sleep 600'` }, { id: "stuck" })], { stopReason: "toolUse" });
      }
      if (text.includes("Continue Home task")) { await resumedTurn.wait(options?.signal); return fauxAssistantMessage("resumed, waiting"); }
      await firstTurn.wait(options?.signal);
      return fauxAssistantMessage("working");
    }));

    // 2. Home delegates; list (status without taskId) shows the running worker and its controls.
    const delegated = await homeCalls("delegate", { taskId: "wire-worker", title: "Wire worker", intent: "Finite work", target: f.cwd,
      model: { provider: f.model.provider, id: f.model.id }, reason: "The scripted worker model" });
    expect(delegated.isError, delegated.text).toBe(false);
    const listed = await homeCalls("task", { action: "status" });
    expect(listed.isError, listed.text).toBe(false);
    const row = listed.json().tasks.find((task: { taskId: string }) => task.taskId === "wire-worker");
    expect(row).toMatchObject({ state: "running", actions: ["status", "steer", "interrupt", "stop"] });
    expect(row.sessionId).toEqual(expect.any(String));
    expect(row.operationId).toMatch(/^task-/u);
    const workerSession = row.sessionId as string;

    // 3. Steer with only taskId and text: the running worker receives it without stopping.
    const steered = await homeCalls("task", { action: "steer", taskId: "wire-worker", text: "STEER-ONE" });
    expect(steered.isError, steered.text).toBe(false);
    expect(steered.json()).toMatchObject({ accepted: true, taskId: "wire-worker", operationId: row.operationId });
    firstTurn.open();
    await waitFor(async () => { try { return alive(Number(await readFile(pidFile, "utf8"))); } catch { return false; } }, "the stuck command running");
    const stuckPid = Number(await readFile(pidFile, "utf8"));
    expect(seen.some(text => text.includes("STEER-ONE"))).toBe(true);
    expect((await f.registry.homeOwner().taskStatus("wire-worker")).lifecycle).toBe("active");

    // 4. Stop with only taskId ends the worker stuck in the command and kills it.
    const stopStarted = Date.now();
    const stopped = await homeCalls("task", { action: "stop", taskId: "wire-worker" });
    expect(stopped.isError, stopped.text).toBe(false);
    await waitFor(async () => (await f.registry.homeOwner().taskStatus("wire-worker")).lifecycle === "terminal", "the stopped task settling");
    const stopMs = Date.now() - stopStarted;
    expect((await f.registry.homeOwner().taskStatus("wire-worker")).terminalEvidence).toMatchObject({ outcome: "interrupted", reason: "task-stop" });
    await waitFor(() => !alive(stuckPid), "the stuck command's process to end");
    expect(stopMs).toBeLessThan(30_000);
    evidence.push({ stuckPid, stopMs });

    // A control that does not apply names the state and what to do instead.
    const late = await homeCalls("task", { action: "steer", taskId: "wire-worker", text: "too late" });
    expect(late.isError).toBe(true);
    expect(late.text).toMatch(/"wire-worker" is settled \(interrupted: task-stop\), so steer does not apply\. Use resume/u);

    // 5. Resume with only taskId continues the same worker session in place.
    const resumed = await homeCalls("task", { action: "resume", taskId: "wire-worker" });
    expect(resumed.isError, resumed.text).toBe(false);
    expect(resumed.json()).toMatchObject({ accepted: true, taskId: "wire-worker.resume-1", sessionId: workerSession, resumes: "wire-worker" });
    await waitFor(() => turns > 0 && seen.at(-1)!.includes("Continue Home task"), "the resumed worker's turn");

    // 6. Steer again by the original taskId: it reaches the worker's current, resumed task.
    const again = await homeCalls("task", { action: "steer", taskId: "wire-worker", text: "STEER-TWO" });
    expect(again.isError, again.text).toBe(false);
    expect(again.json()).toMatchObject({ accepted: true, taskId: "wire-worker.resume-1", resolvedFrom: "wire-worker", sessionId: workerSession });
    resumedTurn.open();
    await waitFor(async () => (await f.registry.homeOwner().taskStatus("wire-worker.resume-1")).lifecycle === "terminal", "the resumed task reporting");
    expect((await f.registry.homeOwner().taskStatus("wire-worker.resume-1")).terminalEvidence).toMatchObject({ outcome: "final" });

    // 7. A mistyped taskId and a guessed field are refused with the fix in the message.
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
  }, 120_000);
});

describe("Stop of a worker blocked in a tool that ignores cancellation (#961)", () => {
  it("abandons the stuck call after the grace, settles the task as stopped and resumes it in place", async () => {
    const f = await fixture();
    // A project tool that never returns and ignores its abort signal, as a blocked extension or MCP call does.
    const extensionDir = join(f.cwd, ".pi", "extensions");
    await mkdir(extensionDir, { recursive: true });
    await writeFile(join(extensionDir, "hang.ts"), `export default function (pi) {
      pi.registerTool({ name: "hang", label: "Hang", description: "Never returns", parameters: { type: "object", properties: {} },
        execute: () => new Promise(() => {}) });
    }`);
    let entered = false;
    const seen: string[] = [];
    f.faux.setResponses([
      () => { entered = true; return fauxAssistantMessage([fauxToolCall("hang", {}, { id: "hang-1" })], { stopReason: "toolUse" }); },
      (context: Context) => { seen.push(lastUser(context)); return fauxAssistantMessage([reportCall("after-hang", "Continued after the stuck tool")], { stopReason: "toolUse" }); },
    ]);
    const run = await f.registry.homeOwner().dispatchTask(f.home.sessionId, { taskId: "hung", intent: "Finite work", target: f.cwd });
    const worker = await f.registry.acquire(run.sessionId!);
    await waitFor(() => entered && worker.snapshot().phase === "running", "the worker blocked in its tool");
    const started = Date.now();
    expect(await f.registry.homeOwner().taskTool(f.home.sessionId, { action: "stop", taskId: "hung" })).toMatchObject({ accepted: true, taskId: "hung" });
    const stopMs = Date.now() - started;
    expect((await run.completion).terminalEvidence).toMatchObject({ outcome: "interrupted", reason: "task-stop" });
    const abandoned = worker.canonicalSessionEntries().find(entry => entry.type === "message" && entry.message.role === "toolResult" && entry.message.toolName === "hang");
    expect(JSON.stringify(abandoned)).toMatch(/Tool hang did not stop within 2000 ms of cancellation/u);
    expect(stopMs).toBeLessThan(10_000);

    const resumed = await f.registry.homeOwner().taskTool(f.home.sessionId, { action: "resume", taskId: "hung", text: "Skip the stuck tool" }) as { taskId: string; sessionId: string };
    expect(resumed).toMatchObject({ taskId: "hung.resume-1", sessionId: run.sessionId });
    await waitFor(async () => (await f.registry.homeOwner().taskStatus("hung.resume-1")).lifecycle === "terminal", "the resumed task settling");
    expect((await f.registry.homeOwner().taskStatus("hung.resume-1")).terminalEvidence).toMatchObject({ outcome: "final" });
    expect(seen[0]).toMatch(/Skip the stuck tool/u);
    evidence.push({ case: "stop-abandons-tool-ignoring-cancellation", stopMs, resumed: resumed.taskId, sessionId: resumed.sessionId });
  }, 60_000);
});

describe("Interrupt of a worker's in-flight command (#1189)", () => {
  it("ends only the running command and its whole tree; the worker reads the interrupt, then the steer, and reports", async () => {
    const f = await fixture();
    // The shell trap proves SIGINT cleanup. One child shares its process group;
    // another runs in its own session, as gate shards and XCTest do, so only
    // the descendant cut reaches it.
    await writeFile(join(f.cwd, "stuck.sh"), `trap 'echo released > released; exit 130' INT
sleep 600 &
echo $! > group-child.pid
perl -e 'use POSIX; POSIX::setsid(); $SIG{TERM} = sub { open(T, ">terminated"); print T "terminated"; close T; exit 143 }; open(F, ">session-child.pid"); print F $$; close F; sleep 600' &
echo $$ > shell.pid
wait
`);
    const results: string[] = [];
    const seen: string[] = [];
    const order: string[] = [];
    f.faux.setResponses([
      () => fauxAssistantMessage([fauxToolCall("bash", { command: "bash stuck.sh" }, { id: "land" })], { stopReason: "toolUse" }),
      (context: Context) => {
        const result = context.messages.findLast(message => message.role === "toolResult");
        results.push(JSON.stringify(result?.content ?? null));
        seen.push(lastUser(context));
        // The steer follows the interrupted result directly.
        order.push(context.messages.slice(-2).map(message => message.role).join(","));
        // Next, a command that ignores SIGINT and SIGTERM, as a wedged child can.
        return fauxAssistantMessage([fauxToolCall("bash", { command: "trap '' INT TERM; echo $$ > stubborn.pid; exec sleep 600" }, { id: "stubborn" })], { stopReason: "toolUse" });
      },
      (context: Context) => {
        const result = context.messages.findLast(message => message.role === "toolResult");
        results.push(JSON.stringify(result?.content ?? null));
        return fauxAssistantMessage([reportCall("after-interrupt", "Interrupted and continued")], { stopReason: "toolUse" });
      },
    ]);
    const run = await f.registry.homeOwner().dispatchTask(f.home.sessionId, { taskId: "lander", intent: "Finite work", target: f.cwd });
    const pid = async (name: string) => { try { return Number(await readFile(join(f.cwd, name), "utf8")); } catch { return 0; } };
    await waitFor(async () => (await pid("shell.pid")) > 0 && (await pid("session-child.pid")) > 0 && (await pid("group-child.pid")) > 0, "the command and its children running");
    const pids = { shell: await pid("shell.pid"), groupChild: await pid("group-child.pid"), sessionChild: await pid("session-child.pid") };
    for (const value of Object.values(pids)) expect(alive(value)).toBe(true);

    const started = Date.now();
    const interrupted = await f.registry.homeOwner().taskTool(f.home.sessionId, { action: "interrupt", taskId: "lander", text: "INTERRUPT-STEER skip the land" });
    expect(interrupted).toMatchObject({ accepted: true, action: "interrupt", taskId: "lander", sessionId: run.sessionId, interrupted: ["bash"] });
    await waitFor(() => Object.values(pids).every(value => !alive(value)), "the command's whole process tree to end");
    const killMs = Date.now() - started;
    // SIGINT reached the command first, so its cleanup ran; the child in its own session, which
    // the group signal misses, still got SIGTERM before any SIGKILL.
    expect(await readFile(join(f.cwd, "released"), "utf8")).toBe("released\n");
    expect(await readFile(join(f.cwd, "terminated"), "utf8")).toBe("terminated");

    expect(killMs).toBeLessThan(5_000);
    expect((await f.registry.homeOwner().taskStatus("lander")).lifecycle).toBe("active");

    // The maintainer's interrupt escalates to SIGKILL for a command that ignores SIGINT and SIGTERM.
    await waitFor(async () => (await pid("stubborn.pid")) > 0, "the stubborn command running");
    const stubborn = await pid("stubborn.pid");
    const operationId = (await f.registry.homeOwner().taskStatus("lander")).operationId!;
    const escalation = Date.now();
    expect(await f.registry.homeOwner().interruptTask({ taskId: "lander", operationId })).toEqual({ interrupted: ["bash"] });
    // The escalation itself takes 10 s (SIGINT, 5 s, SIGTERM, 5 s, SIGKILL), over the shared bound.
    await waitFor(() => !alive(stubborn), "the stubborn command to be killed", { boundMs: 20_000 });
    const escalationMs = Date.now() - escalation;
    expect(escalationMs).toBeGreaterThanOrEqual(9_000);

    const settled = await run.completion;
    expect(settled.terminalEvidence).toMatchObject({ outcome: "final", reason: "explicit-report", sessionId: run.sessionId });
    expect(results[0]).toMatch(/Interrupted by Home: this bash call was cancelled before it finished/u);
    expect(results[0]).toMatch(/Command aborted/u);
    expect(seen[0]).toMatch(/INTERRUPT-STEER skip the land/u);
    expect(order[0]).toBe("toolResult,user");
    expect(results[1]).toMatch(/Interrupted by the maintainer: this bash call was cancelled/u);
    evidence.push({ case: "interrupt-in-flight-command", pids, killMs, escalationMs, results: results.map(text => text.slice(0, 400)), steer: seen[0] });

    // Interrupt applies only to a running worker.
    await expect(f.registry.homeOwner().taskTool(f.home.sessionId, { action: "interrupt", taskId: "lander" })).rejects.toThrow(/is settled .*so interrupt does not apply/u);
  }, 60_000);
});
