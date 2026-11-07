import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { startLockGateway, type LockClient, type LockGateway } from "../../../test-support/gateway-lock-harness.js";
import { normalizeTraceValue } from "../../../test-support/scenario-lock.js";
import { expectRequestShapes, expectSystemShapes } from "../../../test-support/lock-projections.js";
import { awaitsWithin, waitFor } from "../../../test-support/wait-for.js";

/**
 * Session lifecycle locks (packages/gateway/docs/scenario-locks.md#locks; K-0 §7 E0d) guarding the
 * heap, eviction, cold load and drain owners that kernel slices E5 (`run/`) and
 * E7 (`session/`) move out of `RuntimeRegistry`. Each runs the real Gateway over
 * a loopback WebSocket (`gateway-lock-harness.ts`) with the faux provider.
 *
 * - `run-cold-load-eviction`: under a one-runtime cap, an open session is never
 *   reclaimed (a second create is refused); once its client closed it, the
 *   settled session is evicted for capacity by the next create, stays in the
 *   catalog with its attention state while cold, and is cold-loaded back by
 *   `session.open` with its canonical JSONL, transcript and context intact.
 * - `run-drain-snapshot`: the administrative drain (`waitUntilIdle`, what the
 *   restart and stop drains run) observed through `gateway.drain.status`: idle,
 *   a live run with a queued follow-up named as the blocker while waiting (an
 *   idle session is not), new work refused, and completion only after the
 *   follow-up ran.
 *
 * Each scenario asserts its effects by name: lifecycle records, live runtimes, catalog
 * and attention state, refusals, drain snapshots and the provider requests it caused.
 */

const gateways: LockGateway[] = [];
afterEach(async () => { await Promise.all(gateways.splice(0).map((gateway) => gateway.dispose())); });

interface Opened { readonly sessionId: string; readonly subscriptionToken: string; readonly open: { ok: boolean; result?: any; error?: any } }

async function createAndOpen(gateway: LockGateway, client: LockClient, cwd = gateway.cwd): Promise<Opened> {
  const created = await client.request("session.create", { commandId: gateway.commandId(), cwd });
  expect(created.ok, JSON.stringify(created)).toBe(true);
  return open(client, created.result.sessionId as string);
}

async function open(client: LockClient, sessionId: string): Promise<Opened> {
  const opened = await client.request("session.open", { sessionId });
  expect(opened.ok, JSON.stringify(opened)).toBe(true);
  expect((await client.request("session.sync", { sessionId, syncToken: opened.result.syncToken })).ok).toBe(true);
  return { sessionId, subscriptionToken: opened.result.subscriptionToken as string, open: opened };
}

/** A gate a scripted provider step holds until the test opens it. */
function gate(): { opened: Promise<void>; open(): void; reached: Promise<void>; reach(): void } {
  let open = (): void => {};
  let reach = (): void => {};
  const opened = new Promise<void>((resolve) => { open = resolve; });
  const reached = new Promise<void>((resolve) => { reach = resolve; });
  return { opened, open: () => open(), reached, reach: () => reach() };
}

/** The live runtimes by role, as the registry's own load and eviction records leave them. */
function liveRoles(gateway: LockGateway, roles: ReadonlyMap<string, string>): string[] {
  const live = new Set<string>();
  for (const entry of gateway.runtimeLifecycle) {
    if (entry.event === "runtime.loaded") live.add(entry.sessionId);
    else live.delete(entry.sessionId);
  }
  return [...live].map((id) => roles.get(id) ?? "unknown").sort();
}

