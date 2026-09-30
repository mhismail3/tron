import { basename } from "node:path";

/** Where one piece of the assembled prompt came from. `pi` is text Pi itself
 * writes; `module` is a built-in Tron extension (`<inline:name>`); `package` is
 * an installed Pi package; `local` is a user/project extension or skill file;
 * `file` is an instruction file Pi reads verbatim (AGENTS.md, SYSTEM.md,
 * APPEND_SYSTEM.md). */
export type InstructionSource =
  | { kind: "pi" }
  | { kind: "module"; name: string }
  | { kind: "package"; name: string }
  | { kind: "local"; scope: string; path: string }
  | { kind: "file"; path: string }
  | { kind: "unknown" };

export interface InstructionEntry {
  name?: string;
  path?: string;
  text: string;
  /** Tools whose guidelines produced this rule; empty for Pi's own rules. */
  tools?: string[];
  source: InstructionSource;
}

export interface InstructionSection {
  /** Pi's section name (`preamble`, `tools`, …), `tron` for the per-turn
   * operating context, or `prompt` when the text has no recognisable structure. */
  id: string;
  /** `session`: part of the session's base prompt. `turn`: added when each
   * turn starts and not stored in the session. */
  timing: "session" | "turn";
  /** The section body as the model reads it, without Pi's `<name>` wrapper. */
  text: string;
  source?: InstructionSource;
  entries?: InstructionEntry[];
}

export interface AgentInstructions {
  /** The exact system prompt the model receives for a turn. */
  text: string;
  sections: InstructionSection[];
}

interface SourceInfoLike { path: string; source: string; scope: string; origin: string }

export interface AgentInstructionsInput {
  /** Pi's current prompt: the base prompt when idle, or the run's forced prompt
   * (already carrying the Tron context) while a turn is running. */
  prompt: string;
  /** What `tron-core` appends at the start of each turn. */
  tronContext: string;
  customPrompt?: { text: string; path?: string };
  append: { text: string; path?: string }[];
  contextFiles: { path: string; content: string }[];
  skills: { name: string; description: string; filePath: string; disableModelInvocation: boolean; sourceInfo: SourceInfoLike }[];
  tools: { name: string; promptGuidelines?: string[]; sourceInfo: SourceInfoLike }[];
}

const SESSION_SECTIONS = new Set(["preamble", "tools", "rules", "docs", "addendum", "project_context", "skills", "cwd"]);
const TRON_HEADING = "## Tron operating context\n";
const OPEN_TAG = /\n\n<([a-z][a-z0-9_-]*)>\n/y;

/** Splits the prompt Pi renders (`preamble`, then `\n\n<name>\nbody\n</name>`
 * blocks, then any per-turn text a `before_agent_start` handler appended) into
 * attributed sections. Pi does not expose its section map, so this reads the
 * rendered text; every byte stays in exactly one section, and a prompt without
 * Pi's structure is returned verbatim as one `prompt` section. */
export function projectAgentInstructions(input: AgentInstructionsInput): AgentInstructions {
  const parsed = splitPrompt(input);
  if (!parsed) return { text: input.prompt, sections: [{ id: "prompt", timing: "turn", text: input.prompt }] };

  const tools = new Map(input.tools.map((tool) => [tool.name, tool]));
  const sections: InstructionSection[] = [{
    id: "preamble",
    timing: "session",
    text: parsed.preamble,
    source: input.customPrompt ? (input.customPrompt.path ? { kind: "file", path: input.customPrompt.path } : { kind: "unknown" }) : { kind: "pi" },
  }];
  for (const block of parsed.blocks) {
    const section: InstructionSection = { id: block.name, timing: SESSION_SECTIONS.has(block.name) ? "session" : "turn", text: block.body };
    const entries = sectionEntries(block.name, block.body, input, tools);
    if (entries) section.entries = entries;
    else section.source = SESSION_SECTIONS.has(block.name) ? { kind: "pi" } : { kind: "unknown" };
    sections.push(section);
  }

  // Idle, the per-turn context is not in Pi's prompt yet; mid-turn it is the
  // appended remainder. Either way the sheet shows what the next request carries.
  const appended = parsed.rest === "" ? input.tronContext : parsed.rest.slice(2);
  const text = parsed.rest === "" ? `${input.prompt}\n\n${input.tronContext}` : input.prompt;
  sections.push(appended.startsWith(TRON_HEADING)
    ? { id: "tron", timing: "turn", text: appended, source: { kind: "module", name: "tron-core" } }
    : { id: "appended", timing: "turn", text: appended, source: { kind: "unknown" } });
  return { text, sections };
}

