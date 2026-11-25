import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { fauxAssistantMessage, fauxToolCall, type Context } from "@earendil-works/pi-ai";
import { afterAll, afterEach, describe, expect, it } from "vitest";
import { waitFor } from "../../../../test-support/wait-for.js";
import { disposeFixtures, fixture, reportCall } from "../../../../test-support/home-task-fixture.js";
import { homeOwnerOf } from "../../../../test-support/gateway-registry.js";
import { droppingAnyTurnFrame } from "../../../../test-support/turn-frame.js";

const REPORT = "test-results/home-task-tool-interrupt.json";
const evidence: Array<Record<string, unknown>> = [];
afterEach(disposeFixtures);
afterAll(async () => {
  await mkdir("test-results", { recursive: true });
  await writeFile(REPORT, `${JSON.stringify({ suite: "home-task-tool-interrupt", evidence }, null, 2)}\n`);
});

const lastUser = (context: Context) => {
  const content = droppingAnyTurnFrame(context.messages).findLast(message => message.role === "user")?.content;
  return typeof content === "string" ? content : (content ?? []).map(part => part.type === "text" ? part.text : "").join("");
};
const alive = (pid: number) => { try { process.kill(pid, 0); return true; } catch { return false; } };

describe("Interrupt of a worker's in-flight command (#1189)", () => {
  it("ends only the running command and its whole tree; the worker reads the interrupt, then the steer, and reports", async () => {
    const f = await fixture();
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
        order.push(droppingAnyTurnFrame(context.messages).slice(-2).map(message => message.role).join(","));
        return fauxAssistantMessage([fauxToolCall("bash", { command: "trap '' INT TERM; echo $$ > stubborn.pid; exec sleep 600" }, { id: "stubborn" })], { stopReason: "toolUse" });
      },
      (context: Context) => {
        const result = context.messages.findLast(message => message.role === "toolResult");
        results.push(JSON.stringify(result?.content ?? null));
        seen.push(lastUser(context));
        return fauxAssistantMessage([reportCall("after-interrupt", "Interrupted and continued")], { stopReason: "toolUse" });
      },
    ]);
    const run = await homeOwnerOf(f.registry).dispatchTask(f.home.sessionId, { taskId: "lander", intent: "Finite work", target: f.cwd });
    const pid = async (name: string) => { try { return Number(await readFile(join(f.cwd, name), "utf8")); } catch { return 0; } };
    await waitFor(async () => (await pid("shell.pid")) > 0 && (await pid("session-child.pid")) > 0 && (await pid("group-child.pid")) > 0, "the command and its children running");
    const pids = { shell: await pid("shell.pid"), groupChild: await pid("group-child.pid"), sessionChild: await pid("session-child.pid") };
    for (const value of Object.values(pids)) expect(alive(value)).toBe(true);

    const started = Date.now();
    const interrupted = await homeOwnerOf(f.registry).taskTool(f.home.sessionId, { action: "interrupt", taskId: "lander", text: "INTERRUPT-STEER skip the land" });
    expect(interrupted).toMatchObject({ accepted: true, action: "interrupt", taskId: "lander", sessionId: run.sessionId, interrupted: ["bash"] });
    await waitFor(() => Object.values(pids).every(value => !alive(value)), "the command's whole process tree to end");
    const killMs = Date.now() - started;
    expect(await readFile(join(f.cwd, "released"), "utf8")).toBe("released\n");
    expect(await readFile(join(f.cwd, "terminated"), "utf8")).toBe("terminated");

    expect(killMs).toBeLessThan(5_000);
    expect((await homeOwnerOf(f.registry).taskStatus("lander")).lifecycle).toBe("active");

    await waitFor(async () => (await pid("stubborn.pid")) > 0, "the stubborn command running");
    const stubborn = await pid("stubborn.pid");
    const operationId = (await homeOwnerOf(f.registry).taskStatus("lander")).operationId!;
    const escalation = Date.now();
    expect(await homeOwnerOf(f.registry).interruptTask({ taskId: "lander", operationId, text: "MAINTAINER-INTERRUPT finish" })).toEqual({ interrupted: ["bash"] });
    await waitFor(() => !alive(stubborn), "the stubborn command to be killed", { boundMs: 20_000 });
    const escalationMs = Date.now() - escalation;
    expect(escalationMs).toBeGreaterThanOrEqual(9_000);

    const settled = await run.completion;
    expect(settled.terminalEvidence).toMatchObject({ outcome: "final", reason: "explicit-report", sessionId: run.sessionId });
    expect(results[0]).toMatch(/Interrupted by Home: this bash call was cancelled before it finished/u);
    expect(results[0]).toMatch(/Command aborted/u);
    expect(seen).toEqual(["[from: tron-home; kind: steer; authority: task]\nINTERRUPT-STEER skip the land",
      "[from: maintainer; kind: steer; authority: task]\nMAINTAINER-INTERRUPT finish"]);
    expect(order[0]).toBe("toolResult,user");
    expect(results[1]).toMatch(/Interrupted by the maintainer: this bash call was cancelled/u);
    evidence.push({ case: "interrupt-in-flight-command", pids, killMs, escalationMs, results: results.map(text => text.slice(0, 400)), steer: seen[0] });

    await expect(homeOwnerOf(f.registry).taskTool(f.home.sessionId, { action: "interrupt", taskId: "lander" })).rejects.toThrow(/is settled .*so interrupt does not apply/u);
  }, 60_000);
});
