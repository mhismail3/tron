import { join } from "node:path";
import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it, vi } from "vitest";
import { CommandReceiptStore } from "../transport/command-receipts.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "../transport/gateway-service.js";
import { UploadStore } from "../machine/upload-store.js";
import { waitFor } from "../../test-support/wait-for.js";
import { dispatch, disposeFixtures, fixture, reportCall } from "../../test-support/home-task-fixture.js";

afterEach(disposeFixtures);

describe("Home chapters in the dashboard session list", () => {
  it("omits the current and sealed Home chapters from session.list, keeps catalog membership, and still opens Home by id", async () => {
    const f = await fixture();
    const owner = f.registry.homeOwner();
    const model = f.faux.getModel();
    await owner.configureMemory({ model: { provider: model.provider, id: model.id } });
    const predecessor = f.home.sessionId;
    const home = await f.registry.acquire(predecessor);
    f.faux.setResponses([fauxAssistantMessage("Initial Home conversation")]);
    await home.prompt("Start Home");
    await waitFor(() => home.snapshot().configurationBlocker === null, "initial Home terminal");
    const ordinary = await f.registry.create(f.cwd);
    f.faux.setResponses([fauxAssistantMessage("Ordinary reply")]);
    await ordinary.prompt("hello");
    await waitFor(() => ordinary.snapshot().configurationBlocker === null, "ordinary terminal");

    const service = new GatewayService({ config: { tronHome: f.tronHome }, sessions: f.registry, home: owner,
      uploads: new UploadStore(join(f.root, "catalog-uploads"), 1024),
      receipts: new CommandReceiptStore(join(f.root, "catalog-receipts")) } as unknown as GatewayServiceDependencies);
    const client = { id: "catalog-client", identity: "device:catalog-test", isLocal: true, isSubscribed: () => true, isRevoked: () => false } as unknown as ClientContext;
    // The dashboard's list traversal: the rows a client receives.
    const clientRows = async () => (await service.invoke(client, "session.list", { scope: "user", limit: 500 }) as { sessions: Array<{ id: string }> })
      .sessions.map(session => session.id);

    expect(await clientRows()).toEqual([ordinary.id]);
    // Membership is unchanged: search and derived reads still resolve Home's chapters.
    expect((await f.registry.list("user")).map(session => session.id)).toEqual(expect.arrayContaining([predecessor, ordinary.id]));
    expect((await f.registry.list("all")).map(session => session.id)).toEqual(expect.arrayContaining([predecessor, ordinary.id]));

    // Rollover seals the predecessor and reserves its successor without materializing it.
    const port = (owner as any).options.sessions;
    const metrics = vi.spyOn(port, "chapterMetrics").mockResolvedValue({ bytes: 25 * 1024 * 1024, entries: 10, quiescent: true });
    await owner.chapterQuiescent(predecessor);
    metrics.mockRestore();
    expect(await owner.status()).toMatchObject({ phase: "rollover-pending", openSessionId: predecessor });
    expect(await clientRows()).toEqual([ordinary.id]);

    // Materializing the successor makes it the current chapter; neither chapter reaches the dashboard.
    f.faux.setResponses([fauxAssistantMessage("Successor Home conversation")]);
    const accepted = await service.invoke(client, "home.prompt", { commandId: "successor-chapter-command", text: "Continue Home" }) as { sessionId: string };
    expect(accepted.sessionId).not.toBe(predecessor);
    const successor = await f.registry.acquire(accepted.sessionId);
    await waitFor(() => successor.snapshot().configurationBlocker === null, "successor Home terminal");
    expect(await clientRows()).toEqual([ordinary.id]);

    // Opening a chapter by id is the pinned row's and the Chapters sheet's route, so it still resolves.
    expect((await f.registry.acquire(predecessor)).id).toBe(predecessor);
    expect((await f.registry.acquire(accepted.sessionId)).id).toBe(accepted.sessionId);

    // A sealed chapter's transcript opens read-only after its runtime was evicted (#911):
    // the cold open is the Chapters sheet's route once the chapter has idled out.
    const registry = f.registry as unknown as { slots: Map<string, unknown>; retireIdleRuntime(input: unknown): Promise<boolean> };
    const sealedSlot = registry.slots.get(predecessor);
    expect(await registry.retireIdleRuntime({ sessionId: predecessor, slot: sealedSlot, reason: "idle", eligible: () => true })).toBe(true);
    expect(registry.slots.has(predecessor)).toBe(false);
    const reopened = await f.registry.acquire(predecessor);
    expect(registry.slots.get(predecessor)).toBe(reopened);
    expect(JSON.stringify(reopened.canonicalSessionEntries())).toContain("Initial Home conversation");
    // Read-only: the sealed chapter still refuses a prompt.
    await expect(reopened.prompt("write to a sealed chapter")).rejects.toThrow();
  }, 30_000);

  it("marks Home task workers on their catalog rows, unread once settled, across a cold restart (#973)", async () => {
    const f = await fixture();
    const ordinary = await f.registry.create(f.cwd);
    f.faux.setResponses([fauxAssistantMessage("Ordinary reply")]);
    await ordinary.prompt("hello");
    await waitFor(() => ordinary.snapshot().configurationBlocker === null, "ordinary terminal");
    // A worker ends through its `report` tool call, never a final assistant reply.
    f.faux.setResponses([fauxAssistantMessage([reportCall()], { stopReason: "toolUse" })]);
    const task = await (await dispatch(f, "worker-row")).completion;
    expect(task.lifecycle).toBe("terminal");

    const rows = async (registry = f.registry) => {
      const service = new GatewayService({ config: { tronHome: f.tronHome }, sessions: registry, home: registry.homeOwner(),
        uploads: new UploadStore(join(f.root, "worker-uploads"), 1024),
        receipts: new CommandReceiptStore(join(f.root, "worker-receipts")) } as unknown as GatewayServiceDependencies);
      const client = { id: "worker-client", identity: "device:worker-test", isLocal: true, isSubscribed: () => true, isRevoked: () => false } as unknown as ClientContext;
      const listed = await service.invoke(client, "session.list", { scope: "user", limit: 500 }) as { sessions: Array<{ id: string; homeTaskId?: string; isUnread?: boolean }> };
      const status = await service.invoke(client, "home.status", {}) as { waitingForUser?: boolean };
      return { byId: new Map(listed.sessions.map(row => [row.id, row])), status };
    };
    // The worker row names its task and reads unread like a finished chat; the
    // ordinary row is neither a worker nor (its reply observed by nobody) changed by this.
    await waitFor(async () => (await rows()).byId.get(task.sessionId!)?.isUnread === true, "settled worker reads unread");
    const live = await rows();
    expect(live.byId.get(task.sessionId!)).toMatchObject({ homeTaskId: "worker-row", isUnread: true });
    expect(live.byId.get(ordinary.id)?.homeTaskId).toBeUndefined();
    expect(live.status.waitingForUser).toBe(false);

    // Recovery seeds the worker index from its one pass over the ledger.
    const cold = await f.restart();
    const recovered = await rows(cold);
    expect(recovered.byId.get(task.sessionId!)).toMatchObject({ homeTaskId: "worker-row", isUnread: true });
    expect(recovered.byId.get(ordinary.id)?.homeTaskId).toBeUndefined();
  }, 30_000);
});
