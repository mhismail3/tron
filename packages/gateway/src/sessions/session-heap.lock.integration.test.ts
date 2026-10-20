import { fauxAssistantMessage, fauxToolCall } from "@earendil-works/pi-ai";
import { writeFile } from "node:fs/promises";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { startLockGateway, type LockClient, type LockGateway } from "../../test-support/gateway-lock-harness.js";
import { compareWithGolden, lockPaths, lockUpdateRequested, normalizeTraceValue, type TraceValue } from "../../test-support/scenario-lock.js";
import { awaitsWithin, waitFor } from "../../test-support/wait-for.js";

/**
 * Heap and drain locks (restructure plan §6.4, V3; K-0 §7, guarding E5's run
 * ownership and E7's eviction and drain) for the `gateway/run` module, beside
 * `session-lifecycle.lock` (E0d), through the real Gateway (`gateway-lock-harness.ts`).
 *
 * - `run-eviction-choice`: under a three-runtime cap with several eligible
 *   runtimes, each capacity eviction retires the least recently used settled,
 *   closed session; an open session and a never-persisted draft are skipped.
 * - `run-drain-blockers`: blockers that are not a live agent run hold the
 *   administrative drain: an extension command waiting for the user's answer
 *   (still its prompt's preflight work: the handler runs inside admission),
 *   and a detached extension run (an extension tool's declared asynchronous run
 *   with its live status artifact) that outlives the turn which started it. The
 *   drain completes only after the answer and the run's terminal artifact.
 */

const MODULE = "gateway/run";
const gateways: LockGateway[] = [];
afterEach(async () => { await Promise.all(gateways.splice(0).map((gateway) => gateway.dispose())); });

/** Eviction orders by the registry's millisecond touch clock (`Date.now()`):
 * return only once that clock has moved past every touch made so far, so each
 * later touch is strictly newer. The lock also checks the recorded touch order. */
async function tick(): Promise<void> {
  const last = Date.now();
  while (Date.now() <= last) await new Promise<void>((resolve) => { setImmediate(resolve); });
}

interface Opened { readonly sessionId: string; readonly subscriptionToken: string }

async function createAndOpen(gateway: LockGateway, client: LockClient): Promise<Opened> {
  const created = await client.request("session.create", { commandId: gateway.commandId(), cwd: gateway.cwd });
  expect(created.ok, JSON.stringify(created)).toBe(true);
  return open(client, created.result.sessionId as string);
}

async function open(client: LockClient, sessionId: string): Promise<Opened> {
  const opened = await client.request("session.open", { sessionId });
  expect(opened.ok, JSON.stringify(opened)).toBe(true);
  expect((await client.request("session.sync", { sessionId, syncToken: opened.result.syncToken })).ok).toBe(true);
  return { sessionId, subscriptionToken: opened.result.subscriptionToken as string };
}

/** Replace each session id by its role, so a normalized record still says which session. */
function labelled(value: unknown, roles: ReadonlyMap<string, string>, gateway: LockGateway): TraceValue {
  let text = JSON.stringify(value ?? null);
  for (const [sessionId, role] of roles) text = text.split(sessionId).join(`<session:${role}>`);
  return normalizeTraceValue(JSON.parse(text), { ...gateway.normalization, stableIds: [...roles.values()].map((role) => `<session:${role}>`) });
}

const WAITING_COMMAND = `
  export default function (pi) {
    pi.registerCommand("lockask", {
      description: "Ask which lock path to take",
      handler: async (_args, ctx) => { await ctx.ui.select("Choose a lock path", ["Keep", "Change"]); },
    });
  }
`;

/** An extension tool that starts a declared asynchronous run: its status artifact
 * lives under the project's async run root, and the tool returns at once. */
