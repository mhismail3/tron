export type GatewayErrorCode =
  | "unauthenticated"
  | "invalid_request"
  | "not_found"
  | "conflict"
  | "busy"
  | "unsupported"
  | "trust_required"
  | "auth_required"
  | "cancelled"
  | "internal";

export class GatewayError extends Error {
  constructor(
    readonly code: GatewayErrorCode,
    message: string,
    readonly retryable = false,
    readonly details?: unknown,
  ) {
    super(message);
    this.name = "GatewayError";
  }
}

/**
 * An operation whose effect may already have been applied. Owners raise this
 * when they cannot prove whether a durable or external effect landed, so the
 * idempotency receipt keeps its uncertainty fence instead of permitting the
 * identical command to be replayed. Callers must refresh authoritative state
 * and reissue with a new commandId.
 */
export function uncertainOutcome(message: string): GatewayError {
  return new GatewayError("conflict", message, false, { outcomeUnknown: true });
}

/** True only when an error explicitly reports that its effect outcome is unknown. */
export function isUncertainOutcome(error: unknown): boolean {
  if (!(error instanceof GatewayError)) return false;
  const details = error.details;
  return !!details && typeof details === "object" && !Array.isArray(details)
    && (details as Record<string, unknown>).outcomeUnknown === true;
}

/**
 * Preserve an existing rejection classification while recording that the effect
 * outcome is unknown. A failure that is not already a GatewayError cannot prove
 * its effect was rejected, so it is reported as an uncertain conflict.
 */
export function asUncertainOutcome(error: unknown, message: string): GatewayError {
  if (isUncertainOutcome(error)) return error as GatewayError;
  if (error instanceof GatewayError) {
    const details = error.details && typeof error.details === "object" && !Array.isArray(error.details)
      ? { ...(error.details as Record<string, unknown>), outcomeUnknown: true }
      : { outcomeUnknown: true, ...(error.details === undefined ? {} : { reported: error.details }) };
    return new GatewayError(error.code, error.message, error.retryable, details);
  }
  const cause = error instanceof Error ? error.message : String(error);
  return new GatewayError("conflict", `${message} (${cause})`, false, { outcomeUnknown: true });
}

export function publicError(error: unknown): {
  code: GatewayErrorCode;
  message: string;
  retryable: boolean;
  details?: unknown;
} {
  if (error instanceof GatewayError) {
    return {
      code: error.code,
      message: error.message,
      retryable: error.retryable,
      ...(error.details === undefined ? {} : { details: error.details }),
    };
  }
  const message = error instanceof Error ? error.message : "Unexpected gateway failure";
  return { code: "internal", message, retryable: false };
}
