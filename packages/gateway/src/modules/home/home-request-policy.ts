import { createHash, randomUUID } from "node:crypto";
import type { Agent, AgentMessage, PrepareRequest, StreamFn } from "../../kernel/pi/agent-core.js";
import { getCurrentSystemMessage, type Tool } from "../../kernel/pi/ai.js";
import {
  estimateTokens,
  type AgentSession,
  type ModelRuntime,
  type SessionProjection,
} from "../../kernel/pi/coding-agent.js";
import { markAnthropicBlocks, shortenLastMessageMark, VIEW_BLOCK_LINES, VIEW_SETTLED_SPAN } from "../../episodic/cache-layout.js";
import { INPUT_TRIGGER_MESSAGE, INPUT_TRIGGER_RESUME_MESSAGE } from "../../kernel/receipts/delivery-tags.js";
import { HOME_TASK_RESULT_MESSAGE } from "../../kernel/receipts/invocation-receipts.js";
import type { HomeContextSection } from "../../protocol/types.js";
import { HomeResponseTiming, type HomeResponseSample } from "./home-response-timing.js";
import { HomeTokenCalibration, type HomeTokenEstimate } from "./home-token-calibration.js";

const HOME_MEMORY_CUSTOM_TYPE = "tron.home-memory.v1";
export const HOME_NONCE_MARKER = "tron.home-nonce:";
const HOME_RESERVE_TOKENS = 1_024;

export type HomeRefusalReason =
  | "no-activation"
  | "system-unavailable"
  | "memory-not-configured"
  | "memory-paused"
  | "memory-blocked"
  | "memory-usage-limit"
  | "memory-unavailable"
  | "memory-boundary-missing"
  | "memory-wait-cancelled"
  | "memory-view-failed"
  | "projection-mismatch"
  | "boundary-not-found"
  | "context-overflow"
  | "stream-nonce"
  | "stream-digest"
  | "stream-replayed"
  | "context-mutated";

const HOME_REFUSAL_SENTENCES: Record<HomeRefusalReason, string> = {
  "no-activation": "no Home activation is open for this provider request.",
  "system-unavailable": "Home's system prompt could not be prepared for this activation.",
  "memory-not-configured": "Home memory is not configured for this conversation.",
  "memory-paused": "Home memory is paused.",
  "memory-blocked": "Home memory is blocked until its source is repaired.",
  "memory-usage-limit": "Home memory's model has reached its usage limit; wait for the limit to reset, or choose another memory model in settings.",
  "memory-unavailable": "Home memory is unavailable for this activation.",
  "memory-boundary-missing": "the Home memory boundary is missing from this conversation.",
  "memory-wait-cancelled": "the wait for Home memory was cancelled.",
  "memory-view-failed": "Home memory could not build its view for this activation.",
  "projection-mismatch": "the conversation changed while this activation was prepared.",
  "boundary-not-found": "the activation's starting point is no longer in the conversation.",
  "context-overflow": "this message and its context exceed the model's window.",
  "stream-nonce": "the activation's view did not carry its nonce exactly once.",
  "stream-digest": "the outgoing request no longer matches the request prepared for it.",
  "stream-replayed": "the activation's view was already consumed by an earlier request.",
  "context-mutated": "the context handlers changed the activation's view.",
};

function homeRefusalMessage(reason: HomeRefusalReason): string {
  return `Home request refused (${reason}): ${HOME_REFUSAL_SENTENCES[reason]}`;
}

type HomeMemoryRefusalReason = Extract<HomeRefusalReason, `memory-${string}`>;

export class HomeMemoryRefusal extends Error {
  constructor(
    readonly reason: HomeMemoryRefusalReason,
    message: string,
  ) {
    super(message);
    this.name = "HomeMemoryRefusal";
  }
}

interface HomeRefusal {
  reason: HomeRefusalReason;
  detail: string;
}

type HomeActivationKind = "user" | "wake";

interface HomeRequestStep {
  effectiveTokens: number;
  viewBytes: number;
  viewLines: number;
  contextWindow: number;
  sections: HomeContextSection[];
}

export interface HomeSystemPrompt {
  instructions: string;
  profile: string;
  profileNotes: number;
  turn: string;
}

