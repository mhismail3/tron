import { GatewayError } from "../../errors.js";
import type { SessionOperations } from "../../kernel/session/runtime-registry.js";
import { parseHomeTaskCheckin, parseHomeTaskCheckinRequest } from "../../kernel/delegation/task-checkin.js";
import type { HomeTaskCheckin, HomeTaskHistoryItem, HomeTaskHistoryPage } from "../../protocol/types.js";
import type { HomeTaskRecord, HomeTaskStore } from "./home-task-store.js";
import { homeTaskLineages } from "./home-task-lineage.js";
import { homeTaskOperationSpan } from "../../kernel/delegation/task-report.js";

const refuse = () => new GatewayError("conflict", "Task history evidence or cursor changed; reload history");
const compare = (a: Pick<HomeTaskHistoryItem, "at" | "id">, b: Pick<HomeTaskHistoryItem, "at" | "id">) =>
  Date.parse(b.at) - Date.parse(a.at) || a.id.localeCompare(b.id);

/** Recent task snapshots are capped at twelve. Canonical accepted tool results,
 * not the snapshots copied on resume, own the complete progress history. */
export async function readHomeTaskHistory(store: HomeTaskStore, sessions: SessionOperations,
  input: { taskId: string; limit?: number; cursor?: string }, signal?: AbortSignal): Promise<HomeTaskHistoryPage> {
  const limit = input.limit ?? 20;
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > 50) throw new GatewayError("invalid_request", "Invalid history limit");
  const epoch = await store.restoreEpoch();
  const records: HomeTaskRecord[] = [];
  const writes = store.writeCount;
  for await (const task of store.records()) {
    signal?.throwIfAborted(); records.push(task);
  }
  if (store.writeCount !== writes) throw refuse();
  const lineage = homeTaskLineages(records).find(group => group.some(task => task.taskId === input.taskId));
  if (!lineage) throw new GatewayError("not_found", "No task with this id");
  const root = lineage[0]!.taskId;
  let after: Pick<HomeTaskHistoryItem, "at" | "id"> | undefined;
  if (input.cursor) {
    try {
      const value = JSON.parse(Buffer.from(input.cursor, "base64url").toString("utf8"));
      if (Object.keys(value).sort().join() !== "at,epoch,id,root" || value.epoch !== epoch || value.root !== root
        || typeof value.at !== "string" || !Number.isFinite(Date.parse(value.at)) || typeof value.id !== "string" || value.id.length > 200) throw refuse();
      after = value;
    } catch { throw refuse(); }
  }
  // Refused admissions are retained records, not worker operations or resumes.
  const operations = lineage.filter(task => task.operationId !== null);
  const byTask = new Map(operations.map(task => [task.taskId, task]));
  const checkins = new Map<string, HomeTaskCheckin>();
  const directIds = new Set<string>();
  const sources = new Map<string, Awaited<ReturnType<SessionOperations["readTaskEvidence"]>>>();
  let complete = true;
  const accept = (value: unknown) => {
    const checkin = parseHomeTaskCheckin(value);
    const task = byTask.get(checkin.taskId);
    if (!task || task.sessionId !== checkin.sessionId || task.operationId !== checkin.operationId) return;
    const previous = checkins.get(checkin.id);
    if (previous && JSON.stringify(previous) !== JSON.stringify(checkin)) throw refuse();
    checkins.set(checkin.id, checkin);
    return checkin;
  };
  for (const task of operations) for (const checkin of task.checkins ?? []) accept(checkin);
  for (const sessionId of new Set(operations.flatMap(task => task.sessionId ? [task.sessionId] : []))) {
    signal?.throwIfAborted();
    const entries = await sessions.readTaskEvidence(sessionId);
    sources.set(sessionId, entries);
    for (const entry of entries) {
      if (entry.type !== "message" || entry.message.role !== "toolResult" || entry.message.toolName !== "checkin" || entry.message.isError) continue;
      const details = entry.message.details as { checkin?: unknown } | undefined;
      if (details?.checkin) {
        const accepted = accept(details.checkin);
        if (accepted) directIds.add(accepted.id);
      } else { complete = false; }
    }
  }
  // Codemode retains nested arguments/status, not their result details. Snapshots
  // can still supply those exact records; never fabricate an ID or acceptance time
  // for a nested check-in that has aged out of both sources.
  const key = (operationId: string, value: HomeTaskCheckin | ReturnType<typeof parseHomeTaskCheckinRequest>) =>
    JSON.stringify([operationId, value.step, value.done, value.next, value.blocker ?? null, value.needsAttention === true,
      value.refs?.branch ?? null, value.refs?.commit ?? null, value.refs?.issue ?? null]);
  const retained = new Map<string, number>();
  for (const checkin of checkins.values()) if (!directIds.has(checkin.id)) {
    const id = key(checkin.operationId, checkin); retained.set(id, (retained.get(id) ?? 0) + 1);
  }
  for (const task of operations) {
    if (!task.sessionId || !task.operationId) continue;
    const span = homeTaskOperationSpan(sources.get(task.sessionId) ?? [], task.operationId);
    if (span.index < 0) { complete = false; continue; }
    for (const entry of span.run) {
      if (entry.type !== "message" || entry.message.role !== "toolResult") continue;
      const nested = entry.message.nestedCalls;
      // The SDK owns argument/count limits; incomplete means some calls or full
      // arguments were omitted, even when every retained call is successful.
      if (nested?.complete === false) complete = false;
      for (const call of nested?.calls ?? []) if (call.name === "checkin" && call.status !== "error") {
        if (call.status !== "ok") { complete = false; continue; }
        try {
          const id = key(task.operationId, parseHomeTaskCheckinRequest(call.arguments));
          const count = retained.get(id) ?? 0;
          if (!count) { complete = false; } else retained.set(id, count - 1);
        } catch { complete = false; }
      }
    }
  }
  signal?.throwIfAborted();
  const currentEpoch = await store.restoreEpoch();
  if (store.writeCount !== writes || epoch !== currentEpoch) throw refuse();
  const items: HomeTaskHistoryItem[] = [];
  for (const [index, task] of operations.entries()) {
    const operation = { taskId: task.taskId, operationId: task.operationId, operationNumber: index + 1,
      lifecycle: task.lifecycle, outcome: task.terminalEvidence?.outcome ?? null };
    items.push({ ...operation, id: `operation.${task.taskId}`, at: new Date(task.createdAt).toISOString() });
    for (const checkin of checkins.values()) if (checkin.taskId === task.taskId)
      items.push({ ...operation, id: checkin.id, at: checkin.at, checkin });
  }
  items.sort(compare);
  const page = items.filter(item => !after || compare(item, after) > 0).slice(0, limit + 1);
  const last = page[Math.min(page.length, limit) - 1];
  return { items: page.slice(0, limit), total: items.length, complete, ...(page.length > limit && last
    ? { nextCursor: Buffer.from(JSON.stringify({ epoch, root, at: last.at, id: last.id })).toString("base64url") } : {}) };
}
