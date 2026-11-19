import { GatewayError } from "../../errors.js";
import { carriesSecret, SECRET_NAME, refuseSetting as refuse } from "./secret-free.js";
import type { Direction } from "./tool-contract.js";
import type { ValueType } from "./settings-types.js";

const HINT = "subagent secrets stay out of settings";
const MAX_BYTES = 64 * 1024;
const THINKING = ["off", "minimal", "low", "medium", "high", "xhigh", "max"];

type Spec = (value: unknown, path: string) => void;
const must = (ok: boolean, path: string, expected: string) => { if (!ok) refuse(path, `must be ${expected}`); };
const isObject = (value: unknown): value is Record<string, unknown> => !!value && typeof value === "object" && !Array.isArray(value);
const bool: Spec = (value, path) => must(typeof value === "boolean", path, "a boolean");
const text: Spec = (value, path) => must(typeof value === "string" && value.trim() !== "", path, "a non-empty string");
const anyText: Spec = (value, path) => must(typeof value === "string", path, "a string");
const orFalse = (spec: Spec): Spec => (value, path) => { if (value !== false) spec(value, path); };
const oneOf = (...values: unknown[]): Spec => (value, path) => must(values.includes(value), path, `one of ${values.join(", ")}`);
const strings = (nonEmpty: boolean): Spec => (value, path) => must(Array.isArray(value) && value.length <= 256
  && value.every(item => typeof item === "string" && (!nonEmpty || item.trim() !== "")), path, `a list of ${nonEmpty ? "non-empty " : ""}strings`);
const integer = (min: number, nullable = false): Spec => (value, path) =>
  must((nullable && value === null) || (Number.isInteger(value) && (value as number) >= min), path, `${nullable ? "null or " : ""}an integer of at least ${min}`);
const object = (fields: Record<string, Spec>): Spec => (value, path) => {
  must(isObject(value), path, "an object");
  for (const [name, entry] of Object.entries(value as Record<string, unknown>)) {
    const spec = fields[name];
    if (!spec) refuse(path, `.${name} is not a pi-subagents setting`);
    spec(entry, `${path}.${name}`);
  }
};
const map = (spec: Spec): Spec => (value, path) => {
  must(isObject(value), path, "an object");
  for (const [name, entry] of Object.entries(value as Record<string, unknown>)) {
    must(name.trim() !== "", path, "keyed by non-empty names");
    spec(entry, `${path}.${name}`);
  }
};

const machine: Spec = (value, path) => must(typeof value === "string" && value.trim() !== "" && value.trim().length <= 128
  && !/[\u0000-\u001f\u007f]/u.test(value), path, "a machine name of at most 128 characters");
const override = object({
  description: text, advertise: bool, output: orFalse(text), outputMode: oneOf("inline", "file-only"), model: orFalse(anyText), fast: bool,
  thinking: orFalse(anyText), systemPromptMode: oneOf("append", "replace"), inheritProjectContext: bool, inheritGlobalContext: bool,
  inheritSkills: bool, defaultContext: oneOf("fresh", "fork", false), acceptanceRole: oneOf("read-only", "writer", false), disabled: bool,
  toolBudget: orFalse(object({ soft: integer(0), hard: integer(0), block: (value, path) => { if (value !== "*") strings(false)(value, path); } })),
  systemPrompt: anyText, machine: orFalse(machine), defaultProvider: orFalse(text), allowNestedSubagents: bool,
  tools: (value, path) => { if (value !== "inherit") orFalse(strings(false))(value, path); },
  ...Object.fromEntries(["defaultReads", "skills", "excludeTools", "allowedAgents", "extensions", "subagentOnlyExtensions", "mutationTools"]
    .map(name => [name, orFalse(strings(false))])),
});
const allow: Spec = (value, path) => must(Array.isArray(value) && value.some(item => typeof item === "string" && item.trim() !== "")
  && value.every(item => typeof item === "string"), path, "a non-empty list of model patterns");
