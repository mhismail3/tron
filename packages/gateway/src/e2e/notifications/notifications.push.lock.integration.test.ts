import { afterEach, describe, expect, it } from "vitest";
import { expectRequestShapes } from "../../../test-support/lock-projections.js";
import { notificationsPushScenario, PUSH_RELAY_ORIGIN } from "../../../test-support/lock-scenarios.js";

/**
 * Push lock (restructure E0b, `packages/gateway/docs/kernel.md` §2.1 `runTerminal`
 * and `interactionRequired`) for the `gateway/notifications` module.
 *
 * The real Gateway (`gateway-lock-harness.ts`) runs with the production
 * `NotificationService` and grant store; the only replaced party besides the
 * faux model is the relay's HTTP fetcher, which is the network boundary. The
 * phone registers push delivery over the socket, then one chat runs to a
 * completed, an input-required, a failed and a stopped end while hidden, and to
 * an input-required and a completed end while the phone presents it. A Home
 * task worker, admitted through the owned-session boundary as the dispatcher
 * admits it, runs to its end too. The lock records every relay request (the
 * exact push envelopes), every notification receipt (queued, suppressed), the
 * phone's inbox and its push, presentation and answer responses, as explicit checks.
 *
 * Each provider request's tools, prompt sections and prompt hash must equal its
 * `session-shapes` shape, and its messages are checked inline; the client event
 * schemas the phone decodes are pinned by `client-event-schemas`, which runs this
 * same scenario.
 */

const owned: Array<() => Promise<void>> = [];
afterEach(async () => { for (const release of owned.splice(0).reverse()) await release(); });

