// Purpose: one-shot lock-state probe battery for the computer-use reliability plan: console state, OS capture, Cua AX observation/actions on a scratch AppKit window, CDP input/select-all/screenshot on headless and headed Chrome for Testing, and agent-browser, each checked by an independent oracle.
import { execFileSync, spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { fileURLToPath } from "node:url";
import { chromeForTesting, freePort, run, waitFor, waitForCdp } from "../../../tools/computer-bench/process.mjs";
import { startSite } from "../../../tools/computer-bench/fixtures/site.mjs";

const here = fileURLToPath(new URL(".", import.meta.url));
const label = process.argv[2] ?? "run";
const out = join(here, "results", `${label}.json`);
const work = join("/tmp", `cu-probe-${process.pid}`);
mkdirSync(work, { recursive: true });
mkdirSync(join(here, "results"), { recursive: true });
const NATIVE = join(work, "native");
execFileSync("/usr/bin/swiftc", ["-O", "-o", NATIVE, join(here, "native.swift")], { stdio: "pipe" });
const DRIVER = "/Applications/Tron.app/Contents/Library/Native/cua-driver";
const ENV = { HOME: process.env.HOME, PATH: "/usr/bin:/bin:/usr/sbin:/sbin", TMPDIR: process.env.TMPDIR ?? "/tmp", CUA_DRIVER_RS_TELEMETRY_ENABLED: "false", CUA_TELEMETRY_ENABLED: "false" };
const results = { label, startedAt: new Date().toISOString(), steps: [] };
const native = (...args) => JSON.parse(execFileSync(NATIVE, args, { encoding: "utf8" }));
const lum = (file) => (existsSync(file) ? native("lum", file) : { error: "no file" });

async function step(name, fn) {
  const started = performance.now();
  let result;
  try { result = { ok: true, ...(await Promise.race([fn(), delay(25_000).then(() => { throw new Error("step timeout 25s"); })])) }; } catch (error) { result = { ok: false, error: String(error.message ?? error).slice(0, 300) }; }
  result.ms = Math.round(performance.now() - started);
  results.steps.push({ name, ...result });
  process.stderr.write(`${name}: ${JSON.stringify(result).slice(0, 400)}\n`);
  return result;
}

function cdp(wsUrl) {
  const socket = new WebSocket(wsUrl);
  let id = 0;
  const pending = new Map();
  socket.onmessage = (event) => { const message = JSON.parse(event.data); pending.get(message.id)?.(message); pending.delete(message.id); };
  const ready = new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = () => reject(new Error("cdp socket")); });
  const send = async (method, params = {}, timeoutMs = 10_000) => {
    await ready;
    const current = ++id;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { pending.delete(current); reject(new Error(`${method} timed out ${timeoutMs}ms`)); }, timeoutMs);
      pending.set(current, (message) => { clearTimeout(timer); message.error ? reject(new Error(`${method}: ${message.error.message}`)) : resolve(message.result); });
      socket.send(JSON.stringify({ id: current, method, params }));
    });
  };
  return { send, close: () => socket.close() };
}

