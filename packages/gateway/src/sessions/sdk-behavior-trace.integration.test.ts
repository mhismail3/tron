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
  clientEventTrace, collapseRepeatedRequests, compareWithGolden, eventShapePaths, hashPromptText,
  normalizeTraceValue, promptSectionHeadings,
  type BehaviorTrace, type ProviderRequestTrace, type TraceValue,
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
 * - each distinct provider request: declared tool names, system-prompt section
 *   headings, a hash of the normalized prompt text, and how many consecutive
 *   requests it covers;
 * - the TypeSafe classifier request the codemode step makes, so a classify
 *   delta is shown rather than inferred;
 * - each client-facing broadcast topic, with the union of its payload structure;
 * - every canonical session JSONL entry, normalized;
 * - the transcript projection from the slot snapshot.
 *
 * The comparison's diff is `git diff --no-index` over the two traces, so an
 * upgrade pull request reviews the behavior-delta inventory hunk by hunk.
 * Intended changes update the golden with `npm run update:sdk-behavior-trace`.
 *
 * The golden is darwin-specific: Tron's `computer` module registers only on
 * darwin and its description and rule lines reach the prompt. The Gateway check
 * that runs this file is macOS, so that is the recorded platform.
 */

const GOLDEN_PATH = resolve(process.cwd(), "test-fixtures", "pi-sdk", "sdk-behavior-trace.golden.json");
const ACTUAL_PATH = resolve(process.cwd(), "test-results", "sdk-behavior-trace.actual.json");
const LOADED_ACTUAL_PATH = resolve(process.cwd(), "test-results", "sdk-behavior-trace.load.actual.json");
const DIFF_PATH = resolve(process.cwd(), "test-results", "sdk-behavior-trace.diff");

/** A 1x1 PNG, so the codemode `image()` output is a real, fixed image payload. */
const IMAGE_DATA_URL =
  "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==";

/** The tool-call IDs the scenario names itself; every other identity is generated. */
const SCRIPTED_TOOL_CALL_IDS = [
  "trace-read", "trace-codemode", "trace-mcp-direct", "trace-tool-search",
  "trace-mcp-loaded", "trace-steer-read",
];

/**
 * The codemode script the scenario runs: `image()`, a nested tool call,
 * `models.classify()` and a codemode-exposed MCP call. `text()` is a statement
 * that appends output rather than a value, so the script reads tool results
 * through its own `asText`. The classify `catch` keeps the error text: a
 * rejection has to be readable in the trace, not just counted.
 */
const CODEMODE_SCRIPT = [
  "const lines = [];",
  "const asText = (result) => { if (typeof result === 'string') return result; if (!result || !Array.isArray(result.content)) return ''; return result.content.map((block) => (block && block.type === 'text' ? block.text : '')).join(''); };",
  `image({ image_url: ${JSON.stringify(IMAGE_DATA_URL)} });`,
  'lines.push("nested=" + asText(await tools.read({ path: "notes.txt" })).trim());',
  'const model = await models.getModelOfType("classifier", "typesafe", "jev-latest");',
  'let classified = "classify-unavailable";',
  "try {",
  '  const answer = await models.classify(model, { state: { text: "boundary state" }, questions: { relevant: { type: "bool", instructions: "Is this relevant?", criteria: { true: "Relevant.", false: "Not relevant." } } } });',
  "  classified = JSON.stringify(answer);",
  '} catch (error) { classified = "classify-error: " + String(error && error.message ? error.message : error); }',
  'let scripted = "scripted-mcp-unavailable";',
  // Pi's normalized tool name uses underscores for the configured hyphenated
  // MCP server, and that same identifier is available in codemode.
  'try { scripted = asText(await tools.mcp__tron_script__echo({ value: "scripted" })); } catch (error) { scripted = "scripted-mcp-unavailable"; }',
  'lines.push("classified=" + classified);',
  'lines.push("scripted=" + scripted);',
  'return lines.join(" | ");',
].join("\n");

/**
 * A hang bound for the abort step, not a speed budget: the abort signal is the
 * contract, and this only keeps a broken one from turning into a test timeout.
 * Well under the 15 s `testTimeout` so the trace delta, not the runner, reports
 * a broken abort.
 */
const ABORT_STEP_FALLBACK_MS = 5_000;

/**
 * The loaded case perturbs the *schedule* as well as the CPU: each scripted
 * provider response lands this much later, so snapshot coalescing and progress
 * throttling see a different interleaving than the idle case.
 */
