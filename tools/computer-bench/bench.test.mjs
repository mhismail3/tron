import { strict as assert } from "node:assert";
import { test } from "node:test";
import { FUNCTIONS, scorecard, summarize } from "./bench.mjs";
import { DOWNLOAD_BODY, startSite } from "./fixtures/site.mjs";

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
