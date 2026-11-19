import { GatewayError } from "../../errors.js";
import { redactCredentials } from "../../util/credential-redaction.js";
import { SECRET_NAME, refuseSetting as refuse } from "./secret-free.js";
import type { Direction } from "./tool-contract.js";
import type { ValueType } from "./settings-types.js";

const HINT = "subagent secrets stay out of settings";
const MAX_BYTES = 64 * 1024;
const THINKING = ["off", "minimal", "low", "medium", "high", "xhigh", "max"];
const FIELDS: Record<string, "boolean" | "string" | "strings" | "object" | "thinking" | "root"> = {
  disableBuiltins: "boolean", disableThinking: "boolean",
  defaultModel: "string", defaultProvider: "string", defaultThinking: "string", maxThinking: "thinking", projectRootResolution: "root",
  defaultExtensions: "strings", defaultSubagentOnlyExtensions: "strings", agentScanDirs: "strings", agentExcludeDirs: "strings",
  agentOverrides: "object", agentOverridesByProvider: "object", machines: "object", modelScope: "object", watchdog: "object",
};

function secretFree(value: unknown, label: string): void {
  const encoded = JSON.stringify(value);
  if (Buffer.byteLength(encoded) > MAX_BYTES) refuse(label, `must be at most ${MAX_BYTES} bytes`);
  if (redactCredentials(encoded) !== encoded) refuse(label, `carries a credential; ${HINT}`);
  const names = (node: unknown): void => {
    if (!node || typeof node !== "object") return;
    for (const [name, child] of Object.entries(node)) {
      if (!Array.isArray(node) && SECRET_NAME.test(name)) refuse(label, `names a secret; ${HINT}`);
      names(child);
    }
  };
  names(value);
}

function validateSubagentSettings(raw: unknown, label: string): Record<string, unknown> {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) refuse(label, "must be an object");
  const value = raw as Record<string, unknown>;
  for (const [field, entry] of Object.entries(value)) {
    const kind = FIELDS[field];
    if (!kind) refuse(label, `.${field} is not a pi-subagents setting`);
    const valid = kind === "boolean" ? typeof entry === "boolean"
      : kind === "string" ? typeof entry === "string" && entry.trim() !== ""
        : kind === "thinking" ? THINKING.includes(entry as string)
          : kind === "root" ? entry === "nearest" || entry === "git-root"
            : kind === "strings" ? Array.isArray(entry) && entry.length <= 256 && entry.every(item => typeof item === "string" && item.trim() !== "")
              : !!entry && typeof entry === "object" && !Array.isArray(entry);
    if (!valid) refuse(label, `.${field} must be ${kind === "strings" ? "a list of non-empty strings" : kind === "thinking" ? `one of ${THINKING.join(", ")}` : kind === "root" ? "nearest or git-root" : `a${kind === "object" ? "n" : ""} ${kind}`}`);
  }
  secretFree(value, label);
  return value;
}

export const subagentSettingsType: ValueType = {
  kind: "subagentSettings",
  validate: validateSubagentSettings,
  format: value => Object.keys(value as Record<string, unknown>).sort().join(", ") || "None",
};

function validateAgentDefinition(raw: unknown, label: string, name: string | undefined): string {
  if (typeof raw !== "string") throw new GatewayError("invalid_request", `${label} must be the agent's Markdown text`);
  const frontmatter = /^---\n([\s\S]*?)\n---(?:\n|$)/u.exec(raw)?.[1];
  if (frontmatter === undefined) refuse(label, "must open with YAML frontmatter between --- lines");
  if (!new RegExp(`^name:\\s*${(name ?? "").replace(/[.]/gu, "\\.")}\\s*$`, "mu").test(frontmatter)) refuse(label, `frontmatter must declare name: ${name}`);
  for (const field of frontmatter.matchAll(/^\s*([A-Za-z0-9_-]+)\s*:/gmu)) if (SECRET_NAME.test(field[1]!)) refuse(label, `names a secret; ${HINT}`);
  secretFree(raw, label);
  return raw;
}

export const agentDefinitionDirection = (_before: unknown, after: unknown): Direction => after === undefined ? "narrow" : "widen";

export const agentDefinitionType: ValueType = {
  kind: "agentDefinition",
  validate: (value, label, context) => validateAgentDefinition(value, label, context?.instance),
  format: value => {
    const text = value as string;
    const description = /^description:\s*(.+)$/mu.exec(text)?.[1]?.trim();
    const lines = text.split("\n").length;
    return `${description ? `${description}; ` : ""}${lines} line${lines === 1 ? "" : "s"}`;
  },
};
