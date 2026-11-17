import { createTestRegistry, displayStoreOf, displayOwnerOf } from "../../../test-support/gateway-registry.js";
import { DEFAULT_MAX_LIVE_RUNTIMES } from "../../config.js";
import { randomUUID } from "node:crypto";
import * as fsPromises from "node:fs/promises";
import { existsSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { appendFile, copyFile, mkdir, readFile, readdir, realpath, rename, rm, symlink, truncate, writeFile } from "node:fs/promises";
import { basename, dirname, join, resolve } from "node:path";
import { ModelRuntime, SessionManager } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it, vi } from "vitest";
import { TrustService } from "../../kernel/resources/trust-service.js";
import type { SessionSummaryUpdate } from "../../protocol/types.js";
import { CatalogDiscovery, DEFAULT_CATALOG_DISCOVERY_LIMITS, buildCatalogSessionInfo, type CatalogSessionInfo } from "../../sessions/catalog-discovery.js";
import { CatalogMetadataIndex } from "../../sessions/catalog-metadata-index.js";
import { type SessionCatalog, type SessionCatalogReconcileOutcome } from "../../sessions/session-catalog.js";
import {
  RuntimeRegistry,
} from "../../kernel/session/runtime-registry.js";
import { AutomationService } from "../../automations/automation-service.js";
import { waitFor } from "../../../test-support/wait-for.js";
import { catalogOwner, createColdRegistryFixture, initializeRegistry, settleCatalog, temporaryRoot } from "../../../test-support/runtime-registry-fixture.js";
const quarantineLock = vi.hoisted(() => ({ armed: false, directory: "" }));

vi.mock("node:fs/promises", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:fs/promises")>();
  return {
    ...actual,
    rm: async (path: Parameters<typeof actual.rm>[0], ...rest: unknown[]) => {
      if (quarantineLock.armed && String(path).includes(".tron-delete-")) {
        quarantineLock.armed = false;
        quarantineLock.directory = dirname(String(path));
        await actual.chmod(quarantineLock.directory, 0o500);
      }
      return (actual.rm as unknown as (target: unknown, ...args: unknown[]) => Promise<void>)(path, ...rest);
    },
  };
});

async function collectStream(stream: NodeJS.ReadableStream): Promise<Buffer> {
  const chunks: Buffer[] = [];
  for await (const value of stream) chunks.push(Buffer.isBuffer(value) ? value : Buffer.from(value));
  return Buffer.concat(chunks);
}

function catalogWalks(): { count: () => number; restore: () => void } {
  const walk = vi.spyOn(CatalogDiscovery.prototype, "catalogStructureEvidence");
  return { count: () => walk.mock.calls.length, restore: () => walk.mockRestore() };
}

function catalogHeaderReads(): { paths: () => string[]; restore: () => void } {
  const reads = vi.spyOn(CatalogDiscovery.prototype, "readCatalogHeader");
  return { paths: () => reads.mock.calls.map(([path]) => String(path)), restore: () => reads.mockRestore() };
}

