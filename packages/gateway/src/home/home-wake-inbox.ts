import { estimateTokens } from "@earendil-works/pi-coding-agent";
import { createHash } from "node:crypto";
import { CONTEXT_DELIVERY_RECEIPT_TYPE, makeContextDeliveryReceipt } from "../sessions/context-delivery-receipts.js";
import { HOME_TASK_RESULT_MESSAGE, INVOCATION_RECEIPT_TYPE, parseInvocationReceipt } from "../sessions/invocation-receipts.js";
import { GatewayError } from "../errors.js";
import { EpisodicMemoryError } from "../episodic/episodic-contract.js";
import { AsyncMutex } from "../util/async-mutex.js";
import type { HomeTaskRecord, HomeTaskStore } from "./home-task-store.js";
import type { HomeTaskSubagents } from "./home-task-subagents.js";

export { HOME_TASK_RESULT_MESSAGE };
export const HOME_TASK_PENDING_MESSAGE = "tron.home-task-pending.v1";
/** Consecutive wake activations with no user message between them (#749). */
export const HOME_WAKE_CEILING = 8;
export interface HomeWakeEnvelope { signal: AbortSignal; tokens: number; freshTokens: number; bytes: number; entries: number }
export interface HomeWakeRoute { homeId: string; routeGeneration: number; generation: number; enabled: boolean; sessionId: string }
export interface HomeWakeEvent {
  eventId: string;
  routeGeneration: number;
  createdAt: string;
  state: "pending" | "claimed" | "admitted" | "terminal" | "acknowledged" | "blocked" | "outcome-unknown";
  /** Undecided until one push covers the event: a wake reply, a waiting notice, or the task-finished notice. */
  push: "pending" | "decided";
  delivery: { sessionId: string; operationId: string; generation: number; routeGeneration: number; messageDigest: string } | null;
  acknowledgedAt: string | null;
  redeliveries: Array<{ from: number; to: number }>;
}
export interface HomeWakeMessage {
  customType: typeof HOME_TASK_RESULT_MESSAGE | typeof HOME_TASK_PENDING_MESSAGE;
  content: string;
  display: true;
  details: { eventId: string; taskId: string; resultRef: HomeTaskRecord["reportRef"]; terminalEvidence: HomeTaskRecord["terminalEvidence"]; operationId: string; routeGeneration: number };
}
/** The result a wake starts with. It is the run's trigger: the SDK appends it and starts the turn. */
export interface HomeWakeTrigger { taskId: string; message: HomeWakeMessage }
/** `user`: a user activation drains results as context; `wake`: the last result starts the run. */
export type HomeWakeDelivery = "user" | "wake";
export interface HomeWakeEvidence {
  type: string; id: string; sessionId: string; customType?: string; details?: unknown; data?: unknown; content?: unknown;
}
/** The one delivery whose canonical proof is being read. */
export interface HomeWakeEvidenceScope { sessionId: string; taskId: string; eventId: string; operationId: string }
export interface HomeWakeDiagnostic { event: "home.task.inbox"; eventHash: string; state: HomeWakeEvent["state"]; reason: string }
interface Options {
  notify: (input: { sessionId: string; sourceId: string; kind: "agent_finished"; title: string; message: string; route?: { sessionId: string; machineId: string } }) => Promise<unknown>;
  /** The Home chapter a push opens: the newest openable chapter of `homeId`, or
   * undefined when that Home has none. A push names a real session because a
   * notification's route must be the session it is about. */
  pushSession: (homeId: string) => string | undefined;
  machineId?: string;
  result: (taskId: string) => Promise<{ task: HomeTaskRecord | undefined; text: string; subagents: HomeTaskSubagents }>;
  /** Reads the canonical entries one delivery's proof can use; it must keep no others. */
  evidence: (scope: HomeWakeEvidenceScope) => Promise<HomeWakeEvidence[]>;
  /** Whether a settled result may wake Home now. Read when a result settles: only
   * the wake's own admission can refuse later (ceiling, busy, failure). */
  wakeAvailable: (homeId: string) => Promise<boolean>;
  /** Asks the wake owner to look at pending results. Called at most once per settled result. */
  wake: (homeId: string) => void;
  diagnostic?: (record: HomeWakeDiagnostic) => void;
}
const hash = (value: string) => createHash("sha256").update(value).digest("hex");

