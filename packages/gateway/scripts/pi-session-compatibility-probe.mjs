#!/usr/bin/env node
/**
 * Exercise Pi's public persistence APIs in an isolated directory. This file is
 * intentionally a subprocess worker; the rollback orchestrator supplies the
 * package root so no canonical user directory is ever consulted.
 *
 * Failure modes this probe exists to make visible (see check-pi-sdk-rollback.mjs
 * for the cross-version assertions):
 * - an MCP server name that round-trips through `mcp.json` as a different server
 *   (renamed, dropped, or refused), so the tools the user configured are gone;
 * - an MCP OAuth credential that the runtime that wrote it can still resolve and
 *   the next runtime cannot, so a Gateway rollback silently signs the user out.
 * Both are read back through Pi's own public entry (`pi mcp list --json`) so the
 * reported state is the running runtime's resolution, not this probe's guess.
 */
import { spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const MAX_RESULT_BYTES = 256 * 1024;
const [packageRoot, action, workRoot, mcpUrl] = process.argv.slice(2);
if (!packageRoot || !action || !workRoot || !mcpUrl || !["write", "read-append", "read"].includes(action)) throw new Error("usage: probe PACKAGE_ROOT ACTION WORK_ROOT MCP_FIXTURE_URL");
const pi = await import(pathToFileURL(join(packageRoot, "dist/index.js")).href);
const { SessionManager, SettingsManager, ModelRuntime } = pi;
const sessionDir = join(workRoot, "sessions");
const agentDir = join(workRoot, "agent");
const statePath = join(workRoot, "session-path.txt");
mkdirSync(sessionDir, { recursive: true }); mkdirSync(agentDir, { recursive: true });

function textMessages(context) {
  return context.messages.map((message) => ({ role: message.role, content: typeof message.content === "string" ? message.content : message.content?.map((part) => part.text ?? part.type).join("|") }));
}
function countBranches(nodes) {
  return nodes.reduce((count, node) => count + (node.children.length > 1 ? 1 : 0) + countBranches(node.children), 0);
}
function semantic(manager) {
  const entries = manager.getEntries();
  const indexes = new Map(entries.map((entry, index) => [entry.id, index]));
  return {
    entries: entries.map((entry, index) => {
      const copy = { ...entry };
      delete copy.id; delete copy.timestamp;
      copy.parent = entry.parentId === null ? null : indexes.get(entry.parentId);
      delete copy.parentId;
      if (copy.firstKeptEntryId) copy.firstKeptEntry = indexes.get(copy.firstKeptEntryId);
      delete copy.firstKeptEntryId;
      if (copy.targetId) copy.target = indexes.get(copy.targetId);
      delete copy.targetId;
      return copy;
    }),
    context: textMessages(manager.buildSessionContext()),
    treeBranches: countBranches(manager.getTree()),
    thinking: manager.getLeafEntry()?.type ?? null,
  };
}
function assertExpected(value, action) {
  const types = value.entries.map((entry) => entry.type);
  for (const required of ["message", "thinking_level_change", "model_change", "custom", "custom_message", "label", "compaction"]) {
    if (!types.includes(required)) throw new Error(`compatibility lost ${required} entry`);
  }
  if (!value.context.some((message) => message.content === "probe user")) throw new Error("user context was lost");
  if (!value.context.some((message) => message.content === "probe custom message")) throw new Error("custom message context was lost");
  if (!value.entries.some((entry) => entry.type === "model_change" && entry.provider === "fixture" && entry.modelId === "fixture-model")) throw new Error("model semantics were lost");
  if (!value.entries.some((entry) => entry.type === "thinking_level_change" && entry.thinkingLevel === "high")) throw new Error("thinking semantics were lost");
  if (!value.entries.some((entry) => entry.type === "label" && entry.label === "probe-label")) throw new Error("label semantics were lost");
  if (!value.entries.some((entry) => entry.type === "compaction" && entry.summary === "probe compaction")) throw new Error("compaction semantics were lost");
  if (!value.entries.some((entry) => entry.type === "custom" && entry.customType === "codemode-store" && entry.data?.script === "return 42")) throw new Error("codemode store state was lost");
  if (!value.entries.some((entry) => entry.type === "custom" && entry.customType === "virtual-model-state" && entry.data?.physicalModel === "fixture-physical")) throw new Error("virtual model state was lost");
  if (!value.entries.some((entry) => entry.type === "custom" && entry.customType === "tool-search-loadout" && entry.data?.added?.includes("fixture_tool"))) throw new Error("tool-search loadout delta was lost");
  const nested = value.entries.find((entry) => entry.type === "message" && entry.message?.role === "toolResult" && entry.message?.toolCallId === "rollback-parent")?.message;
  if (!nested?.nestedCalls?.calls?.some((call) => call.id === "nested-1" && call.name === "fixture_tool")) throw new Error("nestedCalls were lost");
  if (nested.content?.[0]?.text !== "parent result" || nested.structuredContent?.preserved !== true) throw new Error("parent result content was lost");
  if (nested.details?.tronNested?.complete !== true) throw new Error("nested details extension data was lost");
  if (value.treeBranches < 1) throw new Error("branch semantics were lost");
  if (!value.settingsAuth?.settings || !value.settingsAuth?.auth?.includes("openai")) throw new Error("settings/auth state was lost");
  if (action === "read" && !value.settingsAuth.auth.includes("anthropic")) throw new Error("appended auth state was lost");
}
const MCP_SERVER = "probe-mcp-server";
const MCP_ACCESS_TOKEN = "probe-mcp-access-token";
const mcpConfigPath = join(agentDir, "mcp.json");
const mcpAuthPath = join(agentDir, "mcp-auth.json");

function readJson(path) {
  try { return JSON.parse(readFileSync(path, "utf8")); } catch { return undefined; }
}

/** Seed the on-disk state a pre-upgrade Gateway leaves: one hyphenated server
 * with `direct` exposure, and its OAuth credential keyed the way the store
 * keyed credentials before server names entered the key. */
function writeMcpSeed() {
  writeFileSync(mcpConfigPath, `${JSON.stringify({ mcpServers: { [MCP_SERVER]: { url: mcpUrl, exposure: "direct" } } }, null, 2)}\n`);
  writeFileSync(mcpAuthPath, `${JSON.stringify({ [mcpUrl]: { clientInformation: { client_id: "probe-client", redirect_uris: ["http://127.0.0.1:1/callback"] }, tokens: { access_token: MCP_ACCESS_TOKEN, token_type: "Bearer", expires_in: 3600 }, tokensExpireAt: Date.now() + 3_600_000 } }, null, 2)}\n`);
}

/** What this runtime resolves from the seeded config and credential store.
 * `pi mcp list --json` exits 1 when a configured server is not connected, so a
 * non-zero exit is a reported state, not a probe failure. */
async function mcpState() {
  const cliPath = join(packageRoot, "dist/bundle/cli.js");
  const onDisk = { config: readJson(mcpConfigPath)?.mcpServers ?? {}, credentials: Object.keys(readJson(mcpAuthPath) ?? {}).sort() };
  if (typeof pi.createMcpExtension !== "function" || !existsSync(cliPath)) return { supported: false, ...onDisk };
  const child = spawn(process.execPath, [cliPath, "mcp", "list", "--json"], {
    cwd: workRoot, env: { ...process.env, PI_CODING_AGENT_DIR: agentDir }, stdio: ["ignore", "pipe", "pipe"],
  });
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (chunk) => { stdout += chunk; });
  child.stderr.on("data", (chunk) => { stderr += chunk; });
  const exitCode = await new Promise((resolve) => child.on("close", resolve));
  let listing;
  try { listing = JSON.parse(stdout); } catch { throw new Error(`MCP listing returned invalid JSON (exit ${exitCode}): ${stderr.trim() || stdout.trim()}`); }
  const servers = (listing.servers ?? []).map((server) => ({ name: server.name, enabled: server.enabled, exposure: server.exposure, transport: server.transport, state: server.state, tools: server.tools }))
    .sort((left, right) => left.name.localeCompare(right.name));
  return { supported: true, ...onDisk, servers, errors: listing.errors ?? [] };
}

