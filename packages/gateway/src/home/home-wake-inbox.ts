import { createHash } from "node:crypto";
import { CONTEXT_DELIVERY_RECEIPT_TYPE, makeContextDeliveryReceipt } from "../sessions/context-delivery-receipts.js";
import { INVOCATION_RECEIPT_TYPE, parseInvocationReceipt } from "../sessions/invocation-receipts.js";
import { GatewayError } from "../errors.js";
import { AsyncMutex } from "../util/async-mutex.js";
import type { HomeTaskRecord, HomeTaskStore } from "./home-task-store.js";

export const HOME_TASK_RESULT_MESSAGE = "tron.home-task-result.v1";
export interface HomeWakeRoute { homeId: string; routeGeneration: number; generation: number; enabled: boolean; sessionId: string }
export interface HomeWakeEvent {
  eventId: string;
  routeGeneration: number;
  createdAt: string;
  state: "pending" | "claimed" | "admitted" | "terminal" | "acknowledged" | "cancelled-before-admission" | "blocked" | "outcome-unknown";
  push: "pending" | "decided";
  delivery: { sessionId: string; operationId: string; generation: number; routeGeneration: number; messageDigest: string } | null;
  acknowledgedAt: string | null;
  redeliveries: Array<{ from: number; to: number }>;
}
export interface HomeWakeMessage {
  customType: typeof HOME_TASK_RESULT_MESSAGE;
  content: string;
  display: true;
  details: { eventId: string; taskId: string; resultRefs: HomeTaskRecord["reportRefs"]; terminalEvidence: HomeTaskRecord["terminalEvidence"]; operationId: string; routeGeneration: number };
}
export interface HomeWakeEvidence {
  type: string; id: string; sessionId: string; customType?: string; details?: unknown; data?: unknown; content?: unknown;
}
export interface HomeWakeDiagnostic { event: "home.task.inbox"; eventHash: string; state: HomeWakeEvent["state"]; reason: string }
interface Options {
  notify: (input: { sessionId: string; sourceId: string; kind: "agent_finished"; title: string; message: string; route?: { sessionId: string; machineId: string } }) => Promise<unknown>;
  machineId?: string;
  result: (taskId: string) => Promise<{ task: HomeTaskRecord | undefined; text: string }>;
  evidence: (sessionIds: string[]) => Promise<HomeWakeEvidence[]>;
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
      const tasks = await this.tasks();
      const deliveries = tasks.filter(task => ["admitted", "terminal"].includes(task.wake!.state));
      const entries = deliveries.length ? await this.options.evidence([...new Set(deliveries.map(task => task.wake!.delivery!.sessionId))]) : [];
      for (const task of tasks) {
        await this.push(task.taskId);
        const wake = task.wake!;
        if (wake.state === "claimed") {
          await this.change(task.taskId, current => ({ ...current, state: "pending", delivery: null }), "claim-recovered");
        } else if (["admitted", "terminal"].includes(wake.state)) {
          if (this.proof(task, entries)) {
            if (route.enabled && task.homeId === route.homeId && wake.routeGeneration === route.routeGeneration) await this.ack(task, route);
          }
          else await this.change(task.taskId, current => ({ ...current, state: "outcome-unknown" }), "admission-proof-missing");
        }
      }
    });
  }

  async admit(route: HomeWakeRoute, operationId: string, append: (message: HomeWakeMessage) => Promise<void>): Promise<void> {
    if (!route.enabled) return;
    await this.mutex.run(async () => {
      for (const task of await this.tasks()) {
        const wake = task.wake!;
        if (task.homeId !== route.homeId || wake.state !== "pending") continue;
        if (wake.routeGeneration !== route.routeGeneration) {
          await this.change(task.taskId, current => ({ ...current, state: "blocked" }), "route-replaced"); continue;
        }
        const result = await this.options.result(task.taskId);
        if (!result.task || JSON.stringify(result.task.reportRefs) !== JSON.stringify(task.reportRefs)
          || JSON.stringify(result.task.terminalEvidence) !== JSON.stringify(task.terminalEvidence)) throw new GatewayError("conflict", "Immutable inbox result is unavailable");
        const content = `Home task ${task.taskId} (${task.terminalEvidence!.outcome})\n${result.text}`;
        const delivery = { sessionId: route.sessionId, operationId, generation: route.generation, routeGeneration: route.routeGeneration, messageDigest: hash(content) };
        await this.change(task.taskId, current => ({ ...current, state: "claimed", delivery }), "next-user-message");
        // Before any canonical mutation: uncertain admission can never silently
        // retry an effect. The exact canonical message + terminal prove ack.
        await this.change(task.taskId, current => ({ ...current, state: "admitted" }), "canonical-admission");
        await append({ customType: HOME_TASK_RESULT_MESSAGE, display: true,
          content,
          details: { eventId: wake.eventId, taskId: task.taskId, resultRefs: task.reportRefs, terminalEvidence: task.terminalEvidence,
            operationId, routeGeneration: route.routeGeneration } });
      }
    });
  }

  async settle(route: HomeWakeRoute, operationId: string): Promise<void> {
    await this.mutex.run(async () => {
      const tasks = (await this.tasks()).filter(task => task.wake!.delivery?.operationId === operationId && task.wake!.state === "admitted");
      if (!tasks.length) return;
      const entries = await this.options.evidence([...new Set(tasks.map(task => task.wake!.delivery!.sessionId))]);
      for (const task of tasks) {
        this.assertRoute(task, route);
        if (!this.proof(task, entries)) {
          await this.change(task.taskId, wake => ({ ...wake, state: "outcome-unknown" }), "terminal-proof-missing"); continue;
        }
        await this.change(task.taskId, wake => ({ ...wake, state: "terminal" }), "canonical-terminal");
        await this.ack(task, route);
      }
    });
  }

  async redeliver(taskId: string, route: HomeWakeRoute): Promise<void> {
    await this.mutex.run(async () => {
      const task = await this.store.read(taskId);
      if (!route.enabled || !task?.wake || task.homeId !== route.homeId || !["pending", "blocked", "outcome-unknown", "cancelled-before-admission"].includes(task.wake.state)) throw new GatewayError("conflict", "Inbox event is not eligible for explicit redelivery");
      if (task.wake.state === "pending" && task.wake.routeGeneration === route.routeGeneration) return;
      // Outcome-unknown is not replayable: a maintainer may retarget a blocked
      // pending event, but cannot turn an uncertain admitted effect into pending.
      if (task.wake.delivery) throw new GatewayError("conflict", "Uncertain admitted result requires canonical inspection, not replay");
      await this.change(taskId, wake => ({ ...wake, routeGeneration: route.routeGeneration, state: "pending",
        redeliveries: [...wake.redeliveries, { from: wake.routeGeneration, to: route.routeGeneration }] }), "maintainer-redelivery");
    });
  }

  private assertRoute(task: HomeTaskRecord, route: HomeWakeRoute): void {
    if (!route.enabled || task.homeId !== route.homeId || task.wake!.routeGeneration !== route.routeGeneration
      || task.wake!.delivery?.routeGeneration !== route.routeGeneration) throw new GatewayError("conflict", "Inbox acknowledgement route is stale");
  }
  private async ack(task: HomeTaskRecord, route: HomeWakeRoute): Promise<void> {
    this.assertRoute(task, route);
    await this.change(task.taskId, wake => ({ ...wake, state: "acknowledged", acknowledgedAt: new Date().toISOString() }), "canonical-consumed");
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
      && details.routeGeneration === delivery.routeGeneration && JSON.stringify(details.resultRefs) === JSON.stringify(task.reportRefs)
      && JSON.stringify(details.terminalEvidence) === JSON.stringify(task.terminalEvidence);
  }
  private async tasks(): Promise<HomeTaskRecord[]> {
    const tasks: HomeTaskRecord[] = [];
    try { await this.store.list(task => { if (task.wake && task.wake.state !== "acknowledged") tasks.push(task); }); }
    catch (error) { if ((error as { code?: string }).code === "not-initialized") return []; throw error; }
    return tasks.sort((a, b) => a.wake!.createdAt.localeCompare(b.wake!.createdAt) || a.wake!.eventId.localeCompare(b.wake!.eventId));
  }
  private async change(taskId: string, change: (wake: HomeWakeEvent) => HomeWakeEvent, reason: string): Promise<HomeTaskRecord> {
    const task = await this.store.updateWake(taskId, change);
    this.options.diagnostic?.({ event: "home.task.inbox", eventHash: hash(task.wake!.eventId).slice(0, 16), state: task.wake!.state, reason });
    return task;
  }
}
