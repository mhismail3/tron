import { execFileSync, spawn } from "node:child_process";
import { once } from "node:events";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { afterAll, afterEach, describe, expect, it } from "vitest";
import { waitFor } from "../../test-support/wait-for.js";

// #729: a supervised restart logged `gateway.stopped` and then never left the
// process table, because Node's own exit teardown blocked. launchd only
// relaunches after the process is gone, so the deploy waited forever and Stable
// stayed down. These runs restart a real source Gateway with the deploy's own
// authenticated client.
//
// #1120: the native hang is libuv's at-exit join of a threadpool worker that
// never returns to take the exit message (in production, workers stranded in a
// Darwin psynch condition wait). A preload that parks one real worker in
// open(2) on a FIFO reproduces that join on demand, with the incident's main
// thread stack. A preload that blocks every `exit` listener still exercises the
// restart watcher for a JavaScript-level stall.

const gatewayRoot = fileURLToPath(new URL("../..", import.meta.url));
const resolverPreload = join(gatewayRoot, "test-support", "home-ledger-crash-preload.mjs");
const deployModule = pathToFileURL(join(gatewayRoot, "..", "..", "scripts", "gateway-payload-deploy.mjs")).href;
const reportPath = process.env.TRON_EXIT_AFTER_SHUTDOWN_REPORT
  ?? join(gatewayRoot, "test-results", "exit-after-shutdown.e2e.json");
const roots: string[] = [];
const children: Array<ReturnType<typeof spawn>> = [];
const report: Array<Record<string, unknown>> = [];

type LogRecord = { event?: string; message?: string; code?: string; pid?: number; durationMs?: number };

async function freePort(): Promise<number> {
  return await new Promise((resolve, reject) => {
    const server = createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      server.close(() => typeof address === "object" && address ? resolve(address.port) : reject(new Error("no port")));
    });
  });
}

async function readLog(tronHome: string): Promise<LogRecord[]> {
  const text = await readFile(join(tronHome, "logs", "gateway.jsonl"), "utf8").catch(() => "");
  return text.split("\n").filter(Boolean).flatMap((line) => {
    try { return [JSON.parse(line) as LogRecord]; } catch { return []; }
  });
}

type ExitHang = false | "exit-listener" | "threadpool-worker";

async function restartSupervisedGateway(options: { hangExit: ExitHang; method?: "gateway.restart" | "gateway.stop" }) {
  const root = await mkdtemp(join(tmpdir(), "tron-exit-after-shutdown-"));
  roots.push(root);
  const tronHome = join(root, "tron");
  const payloadRoot = join(root, "payload");
  for (const directory of ["home", "tmp", "agent", join("payload", "app", "dist")]) {
    await mkdir(join(root, directory), { recursive: true });
  }
  // The supervised marker requires a payload root holding a regular entrypoint.
  // This Gateway runs from source, so the payload's runtime contract stays
  // inactive while `gateway.restart` is admitted exactly as under launchd.
  await writeFile(join(payloadRoot, "app", "dist", "index.js"), "");
  const preloads = ["--import", pathToFileURL(resolverPreload).href];
  if (options.hangExit === "exit-listener") {
    const hang = join(root, "hang-exit.mjs");
    await writeFile(hang, "process.on('exit', () => { Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0); });\n");
    preloads.push("--import", pathToFileURL(hang).href);
  } else if (options.hangExit === "threadpool-worker") {
    // No writer ever opens the FIFO, so this worker never rejoins the pool.
    const fifo = join(root, "never-opened.fifo");
    execFileSync("mkfifo", [fifo]);
    const hang = join(root, "park-threadpool-worker.mjs");
    await writeFile(hang, `import { open } from "node:fs";\nopen(${JSON.stringify(fifo)}, "r", () => {});\n`);
    preloads.push("--import", pathToFileURL(hang).href);
  }
  const port = await freePort();
  const child = spawn(process.execPath, [
    "--experimental-transform-types", "--no-warnings", ...preloads, join(gatewayRoot, "src", "index.ts"),
  ], {
    cwd: gatewayRoot,
    stdio: ["ignore", "pipe", "pipe"],
    env: {
      PATH: process.env.PATH,
      HOME: join(root, "home"),
      TMPDIR: join(root, "tmp"),
      TRON_DATA_DIR: tronHome,
      PI_CODING_AGENT_DIR: join(root, "agent"),
      PI_SUBAGENTS_TEMP_ROOT: join(tronHome, "internal", "subagents"),
      TRON_GATEWAY_HOST: "127.0.0.1",
      TRON_GATEWAY_PORT: String(port),
      TRON_GATEWAY_SUPERVISED: "1",
      TRON_GATEWAY_PAYLOAD_ROOT: payloadRoot,
    },
  });
  children.push(child);
  let output = "";
  child.stdout.on("data", (chunk: Buffer) => { output += chunk.toString(); });
  child.stderr.on("data", (chunk: Buffer) => { output += chunk.toString(); });
  const exited = once(child, "exit") as Promise<[number | null, NodeJS.Signals | null]>;
  await waitFor(async () => {
    if (child.exitCode !== null || child.signalCode !== null) throw new Error(`Gateway exited during startup: ${output}`);
    return (await readLog(tronHome)).some((record) => record.event === "gateway.startup-budget") || undefined;
  }, "the source Gateway is serving");

  const { authenticatedRequest, readLocalCredential } = await import(deployModule) as {
    authenticatedRequest: (options: Record<string, unknown>) => Promise<unknown>;
    readLocalCredential: (path: string) => Promise<string>;
  };
  const token = await readLocalCredential(join(tronHome, "gateway", "local-auth.json"));
  const requestedAt = performance.now();
  const method = options.method ?? "gateway.restart";
  await authenticatedRequest({
    host: "127.0.0.1", port, token, timeoutMs: 10_000, method, params: { commandId: "exit-after-shutdown-e2e" },
  });
  if (method === "gateway.stop" && options.hangExit === "exit-listener") {
    await waitFor(async () => (await readLog(tronHome)).some(record => record.event === "gateway.stopped") || undefined,
      "the intentional-stop Gateway completed its shutdown", { boundMs: 30_000 });
    await new Promise(resolve => setTimeout(resolve, 6_000));
    const records = await readLog(tronHome);
    return { pid: child.pid, code: child.exitCode, signal: child.signalCode, records, exitMs: Math.round(performance.now() - requestedAt) };
  }
  const [code, signal] = await waitFor(async () => {
    if (child.exitCode === null && child.signalCode === null) return undefined;
    return await exited;
  }, "the Gateway left the process table", { boundMs: options.hangExit === "threadpool-worker" ? 20_000 : 60_000 });
  const records = await readLog(tronHome);
  return { pid: child.pid, code, signal, records, exitMs: Math.round(performance.now() - requestedAt) };
}

