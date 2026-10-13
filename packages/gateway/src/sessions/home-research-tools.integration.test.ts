/**
 * Tron Home's curated read-only research tools (#724), end to end: `web_search`,
 * `web_fetch`, `session_search`, `knowledge` and `read_file` registered by the
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
import { mkdir, mkdtemp, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import {
  fauxAssistantMessage, fauxProvider, fauxToolCall,
  type FauxProviderHandle, type ToolCall,
} from "@earendil-works/pi-ai";
import { afterAll, afterEach, describe, expect, it } from "vitest";
import { waitFor } from "../../test-support/wait-for.js";
import { TrustService } from "../admin/trust-service.js";
import type { HomeRequestRecord } from "../home/home-request-policy.js";
import type { HomeResearchToolDetails } from "../home/home-research-tools.js";
import { KnowledgeObservationService } from "../knowledge/knowledge-observation.js";
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
  sessionId: string;
  slot: HomeSlot;
}

async function fixture(label: string): Promise<Fixture> {
  const root = await mkdtemp(join(tmpdir(), `tron-home-research-${label}-`));
  roots.push(root);
  const agentDir = join(root, "agent");
  const tronHome = join(root, "tron");
  const project = join(root, "project");
  await Promise.all([mkdir(agentDir, { recursive: true }), mkdir(project, { recursive: true })]);
  await writeFile(join(agentDir, "settings.json"), JSON.stringify({ defaultProvider: PROVIDER, defaultModel: MODEL_ID }));
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
    homeMemorySummarizer: () => ({ summarizer: async () => fauxAssistantMessage("HOME-RESEARCH-LINE") }),
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
  const knowledge = new KnowledgeService(store, new KnowledgeObservationService(store, undefined));
  registry.setKnowledgeService(knowledge);
  const index = await SessionSearchIndex.open(join(tronHome, "gateway", "session-search.sqlite"));
  indexes.push(index);
  registry.setSessionSearchService(new SessionSearchService(registry, index));

  const designation = await registry.homeOwner().designate({ model: MODEL }, () => MODEL);
  await registry.homeOwner().configureMemory({ model: MEMORY_MODEL });
  const slot = await registry.acquire(designation.sessionId);
  return {
    root, agentDir, tronHome, project, faux, runtime, trust, registry,
    requestRecords, requests: [], fetchedUrls: web.fetchedUrls, knowledge,
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
  it("runs every research tool inside Home activations with zero seam refusals, bounded results", async () => {
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
    expect(sessions!.details).toEqual({ status: "ok" });
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
      tools: ["web_search", "web_fetch", "session_search", "knowledge", "read_file"],
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
    for (const name of ["web_search", "web_fetch", "session_search", "read_file"]) {
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
