import { createHash, randomUUID } from "node:crypto";
import type { Agent, AgentMessage, PrepareRequest, StreamFn } from "@earendil-works/pi-agent-core";
import {
  estimateTokens,
  type AgentSession,
  type ModelRuntime,
  type SessionProjection,
} from "@earendil-works/pi-coding-agent";
import { markAnthropicBlocks } from "../episodic/cache-layout.js";

/*
 * Tron Home's request seam (gist §7).
 *
 * A Home activation is one admitted input and everything it triggers: its tool
 * loop, the SDK's retries and continuations, and any steering or follow-up that
 * joins the same run. Every provider request of an activation carries only:
 *
 *   1. the system messages that precede the activation's start entry,
 *   2. ONE request-local memory view frozen for that activation, and
 *   3. the activation's native messages, from its exact start entry onward.
 *
 * Prior activations are never re-sent, and the memory view is never persisted:
 * Home's continuity is the memory, not the transcript.
 *
 * The seam is three wrappers, outermost first:
 *
 *  - `wrapPrepareRequest` replaces the messages the agent loop is about to
 *    convert. It is installed outermost, so the context it rewrites is the
 *    SDK's own canonical projection.
 *  - `wrapTransformContext` is installed outermost on `Agent.transformContext`,
 *    i.e. after every SDK context stage, and records the single-use expectation
 *    for the provider request. A digest taken at `prepareRequest` time can never
 *    match: the SDK's extension `context` handlers, hidden-declaration
 *    projection and forced-prompt projection all run after the outermost
 *    `prepareRequest`, and the last of them rewrites the leading system message
 *    (#412 qualification).
 *  - `wrapStreamFunction` is installed INNERMOST on the provider stream, so it
 *    validates the exact request the provider-facing base stream receives, after
 *    `abortAwareStream` and the compaction policy's rewrite. An outermost guard
 *    would run before those and never see the compaction summary focus.
 *
 * Every wrapper fails closed: no open activation, no provider request. The
 * refusal is a canonical assistant error entry the user can read, never a
 * retried provider call.
 */

/** Custom-message type of the in-request memory view. It is never persisted. */
const HOME_MEMORY_CUSTOM_TYPE = "tron.home-memory.v1";
/** Marker prefix that makes the activation nonce greppable in one request. */
export const HOME_NONCE_MARKER = "tron.home-nonce:";
/** Head-room kept below the model's context window by every Home request. */
const HOME_RESERVE_TOKENS = 1_024;

/** Why a Home request was refused. Bounded and reported; observable. */
export type HomeRefusalReason =
  | "no-activation"
  | "memory-not-configured"
  | "memory-paused"
  | "memory-blocked"
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

/**
 * The text an SDK-visible refusal carries: one fixed sentence per reason. Pi's
 * transient-error classifier matches substrings of the error text (`500`, `timeout`,
 * `overloaded`, a retry phrase), so a refusal that embeds a count, an ID, a path or a
 * memory message can be retried as if the provider failed, and a deterministic refusal
 * then runs its retry budget. The variable detail stays on the refusal record that
 * `home.context` reports (`lastRefusalReason`, `lastRefusalDetail`).
 */
