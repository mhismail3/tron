// Purpose: computer-bench adapter for the agent-browser CLI (the engine behind Tron's agent_browser tool), driving its own managed Chrome for Testing.
import { existsSync, readFileSync, realpathSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";
import { DOWNLOAD_BODY } from "./fixtures/site.mjs";
import { pngSize, run, waitFor } from "./process.mjs";

const BINARY = process.env.COMPUTER_BENCH_AGENT_BROWSER ?? join(homedir(), ".tron/agent/bin/agent-browser");

async function attachmentScope(session) {
  const directory = await mkdtemp("/tmp/cba-");
  const env = { ...process.env, AGENT_BROWSER_SOCKET_DIR: directory };
  delete env.AGENT_BROWSER_DAEMON;
  delete env.AGENT_BROWSER_NAMESPACE;
  const inspect = (command, args) => execFileSync(command, args, { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
  const identity = (pid) => {
    try { return inspect("/bin/ps", ["-p", String(pid), "-o", "lstart=,comm="]); }
    catch (error) { if (error.status === 1) return undefined; throw error; }
  };
  return {
    env,
    async retire(closed) {
      let pid;
      try { pid = Number(readFileSync(join(directory, `${session}.pid`), "utf8")); }
      catch (error) {
        if (error.code !== "ENOENT" || !closed) throw new Error(`Attach daemon retirement unconfirmed in ${directory}`, { cause: error });
      }
      if (pid !== undefined) {
        if (!Number.isSafeInteger(pid) || pid <= 1 || pid === process.pid) throw new Error(`Invalid owned attach daemon PID in ${directory}`);
        const before = identity(pid);
        if (before && closed) {
          if (!await waitFor(() => identity(pid) !== before)) throw new Error(`Closed attach daemon did not exit in ${directory}`);
        } else if (before) {
          const command = inspect("/bin/ps", ["-p", String(pid), "-o", "args="]);
          const binary = realpathSync(BINARY);
          if (!(command === binary || command.endsWith(` ${binary}`))) throw new Error(`Process does not own the expected attach session in ${directory}`);
          let sockets;
          try { sockets = inspect("/usr/sbin/lsof", ["-nP", "-a", "-p", String(pid), "-U", "-Fn"]).split("\n"); }
          catch (error) { if (error.status === 1) sockets = []; else throw error; }
          if (!sockets.includes(`n${join(directory, `${session}.sock`)}`) || identity(pid) !== before) throw new Error(`Process does not own the expected attach session in ${directory}`);
          process.kill(pid, "SIGKILL");
          if (!await waitFor(() => identity(pid) !== before)) throw new Error(`Attach daemon did not retire in ${directory}`);
        }
      }
      await rm(directory, { recursive: true });
    },
  };
}

function throwFailures(errors) {
  if (errors.length === 1) throw errors[0];
  if (errors.length > 1) throw new AggregateError(errors, `${errors[0].message}; cleanup also failed: ${errors.slice(1).map((error) => error.message).join("; ")}`, { cause: errors[0] });
}

export function agentBrowser({ chromeCdp } = {}) {
  const session = `cb2476-${process.pid}`;
  const profileSession = `${session}-profile`;
  const attachedSession = `${session}-attach`;
  let profile;

  async function call(args, { sessionName = session, timeoutMs = 30_000, global = [], env } = {}) {
    const result = await run(BINARY, ["--json", "--session", sessionName, ...global, ...args], { timeoutMs, env });
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
      async "signed-in-chrome"(ctx) {
        if (!chromeCdp) return { ok: false, detail: "consent_required: pass --chrome-cdp with the explicitly consented loopback browser endpoint; no attach attempted" };
        let endpoint;
        try { endpoint = new URL(chromeCdp); } catch { throw new Error("invalid Chrome CDP endpoint"); }
        if (endpoint.href !== chromeCdp || endpoint.protocol !== "ws:" || !["127.0.0.1", "[::1]"].includes(endpoint.hostname)
          || !endpoint.port || endpoint.username || endpoint.password || endpoint.search || endpoint.hash
          || !/^\/devtools\/browser(?:\/[a-f\d]{8}(?:-[a-f\d]{4}){3}-[a-f\d]{12})?$/iu.test(endpoint.pathname)) throw new Error("Chrome CDP endpoint must be an exact loopback browser endpoint without credentials");
        const options = { sessionName: attachedSession };
        const started = performance.now();
        let daemon, connected = false, closed = false, tab, attachMs;
        const errors = [];
        try {
          daemon = await attachmentScope(attachedSession);
          options.env = daemon.env;
          await call(["connect", chromeCdp], { ...options, timeoutMs: 2_000 });
          connected = true;
          attachMs = Math.round(performance.now() - started);
          const connection = await call(["get", "cdp-url"], options);
          if (connection.cdpUrl !== chromeCdp) throw new Error("Attached browser endpoint changed; refusing fixture operation");
          const opened = await call(["tab", "new", `${ctx.site.origin}/form.html`], options);
          tab = opened.tabId;
          if (typeof tab !== "string" || !tab.length) throw new Error("Fixture tab identity unavailable; open outcome uncertain");
          const title = await value(["get", "title"], options);
          return { ok: title === "Bench Form" && attachMs <= 2_000, attachMs, detail: `fixture title=${title}; attach=${attachMs}ms; exact fixture tab closed in finally` };
        } catch (error) { errors.push(error); }
        finally {
          if (tab) {
            try { await call(["tab", "close", tab], options); } catch (error) { errors.push(error); }
          }
          if (connected) {
            try {
              const result = await call(["close"], options);
              if (result.closed !== true) throw new Error("Attached session close was not confirmed");
              closed = true;
            } catch (error) { errors.push(error); }
          }
          if (daemon) {
            try { await daemon.retire(closed); } catch (error) { errors.push(error); }
          }
          throwFailures(errors);
        }
      },
    },
  };
}
