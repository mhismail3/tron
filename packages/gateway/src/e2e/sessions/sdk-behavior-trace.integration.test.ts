import { createTestRegistry } from "../../../test-support/gateway-registry.js";
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
import { TrustService } from "../../kernel/resources/trust-service.js";
import { RuntimeRegistry } from "../../kernel/session/runtime-registry.js";
import {
  clientEventTrace, collapseRepeatedRequests, compareWithGolden, eventShapePaths, hashPromptText,
  lockUpdateRequested, normalizeTraceValue, promptSectionHeadings,
  type BehaviorTrace, type ProviderRequestTrace, type TraceValue,
} from "../../../test-support/scenario-lock.js";
import { WAIT_HANG_BOUND_MS, awaitsWithin, waitFor } from "../../../test-support/wait-for.js";

const GOLDEN_PATH = resolve(process.cwd(), "test-fixtures", "pi-sdk", "sdk-behavior-trace.golden.json");
const ACTUAL_PATH = resolve(process.cwd(), "test-results", "sdk-behavior-trace.actual.json");
const LOADED_ACTUAL_PATH = resolve(process.cwd(), "test-results", "sdk-behavior-trace.load.actual.json");
const DIFF_PATH = resolve(process.cwd(), "test-results", "sdk-behavior-trace.diff");

const IMAGE_DATA_URL =
  "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==";

const SCRIPTED_TOOL_CALL_IDS = [
  "trace-read", "trace-codemode", "trace-mcp-direct", "trace-tool-search",
  "trace-mcp-loaded", "trace-steer-read",
];

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
  'try { scripted = asText(await tools.mcp__tron_script__echo({ value: "scripted" })); } catch (error) { scripted = "scripted-mcp-unavailable"; }',
  'lines.push("classified=" + classified);',
  'lines.push("scripted=" + scripted);',
  'return lines.join(" | ");',
].join("\n");

const ABORT_STEP_FALLBACK_MS = 5_000;

const INJECTED_DELAY_MS = 40;

const SCENARIO_HANG_BOUND_MS = 5 * WAIT_HANG_BOUND_MS;

