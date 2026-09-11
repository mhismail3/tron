import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { once } from "node:events";
import { Worker } from "node:worker_threads";
import { setImmediate as turn } from "node:timers/promises";
import { performance } from "node:perf_hooks";
import test from "node:test";

// This suite MUST load the separately compiled test-only transport artifact.
// Production State/slots/TSFNs/Node buffers/cleanup execute unchanged. No XPC,
// host, grant, inventory, capture or canonical session is reachable here.
const path = process.env.TRON_CAPTURE_TEST_ADDON;
assert.ok(path?.endsWith("/tron-native-capture-test.node"));
const nativeAddon = createRequire(import.meta.url)(path);
assert.equal(typeof nativeAddon.testStats, "function");
assert.equal(nativeAddon.apiVersion, 4);
// Promises belong to JavaScript; this thin adapter retains native synchronous
// argument rejection for the raw-API tests, but owns no native lifecycle.
function completion(action) {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  action((error, value) => error ? reject(error) : resolve(value));
  return promise;
}
const addon = {
  testStats: () => nativeAddon.testStats(),
  testDeliverDelayed: () => nativeAddon.testDeliverDelayed(),
  open(...args) {
    const raw = nativeAddon.open(...args);
    return {
      request: (data) => completion((done) => raw.request(data, done)),
      closeLocal: () => completion((done) => raw.closeLocal(done)),
      testReply: (...args) => raw.testReply(...args),
      testLose: () => raw.testLose(), testFault: (point) => raw.testFault(point),
    };
  },
};
const control = (operation) => Buffer.from(JSON.stringify({ operation }));
const result = Buffer.from('{"version":1,"status":"fixture"}');
async function until(predicate, label) {
  const deadline = performance.now() + 1500;
  do {
    if (predicate()) return;
    await turn();
  } while (performance.now() < deadline);
  assert.fail(`${label}: ${JSON.stringify(addon.testStats())}`);
}
async function retired() {
  await until(() => {
    const stats = addon.testStats();
    return stats.queues === 0 && stats.hooks === 0 && stats.payloads === 0 && stats.references === 0;
  }, "local addon resources survived deadline");
}
async function deliverDelayed() {
  const before = addon.testStats().delayed;
  addon.testDeliverDelayed();
  await until(() => addon.testStats().delayed === before + 1, "native delayed callback did not complete");
}

test("import is inert; explicit open is per-env and bounded", { timeout: 3000 }, async () => {
  assert.deepEqual(addon.testStats(), { owners: 0, payloads: 0, hooks: 0, queues: 0, references: 0, delayed: 0 });
  const clients = Array.from({ length: 4 }, () => addon.open());
  const client = clients[0];
  assert.throws(() => addon.open(), /connection capacity exhausted/);
  const promise = client.request(control("pull"));
  const rejected = assert.rejects(promise, /closed locally/);
  assert.throws(() => client.request(control("pull")), /one native capture pull/);
  assert.throws(() => client.request(Buffer.alloc(65537)), /bounds/);
  assert.throws(() => client.request(control("input")), /invalid capture operation/);
  await Promise.all(clients.map((client) => client.closeLocal()));
  await rejected;
  await retired();
});

test("automation endpoint bootstrap uses the ordinary native request lane", { timeout: 3000 }, async () => {
  const client = addon.open();
  const pending = client.request(control("automationEndpoint"));
  client.testReply(0, result, null, false);
  assert.deepEqual(await pending, { control: result, jpeg: null });
  await client.closeLocal(); await retired();
});

test("actual buffer copies settle once; delayed duplicate cannot settle a reused slot", { timeout: 3000 }, async () => {
  const client = addon.open();
  const first = client.request(control("pull"));
  const pixels = Buffer.from([1, 2, 3]);
  client.testReply(0, result, pixels, false);
  client.testReply(0, result, pixels, false); // exact duplicate callback
  const reply = await first;
  assert.deepEqual(reply.control, result);
  assert.deepEqual(reply.jpeg, pixels);
  pixels.fill(9);
  assert.deepEqual(reply.jpeg, Buffer.from([1, 2, 3]));
  // Save the old transport callback in the delayed native edge, then reuse slot.
  client.testReply(0, result, null, true);
  const second = client.request(control("catalog"));
  let settled = false;
  void second.then(() => { settled = true; });
  await deliverDelayed();
  assert.equal(settled, false);
  client.testReply(0, result, null, false);
  await second;
  await client.closeLocal();
  await retired();
});

