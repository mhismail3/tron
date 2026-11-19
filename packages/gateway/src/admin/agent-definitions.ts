import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { GatewayError } from "../errors.js";
import { durableAtomicWriteText, durableRemove } from "../foundation/durable-json.js";

const MAX_BYTES = 64 * 1024;
const MAX_FILES = 256;

export function agentDefinitionsDirectory(agentDir: string): string { return join(agentDir, "agents"); }

async function read(path: string): Promise<string | undefined> {
  try {
    const text = await readFile(path, "utf8");
    if (Buffer.byteLength(text) > MAX_BYTES) throw new GatewayError("conflict", `${path} exceeds ${MAX_BYTES} bytes`);
    return text;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
    throw error;
  }
}

export function agentDefinition(agentDir: string, name: string): Promise<string | undefined> {
  return read(join(agentDefinitionsDirectory(agentDir), `${name}.md`));
}

export async function setAgentDefinition(agentDir: string, name: string, text: string | undefined): Promise<void> {
  const path = join(agentDefinitionsDirectory(agentDir), `${name}.md`);
  if (text === undefined) await durableRemove(path); else await durableAtomicWriteText(path, text, 0o644);
}

export async function agentDefinitions(agentDir: string): Promise<Record<string, string> | undefined> {
  let names: string[];
  try { names = (await readdir(agentDefinitionsDirectory(agentDir))).filter(name => name.endsWith(".md") && !name.endsWith(".chain.md")).sort(); }
  catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined; throw error; }
  if (names.length > MAX_FILES) throw new GatewayError("conflict", `The agents folder holds more than ${MAX_FILES} definitions`);
  const definitions: Record<string, string> = {};
  for (const name of names) {
    const text = await read(join(agentDefinitionsDirectory(agentDir), name));
    if (text !== undefined) definitions[name.slice(0, -".md".length)] = text;
  }
  return definitions;
}
