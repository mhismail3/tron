import { mkdir, mkdtemp, readFile, realpath, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import {
  fauxAssistantMessage, fauxProvider, fauxThinking, fauxToolCall,
  getCurrentSystemPrompt, getCurrentTools,
  type AssistantMessage, type SimpleStreamOptions, type TranscriptContext,
} from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { TrustService } from "../admin/trust-service.js";
import { RuntimeRegistry } from "./runtime-registry.js";
import {
  clientEventTrace, compareWithGolden, eventShapePaths, hashPromptText, normalizeTraceValue,
  promptSectionHeadings, type BehaviorTrace, type ProviderRequestTrace,
} from "../../test-support/sdk-behavior-trace.js";
import { awaitsWithin, waitFor } from "../../test-support/wait-for.js";

/**
 * The SDK-boundary behavior trace (epic #468, layer L2).
 *
 * Failure mode this file owns: the pinned Pi SDK changes what Tron *emits,
 * persists or sends* — a new transcript row, a renamed tool, changed tool-result
 * text, a new or changed system-prompt section, a tool hidden from the prompt —
 * and it ships unreviewed because nothing records that behavior. The README's
 * "behavior-delta stop" was a manual instruction with no evidence behind it.
 *
 * One deterministic faux-provider scenario runs through the real Gateway
 * (`RuntimeRegistry` + `RuntimeSlot` + Pi's own codemode/tool-search/mcp
 * built-ins), and every seam an SDK upgrade can move is recorded in a normalized
 * trace compared byte-for-byte with a committed golden:
 *
 * - each provider request: declared tool names, system-prompt section headings,
 *   and a hash of the normalized prompt text;
 * - each client-facing broadcast topic, with the union of its payload structure;
 * - every canonical session JSONL entry, normalized;
 * - the transcript projection from the slot snapshot.
 *
 * The comparison's unified diff *is* the behavior-delta inventory an upgrade
 * pull request reviews hunk by hunk. Intended changes update the golden with
 * `npm run update:sdk-behavior-trace` (or `TRON_UPDATE_SDK_BEHAVIOR_TRACE=1`).
 */

const GOLDEN_PATH = resolve(process.cwd(), "test-fixtures", "pi-sdk", "sdk-behavior-trace.golden.json");
const ACTUAL_PATH = resolve(process.cwd(), "test-results", "sdk-behavior-trace.actual.json");
const LOADED_ACTUAL_PATH = resolve(process.cwd(), "test-results", "sdk-behavior-trace.load.actual.json");

/** A 1x1 PNG, so the codemode `image()` output is a real, fixed image payload. */
const IMAGE_DATA_URL =
  "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==";

/**
 * The codemode script the scenario runs: `image()`, a nested tool call,
 * `models.classify()` and a codemode-exposed MCP call. `text()` is a statement
 * that appends output rather than a value, so the script reads tool results
 * through its own `asText`.
 */
const CODEMODE_SCRIPT = [
  "const lines = [];",
  "const asText = (result) => { if (typeof result === 'string') return result; if (!result || !Array.isArray(result.content)) return ''; return result.content.map((block) => (block && block.type === 'text' ? block.text : '')).join(''); };",
  `image({ image_url: ${JSON.stringify(IMAGE_DATA_URL)} });`,
  'lines.push("nested=" + asText(await tools.read({ path: "notes.txt" })).trim());',
  'const model = await models.getModelOfType("classifier", "typesafe", "jev-latest");',
  'let classified = "classify-unavailable";',
  "try {",
  '  const answer = await models.classify(model, { state: { text: "boundary state" }, questions: { relevant: { type: "bool", instructions: "Is this relevant?" } } });',
  "  classified = JSON.stringify(answer);",
  '} catch (error) { classified = "classify-unavailable"; }',
  'let scripted = "scripted-mcp-unavailable";',
  // Pi exposes a codemode tool under its JavaScript-safe identifier, which is
  // how the scripted MCP server (a hyphenated name) is reachable from a script.
  'try { scripted = asText(await tools.mcp__tron_script__echo({ value: "scripted" })); } catch (error) { scripted = "scripted-mcp-unavailable"; }',
  'lines.push("classified=" + classified);',
  'lines.push("scripted=" + scripted);',
  'return lines.join(" | ");',
].join("\n");

/**
 * A hang bound for the abort step, not a speed budget: the abort signal is the
 * contract, and this only keeps a broken one from turning into a test timeout.
 */
const ABORT_STEP_FALLBACK_MS = 8_000;

const registries: RuntimeRegistry[] = [];
const roots: string[] = [];
const fixtureProcessIds = new Set<number>();
afterEach(async () => {
  await Promise.all(registries.splice(0).map((registry) => registry.dispose().catch(() => {})));
  // Kill before removing the roots: a fixture that outlived its Gateway would
  // otherwise keep watching a deleted state file.
  for (const pid of fixtureProcessIds) {
    try { process.kill(pid, "SIGKILL"); } catch { /* Already gone. */ }
  }
  fixtureProcessIds.clear();
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

/**
 * Bounded in-process CPU load: two chains of 4 ms bursts keep roughly one and a
 * half cores busy for the scenario. Deliberately modest — the Gateway suite runs
 * four workers on a Mac shared with other agents, and an event-loop-stall owner
 * (`session-search-stall.test.ts`) measures the host this test also runs on.
 */
function startInProcessLoad(): () => void {
  let running = true;
  const burst = (): void => {
    if (!running) return;
    const until = performance.now() + 4;
    while (performance.now() < until) { /* Spin: the load is the point. */ }
    setTimeout(burst, 0);
  };
  for (let chain = 0; chain < 2; chain += 1) setTimeout(burst, 0);
  return () => { running = false; };
}

interface ScenarioOptions {
  readonly load: boolean;
}

/**
 * One deterministic run of the whole boundary scenario. The caller owns nothing:
 * every process, directory and env mutation is released before this resolves.
 */
async function runBoundaryScenario(options: ScenarioOptions): Promise<BehaviorTrace> {
  const root = await mkdtemp(join(tmpdir(), "tron-sdk-behavior-trace-"));
  roots.push(root);
  const agentDir = join(root, "agent");
  const sessionDir = join(root, "sessions");
  const cwd = join(root, "workspace");
  await Promise.all([mkdir(agentDir, { recursive: true }), mkdir(sessionDir, { recursive: true }), mkdir(cwd, { recursive: true })]);
  // The Gateway reports `cwd` through its realpath; both spellings must normalize
  // to the same placeholder or the prompt hash differs per host.
  const normalization = { roots: [root, await realpath(root)] };

  const fixture = resolve(process.cwd(), "test-fixtures", "pi-sdk", "mcp-jsonrpc-fixture.mjs");
  const fixtureTools = [{
    name: "echo",
    description: "Echo the boundary fixture value",
    inputSchema: { type: "object", properties: { value: { type: "string" } }, required: ["value"] },
  }];
  const servers: Record<string, unknown> = {};
  // Exactly one server is reachable only through tool search. Two would make the
  // order of the loaded tools depend on which MCP server finished connecting
  // first — a host race, not SDK behavior — and the trace compares order too.
  for (const [name, exposure] of [["tron-fixture", "direct"], ["tron-script", "codemode"]] as const) {
    const statePath = join(root, `${name}.state.json`);
    const pidPath = join(root, `${name}.pid`);
    await writeFile(statePath, JSON.stringify({ tools: fixtureTools }));
    servers[name] = { command: process.execPath, args: [fixture, "stdio", statePath, pidPath], exposure };
  }

  await Promise.all([
    writeFile(join(cwd, "notes.txt"), "boundary notes\n"),
    writeFile(join(agentDir, "settings.json"), JSON.stringify({
      sessionDir,
      // Pi's built-ins are registered by `RuntimeSlot`; these make codemode and
      // tool search active so the scenario reaches them without MCP exposure.
      defaultTools: ["+codemode", "+tool-search"],
      // Automatic compaction off, and a small retained tail so the scenario's
      // explicit `compact()` has a real cut point: the summary request and the
      // compaction entry's recorded prompt/tool state are part of the trace.
      compaction: { enabled: false, reserveTokens: 2_048, keepRecentTokens: 300 },
    })),
    writeFile(join(agentDir, "mcp.json"), JSON.stringify({ mcpServers: servers })),
  ]);

  const priorAgentDir = process.env.PI_CODING_AGENT_DIR;
  process.env.PI_CODING_AGENT_DIR = agentDir;
  const trust = new TrustService(agentDir);
  await trust.set(cwd, true);

  const providerRequests: ProviderRequestTrace[] = [];
  const recordRequest = (context: TranscriptContext): void => {
    const prompt = getCurrentSystemPrompt(context.messages);
    providerRequests.push({
      tools: getCurrentTools(context.messages).map((tool) => tool.name),
      promptSections: promptSectionHeadings(prompt),
      promptHash: hashPromptText(prompt, normalization),
    });
  };

  const faux = fauxProvider({ provider: "tron-sdk-behavior-trace", tokensPerSecond: 10_000, tokenSize: { min: 4, max: 4 } });
  const steps: Array<(context: TranscriptContext, options: SimpleStreamOptions | undefined) => AssistantMessage | Promise<AssistantMessage>> = [];

  // Turn 1, step 1: streamed thinking and text plus a direct tool and codemode.
  steps.push((context) => {
    recordRequest(context);
    return fauxAssistantMessage([
      fauxThinking("Reading the boundary fixture before scripting it."),
      { type: "text", text: "Tracing the SDK boundary." },
      fauxToolCall("read", { path: "notes.txt" }, { id: "trace-read" }),
      fauxToolCall("codemode", { code: CODEMODE_SCRIPT }, { id: "trace-codemode" }),
    ], { stopReason: "toolUse" });
  });
  // Turn 1, step 2: a direct MCP tool and a tool search for the tool the
  // codemode exposure keeps out of the declared list.
  steps.push((context) => {
    recordRequest(context);
    return fauxAssistantMessage([
      fauxToolCall("mcp__tron-fixture__echo", { value: "direct" }, { id: "trace-mcp-direct" }),
      fauxToolCall("tool_search", { query: "Echo the boundary fixture value" }, { id: "trace-tool-search" }),
    ], { stopReason: "toolUse" });
  });
  // Turn 1, step 3: the tool search result made the codemode-exposed MCP tool
  // callable directly as well.
  steps.push((context) => {
    recordRequest(context);
    return fauxAssistantMessage([fauxToolCall("mcp__tron-script__echo", { value: "direct-after-search" }, { id: "trace-mcp-loaded" })], { stopReason: "toolUse" });
  });
  steps.push((context) => {
    recordRequest(context);
    return fauxAssistantMessage("Boundary fixture traced.");
  });

  // Turn 2: hold the provider request open so a steer and a follow-up are
  // admitted into the live run, exactly as a client does while it streams.
  let releaseSteer = (): void => {};
  const steerGate = new Promise<void>((resolve) => { releaseSteer = resolve; });
  let steerRequestStarted = (): void => {};
  const steerStarted = new Promise<void>((resolve) => { steerRequestStarted = resolve; });
  steps.push(async (context) => {
    recordRequest(context);
    steerRequestStarted();
    await steerGate;
    return fauxAssistantMessage([fauxToolCall("read", { path: "notes.txt" }, { id: "trace-steer-read" })], { stopReason: "toolUse" });
  });
  steps.push((context) => {
    recordRequest(context);
    return fauxAssistantMessage("Steered work acknowledged.");
  });
  steps.push((context) => {
    recordRequest(context);
    return fauxAssistantMessage("Follow-up work acknowledged.");
  });

  // Turn 3: an aborted turn. The step settles when its request is aborted; the
  // bounded fallback only turns a broken abort into a trace delta (the turn then
  // completes instead of being recorded as aborted) rather than a test timeout.
  let abortRequestStarted = (): void => {};
  const abortStarted = new Promise<void>((resolve) => { abortRequestStarted = resolve; });
  steps.push(async (context, requestOptions) => {
    recordRequest(context);
    abortRequestStarted();
    await new Promise<void>((resolve) => {
      const signal = requestOptions?.signal;
      if (!signal || signal.aborted) { resolve(); return; }
      const expiry = setTimeout(resolve, ABORT_STEP_FALLBACK_MS);
      signal.addEventListener("abort", () => { clearTimeout(expiry); resolve(); }, { once: true });
    });
    return fauxAssistantMessage("Aborted turn response.");
  });

  // A repeated tail: an unscripted request is itself a delta, and it must be
  // recorded rather than crashing the run. Every tail step is identical, so a
  // request the scenario did not script cannot desynchronize the ones after it.
  const fallback = (context: TranscriptContext): AssistantMessage => {
    recordRequest(context);
    return fauxAssistantMessage("Unscripted boundary response.");
  };
  for (let extra = 0; extra < 8; extra += 1) steps.push(fallback);
  faux.setResponses(steps);

  const clientEvents: Array<{ topic: string; paths: readonly string[] }> = [];
  const modelRuntimeFactory = async (): Promise<ModelRuntime> => {
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    await runtime.setRuntimeApiKey("typesafe", "synthetic-typesafe-key");
    return runtime;
  };
  const registry = new RuntimeRegistry({
    agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, modelRuntimeFactory, trust,
    broadcast: (_sessionId, topic, payload) => { clientEvents.push({ topic, paths: eventShapePaths(topic, payload) }); },
    sessionSummaryChanged: () => {}, sessionListChanged: () => {},
  });
  registries.push(registry);

  const originalFetch = globalThis.fetch;
  const stopLoad = options.load ? startInProcessLoad() : () => {};
  globalThis.fetch = (async () => new Response(JSON.stringify({
    model: "jev-latest",
    answers: { relevant: { type: "noul", noul: 0.91 } },
    usage: { input_tokens: 128, output_tokens: 8 },
  }), { status: 200, headers: { "content-type": "application/json" } })) as typeof fetch;

  try {
    await registry.initialize();
    const slot = await registry.create(cwd);
    // A subscriber is what makes the Gateway publish snapshots and streaming
    // progress at all; the trace records the topics a real client receives.
    registry.subscribe("trace-client", slot.id);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    // The faux model names tools unconditionally, unlike a real model whose
    // catalog arrives at dispatch. Join MCP registration before those calls —
    // by server, not by the exact tool name, because that name is one of the
    // facts this trace compares (Pi 1.0 maps `-` to `_` in it).
    const session = (slot as unknown as { runtime: { session: { getAllTools(): Array<{ name: string }> } } }).runtime.session;
    const registered = (server: string): boolean => session.getAllTools().some((tool) =>
      tool.name.startsWith("mcp__") && tool.name.includes(server) && tool.name.endsWith("__echo"));
    await waitFor(() => ["fixture", "script"].every(registered), "the fixture MCP tools to register");

    await slot.prompt("trace the Pi SDK boundary");
    await waitFor(() => !slot.isBusy, "the traced turn to settle");

    const steering = slot.prompt("hold a turn open for a steer");
    await awaitsWithin(steerStarted, "the steerable provider request");
    await slot.prompt("steer the boundary", [], "steer");
    await slot.prompt("then follow up", [], "followUp");
    releaseSteer();
    await steering;
    await waitFor(() => !slot.isBusy, "the steered and follow-up turns to settle");

    const aborting = slot.prompt("abort this turn");
    await awaitsWithin(abortStarted, "the abortable provider request");
    const operationId = slot.snapshot().operation?.id;
    expect(operationId).toBeDefined();
    await slot.abort("agent", operationId);
    await aborting;
    await waitFor(() => !slot.isBusy, "the aborted turn to settle");

    await slot.compact();
    await waitFor(() => !slot.isBusy, "the compacted session to settle");

    const canonical = (await readFile(slot.sessionFile!, "utf8")).trimEnd().split("\n")
      .map((line) => normalizeTraceValue(JSON.parse(line), normalization));
    const transcript = slot.snapshot().transcript.map((item) => normalizeTraceValue(item, normalization));
    return {
      scenario: "pi-sdk-boundary",
      providerRequests,
      clientEvents: clientEventTrace(clientEvents),
      canonicalJsonl: canonical,
      transcript,
    };
  } finally {
    stopLoad();
    globalThis.fetch = originalFetch;
    await registry.dispose().catch(() => {});
    const index = registries.indexOf(registry);
    if (index >= 0) registries.splice(index, 1);
    if (priorAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
    else process.env.PI_CODING_AGENT_DIR = priorAgentDir;
    for (const name of ["tron-fixture", "tron-script"]) {
      const pidPath = join(root, `${name}.pid`);
      const pid = await readFile(pidPath, "utf8").then((text) => Number(text)).catch(() => Number.NaN);
      if (Number.isInteger(pid)) fixtureProcessIds.add(pid);
    }
  }
}

/** A trace that recorded nothing would make every golden comparison vacuous. */
function expectSubstantialTrace(trace: BehaviorTrace): void {
  expect(trace.providerRequests.length).toBeGreaterThanOrEqual(8);
  expect(trace.canonicalJsonl.length).toBeGreaterThan(5);
  expect(trace.transcript.length).toBeGreaterThan(5);
  expect(trace.clientEvents.map((event) => event.topic)).toContain("session.snapshot");
  expect(trace.providerRequests.some((request) => request.promptSections.includes("tools"))).toBe(true);
}

describe("Pi SDK boundary behavior trace", () => {
  it("matches the committed golden for one deterministic scenario through the real Gateway", async () => {
    const trace = await runBoundaryScenario({ load: false });
    expectSubstantialTrace(trace);
    await compareWithGolden({ goldenPath: GOLDEN_PATH, actualPath: ACTUAL_PATH, trace });
  });

  it("produces the same trace while the test process is under load", async () => {
    // Failure mode: the trace records timing- or ordering-dependent SDK
    // behavior, so a busy host produces a different "delta" than an idle one and
    // the golden stops being evidence. No wait in this file is a speed budget;
    // the load is bounded and confined to this process.
    const trace = await runBoundaryScenario({ load: true });
    expectSubstantialTrace(trace);
    await compareWithGolden({ goldenPath: GOLDEN_PATH, actualPath: LOADED_ACTUAL_PATH, trace });
  });
});
