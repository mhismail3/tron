import { createTestRegistry } from "../../test-support/gateway-registry.js";
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { cp, mkdir, mkdtemp, readFile, readdir, realpath, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { fauxAssistantMessage, fauxToolCall } from "@earendil-works/pi-ai";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { describe, expect, it } from "vitest";
import { AuthBroker } from "../../src/admin/auth-broker.js";
import { TrustService } from "../../src/kernel/resources/trust-service.js";
import { UploadStore } from "../../src/machine/upload-store.js";
import type { JsonValue } from "../../src/protocol/types.js";
import { DeviceStore } from "../../src/security/device-store.js";
import { RuntimeRegistry } from "../../src/kernel/session/runtime-registry.js";
import { CommandReceiptStore } from "../../src/transport/command-receipts.js";
import { GatewayService, type GatewayServiceDependencies } from "../../src/transport/gateway-service.js";
import {
  CORPUS_AGENT_DIR,
  CORPUS_AZURE_API_KEY,
  CORPUS_AZURE_MODEL,
  CORPUS_AZURE_PROVIDER,
  CORPUS_FAUX_MODEL,
  CORPUS_FAUX_MODEL_ALT,
  CORPUS_FAUX_PROVIDER,
  CORPUS_MANIFEST_PATH,
  CORPUS_MCP_SERVERS,
  CORPUS_MCP_STATE_FILE,
  CORPUS_SESSIONS_DIR_NAME,
  CORPUS_STDIO_TOOLS,
  CORPUS_TOKENS,
  corpusFauxProvider,
  corpusModelRuntime,
  missingScenarioShapes,
  normalizeObservation,
  observeProviders,
  observeSessions,
  readSessionEntries,
  scenarioShapes,
  waitForRecordedServerTools,
  stageCorpus,
  type CorpusObservation,
  type CorpusServerObservation,
} from "../../test-support/pi-persisted-state-corpus.js";
import { settingsDependencies } from "../../test-support/settings-dependencies.js";
import { waitFor } from "../../test-support/wait-for.js";
import { SYNTHETIC_NATIVE_IMAGE } from "./computer-use-image.js";

const PACKAGE_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const REPOSITORY_ROOT = resolve(PACKAGE_ROOT, "../..");
const MCP_STDIO_FIXTURE = resolve(PACKAGE_ROOT, "test-fixtures/pi-sdk/mcp-jsonrpc-fixture.mjs");
const MCP_OAUTH_FIXTURE = resolve(PACKAGE_ROOT, "test-support/mcp-oauth-fixture.mjs");
const CONTEXT_EDIT_EXTENSION = `
export default function (pi) {
  pi.on("turn_end", (_event, ctx) => {
    const target = ctx.sessionManager.getBranch().find((entry) => entry.type === "message" && entry.message.role === "user");
    if (!target) return;
    return { entries: [{ type: "context_edit", targetId: target.id, replacement: { content: "corpus replacement request" } }] };
  });
}
`;

const CLIENT = {
  id: "corpus-device", identity: "device:corpus", isLocal: true,
  beginSynchronization: () => "sync", establishSynchronization: () => {}, completeSynchronization: () => {},
  setPresentationVisibility: () => ({ visible: true, revision: 0 }), unsubscribe: () => true,

  isSubscribed: () => true, isRevoked: () => false, revokeDevice: () => {},
} as never;

function scrubReplacements(root: string, mcpUrl: string, sessionTexts: readonly string[]): Array<readonly [string, string]> {
  const owners = new Map<string, string>();
  for (const text of sessionTexts) {
    for (const match of text.matchAll(/extension:[A-Za-z0-9_-]{40,}/gu)) {
      if (!owners.has(match[0])) owners.set(match[0], `extension:corpus-synthetic-owner-${owners.size + 1}`);
    }
  }
  const replacements: Array<readonly [string, string]> = [
    [join(root, "workspace"), CORPUS_TOKENS.workspace],
    [join(root, "agent"), CORPUS_TOKENS.agent],
    [join(root, "sessions"), CORPUS_TOKENS.sessions],
    [join(root, CORPUS_MCP_STATE_FILE), `${CORPUS_TOKENS.root}/${CORPUS_MCP_STATE_FILE}`],
    [mcpUrl, CORPUS_TOKENS.mcpUrl],
    [new URL(mcpUrl).origin, CORPUS_TOKENS.mcpOrigin],
    [MCP_STDIO_FIXTURE, CORPUS_TOKENS.fixture],
    [MCP_OAUTH_FIXTURE, CORPUS_TOKENS.fixture],
    [process.execPath, CORPUS_TOKENS.node],
    [REPOSITORY_ROOT, CORPUS_TOKENS.repo],
    [root, CORPUS_TOKENS.root],
  ];
  for (const [from, to] of owners) replacements.push([from, to]);
  return replacements.sort((left, right) => right[0].length - left[0].length);
}

function scrub(text: string, replacements: ReadonlyArray<readonly [string, string]>): string {
  let result = text;
  for (const [from, to] of replacements) result = result.split(from).join(to);
  return result;
}

function canonicalSessionId(path: string, entries: ReadonlyArray<Record<string, unknown>>): string {
  const id = entries.find((entry) => entry.type === "session")?.id;
  if (typeof id !== "string" || !id) throw new Error(`${path} has no canonical session id`);
  return id;
}

function piSdkVersion(manifest: { dependencies?: Record<string, string> }): string {
  const version = manifest.dependencies?.["@earendil-works/pi-coding-agent"];
  if (!version) throw new Error("packages/gateway/package.json is not the Pi SDK version authority");
  return version;
}

describe("persisted-state upgrade corpus recorder", () => {
  it("writes the corpus and its manifest with the installed Pi SDK", async () => {
    const root = await realpath(await mkdtemp(join(tmpdir(), "tron-corpus-record-")));
    const stagedRoot = await realpath(await mkdtemp(join(tmpdir(), "tron-corpus-stage-")));
    const agentDir = join(root, "agent");
    const sessionDir = join(root, "sessions");
    const cwd = join(root, "workspace");
    const oauthPortFile = join(root, "oauth.port");
    await Promise.all([
      mkdir(agentDir, { recursive: true }),
      mkdir(sessionDir, { recursive: true }),
      mkdir(join(cwd, ".pi", "extensions"), { recursive: true }),
      writeFile(join(root, CORPUS_MCP_STATE_FILE), JSON.stringify({ tools: CORPUS_STDIO_TOOLS })),
    ]);
    await writeFile(join(cwd, ".pi", "extensions", "corpus-context-edit.ts"), CONTEXT_EDIT_EXTENSION);
    const oauthServer = spawn(process.execPath, [MCP_OAUTH_FIXTURE, oauthPortFile], { stdio: "ignore" });
    const registries: RuntimeRegistry[] = [];
    const priorAgentDir = process.env.PI_CODING_AGENT_DIR;
    try {
      await waitFor(() => existsSync(oauthPortFile), "the MCP OAuth fixture to bind a port");
      const mcpUrl = `http://127.0.0.1:${Number(await readFile(oauthPortFile, "utf8"))}/mcp`;
      await writeFile(join(agentDir, "mcp.json"), JSON.stringify({ mcpServers: {
        "corpus-mcp": { command: process.execPath, args: [MCP_STDIO_FIXTURE, "stdio", join(root, CORPUS_MCP_STATE_FILE)], exposure: "direct" },
        "corpus-oauth": { url: mcpUrl, exposure: "deferred" },
      } }, null, 2));
      process.env.PI_CODING_AGENT_DIR = agentDir;
      const trust = new TrustService(agentDir);
      await trust.set(cwd, true);
      const faux = corpusFauxProvider();
      const modelRuntimeFactory = () => corpusModelRuntime(agentDir, faux);

      const settingsRuntime = await modelRuntimeFactory();
      const existing = JSON.parse(await readFile(join(agentDir, "settings.json"), "utf8").catch(() => "{}")) as Record<string, unknown>;
      await writeFile(join(agentDir, "settings.json"), JSON.stringify({ ...existing, sessionDir }));
      const mac = (key: string, value: unknown) => ({ key, layer: "global" as const, op: "set" as const, value });
      await settingsDependencies({ agentDir, tronHome: join(root, "tron"), trust, modelRuntime: settingsRuntime }).settingsChanges.change({ kind: "global" }, [
        mac("model.ref[role=chat]", { provider: CORPUS_AZURE_PROVIDER, id: CORPUS_AZURE_MODEL }),
        mac("model.thinking[role=chat]", "medium"),
        mac("model.thinkingBudgets", { minimal: 512, high: 8_192 }),
        mac("tools.active", ["read", "edit", "write", "bash", "+codemode", "+tool_search"]),
        mac("model.offered", [`${CORPUS_AZURE_PROVIDER}/${CORPUS_AZURE_MODEL}`, `${CORPUS_FAUX_PROVIDER}/${CORPUS_FAUX_MODEL}`]),
        mac("context.compaction.enabled", true),
        mac("context.compaction.reserveTokens", 4_096),
        mac("context.compaction.keepRecentTokens", 100),
        mac("sources.extensions", ["-builtin:llama.cpp"]),
      ], { actor: { kind: "ui", id: "corpus-device" } });
      const authEvents: Array<{ topic: string; payload: Record<string, unknown> }> = [];
      const auth = new AuthBroker(settingsRuntime, (_clientId: string, topic: string, payload: JsonValue) => {
        authEvents.push({ topic, payload: payload as Record<string, unknown> });
      });
      const admission = auth.start("corpus-device", CORPUS_AZURE_PROVIDER, "api_key", settingsRuntime, "device:corpus", "corpus-azure-command-0001");
      const keyPrompt = await waitFor(() => authEvents.find((event) => event.topic === "auth.prompt"
        && typeof event.payload.promptId === "string"), "the provider key prompt");
      auth.respond("device:corpus", admission.operationId, keyPrompt.payload.promptId as string, CORPUS_AZURE_API_KEY);
      await waitFor(() => authEvents.some((event) => event.topic === "auth.completed"), "the provider key to be stored");

      const registry = await createTestRegistry({
        agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 600_000, modelRuntimeFactory, trust,
        mcpAuth: { openUrl: (operationId, url, targetSession, server) => auth.openMcpAuthorizationUrl(operationId, url, targetSession, server) },
        broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
      });
      registries.push(registry);
      await registry.initialize();
      const devices = new DeviceStore(join(root, "gateway"), "machine");
      await devices.initialize();
      const service = new GatewayService({
        config: { tronHome: root }, sessions: registry, devices, auth,
        receipts: new CommandReceiptStore(root), uploads: new UploadStore(root, 1024), broadcast: () => {},
        requestRestart: () => {}, sessionDeleted: () => {},
      } as unknown as GatewayServiceDependencies);

      const rich = await registry.create(cwd);
      await rich.setModel(CORPUS_FAUX_PROVIDER, CORPUS_FAUX_MODEL_ALT);
      await rich.setModel(CORPUS_FAUX_PROVIDER, CORPUS_FAUX_MODEL);
      await rich.setThinking("high");
      const stdioTool = `mcp__${CORPUS_MCP_SERVERS[0]!.replaceAll("-", "_")}__echo`;
      const oauthTool = `mcp__${CORPUS_MCP_SERVERS[1]!.replaceAll("-", "_")}__echo`;
      await waitFor(async () => ((await rich.context()) as { availableTools: Array<{ name: string }> }).availableTools
        .some((tool) => tool.name === stdioTool), "the stdio MCP tool");

      faux.setResponses([fauxAssistantMessage("corpus MCP sign-in handled")]);
      await service.invoke(CLIENT, "mcp.auth.start", {
        sessionId: rich.id, server: CORPUS_MCP_SERVERS[1], commandId: "corpus-mcp-signin-0001",
      });
      const urlEvent = await waitFor(() => authEvents.find((event) => event.topic === "auth.event"
        && (event.payload.event as { type?: string } | undefined)?.type === "auth_url"), "the MCP authorization URL");
      const authorized = await fetch((urlEvent.payload.event as { url: string }).url, { redirect: "manual" });
      const callback = new URL(authorized.headers.get("location")!);
      await service.invoke(CLIENT, "auth.callback", {
        operationId: urlEvent.payload.operationId as string,
        callbackId: (urlEvent.payload.callbackCapture as { id: string }).id,
        query: callback.search.slice(1),
      });
      await waitFor(() => authEvents.some((event) => event.topic === "auth.completed"), "the MCP sign-in to complete");
      await waitFor(async () => ((await rich.context()) as { availableTools: Array<{ name: string }> }).availableTools
        .some((tool) => tool.name === oauthTool), "the OAuth-protected MCP tool after sign-in");

      const defaults = ((await rich.context()) as { activeTools: string[] }).activeTools;
      const chosen = [
        ...defaults.filter((name) => name !== "write" && !name.startsWith("mcp__")),
        stdioTool,
      ].sort();
      await rich.setTools(chosen);
      faux.setResponses([
        fauxAssistantMessage([
          fauxToolCall(stdioTool, { value: "direct" }, { id: "corpus-mcp-direct" }),
          fauxToolCall("tool_search", { query: "OAuth-protected echo fixture" }, { id: "corpus-tool-search" }),
          fauxToolCall("codemode", { code: `return text(await tools.mcp__${CORPUS_MCP_SERVERS[0].replaceAll("-", "_")}__echo({ value: "nested" }));` }, { id: "corpus-codemode" }),
        ], { stopReason: "toolUse" }),
        fauxAssistantMessage("corpus turn one complete"),
        fauxAssistantMessage([fauxToolCall(oauthTool, { value: "searched" }, { id: "corpus-mcp-oauth" })], { stopReason: "toolUse" }),
        fauxAssistantMessage("corpus turn two complete"),
        fauxAssistantMessage("corpus compaction summary"),
      ]);
      await rich.prompt("corpus turn one: MCP tools and an image", [SYNTHETIC_NATIVE_IMAGE]);
      await waitFor(() => !rich.isBusy, "the first corpus turn to settle");
      await rich.prompt("corpus turn two: the tool that tool search loaded");
      await waitFor(() => !rich.isBusy, "the second corpus turn to settle");
      await rich.compact("Corpus compaction summary");
      await waitFor(() => rich.snapshot().phase === "idle", "the corpus compaction to settle");
      await rich.setModel(CORPUS_AZURE_PROVIDER, CORPUS_AZURE_MODEL);
      const servers: CorpusServerObservation[] = CORPUS_MCP_SERVERS.map((name) => ({
        name,
        tools: CORPUS_STDIO_TOOLS.map((tool) => `mcp__${name.replaceAll("-", "_")}__${tool.name}`).sort(),
      }));
      const richFile = rich.sessionFile!;

      const providerKey = await registry.create(cwd);
      await providerKey.setModel(CORPUS_FAUX_PROVIDER, CORPUS_FAUX_MODEL);
      faux.setResponses([fauxAssistantMessage("corpus provider key turn complete")]);
      await providerKey.prompt("corpus turn: the saved provider key session");
      await waitFor(() => !providerKey.isBusy, "the provider key turn to settle");
      await providerKey.setModel(CORPUS_AZURE_PROVIDER, CORPUS_AZURE_MODEL);
      const providerKeyFile = providerKey.sessionFile!;
      await registry.dispose();
      registries.splice(registries.indexOf(registry), 1);

      const manager = SessionManager.open(richFile, sessionDir);
      const branch = manager.getBranch();
      const branchPoint = branch.at(-2);
      if (!branchPoint) throw new Error("the corpus session recorded no entry to branch from");
      manager.branch(branchPoint.id);
      manager.appendMessage({
        ...fauxAssistantMessage("corpus branch answer"),
        provider: CORPUS_AZURE_PROVIDER,
        model: CORPUS_AZURE_MODEL,
      });

      const richEntries = await readSessionEntries(richFile);
      const missing = missingScenarioShapes(scenarioShapes(richEntries));
      if (missing.length > 0) throw new Error(`the recorded scenario is missing: ${missing.join(", ")}`);

      const candidateDir = join(root, "corpus-candidate");
      const candidateAgentDir = join(candidateDir, "agent");
      const sessionTexts = await Promise.all([richFile, providerKeyFile].map((file) => readFile(file, "utf8")));
      const replacements = scrubReplacements(root, mcpUrl, sessionTexts);
      await mkdir(join(candidateAgentDir, CORPUS_SESSIONS_DIR_NAME), { recursive: true });
      for (const name of ["settings.json", "auth.json", "mcp.json", "mcp-auth.json"]) {
        const contents = scrub(await readFile(join(agentDir, name), "utf8"), replacements);
        await writeFile(join(candidateAgentDir, name), `${JSON.stringify(JSON.parse(contents), null, 2)}\n`);
      }
      const sessionIds: string[] = [];
      for (const file of [richFile, providerKeyFile]) {
        const target = join(candidateAgentDir, CORPUS_SESSIONS_DIR_NAME, basename(file));
        await writeFile(target, scrub(await readFile(file, "utf8"), replacements));
        sessionIds.push(canonicalSessionId(target, await readSessionEntries(target)));
      }
      expect((await readdir(candidateAgentDir)).sort())
        .toEqual(["auth.json", "mcp-auth.json", "mcp.json", "sessions", "settings.json"]);

      const staged = await stageCorpus({
        root: stagedRoot, corpusDir: candidateDir, mcpUrl, mcpFixture: MCP_STDIO_FIXTURE, nodeExecutable: process.execPath,
      });
      const stagedTrust = new TrustService(staged.agentDir);
      await stagedTrust.set(staged.cwd, true);
      const stagedRegistry = await createTestRegistry({
        agentDir: staged.agentDir, tronHome: join(stagedRoot, "tron"), idleRuntimeMs: 600_000, modelRuntimeFactory,
        trust: stagedTrust, broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
      });
      registries.push(stagedRegistry);
      await stagedRegistry.initialize();
      await waitFor(() => (stagedRegistry as unknown as { sessionCatalog: { hasCompleteCut(): boolean } }).sessionCatalog.hasCompleteCut(),
        "the staged catalog's complete cut");
      await stagedRegistry.catalog("all");
      await waitForRecordedServerTools(stagedRegistry, sessionIds, servers);
      const sessions = await observeSessions({ registry: stagedRegistry, sessionIds, servers });
      const providers = await observeProviders(await modelRuntimeFactory(), [
        { provider: CORPUS_AZURE_PROVIDER, model: { provider: CORPUS_AZURE_PROVIDER, id: CORPUS_AZURE_MODEL } },
      ]);
      const manifest: CorpusObservation = {
        recordedWith: piSdkVersion(JSON.parse(await readFile(join(PACKAGE_ROOT, "package.json"), "utf8"))),
        ...normalizeObservation({ ...sessions, providers }, staged),
      };
      await writeFile(join(candidateDir, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`);
      await stagedRegistry.dispose();
      registries.splice(registries.indexOf(stagedRegistry), 1);
      await rm(CORPUS_AGENT_DIR, { recursive: true, force: true });
      await rm(CORPUS_MANIFEST_PATH, { force: true });
      await cp(candidateAgentDir, CORPUS_AGENT_DIR, { recursive: true });
      await cp(join(candidateDir, "manifest.json"), CORPUS_MANIFEST_PATH);
      process.stdout.write(`\nRecorded the persisted-state corpus with Pi SDK ${manifest.recordedWith}\n`
        + `  sessions: ${manifest.sessions.map((session) => `${session.sessionId} (${session.projection.length} items, ${session.model?.provider}/${session.model?.id}, ${session.activeTools.length} active tools)`).join("; ")}\n`
        + `  servers: ${manifest.servers.map((server) => `${server.name} -> ${server.tools.join(", ") || "none"}`).join("; ")}\n`
        + `  providers: ${manifest.providers.map((provider) => `${provider.provider}${provider.storedCredential ? " (saved credential)" : " (no saved credential)"}`).join(", ")}\n`);
    } finally {
      for (const registry of registries) await registry.dispose().catch(() => {});
      if (priorAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
      else process.env.PI_CODING_AGENT_DIR = priorAgentDir;
      if (oauthServer.exitCode === null && oauthServer.signalCode === null) {
        const exited = new Promise<void>((resolve) => oauthServer.once("exit", () => resolve()));
        oauthServer.kill("SIGTERM");
        await exited;
      }
      await Promise.all([rm(root, { recursive: true, force: true }), rm(stagedRoot, { recursive: true, force: true })]);
    }
  }, 180_000);
});