/** Each terminal task owns its outbox/tombstone. There is no independent event
 * catalog or retention clock that can outlive (or lose) its immutable result.
 * A result wakes Home only through the wake owner; recovery never prompts. */
export class WakeInboxOwner {
  private readonly mutex = new AsyncMutex();
  constructor(private readonly store: HomeTaskStore, private readonly options: Options) {}

  event(task: HomeTaskRecord): HomeWakeEvent {
    return { eventId: `task-result-${hash(task.taskId)}`, routeGeneration: task.routeGeneration,
      createdAt: new Date().toISOString(), state: "pending", push: "pending", delivery: null, acknowledgedAt: null, redeliveries: [] };
  }

  /** A settled result. Home is eligible: the wake owner decides when it runs and
   * which push covers the result. Otherwise the task-finished push goes now. */
  async publish(taskId: string): Promise<void> {
    await this.mutex.run(async () => {
      const task = await this.store.read(taskId);
      if (!task?.wake || task.wake.push === "decided") return;
      if (await this.options.wakeAvailable(task.homeId)) { this.options.wake(task.homeId); return; }
      await this.pushTask(task);
    });
  }

  /** The task-finished push of today: one advisory notice per result, decided before enqueue. */
  private async pushTask(task: HomeTaskRecord): Promise<void> {
    await this.decide([task.taskId], "push-task-finished");
    await this.notify(task.homeId, task.wake!.eventId, `Tron Home task`,
      `Task finished: ${task.terminalEvidence!.outcome}. Open Home to review the result.`);
  }

  /** Results waiting for a wake, in the order a wake would deliver them. */
  async pendingTasks(homeId: string): Promise<HomeTaskRecord[]> {
    const pending: HomeTaskRecord[] = [];
    for await (const task of this.store.records()) {
      if (task.homeId === homeId && task.wake?.state === "pending") pending.push(task);
    }
    return pending.sort(deliveryOrder);
  }

  /** Pending results whose wake was refused. `task` keeps the per-result notice (disabled,
   * paused, blocked); `waiting` announces every pending result in one notice. */
  async pushPending(homeId: string, mode: "task" | "waiting"): Promise<void> {
    await this.mutex.run(async () => {
      const pending: HomeTaskRecord[] = [];
      for await (const task of this.store.records()) {
        if (task.homeId === homeId && task.wake?.state === "pending" && task.wake.push === "pending") pending.push(task);
      }
      if (mode === "task") { for (const task of pending) await this.pushTask(task); return; }
      if (pending.length === 0) return;
      await this.decide(pending.map(task => task.taskId), "push-waiting");
      await this.notify(homeId, `home-waiting:${pending[0]!.wake!.eventId}`, "Tron Home",
        "Home is waiting for you: finished task results are waiting in Home.");
    });
  }

  async recover(route: HomeWakeRoute): Promise<void> {
    await this.mutex.run(async () => {
      const proven = new Map<string, string[]>();
      for await (const task of this.store.records()) {
        if (!task.wake || task.wake.state === "acknowledged") continue;
        if (task.wake.state === "claimed") {
          await this.change(task.taskId, current => ({ ...current, state: "pending", delivery: null }), "claim-recovered");
        } else if (task.wake.state === "pending" && task.wake.push === "pending") {
          // A committed terminal whose publication never ran: decide its push as publish would.
          if (!(await this.options.wakeAvailable(task.homeId))) await this.pushTask(task);
        } else if (["admitted", "terminal"].includes(task.wake.state)) {
          const proof = await this.prove(task);
          if (proof === "proven") {
            // A route this process no longer owns cannot acknowledge; its event stays as it is.
            if (route.enabled && task.homeId === route.homeId && task.wake.routeGeneration === route.routeGeneration) {
              await this.change(task.taskId, current => ({ ...current, state: "terminal" }), "canonical-terminal");
              const operation = task.wake.delivery!.operationId;
              proven.set(operation, [...proven.get(operation) ?? [], task.taskId]);
            }
          }
          else if (proof !== "deferred") await this.change(task.taskId, current => ({ ...current, state: "outcome-unknown" }), `admission-proof-${proof}`);
        }
      }
      const operations = new Set<string>(proven.keys());
      for await (const task of this.store.records()) if (task.wake?.delivery) operations.add(task.wake.delivery.operationId);
      for (const operation of operations) await this.finishOperation(route, operation, proven.get(operation) ?? []);
    });
  }

