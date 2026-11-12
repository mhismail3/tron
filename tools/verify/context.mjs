#!/usr/bin/env node
// Render source-owned context layers and report duplicate, volatile and malformed-index diagnostics.
import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const sentences = text => text.split(/(?<=[.!?])\s+|\n+/).map(value => value.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, " ").trim()).filter(value => value.length >= 60);
const words = text => new Set(text.split(" "));

export function audit(layers, sources = []) {
  const diagnostics = [];
  const sizes = layers.map(layer => ({ role: layer.role, name: layer.name, bytes: Buffer.byteLength(layer.text), tokens: Math.ceil(Buffer.byteLength(layer.text) / 4), estimate: "bytes/4; report only" }));
  for (const layer of layers) {
    if (["system", "tools", "index"].includes(layer.kind) && /\b\d{4}-\d{2}-\d{2}\b|\b[a-f0-9]{12,64}\b|\b\d+\s+(?:active|total)\b|(?:arrival version|capacity|sorting offer|current .* model|current .* thinking level):/i.test(layer.text)) {
      diagnostics.push({ rule: "volatile", role: layer.role, layer: layer.name });
    }
    for (const match of layer.text.matchAll(/<index\b([^>]*)>([\s\S]*?)<\/index>/g)) {
      const attributes = match[1];
      const lines = match[2].trim().split("\n");
      const items = lines.map(line => /^- ([^:]+): (.{1,160}) \| (.+)$/.exec(line));
      const ids = items.filter(Boolean).map(item => item[1]);
      if (!/name="[^"]+"/.test(attributes) || !/open="[^"]+"/.test(attributes) || !/kind="(?:procedure|data|tool)"/.test(attributes) || items.some(item => !item) || ids.join("\n") !== [...ids].sort().join("\n") || new Set(ids).size !== ids.length || Buffer.byteLength(match[0]) > (layer.indexBudget ?? 8192)) {
        diagnostics.push({ rule: "index-format", role: layer.role, layer: layer.name });
      }
    }
  }
  for (let a = 0; a < layers.length; a++) {
    for (let b = a + 1; b < layers.length; b++) {
      if (layers[a].role !== layers[b].role || !layers[a].always || !layers[b].always) continue;
      let duplicate = false;
      for (const first of sentences(layers[a].text)) {
        const one = words(first);
        for (const second of sentences(layers[b].text)) {
          const two = words(second);
          const shared = [...one].filter(word => two.has(word)).length;
          if (shared / new Set([...one, ...two]).size >= 0.8) duplicate = true;
        }
      }
      if (duplicate) diagnostics.push({ rule: "duplicate", role: layers[a].role, layers: [layers[a].name, layers[b].name] });
    }
  }
  for (const [rule, pattern] of [["D1-checkin-owner", /(?:send|ask workers to send) (?:a )?(?:short |lightweight )?checkin[^.!?]*30 minutes/i], ["D2-approval-owner", /Ask (?:him )?only for spend[^.!?]*2FA/i]]) {
    const owners = sources.filter(source => pattern.test(source.text)).map(source => source.name);
    if (owners.length > 1) diagnostics.push({ rule, owners });
  }
  if (sources.some(source => /\.filter\(tool => homeToolAvailable\(tool.name, (?:activation.kind|kind)\)\)/.test(source.text))) diagnostics.push({ rule: "N1-kind-dependent-tools", role: "home" });
  return { diagnostics, sizes, budgets: { tools: 10000, system: 11000 }, budgetPolicy: "review signal; not a gate" };
}

async function render() {
  const require = createRequire(resolve(root, "packages/gateway/node_modules/@earendil-works/pi-coding-agent/package.json"));
  const { createJiti } = require("jiti");
  const jiti = createJiti(import.meta.url, { moduleCache: false, fsCache: false });
  const { tronContext, createTronCoreExtension } = await jiti.import(resolve(root, "packages/gateway/src/workspace/tron-core-extension.ts"));
  const { HOME_OPERATING_CONTEXT } = await jiti.import(resolve(root, "packages/gateway/src/modules/home/tron-home-extension.ts"));
  const { createHomeTaskWorkerExtension } = await jiti.import(resolve(root, "packages/gateway/src/kernel/delegation/task-worker-extension.ts"));
  const { profileIndex } = await jiti.import(resolve(root, "packages/gateway/src/modules/home/home-profile-hierarchy.ts"));
  let worker = "";
  createHomeTaskWorkerExtension({})({ on(name, handler) {
    if (name === "before_agent_start") worker = handler({ systemPrompt: "" }).systemPrompt;
  } });
  let handoff;
  createTronCoreExtension({ describe: async () => ({ root: "/workspace", available: true }) })({ on(name, handler) { if (name === "tool_call") handoff = handler; } });
  const child = { toolName: "subagent", input: { agent: "worker", task: "" } };
  await handoff(child);
  const project = await readFile(resolve(root, "AGENTS.md"), "utf8");
  const core = tronContext({ root: "/workspace", available: true }, "/project", ["computer", "subagent", "display", "ask_user"]);
  const layers = [];
  for (const role of ["chat", "worker", "subagent", "home"]) {
    layers.push({ role, name: "core", text: role === "home" ? HOME_OPERATING_CONTEXT : role === "subagent" ? child.input.task : core, kind: "system", always: true });
    if (["chat", "worker"].includes(role)) layers.push({ role, name: "project", text: project, kind: "rules", always: true });
    if (role === "worker") layers.push({ role, name: "worker-contract", text: worker, kind: "system", always: true });
  }
  const sorting = { version: 1, deferred: false };
  layers.push({ role: "home", name: "profile-index", text: profileIndex({ items: [], diagnostics: [], sorting }, 0, "user"), kind: "index", always: true });
  const paths = ["packages/gateway/src/workspace/tron-core-extension.ts", "packages/gateway/src/modules/home/tron-home-extension.ts", "packages/gateway/src/modules/home/home-task-dispatcher.ts", "packages/gateway/src/kernel/delegation/task-worker-extension.ts", "packages/gateway/src/modules/home/home-request-policy.ts"];
  const sources = await Promise.all(paths.map(async name => ({ name, text: await readFile(resolve(root, name), "utf8") })));
  return { layers, sources };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const input = process.argv.indexOf("--input");
    const rendered = input < 0 ? await render() : JSON.parse(await readFile(process.argv[input + 1], "utf8"));
    const result = audit(rendered.layers, rendered.sources);
    console.log(JSON.stringify(result, null, 2));
    process.exitCode = result.diagnostics.length && !process.argv.includes("--report-only") ? 1 : 0;
  } catch (error) {
    console.error(`context audit: ${error.message}`);
    process.exitCode = 2;
  }
}
