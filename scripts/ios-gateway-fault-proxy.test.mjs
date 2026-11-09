// The fault proxy's Gateway ownership proof (#2386). The real proxy script runs
// from a temporary copy whose repository layout puts a stand-in Gateway at
// packages/gateway/dist/index.js, so the CLI cases exercise its own process,
// ps/lsof proof and refusals; the verifier cases substitute only its ps/lsof
// runner to produce timeouts and PID reuse on demand.
import assert from "node:assert/strict";
import { test, after } from "node:test";
import { copyFile, mkdtemp, mkdir, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { request as httpRequest, createServer } from "node:http";
import { randomBytes } from "node:crypto";
import { fileURLToPath, pathToFileURL } from "node:url";

const scripts = fileURLToPath(new URL(".", import.meta.url));
const gateway = join(scripts, "..", "packages", "gateway");
const root = realpathSync(await mkdtemp(join(tmpdir(), "tron-fault-proxy-test-")));
await mkdir(join(root, "scripts"));
await mkdir(join(root, "packages", "gateway", "dist"), { recursive: true });
await copyFile(join(scripts, "ios-gateway-fault-proxy.mjs"), join(root, "scripts", "ios-gateway-fault-proxy.mjs"));
await copyFile(join(gateway, "package.json"), join(root, "packages", "gateway", "package.json"));
await symlink(join(gateway, "node_modules"), join(root, "packages", "gateway", "node_modules"));
const entry = join(root, "packages", "gateway", "dist", "index.js");
await writeFile(entry, `import { createServer } from "node:http";
createServer((request, response) => response.end("gateway")).listen(Number(process.env.TRON_GATEWAY_PORT), "127.0.0.1");
`);
await writeFile(join(root, "packages", "gateway", "dist", "package.json"), "{\"type\":\"module\"}\n");
const children = new Set();
after(async () => {
  for (const child of children) child.kill("SIGKILL");
  await rm(root, { recursive: true, force: true });
});

function get(port, path = "/health") {
  return new Promise(resolve => {
    const outgoing = httpRequest({ host: "127.0.0.1", port, path, agent: false, timeout: 10_000 }, response => {
      let body = "";
      response.on("data", chunk => { body += chunk; });
      response.on("end", () => resolve({ status: response.statusCode, body }));
    });
    outgoing.on("error", error => resolve({ status: 0, body: error.code }));
    outgoing.on("timeout", () => outgoing.destroy());
    outgoing.end();
  });
}

async function until(read, describe, timeoutMs = 15_000) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const value = await read();
    if (value) return value;
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${describe}`);
    await new Promise(resolve => setTimeout(resolve, 50));
  }
}

function freePort() {
  const server = createServer();
  return new Promise(resolve => server.listen(0, "127.0.0.1", () => {
    const { port } = server.address();
    server.close(() => resolve(port));
  }));
}

function track(child) {
  children.add(child);
  child.once("exit", () => children.delete(child));
  return child;
}

// One Gateway and its proxy, both children of this process as the harness
// makes them siblings: the proxy proves the Gateway's parent is its own.
async function startFixture() {
  const dir = await mkdtemp(join(root, "fixture-"));
  const upstreamPort = await freePort();
  const gatewayProcess = track(spawn(process.execPath, [entry], {
    env: { PATH: process.env.PATH, TRON_GATEWAY_PORT: String(upstreamPort) }, stdio: "ignore",
  }));
  await until(async () => (await get(upstreamPort)).status === 200, "the stand-in Gateway");
  const token = randomBytes(32).toString("hex");
  const ready = join(dir, "ready.json");
  const proxy = track(spawn(process.execPath, [join(root, "scripts", "ios-gateway-fault-proxy.mjs")], {
    env: {
      PATH: process.env.PATH, HOME: dir,
      TRON_E2E_UPSTREAM_PORT: String(upstreamPort), TRON_E2E_UPSTREAM_PID: String(gatewayProcess.pid),
      TRON_E2E_GATEWAY_ENTRY: entry, TRON_E2E_GATEWAY_HOME: dir, TRON_E2E_TRON_HOME: dir, TRON_E2E_AGENT_DIR: dir,
      TRON_E2E_GATEWAY_LOG: join(dir, "gateway.log"), TRON_E2E_GATEWAY_PID_FILE: join(dir, "gateway.pid"),
      TRON_E2E_PROXY_TOKEN: token, TRON_E2E_PROXY_READY: ready,
    },
    stdio: "ignore",
  }));
  const { port } = JSON.parse(await until(() => readFile(ready, "utf8").catch(() => ""), "the proxy"));
  const control = mode => new Promise((resolve, reject) => {
    const outgoing = httpRequest({ host: "127.0.0.1", port, path: "/_fixture/control", method: "POST", agent: false,
      headers: { "x-tron-fixture-token": token, "content-type": "application/json" } }, response => {
      let body = "";
      response.on("data", chunk => { body += chunk; });
      response.on("end", () => resolve({ status: response.statusCode, body }));
    });
    outgoing.on("error", reject);
    outgoing.end(JSON.stringify({ mode }));
  });
  return { port, upstreamPort, gatewayProcess, proxy, control };
}

// The proxy's listener holds at most 12 client sockets at once (its own bound,
// unrelated to ownership), so 40 requests go in waves of 10 concurrent.
async function burst(port, count = 40) {
  const statuses = [];
  for (let sent = 0; sent < count; sent += 10) {
    const wave = await Promise.all(Array.from({ length: Math.min(10, count - sent) }, () => get(port)));
    statuses.push(...wave.map(result => result.status));
  }
  return statuses;
}

const refused = result => result.status === 503 && result.body.includes("owned fixture unavailable");

test("40 requests, 10 at a time, through the proxy all reach the proven Gateway", async () => {
  const fixture = await startFixture();
  for (let round = 0; round < 3; round++) {
    assert.deepEqual(await burst(fixture.port), Array(40).fill(200), `round ${round}`);
  }
});

test("a Gateway killed while idle is refused, and so is a foreign listener on its port", async () => {
  const fixture = await startFixture();
  assert.equal((await get(fixture.port)).status, 200);
  fixture.gatewayProcess.kill("SIGTERM");
  await once(fixture.gatewayProcess, "exit");
  assert.ok(refused(await get(fixture.port)));
  let foreignRequests = 0;
  const foreign = createServer((request, response) => { foreignRequests++; response.end("foreign"); });
  await new Promise(resolve => foreign.listen(fixture.upstreamPort, "127.0.0.1", resolve));
  try {
    for (let attempt = 0; attempt < 3; attempt++) assert.ok(refused(await get(fixture.port)));
    assert.equal(foreignRequests, 0, "the proxy forwarded to a process it never proved");
  } finally {
    await new Promise(resolve => foreign.close(resolve));
  }
});

test("a Gateway killed mid-traffic is refused from its exit on", async () => {
  const fixture = await startFixture();
  let running = true;
  const seen = [];
  const traffic = (async () => {
    while (running) seen.push(...await Promise.all(Array.from({ length: 4 }, () => get(fixture.port))));
  })();
  try {
    await until(() => seen.some(result => result.status === 200), "traffic reaching the Gateway");
    fixture.gatewayProcess.kill("SIGTERM");
    await once(fixture.gatewayProcess, "exit");
  } finally {
    running = false;
    await traffic;
  }
  for (const result of await Promise.all(Array.from({ length: 8 }, () => get(fixture.port)))) {
    assert.ok(refused(result), JSON.stringify(result));
  }
});

test("a respawned Gateway is adopted and proven before it serves", async () => {
  const fixture = await startFixture();
  const restarted = await fixture.control("restart-gateway");
  assert.equal(restarted.status, 200, restarted.body);
  const pid = JSON.parse(restarted.body).pid;
  assert.notEqual(pid, fixture.gatewayProcess.pid);
  await until(async () => (await get(fixture.port)).status === 200, "the adopted Gateway");
  assert.deepEqual(await burst(fixture.port), Array(40).fill(200));
  process.kill(pid, "SIGTERM");
  await until(async () => refused(await get(fixture.port)), "refusal of the exited respawn");
});

// The verifier with its ps/lsof runner substituted. Each call either answers from
// the process table or, when `held`, waits for the case to settle it by hand.
async function verifierCase() {
  const proxyModule = await import(pathToFileURL(join(root, "scripts", "ios-gateway-fault-proxy.mjs")).href);
  const port = 4321;
  const table = new Map();
  const calls = [];
  let held = false;
  let waiter;
  const answer = (file, args) => {
    const pid = Number(args[file.endsWith("ps") ? 1 : args.indexOf("-p") + 1]);
    const row = table.get(pid);
    if (!row) return Promise.reject(Object.assign(new Error("no such process"), { code: 1 }));
    if (file.endsWith("ps")) return Promise.resolve({ stdout: `${row[args[3].replace("=", "")]}\n` });
    return Promise.resolve({ stdout: row.listening ? `p${pid}\nn127.0.0.1:${port}\n` : "" });
  };
  const execute = (file, args) => {
    if (!held) return answer(file, args);
    return new Promise((resolve, reject) => {
      const call = { file, args, pid: Number(file.endsWith("ps") ? args[1] : args[args.indexOf("-p") + 1]),
        pass: () => answer(file, args).then(resolve, reject),
        timeOut: () => reject(Object.assign(new Error("helper timed out"), { killed: true })) };
      calls.push(call);
      waiter?.();
    });
  };
  const nextCall = () => calls.length ? Promise.resolve(calls.shift())
    : new Promise(resolve => { waiter = () => { waiter = undefined; resolve(calls.shift()); }; });
  const row = (pid, ppid, lstart) => table.set(pid, { command: `${process.execPath} ${entry}`, ppid: String(ppid), lstart, listening: true });
  return { proxyModule, port, table, row, execute, nextCall, hold: on => { held = on; } };
}

const settles = promise => Promise.race([promise.then(() => "resolved", () => "rejected"),
  new Promise(resolve => setImmediate(() => resolve("pending")))]);

test("a proven Gateway costs no helper calls per request, alone or concurrent", async () => {
  const fixture = await verifierCase();
  fixture.row(process.pid, process.ppid, "start-a");
  let helperCalls = 0;
  const verify = await fixture.proxyModule.ownedGatewayVerifier(process.pid, fixture.port,
    { execute: (...args) => { helperCalls++; return fixture.execute(...args); }, proofIntervalMs: 60_000 });
  await verify();
  const proof = helperCalls;
  assert.ok(proof > 0, "the first request proves ownership");
  for (let request = 0; request < 40; request++) await verify();
  await Promise.all(Array.from({ length: 40 }, () => verify()));
  assert.equal(helperCalls, proof, "requests after the proof must not spawn ps or lsof");
});

test("a proof that started before a respawn never proves the respawn", async () => {
  const fixture = await verifierCase();
  const sleeper = track(spawn(process.execPath, ["-e", "setTimeout(() => {}, 60000)"], { stdio: "ignore" }));
  fixture.row(process.pid, process.ppid, "start-a");
  fixture.row(sleeper.pid, process.pid, "start-b");
  const verify = await fixture.proxyModule.ownedGatewayVerifier(process.pid, fixture.port,
    { execute: fixture.execute, proofIntervalMs: 60_000 });
  fixture.hold(true);
  const stale = verify();
  // The old Gateway's identity checks pass; its listener check is still running
  // when the respawn is adopted, and then passes too.
  let call = await fixture.nextCall();
  while (!call.file.endsWith("lsof")) {
    assert.equal(call.pid, process.pid);
    call.pass();
    call = await fixture.nextCall();
  }
  fixture.hold(false);
  await verify.adopt(sleeper.pid);
  fixture.hold(true);
  call.pass();
  await stale;
  // The respawn is unproven: verifying it starts its own proof.
  const fresh = verify();
  call = await Promise.race([fixture.nextCall(), fresh.then(() => undefined)]);
  assert.ok(call, "the old Gateway's proof proved the respawn");
  assert.equal(call.pid, sleeper.pid);
  fixture.hold(false);
  call.pass();
  await fresh;
  sleeper.kill("SIGKILL");
});

test("five straight helper timeouts unprove the Gateway; a success resets the count; a reused PID is refused at once", async () => {
  const fixture = await verifierCase();
  fixture.row(process.pid, process.ppid, "start-a");
  const verify = await fixture.proxyModule.ownedGatewayVerifier(process.pid, fixture.port,
    { execute: fixture.execute, proofIntervalMs: 5 });
  await verify();
  fixture.hold(true);
  const missWatcherProofs = async count => {
    for (let miss = 0; miss < count; miss++) {
      (await fixture.nextCall()).timeOut();
      await new Promise(resolve => setImmediate(resolve));
    }
  };
  // Four misses keep the proven Gateway trusted: requests make no helper calls.
  await missWatcherProofs(4);
  assert.equal(await settles(verify()), "resolved");
  // One full watcher proof succeeds and resets the count.
  for (let step = 0; step < 3; step++) (await fixture.nextCall()).pass();
  await missWatcherProofs(4);
  assert.equal(await settles(verify()), "resolved", "a success must reset the miss count");
  // The fifth straight miss unproves it: a request now needs a full proof.
  await missWatcherProofs(1);
  const unproven = verify();
  const proof = await fixture.nextCall();
  proof.timeOut();
  await assert.rejects(unproven);
  // A real mismatch is not a timeout: a reused PID is refused on the first watcher proof.
  fixture.hold(false);
  await verify();
  fixture.table.get(process.pid).lstart = "start-reused";
  await until(async () => await settles(verify()) === "rejected", "refusal of the reused PID", 2_000);
});
