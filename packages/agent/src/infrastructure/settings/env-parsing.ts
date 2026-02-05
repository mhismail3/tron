/**
 * @fileoverview Environment parsing helpers
 *
 * Centralized strict parsing for environment-driven configuration values.
 */

export interface EnvParseLogger {
  warn: (message: string, context?: Record<string, unknown>) => void;
}

export interface ParseEnvIntegerOptions {
  name: string;
  fallback: number;
  min?: number;
  max?: number;
  logger?: EnvParseLogger;
}

export interface ParseOptionalIntegerOptions {
  name: string;
  min?: number;
  max?: number;
  logger?: EnvParseLogger;
}

export interface ParseEnvBooleanOptions {
  name: string;
  fallback: boolean;
  logger?: EnvParseLogger;
}

const TRUE_VALUES = new Set(['true', '1', 'yes', 'on']);
const FALSE_VALUES = new Set(['false', '0', 'no', 'off']);
const INTEGER_PATTERN = /^-?\d+$/;

function logInvalid(
  logger: EnvParseLogger | undefined,
  name: string,
  raw: string,
  reason: string,
  fallback?: number | boolean
): void {
  logger?.warn('Invalid environment value, using fallback', {
    variable: name,
    value: raw,
    reason,
    fallback,
  });
}

function parseStrictInteger(
  raw: string,
  options: { min?: number; max?: number }
): { value?: number; reason?: string } {
  const normalized = raw.trim();
  if (normalized.length === 0 || !INTEGER_PATTERN.test(normalized)) {
    return { reason: 'not_an_integer' };
  }

  const value = Number(normalized);
  if (!Number.isSafeInteger(value)) {
    return { reason: 'not_a_safe_integer' };
  }

  if (options.min !== undefined && value < options.min) {
    return { reason: `below_min_${options.min}` };
  }

  if (options.max !== undefined && value > options.max) {
    return { reason: `above_max_${options.max}` };
  }

  return { value };
}

/**
 * Parse a required integer environment value with fallback.
 */
export function parseEnvInteger(
  raw: string | undefined,
  options: ParseEnvIntegerOptions
): number {
  if (raw === undefined) {
    return options.fallback;
  }

  const parsed = parseStrictInteger(raw, options);
  if (parsed.value === undefined) {
    logInvalid(
      options.logger,
      options.name,
      raw,
      parsed.reason ?? 'invalid_integer',
      options.fallback
    );
    return options.fallback;
  }

  return parsed.value;
}

/**
 * Parse an optional integer environment value.
 * Returns undefined when value is missing or invalid.
 */
export function parseOptionalInteger(
  raw: string | undefined,
  options: ParseOptionalIntegerOptions
): number | undefined {
  if (raw === undefined) {
    return undefined;
  }

  const parsed = parseStrictInteger(raw, options);
  if (parsed.value === undefined) {
    logInvalid(options.logger, options.name, raw, parsed.reason ?? 'invalid_integer');
  }
  return parsed.value;
}

/**
 * Parse a boolean environment value with fallback.
 */
export function parseEnvBoolean(
  raw: string | undefined,
  options: ParseEnvBooleanOptions
): boolean {
  if (raw === undefined) {
    return options.fallback;
  }

  const normalized = raw.trim().toLowerCase();
  if (TRUE_VALUES.has(normalized)) {
    return true;
  }
  if (FALSE_VALUES.has(normalized)) {
    return false;
  }

  logInvalid(
    options.logger,
    options.name,
    raw,
    'invalid_boolean',
    options.fallback
  );
  return options.fallback;
}
