import { mkdir, writeFile } from "node:fs/promises";
import fc from "fast-check";
import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { afterEach, expect, it } from "vitest";
import { fixture, disposeFixtures, reportCall } from "../../../test-support/home-task-fixture.js";
import { homeOwnerOf } from "../../../test-support/gateway-registry.js";
import { waitFor } from "../../../test-support/wait-for.js";
import type { HomeTaskHandle } from "../../modules/home/home-task-dispatcher.js";
import { enabledTaskAction, initialTaskModel, stepTaskModel, type TaskAction, type TaskLifecycleModel } from "./task-lifecycle.reference-model.js";

type Fixture = Awaited<ReturnType<typeof fixture>>;
interface Real {
  fixture: Fixture;
  runs: HomeTaskHandle[];
  release?: () => void;
  entered: number;
  trace: string[];
}
const evidence: unknown[] = [];
afterEach(async () => {
  await disposeFixtures();
  await mkdir("test-results/proof-spike", { recursive: true });
  await writeFile("test-results/proof-spike/lifecycle.json", JSON.stringify(evidence, null, 2));
});

async function assertConforms(model: TaskLifecycleModel, real: Real): Promise<void> {
  expect(real.runs).toHaveLength(model.state === "absent" ? 0 : model.generation + 1);
  const owner = homeOwnerOf(real.fixture.registry);
  const wakes = new Set<string>();
  for (const [index, run] of real.runs.entries()) {
    const task = await owner.taskStatus(run.taskId);
    expect(task.sessionId).toBe(real.runs[0]!.sessionId);
    expect(task.operationId).toBe(run.operationId);
    if (index < model.outcomes.length) {
      expect(task.lifecycle).toBe("terminal");
      expect(task.terminalEvidence?.outcome).toBe(model.outcomes[index]);
      expect(task.wake).not.toBeNull();
      expect(wakes.has(task.wake!.eventId)).toBe(false);
      wakes.add(task.wake!.eventId);
    } else {
      expect(task.lifecycle).toBe("active");
      expect(task.wake).toBeNull();
    }
  }
  if (model.state === "terminal") {
    const slot = await real.fixture.registry.acquire(real.runs.at(-1)!.sessionId);
    await waitFor(() => slot.snapshot().configurationBlocker === null, "terminal worker releases its real run owner");
    expect(slot.hasActiveAgentRun).toBe(false);
    expect(slot.snapshot().operation).toBeUndefined();
    expect(slot.snapshot().processActivities?.filter(row => row.visibility === "active") ?? []).toEqual([]);
  }
}

class TaskCommand implements fc.AsyncCommand<TaskLifecycleModel, Real> {
  constructor(readonly action: TaskAction) {}
  check(model: Readonly<TaskLifecycleModel>): boolean { return enabledTaskAction(model, this.action); }
  toString(): string { return this.action; }
  async run(model: TaskLifecycleModel, real: Real): Promise<void> {
    const owner = homeOwnerOf(real.fixture.registry);
    const current = real.runs.at(-1);
    real.trace.push(this.action);
    if (this.action === "start" || this.action === "resume") {
      let release!: () => void;
      const released = new Promise<void>(resolve => { release = resolve; });
      real.release = release;
      const entered = real.entered;
      real.fixture.faux.setResponses([
        async (_context, options) => {
          real.entered += 1;
          await new Promise<void>((resolve, reject) => {
            const abort = () => reject(new Error("reference-model Stop"));
            if (options?.signal?.aborted) { abort(); return; }
            options?.signal?.addEventListener("abort", abort, { once: true });
            void released.then(() => { options?.signal?.removeEventListener("abort", abort); resolve(); });
          });
          return fauxAssistantMessage("Work is complete; the report follows.");
        },
        fauxAssistantMessage([reportCall(`result-${real.runs.length}`)], { stopReason: "toolUse" }),
      ]);
      const run = this.action === "start"
        ? await owner.dispatchTask(real.fixture.home.sessionId, { taskId: "model-worker", intent: "Finite reference-model work", target: real.fixture.cwd })
        : await owner.resumeTask({ taskId: current!.taskId, operationId: current!.operationId });
      real.runs.push(run);
      await waitFor(() => real.entered > entered, "model worker enters the real Pi provider");
      if (current) expect(run.operationId).not.toBe(current.operationId);
    } else if (this.action === "stop" || this.action === "report") {
      if (this.action === "stop") await owner.stopTask({ taskId: current!.taskId, operationId: current!.operationId });
      else real.release!();
      await current!.completion;
    } else if (this.action === "terminal-stop") {
      await expect(owner.stopTask({ taskId: current!.taskId, operationId: current!.operationId })).rejects.toThrow();
    }
    stepTaskModel(model, this.action);
    await assertConforms(model, real);
  }
}

async function scenario(commands: Iterable<fc.AsyncCommand<TaskLifecycleModel, Real>>): Promise<void> {
  const f = await fixture();
  const real: Real = { fixture: f, runs: [], entered: 0, trace: [] };
  const model = initialTaskModel();
  try {
    await fc.asyncModelRun(() => ({ model, real }), commands);
    evidence.push({ trace: real.trace, model, sessions: real.runs.map(run => run.sessionId) });
  } catch (error) {
    evidence.push({ trace: real.trace, model, error: String(error) });
    throw error;
  } finally {
    real.release?.();
    const current = real.runs.at(-1);
    if (current) {
      await homeOwnerOf(f.registry).stopTask({ taskId: current.taskId, operationId: current.operationId }).catch(() => {});
      await current.completion;
    }
    await disposeFixtures();
  }
}

it("conforms after Stop, repeated terminal control, report-only reminder and same-session resume", async () => {
  await scenario(["start", "stop", "terminal-stop", "resume", "report", "observe", "resume", "stop"].map(action => new TaskCommand(action as TaskAction)));
}, 60_000);

it("conforms step by step for replayable generated task command sequences", async () => {
  const commands = fc.commands([fc.constantFrom<TaskAction>("start", "stop", "report", "resume", "observe", "terminal-stop").map(action => new TaskCommand(action))], { maxCommands: 12 });
  await fc.assert(fc.asyncProperty(commands, async trace => { await scenario([new TaskCommand("start"), ...trace]); }), {
    seed: Number(process.env.TRON_MODEL_SEED ?? 1890), numRuns: 40,
  });
}, 120_000);
