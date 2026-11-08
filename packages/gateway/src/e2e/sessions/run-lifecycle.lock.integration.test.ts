import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { startLockGateway, type LockClient, type LockGateway } from "../../../test-support/gateway-lock-harness.js";
import { expectRequestShapes, expectSystemShapes } from "../../../test-support/lock-projections.js";
import { awaitsWithin, waitFor } from "../../../test-support/wait-for.js";

/**
 * Lifecycle RPC lock (packages/gateway/docs/scenario-locks.md#locks; K-0 §7, guarding E5's abort
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
 *
 * Effects are asserted by name: each exact refusal and result, the drain
 * snapshots and their blockers, the recorded process requests in order, every
 * persisted receipt and message, each provider request's messages and the
 * `session-shapes` shapes. `restarting` and `stopping` count the RPC's own work
 * as a blocker, so they are never true (#1559) and are not asserted.
 */

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

/** A drain snapshot's blockers as `category[:session|method]:state`, in order. */
function blockers(drain: { blockers: Array<{ category: string; sessionId?: string; method?: string; state: string }> }, sessionId: string): string[] {
  return drain.blockers.map((blocker) => [blocker.category, blocker.sessionId === sessionId ? "live" : blocker.sessionId ?? blocker.method, blocker.state].join(":"));
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

    const refusal = (code: string, message: string, retryable = false) => ({ code, message, retryable });
    expect(unsupervisedRestart.error).toEqual(refusal("unsupported", "Gateway restart requires an external supervisor"));
    expect(unsupervisedStop.error).toEqual(refusal("unsupported", "Gateway stop requires an external supervisor"));
    expect(malformedRestartNow.error).toEqual(refusal("invalid_request", "Gateway restart restartNow must be boolean"));
    expect(extraRestart.error).toEqual(refusal("invalid_request", "Gateway restart accepts only commandId and optional restartNow"));
    expect(extraStop.error).toEqual(refusal("invalid_request", "Gateway stop accepts only commandId"));
    expect(reloadIdle.result).toEqual({ reloaded: true });
    expect(reloadRunning.error).toEqual(refusal("busy", "Session must be idle for this operation"));

    // The restart names the live session and drains it and its own RPC; everything else is refused while it drains.
    const drainShape = { omittedCount: 0, suspectProjectionCount: 0, blockerCount: 2, blockerCounts: { "foreground-agent-operation": 1, "rpc-mutation": 1 } };
    expect(restart.result).toMatchObject({ scheduled: true, activeSessionIds: [sessionId], drainRevision: 4, drainId: restart.result.drain.drainId,
      drain: { ...drainShape, phase: "preparing" } });
    expect(blockers(restart.result.drain, sessionId)).toEqual(["foreground-agent-operation:live:active", "rpc-mutation:gateway.restart:active"]);
    const draining = refusal("busy", "Gateway is already draining accepted work; inspect gateway.drain.status or command.status", true);
    expect(secondRestart.error).toEqual(draining);
    expect(stopDuringDrain.error).toEqual(draining);
    expect(promptDuringDrain.error).toEqual(refusal("busy", "The Gateway is draining accepted work", true));
    expect(restartNow.result).toMatchObject({ scheduled: true, restartNow: true, drain: { ...drainShape, phase: "waiting", drainId: restart.result.drainId } });
    expect(blockers(restartNow.result.drain, sessionId)).toEqual(["foreground-agent-operation:live:active", "rpc-mutation:gateway.restart:active"]);
    expect(requestsBeforeSettle).toEqual([
      { kind: "auth.cancelWaitingForRestart" }, { kind: "restart", restartNow: false }, { kind: "restart", restartNow: true },
    ]);
    expect(gateway.lifecycleRequests).toEqual(requestsBeforeSettle);
    expect(completed).toBe(true);
    expect(statusComplete.result).toMatchObject({ phase: "complete", blockerCount: 0, blockerCounts: {}, blockers: [], omittedCount: 0,
      suspectProjectionCount: 0, drainId: restart.result.drainId });

    // The drained run settled; the refused prompt left nothing behind.
    const canonicalJsonl = await gateway.canonical(sessionId);
    const messages = canonicalJsonl.flatMap((entry) => {
      const message = (entry as { message?: { role: string; content?: Array<{ text?: string }>; stopReason?: string } }).message;
      return message && message.role !== "system" ? [`${message.role}:${message.content?.map((part) => part.text).join("")}${message.stopReason ? `:${message.stopReason}` : ""}`] : [];
    });
    expect(messages).toEqual(["user:answer before the reload", "assistant:Answer before the reload.:stop",
      "user:hold this run through the restart", "assistant:Run settled during the drain.:stop"]);
    const receipts = canonicalJsonl.flatMap((entry) => {
      const record = entry as { customType?: string; data?: { receiptKind?: string; lifecycle?: string; errorCode?: string } };
      return record.customType === "tron.chat-invocation.v1" ? [`${record.data?.receiptKind}:${record.data?.lifecycle ?? ""}`] : [];
    });
    const turn = ["start:staged", "transition:accepted", "binding:", "terminal:completed"];
    expect(receipts).toEqual([...turn, ...turn]);
    expectSystemShapes(canonicalJsonl, ["chat#0"]);
    const recorded = gateway.record();
    expect(recorded.providerRequests.map((request) => request.messages.map((message) => {
      const { role, text } = message as { role: string; text?: string };
      return `${role}:${text ?? ""}`;
    }))).toEqual([
      ["user:answer before the reload"],
      ["user:answer before the reload", "assistant:Answer before the reload.", "user:hold this run through the restart"],
    ]);
    expectRequestShapes(recorded.providerRequests, ["chat", "chat"]);

    // The idle Gateway's stop drains only its own RPC and completes.
    expect(stop.result).toMatchObject({ scheduled: true, activeSessionIds: [], drainRevision: 3, drainId: stop.result.drain.drainId,
      drain: { phase: "preparing", omittedCount: 0, suspectProjectionCount: 0, blockerCount: 1, blockerCounts: { "rpc-mutation": 1 } } });
    expect(blockers(stop.result.drain, sessionId)).toEqual(["rpc-mutation:gateway.stop:active"]);
    expect(stopCompleted).toBe(true);
    expect(idle.lifecycleRequests).toEqual([{ kind: "stop" }]);
    expect(stopStatus.result).toMatchObject({ phase: "complete", blockerCount: 0, blockerCounts: {}, blockers: [], drainId: stop.result.drainId });
  }, 60_000);
});
