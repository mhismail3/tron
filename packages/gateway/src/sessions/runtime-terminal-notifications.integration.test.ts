import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { once } from "node:events";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall, type FauxResponseStep } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it, vi } from "vitest";
import { TrustService } from "../admin/trust-service.js";
import { NotificationGrantStore } from "../notifications/grant-store.js";
import { NotificationService } from "../notifications/notification-service.js";
import { PushRelayClient, relaySignature } from "../notifications/relay-client.js";
import { GatewayLogger } from "../transport/logger.js";
import { ManagedSubagents } from "./managed-subagents.js";
import { delegatedArtifactRoot, delegatedProviderEnvironment, DELEGATED_PROVIDER_ROOT_ENV } from "./delegated-provider.js";
import { RuntimeRegistry } from "./runtime-registry.js";
import type { RuntimeSlot } from "./runtime-slot.js";
import { INVOCATION_RECEIPT_TYPE } from "./invocation-receipts.js";
import { waitFor } from "../../test-support/wait-for.js";

function barrier() {
  let release!: () => void;
  const promise = new Promise<void>((resolve) => { release = resolve; });
  return { promise, release };
}

describe.sequential("automatic terminal notifications with the pinned runtime", () => {
  const cleanup: Array<() => Promise<void>> = [];
  const originalEnvironment = Object.fromEntries([
    "PI_CODING_AGENT_DIR", DELEGATED_PROVIDER_ROOT_ENV, "PI_SUBAGENTS_PI_CODING_AGENT_PACKAGE_ROOT",
  ].map((name) => [name, process.env[name]]));
  afterEach(async () => {
    for (const release of cleanup.splice(0).reverse()) await release();
    for (const [name, value] of Object.entries(originalEnvironment)) {
      if (value === undefined) delete process.env[name];
      else process.env[name] = value;
    }
  });

  async function fixture(responses: FauxResponseStep[], options: {
    retry?: { enabled: boolean; maxRetries: number; baseDelayMs: number };
    extension?: string;
    observed?: boolean;
    notifications?: NotificationService;
    managedSubagents?: (tronHome: string) => ManagedSubagents;
    extraProviders?: Array<ReturnType<typeof fauxProvider>["provider"]>;
    model?: { provider: string; id: string };
    setup?: (input: { agentDir: string; cwd: string; trust: TrustService }) => Promise<void>;
  } = {}) {
    const root = await mkdtemp(join(tmpdir(), "tron-terminal-notification-"));
    cleanup.push(() => rm(root, { recursive: true, force: true }));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    process.env.PI_CODING_AGENT_DIR = agentDir;
    await writeFile(join(agentDir, "settings.json"), JSON.stringify({
      retry: options.retry ?? { enabled: false },
      compaction: { enabled: false },
    }));
    const trust = new TrustService(agentDir);
    if (options.setup) await options.setup({ agentDir, cwd, trust });
    if (options.extension) {
      const dir = join(cwd, ".pi", "extensions");
      await mkdir(dir, { recursive: true });
      await writeFile(join(dir, "terminal-test.ts"), options.extension);
      await trust.set(cwd, true);
    }
    const tronHome = join(root, "tron");
    const managedSubagents = options.managedSubagents?.(tronHome);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    const faux = fauxProvider({ provider: "tron-terminal-test", tokensPerSecond: 10_000 });
    faux.setResponses(responses);
    runtime.registerNativeProvider(faux.provider);
    for (const provider of options.extraProviders ?? []) runtime.registerNativeProvider(provider);
    let slot!: RuntimeSlot;
    const canonicalAtAdmission: any[][] = [];
    const persistedAtAdmission: Array<any[] | undefined> = [];
    const enqueue = vi.fn(async (_input: any) => {
      // Take the branch cut synchronously: an asynchronous file read alone could
      // see a receipt appended AFTER premature notification admission.
      canonicalAtAdmission.push([...(slot as unknown as { sessionManager: { getBranch(): any[] } }).sessionManager.getBranch()]);
      try {
        persistedAtAdmission.push((await readFile(slot.sessionFile!, "utf8")).trim().split("\n").map((line) => JSON.parse(line)));
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
        // Pi buffers a new session until its first assistant. Keep this explicit
        // rather than claiming a no-model first invocation reached disk.
        persistedAtAdmission.push(undefined);
      }
      return "queued" as const;
    });
    const suppressAutomatic = vi.fn(async () => "suppressed" as const);
    const registry = new RuntimeRegistry({
      agentDir, tronHome, idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime, trust,
      ...(managedSubagents ? { managedSubagents } : {}),
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
      machineId: "machine-terminal-test",
      notifications: options.notifications ?? { enqueue, suppressAutomatic, markSessionInboxRead: vi.fn(async () => {}) } as unknown as NotificationService,
    });
    cleanup.push(() => registry.dispose());
    await registry.initialize();
    slot = await registry.create(cwd);
    const model = options.model ?? faux.getModel();
    await slot.setModel(model.provider, model.id);
    const sdkEvents: string[] = [];
    const onEvent = (slot as unknown as { onEvent: (event: { type: string }) => void }).onEvent.bind(slot);
    vi.spyOn(slot as unknown as { onEvent: (event: { type: string }) => void }, "onEvent").mockImplementation((event) => {
      if (event.type === "agent_start" || event.type === "agent_end" || event.type === "agent_settled") sdkEvents.push(event.type);
      onEvent(event);
    });
    if (options.observed) {
      registry.subscribe("phone", slot.id);
      registry.setPresentationVisibility({
        clientId: "phone", sessionId: slot.id, subscriptionToken: "subscription", revision: 1, visible: true,
      });
    }
    const settle = async () => {
      await waitFor(() => !slot.isBusy, "the slot to go idle");
      await waitFor(() => enqueue.mock.calls.length + suppressAutomatic.mock.calls.length > 0, "the title refresh");
      // A mock call is visible before its async admission recorder settles.
      await Promise.allSettled(enqueue.mock.results.map((result) => result.value));
    };
    return { slot, registry, faux, enqueue, suppressAutomatic, settle, canonicalAtAdmission, persistedAtAdmission, sdkEvents };
  }

  it.each([
    ["stop", "The agent finished responding.", "completed"],
    ["length", "The agent reached its response limit.", "completed"],
    ["error", "The agent stopped because of an error.", "failed"],
    ["aborted", "The agent was stopped.", "interrupted"],
    ["toolUse", "The agent stopped without a final response.", "outcomeUnknown"],
  ] as const)("notifies exactly once for final %s, after its canonical terminal receipt", async (stopReason, message, lifecycle) => {
    const value = await fixture([fauxAssistantMessage("private response", { stopReason, errorMessage: "private provider detail" })]);
    await value.slot.prompt("terminal request");
    await value.settle();
    const entries = value.canonicalAtAdmission[0]!;
    const assistant = entries.findLast((entry) => entry.type === "message" && entry.message.role === "assistant");
    expect(value.enqueue).toHaveBeenCalledExactlyOnceWith({
      sessionId: value.slot.id, sourceId: assistant.id, kind: "agent_finished",
      title: "terminal request", message, route: { sessionId: value.slot.id, machineId: "machine-terminal-test" },
    });
    const ownsTerminal = (entry: any) => entry.type === "custom" && entry.customType === INVOCATION_RECEIPT_TYPE
      && entry.data.receiptKind === "terminal" && entry.data.lifecycle === lifecycle;
    expect(entries.some(ownsTerminal)).toBe(true);
    expect(value.persistedAtAdmission[0]?.some(ownsTerminal)).toBe(true);
    expect(value.suppressAutomatic).not.toHaveBeenCalled();
    (value.slot as unknown as { onEvent(event: { type: "agent_settled" }): void }).onEvent({ type: "agent_settled" });
    expect(value.enqueue).toHaveBeenCalledTimes(1);
  });

  it("sends terminal and input notifications through the Gateway store to a local fake relay", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-notification-e2e-"));
    cleanup.push(() => rm(root, { recursive: true, force: true }));
    const store = new NotificationGrantStore(root);
    await store.initialize();
    const logger = new GatewayLogger();
    const received: Array<{ envelope: Record<string, unknown>; requestId: string; signatureValid: boolean }> = [];
    let routineCount = 1_000;
    const relayServer = createServer(async (request, response) => {
      const chunks: Buffer[] = [];
      for await (const chunk of request) chunks.push(Buffer.from(chunk));
      const body = Buffer.concat(chunks).toString("utf8");
      const envelope = JSON.parse(body) as Record<string, unknown>;
      const requestId = request.headers["x-tron-request-id"] as string;
      expect(envelope.requestId).toBe(requestId);
      expect(received.some((entry) => entry.requestId === requestId)).toBe(false);
      const signatureValid = request.headers["x-tron-signature"] === relaySignature(
        Buffer.alloc(32, 9).toString("base64url"), "POST", "/v3/notifications",
        request.headers["x-tron-timestamp"] as string, requestId, body,
      );
      received.push({ envelope, requestId, signatureValid });
      if (envelope.notificationKind !== "ask" && envelope.notificationKind !== "explicit") routineCount += 1;
      const rateLimited = envelope.notificationKind !== "ask" && envelope.notificationKind !== "explicit" && routineCount > 1_000;
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify(rateLimited
        ? { status: "rate_limited", reason: "daily_limit" }
        : { status: "accepted_by_apns", apnsId: `apns-${requestId}` }));
    });
    relayServer.listen(0, "127.0.0.1");
    await once(relayServer, "listening");
    cleanup.push(async () => { relayServer.close(); await once(relayServer, "close"); });
    const address = relayServer.address();
    if (!address || typeof address === "string") throw new Error("fake relay did not bind a TCP port");
    const relay = new PushRelayClient("https://push.example.test", async (_url, init) =>
      await fetch(`http://127.0.0.1:${address.port}/v3/notifications`, init) as never);
    const signals: Array<{ kind: string; outcome: string; relayReason: string }> = [];
    const notifications = new NotificationService(
      store, relay, Date.now, () => {}, () => {}, (signal) => {
        signals.push(signal);
        logger.log(signal.outcome === "failed" || signal.outcome === "refused" ? "warning" : "info", "Push notification delivery", {
          event: `notification.push.${signal.outcome.replaceAll("_", "-")}`,
          source: "notifications", kind: signal.kind, outcome: signal.outcome, reason: signal.relayReason,
        });
      },
    );
    cleanup.push(async () => notifications.dispose());
    await notifications.initialize();
    await notifications.upsertGrant({
      deviceId: "device_abcdefgh", installationId: "install_abcdefgh", grantId: "grant_abcdefgh",
      secret: Buffer.alloc(32, 9).toString("base64url"), previewsEnabled: true,
      relayOrigin: "https://push.example.test", notifyWhenAskPresented: true,
      notifyWhenFinished: true, notifyWhenWaiting: true,
    });
    const childStarted = barrier();
    const releaseChild = barrier();
    const childProvider = fauxProvider({ provider: "tron-terminal-child", tokensPerSecond: 10_000 });
    childProvider.setResponses([async () => {
      childStarted.release();
      await releaseChild.promise;
      return fauxAssistantMessage("CHILD_OFFLINE_COMPLETE");
    }]);
    const value = await fixture([
      fauxAssistantMessage([fauxToolCall("subagent", {
        agent: "offline-worker", task: "Return CHILD_OFFLINE_COMPLETE", async: true,
        acceptance: { level: "none", reason: "Bounded notification regression" },
      }, { id: "notification-subagent-launch" })], { stopReason: "toolUse" }),
      fauxAssistantMessage("The background task is still running."),
      fauxAssistantMessage("The background task remains active."),
      fauxAssistantMessage("The background task is complete."),
      fauxAssistantMessage("The ordinary request is complete."),
    ], {
      notifications,
      extraProviders: [childProvider.provider],
      managedSubagents: (tronHome) => {
        delegatedProviderEnvironment(delegatedArtifactRoot(tronHome));
        return ManagedSubagents.activateForStartup(tronHome, logger);
      },
      setup: async ({ cwd, trust }) => {
        await mkdir(join(cwd, ".pi", "agents"), { recursive: true });
        await writeFile(join(cwd, ".pi", "agents", "offline-worker.md"),
          `---\nname: offline-worker\ndescription: Offline notification regression\nmodel: ${childProvider.getModel().provider}/${childProvider.getModel().id}\ntools: read\n---\nReturn the requested completion marker.\n`);
        await trust.set(cwd, true);
      },
    });
    try {
      const resources = await value.slot.resources() as unknown as { tools: Array<{ name: string }> };
      expect(resources.tools.some(({ name }) => name === "subagent")).toBe(true);
      await notifications.userInputRequired({ sessionId: value.slot.id, interactionId: "ask-e2e", observed: false, machineId: "machine-terminal-test" });
      await waitFor(() => received.some(({ envelope }) => envelope.notificationKind === "ask"), "the input-needed relay delivery");
      expect(received.find(({ envelope }) => envelope.notificationKind === "ask")?.envelope).toMatchObject({
        title: "Input needed", message: "Tron needs your input. Open Tron to respond.", interruptionLevel: "time-sensitive",
      });

      const first = value.slot.prompt("background task");
      await childStarted.promise;
      await first;
      await waitFor(() => value.slot.snapshot().extensionActivities?.some((activity) =>
        activity.source.owner?.id === "extension:pi-subagents" && activity.lifecycle?.state === "running") === true,
      "the real managed subagent activity");
      await waitFor(() => received.some(({ envelope }) => envelope.notificationKind === "waiting"), "the waiting notification");
      expect(received.find(({ envelope }) => envelope.notificationKind === "waiting")?.envelope).toMatchObject({
        title: "background task", message: "The agent is waiting on 1 background task.",
      });

      const intermediate = value.slot.prompt("background task still pending");
      await intermediate;
      await waitFor(() => value.sdkEvents.filter((event) => event === "agent_settled").length >= 2, "the intermediate wake-up response to settle");
      expect(received.filter(({ envelope }) => envelope.notificationKind === "waiting")).toHaveLength(1);
      expect(received.filter(({ envelope }) => envelope.notificationKind === "agent_finished")).toHaveLength(0);

      releaseChild.release();
      await waitFor(() => received.filter(({ envelope }) => envelope.notificationKind === "agent_finished").length === 1, "the final background completion");
      expect(received.find(({ envelope }) => envelope.notificationKind === "agent_finished")?.envelope).toMatchObject({
        title: "background task", message: "The agent finished responding.",
      });
      expect(received.every(({ signatureValid }) => signatureValid)).toBe(true);
      await value.slot.prompt("ordinary finished task");
      await waitFor(() => received.filter(({ envelope }) => envelope.notificationKind === "agent_finished").length === 2, "the ordinary truly-finished notification");
      expect(received.map(({ envelope }) => envelope.notificationKind)).toEqual(["ask", "waiting", "agent_finished", "agent_finished"]);
      expect((await notifications.inbox()).notifications.map(({ kind, title, message }) => ({ kind, title, message })))
        .toEqual([
          { kind: "agent_finished", title: "background task", message: "The agent finished responding." },
          { kind: "agent_finished", title: "background task", message: "The agent finished responding." },
          { kind: "waiting", title: "background task", message: "The agent is waiting on 1 background task." },
          { kind: "ask", title: "Input needed", message: "Tron needs your input. Open Tron to respond." },
        ]);

      // The relay is already at its device daily backstop. A routine refusal is terminal,
      // observable, retained in the inbox, and does not prevent the ask exemption.
      await notifications.enqueue({ sessionId: value.slot.id, sourceId: "routine-over-cap", kind: "agent_finished", title: "Routine", message: "Finished." });
      await waitFor(() => signals.some(({ relayReason }) => relayReason === "daily_limit"), "the cap refusal signal");
      await notifications.userInputRequired({ sessionId: value.slot.id, interactionId: "ask-after-cap", observed: false, machineId: "machine-terminal-test" });
      await waitFor(async () => received.filter(({ envelope }) => envelope.notificationKind === "ask").length === 2
        && (await store.snapshot()).pending.length === 0, "the ask after routine cap");
      expect((await store.snapshot()).pending).toEqual([]);
      expect(signals).toContainEqual({ kind: "agent_finished", outcome: "rate_limited", relayReason: "daily_limit" });
      expect(logger.recent(100).some((row) => row.event === "notification.push.rate-limited" && row.reason === "daily_limit")).toBe(true);
      expect((await notifications.inbox()).notifications).toContainEqual(expect.objectContaining({ kind: "agent_finished", title: "Routine", outcome: "failed" }));
      expect(received.filter(({ envelope }) => envelope.title === "Routine")).toHaveLength(1);
      expect(received.map(({ envelope }) => envelope.notificationKind)).toEqual([
        "ask", "waiting", "agent_finished", "agent_finished", "agent_finished", "ask",
      ]);
      const inbox = (await notifications.inbox()).notifications;
      const reportPath = process.env.TRON_NOTIFICATION_E2E_REPORT
        ?? join(process.cwd(), "test-results", "runtime-terminal-notifications.integration.json");
      await mkdir(dirname(reportPath), { recursive: true });
      await writeFile(reportPath, `${JSON.stringify({
        passed: true,
        provider: "faux",
        relay: "local-http",
        deliveredKinds: received.map(({ envelope }) => envelope.notificationKind),
        inbox: inbox.map(({ kind, title, message, outcome }) => ({ kind, title, message, outcome })),
        capSignal: signals.find(({ relayReason }) => relayReason === "daily_limit"),
        capLog: logger.recent(100).find((row) => row.event === "notification.push.rate-limited" && row.reason === "daily_limit"),
      }, null, 2)}\n`);
    } finally {
      releaseChild.release();
      await waitFor(() => !value.slot.isBusy, "the managed subagent to settle before cleanup", { boundMs: 5_000 }).catch(() => {});
      notifications.dispose();
    }
  }, 30_000);

  it("waits through retries and announces only the exhausted final error", async () => {
    const resumed = barrier();
    const release = barrier();
    const error = () => fauxAssistantMessage("", { stopReason: "error", errorMessage: "fetch failed" });
    const value = await fixture([error(), async () => { resumed.release(); await release.promise; return error(); }, error()], {
      retry: { enabled: true, maxRetries: 2, baseDelayMs: 1 },
    });
    try {
      await value.slot.prompt("retry request");
      await resumed.promise;
      expect(value.enqueue).not.toHaveBeenCalled();
    } finally { release.release(); }
    await value.settle();
    expect(value.faux.state.callCount).toBe(3);
    expect(value.enqueue).toHaveBeenCalledTimes(1);
    expect(value.enqueue.mock.calls[0]![0].message).toBe("The agent stopped because of an error.");
  });

  it("does not mislabel a cancelled retry as exhaustion or reuse earlier success", async () => {
    const value = await fixture([
      fauxAssistantMessage("previous success"),
      fauxAssistantMessage("", { stopReason: "error", errorMessage: "fetch failed" }),
    ], { retry: { enabled: true, maxRetries: 2, baseDelayMs: 60_000 } });
    await value.slot.prompt("earlier request");
    await value.settle();
    const previousSource = value.enqueue.mock.calls[0]![0].sourceId;
    value.enqueue.mockClear();
    await value.slot.prompt("cancel retry request");
    await waitFor(() => value.slot.snapshot().phase === "retrying", "the retrying phase");
    expect(value.enqueue).not.toHaveBeenCalled();
    await value.slot.abort();
    await value.settle();
    expect(value.faux.state.callCount).toBe(2);
    expect(value.enqueue).toHaveBeenCalledTimes(1);
    expect(value.enqueue.mock.calls[0]![0]).toMatchObject({ message: "The agent was stopped." });
    expect(value.enqueue.mock.calls[0]![0].sourceId).not.toBe(previousSource);
  });

  it("announces only the final extension continuation, even when it fails", async () => {
    const value = await fixture([
      fauxAssistantMessage("intermediate success"),
      fauxAssistantMessage("", { stopReason: "error", errorMessage: "terminal failure" }),
    ], { extension: `export default function(pi) {
      let continued = false;
      pi.on("agent_before_settle", (event) => {
        pi.appendEntry("test-settlement-order", { stage: "agent_before_settle", outcome: event.outcome });
        if (continued) return;
        continued = true;
        return { entries: [{ type: "custom_message", customType: "test-continuation", content: "continue", display: false }], continue: true };
      });
      pi.on("agent_settled", () => pi.appendEntry("test-settlement-order", { stage: "agent_settled" }));
    }` });
    await value.slot.prompt("continuation request");
    await value.settle();
    expect(value.faux.state.callCount).toBe(2);
    expect(value.sdkEvents).toEqual(["agent_start", "agent_end", "agent_start", "agent_end", "agent_settled"]);
    expect(value.enqueue).toHaveBeenCalledTimes(1);
    expect(value.enqueue.mock.calls[0]![0].message).toBe("The agent stopped because of an error.");
    const entries = value.canonicalAtAdmission[0]!;
    const assistants = entries.filter((entry: any) => entry.type === "message" && entry.message.role === "assistant");
    const terminals = entries.filter((entry: any) => entry.type === "custom" && entry.customType === INVOCATION_RECEIPT_TYPE && entry.data.receiptKind === "terminal");
    const callbacks = entries.filter((entry: any) => entry.type === "custom" && entry.customType === "test-settlement-order")
      .map((entry: any) => entry.data.stage);
    expect(callbacks).toEqual(["agent_before_settle", "agent_before_settle", "agent_settled"]);
    expect(assistants).toHaveLength(2);
    expect(assistants[1].message.stopReason).toBe("error");
    expect(value.enqueue.mock.calls[0]![0].sourceId).toBe(assistants[1].id);
    // The user invocation owns its first completed assistant. Pi's queued
    // continuation is a distinct SDK run whose failure notifies separately; it
    // must not rewrite the already durable invocation receipt.
    expect(terminals).toHaveLength(1);
    expect(terminals[0].data.lifecycle).toBe("completed");
  });

  it("lets recoverable tool errors continue but announces a terminating tool block", async () => {
    const value = await fixture([
      fauxAssistantMessage([fauxToolCall("read", { path: "absent-file" })], { stopReason: "toolUse" }),
      fauxAssistantMessage("recovered"),
      fauxAssistantMessage([fauxToolCall("read", { path: "blocked-file" })], { stopReason: "toolUse" }),
    ], { extension: `export default function(pi) {
      pi.on("tool_call", (event) => event.input.path === "blocked-file"
        ? { block: true, reason: "test block", terminate: true } : undefined);
    }` });
    await value.slot.prompt("recoverable tool request");
    await value.settle();
    expect(value.enqueue).toHaveBeenCalledTimes(1);
    expect(value.enqueue.mock.calls[0]![0].message).toBe("The agent finished responding.");
    value.enqueue.mockClear();
    await value.slot.prompt("blocked tool request");
    await value.settle();
    expect(value.enqueue).toHaveBeenCalledTimes(1);
    expect(value.enqueue.mock.calls[0]![0].message).toBe("The agent stopped without a final response.");
    expect(value.faux.state.callCount).toBe(3);
  });

  it("announces a genuine provider exception as failure, not an earlier completion", async () => {
    const value = await fixture([() => { throw new Error("private provider exception"); }]);
    await value.slot.prompt("provider exception request");
    await value.settle();
    expect(value.enqueue).toHaveBeenCalledTimes(1);
    expect(value.enqueue.mock.calls[0]![0].message).toBe("The agent stopped because of an error.");
  });

  it("waits for queued follow-up work before announcing its final failure", async () => {
    const started = barrier();
    const release = barrier();
    let queuedOperationId!: string;
    const value = await fixture([
      async () => { started.release(); await release.promise; return fauxAssistantMessage("intermediate response"); },
      fauxAssistantMessage("", { stopReason: "error" }),
    ]);
    try {
      await value.slot.prompt("initial request");
      await started.promise;
      queuedOperationId = (await value.slot.prompt("queued request", [], "followUp")).operationId;
      expect(value.enqueue).not.toHaveBeenCalled();
    } finally { release.release(); }
    await value.settle();
    expect(value.faux.state.callCount).toBe(2);
    expect(value.enqueue).toHaveBeenCalledTimes(1);
    expect(value.enqueue.mock.calls[0]![0].message).toBe("The agent stopped because of an error.");
    const terminal = value.canonicalAtAdmission[0]!.find((entry) => entry.customType === INVOCATION_RECEIPT_TYPE
      && entry.data.receiptKind === "terminal" && entry.data.operationId === queuedOperationId);
    expect(terminal?.data.lifecycle).toBe("failed");
    await waitFor(() => !value.slot.isDrainBusy, "the slot to stop draining");
  });

  it("announces drain-cutoff interruption without overwriting the preceding completion receipt", async () => {
    const started = barrier();
    const release = barrier();
    const value = await fixture([
      async () => { started.release(); await release.promise; return fauxAssistantMessage("preceding response"); },
      fauxAssistantMessage("rejected continuation"),
    ], { extension: `export default function(pi) {
      let continued = false;
      pi.on("agent_before_settle", (event) => {
        pi.appendEntry("test-settlement-order", { stage: "agent_before_settle", outcome: event.outcome });
        if (continued) return;
        continued = true;
        return { entries: [{ type: "custom_message", customType: "test-continuation", content: "continue", display: false }], continue: true };
      });
      pi.on("agent_settled", () => pi.appendEntry("test-settlement-order", { stage: "agent_settled" }));
    }` });
    try {
      await value.slot.prompt("draining request");
      await started.promise;
      value.slot.beginAdministrativeDrainCutoff();
    } finally { release.release(); }
    await value.settle();
    await waitFor(() => !value.slot.isDrainBusy, "the slot to stop draining");
    expect(value.sdkEvents).toEqual(["agent_start", "agent_end", "agent_start", "agent_end", "agent_settled"]);
    expect(value.enqueue.mock.calls, JSON.stringify(value.enqueue.mock.calls)).toHaveLength(1);
    expect(value.enqueue.mock.calls[0]![0].message).toBe("The agent was stopped.");
    const entries = value.canonicalAtAdmission[0]!;
    const assistants = entries.filter((entry: any) => entry.type === "message" && entry.message.role === "assistant");
    expect(assistants).toHaveLength(2);
    expect(assistants[0].message.stopReason).toBe("stop");
    expect(assistants[1].message.stopReason).toBe("aborted");
    // Drain rejects the SDK continuation; notification remains bound to the
    // preceding successful assistant without rewriting its completion receipt.
    expect(value.enqueue.mock.calls[0]![0].sourceId).toBe(assistants[0].id);
    expect(entries.filter((entry: any) => entry.type === "custom" && entry.customType === "test-settlement-order")
      .map((entry: any) => entry.data.stage)).toEqual(["agent_before_settle", "agent_settled"]);
    const terminals = entries.filter((entry: any) => entry.customType === INVOCATION_RECEIPT_TYPE && entry.data.receiptKind === "terminal");
    expect(terminals).toHaveLength(1);
    expect(terminals[0].data.lifecycle).toBe("completed");
  });

  it("suppresses a terminal error when its chat is already observed", async () => {
    const value = await fixture([fauxAssistantMessage("", { stopReason: "error" })], { observed: true });
    await value.slot.prompt("visible failure");
    await value.settle();
    expect(value.enqueue).not.toHaveBeenCalled();
    expect(value.suppressAutomatic).toHaveBeenCalledTimes(1);
  });

  it.each([false, true])("latches error observation (%s) before terminal receipt I/O", async (observed) => {
    const value = await fixture([fauxAssistantMessage("", { stopReason: "error" })], { observed });
    if (!observed) value.registry.subscribe("phone", value.slot.id);
    const writing = barrier();
    const release = barrier();
    const owner = value.slot as unknown as { persistInvocationReceipt(...args: any[]): Promise<void> };
    const persist = owner.persistInvocationReceipt.bind(owner);
    vi.spyOn(owner, "persistInvocationReceipt").mockImplementation(async (...args) => {
      if (args[0].receiptKind === "terminal") { writing.release(); await release.promise; }
      await persist(...args);
    });
    try {
      await value.slot.prompt("observation race request");
      await writing.promise;
      value.registry.setPresentationVisibility({
        clientId: "phone", sessionId: value.slot.id, subscriptionToken: "subscription", revision: 2, visible: !observed,
      });
    } finally { release.release(); }
    await value.settle();
    expect(value.enqueue).toHaveBeenCalledTimes(observed ? 0 : 1);
    expect(value.suppressAutomatic).toHaveBeenCalledTimes(observed ? 1 : 0);
  });

  it("notifies admitted preflight failure but not malformed unadmitted requests or handled commands", async () => {
    const value = await fixture([], { extension: `export default function(pi) {
      pi.registerCommand("handled", { handler: async () => {} });
    }` });
    await expect(value.slot.prompt("invalid", [], undefined, {
      text: "invalid", attachmentEnvelope: "", attachmentCount: 2, attachments: [],
    })).rejects.toMatchObject({ code: "invalid_request" });
    expect(value.enqueue).not.toHaveBeenCalled();
    await value.slot.prompt("/handled");
    expect(value.enqueue).not.toHaveBeenCalled();
    // Exercise Pi's real missing-model preflight without reaching a network
    // provider or mocking prompt/settlement events.
    (value.slot as unknown as { runtime: { session: { agent: { state: { model: undefined } } } } })
      .runtime.session.agent.state.model = undefined;
    await expect(value.slot.prompt("setup request")).rejects.toBeDefined();
    await value.settle();
    expect(value.faux.state.callCount).toBe(0);
    expect(value.enqueue).toHaveBeenCalledTimes(1);
    expect(value.persistedAtAdmission).toEqual([undefined]);
    const entries = value.canonicalAtAdmission[0]!;
    const terminal = entries.findLast((entry) => entry.customType === INVOCATION_RECEIPT_TYPE && entry.data.receiptKind === "terminal");
    expect(terminal.data.lifecycle).toBe("failed");
    expect(value.enqueue.mock.calls[0]![0]).toMatchObject({
      sourceId: terminal.data.receiptId, message: "The agent stopped because of an error.",
    });
  });

  it("records ownership loss and notifies once when shutdown interrupts a live retry", async () => {
    const value = await fixture([fauxAssistantMessage("", { stopReason: "error", errorMessage: "fetch failed" })], {
      retry: { enabled: true, maxRetries: 2, baseDelayMs: 60_000 },
    });
    await value.slot.prompt("interrupted request");
    await waitFor(() => value.slot.snapshot().phase === "retrying", "the retrying phase");
    await value.slot.shutdown();
    expect(value.enqueue).toHaveBeenCalledTimes(1);
    expect(value.enqueue.mock.calls[0]![0].message).toBe("The agent was interrupted before its outcome could be confirmed.");
    const terminal = value.canonicalAtAdmission[0]!.findLast((entry) => entry.customType === INVOCATION_RECEIPT_TYPE && entry.data.receiptKind === "terminal");
    expect(terminal.data.lifecycle).toBe("outcomeUnknown");
  });

  it("keeps settlement healthy when notification admission fails", async () => {
    const value = await fixture([fauxAssistantMessage("", { stopReason: "error" })]);
    value.enqueue.mockRejectedValueOnce(new Error("notification store unavailable"));
    await value.slot.prompt("notification failure request");
    await value.settle();
    expect(value.slot.snapshot().phase).toBe("idle");
  });
});
