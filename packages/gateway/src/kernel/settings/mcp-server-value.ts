import { GatewayError } from "../../errors.js";
import { redactCredentials } from "../../util/credential-redaction.js";
import { arrayOfStrings, boolean, object, oneOf, string } from "../../util/validation.js";
import type { Direction } from "./tool-contract.js";
import type { ValueType } from "./settings-types.js";

export const MCP_EXPOSURES = ["codemode", "codemode-deferred", "deferred", "direct", "hidden"] as const;
export type McpExposure = typeof MCP_EXPOSURES[number];

export interface McpServerValue {
  command?: string;
  args?: string[];
  url?: string;
  bearerRef?: string;
  enabled?: boolean;
  exposure?: McpExposure;
}

const FIELDS = ["command", "args", "url", "bearerRef", "enabled", "exposure"] as const;
const SECRET_NAME = /(token|secret|password|passwd|api[-_]?key|apikey|credential|bearer|authorization)/iu;
const OP_REFERENCE = /^op:\/\/([A-Za-z0-9._ -]{1,256})\/([A-Za-z0-9._ -]{1,256})\/([A-Za-z0-9._ -]{1,256})$/u;
const KEYCHAIN_REFERENCE = /^keychain:\/\/([A-Za-z0-9._-]{1,256})\/([A-Za-z0-9._-]{1,256})$/u;
const OP_BINARY = "/opt/homebrew/bin/op";
const SECURITY_BINARY = "/usr/bin/security";
const SED_BEARER = "/usr/bin/sed 's/^/Bearer /'";
const KEYCHAIN_COMMAND = /^!\/usr\/bin\/security find-generic-password -s ([A-Za-z0-9._-]{1,256}) -a ([A-Za-z0-9._-]{1,256}) -w \| \/usr\/bin\/sed 's\/\^\/Bearer \/'$/u;
const OP_COMMAND = /^!\/opt\/homebrew\/bin\/op read --no-newline '(op:\/\/[^']+)' \| \/usr\/bin\/sed 's\/\^\/Bearer \/'$/u;

function refuse(label: string, reason: string): never {
  throw new GatewayError("invalid_request", `${label} ${reason}`);
}

export function isBearerReference(ref: string): boolean {
  return OP_REFERENCE.test(ref) || KEYCHAIN_REFERENCE.test(ref);
}

export function bearerCommand(ref: string): string {
  const keychain = KEYCHAIN_REFERENCE.exec(ref);
  if (keychain) return `!${SECURITY_BINARY} find-generic-password -s ${keychain[1]} -a ${keychain[2]} -w | ${SED_BEARER}`;
  if (OP_REFERENCE.test(ref)) return `!${OP_BINARY} read --no-newline '${ref}' | ${SED_BEARER}`;
  throw new Error("bearer reference is not an op:// or keychain:// reference");
}

export function bearerReferenceOf(command: string): string | undefined {
  const keychain = KEYCHAIN_COMMAND.exec(command);
  const ref = keychain ? `keychain://${keychain[1]}/${keychain[2]}` : OP_COMMAND.exec(command)?.[1];
  return ref !== undefined && isBearerReference(ref) && bearerCommand(ref) === command ? ref : undefined;
}

function secretFreeText(text: string, label: string, what: string): string {
  if (redactCredentials(text) !== text) refuse(label, `${what} carries a credential; MCP secrets are never accepted through settings, reference a bearer token with bearerRef`);
  if (/[\u0000\r\n]/u.test(text)) refuse(label, `${what} has a control character`);
  return text;
}

function secretFreeToken(token: string, label: string, what: string): string {
  secretFreeText(token, label, what);
  const name = token.replace(/^-{1,2}/u, "").split("=", 1)[0]!;
  if (SECRET_NAME.test(name)) refuse(label, `${what} names a secret; MCP secrets are set in mcp.json or the app, never through settings`);
  return token;
}

function secretFreeUrl(value: string, label: string): string {
  secretFreeText(value, label, "url");
  let parsed: URL;
  try { parsed = new URL(value); } catch { refuse(label, "must be an absolute URL"); }
  if (parsed.protocol !== "https:" && parsed.protocol !== "http:") refuse(label, "must use HTTP or HTTPS");
  if (parsed.username || parsed.password) refuse(label, "must not carry credentials; MCP secrets are set in mcp.json or the app");
  for (const name of parsed.searchParams.keys()) {
    if (SECRET_NAME.test(name)) refuse(label, "carries a secret in its query; MCP secrets are set in mcp.json or the app");
  }
  return value;
}

