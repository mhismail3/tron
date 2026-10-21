import { fauxAssistantMessage, fauxToolCall } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { HomeTaskReportOwner } from "../home/home-task-report.js";
import { OwnedSessionDispatch } from "../sessions/owned-session-dispatch.js";
import { startLockGateway, type LockClient, type LockGateway } from "../../test-support/gateway-lock-harness.js";
import { compareWithGolden, lockPaths, lockUpdateRequested, normalizeTraceValue, type TraceValue } from "../../test-support/scenario-lock.js";
import { awaitsWithin, waitFor } from "../../test-support/wait-for.js";
import { NotificationGrantStore } from "./grant-store.js";
import { NotificationService } from "./notification-service.js";
import { PushRelayClient } from "./relay-client.js";

/**
 * Push lock (restructure E0b, `docs/restructure/k0-kernel.md` §2.1 `runTerminal`
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
 * phone's inbox, and the client and provider exchanges.
 */

const MODULE = "gateway/notifications";
const RELAY_ORIGIN = "https://relay.lock.invalid";
const SELECT_EXTENSION = `
  export default function (pi) {
    pi.registerTool({
      name: "lock_select", label: "Lock select", description: "Ask the user which lock path to take",
      parameters: { type: "object", properties: {} },
      execute: async (_id, _params, _signal, _update, ctx) => {
        const answer = await ctx.ui.select("Choose a lock path", ["Keep", "Change"]);
        return { content: [{ type: "text", text: "chosen: " + (answer ?? "cancelled") }], details: { answer: answer ?? null } };
      },
    });
  }
`;

interface RelayRequest { method: string; path: string; grantId: string | null; envelope: TraceValue }

const owned: Array<() => Promise<void>> = [];
afterEach(async () => { for (const release of owned.splice(0).reverse()) await release(); });

