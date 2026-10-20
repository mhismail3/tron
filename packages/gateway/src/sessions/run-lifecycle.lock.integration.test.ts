import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { startLockGateway, type LockClient, type LockGateway } from "../../test-support/gateway-lock-harness.js";
import { compareWithGolden, lockPaths, lockUpdateRequested, normalizeTraceValue, type TraceValue } from "../../test-support/scenario-lock.js";
import { awaitsWithin, waitFor } from "../../test-support/wait-for.js";

/**
 * Lifecycle RPC lock (restructure plan §6.4, V3; K-0 §7, guarding E5's abort
 * and E7's drain) for the `gateway/run` module: the restart and stop RPCs a
 * phone sends, through the real Gateway (`gateway-lock-harness.ts`, option
 * `lifecycleRequests`: the real terminal owner, and `gateway-main`'s process
 * exit requests recorded instead of acted on; the lock runs the drain
 * `gateway-main` would run, `waitUntilIdle`).
 *
 * `run-lifecycle-rpcs`:
 * - an unsupervised Gateway refuses restart and stop; a supervised one refuses
 *   malformed parameters;
 * - `session.reloadResources` (the session restart) reloads an idle session and
 *   is refused during its run;
 * - `gateway.restart` during a live run schedules a drain naming that session,
 *   cancels waiting auth and asks for the restart after its receipt; a second
 *   restart, a stop and new work are refused while it drains; `restartNow`
 *   during the drain asks for an immediate restart; the drain completes after
 *   the run;
 * - on a second, idle Gateway `gateway.stop` drains nothing and asks for the stop.
 */

const MODULE = "gateway/run";
const gateways: LockGateway[] = [];
const previousSupervised = process.env.TRON_GATEWAY_SUPERVISED;
afterEach(async () => {
  if (previousSupervised === undefined) delete process.env.TRON_GATEWAY_SUPERVISED;
  else process.env.TRON_GATEWAY_SUPERVISED = previousSupervised;
  await Promise.all(gateways.splice(0).map((gateway) => gateway.dispose()));
});

/** A gate a scripted provider step holds until the test opens it. */
function gate(): { opened: Promise<void>; open(): void; reached: Promise<void>; reach(): void } {
  let open = (): void => {};
  let reach = (): void => {};
  const opened = new Promise<void>((resolve) => { open = resolve; });
  const reached = new Promise<void>((resolve) => { reach = resolve; });
  return { opened, open: () => open(), reached, reach: () => reach() };
}

async function createAndOpen(gateway: LockGateway, client: LockClient): Promise<string> {
  const created = await client.request("session.create", { commandId: gateway.commandId(), cwd: gateway.cwd });
  expect(created.ok, JSON.stringify(created)).toBe(true);
  const sessionId = created.result.sessionId as string;
  const opened = await client.request("session.open", { sessionId });
  expect((await client.request("session.sync", { sessionId, syncToken: opened.result.syncToken })).ok).toBe(true);
  return sessionId;
}

/** `restarting` and `stopping` count the RPC's own work as a blocker, so they
 * are never true (#1559); they are blinded rather than pinned. */
function blinded(key: string, value: unknown): unknown {
  return key === "restarting" || key === "stopping" ? "<blinded:#1559>" : value;
}

/** Replace a session id by its role, so a normalized record still says which session. */
function labelled(value: unknown, sessionId: string, role: string, gateway: LockGateway): TraceValue {
  const text = JSON.stringify(value ?? null).split(sessionId).join(`<session:${role}>`);
  return normalizeTraceValue(JSON.parse(text, blinded), { ...gateway.normalization, stableIds: [`<session:${role}>`] });
}