export function validateMcpServerValue(value: unknown, label: string): McpServerValue {
  const raw = object(value, label);
  for (const name of Object.keys(raw)) {
    if (!(FIELDS as readonly string[]).includes(name)) {
      refuse(label, `field ${name} is not an MCP setting here; secrets are never accepted (reference a bearer token with bearerRef), and env, headers, oauth and other fields are set in mcp.json or the app`);
    }
  }
  const hasCommand = raw.command !== undefined;
  const hasUrl = raw.url !== undefined;
  if (hasCommand === hasUrl) refuse(label, "needs exactly one of command (stdio) or url (HTTP)");
  const result: McpServerValue = {};
  if (hasCommand) {
    const command = secretFreeText(string(raw.command, `${label}.command`, { min: 1, max: 1_024 }), label, "command");
    for (const token of command.split(/\s+/u)) secretFreeToken(token, label, "command");
    result.command = command;
    if (raw.args !== undefined) result.args = arrayOfStrings(raw.args, `${label}.args`, 64).map(argument => secretFreeToken(argument, label, "argument"));
    if (raw.bearerRef !== undefined) refuse(label, "bearerRef applies only to a url");
  } else {
    if (raw.args !== undefined) refuse(label, "args apply only to a command");
    result.url = secretFreeUrl(string(raw.url, `${label}.url`, { min: 1, max: 4_096 }), label);
    if (raw.bearerRef !== undefined) {
      const ref = string(raw.bearerRef, `${label}.bearerRef`, { min: 1, max: 1_024 });
      if (!isBearerReference(ref)) refuse(label, "bearerRef must be an op:// or keychain:// reference; a secret value is never accepted here");
      result.bearerRef = ref;
    }
  }
  if (raw.enabled !== undefined) result.enabled = boolean(raw.enabled, `${label}.enabled`);
  if (raw.exposure !== undefined) result.exposure = oneOf(raw.exposure, `${label}.exposure`, MCP_EXPOSURES);
  return result;
}

export function mcpServerToDisk(value: McpServerValue): Record<string, unknown> {
  const { bearerRef, ...rest } = value;
  return bearerRef === undefined ? rest : { ...rest, headers: { Authorization: bearerCommand(bearerRef) } };
}

export function mcpServerOnDisk(server: string, raw: unknown): McpServerValue {
  try {
    const label = `MCP server ${server}`;
    const { headers, ...rest } = object(raw, label);
    if (rest.bearerRef !== undefined) refuse(label, "has a bearerRef on disk; credentials are stored only as headers");
    const result = validateMcpServerValue(rest, label);
    if (headers === undefined) return result;
    const authorization = object(headers, `${label}.headers`);
    const ref = Object.keys(authorization).length === 1 && typeof authorization.Authorization === "string"
      ? bearerReferenceOf(authorization.Authorization) : undefined;
    if (ref === undefined || result.url === undefined) refuse(label, "has headers that are not a Tron credential reference");
    return { ...result, bearerRef: ref };
  } catch (error) {
    const reason = error instanceof Error ? error.message.replace(/^MCP server \S+ /u, "") : "cannot be read";
    throw new GatewayError("conflict", `MCP server ${server} cannot be changed here: its configuration ${reason}; edit mcp.json or use the app`);
  }
}

const VISIBILITY: Record<McpExposure | "codemode-deferred", number> = { hidden: 0, codemode: 1, "codemode-deferred": 1, deferred: 1, direct: 2 };

function visibility(value: McpServerValue | undefined): number {
  return value === undefined || value.enabled === false ? 0 : VISIBILITY[value.exposure ?? "codemode"];
}

export function mcpServerDirection(before: unknown, after: unknown): Direction {
  if (after === undefined) return "narrow";
  if (before === undefined) return "widen";
  const was = before as McpServerValue;
  const now = after as McpServerValue;
  if (JSON.stringify([was.command, was.args ?? [], was.url, was.bearerRef]) !== JSON.stringify([now.command, now.args ?? [], now.url, now.bearerRef])) return "widen";
  return visibility(now) > visibility(was) ? "widen" : "narrow";
}

export const mcpServerType: ValueType = {
  kind: "mcpServer",
  validate: (value, label) => validateMcpServerValue(value, label),
  format: value => {
    const server = value as McpServerValue;
    const launch = server.command !== undefined ? [server.command, ...(server.args ?? [])].join(" ") : server.url!;
    return [launch, server.bearerRef ? `bearer ${server.bearerRef}` : undefined, server.enabled === false ? "disabled" : undefined, server.exposure ? `exposure ${server.exposure}` : undefined]
      .filter(Boolean).join(", ");
  },
};
