import { mkdir, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fauxAssistantMessage, fauxToolCall, type AssistantMessage, type TranscriptContext } from "@earendil-works/pi-ai";
import { afterAll, afterEach, describe, expect, it } from "vitest";
import { waitFor } from "../../test-support/wait-for.js";
import { setHomeMemoryModels } from "../../test-support/settings-dependencies.js";
import { disposeFixtures, fixture as homeTaskFixture, reportCall, TASK_REASONING_MODEL_ID } from "../../test-support/home-task-fixture.js";
import { CommandReceiptStore } from "../transport/command-receipts.js";
import { UploadStore } from "../machine/upload-store.js";
import { DEFAULT_MAX_UPLOAD_BYTES } from "../config.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "../transport/gateway-service.js";
import { displayOwnerOf, homeOwnerOf } from "../../test-support/gateway-registry.js";

/** Real Home/worker routine changes and client Session fences at the Gateway RPC boundary.
 * Approval decisions are retired; routine changes retain their original domain/SDK assertions. */
const ARTIFACT = join(dirname(new URL(import.meta.url).pathname), "../../test-results/settings-worker-fences.json");
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

describe("settings worker changes and Session fences", () => {
  it("Home applies routine model/thinking changes to a settled worker without a client opening that worker", async () => {
    const f = await gateway();
    const isWorker = (context: TranscriptContext) => context.messages.some(message => message.role === "user" && textOf(message).includes("This is a finite Home task"));
    let homeCall: { prompt: string; name: string; args: Record<string, unknown> } | undefined;
    const homeResults = new Map<string, { isError: boolean; text: string; details: unknown }>();
    const respond = async (context: TranscriptContext): Promise<AssistantMessage> => {
      if (isWorker(context)) return fauxAssistantMessage([reportCall("settled-worker")], { stopReason: "toolUse" });
      const users = context.messages.filter(message => message.role === "user").map(textOf);
      const last = context.messages.at(-1)!;
      if (last.role === "toolResult") {
        if (homeCall && last.toolName === homeCall.name) homeResults.set(homeCall.prompt, { isError: last.isError === true, text: textOf(last), details: last.details });
        return fauxAssistantMessage("Done.");
      }
      if (homeCall && users.at(-1) === homeCall.prompt) return fauxAssistantMessage([fauxToolCall(homeCall.name, homeCall.args)], { stopReason: "toolUse" });
      return fauxAssistantMessage("Noted.");
    };
    f.faux.setResponses(Array.from({ length: 20 }, () => respond as never));
    const home = await f.registry.acquire(f.home.sessionId);
    const homeSays = async (prompt: string, name: string, args: Record<string, unknown>) => {
      homeCall = { prompt, name, args };
      await home.prompt(prompt);
      const result = await waitFor(() => homeResults.get(prompt), `Home result: ${prompt}`);
      await waitFor(() => home.snapshot().configurationBlocker === null || undefined, `Home settled: ${prompt}`);
      return result;
    };
    await homeSays("Delegate settled-worker", "delegate", { taskId: "settled-worker", title: "Settled worker", intent: "Report at once", target: f.cwd });
    await waitFor(async () => (await homeOwnerOf(f.registry).taskResult("settled-worker").catch(() => undefined) as { wake?: { state?: string } } | undefined)?.wake?.state === "acknowledged" || undefined, "result wake acknowledged");
    await waitFor(() => home.snapshot().configurationBlocker === null || undefined, "Home settled after the result");
    const workerSessionId = (await homeOwnerOf(f.registry).taskStatus("settled-worker")).sessionId!;

    const REASONING = { provider: f.model.provider, id: TASK_REASONING_MODEL_ID };
    const applied = await homeSays("Switch settled-worker to reasoning", "settings", { action: "change", taskId: "settled-worker", reason: "Harder step on resume",
      changes: [{ key: "model.ref[role=chat]", layer: "session", op: "set", value: REASONING }, { key: "model.thinking[role=chat]", layer: "session", op: "set", value: "low" }] });
    expect(applied.details).toMatchObject({ status: "applied", review: { requiresTap: false } });
    expect(home.snapshot().extensionPresentation.pendingInteractions).toEqual([]);
    const worker = await f.registry.acquire(workerSessionId);
    expect(worker.snapshot()).toMatchObject({ model: REASONING, thinkingLevel: "low" });
    expect((await f.settingsChanges.history({ key: "model.thinking[role=chat]" })).entries.map(entry => entry.status)).not.toContain("failed");
    transcript.push({ case: "routine worker change without a client fence", steps: [{ applied: applied.details }] });
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
      refusals.push(String((await refused.catch((error: Error) => error)).message));
    }
    expect((await f.settingsChanges.history({ key: "run.retry.maxRetries" })).entries).toEqual([]);
    const snapshot = slot.snapshot();
    const fence = { runtimeGeneration: snapshot.runtimeGeneration, model: snapshot.model, revision: snapshot.revision };
    // A context window applies at the revision it read: a fence without one is refused before the dry run too.
    const contextWindow = [{ key: "model.contextWindow", layer: "session", op: "set", value: 100_000, qualifiers: { model: `${f.model.provider}/${f.model.id}` } }];
    await expect(f.service.invoke(phone(), "settings.change", { commandId: commandId(), target, fence: { runtimeGeneration: fence.runtimeGeneration, model: fence.model }, changes: contextWindow, dryRun: true }))
      .rejects.toMatchObject({ code: "invalid_request", message: expect.stringMatching(/revision/) });
    // Active tools never needed a fence (the iPhone sends none), so they are still admitted without one.
    await expect(f.service.invoke(phone(), "settings.change", { commandId: commandId(), target, dryRun: true,
      changes: [{ key: "tools.active", layer: "session", op: "set", value: ["read"] }] })).resolves.toMatchObject({ dryRun: true, status: "review", review: { requiresTap: true } });
    // With the fence it read, the same dry run and change pass.
    await expect(f.service.invoke(phone(), "settings.change", { commandId: commandId(), target, fence, changes, dryRun: true })).resolves.toMatchObject({ dryRun: true, status: "applied" });
    await expect(f.service.invoke(phone(), "settings.change", { commandId: commandId(), target, fence, changes })).resolves.toMatchObject({ status: "applied" });
    transcript.push({ case: "fence-less Chat change refused at submission", steps: [{ refusals }] });
  }, 60_000);
});
