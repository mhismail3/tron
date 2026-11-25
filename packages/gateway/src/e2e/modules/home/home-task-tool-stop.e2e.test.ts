import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { fauxAssistantMessage, fauxToolCall, type Context } from "@earendil-works/pi-ai";
import { afterAll, afterEach, describe, expect, it } from "vitest";
import { waitFor } from "../../../../test-support/wait-for.js";
import { disposeFixtures, fixture, reportCall } from "../../../../test-support/home-task-fixture.js";
import { homeOwnerOf } from "../../../../test-support/gateway-registry.js";
import { droppingAnyTurnFrame } from "../../../../test-support/turn-frame.js";

const REPORT = "test-results/home-task-tool-stop.json";
const evidence: Array<Record<string, unknown>> = [];
afterEach(disposeFixtures);
afterAll(async () => {
  await mkdir("test-results", { recursive: true });
  await writeFile(REPORT, `${JSON.stringify({ suite: "home-task-tool-stop", evidence }, null, 2)}\n`);
});

const lastUser = (context: Context) => {
  const content = droppingAnyTurnFrame(context.messages).findLast(message => message.role === "user")?.content;
  return typeof content === "string" ? content : (content ?? []).map(part => part.type === "text" ? part.text : "").join("");
};

describe("Stop of a worker blocked in a tool that ignores cancellation (#961)", () => {
  it("abandons the stuck call after the grace, settles the task as stopped and resumes it in place", async () => {
    const f = await fixture();
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
    const run = await homeOwnerOf(f.registry).dispatchTask(f.home.sessionId, { taskId: "hung", intent: "Finite work", target: f.cwd });
    const worker = await f.registry.acquire(run.sessionId!);
    await waitFor(() => entered && worker.snapshot().phase === "running", "the worker blocked in its tool");
    const started = Date.now();
    expect(await homeOwnerOf(f.registry).taskTool(f.home.sessionId, { action: "stop", taskId: "hung" })).toMatchObject({ accepted: true, taskId: "hung" });
    const stopMs = Date.now() - started;
    expect((await run.completion).terminalEvidence).toMatchObject({ outcome: "interrupted", reason: "task-stop" });
    const abandoned = worker.canonicalSessionEntries().find(entry => entry.type === "message" && entry.message.role === "toolResult" && entry.message.toolName === "hang");
    expect(JSON.stringify(abandoned)).toMatch(/Tool hang did not stop within 2000 ms of cancellation/u);
    expect(stopMs).toBeLessThan(10_000);

    const resumed = await homeOwnerOf(f.registry).taskTool(f.home.sessionId, { action: "resume", taskId: "hung", text: "Skip the stuck tool" }) as { taskId: string; sessionId: string };
    expect(resumed).toMatchObject({ taskId: "hung.resume-1", sessionId: run.sessionId });
    await waitFor(async () => (await homeOwnerOf(f.registry).taskStatus("hung.resume-1")).lifecycle === "terminal", "the resumed task settling");
    expect((await homeOwnerOf(f.registry).taskStatus("hung.resume-1")).terminalEvidence).toMatchObject({ outcome: "final" });
    expect(seen[0]).toMatch(/Skip the stuck tool/u);
    evidence.push({ case: "stop-abandons-tool-ignoring-cancellation", stopMs, resumed: resumed.taskId, sessionId: resumed.sessionId });
  }, 60_000);
});
