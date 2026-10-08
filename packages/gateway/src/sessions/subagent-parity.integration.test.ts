import { cp, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createServer } from "node:http";
import { ChildProcess } from "node:child_process";
import { ModelRuntime, SessionManager } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall } from "@earendil-works/pi-ai";
import { expect, it } from "vitest";
import { TrustService } from "../admin/trust-service.js";
import { PackageService } from "../admin/package-service.js";
import { contextDeliveryMetadataByEntry } from "./context-delivery-receipts.js";
import { RuntimeRegistry } from "./runtime-registry.js";
import { delegatedArtifactRoot, delegatedProviderEnvironment, ensureDelegatedArtifactRoot } from "./delegated-provider.js";
import { waitFor } from "../../test-support/wait-for.js";

// This driver is also copied unchanged into the pre-cutover Gateway. Only
// package selection and the released workflow input spelling vary by leg.
const old = process.env.TRON_PARITY_LEG === "old";
const baseline = fileURLToPath(new URL("../../test-support/subagent-parity-old.json", import.meta.url));
const gate = () => {
  let release!: () => void;
  const promise = new Promise<void>(resolve => { release = resolve; });
  return { promise, release };
};

it("preserves OLD app-facing subagent projections except approved delivery and identity changes", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-subagent-parity-"));
  const agentDir = join(root, "agent");
  const cwd = join(root, "workspace");
  const tronHome = join(root, "tron");
  const envNames = ["PI_CODING_AGENT_DIR", "PI_SUBAGENTS_TEMP_ROOT", "PI_SUBAGENTS_PI_CODING_AGENT_PACKAGE_ROOT", "NODE_OPTIONS", "TRON_TEST_PROCESS_OWNER", "TRON_TEST_PROCESS_OWNER_FAILURE"];
  const previous = envNames.map(name => process.env[name]);
  const gates = { single: gate(), workflow: gate(), answer: gate(), finish: gate() };
  const prototype = ChildProcess.prototype as ChildProcess & { spawn(options: unknown): unknown };
  const spawn = prototype.spawn;
  const children = new Set<ChildProcess>();
  prototype.spawn = function(options) { const result = spawn.call(this, options); if (this.pid) children.add(this); return result; };
  let registry: RuntimeRegistry | undefined;
  let inspectFailure: (() => unknown) | undefined;
  let server: ReturnType<typeof createServer> | undefined;
  const report: Record<string, unknown> = { leg: old ? "old" : "new", passed: false, checkpoints: {} };
  try {
    await mkdir(agentDir, { recursive: true });
    await mkdir(join(cwd, ".pi", "agents"), { recursive: true });
    process.env.PI_CODING_AGENT_DIR = agentDir;
    process.env.TRON_TEST_PROCESS_OWNER = root;
    process.env.TRON_TEST_PROCESS_OWNER_FAILURE = join(root, "join-failure.jsonl");
    process.env.NODE_OPTIONS = `${process.env.NODE_OPTIONS ?? ""} --import=${fileURLToPath(new URL("../../test-support/fixture-process-owner.mjs", import.meta.url))}`.trim();
    await ensureDelegatedArtifactRoot(delegatedArtifactRoot(tronHome));
    delegatedProviderEnvironment(delegatedArtifactRoot(tronHome));
    let managedSubagents;
    let managedSource: string | undefined;
    if (old) {
      const packageRoot = join(agentDir, "npm", "node_modules", "pi-subagents");
      if (!process.env.TRON_PARITY_OLD_PACKAGE) throw new Error("TRON_PARITY_OLD_PACKAGE must name the read-only 0.59.0 source");
      await cp(process.env.TRON_PARITY_OLD_PACKAGE, packageRoot, { recursive: true });
      const manifest = JSON.parse(await readFile(join(packageRoot, "package.json"), "utf8"));
      if (manifest.name !== "pi-subagents" || manifest.version !== "0.59.0") throw new Error("The parity baseline requires pi-subagents 0.59.0");
      report.providerVersion = manifest.version;
      await symlink(join(process.cwd(), "node_modules"), join(packageRoot, "node_modules"), "dir");
      await writeFile(join(agentDir, "npm", "package.json"), JSON.stringify({ dependencies: { "pi-subagents": "0.59.0" } }));
      await writeFile(join(agentDir, "settings.json"), JSON.stringify({ packages: ["npm:pi-subagents@0.59.0"] }));
    } else {
      const modulePath = "./managed-subagents.js";
      const { ManagedSubagents, MANAGED_SUBAGENTS_SOURCE } = await import(modulePath);
      managedSubagents = ManagedSubagents.activateForStartup(tronHome);
      managedSource = MANAGED_SUBAGENTS_SOURCE;
      report.providerVersion = JSON.parse(await readFile(join(managedSubagents.verify(), "package.json"), "utf8")).version;
    }
    const requested = new Set<string>();
    let requests = 0;
    server = createServer(async (request, response) => {
      if (++requests > 16) { response.writeHead(500).end("Request bound exceeded"); return; }
      let bytes = "";
      for await (const chunk of request) { bytes += chunk; if (bytes.length > 2 * 1024 * 1024) { response.writeHead(413).end(); return; } }
      const messages = JSON.parse(bytes).messages as Array<{ role: string; content: unknown }>;
      const text = JSON.stringify(messages);
      const name = ["SINGLE", "FAIL", "QUESTION", "SUCCESS"].find(marker => text.includes(`PARITY_${marker}`));
      if (!name) { response.writeHead(400).end("Unknown scenario child"); return; }
      requested.add(name);
      await (name === "SINGLE" ? gates.single.promise : gates.workflow.promise);
      if (name === "FAIL") { response.writeHead(400, { "content-type": "application/json" }).end(JSON.stringify({ error: { message: "Scripted failure", type: "invalid_request_error" } })); return; }
      const tools = messages.some(message => message.role === "tool");
      if (name === "QUESTION" && tools) await gates.finish.promise;
      if (name === "SUCCESS") await gates.finish.promise;
      const ask = name === "QUESTION" && !tools;
      const delta = ask ? { tool_calls: [
        { index: 0, id: "progress", type: "function", function: { name: "contact_supervisor", arguments: JSON.stringify({ reason: "progress_update", message: "PARITY_PROGRESS" }) } },
        { index: 1, id: "question", type: "function", function: { name: "contact_supervisor", arguments: JSON.stringify({ reason: "need_decision", message: "PARITY_QUESTION: proceed?" }) } },
      ] } : { content: "PARITY_CHILD_COMPLETE" };
      response.writeHead(200, { "content-type": "text/event-stream" });
      for (const [value, finish] of [[{ role: "assistant", ...delta }, null], [{}, ask ? "tool_calls" : "stop"]]) response.write(`data: ${JSON.stringify({ id: "parity-child", object: "chat.completion.chunk", created: 1, model: "child", choices: [{ index: 0, delta: value, finish_reason: finish }] })}\n\n`);
      response.end("data: [DONE]\n\n");
    });
    server.requestTimeout = 10_000;
    await new Promise<void>(resolve => server!.listen(0, "127.0.0.1", resolve));
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("No child model port");
    await writeFile(join(agentDir, "models.json"), JSON.stringify({ providers: { "parity-child": {
      baseUrl: `http://127.0.0.1:${address.port}/v1`, api: "openai-completions", apiKey: "fixture-only",
      models: [{ id: "child", name: "Parity child", reasoning: false, input: ["text"], contextWindow: 128000, maxTokens: 4096, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }],
    } } }));
    await writeFile(join(cwd, ".pi", "agents", "parity-worker.md"), "---\nname: parity-worker\ndescription: Read-only parity child\nmodel: parity-child/child\ntools: read\n---\nComplete the scripted task.\n");
    await writeFile(join(cwd, "parity-workflow.js"), `await Promise.all(["FAIL", "QUESTION", "SUCCESS"].map(name => runs.run(name.toLowerCase(), {agent:"parity-worker", task:"PARITY_" + name, acceptance:{level:"none",reason:"Read-only parity"}}).catch(error => ({error:String(error)})))); throw new Error("Workflow barrier failure");`);
    const faux = fauxProvider({ provider: "parity-parent", tokensPerSecond: 100_000 });
    let sessionFile: string | undefined;
    let action: "single" | "workflow" | undefined = "single";
    const replies = new Set<string>();
    let acknowledged = 0;
    faux.setResponses(Array.from({ length: 16 }, () => async () => {
      if (action) {
        const current = action; action = undefined;
        const input = current === "single" ? { agent: "parity-worker", task: "PARITY_SINGLE", async: true, mission: false, acceptance: { level: "none", reason: "Read-only parity" } }
          : { [old ? "workflowScriptPath" : "workflow"]: "./parity-workflow.js", async: true, mission: false, acceptance: { level: "none", reason: "Read-only parity" } };
        return fauxAssistantMessage([fauxToolCall("subagent", input, { id: `${current}-launch` })], { stopReason: "toolUse" });
      }
      const entries = sessionFile ? SessionManager.open(sessionFile).getEntries() : [];
      const question = entries.find(entry => entry.type === "custom_message" && entry.customType === "subagent_supervisor_request" && (entry.details as { expectsReply?: boolean })?.expectsReply !== false);
      const id = question?.type === "custom_message" ? (question.details as { requestId?: string; id?: string })?.requestId ?? (question.details as { id?: string })?.id : undefined;
      if (id && !replies.has(id)) {
        await gates.answer.promise;
        replies.add(id);
        return fauxAssistantMessage([fauxToolCall("subagent_supervisor", { action: "reply", replyTo: id, message: "Proceed" }, { id: "answer" })], { stopReason: "toolUse" });
      }
      acknowledged = entries.filter(entry => entry.type === "custom_message" && entry.customType === "subagent-notify").length;
      return fauxAssistantMessage("PARITY_PARENT_IDLE");
    }));
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    registry = new RuntimeRegistry({ agentDir, tronHome, ...(managedSubagents ? { managedSubagents } : {}), delegatedArtifactRoot: delegatedArtifactRoot(tronHome), trust, idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => { const runtime = await ModelRuntime.create({ modelsPath: join(agentDir, "models.json"), refreshOnCreate: false }); runtime.registerNativeProvider(faux.provider); return runtime; },
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    await registry.initialize();
    const slot = await registry.create(cwd);
    await slot.setModel(faux.getModel().provider, faux.getModel().id);
    sessionFile = slot.sessionFile;
    inspectFailure = () => ({ requested: [...requested], entries: SessionManager.open(sessionFile!).getEntries(), snapshot: slot.snapshot() });
    const parentIdle = () => !(slot as unknown as { runtime: { session: { isStreaming: boolean } } }).runtime.session.isStreaming && !slot.snapshot().pendingPrompt;
    const entries = () => SessionManager.open(sessionFile!).getEntries();
    const launches = () => entries().filter(entry => entry.type === "message" && entry.message.role === "toolResult" && ["single-launch", "workflow-launch"].includes(entry.message.toolCallId));
    const capture = async (name: string) => {
      for (const entry of launches()) if (entry.type === "message" && entry.message.role === "toolResult") {
        const asyncDir = (entry.message.details as { asyncDir?: string })?.asyncDir;
        if (asyncDir) {
          await slot.discoverExtensionArtifact(asyncDir);
          const statuses = report.statuses as Record<string, unknown> ?? {};
          const status = JSON.parse(await readFile(join(asyncDir, "status.json"), "utf8"));
          statuses[`${name}:${entry.message.toolCallId}`] = status;
          for (const step of status.steps ?? []) if (step.async && step.runId) statuses[`${name}:child:${step.label}`] = JSON.parse(await readFile(join(dirname(asyncDir), step.runId, "status.json"), "utf8"));
          report.statuses = statuses;
        }
      }
      const snapshot = slot.snapshot();
      const processes = (snapshot.processActivities ?? []).filter(row => row.kind === "subagent").map(row => ({
        title: row.title, state: row.lifecycle.state, visibility: row.visibility, executionMode: row.executionMode,
        model: row.model?.split("/").at(-1) ?? null, thinking: row.thinking ?? null, started: Boolean(row.startedAt && Number.isFinite(Date.parse(row.startedAt))),
        toolCount: row.toolCount ?? null, turnCount: row.turnCount ?? null, childCount: row.childCount ?? null,
      })).sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b)));
      const transcript = snapshot.transcript.filter(row => row.kind === "customMessage" && ["subagent-notify", "subagent_supervisor_request", "subagent-incremental-child-notify"].includes(row.customType)
        || row.kind === "message" && row.role === "user").map(row => {
          const details = row.kind === "customMessage" ? row.details as { reason?: string } : undefined;
          const category = row.kind === "customMessage" ? details?.reason ?? row.customType : row.semantic?.kind === "subagentWake" ? "wake" : "prompt";
          const pill = category === "prompt" ? null : category === "need_decision" ? "Needs Attention" : category === "progress_update" ? "Progress Update"
            : category === "subagent-notify" ? "Result Received" : category === "subagent-incremental-child-notify" ? "Child Update" : "Update";
          return { category, origin: row.semantic?.origin.kind ?? "unknown", title: row.semantic?.origin.title ?? null, classification: row.semantic?.kind ?? null,
            direction: row.semantic?.direction ?? null, delivery: row.semantic?.delivery ?? null, visibility: row.semantic?.visibility ?? null, pill };
        }).sort((a, b) => a.category.localeCompare(b.category));
      const semantic = snapshot.extensionPresentation.semanticState;
      const retained = [...semantic.widgets.map(widget => ({ type: "widget", key: widget.key, owner: widget.owner })),
        ...Object.keys(semantic.statuses).map(key => ({ type: "status", key, owner: semantic.statusOwners[key] }))]
        .map(value => ({ type: value.type, key: value.key, source: value.owner?.source ?? null, title: value.owner?.title ?? null, kind: (value.owner as { kind?: string })?.kind ?? null,
          privateSubagent: old ? value.owner?.source?.startsWith("npm:pi-subagents") === true : (value.owner as { kind?: string })?.kind === "subagent" }))
        .sort((a, b) => a.key.localeCompare(b.key));
      const transcriptByCategory: Record<string, typeof transcript> = {};
      for (const row of transcript) (transcriptByCategory[row.category] ??= []).push(row);
      const deliveries: Record<string, unknown[]> = {};
      const canonical = entries();
      const receipts = contextDeliveryMetadataByEntry(canonical);
      for (const entry of canonical) if (entry.type === "custom_message" && ["subagent-notify", "subagent_supervisor_request", "subagent-incremental-child-notify"].includes(entry.customType)) {
        const category = (entry.details as { reason?: string })?.reason ?? entry.customType;
        const receipt = receipts.get(entry.id);
        (deliveries[category] ??= []).push({ display: entry.display, delivery: receipt?.delivery ?? null,
          source: receipt?.origin?.source ?? null, title: receipt?.origin?.owner?.title ?? null });
      }
      (report.checkpoints as Record<string, unknown>)[name] = { processes, transcript: transcriptByCategory, retained, deliveries };
    };
    await slot.prompt("Launch the single child");
    await waitFor(() => requested.has("SINGLE") && parentIdle(), "single is running with idle parent");
    await capture("single-running");
    gates.single.release();
    await waitFor(() => acknowledged === 1 && parentIdle(), "single completion wakes idle parent");
    await capture("single-completed");
    action = "workflow";
    await slot.prompt("Launch the three-child workflow");
    await waitFor(() => ["FAIL", "QUESTION", "SUCCESS"].every(name => requested.has(name)) && parentIdle(), "three workflow children are running");
    await capture("workflow-running");
    gates.workflow.release();
    await waitFor(() => entries().some(entry => entry.type === "custom_message" && entry.customType === "subagent_supervisor_request" && (entry.details as { expectsReply?: boolean })?.expectsReply === true), "child question pauses for parent answer");
    await waitFor(() => (slot.snapshot().processActivities ?? []).some(row => row.toolCount === 2)
      && (slot.snapshot().processActivities ?? []).some(row => row.lifecycle.state === "failed")
      && entries().filter(entry => entry.type === "custom_message" && entry.customType === "subagent_supervisor_request").length === 2,
      "artifact watchers publish failed child and pending question details without explicit discovery");
    await capture("workflow-question");
    if (!old) {
      // Hostile derivatives of the real child file exercise reciprocal-edge
      // admission, not provider execution. This fixture restores exact bytes.
      const status = (report.statuses as Record<string, { steps: Array<{ label?: string; runId: string }> }>)["workflow-question:workflow-launch"]!;
      const question = status.steps.find(step => step.label === "question")!;
      const launch = launches().find(entry => entry.type === "message" && entry.message.role === "toolResult" && entry.message.toolCallId === "workflow-launch")!;
      if (launch.type !== "message" || launch.message.role !== "toolResult") throw new Error("No workflow launch");
      const directory = (launch.message.details as { asyncDir: string }).asyncDir;
      const path = join(dirname(directory), question.runId, "status.json");
      const original = await readFile(path, "utf8");
      const refused: string[] = [];
      try {
        for (const key of ["parentWorkflowRunId", "workflowKey", "sessionOwnerId"] as const) {
          const candidate = JSON.parse(original);
          candidate[key] = "foreign-owner";
          candidate.steps[0].model = "FORGED_MODEL";
          await writeFile(path, JSON.stringify(candidate));
          await slot.discoverExtensionArtifact(directory);
          expect((slot.snapshot().processActivities ?? []).map(row => row.model), `${key} cannot attach foreign child detail`).not.toContain("FORGED_MODEL");
          refused.push(key);
        }
      } finally { await writeFile(path, original); }
      report.refusedChildEdges = refused;
      await slot.discoverExtensionArtifact(directory);
    }
    gates.answer.release();
    await waitFor(() => replies.size === 1 && parentIdle(), "question answer reaches child");
    gates.finish.release();
    await waitFor(() => acknowledged === 2 && parentIdle(), "workflow completion wakes idle parent");
    await capture("workflow-completed");
    const resources = await slot.resources() as { skills: { skills: Array<{ name: string; source: string; distribution?: string }> } };
    report.skills = resources.skills.skills.filter(skill => ["pi-subagents", "council-mode"].includes(skill.name)).map(skill => ({ name: skill.name, source: skill.source, distribution: skill.distribution })).sort((a, b) => a.name.localeCompare(b.name));
    const inventory = await new PackageService(agentDir, trust, () => {}, undefined, managedSubagents).list(cwd) as { packages: Array<{ source: string; provides: { skills: string[] } }> };
    report.packages = inventory.packages.filter(value => value.provides.skills.includes("pi-subagents")).map(value => ({ source: value.source, skills: value.provides.skills })).sort((a, b) => a.source.localeCompare(b.source));
    report.entries = entries();
    report.schemaVersion = 1;
    if (old && process.env.TRON_PARITY_BASELINE_OUTPUT) {
      const { checkpoints, skills, packages, schemaVersion } = report;
      await writeFile(process.env.TRON_PARITY_BASELINE_OUTPUT, JSON.stringify({ schemaVersion, checkpoints, skills, packages }, null, 2) + "\n");
    }
    if (!old) {
      const before = JSON.parse(await readFile(baseline, "utf8"));
      const differences = compareParity(before, report, managedSource!);
      report.differences = differences;
      expect(differences.filter(diff => !diff.approved), JSON.stringify(differences, null, 2)).toEqual([]);
    }
    report.passed = true;
  } catch (error) {
    report.error = String(error);
    report.failure = inspectFailure?.();
    throw error;
  } finally {
    Object.values(gates).forEach(value => value.release());
    let cleanupError: unknown;
    try { await registry?.dispose(); } catch (error) { cleanupError = error; }
    prototype.spawn = spawn;
    try {
      for (const child of children) if (child.exitCode === null && child.signalCode === null) {
        child.kill("SIGTERM");
        await waitFor(() => child.exitCode !== null || child.signalCode !== null, "parity fixture child joins descendants", { boundMs: 6_000 });
      }
      const joinFailure = await readFile(join(root, "join-failure.jsonl"), "utf8").catch(error => { if (error.code === "ENOENT") return ""; throw error; });
      if (joinFailure) throw new Error(`Fixture process join failed: ${joinFailure}`);
    } catch (error) { cleanupError ??= error; }
    try { if (server) await new Promise<void>((resolve, reject) => server!.close(error => error ? reject(error) : resolve())); }
    catch (error) { cleanupError ??= error; }
    envNames.forEach((name, index) => { if (previous[index] === undefined) delete process.env[name]; else process.env[name] = previous[index]; });
    if (cleanupError) { report.passed = false; report.cleanupError = String(cleanupError); report.preservedFixture = root; }
    else await rm(root, { recursive: true, force: true });
    const path = process.env.TRON_PARITY_REPORT ?? join(process.cwd(), "test-results", "subagent-parity.json");
    await mkdir(dirname(path), { recursive: true });
    await writeFile(path, JSON.stringify(report, null, 2) + "\n");
    if (cleanupError) throw cleanupError;
  }
}, 60_000);