describe("RuntimeRegistry with the pinned agent runtime", { concurrent: false }, () => {
  const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
  const registries: RuntimeRegistry[] = [];

  const coldFixture = createColdRegistryFixture.bind(undefined, registries);

  afterEach(async () => {
    await Promise.all(registries.splice(0).map((registry) => registry.dispose()));
    vi.restoreAllMocks();
    if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
    else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
  });
  it("bounds recursive catalog directories and streamed entries before materialization", async () => {
    const root = await temporaryRoot("tron-catalog-discovery-bounds-");
    const agentDir = join(root, "agent");
    const catalog = join(agentDir, "sessions");
    await Promise.all([
      mkdir(join(catalog, "first"), { recursive: true }),
      mkdir(join(catalog, "second"), { recursive: true }),
    ]);
    const bounded = async (
      label: string,
      maximumDirectories: number,
      maximumEntries: number,
      maximumTraversalBytes = 8 * 1_024 * 1_024,
    ) => {
      const reconciled: SessionCatalogReconcileOutcome[] = [];
      const registry = await createTestRegistry({
        agentDir,
        tronHome: join(root, `tron-${label}`),
        idleRuntimeMs: 60_000,
        trust: new TrustService(agentDir),
        broadcast: () => {},
        sessionSummaryChanged: () => {},
        sessionListChanged: () => {},
        catalogDiscoveryLimits: { maximumDirectories, maximumEntries, maximumTraversalBytes },
        catalogReconciled: (outcome) => reconciled.push(outcome),
      });
      registries.push(registry);
      const owner = catalogOwner(registry);
      await registry.initialize();
      await owner.whenReconciled();
      return { registry, reconciled };
    };

    for (const over of [
      await bounded("directories", 2, 2),
      await bounded("entries", 3, 1),
      await bounded("bytes", 3, 2, 1),
    ]) {
      expect(over.reconciled.at(-1)?.outcome).toBe("failed");
      expect(over.reconciled.at(-1)?.files).toBe(0);
      expect(catalogOwner(over.registry).hasCompleteCut()).toBe(false);
      await expect(over.registry.catalog("all")).rejects.toMatchObject({ code: "busy", retryable: true });
    }

    const withinBudget = await bounded("within", 3, 2);
    expect(withinBudget.reconciled.at(-1)?.outcome).toBe("reconciled");
    await expect(withinBudget.registry.catalog("all")).resolves.toMatchObject({ sessions: [] });
  });

  it("ignores JSONL symlinks outside the canonical catalog root", async () => {
    const fixture = await coldFixture("catalog-file-symlink");
    const external = join(fixture.root, "external-session.jsonl");
    const outside = SessionManager.create(fixture.cwd, join(fixture.root, "outside"));
    outside.appendMessage(fauxAssistantMessage("outside catalog fixture"));
    await copyFile(outside.getSessionFile()!, external);
    const alias = join(fixture.agentDir, "sessions", "workspace", "outside.jsonl");
    await symlink(external, alias);

    const listed = await fixture.registry.catalog("all");
    expect(listed.sessions.map((session) => session.id)).not.toContain(outside.getSessionId());
  });

  it("keeps public catalog identity stable when the same folders are enumerated in another order", async () => {
    const fixture = await coldFixture("catalog-walk-order");
    const catalogRoot = join(fixture.agentDir, "sessions");
    const folderNames = ["walk-a", "walk-b", "walk-c"];
    const managers = folderNames.map((name) => {
      const directory = join(catalogRoot, name);
      return SessionManager.create(fixture.cwd, directory);
    });
    for (const manager of managers) manager.appendMessage(fauxAssistantMessage("stable catalog fixture"));

    const before = await fixture.registry.catalog("all");
    const beforeIDs = before.sessions.map((session) => session.id).sort();
    const holding = join(fixture.root, "walk-order-holding");
    await mkdir(holding);
    for (const name of folderNames) await rename(join(catalogRoot, name), join(holding, name));
    for (const name of [...folderNames].reverse()) await rename(join(holding, name), join(catalogRoot, name));

    const after = await fixture.registry.catalog("all");
    expect(after.listRevision).toBe(before.listRevision);
    expect(after.sessions.map((session) => session.id).sort()).toEqual(beforeIDs);
  });

  it("owns nested SDK session directories within its bounded directory budget", async () => {
    const root = await temporaryRoot("tron-catalog-direct-sdk-listing-");
    const agentDir = join(root, "agent");
    const catalog = join(agentDir, "sessions");
    const child = join(catalog, "child");
    await Promise.all([mkdir(catalog, { recursive: true }), mkdir(child, { recursive: true })]);
    const directSession = SessionManager.create(root, catalog);
    const childSession = SessionManager.create(root, child);
    directSession.appendMessage(fauxAssistantMessage("direct catalog fixture"));
    childSession.appendMessage(fauxAssistantMessage("child catalog fixture"));

    expect((await SessionManager.listAll(catalog)).map((session) => session.id)).toEqual([
      directSession.getSessionId(),
    ]);
    expect((await SessionManager.listAll(child)).map((session) => session.id)).toEqual([
      childSession.getSessionId(),
    ]);

    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
      catalogDiscoveryLimits: { maximumDirectories: 2, maximumSessions: 2 },
    });
    registries.push(registry);
    await initializeRegistry(registry);
    expect((await registry.catalog("all")).sessions.map((session) => session.id).sort()).toEqual([
      childSession.getSessionId(), directSession.getSessionId(),
    ].sort());
  });

  it("bounds cold catalog previews without changing canonical prompts or names", async () => {
    const fixture = await coldFixture("large-catalog-preview");
    const prompt = "😀漢字".repeat(5_000);
    const name = "Long session 😀 ".repeat(1_000);
    fixture.manager.appendMessage({ role: "user", content: prompt, timestamp: Date.now() });
    fixture.manager.appendSessionInfo(name);
    await settleCatalog(fixture.registry);
    const before = await readFile(fixture.sessionFile, "utf8");
    const row = (await fixture.registry.catalog("all")).sessions[0]!;
    expect(Buffer.byteLength(row.firstMessage)).toBeLessThanOrEqual(1_024);
    expect(Buffer.byteLength(row.name!)).toBeLessThanOrEqual(1_024);
    expect(row.firstMessage.endsWith("…")).toBe(true);
    expect(row.firstMessage).not.toContain("\uFFFD");
    expect(prompt.startsWith(row.firstMessage.slice(0, -1))).toBe(true);
    expect(await readFile(fixture.sessionFile, "utf8")).toBe(before);
    expect(before).toContain(prompt);
    expect(before).toContain(name.trim());
  });

  it("initializes storage without requiring catalog presentation metadata", async () => {
    const fixture = await coldFixture("storage-without-catalog-preview");
    const store = displayStoreOf(fixture.registry);
    await store.initialize();
    await writeFile(join(fixture.cwd, "retained.txt"), "retained display artifact");
    const display = await store.ingest(fixture.cwd, "retained.txt", fixture.manager.getSessionId());
    const evidence = vi.spyOn(CatalogDiscovery.prototype, "catalogStructureEvidence")
      .mockImplementation(async () => ({
        catalogRoot: await realpath(dirname(dirname(fixture.sessionFile))),
        digest: "incomplete", factsDigest: "incomplete", identitiesByPath: new Map(),
        complete: false, unprovenPaths: new Set(), unstableCanonicalFiles: false,
      }));
    try {
      await catalogOwner(fixture.registry).reconcile();
      await expect(fixture.registry.sessionIDsForStorageMaintenance())
        .rejects.toMatchObject({ code: "busy", retryable: true });
      await expect(displayOwnerOf(fixture.registry).maintainArtifacts()).rejects.toMatchObject({ code: "busy" });
    } finally {
      evidence.mockRestore();
    }
    await expect(fixture.registry.initializeBlobStorage()).resolves.toBeUndefined();
    const displayLease = await store.acquire(display.id, fixture.manager.getSessionId());
    try {
      expect((await collectStream(displayLease.stream)).toString()).toBe("retained display artifact");
    } finally { await displayLease.release(); }
    const membership = vi.spyOn(fixture.registry, "sessionIDsForStorageMaintenance").mockResolvedValueOnce(new Set());
    await displayOwnerOf(fixture.registry).maintainArtifacts();
    membership.mockRestore();
    await expect(store.acquire(display.id, fixture.manager.getSessionId())).rejects.toMatchObject({ code: "not_found" });
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const artifact = await slot.export("jsonl");
    const lease = await fixture.registry.acquireBlob(artifact.blobId);
    try {
      expect((await collectStream(lease.stream)).toString()).toContain("storage-without-catalog-preview");
    } finally { await lease.release(); }
  });

  it("bounds discovered session count and bytes before normalization", async () => {
    const root = await temporaryRoot("tron-catalog-materialization-bounds-");
    const agentDir = join(root, "agent");
    await mkdir(join(agentDir, "sessions"), { recursive: true });
    const now = new Date("2026-01-01T00:00:00Z");
    const infos = ["first", "second"].map((id) => ({
      id,
      path: join(agentDir, "sessions", `${id}.jsonl`),
      cwd: root,
      created: now,
      modified: now,
      messageCount: 0,
      firstMessage: id,
    }));
    await Promise.all(infos.map((info) => writeFile(info.path, `${JSON.stringify({
      type: "session", version: 3, id: info.id, timestamp: now.toISOString(), cwd: root,
    })}\n`)));
    const bounded = async (label: string, maximumSessions: number) => {
      const reconciled: SessionCatalogReconcileOutcome[] = [];
      const registry = await createTestRegistry({
        agentDir,
        tronHome: join(root, `tron-${label}`),
        idleRuntimeMs: 60_000,
        trust: new TrustService(agentDir),
        broadcast: () => {},
        sessionSummaryChanged: () => {},
        sessionListChanged: () => {},
        catalogDiscoveryLimits: { maximumSessions, normalizationConcurrency: 1 },
        catalogReconciled: (outcome) => reconciled.push(outcome),
      });
      registries.push(registry);
      const owner = catalogOwner(registry);
      await registry.initialize();
      await owner.whenReconciled();
      return { registry, reconciled, owner };
    };

    const tooSmall = await bounded("sessions-1", 1);
    expect(tooSmall.reconciled.at(-1)).toMatchObject({ outcome: "failed" });
    expect(tooSmall.owner.hasCompleteCut()).toBe(false);
    await expect(tooSmall.registry.catalog("all")).rejects.toMatchObject({ code: "busy", retryable: true });

    const enough = await bounded("sessions-2", 2);
    expect(enough.reconciled.at(-1)).toMatchObject({ outcome: "reconciled" });
    await expect(enough.registry.catalog("all")).resolves.toMatchObject({
      sessions: [{ id: "first" }, { id: "second" }],
    });
  });

  it("caps canonical session path normalization concurrency", async () => {
    const root = await temporaryRoot("tron-catalog-normalization-concurrency-");
    const agentDir = join(root, "agent");
    await mkdir(join(agentDir, "sessions"), { recursive: true });
    const now = new Date("2026-01-01T00:00:00Z");
    const parentPath = join(agentDir, "sessions", "z-parent.jsonl");
    await writeFile(parentPath, `${JSON.stringify({
      type: "session", version: 3, id: "parent", timestamp: now.toISOString(), cwd: root,
    })}\n`);
    const infos = Array.from({ length: 6 }, (_, index) => ({
      id: `session-${index}`,
      path: join(agentDir, "sessions", `session-${index}.jsonl`),
    }));
    await Promise.all(infos.map((info) => writeFile(info.path, `${JSON.stringify({
      type: "session", version: 3, id: info.id, timestamp: now.toISOString(), cwd: root, parentSession: parentPath,
    })}\n`)));
    const reconciled: SessionCatalogReconcileOutcome[] = [];
    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
      catalogDiscoveryLimits: { normalizationConcurrency: 2 },
      catalogReconciled: (outcome) => reconciled.push(outcome),
    });
    registries.push(registry);
    const internals = registry as unknown as {
      canonicalSessionPath: (path: string) => Promise<string>;
    };
    let active = 0;
    let maximumActive = 0;
    const canonicalize = vi.spyOn(internals, "canonicalSessionPath").mockImplementation(async (path) => {
      active += 1;
      maximumActive = Math.max(maximumActive, active);
      await new Promise((resolve) => setTimeout(resolve, 5));
      active -= 1;
      return resolve(path);
    });

    try {
      const owner = catalogOwner(registry);
      await registry.initialize();
      await owner.whenReconciled();
      await owner.settled();
      maximumActive = 0;

      await owner.reconcile();
      expect(maximumActive).toBe(2);
      expect(reconciled.at(-1)?.outcome).toBe("reconciled");
      expect(reconciled.at(-1)?.files).toBe(infos.length + 1);
      expect((await registry.catalog("all")).sessions.map((session) => session.id).sort())
        .toEqual([...infos.map((info) => info.id), "parent"].sort());
    } finally {
      canonicalize.mockRestore();
    }
  });

  it("resolves a list, a cold open and a hot re-acquire from the owner's rows without a walk", async () => {
    const fixture = await coldFixture("reuse");
    await settleCatalog(fixture.registry);
    const walks = catalogWalks();
    const before = walks.count();

    const catalog = await fixture.registry.catalog("user");
    expect(catalog.sessions.map((session) => session.id)).toContain(fixture.manager.getSessionId());
    fixture.manager.appendMessage(fauxAssistantMessage("ordinary append after catalog"));
    await settleCatalog(fixture.registry);
    const readsFrom = walks.count();
    expect((await fixture.registry.acquire(fixture.manager.getSessionId())).id).toBe(fixture.manager.getSessionId());
    expect(fixture.runtimeFactory).toHaveBeenCalledTimes(1);
    expect((await fixture.registry.acquire(fixture.manager.getSessionId())).id).toBe(fixture.manager.getSessionId());
    expect(walks.count()).toBe(readsFrom);
    walks.restore();
  });

  it("reuses an on-disk catalog across a second registry without a body scan and advances one appended row", async () => {
    const fixture = await coldFixture("restart-index");
    const secondDirectory = join(fixture.agentDir, "sessions", "second");
    await mkdir(secondDirectory, { recursive: true });
    const secondManager = SessionManager.create(fixture.cwd, secondDirectory);
    secondManager.appendMessage(fauxAssistantMessage("unchanged canonical body"));
    fixture.manager.appendMessage(fauxAssistantMessage("initial canonical body"));
    await fixture.registry.catalog("all");
    const indexPath = join(fixture.root, "tron", "cache", "catalog-metadata-v3", "manifest.json");
    await settleCatalog(fixture.registry);
    expect(existsSync(indexPath)).toBe(true);
    await fixture.registry.dispose();
    const restarted = await createTestRegistry({
      agentDir: fixture.agentDir,
      tronHome: join(fixture.root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }),
      trust: new TrustService(fixture.agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(restarted);
    await initializeRegistry(restarted);
    await settleCatalog(restarted);
    const walks = catalogWalks();
    const before = walks.count();
    const append = vi.spyOn(CatalogMetadataIndex.prototype, "append");
    try {
      const unchanged = await restarted.catalog("all");
      expect(unchanged.sessions.find((session) => session.id === fixture.manager.getSessionId())?.messageCount).toBe(2);
      expect(unchanged.sessions.find((session) => session.id === secondManager.getSessionId())?.messageCount).toBe(1);
      fixture.manager.appendMessage(fauxAssistantMessage("external append after restart"));
      await settleCatalog(restarted);
      const readsFrom = walks.count();
      const updated = await restarted.catalog("all");
      expect(append.mock.calls.length).toBeGreaterThan(0);
      expect(updated.sessions.find((session) => session.id === fixture.manager.getSessionId())?.messageCount).toBe(3);
      expect(updated.sessions.find((session) => session.id === secondManager.getSessionId())?.messageCount).toBe(1);
      expect(walks.count()).toBe(readsFrom);
    } finally {
      append.mockRestore();
      walks.restore();
    }
  });

  it("writes the durable catalog document from its owner, not from a reader cut", async () => {
    const fixture = await coldFixture("owner-only-index-writer");
    await settleCatalog(fixture.registry);
    const indexPath = join(fixture.root, "tron", "cache", "catalog-metadata-v3", "manifest.json");
    expect(existsSync(indexPath)).toBe(true);
    await rm(join(fixture.root, "tron", "cache", "catalog-metadata-v3"), { recursive: true, force: true });
    (fixture.registry as unknown as { catalogStructuralIndex: unknown }).catalogStructuralIndex = undefined;
    const save = vi.spyOn(CatalogMetadataIndex.prototype, "save");
    try {
      await fixture.registry.catalog("all");
      await new Promise((resolve) => setTimeout(resolve, 250));
      expect(save).not.toHaveBeenCalled();
      expect(existsSync(indexPath)).toBe(false);
    } finally {
      save.mockRestore();
    }
  });

    it("rejects an unowned append that races durable-index reconciliation", async () => {
    const fixture = await coldFixture("unowned-index-append-race");
    await fixture.registry.catalog("all");
    const indexPath = join(fixture.root, "tron", "cache", "catalog-metadata-v3", "manifest.json");
    await settleCatalog(fixture.registry);
    expect(existsSync(indexPath)).toBe(true);
    await fixture.registry.dispose();
    const restarted = await createTestRegistry({
      agentDir: fixture.agentDir,
      tronHome: join(fixture.root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }),
      trust: new TrustService(fixture.agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(restarted);
    await initializeRegistry(restarted);
    await settleCatalog(restarted);
    const reconcile = vi.spyOn(CatalogMetadataIndex.prototype, "reconcile");
    try {
      fixture.manager.appendMessage(fauxAssistantMessage("unowned append during index reconciliation"));
      await settleCatalog(restarted);
      expect(reconcile).toHaveBeenCalled();
      const listed = await restarted.catalog("all");
      expect(listed.sessions.find((session) => session.id === fixture.manager.getSessionId()))
        .toMatchObject({ messageCount: 2 });
    } finally {
      reconcile.mockRestore();
    }
  });

      it("keeps the last provable row when an unowned canonical file ends in a partial line", async () => {
    const fixture = await coldFixture("partial-final-line");
    const before = (await fixture.registry.catalog("all")).sessions
      .find((session) => session.id === fixture.manager.getSessionId())!;
    await appendFile(fixture.sessionFile, "{\"type\":\"message\"");
    await settleCatalog(fixture.registry);
    const walks = catalogWalks();
    const at = walks.count();
    const after = (await fixture.registry.catalog("all")).sessions
      .find((session) => session.id === fixture.manager.getSessionId())!;
    expect(after.messageCount).toBe(before.messageCount);
    expect(walks.count()).toBe(at);
    walks.restore();
  });

    it("invalidates connected catalogs when cold attention has no live summary", async () => {
    const listChanged = vi.fn();
    const fixture = await coldFixture("cold-attention", { sessionListChanged: listChanged });
    const before = listChanged.mock.calls.length;
    const unread = await fixture.registry.setAttention(fixture.manager.getSessionId(), true);
    expect(unread.isUnread).toBe(true);
    expect(listChanged.mock.calls.length).toBe(before + 1);
  });

  it("converges empty create/list/delete while live summaries churn", async () => {
    const fixture = await coldFixture("create-list-delete-churn");
    const live = await fixture.registry.create(fixture.cwd);
    const internals = fixture.registry as unknown as {
      publishRevisionedSummary: (summary: SessionSummaryUpdate) => void;
    };
    for (let revision = 1; revision <= 8; revision += 1) {
      internals.publishRevisionedSummary({
        sessionId: live.id,
        summaryRevision: revision,
        phase: "running",
        updatedAt: new Date().toISOString(),
        messageCount: revision,
        firstMessage: "created live session",
        completionRevision: 0,
        attentionRevision: 0,
        isUnread: false,
      });
    }
    expect((await fixture.registry.catalog("user")).sessions.map((session) => session.id)).toContain(live.id);
    await fixture.registry.delete(live.id);
    expect((await fixture.registry.catalog("user")).sessions.map((session) => session.id)).not.toContain(live.id);
  });

  it("admits unread and read attention for an empty live-only session", async () => {
    const fixture = await coldFixture("live-only-attention");
    const live = await fixture.registry.create(fixture.cwd);
    const unread = await fixture.registry.setAttention(live.id, true);
    expect(unread.isUnread).toBe(true);
    const read = await fixture.registry.setAttention(live.id, false, unread.completionRevision);
    expect(read.isUnread).toBe(false);
  });

  it("quarantines a disk claimant that collides with an empty live-only session", async () => {
    const fixture = await coldFixture("live-only-attention-collision");
    const live = await fixture.registry.create(fixture.cwd);
    const collisionDirectory = join(fixture.agentDir, "sessions", "collision");
    await mkdir(collisionDirectory, { recursive: true });
    const collision = SessionManager.create(fixture.cwd, collisionDirectory, { id: live.id });
    collision.appendMessage(fauxAssistantMessage("collision"));
    await settleCatalog(fixture.registry);
    await expect(fixture.registry.setAttention(live.id, true)).rejects.toMatchObject({ code: "conflict" });
  });

  it("rechecks a live-only attention target when a disk claimant appears at the commit boundary", async () => {
    const fixture = await coldFixture("live-only-attention-race");
    const live = await fixture.registry.create(fixture.cwd);
    const internals = fixture.registry as unknown as {
      attentionLiveOnlyStillAdmitted: (sessionId: string) => Promise<boolean>;
    };
    const original = internals.attentionLiveOnlyStillAdmitted.bind(fixture.registry);
    let entered!: () => void;
    let release!: () => void;
    const reachedCommitBoundary = new Promise<void>((resolve) => { entered = resolve; });
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const finalAdmission = vi.spyOn(internals, "attentionLiveOnlyStillAdmitted")
      .mockImplementation(async (sessionId) => {
        entered();
        await gate;
        return original(sessionId);
      });

    try {
      const update = fixture.registry.setAttention(live.id, true);
      await reachedCommitBoundary;
      const collisionDirectory = join(fixture.agentDir, "sessions", "late-collision");
      await mkdir(collisionDirectory, { recursive: true });
      const collision = SessionManager.create(fixture.cwd, collisionDirectory, { id: live.id });
      collision.appendMessage(fauxAssistantMessage("late collision"));
      await settleCatalog(fixture.registry);
      release();
      await expect(update).rejects.toMatchObject({ code: "conflict" });
      expect(fixture.registry.attentionProjection(live.id).isUnread).toBe(false);
    } finally {
      release();
      finalAdmission.mockRestore();
    }
  });

  it("keeps the records of an unprovable session that has no stored row", async () => {
    const fixture = await coldFixture("unproven-no-row");
    const sessionId = fixture.manager.getSessionId();
    await settleCatalog(fixture.registry);
    await fixture.registry.setArchived(sessionId, true);
    await settleCatalog(fixture.registry);
    expect(fixture.registry.isArchived(sessionId)).toBe(true);
    await fixture.registry.dispose();
    registries.splice(registries.indexOf(fixture.registry), 1);
    await rm(join(fixture.root, "tron", "cache", "catalog-metadata-v3"), { recursive: true, force: true });
    const completeBytes = (await fsPromises.stat(fixture.sessionFile)).size;
    await appendFile(fixture.sessionFile, '{"type":"message"');

    const reconciled: SessionCatalogReconcileOutcome[] = [];
    const restarted = await createTestRegistry({
      agentDir: fixture.agentDir,
      tronHome: join(fixture.root, "tron"),
      idleRuntimeMs: 60_000,
      trust: new TrustService(fixture.agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
      catalogReconciled: (outcome) => reconciled.push(outcome),
    });
    registries.push(restarted);
    await restarted.initialize();
    const owner = catalogOwner(restarted);
    await owner.whenReconciled();

    expect(reconciled.at(-1)).toMatchObject({ outcome: "incomplete" });
    expect(reconciled.at(-1)!.unproven).toBeGreaterThan(0);
    expect(owner.hasReconciledCut()).toBe(false);
    expect(owner.hasUnknownMembership()).toBe(true);
    expect(owner.unprovenSessionIds().has(sessionId)).toBe(true);
    await restarted.recoverCanonicalAttention();
    expect(restarted.isArchived(sessionId)).toBe(true);
    await expect(restarted.sessionIDsForStorageMaintenance())
      .rejects.toMatchObject({ code: "busy", retryable: true });
    expect((await restarted.list("all")).map((session) => session.id)).not.toContain(sessionId);
    await expect(restarted.acquire(sessionId)).rejects.toMatchObject({ code: "busy", retryable: true, diagnosticReason: "catalog_not_ready" });
    await expect(restarted.delete(sessionId)).rejects.toMatchObject({ code: "busy", retryable: true });

    await truncate(fixture.sessionFile, completeBytes);
    await settleCatalog(restarted);
    expect(owner.hasReconciledCut()).toBe(true);
    expect(restarted.isArchived(sessionId)).toBe(true);
    expect((await restarted.list("all")).find((session) => session.id === sessionId)?.archivedAt).toBeDefined();
    expect((await restarted.sessionIDsForStorageMaintenance()).has(sessionId)).toBe(true);
    expect((await restarted.acquire(sessionId)).id).toBe(sessionId);
  });

  it.each([false, true])("admits an existing-session automation while the first cut runs (durable index: %s)", async (withDocument) => {
    const root = await temporaryRoot("tron-automation-startup-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const sessionDirectory = join(agentDir, "sessions", "workspace");
    await Promise.all([mkdir(sessionDirectory, { recursive: true }), mkdir(cwd, { recursive: true })]);
    process.env.PI_CODING_AGENT_DIR = agentDir;
    let target = "";
    for (let index = 0; index < 200; index += 1) {
      const manager = SessionManager.create(cwd, sessionDirectory);
      manager.appendMessage(fauxAssistantMessage("x".repeat(2_000)));
      target ||= manager.getSessionId();
    }
    const make = async () => await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    if (withDocument) {
      const seeded = await make();
      registries.push(seeded);
      await initializeRegistry(seeded);
      await settleCatalog(seeded);
      await seeded.dispose();
      registries.splice(registries.indexOf(seeded), 1);
    }

    const registry = await make();
    registries.push(registry);
    const blocked: Array<[string, string]> = [];
    const store = {
      initialize: async () => {},
      snapshot: () => [{
        id: "automation-startup", activation: "active",
        target: { kind: "existingSession", sessionId: target },
      }],
      blockTarget: async (sessionId: string, reason: string) => { blocked.push([sessionId, reason]); },
    };
    const scheduler = { recover: async () => {}, start: () => {} };
    await registry.initialize();
    const service = new AutomationService(
      store as never,
      scheduler as never,
      registry,
    );
    await expect(service.initialize()).resolves.toBeUndefined();
    expect(blocked).toEqual([]);
  });

  it("keeps the published rows through an incomplete pass and authorizes nothing destructive", async () => {
    const fixture = await coldFixture("incomplete-index-evidence");
    await settleCatalog(fixture.registry);
    const published = (await fixture.registry.catalog("all")).sessions.map((session) => session.id);
    const catalog = catalogOwner(fixture.registry);
    const evidence = vi.spyOn(CatalogDiscovery.prototype, "catalogStructureEvidence")
      .mockImplementation(async () => ({
        catalogRoot: await realpath(dirname(dirname(fixture.sessionFile))),
        digest: "incomplete", factsDigest: "incomplete", identitiesByPath: new Map(),
        complete: false, unprovenPaths: new Set(), unstableCanonicalFiles: false,
      }));
    try {
      await catalog.reconcile();
    } finally {
      evidence.mockRestore();
    }
    expect((await fixture.registry.catalog("all")).sessions.map((session) => session.id)).toEqual(published);
    expect(catalog.hasReconciledCut()).toBe(false);
    await expect(fixture.registry.sessionIDsForStorageMaintenance())
      .rejects.toMatchObject({ code: "busy", retryable: true });
  });

  it("reclaims reloadable idle runtimes under pressure while protecting visible sessions and drafts", async () => {
    const fixture = await coldFixture("idle-capacity-reclamation", { maximumLiveRuntimes: 3 });
    const first = await fixture.registry.acquire(fixture.manager.getSessionId());
    fixture.registry.subscribe("phone", first.id);
    const secondManager = SessionManager.create(fixture.cwd, dirname(fixture.sessionFile));
    secondManager.appendMessage(fauxAssistantMessage("reloadable idle"));
    await settleCatalog(fixture.registry);
    const second = await fixture.registry.acquire(secondManager.getSessionId());
    const draft = await fixture.registry.create(fixture.cwd);
    const thirdManager = SessionManager.create(fixture.cwd, dirname(fixture.sessionFile));
    thirdManager.appendMessage(fauxAssistantMessage("new visible selection"));
    await settleCatalog(fixture.registry);
    const third = await fixture.registry.acquire(thirdManager.getSessionId());
    expect(second.isDisposed).toBe(true);
    expect(first.isDisposed).toBe(false);
    expect(draft.isDisposed).toBe(false);
    expect(third.id).toBe(thirdManager.getSessionId());
    const retain = third.retainLease();
    try { await expect(fixture.registry.acquire(secondManager.getSessionId())).rejects.toMatchObject({ code: "busy" }); }
    finally { retain(); }
    const reopened = await fixture.registry.acquire(secondManager.getSessionId());
    expect(reopened).not.toBe(second);
    expect(JSON.stringify(reopened.snapshot().transcript)).toContain("reloadable idle");
    expect(third.isDisposed).toBe(true);
    expect(draft.isDisposed).toBe(false);
  });

  it("deduplicates same-session starts and starts distinct sessions concurrently", async () => {
    const root = await temporaryRoot("tron-concurrent-cold-starts-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const sessionDirectory = join(agentDir, "sessions", "workspace");
    await Promise.all([mkdir(sessionDirectory, { recursive: true }), mkdir(cwd, { recursive: true })]);
    process.env.PI_CODING_AGENT_DIR = agentDir;
    const firstManager = SessionManager.create(cwd, sessionDirectory);
    firstManager.appendMessage(fauxAssistantMessage("first cold start"));
    const secondManager = SessionManager.create(cwd, sessionDirectory);
    secondManager.appendMessage(fauxAssistantMessage("second cold start"));
    let entered = 0;
    let release!: () => void;
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const runtimeFactory = vi.fn(async () => {
      entered += 1;
      await gate;
      return ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    });
    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      maximumLiveRuntimes: 2,
      modelRuntimeFactory: runtimeFactory,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    await registry.catalog("all");

    const first = registry.acquire(firstManager.getSessionId());
    const duplicate = registry.acquire(firstManager.getSessionId());
    const second = registry.acquire(secondManager.getSessionId());
    await waitFor(() => entered === 2, "both slots to enter");
    expect(runtimeFactory).toHaveBeenCalledTimes(2);
    await expect(registry.create(cwd)).rejects.toMatchObject({ code: "busy", retryable: true });
    expect(runtimeFactory).toHaveBeenCalledTimes(2);
    release();
    const [firstSlot, duplicateSlot, secondSlot] = await Promise.all([first, duplicate, second]);
    expect(duplicateSlot).toBe(firstSlot);
    expect(secondSlot.id).toBe(secondManager.getSessionId());
  });

  it("reads only the admitted file's own header when a cold open has no cached admission", async () => {
    const fixture = await coldFixture("uncached");
    await settleCatalog(fixture.registry);
    const walks = catalogWalks();
    const before = walks.count();
    const headers = catalogHeaderReads();
    try {
      expect((await fixture.registry.acquire(fixture.manager.getSessionId())).id).toBe(fixture.manager.getSessionId());
      expect(fixture.runtimeFactory).toHaveBeenCalledTimes(1);
      expect(walks.count()).toBe(before);
      expect(headers.paths().length).toBeGreaterThan(0);
      expect(new Set(headers.paths().map((path) => basename(path)))).toEqual(new Set([basename(fixture.sessionFile)]));
    } finally {
      walks.restore();
      headers.restore();
    }
  });

  it("ignores jsonl-named directories during lightweight acquisition", async () => {
    const fixture = await coldFixture("jsonl-directory");
    await mkdir(join(fixture.agentDir, "sessions", "unrelated.jsonl"));
    await settleCatalog(fixture.registry);
    const walks = catalogWalks();
    const before = walks.count();
    try {
      expect((await fixture.registry.acquire(fixture.manager.getSessionId())).id)
        .toBe(fixture.manager.getSessionId());
      expect((await fixture.registry.catalog("all")).sessions.map((session) => session.id))
        .toEqual([fixture.manager.getSessionId()]);
      expect(walks.count()).toBe(before);
    } finally {
      walks.restore();
    }
  });

  it("keeps an unprovable artifact out of the index without blinding the cut", async () => {
    const reconciled: SessionCatalogReconcileOutcome[] = [];
    const fixture = await coldFixture("ignored-artifacts", { catalogReconciled: (outcome) => reconciled.push(outcome) });
    const artifactDirectory = join(fixture.agentDir, "sessions", "workspace", "subagent-artifacts");
    await mkdir(artifactDirectory, { recursive: true });
    await writeFile(join(artifactDirectory, "worker.jsonl"), `${JSON.stringify({ recordType: "message", text: "diagnostic" })}\n`);
    reconciled.length = 0;
    await settleCatalog(fixture.registry);

    const listed = await fixture.registry.catalog("all");
    expect(listed.sessions.map((session) => session.id)).toEqual([fixture.manager.getSessionId()]);
    expect(reconciled.at(-1)).toMatchObject({ outcome: "reconciled" });

    const walks = catalogWalks();
    const before = walks.count();
    try {
      expect((await fixture.registry.catalog("all")).sessions.map((session) => session.id))
        .toEqual([fixture.manager.getSessionId()]);
      expect(walks.count()).toBe(before);
    } finally {
      walks.restore();
    }
  });

    it("keeps an unrelated malformed header out of the cut without a fallback scan", async () => {
    const reconciled: SessionCatalogReconcileOutcome[] = [];
    const fixture = await coldFixture("malformed-fallback", { catalogReconciled: (outcome) => reconciled.push(outcome) });
    const unrelated = join(fixture.agentDir, "sessions", "unrelated");
    await mkdir(unrelated, { recursive: true });
    await writeFile(join(unrelated, "malformed.jsonl"), `${"x".repeat(70_000)}\n`);
    reconciled.length = 0;
    await settleCatalog(fixture.registry);
    const walks = catalogWalks();
    try {
      expect((await fixture.registry.acquire(fixture.manager.getSessionId())).id)
        .toBe(fixture.manager.getSessionId());
      expect(reconciled.at(-1)).toMatchObject({ outcome: "incomplete" });
      expect(reconciled.at(-1)!.unproven).toBeGreaterThan(0);
      expect(catalogOwner(fixture.registry).hasReconciledCut()).toBe(false);
      expect((await fixture.registry.catalog("all")).sessions.map((session) => session.id))
        .toEqual([fixture.manager.getSessionId()]);
      expect(walks.count()).toBe(0);
    } finally {
      walks.restore();
    }
  });

    it("invalidates reusable acquisition when a duplicate or removal changes canonical membership", async () => {
    const duplicateFixture = await coldFixture("duplicate-membership");
    await settleCatalog(duplicateFixture.registry);
    const duplicateDirectory = join(duplicateFixture.agentDir, "sessions", "duplicate");
    await mkdir(duplicateDirectory, { recursive: true });
    await copyFile(
      duplicateFixture.sessionFile,
      join(duplicateDirectory, "duplicate.jsonl"),
    );
    await settleCatalog(duplicateFixture.registry);
    expect((await duplicateFixture.registry.catalog("all")).sessions).toHaveLength(0);

    await expect(duplicateFixture.registry.acquire(duplicateFixture.manager.getSessionId())).rejects.toMatchObject({
      code: "conflict",
    });
    expect(duplicateFixture.runtimeFactory).not.toHaveBeenCalled();
    await rm(join(duplicateDirectory, "duplicate.jsonl"));
    await settleCatalog(duplicateFixture.registry);
    expect((await duplicateFixture.registry.acquire(duplicateFixture.manager.getSessionId())).id)
      .toBe(duplicateFixture.manager.getSessionId());
    const duplicateAgain = join(duplicateDirectory, "duplicate-again.jsonl");
    await copyFile(duplicateFixture.sessionFile, duplicateAgain);
    await settleCatalog(duplicateFixture.registry);
    await expect(duplicateFixture.registry.acquire(duplicateFixture.manager.getSessionId())).rejects.toMatchObject({
      code: "conflict",
    });
    await rm(duplicateAgain);
    await settleCatalog(duplicateFixture.registry);
    expect((await duplicateFixture.registry.acquire(duplicateFixture.manager.getSessionId())).id)
      .toBe(duplicateFixture.manager.getSessionId());

    const removedFixture = await coldFixture("removed-membership");
    await settleCatalog(removedFixture.registry);
    await rm(removedFixture.sessionFile);
    await settleCatalog(removedFixture.registry);

    await expect(removedFixture.registry.acquire(removedFixture.manager.getSessionId())).rejects.toMatchObject({
      code: "not_found",
    });
    expect(removedFixture.runtimeFactory).not.toHaveBeenCalled();
  });

  it("recognizes only the exact delegated-session producer topology", async () => {
    const fixture = await coldFixture("delegated-topology");
    const root = join(fixture.agentDir, "sessions", "topology");
    const timestamp = new Date().toISOString();
    const header = (id: string, parentSession?: string) => `${JSON.stringify({
      type: "session", version: 3, id, timestamp, cwd: fixture.cwd,
      ...(parentSession ? { parentSession } : {}),
    })}\n`;
    const parent = join(root, "parent.jsonl");
    const topLevelParented = join(root, "ordinary-fork.jsonl");
    const fork = join(root, "parent", "forks", "fork.jsonl");
    const fresh = join(root, "parent", "worker", "run-0", "session.jsonl");
    const interrupted = join(root, "parent", "reviewer", "run-1", "session.jsonl");
    const contradictory = join(root, "parent", "worker", "run-2", "session.jsonl");
    const extraDepthRun = join(root, "parent", "worker", "run-3", "extra", "session.jsonl");
    const extraDepthFork = join(root, "parent", "forks", "extra", "fork.jsonl");
    const wrongRunBasename = join(root, "parent", "worker", "run-4", "child.jsonl");
    const arbitraryDeep = join(root, "parent", "arbitrary", "deep", "session.jsonl");
    await Promise.all([...new Set([parent, fork, fresh, interrupted, contradictory,
      extraDepthRun, extraDepthFork, wrongRunBasename, arbitraryDeep, topLevelParented]
      .map((path) => dirname(path)))].map((directory) => mkdir(directory, { recursive: true })));
    await Promise.all([
      writeFile(parent, header("parent")),
      writeFile(topLevelParented, header("ordinary", parent)),
      writeFile(fork, header("fork", parent)),
      writeFile(fresh, header("fresh")),
      writeFile(interrupted, header("interrupted")),
      writeFile(contradictory, header("contradictory", topLevelParented)),
      writeFile(extraDepthRun, header("extra-run")),
      writeFile(extraDepthFork, header("extra-fork", parent)),
      writeFile(wrongRunBasename, header("wrong-basename")),
      writeFile(arbitraryDeep, header("deep")),
    ]);

    await settleCatalog(fixture.registry);
    const rows = new Map((await fixture.registry.catalog("all")).sessions.map((row) => [row.id, row]));
    expect(rows.get("fork")).toMatchObject({ kind: "subagent", parentSessionId: "parent" });
    expect(rows.get("fresh")).toMatchObject({ kind: "subagent" });
    expect(rows.get("fresh")?.parentSessionId).toBeUndefined();
    expect(rows.get("interrupted")?.kind).toBe("subagent");
    for (const id of ["extra-run", "extra-fork", "wrong-basename", "deep", "ordinary"]) {
      expect(rows.get(id)?.kind).toBe("user");
    }
    expect(rows.has("contradictory")).toBe(false);
    expect(existsSync(contradictory)).toBe(true);
    await expect(fixture.registry.acquire("contradictory")).rejects.toMatchObject({ code: "conflict" });
    await expect(fixture.registry.delete("contradictory")).rejects.toMatchObject({ code: "conflict" });
  });

  it("does not infer delegated identity from names, titles, or generic depth", async () => {
    const nestedFixture = await coldFixture("nested-user", { nested: true });
    expect((await nestedFixture.registry.catalog("all")).sessions.find(
      (session) => session.id === nestedFixture.manager.getSessionId(),
    )?.kind).toBe("user");
    expect((await nestedFixture.registry.acquire(nestedFixture.manager.getSessionId())).id)
      .toBe(nestedFixture.manager.getSessionId());

    const namedFixture = await coldFixture("named-user", { name: "subagent-catalog-child" });
    expect((await namedFixture.registry.acquire(namedFixture.manager.getSessionId())).id)
      .toBe(namedFixture.manager.getSessionId());

    const renamedFixture = await coldFixture("renamed-user");
    const beforeRename = await renamedFixture.registry.catalog("all");
    renamedFixture.manager.appendSessionInfo("subagent-renamed-after-catalog");
    expect((await renamedFixture.registry.catalog("all")).listRevision).toBe(beforeRename.listRevision);
    expect((await renamedFixture.registry.acquire(renamedFixture.manager.getSessionId())).id)
      .toBe(renamedFixture.manager.getSessionId());
  });

  it("rejects identity, cwd, or duplicate mutation before runtime creation", async () => {
    for (const field of ["id", "cwd"] as const) {
      const fixture = await coldFixture(`${field}-race`);
      await fixture.registry.catalog("all");
      const replacementCwd = join(fixture.root, "replacement-workspace");
      await mkdir(replacementCwd);
      const internals = fixture.registry as unknown as {
        catalogAcquisition: () => Promise<unknown>;
      };
      const original = internals.catalogAcquisition.bind(fixture.registry);
      const admission = vi.spyOn(internals, "catalogAcquisition").mockImplementation(async () => {
        const acquired = await original();
        const lines = (await readFile(fixture.sessionFile, "utf8")).split("\n");
        const header = JSON.parse(lines[0]!) as Record<string, unknown>;
        lines[0] = JSON.stringify({
          ...header,
          [field]: field === "id" ? "replacement-session-id" : replacementCwd,
        });
        await writeFile(fixture.sessionFile, lines.join("\n"));
        return acquired;
      });

      try {
        await expect(fixture.registry.acquire(fixture.manager.getSessionId())).rejects.toMatchObject({
          code: "conflict",
        });
        expect(fixture.runtimeFactory).not.toHaveBeenCalled();
      } finally {
        admission.mockRestore();
      }
    }

    const duplicateFixture = await coldFixture("duplicate-race");
    await settleCatalog(duplicateFixture.registry);
    const duplicateDirectory = join(duplicateFixture.agentDir, "sessions", "duplicate-gap");
    await mkdir(duplicateDirectory, { recursive: true });
    await copyFile(duplicateFixture.sessionFile, join(duplicateDirectory, "duplicate.jsonl"));
    await settleCatalog(duplicateFixture.registry);
    await expect(duplicateFixture.registry.acquire(duplicateFixture.manager.getSessionId()))
      .rejects.toMatchObject({ code: "conflict" });
    expect(duplicateFixture.runtimeFactory).not.toHaveBeenCalled();
  });

  it("opens a cold session while unrelated catalog files appear in the admission gap", async () => {
    const fixture = await coldFixture("unrelated-open-churn");
    await fixture.registry.catalog("all");
    const internals = fixture.registry as unknown as { catalogAcquisition: () => Promise<unknown> };
    const original = internals.catalogAcquisition.bind(fixture.registry);
    const admission = vi.spyOn(internals, "catalogAcquisition").mockImplementation(async () => {
      const acquired = await original();
      const childDirectory = join(fixture.agentDir, "sessions", "active-parent", "worker", "run-0");
      await mkdir(childDirectory, { recursive: true });
      await writeFile(join(fixture.agentDir, "sessions", "active-parent.jsonl"), `${JSON.stringify({
        type: "session", version: 3, id: "active-parent", timestamp: new Date().toISOString(), cwd: fixture.cwd,
      })}\n`);
      await writeFile(join(childDirectory, "session.jsonl"), `${JSON.stringify({
        type: "session", version: 3, id: "active-child", timestamp: new Date().toISOString(), cwd: fixture.cwd,
      })}\n`);
      return acquired;
    });
    try {
      expect((await fixture.registry.acquire(fixture.manager.getSessionId())).id).toBe(fixture.manager.getSessionId());
      expect(fixture.runtimeFactory).toHaveBeenCalledTimes(1);
    } finally {
      admission.mockRestore();
    }
  });

  it("reports a deletion whose session file could not be restored instead of a retryable conflict", async () => {
    const fixture = await coldFixture("delete-restore-refused");
    await settleCatalog(fixture.registry);
    quarantineLock.armed = true;
    let outcome: unknown;
    try {
      outcome = await fixture.registry.delete(fixture.manager.getSessionId()).then(() => "deleted", error => error);
    } finally {
      quarantineLock.armed = false;
      if (quarantineLock.directory) await fsPromises.chmod(quarantineLock.directory, 0o700);
    }
    expect(quarantineLock.directory).toBe(await realpath(dirname(fixture.sessionFile)));
    expect(outcome).toMatchObject({ code: "conflict", retryable: false,
      message: "Tron session deletion failed and its file could not be restored; it remains beside the original as a .tron-delete file" });
    expect(((outcome as Error).cause as AggregateError).errors.map(error => (error as NodeJS.ErrnoException).code)).toEqual(["EACCES", "EACCES"]);
    expect(existsSync(fixture.sessionFile)).toBe(false);
    expect((await readdir(dirname(fixture.sessionFile))).filter(name => name.startsWith(`${basename(fixture.sessionFile)}.tron-delete-`))).toHaveLength(1);
  });

  it("does not follow a session path replaced by a symlink during delete", async () => {
    const fixture = await coldFixture("delete-symlink-race");
    await settleCatalog(fixture.registry);
    const moved = `${fixture.sessionFile}.moved`;
    const external = join(fixture.root, "external.jsonl");
    const externalContent = `${JSON.stringify({
      type: "session", version: 3, id: fixture.manager.getSessionId(),
      timestamp: new Date().toISOString(), cwd: fixture.cwd,
    })}\n`;
    await writeFile(external, externalContent);
    await rename(fixture.sessionFile, moved);
    await symlink(external, fixture.sessionFile);

    await expect(fixture.registry.delete(fixture.manager.getSessionId())).rejects.toMatchObject({
      code: "conflict",
    });
    expect(await readFile(external, "utf8")).toBe(externalContent);
    expect(existsSync(moved)).toBe(true);
  });

  it("revalidates parent creation, duplicate identity, and topology changes in the delete gap", async () => {
    for (const mutation of ["parent", "duplicate", "topology"] as const) {
      const fixture = await coldFixture(`delete-catalog-gap-${mutation}`);
      await settleCatalog(fixture.registry);
      const mutationDirectory = join(fixture.agentDir, "sessions", `delete-gap-${mutation}`);
      const movedFile = join(mutationDirectory, "owner", "worker", "run-0", "session.jsonl");
      const internals = fixture.registry as unknown as {
        removeCanonicalCatalogFile: (...arguments_: any[]) => Promise<void>;
      };
      const original = internals.removeCanonicalCatalogFile.bind(fixture.registry);
      vi.spyOn(internals, "removeCanonicalCatalogFile").mockImplementation(async (...arguments_) => {
        await mkdir(mutationDirectory, { recursive: true });
        if (mutation === "parent") {
          await writeFile(join(mutationDirectory, "new-parent.jsonl"), `${JSON.stringify({
            type: "session", version: 3, id: "new-parent", timestamp: new Date().toISOString(), cwd: fixture.cwd,
          })}\n`);
        } else if (mutation === "duplicate") {
          await copyFile(fixture.sessionFile, join(mutationDirectory, "duplicate.jsonl"));
          await settleCatalog(fixture.registry);
        } else {
          await mkdir(dirname(movedFile), { recursive: true });
          await rename(fixture.sessionFile, movedFile);
        }
        return original(...arguments_);
      });

      if (mutation === "parent") {
        await fixture.registry.delete(fixture.manager.getSessionId());
        expect(existsSync(fixture.sessionFile)).toBe(false);
      } else {
        await expect(fixture.registry.delete(fixture.manager.getSessionId())).rejects.toMatchObject({
          code: mutation === "duplicate" ? "conflict" : "not_found",
        });
        expect(existsSync(mutation === "topology" ? movedFile : fixture.sessionFile)).toBe(true);
      }
    }
  });

  it("retains persisted, ambiguous, and live-only artifact owners without reading transcript metadata", async () => {
    const fixture = await coldFixture("maintenance-header-membership");
    const parentFile = fixture.manager.getSessionFile()!;
    const forks = join(dirname(parentFile), basename(parentFile, ".jsonl"), "forks");
    await mkdir(forks, { recursive: true });
    const child = SessionManager.forkFrom(parentFile, fixture.cwd, forks);
    child.appendMessage(fauxAssistantMessage("child"));
    await appendFile(child.getSessionFile()!, '{"type":"message"}\n');
    await copyFile(parentFile, join(forks, "ambiguous.jsonl"));
    const live = await fixture.registry.create(fixture.cwd);
    await settleCatalog(fixture.registry);
    const walks = catalogWalks();
    const before = walks.count();
    try {
      const ids = await fixture.registry.sessionIDsForStorageMaintenance();
      expect([...ids].sort()).toEqual([fixture.manager.getSessionId(), child.getSessionId(), live.id].sort());
      expect(walks.count()).toBe(before);
      await writeFile(join(dirname(parentFile), "incomplete-header.jsonl"), "{}");
      await settleCatalog(fixture.registry);
      await expect(fixture.registry.sessionIDsForStorageMaintenance())
        .rejects.toMatchObject({ code: "busy", retryable: true });
      expect(walks.count()).toBeGreaterThan(before);
    } finally { walks.restore(); }
  });

      it("scans only canonical user metadata for a user catalog and reserves all-scope indexing", async () => {
    const fixture = await coldFixture("user-metadata-cut");
    const parentFile = fixture.manager.getSessionFile()!;
    const forksDirectory = join(dirname(parentFile), basename(parentFile, ".jsonl"), "forks");
    await mkdir(forksDirectory, { recursive: true });
    const child = SessionManager.forkFrom(parentFile, fixture.cwd, forksDirectory);
    child.appendMessage(fauxAssistantMessage("delegated body that user catalog must not materialize"));

    await settleCatalog(fixture.registry);
    const walks = catalogWalks();
    const before = walks.count();
    try {
      const user = await fixture.registry.catalog("user");
      expect(user.sessions.map((session) => session.id)).toEqual([fixture.manager.getSessionId()]);
      const all = await fixture.registry.catalog("all");
      expect(all.sessions.map((session) => session.id)).toEqual(
        expect.arrayContaining([fixture.manager.getSessionId(), child.getSessionId()]),
      );
      expect(walks.count()).toBe(before);
    } finally {
      walks.restore();
    }
  });

    it("uses complete headers to quarantine user IDs duplicated by delegated files", async () => {
    const fixture = await coldFixture("user-duplicate-delegated");
    const parentFile = fixture.manager.getSessionFile()!;
    const forksDirectory = join(dirname(parentFile), basename(parentFile, ".jsonl"), "forks");
    await mkdir(forksDirectory, { recursive: true });
    const duplicatePath = join(forksDirectory, "duplicate.jsonl");
    await copyFile(parentFile, duplicatePath);

    await settleCatalog(fixture.registry);
    const user = await fixture.registry.catalog("user");
    expect(user.sessions.find((session) => session.id === fixture.manager.getSessionId())).toBeUndefined();
    const allDuplicate = await fixture.registry.catalog("all");
    expect(allDuplicate.sessions.find((session) => session.id === fixture.manager.getSessionId())).toBeUndefined();
    await expect(fixture.registry.acquire(fixture.manager.getSessionId()))
      .rejects.toMatchObject({ code: "conflict" });

    await rm(duplicatePath);
    const child = SessionManager.forkFrom(parentFile, fixture.cwd, forksDirectory);
    child.appendMessage(fauxAssistantMessage("contradictory delegated header"));
    const childFile = child.getSessionFile()!;
    const childLines = (await readFile(childFile, "utf8")).split("\n");
    childLines[0] = JSON.stringify({ ...JSON.parse(childLines[0]!), parentSession: join(fixture.agentDir, "sessions", "not-the-parent.jsonl") });
    await writeFile(childFile, childLines.join("\n"));
    await settleCatalog(fixture.registry);

    const repairedUser = await fixture.registry.catalog("user");
    expect(repairedUser.sessions.map((session) => session.id)).toContain(fixture.manager.getSessionId());
    const all = await fixture.registry.catalog("all");
    expect(all.sessions.map((session) => session.id)).not.toContain(child.getSessionId());
  });

  it("retains user catalog and search admission while parallel delegated sessions append", async () => {
    const fixture = await coldFixture("user-index-parallel-children");
    const parentFile = fixture.manager.getSessionFile()!;
    const forks = join(dirname(parentFile), basename(parentFile, ".jsonl"), "forks");
    await mkdir(forks, { recursive: true });
    const children = Array.from({ length: 3 }, () => SessionManager.forkFrom(parentFile, fixture.cwd, forks));
    children.forEach(child => child.appendMessage(fauxAssistantMessage("child starts")));
    const parentID = fixture.manager.getSessionId();
    const walks = catalogWalks();
    const before = walks.count();
    try {
      expect((await fixture.registry.catalog("user")).sessions.map(row => row.id)).toEqual([parentID]);
      children.forEach(child => child.appendMessage(fauxAssistantMessage("parallel child progress")));
      await settleCatalog(fixture.registry);
      const live = await fixture.registry.create(fixture.cwd);
      const results = await Promise.all([
        fixture.registry.catalog("user"), fixture.registry.catalog("user"), fixture.registry.readSearchCut(parentID),
      ]);
      for (const result of results.slice(0, 2) as Awaited<ReturnType<RuntimeRegistry["catalog"]>>[]) {
        expect(result.sessions.map(row => row.id)).toEqual(expect.arrayContaining([parentID, live.id]));
        expect(result.sessions).toHaveLength(2);
      }
      expect(results[2]).toMatchObject({ summary: { id: parentID } });
      const settled = walks.count();
      const all = await fixture.registry.catalog("all");
      expect(all.sessions.map(row => row.id)).toEqual(expect.arrayContaining(children.map(child => child.getSessionId())));
      expect(walks.count()).toBe(settled);
      expect(settled).toBeGreaterThan(before);
    } finally { walks.restore(); }
  });

  it("refreshes user metadata and duplicate quarantine after a scoped cut is warm", async () => {
    const fixture = await coldFixture("scoped-index-refresh");
    const parentFile = fixture.manager.getSessionFile()!;
    const forks = join(dirname(parentFile), basename(parentFile, ".jsonl"), "forks");
    await mkdir(forks, { recursive: true });
    const child = SessionManager.forkFrom(parentFile, fixture.cwd, forks);
    child.appendMessage(fauxAssistantMessage("child"));
    const parentID = fixture.manager.getSessionId();
    await settleCatalog(fixture.registry);
    const initialPage = await fixture.registry.pageSource("user");
    fixture.manager.appendSessionInfo("Updated canonical name");
    await settleCatalog(fixture.registry);
    const refreshedPage = await fixture.registry.pageSource("user");
    expect(refreshedPage).not.toBe(initialPage);
    expect((await refreshedPage.page(0, 500)).find(row => row.id === parentID)?.name).toBe("Updated canonical name");
    await copyFile(parentFile, join(forks, "duplicate.jsonl"));
    await settleCatalog(fixture.registry);
    expect((await fixture.registry.catalog("user")).sessions.some(row => row.id === parentID)).toBe(false);
    await expect(fixture.registry.acquire(parentID)).rejects.toMatchObject({ code: "conflict" });
  });

  it("advances user catalog identity when canonical membership changes beside delegated rows", async () => {
    const fixture = await coldFixture("user-membership-revision");
    const parentFile = fixture.manager.getSessionFile()!;
    const forksDirectory = join(dirname(parentFile), basename(parentFile, ".jsonl"), "forks");
    await mkdir(forksDirectory, { recursive: true });
    const child = SessionManager.forkFrom(parentFile, fixture.cwd, forksDirectory);
    child.appendMessage(fauxAssistantMessage("delegated membership fixture"));

    await settleCatalog(fixture.registry);
    const initial = await fixture.registry.pageSource("user");
    const secondDirectory = join(fixture.agentDir, "sessions", "second");
    await mkdir(secondDirectory, { recursive: true });
    const second = SessionManager.create(fixture.cwd, secondDirectory);
    second.appendMessage(fauxAssistantMessage("new canonical user session"));
    await settleCatalog(fixture.registry);
    const added = await fixture.registry.pageSource("user");
    expect(added.generation).not.toBe(initial.generation);
    expect((await fixture.registry.catalog("user")).sessions.map((session) => session.id))
      .toContain(second.getSessionId());

    await rm(second.getSessionFile()!);
    await settleCatalog(fixture.registry);
    const removed = await fixture.registry.pageSource("user");
    expect(removed.generation).not.toBe(added.generation);
    expect((await fixture.registry.catalog("user")).sessions.map((session) => session.id))
      .not.toContain(second.getSessionId());
  });

  it("reports files over the header budget as unproven and refuses an over-budget acquisition retryably", async () => {
    const fixture = await coldFixture("header-bound");
    const reconciled: SessionCatalogReconcileOutcome[] = [];
    const headerRegistry = await createTestRegistry({
      agentDir: fixture.agentDir,
      tronHome: join(fixture.root, "tron-header-bound"),
      idleRuntimeMs: 60_000,
      trust: new TrustService(fixture.agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
      catalogDiscoveryLimits: { maximumHeaderBytes: 1 },
      catalogReconciled: (outcome) => reconciled.push(outcome),
    });
    registries.push(headerRegistry);
    const walks = catalogWalks();
    try {
      await headerRegistry.initialize();
      await catalogOwner(headerRegistry).whenReconciled();
      expect(reconciled.at(-1)).toMatchObject({ outcome: "incomplete" });
      expect(reconciled.at(-1)!.unproven).toBe(1);
      expect((await headerRegistry.catalog("all")).sessions).toEqual([]);
      const settled = walks.count();
      expect((await headerRegistry.catalog("all")).sessions).toEqual([]);
      expect(walks.count()).toBe(settled);
    } finally {
      walks.restore();
    }

    const admissionRegistry = await createTestRegistry({
      agentDir: fixture.agentDir,
      tronHome: join(fixture.root, "tron-admission-bound"),
      idleRuntimeMs: 60_000,
      trust: new TrustService(fixture.agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
      catalogDiscoveryLimits: { maximumAcquisitionBytes: 1 },
    });
    registries.push(admissionRegistry);
    await admissionRegistry.initialize();
    await catalogOwner(admissionRegistry).whenReconciled();
    expect((await admissionRegistry.catalog("all")).sessions).toEqual([]);
    await expect(admissionRegistry.acquire(fixture.manager.getSessionId()))
      .rejects.toMatchObject({ code: "busy", retryable: true, diagnosticReason: "catalog_not_ready" });
  });

  it("admits scaled short headers within the aggregate validation budget", async () => {
    const root = await temporaryRoot("tron-catalog-short-header-budget-");
    const agentDir = join(root, "agent");
    const directory = join(agentDir, "sessions", "workspace");
    const cwd = join(root, "workspace");
    const count = 64;
    await Promise.all([mkdir(directory, { recursive: true }), mkdir(cwd)]);
    await Promise.all(Array.from({ length: count }, (_, index) => writeFile(
      join(directory, `session-${index}.jsonl`),
      `${JSON.stringify({
        type: "session",
        version: 3,
        id: `session-${index}`,
        timestamp: "2026-01-01T00:00:00.000Z",
        cwd,
      })}\n${"x".repeat(4_096)}\n`,
    )));
    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
      catalogDiscoveryLimits: {
        maximumSessions: count,
        maximumHeaderBytes: count * 512,
        normalizationConcurrency: 4,
      },
    });
    registries.push(registry);
    const original = CatalogDiscovery.prototype.readCatalogHeader;
    let active = 0;
    let maximumActive = 0;
    let releaseResolve!: () => void;
    let capacityResolve!: () => void;
    const release = new Promise<void>((resolve) => { releaseResolve = resolve; });
    const capacity = new Promise<void>((resolve) => { capacityResolve = resolve; });
    const headers = vi.spyOn(CatalogDiscovery.prototype, "readCatalogHeader").mockImplementation(
      async function (this: CatalogDiscovery, ...arguments_: Parameters<CatalogDiscovery["readCatalogHeader"]>) {
        active += 1;
        maximumActive = Math.max(maximumActive, active);
        if (maximumActive === 4) capacityResolve();
        await release;
        try { return await original.apply(this, arguments_); }
        finally { active -= 1; }
      },
    );

    const discovery = new CatalogDiscovery({
      limits: {
        ...DEFAULT_CATALOG_DISCOVERY_LIMITS,
        maximumSessions: count,
        maximumHeaderBytes: count * 512,
        normalizationConcurrency: 4,
      },
      catalogDirectory: () => directory,
      catalogCapacityExceeded: () => { throw new Error("scaled catalog bound exceeded"); },
      isLiveRuntimeOwnedPath: () => false,
      canonicalSessionPath: (path) => realpath(path),
      delegatedTopologyParentPath: () => undefined,
    });
    const evidence = discovery.catalogStructureEvidence();
    await capacity;
    expect(maximumActive).toBe(4);
    releaseResolve();
    expect((await evidence).identitiesByPath.size).toBe(count);
    expect(headers).toHaveBeenCalledTimes(count);
    headers.mockRestore();
    await initializeRegistry(registry);
    expect((await registry.catalog("all")).sessions).toHaveLength(count);
  });

  it("keeps a child mutation-protected when its parent ID is duplicated", async () => {
    const root = await temporaryRoot("tron-catalog-duplicate-parent-");
    const agentDir = join(root, "agent");
    const directory = join(agentDir, "sessions", "workspace");
    const duplicateDirectory = join(agentDir, "sessions", "duplicate-workspace");
    const cwd = join(root, "workspace");
    await Promise.all([
      mkdir(directory, { recursive: true }),
      mkdir(duplicateDirectory, { recursive: true }),
      mkdir(cwd),
    ]);
    const timestamp = new Date().toISOString();
    const parentId = "ambiguous-parent";
    const parentFile = join(directory, `${parentId}.jsonl`);
    const header = `${JSON.stringify({ type: "session", version: 3, id: parentId, timestamp, cwd })}\n`;
    await Promise.all([
      writeFile(parentFile, header),
      writeFile(join(duplicateDirectory, "duplicate.jsonl"), header),
    ]);
    const childDirectory = join(directory, parentId, "worker", "run-0");
    await mkdir(childDirectory, { recursive: true });
    const childId = "child-of-ambiguous-parent";
    await writeFile(join(childDirectory, "session.jsonl"), `${JSON.stringify({
      type: "session", version: 3, id: childId, timestamp, cwd,
    })}\n`);
    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);

    await initializeRegistry(registry);
    await settleCatalog(registry);
    const all = await registry.catalog("all");
    expect(all.sessions.map((session) => session.id)).not.toContain(parentId);
    expect(all.sessions.find((session) => session.id === childId)).toMatchObject({ kind: "subagent" });
    await expect(registry.acquire(childId)).rejects.toMatchObject({ code: "conflict" });
    await expect(registry.delete(childId)).rejects.toMatchObject({ code: "conflict" });
  });

  it("omits a reserved child with a contradictory parent header without making it mutable", async () => {
    const root = await temporaryRoot("tron-catalog-contradictory-header-");
    const agentDir = join(root, "agent");
    const directory = join(agentDir, "sessions", "workspace");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(directory, { recursive: true }), mkdir(cwd)]);
    const timestamp = new Date().toISOString();
    const parentId = "expected-parent";
    const parentFile = join(directory, `${parentId}.jsonl`);
    const otherParentFile = join(directory, "other-parent.jsonl");
    await Promise.all([
      writeFile(parentFile, `${JSON.stringify({ type: "session", version: 3, id: parentId, timestamp, cwd })}\n`),
      writeFile(otherParentFile, `${JSON.stringify({
        type: "session", version: 3, id: "other-parent", timestamp, cwd,
      })}\n`),
    ]);
    const childDirectory = join(directory, parentId, "worker", "run-0");
    await mkdir(childDirectory, { recursive: true });
    const childId = "contradictory-child";
    const childFile = join(childDirectory, "session.jsonl");
    await writeFile(childFile, `${JSON.stringify({
      type: "session", version: 3, id: childId, timestamp, cwd, parentSession: otherParentFile,
    })}\n`);
    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);

    await initializeRegistry(registry);
    await settleCatalog(registry);
    expect((await registry.catalog("all")).sessions.map((session) => session.id)).not.toContain(childId);
    const acquisition = await (registry as unknown as {
      catalogAcquisition: () => Promise<{
        entriesByID: ReadonlyMap<string, { structuralSubagent: boolean }>;
      }>;
    }).catalogAcquisition();
    expect(acquisition.entriesByID.get(childId)?.structuralSubagent).toBe(true);
    await expect(registry.acquire(childId)).rejects.toMatchObject({ code: "conflict" });
    await expect(registry.delete(childId)).rejects.toMatchObject({ code: "conflict" });
    expect(existsSync(childFile)).toBe(true);
  });

  it.each(["cut", "row refresh"])("keeps reserved children out of user search and mutation after the catalog root alias is retargeted (%s)", async (read) => {
    let alias = "";
    let originalRoot = "";
    const fixture = await coldFixture("retargeted-root-role", {
      beforeInitialize: async sessionFile => {
        alias = dirname(dirname(sessionFile));
        originalRoot = `${alias}-original`;
        await rename(alias, originalRoot);
        await symlink(originalRoot, alias);
      },
    });
    const nextRoot = `${alias}-replacement`;
    const directory = join(nextRoot, "workspace");
    const parentId = randomUUID();
    const childId = randomUUID();
    const parentFile = join(directory, `${parentId}.jsonl`);
    const childDirectory = join(directory, parentId, "worker", "run-0");
    const childFile = join(childDirectory, "session.jsonl");
    await mkdir(childDirectory, { recursive: true });
    const timestamp = new Date().toISOString();
    await Promise.all([
      writeFile(parentFile, `${JSON.stringify({ type: "session", version: 3, id: parentId, timestamp, cwd: fixture.cwd })}\n`),
      writeFile(childFile, `${JSON.stringify({ type: "session", version: 3, id: childId, timestamp, cwd: fixture.cwd })}\n`),
    ]);
    await rm(alias);
    await symlink(nextRoot, alias);
    if (read === "row refresh") {
      await catalogOwner(fixture.registry).refresh(childFile);
      await catalogOwner(fixture.registry).settled();
    } else await settleCatalog(fixture.registry);
    const identities = await fixture.registry.searchCatalogIdentities();
    const searchIncludesChild = identities?.has(childId);
    const deleteOutcome = await fixture.registry.delete(childId).then(
      () => "deleted",
      (error: unknown) => error instanceof Error && "code" in error ? String(error.code) : "unexpected-error",
    );
    expect({ searchIncludesChild, deleteOutcome, childPreserved: existsSync(childFile) })
      .toEqual({ searchIncludesChild: false, deleteOutcome: "conflict", childPreserved: true });
    expect(existsSync(originalRoot)).toBe(true);
  });

  it("publishes a root-only role change to user catalog clients and its durable owner index", async () => {
    let alias = "";
    let originalRoot = "";
    let registry: RuntimeRegistry | undefined;
    let armed = false;
    const reconciledViews: Array<Promise<{ ids: string[]; revision: number; modified: number }>> = [];
    const fixture = await coldFixture("root-role-change", {
      beforeInitialize: async sessionFile => {
        alias = dirname(dirname(sessionFile));
        originalRoot = `${alias}-original`;
        await rename(alias, originalRoot);
        await symlink(originalRoot, alias);
        await rm(sessionFile, { force: true });
        const childDirectory = join(originalRoot, "workspace", "parent", "worker", "run-0");
        await mkdir(childDirectory, { recursive: true });
        const fixtureRoot = dirname(dirname(dirname(dirname(sessionFile))));
        await writeFile(join(childDirectory, "session.jsonl"), `${JSON.stringify({
          type: "session", version: 3, id: "orphan-role-change", timestamp: new Date().toISOString(),
          cwd: join(fixtureRoot, "workspace"),
        })}\n`);
      },
      catalogReconciled: outcome => {
        if (!armed || !registry) return;
        reconciledViews.push(registry.catalog("user").then(({ sessions, listRevision }) => ({
          ids: sessions.map(session => session.id), revision: listRevision, modified: outcome.modified,
        })));
      },
    });
    registry = fixture.registry;
    const childId = "orphan-role-change";
    await settleCatalog(registry);
    const before = await registry.catalog("user");
    expect(before.sessions.some(session => session.id === childId)).toBe(false);
    const initialIndex = new CatalogMetadataIndex(join(fixture.root, "tron", "cache"));
    expect((await initialIndex.load(originalRoot))?.some(row => row.id === childId)).toBe(true);

    const nextRoot = join(originalRoot, "workspace", "parent");
    await rm(alias);
    await symlink(nextRoot, alias);
    armed = true;
    await settleCatalog(registry);
    const observedViews = await Promise.all(reconciledViews);
    const after = await registry.catalog("user");
    const identities = await registry.searchCatalogIdentities();
    const currentIndex = await initialIndex.load(nextRoot);
    expect({
      clientSawChild: observedViews.at(-1)?.ids.includes(childId),
      publicSawChild: after.sessions.some(session => session.id === childId),
      ownerSearchSawChild: identities?.has(childId),
      revisionAdvanced: after.listRevision > before.listRevision,
      durableRootAccepted: currentIndex?.some(row => row.id === childId),
      roleChangeReported: observedViews.at(-1)?.modified,
      originalRootPreserved: existsSync(originalRoot),
    }).toEqual({
      clientSawChild: true, publicSawChild: true, ownerSearchSawChild: true,
      revisionAdvanced: true, durableRootAccepted: true, roleChangeReported: 1, originalRootPreserved: true,
    });
  });

  it.each(["cut", "row refresh"])("keeps an A-cut reserved child protected when the alias moves to B before publication (%s)", async (read) => {
    let alias = "";
    let originalRoot = "";
    const fixture = await coldFixture("retargeted-mid-cut", {
      beforeInitialize: async sessionFile => {
        alias = dirname(dirname(sessionFile));
        originalRoot = `${alias}-original`;
        await rename(alias, originalRoot);
        await symlink(originalRoot, alias);
      },
    });
    const nextRoot = `${alias}-replacement`;
    await mkdir(nextRoot, { recursive: true });
    const parentId = randomUUID();
    const childId = randomUUID();
    const childDirectory = join(originalRoot, "workspace", parentId, "worker", "run-0");
    const childFile = join(childDirectory, "session.jsonl");
    await mkdir(childDirectory, { recursive: true });
    await writeFile(childFile, `${JSON.stringify({
      type: "session", version: 3, id: childId, timestamp: new Date().toISOString(), cwd: fixture.cwd,
    })}\n`);
    await settleCatalog(fixture.registry);

    const originalScan = CatalogDiscovery.prototype.catalogStructureEvidence;
    let armed = true;
    const scan = vi.spyOn(CatalogDiscovery.prototype, "catalogStructureEvidence").mockImplementation(async function (this: CatalogDiscovery) {
      const evidence = await originalScan.call(this);
      if (armed) {
        armed = false;
        rmSync(alias);
        symlinkSync(nextRoot, alias);
      }
      return evidence;
    });
    let deleteOutcome: string;
    try {
      await settleCatalog(fixture.registry);
      if (read === "row refresh") await catalogOwner(fixture.registry).refresh(childFile);
      deleteOutcome = await fixture.registry.delete(childId).then(
        () => "deleted",
        (error: unknown) => error instanceof Error && "code" in error ? String(error.code) : "unexpected-error",
      );
    } finally {
      scan.mockRestore();
    }
    expect({ armed, deleteOutcome, childPreserved: existsSync(childFile), originalRootPreserved: existsSync(originalRoot) })
      .toEqual({ armed: false, deleteOutcome: "conflict", childPreserved: true, originalRootPreserved: true });
  });

  it("reads the pinned physical file when a row refresh's alias moves after realpath", async () => {
    let alias = "";
    let originalRoot = "";
    const fixture = await coldFixture("retargeted-row-read", {
      beforeInitialize: async sessionFile => {
        alias = dirname(dirname(sessionFile));
        originalRoot = `${alias}-original`;
        await rename(alias, originalRoot);
        await symlink(originalRoot, alias);
      },
    });
    const nextRoot = `${alias}-replacement`;
    const childRelative = join("workspace", "parent", "worker", "run-0", "session.jsonl");
    const childFile = join(originalRoot, childRelative);
    const otherFile = join(nextRoot, childRelative);
    const aliasFile = join(alias, childRelative);
    const header = (id: string) => `${JSON.stringify({
      type: "session", version: 3, id, timestamp: new Date().toISOString(), cwd: fixture.cwd,
    })}\n`;
    await mkdir(dirname(childFile), { recursive: true });
    await mkdir(dirname(otherFile), { recursive: true });
    await writeFile(childFile, header("before-pinned-read"));
    await writeFile(otherFile, header("other-root-child"));
    await settleCatalog(fixture.registry);

    const originalRealpath = fsPromises.realpath;
    let armed = true;
    const pathRead = vi.spyOn(fsPromises, "realpath").mockImplementation(async (...args) => {
      const physical = await originalRealpath(...args);
      if (armed && args[0] === aliasFile) {
        armed = false;
        rmSync(alias);
        symlinkSync(nextRoot, alias);
        writeFileSync(childFile, header("pinned-root-child"));
      }
      return physical;
    });
    let deleteOutcome: string;
    let sawPinned = false;
    let searchIncludesOther: boolean | undefined;
    try {
      await catalogOwner(fixture.registry).refresh(aliasFile);
      sawPinned = (await fixture.registry.catalog("all")).sessions.some(session => session.id === "pinned-root-child");
      searchIncludesOther = (await fixture.registry.searchCatalogIdentities())?.has("other-root-child");
      deleteOutcome = await fixture.registry.delete("other-root-child").then(
        () => "deleted",
        (error: unknown) => error instanceof Error && "code" in error ? String(error.code) : "unexpected-error",
      );
    } finally { pathRead.mockRestore(); }
    expect({ armed, sawPinned, searchIncludesOther, deleteOutcome, otherPreserved: existsSync(otherFile) })
      .toEqual({ armed: false, sawPinned: true, searchIncludesOther: false, deleteOutcome: "not_found", otherPreserved: true });
  });

  it("keeps a reserved child delegated after its parent is deleted and ignores later title metadata", async () => {
    const root = await temporaryRoot("tron-catalog-parent-deleted-");
    const agentDir = join(root, "agent");
    const directory = join(agentDir, "sessions", "workspace");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(directory, { recursive: true }), mkdir(cwd)]);
    const timestamp = new Date().toISOString();
    const parentId = "deleted-parent";
    const parentFile = join(directory, `${parentId}.jsonl`);
    await writeFile(parentFile, `${JSON.stringify({
      type: "session", version: 3, id: parentId, timestamp, cwd,
    })}\n`);
    const childDirectory = join(directory, parentId, "worker", "run-0");
    await mkdir(childDirectory, { recursive: true });
    const childId = "interrupted-before-title";
    const childFile = join(childDirectory, "session.jsonl");
    await writeFile(childFile, `${JSON.stringify({
      type: "session", version: 3, id: childId, timestamp, cwd,
    })}\n`);
    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);

    await initializeRegistry(registry);
    await settleCatalog(registry);
    expect((await registry.catalog("all")).sessions.find((session) => session.id === childId)?.kind)
      .toBe("subagent");
    await rm(parentFile);
    const withoutParent = await registry.catalog("all");
    expect(withoutParent.sessions.find((session) => session.id === childId)?.kind).toBe("subagent");
    await writeFile(childFile, `${await readFile(childFile, "utf8")}${JSON.stringify({
      type: "session_info", id: "late-title", parentId: null, timestamp,
      name: "ordinary title",
    })}\n`);
    const afterTitle = await registry.catalog("all");
    expect(afterTitle.listRevision).toBe(withoutParent.listRevision);
    expect(afterTitle.sessions.find((session) => session.id === childId)?.kind).toBe("subagent");
    await expect(registry.acquire(childId)).rejects.toMatchObject({ code: "conflict" });
    await expect(registry.delete(childId)).rejects.toMatchObject({ code: "conflict" });
  });

  it("classifies a 1,541-file catalog using positive topology only", async () => {
    const root = await temporaryRoot("tron-catalog-topology-scale-");
    const agentDir = join(root, "agent");
    const directory = join(agentDir, "sessions", "workspace");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(directory, { recursive: true }), mkdir(cwd)]);
    const timestamp = new Date().toISOString();
    const parentId = "scale-parent";
    const parentFile = join(directory, `${parentId}.jsonl`);
    const incidentId = "incident-top-level-parented";
    await Promise.all([
      writeFile(parentFile, `${JSON.stringify({ type: "session", version: 3, id: parentId, timestamp, cwd })}\n`),
      writeFile(join(directory, `${incidentId}.jsonl`), `${JSON.stringify({
        type: "session", version: 3, id: incidentId, timestamp, cwd, parentSession: parentFile,
      })}\n`),
      ...Array.from({ length: 1_538 }, (_, index) => writeFile(
        join(directory, `ordinary-${String(index).padStart(4, "0")}.jsonl`),
        `${JSON.stringify({ type: "session", version: 3, id: `ordinary-${index}`, timestamp, cwd })}\n`,
      )),
    ]);
    const childDirectory = join(directory, parentId, "worker", "run-0");
    await mkdir(childDirectory, { recursive: true });
    const childId = "scale-interrupted-child";
    await writeFile(join(childDirectory, "session.jsonl"), `${JSON.stringify({
      type: "session", version: 3, id: childId, timestamp, cwd,
    })}\n`);
    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);

    await initializeRegistry(registry);
    await settleCatalog(registry);
    const all = await registry.catalog("all");
    expect(all.sessions).toHaveLength(1_541);
    expect(all.sessions.find((session) => session.id === childId)?.kind).toBe("subagent");
    expect(all.sessions.find((session) => session.id === incidentId)?.kind).toBe("user");
    expect((await registry.list("user")).map((session) => session.id)).not.toContain(childId);
  }, 30_000);

  it("closes the catalog header handle when the tail probe fails", async () => {
    const fixture = await coldFixture("header-read-failure");
    const probePath = join(fixture.root, "isolated-header.jsonl");
    await copyFile(fixture.manager.getSessionFile()!, probePath);
    const handle = await fsPromises.open(probePath, "r");
    const identity = await handle.stat();
    const originalRead = handle.read;
    const failure = new Error("injected tail read failure");
    let failedHandle: typeof handle | undefined;
    const read = vi.spyOn(Object.getPrototypeOf(handle), "read").mockImplementation(async function (this: typeof handle, ...args: any[]) {
      const current = await this.stat();
      if (current.dev === identity.dev && current.ino === identity.ino) {
        failedHandle = this;
        throw failure;
      }
      return originalRead.apply(this, args as any);
    });
    const internals = fixture.registry as unknown as {
      readCatalogHeader: (path: string, maximumBytes: number, reserve: () => boolean, refund: () => void) => Promise<unknown>;
    };
    try {
      await expect(internals.readCatalogHeader(probePath, 1024, () => true, () => {}))
        .rejects.toBe(failure);
      expect(failedHandle).toBeDefined();
      await expect(failedHandle!.stat()).rejects.toMatchObject({ code: "EBADF" });
    } finally {
      read.mockRestore();
      await handle.close();
      await failedHandle?.close();
      await rm(fixture.root, { recursive: true, force: true });
    }
  });

  it("reserves a deterministic aggregate header-read budget across concurrent readers", async () => {
    const root = await temporaryRoot("tron-catalog-strict-header-budget-");
    const agentDir = join(root, "agent");
    const directory = join(agentDir, "sessions", "workspace");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(directory, { recursive: true }), mkdir(cwd)]);
    await Promise.all(Array.from({ length: 8 }, (_, index) => writeFile(
      join(directory, `session-${index}.jsonl`),
      `${JSON.stringify({
        type: "session",
        id: `session-${index}`,
        cwd: index < 4 ? "/x" : "x".repeat(200),
      })}\n${"x".repeat(4_096)}\n`,
    )));
    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
      catalogDiscoveryLimits: {
        maximumHeaderBytes: 2 * 512,
        normalizationConcurrency: 4,
      },
    });
    registries.push(registry);
    const internals = registry as unknown as {
      catalogStructureEvidence: () => Promise<{
        complete: boolean;
        digest: string;
        identitiesByPath: ReadonlyMap<string, unknown>;
      }>;
    };

    const first = await internals.catalogStructureEvidence();
    const second = await internals.catalogStructureEvidence();
    expect(first.complete).toBe(true);
    expect(first.unprovenPaths.size).toBeGreaterThan(0);
    expect(first.identitiesByPath.size).toBe(4);
    expect([...first.identitiesByPath.keys()]).toEqual([...second.identitiesByPath.keys()]);
    expect(first.digest).toBe(second.digest);
  });

    it("orders history by parsed recency while active heartbeats keep stable positions", async () => {
    const root = await temporaryRoot("tron-catalog-time-precision-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const sessionDirectory = join(agentDir, "sessions", "workspace");
    await Promise.all([mkdir(sessionDirectory, { recursive: true }), mkdir(cwd)]);
    process.env.PI_CODING_AGENT_DIR = agentDir;
    const whole = SessionManager.create(cwd, sessionDirectory);
    whole.appendMessage(fauxAssistantMessage("whole"));
    const fraction = SessionManager.create(cwd, sessionDirectory);
    fraction.appendMessage(fauxAssistantMessage("fraction"));
    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const internals = registry as unknown as {
      latestSummaries: Map<string, SessionSummaryUpdate>;
      publishRevisionedSummary: (summary: SessionSummaryUpdate) => void;
    };
    const summary = (sessionId: string, updatedAt: string): SessionSummaryUpdate => ({
      sessionId,
      summaryRevision: 1,
      phase: "idle",
      updatedAt,
      messageCount: 1,
      firstMessage: "",
      completionRevision: 0,
      attentionRevision: 0,
      isUnread: false,
    });
    internals.latestSummaries.set(whole.getSessionId(), summary(whole.getSessionId(), "2026-01-01T00:00:00Z"));
    internals.latestSummaries.set(fraction.getSessionId(), summary(fraction.getSessionId(), "2026-01-01T00:00:00.900Z"));

    const catalog = await registry.catalog("user");
    expect(catalog.sessions.map((session) => session.id).slice(0, 2)).toEqual([
      fraction.getSessionId(),
      whole.getSessionId(),
    ]);

    internals.publishRevisionedSummary({
      ...summary(whole.getSessionId(), "2026-01-01T00:10:00Z"),
      phase: "running",
      activeSince: "2026-01-01T00:02:00Z",
    });
    internals.publishRevisionedSummary({
      ...summary(fraction.getSessionId(), "2026-01-01T00:20:00Z"),
      phase: "running",
      activeSince: "2026-01-01T00:01:00Z",
    });
    const activeCatalog = await registry.catalog("user");
    expect(activeCatalog.sessions.map((session) => session.id).slice(0, 2)).toEqual([
      whole.getSessionId(),
      fraction.getSessionId(),
    ]);

    internals.publishRevisionedSummary({
      ...summary(fraction.getSessionId(), "2026-01-01T00:30:00Z"),
      phase: "running",
      activeSince: "2026-01-01T00:01:00Z",
    });
    const heartbeatCatalog = await registry.catalog("user");
    expect(heartbeatCatalog.sessions.map((session) => session.id).slice(0, 2)).toEqual([
      whole.getSessionId(),
      fraction.getSessionId(),
    ]);
  });

    it("matches a full scan after create, rename, fork and delete in the catalog index", async () => {
    const root = await temporaryRoot("tron-catalog-index-mutations-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const sessions = join(agentDir, "sessions");
    await Promise.all([mkdir(sessions, { recursive: true }), mkdir(cwd)]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    const faux = fauxProvider({ provider: "tron-catalog-index", tokensPerSecond: 10_000 });
    faux.setResponses([fauxAssistantMessage("catalog index ready"), fauxAssistantMessage("catalog index forked")]);
    runtime.registerNativeProvider(faux.provider);
    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const catalog = (registry as unknown as { sessionCatalog: SessionCatalog }).sessionCatalog;
    const catalogRoot = await realpath(sessions);
    const discovery = new CatalogDiscovery({
      limits: DEFAULT_CATALOG_DISCOVERY_LIMITS,
      catalogDirectory: () => catalogRoot,
      catalogCapacityExceeded: () => { throw new Error("catalog capacity exceeded"); },
      isLiveRuntimeOwnedPath: () => false,
      canonicalSessionPath: (path) => realpath(path).catch(() => path),
      delegatedTopologyParentPath: () => undefined,
    });
    const compareToFullScan = async (label: string) => {
      const walked = await discovery.catalogStructureEvidence();
      const scanned = (await Promise.all(
        [...walked.identitiesByPath.keys()].map(async (path) => {
          const info = await buildCatalogSessionInfo(path);
          if (!info) return null;
          return {
            ...info,
            path: await realpath(info.path),
            ...(info.parentSessionPath ? { parentSessionPath: await realpath(info.parentSessionPath) } : {}),
          };
        }),
      )).filter((info): info is CatalogSessionInfo => info !== null);
      const rows = catalog.rows();
      expect(rows.map((row) => row.path), `${label}: paths`).toEqual(scanned.map((session) => session.path));
      expect(rows.map((row) => [
        row.id,
        resolve(row.cwd),
        row.parentSessionPath === undefined ? undefined : resolve(row.parentSessionPath),
        row.name,
        row.firstMessage,
        row.messageCount,
        row.createdAt,
        row.updatedAt,
      ]), `${label}: metadata`).toEqual(scanned.map((session) => [
        session.id,
        resolve(session.cwd),
        session.parentSessionPath === undefined ? undefined : resolve(session.parentSessionPath),
        session.name,
        session.firstMessage,
        session.messageCount,
        session.created.toISOString(),
        session.modified.toISOString(),
      ]));
      for (const row of rows) {
        const stats = await fsPromises.lstat(row.path);
        expect([row.fileIdentity, row.size, row.eofOffset], `${label}: file facts`)
          .toEqual([`${stats.dev}:${stats.ino}`, stats.size, stats.size]);
      }
    };

    const live = await registry.create(cwd);
    const model = faux.getModel();
    await live.setModel(model.provider, model.id);
    await live.prompt("catalog index create");
    await waitFor(() => !live.isBusy, "the live slot to go idle");
    await catalog.settled();
    await compareToFullScan("create");
    expect(catalog.rows().map((row) => row.id)).toContain(live.id);

    await live.rename("catalog index renamed");
    await catalog.settled();
    await compareToFullScan("rename");
    expect(catalog.row(await realpath(live.sessionFile!))?.name).toBe("catalog index renamed");

    const forkedId = live.snapshot().runtimeGeneration;
    const userEntry = live.history(forkedId).nodes.find((node) => node.role === "user");
    expect(userEntry?.id).toBeTruthy();
    const forked = await live.fork(userEntry!.id, "at");
    await live.prompt("catalog index fork entry");
    await waitFor(() => !live.isBusy, "the live slot to go idle");
    await catalog.settled();
    await compareToFullScan("fork");
    expect(catalog.rows().map((row) => row.id)).toContain(forked.sessionId);
    expect([...catalog.duplicateSessionIds()]).toEqual([]);

    await registry.delete(forked.sessionId);
    await catalog.settled();
    await compareToFullScan("delete");
    expect(catalog.rows().some((row) => row.id === forked.sessionId)).toBe(false);
  });

  it("fails closed when multiple canonical files claim one session ID", async () => {
    const root = await temporaryRoot("tron-catalog-duplicate-id-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    const faux = fauxProvider({ provider: "tron-duplicate-session-id", tokensPerSecond: 10_000 });
    faux.setResponses([fauxAssistantMessage("persisted")]);
    runtime.registerNativeProvider(faux.provider);
    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("persist duplicate ownership fixture");
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    await settleCatalog(registry);
    const duplicatePath = join(agentDir, "sessions", "duplicate", `${slot.id}.jsonl`);
    await mkdir(dirname(duplicatePath), { recursive: true });
    await copyFile(slot.persistedSessionFile!, duplicatePath);
    await settleCatalog(registry);

    const outcomeOf = (attempt: Promise<unknown>) => attempt.then(
      () => ({ outcome: "resolved" }),
      (error: { code?: string }) => ({ outcome: "rejected", code: error.code }),
    );
    const retained = registry.retainLiveSession(slot.id);
    try {
      expect(retained).toBeUndefined();
    } finally {
      retained?.();
    }
    expect(await outcomeOf(registry.setAttention(slot.id, true))).toEqual({ outcome: "rejected", code: "conflict" });
    expect(await outcomeOf(registry.acquire(slot.id))).toEqual({ outcome: "rejected", code: "conflict" });
    await expect(registry.delete(slot.id)).rejects.toMatchObject({ code: "conflict" });

    const conflicted = await registry.catalog("all");
    expect(conflicted.sessions.find((session) => session.id === slot.id)).toBeUndefined();
    const reordered = await registry.catalog("all");
    expect(reordered.listRevision).toBe(conflicted.listRevision);
    expect(reordered.sessions.find((session) => session.id === slot.id)).toBeUndefined();
    await rm(duplicatePath);
    await settleCatalog(registry);

    const repaired = await registry.catalog("all");
    expect(repaired.sessions.filter((session) => session.id === slot.id)).toHaveLength(1);
    expect((await registry.acquire(slot.id)).id).toBe(slot.id);
    const lease = registry.retainLiveSession(slot.id);
    expect(lease).toBeTypeOf("function");
    lease?.();
    expect((await registry.setAttention(slot.id, true)).isUnread).toBe(true);
  });

  it("keeps 128 parallel parent runs discoverable through child churn and repeated client reentry", async () => {
    const root = await temporaryRoot("tron-scale-qualification-");
    const agentDir = join(root, "agent");
    const projects = Array.from({ length: 8 }, (_, index) => join(root, `project-${index}`));
    await Promise.all(projects.map(cwd => mkdir(cwd, { recursive: true })));
    process.env.PI_CODING_AGENT_DIR = agentDir;
    const managers: SessionManager[] = [];
    const children: SessionManager[] = [];
    for (let index = 0; index < 128; index++) {
      const cwd = projects[index % projects.length]!;
      const directory = join(agentDir, "sessions", `project-${index % projects.length}`);
      await mkdir(directory, { recursive: true });
      const manager = SessionManager.create(cwd, directory);
      manager.appendMessage(fauxAssistantMessage(`parent-${index}`));
      managers.push(manager);
      const forks = join(directory, basename(manager.getSessionFile()!, ".jsonl"), "forks");
      await mkdir(forks, { recursive: true });
      const fork = SessionManager.forkFrom(manager.getSessionFile()!, cwd, forks);
      fork.appendMessage(fauxAssistantMessage(`child-${index}`));
      children.push(fork);
    }
    let release!: () => void;
    const barrier = new Promise<void>(resolve => { release = resolve; });
    const faux = fauxProvider({ provider: "tron-scale-test", tokensPerSecond: 100_000 });
    faux.setResponses(managers.map((_, index) => async () => { await barrier; return fauxAssistantMessage(`complete-${index}`); }));
    const runtimeFactory = vi.fn(async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    });
    const registry = await createTestRegistry({ agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000,
      maximumLiveRuntimes: DEFAULT_MAX_LIVE_RUNTIMES, modelRuntimeFactory: runtimeFactory,
      trust: new TrustService(agentDir), broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {} });
    registries.push(registry);
    let acquisitions: Promise<unknown>[] = [];
    try {
      await initializeRegistry(registry);
      acquisitions = managers.flatMap(manager => [registry.acquire(manager.getSessionId()), registry.acquire(manager.getSessionId())]);
      const acquired = await Promise.all(acquisitions) as Awaited<ReturnType<RuntimeRegistry["acquire"]>>[];
      const slots = acquired.filter((_, index) => index % 2 === 0);
      for (let index = 0; index < slots.length; index++) expect(acquired[index * 2 + 1]).toBe(slots[index]);
      const model = faux.getModel();
      await Promise.all(slots.map(async (slot, index) => { await slot.setModel(model.provider, model.id); await slot.prompt(`work-${index}`); }));
      await waitFor(() => faux.state.callCount === 128, "all 128 slots to reach the model");
      expect(registry.activeSessionIds()).toHaveLength(128);
      const expected = managers.map(manager => manager.getSessionId()).sort();
      for (let wave = 0; wave < 3; wave++) {
        for (const child of children) child.appendMessage(fauxAssistantMessage(`progress-${wave}`));
        registry.unsubscribeClient("phone");
        const catalogs = await Promise.all(Array.from({ length: 8 }, () => registry.catalog("user")));
        for (const catalog of catalogs) expect(catalog.sessions.map(row => row.id).sort()).toEqual(expected);
        for (let index = 0; index < slots.length; index++) {
          const slot = slots[(index + wave) % slots.length]!;
          registry.subscribe("phone", slot.id);
          expect(await registry.acquire(slot.id)).toBe(slot);
          expect(slot.snapshot().sessionId).toBe(slot.id);
          registry.unsubscribeClient("phone");
        }
        expect(registry.activeSessionIds()).toHaveLength(128);
        expect(runtimeFactory).toHaveBeenCalledTimes(128);
      }
      release();
      await registry.waitUntilIdle();
      expect(registry.activeSessionIds()).toHaveLength(0);
      for (const slot of slots) expect(slot.snapshot().transcript.some(item => JSON.stringify(item).includes("complete-"))).toBe(true);
    } finally {
      release(); await Promise.allSettled(acquisitions); await registry.dispose();
      await rm(root, { recursive: true, force: true });
    }
  }, 60_000);
});