  /** Decides a user activation's delivered results. A user message is Home's own
   * conversation, so these results need no push of their own. */
  private async decideDrained(taskIds: string[]): Promise<void> {
    await this.decide(taskIds, "push-drained-by-user-activation");
  }

  /** Admits pending results for one activation. `user` admits them as context
   * after the start boundary. `wake` appends all but the last selected result and
   * returns the last one as the trigger: the SDK appends it, and that starts the run. */
  async admit(route: HomeWakeRoute, operationId: string, delivery: HomeWakeDelivery,
    append: (message: HomeWakeMessage) => Promise<void>, prepareEnvelope: () => Promise<HomeWakeEnvelope>): Promise<HomeWakeTrigger | undefined> {
    if (!route.enabled) return undefined;
    return this.mutex.run(async () => {
      let pending = 0;
      for await (const task of this.store.records()) {
        if (task.homeId !== route.homeId || task.wake?.state !== "pending") continue;
        if (task.wake.routeGeneration !== route.routeGeneration) {
          await this.change(task.taskId, current => ({ ...current, state: "blocked" }), "route-replaced");
        } else pending++;
      }
      if (!pending) return undefined;
      const envelope = await prepareEnvelope();
      const pendingMessage = (count: number): HomeWakeMessage => ({ customType: HOME_TASK_PENDING_MESSAGE, display: true,
        content: `${count} more task results pending.`, details: { eventId: `pending:${operationId}`, taskId: "inbox",
          resultRef: null, terminalEvidence: null, operationId, routeGeneration: route.routeGeneration } });
      const cost = (message: HomeWakeMessage) => estimateTokens({ role: "custom", ...message, timestamp: Date.now() });
      // Reserve the attributed count and canonical attribution entries before
      // selecting results. Selection keeps one cursor and one candidate, and it
      // changes no state, so delivery below owns every transition.
      const count = pendingMessage(pending);
      let tokens = envelope.tokens - cost(count);
      let bytes = envelope.bytes - canonicalMessageBytes(count);
      let entries = envelope.entries - 2;
      let cursor: { createdAt: string; eventId: string } | undefined;
      const selected: Array<{ task: HomeTaskRecord; message: HomeWakeMessage; tokens: number; bytes: number }> = [];
      let remaining = pending;
      while (remaining > 0 && tokens > 0 && bytes > 0 && entries >= 2) {
        let next: HomeTaskRecord | undefined;
        for await (const task of this.store.records()) {
          if (task.homeId !== route.homeId || task.wake?.state !== "pending" || task.wake.routeGeneration !== route.routeGeneration
            || (cursor && wakeOrder(task.wake, cursor) <= 0)) continue;
          if (!next || deliveryOrder(task, next) < 0) next = task;
        }
        if (!next) break;
        envelope.signal.throwIfAborted();
        const task = next; const wake = task.wake!;
        const result = await this.options.result(task.taskId);
        if (!result.task || JSON.stringify(result.task.reportRef) !== JSON.stringify(task.reportRef)
          || JSON.stringify(result.task.terminalEvidence) !== JSON.stringify(task.terminalEvidence)) throw new GatewayError("conflict", "Immutable inbox result is unavailable");
        envelope.signal.throwIfAborted();
        // Every result states its subagent counts; the facts are settled with the task, so this header is stable.
        const header = `Home task ${task.taskId} (${task.terminalEvidence!.outcome}; subagents started ${result.subagents.started}, stopped at end ${result.subagents.stoppedAtEnd ?? "unknown"})`;
        let content = `${header}\n${result.text}`;
        const message = (): HomeWakeMessage => ({ customType: HOME_TASK_RESULT_MESSAGE, display: true, content,
          details: { eventId: wake.eventId, taskId: task.taskId, resultRef: task.reportRef, terminalEvidence: task.terminalEvidence,
            operationId, routeGeneration: route.routeGeneration } });
        // A permanently oversized report is acknowledged by its immutable
        // reference, never by a truncated payload or an unbounded tool read.
        if (cost(message()) > envelope.freshTokens - cost(count)) content = `${header}: immutable report, ${Buffer.byteLength(result.text)} bytes. Read the full immutable report through task action report with offset/limit pages.`;
        const selectedMessage = message(); const selectedTokens = cost(selectedMessage);
        const selectedBytes = canonicalMessageBytes(selectedMessage);
        if (selectedTokens > tokens || selectedBytes > bytes) break;
        selected.push({ task, message: selectedMessage, tokens: selectedTokens, bytes: selectedBytes });
        tokens -= selectedTokens; bytes -= selectedBytes; entries -= 2; remaining--; cursor = { createdAt: wake.createdAt, eventId: wake.eventId };
      }
      envelope.signal.throwIfAborted();
      const trigger = delivery === "wake" ? selected.pop() : undefined;
      if (delivery === "wake" && !trigger) return undefined;
      for (const item of selected) {
        await this.deliver(route, operationId, item, envelope);
        await append(item.message);
        if (delivery === "user") await this.decideDrained([item.task.taskId]);
      }
      if (remaining > 0 && envelope.tokens >= cost(count) && envelope.bytes >= canonicalMessageBytes(count) && envelope.entries >= 2) {
        await append(pendingMessage(remaining));
      }
      if (!trigger) return undefined;
      await this.deliver(route, operationId, trigger, envelope);
      return { taskId: trigger.task.taskId, message: trigger.message };
    });
  }

