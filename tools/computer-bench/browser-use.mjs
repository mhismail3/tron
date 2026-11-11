// Purpose: computer-bench adapter for browser-use 1.0's browser-harness CLI from an existing venv, against its own headless Chrome for Testing; telemetry off, state under the run directory.
import { spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { DOWNLOAD_BODY } from "./fixtures/site.mjs";
import { chromeForTesting, freePort, pngSize, run, signedInChromeCdp, waitForCdp } from "./process.mjs";

const VENV = process.env.COMPUTER_BENCH_BROWSER_USE_VENV ?? join(homedir(), "Workspace/browser-use-eval-20261110/.venv");
const MARK = "BENCH_RESULT ";

export function browserUse() {
  let chrome, port, env, profile;

  async function startChrome() {
    const cft = chromeForTesting();
    chrome = spawn(cft.binary, ["--headless=new", `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`, "--no-first-run",
      "--no-default-browser-check", "--window-size=1280,900", "about:blank"], { stdio: "ignore" });
    await waitForCdp(port);
  }
  async function stopChrome() {
    if (!chrome || chrome.exitCode !== null) return;
    const exited = new Promise((resolve) => chrome.once("exit", resolve));
    chrome.kill("SIGTERM");
    await Promise.race([exited, delay(5000)]);
    if (chrome.exitCode === null) chrome.kill("SIGKILL");
  }
  async function py(code, timeoutMs = 30_000) {
    const result = await run(join(VENV, "bin/browser-use"), [], { input: `import json\n${code}\n`, env, timeoutMs });
    if (result.timedOut) throw new Error("browser-use call timed out");
    const line = result.stdout.split("\n").find((entry) => entry.startsWith(MARK));
    if (!line) throw new Error(`no result (rc ${result.code}): ${(result.stderr || result.stdout).trim().split("\n").slice(-3).join(" | ").slice(0, 300)}`);
    return JSON.parse(line.slice(MARK.length));
  }
  const emit = (expression) => `print(${JSON.stringify(MARK)} + json.dumps(${expression}))`;
  const open = (ctx, path = "/form.html") => `ensure_real_tab()\ngoto_url(${JSON.stringify(ctx.site.origin + path)})\nwait_for_load()`;
  const center = (selector) => `_r = js("(() => { const r = document.querySelector(${JSON.stringify(selector).replaceAll('"', "'")}).getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; })()")\nclick_at_xy(_r[0], _r[1])`;

  return {
    name: "browser-use",
    async probe() {
      if (!existsSync(join(VENV, "bin/browser-use"))) return { ok: false, reason: `not installed (no ${VENV})` };
      if (!chromeForTesting()) return { ok: false, reason: "no Chrome for Testing under ~/.agent-browser/browsers" };
      const version = await run(join(VENV, "bin/python"), ["-c", "import importlib.metadata as m; print(m.version('browser-use'), m.version('browser-harness'))"]);
      return { ok: version.code === 0, version: `browser-use ${version.stdout.trim().replace(" ", ", browser-harness ")}` };
    },
    async setup(ctx) {
      port = await freePort();
      profile = join(ctx.workdir, "browser-use-profile");
      const home = join(ctx.workdir, "browser-use-home");
      mkdirSync(home, { recursive: true });
      env = { PATH: `${join(VENV, "bin")}:/usr/bin:/bin`, HOME: homedir(), TMPDIR: process.env.TMPDIR ?? "/tmp", BH_HOME: home, BH_TELEMETRY: "0", ANONYMIZED_TELEMETRY: "false",
        BH_UPDATE_CHECK: "0", BU_CDP_URL: `http://127.0.0.1:${port}`, BH_TAB_MARKER: "0", BH_DOMAIN_SKILLS: "0" };
      await startChrome();
    },
    async teardown() { await run(join(VENV, "bin/browser-use"), ["--reload"], { env, timeoutMs: 10_000 }).catch(() => {}); await stopChrome(); },
    tasks: {
      async navigate(ctx) { const title = await py(`${open(ctx)}\n${emit("page_info()['title']")}`); return { ok: title === "Bench Form", detail: title }; },
      async click(ctx) { const count = await py(`${open(ctx)}\n${center("#inc")}\n${emit("js(\"document.querySelector('#count').textContent\")")}`); return { ok: count === "1", detail: count }; },
      async type(ctx) { const text = await py(`${open(ctx)}\nfill_input('#name', 'Ada Lovelace')\n${emit("js(\"document.querySelector('#name').value\")")}`); return { ok: text === "Ada Lovelace", detail: text }; },
      async replace(ctx) {
        const text = await py(`${open(ctx)}\n${center("#prefilled")}\npress_key('a', 4)\ntype_text('new value')\n${emit("js(\"document.querySelector('#prefilled').value\")")}`);
        return { ok: text === "new value", detail: text };
      },
      async "form-controls"(ctx) {
        const state = await py(`${open(ctx)}\njs("(() => { const s = document.querySelector('#flavor'); s.value = 'chocolate'; s.dispatchEvent(new Event('change', {bubbles: true})); })()")\n${center("#agree")}\n${emit("js(\"document.querySelector('#flavor').value + ':' + document.querySelector('#agree').checked\")")}`);
        return { ok: state === "chocolate:true", detail: `${state} (select via page JS: no select helper)` };
      },
      async upload(ctx) { const info = await py(`${open(ctx)}\nupload_file('#file', ${JSON.stringify(ctx.uploadFile)})\n${emit("js(\"document.querySelector('#fileinfo').textContent\")")}`); return { ok: info === ctx.uploadExpect, detail: info }; },
      async download(ctx) {
        const directory = join(ctx.workdir, `bu-download-${ctx.rep}`);
        mkdirSync(directory, { recursive: true });
        await py(`${open(ctx)}\ncdp('Browser.setDownloadBehavior', behavior='allow', downloadPath=${JSON.stringify(directory)})\n${center("#dl")}\nimport os, time\nfor _ in range(50):\n    if os.path.exists(${JSON.stringify(join(directory, "bench.txt"))}): break\n    time.sleep(0.1)\n${emit("True")}`);
        const file = join(directory, "bench.txt");
        const body = existsSync(file) ? readFileSync(file, "utf8") : "";
        return { ok: body === DOWNLOAD_BODY, detail: `${body.length} bytes (raw CDP Browser.setDownloadBehavior: no download helper)` };
      },
      async "multi-tab"(ctx) {
        const title = await py(`${open(ctx)}\n${center("#newtab")}\nimport time\n_t = None\nfor _ in range(30):\n    _t = next((t for t in list_tabs(False) if t['url'].endswith('/tab2.html')), None)\n    if _t: break\n    time.sleep(0.1)\n_first = current_tab()\nswitch_tab(_t)\nwait_for_load()\n_title = page_info()['title']\nclose_tab(_t)\nswitch_tab(_first)\n${emit("_title")}`);
        return { ok: title === "Bench Tab 2", detail: title };
      },
      async "js-dialog"(ctx) {
        const text = await py(`${open(ctx)}\njs("setTimeout(() => document.querySelector('#confirm').click(), 0)")\nimport time\ntime.sleep(0.3)\n_d = page_info()\nif 'dialog' in _d: cdp('Page.handleJavaScriptDialog', accept=True)\n${emit("js(\"document.querySelector('#dialogresult').textContent\")")}`);
        return { ok: text === "confirmed", detail: `${text} (needs raw Page.handleJavaScriptDialog: a direct click blocks the IPC)` };
      },
      async screenshot(ctx) {
        const target = join(ctx.workdir, `bu-shot-${ctx.rep}.png`);
        await py(`${open(ctx)}\ncapture_screenshot(${JSON.stringify(target)})\n${emit("True")}`);
        const size = existsSync(target) ? pngSize(readFileSync(target)) : undefined;
        return { ok: Boolean(size && size.width > 100), detail: size ? `${size.width}x${size.height}` : "no png" };
      },
      async "ax-read"(ctx) {
        const nodes = await py(`${open(ctx)}\n_ax = cdp('Accessibility.getFullAXTree')\n${emit("[n.get('name', {}).get('value') for n in _ax['nodes'] if n.get('name', {}).get('value')]")}`);
        return { ok: nodes.includes("Increment") && nodes.includes("Prefilled"), detail: `${nodes.length} named nodes (raw CDP Accessibility.getFullAXTree: no snapshot helper)` };
      },
      async "session-reuse"(ctx) {
        await py(`${open(ctx, "/login")}\n${emit("True")}`);
        await stopChrome();
        await startChrome();
        await run(join(VENV, "bin/browser-use"), ["--reload"], { env, timeoutMs: 10_000 });
        const text = await py(`${open(ctx, "/whoami")}\n${emit("js(\"document.querySelector('#result').textContent\")")}`);
        return { ok: text === "user=bench-user", detail: text };
      },
      async "oauth-consent"(ctx) {
        const state = `s${ctx.rep}`;
        const path = `/oauth/authorize?redirect_uri=${encodeURIComponent(`${ctx.site.altOrigin}/callback`)}&state=${state}`;
        const text = await py(`${open(ctx, path)}\n${center("#allow")}\nimport time\nfor _ in range(50):\n    if '/callback' in page_info().get('url', ''): break\n    time.sleep(0.1)\nwait_for_load()\n${emit("js(\"document.querySelector('#result').textContent\")")}`);
        return { ok: text === `code=bench-code state=${state}`, detail: text };
      },
      async "signed-in-chrome"() {
        const present = signedInChromeCdp();
        return { ok: present, detail: present ? "DevToolsActivePort present" : "signed-in Chrome exposes no CDP endpoint (DevToolsActivePort missing)" };
      },
    },
  };
}
