#!/usr/bin/env node
// #1120: repeated intentional-stop and supervised-restart cycles of a real source
// Gateway under the pinned Node, in one isolated realistic home that every cycle
// reuses, as a production Gateway restarts in place. A cycle whose process is
// still alive after its `gateway.stopped` record is a stall: its all-thread lldb
// backtrace and a sample are captured before the harness SIGKILLs that child.
// Only the children this script spawns are ever signalled. Test-only suspect
// toggles are `--preload` modules, never production code.
//
//   scripts/tron-node exec node packages/gateway/scripts/measure-exit-stall-cycles.mjs \
//     --label baseline --cycles 10 --method alternate [--preload file.mjs]...
import { spawn, execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import { once } from "node:events";
import { createWriteStream } from "node:fs";
import { access, mkdir, mkdtemp, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { constants } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { performance } from "node:perf_hooks";
import { setTimeout as sleep } from "node:timers/promises";
import { fileURLToPath, pathToFileURL } from "node:url";
import WebSocket from "ws";

const gatewayRoot = fileURLToPath(new URL("..", import.meta.url));
const repoRoot = resolve(gatewayRoot, "..", "..");
const resolverPreload = join(gatewayRoot, "test-support", "home-ledger-crash-preload.mjs");
const deployModule = pathToFileURL(join(repoRoot, "scripts", "gateway-payload-deploy.mjs")).href;
const artifactRoot = join(gatewayRoot, "test-results", "exit-stall-cycles");

const USAGE = "usage: measure-exit-stall-cycles.mjs --label NAME [--cycles N] [--method stop|restart|alternate] "
  + "[--preload FILE]... [--sessions N] [--terminal none|spawn-dispose] [--payload DIR] [--stall-ms MS] [--capture-after-stopped-ms MS]";

function parseArguments(argv) {
  const options = {
    label: undefined, cycles: 10, method: "alternate", preloads: [], sessions: 0, terminal: "none", payload: undefined,
    stallMs: 30_000, captureAfterStoppedMs: 1_000,
  };
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (value === undefined) throw new Error(`${flag} needs a value\n${USAGE}`);
    if (flag === "--label") options.label = value;
    else if (flag === "--cycles") options.cycles = positiveInteger(flag, value);
    else if (flag === "--method") {
      if (!["stop", "restart", "alternate"].includes(value)) throw new Error(`--method must be stop, restart or alternate\n${USAGE}`);
      options.method = value;
    }
    else if (flag === "--preload") options.preloads.push(resolve(value));
    // A built payload (runtime/node-arm64 + app/dist/index.js) is run read-only, as
    // the staged Gateway is; the isolated supervised marker root stays separate.
    else if (flag === "--payload") options.payload = resolve(value);
    else if (flag === "--sessions") options.sessions = nonNegativeInteger(flag, value);
    else if (flag === "--terminal") {
      if (!["none", "spawn-dispose"].includes(value)) throw new Error(`--terminal must be none or spawn-dispose\n${USAGE}`);
      options.terminal = value;
    }
    else if (flag === "--stall-ms") options.stallMs = positiveInteger(flag, value);
    else if (flag === "--capture-after-stopped-ms") options.captureAfterStoppedMs = positiveInteger(flag, value);
    else throw new Error(`unknown argument ${flag}\n${USAGE}`);
  }
  if (!options.label || !/^[a-z0-9-]+$/.test(options.label)) throw new Error(`--label must match [a-z0-9-]+\n${USAGE}`);
  if (options.terminal !== "none" && options.sessions === 0) throw new Error("--terminal needs --sessions 1 or more (a terminal opens on a session)");
  return options;
}

function positiveInteger(flag, value) {
  const number = Number(value);
  if (!Number.isInteger(number) || number <= 0) throw new Error(`${flag} must be a positive integer`);
  return number;
}

function nonNegativeInteger(flag, value) {
  const number = Number(value);
  if (!Number.isInteger(number) || number < 0) throw new Error(`${flag} must be a non-negative integer`);
  return number;
}

async function freePort() {
  return await new Promise((resolvePort, reject) => {
    const server = createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      server.close(() => typeof address === "object" && address ? resolvePort(address.port) : reject(new Error("no port")));
    });
  });
}