afterEach(async () => {
  for (const child of children.splice(0)) {
    if (child.exitCode !== null || child.signalCode !== null) continue;
    const exited = once(child, "exit");
    child.kill("SIGKILL");
    await exited;
  }
});

afterAll(async () => {
  await mkdir(dirname(reportPath), { recursive: true });
  await writeFile(reportPath, `${JSON.stringify({ issues: [729, 816, 1120], runs: report }, null, 2)}\n`);
  await Promise.all(roots.map((root) => rm(root, { recursive: true, force: true })));
});

describe("Gateway exit after a supervised restart", () => {
  it("exits with the relaunch code and is never killed when exit completes", async () => {
    const result = await restartSupervisedGateway({ hangExit: false });
    report.push({ case: "exit completes", code: result.code, signal: result.signal, exitMs: result.exitMs });
    expect(result.signal).toBeNull();
    expect(result.code).toBe(75);
    expect(result.records.some((record) => record.event === "gateway.exit-stalled")).toBe(false);
  });

  it("leaves the process table when exit blocks after the shutdown was recorded", async () => {
    const result = await restartSupervisedGateway({ hangExit: "exit-listener" });
    const events = result.records.map((record) => record.event);
    const stalled = result.records.find((record) => record.event === "gateway.exit-stalled");
    report.push({ case: "exit blocks", code: result.code, signal: result.signal, exitMs: result.exitMs, stalled });
    // launchd's KeepAlive (SuccessfulExit=false) relaunches after a signal death
    // exactly as after exit 75, so the kill preserves the requested restart.
    expect(result.signal).toBe("SIGKILL");
    expect(events.indexOf("gateway.stopped")).toBeGreaterThanOrEqual(0);
    expect(events.indexOf("gateway.exit-stalled")).toBeGreaterThan(events.indexOf("gateway.stopped"));
    expect(stalled).toMatchObject({ pid: result.pid, code: "75" });
  });

  it("restarts with the relaunch code when a threadpool worker never rejoins at exit", async () => {
    const result = await restartSupervisedGateway({ hangExit: "threadpool-worker" });
    report.push({ case: "threadpool worker never rejoins: restart", code: result.code, signal: result.signal, exitMs: result.exitMs });
    expect(result.signal).toBeNull();
    expect(result.code).toBe(75);
    expect(result.records.some((record) => record.event === "gateway.exit-stalled")).toBe(false);
  });

  it("completes an intentional stop with exit 0 when a threadpool worker never rejoins at exit", async () => {
    const result = await restartSupervisedGateway({ hangExit: "threadpool-worker", method: "gateway.stop" });
    report.push({ case: "threadpool worker never rejoins: stop", code: result.code, signal: result.signal, exitMs: result.exitMs });
    expect(result.signal).toBeNull();
    expect(result.code).toBe(0);
    expect(result.records.some(record => record.event === "gateway.stopped" && record.pid === result.pid && record.code === "0")).toBe(true);
  });

  it("exits normally after an intentional stop", async () => {
    const result = await restartSupervisedGateway({ hangExit: false, method: "gateway.stop" });
    report.push({ case: "intentional stop exits", code: result.code, signal: result.signal, exitMs: result.exitMs });
    expect(result.signal).toBeNull();
    expect(result.code).toBe(0);
    expect(result.records.some(record => record.event === "gateway.stopped" && record.pid === result.pid && record.code === "0")).toBe(true);
  });

  it("records intentional stop completion but does not kill a process blocked in exit", async () => {
    const result = await restartSupervisedGateway({ hangExit: "exit-listener", method: "gateway.stop" });
    report.push({ case: "intentional stop exit blocks", code: result.code, signal: result.signal, exitMs: result.exitMs });
    expect(result.code).toBeNull();
    expect(result.signal).toBeNull();
    expect(result.records.some(record => record.event === "gateway.stopped" && record.pid === result.pid && record.code === "0")).toBe(true);
    expect(result.records.some(record => record.event === "gateway.exit-stalled")).toBe(false);
  }, 45_000);
});
