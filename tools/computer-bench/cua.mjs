// Purpose: computer-bench adapter for Tron's embedded Cua driver over the Native Host socket, using only the operations Tron's computer tool admits, against a scratch AppKit window and a background Chrome for Testing window.
import { execFileSync, spawn } from "node:child_process";
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { fileURLToPath } from "node:url";
import { cdpEvaluate, chromeForTesting, freePort, frontmostApp, pngSize, run, userIdleSeconds, waitFor, waitForCdp } from "./process.mjs";

const DRIVER = process.env.COMPUTER_BENCH_CUA_DRIVER ?? "/Applications/Tron.app/Contents/Library/Native/cua-driver";
const SCRATCH_SOURCE = fileURLToPath(new URL("./fixtures/scratch-window.swift", import.meta.url));
const IDLE_SECONDS = 120;
const ENV = { HOME: process.env.HOME, PATH: "/usr/bin:/bin:/usr/sbin:/sbin", TMPDIR: process.env.TMPDIR ?? "/tmp", CUA_DRIVER_RS_TELEMETRY_ENABLED: "false", CUA_TELEMETRY_ENABLED: "false" };

function driverSocket() {
  const temp = execFileSync("/usr/bin/getconf", ["DARWIN_USER_TEMP_DIR"], { encoding: "utf8" }).trim();
  const sockets = readdirSync(temp).filter((name) => name.startsWith("tron-cua-")).map((name) => join(temp, name, "s")).filter(existsSync);
  return sockets.sort((a, b) => statSync(b).mtimeMs - statSync(a).mtimeMs)[0];
}

