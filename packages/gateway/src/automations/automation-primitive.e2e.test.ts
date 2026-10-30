import { randomUUID } from "node:crypto";
import { mkdtemp, mkdir, readFile, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, it } from "vitest";
import { fauxAssistantMessage, fauxToolCall } from "@earendil-works/pi-ai";
import { startLockGateway, type LockGateway } from "../../test-support/gateway-lock-harness.js";
import { homeOwnerOf } from "../../test-support/gateway-registry.js";
import { waitFor } from "../../test-support/wait-for.js";
import { AutomationStore } from "./automation-store.js";
import { MAXIMUM_AUTOMATIONS } from "./automation-contract.js";
import { automationOccurrenceId } from "./schedule.js";

const gateways: LockGateway[] = [];
const roots: string[] = [];
afterEach(async () => {
  await mkdir("test-results/2156", { recursive: true });
  await writeFile("test-results/2156/primitive-trace.json", JSON.stringify(gateways.map(g => g.record()), null, 2));
  for (const gateway of gateways.splice(0)) await gateway.dispose();
  for (const root of roots.splice(0)) await rm(root, { recursive: true, force: true });
});
async function fixture() {
  const gateway = await startLockGateway("automation-primitive", { automations: true, home: { memorySummarizer: () => async () => fauxAssistantMessage("Summary.") } });
  gateways.push(gateway);
  const phone = await gateway.connect("phone");
  const model = JSON.parse(await readFile(join(gateway.agentDir, "settings.json"), "utf8"));
  const designated = await phone.request("home.designate", { commandId: gateway.commandId(), model: { provider: model.defaultProvider, id: model.defaultModel } });
  expect(designated.ok, JSON.stringify(designated)).toBe(true);
  const sessionId = designated.result.sessionId as string;
  expect((await phone.request("settings.change", { commandId: gateway.commandId(), target: { kind: "home" }, changes: [{ key: "model.queue[role=background]", layer: "session", op: "set", value: [`${model.defaultProvider}/${model.defaultModel}`] }] })).ok).toBe(true);
  const call = async (request: Record<string, unknown>) => {
    gateway.script([() => fauxAssistantMessage([fauxToolCall("schedule", request)], { stopReason: "toolUse" }), () => fauxAssistantMessage("Observed.")]);
    expect((await phone.request("home.prompt", { commandId: gateway.commandId(), text: "Manage the authorized fixture automation." })).ok).toBe(true);
    await gateway.settled(sessionId);
    return (await gateway.registry.acquire(sessionId)).canonicalSessionEntries().findLast(entry => entry.type === "message" && entry.message.role === "toolResult" && entry.message.toolName === "schedule")!.message as any;
  };
  return { gateway, phone, sessionId, call };
}
const create = { action: "create", name: "Authorized work", target: "home", at: "2099-01-01T00:00:00.000Z", activate: true, prompt: "Inspect authorized work; no approval authority." };
it("real Home uses the standard schedule lifecycle without confirmation and retains a maintainer pause", async () => {
  const { gateway, phone, call } = await fixture();
  const created = await call({ ...create, expiresAt: new Date(Date.now() + 3_600_000).toISOString() });
  expect(created.isError, JSON.stringify(created)).not.toBe(true);
  const automation = created.details;
  expect(gateway.record().providerRequests[0].tools).toContain("schedule");
  expect(gateway.record().providerRequests[0].tools).not.toContain("monitor");
  const paused = await phone.request("automation.pause", { commandId: gateway.commandId(), automationId: automation.id, expectedRevision: automation.revision });
  expect(paused.ok).toBe(true);
  expect((await call({ action: "list" })).details.automations).toEqual(expect.arrayContaining([expect.objectContaining({ id: automation.id, activation: "paused" })]));
  expect((await phone.request("automation.get", { automationId: automation.id })).result.activation).toBe("paused");
  const resumed = await call({ action: "enable", automationId: automation.id, expectedRevision: paused.result.revision });
  expect(resumed.isError).not.toBe(true);
  expect((await call({ action: "delete", automationId: automation.id, expectedRevision: resumed.details.revision })).isError).not.toBe(true);
  expect((await phone.request("automation.list", {})).result.items).toHaveLength(0);
});
it("real Home automation-triggered turns cannot mutate automations", async () => {
  const { gateway, phone, call } = await fixture();
  const created = await call({ ...create, activate: false });
  expect(created.isError, JSON.stringify(created)).not.toBe(true);
  const automation = created.details;
  const before = gateway.record().providerRequests.length;
  gateway.script([() => fauxAssistantMessage([fauxToolCall("schedule", create)], { stopReason: "toolUse" }), () => fauxAssistantMessage("Trigger is not authority.")]);
  expect((await phone.request("automation.runNow", { commandId: gateway.commandId(), automationId: automation.id, expectedRevision: automation.revision })).ok).toBe(true);
  await waitFor(() => gateway.record().providerRequests.length >= before + 2, "trigger refusal result");
  const slot = await gateway.registry.acquire((await phone.request("home.status", {})).result.sessionId);
  await gateway.settled(slot.id);
  const result = slot.canonicalSessionEntries().findLast(entry => entry.type === "message" && entry.message.role === "toolResult" && entry.message.toolName === "schedule") as any;
  expect(result.message.isError).toBe(true);
  expect(JSON.stringify(result.message.content)).toContain("Scheduled automation turns cannot mutate automations");
  expect((await phone.request("automation.list", {})).result.items).toHaveLength(1);
});
it("real delegated workers cannot mutate standard automations", async () => {
  const { gateway, phone, sessionId } = await fixture();
  let homeCalls = 0; let workerCalls = 0;
  const step = (context: any) => {
    if (context.messages.some((message: any) => message.role === "user" && JSON.stringify(message.content).includes("This is a finite Home task"))) {
      return workerCalls++ === 0
        ? fauxAssistantMessage([fauxToolCall("schedule", create)], { stopReason: "toolUse" })
        : fauxAssistantMessage([fauxToolCall("report", { resultId: "worker-authority", outcome: "final", text: "Mutation was refused.", evidence: ["Observed schedule refusal"] })], { stopReason: "toolUse" });
    }
    return homeCalls++ === 0
      ? fauxAssistantMessage([fauxToolCall("delegate", { taskId: "worker-authority", title: "Worker authority", intent: "Attempt schedule once, then report.", target: gateway.cwd })], { stopReason: "toolUse" })
      : fauxAssistantMessage("Worker result acknowledged.");
  };
  gateway.script(Array.from({ length: 10 }, () => step));
  expect((await phone.request("home.prompt", { commandId: gateway.commandId(), text: "Delegate the finite fixture work." })).ok).toBe(true);
  await waitFor(async () => (await homeOwnerOf(gateway.registry).taskResult("worker-authority").catch(() => undefined))?.wake?.state === "acknowledged", "worker report");
  await gateway.settled(sessionId);
  expect(workerCalls).toBeGreaterThanOrEqual(2);
  expect((await phone.request("automation.list", {})).result.items).toHaveLength(0);
});
it("real interactive schedule mutations still require and obey confirmation", async () => {
  const { gateway, phone } = await fixture();
  const created = await phone.request("session.create", { commandId: gateway.commandId(), cwd: gateway.cwd });
  expect(created.ok).toBe(true);
  const sessionId = created.result.sessionId;
  const slot = await gateway.registry.acquire(sessionId);
  const model = JSON.parse(await readFile(join(gateway.agentDir, "settings.json"), "utf8"));
  await slot.setModel(model.defaultProvider, model.defaultModel);
  gateway.script([() => fauxAssistantMessage([fauxToolCall("schedule", { ...create, target: "currentSession" })], { stopReason: "toolUse" }), () => fauxAssistantMessage("Cancelled.")]);
  const prompt = slot.prompt("Create this reminder only with my confirmation.");
  await waitFor(() => slot.snapshot().extensionPresentation.pendingInteractions.length === 1, "interactive schedule confirmation");
  expect((await phone.request("automation.list", {})).result.items).toHaveLength(0);
  const pending = slot.snapshot().extensionPresentation.pendingInteractions[0]!;
  slot.respondToInteraction(pending.id, pending.hostEpoch, pending.presentationRevision, false, false);
  await prompt;
  await gateway.settled(sessionId);
  expect((await phone.request("automation.list", {})).result.items).toHaveLength(0);
});
it("real RPC expiry bounds timeline/list and the scheduler never fires an expired automation", async () => {
  const { gateway, phone } = await fixture();
  const status = (await phone.request("home.status", {})).result;
  const now = Date.now();
  const expiresAt = new Date(now + 3_000).toISOString();
  const created = await phone.request("automation.create", { commandId: gateway.commandId(), definition: {
    name: "Finite", activation: "enabled", expiresAt, target: { kind: "home", homeId: status.homeId, routeGeneration: status.routeGeneration },
    trigger: { kind: "interval", everySeconds: 60, anchorAt: new Date(now + 6_000).toISOString() }, action: { kind: "sessionPrompt", text: "Must not fire after expiry." },
  } });
  expect(created.ok, JSON.stringify(created)).toBe(true);
  const timeline = await phone.request("automation.timeline.list", { from: new Date(now).toISOString(), through: new Date(now + 3_600_000).toISOString(), displayTimezone: "UTC", limit: 200 });
  expect(timeline.ok, JSON.stringify(timeline)).toBe(true);
  expect(timeline.result.items).toHaveLength(0);
  await waitFor(async () => (await phone.request("automation.list", {})).result.items[0].activation === "expired", "generic expiry projection");
  const expired = (await phone.request("automation.get", { automationId: created.result.id })).result;
  expect(expired.activation).toBe("expired");
  await waitFor(() => Date.now() >= now + 7_000, "the original occurrence passes without a firing");
  const afterDue = (await phone.request("automation.get", { automationId: created.result.id })).result;
  expect(afterDue.history).toHaveLength(0);
  expect(afterDue.currentRun).toBeUndefined();
  const fired = await phone.request("automation.runNow", { commandId: gateway.commandId(), automationId: created.result.id, expectedRevision: expired.revision });
  expect(fired.ok).toBe(false);
  expect(gateway.record().providerRequests).toHaveLength(0);
});
async function storeFixture() {
  const root = await mkdtemp(join(tmpdir(), "tron-automation-primitive-")); roots.push(root);
  const store = new AutomationStore(root); await store.initialize();
  const definition = await store.create({ name: "Primitive", activation: "draft", target: { kind: "existingSession", sessionId: "fixture" }, trigger: { kind: "interval", everySeconds: 300, anchorAt: new Date().toISOString() }, action: { kind: "sessionPrompt", text: "Fixture." }, provenance: { kind: "local" } });
  return { root, store, definition };
}
it("disk and mutateState use the same generic validator, including provenance expiry and minimum interval", async () => {
  const { root, store, definition } = await storeFixture();
  const expiresAt = new Date(Date.now() + 60_000).toISOString();
  await expect(store.mutateState(definition.id, current => ({ ...current, provenance: { kind: "local", expiresAt } }))).resolves.toMatchObject({ provenance: { expiresAt } });
  await expect(store.mutateState(definition.id, current => ({ ...current, trigger: { kind: "interval", everySeconds: 1, anchorAt: new Date().toISOString() } }))).rejects.toThrow("canonical contract");
  await expect(store.mutateState(definition.id, current => ({ ...current, provenance: { kind: "local", expiresAt: "invalid" } }))).rejects.toThrow("canonical contract");
  const disk = join(root, "gateway", "automations", `${definition.id}.json`);
  const reopened = new AutomationStore(root); await reopened.initialize();
  expect(reopened.get(definition.id).provenance).toEqual({ kind: "local", expiresAt });
  const valid = await readFile(disk, "utf8");
  await writeFile(disk, JSON.stringify({ ...JSON.parse(valid), trigger: { kind: "interval", everySeconds: 1, anchorAt: new Date().toISOString() } }));
  const invalid = new AutomationStore(root); await invalid.initialize();
  expect(invalid.status()).toMatchObject({ degraded: true, malformedRecordCount: 1 });
  expect(() => invalid.get(definition.id)).toThrow("not found");
});
it("resolving an uncertain run and internal state mutation cannot silently resume a paused automation", async () => {
  const { store, definition } = await storeFixture();
  const runId = randomUUID(); const now = new Date().toISOString();
  const run = { runId, occurrenceId: automationOccurrenceId(definition.id, definition.revision, now), automationRevision: definition.revision, scheduledFor: now, triggerSnapshot: definition.trigger, actionSnapshot: definition.action, targetSnapshot: definition.target, executionSessionId: "fixture", state: "outcomeUnknown" as const, createdAt: now, terminalAt: now, preAdmissionAttemptCount: 0 };
  await store.mutateState(definition.id, current => ({ ...current, lastRun: run, history: [run] }));
  const paused = await store.setActivation(definition.id, definition.revision, "paused");
  const resolved = await store.resolveUnknown(definition.id, paused.revision, runId, "succeeded", { kind: "local" });
  expect(resolved.activation).toBe("paused");
  await expect(store.mutateState(definition.id, current => ({ ...current, activation: "enabled" }))).rejects.toThrow("explicit enable");
  expect((await store.setActivation(definition.id, resolved.revision, "enabled")).activation).toBe("enabled");
});
it("real persisted provenance expiry trims the timeline before the scheduler's expiry pass", async () => {
  let { gateway, phone } = await fixture();
  const status = (await phone.request("home.status", {})).result;
  const now = Date.now();
  const created = await phone.request("automation.create", { commandId: gateway.commandId(), definition: {
    name: "Persisted finite schedule", activation: "enabled", target: { kind: "home", homeId: status.homeId, routeGeneration: status.routeGeneration },
    trigger: { kind: "interval", everySeconds: 300, anchorAt: new Date(now + 300_000).toISOString() }, action: { kind: "sessionPrompt", text: "Finite fixture." },
  } });
  expect(created.ok).toBe(true);
  const file = join(gateway.tronHome, "gateway", "automations", `${created.result.id}.json`);
  const record = JSON.parse(await readFile(file, "utf8"));
  const root = gateway.root;
  await gateway.dispose({ keepRoot: true }); gateways.splice(gateways.indexOf(gateway), 1);
  await writeFile(file, JSON.stringify({ ...record, provenance: { kind: "home", homeId: status.homeId, expiresAt: new Date(now + 600_000).toISOString() } }), { mode: 0o600 });
  gateway = await startLockGateway("automation-primitive", { automations: true, root }); gateways.push(gateway);
  phone = await gateway.connect("reopened");
  const timeline = await phone.request("automation.timeline.list", { from: new Date(now).toISOString(), through: new Date(now + 3_600_000).toISOString(), displayTimezone: "UTC", limit: 200 });
  expect(timeline.ok, JSON.stringify(timeline)).toBe(true);
  expect(timeline.result.items).toHaveLength(1);
  expect(timeline.result.items[0]).toMatchObject({ kind: "occurrence", scheduledFor: new Date(now + 300_000).toISOString() });
});
it("expired persisted definitions do not consume the generic definition-count cap", async () => {
  const { root, definition } = await storeFixture();
  const directory = join(root, "gateway", "automations");
  const homeId = randomUUID();
  const expired = { ...definition, createdAt: new Date(Date.now() - 120_000).toISOString(), provenance: { kind: "home", homeId, expiresAt: new Date(Date.now() - 60_000).toISOString() }, target: { kind: "home", homeId, routeGeneration: 1 } };
  await Promise.all(Array.from({ length: MAXIMUM_AUTOMATIONS }, (_, index) => {
    const id = index === 0 ? definition.id : randomUUID();
    return writeFile(join(directory, `${id}.json`), JSON.stringify({ ...expired, id }), { mode: 0o600 });
  }));
  const reopened = new AutomationStore(root); await reopened.initialize();
  expect(reopened.status().degraded).toBe(false);
  await expect(reopened.create({ name: "Fresh", target: definition.target, trigger: definition.trigger, action: definition.action, provenance: { kind: "local" } })).resolves.toMatchObject({ name: "Fresh" });
});