async function chromeBattery(name, site, mode) {
  const cft = chromeForTesting();
  const port = await freePort();
  const profile = join(work, `profile-${name}`);
  const flags = [`--user-data-dir=${profile}`, `--remote-debugging-port=${port}`, "--no-first-run", "--no-default-browser-check", "--window-size=900,700", "--window-position=520,60"];
  if (mode === "headless") flags.push("--headless=new");
  if (mode === "headed-unthrottled") flags.push("--disable-backgrounding-occluded-windows", "--disable-renderer-backgrounding", "--disable-background-timer-throttling");
  const child = spawn(cft.binary, [...flags, "about:blank"], { stdio: "ignore" });
  let client;
  try {
    await step(`${name}.launch`, async () => ({ version: (await waitForCdp(port)).Browser }));
    const target = (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()).find((entry) => entry.type === "page");
    client = cdp(target.webSocketDebuggerUrl);
    const evaluate = async (expression) => (await client.send("Runtime.evaluate", { expression, returnByValue: true })).result.value;
    await step(`${name}.navigate`, async () => {
      await client.send("Page.enable");
      await client.send("Page.navigate", { url: `${site.origin}/form.html` });
      const loaded = await waitFor(async () => (await evaluate("document.readyState")) === "complete", 8000, 100);
      return { loaded: Boolean(loaded), title: await evaluate("document.title"), visibility: await evaluate("document.visibilityState") };
    });
    await step(`${name}.click`, async () => {
      const rect = await evaluate("(() => { const r = document.querySelector('#inc').getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; })()");
      for (const type of ["mousePressed", "mouseReleased"]) await client.send("Input.dispatchMouseEvent", { type, x: rect.x, y: rect.y, button: "left", clickCount: 1 });
      const count = await waitFor(async () => (await evaluate("document.querySelector('#count').textContent")) === "1", 3000);
      return { oracle: await evaluate("document.querySelector('#count').textContent"), pass: Boolean(count) };
    });
    await step(`${name}.select-all-replace`, async () => {
      await evaluate("document.querySelector('#prefilled').focus()");
      await client.send("Input.dispatchKeyEvent", { type: "rawKeyDown", key: "a", code: "KeyA", windowsVirtualKeyCode: 65, modifiers: 4, commands: ["selectAll"] });
      await client.send("Input.dispatchKeyEvent", { type: "keyUp", key: "a", code: "KeyA", windowsVirtualKeyCode: 65, modifiers: 4 });
      await client.send("Input.insertText", { text: "new value" });
      const value = await evaluate("document.querySelector('#prefilled').value");
      return { oracle: value, pass: value === "new value" };
    });
    await step(`${name}.screenshot`, async () => {
      const shot = await client.send("Page.captureScreenshot", { format: "png" }, 10_000);
      const file = join(work, `${name}.png`);
      writeFileSync(file, Buffer.from(shot.data, "base64"));
      return lum(file);
    });
    await step(`${name}.raf`, async () => ({ framesIn1s: await client.send("Runtime.evaluate", { expression: "new Promise(r => { let n = 0; const t = performance.now(); const f = () => { n++; performance.now() - t < 1000 ? requestAnimationFrame(f) : r(n); }; requestAnimationFrame(f); setTimeout(() => r(n), 1500); })", awaitPromise: true, returnByValue: true }, 5000).then((reply) => reply.result.value) }));
  } finally {
    client?.close();
    child.kill("SIGTERM");
    await waitFor(() => child.exitCode !== null || child.signalCode !== null, 5000);
  }
}