// Finite allowances from #611's binding decisions. No native process field is
// ignored; additions must be exact typed notes/wakes at the expected checkpoint.
function compareParity(before: Record<string, unknown>, after: Record<string, unknown>, managedSource: string) {
  const differences: Array<{ path: string; old: unknown; new: unknown; approved: string | null }> = [];
  const record = (value: unknown): value is Record<string, unknown> => Boolean(value && typeof value === "object" && !Array.isArray(value));
  function approval(a: unknown, b: unknown, path: string): string | null {
    if (path.endsWith(".source") && (a === "npm:pi-subagents@0.59.0" || a === null) && b === managedSource) return path.startsWith("skills.") || path.startsWith("packages.") ? "skills listed under the managed package" : "source and title label change (admitted producer attribution)";
    if (path.endsWith(".title") && (a === "Pi Subagents" || a === null) && b === "Subagents") return "source and title label change";
    if (/\.retained\.\d+\.kind$/.test(path) && a === null && b === "subagent") return "source and title label change (typed retained provider classification)";
    if (/\.transcript\.(need_decision|progress_update|subagent-notify)\.\d+\.origin$/.test(path) && a === "extension" && b === "subagent") return "source and title label change (typed producer classification)";
    if (/\.(transcript|deliveries)\.progress_update\.\d+\.delivery$/.test(path) && a === "triggeredTurn" && b === "stored") return "progress stored with no turn";
    if (/\.(transcript|deliveries)\.(need_decision|subagent-notify)\.\d+\.delivery$/.test(path) && a === "triggeredTurn" && b === "stored") return "wake as an internal subagent input (custom context stored before wake)";
    if (a === undefined && Array.isArray(b)) {
      const checkpoint = path.split(".")[1];
      const wakes: Record<string, number> = { "single-completed": 1, "workflow-running": 1, "workflow-question": 2, "workflow-completed": 3 };
      if (path.endsWith(".transcript.wake") && b.length === wakes[checkpoint!] && b.every(row => record(row) && JSON.stringify(row) === JSON.stringify({ category: "wake", origin: "subagent", title: "Subagents", classification: "subagentWake", direction: "inboundContext", delivery: "stored", visibility: "visible", pill: "Update" }))) return "wake as an internal subagent input";
      if (path.endsWith(".transcript.subagent-incremental-child-notify") && checkpoint === "workflow-completed" && b.length === 1 && b.every(row => record(row) && JSON.stringify(row) === JSON.stringify({ category: "subagent-incremental-child-notify", origin: "subagent", title: "Subagents", classification: "message", direction: "inboundContext", delivery: "stored", visibility: "visible", pill: "Child Update" }))) return "per-child notes stored; independent question/barrier owns turns";
      if (path.endsWith(".deliveries.subagent-incremental-child-notify") && ["workflow-question", "workflow-completed"].includes(checkpoint!) && b.length === (checkpoint === "workflow-question" ? 1 : 3) && b.every(row => record(row) && row.delivery === "stored" && row.source === managedSource && row.title === "Subagents" && typeof row.display === "boolean")) return "per-child notes stored; independent question/barrier owns turns";
    }
    return null;
  }
  function visit(a: unknown, b: unknown, path: string) {
    if (JSON.stringify(a) === JSON.stringify(b)) return;
    const approved = approval(a, b, path);
    if (approved) { differences.push({ path, old: a ?? null, new: b ?? null, approved }); return; }
    if (Array.isArray(a) && Array.isArray(b) && a.length === b.length) {
      for (let index = 0; index < a.length; index++) visit(a[index], b[index], `${path}.${index}`);
    } else if (record(a) && record(b)) {
      for (const key of new Set([...Object.keys(a), ...Object.keys(b)])) visit(a[key], b[key], `${path}.${key}`);
    } else differences.push({ path, old: a ?? null, new: b ?? null, approved: null });
  }
  visit(before.checkpoints, after.checkpoints, "checkpoints");
  visit(before.skills, after.skills, "skills");
  visit(before.packages, after.packages, "packages");
  return differences;
}
