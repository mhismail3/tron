import { createHash, randomUUID } from "node:crypto";
import type { AgentMessage, PrepareRequest, StreamFn } from "@earendil-works/pi-agent-core";
import {
  convertToLlm,
  estimateTokens,
  type AgentSession,
  type SessionProjection,
} from "@earendil-works/pi-coding-agent";

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
export const HOME_MEMORY_CUSTOM_TYPE = "tron.home-memory.v1";
/** Marker prefix that makes the activation nonce greppable in one request. */
export const HOME_NONCE_MARKER = "tron.home-nonce:";

/** Why a Home request was refused. Bounded and reported; observable. */
export type HomeRefusalReason =
  | "no-activation"
  | "stale-activation"
  | "memory-not-configured"
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

/** One request the policy refused. Bounded, so a broken session cannot grow it. */
export interface HomeRefusal {
  reason: HomeRefusalReason;
  detail: string;
  operationId?: string;
  nonce?: string;
}

/** One `prepareRequest` the policy rewrote, recorded for evidence. */
export interface HomeRequestStep {
  operationId: string;
  nonce: string;
  /** The activation's start entry, exactly as `admit` captured it. */
  boundaryEntryId: string | null;
  /** Agent-message roles of the rewritten context, in order. */
  roles: string[];
  /** Effective-size estimate of the rewritten context, in tokens. */
  effectiveTokens: number;
  /** UTF-8 bytes and lines of the frozen memory view this request carried. */
  viewBytes: number;
  viewLines: number;
  /** Canonical messages at or before the activation start that were NOT sent. */
  excludedMessages: number;
  /** The model's context window this activation was measured against, 0 when the
   * model declares none. */
  contextWindow: number;
  /** sha256 of `convertToLlm(rewritten messages)`, recorded for evidence. */
  digest: string;
  /** True when the SDK's projection messages were the identical objects compared against. */
  identityEqual: boolean;
}

/** One `transformContext` pass, recorded so the comparison mode stays visible. */
export interface HomeTransformObservation {
  operationId: string;
  nonce: string;
  /** True when the activation's non-system messages survived by object identity. */
  identity: boolean;
  nonSystemMessages: number;
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
  /** Head-room kept below the model's context window. */
  reserveTokens?: number;
  /** Where the seam reports its bounded per-activation and refusal records. */
  onRecord?: (record: HomeRequestRecord) => void;
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
  view: Promise<HomeActivationView> | undefined;
  viewRefusal: HomeRequestPolicyError | undefined;
  /** True while this activation's first request has not been recorded yet. */
  unrecorded: boolean;
}

interface RewrittenContext {
  messages: AgentMessage[];
  /** The memory message plus the activation's native messages, in request order. */
  nonSystem: AgentMessage[];
  roles: string[];
  excludedMessages: number;
  identityEqual: boolean;
}

const MAXIMUM_RECORDED_REFUSALS = 64;
const MAXIMUM_RECORDED_STEPS = 64;
const MAXIMUM_RECORDED_TRANSFORMS = 64;

export class HomeRequestPolicy {
  private activation: ActivationState | undefined;
  private expectedDigest: string | undefined;
  /** The exact non-system request messages `prepareRequest` returned for the current request. */
  private expectedNonSystemMessages: AgentMessage[] | undefined;
  private lastTransformIdentity: boolean | undefined;
  private readonly reserveTokens: number;
  private readonly refusals: HomeRefusal[] = [];
  private readonly steps: HomeRequestStep[] = [];
  private readonly transforms: HomeTransformObservation[] = [];

  constructor(private readonly options: HomeRequestPolicyOptions) {
    this.reserveTokens = options.reserveTokens ?? 1_024;
  }

  /** Every refusal, oldest first (bounded). */
  refusalLog(): readonly HomeRefusal[] {
    return this.refusals;
  }

  /** Every rewritten request, oldest first (bounded). */
  requestLog(): readonly HomeRequestStep[] {
    return this.steps;
  }

