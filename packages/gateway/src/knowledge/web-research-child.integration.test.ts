import { createServer } from "node:http";
import { mkdtemp, mkdir, rm, writeFile, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AddressInfo } from "node:net";
import { ModelRuntime, SessionManager } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall, getCurrentTools } from "@earendil-works/pi-ai";
import { expect, it } from "vitest";
import { createTestRegistry } from "../../test-support/gateway-registry.js";
import { waitFor } from "../../test-support/wait-for.js";
import { TrustService } from "../kernel/resources/trust-service.js";
import { ManagedSubagents } from "../kernel/delegation/managed-subagents.js";
import { delegatedArtifactRoot, delegatedProviderEnvironment, DELEGATED_PROVIDER_ROOT_ENV } from "../kernel/delegation/delegated-provider.js";
import type { RuntimeRegistry } from "../kernel/session/runtime-registry.js";

/** Real Gateway -> pinned role -> real Pi child -> shared socket -> local HTTP.
 * Only model responses and external endpoints are controlled. */
it("both pinned research roles call the same scoped web schema and reject Firecrawl source404", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-shared-web-child-"));
  const agentDir = join(root, "agent"); const cwd = join(root, "project"); const tronHome = join(root, "tron");
  const envKeys = ["PI_CODING_AGENT_DIR", DELEGATED_PROVIDER_ROOT_ENV, "PI_SUBAGENTS_PI_CODING_AGENT_PACKAGE_ROOT", "PI_SUBAGENT_CHILD"];
  const previous = new Map(envKeys.map(key => [key, process.env[key]]));
  let registry: RuntimeRegistry | undefined;
  let providerCalls = 0;
  const server = createServer((request, response) => {
    request.resume();
    if (request.url === "/origin") { response.writeHead(200, { "content-type": "text/html" }).end("<article><p>Origin fixture body.</p></article>"); return; }
    providerCalls++;
    response.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ success: true, data: { markdown: "# Not Found\nThe requested article does not exist.", metadata: { sourceURL: "https://example.org/missing", title: "Not Found", statusCode: 404 } } }));
  });
  const schemas: unknown[] = []; const childTools: string[][] = []; const observed: unknown[] = [];
  let passed = false;
  try {
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    process.env.PI_CODING_AGENT_DIR = agentDir; delete process.env.PI_SUBAGENT_CHILD;
    delegatedProviderEnvironment(delegatedArtifactRoot(tronHome));
    await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
    const endpoint = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
    const managedSubagents = ManagedSubagents.activateForStartup(tronHome);
    const faux = fauxProvider({ provider: "tron-web-child", models: [{ id: "fixture" }], tokensPerSecond: 1000000 });
    const runtime = await ModelRuntime.create({ authPath: join(root, "auth.json"), modelsPath: null, refreshOnCreate: false }); runtime.registerNativeProvider(faux.provider);
    const trust = new TrustService(agentDir); await trust.set(cwd, true);
    registry = await createTestRegistry({ agentDir, tronHome, trust, managedSubagents, modelRuntimeFactory: async () => runtime,
      idleRuntimeMs: 60000, broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
      homeWebTransport: { resolveHost: async () => ["93.184.216.34"], fetcher: (_input, init) => fetch(`${endpoint}/origin`, init), providerFetcher: (_input, init) => fetch(`${endpoint}/api`, init) },
    });
    await registry.initialize(); const slot = await registry.create(cwd); await slot.setModel("tron-web-child", "fixture");
    for (const agent of ["researcher", "evidence-auditor"]) {
      faux.setResponses([
        context => {
          schemas.push(getCurrentTools(context.messages).find(tool => tool.name === "web_search"));
          return fauxAssistantMessage(fauxToolCall("subagent", { agent, model: "tron-web-child/fixture", task: "Read https://example.org/missing and report the actual status. Do not write files.", async: false, acceptance: { level: "none", reason: "Read-only web contract regression" } }));
        },
        context => {
          const tools = getCurrentTools(context.messages); schemas.push(tools.find(tool => tool.name === "web_search")); childTools.push(tools.map(tool => tool.name));
          return fauxAssistantMessage(fauxToolCall("web_search", { op: "read", url: "https://example.org/missing" }));
        },
        context => {
          const result = context.messages.findLast(message => message.role === "toolResult");
          observed.push(result); return fauxAssistantMessage("CHILD_OBSERVED_404");
        },
        fauxAssistantMessage("PARENT_OBSERVED_CHILD"),
      ]);
      await slot.prompt(`Launch the ${agent} contract probe`);
      await waitFor(() => !slot.isBusy, "research child and parent settled");
    }
    expect(schemas).toHaveLength(4); expect(schemas[0]).toBeDefined();
    for (const schema of schemas) expect(schema).toEqual(schemas[0]);
    for (const tools of childTools) {
      expect(tools).toContain("web_search");
      for (const retired of ["fetch_content", "get_search_content", "source_check", "web_fetch"]) expect(tools).not.toContain(retired);
    }
    expect(observed).toHaveLength(2);
    for (const result of observed) expect(result).toMatchObject({ role: "toolResult", toolName: "web_search", isError: true, details: { status: "error", reason: "http_error" } });
    expect(providerCalls).toBe(2);
    const session = SessionManager.open(slot.sessionFile!);
    const launches = session.getEntries().filter(entry => entry.type === "message" && entry.message.role === "toolResult" && entry.message.toolName === "subagent");
    expect(launches).toHaveLength(2);
    for (const launch of launches) {
      expect(launch).toMatchObject({ message: { isError: false } });
      if (launch.type !== "message" || launch.message.role !== "toolResult") throw new Error("Missing launch receipt");
      const details = launch.message.details as { results: Array<{ sessionFile: string; exitCode: number }> };
      expect(details.results[0]?.exitCode).toBe(0);
      expect(await readFile(details.results[0]!.sessionFile, "utf8")).toContain("CHILD_OBSERVED_404");
    }
    passed = true;
  } finally {
    await registry?.dispose();
    await new Promise<void>(resolve => { server.close(() => resolve()); server.closeAllConnections(); });
    for (const [key, value] of previous) { if (value === undefined) delete process.env[key]; else process.env[key] = value; }
    await rm(root, { recursive: true, force: true });
    const output = join(process.cwd(), "test-results", "web-research-child"); await mkdir(output, { recursive: true });
    await writeFile(join(output, "report.json"), JSON.stringify({ passed, providerCalls, schemasEqual: schemas.length === 4 && schemas.every(schema => JSON.stringify(schema) === JSON.stringify(schemas[0])), childTools, observed }, null, 2));
  }
});
