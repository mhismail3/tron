import { workspaceModule } from "../workspace/workspace-module.js";
import { createTestRegistry, homeOwnerOf } from "../../test-support/gateway-registry.js";
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
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { DatabaseSync } from "node:sqlite";
import { mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { setHomeMemoryModels } from "../../test-support/settings-dependencies.js";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ModelRuntime, type SessionManager } from "@earendil-works/pi-coding-agent";
import {
  fauxAssistantMessage, fauxProvider, fauxToolCall, getCurrentTools,
  type FauxProviderHandle, type ToolCall, type Message,
} from "@earendil-works/pi-ai";
import { afterAll, afterEach, describe, expect, it } from "vitest";
import { waitFor } from "../../test-support/wait-for.js";
import { TrustService } from "../kernel/resources/trust-service.js";
import type { HomeRequestRecord } from "../modules/home/home-request-policy.js";
import type { HomeResearchToolDetails } from "../modules/home/home-research-tools.js";
import type { WebResearchTransport } from "../knowledge/web-research.js";
import { KnowledgeService } from "../knowledge/knowledge-service.js";
import { KnowledgeStore } from "../knowledge/knowledge-store.js";
import { RuntimeRegistry } from "../kernel/session/runtime-registry.js";
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
const servers: Server[] = [];

