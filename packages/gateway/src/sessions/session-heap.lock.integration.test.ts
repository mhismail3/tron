import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { startLockGateway, type LockGateway } from "../../test-support/gateway-lock-harness.js";
import { compareWithGolden, lockPaths, lockUpdateRequested, normalizeTraceValue, type TraceValue } from "../../test-support/scenario-lock.js";
import { createAndOpen, DETACHED_RUN, drainBlockersScenario, openExisting, WAITING_COMMAND } from "../../test-support/lock-scenarios.js";

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

/** Replace each session id by its role, so a normalized record still says which session. */
function labelled(value: unknown, roles: ReadonlyMap<string, string>, gateway: LockGateway): TraceValue {
  let text = JSON.stringify(value ?? null);
  for (const [sessionId, role] of roles) text = text.split(sessionId).join(`<session:${role}>`);
  return normalizeTraceValue(JSON.parse(text), { ...gateway.normalization, stableIds: [...roles.values()].map((role) => `<session:${role}>`) });
}

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
    const openC = await openExisting(phone, c);
    await tick();
    for (const sessionId of [a, b]) {
      const reopened = await openExisting(phone, sessionId);
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
  }, 60_000);

  it("run-drain-blockers: a waiting extension command and a detached extension run hold the drain until they settle", async () => {
    const gateway = await startLockGateway("run-drain-blockers", {
      extensions: [{ name: "lock-ask.ts", source: WAITING_COMMAND }, { name: "lock-background.ts", source: DETACHED_RUN }],
    });
    gateways.push(gateway);
    const { phone, asking, detached, roles, commandResponse, statusBefore, statusWaiting, statusAfterAnswer, completed, statusComplete, activities } =
      await drainBlockersScenario(gateway);

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
  }, 60_000);
});
