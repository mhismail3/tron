import { existsSync } from "node:fs";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall } from "@earendil-works/pi-ai";
import { expect, it, vi } from "vitest";
import { createTestRegistry, displayOwnerOf, displayStoreOf } from "../../test-support/gateway-registry.js";
import type { RuntimeRegistry } from "../sessions/runtime-registry.js";
import { TrustService } from "../admin/trust-service.js";
import { waitFor } from "../../test-support/wait-for.js";

it("keeps a displayed photo viewable after source deletion and cold reopen until session deletion", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-display-lifetime-"));
  let registry: RuntimeRegistry | undefined;
  const evidence: Record<string, unknown> = {};
  try {
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const sessionDir = join(root, "sessions");
    await Promise.all([agentDir, cwd, sessionDir].map(path => mkdir(path, { recursive: true })));
    await writeFile(join(agentDir, "settings.json"), JSON.stringify({ sessionDir }));
    const image = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6sAAAAABJRU5ErkJggg==", "base64");
    const source = join(cwd, "photo.png");
    await writeFile(source, image);
    const faux = fauxProvider({ provider: "tron-display-lifetime", tokensPerSecond: 10_000 });
    faux.setResponses([
      fauxAssistantMessage([fauxToolCall("display", {
        title: "Retained photo", altText: "A retained test photo", source: { kind: "path", path: "photo.png" },
      })], { stopReason: "toolUse" }),
      fauxAssistantMessage("done"),
    ]);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const options = {
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust,
      modelRuntimeFactory: async () => {
        const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
        runtime.registerNativeProvider(faux.provider);
        return runtime;
      },
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    };
    registry = await createTestRegistry(options);
    await registry.initialize();
    await registry.initializeBlobStorage();
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("Display the photo");
    await waitFor(() => !slot.isBusy, "display session idle");
    const row = slot.snapshot().transcript.find(item => item.kind === "message" && item.display?.artifact);
    if (row?.kind !== "message" || !row.display?.artifact) throw new Error("Real Pi display result missing");
    const artifactID = row.display.artifact.id;
    const sessionID = slot.id;
    const content = join(root, "tron", "gateway", "display-artifacts", "artifacts", artifactID, "content");
    const readPreview = async () => {
      const lease = await displayOwnerOf(registry!).acquireArtifact(sessionID, artifactID);
      try {
        const chunks: Buffer[] = [];
        for await (const chunk of lease.stream) chunks.push(Buffer.from(chunk));
        expect(Buffer.concat(chunks)).toEqual(image);
      } finally { await lease.release(); }
    };
    await readPreview();
    await rm(source);
    await expect(readFile(source)).rejects.toMatchObject({ code: "ENOENT" });
    await readPreview();
    evidence.afterSourceDeletion = "identical image bytes";
    await registry.dispose();
    registry = await createTestRegistry(options);
    await registry.initialize();
    await registry.initializeBlobStorage();
    await registry.acquire(sessionID);
    await readPreview();
    expect(await readFile(content)).toEqual(image);
    evidence.afterColdReopen = "identical image bytes";
    await registry.delete(sessionID);
    await displayOwnerOf(registry).removeArtifacts(sessionID);
    await expect(displayOwnerOf(registry).acquireArtifact(sessionID, artifactID)).rejects.toMatchObject({ code: "not_found" });
    await expect(readFile(content)).rejects.toMatchObject({ code: "ENOENT" });
    evidence.afterSessionDeletion = "unavailable; owned artifact removed";
  } finally {
    await registry?.dispose();
    await rm(root, { recursive: true, force: true });
    const output = join(process.cwd(), "test-results", "display-photo-lifetime.json");
    await mkdir(dirname(output), { recursive: true });
    await writeFile(output, `${JSON.stringify(evidence, null, 2)}\n`);
  }
}, 30_000);

