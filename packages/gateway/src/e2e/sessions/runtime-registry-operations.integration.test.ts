import { createTestRegistry, displayStoreOf, displayOwnerOf } from "../../../test-support/gateway-registry.js";
import type { RunPersistence } from "../../kernel/run/run-persistence.js";
import { performance as nodePerformance } from "node:perf_hooks";
import { sealBrowserToolReference } from "../../display/browser-tool-reference.js";
import * as fsPromises from "node:fs/promises";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { mkdir, readFile, readdir, rm, truncate, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { ModelRuntime, SessionManager } from "@earendil-works/pi-coding-agent";
import { contentText, fauxAssistantMessage, fauxProvider, fauxToolCall, type AssistantMessage, type FauxResponseFactory, type FauxResponseStep, type ImageContent, type TextContent, type TranscriptContext } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it, onTestFinished, vi } from "vitest";
import { TrustService } from "../../kernel/resources/trust-service.js";
import type { NotificationService } from "../../notifications/notification-service.js";
import type { SessionSummaryUpdate } from "../../protocol/types.js";
import { stage } from "../../util/request-span.js";
import { INVOCATION_RECEIPT_TYPE } from "../../kernel/receipts/invocation-receipts.js";
import {
  RuntimeRegistry,
} from "../../kernel/session/runtime-registry.js";
import { RuntimeSlot } from "../../kernel/run/runtime-slot.js";
import { invocationReceipts } from "../../kernel/receipts/invocation-receipts.js";
import { RunMarkerCompletionConflictError, type RunMarkerStore } from "../../kernel/run/run-markers.js";
import { toolSegmentId } from "../../kernel/projection/projection.js";
import { imageDimensions } from "../../../test-fixtures/pi-sdk/computer-use-image.js";
import { syntheticOversizedJpeg, syntheticPng } from "../../../test-fixtures/synthetic-image.js";
import { awaitsWithin, waitFor } from "../../../test-support/wait-for.js";
import { createColdRegistryFixture, initializeRegistry, temporaryRoot } from "../../../test-support/runtime-registry-fixture.js";
import { withoutTurnFrame } from "../../../test-support/turn-frame.js";
async function collectStream(stream: NodeJS.ReadableStream): Promise<Buffer> {
  const chunks: Buffer[] = [];
  for await (const value of stream) chunks.push(Buffer.isBuffer(value) ? value : Buffer.from(value));
  return Buffer.concat(chunks);
}

function subscribeAudience(registry: RuntimeRegistry, sessionId: string): void {
  registry.subscribe("test-audience", sessionId);
}

const PROVIDER_INLINE_IMAGE_BASE64_LIMIT = 5 * 1_048_576;
const OVERSIZED_PHOTO_BYTES = 6 * 1_048_576;

function providerReply(context: TranscriptContext, text: string): AssistantMessage {
  const oversized = context.messages.some(message => Array.isArray(message.content)
    && message.content.some(part => part.type === "image" && part.data.length > PROVIDER_INLINE_IMAGE_BASE64_LIMIT));
  return oversized
    ? fauxAssistantMessage("provider rejected the request", { stopReason: "error", errorMessage: "image exceeds the provider inline limit" })
    : fauxAssistantMessage(text);
}

function oversizedPhoto(): ImageContent {
  return { type: "image", mimeType: "image/jpeg", data: syntheticOversizedJpeg(OVERSIZED_PHOTO_BYTES).toString("base64") };
}

function smallPhoto(): ImageContent {
  return { type: "image", mimeType: "image/png", data: syntheticPng(64, 48).toString("base64") };
}

function holdFirstReply(text: string): { response: FauxResponseFactory; started: Promise<void>; release: () => void } {
  let release!: () => void;
  let started!: () => void;
  const barrier = new Promise<void>((resolve) => { release = resolve; });
  const startedSignal = new Promise<void>((resolve) => { started = resolve; });
  return {
    started: startedSignal,
    release: () => release(),
    response: async (context) => {
      started();
      await barrier;
      return providerReply(context, text);
    },
  };
}

async function queuedImageSession(registries: RuntimeRegistry[], root: string, provider: string, responses: FauxResponseStep[]): Promise<RuntimeSlot> {
  const agentDir = join(root, "agent");
  const cwd = join(root, "workspace");
  await Promise.all([mkdir(agentDir), mkdir(cwd)]);
  const trust = new TrustService(agentDir);
  await trust.set(cwd, true);
  const faux = fauxProvider({ provider, tokensPerSecond: 10_000 });
  faux.setResponses(responses);
  const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
  runtime.registerNativeProvider(faux.provider);
  const registry = await createTestRegistry({ agentDir,
    tronHome: join(root, "tron"),
    idleRuntimeMs: 60_000,
    modelRuntimeFactory: async () => runtime,
    trust,
    broadcast: () => {},
    sessionSummaryChanged: () => {},
    sessionListChanged: () => {},
  });
  registries.push(registry);
  await initializeRegistry(registry);
  const slot = await registry.create(cwd);
  const model = faux.getModel();
  await slot.setModel(model.provider, model.id);
  return slot;
}

function canonicalUserContents(slot: RuntimeSlot): Array<Array<TextContent | ImageContent>> {
  return slot.canonicalSessionEntries().flatMap(entry => entry.type === "message" && entry.message.role === "user"
    && Array.isArray(entry.message.content) ? [entry.message.content as Array<TextContent | ImageContent>] : []);
}

