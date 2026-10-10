import { estimateTokens } from "@earendil-works/pi-coding-agent";
import { createHash } from "node:crypto";
import { CONTEXT_DELIVERY_RECEIPT_TYPE, makeContextDeliveryReceipt } from "../sessions/context-delivery-receipts.js";
import { INVOCATION_RECEIPT_TYPE, parseInvocationReceipt } from "../sessions/invocation-receipts.js";
import { GatewayError } from "../errors.js";
import { EpisodicMemoryError } from "../episodic/episodic-contract.js";
import { AsyncMutex } from "../util/async-mutex.js";
import type { HomeTaskRecord, HomeTaskStore } from "./home-task-store.js";

export const HOME_TASK_RESULT_MESSAGE = "tron.home-task-result.v1";
export const HOME_TASK_PENDING_MESSAGE = "tron.home-task-pending.v1";
export interface HomeWakeEnvelope { signal: AbortSignal; tokens: number; freshTokens: number; bytes: number; entries: number }
export interface HomeWakeRoute { homeId: string; routeGeneration: number; generation: number; enabled: boolean; sessionId: string }
export interface HomeWakeEvent {
  eventId: string;
  routeGeneration: number;
  createdAt: string;
  state: "pending" | "claimed" | "admitted" | "terminal" | "acknowledged" | "blocked" | "outcome-unknown";
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
export interface HomeWakeEvidence {
  type: string; id: string; sessionId: string; customType?: string; details?: unknown; data?: unknown; content?: unknown;
}
/** The one delivery whose canonical proof is being read. */
export interface HomeWakeEvidenceScope { sessionId: string; taskId: string; eventId: string; operationId: string }
export interface HomeWakeDiagnostic { event: "home.task.inbox"; eventHash: string; state: HomeWakeEvent["state"]; reason: string }
interface Options {
  notify: (input: { sessionId: string; sourceId: string; kind: "agent_finished"; title: string; message: string; route?: { sessionId: string; machineId: string } }) => Promise<unknown>;
  machineId?: string;
  result: (taskId: string) => Promise<{ task: HomeTaskRecord | undefined; text: string }>;
  /** Reads the canonical entries one delivery's proof can use; it must keep no others. */
  evidence: (scope: HomeWakeEvidenceScope) => Promise<HomeWakeEvidence[]>;
  diagnostic?: (record: HomeWakeDiagnostic) => void;
}
const hash = (value: string) => createHash("sha256").update(value).digest("hex");

/** Each terminal task owns its outbox/tombstone. There is no independent event
 * catalog or retention clock that can outlive (or lose) its immutable result.
 * Only a maintainer's next activation admits messages; recovery never prompts. */
export class WakeInboxOwner {
  private readonly mutex = new AsyncMutex();
  constructor(private readonly store: HomeTaskStore, private readonly options: Options) {}

  event(task: HomeTaskRecord): HomeWakeEvent {
    return { eventId: `task-result-${hash(task.taskId)}`, routeGeneration: task.routeGeneration,
      createdAt: new Date().toISOString(), state: "pending", push: "pending", delivery: null, acknowledgedAt: null, redeliveries: [] };
  }

  async publish(taskId: string): Promise<void> {
    await this.mutex.run(() => this.push(taskId));
  }
  private async push(taskId: string): Promise<void> {
    const task = await this.store.read(taskId);
    if (!task?.wake || task.wake.push === "decided") return;
    // At-most-once advisory decision precedes enqueue. Losing a push in this
    // crash window is acceptable; the co-committed inbox is guaranteed delivery.
    // NotificationService's bounded 24h dedupe cannot own task-lifetime replay.
    await this.change(taskId, wake => ({ ...wake, push: "decided" }), "push-decided");
    try {
      await this.options.notify({ sessionId: task.homeId, sourceId: task.wake.eventId, kind: "agent_finished",
        title: "Tron Home task", message: `Task finished: ${task.terminalEvidence!.outcome}. Open Home to review the result.`,
        ...(this.options.machineId ? { route: { sessionId: "home", machineId: this.options.machineId } } : {}) });
    } catch { /* canonical result/inbox remains available independently */ }
  }

  async recover(route: HomeWakeRoute): Promise<void> {
    await this.mutex.run(async () => {
      for await (const task of this.store.records()) {
        if (!task.wake || task.wake.state === "acknowledged") continue;
        await this.push(task.taskId);
        const wake = task.wake!;
        if (wake.state === "claimed") {
          await this.change(task.taskId, current => ({ ...current, state: "pending", delivery: null }), "claim-recovered");
        } else if (["admitted", "terminal"].includes(wake.state)) {
          const proof = await this.prove(task);
          if (proof === "proven") {
            if (route.enabled && task.homeId === route.homeId && wake.routeGeneration === route.routeGeneration) await this.ack(task, route);
          }
          else if (proof !== "deferred") await this.change(task.taskId, current => ({ ...current, state: "outcome-unknown" }), `admission-proof-${proof}`);
        }
      }
    });
  }

