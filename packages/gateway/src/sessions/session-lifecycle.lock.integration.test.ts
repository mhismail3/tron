import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { startLockGateway, type LockClient, type LockGateway } from "../../test-support/gateway-lock-harness.js";
import { compareWithGolden, lockPaths, lockUpdateRequested, normalizeTraceValue, type TraceValue } from "../../test-support/scenario-lock.js";
import { awaitsWithin, waitFor } from "../../test-support/wait-for.js";

/**
 * Session lifecycle locks (restructure plan §6.4, V3; K-0 §7 E0d) guarding the
 * heap, eviction, cold load and drain owners that kernel slices E5 (`run/`) and
 * E7 (`session/`) move out of `RuntimeRegistry`. Each runs the real Gateway over
 * a loopback WebSocket (`gateway-lock-harness.ts`) with the faux provider.
 *
 * - `run-cold-load-eviction`: under a one-runtime cap, a settled session whose
 *   client closed it is evicted for capacity by the next create, stays in the
 *   catalog with its attention state while cold, and is cold-loaded back by
 *   `session.open` with its canonical JSONL, transcript and context intact.
 * - `run-drain-snapshot`: the administrative drain (`waitUntilIdle`, what the
 *   restart and stop drains run) observed through `gateway.drain.status`: idle,
 *   a live run with a queued follow-up named as the blocker while waiting (an
 *   idle session is not), new work refused, and completion only after the
 *   follow-up ran.
 *
 * Session ids normalize to `<id>`, so `observed` names each session by its role.
 */

const MODULE = "gateway/run";
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

/** Replace each session id by its role, so a normalized record still says which session. */
function labelled(value: unknown, roles: ReadonlyMap<string, string>, gateway: LockGateway): TraceValue {
  let text = JSON.stringify(value);
  for (const [sessionId, role] of roles) text = text.split(sessionId).join(`<session:${role}>`);
  return normalizeTraceValue(JSON.parse(text), { ...gateway.normalization, stableIds: [...roles.values()].map((role) => `<session:${role}>`) });
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
      () => fauxAssistantMessage("First answer before eviction."),
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
    const trace = {
      lock: "run-cold-load-eviction",
      exchanges: recorded.exchanges,
      events: recorded.events,
      providerRequests: recorded.providerRequests as unknown as TraceValue[],
      canonicalJsonl: await gateway.canonical(first.sessionId),
      observed: {
        runtimeLifecycle: gateway.runtimeLifecycle.map((entry) => labelled({ event: entry.event, session: entry.sessionId, reason: entry.reason }, roles, gateway)),
        liveAfterEviction, liveAfterColdLoad,
        canonicalUnchangedByEviction: JSON.stringify(canonicalReloaded) === JSON.stringify(canonicalBefore),
        list: {
          live: labelled(listLive.result, roles, gateway),
          cold: labelled(listCold.result, roles, gateway),
          final: labelled(listFinal.result, roles, gateway),
        },
        attentionRead: labelled(read.result, roles, gateway),
      },
    };
    await compareWithGolden({
      module: MODULE, ...lockPaths(import.meta.url, trace.lock), trace, update: lockUpdateRequested(MODULE),
      validate: () => {
        expect(trace.observed.runtimeLifecycle).toContainEqual({ event: "runtime.evicted", session: "<session:A>", reason: "capacity" });
        expect(trace.observed.runtimeLifecycle.filter((entry) => JSON.stringify(entry).includes("<session:A>") && JSON.stringify(entry).includes("runtime.loaded"))).toHaveLength(2);
        expect(liveAfterEviction).toEqual(["B"]);
        expect(liveAfterColdLoad).toEqual(["A"]);
        expect(trace.observed.canonicalUnchangedByEviction).toBe(true);
        expect(JSON.stringify(listCold.result)).toContain(first.sessionId);
        expect(read.ok, JSON.stringify(read)).toBe(true);
        expect(transcript.ok, JSON.stringify(transcript)).toBe(true);
        const last = recorded.providerRequests.at(-1)!;
        expect(JSON.stringify(last.messages)).toContain("remember the word lantern");
        expect(JSON.stringify(last.messages)).toContain("First answer before eviction.");
      },
    });
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
    const label = (response: { result?: unknown; error?: unknown }) => labelled(response.result ?? response.error ?? null, roles, gateway);
    const trace = {
      lock: "run-drain-snapshot",
      exchanges: recorded.exchanges,
      providerRequests: recorded.providerRequests as unknown as TraceValue[],
      canonicalJsonl: await gateway.canonical(running.sessionId),
      observed: {
        completed,
        drain: {
          idle: label(statusIdle), running: label(statusRunning), begun: labelled(begun, roles, gateway), waiting: label(statusWaiting), complete: label(statusComplete),
        },
        refused: { prompt: label(refusedPrompt), create: label(refusedCreate) },
      },
    };
    await compareWithGolden({
      module: MODULE, ...lockPaths(import.meta.url, trace.lock), trace, update: lockUpdateRequested(MODULE),
      validate: () => {
        expect(completed).toBe(true);
        expect(queued.ok, JSON.stringify(queued)).toBe(true);
        expect(JSON.stringify(trace.canonicalJsonl)).toContain("Queued follow-up answered.");
        expect(statusIdle.result.phase).toBe("idle");
        expect(begun.phase).toBe("preparing");
        expect(statusWaiting.result.phase).toBe("waiting");
        expect(statusWaiting.result.blockerCount).toBeGreaterThan(0);
        expect(JSON.stringify(trace.observed.drain.waiting)).toContain("<session:running>");
        expect(JSON.stringify(trace.observed.drain.waiting)).not.toContain("<session:idle>");
        expect(refusedPrompt.ok).toBe(false);
        expect(refusedCreate.ok).toBe(false);
        expect(statusComplete.result).toMatchObject({ phase: "complete", blockerCount: 0 });
      },
    });
  });
});
