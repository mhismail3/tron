import { strict as assert } from "node:assert";
import { test } from "node:test";
import { execFile, spawn } from "node:child_process";
import { once } from "node:events";
import { createConnection } from "node:net";
import { mkdtemp, mkdir, writeFile, readFile, readdir, realpath, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import { FUNCTIONS, scorecard, summarize } from "./bench.mjs";
import { DOWNLOAD_BODY, startSite } from "./fixtures/site.mjs";
import { agentBrowser } from "./agent-browser.mjs";
import { chromeForTesting, freePort, run, waitFor } from "./process.mjs";

test("signed-in Chrome requires explicit loopback consent and never scores endpoint existence as an attach", async () => {
  const refused = await agentBrowser().tasks["signed-in-chrome"]();
  assert.equal(refused.ok, false);
  assert.match(refused.detail, /^consent_required:/u);
  for (const chromeCdp of ["https://127.0.0.1:9222/devtools/browser", "ws://example.test:9222/devtools/browser", "ws://user:password@127.0.0.1:9222/devtools/browser", "ws://127.0.0.1:9222/devtools/browser?token=private", "ws://127.0.0.1:9222/devtools/page/target"]) {
    await assert.rejects(agentBrowser({ chromeCdp }).tasks["signed-in-chrome"](), /exact loopback browser endpoint/u);
  }
});

test("browser-use cannot score DevToolsActivePort existence as signed-in Chrome acceptance", async () => {
  const home = await mkdtemp(join(tmpdir(), "bench-chrome-probe-"));
  try {
    const profile = join(home, "Library/Application Support/Google/Chrome");
    await mkdir(profile, { recursive: true });
    await writeFile(join(profile, "DevToolsActivePort"), "9222\n/devtools/browser\n");
    const source = new URL("./browser-use.mjs", import.meta.url).href;
    const { stdout } = await promisify(execFile)(process.execPath, ["--input-type=module", "-e",
      `import { browserUse } from ${JSON.stringify(source)}; const task = browserUse().tasks['signed-in-chrome']; console.log(JSON.stringify(task ? await task() : {ok:false}));`],
      { env: { ...process.env, HOME: home } });
    assert.equal(JSON.parse(stdout).ok, false);
  } finally { await rm(home, { recursive: true, force: true }); }
});

test("the fixture site serves the consent redirect across origins, the cookie session and the download", async () => {
  const site = await startSite();
  try {
    const approve = await fetch(`${site.origin}/oauth/approve?redirect_uri=${encodeURIComponent(`${site.altOrigin}/callback`)}&state=s1`, { redirect: "manual" });
    assert.equal(approve.status, 302);
    assert.equal(approve.headers.get("location"), `${site.altOrigin}/callback?code=bench-code&state=s1`);
    const login = await fetch(`${site.origin}/login`);
    const cookie = login.headers.get("set-cookie").split(";")[0];
    assert.match(await (await fetch(`${site.origin}/whoami`, { headers: { cookie } })).text(), /user=bench-user/u);
    assert.match(await (await fetch(`${site.origin}/whoami`)).text(), /user=anonymous/u);
    const denied = await fetch(`${site.origin}${site.authPath}/fact`);
    assert.equal(denied.status, 403);
    const attachLogin = await fetch(`${site.origin}${site.authPath}/login`, { redirect: "manual" });
    const attachCookie = attachLogin.headers.get("set-cookie").split(";")[0];
    assert.equal(attachLogin.status, 302);
    assert.equal(attachLogin.headers.get("location"), `${site.authPath}/fact`);
    assert.match(attachLogin.headers.get("set-cookie"), new RegExp(`Path=${site.authPath}/;`, "u"));
    assert.equal(site.authenticatedReads(), 0);
    const fact = await fetch(`${site.origin}${site.authPath}/fact`, { headers: { cookie: attachCookie } });
    assert.equal(fact.status, 200);
    assert.match(await fact.text(), new RegExp(site.authNonce, "u"));
    assert.equal(site.authenticatedReads(), 1);
    const otherSite = await startSite();
    try {
      assert.notEqual(otherSite.authNonce, site.authNonce);
      assert.equal((await fetch(`${otherSite.origin}${otherSite.authPath}/fact`, { headers: { cookie: attachCookie } })).status, 403);
    } finally { await otherSite.close(); }
    assert.equal(await (await fetch(`${site.origin}/download/bench.txt`)).text(), DOWNLOAD_BODY);
  } finally { await site.close(); }
});

async function withChromeFixture(approval, body) {
  const root = await mkdtemp("/tmp/bc-");
  const profile = join(root, "profile"), home = join(root, "home"), sockets = join(root, "s"), calls = join(root, "calls.jsonl");
  await Promise.all([profile, home, sockets].map(path => mkdir(path)));
  await writeFile(calls, "");
  const observer = join(root, "observe-cli.mjs");
  await writeFile(observer, `#!${process.execPath}\nimport {appendFileSync} from 'node:fs'; import {spawn} from 'node:child_process'; const args=process.argv.slice(2); appendFileSync(${JSON.stringify(calls)},JSON.stringify(args[args.includes('--session')?args.indexOf('--session')+2:0])+'\\n'); const child=spawn(${JSON.stringify(process.env.COMPUTER_BENCH_AGENT_BROWSER)},args,{stdio:'inherit'}); for(const signal of ['SIGTERM','SIGINT']) process.on(signal,()=>child.kill(signal)); child.on('error',()=>process.exit(1)); child.on('exit',code=>process.exit(code??1));\n`, { mode: 0o700 });
  const port = await freePort();
  if (approval) {
    await writeFile(join(profile, "Local State"), JSON.stringify({ devtools: { remote_debugging: { "user-enabled": true } } }));
    await writeFile(join(profile, "DevToolsActivePort"), `${port}\n/devtools/browser\n`);
  }
  const chrome = spawn(chromeForTesting().binary, ["--headless=new", `--user-data-dir=${profile}`, "--no-first-run", "--no-default-browser-check", "--password-store=basic", "--use-mock-keychain", ...(approval ? ["--enable-features=DevToolsAcceptDebuggingConnections"] : [`--remote-debugging-port=${port}`]), "about:blank"], { stdio: "ignore", env: { ...process.env, HOME: home, TMPDIR: root } });
  const site = await startSite();
  try {
    assert.ok(await waitFor(() => new Promise(resolve => {
      const socket = createConnection({ host: "127.0.0.1", port });
      socket.once("connect", () => { socket.destroy(); resolve(true); });
      socket.once("error", () => resolve(false));
    }), 10_000), "isolated Chrome did not start");
    const discovery = await fetch(`http://127.0.0.1:${port}/json/version`);
    const endpoint = approval ? `ws://127.0.0.1:${port}/devtools/browser` : (await discovery.json()).webSocketDebuggerUrl;
    const env = { ...process.env, HOME: home, TMPDIR: root, AGENT_BROWSER_SOCKET_DIR: sockets, COMPUTER_BENCH_AGENT_BROWSER: observer, AGENT_BROWSER_EXECUTABLE_PATH: chromeForTesting().binary };
    const invoke = async (chromeCdp = endpoint) => {
      const source = new URL("./agent-browser.mjs", import.meta.url).href;
      const script = `import {agentBrowser} from ${JSON.stringify(source)}; const adapter=agentBrowser({chromeCdp:${JSON.stringify(chromeCdp)},reps:1}); const started=performance.now(); try {const outcome=await adapter.tasks['signed-in-chrome'](${JSON.stringify({ site: { origin: site.origin, authPath: site.authPath, authNonce: site.authNonce }, rep: 0 })}); console.log(JSON.stringify({...outcome,ms:Math.round(performance.now()-started)}));} catch(error) {console.log(JSON.stringify({detail:error.message,code:error.code,name:error.name,ms:Math.round(performance.now()-started)}));}`;
      const result = await run(process.execPath, ["--input-type=module", "-e", script], { env, timeoutMs: 40_000 });
      assert.equal(result.timedOut, false, "attach attempt did not settle");
      assert.equal(result.code, 0, result.stderr);
      const outcome = JSON.parse(result.stdout);
      console.log(JSON.stringify({ scope: "throwaway headless Chrome; real CLI passthrough; prompt visibility not observed", approval, ...outcome }));
      return outcome;
    };
    const report = async () => {
      const output = join(root, "report.json");
      const result = await run(process.execPath, [fileURLToPath(new URL("./bench.mjs", import.meta.url)), "--tools", "agent-browser", "--only", "signed-in-chrome", "--reps", "1", "--chrome-cdp", endpoint, "--json", output], { env, timeoutMs: 40_000 });
      assert.equal(result.code, 0, result.stderr);
      const report = JSON.parse(await readFile(output, "utf8"));
      assert.equal(report.tools[0].probe.ok, true, JSON.stringify(report.tools[0].probe));
      console.log(JSON.stringify({ scope: "public benchmark runner; isolated headless fixtures", engine: report.tools[0].probe.version, row: report.tools[0].tasks["signed-in-chrome"][0] }));
      return report.tools[0].tasks["signed-in-chrome"][0];
    };
    await body({ chrome, site, endpoint, status: discovery.status, invoke, report, calls: async () => (await readFile(calls, "utf8")).split("\n").filter(Boolean).map(JSON.parse) });
  } finally {
    if (chrome.exitCode === null) { const exited = once(chrome, "exit"); chrome.kill("SIGTERM"); await exited; }
    const settled = await waitFor(async () => !(await readdir(sockets)).some(name => name.endsWith(".pid")), 3_000);
    try {
      if (!settled) {
        const canonical = await realpath(sockets);
        for (const name of await readdir(sockets)) {
          if (!name.endsWith(".pid")) continue;
          const pid = Number(await readFile(join(sockets, name), "utf8").catch(() => ""));
          if (!Number.isSafeInteger(pid) || pid <= 1) continue;
          const ownsSocket = async () => {
            try {
              const { stdout } = await promisify(execFile)("/usr/sbin/lsof", ["-n", "-a", "-p", String(pid), "-U", "-Fn"]);
              return stdout.split("\n").some(line => line.startsWith(`n${sockets}/`) || line.startsWith(`n${canonical}/`));
            } catch { return false; }
          };
          for (const signal of ["SIGTERM", "SIGKILL"]) {
            if (!await ownsSocket()) break;
            try { process.kill(pid, signal); } catch (error) { if (error.code !== "ESRCH") throw error; }
            await waitFor(() => { try { process.kill(pid, 0); return false; } catch (error) { return error.code === "ESRCH"; } }, 2_000);
          }
        }
      }
    } finally { await site.close(); }
    if (settled) await rm(root, { recursive: true, force: true });
    assert.ok(settled, `fixture attachment daemon did not exit; preserved ${root}`);
  }
}

const chromeIntegration = { skip: !process.env.COMPUTER_BENCH_AGENT_BROWSER ? "COMPUTER_BENCH_AGENT_BROWSER must declare the qualified engine" : !chromeForTesting() ? "Chrome for Testing is not installed; tests do not download it" : false, timeout: 60_000 };

test("pending Chrome connection approval fails fast with an owner-consent error", chromeIntegration, () => withChromeFixture(true, async ({ chrome, site, status, invoke, report, calls }) => {
  assert.equal(status, 404);
  const outcome = await invoke();
  assert.match(outcome.detail, /needs owner consent/iu);
  assert.ok(outcome.ms < 5_000, `pending approval took ${outcome.ms}ms`);
  assert.equal(site.authenticatedReads(), 0);
  assert.equal(chrome.exitCode, null, "failed attach terminated the external fixture Chrome");
  assert.equal(outcome.code, "owner_consent_required");
  assert.match(outcome.detail, /owner consent required for each new connection; prompt visibility not observed/u);
  assert.deepEqual(await calls(), [], "consent refusal launched an attachment CLI");
  const row = await report();
  assert.equal(row.status, "fail");
  assert.equal(row.code, "owner_consent_required");
  assert.match(row.detail, /owner consent required for each new connection; prompt visibility not observed/u);
  assert.ok(!(await calls()).includes("connect"), "benchmark runner launched an attachment CLI");
}));

test("normal remote-debugging-port Chrome still authenticates and a non-404 root reaches the engine", chromeIntegration, () => withChromeFixture(false, async ({ chrome, site, endpoint, status, invoke, calls }) => {
  assert.equal(status, 200);
  const outcome = await invoke();
  assert.equal(outcome.ok, true, outcome.detail);
  assert.equal(site.authenticatedReads(), 1);
  assert.equal(chrome.exitCode, null, "detach terminated the external fixture Chrome");
  assert.ok((await calls()).includes("connect"));
  const root = new URL(endpoint);
  root.pathname = "/devtools/browser";
  const before = (await calls()).filter(command => command === "connect").length;
  const unsupported = await invoke(root.href);
  assert.notEqual(unsupported.code, "owner_consent_required");
  assert.match(unsupported.detail, /connect .*HTTP error: 404/u);
  assert.equal((await calls()).filter(command => command === "connect").length, before + 1);
}));

test("the scorecard counts absent tools, partial passes and first-class surface reach", () => {
  const present = { name: "agent-browser", probe: { ok: true, version: "x" }, tasks: { click: [{ status: "pass", ms: 10 }, { status: "fail", ms: 30, detail: "missed" }], navigate: [{ status: "pass", ms: 5 }] } };
  const absent = { name: "browser-use", probe: { ok: false, reason: "not installed" }, tasks: {} };
  assert.equal(summarize(present, "click").status, "flaky");
  assert.equal(summarize(present, "upload").status, "unsupported");
  assert.equal(summarize(absent, "click").status, "absent");
  assert.equal(summarize(present, "permission-prompt").status, "not-measured");
  const computer = { name: "cua", probe: { ok: true, version: "x" }, tasks: { "native-click": [{ status: "pass", ms: 10 }] } };
  const homeMarkdown = scorecard({ startedAt: "t", reps: 2, tools: [present, absent, computer], notes: [] });
  assert.match(homeMarkdown, new RegExp(`\\| home: [^|]+\\| first-class \\| none \\| first-class \\| 2/${FUNCTIONS.length} \\|`, "u"));
  assert.match(homeMarkdown, new RegExp(`\\| home-wake: [^|]+\\| none \\| none \\| none \\| 0/${FUNCTIONS.length} \\|`, "u"));
  const markdown = scorecard({ startedAt: "t", reps: 2, tools: [present, absent], notes: [] });
  assert.match(markdown, new RegExp(`\\| worker: [^|]+\\| first-class \\| none \\| 1/${FUNCTIONS.length} \\|`, "u"));
  assert.match(markdown, /\*\*agent-browser click\*\* \(flaky\): missed/u);
});
