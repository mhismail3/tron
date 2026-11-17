import { createTestRegistry } from "../../../test-support/gateway-registry.js";
import { spawn, spawnSync } from "node:child_process";
import * as fsPromises from "node:fs/promises";
import { existsSync, writeFileSync } from "node:fs";
import { mkdir, readFile, readdir, rm, symlink, truncate, writeFile } from "node:fs/promises";
import { basename, dirname, join, resolve, sep } from "node:path";
import { ModelRuntime, SessionManager } from "@earendil-works/pi-coding-agent";
import { contentText, fauxAssistantMessage, fauxProvider, fauxToolCall } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it, onTestFinished, vi } from "vitest";
import { TrustService } from "../../kernel/resources/trust-service.js";
import { admitsAutomationAction } from "../../automations/automation-contract.js";
import { GatewayAutomationExecutor } from "../../automations/automation-executor.js";
import type { AutomationExecutionHandle } from "../../automations/automation-scheduler.js";
import type { AutomationRecord, AutomationRun } from "../../automations/types.js";
import type { NotificationService } from "../../notifications/notification-service.js";
import type { SessionSummaryUpdate } from "../../protocol/types.js";
import { GatewayWorkRegistry } from "../../kernel/run/gateway-work-registry.js";
import { CatalogMetadataIndex } from "../../sessions/catalog-metadata-index.js";
import { INVOCATION_RECEIPT_TYPE } from "../../kernel/receipts/invocation-receipts.js";
import {
  RuntimeRegistry,
} from "../../kernel/session/runtime-registry.js";
import { toolSegmentId } from "../../kernel/projection/projection.js";
import { waitFor } from "../../../test-support/wait-for.js";
import { catalogOwner, createColdRegistryFixture, initializeRegistry, temporaryRoot } from "../../../test-support/runtime-registry-fixture.js";
function subscribeAudience(registry: RuntimeRegistry, sessionId: string): void {
  registry.subscribe("test-audience", sessionId);
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
  it("aborts the exact foreground bash tree even when the client reports a stale bash kind", async () => {
    if (process.platform === "win32") return;
    const root = await temporaryRoot("tron-foreground-bash-abort-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);

    const detachedPidPath = join(cwd, "detached.pid");
    const childProgram = "setInterval(() => {}, 1000)";
    const parentProgram = [
      "const { spawn } = require('node:child_process');",
      "const { writeFileSync } = require('node:fs');",
      `const child = spawn(${JSON.stringify(process.execPath)}, ['-e', ${JSON.stringify(childProgram)}], { detached: true, stdio: 'ignore' });`,
      `writeFileSync(${JSON.stringify(detachedPidPath)}, String(child.pid));`,
      "setInterval(() => {}, 1000);",
    ].join(" ");
    const command = `${JSON.stringify(process.execPath)} -e ${JSON.stringify(parentProgram)}`;
    const faux = fauxProvider({ provider: "tron-foreground-bash-abort", tokensPerSecond: 10_000 });
    faux.setResponses([
      fauxAssistantMessage([fauxToolCall("bash", { command }, { id: "call-owned-bash" })], { stopReason: "toolUse" }),
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

    const prompting = slot.prompt("run the owned command");
    await waitFor(() => existsSync(detachedPidPath), "the detached process id file");
    const detachedPid = Number(await readFile(detachedPidPath, "utf8"));
    expect(() => process.kill(detachedPid, 0)).not.toThrow();
    const operationId = slot.snapshot().operation?.id;
    expect(operationId).toBeDefined();

    await slot.abort("bash", operationId);
    await expect(prompting).resolves.toMatchObject({ operationId });
    await waitFor(() => {
      try { process.kill(detachedPid, 0); return false; }
      catch { return true; }
    }, "the detached process to exit");
    expect(slot.snapshot().toolExecutions).toEqual([]);
  });

  it("projects stable ordinals for parallel tools from start through completion", async () => {
    const root = await temporaryRoot("tron-tool-order-integration-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);

    const faux = fauxProvider({ provider: "tron-tool-order", tokensPerSecond: 10_000 });
    const createModels = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    faux.setResponses([
      fauxAssistantMessage([
        fauxToolCall("read", { path: join(cwd, "one.txt") }, { id: "call-read" }),
        fauxToolCall("bash", { command: "printf start; sleep 0.35; printf end" }, { id: "call-bash" }),
      ], { stopReason: "toolUse" }),
      fauxAssistantMessage("finished"),
    ]);
    await writeFile(join(cwd, "one.txt"), "one\n");
    const events: Array<{ topic: string; payload: any }> = [];
    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: createModels,
      trust: new TrustService(agentDir),
      broadcast: (_sessionId, topic, payload) => events.push({ topic, payload }),
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    subscribeAudience(registry, slot.id);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const prompting = slot.prompt("run tools");
    await waitFor(() => slot.snapshot().toolExecutions.some((tool) => tool.status === "running"), "a running tool execution");
    const activeSnapshot = slot.snapshot();
    expect(activeSnapshot.activeToolSegmentId).toBeDefined();
    expect(activeSnapshot.acceptsQueuedPrompts).toBe(true);
    expect(activeSnapshot.toolExecutions.every(
      (tool) => tool.toolSegmentId === activeSnapshot.activeToolSegmentId,
    )).toBe(true);
    await prompting;
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    expect(slot.snapshot().activeToolSegmentId).toBeUndefined();
    await waitFor(() => registry.attentionProjection(slot.id).isUnread, "the unread attention mark");
    expect(registry.attentionProjection(slot.id).completionRevision).toBe(1);

    const progress = events
      .filter((event) => event.topic === "session.toolProgress")
      .map((event) => event.payload.data as {
        toolCallId: string;
        order: number;
        status: string;
        output?: string;
        progressSequence: number;
        durationMs?: number;
        completedAt?: string;
        toolSegmentId?: string;
        groupId?: string;
        groupIndex?: number;
        groupCount?: number;
        groupFinalized?: boolean;
      });
    const finalizedProgressIndex = events.findIndex((event) => {
      if (event.topic !== "session.progress") return false;
      const message = event.payload.data?.message;
      const calls = message?.content?.filter((part: any) => part.type === "toolCall") ?? [];
      return calls.length === 2 && calls.every((part: any) => part.groupFinalized === true);
    });
    const firstToolProgressIndex = events.findIndex((event) => event.topic === "session.toolProgress");
    expect(finalizedProgressIndex).toBeGreaterThanOrEqual(0);
    expect(firstToolProgressIndex).toBeGreaterThan(finalizedProgressIndex);

    const firstRunning = new Map<string, number>();
    for (const event of progress) {
      if (event.status === "running" && !firstRunning.has(event.toolCallId)) firstRunning.set(event.toolCallId, event.order);
    }
    expect(firstRunning).toEqual(new Map([["call-read", 0], ["call-bash", 1]]));
    const finalOrder = new Map(progress.map((event) => [event.toolCallId, event.order]));
    expect(finalOrder).toEqual(new Map([["call-read", 0], ["call-bash", 1]]));
    const grouped = progress.filter((event) => event.groupFinalized === true);
    expect(grouped.length).toBeGreaterThanOrEqual(2);
    expect(new Set(grouped.map((event) => event.groupId)).size).toBe(1);
    expect(new Set(grouped.map((event) => event.toolSegmentId)).size).toBe(1);
    expect(grouped.every((event) => event.toolSegmentId?.startsWith("tool-segment:") === true)).toBe(true);
    expect(new Set(grouped.map((event) => event.groupCount))).toEqual(new Set([2]));
    expect(new Map(grouped.map((event) => [event.toolCallId, event.groupIndex])))
      .toEqual(new Map([["call-read", 0], ["call-bash", 1]]));
    const bashProgress = progress.filter((event) => event.toolCallId === "call-bash");
    expect(bashProgress.some((event) => event.status === "running" && event.output?.includes("start"))).toBe(true);
    const runningDurations = bashProgress
      .filter((event) => event.status === "running")
      .map((event) => event.durationMs);
    expect(runningDurations.length).toBeGreaterThan(0);
    expect(runningDurations.every((duration) => typeof duration === "number" && duration >= 0)).toBe(true);
    expect(runningDurations).toEqual([...runningDurations].sort((left, right) => left! - right!));
    expect(bashProgress.at(-1)).toMatchObject({ status: "completed", output: "startend" });
    expect(bashProgress.at(-1)!.progressSequence).toBeGreaterThan(2);
    expect(bashProgress.at(-1)!.durationMs).toBeGreaterThanOrEqual(300);
    expect(bashProgress.at(-1)!.completedAt).toBeTypeOf("string");
    expect(events.filter((event) => event.topic === "session.processActivity")).toEqual([]);
    const activeSnapshots = events
      .filter((event) => event.topic === "session.snapshot")
      .map((event) => (event.payload?.data ?? event.payload) as {
        phase?: string;
        transcript?: Array<{ kind?: string; role?: string; toolCallId?: string }>;
        toolExecutions?: Array<{ toolCallId: string }>;
      })
      .filter((snapshot) => snapshot.phase === "running");
    expect(activeSnapshots.some((snapshot) => {
      const runtimeRead = snapshot.toolExecutions?.some((tool) => tool.toolCallId === "call-read");
      const runtimeBash = snapshot.toolExecutions?.some((tool) => tool.toolCallId === "call-bash");
      return runtimeRead === true && runtimeBash === true;
    })).toBe(true);
    expect(activeSnapshots.some((snapshot) => {
      const canonicalRead = snapshot.transcript?.some((item) =>
        item.kind === "message" && item.role === "toolResult" && item.toolCallId === "call-read");
      const canonicalBash = snapshot.transcript?.some((item) =>
        item.kind === "message" && item.role === "toolResult" && item.toolCallId === "call-bash");
      return canonicalRead === true && canonicalBash === true;
    })).toBe(true);
    const snapshotsAfterAdmission = activeSnapshots.filter((snapshot) => {
      const canonicalRead = snapshot.transcript?.some((item) =>
        item.kind === "message" && item.role === "toolResult" && item.toolCallId === "call-read");
      const runtimeRead = snapshot.toolExecutions?.some((tool) => tool.toolCallId === "call-read");
      return canonicalRead === true || runtimeRead === true;
    });
    expect(snapshotsAfterAdmission.length).toBeGreaterThan(0);
    expect(snapshotsAfterAdmission.every((snapshot) => {
      const canonicalRead = snapshot.transcript?.some((item) =>
        item.kind === "message" && item.role === "toolResult" && item.toolCallId === "call-read");
      const runtimeRead = snapshot.toolExecutions?.some((tool) => tool.toolCallId === "call-read");
      return canonicalRead === true || runtimeRead === true;
    })).toBe(true);
    expect(activeSnapshots.every((snapshot) => {
      const canonicalIDs = new Set((snapshot.transcript ?? [])
        .filter((item) => item.kind === "message" && item.role === "toolResult")
        .map((item) => item.toolCallId)
        .filter((id): id is string => typeof id === "string"));
      return !(snapshot.toolExecutions ?? []).some((tool) => canonicalIDs.has(tool.toolCallId));
    })).toBe(true);
    const settled = slot.snapshot();
    expect(settled.toolExecutions).toEqual([]);
    expect(settled.processOverview).toMatchObject({ visibility: "hidden", activeCount: 0, recentCount: 0 });
    expect(settled.processActivities ?? []).toEqual([]);
    expect(slot.processHistory(undefined, 25, { kind: "command" }).activities).toEqual([]);
    const canonicalAssistant = settled.transcript.find((item) => item.kind === "message" && item.role === "assistant");
    const canonicalCalls = canonicalAssistant?.kind === "message"
      ? canonicalAssistant.content.filter((part) => part.type === "toolCall")
      : [];
    expect(canonicalCalls).toHaveLength(2);
    expect(canonicalCalls.every((part) => part.type === "toolCall" && part.groupFinalized === true)).toBe(true);
    expect(new Set(canonicalCalls.flatMap((part) => part.type === "toolCall" ? [part.groupId] : [])).size).toBe(1);
    const canonicalSegmentIDs = new Set(canonicalCalls.flatMap((part) =>
      part.type === "toolCall" ? [part.toolSegmentId] : []
    ));
    expect(canonicalSegmentIDs.size).toBe(1);
    expect(canonicalSegmentIDs).toEqual(new Set(grouped.map((event) => event.toolSegmentId)));
    expect(settled.transcript.find((item) => item.kind === "message" && item.role === "toolResult" && item.toolCallId === "call-bash"))
      .toMatchObject({ durationMs: expect.any(Number), startedAt: expect.any(String), completedAt: expect.any(String) });
    expect(slot.sessionFile?.startsWith(join(agentDir, "sessions") + sep)).toBe(true);
  });

  it("projects codemode nested calls live and after a cold reload", async () => {
    const root = await temporaryRoot("tron-nested-tools-e2e-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensions = join(cwd, ".pi", "extensions");
    await Promise.all([
      mkdir(agentDir), mkdir(extensions, { recursive: true }),
    ]);
    await writeFile(join(agentDir, "settings.json"), JSON.stringify({ defaultTools: ["+codemode"] }));
    const sdkUrl = import.meta.resolve("@earendil-works/pi-coding-agent");
    await Promise.all([
      writeFile(join(extensions, "codemode.ts"), `import { createCodemodeExtension } from ${JSON.stringify(sdkUrl)}; export default createCodemodeExtension({ mode: "on" });\n`),
      writeFile(join(extensions, "failing-tool.ts"), `export default function (pi) { pi.registerTool({ name: "test_fail", label: "Fail fixture", description: "Fails without throwing", parameters: { type: "object", properties: {} }, execute: async () => ({ content: [{ type: "text", text: "expected failure" }], details: {}, usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0.125 } }, isError: true }) }); }\n`),
      writeFile(join(cwd, "read-me.txt"), "faux-provider nested read\n"),
    ]);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const faux = fauxProvider({ provider: "tron-nested-tools", tokensPerSecond: 10_000 });
    const createModels = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    const script = `const results = await Promise.all([\n      tools.read({ path: "read-me.txt" }),\n      tools.bash({ command: "sleep 0.2; printf nested-bash" }),\n      tools.test_fail({}).catch((error) => String(error)),\n    ]); return results.map((result) => text(result)).join("\\n");`;
    faux.setResponses([
      fauxAssistantMessage([fauxToolCall("codemode", { code: script }, { id: "codemode-parent" })], { stopReason: "toolUse" }),
      fauxAssistantMessage([fauxToolCall("test_fail", {}, { id: "top-level-fail" })], { stopReason: "toolUse" }),
      fauxAssistantMessage("done"),
    ]);
    const events: Array<{ topic: string; payload: any }> = [];
    const makeRegistry = async () => await createTestRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000,
      modelRuntimeFactory: createModels, trust,
      broadcast: (_sessionId, topic, payload) => events.push({ topic, payload }),
      sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    let registry = await makeRegistry();
    registries.push(registry);
    await initializeRegistry(registry);
    let slot = await registry.create(cwd);
    subscribeAudience(registry, slot.id);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const prompting = slot.prompt("run nested tools");
    await waitFor(() => slot.snapshot().toolExecutions.some((tool) =>
      tool.toolCallId === "codemode-parent" && (tool.nestedCalls?.calls.length ?? 0) === 3), "the codemode parent's nested calls");
    const live = slot.snapshot();
    const liveParent = live.toolExecutions.find((tool) => tool.toolCallId === "codemode-parent");
    expect(liveParent?.nestedCalls?.calls.map((call) => call.toolName).sort()).toEqual(["bash", "read", "test_fail"]);
    expect(live.toolExecutions.map((tool) => tool.toolCallId)).toEqual(["codemode-parent"]);
    await prompting;
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    const settled = slot.snapshot();
    const canonicalParent = settled.transcript.find((item) =>
      item.kind === "message" && item.role === "toolResult" && item.toolCallId === "codemode-parent");
    expect(canonicalParent).toMatchObject({
      kind: "message", role: "toolResult", isError: false,
      usage: { cost: { total: 0.125 } },
      nestedCalls: { complete: true, calls: [
        { id: "codemode-parent/1", toolName: "read", status: "completed" },
        { id: "codemode-parent/2", toolName: "bash", status: "completed" },
        { id: "codemode-parent/3", toolName: "test_fail", status: "failed" },
      ] },
    });
    expect(settled.stats.cost).toBeGreaterThanOrEqual(0.125);
    expect(settled.transcript.find((item) =>
      item.kind === "message" && item.role === "toolResult" && item.toolCallId === "top-level-fail"))
      .toMatchObject({ isError: true });
    expect(events.some((event) => event.topic === "session.toolProgress"
      && event.payload.data?.toolCallId === "top-level-fail"
      && event.payload.data?.status === "failed")).toBe(true);
    const liveSnapshot = JSON.parse(JSON.stringify(live));
    await registry.dispose();
    registry = await makeRegistry();
    registries.push(registry);
    await initializeRegistry(registry);
    slot = await registry.acquire(slot.id);
    const reloaded = slot.snapshot();
    const reloadedParent = reloaded.transcript.find((item) =>
      item.kind === "message" && item.role === "toolResult" && item.toolCallId === "codemode-parent");
    expect(reloadedParent).toMatchObject({
      role: "toolResult",
      nestedCalls: { complete: true, calls: [
        { id: "codemode-parent/1", status: "completed" },
        { id: "codemode-parent/2", status: "completed" },
        { id: "codemode-parent/3", status: "failed" },
      ] },
    });
    expect(reloaded.toolExecutions).toEqual([]);
    const artifactPath = join(process.cwd(), "test-results", "pi-sdk-099-nested-calls.json");
    await mkdir(dirname(artifactPath), { recursive: true });
    await writeFile(artifactPath, `${JSON.stringify({ live: liveSnapshot, reloaded: reloadedParent }, null, 2)}\n`);
  });

  it("projects every nested call Pi records, live and after a cold reload, within one argument budget", async () => {
    const root = await temporaryRoot("tron-nested-call-list-e2e-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensions = join(cwd, ".pi", "extensions");
    await Promise.all([mkdir(agentDir), mkdir(extensions, { recursive: true })]);
    await writeFile(join(agentDir, "settings.json"), JSON.stringify({ defaultTools: ["+codemode"] }));
    const sdkUrl = import.meta.resolve("@earendil-works/pi-coding-agent");
    await Promise.all([
      writeFile(join(extensions, "codemode.ts"), `import { createCodemodeExtension } from ${JSON.stringify(sdkUrl)}; export default createCodemodeExtension({ mode: "on" });\n`),
      writeFile(join(extensions, "echo-tool.ts"), `export default function (pi) { pi.registerTool({ name: "test_echo", label: "Echo fixture", description: "Returns ok", parameters: { type: "object", properties: { note: { type: "string" } } }, execute: async () => ({ content: [{ type: "text", text: "ok" }], details: {} }) }); }\n`),
    ]);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const faux = fauxProvider({ provider: "tron-nested-call-list", tokensPerSecond: 10_000 });
    const createModels = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    const script = `for (let i = 0; i < 48; i++) await tools.test_echo({ note: "small " + i });\n`
      + `for (let i = 0; i < 40; i++) await tools.test_echo({ note: "x".repeat(900) + i });\nreturn "done";`;
    faux.setResponses([
      fauxAssistantMessage([fauxToolCall("codemode", { code: script }, { id: "codemode-list" })], { stopReason: "toolUse" }),
      fauxAssistantMessage("done"),
    ]);
    const liveFrames: Array<{ calls: Array<{ arguments?: unknown }>; complete: boolean }> = [];
    const makeRegistry = async () => await createTestRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, modelRuntimeFactory: createModels, trust,
      broadcast: (_sessionId, topic, payload: any) => {
        if (topic === "session.toolProgress" && payload.data?.toolCallId === "codemode-list" && payload.data.nestedCalls) {
          liveFrames.push(payload.data.nestedCalls);
        }
      },
      sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    let registry = await makeRegistry();
    registries.push(registry);
    await initializeRegistry(registry);
    let slot = await registry.create(cwd);
    subscribeAudience(registry, slot.id);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("run many nested calls");
    await waitFor(() => !slot.isBusy, "the slot to go idle");

    const argumentBytes = (calls: Array<{ arguments?: unknown }>) =>
      calls.reduce((total, call) => total + (call.arguments === undefined ? 0 : Buffer.byteLength(JSON.stringify(call.arguments))), 0);
    const largestLive = liveFrames.reduce((most, frame) => frame.calls.length > most.calls.length ? frame : most, liveFrames[0]!);
    expect(largestLive.calls).toHaveLength(88);
    expect(liveFrames.every((frame) => argumentBytes(frame.calls) <= 32 * 1024)).toBe(true);
    const parentOf = (snapshot: ReturnType<typeof slot.snapshot>) => snapshot.transcript.find((item) =>
      item.kind === "message" && item.role === "toolResult" && item.toolCallId === "codemode-list");
    const canonical = parentOf(slot.snapshot());
    const canonicalCalls = canonical?.kind === "message" ? canonical.nestedCalls?.calls ?? [] : [];
    expect(canonicalCalls).toHaveLength(88);
    expect(canonicalCalls.slice(0, 48).every((call) => call.arguments !== undefined)).toBe(true);
    expect(argumentBytes(canonicalCalls)).toBeLessThanOrEqual(32 * 1024);
    expect(canonicalCalls.some((call) => call.arguments === undefined && typeof call.argumentsBytes === "number")).toBe(true);

    await registry.dispose();
    registry = await makeRegistry();
    registries.push(registry);
    await initializeRegistry(registry);
    slot = await registry.acquire(slot.id);
    const reloaded = parentOf(slot.snapshot());
    const reloadedCalls = reloaded?.kind === "message" ? reloaded.nestedCalls?.calls ?? [] : [];
    expect(reloadedCalls.map((call) => call.id)).toEqual(canonicalCalls.map((call) => call.id));
  });

  it("returns Pi structured bash output through nested codemode calls", async () => {
    const root = await temporaryRoot("tron-codemode-bash-output-e2e-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensions = join(cwd, ".pi", "extensions");
    await Promise.all([
      mkdir(agentDir), mkdir(extensions, { recursive: true }),
    ]);
    await writeFile(join(agentDir, "settings.json"), JSON.stringify({ defaultTools: ["+codemode"] }));
    const sdkUrl = import.meta.resolve("@earendil-works/pi-coding-agent");
    await writeFile(join(extensions, "codemode.ts"), `import { createCodemodeExtension } from ${JSON.stringify(sdkUrl)}; export default createCodemodeExtension({ mode: "on" });\n`);
    const faux = fauxProvider({ provider: "tron-codemode-bash-output", tokensPerSecond: 10_000 });
    const createModels = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    const script = [
      'const large = await tools.bash({ command: "yes x | head -c 1100000" });',
      'const empty = await tools.bash({ command: "true" });',
      'const failed = await tools.bash({ command: "printf failed-output; exit 7" }).catch((error) => ({ error: String(error) }));',
      'return JSON.stringify({ large: { outputLength: large.output.length, truncated: large.truncated, full_output_path: large.full_output_path, exit_code: large.exit_code, wall_time_seconds: large.wall_time_seconds }, empty, failed });',
    ].join("\n");
    faux.setResponses([
      fauxAssistantMessage([fauxToolCall("codemode", { code: script }, { id: "codemode-bash-output" })], { stopReason: "toolUse" }),
      fauxAssistantMessage("done"),
    ]);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const registry = await createTestRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000,
      modelRuntimeFactory: createModels, trust,
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("inspect structured bash results");
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    const parent = slot.snapshot().transcript.find((item) =>
      item.kind === "message" && item.role === "toolResult" && item.toolCallId === "codemode-bash-output");
    expect(parent).toMatchObject({
      role: "toolResult",
      nestedCalls: { complete: true, calls: [
        { toolName: "bash", status: "completed" },
        { toolName: "bash", status: "completed" },
        { toolName: "bash", status: "failed" },
      ] },
    });
    const parentText = parent?.kind === "message" ? contentText(parent.content) : "";
    const outputMarker = "Output:\n";
    const structured = JSON.parse(parentText.slice(parentText.indexOf(outputMarker) + outputMarker.length)) as {
      large: { outputLength: number; truncated: boolean; full_output_path?: string; exit_code: number; wall_time_seconds: number };
      empty: { output: string; truncated: boolean; exit_code: number; wall_time_seconds: number };
      failed: { output: string; truncated: boolean; exit_code: number; wall_time_seconds: number };
    };
    expect(structured.large.outputLength).toBeGreaterThan(1_048_576);
    expect(structured.large).toMatchObject({ truncated: true, exit_code: 0 });
    expect(structured.large.full_output_path).toBeTypeOf("string");
    expect(structured.large.wall_time_seconds).toBeGreaterThanOrEqual(0);
    expect(structured.empty).toMatchObject({ output: "", truncated: false, exit_code: 0 });
    expect(structured.empty.wall_time_seconds).toBeGreaterThanOrEqual(0);
    expect(structured.failed).toMatchObject({ output: "failed-output", truncated: false, exit_code: 7 });
    expect(structured.failed.wall_time_seconds).toBeGreaterThanOrEqual(0);
    const artifactPath = join(process.cwd(), "test-results", "pi-sdk-099-bash-structured-output.json");
    await mkdir(dirname(artifactPath), { recursive: true });
    await writeFile(artifactPath, `${JSON.stringify({ structured, parent }, null, 2)}\n`);
  });

  it("aborts a nested codemode bash process tree", async () => {
    if (process.platform === "win32") return;
    const root = await temporaryRoot("tron-codemode-bash-abort-e2e-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensions = join(cwd, ".pi", "extensions");
    await Promise.all([
      mkdir(agentDir), mkdir(extensions, { recursive: true }),
    ]);
    await writeFile(join(agentDir, "settings.json"), JSON.stringify({ defaultTools: ["+codemode"] }));
    const sdkUrl = import.meta.resolve("@earendil-works/pi-coding-agent");
    await writeFile(join(extensions, "codemode.ts"), `import { createCodemodeExtension } from ${JSON.stringify(sdkUrl)}; export default createCodemodeExtension({ mode: "on" });\n`);
    const pidPath = join(cwd, "nested.pid");
    const childProgram = "setInterval(() => {}, 1000)";
    const commandProgram = [
      "const { spawn } = require('node:child_process');",
      "const { writeFileSync } = require('node:fs');",
      `const child = spawn(${JSON.stringify(process.execPath)}, ['-e', ${JSON.stringify(childProgram)}], { detached: true, stdio: 'ignore' });`,
      `writeFileSync(${JSON.stringify(pidPath)}, String(child.pid));`,
      "setInterval(() => {}, 1000);",
    ].join(" ");
    const command = `${JSON.stringify(process.execPath)} -e ${JSON.stringify(commandProgram)}`;
    const faux = fauxProvider({ provider: "tron-codemode-bash-abort", tokensPerSecond: 10_000 });
    faux.setResponses([fauxAssistantMessage([fauxToolCall(
      "codemode", { code: `await tools.bash({ command: ${JSON.stringify(command)} }); return "unexpected";` }, { id: "codemode-bash-abort" },
    )], { stopReason: "toolUse" })]);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const registry = await createTestRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => {
        const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
        runtime.registerNativeProvider(faux.provider);
        return runtime;
      },
      trust, broadcast: () => {},
      sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const prompting = slot.prompt("run nested process");
    await waitFor(() => existsSync(pidPath), "the process id file");
    const childPid = Number(await readFile(pidPath, "utf8"));
    expect(() => process.kill(childPid, 0)).not.toThrow();
    const operationId = slot.snapshot().operation?.id;
    expect(operationId).toBeDefined();
    await slot.abort("codemode", operationId);
    await expect(prompting).resolves.toMatchObject({ operationId });
    await waitFor(() => {
      try { process.kill(childPid, 0); return false; }
      catch { return true; }
    }, "the child process to exit");
    expect(slot.snapshot().toolExecutions).toEqual([]);
  });

  it("connects Pi MCP stdio and streamable HTTP fixtures and exposes resources through composed built-ins", async () => {
    const root = await temporaryRoot("tron-pi-mcp-fixture-e2e-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir, { recursive: true }), mkdir(cwd, { recursive: true })]);
    const fixtureScript = resolve(process.cwd(), "test-fixtures/pi-sdk/mcp-jsonrpc-fixture.mjs");
    const stdioState = join(root, "stdio-state.json");
    const stdioPidFile = join(root, "stdio.pid");
    const stdioChildPidFile = join(root, "stdio-child.pid");
    const httpState = join(root, "http-state.json");
    const httpPortFile = join(root, "http.port");
    const codeState = join(root, "code-state.json");
    const deferredState = join(root, "deferred-state.json");
    const codePidFile = join(root, "code.pid");
    const deferredPidFile = join(root, "deferred.pid");
    const tools = [{ name: "echo", description: "Echo searchable fixture input", inputSchema: { type: "object", properties: { value: { type: "string" } } } }];
    await Promise.all([writeFile(stdioState, JSON.stringify({ tools })), writeFile(httpState, JSON.stringify({ tools })), writeFile(codeState, JSON.stringify({ tools })), writeFile(deferredState, JSON.stringify({ tools }))]);
    const httpProcess = spawn(process.execPath, [fixtureScript, "http", httpState, httpPortFile], { stdio: "ignore" });
    onTestFinished(async () => {
      if (httpProcess.exitCode !== null || httpProcess.signalCode !== null) return;
      const exited = new Promise<void>((resolve) => httpProcess.once("exit", () => resolve()));
      httpProcess.kill("SIGTERM");
      await exited;
    });
    const priorAgentDir = process.env.PI_CODING_AGENT_DIR;
    try {
      await waitFor(() => existsSync(httpPortFile), "the HTTP port file");
      const port = Number(await readFile(httpPortFile, "utf8"));
      await writeFile(join(agentDir, "mcp.json"), JSON.stringify({ mcpServers: {
        stdio: { command: process.execPath, args: [fixtureScript, "stdio", stdioState, stdioPidFile, stdioChildPidFile], exposure: "direct" },
        http: { url: `http://127.0.0.1:${port}/mcp`, headers: { Authorization: "Bearer fixture" }, exposure: "direct" },
        code: { command: process.execPath, args: [fixtureScript, "stdio", codeState, codePidFile], exposure: "codemode" },
        search: { command: process.execPath, args: [fixtureScript, "stdio", deferredState, deferredPidFile], exposure: "deferred" },
      } }));
      process.env.PI_CODING_AGENT_DIR = agentDir;
      const faux = fauxProvider({ provider: "tron-pi-mcp-fixture", tokensPerSecond: 10_000 });
      faux.setResponses([
        fauxAssistantMessage([
          fauxToolCall("mcp__stdio__echo", { value: "stdio" }, { id: "mcp-stdio-call" }),
          fauxToolCall("mcp__http__echo", { value: "http" }, { id: "mcp-http-call" }),
          fauxToolCall("list_mcp_resources", { server: "stdio" }, { id: "mcp-resource-list" }),
          fauxToolCall("read_mcp_resource", { server: "stdio", uri: "fixture://one" }, { id: "mcp-resource-read" }),
          fauxToolCall("codemode", { code: 'return text(await tools.mcp__code__echo({ value: "codemode" }));' }, { id: "mcp-codemode-call" }),
        ], { stopReason: "toolUse" }),
        fauxAssistantMessage([fauxToolCall("tool_search", { query: "searchable fixture input" }, { id: "mcp-tool-search" })], { stopReason: "toolUse" }),
        fauxAssistantMessage([fauxToolCall("mcp__search__echo", { value: "deferred" }, { id: "mcp-deferred-call" })], { stopReason: "toolUse" }),
        fauxAssistantMessage("fixture MCP tools completed"),
        fauxAssistantMessage([fauxToolCall("mcp__stdio__added", { value: "changed" }, { id: "mcp-list-changed-call" })], { stopReason: "toolUse" }),
        fauxAssistantMessage("fixture MCP list changed"),
        fauxAssistantMessage([fauxToolCall("mcp__stdio__added", { value: "reconnected" }, { id: "mcp-lazy-reconnect-call" })], { stopReason: "toolUse" }),
        fauxAssistantMessage("fixture MCP reconnected"),
      ]);
      const modelRuntimeFactory = async () => {
        const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
        runtime.registerNativeProvider(faux.provider);
        return runtime;
      };
      const registry = await createTestRegistry({
        agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, modelRuntimeFactory,
        trust: new TrustService(agentDir), broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
      });
      registries.push(registry);
      await initializeRegistry(registry);
      const slot = await registry.create(cwd);
      const model = faux.getModel();
      await slot.setModel(model.provider, model.id);
      await waitFor(() => {
        const tools = (slot as any).runtime.session.getAllTools() as Array<{ name: string; exposure?: string }>;
        return ["mcp__stdio__echo", "mcp__http__echo"].every(name =>
          tools.some(tool => tool.name === name && tool.exposure === "direct"));
      }, "the direct MCP tools");
      await slot.prompt("call MCP fixtures and resource tools");
      await waitFor(() => !slot.isBusy, "the slot to go idle");
      const transcript = slot.snapshot().transcript;
      for (const [id, text] of [
        ["mcp-stdio-call", "fixture:echo:{\"value\":\"stdio\"}"],
        ["mcp-http-call", "fixture:echo:{\"value\":\"http\"}"],
        ["mcp-resource-list", "fixture://one"],
        ["mcp-resource-read", "fixture resource body"],
        ["mcp-codemode-call", "fixture:echo:"],
        ["mcp-deferred-call", "fixture:echo:{\"value\":\"deferred\"}"],
      ]) {
        const result = transcript.find((item) => item.kind === "message" && item.role === "toolResult" && item.toolCallId === id);
        expect(result?.content?.map((block) => block.type === "text" ? block.text : "").join("\\n")).toContain(text);
      }
      const stdioPid = Number(await readFile(stdioPidFile, "utf8"));
      const stdioChildPid = Number(await readFile(stdioChildPidFile, "utf8"));
      await writeFile(stdioState, JSON.stringify({ tools: [{ ...tools[0], name: "added", description: "Changed fixture tool" }] }));
      await waitFor(() => {
        const tools = (slot as any).runtime.session.getAllTools() as Array<{ name: string; exposure?: string }>;
        return tools.some((tool) => tool.name === "mcp__stdio__added" && tool.exposure === "direct")
          && tools.some((tool) => tool.name === "mcp__stdio__echo" && tool.exposure === "hidden");
      }, "the refreshed MCP tool exposure");
      await slot.prompt("call the newly listed MCP tool");
      await waitFor(() => !slot.isBusy, "the slot to go idle");
      const addedResult = slot.snapshot().transcript.find((item) => item.kind === "message" && item.role === "toolResult" && item.toolCallId === "mcp-list-changed-call");
      expect(addedResult?.content?.map((block) => block.type === "text" ? block.text : "").join("\\n")).toContain("fixture:added");
      process.kill(-stdioPid, "SIGKILL");
      await waitFor(() => {
        try { process.kill(stdioPid, 0); return false; } catch (error) { return (error as NodeJS.ErrnoException).code === "ESRCH"; }
      }, "the stdio MCP process to exit");
      await slot.prompt("retry after the MCP server crash");
      await waitFor(() => !slot.isBusy, "the slot to go idle");
      const reconnectedPid = Number(await readFile(stdioPidFile, "utf8"));
      const reconnectedChildPid = Number(await readFile(stdioChildPidFile, "utf8"));
      expect(reconnectedPid).not.toBe(stdioPid);
      const codePid = Number(await readFile(codePidFile, "utf8"));
      const deferredPid = Number(await readFile(deferredPidFile, "utf8"));
      const allResults = slot.snapshot().transcript.filter((item) => item.kind === "message" && item.role === "toolResult");
      expect([stdioPid, codePid, deferredPid, stdioChildPid, reconnectedPid, reconnectedChildPid].every(Number.isInteger)).toBe(true);
      await registry.dispose();
      registries.splice(registries.indexOf(registry), 1);
      await waitFor(() => [stdioPid, codePid, deferredPid, stdioChildPid, reconnectedPid, reconnectedChildPid].every((pid) => {
        try { process.kill(pid, 0); return false; } catch (error) { return (error as NodeJS.ErrnoException).code === "ESRCH"; }
      }), "the MCP processes to exit");
      const artifactPath = join(process.cwd(), "test-results", "pi-sdk-099-mcp-fixtures.json");
      await mkdir(dirname(artifactPath), { recursive: true });
      await writeFile(artifactPath, `${JSON.stringify({ transport: ["stdio", "streamable-http"], exposure: ["direct", "codemode", "deferred"], transcript: allResults }, null, 2)}\n`);
    } finally {
      if (priorAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
      else process.env.PI_CODING_AGENT_DIR = priorAgentDir;
      await rm(root, { recursive: true, force: true });
    }
  });

  it("reaps a slow-starting MCP stdio process and its child when the runtime is disposed", async () => {
    const root = await temporaryRoot("tron-pi-mcp-startup-dispose-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const fixtureScript = resolve(process.cwd(), "test-fixtures/pi-sdk/mcp-jsonrpc-fixture.mjs");
    const statePath = join(root, "state.json");
    const pidFile = join(root, "server.pid");
    const childPidFile = join(root, "child.pid");
    const readyPath = join(root, "ready");
    await Promise.all([mkdir(agentDir, { recursive: true }), mkdir(cwd, { recursive: true })]);
    await writeFile(statePath, JSON.stringify({ tools: [{ name: "echo", description: "Fixture", inputSchema: { type: "object", properties: {} } }] }));
    await writeFile(join(agentDir, "mcp.json"), JSON.stringify({ mcpServers: {
      slow: { command: process.execPath, args: [fixtureScript, "stdio", statePath, pidFile, childPidFile, "30000", readyPath], exposure: "direct" },
    } }));
    const priorAgentDir = process.env.PI_CODING_AGENT_DIR;
    process.env.PI_CODING_AGENT_DIR = agentDir;
    const faux = fauxProvider({ provider: "tron-pi-mcp-slow-start", tokensPerSecond: 10_000 });
    const modelRuntimeFactory = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    const registry = await createTestRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, maximumLiveRuntimes: 1,
      modelRuntimeFactory, trust: new TrustService(agentDir), broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    let serverPid: number | undefined;
    let childPid: number | undefined;
    const processState = (pid: number | undefined): string => {
      if (pid === undefined) return "absent";
      if (!Number.isSafeInteger(pid) || pid <= 1) throw new Error("Invalid owned MCP fixture PID");
      const result = spawnSync("ps", ["-p", String(pid), "-o", "stat="], { encoding: "utf8" });
      if (result.error) throw result.error;
      if (result.status !== 0 && result.status !== 1) throw new Error(`Cannot inspect owned MCP process ${pid}: ${result.stderr}`);
      return result.stdout.trim() || "absent";
    };
    const terminal = (state: string) => state === "absent" || state.startsWith("Z");
    const states = () => ({ server: processState(serverPid), child: processState(childPid) });
    try {
      await initializeRegistry(registry);
      const slot = await registry.create(cwd);
      const model = faux.getModel();
      await slot.setModel(model.provider, model.id);
      await waitFor(() => existsSync(pidFile) && existsSync(childPidFile), "the starting MCP process and child");
      serverPid = Number(await readFile(pidFile, "utf8"));
      childPid = Number(await readFile(childPidFile, "utf8"));
      expect(existsSync(readyPath)).toBe(false);
      process.kill(serverPid, 0);
      process.kill(childPid, 0);
      await registry.dispose();
      registries.splice(registries.indexOf(registry), 1);
      try {
        await waitFor(() => Object.values(states()).every(terminal), "the starting MCP process group to exit after runtime disposal");
        expect(existsSync(readyPath)).toBe(false);
      } finally {
        await mkdir(join(process.cwd(), "test-results"), { recursive: true });
        await writeFile(join(process.cwd(), "test-results", "pi-sdk-mcp-startup-dispose.json"), `${JSON.stringify({ disposedDuringStartup: true, states: states() }, null, 2)}\n`);
      }
    } finally {
      if (priorAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
      else process.env.PI_CODING_AGENT_DIR = priorAgentDir;
      if (serverPid === undefined && existsSync(pidFile)) serverPid = Number(await readFile(pidFile, "utf8"));
      if (childPid === undefined && existsSync(childPidFile)) childPid = Number(await readFile(childPidFile, "utf8"));
      for (const pid of [serverPid, childPid]) {
        if (pid !== undefined && !terminal(processState(pid))) {
          try { process.kill(pid, "SIGKILL"); } catch (error) {
            if ((error as NodeJS.ErrnoException).code !== "ESRCH") throw error;
          }
        }
      }
      await waitFor(() => Object.values(states()).every(terminal), "owned MCP fixture cleanup");
      if (registries.includes(registry)) {
        await registry.dispose();
        registries.splice(registries.indexOf(registry), 1);
      }
      await rm(root, { recursive: true, force: true });
    }
  });

  it("loads project MCP config only after TrustService authorizes the workspace", async () => {
    const root = await temporaryRoot("tron-pi-mcp-project-trust-");
    const agentDir = join(root, "agent");
    const sessionDir = join(agentDir, "sessions", "workspace");
    const cwd = join(root, "workspace");
    const projectConfigDir = join(cwd, ".pi");
    const pidFile = join(root, "project-server.pid");
    const childPidFile = join(root, "project-server-child.pid");
    const statePath = join(root, "project-state.json");
    const fixtureScript = resolve(process.cwd(), "test-fixtures/pi-sdk/mcp-jsonrpc-fixture.mjs");
    await Promise.all([mkdir(agentDir, { recursive: true }), mkdir(sessionDir, { recursive: true }), mkdir(projectConfigDir, { recursive: true }), writeFile(statePath, JSON.stringify({ tools: [{ name: "project_echo", description: "Trusted project fixture", inputSchema: { type: "object", properties: {} } }] }))]);
    await writeFile(join(agentDir, "mcp.json"), JSON.stringify({ mcpServers: {} }));
    await writeFile(join(projectConfigDir, "mcp.json"), JSON.stringify({ mcpServers: {
      project_fixture: { command: process.execPath, args: [fixtureScript, "stdio", statePath, pidFile, childPidFile], exposure: "direct" },
    } }));
    const priorAgentDir = process.env.PI_CODING_AGENT_DIR;
    process.env.PI_CODING_AGENT_DIR = agentDir;
    const trust = new TrustService(agentDir);
    await trust.set(cwd, false);
    const faux = fauxProvider({ provider: "tron-pi-mcp-project-trust", tokensPerSecond: 10_000 });
    faux.setResponses([
      fauxAssistantMessage("untrusted project ignored"),
      fauxAssistantMessage([fauxToolCall("mcp__project_fixture__project_echo", {}, { id: "trusted-project-call" })], { stopReason: "toolUse" }),
      fauxAssistantMessage("trusted project tool completed"),
    ]);
    const modelRuntimeFactory = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    const makeRegistry = async () => await createTestRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, maximumLiveRuntimes: 1,
      modelRuntimeFactory, trust, broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    let registry = await makeRegistry();
    registries.push(registry);
    try {
      await initializeRegistry(registry);
      let slot = await registry.create(cwd);
      const model = faux.getModel();
      await slot.setModel(model.provider, model.id);
      await slot.prompt("load an untrusted project");
      await waitFor(() => !slot.isBusy, "the slot to go idle");
      expect(existsSync(pidFile)).toBe(false);
      expect((slot as any).runtime.session.getAllTools().some((tool: { name: string }) => tool.name === "mcp__project_fixture__project_echo")).toBe(false);
      const sessionId = slot.id;
      await registry.dispose();
      registries.splice(registries.indexOf(registry), 1);
      await trust.set(cwd, true);
      registry = await makeRegistry();
      registries.push(registry);
      await initializeRegistry(registry);
      slot = await registry.acquire(sessionId);
      await slot.setModel(model.provider, model.id);
      await slot.prompt("load trusted project MCP");
      await waitFor(() => !slot.isBusy && existsSync(pidFile), "the idle slot and its process id file");
      const trustedResult = slot.snapshot().transcript.find((item) => item.kind === "message" && item.role === "toolResult" && item.toolCallId === "trusted-project-call");
      expect(trustedResult?.content?.map((block) => block.type === "text" ? block.text : "").join("\\n")).toContain("fixture:project_echo");
      const processId = Number(await readFile(pidFile, "utf8"));
      const childProcessId = Number(await readFile(childPidFile, "utf8"));
      const secondCwd = join(root, "second-workspace");
      await mkdir(secondCwd, { recursive: true });
      await registry.create(secondCwd);
      await waitFor(() => {
        try { process.kill(processId, 0); return false; } catch (error) { return (error as NodeJS.ErrnoException).code === "ESRCH"; }
      }, "the process to exit");
      await waitFor(() => {
        try { process.kill(childProcessId, 0); return false; } catch (error) { return (error as NodeJS.ErrnoException).code === "ESRCH"; }
      }, "the child process to exit");
      await registry.dispose();
      registries.splice(registries.indexOf(registry), 1);
      await waitFor(() => {
        try { process.kill(processId, 0); return false; } catch (error) { return (error as NodeJS.ErrnoException).code === "ESRCH"; }
      }, "the process to exit");
      const artifactPath = join(process.cwd(), "test-results", "pi-sdk-099-mcp-project-trust.json");
      await mkdir(dirname(artifactPath), { recursive: true });
      await writeFile(artifactPath, `${JSON.stringify({ untrustedProjectServerStarted: false, trustedProjectServerCalled: true, capacityEvictedProcessGroupTerminated: true }, null, 2)}\n`);
    } finally {
      await registry.dispose().catch(() => {});
      const index = registries.indexOf(registry);
      if (index >= 0) registries.splice(index, 1);
      if (priorAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
      else process.env.PI_CODING_AGENT_DIR = priorAgentDir;
      await rm(root, { recursive: true, force: true });
    }
  });

  it("stops sleeping and tool-looping codemode scripts and drains active codemode work", async () => {
    const root = await temporaryRoot("tron-pi-codemode-stop-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await Promise.all([mkdir(agentDir, { recursive: true }), mkdir(extensionDir, { recursive: true })]);
    const holdExtension = `export default function (pi) {
      pi.registerTool({ name: "hold", label: "Hold", description: "Wait until cancelled or its deadline", parameters: { type: "object", properties: { ms: { type: "number" } }, required: ["ms"] }, execute: async (_id, args) => {
        await new Promise((resolve) => setTimeout(resolve, args.ms));
        return { content: [{ type: "text", text: "released" }] };
      } });
    }`;
    const sdkUrl = import.meta.resolve("@earendil-works/pi-coding-agent");
    await Promise.all([
      writeFile(join(agentDir, "settings.json"), JSON.stringify({ defaultTools: ["+codemode"] })),
      writeFile(join(extensionDir, "codemode.ts"), `import { createCodemodeExtension } from ${JSON.stringify(sdkUrl)}; export default createCodemodeExtension({ mode: "on" });\n`),
      writeFile(join(extensionDir, "hold.ts"), `${holdExtension}\n`),
    ]);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const faux = fauxProvider({ provider: "tron-pi-codemode-stop", tokensPerSecond: 10_000 });
    const call = (id: string, code: string) => fauxAssistantMessage([fauxToolCall("codemode", { code }, { id })], { stopReason: "toolUse" });
    faux.setResponses([
      call("codemode-sleep", 'await new Promise(resolve => setTimeout(resolve, 30_000)); return "late";'),
      call("codemode-loop", 'while (true) await tools.hold({ ms: 250 });'),
      call("codemode-drain", 'await tools.hold({ ms: 400 }); return "drained";'),
      fauxAssistantMessage("drain completed"),
    ]);
    const modelRuntimeFactory = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    const registry = await createTestRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, modelRuntimeFactory, trust,
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    try {
      await initializeRegistry(registry);
      const slot = await registry.create(cwd);
      const model = faux.getModel();
      await slot.setModel(model.provider, model.id);
      const sleepPrompt = slot.prompt("run sleeping codemode script");
      await waitFor(() => slot.snapshot().toolExecutions.some((tool) => tool.toolCallId === "codemode-sleep"), "the codemode sleep tool");
      await slot.abort("agent");
      await sleepPrompt;
      await waitFor(() => !slot.isBusy, "the slot to go idle");
      expect(slot.snapshot().transcript.find((item) => item.kind === "message" && item.role === "toolResult" && item.toolCallId === "codemode-sleep")).toMatchObject({ isError: true });
      const loopPrompt = slot.prompt("run tool-looping codemode script");
      await waitFor(() => slot.snapshot().toolExecutions.some((tool) => tool.toolCallId === "codemode-loop" && (tool.nestedCalls?.calls.length ?? 0) > 0), "the codemode loop's nested calls").catch(() => { throw new Error(`codemode loop did not call tools: ${JSON.stringify(slot.snapshot().transcript.slice(-6))}`); });
      await slot.abort("agent");
      await loopPrompt;
      await waitFor(() => !slot.isBusy, "the slot to go idle");
      const stoppedLoop = slot.snapshot().transcript.find((item) => item.kind === "message" && item.role === "toolResult" && item.toolCallId === "codemode-loop");
      expect(stoppedLoop).toMatchObject({ isError: true, nestedCalls: { calls: [expect.objectContaining({ toolName: "hold" })] } });
      const drainPrompt = slot.prompt("run codemode under administrative drain");
      await waitFor(() => slot.snapshot().toolExecutions.some((tool) => tool.toolCallId === "codemode-drain"), "the codemode drain tool");
      let drained = false;
      const drain = registry.waitUntilIdle().then(() => { drained = true; });
      await new Promise((resolve) => setTimeout(resolve, 50));
      expect(drained).toBe(false);
      await drainPrompt;
      await drain;
      expect(drained).toBe(true);
      expect(faux.state.callCount).toBeGreaterThanOrEqual(3);
      const artifactPath = join(process.cwd(), "test-results", "pi-sdk-099-codemode-stop-drain.json");
      await mkdir(dirname(artifactPath), { recursive: true });
      await writeFile(artifactPath, `${JSON.stringify({ stopped: ["sleeping-script", "tool-loop"], drainWaitedFor: true, settled: slot.snapshot().transcript.filter((item) => item.kind === "message" && item.role === "toolResult" && item.toolName === "codemode").map((item) => ({ toolCallId: item.toolCallId, isError: item.isError })) }, null, 2)}\n`);
    } finally {
      await registry.dispose();
      const index = registries.indexOf(registry);
      if (index >= 0) registries.splice(index, 1);
      await rm(root, { recursive: true, force: true });
    }
  });

  it("keeps one tool display segment across tool-only agent continuations", async () => {
    const root = await temporaryRoot("tron-tool-segment-continuation-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    await writeFile(join(cwd, "one.txt"), "one\n");
    await writeFile(join(cwd, "two.txt"), "two\n");

    const faux = fauxProvider({ provider: "tron-tool-segment-continuation", tokensPerSecond: 10_000 });
    faux.setResponses([
      fauxAssistantMessage([
        fauxToolCall("read", { path: join(cwd, "one.txt") }, { id: "call-one" }),
      ], { stopReason: "toolUse" }),
      fauxAssistantMessage([
        fauxToolCall("read", { path: join(cwd, "two.txt") }, { id: "call-two" }),
      ], { stopReason: "toolUse" }),
      fauxAssistantMessage("finished"),
    ]);
    const createModels = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    const progress: Array<{ toolCallId: string; toolSegmentId?: string }> = [];
    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: createModels,
      trust: new TrustService(agentDir),
      broadcast: (_sessionId, topic, payload) => {
        if (topic === "session.toolProgress") progress.push(payload.data);
      },
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("run sequential tools");
    await waitFor(() => !slot.isBusy, "the slot to go idle");

    const segmentByCall = new Map(progress.map(event => [event.toolCallId, event.toolSegmentId]));
    expect(segmentByCall.get("call-one")).toMatch(/^tool-segment:/);
    expect(segmentByCall.get("call-two")).toBe(segmentByCall.get("call-one"));
    const canonicalSegments = slot.snapshot().transcript.flatMap(item =>
      item.kind === "message" && item.role === "assistant"
        ? item.content.flatMap(part => part.type === "toolCall" ? [part.toolSegmentId] : [])
        : []
    );
    expect(new Set(canonicalSegments)).toEqual(new Set([segmentByCall.get("call-one")]));
  });

  it("rotates tool segment authority across a visible assistant barrier before new tool progress", async () => {
    const root = await temporaryRoot("tron-tool-segment-visible-barrier-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    await Promise.all([
      writeFile(join(cwd, "one.txt"), "one\n"),
      writeFile(join(cwd, "two.txt"), "two\n"),
    ]);

    const faux = fauxProvider({ provider: "tron-tool-segment-visible-barrier", tokensPerSecond: 10_000 });
    faux.setResponses([
      fauxAssistantMessage([
        fauxToolCall("read", { path: join(cwd, "one.txt") }, { id: "call-before-barrier" }),
        { type: "text", text: "Visible checkpoint" },
      ], { stopReason: "toolUse" }),
      fauxAssistantMessage([
        fauxToolCall("read", { path: join(cwd, "two.txt") }, { id: "call-after-barrier" }),
      ], { stopReason: "toolUse" }),
      fauxAssistantMessage("finished"),
    ]);
    const events: Array<{ topic: string; payload: any }> = [];
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
      broadcast: (_sessionId, topic, payload) => events.push({ topic, payload }),
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    subscribeAudience(registry, slot.id);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("run tools around a visible barrier");
    await waitFor(() => !slot.isBusy, "the slot to go idle");

    const toolProgress = events
      .filter((event) => event.topic === "session.toolProgress")
      .map((event) => event.payload.data as { toolCallId: string; toolSegmentId?: string });
    const segmentByCall = new Map(toolProgress.map((event) => [event.toolCallId, event.toolSegmentId]));
    const beforeSegment = segmentByCall.get("call-before-barrier");
    const afterSegment = segmentByCall.get("call-after-barrier");
    expect(beforeSegment).toMatch(/^tool-segment:/);
    expect(afterSegment).toMatch(/^tool-segment:/);
    expect(afterSegment).not.toBe(beforeSegment);

    const canonicalSegmentByCall = new Map(slot.snapshot().transcript.flatMap((item) =>
      item.kind === "message" && item.role === "assistant"
        ? item.content.flatMap((part) => part.type === "toolCall"
          ? [[part.toolCallId, part.toolSegmentId] as const]
          : [])
        : []
    ));
    expect(canonicalSegmentByCall.get("call-before-barrier")).toBe(beforeSegment);
    expect(canonicalSegmentByCall.get("call-after-barrier")).toBe(afterSegment);

    const afterProgressIndex = events.findIndex((event) =>
      event.topic === "session.toolProgress"
        && event.payload.data?.toolCallId === "call-after-barrier"
    );
    const precedingAuthorityIndex = events.findLastIndex((event, index) => {
      if (index >= afterProgressIndex || event.topic !== "session.snapshot") return false;
      const snapshot = event.payload?.data ?? event.payload;
      return snapshot.activeToolSegmentId === afterSegment;
    });
    expect(afterProgressIndex).toBeGreaterThanOrEqual(0);
    expect(precedingAuthorityIndex).toBeGreaterThanOrEqual(0);
    expect(precedingAuthorityIndex).toBeLessThan(afterProgressIndex);
  });

  it("rotates tool segment authority at a visible custom-message barrier", async () => {
    const root = await temporaryRoot("tron-tool-segment-custom-barrier-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await Promise.all([mkdir(agentDir), mkdir(extensionDir, { recursive: true })]);
    await writeFile(join(extensionDir, "visible-barrier.ts"), `
let sent = false;
export default function (pi) {
  pi.on("turn_end", () => {
    if (sent) return;
    sent = true;
    pi.sendMessage({ customType: "visible-boundary", content: "Visible extension input", display: true }, { triggerTurn: true });
  });
}
`);
    await Promise.all([
      writeFile(join(cwd, "one.txt"), "one\n"),
      writeFile(join(cwd, "two.txt"), "two\n"),
    ]);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const faux = fauxProvider({ provider: "tron-tool-segment-custom-barrier", tokensPerSecond: 10_000 });
    faux.setResponses([
      fauxAssistantMessage([
        fauxToolCall("read", { path: join(cwd, "one.txt") }, { id: "call-before-custom" }),
      ], { stopReason: "toolUse" }),
      fauxAssistantMessage([
        fauxToolCall("read", { path: join(cwd, "two.txt") }, { id: "call-after-custom" }),
      ], { stopReason: "toolUse" }),
      fauxAssistantMessage("finished"),
    ]);
    const progress: Array<{ toolCallId: string; toolSegmentId?: string }> = [];
    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => {
        const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
        runtime.registerNativeProvider(faux.provider);
        return runtime;
      },
      trust,
      broadcast: (_sessionId, topic, payload) => {
        if (topic === "session.toolProgress") progress.push(payload.data);
      },
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("run tools around visible extension input");
    await waitFor(() => !slot.isBusy, "the slot to go idle");

    const segmentByCall = new Map(progress.map((event) => [event.toolCallId, event.toolSegmentId]));
    const beforeSegment = segmentByCall.get("call-before-custom");
    const afterSegment = segmentByCall.get("call-after-custom");
    expect(beforeSegment).toMatch(/^tool-segment:/);
    expect(afterSegment).toMatch(/^tool-segment:/);
    expect(afterSegment).not.toBe(beforeSegment);
    const snapshot = slot.snapshot();
    expect(snapshot.transcript.some((item) => item.kind === "customMessage")).toBe(true);
    const canonicalSegmentByCall = new Map(snapshot.transcript.flatMap((item) =>
      item.kind === "message" && item.role === "assistant"
        ? item.content.flatMap((part) => part.type === "toolCall"
          ? [[part.toolCallId, part.toolSegmentId] as const]
          : [])
        : []
    ));
    expect(canonicalSegmentByCall.get("call-before-custom")).toBe(beforeSegment);
    expect(canonicalSegmentByCall.get("call-after-custom")).toBe(afterSegment);
  });

  it.each(["global", "project"] as const)("a loaded %s extension cannot raise a Tron change card but keeps attributed dialogs", async source => {
    const root = await temporaryRoot("tron-extension-change-refused-");
    const agentDir = join(root, "agent"), cwd = join(root, "workspace");
    const extensionDir = source === "global" ? join(agentDir, "extensions") : join(cwd, ".pi", "extensions");
    await Promise.all([mkdir(agentDir, { recursive: true }), mkdir(cwd, { recursive: true }), mkdir(extensionDir, { recursive: true })]);
    await writeFile(join(extensionDir, "untrusted-card.ts"), `export default function (pi) {
      pi.registerCommand("try-change-card", { handler: async (_args, ctx) => {
        const request = ctx.ui["tron.change.v1"];
        if (request) await request({ review: { title: "Impersonated Tron change", digest: "a".repeat(64), requiresTap: true,
          items: [{ label: "Effect", before: "Absent", after: "Present" }] }, apply: async () => "spoofed" });
        else ctx.ui.setStatus("change-refused", "Tron change cards unavailable");
        await ctx.ui.confirm("Extension dialog", "Ordinary presentation only");
      }});
    }`);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const faux = fauxProvider({ provider: "tron-extension-card-refused", tokensPerSecond: 10_000 });
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const registry = await createTestRegistry({ agentDir, tronHome: join(root, "tron"), trust,
      modelRuntimeFactory: async () => runtime, broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {} });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const command = slot.prompt("/try-change-card");
    void command.catch(() => {});
    const pending = await waitFor(() => slot.snapshot().extensionPresentation.pendingInteractions[0], "extension dialog or forbidden card");
    expect(pending.method).toBe("confirm");
    expect(pending.owner).toMatchObject({ id: expect.stringMatching(/^extension:/), title: "Untrusted Card", source: "auto" });
    expect(slot.snapshot().extensionPresentation.semanticState.statuses).toHaveProperty("change-refused");
    slot.respondToInteraction(pending.id, pending.hostEpoch, pending.presentationRevision, true, false);
    await command;
    expect(slot.snapshot().extensionPresentation.pendingInteractions).toEqual([]);
  });

  it("permits one delayed agent start owned by an accepted extension command during drain", async () => {
    const root = await temporaryRoot("tron-drain-extension-command-start-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await Promise.all([mkdir(agentDir), mkdir(extensionDir, { recursive: true })]);
    await writeFile(join(extensionDir, "command.ts"), `export default function (pi) {
      pi.registerCommand("start-after-confirm", { handler: async (_args, ctx) => {
        if (await ctx.ui.confirm("Start", "Continue?")) {
          pi.sendMessage({ customType: "confirmed", content: "continue", display: false }, { triggerTurn: true });
        }
      }});
    }\n`);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const faux = fauxProvider({ provider: "tron-drain-extension-command-start", tokensPerSecond: 10_000 });
    faux.setResponses([fauxAssistantMessage("command continuation complete")]);
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
    const command = slot.prompt("/start-after-confirm");
    await waitFor(() => slot.snapshot().extensionPresentation.pendingInteractions.length === 1, "the pending interaction");
    const pending = slot.snapshot().extensionPresentation.pendingInteractions[0]!;
    const drain = registry.waitUntilIdle();
    slot.respondToInteraction(pending.id, pending.hostEpoch, pending.presentationRevision, true, false);
    await command;
    await drain;
    expect(faux.state.callCount).toBe(1);
    expect(failures).toEqual([]);
    expect(slot.snapshot()).toMatchObject({ phase: "idle" });
  });

  it("retires a command-triggered foreground owner when the turn has no successful assistant completion", async () => {
    const root = await temporaryRoot("tron-failed-command-turn-drain-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await Promise.all([mkdir(agentDir), mkdir(extensionDir, { recursive: true })]);
    await writeFile(join(extensionDir, "failed-turn.ts"), `export default function (pi) {
      pi.registerCommand("start-failed-turn", { handler: async (_args, ctx) => {
        pi.sendMessage({ customType: "failed-turn", content: "continue", display: false }, { triggerTurn: true });
      }});
    }\n`);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const faux = fauxProvider({ provider: "tron-failed-command-turn", tokensPerSecond: 10_000 });
    faux.setResponses([{
      ...fauxAssistantMessage("provider failed"),
      stopReason: "error",
      errorMessage: "injected provider failure",
    }]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const workRegistry = new GatewayWorkRegistry("failed-command-turn-epoch");
    const derivedAdmissions = vi.spyOn(workRegistry, "beginDerived");
    const registry = await createTestRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust, workRegistry,
      modelRuntimeFactory: async () => runtime,
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);

    await slot.prompt("/start-failed-turn").catch(() => {});
    await waitFor(() => slot.catalogPhase === "idle" || slot.catalogPhase === "interrupted", "the catalog phase to settle");
    await waitFor(() => workRegistry.size === 0, "the work registry to drain");
    expect(faux.state.callCount).toBeGreaterThan(0);
    expect(derivedAdmissions.mock.calls.some(([admission]) =>
      admission.kind === "foreground-agent-operation"
    )).toBe(true);
    const markerPath = join(root, "tron", "state", "runtime-markers", `${slot.id}.json`);
    if (existsSync(markerPath)) {
      const marker = JSON.parse(await readFile(markerPath, "utf8")) as { operations: unknown[] };
      expect(marker.operations).toEqual([]);
    }
    await registry.waitUntilIdle();
    expect(registry.administrativeDrainSnapshot()).toMatchObject({
      phase: "complete", blockerCount: 0, suspectProjectionCount: 0,
    });
  });

  it("classifies and reconciles an unrepresented foreground token during drain", async () => {
    const fixture = await coldFixture("orphaned-foreground-drain");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as {
      pendingPrompt?: { id: string; createdAt: string; text: string; attachmentCount: number };
      runWork: import("../../kernel/run/run-work-owner.js").RunWorkOwner;
      runtime: { session: { readonly isStreaming: boolean } };
      dependencies: { markers: { mark: (sessionId: string, operationId: string) => Promise<void> } };
    };
    internal.runWork.beginDerivedOperationWork("orphaned-operation", "foreground-agent-operation");
    internal.pendingPrompt = {
      id: "orphaned-operation",
      createdAt: new Date().toISOString(),
      text: "stale provisional prompt",
      attachmentCount: 0,
    };
    await internal.dependencies.markers.mark(slot.id, "orphaned-operation");
    const streaming = vi.spyOn(internal.runtime.session, "isStreaming", "get").mockReturnValue(true);

    const admitted = fixture.registry.beginAdministrativeDrain();
    expect(admitted).toMatchObject({
      blockerCount: 1,
      suspectProjectionCount: 0,
      blockers: [expect.objectContaining({
        category: "foreground-agent-operation", state: "active",
      })],
    });
    streaming.mockRestore();
    expect(fixture.registry.administrativeDrainSnapshot()).toMatchObject({
      blockerCount: 1,
      suspectProjectionCount: 1,
      blockers: [expect.objectContaining({
        category: "foreground-agent-operation", state: "suspect",
      })],
    });
    await fixture.registry.waitUntilIdle();
    expect(fixture.registry.administrativeDrainSnapshot()).toMatchObject({
      phase: "complete", blockerCount: 0, suspectProjectionCount: 0,
    });
    expect(slot.snapshot().pendingPrompt).toBeUndefined();
    const markerPath = join(fixture.root, "tron", "state", "runtime-markers", `${slot.id}.json`);
    if (existsSync(markerPath)) {
      const marker = JSON.parse(await readFile(markerPath, "utf8")) as { operations: unknown[] };
      expect(marker.operations).toEqual([]);
    }
  });

  it("reasserts ownership restored while orphan marker cleanup yields", async () => {
    const fixture = await coldFixture("orphan-marker-race");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as {
      phase: "idle" | "running";
      activeOperationId?: string;
      operation?: { id?: string; kind: "prompt"; startedAt: string };
      runWork: import("../../kernel/run/run-work-owner.js").RunWorkOwner;
      dependencies: { markers: {
        mark: (sessionId: string, operationId: string) => Promise<void>;
        clear: (sessionId: string, operationId?: string) => Promise<void>;
        evidenceFor: (sessionId: string) => Promise<Array<{ operationId: string }>>;
      } };
    };
    internal.runWork.beginDerivedOperationWork("racing-operation", "foreground-agent-operation");
    await internal.dependencies.markers.mark(slot.id, "racing-operation");
    const mark = vi.spyOn(internal.dependencies.markers, "mark");
    const originalClear = internal.dependencies.markers.clear.bind(internal.dependencies.markers);
    let releaseClear!: () => void;
    const clearBarrier = new Promise<void>((resolve) => { releaseClear = resolve; });
    const clear = vi.spyOn(internal.dependencies.markers, "clear")
      .mockImplementationOnce(async () => clearBarrier)
      .mockImplementation(originalClear);

    const drain = fixture.registry.waitUntilIdle();
    await waitFor(() => clear.mock.calls.length === 1, "the marker clear");
    internal.phase = "running";
    internal.activeOperationId = "racing-operation";
    internal.operation = {
      id: "racing-operation", kind: "prompt", startedAt: new Date().toISOString(),
    };
    releaseClear();
    await waitFor(() => mark.mock.calls.length === 1, "the marker write");
    await expect(internal.dependencies.markers.evidenceFor(slot.id)).resolves.toEqual([
      expect.objectContaining({ operationId: "racing-operation" }),
    ]);

    internal.phase = "idle";
    internal.activeOperationId = undefined;
    internal.operation = undefined;
    await drain;
    expect(clear.mock.calls.length).toBeGreaterThanOrEqual(2);
    await expect(internal.dependencies.markers.evidenceFor(slot.id)).resolves.toEqual([]);
  });

  it("fails a drain instead of waiting forever on foreground work without a captured slot", async () => {
    const workRegistry = new GatewayWorkRegistry("missing-slot-drain-epoch");
    const fixture = await coldFixture("missing-slot-drain", { workRegistry });
    const stranded = workRegistry.begin({
      kind: "foreground-agent-operation",
      sessionId: "missing-slot",
      hostEpoch: "missing-slot-drain-epoch",
    });

    await expect(fixture.registry.waitUntilIdle()).rejects.toThrow(
      /foreground ownership without a captured runtime slot/u,
    );
    expect(fixture.registry.administrativeDrainSnapshot()).toMatchObject({
      phase: "failed", blockerCount: 1, suspectProjectionCount: 1,
    });
    stranded.settle();
  });

  it("does not treat an ownerless late agent settlement as all-marker authority", async () => {
    const fixture = await coldFixture("ownerless-late-settlement");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as {
      pendingExtensionCommand?: { id: string; kind: "command"; startedAt: string };
      onEvent: (event: { type: "agent_settled" }) => void;
      dependencies: { markers: {
        mark: (sessionId: string, operationId: string) => Promise<void>;
        evidenceFor: (sessionId: string) => Promise<Array<{ operationId: string }>>;
      } };
    };
    internal.pendingExtensionCommand = {
      id: "command-owner", kind: "command", startedAt: new Date().toISOString(),
    };
    await internal.dependencies.markers.mark(slot.id, "other-owner-one");
    await internal.dependencies.markers.mark(slot.id, "other-owner-two");

    internal.onEvent({ type: "agent_settled" });

    await expect(internal.dependencies.markers.evidenceFor(slot.id)).resolves.toEqual([
      expect.objectContaining({ operationId: "other-owner-one" }),
      expect.objectContaining({ operationId: "other-owner-two" }),
    ]);
  });

  it("retires an exact provisional prompt projection even after its work token already settled", async () => {
    const fixture = await coldFixture("settled-provisional-prompt");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as {
      pendingPrompt?: {
        id: string; createdAt: string; text: string; attachmentCount: number;
      };
      runWork: import("../../kernel/run/run-work-owner.js").RunWorkOwner;
    };
    internal.pendingPrompt = {
      id: "settled-operation",
      createdAt: new Date().toISOString(),
      text: "settled prompt",
      attachmentCount: 0,
    };

    internal.runWork.settleOperationWork("settled-operation");

    expect(slot.snapshot().pendingPrompt).toBeUndefined();
  });

  it("admits exact extension commands while streaming without hiding the foreground run", async () => {
    const root = await temporaryRoot("tron-streaming-extension-command-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await Promise.all([mkdir(agentDir), mkdir(extensionDir, { recursive: true })]);
    await writeFile(join(extensionDir, "stream-command.ts"), `export default function (pi) {
      pi.registerCommand("during-stream", {
        description: "Wait for native confirmation",
        handler: async (_args, ctx) => {
          if (await ctx.ui.confirm("Streaming command", "Continue?")) ctx.ui.setStatus("stream-command", "accepted");
        },
      });
    }\n`);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const faux = fauxProvider({ provider: "tron-stream-command", tokensPerSecond: 1 });
    faux.setResponses([fauxAssistantMessage("streaming ".repeat(100))]);
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
    await slot.prompt("start foreground streaming");
    await waitFor(() => slot.catalogPhase === "running", "the catalog phase to run");

    const markerDependencies = (slot as unknown as {
      dependencies: { markers: { mark: (sessionId: string, operationId: string) => Promise<void> } };
    }).dependencies.markers;
    const failedMarker = vi.spyOn(markerDependencies, "mark").mockRejectedValueOnce(new Error("injected marker failure"));
    const recoveredCommand = slot.prompt("/during-stream");
    await waitFor(() => slot.snapshot().extensionPresentation.pendingInteractions.length === 1, "the pending interaction");
    const recoveredPending = slot.snapshot().extensionPresentation.pendingInteractions[0]!;
    slot.respondToInteraction(recoveredPending.id, recoveredPending.hostEpoch, recoveredPending.presentationRevision, false, true);
    await expect(recoveredCommand).resolves.toEqual({ operationId: expect.any(String) });
    await waitFor(() => (slot as any).pendingExtensionCommand === undefined, "the pending extension command to clear");
    expect(failedMarker.mock.calls.length).toBeGreaterThanOrEqual(2);
    failedMarker.mockRestore();

    let resolveAdmission!: (result: { operationId: string }) => void;
    const admission = new Promise<{ operationId: string }>((resolve) => { resolveAdmission = resolve; });
    const command = slot.prompt(
      "/during-stream",
      [],
      undefined,
      undefined,
      resolveAdmission,
    );
    await expect(admission).resolves.toEqual({ operationId: expect.any(String) });
    await waitFor(() => slot.snapshot().extensionPresentation.pendingInteractions.length === 1, "the pending interaction");
    const pending = slot.snapshot().extensionPresentation.pendingInteractions[0]!;
    const during = slot.snapshot();
    expect(during.phase).toBe("running");
    expect(during.operation?.kind).toBe("prompt");
    expect((slot as any).pendingExtensionCommand?.kind).toBe("command");
    const marker = JSON.parse(await readFile(join(root, "tron", "state", "runtime-markers", `${slot.id}.json`), "utf8")) as {
      operations: Array<{ operationId: string }>;
    };
    expect(marker.operations.map((operation) => operation.operationId)).toContain((slot as any).pendingExtensionCommand?.id);
    let drainSettled = false;
    const drain = registry.waitUntilIdle().then(() => { drainSettled = true; });
    await new Promise((resolve) => setTimeout(resolve, 25));
    expect(drainSettled).toBe(false);
    slot.respondToInteraction(pending.id, pending.hostEpoch, pending.presentationRevision, true, false);
    await expect(command).resolves.toEqual({ operationId: expect.any(String) });
    await waitFor(() => (slot as any).pendingExtensionCommand === undefined, "the pending extension command to clear");
    expect(slot.snapshot().extensionPresentation.semanticState.statuses["stream-command"]).toBe("accepted");
    let releaseMarkerClear!: () => void;
    const markerClearBarrier = new Promise<void>((resolve) => { releaseMarkerClear = resolve; });
    const markerStore = (slot as unknown as {
      dependencies: { markers: { clear: (sessionId: string, operationId?: string) => Promise<void> } };
    }).dependencies.markers;
    const originalClear = markerStore.clear.bind(markerStore);
    const markerClear = vi.spyOn(markerStore, "clear").mockImplementationOnce(async () => markerClearBarrier);
    const aborting = slot.abort();
    await waitFor(() => markerClear.mock.calls.length === 1, "the marker clear");
    await new Promise((resolve) => setTimeout(resolve, 25));
    expect(drainSettled).toBe(false);
    markerClear.mockImplementation(originalClear);
    releaseMarkerClear();
    await aborting;
    await waitFor(() => slot.catalogPhase === "idle", "the catalog phase to go idle");
    await drain;
    expect(drainSettled).toBe(true);
  });

  it("rejects scheduled plain-text extension commands before effects or retained operation ownership", async () => {
    const fixture = await coldFixture("scheduled-literal-command");
    const { registry, root, cwd, agentDir } = fixture;
    let handle: AutomationExecutionHandle | undefined;
    try {
      const extensionDir = join(cwd, ".pi", "extensions");
      const sentinel = join(root, "command-effect.txt");
      await mkdir(extensionDir, { recursive: true });
      await writeFile(join(extensionDir, "owned-command.ts"), `import { writeFile } from "node:fs/promises";
        export default function (pi) {
          pi.registerCommand("owned-command", {
            handler: async () => { await writeFile(${JSON.stringify(sentinel)}, "executed"); },
          });
        }\n`);
      await new TrustService(agentDir).set(cwd, true);
      const slot = await registry.acquire(fixture.manager.getSessionId());
      expect(slot.commands()).toContainEqual(expect.objectContaining({ name: "owned-command", source: "extension" }));
      const action = { kind: "sessionPrompt" as const, text: "/owned-command argument" };
      expect(admitsAutomationAction(action)).toBe(true);
      const record: AutomationRecord = {
        schemaVersion: 2, id: "10000000-0000-4000-8000-000000000001", revision: 1, stateRevision: 1,
        name: "Scheduled prompt", activation: "enabled", createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z",
        provenance: { kind: "local" }, target: { kind: "existingSession", sessionId: slot.id },
        trigger: { kind: "once", at: "2026-01-01T01:00:00.000Z" }, misfirePolicy: "latest", overlapPolicy: "skip",
        executionDeadlineSeconds: 3_600, action, nextOccurrenceAt: "2026-01-01T01:00:00.000Z",
        consecutiveFailureCount: 0, history: [],
      };
      const run: AutomationRun = {
        runId: "10000000-0000-4000-8000-000000000002", occurrenceId: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        automationRevision: 1, scheduledFor: "2026-01-01T01:00:00.000Z", triggerSnapshot: record.trigger,
        actionSnapshot: action, targetSnapshot: record.target, executionSessionId: slot.id, state: "admitting",
        createdAt: "2026-01-01T01:00:00.000Z", preAdmissionAttemptCount: 0,
        operationId: "automation:10000000-0000-4000-8000-000000000002",
      };
      const work = registry.administrativeWorkRegistry;
      const executor = new GatewayAutomationExecutor(registry, work, undefined, undefined);
      await expect.soft(executor.start(record, run).then((admitted) => { handle = admitted; return admitted; }))
        .rejects.toMatchObject({ retryable: false, reason: "agent-admission-rejected" });
      expect.soft(existsSync(sentinel)).toBe(false);
      expect.soft(work.size).toBe(0);
      expect.soft(slot.isEvictionProtected).toBe(false);
      expect((await registry.ownedOperationRecoveryEvidence(slot.id, run.operationId!)).marker).toBeUndefined();

      await slot.prompt(action.text);
      expect(await readFile(sentinel, "utf8")).toBe("executed");
      expect(work.size).toBe(0);
    } finally {
      await handle?.acknowledgeTerminal?.();
      await registry.dispose();
      registries.splice(registries.indexOf(registry), 1);
      await rm(root, { recursive: true, force: true });
    }
  });

  it("persists extension notifications as centered non-context rows with exact command provenance", async () => {
    const root = await temporaryRoot("tron-extension-command-notification-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await Promise.all([mkdir(agentDir), mkdir(extensionDir, { recursive: true })]);
    await writeFile(join(extensionDir, "notify-command.ts"), `export default function (pi) {
      pi.registerCommand("notify-command", {
        handler: async (_args, ctx) => {
          ctx.ui.notify("Goal created.", "info");
          pi.sendMessage({
            customType: "goal-event",
            content: "Goal created.",
            display: true,
            details: { goal: { objective: "count to 20", status: "active" } },
          });
          pi.sendMessage({
            customType: "goal-audit",
            content: "Goal receipt stored.",
            display: true,
          });
        },
      });
    }\n`);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      trust,
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);

    await expect(slot.prompt("/notify-command count to 20")).resolves.toEqual({ operationId: expect.any(String) });
    await waitFor(() => slot.snapshot().transcript.some(item =>
      item.kind === "customEntry" && item.semantic?.kind === "status"), "the status entry in the transcript");
    await waitFor(() => slot.snapshot().transcript.filter(item =>
      item.kind === "customMessage" && item.semantic?.origin.kind === "extension").length === 2, "both extension messages in the transcript");
    const snapshot = slot.snapshot();
    const command = snapshot.transcript.find(item => item.semantic?.kind === "command");
    const commandOwnerID = command?.semantic?.origin.ownerId;
    expect(command).toMatchObject({
      semantic: {
        direction: "ambientStatus",
        contextEffect: "none",
        lifecycle: "completed",
        origin: { kind: "extension", ownerId: expect.any(String) },
      },
    });
    expect(snapshot.transcript.find(item =>
      item.kind === "customEntry" && item.semantic?.kind === "status")).toMatchObject({
      kind: "customEntry",
      data: expect.objectContaining({ message: "Goal created.", tone: "info" }),
      semantic: {
        direction: "ambientStatus",
        contextEffect: "none",
        origin: expect.objectContaining({ kind: "extension", ownerId: commandOwnerID }),
      },
    });
    const customMessages = snapshot.transcript.filter(item => item.kind === "customMessage");
    expect(customMessages).toHaveLength(2);
    expect(customMessages[0]).toMatchObject({
      details: { goal: { objective: "count to 20", status: "active" } },
      semantic: {
        direction: "inboundContext",
        contextEffect: "modelInput",
        delivery: "stored",
        origin: expect.objectContaining({ kind: "extension", ownerId: commandOwnerID }),
      },
    });
    expect(customMessages[1]).toMatchObject({
      semantic: {
        direction: "inboundContext",
        contextEffect: "modelInput",
        delivery: "stored",
        origin: expect.objectContaining({ kind: "extension", ownerId: commandOwnerID }),
      },
    });
  });

  it("records a caught extension-command handler error as a failed canonical invocation", async () => {
    const root = await temporaryRoot("tron-extension-command-failure-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await Promise.all([mkdir(agentDir), mkdir(extensionDir, { recursive: true })]);
    await writeFile(join(extensionDir, "failing-command.ts"), `export default function (pi) {
      pi.registerCommand("fail-command", {
        description: "Fail deterministically",
        handler: async () => { throw new Error("expected command failure"); },
      });
    }\n`);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      trust,
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);

    await expect(slot.prompt("/fail-command")).resolves.toEqual({ operationId: expect.any(String) });
    await waitFor(() => (slot as any).pendingExtensionCommand === undefined, "the pending extension command to clear");
    const command = slot.snapshot().transcript.find(item => item.semantic?.kind === "command");
    expect(command).toMatchObject({
      semantic: {
        lifecycle: "failed",
        resourceInvocations: [{ source: "extension", name: "fail-command" }],
      },
    });
  });

  it("keeps exact extension-shutdown ownership through a failed close retry", async () => {
    const fixture = await coldFixture("extension-shutdown-retry");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const runtime = (slot as unknown as { runtime: { dispose: () => Promise<void> } }).runtime;
    const originalDispose = runtime.dispose.bind(runtime);
    const dispose = vi.spyOn(runtime, "dispose")
      .mockRejectedValueOnce(new Error("injected shutdown failure"))
      .mockImplementationOnce(originalDispose);

    (slot as unknown as { requestExtensionShutdown: () => void }).requestExtensionShutdown();
    await waitFor(() => dispose.mock.calls.length === 1, "the disposal");
    expect(fixture.registry.administrativeWorkRegistry.facts()).toMatchObject([{
      kind: "extension-command-prompt-ui",
      sessionId: slot.id,
    }]);
    await waitFor(() => dispose.mock.calls.length === 2, "the second disposal");
    await waitFor(() => fixture.registry.administrativeWorkRegistry.size === 0, "the administrative work registry to drain");
    expect(slot.isDisposed).toBe(true);
  });

  it("retries registry disposal after a transient slot failure without duplicating shared cleanup", async () => {
    const fixture = await coldFixture("registry-dispose-retry");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const originalShutdown = slot.shutdown.bind(slot);
    const shutdown = vi.spyOn(slot, "shutdown")
      .mockRejectedValueOnce(new Error("injected slot shutdown failure"))
      .mockImplementation(originalShutdown);
    const internals = fixture.registry as unknown as {
      blobs: { dispose: () => Promise<void> };
      exports: { dispose: () => Promise<void> };
      workspace: { dispose: () => Promise<void> };
      slots: Map<string, unknown>;
    };
    const disposeCalls = {
      blobs: 0,
      exports: 0,
      workspace: 0,
    };
    for (const [name, store] of Object.entries({
      blobs: internals.blobs,
      exports: internals.exports,
      workspace: internals.workspace,
    }) as Array<[keyof typeof disposeCalls, { dispose: () => Promise<void> }]>) {
      const originalDispose = store.dispose.bind(store);
      vi.spyOn(store, "dispose").mockImplementation(async () => {
        disposeCalls[name] += 1;
        await originalDispose();
      });
    }

    const first = fixture.registry.dispose();
    const concurrent = fixture.registry.dispose();
    await expect(first).rejects.toThrow("One or more session runtimes failed");
    await expect(concurrent).rejects.toThrow("One or more session runtimes failed");
    expect(shutdown).toHaveBeenCalledTimes(1);
    expect(internals.slots.get(slot.id)).toBe(slot);
    await fixture.registry.dispose();
    expect(shutdown).toHaveBeenCalledTimes(2);
    expect(internals.slots.has(slot.id)).toBe(false);
    expect(disposeCalls).toEqual({ blobs: 1, exports: 1, workspace: 1 });
  });

  it("retries only failed shared-store disposal after partial cleanup", async () => {
    const fixture = await coldFixture("registry-shared-dispose-retry");
    const internals = fixture.registry as unknown as {
      blobs: { dispose: () => Promise<void> };
      exports: { dispose: () => Promise<void> };
      workspace: { dispose: () => Promise<void> };
    };
    const originalBlobDispose = internals.blobs.dispose.bind(internals.blobs);
    const originalExportsDispose = internals.exports.dispose.bind(internals.exports);
    const originalWorkspaceDispose = internals.workspace.dispose.bind(internals.workspace);
    const blobs = vi.spyOn(internals.blobs, "dispose")
      .mockRejectedValueOnce(new Error("injected blob cleanup failure"))
      .mockImplementation(originalBlobDispose);
    const exports = vi.spyOn(internals.exports, "dispose").mockImplementation(originalExportsDispose);
    const workspace = vi.spyOn(internals.workspace, "dispose").mockImplementation(originalWorkspaceDispose);

    await expect(fixture.registry.dispose()).rejects.toThrow("injected blob cleanup failure");
    expect(blobs).toHaveBeenCalledTimes(1);
    expect(exports).toHaveBeenCalledTimes(1);
    expect(workspace).toHaveBeenCalledTimes(1);
    await fixture.registry.dispose();
    expect(blobs).toHaveBeenCalledTimes(2);
    expect(exports).toHaveBeenCalledTimes(1);
    expect(workspace).toHaveBeenCalledTimes(1);
  });

  it("reopens a session whose runtime closed before its index row landed", async () => {
    const fixture = await coldFixture("close-before-row");
    const build = CatalogMetadataIndex.prototype.entryFromSummary;
    let release!: () => void;
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const held = vi.spyOn(CatalogMetadataIndex.prototype, "entryFromSummary").mockImplementation(async function (
      this: CatalogMetadataIndex,
      ...arguments_: Parameters<CatalogMetadataIndex["entryFromSummary"]>
    ) {
      await gate;
      return build.apply(this, arguments_);
    });
    try {
      const created = await fixture.registry.create(fixture.cwd);
      const manager = (created as unknown as { sessionManager: SessionManager }).sessionManager;
      manager.appendMessage(fauxAssistantMessage("persisted before extension close"));
      const persisted = (created as unknown as { session: () => void });
      created.publishSnapshot();
      await waitFor(() => created.persistedSessionFile !== undefined, "the persisted session file");
      await waitFor(() => (fixture.registry as unknown as { latestSummaries: Map<string, unknown> }).latestSummaries.has(created.id), "the latest summary for the created session");
      expect(catalogOwner(fixture.registry).rows().some((row) => row.id === created.id)).toBe(false);

      (created as unknown as { requestExtensionShutdown: () => void }).requestExtensionShutdown();
      await waitFor(() => created.isDisposed
        && !(fixture.registry as unknown as { slots: Map<string, unknown> }).slots.has(created.id), "the disposed session to leave the slot map");
      const reopening = fixture.registry.acquire(created.id);
      await new Promise((resolve) => setTimeout(resolve, 25));
      release();
      const reopened = await reopening;
      expect(reopened.id).toBe(created.id);
      expect(JSON.stringify(reopened.snapshot().transcript)).toContain("persisted before extension close");
    } finally {
      release();
      held.mockRestore();
    }
  });

  it("scopes extension shutdown to the owning runtime slot", async () => {
    const root = await temporaryRoot("tron-extension-scoped-shutdown-");
    const agentDir = join(root, "agent");
    const closingCwd = join(root, "closing");
    const otherCwd = join(root, "other");
    const extensionDir = join(closingCwd, ".pi", "extensions");
    await Promise.all([mkdir(agentDir), mkdir(extensionDir, { recursive: true }), mkdir(otherCwd)]);
    await writeFile(join(extensionDir, "shutdown.ts"), `export default function (pi) {
      pi.on("session_shutdown", async (_event, ctx) => {
        await new Promise((resolve) => setTimeout(resolve, 50));
        ctx.ui.setStatus("shutdown", "complete");
        ctx.ui.notify("Shutdown complete.", "info");
      });
      pi.registerCommand("close-owning-session", { handler: async (_args, ctx) => ctx.shutdown() });
    }\n`);
    const trust = new TrustService(agentDir);
    await trust.set(closingCwd, true);
    const shutdownTopics: string[] = [];
    let listChanges = 0;
    const registry = await createTestRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust,
      broadcast: (_sessionID, topic) => shutdownTopics.push(topic),
      sessionSummaryChanged: () => {},
      sessionListChanged: () => { listChanges += 1; },
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const closing = await registry.create(closingCwd);
    const other = await registry.create(otherCwd);
    const closingID = closing.id;
    const ownership = registry as unknown as {
      slots: Map<string, unknown>;
      summaryRevisions: Map<string, number>;
      latestSummaries: Map<string, SessionSummaryUpdate>;
    };
    expect(closing.persistedSessionFile).toBeUndefined();
    expect(ownership.summaryRevisions.has(closingID)).toBe(true);
    expect(ownership.latestSummaries.has(closingID)).toBe(true);

    await closing.prompt("/close-owning-session");
    await waitFor(() => !ownership.slots.has(closingID), "the closing session to leave the slot map");
    expect(() => other.context()).not.toThrow();
    expect(ownership.summaryRevisions.has(closingID)).toBe(false);
    expect(ownership.latestSummaries.has(closingID)).toBe(false);
    await expect(registry.acquire(closingID)).rejects.toMatchObject({ code: "not_found" });
    const shutdownStatusIndex = shutdownTopics.lastIndexOf("session.extensionPresentation");
    const closedIndex = shutdownTopics.lastIndexOf("session.closed");
    expect(shutdownStatusIndex).toBeGreaterThanOrEqual(0);
    expect(closedIndex).toBeGreaterThan(shutdownStatusIndex);

    const persisted = await registry.create(closingCwd);
    const persistedManager = (persisted as unknown as { sessionManager: SessionManager }).sessionManager;
    persistedManager.appendMessage(fauxAssistantMessage("persisted before extension close"));
    persisted.publishSnapshot();
    expect(persisted.persistedSessionFile).toBeDefined();
    const persistedID = persisted.id;
    const revisionBeforeClose = ownership.summaryRevisions.get(persistedID)!;
    const structuralChangesBeforeClose = listChanges;

    await persisted.prompt("/close-owning-session");
    await waitFor(() => !ownership.slots.has(persistedID), "the persisted session to leave the slot map");
    expect(listChanges).toBe(structuralChangesBeforeClose);
    expect(ownership.summaryRevisions.get(persistedID)).toBeGreaterThanOrEqual(revisionBeforeClose);
    expect(ownership.latestSummaries.get(persistedID)).toMatchObject({
      sessionId: persistedID,
      phase: "idle",
      summaryRevision: ownership.summaryRevisions.get(persistedID),
    });
    const reopened = await registry.acquire(persistedID);
    expect(reopened.snapshot().transcript.find(item =>
      item.kind === "customEntry" && item.semantic?.kind === "status"
        && item.data !== undefined && !Array.isArray(item.data)
        && typeof item.data === "object" && item.data !== null
        && item.data.message === "Shutdown complete.")).toMatchObject({
      data: expect.objectContaining({ message: "Shutdown complete." }),
      semantic: { direction: "ambientStatus", contextEffect: "none" },
    });
  });

  it("isolates same-named providers registered by concurrent project extensions", async () => {
    const root = await temporaryRoot("tron-provider-isolation-");
    const agentDir = join(root, "agent");
    const firstCwd = join(root, "first");
    const secondCwd = join(root, "second");
    await Promise.all([
      mkdir(agentDir),
      mkdir(join(firstCwd, ".pi", "extensions"), { recursive: true }),
      mkdir(join(secondCwd, ".pi", "extensions"), { recursive: true }),
    ]);
    const extension = (name: string) => `export default function (pi) { pi.registerProvider("project-provider", { baseUrl: "https://provider.invalid", apiKey: "fixture", api: "openai-completions", models: [{ id: "model", name: ${JSON.stringify(name)}, reasoning: false, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 4096, maxTokens: 1024 }] }); }\n`;
    await Promise.all([
      writeFile(join(firstCwd, ".pi", "extensions", "provider.ts"), extension("First Project Model")),
      writeFile(join(secondCwd, ".pi", "extensions", "provider.ts"), extension("Second Project Model")),
    ]);
    const trust = new TrustService(agentDir);
    await Promise.all([trust.set(firstCwd, true), trust.set(secondCwd, true)]);
    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      trust,
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);

    const [first, second] = await Promise.all([registry.create(firstCwd), registry.create(secondCwd)]);
    expect(first.modelRuntime).not.toBe(second.modelRuntime);
    expect(first.modelRuntime.getModel("project-provider", "model")?.name).toBe("First Project Model");
    expect(second.modelRuntime.getModel("project-provider", "model")?.name).toBe("Second Project Model");
  });

  it("projects the canonical latest cache hit rate used by the terminal footer", async () => {
    const root = await temporaryRoot("tron-cache-rate-integration-");
    const agentDir = join(root, "agent");
    const ignoredSessionDir = join(root, "sessions");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(ignoredSessionDir), mkdir(cwd)]);
    await writeFile(join(agentDir, "settings.json"), JSON.stringify({ sessionDir: ignoredSessionDir }));
    const faux = fauxProvider({ provider: "tron-cache-rate", tokensPerSecond: 10_000 });
    const createModels = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    faux.setResponses([fauxAssistantMessage("cached")]);
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
    expect(slot.sessionFile?.startsWith(join(agentDir, "sessions") + sep)).toBe(true);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("cache stats");
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    expect(await readdir(ignoredSessionDir)).toEqual([]);
    expect(await readFile(slot.sessionFile!, "utf8")).toContain("cached");

    const snapshot = slot.snapshot();
    const assistant = snapshot.transcript.find((item) => item.role === "assistant");
    const usage = (assistant as any)?.usage as { input?: number; cacheRead?: number; cacheWrite?: number } | undefined;
    const promptTokens = (usage?.input ?? 0) + (usage?.cacheRead ?? 0) + (usage?.cacheWrite ?? 0);
    const expected = promptTokens > 0 ? ((usage?.cacheRead ?? 0) / promptTokens) * 100 : undefined;
    expect(snapshot.stats.latestCacheHitRate).toBe(expected);
  });

  it("projects readable metadata for project resources", async () => {
    const root = await temporaryRoot("tron-resources-integration-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const pi = join(cwd, ".pi");
    await Promise.all([
      mkdir(agentDir),
      mkdir(join(pi, "extensions"), { recursive: true }),
      mkdir(join(pi, "prompts"), { recursive: true }),
      mkdir(join(pi, "skills", "review"), { recursive: true }),
    ]);
    const cwdAlias = join(root, "workspace-alias");
    await symlink(cwd, cwdAlias);
    await Promise.all([
      writeFile(join(pi, "extensions", "tool.ts"), `export default function (pi) { pi.on("session_start", () => {}); pi.registerTool({ name: "project_echo", label: "Project echo", description: "Echo project text", parameters: { type: "object", properties: { text: { type: "string" } }, required: ["text"] }, execute: async (_id, params) => ({ content: [{ type: "text", text: params.text }], details: {} }) }); }\n`),
      writeFile(join(pi, "prompts", "review.md"), `---\ndescription: Review the current change\n---\nReview $ARGUMENTS\n`),
      writeFile(join(pi, "skills", "review", "SKILL.md"), `---\nname: review-skill\ndescription: Inspect a code change\n---\nReview carefully.\n`),
    ]);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const resourceEvents: string[] = [];
    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      trust,
      broadcast: (_sessionId, topic) => { resourceEvents.push(topic); },
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);

    const slot = await registry.create(cwd);
    const resources = await slot.resources() as any;
    const inventory = resources.hookInventory;
    for (const key of ["extensions", "handlerEvents", "loadErrors"] as const) {
      expect(inventory[key].retained + inventory[key].omitted).toBe(inventory[key].total);
      expect(inventory[key].omitted).toBe(0);
    }
    expect(inventory.extensions.total).toBeGreaterThanOrEqual(2);
    expect(inventory.handlerEvents.total).toBeGreaterThanOrEqual(1);
    expect(inventory.encodedBytes).toBeGreaterThan(0);
    expect(inventory.encodedBytes).toBeLessThanOrEqual(inventory.encodedBytesLimit);
    expect(resources.extensions).toEqual(expect.arrayContaining([
      expect.objectContaining({
        name: "tool.ts",
        scope: "project",
        tools: ["project_echo"],
        handlers: [{ event: "session_start", count: 1 }],
      }),
    ]));
    expect(resources.prompts.prompts).toEqual(expect.arrayContaining([
      expect.objectContaining({ name: "review", description: "Review the current change", scope: "project" }),
    ]));
    expect(resources.skills.skills).toEqual(expect.arrayContaining([
      expect.objectContaining({ name: "review-skill", description: "Inspect a code change", scope: "project" }),
    ]));
    expect(resources.tools).toEqual(expect.arrayContaining([
      expect.objectContaining({
        name: "project_echo", label: "Project echo",
        description: "Echo project text", scope: "project",
      }),
    ]));

    resourceEvents.length = 0;
    await registry.reloadProject(cwd, false, false);
    await expect(slot.resources()).rejects.toThrow("Project trust is being reconfigured");
    expect(() => slot.modelRuntime).toThrow("Project trust is being reconfigured");
    expect(() => slot.sessionEnvironment()).toThrow("Project trust is being reconfigured");
    expect(() => slot.respondToInteraction("pending", "host", 0, null, true)).toThrow("Project trust is being reconfigured");
    await expect(registry.create(cwd)).rejects.toMatchObject({ code: "busy", retryable: true });
    await expect(registry.create(cwdAlias)).rejects.toMatchObject({ code: "busy", retryable: true });
    await expect(trust.inspect(cwd)).resolves.toMatchObject({ savedDecision: true });
    expect(resourceEvents).not.toContain("session.resourcesChanged");
    await trust.set(cwd, false);
    await registry.commitProjectReload(cwd);
    const untrusted = await slot.resources() as any;
    expect(untrusted.tools).not.toEqual(expect.arrayContaining([
      expect.objectContaining({ name: "project_echo" }),
    ]));
    expect(resourceEvents).toContain("session.resourcesChanged");
  });

  async function distributionFixture(): Promise<any> {
    const root = await temporaryRoot("tron-resource-distribution-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const pi = join(cwd, ".pi");
    const packageRoot = join(root, "vendor-subagent-package");
    await Promise.all([
      mkdir(join(agentDir, "skills", "user-skill"), { recursive: true }),
      mkdir(join(pi, "extensions"), { recursive: true }),
      mkdir(join(pi, "prompts"), { recursive: true }),
      mkdir(join(pi, "skills", "review"), { recursive: true }),
      mkdir(join(packageRoot, "extensions"), { recursive: true }),
    ]);
    await writeFile(join(agentDir, "settings.json"), JSON.stringify({ packages: [packageRoot] }));
    await Promise.all([
      writeFile(join(agentDir, "skills", "user-skill", "SKILL.md"), `---\nname: user-skill\ndescription: A user skill\n---\nUse it.\n`),
      writeFile(join(pi, "extensions", "tool.ts"), `export default function (pi) { pi.registerTool({ name: "project_echo", label: "Project echo", description: "Echo project text", parameters: { type: "object", properties: {} }, execute: async () => ({ content: [{ type: "text", text: "ok" }], details: {} }) }); }\n`),
      writeFile(join(pi, "prompts", "review.md"), `---\ndescription: Review the current change\n---\nReview $ARGUMENTS\n`),
      writeFile(join(pi, "skills", "review", "SKILL.md"), `---\nname: review-skill\ndescription: Inspect a code change\n---\nReview carefully.\n`),
      writeFile(join(packageRoot, "extensions", "package-tool.ts"), `export default function (pi) { pi.registerTool({ name: "package_echo", label: "Package echo", description: "Echo packaged text", parameters: { type: "object", properties: {} }, execute: async () => ({ content: [{ type: "text", text: "ok" }], details: {} }) }); }\n`),
    ]);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      trust,
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    return registry.create(cwd);
  }

  it("tags every available resource with its distribution", async () => {
    const slot = await distributionFixture();
    const resources = await slot.resources() as any;
    const tool = (name: string) => resources.tools.find((candidate: any) => candidate.name === name);

    expect(tool("package_echo")).toMatchObject({ distribution: "external" });
    expect(tool("ask_user")).toMatchObject({ distribution: "module" });
    expect(tool("project_echo")).toMatchObject({ distribution: "local" });
    expect(Object.prototype.hasOwnProperty.call(tool("read"), "distribution")).toBe(false);
    expect(Object.prototype.hasOwnProperty.call(tool("bash"), "distribution")).toBe(false);

    expect(resources.skills.skills).toEqual(expect.arrayContaining([
      expect.objectContaining({ name: "user-skill", scope: "user", distribution: "local" }),
      expect.objectContaining({ name: "review-skill", scope: "project", distribution: "local" }),
    ]));
    expect(resources.prompts.prompts).toEqual(expect.arrayContaining([
      expect.objectContaining({ name: "review", scope: "project", distribution: "local" }),
    ]));

    const promptCommand = resources.commands.find((candidate: any) => candidate.source === "prompt" && candidate.name === "review");
    expect(promptCommand).toMatchObject({ resourceOrigin: "top-level", distribution: "local" });
    const skillCommand = resources.commands.find((candidate: any) => candidate.source === "skill" && candidate.name === "skill:user-skill");
    expect(skillCommand).toMatchObject({ resourceOrigin: "top-level", distribution: "local" });
  });

  it("fails soft for subagents when pi-subagents is absent", async () => {
    const slot = await distributionFixture();
    const resources = await slot.resources() as any;
    expect(resources.subagents).toEqual([]);
    expect(typeof resources.subagentDiagnostics).toBe("string");
  });

  it("persists the first invocation receipt with the first user message across runtime teardown", async () => {
    const root = await temporaryRoot("tron-first-message-receipt-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const faux = fauxProvider({ provider: "tron-first-message-receipt", tokensPerSecond: 10_000 });
    faux.setResponses([fauxAssistantMessage("first response")]);
    const createRuntime = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    const createRegistry = async () => {
      const registry = await createTestRegistry({
        agentDir,
        tronHome: join(root, "tron"),
        idleRuntimeMs: 60_000,
        modelRuntimeFactory: createRuntime,
        trust,
        broadcast: () => {},
        sessionSummaryChanged: () => {},
        sessionListChanged: () => {},
      });
      registries.push(registry);
      await initializeRegistry(registry);
      return registry;
    };
    let registry: RuntimeRegistry | undefined;
    try {
      registry = await createRegistry();
      const slot = await registry.create(cwd);
      const model = faux.getModel();
      await slot.setModel(model.provider, model.id);
      const admitted = await slot.prompt("persist the first turn");
      await waitFor(() => !slot.isBusy, "the slot to go idle");
      const sessionFile = slot.sessionFile!;
      const entries = (await readFile(sessionFile, "utf8"))
        .trimEnd().split("\n").map(line => JSON.parse(line) as Record<string, any>);
      expect(entries.some(entry => entry.type === "message" && entry.message?.role === "user"
        && entry.message.content?.some((part: { text?: string }) => part.text === "persist the first turn"))).toBe(true);
      const firstReceipt = entries.find(entry => entry.type === "custom"
        && entry.customType === INVOCATION_RECEIPT_TYPE
        && entry.data?.operationId === admitted.operationId
        && entry.data?.receiptKind === "start");
      expect(firstReceipt).toBeDefined();

      await registry.dispose();
      registries.splice(registries.indexOf(registry), 1);
      registry = await createRegistry();
      expect((await registry.list()).map(session => session.id)).toContain(slot.id);
      const reopened = await registry.acquire(slot.id);
      const reopenedEntries = (await readFile(reopened.sessionFile!, "utf8"))
        .trimEnd().split("\n").map(line => JSON.parse(line) as Record<string, any>);
      expect(reopenedEntries).toContainEqual(firstReceipt);
      expect(reopened.snapshot().transcript.some(item => item.role === "user"
        && JSON.stringify(item).includes("persist the first turn"))).toBe(true);
    } finally {
      if (registry) {
        await registry.dispose();
        registries.splice(registries.indexOf(registry), 1);
      }
      await rm(root, { recursive: true, force: true });
    }
  });

  it("rekeys the owning slot when a completed session is forked", async () => {
    const root = await temporaryRoot("tron-runtime-fork-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    process.env.PI_CODING_AGENT_DIR = agentDir;

    const faux = fauxProvider({ provider: "tron-fork", tokensPerSecond: 10_000 });
    const createModels = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    faux.setResponses([fauxAssistantMessage("done")]);
    const rekeys: Array<[string, string]> = [];
    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: createModels,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
      sessionRekeyed: (previousId, nextId) => {
        rekeys.push([previousId, nextId]);
        throw new Error("injected post-commit observer failure");
      },
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("fork this");
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    const original = slot.id;
    expect(registry.attentionProjection(original).isUnread).toBe(true);
    const userEntry = slot.snapshot().transcript.find((item) => item.role === "user");
    const assistantEntry = slot.snapshot().transcript.find((item) => item.role === "assistant");
    expect(userEntry).toBeDefined();
    expect(assistantEntry).toBeDefined();
    registry.subscribe("fork-subscriber", original);
    const internals = registry as unknown as {
      attention: { assertAbsent: (sessionId: string) => Promise<void> };
      slots: Map<string, typeof slot>;
      latestSummaries: Map<string, SessionSummaryUpdate>;
    };
    const parentPath = (slot as unknown as { sessionManager: SessionManager }).sessionManager.getSessionFile()!;
    const parentBytes = await readFile(parentPath);
    const forkDirectory = join(dirname(parentPath), basename(parentPath, ".jsonl"), "forks");
    const forkListingBefore = existsSync(forkDirectory)
      ? (await readdir(forkDirectory)).filter((name) => name.endsWith(".jsonl")).sort()
      : [];
    const assertAbsent = vi.spyOn(internals.attention, "assertAbsent")
      .mockRejectedValueOnce(new Error("injected attention prepare failure"));
    await expect(slot.fork(assistantEntry!.id, "at")).rejects.toThrow("injected attention prepare failure");
    expect(slot.id).toBe(original);
    expect((await registry.list()).map((session) => session.id)).toEqual([original]);
    expect(internals.slots.get(original)).toBe(slot);
    expect([...internals.slots.values()].filter((candidate) => candidate === slot)).toHaveLength(1);
    expect(registry.isSubscribed("fork-subscriber", original)).toBe(true);
    expect(internals.latestSummaries.get(original)?.sessionId).toBe(original);
    expect(registry.attentionProjection(original).isUnread).toBe(true);
    expect(await readFile(parentPath)).toEqual(parentBytes);
    const forkListingAfter = existsSync(forkDirectory)
      ? (await readdir(forkDirectory)).filter((name) => name.endsWith(".jsonl")).sort()
      : [];
    expect(forkListingAfter).toEqual(forkListingBefore);
    assertAbsent.mockRestore();

    const fork = await slot.fork(userEntry!.id, "at");
    expect(fork.sessionId).not.toBe(original);
    expect(rekeys).toEqual([[original, fork.sessionId]]);
    expect(registry.attentionProjection(original).isUnread).toBe(true);
    expect(registry.attentionProjection(fork.sessionId)).toEqual({
      completionRevision: 0,
      attentionRevision: 0,
      isUnread: false,
    });
    expect((await registry.acquire(fork.sessionId)).id).toBe(fork.sessionId);

    expect(slot.persistedSessionFile).toBeDefined();
    const forkHeader = JSON.parse((await readFile(slot.persistedSessionFile!, "utf8")).split("\n", 1)[0]!) as {
      parentSession?: string;
    };
    expect(forkHeader.parentSession).toBe(parentPath);
    expect(slot.snapshot().transcript.filter((item) => item.role === "user")).toEqual([
      expect.objectContaining({
        kind: "message",
        role: "user",
        content: [expect.objectContaining({ type: "text", text: "fork this" })],
      }),
    ]);
    const catalog = await registry.list();
    expect(catalog.find((session) => session.id === original)).toMatchObject({ kind: "user" });
    expect(catalog.find((session) => session.id === fork.sessionId)).toMatchObject({
      kind: "user",
      firstMessage: "fork this",
      messageCount: 1,
    });

    const prePromptBoundary = slot.snapshot().forkBoundary;
    expect(prePromptBoundary).toMatchObject({
      kind: "sessionFork", inheritedAnchorId: userEntry!.id, gapOrdinal: expect.any(Number),
    });
    expect(slot.transcriptPage().forkBoundary).toEqual(prePromptBoundary);

    faux.setResponses([fauxAssistantMessage("continued")]);
    await slot.prompt("continue here");
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    expect(slot.persistedSessionFile).toBeDefined();
    const boundary = slot.snapshot().forkBoundary;
    expect(boundary).toEqual(prePromptBoundary);
    expect(slot.transcriptPage().forkBoundary).toEqual(boundary);
    expect(slot.snapshot().transcript.filter((item) => item.role === "user" || item.role === "assistant")).toEqual([
      expect.objectContaining({ role: "user", content: [expect.objectContaining({ text: "fork this" })] }),
      expect.objectContaining({ role: "user", content: [expect.objectContaining({ text: "continue here" })] }),
      expect.objectContaining({ role: "assistant", content: [expect.objectContaining({ text: "continued" })] }),
    ]);
    expect((await registry.list()).find((session) => session.id === fork.sessionId)).toMatchObject({
      kind: "user",
      parentSessionId: original,
      firstMessage: "fork this",
      messageCount: 3,
    });
    await slot.dispose();
    expect((await registry.list()).find((session) => session.id === fork.sessionId)).toMatchObject({
      kind: "user",
      parentSessionId: original,
      firstMessage: "fork this",
      messageCount: 3,
    });
    const reopenedCatalog = await registry.list();
    expect(reopenedCatalog.find((session) => session.id === fork.sessionId)).toMatchObject({
      kind: "user",
      parentSessionId: original,
      firstMessage: "fork this",
      messageCount: 3,
    });
    const reopened = await registry.acquire(fork.sessionId);
    expect(reopened.snapshot().forkBoundary).toEqual(boundary);
    const transcriptBeforeParentRemoval = reopened.snapshot().transcript;
    await reopened.dispose();
    await rm(parentPath);
    const withoutParent = await registry.acquire(fork.sessionId);
    expect(withoutParent.snapshot().forkBoundary).toBeUndefined();
    expect(withoutParent.snapshot().transcript).toEqual(transcriptBeforeParentRemoval);
  });

  it("moves notification inbox rows only for a migrated session identity", async () => {
    const rekeys: Array<[string, string]> = [];
    const notifications = {
      rekeySession: async (previousId: string, nextId: string) => {
        rekeys.push([previousId, nextId]);
        return true;
      },
    } as unknown as NotificationService;
    const { manager, registry } = await coldFixture("notification-rekey", { notifications });
    const sessionId = manager.getSessionId();
    const slot = await registry.acquire(sessionId);
    const hooks = (registry as unknown as { hooks: () => {
      rekey: (previousId: string, nextId: string, slot: unknown, disposition: string, commit: () => void) => Promise<void>;
    } }).hooks();
    let commits = 0;
    await hooks.rekey(sessionId, "migrated-session", slot, "migrate", () => { commits += 1; });
    expect(commits).toBe(1);
    expect(rekeys).toEqual([[sessionId, "migrated-session"]]);
    await hooks.rekey("migrated-session", "reset-session", slot, "reset", () => { commits += 1; });
    expect(commits).toBe(2);
    expect(rekeys).toEqual([[sessionId, "migrated-session"]]);
  });
});
