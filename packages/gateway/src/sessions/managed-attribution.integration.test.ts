import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { createServer, type Server } from "node:http";
import { dirname, join } from "node:path";
import { ModelRuntime, SessionManager, type AgentSession, type ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall } from "@earendil-works/pi-ai";
import { expect, it } from "vitest";
import { TrustService } from "../admin/trust-service.js";
import { ManagedSubagents, MANAGED_SUBAGENTS_SOURCE } from "./managed-subagents.js";
import { delegatedArtifactRoot, delegatedProviderEnvironment, ensureDelegatedArtifactRoot } from "./delegated-provider.js";
import { RuntimeRegistry } from "./runtime-registry.js";
import { waitFor } from "../../test-support/wait-for.js";
import { managedProducerAPI } from "../extensions/managed-producer.js";
import { producerIdentity, withExtensionOwner } from "../extensions/owner-attribution.js";
import { AsyncResource } from "node:async_hooks";
import { ChildProcess } from "node:child_process";
import { fileURLToPath } from "node:url";
import { CONTEXT_DELIVERY_RECEIPT_TYPE, makeContextDeliveryReceipt, contextDeliveryMetadataByEntry } from "./context-delivery-receipts.js";
import { EXTENSION_ACTIVITY_RECEIPT_TYPE, makeExtensionActivityReceipt, extensionActivityReceipts } from "./extension-activity-history.js";

