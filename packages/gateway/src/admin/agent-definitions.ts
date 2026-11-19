import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { durableAtomicWriteText, durableRemove } from "../foundation/durable-json.js";

export function agentDefinitionsDirectory(agentDir: string): string { return join(agentDir, "agents"); }

export async function agentDefinition(agentDir: string, name: string): Promise<string | undefined> {
  try { return await readFile(join(agentDefinitionsDirectory(agentDir), `${name}.md`), "utf8"); }
  catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined; throw error; }
}

export async function setAgentDefinition(agentDir: string, name: string, text: string | undefined): Promise<void> {
  const path = join(agentDefinitionsDirectory(agentDir), `${name}.md`);
  if (text === undefined) await durableRemove(path); else await durableAtomicWriteText(path, text, 0o644);
}

export async function agentDefinitions(agentDir: string): Promise<Record<string, string> | undefined> {
  let entries;
  try { entries = await readdir(agentDefinitionsDirectory(agentDir), { withFileTypes: true }); }
  catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined; throw error; }
  const definitions: Record<string, string> = {};
  for (const entry of entries.filter(item => item.isFile() && item.name.endsWith(".md") && !item.name.endsWith(".chain.md"))
    .sort((left, right) => left.name.localeCompare(right.name))) {
    definitions[entry.name.slice(0, -".md".length)] = await readFile(join(agentDefinitionsDirectory(agentDir), entry.name), "utf8");
  }
  return definitions;
}