async function cuaBattery() {
  const temp = execFileSync("/usr/bin/getconf", ["DARWIN_USER_TEMP_DIR"], { encoding: "utf8" }).trim();
  const socket = readdirSync(temp).filter((name) => name.startsWith("tron-cua-")).map((name) => join(temp, name, "s")).filter(existsSync).sort((a, b) => statSync(b).mtimeMs - statSync(a).mtimeMs)[0];
  const session = `cuprobe-${process.pid}`;
  const call = async (tool, args = {}) => {
    const result = await run(DRIVER, ["call", tool, JSON.stringify({ session, ...args }), "--socket", socket], { env: ENV, timeoutMs: 20_000 });
    if (result.timedOut) throw new Error(`${tool} timed out`);
    try { return JSON.parse(result.stdout); } catch { throw new Error(`${tool}: ${(result.stderr || result.stdout).slice(0, 200)}`); }
  };
  const statePath = join(work, "scratch-state.json");
  const binary = join(work, "scratch-window");
  execFileSync("/usr/bin/swiftc", ["-O", "-o", binary, join(here, "../../../tools/computer-bench/fixtures/scratch-window.swift")], { stdio: "pipe" });
  const scratch = spawn(binary, [statePath], { stdio: "ignore" });
  const state = () => JSON.parse(readFileSync(statePath, "utf8"));
  try {
    await waitFor(() => existsSync(statePath), 5000);
    await step("cua.start_session", async () => ({ active: (await call("start_session")).active }));
    let window;
    await step("cua.list_windows", async () => {
      const listed = await call("list_windows", { pid: scratch.pid });
      window = listed.windows?.find((entry) => entry.title?.includes("Tron Bench Scratch"));
      return { windows: listed.windows?.length, found: Boolean(window), onScreen: window?.is_on_screen };
    });
    if (!window) return;
    const observe = (extra = {}) => call("get_window_state", { pid: scratch.pid, window_id: window.window_id, max_elements: 160, max_depth: 12, include_screenshot: false, ...extra });
    const tokenFor = async (role, name) => (await observe()).elements?.find((entry) => entry.role === role && (entry.label === name || entry.title === name))?.element_token;
    await step("cua.ax-read", async () => { const snapshot = await observe(); return { status: snapshot.status, elements: snapshot.elements?.length, labels: snapshot.elements?.map((entry) => entry.label).filter(Boolean).slice(0, 8), refusal: snapshot.refusal }; });
    await step("cua.window-screenshot", async () => {
      const file = join(work, "cua-window.png");
      const output = await observe({ include_screenshot: true, include_accessibility_tree: false, screenshot_out_file: file });
      return { frameValid: output.screenshot_frame_valid, status: output.status, refusal: output.refusal, ...lum(file) };
    });
    await step("cua.click-ax", async () => {
      const output = await call("click", { pid: scratch.pid, window_id: window.window_id, element_token: await tokenFor("AXButton", "Increment") });
      await waitFor(() => state().count === 1, 2000);
      return { claim: output.effect ?? output.status, route: output.route, refusal: output.refusal ?? output.error, oracle: state().count, pass: state().count === 1 };
    });
    await step("cua.type-text", async () => {
      const output = await call("type_text", { pid: scratch.pid, window_id: window.window_id, element_token: await tokenFor("AXTextField", "Name"), text: "Ada" });
      await waitFor(() => state().name === "Ada", 2000);
      return { claim: output.effect ?? output.status, route: output.route, refusal: output.refusal ?? output.error, oracle: state().name, pass: state().name === "Ada" };
    });
    await step("cua.set-value", async () => {
      const output = await call("set_value", { pid: scratch.pid, window_id: window.window_id, element_token: await tokenFor("AXTextField", "Prefilled"), value: "new value" });
      await waitFor(() => state().prefilled === "new value", 2000);
      return { claim: output.effect ?? output.status, refusal: output.refusal ?? output.error, oracle: state().prefilled, pass: state().prefilled === "new value" };
    });
    await step("cua.hotkey-replace", async () => {
      const select = await call("hotkey", { pid: scratch.pid, window_id: window.window_id, element_token: await tokenFor("AXTextField", "Prefilled"), keys: ["cmd", "a"] });
      const type = await call("type_text", { pid: scratch.pid, window_id: window.window_id, element_token: await tokenFor("AXTextField", "Prefilled"), text: "keyed" });
      await waitFor(() => state().prefilled === "keyed", 2000);
      return { claims: [select.effect ?? select.status, type.effect ?? type.status], refusal: select.refusal ?? select.error ?? type.refusal ?? type.error, oracle: state().prefilled, pass: state().prefilled === "keyed" };
    });
    await step("cua.desktop-screenshot", async () => {
      const file = join(work, "cua-desktop.png");
      const output = await call("get_desktop_state", { screenshot_out_file: file });
      return { status: output.status, refusal: output.refusal, ...lum(file) };
    });
    await call("end_session").catch(() => {});
  } finally {
    scratch.kill("SIGTERM");
  }
}

const site = await startSite();
try {
  await step("console", async () => native("state"));
  await step("os.screencapture", async () => { const file = join(work, "screen.png"); const result = await run("/usr/sbin/screencapture", ["-x", file], { timeoutMs: 15_000 }); return { code: result.code, stderr: result.stderr.trim().slice(0, 120), ...lum(file) }; });
  await cuaBattery();
  for (const mode of ["headless", "headed", "headed-unthrottled"]) await chromeBattery(`cdp-${mode}`, site, mode);
  await step("agent-browser.headless", async () => {
    const binary = join(process.env.HOME, ".tron/agent/bin/agent-browser");
    const session = `cuprobe-${process.pid}`;
    const ab = async (...args) => { const result = await run(binary, ["--json", "--session", session, ...args], { timeoutMs: 20_000 }); return JSON.parse(result.stdout || "{}"); };
    const opened = await ab("open", `${site.origin}/form.html`);
    await ab("click", "#inc");
    const count = await ab("get", "text", "#count");
    const shotFile = join(work, "ab.png");
    await ab("screenshot", shotFile);
    await ab("close");
    return { opened: opened.success, oracle: count.data?.text, pass: count.data?.text === "1", ...lum(shotFile) };
  });
  await step("console.after", async () => native("state"));
} finally {
  results.finishedAt = new Date().toISOString();
  writeFileSync(out, `${JSON.stringify(results, null, 1)}\n`);
  await site.close();
  rmSync(work, { recursive: true, force: true });
  process.stderr.write(`wrote ${out}\n`);
}
