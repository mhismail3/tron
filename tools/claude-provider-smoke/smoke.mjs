#!/usr/bin/env node
// Claude subscription smoke for the pinned Pi release (scripts/tron provider-smoke): catalog, Claude Code version, Fable 5.2 and the Tron wiring tests.
//
// Offline (default) it reads the Gateway's pinned pi-ai: whether Claude Fable 5.2 is in the
// built-in catalog, Opus 5.5's thinking levels, and the Claude Code version Pi's OAuth
// requests claim (captured from one request to a local stub, never the network). It then runs
// the Gateway tests that prove Tron's wiring on Pi's built-in Anthropic OAuth. `--live` adds at
// most six short real requests with the current access token from <agent-dir>/auth.json, read
// only: the OAuth token endpoint is blocked, so the stored login is never refreshed or rotated.
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const GATEWAY = join(ROOT, "packages/gateway");
const FABLE = "claude-fable-5-2";
/** Anthropic refuses Fable 5.2 to subscription requests claiming an older Claude Code (`claude_code_version_too_old`, measured 2026-11-09). */
const FABLE_MIN_CLAUDE_CODE = "2.1.290";
const OPUS = "claude-opus-5-5";
const HAIKU = "claude-haiku-5-5";
const WIRING_TESTS = ["src/e2e/modules/home/home-anthropic-oauth-wire.integration.test.ts", "src/providers/provider-usage.integration.test.ts"];
const USAGE_URL = "https://api.anthropic.com/api/oauth/usage";

const USAGE = `Usage: scripts/tron provider-smoke [--probe-only] [--live --agent-dir <dir>] [--require-fable-5-2] [--json]
  (default)            offline probe of the pinned Pi, then the Gateway wiring tests
  --probe-only         offline probe only
  --live               also send at most six short real requests on the subscription
  --agent-dir <dir>    agent directory whose auth.json --live reads (required with --live); never written
  --require-fable-5-2  fail unless the pinned Pi serves Claude Fable 5.2
  --json               print the result as JSON`;

/** Import a pi-ai subpath through the package's own export map. */
async function piAi(subpath = ".") {
  const dir = join(GATEWAY, "node_modules/@earendil-works/pi-ai");
  const { exports } = JSON.parse(readFileSync(join(dir, "package.json"), "utf8"));
  const pattern = Object.keys(exports).find((key) => key === subpath || (key.endsWith("/*") && subpath.startsWith(key.slice(0, -1))));
  if (!pattern) throw new Error(`pi-ai does not export ${subpath}`);
  const target = exports[pattern].import.replace("*", subpath.slice(pattern.length - 1));
  return import(pathToFileURL(join(dir, target)).href);
}

export function newerOrEqual(version, minimum) {
  const a = version.split(".").map(Number), b = minimum.split(".").map(Number);
  for (let i = 0; i < Math.max(a.length, b.length); i++) if ((a[i] ?? 0) !== (b[i] ?? 0)) return (a[i] ?? 0) > (b[i] ?? 0);
  return true;
}

const user = (text) => ({ role: "user", content: [{ type: "text", text }], timestamp: Date.now() });

async function probe() {
  const [{ PI_AI_VERSION, getSupportedThinkingLevels, normalizeContext }, { getBuiltinModels }, { streamSimple }] =
    await Promise.all([piAi(), piAi("./providers/all"), piAi("./api/anthropic-messages")]);
  const models = getBuiltinModels("anthropic");
  const opus = models.find((model) => model.id === OPUS);
  let userAgent = null;
  // One OAuth-shaped request to a stub: the version Pi claims is a fact of the wire, not of Pi's source.
  await streamSimple(opus, normalizeContext({ systemPrompt: "probe", messages: [user("probe")] }), {
    apiKey: "sk-ant-oat01-provider-smoke-offline",
    fetch: async (_input, init) => { userAgent = new Headers(init?.headers).get("user-agent"); return new Response("{}", { status: 503 }); },
  }).result();
  const claudeCode = /^claude-cli\/(\d+\.\d+\.\d+)/u.exec(userAgent ?? "")?.[1] ?? null;
  const listed = models.some((model) => model.id === FABLE);
  const versionOk = claudeCode !== null && newerOrEqual(claudeCode, FABLE_MIN_CLAUDE_CODE);
  const fable = { listed, minimumClaudeCode: FABLE_MIN_CLAUDE_CODE, status: listed ? (versionOk ? "servable" : "listed-but-refused") : "absent" };
  const opusLevels = opus ? getSupportedThinkingLevels(opus) : [];
  const failures = [];
  if (!claudeCode) failures.push(`Pi's OAuth request carried no Claude Code version (user-agent ${JSON.stringify(userAgent)})`);
  if (fable.status === "listed-but-refused") failures.push(`Pi lists ${FABLE} but claims Claude Code ${claudeCode}; Anthropic refuses it below ${FABLE_MIN_CLAUDE_CODE}`);
  if (!["xhigh", "max"].every((level) => opusLevels.includes(level))) failures.push(`${OPUS} lacks xhigh/max: ${opusLevels.join(",")}`);
  return { piAi: PI_AI_VERSION, claudeCode, userAgent, fable52: fable, opusLevels, anthropicModels: models.map((model) => model.id), failures };
}

