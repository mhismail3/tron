import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { performance } from "node:perf_hooks";
import { fileURLToPath } from "node:url";
import { afterAll, afterEach, describe, expect, it } from "vitest";
import {
  fauxAssistantMessage, fauxProvider, fauxText, fauxThinking, fauxToolCall,
  type AssistantMessage, type Message, type TranscriptContext,
} from "@earendil-works/pi-ai";
import { ModelRuntime, SessionManager } from "@earendil-works/pi-coding-agent";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import {
  createEpisodicTokenBudget, EpisodicMemoryError, resolveLimits,
  type EpisodicLimits, type EpisodicMemoryStatus, type EpisodicSummarizer,
} from "./episodic-contract.js";
import { createModelRuntimeSummarizer } from "./episodic-compactor.js";
import { EpisodicMemory } from "./episodic-memory.js";
import { foldView } from "./episodic-tree.js";

/*
 * End-to-end: a real canonical session in OS temp, driven incrementally through
 * the owner, with a deterministic faux compactor. The view is compared after
 * every step against an independent reference fold re-derived from the durable
 * record stream (never from this module's code).
 *
 * The retained artifact is packages/gateway/test-results/episodic-memory/report.json.
 */

const GATEWAY_ROOT = fileURLToPath(new URL("../..", import.meta.url));
const REPORT_PATH = join(GATEWAY_ROOT, "test-results/episodic-memory/report.json");
const IMAGE_BASE64 = `iVBORw0KGgoAAAANSUhEUg${"QUJD".repeat(120)}`;
const THINKING_PREFIX = "SECRET-REASONING-";
const CAP_MARKER = "…[truncated ";

interface Report {
  generatedAt: string;
  limits: Partial<EpisodicLimits>;
  steps: number;
  messages: number;
  catalogRecords: number;
  nodes: { total: number; free: number; summary: number };
  compactor: { calls: number; maxConcurrent: number; feedbackTurns: number; levelZeroCalls: number };
  invalidations: Array<{ generation: number; invalidated: number; predicted: number; nodesBefore: number }>;
  refold: Array<{ messages: number; ms: number; parts: number; method: string }>;
  negativeControl: {
    wrongWeight: { rule: string; mismatched: boolean; firstDivergenceStep: number | null };
    exponentShift: { rule: string; mismatched: boolean; note: string };
  };
  blocked: Array<{ reason: string; resumed: boolean; nodesAtBlock: number }>;
  earlyEditAtOneThousandMessages: { invalidated: number; nodesBefore: number; messages: number } | null;
}

const report: Report = {
  generatedAt: new Date().toISOString(),
  limits: {},
  steps: 0,
  messages: 0,
  catalogRecords: 0,
  nodes: { total: 0, free: 0, summary: 0 },
  compactor: { calls: 0, maxConcurrent: 0, feedbackTurns: 0, levelZeroCalls: 0 },
  invalidations: [],
  refold: [],
  negativeControl: {
    wrongWeight: { rule: "", mismatched: false, firstDivergenceStep: null },
    exponentShift: { rule: "", mismatched: false, note: "" },
  },
  blocked: [],
  earlyEditAtOneThousandMessages: null,
};

const roots: string[] = [];
const owners: TronWorkspace[] = [];
afterEach(async () => {
  await Promise.all(owners.splice(0).map(owner => owner.dispose()));
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })));
});
afterAll(async () => {
  await mkdir(join(GATEWAY_ROOT, "test-results/episodic-memory"), { recursive: true });
  await writeFile(REPORT_PATH, `${JSON.stringify(report, null, 2)}\n`, "utf8");
  const invalidated = report.invalidations.reduce((total, entry) => total + entry.invalidated, 0);
  console.log(`episodic-memory report: ${report.steps} steps, ${report.messages} messages, ${report.nodes.total} nodes, ${report.compactor.calls} compactor calls, max ${report.compactor.maxConcurrent} concurrent, ${invalidated} nodes invalidated by context edits, refold ${report.refold.map(entry => `${entry.messages}=${entry.ms.toFixed(0)}ms`).join(" ")}`);
});

// ---- the reference fold: written from the gist's pseudocode, not from this module ----

interface Part { level: number; index: number; start: number; span: number }
interface OracleNode { level: number; index: number; text: string; contextDependencies: string[] }

const PLACEHOLDER_BYTES = Buffer.byteLength("(not summarized yet: zoom it)", "utf8");
const address = (level: number, index: number): string => `${index * 2 ** level}+${2 ** level}`;

