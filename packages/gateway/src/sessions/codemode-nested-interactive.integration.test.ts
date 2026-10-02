import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { TrustService } from "../admin/trust-service.js";
import { GatewayScheduleToolOperations } from "../automations/automation-tool-operations.js";
import type { ScheduleToolRequest } from "../automations/tron-schedule-extension.js";
import { CommandReceiptStore } from "../transport/command-receipts.js";
import { NotificationGrantStore } from "../notifications/grant-store.js";
import { NotificationService } from "../notifications/notification-service.js";
import type { PushRelayClient } from "../notifications/relay-client.js";
import type { NotificationService as NotificationServiceType } from "../notifications/notification-service.js";
import { RuntimeRegistry } from "./runtime-registry.js";

const registries: RuntimeRegistry[] = [];
const roots: string[] = [];
afterEach(async () => {
  await Promise.all(registries.splice(0).map((registry) => registry.dispose().catch(() => {})));
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

async function waitUntil(predicate: () => boolean, timeoutMs = 5_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error("condition timed out");
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

describe("codemode nested interactive tools", () => {
  it("serializes nested forms, cancels the pending form on Stop, and preserves notify and schedule owners", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-codemode-nested-interactive-"));
    roots.push(root);
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await Promise.all([mkdir(agentDir, { recursive: true }), mkdir(extensionDir, { recursive: true })]);
    const sdkUrl = import.meta.resolve("@earendil-works/pi-coding-agent");
    await Promise.all([
      writeFile(join(agentDir, "settings.json"), JSON.stringify({ defaultTools: ["+codemode"] })),
      writeFile(join(extensionDir, "codemode.ts"), `import { createCodemodeExtension } from ${JSON.stringify(sdkUrl)}; export default createCodemodeExtension({ mode: "on" });\n`),
    ]);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);

    const notificationStore = new NotificationGrantStore(join(root, "notifications"));
    await notificationStore.initialize();
    const grant = {
      deviceId: "device_abcdefgh", installationId: "install_abcdefgh", grantId: "grant_abcdefgh",
      secret: Buffer.alloc(32, 9).toString("base64url") as const,
      previewsEnabled: false, relayOrigin: "https://push.example.test",
    };
    const relay = {
      available: true, relayOrigin: "https://push.example.test",
      async send() { return "accepted_by_apns" as const; },
      async revoke() { return "revoked" as const; },
    } as unknown as PushRelayClient;
    const notificationService = new NotificationService(notificationStore, relay, Date.now, {
      dailyIntents: 3, sessionHourlyIntents: 3, targetDailyIntents: 3,
    });
    await notificationService.upsertGrant(grant);
    const notificationAdmissions: Array<{ kind: string; status: string; sessionId: string }> = [];
    const enqueue = notificationService.enqueue.bind(notificationService);
    notificationService.enqueue = async (input) => {
      const result = await enqueue(input);
      notificationAdmissions.push({ kind: input.kind, status: result, sessionId: input.sessionId });
      return result;
    };

    const scheduleCalls: Array<{ sessionId: string; toolCallId: string; action: string }> = [];
    const automationCreate = async (definition: Record<string, unknown>, provenance: { sessionId: string; sourceId: string }) => {
      scheduleCalls.push({ sessionId: provenance.sessionId, toolCallId: provenance.sourceId, action: "create" });
      return { id: "automation-fixture", name: definition.name, activation: definition.activation, provenance };
    };
    const scheduleReceipts = new CommandReceiptStore(join(root, "receipt-home"));
    const schedule = new GatewayScheduleToolOperations(
      { create: automationCreate } as never,
      scheduleReceipts,
      () => Date.parse("2026-01-01T00:00:00.000Z"),
    );
    const faux = fauxProvider({ provider: "tron-codemode-nested-interactive", tokensPerSecond: 10_000 });
    const script = `const results = await Promise.allSettled([\n` +
      `  tools.ask_user({ title: "First", questions: [{ question: "First choice?", options: [{ label: "A" }, { label: "B" }] }] }),\n` +
      `  tools.ask_user({ title: "Second", questions: [{ question: "Second choice?", options: [{ label: "A" }, { label: "B" }] }] }),\n` +
      `  tools.notify({ message: "nested one" }),\n` +
      `  tools.notify({ message: "nested two" }),\n` +
      `  tools.schedule({ action: "create", name: "Nested schedule", prompt: "Review", at: "2030-01-01T00:00:00.000Z", activate: false }),\n` +
      `]); return JSON.stringify(results.map((r) => r.status));`;
    faux.setResponses([
      fauxAssistantMessage([fauxToolCall("codemode", { code: script }, { id: "interactive-parent" })], { stopReason: "toolUse" }),
      fauxAssistantMessage("done"),
      fauxAssistantMessage([fauxToolCall("codemode", { code: 'return await tools.ask_user({ title: "Stop test", questions: [{ question: "Stop?", options: [{ label: "Yes" }, { label: "No" }] }] });' }, { id: "interactive-stop-parent" })], { stopReason: "toolUse" }),
      fauxAssistantMessage("stopped"),
    ]);
    const modelRuntimeFactory = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    const interactionWaiters: Array<() => void> = [];
    const waitForPendingInteraction = (): Promise<void> => new Promise((resolve) => interactionWaiters.push(resolve));
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, modelRuntimeFactory, trust,
      notifications: notificationService as unknown as NotificationServiceType,
      scheduleToolOperations: schedule,
      broadcast: (_sessionId, topic, payload) => {
        if (typeof payload !== "object" || payload === null || Array.isArray(payload)) return;
        const data = (payload as { data?: unknown }).data;
        if (typeof data !== "object" || data === null || Array.isArray(data)) return;
        if (topic === "session.extensionPresentation") {
          const interactionList = (data as { interactionList?: unknown }).interactionList;
          if (Array.isArray(interactionList) && interactionList.length > 0) interactionWaiters.shift()?.();
        }
      },
      sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const firstInteraction = waitForPendingInteraction();
    const prompting = slot.prompt("Run nested interactive actions");

    await firstInteraction;
    const first = slot.snapshot().extensionPresentation.pendingInteractions[0]!;
    expect(first.method).toBe("form");
    expect(slot.snapshot().extensionPresentation.pendingInteractions).toHaveLength(1);
    slot.respondToInteraction(first.id, first.hostEpoch, first.presentationRevision, {
      version: 1, answers: [{ questionId: "question-0", optionIds: ["question-0-option-0"] }],
    }, false);
    const answered = new Set([first.id]);
    for (let attempt = 0; attempt < 40 && slot.isBusy; attempt += 1) {
      const pending = slot.snapshot().extensionPresentation.pendingInteractions.find((item) => !answered.has(item.id));
      if (pending) {
        answered.add(pending.id);
        slot.respondToInteraction(pending.id, pending.hostEpoch, pending.presentationRevision,
          pending.method === "form"
            ? { version: 1, answers: [{ questionId: "question-0", optionIds: ["question-0-option-0"] }] }
            : true,
          false);
      } else {
        await new Promise((resolve) => setTimeout(resolve, 25));
      }
    }
    await prompting;
    await waitUntil(() => !slot.isBusy);
    expect(slot.snapshot().extensionPresentation.pendingInteractions).toEqual([]);

    const parentResult = slot.snapshot().transcript.find((item) =>
      item.kind === "message" && item.role === "toolResult" && item.toolCallId === "interactive-parent");
    expect(parentResult).toMatchObject({
      role: "toolResult",
      nestedCalls: { complete: true, calls: [
        { toolName: "ask_user", status: "completed" },
        { toolName: "ask_user", status: "completed" },
        { toolName: "notify", status: "completed" },
        { toolName: "notify", status: "completed" },
        { toolName: "schedule", status: "completed" },
      ] },
    });
    const notificationState = await notificationStore.snapshot();
    expect(notificationState.receipts).toHaveLength(3);
    expect(notificationAdmissions.filter((admission) => admission.kind === "explicit").map((admission) => admission.status).sort())
      .toEqual(["queued", "rate_limited"]);
    expect(notificationAdmissions.every((admission) => admission.sessionId === slot.id)).toBe(true);
    expect(notificationState.receipts.every((receipt) => ["queued", "accepted_by_apns"].includes(receipt.result))).toBe(true);
    expect(notificationState.inbox.filter((item) => item.kind === "explicit")).toHaveLength(1);
    expect(notificationState.inbox.find((item) => item.kind === "explicit")).toMatchObject({ sessionId: slot.id });
    expect(scheduleCalls).toHaveLength(1);
    expect(scheduleCalls[0]).toMatchObject({ sessionId: slot.id, action: "create", toolCallId: expect.stringMatching(/^interactive-parent\//) });
    const scheduleCallId = scheduleCalls[0]!.toolCallId;
    const scheduleReplay = await schedule.execute(slot.id, scheduleCallId, {
      action: "create", name: "Nested schedule", prompt: "Review", at: "2030-01-01T00:00:00.000Z", activate: false,
    } satisfies ScheduleToolRequest);
    expect(scheduleReplay.details).toMatchObject({ provenance: { sessionId: slot.id, sourceId: scheduleCallId } });
    expect(scheduleCalls).toHaveLength(1);
    expect(parentResult).toMatchObject({
      details: { calls: expect.arrayContaining([
        expect.objectContaining({ id: scheduleCalls[0]!.toolCallId, name: "schedule", status: "ok" }),
      ]) },
    });

    const stopInteraction = waitForPendingInteraction();
    const stopPrompt = slot.prompt("Run nested form to stop");
    await stopInteraction;
    const pending = slot.snapshot().extensionPresentation.pendingInteractions[0]!;
    expect(pending.method).toBe("form");
    await slot.abort("agent");
    await stopPrompt;
    await waitUntil(() => !slot.isBusy);
    expect(slot.snapshot().extensionPresentation.pendingInteractions).toEqual([]);
    expect(slot.snapshot().transcript.some((item) =>
      item.kind === "message" && item.role === "toolResult" && item.toolCallId === pending.id)).toBe(false);

    const artifactPath = join(process.cwd(), "test-results", "pi-sdk-099-nested-interactive.json");
    await mkdir(dirname(artifactPath), { recursive: true });
    await writeFile(artifactPath, `${JSON.stringify({
      askUser: { concurrentRequests: 2, maximumLiveForms: 1, stopLeavesPendingForms: 0 },
      notify: { admissions: notificationAdmissions.filter((item) => item.kind === "explicit"), sessionId: notificationState.inbox[0]?.sessionId },
      schedule: scheduleCalls,
    }, null, 2)}\n`);
  });
});
