import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import fc from "fast-check";
import { afterAll, afterEach, describe, expect, it, vi } from "vitest";
import { freezeHomeLedgerWriter } from "../../../test-support/home-ledger-crash-frozen-owner.js";
import { EPISODIC_DEFAULTS } from "../../episodic/episodic-contract.js";
import { EpisodicMemoryError } from "../../errors.js";
import { makeContextDeliveryReceipt } from "../../kernel/receipts/context-delivery-receipts.js";
import { makeInvocationReceipt } from "../../kernel/receipts/invocation-receipts.js";
import { TronWorkspace } from "../../workspace/tron-workspace.js";
import { HomeTaskStore, taskIntentDigest, type HomeTaskRecord } from "./home-task-store.js";

const roots: string[] = [];
const workspaces: TronWorkspace[] = [];
const artifact: unknown[] = [];
afterEach(async () => { vi.restoreAllMocks(); for (const workspace of workspaces.splice(0)) await workspace.dispose(); for (const root of roots.splice(0)) await rm(root, { recursive: true, force: true }); });
afterAll(async () => { if (process.env.HOME_WAKE_REPORT) await writeFile(process.env.HOME_WAKE_REPORT, JSON.stringify({ cases: artifact }, null, 2)); });

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "tron-wake-cut-")); roots.push(root);
  const home = join(root, "tron");
  await mkdir(join(home, "gateway"), { recursive: true, mode: 0o700 });
  const workspace = new TronWorkspace(home); workspaces.push(workspace); await workspace.initialize();
  const store = new HomeTaskStore(home, workspace); await store.initialize();
  const intent = { text: "finite" };
  const task = { version: 1, taskId: "task", revision: 1, homeId: "home", generation: 1, routeGeneration: 1,
    intent, intentDigest: taskIntentDigest(intent.text), target: root,
    grantRef: null, scopeRef: null, lifecycle: "pending",
    sessionId: null, operationId: null, stopIntent: null, spend: null, reportRef: null, terminalEvidence: null, wake: null } as HomeTaskRecord;
  await store.put(task, null);
  const { WakeInboxOwner } = await import("./home-wake-inbox.js");
  const pushes: unknown[] = []; const entries: any[] = [];
  // Home is not wake-eligible in these fixtures: each settled result keeps its task-finished push.
  const options = { notify: async (input: unknown) => { pushes.push(input); return "queued"; }, pushSession: () => "chapter-one", wakeAvailable: async () => false, wake: () => {},
    result: async () => ({ task: await store.read("task"), text: "immutable evidence", subagents: { started: 0, stoppedAtEnd: 0 } }),
    evidence: async () => entries };
  const owner = new WakeInboxOwner(store, options);
  const terminal = { ...task, revision: 2, lifecycle: "terminal", terminalEvidence: { outcome: "unknown", sessionId: null, entryIds: [], reason: "no-report" } } as HomeTaskRecord;
  terminal.wake = owner.event(terminal);
  await store.put(terminal, 1);
  const route = { homeId: "home", routeGeneration: 1, generation: 1, enabled: true, sessionId: "chapter-one" };
  const append = async (message: any) => {
    if (message.customType === "tron.home-task-pending.v1") return;
    entries.push({ type: "custom_message", id: "work-entry", sessionId: route.sessionId, customType: "tron.home-task-result.v1", details: message.details, content: message.content });
    entries.push({ type: "custom", id: "attribution-entry", sessionId: route.sessionId, customType: "tron.context-delivery.v4", data: makeContextDeliveryReceipt("work-entry", "stored", { source: "gateway:home-task", owner: { id: "task", title: "Home task", source: "gateway:home-task" } }) });
  };
  const receipt = () => entries.push({ type: "custom", id: "terminal-entry", sessionId: route.sessionId, customType: "tron.chat-invocation.v1", data: makeInvocationReceipt({ version: 1, receiptId: "terminal:invocation", invocationId: "invocation", source: "plain", sequence: 5, createdAt: "2026-10-07T00:00:00.000Z", receiptKind: "terminal", operationId: "activation", sessionId: route.sessionId, lifecycle: "completed" }) });
  return { store, owner, options, route, append, receipt, entries, pushes, reopen: () => new WakeInboxOwner(new HomeTaskStore(home, workspace), options) };
}