export const HOME_REFUSAL_SENTENCES: Record<HomeRefusalReason, string> = {
  "no-activation": "no Home activation is open for this provider request.",
  "memory-not-configured": "Home memory is not configured for this conversation.",
  "memory-paused": "Home memory is paused.",
  "memory-blocked": "Home memory is blocked until its source is repaired.",
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

/** The SDK-visible message of a refusal: the reason and its fixed sentence. */
export function homeRefusalMessage(reason: HomeRefusalReason): string {
  return `Home request refused (${reason}): ${HOME_REFUSAL_SENTENCES[reason]}`;
}

/** The memory reasons a view source may raise. */
export type HomeMemoryRefusalReason = Extract<HomeRefusalReason, `memory-${string}`>;

/**
 * What the memory view source refuses with. The seam keeps the memory's own
 * reason, because "not configured" and "blocked" are states the user fixes while
 * "the view source threw" is a defect; both fail closed with zero requests.
 */
export class HomeMemoryRefusal extends Error {
  constructor(
    readonly reason: HomeMemoryRefusalReason,
    message: string,
  ) {
    super(message);
    this.name = "HomeMemoryRefusal";
  }
}

/** The refusal an activation ended with, as `home.context` reports it. */
export interface HomeRefusal {
  reason: HomeRefusalReason;
  detail: string;
}

/** The sizes of the last request one activation prepared, as `home.context` reports them. */
export interface HomeRequestStep {
  /** Effective-size estimate of the rewritten context, in tokens. */
  effectiveTokens: number;
  /** UTF-8 bytes and lines of the frozen memory view this request carried. */
  viewBytes: number;
  viewLines: number;
  /** The model's context window this activation was measured against, 0 when the
   * model declares none. */
  contextWindow: number;
}

/** What identifies one activation to the memory view source. */
export interface HomeActivationIdentity {
  operationId: string;
  nonce: string;
  /** The canonical leaf captured immediately before the input reached Pi. */
  boundaryEntryId: string | null;
}

/** The frozen view one activation receives, and how long it waited for it. */
export interface HomeActivationView {
  text: string;
  /** The view as request blocks (`viewPieces`); they rejoin to `text`. */
  pieces: string[];
  /** Records that a request carrying this view was prepared, so the next
   * activation's blocks start where this one ended. Called after every refusal
   * check: a refused activation sends nothing, and must not move it. */
  commit: () => void;
  /** Milliseconds spent waiting for the memory to cover the activation's start;
   * 0 when every line it needed was already built. */
  waitedMs: number;
}

/**
 * One bounded record per activation and per refusal. Home is used deliberately,
 * one turn at a time, so one line per activation is the only place the effective
 * size of a request and the readiness wait are visible at all; nothing here
 * carries message text, an entry id or the activation nonce.
 */
export type HomeRequestRecord =
  | {
    event: "activation";
    /** Effective-size estimate of the request this activation sent, in tokens. */
    effectiveTokens: number;
    contextWindow: number;
    viewLines: number;
    viewBytes: number;
    excludedMessages: number;
    waitedMs: number;
  }
  | {
    event: "refused";
    reason: HomeRefusalReason;
    detail: string;
    effectiveTokens?: number;
    contextWindow?: number;
  };

export interface HomeRequestPolicyOptions {
  /**
   * The frozen memory view for one activation. Called at most once per
   * activation, at its first `prepareRequest` step; a throw or rejection fails
   * that activation closed before any provider call. The wait for the memory to
   * cover the activation start is abortable through the request's signal.
   */
  prepareMemoryView: (activation: HomeActivationIdentity, signal: AbortSignal | undefined) => Promise<HomeActivationView>;
  /** Where the seam reports its bounded per-activation and refusal records. */
  onRecord?: (record: HomeRequestRecord) => void;
}

/** The evidence of one activation, as `home.context` reports it. Only fields of
 * that activation: its start entry, whether it is open, the last request it
 * prepared, and its own refusal when it was refused. */
export interface HomeActivationEvidence {
  activationStartEntryId: string | null;
  activationOpen: boolean;
  step?: HomeRequestStep;
  refusal?: HomeRefusal;
}

/** Raised for every refusal. Never retryable and never provider-visible. */
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
  view: Promise<HomeActivationView> | undefined;
  viewRefusal: HomeRequestPolicyError | undefined;
  /** True while this activation's first request has not been recorded yet. */
  unrecorded: boolean;
  /** The last request this activation prepared. */
  step: HomeRequestStep | undefined;
  /** This activation's own last refusal, if it was refused. */
  refusal: HomeRefusal | undefined;
}

