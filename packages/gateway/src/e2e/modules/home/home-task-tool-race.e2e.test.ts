import { mkdir, writeFile } from "node:fs/promises";
import { setHomeMemoryModels } from "../../../../test-support/settings-dependencies.js";
import { fauxAssistantMessage, fauxToolCall, type Context } from "@earendil-works/pi-ai";
import { afterAll, afterEach, describe, expect, it, vi } from "vitest";
import { waitFor } from "../../../../test-support/wait-for.js";
import type { RuntimeSlot } from "../../../kernel/run/runtime-slot.js";
import { disposeFixtures, fixture, reportCall } from "../../../../test-support/home-task-fixture.js";
import { homeOwnerOf } from "../../../../test-support/gateway-registry.js";
import { WakeInboxOwner } from "../../../modules/home/home-wake-inbox.js";
import { droppingAnyTurnFrame } from "../../../../test-support/turn-frame.js";

const REPORT = "test-results/home-task-tool-race.json";
const evidence: Array<Record<string, unknown>> = [];
afterEach(disposeFixtures);
afterAll(async () => {
  await mkdir("test-results", { recursive: true });
  await writeFile(REPORT, `${JSON.stringify({ suite: "home-task-tool-race", evidence }, null, 2)}\n`);
});

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

async function promptHomeControl(home: RuntimeSlot, text: string, afterIdle?: () => Promise<void>) {
  await waitFor(() => !home.isBusy && home.snapshot().configurationBlocker === null, "Home idle");
  await afterIdle?.();
  return home.prompt(text, [], "followUp");
}

describe("Home's task tool against a task-result wake (#1231, #2213)", () => {
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
        results.push(droppingAnyTurnFrame(context.messages).at(-1));
        return fauxAssistantMessage("Control handled");
      },
    ]);
    const run = await homeOwnerOf(f.registry).dispatchTask(f.home.sessionId, { taskId: "race-worker", intent: "Finite work", target: f.cwd });
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
    expect((await homeOwnerOf(f.registry).taskResult("race-worker")).wake?.state).toBe("acknowledged");
    evidence.push({ case: "idle-to-prompt-wake-race", inputs, results });
  });

  it("stays busy until the wake's inbox acknowledgement settles (#2213)", async () => {
    const f = await fixture();
    await setHomeMemoryModels(f.registry, [{ provider: f.model.provider, id: f.model.id }]);
    const home = await f.registry.acquire(f.home.sessionId);
    const finishWorker = gate(), finishWake = gate(), holdSettle = gate();
    let wakeStarted = false, settleHeld = 0;
    const settle = WakeInboxOwner.prototype.settle;
    vi.spyOn(WakeInboxOwner.prototype, "settle").mockImplementation(async function(this: WakeInboxOwner, ...args: Parameters<typeof settle>) {
      settleHeld += 1;
      await holdSettle.wait();
      return settle.apply(this, args);
    });
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
      () => fauxAssistantMessage([fauxToolCall("task", { action: "status", taskId: "race-worker" })], { stopReason: "toolUse" }),
      context => { results.push(droppingAnyTurnFrame(context.messages).at(-1)); return fauxAssistantMessage("Control handled"); },
    ]);
    try {
      const run = await homeOwnerOf(f.registry).dispatchTask(f.home.sessionId, { taskId: "race-worker", intent: "Finite work", target: f.cwd });
      try {
        await promptHomeControl(home, "Inspect race-worker", async () => {
          finishWorker.open();
          await run.completion;
          await waitFor(() => wakeStarted, "real task-result wake owns Home");
        });
      } finally { finishWorker.open(); finishWake.open(); }
      try {
        await waitFor(() => results.length === 1 && settleHeld > 0, "control answered and the wake settlement started");
        const idleEarly = await waitFor(() => !home.isBusy || undefined, "home idle", { boundMs: 1500 }).then(() => true, () => false);
        expect(idleEarly).toBe(false);
      } finally { holdSettle.open(); }
      await waitFor(() => !home.isBusy, "home idle after settlement");
      expect((await homeOwnerOf(f.registry).taskResult("race-worker")).wake?.state).toBe("acknowledged");
    } finally { holdSettle.open(); vi.restoreAllMocks(); }
  });
});
