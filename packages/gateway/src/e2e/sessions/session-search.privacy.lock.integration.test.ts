import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ModelRuntime, type SessionManager } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider } from "@earendil-works/pi-ai";
import { expect, it, vi } from "vitest";
import { createTestRegistry } from "../../../test-support/gateway-registry.js";
import { waitFor } from "../../../test-support/wait-for.js";
import { TrustService } from "../../kernel/resources/trust-service.js";
import { SessionSearchIndex } from "../../sessions/session-search-index.js";
import { SessionSearchService } from "../../sessions/session-search-service.js";

// This adds cancellation/reopen coverage; the manifest also selects the existing
// real Home-tool edit, credential, chapter-exclusion and exact-citation journeys.
it("cancels only the query wait and reopens the index from the current canonical source", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-search-retirement-"));
  vi.stubEnv("HOME", root);
  vi.stubEnv("TMPDIR", root);
  vi.stubEnv("PI_CODING_AGENT_DIR", join(root, "agent"));
  vi.stubEnv("PI_OFFLINE", "1");
  let registry: Awaited<ReturnType<typeof createTestRegistry>> | undefined;
  let search: SessionSearchService | undefined;
  let release = () => {};
  let pending: Promise<unknown> | undefined;
  try {
    const agentDir = join(root, "agent");
    const project = join(root, "project");
    await mkdir(agentDir, { recursive: true });
    await mkdir(project);
    const faux = fauxProvider({ provider: "search-retirement" });
    const model = faux.getModel();
    await writeFile(join(agentDir, "settings.json"), JSON.stringify({ defaultProvider: model.provider, defaultModel: model.id }));
    const runtime = await ModelRuntime.create({ authPath: join(agentDir, "auth.json"), modelsPath: null, refreshOnCreate: false, allowModelNetwork: false });
    runtime.registerNativeProvider(faux.provider);
    const trust = new TrustService(agentDir);
    await trust.set(project, true);
    registry = await createTestRegistry({ agentDir, trust, tronHome: join(root, "tron"),
      modelRuntimeFactory: async () => runtime, broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {} });
    await registry.initialize();
    const slot = await registry.create(project);
    await slot.setModel(model.provider, model.id);
    faux.setResponses([fauxAssistantMessage("RETIREMENT-NEEDLE LEXICAL-SURVIVES original source")]);
    await slot.prompt("save a historical decision");
    await waitFor(() => slot.snapshot().phase === "idle" || undefined, "source settled");
    const source = await registry.readSearchCut(slot.id);
    const anchor = source.entries.find(entry => entry.type === "message" && entry.message.role === "assistant");
    if (!anchor) throw new Error("fixture has no canonical answer");
    const path = join(root, "search.sqlite");
    search = new SessionSearchService(registry, await SessionSearchIndex.open(path));
    await search.warm();
    let started = false;
    const barrier = new Promise<void>(resolve => { release = resolve; });
    const metadata = { dimension: 2, language: "en", modelRevision: "lock-provider" };
    search.setSemanticClient({
      qualify: async () => metadata,
      // Faux provider I/O deliberately ignores cancellation: the disposable
      // caller must return without cancelling the shared SQLite/index owner.
      embed: async text => {
        if (text === "RETIREMENT-NEEDLE") { started = true; await barrier; }
        return { ...metadata, vector: [1, 0] };
      },
    });
    await waitFor(async () => (await search!.search({ query: "warmup" })).semantic.state === "ready" || undefined, "index ready");
    const controller = new AbortController();
    pending = search.search({ query: "RETIREMENT-NEEDLE" }, controller.signal)
      .then(() => ({ state: "published" }), error => ({ state: "refused", code: error.code }));
    await waitFor(() => started || undefined, "query awaiting provider");
    controller.abort();
    const independent = await search.search({ query: "LEXICAL-SURVIVES" });
    expect(independent.results.map(hit => hit.entryId)).toContain(anchor.id);
    // An independently completed query is the barrier, not a timer or a
    // provider call-count assertion. The cancelled caller must already be done.
    const cancelled = await Promise.race([pending, Promise.resolve({ state: "still-waiting" })]);
    expect(cancelled).toEqual({ state: "refused", code: "cancelled" });
    release();
    await pending;
    // Edit through the single live SDK owner, not a second session/client.
    const manager = (slot as unknown as { sessionManager: SessionManager }).sessionManager;
    manager.appendContextEdit(anchor.id, { content: [{ type: "text", text: "CURRENT-REOPEN-DECISION" }] });
    await search.close();
    search = undefined;
    search = new SessionSearchService(registry, await SessionSearchIndex.open(path));
    const old = await search.search({ query: "RETIREMENT-NEEDLE" });
    const current = await search.search({ query: "CURRENT-REOPEN-DECISION" });
    expect(old.results).toEqual([]);
    expect(current.results.map(hit => hit.entryId)).toContain(anchor.id);
    const admitted = await registry.readSearchCut(current.results[0]!.sessionId);
    expect(admitted.entries.some(entry => entry.id === current.results[0]!.entryId)).toBe(true);
    const artifact = join(process.cwd(), "test-results", "session-search-retirement");
    await mkdir(artifact, { recursive: true });
    await writeFile(join(artifact, "trace.json"), JSON.stringify({ cancelled,
      independent: independent.results.map(hit => hit.snippet), old: old.results,
      current: current.results.map(hit => hit.snippet), citationAdmitted: admitted.entries.some(entry => entry.id === current.results[0]!.entryId),
    }, null, 2) + "\n");
  } finally {
    release();
    await pending;
    try { await search?.close(); } finally {
      try { await registry?.dispose(); } finally { vi.unstubAllEnvs(); await rm(root, { recursive: true, force: true }); }
    }
  }
}, 60_000);

// Transcript text reaches only a helper the Gateway composition admitted
// (gateway-main.ts: development override or the signed bundled helper). The
// variable alone, outside that admission, never arms semantic indexing.
it("never arms an embedding helper the Gateway composition did not admit", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-search-helper-owner-"));
  const helper = join(root, "unadmitted-helper");
  await writeFile(helper, `#!/bin/sh\necho ran >> "${join(root, "helper-ran")}"\nexit 1\n`, { mode: 0o755 });
  vi.stubEnv("HOME", root);
  vi.stubEnv("TMPDIR", root);
  vi.stubEnv("PI_CODING_AGENT_DIR", join(root, "agent"));
  vi.stubEnv("PI_OFFLINE", "1");
  vi.stubEnv("TRON_SEARCH_EMBEDDING_HELPER", helper);
  let registry: Awaited<ReturnType<typeof createTestRegistry>> | undefined;
  let search: SessionSearchService | undefined;
  try {
    const agentDir = join(root, "agent");
    await mkdir(agentDir, { recursive: true });
    registry = await createTestRegistry({ agentDir, trust: new TrustService(agentDir), tronHome: join(root, "tron"),
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {} });
    await registry.initialize();
    // Startup warms search after the first catalog cut; an unknown id joins that cut.
    expect(await registry.sessionFile("no-such-session")).toBeUndefined();
    search = new SessionSearchService(registry, await SessionSearchIndex.open(join(root, "search.sqlite")));
    await search.warm();
    const { semantic } = await search.search({ query: "anything" });
    expect(semantic).toEqual({ state: "unavailable", vectorsIndexed: 0, vectorsTotal: 0,
      reason: "The signed NaturalLanguage helper is unavailable or not qualified" });
  } finally {
    try { await search?.close(); } finally {
      try { await registry?.dispose(); } finally { vi.unstubAllEnvs(); await rm(root, { recursive: true, force: true }); }
    }
  }
}, 60_000);
