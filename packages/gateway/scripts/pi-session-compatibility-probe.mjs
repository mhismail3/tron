#!/usr/bin/env node
/**
 * Exercise Pi's public persistence APIs in an isolated directory. This file is
 * intentionally a subprocess worker; the rollback orchestrator supplies the
 * package root so no canonical user directory is ever consulted.
 */
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const MAX_RESULT_BYTES = 256 * 1024;
const [packageRoot, action, workRoot] = process.argv.slice(2);
if (!packageRoot || !action || !workRoot || !["write", "read-append", "read"].includes(action)) throw new Error("usage: probe PACKAGE_ROOT ACTION WORK_ROOT");
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
  if (value.treeBranches < 1) throw new Error("branch semantics were lost");
  if (!value.settingsAuth?.settings || !value.settingsAuth?.auth?.includes("openai")) throw new Error("settings/auth state was lost");
  if (action === "read" && !value.settingsAuth.auth.includes("anthropic")) throw new Error("appended auth state was lost");
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
if (action === "write") {
  manager = SessionManager.create(workRoot, sessionDir);
  const user = manager.appendMessage({ role: "user", content: "probe user", timestamp: 1 });
  manager.appendThinkingLevelChange("high"); manager.appendModelChange("fixture", "fixture-model");
  manager.appendCustomEntry("probe-custom", { stable: true });
  const customMessage = manager.appendCustomMessageEntry("probe-custom-message", "probe custom message", true, { stable: true });
  manager.appendMessage({ role: "assistant", content: [{ type: "text", text: "probe assistant" }], api: "fixture", provider: "fixture", model: "fixture-model", usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, stopReason: "stop", timestamp: 1 });
  manager.appendLabelChange(user, "probe-label");
  manager.branch(customMessage);
  manager.appendMessage({ role: "assistant", content: [{ type: "text", text: "probe branch" }], api: "fixture", provider: "fixture", model: "fixture-model", usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, stopReason: "stop", timestamp: 1 });
  manager.appendCompaction("probe compaction", user, 10, { stable: true });
  settingsAuth = await settingsAndAuth("write");
  writeFileSync(statePath, manager.getSessionFile());
} else {
  const sessionPath = readFileSync(statePath, "utf8").trim();
  manager = SessionManager.open(sessionPath, sessionDir);
  const before = semantic(manager);
  settingsAuth = await settingsAndAuth(action);
  assertExpected({ ...before, settingsAuth }, action);
  if (action === "read-append") manager.appendCustomEntry("probe-after-read", { stable: true });
}
const result = { ...semantic(manager), settingsAuth };
const encoded = JSON.stringify(result);
if (Buffer.byteLength(encoded) > MAX_RESULT_BYTES) throw new Error("probe result exceeded bound");
process.stdout.write(`${encoded}\n`);