function partBytes(part: Part, nodes: Map<string, OracleNode>): number {
  const node = nodes.get(address(part.level, part.index));
  return node ? Buffer.byteLength(node.text, "utf8") : PLACEHOLDER_BYTES;
}

/** The gist §5.2 weight `2^(l+2)`. A uniform exponent shift cancels out of the
 * comparison, so the negative control replaces the weight itself. */
const GIST_WEIGHT = (level: number): number => 2 ** (level + 2);

/** gist §5.2 `fit`. `weight` is the real rule in the reference oracle; the
 * negative control passes a wrong weight and must disagree with the view. */
function fit(view: Part[], count: number, budget: number, nodes: Map<string, OracleNode>, weight = GIST_WEIGHT): void {
  for (;;) {
    let size = 0;
    for (const part of view) size += partBytes(part, nodes);
    if (size <= budget) return;
    let best: { position: number; due: number } | undefined;
    for (let position = 0; position + 1 < view.length; position += 1) {
      const a = view[position]!;
      const b = view[position + 1]!;
      if (a.level !== b.level || a.index % 2 !== 0 || b.index !== a.index + 1) continue;
      if (!nodes.has(address(a.level + 1, a.index / 2))) continue;
      const due = (count - a.start) / weight(a.level);
      if (!best || due > best.due) best = { position, due };
    }
    if (!best) return;
    const a = view[best.position]!;
    view.splice(best.position, 2, { level: a.level + 1, index: a.index / 2, start: a.start, span: a.span * 2 });
  }
}

function expandInvalidated(view: Part[], invalid: Set<string>): Part[] {
  let current = view;
  for (;;) {
    let expanded = false;
    const next: Part[] = [];
    for (const part of current) {
      if (part.level > 0 && invalid.has(address(part.level, part.index))) {
        const half = part.span / 2;
        next.push({ level: part.level - 1, index: part.index * 2, start: part.start, span: half });
        next.push({ level: part.level - 1, index: part.index * 2 + 1, start: part.start + half, span: half });
        expanded = true;
      } else next.push(part);
    }
    current = next;
    if (!expanded) return current;
  }
}

interface OracleState { view: Part[]; messages: number; nodes: Map<string, OracleNode>; weight: (level: number) => number }

interface RawNode { revision: number; level: number; index: number; kind: "free" | "summary"; text: string; contextDependencies: string[] }

function readJsonlSafe(path: string): Array<Record<string, unknown>> {
  let text: string;
  try {
    text = readFileSync(path, "utf8");
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return [];
    throw error;
  }
  return text.split("\n").filter(line => line.trim() !== "").map(line => JSON.parse(line) as Record<string, unknown>);
}

function maxIndex(records: Array<Record<string, unknown>>): number {
  return records.reduce((highest, record) => Math.max(highest, record.index as number), -1);
}

/** Every live ancestor of one node address, nearest first (a missing ancestor
 * means every ancestor above it is missing too). */
function ancestorsOf(nodes: Map<string, OracleNode>, address: string): string[] {
  const match = /^(\d+)\+(\d+)$/u.exec(address);
  if (!match) return [];
  const start = Number(match[1]);
  const span = Number(match[2]);
  const ancestors: string[] = [];
  for (let level = Math.log2(span), index = start / span; level <= 63; level += 1, index = Math.floor(index / 2)) {
    const key = nodeAddressOf(level, index);
    if (!nodes.has(key)) break;
    ancestors.push(key);
  }
  return ancestors;
}

function nodeAddressOf(level: number, index: number): string {
  return `${index * 2 ** level}+${2 ** level}`;
}

/** The predicted invalidation closure, as a fixed point over the durable
 * records: the changed leaf and its ancestors, plus every node whose recorded
 * context included any invalidated node (and that node's ancestors), until
 * nothing changes. */
function predictedInvalidation(nodes: Map<string, OracleNode>, index: number): Set<string> {
  const invalid = new Set(ancestorsOf(nodes, address(0, index)));
  for (let changed = true; changed;) {
    changed = false;
    for (const [key, node] of nodes) {
      if (invalid.has(key)) continue;
      if (node.contextDependencies.some(dependency => invalid.has(dependency))) {
        invalid.add(key);
        changed = true;
      }
    }
    for (const key of [...invalid]) {
      for (const ancestor of ancestorsOf(nodes, key)) {
        if (invalid.has(ancestor)) continue;
        invalid.add(ancestor);
        changed = true;
      }
    }
  }
  return invalid;
}

/** Replay one step's durable records into the oracle, in the order the owner
 * made them: appends (with the node set the step started from), then
 * invalidations (revoke, expand, fit), then the step's new nodes, then the
 * quiescence fit. */
