import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { fauxAssistantMessage, fauxToolCall } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { fixture, disposeFixtures } from "../../test-support/home-task-fixture.js";
import { waitFor } from "../../test-support/wait-for.js";
import { setHomeMemoryModels } from "../../test-support/settings-dependencies.js";
import type { ExtensionInteraction } from "../protocol/types.js";

// A real Home runtime on a faux model. The durable approval must also publish
// an in-turn client interaction; a settings invalidation alone is not a prompt.
afterEach(disposeFixtures);

async function pendingApproval(options: Parameters<typeof fixture>[5] = {}) {
  const f = await fixture(false, false, undefined, false, undefined, options);
  await setHomeMemoryModels(f.registry, [{ provider: f.model.provider, id: f.model.id }]);
  f.faux.setResponses([
    fauxAssistantMessage([fauxToolCall("settings", { action: "request", reason: "Retry a transient failure", changes: [
      { key: "run.retry.maxRetries", layer: "session", op: "set", value: 3 },
    ] }, { id: "settings-request" })], { stopReason: "toolUse" }),
    fauxAssistantMessage("Finished"),
  ]);
  const home = await f.registry.acquire(f.home.sessionId);
  const prompting = home.prompt("Request a retry setting change");
  const interaction = await waitFor(() => home.snapshot().extensionPresentation.pendingInteractions[0], "settings approval form");
  const request = (await f.settings.settingsChanges.pendingApprovals())[0]!;
  const answer = (choice: "approve" | "deny", current: ExtensionInteraction = interaction) => home.respondToInteraction(current.id, current.hostEpoch, current.presentationRevision,
    { version: 1, answers: [{ questionId: request.requestId, optionIds: [choice] }] }, false);
  return { ...f, home, prompting, interaction, request, answer };
}

async function saveCase(name: string, evidence: unknown) {
  const directory = join(process.cwd(), "test-results/settings-approval-blocking");
  await mkdir(directory, { recursive: true });
  await writeFile(join(directory, `${name}.json`), `${JSON.stringify(evidence, null, 2)}\n`);
}

