import { cp, mkdir, mkdtemp, readFile, realpath, rename, rm, stat, symlink, writeFile } from "node:fs/promises";
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
import { subagentProcessesFromActivity } from "./process-activity.js";
import { RuntimeRegistry } from "./runtime-registry.js";
import { delegatedArtifactRoot, delegatedProviderEnvironment, ensureDelegatedArtifactRoot } from "./delegated-provider.js";
import { waitFor } from "../../test-support/wait-for.js";

// This driver is also copied unchanged into the pre-cutover Gateway. Only
// package selection and the released workflow input spelling vary by leg.
const old = process.env.TRON_PARITY_LEG === "old";
const baseline = fileURLToPath(new URL("../../test-support/subagent-parity-old.json", import.meta.url));
type ParityResourceRow = { name: string; path?: string; [key: string]: unknown };
type ParitySettings = {
  skills: ParityResourceRow[]; prompts: ParityResourceRow[];
  skillDiagnostics: unknown; promptDiagnostics: unknown;
  subagents: Record<string, ParityResourceRow>; subagentDiagnostics: string | null;
};
const gate = () => {
  let release!: () => void;
  const promise = new Promise<void>(resolve => { release = resolve; });
  return { promise, release };
};

it("preserves OLD app-facing subagent projections except approved delivery and identity changes", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-subagent-parity-"));
  // The temp root and its canonical form differ under macOS aliases (/tmp and
  // /var resolve below /private). Normalize both, canonical first, so reports
  // never depend on which temporary directory the run used.
  const canonicalRoot = await realpath(root);
  const withoutRoot = (text: string, base: string, label: string) =>
    text.split(canonicalRoot + base.slice(root.length)).join(label).split(base).join(label);
  const agentDir = join(root, "agent");
  const cwd = join(root, "workspace");
  const tronHome = join(root, "tron");
  const envNames = ["PI_CODING_AGENT_DIR", "PI_SUBAGENTS_TEMP_ROOT", "PI_SUBAGENTS_PI_CODING_AGENT_PACKAGE_ROOT", "NODE_OPTIONS", "TRON_TEST_PROCESS_OWNER", "TRON_TEST_PROCESS_OWNER_FAILURE"];
  const previous = envNames.map(name => process.env[name]);
  const gates = { single: gate(), workflow: gate(), answer: gate(), finish: gate(), preflight: gate(), busy: gate() };
  const globals = globalThis as unknown as { parityPreflight?: () => Promise<void>; parityPi?: import("@earendil-works/pi-coding-agent").ExtensionAPI };
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
    await writeFile(join(agentDir, "parity-input.mjs"), `export default pi => { globalThis.parityPi = pi; pi.on("input", async event => { if (event.text === "Subagent updates above." && globalThis.parityPreflight) await globalThis.parityPreflight(); return {action:"continue"}; }); };`);
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
      await cp(process.env.TRON_PARITY_OLD_PACKAGE, packageRoot, { recursive: true,
        // Source installations may be read-only. Fixture directories must stay
        // writable for dependency links, loader caches and owner cleanup.
        filter: async (source, target) => { if ((await stat(source)).isDirectory()) await mkdir(target, { recursive: true, mode: 0o700 }); return true; },
      });
      const manifest = JSON.parse(await readFile(join(packageRoot, "package.json"), "utf8"));
      if (manifest.name !== "pi-subagents" || manifest.version !== "0.59.0") throw new Error("The parity baseline requires pi-subagents 0.59.0");
      report.providerVersion = manifest.version;
      await symlink(join(process.cwd(), "node_modules"), join(packageRoot, "node_modules"), "dir");
      await writeFile(join(agentDir, "npm", "package.json"), JSON.stringify({ dependencies: { "pi-subagents": "0.59.0" } }));
      await writeFile(join(agentDir, "settings.json"), JSON.stringify({ packages: ["npm:pi-subagents@0.59.0"], extensions: ["./parity-input.mjs"] }));
    } else {
      const modulePath = "./managed-subagents.js";
      const { ManagedSubagents, MANAGED_SUBAGENTS_SOURCE } = await import(modulePath);
      managedSubagents = ManagedSubagents.activateForStartup(tronHome);
      managedSource = MANAGED_SUBAGENTS_SOURCE;
      report.providerVersion = JSON.parse(await readFile(join(managedSubagents.verify(), "package.json"), "utf8")).version;
      await writeFile(join(agentDir, "settings.json"), JSON.stringify({ extensions: ["./parity-input.mjs"] }));
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
      // Normalize execution identities before visiting values; never sort process
      // or child arrays, whose producer launch order is user-visible.
      const identities = new Map<string, string>();
      for (const entry of launches()) if (entry.type === "message" && entry.message.role === "toolResult") {
        const status = (report.statuses as Record<string, { runId: string; steps?: Array<{ runId?: string; sessionOwnerId?: string; label?: string }> }>)[`${name}:${entry.message.toolCallId}`];
        if (!status) continue;
        identities.set(status.runId, `<${entry.message.toolCallId}:run>`);
        for (const [index, step] of (status.steps ?? []).entries()) {
          if (step.runId) identities.set(step.runId, `<${entry.message.toolCallId}:child:${step.label ?? index}>`);
          if (step.sessionOwnerId) identities.set(step.sessionOwnerId, `<${entry.message.toolCallId}:session:${step.label ?? index}>`);
        }
      }
      const normalize = (value: unknown, key = ""): unknown => {
        if (Array.isArray(value)) return value.map(item => normalize(item));
        if (value && typeof value === "object") return Object.fromEntries(Object.entries(value).map(([field, item]) => [field, normalize(item, field)]));
        if (typeof value === "number" && /(?:At|timestamp|durationMs|elapsedMs|remainingMs)$/.test(key)) return Number.isFinite(value) && value >= 0 ? "<time>" : value;
        if (typeof value !== "string") return value;
        if (/(?:At|Until|timestamp)$/.test(key) && Number.isFinite(Date.parse(value))) return "<time>";
        if (key === "sessionOwnerId" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)) return "<session-owner>";
        if (key === "id" && /^(?:extension:|[0-9a-f]{8}:\d+)/.test(value)) return value.startsWith("extension:") ? "extension:<owner>" : `<entry>:${value.split(":")[1]}`;
        let text = value;
        // Canonical session layout and temporary/verified installation roots
        // vary per execution, but file names and provider-authored text do not.
        text = text.split(dirname(sessionFile!)).join("<sessions>");
        text = withoutRoot(text, root, "<fixture>");
        text = volatileProviderText(text);
        for (const [id, label] of identities) text = text.split(id).join(label);
        return text.replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi, "<uuid>")
          .replace(/\d{4}-\d{2}-\d{2}T[\d:.]+Z/g, "<time>")
          .replace(/\b\d+(?:\.\d+)?(?:ms|s)\b/g, "<elapsed>");
      };
      (report.snapshots as Record<string, unknown> ??= {})[name] = snapshot;
      // The transport bounds rows by recency (ties include random process IDs).
      // Compare the actual mounted rows in canonical launch/producer-child order,
      // not that time-dependent eviction order. Missing/extra rows still fail.
      const mounted = (snapshot.processActivities ?? []).filter(row => row.kind === "subagent");
      const rows = launches().flatMap(entry => {
        if (entry.type !== "message" || entry.message.role !== "toolResult") return [];
        const activity = snapshot.extensionActivities?.find(item => item.toolCallId === entry.message.toolCallId);
        if (!activity) return [];
        return subagentProcessesFromActivity(slot.id, activity).map(expected => {
          const actual = mounted.find(item => item.processId === expected.processId);
          if (!actual) throw new Error(`Missing mounted process ${expected.processId}`);
          return actual;
        });
      });
      expect(rows.length, "all mounted subagent rows participate in parity").toBe(mounted.length);
      rows.forEach((row, index) => identities.set(row.processId, `process:subagent:<row:${index}>`));
      const processes = rows.map(row => normalize({
        ...row, model: row.model?.split("/").at(-1),
        lifecycle: { ...row.lifecycle, sequence: "<revision>" },
      }));
      // Native process rows above own activity facts/timing. These additional
      // child fields own task and exact child/control admission; aggregate
      // extension counters are not consumed by the native process renderer.
      const childIdentity = (child: import("../protocol/types.js").ExtensionRunChild): unknown => normalize({
        id: child.id, producerId: child.producerId, label: child.label,
        task: child.task, childSessionRef: child.childSessionRef,
        sessionOwnerId: child.sessionOwnerId,
        children: child.children?.map(childIdentity), hostStep: child.hostStep,
      });
      const activities = (snapshot.extensionActivities ?? []).map(activity => normalize({
        toolCallId: activity.toolCallId, runId: activity.runId,
        children: activity.children.map(childIdentity),
      }));
      const transcript = snapshot.transcript.filter(row => row.semantic?.direction !== "hiddenInternal").filter(row => row.kind === "customMessage" && ["subagent-notify", "subagent_supervisor_request", "subagent-incremental-child-notify"].includes(row.customType)
        || row.kind === "message" && row.role === "user").map(row => {
          const details = row.kind === "customMessage" ? row.details as { reason?: string } : undefined;
          const category = row.kind === "customMessage" ? details?.reason ?? row.customType : "prompt";
          return { category, origin: row.semantic?.origin.kind ?? "unknown", title: row.semantic?.origin.title ?? null, classification: row.semantic?.kind ?? null,
            direction: row.semantic?.direction ?? null, contextEffect: row.semantic?.contextEffect ?? null, confidence: row.semantic?.origin.confidence ?? null,
            lifecycle: row.semantic?.lifecycle ?? null, resourceInvocation: normalize(row.semantic?.resourceInvocation ?? null), submittedText: row.semantic?.submittedText ?? null, delivery: row.semantic?.delivery ?? null, visibility: row.semantic?.visibility ?? null,
            content: normalize(row.content), details: normalize(row.kind === "customMessage" ? row.details ?? null : null) };
        });
      const semantic = snapshot.extensionPresentation.semanticState;
      const retained = [...semantic.widgets.map(widget => ({ type: "widget", key: widget.key, owner: widget.owner,
          contents: { lines: widget.lines, placement: widget.placement } })),
        ...Object.keys(semantic.statuses).sort().map(key => ({ type: "status", key, owner: semantic.statusOwners[key], contents: semantic.statuses[key] }))]
        .map(value => {
          const privateSubagent = old ? value.owner?.source?.startsWith("npm:pi-subagents") === true : value.owner?.kind === "subagent";
          return { type: value.type, key: value.key, source: value.owner?.source ?? null, title: value.owner?.title ?? null, kind: value.owner?.kind ?? null,
            privateSubagent, nativeVisibility: privateSubagent ? "hidden" : "visible", contents: privateSubagent ? null : normalize(value.contents) };
        });
      // ExtensionRetainedContentPolicy.content excludes subagent widgets,
      // statuses and surfaces before every native consumer (Swift lines 100,
      // 112 and 124). Private frames are not app text; compare ownership and
      // hidden visibility, retaining their raw bytes in report.snapshots only.
      const surfaces = snapshot.extensionPresentation.surfaces.map(surface => {
        const privateSubagent = old ? surface.provenance?.source?.startsWith("npm:pi-subagents") === true : surface.provenance?.kind === "subagent";
        const presentable = surface.kind === "widget" && surface.lifecycle !== "blocking" && surface.frame.lines.length > 0;
        return normalize({ ...surface, revision: "<revision>", privateSubagent,
          nativeVisibility: privateSubagent || !presentable ? "hidden" : "visible", frame: privateSubagent ? null : surface.frame });
      });
      const input = (item: typeof snapshot.pendingPrompt | typeof snapshot.queuedItems[number]) => item ? normalize({
        ...item, id: "<input>", semantic: item.semantic ? { ...item.semantic, origin: { ...item.semantic.origin, ownerId: item.semantic.origin.ownerId ? "<owner>" : undefined } } : undefined,
      }) : null;
      const inputs = { pending: input(snapshot.pendingPrompt), queued: snapshot.queuedItems.map(input),
        displayedPending: snapshot.pendingPrompt?.semantic?.direction === "hiddenInternal" ? null : input(snapshot.pendingPrompt),
        displayedQueued: snapshot.queuedItems.filter(item => item.semantic?.direction !== "hiddenInternal").map(input) };
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
      (report.checkpoints as Record<string, unknown>)[name] = { processes, nativeCounts: { active: snapshot.processOverview?.activeCount, recent: snapshot.processOverview?.recentCount, problem: snapshot.processOverview?.problemCount }, activities, transcript: transcriptByCategory, retained, surfaces, inputs, deliveries };
    };
    await slot.prompt("Launch the single child");
    await waitFor(() => requested.has("SINGLE") && parentIdle(), "single is running with idle parent");
    await capture("single-running");
    let preflightStarted = false;
    globals.parityPreflight = async () => { preflightStarted = true; await gates.preflight.promise; };
    gates.single.release();
    if (!old) {
      await waitFor(() => preflightStarted && Boolean(slot.snapshot().pendingPrompt), "idle wake pending preflight");
      const pending = slot.snapshot().pendingPrompt!;
      expect(pending.semantic).toMatchObject({ kind: "prompt", origin: { kind: "subagent" }, direction: "hiddenInternal", visibility: "hidden" });
      report.pendingWakeAuthority = pending;
      report.inputPresentation = { pending: pending.semantic?.direction === "hiddenInternal" ? null : pending.text };
    }
    if (old) report.inputPresentation = { pending: null };
    gates.preflight.release();
    delete globals.parityPreflight;
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
      const replacement = `${path}.parity-fixture`;
      const replaceStatus = async (bytes: string) => {
        await writeFile(replacement, bytes);
        await rename(replacement, path);
      };
      try {
        for (const key of ["parentWorkflowRunId", "workflowKey", "sessionOwnerId"] as const) {
          const candidate = JSON.parse(original);
          candidate[key] = "foreign-owner";
          candidate.steps[0].model = "FORGED_MODEL";
          await replaceStatus(JSON.stringify(candidate));
          await slot.discoverExtensionArtifact(directory);
          expect((slot.snapshot().processActivities ?? []).map(row => row.model), `${key} cannot attach foreign child detail`).not.toContain("FORGED_MODEL");
          refused.push(key);
        }
      } finally { await replaceStatus(original); await rm(replacement, { force: true }); }
      report.refusedChildEdges = refused;
      await slot.discoverExtensionArtifact(directory);
    }
    gates.answer.release();
    await waitFor(() => replies.size === 1 && parentIdle(), "question answer reaches child");
    gates.finish.release();
    await waitFor(() => acknowledged === 2 && parentIdle(), "workflow completion wakes idle parent");
    await capture("workflow-completed");
    // A factory-bound API probe covers the racing steer lifetime separately
    // from the unchanged released-provider scenario above. OLD had only a
    // custom-message turn here; NEW retains its typed, hidden normal-input wake.
    const api = globals.parityPi!;
    const sender = old ? api : await (async () => {
      const { managedProducerAPI } = await import("../extensions/managed-producer.js");
      const owner = { id: "parity-managed-owner", source: managedSource!, title: "Subagents", kind: "subagent" as const };
      return managedProducerAPI(api, owner, (...args) => slot.admitSubagentWake(...args));
    })();
    let busyStarted = false;
    faux.setResponses([async () => { busyStarted = true; await gates.busy.promise; return fauxAssistantMessage("PARITY_BUSY"); },
      ...Array.from({ length: 8 }, () => fauxAssistantMessage("PARITY_PARENT_IDLE"))]);
    await slot.prompt("Maintainer continues after workflow");
    await waitFor(() => busyStarted, "maintainer model gate");
    if (old) sender.sendMessage({ customType: "parity-wake-probe", content: "Queued context", display: false }, { triggerTurn: true });
    else sender.sendUserMessage("PARITY_QUEUED_WAKE", { deliverAs: "steer" });
    await slot.prompt("Queued maintainer input", [], "steer");
    await waitFor(() => slot.snapshot().queuedItems.length === (old ? 1 : 2), "racing internal and maintainer steering inputs");
    const queued = slot.snapshot().queuedItems;
    if (!old) expect(queued.find(item => item.text === "PARITY_QUEUED_WAKE")?.semantic).toMatchObject({ kind: "prompt", origin: { kind: "subagent" }, direction: "hiddenInternal", visibility: "hidden" });
    report.queuedWakeAuthority = queued;
    (report.inputPresentation as Record<string, unknown>).queued = queued.filter(item => item.semantic?.direction !== "hiddenInternal").map(item => ({ ...item, id: "<input>" }));
    gates.busy.release();
    await waitFor(parentIdle, "queued inputs bind and settle");
    const settings = async (): Promise<ParitySettings> => {
      const resources = await slot.resources() as {
        skills: { skills: ParityResourceRow[]; diagnostics: unknown };
        prompts: { prompts: ParityResourceRow[]; diagnostics: unknown };
        subagents: ParityResourceRow[]; subagentDiagnostics?: string;
      };
      const resourceRow = (row: ParityResourceRow) => ({ ...row, ...(row.path ? {
        path: volatileProviderText(withoutRoot(row.path, root, "<fixture>")),
      } : {}) });
      return {
        skills: resources.skills.skills.filter((row: ParityResourceRow) => ["pi-subagents", "council-mode"].includes(row.name)).map(resourceRow),
        prompts: resources.prompts.prompts.map(resourceRow),
        skillDiagnostics: resources.skills.diagnostics, promptDiagnostics: resources.prompts.diagnostics,
        subagents: Object.fromEntries(resources.subagents.map((row: ParityResourceRow) => [row.name, row])),
        subagentDiagnostics: resources.subagentDiagnostics === undefined ? null : withoutRoot(resources.subagentDiagnostics, cwd, "<workspace>"),
      };
    };
    const resourceStates = { healthy: await settings(), invalid: undefined as ParitySettings | undefined, repaired: undefined as ParitySettings | undefined };
    report.settings = resourceStates;
    const invalid = join(cwd, ".pi", "agents", "parity-invalid.md");
    await writeFile(invalid, "---\nname: parity-invalid\ndescription: Invalid parity definition\nfallbackModels: [parity-child/child]\n---\nRead only.\n");
    resourceStates.invalid = await settings();
    if (!old) {
      expect(resourceStates.invalid.subagentDiagnostics).toContain("fallbackModels");
      expect(resourceStates.invalid.subagents["parity-invalid"]).toBeUndefined();
    }
    await rm(invalid);
    resourceStates.repaired = await settings();
    expect(resourceStates.healthy.subagentDiagnostics).toBeNull();
    expect(resourceStates.repaired.subagentDiagnostics).toBeNull();
    const inventory = await new PackageService(agentDir, trust, () => {}, undefined, managedSubagents).list(cwd) as { packages: Array<{ source: string; provides: { skills: string[]; prompts: string[] } }> };
    report.packages = inventory.packages.filter(value => value.provides.skills.includes("pi-subagents")).map(value => ({ source: value.source, skills: value.provides.skills, prompts: value.provides.prompts }));
    report.entries = entries();
    report.schemaVersion = 2;
    if (old && process.env.TRON_PARITY_BASELINE_OUTPUT) {
      const { checkpoints, settings, packages, inputPresentation, schemaVersion } = report;
      await writeFile(process.env.TRON_PARITY_BASELINE_OUTPUT, JSON.stringify({ schemaVersion, checkpoints, settings, packages, inputPresentation }, null, 2) + "\n");
    }
    if (!old) {
      const before = JSON.parse(await readFile(baseline, "utf8"));
      const approved = JSON.parse(await readFile(fileURLToPath(new URL("../../test-support/subagent-parity-approved.json", import.meta.url)), "utf8"));
      const differences = compareParity(before, report, managedSource!, approved);
      report.differences = differences;
      expect(differences.filter(diff => !diff.approved), JSON.stringify(differences, null, 2)).toEqual([]);
    }
    report.passed = true;
  } catch (error) {
    report.error = String(error);
    report.failure = inspectFailure?.();
    throw error;
  } finally {
    delete globals.parityPreflight;
    delete globals.parityPi;
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
});