const DETACHED_RUN = `
  import { mkdirSync, writeFileSync } from "node:fs";
  import { join } from "node:path";
  export default function (pi) {
    pi.registerTool({
      name: "lock_background", label: "Lock background", description: "Start the lock's background run",
      parameters: { type: "object", properties: {} },
      execute: async (_id, _params, _signal, _update, ctx) => {
        const runId = "lock-background-run";
        const asyncDir = join(ctx.cwd, ".pi", "subagents", "async-subagent-runs", runId);
        mkdirSync(asyncDir, { recursive: true });
        writeFileSync(join(asyncDir, "status.json"), JSON.stringify({ runId, state: "running", startedAt: Date.now(), lastUpdate: Date.now() }));
        return { content: [{ type: "text", text: "Background run started." }], details: { runId, asyncDir, state: "running" } };
      },
    });
  }
`;

describe("gateway/run heap and drain locks", () => {
  it("run-eviction-choice: capacity evicts the least recently used eligible runtime, never an open session or an unsaved draft", async () => {
    const gateway = await startLockGateway("run-eviction-choice", { maximumLiveRuntimes: 3 });
    gateways.push(gateway);
    const phone = await gateway.connect("phone");
    gateway.script(["A", "B", "C"].map((role) => () => fauxAssistantMessage(`Session ${role} answered.`)));
    const roles = new Map<string, string>();
    const settledAndClosed = async (role: string): Promise<string> => {
      const session = await createAndOpen(gateway, phone);
      roles.set(session.sessionId, role);
      expect((await phone.request("session.prompt", { commandId: gateway.commandId(), sessionId: session.sessionId, text: `session ${role} turn` })).ok).toBe(true);
      await gateway.settled(session.sessionId);
      expect((await phone.request("session.close", { sessionId: session.sessionId, subscriptionToken: session.subscriptionToken })).ok).toBe(true);
      await tick();
      return session.sessionId;
    };
    const live = () => {
      const current = new Set<string>();
      for (const entry of gateway.runtimeLifecycle) {
        if (entry.event === "runtime.loaded") current.add(entry.sessionId);
        else current.delete(entry.sessionId);
      }
      return [...current].map((id) => roles.get(id) ?? "unknown").sort();
    };

    // A, B and C settle and close. C is reopened and stays open, then A and B are
    // reopened and closed: by touch, C (open) < A < B.
    const a = await settledAndClosed("A");
    const b = await settledAndClosed("B");
    const c = await settledAndClosed("C");
    const openC = await open(phone, c);
    await tick();
    for (const sessionId of [a, b]) {
      const reopened = await open(phone, sessionId);
      expect((await phone.request("session.close", { sessionId, subscriptionToken: reopened.subscriptionToken })).ok).toBe(true);
      await tick();
    }
    const liveFull = live();
    // The touch clock the eviction sorts by, read without acquiring (which touches).
    const slots = (gateway.registry as unknown as { slots: Map<string, { touchedAt: number }> }).slots;
    const touchOrder = [...slots].sort(([, left], [, right]) => left.touchedAt - right.touchedAt)
      .map(([id]) => roles.get(id));
    const touchesDistinct = new Set([...slots.values()].map((slot) => slot.touchedAt)).size === slots.size;

    // D needs a slot: the oldest, C, is open, so A goes.
    const d = await createAndOpen(gateway, phone);
    roles.set(d.sessionId, "D-draft");
    const liveAfterD = live();
    await tick();
    // E needs a slot once the draft D is closed: C is open and D was never saved, so B goes.
    expect((await phone.request("session.close", { sessionId: d.sessionId, subscriptionToken: d.subscriptionToken })).ok).toBe(true);
    await tick();
    const e = await createAndOpen(gateway, phone);
    roles.set(e.sessionId, "E-open");
    const liveAfterE = live();
    // Nothing is eligible: C and E are open, D is unsaved. Once C closes, it goes.
    const refused = await phone.request("session.create", { commandId: gateway.commandId(), cwd: gateway.cwd });
    expect((await phone.request("session.close", { sessionId: c, subscriptionToken: openC.subscriptionToken })).ok).toBe(true);
    await tick();
    const f = await createAndOpen(gateway, phone);
    roles.set(f.sessionId, "F-open");
    const liveAfterF = live();
    const list = await phone.request("session.list", {});

    const recorded = gateway.record();
    const trace = {
      lock: "run-eviction-choice",
      exchanges: recorded.exchanges.map((entry) => labelled(entry, roles, gateway)),
      providerRequests: recorded.providerRequests as unknown as TraceValue[],
      observed: {
        runtimeLifecycle: gateway.runtimeLifecycle.map((entry) => labelled({ event: entry.event, session: entry.sessionId, reason: entry.reason }, roles, gateway)),
        live: { full: liveFull, afterD: liveAfterD, afterE: liveAfterE, afterF: liveAfterF },
        refused: labelled(refused.error, roles, gateway),
        list: labelled(list.result, roles, gateway),
      },
    };
    await compareWithGolden({
      module: MODULE, ...lockPaths(import.meta.url, trace.lock), trace, update: lockUpdateRequested(MODULE),
      validate: () => {
        expect(liveFull).toEqual(["A", "B", "C"]);
        expect(touchesDistinct).toBe(true);
        expect(touchOrder).toEqual(["C", "A", "B"]);
        expect(liveAfterD).toEqual(["B", "C", "D-draft"]);
        expect(liveAfterE).toEqual(["C", "D-draft", "E-open"]);
        expect(liveAfterF).toEqual(["D-draft", "E-open", "F-open"]);
        expect(refused.error).toMatchObject({ code: "busy" });
        const evictions = trace.observed.runtimeLifecycle.filter((entry) => JSON.stringify(entry).includes("runtime.evicted"));
        expect(evictions).toEqual(["A", "B", "C"].map((role) => ({ event: "runtime.evicted", session: `<session:${role}>`, reason: "capacity" })));
      },
    });
  });

  it("run-drain-blockers: a waiting extension command and a detached extension run hold the drain until they settle", async () => {
    const gateway = await startLockGateway("run-drain-blockers", {
      extensions: [{ name: "lock-ask.ts", source: WAITING_COMMAND }, { name: "lock-background.ts", source: DETACHED_RUN }],
    });
    gateways.push(gateway);
    const phone = await gateway.connect("phone");
    gateway.script([
      () => fauxAssistantMessage([fauxToolCall("lock_background", {}, { id: "lock-background-call" })], { stopReason: "toolUse" }),
      () => fauxAssistantMessage("The background run is under way."),
    ]);
    const asking = await createAndOpen(gateway, phone);
    const detached = await createAndOpen(gateway, phone);
    const roles = new Map([[asking.sessionId, "command"], [detached.sessionId, "detached"]]);
    // Each RPC's own work settles just after its response frame; wait for it, so
    // each status names only the blockers under test.
    const rpcSettled = () => waitFor(() => !gateway.registry.administrativeDrainSnapshot().blockers
      .some((blocker) => blocker.category === "rpc-mutation"), "the RPCs' own work to settle");

    // The detached session's turn starts the background run and ends; the run stays live.
    expect((await phone.request("session.prompt", { commandId: gateway.commandId(), sessionId: detached.sessionId, text: "start the background run" })).ok).toBe(true);
    // The slot stays busy while it owns the run, so the turn's end is its settled operation.
    const detachedSlot = await gateway.registry.acquire(detached.sessionId);
    await waitFor(() => !detachedSlot.snapshot().operation && gateway.record().providerRequests.length === 2
      && detachedSlot.snapshot().extensionActivities?.some((activity) => activity.status === "running")
      && gateway.registry.administrativeDrainSnapshot().blockers.every((blocker) => blocker.category === "detached-extension-run"),
    "the detached turn and its receipts to settle with its run live");
    // The command session waits on the user's answer, with no agent run.
    const command = phone.send("session.prompt", { commandId: gateway.commandId(), sessionId: asking.sessionId, text: "/lockask" });
    const pending = await waitFor(() => {
      for (const event of phone.events) {
        // A command runs no agent turn, so its select arrives on the presentation topic alone.
        if (event.topic !== "session.extensionPresentation" || event.sessionId !== asking.sessionId) continue;
        const shown = (event.payload as { data?: { interactionList?: Array<{ id: string; hostEpoch: string; presentationRevision: number }> } })
          ?.data?.interactionList?.[0];
        if (shown) return shown;
      }
      return undefined;
    }, "the command's select to reach the phone");
    await rpcSettled();
    const statusBefore = await phone.request("gateway.drain.status", {});

    gateway.registry.beginAdministrativeDrain();
    const drained = gateway.registry.waitUntilIdle();
    await waitFor(() => gateway.registry.administrativeDrainSnapshot().phase === "waiting", "the drain to wait");
    await rpcSettled();
    const statusWaiting = await phone.request("gateway.drain.status", {});

    // The answer settles the command; the detached run still holds the drain.
    expect((await phone.request("extension.respond", {
      commandId: gateway.commandId(), sessionId: asking.sessionId, interactionId: pending.id,
      hostEpoch: pending.hostEpoch, presentationRevision: pending.presentationRevision, value: "Keep",
    })).ok).toBe(true);
    const commandResponse = await command;
    await waitFor(() => !gateway.registry.administrativeDrainSnapshot().blockers.some((blocker) => blocker.sessionId === asking.sessionId),
      "the answered command to leave the drain");
    await rpcSettled();
    const statusAfterAnswer = await phone.request("gateway.drain.status", {});

    // The run's terminal artifact ends it, and the drain completes.
    const endedAt = Date.now();
    await writeFile(join(gateway.cwd, ".pi", "subagents", "async-subagent-runs", "lock-background-run", "status.json"), JSON.stringify({
      runId: "lock-background-run", state: "complete", startedAt: endedAt - 1_000, endedAt, lastUpdate: endedAt + 1,
    }));
    const completed = await awaitsWithin(drained, "the drain to complete");
    const statusComplete = await phone.request("gateway.drain.status", {});
    const activities = detachedSlot.snapshot().extensionActivities ?? [];

    const recorded = gateway.record();
    const label = (response: { result?: unknown; error?: unknown }) => labelled(response.result ?? response.error ?? null, roles, gateway);
    const trace = {
      lock: "run-drain-blockers",
      providerRequests: recorded.providerRequests as unknown as TraceValue[],
      // A command alone never saves a new session, so only its transcript projection exists.
      commandTranscript: label(await phone.request("session.transcript", { sessionId: asking.sessionId })),
      canonicalJsonl: await gateway.canonical(detached.sessionId),
      observed: {
        commandResponse: label(commandResponse),
        drain: {
          before: label(statusBefore), waiting: label(statusWaiting), afterAnswer: label(statusAfterAnswer), completed, complete: label(statusComplete),
        },
        activities: activities.map((activity) => labelled({ status: activity.status, mode: activity.mode ?? null, state: activity.lifecycle?.state ?? null }, roles, gateway)),
      },
    };
    await compareWithGolden({
      module: MODULE, ...lockPaths(import.meta.url, trace.lock), trace, update: lockUpdateRequested(MODULE),
      validate: () => {
        const categories = (status: { result?: { blockers: Array<{ category: string; sessionId?: string }> } }) =>
          status.result!.blockers.map((blocker) => `${roles.get(blocker.sessionId ?? "") ?? "none"}:${blocker.category}`).sort();
        // A command's handler runs inside Pi's admission, so its wait is still the
        // prompt's preflight work, which owns its select.
        expect(categories(statusWaiting)).toEqual(["command:prompt-preflight", "detached:detached-extension-run"]);
        expect(categories(statusAfterAnswer)).toEqual(["detached:detached-extension-run"]);
        expect(statusWaiting.result.phase).toBe("waiting");
        expect(statusAfterAnswer.result.phase).toBe("waiting");
        expect(commandResponse.ok, JSON.stringify(commandResponse)).toBe(true);
        expect(completed).toBe(true);
        expect(statusComplete.result).toMatchObject({ phase: "complete", blockerCount: 0 });
        expect(trace.observed.activities).toEqual([{ status: "completed", mode: "asynchronous", state: "completed" }]);
      },
    });
  });
});
