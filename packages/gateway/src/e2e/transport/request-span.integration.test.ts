import { TEST_SETTINGS_SCHEMA } from "../../../test-support/settings-schema.js";
import { persistedLogRecords } from "../../../test-support/persisted-logs.js";
import { displayOwnerOf, createTestRegistry } from "../../../test-support/gateway-registry.js";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import WebSocket from "ws";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { afterEach, describe, expect, it } from "vitest";
import { AuthBroker } from "../../admin/auth-broker.js";
import { TrustService } from "../../kernel/resources/trust-service.js";
import { SettingsStoreAdapter } from "../../admin/settings-model.js";
import { SettingsModel } from "../../kernel/settings/settings-model.js";
import { UploadStore } from "../../machine/upload-store.js";
import { DeviceStore } from "../../security/device-store.js";
import { MacTerminalService } from "../../security/mac-terminal-service.js";
import { RuntimeRegistry } from "../../kernel/session/runtime-registry.js";
import { PROTOCOL_VERSION } from "../../version.js";
import { CommandReceiptStore } from "../../transport/command-receipts.js";
import { GatewayService, type GatewayServiceDependencies } from "../../transport/gateway-service.js";
import { GatewayLogger } from "../../transport/logger.js";
import { GatewayServer } from "../../transport/server.js";
import { RequestSpan, runInRequestSpan } from "../../util/request-span.js";
import { waitFor } from "../../../test-support/wait-for.js";

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => { await Promise.all(cleanups.splice(0).map((cleanup) => cleanup())); });

const COLD_OPEN_WAIT_BOUND_MS = 120_000;
const REPORT_PATH = join(process.cwd(), "test-results", "request-span.integration.json");
const SETTINGS_REPORT_PATH = join(process.cwd(), "test-results", "settings-request-span.integration.json");
const execFileAsync = promisify(execFile);

interface SocketFrame {
  type?: string;
  id?: string;
  ok?: boolean;
  result?: { session?: { sessionId?: string }; syncToken?: string; keys?: Array<{ key: string; value?: unknown; layer?: string }> };
  error?: { code?: string; message?: string };
}

async function unusedPort(): Promise<number> {
  const probe = createServer();
  await new Promise<void>((resolve) => probe.listen(0, "127.0.0.1", resolve));
  const address = probe.address();
  if (!address || typeof address === "string") throw new Error("probe did not bind");
  await new Promise<void>((resolve) => probe.close(() => resolve()));
  return address.port;
}

function stagesOf(stages: string): Map<string, number> {
  const parsed = new Map<string, number>();
  for (const entry of stages.split(";")) {
    const [name, detail] = entry.split("=");
    const duration = detail === undefined ? null : /(\d+)ms/u.exec(detail);
    parsed.set(name!, duration === null ? 0 : Number(duration[1]));
  }
  return parsed;
}

describe("receipt-backed prompt request span", () => {
  it("logs receipt persistence and measures only the same-command lane wait", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-request-span-receipt-"));
    cleanups.push(async () => { await rm(root, { recursive: true, force: true }); });
    const receipts = new CommandReceiptStore(root);
    let releaseOperation!: () => void;
    let markOperationStarted!: () => void;
    const operationStarted = new Promise<void>((resolve) => { markOperationStarted = resolve; });
    const operationGate = new Promise<void>((resolve) => { releaseOperation = resolve; });
    const firstSpan = new RequestSpan();
    const secondSpan = new RequestSpan();
    const first = runInRequestSpan(firstSpan, () => receipts.execute(
      "device", "session.prompt", "shared-command", async () => {
        markOperationStarted();
        await operationGate;
        return { accepted: true };
      },
    ));
    await operationStarted;
    const secondStartedAt = performance.now();
    const second = runInRequestSpan(secondSpan, () => receipts.execute(
      "device", "session.prompt", "shared-command", async () => ({ accepted: true }),
    ));
    const lockHeldAt = performance.now();
    await new Promise((resolve) => setTimeout(resolve, 20));
    const lockHeldMs = performance.now() - lockHeldAt;
    releaseOperation();
    await first;
    await second;
    const secondElapsedMs = performance.now() - secondStartedAt;
    const firstBreakdown = firstSpan.breakdown(1);
    const secondBreakdown = secondSpan.breakdown(1);
    expect(firstBreakdown?.stages).toContain("receipt.pending-persist");
    expect(firstBreakdown?.stages).toContain("receipt.completed-persist");
    expect(secondBreakdown?.stages).toContain("receipt.command-lane=");
    const laneWaitMs = stagesOf(secondBreakdown!.stages).get("receipt.command-lane")!;
    expect(laneWaitMs).toBeGreaterThanOrEqual(lockHeldMs - 1);
    expect(laneWaitMs).toBeLessThanOrEqual(secondElapsedMs);
  });
});

