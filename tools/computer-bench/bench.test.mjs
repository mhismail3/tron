import { strict as assert } from "node:assert";
import { test } from "node:test";
import { FUNCTIONS, scorecard, summarize } from "./bench.mjs";
import { DOWNLOAD_BODY, startSite } from "./fixtures/site.mjs";
import { agentBrowser } from "./agent-browser.mjs";
import { createServer } from "node:net";
import { execFileSync } from "node:child_process";
import { mkdtemp, readFile, readdir, rm } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { run, waitFor } from "./process.mjs";

test("signed-in Chrome requires explicit loopback consent and never scores endpoint existence as an attach", async () => {
  const refused = await agentBrowser().tasks["signed-in-chrome"]();
  assert.equal(refused.ok, false);
  assert.match(refused.detail, /^consent_required:/u);
  for (const chromeCdp of ["https://127.0.0.1:9222/devtools/browser", "ws://example.test:9222/devtools/browser", "ws://user:password@127.0.0.1:9222/devtools/browser", "ws://127.0.0.1:9222/devtools/browser?token=private", "ws://127.0.0.1:9222/devtools/page/target"]) {
    await assert.rejects(agentBrowser({ chromeCdp }).tasks["signed-in-chrome"](), /exact loopback browser endpoint/u);
  }
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
    assert.equal(await (await fetch(`${site.origin}/download/bench.txt`)).text(), DOWNLOAD_BODY);
  } finally { await site.close(); }
});

test("the scorecard counts absent tools, partial passes and shell-only reach as gaps", () => {
  const present = { name: "agent-browser", probe: { ok: true, version: "x" }, tasks: { click: [{ status: "pass", ms: 10 }, { status: "fail", ms: 30, detail: "missed" }], navigate: [{ status: "pass", ms: 5 }] } };
  const absent = { name: "browser-use", probe: { ok: false, reason: "not installed" }, tasks: {} };
  assert.equal(summarize(present, "click").status, "flaky");
  assert.equal(summarize(present, "upload").status, "unsupported");
  assert.equal(summarize(absent, "click").status, "absent");
  assert.equal(summarize(present, "permission-prompt").status, "not-measured");
  const computer = { name: "cua", probe: { ok: true, version: "x" }, tasks: { "native-click": [{ status: "pass", ms: 10 }] } };
  const homeMarkdown = scorecard({ startedAt: "t", reps: 2, tools: [present, absent, computer], notes: [] });
  assert.match(homeMarkdown, new RegExp(`\\| home: [^|]+\\| shell \\| none \\| first-class \\| 1/${FUNCTIONS.length} \\|`, "u"));
  assert.match(homeMarkdown, new RegExp(`\\| home-wake: [^|]+\\| none \\| none \\| none \\| 0/${FUNCTIONS.length} \\|`, "u"));
  const markdown = scorecard({ startedAt: "t", reps: 2, tools: [present, absent], notes: [] });
  assert.match(markdown, new RegExp(`\\| worker: [^|]+\\| first-class \\| none \\| 1/${FUNCTIONS.length} \\|`, "u"));
  assert.match(markdown, /\*\*agent-browser click\*\* \(flaky\): missed/u);
});


async function failureProbe(mode, endpoint, directory) {
  const module = new URL("./agent-browser.mjs", import.meta.url).href;
  const script = `import { agentBrowser } from ${JSON.stringify(module)};
    try {
      const result = await agentBrowser({chromeCdp:process.env.BENCH_TEST_CDP}).tasks["signed-in-chrome"]({site:{origin:"http://fixture.invalid"}});
      console.log(JSON.stringify({result}));
    } catch(error) {
      console.log(JSON.stringify({message:error.message,cause:error.cause?.message,secondary:Array.from(error.errors??[]).slice(1).map(item=>item.message)}));
    }`;
  const result = await run(process.execPath, ["--input-type=module", "--eval", script], {
    env: { ...process.env, PATH: `${dirname(process.execPath)}:${process.env.PATH}`,
      COMPUTER_BENCH_AGENT_BROWSER: fileURLToPath(new URL("./fixtures/agent-browser-cli.mjs", import.meta.url)),
      COMPUTER_BENCH_FIXTURE_MODE: mode, COMPUTER_BENCH_FIXTURE_OWNER_DIRECTORY: directory,
      COMPUTER_BENCH_FIXTURE_FOREIGN_PID: String(process.pid), AGENT_BROWSER_SOCKET_DIR: directory, BENCH_TEST_CDP: endpoint },
  });
  assert.equal(result.code, 0, result.stderr);
  return JSON.parse(result.stdout);
}

