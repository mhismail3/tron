import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { afterAll, afterEach, describe, expect, it } from "vitest";
import {
  fauxAssistantMessage, fauxProvider, fauxText, fauxThinking, fauxToolCall,
  type AssistantMessage, type Message, type TranscriptContext, type Usage,
} from "@earendil-works/pi-ai";
import { ModelRuntime, SessionManager } from "@earendil-works/pi-coding-agent";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import {
  EpisodicMemoryError, resolveLimits,
  type EpisodicLimits, type EpisodicMemoryStatus, type EpisodicSummarizer,
} from "./episodic-contract.js";
import { createModelRuntimeSummarizer } from "./episodic-compactor.js";
import { EpisodicMemory } from "./episodic-memory.js";

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
const PLANTED_CREDENTIAL = "sk-abcdefghijklmnopqrstuvwxyz012345";

interface Report {
  generatedAt: string;
  limits: Partial<EpisodicLimits>;
  steps: number;
  messages: number;
  catalogRecords: number;
  nodes: { total: number; free: number; summary: number };
  compactor: { calls: number; maxConcurrent: number; feedbackTurns: number; levelZeroCalls: number };
  invalidations: Array<{ generation: number; chunks: number; invalidated: number; predicted: number; nodesBefore: number }>;
  concurrency: { indices: number; catalogRecords: number; duplicateViewParts: number };
  inFlightEdit: { invalidated: number; predicted: number; stalePublished: number };
  usage: { totalTokensUsed: number; summedUsageUsed: number };
  oversized: { recordChars: number; capped: boolean; headKept: boolean; tailKept: boolean; blockedOnLineBound: string | null };
  blocked: Array<{ reason: string; resumed: boolean; nodesAtBlock: number }>;
  recordedOnce: { negativeControl: string };
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
  concurrency: { indices: 0, catalogRecords: 0, duplicateViewParts: 0 },
  inFlightEdit: { invalidated: 0, predicted: 0, stalePublished: 0 },
  usage: { totalTokensUsed: 0, summedUsageUsed: 0 },
  oversized: { recordChars: 0, capped: false, headKept: false, tailKept: false, blockedOnLineBound: null },
  blocked: [],
  recordedOnce: {
    negativeControl: "Recorded once before this test was removed: an oracle whose due weight dropped the level term (due = T - start) diverged from the view at step 8 of a 300-message run, while a uniform exponent shift (2^(level+3)) provably cannot diverge.",
  },
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
  console.log(`episodic-memory report: ${report.steps} steps, ${report.messages} messages, ${report.nodes.total} nodes, ${report.compactor.calls} compactor calls, max ${report.compactor.maxConcurrent} concurrent, ${invalidated} nodes invalidated by context edits, blocked ${report.blocked.map(entry => entry.reason).join("/")}`);
});

// ---- the reference fold: written from the gist's pseudocode, not from this module ----

interface Part { level: number; index: number; start: number; span: number }
interface OracleNode { level: number; index: number; text: string; contextRuns: Array<[number, number]> }

const PLACEHOLDER_BYTES = Buffer.byteLength("(not summarized yet: zoom it)", "utf8");
const address = (level: number, index: number): string => `${index * 2 ** level}+${2 ** level}`;

/** The invalidation record's compact address encoding, decoded independently. */
function decodeCodes(value: string): string[] {
  return value.split(" ").filter(code => code !== "").map(code => {
    const packed = Number.parseInt(code, 36);
    const level = packed % 32;
    const start = (packed - level) / 32;
    return `${start}+${2 ** level}`;
  });
}

/** The node record's level-run context, decoded independently. */
function decodeRuns(runs: ReadonlyArray<readonly [number, number]>): string[] {
  const addresses: string[] = [];
  let cursor = 0;
  for (const [level, count] of runs) {
    const span = 2 ** level;
    for (let offset = 0; offset < count; offset += 1) {
      addresses.push(`${cursor}+${span}`);
      cursor += span;
    }
  }
  return addresses;
}

function partBytes(part: Part, nodes: Map<string, OracleNode>): number {
  const node = nodes.get(address(part.level, part.index));
  return node ? Buffer.byteLength(node.text, "utf8") : PLACEHOLDER_BYTES;
}

