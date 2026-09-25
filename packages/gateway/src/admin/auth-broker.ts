import { randomUUID } from "node:crypto";
import { request as httpRequest } from "node:http";
import type { AuthEvent, AuthPrompt, AuthType } from "@earendil-works/pi-ai";
import type { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { GatewayError } from "../errors.js";
import type { JsonValue } from "../protocol/types.js";
import type { GatewayWorkHandle, GatewayWorkRegistry } from "../sessions/gateway-work-registry.js";

interface PendingPrompt {
  id: string;
  wirePayload: JsonValue;
  resolve: (value: string) => void;
  reject: (error: Error) => void;
  cleanup?: () => void;
}

interface OAuthCallbackCapture {
  id: string;
  host: "localhost" | "127.0.0.1" | "::1";
  port: number;
  path: string;
  expectedState?: string;
  claimed: boolean;
}

interface AuthOperation {
  id: string;
  ownerIdentity: string;
  deliveryClientId: string | undefined;
  providerId: string;
  authType: AuthType;
  targetKey: string;
  controller: AbortController;
  prompt: PendingPrompt | undefined;
  latestEvent: JsonValue | undefined;
  callback: OAuthCallbackCapture | undefined;
  timer: NodeJS.Timeout;
  admittedAt: number;
  /** True after the user answered or a callback was relayed, until the
   * provider asks for more input. Only a completing login may hold a drain. */
  completing: boolean;
  work?: GatewayWorkHandle;
  /** Settles when Pi's login promise for this exact operation settles. */
  settled: Promise<void>;
}

/** Result of `auth.begin`: either a new admission or the recovered active
 * operation for the same owner/provider/auth-method/target. */
export interface AuthAdmission {
  operationId: string;
  recovered: boolean;
}

interface AuthCompletion {
  operationId: string;
  providerId: string;
  success: boolean;
  error?: string;
}

interface RetiredAuthOperation {
  ownerIdentity: string;
  providerId: string;
  completion?: AuthCompletion;
  expiresAt: number;
}

interface BeginReceipt {
  ownerIdentity: string;
  operationId: string;
  providerId: string;
  authType: AuthType;
  targetKey: string;
  replaceOperationId: string | undefined;
  recovered: boolean;
  expiresAt: number;
}

export type AdminEventSink = (clientId: string, topic: string, payload: JsonValue) => void;
export type AuthLifecycleLog = (level: "info" | "warning", message: string, event: string) => void;

const DEFAULT_MAX_AUTH_OPERATIONS = 8;
const DEFAULT_MAX_AUTH_OPERATIONS_PER_CLIENT = 2;
const DEFAULT_AUTH_OPERATION_TIMEOUT_MS = 15 * 60_000;
const RETIRED_AUTH_OPERATION_TTL_MS = 15 * 60_000;
const MAX_RETIRED_AUTH_OPERATIONS = 64;
const MAX_BEGIN_RECEIPTS = 128;
const MAX_AUTH_PROJECTION_BYTES = 128 * 1_024;
const MAX_AUTH_ERROR_BYTES = 8 * 1_024;
const MAX_CALLBACK_QUERY_BYTES = 16 * 1_024;
const CALLBACK_RELAY_TIMEOUT_MS = 35_000;
const MAX_CALLBACK_RESPONSE_BYTES = 64 * 1_024;
const DEFAULT_PREDECESSOR_SETTLE_TIMEOUT_MS = 30_000;

function recoveryKey(ownerIdentity: string, providerId: string, authType: AuthType, targetKey: string): string {
  return `${ownerIdentity}\0${providerId}\0${authType}\0${targetKey}`;
}

function boundedError(value: unknown): string {
  let text: string;
  try { text = String(value instanceof Error ? value.message : value); }
  catch { text = "Authentication failed with an unreadable provider error"; }
  const encoded = Buffer.from(text);
  if (encoded.length <= MAX_AUTH_ERROR_BYTES) return text;
  const suffix = "…";
  const available = MAX_AUTH_ERROR_BYTES - Buffer.byteLength(suffix);
  const decoder = new TextDecoder("utf-8", { fatal: true });
  for (let end = available; end >= Math.max(0, available - 3); end -= 1) {
    try { return `${decoder.decode(encoded.subarray(0, end))}${suffix}`; }
    catch { /* Remove only an incomplete terminal UTF-8 sequence. */ }
  }
  return suffix;
}

function requireBoundedProjection(value: unknown, label: string): void {
  if (Buffer.byteLength(JSON.stringify(value)) > MAX_AUTH_PROJECTION_BYTES) {
    throw new GatewayError("conflict", `Authentication ${label} exceeds its bounded capacity`);
  }
}

function normalizedLoopbackHost(hostname: string): OAuthCallbackCapture["host"] | undefined {
  const normalized = hostname.toLowerCase().replace(/^\[(.*)\]$/u, "$1");
  if (normalized === "localhost" || normalized === "127.0.0.1" || normalized === "::1") return normalized;
  return undefined;
}

/** Derive callback admission exclusively from the provider-authored authorization
 * URL. A mobile client is never allowed to choose a Gateway-local destination. */
function callbackCapture(event: AuthEvent): OAuthCallbackCapture | undefined {
  if (event.type !== "auth_url" || typeof event.url !== "string") return undefined;
  try {
    const authorization = new URL(event.url);
    if (authorization.protocol !== "https:" && authorization.protocol !== "http:") return undefined;
    if (authorization.username || authorization.password) return undefined;
    const callbackValues = [
      ...authorization.searchParams.getAll("redirect_uri"),
      ...authorization.searchParams.getAll("callback_url"),
    ];
    const stateValues = authorization.searchParams.getAll("state");
    if (callbackValues.length !== 1 || stateValues.length > 1) return undefined;
    const nestedValue = callbackValues[0]!;
    const nested = new URL(nestedValue);
    const host = normalizedLoopbackHost(nested.hostname);
    const port = Number(nested.port);
    if (nested.protocol !== "http:" || !host || !Number.isSafeInteger(port) || port < 1 || port > 65_535
      || nested.username || nested.password || nested.search || nested.hash) return undefined;
    return {
      id: randomUUID(),
      host,
      port,
      path: nested.pathname || "/",
      ...(stateValues[0] ? { expectedState: stateValues[0] } : {}),
      claimed: false,
    };
  } catch {
    return undefined;
  }
}

function callbackProjection(capture: OAuthCallbackCapture | undefined): JsonValue | undefined {
  if (!capture) return undefined;
  return {
    id: capture.id,
    host: capture.host,
    port: capture.port,
    path: capture.path,
  };
}

export class AuthBroker {
  private readonly operations = new Map<string, AuthOperation>();
  private readonly retiredOperations = new Map<string, RetiredAuthOperation>();
  private readonly beginReceipts = new Map<string, BeginReceipt>();
  /** Latest Pi login promise per recovery key whose operation may still be
   * settling. A successor for the same key starts its provider login only after
   * this settles, so replacement never races its predecessor's resources. */
  private readonly unsettledLogins = new Map<string, Promise<void>>();

  private readonly maximumOperations: number;
  private readonly maximumOperationsPerClient: number;
  private readonly operationTimeoutMs: number;
  private readonly predecessorSettleTimeoutMs: number;
  private readonly workRegistry: GatewayWorkRegistry | undefined;
  private pendingGlobalProviderRefresh: (() => Promise<void>) | undefined;
  private runningGlobalProviderRefresh = false;
  private readonly unsettledGlobalAuthOperations = new Set<AuthOperation>();
  private readonly log: AuthLifecycleLog;

  constructor(
    private readonly modelRuntime: ModelRuntime,
    private readonly emit: AdminEventSink,
    private readonly broadcast: (topic: string, payload: JsonValue) => void = () => {},
    options: {
      maximumOperations?: number;
      maximumOperationsPerClient?: number;
      operationTimeoutMs?: number;
      predecessorSettleTimeoutMs?: number;
      workRegistry?: GatewayWorkRegistry;
      log?: AuthLifecycleLog;
    } = {},
  ) {
    this.log = options.log ?? (() => {});
    this.maximumOperations = options.maximumOperations ?? DEFAULT_MAX_AUTH_OPERATIONS;
    this.maximumOperationsPerClient = options.maximumOperationsPerClient ?? DEFAULT_MAX_AUTH_OPERATIONS_PER_CLIENT;
    this.operationTimeoutMs = options.operationTimeoutMs ?? DEFAULT_AUTH_OPERATION_TIMEOUT_MS;
    this.predecessorSettleTimeoutMs = options.predecessorSettleTimeoutMs ?? DEFAULT_PREDECESSOR_SETTLE_TIMEOUT_MS;
    this.workRegistry = options.workRegistry;
    if (!Number.isSafeInteger(this.maximumOperations) || this.maximumOperations < 1
      || !Number.isSafeInteger(this.maximumOperationsPerClient) || this.maximumOperationsPerClient < 1
      || this.maximumOperationsPerClient > this.maximumOperations
      || !Number.isSafeInteger(this.operationTimeoutMs) || this.operationTimeoutMs < 1
      || !Number.isSafeInteger(this.predecessorSettleTimeoutMs) || this.predecessorSettleTimeoutMs < 1) {
      throw new Error("Authentication operation bounds are invalid");
    }
  }

  /** Admitted operations, currently or awaiting their provider. The bound and
   * its release are asserted through this count: capacity alone is observable
   * only as a later `busy` refusal, which a leaked slot also produces. */
  get activeOperationCount(): number { return this.operations.size; }

  /** Coalesce user-resource changes and apply them between global auth operations. */
  requestGlobalProviderRefresh(refresh: () => Promise<void>): void {
    this.pendingGlobalProviderRefresh = refresh;
    this.drainGlobalProviderRefresh();
  }

  /**
   * Admit, recover, or replace one authentication operation. Admission is
   * synchronous because device admission requires it; a replacement's provider
   * login is deferred until its predecessor's Pi login promise settles.
   *
   * - A retried command ID returns its original admission.
   * - An active operation with the same owner/provider/auth-method/target is
   *   recovered (delivery rebound, bounded state replayed) before capacity is
   *   enforced, so a client that lost its operation ID never consumes a slot.
   * - `replaceOperationId` naming that exact active operation retires it and
   *   admits a successor. A stale ID (already retired) admits or recovers
   *   normally; one naming a different key is a conflict.
   */
  start(
    clientId: string,
    providerId: string,
    authType: AuthType,
    modelRuntime: ModelRuntime = this.modelRuntime,
    ownerIdentity = clientId,
    commandId?: string,
    targetKey = "global",
    replaceOperationId?: string,
  ): AuthAdmission {
    this.pruneRetainedState();
    const receiptKey = commandId ? `${ownerIdentity}\0${commandId}` : undefined;
    if (receiptKey) {
      const receipt = this.beginReceipts.get(receiptKey);
      if (receipt) {
        if (receipt.providerId !== providerId || receipt.authType !== authType || receipt.targetKey !== targetKey
          || receipt.replaceOperationId !== replaceOperationId) {
          throw new GatewayError("conflict", "Authentication command ID was already used with different parameters");
        }
        const active = this.operations.get(receipt.operationId);
        if (active) {
          active.deliveryClientId = clientId;
          this.replay(active);
        } else {
          const retired = this.retiredOperations.get(receipt.operationId);
          if (retired?.completion) this.emit(clientId, "auth.completed", retired.completion as unknown as JsonValue);
        }
        return { operationId: receipt.operationId, recovered: receipt.recovered };
      }
    }

    const key = recoveryKey(ownerIdentity, providerId, authType, targetKey);
    if (replaceOperationId !== undefined) {
      const replaced = this.operations.get(replaceOperationId);
      if (replaced) {
        this.requireOwner(replaced, ownerIdentity);
        if (recoveryKey(replaced.ownerIdentity, replaced.providerId, replaced.authType, replaced.targetKey) !== key) {
          throw new GatewayError("conflict", "Authentication replacement targets a different provider login");
        }
        replaced.controller.abort();
        this.retire(replaced, "Authentication restarted");
      }
    }
    const existing = [...this.operations.values()].find((operation) =>
      recoveryKey(operation.ownerIdentity, operation.providerId, operation.authType, operation.targetKey) === key);
    if (existing) {
      existing.deliveryClientId = clientId;
      if (receiptKey) this.recordReceipt(receiptKey, existing, replaceOperationId, true);
      this.log("info", `Provider login recovered for ${providerId} (${authType})`, "auth.login.recovered");
      this.replay(existing);
      return { operationId: existing.id, recovered: true };
    }

    if (targetKey === "global" && (this.pendingGlobalProviderRefresh || this.runningGlobalProviderRefresh)) {
      throw new GatewayError("busy", "Global provider resources are refreshing; retry authentication shortly", true);
    }
    const provider = modelRuntime.getProvider(providerId);
    if (!provider) throw new GatewayError("not_found", "Provider is not registered in Tron");
    if (authType === "api_key" && !provider.auth.apiKey?.login) {
      throw new GatewayError("unsupported", "Provider does not offer interactive API-key setup");
    }
    if (authType === "oauth" && !provider.auth.oauth) {
      throw new GatewayError("unsupported", "Provider does not offer OAuth setup");
    }
    if (this.operations.size >= this.maximumOperations
      || [...this.operations.values()].filter((operation) => operation.ownerIdentity === ownerIdentity).length
        >= this.maximumOperationsPerClient) {
      throw new GatewayError("busy", "Concurrent authentication operations reached their bounded capacity", true);
    }

    const predecessor = this.unsettledLogins.get(key);
    let operation!: AuthOperation;
    const controller = new AbortController();
    const work = this.workRegistry?.begin({
      kind: "provider-login",
      hostEpoch: this.workRegistry.runtimeEpoch,
      cancellation: () => {
        controller.abort();
        if (operation) this.retire(operation, "Gateway restart cancelled authentication");
      },
    });
    const timer = setTimeout(() => this.timeout(operation), this.operationTimeoutMs);
    timer.unref();
    operation = {
      id: randomUUID(),
      ownerIdentity,
      deliveryClientId: clientId,
      providerId,
      authType,
      targetKey,
      controller,
      prompt: undefined,
      latestEvent: undefined,
      callback: undefined,
      timer,
      admittedAt: Date.now(),
      completing: false,
      settled: Promise.resolve(),
      ...(work ? { work } : {}),
    };
    this.operations.set(operation.id, operation);
    if (targetKey === "global") this.unsettledGlobalAuthOperations.add(operation);
    if (receiptKey) this.recordReceipt(receiptKey, operation, replaceOperationId, false);
    this.log("info", `Provider login started for ${providerId} (${authType})`, "auth.login.started");

    const interaction = {
      signal: operation.controller.signal,
      prompt: (prompt: AuthPrompt) => this.prompt(operation, prompt),
      notify: (event: AuthEvent) => {
        if (this.operations.get(operation.id) !== operation) return;
        // A fixed provider callback port can be held by another active login.
        // Relaying this operation's callback there would deliver its code to
        // the wrong listener, so withhold the capture and keep manual entry.
        let capture = callbackCapture(event);
        if (capture && [...this.operations.values()].some((other) => other !== operation
          && other.callback?.host === capture!.host && other.callback.port === capture!.port)) capture = undefined;
        if (capture) operation.callback = capture;
        if (event.type !== "progress") operation.completing = false;
        const payload = {
          operationId: operation.id,
          event,
          ...(capture ? { callbackCapture: callbackProjection(capture) } : {}),
        } as unknown as JsonValue;
        requireBoundedProjection(payload, "event");
        operation.latestEvent = payload;
        this.emitToOperation(operation, "auth.event", payload);
      },
    };
    operation.settled = this.awaitPredecessor(predecessor)
      .then(() => {
        if (this.operations.get(operation.id) !== operation) {
          throw new GatewayError("cancelled", "Authentication operation ended");
        }
        return modelRuntime.login(providerId, authType, interaction);
      })
      .then(
        () => this.complete(operation, true),
        (error: unknown) => this.complete(operation, false, error),
      )
      .finally(() => {
        operation.work?.settle();
        if (this.unsettledLogins.get(key) === operation.settled) this.unsettledLogins.delete(key);
        if (operation.targetKey === "global") {
          this.unsettledGlobalAuthOperations.delete(operation);
          this.drainGlobalProviderRefresh();
        }
      });
    this.unsettledLogins.set(key, operation.settled);
    return { operationId: operation.id, recovered: false };
  }

  private awaitPredecessor(predecessor: Promise<void> | undefined): Promise<void> {
    if (!predecessor) return Promise.resolve();
    return new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => reject(new GatewayError(
        "busy",
        "The previous login for this provider is still finishing; restart again shortly",
        true,
      )), this.predecessorSettleTimeoutMs);
      timer.unref();
      const settle = () => { clearTimeout(timer); resolve(); };
      void predecessor.then(settle, settle);
    });
  }

  private recordReceipt(
    receiptKey: string,
    operation: AuthOperation,
    replaceOperationId: string | undefined,
    recovered: boolean,
  ): void {
    this.beginReceipts.set(receiptKey, {
      ownerIdentity: operation.ownerIdentity,
      operationId: operation.id,
      providerId: operation.providerId,
      authType: operation.authType,
      targetKey: operation.targetKey,
      replaceOperationId,
      recovered,
      expiresAt: Date.now() + RETIRED_AUTH_OPERATION_TTL_MS,
    });
    this.boundBeginReceipts();
  }

  private prompt(operation: AuthOperation, prompt: AuthPrompt): Promise<string> {
    if (this.operations.get(operation.id) !== operation) {
      return Promise.reject(new GatewayError("cancelled", "Authentication operation ended"));
    }
    if (prompt.signal?.aborted) {
      return Promise.reject(new GatewayError("cancelled", "Authentication prompt was cancelled"));
    }
    const { signal: _signal, ...wirePrompt } = prompt;
    const id = randomUUID();
    const payload = {
      operationId: operation.id,
      promptId: id,
      prompt: wirePrompt,
    } as unknown as JsonValue;
    try { requireBoundedProjection(payload, "prompt"); }
    catch (error) { return Promise.reject(error); }
    operation.prompt?.cleanup?.();
    operation.prompt?.reject(new GatewayError("cancelled", "Authentication prompt was replaced"));
    operation.completing = false;
    return new Promise((resolve, reject) => {
      const pending: PendingPrompt = { id, wirePayload: payload, resolve, reject };
      if (prompt.signal) {
        const abort = () => {
          if (operation.prompt === pending) operation.prompt = undefined;
          reject(new GatewayError("cancelled", "Authentication prompt was cancelled"));
        };
        prompt.signal.addEventListener("abort", abort, { once: true });
        pending.cleanup = () => prompt.signal?.removeEventListener("abort", abort);
      }
      operation.prompt = pending;
      this.emitToOperation(operation, "auth.prompt", payload);
    });
  }

  respond(ownerIdentity: string, operationId: string, promptId: string, value: string): boolean {
    this.pruneRetainedState();
    const operation = this.operations.get(operationId);
    if (!operation) {
      if (this.retiredOperations.get(operationId)?.ownerIdentity === ownerIdentity) return false;
      throw new GatewayError("not_found", "Authentication operation was not found");
    }
    this.requireOwner(operation, ownerIdentity);
    const prompt = operation.prompt;
    if (!prompt || prompt.id !== promptId) return false;
    operation.prompt = undefined;
    prompt.cleanup?.();
    prompt.resolve(value);
    this.markCompleting(operation);
    return true;
  }

  async forwardCallback(ownerIdentity: string, operationId: string, callbackId: string, query: string): Promise<boolean> {
    const operation = this.operations.get(operationId);
    if (!operation) {
      if (this.retiredOperations.get(operationId)?.ownerIdentity === ownerIdentity) return false;
      throw new GatewayError("not_found", "Authentication operation was not found");
    }
    this.requireOwner(operation, ownerIdentity);
    const capture = operation.callback;
    if (!capture || capture.id !== callbackId) throw new GatewayError("not_found", "Authentication callback was not found");
    if (capture.claimed) return false;
    if (Buffer.byteLength(query) > MAX_CALLBACK_QUERY_BYTES || /[\r\n#]/u.test(query)) {
      throw new GatewayError("invalid_request", "Authentication callback query is invalid");
    }
    const callback = new URL(`http://${capture.host === "::1" ? "[::1]" : capture.host}:${capture.port}${capture.path}${query ? `?${query}` : ""}`);
    const codeValues = callback.searchParams.getAll("code");
    const errorValues = callback.searchParams.getAll("error");
    const stateValues = callback.searchParams.getAll("state");
    if (codeValues.length > 1 || errorValues.length > 1 || stateValues.length > 1
      || codeValues.length + errorValues.length !== 1) {
      throw new GatewayError("invalid_request", "Authentication callback has an ambiguous authorization result");
    }
    if (capture.expectedState !== undefined && callback.searchParams.get("state") !== capture.expectedState) {
      throw new GatewayError("invalid_request", "Authentication callback state does not match the active operation");
    }
    // Claim before I/O. A local connection failure can be outcome-unknown if
    // the provider listener accepted the one-use code and closed before its
    // response reached us, so replay must never issue a second callback GET.
    capture.claimed = true;
    await this.relayCallback(capture, query);
    this.markCompleting(operation);
    return true;
  }

  resume(ownerIdentity: string, clientId: string, operationId: string): JsonValue {
    this.pruneRetainedState();
    const operation = this.operations.get(operationId);
    if (operation) {
      this.requireOwner(operation, ownerIdentity);
      operation.deliveryClientId = clientId;
      this.replay(operation);
      return { state: "active", operationId, providerId: operation.providerId };
    }
    const retired = this.retiredOperations.get(operationId);
    if (!retired || retired.ownerIdentity !== ownerIdentity) {
      throw new GatewayError("not_found", "Authentication operation was not found");
    }
    if (retired.completion) this.emit(clientId, "auth.completed", retired.completion as unknown as JsonValue);
    return {
      state: retired.completion ? "completed" : "cancelled",
      operationId,
      providerId: retired.providerId,
      ...(retired.completion ? { success: retired.completion.success } : {}),
    };
  }

  cancel(ownerIdentity: string, operationId: string): boolean {
    this.pruneRetainedState();
    const operation = this.operations.get(operationId);
    if (!operation) {
      if (this.retiredOperations.get(operationId)?.ownerIdentity === ownerIdentity) return false;
      throw new GatewayError("not_found", "Authentication operation was not found");
    }
    this.requireOwner(operation, ownerIdentity);
    operation.controller.abort();
    this.retire(operation, "Authentication cancelled");
    return true;
  }

  /** A transport connection is disposable. Authentication remains owned by the
   * authenticated device identity and can be rebound through auth.resume. */
  detachClient(clientId: string): void {
    for (const operation of this.operations.values()) {
      if (operation.deliveryClientId === clientId) operation.deliveryClientId = undefined;
    }
  }

  /**
   * A restart retires every login anyway. Cancel the ones waiting on the user
   * now, so an abandoned sheet cannot hold the drain until its timeout; a login
   * that is completing (answer submitted, credential possibly being written)
   * keeps its work entry and the drain waits for it.
   */
  cancelWaitingForRestart(): void {
    for (const operation of [...this.operations.values()]) {
      if (operation.completing) continue;
      operation.controller.abort();
      const completion: AuthCompletion = {
        operationId: operation.id,
        providerId: operation.providerId,
        success: false,
        error: "Tron is restarting. Start the login again after it reconnects.",
      };
      const deliveryClientId = operation.deliveryClientId;
      if (!this.retire(operation, "Gateway restart cancelled a waiting login", completion)) continue;
      if (deliveryClientId) this.emit(deliveryClientId, "auth.completed", completion as unknown as JsonValue);
    }
  }

  cancelOwner(ownerIdentity: string): void {
    for (const operation of [...this.operations.values()]) {
      if (operation.ownerIdentity !== ownerIdentity) continue;
      operation.controller.abort();
      this.retire(operation, "Authentication owner was revoked");
    }
  }

  private requireOwner(operation: AuthOperation, ownerIdentity: string): void {
    if (operation.ownerIdentity !== ownerIdentity) {
      throw new GatewayError("not_found", "Authentication operation was not found");
    }
  }

  private markCompleting(operation: AuthOperation): void {
    if (this.operations.get(operation.id) !== operation) return;
    operation.completing = true;
    const payload = {
      operationId: operation.id,
      event: { type: "progress", message: "Completing provider login…" },
    } as unknown as JsonValue;
    operation.latestEvent = payload;
    this.emitToOperation(operation, "auth.event", payload);
  }

  private replay(operation: AuthOperation): void {
    if (operation.latestEvent) this.emitToOperation(operation, "auth.event", operation.latestEvent);
    if (operation.prompt) this.emitToOperation(operation, "auth.prompt", operation.prompt.wirePayload);
  }

  private emitToOperation(operation: AuthOperation, topic: string, payload: JsonValue): void {
    if (operation.deliveryClientId) this.emit(operation.deliveryClientId, topic, payload);
  }

  private retire(operation: AuthOperation, reason: string, completion?: AuthCompletion): boolean {
    if (!this.operations.delete(operation.id)) return false;
    // Provider IDs, methods and reasons only; never prompts, answers or credentials.
    const outcome = completion?.success ? "succeeded" : "ended";
    this.log(
      completion?.success ? "info" : "warning",
      `Provider login ${outcome} for ${operation.providerId} (${operation.authType}) after ${Math.round((Date.now() - operation.admittedAt) / 1_000)}s: ${reason}`,
      `auth.login.${outcome}`,
    );
    this.pruneRetainedState();
    this.retiredOperations.set(operation.id, {
      ownerIdentity: operation.ownerIdentity,
      providerId: operation.providerId,
      ...(completion ? { completion } : {}),
      expiresAt: Date.now() + RETIRED_AUTH_OPERATION_TTL_MS,
    });
    while (this.retiredOperations.size > MAX_RETIRED_AUTH_OPERATIONS) {
      const oldest = this.retiredOperations.keys().next().value;
      if (oldest === undefined) break;
      this.retiredOperations.delete(oldest);
    }
    for (const receipt of this.beginReceipts.values()) {
      if (receipt.operationId === operation.id) receipt.expiresAt = Date.now() + RETIRED_AUTH_OPERATION_TTL_MS;
    }
    clearTimeout(operation.timer);
    operation.prompt?.cleanup?.();
    operation.prompt?.reject(new GatewayError("cancelled", reason));
    operation.prompt = undefined;
    if (operation.targetKey === "global") queueMicrotask(() => this.drainGlobalProviderRefresh());
    return true;
  }

  private pruneRetainedState(now = Date.now()): void {
    for (const [operationID, retired] of this.retiredOperations) {
      if (retired.expiresAt <= now) this.retiredOperations.delete(operationID);
    }
    for (const [key, receipt] of this.beginReceipts) {
      if (receipt.expiresAt <= now && !this.operations.has(receipt.operationId)) this.beginReceipts.delete(key);
    }
  }

  private boundBeginReceipts(): void {
    while (this.beginReceipts.size > MAX_BEGIN_RECEIPTS) {
      const evictable = [...this.beginReceipts].find(([, receipt]) => !this.operations.has(receipt.operationId));
      if (!evictable) throw new GatewayError("busy", "Authentication command receipt capacity is full", true);
      this.beginReceipts.delete(evictable[0]);
    }
  }

  private drainGlobalProviderRefresh(): void {
    if (this.runningGlobalProviderRefresh || !this.pendingGlobalProviderRefresh
      || this.unsettledGlobalAuthOperations.size > 0) return;
    const refresh = this.pendingGlobalProviderRefresh;
    this.pendingGlobalProviderRefresh = undefined;
    this.runningGlobalProviderRefresh = true;
    void Promise.resolve()
      .then(refresh)
      .catch(() => {})
      .finally(() => {
        this.runningGlobalProviderRefresh = false;
        this.drainGlobalProviderRefresh();
      });
  }

  private timeout(operation: AuthOperation): void {
    if (this.operations.get(operation.id) !== operation) return;
    operation.controller.abort();
    const completion: AuthCompletion = {
      operationId: operation.id,
      providerId: operation.providerId,
      success: false,
      error: "Authentication timed out",
    };
    const deliveryClientId = operation.deliveryClientId;
    if (!this.retire(operation, "Authentication timed out", completion)) return;
    if (deliveryClientId) this.emit(deliveryClientId, "auth.completed", completion as unknown as JsonValue);
  }

  private complete(operation: AuthOperation, success: boolean, error?: unknown): void {
    const completion: AuthCompletion = {
      operationId: operation.id,
      providerId: operation.providerId,
      success,
      ...(success ? {} : { error: boundedError(error) }),
    };
    const deliveryClientId = operation.deliveryClientId;
    if (!this.retire(operation, success ? "Authentication flow ended" : "Provider reported a login failure", completion)) {
      // Pi resolves login only after its credential mutation committed. If
      // cancellation or timeout retired the UI operation after that mutation
      // began, the credential is canonical; project it truthfully instead of
      // leaving a false cancellation tombstone.
      if (!success) return;
      this.log("info", `Provider login for ${operation.providerId} (${operation.authType}) stored its credential after the operation ended`, "auth.login.succeeded");
      const retired = this.retiredOperations.get(operation.id);
      if (retired) retired.completion = completion;
      if (deliveryClientId) this.emit(deliveryClientId, "auth.completed", completion as unknown as JsonValue);
      this.broadcast("providers.changed", {});
      return;
    }
    if (deliveryClientId) this.emit(deliveryClientId, "auth.completed", completion as unknown as JsonValue);
    if (success) this.broadcast("providers.changed", {});
  }

  private async relayCallback(capture: OAuthCallbackCapture, query: string): Promise<void> {
    const host = capture.host === "localhost" ? "127.0.0.1" : capture.host;
    await new Promise<void>((resolve, reject) => {
      let responseBytes = 0;
      let settled = false;
      const finish = (error?: Error) => {
        if (settled) return;
        settled = true;
        error ? reject(error) : resolve();
      };
      const request = httpRequest({
        host,
        port: capture.port,
        method: "GET",
        path: `${capture.path}${query ? `?${query}` : ""}`,
        headers: { host: `${capture.host === "::1" ? "[::1]" : capture.host}:${capture.port}`, connection: "close" },
        agent: false,
        timeout: CALLBACK_RELAY_TIMEOUT_MS,
      }, (response) => {
        response.on("data", (chunk: Buffer) => {
          responseBytes += chunk.length;
          if (responseBytes > MAX_CALLBACK_RESPONSE_BYTES) response.destroy();
        });
        response.on("end", () => finish());
        response.on("error", () => finish(new GatewayError("conflict", "Provider callback listener ended unexpectedly", true)));
      });
      request.on("timeout", () => request.destroy(new Error("timeout")));
      request.on("error", () => finish(new GatewayError("conflict", "Provider callback listener is unavailable", true)));
      request.end();
    });
  }
}
