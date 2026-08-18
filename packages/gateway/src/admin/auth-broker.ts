import { randomUUID } from "node:crypto";
import type { AuthEvent, AuthPrompt, AuthType } from "@earendil-works/pi-ai";
import type { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { GatewayError } from "../errors.js";
import type { JsonValue } from "../protocol/types.js";

interface PendingPrompt {
  id: string;
  resolve: (value: string) => void;
  reject: (error: Error) => void;
  cleanup?: () => void;
}

interface AuthOperation {
  id: string;
  clientId: string;
  providerId: string;
  controller: AbortController;
  prompt: PendingPrompt | undefined;
  timer: NodeJS.Timeout;
}

export type AdminEventSink = (clientId: string, topic: string, payload: JsonValue) => void;

const DEFAULT_MAX_AUTH_OPERATIONS = 8;
const DEFAULT_MAX_AUTH_OPERATIONS_PER_CLIENT = 2;
const DEFAULT_AUTH_OPERATION_TIMEOUT_MS = 15 * 60_000;
const MAX_AUTH_PROJECTION_BYTES = 128 * 1_024;
const MAX_AUTH_ERROR_BYTES = 8 * 1_024;

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

export class AuthBroker {
  private readonly operations = new Map<string, AuthOperation>();

  private readonly maximumOperations: number;
  private readonly maximumOperationsPerClient: number;
  private readonly operationTimeoutMs: number;

  constructor(
    private readonly modelRuntime: ModelRuntime,
    private readonly emit: AdminEventSink,
    private readonly broadcast: (topic: string, payload: JsonValue) => void = () => {},
    options: {
      maximumOperations?: number;
      maximumOperationsPerClient?: number;
      operationTimeoutMs?: number;
    } = {},
  ) {
    this.maximumOperations = options.maximumOperations ?? DEFAULT_MAX_AUTH_OPERATIONS;
    this.maximumOperationsPerClient = options.maximumOperationsPerClient ?? DEFAULT_MAX_AUTH_OPERATIONS_PER_CLIENT;
    this.operationTimeoutMs = options.operationTimeoutMs ?? DEFAULT_AUTH_OPERATION_TIMEOUT_MS;
    if (!Number.isSafeInteger(this.maximumOperations) || this.maximumOperations < 1
      || !Number.isSafeInteger(this.maximumOperationsPerClient) || this.maximumOperationsPerClient < 1
      || this.maximumOperationsPerClient > this.maximumOperations
      || !Number.isSafeInteger(this.operationTimeoutMs) || this.operationTimeoutMs < 1) {
      throw new Error("Authentication operation bounds are invalid");
    }
  }

  get activeOperationCount(): number { return this.operations.size; }

  start(clientId: string, providerId: string, authType: AuthType, modelRuntime: ModelRuntime = this.modelRuntime): string {
    const provider = modelRuntime.getProvider(providerId);
    if (!provider) throw new GatewayError("not_found", "Provider is not registered in Tron");
    if (authType === "api_key" && !provider.auth.apiKey?.login) {
      throw new GatewayError("unsupported", "Provider does not offer interactive API-key setup");
    }
    if (authType === "oauth" && !provider.auth.oauth) {
      throw new GatewayError("unsupported", "Provider does not offer OAuth setup");
    }
    if (this.operations.size >= this.maximumOperations
      || [...this.operations.values()].filter((operation) => operation.clientId === clientId).length
        >= this.maximumOperationsPerClient) {
      throw new GatewayError("busy", "Concurrent authentication operations reached their bounded capacity", true);
    }

    let operation!: AuthOperation;
    const timer = setTimeout(() => this.timeout(operation), this.operationTimeoutMs);
    timer.unref();
    operation = {
      id: randomUUID(),
      clientId,
      providerId,
      controller: new AbortController(),
      prompt: undefined,
      timer,
    };
    this.operations.set(operation.id, operation);
    const interaction = {
      signal: operation.controller.signal,
      prompt: (prompt: AuthPrompt) => this.prompt(operation, prompt),
      notify: (event: AuthEvent) => {
        if (this.operations.get(operation.id) !== operation) return;
        const payload = { operationId: operation.id, event } as unknown as JsonValue;
        requireBoundedProjection(payload, "event");
        this.emit(clientId, "auth.event", payload);
      },
    };
    void Promise.resolve()
      .then(() => modelRuntime.login(providerId, authType, interaction))
      .then(
        () => this.complete(operation, true),
        (error: unknown) => this.complete(operation, false, error),
      );
    return operation.id;
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
    return new Promise((resolve, reject) => {
      const pending: PendingPrompt = { id, resolve, reject };
      if (prompt.signal) {
        const abort = () => {
          operation.prompt = undefined;
          reject(new GatewayError("cancelled", "Authentication prompt was cancelled"));
        };
        prompt.signal.addEventListener("abort", abort, { once: true });
        pending.cleanup = () => prompt.signal?.removeEventListener("abort", abort);
      }
      operation.prompt = pending;
      this.emit(operation.clientId, "auth.prompt", payload);
    });
  }

  respond(clientId: string, operationId: string, promptId: string, value: string): void {
    const operation = this.operations.get(operationId);
    if (!operation || operation.clientId !== clientId) throw new GatewayError("not_found", "Authentication operation was not found");
    const prompt = operation.prompt;
    if (!prompt || prompt.id !== promptId) throw new GatewayError("not_found", "Authentication prompt is no longer pending");
    operation.prompt = undefined;
    prompt.cleanup?.();
    prompt.resolve(value);
  }

  cancel(clientId: string, operationId: string): void {
    const operation = this.operations.get(operationId);
    if (!operation || operation.clientId !== clientId) throw new GatewayError("not_found", "Authentication operation was not found");
    operation.controller.abort();
    this.retire(operation, "Authentication cancelled");
  }

  cancelClient(clientId: string): void {
    for (const operation of [...this.operations.values()]) {
      if (operation.clientId === clientId) this.cancel(clientId, operation.id);
    }
  }

  private retire(operation: AuthOperation, reason: string): boolean {
    if (!this.operations.delete(operation.id)) return false;
    clearTimeout(operation.timer);
    operation.prompt?.cleanup?.();
    operation.prompt?.reject(new GatewayError("cancelled", reason));
    operation.prompt = undefined;
    return true;
  }

  private timeout(operation: AuthOperation): void {
    if (this.operations.get(operation.id) !== operation) return;
    operation.controller.abort();
    if (!this.retire(operation, "Authentication timed out")) return;
    this.emit(operation.clientId, "auth.completed", {
      operationId: operation.id,
      providerId: operation.providerId,
      success: false,
      error: "Authentication timed out",
    });
  }

  private complete(operation: AuthOperation, success: boolean, error?: unknown): void {
    if (!this.retire(operation, "Authentication flow ended")) return;
    this.emit(operation.clientId, "auth.completed", {
      operationId: operation.id,
      providerId: operation.providerId,
      success,
      ...(success ? {} : { error: boundedError(error) }),
    });
    if (success) this.broadcast("providers.changed", {});
  }
}