for (const operation of ["stop", "suspend"]) test(`ordinary saturation reserves independent ${operation} and terminal capacity`, { timeout: 3000 }, async () => {
  const client = addon.open();
  const ordinary = Array.from({ length: 4 }, () => client.request(control("catalog")));
  assert.throws(() => client.request(control("hello")), /capacity exhausted/);
  const stop = client.request(control(operation));
  assert.throws(() => client.request(control(operation)), /capacity exhausted/);
  for (let slot = 0; slot < 4; slot++) client.testReply(slot, result, null, false);
  client.testReply(4, result, null, false);
  const replies = await Promise.all([...ordinary, stop]);
  assert.equal(replies.length, 5);
  await client.closeLocal();
  await retired();
});

test("actual napi_queue_full rejects accepted requests without a side backlog", { timeout: 3000 }, async () => {
  const client = addon.open(99); // actual ordinary TSFN max_queue_size=1
  const ordinary = Array.from({ length: 4 }, () => client.request(control("catalog")));
  const stop = client.request(control("stop"));
  const rejected = [...ordinary, stop].map((promise) => assert.rejects(promise, /transport lost/));
  // The Node loop cannot drain between these synchronous native enqueues.
  client.testReply(0, result, null, false);
  client.testReply(1, result, null, false);
  client.testReply(4, result, null, false);
  await Promise.all(rejected);
  await client.closeLocal();
  await retired();
});

test("oversized native replies and peer loss close admission; Stop is not forged", { timeout: 3000 }, async () => {
  for (const kind of ["control", "jpeg", "lost"]) {
    const client = addon.open();
    const pending = client.request(control("pull"));
    const rejected = assert.rejects(pending, /remote retirement unconfirmed/);
    if (kind === "lost") client.testLose();
    else client.testReply(0, kind === "control" ? Buffer.alloc(65537) : result,
      kind === "jpeg" ? Buffer.alloc(2 * 1024 * 1024 + 1) : null, false);
    await rejected;
    assert.throws(() => client.request(control("stop")), /closed/);
    await client.closeLocal();
    await retired();
  }
});

test("partial initialization unwinds each acquired TSFN/hook/transport", { timeout: 3000 }, async () => {
  for (let fault = 1; fault <= 5; fault++) {
    assert.throws(() => addon.open(fault), /test initialization failure/);
    await retired();
    const successor = addon.open();
    await successor.closeLocal();
    await retired();
  }
});


test("actual result allocation failure notifies every pending callback and retires", { timeout: 3000 }, async () => {
  const client = addon.open();
  const pending = [client.request(control("catalog")), client.request(control("stop"))];
  const refused = pending.map((promise) => assert.rejects(promise, /client failed/));
  client.testFault(1);
  client.testReply(0, result, null, false);
  await Promise.all(refused);
  await client.closeLocal();
  await retired();
});

test("native-thread reply allocation failure still signals terminal cleanup", { timeout: 3000 }, async () => {
  const client = addon.open();
  const pending = [client.request(control("catalog")), client.request(control("stop"))];
  const refused = pending.map((promise) => assert.rejects(promise, /client failed/));
  client.testReply(0, result, null, true);
  client.testFault(2);
  await deliverDelayed(); // real GCD callback must return, not unwind/terminate
  await Promise.all(refused);
  await client.closeLocal();
  await retired();
});

test("rejection preparation failure cannot skip native retirement", { timeout: 3000 }, async () => {
  const client = addon.open();
  const pending = client.request(control("catalog"));
  const refused = assert.rejects(pending, /client failed/);
  client.testFault(3);
  await assert.rejects(client.closeLocal(), /client failed/);
  await refused;
  await retired();
  assert.throws(() => client.request(control("stop")), /closed/);
});

