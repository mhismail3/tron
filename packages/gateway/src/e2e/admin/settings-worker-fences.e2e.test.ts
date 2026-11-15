import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fauxAssistantMessage, getSystemMessageText, fauxToolCall, type AssistantMessage, type TranscriptContext } from "@earendil-works/pi-ai";
import { afterAll, afterEach, describe, expect, it } from "vitest";
import { waitFor } from "../../../test-support/wait-for.js";
import { setHomeMemoryModels } from "../../../test-support/settings-dependencies.js";
import { disposeFixtures, fixture as homeTaskFixture, reportCall, TASK_REASONING_MODEL_ID } from "../../../test-support/home-task-fixture.js";
import { CommandReceiptStore } from "../../transport/command-receipts.js";
import { UploadStore } from "../../machine/upload-store.js";
import { DEFAULT_MAX_UPLOAD_BYTES } from "../../config.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "../../transport/gateway-service.js";
import { displayOwnerOf, homeOwnerOf } from "../../../test-support/gateway-registry.js";

const ARTIFACT = join(dirname(new URL(import.meta.url).pathname), "../../../test-results/settings-worker-fences.json");
const transcript: Array<{ case: string; steps: Array<Record<string, unknown>> }> = [];
afterEach(async () => { await disposeFixtures(); });
afterAll(async () => {
  await mkdir(dirname(ARTIFACT), { recursive: true });
  await writeFile(ARTIFACT, `${JSON.stringify(transcript, null, 2)}\n`);
});

function phone(): ClientContext {
  return { id: "phone", identity: "device:phone", isLocal: false, isSubscribed: () => true, isRevoked: () => false, revokeDevice: () => {} } as unknown as ClientContext;
}

let command = 0;
const commandId = () => `worker-fence-${String(++command).padStart(4, "0")}`;
const textOf = (message: { content: unknown }) => typeof message.content === "string" ? message.content
  : (message.content as Array<{ text?: string }>).map(part => part.text ?? "").join("");

async function gateway() {
  const f = await homeTaskFixture();
  const { settingsModel, settingsChanges } = f.settings;
  await setHomeMemoryModels(f.registry, [{ provider: f.model.provider, id: f.model.id }]);
  const service = new GatewayService({ display: displayOwnerOf(f.registry),
    config: { machineId: "machine", machineGroupID: "group", machineName: "Mac", tronHome: f.tronHome, agentDir: f.agentDir },
    modelRuntime: f.gateway, trust: f.trust, settingsModel, settingsChanges, sessions: f.registry, home: homeOwnerOf(f.registry),
    receipts: new CommandReceiptStore(f.tronHome), uploads: new UploadStore(f.tronHome, DEFAULT_MAX_UPLOAD_BYTES),
    notifications: { enqueue: async () => "queued" }, broadcast: () => {},
    globalProviderResources: { withStableSnapshot: async (operation: () => Promise<unknown>) => operation(), requestReload: () => {} },
  } as unknown as GatewayServiceDependencies);
  return { ...f, service, settingsChanges };
}

type ToolArgs = Parameters<typeof fauxToolCall>[1];
type Settled = { taskId: string; call?: { name: string; args: Record<string, unknown> } };