// pi-subagents' installation root embeds its version and its bundled worker-eval
// frames embed line/column positions. Both change on any fork bump and carry no
// app-facing meaning, so the NEW capture and the committed OLD baseline share this rule.
function volatileProviderText(text: string) {
  return text
    .replace(/(?:<fixture>\/agent\/npm\/node_modules\/pi-subagents|<fixture>\/tron\/internal\/pi-subagents\/[^\/\s"']+|<fixture>\/tron\/internal\/[^\s"']*?\/root)(?=\/|$)/g, "<provider>")
    .replace(/\[worker eval\]:\d+:\d+/g, "[worker eval]:<frame>");
}

// Finite allowances from #611: this compares deterministic Gateway projections,
// not Swift rendering or absolute timing. Arrays retain meaningful launch order.
function compareParity(before: Record<string, unknown>, after: Record<string, unknown>, managedSource: string, upstream: Array<{ path: string; old: unknown; new: unknown; approved: string }>) {
  const differences: Array<{ path: string; old: unknown; new: unknown; approved: string | null }> = [];
  const record = (value: unknown): value is Record<string, unknown> => Boolean(value && typeof value === "object" && !Array.isArray(value));
  const normalizeVolatile = (value: unknown): unknown => typeof value === "string" ? volatileProviderText(value)
    : Array.isArray(value) ? value.map(normalizeVolatile)
    : record(value) ? Object.fromEntries(Object.entries(value).map(([key, item]) => [key, normalizeVolatile(item)])) : value;
  // The committed OLD baseline was captured before this rule existed; normalizing it
  // here keeps both legs under one volatile-text rule without regenerating OLD.
  const baseline = normalizeVolatile(before) as Record<string, unknown>;
  function approval(a: unknown, b: unknown, path: string): string | null {
    // Upstream changes accepted in decisions.md are exact value pairs, not
    // exemptions for content, details, or resource fields.
    // Pairs stay raw evidence; they match after the same volatile rule as the baseline.
    const expected = upstream.find(change => change.path === path && JSON.stringify(normalizeVolatile(change.old)) === JSON.stringify(a ?? null) && JSON.stringify(normalizeVolatile(change.new)) === JSON.stringify(b ?? null));
    if (expected) return expected.approved;
    if (path.endsWith(".source") && (a === "npm:pi-subagents@0.59.0" || a === null) && b === managedSource) return path.startsWith("skills.") || path.startsWith("packages.") ? "skills listed under the managed package" : "source and title label change (admitted producer attribution)";
    if (path.endsWith(".title") && (a === "Pi Subagents" || a === null) && b === "Subagents") return "source and title label change";
    if (/\.(?:retained\.\d+\.kind|surfaces\.\d+\.provenance\.kind)$/.test(path) && (a === null || a === undefined) && b === "subagent") return "source and title label change (typed retained provider classification)";
    if (/\.transcript\.(need_decision|progress_update|subagent-notify)\.\d+\.origin$/.test(path) && a === "extension" && b === "subagent") return "source and title label change (typed producer classification)";
    if (/\.(transcript|deliveries)\.progress_update\.\d+\.delivery$/.test(path) && a === "triggeredTurn" && b === "stored") return "progress stored with no turn";
    if (a === undefined && Array.isArray(b)) {
      const checkpoint = path.split(".")[1];
      // Canonical deliveries pin the per-checkpoint count above. The projected
      // transcript publishes asynchronously, so a capture may observe the
      // question checkpoint's failed-child note before or after projection;
      // whenever present, each row must have the approved typed shape.
      if (path.endsWith(".transcript.subagent-incremental-child-notify") && ["workflow-question", "workflow-completed"].includes(checkpoint!) && b.length > 0 && b.every(row => record(row) && row.category === "subagent-incremental-child-notify" && row.origin === "subagent" && row.title === "Subagents" && row.direction === "inboundContext" && row.delivery === "stored" && row.visibility === "visible")) return "per-child notes stored; independent question/barrier owns turns";
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
  visit(baseline.checkpoints, after.checkpoints, "checkpoints");
  visit(baseline.settings, after.settings, "settings");
  visit(baseline.packages, after.packages, "packages");
  visit(baseline.inputPresentation, after.inputPresentation, "inputPresentation");
  return differences;
}
