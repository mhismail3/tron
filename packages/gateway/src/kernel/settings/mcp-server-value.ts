import { GatewayError } from "../../errors.js";
import { arrayOfStrings, boolean, object, oneOf, string } from "../../util/validation.js";
import type { Direction } from "./tool-contract.js";
import type { ValueType } from "./settings-types.js";

export const MCP_EXPOSURES = ["codemode", "codemode-deferred", "deferred", "direct", "hidden"] as const;
export type McpExposure = typeof MCP_EXPOSURES[number];

export interface McpServerValue {
  command?: string;
  args?: string[];
  url?: string;
  enabled?: boolean;
  exposure?: McpExposure;
}

const FIELDS = ["command", "args", "url", "enabled", "exposure"] as const;
const SECRET_NAME = /(token|secret|password|passwd|api[-_]?key|apikey|credential|bearer|authorization)/iu;

function refuse(label: string, reason: string): never {
  throw new GatewayError("invalid_request", `${label} ${reason}`);
}

function secretFreeArgument(argument: string, label: string): string {
  const name = argument.replace(/^-{1,2}/u, "").split("=", 1)[0]!;
  if (SECRET_NAME.test(name)) refuse(label, "names a secret; MCP secrets are set in mcp.json or the app, never through settings");
  if (/[\u0000\r\n]/u.test(argument)) refuse(label, "has a control character");
  return argument;
}

function secretFreeUrl(value: string, label: string): string {
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
      refuse(label, `field ${name} is not an MCP setting here; secrets (env, headers, oauth, tokens) and other fields are set in mcp.json or the app`);
    }
  }
  const hasCommand = raw.command !== undefined;
  const hasUrl = raw.url !== undefined;
  if (hasCommand === hasUrl) refuse(label, "needs exactly one of command (stdio) or url (HTTP)");
  const result: McpServerValue = {};
  if (hasCommand) {
    const command = string(raw.command, `${label}.command`, { min: 1, max: 1_024 });
    if (/[\u0000\r\n]/u.test(command)) refuse(label, "command has a control character");
    result.command = command;
    if (raw.args !== undefined) result.args = arrayOfStrings(raw.args, `${label}.args`, 64).map(argument => secretFreeArgument(argument, label));
  } else {
    if (raw.args !== undefined) refuse(label, "args apply only to a command");
    result.url = secretFreeUrl(string(raw.url, `${label}.url`, { min: 1, max: 4_096 }), label);
  }
  if (raw.enabled !== undefined) result.enabled = boolean(raw.enabled, `${label}.enabled`);
  if (raw.exposure !== undefined) result.exposure = oneOf(raw.exposure, `${label}.exposure`, MCP_EXPOSURES);
  return result;
}

export function mcpServerOnDisk(server: string, raw: unknown): McpServerValue {
  try {
    return validateMcpServerValue(raw, `MCP server ${server}`);
  } catch (error) {
    const reason = error instanceof Error ? error.message.replace(/^MCP server \S+ /u, "") : "cannot be read";
    throw new GatewayError("conflict", `MCP server ${server} cannot be changed here: its configuration ${reason}; edit mcp.json or use the app`);
  }
}

function runs(value: McpServerValue | undefined): boolean {
  return value !== undefined && value.enabled !== false;
}

export function mcpServerDirection(before: unknown, after: unknown): Direction {
  if (after === undefined) return "narrow";
  if (before === undefined) return "widen";
  const was = before as McpServerValue;
  const now = after as McpServerValue;
  if (!runs(was) && runs(now)) return "widen";
  if (JSON.stringify([was.command, was.args ?? [], was.url]) !== JSON.stringify([now.command, now.args ?? [], now.url])) return "widen";
  return "narrow";
}

export const mcpServerType: ValueType = {
  kind: "mcpServer",
  validate: (value, label) => validateMcpServerValue(value, label),
  format: value => {
    const server = value as McpServerValue;
    const launch = server.command !== undefined ? [server.command, ...(server.args ?? [])].join(" ") : server.url!;
    return [launch, server.enabled === false ? "disabled" : undefined, server.exposure ? `exposure ${server.exposure}` : undefined]
      .filter(Boolean).join(", ");
  },
};
