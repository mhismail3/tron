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

type GatewayDiagnosticReason =
  | "viewer_capacity" | "viewer_retired" | "viewer_identity_in_use"
  | "catalog_capacity" | "catalog_headers_unavailable" | "catalog_changed"
  | `session_configuration_${"running" | "queued" | "settling" | "mutation" | "interaction" | "unavailable"}`
  | "catalog_identity_ambiguous" | "catalog_not_ready" | "session_operation_busy" | "attention-pending"
  | "home-memory-revision-changed" | "home-memory-source-unavailable";

export class GatewayError extends Error {
  constructor(
    readonly code: GatewayErrorCode,
    message: string,
    readonly retryable = false,
    readonly details?: unknown,
    readonly diagnosticReason?: GatewayDiagnosticReason,
  ) {
    super(message);
    this.name = "GatewayError";
  }
}

export function uncertainOutcome(message: string): GatewayError {
  return new GatewayError("conflict", message, false, { outcomeUnknown: true });
}

export function isUncertainOutcome(error: unknown): boolean {
  if (!(error instanceof GatewayError)) return false;
  const details = error.details;
  return !!details && typeof details === "object" && !Array.isArray(details)
    && (details as Record<string, unknown>).outcomeUnknown === true;
}

export function asUncertainOutcome(error: unknown, message: string): GatewayError {
  if (isUncertainOutcome(error)) return error as GatewayError;
  if (error instanceof GatewayError) {
    const details = error.details && typeof error.details === "object" && !Array.isArray(error.details)
      ? { ...(error.details as Record<string, unknown>), outcomeUnknown: true }
      : { outcomeUnknown: true, ...(error.details === undefined ? {} : { reported: error.details }) };
    return new GatewayError(error.code, error.message, false, details);
  }
  const failure = new GatewayError("conflict", message, false, { outcomeUnknown: true });
  failure.cause = error;
  return failure;
}

export function publicError(error: unknown): {
  code: GatewayErrorCode;
  message: string;
  retryable: boolean;
  details?: unknown;
} {
  if (error instanceof GatewayError && error.code !== "internal") {
    return {
      code: error.code,
      message: error.message,
      retryable: error.retryable,
      ...(error.details === undefined ? {} : { details: error.details }),
    };
  }
  return { code: "internal", message: "Unexpected gateway failure", retryable: error instanceof GatewayError && error.retryable };
}

type EpisodicErrorKind =
  | "paused"
  | "blocked"
  | "closed"
  | "invalid-store"
  | "unsafe-store"
  | "source"
  | "invalid-request"
  | "already-open";

export class EpisodicMemoryError extends Error {
  constructor(readonly kind: EpisodicErrorKind, message: string) {
    super(message);
    this.name = "EpisodicMemoryError";
  }
}
