import { readFileSync } from "node:fs";
import { stripFrontmatter } from "@earendil-works/pi-coding-agent";
import type { ResourceInvocation } from "../protocol/types.js";
import { GatewayError } from "../errors.js";

/** Resource limits are UTF-8 byte limits because they bound JSONL and wire data. */
export const RESOURCE_NAME_MAX_BYTES = 512;
// Invocation receipts are bounded to 8 KiB; this leaves room for immutable
// identity and lifecycle metadata without truncating semantic arguments.
export const RESOURCE_ARGUMENTS_MAX_BYTES = 5_000;
const MAX_SKILL_INVOCATION_BYTES = 4 * 1_048_576;
const MAX_SKILL_PATH_BYTES = 8_192;

interface ProjectedSkillInvocation {
  resourceName: string;
  text: string;
}

/** Recognizes only Pi's exact persisted skill envelope. */
export function projectSkillInvocation(value: string, expectedArguments?: string): ProjectedSkillInvocation | undefined {
  if (!value.startsWith("<skill name=\"") || Buffer.byteLength(value) > MAX_SKILL_INVOCATION_BYTES) return undefined;
  const headerEnd = value.indexOf(">\n");
  if (headerEnd < 0 || headerEnd > RESOURCE_NAME_MAX_BYTES + MAX_SKILL_PATH_BYTES + 64) return undefined;
  const match = /^<skill name="([A-Za-z0-9][A-Za-z0-9._-]*)" location="([^"\r\n]+)">$/.exec(value.slice(0, headerEnd + 1));
  if (!match) return undefined;
  const [, resourceName, location] = match;
  if (!resourceName || !location || Buffer.byteLength(resourceName) > RESOURCE_NAME_MAX_BYTES
      || Buffer.byteLength(location) > MAX_SKILL_PATH_BYTES) return undefined;
  const bodyStart = headerEnd + 2;
  const referenceEnd = value.indexOf("\n\n", bodyStart);
  if (referenceEnd < 0) return undefined;
  const reference = value.slice(bodyStart, referenceEnd);
  const referencePrefix = "References are relative to ";
  if (!reference.startsWith(referencePrefix) || !reference.endsWith(".")) return undefined;
  const baseDir = reference.slice(referencePrefix.length, -1);
  if (!baseDir || /[\r\n]/u.test(baseDir) || Buffer.byteLength(baseDir) > MAX_SKILL_PATH_BYTES) return undefined;
  const closing = "\n</skill>";
  let closingIndex = value.lastIndexOf(closing);
  if (expectedArguments !== undefined) {
    let matched = false;
    let candidate = value.indexOf(closing, referenceEnd + 2);
    while (candidate >= 0) {
      const tail = value.slice(candidate + closing.length);
      if ((tail === "" && expectedArguments === "")
        || (tail.startsWith("\n\n") && tail.slice(2) === expectedArguments)) {
        closingIndex = candidate;
        matched = true;
        break;
      }
      candidate = value.indexOf(closing, candidate + closing.length);
    }
    if (!matched) return undefined;
  } else if (value.indexOf(closing, referenceEnd + 2) !== closingIndex) {
    return undefined;
  }
  if (closingIndex < referenceEnd + 2) return undefined;
  const tail = value.slice(closingIndex + closing.length);
  if (tail !== "" && !tail.startsWith("\n\n")) return undefined;
  return { resourceName, text: tail === "" ? "" : tail.slice(2) };
}

function friendlyResourceName(value: string): string {
  const words = value.replace(/^skill:/u, "").replace(/[._-]+/gu, " ").trim();
  return words ? words[0]!.toLocaleUpperCase() + words.slice(1) : "New session";
}

/**
 * Skips the leading skill blocks of a composed message (#311) for a preview.
 * Each block ends at the first `</skill>` line followed by the next block or the
 * end; a skill body quoting that line can shorten a preview, never identity.
 */
function afterLeadingSkillBlocks(value: string): { resourceName: string; text: string } | undefined {
  let rest = value;
  let resourceName: string | undefined;
  const header = /^<skill name="([A-Za-z0-9][A-Za-z0-9._-]*)" location="[^"\r\n]+">\n/u;
  while (rest.startsWith("<skill name=\"")) {
    const match = header.exec(rest.slice(0, RESOURCE_NAME_MAX_BYTES + MAX_SKILL_PATH_BYTES + 64));
    const closing = rest.indexOf("\n</skill>");
    if (!match || closing < 0) return undefined;
    resourceName = match[1]!;
    const tail = rest.slice(closing + "\n</skill>".length);
    if (tail !== "" && !tail.startsWith("\n\n")) return undefined;
    rest = tail.slice(2);
  }
  return resourceName === undefined ? undefined : { resourceName, text: rest };
}

/** Removes machine-authored invocation syntax from user-facing session titles. */
export function userFacingPromptPreview(value: string): string {
  const skill = projectSkillInvocation(value) ?? afterLeadingSkillBlocks(value);
  if (skill) return skill.text.trim() || friendlyResourceName(skill.resourceName);
  const command = parsePiLiteralCommand(value);
  if (command) return command.arguments.trim() || friendlyResourceName(command.name);
  return value.trim();
}

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

