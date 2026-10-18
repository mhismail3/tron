import { join } from "node:path";
import { mkdir, writeFile } from "node:fs/promises";
import { setHomeMemoryModels } from "../../test-support/settings-dependencies.js";
import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { afterAll, afterEach, describe, expect, it, vi } from "vitest";
import { CommandReceiptStore } from "../transport/command-receipts.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "../transport/gateway-service.js";
import { UploadStore } from "../machine/upload-store.js";
import { waitFor } from "../../test-support/wait-for.js";
import { dispatch, disposeFixtures, fixture, reportCall } from "../../test-support/home-task-fixture.js";

afterEach(disposeFixtures);

const evidence: Array<Record<string, unknown>> = [];
afterAll(async () => {
  const directory = join(process.cwd(), "test-results", "home-session-catalog");
  await mkdir(directory, { recursive: true });
  await writeFile(join(directory, "report.json"), JSON.stringify(evidence, null, 2) + "\n");
});

describe("Home chapters in the dashboard session list", () => {
  it("omits the current and sealed Home chapters from session.list, keeps catalog membership, and still opens Home by id", async () => {
    const f = await fixture();
    const owner = f.registry.homeOwner();
    const model = f.faux.getModel();
    await setHomeMemoryModels(f.registry, [{ provider: model.provider, id: model.id }]);
    const predecessor = f.home.sessionId;
    const home = await f.registry.acquire(predecessor);
    f.faux.setResponses([fauxAssistantMessage("Initial Home conversation")]);
    await home.prompt("Start Home");
    await waitFor(() => home.snapshot().configurationBlocker === null, "initial Home terminal");
    const ordinary = await f.registry.create(f.cwd);
    f.faux.setResponses([fauxAssistantMessage("Ordinary reply")]);
    await ordinary.prompt("hello");
    await waitFor(() => ordinary.snapshot().configurationBlocker === null, "ordinary terminal");
    // Titles are presentation only, including a title identical to Home's role.
    await ordinary.rename("Home");
    await home.rename("An ordinary-looking chapter");

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
    evidence.push({ case: "chapter-membership-not-title", predecessor, successor: accepted.sessionId,
      ordinary: ordinary.id, dashboardIDs: await clientRows() });
  }, 30_000);

  it("marks Home task workers on their catalog rows and never unread, while a maintainer's own session completes unread (#973, #1003)", async () => {
    const f = await fixture();
    const ordinary = await f.registry.create(f.cwd);
    f.faux.setResponses([fauxAssistantMessage("Ordinary reply")]);
    await ordinary.prompt("hello");
    await waitFor(() => ordinary.snapshot().configurationBlocker === null, "ordinary terminal");
    // A worker ends through its `report` tool call, never a final assistant reply.
    f.faux.setResponses([fauxAssistantMessage([reportCall()], { stopReason: "toolUse" })]);
    const task = await (await dispatch(f, "worker-row")).completion;
    expect(task.lifecycle).toBe("terminal");
    const worker = task.sessionId!;
    await ordinary.rename("Home");
    await (await f.registry.acquire(worker)).rename("Ordinary-looking session");

    const rows = async (registry = f.registry) => {
      const service = new GatewayService({ config: { tronHome: f.tronHome }, sessions: registry, home: registry.homeOwner(),
        uploads: new UploadStore(join(f.root, "worker-uploads"), 1024),
        receipts: new CommandReceiptStore(join(f.root, "worker-receipts")) } as unknown as GatewayServiceDependencies);
      const client = { id: "worker-client", identity: "device:worker-test", isLocal: true, isSubscribed: () => true, isRevoked: () => false } as unknown as ClientContext;
      type Row = { id: string; name?: string; homeTaskId?: string; isUnread?: boolean; completionRevision?: number };
      const listed: Row[] = [];
      let cursor: string | undefined;
      let pages = 0;
      do {
        const page = await service.invoke(client, "session.list", { scope: "user", limit: 1, ...(cursor ? { cursor } : {}) }) as
          { sessions: Row[]; nextCursor: string | null };
        listed.push(...page.sessions);
        cursor = page.nextCursor ?? undefined;
        expect(++pages).toBeLessThan(10);
      } while (cursor);
      expect(pages).toBeGreaterThan(1);
      const status = await service.invoke(client, "home.status", {}) as { waitingForUser?: boolean };
      return { byId: new Map(listed.map(row => [row.id, row])), status, pages };
    };
    // The settled worker records its completion read; the maintainer's own
    // chat, finished with nobody watching, is unread.
    await waitFor(async () => ((await rows()).byId.get(worker)?.completionRevision ?? 0) >= 1, "settled worker records its completion");
    const live = await rows();
    expect(live.byId.get(worker)).toMatchObject({ name: "Ordinary-looking session", homeTaskId: "worker-row", isUnread: false });
    expect(live.byId.get(ordinary.id)).toMatchObject({ name: "Home", isUnread: true });
    expect(live.byId.get(ordinary.id)?.homeTaskId).toBeUndefined();
    expect(live.status.waitingForUser).toBe(false);

    // A resumed worker reuses its session and settles read again.
    f.faux.setResponses([fauxAssistantMessage([reportCall("report-two")], { stopReason: "toolUse" })]);
    const resumed = await f.registry.homeOwner().taskTool(f.home.sessionId, { action: "resume", taskId: task.taskId, operationId: task.operationId }) as
      { taskId: string; sessionId: string };
    expect(resumed.sessionId).toBe(worker);
    await waitFor(async () => (await f.registry.homeOwner().taskStatus(resumed.taskId)).lifecycle === "terminal", "resumed worker settles");
    await waitFor(async () => ((await rows()).byId.get(worker)?.completionRevision ?? 0) >= 2, "resumed worker records its completion");
    expect((await rows()).byId.get(worker)).toMatchObject({ homeTaskId: "worker-row", isUnread: false });

    // Unread left by an earlier build (a worker completion admitted unread) is
    // acknowledged when startup recovery seeds the worker index.
    const attention = (f.registry as unknown as { attention: {
      complete(id: string, completion: string, observed: boolean): Promise<{ projection: { isUnread: boolean } }>;
    } }).attention;
    expect((await attention.complete(worker, "legacy-unread-completion", false)).projection.isUnread).toBe(true);
    const cold = await f.restart();
    await waitFor(async () => (await rows(cold)).byId.get(worker)?.isUnread === false, "startup seeding acknowledges the legacy unread worker");
    const recovered = await rows(cold);
    expect(recovered.byId.get(worker)).toMatchObject({ homeTaskId: "worker-row", isUnread: false });
    expect(recovered.byId.get(ordinary.id)).toMatchObject({ isUnread: true });
    expect(recovered.byId.get(ordinary.id)?.homeTaskId).toBeUndefined();
    // A user's read acknowledges only that exact completion; it changes neither
    // catalog membership nor the worker metadata after cold recovery.
    const completionRevision = recovered.byId.get(ordinary.id)!.completionRevision!;
    await cold.setAttention(ordinary.id, false, completionRevision);
    const read = await rows(cold);
    expect(read.byId.get(ordinary.id)).toMatchObject({ name: "Home", isUnread: false });
    expect(read.byId.get(worker)).toMatchObject({ name: "Ordinary-looking session", homeTaskId: "worker-row" });
    evidence.push({ case: "worker-and-ordinary-paged-cold-catalog", pages: read.pages, rows: [...read.byId.values()] });
  }, 30_000);
});
