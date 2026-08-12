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