  /** Claim and admit one selected result. Nothing reaches the canonical session
   * before `append`, so an abort before it returns the event to pending under this
   * mutex. Its later proof would otherwise find no entry and mark a never-delivered
   * event outcome-unknown. */
  private async deliver(route: HomeWakeRoute, operationId: string, item: { task: HomeTaskRecord; message: HomeWakeMessage }, envelope: HomeWakeEnvelope): Promise<void> {
    const taskId = item.task.taskId;
    const delivery = { sessionId: route.sessionId, operationId, generation: route.generation, routeGeneration: route.routeGeneration,
      messageDigest: hash(item.message.content) };
    await this.change(taskId, current => ({ ...current, state: "claimed", delivery }), "next-user-message");
    if (envelope.signal.aborted) await this.release(taskId);
    envelope.signal.throwIfAborted();
    await this.change(taskId, current => ({ ...current, state: "admitted" }), "canonical-admission");
    if (envelope.signal.aborted) await this.release(taskId);
    envelope.signal.throwIfAborted();
  }

  /** The trigger reached no canonical session (its run never started), so it returns to
   * pending before any terminal receipt could settle it as outcome-unknown. */
  async releaseTrigger(taskId: string, operationId: string): Promise<void> {
    await this.mutex.run(async () => {
      const task = await this.store.read(taskId);
      if (task?.wake?.state === "admitted" && task.wake.delivery?.operationId === operationId) await this.release(taskId);
    });
  }

  async settle(route: HomeWakeRoute, operationId: string): Promise<void> {
    await this.mutex.run(async () => {
      const proven: string[] = [];
      for await (const task of this.store.records()) {
        if (task.wake?.delivery?.operationId !== operationId || task.wake.state !== "admitted") continue;
        this.assertRoute(task, route);
        const proof = await this.prove(task);
        if (proof === "deferred") continue;
        if (proof !== "proven") {
          await this.change(task.taskId, wake => ({ ...wake, state: "outcome-unknown" }), `terminal-proof-${proof}`); continue;
        }
        await this.change(task.taskId, wake => ({ ...wake, state: "terminal" }), "canonical-terminal");
        proven.push(task.taskId);
      }
      await this.finishOperation(route, operationId, proven);
    });
  }

