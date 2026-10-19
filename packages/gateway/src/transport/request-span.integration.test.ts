import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { existsSync, readFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import WebSocket from "ws";
import { ModelRuntime, SessionManager } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { AuthBroker } from "../admin/auth-broker.js";
import { TrustService } from "../admin/trust-service.js";
import { SettingsModel } from "../admin/settings-model.js";
import { UploadStore } from "../machine/upload-store.js";
import { DeviceStore } from "../security/device-store.js";
import { MacTerminalKeys } from "../security/mac-terminal.js";
import { RuntimeRegistry } from "../sessions/runtime-registry.js";
import { PROTOCOL_VERSION } from "../version.js";
import { CommandReceiptStore } from "./command-receipts.js";
import { GatewayService, type GatewayServiceDependencies } from "./gateway-service.js";
import { GatewayLogger, type LogRecord } from "./logger.js";
import { GatewayServer } from "./server.js";
import { RequestSpan, runInRequestSpan } from "./request-span.js";
import { waitFor } from "../../test-support/wait-for.js";

/**
 * Proves the request span's breakdown reaches the real log writer: every
 * `session.open` below runs through a real `GatewayServer`, `GatewayService`,
 * `RuntimeRegistry` and `GatewayLogger`, and the assertions read that logger's
 * own records instead of a double. A failed open proves the persisted JSONL
 * line, which is where the earlier allowlist dropped `stages` and
 * `unaccountedMs`.
 *
 * The exact breakdown and its request attribution are retained at
 * `packages/gateway/test-results/request-span.integration.json`, gitignored and
 * regenerated with `node_modules/.bin/vitest run src/transport/request-span.integration.test.ts`.
 * This gating test proves the structural contract only. The >=95% accounted-share
 * benchmark is tracked by #157; host scheduling under load contributes to that
 * ratio, so it is not a timing gate here.
 */

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => { await Promise.all(cleanups.splice(0).map((cleanup) => cleanup())); });

/** A 128-message, 2 MiB canonical transcript exercises the real cold-open path
 * without turning structural instrumentation coverage into a host benchmark. */
const COLD_OPEN_MESSAGE_COUNT = 128;
const COLD_OPEN_MESSAGE_TEXT_BYTES = 16 * 1_024;
/** Retained, regenerable evidence for one run of this file, like the other
 * integration cases: a stable gitignored path an operator can inspect. */
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

function isSessionOpenCompletion(record: LogRecord): boolean {
  return record.event === "rpc.completed" && record.method === "session.open";
}

/** Debug detail is memory-only, a slow or failed completion is persisted; the
 * open's own record is in exactly one of the two. */
function completedOpens(logger: GatewayLogger): LogRecord[] {
  return [...logger.debugTail(), ...logger.recent()].filter(isSessionOpenCompletion);
}

function persistedRecords(path: string): Array<Record<string, unknown>> {
  if (!existsSync(path)) return [];
  return readFileSync(path, "utf8").split("\n").filter(Boolean)
    .map((line) => JSON.parse(line) as Record<string, unknown>);
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
    // The duplicate waits at least as long as the first command held its lane,
    // and the lane stage is part of, never more than, its own request. The
    // first command's completed-receipt fsync also holds the lane (F-5), so
    // no fixed allowance on top of the held time can bound it on a busy disk.
    expect(laneWaitMs).toBeGreaterThanOrEqual(lockHeldMs - 1);
    expect(laneWaitMs).toBeLessThanOrEqual(secondElapsedMs);
  });
});

/** This case measures a 2 MiB cold `session.open` and reports its stages, so its
 * waits take a bound sized to the case's own budget (its test timeout below)
 * rather than the suite-wide hang bound: a loaded host must not report the
 * measurement's own fixture cost as a hang. Well below the 300 s timeout, and
 * well above the old 30 s speed budget this file used to carry. */
const COLD_OPEN_WAIT_BOUND_MS = 120_000;