test("interruption closes admission before Node drains the terminal queue", { timeout: 3000 }, async () => {
  const client = addon.open();
  const pending = client.request(control("catalog"));
  const refused = assert.rejects(pending, /transport lost/);
  client.testLose();
  assert.throws(() => client.request(control("start")), /closed/);
  client.testReply(0, result, null, false); // late reply cannot revive connection
  await refused;
  await client.closeLocal();
  await retired();
});

test("throwing rejection still notifies later accepted callbacks", { timeout: 3000 }, async () => {
  const raw = nativeAddon.open();
  let first = 0, later = 0, closed = false;
  raw.request(control("catalog"), () => { first++; throw Error("rejection boom"); });
  raw.request(control("catalog"), (error) => { assert.ok(error); later++; });
  assert.throws(() => raw.closeLocal(() => { closed = true; }), /rejection boom/);
  await until(() => closed, "close did not retire after throwing rejection");
  assert.equal(first, 1);
  assert.equal(later, 1);
  await retired();
});

async function collectOwners() {
  assert.equal(typeof global.gc, "function", "run the offline suite with --expose-gc");
  await until(() => {
    global.gc();
    return addon.testStats().owners === 0;
  }, "native State survived JS/TSFN retirement");
}
async function workerCase(mode) {
  await collectOwners();
  const worker = new Worker(`
    const { parentPort, workerData } = require('node:worker_threads');
    const addon = require(workerData.path);
    const client = addon.open();
    const control = Buffer.from('{"operation":"pull"}');
    client.request(control, () => { if (workerData.mode === 'natural-exit') parentPort.close(); });
    client.testReply(0, Buffer.from('{"fixture":true}'), null, true);
    if (workerData.mode === 'terminal-exit') {
      client.testLose();
      process.exit(0);
    } else if (workerData.mode === 'close-exit') {
      client.closeLocal(() => {});
      process.exit(0);
    } else if (workerData.mode === 'queued-exit') {
      client.testReply(0, Buffer.from('{"fixture":true}'), Buffer.alloc(1024), false);
      process.exit(0);
    } else if (workerData.mode === 'natural-exit') {
      client.testReply(0, Buffer.from('{"fixture":true}'), null, false);
    } else {
      parentPort.postMessage('pending');
      parentPort.on('message', () => {});
    }
  `, { eval: true, workerData: { path, mode } });
  const signal = AbortSignal.timeout(2000);
  const exit = once(worker, "exit", { signal });
  try {
    if (mode === "terminate") {
      await once(worker, "message", { signal });
      await worker.terminate();
    }
    await exit;
  } finally { await worker.terminate(); }
  await retired();
  assert.equal(addon.testStats().owners, 0);
  // Deliberately late weak callback after worker/env resources are gone.
  await deliverDelayed();
  await retired();
  assert.equal(addon.testStats().owners, 0);
}
for (const mode of ["terminate", "queued-exit", "natural-exit", "close-exit", "terminal-exit"]) {
  test(`actual Node env cleanup: ${mode}, including late native callbacks`, { timeout: 3000 }, async () => {
    await workerCase(mode);
    // A new owner in this environment must not inherit the retired worker.
    const successor = addon.open();
    await successor.closeLocal();
    await retired();
  });
}

// Actual JS callback errors are observable, but native references still retire.
test("throwing completion is not retried and native references retire", { timeout: 3000 }, async () => {
  const worker = new Worker(`
    const { workerData } = require('node:worker_threads');
    const addon = require(workerData.path);
    const client = addon.open();
    client.request(Buffer.from('{"operation":"catalog"}'), () => { throw Error('completion failed'); });
    client.request(Buffer.from('{"operation":"stop"}'), () => {});
    client.testReply(0, Buffer.from('{"fixture":true}'), null, false);
    // This keeps the worker alive until the actual TSFN callback runs.
    require('node:worker_threads').parentPort.on('message', () => {});
  `, { eval: true, workerData: { path } });
  const signal = AbortSignal.timeout(2000);
  const failure = once(worker, "error", { signal });
  // Separate exit listener: events.once(exit) rejects on the expected error.
  const exit = new Promise((resolve) => worker.once("exit", resolve));
  try {
    const [error] = await failure;
    assert.match(error.message, /completion failed/);
    assert.notEqual(await exit, 0);
  } finally { await worker.terminate(); }
  await retired();
});