  /** Every `transformContext` pass, oldest first (bounded), surviving settlement. */
  transformLog(): readonly HomeTransformObservation[] {
    return this.transforms;
  }

  currentNonce(): string | undefined {
    return this.activation?.nonce;
  }

  currentOperationId(): string | undefined {
    return this.activation?.operationId;
  }

  /** The boundary entry of the open activation, or undefined when none is open. */
  currentBoundaryEntryId(): string | null | undefined {
    return this.activation?.boundaryEntryId;
  }

  /**
   * Fidelity of the last `transformContext` pass: `true` when the activation's
   * non-system messages survived by object identity, `false` when the SDK's
   * context stage replaced them with equal clones. Undefined before the first.
   */
  lastTransformObservedIdentity(): boolean | undefined {
    return this.lastTransformIdentity;
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
    if (this.activation && this.activation.operationId !== operationId) {
      this.recordRefusal({
        reason: "stale-activation",
        detail: `activation for ${this.activation.operationId} was replaced by ${operationId}`,
        operationId: this.activation.operationId,
        nonce: this.activation.nonce,
      });
    }
    this.activation = {
      operationId,
      nonce: randomUUID(),
      boundaryEntryId,
      view: undefined,
      viewRefusal: undefined,
      unrecorded: true,
    };
    this.expectedDigest = undefined;
    this.expectedNonSystemMessages = undefined;
    this.lastTransformIdentity = undefined;
  }

  /** Closes the activation when Tron settles that exact operation. */
  settle(operationId: string | undefined): void {
    if (!operationId) return;
    if (this.activation?.operationId !== operationId) return;
    this.activation = undefined;
    this.expectedDigest = undefined;
    this.expectedNonSystemMessages = undefined;
    this.lastTransformIdentity = undefined;
  }

  /**
   * Follows a foreground ownership transfer inside one activation.
   *
   * Tron reassigns `activeOperationId` when a dequeued follow-up retrospectively
   * takes over the already-started run and when a queue admission is
   * reclassified as an ordinary prompt. The run, its boundary entry and its
   * frozen memory view are unchanged — only the operation identity Tron reports
   * is — so the activation is renamed, or its later `settle` would never match
   * and it would outlive the run (#412 R1, verified failing before the fix).
   */
  transferOperation(from: string | undefined, to: string): void {
    if (!from || from === to) return;
    if (this.activation?.operationId !== from) return;
    this.activation.operationId = to;
  }

