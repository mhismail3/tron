/**
 * Records the persisted-state upgrade corpus (#471, layer L1).
 *
 * This is the generator. It drives the real Gateway — `RuntimeRegistry` with the
 * faux provider, Pi's own MCP fixture servers, Tron's `SettingsService`,
 * `AuthBroker` and `GatewayService` — under the **installed** Pi SDK and writes
 * a scrubbed, synthetic corpus into `test-fixtures/pi-sdk/corpus/`:
 *
 * - `agent/` — the canonical Pi agent directory (settings, provider
 *   credentials, MCP configuration and MCP OAuth credentials) plus the sessions
 *   the Gateway wrote, covering every shape this layer claims;
 * - `manifest.json` — the Tron-level observation of that corpus reopened from a
 *   staged copy, which `pi-persisted-state-corpus.integration.test.ts` compares
 *   against.
 *
 * The scenario is asserted against the recorded JSONL before anything is written
 * (`missingScenarioShapes`), so a recording that quietly lost a shape — a
 * codemode call JavaScript parses as a subtraction, a tool search that loads
 * nothing — fails instead of committing a corpus whose documented coverage is
 * false. The new corpus is built in a candidate directory and swapped into place
 * only once the manifest exists, so a failed regeneration leaves the committed
 * corpus untouched.
 *
 * Record with the **outgoing** SDK before an upgrade, so the upgrade is tested
 * against state the previous SDK actually wrote. Absolute host paths, the Node
 * installation, the fixture paths, the live MCP port and the extension owner ids
 * are stored as tokens; nothing else is rewritten, and the session files keep
 * Pi's own names and header ids.
 *
 * Run with `npm run record:pi-corpus` (see `packages/gateway/README.md`,
 * "Pi SDK maintenance"). It is not part of the default test run because it
 * rewrites committed fixtures.
 */
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
import { SettingsService } from "../../src/admin/settings-service.js";
import { TrustService } from "../../src/admin/trust-service.js";
import { UploadStore } from "../../src/machine/upload-store.js";
import type { JsonValue } from "../../src/protocol/types.js";
import { DeviceStore } from "../../src/security/device-store.js";
import { RuntimeRegistry } from "../../src/sessions/runtime-registry.js";
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
import { waitFor } from "../../test-support/wait-for.js";
import { SYNTHETIC_NATIVE_IMAGE } from "./computer-use-image.js";

const PACKAGE_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const REPOSITORY_ROOT = resolve(PACKAGE_ROOT, "../..");
const MCP_STDIO_FIXTURE = resolve(PACKAGE_ROOT, "test-fixtures/pi-sdk/mcp-jsonrpc-fixture.mjs");
const MCP_OAUTH_FIXTURE = resolve(PACKAGE_ROOT, "test-support/mcp-oauth-fixture.mjs");
/** The project extension that records a `context_edit` entry, which Tron never writes itself. */
const CONTEXT_EDIT_EXTENSION = `
export default function (pi) {
  pi.on("turn_end", (_event, ctx) => {
    const target = ctx.sessionManager.getBranch().find((entry) => entry.type === "message" && entry.message.role === "user");
    if (!target) return;
    return { entries: [{ type: "context_edit", targetId: target.id, replacement: { content: "corpus replacement request" } }] };
  });
}
`;

/** Device context a Gateway RPC caller needs; the same shape the MCP auth integration test uses. */
const CLIENT = {
  id: "corpus-device", identity: "device:corpus", isLocal: true,
  beginSynchronization: () => "sync", establishSynchronization: () => {}, completeSynchronization: () => {},
  setPresentationVisibility: () => ({ visible: true, revision: 0 }), unsubscribe: () => true,
  attachTerminal: () => {}, detachTerminal: () => {}, ownsTerminal: () => false,
  isSubscribed: () => true, isRevoked: () => false, revokeDevice: () => {},
} as never;