interface RewrittenContext {
  messages: AgentMessage[];
  /** The memory message plus the activation's native messages, in request order. */
  nonSystem: AgentMessage[];
  excludedMessages: number;
}

const MAXIMUM_RECORDED_TRANSFORMS = 64;

export class HomeRequestPolicy {
  private activation: ActivationState | undefined;
  /** The last settled activation's evidence, kept so `home.context` can report
   * it after the run ends. Replaced whole, never merged field by field. */
  private lastClosed: HomeActivationEvidence | undefined;
  private expectedDigest: string | undefined;
  /** The exact non-system request messages `prepareRequest` returned for the current request. */
  private expectedNonSystemMessages: AgentMessage[] | undefined;
  /** Whether each recent `transformContext` pass kept the activation's non-system
   * messages by object identity, oldest first. Bounded, and surviving settlement. */
  private readonly transformIdentities: boolean[] = [];

  constructor(private readonly options: HomeRequestPolicyOptions) {}

  /** The SDK's context stage clones messages, so this is the one place the
   * identity claim is observed rather than inferred (the fidelity check's
   * equal-value fallback is what Gateway sessions use). */
  recentTransformIdentities(): readonly boolean[] {
    return this.transformIdentities;
  }

  /**
   * The evidence of Home's current or last activation: the start entry `admit`
   * captured, whether it is still open, the last request it prepared, and its own
   * refusal. `undefined` before the first activation.
   */
  contextEvidence(): HomeActivationEvidence | undefined {
    const activation = this.activation;
    if (activation) {
      return {
        activationStartEntryId: activation.boundaryEntryId,
        activationOpen: true,
        ...(activation.step ? { step: activation.step } : {}),
        ...(activation.refusal ? { refusal: activation.refusal } : {}),
      };
    }
    return this.lastClosed;
  }

  /**
   * Opens an activation for `operationId`. `boundaryEntryId` is the canonical
   * leaf captured immediately before the input reached Pi, which is the exact
   * activation start: the input's own entry is appended inside `session.prompt`
   * afterwards, and steering later inserts entries after it, never before it.
   */
  admit(operationId: string, boundaryEntryId: string | null): void {
    // A displaced activation means the previous operation settled without a
    // matching `settle`, or a new run began first. Replacing it is the only safe
    // choice: the old boundary can no longer be trusted.
    this.activation?.cancellation.abort();
    this.activation = {
      operationId,
      nonce: randomUUID(),
      cancellation: new AbortController(),
      boundaryEntryId,
      view: undefined,
      viewRefusal: undefined,
      unrecorded: true,
      step: undefined,
      refusal: undefined,
    };
    this.expectedDigest = undefined;
    this.expectedNonSystemMessages = undefined;
  }

  /** Closes the activation when Tron settles that exact operation. */
  settle(operationId: string | undefined): void {
    if (!operationId) return;
    const activation = this.activation;
    if (activation?.operationId !== operationId) return;
    // The whole activation moves, so `home.context` can never report one
    // activation's start entry with another's sizes.
    this.lastClosed = {
      activationStartEntryId: activation.boundaryEntryId,
      activationOpen: false,
      ...(activation.step ? { step: activation.step } : {}),
      ...(activation.refusal ? { refusal: activation.refusal } : {}),
    };
    activation.cancellation.abort();
    this.activation = undefined;
    this.expectedDigest = undefined;
    this.expectedNonSystemMessages = undefined;
  }

  /**
   * Follows a foreground ownership transfer inside one activation.
   *
   * Tron reassigns `activeOperationId` when a dequeued follow-up retrospectively
   * takes over the already-started run and when a queue admission is
   * reclassified as an ordinary prompt. The run, its boundary entry and its
   * frozen memory view are unchanged — only the operation identity Tron reports
   * is — so the activation is renamed, or its later `settle` would never match
   * and it would outlive the run.
   */
  transferOperation(from: string | undefined, to: string): void {
    if (!from || from === to) return;
    if (this.activation?.operationId !== from) return;
    this.activation.operationId = to;
  }

