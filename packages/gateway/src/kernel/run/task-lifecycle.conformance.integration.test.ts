import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import type { RunMarkerStore } from "./run-markers.js";
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
  lateNotice: boolean;
  releaseStamp: () => void;
  terminalFacts: Map<string, string>;
}
const evidence: unknown[] = [];
afterEach(async () => {
  await disposeFixtures();
  await mkdir("test-results", { recursive: true });
  await writeFile("test-results/kernel-run-lifecycle.json", JSON.stringify(evidence, null, 2));
});

async function assertConforms(model: TaskLifecycleModel, real: Real): Promise<void> {
  expect(real.runs).toHaveLength(model.state === "absent" ? 0 : model.generation + 1);
  const owner = homeOwnerOf(real.fixture.registry);
  const wakes = new Set<string>();
  expect(new Set(real.runs.map(run => run.operationId)).size).toBe(real.runs.length);
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
      const fact = JSON.stringify([task.sessionId, task.operationId, task.terminalEvidence, task.reportRef, task.wake!.eventId]);
      if (real.terminalFacts.has(task.taskId)) expect(fact).toBe(real.terminalFacts.get(task.taskId));
      else real.terminalFacts.set(task.taskId, fact);
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
  } else if (model.state === "active") {
    const slot = await real.fixture.registry.acquire(real.runs.at(-1)!.sessionId);
    expect(slot.hasActiveAgentRun).toBe(true);
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
        ...(real.lateNotice && real.runs.length === 0 ? [async () => {
          const slot = await real.fixture.registry.acquire(real.runs[0]!.sessionId);
          await (slot as unknown as { runAttention: { attentionBarrier?: Promise<void> } }).runAttention.attentionBarrier;
          return fauxAssistantMessage("The background review is ready too.");
        }] : []),
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
      else {
        real.release!();
        if (real.lateNotice) {
          const slot = await real.fixture.registry.acquire(current!.sessionId);
          try {
            await waitFor(() => slot.canonicalSessionEntries().some(entry => entry.type === "custom"
              && entry.customType === "tron.chat-invocation.v1"
              && (entry.data as { receiptKind?: string }).receiptKind === "terminal"), "terminal invocation before delayed reply stamp");
          } finally { real.releaseStamp(); }
        }
      }
      await current!.completion;
    } else if (this.action === "steer") {
      await owner.maintainTask({ taskId: current!.taskId, operationId: current!.operationId, text: "Retain this operation and report its evidence." });
    } else if (this.action === "interrupt") {
      // The provider is held, with no executing tools. Interrupt must not Stop
      // the model run or mint a successor just because no tool needs abortion.
      expect(await owner.interruptTask({ taskId: current!.taskId, operationId: current!.operationId })).toEqual({ interrupted: [] });
    } else if (this.action === "terminal-stop") {
      await expect(owner.stopTask({ taskId: current!.taskId, operationId: current!.operationId })).rejects.toThrow();
    }
    stepTaskModel(model, this.action);
    await assertConforms(model, real);
  }
}

async function scenario(commands: Iterable<fc.AsyncCommand<TaskLifecycleModel, Real>>, lateNotice = false): Promise<void> {
  const f = await fixture();
  let releaseStamp = () => {};
  if (lateNotice) {
    const directory = join(f.cwd, ".pi", "extensions");
    await mkdir(directory, { recursive: true });
    await writeFile(join(directory, "model-late-notice.ts"), `export default function(pi) {
      let sent = false;
      pi.on("turn_end", event => {
        if (!sent && event.message.stopReason === "stop") {
          sent = true;
          pi.sendMessage({ customType: "model-review", content: "Review completed", display: false }, { triggerTurn: true });
        }
      });
    }`);
    // Suspend only the second real durable stamp: the historical collision must
    // arrive after the canonical invocation terminal, not win a scheduler race.
    const markers = (f.registry as unknown as { markers: RunMarkerStore }).markers;
    const stamp = markers.reassertAssistantCompletion.bind(markers);
    const gate = new Promise<void>(resolve => { releaseStamp = resolve; });
    const seen = new Set<string>();
    markers.reassertAssistantCompletion = async (...args) => {
      seen.add(args[2]);
      if (seen.size > 1) await gate;
      return stamp(...args);
    };
  }
  const real: Real = { fixture: f, runs: [], entered: 0, trace: [], lateNotice, releaseStamp, terminalFacts: new Map() };
  const model = initialTaskModel();
  try {
    await fc.asyncModelRun(() => ({ model, real }), commands);
    evidence.push({ trace: real.trace, model, sessions: real.runs.map(run => run.sessionId) });
  } catch (error) {
    const current = real.runs.at(-1);
    evidence.push({ trace: real.trace, model, error: String(error),
      ...(current ? { task: await homeOwnerOf(f.registry).taskStatus(current.taskId), snapshot: (await f.registry.acquire(current.sessionId)).snapshot() } : {}),
      diagnostics: f.events.filter(row => row.topic === "session.diagnostic") });
    throw error;
  } finally {
    releaseStamp();
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
  await scenario(["start", "steer", "interrupt", "stop", "terminal-stop", "resume", "report", "observe", "resume", "stop"].map(action => new TaskCommand(action as TaskAction)));
}, 60_000);

it("conforms when a late child notice and report settle before a delayed reply stamp (#1730)", async () => {
  await scenario(["start", "report", "resume", "stop"].map(action => new TaskCommand(action as TaskAction)), true);
}, 60_000);

it("conforms step by step for replayable generated task command sequences", async () => {
  const commands = fc.commands([fc.constantFrom<TaskAction>("start", "steer", "interrupt", "stop", "report", "resume", "observe", "terminal-stop").map(action => new TaskCommand(action))], { maxCommands: 12 });
  await fc.assert(fc.asyncProperty(commands, async trace => { await scenario([new TaskCommand("start"), ...trace]); }), {
    seed: Number(process.env.TRON_MODEL_SEED ?? 1890), numRuns: 40,
    ...(process.env.TRON_MODEL_PATH ? { path: process.env.TRON_MODEL_PATH } : {}),
  });
}, 120_000);
