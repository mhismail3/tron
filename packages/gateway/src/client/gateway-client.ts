import { randomUUID } from "node:crypto";
import WebSocket from "ws";
import { PROTOCOL_VERSION } from "../version.js";
import type { JsonValue } from "../protocol/types.js";

export interface GatewayClientEvent {
  type: "event";
  topic: string;
  sessionId?: string;
  payload: JsonValue;
}

interface GatewayFailure {
  code: string;
  message: string;
  retryable: boolean;
  details?: JsonValue;
}

interface PendingRequest {
  resolve: (value: JsonValue) => void;
  reject: (error: Error) => void;
  timer: NodeJS.Timeout;
}

export class GatewayClientError extends Error {
  constructor(
    readonly code: string,
    message: string,
    readonly retryable: boolean,
    readonly details?: JsonValue,
  ) {
    super(message);
    this.name = "GatewayClientError";
  }
}

/** Small stable-protocol client shared by Tron's terminal surfaces and tests. */
export class GatewayProtocolClient {
  private socket: WebSocket | undefined;
  private readonly pending = new Map<string, PendingRequest>();
  private readonly eventListeners = new Set<(event: GatewayClientEvent) => void>();
  private readonly disconnectListeners = new Set<(error: Error) => void>();
  private closeError: Error | undefined;

  constructor(
    private readonly url: string,
    private readonly token: string,
  ) {}

  async connect(timeoutMs = 15_000): Promise<JsonValue> {
    if (this.socket) throw new Error("gateway client is already connected");
    const socket = new WebSocket(this.url, { headers: { authorization: `Bearer ${this.token}` }, perMessageDeflate: false });
    this.socket = socket;
    this.closeError = undefined;
    return new Promise<JsonValue>((resolve, reject) => {
      const timer = setTimeout(() => {
        socket.terminate();
        reject(new GatewayClientError("timeout", "Gateway handshake timed out", true));
      }, timeoutMs);
      timer.unref();
      const fail = (error: Error) => {
        clearTimeout(timer);
        reject(error);
      };
      socket.once("error", fail);
      socket.once("open", () => {
        socket.send(JSON.stringify({ type: "hello", protocolVersion: PROTOCOL_VERSION, clientId: randomUUID() }));
      });
      socket.on("message", (raw) => {
        try {
          const frame = JSON.parse(raw.toString()) as Record<string, unknown>;
          if (frame.type === "hello") {
            if (frame.protocolVersion !== PROTOCOL_VERSION || frame.minProtocolVersion !== PROTOCOL_VERSION) {
              clearTimeout(timer);
              socket.terminate();
              reject(new GatewayClientError("protocol_mismatch", "Gateway protocol is not compatible", false));
              return;
            }
            clearTimeout(timer);
            socket.off("error", fail);
            resolve(frame as JsonValue);
            return;
          }
          this.handleFrame(frame);
        } catch (error) {
          this.close(error instanceof Error ? error : new Error(String(error)));
        }
      });
      socket.on("error", (error) => { this.closeError = new GatewayClientError("disconnected", error.message, true); });
      socket.on("close", (_code, reason) => {
        const error = this.closeError ?? new GatewayClientError("disconnected", reason.toString() || "Gateway disconnected", true);
        this.failPending(error);
        this.socket = undefined;
        for (const listener of this.disconnectListeners) listener(error);
      });
    });
  }

  onEvent(listener: (event: GatewayClientEvent) => void): () => void {
    this.eventListeners.add(listener);
    return () => this.eventListeners.delete(listener);
  }

  onDisconnect(listener: (error: Error) => void): () => void {
    this.disconnectListeners.add(listener);
    return () => this.disconnectListeners.delete(listener);
  }

  async request(method: string, params: JsonValue, timeoutMs = 30_000): Promise<JsonValue> {
    const socket = this.socket;
    if (!socket || socket.readyState !== WebSocket.OPEN) {
      throw new GatewayClientError("disconnected", "Gateway is not connected", true);
    }
    const id = randomUUID();
    return new Promise<JsonValue>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new GatewayClientError("timeout", `Gateway request timed out: ${method}`, true));
      }, timeoutMs);
      timer.unref();
      this.pending.set(id, { resolve, reject, timer });
      socket.send(JSON.stringify({ type: "request", id, method, params }), (error) => {
        if (!error) return;
        const pending = this.pending.get(id);
        if (!pending) return;
        clearTimeout(pending.timer);
        this.pending.delete(id);
        pending.reject(error instanceof GatewayClientError ? error : new GatewayClientError("disconnected", error.message, true));
      });
    });
  }

  close(error: Error = new GatewayClientError("closed", "Gateway client closed", true)): void {
    this.closeError = error;
    const socket = this.socket;
    this.socket = undefined;
    if (socket?.readyState === WebSocket.CONNECTING) socket.terminate();
    else socket?.close(1000, "client closed");
    this.failPending(error);
  }

  private handleFrame(frame: Record<string, unknown>): void {
    if (frame.type === "response" && typeof frame.id === "string") {
      const pending = this.pending.get(frame.id);
      if (!pending) return;
      clearTimeout(pending.timer);
      this.pending.delete(frame.id);
      if (frame.ok === true) pending.resolve((frame.result ?? null) as JsonValue);
      else {
        const failure = (frame.error ?? {}) as Partial<GatewayFailure>;
        pending.reject(new GatewayClientError(
          failure.code ?? "invalid_response",
          failure.message ?? "Gateway returned an invalid error",
          failure.retryable ?? false,
          failure.details,
        ));
      }
      return;
    }
    if (frame.type === "event" && typeof frame.topic === "string") {
      const event: GatewayClientEvent = {
        type: "event",
        topic: frame.topic,
        ...(typeof frame.sessionId === "string" ? { sessionId: frame.sessionId } : {}),
        payload: (frame.payload ?? null) as JsonValue,
      };
      for (const listener of this.eventListeners) listener(event);
    }
  }

  private failPending(error: Error): void {
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.pending.clear();
  }
}