/**
 * Every value the committed corpus must not carry. `sessionTexts` supplies the
 * extension owner ids: Tron derives them as a sha256 of an extension's source and
 * resolved path (`owner-attribution.ts`), so each recording would otherwise embed
 * a host-path fingerprint that nothing can reproduce or rebind.
 */
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
  // Longest first: a token must not eat a longer path that contains it.
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
    // Real paths only: macOS resolves `/var` to `/private/var`, and Pi records
    // the resolved session cwd, so an unresolved root would leave a stray
    // prefix in the scrubbed corpus.
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

      // The agent directory's own owners write the settings and the provider
      // credential: `settings.json` through Tron's SettingsService (which
      // validates the model against the SDK catalog) and `auth.json` through the
      // Gateway's AuthBroker, exactly as a device sign-in does.
      const settingsRuntime = await modelRuntimeFactory();
      await new SettingsService(agentDir, settingsRuntime).update({
        sessionDir,
        defaultModel: { provider: CORPUS_AZURE_PROVIDER, id: CORPUS_AZURE_MODEL },
        defaultThinkingLevel: "medium",
        thinkingBudgets: { minimal: 512, high: 8_192 },
        defaultTools: ["read", "edit", "write", "bash", "+codemode", "+tool_search"],
        enabledModels: [`${CORPUS_AZURE_PROVIDER}/${CORPUS_AZURE_MODEL}`, `${CORPUS_FAUX_PROVIDER}/${CORPUS_FAUX_MODEL}`],
        // A corpus-sized session must still be compactable: the retained tail is
        // tiny, so one manual compaction records a real `compaction` entry.
        compaction: { enabled: true, reserveTokens: 4_096, keepRecentTokens: 100 },
        // Scoped built-in extension settings: the form Tron persists for the shared built-in list.
        extensions: ["-builtin:llama.cpp"],
      }, { cwd, scope: "global", projectTrusted: false });
      const authEvents: Array<{ topic: string; payload: Record<string, unknown> }> = [];
      const auth = new AuthBroker(settingsRuntime, (_clientId: string, topic: string, payload: JsonValue) => {
        authEvents.push({ topic, payload: payload as Record<string, unknown> });
      });
      const admission = auth.start("corpus-device", CORPUS_AZURE_PROVIDER, "api_key", settingsRuntime, "device:corpus", "corpus-azure-command-0001");
      const keyPrompt = await waitFor(() => authEvents.find((event) => event.topic === "auth.prompt"
        && typeof event.payload.promptId === "string"), "the provider key prompt");
      auth.respond("device:corpus", admission.operationId, keyPrompt.payload.promptId as string, CORPUS_AZURE_API_KEY);
      await waitFor(() => authEvents.some((event) => event.topic === "auth.completed"), "the provider key to be stored");

      const registry = new RuntimeRegistry({
        agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 600_000, modelRuntimeFactory, trust,
        // Pi's built-in MCP sign-in relays its authorization URL to the Tron
        // operation that started it; this is the hook the Gateway installs.
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

      // Sign in to the OAuth-protected server through the real RPC route, so
      // Pi's own credential store records the credential the corpus reopens
      // with. `corpus-oauth` is hyphenated and its tool is deferred, so the
      // recorded state covers the rename on a server reached through tool
      // search rather than a directly declared one.
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
      // Deferred exposure means the tool is registered but not declared, so the
      // sign-in is proven by the server answering `tools/list`, not by an active tool.
      await waitFor(async () => ((await rich.context()) as { availableTools: Array<{ name: string }> }).availableTools
        .some((tool) => tool.name === oauthTool), "the OAuth-protected MCP tool after sign-in");

      // The per-chat tool selection: a default tool disabled, and the directly
      // declared MCP tool enabled. This is the loadout the transcript declares,
      // which is what a chat's "Available Tools" choice becomes on disk (#327).
      // The deferred server's tool is deliberately not selected: the corpus
      // records it arriving later, through tool search.
      const defaults = ((await rich.context()) as { activeTools: string[] }).activeTools;
      const chosen = [
        ...defaults.filter((name) => name !== "write" && !name.startsWith("mcp__")),
        stdioTool,
      ].sort();
      await rich.setTools(chosen);
      faux.setResponses([
        fauxAssistantMessage([
          fauxToolCall(stdioTool, { value: "direct" }, { id: "corpus-mcp-direct" }),
          // The deferred server's tool is not declared, so the model has to find
          // it; loading it persists the tool-search loadout delta.
          fauxToolCall("tool_search", { query: "OAuth-protected echo fixture" }, { id: "corpus-tool-search" }),
          // Codemode exposes nested tools as normalized JavaScript identifiers,
          // where `-` becomes `_`: `tools.mcp__corpus_mcp__echo`, not the tool's
          // own name (which JavaScript would read as a subtraction).
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
      // The transcript's last model change names the provider key and model
      // whose synthetic credential `auth.json` holds, so reopening restores
      // the saved selection instead of falling back to a default.
      await rich.setModel(CORPUS_AZURE_PROVIDER, CORPUS_AZURE_MODEL);
      // `availableTools` is prompt-specific and does not necessarily include
      // every exposure the scenario exercised. Persist the fixture-declared tool
      // names so reopen must prove both MCP servers resolve them.
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
      // Reopening it proves the persisted selection resolves without the
      // scenario provider the recording streamed with.
      await providerKey.setModel(CORPUS_AZURE_PROVIDER, CORPUS_AZURE_MODEL);
      const providerKeyFile = providerKey.sessionFile!;
      await registry.dispose();
      registries.splice(registries.indexOf(registry), 1);

      // Pi's own canonical writer adds the sibling branch Tron never writes:
      // Tron's branch route forks a new session, so a branched tree is recorded
      // here through the SDK that owns the JSONL format. The branch point is the
      // parent of the last entry, so the branch keeps every recorded row on the
      // leaf's path and the answer is attributed to the session's current model.
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

      // The scenario is asserted before anything is written: a recording that
      // quietly lost a shape (a codemode call that parsed as a subtraction, a
      // tool search that loaded nothing) must fail here rather than commit a
      // corpus whose documented coverage is false.
      const richEntries = await readSessionEntries(richFile);
      const missing = missingScenarioShapes(scenarioShapes(richEntries));
      if (missing.length > 0) throw new Error(`the recorded scenario is missing: ${missing.join(", ")}`);

      // Write a candidate corpus first: the agent-directory stores, the MCP
      // configuration and credential, and the canonical session files, with
      // every environment value tokenized. It is swapped into place only after
      // the manifest is recorded, so a failed regeneration leaves the committed
      // corpus untouched.
      const candidateDir = join(root, "corpus-candidate");
      const candidateAgentDir = join(candidateDir, "agent");
      const sessionTexts = await Promise.all([richFile, providerKeyFile].map((file) => readFile(file, "utf8")));
      const replacements = scrubReplacements(root, mcpUrl, sessionTexts);
      await mkdir(join(candidateAgentDir, CORPUS_SESSIONS_DIR_NAME), { recursive: true });
      for (const name of ["settings.json", "auth.json", "mcp.json", "mcp-auth.json"]) {
        const contents = scrub(await readFile(join(agentDir, name), "utf8"), replacements);
        await writeFile(join(candidateAgentDir, name), `${JSON.stringify(JSON.parse(contents), null, 2)}\n`);
      }
      // Pi's own session file name and header id are kept: the corpus must be
      // the state the SDK wrote, not a renamed copy an SDK that validated
      // identity shape would reject.
      const sessionIds: string[] = [];
      for (const file of [richFile, providerKeyFile]) {
        const target = join(candidateAgentDir, CORPUS_SESSIONS_DIR_NAME, basename(file));
        await writeFile(target, scrub(await readFile(file, "utf8"), replacements));
        sessionIds.push(canonicalSessionId(target, await readSessionEntries(target)));
      }
      expect((await readdir(candidateAgentDir)).sort())
        .toEqual(["auth.json", "mcp-auth.json", "mcp.json", "sessions", "settings.json"]);

      // Record the manifest from a staged copy, so the recorded values and the
      // values the test observes are produced by the same code over the same
      // corpus content.
      const staged = await stageCorpus({
        root: stagedRoot, corpusDir: candidateDir, mcpUrl, mcpFixture: MCP_STDIO_FIXTURE, nodeExecutable: process.execPath,
      });
      const stagedTrust = new TrustService(staged.agentDir);
      await stagedTrust.set(staged.cwd, true);
      const stagedRegistry = new RuntimeRegistry({
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
      // Only the saved provider key is observed: the faux provider is the
      // recording harness, not persisted user state.
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
      // Swap the candidate into the committed corpus only now that both halves
      // of it exist.
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