describe("blocking settings approval", () => {
  it("Home publishes a client-visible approval prompt before returning the settings result", async () => {
    const f = await fixture();
    await setHomeMemoryModels(f.registry, [{ provider: f.model.provider, id: f.model.id }]);
    f.faux.setResponses([
      fauxAssistantMessage([fauxToolCall("settings", { action: "request", reason: "Retry a transient failure", changes: [
        { key: "run.retry.maxRetries", layer: "session", op: "set", value: 3 },
      ] })], { stopReason: "toolUse" }),
      fauxAssistantMessage("Finished"),
    ]);
    const home = await f.registry.acquire(f.home.sessionId);
    const prompting = home.prompt("Request a retry setting change");
    try {
      const request = await waitFor(async () => (await f.settings.settingsChanges.pendingApprovals())[0], "Home creates its approval request");
      await waitFor(() => home.snapshot().extensionPresentation.pendingInteractions.length > 0
        || home.snapshot().transcript.some(item => item.kind === "message" && item.role === "toolResult"), "approval prompt or returned tool result");
      const snapshot = home.snapshot();
      const evidence = {
        request: { requestId: request.requestId, status: request.status, actor: request.actor, target: request.target },
        clientInteractions: snapshot.extensionPresentation.pendingInteractions,
        isBusy: home.isBusy,
        toolResults: snapshot.transcript.filter(item => item.kind === "message" && item.role === "toolResult"),
      };
      const directory = join(process.cwd(), "test-results");
      await mkdir(directory, { recursive: true });
      await writeFile(join(directory, "settings-approval-blocking.json"), `${JSON.stringify(evidence, null, 2)}\n`);
      expect(snapshot.extensionPresentation.pendingInteractions).toHaveLength(1);
    } finally {
      await mkdir(join(process.cwd(), "test-results"), { recursive: true });
      await writeFile(join(process.cwd(), "test-results/settings-approval-blocking-final.json"), `${JSON.stringify({ snapshot: home.snapshot(), events: f.events }, null, 2)}\n`);
      await home.abort("agent");
      await prompting;
    }
  });

  it("an own-session SDK change is refused before asking for an approval it cannot apply mid-turn", async () => {
    const f = await fixture();
    await setHomeMemoryModels(f.registry, [{ provider: f.model.provider, id: f.model.id }]);
    f.faux.setResponses([
      fauxAssistantMessage([fauxToolCall("settings", { action: "request", reason: "Less thinking", changes: [
        { key: "model.thinking[role=chat]", layer: "session", op: "set", value: "low" },
      ] })], { stopReason: "toolUse" }), fauxAssistantMessage("Noted"),
    ]);
    const home = await f.registry.acquire(f.home.sessionId);
    await home.prompt("Request own thinking change");
    try {
      await waitFor(() => home.snapshot().extensionPresentation.pendingInteractions.length > 0
        || home.snapshot().transcript.some(item => item.kind === "message" && item.role === "toolResult"), "own SDK change refusal or prompt");
      expect(home.snapshot().extensionPresentation.pendingInteractions).toEqual([]);
      expect(await f.settings.settingsChanges.pendingApprovals()).toEqual([]);
      const result = home.snapshot().transcript.find(item => item.kind === "message" && item.role === "toolResult");
      expect(result).toMatchObject({ isError: true, content: [expect.objectContaining({ text: expect.stringContaining("between runs") })] });
    } finally { await home.abort("agent"); }
  });

  for (const choice of ["approve", "deny"] as const) {
    it(`${choice} resumes the same tool turn with an explicit outcome and consumes its tap once`, async () => {
      const f = await pendingApproval();
      try {
        expect(f.interaction.method).toBe("form");
        expect(f.home.isBusy).toBe(true);
        expect(f.home.snapshot().transcript.some(item => item.kind === "message" && item.role === "toolResult")).toBe(false);
        f.answer(choice);
        await f.prompting;
        await waitFor(() => !f.home.isBusy, "approval turn settles");
        const snapshot = f.home.snapshot();
        expect(snapshot.extensionPresentation.pendingInteractions).toEqual([]);
        const result = snapshot.transcript.find(item => item.kind === "message" && item.role === "toolResult" && item.toolCallId === "settings-request");
        expect(result).toMatchObject({ details: { status: choice === "approve" ? "approved" : "declined" } });
        expect((await f.settings.settingsChanges.pendingApprovals())).toEqual([]);
        const history = (await f.settings.settingsChanges.history({ key: "run.retry.maxRetries" })).entries;
        expect(history.map(entry => entry.status)).toContain(choice === "approve" ? "approved" : "declined");
        expect(() => f.answer(choice)).toThrow();
        await expect(f.settings.settingsChanges.decide(f.request.requestId, { digest: f.request.digest, approved: true, decidedBy: { kind: "ui", id: "phone" } })).rejects.toThrow();
        expect(await f.settings.settingsChanges.takeOutcomes([f.home.id])).toBeUndefined();
        await saveCase(choice, { interaction: f.interaction, result, history });
      } finally { await f.home.abort("agent"); await f.prompting; }
    });
  }

  it("Stop while approval is pending cancels both the form and the exact diff", async () => {
    const f = await pendingApproval();
    await f.home.abort("agent");
    await f.prompting;
    expect(f.home.snapshot().extensionPresentation.pendingInteractions).toEqual([]);
    expect(await f.settings.settingsChanges.pendingApprovals()).toEqual([]);
    const history = (await f.settings.settingsChanges.history({ key: "run.retry.maxRetries" })).entries;
    expect(history).toEqual(expect.arrayContaining([expect.objectContaining({ status: "superseded", failure: expect.stringMatching(/cancelled/) })]));
    expect(history.some(entry => entry.status === "approved")).toBe(false);
    expect(() => f.answer("approve")).toThrow();
    await expect(f.settings.settingsChanges.decide(f.request.requestId, { digest: f.request.digest, approved: true, decidedBy: { kind: "ui", id: "phone" } })).rejects.toThrow();
    await saveCase("stop", { history, interactions: f.home.snapshot().extensionPresentation.pendingInteractions });
  });

  it("an Approve tap racing the deadline returns expired rather than a tool error", async () => {
    let now = new Date("2030-01-01T00:00:00Z");
    const f = await pendingApproval({ settingsNow: () => now });
    try {
      f.answer("approve");
      now = new Date("2030-01-02T00:00:00Z");
      await waitFor(() => !f.home.isBusy, "deadline-racing approval settles");
      const result = f.home.snapshot().transcript.find(item => item.kind === "message" && item.role === "toolResult" && item.toolCallId === "settings-request");
      expect(result).toMatchObject({ isError: false, details: { status: "expired" } });
      expect((await f.settings.settingsChanges.history({ key: "run.retry.maxRetries" })).entries.some(entry => entry.status === "approved")).toBe(false);
      await saveCase("tap-expiry-race", { result });
    } finally { await f.home.abort("agent"); await f.prompting; }
  });

  it("24 hour expiry retires the form and resumes with an explicit expired outcome", async () => {
    let now = new Date("2030-01-01T00:00:00Z");
    const f = await pendingApproval({ settingsNow: () => now });
    try {
      now = new Date("2030-01-02T00:00:00Z");
      expect(await f.settings.settingsChanges.pendingApprovals()).toEqual([]);
      await f.prompting;
      await waitFor(() => !f.home.isBusy, "expired approval turn settles");
      const snapshot = f.home.snapshot();
      expect(snapshot.extensionPresentation.pendingInteractions).toEqual([]);
      const result = snapshot.transcript.find(item => item.kind === "message" && item.role === "toolResult" && item.toolCallId === "settings-request");
      expect(result).toMatchObject({ details: { status: "expired" } });
      expect(() => f.answer("approve")).toThrow();
      await saveCase("expiry", { result });
    } finally { await f.home.abort("agent"); await f.prompting; }
  });
});