function splitPrompt(input: AgentInstructionsInput) {
  const { prompt } = input;
  let cursor: number;
  if (input.customPrompt) {
    if (!prompt.startsWith(input.customPrompt.text)) return undefined;
    cursor = input.customPrompt.text.length;
  } else {
    const first = /\n\n<[a-z][a-z0-9_-]*>\n/.exec(prompt);
    if (!first) return undefined;
    cursor = first.index;
  }
  const preamble = prompt.slice(0, cursor);
  // Bodies that embed user files are known exactly, so hostile file content
  // such as a literal `</project_context>` cannot move a section boundary.
  const known: Record<string, string | undefined> = {
    project_context: input.contextFiles.length === 0 ? undefined : [
      "Project-specific instructions and guidelines:",
      ...input.contextFiles.map(({ path, content }) => `<project_instructions path="${path}">\n${content}\n</project_instructions>`),
    ].join("\n\n"),
    addendum: input.append.length === 0 ? undefined : input.append.map((item) => item.text).join("\n\n"),
  };
  const blocks: { name: string; body: string }[] = [];
  for (;;) {
    OPEN_TAG.lastIndex = cursor;
    const open = OPEN_TAG.exec(prompt);
    if (!open) break;
    const name = open[1]!;
    const start = cursor + open[0].length;
    const close = `\n</${name}>`;
    let end = -1;
    const expected = known[name];
    if (expected !== undefined && prompt.startsWith(expected + close, start)) end = start + expected.length;
    for (let at = prompt.indexOf(close, start); end < 0 && at >= 0; at = prompt.indexOf(close, at + 1)) {
      if (isBoundary(prompt, at + close.length)) end = at;
    }
    if (end < 0) return undefined;
    blocks.push({ name, body: prompt.slice(start, end) });
    cursor = end + close.length;
  }
  // Pi always renders `<cwd>`; without blocks this is some other forced prompt.
  if (blocks.length === 0) return undefined;
  const rest = prompt.slice(cursor);
  if (rest !== "" && !rest.startsWith("\n\n")) return undefined;
  return { preamble, blocks, rest };
}

function isBoundary(prompt: string, at: number): boolean {
  if (at === prompt.length || prompt.startsWith(`\n\n${TRON_HEADING}`, at)) return true;
  OPEN_TAG.lastIndex = at;
  return OPEN_TAG.test(prompt);
}

function sectionEntries(
  name: string,
  body: string,
  input: AgentInstructionsInput,
  tools: Map<string, AgentInstructionsInput["tools"][number]>,
): InstructionEntry[] | undefined {
  switch (name) {
    case "tools": {
      const names = [...tools.keys()].sort((a, b) => b.length - a.length);
      return body.split("\n").flatMap((line) => {
        const tool = names.find((candidate) => line.startsWith(`- ${candidate}: `));
        return tool ? [{ name: tool, text: line.slice(tool.length + 4), source: sourceOf(tools.get(tool)!.sourceInfo) }] : [];
      });
    }
    case "rules":
      return ruleEntries(body, input.tools);
    case "project_context":
      return input.contextFiles.map(({ path, content }) => ({ name: basename(path), path, text: content, source: { kind: "file", path } }));
    case "addendum":
      return input.append.map(({ text, path }) => ({ ...(path ? { name: basename(path), path } : {}), text, source: path ? { kind: "file", path } : { kind: "unknown" } }));
    case "skills":
      return input.skills
        .filter((skill) => !skill.disableModelInvocation && body.includes(`<location>${escapeXml(skill.filePath)}</location>`))
        .map((skill) => ({ name: skill.name, path: skill.filePath, text: skill.description, source: sourceOf(skill.sourceInfo) }));
    default:
      return undefined;
  }
}

/** Pi renders each rule as `- rule` joined by newlines, and a tool guideline
 * may itself span lines or contain bullets. Known guidelines are matched whole
 * so they keep their tool attribution; anything else is one of Pi's own rules. */
function ruleEntries(body: string, tools: AgentInstructionsInput["tools"]): InstructionEntry[] {
  const owners = new Map<string, string[]>();
  for (const tool of tools) {
    for (const guideline of tool.promptGuidelines ?? []) {
      const rule = guideline.trim();
      if (rule) owners.set(rule, [...(owners.get(rule) ?? []), tool.name]);
    }
  }
  const candidates = [...owners.keys()].sort((a, b) => b.length - a.length);
  const bySource = new Map(tools.map((tool) => [tool.name, sourceOf(tool.sourceInfo)]));
  const entries: InstructionEntry[] = [];
  let at = 0;
  while (at < body.length) {
    const start = body.startsWith("- ", at) ? at + 2 : at;
    const known = candidates.find((rule) => body.startsWith(rule, start)
      && (start + rule.length === body.length || body.startsWith("\n- ", start + rule.length)));
    const next = body.indexOf("\n- ", start);
    const end = known ? start + known.length : next < 0 ? body.length : next;
    const text = body.slice(start, end);
    const ruleTools = owners.get(text) ?? [];
    entries.push({ text, tools: ruleTools, source: ruleTools.length > 0 ? bySource.get(ruleTools[0]!)! : { kind: "pi" } });
    at = end + 1;
  }
  return entries;
}

function sourceOf(info: SourceInfoLike): InstructionSource {
  if (info.source === "builtin" || info.source === "sdk") return { kind: "pi" };
  const inline = /^<inline:(.+)>$/.exec(info.path);
  if (inline) return { kind: "module", name: inline[1]! };
  if (info.origin === "package") return { kind: "package", name: packageName(info.source) };
  return { kind: "local", scope: info.scope, path: info.path };
}

/** `npm:@scope/name@1.2.3` → `@scope/name`; `git:github.com/o/repo@sha` → `repo`. */
function packageName(source: string): string {
  const spec = source.replace(/^(npm|git|github|https?):/, "");
  const versionAt = spec.indexOf("@", spec.startsWith("@") ? 1 : 0);
  const name = versionAt > 0 ? spec.slice(0, versionAt) : spec;
  return source.startsWith("npm:") ? name : basename(name.replace(/\.git$/, ""));
}

function escapeXml(value: string): string {
  return value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&apos;");
}