async function retireFixture(directory) {
  for (const file of await readdir(directory)) {
    if (file.startsWith("fixture-") && file.endsWith(".json")) {
      const owned = JSON.parse(await readFile(join(directory, file), "utf8"));
      assert.equal(Number.isSafeInteger(owned.pid) && owned.pid > 1 && owned.pid !== process.pid, true);
      assert.equal(owned.directory === directory || owned.directory.startsWith("/tmp/cba-"), true);
      let sockets;
      try { sockets = execFileSync("/usr/sbin/lsof", ["-nP", "-a", "-p", String(owned.pid), "-U", "-Fn"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).split("\n"); }
      catch (error) { if (error.status === 1) sockets = []; else throw error; }
      if (sockets.includes(`n${owned.socket}`)) {
        try { process.kill(owned.pid, "SIGKILL"); } catch (error) { if (error.code !== "ESRCH") throw error; }
      }
      if (owned.directory !== directory) await rm(owned.directory, { recursive: true, force: true });
    }
  }
  await rm(directory, { recursive: true });
}

test("a failed consent attach preserves its primary error and retires the pending transport", async (t) => {
  const directory = await mkdtemp("/tmp/cbb-test-");
  const sockets = new Set();
  const server = createServer((socket) => {
    sockets.add(socket);
    socket.on("error", () => {});
    socket.on("close", () => sockets.delete(socket));
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  try {
    const result = await failureProbe("pending", `ws://127.0.0.1:${server.address().port}/devtools/browser`, directory);
    await t.test("primary connect failure survives cleanup", () => {
      assert.match(result.message, /^timed out: connect /u);
    });
    await t.test("the consent transport has no remaining client", async () => {
      assert.equal(await waitFor(() => sockets.size === 0), true);
    });
  } finally {
    for (const socket of sockets) socket.destroy();
    await retireFixture(directory);
    await new Promise((resolve) => server.close(resolve));
  }
});

test("a post-connect primary error retains a close failure as secondary", async () => {
  const directory = await mkdtemp("/tmp/cbb-test-");
  try {
    const result = await failureProbe("connected", "ws://127.0.0.1:9222/devtools/browser", directory);
    assert.match(result.message, /^get cdp-url: primary fixture read failed/u);
    assert.equal(result.cause, "get cdp-url: primary fixture read failed");
    assert.deepEqual(result.secondary, ["close: secondary fixture cleanup failed"]);
  } finally { await retireFixture(directory); }
});

test("attach cleanup honors a confirmed close and refuses a foreign PID receipt", async (t) => {
  for (const mode of ["success", "foreign"]) {
    await t.test(mode, async () => {
      const directory = await mkdtemp("/tmp/cbb-test-");
      try {
        const result = await failureProbe(mode, "ws://127.0.0.1:9222/devtools/browser", directory);
        if (mode === "success") assert.equal(result.result.ok, true);
        else {
          assert.match(result.message, /^get cdp-url: primary fixture read failed/u);
          assert.equal(result.secondary.some((message) => message.includes("does not own the expected attach session")), true);
        }
      } finally { await retireFixture(directory); }
    });
  }
});

test("the shipped bench reports every bounded cleanup diagnostic after long primary errors", async () => {
  const directory = await mkdtemp("/tmp/cbb-test-");
  try {
    const report = join(directory, "report.json"), markdown = join(directory, "report.md");
    const result = await run(process.execPath, [fileURLToPath(new URL("./bench.mjs", import.meta.url)), "--tools", "agent-browser", "--only", "signed-in-chrome", "--reps", "1", "--chrome-cdp", "ws://127.0.0.1:9222/devtools/browser", "--json", report, "--markdown", markdown], {
      timeoutMs: 10000,
      env: { ...process.env, COMPUTER_BENCH_AGENT_BROWSER: fileURLToPath(new URL("./fixtures/agent-browser-cli.mjs", import.meta.url)),
        COMPUTER_BENCH_FIXTURE_MODE: "long-errors", COMPUTER_BENCH_FIXTURE_OWNER_DIRECTORY: directory,
        COMPUTER_BENCH_FIXTURE_FOREIGN_PID: String(process.pid), AGENT_BROWSER_SOCKET_DIR: directory },
    });
    assert.equal(result.code, 0, result.stderr);
    const attempt = JSON.parse(await readFile(report, "utf8")).tools[0].tasks["signed-in-chrome"][0];
    assert.equal(attempt.status, "fail");
    for (const diagnostics of [attempt.detail, result.stderr, await readFile(markdown, "utf8")]) {
      assert.match(diagnostics, /primary fixture read failed/u);
      assert.match(diagnostics, /secondary fixture cleanup failed/u);
      assert.match(diagnostics, /does not own the expected attach session in \/tmp\/cba-/u);
    }
  } finally { await retireFixture(directory); }
});