const registries: RuntimeRegistry[] = [];
const roots: string[] = [];
const fixtureProcessIds = new Set<number>();
afterEach(async () => {
  await Promise.all(registries.splice(0).map((registry) => registry.dispose().catch(() => {})));
  for (const pid of fixtureProcessIds) try { process.kill(pid, "SIGKILL"); } catch { }
  fixtureProcessIds.clear();
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

function startInProcessLoad(): () => void {
  let running = true;
  const burst = (): void => {
    if (!running) return;
    const until = performance.now() + 4;
    while (performance.now() < until) { }
    setTimeout(burst, 0);
  };
  for (let chain = 0; chain < 2; chain += 1) setTimeout(burst, 0);
  return () => { running = false; };
}

interface ScenarioOptions { readonly load: boolean }

type SessionSlot = Awaited<ReturnType<RuntimeRegistry["acquire"]>>;

async function availableTools(slot: SessionSlot): Promise<Array<{ name: string }>> {
  const context = await slot.context() as { availableTools?: unknown };
  const tools = Array.isArray(context.availableTools) ? context.availableTools : [];
  return tools.flatMap((tool) => tool !== null && typeof tool === "object" && typeof (tool as { name?: unknown }).name === "string"
    ? [{ name: (tool as { name: string }).name }]
    : []);
}

async function runBoundaryScenario(options: ScenarioOptions): Promise<BehaviorTrace> {
  const root = await mkdtemp(join(tmpdir(), "tron-sdk-behavior-trace-"));
  roots.push(root);
  const agentDir = join(root, "agent");
  const sessionDir = join(root, "sessions");
  const cwd = join(root, "workspace");
  await Promise.all([mkdir(agentDir, { recursive: true }), mkdir(sessionDir, { recursive: true }), mkdir(cwd, { recursive: true })]);
  const normalization = { roots: [root, await realpath(root)], stableIds: SCRIPTED_TOOL_CALL_IDS };

  const fixture = resolve(process.cwd(), "test-fixtures", "pi-sdk", "mcp-jsonrpc-fixture.mjs");
  const fixtureTools = [{
    name: "echo",
    description: "Echo the boundary fixture value",
    inputSchema: { type: "object", properties: { value: { type: "string" } }, required: ["value"] },
  }];
  const servers: Record<string, unknown> = {};
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
      defaultTools: ["+codemode", "+tool_search"],
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
  const delay = (): Promise<void> => options.load
    ? new Promise<void>((settle) => { setTimeout(settle, INJECTED_DELAY_MS); }) : Promise.resolve();

  const faux = fauxProvider({ provider: "tron-sdk-behavior-trace", tokensPerSecond: 10_000, tokenSize: { min: 4, max: 4 } });
  const steps: Array<(context: TranscriptContext, options: SimpleStreamOptions | undefined) => AssistantMessage | Promise<AssistantMessage>> = [];

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
  steps.push(async (context) => {
    recordRequest(context);
    await delay();
    return fauxAssistantMessage([
      fauxToolCall("mcp__tron_fixture__echo", { value: "direct" }, { id: "trace-mcp-direct" }),
      fauxToolCall("tool_search", { query: "Echo the boundary fixture value" }, { id: "trace-tool-search" }),
    ], { stopReason: "toolUse" });
  });
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
  const registry = await createTestRegistry({
    agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, modelRuntimeFactory, trust,
    broadcast: (_sessionId, topic, payload) => { clientEvents.push({ topic, paths: eventShapePaths(topic, payload) }); },
    sessionSummaryChanged: () => {}, sessionListChanged: () => {},
  });
  registries.push(registry);

  const originalFetch = globalThis.fetch;
  const stopLoad = options.load ? startInProcessLoad() : () => {};
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
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
    registry.subscribe("trace-client", slot.id);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await waitFor(async () => {
      const names = (await availableTools(slot)).map((tool) => tool.name);
      return ["fixture", "script"].every((server) => names.some((name) =>
        name.startsWith("mcp__") && name.includes(server) && name.endsWith("__echo")));
    }, "the fixture MCP tools to register");

    await slot.prompt("trace the Pi SDK boundary");
    await waitFor(() => !slot.isBusy, "the traced turn to settle");

    const steering = slot.prompt("hold a turn open for a steer");
    steering.catch(() => {});
    await awaitsWithin(steerStarted, "the steerable provider request");
    await slot.prompt("steer the boundary", [], "steer");
    await slot.prompt("then follow up", [], "followUp");
    releaseSteer();
    await steering;
    await waitFor(() => !slot.isBusy, "the steered and follow-up turns to settle");

    const aborting = slot.prompt("abort this turn");
    aborting.catch(() => {});
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

function field(value: TraceValue | undefined, key: string): TraceValue | undefined {
  return isTraceObject(value) ? value[key] : undefined;
}

function traceText(value: TraceValue | undefined): string {
  if (typeof value === "string") return value;
  if (Array.isArray(value)) return value.map((item) => traceText(item)).join("\n");
  if (isTraceObject(value)) return typeof value.text === "string" ? value.text : "";
  return "";
}

function expectScenarioValid(trace: BehaviorTrace): void {
  const results = trace.transcript.filter((item) => field(item, "kind") === "message" && field(item, "role") === "toolResult");
  const resultText = (item: TraceValue): string => traceText(field(item, "content"));
  expect(results.map(resultText).filter((text) => text.includes("not found"))).toEqual([]);
  for (const name of ["read", "codemode", "mcp__tron_fixture__echo", "tool_search", "mcp__tron_script__echo"]) {
    expect(results.some((item) => field(item, "toolName") === name && field(item, "isError") === false), `${name} must have succeeded`).toBe(true);
  }
  const search = results.find((item) => field(item, "toolName") === "tool_search");
  expect(field(field(search, "details"), "loaded")).toEqual(["mcp__tron_script__echo"]);
  const codemodeResult = results.find((item) => field(item, "toolName") === "codemode");
  const codemode = resultText(codemodeResult ?? null);
  expect(codemode).toContain("nested=boundary notes");
  expect(codemode).not.toContain("[Image saved to ");
  expect(Array.isArray(field(codemodeResult, "content"))
    && (field(codemodeResult, "content") as TraceValue[]).some((part) => field(part, "type") === "image"))
    .toBe(true);
  const canonicalCodemodeResult = trace.canonicalJsonl.find((entry) =>
    field(field(entry, "message"), "role") === "toolResult"
    && field(field(entry, "message"), "toolName") === "codemode");
  expect(traceText(field(field(canonicalCodemodeResult, "message"), "content"))).toContain("[Image saved to ");
  expect(codemode).toContain('"api":"typesafe-system-one"');
  expect(codemode).toContain('scripted=fixture:echo:{"value":"scripted"}');
  expect(trace.classifierRequests).toHaveLength(1);
  expect(trace.clientEvents.map((event) => event.topic)).toContain("session.snapshot");
  expect(trace.canonicalJsonl.length).toBeGreaterThan(5);
  expect(trace.transcript.length).toBeGreaterThan(5);
  expect(trace.providerRequests.some((request) => request.promptSections.includes("tools"))).toBe(true);
}

const LOCK_MODULE = "gateway/e2e";
const updating = lockUpdateRequested(LOCK_MODULE);

describe("Pi SDK boundary behavior trace", { timeout: SCENARIO_HANG_BOUND_MS }, () => {
  it("matches the committed golden for one deterministic scenario through the real Gateway", async () => {
    const trace = await runBoundaryScenario({ load: false });
    await compareWithGolden({
      module: LOCK_MODULE, goldenPath: GOLDEN_PATH, actualPath: ACTUAL_PATH, diffPath: DIFF_PATH, trace,
      update: updating, validate: expectScenarioValid,
    });
  });

  it("produces the same trace under in-process load and an injected response delay", async () => {
    const trace = await runBoundaryScenario({ load: true });
    await compareWithGolden({
      module: LOCK_MODULE, goldenPath: GOLDEN_PATH, actualPath: LOADED_ACTUAL_PATH, diffPath: DIFF_PATH, trace,
      update: false, validate: expectScenarioValid,
    });
  });
});
