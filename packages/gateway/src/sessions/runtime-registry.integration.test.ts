import { randomUUID } from "node:crypto";
import { copyFile, mkdtemp, mkdir, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { getExamplesPath, ModelRuntime, SessionManager } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it, vi } from "vitest";
import { TrustService } from "../admin/trust-service.js";
import type { SessionSummaryUpdate } from "../protocol/types.js";
import { RuntimeRegistry } from "./runtime-registry.js";

async function waitUntil(predicate: () => boolean, timeoutMs = 5_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error("condition timed out");
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

describe.sequential("RuntimeRegistry with the pinned agent runtime", () => {
  const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
  const registries: RuntimeRegistry[] = [];

  async function coldFixture(label: string, options: { nested?: boolean; name?: string; maximumLiveRuntimes?: number } = {}) {
    const root = await mkdtemp(join(tmpdir(), `tron-cold-acquire-${label}-`));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const sessionDirectory = options.nested
      ? join(agentDir, "sessions", "workspace", "child")
      : join(agentDir, "sessions", "workspace");
    await Promise.all([mkdir(sessionDirectory, { recursive: true }), mkdir(cwd, { recursive: true })]);
    process.env.PI_CODING_AGENT_DIR = agentDir;
    const manager = SessionManager.create(cwd, sessionDirectory);
    manager.appendMessage(fauxAssistantMessage(`cold acquisition ${label}`));
    if (options.name) manager.appendSessionInfo(options.name);
    const runtimeFactory = vi.fn(async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }));
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      maximumLiveRuntimes: options.maximumLiveRuntimes,
      modelRuntimeFactory: runtimeFactory,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    return {
      root,
      agentDir,
      cwd,
      manager,
      registry,
      runtimeFactory,
      sessionFile: manager.getSessionFile()!,
    };
  }

  afterEach(async () => {
    await Promise.all(registries.splice(0).map((registry) => registry.dispose()));
    if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
    else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
  });

  it("keeps row-summary revisions separate and lists phase without transcript snapshots", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-catalog-summary-revision-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    const faux = fauxProvider({ provider: "tron-catalog-boundary", tokensPerSecond: 10_000 });
    faux.setResponses([fauxAssistantMessage("catalog ready")]);
    runtime.registerNativeProvider(faux.provider);
    const summaries: SessionSummaryUpdate[] = [];
    let listChanges = 0;
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: (summary) => summaries.push(summary),
      sessionListChanged: () => { listChanges += 1; },
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt(`catalog boundary ${"x".repeat(5_000)}`);
    await waitUntil(() => !slot.isBusy);
    await slot.rename(`catalog-${"n".repeat(5_000)}`);
    const before = await registry.catalog("user");
    const snapshot = vi.spyOn(slot, "snapshot");
    const structuralChangesBeforeSummary = listChanges;

    slot.publishSnapshot();
    snapshot.mockClear();
    const after = await registry.catalog("user");

    expect(summaries.at(-1)?.summaryRevision).toBeGreaterThan(0);
    expect(Buffer.byteLength(summaries.at(-1)?.firstMessage ?? "")).toBeLessThanOrEqual(1_024);
    expect(Buffer.byteLength(summaries.at(-1)?.name ?? "")).toBeLessThanOrEqual(1_024);
    expect(after.listRevision).toBe(before.listRevision);
    expect(listChanges).toBe(structuralChangesBeforeSummary);
    expect(after.sessions[0]?.phase).toBe(slot.catalogPhase);
    // Runtime-owned deferred publication may legitimately call snapshot(sequence)
    // here; catalog listing must never call the former zero-argument full snapshot.
    expect(snapshot.mock.calls.filter((arguments_) => arguments_.length === 0)).toHaveLength(0);
  });

  it("bounds recursive catalog directories and streamed entries before materialization", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-catalog-discovery-bounds-"));
    const agentDir = join(root, "agent");
    const catalog = join(agentDir, "sessions");
    await Promise.all([
      mkdir(join(catalog, "first"), { recursive: true }),
      mkdir(join(catalog, "second"), { recursive: true }),
    ]);
    const makeRegistry = (
      maximumDirectories: number,
      maximumEntries: number,
      maximumTraversalBytes = 8 * 1_024 * 1_024,
    ) => {
      const registry = new RuntimeRegistry({
        agentDir,
        tronHome: join(root, `tron-${maximumDirectories}-${maximumEntries}-${maximumTraversalBytes}`),
        idleRuntimeMs: 60_000,
        trust: new TrustService(agentDir),
        broadcast: () => {},
        sessionSummaryChanged: () => {},
        sessionListChanged: () => {},
        catalogDiscoveryLimits: { maximumDirectories, maximumEntries, maximumTraversalBytes },
      });
      registries.push(registry);
      return registry;
    };

    await expect(makeRegistry(2, 2).catalog("all")).rejects.toMatchObject({
      code: "busy",
      retryable: true,
    });
    await expect(makeRegistry(3, 1).catalog("all")).rejects.toMatchObject({
      code: "busy",
      retryable: true,
    });
    await expect(makeRegistry(3, 2, 1).catalog("all")).rejects.toMatchObject({ code: "busy" });
    await expect(makeRegistry(3, 2).catalog("all")).resolves.toMatchObject({ sessions: [] });
  });

  it("owns recursion without overlapping SDK directory materializations", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-catalog-direct-sdk-listing-"));
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

    const registry = new RuntimeRegistry({
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
    expect((await registry.catalog("all")).sessions.map((session) => session.id).sort()).toEqual([
      childSession.getSessionId(), directSession.getSessionId(),
    ].sort());
  });

  it("bounds discovered session count and bytes before normalization", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-catalog-materialization-bounds-"));
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
      allMessagesText: "unused picker search text ".repeat(20_000),
    }));
    const encodedBytes = infos.reduce((total, { allMessagesText: _discarded, ...info }) => (
      total + Buffer.byteLength(JSON.stringify(info))
    ), 0);
    const listAll = vi.spyOn(SessionManager, "listAll").mockResolvedValue(infos as never);
    const makeRegistry = (maximumSessions: number, maximumRetainedBytes: number) => {
      const registry = new RuntimeRegistry({
        agentDir,
        tronHome: join(root, `tron-${maximumSessions}-${maximumRetainedBytes}`),
        idleRuntimeMs: 60_000,
        trust: new TrustService(agentDir),
        broadcast: () => {},
        sessionSummaryChanged: () => {},
        sessionListChanged: () => {},
        catalogDiscoveryLimits: { maximumSessions, maximumRetainedBytes, normalizationConcurrency: 1 },
      });
      registries.push(registry);
      return registry;
    };

    try {
      await expect(makeRegistry(1, encodedBytes).catalog("all")).rejects.toMatchObject({ code: "busy" });
      await expect(makeRegistry(2, encodedBytes - 1).catalog("all")).rejects.toMatchObject({ code: "busy" });
      await expect(makeRegistry(2, encodedBytes).catalog("all")).resolves.toMatchObject({
        sessions: [{ id: "first" }, { id: "second" }],
      });
    } finally {
      listAll.mockRestore();
    }
  });

  it("caps canonical session path normalization concurrency", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-catalog-normalization-concurrency-"));
    const agentDir = join(root, "agent");
    await mkdir(join(agentDir, "sessions"), { recursive: true });
    const now = new Date("2026-01-01T00:00:00Z");
    const infos = Array.from({ length: 6 }, (_, index) => ({
      id: `session-${index}`,
      path: join(agentDir, "sessions", `session-${index}.jsonl`),
      cwd: root,
      created: now,
      modified: now,
      messageCount: 0,
      firstMessage: `session ${index}`,
    }));
    const listAll = vi.spyOn(SessionManager, "listAll").mockResolvedValue(infos as never);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
      catalogDiscoveryLimits: { normalizationConcurrency: 2 },
    });
    registries.push(registry);
    const internals = registry as unknown as {
      canonicalSessionPath: (path: string) => Promise<string>;
    };
    let active = 0;
    let maximumActive = 0;
    let release!: () => void;
    let reachedCapacity!: () => void;
    const capacity = new Promise<void>((resolve) => { reachedCapacity = resolve; });
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const canonicalize = vi.spyOn(internals, "canonicalSessionPath").mockImplementation(async (path) => {
      active += 1;
      maximumActive = Math.max(maximumActive, active);
      if (active === 2) reachedCapacity();
      await gate;
      active -= 1;
      return resolve(path);
    });

    try {
      const loading = registry.catalog("all");
      await capacity;
      expect(maximumActive).toBe(2);
      release();
      await loading;
      expect(maximumActive).toBe(2);
    } finally {
      canonicalize.mockRestore();
      listAll.mockRestore();
    }
  });

  it("reuses one stable catalog acquisition without a second transcript-wide materialization", async () => {
    const fixture = await coldFixture("reuse");
    const internals = fixture.registry as unknown as { sessionInfos: () => Promise<unknown[]> };
    const materialize = vi.spyOn(internals, "sessionInfos");

    const catalog = await fixture.registry.catalog("user");
    expect(catalog.sessions.map((session) => session.id)).toContain(fixture.manager.getSessionId());
    expect(materialize).toHaveBeenCalledTimes(1);
    fixture.manager.appendMessage(fauxAssistantMessage("ordinary append after catalog"));

    expect((await fixture.registry.acquire(fixture.manager.getSessionId())).id).toBe(fixture.manager.getSessionId());
    expect(materialize).toHaveBeenCalledTimes(1);
    expect(fixture.runtimeFactory).toHaveBeenCalledTimes(1);

    // A hot slot not marked ambiguous by the latest full catalog bypasses
    // both transcript materialization and global header validation.
    const evidence = vi.spyOn(fixture.registry as any, "catalogStructureEvidence");
    expect((await fixture.registry.acquire(fixture.manager.getSessionId())).id).toBe(fixture.manager.getSessionId());
    expect(materialize).toHaveBeenCalledTimes(1);
    expect(evidence).not.toHaveBeenCalled();
  });

  it("uses only bounded header evidence when cold acquisition has no reusable admission", async () => {
    const fixture = await coldFixture("uncached");
    const internals = fixture.registry as unknown as { sessionInfos: () => Promise<unknown[]> };
    const materialize = vi.spyOn(internals, "sessionInfos");

    expect((await fixture.registry.acquire(fixture.manager.getSessionId())).id).toBe(fixture.manager.getSessionId());
    expect(materialize).not.toHaveBeenCalled();
    expect(fixture.runtimeFactory).toHaveBeenCalledTimes(1);
  });

  it("ignores jsonl-named directories during lightweight acquisition", async () => {
    const fixture = await coldFixture("jsonl-directory");
    await mkdir(join(fixture.agentDir, "sessions", "unrelated.jsonl"));
    const internals = fixture.registry as unknown as { sessionInfos: () => Promise<unknown[]> };
    const materialize = vi.spyOn(internals, "sessionInfos");

    expect((await fixture.registry.acquire(fixture.manager.getSessionId())).id)
      .toBe(fixture.manager.getSessionId());
    expect(materialize).not.toHaveBeenCalled();
  });

  it("falls back to stable SDK discovery for an unrelated malformed header", async () => {
    const fixture = await coldFixture("malformed-fallback");
    const unrelated = join(fixture.agentDir, "sessions", "unrelated");
    await mkdir(unrelated, { recursive: true });
    await writeFile(join(unrelated, "malformed.jsonl"), `${"x".repeat(70_000)}\n`);
    const internals = fixture.registry as unknown as {
      sessionInfos: () => Promise<unknown[]>;
      catalogAcquisitionAdmission?: unknown;
    };
    const materialize = vi.spyOn(internals, "sessionInfos");

    expect((await fixture.registry.acquire(fixture.manager.getSessionId())).id)
      .toBe(fixture.manager.getSessionId());
    expect(materialize).toHaveBeenCalledTimes(3);
    expect(internals.catalogAcquisitionAdmission).toBeUndefined();
  });

  it("revalidates oversized SDK identities after fallback resolution", async () => {
    const fixture = await coldFixture("oversized-fallback-identity");
    const unrelatedDirectory = join(fixture.agentDir, "sessions", "unrelated-oversized");
    const unrelatedFile = join(unrelatedDirectory, "unrelated.jsonl");
    await mkdir(unrelatedDirectory, { recursive: true });
    const originalLines = (await readFile(fixture.sessionFile, "utf8")).split("\n");
    const originalHeader = JSON.parse(originalLines[0]!) as Record<string, unknown>;
    originalLines[0] = JSON.stringify({
      ...originalHeader,
      id: "unrelated-oversized-session",
      padding: "x".repeat(70_000),
    });
    await writeFile(unrelatedFile, originalLines.join("\n"));
    const internals = fixture.registry as unknown as {
      fallbackCatalogAcquisition: () => Promise<unknown>;
      sessionInfos: () => Promise<unknown[]>;
    };
    const originalFallback = internals.fallbackCatalogAcquisition.bind(fixture.registry);
    const fallback = vi.spyOn(internals, "fallbackCatalogAcquisition").mockImplementation(async () => {
      const resolution = await originalFallback();
      const mutatedLines = (await readFile(unrelatedFile, "utf8")).split("\n");
      const mutatedHeader = JSON.parse(mutatedLines[0]!) as Record<string, unknown>;
      mutatedLines[0] = JSON.stringify({ ...mutatedHeader, id: fixture.manager.getSessionId() });
      await writeFile(unrelatedFile, mutatedLines.join("\n"));
      return resolution;
    });
    const materialize = vi.spyOn(internals, "sessionInfos");

    await expect(fixture.registry.acquire(fixture.manager.getSessionId()))
      .rejects.toMatchObject({ code: "busy", retryable: true });
    expect(fallback).toHaveBeenCalledTimes(1);
    expect(materialize).toHaveBeenCalledTimes(3);
    expect(fixture.runtimeFactory).not.toHaveBeenCalled();
  });

  it("invalidates reusable acquisition when a duplicate or removal changes canonical membership", async () => {
    const duplicateFixture = await coldFixture("duplicate-membership");
    const duplicateInternals = duplicateFixture.registry as unknown as { sessionInfos: () => Promise<unknown[]> };
    const duplicateMaterialize = vi.spyOn(duplicateInternals, "sessionInfos");
    await duplicateFixture.registry.catalog("all");
    const duplicateDirectory = join(duplicateFixture.agentDir, "sessions", "duplicate");
    await mkdir(duplicateDirectory, { recursive: true });
    await copyFile(
      duplicateFixture.sessionFile,
      join(duplicateDirectory, "duplicate.jsonl"),
    );

    await expect(duplicateFixture.registry.acquire(duplicateFixture.manager.getSessionId())).rejects.toMatchObject({
      code: "conflict",
    });
    expect(duplicateMaterialize).toHaveBeenCalledTimes(1);
    expect(duplicateFixture.runtimeFactory).not.toHaveBeenCalled();
    await rm(join(duplicateDirectory, "duplicate.jsonl"));
    expect((await duplicateFixture.registry.acquire(duplicateFixture.manager.getSessionId())).id)
      .toBe(duplicateFixture.manager.getSessionId());
    expect(duplicateMaterialize).toHaveBeenCalledTimes(1);
    const duplicateAgain = join(duplicateDirectory, "duplicate-again.jsonl");
    await copyFile(duplicateFixture.sessionFile, duplicateAgain);
    await duplicateFixture.registry.catalog("all");
    await expect(duplicateFixture.registry.acquire(duplicateFixture.manager.getSessionId())).rejects.toMatchObject({
      code: "conflict",
    });
    await rm(duplicateAgain);
    expect((await duplicateFixture.registry.acquire(duplicateFixture.manager.getSessionId())).id)
      .toBe(duplicateFixture.manager.getSessionId());

    const removedFixture = await coldFixture("removed-membership");
    const removedInternals = removedFixture.registry as unknown as { sessionInfos: () => Promise<unknown[]> };
    const removedMaterialize = vi.spyOn(removedInternals, "sessionInfos");
    await removedFixture.registry.catalog("all");
    await rm(removedFixture.sessionFile);

    await expect(removedFixture.registry.acquire(removedFixture.manager.getSessionId())).rejects.toMatchObject({
      code: "not_found",
    });
    expect(removedMaterialize).toHaveBeenCalledTimes(1);
    expect(removedFixture.runtimeFactory).not.toHaveBeenCalled();
  });

  it("resolves deepest nested topology owners without scanning every root", async () => {
    const fixture = await coldFixture("topology-helper");
    const internals = fixture.registry as unknown as {
      nestedOwners: (sessions: Array<{ id: string; path: string }>) => ReadonlyMap<string, string>;
    };
    const root = join(fixture.root, "topology");
    const parent = join(root, "parent.jsonl");
    const child = join(root, "parent", "child.jsonl");
    const grandchild = join(root, "parent", "child", "run", "grandchild.jsonl");
    const unrelated = join(root, "unrelated.jsonl");

    expect([...internals.nestedOwners([
      { id: "parent", path: parent },
      { id: "child", path: child },
      { id: "grandchild", path: grandchild },
      { id: "unrelated", path: unrelated },
    ])]).toEqual([
      [resolve(child), "parent"],
      [resolve(grandchild), "child"],
    ]);
  });

  it("keeps structural and exact current named subagent sessions non-openable", async () => {
    const nestedFixture = await coldFixture("nested-subagent", { nested: true });
    const nestedInternals = nestedFixture.registry as unknown as { sessionInfos: () => Promise<unknown[]> };
    const nestedMaterialize = vi.spyOn(nestedInternals, "sessionInfos");
    const nestedCatalog = await nestedFixture.registry.catalog("all");
    expect(nestedCatalog.sessions.find((session) => session.id === nestedFixture.manager.getSessionId())?.kind)
      .toBe("subagent");
    await expect(nestedFixture.registry.acquire(nestedFixture.manager.getSessionId())).rejects.toMatchObject({
      code: "conflict",
    });
    expect(nestedMaterialize).toHaveBeenCalledTimes(1);
    expect(nestedFixture.runtimeFactory).not.toHaveBeenCalled();

    const namedFixture = await coldFixture("named-subagent", { name: "subagent-catalog-child" });
    const namedInternals = namedFixture.registry as unknown as { sessionInfos: () => Promise<unknown[]> };
    const namedMaterialize = vi.spyOn(namedInternals, "sessionInfos");
    await expect(namedFixture.registry.acquire(namedFixture.manager.getSessionId())).rejects.toMatchObject({
      code: "conflict",
    });
    expect(namedMaterialize).not.toHaveBeenCalled();
    expect(namedFixture.runtimeFactory).not.toHaveBeenCalled();

    const renamedFixture = await coldFixture("renamed-subagent");
    const renamedInternals = renamedFixture.registry as unknown as { sessionInfos: () => Promise<unknown[]> };
    const renamedMaterialize = vi.spyOn(renamedInternals, "sessionInfos");
    await renamedFixture.registry.catalog("all");
    renamedFixture.manager.appendSessionInfo("subagent-renamed-after-catalog");
    await expect(renamedFixture.registry.acquire(renamedFixture.manager.getSessionId())).rejects.toMatchObject({
      code: "conflict",
    });
    expect(renamedMaterialize).toHaveBeenCalledTimes(1);
    expect(renamedFixture.runtimeFactory).not.toHaveBeenCalled();
  });

  it("rejects identity, cwd, or duplicate mutation before runtime creation", async () => {
    for (const field of ["id", "cwd", "duplicate"] as const) {
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
        if (field === "duplicate") {
          const duplicateDirectory = join(fixture.agentDir, "sessions", "duplicate-gap");
          await mkdir(duplicateDirectory, { recursive: true });
          await copyFile(fixture.sessionFile, join(duplicateDirectory, "duplicate.jsonl"));
        } else {
          const lines = (await readFile(fixture.sessionFile, "utf8")).split("\n");
          const header = JSON.parse(lines[0]!) as Record<string, unknown>;
          lines[0] = JSON.stringify({
            ...header,
            [field]: field === "id" ? "replacement-session-id" : replacementCwd,
          });
          await writeFile(fixture.sessionFile, lines.join("\n"));
        }
        return acquired;
      });

      try {
        await expect(fixture.registry.acquire(fixture.manager.getSessionId())).rejects.toMatchObject({
          code: field === "duplicate" ? "busy" : "conflict",
        });
        expect(fixture.runtimeFactory).not.toHaveBeenCalled();
      } finally {
        admission.mockRestore();
      }
    }
  });

  it("retries lightweight acquisition without stamping invalidated evidence current", async () => {
    const fixture = await coldFixture("lightweight-generation-race");
    const internals = fixture.registry as unknown as {
      buildCatalogAcquisition: (...arguments_: any[]) => Promise<unknown>;
      catalogAcquisition: () => Promise<unknown>;
      invalidateCatalogAcquisition: () => void;
      catalogAcquisitionInvalidationGeneration: number;
      catalogAcquisitionAdmission?: { invalidationGeneration: number };
    };
    const original = internals.buildCatalogAcquisition.bind(fixture.registry);
    let calls = 0;
    const build = vi.spyOn(internals, "buildCatalogAcquisition").mockImplementation(async (...arguments_) => {
      const resolution = await original(...arguments_);
      calls += 1;
      if (calls === 1) internals.invalidateCatalogAcquisition();
      return resolution;
    });

    await internals.catalogAcquisition();
    expect(build).toHaveBeenCalledTimes(2);
    expect(internals.catalogAcquisitionAdmission?.invalidationGeneration)
      .toBe(internals.catalogAcquisitionInvalidationGeneration);
  });

  it("fails busy after a second lightweight acquisition invalidation", async () => {
    const fixture = await coldFixture("repeated-lightweight-generation-race");
    const internals = fixture.registry as unknown as {
      catalogStructureEvidence: () => Promise<unknown>;
      catalogAcquisition: () => Promise<unknown>;
      invalidateCatalogAcquisition: () => void;
      catalogAcquisitionAdmission?: unknown;
    };
    const original = internals.catalogStructureEvidence.bind(fixture.registry);
    const evidence = vi.spyOn(internals, "catalogStructureEvidence").mockImplementation(async () => {
      const captured = await original();
      internals.invalidateCatalogAcquisition();
      return captured;
    });

    await expect(internals.catalogAcquisition()).rejects.toMatchObject({ code: "busy", retryable: true });
    expect(evidence).toHaveBeenCalledTimes(2);
    expect(internals.catalogAcquisitionAdmission).toBeUndefined();
  });

  it("cannot republish an acquisition invalidated during full materialization", async () => {
    const fixture = await coldFixture("invalidation-race");
    const internals = fixture.registry as unknown as {
      sessionInfos: () => Promise<unknown[]>;
      invalidateCatalogAcquisition: () => void;
    };
    const original = internals.sessionInfos.bind(fixture.registry);
    let calls = 0;
    const materialize = vi.spyOn(internals, "sessionInfos").mockImplementation(async () => {
      const infos = await original();
      calls += 1;
      if (calls === 1) internals.invalidateCatalogAcquisition();
      return infos;
    });

    await fixture.registry.catalog("all");
    expect(materialize).toHaveBeenCalledTimes(2);
    await fixture.registry.acquire(fixture.manager.getSessionId());
    expect(materialize).toHaveBeenCalledTimes(2);
  });

  it("rejects a mutation in the final full-catalog publication gap", async () => {
    const fixture = await coldFixture("final-publication-gap");
    const internals = fixture.registry as unknown as {
      publishCatalogAcquisition: (...arguments_: unknown[]) => Promise<boolean>;
      invalidateCatalogAcquisition: () => void;
      updateCatalogIdentity: (...arguments_: unknown[]) => void;
      catalogAcquisitionAdmission?: unknown;
    };
    const original = internals.publishCatalogAcquisition.bind(fixture.registry);
    const publication = vi.spyOn(internals, "publishCatalogAcquisition").mockImplementation(async (...arguments_) => {
      const admitted = await original(...arguments_);
      internals.invalidateCatalogAcquisition();
      return admitted;
    });
    const identity = vi.spyOn(internals, "updateCatalogIdentity");

    await expect(fixture.registry.catalog("all")).rejects.toMatchObject({ code: "busy", retryable: true });
    expect(publication).toHaveBeenCalledTimes(1);
    expect(identity).not.toHaveBeenCalled();
    expect(internals.catalogAcquisitionAdmission).toBeUndefined();
  });

  it("fails busy without publishing after a second unstable full materialization", async () => {
    const fixture = await coldFixture("repeated-instability");
    const internals = fixture.registry as unknown as {
      catalogStructureEvidence: () => Promise<{ digest: string; identitiesByPath: ReadonlyMap<string, unknown>; complete: boolean }>;
      catalogAcquisition: () => Promise<unknown>;
      sessionInfos: () => Promise<unknown[]>;
      updateCatalogIdentity: (...arguments_: unknown[]) => void;
      catalogAcquisitionAdmission?: unknown;
    };
    await internals.catalogAcquisition();
    expect(internals.catalogAcquisitionAdmission).toBeDefined();
    const originalEvidence = internals.catalogStructureEvidence.bind(fixture.registry);
    let evidenceCall = 0;
    const evidence = vi.spyOn(internals, "catalogStructureEvidence").mockImplementation(async () => {
      const current = await originalEvidence();
      evidenceCall += 1;
      return { ...current, digest: `${current.digest}-${evidenceCall}` };
    });
    const materialize = vi.spyOn(internals, "sessionInfos");
    const publishIdentity = vi.spyOn(internals, "updateCatalogIdentity");

    try {
      await expect(fixture.registry.catalog("all")).rejects.toMatchObject({ code: "busy", retryable: true });
      expect(materialize).toHaveBeenCalledTimes(2);
      expect(publishIdentity).not.toHaveBeenCalled();
      expect(internals.catalogAcquisitionAdmission).toBeUndefined();
    } finally {
      evidence.mockRestore();
    }
  });

  it("bounds validation reads and retained acquisition evidence before publication", async () => {
    const headerFixture = await coldFixture("header-bound");
    const headerRegistry = new RuntimeRegistry({
      agentDir: headerFixture.agentDir,
      tronHome: join(headerFixture.root, "tron-header-bound"),
      idleRuntimeMs: 60_000,
      trust: new TrustService(headerFixture.agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
      catalogDiscoveryLimits: { maximumHeaderBytes: 1 },
    });
    registries.push(headerRegistry);
    await expect(headerRegistry.catalog("all")).resolves.toMatchObject({
      sessions: expect.arrayContaining([expect.objectContaining({ id: headerFixture.manager.getSessionId() })]),
    });

    const admissionRegistry = new RuntimeRegistry({
      agentDir: headerFixture.agentDir,
      tronHome: join(headerFixture.root, "tron-admission-bound"),
      idleRuntimeMs: 60_000,
      trust: new TrustService(headerFixture.agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
      catalogDiscoveryLimits: { maximumAcquisitionBytes: 1 },
    });
    registries.push(admissionRegistry);
    await expect(admissionRegistry.catalog("all")).resolves.toMatchObject({
      sessions: expect.arrayContaining([expect.objectContaining({ id: headerFixture.manager.getSessionId() })]),
    });
    await expect(admissionRegistry.acquire(headerFixture.manager.getSessionId()))
      .rejects.toMatchObject({ code: "busy", retryable: true });
  });

  it("admits scaled short headers within the aggregate validation budget", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-catalog-short-header-budget-"));
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
    const registry = new RuntimeRegistry({
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
    const internals = registry as unknown as {
      catalogAcquisition: () => Promise<{ entriesByID: ReadonlyMap<string, unknown> }>;
      readCatalogHeader: (...arguments_: any[]) => Promise<unknown>;
    };
    const original = internals.readCatalogHeader.bind(registry);
    let active = 0;
    let maximumActive = 0;
    let releaseResolve!: () => void;
    let capacityResolve!: () => void;
    const release = new Promise<void>((resolve) => { releaseResolve = resolve; });
    const capacity = new Promise<void>((resolve) => { capacityResolve = resolve; });
    const headers = vi.spyOn(internals, "readCatalogHeader").mockImplementation(async (...arguments_) => {
      active += 1;
      maximumActive = Math.max(maximumActive, active);
      if (maximumActive === 4) capacityResolve();
      await release;
      try { return await original(...arguments_); }
      finally { active -= 1; }
    });

    const acquiring = internals.catalogAcquisition();
    await capacity;
    expect(maximumActive).toBe(4);
    releaseResolve();
    expect((await acquiring).entriesByID.size).toBe(count);
    expect(headers).toHaveBeenCalledTimes(count);
  });

  it("reserves a deterministic aggregate header-read budget across concurrent readers", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-catalog-strict-header-budget-"));
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
    const registry = new RuntimeRegistry({
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
    expect(first.complete).toBe(false);
    expect(first.identitiesByPath.size).toBe(4);
    expect([...first.identitiesByPath.keys()]).toEqual([...second.identitiesByPath.keys()]);
    expect(first.digest).toBe(second.digest);
  });

  it("acquires from header evidence while a full catalog materialization is suspended", async () => {
    const fixture = await coldFixture("concurrent-list");
    const internals = fixture.registry as unknown as { sessionInfos: () => Promise<unknown[]> };
    const original = internals.sessionInfos.bind(fixture.registry);
    let suspendedResolve!: () => void;
    let releaseResolve!: () => void;
    const suspended = new Promise<void>((resolve) => { suspendedResolve = resolve; });
    const release = new Promise<void>((resolve) => { releaseResolve = resolve; });
    const materialize = vi.spyOn(internals, "sessionInfos").mockImplementation(async () => {
      suspendedResolve();
      await release;
      return original();
    });

    const listing = fixture.registry.catalog("all");
    await suspended;
    try {
      expect((await fixture.registry.acquire(fixture.manager.getSessionId())).id)
        .toBe(fixture.manager.getSessionId());
      expect(materialize).toHaveBeenCalledTimes(1);
    } finally {
      releaseResolve();
    }
    await expect(listing).resolves.toMatchObject({
      sessions: expect.arrayContaining([expect.objectContaining({ id: fixture.manager.getSessionId() })]),
    });
  });

  it("never stamps captured stale catalog fields with a newer summary revision", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-catalog-summary-race-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    const faux = fauxProvider({ provider: "tron-catalog-race", tokensPerSecond: 10_000 });
    faux.setResponses([fauxAssistantMessage("catalog ready")]);
    runtime.registerNativeProvider(faux.provider);
    const summaries: SessionSummaryUpdate[] = [];
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: (summary) => summaries.push(summary),
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("catalog race baseline");
    await waitUntil(() => !slot.isBusy);

    const internals = registry as unknown as { sessionInfos: () => Promise<unknown[]> };
    const originalSessionInfos = internals.sessionInfos.bind(registry);
    let capturedResolve!: () => void;
    let releaseResolve!: () => void;
    const captured = new Promise<void>((resolve) => { capturedResolve = resolve; });
    const release = new Promise<void>((resolve) => { releaseResolve = resolve; });
    vi.spyOn(internals, "sessionInfos").mockImplementation(async () => {
      const infos = await originalSessionInfos();
      capturedResolve();
      await release;
      return infos;
    });

    const loading = registry.catalog("user");
    await captured;
    await slot.rename("new authoritative name");
    const latest = summaries.at(-1)!;
    releaseResolve();
    const catalog = await loading;

    expect(catalog.sessions[0]?.name).toBe(latest.name);
    expect(catalog.sessions[0]?.phase).toBe(latest.phase);
    expect(catalog.sessions[0]?.messageCount).toBe(latest.messageCount);
    expect(catalog.sessions[0]?.summaryRevision).toBe(latest.summaryRevision);
  });

  it("fails closed when multiple canonical files claim one session ID", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-catalog-duplicate-id-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    const faux = fauxProvider({ provider: "tron-duplicate-session-id", tokensPerSecond: 10_000 });
    faux.setResponses([fauxAssistantMessage("persisted")]);
    runtime.registerNativeProvider(faux.provider);
    const registry = new RuntimeRegistry({
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
    await registry.initialize();
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("persist duplicate ownership fixture");
    await waitUntil(() => !slot.isBusy);
    const internals = registry as unknown as {
      sessionInfos: () => Promise<Array<Record<string, unknown>>>;
    };
    const originalSessionInfos = internals.sessionInfos.bind(registry);
    const existing = (await originalSessionInfos()).find((session) => session.id === slot.id)!;
    const duplicate = {
      ...existing,
      path: join(root, "duplicate", `${slot.id}.jsonl`),
    };
    let reverseDiscoveryOrder = false;
    const discovery = vi.spyOn(internals, "sessionInfos").mockImplementation(async () => (
      reverseDiscoveryOrder ? [duplicate, existing] : [existing, duplicate]
    ));

    const conflicted = await registry.catalog("all");
    expect(conflicted.sessions.find((session) => session.id === slot.id)).toBeUndefined();
    reverseDiscoveryOrder = true;
    const reordered = await registry.catalog("all");
    expect(reordered.listRevision).toBe(conflicted.listRevision);
    expect(reordered.sessions.find((session) => session.id === slot.id)).toBeUndefined();
    // Open admission uses current canonical headers rather than the stale global
    // ambiguity last projected by a mocked full catalog.
    expect((await registry.acquire(slot.id)).id).toBe(slot.id);
    await expect(registry.delete(slot.id)).rejects.toMatchObject({ code: "conflict" });

    discovery.mockRestore();
    const repaired = await registry.catalog("all");
    expect(repaired.sessions.filter((session) => session.id === slot.id)).toHaveLength(1);
    expect((await registry.acquire(slot.id)).id).toBe(slot.id);
  });

  it("runs distinct sessions concurrently and keeps a run alive after its client disconnects", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-runtime-integration-"));
    const agentDir = join(root, "agent");
    const tronHome = join(root, "tron");
    const firstCwd = join(root, "first");
    const secondCwd = join(root, "second");
    await Promise.all([mkdir(agentDir), mkdir(tronHome), mkdir(firstCwd), mkdir(secondCwd)]);
    process.env.PI_CODING_AGENT_DIR = agentDir;

    const faux = fauxProvider({ provider: "tron-test", tokensPerSecond: 10_000 });
    const runtimes: ModelRuntime[] = [];
    const summaryUpdates: Array<{ sessionId: string; phase: string }> = [];
    const createModels = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      runtimes.push(runtime);
      return runtime;
    };
    faux.setResponses([
      async () => { await new Promise((resolve) => setTimeout(resolve, 150)); return fauxAssistantMessage("first complete"); },
      async () => { await new Promise((resolve) => setTimeout(resolve, 150)); return fauxAssistantMessage("second complete"); },
    ]);

    const registry = new RuntimeRegistry({
      agentDir,
      tronHome,
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: createModels,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: (summary) => summaryUpdates.push(summary),
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();

    const [first, second] = await Promise.all([registry.create(firstCwd), registry.create(secondCwd)]);
    expect(first.modelRuntime).not.toBe(second.modelRuntime);
    expect(runtimes).toHaveLength(2);
    const model = faux.getModel();
    await Promise.all([first.setModel(model.provider, model.id), second.setModel(model.provider, model.id)]);
    registry.subscribe("phone", first.id);
    registry.subscribe("phone", second.id);

    await Promise.all([first.prompt("one"), second.prompt("two")]);
    await waitUntil(() => first.isBusy && second.isBusy);
    expect(faux.state.callCount).toBe(2);
    expect(summaryUpdates).toEqual(expect.arrayContaining([
      expect.objectContaining({ sessionId: first.id, phase: "running" }),
      expect.objectContaining({ sessionId: second.id, phase: "running" }),
    ]));

    registry.unsubscribeClient("phone");
    expect(first.isBusy).toBe(true);
    expect(second.isBusy).toBe(true);
    let drainCompleted = false;
    const drain = registry.waitUntilIdle().then(() => { drainCompleted = true; });
    await new Promise((resolve) => setTimeout(resolve, 30));
    expect(drainCompleted).toBe(false);

    await waitUntil(() => !first.isBusy && !second.isBusy);
    await drain;
    expect(drainCompleted).toBe(true);
    const hasCompletion = (slot: typeof first) => slot.snapshot().transcript.some(
      (item) => item.kind === "message" && item.role === "assistant" && item.content.some(
        (part) => part.type === "text" && part.text.includes("complete"),
      ),
    );
    expect(hasCompletion(first)).toBe(true);
    expect(hasCompletion(second)).toBe(true);
    expect(summaryUpdates.filter((update) => update.phase === "idle").map((update) => update.sessionId)).toEqual(
      expect.arrayContaining([first.id, second.id]),
    );
  });

  it("runs the unchanged official status and working-indicator examples with the baseline theme", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-official-semantic-examples-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await Promise.all([mkdir(agentDir), mkdir(extensionDir, { recursive: true })]);
    const examples = join(getExamplesPath(), "extensions");
    await Promise.all([
      copyFile(join(examples, "status-line.ts"), join(extensionDir, "status-line.ts")),
      copyFile(join(examples, "working-indicator.ts"), join(extensionDir, "working-indicator.ts")),
    ]);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const faux = fauxProvider({ provider: "tron-official-examples", tokensPerSecond: 10_000 });
    faux.setResponses([fauxAssistantMessage("persisted")]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust,
      modelRuntimeFactory: async () => runtime,
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const presentation = slot.snapshot().extensionPresentation;
    expect(presentation.semanticState.statuses["status-demo"]).toBe("Ready");
    expect(presentation.semanticState.statuses["working-indicator"]).toBe("Indicator: custom spinner");
    expect(presentation.semanticState.working.indicator).toMatchObject({ kind: "animated", intervalMs: 80 });
    expect(presentation.semanticState.working.indicator.frames.every((frame) => !frame.includes("\u001b"))).toBe(true);
    expect(slot.isBusy).toBe(false);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("persist session");
    await waitUntil(() => !slot.isBusy);
    await registry.reloadProject(cwd, true);
    expect(slot.snapshot().extensionPresentation.hostEpoch).not.toBe(presentation.hostEpoch);
    await slot.rename("decorative-state-delete-fixture");
    const sessionID = slot.id;
    await registry.delete(sessionID);
    await expect(registry.acquire(sessionID)).rejects.toMatchObject({ code: "not_found" });
  });

  it("projects retained component widgets through the RPC-bound host without enabling TUI mode", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-rpc-factory-dormant-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await mkdir(extensionDir, { recursive: true });
    await writeFile(join(extensionDir, "rpc-factory.ts"), `export default function (pi) {
      let invoked = false;
      pi.on("session_start", async (_event, ctx) => {
        ctx.ui.setStatus("context-has-ui", ctx.hasUI ? "true" : "false");
        ctx.ui.setStatus("context-mode", ctx.mode);
        ctx.ui.setWidget("factory", () => ({
          render: () => ["must mount"], invalidate: () => {}
        }));
        try {
          await ctx.ui.custom(() => {
            invoked = true;
            return { render: () => ["must not invoke"], invalidate: () => {} };
          });
        } catch {
          ctx.ui.setStatus("custom-deferred", invoked ? "invoked" : "not-invoked");
        }
      });
    }\n`);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust,
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const internal = slot as unknown as { extensionHost: { isTuiStarted: boolean; mountedComponentCount: number } };
    await waitUntil(() => internal.extensionHost.mountedComponentCount === 1);
    expect(internal.extensionHost.isTuiStarted).toBe(true);
    const snapshot = slot.snapshot();
    expect(snapshot.extensionPresentation.semanticState.statuses).toMatchObject({
      "context-has-ui": "true", "context-mode": "rpc", "custom-deferred": "not-invoked",
    });
    expect(snapshot.extensionPresentation.semanticState.widgets).toEqual([]);
    expect(snapshot.extensionPresentation.surfaces).toEqual(expect.arrayContaining([
      expect.objectContaining({ id: "widget:ZmFjdG9yeQ", kind: "widget", placement: "aboveEditor", inputMode: "none" }),
    ]));
  });

  it("keeps ask-style semantic selection on the RPC interaction path", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-rpc-semantic-ask-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await mkdir(extensionDir, { recursive: true });
    await writeFile(join(extensionDir, "semantic-ask.ts"), `export default function (pi) {
      pi.registerCommand("semantic-ask", { handler: async (_args, ctx) => {
        const answer = await ctx.ui.select("Choose a path", ["Keep", "Change"]);
        ctx.ui.setStatus("answer", answer ?? "Cancelled");
      }});
    }\n`);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust,
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const command = slot.prompt("/semantic-ask");
    await waitUntil(() => slot.snapshot().extensionPresentation.pendingInteractions.length === 1);
    const pending = slot.snapshot().extensionPresentation.pendingInteractions[0]!;
    expect(pending.method).toBe("select");
    expect(pending.options).toEqual(["Keep", "Change"]);
    const internal = slot as unknown as { respondToInteraction: (id: string, epoch: string, revision: number, value: unknown, cancelled: boolean) => void };
    internal.respondToInteraction(pending.id, pending.hostEpoch, pending.presentationRevision, "Keep", false);
    await command;
    expect(slot.snapshot().extensionPresentation.semanticState.statuses.answer).toBe("Keep");
  });

  it("rotates and retires semantic epochs on direct, command, and trust reload paths", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-semantic-epoch-reload-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await Promise.all([mkdir(agentDir), mkdir(extensionDir, { recursive: true })]);
    await writeFile(join(extensionDir, "reload.ts"), `export default function (pi) {
      pi.on("session_start", (_event, ctx) => ctx.ui.setStatus("epoch", "started"));
      pi.registerCommand("reload-host", { handler: async (_args, ctx) => ctx.reload() });
    }\n`);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust,
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const internal = slot as unknown as { ui: { context(): { confirm(title: string, message: string): Promise<boolean>; setStatus(key: string, text: string): void } } };
    const oldContext = internal.ui.context();
    const firstEpoch = slot.snapshot().extensionPresentation.hostEpoch;

    await slot.reload();
    const secondEpoch = slot.snapshot().extensionPresentation.hostEpoch;
    expect(secondEpoch).not.toBe(firstEpoch);
    expect(() => oldContext.setStatus("late", "old callback")).toThrow(expect.objectContaining({ code: "conflict" }));

    const pending = internal.ui.context().confirm("Pending", "Retire me");
    // Attach rejection observation before the command retires the epoch.
    const retiredPending = expect(pending).rejects.toMatchObject({ code: "cancelled" });
    await slot.prompt("/reload-host");
    await retiredPending;
    const thirdEpoch = slot.snapshot().extensionPresentation.hostEpoch;
    expect(thirdEpoch).not.toBe(secondEpoch);
    await registry.reloadProject(cwd, true);
    expect(slot.snapshot().extensionPresentation.hostEpoch).not.toBe(thirdEpoch);
  });

  it("does not let an older settlement hide an extension-triggered continuation", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-settlement-overlap-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([
      mkdir(agentDir),
      mkdir(join(cwd, ".pi", "extensions"), { recursive: true }),
    ]);
    await writeFile(join(cwd, ".pi", "extensions", "continuation.ts"), `
let triggered = false;
export default function (pi) {
  pi.on("agent_settled", () => {
    if (triggered) return;
    triggered = true;
    pi.sendMessage({ customType: "test-continuation", content: "continue", display: false }, { triggerTurn: true });
  });
}
`);

    const faux = fauxProvider({ provider: "tron-settlement-overlap", tokensPerSecond: 10_000 });
    const createModels = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    faux.setResponses([
      fauxAssistantMessage("first complete"),
      async () => {
        await new Promise((resolve) => setTimeout(resolve, 250));
        return fauxAssistantMessage("continuation complete");
      },
    ]);
    const snapshots: Array<{ phase: string; operation?: unknown }> = [];
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: createModels,
      trust,
      broadcast: (_sessionId, topic, payload) => {
        if (topic === "session.snapshot") snapshots.push(payload as { phase: string; operation?: unknown });
      },
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    expect(slot.sessionFile?.startsWith(join(agentDir, "sessions"))).toBe(true);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("start");

    await waitUntil(() => faux.state.callCount === 2);
    expect(slot.snapshot()).toMatchObject({ phase: "running", operation: { kind: "prompt" } });
    const continuationSnapshotIndex = snapshots.length;
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(snapshots.slice(continuationSnapshotIndex).every((snapshot) => snapshot.phase === "running" && snapshot.operation)).toBe(true);
    await waitUntil(() => !slot.isBusy);
    expect(slot.snapshot()).toMatchObject({ phase: "idle" });
    expect(snapshots.some((snapshot) => snapshot.phase === "running" && snapshot.operation)).toBe(true);
  });

  it("coalesces streaming progress frames while keeping the event stream contiguous and complete", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-streaming-coalesce-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    process.env.PI_CODING_AGENT_DIR = agentDir;

    // Deterministic 4-character chunks at 100 tokens/second stream ~240 SDK
    // updates over ~2.4 seconds. Uncoalesced, every update would republish the
    // cumulative message to each subscriber.
    const text = "streaming chunk ".repeat(60);
    const faux = fauxProvider({ provider: "tron-streaming-coalesce", tokensPerSecond: 100, tokenSize: { min: 1, max: 1 } });
    const createModels = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    faux.setResponses([fauxAssistantMessage(text)]);
    const events: Array<{ topic: string; payload: { eventSequence?: number; data?: any } }> = [];
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: createModels,
      trust: new TrustService(agentDir),
      broadcast: (_sessionId, topic, payload) => events.push({ topic, payload: payload as { eventSequence?: number; data?: any } }),
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("stream");
    await waitUntil(() => !slot.isBusy);
    expect(slot.snapshot().pendingPrompt).toBeUndefined();

    const progress = events.filter((event) => event.topic === "session.progress");
    expect(progress.length).toBeGreaterThanOrEqual(2);
    expect(progress.length).toBeLessThanOrEqual(40);

    // Coalescing must never reorder or gap the sequenced event stream.
    const sequenced = events.filter((event) => typeof event.payload.eventSequence === "number");
    for (let index = 1; index < sequenced.length; index += 1) {
      expect(sequenced[index]!.payload.eventSequence).toBe(sequenced[index - 1]!.payload.eventSequence! + 1);
    }

    // The last live frame carries the complete cumulative message and the
    // settled canonical transcript keeps the full text.
    const lastMessage = progress.at(-1)!.payload.data?.message;
    const lastText = (lastMessage?.content ?? []).filter((part: any) => part.type === "text").map((part: any) => part.text).join("");
    expect(lastText.trimEnd().endsWith("streaming chunk")).toBe(true);
    const transcriptText = slot.snapshot().transcript
      .filter((item) => item.kind === "message")
      .flatMap((item) => item.kind === "message" ? item.content : [])
      .filter((part) => part.type === "text")
      .map((part) => part.type === "text" ? part.text : "")
      .join("");
    expect(transcriptText).toContain(text.trimEnd());
  });

  it("keeps async input preflight alive and settles accepted handled input exactly once", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-input-handled-preflight-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await Promise.all([mkdir(agentDir), mkdir(extensionDir, { recursive: true })]);
    await writeFile(join(extensionDir, "handled.ts"), `export default function (pi) {
      pi.on("input", async () => {
        await new Promise((resolve) => setTimeout(resolve, 200));
        return { action: "handled" };
      });
    }\n`);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust,
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const prompting = slot.prompt("handled without agent");
    await waitUntil(() => slot.isBusy);
    await expect(slot.dispose()).rejects.toMatchObject({ code: "busy" });
    await expect(prompting).resolves.toMatchObject({ operationId: expect.any(String) });
    await waitUntil(() => !slot.isBusy);
    expect(slot.snapshot()).toMatchObject({ phase: "idle" });
    expect(slot.snapshot().operation).toBeUndefined();
    const markerStore = (registry as unknown as { markers: { interruptedSessionIds(): Promise<Set<string>> } }).markers;
    expect((await markerStore.interruptedSessionIds()).has(slot.id)).toBe(false);
  });

  it("cuts off extension auto-continuations during administrative drain", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-drain-continuation-cutoff-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await Promise.all([mkdir(agentDir), mkdir(extensionDir, { recursive: true })]);
    await writeFile(join(extensionDir, "continue.ts"), `let sent = false;
      export default function (pi) {
        pi.on("agent_settled", () => {
          if (sent) return;
          sent = true;
          pi.sendMessage({ customType: "after-cutoff", content: "continue", display: false }, { triggerTurn: true });
        });
      }\n`);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const faux = fauxProvider({ provider: "tron-drain-cutoff", tokensPerSecond: 10_000 });
    faux.setResponses([
      async () => { await new Promise((resolve) => setTimeout(resolve, 150)); return fauxAssistantMessage("first"); },
      fauxAssistantMessage("must be aborted"),
    ]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const failures: unknown[] = [];
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust,
      modelRuntimeFactory: async () => runtime,
      broadcast: (_id, topic, payload) => { if (topic === "session.operationFailed") failures.push(payload); },
      sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("start");
    await waitUntil(() => slot.catalogPhase === "running");
    await registry.waitUntilIdle(5_000);
    expect(slot.isDrainBusy).toBe(false);
    expect(failures).not.toEqual([]);
  });

  it("uses runtime preflight as the sole prompt-admission outcome", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-prompt-preflight-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    const registry = new RuntimeRegistry({
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
    await registry.initialize();
    const slot = await registry.create(cwd);
    const session = (slot as unknown as {
      runtime: { session: { prompt: (
        text: string,
        options?: { preflightResult?: (accepted: boolean) => void },
      ) => Promise<void> } };
    }).runtime.session;
    let startedResolve!: () => void;
    const started = new Promise<void>((resolve) => { startedResolve = resolve; });
    vi.spyOn(session, "prompt").mockImplementationOnce(async (_text, options) => {
      startedResolve();
      await new Promise((resolve) => setTimeout(resolve, 6_000));
      options?.preflightResult?.(true);
    });

    vi.useFakeTimers();
    try {
      const prompting = slot.prompt("delayed preflight");
      await started;
      expect(slot.snapshot().pendingPrompt).toMatchObject({
        id: expect.any(String),
        text: "delayed preflight",
        attachmentCount: 0,
      });
      await vi.advanceTimersByTimeAsync(6_000);
      await expect(prompting).resolves.toMatchObject({ operationId: expect.any(String) });
    } finally {
      vi.useRealTimers();
    }
  });

  it("exports the complete canonical JSONL tree including abandoned branches", async () => {
    const fixture = await coldFixture("complete-jsonl-export");
    await fixture.registry.initializeBlobStorage();
    fixture.manager.appendMessage({ role: "user", content: "root prompt", timestamp: Date.now() });
    const rootEntry = fixture.manager.getEntries().at(-1)!;
    fixture.manager.appendMessage(fauxAssistantMessage("abandoned branch response"));
    const abandonedEntry = fixture.manager.getEntries().at(-1)!;
    fixture.manager.branch(rootEntry.id);
    fixture.manager.appendMessage(fauxAssistantMessage("active branch response"));
    const activeEntry = fixture.manager.getEntries().at(-1)!;

    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const artifact = await slot.export("jsonl");
    const lease = await fixture.registry.acquireBlob(artifact.blobId);
    let exported = "";
    try {
      for await (const chunk of lease.stream) exported += Buffer.from(chunk).toString("utf8");
    } finally {
      await lease.release();
    }

    const lines = exported.trimEnd().split("\n").map((line) => JSON.parse(line) as {
      id?: string;
      parentId?: string | null;
    });
    expect(lines.some((entry) => entry.id === abandonedEntry.id && entry.parentId === rootEntry.id)).toBe(true);
    expect(lines.some((entry) => entry.id === activeEntry.id && entry.parentId === rootEntry.id)).toBe(true);
    expect(exported).toContain("abandoned branch response");
    expect(exported).toContain("active branch response");
  });

  it("clears branch-summary operation state when tree navigation rejects or is cancelled", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-navigation-cleanup-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    const snapshots: Array<{ phase: string; operation?: { kind: string }; retry?: unknown }> = [];
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime,
      trust: new TrustService(agentDir),
      broadcast: (_sessionId, topic, payload) => {
        if (topic === "session.snapshot") snapshots.push(payload as { phase: string; operation?: { kind: string }; retry?: unknown });
      },
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const session = (slot as unknown as {
      runtime: { session: { navigateTree: (targetId: string, options: unknown) => Promise<{ cancelled: boolean }> } };
    }).runtime.session;
    const navigate = vi.spyOn(session, "navigateTree");

    navigate.mockRejectedValueOnce(new Error("navigation failed"));
    await expect(slot.navigate("target", { summarize: true })).rejects.toThrow("navigation failed");
    expect(slot.snapshot()).toMatchObject({ phase: "idle" });
    expect(slot.snapshot().operation).toBeUndefined();
    expect(slot.snapshot().retry).toBeUndefined();

    navigate.mockResolvedValueOnce({ cancelled: true });
    await expect(slot.navigate("target", { summarize: true })).rejects.toMatchObject({ code: "cancelled" });
    expect(slot.snapshot().operation).toBeUndefined();
    expect(slot.snapshot().retry).toBeUndefined();
    expect(snapshots.at(-1)?.operation).toBeUndefined();
  });

  it("projects and atomically manages multiple queued messages by stable identity", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-queue-management-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);

    let releaseResponse!: () => void;
    const responseBarrier = new Promise<void>((resolve) => { releaseResponse = resolve; });
    const faux = fauxProvider({ provider: "tron-queue-management", tokensPerSecond: 10_000 });
    faux.setResponses([
      async () => {
        await responseBarrier;
        return fauxAssistantMessage("initial complete");
      },
      fauxAssistantMessage("queued complete"),
      fauxAssistantMessage("follow-up complete"),
    ]);
    const createModels = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: createModels,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("start");
    await waitUntil(() => slot.isBusy);

    await slot.prompt("first steer", [], "steer", {
      text: "first steer",
      attachmentEnvelope: "",
      attachmentCount: 0,
    });
    await slot.prompt("first steer", [], "steer", {
      text: "first steer",
      attachmentEnvelope: "",
      attachmentCount: 0,
    });
    await slot.prompt("later follow-up", [], "followUp", {
      text: "later follow-up",
      attachmentEnvelope: "",
      attachmentCount: 0,
    });
    const queued = slot.snapshot();
    expect(queued.queuedItems).toHaveLength(3);
    expect(queued.queuedItems?.map((item) => item.behavior)).toEqual(["steer", "steer", "followUp"]);
    expect(queued.queuedItems?.map((item) => item.text)).toEqual(["first steer", "first steer", "later follow-up"]);
    expect(new Set(queued.queuedItems?.map((item) => item.id)).size).toBe(3);

    const [first, duplicate, followUp] = queued.queuedItems!;
    const replaced = await slot.replaceQueue(queued.queueRevision!, [
      { id: duplicate!.id, behavior: "steer", text: duplicate!.text },
      { id: followUp!.id, behavior: "steer", text: "edited and earlier" },
      { id: first!.id, behavior: "followUp", text: first!.text },
    ]);
    expect(replaced.items.map(({ id, behavior, text }) => ({ id, behavior, text }))).toEqual([
      { id: duplicate!.id, behavior: "steer", text: "first steer" },
      { id: followUp!.id, behavior: "steer", text: "edited and earlier" },
      { id: first!.id, behavior: "followUp", text: "first steer" },
    ]);
    await expect(slot.replaceQueue(queued.queueRevision!, [])).rejects.toMatchObject({ code: "conflict" });

    const removed = await slot.replaceQueue(replaced.queueRevision, [replaced.items[1]!]);
    expect(removed.items).toHaveLength(1);
    expect(removed.items[0]?.id).toBe(followUp!.id);

    const cleared = await slot.clearQueue();
    expect(cleared.steering).toEqual(["edited and earlier"]);
    expect(slot.snapshot().queuedItems).toEqual([]);
    await expect(slot.replaceQueue(removed.queueRevision, removed.items))
      .rejects.toMatchObject({ code: "conflict" });

    releaseResponse();
    await waitUntil(() => !slot.isBusy);
  });

  it("queues one manual compaction behind an active run and keeps its receipt pending", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-queued-compaction-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);

    let releaseResponse!: () => void;
    const responseBarrier = new Promise<void>((resolve) => { releaseResponse = resolve; });
    let releaseCompaction!: () => void;
    const compactionBarrier = new Promise<void>((resolve) => { releaseCompaction = resolve; });
    const faux = fauxProvider({ provider: "tron-queued-compaction", tokensPerSecond: 10_000 });
    faux.setResponses([async () => {
      await responseBarrier;
      return fauxAssistantMessage("run complete");
    }]);
    const createModels = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: createModels,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const session = (slot as unknown as {
      runtime: { session: { compact: (instructions?: string) => Promise<unknown> } };
    }).runtime.session;
    const compact = vi.spyOn(session, "compact").mockImplementation(async () => {
      await compactionBarrier;
      return {};
    });
    let releaseMarker!: () => void;
    const markerBarrier = new Promise<void>((resolve) => { releaseMarker = resolve; });
    const markerStore = (slot as unknown as {
      dependencies: { markers: { clear: (sessionId: string) => Promise<void> } };
    }).dependencies.markers;
    const clearMarker = vi.spyOn(markerStore, "clear").mockImplementation(async () => markerBarrier);

    await slot.prompt("start");
    await waitUntil(() => slot.isBusy);
    const queuedCompaction = slot.compact("Preserve exact decisions");
    await waitUntil(() => slot.snapshot().compactionQueued === true);

    expect(slot.snapshot()).toMatchObject({
      phase: "running",
      compactionQueued: true,
      automaticCompactionEnabled: true,
    });
    expect(registry.activeSessionIds()).toContain(slot.id);
    await expect(slot.compact()).rejects.toMatchObject({
      code: "busy",
      message: "A manual compaction is already pending for this session",
    });
    expect(compact).not.toHaveBeenCalled();

    releaseResponse();
    await waitUntil(() => compact.mock.calls.length === 1);
    expect(compact).toHaveBeenCalledWith("Preserve exact decisions");
    expect(slot.snapshot()).toMatchObject({ phase: "compacting", compactionQueued: false });
    expect(registry.activeSessionIds()).toContain(slot.id);

    let queuedSettled = false;
    void queuedCompaction.then(() => { queuedSettled = true; }, () => {});
    releaseCompaction();
    await waitUntil(() => clearMarker.mock.calls.length === 1);
    await Promise.resolve();
    expect(queuedSettled).toBe(false);
    expect(registry.activeSessionIds()).toContain(slot.id);
    releaseMarker();
    await expect(queuedCompaction).resolves.toEqual({ queued: true });
    await waitUntil(() => !slot.isBusy);
    expect(slot.snapshot()).toMatchObject({ phase: "idle", compactionQueued: false });
    expect(registry.activeSessionIds()).not.toContain(slot.id);
  });

  it("cleans up queued manual compaction state when canonical compaction fails", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-queued-compaction-failure-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);

    let releaseResponse!: () => void;
    const responseBarrier = new Promise<void>((resolve) => { releaseResponse = resolve; });
    const faux = fauxProvider({ provider: "tron-queued-compaction-failure", tokensPerSecond: 10_000 });
    faux.setResponses([async () => {
      await responseBarrier;
      return fauxAssistantMessage("run complete");
    }]);
    const createModels = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: createModels,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const session = (slot as unknown as {
      runtime: { session: { compact: (instructions?: string) => Promise<unknown> } };
    }).runtime.session;
    vi.spyOn(session, "compact").mockRejectedValue(new Error("manual compaction failed"));

    await slot.prompt("start");
    await waitUntil(() => slot.isBusy);
    const queuedCompaction = slot.compact();
    const failure = expect(queuedCompaction).rejects.toThrow("manual compaction failed");
    await waitUntil(() => slot.snapshot().compactionQueued === true);
    releaseResponse();
    await failure;
    await waitUntil(() => !slot.isBusy);
    expect(slot.snapshot()).toMatchObject({ phase: "idle", compactionQueued: false });
    expect(slot.snapshot().operation).toBeUndefined();
  });

  it("does not publish queued compaction as settled when durable marker removal fails", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-compaction-marker-failure-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    let releaseResponse!: () => void;
    const responseBarrier = new Promise<void>((resolve) => { releaseResponse = resolve; });
    const faux = fauxProvider({ provider: "tron-compaction-marker-failure", tokensPerSecond: 10_000 });
    faux.setResponses([async () => {
      await responseBarrier;
      return fauxAssistantMessage("run complete");
    }]);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => {
        const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
        runtime.registerNativeProvider(faux.provider);
        return runtime;
      },
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const session = (slot as unknown as {
      runtime: { session: { compact: (instructions?: string) => Promise<unknown> } };
    }).runtime.session;
    vi.spyOn(session, "compact").mockResolvedValue({});
    const markerStore = (slot as unknown as {
      dependencies: { markers: { clear: (sessionId: string) => Promise<void> } };
    }).dependencies.markers;
    const clearMarker = vi.spyOn(markerStore, "clear")
      .mockRejectedValueOnce(new Error("marker removal failed"));

    await slot.prompt("start");
    await waitUntil(() => slot.isBusy);
    const queuedCompaction = slot.compact();
    await waitUntil(() => slot.snapshot().compactionQueued === true);
    releaseResponse();
    await expect(queuedCompaction).rejects.toThrow("marker removal failed");
    expect(slot.snapshot()).toMatchObject({ phase: "interrupted", compactionQueued: false });
    expect(slot.snapshot().operation).toBeUndefined();
    clearMarker.mockRestore();
  });

  it("admits only one direct manual compaction and retains the claim through completion", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-direct-compaction-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }),
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    let releaseCompaction!: () => void;
    const barrier = new Promise<void>((resolve) => { releaseCompaction = resolve; });
    const session = (slot as unknown as {
      runtime: { session: { compact: (instructions?: string) => Promise<unknown> } };
    }).runtime.session;
    const compact = vi.spyOn(session, "compact").mockImplementation(async () => {
      await barrier;
      return {};
    });

    const first = slot.compact("Keep decisions");
    await waitUntil(() => slot.snapshot().phase === "compacting");
    expect(registry.activeSessionIds()).toContain(slot.id);
    await expect(slot.compact()).rejects.toMatchObject({
      code: "busy",
      message: "A manual compaction is already pending for this session",
    });
    expect(compact).toHaveBeenCalledTimes(1);

    releaseCompaction();
    await expect(first).resolves.toEqual({ queued: false });
    await waitUntil(() => !slot.isBusy);
    expect(slot.snapshot()).toMatchObject({ phase: "idle", compactionQueued: false });
  });

  it("cleans up a failed direct manual compaction claim", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-direct-compaction-failure-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }),
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const session = (slot as unknown as {
      runtime: { session: { compact: (instructions?: string) => Promise<unknown> } };
    }).runtime.session;
    const compact = vi.spyOn(session, "compact")
      .mockRejectedValueOnce(new Error("direct compaction failed"))
      .mockResolvedValueOnce({});

    await expect(slot.compact()).rejects.toThrow("direct compaction failed");
    expect(slot.snapshot()).toMatchObject({ phase: "idle", compactionQueued: false });
    expect(slot.snapshot().operation).toBeUndefined();
    await expect(slot.compact()).resolves.toEqual({ queued: false });
    expect(compact).toHaveBeenCalledTimes(2);
  });

  it("defers queued compaction when a newer prompt enters preflight before handoff", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-compaction-handoff-race-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    let releaseFirst!: () => void;
    let releaseSecond!: () => void;
    const firstBarrier = new Promise<void>((resolve) => { releaseFirst = resolve; });
    const secondBarrier = new Promise<void>((resolve) => { releaseSecond = resolve; });
    const faux = fauxProvider({ provider: "tron-compaction-handoff-race", tokensPerSecond: 10_000 });
    faux.setResponses([
      async () => { await firstBarrier; return fauxAssistantMessage("first complete"); },
      async () => { await secondBarrier; return fauxAssistantMessage("second complete"); },
    ]);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => {
        const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
        runtime.registerNativeProvider(faux.provider);
        return runtime;
      },
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const runtimeSession = (slot as unknown as {
      runtime: { session: {
        compact: (instructions?: string) => Promise<unknown>;
        isStreaming: boolean;
      } };
    }).runtime.session;
    const compact = vi.spyOn(runtimeSession, "compact").mockResolvedValue({});
    const lane = (slot as unknown as {
      lane: { run<T>(operation: () => Promise<T> | T): Promise<T> };
    }).lane;

    await slot.prompt("first");
    await waitUntil(() => runtimeSession.isStreaming);
    const queuedCompaction = slot.compact();
    await waitUntil(() => slot.snapshot().compactionQueued === true);

    let releaseLane!: () => void;
    let laneEntered!: () => void;
    const laneWasEntered = new Promise<void>((resolve) => { laneEntered = resolve; });
    const laneBarrier = new Promise<void>((resolve) => { releaseLane = resolve; });
    const blocker = lane.run(async () => {
      laneEntered();
      await laneBarrier;
    });
    await laneWasEntered;
    const newerPrompt = slot.prompt("newer");
    releaseFirst();
    await waitUntil(() => !runtimeSession.isStreaming);
    releaseLane();
    await blocker;
    await newerPrompt;
    await waitUntil(() => runtimeSession.isStreaming);
    await lane.run(() => {});
    expect(compact).not.toHaveBeenCalled();
    expect(slot.snapshot().compactionQueued).toBe(true);

    releaseSecond();
    await waitUntil(() => compact.mock.calls.length === 1);
    await expect(queuedCompaction).resolves.toEqual({ queued: true });
    await waitUntil(() => !slot.isBusy);
  });

  it("cancels pending compaction and drains its runtime during registry shutdown", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-queued-compaction-shutdown-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    let releaseResponse!: () => void;
    const responseBarrier = new Promise<void>((resolve) => { releaseResponse = resolve; });
    const faux = fauxProvider({ provider: "tron-queued-compaction-shutdown", tokensPerSecond: 10_000 });
    faux.setResponses([async () => {
      await responseBarrier;
      return fauxAssistantMessage("run complete");
    }]);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => {
        const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
        runtime.registerNativeProvider(faux.provider);
        return runtime;
      },
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const session = (slot as unknown as {
      runtime: { session: { compact: (instructions?: string) => Promise<unknown> } };
    }).runtime.session;
    const compact = vi.spyOn(session, "compact").mockResolvedValue({});

    await slot.prompt("start");
    await waitUntil(() => slot.isBusy);
    const queuedCompaction = slot.compact();
    const queuedOutcome = queuedCompaction.then(
      () => ({ status: "fulfilled" as const }),
      (error: unknown) => ({ status: "rejected" as const, error }),
    );
    await waitUntil(() => slot.snapshot().compactionQueued === true);
    const shutdown = registry.dispose();
    releaseResponse();

    const outcome = await queuedOutcome;
    expect(outcome).toMatchObject({ status: "rejected", error: { code: "cancelled" } });
    await shutdown;
    expect(compact).not.toHaveBeenCalled();
    expect(registry.activeSessionIds()).toEqual([]);
    const index = registries.indexOf(registry);
    if (index >= 0) registries.splice(index, 1);
  });

  it("aborts and drains an in-flight direct compaction during registry shutdown", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-direct-compaction-shutdown-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }),
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    let releaseCompaction!: () => void;
    const compactionBarrier = new Promise<void>((resolve) => { releaseCompaction = resolve; });
    const session = (slot as unknown as {
      runtime: { session: {
        compact: (instructions?: string) => Promise<unknown>;
        abortCompaction: () => void;
      } };
    }).runtime.session;
    vi.spyOn(session, "compact").mockImplementation(async () => {
      await compactionBarrier;
      return {};
    });
    const originalAbort = session.abortCompaction.bind(session);
    const abortCompaction = vi.spyOn(session, "abortCompaction").mockImplementation(() => {
      originalAbort();
      releaseCompaction();
    });

    const compaction = slot.compact();
    await waitUntil(() => slot.snapshot().phase === "compacting");
    const shutdown = registry.dispose();
    await expect(compaction).resolves.toEqual({ queued: false });
    await shutdown;
    expect(abortCompaction).toHaveBeenCalled();
    expect(registry.activeSessionIds()).toEqual([]);
    const index = registries.indexOf(registry);
    if (index >= 0) registries.splice(index, 1);
  });

  it("closes global slot admission before draining an already-entered creation", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-registry-admission-shutdown-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    let factoryEntered!: () => void;
    let releaseFactory!: () => void;
    const factoryWasEntered = new Promise<void>((resolve) => { factoryEntered = resolve; });
    const factoryBarrier = new Promise<void>((resolve) => { releaseFactory = resolve; });
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => {
        factoryEntered();
        await factoryBarrier;
        return ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      },
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();

    const creating = registry.create(cwd);
    await factoryWasEntered;
    let shutdownFinished = false;
    const shutdown = registry.dispose().then(() => { shutdownFinished = true; });
    await Promise.resolve();
    expect(shutdownFinished).toBe(false);
    await expect(registry.create(cwd)).rejects.toMatchObject({
      code: "conflict",
      message: "Session runtime registry is shutting down",
    });

    releaseFactory();
    const created = await creating;
    await shutdown;
    expect(shutdownFinished).toBe(true);
    expect(registry.activeSessionIds()).toEqual([]);
    expect((registry as unknown as { slots: Map<string, unknown> }).slots.size).toBe(0);
    await expect(registry.acquire(created.id)).rejects.toMatchObject({ code: "conflict" });
    const index = registries.indexOf(registry);
    if (index >= 0) registries.splice(index, 1);
  });

  it("preserves the admitted run marker when global shutdown forces interruption", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-forced-shutdown-marker-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const faux = fauxProvider({ provider: "tron-forced-marker", tokensPerSecond: 10_000 });
    faux.setResponses([
      async () => { await new Promise((resolve) => setTimeout(resolve, 250)); return fauxAssistantMessage("late"); },
    ]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime, trust: new TrustService(agentDir),
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("accepted work");
    await waitUntil(() => slot.catalogPhase === "running");
    const sessionID = slot.id;
    await slot.shutdown();
    const markerStore = (registry as unknown as { markers: { interruptedSessionIds(): Promise<Set<string>> } }).markers;
    expect((await markerStore.interruptedSessionIds()).has(sessionID)).toBe(true);
  });

  it("does not tear down blob ownership before every captured slot drains", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-registry-blob-drain-order-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }),
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);

    let shutdownEntered!: () => void;
    let releaseShutdown!: () => void;
    const shutdownWasEntered = new Promise<void>((resolve) => { shutdownEntered = resolve; });
    const shutdownBarrier = new Promise<void>((resolve) => { releaseShutdown = resolve; });
    const originalShutdown = slot.shutdown.bind(slot);
    let slotDrained = false;
    vi.spyOn(slot, "shutdown").mockImplementation(async () => {
      shutdownEntered();
      await shutdownBarrier;
      await originalShutdown();
      slotDrained = true;
    });
    const blobs = (registry as unknown as { blobs: { dispose: () => Promise<void> } }).blobs;
    const originalBlobDispose = blobs.dispose.bind(blobs);
    let blobDisposeStarted = false;
    vi.spyOn(blobs, "dispose").mockImplementation(async () => {
      blobDisposeStarted = true;
      expect(slotDrained).toBe(true);
      await originalBlobDispose();
    });

    const shutdown = registry.dispose();
    await shutdownWasEntered;
    expect(blobDisposeStarted).toBe(false);
    releaseShutdown();
    await shutdown;
    expect(slotDrained).toBe(true);
    expect(blobDisposeStarted).toBe(true);
    const index = registries.indexOf(registry);
    if (index >= 0) registries.splice(index, 1);
  });

  it("projects stable ordinals for parallel tools from start through completion", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-tool-order-integration-"));
    const agentDir = join(root, "agent");
    const sessionDir = join(root, "sessions");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(sessionDir), mkdir(cwd)]);
    await writeFile(join(agentDir, "settings.json"), JSON.stringify({ sessionDir }));

    const faux = fauxProvider({ provider: "tron-tool-order", tokensPerSecond: 10_000 });
    const createModels = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    faux.setResponses([
      fauxAssistantMessage([
        fauxToolCall("read", { path: join(cwd, "one.txt") }, { id: "call-read" }),
        fauxToolCall("bash", { command: "printf start; sleep 0.35; printf end" }, { id: "call-bash" }),
      ], { stopReason: "toolUse" }),
      fauxAssistantMessage("finished"),
    ]);
    await writeFile(join(cwd, "one.txt"), "one\n");
    const events: Array<{ topic: string; payload: any }> = [];
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: createModels,
      trust: new TrustService(agentDir),
      broadcast: (_sessionId, topic, payload) => events.push({ topic, payload }),
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("run tools");
    await waitUntil(() => !slot.isBusy);

    const progress = events
      .filter((event) => event.topic === "session.toolProgress")
      .map((event) => event.payload.data as {
        toolCallId: string;
        order: number;
        status: string;
        output?: string;
        progressSequence: number;
        durationMs?: number;
        completedAt?: string;
      });
    const firstRunning = new Map<string, number>();
    for (const event of progress) {
      if (event.status === "running" && !firstRunning.has(event.toolCallId)) firstRunning.set(event.toolCallId, event.order);
    }
    expect(firstRunning).toEqual(new Map([["call-read", 0], ["call-bash", 1]]));
    const finalOrder = new Map(progress.map((event) => [event.toolCallId, event.order]));
    expect(finalOrder).toEqual(new Map([["call-read", 0], ["call-bash", 1]]));
    const bashProgress = progress.filter((event) => event.toolCallId === "call-bash");
    expect(bashProgress.some((event) => event.status === "running" && event.output?.includes("start"))).toBe(true);
    expect(bashProgress.at(-1)).toMatchObject({ status: "completed", output: "startend" });
    expect(bashProgress.at(-1)!.progressSequence).toBeGreaterThan(2);
    expect(bashProgress.at(-1)!.durationMs).toBeGreaterThanOrEqual(300);
    expect(bashProgress.at(-1)!.completedAt).toBeTypeOf("string");
    const settled = slot.snapshot();
    expect(settled.toolExecutions).toEqual([]);
    expect(settled.transcript.find((item) => item.kind === "message" && item.role === "toolResult" && item.toolCallId === "call-bash"))
      .toMatchObject({ durationMs: expect.any(Number), startedAt: expect.any(String), completedAt: expect.any(String) });
    expect(slot.sessionFile?.startsWith(sessionDir)).toBe(true);
  });

  it("admits exact extension commands while streaming without hiding the foreground run", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-streaming-extension-command-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await Promise.all([mkdir(agentDir), mkdir(extensionDir, { recursive: true })]);
    await writeFile(join(extensionDir, "stream-command.ts"), `export default function (pi) {
      pi.registerCommand("during-stream", {
        description: "Wait for native confirmation",
        handler: async (_args, ctx) => {
          if (await ctx.ui.confirm("Streaming command", "Continue?")) ctx.ui.setStatus("stream-command", "accepted");
        },
      });
    }\n`);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const faux = fauxProvider({ provider: "tron-stream-command", tokensPerSecond: 1 });
    faux.setResponses([fauxAssistantMessage("streaming ".repeat(100))]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust,
      modelRuntimeFactory: async () => runtime,
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("start foreground streaming");
    await waitUntil(() => slot.catalogPhase === "running");

    const command = slot.prompt("/during-stream");
    await waitUntil(() => slot.snapshot().extensionPresentation.pendingInteractions.length === 1);
    const pending = slot.snapshot().extensionPresentation.pendingInteractions[0]!;
    const during = slot.snapshot();
    expect(during.phase).toBe("running");
    expect(during.operation?.kind).toBe("prompt");
    expect(during.extensionCommand?.kind).toBe("command");
    const marker = JSON.parse(await readFile(join(root, "tron", "gateway", "runtime-markers", `${slot.id}.json`), "utf8")) as { operationId: string };
    expect(marker.operationId).toBe(during.extensionCommand?.id);
    await expect(registry.waitUntilIdle(25)).rejects.toMatchObject({ code: "busy", retryable: true });
    slot.respondToInteraction(pending.id, pending.hostEpoch, pending.presentationRevision, true, false);
    await expect(command).resolves.toEqual({ operationId: expect.any(String) });
    await waitUntil(() => slot.snapshot().extensionCommand === undefined);
    expect(slot.snapshot().extensionPresentation.semanticState.statuses["stream-command"]).toBe("accepted");
    await slot.abort();
    await waitUntil(() => slot.catalogPhase === "idle");
  });

  it("scopes extension shutdown to the owning runtime slot", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-extension-scoped-shutdown-"));
    const agentDir = join(root, "agent");
    const closingCwd = join(root, "closing");
    const otherCwd = join(root, "other");
    const extensionDir = join(closingCwd, ".pi", "extensions");
    await Promise.all([mkdir(agentDir), mkdir(extensionDir, { recursive: true }), mkdir(otherCwd)]);
    await writeFile(join(extensionDir, "shutdown.ts"), `export default function (pi) {
      pi.on("session_shutdown", async (_event, ctx) => {
        await new Promise((resolve) => setTimeout(resolve, 50));
        ctx.ui.setStatus("shutdown", "complete");
      });
      pi.registerCommand("close-owning-session", { handler: async (_args, ctx) => ctx.shutdown() });
    }\n`);
    const trust = new TrustService(agentDir);
    await trust.set(closingCwd, true);
    const shutdownTopics: string[] = [];
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust,
      broadcast: (_sessionID, topic) => shutdownTopics.push(topic), sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const closing = await registry.create(closingCwd);
    const other = await registry.create(otherCwd);
    const closingID = closing.id;

    await closing.prompt("/close-owning-session");
    await waitUntil(() => !registry.activeSessionIds().includes(closingID));
    expect(() => other.context()).not.toThrow();
    await expect(registry.acquire(closingID)).rejects.toMatchObject({ code: "not_found" });
    const shutdownStatusIndex = shutdownTopics.lastIndexOf("session.extensionPresentation");
    const closedIndex = shutdownTopics.lastIndexOf("session.closed");
    expect(shutdownStatusIndex).toBeGreaterThanOrEqual(0);
    expect(closedIndex).toBeGreaterThan(shutdownStatusIndex);
  });

  it("isolates same-named providers registered by concurrent project extensions", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-provider-isolation-"));
    const agentDir = join(root, "agent");
    const firstCwd = join(root, "first");
    const secondCwd = join(root, "second");
    await Promise.all([
      mkdir(agentDir),
      mkdir(join(firstCwd, ".pi", "extensions"), { recursive: true }),
      mkdir(join(secondCwd, ".pi", "extensions"), { recursive: true }),
    ]);
    const extension = (name: string) => `export default function (pi) { pi.registerProvider("project-provider", { baseUrl: "https://provider.invalid", apiKey: "fixture", api: "openai-completions", models: [{ id: "model", name: ${JSON.stringify(name)}, reasoning: false, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 4096, maxTokens: 1024 }] }); }\n`;
    await Promise.all([
      writeFile(join(firstCwd, ".pi", "extensions", "provider.ts"), extension("First Project Model")),
      writeFile(join(secondCwd, ".pi", "extensions", "provider.ts"), extension("Second Project Model")),
    ]);
    const trust = new TrustService(agentDir);
    await Promise.all([trust.set(firstCwd, true), trust.set(secondCwd, true)]);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      trust,
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();

    const [first, second] = await Promise.all([registry.create(firstCwd), registry.create(secondCwd)]);
    expect(first.modelRuntime).not.toBe(second.modelRuntime);
    expect(first.modelRuntime.getModel("project-provider", "model")?.name).toBe("First Project Model");
    expect(second.modelRuntime.getModel("project-provider", "model")?.name).toBe("Second Project Model");
  });

  it("projects the canonical latest cache hit rate used by the terminal footer", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-cache-rate-integration-"));
    const agentDir = join(root, "agent");
    const sessionDir = join(root, "sessions");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(sessionDir), mkdir(cwd)]);
    await writeFile(join(agentDir, "settings.json"), JSON.stringify({ sessionDir }));
    const faux = fauxProvider({ provider: "tron-cache-rate", tokensPerSecond: 10_000 });
    const createModels = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    faux.setResponses([fauxAssistantMessage("cached")]);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: createModels,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    expect(slot.sessionFile?.startsWith(sessionDir)).toBe(true);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("cache stats");
    await waitUntil(() => !slot.isBusy);

    const snapshot = slot.snapshot();
    const assistant = snapshot.transcript.find((item) => item.role === "assistant");
    const usage = (assistant as any)?.usage as { input?: number; cacheRead?: number; cacheWrite?: number } | undefined;
    const promptTokens = (usage?.input ?? 0) + (usage?.cacheRead ?? 0) + (usage?.cacheWrite ?? 0);
    const expected = promptTokens > 0 ? ((usage?.cacheRead ?? 0) / promptTokens) * 100 : undefined;
    expect(snapshot.stats.latestCacheHitRate).toBe(expected);
  });

  it("projects readable metadata for project resources", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-resources-integration-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const pi = join(cwd, ".pi");
    await Promise.all([
      mkdir(agentDir),
      mkdir(join(pi, "extensions"), { recursive: true }),
      mkdir(join(pi, "prompts"), { recursive: true }),
      mkdir(join(pi, "skills", "review"), { recursive: true }),
    ]);
    const cwdAlias = join(root, "workspace-alias");
    await symlink(cwd, cwdAlias);
    await Promise.all([
      writeFile(join(pi, "extensions", "tool.ts"), `export default function (pi) { pi.registerTool({ name: "project_echo", label: "Project echo", description: "Echo project text", parameters: { type: "object", properties: { text: { type: "string" } }, required: ["text"] }, execute: async (_id, params) => ({ content: [{ type: "text", text: params.text }], details: {} }) }); }\n`),
      writeFile(join(pi, "prompts", "review.md"), `---\ndescription: Review the current change\n---\nReview $ARGUMENTS\n`),
      writeFile(join(pi, "skills", "review", "SKILL.md"), `---\nname: review-skill\ndescription: Inspect a code change\n---\nReview carefully.\n`),
    ]);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const resourceEvents: string[] = [];
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      trust,
      broadcast: (_sessionId, topic) => { resourceEvents.push(topic); },
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();

    const slot = await registry.create(cwd);
    const resources = slot.resources() as any;
    expect(resources.extensions).toEqual(expect.arrayContaining([
      expect.objectContaining({ name: "tool.ts", scope: "project", tools: ["project_echo"] }),
    ]));
    expect(resources.prompts.prompts).toEqual(expect.arrayContaining([
      expect.objectContaining({ name: "review", description: "Review the current change", scope: "project" }),
    ]));
    expect(resources.skills.skills).toEqual(expect.arrayContaining([
      expect.objectContaining({ name: "review-skill", description: "Inspect a code change", scope: "project" }),
    ]));
    expect(resources.tools).toEqual(expect.arrayContaining([
      expect.objectContaining({ name: "project_echo", description: "Echo project text", scope: "project" }),
    ]));

    resourceEvents.length = 0;
    await registry.reloadProject(cwd, false, false);
    expect(() => slot.resources()).toThrow("Project trust is being reconfigured");
    expect(() => slot.modelRuntime).toThrow("Project trust is being reconfigured");
    expect(() => slot.sessionEnvironment()).toThrow("Project trust is being reconfigured");
    expect(() => slot.respondToInteraction("pending", "host", 0, null, true)).toThrow("Project trust is being reconfigured");
    await expect(registry.create(cwd)).rejects.toMatchObject({ code: "busy", retryable: true });
    await expect(registry.create(cwdAlias)).rejects.toMatchObject({ code: "busy", retryable: true });
    await expect(trust.inspect(cwd)).resolves.toMatchObject({ savedDecision: true });
    expect(resourceEvents).not.toContain("session.resourcesChanged");
    await trust.set(cwd, false);
    await registry.commitProjectReload(cwd);
    const untrusted = slot.resources() as any;
    expect(untrusted.tools).not.toEqual(expect.arrayContaining([
      expect.objectContaining({ name: "project_echo" }),
    ]));
    expect(resourceEvents).toContain("session.resourcesChanged");
  });

  it("owns its catalog, infers nested subagents, and keeps ordinary forks user-visible", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-session-catalog-"));
    const agentDir = join(root, "agent");
    const tronHome = join(root, "tron");
    const cwd = join(root, "workspace");
    const externalDir = join(root, "external-sessions");
    await Promise.all([mkdir(agentDir), mkdir(tronHome), mkdir(cwd), mkdir(externalDir)]);

    const timestamp = new Date().toISOString();
    const writeSession = async (directory: string, id: string, message: string, parentSession?: string) => {
      const path = join(directory, `${id}.jsonl`);
      await writeFile(path, [
        JSON.stringify({ type: "session", version: 3, id, timestamp, cwd, ...(parentSession ? { parentSession } : {}) }),
        JSON.stringify({ type: "message", id: randomUUID().slice(0, 8), parentId: null, timestamp, message: { role: "user", content: message, timestamp: Date.now() } }),
      ].join("\n") + "\n");
      return path;
    };
    const externalId = randomUUID();
    await writeSession(externalDir, externalId, "external process");

    const piSessionDirectory = join(agentDir, "sessions", "--workspace--");
    await mkdir(piSessionDirectory, { recursive: true });
    const parentId = randomUUID();
    const parentFile = await writeSession(piSessionDirectory, parentId, "parent");

    const nestedDirectory = join(parentFile.replace(/\.jsonl$/, ""), "child", "run-0");
    await mkdir(nestedDirectory, { recursive: true });
    const nestedId = randomUUID();
    await writeSession(nestedDirectory, nestedId, "nested fresh child");

    const fork = SessionManager.forkFrom(parentFile, cwd, piSessionDirectory);
    fork.appendSessionInfo("ordinary fork");
    const directSubagent = SessionManager.forkFrom(parentFile, cwd, piSessionDirectory);
    directSubagent.appendSessionInfo("subagent-worker-fixture-1");

    const registry = new RuntimeRegistry({
      agentDir,
      tronHome,
      idleRuntimeMs: 60_000,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const defaultCatalog = await registry.list();
    const completeCatalog = await registry.list("all");
    expect(defaultCatalog.map((session) => session.id)).toEqual(expect.arrayContaining([parentId, fork.getSessionId()]));
    expect(defaultCatalog.map((session) => session.id)).not.toContain(nestedId);
    expect(defaultCatalog.map((session) => session.id)).not.toContain(directSubagent.getSessionId());
    expect(defaultCatalog.map((session) => session.id)).not.toContain(externalId);
    expect(completeCatalog.map((session) => session.id)).not.toContain(externalId);
    expect(completeCatalog.find((session) => session.id === parentId)).toMatchObject({ kind: "user" });
    expect(completeCatalog.find((session) => session.id === fork.getSessionId())).toMatchObject({ kind: "user", parentSessionId: parentId });
    expect(completeCatalog.find((session) => session.id === directSubagent.getSessionId())).toMatchObject({
      kind: "subagent",
      parentSessionId: parentId,
    });
    expect(completeCatalog.find((session) => session.id === nestedId)).toMatchObject({
      kind: "subagent",
      parentSessionId: parentId,
    });
    await expect(registry.acquire(nestedId)).rejects.toMatchObject({ code: "conflict" });
    await expect(registry.delete(nestedId)).rejects.toMatchObject({ code: "conflict" });

    await registry.delete(parentId);
    expect((await registry.list("all")).find((session) => session.id === nestedId)).toMatchObject({ kind: "subagent" });
  });

  it("rekeys the owning slot when a completed session is forked", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-runtime-fork-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    process.env.PI_CODING_AGENT_DIR = agentDir;

    const faux = fauxProvider({ provider: "tron-fork", tokensPerSecond: 10_000 });
    const createModels = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    faux.setResponses([fauxAssistantMessage("done")]);
    const rekeys: Array<[string, string]> = [];
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: createModels,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
      sessionRekeyed: (previousId, nextId) => rekeys.push([previousId, nextId]),
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("fork this");
    await waitUntil(() => !slot.isBusy);
    const original = slot.id;
    const userEntry = slot.snapshot().transcript.find((item) => item.role === "user");
    expect(userEntry).toBeDefined();

    const fork = await slot.fork(userEntry!.id, "at");
    expect(fork.sessionId).not.toBe(original);
    expect(rekeys).toEqual([[original, fork.sessionId]]);
    expect((await registry.acquire(fork.sessionId)).id).toBe(fork.sessionId);
  });

  it("rejects imports when live runtime capacity is full", async () => {
    const { root, cwd, registry } = await coldFixture("import-capacity", { maximumLiveRuntimes: 1 });
    await registry.create(cwd);

    await expect(registry.importFromJsonl(join(root, "import.jsonl"), cwd)).rejects.toMatchObject({
      code: "busy",
      retryable: true,
    });
  });

  it("cancels an idle eviction when a selected slot is acquired or subscribed before disposal", async () => {
    const { manager, registry } = await coldFixture("idle-eviction-acquire-subscribe");
    const sessionId = manager.getSessionId();
    const slot = await registry.acquire(sessionId);
    vi.spyOn(slot, "touchedAt", "get").mockReturnValue(0);

    let releaseLane!: () => void;
    let laneEntered!: () => void;
    const laneHeld = new Promise<void>((resolve) => { releaseLane = resolve; });
    const laneEnteredPromise = new Promise<void>((resolve) => { laneEntered = resolve; });
    const lane = (slot as unknown as { lane: { run: (operation: () => Promise<void>) => Promise<void> } }).lane;
    const blockedLane = lane.run(async () => {
      laneEntered();
      await laneHeld;
    });
    await laneEnteredPromise;

    const eviction = (registry as unknown as { evictIdle: () => Promise<void> }).evictIdle();
    await waitUntil(() => (registry as unknown as { idleEvictions: Map<string, { slot: unknown }> }).idleEvictions.get(sessionId)?.slot === slot);

    const [acquired] = await Promise.all([
      registry.acquire(sessionId),
      Promise.resolve().then(() => registry.subscribe("race-client", sessionId)),
    ]);
    releaseLane();
    await Promise.all([blockedLane, eviction]);

    expect(acquired).toBe(slot);
    expect(await registry.acquire(sessionId)).toBe(slot);
    expect(registry.isSubscribed("race-client", sessionId)).toBe(true);
  });
});
