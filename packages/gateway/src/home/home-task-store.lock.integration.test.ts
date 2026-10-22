import { createHash } from "node:crypto";
import { chmod, mkdir, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { it } from "vitest";
import { storePathLock } from "../../test-support/store-path-lock.js";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { authorizationRequestId, type HomeTaskAuthorizationState } from "./home-task-authorization.js";
import type { HomeTaskCheckin } from "../protocol/types.js";
import { HomeTaskStore, taskIntentDigest, type HomeTaskRecord, type HomeTaskWrite } from "./home-task-store.js";
import type { HomeWakeEvent } from "./home-wake-inbox.js";

/**
 * `gateway/home` mutation-path lock for the Home task store (plan §6.5 V4, §6.6;
 * test-support/store-path-lock.ts): setup, authority saves, task put/update/wake
 * publication, record admission, paging and temporary recovery, with each refusal code
 * and the exact files under `gateway/home/tasks` after every step.
 */
it("home-task-store-paths: initialize, authority, put, update, wake, page and admission", async () => {
  const log = await storePathLock({ module: "gateway/home", name: "home-task-store-paths", testFileUrl: import.meta.url, owned: "gateway/home/tasks" });
  const workspace = new TronWorkspace(log.home);
  try {
    await workspace.initialize();
    await drive(log, new HomeTaskStore(log.home, workspace));
  } finally {
    await workspace.dispose();
  }
  await log.finish();
});

type Log = Awaited<ReturnType<typeof storePathLock>>;
const hex = (seed: string) => createHash("sha256").update(seed).digest("hex");
const intent = { text: "Investigate a trusted project" };
const binding = { intentDigest: taskIntentDigest(intent.text), target: "/trusted/project", authorizationScope: "project-work", restoreEpoch: "epoch-1" };

function task(taskId: string, extra: Partial<HomeTaskWrite> = {}): HomeTaskWrite {
  return {
    version: 1, taskId, revision: 1, homeId: "home-1", generation: 1, routeGeneration: 1, intent, intentDigest: binding.intentDigest,
    target: binding.target, grantRef: null, scopeRef: null, lifecycle: "pending", sessionId: null, operationId: null,
    stopIntent: null, spend: null, reportRef: null, terminalEvidence: null, wake: null, ...extra,
  };
}

function checkin(id: string, extra: Partial<HomeTaskCheckin> = {}): HomeTaskCheckin {
  return { id, taskId: "task-1", sessionId: "sess-1", operationId: "op-1", at: "2026-01-01T00:10:00.000Z", attention: "none",
    step: "Step", done: "Done", next: "Next", ...extra };
}

function wake(eventId: string): HomeWakeEvent {
  return { eventId, routeGeneration: 1, createdAt: "2026-01-01T00:20:00.000Z", state: "pending", push: "pending", delivery: null, acknowledgedAt: null, redeliveries: [] };
}

async function drive(log: Log, store: HomeTaskStore): Promise<void> {
  const tasks = join(log.home, "gateway", "home", "tasks");
  const records = async () => { const all: HomeTaskRecord[] = []; for await (const record of store.records()) all.push(record); return all; };
  const page = async (input: { limit?: number; cursor?: string }) => {
    const { nextCursor, ...rest } = await store.page(input);
    return { ...rest, nextCursor: nextCursor !== undefined };
  };

  await log.step("read before initialize is refused", () => store.read("task-1"), "refused");
  await log.step("page and records before initialize are empty", async () => ({ page: await page({}), records: await records() }));
  await mkdir(join(log.home, "gateway", "home"), { mode: 0o700 });
  await writeFile(tasks, "{}", { mode: 0o700 });
  try {
    await log.step("a regular file where the tasks directory belongs is unsafe", () => store.read("task-1"), "refused");
  } finally { await rm(join(log.home, "gateway", "home"), { recursive: true }); }
  await log.step("initialize", () => store.initialize(), "result");
  await log.step("initialize again is unchanged", () => store.initialize(), "result");
  await log.step("restore epoch is a stable digest", async () => {
    const first = await store.restoreEpoch();
    return { digest: /^[a-f0-9]{64}$/u.test(first), stable: first === await store.restoreEpoch() };
  });

  const auth = store.authorization;
  const scope = { id: "scope-1", kind: "all-trusted-projects" as const, active: true, restoreEpoch: "epoch-1", createdAt: 1_000 };
  const requestId = authorizationRequestId(binding);
  const decision = { id: "decision-1", requestId, decidedAt: 1_000, approved: true, expiresAt: 5_000 };
  const grant = { id: "grant-1", decisionId: "decision-1", ...binding, expiresAt: 5_000, state: "available" as const };
  const save = (change: (state: HomeTaskAuthorizationState) => HomeTaskAuthorizationState) => async () => {
    await auth.save(change(await auth.load()));
    return auth.load();
  };
  await log.step("save authority from a stale revision conflicts", save((state) => ({ ...state, revision: 2 })), "refused");
  await log.step("save a scope", save((state) => ({ ...state, scopes: [scope] })), "result");
  await log.step("save a request, its decision and grant", save((state) => ({
    ...state, requests: [{ id: requestId, request: binding }], decisions: [decision], grants: [grant] })), "result");
  await log.step("a grant expiring apart from its decision is refused", save((state) => ({ ...state, grants: [{ ...grant, expiresAt: 6_000 }] })), "refused");
  await log.step("a grant bound to another request is refused", save((state) => ({ ...state, grants: [{ ...grant, target: "/other" }] })), "refused");
  await log.step("removing a scope is refused", save((state) => ({ ...state, scopes: [] })), "refused");

  await log.step("put task-1", () => store.put(task("task-1"), null), "result");
  log.advance(1_000);
  await log.step("put task-2", () => store.put(task("task-2"), null), "result");
  await log.step("put task-1 again as new conflicts", () => store.put(task("task-1"), null), "refused");
  await log.step("put a new task at revision 2 conflicts", () => store.put(task("task-3", { revision: 2 }), null), "refused");
  await log.step("put task-1 from a stale revision conflicts", () => store.put(task("task-1", { revision: 3 }), 2), "refused");
  // Each invalid record is refused before it is published; the codes are pinned per record.
  const invalidRecords: Array<[string, HomeTaskWrite]> = [
    ["generation 0", task("task-x", { generation: 0 })],
    ["an invalid home id", task("task-x", { homeId: "bad id!" })],
    ["an intent with another key", task("task-x", { intent: { ...intent, extra: 1 } as HomeTaskWrite["intent"] })],
    ["an intent digest of other text", task("task-x", { intentDigest: taskIntentDigest("other") })],
    ["a stop intent for another operation", task("task-x", { operationId: "op-1", stopIntent: { operationId: "op-2", requestedAt: "2026-01-01T00:00:00.000Z" } })],
    ["a report with an invalid entry id", task("task-x", { reportRef: { resultId: "r-1", sessionId: "sess-1", entryId: "bad id!", digest: hex("report") } })],
    ["a final outcome without its report", task("task-x", { lifecycle: "terminal", wake: wake(`task-result-${hex("task-x")}`),
      terminalEvidence: { outcome: "final", sessionId: "sess-1", entryIds: [], reason: "reported" } })],
    ["thirteen check-ins", task("task-x", { checkins: Array.from({ length: 13 }, (_v, index) => checkin(`c-${index}`, { taskId: "task-x" })) })],
    ["an attention check-in naming another session", task("task-x", { sessionId: "sess-1", operationId: "op-1",
      lastAttentionAt: "2026-01-01T00:10:00.000Z", attention: { checkin: checkin("c-a", { taskId: "task-x", sessionId: "sess-2", attention: "requested", needsAttention: true, blocker: "B" }), wake: wake("task-attention-c-a") } })],
    ["an attention check-in that requested none", task("task-x", { sessionId: "sess-1", operationId: "op-1",
      lastAttentionAt: "2026-01-01T00:10:00.000Z", attention: { checkin: checkin("c-a", { taskId: "task-x" }), wake: wake("task-attention-c-a") } })],
    ["the authorization name", task("authorization")],
    ["a scope the authority does not hold", task("task-x", { scopeRef: "scope-9" })],
  ];
  await log.step("invalid records are refused unpublished", async () => {
    const codes: Record<string, string | undefined> = {};
    for (const [label, record] of invalidRecords) codes[label] = await store.put(record, null).then(() => "published", (error: { code?: string }) => error.code ?? `uncoded: ${String(error)}`);
    if (Object.values(codes).includes("published")) throw new Error(`an invalid record was published: ${JSON.stringify(codes)}`);
    return codes;
  });
  log.advance(1_000);
  await log.step("activate task-1 under the scope", () => store.put(task("task-1", { revision: 2, lifecycle: "active", sessionId: "sess-1", operationId: "op-1", scopeRef: "scope-1" }), 1), "result");
  await log.step("moving task-1 to another reference is refused", () => store.put(task("task-1", { revision: 3, lifecycle: "active", sessionId: "sess-1", operationId: "op-1", grantRef: "grant-1" }), 2), "refused");
  const update = (label: string, taskId: string, change: (current: HomeTaskRecord) => HomeTaskRecord, expected: "result" | "refused") =>
    log.step(label, async () => ({ record: await store.update(taskId, change), writes: store.writeCount }), expected);
  await update("an unchanged update does not publish", "task-1", (current) => current, "result");
  log.advance(1_000);
  await update("record spend", "task-1", (current) => ({ ...current, spend: { sourceDigest: hex("spend"), inputTokens: 10, outputTokens: 5 } }), "result");
  await update("grow spend", "task-1", (current) => ({ ...current, spend: { ...current.spend!, inputTokens: 20, cacheReadTokens: 4, cacheWriteTokens: 1 } }), "result");
  await update("shrinking spend is refused", "task-1", (current) => ({ ...current, spend: { ...current.spend!, inputTokens: 1 } }), "refused");
  await update("dropping the cache split is refused", "task-1", (current) => ({ ...current, spend: { sourceDigest: hex("spend"), inputTokens: 40, outputTokens: 5 } }), "refused");
  await update("record two check-ins", "task-1", (current) => ({ ...current, checkins: [checkin("c-1"), checkin("c-2", { refs: { issue: "#1" } })] }), "result");
  await update("request attention", "task-1", (current) => ({ ...current, lastAttentionAt: "2026-01-01T00:10:00.000Z",
    attention: { checkin: checkin("c-3", { attention: "requested", needsAttention: true, blocker: "Blocked" }), wake: wake("task-attention-c-3") } }), "result");
  await update("changing the operation is refused", "task-1", (current) => ({ ...current, operationId: "op-2" }), "refused");
  await update("an invalid task id is refused", "bad id!", (current) => current, "refused");
  await update("the authorization name is refused", "authorization", (current) => current, "refused");
  await update("a missing task is refused", "task-9", (current) => current, "refused");
  await update("request stop", "task-1", (current) => ({ ...current, stopIntent: { operationId: "op-1", requestedAt: "2026-01-01T00:30:00.000Z" } }), "result");
  await update("changing the stop intent is refused", "task-1", (current) => ({ ...current, stopIntent: { operationId: "op-1", requestedAt: "2026-01-01T00:31:00.000Z" } }), "refused");
  log.advance(1_000);
  await update("settle task-1 final", "task-1", (current) => ({ ...current, lifecycle: "terminal", wake: wake(`task-result-${hex("task-1")}`),
    reportRef: { resultId: "result-1", sessionId: "sess-1", entryId: "entry-1", digest: hex("report") },
      terminalEvidence: { outcome: "final", sessionId: "sess-1", entryIds: ["entry-1"], reason: "reported" } }), "result");
  await update("a terminal task is final", "task-1", (current) => ({ ...current, queuedAt: "2026-01-01T00:00:00.000Z" }), "refused");

  const delivery = { sessionId: "home-sess", operationId: "home-op", generation: 1, routeGeneration: 1, messageDigest: hex("message") };
  const updateWake = (label: string, taskId: string, change: (current: HomeWakeEvent) => HomeWakeEvent, expected: "result" | "refused", eventId?: string) =>
    log.step(label, () => store.updateWake(taskId, change, eventId), expected);
  await updateWake("decide the result push", "task-1", (current) => ({ ...current, push: "decided" }), "result");
  await updateWake("an unchanged wake does not publish", "task-1", (current) => current, "result");
  await updateWake("undeciding the push is refused", "task-1", (current) => ({ ...current, push: "pending" }), "refused");
  await updateWake("renaming the event is refused", "task-1", (current) => ({ ...current, eventId: "task-result-other" }), "refused");
  await updateWake("admit the result", "task-1", (current) => ({ ...current, state: "admitted", delivery }), "result");
  await updateWake("claim the attention wake", "task-1", (current) => ({ ...current, state: "claimed", delivery }), "result", "task-attention-c-3");
  await updateWake("another event id is refused", "task-1", (current) => current, "refused", "task-attention-other");
  await updateWake("acknowledge the result", "task-1", (current) => ({ ...current, state: "acknowledged", acknowledgedAt: "2026-01-01T00:40:00.000Z" }), "result");
  await updateWake("an acknowledged wake is final", "task-1", (current) => ({ ...current, redeliveries: [{ from: 1, to: 2 }] }), "refused");
  await updateWake("a task with no wake is refused", "task-2", (current) => ({ ...current, push: "decided" }), "refused");

  await log.step("page one", () => page({ limit: 1 }));
  await log.step("page two follows the cursor", async () => {
    const first = await store.page({ limit: 1 });
    return page({ limit: 1, cursor: first.nextCursor! });
  });
  await log.step("a zero page limit is refused", () => page({ limit: 0 }), "refused");
  await log.step("a foreign cursor is refused", () => page({ cursor: Buffer.from(JSON.stringify({ epoch: "x", createdAt: 1, taskId: "task-1" })).toString("base64url") }), "refused");
  await log.step("records lists both tasks", records);

  const temporary = join(tasks, "0000000000000-task-9.json.123.abcdefabcdef.tmp");
  await log.step("an abandoned temporary is not a record", async () => { await writeFile(temporary, "{}", { mode: 0o600 }); return (await records()).map((record) => record.taskId); });
  await log.step("startup recovery removes the temporary", () => store.removeAbandonedTemporaries(), "result");
  const taskTwo = join(tasks, (await readdir(tasks)).find((name) => name.endsWith("-task-2.json"))!);
  await log.step("a task file readable by others is unsafe", async () => {
    await chmod(taskTwo, 0o644);
    try { return await store.read("task-2"); } finally { await chmod(taskTwo, 0o600); }
  }, "refused");
  await log.step("a malformed task file is invalid", async () => {
    const bytes = await readFile(taskTwo);
    await writeFile(taskTwo, "{");
    try { return await store.read("task-2"); } finally { await writeFile(taskTwo, bytes); }
  }, "refused");
  await log.step("read task-2", () => store.read("task-2"), "result");
}