describe("gateway/run lifecycle RPC lock", () => {
  it("run-lifecycle-rpcs: restart and stop refusals, the session restart, a restart drain over a live run, and an idle stop", async () => {
    const gateway = await startLockGateway("run-lifecycle-rpcs", { lifecycleRequests: true });
    gateways.push(gateway);
    const phone = await gateway.connect("phone");
    const held = gate();
    gateway.script([
      () => fauxAssistantMessage("Answer before the reload."),
      async () => { held.reach(); await held.opened; return fauxAssistantMessage("Run settled during the drain."); },
    ]);
    const command = (method: string, params: Record<string, unknown> = {}) =>
      phone.request(method, { commandId: gateway.commandId(), ...params });

    // 1. Refusals: no supervisor, then malformed parameters.
    delete process.env.TRON_GATEWAY_SUPERVISED;
    const unsupervisedRestart = await command("gateway.restart");
    const unsupervisedStop = await command("gateway.stop");
    process.env.TRON_GATEWAY_SUPERVISED = "1";
    const malformedRestartNow = await command("gateway.restart", { restartNow: "yes" });
    const extraRestart = await command("gateway.restart", { reason: "lock" });
    const extraStop = await command("gateway.stop", { reason: "lock" });

    // 2. The session restart: reload while idle, refused while its run is live.
    const sessionId = await createAndOpen(gateway, phone);
    expect((await command("session.prompt", { sessionId, text: "answer before the reload" })).ok).toBe(true);
    await gateway.settled(sessionId);
    const reloadIdle = await command("session.reloadResources", { sessionId });
    const running = await command("session.prompt", { sessionId, text: "hold this run through the restart" });
    expect(running.ok, JSON.stringify(running)).toBe(true);
    await awaitsWithin(held.reached, "the held provider request");
    const reloadRunning = await command("session.reloadResources", { sessionId });

    // 3. A restart drains the live run; while it drains, everything else is refused.
    const restart = await command("gateway.restart");
    expect(restart.ok, JSON.stringify(restart)).toBe(true);
    await waitFor(() => gateway.lifecycleRequests.some((request) => request.kind === "restart"), "the scheduled restart request");
    const drained = gateway.registry.waitUntilIdle();
    await waitFor(() => gateway.registry.administrativeDrainSnapshot().phase === "waiting", "the drain to wait on the live run");
    const secondRestart = await command("gateway.restart");
    const stopDuringDrain = await command("gateway.stop");
    const promptDuringDrain = await command("session.prompt", { sessionId, text: "new work during the restart drain" });
    const restartNow = await command("gateway.restart", { restartNow: true });
    const requestsBeforeSettle = [...gateway.lifecycleRequests];
    held.open();
    const completed = await awaitsWithin(drained, "the restart drain to complete");
    const statusComplete = await phone.request("gateway.drain.status", {});

    // 4. An idle Gateway's stop drains nothing and asks for the stop.
    const idle = await startLockGateway("run-lifecycle-stop", { lifecycleRequests: true });
    gateways.push(idle);
    const mac = await idle.connect("mac");
    const stop = await mac.request("gateway.stop", { commandId: idle.commandId() });
    await waitFor(() => idle.lifecycleRequests.some((request) => request.kind === "stop"), "the stop request");
    const stopCompleted = await awaitsWithin(idle.registry.waitUntilIdle(), "the stop drain to complete");
    const stopStatus = await mac.request("gateway.drain.status", {});

    const recorded = gateway.record();
    const label = (response: { result?: unknown; error?: unknown }) => labelled(response.result ?? response.error ?? null, sessionId, "live", gateway);
    const trace = {
      lock: "run-lifecycle-rpcs",
      exchanges: recorded.exchanges.map((entry) => labelled(entry, sessionId, "live", gateway)),
      providerRequests: recorded.providerRequests as unknown as TraceValue[],
      canonicalJsonl: await gateway.canonical(sessionId),
      observed: {
        refused: {
          unsupervisedRestart: label(unsupervisedRestart), unsupervisedStop: label(unsupervisedStop),
          malformedRestartNow: label(malformedRestartNow), extraRestart: label(extraRestart), extraStop: label(extraStop),
        },
        reload: { idle: label(reloadIdle), running: label(reloadRunning) },
        restart: {
          accepted: label(restart), secondRestart: label(secondRestart), stopDuringDrain: label(stopDuringDrain),
          promptDuringDrain: label(promptDuringDrain), restartNow: label(restartNow),
          requestsBeforeSettle: requestsBeforeSettle as unknown as TraceValue, completed, complete: label(statusComplete),
          requests: [...gateway.lifecycleRequests] as unknown as TraceValue,
        },
        stop: {
          completed: stopCompleted,
          requests: [...idle.lifecycleRequests] as unknown as TraceValue,
          exchanges: idle.record().exchanges.map((entry) => normalizeTraceValue(JSON.parse(JSON.stringify(entry), blinded), idle.normalization)),
        },
      },
    };
    await compareWithGolden({
      module: MODULE, ...lockPaths(import.meta.url, trace.lock), trace, update: lockUpdateRequested(MODULE),
      validate: () => {
        expect(unsupervisedRestart.error).toMatchObject({ code: "unsupported" });
        expect(unsupervisedStop.error).toMatchObject({ code: "unsupported" });
        for (const refusal of [malformedRestartNow, extraRestart, extraStop]) expect(refusal.error).toMatchObject({ code: "invalid_request" });
        expect(reloadIdle.result).toEqual({ reloaded: true });
        expect(reloadRunning.ok).toBe(false);
        expect(restart.result).toMatchObject({ scheduled: true, activeSessionIds: [sessionId] });
        expect(JSON.stringify(trace.observed.restart.accepted)).toContain("foreground-agent-operation");
        expect(secondRestart.error).toMatchObject({ code: "busy" });
        expect(stopDuringDrain.error).toMatchObject({ code: "busy" });
        expect(promptDuringDrain.ok).toBe(false);
        expect(restartNow.result).toMatchObject({ scheduled: true, restartNow: true });
        expect(requestsBeforeSettle).toEqual([
          { kind: "auth.cancelWaitingForRestart" }, { kind: "restart", restartNow: false }, { kind: "restart", restartNow: true },
        ]);
        expect(completed).toBe(true);
        expect(statusComplete.result).toMatchObject({ phase: "complete", blockerCount: 0 });
        expect(JSON.stringify(trace.canonicalJsonl)).toContain("Run settled during the drain.");
        expect(stop.result).toMatchObject({ scheduled: true, activeSessionIds: [] });
        expect(idle.lifecycleRequests).toEqual([{ kind: "stop" }]);
        expect(stopStatus.result).toMatchObject({ phase: "complete", blockerCount: 0 });
      },
    });
  }, 60_000);
});
