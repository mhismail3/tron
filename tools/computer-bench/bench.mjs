#!/usr/bin/env node
// Purpose: computer- and browser-use scorecard (scripts/tron computer-bench): fixed local tasks per tool, success rate, wall time and function coverage per Tron surface.
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { agentBrowser } from "./agent-browser.mjs";
import { browserUse } from "./browser-use.mjs";
import { cua } from "./cua.mjs";
import { startSite } from "./fixtures/site.mjs";

export const FUNCTIONS = [
  ["navigate", "Navigate to a URL and read the title"],
  ["click", "Click a page button"],
  ["type", "Type into a page field"],
  ["replace", "Select-all and replace a page field's text"],
  ["form-controls", "Select a dropdown option and check a box"],
  ["upload", "Upload a file through a file input"],
  ["download", "Download a file to a chosen path"],
  ["multi-tab", "Follow a new-tab link, read it, return"],
  ["js-dialog", "Accept a JavaScript confirm dialog"],
  ["screenshot", "Capture a page/window screenshot"],
  ["ax-read", "Read the page accessibility tree"],
  ["session-reuse", "Reuse a cookie session across browser restarts"],
  ["oauth-consent", "Click through a two-origin consent redirect"],
  ["signed-in-chrome", "Attach to the maintainer's signed-in Chrome"],
  ["native-read", "Read a native window's controls (AX)"],
  ["native-click", "Click a native button"],
  ["native-type", "Type into a native text field"],
  ["native-replace", "Select-all and replace a native field"],
  ["native-select", "Choose a native pop-up menu item"],
  ["native-modal", "Approve an in-app modal sheet (permission-prompt proxy)"],
  ["desktop-screenshot", "Capture the full desktop"],
  ["background-delivery", "Act without changing the frontmost app"],
  ["foreground-delivery", "Foreground input that restores the frontmost app"],
  ["permission-prompt", "Approve a real macOS permission prompt"],
  ["locked-refusal", "Refuse input while the Mac is locked/asleep"],
];
const NOT_MEASURED = {
  "permission-prompt": "not measured: triggering a real TCC prompt changes system permissions",
  "locked-refusal": "not measured: needs the Mac locked or asleep",
};
const ADAPTERS = { "agent-browser": agentBrowser, "browser-use": browserUse, cua };
const SURFACES = JSON.parse(readFileSync(new URL("./surfaces.json", import.meta.url), "utf8"));
const USAGE = `Usage: scripts/tron computer-bench [--tools agent-browser,cua,browser-use] [--reps N] [--only task,...] [--foreground] [--json <file>] [--markdown <file>]
  --tools       adapters to run (default: all; an unavailable adapter is reported, not skipped)
  --reps        repetitions per task (default 3)
  --only        run only these task ids
  --foreground  also run foreground-delivery cases (moves focus briefly; idle Mac only)
  --json        write raw results
  --markdown    write the scorecard markdown (default: stdout)`;

const median = (values) => { const sorted = [...values].sort((a, b) => a - b); return sorted.length ? sorted[Math.floor((sorted.length - 1) / 2)] : undefined; };

async function runTool(name, options, ctx) {
  const adapter = ADAPTERS[name](options);
  const probe = await adapter.probe().catch((error) => ({ ok: false, reason: String(error.message ?? error) }));
  const tool = { name, probe, tasks: {} };
  if (!probe.ok) return tool;
  const ids = Object.keys(adapter.tasks).filter((id) => !options.only || options.only.includes(id));
  const setupStarted = performance.now();
  try { await adapter.setup(ctx); } catch (error) { tool.probe = { ...probe, ok: false, reason: `setup failed: ${error.message}` }; await adapter.teardown().catch(() => {}); return tool; }
  tool.setupMs = Math.round(performance.now() - setupStarted);
  try {
    for (let rep = 0; rep < options.reps; rep += 1) {
      ctx.rep = rep;
      if (adapter.beforeRep) await adapter.beforeRep(ctx);
      for (const id of ids) {
        const started = performance.now();
        let outcome;
        try { outcome = await adapter.tasks[id](ctx); } catch (error) { outcome = { ok: false, detail: String(error.message ?? error).slice(0, 400) }; }
        const ms = Math.round(performance.now() - started);
        const status = outcome.status ?? (outcome.ok ? "pass" : "fail");
        (tool.tasks[id] ??= []).push({ status, ms, detail: outcome.detail?.replace(/\s+/gu, " ").trim(), stoleFocus: outcome.stoleFocus ?? false });
        process.stderr.write(`${name} ${id} #${rep + 1}: ${status} ${ms}ms ${outcome.detail ?? ""}\n`);
      }
    }
  } finally { await adapter.teardown().catch((error) => ctx.notes.push(`${name} teardown: ${error.message}`)); }
  if (name === "cua") {
    const attempts = Object.entries(tool.tasks).filter(([id]) => id !== "foreground-delivery").flatMap(([, list]) => list);
    const stolen = attempts.filter((attempt) => attempt.stoleFocus).length;
    tool.tasks["background-delivery"] = [{ status: stolen ? "fail" : "pass", ms: 0, detail: `${stolen}/${attempts.length} background actions changed the frontmost app` }];
  }
  return tool;
}