  /** Decides the operation's push, then acknowledges its proven results. The store
   * refuses a push decision once a result is acknowledged, so the order is fixed.
   * One push per wake: the operation's first finished delivery covers every result it
   * carried; a wake whose results were all uncertain says Home is waiting instead.
   * Results a user activation drained were decided when admitted, so only wake
   * deliveries reach here. A still-admitted result is left for its own proof. */
  private async finishOperation(route: HomeWakeRoute, operationId: string, provenIds: string[]): Promise<void> {
    const pending: HomeTaskRecord[] = [];
    let replied = false;
    let open = false;
    for await (const task of this.store.records()) {
      if (task.wake?.delivery?.operationId !== operationId) continue;
      if (task.wake.state === "admitted") open = true;
      if (["terminal", "acknowledged"].includes(task.wake.state)) replied = true;
      if (task.wake.push === "pending" && task.wake.state !== "acknowledged") pending.push(task);
    }
    if (!open && pending.length > 0) {
      await this.decide(pending.map(task => task.taskId), replied ? "push-wake-reply" : "push-waiting-uncertain");
      if (replied) await this.notify(route.homeId, `home-wake:${operationId}`, "Tron Home", "Home replied to finished task results. Open Home to review.");
      else await this.notify(route.homeId, `home-waiting:${pending[0]!.wake!.eventId}`, "Tron Home", "Home is waiting for you: finished task results are waiting in Home.");
    }
    for (const taskId of provenIds) {
      const task = await this.store.read(taskId);
      if (task?.wake?.state === "terminal") await this.ack(task, route);
    }
  }

  async redeliver(taskId: string, route: HomeWakeRoute): Promise<void> {
    await this.mutex.run(async () => {
      const task = await this.store.read(taskId);
      // Only an event that was never admitted is retargetable. The store keeps
      // `delivery` null for pending and blocked events, so an uncertain admitted
      // effect (`outcome-unknown`) can never be re-stamped as pending.
      if (!route.enabled || !task?.wake || task.homeId !== route.homeId || !["pending", "blocked"].includes(task.wake.state)) throw new GatewayError("conflict", "Inbox event is not eligible for explicit redelivery");
      if (task.wake.state === "pending" && task.wake.routeGeneration === route.routeGeneration) return;
      await this.change(taskId, wake => ({ ...wake, routeGeneration: route.routeGeneration, state: "pending",
        redeliveries: [...wake.redeliveries, { from: wake.routeGeneration, to: route.routeGeneration }] }), "maintainer-redelivery");
    });
  }

  private async release(taskId: string): Promise<void> {
    await this.change(taskId, current => ({ ...current, state: "pending", delivery: null }), "admission-aborted");
  }

  private assertRoute(task: HomeTaskRecord, route: HomeWakeRoute): void {
    if (!route.enabled || task.homeId !== route.homeId || task.wake!.routeGeneration !== route.routeGeneration
      || task.wake!.delivery?.routeGeneration !== route.routeGeneration) throw new GatewayError("conflict", "Inbox acknowledgement route is stale");
  }
  private async ack(task: HomeTaskRecord, route: HomeWakeRoute): Promise<void> {
    this.assertRoute(task, route);
    await this.change(task.taskId, wake => ({ ...wake, state: "acknowledged", acknowledgedAt: new Date().toISOString() }), "canonical-consumed");
  }

  /** One delivery's proof. A source that refuses this event (over the bound, torn,
   * or not this session) can never prove it: `unreadable`. A transient read or
   * fsync failure is `deferred`: the event keeps its state for the next activation
   * to re-prove. Neither outcome refuses the activation. */
  private async prove(task: HomeTaskRecord): Promise<"proven" | "missing" | "unreadable" | "deferred"> {
    const delivery = task.wake!.delivery!;
    let entries: HomeWakeEvidence[];
    try {
      entries = await this.options.evidence({ sessionId: delivery.sessionId, taskId: task.taskId, eventId: task.wake!.eventId, operationId: delivery.operationId });
    } catch (error) {
      return error instanceof EpisodicMemoryError && error.kind === "source" ? "unreadable" : "deferred";
    }
    return this.proof(task, entries) ? "proven" : "missing";
  }