describe("cold session.open request span", () => {
  it("names a cold open's stages in the real logger's record and reports their volume", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-request-span-open-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const sessionDirectory = join(agentDir, "sessions", "workspace");
    await Promise.all([mkdir(sessionDirectory, { recursive: true }), mkdir(cwd, { recursive: true })]);
    const text = "x".repeat(COLD_OPEN_MESSAGE_TEXT_BYTES);
    const manager = SessionManager.create(cwd, sessionDirectory);
    for (let message = 0; message < COLD_OPEN_MESSAGE_COUNT; message += 1) {
      manager.appendMessage(fauxAssistantMessage(`${text}-${message}`));
    }
    const fileBytes = (await readFile(manager.getSessionFile()!)).byteLength;

    const registry = new RuntimeRegistry({
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
    const localToken = JSON.parse(await readFile(join(root, "gateway", "local-auth.json"), "utf8")).bearerToken as string;
    const logPath = join(root, "logs", "gateway.jsonl");
    const logger = new GatewayLogger(logPath);
    const uploads = new UploadStore(root, 1_024);
    const auth = new AuthBroker(await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }), () => {});
    // Only the dependencies `session.open` never reaches are absent; the
    // registry, receipts, uploads, auth and the logger are real.
    const service = new GatewayService({
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
    gateway = new GatewayServer({
      host: "127.0.0.1",
      port,
      // The snapshot response of a large session is bounded by the page budget;
      // keep frame admission well above it so the measurement is the open.
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

    const reports: Array<Record<string, unknown>> = [];
    const requestId = "cold-open";
    const completionOf = (): LogRecord | undefined =>
      completedOpens(logger).find((record) => record.requestID === requestId);
    socket.send(JSON.stringify({
      type: "request",
      id: requestId,
      method: "session.open",
      params: { sessionId: manager.getSessionId() },
    }));
    await waitFor(() => frames.some((frame) => frame.id === requestId), "the request's response frame", { boundMs: COLD_OPEN_WAIT_BOUND_MS });
    const response = frames.find((frame) => frame.id === requestId);
    expect(response?.ok, JSON.stringify(response)).toBe(true);
    // By request ID, not by position: another RPC's record must not be read
    // as this open's breakdown.
    await waitFor(() => completionOf() !== undefined, "the completion", { boundMs: COLD_OPEN_WAIT_BOUND_MS });

    const completion = completionOf()!;
    const stages = completion.stages;
    const unaccountedMs = completion.unaccountedMs;
    const durationMs = completion.durationMs!;
    expect(stages, "the real logger must keep the span breakdown").toBeDefined();
    expect(unaccountedMs).toBeDefined();
    expect(completion.level).toBe(durationMs >= 1_000 ? "warning" : "debug");
    // The named stage is attributed to this exact RPC; serialized stage
    // durations plus uncovered time may differ by at most their rounding.
    expect(completion.requestID).toBe(requestId);
    const named = stagesOf(stages!);
    expect(named.get("session.open.manager")).toBeGreaterThan(0);
    const accountedMs = [...named.values()].reduce((total, duration) => total + duration, 0);
    expect(unaccountedMs!).toBeGreaterThanOrEqual(0);
    expect(unaccountedMs!).toBeLessThanOrEqual(durationMs);
    expect(Math.abs(durationMs - unaccountedMs! - accountedMs)).toBeLessThanOrEqual(named.size + 1);
    reports.push({
      requestId,
      durationMs,
      unaccountedMs,
      accountedMs,
      level: completion.level,
      stages,
      recordBytes: Buffer.byteLength(JSON.stringify(completion), "utf8"),
      stagesBytes: Buffer.byteLength(stages!, "utf8"),
      sessionFilesBytes: fileBytes,
    });

    // A failed open is persisted, so it proves the writer keeps the breakdown in
    // the JSONL file itself; the successful opens above are debug on this host.
    const failedRequestId = "missing-open";
    socket.send(JSON.stringify({
      type: "request",
      id: failedRequestId,
      method: "session.open",
      params: { sessionId: "00000000-0000-4000-8000-000000000000" },
    }));
    await waitFor(() => frames.some((frame) => frame.id === failedRequestId), "the failed request's response frame", { boundMs: COLD_OPEN_WAIT_BOUND_MS });
    expect(frames.find((frame) => frame.id === failedRequestId)?.ok).toBe(false);
    await waitFor(() => persistedRecords(logPath).some(
      (record) => record.requestID === failedRequestId && record.event === "rpc.completed",
    ), "the persisted rpc.completed record", { boundMs: COLD_OPEN_WAIT_BOUND_MS });
    const persisted = persistedRecords(logPath)
      .find((record) => record.requestID === failedRequestId && record.event === "rpc.completed")!;
    expect(persisted.outcome).toBe("failure");
    expect(persisted.stages, "the persisted line must carry the breakdown").toBeDefined();
    expect(persisted.stages as string).not.toBe("");
    expect(persisted.unaccountedMs).toBeDefined();
    expect(persisted.unaccountedMs as number).toBeGreaterThanOrEqual(0);
    expect(persisted.unaccountedMs as number).toBeLessThanOrEqual(persisted.durationMs as number);

    // The retained artifact: the exact breakdown, attribution, and bytes the
    // persisted line costs. Host-load ratios are reserved for the heavy run.
    const report = {
      coldOpens: reports.length,
      runs: reports,
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
    // The concrete public store supports an owned directory. Override only its
    // read boundary with a real process; do not erase the dependency's type.
    class FixtureMacTerminalKeys extends MacTerminalKeys {
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
    const macTerminalKeys = new FixtureMacTerminalKeys(join(root, "ssh"));
    const settingsModel = new SettingsModel({ agentDir, tronHome: root, trust, modelRuntime, macTerminalKeys });
    const registry = new RuntimeRegistry({
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
    const localToken = JSON.parse(await readFile(join(root, "gateway", "local-auth.json"), "utf8")).bearerToken as string;
    const logPath = join(root, "logs", "gateway.jsonl");
    const logger = new GatewayLogger(logPath);
    const uploads = new UploadStore(root, 1_024);
    const auth = new AuthBroker(await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }), () => {});
    const service = new GatewayService({
      config: { machineId: "machine", machineGroupID: "group", machineName: "Mac", tronHome: root, agentDir },
      devices, sessions: registry, receipts: new CommandReceiptStore(root), uploads, auth, logger,
      trust, settingsModel, modelRuntime,
      requestRestart: () => {}, sessionDeleted: () => {}, broadcast: () => {},
    } as unknown as GatewayServiceDependencies);
    const port = await unusedPort();
    gateway = new GatewayServer({ host: "127.0.0.1", port, maxFrameBytes: 4 * 1_048_576, devices, uploads, sessions: registry, auth, service, logger });
    await gateway.listen();
    const frames: SocketFrame[] = [];
    socket = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${localToken}` } });
    socket.on("message", raw => frames.push(JSON.parse(raw.toString()) as SocketFrame));
    await new Promise<void>(resolve => socket.once("open", resolve));
    socket.send(JSON.stringify({ type: "hello", protocolVersion: PROTOCOL_VERSION }));
    await waitFor(() => frames.some(frame => frame.type === "hello"), "settings hello", { boundMs: 10_000 });

    const successfulId = "settings-success";
    socket.send(JSON.stringify({ type: "request", id: successfulId, method: "settings.resolve", params: { target: { kind: "mac" }, keys: ["run.retry.maxRetries"] } }));
    await waitFor(() => frames.some(frame => frame.id === successfulId), "settings success response");
    const successfulResponse = frames.find(frame => frame.id === successfulId)!;
    expect(successfulResponse.ok).toBe(true);
    const projectedSetting = successfulResponse.result?.keys?.find(setting => setting.key === "run.retry.maxRetries");
    expect(projectedSetting?.value).toBe(7);
    expect(projectedSetting?.layer).toBe("mac");
    const successfulCompletion = [...logger.debugTail(), ...logger.recent()].find(record => record.event === "rpc.completed" && record.requestID === successfulId);
    expect(successfulCompletion?.outcome).toBe("success");
    expect(successfulCompletion?.method).toBe("settings.resolve");

    mode = "failure";
    const failedId = "settings-failure";
    socket.send(JSON.stringify({ type: "request", id: failedId, method: "settings.resolve", params: { target: { kind: "mac" }, keys: ["run.retry.maxRetries"] } }));
    await waitFor(() => frames.some(frame => frame.id === failedId), "settings failure response");
    expect(frames.find(frame => frame.id === failedId)?.ok).toBe(false);
    await waitFor(() => persistedRecords(logPath).some(record => record.requestID === failedId && record.event === "rpc.completed"), "persisted failed settings completion");
    const failedCompletion = persistedRecords(logPath).find(record => record.requestID === failedId && record.event === "rpc.completed")!;
    expect(failedCompletion.outcome).toBe("failure");
    expect(failedCompletion.method).toBe("settings.resolve");
    await mkdir(dirname(SETTINGS_REPORT_PATH), { recursive: true });
    await writeFile(SETTINGS_REPORT_PATH, `${JSON.stringify({
      success: { requestId: successfulId, outcome: successfulCompletion?.outcome, method: successfulCompletion?.method, attributed: successfulCompletion?.stages?.includes("settings.store.mac-terminal-keys") ?? false, projectedKey: "run.retry.maxRetries", projectedLayer: projectedSetting?.layer },
      persistedFailure: { requestId: failedId, outcome: failedCompletion.outcome, method: failedCompletion.method, attributed: typeof failedCompletion.stages === "string" && failedCompletion.stages.includes("settings.store.mac-terminal-keys") },
    }, null, 2)}\n`);
    expect({
      successAttributed: successfulCompletion?.stages?.includes("settings.store.mac-terminal-keys") ?? false,
      persistedFailureAttributed: typeof failedCompletion.stages === "string" && failedCompletion.stages.includes("settings.store.mac-terminal-keys"),
    }).toEqual({ successAttributed: true, persistedFailureAttributed: true });
    socket.close();
  });
});