async function readGatewayLog(tronHome) {
  const text = await readFile(join(tronHome, "logs", "gateway.jsonl"), "utf8").catch(() => "");
  return text.split("\n").filter(Boolean).flatMap((line) => {
    try { return [JSON.parse(line)]; } catch { return []; }
  });
}

function isAlive(child) {
  return child.exitCode === null && child.signalCode === null;
}

// The lldb backtrace is the evidence the issue asks for; it is captured before
// anything signals the stalled child. `sample` runs after it as a second view.
async function captureHang(pid, cycleDirectory) {
  const lldbPath = join(cycleDirectory, "lldb-threads.txt");
  const samplePath = join(cycleDirectory, "sample.txt");
  const lldbStarted = performance.now();
  const lldb = await run("lldb", ["-p", String(pid), "--batch", "-o", "thread backtrace all", "-o", "detach", "-o", "quit"], 90_000);
  await writeFile(lldbPath, lldb.output);
  const lldbMs = Math.round(performance.now() - lldbStarted);
  const sampleStarted = performance.now();
  const sample = await run("/usr/bin/sample", [String(pid), "1", "-file", samplePath], 60_000);
  const sampleMs = Math.round(performance.now() - sampleStarted);
  return {
    lldb: { path: lldbPath, exitCode: lldb.code, durationMs: lldbMs },
    sample: { path: samplePath, exitCode: sample.code, durationMs: sampleMs },
  };
}

function run(command, args, timeoutMs) {
  return new Promise((resolveRun) => {
    execFile(command, args, { timeout: timeoutMs, maxBuffer: 64 * 1024 * 1024 }, (error, stdout, stderr) => {
      const code = error ? (typeof error.code === "number" ? error.code : `${error.signal ?? error.message}`) : 0;
      resolveRun({ code, output: `${stdout}${stderr}` });
    });
  });
}

function startGateway({ home, port, options }) {
  const preloadArguments = options.preloads.flatMap((preload) => ["--import", pathToFileURL(preload).href]);
  // Source runs under the pinned toolchain with the resolver; a payload runs its
  // own bundled runtime with the production launch arguments (launchd's ProgramArguments).
  const launch = options.payload
    ? {
      command: join(options.payload, "runtime", "node-arm64"),
      args: ["--max-old-space-size=4096", ...preloadArguments, join(options.payload, "app", "dist", "index.js")],
      cwd: join(options.payload, "app"),
    }
    : {
      command: process.execPath,
      args: [
        "--experimental-transform-types", "--no-warnings", "--import", pathToFileURL(resolverPreload).href,
        ...preloadArguments, join(gatewayRoot, "src", "index.ts"),
      ],
      cwd: gatewayRoot,
    };
  return spawn(launch.command, launch.args, {
    cwd: launch.cwd,
    stdio: ["ignore", "pipe", "pipe"],
    env: {
      PATH: process.env.PATH,
      HOME: join(home.root, "home"),
      TMPDIR: join(home.root, "tmp"),
      TRON_DATA_DIR: home.tronHome,
      PI_CODING_AGENT_DIR: join(home.root, "agent"),
      PI_SUBAGENTS_TEMP_ROOT: join(home.tronHome, "internal", "subagents"),
      TRON_GATEWAY_HOST: "127.0.0.1",
      TRON_GATEWAY_PORT: String(port),
      TRON_GATEWAY_SUPERVISED: "1",
      TRON_GATEWAY_PAYLOAD_ROOT: home.payloadRoot,
    },
  });
}

async function createIsolatedHome() {
  const root = await mkdtemp(join(tmpdir(), "tron-1120-cycles-"));
  // Owner-only like a production home: the Gateway refuses a Tron workspace
  // whose directories other users can read.
  for (const directory of ["home", "tmp", "agent", join("payload", "app", "dist"), join("tron")]) {
    await mkdir(join(root, directory), { recursive: true, mode: 0o700 });
  }
  const payloadRoot = join(root, "payload");
  // The supervised marker needs a payload entrypoint in its own root. This root is
  // isolated and never the artifact under test, which only supplies the runtime
  // and entry under --payload.
  await writeFile(join(payloadRoot, "app", "dist", "index.js"), "");
  return { root, payloadRoot, tronHome: join(root, "tron") };
}