  async admit(route: HomeWakeRoute, operationId: string, append: (message: HomeWakeMessage) => Promise<void>, prepareEnvelope: () => Promise<HomeWakeEnvelope>): Promise<void> {
    if (!route.enabled) return;
    await this.mutex.run(async () => {
      let pending = 0;
      for await (const task of this.store.records()) {
        if (task.homeId !== route.homeId || task.wake?.state !== "pending") continue;
        if (task.wake.routeGeneration !== route.routeGeneration) {
          await this.change(task.taskId, current => ({ ...current, state: "blocked" }), "route-replaced");
        } else pending++;
      }
      if (!pending) return;
      const envelope = await prepareEnvelope();
      const pendingMessage = (count: number): HomeWakeMessage => ({ customType: HOME_TASK_PENDING_MESSAGE, display: true,
        content: `${count} more task results pending.`, details: { eventId: `pending:${operationId}`, taskId: "inbox", resultRef: null,
          terminalEvidence: null, operationId, routeGeneration: route.routeGeneration } });
      const cost = (message: HomeWakeMessage) => estimateTokens({ role: "custom", ...message, timestamp: Date.now() });
      // Reserve the attributed count and canonical attribution entries before
      // selecting results. A cursor/minimum selection retains only one record,
      // irrespective of blocked events or total backlog membership.
      const count = pendingMessage(pending);
      let tokens = envelope.tokens - cost(count);
      let bytes = envelope.bytes - canonicalMessageBytes(count);
      let entries = envelope.entries - 2;
      let cursor: { createdAt: string; eventId: string } | undefined;
      while (pending > 0 && tokens > 0 && bytes > 0 && entries >= 2) {
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
        let content = `Home task ${task.taskId} (${task.terminalEvidence!.outcome})\n${result.text}`;
        const message = (): HomeWakeMessage => ({ customType: HOME_TASK_RESULT_MESSAGE, display: true, content,
          details: { eventId: wake.eventId, taskId: task.taskId, resultRef: task.reportRef, terminalEvidence: task.terminalEvidence,
            operationId, routeGeneration: route.routeGeneration } });
        // A permanently oversized report is acknowledged by its immutable
        // reference, never by a truncated payload or an unbounded tool read.
        if (cost(message()) > envelope.freshTokens - cost(count)) content = `Home task ${task.taskId} (${task.terminalEvidence!.outcome}): immutable report, ${Buffer.byteLength(result.text)} bytes. Read the full immutable report through task action report with offset/limit pages.`;
        const selected = message(); const selectedTokens = cost(selected);
        const selectedBytes = canonicalMessageBytes(selected);
        if (selectedTokens > tokens || selectedBytes > bytes) break;
        const delivery = { sessionId: route.sessionId, operationId, generation: route.generation, routeGeneration: route.routeGeneration, messageDigest: hash(content) };
        await this.change(task.taskId, current => ({ ...current, state: "claimed", delivery }), "next-user-message");
        // Nothing reaches the canonical session before `append`, so an abort
        // before it returns the event to pending under this mutex. Its later
        // proof would otherwise find no entry and mark a never-delivered event
        // outcome-unknown.
        if (envelope.signal.aborted) await this.release(task.taskId);
        envelope.signal.throwIfAborted();
        await this.change(task.taskId, current => ({ ...current, state: "admitted" }), "canonical-admission");
        if (envelope.signal.aborted) await this.release(task.taskId);
        envelope.signal.throwIfAborted();
        await append(selected);
        tokens -= selectedTokens; bytes -= selectedBytes; entries -= 2; pending--; cursor = { createdAt: wake.createdAt, eventId: wake.eventId };
      }
      envelope.signal.throwIfAborted();
      if (envelope.tokens >= cost(count) && envelope.bytes >= canonicalMessageBytes(count) && envelope.entries >= 2) await append(pendingMessage(pending));
    });
  }

  async settle(route: HomeWakeRoute, operationId: string): Promise<void> {
    await this.mutex.run(async () => {
      for await (const task of this.store.records()) {
        if (task.wake?.delivery?.operationId !== operationId || task.wake.state !== "admitted") continue;
        this.assertRoute(task, route);
        const proof = await this.prove(task);
        if (proof === "deferred") continue;
        if (proof !== "proven") {
          await this.change(task.taskId, wake => ({ ...wake, state: "outcome-unknown" }), `terminal-proof-${proof}`); continue;
        }
        await this.change(task.taskId, wake => ({ ...wake, state: "terminal" }), "canonical-terminal");
        await this.ack(task, route);
      }
    });
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