/** The current access token, read only. Refuses a token Pi would refresh during the run. */
function liveToken(agentDir) {
  const login = JSON.parse(readFileSync(join(agentDir, "auth.json"), "utf8")).anthropic;
  if (login?.type !== "oauth" || !String(login.access).startsWith("sk-ant-oat")) throw new Error(`${agentDir}/auth.json has no Anthropic OAuth login`);
  if (login.expires - Date.now() < 30 * 60_000) throw new Error("the access token expires within 30 minutes; let Tron refresh it, then retry");
  return login.access;
}

/** Every request of the live run goes through this fetch: the token endpoint is refused before any byte leaves. */
function guardedFetch(real) {
  return async (input, init) => {
    const url = String(input instanceof Request ? input.url : input);
    if (/\/oauth\/token\b/u.test(url) || /refresh_token/u.test(String(init?.body ?? ""))) throw new Error("provider-smoke never refreshes the stored login");
    return real(input, init);
  };
}

async function live(agentDir, probed) {
  const token = liveToken(agentDir);
  const fetch = guardedFetch(globalThis.fetch);
  const [{ normalizeContext }, { getBuiltinModel }, { streamSimple }] = await Promise.all([piAi(), piAi("./providers/all"), piAi("./api/anthropic-messages")]);
  const usage = async () => {
    const response = await fetch(USAGE_URL, { headers: { Authorization: `Bearer ${token}`, Accept: "application/json", "anthropic-beta": "oauth-2025-04-20", "User-Agent": `claude-code/${probed.claudeCode}` } });
    const body = response.ok ? await response.json() : null;
    return { status: response.status, weeklyPercent: body?.seven_day?.utilization ?? null, extraUsageEnabled: body?.extra_usage?.is_enabled ?? null, spendMinor: body?.spend?.used?.amount_minor ?? null };
  };
  const words = "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike".split(" ");
  const prefix = `Terse provider smoke. Reference corpus, ignore unless asked:\n${Array.from({ length: 500 }, (_, i) => `Fact ${i}: ${words[i % 13]} ${words[(i * 7) % 13]} maps to ${(i * 37) % 1000}.`).join("\n")}`;
  const bash = { name: "bash", description: "Run a shell command.", parameters: { type: "object", properties: { command: { type: "string" } }, required: ["command"] } };
  const steps = [];
  const send = async (name, modelId, context, reasoning) => {
    let headers = {};
    const result = await streamSimple(getBuiltinModel("anthropic", modelId), normalizeContext(context), {
      apiKey: token, fetch, sessionId: "provider-smoke", cacheRetention: "long", reasoning, maxTokens: 2048,
      onResponse: (response) => { headers = response.headers; },
    }).result();
    const step = { name, model: modelId, stopReason: result.stopReason, error: result.errorMessage?.slice(0, 300) ?? null,
      toolCalls: result.content.filter((block) => block.type === "toolCall").map((block) => block.name),
      cacheRead: result.usage.cacheRead, cacheWrite: result.usage.cacheWrite,
      unifiedStatus: headers["anthropic-ratelimit-unified-status"] ?? null, claim: headers["anthropic-ratelimit-unified-representative-claim"] ?? null,
      overageStatus: headers["anthropic-ratelimit-unified-overage-status"] ?? null };
    steps.push(step);
    return step;
  };
  const before = await usage();
  const tool = { systemPrompt: prefix, tools: [bash], messages: [user("Call the bash tool with command `echo ok`. Do nothing else.")] };
  const first = await send("tool", HAIKU, tool, "low");
  const repeat = await send("cache-repeat", HAIKU, tool, "low");
  const xhigh = await send("opus-xhigh", OPUS, { systemPrompt: "Answer in one word.", messages: [user("What is 2+2?")] }, "xhigh");
  const max = await send("opus-max", OPUS, { systemPrompt: "Answer in one word.", messages: [user("Capital of France?")] }, "max");
  if (probed.fable52.listed) await send("fable-5-2", FABLE, { systemPrompt: "Answer in one word.", messages: [user("Say hi.")] }, "high");
  await new Promise((done) => setTimeout(done, 10_000));
  const after = await usage();
  const failures = [];
  for (const step of steps) {
    if (step.stopReason === "error") failures.push(`${step.name}: ${step.error}`);
    else if (step.unifiedStatus !== "allowed") failures.push(`${step.name}: unified status ${step.unifiedStatus}, not billed to the plan`);
  }
  if (!first.toolCalls.includes("bash")) failures.push(`tool: expected a bash call, got ${JSON.stringify(first.toolCalls)}`);
  if (first.cacheWrite + first.cacheRead > 0 && repeat.cacheRead < 0.9 * (first.cacheWrite + first.cacheRead)) failures.push(`cache-repeat read ${repeat.cacheRead} of ${first.cacheWrite + first.cacheRead}`);
  if (first.cacheWrite + first.cacheRead === 0) failures.push("tool: the prefix was not cached");
  for (const step of [xhigh, max]) if (step.stopReason !== "stop") failures.push(`${step.name}: ${step.stopReason}`);
  if (before.status === 200 && after.status === 200 && (before.spendMinor !== after.spendMinor || after.extraUsageEnabled)) failures.push("usage: spend or extra usage changed");
  return { usageBefore: before, usageAfter: after, steps, failures };
}

