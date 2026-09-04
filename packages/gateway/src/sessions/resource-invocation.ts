import type { ResourceInvocation } from "../protocol/types.js";
import { GatewayError } from "../errors.js";

/** Resource limits are UTF-8 byte limits because they bound JSONL and wire data. */
export const RESOURCE_NAME_MAX_BYTES = 512;
// Invocation receipts are bounded to 8 KiB; this leaves room for immutable
// identity and lifecycle metadata without truncating semantic arguments.
export const RESOURCE_ARGUMENTS_MAX_BYTES = 5_000;

function admittedText(value: unknown, field: string, maximumBytes: number, allowEmpty = true): string {
  if (typeof value !== "string") throw new GatewayError("invalid_request", `${field} must be a string`);
  if (!allowEmpty && value.length === 0) throw new GatewayError("invalid_request", `${field} is required`);
  if (Buffer.byteLength(value, "utf8") > maximumBytes) {
    throw new GatewayError("invalid_request", `${field} exceeds ${maximumBytes} UTF-8 bytes`);
  }
  // Newline, carriage return, and tab are valid prompt content. Other controls
  // cannot be represented safely in invocation identity or Pi command text.
  if (/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/u.test(value)) {
    throw new GatewayError("invalid_request", `${field} contains unsupported control characters`);
  }
  return value;
}

export function admitResourceName(value: unknown, field = "resourceInvocation.name"): string {
  const name = admittedText(value, field, RESOURCE_NAME_MAX_BYTES, false);
  // Pi command tokens cannot contain whitespace. Reject catalog entries that
  // could be displayed but never invoked through their declared identity.
  if (/\s/u.test(name)) {
    throw new GatewayError("invalid_request", `${field} contains whitespace`);
  }
  return name;
}

export function canonicalResourceName(source: ResourceInvocation["source"], name: string): string {
  if (source === "skill") {
    return name.startsWith("skill:") ? name : `skill:${name}`;
  }
  return name;
}

export function admitPromptText(value: string, maximumBytes = 192 * 1_024): string {
  return admittedText(value, "text", maximumBytes);
}

export function admitResourceInvocation(value: unknown): ResourceInvocation {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new GatewayError("invalid_request", "resourceInvocation must be an object");
  }
  const candidate = value as Record<string, unknown>;
  if (!["skill", "prompt", "extension"].includes(candidate.source as string)) {
    throw new GatewayError("invalid_request", "resourceInvocation.source must be skill, prompt, or extension");
  }
  const source = candidate.source as ResourceInvocation["source"];
  const rawName = admitResourceName(candidate.name);
  const name = canonicalResourceName(source, rawName);
  if (source === "skill" && !/^skill:[A-Za-z0-9][A-Za-z0-9._-]*$/u.test(name)) {
    throw new GatewayError("invalid_request", "resourceInvocation.name is not a valid skill name");
  }
  const argumentsText = admittedText(candidate.arguments, "resourceInvocation.arguments", RESOURCE_ARGUMENTS_MAX_BYTES);
  const allowed = new Set(["source", "name", "arguments"]);
  if (Object.keys(candidate).some(key => !allowed.has(key))) {
    throw new GatewayError("invalid_request", "resourceInvocation contains unknown fields");
  }
  return { source, name: source === "skill" ? name.slice("skill:".length) : name, arguments: argumentsText };
}

/** The Pi extension/skill command delimiter is literal ASCII space. */
export function parsePiLiteralCommand(text: string): { name: string; arguments: string } | undefined {
  if (!text.startsWith("/")) return undefined;
  const rest = text.slice(1);
  const separator = rest.indexOf(" ");
  const name = separator < 0 ? rest : rest.slice(0, separator);
  if (!name) return undefined;
  return { name, arguments: separator < 0 ? "" : rest.slice(separator + 1) };
}