const INJECTED_DELAY_MS = 40;

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
 * Bounded in-process CPU load: two chains of 4 ms bursts. Both run on this
 * worker's event loop, so this is one thread kept busy, not several cores — and
 * deliberately modest, because the Gateway suite runs four workers on a Mac
 * shared with other agents and an event-loop-stall owner
 * (`session-search-stall.test.ts`) measures that same host.
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

type SessionSlot = Awaited<ReturnType<RuntimeRegistry["acquire"]>>;

/**
 * The tools the session has registered, through the public slot projection.
 * Hidden (codemode-exposed) tools have to be joined before a prompt names them,
 * and no public SDK call lists them ahead of a turn.
 */
async function availableTools(slot: SessionSlot): Promise<Array<{ name: string }>> {
  const context = await slot.context() as { availableTools?: unknown };
  const tools = Array.isArray(context.availableTools) ? context.availableTools : [];
  return tools.flatMap((tool) => tool !== null && typeof tool === "object" && typeof (tool as { name?: unknown }).name === "string"
    ? [{ name: (tool as { name: string }).name }]
    : []);
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
  const normalization = { roots: [root, await realpath(root)], stableIds: SCRIPTED_TOOL_CALL_IDS };

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
      // `defaultTools` entries are *tool* names, not extension names: `tool_search`
      // is the tool the tool-search built-in registers inactive.
      defaultTools: ["+codemode", "+tool_search"],
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

  const providerRequests: Array<Omit<ProviderRequestTrace, "repeats">> = [];
  const recordRequest = (context: TranscriptContext): void => {
    const prompt = getCurrentSystemPrompt(context.messages);
    providerRequests.push({
      tools: getCurrentTools(context.messages).map((tool) => tool.name),
      promptSections: promptSectionHeadings(prompt),
      promptHash: hashPromptText(prompt, normalization),
    });
  };
  const classifierRequests: unknown[] = [];
  const delay = async (): Promise<void> => {
    if (!options.load) return;
    await new Promise((settle) => setTimeout(settle, INJECTED_DELAY_MS));
  };

  const faux = fauxProvider({ provider: "tron-sdk-behavior-trace", tokensPerSecond: 10_000, tokenSize: { min: 4, max: 4 } });
  const steps: Array<(context: TranscriptContext, options: SimpleStreamOptions | undefined) => AssistantMessage | Promise<AssistantMessage>> = [];

  // Turn 1, step 1: streamed thinking and text plus a direct tool and codemode.
  steps.push(async (context) => {
    recordRequest(context);
    await delay();
    return fauxAssistantMessage([
      fauxThinking("Reading the boundary fixture before scripting it."),
      { type: "text", text: "Tracing the SDK boundary." },
      fauxToolCall("read", { path: "notes.txt" }, { id: "trace-read" }),
      fauxToolCall("codemode", { code: CODEMODE_SCRIPT }, { id: "trace-codemode" }),
    ], { stopReason: "toolUse" });
  });
  // Turn 1, step 2: a direct MCP tool and a tool search for the tool the
  // codemode exposure keeps out of the declared list.
  steps.push(async (context) => {
    recordRequest(context);
    await delay();
    return fauxAssistantMessage([
      fauxToolCall("mcp__tron_fixture__echo", { value: "direct" }, { id: "trace-mcp-direct" }),
      fauxToolCall("tool_search", { query: "Echo the boundary fixture value" }, { id: "trace-tool-search" }),
    ], { stopReason: "toolUse" });
  });
  // Turn 1, step 3: the tool search result made the codemode-exposed MCP tool
  // callable directly as well.
  steps.push(async (context) => {
    recordRequest(context);
    await delay();
    return fauxAssistantMessage([fauxToolCall("mcp__tron_script__echo", { value: "loaded-by-search" }, { id: "trace-mcp-loaded" })], { stopReason: "toolUse" });
  });
  steps.push(async (context) => {
    recordRequest(context);
    await delay();
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
    await delay();
    await steerGate;
    return fauxAssistantMessage([fauxToolCall("read", { path: "notes.txt" }, { id: "trace-steer-read" })], { stopReason: "toolUse" });
  });
  steps.push(async (context) => {
    recordRequest(context);
    await delay();
    return fauxAssistantMessage("Steered work acknowledged.");
  });
  steps.push(async (context) => {
    recordRequest(context);
    await delay();
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
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    // The classify boundary is recorded, not swallowed: the trace has to show
    // whether a TypeSafe request was made and what shape it carried.
    classifierRequests.push({
      url: String(input),
      body: typeof init?.body === "string" ? JSON.parse(init.body) : null,
    });
    return new Response(JSON.stringify({
      model: "jev-latest",
      answers: { relevant: { type: "noul", noul: 0.91 } },
      usage: { input_tokens: 128, output_tokens: 8 },
    }), { status: 200, headers: { "content-type": "application/json" } });
  }) as typeof fetch;

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
    await waitFor(async () => {
      const names = (await availableTools(slot)).map((tool) => tool.name);
      return ["fixture", "script"].every((server) => names.some((name) =>
        name.startsWith("mcp__") && name.includes(server) && name.endsWith("__echo")));
    }, "the fixture MCP tools to register");

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
      providerRequests: collapseRepeatedRequests(providerRequests),
      classifierRequests: classifierRequests.map((entry) => normalizeTraceValue(entry, normalization)),
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

function isTraceObject(value: TraceValue | undefined): value is { readonly [key: string]: TraceValue } {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

/** One field of a normalized trace object, or `undefined` when it is not one. */
function field(value: TraceValue | undefined, key: string): TraceValue | undefined {
  return isTraceObject(value) ? value[key] : undefined;
}

/** The text of a normalized content list, or of a string. */
function traceText(value: TraceValue | undefined): string {
  if (typeof value === "string") return value;
  if (Array.isArray(value)) return value.map((item) => traceText(item)).join("\n");
  if (isTraceObject(value)) return typeof value.text === "string" ? value.text : "";
  return "";
}

/**
 * The scenario's own steps must have run on the pinned SDK.
 *
 * This is not a restatement of the golden: it is what makes the golden evidence
 * at all. A renamed tool, a `defaultTools` entry that names an extension instead
 * of a tool, or a rejected classifier call would otherwise be recorded as the
 * expected behavior — which is exactly how the golden once locked in
 * "Tool tool_search not found".
 *
 * It runs only when the trace *matches* the golden (see `compareWithGolden`), so
 * a real SDK delta is still reported as a diff rather than as this failure.
 */
function expectScenarioValid(trace: BehaviorTrace): void {
  const results = trace.transcript.filter((item) => field(item, "kind") === "message" && field(item, "role") === "toolResult");
  const resultText = (item: TraceValue): string => traceText(field(item, "content"));
  expect(results.map(resultText).filter((text) => text.includes("not found"))).toEqual([]);
  for (const name of ["read", "codemode", "mcp__tron_fixture__echo", "tool_search", "mcp__tron_script__echo"]) {
    expect(results.some((item) => field(item, "toolName") === name && field(item, "isError") === false), `${name} must have succeeded`).toBe(true);
  }
  const search = results.find((item) => field(item, "toolName") === "tool_search");
  expect(field(field(search, "details"), "loaded")).toEqual(["mcp__tron_script__echo"]);
  const codemode = resultText(results.find((item) => field(item, "toolName") === "codemode") ?? null);
  expect(codemode).toContain("nested=boundary notes");
  // The classifier answered through the real TypeSafe path: a request was made
  // and Pi parsed its response.
  expect(codemode).toContain('"api":"typesafe-system-one"');
  expect(codemode).toContain('scripted=fixture:echo:{"value":"scripted"}');
  expect(trace.classifierRequests).toHaveLength(1);
  expect(trace.clientEvents.map((event) => event.topic)).toContain("session.snapshot");
  expect(trace.canonicalJsonl.length).toBeGreaterThan(5);
  expect(trace.transcript.length).toBeGreaterThan(5);
  expect(trace.providerRequests.some((request) => request.promptSections.includes("tools"))).toBe(true);
}

const updating = process.env.TRON_UPDATE_SDK_BEHAVIOR_TRACE === "1";

describe("Pi SDK boundary behavior trace", () => {
  it("matches the committed golden for one deterministic scenario through the real Gateway", async () => {
    const trace = await runBoundaryScenario({ load: false });
    // Only the idle case may write the golden; the load case has to agree with
    // whatever this run wrote.
    await compareWithGolden({
      goldenPath: GOLDEN_PATH, actualPath: ACTUAL_PATH, diffPath: DIFF_PATH, trace,
      update: updating, validate: expectScenarioValid,
    });
  });

  it("produces the same trace under in-process load and an injected response delay", async () => {
    // Failure mode: the trace records timing- or ordering-dependent SDK
    // behavior, so a busy host produces a different "delta" than an idle one and
    // the golden stops being evidence. No wait in this file is a speed budget;
    // the load is bounded and confined to this process.
    const trace = await runBoundaryScenario({ load: true });
    await compareWithGolden({
      goldenPath: GOLDEN_PATH, actualPath: LOADED_ACTUAL_PATH, diffPath: DIFF_PATH, trace,
      update: false, validate: expectScenarioValid,
    });
  });
});
