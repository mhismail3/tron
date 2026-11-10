import { readFileSync } from "node:fs";
import { stripFrontmatter } from "../pi/coding-agent.js";
import type { ResourceInvocation } from "../../protocol/types.js";
import { GatewayError } from "../../errors.js";

export interface ResourceExpansionCatalog {
  skills: ReadonlyArray<{ name: string; filePath: string; baseDir: string }>;
  promptTemplates: ReadonlyArray<{ name: string; content: string }>;
}

const TEMPLATE_PLACEHOLDER = /\$\{(\d+|ARGUMENTS|@):-([^}]*)\}|\$\{@:(\d+)(?::(\d+))?\}|\$(ARGUMENTS|@|\d+)/g;

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
      return template.content.replace(TEMPLATE_PLACEHOLDER, (_match, defaultTarget: string | undefined, defaultValue: string | undefined) =>
        defaultTarget ? defaultValue ?? "" : "").trim();
    }
    throw new GatewayError("invalid_request", "Extension commands are not composed into a message");
  });
  return [...expansions, visiblePrompt].filter(part => part.length > 0).join("\n\n");
}