export function cua(options) {
  const session = `cb2476-${process.pid}`;
  let socket, scratch, statePath, chrome;

  async function call(tool, args = {}) {
    const result = await run(DRIVER, ["call", tool, JSON.stringify({ session, ...args }), "--socket", socket], { env: ENV, timeoutMs: 30_000 });
    if (result.timedOut) throw new Error(`${tool} timed out`);
    let output;
    try { output = JSON.parse(result.stdout); } catch { throw new Error(`${tool}: ${(result.stderr || result.stdout).slice(0, 300)}`); }
    if (output.status === "refused" || output.refusal) throw new Error(`${tool} refused: ${JSON.stringify(output.refusal ?? output).slice(0, 300)}`);
    return output;
  }
  const effect = (output) => output.effect ?? output.status ?? "unknown";
  const state = () => JSON.parse(readFileSync(statePath, "utf8"));

  async function windowFor(pid, title) {
    const found = await waitFor(async () => (await call("list_windows", { pid })).windows.find((entry) => entry.is_on_screen && entry.title.includes(title)), 10_000, 200);
    if (!found) throw new Error(`no window "${title}" for pid ${pid}`);
    return found.window_id;
  }
  async function observe(target, extra = {}) {
    return call("get_window_state", { pid: target.pid, window_id: target.window, include_screenshot: false, max_elements: 160, max_depth: 12, ...extra });
  }
  async function token(target, role, label) {
    const snapshot = await observe(target, target === chrome?.target ? { query: label } : {});
    const element = snapshot.elements.find((entry) => entry.role === role && (entry.label === label || entry.title === label || entry.description === label));
    if (!element) throw new Error(`no ${role} "${label}" in ${snapshot.elements.length} elements`);
    return element.element_token;
  }
  async function act(tool, target, args) {
    const before = frontmostApp();
    const output = await call(tool, { pid: target.pid, window_id: target.window, ...args });
    const after = frontmostApp();
    return { claim: effect(output), stoleFocus: !args.delivery_mode && before !== after, output };
  }
  const native = () => scratch.target;
  const page = () => chrome.target;
  const pageValue = (expression) => cdpEvaluate(chrome.port, expression, "/form.html");
  const report = (ok, detail, steps) => ({ ok, detail: `${detail}; claims ${steps.map((step) => step.claim).join(",")}`, stoleFocus: steps.some((step) => step.stoleFocus) });

  async function startScratch(ctx) {
    statePath = join(ctx.workdir, `scratch-state-${Date.now()}.json`);
    const binary = join(ctx.workdir, "scratch-window");
    if (!existsSync(binary)) execFileSync("/usr/bin/swiftc", ["-O", "-o", binary, SCRATCH_SOURCE], { stdio: "pipe" });
    const process_ = spawn(binary, [statePath], { stdio: "ignore" });
    await waitFor(() => existsSync(statePath), 5000);
    scratch = { process: process_, target: { pid: process_.pid, window: await windowFor(process_.pid, "Tron Bench Scratch") } };
  }
  async function stopScratch() {
    if (!scratch) return;
    scratch.process.kill("SIGTERM");
    await new Promise((resolve) => scratch.process.exitCode !== null ? resolve() : scratch.process.once("exit", resolve));
    scratch = undefined;
  }
  async function startChrome(ctx) {
    const cft = chromeForTesting();
    const port = await freePort();
    const profile = join(ctx.workdir, "cua-chrome-profile");
    const before = frontmostApp();
    execFileSync("/usr/bin/open", ["-g", "-n", "-a", cft.app, "--args", `--user-data-dir=${profile}`, `--remote-debugging-port=${port}`, "--no-first-run",
      "--no-default-browser-check", "--window-size=900,700", "--window-position=520,60", `${ctx.site.origin}/form.html`]);
    await waitForCdp(port);
    const pid = await waitFor(() => {
      try {
        return execFileSync("/bin/ps", ["-axo", "pid=,command="], { encoding: "utf8" }).split("\n")
          .map((line) => line.trim()).find((line) => line.includes(`--user-data-dir=${profile}`) && !line.includes("--type="))?.split(" ")[0];
      } catch { return undefined; }
    }, 5000);
    chrome = { port, pid: Number(pid), launchStoleFocus: before !== frontmostApp() };
    chrome.target = { pid: chrome.pid, window: await windowFor(chrome.pid, "Bench Form") };
    const warm = performance.now();
    const first = await observe(chrome.target);
    const visible = async () => (await observe(chrome.target)).elements.some((entry) => entry.label === "Increment");
    const ready = first.elements.some((entry) => entry.label === "Increment") || await waitFor(visible, 30_000, 3000);
    ctx.notes.push(`cua: Chromium's web accessibility tree ${ready ? `appeared ${Math.round(performance.now() - warm)}ms after the first window read (Tron's 160/12 default; reads 3s apart)` : "did not appear within 30s of reads 3s apart"}; the first read held only browser chrome and menus (${first.elements.length} elements)`);
  }
  async function stopChrome() {
    if (!chrome?.pid) return;
    try { process.kill(chrome.pid, "SIGTERM"); } catch {}
    await waitFor(() => { try { process.kill(chrome.pid, 0); return false; } catch { return true; } }, 5000);
    chrome = undefined;
  }
  async function resetPage() {
    await pageValue("location.reload()").catch(() => {});
    await waitFor(async () => (await pageValue("document.readyState").catch(() => "")) === "complete", 5000);
  }

  return {
    name: "cua",
    async probe() {
      if (!existsSync(DRIVER)) return { ok: false, reason: `missing ${DRIVER}` };
      socket = driverSocket();
      if (!socket) return { ok: false, reason: "no Tron Native Host Cua socket (tron-cua-*/s) in the user temp directory" };
      const version = (await run(DRIVER, ["--version"], { env: ENV })).stdout.trim();
      try {
        const started = await call("start_session");
        return started.active ? { ok: true, version } : { ok: false, reason: "start_session not active" };
      } catch (error) { return { ok: false, reason: String(error.message ?? error) }; }
    },
    async setup(ctx) { await startScratch(ctx); if (chromeForTesting()) await startChrome(ctx); ctx.notes.push(`cua: Chrome for Testing launched with open -g; launch ${chrome?.launchStoleFocus ? "changed" : "kept"} the frontmost app`); },
    async teardown() { await stopScratch(); await stopChrome(); await call("end_session").catch(() => {}); },
    async beforeRep(ctx) { await stopScratch(); await startScratch(ctx); if (chrome) await resetPage(); },
    tasks: {
      async "native-read"() {
        const snapshot = await observe(native());
        const labels = snapshot.elements.map((entry) => entry.label);
        return { ok: ["Name", "Prefilled", "Flavor", "Increment"].every((label) => labels.includes(label)), detail: `${snapshot.elements.length} elements, ${JSON.stringify(snapshot).length} bytes` };
      },
      async "native-click"() {
        const step = await act("click", native(), { element_token: await token(native(), "AXButton", "Increment") });
        const count = await waitFor(() => state().count === 1, 2000);
        return report(Boolean(count), `count ${state().count}`, [step]);
      },
      async "native-type"() {
        const step = await act("type_text", native(), { element_token: await token(native(), "AXTextField", "Name"), text: "Ada Lovelace" });
        await waitFor(() => state().name === "Ada Lovelace", 2000);
        return report(state().name === "Ada Lovelace", `name "${state().name}"`, [step]);
      },
      async "native-replace"() {
        const select = await act("hotkey", native(), { element_token: await token(native(), "AXTextField", "Prefilled"), keys: ["cmd", "a"] }).catch((error) => ({ claim: `error ${error.message.slice(0, 80)}` }));
        const type = await act("type_text", native(), { element_token: await token(native(), "AXTextField", "Prefilled"), text: "new value" });
        await waitFor(() => state().prefilled === "new value", 2000);
        return report(state().prefilled === "new value", `prefilled "${state().prefilled}"`, [select, type]);
      },
      async "native-select"() {
        const step = await act("set_value", native(), { element_token: await token(native(), "AXPopUpButton", "Flavor"), value: "Chocolate" });
        await waitFor(() => state().flavor === "Chocolate", 2000);
        return report(state().flavor === "Chocolate", `flavor ${state().flavor}`, [step]);
      },
      async "native-modal"() {
        const open = await act("click", native(), { element_token: await token(native(), "AXButton", "Show Alert") });
        await waitFor(() => state().alertOpen, 2000);
        const approve = await act("click", native(), { element_token: await token(native(), "AXButton", "Approve") });
        await waitFor(() => state().approved, 2000);
        return report(state().approved, `approved ${state().approved}`, [open, approve]);
      },
      async screenshot(ctx) {
        const file = join(ctx.workdir, `cua-window-${ctx.rep}.png`);
        const output = await call("get_window_state", { pid: page().pid, window_id: page().window, include_accessibility_tree: false, screenshot_out_file: file });
        const size = existsSync(file) ? pngSize(readFileSync(file)) : undefined;
        return { ok: Boolean(size && output.screenshot_frame_valid !== false), detail: size ? `${size.width}x${size.height}` : "no png" };
      },
      async "desktop-screenshot"(ctx) {
        const file = join(ctx.workdir, `cua-desktop-${ctx.rep}.png`);
        await call("get_desktop_state", { screenshot_out_file: file });
        const size = existsSync(file) ? pngSize(readFileSync(file)) : undefined;
        return { ok: Boolean(size), detail: size ? `${size.width}x${size.height}` : "no png" };
      },
      async "ax-read"() {
        const snapshot = await observe(page(), { max_elements: 200, max_depth: 16 });
        const labels = snapshot.elements.map((entry) => entry.label);
        const ok = labels.includes("Increment") && labels.includes("Prefilled");
        return { ok, detail: `${snapshot.elements.length} elements, ${JSON.stringify(snapshot).length} bytes at Tron's 200-element/16-depth cap${ok ? "" : "; page controls cut off by browser chrome and menu bar"}` };
      },
      async click() {
        const step = await act("click", page(), { element_token: await token(page(), "AXButton", "Increment") });
        const count = await waitFor(async () => (await pageValue("document.querySelector('#count').textContent")) === "1", 2000);
        return report(Boolean(count), `count ${await pageValue("document.querySelector('#count').textContent")}`, [step]);
      },
      async type() {
        const step = await act("type_text", page(), { element_token: await token(page(), "AXTextField", "Name"), text: "Ada Lovelace" });
        await waitFor(async () => (await pageValue("document.querySelector('#name').value")) === "Ada Lovelace", 2000);
        const value = await pageValue("document.querySelector('#name').value");
        return report(value === "Ada Lovelace", `value "${value}"`, [step]);
      },
      async replace() {
        const select = await act("hotkey", page(), { element_token: await token(page(), "AXTextField", "Prefilled"), keys: ["cmd", "a"] }).catch((error) => ({ claim: `error ${error.message.slice(0, 80)}` }));
        const type = await act("type_text", page(), { element_token: await token(page(), "AXTextField", "Prefilled"), text: "new value" });
        await waitFor(async () => (await pageValue("document.querySelector('#prefilled').value")) === "new value", 2000);
        const value = await pageValue("document.querySelector('#prefilled').value");
        return report(value === "new value", `value "${value}"`, [select, type]);
      },
      async "foreground-delivery"() {
        const idle = userIdleSeconds();
        if (!options.foreground || idle < IDLE_SECONDS) return { status: "needs-idle", detail: `foreground input moves focus; runs only with --foreground after ${IDLE_SECONDS}s without user input (idle ${Math.round(idle)}s)` };
        await call("get_desktop_state", { include_screenshot: false }).catch(() => call("get_desktop_state", {}));
        const before = frontmostApp();
        const select = await act("hotkey", page(), { element_token: await token(page(), "AXTextField", "Prefilled"), keys: ["cmd", "a"], delivery_mode: "foreground" });
        const type = await act("type_text", page(), { element_token: await token(page(), "AXTextField", "Prefilled"), text: "fg value", delivery_mode: "foreground" });
        await delay(300);
        const value = await pageValue("document.querySelector('#prefilled').value");
        const restored = frontmostApp() === before;
        return report(value === "fg value" && restored, `value "${value}", frontmost ${restored ? "restored" : `changed to ${frontmostApp()}`}`, [select, type]);
      },
    },
  };
}
