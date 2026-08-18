import { GatewayError } from "../errors.js";

export function object(value: unknown, label = "params"): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new GatewayError("invalid_request", `${label} must be an object`);
  }
  return value as Record<string, unknown>;
}

export function string(value: unknown, label: string, options: { min?: number; max?: number } = {}): string {
  if (typeof value !== "string") throw new GatewayError("invalid_request", `${label} must be a string`);
  const trimmed = value.trim();
  if (trimmed.length < (options.min ?? 1)) throw new GatewayError("invalid_request", `${label} is required`);
  if (trimmed.length > (options.max ?? 4096)) throw new GatewayError("invalid_request", `${label} is too long`);
  return trimmed;
}

/** Bounded text payload that may intentionally be empty or whitespace-only. */
export function text(value: unknown, label: string, max = 4096): string {
  if (typeof value !== "string") throw new GatewayError("invalid_request", `${label} must be a string`);
  if (value.length > max) throw new GatewayError("invalid_request", `${label} is too long`);
  return value;
}

export function optionalString(value: unknown, label: string, max = 4096): string | undefined {
  if (value === undefined || value === null) return undefined;
  return string(value, label, { max });
}

export function boolean(value: unknown, label: string): boolean {
  if (typeof value !== "boolean") throw new GatewayError("invalid_request", `${label} must be a boolean`);
  return value;
}

export function integer(value: unknown, label: string, min: number, max: number): number {
  if (!Number.isSafeInteger(value) || (value as number) < min || (value as number) > max) {
    throw new GatewayError("invalid_request", `${label} must be an integer from ${min} through ${max}`);
  }
  return value as number;
}

export function oneOf<T extends string>(value: unknown, label: string, choices: readonly T[]): T {
  if (typeof value !== "string" || !choices.includes(value as T)) {
    throw new GatewayError("invalid_request", `${label} must be one of ${choices.join(", ")}`);
  }
  return value as T;
}

export function arrayOfStrings(value: unknown, label: string, maxItems = 256): string[] {
  if (!Array.isArray(value) || value.length > maxItems) {
    throw new GatewayError("invalid_request", `${label} must be an array with at most ${maxItems} items`);
  }
  return value.map((item, index) => string(item, `${label}[${index}]`, { max: 4096 }));
}
