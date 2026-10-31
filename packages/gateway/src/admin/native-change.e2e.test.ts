import { mkdir, readFile, readdir, stat, writeFile } from "node:fs/promises";
import { spawn, execFile } from "node:child_process";
import { readFileSync } from "node:fs";
import { once } from "node:events";
import { fileURLToPath, pathToFileURL } from "node:url";
import { promisify } from "node:util";
import { join } from "node:path";
import { fauxAssistantMessage, fauxToolCall, type TranscriptContext } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it, vi } from "vitest";
import { fixture, disposeFixtures, reportCall } from "../../test-support/home-task-fixture.js";
import { waitFor } from "../../test-support/wait-for.js";
import { setHomeMemoryModels } from "../../test-support/settings-dependencies.js";
import type { ExtensionInteraction } from "../protocol/types.js";
import type { ChangeRequest, Resolution } from "../kernel/settings/tool-contract.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "../transport/gateway-service.js";
import { CommandReceiptStore } from "../transport/command-receipts.js";
import { UploadStore } from "../machine/upload-store.js";
import { DEFAULT_MAX_UPLOAD_BYTES } from "../config.js";
import { displayOwnerOf, homeOwnerOf } from "../../test-support/gateway-registry.js";
import { CHANGE_REVIEW_TTL_MS, SemanticUIBroker } from "../kernel/host/semantic-ui-broker.js";
import { ExtensionPresentationStore } from "../kernel/host/presentation/extension-presentation-store.js";
import { changeReview } from "../kernel/settings/settings-types.js";
import { SettingsChangeRecord } from "../kernel/settings/settings-record.js";
import { SettingsChangePath } from "../kernel/settings/settings-change.js";

afterEach(disposeFixtures);
const phone = { id: "phone", identity: "device:phone", isLocal: false, isSubscribed: () => true,
  isRevoked: () => false, revokeDevice: () => {} } as unknown as ClientContext;
let sequence = 0;
function settingsService(f: Awaited<ReturnType<typeof fixture>>, broadcast: (topic: string, payload: unknown) => void = () => {}) {
  return new GatewayService({ display: displayOwnerOf(f.registry),
    config: { machineId: "machine", machineGroupID: "group", machineName: "Mac", tronHome: f.tronHome, agentDir: f.agentDir },
    modelRuntime: f.gateway, trust: f.trust, settingsModel: f.settings.settingsModel, settingsChanges: f.settings.settingsChanges,
    sessions: f.registry, home: homeOwnerOf(f.registry), receipts: new CommandReceiptStore(f.tronHome),
    uploads: new UploadStore(f.tronHome, DEFAULT_MAX_UPLOAD_BYTES), notifications: { enqueue: async () => "queued" },
    broadcast, globalProviderResources: { withStableSnapshot: async (operation: () => Promise<unknown>) => operation(), requestReload: () => {} },
  } as unknown as GatewayServiceDependencies);
}
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
async function nativeChange(changes: ChangeRequest[] = [{ key: "tools.shell.path", layer: "global", op: "set", value: "/bin/zsh" }], worker = true, reason = "Choose the exact shell") {
  const f = await fixture();
  await setHomeMemoryModels(f.registry, [{ provider: f.model.provider, id: f.model.id }]);
  const taskId = worker ? await settledWorker(f) : undefined;
  f.faux.setResponses([
    fauxAssistantMessage([fauxToolCall("settings", { action: "change", reason, changes, ...(taskId ? { taskId } : {}) }, { id: "native-change" })], { stopReason: "toolUse" }),
    fauxAssistantMessage("Finished"),
  ]);
  const home = await f.registry.acquire(f.home.sessionId);
  const prompting = home.prompt("Change the setting").then(() => waitFor(() => !home.isBusy, "native tool turn settled"));
  const interaction = await waitFor(() => home.snapshot().extensionPresentation.pendingInteractions[0], "native change card").catch(async error => {
    await saveCase("missing-card", { snapshot: home.snapshot(), events: f.events });
    await home.abort("agent"); await prompting; throw error;
  });
  expect(interaction.method).toBe("change");
  if (interaction.method !== "change") throw new Error("A generic form is not a native change card");
  const service = settingsService(f);
  const answer = (approved: boolean, current: ExtensionInteraction = interaction, value: unknown = { digest: interaction.review.digest, approved }, client = phone) => service.invoke(client, "extension.respond", {
    commandId: `native-response-${++sequence}`, sessionId: home.id, interactionId: current.id,
    hostEpoch: current.hostEpoch, presentationRevision: current.presentationRevision, value,
  });
  return { ...f, home, prompting, interaction, answer, service };
}
async function saveCase(name: string, evidence: unknown) {
  const directory = join(process.cwd(), "test-results/native-change");
  await mkdir(directory, { recursive: true });
  await writeFile(join(directory, `${name}.json`), `${JSON.stringify(evidence, null, 2)}\n`);
}