export interface HomeActivationIdentity {
  operationId: string;
  nonce: string;
  boundaryEntryId: string | null;
}

export interface HomeActivationView {
  text: string;
  pieces: string[];
  waitedMs: number;
}

export type HomeRequestRecord =
  | HomeResponseSample
  | {
    event: "activation";
    effectiveTokens: number;
    contextWindow: number;
    viewLines: number;
    viewBytes: number;
    excludedMessages: number;
    waitedMs: number;
  }
  | {
    event: "usage";
    estimatedTokens: number;
    providerTokens: number;
  }
  | {
    event: "refused";
    reason: HomeRefusalReason;
    detail: string;
    effectiveTokens?: number;
    contextWindow?: number;
  };

interface HomeRequestPolicyOptions {
  prepareMemoryView: (activation: HomeActivationIdentity, signal: AbortSignal | undefined) => Promise<HomeActivationView>;
  prepareSystemPrompt: (base: string, activation: HomeActivationKind) => Promise<HomeSystemPrompt>;
  onRecord?: (record: HomeRequestRecord) => void;
}

interface HomeActivationEvidence {
  activationStartEntryId: string | null;
  activationOpen: boolean;
  kind: HomeActivationKind;
  startedAt: string;
  step?: HomeRequestStep;
  refusal?: HomeRefusal;
}

export class HomeRequestPolicyError extends Error {
  constructor(
    readonly reason: HomeRefusalReason,
    message: string,
  ) {
    super(message);
    this.name = "HomeRequestPolicyError";
  }
}

interface ActivationState extends HomeActivationIdentity {
  cancellation: AbortController;
  kind: HomeActivationKind;
  startedAt: string;
  systemBase: string;
  system: Promise<HomeSystemPrompt> | undefined;
  view: Promise<HomeActivationView> | undefined;
  viewRefusal: HomeRequestPolicyError | undefined;
  unrecorded: boolean;
  unmeasured: boolean;
  step: HomeRequestStep | undefined;
  sent: { model: string; estimate: HomeTokenEstimate } | undefined;
  refusal: HomeRefusal | undefined;
}

interface TailMessage {
  message: AgentMessage;
  entry: number;
}

interface RewrittenContext {
  messages: AgentMessage[];
  nonSystem: AgentMessage[];
  excludedMessages: number;
  memory: AgentMessage;
  tail: TailMessage[];
}

const MAXIMUM_RECORDED_TRANSFORMS = 64;

export class HomeRequestPolicy {
  readonly inputCancellation = { epoch: 0 };
  private activation: ActivationState | undefined;
  private lastClosed: HomeActivationEvidence | undefined;
  private expectedDigest: string | undefined;
  private expectedNonSystemMessages: AgentMessage[] | undefined;
  private readonly transformIdentities: boolean[] = [];
  private readonly calibration = new HomeTokenCalibration();

  readonly responseTiming: HomeResponseTiming;

  constructor(private readonly options: HomeRequestPolicyOptions) {
    this.responseTiming = new HomeResponseTiming(sample => options.onRecord?.(sample));
  }

  recentTransformIdentities(): readonly boolean[] {
    return this.transformIdentities;
  }

  contextEvidence(): HomeActivationEvidence | undefined {
    const activation = this.activation;
    if (activation) {
      return {
        activationStartEntryId: activation.boundaryEntryId,
        activationOpen: true,
        kind: activation.kind,
        startedAt: activation.startedAt,
        ...(activation.step ? { step: activation.step } : {}),
        ...(activation.refusal ? { refusal: activation.refusal } : {}),
      };
    }
    return this.lastClosed;
  }

  admit(operationId: string, boundaryEntryId: string | null, systemBase: string, kind: HomeActivationKind): void {
    this.activation?.cancellation.abort();
    this.activation = {
      operationId,
      nonce: randomUUID(),
      cancellation: new AbortController(),
      kind,
      startedAt: new Date().toISOString(),
      boundaryEntryId,
      systemBase,
      system: undefined,
      view: undefined,
      viewRefusal: undefined,
      unrecorded: true,
      unmeasured: true,
      step: undefined,
      sent: undefined,
      refusal: undefined,
    };
    this.expectedDigest = undefined;
    this.expectedNonSystemMessages = undefined;
  }