function wiringTests() {
  const run = spawnSync(join(ROOT, "scripts/tron"), ["test", "gateway", ...WIRING_TESTS], { stdio: "inherit" });
  return run.status === 0 ? [] : [`Gateway wiring tests failed (scripts/tron test gateway ${WIRING_TESTS.join(" ")})`];
}

async function main(argv) {
  const flags = new Set(argv.filter((arg) => arg.startsWith("--")));
  const dirAt = argv.indexOf("--agent-dir");
  const unknown = [...flags].filter((flag) => !["--probe-only", "--live", "--agent-dir", "--require-fable-5-2", "--json", "--help"].includes(flag));
  if (flags.has("--help") || unknown.length || (dirAt >= 0 && !argv[dirAt + 1]) || (flags.has("--live") && dirAt < 0)) {
    console.error(USAGE);
    return flags.has("--help") ? 0 : 2;
  }
  const result = { probe: await probe() };
  const failures = [...result.probe.failures];
  if (flags.has("--require-fable-5-2") && result.probe.fable52.status !== "servable") failures.push(`${FABLE} is ${result.probe.fable52.status} in pi-ai ${result.probe.piAi}`);
  if (flags.has("--live")) {
    result.live = await live(resolve(argv[dirAt + 1]), result.probe);
    failures.push(...result.live.failures);
  }
  if (!flags.has("--probe-only")) failures.push(...wiringTests());
  result.failures = failures;
  if (flags.has("--json")) console.log(JSON.stringify(result, null, 2));
  else {
    const { probe: p } = result;
    console.log(`pi-ai ${p.piAi}: claims Claude Code ${p.claudeCode}; ${FABLE} ${p.fable52.status} (needs Claude Code >= ${FABLE_MIN_CLAUDE_CODE}); ${OPUS} levels ${p.opusLevels.join(",")}`);
    for (const step of result.live?.steps ?? []) console.log(`live ${step.name}: ${step.stopReason} ${step.unifiedStatus ?? "-"} ${step.claim ?? "-"} read ${step.cacheRead} write ${step.cacheWrite}`);
    if (result.live) console.log(`usage weekly ${result.live.usageBefore.weeklyPercent}% -> ${result.live.usageAfter.weeklyPercent}%`);
    console.log(failures.length ? `FAIL\n${failures.map((failure) => `- ${failure}`).join("\n")}` : "PASS");
  }
  return failures.length ? 1 : 0;
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) process.exitCode = await main(process.argv.slice(2));