  /** Stop addresses this exact activation, including its pre-provider view wait. */
  cancel(operationId: string | undefined): void {
    if (operationId && this.activation?.operationId === operationId) this.activation.cancellation.abort();
  }

  /** Use the same frozen view and cut as preparation, before inbox writes.
   * Fresh headroom excludes the incoming message, not the durable memory prefix. */
  async deliveryHeadroom(session: AgentSession, input: AgentMessage, systemPrompt: string, signal?: AbortSignal): Promise<{ tokens: number; freshTokens: number; signal: AbortSignal }> {
    const activation = this.requireActivation();
    const view = await this.memoryView(activation, signal);
    activation.cancellation.signal.throwIfAborted();
    signal?.throwIfAborted();
    const projection = session.sessionManager.buildSessionProjection();
    const cut = this.cut(projection, this.boundaryIndex(projection, activation), activation, view);
    const window = session.model?.contextWindow ?? 0;
    const nonSystem = cut.messages.filter(message => message.role !== "system").reduce((total, message) => total + estimateTokens(message), 0);
    const recordedSystem = cut.messages.filter(message => message.role === "system").reduce((total, message) => total + estimateTokens(message), 0);
    const incomingSystem = estimateTokens({ role: "system", content: systemPrompt, timestamp: Date.now() });
    const prefix = nonSystem + Math.max(recordedSystem, incomingSystem);
    const freshTokens = Math.max(0, window - HOME_RESERVE_TOKENS - prefix);
    return { tokens: Math.max(0, freshTokens - estimateTokens(input)), freshTokens, signal: activation.cancellation.signal };
  }

  /** Outer `Agent.prepareRequest`: rebuild the request from the activation, not from canonical history. */
  wrapPrepareRequest(session: AgentSession, inner: PrepareRequest | undefined): PrepareRequest {
    return async (request, signal) => {
      const update = inner ? await inner(request, signal) : undefined;
      const context = update?.context ?? request.context;
      const activation = this.requireActivation();
      // The projection, and the proof that the request is exactly it, come FIRST:
      // a request some other `prepareRequest` rewrite changed is a refusal, not
      // something to spend a multi-second memory wait on.
      const projectionBefore = session.sessionManager.buildSessionProjection();
      this.assertProjectionFidelity(context.messages, projectionBefore, activation);
      const boundaryBefore = this.boundaryIndex(projectionBefore, activation);
      const excludedBefore = excludedMessages(projectionBefore, boundaryBefore);
      const memoryView = await this.memoryView(activation, signal);
      // The wait can last seconds, so the projection the cut is computed from is
      // read again afterwards. What must not have moved is the part this request
      // does NOT send: the history up to and including the activation's start.
      // Entries appended after the boundary during the wait are the activation's
      // own — a steering message arrives at exactly this point, and the tail
      // below picks it up — so they are expected, not a change.
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
      const rewritten = this.cut(projection, boundaryIndex, activation, memoryView);
      const model = update?.model ?? request.model;
      const effectiveTokens = rewritten.messages.reduce(
        (total, message) => total + estimateTokens(message),
        0,
      );
      const contextWindow = model?.contextWindow ?? 0;
      if (contextWindow > 0 && effectiveTokens > contextWindow - HOME_RESERVE_TOKENS) {
        throw this.refuse(
          "context-overflow",
          `effective ${effectiveTokens} tokens leave no head-room below the ${contextWindow}-token window`,
          activation,
          { effectiveTokens, contextWindow },
        );
      }
      this.expectedNonSystemMessages = rewritten.nonSystem;
      const viewBytes = utf8Bytes(memoryView.text);
      const viewLines = memoryView.text === "" ? 0 : memoryView.text.split("\n").length;
      activation.step = { effectiveTokens, viewBytes, viewLines, contextWindow };
      memoryView.commit();
      // Once per activation, not once per request: a tool loop or a retry is the
      // same activation and its effective size and wait are already reported.
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

  /**
   * Outermost `Agent.transformContext` — the last point the seam observes before
   * `convertToLlm`. It refuses unless the activation's non-system messages came
   * through the context stages unchanged, then records the single-use
   * expectation the innermost stream guard requires.
   */
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
      this.assertContextNotMutated(transformed, activation);
      // Use the same settings-aware converter as this agent's loop; bare
      // conversion would reject Pi's supported image-blocking replacement.
      this.expectedDigest = digestLlmMessages(await convertMessages(transformed));
      return transformed;
    };
  }

