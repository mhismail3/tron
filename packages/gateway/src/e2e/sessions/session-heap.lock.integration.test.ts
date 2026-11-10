import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { startLockGateway, type LockGateway } from "../../../test-support/gateway-lock-harness.js";
import { normalizeTraceValue } from "../../../test-support/scenario-lock.js";
import { expectRequestShapes, expectSystemShapes } from "../../../test-support/lock-projections.js";
import { createAndOpen, DETACHED_RUN, drainBlockersScenario, openExisting, WAITING_COMMAND } from "../../../test-support/lock-scenarios.js";

const gateways: LockGateway[] = [];
afterEach(async () => { await Promise.all(gateways.splice(0).map((gateway) => gateway.dispose())); });

async function tick(): Promise<void> {
  const last = Date.now();
  while (Date.now() <= last) await new Promise<void>((resolve) => { setImmediate(resolve); });
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
    const slots = (gateway.registry as unknown as { slots: Map<string, { touchedAt: number }> }).slots;
    const touchOrder = [...slots].sort(([, left], [, right]) => left.touchedAt - right.touchedAt)
      .map(([id]) => roles.get(id));
    const touchesDistinct = new Set([...slots.values()].map((slot) => slot.touchedAt)).size === slots.size;

    const d = await createAndOpen(gateway, phone);
    roles.set(d.sessionId, "D-draft");
    const liveAfterD = live();
    await tick();
    expect((await phone.request("session.close", { sessionId: d.sessionId, subscriptionToken: d.subscriptionToken })).ok).toBe(true);
    await tick();
    const e = await createAndOpen(gateway, phone);
    roles.set(e.sessionId, "E-open");
    const liveAfterE = live();
    const refused = await phone.request("session.create", { commandId: gateway.commandId(), cwd: gateway.cwd });
    expect((await phone.request("session.close", { sessionId: c, subscriptionToken: openC.subscriptionToken })).ok).toBe(true);
    await tick();
    const f = await createAndOpen(gateway, phone);
    roles.set(f.sessionId, "F-open");
    const liveAfterF = live();
    const list = await phone.request("session.list", {});

    expect(liveFull).toEqual(["A", "B", "C"]);
    expect(touchesDistinct).toBe(true);
    expect(touchOrder).toEqual(["C", "A", "B"]);
    expect(liveAfterD).toEqual(["B", "C", "D-draft"]);
    expect(liveAfterE).toEqual(["C", "D-draft", "E-open"]);
    expect(liveAfterF).toEqual(["D-draft", "E-open", "F-open"]);
    expect(refused.error).toEqual({ code: "busy", message: "Gateway live runtime capacity is full; close or wait for an idle session", retryable: true });
    expect(gateway.runtimeLifecycle.map((entry) => `${entry.event} ${roles.get(entry.sessionId)} ${entry.reason}`)).toEqual([
      "runtime.loaded A create", "runtime.loaded B create", "runtime.loaded C create", "runtime.evicted A capacity",
      "runtime.loaded D-draft create", "runtime.evicted B capacity", "runtime.loaded E-open create", "runtime.evicted C capacity",
      "runtime.loaded F-open create",
    ]);
    const listed = new Map(list.result.sessions.map((session: { id: string }) => [roles.get(session.id), session]));
    for (const role of ["A", "B", "C"]) {
      expect(listed.get(role)).toMatchObject({ isUnread: true, completionRevision: 1, attentionRevision: 1, messageCount: 2, firstMessage: `session ${role} turn` });
    }
    for (const role of ["D-draft", "E-open", "F-open"]) expect(listed.get(role)).toMatchObject({ isUnread: false, completionRevision: 0, attentionRevision: 0, messageCount: 0 });
    expect(gateway.record().providerRequests.map((request) => JSON.stringify(request.messages)))
      .toEqual(["A", "B", "C"].map((role) => expect.stringContaining(`session ${role} turn`)));
    expectRequestShapes(gateway.record().providerRequests, ["chat", "chat", "chat"]);
  }, 60_000);

  it("run-drain-blockers: a waiting extension command and a detached extension run hold the drain until they settle", async () => {
    const gateway = await startLockGateway("run-drain-blockers", {
      extensions: [{ name: "lock-ask.ts", source: WAITING_COMMAND }, { name: "lock-background.ts", source: DETACHED_RUN }],
    });
    gateways.push(gateway);
    const { phone, asking, detached, roles, commandResponse, statusBefore, statusWaiting, statusAfterAnswer, completed, statusComplete, activities } =
      await drainBlockersScenario(gateway);

    const categories = (status: { result?: { blockers: Array<{ category: string; sessionId?: string }> } }) =>
      status.result!.blockers.map((blocker) => `${roles.get(blocker.sessionId ?? "") ?? "none"}:${blocker.category}`).sort();
    expect(categories(statusBefore)).toEqual(["command:prompt-preflight", "detached:detached-extension-run"]);
    expect(statusBefore.result).toMatchObject({ phase: "idle", blockerCount: 2 });
    expect(categories(statusWaiting)).toEqual(["command:prompt-preflight", "detached:detached-extension-run"]);
    expect(statusWaiting.result.blockerCounts).toEqual({ "detached-extension-run": 1, "prompt-preflight": 1 });
    expect(categories(statusAfterAnswer)).toEqual(["detached:detached-extension-run"]);
    expect(statusWaiting.result.phase).toBe("waiting");
    expect(statusAfterAnswer.result.phase).toBe("waiting");
    expect(commandResponse.ok, JSON.stringify(commandResponse)).toBe(true);
    expect(completed).toBe(true);
    expect(statusComplete.result).toMatchObject({ phase: "complete", blockerCount: 0 });
    expect(activities.map((activity) => ({ status: activity.status, mode: activity.mode, state: activity.lifecycle?.state })))
      .toEqual([{ status: "completed", mode: "asynchronous", state: "completed" }]);
    const detachedJsonl = await gateway.canonical(detached.sessionId);
    expect(JSON.stringify(detachedJsonl)).toContain("Background run started.");
    expectSystemShapes(normalizeTraceValue(detachedJsonl, gateway.normalization) as unknown[], ["chatWithExtensionBackground#0"]);
    expectRequestShapes(gateway.record().providerRequests, ["chatWithExtensionBackground", "chatWithExtensionBackground"]);
    const commandTranscript = await phone.request("session.transcript", { sessionId: asking.sessionId });
    expect(commandTranscript.result).toMatchObject({ end: 3 });
  }, 60_000);
});
