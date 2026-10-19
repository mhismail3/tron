/**
 * Tron Home's curated read-only research tools (#724), end to end: `web_search`,
 * `web_fetch`, `session_search`, `session_read`, `knowledge` and `read_file` registered by the
 * real `tron-home-research` module, called by a faux model inside real
 * activations on a designated Home, with the request seam live and counted.
 *
 * Failure modes these cases exist for, written before the code they test:
 *  F1 a research tool call refuses its activation at the request seam
 *     (`context-mutated`, `projection-mismatch`, a nonce or digest failure);
 *  F2 an unbounded tool result enters the transcript (the memory projection's
 *     30,000-character cap must hold at the tool, not only at projection);
 *  F3 `read_file` escapes trust: a default-trusted or untrusted path, or a
 *     symlink inside a trusted project resolving outside it;
 *  F4 a Knowledge write action is reachable from Home;
 *  F5 `web_fetch` reaches a private destination (SSRF) or follows a redirect to
 *     one;
 *  F6 ordinary sessions gain research tools or the Home-only module;
 *  F7 a varying tool list or system prompt between activations (the cached
 *     prefix head must stay byte-identical).
 *
 * The retained artifact is `test-results/home-research-tools/report.json`.
 */
import { createHash } from "node:crypto";
import { DatabaseSync } from "node:sqlite";
import { mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { setHomeMemoryModels } from "../../test-support/settings-dependencies.js";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ModelRuntime, type SessionManager } from "@earendil-works/pi-coding-agent";
import {
  fauxAssistantMessage, fauxProvider, fauxToolCall,
  type FauxProviderHandle, type ToolCall, type Message,
} from "@earendil-works/pi-ai";
import { afterAll, afterEach, describe, expect, it } from "vitest";
import { waitFor } from "../../test-support/wait-for.js";
import { TrustService } from "../admin/trust-service.js";
import type { HomeRequestRecord } from "../home/home-request-policy.js";
import type { HomeResearchToolDetails } from "../home/home-research-tools.js";
import { legacyEntriesDigest, seedLegacyChronicle } from "../../test-support/legacy-chronicle.js";
import { KnowledgeService } from "../knowledge/knowledge-service.js";
import { KnowledgeStore } from "../knowledge/knowledge-store.js";
import { RuntimeRegistry } from "./runtime-registry.js";
import { SessionSearchIndex } from "./session-search-index.js";
import { SessionSearchService } from "./session-search-service.js";

const PROVIDER = "tron-home-research";
const MODEL_ID = "chat";
const MEMORY_PROVIDER = "tron-home-research-memory";
const MEMORY_MODEL = { provider: MEMORY_PROVIDER, id: "compactor" };
const MODEL = { provider: PROVIDER, id: MODEL_ID };
const REPORT_PATH = "test-results/home-research-tools/report.json";
/** A resolvable public address for the injected DNS seam. */
const PUBLIC_ADDRESS = "93.184.216.34";

const report: { generatedAt: string; cases: Array<Record<string, unknown>> } = {
  generatedAt: new Date().toISOString(),
  cases: [],
};

const roots: string[] = [];
const registries: RuntimeRegistry[] = [];
const indexes: SessionSearchIndex[] = [];