  /**
   * Innermost `Agent.streamFunction`: refuse anything that changed after the
   * context stages. The expectation is single-use, so only this request's
   * `transformContext` pass can authorize exactly one provider call.
   */
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
      return stream(model, context, options);
    };
  }

  private requireActivation(): ActivationState {
    const activation = this.activation;
    if (!activation) {
      throw this.refuse("no-activation", "a provider request was attempted with no open Home activation");
    }
    return activation;
  }

  /**
   * The activation's frozen view. Computed at its first request and reused by
   * every later step of the same activation, so a tool loop or an SDK retry
   * cannot re-render (and cannot re-wait on) the memory.
   */
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

  /** A memory refusal keeps its own reason; anything else is a view failure. */
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

  /**
   * Asserts that the request context the SDK handed us is exactly its own
   * canonical projection. Message entries project by reference; synthesized
   * entries (custom messages, compaction summaries) allocate per call, so deep
   * equality is the fallback and the weaker answer is reported.
   */
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

  /**
   * Refuses unless the activation's non-system messages survived the context
   * handlers unchanged: same count, same order, and nothing added, dropped or
   * rewritten.
   *
   * Object identity is never preserved for a Gateway session, because the SDK's
   * context stage clones every message before any extension sees it
   * (`structuredClone` in `ExtensionRunner.emitContext`, which runs even with no
   * handler registered — verified in #412). Identity stays the primary
   * assertion and equal-value replacement the fallback; the observed mode is
   * recorded so the weaker answer is visible rather than implied.
   *
   * System messages are exempt: the SDK's own hidden-declaration and
   * forced-prompt stages rewrite them, and the forced prompt collapses them into
   * one head. A handler that injects a system message is therefore not detected
   * here; no Gateway-shipped extension registers a `context` handler.
   */
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
  ): RewrittenContext {
    const systems: AgentMessage[] = [];
    const tail: AgentMessage[] = [];
    let excludedMessages = 0;
    projection.entries.forEach((entry, index) => {
      const withinActivation = index > boundaryIndex;
      for (const message of entry.messages as AgentMessage[]) {
        if (message.role === "system") {
          // The session's own system message is hoisted so a provider always
          // receives it first, even when it was appended inside the very first
          // activation.
          systems.push(message);
          continue;
        }
        if (withinActivation) tail.push(message);
        else excludedMessages += 1;
      }
    });
    // The view first, as its cache blocks (#491), and the per-activation nonce
    // last: anything that changes every activation must follow the view, or no
    // request could re-read the view from a provider's cache (gist §8).
    const memory: AgentMessage = {
      role: "custom",
      customType: HOME_MEMORY_CUSTOM_TYPE,
      content: [
        ...memoryView.pieces.map((text) => ({ type: "text" as const, text })),
        { type: "text" as const, text: `${HOME_NONCE_MARKER}${activation.nonce}` },
      ],
      display: false,
      details: undefined,
      timestamp: Date.now(),
    } as unknown as AgentMessage;
    return {
      messages: [...systems, memory, ...tail],
      nonSystem: [memory, ...tail],
      excludedMessages,
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

/** The messages a request starting after `boundaryIndex` would NOT send: the
 * canonical history up to and including the activation's start entry. */
function excludedMessages(projection: SessionProjection, boundaryIndex: number): AgentMessage[] {
  const messages: AgentMessage[] = [];
  projection.entries.forEach((entry, index) => {
    if (index <= boundaryIndex) messages.push(...entry.messages as AgentMessage[]);
  });
  return messages;
}

/** Identity first, then value, exactly as the request's own fidelity check does:
 * the SDK allocates fresh objects for synthesized entries. */
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

/** Stable digest of the LLM messages one provider request would carry. */
function digestLlmMessages(messages: unknown): string {
  return createHash("sha256").update(JSON.stringify(messages)).digest("hex");
}

/**
 * Place Home's cache breakpoints on the memory message of an Anthropic Messages
 * payload (#491): one on the view's base block, which is unchanged between
 * rebalances, and one on its last line, where the next request's 20-block
 * lookback finds this request's entry; none on the footer or the nonce. It runs
 * as Home's `before_provider_request` handler, after this seam validated the
 * request, and changes only `cache_control` fields (cache-layout.ts).
 */
export function markHomeMemoryCache(payload: unknown): unknown {
  const messages = (payload as { messages?: unknown } | null)?.messages;
  if (!Array.isArray(messages)) return payload;
  // The memory message is the first whose last block is the nonce this seam
  // appended (`cut`); it always precedes the activation's own messages.
  const index = messages.findIndex((message) => {
    const content = (message as { content?: unknown } | null)?.content;
    const last = Array.isArray(content) ? content.at(-1) as { type?: unknown; text?: unknown } | undefined : undefined;
    return last?.type === "text" && typeof last.text === "string" && last.text.startsWith(HOME_NONCE_MARKER);
  });
  if (index < 0) return payload;
  const blocks = (messages[index] as { content: unknown[] }).content;
  // [first, ...lines, footer, nonce]: the last line is third from the end, or the
  // first block when no line followed it. The first block is found by shape, not
  // position: a provider that composes its own request may put blocks before it
  // (CortexKit prepends its cached prompt block to the first user message).
  const last = blocks.length - 3;
  let first = last;
  while (first > 0 && isViewLineBlock(blocks[first])) first -= 1;
  return last < 0 ? payload : markAnthropicBlocks(payload, index, [...new Set([first, last])]);
}

/** One block per view line after the first block (`viewPieces`): `id+n|text` and a line end. */
function isViewLineBlock(block: unknown): boolean {
  const text = (block as { type?: unknown; text?: unknown } | null)?.text;
  return (block as { type?: unknown } | null)?.type === "text" && typeof text === "string" && /^\d+\+\d+\|[^\n]*\n$/u.test(text);
}

/**
 * Home's requests ask pi-ai for long prompt-cache retention (#491): Anthropic's
 * one-hour TTL where the model supports it, OpenAI's longest retention. Home is
 * used on and off through a day, so a five-minute cache would expire between
 * most turns, and Home's view is a long prefix that is worth keeping. pi-ai maps
 * `long` per provider; a provider that composes its own requests, such as
 * CortexKit's, applies its own retention.
 *
 * The override is a write on `runtime`, which must be the Home session's own
 * view of the shared runtime (`sessionRuntimeView`), never the shared runtime
 * itself: ordinary sessions keep pi-ai's default retention.
 */
export function applyHomeCacheRetention(runtime: ModelRuntime): ModelRuntime {
  const stream = runtime.streamSimple.bind(runtime);
  runtime.streamSimple = ((model, context, options) =>
    stream(model, context, { ...options, cacheRetention: options?.cacheRetention ?? "long" })) as ModelRuntime["streamSimple"];
  return runtime;
}

/** Occurrences of the activation nonce anywhere in one request's messages. */
function countNonce(messages: readonly unknown[], nonce: string): number {
  return JSON.stringify(messages).split(nonce).length - 1;
}

function utf8Bytes(text: string): number {
  return Buffer.byteLength(text, "utf8");
}