afterEach(async () => {
  await Promise.all(registries.splice(0).map((registry) => registry.dispose().catch(() => {})));
  for (const index of indexes.splice(0)) index.close();
  await Promise.all(servers.splice(0).map(server => new Promise<void>((resolve, reject) => {
    server.close(error => error ? reject(error) : resolve());
    server.closeAllConnections();
  })));
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
        if (url.pathname === "/huge") return htmlResponse(HUGE_HTML);
        if (url.pathname === "/redirect-private") return new Response(null, { status: 302, headers: { location: "http://127.0.0.1/secret" } });
        return htmlResponse(PAGE_HTML);
      },
      providerFetcher: async (input: string | URL, init?: RequestInit): Promise<Response> => {
        const body = JSON.parse(String(init?.body));
        const data = new URL(String(input)).pathname.endsWith("/search") ? { web: [
          { url: "https://example.org/alpha", title: "Alpha & result", description: "First snippet text" },
          { url: "https://example.org/beta", title: "Beta result", description: "Second snippet" },
        ] } : { markdown: String(body.url).endsWith("/huge") ? "huge page text that keeps repeating so the result must be capped. ".repeat(3_000) : ARTICLE_BODY,
          metadata: { sourceURL: body.url, title: String(body.url).endsWith("/huge") ? "Huge" : "Research Fixture Page", statusCode: 200 } };
        return Response.json({ success: true, data });
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
  transport?: WebResearchTransport,
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
  let search: SessionSearchService | undefined;
  let knowledge: KnowledgeService | undefined;
  const registry = await createTestRegistry({ knowledge: () => knowledge, agentDir, sessionSearch: () => search,
    tronHome,
    idleRuntimeMs: 60_000,
    modelRuntimeFactory: async () => runtime,
    trust,
    broadcast: () => {},
    sessionSummaryChanged: () => {},
    sessionListChanged: () => {},
    homeMemorySummarizer: () => async () => fauxAssistantMessage("HOME-RESEARCH-LINE"),
    homeRequestDiagnostic: (record) => requestRecords.push(record),
    homeWebTransport: transport ?? web.transport,
  });
  registries.push(registry);
  await registry.initialize();
  const hasCut = (): boolean => (registry as unknown as { sessionCatalog: { hasCompleteCut(): boolean } }).sessionCatalog.hasCompleteCut();
  await waitFor(() => hasCut() || undefined, "catalog cut", { boundMs: 30_000 });
  await registry.catalog("all");

  // Real owners, installed the way gateway-main installs them.
  const store = new KnowledgeStore(registry.moduleHost.contract(workspaceModule), () => {});
  knowledge = new KnowledgeService(store);
  const indexPath = join(tronHome, "gateway", "session-search.sqlite");
  await seedIndex?.(registry, indexPath);
  const index = await SessionSearchIndex.open(indexPath);
  indexes.push(index);
  search = new SessionSearchService(registry, index);

  const designation = await homeOwnerOf(registry).designate({ model: MODEL }, () => MODEL);
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
  async function sharedFixture(label: string, seedCanonical?: (agentDir: string, project: string) => Promise<void>) {
    const calls: Array<{ path: string; body: Record<string, any> }> = [];
    const server = createServer((request, response) => {
      const chunks: Buffer[] = [];
      request.on("data", chunk => chunks.push(chunk));
      request.on("end", () => {
        const body = chunks.length ? JSON.parse(Buffer.concat(chunks).toString("utf8")) : {};
        calls.push({ path: request.url!, body });
        if (request.url === "/origin") { response.writeHead(200, { "content-type": "text/html" }); response.end(PAGE_HTML); return; }
        response.setHeader("content-type", "application/json");
        if (body.query === "quota") { response.writeHead(429, { "retry-after": "120" }); response.end("{}"); return; }
        if (request.url === "/v2/search") {
          if (body.query === "malformed") { response.end("{bad json"); return; }
          const paths = body.query === "empty" ? [] : body.query === "partial" ? ["good", "missing"] : body.query === "deadline" ? ["good", "hung"] : ["good?utm_source=x", "good#anchor", "duplicate-body"];
          response.end(JSON.stringify({ success: true, data: { web: paths.map((path, index) => ({ url: `https://example.org/${path}`, title: `Document ${index}`, description: path.includes("good") || path === "duplicate-body" ? "Known fixture passage." : "Another fixture source." })) } })); return;
        }
        const url = String(body.url ?? "");
        if (url.endsWith("/hung")) { const timer = setTimeout(() => response.end("{}"), 30000); response.on("close", () => clearTimeout(timer)); return; }
        response.end(JSON.stringify({ success: true, data: { markdown: url.endsWith("/missing") ? "# Not Found\nThis document does not exist." : url.endsWith("/blocked") ? "Verify you are human to continue." : url.endsWith("/captcha-article") ? "# CAPTCHA\nDiscussing CAPTCHA design is ordinary article evidence, not a request to solve a challenge." : `Known fixture passage. ${"資料🙂".repeat(5000)}`,
          metadata: { sourceURL: url, title: url.endsWith("/blocked") ? "Just a moment" : url.endsWith("/captcha-article") ? "CAPTCHA" : "Fixture article", statusCode: url.endsWith("/missing") ? 404 : 200 } } }));
      });
    });
    servers.push(server);
    await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
    const endpoint = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
    const f = await fixture(label, seedCanonical, undefined, {
      resolveHost: async () => [PUBLIC_ADDRESS],
      fetcher: (_input, init) => fetch(`${endpoint}/origin`, init),
      providerFetcher: (input, init) => fetch(`${endpoint}${new URL(String(input)).pathname}`, init),
    });
    return { f, calls };
  }

  it("shared web accepts an article discussing CAPTCHA and rejects empty or invalid inputs", async () => {
    const { f, calls } = await sharedFixture("shared-content-validation");
    const [article, blank, invalid] = await toolAnswers(f, "distinguish an article from unavailable evidence", [
      { name: "web_search", args: { op: "read", url: "https://example.org/captcha-article" } },
      { name: "web_search", args: { op: "search", query: " " } },
      { name: "web_search", args: { op: "read", urls: [] } },
    ]);
    expect(article!.isError).toBe(false); expect(article!.text).toContain("Discussing CAPTCHA design");
    expect(blank!.isError).toBe(true); expect(JSON.parse(blank!.text).reason).toBe("invalid_input");
    expect(invalid!.isError).toBe(true); expect(calls).toHaveLength(2);
    recordCase("shared-content-and-input-validation", { article: JSON.parse(article!.text), blank: blank!.isError, invalid: invalid!.isError });
  }, 120_000);

  it("shared web excludes the retired package before code execution without changing canonical settings", async () => {
    let settings = ""; let marker = "";
    const { f } = await sharedFixture("shared-retirement", async agentDir => {
      settings = JSON.stringify({ defaultProvider: PROVIDER, defaultModel: MODEL_ID, packages: ["npm:pi-web-access@0.22.0"] });
      await writeFile(join(agentDir, "settings.json"), settings);
      const npm = join(agentDir, "npm"); const pkg = join(npm, "node_modules", "pi-web-access");
      await mkdir(pkg, { recursive: true }); marker = join(agentDir, "legacy-provider-executed");
      await writeFile(join(npm, "package.json"), JSON.stringify({ dependencies: { "pi-web-access": "0.22.0" } }));
      await writeFile(join(pkg, "package.json"), JSON.stringify({ name: "pi-web-access", version: "0.22.0", pi: { extensions: ["index.mjs"] } }));
      await writeFile(join(pkg, "index.mjs"), `import { writeFileSync } from 'node:fs'; writeFileSync(${JSON.stringify(marker)}, 'executed'); export default () => {};`);
    });
    const ordinary = await f.registry.create(f.project); await ordinary.setModel(PROVIDER, MODEL_ID);
    const [answer] = await toolAnswers({ ...f, slot: ordinary }, "use the admitted web capability", [{ name: "web_search", args: { op: "search", query: "dedupe" } }]);
    expect(answer!.isError).toBe(false);
    await ordinary.reload(true, true, true);
    expect(await readFile(marker, "utf8").then(() => true, () => false)).toBe(false);
    expect(await readFile(join(f.agentDir, "settings.json"), "utf8")).toBe(settings);
    recordCase("shared-retired-package", { executed: false, canonicalSettingsPreserved: true });
  }, 120_000);

  it("shared web schema and scoped source reads are identical in Home and an ordinary worker", async () => {
    const { f } = await sharedFixture("shared-parity");
    const ordinary = await f.registry.create(f.project); await ordinary.setModel(PROVIDER, MODEL_ID);
    const schemas: unknown[] = [];
    for (const [index, slot] of [f.slot, ordinary].entries()) {
      f.faux.setResponses([context => {
        schemas.push(getCurrentTools(context.messages).find(tool => tool.name === "web_search"));
        return fauxAssistantMessage("schema captured");
      }]);
      await slot.prompt("inspect registered research capability");
      await waitFor(() => schemas.length === index + 1 || undefined, "schema reached model", { boundMs: 30_000 });
      await waitFor(() => slot.snapshot().configurationBlocker === null || undefined, "schema activation settled", { boundMs: 30_000 });
    }
    expect(schemas).toHaveLength(2); expect(schemas[0]).toBeDefined(); expect(schemas[1]).toEqual(schemas[0]);
    const [search] = await toolAnswers(f, "search shared fixtures", [{ name: "web_search", args: { op: "search", query: "dedupe" } }]);
    expect(search!.isError).toBe(false);
    const found = JSON.parse(search!.text);
    expect(found.status).toBe("ok"); expect(found.sources).toHaveLength(1);
    expect(found.sources[0].url).toBe("https://example.org/good");
    const [read] = await toolAnswers(f, "read that citation", [{ name: "web_search", args: { op: "read", url: found.sources[0].url, freshness: "fresh" } }]);
    const page = JSON.parse(read!.text);
    expect(page.sources[0].content).toContain("Known fixture passage.");
    expect(Buffer.byteLength(read!.text)).toBeLessThanOrEqual(8192);
    const request = { op: "content", resultId: page.resultId, sourceId: page.sources[0].sourceId, find: "Known fixture passage" };
    const [own] = await toolAnswers(f, "open stored passage", [{ name: "web_search", args: request }]);
    expect(own!.isError).toBe(false); expect(own!.text).toContain("Known fixture passage.");
    const [foreign] = await toolAnswers({ ...f, slot: ordinary }, "try unrelated session handle", [{ name: "web_search", args: request }]);
    expect(foreign!.isError).toBe(true); expect(JSON.parse(foreign!.text).reason).toBe("expired");
    recordCase("shared-schema-scoped-content", { schemaEqual: true, searchBytes: Buffer.byteLength(search!.text), readBytes: Buffer.byteLength(read!.text) });
  }, 120_000);

  it("shared web reports source404, blocked, malformed, empty and partial outcomes truthfully", async () => {
    const { f } = await sharedFixture("shared-status");
    const answers = await toolAnswers(f, "exercise public fixture outcomes", [
      { name: "web_search", args: { op: "read", url: "https://example.org/missing" } },
      { name: "web_search", args: { op: "read", url: "https://example.org/blocked" } },
      { name: "web_search", args: { op: "search", query: "malformed" } },
      { name: "web_search", args: { op: "search", query: "empty" } },
      { name: "web_search", args: { op: "search", query: "partial", fetch: "top3" } },
    ]);
    expect(answers.map(answer => answer.isError)).toEqual([true, true, true, false, false]);
    const parsed = answers.map(answer => JSON.parse(answer.text));
    expect(parsed.map(value => value.status)).toEqual(["error", "error", "error", "empty", "partial"]);
    expect(parsed.slice(0, 3).map(value => value.reason)).toEqual(["http_error", "blocked", "parse_error"]);
    expect(parsed[0].providers).toContainEqual(expect.objectContaining({ sourceStatus: 404 }));
    expect(parsed[4].sources.some((source: { snippet: string }) => source.snippet.includes("Known fixture passage."))).toBe(true);
    for (const answer of answers) expect(Buffer.byteLength(answer.text)).toBeLessThanOrEqual(8192);
    recordCase("shared-source-failure-matrix", { outcomes: parsed });
  }, 120_000);

  it("shared web returns completed evidence by its deadline and discloses quota without redispatch", async () => {
    const { f, calls } = await sharedFixture("shared-deadline-quota");
    const start = Date.now();
    const [partial] = await toolAnswers(f, "bounded read expansion", [{ name: "web_search", args: { op: "search", query: "deadline", depth: "fast", fetch: "top3" } }]);
    const elapsed = Date.now() - start;
    expect(elapsed).toBeLessThan(4000);
    const bounded = JSON.parse(partial!.text);
    expect(bounded.status).toBe("partial"); expect(bounded.reason).toBe("timeout"); expect(partial!.isError).toBe(false);
    expect(bounded.sources.some((source: { freshness: string }) => source.freshness === "provider-cache-allowed")).toBe(true);
    const [quota, cooldown] = await toolAnswers(f, "report provider quota honestly", [
      { name: "web_search", args: { op: "search", query: "quota" } },
      { name: "web_search", args: { op: "search", query: "after-quota" } },
    ]);
    for (const result of [quota!, cooldown!]) { expect(result.isError).toBe(true); expect(JSON.parse(result.text).reason).toBe("rate_limited"); }
    expect(calls.filter(call => call.body.query === "quota")).toHaveLength(1);
    expect(calls.filter(call => call.body.query === "after-quota")).toHaveLength(0);
    recordCase("shared-deadline-quota", { elapsed, quota: JSON.parse(quota!.text), cooldown: JSON.parse(cooldown!.text) });
  }, 120_000);

  it("does not report HTTP 200 error pages as successful searches or readable articles", async () => {
    let requests = 0;
    const server = createServer((_request, response) => {
      requests += 1;
      response.writeHead(200, { "content-type": "text/html; charset=utf-8" });
      response.end("<html><head><title>Search temporarily unavailable</title></head><body><h1>Search temporarily unavailable</h1><p>Please try again later.</p></body></html>");
    });
    servers.push(server);
    await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
    const endpoint = `http://127.0.0.1:${(server.address() as AddressInfo).port}/`;
    const f = await fixture("soft-error", undefined, undefined, {
      // Keep the public-destination guard live; route only the transport to the
      // owned local socket, never to a provider or private destination.
      resolveHost: async () => [PUBLIC_ADDRESS],
      fetcher: (_input, init) => fetch(endpoint, init),
      providerFetcher: (_input, init) => fetch(endpoint, init),
    });
    const answers = await toolAnswers(f, "read the public fixture", [
      { name: "web_search", args: { op: "search", query: "public fixture" } },
      { name: "web_search", args: { op: "read", url: "https://example.org/article" } },
    ]);
    expect(requests).toBe(3);
    expect(refusals(f)).toEqual([]);
    recordCase("http-200-soft-error", { requests, answers });
    for (const answer of answers) {
      expect.soft(answer.isError, `${answer.toolName} must not convert upstream failure to absence or evidence`).toBe(true);
      expect.soft(answer.details?.status).not.toBe("ok");
    }
  }, 120_000);

  it("runs web, search, Knowledge and trusted-file tools inside Home activations with zero seam refusals", async () => {
    const f = await fixture("all-tools");

    // Profile remains active note storage. Source capture is no longer a tool.
    await f.store.createNote({ commandId: "seed-note-0001", record: {
      id: "profile-fixture", kind: "note", scope: "personal", provenance: { actor: "user", evidence: [] }, relations: [],
      content: { title: "Profile fixture note", body: "the profile fixture body", role: "fact", confirmed: true },
    } });

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
    const [search] = await toolAnswers(f, "search the web", [{ name: "web_search", args: { op: "search", query: "alpha beta" } }]);
    expect(search!.isError).toBe(false);
    expect(search!.details).toMatchObject({ status: "ok", requestId: expect.any(String) });
    expect(search!.text).toContain("Untrusted web content");
    expect(search!.text).toContain("Alpha & result");
    expect(search!.text).toContain("https://example.org/alpha");
    expect(search!.text).toContain("Second snippet");

    const [fetch] = await toolAnswers(f, "fetch the page", [{ name: "web_search", args: { op: "read", url: "https://example.org/page" } }]);
    expect(fetch!.details).toMatchObject({ status: "ok", requestId: expect.any(String) });
    expect(JSON.parse(fetch!.text).sources[0].title).toBe("Research Fixture Page");
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

    const [knowledge] = await toolAnswers(f, "what do we know", [{ name: "knowledge", args: { action: "read", id: "profile-fixture" } }]);
    expect(knowledge!.details).toEqual({ status: "ok" });
    expect(knowledge!.text).toContain("Profile fixture note");

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

    // F2: the complete shared-tool JSON, including citations and diagnostics,
    // stays inside the stronger UTF-8 byte cap and declares incomplete content.
    const [huge] = await toolAnswers(f, "fetch the huge page", [{ name: "web_search", args: { op: "read", url: "https://example.org/huge" } }]);
    expect(huge!.details).toMatchObject({ status: "partial" });
    expect(Buffer.byteLength(huge!.text, "utf8")).toBeLessThanOrEqual(8192);
    expect(JSON.parse(huge!.text).sources[0].truncated).toBe(true);

    // F5: private destinations are refused before any transport use.
    const fetchedBefore = f.fetchedUrls.length;
    const [local, privateHost, redirected] = await toolAnswers(f, "try unsafe fetches", [
      { name: "web_search", args: { op: "read", url: "http://127.0.0.1/secret" } },
      { name: "web_search", args: { op: "read", url: "https://private.internal/data" } },
      { name: "web_search", args: { op: "read", url: "https://example.org/redirect-private" } },
    ]);
    expect(local!.details).toMatchObject({ status: "error", reason: "blocked" });
    expect(privateHost!.details).toMatchObject({ status: "error", reason: "blocked" });
    expect(redirected!.details).toMatchObject({ status: "error", reason: "blocked" });
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
    expect((await f.store.list({ kind: "note" })).records.some(record => record.content.title === "evil")).toBe(false);

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
    expect(homeOwnerOf(f.registry).isHomeChapter(f.sessionId)).toBe(true);
    // A settled Home turn dirties the catalog too; it must not become a
    // spurious omission when coverage is recomputed on the next search.
    const refreshed = await f.search.search({ query: "HOME-NATIVE-HISTORY-ONLY" });
    expect(refreshed.results).toEqual([]);
    expect(refreshed.coverage).toMatchObject({ sessionsTotal: 0, sessionsIndexed: 0, omittedSessions: 0, state: "complete" });
    expect(refusals(f)).toEqual([]);
    await homeOwnerOf(f.registry).disable();
    expect(homeOwnerOf(f.registry).isHomeChapter(f.sessionId)).toBe(true);
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

  it("reads every exported source revision and citation through the existing Home file tool", async () => {
    const f = await fixture("plain-source-citation");
    const exported = join(f.project, "research");
    // Reuse the converter's sole synthetic persisted-store fixture, then invoke
    // its real CLI subprocess. No source bytes or conversion logic are copied.
    const fixtureScript = fileURLToPath(new URL("../../../../scripts/test-retire-knowledge.py", import.meta.url));
    await promisify(execFile)("python3", ["-c", [
      "import runpy,shutil,sys",
      "fixture=runpy.run_path(sys.argv[1])['Retirement']()",
      "fixture.setUp()",
      "try:",
      " fixture.run_command()",
      " shutil.copytree(fixture.files,sys.argv[2])",
      "finally: fixture.doCleanups()",
    ].join("\n"), fixtureScript, exported]);
    const manifest = JSON.parse(await readFile(join(exported, "MANIFEST.json"), "utf8"));
    expect(manifest.counts.sourceRevisions).toBe(2);
    for (const revision of ["source-rev-0", "source-rev-1"]) {
      const path = join(exported, "sources", "source", revision, "source.md");
      const original = await readFile(path, "utf8");
      const [answer] = await toolAnswers(f, "read the saved source with its original citation", [
        { name: "read_file", args: { path, offset: 1, limit: 1000 } },
      ]);
      expect(answer!.details).toEqual({ status: "ok" });
      for (const text of ["Café", "second line", "https://example.com/source", revision]) {
        expect(answer!.text).toContain(text);
      }
      expect(await readFile(path, "utf8")).toBe(original);
    }
    expect(refusals(f)).toEqual([]);
    recordCase("plain-source-citation", { revisions: 2, ordinaryFileTool: true, citationsRetained: true });
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
      await homeOwnerOf(f.registry).initialize();
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

  it("gives ordinary sessions shared web without Home-only research tools or modules", async () => {
    const f = await fixture("ordinary");
    const ordinary = await f.registry.create(f.project);
    await ordinary.setModel(PROVIDER, MODEL_ID);
    const context = await ordinary.context() as unknown as {
      availableTools: Array<{ name: string }>;
      extensions: Array<{ name: string }>;
    };
    const tools = context.availableTools.map((tool) => tool.name);
    // F6: web is shared, while Home-only research registrations stay in Home.
    // Ordinary sessions retain tron-core's full Knowledge tool.
    expect(tools).toContain("web_search");
    for (const name of ["web_fetch", "session_search", "session_read", "read_file"]) {
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