function oracleStep(state: OracleState, step: { newMessages: number; records: Array<Record<string, unknown>>; budget: number }): void {
  for (let index = state.messages; index < step.newMessages; index += 1) {
    state.view.push({ level: 0, index, start: index, span: 1 });
    fit(state.view, index + 1, step.budget, state.nodes, state.weight);
  }
  state.messages = step.newMessages;
  for (const record of step.records) {
    if (Array.isArray(record.addresses)) {
      const invalid = new Set(record.addresses as string[]);
      for (const key of invalid) state.nodes.delete(key);
      state.view = expandInvalidated(state.view, invalid);
      fit(state.view, state.messages, step.budget, state.nodes, state.weight);
    } else {
      const node = record as unknown as RawNode;
      state.nodes.set(address(node.level, node.index), { level: node.level, index: node.index, text: node.text, contextDependencies: node.contextDependencies });
    }
  }
  fit(state.view, state.messages, step.budget, state.nodes, state.weight);
}

function statusParts(status: EpisodicMemoryStatus): Array<{ address: string; start: number; messages: number }> {
  return status.view.parts.map(part => ({ address: part.address, start: part.start, messages: part.messages }));
}

function oracleParts(state: OracleState): Array<{ address: string; start: number; messages: number }> {
  return state.view.map(part => ({ address: address(part.level, part.index), start: part.start, messages: part.span }));
}

// ---- fixture -------------------------------------------------------------------

interface Fixture {
  root: string;
  home: string;
  sessionFile: string;
  sessionId: string;
  manager: SessionManager;
  workspace: TronWorkspace;
  modelRuntime: ModelRuntime;
  model: ReturnType<ReturnType<typeof fauxProvider>["getModel"]>;
  faux: ReturnType<typeof fauxProvider>;
  limits: EpisodicLimits;
  catalogPath: string;
  nodesPath: string;
  compactor: {
    calls: number;
    inFlight: number;
    maxConcurrent: number;
    feedbackTurns: number;
    levelZeroBodies: string[];
    prompts: string[];
  };
  summarizer: EpisodicSummarizer;
}

function pad(head: string, length: number): string {
  return `${head}${"m".repeat(Math.max(0, length - head.length))}`;
}

/** Deterministic replies computed from the prompt: most fit `nodeBytes`, one in
 * five deliberately overshoots so the size loop has to run. */
function respond(context: TranscriptContext, nodeBytes: number, compactor: Fixture["compactor"]): AssistantMessage {
  const last = [...context.messages].reverse().find(message => message.role === "user");
  const text = last && last.role === "user"
    ? typeof last.content === "string" ? last.content : last.content.map(part => part.type === "text" ? part.text : "").join("\n")
    : "";
  if (text.includes("must end where it is cut here")) {
    compactor.feedbackTurns += 1;
    return fauxAssistantMessage(pad("short", nodeBytes - 40));
  }
  const leaf = /Compress this message into one line, in at most \d+ bytes:\n([\s\S]*)$/u.exec(text);
  const merge = /Merge these two lines into one, in at most \d+ bytes:\n([\s\S]*)$/u.exec(text);
  const body = (leaf?.[1] ?? merge?.[1] ?? text).replace(/\s+/gu, " ").trim();
  if (leaf) compactor.levelZeroBodies.push(body);
  const overshoot = body.length % 5 === 0;
  return fauxAssistantMessage(pad(body.slice(0, 100), overshoot ? nodeBytes + 100 : nodeBytes - 60));
}