export function summarize(tool, id) {
  if (NOT_MEASURED[id]) return { cell: "n/m", status: "not-measured", detail: NOT_MEASURED[id] };
  if (!tool.probe.ok) return { cell: "absent", status: "absent", detail: tool.probe.reason };
  const attempts = tool.tasks[id];
  if (!attempts) return { cell: "—", status: "unsupported" };
  if (attempts.every((attempt) => attempt.status === "needs-idle")) return { cell: "idle", status: "needs-idle", detail: attempts[0].detail };
  const passed = attempts.filter((attempt) => attempt.status === "pass").length;
  const ms = median(attempts.map((attempt) => attempt.ms));
  return { cell: `${passed}/${attempts.length}${ms ? ` · ${ms}ms` : ""}`, status: passed === attempts.length ? "pass" : passed ? "flaky" : "fail", passed, total: attempts.length, ms, detail: attempts.find((attempt) => attempt.status !== "pass")?.detail ?? attempts[0].detail };
}

export function scorecard(results) {
  const tools = results.tools;
  const lines = [`# Computer- and browser-use scorecard`, "", `Generated by \`scripts/tron computer-bench\` (${results.reps} reps, ${results.startedAt}). Regenerate rather than edit.`, ""];
  lines.push("## Tools", "", "| Tool | Available | Version / reason | Setup |", "|---|---|---|---|");
  for (const tool of tools) lines.push(`| ${tool.name} | ${tool.probe.ok ? "yes" : "no"} | ${tool.probe.version ?? tool.probe.reason ?? ""} | ${tool.setupMs ? `${tool.setupMs}ms` : ""} |`);
  lines.push("", "## Coverage (passes/attempts · median wall time)", "", "`—` not attempted by the tool's adapter, `idle` needs an idle Mac (`--foreground`), `n/m` not measured, `absent` tool not present.", "");
  lines.push(`| Function | ${tools.map((tool) => tool.name).join(" | ")} |`, `|---|${tools.map(() => "---").join("|")}|`);
  for (const [id, label] of FUNCTIONS) lines.push(`| ${id}: ${label} | ${tools.map((tool) => summarize(tool, id).cell).join(" | ")} |`);
  lines.push("", "## Per tool", "", "| Tool | Functions passing | Success rate (attempts) | Median task wall time |", "|---|---|---|---|");
  for (const tool of tools) {
    const cells = FUNCTIONS.map(([id]) => summarize(tool, id));
    const measured = cells.filter((cell) => cell.total);
    const passed = measured.reduce((sum, cell) => sum + cell.passed, 0), total = measured.reduce((sum, cell) => sum + cell.total, 0);
    const times = Object.values(tool.tasks).flat().filter((attempt) => attempt.ms).map((attempt) => attempt.ms);
    lines.push(`| ${tool.name} | ${cells.filter((cell) => cell.status === "pass").length}/${FUNCTIONS.length} | ${total ? `${Math.round((100 * passed) / total)}% (${passed}/${total})` : "—"} | ${times.length ? `${median(times)}ms` : "—"} |`);
  }
  lines.push("", "## Per surface", "", "A tool counts on a surface only when it is a first-class tool there; `shell` means reachable only through bash.", "");
  const surfaceIds = Object.keys(SURFACES.surfaces);
  lines.push(`| Surface | ${tools.map((tool) => tool.name).join(" | ")} | Functions passing (any first-class tool) |`, `|---|${tools.map(() => "---").join("|")}|---|`);
  for (const surface of surfaceIds) {
    const firstClass = tools.filter((tool) => SURFACES.reach[tool.name]?.[surface]?.reach === "first-class");
    const covered = FUNCTIONS.filter(([id]) => firstClass.some((tool) => summarize(tool, id).status === "pass")).length;
    lines.push(`| ${surface}: ${SURFACES.surfaces[surface]} | ${tools.map((tool) => SURFACES.reach[tool.name]?.[surface]?.reach ?? "none").join(" | ")} | ${covered}/${FUNCTIONS.length} |`);
  }
  lines.push("", "## Failures and notes", "");
  for (const tool of tools) for (const [id] of FUNCTIONS) {
    const cell = summarize(tool, id);
    if (["fail", "flaky", "needs-idle"].includes(cell.status)) lines.push(`- **${tool.name} ${id}** (${cell.status}): ${cell.detail}`);
  }
  for (const note of results.notes) lines.push(`- ${note}`);
  lines.push("", "Surface evidence: [`surfaces.json`](surfaces.json).", "");
  return lines.join("\n");
}

async function main() {
  const { values } = parseArgs({ options: { tools: { type: "string" }, reps: { type: "string", default: "3" }, only: { type: "string" }, foreground: { type: "boolean", default: false },
    json: { type: "string" }, markdown: { type: "string" }, help: { type: "boolean", default: false } } });
  if (values.help) { console.log(USAGE); return; }
  const names = (values.tools ?? Object.keys(ADAPTERS).join(",")).split(",");
  for (const name of names) if (!ADAPTERS[name]) throw new Error(`unknown tool ${name}\n${USAGE}`);
  const options = { reps: Number(values.reps), only: values.only?.split(","), foreground: values.foreground };
  const workdir = mkdtempSync("/tmp/cbench-");
  const site = await startSite();
  const uploadFile = join(workdir, "bench-upload.txt");
  writeFileSync(uploadFile, "upload-bytes");
  const ctx = { site, workdir, uploadFile, uploadExpect: "bench-upload.txt:12", notes: [], rep: 0 };
  const results = { startedAt: new Date().toISOString(), reps: options.reps, tools: [], notes: ctx.notes };
  try {
    for (const name of names) results.tools.push(await runTool(name, options, ctx));
  } finally {
    await site.close();
    rmSync(workdir, { recursive: true, force: true });
  }
  if (values.json) writeFileSync(values.json, `${JSON.stringify(results, null, 2)}\n`);
  const markdown = scorecard(results);
  if (values.markdown) writeFileSync(values.markdown, markdown); else process.stdout.write(markdown);
}

if (import.meta.url === `file://${process.argv[1]}`) await main();