describe("Wake inbox frozen-owner crash cuts", () => {
  it("never replays a decided advisory push after a crash before enqueue or after the notification dedupe horizon", async () => {
    const f = await fixture();
    const update = (f.store as any).updateWake.bind(f.store);
    vi.spyOn(f.store as any, "updateWake").mockImplementation(freezeHomeLedgerWriter(update,
      (result: HomeTaskRecord) => result.wake!.push === "decided"));
    await f.owner.publish("task").catch(() => {});
    expect(f.pushes).toHaveLength(0);
    vi.restoreAllMocks();
    await f.reopen().recover(f.route);
    expect(f.pushes).toHaveLength(0);
    const second = await fixture();
    await second.owner.publish("task");
    expect(second.pushes).toHaveLength(1);
    // This notification port retains NO receipts at all: stronger than expiry
    // after 24h. Only the task's durable terminal decision prevents replay.
    await second.reopen().recover(second.route);
    expect(second.pushes).toHaveLength(1);
  });
  it.each(["terminal", "push", "claimed", "admitted", "canonical", "terminal-receipt", "terminal-state", "acknowledged"])("never replays effects across the %s cut", async cut => {
    const f = await fixture();
    if (cut !== "terminal") await f.owner.publish("task");
    if (!["terminal", "push"].includes(cut)) {
      // A frozen owner cannot execute after the cut. The fresh owner sees only
      // durable store state and the canonical cut, as after process loss.
      const update = (f.store as any).updateWake.bind(f.store);
      vi.spyOn(f.store as any, "updateWake").mockImplementation(freezeHomeLedgerWriter(update,
        (result: HomeTaskRecord) => result.wake!.state === (cut === "terminal-state" ? "terminal" : cut)));
      if (cut === "canonical") {
        vi.restoreAllMocks();
        await f.owner.admit(f.route, "activation", "user", async message => { await f.append(message); throw new Error("frozen owner"); }, async () => ({ signal: new AbortController().signal, tokens: 128000, freshTokens: 128000, bytes: 1000000, entries: 1000 })).catch(() => {});
      } else {
        await f.owner.admit(f.route, "activation", "user", f.append, async () => ({ signal: new AbortController().signal, tokens: 128000, freshTokens: 128000, bytes: 1000000, entries: 1000 })).catch(() => {});
      }
      if (["terminal-receipt", "terminal-state", "acknowledged"].includes(cut)) {
        f.receipt(); if (cut !== "terminal-receipt") await f.owner.settle(f.route, "activation").catch(() => {});
      }
    }
    vi.restoreAllMocks();
    const recovered = f.reopen();
    await recovered.recover(f.route);
    const task = (await f.store.read("task"))!;
    const before = f.entries.length;
    await recovered.admit(f.route, "next-activation", "user", f.append, async () => ({ signal: new AbortController().signal, tokens: 128000, freshTokens: 128000, bytes: 1000000, entries: 1000 }));
    if (["admitted", "canonical"].includes(cut)) {
      expect(task.wake?.state).toBe("outcome-unknown");
      expect(f.entries.length).toBe(before);
    } else if (["terminal-receipt", "terminal-state", "acknowledged"].includes(cut)) {
      expect(task.wake?.state).toBe("acknowledged");
      expect(f.entries.filter(entry => entry.type === "custom_message")).toHaveLength(1);
    } else {
      expect(f.entries.filter(entry => entry.type === "custom_message")).toHaveLength(1);
    }
    expect(new Set(f.pushes.map((input: any) => input.sourceId)).size).toBe(1);
    artifact.push({ cut, recovered: task.wake, canonical: f.entries, pushes: f.pushes });
  });

  it.each(["missing", "malformed", "duplicate", "contradictory", "missing-attribution"])("never acknowledges %s canonical result evidence", async mode => {
    const f = await fixture();
    await f.owner.admit(f.route, "activation", "user", f.append, async () => ({ signal: new AbortController().signal, tokens: 128000, freshTokens: 128000, bytes: 1000000, entries: 1000 }));
    f.receipt();
    if (mode === "missing") f.entries.shift();
    if (mode === "missing-attribution") f.entries.splice(1, 1);
    if (mode === "malformed") f.entries.at(-1).data = { receiptKind: "terminal", operationId: "activation" };
    if (mode === "duplicate") f.entries.push({ ...f.entries[0], id: "duplicate-message" });
    if (mode === "contradictory") f.entries[0].details.resultRef = { resultId: "forged" };
    await f.owner.settle(f.route, "activation");
    expect((await f.store.read("task"))?.wake?.state).toBe("outcome-unknown");
  });

  it("settles a delivery whose proof cannot be read as outcome-unknown without failing the activation", async () => {
    const f = await fixture();
    await f.owner.admit(f.route, "activation", "user", f.append, async () => ({ signal: new AbortController().signal, tokens: 128000, freshTokens: 128000, bytes: 1000000, entries: 1000 }));
    f.receipt();
    vi.spyOn(f.options, "evidence").mockRejectedValueOnce(new EpisodicMemoryError("source", `Canonical session line exceeds ${EPISODIC_DEFAULTS.maxSourceLineBytes} bytes`));
    await expect(f.owner.settle(f.route, "activation")).resolves.toBeUndefined();
    expect((await f.store.read("task"))?.wake?.state).toBe("outcome-unknown");
    // A later activation recovers the rest of the namespace; the unreadable event is not replayed.
    await expect(f.reopen().recover(f.route)).resolves.toBeUndefined();
    expect((await f.store.read("task"))?.wake?.state).toBe("outcome-unknown");
    expect(f.entries.filter(entry => entry.type === "custom_message")).toHaveLength(1);
  });

  it("keeps a delivery whose proof read fails transiently admitted, so the next activation proves and acknowledges it", async () => {
    const f = await fixture();
    await f.owner.admit(f.route, "activation", "user", f.append, async () => ({ signal: new AbortController().signal, tokens: 128000, freshTokens: 128000, bytes: 1000000, entries: 1000 }));
    f.receipt();
    vi.spyOn(f.options, "evidence").mockRejectedValueOnce(new Error("EIO while syncing the chapter"));
    await expect(f.owner.settle(f.route, "activation")).resolves.toBeUndefined();
    expect((await f.store.read("task"))?.wake?.state).toBe("admitted");
    vi.restoreAllMocks();
    await f.reopen().recover(f.route);
    expect((await f.store.read("task"))?.wake?.state).toBe("acknowledged");
  });

  it("settles an admitted delivery whose proof is unreadable during recovery as outcome-unknown without refusing the activation", async () => {
    const second = await fixture();
    await second.owner.admit(second.route, "activation", "user", second.append, async () => ({ signal: new AbortController().signal, tokens: 128000, freshTokens: 128000, bytes: 1000000, entries: 1000 }));
    second.receipt();
    vi.spyOn(second.options, "evidence").mockRejectedValueOnce(new EpisodicMemoryError("source", "Canonical session has an incomplete tail"));
    await expect(second.reopen().recover(second.route)).resolves.toBeUndefined();
    expect((await second.store.read("task"))?.wake?.state).toBe("outcome-unknown");
    // An uncertain admitted effect is never retargeted into a pending delivery.
    await expect(second.reopen().redeliver("task", { ...second.route, routeGeneration: 2 })).rejects.toMatchObject({ code: "conflict" });
    expect((await second.store.read("task"))?.wake?.state).toBe("outcome-unknown");
  });

  it("returns a delivery aborted before its canonical append to pending, with no delivery and no append", async () => {
    const f = await fixture();
    const controller = new AbortController();
    const update = (f.store as any).updateWake.bind(f.store);
    vi.spyOn(f.store as any, "updateWake").mockImplementation(async (id: string, change: (wake: any) => any) => {
      const result = await update(id, change);
      if (result.wake?.state === "admitted") controller.abort(new Error("Stop before append"));
      return result;
    });
    await expect(f.owner.admit(f.route, "activation", "user", f.append, async () => ({ signal: controller.signal, tokens: 128000, freshTokens: 128000, bytes: 1000000, entries: 1000 })))
      .rejects.toThrow(/Stop before append/);
    expect(f.entries).toHaveLength(0);
    expect((await f.store.read("task"))?.wake).toMatchObject({ state: "pending", delivery: null });
    vi.restoreAllMocks();
    await f.owner.admit(f.route, "next-activation", "user", f.append, async () => ({ signal: new AbortController().signal, tokens: 128000, freshTokens: 128000, bytes: 1000000, entries: 1000 }));
    expect(f.entries.filter(entry => entry.type === "custom_message")).toHaveLength(1);
  });

  it("waits while disabled, blocks replacement and refuses stale-route acknowledgement", async () => {
    const f = await fixture();
    await f.owner.admit({ ...f.route, enabled: false }, "disabled", "user", f.append, async () => ({ signal: new AbortController().signal, tokens: 128000, freshTokens: 128000, bytes: 1000000, entries: 1000 }));
    expect(f.entries).toHaveLength(0);
    await f.owner.admit({ ...f.route, routeGeneration: 2 }, "replacement", "user", f.append, async () => ({ signal: new AbortController().signal, tokens: 128000, freshTokens: 128000, bytes: 1000000, entries: 1000 }));
    expect((await f.store.read("task"))?.wake?.state).toBe("blocked");
    expect(f.entries).toHaveLength(0);
    await f.owner.redeliver("task", { ...f.route, routeGeneration: 2 });
    await f.owner.admit({ ...f.route, routeGeneration: 2 }, "activation", "user", f.append, async () => ({ signal: new AbortController().signal, tokens: 128000, freshTokens: 128000, bytes: 1000000, entries: 1000 })); f.receipt();
    await expect(f.owner.settle(f.route, "activation")).rejects.toThrow(/route/i);
    await f.owner.settle({ ...f.route, routeGeneration: 2 }, "activation");
    expect((await f.store.read("task"))?.wake?.state).toBe("acknowledged");
  });
});