async function fixture(label: string, overrides: Partial<EpisodicLimits> = {}): Promise<Fixture> {
  const root = await mkdtemp(join(tmpdir(), `tron-episodic-${label}-`));
  roots.push(root);
  const home = join(root, "home");
  const cwd = join(root, "project");
  const sessionDir = join(root, "sessions");
  await Promise.all([mkdir(cwd, { recursive: true }), mkdir(sessionDir, { recursive: true })]);
  const manager = SessionManager.create(cwd, sessionDir);
  manager.appendMessage({ role: "user", content: "first prompt", timestamp: Date.now() });
  const sessionFile = manager.getSessionFile()!;
  const sessionId = manager.getSessionId();
  const workspace = new TronWorkspace(home);
  owners.push(workspace);
  const faux = fauxProvider({ provider: `tron-episodic-${label}`, models: [{ id: "compactor", reasoning: false }] });
  const modelRuntime = await ModelRuntime.create({ authPath: join(root, "auth.json"), modelsPath: null, refreshOnCreate: false });
  modelRuntime.registerNativeProvider(faux.provider);
  const model = faux.getModel();
  const limits = resolveLimits(overrides);
  const compactor: Fixture["compactor"] = { calls: 0, inFlight: 0, maxConcurrent: 0, feedbackTurns: 0, levelZeroBodies: [], prompts: [] };
  const defaultSummarizer = createModelRuntimeSummarizer(modelRuntime, model);
  const summarizer: EpisodicSummarizer = async (request) => {
    compactor.calls += 1;
    compactor.inFlight += 1;
    compactor.maxConcurrent = Math.max(compactor.maxConcurrent, compactor.inFlight);
    compactor.prompts.push(request.turns.map(turn => turn.text).join("\n"));
    faux.appendResponses([(context: TranscriptContext) => respond(context, limits.nodeBytes, compactor)]);
    try {
      return await defaultSummarizer(request);
    } finally {
      compactor.inFlight -= 1;
    }
  };
  return {
    root, home, sessionFile, sessionId, manager, workspace, modelRuntime, model, faux, limits,
    catalogPath: join(home, "workspace", "state", "episodic", sessionId, "catalog.jsonl"),
    nodesPath: join(home, "workspace", "state", "episodic", sessionId, "nodes.jsonl"),
    compactor, summarizer,
  };
}

async function openMemory(fx: Fixture, summarizer?: EpisodicSummarizer, budget = createEpisodicTokenBudget(50_000_000)): Promise<EpisodicMemory> {
  return EpisodicMemory.open({
    workspace: fx.workspace,
    sessionId: fx.sessionId,
    sessionFile: fx.sessionFile,
    modelRuntime: fx.modelRuntime,
    model: fx.model,
    budget,
    limits: fx.limits,
    summarizer: summarizer ?? fx.summarizer,
    sleep: async () => {},
  });
}

function userMessage(text: string): Message {
  return { role: "user", content: text, timestamp: Date.now() };
}

function toolResultMessage(toolCallId: string, text: string): Message {
  return { role: "toolResult", toolCallId, toolName: "read_file", content: [{ type: "text", text }], isError: false, timestamp: Date.now() };
}

/** Varied sizes: some fit NODE as free nodes, some need a compactor call, and
 * one tool result in thirteen is far over CAP. */
function messageText(index: number): string {
  if (index % 11 === 0) return `short question ${index}`;
  if (index % 7 === 0) return `paste ${index} ${"p".repeat(2_400)}`;
  return `prompt ${index} about the reconcile loop and the ${"d".repeat(index % 400)} detail`;
}

function toolResultText(index: number): string {
  return index % 13 === 0 ? `result ${index} ${"t".repeat(40_000)}` : `result ${index} ${"r".repeat(index % 900)}`;
}

// ---- tests ---------------------------------------------------------------------