describe("RuntimeRegistry with the pinned agent runtime", { concurrent: false }, () => {
  const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
  const registries: RuntimeRegistry[] = [];
  const syntheticTranscriptSizes = new Map<string, number>();

  const coldFixture = createColdRegistryFixture.bind(undefined, registries);

  afterEach(async () => {
    try {
      const transcripts = [...syntheticTranscriptSizes];
      await Promise.all(transcripts.map(([path, size]) => truncate(path, size)));
      for (const [path, size] of transcripts) {
        expect((await fsPromises.stat(path)).size).toBe(size);
      }
      syntheticTranscriptSizes.clear();
    } finally {
      await Promise.all(registries.splice(0).map((registry) => registry.dispose()));
      vi.restoreAllMocks();
      if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
      else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
    }
  });
  it("applies the per-model prompt image profile once before canonical history", async () => {
    const root = await temporaryRoot("tron-prompt-image-bound-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const faux = fauxProvider({ provider: "tron-prompt-image-bound", tokensPerSecond: 10_000 });
    faux.setResponses([fauxAssistantMessage("complete")]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const registry = await createTestRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust,
      modelRuntimeFactory: async () => runtime,
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    model.inputLimits = { images: { resize: { maxWidth: 1_000, maxHeight: 1_000 } } };
    await slot.setModel(model.provider, model.id);

    const screenshot: ImageContent = { type: "image", mimeType: "image/png", data: syntheticPng(1320, 2868).toString("base64") };
    const originalData = screenshot.data;
    await slot.prompt("Look at this screenshot", [screenshot]);
    expect(screenshot.data).toBe(originalData);
    await waitFor(() => !slot.isBusy, "the slot to go idle");

    const entries = (await readFile(slot.sessionFile!, "utf8"))
      .trimEnd().split("\n").map(line => JSON.parse(line) as any);
    const recorded = entries.find(entry => entry.type === "message" && entry.message?.role === "user")
      ?.message.content.find((part: any) => part.type === "image") as ImageContent | undefined;
    expect(recorded).toBeDefined();
    expect(recorded!.data).not.toBe(screenshot.data);
    const dimensions = imageDimensions(recorded!);
    expect(Math.max(dimensions.width, dimensions.height)).toBe(1_000);
  });

  it("normalizes photos queued as steers and follow-ups before canonical history so later turns still run", async () => {
    const root = await temporaryRoot("tron-queued-image-bound-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    let releaseInitial!: () => void;
    let releaseSteering!: () => void;
    let initialStarted!: () => void;
    let steeringStarted!: () => void;
    let followUpStarted!: () => void;
    const initialBarrier = new Promise<void>((resolve) => { releaseInitial = resolve; });
    const steeringBarrier = new Promise<void>((resolve) => { releaseSteering = resolve; });
    const initialStart = new Promise<void>((resolve) => { initialStarted = resolve; });
    const steeringStart = new Promise<void>((resolve) => { steeringStarted = resolve; });
    const followUpStart = new Promise<void>((resolve) => { followUpStarted = resolve; });
    onTestFinished(() => {
      releaseInitial();
      releaseSteering();
    });
    const faux = fauxProvider({ provider: "tron-queued-image-bound", tokensPerSecond: 10_000 });
    faux.setResponses([
      async (context) => {
        initialStarted();
        await initialBarrier;
        return providerReply(context, "initial complete");
      },
      async (context) => {
        steeringStarted();
        await steeringBarrier;
        return providerReply(context, "steering complete");
      },
      (context) => {
        followUpStarted();
        return providerReply(context, "follow-up complete");
      },
      (context) => providerReply(context, "recovered complete"),
    ]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime,
      trust,
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);

    const canonicalAssistantText = (text: string) => slot.canonicalSessionEntries().some(entry => entry.type === "message"
      && entry.message.role === "assistant" && contentText(entry.message.content).includes(text));
    const canonicalUserPhotos = (): ImageContent[] => slot.canonicalSessionEntries().flatMap(entry => entry.type === "message"
      && entry.message.role === "user" && Array.isArray(entry.message.content)
      ? (entry.message.content as ImageContent[]).filter(part => part.type === "image") : []);
    const expectWithinProviderLimit = (photos: readonly ImageContent[]) => {
      for (const photo of photos) expect(photo.data.length).toBeLessThanOrEqual(PROVIDER_INLINE_IMAGE_BASE64_LIMIT);
    };
    const steeredPhoto = oversizedPhoto();
    const followUpPhoto = oversizedPhoto();
    expect(steeredPhoto.data.length).toBeGreaterThan(PROVIDER_INLINE_IMAGE_BASE64_LIMIT);

    const initial = slot.prompt("initial");
    await initialStart;
    await slot.prompt("steer with photo", [steeredPhoto], "steer");
    releaseInitial();
    await steeringStart;
    expect(canonicalUserPhotos()).toHaveLength(1);
    expectWithinProviderLimit(canonicalUserPhotos());
    await slot.prompt("follow-up with photo", [followUpPhoto], "followUp");
    releaseSteering();
    await followUpStart;
    expectWithinProviderLimit(canonicalUserPhotos());
    await waitFor(() => !slot.isBusy, "the steered and queued follow-up turns to settle");
    await initial;

    expect(canonicalAssistantText("steering complete")).toBe(true);
    expect(canonicalAssistantText("follow-up complete")).toBe(true);
    expect(canonicalUserPhotos()).toHaveLength(2);
    expect(slot.snapshot().queuedItems).toEqual([]);

    await slot.prompt("after the queued photos");
    await waitFor(() => !slot.isBusy, "the recovery turn to settle");
    expect(canonicalAssistantText("recovered complete")).toBe(true);
  });

  it("delivers image-only and text-with-image steers and follow-ups from the queue, bounding large photos and keeping small ones byte-identical", async () => {
    const root = await temporaryRoot("tron-queued-image-shapes-");
    const hold = holdFirstReply("initial complete");
    const slot = await queuedImageSession(registries, root, "tron-queued-image-shapes", [
      hold.response,
      ...Array.from({ length: 4 }, (_, index) => (context: TranscriptContext) => providerReply(context, `reply ${index + 1}`)),
    ]);
    const initial = slot.prompt("initial");
    await hold.started;
    const smallSteer = smallPhoto();
    const smallFollowUp = smallPhoto();
    await slot.prompt("", [oversizedPhoto()], "steer");
    await slot.prompt("small steer", [smallSteer], "steer");
    await slot.prompt("", [oversizedPhoto()], "followUp");
    await slot.prompt("small follow-up", [smallFollowUp], "followUp");
    expect(slot.snapshot().queuedItems.map(item => [item.behavior, item.text])).toEqual([
      ["steer", ""], ["steer", "small steer"], ["followUp", ""], ["followUp", "small follow-up"],
    ]);
    hold.release();
    await waitFor(() => !slot.isBusy, "the queued inputs to deliver and the run to settle");
    await initial;

    const [, imageOnlySteer, textSteer, imageOnlyFollowUp, textFollowUp] = canonicalUserContents(slot);
    expect(canonicalUserContents(slot)).toHaveLength(5);
    for (const message of [imageOnlySteer!, imageOnlyFollowUp!]) {
      expect(message[0]).toEqual({ type: "text", text: expect.stringMatching(/^\n\n\[Image: /u) });
      const photos = message.filter((part): part is ImageContent => part.type === "image");
      expect(photos).toHaveLength(1);
      expect(photos[0]!.data.length).toBeLessThanOrEqual(PROVIDER_INLINE_IMAGE_BASE64_LIMIT);
    }
    expect(textSteer).toEqual([{ type: "text", text: "small steer" }, { type: "image", data: smallSteer.data, mimeType: "image/png" }]);
    expect(textFollowUp).toEqual([{ type: "text", text: "small follow-up" }, { type: "image", data: smallFollowUp.data, mimeType: "image/png" }]);
    expect(slot.snapshot().queuedItems).toEqual([]);
  });

  it("keeps a queued photo's normalization hint to one copy through a queue rebuild, in requested order", async () => {
    const root = await temporaryRoot("tron-queued-image-rebuild-");
    const hold = holdFirstReply("initial complete");
    const slot = await queuedImageSession(registries, root, "tron-queued-image-rebuild", [
      hold.response,
      (context) => providerReply(context, "photo reply"),
      (context) => providerReply(context, "text reply"),
    ]);
    const initial = slot.prompt("initial");
    await hold.started;
    await slot.prompt("steer photo", [oversizedPhoto()], "steer");
    await slot.prompt("steer text", [], "steer");
    const queued = slot.snapshot();
    let replaced: Awaited<ReturnType<typeof slot.replaceQueue>>;
    try {
      replaced = await slot.replaceQueue(queued.queueRevision, queued.queuedItems.map(({ id, behavior, text }) => ({ id, behavior, text })));
    } finally {
      hold.release();
    }
    expect(replaced.items.map(item => item.text)).toEqual(["steer photo", "steer text"]);
    await waitFor(() => !slot.isBusy, "the rebuilt steers to deliver and the run to settle");
    await initial;

    const userTexts = canonicalUserContents(slot).map(message => message[0]?.type === "text" ? message[0].text : undefined);
    expect(userTexts).toEqual(["initial", expect.stringMatching(/^steer photo\n\n\[Image[^\n]*\]$/u), "steer text"]);
    const photoText = canonicalUserContents(slot)[1]!.flatMap(part => part.type === "text" ? [part.text] : []).join("\n");
    expect(photoText.match(/\[Image/gu)).toHaveLength(1);
    expect(canonicalUserContents(slot)[2]).toEqual([{ type: "text", text: "steer text" }]);
    expect(slot.snapshot().queuedItems).toEqual([]);
  });

  it("leaves no queued ghost when a photo cannot be normalized, and the next turn still runs", async () => {
    const root = await temporaryRoot("tron-queued-image-failure-");
    const hold = holdFirstReply("initial complete");
    const slot = await queuedImageSession(registries, root, "tron-queued-image-failure", [
      hold.response,
      (context) => providerReply(context, "steer reply"),
      (context) => providerReply(context, "after failure complete"),
    ]);
    const initial = slot.prompt("initial");
    await hold.started;
    const undecodable: ImageContent = { type: "image", mimeType: "image/png", data: Buffer.from("not a png").toString("base64") };
    await slot.prompt("steer with undecodable photo", [undecodable], "steer");
    expect(slot.snapshot().queuedItems.map(item => item.text)).toEqual(["steer with undecodable photo"]);
    hold.release();
    await waitFor(() => !slot.isBusy, "the steer with the omitted photo to settle");
    await initial;

    const delivered = canonicalUserContents(slot).find(message => message.some(part => part.type === "text"
      && /^steer with undecodable photo\n\n\[Image omitted[^\n]*\]$/u.test(part.text)));
    expect(delivered).toBeDefined();
    expect(delivered!.some(part => part.type === "image")).toBe(false);
    expect(delivered!.some(part => part.type === "text" && part.text.includes("[Image omitted"))).toBe(true);
    expect(slot.snapshot().queuedItems).toEqual([]);

    await slot.prompt("after failure");
    await waitFor(() => !slot.isBusy, "the next turn to settle");
    expect(slot.canonicalSessionEntries().some(entry => entry.type === "message" && entry.message.role === "assistant"
      && contentText(entry.message.content).includes("after failure complete"))).toBe(true);
  });

  it("admits multiline plain prompts without duplicating their body into invocation receipts", async () => {
    const root = await temporaryRoot("tron-multiline-prompt-receipt-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const faux = fauxProvider({ provider: "tron-multiline-prompt", tokensPerSecond: 10_000 });
    faux.setResponses([fauxAssistantMessage("complete")]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const registry = await createTestRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust,
      modelRuntimeFactory: async () => runtime,
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);

    const prompt = "first line\nsecond line";
    await expect(slot.prompt(prompt)).resolves.toEqual({ operationId: expect.any(String) });
    await waitFor(() => !slot.isBusy, "the slot to go idle");

    const entries = (await readFile(slot.sessionFile!, "utf8"))
      .trimEnd().split("\n").map(line => JSON.parse(line) as any);
    const startReceipt = entries.find(entry => entry.type === "custom"
      && entry.customType === INVOCATION_RECEIPT_TYPE
      && entry.data?.receiptKind === "start");
    expect(startReceipt?.data).toMatchObject({ source: "plain", lifecycle: "staged" });
    expect(startReceipt?.data).not.toHaveProperty("arguments");
    expect(entries.some(entry => entry.type === "message" && entry.message?.role === "user"
      && entry.message.content?.some((part: any) => part.type === "text" && part.text === prompt))).toBe(true);
  });

  it("keeps the Gateway alive when extension timers emit oversized or JSON-dense widgets", async () => {
    const root = await temporaryRoot("tron-rpc-oversized-widget-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await mkdir(extensionDir, { recursive: true });
    await writeFile(join(extensionDir, "oversized-widget.ts"), `export default function (pi) {
      pi.on("session_start", (_event, ctx) => {
        setImmediate(() => {
          ctx.ui.setWidget("async-status", ["PI_SUBAGENT_ASYNC_JSON:" + "x".repeat(1_024)]);
          ctx.ui.setWidget("async-status", ["PI_SUBAGENT_ASYNC_JSON:" + '\"x\",'.repeat(115)]);
          ctx.ui.setStatus("oversized-widget-callback", "completed");
        });
      });
    }\n`);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const registry = await createTestRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust,
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    try {
      await waitFor(() => slot.snapshot().extensionPresentation.semanticState.statuses["oversized-widget-callback"] === "completed", "the oversized widget callback to complete");
    } catch (cause) {
      throw new Error(`Oversized-widget callback did not complete: ${JSON.stringify(slot.snapshot().extensionPresentation)}`, { cause });
    }
    expect(slot.snapshot().extensionPresentation.semanticState.widgets).toEqual([]);
  });

  it("projects retained component widgets through the RPC-bound host without enabling TUI mode", async () => {
    const root = await temporaryRoot("tron-rpc-factory-dormant-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await mkdir(extensionDir, { recursive: true });
    await writeFile(join(extensionDir, "rpc-factory.ts"), `export default function (pi) {
      let invoked = false;
      pi.on("session_start", async (_event, ctx) => {
        ctx.ui.setStatus("context-has-ui", ctx.hasUI ? "true" : "false");
        ctx.ui.setStatus("context-mode", ctx.mode);
        ctx.ui.setWidget("factory", () => ({
          render: () => ["must mount"], invalidate: () => {}
        }));
        ctx.ui.setWidget("custom:broken", () => { throw new Error("factory failed"); });
        try {
          await ctx.ui.custom(() => {
            invoked = true;
            return { render: () => ["must not invoke"], invalidate: () => {} };
          });
        } catch {
          ctx.ui.setStatus("custom-deferred", invoked ? "invoked" : "not-invoked");
        }
      });
    }\n`);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const registry = await createTestRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust,
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    await waitFor(() => slot.snapshot().extensionPresentation.surfaces.some((surface) => surface.frame.plainText.includes("must mount")), "the mounted extension component frame");
    const snapshot = slot.snapshot();
    expect(snapshot.extensionPresentation.semanticState.statuses).toMatchObject({
      "context-has-ui": "true", "context-mode": "rpc", "custom-deferred": "not-invoked",
    });
    expect(snapshot.extensionPresentation.semanticState.widgets).toEqual([]);
    expect(snapshot.extensionPresentation.surfaces).toHaveLength(2);
    expect(snapshot.extensionPresentation.surfaces).toEqual(expect.arrayContaining([
      expect.objectContaining({ id: "widget:ZmFjdG9yeQ", kind: "widget", placement: "aboveEditor", lifecycle: "retained", focused: false, inputMode: "none" }),
      expect.objectContaining({ id: "widget:Y3VzdG9tOmJyb2tlbg", kind: "widget", lifecycle: "retained", focused: false, inputMode: "none",
        frame: expect.objectContaining({ plainText: "[Extension component unavailable: factory failed]" }) }),
    ]));
    expect(snapshot.extensionPresentation.diagnostics).toContainEqual({ code: "component.render-invalid", message: "Blocking component UI is deferred in RPC mode" });
  });

  it("keeps ask-style semantic selection on the RPC interaction path", async () => {
    const root = await temporaryRoot("tron-rpc-semantic-ask-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await mkdir(extensionDir, { recursive: true });
    await writeFile(join(extensionDir, "semantic-ask.ts"), `export default function (pi) {
      pi.registerCommand("semantic-ask", { handler: async (_args, ctx) => {
        const answer = await ctx.ui.select("Choose a path", ["Keep", "Change"]);
        ctx.ui.setStatus("answer", answer ?? "Cancelled");
      }});
    }\n`);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const summaries: SessionSummaryUpdate[] = [];
    const userInputRequired = vi.fn(async () => {});
    const registry = await createTestRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust,
      broadcast: () => {}, sessionSummaryChanged: (summary) => summaries.push(summary), sessionListChanged: () => {},
      machineId: "machine-input-test",
      notifications: { userInputRequired, markSessionInboxRead: vi.fn(async () => {}) } as unknown as NotificationService,
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const command = slot.prompt("/semantic-ask");
    await waitFor(() => slot.snapshot().extensionPresentation.pendingInteractions.length === 1, "the pending interaction");
    const pending = slot.snapshot().extensionPresentation.pendingInteractions[0]!;
    expect(pending.method).toBe("select");
    expect(pending.options).toEqual(["Keep", "Change"]);
    expect(userInputRequired).toHaveBeenCalledWith({
      sessionId: slot.id,
      interactionId: pending.id,
      machineId: "machine-input-test",
      observed: false,
    });
    expect(summaries.at(-1)?.waitingForUser).toBe(true);
    expect((await registry.list()).find((session) => session.id === slot.id)?.waitingForUser).toBe(true);
    const internal = slot as unknown as { respondToInteraction: (id: string, epoch: string, revision: number, value: unknown, cancelled: boolean) => void };
    internal.respondToInteraction(pending.id, pending.hostEpoch, pending.presentationRevision, "Keep", false);
    expect(summaries.at(-1)?.waitingForUser).toBe(false);
    expect((await registry.list()).find((session) => session.id === slot.id)?.waitingForUser).toBe(false);
    await command;
    expect(slot.snapshot().extensionPresentation.semanticState.statuses.answer).toBe("Keep");

    registry.subscribe("visible-phone", slot.id);
    registry.setPresentationVisibility({
      clientId: "visible-phone",
      sessionId: slot.id,
      subscriptionToken: "visible-subscription",
      revision: 1,
      visible: true,
    });
    const visibleCommand = slot.prompt("/semantic-ask");
    await waitFor(() => slot.snapshot().extensionPresentation.pendingInteractions.length === 1, "the pending interaction");
    const visiblePending = slot.snapshot().extensionPresentation.pendingInteractions[0]!;
    expect(userInputRequired).toHaveBeenLastCalledWith({
      sessionId: slot.id,
      interactionId: visiblePending.id,
      machineId: "machine-input-test",
      observed: true,
    });
    internal.respondToInteraction(
      visiblePending.id,
      visiblePending.hostEpoch,
      visiblePending.presentationRevision,
      "Change",
      false,
    );
    await visibleCommand;
  });

  it("presents multi-line select options on one line and answers with the extension's own option", async () => {
    const root = await temporaryRoot("tron-rpc-semantic-multiline-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await mkdir(extensionDir, { recursive: true });
    await writeFile(join(extensionDir, "sectioned-menu.ts"), `export default function (pi) {
      pi.registerCommand("sectioned-menu", { handler: async (_args, ctx) => {
        const answer = await ctx.ui.select("Claude", [
          "Accounts: Custody: local\\nmain: main (oauth, enabled, local)\\n- Enrollment: not enrolled",
          "Routing: Routing: main-first",
          "Cache: 1-hour cache: enabled\\n\\n- Persisted: pool.json",
        ]);
        ctx.ui.setStatus("answer", JSON.stringify(answer ?? null));
      }});
    }\n`);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const registry = await createTestRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust,
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const command = slot.prompt("/sectioned-menu");
    await waitFor(() => slot.snapshot().extensionPresentation.pendingInteractions.length === 1, "the pending interaction");
    const pending = slot.snapshot().extensionPresentation.pendingInteractions[0]!;
    expect(pending.options).toEqual([
      "Accounts: Custody: local · main: main (oauth, enabled, local) · - Enrollment: not enrolled",
      "Routing: Routing: main-first",
      "Cache: 1-hour cache: enabled · - Persisted: pool.json",
    ]);
    const internal = slot as unknown as { respondToInteraction: (id: string, epoch: string, revision: number, value: unknown, cancelled: boolean) => void };
    internal.respondToInteraction(pending.id, pending.hostEpoch, pending.presentationRevision, pending.options![0], false);
    await command;
    expect(JSON.parse(slot.snapshot().extensionPresentation.semanticState.statuses.answer!))
      .toBe("Accounts: Custody: local\nmain: main (oauth, enabled, local)\n- Enrollment: not enrolled");
  });

  it("rotates and retires semantic epochs on direct, command, and trust reload paths", async () => {
    const root = await temporaryRoot("tron-semantic-epoch-reload-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await Promise.all([mkdir(agentDir), mkdir(extensionDir, { recursive: true })]);
    await writeFile(join(extensionDir, "reload.ts"), `export default function (pi) {
      pi.on("session_start", (_event, ctx) => ctx.ui.setStatus("epoch", "started"));
      pi.registerCommand("reload-host", { handler: async (_args, ctx) => ctx.reload() });
    }\n`);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const registry = await createTestRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust,
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const internal = slot as unknown as { ui: { context(): { confirm(title: string, message: string): Promise<boolean>; setStatus(key: string, text: string): void } } };
    const oldContext = internal.ui.context();
    const firstEpoch = slot.snapshot().extensionPresentation.hostEpoch;

    await slot.reload();
    const secondEpoch = slot.snapshot().extensionPresentation.hostEpoch;
    expect(secondEpoch).not.toBe(firstEpoch);
    expect(() => oldContext.setStatus("late", "old callback")).not.toThrow();
    expect(slot.snapshot().extensionPresentation.semanticState.statuses.late).toBeUndefined();

    const pending = internal.ui.context().confirm("Pending", "Retire me");
    const retiredPending = expect(pending).rejects.toMatchObject({ code: "cancelled" });
    await slot.prompt("/reload-host");
    await retiredPending;
    const thirdEpoch = slot.snapshot().extensionPresentation.hostEpoch;
    expect(thirdEpoch).not.toBe(secondEpoch);
    await registry.reloadProject(cwd, true);
    expect(slot.snapshot().extensionPresentation.hostEpoch).not.toBe(thirdEpoch);
  });

  it("orders context-edit settlement callbacks before terminal ownership and feeds the next provider request", async () => {
    const root = await temporaryRoot("tron-context-edit-settlement-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(join(cwd, ".pi", "extensions"), { recursive: true })]);
    await writeFile(join(cwd, ".pi", "extensions", "context-edit-boundary.ts"), `
export default function (pi) {
  pi.on("turn_end", (_event, ctx) => {
    const target = ctx.sessionManager.getBranch().find(entry => entry.type === "message" && entry.message.role === "user");
    return { entries: [
      { type: "context_edit", targetId: target.id, replacement: { content: "replacement from turn_end" } },
      { type: "custom", customType: "context-edit-order", data: { stage: "turn_end" } },
    ] };
  });
  pi.on("agent_before_settle", () => ({ entries: [
    { type: "custom", customType: "context-edit-order", data: { stage: "agent_before_settle" } },
  ] }));
  pi.on("agent_settled", () => {
    pi.appendEntry("context-edit-order", { stage: "agent_settled" });
  });
}
`);
    const faux = fauxProvider({ provider: "tron-context-edit-settlement", tokensPerSecond: 10_000 });
    const contexts: TranscriptContext[] = [];
    faux.setResponses([
      (context) => { contexts.push(context); return fauxAssistantMessage("first completed"); },
      (context) => { contexts.push(context); return fauxAssistantMessage("second completed"); },
    ]);
    const modelRuntimeFactory = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const registry = await createTestRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, modelRuntimeFactory, trust,
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    await slot.setModel(faux.getModel().provider, faux.getModel().id);
    await slot.prompt("original request");
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    const branch = (slot as unknown as { sessionManager: SessionManager }).sessionManager.getBranch();
    const order = branch.filter(entry => entry.type === "custom" && entry.customType === "context-edit-order")
      .map(entry => {
        if (entry.type !== "custom") throw new Error("Unexpected non-custom order entry");
        return (entry.data as { stage: string }).stage;
      });
    expect(order).toEqual(["turn_end", "agent_before_settle", "agent_settled"]);
    expect(branch.some(entry => entry.type === "context_edit" && entry.replacement.content === "replacement from turn_end")).toBe(true);
    await waitFor(() => registry.attentionProjection(slot.id).completionRevision === 1, "the first completion revision");
    expect(registry.attentionProjection(slot.id)).toMatchObject({ completionRevision: 1 });

    await slot.prompt("follow-up");
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    expect(contexts).toHaveLength(2);
    expect(withoutTurnFrame(contexts[1]!.messages).filter(message => message.role === "user").map(message =>
      message.role === "user" ? contentText(message.content) : "")).toEqual([
      "replacement from turn_end", "follow-up",
    ]);
    await waitFor(() => registry.attentionProjection(slot.id).completionRevision === 2, "the second completion revision");
    expect(registry.attentionProjection(slot.id)).toMatchObject({ completionRevision: 2 });
  });

  it("serializes chained extension continuation ownership through a transient attention failure", async () => {
    const root = await temporaryRoot("tron-settlement-overlap-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([
      mkdir(agentDir),
      mkdir(join(cwd, ".pi", "extensions"), { recursive: true }),
    ]);
    await writeFile(join(cwd, ".pi", "extensions", "continuation.ts"), `
let remaining = 3;
export default function (pi) {
  pi.on("agent_settled", () => {
    if (remaining === 0) return;
    const sequence = 4 - remaining;
    remaining -= 1;
    pi.sendMessage({ customType: "test-continuation", content: \`continue-\${sequence}\`, display: false }, { triggerTurn: true });
  });
}
`);

    const faux = fauxProvider({ provider: "tron-settlement-overlap", tokensPerSecond: 10_000 });
    const createModels = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    faux.setResponses([
      fauxAssistantMessage("first complete"),
      async () => {
        await new Promise((resolve) => setTimeout(resolve, 250));
        return fauxAssistantMessage("continuation one complete");
      },
      fauxAssistantMessage("continuation two complete"),
      async () => {
        await new Promise((resolve) => setTimeout(resolve, 250));
        return fauxAssistantMessage("continuation three complete");
      },
    ]);
    const snapshots: Array<{ phase: string; operation?: unknown }> = [];
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: createModels,
      trust,
      broadcast: (_sessionId, topic, payload) => {
        if (topic === "session.snapshot") snapshots.push(payload as { phase: string; operation?: unknown });
      },
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    expect(slot.sessionFile?.startsWith(join(agentDir, "sessions"))).toBe(true);
    subscribeAudience(registry, slot.id);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const internals = registry as unknown as {
      attention: { complete: (sessionId: string, completionId: string) => Promise<unknown> };
      markers: {
        reassertAssistantCompletion: (
          sessionId: string, operationId: string, completionId: string, completedAt: string,
        ) => Promise<void>;
      };
    };
    const attention = internals.attention;
    const completionStamps = vi.spyOn(internals.markers, "reassertAssistantCompletion");
    const originalComplete = attention.complete.bind(attention);
    const complete = vi.spyOn(attention, "complete")
      .mockRejectedValueOnce(new Error("injected overlapping attention failure"))
      .mockImplementation(originalComplete);
    await slot.prompt("start");

    await waitFor(() => faux.state.callCount === 4, "the fourth model call");
    expect(slot.snapshot()).toMatchObject({ phase: "running", operation: { kind: "prompt" } });
    const continuationSnapshotIndex = snapshots.length;
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(snapshots.slice(continuationSnapshotIndex).every((snapshot) => snapshot.phase === "running" && snapshot.operation)).toBe(true);
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    const settled = slot.snapshot();
    expect(settled).toMatchObject({ phase: "idle" });
    expect(settled.transcript.find((item) => item.kind === "customMessage")).toBeUndefined();
    expect(settled.transcript.some((item) =>
      item.role === "user"
        && item.semantic?.invocationId !== undefined
        && item.semantic.lifecycle === "completed")).toBe(true);
    expect(registry.attentionProjection(slot.id).completionRevision).toBe(4);
    const completionIds = complete.mock.calls.map(([, completionId]) => completionId);
    expect(completionIds).toHaveLength(5);
    expect(completionIds[0]).toBe(completionIds[1]);
    expect(new Set(completionIds.slice(1)).size).toBe(4);
    const stampedOperationIds = completionStamps.mock.calls.map(([, operationId]) => operationId);
    expect(stampedOperationIds).toHaveLength(4);
    expect(new Set(stampedOperationIds).size).toBe(4);
    expect(snapshots.some((snapshot) => snapshot.phase === "running" && snapshot.operation)).toBe(true);
  });

  it("does not retry permanent marker completion conflicts", async () => {
    const fixture = await coldFixture("permanent-marker-invariant");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const persistence = (slot as unknown as { runPersistence: RunPersistence }).runPersistence;
    const retry = persistence.retryDurableWrite.bind(persistence);
    const operation = vi.fn(async () => {
      throw new RunMarkerCompletionConflictError("injected permanent ownership conflict");
    });

    await expect(retry("marker:test", operation)).rejects.toThrow("injected permanent ownership conflict");
    expect(operation).toHaveBeenCalledOnce();
    expect(fixture.events.filter((event) => event.topic === "session.operationFailed")).toEqual([]);
  });

  it("recovers ordered continuation completions after the attention head repeatedly fails and restart", async () => {
    const root = await temporaryRoot("tron-settlement-crash-durable-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([
      mkdir(agentDir),
      mkdir(join(cwd, ".pi", "extensions"), { recursive: true }),
    ]);
    await writeFile(join(cwd, ".pi", "extensions", "continuation.ts"), `
let triggered = false;
export default function (pi) {
  pi.on("agent_settled", () => {
    if (triggered) return;
    triggered = true;
    pi.sendMessage({ customType: "test-continuation", content: "continue", display: false }, { triggerTurn: true });
  });
}
`);
    const faux = fauxProvider({ provider: "tron-settlement-crash-durable", tokensPerSecond: 10_000 });
    faux.setResponses([
      fauxAssistantMessage("completion A"),
      fauxAssistantMessage("completion B"),
    ]);
    const createModels = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const tronHome = join(root, "tron");
    const registry = await createTestRegistry({
      agentDir, tronHome, idleRuntimeMs: 60_000, modelRuntimeFactory: createModels, trust,
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const internals = registry as unknown as {
      attention: { complete: (sessionId: string, completionId: string) => Promise<unknown> };
      markers: {
        evidenceFor: (sessionId: string) => Promise<Array<{ assistantCompletionId?: string }>>;
        reassertAssistantCompletion: (
          sessionId: string, operationId: string, completionId: string, completedAt: string,
        ) => Promise<void>;
      };
    };
    vi.spyOn(internals.attention, "complete").mockRejectedValue(new Error("injected persistent attention failure"));
    const originalStamp = internals.markers.reassertAssistantCompletion.bind(internals.markers);
    let secondStampEntered!: () => void;
    let releaseSecondStamp!: () => void;
    const secondStampEntry = new Promise<void>((resolve) => { secondStampEntered = resolve; });
    const secondStampBarrier = new Promise<void>((resolve) => { releaseSecondStamp = resolve; });
    let stampCount = 0;
    vi.spyOn(internals.markers, "reassertAssistantCompletion").mockImplementation(async (...arguments_) => {
      stampCount += 1;
      if (stampCount === 2) {
        secondStampEntered();
        await secondStampBarrier;
      }
      await originalStamp(...arguments_);
    });

    await slot.prompt("start");
    await secondStampEntry;
    await waitFor(() => slot.snapshot().phase === "interrupted", "the interrupted phase");
    const blockedQueue = (slot as unknown as { runAttention: { completionOwnershipQueue: unknown[] } }).runAttention.completionOwnershipQueue;
    expect(blockedQueue).toHaveLength(1);
    let disposalSettled = false;
    const disposal = registry.dispose().finally(() => { disposalSettled = true; });
    await new Promise((resolve) => setTimeout(resolve, 25));
    expect(disposalSettled).toBe(false);
    releaseSecondStamp();
    await disposal;

    const durableCompletionIds = (await internals.markers.evidenceFor(slot.id))
      .map((marker) => marker.assistantCompletionId)
      .filter((id): id is string => id !== undefined);
    expect(durableCompletionIds).toHaveLength(2);
    expect(new Set(durableCompletionIds).size).toBe(2);
    const restarted = await createTestRegistry({
      agentDir, tronHome, idleRuntimeMs: 60_000, modelRuntimeFactory: createModels,
      trust: new TrustService(agentDir),
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(restarted);
    const restartedAttention = (restarted as unknown as {
      attention: { complete: (sessionId: string, completionId: string) => Promise<unknown> };
    }).attention;
    const recovered = vi.spyOn(restartedAttention, "complete");
    await initializeRegistry(restarted);
    await restarted.recoverCanonicalAttention();

    expect(recovered.mock.calls.map(([, completionId]) => completionId)).toEqual(durableCompletionIds);
    expect(restarted.attentionProjection(slot.id)).toMatchObject({ completionRevision: 2, isUnread: true });
  });

  it("measures real prompt snapshot burst without dropping ordered lifecycle frames", async () => {
    const root = await temporaryRoot("tron-snapshot-burst-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const sessionDirectory = join(agentDir, "sessions", "workspace");
    await mkdir(sessionDirectory, { recursive: true });
    await mkdir(cwd, { recursive: true });
    process.env.PI_CODING_AGENT_DIR = agentDir;
    const manager = SessionManager.create(cwd, sessionDirectory);
    for (let index = 0; index < 160; index += 1) {
      manager.appendMessage(fauxAssistantMessage(`history-${index} ${"x".repeat(3_600)}`));
    }
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    const faux = fauxProvider({ provider: "tron-snapshot-burst", tokensPerSecond: 10_000 });
    faux.setResponses([fauxAssistantMessage("prompt response")]);
    runtime.registerNativeProvider(faux.provider);
    const events: Array<{ topic: string; payload: any; at: number }> = [];
    const registry = await createTestRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime,
      trust: new TrustService(agentDir), broadcast: (_id, topic, payload) => events.push({ topic, payload, at: Date.now() }),
      sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.acquire(manager.getSessionId());
    subscribeAudience(registry, slot.id);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const before = events.length;
    const receipt = await slot.prompt("accepted snapshot burst");
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    const snapshots = events.slice(before).filter((event) => event.topic === "session.snapshot");
    const sizes = snapshots.map((event) => Buffer.byteLength(JSON.stringify(event.payload)));
    expect(sizes.some((size) => size >= 400 * 1_024)).toBe(true);
    const sequences = events.slice(before)
      .map((event) => event.payload.eventSequence)
      .filter((value) => typeof value === "number");
    for (let index = 1; index < sequences.length; index += 1) {
      expect(sequences[index]).toBe(sequences[index - 1]! + 1);
    }
    const pausedQueue = events.slice(before).map((event) => Buffer.byteLength(JSON.stringify({
      type: "event", topic: event.topic, sessionId: slot.id, payload: event.payload,
    })));
    const pausedBytes = pausedQueue.reduce((total, bytes) => total + bytes, 0);
    expect(pausedBytes).toBeGreaterThan(2 * 1_024 * 1_024);
    let resumedBytes = pausedBytes;
    for (const bytes of pausedQueue) resumedBytes -= bytes;
    expect(resumedBytes).toBe(0);
    expect(slot.snapshot().transcript.some((item) => item.kind === "message" && item.presentationId === receipt.operationId)).toBe(true);
    expect(snapshots.every((event) => event.payload.sessionId === slot.id)).toBe(true);
  });

  it("keeps a large streamed write visible through snapshot recovery and canonical handoff", async () => {
    const root = await temporaryRoot("tron-large-streamed-write-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    process.env.PI_CODING_AGENT_DIR = agentDir;
    const content = "Report line 🦌\\n".repeat(3_000);
    const path = join(cwd, "report.txt");
    const faux = fauxProvider({ provider: "tron-large-streamed-write", tokensPerSecond: 100_000, tokenSize: { min: 32, max: 32 } });
    faux.setResponses([
      fauxAssistantMessage([
        { type: "text", text: "Here is the summary before the report." },
        fauxToolCall("write", { path, content }, { id: "call-large-write" }),
      ], { stopReason: "toolUse" }),
      fauxAssistantMessage("Report saved."),
    ]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const events: Array<{ topic: string; payload: any }> = [];
    const liveSnapshots: Array<{ progress: any; streaming: any }> = [];
    let currentSlot: Awaited<ReturnType<RuntimeRegistry["create"]>> | undefined;
    const registry = await createTestRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime, trust: new TrustService(agentDir),
      broadcast: (_id, topic, payload) => {
        events.push({ topic, payload });
        if (topic === "session.progress" && currentSlot) {
          liveSnapshots.push({ progress: (payload as any).data?.message, streaming: currentSlot.snapshot().streaming });
        }
      },
      sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    currentSlot = slot;
    subscribeAudience(registry, slot.id);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("Write a report");
    await waitFor(() => !slot.isBusy, "the slot to go idle");

    const declarations = liveSnapshots.filter(({ progress }) => progress?.content?.some(
      (part: any) => part.toolCallId === "call-large-write" && part.arguments?.truncated === true,
    ));
    expect(declarations.length).toBeGreaterThan(0);
    for (const { progress, streaming } of declarations) {
      expect(Buffer.byteLength(JSON.stringify(progress))).toBeLessThanOrEqual(24_000);
      expect(progress.content).toContainEqual(expect.objectContaining({ type: "text", text: "Here is the summary before the report." }));
      expect(streaming).toEqual(progress);
    }
    const finalized = events.findIndex(event => event.topic === "session.progress"
      && event.payload.data?.message?.content?.some((part: any) => part.toolCallId === "call-large-write" && part.groupFinalized));
    const running = events.findIndex(event => event.topic === "session.toolProgress"
      && event.payload.data?.toolCallId === "call-large-write" && event.payload.data?.status === "running");
    expect(finalized).toBeGreaterThanOrEqual(0);
    expect(running).toBeGreaterThan(finalized);
    expect(await readFile(path, "utf8")).toBe(content);
    const settled = slot.snapshot();
    expect(settled.streaming).toBeUndefined();
    const calls = settled.transcript.flatMap(item => item.kind === "message" ? item.content : [])
      .filter(part => part.type === "toolCall" && part.toolCallId === "call-large-write");
    expect(calls).toHaveLength(1);
    expect(calls[0]).toMatchObject({ arguments: { path, content }, groupFinalized: true });
    const declaration = declarations.at(-1)!.progress;
    expect(settled.transcript.some(item => item.presentationId === declaration.presentationId)).toBe(true);
  });

  it("coalesces streaming progress frames while keeping the event stream contiguous and complete", async () => {
    const root = await temporaryRoot("tron-streaming-coalesce-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    process.env.PI_CODING_AGENT_DIR = agentDir;

    const text = "streaming chunk ".repeat(60);
    const faux = fauxProvider({ provider: "tron-streaming-coalesce", tokensPerSecond: 100, tokenSize: { min: 1, max: 1 } });
    const createModels = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    faux.setResponses([fauxAssistantMessage(text)]);
    const events: Array<{ topic: string; at: number; payload: { eventSequence?: number; data?: any } }> = [];
    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: createModels,
      trust: new TrustService(agentDir),
      broadcast: (_sessionId, topic, payload) => events.push({
        topic,
        at: nodePerformance.now(),
        payload: payload as { eventSequence?: number; data?: any },
      }),
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    subscribeAudience(registry, slot.id);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const promptReceipt = await slot.prompt("stream");
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    expect(slot.snapshot().pendingPrompt).toBeUndefined();
    const canonicalUser = slot.snapshot().transcript.find((item) => item.role === "user");
    expect(canonicalUser).toMatchObject({ presentationId: promptReceipt.operationId });

    const progress = events.filter((event) => event.topic === "session.progress");
    expect(progress.length).toBeGreaterThanOrEqual(2);

    const cadence = progress.filter((event, index) => {
      if (index === progress.length - 1) return false;
      return events[events.indexOf(event) + 1]?.topic !== "session.snapshot";
    });
    expect(cadence.length).toBeGreaterThanOrEqual(5);
    for (let index = 1; index < cadence.length; index += 1) {
      expect(cadence[index]!.at - cadence[index - 1]!.at).toBeGreaterThanOrEqual(100);
    }
    const progressTextLengths = progress.map((event) => (event.payload.data?.message?.content ?? [])
      .filter((part: any) => part.type === "text")
      .reduce((length: number, part: any) => length + part.text.length, 0));
    for (let index = 1; index < progressTextLengths.length; index += 1) {
      expect(progressTextLengths[index]).toBeGreaterThanOrEqual(progressTextLengths[index - 1]!);
    }

    const sequenced = events.filter((event) => typeof event.payload.eventSequence === "number");
    for (let index = 1; index < sequenced.length; index += 1) {
      expect(sequenced[index]!.payload.eventSequence).toBe(sequenced[index - 1]!.payload.eventSequence! + 1);
    }

    const progressMessages = progress.map((event) => event.payload.data?.message).filter(Boolean);
    const lastMessage = progressMessages.at(-1)!;
    const lastText = (lastMessage.content ?? []).filter((part: any) => part.type === "text").map((part: any) => part.text).join("");
    expect(lastText.trimEnd().endsWith("streaming chunk")).toBe(true);
    expect(new Set(progressMessages.map((message) => message.presentationId)).size).toBe(1);
    expect(new Set(progressMessages.map((message) => message.parentId)).size).toBe(1);
    expect(new Set(progressMessages.map((message) => message.timestamp)).size).toBe(1);
    expect(lastMessage.content.map((part: any) => part.ordinal)).toEqual([0]);
    const finalSnapshot = slot.snapshot();
    expect(finalSnapshot.streaming).toBeUndefined();
    const assistant = finalSnapshot.transcript.find(
      (item) => item.kind === "message" && item.role === "assistant",
    );
    expect(assistant).toMatchObject({ presentationId: lastMessage.presentationId });
    const transcriptText = finalSnapshot.transcript
      .filter((item) => item.kind === "message")
      .flatMap((item) => item.kind === "message" ? item.content : [])
      .filter((part) => part.type === "text")
      .map((part) => part.type === "text" ? part.text : "")
      .join("");
    expect(transcriptText).toContain(text.trimEnd());
  });

  it("projects no streaming progress for a session with no subscriber and resumes it on subscribe", async () => {
    const root = await temporaryRoot("tron-streaming-unwatched-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    process.env.PI_CODING_AGENT_DIR = agentDir;

    const unwatched = "unwatched chunk ".repeat(20);
    const watched = "watched chunk ".repeat(20);
    const faux = fauxProvider({ provider: "tron-streaming-unwatched", tokensPerSecond: 100, tokenSize: { min: 1, max: 1 } });
    const createModels = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    faux.setResponses([fauxAssistantMessage(unwatched), fauxAssistantMessage(watched)]);
    const events: Array<{ topic: string; payload: { data?: any } }> = [];
    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: createModels,
      trust: new TrustService(agentDir),
      broadcast: (_sessionId, topic, payload) => events.push({ topic, payload: payload as { data?: any } }),
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);

    const unwatchedPrompt = slot.prompt("stream unobserved");
    await waitFor(() => slot.snapshot().streaming !== undefined, "the streaming projection");
    await unwatchedPrompt;
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    expect(slot.snapshot().transcript.some((item) => item.kind === "message"
      && item.role === "assistant" && item.content.some((part) => part.type === "text" && part.text.includes(unwatched.trimEnd())))).toBe(true);
    expect(events.filter((event) => event.topic === "session.progress")).toHaveLength(0);

    subscribeAudience(registry, slot.id);
    await slot.prompt("stream observed");
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    const frames = events.filter((event) => event.topic === "session.progress");
    expect(frames.length).toBeGreaterThanOrEqual(2);
    const lastFrame = frames.at(-1)!.payload.data.message;
    expect(lastFrame.content
      .filter((part: any) => part.type === "text")
      .map((part: any) => part.text)
      .join("").trimEnd()).toBe(watched.trimEnd());
    expect(JSON.stringify(frames)).not.toContain("unwatched chunk");
  });

  it.each(["message_start", "message_end"] as const)(
    "keeps one presentation identity through an async %s extension hook",
    async (hook) => {
      const root = await temporaryRoot(`tron-streaming-${hook}-`);
      const agentDir = join(root, "agent");
      const cwd = join(root, "workspace");
      const extensionDir = join(cwd, ".pi", "extensions");
      const entered = join(root, "entered");
      const release = join(root, "release");
      await Promise.all([mkdir(agentDir), mkdir(extensionDir, { recursive: true })]);
      process.env.PI_CODING_AGENT_DIR = agentDir;
      await writeFile(join(extensionDir, "streaming-hook.ts"), `
        import { existsSync, writeFileSync } from "node:fs";
        export default function (pi) {
          pi.on(${JSON.stringify(hook)}, async (event) => {
            if (event.message?.role !== "assistant") return;
            writeFileSync(${JSON.stringify(entered)}, "entered");
            while (!existsSync(${JSON.stringify(release)})) {
              await new Promise((resolve) => setTimeout(resolve, 5));
            }
          });
        }
      `);
      const trust = new TrustService(agentDir);
      await trust.set(cwd, true);
      const faux = fauxProvider({ provider: `tron-streaming-${hook}`, tokensPerSecond: 20, tokenSize: { min: 1, max: 1 } });
      const createModels = async () => {
        const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
        runtime.registerNativeProvider(faux.provider);
        return runtime;
      };
      faux.setResponses([fauxAssistantMessage("stable identity")]);
      const registry = await createTestRegistry({
        agentDir,
        tronHome: join(root, "tron"),
        idleRuntimeMs: 60_000,
        modelRuntimeFactory: createModels,
        trust,
        broadcast: () => {},
        sessionSummaryChanged: () => {},
        sessionListChanged: () => {},
      });
      registries.push(registry);
      await initializeRegistry(registry);
      const slot = await registry.create(cwd);
      const model = faux.getModel();
      await slot.setModel(model.provider, model.id);

      const prompt = slot.prompt("stream");
      await waitFor(() => existsSync(entered), "the entered marker file");
      const during = slot.snapshot().streaming;
      expect(during).toMatchObject({ role: "assistant" });
      if (during?.kind !== "message") throw new Error("expected live assistant");
      if (hook === "message_end") {
        expect(slot.snapshot().transcript.some((item) => item.kind === "message" && item.role === "assistant")).toBe(false);
      }
      await writeFile(release, "release");
      await prompt;
      await waitFor(() => !slot.isBusy, "the slot to go idle");

      const finalSnapshot = slot.snapshot();
      expect(finalSnapshot.streaming).toBeUndefined();
      const canonical = finalSnapshot.transcript.find(
        (item) => item.kind === "message" && item.role === "assistant",
      );
      expect(canonical).toMatchObject({
        id: expect.not.stringMatching(/^streaming$/),
        presentationId: during.presentationId,
      });
      if (canonical?.kind !== "message") throw new Error("expected canonical assistant");
      expect(canonical.content.slice(0, during.content.length).map(
        (part) => ({ id: part.id, ordinal: part.ordinal }),
      )).toEqual(during.content.map((part) => ({ id: part.id, ordinal: part.ordinal })));
    },
    15_000,
  );

  it("keeps async input preflight alive and settles accepted handled input exactly once", async () => {
    const root = await temporaryRoot("tron-input-handled-preflight-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await Promise.all([mkdir(agentDir), mkdir(extensionDir, { recursive: true })]);
    await writeFile(join(extensionDir, "handled.ts"), `export default function (pi) {
      pi.on("input", async () => {
        await new Promise((resolve) => setTimeout(resolve, 200));
        return { action: "handled" };
      });
    }\n`);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const registry = await createTestRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust,
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const prompting = slot.prompt("handled without agent");
    await waitFor(() => slot.isBusy, "the slot to take work");
    await expect(slot.dispose()).rejects.toMatchObject({ code: "busy" });
    const admitted = await prompting;
    expect(admitted).toMatchObject({ operationId: expect.any(String) });
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    expect(slot.snapshot()).toMatchObject({ phase: "idle" });
    expect(slot.snapshot().operation).toBeUndefined();
    const entries = (slot as any).runtime.session.sessionManager.getEntries() as any[];
    const receipts = entries.filter(entry =>
      entry.customType === INVOCATION_RECEIPT_TYPE
        && entry.data?.operationId === admitted.operationId,
    ).map(entry => entry.data);
    expect(receipts.map(receipt => receipt.receiptKind)).toEqual(["start", "transition", "terminal"]);
    expect(receipts.at(-1)).toMatchObject({ lifecycle: "completed" });
    const markerStore = (registry as unknown as { markers: { interruptedSessionIds(): Promise<Set<string>> } }).markers;
    expect((await markerStore.interruptedSessionIds()).has(slot.id)).toBe(false);
  });

  it("permits the exact delayed prompt accepted before the drain cutoff", async () => {
    const root = await temporaryRoot("tron-drain-delayed-preflight-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await Promise.all([mkdir(agentDir), mkdir(extensionDir, { recursive: true })]);
    await writeFile(join(extensionDir, "delay.ts"), `export default function (pi) {
      pi.on("input", async () => { await new Promise((resolve) => setTimeout(resolve, 150)); });
    }\n`);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const faux = fauxProvider({ provider: "tron-drain-delayed-preflight", tokensPerSecond: 10_000 });
    faux.setResponses([fauxAssistantMessage("accepted after delayed preflight")]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const failures: unknown[] = [];
    const registry = await createTestRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust,
      modelRuntimeFactory: async () => runtime,
      broadcast: (_id, topic, payload) => { if (topic === "session.operationFailed") failures.push(payload); },
      sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const prompt = slot.prompt("accepted before cutoff");
    await waitFor(() => slot.isBusy, "the slot to take work");
    const drain = registry.waitUntilIdle();
    await expect(prompt).resolves.toMatchObject({ operationId: expect.any(String) });
    await drain;
    expect(faux.state.callCount).toBe(1);
    expect(failures).toEqual([]);
    expect(slot.snapshot()).toMatchObject({ phase: "idle" });
  });

  it("cuts off extension auto-continuations during administrative drain", async () => {
    const root = await temporaryRoot("tron-drain-continuation-cutoff-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await Promise.all([mkdir(agentDir), mkdir(extensionDir, { recursive: true })]);
    await writeFile(join(extensionDir, "continue.ts"), `let sent = false;
      export default function (pi) {
        pi.on("agent_settled", () => {
          if (sent) return;
          sent = true;
          pi.sendMessage({ customType: "after-cutoff", content: "continue", display: false }, { triggerTurn: true });
        });
      }\n`);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const faux = fauxProvider({ provider: "tron-drain-cutoff", tokensPerSecond: 10_000 });
    faux.setResponses([
      async () => { await new Promise((resolve) => setTimeout(resolve, 150)); return fauxAssistantMessage("first"); },
      fauxAssistantMessage("must be aborted"),
    ]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const failures: unknown[] = [];
    const registry = await createTestRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust,
      modelRuntimeFactory: async () => runtime,
      broadcast: (_id, topic, payload) => { if (topic === "session.operationFailed") failures.push(payload); },
      sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("start");
    await waitFor(() => slot.catalogPhase === "running", "the catalog phase to run");
    await registry.waitUntilIdle();
    expect(slot.isDrainBusy).toBe(false);
    expect(failures).not.toEqual([]);
  });

  it("uses runtime preflight as the sole prompt-admission outcome", async () => {
    const root = await temporaryRoot("tron-prompt-preflight-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const session = (slot as unknown as {
      runtime: { session: { prompt: (
        text: string,
        options?: { preflightResult?: (disposition: "handled" | "queued" | "started") => void },
      ) => Promise<void> } };
    }).runtime.session;
    let startedResolve!: () => void;
    const started = new Promise<void>((resolve) => { startedResolve = resolve; });
    vi.spyOn(session, "prompt").mockImplementationOnce(async (_text, options) => {
      startedResolve();
      await new Promise((resolve) => setTimeout(resolve, 6_000));
      options?.preflightResult?.("started");
    });

    vi.useFakeTimers();
    try {
      const attachment = {
        id: "upload:00000000-0000-4000-8000-000000000001",
        name: "notes.txt", mimeType: "text/plain", size: 4,
      };
      const prompting = slot.prompt("delayed preflight", [], undefined, {
        text: "delayed preflight",
        attachmentEnvelope: '<attachment name="notes.txt" />',
        attachmentCount: 1,
        photoCount: 0,
        fileAttachmentCount: 1,
        attachments: [attachment],
      });
      await started;
      expect(slot.snapshot().pendingPrompt).toMatchObject({
        id: expect.any(String),
        text: "delayed preflight",
        attachmentCount: 1,
        attachments: [attachment],
      });
      await vi.advanceTimersByTimeAsync(6_000);
      await expect(prompting).resolves.toMatchObject({ operationId: expect.any(String) });
    } finally {
      vi.useRealTimers();
    }
  });

  it("rejects a stale stop receipt before it can abort a newer operation", async () => {
    const fixture = await coldFixture("stale-operation-abort");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as {
      operation?: { id: string; kind: "prompt"; startedAt: string };
    };
    internal.operation = {
      id: "newer-operation", kind: "prompt", startedAt: new Date().toISOString(),
    };

    await expect(slot.abort("agent", "older-operation")).rejects.toMatchObject({
      code: "conflict",
      retryable: true,
    });
    expect(internal.operation?.id).toBe("newer-operation");
  });

  it("holds steering behind compaction even while Pi reports broad streaming", async () => {
    const fixture = await coldFixture("compaction-steer-admission");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as {
      phase: "compacting" | "running";
      activeOperationId?: string;
      operation?: { id?: string; kind: "compaction"; startedAt: string };
      publishSnapshot: () => void;
      runtime: { session: {
        readonly isStreaming: boolean;
        prompt: (text: string, options?: {
          streamingBehavior?: "steer" | "followUp";
          preflightResult?: (disposition: "handled" | "queued" | "started") => void;
        }) => Promise<void>;
        getSteeringMessages: () => readonly string[];
      } };
    };
    internal.phase = "compacting";
    internal.operation = {
      id: "compaction-operation", kind: "compaction", startedAt: new Date().toISOString(),
    };
    vi.spyOn(internal.runtime.session, "isStreaming", "get").mockReturnValue(true);
    internal.activeOperationId = "prior-agent-operation";
    const compactingSnapshot = slot.snapshot();
    expect(compactingSnapshot.acceptsQueuedPrompts).toBe(true);
    expect(compactingSnapshot.activeToolSegmentId).toBeUndefined();
    internal.activeOperationId = undefined;
    let queued = false;
    vi.spyOn(internal.runtime.session, "getSteeringMessages")
      .mockImplementation(() => queued ? ["after compaction"] : []);
    let invoked = false;
    vi.spyOn(internal.runtime.session, "prompt").mockImplementationOnce(async (_text, options) => {
      invoked = true;
      expect(options?.streamingBehavior).toBe("steer");
      queued = true;
      options?.preflightResult?.("started");
    });

    const prompting = slot.prompt("after compaction", [], "steer");
    await Promise.resolve();
    expect(invoked).toBe(false);
    internal.phase = "running";
    internal.operation = undefined;
    internal.publishSnapshot();

    const { operationId } = await prompting;
    await waitFor(() => invoked, "the invocation");
    await waitFor(() => slot.snapshot().queuedItems.length === 1 && queued, "the queued prompt");
    expect(slot.snapshot().queuedItems).toEqual([
      expect.objectContaining({ id: operationId, behavior: "steer", text: "after compaction" }),
    ]);
  });

  it("preserves a successor operation and abort intent across compaction_end", async () => {
    const fixture = await coldFixture("compaction-successor-ownership");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as {
      phase: "running" | "compacting";
      activeOperationId?: string;
      operation?: { id?: string; kind: "prompt" | "compaction"; startedAt: string };
      runAbort: import("../../kernel/run/run-abort-owner.js").RunAbortOwner;
      onEvent: (event: unknown) => void;
      runtime: { session: { readonly isStreaming: boolean } };
    };
    const streaming = vi.spyOn(internal.runtime.session, "isStreaming", "get").mockReturnValue(true);
    internal.phase = "running";
    internal.activeOperationId = "original-operation";
    internal.operation = { id: "original-operation", kind: "prompt", startedAt: new Date().toISOString() };

    internal.onEvent({ type: "compaction_start", reason: "threshold" });
    const compactionID = internal.operation?.id;
    expect(internal.operation?.kind).toBe("compaction");
    expect(compactionID).toBeDefined();
    internal.runAbort.abortedOperations.add(compactionID!);

    internal.operation = { id: "successor-operation", kind: "prompt", startedAt: new Date().toISOString() };
    internal.activeOperationId = "successor-operation";
    internal.phase = "running";
    internal.runAbort.abortedOperations.add("successor-operation");
    internal.onEvent({ type: "compaction_end", reason: "threshold", result: undefined, aborted: false, willRetry: false });

    expect(slot.snapshot()).toMatchObject({
      phase: "running",
      operation: { id: "successor-operation", kind: "prompt" },
    });
    expect(internal.runAbort.abortedOperations.has(compactionID!)).toBe(false);
    expect(internal.runAbort.abortedOperations.has("successor-operation")).toBe(true);
    streaming.mockRestore();
  });

  it("leaves a successor running when manual compaction settles after an awaited failure", async () => {
    const fixture = await coldFixture("manual-compaction-successor-cleanup");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as {
      phase: "idle" | "running" | "compacting";
      operation?: { id?: string; kind: "prompt" | "compaction"; startedAt: string };
      runAbort: import("../../kernel/run/run-abort-owner.js").RunAbortOwner;
      runtime: { session: { compact: (instructions?: string) => Promise<unknown> } };
    };
    vi.spyOn(internal.runtime.session, "compact").mockImplementation(async () => {
      const compactionID = internal.operation?.id;
      expect(internal.operation?.kind).toBe("compaction");
      if (compactionID) internal.runAbort.abortedOperations.add(compactionID);
      internal.operation = { id: "manual-successor", kind: "prompt", startedAt: new Date().toISOString() };
      internal.phase = "running";
      internal.runAbort.abortedOperations.add("manual-successor");
      throw new Error("manual compaction failed after successor start");
    });

    await expect(slot.compact()).rejects.toThrow("manual compaction failed after successor start");
    expect(slot.snapshot()).toMatchObject({
      phase: "running",
      operation: { id: "manual-successor", kind: "prompt" },
    });
    expect(internal.runAbort.abortedOperations.has("manual-successor")).toBe(true);
  });

  it("rotates provisional tool segment authority across automatic compaction", async () => {
    const fixture = await coldFixture("compaction-tool-segment-boundary");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as {
      phase: "running" | "compacting";
      activeOperationId?: string;
      activeToolSegmentOwnerId?: string;
      onEvent: (event: unknown) => void;
      runtime: { session: { readonly isStreaming: boolean } };
    };
    const streaming = vi.spyOn(internal.runtime.session, "isStreaming", "get").mockReturnValue(true);
    internal.phase = "running";
    internal.activeOperationId = "operation-before-compaction";
    internal.activeToolSegmentOwnerId = "operation-before-compaction";
    const beforeSegment = slot.snapshot().activeToolSegmentId;
    expect(beforeSegment).toBe(toolSegmentId("operation-before-compaction"));

    internal.onEvent({ type: "compaction_start", reason: "threshold" });
    expect(slot.snapshot()).toMatchObject({
      phase: "compacting",
      acceptsQueuedPrompts: true,
    });
    expect(slot.snapshot().activeToolSegmentId).toBeUndefined();

    internal.onEvent({
      type: "compaction_end",
      reason: "threshold",
      result: undefined,
      aborted: false,
      willRetry: false,
    });
    const provisionalSegment = slot.snapshot().activeToolSegmentId;
    expect(provisionalSegment).toMatch(/^tool-segment:/);
    expect(provisionalSegment).not.toBe(beforeSegment);

    const assistant = fauxAssistantMessage([
      fauxToolCall("read", { path: "README.md" }, { id: "call-after-compaction" }),
    ], { stopReason: "toolUse" });
    internal.onEvent({ type: "message_start", message: assistant });
    const assistantSegment = slot.snapshot().activeToolSegmentId;
    expect(assistantSegment).toMatch(/^tool-segment:/);
    expect(assistantSegment).not.toBe(provisionalSegment);
    internal.onEvent({ type: "message_end", message: assistant });
    internal.onEvent({
      type: "tool_execution_start",
      toolCallId: "call-after-compaction",
      toolName: "read",
      args: { path: "README.md" },
    });
    expect(slot.snapshot().toolExecutions).toEqual([
      expect.objectContaining({
        toolCallId: "call-after-compaction",
        toolSegmentId: assistantSegment,
      }),
    ]);
    streaming.mockRestore();
  });

  it.each(["successful append", "pre-staging append failure"])(
    "retires completion observations after queued successful operations settle (%s)", async (appendOutcome) => {
    const root = await temporaryRoot("tron-completion-observation-retirement-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    let releaseInitial!: () => void;
    let releaseFollowUp!: () => void;
    let releaseAttention!: () => void;
    let followUpStarted!: () => void;
    const initialBarrier = new Promise<void>((resolve) => { releaseInitial = resolve; });
    const followUpBarrier = new Promise<void>((resolve) => { releaseFollowUp = resolve; });
    const attentionBarrier = new Promise<void>((resolve) => { releaseAttention = resolve; });
    const followUpStart = new Promise<void>((resolve) => { followUpStarted = resolve; });
    onTestFinished(async () => {
      releaseInitial();
      releaseFollowUp();
      releaseAttention();
      await rm(root, { recursive: true, force: true });
    });
    const faux = fauxProvider({ provider: "tron-completion-observation-retirement", tokensPerSecond: 10_000 });
    faux.setResponses([
      async () => {
        await initialBarrier;
        return fauxAssistantMessage("initial complete");
      },
      async () => {
        followUpStarted();
        await followUpBarrier;
        return fauxAssistantMessage("follow-up complete");
      },
    ]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);

    const attention = (registry as unknown as {
      attention: { complete: (sessionId: string, completionId: string) => Promise<unknown> };
    }).attention;
    const originalComplete = attention.complete.bind(attention);
    vi.spyOn(attention, "complete").mockImplementation(async (...args) => {
      await attentionBarrier;
      return originalComplete(...args);
    });
    const slotInternals = (slot as unknown as { runTerminal: { operationObservations: Map<string, unknown> } }).runTerminal;

    const initial = slot.prompt("initial");
    await waitFor(() => slot.snapshot().phase === "running", "the initial run");
    const initialOperationId = slot.snapshot().operation?.id;
    expect(initialOperationId).toBeTruthy();
    const queued = await slot.prompt("queued follow-up", [], "followUp");
    const manager = (slot as unknown as { runtime: { session: { sessionManager: SessionManager } } }).runtime.session.sessionManager;
    const append = manager.appendCustomEntry.bind(manager);
    let failed = false;
    const receiptAppend = vi.spyOn(manager, "appendCustomEntry").mockImplementation((customType, data) => {
      const receipt = data as { receiptKind?: unknown; operationId?: unknown } | undefined;
      if (appendOutcome === "pre-staging append failure" && !failed && customType === INVOCATION_RECEIPT_TYPE
        && receipt?.receiptKind === "terminal" && receipt?.operationId === initialOperationId) {
        failed = true;
        throw new Error("injected pre-staging terminal receipt failure");
      }
      return append(customType, data);
    });
    releaseInitial();
    try {
      await followUpStart;
      const entries = slot.canonicalSessionEntries();
      const completionIndex = entries.findIndex(entry => entry.type === "message"
        && entry.message.role === "assistant" && contentText(entry.message.content).includes("initial complete"));
      expect(completionIndex).toBeGreaterThanOrEqual(0);
      const followUpIndex = entries.findIndex(entry => entry.type === "message" && entry.message.role === "user"
        && contentText(entry.message.content).includes("queued follow-up"));
      if (appendOutcome === "pre-staging append failure") expect(failed).toBe(true);
      expect(entries[completionIndex + 1]).toMatchObject({
        type: "custom",
        customType: INVOCATION_RECEIPT_TYPE,
        data: { receiptKind: "terminal", operationId: initialOperationId, lifecycle: "completed" },
      });
      expect(followUpIndex).toBeGreaterThan(completionIndex + 1);
    } catch (error) {
      releaseAttention();
      throw error;
    } finally {
      releaseFollowUp();
    }
    await waitFor(() => faux.state.callCount === 2, "both successful model responses");
    await initial;
    releaseAttention();
    await waitFor(() => !slot.isBusy, "both operations to settle");

    receiptAppend.mockRestore();
    const persisted = (await readFile(manager.getSessionFile()!, "utf8")).trim().split("\n")
      .map(line => JSON.parse(line));
    const terminalEntries = persisted.filter(entry => entry.type === "custom" && entry.customType === INVOCATION_RECEIPT_TYPE
      && entry.data?.receiptKind === "terminal" && entry.data?.operationId === initialOperationId);
    expect(terminalEntries).toHaveLength(1);
    expect(terminalEntries[0].data).toMatchObject({ lifecycle: "completed" });
    expect(slotInternals.operationObservations.has(initialOperationId!)).toBe(false);
    expect(slotInternals.operationObservations.has(queued.operationId)).toBe(false);
    expect(slotInternals.operationObservations.size).toBe(0);
  });

  it("retires a steered operation observation when a successful queued follow-up takes ownership", async () => {
    const root = await temporaryRoot("tron-steering-follow-up-observation-retirement-");
    onTestFinished(() => rm(root, { recursive: true, force: true }));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    let releaseInitial!: () => void;
    let releaseSteering!: () => void;
    let initialStarted!: () => void;
    let steeringStarted!: () => void;
    let followUpStarted!: () => void;
    const initialBarrier = new Promise<void>((resolve) => { releaseInitial = resolve; });
    const steeringBarrier = new Promise<void>((resolve) => { releaseSteering = resolve; });
    const initialStart = new Promise<void>((resolve) => { initialStarted = resolve; });
    const steeringStart = new Promise<void>((resolve) => { steeringStarted = resolve; });
    const followUpStart = new Promise<void>((resolve) => { followUpStarted = resolve; });
    onTestFinished(() => {
      releaseInitial();
      releaseSteering();
    });
    const faux = fauxProvider({ provider: "tron-steering-follow-up-observation-retirement", tokensPerSecond: 10_000 });
    faux.setResponses([
      async () => {
        initialStarted();
        await initialBarrier;
        return fauxAssistantMessage("initial complete");
      },
      async () => {
        steeringStarted();
        await steeringBarrier;
        return fauxAssistantMessage("steering complete");
      },
      async () => {
        followUpStarted();
        return fauxAssistantMessage("follow-up complete");
      },
    ]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const slotInternals = (slot as unknown as { runTerminal: { operationObservations: Map<string, { observedCompletionId?: string }> } }).runTerminal;

    const initial = slot.prompt("initial");
    await waitFor(() => slot.snapshot().phase === "running", "the initial run");
    const initialOperationId = slot.snapshot().operation?.id;
    expect(initialOperationId).toBeTruthy();
    await initialStart;
    const steer = await slot.prompt("steer during foreground run", [], "steer");
    releaseInitial();
    await steeringStart;
    const initialCompletion = slot.canonicalSessionEntries().find(entry =>
      entry.type === "message" && entry.message.role === "assistant"
        && contentText(entry.message.content).includes("initial complete"));
    expect(initialCompletion?.type).toBe("message");
    await waitFor(() => slotInternals.operationObservations.get(initialOperationId!)?.observedCompletionId === initialCompletion!.id, "the initial completion admission");

    const queuedFollowUp = await slot.prompt("queued successful follow-up", [], "followUp");
    releaseSteering();
    await followUpStart;
    await waitFor(() => !slot.isBusy, "the steering and queued follow-up to settle");
    await initial;

    const steeringCompletion = slot.canonicalSessionEntries().find(entry =>
      entry.type === "message" && entry.message.role === "assistant"
        && contentText(entry.message.content).includes("steering complete"));
    const followUpCompletion = slot.canonicalSessionEntries().find(entry =>
      entry.type === "message" && entry.message.role === "assistant"
        && contentText(entry.message.content).includes("follow-up complete"));
    expect(steeringCompletion?.type).toBe("message");
    expect(followUpCompletion?.type).toBe("message");
    expect(slotInternals.operationObservations.has(initialOperationId!)).toBe(false);
    expect(slotInternals.operationObservations.has(steer.operationId)).toBe(false);
    expect(slotInternals.operationObservations.has(queuedFollowUp.operationId)).toBe(false);
    expect(slotInternals.operationObservations.size).toBe(0);
  });

  it("settles a reply before the queued follow-up runs so steering remains admissible", async () => {
    const root = await temporaryRoot("tron-follow-up-steering-settlement-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    let releaseInitial!: () => void;
    let releaseFollowUp!: () => void;
    let followUpStarted!: () => void;
    const initialBarrier = new Promise<void>((resolve) => { releaseInitial = resolve; });
    const followUpBarrier = new Promise<void>((resolve) => { releaseFollowUp = resolve; });
    onTestFinished(() => releaseFollowUp());
    const followUpStart = new Promise<void>((resolve) => { followUpStarted = resolve; });
    const faux = fauxProvider({ provider: "tron-follow-up-steering-settlement", tokensPerSecond: 10_000 });
    faux.setResponses([
      async () => {
        await initialBarrier;
        return fauxAssistantMessage("initial complete");
      },
      async () => {
        followUpStarted();
        await followUpBarrier;
        return fauxAssistantMessage("follow-up complete");
      },
      fauxAssistantMessage("steering complete"),
    ]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);

    const initial = slot.prompt("initial");
    await waitFor(() => slot.snapshot().phase === "running", "the initial run");
    const initialOperationId = slot.snapshot().operation?.id;
    expect(initialOperationId).toBeTruthy();
    const queuedFollowUp = await slot.prompt("queued follow-up", [], "followUp");
    releaseInitial();
    await followUpStart;

    let steer: { operationId: string };
    try {
      steer = await slot.prompt("steer during follow-up", [], "steer");
      expect(steer.operationId).toBeTruthy();
      expect(slot.snapshot().queuedItems).toEqual([
        expect.objectContaining({ id: steer.operationId, behavior: "steer" }),
      ]);
      await waitFor(() => invocationReceipts(slot.canonicalSessionEntries(), slot.id).some(receipt =>
        receipt.operationId === initialOperationId && receipt.receiptKind === "terminal" && receipt.lifecycle === "completed"),
      "the initial terminal receipt while the follow-up is active");
    } finally {
      releaseFollowUp();
    }
    await initial;
    await waitFor(() => !slot.isBusy, "the follow-up and accepted steer to settle");
    const entries = (await readFile(slot.sessionFile!, "utf8"))
      .trimEnd().split("\n").map(line => JSON.parse(line) as any);
    const queuedReceipt = entries
      .filter(entry => entry.customType === INVOCATION_RECEIPT_TYPE && entry.data?.operationId === queuedFollowUp.operationId)
      .map(entry => entry.data);
    expect(queuedReceipt.at(-1)).toMatchObject({ receiptKind: "terminal", lifecycle: "completed" });
    const steerReceipt = entries
      .filter(entry => entry.customType === INVOCATION_RECEIPT_TYPE && entry.data?.operationId === steer.operationId)
      .map(entry => entry.data);
    expect(steerReceipt.at(-1)).toMatchObject({ receiptKind: "terminal", lifecycle: "completed" });
    const artifactPath = join(process.cwd(), "test-results", "runtime-slot-follow-up-steering.json");
    await mkdir(dirname(artifactPath), { recursive: true });
    await writeFile(artifactPath, `${JSON.stringify({
      test: "queued follow-up then steer",
      transcript: entries.filter(entry => entry.type === "message"
        && (entry.message.role === "user" || entry.message.role === "assistant"))
        .map(entry => ({ role: entry.message.role, content: entry.message.content, stopReason: entry.message.stopReason })),
      receipts: entries.filter(entry => entry.customType === INVOCATION_RECEIPT_TYPE
        && [queuedFollowUp.operationId, steer.operationId].includes(entry.data?.operationId))
        .map(entry => entry.data),
    }, null, 2)}\n`);
  });

  it("orders a prompt behind a genuinely pending attention commit", async () => {
    const root = await temporaryRoot("tron-attention-admission-order-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    let secondResponseStarted!: () => void;
    let attentionStarted!: () => void;
    let releaseAttention!: () => void;
    const secondStarted = new Promise<void>((resolve) => { secondResponseStarted = resolve; });
    const attentionEntered = new Promise<void>((resolve) => { attentionStarted = resolve; });
    const attentionBarrier = new Promise<void>((resolve) => { releaseAttention = resolve; });
    onTestFinished(() => releaseAttention());
    const faux = fauxProvider({ provider: "tron-attention-admission-order", tokensPerSecond: 10_000 });
    faux.setResponses([
      fauxAssistantMessage("first complete"),
      async () => {
        secondResponseStarted();
        return fauxAssistantMessage("second complete");
      },
    ]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const originalAttention = slot.hooks.assistantResponseCompleted.bind(slot.hooks);
    slot.hooks.assistantResponseCompleted = async (...args: any[]) => {
      attentionStarted();
      await attentionBarrier;
      return originalAttention(...args);
    };

    await slot.prompt("first");
    await attentionEntered;
    let secondSettled = false;
    const second = slot.prompt("ordered second", [], "steer").then(result => {
      secondSettled = true;
      return result;
    });
    await new Promise<void>((resolve) => setTimeout(resolve, 0));
    expect(secondSettled, "the newer command waits for the durable attention commit").toBe(false);
    releaseAttention();
    const accepted = await second;
    expect(accepted.operationId).toBeTruthy();
    await secondStarted;
    await waitFor(() => !slot.isBusy, "the second response and its settlement");
  });

  it("names the exact pending completion and age when attention blocks prompt admission", async () => {
    const fixture = await coldFixture("attention-pending-diagnostic");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const completion = {
      id: "canonical-completion-id",
      completedAt: new Date(Date.now() - 2_000).toISOString(),
      operationId: "pending-operation-id",
    };
    const rejectedBarrier = Promise.reject(new Error("injected blocked completion"));
    void rejectedBarrier.catch(() => {});
    const internal = (slot as unknown as { runAttention: {
      attentionBarrier: Promise<void>;
      pendingAssistantCompletion: typeof completion;
    } }).runAttention;
    internal.pendingAssistantCompletion = completion;
    internal.attentionBarrier = rejectedBarrier;

    const error = await slot.prompt("new prompt").then(() => undefined, value => value);
    expect(error).toMatchObject({
      code: "busy",
      diagnosticReason: "attention-pending",
      details: { reason: "attention-pending", operationId: "pending-operation-id", ageMs: expect.any(Number) },
    });
    expect(fixture.events.find(event => event.topic === "session.diagnostic")?.payload.data).toMatchObject({
      code: "attention-pending",
      operationId: "pending-operation-id",
      ageMs: expect.any(Number),
    });
  });

  it("binds duplicate consumed steering to each exact queue operation", async () => {
    const root = await temporaryRoot("tron-steering-ownership-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    let releaseResponse!: () => void;
    let releaseSteeringResponse!: () => void;
    let steeringResponseStarted!: () => void;
    const responseBarrier = new Promise<void>((resolve) => { releaseResponse = resolve; });
    const steeringResponseBarrier = new Promise<void>((resolve) => { releaseSteeringResponse = resolve; });
    const steeringStarted = new Promise<void>((resolve) => { steeringResponseStarted = resolve; });
    let responseStarted!: () => void;
    const initialStarted = new Promise<void>((resolve) => { responseStarted = resolve; });
    const faux = fauxProvider({ provider: "tron-steering-ownership", tokensPerSecond: 10_000 });
    faux.setResponses([
      async () => {
        responseStarted();
        await responseBarrier;
        return fauxAssistantMessage("initial complete");
      },
      async () => {
        steeringResponseStarted();
        await steeringResponseBarrier;
        return fauxAssistantMessage("steering complete");
      },
    ]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);

    const initial = slot.prompt("initial");
    await awaitsWithin(initialStarted, "the initial request in flight");
    const queued = await slot.prompt("steer me", [], "steer", {
      text: "steer me",
      attachmentEnvelope: "",
      attachmentCount: 0,
    });
    const duplicate = await slot.prompt("steer me", [], "steer", {
      text: "steer me",
      attachmentEnvelope: "",
      attachmentCount: 0,
    });
    expect(slot.snapshot().queuedItems).toEqual([
      expect.objectContaining({ id: queued.operationId, behavior: "steer", text: "steer me" }),
      expect.objectContaining({ id: duplicate.operationId, behavior: "steer", text: "steer me" }),
    ]);

    releaseResponse();
    await waitFor(() => [queued.operationId, duplicate.operationId].some(operationId =>
      slot.snapshot().transcript.some(item =>
        item.kind === "message" && item.role === "user" && item.presentationId === operationId,
      ),
    ), "one queued prompt projected");
    const steeringSnapshot = slot.snapshot();
    const consumedSteeringIDs = steeringSnapshot.transcript.flatMap((item) =>
      item.kind === "message" && item.role === "user"
        && [queued.operationId, duplicate.operationId].includes(item.presentationId ?? "")
        ? [item.presentationId!] : [],
    );
    expect(consumedSteeringIDs.length).toBeGreaterThan(0);
    expect(steeringSnapshot.activeToolSegmentId).toBe(toolSegmentId(consumedSteeringIDs.at(-1)!));
    await steeringStarted;
    const canonicalBeforeSteeringResponse = slot.canonicalSessionEntries();
    const firstCompletion = canonicalBeforeSteeringResponse.find(entry =>
      entry.type === "message" && entry.message.role === "assistant"
        && contentText(entry.message.content).includes("initial complete"));
    expect(firstCompletion?.type).toBe("message");
    releaseSteeringResponse();
    await initial;
    await waitFor(() => [queued.operationId, duplicate.operationId].every(operationId =>
      slot.snapshot().transcript.some(item =>
        item.kind === "message" && item.role === "user" && item.presentationId === operationId,
      ),
    ), "both queued prompts projected");
    await waitFor(() => !slot.isBusy, "the slot to go idle");

    const entries = (await readFile(slot.sessionFile!, "utf8"))
      .trimEnd().split("\n").map(line => JSON.parse(line) as any);
    for (const operationId of [queued.operationId, duplicate.operationId]) {
      const receipts = entries
        .filter(entry => entry.customType === INVOCATION_RECEIPT_TYPE && entry.data?.operationId === operationId)
        .map(entry => entry.data);
      expect(receipts.map(receipt => receipt.receiptKind)).toEqual(["start", "transition", "binding", "terminal"]);
      expect(receipts.at(-1)).toMatchObject({ lifecycle: "completed" });
    }
    expect(slot.snapshot().queuedItems).toEqual([]);
  });

  it("reclassifies queued intent when Pi becomes idle inside an async input hook", async () => {
    const root = await temporaryRoot("tron-queue-disposition-race-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    const entered = join(root, "input-entered");
    const releaseInput = join(root, "release-input");
    await Promise.all([mkdir(agentDir), mkdir(extensionDir, { recursive: true })]);
    await writeFile(join(extensionDir, "delay-queued-input.ts"), `
      import { existsSync, writeFileSync } from "node:fs";
      export default function (pi) {
        pi.on("input", async (event) => {
          if (event.text !== "became ordinary") return;
          writeFileSync(${JSON.stringify(entered)}, "entered");
          while (!existsSync(${JSON.stringify(releaseInput)})) {
            await new Promise((resolve) => setTimeout(resolve, 5));
          }
        });
      }\n`);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    let releaseResponse!: () => void;
    const responseBarrier = new Promise<void>((resolve) => { releaseResponse = resolve; });
    const faux = fauxProvider({ provider: "tron-queue-disposition-race", tokensPerSecond: 10_000 });
    faux.setResponses([
      async () => {
        await responseBarrier;
        return fauxAssistantMessage("initial complete");
      },
      fauxAssistantMessage("ordinary complete"),
    ]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime,
      trust,
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);

    await slot.prompt("initial");
    await waitFor(() => slot.snapshot().acceptsQueuedPrompts, "the slot to accept queued prompts");
    const prompting = slot.prompt("became ordinary", [], "steer");
    await waitFor(() => existsSync(entered), "the entered marker file");
    releaseResponse();
    await waitFor(() => !slot.snapshot().acceptsQueuedPrompts, "the slot to stop accepting queued prompts");
    await writeFile(releaseInput, "release");

    const admitted = await prompting;
    await waitFor(() => slot.snapshot().transcript.some(item =>
      item.kind === "message" && item.role === "user" && item.presentationId === admitted.operationId,
    ), "the admitted prompt in the transcript");
    expect(slot.snapshot().queuedItems).toEqual([]);
    expect(slot.snapshot().pendingPrompt).toBeUndefined();
    const entries = (await readFile(slot.sessionFile!, "utf8"))
      .trimEnd().split("\n").map(line => JSON.parse(line) as any);
    const receipts = entries
      .filter(entry => entry.customType === INVOCATION_RECEIPT_TYPE && entry.data?.operationId === admitted.operationId)
      .map(entry => entry.data);
    expect(receipts.find(receipt => receipt.receiptKind === "transition")).toMatchObject({ lifecycle: "accepted" });
    expect(receipts.find(receipt => receipt.receiptKind === "binding")).toBeDefined();
    await waitFor(() => !slot.isBusy, "the slot to go idle");
  }, 15_000);

  it("settles a queued admission when the Pi call rejects before queue evidence", async () => {
    const fixture = await coldFixture("queue-disposition-rejection");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as {
      phase: "running" | "idle";
      activeOperationId?: string;
      operation?: { id?: string; kind: "prompt"; startedAt: string };
      runQueue: import("../../kernel/run/run-queue-owner.js").RunQueueOwner;
      runtime: { session: {
        readonly isStreaming: boolean;
        prompt: (text: string, options?: {
          streamingBehavior?: "steer" | "followUp";
          preflightResult?: (disposition: "handled" | "queued" | "started") => void;
        }) => Promise<void>;
        getSteeringMessages: () => readonly string[];
      } };
    };
    internal.phase = "running";
    internal.activeOperationId = "existing-operation";
    internal.operation = {
      id: "existing-operation", kind: "prompt", startedAt: new Date().toISOString(),
    };
    vi.spyOn(internal.runtime.session, "isStreaming", "get").mockReturnValue(true);
    vi.spyOn(internal.runtime.session, "getSteeringMessages").mockReturnValue([]);
    vi.spyOn(internal.runtime.session, "prompt").mockImplementationOnce(async (_text, options) => {
      expect(options?.streamingBehavior).toBe("steer");
      options?.preflightResult?.("started");
      throw new Error("queue admission failed");
    });

    await expect(slot.prompt("never queued", [], "steer")).rejects.toThrow("queue admission failed");
    expect(internal.runQueue.pendingQueueAdmission).toBeUndefined();
    const entries = (await readFile(slot.sessionFile!, "utf8"))
      .trimEnd().split("\n").map(line => JSON.parse(line) as any);
    const starts = entries.filter(entry =>
      entry.customType === INVOCATION_RECEIPT_TYPE && entry.data?.receiptKind === "start",
    );
    const operationId = starts.at(-1)?.data.operationId;
    expect(operationId).toEqual(expect.any(String));
    expect(entries.find(entry =>
      entry.customType === INVOCATION_RECEIPT_TYPE
        && entry.data?.operationId === operationId
        && entry.data?.receiptKind === "terminal",
    )?.data).toMatchObject({ lifecycle: "failed", errorCode: "runtime-prompt-failed" });

    internal.phase = "idle";
    internal.activeOperationId = undefined;
    internal.operation = undefined;
  });

  it("fails an accepted prompt that rejects before creating agent or canonical work", async () => {
    const fixture = await coldFixture("accepted-prompt-rejection");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const session = (slot as unknown as {
      runtime: { session: { prompt: (
        text: string,
        options?: { preflightResult?: (disposition: "handled" | "queued" | "started") => void },
      ) => Promise<void> } };
    }).runtime.session;
    vi.spyOn(session, "prompt").mockImplementationOnce(async (_text, options) => {
      options?.preflightResult?.("started");
      throw new Error("accepted prompt failed");
    });

    const admitted = await slot.prompt("fails after acceptance");
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    const entries = (slot as any).runtime.session.sessionManager.getEntries() as any[];
    const receipts = entries.filter(entry =>
      entry.customType === INVOCATION_RECEIPT_TYPE
        && entry.data?.operationId === admitted.operationId,
    ).map(entry => entry.data);
    expect(receipts.map(receipt => receipt.receiptKind)).toEqual(["start", "transition", "terminal"]);
    expect(receipts.at(-1)).toMatchObject({ lifecycle: "failed", errorCode: "runtime-prompt-failed" });
    expect(fixture.events).toContainEqual(expect.objectContaining({
      topic: "session.operationFailed",
      payload: expect.objectContaining({
        data: expect.objectContaining({ operationId: admitted.operationId }),
      }),
    }));
    expect(slot.snapshot()).toMatchObject({ phase: "idle" });
    expect(slot.snapshot().operation).toBeUndefined();
  });

  it("keeps ordinary prompt admission behind the Gateway settlement transition", async () => {
    const fixture = await coldFixture("prompt-settlement-admission");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as {
      phase: "running" | "idle";
      activeOperationId?: string;
      operation?: { id?: string; kind: "prompt"; startedAt: string };
      publishSnapshot: () => void;
      runtime: { session: { prompt: (
        text: string,
        options?: { preflightResult?: (disposition: "handled" | "queued" | "started") => void },
      ) => Promise<void> } };
    };
    internal.phase = "running";
    internal.activeOperationId = "settling-operation";
    internal.operation = {
      id: "settling-operation", kind: "prompt", startedAt: new Date().toISOString(),
    };
    let invoked = false;
    vi.spyOn(internal.runtime.session, "prompt").mockImplementationOnce(async (_text, options) => {
      invoked = true;
      options?.preflightResult?.("started");
    });

    const prompting = slot.prompt("after settlement");
    await Promise.resolve();
    expect(invoked).toBe(false);
    internal.phase = "idle";
    internal.activeOperationId = undefined;
    internal.operation = undefined;
    internal.publishSnapshot();

    await expect(prompting).resolves.toMatchObject({ operationId: expect.any(String) });
    expect(invoked).toBe(true);
  });

  it("does not retire a newer pending prompt for an older user message callback", async () => {
    const fixture = await coldFixture("pending-prompt-object-ownership");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as {
      pendingPrompt?: {
        id: string; createdAt: string; text: string; attachmentCount: number;
      };
      pendingPromptMessage?: unknown;
      onEvent: (event: unknown) => void;
    };
    const older = { role: "user", content: "same", timestamp: Date.now() };
    const newer = { role: "user", content: "same", timestamp: Date.now() + 1 };
    internal.pendingPrompt = {
      id: "older-operation", createdAt: new Date().toISOString(),
      text: "same", attachmentCount: 0,
    };
    internal.onEvent({ type: "message_start", message: older });
    internal.pendingPrompt = {
      id: "newer-operation", createdAt: new Date().toISOString(),
      text: "same", attachmentCount: 0,
    };
    internal.pendingPromptMessage = undefined;
    internal.onEvent({ type: "message_start", message: newer });
    internal.onEvent({ type: "message_end", message: older });
    expect(internal.pendingPrompt?.id).toBe("newer-operation");
    expect(internal.pendingPromptMessage).toBe(newer);
  });

  it("authorizes display artifacts only from the exact active canonical branch", async () => {
    const fixture = await coldFixture("active-display-artifact-branch");
    await fixture.registry.initializeBlobStorage();
    const store = displayStoreOf(fixture.registry);
    const png = Buffer.concat([
      Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
      Buffer.from("payload"),
    ]);
    await writeFile(join(fixture.cwd, "abandoned.png"), png);
    await writeFile(join(fixture.cwd, "active.png"), Buffer.concat([png, Buffer.from("active")]));
    const abandoned = await store.ingest(fixture.cwd, "abandoned.png", fixture.manager.getSessionId());
    const active = await store.ingest(fixture.cwd, "active.png", fixture.manager.getSessionId());
    fixture.manager.appendMessage({ role: "user", content: "root prompt", timestamp: Date.now() });
    const rootEntry = fixture.manager.getEntries().at(-1)!;
    const result = (toolCallId: string, artifact: typeof active) => ({
      role: "toolResult" as const,
      toolCallId,
      toolName: "display",
      isError: false,
      timestamp: Date.now(),
      content: [{ type: "text" as const, text: "Displayed." }],
      details: { display: {
        schema: "tron.display.v1",
        displayId: `${toolCallId}-display`,
        revision: 1,
        title: "Preview",
        altText: "Preview image.",
        kind: "image",
        presentation: { requestedSurface: "sheet", inlineTapAction: "sheet" },
        eligibleSurfaces: ["sheet", "inline", "floating"],
        fallbackText: "Preview image.",
        artifact: {
          id: artifact.id,
          name: artifact.name,
          mimeType: artifact.mimeType,
          size: artifact.size,
          kind: artifact.kind,
        },
      } },
    });
    fixture.manager.appendMessage(result("abandoned", abandoned));
    fixture.manager.branch(rootEntry.id);
    fixture.manager.appendMessage(result("active", active));

    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    expect(displayOwnerOf(fixture.registry).artifactIDs(slot)).toEqual([active.id]);
    expect(displayOwnerOf(fixture.registry).referencesArtifact(slot, abandoned.id)).toBe(false);
    expect(displayOwnerOf(fixture.registry).referencesArtifact(slot, active.id)).toBe(true);
    await expect(displayOwnerOf(fixture.registry).acquireArtifact(
      fixture.manager.getSessionId(),
      abandoned.id,
    )).rejects.toMatchObject({ code: "not_found" });
    const lease = await displayOwnerOf(fixture.registry).acquireArtifact(
      fixture.manager.getSessionId(),
      active.id,
    );
    expect(await collectStream(lease.stream)).toEqual(Buffer.concat([png, Buffer.from("active")]));
    await lease.release();
  });

  it.each(["browser_live", "native_live"])("authorizes %s views only from admitted display results on the exact canonical branch", async (kind) => {
    const fixture = await coldFixture("active-live-display-branch");
    fixture.manager.appendMessage({ role: "user", content: "root", timestamp: Date.now() });
    const root = fixture.manager.getEntries().at(-1)!;
    const result = (viewId: string, toolName = "display") => ({
      role: "toolResult" as const, toolCallId: viewId, toolName, isError: false, timestamp: Date.now(),
      content: [{ type: "text" as const, text: "Displayed" }],
      details: { display: { schema: "tron.display.v1", displayId: viewId, revision: 1,
        title: "Window", altText: "Window", kind,
        presentation: { requestedSurface: "sheet", inlineTapAction: "sheet" },
        eligibleSurfaces: ["sheet", "floating"], fallbackText: "Unavailable",
        liveView: { schema: kind === "native_live" ? "tron.native-live-view.v1" : "tron.browser-live-view.v1", viewId, generation: "generation",
          title: "Browser", fallbackText: "Unavailable" } } },
    });
    fixture.manager.appendMessage(result("abandoned"));
    fixture.manager.branch(root.id);
    fixture.manager.appendMessage(result("spoof", "other-tool"));
    fixture.manager.appendMessage(result("active"));
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    expect(displayOwnerOf(fixture.registry).referencesLiveView(slot, "abandoned", "generation")).toBe(false);
    expect(displayOwnerOf(fixture.registry).referencesLiveView(slot, "spoof", "generation")).toBe(false);
    expect(displayOwnerOf(fixture.registry).referencesLiveView(slot, "active", "wrong-generation")).toBe(false);
    expect(displayOwnerOf(fixture.registry).referencesLiveView(slot, "active", "generation")).toBe(true);
    expect(displayOwnerOf(fixture.registry).authorizeLiveView(fixture.manager.getSessionId(), "active", "generation")).toBe(true);
  });

  it("authorizes provider-bound browser actions only on their admitted call and canonical branch", async () => {
    const fixture = await coldFixture("browser-action-branch");
    fixture.manager.appendMessage({ role: "user", content: "root", timestamp: Date.now() });
    const root = fixture.manager.getEntries().at(-1)!;
    const result = (id: string, sessionId = fixture.manager.getSessionId()) => ({
      role: "toolResult" as const, toolCallId: id, toolName: "agent_browser", isError: false, timestamp: Date.now(),
      content: [{ type: "text" as const, text: "clicked" }],
      details: { tronBrowserReference: sealBrowserToolReference(sessionId, id, {
        schema: "tron.browser-live-view.v1", viewId: id, generation: "generation", title: "Browser", fallbackText: "Unavailable",
      }, true) },
    });
    fixture.manager.appendMessage(result("abandoned"));
    fixture.manager.branch(root.id);
    fixture.manager.appendMessage({ ...result("copied"), toolCallId: "wrong-call" });
    fixture.manager.appendMessage(result("wrong-session", "other-session"));
    fixture.manager.appendMessage(result("active"));
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    for (const id of ["abandoned", "copied", "wrong-session"]) {
      expect(displayOwnerOf(fixture.registry).referencesLiveView(slot, id, "generation")).toBe(false);
    }
    expect(displayOwnerOf(fixture.registry).referencesLiveView(slot, "active", "generation")).toBe(true);
    expect(displayOwnerOf(fixture.registry).referencesLiveView(slot, "active", "wrong-generation")).toBe(false);
    const transcript = slot.snapshot().transcript;
    const projected = (callId: string) => transcript.find(item => item.kind === "message" && item.toolCallId === callId);
    expect(projected("active")).toHaveProperty("display.kind", "browser_live");
    expect(projected("wrong-session")).not.toHaveProperty("display");
    expect(projected("wrong-call")).not.toHaveProperty("display");
  });

  it("exports the complete canonical JSONL tree including abandoned branches", async () => {
    const fixture = await coldFixture("complete-jsonl-export");
    await fixture.registry.initializeBlobStorage();
    fixture.manager.appendMessage({ role: "user", content: "root prompt", timestamp: Date.now() });
    const rootEntry = fixture.manager.getEntries().at(-1)!;
    fixture.manager.appendMessage(fauxAssistantMessage("abandoned branch response"));
    const abandonedEntry = fixture.manager.getEntries().at(-1)!;
    fixture.manager.branch(rootEntry.id);
    fixture.manager.appendMessage(fauxAssistantMessage("active branch response"));
    const activeEntry = fixture.manager.getEntries().at(-1)!;

    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const artifact = await slot.export("jsonl");
    const lease = await fixture.registry.acquireBlob(artifact.blobId);
    let exported = "";
    try {
      for await (const chunk of lease.stream) exported += Buffer.from(chunk).toString("utf8");
    } finally {
      await lease.release();
    }

    const lines = exported.trimEnd().split("\n").map((line) => JSON.parse(line) as {
      id?: string;
      parentId?: string | null;
    });
    expect(lines.some((entry) => entry.id === abandonedEntry.id && entry.parentId === rootEntry.id)).toBe(true);
    expect(lines.some((entry) => entry.id === activeEntry.id && entry.parentId === rootEntry.id)).toBe(true);
    expect(exported).toContain("abandoned branch response");
    expect(exported).toContain("active branch response");
  });

  it("round-trips canonical context edits through Gateway JSONL export/import without a chat row", async () => {
    const fixture = await coldFixture("context-edit-jsonl-roundtrip");
    await fixture.registry.initializeBlobStorage();
    const prompt = fixture.manager.appendMessage({ role: "user", content: "Original authored prompt", timestamp: Date.now() });
    const edit = fixture.manager.appendContextEdit(prompt, { content: "Replacement model context" });
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const exportedArtifact = await slot.export("jsonl");
    const lease = await fixture.registry.acquireBlob(exportedArtifact.blobId);
    let exported = "";
    try {
      for await (const chunk of lease.stream) exported += Buffer.from(chunk).toString("utf8");
    } finally {
      await lease.release();
    }
    const records = exported.trimEnd().split("\n").map(line => JSON.parse(line) as Record<string, unknown>);
    expect(records.some(entry => entry.type === "context_edit" && entry.id === edit
      && (entry.replacement as { content?: string })?.content === "Replacement model context")).toBe(true);
    const importPath = join(fixture.root, "context-edit-export.jsonl");
    await writeFile(importPath, exported);
    const sourceId = slot.id;
    const sourceEntries = fixture.manager.getBranch().map(entry => ({ id: entry.id, parentId: entry.parentId }));
    const imported = await fixture.registry.importFromJsonl(importPath, fixture.cwd);
    const importedAgain = await fixture.registry.importFromJsonl(importPath, fixture.cwd);
    expect(imported.id).not.toBe(sourceId);
    expect(importedAgain.id).not.toBe(sourceId);
    expect(importedAgain.id).not.toBe(imported.id);
    expect((await fixture.registry.acquire(sourceId)).id).toBe(sourceId);
    for (const importedSlot of [imported, importedAgain]) {
      const manager = (importedSlot as unknown as { sessionManager: SessionManager }).sessionManager;
      expect(manager.getBranch().some(entry => entry.type === "context_edit" && entry.targetId === prompt)).toBe(true);
      expect(manager.getBranch().slice(0, sourceEntries.length).map(entry => ({ id: entry.id, parentId: entry.parentId }))).toEqual(sourceEntries);
      expect(manager.buildSessionContext().messages.filter(message => message.role === "user").map(message =>
        message.role === "user" ? message.content : "")).toEqual(["Replacement model context"]);
      expect(importedSlot.snapshot().transcript.filter(item => item.role === "user")).toMatchObject([
        { content: [{ type: "text", text: "Original authored prompt" }] },
      ]);
      expect(importedSlot.snapshot().transcript.some(item => item.id === edit)).toBe(false);
    }
    const sessionRoot = join(fixture.agentDir, "sessions");
    const beforeFailure = (await readdir(sessionRoot, { recursive: true })).sort();
    vi.spyOn(fixture.registry as any, "dependencies").mockImplementationOnce(() => {
      throw new Error("injected import runtime setup failure");
    });
    await expect(fixture.registry.importFromJsonl(importPath, fixture.cwd)).rejects.toThrow("injected import runtime setup failure");
    expect((await readdir(sessionRoot, { recursive: true })).sort()).toEqual(beforeFailure);

    const importedFiles = [imported, importedAgain].map(importedSlot => importedSlot.sessionFile!);
    await Promise.all([imported.dispose(), importedAgain.dispose()]);
    await rm(importPath);
    for (const importedFile of importedFiles) {
      const reopened = SessionManager.open(importedFile, dirname(importedFile), fixture.cwd);
      expect(reopened.getHeader().parentSession).toBe(importPath);
      expect(reopened.buildSessionContext().messages.filter(message => message.role === "user").map(message =>
        message.role === "user" ? message.content : "")).toEqual(["Replacement model context"]);
      expect(reopened.getBranch().some(entry => entry.type === "context_edit" && entry.targetId === prompt)).toBe(true);
    }
  });

  it("exports a committed JSONL cut while the live session phase is running", async () => {
    const fixture = await coldFixture("active-jsonl-export");
    await fixture.registry.initializeBlobStorage();
    fixture.manager.appendMessage({ role: "user", content: "committed before export", timestamp: Date.now() });
    fixture.manager.appendMessage(fauxAssistantMessage("committed response"));
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as { phase: "running" | "idle" };
    internal.phase = "running";
    try {
      const artifact = await slot.export("jsonl");
      expect(artifact.size).toBeGreaterThan(0);
      const lease = await fixture.registry.acquireBlob(artifact.blobId);
      let exported = "";
      try {
        for await (const chunk of lease.stream) exported += Buffer.from(chunk).toString("utf8");
      } finally {
        await lease.release();
      }
      expect(exported).toContain("committed before export");
      expect(exported).toContain("committed response");
      expect(exported.endsWith("\n")).toBe(true);
    } finally {
      internal.phase = "idle";
    }
  });

  it("fails closed instead of projecting over an existing empty canonical file", async () => {
    const fixture = await coldFixture("empty-canonical-export");
    await fixture.registry.initializeBlobStorage();
    const source = fixture.manager.getSessionFile();
    expect(source).toBeDefined();
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    await writeFile(source!, "");
    await expect(slot.export("jsonl")).rejects.toMatchObject({
      code: "conflict",
      message: expect.stringContaining("empty"),
    });
  });

  it("renders HTML from an immutable cut without requiring the live session to become idle", async () => {
    const fixture = await coldFixture("active-html-export");
    await fixture.registry.initializeBlobStorage();
    const branchRoot = fixture.manager.getEntries().at(-1)!;
    fixture.manager.appendMessage(fauxAssistantMessage("abandoned html branch"));
    fixture.manager.branch(branchRoot.id);
    fixture.manager.appendMessage({ role: "user", content: "html snapshot marker", timestamp: Date.now() });
    fixture.manager.appendMessage({ role: "custom_message", customType: "hidden-export-marker", content: "hidden custom export marker", display: false, timestamp: Date.now() });
    fixture.manager.appendMessage(fauxAssistantMessage("html snapshot response"));
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as { phase: "running" | "idle" };
    internal.phase = "running";
    try {
      const artifact = await slot.export("html");
      expect(artifact.mimeType).toContain("text/html");
      const lease = await fixture.registry.acquireBlob(artifact.blobId);
      let exported = "";
      try {
        for await (const chunk of lease.stream) exported += Buffer.from(chunk).toString("utf8");
      } finally {
        await lease.release();
      }
      expect(exported).toContain("<!DOCTYPE html>");
      expect(Buffer.byteLength(exported)).toBe(artifact.size);
      const encoded = exported.match(/<script id="session-data" type="application\/json">([^<]+)<\/script>/)?.[1];
      expect(encoded).toBeDefined();
      const sessionData = Buffer.from(encoded!, "base64").toString("utf8");
      expect(sessionData).toContain("html snapshot marker");
      expect(sessionData).toContain("html snapshot response");
      expect(sessionData).toContain("hidden custom export marker");
      expect(exported).toContain("const hidden = entry.display === false");
      expect(exported).toContain("hook-message-hidden");
      expect(exported).toContain("Hidden in terminal");
      expect(sessionData).not.toContain("abandoned html branch");
      const artifactPath = join(process.cwd(), "test-results", "pi-sdk-099-html-export.json");
      await mkdir(dirname(artifactPath), { recursive: true });
      await writeFile(artifactPath, `${JSON.stringify({ format: "html", mimeType: artifact.mimeType, size: artifact.size, visibleMarkers: ["html snapshot marker", "html snapshot response"], hiddenMarkerRenderedHidden: exported.includes('class="hook-message hook-message-hidden"'), abandonedBranchOmitted: !sessionData.includes("abandoned html branch") }, null, 2)}\n`);
    } finally {
      internal.phase = "idle";
    }
  }, 30_000);

  it("keeps session exports independent from the 25 MiB transient media item limit", async () => {
    const fixture = await coldFixture("large-jsonl-export");
    await fixture.registry.initializeBlobStorage();
    fixture.manager.appendCustomEntry("large-export-fixture", {
      payload: "x".repeat(26 * 1_024 * 1_024),
    });
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const artifact = await slot.export("jsonl");
    expect(artifact.size).toBeGreaterThan(25 * 1_024 * 1_024);
    const lease = await fixture.registry.acquireBlob(artifact.blobId);
    let bytes = 0;
    try {
      for await (const chunk of lease.stream) bytes += Buffer.byteLength(chunk);
    } finally {
      await lease.release();
    }
    expect(bytes).toBe(artifact.size);
  }, 30_000);

  it("routes virtual models across resume, fork, retry and compaction in a RuntimeRegistry session", async () => {
    const fixture = await coldFixture("virtual-model-lifecycle");
    const provider = "tron-p99-virtual-lifecycle";
    await mkdir(join(fixture.cwd, ".pi", "extensions"), { recursive: true });
    await writeFile(join(fixture.cwd, ".pi", "extensions", "virtual-router.ts"), `
      export default function (pi) {
        pi.registerVirtualModel({
          provider: ${JSON.stringify(provider)}, id: "router", name: "Fixture router", contextWindow: 1,
          route(request, ctx) {
            const routeCount = request.state?.routeCount ?? 0;
            const useWide = request.reason === "direct" || Boolean(request.failed) || routeCount % 2 === 1;
            const physical = ctx.modelRegistry.find(${JSON.stringify(provider)}, useWide ? "wide" : "small");
            return { model: physical, thinkingLevel: useWide ? "high" : "low",
              state: { routeCount: routeCount + 1, lastReason: request.reason, lastModel: physical.id, failed: Boolean(request.failed) } };
          },
        });
      }
    `);
    await new TrustService(fixture.agentDir).set(fixture.cwd, true);
    await writeFile(join(fixture.agentDir, "settings.json"), JSON.stringify({ retry: { enabled: true, maxRetries: 2, baseDelayMs: 1 }, compaction: { enabled: false, keepRecentTokens: 1 } }));
    const faux = fauxProvider({ provider, tokensPerSecond: 10_000, models: [
      { id: "small", name: "Small physical", reasoning: true, input: ["text"], contextWindow: 4096, maxTokens: 1024, cost: { input: 1, output: 2, cacheRead: 0, cacheWrite: 0 } },
      { id: "wide", name: "Wide physical", reasoning: true, input: ["text"], contextWindow: 16384, maxTokens: 2048, cost: { input: 3, output: 4, cacheRead: 0, cacheWrite: 0 } },
    ] });
    const responseModels: string[] = [];
    const response = (text: string) => (_context: unknown, _options: unknown, _state: unknown, model: any) => {
      responseModels.push(model.id);
      return fauxAssistantMessage(text, { provider: model.provider, model: model.id });
    };
    faux.setResponses([
      fauxAssistantMessage("", { stopReason: "error", errorMessage: "fetch failed" }),
      response("retried on physical wide"),
      response("continued on physical small"),
      response("alternate physical wide"),
      response("compact summary on physical wide"),
      response("after compaction on virtual"),
      ...Array.from({ length: 5 }, (_, index) => response(`post-compaction continuation ${index + 1}`)),
    ]);
    const modelRuntime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    modelRuntime.registerNativeProvider(faux.provider);
    fixture.runtimeFactory.mockResolvedValue(modelRuntime);
    let slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    await slot.setModel(provider, "router");
    await slot.prompt("trigger automatic retry");
    await waitFor(() => !slot!.isBusy, "the slot to go idle");
    const retried = slot.snapshot().transcript.filter((item) => item.kind === "message" && item.role === "assistant");
    expect(retried.at(-1)).toMatchObject({ provider, modelId: "wide", thinkingLevel: "high" });
    expect(faux.state.callCount).toBe(2);

    const branchEntries = slot.runtime.session.sessionManager.getBranch();
    expect(branchEntries.some((entry: any) => entry.type === "custom" && entry.customType === "pi.virtual-model-state")).toBe(true);
    const userEntry = slot.history(slot.snapshot().runtimeGeneration).nodes.find((node: any) => node.role === "user");
    expect(userEntry).toBeDefined();
    await fixture.registry.dispose();
    registries.splice(registries.indexOf(fixture.registry), 1);
    const resumedRegistry = await createTestRegistry({
      agentDir: fixture.agentDir, tronHome: join(fixture.root, "tron"), idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => { const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }); runtime.registerNativeProvider(faux.provider); return runtime; },
      trust: new TrustService(fixture.agentDir), broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(resumedRegistry);
    await initializeRegistry(resumedRegistry);
    slot = await resumedRegistry.acquire(fixture.manager.getSessionId());
    expect(slot.runtime.session.model?.id).toBe("router");
    expect(slot.snapshot().transcript.some((item) => item.kind === "message" && item.role === "assistant" && item.provider === provider && item.modelId === "wide" && item.thinkingLevel === "high")).toBe(true);
    expect(slot.runtime.session.sessionManager.getBranch().some((entry: any) => entry.type === "custom" && entry.customType === "pi.virtual-model-state")).toBe(true);
    const restoredState = slot.runtime.session.sessionManager.getBranch().filter((entry: any) => entry.type === "custom" && entry.customType === "pi.virtual-model-state");
    expect(restoredState.length).toBeGreaterThan(0);
    expect(restoredState.at(-1)).toMatchObject({ data: { state: { routeCount: 2, lastReason: "retry", lastModel: "wide", failed: true } } });

    const forkPoint = slot.runtime.session.sessionManager.getLeafId();
    const fork = await slot.fork(forkPoint!, "at");
    const forkSlot = await resumedRegistry.acquire(fork.sessionId);
    const forkRouterState = forkSlot.runtime.session.sessionManager.getBranch().filter((entry: any) => entry.type === "custom" && entry.customType === "pi.virtual-model-state");
    expect(forkRouterState.at(-1)?.data).toEqual(restoredState.at(-1)?.data);
    await forkSlot.prompt("fork continues through router");
    await waitFor(() => !forkSlot.isBusy, "the forked slot to go idle");
    expect(forkSlot.snapshot().transcript.filter((item) => item.kind === "message" && item.role === "assistant").at(-1)).toMatchObject({ provider, modelId: "small", thinkingLevel: "low" });

    await slot.setModel(provider, "router");
    await slot.prompt(`route to the alternate physical model ${"context ".repeat(5000)}`);
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    expect(slot.snapshot().transcript.filter((item) => item.kind === "message" && item.role === "assistant").at(-1)).toMatchObject({ provider, modelId: "wide", thinkingLevel: "high" });
    expect(slot.snapshot().contextUsage?.contextWindow).toBe(16384);
    await slot.compact("keep the router selection");
    await slot.prompt("after compaction");
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    expect(slot.runtime.session.model?.id).toBe("router");
    const postCompactionAssistant = slot.snapshot().transcript.filter((item) => item.kind === "message" && item.role === "assistant").at(-1);
    expect(postCompactionAssistant).toMatchObject({ provider, modelId: responseModels.at(-1), stopReason: "stop" });
    expect(responseModels.slice(0, 4)).toEqual(["wide", "small", "wide", "wide"]);
    expect(responseModels.length).toBeGreaterThan(4);
    expect(slot.snapshot().contextUsage?.contextWindow).toBe(4096);
    const artifactPath = join(process.cwd(), "test-results", "pi-sdk-099-virtual-lifecycle.json");
    await mkdir(join(process.cwd(), "test-results"), { recursive: true });
    await writeFile(artifactPath, `${JSON.stringify({ selectedModel: slot.runtime.session.model?.id, retry: { calls: faux.state.callCount, assistant: retried.at(-1), persistedState: restoredState.at(-1)?.data }, resumed: { model: "router", stateEntries: restoredState.length }, fork: { sessionId: fork.sessionId, routerState: forkRouterState.at(-1)?.data }, responseModels, routedRows: slot.snapshot().transcript.filter((item) => item.kind === "message" && item.role === "assistant"), contextUsage: slot.snapshot().contextUsage, compacted: slot.snapshot().transcript.some((item) => item.kind === "compaction") }, null, 2)}\n`);
  }, 60_000);

  it("projects resumed retry attempts as running before their assistant response completes", async () => {
    const fixture = await coldFixture("retry-resumption");
    await writeFile(join(fixture.agentDir, "settings.json"), JSON.stringify({
      retry: { enabled: true, maxRetries: 3, baseDelayMs: 1 },
    }));
    const faux = fauxProvider({ provider: "tron-retry-resumption", tokensPerSecond: 10_000 });
    let releaseResponse!: () => void;
    const responseBarrier = new Promise<void>((resolve) => { releaseResponse = resolve; });
    let resumed = false;
    faux.setResponses([
      fauxAssistantMessage("", { stopReason: "error", errorMessage: "fetch failed" }),
      async () => {
        resumed = true;
        await responseBarrier;
        return fauxAssistantMessage("Continued successfully");
      },
    ]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    fixture.runtimeFactory.mockResolvedValue(runtime);
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    subscribeAudience(fixture.registry, slot.id);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    try {
      await slot.prompt("Exercise one transient provider failure");
      await waitFor(() => resumed, "the resumed turn");
      expect(faux.state.callCount).toBe(2);
      expect(fixture.events.some(({ topic, payload }) => topic === "session.snapshot"
        && payload.phase === "retrying" && payload.retry?.attempt === 1)).toBe(true);
      const resumedSnapshot = slot.snapshot();
      expect(resumedSnapshot.phase).toBe("running");
      expect(resumedSnapshot.retry).toMatchObject({ source: "agent", attempt: 1 });
      expect((await fixture.registry.acquire(slot.id)).snapshot().phase).toBe("running");
    } finally {
      releaseResponse();
    }
    await waitFor(() => slot.snapshot().phase === "idle", "the idle phase");
    expect(slot.snapshot().retry).toBeUndefined();
  });

  it("drains branch summarization through exact SDK settlement", async () => {
    const { manager, registry } = await coldFixture("branch-summary-drain");
    const slot = await registry.acquire(manager.getSessionId());
    let release!: () => void;
    const barrier = new Promise<void>((resolve) => { release = resolve; });
    const session = (slot as unknown as {
      runtime: { session: { navigateTree: (...arguments_: unknown[]) => Promise<{ cancelled: boolean }> } };
    }).runtime.session;
    const navigate = vi.spyOn(session, "navigateTree").mockImplementation(async () => {
      await barrier;
      return { cancelled: false };
    });
    const navigating = slot.navigate("target", { summarize: true });
    await waitFor(() => navigate.mock.calls.length === 1, "the navigation");
    let drained = false;
    const drain = registry.waitUntilIdle().then(() => { drained = true; });
    await new Promise((resolve) => setTimeout(resolve, 25));
    expect(drained).toBe(false);
    release();
    await navigating;
    await drain;
    expect(drained).toBe(true);
  });

  it("drains extension resource reload through exact loader settlement", async () => {
    const { manager, registry } = await coldFixture("resource-reload-drain");
    const slot = await registry.acquire(manager.getSessionId());
    let release!: () => void;
    const barrier = new Promise<void>((resolve) => { release = resolve; });
    const loader = (slot as unknown as {
      runtime: { session: { resourceLoader: { reload: (...arguments_: unknown[]) => Promise<void> } } };
    }).runtime.session.resourceLoader;
    const reload = vi.spyOn(loader, "reload").mockImplementation(async () => { await barrier; });
    const reloading = slot.reload();
    await waitFor(() => reload.mock.calls.length === 1, "the reload");
    let drained = false;
    const drain = registry.waitUntilIdle().then(() => { drained = true; });
    await new Promise((resolve) => setTimeout(resolve, 25));
    expect(drained).toBe(false);
    release();
    await reloading;
    await drain;
    expect(drained).toBe(true);
  });

  it("clears branch-summary operation state when tree navigation rejects or is cancelled", async () => {
    const root = await temporaryRoot("tron-navigation-cleanup-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    const snapshots: Array<{ phase: string; operation?: { kind: string }; retry?: unknown }> = [];
    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime,
      trust: new TrustService(agentDir),
      broadcast: (_sessionId, topic, payload) => {
        if (topic === "session.snapshot") snapshots.push(payload as { phase: string; operation?: { kind: string }; retry?: unknown });
      },
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    subscribeAudience(registry, slot.id);
    const session = (slot as unknown as {
      runtime: { session: { navigateTree: (targetId: string, options: unknown) => Promise<{ cancelled: boolean }> } };
    }).runtime.session;
    const navigate = vi.spyOn(session, "navigateTree");

    navigate.mockRejectedValueOnce(new Error("navigation failed"));
    await expect(slot.navigate("target", { summarize: true })).rejects.toThrow("navigation failed");
    expect(slot.snapshot()).toMatchObject({ phase: "idle" });
    expect(slot.snapshot().operation).toBeUndefined();
    expect(slot.snapshot().retry).toBeUndefined();

    navigate.mockResolvedValueOnce({ cancelled: true });
    await expect(slot.navigate("target", { summarize: true })).rejects.toMatchObject({ code: "cancelled" });
    expect(slot.snapshot().operation).toBeUndefined();
    expect(slot.snapshot().retry).toBeUndefined();
    expect(snapshots.length).toBeGreaterThan(0);
    expect(snapshots.at(-1)?.operation).toBeUndefined();
  });

  it("persists fast foreground skill and prompt bindings without operation failures", async () => {
    const root = await temporaryRoot("tron-skill-binding-receipt-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([
      mkdir(join(agentDir, "skills", "review"), { recursive: true }),
      mkdir(join(agentDir, "prompts"), { recursive: true }),
      mkdir(cwd),
    ]);
    await Promise.all([
      writeFile(join(agentDir, "skills", "review", "SKILL.md"),
        "---\nname: review\ndescription: Review carefully\n---\nReview the requested change.\n"),
      writeFile(join(agentDir, "prompts", "summarize.md"),
        "---\ndescription: Summarize carefully\n---\nSummarize $ARGUMENTS\n"),
    ]);
    const failures: unknown[] = [];
    const snapshots: any[] = [];
    const faux = fauxProvider({ provider: "tron-skill-binding", tokensPerSecond: 10_000 });
    faux.setResponses([fauxAssistantMessage("skill complete"), fauxAssistantMessage("prompt complete")]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const registry = await createTestRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime, trust: new TrustService(agentDir),
      broadcast: (_sessionId, topic, payload) => {
        if (topic === "session.operationFailed") failures.push(payload);
        if (topic === "session.snapshot") snapshots.push(payload);
      },
      sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    subscribeAudience(registry, slot.id);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await expect(slot.prompt("configurations", [], undefined, {
      text: "configurations",
      resourceInvocations: [{ source: "skill", name: "review", arguments: "" }],
      attachmentEnvelope: "", attachmentCount: 0,
    })).resolves.toEqual({ operationId: expect.any(String) });
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    const entries = (await readFile(slot.sessionFile!, "utf8")).trimEnd().split("\n").map(line => JSON.parse(line) as any);
    let receipts = entries.filter(entry => entry.customType === INVOCATION_RECEIPT_TYPE).map(entry => entry.data);
    expect(receipts.map(receipt => receipt.receiptKind)).toEqual(["start", "transition", "binding", "terminal"]);
    expect(receipts.find(receipt => receipt.receiptKind === "binding")).not.toHaveProperty("name");
    expect(snapshots.some(snapshot => snapshot.pendingPrompt?.resourceInvocations?.[0]?.name === "review")).toBe(true);
    expect(slot.snapshot().transcript.some(item => item.semantic?.resourceInvocations?.[0]?.name === "review")).toBe(true);

    await expect(slot.prompt("configurations", [], undefined, {
      text: "configurations",
      resourceInvocations: [{ source: "prompt", name: "summarize", arguments: "" }],
      attachmentEnvelope: "", attachmentCount: 0,
    })).resolves.toEqual({ operationId: expect.any(String) });
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    const allEntries = (await readFile(slot.sessionFile!, "utf8")).trimEnd().split("\n").map(line => JSON.parse(line) as any);
    receipts = allEntries.filter(entry => entry.customType === INVOCATION_RECEIPT_TYPE).map(entry => entry.data);
    const promptReceipts = receipts.filter(receipt => receipt.source === "prompt");
    expect(promptReceipts.map(receipt => receipt.receiptKind)).toEqual(["start", "transition", "binding", "terminal"]);
    expect(promptReceipts.find(receipt => receipt.receiptKind === "binding")).not.toHaveProperty("name");
    expect(slot.snapshot().transcript.some(item => item.semantic?.resourceInvocations?.[0]?.name === "summarize")).toBe(true);
    expect(failures).toEqual([]);
  });

  it("records interruption intent before fast SDK settlement", async () => {
    const root = await temporaryRoot("tron-abort-invocation-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    let release!: () => void;
    const responseBarrier = new Promise<void>((resolve) => { release = resolve; });
    let agentEntered!: () => void;
    const agentAdmitted = new Promise<void>((resolve) => { agentEntered = resolve; });
    const faux = fauxProvider({ provider: "tron-abort-invocation", tokensPerSecond: 10_000 });
    faux.setResponses([async () => { agentEntered(); await responseBarrier; return fauxAssistantMessage("should not complete"); }]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const registry = await createTestRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime, trust: new TrustService(agentDir),
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const prompt = slot.prompt("interrupt me");
    await agentAdmitted;
    const aborting = slot.abort("agent");
    release();
    await aborting;
    await expect(prompt).resolves.toEqual({ operationId: expect.any(String) });
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    const entries = (await readFile(slot.sessionFile!, "utf8")).trimEnd().split("\n").map(line => JSON.parse(line) as any);
    const terminal = entries.find(entry => entry.customType === INVOCATION_RECEIPT_TYPE && entry.data?.receiptKind === "terminal");
    expect(terminal?.data).toMatchObject({ lifecycle: "interrupted" });
  });

  it("joins a completed run's settlement chain before dispose resolves", async () => {
    const root = await temporaryRoot("tron-dispose-settlement-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const faux = fauxProvider({ provider: "tron-dispose-settlement", tokensPerSecond: 10_000 });
    faux.setResponses([fauxAssistantMessage("completed before dispose")]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const registry = await createTestRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime, trust: new TrustService(agentDir),
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const internal = (slot as unknown as { runInvocations: { persistInvocationTerminal(...args: unknown[]): Promise<unknown> } }).runInvocations;
    const terminalize = internal.persistInvocationTerminal.bind(internal);
    let releaseTerminal!: () => void;
    const terminalGate = new Promise<void>((resolve) => { releaseTerminal = resolve; });
    let held = 0;
    const spy = vi.spyOn(internal, "persistInvocationTerminal").mockImplementation(async (...args) => {
      if (held++ === 0) await terminalGate;
      return terminalize(...args);
    });
    let disposed = false;
    let disposal: Promise<void> | undefined;
    try {
      void slot.prompt("complete normally").catch(() => {});
      await waitFor(() => held > 0, "the completed run's settlement chain to start");
      disposal = registry.dispose().then(() => { disposed = true; });
      await new Promise((resolve) => setTimeout(resolve, 100));
      expect(disposed, "dispose resolved while the settlement chain was still pending").toBe(false);
    } finally {
      releaseTerminal();
    }
    await disposal;
    spy.mockRestore();
    const markerPath = join(root, "tron", "state", "runtime-markers", `${slot.id}.json`);
    const markerAtDispose = existsSync(markerPath) ? readFileSync(markerPath, "utf8") : undefined;
    await new Promise((resolve) => setTimeout(resolve, 100));
    expect(existsSync(markerPath) ? readFileSync(markerPath, "utf8") : undefined, "a marker write landed after dispose").toEqual(markerAtDispose);
  });

  it("records completed when SDK Stop fails before cancellation and the real run finishes naturally", async () => {
    const root = await temporaryRoot("tron-abort-failed-stop-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    let release!: () => void;
    const responseBarrier = new Promise<void>((resolve) => { release = resolve; });
    let agentEntered!: () => void;
    const agentAdmitted = new Promise<void>((resolve) => { agentEntered = resolve; });
    const faux = fauxProvider({ provider: "tron-abort-failed-stop", tokensPerSecond: 10_000 });
    faux.setResponses([async () => { agentEntered(); await responseBarrier; return fauxAssistantMessage("completed on its own"); }]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const registry = await createTestRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime, trust: new TrustService(agentDir),
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const prompt = slot.prompt("finish on its own");
    await agentAdmitted;
    const session = (slot as unknown as { runtime: { session: { abort(): Promise<void> } } }).runtime.session;
    const sdkAbort = session.abort.bind(session);
    session.abort = async () => { throw new Error("abort refused"); };
    try {
      await expect(slot.abort("agent")).rejects.toThrow(/did not stop/);
    } finally {
      session.abort = sdkAbort;
      release();
      await prompt;
    }
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    const entries = (await readFile(slot.sessionFile!, "utf8")).trimEnd().split("\n").map(line => JSON.parse(line) as any);
    const terminals = entries.filter(entry => entry.customType === INVOCATION_RECEIPT_TYPE && entry.data?.receiptKind === "terminal");
    expect(terminals).toHaveLength(1);
    await mkdir("test-results", { recursive: true });
    await writeFile("test-results/failed-stop-natural-completion.json", JSON.stringify({
      lifecycle: terminals[0]?.data.lifecycle, errorCode: terminals[0]?.data.errorCode ?? null,
    }, null, 2));
    expect(terminals[0]?.data).toMatchObject({ lifecycle: "completed" });
    expect(terminals[0]?.data.errorCode).toBeUndefined();
  });

  it("records a completed receipt for a Stop that arrives after a natural completion", async () => {
    const root = await temporaryRoot("tron-abort-after-completion-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const faux = fauxProvider({ provider: "tron-abort-after-completion", tokensPerSecond: 10_000 });
    faux.setResponses([fauxAssistantMessage("finished before Stop")]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const registry = await createTestRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime, trust: new TrustService(agentDir),
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const { operationId } = await slot.prompt("finish first");
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    await slot.abort("agent");
    const entries = (await readFile(slot.sessionFile!, "utf8")).trimEnd().split("\n").map(line => JSON.parse(line) as any);
    const terminals = entries.filter(entry => entry.customType === INVOCATION_RECEIPT_TYPE && entry.data?.receiptKind === "terminal" && entry.data.operationId === operationId);
    expect(terminals).toHaveLength(1);
    expect(terminals[0]?.data).toMatchObject({ lifecycle: "completed" });
    expect(terminals[0]?.data).not.toHaveProperty("errorCode");
  });

  it("projects and atomically manages multiple queued messages by stable identity", async () => {
    const root = await temporaryRoot("tron-queue-management-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const skillDir = join(agentDir, "skills", "review");
    const extensionDir = join(cwd, ".pi", "extensions");
    await Promise.all([mkdir(skillDir, { recursive: true }), mkdir(extensionDir, { recursive: true })]);
    await writeFile(join(extensionDir, "handled-queue.ts"), `export default function (pi) {
      pi.on("input", (event) => event.text === "handled during rebuild" ? { action: "handled" } : undefined);
    }\n`);
    await writeFile(
      join(skillDir, "SKILL.md"),
      "---\nname: review\ndescription: Review carefully\n---\nReview the requested change.\n",
    );

    let releaseResponse!: () => void;
    const responseBarrier = new Promise<void>((resolve) => { releaseResponse = resolve; });
    const faux = fauxProvider({ provider: "tron-queue-management", tokensPerSecond: 10_000 });
    faux.setResponses([
      async () => {
        await responseBarrier;
        return fauxAssistantMessage("initial complete");
      },
      fauxAssistantMessage("queued complete"),
      fauxAssistantMessage("follow-up complete"),
    ]);
    const createModels = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: createModels,
      trust,
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("start");
    await waitFor(() => slot.isBusy, "the slot to take work");

    const oversizedDescriptors = Array.from({ length: 11 }, (_, index) => ({
      id: `upload-${index}`, name: `file-${index}.txt`, mimeType: "text/plain", size: 1,
    }));
    await expect(slot.prompt("invalid", [], "steer", {
      text: "invalid",
      attachmentEnvelope: "",
      attachmentCount: oversizedDescriptors.length,
      attachments: oversizedDescriptors,
    })).rejects.toMatchObject({ code: "invalid_request" });

    const attachment = {
      id: "upload:00000000-0000-4000-8000-000000000001",
      name: "notes.txt", mimeType: "text/plain", size: 4,
    };
    await slot.prompt("first steer", [], "steer", {
      text: "first steer",
      attachmentEnvelope: '<attachment name="notes.txt" />',
      attachmentCount: 1,
      photoCount: 0,
      fileAttachmentCount: 1,
      attachments: [attachment],
    });
    await slot.prompt("first steer", [], "steer", {
      text: "first steer",
      attachmentEnvelope: "",
      attachmentCount: 0,
    });
    await slot.prompt("later follow-up", [], "followUp", {
      text: "later follow-up",
      attachmentEnvelope: "",
      attachmentCount: 0,
    });
    await slot.prompt("queued skill", [], "steer", {
      text: "queued skill",
      resourceInvocations: [{ source: "skill", name: "review", arguments: "" }],
      attachmentEnvelope: "",
      attachmentCount: 0,
    });
    const queued = slot.snapshot();
    expect(queued.queuedItems).toHaveLength(4);
    expect(queued.queuedItems.map((item) => item.behavior)).toEqual(["steer", "steer", "steer", "followUp"]);
    expect(queued.queuedItems.map((item) => item.text)).toEqual([
      "first steer", "first steer", "queued skill", "later follow-up",
    ]);
    expect(new Set(queued.queuedItems.map((item) => item.id)).size).toBe(4);
    expect(queued.queuedItems[0]?.attachments).toEqual([attachment]);

    const [first, duplicate, skill, followUp] = queued.queuedItems;
    const replaced = await slot.replaceQueue(queued.queueRevision, [
      { id: duplicate!.id, behavior: "steer", text: duplicate!.text },
      { id: followUp!.id, behavior: "steer", text: "edited and earlier" },
      { id: first!.id, behavior: "followUp", text: first!.text },
      { id: skill!.id, behavior: "followUp", text: "edited skill" },
    ]);
    expect(replaced.items.map(({ id, behavior, text }) => ({ id, behavior, text }))).toEqual([
      { id: duplicate!.id, behavior: "steer", text: "first steer" },
      { id: followUp!.id, behavior: "steer", text: "edited and earlier" },
      { id: first!.id, behavior: "followUp", text: "first steer" },
      { id: skill!.id, behavior: "followUp", text: "edited skill" },
    ]);
    expect(replaced.items[2]?.attachments).toEqual([attachment]);
    expect(replaced.items[3]?.resourceInvocations).toEqual([{ source: "skill", name: "review", arguments: "" }]);
    const afterEditEntries = (slot as any).runtime.session.sessionManager.getEntries() as any[];
    const skillInvocationReceipts = afterEditEntries.filter(entry => entry.customType === INVOCATION_RECEIPT_TYPE
      && entry.data?.operationId === skill!.id).map(entry => entry.data);
    expect(skillInvocationReceipts.filter(receipt => receipt.receiptKind === "start")
      .map(receipt => receipt.submittedText)).toEqual(["queued skill", "edited skill"]);
    expect(skillInvocationReceipts.some(receipt => receipt.receiptKind === "terminal"
      && receipt.lifecycle === "interrupted" && receipt.errorCode === "queue-edited")).toBe(true);
    const queuedRuntime = (slot as unknown as {
      runtime: { session: { getFollowUpMessages(): readonly string[] } };
    }).runtime.session.getFollowUpMessages();
    expect(queuedRuntime.some(
      (text) => text.startsWith('<skill name="review"') && text.endsWith("edited skill"),
    )).toBe(true);
    await expect(slot.replaceQueue(queued.queueRevision, [])).rejects.toMatchObject({ code: "conflict" });

    const handledReplacement = await slot.replaceQueue(replaced.queueRevision, [
      { ...replaced.items[1]!, text: "handled during rebuild" },
      replaced.items[0]!,
    ]);
    expect(handledReplacement.items.map(({ id }) => id)).toEqual([duplicate!.id]);
    const afterHandledRebuild = (slot as any).runtime.session.sessionManager.getEntries() as any[];
    expect(afterHandledRebuild.some(entry => entry.customType === INVOCATION_RECEIPT_TYPE
      && entry.data?.operationId === followUp!.id
      && entry.data?.receiptKind === "terminal"
      && entry.data?.lifecycle === "completed")).toBe(true);
    expect(afterHandledRebuild.some(entry => entry.customType === INVOCATION_RECEIPT_TYPE
      && entry.data?.operationId === skill!.id
      && entry.data?.receiptKind === "terminal"
      && entry.data?.lifecycle === "interrupted")).toBe(true);

    await slot.clearQueue();
    expect(slot.snapshot().queuedItems).toEqual([]);
    const afterClearEntries = (slot as any).runtime.session.sessionManager.getEntries() as any[];
    expect(afterClearEntries.some(entry => entry.customType === INVOCATION_RECEIPT_TYPE
      && entry.data?.operationId === duplicate!.id
      && entry.data?.receiptKind === "terminal"
      && entry.data?.lifecycle === "interrupted"
      && entry.data?.errorCode === "queue-cleared")).toBe(true);
    await expect(slot.replaceQueue(handledReplacement.queueRevision, []))
      .rejects.toMatchObject({ code: "conflict" });

    releaseResponse();
    await waitFor(() => !slot.isBusy, "the slot to go idle");
  });

  it("queues one manual compaction behind an active run and keeps its receipt pending", async () => {
    const root = await temporaryRoot("tron-queued-compaction-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);

    let releaseResponse!: () => void;
    const responseBarrier = new Promise<void>((resolve) => { releaseResponse = resolve; });
    let releaseCompaction!: () => void;
    const compactionBarrier = new Promise<void>((resolve) => { releaseCompaction = resolve; });
    const faux = fauxProvider({ provider: "tron-queued-compaction", tokensPerSecond: 10_000 });
    faux.setResponses([async () => {
      await responseBarrier;
      return fauxAssistantMessage("run complete");
    }]);
    const createModels = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: createModels,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const session = (slot as unknown as {
      runtime: { session: { compact: (instructions?: string) => Promise<unknown> } };
    }).runtime.session;
    const compact = vi.spyOn(session, "compact").mockImplementation(async () => {
      await compactionBarrier;
      return {};
    });
    let releaseMarker!: () => void;
    const markerBarrier = new Promise<void>((resolve) => { releaseMarker = resolve; });
    const markerStore = (slot as unknown as { dependencies: { markers: RunMarkerStore } }).dependencies.markers;
    const originalClear = markerStore.clear.bind(markerStore);
    let promptOperationId: string;
    const clearMarker = vi.spyOn(markerStore, "clear").mockImplementation(async (sessionId, operationId) => {
      if (operationId !== promptOperationId) await markerBarrier;
      await originalClear(sessionId, operationId);
    });

    promptOperationId = (await slot.prompt("start")).operationId;
    await waitFor(() => slot.isBusy, "the slot to take work");
    const queuedCompaction = slot.compact("Preserve exact decisions");
    await waitFor(() => slot.snapshot().compactionQueued === true, "the queued compaction");

    expect(slot.snapshot()).toMatchObject({
      phase: "running",
      compactionQueued: true,
      automaticCompactionEnabled: true,
    });
    expect(registry.activeSessionIds()).toContain(slot.id);
    await expect(slot.compact()).rejects.toMatchObject({
      code: "busy",
      message: "A manual compaction is already pending for this session",
    });
    expect(compact).not.toHaveBeenCalled();

    releaseResponse();
    await waitFor(() => compact.mock.calls.length === 1, "the compaction call");
    expect(compact).toHaveBeenCalledWith("Preserve exact decisions");
    expect(slot.snapshot()).toMatchObject({ phase: "compacting", compactionQueued: false });
    expect(registry.activeSessionIds()).toContain(slot.id);

    let queuedSettled = false;
    void queuedCompaction.then(() => { queuedSettled = true; }, () => {});
    releaseCompaction();
    await waitFor(() => clearMarker.mock.calls.some(([, id]) => id !== promptOperationId), "a marker clear for another operation");
    await Promise.resolve();
    expect(queuedSettled).toBe(false);
    expect(registry.activeSessionIds()).toContain(slot.id);
    releaseMarker();
    await expect(queuedCompaction).resolves.toEqual({ queued: true });
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    expect(slot.snapshot()).toMatchObject({ phase: "idle", compactionQueued: false });
    expect(registry.activeSessionIds()).not.toContain(slot.id);
    expect(await markerStore.evidenceFor(slot.id)).toEqual([]);
  });

  it("reasserts exact marker ownership when cleanup races terminal completion stamping", async () => {
    const root = await temporaryRoot("tron-terminal-marker-race-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    let releaseResponse!: () => void;
    const responseBarrier = new Promise<void>((resolve) => { releaseResponse = resolve; });
    const faux = fauxProvider({ provider: "tron-terminal-marker-race", tokensPerSecond: 10_000 });
    faux.setResponses([
      async () => { await responseBarrier; return fauxAssistantMessage("first completion"); },
      fauxAssistantMessage("next completion"),
    ]);
    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => {
        const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
        runtime.registerNativeProvider(faux.provider);
        return runtime;
      },
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);

    const first = await slot.prompt("first");
    await waitFor(() => slot.snapshot().phase === "running", "the running phase");
    const markers = (slot as unknown as {
      dependencies: {
        markers: {
          clear: (sessionId: string, operationId?: string) => Promise<void>;
          evidenceFor: (sessionId: string) => Promise<Array<{ operationId: string }>>;
        };
      };
    }).dependencies.markers;
    await markers.clear(slot.id, first.operationId);
    expect(await markers.evidenceFor(slot.id)).toEqual([]);

    releaseResponse();
    await waitFor(() => registry.attentionProjection(slot.id).completionRevision === 1, "the first completion revision");
    await waitFor(() => slot.snapshot().phase === "idle", "the idle phase");
    await expect(slot.reconcileAttention()).resolves.toBeUndefined();
    expect(await markers.evidenceFor(slot.id)).toEqual([]);

    await expect(slot.prompt("next", [], "steer")).resolves.toEqual({
      operationId: expect.any(String),
    });
    const drain = registry.waitUntilIdle();
    await waitFor(() => registry.attentionProjection(slot.id).completionRevision === 2, "the second completion revision");
    await drain;
    expect(slot.snapshot().phase).toBe("idle");
    expect(registry.administrativeDrainSnapshot()).toMatchObject({ phase: "complete", blockerCount: 0 });
  });

  it("settles a failed completion owner so the next prompt can proceed", async () => {
    const root = await temporaryRoot("tron-attention-settlement-failure-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const faux = fauxProvider({ provider: "tron-attention-failure", tokensPerSecond: 10_000 });
    faux.setResponses([
      fauxAssistantMessage("first completion"),
      fauxAssistantMessage("must not be admitted"),
    ]);
    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => {
        const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
        runtime.registerNativeProvider(faux.provider);
        return runtime;
      },
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const attention = (registry as unknown as {
      attention: { complete: (sessionId: string, completionId: string) => Promise<unknown> };
    }).attention;
    const complete = vi.spyOn(attention, "complete").mockRejectedValue(new Error("attention persistence failed"));

    await slot.prompt("first");
    await waitFor(() => slot.snapshot().phase === "interrupted", "the interrupted phase");
    expect(complete).toHaveBeenCalledTimes(3);
    await expect(slot.prompt("second")).resolves.toMatchObject({ operationId: expect.any(String) });
    expect(complete.mock.calls.map(([, completionId]) => completionId))
      .toEqual(Array(3).fill(complete.mock.calls[0]![1]));

    complete.mockRestore();
    await slot.reconcileAttention();
    await waitFor(() => slot.snapshot().phase === "idle", "the idle phase");
    expect(registry.attentionProjection(slot.id)).toMatchObject({ completionRevision: 2, isUnread: true });
  });

  it("cleans up queued manual compaction state when canonical compaction fails", async () => {
    const root = await temporaryRoot("tron-queued-compaction-failure-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);

    let releaseResponse!: () => void;
    const responseBarrier = new Promise<void>((resolve) => { releaseResponse = resolve; });
    const faux = fauxProvider({ provider: "tron-queued-compaction-failure", tokensPerSecond: 10_000 });
    faux.setResponses([async () => {
      await responseBarrier;
      return fauxAssistantMessage("run complete");
    }]);
    const createModels = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: createModels,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const session = (slot as unknown as {
      runtime: { session: { compact: (instructions?: string) => Promise<unknown> } };
    }).runtime.session;
    vi.spyOn(session, "compact").mockRejectedValue(new Error("manual compaction failed"));

    await slot.prompt("start");
    await waitFor(() => slot.isBusy, "the slot to take work");
    const queuedCompaction = slot.compact();
    const failure = expect(queuedCompaction).rejects.toThrow("manual compaction failed");
    await waitFor(() => slot.snapshot().compactionQueued === true, "the queued compaction");
    releaseResponse();
    await failure;
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    expect(slot.snapshot()).toMatchObject({ phase: "idle", compactionQueued: false });
    expect(slot.snapshot().operation).toBeUndefined();
  });

  it("keeps queued compaction owned while transient marker removal retries", async () => {
    const root = await temporaryRoot("tron-compaction-marker-failure-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    let releaseResponse!: () => void;
    const responseBarrier = new Promise<void>((resolve) => { releaseResponse = resolve; });
    const faux = fauxProvider({ provider: "tron-compaction-marker-failure", tokensPerSecond: 10_000 });
    faux.setResponses([async () => {
      await responseBarrier;
      return fauxAssistantMessage("run complete");
    }]);
    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => {
        const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
        runtime.registerNativeProvider(faux.provider);
        return runtime;
      },
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const session = (slot as unknown as {
      runtime: { session: { compact: (instructions?: string) => Promise<unknown> } };
    }).runtime.session;
    vi.spyOn(session, "compact").mockResolvedValue({});
    const markerStore = (slot as unknown as { dependencies: { markers: RunMarkerStore } }).dependencies.markers;
    const originalClear = markerStore.clear.bind(markerStore);
    let promptOperationId: string;
    let maintenanceAttempts = 0;
    const clearMarker = vi.spyOn(markerStore, "clear").mockImplementation(async (sessionId, operationId) => {
      if (operationId !== promptOperationId && ++maintenanceAttempts === 1) throw new Error("marker removal failed");
      await originalClear(sessionId, operationId);
    });

    promptOperationId = (await slot.prompt("start")).operationId;
    await waitFor(() => slot.isBusy, "the slot to take work");
    const queuedCompaction = slot.compact();
    await waitFor(() => slot.snapshot().compactionQueued === true, "the queued compaction");
    releaseResponse();
    await expect(queuedCompaction).resolves.toEqual({ queued: true });
    expect(maintenanceAttempts).toBe(2);
    expect(clearMarker.mock.calls.every(([, id]) => id !== undefined)).toBe(true);
    expect(await markerStore.evidenceFor(slot.id)).toEqual([]);
    expect(slot.snapshot()).toMatchObject({ phase: "idle", compactionQueued: false });
    expect(slot.snapshot().operation).toBeUndefined();
    clearMarker.mockRestore();
  });

  it("admits only one direct manual compaction and retains the claim through completion", async () => {
    const root = await temporaryRoot("tron-direct-compaction-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }),
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    let releaseCompaction!: () => void;
    const barrier = new Promise<void>((resolve) => { releaseCompaction = resolve; });
    const session = (slot as unknown as {
      runtime: { session: { compact: (instructions?: string) => Promise<unknown> } };
    }).runtime.session;
    const compact = vi.spyOn(session, "compact").mockImplementation(async () => {
      await barrier;
      return {};
    });
    const markerStore = (slot as unknown as {
      dependencies: { markers: { clear: (sessionId: string, operationId?: string) => Promise<void> } };
    }).dependencies.markers;
    const clearMarker = vi.spyOn(markerStore, "clear").mockRejectedValueOnce(new Error("transient clear failure"));

    const first = slot.compact("Keep decisions");
    await waitFor(() => slot.snapshot().phase === "compacting", "the compacting phase");
    expect(registry.activeSessionIds()).toContain(slot.id);
    await expect(slot.compact()).rejects.toMatchObject({
      code: "busy",
      message: "A manual compaction is already pending for this session",
    });
    expect(compact).toHaveBeenCalledTimes(1);
    const markerPath = join(root, "tron", "state", "runtime-markers", `${slot.id}.json`);
    expect(JSON.parse(await readFile(markerPath, "utf8")).operations).toHaveLength(1);

    releaseCompaction();
    await expect(first).resolves.toEqual({ queued: false });
    expect(clearMarker.mock.calls.length).toBeGreaterThanOrEqual(2);
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    expect(slot.snapshot()).toMatchObject({ phase: "idle", compactionQueued: false });
  });

  it("publishes one authoritative compaction snapshot including a hook-appended suffix", async () => {
    const root = await temporaryRoot("tron-compaction-delta-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const broadcasts: Array<{ sessionId: string; topic: string; payload: unknown }> = [];
    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }),
      trust: new TrustService(agentDir),
      broadcast: (sessionId, topic, payload) => broadcasts.push({ sessionId, topic, payload }),
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    subscribeAudience(registry, slot.id);
    const runtime = (slot as unknown as {
      runtime: { session: { sessionManager: SessionManager } };
      onEvent: (event: unknown) => void;
    });
    const firstKeptEntryId = runtime.runtime.session.sessionManager.appendMessage(
      fauxAssistantMessage("canonical history")
    );
    const summary = "Preserved exact decisions";
    const tokensBefore = 12_345;
    const compactionId = runtime.runtime.session.sessionManager.appendCompaction(
      summary,
      firstKeptEntryId,
      tokensBefore
    );
    runtime.runtime.session.sessionManager.appendLabelChange(
      compactionId,
      "hook appended after compaction"
    );

    runtime.onEvent({
      type: "compaction_end",
      reason: "manual",
      result: { summary, firstKeptEntryId, tokensBefore },
      aborted: false,
      willRetry: true,
    });

    expect(broadcasts.some((event) => event.topic === "session.compaction")).toBe(false);
    const completion = broadcasts.filter((event) => event.topic === "session.snapshot").at(-1);
    const payload = completion?.payload as {
      eventSequence?: number;
      phase?: string;
      leafEntryId?: string;
      transcript?: Array<{ id: string; kind: string }>;
    } | undefined;
    expect(completion?.sessionId).toBe(slot.id);
    expect(payload).toMatchObject({
      eventSequence: expect.any(Number),
      phase: "idle",
      leafEntryId: expect.any(String),
    });
    expect(payload?.transcript).toEqual(expect.arrayContaining([
      expect.objectContaining({ id: compactionId, kind: "compaction" }),
      expect.objectContaining({ id: payload?.leafEntryId, kind: "label" }),
    ]));
  });

  it("restores a pre-prompt operation in the authoritative compaction completion frame", async () => {
    const root = await temporaryRoot("tron-preprompt-compaction-frame-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const broadcasts: Array<{ topic: string; payload: any }> = [];
    const registry = await createTestRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }),
      trust: new TrustService(agentDir),
      broadcast: (_sessionId, topic, payload) => broadcasts.push({ topic, payload }),
      sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    subscribeAudience(registry, slot.id);
    const internal = slot as unknown as {
      runtime: { session: { sessionManager: SessionManager } };
      pendingPrompt: { id: string; createdAt: string; text: string; attachmentCount: number };
      phase: string;
      operation: unknown;
      compactionOperation: unknown;
      onEvent: (event: unknown) => void;
    };
    const parent = internal.runtime.session.sessionManager.appendMessage(
      fauxAssistantMessage("history")
    );
    const compaction = internal.runtime.session.sessionManager.appendCompaction(
      "summary", parent, 4_096
    );
    internal.runtime.session.sessionManager.appendLabelChange(compaction, "hook suffix");
    internal.pendingPrompt = {
      id: "pending-operation", createdAt: "2026-01-01T00:00:00.000Z",
      text: "continue", attachmentCount: 0,
    };
    internal.phase = "compacting";
    internal.operation = { kind: "compaction" };
    internal.compactionOperation = internal.operation;
    internal.onEvent({
      type: "compaction_end", reason: "threshold",
      result: { summary: "summary", firstKeptEntryId: parent, tokensBefore: 4_096 },
      aborted: false, willRetry: false,
    });
    const completion = broadcasts.filter((event) => event.topic === "session.snapshot").at(-1)?.payload;
    expect(completion).toMatchObject({
      phase: "running",
      operation: { id: "pending-operation", kind: "prompt", startedAt: "2026-01-01T00:00:00.000Z" },
      pendingPrompt: { id: "pending-operation" },
    });
    expect(completion.leafEntryId).not.toBe(compaction);
  });

  it("cleans up a failed direct manual compaction claim", async () => {
    const root = await temporaryRoot("tron-direct-compaction-failure-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }),
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const session = (slot as unknown as {
      runtime: { session: { compact: (instructions?: string) => Promise<unknown> } };
    }).runtime.session;
    const compact = vi.spyOn(session, "compact")
      .mockRejectedValueOnce(new Error("direct compaction failed"))
      .mockResolvedValueOnce({});

    await expect(slot.compact()).rejects.toThrow("direct compaction failed");
    expect(slot.snapshot()).toMatchObject({ phase: "idle", compactionQueued: false });
    expect(slot.snapshot().operation).toBeUndefined();
    await expect(slot.compact()).resolves.toEqual({ queued: false });
    expect(compact).toHaveBeenCalledTimes(2);
  });

  it("defers queued compaction when a newer prompt enters preflight before handoff", async () => {
    const root = await temporaryRoot("tron-compaction-handoff-race-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    let releaseFirst!: () => void;
    let releaseSecond!: () => void;
    const firstBarrier = new Promise<void>((resolve) => { releaseFirst = resolve; });
    const secondBarrier = new Promise<void>((resolve) => { releaseSecond = resolve; });
    const faux = fauxProvider({ provider: "tron-compaction-handoff-race", tokensPerSecond: 10_000 });
    faux.setResponses([
      async () => { await firstBarrier; return fauxAssistantMessage("first complete"); },
      async () => { await secondBarrier; return fauxAssistantMessage("second complete"); },
    ]);
    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => {
        const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
        runtime.registerNativeProvider(faux.provider);
        return runtime;
      },
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const runtimeSession = (slot as unknown as {
      runtime: { session: {
        compact: (instructions?: string) => Promise<unknown>;
        isStreaming: boolean;
      } };
    }).runtime.session;
    const compact = vi.spyOn(runtimeSession, "compact").mockResolvedValue({});
    const lane = (slot as unknown as {
      lane: { run<T>(operation: () => Promise<T> | T): Promise<T> };
    }).lane;

    await slot.prompt("first");
    await waitFor(() => runtimeSession.isStreaming, "the runtime to start streaming");
    const queuedCompaction = slot.compact();
    await waitFor(() => slot.snapshot().compactionQueued === true, "the queued compaction");

    let releaseLane!: () => void;
    let laneEntered!: () => void;
    const laneWasEntered = new Promise<void>((resolve) => { laneEntered = resolve; });
    const laneBarrier = new Promise<void>((resolve) => { releaseLane = resolve; });
    const blocker = lane.run(async () => {
      laneEntered();
      await laneBarrier;
    });
    await laneWasEntered;
    const newerPrompt = slot.prompt("newer");
    releaseFirst();
    await waitFor(() => !runtimeSession.isStreaming, "the runtime to stop streaming");
    releaseLane();
    await blocker;
    await newerPrompt;
    await waitFor(() => runtimeSession.isStreaming, "the runtime to start streaming");
    await lane.run(() => {});
    expect(compact).not.toHaveBeenCalled();
    expect(slot.snapshot().compactionQueued).toBe(true);

    releaseSecond();
    await waitFor(() => compact.mock.calls.length === 1, "the compaction call");
    await expect(queuedCompaction).resolves.toEqual({ queued: true });
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    const markers = (slot as unknown as { dependencies: { markers: RunMarkerStore } }).dependencies.markers;
    expect(await markers.evidenceFor(slot.id)).toEqual([]);
  });

  it("cancels pending compaction and drains its runtime during registry shutdown", async () => {
    const root = await temporaryRoot("tron-queued-compaction-shutdown-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    let releaseResponse!: () => void;
    const responseBarrier = new Promise<void>((resolve) => { releaseResponse = resolve; });
    const faux = fauxProvider({ provider: "tron-queued-compaction-shutdown", tokensPerSecond: 10_000 });
    faux.setResponses([async () => {
      await responseBarrier;
      return fauxAssistantMessage("run complete");
    }]);
    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => {
        const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
        runtime.registerNativeProvider(faux.provider);
        return runtime;
      },
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const session = (slot as unknown as {
      runtime: { session: { compact: (instructions?: string) => Promise<unknown> } };
    }).runtime.session;
    const compact = vi.spyOn(session, "compact").mockResolvedValue({});

    await slot.prompt("start");
    await waitFor(() => slot.isBusy, "the slot to take work");
    const queuedCompaction = slot.compact();
    const queuedOutcome = queuedCompaction.then(
      () => ({ status: "fulfilled" as const }),
      (error: unknown) => ({ status: "rejected" as const, error }),
    );
    await waitFor(() => slot.snapshot().compactionQueued === true, "the queued compaction");
    const shutdown = registry.dispose();
    releaseResponse();

    const outcome = await queuedOutcome;
    expect(outcome).toMatchObject({ status: "rejected", error: { code: "cancelled" } });
    await shutdown;
    expect(compact).not.toHaveBeenCalled();
    expect(registry.activeSessionIds()).toEqual([]);
    const index = registries.indexOf(registry);
    if (index >= 0) registries.splice(index, 1);
  });

  it("aborts and drains an in-flight direct compaction during registry shutdown", async () => {
    const root = await temporaryRoot("tron-direct-compaction-shutdown-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }),
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    let releaseCompaction!: () => void;
    const compactionBarrier = new Promise<void>((resolve) => { releaseCompaction = resolve; });
    const session = (slot as unknown as {
      runtime: { session: {
        compact: (instructions?: string) => Promise<unknown>;
        abortCompaction: () => void;
      } };
    }).runtime.session;
    vi.spyOn(session, "compact").mockImplementation(async () => {
      await compactionBarrier;
      return {};
    });
    const originalAbort = session.abortCompaction.bind(session);
    const abortCompaction = vi.spyOn(session, "abortCompaction").mockImplementation(() => {
      originalAbort();
      releaseCompaction();
    });

    const compaction = slot.compact();
    await waitFor(() => slot.snapshot().phase === "compacting", "the compacting phase");
    const shutdown = registry.dispose();
    await expect(compaction).resolves.toEqual({ queued: false });
    await shutdown;
    expect(abortCompaction).toHaveBeenCalled();
    expect(registry.activeSessionIds()).toEqual([]);
    const index = registries.indexOf(registry);
    if (index >= 0) registries.splice(index, 1);
  });

  it("closes global slot admission before draining an already-entered creation", async () => {
    const root = await temporaryRoot("tron-registry-admission-shutdown-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    let factoryEntered!: () => void;
    let releaseFactory!: () => void;
    const factoryWasEntered = new Promise<void>((resolve) => { factoryEntered = resolve; });
    const factoryBarrier = new Promise<void>((resolve) => { releaseFactory = resolve; });
    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => {
        factoryEntered();
        await factoryBarrier;
        return ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      },
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);

    const creating = registry.create(cwd);
    await factoryWasEntered;
    let shutdownFinished = false;
    const shutdown = registry.dispose().then(() => { shutdownFinished = true; });
    await Promise.resolve();
    expect(shutdownFinished).toBe(false);
    await expect(registry.create(cwd)).rejects.toMatchObject({
      code: "conflict",
      message: "Session runtime registry is shutting down",
    });

    releaseFactory();
    const created = await creating;
    await shutdown;
    expect(shutdownFinished).toBe(true);
    expect(registry.activeSessionIds()).toEqual([]);
    expect((registry as unknown as { slots: Map<string, unknown> }).slots.size).toBe(0);
    await expect(registry.acquire(created.id)).rejects.toMatchObject({ code: "conflict" });
    const index = registries.indexOf(registry);
    if (index >= 0) registries.splice(index, 1);
  });

  it("preserves the admitted run marker when global shutdown forces interruption", async () => {
    const root = await temporaryRoot("tron-forced-shutdown-marker-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const faux = fauxProvider({ provider: "tron-forced-marker", tokensPerSecond: 10_000 });
    faux.setResponses([
      async () => { await new Promise((resolve) => setTimeout(resolve, 250)); return fauxAssistantMessage("late"); },
    ]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const registry = await createTestRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime, trust: new TrustService(agentDir),
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("accepted work");
    await waitFor(() => slot.catalogPhase === "running", "the catalog phase to run");
    const sessionID = slot.id;
    await slot.shutdown();
    const markerStore = (registry as unknown as { markers: { interruptedSessionIds(): Promise<Set<string>> } }).markers;
    expect((await markerStore.interruptedSessionIds()).has(sessionID)).toBe(true);
  });

  it("does not tear down blob ownership before every captured slot drains", async () => {
    const root = await temporaryRoot("tron-registry-blob-drain-order-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }),
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);

    let shutdownEntered!: () => void;
    let releaseShutdown!: () => void;
    const shutdownWasEntered = new Promise<void>((resolve) => { shutdownEntered = resolve; });
    const shutdownBarrier = new Promise<void>((resolve) => { releaseShutdown = resolve; });
    const originalShutdown = slot.shutdown.bind(slot);
    let slotDrained = false;
    vi.spyOn(slot, "shutdown").mockImplementation(async () => {
      shutdownEntered();
      await shutdownBarrier;
      await originalShutdown();
      slotDrained = true;
    });
    const blobs = (registry as unknown as { blobs: { dispose: () => Promise<void> } }).blobs;
    const originalBlobDispose = blobs.dispose.bind(blobs);
    let blobDisposeStarted = false;
    vi.spyOn(blobs, "dispose").mockImplementation(async () => {
      blobDisposeStarted = true;
      expect(slotDrained).toBe(true);
      await originalBlobDispose();
    });

    const shutdown = registry.dispose();
    await shutdownWasEntered;
    expect(blobDisposeStarted).toBe(false);
    releaseShutdown();
    await shutdown;
    expect(slotDrained).toBe(true);
    expect(blobDisposeStarted).toBe(true);
    const index = registries.indexOf(registry);
    if (index >= 0) registries.splice(index, 1);
  });

  it("omits a terminal runtime overlay when its canonical result is outside the bounded tail", async () => {
    const fixture = await coldFixture("canonical-tool-ownership-backstop");
    fixture.manager.appendMessage({
      role: "toolResult",
      toolCallId: "canonical-old",
      toolName: "read",
      content: [{ type: "text", text: "canonical result" }],
      isError: true,
      timestamp: Date.now(),
    });
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as {
      toolExecutions: Map<string, unknown>;
      toolMetadata: Map<string, unknown>;
      toolStartedAtMonotonicMs: Map<string, number>;
      activeOperationId?: string;
      activeToolSegmentOwnerId?: string;
      onEvent: (event: unknown) => void;
      runtime: { session: { readonly isStreaming: boolean } };
    };
    internal.toolExecutions.set("canonical-old", {
      toolCallId: "canonical-old", toolName: "read", order: 0, status: "running",
      arguments: null, isError: false, startedAt: new Date(0).toISOString(),
      updatedAt: new Date(0).toISOString(), lastProgressAt: new Date(0).toISOString(),
      progressSequence: 1,
    });
    const startedAt = new Date(Date.now() - 1_500).toISOString();
    const metadata = {
      startedAt,
      durationMs: 1_500,
      lastProgressAt: startedAt,
      progressSequence: 3,
      toolSegmentId: "tool-segment:retained",
      groupId: "tool-group:retained",
      groupIndex: 0,
      groupCount: 1,
      groupFinalized: true,
    };
    internal.toolMetadata.set("canonical-old", metadata);
    internal.toolStartedAtMonotonicMs.set("canonical-old", performance.now() - 1_500);
    expect(slot.snapshot().toolExecutions).toEqual([]);
    const streaming = vi.spyOn(internal.runtime.session, "isStreaming", "get").mockReturnValue(true);
    internal.onEvent({
      type: "message_end",
      message: {
        role: "toolResult", toolCallId: "canonical-old", toolName: "read",
        content: [{ type: "text", text: "canonical result" }], isError: true,
        timestamp: Date.now(),
      },
    });
    await Promise.resolve();
    expect(internal.toolExecutions.has("canonical-old")).toBe(false);
    expect(internal.toolMetadata.get("canonical-old")).toMatchObject({
      startedAt,
      durationMs: expect.any(Number),
      progressSequence: 3,
      toolSegmentId: "tool-segment:retained",
      groupId: "tool-group:retained",
    });
    const handoffDurationMs = (internal.toolMetadata.get("canonical-old") as { durationMs: number }).durationMs;
    expect(handoffDurationMs).toBeGreaterThanOrEqual(1_500);
    expect(internal.toolStartedAtMonotonicMs.has("canonical-old")).toBe(true);
    internal.toolStartedAtMonotonicMs.delete("canonical-old");
    internal.onEvent({
      type: "tool_execution_end", toolCallId: "canonical-old", toolName: "read",
      result: { content: [{ type: "text", text: "late terminal" }] }, isError: true,
    });
    expect(internal.toolExecutions.has("canonical-old")).toBe(false);
    expect(internal.toolMetadata.get("canonical-old")).toMatchObject({
      startedAt,
      completedAt: expect.any(String),
      durationMs: expect.any(Number),
      progressSequence: 4,
      toolSegmentId: "tool-segment:retained",
      groupId: "tool-group:retained",
      groupIndex: 0,
      groupCount: 1,
      groupFinalized: true,
    });
    expect((internal.toolMetadata.get("canonical-old") as { durationMs: number }).durationMs)
      .toBe(handoffDurationMs);
    expect(internal.toolStartedAtMonotonicMs.has("canonical-old")).toBe(false);
    expect(slot.snapshot().toolExecutions).toEqual([]);

    const silentStartedAt = new Date().toISOString();
    internal.toolExecutions.set("silent-running", {
      toolCallId: "silent-running", toolName: "bash", order: 1, status: "running",
      arguments: null, isError: false, startedAt: silentStartedAt,
      updatedAt: silentStartedAt, lastProgressAt: silentStartedAt,
      durationMs: 0, progressSequence: 1,
    });
    internal.toolStartedAtMonotonicMs.set("silent-running", performance.now() - 500);
    expect(slot.snapshot().toolExecutions.find((tool) => tool.toolCallId === "silent-running")?.durationMs)
      .toBeGreaterThanOrEqual(450);
    internal.toolExecutions.delete("silent-running");
    internal.toolStartedAtMonotonicMs.delete("silent-running");

    const notPersisted = {
      toolCallId: "not-persisted", toolName: "read", order: 1, status: "completed",
      arguments: null, isError: false, startedAt: new Date(0).toISOString(),
      updatedAt: new Date(0).toISOString(), lastProgressAt: new Date(0).toISOString(),
      progressSequence: 1,
    };
    internal.toolExecutions.set("not-persisted", notPersisted);
    internal.onEvent({
      type: "message_end",
      message: {
        role: "toolResult", toolCallId: "not-persisted", toolName: "read",
        content: [{ type: "text", text: "append failed" }], isError: false,
        timestamp: Date.now(),
      },
    });
    await Promise.resolve();
    expect(internal.toolExecutions.get("not-persisted")).toEqual(notPersisted);
    internal.toolExecutions.delete("not-persisted");

    internal.toolMetadata.set("reused-after-interruption", {
      startedAt: new Date(0).toISOString(), completedAt: new Date(1_000).toISOString(),
      durationMs: 1_000, lastProgressAt: new Date(1_000).toISOString(), progressSequence: 9,
      toolSegmentId: "tool-segment:stale", groupId: "tool-group:stale",
      groupIndex: 0, groupCount: 1, groupFinalized: true,
    });
    internal.activeOperationId = "fresh-operation";
    internal.activeToolSegmentOwnerId = "fresh-operation";
    internal.onEvent({
      type: "tool_execution_start", toolCallId: "reused-after-interruption",
      toolName: "read", args: { path: "fresh" },
    });
    expect(internal.toolMetadata.get("reused-after-interruption")).toMatchObject({
      startedAt: expect.not.stringContaining("1970-01-01"),
      durationMs: expect.any(Number),
      progressSequence: 1,
      toolSegmentId: "tool-segment:\"fresh-operation\"",
    });
    expect(internal.toolMetadata.get("reused-after-interruption")).not.toMatchObject({
      completedAt: expect.anything(), groupId: "tool-group:stale",
    });
    internal.toolExecutions.delete("reused-after-interruption");
    internal.toolMetadata.delete("reused-after-interruption");
    internal.toolStartedAtMonotonicMs.delete("reused-after-interruption");
    internal.activeOperationId = undefined;
    internal.activeToolSegmentOwnerId = undefined;
    streaming.mockRestore();
  });
});
