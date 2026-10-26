import fs from "node:fs/promises";
import { syncBuiltinESMExports } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { fauxAssistantMessage, type TranscriptContext, type FauxResponseFactory } from "@earendil-works/pi-ai";
import { afterAll, afterEach, describe, expect, it, vi } from "vitest";
import { fixture, disposeFixtures } from "../../test-support/home-task-fixture.js";
import { homeOwnerOf } from "../../test-support/gateway-registry.js";
import { setHomeMemoryModels } from "../../test-support/settings-dependencies.js";
import { awaitsWithin, waitFor } from "../../test-support/wait-for.js";
import { SettingsApprovals, APPROVAL_TTL_MS } from "../kernel/settings/settings-approvals.js";
import { SETTINGS_OUTCOME_MESSAGE } from "../kernel/settings/tool-contract.js";
import type { RuntimeSlot } from "../kernel/run/runtime-slot.js";
import * as durability from "../util/durable-json.js";

const evidence: unknown[] = [];
afterEach(async () => { vi.restoreAllMocks(); syncBuiltinESMExports(); await disposeFixtures(); });
afterAll(async () => {
  const path = fileURLToPath(new URL("../../test-results/settings-outcome-recovery.json", import.meta.url));
  await fs.mkdir(dirname(path), { recursive: true }); await fs.writeFile(path, JSON.stringify(evidence, null, 2) + "\n");
});
const textOf = (message: { content: unknown }) => typeof message.content === "string" ? message.content
  : (message.content as Array<{ text?: string }>).map(part => part.text ?? "").join("");
const outcomes = (slot: RuntimeSlot) => slot.canonicalSessionEntries().filter(entry => entry.type === "custom_message" && entry.customType === SETTINGS_OUTCOME_MESSAGE);
async function prompt(slot: RuntimeSlot, text: string) {
  await slot.prompt(text);
  await waitFor(() => slot.snapshot().phase === "idle" && slot.snapshot().configurationBlocker === null || undefined, "real Home activation settles");
}
async function gateway(contextWindow?: number) {
  let clock = Date.now();
  const timers: Array<{ run(): void; ms: number; cancelled: boolean }> = [];
  const f = await fixture(false, false, contextWindow, false, undefined, {
    settingsNow: () => new Date(clock),
    settingsSchedule: (run, ms) => { const timer = { run, ms, cancelled: false }; timers.push(timer); return { cancel: () => { timer.cancelled = true; } }; },
  });
  await setHomeMemoryModels(f.registry, [{ provider: f.model.provider, id: f.model.id }]);
  const received: string[] = []; const providerInputs: string[] = [];
  const respond = async (context: TranscriptContext) => {
    const fresh = context.messages.slice(context.messages.findLastIndex(message => message.role === "assistant") + 1);
    received.push(fresh.map(textOf).join("\n"));
    providerInputs.push(...fresh.filter(message => message.role === "user").map(textOf));
    return fauxAssistantMessage("Outcome receipt confirmed.");
  };
  f.faux.setResponses(Array.from({ length: 80 }, () => respond as never));
  const home = await f.registry.acquire(f.home.sessionId);
  await prompt(home, "Open Home before requesting approval");
  const { settingsChanges } = f.settings;
  settingsChanges.registerAction("fixture.recovery", {
    plan: async params => ({ title: `Recovery operation ${String(params)}`, target: { kind: "global" }, items: [{ label: "Operation", value: String(params) }] }),
    apply: async () => ({ summary: "Applied once" }),
  });
  const approvals = new SettingsApprovals(f.tronHome);
  const request = (label: string, requester = home.id) => f.settings.settingsChanges.requestAction("fixture.recovery", label,
    { actor: { kind: requester === home.id ? "home" : "agent", id: requester, sessionId: requester }, reason: "Real delivery recovery proof" });
  const decide = (held: Awaited<ReturnType<typeof request>>, approved = true) => f.settings.settingsChanges.decide(held.approval!.requestId,
    { digest: held.approval!.digest, approved, decidedBy: { kind: "ui", id: "maintainer" } });
  return { ...f, get settings() { return f.settings; }, home, get settingsChanges() { return f.settings.settingsChanges; }, approvals, request, decide, received, providerInputs, respond, timers, advance: (ms: number) => { clock += ms; } };
}