describe("episodic memory end to end", () => {
  it("keeps the view equal to the durable record fold while ingesting, editing and invalidating", async () => {
    const fx = await fixture("e2e", { viewBytes: 4_096, jobs: 4, retryMs: 1, maxRetries: 2 });
    report.limits = { ...fx.limits };
    const memory = await openMemory(fx);
    const oracle: OracleState = { view: [], messages: 0, nodes: new Map(), weight: GIST_WEIGHT };
    let nodesConsumed = 0;
    let catalogConsumed = 0;
    let editIndex = -1;
    let messagesAtEdit = 0;
    let preEditBodies: string[] = [];
    let preEditTexts: string[] = [];

    const step = async (): Promise<void> => {
      const preStepNodes = new Map(oracle.nodes);
      await memory.entriesCommitted(fx.sessionId);
      const catalog = readJsonlSafe(fx.catalogPath);
      const nodeRecords = readJsonlSafe(fx.nodesPath);
      const stepRecords = nodeRecords.slice(nodesConsumed);
      const invalidations = stepRecords.filter(record => Array.isArray(record.addresses));
      if (invalidations.length > 0) {
        const predicted = predictedInvalidation(preStepNodes, editIndex);
        for (const record of invalidations) {
          const addresses = record.addresses as string[];
          report.invalidations.push({ generation: record.generation as number, invalidated: addresses.length, predicted: predicted.size, nodesBefore: preStepNodes.size });
          expect(new Set(addresses)).toEqual(predicted);
        }
      }
      oracleStep(oracle, { newMessages: maxIndex(catalog) + 1, records: stepRecords, budget: fx.limits.viewBytes });
      nodesConsumed = nodeRecords.length;
      catalogConsumed = catalog.length;
      const status = memory.status();
      expect(statusParts(status)).toEqual(oracleParts(oracle));
      expect(status.messages).toBe(oracle.messages);
      expect(status.view.unbuilt).toBe(0);
      expect(status.view.truncatedParts).toBe(0);
      let cursor = 0;
      for (const part of status.view.parts) {
        expect(part.start).toBe(cursor);
        cursor += part.messages;
      }
      expect(cursor).toBe(status.messages);
      expect(status.nodes.total).toBe(oracle.nodes.size);
    };

    for (let batch = 0; batch < 12; batch += 1) {
      for (let index = 0; index < 25; index += 1) {
        const number = batch * 25 + index;
        fx.manager.appendMessage(userMessage(messageText(number)));
        fx.manager.appendMessage(fauxAssistantMessage([
          fauxText(`reply ${number}`),
          fauxThinking(`${THINKING_PREFIX}${number}`),
          fauxToolCall("read_file", { path: `/Users/example/project/file-${number}.ts` }),
        ]));
        if (number % 3 === 0) fx.manager.appendMessage(toolResultMessage(`call-${number}`, toolResultText(number)));
      }
      if (batch === 4) {
        // An image attachment and a display custom message, plus entries that
        // must never become messages.
        fx.manager.appendMessage({ role: "user", content: [{ type: "text", text: "look at this screenshot" }, { type: "image", data: IMAGE_BASE64, mimeType: "image/png" }], timestamp: Date.now() });
        fx.manager.appendCustomMessageEntry("tron.receipt", "displayed event text", true);
        fx.manager.appendCustomMessageEntry("tron.receipt", "hidden receipt text", false);
        fx.manager.appendCustomEntry("tron.bookkeeping", { private: "bookkeeping" });
        fx.manager.appendModelChange("faux", "compactor");
        fx.manager.appendThinkingLevelChange("high");
        fx.manager.appendLabelChange(fx.manager.getLeafId()!, "bookmark");
        fx.manager.appendSessionInfo("renamed session");
        await step();
        // A context edit targets an already-ingested entry: this is the
        // invalidation case, and it must not renumber anything.
        preEditBodies = [...fx.compactor.levelZeroBodies];
        preEditTexts = catalogLevelZeroTexts(fx);
        messagesAtEdit = memory.status().messages;
        const target = fx.manager.getBranch().filter(entry => entry.type === "message")[6]!;
        editIndex = catalogIndexFor(fx, target.id);
        fx.manager.appendContextEdit(target.id, { content: "replacement prompt from a context edit" });
        await step();
        continue;
      }
      await step();
    }

    report.steps = 13;
    report.messages = memory.status().messages;
    report.catalogRecords = catalogConsumed;
    report.nodes = { total: memory.status().nodes.total, free: memory.status().nodes.free, summary: memory.status().nodes.summary };
    report.compactor = {
      calls: fx.compactor.calls,
      maxConcurrent: fx.compactor.maxConcurrent,
      feedbackTurns: fx.compactor.feedbackTurns,
      levelZeroCalls: fx.compactor.levelZeroBodies.length,
    };

    // Rule 3: leaves are built strictly in order. The durable level-0 records
    // prove it: the first pass appends leaves 0,1,2,… with no gap and no
    // repeat, and the context edit's rebuild touches exactly the invalidated
    // leaves, each once.
    const levelZeroIndices = readJsonlSafe(fx.nodesPath)
      .filter(record => !Array.isArray(record.addresses) && record.level === 0)
      .sort((a, b) => (a.revision as number) - (b.revision as number))
      .map(record => record.index as number);
    const firstDecrease = levelZeroIndices.findIndex((index, position) => position > 0 && index <= levelZeroIndices[position - 1]!);
    const firstPass = firstDecrease === -1 ? levelZeroIndices.length : firstDecrease;
    expect(levelZeroIndices.slice(0, firstPass)).toEqual([...Array(firstPass).keys()]);
    expect(firstPass).toBe(messagesAtEdit);
    const rebuilt = levelZeroIndices.slice(firstPass).filter(index => index < messagesAtEdit);
    const invalidatedLeaves = readJsonlSafe(fx.nodesPath)
      .filter(record => Array.isArray(record.addresses))
      .flatMap(record => (record.addresses as string[]).filter(entry => entry.endsWith("+1")))
      .map(entry => Number(entry.split("+")[0]));
    expect(rebuilt.length).toBe(new Set(rebuilt).size);
    expect(new Set(rebuilt)).toEqual(new Set(invalidatedLeaves));

    // The compactor's level-0 steps are the messages that needed a call, in
    // index order, before the edit rebuilds them.
    expect(preEditBodies.map(sha)).toEqual(preEditTexts.map(sha));
    expect(preEditBodies.length).toBeGreaterThan(10);

    // The compactor never sees an unsummarized line, reasoning or attachment
    // bytes; concurrency stays inside JOBS and the size loop ran.
    for (const prompt of fx.compactor.prompts) {
      expect(prompt).not.toContain("(not summarized yet");
      expect(prompt).not.toContain(THINKING_PREFIX);
      expect(prompt).not.toContain(IMAGE_BASE64);
    }
    expect(fx.compactor.maxConcurrent).toBeLessThanOrEqual(fx.limits.jobs);
    expect(fx.compactor.maxConcurrent).toBeGreaterThan(1);
    expect(fx.compactor.feedbackTurns).toBeGreaterThan(0);

    const catalogRaw = await readFile(fx.catalogPath, "utf8");
    expect(catalogRaw).not.toContain(THINKING_PREFIX);
    expect(catalogRaw).not.toContain(IMAGE_BASE64);
    expect(catalogRaw).toContain("[image: image/png]");
    // Redaction is the Gateway's one rule set: a machine-local path is replaced
    // before the text is projected, and the omission records it.
    expect(catalogRaw).toContain("[USER_PATH]");
    expect(catalogRaw).not.toContain("/Users/example/project");
    expect(catalogRaw).toContain("displayed event text");
    expect(catalogRaw).not.toContain("hidden receipt text");
    expect(catalogRaw).not.toContain("bookkeeping");
    expect(catalogRaw).not.toContain("renamed session");

    // A tool result over CAP is capped head and tail, and says so.
    const capped = readJsonlSafe(fx.catalogPath).find(record => typeof record.text === "string" && (record.text as string).includes(CAP_MARKER))!;
    expect(capped).toBeDefined();
    const cappedText = capped.text as string;
    expect(cappedText.startsWith("tool read_file: result ")).toBe(true);
    // Head and tail kept: the first characters and the last characters of the
    // 40,000-character result both survive the cap.
    expect(cappedText.endsWith("t".repeat(100))).toBe(true);
    expect(cappedText.length).toBeLessThan(40_000);
    expect(capped.omissions as string[]).toContain("capped");

    // The context edit replaced its target without renumbering anything.
    const edited = readJsonlSafe(fx.catalogPath).find(record => record.text === "replacement prompt from a context edit");
    expect(edited).toBeDefined();
    expect(edited!.index).toBe(editIndex);

    await memory.whenReady(memory.status().messages);
    await memory.dispose();
  }, 300_000);

  it("negative control: a wrong due weight in the oracle disagrees with the view", async () => {
    const fx = await fixture("control", { viewBytes: 16_384, jobs: 4, retryMs: 1 });
    const memory = await openMemory(fx);
    // The real rule is `due = (T - start) / 2^(level + 2)`. A uniform exponent
    // shift cancels out of that comparison, so a wrong exponent alone can never
    // disagree; the control drops the level weight entirely, which changes
    // which pair wins. Both are recorded.
    const wrong: OracleState = { view: [], messages: 0, nodes: new Map(), weight: () => 1 };
    const equivalent: OracleState = { view: [], messages: 0, nodes: new Map(), weight: (level: number) => 2 ** (level + 3) };
    let wrongConsumed = 0;
    let equivalentConsumed = 0;
    let wrongDivergedAt: number | null = null;
    let equivalentDivergedAt: number | null = null;
    for (let batch = 0; batch < 60; batch += 1) {
      for (let index = 0; index < 10; index += 1) {
        const number = batch * 10 + index;
        fx.manager.appendMessage(userMessage(messageText(number)));
        fx.manager.appendMessage(fauxAssistantMessage([fauxText(`reply ${number}`), fauxToolCall("read_file", { path: `file-${number}.ts` })]));
      }
      await memory.entriesCommitted(fx.sessionId);
      const catalog = readJsonlSafe(fx.catalogPath);
      const nodeRecords = readJsonlSafe(fx.nodesPath);
      const messages = maxIndex(catalog) + 1;
      oracleStep(wrong, { newMessages: messages, records: nodeRecords.slice(wrongConsumed), budget: fx.limits.viewBytes });
      oracleStep(equivalent, { newMessages: messages, records: nodeRecords.slice(equivalentConsumed), budget: fx.limits.viewBytes });
      wrongConsumed = nodeRecords.length;
      equivalentConsumed = nodeRecords.length;
      const actual = JSON.stringify(statusParts(memory.status()));
      if (wrongDivergedAt === null && JSON.stringify(oracleParts(wrong)) !== actual) wrongDivergedAt = batch;
      if (equivalentDivergedAt === null && JSON.stringify(oracleParts(equivalent)) !== actual) equivalentDivergedAt = batch;
    }
    report.negativeControl = {
      wrongWeight: { rule: "due = T - start (no level weight)", mismatched: wrongDivergedAt !== null, firstDivergenceStep: wrongDivergedAt },
      exponentShift: { rule: "due = (T - start) / 2^(level + 3)", mismatched: equivalentDivergedAt !== null, note: "a uniform exponent shift cancels out of the comparison" },
    };
    expect(wrongDivergedAt).not.toBeNull();
    expect(equivalentDivergedAt).toBeNull();
    await memory.dispose();
  }, 300_000);

  it("blocks on a permanent refusal, exhausted retries and an exhausted budget, and resumes", async () => {
    const fx = await fixture("blocked", { viewBytes: 1_024, jobs: 2, retryMs: 1, maxRetries: 2 });
    for (let index = 0; index < 12; index += 1) {
      fx.manager.appendMessage(userMessage(`blocked case message ${index} ${"b".repeat(600)}`));
      fx.manager.appendMessage(fauxAssistantMessage([fauxText(`reply ${index} ${"a".repeat(600)}`)]));
    }

    // 1. A permanent refusal blocks at once, and the pump stops.
    let calls = 0;
    const refusal: EpisodicSummarizer = async () => {
      calls += 1;
      return fauxAssistantMessage("", { stopReason: "error", errorMessage: "The model refused this request" });
    };
    const refused = await openMemory(fx, refusal);
    await refused.entriesCommitted(fx.sessionId);
    const refusedStatus = refused.status();
    expect(refusedStatus.blocked?.reason).toBe("permanent-failure");
    expect(refusedStatus.pump.busy).toBe(0);
    const nodesWhenBlocked = refusedStatus.nodes.total;
    const callsAtBlock = calls;
    await refused.entriesCommitted(fx.sessionId);
    expect(calls).toBe(callsAtBlock);
    await expect(refused.whenReady(refusedStatus.messages)).rejects.toBeInstanceOf(EpisodicMemoryError);
    // The blocked state survives a restart, and resume() with a working
    // compactor recovers it.
    const recovered = await openMemory(fx);
    expect(recovered.status().blocked?.reason).toBe("permanent-failure");
    await recovered.resume();
    expect(recovered.status().blocked).toBeNull();
    expect(recovered.status().nodes.total).toBeGreaterThan(nodesWhenBlocked);
    report.blocked.push({ reason: "permanent-failure", resumed: true, nodesAtBlock: nodesWhenBlocked });
    await refused.dispose();
    await recovered.dispose();

    // 2. A transient failure that never succeeds exhausts its retries; once the
    // provider recovers, resume() restarts the pump on the same memory.
    const retryFixture = await fixture("retries", { viewBytes: 1_024, jobs: 2, retryMs: 1, maxRetries: 2 });
    for (let index = 0; index < 4; index += 1) retryFixture.manager.appendMessage(userMessage(`retry case message ${index} ${"c".repeat(600)}`));
    let attempts = 0;
    const flaky: EpisodicSummarizer = async (request) => {
      attempts += 1;
      if (attempts <= 3) throw new Error("overloaded, please retry");
      return retryFixture.summarizer(request);
    };
    const retried = await openMemory(retryFixture, flaky);
    await retried.entriesCommitted(retryFixture.sessionId);
    expect(retried.status().blocked?.reason).toBe("retries-exhausted");
    expect(attempts).toBe(3);
    report.blocked.push({ reason: "retries-exhausted", resumed: false, nodesAtBlock: retried.status().nodes.total });
    await retried.resume();
    expect(retried.status().blocked).toBeNull();
    expect(retried.status().nodes.total).toBeGreaterThan(0);
    await retried.dispose();

    // 3. A budget that cannot fit the next call blocks; a larger budget resumes.
    const budgetFixture = await fixture("budget", { viewBytes: 1_024, jobs: 2, retryMs: 1 });
    for (let index = 0; index < 4; index += 1) budgetFixture.manager.appendMessage(userMessage(`budget case message ${index} ${"d".repeat(600)}`));
    const budgeted = await openMemory(budgetFixture, undefined, createEpisodicTokenBudget(10));
    await budgeted.entriesCommitted(budgetFixture.sessionId);
    expect(budgeted.status().blocked?.reason).toBe("budget-exhausted");
    // The seed message is short, so it is a free node; no compactor call was
    // ever admitted, so no summary node exists.
    expect(budgeted.status().nodes.summary).toBe(0);
    report.blocked.push({ reason: "budget-exhausted", resumed: false, nodesAtBlock: budgeted.status().nodes.total });
    await budgeted.dispose();
    const funded = await openMemory(budgetFixture);
    expect(funded.status().blocked?.reason).toBe("budget-exhausted");
    await funded.resume();
    expect(funded.status().blocked).toBeNull();
    expect(funded.status().nodes.total).toBeGreaterThan(0);
    expect(funded.status().tokens.used).toBeGreaterThan(0);
    await funded.dispose();
  }, 300_000);

  it("measures the refold at 10k and 100k synthetic messages", () => {
    for (const messages of [10_000, 100_000]) {
      const built = new Set<string>();
      for (let level = 0; 2 ** level <= messages; level += 1) {
        const span = 2 ** level;
        for (let index = 0; (index + 1) * span <= messages; index += 1) built.add(address(level, index));
      }
      const bytesOf = (part: Part): { built: boolean; bytes: number } => built.has(address(part.level, part.index))
        ? { built: true, bytes: 250 }
        : { built: false, bytes: PLACEHOLDER_BYTES };
      const started = performance.now();
      const parts = foldView(messages, 128_000, bytesOf, key => built.has(key));
      report.refold.push({
        messages,
        ms: performance.now() - started,
        parts: parts.length,
        method: "every node built; one Set lookup per part and per candidate merge; constant part bytes",
      });
    }
    expect(report.refold).toHaveLength(2);
    expect(report.refold[0]!.parts).toBeGreaterThan(0);
  }, 300_000);

  it("measures how many nodes an early edit invalidates in a 1,000-message history", async () => {
    const fx = await fixture("thousand", { viewBytes: 8_192, jobs: 8, retryMs: 1 });
    // A 1,000-message backlog ingested at once leaves the view far over its soft
    // budget until merges catch up, so the first calls carry a large context;
    // the budget here is about the invalidation measurement, not about cost.
    const memory = await openMemory(fx, undefined, createEpisodicTokenBudget(2_000_000_000));
    // The fixture's seed message plus 999 more make a 1,000-message history.
    for (let index = 0; index < 499; index += 1) {
      fx.manager.appendMessage(userMessage(`thousand case prompt ${index} ${"k".repeat(600)}`));
      fx.manager.appendMessage(fauxAssistantMessage([fauxText(`reply ${index} ${"l".repeat(600)}`)]));
    }
    fx.manager.appendMessage(userMessage(`thousand case prompt 999 ${"k".repeat(600)}`));
    await memory.entriesCommitted(fx.sessionId);
    const nodesBefore = readJsonlSafe(fx.nodesPath).filter(record => !Array.isArray(record.addresses));
    const target = fx.manager.getBranch().filter(entry => entry.type === "message")[1]!;
    fx.manager.appendContextEdit(target.id, { content: "early replacement" });
    await memory.entriesCommitted(fx.sessionId);
    const invalidations = readJsonlSafe(fx.nodesPath).filter(record => Array.isArray(record.addresses));
    const invalidated = invalidations.reduce((total, record) => total + (record.addresses as string[]).length, 0);
    report.earlyEditAtOneThousandMessages = { invalidated, nodesBefore: nodesBefore.length, messages: memory.status().messages };
    expect(memory.status().blocked).toBeNull();
    expect(memory.status().messages).toBe(1_000);
    expect(invalidated).toBeGreaterThan(0);
    expect(invalidated).toBeLessThanOrEqual(nodesBefore.length);
    await memory.dispose();
  }, 900_000);
});

function catalogIndexFor(fx: Fixture, entryId: string): number {
  const record = readJsonlSafe(fx.catalogPath).find(candidate => candidate.entryId === entryId);
  expect(record).toBeDefined();
  return record!.index as number;
}

/** The catalog's level-0 source lines that do not fit NODE, in index order. */
function catalogLevelZeroTexts(fx: Fixture): string[] {
  return readJsonlSafe(fx.catalogPath)
    .filter(record => !record.omitted)
    .sort((a, b) => (a.index as number) - (b.index as number))
    .map(record => `${record.kind as string}: ${record.text as string}`.replace(/\s+/gu, " ").trim())
    .filter(line => Buffer.byteLength(line, "utf8") > fx.limits.nodeBytes);
}

/** Failure diffs of 40 KB tool results are unreadable; compare digests. */
function sha(value: string): string {
  return createHash("sha256").update(value).digest("hex").slice(0, 16);
}