async function homeScript(f: Awaited<ReturnType<typeof gateway>>, settled: Settled = { taskId: "settled-worker" }) {
  const isWorker = (context: TranscriptContext) => context.messages.some(message => message.role === "system" && getSystemMessageText(message).includes("This is a finite Home task"));
  let homeCall: { prompt: string; name: string; args: Record<string, unknown> } | undefined;
  const homeResults = new Map<string, { isError: boolean; text: string; details: unknown }>();
  let workerResult: { isError: boolean; text: string } | undefined;
  const respond = async (context: TranscriptContext): Promise<AssistantMessage> => {
    if (isWorker(context)) {
      const last = context.messages.at(-1)!;
      if (settled.call && last.role === "user") return fauxAssistantMessage([fauxToolCall(settled.call.name, settled.call.args as ToolArgs)], { stopReason: "toolUse" });
      if (settled.call && last.role === "toolResult" && last.toolName === settled.call.name) workerResult = { isError: last.isError === true, text: textOf(last) };
      return fauxAssistantMessage([reportCall(settled.taskId)], { stopReason: "toolUse" });
    }
    const users = context.messages.filter(message => message.role === "user").map(textOf);
    const last = context.messages.at(-1)!;
    if (last.role === "toolResult") {
      if (homeCall && last.toolName === homeCall.name) homeResults.set(homeCall.prompt, { isError: last.isError === true, text: textOf(last), details: last.details });
      return fauxAssistantMessage("Done.");
    }
    if (homeCall && users.at(-1) === homeCall.prompt) return fauxAssistantMessage([fauxToolCall(homeCall.name, homeCall.args as ToolArgs)], { stopReason: "toolUse" });
    return fauxAssistantMessage("Noted.");
  };
  f.faux.setResponses(Array.from({ length: 20 }, () => respond as never));
  const home = await f.registry.acquire(f.home.sessionId);
  const ask = (prompt: string, name: string, args: Record<string, unknown>) => {
    homeCall = { prompt, name, args };
    return home.prompt(prompt);
  };
  const resultOf = (prompt: string) => waitFor(() => homeResults.get(prompt), `Home result: ${prompt}`);
  const homeSays = async (prompt: string, name: string, args: Record<string, unknown>) => {
    await ask(prompt, name, args);
    const result = await resultOf(prompt);
    await waitFor(() => home.snapshot().configurationBlocker === null || undefined, `Home settled: ${prompt}`);
    return result;
  };
  return { home, ask, resultOf, homeSays, workerResult: () => workerResult };
}

async function delegateSettled(f: Awaited<ReturnType<typeof gateway>>, home: Awaited<ReturnType<Awaited<ReturnType<typeof gateway>>["registry"]["acquire"]>>, homeSays: (prompt: string, name: string, args: Record<string, unknown>) => Promise<unknown>, taskId: string) {
  await homeSays(`Delegate ${taskId}`, "delegate", { taskId, title: taskId, intent: "Report at once", target: f.cwd });
  await waitFor(async () => (await homeOwnerOf(f.registry).taskResult(taskId).catch(() => undefined) as { wake?: { state?: string } } | undefined)?.wake?.state === "acknowledged" || undefined, "result wake acknowledged");
  await waitFor(() => home.snapshot().configurationBlocker === null || undefined, "Home settled after the result");
  return (await homeOwnerOf(f.registry).taskStatus(taskId)).sessionId!;
}

const defaultTrustOnDisk = async (agentDir: string) => (JSON.parse(await readFile(join(agentDir, "settings.json"), "utf8")) as Record<string, unknown>).defaultProjectTrust;

