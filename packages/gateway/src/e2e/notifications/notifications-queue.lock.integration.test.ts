import { fauxAssistantMessage, fauxToolCall } from "@earendil-works/pi-ai";
import { readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { startLockGateway, type LockClient, type LockGateway } from "../../../test-support/gateway-lock-harness.js";
import { expectRequestShapes } from "../../../test-support/lock-projections.js";
import { awaitsWithin, waitFor } from "../../../test-support/wait-for.js";
import { NotificationGrantStore } from "../../notifications/grant-store.js";
import { NotificationService } from "../../notifications/notification-service.js";
import { PushRelayClient } from "../../notifications/relay-client.js";

const RELAY_ORIGIN = "https://relay.lock.invalid";
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

interface RelayRequest { method: string; path: string; requestDigest: string; status: number; envelope: unknown }
interface PushDocument {
  receipts: Array<{ result: string; kind?: string; dedupeKey: string; sessionKey: string }>;
  pending: Array<{ kind: string; targets: Array<{ attempts: number; outcome: string }> }>;
  revocations: unknown[];
  inbox: unknown[];
}

const owned: Array<() => Promise<void>> = [];
afterEach(async () => { for (const release of owned.splice(0).reverse()) await release(); });

class Relay {
  available = true;
  readonly requests: RelayRequest[] = [];
  readonly fetcher = async (url: string, init: { method?: string; headers?: unknown; body?: unknown }) => {
    const status = this.available ? 200 : 503;
    const path = new URL(url).pathname;
    this.requests.push({
      method: String(init.method), path, status,
      requestDigest: (init.headers as Record<string, string> | undefined)?.["x-tron-request-id"] ?? "",
      envelope: init.body ? JSON.parse(String(init.body)) as unknown : null,
    });
    const body = !this.available ? "" : init.method === "DELETE" ? JSON.stringify({ version: 1, revoked: true }) : JSON.stringify({ status: "accepted_by_apns" });
    return new Response(body, { status }) as never;
  };
}

const ISO = expect.stringMatching(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/u);
const DIGEST = expect.stringMatching(/^[A-Za-z0-9_-]{43}$/u);
const GRANT = "lock-grant-0001";
const SECRET = Buffer.alloc(32, 7).toString("base64url");

function envelope(sessionId: string, title: string, notificationKind: string, message: string) {
  return { version: 1, kind: "agent_alert", notificationKind, machineId: "lock-machine", sessionId, title, message, requestId: DIGEST, expiresAt: ISO };
}

function posts(relay: Relay) {
  return relay.requests.filter((request) => request.method === "POST").map((request) => {
    expect(request.path).toBe("/v3/notifications");
    expect((request.envelope as { requestId: string }).requestId, "the relay request id is the envelope's").toBe(request.requestDigest);
    return { status: request.status, id: request.requestDigest, envelope: request.envelope };
  });
}

function push(input: { sessionKey: unknown; requestId: string; envelope: unknown; result: string; title: string; kind: string; message: string; sessionId: string }) {
  const dedupeKey = DIGEST;
  return {
    receipt: { dedupeKey, sessionKey: input.sessionKey, grantIds: [GRANT], createdAt: ISO, expiresAt: ISO, result: input.result },
    inbox: { id: expect.any(String), dedupeKey, kind: input.kind, machineId: "lock-machine", message: input.message, outcome: input.result,
      requestIds: [input.requestId], sessionId: input.sessionId, title: input.title, createdAt: ISO, updatedAt: ISO },
    pending: (attempts: number, outcome: string) => ({ id: expect.any(String), dedupeKey, kind: input.kind, sessionKey: input.sessionKey,
      createdAt: ISO, expiresAt: ISO, targets: [{ grantId: GRANT, attempts, outcome, nextAttemptAt: ISO, requestId: input.requestId,
        title: input.title, message: input.message, route: { machineId: "lock-machine", sessionId: input.sessionId }, relayEnvelope: input.envelope }] }),
  };
}

function parsed(document: PushDocument) {
  return { receipts: document.receipts, revocations: document.revocations, inbox: document.inbox, pending: document.pending.map((intent) => ({ ...intent, targets: intent.targets.map((target) => {
    const stored = (target as { relayEnvelope?: unknown }).relayEnvelope;
    return typeof stored === "string" ? { ...target, relayEnvelope: JSON.parse(stored) as unknown } : target;
  }) })) };
}

function dedupeKeysJoin(document: PushDocument): void {
  const keys = document.receipts.map((receipt) => receipt.dedupeKey);
  expect(new Set(keys).size, "one dedupe key per push").toBe(keys.length);
  expect((document.inbox as Array<{ dedupeKey: string }>).map((entry) => entry.dedupeKey), "the inbox names each push's receipt").toEqual(keys);
  for (const intent of document.pending as unknown as Array<{ dedupeKey: string }>) expect(keys, "each queued intent has its receipt").toContain(intent.dedupeKey);
}

const answer = (frame: { ok: boolean; result?: unknown; error?: unknown }) => ({ ok: frame.ok, result: frame.result ?? null, error: frame.error ?? null });

const REGISTERED = { available: true, deviceRegistered: true, enabledDeviceCount: 1, notifyWhenAskPresented: true, notifyWhenFinished: true,
  notifyWhenWaiting: true, pendingCount: 0, registered: true, relayOrigin: RELAY_ORIGIN, requiresGrantRotation: false };

interface PushLock {
  readonly gateway: LockGateway;
  readonly phone: LockClient;
  readonly relay: Relay;
  readonly sessionId: string;
  readonly service: () => NotificationService;
  build(): Promise<NotificationService>;
  freeze(): void;
  advance(milliseconds: number): void;
  document(): Promise<PushDocument>;
  prompt(text: string): Promise<{ ok: boolean; result?: any; error?: any }>;
}

async function pushLock(name: string, extensions: Array<{ name: string; source: string }> = []): Promise<PushLock> {
  const relay = new Relay();
  let skew = 0;
  let frozen: number | undefined;
  const clock = () => (frozen ?? Date.now()) + skew;
  let current!: NotificationService;
  let gateway!: LockGateway;
  let home = "";
  const build = async () => {
    current = new NotificationService(new NotificationGrantStore(home), new PushRelayClient(RELAY_ORIGIN, relay.fetcher, clock), clock,
      () => {}, () => {}, () => {}, () => false);
    await current.initialize();
    owned.push(async () => current.dispose());
    return current;
  };
  gateway = await startLockGateway(name, { extensions, notifications: async (tronHome) => { home = tronHome; return build(); } });
  owned.push(() => gateway.dispose());
  const phone = await gateway.connect("phone", { clientRole: "mobile" });
  expect(answer(await phone.request("push.registration.upsert", {
    commandId: gateway.commandId(), installationId: "lock-installation", grantId: GRANT,
    secret: SECRET, previewsEnabled: false, relayOrigin: RELAY_ORIGIN,
    notifyWhenAskPresented: true, notifyWhenFinished: true, notifyWhenWaiting: true,
  })), "the registration").toEqual({ ok: true, result: REGISTERED, error: null });
  const created = await phone.request("session.create", { commandId: gateway.commandId(), cwd: gateway.cwd });
  const sessionId = created.result.sessionId as string;
  const opened = await phone.request("session.open", { sessionId });
  expect((await phone.request("session.sync", { sessionId, syncToken: opened.result.syncToken })).ok).toBe(true);
  return {
    gateway, phone, relay, sessionId, build,
    service: () => current,
    freeze: () => { frozen = Date.now(); },
    advance: (milliseconds) => { skew += milliseconds; },
    document: async () => JSON.parse(await readFile(join(gateway.tronHome, "state", "notifications.json"), "utf8")) as PushDocument,
    prompt: (text) => phone.send("session.prompt", { commandId: gateway.commandId(), sessionId, text }),
  };
}

function pushes(relay: Relay): string[] {
  return relay.requests.filter((request) => request.method === "POST").map((request) => {
    const envelope = request.envelope as { notificationKind?: string; title?: string; message?: string };
    return `${request.status} ${envelope.notificationKind} [${envelope.title}]: ${envelope.message}`;
  }, 60_000);
}

describe("gateway/notifications delivery locks", () => {
  it("notifications-waiting: a live detached run pushes waiting once per episode, and finished after it ends", async () => {
    const lock = await pushLock("notifications-waiting", [{ name: "lock-background.ts", source: DETACHED_RUN }]);
    const { gateway, relay, sessionId } = lock;
    const slot = await gateway.registry.acquire(sessionId);
    const turnEnded = (requests: number, label: string) => waitFor(() => !slot.snapshot().operation
      && gateway.record().providerRequests.length === requests
      && gateway.registry.administrativeDrainSnapshot().blockers.every((blocker) => blocker.category === "detached-extension-run"), label);
    gateway.script([
      () => fauxAssistantMessage([fauxToolCall("lock_background", {}, { id: "lock-background-call" })], { stopReason: "toolUse" }),
      () => fauxAssistantMessage("The background run is under way."),
      () => fauxAssistantMessage("Still waiting on the background run."),
      () => fauxAssistantMessage("The background run is done."),
    ]);

    expect((await lock.prompt("start the background run")).ok).toBe(true);
    await turnEnded(2, "the launching turn to end");
    await waitFor(() => pushes(relay).length === 1, "the waiting push");
    expect((await lock.prompt("is it still running")).ok).toBe(true);
    await turnEnded(3, "the second turn to end");
    await waitFor(async () => (await lock.document()).pending.length === 0, "the pushes to settle");
    const afterSecondTurn = pushes(relay);

    const endedAt = Date.now();
    await writeFile(join(gateway.cwd, ".pi", "subagents", "async-subagent-runs", "lock-background-run", "status.json"), JSON.stringify({
      runId: "lock-background-run", state: "complete", startedAt: endedAt - 1_000, endedAt, lastUpdate: endedAt + 1,
    }));
    await waitFor(() => slot.snapshot().extensionActivities?.every((activity) => activity.status === "completed"), "the background run to end");
    expect((await lock.prompt("and now")).ok).toBe(true);
    await gateway.settled(sessionId);
    await waitFor(() => pushes(relay).length === 2, "the finished push");
    await waitFor(async () => (await lock.document()).pending.length === 0, "the finished push to settle");

    expect(afterSecondTurn, "the second turn in the same waiting episode pushes nothing").toEqual(["200 waiting [start the background run]: The agent is waiting on 1 background task."]);
    const title = "start the background run";
    const sent = posts(relay);
    expect(sent, "one waiting push, then one finished push, each accepted").toEqual([
      { status: 200, id: DIGEST, envelope: envelope(sessionId, title, "waiting", "The agent is waiting on 1 background task.") },
      { status: 200, id: DIGEST, envelope: envelope(sessionId, title, "agent_finished", "The agent finished responding.") },
    ]);
    expect(sent[0]!.id, "distinct pushes go out under distinct request ids").not.toBe(sent[1]!.id);
    expect(relay.requests.every((request) => request.method === "POST"), "nothing is revoked").toBe(true);
    const document = await lock.document();
    const sessionKey = document.receipts[0]!.sessionKey;
    const waiting = push({ sessionKey, requestId: sent[0]!.id, envelope: sent[0]!.envelope, result: "accepted_by_apns", title, kind: "waiting",
      message: "The agent is waiting on 1 background task.", sessionId });
    const finished = push({ sessionKey, requestId: sent[1]!.id, envelope: sent[1]!.envelope, result: "accepted_by_apns", title, kind: "agent_finished",
      message: "The agent finished responding.", sessionId });
    expect(parsed(document), "both pushes delivered: receipts and inbox, nothing pending").toEqual({
      receipts: [waiting.receipt, finished.receipt], pending: [], revocations: [], inbox: [waiting.inbox, finished.inbox] });
    expect(sessionKey).toEqual(DIGEST);
    dedupeKeysJoin(document);
    const providerRequests = gateway.record().providerRequests;
    expectRequestShapes(providerRequests, Array.from({ length: 4 }, () => "chatWithNotificationsBackground"));
    const conversation = [
      { role: "user", text: title }, { role: "assistant", text: "", toolCalls: ["lock_background"] },
      { role: "toolResult", text: "Background run started.", toolName: "lock_background" },
      { role: "assistant", text: "The background run is under way." }, { role: "user", text: "is it still running" },
      { role: "assistant", text: "Still waiting on the background run." }, { role: "user", text: "and now" },
    ];
    expect(providerRequests.map((request) => request.messages), "the scripted turns' messages").toEqual([1, 3, 5, 7].map((count) => conversation.slice(0, count)));
  }, 60_000);

  it("overlapping terminal admissions send one waiting push per live background episode", async () => {
    const lock = await pushLock("notifications-overlapping-terminal", [{ name: "lock-background.ts", source: DETACHED_RUN }]);
    const { gateway, relay, sessionId } = lock;
    const slot = await gateway.registry.acquire(sessionId);
    let release!: () => void;
    const held = new Promise<void>(resolve => { release = resolve; });
    const service = lock.service();
    const enqueue = service.enqueue.bind(service);
    let reached!: () => void;
    const admitted = new Promise<void>(resolve => { reached = resolve; });
    let heldFirst = false;
    service.enqueue = async input => {
      const result = await enqueue(input);
      if (input.kind === "waiting" && !heldFirst) {
        heldFirst = true;
        reached();
        await held;
      }
      return result;
    };
    owned.push(async () => { release(); });
    gateway.script([
      () => fauxAssistantMessage([fauxToolCall("lock_background", {}, { id: "overlap-background-call" })], { stopReason: "toolUse" }),
      () => fauxAssistantMessage("Background work is running."),
      () => fauxAssistantMessage("The work is still running."),
    ]);
    expect((await lock.prompt("start background work")).ok).toBe(true);
    await awaitsWithin(admitted, "the predecessor's waiting admission");
    await waitFor(() => pushes(relay).length === 1, "the predecessor's waiting push");
    let successorSettled!: () => void;
    const successorTerminal = new Promise<void>(resolve => { successorSettled = resolve; });
    const notify = slot.runTerminal.notifyAgentTerminal.bind(slot.runTerminal);
    slot.runTerminal.notifyAgentTerminal = async (...args) => {
      await notify(...args);
      successorSettled();
    };
    expect((await lock.prompt("check the same background work")).ok).toBe(true);
    await waitFor(() => gateway.record().providerRequests.length === 3 && !slot.snapshot().operation, "the successor turn to end");
    await awaitsWithin(successorTerminal, "the successor terminal owner to settle while its predecessor is held");
    release();
    await waitFor(() => gateway.registry.administrativeDrainSnapshot().blockers.every(blocker => blocker.category === "detached-extension-run"), "both terminal owners to settle");
    await waitFor(async () => (await lock.document()).pending.length === 0, "the successor push to settle");
    expect(slot.snapshot().extensionActivities?.some(activity => activity.status === "running")).toBe(true);
    expect(pushes(relay)).toEqual([
      "200 waiting [start background work]: The agent is waiting on 1 background task.",
    ]);
  }, 60_000);

  it("a rejected waiting admission leaves the same live episode eligible for the next turn", async () => {
    const lock = await pushLock("notifications-waiting-rejected", [{ name: "lock-background.ts", source: DETACHED_RUN }]);
    const { gateway, relay, sessionId } = lock;
    const service = lock.service();
    const enqueue = service.enqueue.bind(service);
    let rejected!: () => void;
    const failed = new Promise<void>(resolve => { rejected = resolve; });
    service.enqueue = async input => {
      if (input.kind === "waiting") {
        service.enqueue = enqueue;
        rejected();
        throw new Error("Controlled notification admission rejection");
      }
      return enqueue(input);
    };
    gateway.script([
      () => fauxAssistantMessage([fauxToolCall("lock_background", {}, { id: "rejected-background-call" })], { stopReason: "toolUse" }),
      () => fauxAssistantMessage("Background work started."),
      () => fauxAssistantMessage("Still waiting."),
    ]);
    expect((await lock.prompt("start background work")).ok).toBe(true);
    await awaitsWithin(failed, "the controlled admission rejection");
    await waitFor(() => gateway.registry.administrativeDrainSnapshot().blockers.every(blocker => blocker.category === "detached-extension-run"), "the failed notification's terminal owner to settle");
    expect((await lock.prompt("check background work")).ok).toBe(true);
    await waitFor(() => pushes(relay).length === 1, "the next turn's waiting notification");
    expect(pushes(relay)).toEqual([
      "200 waiting [start background work]: The agent is waiting on 1 background task.",
    ]);
  }, 60_000);

  it("notifications-queued-restart: pushes the relay could not take stay queued and a restarted owner delivers them", async () => {
    const lock = await pushLock("notifications-queued-restart");
    const { gateway, phone, relay, sessionId } = lock;
    lock.freeze();
    const attempted = (count: number, label: string) => waitFor(async () => {
      const document = await lock.document();
      return document.pending.length === count && document.pending.every((intent) => intent.targets.every((target) => target.attempts === 1))
        ? document : undefined;
    }, label);
    relay.available = false;

    let reached!: () => void;
    const held = new Promise<void>((resolve) => { reached = resolve; });
    gateway.script([
      () => fauxAssistantMessage("Finished while the relay was down."),
      async (_context, options) => {
        reached();
        await new Promise<void>((resolve) => {
          const signal = options?.signal;
          if (!signal || signal.aborted) { resolve(); return; }
          signal.addEventListener("abort", () => resolve(), { once: true });
        });
        return fauxAssistantMessage("Aborted turn response.");
      },
    ]);
    expect((await lock.prompt("finish while the relay is down")).ok).toBe(true);
    await gateway.settled(sessionId);
    await attempted(1, "the finished push's first attempt");
    lock.advance(1_000);
    const stoppable = await lock.prompt("start a run to stop");
    await awaitsWithin(held, "the abortable provider request");
    expect((await phone.request("session.abort", { commandId: gateway.commandId(), sessionId, operationId: stoppable.result.operationId })).ok).toBe(true);
    await gateway.settled(sessionId);
    const queued = await attempted(2, "the stopped push's first attempt");

    lock.service().dispose();
    relay.available = true;
    lock.advance(6_000);
    await lock.build();
    await waitFor(async () => (await lock.document()).pending.length === 0, "the restarted owner to deliver the queue");
    const inbox = await lock.service().inbox();

    const title = "finish while the relay is down";
    const finishedMessage = "The agent finished responding.";
    const stoppedMessage = "The agent was stopped.";
    const sent = posts(relay);
    const finishedEnvelope = envelope(sessionId, title, "agent_finished", finishedMessage);
    const stoppedEnvelope = envelope(sessionId, title, "agent_finished", stoppedMessage);
    expect(sent, "each push is refused once while the relay is down, then delivered in order by the restarted owner").toEqual([
      { status: 503, id: DIGEST, envelope: finishedEnvelope }, { status: 503, id: DIGEST, envelope: stoppedEnvelope },
      { status: 200, id: DIGEST, envelope: finishedEnvelope }, { status: 200, id: DIGEST, envelope: stoppedEnvelope },
    ]);
    expect(sent[2]!.id, "the finished push is retried under its own request id").toBe(sent[0]!.id);
    expect(sent[3]!.id, "the stopped push is retried under its own request id").toBe(sent[1]!.id);
    expect(sent[0]!.id).not.toBe(sent[1]!.id);
    expect(sent[2]!.envelope, "and with the same envelope").toEqual(sent[0]!.envelope);
    expect(sent[3]!.envelope).toEqual(sent[1]!.envelope);
    const sessionKey = queued.receipts[0]!.sessionKey;
    const finished = (result: string) => push({ sessionKey, requestId: sent[0]!.id, envelope: sent[0]!.envelope, result, title, kind: "agent_finished", message: finishedMessage, sessionId });
    const stopped = (result: string) => push({ sessionKey, requestId: sent[1]!.id, envelope: sent[1]!.envelope, result, title, kind: "agent_finished", message: stoppedMessage, sessionId });
    expect(parsed(queued), "both pushes stay queued after one retryable attempt each").toEqual({
      receipts: [finished("queued").receipt, stopped("queued").receipt],
      pending: [finished("queued").pending(1, "retryable"), stopped("queued").pending(1, "retryable")],
      revocations: [], inbox: [finished("queued").inbox, stopped("queued").inbox] });
    dedupeKeysJoin(queued);
    const delivered = await lock.document();
    expect(parsed(delivered), "the restarted owner delivers both").toEqual({
      receipts: [finished("accepted_by_apns").receipt, stopped("accepted_by_apns").receipt], pending: [], revocations: [],
      inbox: [finished("accepted_by_apns").inbox, stopped("accepted_by_apns").inbox] });
    expect(delivered.receipts.map((receipt) => receipt.dedupeKey), "under the queued receipts")
      .toEqual(queued.receipts.map((receipt) => receipt.dedupeKey));
    const entry = (message: string) => ({ version: 1, id: expect.any(String), kind: "agent_finished", title, message, outcome: "accepted_by_apns",
      sessionId, isUnread: true, createdAt: ISO, updatedAt: ISO });
    expect(inbox, "the phone's inbox lists both, newest first, unread").toEqual({ notifications: [entry(stoppedMessage), entry(finishedMessage)], revision: expect.stringMatching(/^[0-9a-f]{32}$/u), unreadCount: 2 });
  }, 60_000);

  it("refuses the deleted read-only methods push.registration.status and filesystem.home as unknown", async () => {
    const { phone } = await pushLock("notifications-deleted-methods");
    for (const method of ["push.registration.status", "filesystem.home"]) {
      expect(answer(await phone.request(method, {})), method)
        .toEqual({ ok: false, result: null, error: expect.objectContaining({ code: "not_found", message: `Unknown gateway method: ${method}` }) });
    }
  }, 60_000);

  it("notifications-queued-cancel: removing the registration cancels a queued push and revokes the grant once the relay is back", async () => {
    const lock = await pushLock("notifications-queued-cancel");
    const { gateway, phone, relay, sessionId } = lock;
    lock.freeze();
    relay.available = false;
    gateway.script([() => fauxAssistantMessage("Finished while the relay was down.")]);
    expect((await lock.prompt("finish while the relay is down")).ok).toBe(true);
    await gateway.settled(sessionId);
    const queued = await waitFor(async () => {
      const document = await lock.document();
      return document.pending[0]?.targets[0]?.attempts === 1 ? document : undefined;
    }, "the push's first attempt");

    const removed = await phone.request("push.registration.remove", { commandId: gateway.commandId() });
    expect(removed.ok, JSON.stringify(removed)).toBe(true);
    const cancelled = await waitFor(async () => {
      const document = await lock.document();
      return (document.revocations[0] as { attempts?: number } | undefined)?.attempts === 1 ? document : undefined;
    }, "the revocation's first attempt");
    relay.available = true;
    lock.advance(60_000);
    await lock.service().drain();
    await waitFor(async () => (await lock.document()).revocations.length === 0, "the revocation to reach the relay");
    lock.advance(600_000);
    await lock.service().drain();
    const inbox = await lock.service().inbox();

    const title = "finish while the relay is down";
    const message = "The agent finished responding.";
    const sent = posts(relay);
    expect(sent, "the push is attempted once and never again").toEqual([{ status: 503, id: DIGEST, envelope: envelope(sessionId, title, "agent_finished", message) }]);
    const revocations = relay.requests.filter((request) => request.method === "DELETE");
    expect(revocations.map(({ path, status, envelope: body }) => ({ path, status, body })), "the grant is revoked once the relay is back")
      .toEqual([{ path: `/v3/grants/${GRANT}`, status: 503, body: null }, { path: `/v3/grants/${GRANT}`, status: 200, body: null }]);
    expect(revocations[1]!.requestDigest, "under one request id").toBe(revocations[0]!.requestDigest);
    expect(revocations[0]!.requestDigest).toEqual(DIGEST);
    expect(revocations[0]!.requestDigest).not.toBe(sent[0]!.id);
    expect(relay.requests.map((request) => request.method), "in this order").toEqual(["POST", "DELETE", "DELETE"]);
    const sessionKey = queued.receipts[0]!.sessionKey;
    const finished = (result: string) => push({ sessionKey, requestId: sent[0]!.id, envelope: sent[0]!.envelope, result, title, kind: "agent_finished", message, sessionId });
    expect(parsed(queued), "the push is queued after one retryable attempt").toEqual({
      receipts: [finished("queued").receipt], pending: [finished("queued").pending(1, "retryable")], revocations: [], inbox: [finished("queued").inbox] });
    dedupeKeysJoin(queued);
    const failed = { receipts: [finished("failed").receipt], pending: [], inbox: [finished("failed").inbox] };
    expect(parsed(cancelled), "removing the registration cancels it: receipt and inbox failed, the grant's revocation queued").toEqual({ ...failed,
      revocations: [{ grantId: GRANT, secret: SECRET, requestId: revocations[0]!.requestDigest, attempts: 1, createdAt: ISO, nextAttemptAt: ISO }] });
    expect(parsed(await lock.document()), "the delivered revocation leaves the store").toEqual({ ...failed, revocations: [] });
    expect(inbox, "the phone's inbox keeps the failed push, unread").toEqual({ notifications: [{ version: 1, id: expect.any(String), kind: "agent_finished",
      title, message, outcome: "failed", sessionId, isUnread: true, createdAt: ISO, updatedAt: ISO }], revision: expect.stringMatching(/^[0-9a-f]{32}$/u), unreadCount: 1 });
    expect(answer(removed), "the phone's removal").toEqual({ ok: true, result: { removed: true }, error: null });
  }, 60_000);
});
