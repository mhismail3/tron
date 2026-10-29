import { mkdir, mkdtemp, readFile, readdir, realpath, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall, type TranscriptContext } from "@earendil-works/pi-ai";
import { afterEach, expect, it } from "vitest";
import { createTestRegistry, displayOwnerOf } from "../../../test-support/gateway-registry.js";
import { TrustService } from "../../kernel/resources/trust-service.js";
import { GatewayService, type GatewayServiceDependencies } from "../../transport/gateway-service.js";
import { CommandReceiptStore } from "../../transport/command-receipts.js";
import { waitFor } from "../../../test-support/wait-for.js";

const cleanup: Array<() => Promise<void>> = [];
afterEach(async () => { for (const close of cleanup.splice(0).reverse()) await close(); });
async function fixture(existingRoot?: string) {
  const root = existingRoot ?? await realpath(await mkdtemp(join(tmpdir(), "tron-app-display-"))), home = join(root, "tron"), agentDir = join(root, "agent");
  if (!existingRoot) cleanup.push(() => rm(root, { recursive: true, force: true })); await mkdir(agentDir, { recursive: true });
  await mkdir(join(home, "workspace/files/apps"), { recursive: true, mode: 0o700 });
  const trust = new TrustService(agentDir), faux = fauxProvider({ provider: "folder-display", tokensPerSecond: 100_000 });
  const registry = await createTestRegistry({ agentDir, tronHome: home, trust,
    modelRuntimeFactory: async () => { const runtime = await ModelRuntime.create({ authPath: join(agentDir, "auth.json"), modelsPath: null, refreshOnCreate: false, allowModelNetwork: false }); runtime.registerNativeProvider(faux.provider); return runtime; },
    broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {} });
  cleanup.push(() => registry.dispose()); await registry.initialize(); await registry.initializeBlobStorage();
  const service = new GatewayService({ display: displayOwnerOf(registry), sessions: registry, modules: registry.moduleHost,
    config: { machineId: "machine", machineGroupID: "group", machineName: "Mac", tronHome: home, agentDir }, receipts: new CommandReceiptStore(home), broadcast: () => {},
    globalProviderResources: { withStableSnapshot: async (run: () => Promise<unknown>) => run(), requestReload: () => {} },
  } as unknown as GatewayServiceDependencies);
  const rpc = (method: string, params: Record<string, unknown> = {}) => service.invoke({ id: "phone", identity: "device:fixture", isLocal: false } as never, method, params) as Promise<any>;
  const display = async (cwd: string, path: string, title = "Fixture") => {
    await trust.set(cwd, true);
    let result: any;
    faux.setResponses([fauxAssistantMessage([fauxToolCall("display", { title, altText: "Fixture artifact", source: { kind: "path", path } }, { id: "show-file" })], { stopReason: "toolUse" }),
      (context: TranscriptContext) => { result = context.messages.findLast(message => message.role === "toolResult"); return fauxAssistantMessage("Done"); }]);
    const slot = await registry.create(cwd), model = faux.getModel(); await slot.setModel(model.provider, model.id); await slot.prompt("Display the requested fixture.");
    await waitFor(() => result && !slot.isBusy ? true : undefined, "display turn settles");
    return { result, slot };
  };
  return { root, home, registry, rpc, display, apps: join(home, "workspace/files/apps") };
}

it("materializes admitted Markdown dependencies once across chats and keeps both chat snapshots and copied files independent of the producer", async () => {
  const f = await fixture(), cwd = join(f.root, "project"); await mkdir(join(cwd, "assets"), { recursive: true });
  const document = "# Report\n\n![Logo](assets/logo.png)\n", image = Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]), Buffer.from("fixture")]);
  await writeFile(join(cwd, "report.md"), document); await writeFile(join(cwd, "assets/logo.png"), image);
  const first = await f.display(cwd, "report.md", "First title"), second = await f.display(cwd, "report.md", "Another title");
  expect(first.result.isError).not.toBe(true); expect(second.result.isError).not.toBe(true);
  const rows = (await f.rpc("apps.catalog")).rows; expect(rows).toHaveLength(1);
  expect(rows[0].id).toMatch(/^display-[a-f0-9]{64}$/); expect(rows[0].title).toBe("First title");
  expect(first.result.details.display.app).toEqual({ id: rows[0].id, contentRevision: rows[0].contentRevision });
  expect(second.result.details.display.app).toEqual(first.result.details.display.app);
  const folder = join(f.apps, rows[0].id), manifest = JSON.parse(await readFile(join(folder, "app.json"), "utf8"));
  expect(await readFile(join(folder, manifest.entry), "utf8")).toBe(document); expect(await readFile(join(folder, "assets/logo.png"))).toEqual(image);
  await writeFile(join(cwd, "report.md"), "changed producer"); await writeFile(join(cwd, "assets/logo.png"), "changed producer");
  expect(await readFile(join(folder, manifest.entry), "utf8")).toBe(document); expect(await readFile(join(folder, "assets/logo.png"))).toEqual(image);
  const lease = await displayOwnerOf(f.registry).acquireArtifact(first.slot.id, first.result.details.display.artifact.id);
  try { const chunks = []; for await (const chunk of lease.stream) chunks.push(Buffer.from(chunk)); expect(Buffer.concat(chunks).toString()).toBe(document); } finally { await lease.release(); }
});

it("reuses an explicit entry without replacing metadata and refuses a displayed sibling that is not its declared entry", async () => {
  const f = await fixture(), folder = join(f.apps, "explicit"); await mkdir(folder, { recursive: true });
  await writeFile(join(folder, "app.json"), JSON.stringify({ title: "Owned title", entry: "note.txt" }));
  await writeFile(join(folder, "note.txt"), "correct"); await writeFile(join(folder, "sibling.txt"), "other");
  const first = await f.display(folder, "note.txt", "Do not rename"); expect(first.result.isError).not.toBe(true);
  expect(first.result.details.display.app.id).toBe("explicit"); expect((await f.rpc("apps.catalog")).rows).toHaveLength(1);
  const refused = await f.display(folder, "sibling.txt"); expect(refused.result.isError).toBe(true);
  expect((await f.rpc("apps.catalog")).rows[0].title).toBe("Owned title"); expect(await readdir(f.apps)).toEqual(["explicit"]);
});

it("never overwrites an externally edited digest folder or resurrects a deleted entry when canonical history reloads", async () => {
  const f = await fixture(), cwd = join(f.root, "project"); await mkdir(cwd); await writeFile(join(cwd, "note.txt"), "original");
  const first = await f.display(cwd, "note.txt"), row = (await f.rpc("apps.catalog")).rows[0];
  expect(row).toBeDefined(); const folder = join(f.apps, row.id), manifest = JSON.parse(await readFile(join(folder, "app.json"), "utf8"));
  await writeFile(join(folder, manifest.entry), "external edit");
  const refused = await f.display(cwd, "note.txt"); expect(refused.result.isError).toBe(true); expect(await readFile(join(folder, manifest.entry), "utf8")).toBe("external edit");
  await rm(folder, { recursive: true }); await f.registry.dispose(); const restarted = await fixture(f.root); await restarted.registry.acquire(first.slot.id);
  expect((await restarted.rpc("apps.catalog")).rows).toHaveLength(0); expect(await readdir(f.apps)).toEqual([]);
});
