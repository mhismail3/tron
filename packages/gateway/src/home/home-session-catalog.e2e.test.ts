import { join } from "node:path";
import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it, vi } from "vitest";
import { CommandReceiptStore } from "../transport/command-receipts.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "../transport/gateway-service.js";
import { UploadStore } from "../machine/upload-store.js";
import { waitFor } from "../../test-support/wait-for.js";
import { disposeFixtures, fixture } from "../../test-support/home-task-fixture.js";

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
  }, 30_000);
});