function admitResourceName(value: unknown): string {
  const name = admittedText(value, "resourceInvocation.name", RESOURCE_NAME_MAX_BYTES, false);
  // Pi command tokens cannot contain whitespace. Reject catalog entries that
  // could be displayed but never invoked through their declared identity.
  if (/\s/u.test(name)) {
    throw new GatewayError("invalid_request", "resourceInvocation.name contains whitespace");
  }
  return name;
}

export function canonicalResourceName(source: ResourceInvocation["source"], name: string): string {
  if (source === "skill") {
    return name.startsWith("skill:") ? name : `skill:${name}`;
  }
  return name;
}

/** The UTF-8 bytes one prompt's text may carry. Home's source bound is derived from it. */
export const PROMPT_TEXT_MAX_BYTES = 192 * 1_024;

export function admitPromptText(value: string, maximumBytes = PROMPT_TEXT_MAX_BYTES): string {
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

/** One message may combine at most this many skills and prompts. */
export const MAXIMUM_RESOURCE_INVOCATIONS = 16;

/**
 * Admits one chat message's ordered resources (#311). Skills and prompts combine
 * in any order, each at most once, and carry no arguments: the message text
 * follows every expansion once. An extension command runs instead of a message,
 * so it is exclusive and its arguments are exactly the message text.
 */
export function admitResourceInvocations(value: unknown, text: string): ResourceInvocation[] {
  if (!Array.isArray(value) || value.length === 0 || value.length > MAXIMUM_RESOURCE_INVOCATIONS) {
    throw new GatewayError("invalid_request", `resourceInvocations must list 1 to ${MAXIMUM_RESOURCE_INVOCATIONS} resources`);
  }
  const resources = value.map(admitResourceInvocation);
  if (resources.some(resource => resource.source === "extension")) {
    if (resources.length !== 1) {
      throw new GatewayError("invalid_request", "An extension command cannot be combined with other resources");
    }
    if (resources[0]!.arguments !== text) {
      throw new GatewayError("invalid_request", "Prompt text must exactly match the extension command's arguments");
    }
    return resources;
  }
  if (resources.some(resource => resource.arguments !== "")) {
    throw new GatewayError("invalid_request", "Skill and prompt resources carry no arguments; the message text follows them");
  }
  const seen = new Set<string>();
  for (const resource of resources) {
    if (!seen.add(`${resource.source}:${resource.name}`)) {
      throw new GatewayError("invalid_request", "resourceInvocations lists a resource more than once");
    }
  }
  return resources;
}

/** The loaded skills and prompt templates one session expands resources from. */
export interface ResourceExpansionCatalog {
  skills: ReadonlyArray<{ name: string; filePath: string; baseDir: string }>;
  promptTemplates: ReadonlyArray<{ name: string; content: string }>;
}

/** Pi's template placeholders, as Pi substitutes them with no arguments. */
const TEMPLATE_PLACEHOLDER = /\$\{(\d+|ARGUMENTS|@):-([^}]*)\}|\$\{@:(\d+)(?::(\d+))?\}|\$(ARGUMENTS|@|\d+)/g;

/**
 * The model input for a message that invokes skills and prompts: each resource
 * expanded in order, then the visible prompt once. Pi expands only one leading
 * slash command, so Gateway composes the set and hands Pi the result with
 * expansion off. A skill block is byte-identical to Pi's own expansion, which
 * transcript projection and the model's skill contract recognize; a prompt
 * template expands as Pi would with no arguments.
 */
export function composeResourcePrompt(
  resources: readonly ResourceInvocation[],
  visiblePrompt: string,
  catalog: ResourceExpansionCatalog,
): string {
  const expansions = resources.map((resource) => {
    if (resource.source === "skill") {
      const skill = catalog.skills.find(candidate => candidate.name === resource.name);
      if (!skill) throw new GatewayError("conflict", `Skill "${resource.name}" is no longer available for this session`);
      let content: string;
      try {
        content = readFileSync(skill.filePath, "utf8");
      } catch {
        throw new GatewayError("conflict", `Skill "${resource.name}" could not be read`);
      }
      const body = stripFrontmatter(content).trim();
      return `<skill name="${skill.name}" location="${skill.filePath}">\nReferences are relative to ${skill.baseDir}.\n\n${body}\n</skill>`;
    }
    if (resource.source === "prompt") {
      const template = catalog.promptTemplates.find(candidate => candidate.name === resource.name);
      if (!template) throw new GatewayError("conflict", `Prompt "${resource.name}" is no longer available for this session`);
      // Trimmed like a skill body, so parts join with exactly one blank line.
      return template.content.replace(TEMPLATE_PLACEHOLDER, (_match, defaultTarget: string | undefined, defaultValue: string | undefined) =>
        defaultTarget ? defaultValue ?? "" : "").trim();
    }
    throw new GatewayError("invalid_request", "Extension commands are not composed into a message");
  });
  return [...expansions, visiblePrompt].filter(part => part.length > 0).join("\n\n");
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