/** gist §5.2 `fit`. `weight` is the real rule; a wrong weight is what the
 * recorded one-time negative control used. */
const GIST_WEIGHT = (level: number): number => 2 ** (level + 2);

/** The view's fit (gist §5.2) as #491 batches it: nothing until the view passes
 * its budget, then merges down to seven eighths of it. */
function fit(view: Part[], count: number, budget: number, nodes: Map<string, OracleNode>, weight = GIST_WEIGHT): void {
  const size = () => view.reduce((sum, part) => sum + partBytes(part, nodes), 0);
  if (size() <= budget) return;
  const target = budget - Math.floor(budget / 8);
  for (;;) {
    if (size() <= target) return;
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

interface OracleState { view: Part[]; messages: number; nodes: Map<string, OracleNode> }

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

function ancestorsOf(nodes: Map<string, OracleNode>, from: string): string[] {
  const match = /^(\d+)\+(\d+)$/u.exec(from);
  if (!match) return [];
  const start = Number(match[1]);
  const span = Number(match[2]);
  const ancestors: string[] = [];
  for (let level = Math.log2(span), index = start / span; level <= 63; level += 1, index = Math.floor(index / 2)) {
    const key = address(level, index);
    if (!nodes.has(key)) break;
    ancestors.push(key);
  }
  return ancestors;
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
      if (decodeRuns(node.contextRuns).some(dependency => invalid.has(dependency))) {
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
 * made them: appends (with the node set the step started from), then each
 * invalidation chunk and each node record, each followed by a fit. */
function oracleStep(state: OracleState, step: { newMessages: number; records: Array<Record<string, unknown>>; budget: number }): void {
  for (let index = state.messages; index < step.newMessages; index += 1) {
    state.view.push({ level: 0, index, start: index, span: 1 });
    fit(state.view, index + 1, step.budget, state.nodes);
  }
  state.messages = step.newMessages;
  for (const record of step.records) {
    if (typeof record.nodes === "string") {
      const invalid = new Set(decodeCodes(record.nodes));
      for (const key of invalid) state.nodes.delete(key);
      state.view = expandInvalidated(state.view, invalid);
      fit(state.view, state.messages, step.budget, state.nodes);
    } else {
      state.nodes.set(address(record.level as number, record.index as number), {
        level: record.level as number, index: record.index as number, text: record.text as string,
        contextRuns: record.contextRuns as Array<[number, number]>,
      });
      fit(state.view, state.messages, step.budget, state.nodes);
    }
  }
}

function statusParts(status: EpisodicMemoryStatus): Array<{ address: string; start: number; messages: number }> {
  return status.view.parts.map(part => ({ address: part.address, start: part.start, messages: part.messages }));
}

function oracleParts(state: OracleState): Array<{ address: string; start: number; messages: number }> {
  return state.view.map(part => ({ address: address(part.level, part.index), start: part.start, messages: part.span }));
}

// ---- fixture -------------------------------------------------------------------

interface Gate {
  paused: boolean;
  inFlight: number;
  waiters: Array<() => void>;
}

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
  gate: Gate;
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
  const line = pad(body.slice(0, 100), overshoot ? nodeBytes + 100 : nodeBytes - 60);
  // One in three summaries carries a second line, so the prompt's context lines
  // have to be flattened (the view is one line per part).
  return fauxAssistantMessage(compactor.calls % 3 === 0 ? `${line}\nLINEBREAK-${compactor.calls}` : line);
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
  const gate: Gate = { paused: false, inFlight: 0, waiters: [] };
  const compactor: Fixture["compactor"] = { calls: 0, inFlight: 0, maxConcurrent: 0, feedbackTurns: 0, levelZeroBodies: [], prompts: [] };
  const defaultSummarizer = createModelRuntimeSummarizer(modelRuntime, model);
  const summarizer: EpisodicSummarizer = async (request) => {
    compactor.calls += 1;
    compactor.inFlight += 1;
    gate.inFlight += 1;
    compactor.maxConcurrent = Math.max(compactor.maxConcurrent, compactor.inFlight);
    compactor.prompts.push(request.turns.map(turn => turn.text).join("\n"));
    faux.appendResponses([(context: TranscriptContext) => respond(context, limits.nodeBytes, compactor)]);
    try {
      // Only a first attempt parks: the size loop's feedback turn must finish, or
      // the parked node could never advance the view.
      if (gate.paused && request.turns.length === 1) await new Promise<void>(resolve => gate.waiters.push(resolve));
      return await defaultSummarizer(request);
    } finally {
      gate.inFlight -= 1;
      compactor.inFlight -= 1;
    }
  };
  return {
    root, home, sessionFile, sessionId, manager, workspace, modelRuntime, model, faux, limits, gate,
    catalogPath: join(home, "workspace", "state", "episodic", sessionId, "catalog.jsonl"),
    nodesPath: join(home, "workspace", "state", "episodic", sessionId, "nodes.jsonl"),
    compactor, summarizer,
  };
}

async function openMemory(fx: Fixture, summarizer?: EpisodicSummarizer): Promise<EpisodicMemory> {
  return EpisodicMemory.open({
    workspace: fx.workspace,
    sessionId: fx.sessionId,
    sessionFile: fx.sessionFile,
    modelRuntime: fx.modelRuntime,
    model: fx.model,
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

function catalogIndexFor(fx: Fixture, entryId: string): number {
  const record = readJsonlSafe(fx.catalogPath).find(candidate => candidate.entryId === entryId);
  expect(record).toBeDefined();
  return record!.index as number;
}

/** The latest record per index, which is the live projection. */
function latestCatalog(path: string): Map<number, Record<string, unknown>> {
  const latest = new Map<number, Record<string, unknown>>();
  for (const record of readJsonlSafe(path)) latest.set(record.index as number, record);
  return latest;
}

function sha(value: string): string {
  return createHash("sha256").update(value).digest("hex").slice(0, 16);
}

// ---- tests ---------------------------------------------------------------------

describe("episodic memory end to end", () => {
  it("keeps the view equal to the durable record fold while ingesting, editing and invalidating", async () => {
    const fx = await fixture("e2e", { viewBytes: 4_096, jobs: 4, retryMs: 1, maxRetries: 2 });
    report.limits = { ...fx.limits };
    const memory = await openMemory(fx);
    const oracle: OracleState = { view: [], messages: 0, nodes: new Map() };
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
      const invalidations = stepRecords.filter(record => typeof record.nodes === "string");
      if (invalidations.length > 0) {
        const predicted = predictedInvalidation(preStepNodes, editIndex);
        const generation = invalidations[0]!.generation as number;
        const addresses = new Set(invalidations.filter(record => record.generation === generation).flatMap(record => decodeCodes(record.nodes as string)));
        report.invalidations.push({ generation, chunks: invalidations.length, invalidated: addresses.size, predicted: predicted.size, nodesBefore: preStepNodes.size });
        expect(addresses).toEqual(predicted);
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
      expect(new Set(status.view.parts.map(part => part.address)).size).toBe(status.view.parts.length);
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
        // An image attachment, a display custom message, a planted credential,
        // and entries that must never become messages.
        fx.manager.appendMessage({ role: "user", content: [{ type: "text", text: `look at this screenshot token ${PLANTED_CREDENTIAL}` }, { type: "image", data: IMAGE_BASE64, mimeType: "image/png" }], timestamp: Date.now() });
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
      .filter(record => typeof record.nodes !== "string" && record.level === 0)
      .sort((a, b) => (a.revision as number) - (b.revision as number))
      .map(record => record.index as number);
    const firstDecrease = levelZeroIndices.findIndex((index, position) => position > 0 && index <= levelZeroIndices[position - 1]!);
    const firstPass = firstDecrease === -1 ? levelZeroIndices.length : firstDecrease;
    expect(levelZeroIndices.slice(0, firstPass)).toEqual([...Array(firstPass).keys()]);
    expect(firstPass).toBe(messagesAtEdit);
    const rebuilt = levelZeroIndices.slice(firstPass).filter(index => index < messagesAtEdit);
    const invalidatedLeaves = readJsonlSafe(fx.nodesPath)
      .filter(record => typeof record.nodes === "string")
      .flatMap(record => decodeCodes(record.nodes as string).filter(entry => entry.endsWith("+1")))
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
      expect(prompt).not.toContain(PLANTED_CREDENTIAL);
      // Every context line is one line: a summary's own newline became a space.
      const chat = prompt.split("<chat>\n")[1]?.split("\n</chat>")[0] ?? "";
      expect(chat.split("\n").every(line => !line.startsWith("LINEBREAK-"))).toBe(true);
    }
    expect(fx.compactor.maxConcurrent).toBeLessThanOrEqual(fx.limits.jobs);
    expect(fx.compactor.maxConcurrent).toBeGreaterThan(1);
    expect(fx.compactor.feedbackTurns).toBeGreaterThan(0);

    const catalogRaw = await readFile(fx.catalogPath, "utf8");
    expect(catalogRaw).not.toContain(THINKING_PREFIX);
    expect(catalogRaw).not.toContain(IMAGE_BASE64);
    expect(catalogRaw).not.toContain(PLANTED_CREDENTIAL);
    expect(catalogRaw).toContain("[image: image/png]");
    // Paths are not credentials: the memory keeps them readable.
    expect(catalogRaw).toContain("/Users/example/project/file-0.ts");
    expect(catalogRaw).not.toContain("[USER_PATH]");
    expect(catalogRaw).toContain("displayed event text");
    expect(catalogRaw).not.toContain("hidden receipt text");
    expect(catalogRaw).not.toContain("bookkeeping");
    expect(catalogRaw).not.toContain("renamed session");

    // A tool result over CAP is capped head and tail, and says so.
    const capped = readJsonlSafe(fx.catalogPath).find(record => typeof record.text === "string" && (record.text as string).includes(CAP_MARKER))!;
    expect(capped).toBeDefined();
    const cappedText = capped.text as string;
    expect(cappedText.startsWith("tool read_file: result ")).toBe(true);
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

  it("serializes concurrent commits: unique contiguous indices and no duplicate view parts", async () => {
    const fx = await fixture("concurrent", { viewBytes: 4_096, jobs: 4, retryMs: 1 });
    const memory = await openMemory(fx);
    for (let index = 0; index < 40; index += 1) {
      fx.manager.appendMessage(userMessage(`concurrent prompt ${index} ${"c".repeat(700)}`));
      fx.manager.appendMessage(fauxAssistantMessage([fauxText(`reply ${index} ${"r".repeat(700)}`)]));
    }
    // Two commits race: ingestion must not interleave index assignment.
    await Promise.all([
      memory.entriesCommitted(fx.sessionId),
      memory.entriesCommitted(fx.sessionId),
    ]);
    const status = memory.status();
    const catalog = readJsonlSafe(fx.catalogPath);
    const latest = latestCatalog(fx.catalogPath);
    const indices = [...latest.keys()].sort((a, b) => a - b);
    report.concurrency = {
      indices: indices.length,
      catalogRecords: catalog.length,
      duplicateViewParts: status.view.parts.length - new Set(status.view.parts.map(part => part.address)).size,
    };
    expect(indices).toEqual([...Array(status.messages).keys()]);
    expect(new Set([...latest.values()].map(record => record.entryId)).size).toBe(status.messages);
    // The second commit saw the cursor and appended nothing.
    expect(catalog.length).toBe(status.messages);
    expect(report.concurrency.duplicateViewParts).toBe(0);
    let cursor = 0;
    for (const part of status.view.parts) {
      expect(part.start).toBe(cursor);
      cursor += part.messages;
    }
    expect(cursor).toBe(status.messages);
    await memory.dispose();
  }, 300_000);

  it("discards a build whose inputs an invalidation revoked while it was in flight", async () => {
    const fx = await fixture("in-flight", { viewBytes: 4_096, jobs: 4, retryMs: 1 });
    const memory = await openMemory(fx);
    for (let index = 0; index < 60; index += 1) {
      fx.manager.appendMessage(userMessage(`in-flight prompt ${index} ${"i".repeat(700)}`));
      fx.manager.appendMessage(fauxAssistantMessage([fauxText(`reply ${index} ${"j".repeat(700)}`)]));
    }
    await memory.entriesCommitted(fx.sessionId);
    const target = fx.manager.getBranch().filter(entry => entry.type === "message")[2]!;
    const editIndex = catalogIndexFor(fx, target.id);
    const nodesBefore = memory.status().nodes.total;
    const promptMark = fx.compactor.prompts.length;

    // Park first attempts, commit more messages, let exactly the next leaf
    // through so a merge becomes startable beside the following leaf, and edit
    // an early message while both are in flight.
    fx.gate.paused = true;
    for (let index = 60; index < 80; index += 1) {
      fx.manager.appendMessage(userMessage(`in-flight prompt ${index} ${"i".repeat(700)}`));
      fx.manager.appendMessage(fauxAssistantMessage([fauxText(`reply ${index} ${"j".repeat(700)}`)]));
    }
    const first = memory.entriesCommitted(fx.sessionId);
    while (memory.status().pump.busy < 1) await new Promise(resolve => setTimeout(resolve, 2));
    fx.gate.waiters.shift()?.();
    while (memory.status().pump.busy < 2) await new Promise(resolve => setTimeout(resolve, 2));
    const inFlight = fx.compactor.prompts.slice(promptMark);
    expect(inFlight.some(prompt => prompt.includes("Compress this message into one line"))).toBe(true);
    expect(inFlight.some(prompt => prompt.includes("Merge these two lines into one"))).toBe(true);

    const preEditNodes = liveNodes(fx);
    fx.manager.appendContextEdit(target.id, { content: "in-flight replacement" });
    const second = memory.entriesCommitted(fx.sessionId);
    // Hold the parked builds until the invalidation is durable: that is the
    // window the reviewer asked for, and it is provable from the log.
    while (!readJsonlSafe(fx.nodesPath).some(record => typeof record.nodes === "string")) await new Promise(resolve => setTimeout(resolve, 2));
    const released = fx.gate.waiters.splice(0);
    fx.gate.paused = false;
    for (const resolve of released) resolve();
    await Promise.all([first, second]);
    while (memory.status().pump.busy > 0) await new Promise(resolve => setTimeout(resolve, 2));

    const invalidations = readJsonlSafe(fx.nodesPath).filter(record => typeof record.nodes === "string");
    const invalidated = new Set(invalidations.flatMap(record => decodeCodes(record.nodes as string)));
    const predicted = predictedInvalidation(preEditNodes, editIndex);
    report.inFlightEdit = { invalidated: invalidated.size, predicted: predicted.size, stalePublished: 0 };
    expect(invalidated.size).toBeGreaterThan(0);
    expect(invalidated).toEqual(predicted);
    expect(memory.status().generation).toBeGreaterThan(0);
    expect(memory.status().messages).toBe(161);
    expect(memory.status().view.unbuilt).toBe(0);
    await memory.dispose();

    // The store must reopen consistently: a stale node published under revoked
    // children would be refused here.
    const reopened = await openMemory(fx);
    expect(reopened.status().nodes.total).toBeGreaterThan(nodesBefore);
    expect(reopened.status().blocked).toBeNull();
    await reopened.entriesCommitted(fx.sessionId);
    expect(reopened.status().view.unbuilt).toBe(0);
    await reopened.dispose();
  }, 300_000);

  it("blocks on a permanent refusal and exhausted retries, and resumes", async () => {
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
    await refused.dispose();
    // The blocked state survives a restart, and resume() with a working
    // compactor recovers it.
    const recovered = await openMemory(fx);
    expect(recovered.status().blocked?.reason).toBe("permanent-failure");
    await recovered.resume();
    expect(recovered.status().blocked).toBeNull();
    expect(recovered.status().nodes.total).toBeGreaterThan(nodesWhenBlocked);
    report.blocked.push({ reason: "permanent-failure", resumed: true, nodesAtBlock: nodesWhenBlocked });
    await recovered.dispose();

    // 2. An auth or configuration error is permanent, not retried.
    const authFixture = await fixture("auth", { viewBytes: 1_024, jobs: 2, retryMs: 1, maxRetries: 3 });
    for (let index = 0; index < 4; index += 1) authFixture.manager.appendMessage(userMessage(`auth case message ${index} ${"x".repeat(600)}`));
    let authAttempts = 0;
    const unauthorized: EpisodicSummarizer = async () => {
      authAttempts += 1;
      throw new Error("401 Unauthorized: invalid api key");
    };
    const unauthorizedMemory = await openMemory(authFixture, unauthorized);
    await unauthorizedMemory.entriesCommitted(authFixture.sessionId);
    expect(unauthorizedMemory.status().blocked?.reason).toBe("permanent-failure");
    expect(authAttempts).toBe(1);
    report.blocked.push({ reason: "permanent-failure", resumed: false, nodesAtBlock: unauthorizedMemory.status().nodes.total });
    await unauthorizedMemory.dispose();

    // 3. A transient failure that never succeeds exhausts its retries; once the
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

  }, 300_000);

  it("charges the provider's total usage when it reports one and every bucket otherwise", async () => {
    const fixtureFor = async (label: string, usage: Usage): Promise<{ fx: Fixture; used: number }> => {
      const fx = await fixture(label, { viewBytes: 1_024, jobs: 1, retryMs: 1 });
      fx.manager.appendMessage(userMessage(`usage case message ${"u".repeat(600)}`));
      // The reply's usage is what the memory records as spend, so the real
      // faux reply is returned with the injected usage.
      const injected: EpisodicSummarizer = async (request) => ({ ...await fx.summarizer(request), usage });
      const memory = await openMemory(fx, injected);
      await memory.entriesCommitted(fx.sessionId);
      expect(memory.status().blocked).toBeNull();
      const snapshot = memory.status().tokens;
      await memory.dispose();
      return { fx, used: snapshot.used };
    };
    // The provider's own total wins when it reports one.
    const withTotal = await fixtureFor("usage-total", { input: 10, output: 5, cacheRead: 7, cacheWrite: 3, totalTokens: 40, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } });
    // Every call is charged the reported total (40), never the bucket sum (24).
    expect(withTotal.used).toBeGreaterThanOrEqual(40);
    expect(withTotal.used % 40).toBe(0);
    expect(withTotal.used % 24).not.toBe(0);
    // Without a reported total, every billed bucket counts, cache reads included.
    const summed = await fixtureFor("usage-sum", { input: 10, output: 5, cacheRead: 7, cacheWrite: 3, totalTokens: undefined as unknown as number, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } });
    expect(summed.used).toBeGreaterThanOrEqual(25);
    expect(summed.used % 25).toBe(0);
    report.usage = { totalTokensUsed: withTotal.used, summedUsageUsed: summed.used };
  }, 300_000);

  it("caps a 1.5 MB paste below the store's line bound and blocks visibly when it cannot", async () => {
    const fx = await fixture("oversized", { viewBytes: 1_024, jobs: 2, retryMs: 1 });
    const paste = `start-of-paste ${"z".repeat(1_500_000)} end-of-paste`;
    fx.manager.appendMessage(userMessage(paste));
    const memory = await openMemory(fx);
    await memory.entriesCommitted(fx.sessionId);
    expect(memory.status().blocked).toBeNull();
    const record = [...latestCatalog(fx.catalogPath).values()].find(candidate => typeof candidate.text === "string" && (candidate.text as string).startsWith("start-of-paste "))!;
    expect(record).toBeDefined();
    const text = record.text as string;
    report.oversized = {
      recordChars: text.length,
      capped: (record.omissions as string[]).includes("capped"),
      headKept: text.startsWith("start-of-paste "),
      tailKept: text.endsWith(" end-of-paste"),
      blockedOnLineBound: null,
    };
    // The cap keeps `recordCapChars` characters of content plus its marker.
    expect(text.length).toBeLessThanOrEqual(fx.limits.recordCapChars + 64);
    expect(text).toContain(CAP_MARKER);
    expect(record.omissions as string[]).toContain("capped");
    expect(text.startsWith("start-of-paste ")).toBe(true);
    expect(text.endsWith(" end-of-paste")).toBe(true);
    // The record the store holds is far below its line bound, and the memory
    // summarized the capped text rather than the paste.
    const raw = await readFile(fx.catalogPath, "utf8");
    expect(Buffer.byteLength(raw.split("\n")[0]!)).toBeLessThan(fx.limits.maxStoreLineBytes);
    expect(fx.compactor.prompts.every(prompt => prompt.length < 500_000)).toBe(true);
    await memory.dispose();

    // A store bound the projection cannot respect is a visible blocked state,
    // never a silent throw with a stalled cursor.
    const tight = await fixture("oversized-blocked", { viewBytes: 1_024, jobs: 2, retryMs: 1, maxStoreLineBytes: 4_096, recordCapChars: 1_000_000 });
    tight.manager.appendMessage(userMessage(`start ${"q".repeat(200_000)}`));
    const tightMemory = await openMemory(tight);
    await tightMemory.entriesCommitted(tight.sessionId);
    report.oversized.blockedOnLineBound = tightMemory.status().blocked?.reason ?? null;
    expect(tightMemory.status().blocked?.reason).toBe("permanent-failure");
    await tightMemory.dispose();
  }, 300_000);

  it("cuts the view at a canonical entry and renders only what precedes it", async () => {
    // The request layer's cut (gist §6): how many summarized messages a turn
    // starting at one canonical entry covers. A turn sends the view up to that
    // cut and nothing after it, so the render must stop there.
    const fx = await fixture("cut", { viewBytes: 4_096, jobs: 2, retryMs: 1 });
    const memory = await openMemory(fx);
    await memory.entriesCommitted(fx.sessionId);
    const first = fx.manager.getBranch()[0]!;
    expect(memory.cutAtEntry(null)).toBe(0);
    expect(memory.cutAtEntry(first.id)).toBe(1);
    expect(memory.cutAtEntry("entry-that-no-branch-holds")).toBeUndefined();

    // A non-message entry between two messages: the cut counts the messages at or
    // before the named entry, whatever the entry's own type is.
    fx.manager.appendMessage(fauxAssistantMessage(fauxText("first reply")));
    fx.manager.appendCustomEntry("tron.bookkeeping", { private: "bookkeeping" });
    const bookkeeping = fx.manager.getLeafId()!;
    fx.manager.appendMessage(userMessage("third message"));
    await memory.entriesCommitted(fx.sessionId);
    expect(memory.cutAtEntry(bookkeeping)).toBe(2);
    const leaf = fx.manager.getLeafId()!;
    expect(memory.cutAtEntry(leaf)).toBe(3);

    const view = memory.renderView(2);
    const lines = view.text.split("\n");
    expect(lines.length).toBeGreaterThan(0);
    expect(view.bytes).toBe(Buffer.byteLength(view.text, "utf8"));
    for (const line of lines) {
      const [address, text] = line.split("|");
      const [start, span] = address!.split("+").map(Number) as [number, number];
      expect(text).toBeTruthy();
      // Nothing covering the third message may be rendered.
      expect(start + span).toBeLessThanOrEqual(2);
    }
    const full = memory.renderView(3);
    expect(full.lines).toBeGreaterThan(view.lines);
    await memory.dispose();
  }, 300_000);
});

/** The live nodes as the oracle sees them, from the durable log. */
function liveNodes(fx: Fixture): Map<string, OracleNode> {
  const nodes = new Map<string, OracleNode>();
  for (const record of readJsonlSafe(fx.nodesPath)) {
    if (typeof record.nodes === "string") {
      for (const code of decodeCodes(record.nodes as string)) nodes.delete(code);
    } else {
      nodes.set(address(record.level as number, record.index as number), {
        level: record.level as number, index: record.index as number, text: record.text as string,
        contextRuns: record.contextRuns as Array<[number, number]>,
      });
    }
  }
  return nodes;
}

/** The catalog's level-0 source lines that do not fit NODE, in index order. */
function catalogLevelZeroTexts(fx: Fixture): string[] {
  return [...latestCatalog(fx.catalogPath).values()]
    .sort((a, b) => (a.index as number) - (b.index as number))
    .filter(record => !record.omitted)
    .map(record => `${record.kind as string}: ${record.text as string}`.replace(/\s+/gu, " ").trim())
    .filter(line => Buffer.byteLength(line, "utf8") > fx.limits.nodeBytes);
}