async function settingsAndAuth(mode) {
  const settings = SettingsManager.create(workRoot, agentDir);
  const runtime = await ModelRuntime.create({ authPath: join(agentDir, "auth.json"), modelsPath: null, refreshOnCreate: false, allowModelNetwork: false });
  if (mode === "write") {
    settings.setDefaultProvider("fixture"); settings.setDefaultModel("fixture-model"); settings.setDefaultThinkingLevel("high");
    settings.setCompactionEnabled(true); settings.setRetryEnabled(true); settings.setTheme("light"); await settings.flush();
    await runtime.login("openai", "api_key", { signal: new AbortController().signal, prompt: async () => "dummy-openai-key" });
  } else {
    if (settings.getDefaultProvider() !== "fixture" || settings.getDefaultModel() !== "fixture-model" || settings.getDefaultThinkingLevel() !== "high") throw new Error("settings semantics were not readable");
    if (!settings.getCompactionEnabled() || !settings.getRetryEnabled()) throw new Error("settings behavior was not readable");
    if (mode === "read-append") {
      settings.setTheme("dark"); await settings.flush();
      await runtime.login("anthropic", "api_key", { signal: new AbortController().signal, prompt: async () => "dummy-anthropic-key" });
    } else if (settings.getTheme() !== "dark") throw new Error("settings append was not readable");
    const openai = await runtime.getAuth("openai");
    if (openai?.auth?.apiKey !== "dummy-openai-key") throw new Error("initial auth was not readable");
    if (mode !== "read-append") {
      const anthropic = await runtime.getAuth("anthropic");
      if (anthropic?.auth?.apiKey !== "dummy-anthropic-key") throw new Error("appended auth was not readable");
    }
  }
  const auth = (await runtime.listCredentials()).map((entry) => entry.providerId).sort();
  return { settings: { provider: settings.getDefaultProvider(), model: settings.getDefaultModel(), thinking: settings.getDefaultThinkingLevel(), compaction: settings.getCompactionEnabled(), retry: settings.getRetryEnabled(), theme: settings.getTheme() }, auth };
}
let manager;
let settingsAuth;
let mcp;
if (action === "write") {
  writeMcpSeed();
  manager = SessionManager.create(workRoot, sessionDir);
  const user = manager.appendMessage({ role: "user", content: "probe user", timestamp: 1 });
  manager.appendThinkingLevelChange("high"); manager.appendModelChange("fixture", "fixture-model");
  manager.appendCustomEntry("probe-custom", { stable: true });
  const customMessage = manager.appendCustomMessageEntry("probe-custom-message", "probe custom message", true, { stable: true });
  manager.appendMessage({ role: "assistant", content: [{ type: "text", text: "probe assistant" }], api: "fixture", provider: "fixture", model: "fixture-model", usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, stopReason: "stop", timestamp: 1 });
  manager.appendCustomEntry("codemode-store", { script: "return 42" });
  manager.appendCustomEntry("virtual-model-state", { selected: "fixture-virtual", physicalModel: "fixture-physical" });
  manager.appendModelChange("fixture", "fixture-virtual");
  manager.appendCustomEntry("tool-search-loadout", { added: ["fixture_tool"], removed: [] });
  manager.appendMessage({
    role: "toolResult", toolCallId: "rollback-parent", toolName: "codemode", isError: false,
    content: [{ type: "text", text: "parent result" }], structuredContent: { preserved: true },
    nestedCalls: { complete: true, calls: [{ id: "nested-1", name: "fixture_tool", args: {}, status: "completed", durationMs: 3 }] },
    details: { tronNested: { complete: true, display: [{ id: "fixture-artifact" }], browserLiveViews: [] } },
  });
  manager.appendLabelChange(user, "probe-label");
  manager.branch(customMessage);
  manager.appendMessage({ role: "assistant", content: [{ type: "text", text: "probe branch" }], api: "fixture", provider: "fixture", model: "fixture-model", usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, stopReason: "stop", timestamp: 1 });
  manager.appendCompaction("probe compaction", user, 10, { stable: true });
  settingsAuth = await settingsAndAuth("write");
  mcp = await mcpState();
  writeFileSync(statePath, manager.getSessionFile());
} else {
  const sessionPath = readFileSync(statePath, "utf8").trim();
  manager = SessionManager.open(sessionPath, sessionDir);
  const before = semantic(manager);
  settingsAuth = await settingsAndAuth(action);
  assertExpected({ ...before, settingsAuth }, action);
  mcp = await mcpState();
  if (action === "read-append") manager.appendCustomEntry("probe-after-read", { stable: true });
}
const result = { ...semantic(manager), settingsAuth, mcp };
const encoded = JSON.stringify(result);
if (Buffer.byteLength(encoded) > MAX_RESULT_BYTES) throw new Error("probe result exceeded bound");
process.stdout.write(`${encoded}\n`);
