import { strict as assert } from "node:assert";
import { test } from "node:test";
import { execFile } from "node:child_process";
import { mkdtemp, mkdir, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { FUNCTIONS, scorecard, summarize } from "./bench.mjs";
import { DOWNLOAD_BODY, startSite } from "./fixtures/site.mjs";
import { agentBrowser } from "./agent-browser.mjs";

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
    const denied = await fetch(`${site.origin}/attach/fact`);
    assert.equal(denied.status, 403);
    const attachLogin = await fetch(`${site.origin}/attach/login`, { redirect: "manual" });
    const attachCookie = attachLogin.headers.get("set-cookie").split(";")[0];
    assert.equal(attachLogin.status, 302);
    assert.equal(attachLogin.headers.get("location"), "/attach/fact");
    assert.equal(site.authenticatedReads(), 0);
    const fact = await fetch(`${site.origin}/attach/fact`, { headers: { cookie: attachCookie } });
    assert.equal(fact.status, 200);
    assert.match(await fact.text(), new RegExp(site.authNonce, "u"));
    assert.equal(site.authenticatedReads(), 1);
    const otherSite = await startSite();
    try {
      assert.notEqual(otherSite.authNonce, site.authNonce);
      assert.equal((await fetch(`${otherSite.origin}/attach/fact`, { headers: { cookie: attachCookie } })).status, 403);
    } finally { await otherSite.close(); }
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
