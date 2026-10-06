import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { existsSync, readFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import WebSocket from "ws";
import { ModelRuntime, SessionManager } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { AuthBroker } from "../admin/auth-broker.js";
import { BackgroundWorkScheduler } from "../background-work.js";
import { TrustService } from "../admin/trust-service.js";
import { UploadStore } from "../machine/upload-store.js";
import { DeviceStore } from "../security/device-store.js";
import { GatewayWorkRegistry } from "../sessions/gateway-work-registry.js";
import { RuntimeRegistry } from "../sessions/runtime-registry.js";
import { PROTOCOL_VERSION } from "../version.js";
import { CommandReceiptStore } from "./command-receipts.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "./gateway-service.js";
import { GatewayLogger, type LogRecord } from "./logger.js";
import { GatewayServer } from "./server.js";
import { RequestSpan, requestsCompetingForLoop, runInRequestSpan } from "./request-span.js";
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
 *
 * The second case drives the scheduler's in-flight signal (`requestsCompetingForLoop`,
 * the predicate `gateway-main.ts` passes) through the real `GatewayService`
 * mutation boundary: only the receipt store is a double there, and it hands the
 * operation straight through.
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

interface SocketFrame {
  type?: string;
  id?: string;
  ok?: boolean;
  result?: { session?: { sessionId?: string }; syncToken?: string };
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
    await waitFor(() => frames.some((frame) => frame.type === "hello"), "the hello frame");

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
    await waitFor(() => frames.some((frame) => frame.id === requestId), "the request's response frame");
    const response = frames.find((frame) => frame.id === requestId);
    expect(response?.ok, JSON.stringify(response)).toBe(true);
    // By request ID, not by position: another RPC's record must not be read
    // as this open's breakdown.
    await waitFor(() => completionOf() !== undefined, "the completion");

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
    await waitFor(() => frames.some((frame) => frame.id === failedRequestId), "the failed request's response frame");
    expect(frames.find((frame) => frame.id === failedRequestId)?.ok).toBe(false);
    await waitFor(() => persistedRecords(logPath).some(
      (record) => record.requestID === failedRequestId && record.event === "rpc.completed",
    ), "the persisted rpc.completed record");
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

describe("request loop signal", () => {
  const client: ClientContext = {
    id: "phone",
    identity: "device:test",
    isLocal: false,
    beginSynchronization: () => "sync",
    establishSynchronization: () => {},
    completeSynchronization: () => {},
    unsubscribe: () => true,
    attachTerminal: () => {},
    detachTerminal: () => {},
    ownsTerminal: () => false,
    isSubscribed: () => true,
    isRevoked: () => false,
    revokeDevice: () => {},
  };

  it("keeps running a due slice while a receipt-backed mutation waits, and pauses for a request that shares the loop", async () => {
    const scheduler = new BackgroundWorkScheduler();
    const slices: number[] = [];
    scheduler.register({ name: "check.slice", intervalMs: 1, slice: () => { slices.push(1); } });
    // The production wiring: the in-flight signal is the request span count.
    scheduler.start({ requestsInFlight: requestsCompetingForLoop });
    try {
      // An idle loop runs the job.
      await waitFor(() => slices.length >= 2, "the second background slice");
      const idle = slices.length;

      // A request that shares the loop pauses the slices.
      const readSpan = new RequestSpan();
      await new Promise((resolve) => setTimeout(resolve, 50));
      const paused = slices.length;
      await new Promise((resolve) => setTimeout(resolve, 60));
      expect(slices.length).toBe(paused);
      readSpan.breakdown(0);

      // A receipt-backed mutation whose operation waits away from the loop does
      // not: one `!` bash command or one manual compaction holds its receipt for
      // minutes without using the loop, and pausing for it would stop the loop's
      // background work for that whole time.
      const workRegistry = new GatewayWorkRegistry("epoch", 8);
      let finishRename: (() => void) | undefined;
      const service = new GatewayService({
        sessions: {
          acquire: async () => ({
            rename: () => new Promise<void>((resolve) => { finishRename = resolve; }),
          }),
        },
        receipts: {
          execute: async (
            _identity: string,
            _method: string,
            _commandId: string,
            operation: () => Promise<unknown>,
          ) => operation(),
        },
        workRegistry,
      } as unknown as GatewayServiceDependencies);

      const mutationSpan = new RequestSpan();
      const pending = runInRequestSpan(mutationSpan, () => service.invoke(
        client,
        "session.rename",
        { commandId: "rename-command", sessionId: "session-1", name: "Renamed" },
      ));
      await waitFor(() => finishRename !== undefined, "the rename to finish");
      expect(requestsCompetingForLoop()).toBe(false);
      expect(workRegistry.facts()).toEqual([
        expect.objectContaining({ kind: "rpc-mutation", method: "session.rename" }),
      ]);
      // A slice already decided before the mutation started settles here; every
      // slice after it must still start while the mutation waits.
      await new Promise((resolve) => setTimeout(resolve, 30));
      const holding = slices.length;
      await waitFor(() => slices.length > holding, "the background slices to resume");

      finishRename!();
      await pending;
      // The request is on the loop again for its receipt write and its response.
      expect(requestsCompetingForLoop()).toBe(true);
      mutationSpan.breakdown(0);
      expect(requestsCompetingForLoop()).toBe(false);
      await waitFor(() => workRegistry.size === 0, "the work registry to drain");
    } finally {
      scheduler.stop();
    }
  }, 30_000);
});