  private proof(task: HomeTaskRecord, entries: HomeWakeEvidence[]): boolean {
    const wake = task.wake!; const delivery = wake.delivery;
    if (!delivery) return false;
    const messages = entries.filter(entry => entry.type === "custom_message" && entry.customType === HOME_TASK_RESULT_MESSAGE
      && (entry.details as { eventId?: string })?.eventId === wake.eventId);
    if (messages.length !== 1) return false;
    const message = messages[0]!;
    const details = message.details as HomeWakeMessage["details"];
    const terminals = entries.filter(entry => entry.type === "custom" && entry.customType === INVOCATION_RECEIPT_TYPE && entry.sessionId === delivery.sessionId)
      .map(entry => parseInvocationReceipt(entry.data)).filter(receipt => receipt?.receiptKind === "terminal" && receipt.operationId === delivery.operationId && receipt.sessionId === delivery.sessionId);
    const attribution = makeContextDeliveryReceipt(message.id, "stored", { source: "gateway:home-task",
      owner: { id: task.taskId, title: "Home task", source: "gateway:home-task" } });
    const attributed = entries.some(entry => entry.type === "custom" && entry.customType === CONTEXT_DELIVERY_RECEIPT_TYPE && entry.sessionId === delivery.sessionId
      && JSON.stringify(entry.data) === JSON.stringify(attribution));
    return attributed && terminals.length === 1 && typeof message.content === "string" && hash(message.content) === delivery.messageDigest
      && message.sessionId === delivery.sessionId && details.taskId === task.taskId && details.operationId === delivery.operationId
      && details.routeGeneration === delivery.routeGeneration && JSON.stringify(details.resultRef) === JSON.stringify(task.reportRef)
      && JSON.stringify(details.terminalEvidence) === JSON.stringify(task.terminalEvidence);
  }

  /** Marks the push decided for each task, durably, before any notification. */
  private async decide(taskIds: string[], reason: string): Promise<void> {
    for (const taskId of taskIds) await this.change(taskId, wake => ({ ...wake, push: "decided" }), reason);
  }

  private async notify(homeId: string, sourceId: string, title: string, message: string): Promise<void> {
    const sessionId = this.options.pushSession(homeId);
    if (!sessionId) return;
    try {
      await this.options.notify({ sessionId, sourceId, kind: "agent_finished", title, message,
        ...(this.options.machineId ? { route: { sessionId, machineId: this.options.machineId } } : {}) });
    } catch { /* canonical result/inbox remains available independently */ }
  }

  private async change(taskId: string, change: (wake: HomeWakeEvent) => HomeWakeEvent, reason: string): Promise<HomeTaskRecord> {
    const task = await this.store.updateWake(taskId, change);
    this.options.diagnostic?.({ event: "home.task.inbox", eventHash: hash(task.wake!.eventId).slice(0, 16), state: task.wake!.state, reason });
    return task;
  }
}

/** Whether a canonical entry can belong to one delivery's proof: its result
 * message, its terminal invocation receipt, or the attribution receipt that names
 * its task. The reader retains only these, never the whole chapter. */
export function isWakeEvidence(scope: HomeWakeEvidenceScope, entry: HomeWakeEvidence): boolean {
  if (entry.sessionId !== scope.sessionId) return false;
  if (entry.type === "custom_message") {
    return entry.customType === HOME_TASK_RESULT_MESSAGE && (entry.details as { eventId?: string } | undefined)?.eventId === scope.eventId;
  }
  if (entry.type !== "custom") return false;
  if (entry.customType === INVOCATION_RECEIPT_TYPE) {
    const receipt = parseInvocationReceipt(entry.data);
    return receipt?.receiptKind === "terminal" && receipt.operationId === scope.operationId;
  }
  if (entry.customType === CONTEXT_DELIVERY_RECEIPT_TYPE) {
    return (entry.data as { origin?: { owner?: { id?: unknown } } } | undefined)?.origin?.owner?.id === scope.taskId;
  }
  return false;
}

function deliveryOrder(a: HomeTaskRecord, b: HomeTaskRecord): number {
  return wakeOrder(a.wake!, b.wake!);
}

function wakeOrder(a: { createdAt: string; eventId: string }, b: { createdAt: string; eventId: string }): number {
  return a.createdAt.localeCompare(b.createdAt) || a.eventId.localeCompare(b.eventId);
}

/** Upper-bound the two SDK entries (message + attribution), including their
 * canonical identity framing. Home chapter/session IDs are bounded to 200. */
function canonicalMessageBytes(message: HomeWakeMessage): number {
  const identity = "x".repeat(200);
  const framing = { id: identity, parentId: identity, timestamp: new Date().toISOString() };
  return Buffer.byteLength(JSON.stringify({ ...framing, type: "custom_message", ...message })) + 1
    + Buffer.byteLength(JSON.stringify({ ...framing, type: "custom", customType: CONTEXT_DELIVERY_RECEIPT_TYPE,
      data: makeContextDeliveryReceipt(identity, "stored", { source: "gateway:home-task", owner: { id: message.details.taskId, title: "Home task inbox", source: "gateway:home-task" } }) })) + 1;
}