afterEach(async () => {
  await Promise.all(registries.splice(0).map((registry) => registry.dispose().catch(() => {})));
  for (const index of indexes.splice(0)) index.close();
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

afterAll(async () => {
  await mkdir(join(process.cwd(), "test-results", "home-research-tools"), { recursive: true });
  await writeFile(join(process.cwd(), REPORT_PATH), `${JSON.stringify(report, null, 2)}\n`);
  process.stdout.write(`home-research-tools: ${report.cases.length} cases -> ${REPORT_PATH}\n`);
});

function recordCase(name: string, data: Record<string, unknown>): void {
  report.cases.push({ name, ...data });
}

// ---- the injected web transport -------------------------------------------------

/** DuckDuckGo-shaped results markup, the structural parts the parser reads. */
const SEARCH_HTML = `<html><body>
<div class="result"><h2><a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.org%2Falpha&amp;rut=abc">Alpha &amp; result</a></h2>
<a class="result__snippet" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.org%2Falpha">First <b>snippet</b> text</a></div>
<div class="result"><h2><a rel="nofollow" class="result__a" href="https://example.org/beta">Beta result</a></h2>
<a class="result__snippet" href="https://example.org/beta">Second snippet</a></div>
</body></html>`;

const ARTICLE_BODY = "This is the research article body, written as a real paragraph with enough substance that readable-text extraction keeps it whole. ".repeat(4);
const PAGE_HTML = `<html><head><title>Research Fixture Page</title></head><body><article><h1>Research Fixture Page</h1><p>${ARTICLE_BODY}</p></article></body></html>`;
const HUGE_HTML = `<html><head><title>Huge</title></head><body><article><p>${"huge page text that keeps repeating so the result must be capped. ".repeat(3_000)}</p></article></body></html>`;

function htmlResponse(html: string): Response {
  return new Response(html, { status: 200, headers: { "content-type": "text/html; charset=utf-8" } });
}

/** One deterministic transport: no sockets, no real DNS. It records each fetched
 * URL so SSRF cases can prove the transport was never reached. */
function webTransport() {
  const fetchedUrls: string[] = [];
  return {
    fetchedUrls,
    transport: {
      fetcher: async (input: string | URL): Promise<Response> => {
        const url = new URL(String(input));
        fetchedUrls.push(url.href);
        if (url.hostname === "html.duckduckgo.com") return htmlResponse(SEARCH_HTML);
        if (url.pathname === "/huge") return htmlResponse(HUGE_HTML);
        if (url.pathname === "/redirect-private") return new Response(null, { status: 302, headers: { location: "http://127.0.0.1/secret" } });
        return htmlResponse(PAGE_HTML);
      },
      resolveHost: async (hostname: string): Promise<string[]> =>
        hostname === "private.internal" ? ["10.0.0.5"] : [PUBLIC_ADDRESS],
    },
  };
}

// ---- the fixture ----------------------------------------------------------------

type HomeSlot = Awaited<ReturnType<RuntimeRegistry["acquire"]>>;

interface Fixture {
  root: string;
  agentDir: string;
  tronHome: string;
  project: string;
  faux: FauxProviderHandle;
  runtime: ModelRuntime;
  trust: TrustService;
  registry: RuntimeRegistry;
  requestRecords: HomeRequestRecord[];
  requests: CapturedRequest[];
  fetchedUrls: string[];
  knowledge: KnowledgeService;
  store: KnowledgeStore;
  search: SessionSearchService;
  sessionId: string;
  slot: HomeSlot;
}

async function fixture(
  label: string,
  seedCanonical?: (agentDir: string, project: string) => Promise<void>,
  seedIndex?: (registry: RuntimeRegistry, path: string) => Promise<void>,
): Promise<Fixture> {
  const root = await mkdtemp(join(tmpdir(), `tron-home-research-${label}-`));
  roots.push(root);
  const agentDir = join(root, "agent");
  const tronHome = join(root, "tron");
  const project = join(root, "project");
  await Promise.all([mkdir(agentDir, { recursive: true }), mkdir(project, { recursive: true })]);
  await writeFile(join(agentDir, "settings.json"), JSON.stringify({ defaultProvider: PROVIDER, defaultModel: MODEL_ID }));
  await seedCanonical?.(agentDir, project);
  const faux = fauxProvider({ provider: PROVIDER, models: [{ id: MODEL_ID }], tokensPerSecond: 1_000_000, tokenSize: { min: 10, max: 10 } });
  const memoryFaux = fauxProvider({ provider: MEMORY_PROVIDER, models: [{ id: MEMORY_MODEL.id, reasoning: false }] });
  const runtime = await ModelRuntime.create({ authPath: join(root, "auth.json"), modelsPath: null, refreshOnCreate: false });
  runtime.registerNativeProvider(faux.provider);
  runtime.registerNativeProvider(memoryFaux.provider);
  const trust = new TrustService(agentDir);
  await trust.set(project, true);
  const requestRecords: HomeRequestRecord[] = [];
  const web = webTransport();
  const registry = new RuntimeRegistry({
    agentDir,
    tronHome,
    idleRuntimeMs: 60_000,
    modelRuntimeFactory: async () => runtime,
    trust,
    broadcast: () => {},
    sessionSummaryChanged: () => {},
    sessionListChanged: () => {},
    homeMemorySummarizer: () => async () => fauxAssistantMessage("HOME-RESEARCH-LINE"),
    homeRequestDiagnostic: (record) => requestRecords.push(record),
    homeWebTransport: web.transport,
  });
  registries.push(registry);
  await registry.initialize();
  const hasCut = (): boolean => (registry as unknown as { sessionCatalog: { hasCompleteCut(): boolean } }).sessionCatalog.hasCompleteCut();
  await waitFor(() => hasCut() || undefined, "catalog cut", { boundMs: 30_000 });
  await registry.catalog("all");

  // Real owners, installed the way gateway-main installs them.
  const store = new KnowledgeStore(registry.knowledgeWorkspace(), () => {});
  const knowledge = new KnowledgeService(store);
  registry.setKnowledgeService(knowledge);
  const indexPath = join(tronHome, "gateway", "session-search.sqlite");
  await seedIndex?.(registry, indexPath);
  const index = await SessionSearchIndex.open(indexPath);
  indexes.push(index);
  const search = new SessionSearchService(registry, index);
  registry.setSessionSearchService(search);

  const designation = await registry.homeOwner().designate({ model: MODEL }, () => MODEL);
  await setHomeMemoryModels(registry, [MEMORY_MODEL]);
  const slot = await registry.acquire(designation.sessionId);
  return {
    root, agentDir, tronHome, project, faux, runtime, trust, registry,
    requestRecords, requests: [], fetchedUrls: web.fetchedUrls, knowledge, store, search,
    sessionId: designation.sessionId, slot,
  };
}

// ---- driving activations --------------------------------------------------------

interface CapturedRequest { blob: string }

interface ToolObservation {
  toolName: string;
  text: string;
  details: HomeResearchToolDetails | undefined;
  isError: boolean;
}

function toolResultsOf(request: CapturedRequest): ToolObservation[] {
  return (JSON.parse(request.blob) as Array<Record<string, unknown>>)
    .filter((message) => message.role === "toolResult")
    .map((message) => ({
      toolName: String(message.toolName),
      text: (Array.isArray(message.content) ? message.content : []).map((part) => String((part as { text?: unknown }).text ?? "")).join(""),
      details: message.details as HomeResearchToolDetails | undefined,
      isError: message.isError === true,
    }));
}

interface Step { name: string; args: ToolCall["arguments"] }

/** Run one activation: one model step per tool call, then a closing reply, and
 * return the tool results the closing request carried. */
async function toolAnswers(f: Fixture, input: string, steps: Step[]): Promise<ToolObservation[]> {
  f.faux.setResponses([
    ...steps.map((step) => async (context: { messages: Array<{ role: string }> }) => {
      f.requests.push({ blob: JSON.stringify(context.messages, (key, value) => key === "timestamp" ? 0 : value) });
      return fauxAssistantMessage(fauxToolCall(step.name, step.args));
    }),
    async (context: { messages: Array<{ role: string }> }) => {
      f.requests.push({ blob: JSON.stringify(context.messages, (key, value) => key === "timestamp" ? 0 : value) });
      return fauxAssistantMessage("research reply");
    },
  ]);
  const before = f.requests.length;
  await f.slot.prompt(input);
  await waitFor(() => f.requests.length >= before + steps.length + 1 || undefined, "activation requests", { boundMs: 30_000 });
  await waitFor(() => (f.slot.snapshot().configurationBlocker === null) || undefined, "activation settled", { boundMs: 30_000 });
  const closing = f.requests.at(-1)!;
  const answers = toolResultsOf(closing);
  expect(answers.length, "each scripted tool call must have executed").toBe(steps.length);
  return answers;
}

function refusals(f: Fixture): HomeRequestRecord[] {
  return f.requestRecords.filter((record) => record.event === "refused");
}

// ---- the cases ------------------------------------------------------------------

describe("Tron Home research tools", () => {
  it("runs web, search, Knowledge and trusted-file tools inside Home activations with zero seam refusals", async () => {
    const f = await fixture("all-tools");

    // Seed Knowledge with a note the read-only tool must find (the write goes
    // through the service directly, exactly as an ordinary session's tool would).
    await f.knowledge.tool({ action: "createNote", commandId: "seed-note-0001", title: "Research fixture note", noteBody: "the research fixture body", scope: "research" });

    // Seed another chat for session search, then release its runtime.
    const ordinary = await f.registry.create(f.project);
    await ordinary.setModel(PROVIDER, MODEL_ID);
    f.faux.setResponses([fauxAssistantMessage("ordinary reply about RESEARCH-NEEDLE-ALPHA")]);
    await ordinary.prompt("please remember RESEARCH-NEEDLE-ALPHA");
    await waitFor(() => (ordinary.snapshot().configurationBlocker === null) || undefined, "ordinary settled", { boundMs: 30_000 });

    // A trusted-project file for read_file.
    const filePath = join(f.project, "notes.txt");
    await writeFile(filePath, Array.from({ length: 12 }, (_, i) => `line ${i + 1} of the trusted file`).join("\n"));

    // F1: every tool, one activation each; the seam must never refuse.
    const [search] = await toolAnswers(f, "search the web", [{ name: "web_search", args: { query: "alpha beta", maxResults: 2 } }]);
    expect(search!.isError).toBe(false);
    expect(search!.details).toEqual({ status: "ok" });
    expect(search!.text).toContain("Untrusted web content");
    expect(search!.text).toContain("Alpha & result");
    expect(search!.text).toContain("https://example.org/alpha");
    expect(search!.text).toContain("Second snippet");

    const [fetch] = await toolAnswers(f, "fetch the page", [{ name: "web_fetch", args: { url: "https://example.org/page" } }]);
    expect(fetch!.details).toEqual({ status: "ok" });
    expect(fetch!.text).toContain("Title: Research Fixture Page");
    expect(fetch!.text).toContain("the research article body");

    const [sessions] = await toolAnswers(f, "find that chat", [{ name: "session_search", args: { query: "RESEARCH-NEEDLE-ALPHA" } }]);
    expect(sessions!.details).toMatchObject({
      status: "ok", query: "RESEARCH-NEEDLE-ALPHA",
      coverage: expect.any(String), ranking: expect.any(String),
      hits: expect.arrayContaining([expect.objectContaining({
        sessionId: ordinary.id, entryId: expect.any(String),
        role: "assistant", title: expect.any(String), updatedAt: expect.any(String),
        snippet: expect.stringContaining("RESEARCH-NEEDLE-ALPHA"),
      })]),
    });
    // This is the real Home tool-result in the canonical session, not a UI
    // fixture or a separately invented display model.
    const persistedSearch = (await readFile(f.slot.persistedSessionFile!, "utf8")).trim().split("\n")
      .map(line => JSON.parse(line))
      .findLast(entry => entry.type === "message" && entry.message.role === "toolResult" && entry.message.toolName === "session_search");
    expect(persistedSearch?.message.details).toEqual(sessions!.details);
    expect(sessions!.text).toContain("RESEARCH-NEEDLE-ALPHA");
    expect(sessions!.text).toContain("untrusted content");

    const [knowledge] = await toolAnswers(f, "what do we know", [{ name: "knowledge", args: { action: "search", query: "fixture" } }]);
    expect(knowledge!.details).toEqual({ status: "ok" });
    expect(knowledge!.text).toContain("Research fixture note");

    const [file] = await toolAnswers(f, "read the notes", [{ name: "read_file", args: { path: filePath, offset: 2, limit: 3 } }]);
    expect(file!.details).toEqual({ status: "ok" });
    expect(file!.text).toContain("lines 2-4 of 12");
    expect(file!.text).toContain("line 2 of the trusted file");
    expect(file!.text).not.toContain("line 5 of the trusted file");

    expect(refusals(f), "no activation may be refused by the request seam").toEqual([]);
    const activations = f.requestRecords.filter((record) => record.event === "activation");
    expect(activations.length).toBeGreaterThanOrEqual(5);

    // F7: the cached prefix head is byte-identical across activations.
    const systemOf = (request: CapturedRequest): string =>
      JSON.stringify((JSON.parse(request.blob) as Array<{ role: string }>).filter((message) => message.role === "system"));
    const heads = new Set(f.requests.map(systemOf));
    expect(heads.size, "one constant system head across every request").toBe(1);

    recordCase("all-tools", {
      refusals: refusals(f).length,
      activations: activations.length,
      tools: [search, fetch, sessions, knowledge, file].map(answer => answer!.toolName),
    });
  }, 120_000);

  it("keeps every result under the projection cap, refuses SSRF and trust escapes, and cannot reach Knowledge writes", async () => {
    const f = await fixture("bounds");

    // F2: a huge page is capped at the tool, inside the 30,000-character
    // projection bound (plus the truncation marker).
    const [huge] = await toolAnswers(f, "fetch the huge page", [{ name: "web_fetch", args: { url: "https://example.org/huge" } }]);
    expect(huge!.details).toEqual({ status: "ok" });
    expect(huge!.text.length).toBeLessThanOrEqual(31_000);
    expect(huge!.text).toContain("[truncated");

    // F5: private destinations are refused before any transport use.
    const fetchedBefore = f.fetchedUrls.length;
    const [local, privateHost, redirected] = await toolAnswers(f, "try unsafe fetches", [
      { name: "web_fetch", args: { url: "http://127.0.0.1/secret" } },
      { name: "web_fetch", args: { url: "https://private.internal/data" } },
      { name: "web_fetch", args: { url: "https://example.org/redirect-private" } },
    ]);
    expect(local!.details).toMatchObject({ status: "refused" });
    expect(privateHost!.details).toMatchObject({ status: "refused" });
    expect(redirected!.details).toMatchObject({ status: "refused" });
    // Only the redirecting hop itself was fetched; neither private target was.
    expect(f.fetchedUrls.slice(fetchedBefore)).toEqual(["https://example.org/redirect-private"]);

    // F3: no explicit trust decision means no read, even though files exist.
    const untrustedFile = join(f.root, "untrusted.txt");
    await writeFile(untrustedFile, "must not be readable");
    // A symlink inside the trusted project resolving outside it is refused on
    // its canonical location.
    const link = join(f.project, "escape.txt");
    await symlink(untrustedFile, link);
    // Home's own workspace carries an explicit `false` decision from designation.
    const homeWorkspaceFile = join(f.tronHome, "gateway", "home", "workspace", "inside-home.txt");
    await writeFile(homeWorkspaceFile, "home workspace content");
    const [untrusted, escaped, homeFile, relative] = await toolAnswers(f, "try unsafe reads", [
      { name: "read_file", args: { path: untrustedFile } },
      { name: "read_file", args: { path: link } },
      { name: "read_file", args: { path: homeWorkspaceFile } },
      { name: "read_file", args: { path: "relative/path.txt" } },
    ]);
    for (const answer of [untrusted, escaped, homeFile]) {
      expect(answer!.details).toMatchObject({ status: "refused" });
      expect(answer!.text).toContain("explicitly trusted projects");
    }
    expect(relative!.details).toMatchObject({ status: "refused" });
    expect(relative!.text).toContain("absolute path");

    // F4: a Knowledge write action is structurally outside the Home schema, so
    // the SDK refuses the arguments before the service is ever reached.
    const [write] = await toolAnswers(f, "try a knowledge write", [{ name: "knowledge", args: { action: "createNote", commandId: "evil-note-0001", title: "evil", scope: "personal" } }]);
    expect(write!.isError).toBe(true);
    const search = await f.knowledge.tool({ action: "search", query: "evil" });
    expect(search.text).toContain("No knowledge match.");

    // None of these refusals is a seam refusal: the activation always completed.
    expect(refusals(f)).toEqual([]);

    recordCase("bounds-and-refusals", {
      hugeResultChars: huge!.text.length,
      fetchedUrls: f.fetchedUrls,
      seamRefusals: refusals(f).length,
    });
  }, 120_000);

  it("searches the current edited message, not replaced or omitted text, and opens the same citation", async () => {
    const f = await fixture("search-edits", async (agentDir, cwd) => {
      const directory = join(agentDir, "sessions", "search-edits");
      await mkdir(directory, { recursive: true });
      const timestamp = new Date().toISOString();
      const entries = [
        { type: "session", version: 3, id: "edited-root", timestamp, cwd },
        { type: "message", id: "abandoned-user", parentId: null, timestamp,
          message: { role: "user", content: "ABANDONED-SEARCH-TEXT", timestamp: Date.now() } },
        { type: "message", id: "edited-user", parentId: null, timestamp,
          message: { role: "user", content: "REPLACED-PRIVATE-TEXT", timestamp: Date.now() } },
        { type: "message", id: "omitted-answer", parentId: "edited-user", timestamp,
          message: fauxAssistantMessage("OMITTED-PRIVATE-TEXT") },
        { type: "message", id: "nontext-answer", parentId: "omitted-answer", timestamp,
          message: fauxAssistantMessage([{ type: "thinking", thinking: "EXCLUDED-SEARCH-THOUGHT" },
            fauxToolCall("fixture_missing_tool", { text: "EXCLUDED-SEARCH-TOOL-ARG" })]) },
        { type: "custom_message", id: "hidden-entry", parentId: "nontext-answer", timestamp,
          customType: "fixture-hidden", content: "EXCLUDED-SEARCH-HIDDEN", display: false },
        { type: "context_edit", id: "first-edit", parentId: "hidden-entry", timestamp,
          targetId: "edited-user", replacement: { content: "SUPERSEDED-REPLACEMENT" } },
        { type: "context_edit", id: "omit-edit", parentId: "first-edit", timestamp,
          targetId: "omitted-answer", replacement: null },
        { type: "context_edit", id: "last-edit", parentId: "omit-edit", timestamp,
          targetId: "edited-user", replacement: { content: [{ type: "text", text: "CURRENT-EDIT-DECISION path=/work/source hash=abcdef" }] } },
      ];
      await writeFile(join(directory, "edited-root.jsonl"), entries.map(entry => JSON.stringify(entry)).join("\n") + "\n");
    });
    const sourcePath = join(f.agentDir, "sessions", "search-edits", "edited-root.jsonl");
    const original = await readFile(sourcePath, "utf8");
    const [current, ...excluded] = await toolAnswers(f, "find the current historical decision", [
      ...["CURRENT-EDIT-DECISION", "REPLACED-PRIVATE-TEXT", "OMITTED-PRIVATE-TEXT", "SUPERSEDED-REPLACEMENT",
        "ABANDONED-SEARCH-TEXT", "EXCLUDED-SEARCH-THOUGHT", "EXCLUDED-SEARCH-TOOL-ARG", "EXCLUDED-SEARCH-HIDDEN"]
        .map(query => ({ name: "session_search", args: { query, maxResults: 5 } })),
    ]);
    expect(current!.details).toMatchObject({ hits: [expect.objectContaining({ sessionId: "edited-root", entryId: "edited-user",
      title: expect.stringContaining("CURRENT-EDIT-DECISION"), snippet: expect.stringContaining("path=/work/source hash=abcdef") })] });
    for (const answer of excluded) expect(answer!.details).toMatchObject({ hits: [] });
    const [read] = await toolAnswers(f, "open that exact citation", [
      { name: "session_read", args: { sessionId: "edited-root", entryId: "edited-user", before: 0, after: 1 } },
    ]);
    expect(read!.text).toContain("entry=edited-user");
    expect(read!.text).toContain("CURRENT-EDIT-DECISION");
    expect(read!.text).toContain("[omitted]");
    for (const old of ["REPLACED-PRIVATE-TEXT", "OMITTED-PRIVATE-TEXT", "SUPERSEDED-REPLACEMENT"]) expect(read!.text).not.toContain(old);
    expect(await readFile(sourcePath, "utf8")).toBe(original);
    expect(refusals(f)).toEqual([]);
    recordCase("search-edits", { citation: "edited-root/edited-user", sourceUnchanged: true, staleHits: 0 });
  }, 60_000);

  it("redacts search snippets and explicit or fallback titles before persisted Home results", async () => {
    const secret = `sk-${"searchcredentialfixture".repeat(6)}`;
    const namedSecret = `Bearer ${"namedcredentialfixture".repeat(6)}`;
    const f = await fixture("search-credentials", async (agentDir, cwd) => {
      const directory = join(agentDir, "sessions", "search-credentials");
      await mkdir(directory, { recursive: true });
      for (const id of ["fallback-title-root", "named-title-root"]) {
        const timestamp = new Date().toISOString();
        const entries = [
          { type: "session", version: 3, id, timestamp, cwd },
          { type: "message", id: `${id}-user`, parentId: null, timestamp,
            message: { role: "user", content: `SEARCH-CREDENTIAL-PASSAGE ${secret}`, timestamp: Date.now() } },
          ...(id === "named-title-root" ? [{ type: "session_info", id: "name-entry", parentId: `${id}-user`, timestamp, name: namedSecret }] : []),
        ];
        await writeFile(join(directory, `${id}.jsonl`), entries.map(entry => JSON.stringify(entry)).join("\n") + "\n");
      }
    });
    const [search, secretOnly] = await toolAnswers(f, "inspect the historical passages", [
      { name: "session_search", args: { query: "SEARCH-CREDENTIAL-PASSAGE", maxResults: 5 } },
      { name: "session_search", args: { query: "searchcredentialfixture", maxResults: 5 } },
    ]);
    expect(search!.details).toMatchObject({ hits: [expect.any(Object), expect.any(Object)] });
    const serialized = JSON.stringify(search);
    expect(serialized).not.toContain("searchcredentialfixture");
    expect(serialized).not.toContain("namedcredentialfixture");
    expect(serialized).toContain("[REDACTED]");
    expect(secretOnly!.details).toMatchObject({ hits: [] });
    const persisted = (await readFile(f.slot.persistedSessionFile!, "utf8")).trim().split("\n")
      .map(line => JSON.parse(line)).filter(entry => entry.type === "message" && entry.message.role === "toolResult" && entry.message.toolName === "session_search");
    expect(persisted[0].message.details).toEqual(search!.details);
    expect(JSON.stringify(persisted[0])).not.toContain("searchcredentialfixture");
    expect(JSON.stringify(persisted[0])).not.toContain("namedcredentialfixture");
    recordCase("search-credentials", { roots: 2, resultRedacted: true, persistedDetailsRedacted: true, credentialOnlyHits: 0 });
  }, 60_000);

  it("keeps Home history on its native memory route instead of returning unreadable other-chat citations", async () => {
    const f = await fixture("search-home-route");
    const [search] = await toolAnswers(f, "HOME-NATIVE-HISTORY-ONLY", [
      { name: "session_search", args: { query: "HOME-NATIVE-HISTORY-ONLY", maxResults: 5 } },
    ]);
    expect(search!.details).toMatchObject({ status: "ok", hits: [] });
    expect(f.registry.homeOwner().isHomeChapter(f.sessionId)).toBe(true);
    // A settled Home turn dirties the catalog too; it must not become a
    // spurious omission when coverage is recomputed on the next search.
    const refreshed = await f.search.search({ query: "HOME-NATIVE-HISTORY-ONLY" });
    expect(refreshed.results).toEqual([]);
    expect(refreshed.coverage).toMatchObject({ sessionsTotal: 0, sessionsIndexed: 0, omittedSessions: 0, state: "complete" });
    expect(refusals(f)).toEqual([]);
    await f.registry.homeOwner().disable();
    expect(f.registry.homeOwner().isHomeChapter(f.sessionId)).toBe(true);
    const disabled = await f.search.search({ query: "HOME-NATIVE-HISTORY-ONLY" });
    expect(disabled.results).toEqual([]);
    expect(disabled.coverage).toMatchObject({ sessionsTotal: 0, omittedSessions: 0 });
    recordCase("search-home-route", { homeChapterHits: 0, disabledChapterHits: 0, coverage: refreshed.coverage, seamRefusals: 0 });
  }, 60_000);

  it("rederives a v1 raw index from unchanged canonical history instead of reusing unsafe postings", async () => {
    const secret = `sk-${"oldcachecredentialfixture".repeat(2)}`;
    let sourcePath = "";
    const f = await fixture("search-old-index", async (agentDir, cwd) => {
      const directory = join(agentDir, "sessions", "old-index");
      await mkdir(directory, { recursive: true });
      sourcePath = join(directory, "old-index-root.jsonl");
      const timestamp = new Date().toISOString();
      await writeFile(sourcePath, [
        { type: "session", version: 3, id: "old-index-root", timestamp, cwd },
        { type: "message", id: "old-index-user", parentId: null, timestamp,
          message: { role: "user", content: `OLD-INDEX-ORIGINAL ${secret}`, timestamp: Date.now() } },
        { type: "context_edit", id: "old-index-edit", parentId: "old-index-user", timestamp,
          targetId: "old-index-user", replacement: { content: `CURRENT-INDEX-DECISION ${secret}` } },
      ].map(entry => JSON.stringify(entry)).join("\n") + "\n");
    }, async (registry, path) => {
      const cut = await registry.readSearchCut("old-index-root");
      const identity = (await registry.searchCatalogIdentities())?.get("old-index-root");
      if (!identity) throw new Error("fixture has no verified catalog identity");
      const old = await SessionSearchIndex.open(path);
      try {
        // A real old-generation durable row, stamped with *unchanged* catalog
        // facts. Only the derivation fence can make warm-up parse it again.
        await old.replace({ sessionId: "old-index-root", title: `OLD-INDEX-ORIGINAL ${secret}`, cwd: cut.summary.cwd,
          updatedAt: new Date().toISOString(), fileIdentity: identity.fileIdentity,
          branchDigest: createHash("sha256").update(JSON.stringify(cut.entries.slice(1))).digest("base64url"),
          leafEntryId: "old-index-edit", entries: [{ id: "old-index-user", parentId: null, timestamp: new Date().toISOString(),
            ordinal: 0, role: "user", text: `OLD-INDEX-ORIGINAL ${secret}` }] }, identity);
      } finally { old.close(); }
      const database = new DatabaseSync(path);
      try { database.prepare("UPDATE schema SET value = ? WHERE key = 'schema'").run("session-search-index-2:session-search-derivation-1"); }
      finally { database.close(); }
    });
    const canonical = await readFile(sourcePath, "utf8");
    await f.search.warm();
    const database = new DatabaseSync(join(f.tronHome, "gateway", "session-search.sqlite"), { readOnly: true });
    try {
      expect(JSON.stringify(database.prepare("SELECT term FROM passage_terms").all())).not.toContain("oldcachecredentialfixture");
      expect(JSON.stringify(database.prepare("SELECT title FROM sessions").all())).not.toContain("oldcachecredentialfixture");
    } finally { database.close(); }
    const [current, old] = await toolAnswers(f, "find the current indexed decision", [
      { name: "session_search", args: { query: "CURRENT-INDEX-DECISION", maxResults: 5 } },
      { name: "session_search", args: { query: "OLD-INDEX-ORIGINAL", maxResults: 5 } },
    ]);
    expect(current!.details).toMatchObject({ hits: [expect.objectContaining({ sessionId: "old-index-root", entryId: "old-index-user" })] });
    expect(JSON.stringify(current)).not.toContain("oldcachecredentialfixture");
    expect(old!.details).toMatchObject({ hits: [] });
    expect(f.search.indexPassStats()).toMatchObject({ reusedSessions: 0, parsedSessions: 1 });
    expect(await readFile(sourcePath, "utf8")).toBe(canonical);
    recordCase("search-old-index", { unchangedSource: true, rawRowsReused: 0, rederivedSessions: 1, credentialPostings: 0 });
  }, 60_000);

  it("drops an edited passage while semantic ranking awaits and reads the new canonical content", async () => {
    const f = await fixture("search-publication-edit");
    const ordinary = await f.registry.create(f.project);
    await ordinary.setModel(PROVIDER, MODEL_ID);
    const secret = `sk-${"embeddingcredentialfixture".repeat(2)}`;
    f.faux.setResponses([fauxAssistantMessage(`PUBLICATION-RACE-NEEDLE original decision ${secret}`)]);
    await ordinary.prompt("a separate historical decision");
    await waitFor(() => ordinary.snapshot().phase === "idle" || undefined, "historical answer settled");
    const cut = await f.registry.readSearchCut(ordinary.id);
    const anchor = cut.entries.find(entry => entry.type === "message" && entry.message.role === "assistant");
    if (!anchor) throw new Error("fixture has no source answer");
    expect((await f.search.search({ query: "PUBLICATION-RACE-NEEDLE" })).results.map(hit => hit.entryId)).toContain(anchor.id);
    let release!: () => void;
    let started = false;
    const barrier = new Promise<void>(resolve => { release = resolve; });
    const embedded: string[] = [];
    const metadata = { dimension: 2, language: "en", modelRevision: "fixture-local" };
    f.search.setSemanticClient({
      qualify: async () => metadata,
      embed: async text => {
        embedded.push(text);
        if (text === "PUBLICATION-RACE-NEEDLE") { started = true; await barrier; }
        return { ...metadata, vector: [1, 0] };
      },
    });
    await waitFor(async () => (await f.search.search({ query: "warm-index" })).semantic.state === "ready" || undefined, "local ranking ready");
    const pending = f.search.search({ query: "PUBLICATION-RACE-NEEDLE" });
    try {
      await waitFor(() => started || undefined, "query ranking awaiting");
      // Append through the one live SDK owner, not an independently opened file.
      const manager = (ordinary as unknown as { sessionManager: SessionManager }).sessionManager;
      manager.appendContextEdit(anchor.id, { content: [{ type: "text", text: "PUBLICATION-CURRENT-DECISION" }] });
    } finally { release(); await pending; }
    const result = await pending;
    expect(embedded.some(text => text.includes("original decision") && text.includes("[REDACTED]"))).toBe(true);
    expect(JSON.stringify(embedded)).not.toContain("embeddingcredentialfixture");
    expect(result.results.map(hit => hit.entryId)).not.toContain(anchor.id);
    const [read] = await toolAnswers(f, "verify the revised historical citation", [
      { name: "session_read", args: { sessionId: ordinary.id, entryId: anchor.id, before: 0, after: 0 } },
    ]);
    expect(read!.text).toContain("PUBLICATION-CURRENT-DECISION");
    expect(read!.text).not.toContain("PUBLICATION-RACE-NEEDLE");
    recordCase("search-publication-edit", { staleCitationDropped: true, canonicalEditReadable: true, localEmbeddings: embedded.length });
  }, 60_000);

  it("retrieves a preserved Chronicle revision and verifies its source through the existing Home tools", async () => {
    const f = await fixture("legacy-chronicle-citation");
    const ordinary = await f.registry.create(f.project);
    await ordinary.setModel(PROVIDER, MODEL_ID);
    f.faux.setResponses([fauxAssistantMessage("LEGACY-UNIQUE-DECISION was accepted, not merely proposed")]);
    await ordinary.prompt("record the historical decision");
    await waitFor(() => ordinary.snapshot().phase === "idle" || undefined, "legacy source settled");
    const cut = await f.registry.readSearchCut(ordinary.id);
    const anchor = cut.entries.find(entry => entry.type === "message" && entry.message.role === "assistant");
    if (!anchor) throw new Error("fixture has no historical answer");
    const range = { sessionId: ordinary.id, fromEntryId: anchor.id, toEntryId: anchor.id, entryIds: [anchor.id], entryDigest: legacyEntriesDigest([anchor]) };
    // A pre-#1315 observer's record; Chronicle generation itself is retired.
    const published = await seedLegacyChronicle(f.registry.knowledgeWorkspace(), f.store, { groups: [{ coverageId: "legacy-fixture-cut", range,
      records: [{ id: "legacy-chronicle-record", item: { text: "LEGACY-UNIQUE-DECISION was accepted", attribution: "assistant", certainty: "certain", observedAt: anchor.timestamp } }] }] });
    const legacy = published.records[0]!;
    const before = JSON.stringify(await f.store.read(legacy.id, legacy.revisionId));
    const source = await readFile(ordinary.persistedSessionFile!, "utf8");
    const [recall, record, search, read] = await toolAnswers(f, "find and verify the historical decision without regenerating it", [
      { name: "knowledge", args: { action: "recall", query: "LEGACY-UNIQUE-DECISION", limit: 3 } },
      { name: "knowledge", args: { action: "read", id: legacy.id, revisionId: legacy.revisionId } },
      { name: "session_search", args: { query: "LEGACY-UNIQUE-DECISION", maxResults: 3 } },
      { name: "session_read", args: { sessionId: ordinary.id, entryId: anchor.id, before: 0, after: 0 } },
    ]);
    expect(recall!.text).toContain(legacy.id);
    expect(recall!.text).toContain(legacy.revisionId);
    expect(record!.text).toContain(range.entryDigest);
    expect(record!.text).toContain(anchor.id);
    expect(search!.details).toMatchObject({ hits: [expect.objectContaining({ sessionId: ordinary.id, entryId: anchor.id })] });
    expect(read!.text).toContain("was accepted, not merely proposed");
    expect(JSON.stringify(await f.store.read(legacy.id, legacy.revisionId))).toBe(before);
    expect(await readFile(ordinary.persistedSessionFile!, "utf8")).toBe(source);
    expect((await f.store.search({ kind: "observation", query: "LEGACY-UNIQUE-DECISION" })).hits).toHaveLength(1);
    expect(refusals(f)).toEqual([]);
    recordCase("legacy-chronicle-citation", { record: legacy.id, revision: legacy.revisionId, sourceSession: ordinary.id,
      sourceEntry: anchor.id, sourceDigest: range.entryDigest, sourceUnchanged: true, revisionUnchanged: true, observations: 1 });
  }, 60_000);

  it("opens a cited root entry with redacted neighbours, refuses Home and foreign ids, and keeps the prefix constant", async () => {
    const f = await fixture("cited-entry");
    const ordinary = await f.registry.create(f.project);
    await ordinary.setModel(PROVIDER, MODEL_ID);
    const secret = `sk-${"privatefixture".repeat(3)}`;
    const reply = fauxAssistantMessage(`CITED-ANSWER ${secret} ${"long public passage ".repeat(2_000)} CITED-ANSWER-END`);
    reply.content.unshift({ type: "thinking", thinking: "PRIVATE-THOUGHT-NOT-EVIDENCE" });
    f.faux.setResponses([reply]);
    await ordinary.prompt(`CITED-NEIGHBOUR-BEFORE ${"large preceding text ".repeat(2_000)} BEFORE-END`);
    await waitFor(() => ordinary.snapshot().phase === "idle" || undefined, "cited reply settled");
    f.faux.setResponses([fauxAssistantMessage("second reply")]);
    await ordinary.prompt(`CITED-NEIGHBOUR-AFTER ${"large following text ".repeat(2_000)} AFTER-END`);
    await waitFor(() => ordinary.snapshot().phase === "idle" || undefined, "neighbour reply settled");
    const cut = await f.registry.readSearchCut(ordinary.id);
    const anchor = cut.entries.find(entry => entry.type === "message" && entry.message.role === "assistant");
    if (!anchor) throw new Error("fixture did not persist the cited assistant entry");

    const [read] = await toolAnswers(f, "verify the cited answer", [
      { name: "session_read", args: { sessionId: ordinary.id, entryId: anchor.id, before: 1, after: 1 } },
    ]);
    expect(read!.isError, read!.text).toBe(false);
    expect(read!.details).toEqual({ status: "ok" });
    expect(read!.text).toContain(anchor.id);
    expect(read!.text).toContain("CITED-ANSWER");
    expect(read!.text).toContain("CITED-ANSWER-END");
    expect(read!.text).toContain("CITED-NEIGHBOUR-BEFORE");
    expect(read!.text).toContain("CITED-NEIGHBOUR-AFTER");
    expect(read!.text).toContain("BEFORE-END");
    expect(read!.text).toContain("AFTER-END");
    expect(read!.text).toContain("[REDACTED]");
    expect(read!.text).not.toContain(secret);
    expect(read!.text).not.toContain("PRIVATE-THOUGHT-NOT-EVIDENCE");
    expect(read!.text).toContain("untrusted content");
    expect(read!.text.length).toBeLessThanOrEqual(30_000);
    expect(read!.text).toContain("[truncated");

    const homeEntry = f.slot.canonicalSessionEntries().find(entry => entry.type === "message" && entry.message.role === "user");
    if (!homeEntry) throw new Error("fixture did not persist its Home activation");
    const [home, foreign, missing] = await toolAnswers(f, "check admission", [
      { name: "session_read", args: { sessionId: f.sessionId, entryId: homeEntry.id } },
      { name: "session_read", args: { sessionId: "not-a-canonical-session", entryId: anchor.id } },
      { name: "session_read", args: { sessionId: ordinary.id, entryId: "not-a-canonical-entry" } },
    ]);
    for (const result of [home, foreign, missing]) {
      expect(result!.details).toMatchObject({ status: "refused" });
      expect(result!.text).not.toContain("CITED-ANSWER");
    }
    const firstUser = cut.entries.find(entry => entry.type === "message" && entry.message.role === "user");
    if (!firstUser) throw new Error("fixture has no branch point");
    await ordinary.navigate(firstUser.id, { summarize: false });
    const [offBranch] = await toolAnswers(f, "recheck after branch navigation", [
      { name: "session_read", args: { sessionId: ordinary.id, entryId: anchor.id } },
    ]);
    expect(offBranch!.details).toMatchObject({ status: "refused" });
    expect(offBranch!.text).not.toContain("CITED-ANSWER");
    const systemMessages = f.requests.map(request => (JSON.parse(request.blob) as Message[]).filter(message => message.role === "system"));
    const schemas = systemMessages[0]!.flatMap(message => message.toolsAdded ?? []);
    expect(schemas.find(tool => tool.name === "session_read")?.parameters).toBeDefined();
    const heads = systemMessages.map(messages => JSON.stringify(messages));
    expect(heads[0]).toContain("session_read");
    expect(new Set(heads).size, "actual system/tool prefix across activations").toBe(1);
    expect(refusals(f)).toEqual([]);
    recordCase("cited-entry", {
      chars: read!.text.length, credentialPresent: read!.text.includes(secret),
      chapterStatus: home!.details?.status, offBranchStatus: offBranch!.details?.status,
      prefixHeads: new Set(heads).size, prefixToolNames: schemas.map(tool => tool.name),
    });
  }, 120_000);

  it("redacts credentials before source projection caps can split their shape", async () => {
    const f = await fixture("credential-edge");
    const ordinary = await f.registry.create(f.project);
    await ordinary.setModel(PROVIDER, MODEL_ID);
    const secret = `sk-${"boundarycredential".repeat(3)}`;
    // JSON's closing quote/brace put the shared 4K tail twenty characters
    // into this credential. Redacting only the already-capped text leaks its suffix.
    const text = `${"p".repeat(50_000)} ${secret} ${"z".repeat(4_017 - secret.length)}`;
    f.faux.setResponses([
      fauxAssistantMessage(fauxToolCall("fixture_missing_tool", { text })),
      fauxAssistantMessage("source tool call settled"),
    ]);
    await ordinary.prompt("record the synthetic tool arguments");
    await waitFor(() => ordinary.snapshot().phase === "idle" || undefined, "source tool call settled");
    const cut = await f.registry.readSearchCut(ordinary.id);
    const anchor = cut.entries.find(entry => entry.type === "message" && entry.message.role === "assistant"
      && entry.message.content.some(part => part.type === "toolCall"));
    if (!anchor) throw new Error("fixture tool-call entry was not persisted");
    expect(JSON.stringify(anchor)).toContain(secret);
    const [read] = await toolAnswers(f, "read the cited tool call", [
      { name: "session_read", args: { sessionId: ordinary.id, entryId: anchor.id, before: 0, after: 0 } },
    ]);
    expect(read!.details).toEqual({ status: "ok" });
    expect(read!.text).not.toContain(secret.slice(-20));
    expect(read!.text).toContain("fixture_missing_tool");
    recordCase("credential-edge", { suffixPresent: read!.text.includes(secret.slice(-20)), chars: read!.text.length });
  }, 60_000);

  it("refuses session_read when the Home ledger becomes missing during an activation", async () => {
    const f = await fixture("ledger-missing");
    f.faux.setResponses([async () => {
      const entry = f.slot.canonicalSessionEntries().find(item => item.type === "message" && item.message.role === "user");
      if (!entry) throw new Error("fixture Home activation was not persisted");
      await rm(join(f.tronHome, "gateway", "home", "home.json"));
      await f.registry.homeOwner().initialize();
      return fauxAssistantMessage(fauxToolCall("session_read", { sessionId: f.sessionId, entryId: entry.id }));
    }]);
    await f.slot.prompt("HOME-LEDGER-PRIVATE-CONTENT");
    const result = await waitFor(() => toolResultsOf({ blob: JSON.stringify(f.slot.canonicalSessionEntries()
      .flatMap(entry => entry.type === "message" ? [entry.message] : [])) })
      .find(answer => answer.toolName === "session_read"), "registered tool result after ledger reload", { boundMs: 30_000 });
    expect(result.details).toMatchObject({ status: "refused" });
    expect(result.text).not.toContain("HOME-LEDGER-PRIVATE-CONTENT");
    recordCase("ledger-missing", { status: result.details?.status, leaked: result.text.includes("HOME-LEDGER-PRIVATE-CONTENT") });
  }, 60_000);

  it("refuses cataloged children and malformed roots while reading an ordinary parent", async () => {
    const f = await fixture("delegated-admission", async (agentDir, cwd) => {
      const directory = join(agentDir, "sessions", "reader-fixture");
      const childDirectory = join(directory, "reader-parent", "worker", "run-0");
      await mkdir(childDirectory, { recursive: true });
      const timestamp = new Date().toISOString();
      const source = (id: string, entryId: string, text: string) => [
        { type: "session", version: 3, id, timestamp, cwd },
        { type: "message", id: entryId, parentId: null, timestamp,
          message: { role: "user", content: [{ type: "text", text }], timestamp: Date.now() } },
      ].map(entry => JSON.stringify(entry)).join("\n") + "\n";
      await writeFile(join(directory, "reader-parent.jsonl"), source("reader-parent", "parent-entry", "PARENT-READABLE"));
      await writeFile(join(childDirectory, "session.jsonl"), source("reader-child", "child-entry", "CHILD-NOT-READABLE"));
      // A valid anchor after an oversized neighbour proves full graph admission
      // runs before projection/budgeting, not merely an anchor lookup failure.
      const oversizedId = "x".repeat(30_000);
      const invalid = source("reader-invalid-ids", oversizedId, "BAD-GRAPH-CONTENT") + JSON.stringify({
        type: "message", id: "graph-anchor", parentId: oversizedId, timestamp,
        message: { role: "user", content: [{ type: "text", text: "BAD-GRAPH-ANCHOR" }], timestamp: Date.now() },
      }) + "\n";
      await writeFile(join(directory, "reader-invalid-ids.jsonl"), invalid);
    });
    const catalog = await f.registry.catalog("all");
    expect(catalog.sessions.find(session => session.id === "reader-child")).toMatchObject({ kind: "subagent" });
    expect(catalog.sessions.find(session => session.id === "reader-invalid-ids")).toMatchObject({ kind: "user" });
    const [parent, child, malformed] = await toolAnswers(f, "read only the admitted ordinary root", [
      { name: "session_read", args: { sessionId: "reader-parent", entryId: "parent-entry" } },
      { name: "session_read", args: { sessionId: "reader-child", entryId: "child-entry" } },
      { name: "session_read", args: { sessionId: "reader-invalid-ids", entryId: "graph-anchor" } },
    ]);
    expect(parent!.details).toEqual({ status: "ok" });
    expect(parent!.text).toContain("PARENT-READABLE");
    expect(child!.details).toMatchObject({ status: "refused" });
    expect(child!.text).not.toContain("CHILD-NOT-READABLE");
    expect(malformed!.details).toMatchObject({ status: "refused" });
    expect(malformed!.text).not.toContain("BAD-GRAPH");
    recordCase("delegated-admission", { parentStatus: parent!.details?.status, childStatus: child!.details?.status, malformedStatus: malformed!.details?.status });
  }, 60_000);

  it("leaves ordinary sessions without research tools or the Home-only modules", async () => {
    const f = await fixture("ordinary");
    const ordinary = await f.registry.create(f.project);
    await ordinary.setModel(PROVIDER, MODEL_ID);
    const context = await ordinary.context() as unknown as {
      availableTools: Array<{ name: string }>;
      extensions: Array<{ name: string }>;
    };
    const tools = context.availableTools.map((tool) => tool.name);
    // F6: the Tron-owned research registrations exist only in Home. (`knowledge`
    // stays: ordinary sessions get tron-core's full Knowledge tool.)
    for (const name of ["web_search", "web_fetch", "session_search", "session_read", "read_file"]) {
      expect(tools, `ordinary sessions must not register ${name}`).not.toContain(name);
    }
    expect(tools).toContain("knowledge");
    expect(tools).toContain("bash");
    const extensions = context.extensions.map((extension) => extension.name.replace(/^<inline:/, "").replace(/>$/, ""));
    expect(extensions).not.toContain("tron-home-research");
    expect(extensions).not.toContain("tron-home");
    recordCase("ordinary-unaffected", { ordinaryTools: tools.length, extensions });
  }, 120_000);
});
