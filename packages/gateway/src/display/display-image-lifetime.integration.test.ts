import { createHash } from "node:crypto";
import { existsSync } from "node:fs";
import { mkdir, mkdtemp, readFile, rm, stat, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall } from "@earendil-works/pi-ai";
import { expect, it, vi } from "vitest";
import { createTestRegistry, displayOwnerOf, displayStoreOf } from "../../test-support/gateway-registry.js";
import type { RuntimeRegistry } from "../kernel/session/runtime-registry.js";
import { TrustService } from "../kernel/resources/trust-service.js";
import { waitFor } from "../../test-support/wait-for.js";
import { DisplayArtifactStore } from "./display-artifact-store.js";
import { drainDurableWriteStats } from "../foundation/durable-json.js";

it("durably publishes new display bytes once and reuses them for distinct retained artifacts", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-display-dedup-"));
  try {
    const store = new DisplayArtifactStore(root);
    await store.initialize();
    const source = "// original snapshot\n";
    await writeFile(join(root, "Snapshot.swift"), source);
    // A valid but unreferenced inode models a prior interrupted publication.
    const digest = createHash("sha256").update(source).digest("hex");
    const object = join(root, "gateway/display-artifacts/objects", digest.slice(0, 2), digest.slice(2));
    await mkdir(dirname(object), { recursive: true });
    await writeFile(object, source, { mode: 0o400 });
    const orphan = await stat(object);
    drainDurableWriteStats();
    const first = await store.ingest(root, "Snapshot.swift", "first-session");
    expect(drainDurableWriteStats().count).toBe(3); // object bytes, metadata, metadata directory
    const retained = await stat(join(root, "gateway/display-artifacts/artifacts", first.id, "content"));
    expect([retained.dev, retained.ino]).toEqual([orphan.dev, orphan.ino]); // actual existing-object path
    const second = await store.ingest(root, "Snapshot.swift", "second-session");
    expect(drainDurableWriteStats().count).toBe(2); // metadata and directory; staged duplicate is discarded
    expect(second.id).not.toBe(first.id);
    await rm(join(root, "Snapshot.swift"));
    const reopened = new DisplayArtifactStore(root);
    await reopened.initialize();
    for (const [artifact, session] of [[first, "first-session"], [second, "second-session"]] as const) {
      const lease = await reopened.acquire(artifact.id, session);
      try {
        const chunks: Buffer[] = [];
        for await (const chunk of lease.stream) chunks.push(Buffer.from(chunk));
        expect(Buffer.concat(chunks).toString()).toBe("// original snapshot\n");
      } finally { await lease.release(); }
    }
    const destination = join(root, "Retained.swift");
    await expect(reopened.linkArtifact(second.id, "other-session", digest, destination)).rejects.toMatchObject({ code: "not_found" });
    await expect(reopened.linkArtifact(second.id, "second-session", "0".repeat(64), destination)).rejects.toMatchObject({ code: "conflict" });
    await expect(stat(destination)).rejects.toMatchObject({ code: "ENOENT" });
    expect(await reopened.linkArtifact(second.id, "second-session", digest, destination)).toBe(true);
    const linked = await stat(destination);
    expect([linked.dev, linked.ino]).toEqual([orphan.dev, orphan.ino]);
    await expect(reopened.linkArtifact(second.id, "second-session", digest, destination)).rejects.toMatchObject({ code: "EEXIST" });
    await reopened.revoke(first.id, "first-session");
    await reopened.revoke(second.id, "second-session");
    expect(await readFile(destination, "utf8")).toBe(source);
  } finally { await rm(root, { recursive: true, force: true }); }
});

it("retains only authorized sibling Markdown images through source removal, cold reopen and session deletion", async () => {
  const fixture = await displayedPhotoFixture();
  let registry = fixture.registry;
  const sessionID = fixture.slot.id;
  const evidence: Record<string, unknown> = {};
  try {
    const files = join(fixture.options.tronHome, "workspace/files/review");
    await mkdir(files, { recursive: true });
    await writeFile(join(files, "preview.png"), fixture.image);
    await writeFile(join(files, "ignored.png"), fixture.image);
    await writeFile(join(files, "../outside.png"), fixture.image);
    await symlink(join(files, "../outside.png"), join(files, "linked.png"));
    await writeFile(join(files, "report.md"), [
      "# Review", "![Preview](preview.png)", "![Missing](missing.png)",
      "![Outside](../outside.png)", "![Linked](linked.png)",
      "![Remote](https://example.test/tracker.png)", "```md", "![Code](ignored.png)", "```",
    ].join("\n\n"));
    fixture.faux.setResponses([
      fauxAssistantMessage([fauxToolCall("display", {
        title: "Review images", altText: "Internal report", source: { kind: "internal_file", path: "review/report.md" },
      })], { stopReason: "toolUse" }), fauxAssistantMessage("done"),
    ]);
    await fixture.slot.prompt("Display the review document");
    await waitFor(() => !fixture.slot.isBusy, "Markdown display idle");
    const row = fixture.slot.snapshot().transcript.findLast(item => item.kind === "message" && item.display?.title === "Review images");
    if (row?.kind !== "message" || !row.display?.artifact) throw new Error("Markdown display missing");
    // Read the actual projected contract, without an implementation helper.
    const display = row.display as typeof row.display & { markdownImages?: Array<{ destination: string; artifact: { id: string } }> };
    expect(display.markdownImages?.map(image => image.destination)).toEqual(["preview.png"]);
    const imageID = display.markdownImages![0]!.artifact.id;
    expect(await previewBytes(registry, sessionID, imageID)).toEqual(fixture.image);
    await rm(files, { recursive: true });
    expect(await previewBytes(registry, sessionID, imageID)).toEqual(fixture.image);
    evidence.afterSourceDeletion = "identical retained sibling image";
    await registry.dispose();
    registry = await createTestRegistry(fixture.options);
    await registry.initialize();
    await registry.initializeBlobStorage();
    await registry.acquire(sessionID);
    expect(await previewBytes(registry, sessionID, imageID)).toEqual(fixture.image);
    evidence.afterColdReopen = "identical retained sibling image";
    await registry.delete(sessionID);
    await displayOwnerOf(registry).removeArtifacts(sessionID);
    await expect(displayOwnerOf(registry).acquireArtifact(sessionID, imageID)).rejects.toMatchObject({ code: "not_found" });
    evidence.afterSessionDeletion = "unavailable";
  } finally {
    await registry.dispose();
    await rm(fixture.root, { recursive: true, force: true });
    const output = join(process.cwd(), "test-results/display-markdown-images.json");
    await mkdir(dirname(output), { recursive: true });
    await writeFile(output, `${JSON.stringify(evidence, null, 2)}\n`);
  }
}, 30_000);

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
    return { root, options, registry, slot, image, artifactID, rekeys, faux,
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
