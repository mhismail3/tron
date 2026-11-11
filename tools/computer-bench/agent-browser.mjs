// Purpose: computer-bench adapter for the agent-browser CLI (the engine behind Tron's agent_browser tool), driving its own managed Chrome for Testing.
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { DOWNLOAD_BODY } from "./fixtures/site.mjs";
import { pngSize, run, signedInChromeCdp } from "./process.mjs";

const BINARY = process.env.COMPUTER_BENCH_AGENT_BROWSER ?? join(homedir(), ".tron/agent/bin/agent-browser");

export function agentBrowser() {
  const session = `cb2476-${process.pid}`;
  const profileSession = `${session}-profile`;
  let profile;

  async function call(args, { sessionName = session, timeoutMs = 30_000, global = [] } = {}) {
    const result = await run(BINARY, ["--json", "--session", sessionName, ...global, ...args], { timeoutMs });
    let parsed;
    try { parsed = JSON.parse(result.stdout); } catch { parsed = undefined; }
    if (result.timedOut) throw new Error(`timed out: ${args.join(" ")}`);
    if (!parsed?.success) throw new Error(`${args.join(" ")}: ${(parsed?.error ?? result.stderr ?? result.stdout).slice(0, 300)}`);
    const { lifecycle, ...data } = parsed.data ?? {};
    return data;
  }
  const value = async (args, options) => { const data = await call(args, options); const found = ["text", "value", "result", "title"].find((key) => key in data); return found ? String(data[found]) : ""; };
  const openForm = (ctx) => call(["open", `${ctx.site.origin}/form.html`]);

  return {
    name: "agent-browser",
    async probe() {
      if (!existsSync(BINARY)) return { ok: false, reason: `missing ${BINARY}` };
      const result = await run(BINARY, ["--version"]);
      return { ok: result.code === 0, version: result.stdout.trim(), reason: result.stderr.trim() };
    },
    async setup(ctx) { profile = join(ctx.workdir, "agent-browser-profile"); await openForm(ctx); },
    async teardown() {
      await call(["close"]).catch(() => {});
      await call(["close"], { sessionName: profileSession }).catch(() => {});
    },
    tasks: {
      async navigate(ctx) { await openForm(ctx); const title = await value(["get", "title"]); return { ok: title === "Bench Form", detail: title }; },
      async click(ctx) { await openForm(ctx); await call(["click", "#inc"]); const count = await value(["get", "text", "#count"]); return { ok: count === "1", detail: count }; },
      async type(ctx) { await openForm(ctx); await call(["fill", "#name", "Ada Lovelace"]); const text = await value(["get", "value", "#name"]); return { ok: text === "Ada Lovelace", detail: text }; },
      async replace(ctx) {
        await openForm(ctx);
        await call(["click", "#prefilled"]); await call(["press", "Meta+a"]); await call(["keyboard", "type", "new value"]);
        const text = await value(["get", "value", "#prefilled"]);
        return { ok: text === "new value", detail: text };
      },
      async "form-controls"(ctx) {
        await openForm(ctx);
        await call(["select", "#flavor", "chocolate"]); await call(["check", "#agree"]);
        const state = await value(["eval", "document.querySelector('#flavor').value + ':' + document.querySelector('#agree').checked"]);
        return { ok: state === "chocolate:true", detail: state };
      },
      async upload(ctx) {
        await openForm(ctx); await call(["upload", "#file", ctx.uploadFile]);
        const info = await value(["get", "text", "#fileinfo"]);
        return { ok: info === ctx.uploadExpect, detail: info };
      },
      async download(ctx) {
        await openForm(ctx);
        const target = join(ctx.workdir, `ab-download-${ctx.rep}.txt`);
        await call(["download", "#dl", target]);
        const body = existsSync(target) ? readFileSync(target, "utf8") : "";
        return { ok: body === DOWNLOAD_BODY, detail: `${body.length} bytes` };
      },
      async "multi-tab"(ctx) {
        await openForm(ctx); await call(["click", "#newtab"]);
        const tabs = await call(["tab", "list"]);
        const list = Object.values(tabs).find(Array.isArray) ?? [];
        const second = list.find((tab) => String(tab.url ?? "").endsWith("/tab2.html"));
        if (!second) return { ok: false, detail: `tabs: ${JSON.stringify(list).slice(0, 200)}` };
        await call(["tab", String(second.tabId ?? second.id)]);
        const title = await value(["get", "title"]);
        const first = list.find((tab) => String(tab.url ?? "").endsWith("/form.html"));
        if (first) await call(["tab", String(first.tabId ?? first.id)]);
        await call(["tab", "close", String(second.tabId ?? second.id)]).catch(() => {});
        return { ok: title === "Bench Tab 2", detail: title };
      },
      async "js-dialog"(ctx) {
        await openForm(ctx); await call(["click", "#confirm"]); await call(["dialog", "accept"]);
        const text = await value(["get", "text", "#dialogresult"]);
        return { ok: text === "confirmed", detail: text };
      },
      async screenshot(ctx) {
        await openForm(ctx);
        const target = join(ctx.workdir, `ab-shot-${ctx.rep}.png`);
        await call(["screenshot", target]);
        const size = existsSync(target) ? pngSize(readFileSync(target)) : undefined;
        return { ok: Boolean(size && size.width > 100), detail: size ? `${size.width}x${size.height}` : "no png" };
      },
      async "ax-read"(ctx) {
        await openForm(ctx);
        const data = await call(["snapshot", "-i"]);
        const text = JSON.stringify(data);
        return { ok: text.includes("Increment") && text.includes("Prefilled"), detail: `${text.length} chars` };
      },
      async "session-reuse"(ctx) {
        const global = ["--profile", profile];
        await call(["open", `${ctx.site.origin}/login`], { sessionName: profileSession, global });
        await call(["close"], { sessionName: profileSession });
        await call(["open", `${ctx.site.origin}/whoami`], { sessionName: profileSession, global });
        const text = await value(["get", "text", "#result"], { sessionName: profileSession });
        await call(["close"], { sessionName: profileSession });
        return { ok: text === "user=bench-user", detail: text };
      },
      async "oauth-consent"(ctx) {
        const state = `s${ctx.rep}`;
        await call(["open", `${ctx.site.origin}/oauth/authorize?redirect_uri=${encodeURIComponent(`${ctx.site.altOrigin}/callback`)}&state=${state}`]);
        await call(["click", "#allow"]);
        await call(["wait", "--url", "**/callback*"]);
        const text = await value(["get", "text", "#result"]);
        return { ok: text === `code=bench-code state=${state}`, detail: text };
      },
      async "signed-in-chrome"() {
        const port = signedInChromeCdp();
        return { ok: port, detail: port ? "DevToolsActivePort present" : "signed-in Chrome exposes no CDP endpoint (DevToolsActivePort missing); --auto-connect has nothing to attach to" };
      },
    },
  };
}