  settle(operationId: string | undefined): void {
    if (!operationId) return;
    const activation = this.activation;
    if (activation?.operationId !== operationId) return;
    this.lastClosed = {
      activationStartEntryId: activation.boundaryEntryId,
      activationOpen: false,
      kind: activation.kind,
      startedAt: activation.startedAt,
      ...(activation.step ? { step: activation.step } : {}),
      ...(activation.refusal ? { refusal: activation.refusal } : {}),
    };
    activation.cancellation.abort();
    this.activation = undefined;
    this.expectedDigest = undefined;
    this.expectedNonSystemMessages = undefined;
  }

  transferOperation(from: string | undefined, to: string): void {
    if (!from || from === to) return;
    this.responseTiming.transfer(from, to);
    if (this.activation?.operationId !== from) return;
    this.activation.operationId = to;
  }

  cancel(operationId: string | undefined): void {
    if (operationId && this.activation?.operationId === operationId) this.activation.cancellation.abort();
  }

  async deliveryHeadroom(session: AgentSession, input: AgentMessage, systemPrompt: string, signal?: AbortSignal): Promise<{ tokens: number; freshTokens: number; signal: AbortSignal }> {
    const activation = this.requireActivation();
    const view = await this.memoryView(activation, signal);
    activation.cancellation.signal.throwIfAborted();
    signal?.throwIfAborted();
    const projection = session.sessionManager.buildSessionProjection();
    const cut = this.cut(projection, this.boundaryIndex(projection, activation), activation, view, "");
    const window = session.model?.contextWindow ?? 0;
    const memory = estimateTokens(cut.memory);
    const other = cut.tail.reduce((total, item) => total + estimateTokens(item.message), 0) + estimateTokens(systemMessage(systemPrompt, { toolsAdded: session.agent.state.tools, timestamp: 0 }));
    const scale = this.calibration.factors(modelKey(session.model));
    const prefix = Math.ceil(memory * scale.memory + other * scale.other);
    const freshTokens = Math.floor(Math.max(0, window - HOME_RESERVE_TOKENS - prefix) / scale.other);
    return { tokens: Math.max(0, freshTokens - estimateTokens(input)), freshTokens, signal: activation.cancellation.signal };
  }

  wrapPrepareRequest(session: AgentSession, inner: PrepareRequest | undefined): PrepareRequest {
    return async (request, signal) => {
      const update = inner ? await inner(request, signal) : undefined;
      const context = update?.context ?? request.context;
      const activation = this.requireActivation();
      const projectionBefore = session.sessionManager.buildSessionProjection();
      this.assertProjectionFidelity(context.messages, projectionBefore, activation);
      const boundaryBefore = this.boundaryIndex(projectionBefore, activation);
      const excludedBefore = excludedMessages(projectionBefore, boundaryBefore);
      const system = await this.systemPromptFor(activation);
      const memoryView = await this.memoryView(activation, signal);
      const projection = session.sessionManager.buildSessionProjection();
      const boundaryIndex = this.boundaryIndex(projection, activation);
      const excluded = excludedMessages(projection, boundaryIndex);
      if (!messagesMatch(excludedBefore, excluded)) {
        throw this.refuse(
          "projection-mismatch",
          `the history before this activation changed while it waited for its memory (`
          + `${excludedBefore.length} to ${excluded.length} excluded messages)`,
          activation,
        );
      }
      const rewritten = this.cut(projection, boundaryIndex, activation, memoryView, system.turn);
      const model = update?.model ?? request.model;
      const estimated = requestSections(system, rewritten, memoryView, activation.kind);
      const scale = this.calibration.factors(modelKey(model));
      const sections = estimated.map(section => ({ ...section, tokens: Math.ceil(section.tokens * (section.id === "memory" ? scale.memory : scale.other)) }));
      const effectiveTokens = sections.reduce((total, section) => total + section.tokens, 0);
      const contextWindow = model?.contextWindow ?? 0;
      if (contextWindow > 0 && effectiveTokens > contextWindow - HOME_RESERVE_TOKENS) {
        throw this.refuse(
          "context-overflow",
          `effective ${effectiveTokens} tokens leave no head-room below the ${contextWindow}-token window`,
          activation,
          { effectiveTokens, contextWindow },
        );
      }
      const memoryEstimate = estimated.find(section => section.id === "memory")?.tokens ?? 0;
      activation.sent = { model: modelKey(model), estimate: { memory: memoryEstimate,
        other: estimated.reduce((total, section) => total + section.tokens, 0) - memoryEstimate } };
      this.expectedNonSystemMessages = rewritten.nonSystem;
      const viewBytes = utf8Bytes(memoryView.text);
      const viewLines = memoryView.text === "" ? 0 : memoryView.text.split("\n").length;
      activation.step = { effectiveTokens, viewBytes, viewLines, contextWindow, sections };
      if (activation.unrecorded) {
        activation.unrecorded = false;
        this.options.onRecord?.({
          event: "activation",
          effectiveTokens,
          contextWindow,
          viewLines,
          viewBytes,
          excludedMessages: rewritten.excludedMessages,
          waitedMs: memoryView.waitedMs,
        });
      }
      return { ...update, context: { ...context, messages: rewritten.messages } };
    };
  }

