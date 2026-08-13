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
}

export type AdminEventSink = (clientId: string, topic: string, payload: JsonValue) => void;

export class AuthBroker {
  private readonly operations = new Map<string, AuthOperation>();

  constructor(
    private readonly modelRuntime: ModelRuntime,
    private readonly emit: AdminEventSink,
    private readonly broadcast: (topic: string, payload: JsonValue) => void = () => {},
  ) {}

  start(clientId: string, providerId: string, authType: AuthType, modelRuntime: ModelRuntime = this.modelRuntime): string {
    const provider = modelRuntime.getProvider(providerId);
    if (!provider) throw new GatewayError("not_found", "Provider is not registered in Tron");
    if (authType === "api_key" && !provider.auth.apiKey?.login) {
      throw new GatewayError("unsupported", "Provider does not offer interactive API-key setup");
    }
    if (authType === "oauth" && !provider.auth.oauth) {
      throw new GatewayError("unsupported", "Provider does not offer OAuth setup");
    }

    const operation: AuthOperation = {
      id: randomUUID(),
      clientId,
      providerId,
      controller: new AbortController(),
      prompt: undefined,
    };
    this.operations.set(operation.id, operation);
    const interaction = {
      signal: operation.controller.signal,
      prompt: (prompt: AuthPrompt) => this.prompt(operation, prompt),
      notify: (event: AuthEvent) => this.emit(clientId, "auth.event", { operationId: operation.id, event } as unknown as JsonValue),
    };
    void modelRuntime.login(providerId, authType, interaction).then(
      () => this.complete(operation, true),
      (error: unknown) => this.complete(operation, false, error),
    );
    return operation.id;
  }

  private prompt(operation: AuthOperation, prompt: AuthPrompt): Promise<string> {
    operation.prompt?.reject(new GatewayError("cancelled", "Authentication prompt was replaced"));
    return new Promise((resolve, reject) => {
      const id = randomUUID();
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
      const { signal: _signal, ...wirePrompt } = prompt;
      this.emit(operation.clientId, "auth.prompt", {
        operationId: operation.id,
        promptId: id,
        prompt: wirePrompt,
      } as unknown as JsonValue);
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
    operation.prompt?.reject(new GatewayError("cancelled", "Authentication cancelled"));
    this.operations.delete(operationId);
  }

  cancelClient(clientId: string): void {
    for (const operation of [...this.operations.values()]) {
      if (operation.clientId === clientId) this.cancel(clientId, operation.id);
    }
  }

  private complete(operation: AuthOperation, success: boolean, error?: unknown): void {
    if (!this.operations.delete(operation.id)) return;
    operation.prompt?.cleanup?.();
    operation.prompt?.reject(new GatewayError("cancelled", "Authentication flow ended"));
    this.emit(operation.clientId, "auth.completed", {
      operationId: operation.id,
      providerId: operation.providerId,
      success,
      ...(success ? {} : { error: error instanceof Error ? error.message : String(error) }),
    });
    if (success) this.broadcast("providers.changed", {});
  }
}
