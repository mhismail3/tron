import { fauxAssistantMessage, fauxToolCall } from "@earendil-works/pi-ai";
import { writeFile } from "node:fs/promises";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { startLockGateway, type LockClient, type LockGateway } from "../../test-support/gateway-lock-harness.js";
import { compareWithGolden, lockPaths, lockUpdateRequested, normalizeTraceValue, type TraceValue } from "../../test-support/scenario-lock.js";
import { awaitsWithin, waitFor } from "../../test-support/wait-for.js";
import { NotificationGrantStore } from "./grant-store.js";
import { NotificationService } from "./notification-service.js";
import { PushRelayClient } from "./relay-client.js";

/**
 * Push delivery locks (restructure E0b follow-up, K-0 §2.1 `runTerminal`;
 * guarding E5's notification hook) for `gateway/notifications`, beside
 * `notifications.push.lock`. The real Gateway (`gateway-lock-harness.ts`) runs
 * the production `NotificationService` and grant store; only the relay's HTTP
 * fetcher is replaced, and its answers are scripted per phase.
 *
 * - `notifications-waiting`: a turn that ends while its detached extension run
 *   is live pushes `waiting`; the next turn in the same waiting episode pushes
 *   nothing; once the run ends, a turn pushes `agent_finished`.
 * - `notifications-queued-restart`: with the relay unavailable a finished and a
 *   stopped push stay queued after one retryable attempt each; a restarted
 *   notification owner over the same Tron home delivers both, in order, under
 *   the same relay request ids.
 * - `notifications-queued-cancel`: a queued push is cancelled when the phone
 *   removes its registration (never sent again; receipt and inbox failed), and
 *   the grant's revocation reaches the relay once it is available.
 *
 * Dedupe keys, session keys and relay request ids are digests of per-run
 * session ids; each is relabelled by first appearance (`<digest:n>`), so a retry
 * under the same request id, or an inbox row naming it, reads as the same label.
 */

const MODULE = "gateway/notifications";
const RELAY_ORIGIN = "https://relay.lock.invalid";
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

/** `requestDigest` is the relay request id; it is not named `requestId`, which the
 * shared normalization would blind, so a retry's identity stays visible. */
interface RelayRequest { method: string; path: string; requestDigest: string; status: number; envelope: unknown }
interface PushDocument {
  receipts: Array<{ result: string; kind?: string }>;
  pending: Array<{ kind: string; targets: Array<{ attempts: number; outcome: string }> }>;
  revocations: unknown[];
  inbox: unknown[];
}

const owned: Array<() => Promise<void>> = [];
afterEach(async () => { for (const release of owned.splice(0).reverse()) await release(); });

/** The relay boundary: a scripted availability, every request recorded. */
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

/** A per-run digest (`notificationHash`: base64url SHA-256). */
const DIGEST = /^[A-Za-z0-9_-]{43}$/;

/** The trace with each digest relabelled by its first appearance. */
function relabelled(trace: Record<string, unknown>): TraceValue {
  const labels = new Map<string, string>();
  const walk = (value: unknown): unknown => {
    if (typeof value === "string" && DIGEST.test(value)) {
      if (!labels.has(value)) labels.set(value, `<digest:${labels.size + 1}>`);
      return labels.get(value);
    }
    if (Array.isArray(value)) return value.map(walk);
    if (value !== null && typeof value === "object") return Object.fromEntries(Object.entries(value).map(([key, child]) => [key, walk(child)]));
    return value;
  };
  return walk(trace) as TraceValue;
}

interface PushLock {
  readonly gateway: LockGateway;
  readonly phone: LockClient;
  readonly relay: Relay;
  readonly sessionId: string;
  /** The owner `gateway-main` builds, on a clock the lock may move forward. */
  readonly service: () => NotificationService;
  build(): Promise<NotificationService>;
  /** Stop the owner's clock, so no retry comes due unless the lock advances it. */
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
  expect((await phone.request("push.registration.upsert", {
    commandId: gateway.commandId(), installationId: "lock-installation", grantId: "lock-grant-0001",
    secret: Buffer.alloc(32, 7).toString("base64url"), previewsEnabled: false, relayOrigin: RELAY_ORIGIN,
    notifyWhenAskPresented: true, notifyWhenFinished: true, notifyWhenWaiting: true,
  })).ok).toBe(true);
  const created = await phone.request("session.create", { commandId: gateway.commandId(), cwd: gateway.cwd });
  const sessionId = created.result.sessionId as string;
  const opened = await phone.request("session.open", { sessionId });
  expect((await phone.request("session.sync", { sessionId, syncToken: opened.result.syncToken })).ok).toBe(true);
  return {
    gateway, phone, relay, sessionId, build,
    service: () => current,
    freeze: () => { frozen = Date.now(); },
    advance: (milliseconds) => { skew += milliseconds; },
    document: async () => (await gateway.file(`${gateway.tronHome}/gateway/notifications.json`)) as unknown as PushDocument,
    prompt: (text) => phone.send("session.prompt", { commandId: gateway.commandId(), sessionId, text }),
  };
}

/** Envelope summaries: kind, title and message of each push the relay was asked to send. */
function pushes(relay: Relay): string[] {
  return relay.requests.filter((request) => request.method === "POST").map((request) => {
    const envelope = request.envelope as { notificationKind?: string; title?: string; message?: string };
    return `${request.status} ${envelope.notificationKind} [${envelope.title}]: ${envelope.message}`;
  }, 60_000);
}

/** The store's queue, receipts, revocations and inbox; each target's stored relay
 * envelope is parsed, so its values are normalized like every other. */