const scopeRule = { enforce: bool, strict: bool, allow };
const modelScope: Spec = (value, path) => {
  object({ ...scopeRule, agents: map(object(scopeRule)) })(value, path);
  const scope = value as { enforce?: boolean; allow?: unknown[]; agents?: Record<string, { allow?: unknown[] }> };
  must(scope.enforce !== true || !!scope.allow?.length || Object.values(scope.agents ?? {}).some(rule => !!rule.allow?.length),
    path, "given an allow list when enforce is on");
};
const thinkingOrFalse = oneOf(...THINKING, false);
const cadence = object({ everyNTools: integer(5, true) });
const watchdog = object({
  enabled: bool, clarification: bool, agentEndTimeoutMs: integer(1), severityThreshold: oneOf("concern", "blocker"),
  maxWarnings: integer(0, true), guidance: object({ watchdogMd: bool }), stalemateRepeats: integer(1), scope: object({ enabled: bool }), cadence,
  main: object({ enabled: bool, model: text, thinking: thinkingOrFalse }),
  children: object({ enabled: bool, model: text, thinking: thinkingOrFalse, watchdogTailTimeoutMs: integer(1), cadence,
    overrides: map(object({ enabled: bool, model: text, thinking: thinkingOrFalse, cadence })) }),
  lsp: object({ enabled: bool, timeoutMs: integer(1), maxFiles: integer(1), maxDiagnostics: integer(0) }),
  rules: object({ action: oneOf("warn", "block"), roleModels: map(object({ allow: strings(true), deny: strings(true), note: text })) }),
});
const settings = object({
  disableBuiltins: bool, disableThinking: bool, defaultModel: text, defaultProvider: text, defaultThinking: text,
  maxThinking: oneOf(...THINKING), projectRootResolution: oneOf("nearest", "git-root"),
  defaultExtensions: strings(true), defaultSubagentOnlyExtensions: strings(true), agentScanDirs: strings(true), agentExcludeDirs: strings(true),
  agentOverrides: map(override), agentOverridesByProvider: map(map(override)), modelScope, watchdog,
  machines: map(object({
    cwd: (value, path) => must(typeof value === "string" && /^(?:\/|~)/u.test(value.trim()) && !/[\u0000-\u001f\u007f]/u.test(value),
      path, "an absolute POSIX path or one starting with ~"),
    env: (value, path) => must(isObject(value) && Object.keys(value).length === 0, path,
      "empty: saved-machine runs use the remote machine's environment"),
  })),
});

function refuseSecret(value: unknown, label: string): void {
  if (Buffer.byteLength(JSON.stringify(value)) > MAX_BYTES) refuse(label, `must be at most ${MAX_BYTES} bytes`);
  if (carriesSecret(value)) refuse(label, `carries a credential or a secret-named field; ${HINT}`);
}

const onDiskRefusal = (label: string): never => {
  throw new GatewayError("conflict", `${label} on disk carries a credential or a secret-named field; it cannot be changed here, edit it by hand`);
};

export const subagentSettingsType: ValueType = {
  kind: "subagentSettings",
  validate: (value, label) => { settings(value, label); refuseSecret(value, label); return value; },
  onDisk: (value, label) => { if (carriesSecret(value)) onDiskRefusal(label); },
  format: value => Object.keys(value as Record<string, unknown>).sort().join(", ") || "None",
};

const frontmatterOf = (text: string) => /^---\n([\s\S]*?)\n---(?:\n|$)/u.exec(text)?.[1];
const secretNamedField = (text: string) => [...(frontmatterOf(text) ?? "").matchAll(/^\s*([A-Za-z0-9_-]+)\s*:/gmu)].some(field => SECRET_NAME.test(field[1]!));
const agentSecret = (text: string) => carriesSecret(text) || secretNamedField(text);

function validateAgentDefinition(raw: unknown, label: string, name: string | undefined): string {
  if (typeof raw !== "string") throw new GatewayError("invalid_request", `${label} must be the agent's Markdown text`);
  const frontmatter = frontmatterOf(raw);
  if (frontmatter === undefined) refuse(label, "must open with YAML frontmatter between --- lines");
  if (!new RegExp(`^name:\\s*${(name ?? "").replace(/[.]/gu, "\\.")}\\s*$`, "mu").test(frontmatter)) refuse(label, `frontmatter must declare name: ${name}`);
  if (!/^description:\s*\S/mu.test(frontmatter)) refuse(label, "frontmatter must declare a description; pi-subagents skips an agent without one");
  if (secretNamedField(raw)) refuse(label, `carries a credential or a secret-named field; ${HINT}`);
  refuseSecret(raw, label);
  return raw;
}

export const agentDefinitionDirection = (_before: unknown, after: unknown): Direction => after === undefined ? "narrow" : "widen";

export const agentDefinitionType: ValueType = {
  kind: "agentDefinition",
  validate: (value, label, context) => validateAgentDefinition(value, label, context?.instance),
  onDisk: (value, label) => { if (typeof value === "string" && agentSecret(value)) onDiskRefusal(label); },
  format: value => {
    const text = value as string;
    const description = /^description:\s*(.+)$/mu.exec(text)?.[1]?.trim();
    const lines = text.split("\n").length;
    return `${description ? `${description}; ` : ""}${lines} line${lines === 1 ? "" : "s"}`;
  },
};
