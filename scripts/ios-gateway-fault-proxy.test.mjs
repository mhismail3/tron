import assert from "node:assert/strict";
import { once } from "node:events";
import { createServer } from "node:http";
import { createRequire } from "node:module";
import test from "node:test";
import { startFaultProxyForServer } from "./ios-gateway-fault-proxy.mjs";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
const { WebSocket, WebSocketServer } = createRequire(new URL("../packages/gateway/package.json", import.meta.url))("ws");
const token = "fixture-control-token-0000000000000000";

async function bounded(promise) {
  let timer;
  try { return await Promise.race([promise, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("fixture timed out")), 3_000); })]); }
  finally { clearTimeout(timer); }
}

test("fixture rejects unowned targets before opening a proxy", async () => {
  await assert.rejects(startFaultProxyForServer({ listening: true, address: () => ({ port: 9847 }) }, { token }), /own its upstream/);
  const unbound = createServer();
  await assert.rejects(startFaultProxyForServer(unbound, { token }), /not bound/);
  await assert.rejects(promisify(execFile)(process.execPath, [fileURLToPath(new URL("./ios-gateway-fault-proxy.mjs", import.meta.url))], {
    env: { ...process.env, TRON_E2E_UPSTREAM_PORT: "9847", TRON_E2E_UPSTREAM_PID: String(process.pid), TRON_E2E_PROXY_TOKEN: token },
    timeout: 5_000,
  }), error => error.code === 1 && error.stderr.includes("owned Gateway fixture process"));
});

test("test-only proxy holds ordered boundaries and loses one accepted response", async () => {
  const upstream = createServer((_request, response) => { response.writeHead(200); response.end("owned upstream"); });
  const backend = new WebSocketServer({ server: upstream });
  const calls = [];
  backend.on("connection", socket => {
    socket.send(JSON.stringify({ type: "hello", protocolVersion: 5 }));
    socket.on("message", data => {
      const frame = JSON.parse(data.toString());
      calls.push(frame.method);
      socket.send(JSON.stringify({ type: "response", id: frame.id, ok: true, result: { accepted: true } }));
    });
  });
  await new Promise(resolve => upstream.listen(0, "127.0.0.1", resolve));
  const proxy = await startFaultProxyForServer(upstream, { token });
  let peer;
  const control = async mode => {
    const response = await fetch(`http://127.0.0.1:${proxy.port}/_fixture/control`, {
      method: "POST", headers: { "x-tron-fixture-token": token },
      body: JSON.stringify(typeof mode === "string" ? { mode } : mode), signal: AbortSignal.timeout(5_000),
    });
    assert.equal(response.status, 200);
    return response.json();
  };
  try {
    assert.equal(await (await fetch(`http://127.0.0.1:${proxy.port}/health`)).text(), "owned upstream");
    await control("hold-hello");
    peer = new WebSocket(`ws://127.0.0.1:${proxy.port}/v1/socket`);
    peer.on("error", () => {});
    const frames = [];
    peer.on("message", data => frames.push(JSON.parse(data.toString())));
    await bounded(once(peer, "open"));
    const hello = once(peer, "message");
    await control("await-intercepted");
    assert.equal(frames.length, 0);
    await control("pass");
    assert.equal(JSON.parse((await bounded(hello))[0].toString()).type, "hello");
    for (const [mode, method] of [["hold-open", "session.open"], ["hold-sync", "session.sync"]]) {
      await control(mode);
      const response = once(peer, "message");
      peer.send(JSON.stringify({ type: "request", id: method, method }));
      await control("await-intercepted");
      assert.equal(frames.some(frame => frame.id === method), false);
      await control("pass");
      assert.equal(JSON.parse((await bounded(response))[0].toString()).id, method);
    }
    let pongs = 0;
    peer.on("pong", () => pongs++);
    const pong = once(peer, "pong");
    peer.ping("live");
    await bounded(pong);
    assert.equal(pongs, 1);
    await control("blackhole");
    peer.ping("blocked");
    await control("await-intercepted");
    await control("pass");
    const marker = once(peer, "message");
    peer.send(JSON.stringify({ type: "request", id: "marker", method: "system.info" }));
    await bounded(marker); // FIFO marker follows any erroneously fabricated pong.
    assert.equal(pongs, 1);
    await control({ mode: "drop-prompt-response", commandId: "fixture-command" });
    const closed = once(peer, "close");
    peer.send(JSON.stringify({ type: "request", id: "lost", method: "session.prompt", params: { commandId: "fixture-command" } }));
    await bounded(closed);
    assert.equal(calls.filter(method => method === "session.prompt").length, 1);
    assert.equal(frames.some(frame => frame.id === "lost"), false);
    peer = new WebSocket(`ws://127.0.0.1:${proxy.port}/v1/socket`);
    peer.on("error", () => {});
    await bounded(once(peer, "message"));
    const remoteClose = once(peer, "close");
    await control({ mode: "close", code: 1013 });
    assert.equal((await bounded(remoteClose))[0], 1013);
  } finally {
    peer?.terminate();
    await proxy.close();
    for (const socket of backend.clients) socket.terminate();
    await new Promise(resolve => backend.close(resolve));
    await new Promise(resolve => upstream.close(resolve));
  }
});