describe("session.open request span", () => {
  it("records a failed session.open with its persisted stage breakdown through the socket", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-request-span-open-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const sessionDirectory = join(agentDir, "sessions", "workspace");
    await Promise.all([mkdir(sessionDirectory, { recursive: true }), mkdir(cwd, { recursive: true })]);
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
    let gateway: GatewayServer | undefined;
    cleanups.push(async () => {
      await gateway?.close();
      await registry.dispose();
      await rm(root, { recursive: true, force: true });
    });
    await registry.initialize();
    await registry.recoverCanonicalAttention();

    const devices = new DeviceStore(root, "machine");
    await devices.initialize();
    const localToken = JSON.parse(await readFile(join(root, "state", "local-auth.json"), "utf8")).bearerToken as string;
    const logPath = join(root, "logs", "gateway.jsonl");
    const logger = new GatewayLogger(logPath);
    const uploads = new UploadStore(root, 1_024);
    const auth = new AuthBroker(await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }), () => {});
    const service = new GatewayService({
      display: displayOwnerOf(registry),
      config: { tronHome: root },
      devices,
      sessions: registry,
      receipts: new CommandReceiptStore(root),
      uploads,
      auth,
      logger,
      requestRestart: () => {},
      sessionDeleted: () => {},
      broadcast: () => {},
    } as unknown as GatewayServiceDependencies);
    const port = await unusedPort();
    gateway = new GatewayServer({ display: displayOwnerOf(registry),
      host: "127.0.0.1",
      port,
      maxFrameBytes: 4 * 1_048_576,
      devices,
      uploads,
      sessions: registry,
      auth,
      service,
      logger,
    });
    await gateway.listen();

    const frames: SocketFrame[] = [];
    const socket = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${localToken}` } });
    socket.on("message", (raw) => frames.push(JSON.parse(raw.toString()) as SocketFrame));
    await new Promise<void>((resolve) => socket.once("open", () => resolve()));
    socket.send(JSON.stringify({ type: "hello", protocolVersion: PROTOCOL_VERSION }));
    await waitFor(() => frames.some((frame) => frame.type === "hello"), "the hello frame", { boundMs: COLD_OPEN_WAIT_BOUND_MS });

    const failedRequestId = "missing-open";
    socket.send(JSON.stringify({
      type: "request",
      id: failedRequestId,
      method: "session.open",
      params: { sessionId: "00000000-0000-4000-8000-000000000000" },
    }));
    await waitFor(() => frames.some((frame) => frame.id === failedRequestId), "the failed request's response frame", { boundMs: COLD_OPEN_WAIT_BOUND_MS });
    expect(frames.find((frame) => frame.id === failedRequestId)?.ok).toBe(false);
    await waitFor(() => persistedLogRecords(logPath).some(
      (record) => record.requestID === failedRequestId && record.event === "rpc.completed",
    ), "the persisted rpc.completed record", { boundMs: COLD_OPEN_WAIT_BOUND_MS });
    const persisted = persistedLogRecords(logPath)
      .find((record) => record.requestID === failedRequestId && record.event === "rpc.completed")!;
    expect(persisted.outcome).toBe("failure");
    expect(persisted.stages, "the persisted line must carry the breakdown").toBeDefined();
    expect(persisted.stages as string).not.toBe("");
    expect(persisted.unaccountedMs).toBeDefined();
    expect(persisted.unaccountedMs as number).toBeGreaterThanOrEqual(0);
    expect(persisted.unaccountedMs as number).toBeLessThanOrEqual(persisted.durationMs as number);
    const named = stagesOf(persisted.stages as string);
    expect(named.has("session.open.catalog"), "a failed missing-session open must name the catalog stage it failed in").toBe(true);
    const accountedMs = [...named.values()].reduce((total, duration) => total + duration, 0);
    expect(Math.abs((persisted.durationMs as number) - (persisted.unaccountedMs as number) - accountedMs)).toBeLessThanOrEqual(named.size + 1);

    const report = {
      failureRecord: {
        stages: persisted.stages,
        unaccountedMs: persisted.unaccountedMs,
        durationMs: persisted.durationMs,
        recordBytes: Buffer.byteLength(JSON.stringify(persisted), "utf8"),
      },
    };
    await mkdir(dirname(REPORT_PATH), { recursive: true });
    await writeFile(REPORT_PATH, `${JSON.stringify(report, null, 2)}\n`);
    console.log(`request span report ${REPORT_PATH} ${JSON.stringify(report)}`);
  }, 300_000);
});

describe("settings.resolve request span", () => {
  it("attributes the real store process await on successful and failed socket requests", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-request-span-settings-"));
    let gateway: GatewayServer | undefined;
    let registryForCleanup: RuntimeRegistry | undefined;
    let socket: WebSocket | undefined;
    cleanups.push(async () => {
      socket?.close();
      await gateway?.close();
      await registryForCleanup?.dispose();
      await rm(root, { recursive: true, force: true });
    });
    const agentDir = join(root, "agent");
    await mkdir(agentDir, { recursive: true });
    const fixtureResult = join(root, "fixture-result.json");
    await Promise.all([
      writeFile(fixtureResult, "{}\n"),
      writeFile(join(agentDir, "settings.json"), JSON.stringify({ retry: { maxRetries: 7 } })),
    ]);
    const trust = new TrustService(agentDir);
    const modelRuntime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    let mode: "success" | "failure" = "success";
    class FixtureMacTerminalService extends MacTerminalService {
      override async read(): Promise<Record<string, string>> {
        try {
          const { stdout } = await execFileAsync(process.execPath, [
            join(process.cwd(), "test-fixtures", "mac-terminal-keys-process.mjs"), mode, fixtureResult,
          ], { timeout: 10_000, maxBuffer: 4_096 });
          return JSON.parse(stdout) as Record<string, string>;
        } catch {
          throw new Error("Mac Terminal key fixture failed");
        }
      }
    }
    const macTerminalKeys = new FixtureMacTerminalService({ root: join(root, "state/mac-terminal"), launchAgentDirectory: join(root, "agents") });
    const settingsModel = new SettingsModel(new SettingsStoreAdapter({ schema: TEST_SETTINGS_SCHEMA, agentDir, tronHome: root, trust, modelRuntime, macTerminalKeys }));
    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }),
      trust,
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registryForCleanup = registry;
    await registry.initialize();
    await registry.recoverCanonicalAttention();
    const devices = new DeviceStore(root, "machine");
    await devices.initialize();
    const localToken = JSON.parse(await readFile(join(root, "state", "local-auth.json"), "utf8")).bearerToken as string;
    const logPath = join(root, "logs", "gateway.jsonl");
    const logger = new GatewayLogger(logPath);
    const uploads = new UploadStore(root, 1_024);
    const auth = new AuthBroker(await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }), () => {});
    const service = new GatewayService({
      display: displayOwnerOf(registry),
      config: { machineId: "machine", machineGroupID: "group", machineName: "Mac", tronHome: root, agentDir },
      devices, sessions: registry, receipts: new CommandReceiptStore(root), uploads, auth, logger,
      trust, settingsModel, modelRuntime,
      requestRestart: () => {}, sessionDeleted: () => {}, broadcast: () => {},
    } as unknown as GatewayServiceDependencies);
    const port = await unusedPort();
    gateway = new GatewayServer({ display: displayOwnerOf(registry), host: "127.0.0.1", port, maxFrameBytes: 4 * 1_048_576, devices, uploads, sessions: registry, auth, service, logger });
    await gateway.listen();
    const frames: SocketFrame[] = [];
    socket = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${localToken}` } });
    socket.on("message", raw => frames.push(JSON.parse(raw.toString()) as SocketFrame));
    await new Promise<void>(resolve => socket.once("open", resolve));
    socket.send(JSON.stringify({ type: "hello", protocolVersion: PROTOCOL_VERSION }));
    await waitFor(() => frames.some(frame => frame.type === "hello"), "settings hello", { boundMs: 10_000 });

    const successfulId = "settings-success";
    socket.send(JSON.stringify({ type: "request", id: successfulId, method: "settings.resolve", params: { target: { kind: "global" }, keys: ["run.retry.maxRetries"] } }));
    await waitFor(() => frames.some(frame => frame.id === successfulId), "settings success response");
    const successfulResponse = frames.find(frame => frame.id === successfulId)!;
    expect(successfulResponse.ok).toBe(true);
    const projectedSetting = successfulResponse.result?.keys?.find(setting => setting.key === "run.retry.maxRetries");
    expect(projectedSetting?.value).toBe(7);
    expect(projectedSetting?.layer).toBe("global");

    mode = "failure";
    const failedId = "settings-failure";
    socket.send(JSON.stringify({ type: "request", id: failedId, method: "settings.resolve", params: { target: { kind: "global" }, keys: ["run.retry.maxRetries"] } }));
    await waitFor(() => frames.some(frame => frame.id === failedId), "settings failure response");
    expect(frames.find(frame => frame.id === failedId)?.ok).toBe(false);
    await waitFor(() => persistedLogRecords(logPath).some(record => record.requestID === failedId && record.event === "rpc.completed"), "persisted failed settings completion");
    const failedCompletion = persistedLogRecords(logPath).find(record => record.requestID === failedId && record.event === "rpc.completed")!;
    expect(failedCompletion.outcome).toBe("failure");
    expect(failedCompletion.method).toBe("settings.resolve");
    await mkdir(dirname(SETTINGS_REPORT_PATH), { recursive: true });
    await writeFile(SETTINGS_REPORT_PATH, `${JSON.stringify({
      persistedFailure: { requestId: failedId, outcome: failedCompletion.outcome, method: failedCompletion.method, attributed: typeof failedCompletion.stages === "string" && failedCompletion.stages.includes("settings.store.mac-terminal-keys") },
    }, null, 2)}\n`);
    expect(typeof failedCompletion.stages === "string" && failedCompletion.stages.includes("settings.store.mac-terminal-keys")).toBe(true);
    socket.close();
  });
});