  wrapTransformContext(
    inner: ((messages: AgentMessage[], signal?: AbortSignal) => Promise<AgentMessage[]>) | undefined,
    convertMessages: Agent["convertToLlm"],
  ): (messages: AgentMessage[], signal?: AbortSignal) => Promise<AgentMessage[]> {
    return async (messages, signal) => {
      const activation = this.requireActivation();
      const transformed = inner ? await inner(messages, signal) : messages;
      const occurrences = countNonce(transformed, activation.nonce);
      if (occurrences !== 1) {
        throw this.refuse(
          "stream-nonce",
          `the activation view carried the nonce ${occurrences} times after the context handlers, expected once`,
          activation,
        );
      }
      const framed = homeSystemFrame(transformed, homeSystemText(await this.systemPromptFor(activation)));
      this.assertContextNotMutated(framed, activation);
      this.expectedDigest = digestLlmMessages(await convertMessages(framed));
      return framed;
    };
  }

  wrapStreamFunction(stream: StreamFn): StreamFn {
    return (model, context, options) => {
      const activation = this.requireActivation();
      const occurrences = countNonce(context.messages as readonly unknown[], activation.nonce);
      if (occurrences !== 1) {
        throw this.refuse(
          "stream-nonce",
          `the outgoing request carried the activation nonce ${occurrences} times instead of once`,
        );
      }
      const expected = this.expectedDigest;
      this.expectedDigest = undefined;
      if (expected === undefined) {
        throw this.refuse(
          "stream-replayed",
          "this request had no fresh context pass; the activation view was already consumed",
        );
      }
      const digest = digestLlmMessages(context.messages);
      if (digest !== expected) {
        throw this.refuse(
          "stream-digest",
          "the outgoing request no longer matches the request the context handlers prepared",
        );
      }
      const finish = this.responseTiming.model(activation.operationId);
      const step = activation.step;
      const sent = activation.sent;
      try {
        const result = stream(model, context, options);
        void Promise.resolve(result).then((stream) => stream.result()).then((message) => {
          finish();
          if (step && sent) this.measure(activation, step, sent, message.usage.input + message.usage.cacheRead + message.usage.cacheWrite);
        }, finish).catch(() => {});
        return result;
      } catch (error) {
        finish();
        throw error;
      }
    };
  }

  private measure(activation: ActivationState, step: HomeRequestStep, sent: NonNullable<ActivationState["sent"]>, providerTokens: number): void {
    if (!this.calibration.observe(sent.model, activation.nonce, sent.estimate, providerTokens)) return;
    if (activation.unmeasured) {
      activation.unmeasured = false;
      this.options.onRecord?.({ event: "usage", estimatedTokens: step.effectiveTokens, providerTokens });
    }
    const estimated = step.effectiveTokens;
    let assigned = 0;
    for (const section of step.sections) {
      section.tokens = Math.floor(section.tokens * providerTokens / estimated);
      assigned += section.tokens;
    }
    const largest = step.sections.reduce((best, section) => section.tokens > best.tokens ? section : best);
    largest.tokens += providerTokens - assigned;
    step.effectiveTokens = providerTokens;
  }