it("attributes real workflow completion and supervisor delivery to their managed producer", async ({ task }) => {
  const root = await mkdtemp(join(tmpdir(), "tron-managed-attribution-"));
  const agentDir = join(root, "agent");
  const cwd = join(root, "workspace");
  const tronHome = join(root, "tron");
  const names = ["PI_CODING_AGENT_DIR", "PI_SUBAGENTS_TEMP_ROOT", "PI_SUBAGENTS_PI_CODING_AGENT_PACKAGE_ROOT",
    "NODE_OPTIONS", "TRON_TEST_PROCESS_OWNER", "TRON_TEST_PROCESS_OWNER_FAILURE"];
  const previous = names.map(name => process.env[name]);
  let registry: RuntimeRegistry | undefined;
  let server: Server | undefined;
  let release: (() => void) | undefined;
  let releaseFailure: (() => void) | undefined;
  let releaseRemaining: (() => void) | undefined;
  const failureGate = new Promise<void>(resolve => { releaseFailure = resolve; });
  const remainingGate = new Promise<void>(resolve => { releaseRemaining = resolve; });
  const external = new AsyncResource("managed-attribution-external-producer");
  const globals = globalThis as typeof globalThis & { tronAttributionPi?: ExtensionAPI; tronWakeInputGate?: Promise<void>; tronWakeInputStarted?: boolean };
  // Detached provider children inherit the existing test-only recursive join
  // owner. The fixture keeps its direct spawn handles and joins before files.
  const prototype = ChildProcess.prototype as ChildProcess & { spawn(options: unknown): unknown };
  const spawn = prototype.spawn;
  const children = new Set<ChildProcess>();
  prototype.spawn = function (options) {
    const result = spawn.call(this, options);
    if (this.pid !== undefined) children.add(this);
    return result;
  };
  const facts: Record<string, unknown> = { passed: false };
  const extensionErrors: unknown[] = [];
  try {
    await mkdir(agentDir);
    await mkdir(join(cwd, ".pi", "agents"), { recursive: true });
    await writeFile(join(agentDir, "capture.mjs"), `export default pi => { globalThis.tronAttributionPi = pi; pi.on("input", async event => { if (event.text === "idle-wake-marker" && globalThis.tronWakeInputGate) { globalThis.tronWakeInputStarted = true; await globalThis.tronWakeInputGate; } return {action:"continue"}; }); pi.on("before_agent_start", () => ({ message: { customType: "wake-hook-proof", content: "NORMAL_PROMPT_HOOK", display: false } })); };`);
    await writeFile(join(agentDir, "settings.json"), JSON.stringify({ extensions: ["capture.mjs"] }));
    process.env.PI_CODING_AGENT_DIR = agentDir;
    process.env.TRON_TEST_PROCESS_OWNER = root;
    process.env.TRON_TEST_PROCESS_OWNER_FAILURE = join(root, "process-owner-failure.jsonl");
    const preload = fileURLToPath(new URL("../../test-support/fixture-process-owner.mjs", import.meta.url));
    process.env.NODE_OPTIONS = `${process.env.NODE_OPTIONS ?? ""} --import=${preload}`.trim();
    await ensureDelegatedArtifactRoot(delegatedArtifactRoot(tronHome));
    delegatedProviderEnvironment(delegatedArtifactRoot(tronHome));
    const managedSubagents = ManagedSubagents.activateForStartup(tronHome);
    const faux = fauxProvider({ provider: "tron-managed-attribution", tokensPerSecond: 10_000 });
    const model = faux.getModel();
    // Detached children have their own SDK/provider registry. A loopback
    // OpenAI-compatible fixture supplies their scripted model, not credentials.
    let childRequests = 0;
    server = createServer(async (request, response) => {
      if (++childRequests > 32) { response.writeHead(500).end("Child fixture request bound exceeded"); return; }
      let bytes = "";
      for await (const chunk of request) {
        bytes += chunk;
        if (bytes.length > 2 * 1024 * 1024) { response.writeHead(413).end(); return; }
      }
      const messages = JSON.parse(bytes).messages as Array<{ role: string; content: unknown }>;
      if (JSON.stringify(messages).includes("FAIL_CHILD")) {
        await failureGate;
        response.writeHead(400, { "content-type": "application/json" }).end(JSON.stringify({ error: { message: "Scripted child failure", type: "invalid_request_error" } }));
        return;
      }
      if (JSON.stringify(messages).includes("COMPLETE_ONLY lane-")) await remainingGate;
      const alreadyRequested = messages.some(message => message.role === "tool") || JSON.stringify(messages).includes("COMPLETE_ONLY");
      const delta = alreadyRequested ? { content: "CHILD_COMPLETE" } : { tool_calls: [{ index: 0, id: "progress", type: "function",
        function: { name: "contact_supervisor", arguments: JSON.stringify({ reason: "progress_update", message: "ATTRIBUTION_PROGRESS" }) } }, { index: 1, id: "decision", type: "function",
        function: { name: "contact_supervisor", arguments: JSON.stringify({ reason: "need_decision", message: "ATTRIBUTION_DECISION" }) } }] };
      response.writeHead(200, { "content-type": "text/event-stream" });
      for (const [value, finish] of [[{ role: "assistant", ...delta }, null], [{}, alreadyRequested ? "stop" : "tool_calls"]]) {
        response.write(`data: ${JSON.stringify({ id: "child-probe", object: "chat.completion.chunk", created: 1, model: "child",
          choices: [{ index: 0, delta: value, finish_reason: finish }] })}\n\n`);
      }
      response.end("data: [DONE]\n\n");
    });
    server.requestTimeout = 5_000;
    await new Promise<void>(resolve => server!.listen(0, "127.0.0.1", resolve));
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("Missing child fixture port");
    await writeFile(join(agentDir, "models.json"), JSON.stringify({ providers: { "attribution-child": {
      baseUrl: `http://127.0.0.1:${address.port}/v1`, api: "openai-completions", apiKey: "fixture-only",
      models: [{ id: "child", name: "Scripted child", reasoning: false, input: ["text"], contextWindow: 128000, maxTokens: 4096,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }],
    } } }));
    await writeFile(join(cwd, ".pi", "agents", "probe.md"), `---\nname: probe\ndescription: Attribution probe\nmodel: attribution-child/child\ntools: read\n---\nSend a progress update and finish.\n`);
    await writeFile(join(cwd, "workflow.js"), `await Promise.all([0,1,2,3].map(i => runs.run("lane-" + i, {agent:"probe", task:(i === 0 ? "Send attribution progress" : i === 1 ? "FAIL_CHILD" : "COMPLETE_ONLY") + " lane-" + i, acceptance:{level:"none",reason:"Read-only attribution probe"}}).catch(error => ({error:String(error)})))); throw new Error("Workflow completion failure after all child results");`);
    await writeFile(join(cwd, "foreground.js"), `return runs.run("foreground-child", {agent:"probe", task:"COMPLETE_ONLY foreground", async:false, acceptance:{level:"none",reason:"Read-only foreground probe"}});`);
    await writeFile(join(cwd, "quiet-failure.js"), `throw new Error("QUIET_SCHEDULE_FAILURE");`);
    const replied = new Set<string>();
    let sessionFile: string | undefined;
    let workflowCompletionAcknowledged = false;
    faux.setResponses([
      fauxAssistantMessage([fauxToolCall("subagent", { workflow: "./workflow.js", async: true, mission: false,
        acceptance: { level: "none", reason: "Read-only attribution probe" } }, { id: "workflow-launch" })], { stopReason: "toolUse" }),

      ...Array.from({ length: 8 }, () => () => {
        const request = sessionFile ? SessionManager.open(sessionFile).getEntries().find(entry => entry.type === "custom_message"
          && entry.customType === "subagent_supervisor_request" && (entry.details as { expectsReply?: boolean })?.expectsReply !== false) : undefined;
        const id = (request && "details" in request ? request.details as { requestId?: string } : undefined)?.requestId;
        if (id && !replied.has(id)) {
          replied.add(id);
          return fauxAssistantMessage([fauxToolCall("subagent_supervisor", { action: "reply", replyTo: id, message: "Proceed" }, { id: `reply-${replied.size}` })], { stopReason: "toolUse" });
        }
        if (sessionFile && SessionManager.open(sessionFile).getEntries().some(entry => entry.type === "custom_message"
          && entry.customType === "subagent-notify")) workflowCompletionAcknowledged = true;
        return fauxAssistantMessage("PARENT_COMPLETE");
      }),
    ]);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    registry = new RuntimeRegistry({
      agentDir, tronHome, managedSubagents, delegatedArtifactRoot: delegatedArtifactRoot(tronHome), trust, idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => {
        const runtime = await ModelRuntime.create({ modelsPath: join(agentDir, "models.json"), refreshOnCreate: false });
        runtime.registerNativeProvider(faux.provider);
        return runtime;
      },
      broadcast: (_sessionId, topic, payload) => { if (topic === "session.extensionError") extensionErrors.push(payload.data); }, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    await registry.initialize();
    const slot = await registry.create(cwd);
    await slot.setModel(model.provider, model.id);
    sessionFile = slot.sessionFile;
    const liveSession = (slot as unknown as { runtime: { session: AgentSession } }).runtime.session;
    await slot.prompt("Run the attribution workflow");
    await waitFor(() => {
      facts.entries = SessionManager.open(slot.sessionFile!).getEntries();
      return !liveSession.isStreaming;
    }, "workflow parent settles");
    const readEntries = () => SessionManager.open(slot.sessionFile!).getEntries();
    const userCount = () => readEntries().filter(entry => entry.type === "message" && entry.message.role === "user").length;
    const notes = () => readEntries().filter(entry => entry.type === "custom_message" && entry.customType === "subagent-incremental-child-notify");
    const launch = readEntries().find(entry => entry.type === "message" && entry.message.role === "toolResult" && entry.message.toolCallId === "workflow-launch");
    if (!launch || launch.type !== "message" || launch.message.role !== "toolResult") throw new Error("Missing workflow launch");
    const asyncDir = (launch.message.details as { asyncDir: string }).asyncDir;
    await waitFor(() => replied.size === 1 && notes().length === 1 && !liveSession.isStreaming, "waiting child receives its independent supervisor decision wake and finishes");
    const decisionEntries = readEntries();
    facts.decisionWakeEntries = decisionEntries;
    expect.soft(userCount(), "one maintainer launch and one decision wake").toBe(2);
    const beforeFailureUsers = userCount();
    const beforeFailureNotes = notes().length;
    releaseFailure!(); releaseFailure = undefined;
    await waitFor(() => notes().length > beforeFailureNotes && !liveSession.isStreaming && !slot.snapshot().pendingPrompt, "failed child note is stored while remaining children are gated");
    const realFailure = notes()[beforeFailureNotes];
    const settledEvents = (await readFile(join(asyncDir, "events.jsonl"), "utf8")).trim().split("\n").map(line => JSON.parse(line));
    facts.failedChildEvents = settledEvents;
    expect.soft(settledEvents.some(event => event.type === "subagent.workflow.child_settled" && event.childKey === "lane-1" && event.outcome === "failed" && event.workflowRunning === true)).toBe(true);
    expect.soft(userCount(), "failed incremental note must not admit an idle wake").toBe(beforeFailureUsers);
    facts.failedChildBeforeCompletion = { entry: realFailure, usersBefore: beforeFailureUsers, usersAfter: userCount(), status: JSON.parse(await readFile(join(asyncDir, "status.json"), "utf8")) };
    releaseRemaining!(); releaseRemaining = undefined;
    const types = ["subagent-notify", "subagent-incremental-child-notify", "subagent_supervisor_request"];
    await waitFor(() => {
      facts.entries = readEntries();
      return types.every(type => readEntries().some(entry => entry.type === "custom_message" && entry.customType === type)) && workflowCompletionAcknowledged && !slot.isBusy;
    }, "workflow receives its independent completion wake");
    expect.soft(userCount(), "exactly one internal wake at workflow completion").toBe(beforeFailureUsers + 1);
    const entries = readEntries();
    const realInputs = slot.snapshot().transcript.filter(message => message.kind === "message" && message.role === "user");
    facts.realWakeProjection = realInputs;
    expect.soft(realInputs).toHaveLength(3);
    expect.soft(realInputs[0]).toMatchObject({ semantic: { origin: { kind: "user" } } });
    for (const input of realInputs.slice(1)) expect.soft(input).toMatchObject({ semantic: { kind: "subagentWake", direction: "inboundContext", origin: { kind: "subagent" } } });
    facts.customMessages = entries.filter(entry => entry.type === "custom_message");
    // The released provider's path-first header is ownership, not the compact
    // widget's native detail/coverage contract. Exercise its real four-child file.
    const status = JSON.parse(await readFile(join(asyncDir, "status.json"), "utf8"));
    facts.workflowStatus = status;
    expect.soft(status.lifecycleProjection.sessionId).toBe(slot.sessionFile);
    await slot.discoverExtensionArtifact(asyncDir);
    const native = slot.snapshot().extensionActivities?.find(activity => activity.toolCallId === "workflow-launch")
      ?? extensionActivityReceipts(SessionManager.open(slot.sessionFile!).getEntries(), slot.id).find(value => value.receipt.toolCallId === "workflow-launch");
    facts.workflowNative = native;
    // A terminal workflow is canonical history; capture native process/detail
    // parity on a running R1-shaped version of the actual provider artifact.
    const running = { ...status, state: "running", status: "running", completedAt: undefined, endedAt: undefined,
      lifecycleProjection: { ...status.lifecycleProjection, root: { ...status.lifecycleProjection.root, state: "running", endedAt: undefined } },
      steps: status.steps.map((step: Record<string, unknown>, index: number) => ({ ...step, state: "running", status: "running", endedAt: undefined,
        model: "attribution-child/child", thinking: "high", task: `Task ${index}`, currentPath: "src/owned.ts", output: `Output ${index}`, toolCount: index + 1, turnCount: index + 2 })) };
    const parityRun = `${status.runId}-parity`;
    const parityTool = "parity-launch";
    const parityDir = join(dirname(asyncDir), parityRun);
    running.runId = parityRun;
    running.toolCallId = parityTool;
    running.lifecycleProjection = { ...running.lifecycleProjection, runId: parityRun, toolCallId: parityTool,
      root: { ...running.lifecycleProjection.root, id: parityRun, runId: parityRun } };
    await mkdir(parityDir);
    await writeFile(join(parityDir, "status.json"), JSON.stringify(running));
    const runtimeManager = (slot as unknown as { runtime: { session: AgentSession } }).runtime.session.sessionManager;
    runtimeManager.appendMessage({ role: "toolResult", toolName: "subagent", toolCallId: parityTool, content: [{ type: "text", text: "parity launch" }],
      details: { runId: parityRun, asyncId: parityRun, asyncDir: parityDir, mode: "workflow", state: "running" }, isError: false, timestamp: Date.now() });
    facts.parityStatus = running;
    facts.parityDiscovery = await slot.discoverExtensionArtifact(parityDir);
    facts.parityProcesses = slot.snapshot().processActivities;
    const parity = slot.snapshot().extensionActivities?.find(activity => activity.toolCallId === parityTool);
    facts.parity = parity;
    expect.soft(parity?.children).toHaveLength(4);
    for (let index = 0; index < 4; index++) expect.soft(parity?.children[index]).toMatchObject({ label: "probe", model: "attribution-child/child", thinking: "high",
      currentPath: "owned.ts", output: `Output ${index}`, task: `Task ${index}`, toolCount: index + 1, turnCount: index + 2 });
    expect.soft(slot.snapshot().processActivities?.filter(process => process.toolCallId === parityTool).length ?? 0).toBeGreaterThanOrEqual(4);
    // Coverage/order belongs to full status, independent of the compact header
    // which still contains only the four actual child declarations here.
    const expanded = { ...running, steps: Array.from({ length: 40 }, (_, index) => ({ ...running.steps[index % 4], workflowKey: `bounded-${index}`,
      runId: `bounded-child-${index}`, sessionFile: undefined, sessionOwnerId: undefined, children: [] })) };
    await writeFile(join(parityDir, "status.json"), JSON.stringify(expanded));
    await slot.discoverExtensionArtifact(parityDir);
    const covered = slot.snapshot().extensionActivities?.find(activity => activity.toolCallId === parityTool);
    expect.soft(covered?.children.map(child => child.id)).toEqual(Array.from({ length: 32 }, (_, index) => `bounded-${index}`));
    const nested = { ...expanded, steps: expanded.steps.map((step: Record<string, unknown>, index: number) => ({ ...step,
      children: [0, 1].map(child => ({ agent: "probe", workflowKey: `nested-${index}-${child}`, runId: `nested-run-${index}-${child}`, status: "running", toolCount: 1 })) })) };
    await writeFile(join(parityDir, "status.json"), JSON.stringify(nested));
    await slot.discoverExtensionArtifact(parityDir);
    const tree = slot.snapshot().extensionActivities?.find(activity => activity.toolCallId === parityTool)?.children ?? [];
    const count = (children: typeof tree): number => children.reduce((sum, child) => sum + 1 + count(child.children ?? []), 0);
    expect.soft(count(tree)).toBe(64);
    facts.boundedChildren = covered?.children;
    facts.boundedTree = tree;
    await writeFile(join(parityDir, "status.json"), JSON.stringify({ ...running, state: "completed", endedAt: status.endedAt,
      lifecycleProjection: { ...running.lifecycleProjection, root: { ...running.lifecycleProjection.root, state: "complete", endedAt: status.endedAt } } }));
    await slot.discoverExtensionArtifact(parityDir);
    facts.receipts = entries.filter(entry => entry.type === "custom" && entry.customType === "tron.context-delivery.v4");
    const decodedDeliveries = contextDeliveryMetadataByEntry(entries);
    facts.decodedDeliveries = [...decodedDeliveries];
    expect.soft(decodedDeliveries.get(realFailure.id)).toMatchObject({ delivery: "stored", origin: { owner: { kind: "subagent" } } });
    for (const note of entries.filter(entry => entry.type === "custom_message" && entry.customType === "subagent-incremental-child-notify")) {
      expect.soft(decodedDeliveries.get(note.id)).toMatchObject({ delivery: "stored", origin: { owner: { kind: "subagent" } } });
    }
    for (const type of types) {
      const messages = entries.filter(entry => entry.type === "custom_message" && entry.customType === type);
      expect(messages.length, type).toBeGreaterThan(0);
      for (const message of messages) {
        expect.soft(entries.find(entry => entry.type === "custom" && entry.customType === "tron.context-delivery.v4"
          && (entry.data as { targetEntryId?: string }).targetEntryId === message.id), type)
          .toMatchObject({ data: { origin: { owner: { source: MANAGED_SUBAGENTS_SOURCE, title: "Subagents", kind: "subagent" } } } });
        expect.soft(decodedDeliveries.get(message.id)?.origin?.owner).toMatchObject({ source: MANAGED_SUBAGENTS_SOURCE, kind: "subagent" });
      }
    }
    const projected = slot.snapshot().transcript.filter(message => message.kind === "customMessage");
    facts.projection = projected;
    expect(projected.length).toBeGreaterThan(0);
    for (const row of projected) expect.soft(row).toMatchObject({ semantic: { origin: { kind: "subagent" } } });
    await waitFor(() => workflowCompletionAcknowledged && !slot.isBusy, "parent acknowledges workflow completion before next prompt");
    // Keep the parent loop busy while a distinct real async child completes.
    // The provider must steer its notification, not use its idle wake path.
    let completionLoopStarted = false;
    const completionGate = new Promise<void>(resolve => { release = resolve; });
    faux.setResponses([
      fauxAssistantMessage([fauxToolCall("subagent", { agent: "probe", task: "COMPLETE_ONLY", async: true,
        acceptance: { level: "none", reason: "Read-only completion probe" } }, { id: "async-launch" })], { stopReason: "toolUse" }),
      async () => { completionLoopStarted = true; await completionGate; return fauxAssistantMessage("BUSY_PARENT_COMPLETE"); },
      ...Array.from({ length: 8 }, () => fauxAssistantMessage("NOTIFY_ACK")),
    ]);
    await slot.prompt("Launch an asynchronous completion while busy");
    await waitFor(() => completionLoopStarted, "completion parent loop starts");
    await waitFor(() => {
      facts.completionQueue = liveSession.agent.peekQueuedMessages();
      facts.completionEntries = SessionManager.open(slot.sessionFile!).getEntries();
      facts.completionActivities = slot.snapshot().processActivities;
      return liveSession.agent.peekQueuedMessages().some(message => message.role === "custom" && message.customType === "subagent-notify");
    }, "real completion notification queues behind busy loop");
    release!();
    release = undefined;
    await waitFor(() => !slot.isBusy, "real triggered completion settles");
    const completedEntries = SessionManager.open(slot.sessionFile!).getEntries();
    const completion = completedEntries.findLast(entry => entry.type === "custom_message" && entry.customType === "subagent-notify");
    expect(completion).toBeDefined();
    const completionReceipt = completedEntries.find(entry => entry.type === "custom" && entry.customType === "tron.context-delivery.v4"
      && (entry.data as { targetEntryId?: string }).targetEntryId === completion!.id);
    facts.triggeredCompletion = { message: completion, receipt: completionReceipt };
    expect.soft(completionReceipt).toMatchObject({ data: { delivery: "triggeredTurn", origin: { owner: { source: MANAGED_SUBAGENTS_SOURCE, kind: "subagent" } } } });
    const retainedActivities = extensionActivityReceipts(completedEntries, slot.id).map(entry => entry.receipt)
      .filter(activity => activity.owner?.source === MANAGED_SUBAGENTS_SOURCE);
    expect(retainedActivities.length).toBeGreaterThan(0);
    for (const activity of retainedActivities) expect.soft(activity.owner).toMatchObject({ kind: "subagent" });
    const api = globals.tronAttributionPi;
    delete globals.tronAttributionPi;
    if (!api) throw new Error("Missing real SDK API fixture");
    const owner = producerIdentity(MANAGED_SUBAGENTS_SOURCE, "fixture-producer", "Subagents");
    const managed = managedProducerAPI(api, owner, (content, options, producer) => slot.admitSubagentWake(content, options, producer));
    const send = (type: string, content: Parameters<ExtensionAPI["sendMessage"]>[0]["content"], options?: Parameters<ExtensionAPI["sendMessage"]>[1]) =>
      external.runInAsyncScope(() => managed.sendMessage({ customType: type, content, display: true }, options));
    faux.setResponses(Array.from({ length: 12 }, () => fauxAssistantMessage("BOUNDARY_COMPLETE")));
    send("idle-stored", "idle stored", { triggerTurn: false });
    await waitFor(() => SessionManager.open(slot.sessionFile!).getEntries().some(entry => entry.type === "custom" && entry.customType === "tron.context-delivery.v4"
      ), "idle stored receipt");
    send("idle-triggered", "idle triggered", { triggerTurn: true });
    await waitFor(() => !slot.isBusy, "idle triggered settles");
    let started = false;
    const blocked = new Promise<void>(resolve => { release = resolve; });
    faux.setResponses([async () => { started = true; await blocked; return fauxAssistantMessage("BUSY_COMPLETE"); },
      ...Array.from({ length: 12 }, () => fauxAssistantMessage("QUEUED_COMPLETE"))]);
    await withExtensionOwner({ id: "foreign-loop", title: "Other producer", source: "fixture:foreign-loop", kind: "extension" },
      () => slot.prompt("Hold the loop until detached producer sends"));
    await waitFor(() => started, "busy loop starts");
    const reused = [{ type: "text" as const, text: "reused array" }];
    send("busy-steer", reused, { triggerTurn: true, deliverAs: "steer" });
    send("busy-followup", reused, { triggerTurn: true, deliverAs: "followUp" });
    send("busy-stored", "busy stored", { triggerTurn: false });
    // A competing producer using the same input array must not overwrite the
    // first sends' identity while those messages are still queued.
    const otherOwner = producerIdentity(MANAGED_SUBAGENTS_SOURCE, "other-fixture", "Subagents");
    const other = managedProducerAPI(api, otherOwner);
    external.runInAsyncScope(() => other.sendMessage({ customType: "busy-other", content: reused, display: true }, { triggerTurn: true, deliverAs: "followUp" }));
    release();
    release = undefined;
    await waitFor(() => !slot.isBusy, "queued messages settle");
    const boundaryEntries = SessionManager.open(slot.sessionFile!).getEntries();
    facts.boundaryEntries = boundaryEntries;
    for (const [type, expectedOwner, delivery] of [["idle-stored", owner, "stored"], ["idle-triggered", owner, "triggeredTurn"],
      ["busy-steer", owner, "triggeredTurn"], ["busy-followup", owner, "triggeredTurn"], ["busy-stored", owner, "stored"],
      ["busy-other", otherOwner, "triggeredTurn"]] as const) {
      const entry = boundaryEntries.find(entry => entry.type === "custom_message" && entry.customType === type
        || entry.type === "message" && entry.message.role === "custom" && entry.message.customType === type);
      expect(entry, type).toBeDefined();
      expect.soft(boundaryEntries.find(receipt => receipt.type === "custom" && receipt.customType === "tron.context-delivery.v4"
        && (receipt.data as { targetEntryId?: string }).targetEntryId === entry!.id), type).toMatchObject({ data: { delivery, origin: { owner: expectedOwner } } });
      if (entry?.type === "custom_message") {
        // The transient carrier must not change the persisted content schema.
        if (type === "idle-stored" || type === "idle-triggered" || type === "busy-stored") expect(typeof entry.content, type).toBe("string");
        else expect(entry.content, type).toEqual(reused);
      }
    }
    // Per-child notes are always context, even if an emitter requests a turn
    // or supplies outcome metadata. Independent typed sources carry wakes.
    const sendIncremental = (outcome: string, workflowRunning: boolean) => external.runInAsyncScope(() => managed.sendMessage({
      customType: "subagent-incremental-child-notify", content: `typed-${outcome}-${workflowRunning}`, display: true,
      details: { outcome, workflowRunning },
    }, { triggerTurn: true }));
    const assistantCount = () => SessionManager.open(slot.sessionFile!).getEntries().filter(entry => entry.type === "message" && entry.message.role === "assistant").length;
    const before = assistantCount();
    for (const outcome of ["failed", "stopped", "completed", "paused"]) sendIncremental(outcome, true);
    sendIncremental("failed", false);
    await waitFor(() => SessionManager.open(slot.sessionFile!).getEntries().filter(entry => entry.type === "custom_message" && typeof entry.content === "string" && entry.content.startsWith("typed-")).length === 5, "all incremental context stored");
    expect.soft(assistantCount(), "all incremental notes remain context").toBe(before);
    const progress = entries.find(entry => entry.type === "custom_message" && entry.customType === "subagent_supervisor_request" && (entry.details as { expectsReply?: boolean })?.expectsReply === false);
    expect.soft(progress, "real supervisor progress stored").toBeDefined();
    if (progress) expect.soft(decodedDeliveries.get(progress.id)).toMatchObject({ delivery: "stored", origin: { owner: { kind: "subagent" } } });

    // A foreground workflow already returns through the active parent tool
    // loop. No independent user/wake admission is needed for completion.
    const beforeForeground = readEntries().length;
    const beforeForegroundUsers = userCount();
    faux.setResponses([
      fauxAssistantMessage([fauxToolCall("subagent", { workflow: "./foreground.js", async: false, mission: false,
        acceptance: { level: "none", reason: "Read-only foreground probe" } }, { id: "foreground-workflow-launch" })], { stopReason: "toolUse" }),
      fauxAssistantMessage("FOREGROUND_RESULT_CONSUMED"),
    ]);
    await slot.prompt("Run a foreground workflow");
    await waitFor(() => !slot.isBusy, "foreground workflow returns through its tool result");
    const foregroundEntries = readEntries().slice(beforeForeground);
    facts.foregroundWorkflowEntries = foregroundEntries;
    expect.soft(userCount()).toBe(beforeForegroundUsers + 1);
    expect.soft(foregroundEntries.find(entry => entry.type === "message" && entry.message.role === "toolResult" && entry.message.toolCallId === "foreground-workflow-launch"))
      .toMatchObject({ message: { isError: false, details: { mode: "workflow", results: [expect.objectContaining({ agent: "probe", exitCode: 0 })] } } });
    expect.soft(foregroundEntries.find(entry => entry.type === "message" && entry.message.role === "assistant" && JSON.stringify(entry.message.content).includes("FOREGROUND_RESULT_CONSUMED"))).toBeDefined();

    // A quiet recurring schedule suppresses routine success, not failure.
    // Fire it manually under the same quiet completion policy while the real
    // parent is busy, then consume its independent notification in that loop.
    const beforeScheduled = readEntries().length;
    let scheduledParentStarted = false;
    const scheduledGate = new Promise<void>(resolve => { release = resolve; });
    faux.setResponses([
      fauxAssistantMessage([fauxToolCall("subagent", { action: "schedule.create", id: "quiet-failure-probe", workflow: "./quiet-failure.js",
        every: "1h", quiet: true, sessionOnly: true }, { id: "schedule-create" })], { stopReason: "toolUse" }),
      fauxAssistantMessage([fauxToolCall("subagent", { action: "schedule.run", id: "quiet-failure-probe", quiet: true }, { id: "schedule-run" })], { stopReason: "toolUse" }),
      async () => { scheduledParentStarted = true; await scheduledGate; return fauxAssistantMessage("SCHEDULE_PARENT_COMPLETE"); },
      ...Array.from({ length: 4 }, () => fauxAssistantMessage("SCHEDULE_COMPLETION_ACK")),
    ]);
    await slot.prompt("Fire the quiet failed workflow schedule");
    await waitFor(() => scheduledParentStarted, "scheduled parent loop starts");
    await waitFor(() => liveSession.agent.peekQueuedMessages().some(message => message.role === "custom" && message.customType === "subagent-notify"), "quiet failed workflow completion independently queues a turn");
    release!(); release = undefined;
    await waitFor(() => !slot.isBusy, "quiet failed completion settles");
    const scheduledEntries = readEntries().slice(beforeScheduled);
    facts.quietScheduledFailureEntries = scheduledEntries;
    for (const toolCallId of ["schedule-create", "schedule-run"]) expect.soft(scheduledEntries.find(entry => entry.type === "message" && entry.message.role === "toolResult" && entry.message.toolCallId === toolCallId))
      .toMatchObject({ message: { isError: false } });
    const scheduledCompletion = scheduledEntries.find(entry => entry.type === "custom_message" && entry.customType === "subagent-notify");
    expect(scheduledCompletion).toBeDefined();
    expect.soft(contextDeliveryMetadataByEntry(readEntries()).get(scheduledCompletion!.id))
      .toMatchObject({ delivery: "triggeredTurn", origin: { owner: { kind: "subagent" } } });
    const scheduleRun = scheduledEntries.find(entry => entry.type === "message" && entry.message.role === "toolResult" && entry.message.toolCallId === "schedule-run");
    facts.quietScheduleRunResult = scheduleRun;
    if (!scheduleRun || scheduleRun.type !== "message" || scheduleRun.message.role !== "toolResult") throw new Error("Missing quiet scheduled launch result");
    const scheduledAsyncDir = (scheduleRun.message.details as { schedules: { runs: Array<{ asyncDir: string }> } }).schedules.runs[0].asyncDir;
    const scheduledStatus = JSON.parse(await readFile(join(scheduledAsyncDir, "status.json"), "utf8"));
    facts.quietScheduledStatus = scheduledStatus;
    expect.soft(scheduledStatus).toMatchObject({ state: "failed", scheduleOrigin: { id: "quiet-failure-probe", quiet: true } });

    // Internal wakes use the exact same owner as prompt/queue invocation
    // binding, including a concurrent maintainer prompt and queue consumption.
    faux.setResponses(Array.from({ length: 12 }, () => fauxAssistantMessage("WAKE_COMPLETE")));
    globals.tronWakeInputGate = new Promise<void>(resolve => { release = resolve; });
    external.runInAsyncScope(() => managed.sendUserMessage("idle-wake-marker", { deliverAs: "steer" }));
    await waitFor(() => globals.tronWakeInputStarted === true, "idle wake preflight hook");
    expect.soft(slot.snapshot().pendingPrompt).toMatchObject({ semantic: { kind: "subagentWake", origin: { kind: "subagent", ownerId: owner.id } } });
    release!(); release = undefined;
    delete globals.tronWakeInputGate; delete globals.tronWakeInputStarted;
    await waitFor(() => slot.snapshot().transcript.some(item => item.kind === "message" && item.role === "user" && JSON.stringify(item.content).includes("idle-wake-marker")) && !slot.isBusy, "idle wake settles");
    let wakeLoopStarted = false;
    const wakeGate = new Promise<void>(resolve => { release = resolve; });
    faux.setResponses([async () => { wakeLoopStarted = true; await wakeGate; return fauxAssistantMessage("WAKE_BUSY"); },
      ...Array.from({ length: 12 }, () => fauxAssistantMessage("WAKE_QUEUED_COMPLETE"))]);
    await slot.prompt("maintainer-marker");
    await waitFor(() => wakeLoopStarted, "wake busy parent starts");
    external.runInAsyncScope(() => managed.sendUserMessage("busy-wake-marker", { deliverAs: "steer" }));
    const racing = slot.prompt("racing-maintainer-marker", [], "steer");
    await racing;
    await waitFor(() => liveSession.getSteeringMessages().length >= 2, "both owners queued");
    facts.wakeQueue = slot.snapshot().queuedItems;
    expect.soft(slot.snapshot().queuedItems.find(item => item.text === "busy-wake-marker")).toMatchObject({ semantic: { kind: "subagentWake", origin: { kind: "subagent", ownerId: owner.id } } });
    release!(); release = undefined;
    await waitFor(() => !slot.isBusy, "wake and maintainer queue settle");
    const wakeProjection = slot.snapshot().transcript;
    facts.wakeProjection = wakeProjection;
    for (const marker of ["idle-wake-marker", "busy-wake-marker"]) expect.soft(wakeProjection.find(item => item.kind === "message" && item.role === "user" && JSON.stringify(item.content).includes(marker)))
      .toMatchObject({ semantic: { kind: "subagentWake", origin: { kind: "subagent", ownerId: owner.id }, direction: "inboundContext" } });
    for (const marker of ["maintainer-marker", "racing-maintainer-marker"]) expect.soft(wakeProjection.find(item => item.kind === "message" && item.role === "user" && JSON.stringify(item.content).includes(marker)))
      .toMatchObject({ semantic: { origin: { kind: "user" } } });
    const wakeEntries = SessionManager.open(slot.sessionFile!).getEntries();
    facts.wakeEntries = wakeEntries;
    expect.soft(wakeEntries.filter(entry => entry.type === "custom_message" && entry.customType === "wake-hook-proof").length).toBeGreaterThanOrEqual(2);
    for (const source of ["npm:pi-subagents", "npm:pi-subagents@0.59.0", "tron:pi-subagents@0.76.1-tron.4#" + "a".repeat(128)]) {
      const historicalOwner = { id: `historic-${source.slice(0, 35)}`, title: "Pi Subagents", source };
      const entryId = runtimeManager.appendCustomMessageEntry("historic-provider-context", "Captured historic context", true);
      runtimeManager.appendCustomEntry(CONTEXT_DELIVERY_RECEIPT_TYPE, makeContextDeliveryReceipt(entryId, "stored", { source, owner: historicalOwner }));
      const context = contextDeliveryMetadataByEntry(runtimeManager.getEntries()).get(entryId);
      expect.soft(context?.origin?.owner, source).toMatchObject({ kind: "subagent" });
      expect.soft(slot.snapshot().transcript.find(item => item.id === entryId), source).toMatchObject({ semantic: { origin: { kind: "subagent" } } });
      const terminal = makeExtensionActivityReceipt({ id: entryId, toolCallId: entryId, title: "Subagents", source: { source, owner: historicalOwner }, status: "completed", children: [],
        startedAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:01.000Z", completedAt: "2026-01-01T00:00:01.000Z" }, slot.id)!;
      runtimeManager.appendCustomEntry(EXTENSION_ACTIVITY_RECEIPT_TYPE, terminal);
      expect.soft(extensionActivityReceipts(runtimeManager.getEntries(), slot.id).find(value => value.receipt.activityId === entryId)?.receipt.owner, source).toMatchObject({ kind: "subagent" });
    }
    facts.historicalReceipts = runtimeManager.getEntries().filter(entry => entry.type === "custom" && [CONTEXT_DELIVERY_RECEIPT_TYPE, EXTENSION_ACTIVITY_RECEIPT_TYPE].includes(entry.customType));
    const beforeDispose = SessionManager.open(slot.sessionFile!).getEntries().length;
    await registry.dispose();
    external.runInAsyncScope(() => managed.sendUserMessage("post-dispose-wake-marker", { deliverAs: "steer" }));
    await waitFor(() => extensionErrors.some(error => { const event = error as { code?: string; owner?: { id?: string } };
      return event.code === "subagent-wake-admission-failed" && event.owner?.id === owner.id; }), "disposed wake admission reported for exact owner");
    expect.soft(SessionManager.open(slot.sessionFile!).getEntries().length).toBe(beforeDispose);
    facts.extensionErrors = extensionErrors;
    facts.assertionFailures = task.result?.errors?.map(error => error.message) ?? [];
    facts.passed = !task.result?.errors?.length;
  } finally {
    releaseFailure?.(); releaseRemaining?.();
    release?.();
    external.emitDestroy();
    delete globals.tronAttributionPi;
    delete globals.tronWakeInputGate; delete globals.tronWakeInputStarted;
    try { await registry?.dispose(); }
    finally {
      prototype.spawn = spawn;
      let cleanupError: unknown;
      try {
        for (const child of children) {
          if (child.exitCode !== null || child.signalCode !== null) continue;
          child.kill("SIGTERM");
          await waitFor(() => child.exitCode !== null || child.signalCode !== null, "fixture child joins its detached descendants", { boundMs: 6_000 });
        }
        const failure = await readFile(join(root, "process-owner-failure.jsonl"), "utf8").catch(error => {
          if (error.code === "ENOENT") return "";
          throw error;
        });
        if (failure) throw new Error(`Fixture process join failed: ${failure}`);
      } catch (error) { cleanupError = error; }
      try {
        if (server) await new Promise<void>((resolve, reject) => server!.close(error => error ? reject(error) : resolve()));
      } catch (error) { cleanupError ??= error; }
      names.forEach((name, index) => { if (previous[index] === undefined) delete process.env[name]; else process.env[name] = previous[index]; });
      // A failed recursive join must not delete files a child could still own.
      if (cleanupError) { facts.passed = false; facts.cleanupError = String(cleanupError); facts.preservedFixture = root; }
      else await rm(root, { recursive: true, force: true });
      const report = process.env.TRON_ATTRIBUTION_REPORT ?? join(process.cwd(), "test-results", "managed-attribution.integration.json");
      await mkdir(dirname(report), { recursive: true });
      await writeFile(report, `${JSON.stringify(facts, null, 2)}\n`);
      if (cleanupError) throw cleanupError;
    }
  }
}, 60_000);