async function displayedPhotoFixture() {
  const root = await mkdtemp(join(tmpdir(), "tron-display-ownership-"));
  let registry: RuntimeRegistry | undefined;
  try {
    const agentDir = join(root, "agent"), cwd = join(root, "workspace"), sessionDir = join(root, "sessions");
    await Promise.all([agentDir, cwd, sessionDir].map(path => mkdir(path, { recursive: true })));
    await writeFile(join(agentDir, "settings.json"), JSON.stringify({ sessionDir }));
    const image = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6sAAAAABJRU5ErkJggg==", "base64");
    await writeFile(join(cwd, "photo.png"), image);
    const faux = fauxProvider({ provider: "tron-display-ownership", tokensPerSecond: 10_000 });
    faux.setResponses([
      fauxAssistantMessage([fauxToolCall("display", {
        title: "Retained photo", altText: "A retained test photo", source: { kind: "path", path: "photo.png" },
      })], { stopReason: "toolUse" }), fauxAssistantMessage("done"),
    ]);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const rekeys: Array<[string, string]> = [];
    const options = {
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust,
      modelRuntimeFactory: async () => {
        const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
        runtime.registerNativeProvider(faux.provider);
        return runtime;
      },
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
      sessionRekeyed: (previousId: string, nextId: string) => { rekeys.push([previousId, nextId]); },
    };
    registry = await createTestRegistry(options);
    await registry.initialize();
    await registry.initializeBlobStorage();
    const slot = await registry.create(cwd), model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("Display the photo");
    await waitFor(() => !slot.isBusy, "display ownership session idle");
    const row = slot.snapshot().transcript.find(item => item.kind === "message" && item.display?.artifact);
    if (row?.kind !== "message" || !row.display?.artifact) throw new Error("Real Pi display result missing");
    const artifactID = row.display.artifact.id;
    return { root, options, registry, slot, image, artifactID, rekeys,
      content: join(root, "tron", "gateway", "display-artifacts", "artifacts", artifactID, "content") };
  } catch (error) {
    await registry?.dispose();
    await rm(root, { recursive: true, force: true });
    throw error;
  }
}

async function previewBytes(registry: RuntimeRegistry, sessionID: string, artifactID: string) {
  const lease = await displayOwnerOf(registry).acquireArtifact(sessionID, artifactID);
  try {
    const chunks: Buffer[] = [];
    for await (const chunk of lease.stream) chunks.push(Buffer.from(chunk));
    return Buffer.concat(chunks);
  } finally { await lease.release(); }
}

it("commits inherited display ownership before fork publication and preserves the parent on grant failure", async () => {
  const fixture = await displayedPhotoFixture();
  let registry = fixture.registry;
  const parent = fixture.slot.id;
  const assistant = fixture.slot.snapshot().transcript.findLast(item => item.kind === "message" && item.role === "assistant");
  const failure = new Error("injected display grant failure");
  const grant = vi.spyOn(displayStoreOf(registry), "grant").mockRejectedValueOnce(failure);
  try {
    if (!assistant) throw new Error("Real Pi assistant entry missing");
    await expect(fixture.slot.fork(assistant.id, "at")).rejects.toThrow(failure.message);
    expect(fixture.slot.id).toBe(parent);
    expect(fixture.rekeys).toEqual([]);
    expect(await previewBytes(registry, parent, fixture.artifactID)).toEqual(fixture.image);
    grant.mockRestore();
    const fork = await fixture.slot.fork(assistant.id, "at");
    expect(fixture.rekeys).toEqual([[parent, fork.sessionId]]);
    expect(await previewBytes(registry, fork.sessionId, fixture.artifactID)).toEqual(fixture.image);
    expect(await previewBytes(registry, parent, fixture.artifactID)).toEqual(fixture.image);
    await registry.dispose();
    registry = await createTestRegistry(fixture.options);
    await registry.initialize();
    await registry.initializeBlobStorage();
    expect(await previewBytes(registry, parent, fixture.artifactID)).toEqual(fixture.image);
    expect(await previewBytes(registry, fork.sessionId, fixture.artifactID)).toEqual(fixture.image);
  } finally {
    grant.mockRestore();
    await registry.dispose();
    await rm(fixture.root, { recursive: true, force: true });
  }
});

it("releases a display lease delivered after cancellation so session deletion reclaims its physical artifact", async () => {
  const fixture = await displayedPhotoFixture();
  const registry = fixture.registry, store = displayStoreOf(registry), sessionID = fixture.slot.id;
  const acquire = store.acquire.bind(store);
  let ready!: () => void, deliver!: () => void;
  const acquired = new Promise<void>(resolve => { ready = resolve; });
  const delivery = new Promise<void>(resolve => { deliver = resolve; });
  let lateLease: Awaited<ReturnType<typeof store.acquire>> | undefined;
  const held = vi.spyOn(store, "acquire").mockImplementation(async (...args) => {
    lateLease = await acquire(...args);
    ready();
    await delivery;
    return lateLease;
  });
  try {
    const controller = new AbortController();
    const pending = displayOwnerOf(registry).acquireArtifact(sessionID, fixture.artifactID, undefined, controller.signal);
    await Promise.race([acquired, pending]);
    controller.abort();
    await expect(pending).rejects.toMatchObject({ name: "AbortError" });
    await registry.delete(sessionID);
    const removal = displayOwnerOf(registry).removeArtifacts(sessionID);
    deliver();
    await removal;
    await waitFor(() => !existsSync(fixture.content), "late display lease release and physical removal");
    await expect(readFile(fixture.content)).rejects.toMatchObject({ code: "ENOENT" });
  } finally {
    deliver();
    held.mockRestore();
    await lateLease?.release();
    await registry.dispose();
    await rm(fixture.root, { recursive: true, force: true });
  }
});