  /** Outer `Agent.prepareRequest`: rebuild the request from the activation, not from canonical history. */
  wrapPrepareRequest(session: AgentSession, inner: PrepareRequest | undefined): PrepareRequest {
    return async (request, signal) => {
      const update = inner ? await inner(request, signal) : undefined;
      const context = update?.context ?? request.context;
      const activation = this.requireActivation();
      const memoryView = await this.memoryView(activation, signal);
      const projection = session.sessionManager.buildSessionProjection();
      // The SDK's own projection is the only accepted input for the cut; a
      // mismatch means some other `prepareRequest` rewrite changed the request.
      const identityEqual = this.assertProjectionFidelity(context.messages, projection, activation);
      const boundaryIndex = this.boundaryIndex(projection, activation);
      const rewritten = this.cut(projection, boundaryIndex, activation, memoryView, identityEqual);
      const model = update?.model ?? request.model;
      const effectiveTokens = rewritten.messages.reduce(
        (total, message) => total + estimateTokens(message),
        0,
      );
      const contextWindow = model?.contextWindow ?? 0;
      if (contextWindow > 0 && effectiveTokens > contextWindow - this.reserveTokens) {
        throw this.refuse(
          "context-overflow",
          `effective ${effectiveTokens} tokens leave no head-room below the ${contextWindow}-token window`,
          activation,
          { effectiveTokens, contextWindow },
        );
      }
      const digest = digestLlmMessages(convertToLlm(rewritten.messages));
      this.expectedDigest = digest;
      this.expectedNonSystemMessages = rewritten.nonSystem;
      const viewBytes = utf8Bytes(memoryView.text);
      const viewLines = memoryView.text === "" ? 0 : memoryView.text.split("\n").length;
      this.recordStep({
        operationId: activation.operationId,
        nonce: activation.nonce,
        boundaryEntryId: activation.boundaryEntryId,
        roles: rewritten.roles,
        effectiveTokens,
        viewBytes,
        viewLines,
        excludedMessages: rewritten.excludedMessages,
        contextWindow,
        digest,
        identityEqual: rewritten.identityEqual,
      });
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
      this.expectedDigest = digestLlmMessages(convertToLlm(transformed));
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
        return await this.options.prepareMemoryView(activationIdentity(activation), signal);
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
  ): boolean {
    const canonical = projection.messages;
    if (expected.length !== canonical.length) {
      throw this.refuse(
        "projection-mismatch",
        `request context carries ${expected.length} messages but the canonical projection has ${canonical.length}`,
        activation,
      );
    }
    let identical = true;
    for (let index = 0; index < canonical.length; index++) {
      const candidate = expected[index];
      const current = canonical[index];
      if (candidate === current) continue;
      identical = false;
      if (JSON.stringify(candidate) !== JSON.stringify(current)) {
        throw this.refuse(
          "projection-mismatch",
          `request context message ${index} differs from the canonical projection`,
          activation,
        );
      }
    }
    return identical;
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
    this.lastTransformIdentity = identical;
    this.transforms.push({
      operationId: activation.operationId,
      nonce: activation.nonce,
      identity: identical,
      nonSystemMessages: actual.length,
    });
    if (this.transforms.length > MAXIMUM_RECORDED_TRANSFORMS) this.transforms.shift();
  }

  private cut(
    projection: SessionProjection,
    boundaryIndex: number,
    activation: ActivationState,
    memoryView: HomeActivationView,
    identityEqual: boolean,
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
    const memory: AgentMessage = {
      role: "custom",
      customType: HOME_MEMORY_CUSTOM_TYPE,
      content: `${HOME_NONCE_MARKER}${activation.nonce}\n${memoryView.text}`,
      display: false,
      details: undefined,
      timestamp: Date.now(),
    } as unknown as AgentMessage;
    const messages = [...systems, memory, ...tail];
    return {
      messages,
      nonSystem: [memory, ...tail],
      roles: messages.map((message) => message.role),
      excludedMessages,
      identityEqual,
    };
  }

  private recordStep(step: HomeRequestStep): void {
    this.steps.push(step);
    if (this.steps.length > MAXIMUM_RECORDED_STEPS) this.steps.shift();
  }

  private recordRefusal(refusal: HomeRefusal): void {
    this.refusals.push(refusal);
    if (this.refusals.length > MAXIMUM_RECORDED_REFUSALS) this.refusals.shift();
  }

  private refuse(
    reason: HomeRefusalReason,
    detail: string,
    activation?: ActivationState,
    sizes?: { effectiveTokens: number; contextWindow: number },
  ): HomeRequestPolicyError {
    const open = activation ?? this.activation;
    this.recordRefusal({
      reason,
      detail,
      ...(open ? { operationId: open.operationId, nonce: open.nonce } : {}),
    });
    this.options.onRecord?.({ event: "refused", reason, detail, ...(sizes ?? {}) });
    return new HomeRequestPolicyError(reason, `Home request refused (${reason}): ${detail}`);
  }
}

function activationIdentity(activation: ActivationState): HomeActivationIdentity {
  return {
    operationId: activation.operationId,
    nonce: activation.nonce,
    boundaryEntryId: activation.boundaryEntryId,
  };
}

/** Stable digest of the LLM messages one provider request would carry. */
export function digestLlmMessages(messages: unknown): string {
  return createHash("sha256").update(JSON.stringify(messages)).digest("hex");
}

/** Occurrences of the activation nonce anywhere in one request's messages. */
function countNonce(messages: readonly unknown[], nonce: string): number {
  return JSON.stringify(messages).split(nonce).length - 1;
}

function utf8Bytes(text: string): number {
  return Buffer.byteLength(text, "utf8");
}
