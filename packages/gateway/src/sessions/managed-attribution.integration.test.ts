import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { createServer, type Server } from "node:http";
import { dirname, join } from "node:path";
import { ModelRuntime, SessionManager, type AgentSession, type ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall } from "@earendil-works/pi-ai";
import { expect, it } from "vitest";
import { TrustService } from "../admin/trust-service.js";
import { ManagedSubagents, MANAGED_SUBAGENTS_SOURCE } from "./managed-subagents.js";
import { delegatedArtifactRoot, delegatedProviderEnvironment } from "./delegated-provider.js";
import { RuntimeRegistry } from "./runtime-registry.js";
import { waitFor } from "../../test-support/wait-for.js";
import { managedProducerAPI } from "../extensions/managed-producer.js";
import { producerIdentity, withExtensionOwner } from "../extensions/owner-attribution.js";
import { AsyncResource } from "node:async_hooks";
import { ChildProcess } from "node:child_process";
import { fileURLToPath } from "node:url";
import { contextDeliveryMetadataByEntry } from "./context-delivery-receipts.js";
import { extensionActivityReceipts } from "./extension-activity-history.js";

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
  const external = new AsyncResource("managed-attribution-external-producer");
  const globals = globalThis as typeof globalThis & { tronAttributionPi?: ExtensionAPI };
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
  try {
    await mkdir(agentDir);
    await mkdir(join(cwd, ".pi", "agents"), { recursive: true });
    await writeFile(join(agentDir, "capture.mjs"), `export default pi => { globalThis.tronAttributionPi = pi; };`);
    await writeFile(join(agentDir, "settings.json"), JSON.stringify({ extensions: ["capture.mjs"] }));
    process.env.PI_CODING_AGENT_DIR = agentDir;
    process.env.TRON_TEST_PROCESS_OWNER = root;
    process.env.TRON_TEST_PROCESS_OWNER_FAILURE = join(root, "process-owner-failure.jsonl");
    const preload = fileURLToPath(new URL("../../test-support/fixture-process-owner.mjs", import.meta.url));
    process.env.NODE_OPTIONS = `${process.env.NODE_OPTIONS ?? ""} --import=${preload}`.trim();
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
      const alreadyRequested = messages.some(message => message.role === "tool") || JSON.stringify(messages).includes("COMPLETE_ONLY");
      const delta = alreadyRequested ? { content: "CHILD_COMPLETE" } : { tool_calls: [{ index: 0, id: "progress", type: "function",
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
    await writeFile(join(cwd, "workflow.js"), `return runs.run("probe", {agent:"probe", task:"Send attribution progress and return CHILD_COMPLETE", acceptance:{level:"none",reason:"Read-only attribution probe"}});`);
    const replied = new Set<string>();
    let sessionFile: string | undefined;
    let workflowCompletionAcknowledged = false;
    faux.setResponses([
      fauxAssistantMessage([fauxToolCall("subagent", { workflow: "./workflow.js", async: true, mission: false,
        acceptance: { level: "none", reason: "Read-only attribution probe" } }, { id: "workflow-launch" })], { stopReason: "toolUse" }),

      ...Array.from({ length: 8 }, () => () => {
        const request = sessionFile ? SessionManager.open(sessionFile).getEntries().find(entry => entry.type === "custom_message"
          && entry.customType === "subagent_supervisor_request") : undefined;
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
      agentDir, tronHome, managedSubagents, trust, idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => {
        const runtime = await ModelRuntime.create({ modelsPath: join(agentDir, "models.json"), refreshOnCreate: false });
        runtime.registerNativeProvider(faux.provider);
        return runtime;
      },
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    await registry.initialize();
    const slot = await registry.create(cwd);
    await slot.setModel(model.provider, model.id);
    sessionFile = slot.sessionFile;
    await slot.prompt("Run the attribution workflow");
    await waitFor(() => {
      facts.entries = SessionManager.open(slot.sessionFile!).getEntries();
      return !slot.isBusy;
    }, "workflow settles");
    facts.entries = SessionManager.open(slot.sessionFile!).getEntries();
    const types = ["subagent-notify", "subagent-incremental-child-notify", "subagent_supervisor_request"];
    await waitFor(() => {
      const session = SessionManager.open(slot.sessionFile!);
      facts.entries = session.getEntries();
      return types.every(type => session.getEntries().some(entry => entry.type === "custom_message" && entry.customType === type));
    }, "all real provider custom messages");
    const session = SessionManager.open(slot.sessionFile!);
    const entries = session.getEntries();
    facts.customMessages = entries.filter(entry => entry.type === "custom_message");
    facts.receipts = entries.filter(entry => entry.type === "custom" && entry.customType === "tron.context-delivery.v4");
    const decodedDeliveries = contextDeliveryMetadataByEntry(entries);
    facts.decodedDeliveries = [...decodedDeliveries];
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
    const liveSession = (slot as unknown as { runtime: { session: AgentSession } }).runtime.session;
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
    const managed = managedProducerAPI(api, owner);
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
    facts.assertionFailures = task.result?.errors?.map(error => error.message) ?? [];
    facts.passed = !task.result?.errors?.length;
  } finally {
    release?.();
    external.emitDestroy();
    delete globals.tronAttributionPi;
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
