import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall } from "@earendil-works/pi-ai";
import { expect, it } from "vitest";
import { createTestRegistry } from "../../test-support/gateway-registry.js";
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
      const lease = await registry!.acquireDisplayArtifact(sessionID, artifactID);
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
    await registry.removeDisplayArtifacts(sessionID);
    await expect(registry.acquireDisplayArtifact(sessionID, artifactID)).rejects.toMatchObject({ code: "not_found" });
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