  private requireActivation(): ActivationState {
    const activation = this.activation;
    if (!activation) {
      throw this.refuse("no-activation", "a provider request was attempted with no open Home activation");
    }
    return activation;
  }

  private async memoryView(activation: ActivationState, signal: AbortSignal | undefined): Promise<HomeActivationView> {
    if (activation.viewRefusal) throw activation.viewRefusal;
    activation.view ??= (async () => {
      try {
        return await this.options.prepareMemoryView(activationIdentity(activation), signal ? AbortSignal.any([signal, activation.cancellation.signal]) : activation.cancellation.signal);
      } catch (error) {
        throw (activation.viewRefusal = this.viewRefusal(error, activation));
      }
    })();
    return activation.view;
  }

  private systemPromptFor(activation: ActivationState): Promise<HomeSystemPrompt> {
    activation.system ??= this.options.prepareSystemPrompt(activation.systemBase, activation.kind).catch(error => {
      throw this.refuse("system-unavailable", error instanceof Error ? error.message : String(error), activation);
    });
    return activation.system;
  }

  private viewRefusal(error: unknown, activation: ActivationState): HomeRequestPolicyError {
    const detail = error instanceof Error ? error.message : String(error);
    if (error instanceof HomeMemoryRefusal) return this.refuse(error.reason, detail, activation);
    return this.refuse("memory-view-failed", detail, activation);
  }

  private boundaryIndex(projection: SessionProjection, activation: ActivationState): number {
    if (activation.boundaryEntryId === null) return -1;
    const index = projection.entries.findIndex(
      (entry) => entry.sourceEntry.id === activation.boundaryEntryId,
    );
    if (index < 0) {
      throw this.refuse(
        "boundary-not-found",
        `activation boundary ${activation.boundaryEntryId} is not in the current projection`,
        activation,
      );
    }
    return index;
  }

  private assertProjectionFidelity(
    expected: readonly AgentMessage[],
    projection: SessionProjection,
    activation: ActivationState,
  ): void {
    const canonical = projection.messages;
    if (expected.length !== canonical.length) {
      throw this.refuse(
        "projection-mismatch",
        `request context carries ${expected.length} messages but the canonical projection has ${canonical.length}`,
        activation,
      );
    }
    for (let index = 0; index < canonical.length; index++) {
      const candidate = expected[index];
      const current = canonical[index];
      if (candidate === current) continue;
      if (JSON.stringify(candidate) !== JSON.stringify(current)) {
        throw this.refuse(
          "projection-mismatch",
          `request context message ${index} differs from the canonical projection`,
          activation,
        );
      }
    }
  }

  private assertContextNotMutated(transformed: readonly AgentMessage[], activation: ActivationState): void {
    const expected = this.expectedNonSystemMessages;
    if (!expected) {
      throw this.refuse(
        "context-mutated",
        "the context handlers ran without an activation view prepared for this request",
        activation,
      );
    }
    const actual = transformed.filter((message) => message.role !== "system");
    if (actual.length !== expected.length) {
      throw this.refuse(
        "context-mutated",
        `the context handlers returned ${actual.length} non-system messages but the activation view has ${expected.length}`,
        activation,
      );
    }
    let identical = true;
    for (let index = 0; index < expected.length; index++) {
      const candidate = actual[index];
      const prepared = expected[index];
      if (candidate === prepared) continue;
      identical = false;
      if (JSON.stringify(candidate) !== JSON.stringify(prepared)) {
        throw this.refuse(
          "context-mutated",
          `the context handlers changed non-system message ${index} of the activation view`,
          activation,
        );
      }
    }
    this.transformIdentities.push(identical);
    if (this.transformIdentities.length > MAXIMUM_RECORDED_TRANSFORMS) this.transformIdentities.shift();
  }

