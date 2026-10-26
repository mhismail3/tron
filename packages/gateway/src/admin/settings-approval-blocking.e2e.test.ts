import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { fauxAssistantMessage, fauxToolCall, type TranscriptContext } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { fixture, disposeFixtures, reportCall } from "../../test-support/home-task-fixture.js";
import { waitFor } from "../../test-support/wait-for.js";
import { setHomeMemoryModels } from "../../test-support/settings-dependencies.js";
import type { ExtensionInteraction } from "../protocol/types.js";
import type { ChangeRequest } from "../kernel/settings/tool-contract.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "../transport/gateway-service.js";
import { CommandReceiptStore } from "../transport/command-receipts.js";
import { UploadStore } from "../machine/upload-store.js";
import { DEFAULT_MAX_UPLOAD_BYTES } from "../config.js";
import { displayOwnerOf, homeOwnerOf } from "../../test-support/gateway-registry.js";

// A real Home runtime on a faux model. The durable approval must also publish
// an in-turn client interaction; a settings invalidation alone is not a prompt.
afterEach(disposeFixtures);

async function settledWorker(f: Awaited<ReturnType<typeof fixture>>) {
  const home = await f.registry.acquire(f.home.sessionId);
  const respond = (context: TranscriptContext) => {
    if (context.messages.some(message => message.role === "user" && JSON.stringify(message.content).includes("This is a finite Home task"))) {
      return fauxAssistantMessage([reportCall("diff-worker")], { stopReason: "toolUse" });
    }
    const last = context.messages.at(-1);
    return last?.role === "user" && JSON.stringify(last.content).includes("Create diff worker")
      ? fauxAssistantMessage([fauxToolCall("delegate", { taskId: "diff-worker", title: "Review diff worker", intent: "Report at once", target: f.cwd })], { stopReason: "toolUse" })
      : fauxAssistantMessage("Noted");
  };
  f.faux.setResponses(Array.from({ length: 20 }, () => respond as never));
  await home.prompt("Create diff worker");
  await waitFor(async () => (await homeOwnerOf(f.registry).taskResult("diff-worker").catch(() => undefined) as { wake?: { state?: string } } | undefined)?.wake?.state === "acknowledged" || undefined, "diff worker result acknowledged");
  await waitFor(() => !home.isBusy, "Home settled after diff worker");
  return "diff-worker";
}