// A realistic home holds persisted sessions. `session.create` alone keeps a
// session in memory until its first turn, so seeding copies canonical Pi session
// files from the corpus (the same bytes the SDK corpus test reads) into the
// directory the registry uses for this cwd. Their catalog, search index and
// startup warm-up are then real work on the Gateway.
const CORPUS_SESSIONS = join(gatewayRoot, "test-fixtures", "pi-sdk", "corpus", "agent", "sessions");
const CORPUS_WORKSPACE_TOKEN = "«corpus-workspace»";
async function seedSessions(home, count) {
  const files = (await readdir(CORPUS_SESSIONS)).filter((name) => name.endsWith(".jsonl")).sort();
  if (count > files.length) throw new Error(`--sessions ${count} exceeds the ${files.length} corpus sessions`);
  const cwd = join(home.root, "workspace", "project-1");
  await mkdir(cwd, { recursive: true });
  // Mirrors SessionRegistry.sessionDirectoryFor: resolved cwd with separators as dashes.
  const directory = join(home.root, "agent", "sessions", `--${cwd.replace(/^[/\\]/, "").replace(/[/\\:]/g, "-")}--`);
  await mkdir(directory, { recursive: true, mode: 0o700 });
  home.sessionIds = [];
  for (const name of files.slice(0, count)) {
    const text = (await readFile(join(CORPUS_SESSIONS, name), "utf8")).replaceAll(CORPUS_WORKSPACE_TOKEN, cwd);
    await writeFile(join(directory, name), text, { mode: 0o600 });
    home.sessionIds.push(JSON.parse(text.split("\n")[0]).id);
  }
}

// A client that stays connected through the stop, like the Mac app's. Terminal
// I/O is only admitted on a connection that opened the session first.
async function openPersistentClient({ port, token }) {
  const socket = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, {
    headers: { authorization: `Bearer ${token}` }, perMessageDeflate: false,
  });
  const pending = new Map();
  const { protocolHandshakeCompatible } = await import(deployModule);
  await new Promise((resolveReady, reject) => {
    socket.once("error", reject);
    socket.once("open", () => socket.send(JSON.stringify({ type: "hello", protocolVersion: 8, clientId: randomUUID() })));
    socket.on("message", (raw) => {
      let frame;
      try { frame = JSON.parse(raw.toString()); } catch { return; }
      if (frame.type === "hello") {
        if (!protocolHandshakeCompatible(frame)) reject(new Error("Gateway protocol handshake is not compatible"));
        else resolveReady();
        return;
      }
      if (frame.type !== "response" || !pending.has(frame.id)) return;
      const request = pending.get(frame.id);
      pending.delete(frame.id);
      if (frame.ok === true) request.resolve(frame.result ?? null);
      else request.reject(new Error(frame.error?.message ?? "request failed"));
    });
  });
  return {
    request(method, params) {
      const id = randomUUID();
      return new Promise((resolveRequest, rejectRequest) => {
        pending.set(id, { resolve: resolveRequest, reject: rejectRequest });
        socket.send(JSON.stringify({ type: "request", id, method, params }));
      });
    },
    close() { socket.close(); },
  };
}

async function childPids(parentPid) {
  const { output } = await run("ps", ["-axo", "pid=,ppid="], 10_000);
  return output.split("\n").map((line) => line.trim().split(/\s+/).map(Number))
    .filter(([, ppid]) => ppid === parentPid).map(([pid]) => pid);
}

