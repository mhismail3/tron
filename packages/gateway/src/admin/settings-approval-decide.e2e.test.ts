import { mkdir, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fauxAssistantMessage, fauxToolCall, type AssistantMessage, type TranscriptContext } from "@earendil-works/pi-ai";
import { afterAll, afterEach, describe, expect, it } from "vitest";
import { waitFor } from "../../test-support/wait-for.js";
import { settingsDependencies, setHomeMemoryModels } from "../../test-support/settings-dependencies.js";
import { disposeFixtures, fixture as homeTaskFixture, reportCall, TASK_REASONING_MODEL_ID } from "../../test-support/home-task-fixture.js";
import { CommandReceiptStore } from "../transport/command-receipts.js";
import { UploadStore } from "../machine/upload-store.js";
import { DEFAULT_MAX_UPLOAD_BYTES } from "../config.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "../transport/gateway-service.js";

/**
 * Settings decisions and submissions at the Gateway RPC boundary (#1642), with
 * real Home, worker and chat runtimes on a faux model. The maintainer decides
 * from the Global Changes sheet, which never opened the requester's chat, so a
 * decision has no client fence: the approval's digest-bound diff is its fence.
 * What a change refuses for a missing fence, its dry run refuses too, before
 * the maintainer is ever asked. Retained at `test-results/settings-approval-decide.json`.
 */
const ARTIFACT = join(dirname(new URL(import.meta.url).pathname), "../../test-results/settings-approval-decide.json");
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
const commandId = () => `approval-decide-${String(++command).padStart(4, "0")}`;
const textOf = (message: { content: unknown }) => typeof message.content === "string" ? message.content
  : (message.content as Array<{ text?: string }>).map(part => part.text ?? "").join("");

async function gateway() {
  const f = await homeTaskFixture();
  const { settingsModel, settingsChanges } = settingsDependencies({ agentDir: f.agentDir, tronHome: f.tronHome, trust: f.trust, modelRuntime: f.gateway,
    sessions: f.registry, home: () => f.registry.homeOwner(), registry: f.registry });
  await setHomeMemoryModels(f.registry, [{ provider: f.model.provider, id: f.model.id }]);
  const service = new GatewayService({
    config: { machineId: "machine", machineGroupID: "group", machineName: "Mac", tronHome: f.tronHome, agentDir: f.agentDir },
    modelRuntime: f.gateway, trust: f.trust, settingsModel, settingsChanges, sessions: f.registry, home: f.registry.homeOwner(),
    receipts: new CommandReceiptStore(f.tronHome), uploads: new UploadStore(f.tronHome, DEFAULT_MAX_UPLOAD_BYTES),
    notifications: { enqueue: async () => "queued" }, broadcast: () => {},
    globalProviderResources: { withStableSnapshot: async (operation: () => Promise<unknown>) => operation(), requestReload: () => {} },
  } as unknown as GatewayServiceDependencies);
  return { ...f, service, settingsChanges };
}

describe("settings approval decisions", () => {
  it("the maintainer approves Home's change to a settled worker's Chat layer without having opened that worker", async () => {
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
    await waitFor(async () => (await f.registry.homeOwner().taskResult("settled-worker").catch(() => undefined) as { wake?: { state?: string } } | undefined)?.wake?.state === "acknowledged" || undefined, "result wake acknowledged");
    await waitFor(() => home.snapshot().configurationBlocker === null || undefined, "Home settled after the result");
    const workerSessionId = (await f.registry.homeOwner().taskStatus("settled-worker")).sessionId!;

    // The maintainer raised thinking's floor, so Home's model and thinking change waits for his tap.
    await f.service.invoke(phone(), "settings.change", { commandId: commandId(), target: { kind: "mac" },
      changes: [{ key: "permissions.floor", layer: "mac", op: "set", value: "approve", qualifiers: { key: "model.thinking[role=chat]" } }] });
    const REASONING = { provider: f.model.provider, id: TASK_REASONING_MODEL_ID };
    const pending = await homeSays("Switch settled-worker to reasoning", "settings", { action: "change", taskId: "settled-worker", reason: "Harder step on resume",
      changes: [{ key: "model.ref[role=chat]", layer: "chat", op: "set", value: REASONING }, { key: "model.thinking[role=chat]", layer: "chat", op: "set", value: "low" }] });
    expect(pending.details).toMatchObject({ status: "pending", tier: "approve" });

    // Approved from the Global Changes sheet: the iPhone never opened the worker, so it sends no fence.
    const [request] = (await f.service.invoke(phone(), "settings.approvals", {}) as unknown as { requests: Array<{ requestId: string; digest: string }> }).requests;
    const approved = await f.service.invoke(phone(), "settings.decide", { commandId: commandId(), requestId: request!.requestId, digest: request!.digest, approved: true }) as unknown as Record<string, unknown>;
    expect(approved).toMatchObject({ status: "approved", changes: expect.arrayContaining([expect.objectContaining({ key: "model.thinking[role=chat]", status: "approved", after: "low" })]) });
    const worker = await f.registry.acquire(workerSessionId);
    expect(worker.snapshot()).toMatchObject({ model: REASONING, thinkingLevel: "low" });
    expect((await f.settingsChanges.history({ key: "model.thinking[role=chat]" })).entries.map(entry => entry.status)).not.toContain("failed");
    transcript.push({ case: "decide without a client fence", steps: [{ pending: pending.details, approved }] });
  }, 90_000);

  it("a Chat-layer change without the fence it read is refused at submission, dry run included", async () => {
    const f = await gateway();
    const slot = await f.registry.create(f.cwd);
    await slot.setModel(f.model.provider, f.model.id);
    const target = { kind: "session", sessionId: slot.id };
    const changes = [{ key: "run.retry.maxRetries", layer: "chat", op: "set", value: 7 }];
    const refusals: string[] = [];
    for (const dryRun of [true, false]) {
      const refused = f.service.invoke(phone(), "settings.change", { commandId: commandId(), target, changes, ...(dryRun ? { dryRun } : {}) });
      await expect(refused).rejects.toMatchObject({ code: "invalid_request", message: expect.stringMatching(/fence/) });
      refusals.push(String((await refused.catch((error: Error) => error)).message));
    }
    expect((await f.settingsChanges.history({ key: "run.retry.maxRetries" })).entries).toEqual([]);
    // With the fence it read, the same dry run and change pass.
    const snapshot = slot.snapshot();
    const fence = { runtimeGeneration: snapshot.runtimeGeneration, model: snapshot.model, revision: snapshot.revision };
    await expect(f.service.invoke(phone(), "settings.change", { commandId: commandId(), target, fence, changes, dryRun: true })).resolves.toMatchObject({ dryRun: true, status: "applied" });
    await expect(f.service.invoke(phone(), "settings.change", { commandId: commandId(), target, fence, changes })).resolves.toMatchObject({ status: "applied" });
    transcript.push({ case: "fence-less Chat change refused at submission", steps: [{ refusals }] });
  }, 60_000);
});