describe("typed changes and exact native acceptance", () => {
  it("configures numeric maps through the agent and keeps a task-budget raise behind the shared card", async () => {
    const f = await fixture();
    await setHomeMemoryModels(f.registry, [f.model]);
    const home = await f.registry.acquire(f.home.sessionId);
    const service = settingsService(f);
    f.faux.setResponses([
      fauxAssistantMessage([fauxToolCall("settings", { action: "change", reason: "Choose numeric budgets", changes: [
        { key: "model.thinkingBudgets", layer: "global", op: "set", value: { high: 2048 } },
        { key: "permissions.budget.task", layer: "session", op: "set", value: { outputTokens: 100 } },
      ] }, { id: "numeric-maps" })], { stopReason: "toolUse" }), fauxAssistantMessage("Configured"),
    ]);
    await home.prompt("Configure the numeric maps");
    await waitFor(() => !home.isBusy, "numeric map changes settled");
    expect(home.snapshot().extensionPresentation.pendingInteractions).toHaveLength(0);
    expect(home.canonicalSessionEntries().find(entry => entry.type === "message" && entry.message.role === "toolResult" && entry.message.toolCallId === "numeric-maps"))
      .toMatchObject({ type: "message", message: { role: "toolResult", isError: false } });
    const next = await f.registry.create(f.cwd);
    expect(next.runtime.session.settingsManager.getThinkingBudgets()).toEqual({ high: 2048 });
    const readBudget = () => service.invoke(phone, "settings.resolve", { target: { kind: "home" }, keys: ["permissions.budget.task"] }) as Promise<Resolution>;
    expect((await readBudget()).keys[0]!.value).toEqual({ outputTokens: 100 });
    for (const value of [{ outputTokens: 0 }, { outputTokens: 0.5 }, { outputTokens: 10_000_000_001 }, { unoffered: 3 }]) {
      const id = `invalid-map-${++sequence}`;
      f.faux.setResponses([
        fauxAssistantMessage([fauxToolCall("settings", { action: "change", reason: "Invalid map probe", changes: [
          { key: "permissions.budget.task", layer: "session", op: "set", value },
        ] }, { id })], { stopReason: "toolUse" }), fauxAssistantMessage("Refused"),
      ]);
      await home.prompt("Try the invalid numeric map");
      await waitFor(() => !home.isBusy, "invalid numeric map refused");
      expect(home.canonicalSessionEntries().find(entry => entry.type === "message" && entry.message.role === "toolResult" && entry.message.toolCallId === id))
        .toMatchObject({ type: "message", message: { role: "toolResult", isError: true } });
      expect((await readBudget()).keys[0]!.value).toEqual({ outputTokens: 100 });
      expect(home.snapshot().extensionPresentation.pendingInteractions).toHaveLength(0);
    }
    f.faux.setResponses([
      fauxAssistantMessage([fauxToolCall("settings", { action: "change", reason: "Allow a larger task", changes: [
        { key: "permissions.budget.task", layer: "session", op: "set", value: { outputTokens: 200 } },
      ] }, { id: "numeric-map-raise" })], { stopReason: "toolUse" }), fauxAssistantMessage("Raised"),
    ]);
    const raising = home.prompt("Raise the task budget");
    const interaction = await waitFor(() => home.snapshot().extensionPresentation.pendingInteractions[0], "task-budget native card");
    if (interaction.method !== "change") throw new Error("Expected the shared change card");
    expect(interaction.review).toMatchObject({ requiresTap: true, items: [{ label: "Task budget", before: "output 100", after: "output 200" }] });
    expect(JSON.parse(interaction.review.items[0]!.exact!)).toMatchObject({ target: { kind: "home" }, key: "permissions.budget.task", before: { outputTokens: 100 }, after: { outputTokens: 200 } });
    expect((await readBudget()).keys[0]!.value).toEqual({ outputTokens: 100 });
    await service.invoke(phone, "extension.respond", { commandId: `numeric-response-${++sequence}`, sessionId: home.id,
      interactionId: interaction.id, hostEpoch: interaction.hostEpoch, presentationRevision: interaction.presentationRevision,
      value: { digest: interaction.review.digest, approved: true } });
    await raising;
    await waitFor(() => !home.isBusy, "approved budget raise settled");
    expect((await readBudget()).keys[0]!.value).toEqual({ outputTokens: 200 });
    const history = await f.settings.settingsChanges.history({ key: "model.thinkingBudgets" });
    const applied = history.entries.find(entry => entry.status === "applied")!;
    expect(applied).toBeDefined();
    await service.invoke(phone, "settings.undo", { commandId: `numeric-undo-${++sequence}`, changeId: applied.changeId });
    const afterUndo = await f.registry.create(f.cwd);
    expect(afterUndo.runtime.session.settingsManager.getThinkingBudgets()).toBeUndefined();
    await saveCase("numeric-maps", { interaction, history, budget: (await readBudget()).keys[0]!.value });
  });

  it("refuses a small input when the full Home catalog leaves no native response headroom", async () => {
    const f = await fixture(false, false, 8000);
    await setHomeMemoryModels(f.registry, [f.model]);
    const home = await f.registry.acquire(f.home.sessionId), calls = f.faux.state.callCount;
    await home.prompt("A small input still carries the declared Home tools").catch(() => {});
    await waitFor(() => !home.isBusy && !home.hasActiveAgentRun || undefined, "catalog-only overflow releases native ownership");
    const observed = { refused: f.signals.some(signal => signal.event === "refused" && signal.reason === "context-overflow"),
      providerCalls: f.faux.state.callCount - calls };
    expect(observed).toEqual({ refused: true, providerCalls: 0 });
    await saveCase("catalog-only-overflow", observed);
  });

  it("keeps canonical key identity refusal across real Home resolve, change, dry run and contradictory qualifiers", async () => {
    const f = await fixture();
    await setHomeMemoryModels(f.registry, [f.model]);
    const home = await f.registry.acquire(f.home.sessionId);
    const turn = async (args: Record<string, unknown>, id: string) => {
      f.faux.setResponses([fauxAssistantMessage([fauxToolCall("settings", args, { id })], { stopReason: "toolUse" }), fauxAssistantMessage("Done")]);
      await home.prompt(id);
      await waitFor(() => !home.isBusy && home.snapshot().configurationBlocker === null || undefined, "key identity tool turn settled");
      const result = home.canonicalSessionEntries().find(entry => entry.type === "message" && entry.message.role === "toolResult" && entry.message.toolCallId === id);
      if (result?.type !== "message" || result.message.role !== "toolResult") throw new Error("No canonical settings tool result");
      return { isError: result.message.isError, text: result.message.content.map(part => part.type === "text" ? part.text : "").join("") };
    };
    expect(await turn({ action: "resolve", keys: ["model.thinking"] }, "key-read")).toMatchObject({
      isError: true, text: expect.stringContaining("use model.thinking[role=chat]") });
    for (const dryRun of [true, false]) {
      const changed = await turn({ action: "change", reason: "Cheaper", dryRun,
        changes: [{ key: "model.thinking", layer: "session", op: "set", value: "low", qualifiers: { role: "chat" } }] }, `key-write-${dryRun}`);
      expect(changed.text).toContain("use model.thinking[role=chat]");
    }
    const contradicted = await turn({ action: "change", reason: "Cheaper", dryRun: true,
      changes: [{ key: "model.thinking[role=chat]", layer: "session", op: "set", value: "low", qualifiers: { role: "worker" } }] }, "key-qualifier");
    expect(contradicted.text).toContain("role=worker is a different setting");
    await saveCase("canonical-key-identity", contradicted);
  });

  it.each(["pending", "effects", "completion"] as const)("recovers the actual native response receipt after a fixture kill at %s without replaying effects", async cut => {
    const f = await fixture(), root = join(f.root, `native-crash-${cut}`);
    await mkdir(root);
    const args = ["--experimental-transform-types", "--import",
      pathToFileURL(fileURLToPath(new URL("../../test-support/home-ledger-crash-preload.mjs", import.meta.url))).href,
      fileURLToPath(new URL("../../test-support/native-change-crash-child.ts", import.meta.url)), root, cut];
    const child = spawn(process.execPath, [...args, "kill"], { stdio: ["pipe", "pipe", "pipe"], env: { ...process.env, PI_OFFLINE: "1" } });
    let output = "";
    child.stdout.on("data", bytes => { output += bytes; }); child.stderr.on("data", bytes => { output += bytes; });
    const exited = once(child, "exit");
    try {
      await waitFor(async () => {
        try { return await readFile(join(root, "cut"), "utf8"); }
        catch { if (child.exitCode !== null || child.signalCode !== null) throw new Error(`Native crash fixture exited: ${output}`); return undefined; }
      }, `native response durable ${cut} cut`, { boundMs: 15_000 });
      child.kill("SIGKILL");
      expect((await exited)[1]).toBe("SIGKILL");
      // The kill may land inside the SDK's synchronous trust/settings lock while
      // the accepted run continues. A restart honors proper-lockfile's own 10 s
      // stale window; the fixture neither erases nor shortens that owner's lock.
      const agentDir = join(root, "agent");
      for (const name of (await readdir(agentDir)).filter(entry => entry.endsWith(".lock"))) {
        const age = Date.now() - (await stat(join(agentDir, name))).mtimeMs;
        if (age < 10_500) await new Promise(resolve => setTimeout(resolve, 10_500 - age));
      }
      await promisify(execFile)(process.execPath, [...args, "recover"], { env: { ...process.env, PI_OFFLINE: "1" }, timeout: 20_000 });
      const recovered = JSON.parse(await readFile(join(root, "recovered.json"), "utf8"));
      if (cut === "completion") expect(recovered.replay).toEqual({ result: { answered: true } });
      else expect(recovered.replay).toMatchObject({ error: { code: "conflict", details: { outcomeUnknown: true } } });
      expect(recovered.blockImages).toBe(cut === "pending");
      expect(recovered.history).toHaveLength(cut === "pending" ? 0 : 1);
      if (cut !== "pending") expect(recovered.history[0]).toMatchObject({ status: "applied", commandId: "native-crash-response",
        actor: { kind: "ui", id: "device:native-crash" }, before: true, after: false });
      await saveCase(`receipt-crash-${cut}`, recovered);
    } finally {
      if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
      await exited;
    }
  }, 30_000);

  it("an internal Home tool recipe change is applied and logged, never reported from an unapplied result", async () => {
    const f = await fixture(), home = await f.registry.acquire(f.home.sessionId);
    await home.setTools(["settings"]);
    expect((await f.settings.settingsModel.resolve({ kind: "home" }, undefined, ["tools.active"])).keys[0]!.value).toEqual(["settings"]);
    expect((await f.settings.settingsChanges.history({ key: "tools.active" })).entries).toMatchObject([{ status: "applied", after: ["settings"] }]);
  });

  it("keeps the canonical receipt pending after a real observer I/O failure, without reapplying the same command", async () => {
    const f = await fixture();
    let notifications = 0;
    const service = settingsService(f, topic => {
      if (topic === "settings.changed") { notifications++; readFileSync(join(f.root, "missing-observer-target")); }
    });
    const params = { commandId: `observer-io-${++sequence}`, target: { kind: "global" },
      changes: [{ key: "run.retry.maxRetries", layer: "global", op: "set", value: 9 }] };
    const first = await service.invoke(phone, "settings.change", params).then(() => undefined, error => error);
    await expect(service.invoke(phone, "settings.change", params)).rejects.toMatchObject({ code: "conflict", details: { outcomeUnknown: true } });
    expect(notifications).toBe(1);
    expect((await f.settings.settingsChanges.history({ key: "run.retry.maxRetries" })).entries).toHaveLength(1);
    expect(JSON.parse(await readFile(join(f.agentDir, "settings.json"), "utf8")).retry.maxRetries).toBe(9);
    expect(first).toMatchObject({ code: "conflict", details: { outcomeUnknown: true } });
    await saveCase("observer-io-uncertainty", { code: first.code, details: first.details, notifications });
  });

  it("allows exactly one of sixteen concurrent Undo commands and permanently consumes the original inverse", async () => {
    const f = await fixture(), service = settingsService(f);
    const original = await service.invoke(phone, "settings.change", { commandId: `undo-original-${++sequence}`, target: { kind: "global" },
      changes: [{ key: "run.retry.maxRetries", layer: "global", op: "set", value: 3 }] }) as unknown as { changes: Array<{ changeId: string }> };
    const changeId = original.changes[0]!.changeId;
    const race = await Promise.allSettled(Array.from({ length: 16 }, (_, index) => service.invoke(phone, "settings.undo",
      { commandId: `undo-race-${sequence}-${index}`, changeId })));
    const winners = race.filter(result => result.status === "fulfilled");
    expect(winners).toHaveLength(1);
    expect(winners[0]).toMatchObject({ value: { status: "applied" } });
    expect(race.filter(result => result.status === "rejected")).toHaveLength(15);
    expect(race.filter(result => result.status === "rejected").every(result => result.reason.code === "conflict")).toBe(true);
    const history = (await f.settings.settingsChanges.history({ key: "run.retry.maxRetries" })).entries;
    expect(history.filter(entry => entry.undoOf === changeId)).toHaveLength(1);
    expect(JSON.parse(await readFile(join(f.agentDir, "settings.json"), "utf8")).retry?.maxRetries).toBeUndefined();
    await service.invoke(phone, "settings.change", { commandId: `undo-restored-after-${++sequence}`, target: { kind: "global" },
      changes: [{ key: "run.retry.maxRetries", layer: "global", op: "set", value: 3 }] });
    await expect(service.invoke(phone, "settings.undo", { commandId: `undo-consumed-${sequence}`, changeId })).rejects.toMatchObject({ code: "conflict" });
    expect(JSON.parse(await readFile(join(f.agentDir, "settings.json"), "utf8")).retry.maxRetries).toBe(3);
    expect((await f.settings.settingsChanges.history({ key: "run.retry.maxRetries" })).entries.filter(entry => entry.undoOf === changeId)).toHaveLength(1);
    await saveCase("undo-sixteen-way", { race, history });
  });

  it("applies a reversible routine edit in its original real tool turn without any approval reader or form", async () => {
    const f = await fixture();
    await setHomeMemoryModels(f.registry, [{ provider: f.model.provider, id: f.model.id }]);
    f.faux.setResponses([fauxAssistantMessage([fauxToolCall("settings", { action: "change", reason: "Retry transient failures", changes: [
      { key: "run.retry.maxRetries", layer: "session", op: "set", value: 3 },
    ] })], { stopReason: "toolUse" }), fauxAssistantMessage("Finished")]);
    const home = await f.registry.acquire(f.home.sessionId);
    await home.prompt("Change retries");
    expect(home.snapshot().extensionPresentation.pendingInteractions).toEqual([]);
    expect(await waitFor(() => home.snapshot().transcript.find(item => item.kind === "message" && item.role === "toolResult"), "routine tool result"))
      .toMatchObject({ isError: false, details: { status: "applied", review: { requiresTap: false }, changes: [expect.objectContaining({ before: null, after: 3 })] } });
    const service = settingsService(f);
    await expect(service.invoke(phone, "settings.approvals", {})).rejects.toMatchObject({ code: "not_found" });
    await expect(service.invoke(phone, "settings.decide", { commandId: "retired-decision" })).rejects.toMatchObject({ code: "not_found" });
    expect((await f.settings.settingsChanges.history({ key: "run.retry.maxRetries" })).entries).toHaveLength(1);
  });

  it("publishes the exact built-in card, refuses local/generic/stale answers without consuming it, then applies once under the response receipt", async () => {
    const f = await nativeChange();
    try {
      expect(f.interaction.review).toMatchObject({ requiresTap: true, title: "Shell", reason: "Choose the exact shell" });
      expect(f.interaction.review.items[0]).toMatchObject({ label: "Shell", after: "/bin/zsh", detail: expect.stringContaining("Global stored value") });
      await expect(f.answer(true, f.interaction, { digest: f.interaction.review.digest, approved: true }, { ...phone, isLocal: true })).rejects.toMatchObject({ code: "invalid_request" });
      await expect(f.answer(true, f.interaction, { version: 1, answers: [] })).rejects.toMatchObject({ code: "invalid_request" });
      await expect(f.answer(true, f.interaction, { digest: "0".repeat(64), approved: true })).rejects.toMatchObject({ code: "invalid_request" });
      await expect(f.answer(true, { ...f.interaction, hostEpoch: "retired" })).rejects.toMatchObject({ code: "conflict" });
      await expect(f.answer(true, { ...f.interaction, presentationRevision: f.interaction.presentationRevision + 1 })).rejects.toMatchObject({ code: "conflict" });
      expect(f.home.snapshot().extensionPresentation.pendingInteractions).toHaveLength(1);
      expect((await f.settings.settingsChanges.history({ key: "tools.shell.path" })).entries).toEqual([]);
      const answers = await Promise.allSettled([f.answer(true), f.answer(true)]);
      expect(answers.filter(answer => answer.status === "fulfilled")).toEqual([{ status: "fulfilled", value: { answered: true } }]);
      expect(answers.filter(answer => answer.status === "rejected")).toEqual([{ status: "rejected", reason: expect.objectContaining({ code: "not_found" }) }]);
      await f.prompting;
      expect(JSON.parse(await readFile(join(f.agentDir, "settings.json"), "utf8")).shellPath).toBe("/bin/zsh");
      const history = (await f.settings.settingsChanges.history({ key: "tools.shell.path" })).entries;
      expect(history).toHaveLength(1);
      expect(history[0]).toMatchObject({ actor: { kind: "ui", id: "device:phone" }, status: "applied", after: "/bin/zsh", commandId: expect.stringMatching(/^native-response-/) });
      await expect(f.service.invoke(phone, "extension.respond", { commandId: history[0]!.commandId, sessionId: f.home.id,
        interactionId: f.interaction.id, hostEpoch: f.interaction.hostEpoch, presentationRevision: f.interaction.presentationRevision,
        value: { digest: f.interaction.review.digest, approved: true } })).resolves.toEqual({ answered: true });
      expect((await f.settings.settingsChanges.history({ key: "tools.shell.path" })).entries).toHaveLength(1);
      expect(f.home.snapshot().transcript.find(item => item.kind === "message" && item.role === "toolResult" && item.toolCallId === "native-change"))
        .toMatchObject({ isError: false, details: { status: "applied" } });
      // The tapped change is logged once and the maintainer can undo it.
      await expect(f.service.invoke(phone, "settings.undo", { commandId: `undo-tapped-${++sequence}`, changeId: history[0]!.changeId }))
        .resolves.toMatchObject({ status: "applied" });
      expect(JSON.parse(await readFile(join(f.agentDir, "settings.json"), "utf8")).shellPath).toBeUndefined();
      expect((await f.settings.settingsChanges.history({ key: "tools.shell.path" })).entries.filter(entry => entry.undoOf === history[0]!.changeId)).toHaveLength(1);
      await saveCase("accepted", { interaction: f.interaction, history });
    } finally { await f.home.abort("agent"); await f.prompting; }
  });

  it.each([false, true])("decline or Stop before acceptance has no effect (Stop=%s)", async stop => {
    const f = await nativeChange();
    try {
      if (stop) await f.home.abort("agent"); else await f.answer(false);
      await f.prompting;
      expect(f.home.snapshot().extensionPresentation.pendingInteractions).toEqual([]);
      expect(JSON.parse(await readFile(join(f.agentDir, "settings.json"), "utf8")).shellPath).toBeUndefined();
      expect((await f.settings.settingsChanges.history({ key: "tools.shell.path" })).entries).toEqual([]);
      await expect(f.answer(true)).rejects.toMatchObject({ code: "not_found" });
    } finally { await f.home.abort("agent"); await f.prompting; }
  });

  it("replans the actual store after the human wait and refuses a stale exact review", async () => {
    const f = await nativeChange();
    try {
      // The maintainer's own paired tap applies directly while the card waits.
      await expect(f.service.invoke(phone, "settings.change", { commandId: "other-shell-accepted", target: { kind: "global" }, changes: [{ key: "tools.shell.path", layer: "global", op: "set", value: "/bin/bash" }] }))
        .resolves.toMatchObject({ status: "applied", review: { requiresTap: true } });
      await expect(f.answer(true)).rejects.toMatchObject({ code: "conflict", message: expect.stringContaining("stale") });
      await f.prompting;
      expect(JSON.parse(await readFile(join(f.agentDir, "settings.json"), "utf8")).shellPath).toBe("/bin/bash");
      expect((await f.settings.settingsChanges.history({ key: "tools.shell.path" })).entries).toHaveLength(1);
    } finally { await f.home.abort("agent"); await f.prompting; }
  });

  it("refuses a worker removed after native review instead of applying through a retired source", async () => {
    const f = await nativeChange();
    try {
      const workerID = (await homeOwnerOf(f.registry).taskStatus("diff-worker")).sessionId!;
      await f.registry.delete(workerID);
      await expect(f.answer(true)).rejects.toBeDefined();
      await f.prompting;
      expect((await f.settings.settingsChanges.history({ key: "tools.shell.path" })).entries).toEqual([]);
      expect(JSON.parse(await readFile(join(f.agentDir, "settings.json"), "utf8")).shellPath).toBeUndefined();
    } finally { await f.home.abort("agent"); await f.prompting; }
  });

  it.each([false, true])("refuses an own-session SDK edit before a card or write (dryRun=%s)", async dryRun => {
    const f = await fixture();
    await setHomeMemoryModels(f.registry, [{ provider: f.model.provider, id: f.model.id }]);
    const home = await f.registry.acquire(f.home.sessionId), before = home.snapshot().thinkingLevel;
    f.faux.setResponses([fauxAssistantMessage([fauxToolCall("settings", { action: "change", dryRun, reason: "Less thinking", changes: [
      { key: "model.thinking[role=chat]", layer: "session", op: "set", value: "low" },
    ] })], { stopReason: "toolUse" }), fauxAssistantMessage("Noted")]);
    await home.prompt("Change own thinking");
    const result = await waitFor(() => home.snapshot().transcript.find(item => item.kind === "message" && item.role === "toolResult"), "own SDK refusal");
    if (dryRun) expect(result).toMatchObject({ isError: false, details: { dryRun: true, status: "failed", changes: [expect.objectContaining({ status: "failed", error: { code: "busy", message: expect.stringContaining("between runs") } })] } });
    else expect(result).toMatchObject({ isError: true, content: [expect.objectContaining({ text: expect.stringContaining("between runs") })] });
    expect(home.snapshot().extensionPresentation.pendingInteractions).toEqual([]);
    expect((await f.settings.settingsChanges.history({ key: "model.thinking" })).entries).toEqual([]);
    expect(home.snapshot().thinkingLevel).toBe(before);
  });

  it("a mixed valid/refused dry run fails the whole bundle just like its live call", async () => {
    const f = await fixture();
    await setHomeMemoryModels(f.registry, [{ provider: f.model.provider, id: f.model.id }]);
    const changes = [{ key: "run.retry.maxRetries", layer: "session", op: "set", value: 3 }, { key: "model.thinking[role=chat]", layer: "session", op: "set", value: "low" }];
    f.faux.setResponses([fauxAssistantMessage([fauxToolCall("settings", { action: "change", dryRun: true, reason: "Mixed preview", changes }, { id: "mixed-dry" })], { stopReason: "toolUse" }), fauxAssistantMessage("Noted"),
      fauxAssistantMessage([fauxToolCall("settings", { action: "change", reason: "Mixed live", changes }, { id: "mixed-live" })], { stopReason: "toolUse" }), fauxAssistantMessage("Noted")]);
    const home = await f.registry.acquire(f.home.sessionId);
    await home.prompt("Preview mixed request");
    expect(await waitFor(() => home.snapshot().transcript.find(item => item.kind === "message" && item.role === "toolResult" && item.toolCallId === "mixed-dry"), "mixed preview result"))
      .toMatchObject({ isError: false, details: { dryRun: true, status: "failed" } });
    await waitFor(() => !home.isBusy, "mixed preview settled");
    await home.prompt("Make mixed request");
    expect(await waitFor(() => home.snapshot().transcript.find(item => item.kind === "message" && item.role === "toolResult" && item.toolCallId === "mixed-live"), "mixed live result"))
      .toMatchObject({ isError: true });
    expect(home.snapshot().extensionPresentation.pendingInteractions).toEqual([]);
    expect((await f.settings.settingsChanges.history({ key: "run.retry.maxRetries" })).entries).toEqual([]);
  });

  it("the shared card retains complete long text, raw tool selections and exact target scope", async () => {
    const instructions = "Keep every detail " + "x".repeat(120) + " [label](https://example.test/full-target) ![image](https://example.test/raw.png)";
    const tools = ["read", "write", "edit", "bash", "settings"];
    const f = await nativeChange([{ key: "context.compaction.instructions", layer: "session", op: "set", value: instructions }, { key: "tools.active", layer: "session", op: "set", value: tools },
      { key: "context.images.block", layer: "session", op: "set", value: false }], true);
    try {
      const exact = f.interaction.review.items.map(item => JSON.parse(item.exact!));
      expect(exact.find(item => item.key === "context.compaction.instructions").after).toBe(instructions);
      expect(exact.find(item => item.key === "tools.active").after).toEqual(tools);
      expect(exact.every(item => item.target.kind === "session" && item.target.sessionId)).toBe(true);
      await f.answer(false); await f.prompting;
      await saveCase("complete-diff", { interaction: f.interaction });
    } finally { await f.home.abort("agent"); await f.prompting; }
  });

  it.each([
    ["prefix\u009dnot-hidden\u009cafter\u007f\u0085\u2028\u2029", "\\u009dnot-hidden\\u009cafter\\u007f\\u0085\\u2028\\u2029", "Reason\u009dnot-hidden\u007ftail", "\\u009dnot-hidden\\u007ftail"],
    ["visible\u061c\u200b\u200c\u200d\u200e\u200f\u202a\u202b\u202c\u202d\u202e\u2066\u2067\u2068\u2069\ufeffend", "visible\\u061c\\u200b\\u200c\\u200d\\u200e\\u200f\\u202a\\u202b\\u202c\\u202d\\u202e\\u2066\\u2067\\u2068\\u2069\\ufeffend", "Visible reason", "Visible reason"],
    ["visible\u{e0041}\u2060\u00ad\u180e\u115f\u1160\u3164\ufff9\ufffa\ufffbend", "visible\\udb40\\udc41\\u2060\\u00ad\\u180e\\u115f\\u1160\\u3164\\ufff9\\ufffa\\ufffbend", "Reason\u{e0041}\u2060tail", "Reason\\udb40\\udc41\\u2060tail"],
  ])("discloses controls, bidi and astral tags without hiding exact value or reason (%s)", async (value, expected, reason, expectedReason) => {
    const f = await nativeChange([{ key: "context.compaction.instructions", layer: "session", op: "set", value }, { key: "context.images.block", layer: "session", op: "set", value: false }], true, reason);
    try {
      expect(f.interaction.review.reason).toContain(expectedReason);
      expect(f.interaction.review.items[0]!.after).toContain(expected);
      expect(JSON.parse(f.interaction.review.items[0]!.exact!).key).toBe("context.compaction.instructions");
      await f.answer(false); await f.prompting;
    } finally { await f.home.abort("agent"); await f.prompting; }
  });

  it("the real kernel retains accepted callback/response ownership through abort and retirement, without early acknowledgement", async () => {
    const f = await fixture();
    const store = new ExtensionPresentationStore(() => {}), broker = new SemanticUIBroker(store), controller = new AbortController();
    let release!: () => void, requestSettled = false, acknowledged = false;
    const gate = new Promise<void>(resolve => { release = resolve; });
    const effect = join(f.root, "native-effect.json");
    const review = changeReview("kernel-effect", { title: "Exact file effect", requiresTap: true, items: [{ label: "File", before: "Absent", after: "Accepted command" }] });
    const requested = broker.requestChange({ review, signal: controller.signal, apply: async accepted => {
      await writeFile(effect, JSON.stringify(accepted)); await gate; return accepted.commandId;
    } }).then(value => { requestSettled = true; return value; });
    const interaction = broker.interactions()[0]!;
    const response = Promise.resolve(broker.respond(interaction.id, interaction.hostEpoch, interaction.presentationRevision, { digest: review.digest, approved: true }, false, { deviceId: phone.identity, commandId: "held-effect-command" }))
      .then(() => { acknowledged = true; });
    try {
      await waitFor(async () => readFile(effect, "utf8").catch(() => undefined), "actual accepted effect");
      controller.abort(); broker.retire();
      expect(requestSettled).toBe(false); expect(acknowledged).toBe(false);
      expect(JSON.parse(await readFile(effect, "utf8"))).toEqual({ deviceId: phone.identity, commandId: "held-effect-command" });
      release(); await expect(requested).resolves.toBe("held-effect-command"); await response;
      expect(acknowledged).toBe(true);
    } finally { release(); await Promise.allSettled([requested, response]); broker.retire(); }
  });

  it("refuses a truncated indexed closed group instead of restoring only its surviving members", async () => {
    const f = await fixture(), record = f.settings.settingsChanges.record;
    const seed = { at: new Date().toISOString(), actor: { kind: "ui" as const, id: phone.identity }, target: { kind: "home" as const }, layer: "session" as const,
      key: "home.profile.item", op: "set" as const, before: "before", after: "after", status: "applied" as const };
    await record.append(Array.from({ length: 499 }, (_, index) => ({ ...seed, changeId: `seed-${index}` })));
    await record.append(["member-a", "member-b"].map(changeId => ({ ...seed, changeId, group: { id: "complete-group", size: 2 } })));
    await record.append([{ ...seed, changeId: "tail" }]);
    expect((await record.group("complete-group", 2)).map(entry => entry.changeId)).toEqual(["member-a", "member-b"]);
    const path = join(record.path, "000000.jsonl"), original = await readFile(path, "utf8");
    await writeFile(path, original.split("\n").slice(0, 499).join("\n") + "\n");
    await expect(record.recover()).rejects.toMatchObject({ code: "conflict" });
    await expect(record.group("complete-group", 2)).rejects.toMatchObject({ code: "conflict" });
    await saveCase("truncated-group", { indexedRows: 500, actualRows: 499, missing: "member-a" });
  });

  it("reads pre-retirement audit rows, including approval facts, as immutable history without an Undo", async () => {
    const f = await fixture(), directory = join(f.root, "stable-home", "gateway", "settings", "changes");
    // Exact rows a Stable Gateway wrote before typed writes: a pending approval and its decline.
    const rows = [
      "{\"changeId\":\"00000005-0000-4000-8000-000000000000\",\"at\":\"2026-01-01T00:00:00.000Z\",\"actor\":{\"kind\":\"agent\",\"id\":\"01a00000-0000-7000-8000-00000000c0a1\",\"sessionId\":\"01a00000-0000-7000-8000-00000000c0a1\"},\"target\":{\"kind\":\"global\"},\"layer\":\"global\",\"key\":\"run.retry.maxRetries\",\"op\":\"set\",\"before\":6,\"after\":2,\"reason\":\"Corpus: an agent asks to retry less\",\"tier\":\"approve\",\"tierBasis\":{\"direction\":\"widen\",\"floor\":\"approve\",\"floorSource\":\"override\",\"web\":false,\"risk\":null},\"status\":\"pending\",\"requestId\":\"00000006-0000-4000-8000-000000000000\"}",
      "{\"changeId\":\"00000007-0000-4000-8000-000000000000\",\"at\":\"2026-01-01T00:00:00.000Z\",\"actor\":{\"kind\":\"agent\",\"id\":\"01a00000-0000-7000-8000-00000000c0a1\",\"sessionId\":\"01a00000-0000-7000-8000-00000000c0a1\"},\"target\":{\"kind\":\"global\"},\"layer\":\"global\",\"key\":\"context.images.block\",\"op\":\"set\",\"before\":true,\"after\":false,\"reason\":\"Corpus: an agent asks to allow images\",\"tier\":\"approve\",\"tierBasis\":{\"direction\":\"widen\",\"floor\":\"approve\",\"floorSource\":\"code\",\"web\":false,\"risk\":null},\"status\":\"pending\",\"requestId\":\"00000008-0000-4000-8000-000000000000\"}",
      "{\"changeId\":\"00000009-0000-4000-8000-000000000000\",\"at\":\"2026-01-01T00:00:00.000Z\",\"actor\":{\"kind\":\"agent\",\"id\":\"01a00000-0000-7000-8000-00000000c0a1\",\"sessionId\":\"01a00000-0000-7000-8000-00000000c0a1\"},\"target\":{\"kind\":\"global\"},\"layer\":\"global\",\"key\":\"run.retry.maxRetries\",\"op\":\"set\",\"before\":6,\"after\":2,\"reason\":\"Corpus: an agent asks to retry less\",\"tier\":\"approve\",\"tierBasis\":{\"direction\":\"widen\",\"floor\":\"approve\",\"floorSource\":\"override\",\"web\":false,\"risk\":null},\"status\":\"declined\",\"requestId\":\"00000006-0000-4000-8000-000000000000\",\"refersTo\":\"00000005-0000-4000-8000-000000000000\",\"decidedBy\":{\"kind\":\"ui\",\"id\":\"device:corpus-phone\"}}",
    ];
    await mkdir(directory, { recursive: true });
    await writeFile(join(directory, "000000.jsonl"), rows.map(row => row + "\n").join(""));
    await writeFile(join(directory, "index.json"), JSON.stringify({ version: 1, segments: [{ name: "000000", count: rows.length }] }));
    const record = new SettingsChangeRecord(join(f.root, "stable-home"));
    expect((await record.page({ limit: 10 })).entries).toEqual(rows.map(row => JSON.parse(row)).reverse());
    const pending = JSON.parse(rows[0]!) as { changeId: string };
    expect(await record.entry(pending.changeId)).toEqual({ entry: JSON.parse(rows[0]!), facts: [JSON.parse(rows[2]!)] });
    const changes = new SettingsChangePath(f.settings.settingsModel, record, {});
    await expect(changes.undo(pending.changeId, { actor: { kind: "ui", id: phone.identity }, commandId: "stable-pending-undo" })).rejects.toMatchObject({ code: "conflict", message: "Only an applied change can be undone" });
    await record.append([{ ...JSON.parse(rows[0]!), changeId: "after-retirement", status: "applied", tier: undefined, tierBasis: undefined, requestId: undefined }]);
    expect((await record.page({ limit: 10 })).entries.map(entry => entry.changeId)).toEqual(["after-retirement", ...rows.map(row => JSON.parse(row).changeId).reverse()]);
  });

  it("history reads observe one published audit cut while real appends replace the tail segment", async () => {
    const f = await fixture(), record = f.settings.settingsChanges.record;
    const seed = { at: new Date().toISOString(), actor: { kind: "ui" as const, id: phone.identity }, target: { kind: "global" as const }, layer: "global" as const,
      key: "run.retry.maxRetries", op: "set" as const, before: 1, after: 2, status: "applied" as const };
    await record.append([{ ...seed, changeId: "race-seed" }]);
    let writing = true, reads = 0;
    const writer = (async () => {
      try { for (let index = 0; index < 150; index += 1) await record.append([{ ...seed, changeId: `race-${index}` }]); }
      finally { writing = false; }
    })();
    const readers = Array.from({ length: 4 }, async () => {
      while (writing) {
        await record.find("race-absent"); await record.entry("race-seed"); reads += 2;
      }
    });
    await Promise.all([writer, ...readers]);
    expect(reads).toBeGreaterThan(0);
    expect((await record.page({ limit: 200, filter: entry => entry.changeId.startsWith("race-") })).entries).toHaveLength(151);
  });

  it("an unanswered exact change card expires after a day, applies nothing and refuses a late tap", async () => {
    vi.useFakeTimers();
    const broker = new SemanticUIBroker(new ExtensionPresentationStore(() => {}));
    let applied = 0;
    try {
      const review = changeReview("expiring", { title: "Expiring change", requiresTap: true, items: [{ label: "Effect", before: "Absent", after: "Present" }] });
      const requested = broker.requestChange({ review, apply: async () => { applied += 1; return "applied"; } }).then(value => ({ value }), error => ({ error }));
      const interaction = broker.interactions()[0]!;
      expect(Date.parse(interaction.expiresAt!) - Date.now()).toBe(CHANGE_REVIEW_TTL_MS);
      await vi.advanceTimersByTimeAsync(CHANGE_REVIEW_TTL_MS - 1);
      expect(broker.interactions()).toHaveLength(1);
      await vi.advanceTimersByTimeAsync(1);
      expect(await requested).toMatchObject({ error: { code: "conflict", message: expect.stringContaining("expired") } });
      expect(broker.interactions()).toEqual([]);
      expect(() => broker.respond(interaction.id, interaction.hostEpoch, interaction.presentationRevision, { digest: review.digest, approved: true }, false,
        { deviceId: phone.identity, commandId: "late-tap" })).toThrow();
      expect(applied).toBe(0);
    } finally { broker.retire(); vi.useRealTimers(); }
  });

  it("a synchronous trusted callback throw settles both the original request and the response", async () => {
    const broker = new SemanticUIBroker(new ExtensionPresentationStore(() => {}));
    const review = changeReview("throw", { title: "Throwing callback", requiresTap: true, items: [{ label: "Effect", before: "Absent", after: "Attempt" }] });
    const requested = broker.requestChange({ review, apply: () => { throw new Error("synchronous effect failure"); } });
    const settled = requested.then(value => value, error => error);
    const interaction = broker.interactions()[0]!;
    try {
      await expect(broker.respond(interaction.id, interaction.hostEpoch, interaction.presentationRevision, { digest: review.digest, approved: true }, false, { deviceId: phone.identity, commandId: "throwing-effect-command" })).rejects.toThrow("synchronous effect failure");
      expect(await settled).toMatchObject({ message: "synchronous effect failure" });
      expect(broker.interactions()).toEqual([]);
    } finally { broker.retire(); }
  });
});
