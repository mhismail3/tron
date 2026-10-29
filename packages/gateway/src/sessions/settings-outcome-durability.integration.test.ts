import { spawn } from "node:child_process";
import { once } from "node:events";
import { appendFile, mkdir, readFile, stat, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { fauxAssistantMessage, type TranscriptContext } from "@earendil-works/pi-ai";
import { afterAll, afterEach, describe, expect, it, vi } from "vitest";
import { disposeFixtures, fixture } from "../../test-support/home-task-fixture.js";
import { homeOwnerOf } from "../../test-support/gateway-registry.js";
import { setHomeMemoryModels } from "../../test-support/settings-dependencies.js";
import { waitFor } from "../../test-support/wait-for.js";
import { SettingsApprovals, APPROVAL_TTL_MS } from "../kernel/settings/settings-approvals.js";
import { SETTINGS_OUTCOME_MESSAGE } from "../kernel/receipts/delivery-tags.js";
import * as durability from "../foundation/durable-json.js";
import { INVOCATION_RECEIPT_TYPE } from "../kernel/receipts/invocation-receipts.js";
import { CONTEXT_DELIVERY_RECEIPT_TYPE } from "../kernel/receipts/delivery-tags.js";

const artifacts: unknown[] = [];
afterEach(async () => { vi.restoreAllMocks(); await disposeFixtures(); });
afterAll(async () => {
  const path = fileURLToPath(new URL("../../test-results/settings-outcome-durability.json", import.meta.url));
  await mkdir(dirname(path), { recursive: true }); await writeFile(path, `${JSON.stringify(artifacts, null, 2)}\n`);
});

async function gateway() {
  let clock = Date.now();
  const timers: Array<{ run(): void; cancelled: boolean }> = [];
  const f = await fixture(false, false, undefined, false, undefined, {
    settingsNow: () => new Date(clock),
    settingsSchedule: run => { const timer = { run, cancelled: false }; timers.push(timer); return { cancel: () => { timer.cancelled = true; } }; },
  });
  const { settingsChanges } = f.settings;
  await setHomeMemoryModels(f.registry, [{ provider: f.model.provider, id: f.model.id }]);
  f.faux.setResponses(Array.from({ length: 60 }, () => fauxAssistantMessage("Noted.")));
  const slot = await f.registry.create(f.cwd); await slot.setModel(f.model.provider, f.model.id);
  await prompt(slot, "Create the canonical conversation");
  const approvals = new SettingsApprovals(f.tronHome);
  const effects = join(f.cwd, "approval-effects");
  settingsChanges.registerAction("fixture.durable", {
    plan: async () => ({ title: "Write the marker", target: { kind: "global" }, items: [{ label: "Effect", value: "One marker" }] }),
    apply: async () => { await appendFile(effects, "applied\n"); return { summary: "Marker written" }; },
  });
  const request = (sessionId: string, kind: "agent" | "home" = "agent") => settingsChanges.requestAction("fixture.durable", {},
    { actor: { kind, id: sessionId, sessionId }, reason: "Canonical delivery boundary proof" });
  return { ...f, slot, settingsChanges, approvals, effects, request, timers, advance: () => { clock += APPROVAL_TTL_MS + 1; } };
}
const outcomes = (slot: Awaited<ReturnType<typeof gateway>>["slot"]) => slot.canonicalSessionEntries().filter(entry => entry.type === "custom_message" && entry.customType === SETTINGS_OUTCOME_MESSAGE);
async function prompt(slot: import("../kernel/run/runtime-slot.js").RuntimeSlot, text: string): Promise<void> {
  await slot.prompt(text);
  await waitFor(() => slot.snapshot().phase === "idle" && slot.snapshot().configurationBlocker === null || undefined, "real prompt settled");
}

/** Real Registry/Pi/store/filesystem boundary: an SDK-visible delivery may retire
 * the sole approvals outbox only after both canonical file and directory sync. */
describe("native settings outcome durability", () => {
  it.each(["file", "directory"] as const)("a %s sync failure defers acknowledgement, not the prompt, and retry never duplicates", async kind => {
    const f = await gateway();
    const held = await f.request(f.slot.id);
    await f.settingsChanges.decide(held.approval!.requestId, { digest: held.approval!.digest, approved: true, decidedBy: { kind: "ui", id: "phone" } });
    await prompt(f.slot, "Hear the outcome");
    expect(outcomes(f.slot)).toHaveLength(1);
    expect((await f.approvals.takeOutcomes([f.slot.id])).map(request => request.requestId)).toEqual([held.approval!.requestId]);
    const path = f.slot.sessionFile!;
    const target = await stat(kind === "file" ? path : dirname(path));
    const sync = durability.syncDurably;
    let failed = false;
    vi.spyOn(durability, "syncDurably").mockImplementation(async handle => {
      const info = await (handle as import("node:fs/promises").FileHandle).stat();
      if (!failed && info.dev === target.dev && info.ino === target.ino) { failed = true; throw new Error(`injected canonical ${kind} sync failure`); }
      await sync(handle);
    });
    await prompt(f.slot, "Continue despite failed durability proof");
    expect(failed).toBe(true);
    expect(f.slot.snapshot().phase).toBe("idle");
    expect(outcomes(f.slot)).toHaveLength(1);
    expect((await f.approvals.takeOutcomes([f.slot.id])).map(request => request.requestId)).toEqual([held.approval!.requestId]);
    vi.restoreAllMocks();
    await prompt(f.slot, "Retry the durable proof");
    expect(await f.approvals.takeOutcomes([f.slot.id])).toEqual([]);
    expect(outcomes(f.slot)).toHaveLength(1);
    artifacts.push({ case: `sync-${kind}`, requestId: held.approval!.requestId, delivered: outcomes(f.slot).map(entry => entry.id) });
  });

  it.each(["before", "after"] as const)("a killed SDK writer %s canonical append recovers one outcome without replaying its effect", async cut => {
    const f = await gateway();
    const held = await f.request(f.slot.id);
    await f.settingsChanges.decide(held.approval!.requestId, { digest: held.approval!.digest, approved: true, decidedBy: { kind: "ui", id: "phone" } });
    const outcome = await f.settingsChanges.takeOutcomes([f.slot.id]);
    const input = join(f.root, "outcome-input.json"); const marker = join(f.root, "outcome-cut");
    await writeFile(input, JSON.stringify({ path: f.slot.sessionFile, outcome }));
    await f.registry.dispose();
    const program = fileURLToPath(new URL("../../test-support/settings-outcome-crash-child.ts", import.meta.url));
    const preload = fileURLToPath(new URL("../../test-support/home-ledger-crash-preload.mjs", import.meta.url));
    const child = spawn(process.execPath, ["--experimental-transform-types", "--import", pathToFileURL(preload).href, program, input, cut, marker], { stdio: ["pipe", "pipe", "pipe"] });
    let output = ""; child.stderr.on("data", chunk => { output += String(chunk); });
    try {
      await waitFor(async () => {
        if (child.exitCode !== null) throw new Error(`Crash child exited early: ${output}`);
        return await readFile(marker, "utf8").then(() => true, () => undefined);
      }, "owned child reached the actual SDK append cut");
      const exited = once(child, "exit"); child.kill("SIGKILL");
      expect((await exited)[1]).toBe("SIGKILL");
      const cold = await f.restart();
      const slot = await cold.acquire(f.slot.id);
      await prompt(slot, "Recover the outcome"); await prompt(slot, "Prove it stays heard once");
      expect(outcomes(slot)).toHaveLength(1);
      expect(await f.approvals.takeOutcomes([slot.id])).toEqual([]);
      expect(await readFile(f.effects, "utf8")).toBe("applied\n");
      artifacts.push({ case: `crash-${cut}`, requestId: held.approval!.requestId, canonical: outcomes(slot).map(entry => entry.id) });
    } finally {
      if (child.exitCode === null && child.signalCode === null) { const exited = once(child, "exit"); child.kill("SIGKILL"); await exited; }
    }
  });

  it.each(["approved", "declined", "expired"] as const)("Home hears %s autonomously with native invocation and delivery receipts", async status => {
    const f = await gateway(); const owner = homeOwnerOf(f.registry); const slot = await f.registry.acquire(f.home.sessionId);
    await prompt(slot, "Open Home before its request settles");
    const providerOutcomes: string[] = [];
    f.faux.setResponses(Array.from({ length: 60 }, () => (context: TranscriptContext) => {
      for (const message of context.messages) {
        if (message.role !== "user") continue;
        const text = typeof message.content === "string" ? message.content
          : message.content.filter(part => part.type === "text").map(part => part.text).join("");
        if (text.startsWith("Settings request ")) providerOutcomes.push(text);
      }
      return fauxAssistantMessage("Outcome heard successfully.");
    }));
    const held = await f.request(slot.id, "home");
    if (status === "expired") {
      await waitFor(() => f.timers.some(timer => !timer.cancelled) || undefined, "request deadline armed");
      f.advance(); f.timers.filter(timer => !timer.cancelled).at(-1)!.run();
    } else await f.settingsChanges.decide(held.approval!.requestId, { digest: held.approval!.digest, approved: status === "approved", decidedBy: { kind: "ui", id: "phone" } });
    await waitFor(() => outcomes(slot).length === 1 && slot.snapshot().phase === "idle" || undefined, "autonomous settings wake settles without a user prompt").catch(error => {
      artifacts.push({ case: `autonomous-${status}-failure`, entries: slot.canonicalSessionEntries(), snapshot: slot.snapshot(), signals: f.signals }); throw error;
    });
    await waitFor(async () => (await f.approvals.takeOutcomes([slot.id])).length === 0 || undefined, "durable wake acknowledgement");
    const entries = slot.canonicalSessionEntries(); const message = outcomes(slot)[0]!;
    expect(message).toMatchObject({ details: { requests: [{ requestId: held.approval!.requestId, status }] } });
    expect(providerOutcomes).toEqual([String(message.content)]);
    expect(entries.slice(entries.indexOf(message) + 1).some(entry => entry.type === "message" && entry.message.role === "assistant"
      && entry.message.content.some(part => part.type === "text" && part.text === "Outcome heard successfully."))).toBe(true);
    expect(entries.some(entry => entry.type === "custom" && entry.customType === INVOCATION_RECEIPT_TYPE
      && (entry.data as { receiptKind?: string; canonicalEntryId?: string }).receiptKind === "binding"
      && (entry.data as { canonicalEntryId?: string }).canonicalEntryId === message.id)).toBe(true);
    expect(entries.some(entry => entry.type === "custom" && entry.customType === CONTEXT_DELIVERY_RECEIPT_TYPE
      && JSON.stringify(entry.data).includes("gateway:settings") && JSON.stringify(entry.data).includes(message.id))).toBe(true);
    expect((await owner.status()).enabled).toBe(true);
    artifacts.push({ case: `autonomous-${status}`, requestId: held.approval!.requestId, canonicalEntryId: message.id });
  });

  it.each(["file", "directory"] as const)("Home retains a visible outcome after a %s sync failure and acknowledges it once after recovery", async kind => {
    const f = await gateway(); const owner = homeOwnerOf(f.registry); const slot = await f.registry.acquire(f.home.sessionId);
    await prompt(slot, "Open Home before the durability fault");
    const path = slot.sessionFile!;
    const target = await stat(kind === "file" ? path : dirname(path));
    const sync = durability.syncDurably;
    let failed = 0;
    vi.spyOn(durability, "syncDurably").mockImplementation(async handle => {
      const info = await (handle as import("node:fs/promises").FileHandle).stat();
      // Initial selection may read durable history. Fail only the post-append
      // proof, when the actual SDK already exposes this settings message.
      if (outcomes(slot).length > 0 && info.dev === target.dev && info.ino === target.ino) {
        failed += 1; throw new Error(`injected Home canonical ${kind} sync failure`);
      }
      await sync(handle);
    });
    const held = await f.request(slot.id, "home");
    await f.settingsChanges.decide(held.approval!.requestId, { digest: held.approval!.digest, approved: true, decidedBy: { kind: "ui", id: "phone" } });
    await waitFor(() => outcomes(slot).length === 1 && slot.snapshot().phase === "idle" || undefined, "Home outcome visibly appended");
    await waitFor(async () => failed > 0 || (await f.approvals.takeOutcomes([slot.id])).length === 0 || undefined, "Home attempts post-append proof or acknowledgement");
    expect(failed).toBeGreaterThan(0);
    await owner.pauseMemory();
    expect(outcomes(slot)).toHaveLength(1);
    expect((await f.approvals.takeOutcomes([slot.id])).map(request => request.requestId)).toEqual([held.approval!.requestId]);
    vi.restoreAllMocks();
    await owner.resumeMemory();
    await waitFor(async () => (await f.approvals.takeOutcomes([slot.id])).length === 0 || undefined, "Home acknowledges the existing outcome after durable recovery");
    expect(outcomes(slot)).toHaveLength(1);
    expect(await readFile(f.effects, "utf8")).toBe("applied\n");
    artifacts.push({ case: `home-sync-${kind}`, failed, requestId: held.approval!.requestId, canonicalEntryId: outcomes(slot)[0]!.id });
  });

  it("a paused Home refuses a wake without consuming its outcome, then resumes autonomously", async () => {
    const f = await gateway(); const owner = homeOwnerOf(f.registry); const slot = await f.registry.acquire(f.home.sessionId);
    await prompt(slot, "Open Home before pausing"); await owner.pauseMemory();
    const held = await f.request(slot.id, "home");
    await f.settingsChanges.decide(held.approval!.requestId, { digest: held.approval!.digest, approved: false, decidedBy: { kind: "ui", id: "phone" } });
    await waitFor(() => f.signals.some(signal => signal.outcome === "wake" && signal.reason === "paused") || undefined, "paused wake refusal");
    expect(outcomes(slot)).toHaveLength(0);
    expect((await f.approvals.takeOutcomes([slot.id])).map(request => request.requestId)).toEqual([held.approval!.requestId]);
    await owner.resumeMemory();
    await waitFor(() => outcomes(slot).length === 1 && slot.snapshot().phase === "idle" || undefined, "resume delivers the retained outcome without a prompt");
    await waitFor(async () => (await f.approvals.takeOutcomes([slot.id])).length === 0 || undefined, "resumed outcome acknowledgement");
    artifacts.push({ case: "refused-then-resumed", requestId: held.approval!.requestId });
  });
});