describe("settings outcome recovery at the real Registry/Pi/store boundary", () => {
  it("keeps a later deadline armed after an actual one-shot approvals read failure, without a foreground read", async () => {
    const f = await gateway();
    const requester = await f.registry.create(f.cwd);
    const first = await f.request("first", requester.id);
    f.advance(1000);
    const second = await f.request("second", requester.id);
    await waitFor(() => f.timers.some(timer => !timer.cancelled) || undefined, "earliest actual request deadline armed");
    const saved = await fs.readFile(f.approvals.path, "utf8");
    await fs.writeFile(f.approvals.path, "{incomplete approvals JSON");
    const read = fs.readFile;
    let failedRead = false;
    vi.spyOn(fs, "readFile").mockImplementation(async (path, options) => {
      const result = await read(path, options as never);
      if (String(path) === f.approvals.path && !failedRead) {
        failedRead = true;
        // The reader receives real malformed bytes; restoration is filesystem
        // recovery, not a replacement return value or a fake store result.
        await fs.writeFile(f.approvals.path, saved);
      }
      return result as never;
    });
    syncBuiltinESMExports();
    f.advance(APPROVAL_TTL_MS - 999);
    const deadline = f.timers.findLast(timer => !timer.cancelled)!;
    deadline.run();
    await waitFor(() => failedRead || undefined, "deadline consumes the actual malformed file cut");
    evidence.push({ case: "expiry-fault-reached", failedRead, requests: [first.approval!.requestId, second.approval!.requestId] });
    const later = await waitFor(() => f.timers.find(timer => timer !== deadline && !timer.cancelled), "later request retains an autonomous deadline after storage failure", { boundMs: 3000 });
    f.advance(1000); later.run();
    await waitFor(async () => (await f.approvals.get(second.approval!.requestId))?.status === "expired" || undefined, "later deadline expires without a prompt or approvals admission");
    expect((await f.approvals.get(first.approval!.requestId))?.status).toBe("expired");
    expect((await f.approvals.takeOutcomes([requester.id])).map(request => request.requestId).sort()).toEqual([first.approval!.requestId, second.approval!.requestId].sort());
    evidence.push({ case: "expiry-read-failure", requests: [first.approval!.requestId, second.approval!.requestId], failedRead });
  });

  it("reserves bounded outbox capacity before accepting requests and never evicts an untold outcome", async () => {
    const f = await gateway(); const requester = await f.registry.create(f.cwd);
    await requester.setModel(f.model.provider, f.model.id);
    const ids: string[] = [];
    for (let index = 0; index < 400; index++) {
      const held = await f.request(`retained-${index}`, requester.id);
      ids.push(held.approval!.requestId); await f.decide(held, false); f.advance(1);
    }
    expect((await f.approvals.takeOutcomes([requester.id])).map(request => request.requestId)).toEqual(ids);
    await expect(f.request("past-capacity", requester.id)).rejects.toMatchObject({ code: "busy" });
    expect((await f.approvals.takeOutcomes([requester.id])).map(request => request.requestId)).toEqual(ids);
    await prompt(requester, "Hear the retained approval outcomes");
    const received = f.received.filter(turn => turn.includes(ids[0]!));
    expect(received).toHaveLength(1);
    for (const id of ids) expect(received[0]!.split(id)).toHaveLength(2);
    await prompt(requester, "Confirm their durable delivery");
    expect(await f.approvals.takeOutcomes([requester.id])).toEqual([]);
    expect((await f.request("after-delivery", requester.id)).status).toBe("pending");
    evidence.push({ case: "bounded-outbox", retained: ids.length, providerReceived: ids.length });
  }, 60_000);

  it("drains fitting Home batches through the actual native context budget and successful provider replies", async () => {
    const f = await gateway(8000); const owner = homeOwnerOf(f.registry); await owner.pauseMemory();
    const ids: string[] = [];
    for (let index = 0; index < 160; index++) {
      const held = await f.request(`bounded Home batch ${index}`);
      ids.push(held.approval!.requestId); await f.decide(held, false); f.advance(1);
    }
    expect(outcomes(f.home)).toHaveLength(0); await owner.resumeMemory();
    await waitFor(async () => (await f.approvals.takeOutcomes([f.home.id])).length === 0 || undefined, "all fitting batches reach durable delivery");
    await waitFor(() => !f.home.isBusy || undefined, "all fitting batch replies settle");
    const messages = outcomes(f.home); expect(messages.length).toBeGreaterThan(1);
    expect(messages.flatMap(message => (message.details as { requests: Array<{ requestId: string }> }).requests.map(request => request.requestId))).toEqual(ids);
    const entries = f.home.canonicalSessionEntries();
    for (const [index, message] of messages.entries()) {
      expect(f.providerInputs.filter(body => body === String(message.content))).toHaveLength(1);
      const start = entries.indexOf(message); const end = index + 1 < messages.length ? entries.indexOf(messages[index + 1]!) : entries.length;
      expect(entries.slice(start + 1, end).some(entry => entry.type === "message" && entry.message.role === "assistant"
        && textOf(entry.message).includes("Outcome receipt confirmed."))).toBe(true);
    }
    evidence.push({ case: "native-fitting-batches", requests: ids.length, batches: messages.length });
  }, 60_000);

  it("reconciles settings outcomes on cold start even when task recovery is refused", async () => {
    const f = await gateway(); const held = await f.request("cold independent settings");
    const calls = f.faux.state.callCount;
    const heldResponse: FauxResponseFactory = (_context, options) => new Promise(resolve => {
      options?.signal?.addEventListener("abort", () => resolve(fauxAssistantMessage("Stopped owned activation.")), { once: true });
    });
    f.faux.setResponses([heldResponse]);
    const turn = f.home.prompt("Hold this owned activation until Stop");
    await waitFor(() => f.faux.state.callCount > calls || undefined, "owned Home provider activation is held");
    await f.decide(held);
    await waitFor(() => f.signals.some(signal => signal.outcome === "wake" && signal.decision === "deferred" && signal.reason === "busy") || undefined,
      "settings nudge observes the held activation as busy before Stop");
    await f.home.abort("agent"); await turn.catch(() => {});
    await waitFor(() => f.home.snapshot().operation === undefined || undefined, "Stop settles the owned activation");
    expect(outcomes(f.home)).toHaveLength(0);
    expect((await f.approvals.takeOutcomes([f.home.id])).map(request => request.requestId)).toEqual([held.approval!.requestId]);
    await f.registry.dispose(); await f.registry.administrativeWorkRegistry.waitUntilSettled();
    const taskDirectory = join(f.tronHome, "gateway", "home", "tasks");
    await fs.mkdir(taskDirectory, { recursive: true, mode: 0o700 });
    await fs.chmod(taskDirectory, 0o755);
    f.faux.setResponses(Array.from({ length: 80 }, () => f.respond as never));
    const cold = await f.restart(); const owner = homeOwnerOf(cold);
    expect(await owner.status()).toMatchObject({ taskRecovery: { available: false, reason: "unsafe-state" } });
    expect(await owner.status()).toMatchObject({ phase: "ready", enabled: true, readiness: { ready: true }, memory: { configured: true, paused: false } });
    // Repair only the fixture's task directory; its recovery refusal stays process-wide.
    await fs.chmod(taskDirectory, 0o700);
    evidence.push({ case: "cold-start-observed", status: await owner.status(), signals: f.signals });
    await waitFor(() => f.received.some(text => text.includes(held.approval!.requestId)) || undefined, "settings-only cold wake reaches the provider despite task recovery refusal");
    const slot = await cold.acquire(f.home.id);
    await waitFor(() => slot.snapshot().phase === "idle" && slot.snapshot().configurationBlocker === null || undefined, "independent settings wake replies");
    expect(f.received.filter(text => text.includes(held.approval!.requestId))).toHaveLength(1);
    await waitFor(async () => (await f.approvals.takeOutcomes([f.home.id])).length === 0 || undefined, "independent wake durable acknowledgement");
    expect(await owner.status()).toMatchObject({ taskRecovery: { available: false, reason: "unsafe-state" } });
    evidence.push({ case: "task-refused-independent-settings", requestId: held.approval!.requestId });
  });

  it("retains the outcome when the actual native request overflows context, then delivers on a usable input", async () => {
    const f = await gateway(8000); const owner = homeOwnerOf(f.registry); const held = await f.request("native refusal");
    const calls = f.faux.state.callCount;
    const heldResponse: FauxResponseFactory = (_context, options) => new Promise(resolve => {
      options?.signal?.addEventListener("abort", () => resolve(fauxAssistantMessage("Stopped owned activation.")), { once: true });
    });
    f.faux.setResponses([heldResponse]); const turn = f.home.prompt("Hold while the result settles");
    await waitFor(() => f.faux.state.callCount > calls || undefined, "owned native provider holds the user activation"); await f.decide(held);
    await waitFor(() => f.signals.some(signal => signal.outcome === "wake" && signal.decision === "deferred" && signal.reason === "busy") || undefined,
      "settled result observes the busy activation");
    await f.home.abort("agent"); await turn.catch(() => {});
    await waitFor(() => !f.home.isBusy || undefined, "Stop leaves native input ownership quiescent");
    expect(await owner.status()).toMatchObject({ phase: "ready", memory: { configured: true, paused: false } });
    const before = f.faux.state.callCount; f.faux.setResponses(Array.from({ length: 80 }, () => f.respond as never));
    await f.home.prompt("x".repeat(100000)).catch(() => {});
    await waitFor(() => !f.home.isBusy || undefined, "overflow refusal releases actual native ownership");
    evidence.push({ case: "native-overflow-observed", signals: f.signals, callsBefore: before, callsAfter: f.faux.state.callCount });
    expect(f.signals.some(signal => signal.event === "refused" && signal.reason === "context-overflow")).toBe(true);
    expect(f.faux.state.callCount).toBe(before); expect(outcomes(f.home)).toHaveLength(0);
    expect((await f.approvals.takeOutcomes([f.home.id])).map(request => request.requestId)).toEqual([held.approval!.requestId]);
    await prompt(f.home, "A usable input can hear the retained outcome");
    await waitFor(async () => (await f.approvals.takeOutcomes([f.home.id])).length === 0 || undefined, "usable input proves delivery");
    expect(outcomes(f.home)).toHaveLength(1);
    expect(f.providerInputs.filter(body => body === String(outcomes(f.home)[0]!.content))).toHaveLength(1);
    evidence.push({ case: "native-context-refusal", requestId: held.approval!.requestId });
  });

  it("delivers a settled Home outcome without joining an unrelated action's live effect", async () => {
    const f = await gateway(); const changes = f.settingsChanges;
    let release!: () => void; const gate = new Promise<void>(resolve => { release = resolve; });
    changes.registerAction("fixture.live-effect", {
      plan: async () => ({ title: "Held live effect", target: { kind: "global" }, items: [{ label: "Operation", value: "Await the owned gate" }] }),
      apply: async () => { await gate; return { summary: "Owned effect completed" }; },
    });
    changes.registerAction("fixture.other-target", {
      plan: async () => ({ title: "Independent Home operation", target: { kind: "home" }, items: [{ label: "Operation", value: "No shared target" }] }),
      apply: async () => ({ summary: "Not invoked for a decline" }),
    });
    const actor = { kind: "home" as const, id: f.home.id, sessionId: f.home.id };
    const active = await changes.requestAction("fixture.live-effect", {}, { actor, reason: "Hold the owned effect while unrelated delivery proceeds" });
    const applying = f.decide(active); let restarting: Promise<void> | undefined;
    try {
      await waitFor(async () => (await f.approvals.get(active.approval!.requestId))?.executionStartedAt || undefined, "actual execution claim precedes the held effect");
      restarting = changes.start(); await awaitsWithin(restarting, "repeated start does not recover this owner's live effect");
      const settled = await changes.requestAction("fixture.other-target", {}, { actor, reason: "Prove unrelated terminal delivery remains independent" }); await f.decide(settled, false);
      await waitFor(() => f.received.some(body => body.includes(settled.approval!.requestId)) || undefined, "independent outcome reaches Home while the other effect remains live");
      expect(await f.approvals.get(active.approval!.requestId)).toMatchObject({ status: "pending", executionStartedAt: expect.any(String) });
      expect(outcomes(f.home)).toHaveLength(1);
      expect(f.providerInputs.filter(body => body === String(outcomes(f.home)[0]!.content))).toHaveLength(1);
      evidence.push({ case: "live-effect-independent-outcome", live: active.approval!.requestId, delivered: settled.approval!.requestId });
    } finally { release(); await applying; await restarting; }
  });

  it("a cold selecting wake cannot outlive Stop and retirement of an intervening runtime", async () => {
    const f = await gateway(); const held = await f.request("cold Stop during selection");
    const cold = await f.restartToReadiness(); const owner = homeOwnerOf(cold);
    expect(cold.runtimeEntries().some(([id]) => id === f.home.id)).toBe(false);
    let release!: () => void; const gate = new Promise<void>(resolve => { release = resolve; }); let selecting = false;
    const take = f.settingsChanges.takeOutcomes.bind(f.settingsChanges);
    vi.spyOn(f.settingsChanges, "takeOutcomes").mockImplementation(async (...args) => {
      const message = await take(...args);
      if (message && !selecting) { selecting = true; await gate; }
      return message;
    });
    try {
      await f.decide(held, false); await owner.recoverTasks();
      await waitFor(() => selecting || undefined, "cold actual outbox selection held without constructing a runtime");
      expect(cold.runtimeEntries().some(([id]) => id === f.home.id)).toBe(false);
      const intervening = await cold.acquire(f.home.id); const calls = f.faux.state.callCount;
      await intervening.abort("agent"); await waitFor(() => !intervening.isBusy || undefined, "actual cold Stop reaches native quiescence");
      expect(await cold.retireIdleRuntime({ sessionId: f.home.id, slot: intervening, reason: "idle", eligible: () => true })).toBe(true);
      const replacement = await cold.acquire(f.home.id); expect(replacement).not.toBe(intervening);
      release(); await (owner as unknown as { wakeDrain?: Promise<void> }).wakeDrain;
      await waitFor(() => !replacement.isBusy || undefined, "cold pending attempt reaches native quiescence");
      expect(outcomes(replacement)).toHaveLength(0); expect(f.faux.state.callCount).toBe(calls);
      expect((await f.approvals.takeOutcomes([f.home.id])).map(request => request.requestId)).toEqual([held.approval!.requestId]);
      owner.requestWake();
      await waitFor(() => f.received.some(body => body.includes(held.approval!.requestId)) || undefined, "a genuinely new wake can deliver after Stop");
      await (owner as unknown as { wakeDrain?: Promise<void> }).wakeDrain;
      await waitFor(() => !replacement.isBusy || undefined, "fresh cold wake provider and native work settle");
      expect(outcomes(replacement)).toHaveLength(1);
      expect(f.providerInputs.filter(body => body === String(outcomes(replacement)[0]!.content))).toHaveLength(1);
      const entries = replacement.canonicalSessionEntries(); const delivered = entries.indexOf(outcomes(replacement)[0]!);
      expect(entries.slice(delivered + 1).some(entry => entry.type === "message" && entry.message.role === "assistant"
        && textOf(entry.message).includes("Outcome receipt confirmed."))).toBe(true);
      expect(await f.approvals.takeOutcomes([f.home.id])).toEqual([]);
      evidence.push({ case: "cold-stop-retirement", requestId: held.approval!.requestId });
    } finally { release(); }
  });

  it("Stop cancels an already selecting settings wake instead of reviving Home", async () => {
    const f = await gateway(); const owner = homeOwnerOf(f.registry);
    const held = await f.request("Stop during selection"); const calls = f.faux.state.callCount;
    const heldResponse: FauxResponseFactory = (_context, options) => new Promise(resolve => {
      options?.signal?.addEventListener("abort", () => resolve(fauxAssistantMessage("Stopped owned activation.")), { once: true });
    });
    f.faux.setResponses([heldResponse]); const turn = f.home.prompt("Hold the real provider until Stop");
    await waitFor(() => f.faux.state.callCount > calls || undefined, "owned user provider is held");
    let release!: () => void; const gate = new Promise<void>(resolve => { release = resolve; }); let selecting = false;
    const take = f.settingsChanges.takeOutcomes.bind(f.settingsChanges);
    vi.spyOn(f.settingsChanges, "takeOutcomes").mockImplementation(async (...args) => {
      const message = await take(...args);
      if (message && !selecting) { selecting = true; await gate; }
      return message;
    });
    try {
      await f.decide(held); await waitFor(() => selecting || undefined, "actual outbox selection is held after its real read");
      await f.home.abort("agent"); await turn.catch(() => {});
      await waitFor(() => !f.home.isBusy || undefined, "Stop settles all native owned work before releasing selection");
      f.faux.setResponses(Array.from({ length: 80 }, () => f.respond as never)); release();
      await (owner as unknown as { wakeDrain?: Promise<void> }).wakeDrain;
      await waitFor(() => !f.home.isBusy || undefined, "the pending wake attempt reaches native quiescence");
      expect(outcomes(f.home)).toHaveLength(0);
      expect(f.faux.state.callCount).toBe(calls + 1);
      expect((await f.approvals.takeOutcomes([f.home.id])).map(request => request.requestId)).toEqual([held.approval!.requestId]);
      evidence.push({ case: "stop-held-selection", requestId: held.approval!.requestId });
    } finally { release(); }
  });

  it.each(["file", "directory"] as const)("requires durable delivery before sealing a chapter after a %s sync failure", async kind => {
    const f = await gateway(); const owner = homeOwnerOf(f.registry); const path = f.home.sessionFile!;
    const target = await fs.stat(kind === "file" ? path : dirname(path)); const sync = durability.syncDurably; let failed = 0;
    vi.spyOn(durability, "syncDurably").mockImplementation(async handle => {
      const current = await (handle as import("node:fs/promises").FileHandle).stat();
      if (outcomes(f.home).length && current.dev === target.dev && current.ino === target.ino) {
        failed++; throw new Error(`Owned canonical ${kind} sync fault`);
      }
      await sync(handle);
    });
    const held = await f.request(`seal after ${kind} fault`); await f.decide(held);
    await waitFor(() => outcomes(f.home).length === 1 && f.home.snapshot().phase === "idle" || undefined, "outcome appends and provider completes");
    await waitFor(() => failed > 0 || undefined, "actual canonical durability proof fails"); await owner.pauseMemory();
    await (owner as unknown as { wakeDrain?: Promise<void> }).wakeDrain;
    await waitFor(() => !f.home.isBusy || undefined, "all earlier wake receipts settle before measuring rollover");
    const frozen = await fs.readFile(path, "utf8");
    const measured = owner as unknown as { options: { sessions: { chapterMetrics(id: string): Promise<{ bytes: number; entries: number; quiescent: boolean }> } } };
    const metrics = measured.options.sessions.chapterMetrics;
    try {
      measured.options.sessions.chapterMetrics = async () => ({ bytes: 24 * 1024 * 1024 + 1, entries: 3, quiescent: true });
      await expect(owner.chapterQuiescent(f.home.id)).rejects.toThrow(`Owned canonical ${kind} sync fault`);
      expect(await owner.status()).toMatchObject({ sessionId: f.home.id, chapter: { count: 1 } });
      expect((await f.approvals.takeOutcomes([f.home.id])).map(request => request.requestId)).toEqual([held.approval!.requestId]);
      vi.restoreAllMocks(); await owner.chapterQuiescent(f.home.id);
    } finally { measured.options.sessions.chapterMetrics = metrics; }
    expect(await owner.status()).toMatchObject({ phase: "rollover-pending", chapter: { count: 2 } });
    expect(await f.approvals.takeOutcomes([f.home.id])).toEqual([]);
    expect(await fs.readFile(path, "utf8")).toBe(frozen); expect(outcomes(f.home)).toHaveLength(1);
    evidence.push({ case: `seal-${kind}-proof`, requestId: held.approval!.requestId, failed });
  });

  it("admits no settings trigger outside the Home input envelope and retains the outcome", async () => {
    const f = await gateway(); const owner = homeOwnerOf(f.registry); await owner.pauseMemory();
    const held = await f.request("no headroom"); await f.decide(held);
    const trigger = await owner.admitTaskResults(f.home.id, "no-headroom", "wake", async () => { throw new Error("No message fits"); },
      async () => ({ signal: new AbortController().signal, tokens: 0, freshTokens: 128000, bytes: 0, entries: 0 }));
    expect(trigger).toBeUndefined();
    expect(outcomes(f.home)).toHaveLength(0);
    expect((await f.approvals.takeOutcomes([f.home.id])).map(request => request.requestId)).toEqual([held.approval!.requestId]);
    evidence.push({ case: "input-envelope-headroom", requestId: held.approval!.requestId });
  });

  it("honors the activation cancellation signal before returning a settings wake trigger", async () => {
    const f = await gateway(); const owner = homeOwnerOf(f.registry); await owner.pauseMemory();
    const held = await f.request("cancelled input"); await f.decide(held);
    const controller = new AbortController(); controller.abort(new Error("Owned activation stopped"));
    await expect(owner.admitTaskResults(f.home.id, "cancelled", "wake", async () => { throw new Error("Cancelled append"); },
      async () => ({ signal: controller.signal, tokens: 128000, freshTokens: 128000, bytes: 1000000, entries: 1000 }))).rejects.toThrow("Owned activation stopped");
    expect(outcomes(f.home)).toHaveLength(0);
    expect((await f.approvals.takeOutcomes([f.home.id])).map(request => request.requestId)).toEqual([held.approval!.requestId]);
    evidence.push({ case: "input-envelope-cancel", requestId: held.approval!.requestId });
  });

  it("delivers a requesting sealed chapter's outcome in its successor to the provider, once", async () => {
    const f = await gateway(); const held = await f.request("chapter A");
    const owner = homeOwnerOf(f.registry);
    // Existing chapter metrics port drives the normal quiescent rollover owner;
    // neither the Home record nor canonical session is manually rewritten.
    const measured = owner as unknown as { options: { sessions: { chapterMetrics(id: string): Promise<{ bytes: number; entries: number; quiescent: boolean }> } } };
    const metrics = measured.options.sessions.chapterMetrics;
    try {
      measured.options.sessions.chapterMetrics = async () => ({ bytes: 24 * 1024 * 1024 + 1, entries: 3, quiescent: true });
      await owner.chapterQuiescent(f.home.id);
    } finally { measured.options.sessions.chapterMetrics = metrics; }
    const successor = await owner.status();
    expect(successor.phase).toBe("rollover-pending"); expect(successor.sessionId).not.toBe(f.home.id);
    const frozen = await fs.readFile(f.home.sessionFile!, "utf8");
    await f.decide(held);
    evidence.push({ case: "rollover-observed", status: await owner.status(), signals: f.signals });
    await waitFor(() => f.received.some(turn => turn.includes(held.approval!.requestId)) || undefined, "successor provider hears historical request outcome without a user prompt");
    const slot = await f.registry.acquire(successor.sessionId);
    await waitFor(() => slot.snapshot().phase === "idle" && slot.snapshot().configurationBlocker === null || undefined, "successor successful reply");
    expect(outcomes(slot)).toHaveLength(1); expect(outcomes(f.home)).toHaveLength(0);
    const canonicalBody = String(outcomes(slot)[0]!.content);
    expect(f.providerInputs.filter(body => body === canonicalBody)).toHaveLength(1);
    const entries = slot.canonicalSessionEntries(); const index = entries.indexOf(outcomes(slot)[0]!);
    expect(entries.slice(index + 1).some(entry => entry.type === "message" && entry.message.role === "assistant"
      && textOf(entry.message).includes("Outcome receipt confirmed."))).toBe(true);
    await waitFor(async () => (await f.approvals.takeOutcomes([f.home.id])).length === 0 || undefined, "historical requester acknowledged after successor durable proof");
    expect(await fs.readFile(f.home.sessionFile!, "utf8")).toBe(frozen);
    const cold = await f.restart(); const current = await cold.acquire(successor.sessionId);
    await prompt(current, "Continue after cold recovery");
    expect(outcomes(current)).toHaveLength(1);
    // A memory view may quote the prior request ID; that is not a second
    // settings delivery. Prove the actual canonical body, not substring counts.
    expect(f.providerInputs.filter(body => body === canonicalBody)).toHaveLength(1);
    evidence.push({ case: "chapter-rollover", requestId: held.approval!.requestId, requester: f.home.id, deliveredTo: successor.sessionId });
  });
});
