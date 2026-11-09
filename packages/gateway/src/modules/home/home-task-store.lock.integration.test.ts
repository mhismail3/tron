import { createHash } from "node:crypto";
import { chmod, mkdir, mkdtemp, readdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it, onTestFinished, vi } from "vitest";
import { TronWorkspace } from "../../workspace/tron-workspace.js";
import { authorizationRequestId, type HomeTaskAuthorizationState } from "./home-task-authorization.js";
import type { HomeTaskCheckin } from "../../protocol/types.js";
import { HomeTaskStore, taskIntentDigest, type HomeTaskRecord, type HomeTaskWrite } from "./home-task-store.js";
import type { HomeWakeEvent } from "./home-wake-inbox.js";

/**
 * `gateway/home` Home task store write paths (packages/gateway/docs/scenario-locks.md#persisted-stores-v4):
 * setup, authority saves, task put/update/wake publication, record admission, paging and
 * temporary recovery. Each step asserts its exact result or refusal, and the whole
 * `gateway/home/tasks` directory (literal file names, exact documents) is asserted after
 * every write and after each run of refusals, under a
 * fixed clock, so a changed write, name or refusal fails here. `store-home-tasks` pins
 * reading the committed format back.
 */
it("home-task-store-paths: initialize, authority, put, update, wake, page and admission", async () => {
  const home = await mkdtemp(join(tmpdir(), "tron-home-task-store-"));
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(EPOCH);
  onTestFinished(async () => { vi.useRealTimers(); await rm(home, { recursive: true, force: true }); });
  const workspace = new TronWorkspace(home);
  try {
    await workspace.initialize();
    await drive(home, new HomeTaskStore(home, workspace));
  } finally {
    await workspace.dispose();
  }
});

const EPOCH = Date.parse("2026-01-01T00:00:00.000Z");
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


/** What a store call was told: its result, or its refusal's message. */
async function outcome(work: () => unknown): Promise<{ result: unknown } | { refused: string }> {
  try { return { result: await work() }; } catch (error) { return { refused: error instanceof Error ? error.message : String(error) }; }
}
const refused = (code: string) => ({ refused: `Home task namespace refused: ${code}` });

/** A task record exactly as the store writes it: the write plus its creation and last publication times. */
const stored = (write: HomeTaskWrite, createdAt: number, updatedAt: number): HomeTaskRecord =>
  ({ ...write, createdAt: EPOCH + createdAt, updatedAt: EPOCH + updatedAt }) as HomeTaskRecord;