describe("gateway/notifications push lock", () => {
  it("notifications-push: terminal and input-required pushes, presence suppression and the task-worker skip", async () => {
    const { gateway, relayRequests, responses, inbox, stored, workerRoles, sessionId } = await notificationsPushScenario((release) => { owned.push(release); });
    const RELAY_ORIGIN = PUSH_RELAY_ORIGIN;
    const answer = (frame: { ok: boolean; result?: unknown; error?: unknown }) => ({ ok: frame.ok, result: frame.result ?? null, error: frame.error ?? null });
    expect(answer(responses.registered!), "the registration").toEqual({ ok: true, error: null, result: { available: true, deviceRegistered: true, enabledDeviceCount: 1,
      notifyWhenAskPresented: true, notifyWhenFinished: true, notifyWhenWaiting: true, pendingCount: 0, registered: true, relayOrigin: RELAY_ORIGIN,
      requiresGrantRotation: false } });
    expect(answer(responses.hiddenAnswer!), "the hidden answer").toEqual({ ok: true, result: { answered: true }, error: null });
    expect(answer(responses.presenting!), "presenting the chat").toEqual({ ok: true, result: { revision: 1, visible: true }, error: null });
    expect(answer(responses.presentedAnswer!), "the presented answer").toEqual({ ok: true, result: { answered: true }, error: null });
    expect(answer(responses.hiding!), "hiding the chat").toEqual({ ok: true, result: { revision: 2, visible: false }, error: null });
    expect(answer(responses.rename!), "the rename").toEqual({ ok: true, result: { updated: true }, error: null });
    const ISO = expect.stringMatching(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/u);
    const envelope = (notificationKind: string, title: string, message: string, extra: Record<string, unknown> = {}) => ({
      method: "POST", path: "/v3/notifications", grantId: "lock-grant-0001", envelope: { version: 1, kind: "agent_alert", notificationKind,
        machineId: "lock-machine", sessionId, title, message, requestId: expect.stringMatching(/^[A-Za-z0-9_-]{43}$/u), expiresAt: ISO, ...extra } });
    expect(relayRequests, "a hidden chat pushes finished, input needed, finished, error and stopped; the presented ask and end push nothing").toEqual([
      envelope("agent_finished", "finish the quiet run", "The agent finished responding."),
      envelope("ask", "Input needed", "Tron needs your input. Open Tron to respond.", { interruptionLevel: "time-sensitive" }),
      envelope("agent_finished", "finish the quiet run", "The agent finished responding."),
      envelope("agent_finished", "Renamed lock chat", "The agent stopped because of an error."),
      envelope("agent_finished", "Renamed lock chat", "The agent was stopped."),
    ]);
    const ids = relayRequests.map((request) => (request.envelope as { requestId: string }).requestId);
    expect(new Set(ids).size, "each push has its own request id").toBe(ids.length);
    expect(stored.receipts.map((receipt) => ({ result: receipt.result, grants: receipt.grantIds.length })),
      "receipts: delivered pushes name the grant, the presented ask and end are suppressed with none, and the worker leaves no receipt").toEqual([
      { result: "accepted_by_apns", grants: 1 }, { result: "accepted_by_apns", grants: 1 }, { result: "accepted_by_apns", grants: 1 },
      { result: "suppressed", grants: 0 }, { result: "suppressed", grants: 0 }, { result: "accepted_by_apns", grants: 1 }, { result: "accepted_by_apns", grants: 1 },
    ]);
    const entry = (kind: string, title: string, message: string, isUnread: boolean) => ({ version: 1, id: expect.any(String), kind, title, message,
      outcome: "accepted_by_apns", sessionId, isUnread, createdAt: ISO, updatedAt: ISO });
    expect(answer(inbox), "the inbox lists every push newest first; those before the chat was presented are read").toEqual({ ok: true, error: null, result: {
      notifications: [
        entry("agent_finished", "Renamed lock chat", "The agent was stopped.", true),
        entry("agent_finished", "Renamed lock chat", "The agent stopped because of an error.", true),
        entry("agent_finished", "finish the quiet run", "The agent finished responding.", false),
        entry("ask", "Input needed", "Tron needs your input. Open Tron to respond.", false),
        entry("agent_finished", "finish the quiet run", "The agent finished responding.", false),
      ], revision: expect.stringMatching(/^[0-9a-f]{32}$/u), unreadCount: 2 } });
    expect(workerRoles, "the task worker ran a turn and its reminder turn").toEqual(["system", "user", "assistant", "assistant"]);
    // The model receives the chat's growing conversation, then the worker's turn and its report reminder (the
    // reminder request has the task worker's shape; its text is the last message).
    const requests = gateway.record().providerRequests;
    expectRequestShapes(requests, [...Array.from({ length: 7 }, () => "chatWithNotificationsSelect"), "taskWorker", "taskWorker"]);
    const select = (text: string) => [{ role: "assistant", text: "", toolCalls: ["lock_select"] }, { role: "toolResult", text: "chosen: Keep", toolName: "lock_select" },
      { role: "assistant", text }];
    const chat = [
      { role: "user", text: "finish the quiet run" }, { role: "assistant", text: "Finished the quiet run." },
      { role: "user", text: "ask me while I am away" }, ...select("Keeping the hidden path."),
      { role: "user", text: "ask me while I am watching" }, ...select("Keeping the presented path."),
      { role: "user", text: "fail this run" }, { role: "assistant", text: "partial" }, { role: "user", text: "start a run to stop" },
    ];
    const worker = [{ role: "user", text: "do the lock task" }, { role: "assistant", text: "Worker reply without a report." }, { role: "user",
      text: "Call report now with the current outcome and partial evidence. Do not continue implementation or validation. Use progress for unfinished work or needs-input "
        + "for a blocker; do not claim final success without acceptance evidence. If you cannot report, the task will settle with no report." }];
    expect(requests.map((request) => request.messages), "each request's messages: the chat's turns so far, then the worker's turn and its reminder").toEqual([
      ...[1, 3, 5, 7, 9, 11, 13].map((count) => chat.slice(0, count)), worker.slice(0, 1), worker]);
  });
});
