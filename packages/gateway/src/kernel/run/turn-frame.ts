import type { StreamFn } from "../pi/agent-core.js";
import { getCurrentSystemMessage, getCurrentTools } from "../pi/ai.js";
import type { ResourceLoader } from "../pi/coding-agent.js";
import { escapeIndexValue } from "../resources/context-index.js";

export type TurnActivation = "user" | "wake" | "automation" | "task" | "subagent";

export interface TurnFrameSource {
  turn(): boolean;
  activation(): TurnActivation;
  facts(): Promise<string | undefined>;
  resources(): ResourceLoader;
}

interface LoadedResources { loaded: Map<string, string>; warnings: Set<string> }

const LAYERS: Record<string, string> = {
  preamble: "core", role: "role", tools: "tool-rules", rules: "tool-rules", docs: "tool-rules", addendum: "global-rules",
  global_context: "global-rules", skills: "global-index:skills", project_skills: "project-index:skills", cwd: "cwd", tron: "workspace",
};
const PROJECT_FILE = /<project_instructions path="([^"]*)">\n([\s\S]*?)\n<\/project_instructions>/gu;

function localDate(now: Date): string {
  const day = [now.getFullYear(), now.getMonth() + 1, now.getDate()].map(part => String(part).padStart(2, "0")).join("-");
  return `${day} (${Intl.DateTimeFormat().resolvedOptions().timeZone})`;
}

function projectFiles(section: string | null | undefined): Map<string, string> {
  return new Map([...(section ?? "").matchAll(PROJECT_FILE)].map(match => [match[1]!, match[2]!]));
}

function changedLayers(previous: Record<string, string | null>, current: Record<string, string | null>): string[] {
  const changed = new Set<string>();
  for (const name of new Set([...Object.keys(previous), ...Object.keys(current)])) {
    if (previous[name] === current[name]) continue;
    if (name === "project_context") {
      const before = projectFiles(previous[name]), after = projectFiles(current[name]);
      for (const path of new Set([...before.keys(), ...after.keys()])) if (before.get(path) !== after.get(path)) changed.add(`project-rules:${escapeIndexValue(path)}`);
    } else if (LAYERS[name]) changed.add(LAYERS[name]);
  }
  return [...changed];
}

function loadedResources(loader: ResourceLoader): LoadedResources {
  const { skills, diagnostics: skillDiagnostics } = loader.getSkills(), { prompts, diagnostics: promptDiagnostics } = loader.getPrompts();
  const { errors, warnings = [] } = loader.getExtensions();
  return {
    loaded: new Map([...skills.map(skill => [`skill ${skill.name}`, skill.filePath] as const), ...prompts.map(prompt => [`prompt ${prompt.name}`, prompt.filePath] as const)]),
    warnings: new Set([...[...skillDiagnostics, ...promptDiagnostics].map(item => ({ path: item.path ?? "", message: item.message })),
      ...errors.map(item => ({ path: item.path, message: item.error })), ...warnings.map(item => ({ path: item.path, message: item.warning }))]
      .map(item => escapeIndexValue(`${item.path}: ${item.message}`))),
  };
}

function resourceChanges(previous: LoadedResources | undefined, current: LoadedResources): string[] {
  const list = (entries: Array<[string, string]>) => entries.map(([name, path]) => escapeIndexValue(`${name} (${path})`)).join(", ");
  const added = previous ? [...current.loaded].filter(([name, path]) => previous.loaded.get(name) !== path) : [];
  const removed = previous ? [...previous.loaded].filter(([name]) => !current.loaded.has(name)) : [];
  const warnings = [...current.warnings].filter(warning => !previous?.warnings.has(warning));
  return [...(added.length ? [`Resources added: ${list(added)}.`] : []), ...(removed.length ? [`Resources removed: ${list(removed)}.`] : []),
    ...(warnings.length ? [`Resource load warnings: ${warnings.join("; ")}.`] : [])];
}

export function turnFrameStream(source: TurnFrameSource, stream: StreamFn): StreamFn {
  let previous: { tools: Set<string>; sections: Record<string, string | null>; resources: LoadedResources } | undefined;
  return async (model, context, options) => {
    const last = context.messages.findLast(message => message.role !== "system");
    if (!source.turn() || (last?.role !== "user" && last?.role !== "toolResult")) return stream(model, context, options);
    const tools = new Set(getCurrentTools(context.messages).map(tool => tool.name));
    const sections = getCurrentSystemMessage(context.messages)?.sections ?? {};
    const enabled = previous ? [...tools].filter(name => !previous!.tools.has(name)) : [];
    const changed = previous ? changedLayers(previous.sections, sections) : [];
    const resources = loadedResources(source.resources());
    const reported = resourceChanges(previous?.resources, resources);
    previous = { tools, sections, resources };
    const facts = await source.facts();
    const frame = ["<turn-frame>", `Date: ${localDate(new Date())}.`, `Model: ${model.provider}/${model.id}. Thinking: ${options?.reasoning ?? "off"}.`,
      `Activation: ${source.activation()}.`, ...(enabled.length ? [`Tools enabled: ${enabled.join(", ")}.`] : []),
      ...(changed.length ? [`Context changed: ${changed.join(", ")}.`] : []), ...reported, ...(facts ? [facts] : []), "</turn-frame>"].join("\n");
    const framed = { ...context, messages: [...context.messages, { role: "user" as const, content: [{ type: "text" as const, text: frame }], timestamp: Date.now() }] };
    return stream(model, framed, options);
  };
}

type Block = Record<string, unknown>;

export function unmarkTurnFrame(payload: unknown): unknown {
  const messages = (payload as { messages?: Array<{ content?: unknown }> }).messages;
  if (!Array.isArray(messages)) return payload;
  const blocks = messages.flatMap(message => Array.isArray(message.content) ? message.content as Block[] : []);
  const frame = blocks.at(-1);
  if (typeof frame?.text !== "string" || !frame.text.startsWith("<turn-frame>") || frame.cache_control === undefined) return payload;
  const next = structuredClone(payload) as { messages: Array<{ content: Block[] }> };
  const all = next.messages.flatMap(message => Array.isArray(message.content) ? message.content : []);
  const control = all.at(-1)!.cache_control;
  delete all.at(-1)!.cache_control;
  if (all.length > 1) all.at(-2)!.cache_control = control;
  return next;
}
