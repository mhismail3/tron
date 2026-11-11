// Purpose: shared process, timing, free-port, Chrome for Testing and CDP helpers for the computer-bench adapters.
import { spawn, execFileSync } from "node:child_process";
import { existsSync, readdirSync } from "node:fs";
import { createServer } from "node:net";
import { homedir } from "node:os";
import { join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";

export function run(command, args, { input, env, timeoutMs = 30_000 } = {}) {
  return new Promise((resolve) => {
    const started = performance.now();
    const child = spawn(command, args, { env: env ?? process.env, stdio: ["pipe", "pipe", "pipe"] });
    let stdout = "", stderr = "", timedOut = false;
    const timer = setTimeout(() => { timedOut = true; child.kill("SIGTERM"); setTimeout(() => child.kill("SIGKILL"), 2000).unref(); }, timeoutMs);
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("error", (error) => { stderr += String(error); });
    child.on("close", (code) => { clearTimeout(timer); resolve({ code, stdout, stderr, timedOut, ms: performance.now() - started }); });
    child.stdin.on("error", () => {});
    child.stdin.end(input ?? "");
  });
}

export function freePort() {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.on("error", reject);
    server.listen(0, "127.0.0.1", () => { const { port } = server.address(); server.close(() => resolve(port)); });
  });
}

export function chromeForTesting() {
  const root = join(homedir(), ".agent-browser/browsers");
  const versions = existsSync(root) ? readdirSync(root).filter((name) => name.startsWith("chrome-")).sort() : [];
  if (!versions.length) return undefined;
  const app = join(root, versions.at(-1), "Google Chrome for Testing.app");
  return existsSync(app) ? { app, binary: join(app, "Contents/MacOS/Google Chrome for Testing"), version: versions.at(-1) } : undefined;
}

export async function waitForCdp(port, timeoutMs = 15_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try { const response = await fetch(`http://127.0.0.1:${port}/json/version`); if (response.ok) return await response.json(); } catch {}
    await delay(150);
  }
  throw new Error(`no CDP endpoint on port ${port}`);
}

export async function cdpEvaluate(port, expression, urlPart = "") {
  const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  const target = targets.find((entry) => entry.type === "page" && entry.url.includes(urlPart));
  if (!target) throw new Error(`no page target matching ${urlPart}`);
  const socket = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = () => reject(new Error("CDP socket failed")); });
  try {
    const reply = await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("CDP evaluate timed out")), 5000);
      socket.onmessage = (event) => { const message = JSON.parse(event.data); if (message.id === 1) { clearTimeout(timer); resolve(message); } };
      socket.send(JSON.stringify({ id: 1, method: "Runtime.evaluate", params: { expression, returnByValue: true } }));
    });
    return reply.result?.result?.value;
  } finally { socket.close(); }
}

export function frontmostApp() {
  try {
    const asn = execFileSync("/usr/bin/lsappinfo", ["front"], { encoding: "utf8" }).trim();
    return /"([^"]*)"/.exec(execFileSync("/usr/bin/lsappinfo", ["info", "-only", "name", asn], { encoding: "utf8" }))?.[1] ?? asn;
  } catch { return "unknown"; }
}

export function userIdleSeconds() {
  try {
    const nanoseconds = /"HIDIdleTime" = (\d+)/.exec(execFileSync("/usr/sbin/ioreg", ["-c", "IOHIDSystem", "-d", "4"], { encoding: "utf8" }))?.[1];
    return nanoseconds ? Number(nanoseconds) / 1e9 : 0;
  } catch { return 0; }
}

export function signedInChromeCdp() {
  const file = join(homedir(), "Library/Application Support/Google/Chrome/DevToolsActivePort");
  return existsSync(file);
}

export function pngSize(buffer) {
  if (buffer.length < 24 || !buffer.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) return undefined;
  return { width: buffer.readUInt32BE(16), height: buffer.readUInt32BE(20) };
}

export async function waitFor(check, timeoutMs = 3000, interval = 100) {
  const deadline = Date.now() + timeoutMs;
  let last;
  while (Date.now() < deadline) {
    last = await check();
    if (last) return last;
    await delay(interval);
  }
  return last;
}