// #1995: a pass after the first reads only the tasks its predecessor found
// actionable and those written since. A fresh owner (no proof, one full pass) is
// the oracle: whatever writes ran between passes, both see the same results.
describe("Wake inbox quiet proof", () => {
  async function inbox() {
    const root = await mkdtemp(join(tmpdir(), "tron-wake-proof-")); roots.push(root);
    const home = join(root, "tron");
    await mkdir(join(home, "gateway"), { recursive: true, mode: 0o700 });
    const workspace = new TronWorkspace(home); workspaces.push(workspace); await workspace.initialize();
    const store = new HomeTaskStore(home, workspace); await store.initialize();
    const { WakeInboxOwner } = await import("./home-wake-inbox.js");
    const authority = await store.authorization.load();
    await store.authorization.save({ ...authority, scopes: [{ id: "scope", kind: "all-trusted-projects", active: true, restoreEpoch: "epoch", createdAt: 1 }] });
    const options = { notify: async () => "queued", pushSession: () => "chapter", wakeAvailable: async () => false, wake: () => {},
      result: async () => ({ task: undefined, text: "", subagents: { started: 0, stoppedAtEnd: 0 } }), evidence: async () => [] };
    const owner = () => new WakeInboxOwner(store, options);
    const record = (taskId: string): HomeTaskRecord => ({ version: 1, taskId, revision: 1, homeId: "home", generation: 1, routeGeneration: 1,
      intent: { text: taskId }, intentDigest: taskIntentDigest(taskId), target: root, grantRef: null, scopeRef: null, lifecycle: "pending",
      sessionId: null, operationId: null, stopIntent: null, spend: null, reportRef: null, terminalEvidence: null, wake: null } as HomeTaskRecord);
    const at = (minute: number) => new Date(Date.UTC(2026, 0, 1, 0, minute)).toISOString();
    const checkin = (taskId: string, id: string, attention: "none" | "requested") => ({ id, taskId, sessionId: `session-${taskId}`, operationId: `operation-${taskId}`,
      at: at(id.length), attention, step: "Step", done: "Done", next: "Next", ...(attention === "requested" ? { needsAttention: true, blocker: "Blocked" } : {}) });
    const pending = async (reader: InstanceType<typeof WakeInboxOwner>) => (await reader.pendingTasks("home")).map(task => task.wake!.eventId);
    // Each command is one store publication that an owner would make.
    const commands = {
      create: async (taskId: string) => { if (!await store.read(taskId)) await store.put(record(taskId), null); },
      activate: async (taskId: string) => {
        const current = await store.read(taskId);
        if (current?.lifecycle === "pending") await store.put({ ...current, revision: current.revision + 1, lifecycle: "active", scopeRef: "scope", sessionId: `session-${taskId}`, operationId: `operation-${taskId}` }, current.revision);
      },
      checkin: async (taskId: string) => {
        const current = await store.read(taskId);
        if (current?.lifecycle === "active") await store.update(taskId, task => ({ ...task, checkins: [...task.checkins ?? [], checkin(taskId, `c${task.revision}`, "none")].slice(-5) }));
      },
      attention: async (taskId: string) => {
        const current = await store.read(taskId);
        if (current?.lifecycle !== "active" || current.attention) return;
        const accepted = checkin(taskId, `a${current.revision}`, "requested");
        await store.update(taskId, task => ({ ...task, lastAttentionAt: accepted.at, attention: { checkin: accepted, wake: owner().attentionEvent(task, accepted as never) } }));
      },
      settle: async (taskId: string) => {
        const current = await store.read(taskId);
        if (!current || current.lifecycle === "terminal") return;
        const terminal = { ...current, revision: current.revision + 1, lifecycle: "terminal", terminalEvidence: { outcome: "unknown", sessionId: null, entryIds: [], reason: "no-report" } } as HomeTaskRecord;
        await store.put({ ...terminal, wake: owner().event(terminal) }, current.revision);
      },
      wake: async (taskId: string, state: "blocked" | "pending" | "acknowledged" | "outcome-unknown", attention: boolean) => {
        const current = await store.read(taskId);
        const before = attention ? current?.attention?.wake : current?.wake;
        if (!before || before.state === "acknowledged") return;
        const delivery = { sessionId: "chapter", operationId: "activation", generation: 1, routeGeneration: before.routeGeneration, messageDigest: "0".repeat(64) };
        await store.updateWake(taskId, wake => ({ ...wake, state, push: state === "outcome-unknown" ? "decided" : wake.push,
          delivery: ["blocked", "pending"].includes(state) ? null : delivery, acknowledgedAt: state === "acknowledged" ? at(59) : null }), before.eventId);
      },
    };
    return { store, owner, pending, commands };
  }

  it("yields exactly the results a full pass yields after any sequence of task writes", async () => {
    const ids = ["t0", "t1", "t2", "t3"];
    const id = fc.constantFrom(...ids);
    const command = fc.oneof(
      fc.record({ kind: fc.constantFrom("create", "activate", "checkin", "attention", "settle"), taskId: id }),
      fc.record({ kind: fc.constant("wake"), taskId: id, state: fc.constantFrom("blocked", "pending", "acknowledged", "outcome-unknown"), attention: fc.boolean() }),
      fc.record({ kind: fc.constant("compare") }));
    let compared = 0;
    await fc.assert(fc.asyncProperty(fc.array(command, { minLength: 4, maxLength: 24 }), async trace => {
      const f = await inbox();
      const incremental = f.owner();
      for (const step of [...trace, { kind: "compare" } as const]) {
        if (step.kind === "compare") { expect(await f.pending(incremental)).toEqual(await f.pending(f.owner())); compared++; }
        else if (step.kind === "wake") await f.commands.wake(step.taskId, step.state, step.attention);
        else await f.commands[step.kind](step.taskId);
      }
    }), { numRuns: 25, seed: 1995 });
    expect(compared).toBeGreaterThan(25);
  }, 120_000);

  it("never misses a result settled while a pass is reading", async () => {
    const f = await inbox();
    for (const taskId of ["early", "late"]) await f.commands.create(taskId);
    await f.commands.settle("early");
    const reader = f.owner();
    expect(await f.pending(reader)).toHaveLength(1);
    await f.commands.wake("early", "acknowledged", false);
    // A result settles after this pass began and after its own records were read.
    const read = f.store.read.bind(f.store);
    let settled = false;
    vi.spyOn(f.store, "read").mockImplementation(async taskId => {
      const task = await read(taskId);
      if (!settled) { settled = true; await f.commands.settle("late"); }
      return task;
    });
    expect(await f.pending(reader)).toEqual([]);
    vi.restoreAllMocks();
    expect(await f.pending(reader)).toEqual(await f.pending(f.owner()));
    expect(await f.pending(reader)).toHaveLength(1);
  });

  it("takes a full pass once the store's journal no longer names every write since the last one", async () => {
    const f = await inbox();
    for (const taskId of ["busy", "result"]) await f.commands.create(taskId);
    await f.commands.activate("busy");
    const reader = f.owner();
    expect(await f.pending(reader)).toEqual([]);
    await f.commands.settle("result");
    for (let i = 0; i < 1_030; i++) await f.store.update("busy", task => ({ ...task, queuedAt: new Date(Date.UTC(2026, 0, 1, 0, 0, 0, i + 1)).toISOString() }));
    expect(f.store.taskWritesSince(f.store.writeCount - 1_030)).toBeUndefined();
    expect(await f.pending(reader)).toEqual(await f.pending(f.owner()));
    expect(await f.pending(reader)).toHaveLength(1);
  }, 120_000);
});