async function runCycle({ home, cycle, method, options, evidenceRoot }) {
  const cycleDirectory = join(evidenceRoot, `cycle-${cycle}`);
  await mkdir(cycleDirectory, { recursive: true });
  const port = await freePort();
  // The log is shared by every cycle of this home, so readiness counts only
  // the records this cycle's process adds.
  const budgetsBefore = (await readGatewayLog(home.tronHome)).filter((record) => record.event === "gateway.startup-budget").length;
  const child = startGateway({ home, port, options });
  const output = createWriteStream(join(cycleDirectory, "gateway-output.log"), { mode: 0o600 });
  child.stdout.pipe(output, { end: false });
  child.stderr.pipe(output, { end: false });
  const exit = once(child, "exit").then(([code, signal]) => ({ code, signal, at: performance.now() }));
  let exited;
  exit.then((state) => { exited = state; });
  const result = { cycle, method, pid: child.pid, port, outcome: undefined, stoppedRecord: undefined, capture: undefined };
  let client;
  try {
    await waitFor(async () => {
      if (exited) throw new Error(`Gateway exited during startup (code ${exited.code}, signal ${exited.signal})`);
      const budgets = (await readGatewayLog(home.tronHome)).filter((record) => record.event === "gateway.startup-budget").length;
      return budgets > budgetsBefore || undefined;
    }, 60_000, "the Gateway is serving");
    const { authenticatedRequest, readLocalCredential } = await import(deployModule);
    const token = await readLocalCredential(join(home.tronHome, "gateway", "local-auth.json"));
    if (options.terminal !== "none") {
      // Real session work and a live PTY per cycle. The Gateway refuses an
      // intentional stop while a device holds an open terminal, so the cycle
      // spawns the PTY, then the client terminates it before the stop, as a
      // user closing terminals before Quit does.
      client = await openPersistentClient({ port, token });
      const sessionId = home.sessionIds[0];
      await client.request("session.open", { sessionId, commandId: `1120-${options.label}-${cycle}-open` });
      const opened = await client.request("terminal.open", {
        sessionId, columns: 100, rows: 30, commandId: `1120-${options.label}-${cycle}-terminal`,
      });
      result.terminal = { mode: options.terminal, terminalId: opened.terminal.id, shellPidsBeforeStop: await childPids(child.pid) };
      await client.request("terminal.terminate", { terminalId: opened.terminal.id, commandId: `1120-${options.label}-${cycle}-terminate` });
    }
    const requestedAt = performance.now();
    await authenticatedRequest({
      host: "127.0.0.1", port, token, timeoutMs: 10_000, method, params: { commandId: `1120-${options.label}-${cycle}` },
    });
    let stoppedAt;
    let captured = false;
    while (!exited) {
      const stopped = (await readGatewayLog(home.tronHome)).find((record) => record.event === "gateway.stopped" && record.pid === child.pid);
      if (stopped && stoppedAt === undefined) {
        stoppedAt = performance.now();
        result.stoppedRecord = { code: stopped.code, durationMs: Math.round(stopped.durationMs) };
      }
      const now = performance.now();
      // A normal exit leaves within milliseconds of gateway.stopped. Capture a
      // process still alive after the capture delay, before a restart's
      // watcher SIGKILLs it, and at the deadline if shutdown never completed.
      const captureDue = (stoppedAt !== undefined && now - stoppedAt >= options.captureAfterStoppedMs)
        || now - requestedAt >= options.stallMs;
      if (!captured && captureDue && !exited) {
        captured = true;
        result.capture = { atMs: Math.round(now - requestedAt), phase: stoppedAt === undefined ? "before-stopped" : "after-stopped",
          ...(await captureHang(child.pid, cycleDirectory)) };
      }
      if (now - requestedAt >= options.stallMs) break;
      await Promise.race([sleep(100), exit]);
    }
    if (exited) {
      result.exit = { code: exited.code, signal: exited.signal, afterStoppedMs: stoppedAt === undefined
        ? undefined : Math.round(exited.at - stoppedAt) };
      result.outcome = exited.signal === null && (method === "gateway.stop" ? exited.code === 0 : exited.code === 75)
        ? "exited" : "exited-abnormally";
    } else {
      result.outcome = "stalled";
      result.exit = { code: null, signal: "SIGKILL-by-harness", afterStoppedMs: undefined };
    }
  } catch (error) {
    result.outcome = "error";
    result.error = error instanceof Error ? error.message : String(error);
  } finally {
    client?.close();
    if (!exited) {
      child.kill("SIGKILL");
      await exit;
    }
    if (result.terminal) {
      // A PTY shell that outlives its Gateway is a leak this run must surface.
      const survivors = [];
      for (const pid of result.terminal.shellPidsBeforeStop) {
        const alive = await run("ps", ["-p", String(pid), "-o", "pid="], 5_000);
        if (alive.output.trim() !== "") survivors.push(pid);
      }
      result.terminal.survivorsAfterExit = survivors;
    }
    const records = await readGatewayLog(home.tronHome);
    await writeFile(join(cycleDirectory, "gateway.jsonl"), records.map((record) => JSON.stringify(record)).join("\n") + "\n", { mode: 0o600 });
    result.exitStalledRecord = records.some((record) => record.event === "gateway.exit-stalled" && record.pid === child.pid);
    output.end();
  }
  return result;
}