async function drive(home: string, store: HomeTaskStore): Promise<void> {
  const tasks = join(home, "gateway", "home", "tasks");
  const advance = (ms: number) => { vi.setSystemTime(Date.now() + ms); };
  const records = async () => { const all: HomeTaskRecord[] = []; for await (const record of store.records()) all.push(record); return all; };
  const page = async (input: { limit?: number; cursor?: string }) => {
    const { nextCursor, ...rest } = await store.page(input);
    return { ...rest, nextCursor: nextCursor !== undefined };
  };
  /** The files the store must hold, by literal name; a write updates it, then the directory must equal it at each checkpoint. */
  const expected: Record<string, unknown> = {};
  const holds = async (label: string) => {
    const names = await readdir(tasks).catch((error: NodeJS.ErrnoException) => { if (error.code === "ENOENT") return []; throw error; });
    const found: Record<string, unknown> = {};
    for (const name of names.sort()) found[name] = JSON.parse(await readFile(join(tasks, name), "utf8"));
    expect(found, `${label}: task files`).toEqual(expected);
  };

  expect(await outcome(() => store.read("task-1")), "read before initialize").toEqual(refused("not-initialized"));
  expect(await page({}), "page before initialize").toEqual({ items: [], counts: { active: 0, finished: 0 }, nextCursor: false });
  expect(await records(), "records before initialize").toEqual([]);
  await holds("before initialize");
  await mkdir(join(home, "gateway", "home"), { mode: 0o700 });
  await writeFile(tasks, "{}", { mode: 0o700 });
  try {
    expect(await outcome(() => store.read("task-1")), "a regular file where the tasks directory belongs").toEqual(refused("unsafe-state"));
    expect(await readFile(tasks, "utf8"), "the regular file is left as it was").toBe("{}");
  } finally { await rm(join(home, "gateway", "home"), { recursive: true }); }
  expect(await store.initialize(), "initialize").toBe(true);
  const authority = { version: 1, revision: 1, scopes: [] as unknown[], requests: [] as unknown[], decisions: [] as unknown[], grants: [] as unknown[] };
  expected["authorization.json"] = { ...authority };
  await holds("initialize writes the empty authority");
  expect(await store.initialize(), "initialize again is unchanged").toBe(false);
  await holds("initialize again");
  const epoch = await store.restoreEpoch();
  expect(epoch, "restore epoch is a digest").toMatch(/^[a-f0-9]{64}$/u);
  expect(await store.restoreEpoch(), "restore epoch is stable").toBe(epoch);

  const auth = store.authorization;
  const scope = { id: "scope-1", kind: "all-trusted-projects" as const, active: true, restoreEpoch: "epoch-1", createdAt: 1_000 };
  const requestId = authorizationRequestId(binding);
  expect(requestId, "the request id is the binding's digest").toBe("4ad71e1723ffd8be4999b95db6b7e405f472c43263098a2532ac59100ae7359a");
  const decision = { id: "decision-1", requestId, decidedAt: 1_000, approved: true, expiresAt: 5_000 };
  const grant = { id: "grant-1", decisionId: "decision-1", ...binding, expiresAt: 5_000, state: "available" as const };
  const save = async (change: (state: HomeTaskAuthorizationState) => HomeTaskAuthorizationState) => {
    await auth.save(change(await auth.load()));
    return auth.load();
  };
  const authorityHolds = async (label: string) => {
    const { version: _version, ...state } = authority;
    expect(await auth.load(), `${label}: loaded authority`).toEqual(state);
    expected["authorization.json"] = { ...authority };
    await holds(label);
  };
  expect(await outcome(() => save((state) => ({ ...state, revision: 2 }))), "save authority from a stale revision").toEqual(refused("revision-conflict"));
  await authorityHolds("the stale save changed nothing");
  await save((state) => ({ ...state, scopes: [scope] }));
  Object.assign(authority, { revision: 2, scopes: [scope] });
  await authorityHolds("save a scope");
  await save((state) => ({ ...state, requests: [{ id: requestId, request: binding }], decisions: [decision], grants: [grant] }));
  Object.assign(authority, { revision: 3, requests: [{ id: requestId, request: binding }], decisions: [decision], grants: [grant] });
  await authorityHolds("save a request, its decision and grant");
  expect(await outcome(() => save((state) => ({ ...state, grants: [{ ...grant, expiresAt: 6_000 }] }))), "a grant expiring apart from its decision").toEqual(refused("invalid-record"));
  expect(await outcome(() => save((state) => ({ ...state, grants: [{ ...grant, target: "/other" }] }))), "a grant bound to another request").toEqual(refused("invalid-record"));
  expect(await outcome(() => save((state) => ({ ...state, scopes: [] }))), "removing a scope").toEqual(refused("invalid-record"));
  await authorityHolds("refused authority saves change nothing");

  const TASK_1 = "1767225600000-task-1.json";
  const TASK_2 = "1767225601000-task-2.json";
  let one = stored(task("task-1"), 0, 0);
  expect(await store.put(task("task-1"), null), "put task-1").toEqual(one);
  expected[TASK_1] = one;
  await holds("put task-1 is named by its creation time");
  advance(1_000);
  const two = stored(task("task-2"), 1_000, 1_000);
  expect(await store.put(task("task-2"), null), "put task-2").toEqual(two);
  expected[TASK_2] = two;
  await holds("put task-2");
  expect(await outcome(() => store.put(task("task-1"), null)), "put task-1 again as new").toEqual(refused("revision-conflict"));
  expect(await outcome(() => store.put(task("task-3", { revision: 2 }), null)), "put a new task at revision 2").toEqual(refused("revision-conflict"));
  expect(await outcome(() => store.put(task("task-1", { revision: 3 }), 2)), "put task-1 from a stale revision").toEqual(refused("revision-conflict"));
  await holds("conflicting puts publish nothing");
  // Each invalid record is refused before it is published.
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
  for (const [label, record] of invalidRecords) expect(await outcome(() => store.put(record, null)), label).toEqual(refused("invalid-record"));
  await holds("invalid records are refused unpublished");
  advance(1_000);
  const active = task("task-1", { revision: 2, lifecycle: "active", sessionId: "sess-1", operationId: "op-1", scopeRef: "scope-1" });
  one = stored(active, 0, 2_000);
  expect(await store.put(active, 1), "activate task-1 under the scope").toEqual(one);
  expected[TASK_1] = one;
  await holds("activate task-1 keeps its name");
  expect(await outcome(() => store.put(task("task-1", { revision: 3, lifecycle: "active", sessionId: "sess-1", operationId: "op-1", grantRef: "grant-1" }), 2)),
    "moving task-1 to another reference").toEqual(refused("invalid-record"));
  await holds("the refused move");

  /** Apply `change` through the store; when it publishes, task-1 must hold `next` at the next revision, stamped now. */
  const published = async (label: string, change: (current: HomeTaskRecord) => HomeTaskRecord, next: (current: HomeTaskRecord) => HomeTaskRecord, writes: number) => {
    one = { ...next(one), revision: one.revision + 1, updatedAt: Date.now() };
    expect(await store.update("task-1", change), label).toEqual(one);
    expect(store.writeCount, `${label}: one write`).toBe(writes);
    expected[TASK_1] = one;
    await holds(label);
  };
  const refusedUpdate = async (label: string, taskId: string, change: (current: HomeTaskRecord) => HomeTaskRecord, code: string) => {
    const writes = store.writeCount;
    expect(await outcome(() => store.update(taskId, change)), label).toEqual(refused(code));
    expect(store.writeCount, `${label}: no write`).toBe(writes);
    await holds(label);
  };
  expect(await store.update("task-1", (current) => current), "an unchanged update").toEqual(one);
  expect(store.writeCount, "an unchanged update does not publish").toBe(6);
  await holds("an unchanged update");
  advance(1_000);
  const spend = { sourceDigest: hex("spend"), inputTokens: 10, outputTokens: 5 };
  await published("record spend", (current) => ({ ...current, spend }), (current) => ({ ...current, spend }), 7);
  const grown = { ...spend, inputTokens: 20, cacheReadTokens: 4, cacheWriteTokens: 1 };
  await published("grow spend", (current) => ({ ...current, spend: { ...current.spend!, inputTokens: 20, cacheReadTokens: 4, cacheWriteTokens: 1 } }),
    (current) => ({ ...current, spend: grown }), 8);
  await refusedUpdate("shrinking spend", "task-1", (current) => ({ ...current, spend: { ...current.spend!, inputTokens: 1 } }), "invalid-record");
  await refusedUpdate("dropping the cache split", "task-1", (current) => ({ ...current, spend: { sourceDigest: hex("spend"), inputTokens: 40, outputTokens: 5 } }), "invalid-record");
  const checkins = [checkin("c-1"), checkin("c-2", { refs: { issue: "#1" } })];
  await published("record two check-ins", (current) => ({ ...current, checkins }), (current) => ({ ...current, checkins }), 9);
  const attention = { checkin: checkin("c-3", { attention: "requested", needsAttention: true, blocker: "Blocked" }), wake: wake("task-attention-c-3") };
  await published("request attention", (current) => ({ ...current, lastAttentionAt: "2026-01-01T00:10:00.000Z", attention }),
    (current) => ({ ...current, lastAttentionAt: "2026-01-01T00:10:00.000Z", attention }), 10);
  await refusedUpdate("changing the operation", "task-1", (current) => ({ ...current, operationId: "op-2" }), "invalid-record");
  await refusedUpdate("an invalid task id", "bad id!", (current) => current, "invalid-record");
  await refusedUpdate("the authorization name", "authorization", (current) => current, "invalid-record");
  await refusedUpdate("a missing task", "task-9", (current) => current, "missing-state");
  const stopIntent = { operationId: "op-1", requestedAt: "2026-01-01T00:30:00.000Z" };
  await published("request stop", (current) => ({ ...current, stopIntent }), (current) => ({ ...current, stopIntent }), 11);
  await refusedUpdate("changing the stop intent", "task-1", (current) => ({ ...current, stopIntent: { operationId: "op-1", requestedAt: "2026-01-01T00:31:00.000Z" } }), "invalid-record");
  advance(1_000);
  const settled = { lifecycle: "terminal" as const, wake: wake(`task-result-${hex("task-1")}`),
    reportRef: { resultId: "result-1", sessionId: "sess-1", entryId: "entry-1", digest: hex("report") },
    terminalEvidence: { outcome: "final" as const, sessionId: "sess-1", entryIds: ["entry-1"], reason: "reported" as const } };
  await published("settle task-1 final", (current) => ({ ...current, ...settled }), (current) => ({ ...current, ...settled }), 12);
  expect(one.updatedAt, "settled at the advanced clock").toBe(EPOCH + 4_000);
  await refusedUpdate("a terminal task is final", "task-1", (current) => ({ ...current, queuedAt: "2026-01-01T00:00:00.000Z" }), "invalid-record");

  const delivery = { sessionId: "home-sess", operationId: "home-op", generation: 1, routeGeneration: 1, messageDigest: hex("message") };
  /** Apply a wake change; when it publishes, task-1 must hold `next` at the next revision. */
  const wakePublished = async (label: string, change: (current: HomeWakeEvent) => HomeWakeEvent, next: (current: HomeTaskRecord) => HomeTaskRecord, eventId?: string) => {
    one = { ...next(one), revision: one.revision + 1, updatedAt: Date.now() };
    expect(await store.updateWake("task-1", change, eventId), label).toEqual(one);
    expected[TASK_1] = one;
    await holds(label);
  };
  const wakeRefused = async (label: string, taskId: string, change: (current: HomeWakeEvent) => HomeWakeEvent, code: string, eventId?: string) => {
    expect(await outcome(() => store.updateWake(taskId, change, eventId)), label).toEqual(refused(code));
    await holds(label);
  };
  await wakePublished("decide the result push", (current) => ({ ...current, push: "decided" }), (current) => ({ ...current, wake: { ...current.wake!, push: "decided" } }));
  expect(await store.updateWake("task-1", (current) => current), "an unchanged wake").toEqual(one);
  await holds("an unchanged wake does not publish");
  await wakeRefused("undeciding the push", "task-1", (current) => ({ ...current, push: "pending" }), "invalid-record");
  await wakeRefused("renaming the event", "task-1", (current) => ({ ...current, eventId: "task-result-other" }), "invalid-record");
  await wakePublished("admit the result", (current) => ({ ...current, state: "admitted", delivery }),
    (current) => ({ ...current, wake: { ...current.wake!, state: "admitted", delivery } }));
  await wakePublished("claim the attention wake", (current) => ({ ...current, state: "claimed", delivery }),
    (current) => ({ ...current, attention: { ...current.attention!, wake: { ...current.attention!.wake, state: "claimed", delivery } } }), "task-attention-c-3");
  await wakeRefused("another event id", "task-1", (current) => current, "missing-state", "task-attention-other");
  await wakePublished("acknowledge the result", (current) => ({ ...current, state: "acknowledged", acknowledgedAt: "2026-01-01T00:40:00.000Z" }),
    (current) => ({ ...current, wake: { ...current.wake!, state: "acknowledged", acknowledgedAt: "2026-01-01T00:40:00.000Z" } }));
  expect(one.revision, "twelve publications of task-1").toBe(12);
  await wakeRefused("an acknowledged wake is final", "task-1", (current) => ({ ...current, redeliveries: [{ from: 1, to: 2 }] }), "invalid-record");
  await wakeRefused("a task with no wake", "task-2", (current) => ({ ...current, push: "decided" }), "missing-state");

  const counts = { active: 1, finished: 1 };
  expect(await page({ limit: 1 }), "page one is the newest task").toEqual({ items: [{ task: two, pendingGrant: false }], counts, nextCursor: true });
  const first = await store.page({ limit: 1 });
  expect(await page({ limit: 1, cursor: first.nextCursor! }), "page two follows the cursor").toEqual({ items: [{ task: one, pendingGrant: false }], counts, nextCursor: false });
  expect(await outcome(() => page({ limit: 0 })), "a zero page limit").toEqual(refused("invalid-record"));
  expect(await outcome(() => page({ cursor: Buffer.from(JSON.stringify({ epoch: "x", createdAt: 1, taskId: "task-1" })).toString("base64url") })),
    "a foreign cursor").toEqual(refused("invalid-record"));
  expect(await records(), "records lists both tasks").toEqual([one, two]);
  await holds("reads publish nothing");

  const temporary = "0000000000000-task-9.json.123.abcdefabcdef.tmp";
  await writeFile(join(tasks, temporary), "{}", { mode: 0o600 });
  expected[temporary] = {};
  expect((await records()).map((record) => record.taskId), "an abandoned temporary is not a record").toEqual(["task-1", "task-2"]);
  await holds("the temporary stays until recovery");
  expect(await store.removeAbandonedTemporaries(), "startup recovery").toBeUndefined();
  delete expected[temporary];
  await holds("startup recovery removes the temporary");
  const taskTwo = join(tasks, TASK_2);
  await chmod(taskTwo, 0o644);
  try {
    expect(await outcome(() => store.read("task-2")), "a task file readable by others").toEqual(refused("unsafe-state"));
  } finally { await chmod(taskTwo, 0o600); }
  const bytes = await readFile(taskTwo);
  await writeFile(taskTwo, "{");
  try {
    expect(await outcome(() => store.read("task-2")), "a malformed task file").toEqual(refused("invalid-record"));
  } finally { await writeFile(taskTwo, bytes); }
  expect(await store.read("task-2"), "read task-2").toEqual(two);
  expect((await stat(taskTwo)).mode & 0o777, "task files are private").toBe(0o600);
  await holds("the end state");
}