async function pendingApproval(options: Parameters<typeof fixture>[5] = {}, changes: ChangeRequest[] = [
  { key: "run.retry.maxRetries", layer: "session", op: "set", value: 3 },
], worker = false, reason = "Retry a transient failure") {
  const f = await fixture(false, false, undefined, false, undefined, options);
  await setHomeMemoryModels(f.registry, [{ provider: f.model.provider, id: f.model.id }]);
  const taskId = worker ? await settledWorker(f) : undefined;
  f.faux.setResponses([
    fauxAssistantMessage([fauxToolCall("settings", { action: "request", reason, changes, ...(taskId ? { taskId } : {}) }, { id: "settings-request" })], { stopReason: "toolUse" }),
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

  it("dry run refuses the same own-turn SDK change without creating a form, approval or write", async () => {
    const f = await fixture();
    await setHomeMemoryModels(f.registry, [{ provider: f.model.provider, id: f.model.id }]);
    const home = await f.registry.acquire(f.home.sessionId);
    const before = home.snapshot().thinkingLevel;
    f.faux.setResponses([
      fauxAssistantMessage([fauxToolCall("settings", { action: "request", dryRun: true, reason: "Preview less thinking", changes: [
        { key: "model.thinking[role=chat]", layer: "session", op: "set", value: "low" },
      ] })], { stopReason: "toolUse" }), fauxAssistantMessage("Noted"),
    ]);
    await home.prompt("Preview own thinking change");
    try {
      const result = await waitFor(() => home.snapshot().transcript.find(item => item.kind === "message" && item.role === "toolResult"), "dry-run result");
      expect(result).toMatchObject({ isError: false, details: { dryRun: true, changes: [
        expect.objectContaining({ status: "failed", error: { code: "busy", message: expect.stringContaining("between runs") } }),
      ] } });
      expect(result).toMatchObject({ details: { status: "failed", tier: "quiet" } });
      expect(home.snapshot().extensionPresentation.pendingInteractions).toEqual([]);
      expect(await f.settings.settingsChanges.pendingApprovals()).toEqual([]);
      expect((await f.settings.settingsChanges.history({ key: "model.thinking" })).entries).toEqual([]);
      expect(home.snapshot().thinkingLevel).toBe(before);
      await saveCase("dry-run-admission", { before, after: home.snapshot().thinkingLevel, result });
    } finally { await home.abort("agent"); }
  });

  it("the form contains complete long text and tool selections rather than display summaries", async () => {
    const instructions = "Keep every detail " + "x".repeat(120) + " [label](https://example.test/full-target) ![image](https://example.test/raw.png)";
    const tools = ["read", "write", "edit", "bash", "settings"];
    const f = await pendingApproval({}, [
      { key: "context.compaction.instructions", layer: "session", op: "set", value: instructions },
      { key: "tools.active", layer: "session", op: "set", value: tools },
    ], true);
    try {
      const context = f.interaction.form!.questions[0]!.context!;
      expect(context).toContain(JSON.stringify(instructions, null, 2));
      expect(context).toContain(JSON.stringify(tools, null, 2));
      expect(context).not.toContain("…");
      f.answer("deny");
      await f.prompting;
      await waitFor(() => !f.home.isBusy, "full diff denial settles");
      await saveCase("complete-diff", { interaction: f.interaction });
    } finally { await f.home.abort("agent"); await f.prompting; }
  });

  it("control characters are disclosed as escapes without swallowing the digest-bound diff", async () => {
    const instructions = "prefix\u009dnot-hidden\u009cafter\u007f\u0085\u2028\u2029";
    const f = await pendingApproval({}, [
      { key: "context.compaction.instructions", layer: "session", op: "set", value: instructions },
    ], true, "Reason\u009dnot-hidden\u007ftail");
    try {
      const context = f.interaction.form!.questions[0]!.context!;
      expect(context).toContain("\\u009dnot-hidden\\u007ftail");
      expect(context).toContain("\\u009dnot-hidden\\u009cafter\\u007f\\u0085\\u2028\\u2029");
      expect(context).toContain("context.compaction.instructions");
      expect(context).toContain("Approve applies only this diff. Deny changes nothing.");
      f.answer("deny");
      await f.prompting;
      await waitFor(() => !f.home.isBusy, "escaped diff denial settles");
      await saveCase("control-character-diff", { interaction: f.interaction });
    } finally { await f.home.abort("agent"); await f.prompting; }
  });

  it("bidi and zero-width format controls are visible escapes in the exact diff", async () => {
    const value = "visible\u061c\u200b\u200c\u200d\u200e\u200f\u202a\u202b\u202c\u202d\u202e\u2066\u2067\u2068\u2069\ufeffend";
    const f = await pendingApproval({}, [
      { key: "context.compaction.instructions", layer: "session", op: "set", value },
    ], true);
    try {
      const context = f.interaction.form!.questions[0]!.context!;
      expect(context).toContain("visible\\u061c\\u200b\\u200c\\u200d\\u200e\\u200f\\u202a\\u202b\\u202c\\u202d\\u202e\\u2066\\u2067\\u2068\\u2069\\ufeffend");
      f.answer("deny");
      await f.prompting;
      await waitFor(() => !f.home.isBusy, "format control diff denial settles");
      await saveCase("format-control-diff", { interaction: f.interaction });
    } finally { await f.home.abort("agent"); await f.prompting; }
  });

  it("astral tags and other default-ignorable characters cannot hide reason or value text", async () => {
    const value = "visible\u{e0041}\u2060\u00ad\u180e\u115f\u1160\u3164\ufff9\ufffa\ufffbend";
    const f = await pendingApproval({}, [
      { key: "context.compaction.instructions", layer: "session", op: "set", value },
    ], true, "Reason\u{e0041}\u2060tail");
    try {
      const context = f.interaction.form!.questions[0]!.context!;
      expect(context).toContain("Reason\\udb40\\udc41\\u2060tail");
      expect(context).toContain("visible\\udb40\\udc41\\u2060\\u00ad\\u180e\\u115f\\u1160\\u3164\\ufff9\\ufffa\\ufffbend");
      expect(context).toContain("Approve applies only this diff. Deny changes nothing.");
      f.answer("deny");
      await f.prompting;
      await waitFor(() => !f.home.isBusy, "astral escaped diff denial settles");
      await saveCase("astral-format-diff", { interaction: f.interaction });
    } finally { await f.home.abort("agent"); await f.prompting; }
  });

  it("a mixed valid/refused dry run fails the whole bundle just like its real request", async () => {
    const f = await fixture();
    await setHomeMemoryModels(f.registry, [{ provider: f.model.provider, id: f.model.id }]);
    const changes = [
      { key: "run.retry.maxRetries", layer: "session", op: "set", value: 3 },
      { key: "model.thinking[role=chat]", layer: "session", op: "set", value: "low" },
    ];
    f.faux.setResponses([
      fauxAssistantMessage([fauxToolCall("settings", { action: "request", dryRun: true, reason: "Mixed preview", changes }, { id: "mixed-dry" })], { stopReason: "toolUse" }),
      fauxAssistantMessage("Noted"),
      fauxAssistantMessage([fauxToolCall("settings", { action: "request", reason: "Mixed request", changes }, { id: "mixed-live" })], { stopReason: "toolUse" }),
      fauxAssistantMessage("Noted"),
    ]);
    const home = await f.registry.acquire(f.home.sessionId);
    try {
      await home.prompt("Preview mixed request");
      const dry = await waitFor(() => home.snapshot().transcript.find(item => item.kind === "message" && item.role === "toolResult" && item.toolCallId === "mixed-dry"), "mixed preview result");
      expect(dry).toMatchObject({ isError: false, details: { dryRun: true, status: "failed", tier: "quiet" } });
      await waitFor(() => !home.isBusy, "mixed preview settles");
      await home.prompt("Make mixed request");
      const real = await waitFor(() => home.snapshot().transcript.find(item => item.kind === "message" && item.role === "toolResult" && item.toolCallId === "mixed-live"), "mixed request refusal");
      expect(real).toMatchObject({ isError: true });
      expect(home.snapshot().extensionPresentation.pendingInteractions).toEqual([]);
      expect(await f.settings.settingsChanges.pendingApprovals()).toEqual([]);
      expect((await f.settings.settingsChanges.history({ key: "run.retry.maxRetries" })).entries).toEqual([]);
      await saveCase("mixed-dry-run", { dry, real });
    } finally { await home.abort("agent"); }
  });

  it("an oversized exact diff is refused explicitly without leaving an unreviewable pending request", async () => {
    const f = await fixture();
    await setHomeMemoryModels(f.registry, [{ provider: f.model.provider, id: f.model.id }]);
    const taskId = await settledWorker(f);
    f.faux.setResponses([
      fauxAssistantMessage([fauxToolCall("settings", { action: "request", taskId, reason: "Review capacity", changes: [
        { key: "sources.skills", layer: "global", op: "set", value: Array.from({ length: 250 }, (_, index) => "/review-only/skill-" + index + "-" + "x".repeat(180)) },
      ] }, { id: "oversized-request" })], { stopReason: "toolUse" }), fauxAssistantMessage("Noted"),
    ]);
    const home = await f.registry.acquire(f.home.sessionId);
    const prompting = home.prompt("Request a bounded exact diff");
    try {
      await waitFor(() => home.snapshot().extensionPresentation.pendingInteractions[0]
        || home.snapshot().transcript.find(item => item.kind === "message" && item.role === "toolResult" && item.toolCallId === "oversized-request"), "oversized diff refusal or form");
      const result = home.snapshot().transcript.find(item => item.kind === "message" && item.role === "toolResult" && item.toolCallId === "oversized-request");
      expect(result).toMatchObject({ isError: true, content: [expect.objectContaining({ text: expect.stringContaining("diff is too large to review") })] });
      expect(home.snapshot().extensionPresentation.pendingInteractions).toEqual([]);
      expect(await f.settings.settingsChanges.pendingApprovals()).toEqual([]);
      expect((await f.settings.settingsChanges.history({ key: "sources.skills" })).entries.some(entry => entry.status === "approved")).toBe(false);
      await saveCase("oversized-diff", { result });
    } finally { await home.abort("agent"); await prompting; }
  });

  it("a worker removed before decision admission retires the owned request instead of orphaning it", async () => {
    const f = await pendingApproval({}, [
      { key: "run.retry.maxRetries", layer: "session", op: "set", value: 3 },
    ], true);
    try {
      const workerSessionId = (await homeOwnerOf(f.registry).taskStatus("diff-worker")).sessionId!;
      await f.registry.delete(workerSessionId);
      f.answer("approve");
      await waitFor(() => !f.home.isBusy, "removed worker decision settles");
      const result = f.home.snapshot().transcript.find(item => item.kind === "message" && item.role === "toolResult" && item.toolCallId === "settings-request");
      expect(result).toMatchObject({ isError: true });
      expect(await f.settings.settingsChanges.pendingApprovals()).toEqual([]);
      const history = (await f.settings.settingsChanges.history({ key: "run.retry.maxRetries" })).entries;
      expect(history.some(entry => entry.status === "approved")).toBe(false);
      expect(history.some(entry => entry.status === "superseded")).toBe(true);
      expect(history.find(entry => entry.status === "superseded")?.failure).toContain("decision could not be admitted");
      await saveCase("removed-worker", { result, history });
    } finally { await f.home.abort("agent"); await f.prompting; }
  });

  it("Changes approves a live Home form through settings.decide once and retires the same interaction", async () => {
    const f = await pendingApproval();
    const service = new GatewayService({
      display: displayOwnerOf(f.registry),
      config: { machineId: "machine", machineGroupID: "group", machineName: "Mac", tronHome: f.tronHome, agentDir: f.agentDir },
      modelRuntime: f.gateway, trust: f.trust, settingsModel: f.settings.settingsModel, settingsChanges: f.settings.settingsChanges,
      sessions: f.registry, home: homeOwnerOf(f.registry), receipts: new CommandReceiptStore(f.tronHome),
      uploads: new UploadStore(f.tronHome, DEFAULT_MAX_UPLOAD_BYTES), notifications: { enqueue: async () => "queued" },
      broadcast: () => {}, globalProviderResources: { withStableSnapshot: async (operation: () => Promise<unknown>) => operation(), requestReload: () => {} },
    } as unknown as GatewayServiceDependencies);
    const phone = { id: "phone", identity: "device:phone", isLocal: false, isSubscribed: () => true,
      isRevoked: () => false, revokeDevice: () => {} } as unknown as ClientContext;
    const decision = { commandId: "live-form-changes-approval", requestId: f.request.requestId, digest: f.request.digest, approved: true };
    try {
      expect(f.home.isBusy).toBe(true);
      expect(f.interaction.form).toMatchObject({ presentation: "approval" });
      const approved = await service.invoke(phone, "settings.decide", decision);
      await f.prompting;
      await waitFor(() => !f.home.isBusy, "Changes decision releases the requesting turn");
      expect(approved).toMatchObject({ status: "approved" });
      expect(await service.invoke(phone, "settings.decide", decision)).toEqual(approved);
      const snapshot = f.home.snapshot();
      expect(snapshot.extensionPresentation.pendingInteractions).toEqual([]);
      expect(snapshot.transcript.find(item => item.kind === "message" && item.role === "toolResult" && item.toolCallId === "settings-request"))
        .toMatchObject({ isError: false, details: { status: "approved" } });
      const history = (await f.settings.settingsChanges.history({ key: "run.retry.maxRetries" })).entries;
      expect(history.filter(entry => entry.status === "approved")).toHaveLength(1);
      expect(history.find(entry => entry.status === "approved")).toMatchObject({ after: 3 });
      const resolution = await service.invoke(phone, "settings.resolve", { target: { kind: "home" }, keys: ["run.retry.maxRetries"] });
      expect(resolution).toMatchObject({ keys: [expect.objectContaining({ value: 3 })] });
      expect(() => f.answer("approve")).toThrow();
      await saveCase("changes-live-form", { approved, history, resolution });
    } finally { await f.home.abort("agent"); await f.prompting; }
  });

  it("an unanswered form stays pending without applying and its later answer applies the same diff", async () => {
    const f = await pendingApproval();
    try {
      // Local dismissal sends no answer. Authoritative rereads must retain the
      // request and continuation, with no approved write, until the later tap.
      const pending = await f.settings.settingsChanges.pendingApprovals();
      const before = (await f.settings.settingsChanges.history({ key: "run.retry.maxRetries" })).entries;
      expect(pending).toEqual([expect.objectContaining({ requestId: f.request.requestId, status: "pending" })]);
      expect(before.some(entry => entry.status === "approved" || entry.status === "declined")).toBe(false);
      expect(f.home.isBusy).toBe(true);
      expect(f.home.snapshot().extensionPresentation.pendingInteractions).toEqual([f.interaction]);
      f.answer("approve");
      await f.prompting;
      await waitFor(() => !f.home.isBusy, "later approval settles");
      const history = (await f.settings.settingsChanges.history({ key: "run.retry.maxRetries" })).entries;
      expect(history.filter(entry => entry.status === "approved")).toEqual([
        expect.objectContaining({ after: 3 }),
      ]);
      expect(f.home.snapshot().extensionPresentation.pendingInteractions).toEqual([]);
      await saveCase("unanswered-later-approve", { pending, before, history });
    } finally { await f.home.abort("agent"); await f.prompting; }
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