describe("session lifecycle kernel locks", () => {
  it("cold load and eviction: a capacity-evicted session keeps its catalog row and attention, and reloads intact", async () => {
    const gateway = await startLockGateway("run-cold-load-eviction", { maximumLiveRuntimes: 1 });
    gateways.push(gateway);
    const phone = await gateway.connect("phone");
    gateway.script([
      async () => {
        await gateway.observeLiveOperation(phone, first.sessionId);
        return fauxAssistantMessage("First answer before eviction.");
      },
      () => fauxAssistantMessage("Second session answer."),
      () => fauxAssistantMessage("Answer after the cold load."),
    ]);

    // A: one settled turn that completes while no client presents it (unread), then closed.
    const first = await createAndOpen(gateway, phone);
    const roles = new Map([[first.sessionId, "A"]]);
    expect((await phone.request("session.prompt", { commandId: gateway.commandId(), sessionId: first.sessionId, text: "remember the word lantern" })).ok).toBe(true);
    await gateway.settled(first.sessionId);
    const canonicalBefore = await gateway.canonical(first.sessionId);
    const listLive = await phone.request("session.list", {});
    // An open (subscribed) runtime is never reclaimed: the cap refuses a second one.
    const refusedWhileOpen = await phone.request("session.create", { commandId: gateway.commandId(), cwd: gateway.cwd });
    expect((await phone.request("session.close", { sessionId: first.sessionId, subscriptionToken: first.subscriptionToken })).ok).toBe(true);

    // B: the next create needs A's runtime slot; A is reloadable and unobserved.
    const second = await createAndOpen(gateway, phone);
    roles.set(second.sessionId, "B");
    const liveAfterEviction = liveRoles(gateway, roles);
    const listCold = await phone.request("session.list", {});

    // A again: B is persisted by its own turn, so once closed it is the one evicted
    // for capacity, and session.open cold-loads A from its file.
    expect((await phone.request("session.prompt", { commandId: gateway.commandId(), sessionId: second.sessionId, text: "a second session turn" })).ok).toBe(true);
    await gateway.settled(second.sessionId);
    expect((await phone.request("session.close", { sessionId: second.sessionId, subscriptionToken: second.subscriptionToken })).ok).toBe(true);
    const reopened = await open(phone, first.sessionId);
    const liveAfterColdLoad = liveRoles(gateway, roles);
    const canonicalReloaded = await gateway.canonical(first.sessionId);
    const read = await phone.request("session.attention.read", {
      sessionId: first.sessionId, throughCompletionRevision: reopened.open.result.completionRevision,
    });
    // The reloaded runtime carries the earlier turn into the next provider request.
    expect((await phone.request("session.prompt", { commandId: gateway.commandId(), sessionId: first.sessionId, text: "which word?" })).ok).toBe(true);
    await gateway.settled(first.sessionId);
    const transcript = await phone.request("session.transcript", { sessionId: first.sessionId });
    const listFinal = await phone.request("session.list", {});

    const recorded = gateway.record();
    // A is evicted for B, B for A's cold load on open.
    expect(gateway.runtimeLifecycle.map((entry) => `${entry.event} ${roles.get(entry.sessionId)} ${entry.reason}`)).toEqual([
      "runtime.loaded A create", "runtime.evicted A capacity", "runtime.loaded B create", "runtime.evicted B capacity", "runtime.loaded A open",
    ]);
    expect(refusedWhileOpen.error).toMatchObject({ code: "busy", retryable: true });
    expect(liveAfterEviction).toEqual(["B"]);
    expect(liveAfterColdLoad).toEqual(["A"]);
    expect(JSON.stringify(canonicalReloaded)).toBe(JSON.stringify(canonicalBefore));
    expectSystemShapes(normalizeTraceValue(await gateway.canonical(first.sessionId), gateway.normalization) as unknown[], ["chat#0"]);
    const row = (list: { result?: any }, sessionId: string) => list.result.sessions.find((session: { id: string }) => session.id === sessionId);
    // A's completion arrived while no client presented it: unread while open, and still while cold.
    expect(row(listLive, first.sessionId)).toMatchObject({ isUnread: true, completionRevision: 1, attentionRevision: 1 });
    expect(row(listCold, first.sessionId)).toMatchObject({ isUnread: true, completionRevision: 1, attentionRevision: 1, messageCount: 2,
      firstMessage: "remember the word lantern", phase: "idle" });
    expect(row(listCold, second.sessionId)).toMatchObject({ isUnread: false, messageCount: 0 });
    // Reading A's attention acknowledges its one completion.
    expect(read.result).toEqual({ attentionRevision: 2, completionRevision: 1, isUnread: false });
    expect(row(listFinal, first.sessionId)).toMatchObject({ isUnread: true, completionRevision: 2, attentionRevision: 3, messageCount: 4 });
    expect(row(listFinal, second.sessionId)).toMatchObject({ isUnread: true, completionRevision: 1, messageCount: 2, firstMessage: "a second session turn" });
    expect(transcript.ok, JSON.stringify(transcript)).toBe(true);
    expect(JSON.stringify(transcript.result)).toContain("First answer before eviction.");
    expect(JSON.stringify(transcript.result)).toContain("Answer after the cold load.");
    // Each turn reached the provider once; the reloaded runtime sent the earlier turn.
    expectRequestShapes(recorded.providerRequests, ["chat", "chat", "chat"]);
    const last = recorded.providerRequests.at(-1)!;
    expect(JSON.stringify(last.messages)).toContain("remember the word lantern");
    expect(JSON.stringify(last.messages)).toContain("First answer before eviction.");
  });

  it("drain snapshot: a live run and its queued follow-up block the drain, new work is refused, and the drain completes after both", async () => {
    const gateway = await startLockGateway("run-drain-snapshot");
    gateways.push(gateway);
    const phone = await gateway.connect("phone");
    const held = gate();
    gateway.script([
      async () => { held.reach(); await held.opened; return fauxAssistantMessage("Held run settled."); },
      () => fauxAssistantMessage("Queued follow-up answered."),
    ]);
    const running = await createAndOpen(gateway, phone);
    const idle = await createAndOpen(gateway, phone);
    const roles = new Map([[running.sessionId, "running"], [idle.sessionId, "idle"]]);

    const statusIdle = await phone.request("gateway.drain.status", {});
    const admitted = await phone.request("session.prompt", { commandId: gateway.commandId(), sessionId: running.sessionId, text: "hold this run open" });
    expect(admitted.ok, JSON.stringify(admitted)).toBe(true);
    await awaitsWithin(held.reached, "the held provider request");
    // Accepted queued work stays authoritative: the drain waits for it, never clears it.
    const queued = await phone.request("session.prompt", { commandId: gateway.commandId(), sessionId: running.sessionId, text: "queued before the drain", behavior: "followUp" });
    // A prompt RPC's own work settles just after its response frame; wait for that
    // exact work, so each status names only the run and its queue.
    const rpcSettled = () => waitFor(() => !gateway.registry.administrativeDrainSnapshot().blockers
      .some((blocker) => blocker.category === "rpc-mutation"), "the prompt RPCs' own work to settle");
    await rpcSettled();
    const statusRunning = await phone.request("gateway.drain.status", {});

    // gateway.restart and gateway.stop begin the drain in their RPC turn and answer
    // with this snapshot; gateway-main's runRestartDrain/runStopDrain then wait.
    const begun = gateway.registry.beginAdministrativeDrain();
    const drained = gateway.registry.waitUntilIdle();
    await waitFor(() => gateway.registry.administrativeDrainSnapshot().phase === "waiting", "the drain to wait on the live run");
    await rpcSettled();
    const statusWaiting = await phone.request("gateway.drain.status", {});
    const refusedPrompt = await phone.request("session.prompt", { commandId: gateway.commandId(), sessionId: idle.sessionId, text: "new work during the drain" });
    const refusedCreate = await phone.request("session.create", { commandId: gateway.commandId(), cwd: gateway.cwd });

    held.open();
    const completed = await awaitsWithin(drained, "the drain to complete");
    const statusComplete = await phone.request("gateway.drain.status", {});

    const recorded = gateway.record();
    const blockers = (snapshot: { blockers: Array<{ category: string; sessionId?: string }> }) =>
      snapshot.blockers.map((blocker) => `${roles.get(blocker.sessionId ?? "") ?? "none"}:${blocker.category}`);
    const runAndQueue = { "foreground-agent-operation": 1, "queued-mutation": 1 };
    expect(completed).toBe(true);
    expect(queued.ok, JSON.stringify(queued)).toBe(true);
    const runningJsonl = await gateway.canonical(running.sessionId);
    expect(JSON.stringify(runningJsonl)).toContain("Queued follow-up answered.");
    expectSystemShapes(normalizeTraceValue(runningJsonl, gateway.normalization) as unknown[], ["chat#0"]);
    expect(statusIdle.result).toMatchObject({ phase: "idle", blockerCount: 0, blockerCounts: {} });
    // The live run and its queued follow-up are the blockers; the idle session never is.
    expect(statusRunning.result).toMatchObject({ phase: "idle", blockerCount: 2, blockerCounts: runAndQueue });
    expect(blockers(statusRunning.result)).toEqual(["running:foreground-agent-operation", "running:queued-mutation"]);
    expect(begun).toMatchObject({ phase: "preparing", blockerCount: 2, blockerCounts: runAndQueue });
    expect(statusWaiting.result).toMatchObject({ phase: "waiting", blockerCount: 2, blockerCounts: runAndQueue });
    expect(blockers(statusWaiting.result)).toEqual(["running:foreground-agent-operation", "running:queued-mutation"]);
    // New work is refused with the drain's retryable busy error.
    const draining = { code: "busy", message: "The Gateway is draining accepted work", retryable: true };
    expect(refusedPrompt.error).toEqual(draining);
    expect(refusedCreate.error).toEqual(draining);
    expect(statusComplete.result).toMatchObject({ phase: "complete", blockerCount: 0, blockerCounts: {} });
    // The accepted follow-up ran exactly once, after the held turn.
    expectRequestShapes(recorded.providerRequests, ["chat", "chat"]);
    const followUp = JSON.stringify(recorded.providerRequests[1]!.messages);
    expect(followUp.indexOf("Held run settled.")).toBeGreaterThan(-1);
    expect(followUp.indexOf("queued before the drain")).toBeGreaterThan(followUp.indexOf("Held run settled."));
  });
});