describe("settings worker changes and Session fences", () => {
  it("Home applies routine model/thinking changes to a settled worker without a client opening that worker", async () => {
    const f = await gateway();
    const { home, homeSays } = await homeScript(f);
    const workerSessionId = await delegateSettled(f, home, homeSays, "settled-worker");

    const REASONING = { provider: f.model.provider, id: TASK_REASONING_MODEL_ID };
    const applied = await homeSays("Switch settled-worker to reasoning", "settings", { action: "change", taskId: "settled-worker", reason: "Harder step on resume",
      changes: [{ key: "model.ref[role=chat]", layer: "session", op: "set", value: REASONING }, { key: "model.thinking[role=chat]", layer: "session", op: "set", value: "low" }] });
    expect(applied.details).toMatchObject({ status: "applied", review: { requiresTap: false } });
    expect(home.snapshot().extensionPresentation.pendingInteractions).toEqual([]);
    const worker = await f.registry.acquire(workerSessionId);
    expect(worker.snapshot()).toMatchObject({ model: REASONING, thinkingLevel: "low" });
    expect((await f.settingsChanges.history({ key: "model.thinking[role=chat]" }, { kind: "ui", id: "maintainer" })).entries.map(entry => entry.status)).not.toContain("failed");
    transcript.push({ case: "routine worker change without a client fence", steps: [{ applied: applied.details }] });
  }, 90_000);

  it("Home's default trust change needs the native card; an ordinary chat is refused", async () => {
    const f = await gateway();
    const { home, ask, resultOf } = await homeScript(f);
    const changes = [{ key: "permissions.defaultProjectTrust", layer: "global", op: "set", value: "always" }] as const;
    const prompt = "Trust new projects by default";
    const asked = ask(prompt, "settings", { action: "change", reason: "Maintainer asked to trust new projects", changes });
    const card = await waitFor(() => home.snapshot().extensionPresentation.pendingInteractions[0], "native default trust card");
    if (card.method !== "change") throw new Error("Home's default trust change must present a change card");
    expect(card.review).toMatchObject({ requiresTap: true });
    expect(await defaultTrustOnDisk(f.agentDir)).not.toBe("always");
    await expect(f.service.invoke(phone(), "extension.respond", { commandId: commandId(), sessionId: home.id, interactionId: card.id,
      hostEpoch: card.hostEpoch, presentationRevision: card.presentationRevision, value: { digest: card.review.digest, approved: true } })).resolves.toBeDefined();
    await asked;
    const applied = await resultOf(prompt);
    expect(applied.details).toMatchObject({ status: "applied" });
    expect(await defaultTrustOnDisk(f.agentDir)).toBe("always");
    const chat = await f.registry.create(f.cwd);
    await expect(f.settingsChanges.change({ kind: "global" }, changes, { actor: { kind: "agent", id: chat.id, sessionId: chat.id },
      reason: "Ordinary chat tries" })).rejects.toMatchObject({ code: "invalid_request", message: "Default trust policy cannot be changed by agent" });
    transcript.push({ case: "Home default trust change needs the native card", steps: [{ applied: applied.details }] });
  }, 90_000);

  it("a registered worker cannot change default trust itself; its own settings call is refused", async () => {
    const f = await gateway();
    const changes = [{ key: "permissions.defaultProjectTrust", layer: "global", op: "set", value: "always" }] as const;
    const { home, homeSays, workerResult } = await homeScript(f, { taskId: "trust-worker", call: { name: "settings", args: { action: "change", reason: "Worker asks to trust projects", changes } } });
    await delegateSettled(f, home, homeSays, "trust-worker");
    const refused = await waitFor(() => workerResult(), "worker settings result");
    expect(refused).toMatchObject({ isError: true });
    expect(refused.text).toContain("Default trust policy cannot be changed by worker");
    expect(await defaultTrustOnDisk(f.agentDir)).not.toBe("always");
    expect((await f.settingsChanges.history({ key: "permissions.defaultProjectTrust" })).entries).toEqual([]);
    transcript.push({ case: "registered worker default-trust change refused", steps: [{ refused: refused.text }] });
  }, 90_000);

  it("a Session-scope change without the fence it read is refused at submission, dry run included", async () => {
    const f = await gateway();
    const slot = await f.registry.create(f.cwd);
    await slot.setModel(f.model.provider, f.model.id);
    const target = { kind: "session", sessionId: slot.id };
    const changes = [{ key: "run.retry.maxRetries", layer: "session", op: "set", value: 7 }];
    const refusals: string[] = [];
    for (const dryRun of [true, false]) {
      const refused = f.service.invoke(phone(), "settings.change", { commandId: commandId(), target, changes, ...(dryRun ? { dryRun } : {}) });
      await expect(refused).rejects.toMatchObject({ code: "invalid_request", message: expect.stringMatching(/fence/) });
      refusals.push(String(((await refused.catch((error: Error) => error)) as Error).message));
    }
    expect((await f.settingsChanges.history({ key: "run.retry.maxRetries" }, { kind: "ui", id: "maintainer" })).entries).toEqual([]);
    const snapshot = slot.snapshot();
    const fence = { runtimeGeneration: snapshot.runtimeGeneration, model: snapshot.model, revision: snapshot.revision };
    const contextWindow = [{ key: "model.contextWindow", layer: "session", op: "set", value: 100_000, qualifiers: { model: `${f.model.provider}/${f.model.id}` } }];
    await expect(f.service.invoke(phone(), "settings.change", { commandId: commandId(), target, fence: { runtimeGeneration: fence.runtimeGeneration, model: fence.model }, changes: contextWindow, dryRun: true }))
      .rejects.toMatchObject({ code: "invalid_request", message: expect.stringMatching(/revision/) });
    await expect(f.service.invoke(phone(), "settings.change", { commandId: commandId(), target, dryRun: true,
      changes: [{ key: "tools.active", layer: "session", op: "set", value: ["read"] }] })).resolves.toMatchObject({ dryRun: true, status: "applied" });
    await expect(f.service.invoke(phone(), "settings.change", { commandId: commandId(), target, fence, changes, dryRun: true })).resolves.toMatchObject({ dryRun: true, status: "applied" });
    await expect(f.service.invoke(phone(), "settings.change", { commandId: commandId(), target, fence, changes })).resolves.toMatchObject({ status: "applied" });
    transcript.push({ case: "fence-less Chat change refused at submission", steps: [{ refusals }] });
  }, 60_000);
});