async function waitFor(check, timeoutMs, description) {
  const deadline = performance.now() + timeoutMs;
  for (;;) {
    const value = await check();
    if (value !== undefined) return value;
    if (performance.now() >= deadline) throw new Error(`timed out waiting for ${description}`);
    await sleep(100);
  }
}

function summarize(cycles) {
  const stalls = cycles.filter((cycle) => cycle.outcome === "stalled");
  const byMethod = {};
  for (const method of new Set(cycles.map((cycle) => cycle.method))) {
    const runs = cycles.filter((cycle) => cycle.method === method);
    byMethod[method] = { cycles: runs.length, stalls: runs.filter((cycle) => cycle.outcome === "stalled").length };
  }
  return {
    cycles: cycles.length,
    stalls: stalls.length,
    stallRate: cycles.length ? Number((stalls.length / cycles.length).toFixed(3)) : null,
    outcomes: Object.fromEntries([...new Set(cycles.map((cycle) => cycle.outcome))].map((outcome) => [
      outcome, cycles.filter((cycle) => cycle.outcome === outcome).length,
    ])),
    byMethod,
  };
}

async function main() {
  const options = parseArguments(process.argv.slice(2));
  const pin = (await readFile(join(repoRoot, ".node-version"), "utf8")).trim();
  if (process.version !== `v${pin}`) {
    throw new Error(`run under the pinned Node v${pin} (scripts/tron-node exec); this is ${process.version}`);
  }
  const evidenceRoot = join(artifactRoot, options.label);
  await rm(evidenceRoot, { recursive: true, force: true });
  await mkdir(evidenceRoot, { recursive: true });
  if (options.payload) {
    const required = [
      [join(options.payload, "runtime", "node-arm64"), constants.X_OK],
      [join(options.payload, "app", "dist", "index.js"), constants.R_OK],
    ];
    for (const [path, mode] of required) {
      await access(path, mode).catch(() => { throw new Error(`--payload is missing ${path}`); });
    }
  }
  const payloadNode = options.payload
    ? (await run(join(options.payload, "runtime", "node-arm64"), ["--version"], 30_000)).output.trim()
    : undefined;
  const reportPath = join(artifactRoot, `${options.label}.json`);
  const home = await createIsolatedHome();
  if (options.sessions > 0) await seedSessions(home, options.sessions);
  const report = {
    label: options.label,
    createdAt: new Date().toISOString(),
    node: process.version,
    pin,
    platform: `${process.platform}-${process.arch}`,
    stallMs: options.stallMs,
    captureAfterStoppedMs: options.captureAfterStoppedMs,
    preloads: options.preloads.map((preload) => preload.slice(gatewayRoot.length)),
    method: options.method,
    sessions: options.sessions,
    terminal: options.terminal,
    entry: options.payload
      ? { kind: "payload", root: options.payload, node: payloadNode, runtime: "runtime/node-arm64", entry: "app/dist/index.js" }
      : { kind: "source", node: process.version, entry: "src/index.ts" },
    home: "isolated temporary root, removed after the run; logs kept per cycle",
    cycles: [],
  };
  try {
    for (let cycle = 1; cycle <= options.cycles; cycle++) {
      const method = options.method === "alternate"
        ? (cycle % 2 === 1 ? "gateway.stop" : "gateway.restart")
        : `gateway.${options.method}`;
      const result = await runCycle({ home, cycle, method, options, evidenceRoot });
      report.cycles.push(result);
      report.summary = summarize(report.cycles);
      await writeFile(reportPath, `${JSON.stringify(report, null, 2)}\n`);
      console.log(`cycle ${cycle} ${method}: ${result.outcome}${result.capture ? ` (captured ${result.capture.phase}: ${result.capture.lldb.path})` : ""}`);
    }
  } finally {
    report.summary = summarize(report.cycles);
    await writeFile(reportPath, `${JSON.stringify(report, null, 2)}\n`);
    await rm(home.root, { recursive: true, force: true });
  }
  console.log(JSON.stringify(report.summary));
}

await main();