  private cut(
    projection: SessionProjection,
    boundaryIndex: number,
    activation: ActivationState,
    memoryView: HomeActivationView,
    turn: string,
  ): RewrittenContext {
    const systems: AgentMessage[] = [];
    const tail: TailMessage[] = [];
    let excludedMessages = 0;
    projection.entries.forEach((entry, index) => {
      const withinActivation = index > boundaryIndex;
      for (const message of entry.messages as AgentMessage[]) {
        if (message.role === "system") {
          systems.push(message);
          continue;
        }
        if (withinActivation) tail.push({ message, entry: index });
        else excludedMessages += 1;
      }
    });
    const memory: AgentMessage = {
      role: "custom",
      customType: HOME_MEMORY_CUSTOM_TYPE,
      content: [
        ...memoryView.pieces.map((text) => ({ type: "text" as const, text })),
        { type: "text" as const, text: turn },
        { type: "text" as const, text: `${HOME_NONCE_MARKER}${activation.nonce}` },
      ],
      display: false,
      details: undefined,
      timestamp: Date.now(),
    } as unknown as AgentMessage;
    const messages = tail.map(item => item.message);
    return {
      messages: [...systems, memory, ...messages],
      nonSystem: [memory, ...messages],
      excludedMessages,
      memory,
      tail,
    };
  }

  private refuse(
    reason: HomeRefusalReason,
    detail: string,
    activation?: ActivationState,
    sizes?: { effectiveTokens: number; contextWindow: number },
  ): HomeRequestPolicyError {
    const open = activation ?? this.activation;
    if (open) open.refusal = { reason, detail };
    this.options.onRecord?.({ event: "refused", reason, detail, ...(sizes ?? {}) });
    return new HomeRequestPolicyError(reason, homeRefusalMessage(reason));
  }
}

function modelKey(model: { provider: string; id: string } | undefined): string {
  return model ? `${model.provider}/${model.id}` : "";
}

function homeSystemText(prompt: HomeSystemPrompt): string {
  return `${prompt.instructions}\n\n${prompt.profile}`;
}

function isTaskResult(message: AgentMessage): boolean {
  return message.role === "custom" && [HOME_TASK_RESULT_MESSAGE, INPUT_TRIGGER_MESSAGE, INPUT_TRIGGER_RESUME_MESSAGE].includes((message as { customType: string }).customType);
}

const MEMORY_SUMMARY_LINE = /^\d+\+\d+\|/u;

function requestSections(system: HomeSystemPrompt, cut: RewrittenContext, view: HomeActivationView,
  kind: HomeActivationKind): HomeContextSection[] {
  const tail = cut.tail;
  let inputAt = -1;
  if (kind === "user") inputAt = tail.findIndex(item => item.message.role === "user");
  else for (let index = tail.length - 1; index >= 0 && inputAt < 0; index--) {
    if (isTaskResult(tail[index]!.message)) inputAt = index;
  }
  let inputTokens = 0;
  let resultTokens = 0;
  let results = 0;
  let chapterTokens = 0;
  const chapterEntries = new Set<number>();
  tail.forEach((item, index) => {
    const tokens = estimateTokens(item.message);
    if (index === inputAt) inputTokens = tokens;
    else if (isTaskResult(item.message)) { resultTokens += tokens; results += 1; }
    else { chapterTokens += tokens; chapterEntries.add(item.entry); }
  });
  const summaries = view.text === "" ? 0 : view.text.split("\n").filter(line => MEMORY_SUMMARY_LINE.test(line)).length;
  return [
    { id: "instructions", tokens: estimateTokens(systemMessage(system.instructions, getCurrentSystemMessage(cut.messages as never))) },
    { id: "profile", tokens: estimateTokens(systemMessage(`${system.profile}\n${system.turn}`)), count: system.profileNotes },
    { id: "memory", tokens: estimateTokens(cut.memory) - estimateTokens(systemMessage(system.turn)), count: summaries },
    { id: "chapter", tokens: chapterTokens, count: chapterEntries.size },
    { id: "results", tokens: resultTokens, count: results },
    { id: "input", tokens: inputTokens },
  ];
}

function systemMessage(text: string, current?: { toolsAdded?: Tool[]; timestamp: number }): AgentMessage {
  const toolsAdded = current?.toolsAdded;
  return { role: "system", content: text, ...(toolsAdded ? { toolsAdded } : {}), timestamp: current?.timestamp ?? 0 } as AgentMessage;
}

