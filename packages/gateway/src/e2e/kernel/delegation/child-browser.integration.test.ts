import { createServer } from "node:http";
import { mkdtemp, mkdir, rm, stat, writeFile, readFile } from "node:fs/promises";
import { join } from "node:path";
import type { AddressInfo } from "node:net";
import { ModelRuntime, SessionManager } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall, getCurrentTools } from "@earendil-works/pi-ai";
import { expect, it } from "vitest";
import { createTestRegistry } from "../../../../test-support/gateway-registry.js";
import { waitFor } from "../../../../test-support/wait-for.js";
import { TrustService } from "../../../kernel/resources/trust-service.js";
import { ManagedSubagents } from "../../../kernel/delegation/managed-subagents.js";
import { delegatedArtifactRoot, delegatedProviderEnvironment, DELEGATED_PROVIDER_ROOT_ENV } from "../../../kernel/delegation/delegated-provider.js";
import type { RuntimeRegistry } from "../../../kernel/session/runtime-registry.js";

const PACKAGE = "git:github.com/fitchmultz/pi-agent-browser-native@6346982c0fec9e00b9f3ef6997cfb2d6f6893c6d";

it("a subagent child gets the pinned managed browser and its owned launch from the Gateway, with no agent extension path", async () => {
  const root = await mkdtemp("/tmp/cb-");
  const agentDir = join(root, "agent"); const cwd = join(root, "project"); const tronHome = join(root, "tron");
  const envKeys = ["PI_CODING_AGENT_DIR", DELEGATED_PROVIDER_ROOT_ENV, "PI_SUBAGENTS_PI_CODING_AGENT_PACKAGE_ROOT", "PI_SUBAGENT_CHILD", "AGENT_BROWSER_SOCKET_DIR"];
  const previous = new Map(envKeys.map(key => [key, process.env[key]]));
  let registry: RuntimeRegistry | undefined;
  const site = createServer((_request, response) => { response.writeHead(200, { "content-type": "text/html" }).end("<title>child browser fixture</title><p>pinned</p>"); });
  const childTools: string[][] = []; const observed: unknown[] = [];
  try {
    await Promise.all([mkdir(agentDir), mkdir(join(cwd, ".pi", "agents"), { recursive: true }), mkdir(join(root, "sockets"))]);
    process.env.PI_CODING_AGENT_DIR = agentDir; process.env.AGENT_BROWSER_SOCKET_DIR = join(root, "sockets"); delete process.env.PI_SUBAGENT_CHILD;
    delegatedProviderEnvironment(delegatedArtifactRoot(tronHome));
    await new Promise<void>(resolve => site.listen(0, "127.0.0.1", resolve));
    const url = `http://127.0.0.1:${(site.address() as AddressInfo).port}/fixture`;
    await writeFile(join(agentDir, "settings.json"), JSON.stringify({ packages: [PACKAGE] }));
    await writeFile(join(cwd, ".pi", "agents", "browser-worker.md"), "---\nname: browser-worker\ndescription: Browser child probe\nmodel: tron-child-browser/fixture\ntools: agent_browser\ninheritProjectContext: false\n---\nUse the browser as asked.\n");
    const managedSubagents = ManagedSubagents.activateForStartup(tronHome);
    const faux = fauxProvider({ provider: "tron-child-browser", models: [{ id: "fixture" }], tokensPerSecond: 1000000 });
    const runtime = await ModelRuntime.create({ authPath: join(root, "auth.json"), modelsPath: null, refreshOnCreate: false }); runtime.registerNativeProvider(faux.provider);
    const trust = new TrustService(agentDir); await trust.set(cwd, true);
    registry = await createTestRegistry({ agentDir, tronHome, trust, managedSubagents, modelRuntimeFactory: async () => runtime,
      idleRuntimeMs: 60000, broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {} });
    await registry.initialize(); const slot = await registry.create(cwd); await slot.setModel("tron-child-browser", "fixture");
    faux.setResponses([
      () => fauxAssistantMessage(fauxToolCall("subagent", { agent: "browser-worker", task: "Open the fixture and read its title.", async: false, acceptance: { level: "none", reason: "Read-only child browser probe" } })),
      context => { childTools.push(getCurrentTools(context.messages).map(tool => tool.name)); return fauxAssistantMessage(fauxToolCall("agent_browser", { args: ["open", url] })); },
      context => { observed.push(context.messages.findLast(message => message.role === "toolResult")); return fauxAssistantMessage(fauxToolCall("agent_browser", { args: ["get", "title"] })); },
      context => { observed.push(context.messages.findLast(message => message.role === "toolResult")); return fauxAssistantMessage(fauxToolCall("agent_browser", { args: ["close"] })); },
      context => { observed.push(context.messages.findLast(message => message.role === "toolResult")); return fauxAssistantMessage("CHILD_BROWSER_DONE"); },
      fauxAssistantMessage("PARENT_DONE"),
    ]);
    await slot.prompt("Launch the browser child probe");
    await waitFor(() => !slot.isBusy, "browser child and parent settled");
    expect(childTools[0]).toContain("agent_browser");
    expect(observed).toHaveLength(3);
    for (const result of observed) expect(result).toMatchObject({ role: "toolResult", toolName: "agent_browser", isError: false });
    expect(JSON.stringify(observed[1])).toContain("child browser fixture");
    expect((await stat(join(agentDir, "browser", "profile.launches"))).isDirectory()).toBe(true);
    expect(JSON.stringify(observed)).not.toContain("unsupported");
    const launch = SessionManager.open(slot.sessionFile!).getEntries().find(entry => entry.type === "message" && entry.message.role === "toolResult" && entry.message.toolName === "subagent");
    if (launch?.type !== "message" || launch.message.role !== "toolResult") throw new Error("Missing launch receipt");
    expect(launch.message.isError).toBe(false);
    const details = launch.message.details as { results: Array<{ sessionFile: string; exitCode: number }> };
    expect(details.results[0]?.exitCode).toBe(0);
    expect(await readFile(details.results[0]!.sessionFile, "utf8")).toContain("CHILD_BROWSER_DONE");
  } finally {
    await registry?.dispose();
    await new Promise<void>(resolve => { site.close(() => resolve()); site.closeAllConnections(); });
    for (const [key, value] of previous) { if (value === undefined) delete process.env[key]; else process.env[key] = value; }
    await rm(root, { recursive: true, force: true });
  }
});
