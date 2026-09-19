import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtemp, mkdir, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createRequire } from "node:module";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { parseArguments } from "./tron-ios-device-bind.mjs";

const require = createRequire(new URL("../packages/gateway/package.json", import.meta.url));
const { WebSocketServer } = require("ws");
const targetIdentifier = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE";

test("binding options require exact identities and local-only destinations", () => {
  assert.equal(parseArguments(["--list"]).host, "tailscale");
  assert.equal(parseArguments(["--list", "--channel", "dev"]).port, 9848);
  for (const args of [[], ["--list", "--host", "example.com"], ["--list", "--tron-home"],
    ["--list", "--port", "0"], ["--list", "--list"], ["--device-id", "phone"],
    ["--list", "--device-id", "phone"], ["--list", "--channel", "other"]]) {
    assert.throws(() => parseArguments(args));
  }
  assert.equal(parseArguments(["--device-id", "phone", "--target-identifier", targetIdentifier]).deviceId, "phone");
});

test("CLI authenticates locally, lists paired IDs, and sends one explicit binding without leaking credentials", async () => {
  const home = await mkdtemp(join(tmpdir(), "tron-device-binding-test-"));
  const server = new WebSocketServer({ host: "127.0.0.1", port: 0 });
  await once(server, "listening");
  const token = "fixture-local-token-not-a-secret-00000000";
  const calls = [];
  server.on("connection", (ws, request) => {
    assert.equal(request.headers.authorization, `Bearer ${token}`);
    ws.on("message", (raw) => {
      const frame = JSON.parse(raw.toString());
      if (frame.type === "hello") {
        ws.send(JSON.stringify({ type: "hello", protocolVersion: 5, minProtocolVersion: 5 }));
      } else {
        calls.push(frame);
        ws.send(JSON.stringify({ type: "response", id: frame.id, ok: true, result:
          frame.method === "device.list" ? { devices: [{ id: "phone", name: "Fixture Phone" }] }
            : { deviceId: "phone", target: { name: "Fixture Phone" } },
        }));
      }
    });
  });
  try {
    await mkdir(join(home, "gateway"));
    await writeFile(join(home, "gateway", "local-auth.json"), JSON.stringify({
      version: 2, purpose: "local-wrapper-health", bearerToken: token, lastUpdated: "2026-09-01T00:00:00Z",
    }), { mode: 0o600 });
    for (const args of [["--list"], ["--device-id", "phone", "--target-identifier", targetIdentifier]]) {
      const child = spawn(process.execPath, ["scripts/tron-ios-device-bind.mjs", ...args,
        "--tron-home", home, "--host", "127.0.0.1", "--port", String(server.address().port)],
      { cwd: new URL("..", import.meta.url), stdio: ["ignore", "pipe", "pipe"] });
      let output = "";
      child.stdout.on("data", (data) => { output += data; });
      child.stderr.on("data", (data) => { output += data; });
      const timer = setTimeout(() => child.kill("SIGKILL"), 10_000);
      const [code] = await once(child, "close");
      clearTimeout(timer);
      assert.equal(code, 0, output);
      assert.ok(!output.includes(token));
      assert.ok(!output.includes(targetIdentifier));
      assert.match(output, args[0] === "--list" ? /"deviceId":"phone"/ : /Bound the selected/);
    }
    assert.deepEqual(calls.map((call) => call.method), ["device.list", "device.install.target.bind"]);
    assert.equal(calls[1].params.deviceId, "phone");
    assert.equal(calls[1].params.targetIdentifier, targetIdentifier);
    assert.match(calls[1].params.commandId, /^ios-bind-/);
  } finally {
    for (const socket of server.clients) socket.terminate();
    await new Promise((resolve) => server.close(resolve));
    await rm(home, { recursive: true, force: true });
  }
});