describe("gateway/notifications push lock", () => {
  it("notifications-push: terminal and input-required pushes, presence suppression and the task-worker skip", async () => {
    const relayRequests: RelayRequest[] = [];
    let gateway!: LockGateway;
    let notifications!: NotificationService;
    gateway = await startLockGateway("notifications-push", {
      extensions: [{ name: "lock-select.ts", source: SELECT_EXTENSION }],
      notifications: async (tronHome) => {
        // The relay boundary: every push the Gateway would send to Tron Push.
        const relay = new PushRelayClient(RELAY_ORIGIN, async (url, init) => {
          relayRequests.push({
            method: String(init.method), path: new URL(url).pathname,
            grantId: (init.headers as Record<string, string> | undefined)?.["x-tron-grant-id"] ?? null,
            envelope: init.body ? JSON.parse(String(init.body)) as TraceValue : null,
          });
          return new Response(JSON.stringify({ status: "accepted_by_apns" }), { status: 200 }) as never;
        });
        // gateway-main's wiring, Home role resolved from the live registry.
        notifications = new NotificationService(new NotificationGrantStore(tronHome), relay, Date.now, () => {}, () => {}, () => {},
          (sessionId) => gateway?.registry.homeOwner().chapterStateFor(sessionId).homeId !== undefined);
        await notifications.initialize();
        return notifications;
      },
    });
    owned.push(() => gateway.dispose());
    owned.push(async () => notifications.dispose());
    const sent = (count: number, label: string) => waitFor(() => relayRequests.length >= count, label);
    const document = async () => (await gateway.file(`${gateway.tronHome}/gateway/notifications.json`)) as {
      receipts: Array<{ result: string; grantIds: string[] }>;
      pending: unknown[];
    };

    const phone = await gateway.connect("phone", { clientRole: "mobile" });
    const registered = await phone.request("push.registration.upsert", {
      commandId: gateway.commandId(), installationId: "lock-installation", grantId: "lock-grant-0001",
      secret: Buffer.alloc(32, 7).toString("base64url"), previewsEnabled: false, relayOrigin: RELAY_ORIGIN,
      notifyWhenAskPresented: true, notifyWhenFinished: true, notifyWhenWaiting: true,
    });
    expect(registered.ok, JSON.stringify(registered)).toBe(true);

    const created = await phone.request("session.create", { commandId: gateway.commandId(), cwd: gateway.cwd });
    expect(created.ok, JSON.stringify(created)).toBe(true);
    const sessionId = created.result.sessionId as string;
    const opened = await phone.request("session.open", { sessionId });
    expect(opened.ok, JSON.stringify(opened)).toBe(true);
    expect((await phone.request("session.sync", { sessionId, syncToken: opened.result.syncToken })).ok).toBe(true);
    const subscriptionToken = opened.result.subscriptionToken as string;
    const slot = await gateway.registry.acquire(sessionId);
    // Pin the ordinary idle path before a run can supersede it. Terminal idle
    // snapshots may all coalesce into rebaselines, even on a loopback socket.
    await waitFor(() => slot.snapshot().configurationBlocker === null, "the initial session ownership to retire");
    const initialEvents = phone.events.length;
    slot.publishSnapshot();
    await waitFor(() => phone.events.slice(initialEvents).some((event) => event.sessionId === sessionId && event.topic === "session.snapshot"
      && (event.payload as { configurationBlocker?: unknown }).configurationBlocker === null),
    "the initial ordinary idle snapshot to reach the phone");
    const prompt = (text: string) => phone.send("session.prompt", { commandId: gateway.commandId(), sessionId, text });
    const answerSelect = async (client: LockClient, answered: number) => {
      const pending = await waitFor(() => {
        const shown = client.events.flatMap((event) => (event.payload as {
          extensionPresentation?: { pendingInteractions?: Array<{ id: string; hostEpoch: string; presentationRevision: number }> };
        })?.extensionPresentation?.pendingInteractions ?? []);
        return shown.filter((interaction, index) => shown.findIndex((other) => other.id === interaction.id) === index)[answered];
      }, "the pending select to reach the phone");
      return pending;
    };
    const respond = (pending: { id: string; hostEpoch: string; presentationRevision: number }) => phone.request("extension.respond", {
      commandId: gateway.commandId(), sessionId, interactionId: pending.id,
      hostEpoch: pending.hostEpoch, presentationRevision: pending.presentationRevision, value: "Keep",
    });

    // 1. Hidden: a completed run pushes "finished".
    gateway.script([() => fauxAssistantMessage("Finished the quiet run.")]);
    expect((await prompt("finish the quiet run")).ok).toBe(true);
    await gateway.settled(sessionId);
    await sent(1, "the completed-run push");

    // 2. Hidden: input required pushes "Input needed" before the answer; the run's end pushes again.
    gateway.script([
      () => fauxAssistantMessage([fauxToolCall("lock_select", {}, { id: "lock-select-hidden" })], { stopReason: "toolUse" }),
      () => fauxAssistantMessage("Keeping the hidden path."),
    ]);
    const hiddenRun = prompt("ask me while I am away");
    const hiddenAsk = await answerSelect(phone, 0);
    await sent(2, "the input-required push");
    expect((await respond(hiddenAsk)).ok).toBe(true);
    expect((await hiddenRun).ok).toBe(true);
    await gateway.settled(sessionId);
    await sent(3, "the push after the answered run");

    // 3. Presented: the same ask and end are suppressed, not pushed.
    expect((await phone.request("session.presentation.set", { sessionId, subscriptionToken, revision: 1, visible: true })).ok).toBe(true);
    gateway.script([
      () => fauxAssistantMessage([fauxToolCall("lock_select", {}, { id: "lock-select-presented" })], { stopReason: "toolUse" }),
      () => fauxAssistantMessage("Keeping the presented path."),
    ]);
    const presentedRun = prompt("ask me while I am watching");
    expect((await respond(await answerSelect(phone, 1))).ok).toBe(true);
    expect((await presentedRun).ok).toBe(true);
    await gateway.settled(sessionId);
    await waitFor(async () => (await document()).receipts.filter((receipt) => receipt.result === "suppressed").length >= 2,
      "the presented ask and end to be suppressed");
    expect((await phone.request("session.presentation.set", { sessionId, subscriptionToken, revision: 2, visible: false })).ok).toBe(true);

    // 4. Hidden, renamed: a provider error pushes "stopped because of an error", titled by the name.
    expect((await phone.request("session.rename", { commandId: gateway.commandId(), sessionId, name: "Renamed lock chat" })).ok).toBe(true);
    let failedProviderReached!: () => void;
    const failedProvider = new Promise<void>((resolve) => { failedProviderReached = resolve; });
    gateway.script([() => {
      failedProviderReached();
      return fauxAssistantMessage("partial", { stopReason: "error", errorMessage: "lock provider failure" });
    }]);
    const failureEvents = phone.events.length;
    // A slow writer must receive the idle snapshot as a rebaseline covering
    // unsent busy state. Otherwise compression versus receipt I/O decides which
    // topic carries the null configuration blocker, making the schema lock race.
    const releaseWrites = phone.holdWrites();
    try {
      const failedRun = prompt("fail this run");
      await awaitsWithin(failedProvider, "the failed provider request");
      await gateway.settled(sessionId);
      await waitFor(() => slot.snapshot().configurationBlocker === null, "the failed run's terminal ownership to retire");
      releaseWrites();
      expect((await failedRun).ok).toBe(true);
      await waitFor(() => phone.events.slice(failureEvents).some((event) => event.topic === "session.rebaseline"
        && (event.payload as { snapshot?: { configurationBlocker?: unknown } }).snapshot?.configurationBlocker === null),
      "the failed run's idle rebaseline to reach the phone");
    } finally {
      releaseWrites();
    }
    await sent(4, "the failed-run push");

    // 5. Hidden: a client abort pushes "was stopped".
    let reached!: () => void;
    const held = new Promise<void>((resolve) => { reached = resolve; });
    gateway.script([async (_context, options) => {
      reached();
      await new Promise<void>((resolve) => {
        const signal = options?.signal;
        if (!signal || signal.aborted) { resolve(); return; }
        signal.addEventListener("abort", () => resolve(), { once: true });
      });
      return fauxAssistantMessage("Aborted turn response.");
    }]);
    const abortable = await prompt("start a run to stop");
    expect(abortable.ok).toBe(true);
    await awaitsWithin(held, "the abortable provider request");
    expect((await phone.request("session.abort", { commandId: gateway.commandId(), sessionId, operationId: abortable.result.operationId })).ok).toBe(true);
    await gateway.settled(sessionId);
    await sent(5, "the stopped-run push");

    // 6. A Home task worker's end is never a generic chat push (its report owner decides).
    gateway.script([() => fauxAssistantMessage("Worker reply without a report."), () => fauxAssistantMessage("Worker still has no report.")]);
    const operationId = "task-lock-operation";
    const report = new HomeTaskReportOwner({ taskId: "lock-task", homeId: "lock-home", generation: 1, operationId }, async () => {});
    const dispatch = new OwnedSessionDispatch(gateway.registry);
    const lease = await dispatch.createWorker(gateway.cwd, report);
    const workerTerminal = new Promise<unknown>((resolve) => {
      void dispatch.admit(lease.slot, "do the lock task", [], undefined, undefined, undefined, {
        operationId, signal: report.signal, origin: { kind: "gateway", ownerId: "lock-task", title: "Home task", confidence: "boundary" },
        onTerminal: resolve,
      });
    });
    await awaitsWithin(workerTerminal, "the task worker's terminal");
    // The owner acknowledges settlement, as the dispatcher does; only then is the operation released.
    await dispatch.acknowledge(lease.slot.id, operationId, lease);
    report.retire();
    await gateway.settled(lease.slot.id);
    const workerRoles = (await gateway.canonical(lease.slot.id)).flatMap((entry) => {
      const role = (entry as { message?: { role?: string } }).message?.role;
      return role ? [role] : [];
    });

    // Every queued push has reached a final relay outcome before the inbox is read.
    await waitFor(async () => (await document()).pending.length === 0, "every queued push to settle at the relay");
    const inbox = await phone.request("notification.inbox.list", {});
    expect(inbox.ok, JSON.stringify(inbox)).toBe(true);
    const stored = await document();
    const recorded = gateway.record();
    const trace = {
      lock: "notifications-push",
      relayRequests: normalizeTraceValue(relayRequests, gateway.normalization),
      receipts: stored.receipts.map((receipt) => ({ result: receipt.result, grants: receipt.grantIds.length })),
      exchanges: recorded.exchanges,
      events: recorded.events,
      providerRequests: recorded.providerRequests as unknown as TraceValue[],
      worker: normalizeTraceValue({ roles: workerRoles }, gateway.normalization),
    };
    await compareWithGolden({
      module: MODULE, ...lockPaths(import.meta.url, "notifications-push"), trace, update: lockUpdateRequested(MODULE),
      validate: () => {
        const kinds = relayRequests.map((request) => {
          const envelope = request.envelope as { notificationKind?: string; title?: string; message?: string };
          return `${envelope.notificationKind} [${envelope.title}]: ${envelope.message}`;
        });
        expect(kinds).toEqual([
          "agent_finished [finish the quiet run]: The agent finished responding.",
          "ask [Input needed]: Tron needs your input. Open Tron to respond.",
          "agent_finished [finish the quiet run]: The agent finished responding.",
          "agent_finished [Renamed lock chat]: The agent stopped because of an error.",
          "agent_finished [Renamed lock chat]: The agent was stopped.",
        ]);
        expect(stored.receipts.map((receipt) => receipt.result)).toEqual([
          "accepted_by_apns", "accepted_by_apns", "accepted_by_apns", "suppressed", "suppressed", "accepted_by_apns", "accepted_by_apns",
        ]);
        // The worker ran a turn and its reminder turn, and pushed nothing.
        expect(workerRoles.filter((role) => role === "assistant")).toHaveLength(2);
      },
    });
  });
});
