import { randomUUID } from "node:crypto";
import { chmod, mkdir, readFile, realpath, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { afterAll, afterEach, describe, expect, it } from "vitest";
import { fauxAssistantMessage, fauxToolCall, type TranscriptContext } from "@earendil-works/pi-ai";
import { disposeFixtures, fixture, reportCall, TASK_REASONING_MODEL_ID } from "../../test-support/home-task-fixture.js";
import { setModelQueue } from "../../test-support/settings-dependencies.js";
import { waitFor } from "../../test-support/wait-for.js";
import { CommandReceiptStore } from "../transport/command-receipts.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "../transport/gateway-service.js";
import type { ChangeResult, Resolution } from "../kernel/settings/tool-contract.js";
import { displayOwnerOf, homeOwnerOf } from "../../test-support/gateway-registry.js";

// Real Registry/Pi/provider/RPC boundaries, not declaration-table assertions.
// This RED checkpoint names the approved behavior before changing any owner.
const evidence: Array<Record<string, unknown>> = [];
afterEach(disposeFixtures);
afterAll(async () => {
  await mkdir("test-results/settings-three-layer", { recursive: true });
  await writeFile("test-results/settings-three-layer/boundary-contracts.json", JSON.stringify(evidence, null, 2) + "\n");
});

async function setup() {
  const f = await fixture();
  const dependencies = { registry: f.registry, agentDir: f.agentDir, tronHome: f.tronHome, trust: f.trust, modelRuntime: f.gateway };
  const { settingsModel, settingsChanges } = f.settings;
  const service = new GatewayService({ display: displayOwnerOf(f.registry),
    config: { machineId: "settings-machine", machineGroupID: "settings-group", machineName: "Test Mac", agentDir: f.agentDir, tronHome: f.tronHome },
    modelRuntime: f.gateway, trust: f.trust, settingsModel, settingsChanges, sessions: f.registry,
    home: homeOwnerOf(f.registry), receipts: new CommandReceiptStore(f.tronHome), broadcast: () => {},
    globalProviderResources: { withStableSnapshot: async (operation: () => Promise<unknown>) => operation(), requestReload: () => {} },
  } as unknown as GatewayServiceDependencies);
  const client = { id: "settings-phone", identity: "local", isLocal: true, isSubscribed: () => true,
    isRevoked: () => false, revokeDevice: () => {} } as unknown as ClientContext;
  const globalPath = join(f.agentDir, "settings.json");
  const global = JSON.parse(await readFile(globalPath, "utf8"));
  await writeFile(globalPath, JSON.stringify({ ...global, defaultTools: ["read"], retry: { maxRetries: 1, baseDelayMs: 1 } }));
  await f.trust.set(f.cwd, true);
  await mkdir(join(f.cwd, ".pi"), { recursive: true });
  const project = (document: Record<string, unknown>) => writeFile(join(f.cwd, ".pi", "settings.json"), JSON.stringify(document));
  const create = () => f.registry.create(f.cwd);
  type Slot = Awaited<ReturnType<typeof create>>;
  const resolve = (slot: Slot, keys: string[]) => service.invoke(client, "settings.resolve", {
    target: { kind: "session", sessionId: slot.id }, keys,
  }) as unknown as Promise<Resolution>;
  const retryChange = (slot: Slot, op: "set" | "unset", value?: number) => service.invoke(client, "settings.change", {
    commandId: randomUUID(), target: { kind: "session", sessionId: slot.id },
    fence: { runtimeGeneration: slot.snapshot().runtimeGeneration, model: slot.snapshot().model },
    changes: [{ key: "run.retry.maxRetries", layer: "session", op, ...(value === undefined ? {} : { value }) }],
  });
  const attempts = async (slot: Slot) => {
    let count = 0;
    f.faux.setResponses(Array.from({ length: 5 }, () => () => {
      count += 1;
      return fauxAssistantMessage("", { stopReason: "error", errorMessage: "503 service unavailable" });
    }));
    await slot.prompt("Exercise the effective retry policy");
    await waitFor(() => slot.snapshot().configurationBlocker === null, "retry request settled");
    return count;
  };
  return { ...f, dependencies, service, client, project, create, resolve, retryChange, attempts };
}

const retryValue = (resolution: Resolution) => resolution.keys.find(row => row.key === "run.retry.maxRetries")?.value;

describe("approved three-layer settings at real Gateway boundaries", () => {
  it("applies, logs and undoes through receipts, refusing a second command and allowing Undo of Undo", async () => {
    const f = await setup();
    const slot = await f.create();
    const applied = await f.retryChange(slot, "set", 3) as unknown as ChangeResult;
    const original = applied.changes[0]!.changeId;
    const undo = { commandId: randomUUID(), changeId: original,
      fence: { runtimeGeneration: slot.snapshot().runtimeGeneration, model: slot.snapshot().model } };
    const reverted = await f.service.invoke(f.client, "settings.undo", undo) as unknown as ChangeResult;
    expect(retryValue(await f.resolve(slot, ["run.retry.maxRetries"]))).toBe(1);
    expect(await f.service.invoke(f.client, "settings.undo", undo)).toEqual(reverted);
    await expect(f.service.invoke(f.client, "settings.undo", { ...undo, commandId: randomUUID() })).rejects.toMatchObject({ code: "conflict" });
    const redone = await f.service.invoke(f.client, "settings.undo", { ...undo, commandId: randomUUID(), changeId: reverted.changes[0]!.changeId }) as unknown as ChangeResult;
    expect(retryValue(await f.resolve(slot, ["run.retry.maxRetries"]))).toBe(3);
    const entries = (await f.settings.settingsChanges.history({ key: "run.retry.maxRetries" })).entries;
    expect(entries.find(entry => entry.changeId === reverted.changes[0]!.changeId)?.undoOf).toBe(original);
    expect(entries.find(entry => entry.changeId === redone.changes[0]!.changeId)?.undoOf).toBe(reverted.changes[0]!.changeId);
    expect(entries.filter(entry => entry.changeId === reverted.changes[0]!.changeId)).toHaveLength(1);
    evidence.push({ case: "receipt-apply-log-undo-redo", original, reverted, redone });
  });

  it("serializes concurrent expected-value Session changes and never overwrites the winner", async () => {
    const f = await setup();
    const slot = await f.create();
    const results = await Promise.allSettled([2, 3].map(value => f.service.invoke(f.client, "settings.change", {
      commandId: randomUUID(), target: { kind: "session", sessionId: slot.id },
      fence: { runtimeGeneration: slot.snapshot().runtimeGeneration, model: slot.snapshot().model },
      changes: [{ key: "run.retry.maxRetries", layer: "session", op: "set", value, expected: null }],
    })));
    const winners = results.filter((result): result is PromiseFulfilledResult<Awaited<ReturnType<typeof f.service.invoke>>> => result.status === "fulfilled");
    expect(winners).toHaveLength(1);
    const refusal = results.find((result): result is PromiseRejectedResult => result.status === "rejected");
    expect(["busy", "conflict"]).toContain(refusal?.reason.code);
    const winner = winners[0]!.value as unknown as ChangeResult;
    await expect(f.service.invoke(f.client, "settings.change", {
      commandId: randomUUID(), target: { kind: "session", sessionId: slot.id },
      fence: { runtimeGeneration: slot.snapshot().runtimeGeneration, model: slot.snapshot().model },
      changes: [{ key: "run.retry.maxRetries", layer: "session", op: "set", value: 4, expected: null }],
    })).rejects.toMatchObject({ code: "conflict" });
    expect(retryValue(await f.resolve(slot, ["run.retry.maxRetries"]))).toBe(winner.changes[0]!.after);
    expect((await f.settings.settingsChanges.history({ key: "run.retry.maxRetries" })).entries.filter(entry => entry.status === "applied")).toHaveLength(1);
    evidence.push({ case: "expected-session-winner", winner });
  });
  it("refuses a stale expected value for a Session-owned field without changing its effective value", async () => {
    const f = await setup();
    const slot = await f.create();
    const before = (await f.resolve(slot, ["model.contextWindow"])).keys[0]!.value;
    await expect(f.service.invoke(f.client, "settings.change", {
      commandId: randomUUID(), target: { kind: "session", sessionId: slot.id },
      fence: { runtimeGeneration: slot.snapshot().runtimeGeneration, model: slot.snapshot().model, revision: slot.snapshot().revision },
      changes: [{ key: "model.contextWindow", layer: "session", op: "set", value: 65536, expected: 1024,
        qualifiers: { model: `${slot.snapshot().model!.provider}/${slot.snapshot().model!.id}` } }],
    })).rejects.toMatchObject({ code: "conflict" });
    expect((await f.resolve(slot, ["model.contextWindow"])).keys[0]!.value).toEqual(before);
  });

  it("retains an uncertain receipt after a post-effect history publication failure and never replays the effect", async () => {
    const f = await setup();
    const history = f.settings.settingsChanges.record.path;
    const settingsPath = join(f.agentDir, "settings.json");
    expect(JSON.parse(await readFile(settingsPath, "utf8")).retry.maxRetries).toBe(1);
    await mkdir(history, { recursive: true });
    await chmod(history, 0o500);
    const command = { commandId: randomUUID(), target: { kind: "global" },
      changes: [{ key: "run.retry.maxRetries", layer: "global", op: "set", value: 3 }] };
    let failure: unknown;
    try {
      failure = await f.service.invoke(f.client, "settings.change", command).then(() => undefined, error => error);
      expect(failure).toMatchObject({ message: expect.stringContaining(history) });
      expect(JSON.parse(await readFile(settingsPath, "utf8")).retry.maxRetries).toBe(3);
    } finally {
      await chmod(history, 0o700);
    }
    await expect(f.service.invoke(f.client, "settings.change", command)).rejects.toMatchObject({ code: "conflict", details: { outcomeUnknown: true } });
    expect(failure).toMatchObject({ code: "conflict", details: { outcomeUnknown: true } });
  });

  it("Project beats a stored Session override in both RPC resolution and actual provider retries", async () => {
    const f = await setup();
    const slot = await f.create();
    await f.retryChange(slot, "set", 0);
    await f.project({ retry: { maxRetries: 2 } });
    const observed = { effective: retryValue(await f.resolve(slot, ["run.retry.maxRetries"])), requests: await f.attempts(slot) };
    evidence.push({ case: "project precedence", observed });
    expect(observed).toEqual({ effective: 2, requests: 3 });
  });

  it("a trusted Project cannot replace the Global tool-permission loadout during SDK admission", async () => {
    const f = await setup();
    await f.project({ defaultTools: ["write"] });
    const slot = await f.create();
    const tools = slot.runtime.session.getActiveToolNames();
    const resolved = (await f.resolve(slot, ["tools.active"])).keys[0];
    evidence.push({ case: "project tool permission refused", tools, resolved });
    expect(tools).toContain("read");
    expect(tools).not.toContain("write");
    expect(resolved?.value).toContain("read");
  });

  it("refuses edits masked by Project without mutating the inactive canonical Session override", async () => {
    const f = await setup();
    const slot = await f.create();
    await f.retryChange(slot, "set", 0);
    await f.project({ retry: { maxRetries: 2 } });
    let refusal: { code?: string; message?: string } | undefined;
    try { await f.retryChange(slot, "set", 1); } catch (error) { refusal = error as typeof refusal; }
    const stored = slot.settingsSessionLayer().settings;
    evidence.push({ case: "masked mutation", refusal, stored });
    expect(refusal?.code).toBe("conflict");
    expect(stored).toMatchObject({ retry: { maxRetries: 0 } });
  });

  it("reactivates the retained override after Project removal, then Revert inherits Global", async () => {
    const f = await setup();
    const slot = await f.create();
    await f.retryChange(slot, "set", 0);
    await f.project({ retry: { maxRetries: 2 } });
    const projectValue = retryValue(await f.resolve(slot, ["run.retry.maxRetries"]));
    await f.project({});
    const activeOverride = retryValue(await f.resolve(slot, ["run.retry.maxRetries"]));
    await f.retryChange(slot, "unset");
    const inherited = retryValue(await f.resolve(slot, ["run.retry.maxRetries"]));
    const requests = await f.attempts(slot);
    const observed = { projectValue, activeOverride, inherited, requests };
    evidence.push({ case: "inactive override and revert", observed });
    expect(observed).toEqual({ projectValue: 2, activeOverride: 0, inherited: 1, requests: 2 });
    expect(slot.settingsSessionLayer().settings).not.toHaveProperty("retry.maxRetries");
  });

  it("Revert already removes only its own override and follows the Global provider policy", async () => {
    const f = await setup();
    const slot = await f.create();
    await f.retryChange(slot, "set", 0);
    expect(await f.attempts(slot)).toBe(1);
    await f.retryChange(slot, "unset");
    const observed = { effective: retryValue(await f.resolve(slot, ["run.retry.maxRetries"])), requests: await f.attempts(slot) };
    evidence.push({ case: "existing revert positive control", observed });
    expect(observed).toEqual({ effective: 1, requests: 2 });
  });

  it("serves read-only recovery scope, inactive override and exact Project path from real resolution", async () => {
    const f = await setup();
    const slot = await f.create();
    await f.retryChange(slot, "set", 0);
    await f.project({ retry: { maxRetries: 2 } });
    const read = async () => f.service.invoke(f.client, "settings.resolve", {
      target: { kind: "session", sessionId: slot.id }, keys: ["run.retry.maxRetries"],
      renderer: { version: 1, controls: [] },
    }) as Promise<{ keys: Array<{ value: unknown; overridden: boolean; projectSetting?: { file: string; path: string }; presentation: { sessionOverridable: boolean; projectSettable: boolean; editable: boolean } }> }>;
    const masked = (await read()).keys[0]!;
    expect(masked).toMatchObject({ value: 2, overridden: true,
      projectSetting: { file: join(await realpath(f.cwd), ".pi", "settings.json"), path: "retry.maxRetries" },
      presentation: { sessionOverridable: true, projectSettable: true, editable: true } });
    await f.project({});
    const active = (await read()).keys[0]!;
    expect(active).toMatchObject({ value: 0, overridden: true });
    expect(active.projectSetting).toBeUndefined();
    await f.retryChange(slot, "unset");
    expect((await read()).keys).toEqual([]);
  });

  it("serves target-specific recovery capability, Global reset presence and no stopped-runtime setting row", async () => {
    const f = await setup();
    const read = (target: Record<string, string>) => f.service.invoke(f.client, "settings.resolve", {
      target, keys: ["run.retry.maxRetries", "setup.sessionDir"], renderer: { version: 1, controls: ["text"] },
    }) as Promise<{ keys: Array<{ key: string; overridden: boolean; presentation: { editable: boolean } }> }>;
    const global = await read({ kind: "global" });
    expect(global.keys).toHaveLength(1);
    expect(global.keys[0]).toMatchObject({ key: "run.retry.maxRetries", overridden: true, presentation: { editable: true } });
    await f.project({ retry: { maxRetries: 2 } });
    const project = await read({ kind: "project", cwd: f.cwd });
    expect(project.keys.find(row => row.key === "run.retry.maxRetries")?.presentation.editable).toBe(false);
  });

  it("reports ignored Project fields with a bounded file/key/reason projection, never their values", async () => {
    const f = await setup();
    const slot = await f.create();
    await f.project({ defaultTools: ["do-not-disclose-value"], thinkingBudgets: { high: 7 },
      retry: { maxRetries: 2 }, ...Object.fromEntries(Array.from({ length: 40 }, (_, index) => [`unknown${index}`, "do-not-disclose-value"])) });
    const resolved = await f.resolve(slot, ["run.retry.maxRetries"]) as Resolution & { diagnosticsTruncated?: true };
    expect(retryValue(resolved)).toBe(2);
    expect(resolved.diagnostics).toHaveLength(32);
    expect(resolved.diagnosticsTruncated).toBe(true);
    expect(resolved.diagnostics).toContainEqual({ key: "tools.active", layer: "project", reason: "project-forbidden",
      path: "defaultTools", file: join(await realpath(f.cwd), ".pi", "settings.json") });
    expect(JSON.stringify(resolved.diagnostics)).not.toContain("do-not-disclose-value");
  });

  it("leaves untrusted and unreadable Project rows inherited and editable, with path-only notices", async () => {
    const f = await setup();
    const slot = await f.create();
    await f.project({ retry: { maxRetries: 2 } });
    await f.trust.set(f.cwd, false);
    const untrusted = await f.resolve(slot, ["run.retry.maxRetries"]);
    expect(retryValue(untrusted)).toBe(1);
    expect(untrusted.keys[0]?.projectSetting).toBeUndefined();
    expect(untrusted.projectNotice).toEqual({ file: join(await realpath(f.cwd), ".pi", "settings.json"),
      message: "Project settings aren't applied until this project is trusted" });
    await writeFile(join(f.cwd, ".pi", "settings.json"), "unreadable-json-secret-value");
    const unreadable = await f.resolve(slot, ["run.retry.maxRetries"]);
    expect(retryValue(unreadable)).toBe(1);
    expect(unreadable.keys[0]?.projectSetting).toBeUndefined();
    expect(unreadable.projectNotice).toEqual({ file: join(await realpath(f.cwd), ".pi", "settings.json"),
      message: "Project settings couldn't be read" });
    expect(JSON.stringify(unreadable)).not.toContain("unreadable-json-secret-value");
  });

  it("keeps thinking budgets and image visibility Global-only during real SDK admission", async () => {
    const f = await setup();
    const globalPath = join(f.agentDir, "settings.json");
    const global = JSON.parse(await readFile(globalPath, "utf8"));
    await writeFile(globalPath, JSON.stringify({ ...global, thinkingBudgets: { high: 4096 }, images: { blockImages: true } }));
    await f.project({ thinkingBudgets: { high: 8 }, images: { blockImages: false } });
    const slot = await f.create();
    expect(slot.runtime.session.settingsManager.getThinkingBudgets()).toEqual({ high: 4096 });
    expect(slot.runtime.session.settingsManager.getBlockImages()).toBe(true);
    const rows = (await f.resolve(slot, ["model.thinkingBudgets", "context.images.block"])).keys;
    expect(rows.find(row => row.key === "model.thinkingBudgets")?.value).toEqual({ high: 4096 });
    expect(rows.find(row => row.key === "context.images.block")?.value).toBe(true);
  });

  it("Project compaction budget reaches both the real SDK threshold and operation projection", async () => {
    const f = await setup();
    const slot = await f.create();
    await f.service.invoke(f.client, "settings.change", {
      commandId: randomUUID(), target: { kind: "session", sessionId: slot.id },
      fence: { runtimeGeneration: slot.snapshot().runtimeGeneration, model: slot.snapshot().model },
      changes: [{ key: "context.compaction.reserveTokens", layer: "session", op: "set", value: 2048 }],
    });
    await f.project({ compaction: { reserveTokens: 4096 } });
    await f.attempts(slot);
    const observed = { sdk: slot.runtime.session.settingsManager.getCompactionSettings().reserveTokens,
      projected: slot.snapshot().compactionPolicy?.next.reserveTokens };
    evidence.push({ case: "single compaction precedence", observed });
    expect(observed).toEqual({ sdk: 4096, projected: 4096 });
  });

  it("SDK Project writes preserve ignored fields without admitting them", async () => {
    const f = await setup();
    const ignored = { defaultTools: ["write"], futureOwnedField: { keep: "untouched" } };
    await f.project({ ...ignored, packages: [] });
    const slot = await f.create();
    const manager = slot.runtime.session.settingsManager;
    manager.setProjectPackages(["./fixture-package"]);
    await manager.flush();
    const raw = JSON.parse(await readFile(join(f.cwd, ".pi", "settings.json"), "utf8"));
    const admitted = manager.getProjectSettings();
    evidence.push({ case: "SDK locked projection write", raw, admitted });
    expect(raw).toMatchObject({ ...ignored, packages: ["./fixture-package"] });
    expect(admitted).not.toHaveProperty("defaultTools");
    expect(admitted).not.toHaveProperty("futureOwnedField");
  });

  it.each([
    { defaultProvider: "test-faux" },
    { defaultModel: "faux-1" },
    { defaultProvider: 17, defaultModel: "faux-1" },
  ])("refuses an invalid Project model reference instead of inheriting Global: %j", async invalid => {
    const f = await setup();
    await f.project(invalid);
    await expect(f.create()).rejects.toMatchObject({ code: "conflict" });
    evidence.push({ case: "invalid Project model refused", fields: Object.keys(invalid) });
  });

  it("refuses an unavailable Project model instead of admitting the SDK fallback", async () => {
    const f = await setup();
    await f.project({ defaultProvider: f.model.provider, defaultModel: "missing-project-model" });
    await expect(f.create()).rejects.toMatchObject({ code: "conflict" });
    evidence.push({ case: "unavailable Project model refused" });
  });

  it("retains a model override through masking and cold resume, then reactivates it after Project removal", async () => {
    const f = await setup();
    const slot = await f.create();
    await f.service.invoke(f.client, "settings.change", {
      commandId: randomUUID(), target: { kind: "session", sessionId: slot.id },
      fence: { runtimeGeneration: slot.snapshot().runtimeGeneration, model: slot.snapshot().model },
      changes: [{ key: "model.ref[role=chat]", layer: "session", op: "set", value: { provider: f.model.provider, id: TASK_REASONING_MODEL_ID } }],
    });
    await f.project({ defaultProvider: f.model.provider, defaultModel: f.model.id });
    const observed: string[] = [];
    const respond = () => (_context: unknown, _options: unknown, _state: unknown, model: { id: string }) => {
      observed.push(model.id); return fauxAssistantMessage("model admitted");
    };
    f.faux.setResponses([respond(), respond(), respond()]);
    await slot.prompt("Read the Project model");
    await waitFor(() => slot.snapshot().configurationBlocker === null, "first model request settled");
    const cold = await f.restart();
    const resumed = await cold.acquire(slot.id);
    await resumed.prompt("Read the Project model after cold resume");
    await waitFor(() => resumed.snapshot().configurationBlocker === null, "cold model request settled");
    await f.project({});
    await resumed.prompt("Read the retained Session override");
    await waitFor(() => resumed.snapshot().configurationBlocker === null, "unmasked model request settled");
    evidence.push({ case: "cold inactive model override", observed });
    expect(observed).toEqual([f.model.id, f.model.id, TASK_REASONING_MODEL_ID]);
  });

  it.each(["seed", "explicit"])("Project model beats the Home worker %s at the first real request", async mode => {
    const f = await setup();
    const taskId = `three-layer-${mode}-worker`;
    await f.project({ defaultProvider: f.model.provider, defaultModel: f.model.id });
    await setModelQueue(f.dependencies, "background", [f.model]);
    await setModelQueue(f.dependencies, "worker", [{ provider: f.model.provider, id: TASK_REASONING_MODEL_ID }]);
    const observed: string[] = [];
    const text = (content: unknown): string => typeof content === "string" ? content
      : Array.isArray(content) ? content.map(part => part.text ?? "").join("") : "";
    const workerTurn = (context: TranscriptContext) => context.messages.some(message => message.role === "user"
      && text(message.content).includes("This is a finite Home task"));
    f.faux.setResponses(Array.from({ length: 4 }, () => (context, _options, _state, model) => {
      if (workerTurn(context)) {
        observed.push(model.id);
        return fauxAssistantMessage([reportCall("three-layer-worker")], { stopReason: "toolUse" });
      }
      const current = context.messages.slice(context.messages.findLastIndex(message => message.role === "user"));
      return current.some(message => message.role === "toolResult" && message.toolName === "delegate")
        ? fauxAssistantMessage("Delegation accepted")
        : fauxAssistantMessage([fauxToolCall("delegate", {
          taskId, intent: "Finite model precedence check", target: f.cwd,
          ...(mode === "explicit" ? { model: { provider: f.model.provider, id: TASK_REASONING_MODEL_ID }, reason: "Test explicit task model against Project" } : {}),
        })], { stopReason: "toolUse" });
    }));
    const home = await f.registry.acquire(f.home.sessionId);
    await home.prompt("Delegate the model precedence check");
    await waitFor(() => home.snapshot().configurationBlocker === null, "Home delegation turn settled");
    await waitFor(async () => (await homeOwnerOf(f.registry).taskStatus(taskId)).lifecycle === "terminal", "worker terminal");
    evidence.push({ case: `worker ${mode} admission Project precedence`, observed, projectModel: f.model.id });
    expect(observed).toEqual([f.model.id]);
  });
});
