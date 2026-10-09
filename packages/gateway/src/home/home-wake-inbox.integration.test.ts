import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, afterEach, describe, expect, it, vi } from "vitest";
import { freezeHomeLedgerWriter } from "../../test-support/home-ledger-crash-frozen-owner.js";
import { EPISODIC_DEFAULTS, EpisodicMemoryError } from "../episodic/episodic-contract.js";
import { makeContextDeliveryReceipt } from "../sessions/context-delivery-receipts.js";
import { makeInvocationReceipt } from "../sessions/invocation-receipts.js";
import { TronWorkspace } from "../workspace/tron-workspace.js";
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
    sessionId: null, operationId: null, stopIntent: null, spend: null, reportRefs: null, terminalEvidence: null, wake: null } as HomeTaskRecord;
  await store.put(task, null);
  const { WakeInboxOwner } = await import("./home-wake-inbox.js");
  const pushes: unknown[] = []; const entries: any[] = [];
  const options = { notify: async (input: unknown) => { pushes.push(input); return "queued"; },
    result: async () => ({ task: await store.read("task"), text: "immutable evidence" }),
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
        await f.owner.admit(f.route, "activation", async message => { await f.append(message); throw new Error("frozen owner"); }, async () => ({ signal: new AbortController().signal, tokens: 128000, freshTokens: 128000, bytes: 1000000, entries: 1000 })).catch(() => {});
      } else {
        await f.owner.admit(f.route, "activation", f.append, async () => ({ signal: new AbortController().signal, tokens: 128000, freshTokens: 128000, bytes: 1000000, entries: 1000 })).catch(() => {});
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
    await recovered.admit(f.route, "next-activation", f.append, async () => ({ signal: new AbortController().signal, tokens: 128000, freshTokens: 128000, bytes: 1000000, entries: 1000 }));
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
    await f.owner.admit(f.route, "activation", f.append, async () => ({ signal: new AbortController().signal, tokens: 128000, freshTokens: 128000, bytes: 1000000, entries: 1000 }));
    f.receipt();
    if (mode === "missing") f.entries.shift();
    if (mode === "missing-attribution") f.entries.splice(1, 1);
    if (mode === "malformed") f.entries.at(-1).data = { receiptKind: "terminal", operationId: "activation" };
    if (mode === "duplicate") f.entries.push({ ...f.entries[0], id: "duplicate-message" });
    if (mode === "contradictory") f.entries[0].details.resultRefs = [{ resultId: "forged" }];
    await f.owner.settle(f.route, "activation");
    expect((await f.store.read("task"))?.wake?.state).toBe("outcome-unknown");
  });

  it("settles a delivery whose proof cannot be read as outcome-unknown without failing the activation", async () => {
    const f = await fixture();
    await f.owner.admit(f.route, "activation", f.append, async () => ({ signal: new AbortController().signal, tokens: 128000, freshTokens: 128000, bytes: 1000000, entries: 1000 }));
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
    await f.owner.admit(f.route, "activation", f.append, async () => ({ signal: new AbortController().signal, tokens: 128000, freshTokens: 128000, bytes: 1000000, entries: 1000 }));
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
    await second.owner.admit(second.route, "activation", second.append, async () => ({ signal: new AbortController().signal, tokens: 128000, freshTokens: 128000, bytes: 1000000, entries: 1000 }));
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
    await expect(f.owner.admit(f.route, "activation", f.append, async () => ({ signal: controller.signal, tokens: 128000, freshTokens: 128000, bytes: 1000000, entries: 1000 })))
      .rejects.toThrow(/Stop before append/);
    expect(f.entries).toHaveLength(0);
    expect((await f.store.read("task"))?.wake).toMatchObject({ state: "pending", delivery: null });
    vi.restoreAllMocks();
    await f.owner.admit(f.route, "next-activation", f.append, async () => ({ signal: new AbortController().signal, tokens: 128000, freshTokens: 128000, bytes: 1000000, entries: 1000 }));
    expect(f.entries.filter(entry => entry.type === "custom_message")).toHaveLength(1);
  });

  it("waits while disabled, blocks replacement and refuses stale-route acknowledgement", async () => {
    const f = await fixture();
    await f.owner.admit({ ...f.route, enabled: false }, "disabled", f.append, async () => ({ signal: new AbortController().signal, tokens: 128000, freshTokens: 128000, bytes: 1000000, entries: 1000 }));
    expect(f.entries).toHaveLength(0);
    await f.owner.admit({ ...f.route, routeGeneration: 2 }, "replacement", f.append, async () => ({ signal: new AbortController().signal, tokens: 128000, freshTokens: 128000, bytes: 1000000, entries: 1000 }));
    expect((await f.store.read("task"))?.wake?.state).toBe("blocked");
    expect(f.entries).toHaveLength(0);
    await f.owner.redeliver("task", { ...f.route, routeGeneration: 2 });
    await f.owner.admit({ ...f.route, routeGeneration: 2 }, "activation", f.append, async () => ({ signal: new AbortController().signal, tokens: 128000, freshTokens: 128000, bytes: 1000000, entries: 1000 })); f.receipt();
    await expect(f.owner.settle(f.route, "activation")).rejects.toThrow(/route/i);
    await f.owner.settle({ ...f.route, routeGeneration: 2 }, "activation");
    expect((await f.store.read("task"))?.wake?.state).toBe("acknowledged");
  });
});