function homeSystemFrame(messages: readonly AgentMessage[], system: string): AgentMessage[] {
  return [systemMessage(system, getCurrentSystemMessage(messages as never)), ...messages.filter(message => message.role !== "system")];
}

function excludedMessages(projection: SessionProjection, boundaryIndex: number): AgentMessage[] {
  const messages: AgentMessage[] = [];
  projection.entries.forEach((entry, index) => {
    if (index <= boundaryIndex) messages.push(...entry.messages as AgentMessage[]);
  });
  return messages;
}

function messagesMatch(left: readonly AgentMessage[], right: readonly AgentMessage[]): boolean {
  if (left.length !== right.length) return false;
  for (let index = 0; index < left.length; index += 1) {
    if (left[index] === right[index]) continue;
    if (JSON.stringify(left[index]) !== JSON.stringify(right[index])) return false;
  }
  return true;
}

function activationIdentity(activation: ActivationState): HomeActivationIdentity {
  return {
    operationId: activation.operationId,
    nonce: activation.nonce,
    boundaryEntryId: activation.boundaryEntryId,
  };
}

function digestLlmMessages(messages: unknown): string {
  return createHash("sha256").update(JSON.stringify(messages)).digest("hex");
}

export function markHomeMemoryCache(payload: unknown): unknown {
  const messages = (payload as { messages?: unknown } | null)?.messages;
  if (!Array.isArray(messages)) return payload;
  const index = messages.findIndex((message) => {
    const content = (message as { content?: unknown } | null)?.content;
    const last = Array.isArray(content) ? content.at(-1) as { type?: unknown; text?: unknown } | undefined : undefined;
    return last?.type === "text" && typeof last.text === "string" && last.text.startsWith(HOME_NONCE_MARKER);
  });
  if (index < 0) return payload;
  const blocks = (messages[index] as { content: unknown[] }).content;
  let mark = blocks.length - 4;
  if (mark < 0) return payload;
  const lines = viewGroupLines(blocks[mark]);
  if (lines !== undefined && lines < VIEW_BLOCK_LINES) mark -= 1;
  const settled = settledBlock(blocks, mark);
  const both = settled === undefined ? payload : markAnthropicBlocks(payload, index, [settled, mark]);
  return shortenLastMessageMark(both === payload ? markAnthropicBlocks(payload, index, [mark]) : both, index);
}

function viewGroupText(block: unknown): string | undefined {
  const text = (block as { type?: unknown; text?: unknown } | null)?.text;
  if ((block as { type?: unknown } | null)?.type !== "text" || typeof text !== "string") return undefined;
  return /^(?:\d+\+\d+\|[^\n]*\n)+$/u.test(text) ? text : undefined;
}

function viewGroupLines(block: unknown): number | undefined {
  const text = viewGroupText(block);
  return text === undefined ? undefined : text.split("\n").length - 1;
}

function settledBlock(blocks: readonly unknown[], before: number): number | undefined {
  let settled: number | undefined;
  for (let at = 0; at < before; at += 1) {
    const text = viewGroupText(blocks[at]);
    if (text === undefined) {
      if (settled === undefined) continue;
      break;
    }
    const spans = [...text.matchAll(/^\d+\+(\d+)\|/gmu)].map((line) => Number(line[1]));
    if (spans.length < VIEW_BLOCK_LINES || spans.some((span) => span < VIEW_SETTLED_SPAN)) break;
    settled = at;
  }
  return settled;
}

export function applyHomeCacheRetention(runtime: ModelRuntime): ModelRuntime {
  const stream = runtime.streamSimple.bind(runtime);
  runtime.streamSimple = ((model, context, options) =>
    stream(model, context, { ...options, cacheRetention: options?.cacheRetention ?? "long" })) as ModelRuntime["streamSimple"];
  return runtime;
}

function countNonce(messages: readonly unknown[], nonce: string): number {
  return JSON.stringify(messages).split(nonce).length - 1;
}

function utf8Bytes(text: string): number {
  return Buffer.byteLength(text, "utf8");
}