function storeRecord(document: PushDocument, gateway: LockGateway): TraceValue {
  const pending = document.pending.map((intent) => ({
    ...intent,
    targets: intent.targets.map((target) => {
      const envelope = (target as { relayEnvelope?: unknown }).relayEnvelope;
      return typeof envelope === "string" ? { ...target, relayEnvelope: JSON.parse(envelope) as unknown } : target;
    }),
  }));
  return normalizeTraceValue({ receipts: document.receipts, pending, revocations: document.revocations, inbox: document.inbox } as unknown as TraceValue,
    gateway.normalization);
}

describe("gateway/notifications delivery locks", () => {
  it("notifications-waiting: a live detached run pushes waiting once per episode, and finished after it ends", async () => {
    const lock = await pushLock("notifications-waiting", [{ name: "lock-background.ts", source: DETACHED_RUN }]);
    const { gateway, relay, sessionId } = lock;
    const slot = await gateway.registry.acquire(sessionId);
    // The slot stays busy while it owns the run, so a turn has ended once its
    // terminal work (receipt, then its push decision) has left the drain's
    // blockers and only the detached run remains. Prompting earlier races that
    // push decision (#1567).
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
    // The second turn's terminal has been decided once its receipt is written.
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

    const recorded = gateway.record();
    const trace = relabelled({
      lock: "notifications-waiting",
      relayRequests: normalizeTraceValue(relay.requests as unknown as TraceValue, gateway.normalization),
      store: storeRecord(await lock.document(), gateway),
      exchanges: recorded.exchanges,
      providerRequests: recorded.providerRequests as unknown as TraceValue[],
    });
    await compareWithGolden({
      module: MODULE, ...lockPaths(import.meta.url, (trace as { lock: string }).lock), trace, update: lockUpdateRequested(MODULE),
      validate: () => {
        expect(afterSecondTurn).toEqual(["200 waiting [start the background run]: The agent is waiting on 1 background task."]);
        expect(pushes(relay)).toEqual([
          "200 waiting [start the background run]: The agent is waiting on 1 background task.",
          "200 agent_finished [start the background run]: The agent finished responding.",
        ]);
      },
    });
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

    // A finished run, then a stopped one, while the relay answers 503.
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
    // The frozen clock moves one second, so the two pushes keep their creation order.
    lock.advance(1_000);
    const stoppable = await lock.prompt("start a run to stop");
    await awaitsWithin(held, "the abortable provider request");
    expect((await phone.request("session.abort", { commandId: gateway.commandId(), sessionId, operationId: stoppable.result.operationId })).ok).toBe(true);
    await gateway.settled(sessionId);
    const queued = await attempted(2, "the stopped push's first attempt");

    // The owner restarts over the same Tron home after the retry delay; the relay is back.
    lock.service().dispose();
    relay.available = true;
    lock.advance(6_000);
    await lock.build();
    await waitFor(async () => (await lock.document()).pending.length === 0, "the restarted owner to deliver the queue");
    const inbox = await lock.service().inbox();

    const recorded = gateway.record();
    const trace = relabelled({
      lock: "notifications-queued-restart",
      relayRequests: normalizeTraceValue(relay.requests as unknown as TraceValue, gateway.normalization),
      queued: storeRecord(queued, gateway),
      delivered: storeRecord(await lock.document(), gateway),
      inbox: normalizeTraceValue(inbox as unknown as TraceValue, gateway.normalization),
      exchanges: recorded.exchanges,
    });
    await compareWithGolden({
      module: MODULE, ...lockPaths(import.meta.url, (trace as { lock: string }).lock), trace, update: lockUpdateRequested(MODULE),
      validate: () => {
        expect(pushes(relay)).toEqual([
          "503 agent_finished [finish while the relay is down]: The agent finished responding.",
          "503 agent_finished [finish while the relay is down]: The agent was stopped.",
          "200 agent_finished [finish while the relay is down]: The agent finished responding.",
          "200 agent_finished [finish while the relay is down]: The agent was stopped.",
        ]);
        const ids = relay.requests.filter((request) => request.method === "POST").map((request) => request.requestDigest);
        expect(ids[2]).toBe(ids[0]);
        expect(ids[3]).toBe(ids[1]);
        expect(ids[0]).not.toBe(ids[1]);
        expect(queued.pending.map((intent) => intent.targets[0]!.outcome)).toEqual(["retryable", "retryable"]);
      },
    });
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
    // The revocation's first attempt meets the unavailable relay too.
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

    const recorded = gateway.record();
    const trace = relabelled({
      lock: "notifications-queued-cancel",
      relayRequests: normalizeTraceValue(relay.requests as unknown as TraceValue, gateway.normalization),
      queued: storeRecord(queued, gateway),
      cancelled: storeRecord(cancelled, gateway),
      final: storeRecord(await lock.document(), gateway),
      inbox: normalizeTraceValue(inbox as unknown as TraceValue, gateway.normalization),
      exchanges: recorded.exchanges,
    });
    await compareWithGolden({
      module: MODULE, ...lockPaths(import.meta.url, (trace as { lock: string }).lock), trace, update: lockUpdateRequested(MODULE),
      validate: () => {
        expect(pushes(relay)).toEqual(["503 agent_finished [finish while the relay is down]: The agent finished responding."]);
        expect(cancelled.pending).toEqual([]);
        expect(cancelled.receipts.at(-1)?.result).toBe("failed");
        expect(relay.requests.filter((request) => request.method === "DELETE").map((request) => request.status)).toEqual([503, 200]);
      },
    });
  }, 60_000);
});
