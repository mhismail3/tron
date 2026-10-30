import { readFile, mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { fauxAssistantMessage, fauxToolCall, getCurrentTools } from "@earendil-works/pi-ai";
import { afterEach, expect, it, vi } from "vitest";
import { startLockGateway, type LockGateway } from "../../test-support/gateway-lock-harness.js";
import { homeOwnerOf } from "../../test-support/gateway-registry.js";
import { waitFor } from "../../test-support/wait-for.js";

const owned: LockGateway[] = [];
afterEach(async () => {
  await mkdir("test-results/2156", { recursive: true });
  await writeFile("test-results/2156/monitor-trace.json", JSON.stringify(owned.map(g => g.record()), null, 2));
  try { for (const g of owned.splice(0)) await g.dispose(); }
  finally { vi.restoreAllMocks(); }
});

async function fixture() {
  const gateway = await startLockGateway("home-monitor", { automations: true, home: { memorySummarizer: () => async () => fauxAssistantMessage("Summary.") } });
  owned.push(gateway);
  const phone = await gateway.connect("phone");
  const model = JSON.parse(await readFile(join(gateway.agentDir, "settings.json"), "utf8"));
  const designated = await phone.request("home.designate", { commandId: gateway.commandId(), model: { provider: model.defaultProvider, id: model.defaultModel } });
  expect(designated.ok, JSON.stringify(designated)).toBe(true);
  const sessionId = designated.result.sessionId as string;
  expect((await phone.request("settings.change", { commandId: gateway.commandId(), target: { kind: "home" }, changes: [{ key: "model.queue[role=background]", layer: "session", op: "set", value: [`${model.defaultProvider}/${model.defaultModel}`] }] })).ok).toBe(true);
  const prompt = async (text: string, calls: Array<{ action: string; [key: string]: unknown }>) => {
    gateway.script([
      () => fauxAssistantMessage(calls.map(call => fauxToolCall("monitor", call)), { stopReason: "toolUse" }),
      () => fauxAssistantMessage("Monitor operation observed."),
    ]);
    const response = await phone.request("home.prompt", { commandId: gateway.commandId(), text });
    expect(response.ok, JSON.stringify(response)).toBe(true);
    await gateway.settled(sessionId);
    return (await gateway.registry.acquire(sessionId)).canonicalSessionEntries().filter(entry => entry.type === "message" && entry.message.role === "toolResult" && entry.message.toolName === "monitor").slice(-calls.length).map(entry => entry.message);
  };
  // Date.now controls schedule time only; the real scheduler scan is awakened
  // through an ordinary socket mutation, not a private tick or a second timer.
  const nudge = async () => {
    const status = (await phone.request("home.status", {})).result;
    const created = await phone.request("automation.create", { commandId: gateway.commandId(), definition: {
      name: "Fixture scheduler scan", activation: "draft", target: { kind: "home", homeId: status.homeId, routeGeneration: status.routeGeneration },
      trigger: { kind: "once", at: "2099-01-01T00:00:00.000Z" }, action: { kind: "sessionPrompt", text: "Never activated." },
    } });
    expect(created.ok, JSON.stringify(created)).toBe(true);
    expect((await phone.request("automation.delete", { commandId: gateway.commandId(), automationId: created.result.id, expectedRevision: created.result.revision })).ok).toBe(true);
  };
  const monitors = async () => (await phone.request("automation.list", {})).result.items;
  return { gateway, phone, sessionId, prompt, nudge, monitors };
}

it("real Gateway/socket/Pi: Home creates a visible bounded monitor without approval", async () => {
  const { gateway, phone, prompt } = await fixture();
  const expiresAt = new Date(Date.now() + 3_600_000).toISOString();
  const results = await prompt("Watch authorized fixture work.", [{ action: "create", name: "Fixture work", message: "Objective: finish fixture. Ref: #2156. Stop on completion or maintainer blocker.", everyMinutes: 5, expiresAt }]);
  expect(results).toHaveLength(1);
  expect(results[0].isError, JSON.stringify(results)).not.toBe(true);
  const listed = await phone.request("automation.list", {});
  expect(listed.ok, JSON.stringify(listed)).toBe(true);
  expect(listed.result.items).toHaveLength(1);
  const record = (await phone.request("automation.get", { automationId: listed.result.items[0].id })).result;
  expect(record).toMatchObject({ activation: "enabled", provenance: { kind: "home", expiresAt }, trigger: { kind: "interval", everySeconds: 300 }, target: { kind: "home" }, action: { kind: "sessionPrompt" } });
  expect((await phone.request("settings.approvals", {})).result.requests).toHaveLength(0);
  expect(gateway.record().providerRequests[0].tools).toContain("monitor");
});

it("real Gateway/socket/Pi: the existing scheduler timer expires a monitor without a nudge or provider wake", async () => {
  const { gateway, phone, prompt, monitors } = await fixture();
  expect((await prompt("Use a short real lease.", [{ action: "create", name: "Timer expiry", message: "Ref #2156. Disarm at expiry.", everyMinutes: 5, expiresAt: new Date(Date.now() + 6_000).toISOString() }]))[0].isError).not.toBe(true);
  const monitor = (await monitors())[0];
  const before = gateway.record().providerRequests.length;
  await waitFor(async () => (await phone.request("automation.get", { automationId: monitor.id })).result.activation === "completed", "real scheduler timer disarms expired monitor");
  expect(gateway.record().providerRequests).toHaveLength(before);
});

it.each(["monitor", "result"] as const)("real Gateway/socket/Pi: %s wake resumes the same progress worker exactly once", async mode => {
  let clock = Date.now();
  vi.spyOn(Date, "now").mockImplementation(() => clock);
  const { gateway, phone, sessionId, nudge, monitors } = await fixture();
  const owner = homeOwnerOf(gateway.registry);
  let homeStep = 0, workerReports = 0, resumes = 0, deletions = 0;
  gateway.script(Array.from({ length: 30 }, () => async context => {
    if (getCurrentTools(context.messages).some(tool => tool.name === "report")) {
      const outcome = ++workerReports === 1 ? "progress" : "final";
      return fauxAssistantMessage([fauxToolCall("report", { resultId: `worker-${outcome}`, outcome, text: `Fixture worker ${outcome}.`, evidence: ["Synthetic fixture completed this operation."] })], { stopReason: "toolUse" });
    }
    if (homeStep++ === 0) return fauxAssistantMessage([fauxToolCall("monitor", { action: "create", name: "Open fixture objective", message: "Ref #2156: finish the authorized objective; inspect worker incident-worker and resume it only if unblocked. Stop on completion or maintainer blocker.", everyMinutes: 5, expiresAt: new Date(clock + 3_600_000).toISOString() })], { stopReason: "toolUse" });
    if (homeStep === 2) return fauxAssistantMessage([fauxToolCall("delegate", { taskId: "incident-worker", title: "Incident fixture worker", intent: "Complete the synthetic objective and report progress first.", target: gateway.cwd })], { stopReason: "toolUse" });
    const last = JSON.stringify(context.messages.at(-1));
    if ((mode === "monitor" ? last.includes("Automation · Open fixture objective") : last.includes("outcome: progress")) && resumes === 0) {
      resumes++;
      return fauxAssistantMessage([fauxToolCall("task", { action: "resume", taskId: "incident-worker", text: "Continue the already-authorized unfinished fixture objective." })], { stopReason: "toolUse" });
    }
    if (mode === "result" && last.includes("outcome: final") && deletions++ === 0) {
      const record = (await monitors())[0];
      return fauxAssistantMessage([fauxToolCall("monitor", { action: "delete", automationId: record.id, expectedRevision: record.revision })], { stopReason: "toolUse" });
    }
    return fauxAssistantMessage("Result summarized; no continuation tool called on this result wake.");
  }));
  expect((await phone.request("home.prompt", { commandId: gateway.commandId(), text: "Complete the authorized fixture objective and keep it moving." })).ok).toBe(true);
  if (mode === "result") {
    await waitFor(async () => (await owner.taskResult("incident-worker.resume-1").catch(() => undefined))?.wake?.state === "acknowledged", "ordinary result wake resumes and finishes the same worker");
    await gateway.settled(sessionId);
    const first = await owner.taskStatus("incident-worker");
    expect(await owner.taskStatus("incident-worker.resume-1")).toMatchObject({ sessionId: first.sessionId, lifecycle: "terminal", terminalEvidence: { outcome: "final" } });
    expect(resumes).toBe(1);
    expect(workerReports).toBe(2);
    expect(await monitors()).toHaveLength(0);
    expect((await gateway.registry.acquire(sessionId)).canonicalSessionEntries().filter(entry => entry.type === "custom_message" && entry.customType === "tron.home-trigger.v1")).toHaveLength(0);
    return;
  }
  await waitFor(async () => (await owner.taskResult("incident-worker").catch(() => undefined))?.wake?.state === "acknowledged", "progress result wake acknowledged");
  await gateway.settled(sessionId);
  const first = await owner.taskStatus("incident-worker");
  expect(first).toMatchObject({ lifecycle: "terminal", terminalEvidence: { outcome: "progress" } });
  expect(workerReports).toBe(1);
  expect(resumes).toBe(0);
  const before = gateway.record().providerRequests.length;
  const monitor = (await monitors())[0];
  clock = Date.parse(monitor.nextOccurrenceAt);
  await nudge();
  await waitFor(async () => (await owner.taskResult("incident-worker.resume-1").catch(() => undefined))?.wake?.state === "acknowledged", "same worker resumed and successor result acknowledged");
  await gateway.settled(sessionId);
  expect(await owner.taskStatus("incident-worker.resume-1")).toMatchObject({ sessionId: first.sessionId, lifecycle: "terminal" });
  expect(workerReports).toBe(2);
  expect(resumes).toBe(1);
  const record = (await phone.request("automation.get", { automationId: monitor.id })).result;
  expect(record.history).toHaveLength(1);
  expect(record.lastRun).toMatchObject({ state: "succeeded", homeDelivery: "wake", executionSessionId: sessionId });
  const entries = (await gateway.registry.acquire(sessionId)).canonicalSessionEntries();
  expect(entries.filter(entry => entry.type === "custom_message" && entry.customType === "tron.home-trigger.v1")).toHaveLength(1);
  expect(entries.filter(entry => entry.type === "message" && entry.message.role === "toolResult" && entry.message.toolName === "task")).toHaveLength(1);
  expect(gateway.record().providerRequests.length).toBeGreaterThan(before);
  await nudge(); // Same occurrence scanned again: no delivery or resume.
  await gateway.settled(sessionId);
  expect(resumes).toBe(1);
  expect((await phone.request("automation.get", { automationId: monitor.id })).result.history).toHaveLength(1);
  const stopped = await phone.request("automation.pause", { commandId: gateway.commandId(), automationId: monitor.id, expectedRevision: record.revision });
  expect(stopped.ok).toBe(true);
  const after = gateway.record().providerRequests.length;
  clock += 300_000;
  await nudge();
  await gateway.settled(sessionId);
  expect(gateway.record().providerRequests).toHaveLength(after);
  expect(resumes).toBe(1);
});

it("real Gateway/socket/Pi: interval, expiry, active-count and ownership refusals cannot widen Home authority", async () => {
  const { gateway, phone, prompt, monitors } = await fixture();
  const create = { action: "create", name: "Bounded", message: "Ref #2156, stop on completion.", everyMinutes: 5, expiresAt: new Date(Date.now() + 3_600_000).toISOString() };
  const invalid = [ { ...create, everyMinutes: 4 }, { ...create, expiresAt: new Date(Date.now() + 86_401_000).toISOString() }, { ...create, expiresAt: new Date(Date.now() - 1_000).toISOString() }, { ...create, expiresAt: undefined } ];
  for (const call of invalid) {
    const results = await prompt("Exercise a bound refusal.", [call]);
    expect(results[0]?.isError, JSON.stringify(results)).toBe(true);
  }
  expect(await monitors()).toHaveLength(0);
  const results = await prompt("Create four bounded monitors.", [create, create, create, create]);
  expect(results.map(result => result.isError === true)).toEqual([false, false, false, true]);
  const records = await monitors();
  const paused = await phone.request("automation.pause", { commandId: gateway.commandId(), automationId: records[0].id, expectedRevision: records[0].revision });
  expect(paused.ok).toBe(true);
  expect((await prompt("Use the freed active slot.", [create]))[0].isError).not.toBe(true);
  expect((await prompt("Do not exceed the bound by resuming.", [{ action: "resume", automationId: records[0].id, expectedRevision: paused.result.revision }]))[0].isError).toBe(true);
  const status = (await phone.request("home.status", {})).result;
  const foreign = await phone.request("automation.create", { commandId: gateway.commandId(), definition: { name: "Maintainer owned", target: { kind: "home", homeId: status.homeId, routeGeneration: status.routeGeneration }, trigger: { kind: "once", at: "2099-01-01T00:00:00.000Z" }, action: { kind: "sessionPrompt", text: "Maintainer's message." } } });
  expect(foreign.ok).toBe(true);
  for (const action of ["pause", "resume", "delete"]) {
    expect((await prompt("A Home target is not Home ownership.", [{ action, automationId: foreign.result.id, expectedRevision: foreign.result.revision }]))[0].isError).toBe(true);
  }
  expect((await phone.request("automation.get", { automationId: foreign.result.id })).result).toEqual(foreign.result);
  const ownList = (await prompt("List only Home-created definitions.", [{ action: "list" }]))[0].details as any;
  expect(ownList.monitors).toHaveLength(4);
  expect(ownList.omittedCount).toBe(0);
  expect(ownList.monitors.every((record: any) => record.expiresAt && record.history === undefined && record.action === undefined)).toBe(true);
  expect(ownList.monitors.some((record: any) => record.id === foreign.result.id)).toBe(false);
  expect((await phone.request("settings.approvals", {})).result.requests).toHaveLength(0);
  expect(gateway.record().providerRequests.every(request => request.tools.includes("monitor"))).toBe(true);
});

it("real Gateway/socket/Pi: expiry disarms even a queued occurrence; pause and deletion stay in the existing Automations lifecycle", async () => {
  let clock = Date.now();
  vi.spyOn(Date, "now").mockImplementation(() => clock);
  const { gateway, phone, sessionId, prompt, nudge, monitors } = await fixture();
  const create = { action: "create", name: "Expires", message: "Ref #2156, stop on expiry.", everyMinutes: 5, expiresAt: new Date(clock + 360_000).toISOString() };
  expect((await prompt("Create a finite monitor.", [create]))[0].isError).not.toBe(true);
  const monitor = (await monitors())[0];
  expect((await phone.request("home.pauseMemory", { commandId: gateway.commandId() })).ok).toBe(true);
  const before = gateway.record().providerRequests.length;
  clock = Date.parse(monitor.nextOccurrenceAt);
  await nudge();
  await waitFor(async () => Boolean((await phone.request("automation.get", { automationId: monitor.id })).result.currentRun), "scheduled monitor occurrence queued while Home paused");
  clock += 60_000;
  await nudge();
  await waitFor(async () => (await phone.request("automation.get", { automationId: monitor.id })).result.activation === "completed", "monitor expiry disarms");
  const expired = (await phone.request("automation.get", { automationId: monitor.id })).result;
  expect(expired.nextOccurrenceAt).toBeUndefined();
  expect(expired.currentRun).toBeUndefined();
  expect(expired.lastRun).toMatchObject({ state: "cancelled", reason: "monitor-expired" });
  expect((await phone.request("home.resumeMemory", { commandId: gateway.commandId() })).ok).toBe(true);
  await gateway.settled(sessionId);
  expect(gateway.record().providerRequests).toHaveLength(before);
  expect((await prompt("An expired lease cannot be renewed.", [{ action: "resume", automationId: monitor.id, expectedRevision: expired.revision }]))[0].isError).toBe(true);
  expect((await prompt("Delete finished monitoring.", [{ action: "delete", automationId: monitor.id, expectedRevision: expired.revision }]))[0].isError).not.toBe(true);
  expect(await monitors()).toHaveLength(0);
  expect((await prompt("Arm another bounded monitor.", [{ ...create, expiresAt: new Date(clock + 600_000).toISOString() }]))[0].isError).not.toBe(true);
  const next = (await monitors())[0];
  expect((await prompt("Pause the monitor on a maintainer blocker.", [{ action: "pause", automationId: next.id, expectedRevision: next.revision }]))[0].isError).not.toBe(true);
  const after = gateway.record().providerRequests.length;
  clock += 300_000;
  await nudge();
  await gateway.settled(sessionId);
  expect(gateway.record().providerRequests).toHaveLength(after);
});

it("real Gateway/socket/Pi: a monitor cannot resume on a consumed one-use grant or renew it", async () => {
  const { gateway, phone, sessionId, prompt, monitors } = await fixture();
  const owner = homeOwnerOf(gateway.registry);
  let reports = 0;
  const dispatch = async (taskId: string, intent: string) => {
    let called = false;
    gateway.script(Array.from({ length: 12 }, () => context => {
      if (getCurrentTools(context.messages).some(tool => tool.name === "report")) {
        reports++;
        return fauxAssistantMessage([fauxToolCall("report", { resultId: `${taskId}-progress`, outcome: "progress", text: "Unfinished fixture work.", evidence: ["Grant fixture operation settled."] })], { stopReason: "toolUse" });
      }
      if (!called) { called = true; return fauxAssistantMessage([fauxToolCall("delegate", { taskId, title: "Grant fixture worker", intent, target: gateway.cwd })], { stopReason: "toolUse" }); }
      return fauxAssistantMessage("Grant fixture result summarized.");
    }));
    const response = await phone.request("home.prompt", { commandId: gateway.commandId(), text: "Run this authorized grant fixture." });
    expect(response.ok, JSON.stringify(response)).toBe(true);
    await waitFor(async () => (await owner.taskResult(taskId).catch(() => undefined))?.wake?.state === "acknowledged", "delegation result wake settled");
    await gateway.settled(sessionId);
  };
  await dispatch("scope-seed", "Seed the fixture scope");
  await waitFor(async () => (await owner.taskResult("scope-seed").catch(() => undefined))?.wake?.state === "acknowledged", "scope seed result");
  await gateway.settled(sessionId);
  const initial = (await phone.request("home.taskPermissions", {})).result;
  for (const scope of initial.scopes.filter((scope: any) => scope.active)) expect((await phone.request("home.revokeTaskScope", { commandId: gateway.commandId(), scopeId: scope.id })).ok).toBe(true);
  const intent = "Complete exactly this synthetic one-use objective";
  await dispatch("request-grant", intent);
  const request = (await phone.request("home.taskPermissions", {})).result.requests[0];
  expect(request).toBeDefined();
  expect((await phone.request("home.decideTaskGrant", { commandId: gateway.commandId(), requestId: request.id, approved: true, expiresAt: Date.now() + 3_600_000 })).ok).toBe(true);
  await dispatch("one-use-worker", intent);
  await waitFor(async () => (await owner.taskResult("one-use-worker").catch(() => undefined))?.wake?.state === "acknowledged", "one-use worker progress result");
  await gateway.settled(sessionId);
  const consumed = (await phone.request("home.taskPermissions", {})).result;
  expect(consumed.grants).toHaveLength(1);
  expect(consumed.grants[0].state).toBe("consumed");
  expect(reports).toBe(2);
  expect((await prompt("Monitor, but do not renew authority.", [{ action: "create", name: "Consumed grant", message: "Resume one-use-worker only with current authorization. Never renew grants.", everyMinutes: 5, expiresAt: new Date(Date.now() + 3_600_000).toISOString() }]))[0].isError).not.toBe(true);
  const monitor = (await monitors())[0];
  gateway.script([
    () => fauxAssistantMessage([fauxToolCall("task", { action: "resume", taskId: "one-use-worker" }), fauxToolCall("home.decideTaskGrant", { requestId: request.id, approved: true, expiresAt: Date.now() + 3_600_000 })], { stopReason: "toolUse" }),
    () => fauxAssistantMessage("Consumed authority stays consumed; the maintainer must decide."),
  ]);
  const fired = await phone.request("automation.runNow", { commandId: gateway.commandId(), automationId: monitor.id, expectedRevision: monitor.revision });
  expect(fired.ok).toBe(true);
  await waitFor(async () => (await phone.request("automation.run.get", { automationId: monitor.id, runId: fired.result.runId })).result.state === "succeeded", "consumed-grant monitor delivered");
  await gateway.settled(sessionId);
  const results = (await gateway.registry.acquire(sessionId)).canonicalSessionEntries().filter(entry => entry.type === "message" && entry.message.role === "toolResult" && ["task", "home.decideTaskGrant"].includes(entry.message.toolName));
  expect(results).toHaveLength(2);
  expect(results.every(entry => entry.message.isError)).toBe(true);
  expect(JSON.stringify(results[0])).toContain("grant-required");
  expect((await phone.request("home.taskPermissions", {})).result.grants).toEqual(consumed.grants);
  expect(reports).toBe(2);
});

it("real Gateway/socket/Pi: maintainer Stop pauses Home monitors before acknowledging and does not pause maintainer automations", async () => {
  let clock = Date.now();
  vi.spyOn(Date, "now").mockImplementation(() => clock);
  const { gateway, phone, sessionId, prompt, nudge, monitors } = await fixture();
  expect((await prompt("Monitor the authorized fixture.", [{ action: "create", name: "Stop fixture", message: "Ref #2156. Stop means no continuation.", everyMinutes: 5, expiresAt: new Date(clock + 3_600_000).toISOString() }]))[0].isError).not.toBe(true);
  const monitor = (await monitors())[0];
  const status = (await phone.request("home.status", {})).result;
  const foreign = await phone.request("automation.create", { commandId: gateway.commandId(), definition: { name: "Maintainer schedule", activation: "enabled", target: { kind: "home", homeId: status.homeId, routeGeneration: status.routeGeneration }, trigger: { kind: "once", at: "2099-01-01T00:00:00.000Z" }, action: { kind: "sessionPrompt", text: "Maintainer-owned future message." } } });
  expect(foreign.ok).toBe(true);
  const opened = await phone.request("session.open", { sessionId });
  expect(opened.ok, JSON.stringify(opened)).toBe(true);
  let started = false;
  gateway.script([(_context, options) => new Promise(resolve => {
    started = true;
    const stop = () => resolve(fauxAssistantMessage("Stopped.", { stopReason: "aborted" }));
    if (options?.signal?.aborted) stop(); else options?.signal?.addEventListener("abort", stop, { once: true });
  })]);
  clock = Date.parse(monitor.nextOccurrenceAt);
  await nudge();
  await waitFor(() => started, "monitor activation is running");
  const stop = await phone.request("session.abort", { commandId: gateway.commandId(), sessionId });
  expect(stop.ok, JSON.stringify(stop)).toBe(true);
  expect((await phone.request("automation.get", { automationId: monitor.id })).result.activation).toBe("paused");
  expect((await phone.request("automation.get", { automationId: foreign.result.id })).result).toEqual(foreign.result);
  await gateway.settled(sessionId);
  const after = gateway.record().providerRequests.length;
  clock += 300_000;
  await nudge();
  await gateway.settled(sessionId);
  expect(gateway.record().providerRequests).toHaveLength(after);
});
