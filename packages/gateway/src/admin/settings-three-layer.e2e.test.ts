import { randomUUID } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { afterAll, afterEach, describe, expect, it } from "vitest";
import { fauxAssistantMessage, fauxToolCall, type TranscriptContext } from "@earendil-works/pi-ai";
import { disposeFixtures, fixture, reportCall, TASK_REASONING_MODEL_ID } from "../../test-support/home-task-fixture.js";
import { settingsDependencies, setModelQueue } from "../../test-support/settings-dependencies.js";
import { waitFor } from "../../test-support/wait-for.js";
import { CommandReceiptStore } from "../transport/command-receipts.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "../transport/gateway-service.js";
import type { Resolution } from "../kernel/settings/tool-contract.js";

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
  const { settingsModel, settingsChanges } = settingsDependencies({ ...dependencies, sessions: f.registry, home: () => f.registry.homeOwner() });
  const service = new GatewayService({
    config: { machineId: "settings-machine", machineGroupID: "settings-group", machineName: "Test Mac", agentDir: f.agentDir, tronHome: f.tronHome },
    modelRuntime: f.gateway, trust: f.trust, settingsModel, settingsChanges, sessions: f.registry,
    home: f.registry.homeOwner(), receipts: new CommandReceiptStore(f.tronHome), broadcast: () => {},
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
    changes: [{ key: "run.retry.maxRetries", layer: "chat", op, ...(value === undefined ? {} : { value }) }],
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
    const stored = slot.settingsChatLayer().settings;
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
    expect(slot.settingsChatLayer().settings).not.toHaveProperty("retry.maxRetries");
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

  it("Project compaction budget reaches both the real SDK threshold and operation projection", async () => {
    const f = await setup();
    const slot = await f.create();
    await f.service.invoke(f.client, "settings.change", {
      commandId: randomUUID(), target: { kind: "session", sessionId: slot.id },
      fence: { runtimeGeneration: slot.snapshot().runtimeGeneration, model: slot.snapshot().model },
      changes: [{ key: "context.compaction.reserveTokens", layer: "chat", op: "set", value: 2048 }],
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
      changes: [{ key: "model.ref[role=chat]", layer: "chat", op: "set", value: { provider: f.model.provider, id: TASK_REASONING_MODEL_ID } }],
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
    await waitFor(async () => (await f.registry.homeOwner().taskStatus(taskId)).lifecycle === "terminal", "worker terminal");
    evidence.push({ case: `worker ${mode} admission Project precedence`, observed, projectModel: f.model.id });
    expect(observed).toEqual([f.model.id]);
  });
});
