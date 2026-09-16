import { lstat, opendir, readFile, readlink, realpath } from "node:fs/promises";
import { homedir } from "node:os";
import { isAbsolute, relative, resolve, sep, dirname, parse, basename } from "node:path";
import { fileURLToPath } from "node:url";

const DEFAULT_MAX_ENTRIES = 50_000;
const MAX_MAX_ENTRIES = 100_000;
const MAX_DEPTH = 64;
const SETTINGS_MAX_BYTES = 1 * 1024 * 1024;
const MAX_RESOURCE_ENTRIES = 500;
const MAX_RESOURCE_VALUE_BYTES = 2_000;
const MAX_AGENT_DEFINITION_BYTES = 1 * 1024 * 1024;
const MAX_AGENT_DEFINITION_FILES = 5_000;
const MAX_SUBAGENT_CONFIG_BYTES = 1 * 1024 * 1024;
const MAX_PACKAGE_MANIFESTS = 5_000;

export interface AgentHomePreflightOptions {
  readonly source: string;
  readonly destination: string;
  readonly maxEntries?: number;
}

export interface AgentHomePreflightIssue {
  readonly code: string;
  readonly path?: string;
  readonly detail?: string;
  readonly blocking: boolean;
}

export interface AgentHomePreflightResult {
  readonly source: string;
  readonly destination: string;
  readonly status: "assessment-only" | "decision-required" | "blocked";
  readonly entriesInspected: number;
  readonly issues: readonly AgentHomePreflightIssue[];
  readonly safeInternalSymlinks: number;
  readonly unresolvedSymlinks: number;
  readonly externalConfigurationReferences: number;
  readonly writerQuiescence: "unproven";
  readonly changesMade: false;
}

interface MutableResult {
  source: string;
  destination: string;
  entriesInspected: number;
  issues: AgentHomePreflightIssue[];
  safeInternalSymlinks: number;
  unresolvedSymlinks: number;
  externalConfigurationReferences: number;
  writerQuiescence: "unproven";
  changesMade: false;
  traversalLimitReported: boolean;
}

function issue(result: MutableResult, code: string, blocking: boolean, path?: string, detail?: string): void {
  const entry: AgentHomePreflightIssue = {
    code,
    blocking,
    ...(path === undefined ? {} : { path }),
    ...(detail === undefined ? {} : { detail }),
  };
  result.issues.push(entry);
}

function isWithin(root: string, candidate: string): boolean {
  const remainder = relative(root, candidate);
  return remainder === "" || (remainder !== ".." && !remainder.startsWith(`..${sep}`) && !isAbsolute(remainder));
}

function relativeDisplay(root: string, path: string): string {
  const value = relative(root, path);
  return value || ".";
}

function validateInput(value: string, name: string, result: MutableResult): string {
  if (!value || !isAbsolute(value)) {
    issue(result, "absolute-path-required", true, name, "source and destination must be absolute paths");
    return resolve(value || ".");
  }
  const normalized = resolve(value);
  if (normalized === parse(normalized).root) issue(result, "root-path-rejected", true, name);
  return normalized;
}

async function inspectRoot(result: MutableResult, path: string, name: "source" | "destination"): Promise<"directory" | "missing" | "other"> {
  try {
    const entry = await lstat(path);
    if (entry.isSymbolicLink()) {
      issue(result, `${name}-root-symlink`, true, name);
      return "other";
    }
    if (!entry.isDirectory()) {
      issue(result, `${name}-root-not-directory`, true, name, entry.isFile() ? "regular-file" : "special-file");
      return "other";
    }
    return "directory";
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT" && name === "destination") return "missing";
    issue(result, `${name}-unreadable`, true, name);
    return "other";
  }
}

async function canonicalSource(result: MutableResult, source: string): Promise<string | undefined> {
  try {
    return await realpath(source);
  } catch {
    issue(result, "source-root-unresolvable", true, "source", "physical source root could not be resolved without writing");
    return undefined;
  }
}

async function canonicalDestination(result: MutableResult, destination: string): Promise<string | undefined> {
  let current = destination;
  const missingSuffix: string[] = [];
  while (true) {
    try {
      const entry = await lstat(current);
      if (!entry.isDirectory() && !entry.isSymbolicLink()) {
        issue(result, "destination-ancestor-not-directory", true, "destination", "an existing destination ancestor is not a directory");
        return undefined;
      }
      if (missingSuffix.length > 0 && entry.isSymbolicLink()) {
        issue(result, "destination-ancestor-symlink", true, "destination", "destination creation would traverse an existing symlink ancestor");
      }
      let physical: string;
      try {
        physical = await realpath(current);
        const physicalEntry = await lstat(physical);
        if (!physicalEntry.isDirectory()) {
          issue(result, "destination-ancestor-not-directory", true, "destination", "physical destination ancestor is not a directory");
          return undefined;
        }
      } catch {
        issue(result, "destination-root-unresolvable", true, "destination", "physical destination ancestor could not be resolved without writing");
        return undefined;
      }
      return missingSuffix.reduce((base, component) => resolve(base, component), physical);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") {
        issue(result, "destination-ancestor-unreadable", true, "destination");
        return undefined;
      }
      const parent = dirname(current);
      if (parent === current) {
        issue(result, "destination-root-unresolvable", true, "destination");
        return undefined;
      }
      missingSuffix.unshift(basename(current));
      current = parent;
    }
  }
}

async function inspectSymlink(result: MutableResult, source: string, path: string): Promise<void> {

  let target: string;
  try {
    target = await readlink(path, "utf8");
  } catch {
    issue(result, "symlink-unreadable", true, relativeDisplay(source, path));
    return;
  }
  if (target.startsWith("/")) {
    result.unresolvedSymlinks += 1;
    issue(result, "external-absolute-symlink", true, relativeDisplay(source, path), "absolute target is not followed");
    return;
  }
  const resolvedTarget = resolve(dirname(path), target);
  if (!isWithin(source, resolvedTarget)) {
    result.unresolvedSymlinks += 1;
    issue(result, "external-relative-symlink", true, relativeDisplay(source, path), "target escapes source and is not followed");
    return;
  }
  // Do not stat the target: even an lstat can follow symlinked parent
  // components. Lexical containment is the safe, bounded answer for a
  // preflight; publication can validate the complete staged tree offline.
  result.safeInternalSymlinks += 1;
}

async function inspectTreeWithoutFollowing(result: MutableResult, source: string, destination: string, current: string, depth: number, maxEntries: number): Promise<void> {
  if (depth > MAX_DEPTH) {
    issue(result, "traversal-depth-limit", true, relativeDisplay(source, current));
    return;
  }
  let directory;
  try {
    directory = await opendir(current);
  } catch {
    issue(result, "directory-unreadable", true, relativeDisplay(source, current));
    return;
  }
  try {
    while (true) {
      if (result.entriesInspected >= maxEntries) {
        // Read at most one extra directory entry to distinguish an exact
        // boundary from an omitted entry, then stop. This keeps enumeration
        // bounded without materializing a whole directory listing.
        let extra;
        try {
          extra = await directory.read();
        } catch {
          issue(result, "directory-unreadable", true, relativeDisplay(source, current));
          return;
        }
        if (extra !== null && !result.traversalLimitReported) {
          result.traversalLimitReported = true;
          issue(result, "traversal-entry-limit", true, relativeDisplay(source, current));
        }
        return;
      }
      let dirent;
      try {
        dirent = await directory.read();
      } catch {
        issue(result, "directory-unreadable", true, relativeDisplay(source, current));
        return;
      }
      if (dirent === null) return;
      const path = resolve(current, dirent.name);
      if (path === destination) continue;
      const display = relativeDisplay(source, path);
      result.entriesInspected += 1;
      let entry;
      try {
        entry = await lstat(path);
      } catch {
        issue(result, "entry-unreadable", true, display);
        continue;
      }
      if (entry.isSymbolicLink()) {
        await inspectSymlink(result, source, path);
      } else if (entry.isDirectory()) {
        await inspectTreeWithoutFollowing(result, source, destination, path, depth + 1, maxEntries);
      } else if (!entry.isFile()) {
        issue(result, "special-file", true, display);
      }
    }
  } finally {
    await directory.close();
  }
}

type ReferenceClassification = "internal" | "relocation-sensitive" | "external-absolute" | "external-relative" | "external-package" | "portable-package" | "unresolvable";

function normalizedResourcePattern(value: string): string {
  return value.startsWith("!") || value.startsWith("+") || value.startsWith("-") ? value.slice(1) : value;
}

function resolveConfiguredPath(base: string, value: string): string | undefined {
  const pattern = normalizedResourcePattern(value).trim();
  if (!pattern) return undefined;
  if (pattern === "~") return homedir();
  if (pattern.startsWith("~/")) return resolve(homedir(), pattern.slice(2));
  return isAbsolute(pattern) ? resolve(pattern) : resolve(base, pattern);
}

function classifyPathPattern(base: string, value: string): ReferenceClassification {
  const normalized = normalizedResourcePattern(value);
  const candidate = resolveConfiguredPath(base, value);
  if (!candidate) return "unresolvable";
  const homeExpanded = normalized === "~" || normalized.startsWith("~/");
  if (homeExpanded) return "relocation-sensitive";
  if (isAbsolute(normalized)) return isWithin(base, candidate) ? "relocation-sensitive" : "external-absolute";
  return isWithin(base, candidate) ? "internal" : "external-relative";
}

function isPathLikeAgentReference(value: string, relativePath = false): boolean {
  const normalized = normalizedResourcePattern(value).trim();
  if (!normalized) return false;
  if (isAbsolute(normalized) || normalized === "~" || normalized.startsWith("~/")) return true;
  return relativePath && (normalized === "." || normalized === ".." || normalized.startsWith("./") || normalized.startsWith("../"));
}

function classifyAgentPath(source: string, definitionDir: string, value: string): ReferenceClassification {
  const normalized = normalizedResourcePattern(value).trim();
  if (!normalized) return "unresolvable";
  if (normalized === "~" || normalized.startsWith("~/")) return "relocation-sensitive";
  if (isAbsolute(normalized)) return isWithin(source, resolve(normalized)) ? "relocation-sensitive" : "external-absolute";
  const candidate = resolve(definitionDir, normalized);
  return isWithin(source, candidate) ? "internal" : "external-relative";
}

function issueReference(result: MutableResult, classification: ReferenceClassification, path: string): void {
  result.externalConfigurationReferences += 1;
  issue(result, classification === "relocation-sensitive" ? "relocation-sensitive-reference" : "configured-external-reference", true, path, classification === "relocation-sensitive" ? "absolute or home-expanded path remains tied to the old home" : classification === "unresolvable" ? "resource path could not be resolved" : "resource owner decision required");
}

function hasGlob(value: string): boolean {
  return /[*?\[]/u.test(value);
}

async function referenceExists(base: string, value: string): Promise<boolean> {
  const normalized = normalizedResourcePattern(value).trim();
  if (!normalized || normalized === "~" || normalized.startsWith("~/")) return false;
  const candidate = resolveConfiguredPath(base, normalized);
  if (!candidate) return false;
  // Resource patterns are not expanded by preflight. Checking the stable
  // non-pattern prefix catches moved/broken package roots without inventing a
  // second glob implementation or executing an extension.
  const pathToCheck = hasGlob(candidate) ? candidate.slice(0, candidate.search(/[*?\[]/u)).replace(/[\\/]?[^\\/]*$/u, "") || dirname(candidate) : candidate;
  try {
    await lstat(pathToCheck);
    return true;
  } catch {
    return false;
  }
}

function classifyPackageSource(agentRoot: string, value: string): { classification: ReferenceClassification; packageRoot?: string } {
  const trimmed = value.trim();
  // Registry and VCS specs identify package provenance, not an external
  // filesystem authority. The installed tree is copied with the agent home.
  if (/^(?:npm:|git:|github:|https?:|ssh:)/u.test(trimmed)) return { classification: "portable-package" };
  if (trimmed.startsWith("file:")) return { classification: "unresolvable" };
  const classification = classifyPathPattern(agentRoot, trimmed);
  if (classification !== "internal" && classification !== "relocation-sensitive") return { classification };
  const packageRoot = resolveConfiguredPath(agentRoot, trimmed);
  return packageRoot === undefined ? { classification: "unresolvable" } : { classification, packageRoot };
}

function inspectResourceArray(result: MutableResult, value: unknown, base: string, pathPrefix: string, portableRelative = false): void {
  if (!Array.isArray(value) || value.length > MAX_RESOURCE_ENTRIES || value.some(entry => typeof entry !== "string" || Buffer.byteLength(entry) > MAX_RESOURCE_VALUE_BYTES)) {
    issue(result, "unrecognized-settings-value", true, pathPrefix);
    return;
  }
  for (let index = 0; index < value.length; index += 1) {
    const resource = value[index] as string;
    const normalized = normalizedResourcePattern(resource).trim();
    const classification = portableRelative && normalized && !isAbsolute(normalized) && !normalized.startsWith("~")
      ? "portable-package"
      : classifyPathPattern(base, resource);
    if (classification !== "internal" && classification !== "portable-package") {
      result.externalConfigurationReferences += 1;
      issue(result, classification === "relocation-sensitive" ? "relocation-sensitive-reference" : "configured-external-reference", true, `${pathPrefix}[${index}]`, classification === "relocation-sensitive" ? "absolute or home-expanded path remains tied to the old home" : classification === "unresolvable" ? "resource path could not be resolved" : "resource owner decision required");
    }
  }
}

function parseDefinitionFrontmatter(content: string): { fields: Record<string, string>; malformed: boolean } {
  const normalized = content.replace(/\r\n/g, "\n");
  if (!normalized.startsWith("---")) return { fields: {}, malformed: false };
  const endIndex = normalized.indexOf("\n---", 3);
  if (endIndex < 0) return { fields: {}, malformed: true };
  const fields: Record<string, string> = {};
  const lines = normalized.slice(4, endIndex).split("\n");
  for (let index = 0; index < lines.length; index += 1) {
    const match = lines[index]?.match(/^([\w-]+):\s*(.*)$/u);
    if (!match) continue;
    const key = match[1]!;
    const raw = match[2]!.trim();
    if (raw) {
      const quoted = (raw.startsWith('"') && raw.endsWith('"')) || (raw.startsWith("'") && raw.endsWith("'"));
      fields[key] = quoted ? raw.slice(1, -1) : raw;
      continue;
    }
    const block: string[] = [];
    while (index + 1 < lines.length && (/^\s+/u.test(lines[index + 1]!) || lines[index + 1]!.trim() === "")) block.push(lines[++index]!);
    const commonIndent = block.find(line => line.trim())?.match(/^\s*/u)?.[0].length ?? 0;
    fields[key] = block.map(line => line.slice(Math.min(commonIndent, line.length))).join("\n").trim();
  }
  return { fields, malformed: false };
}

function parseFrontmatterListValue(raw: string | undefined): string[] {
  if (raw === undefined) return [];
  return raw.split("\n").flatMap(line => {
    const value = line.trim();
    const listItem = value.match(/^-\s+(.+)$/u);
    return (listItem?.[1] ?? value).split(",");
  }).map(value => value.trim()).filter(Boolean);
}

async function inspectAgentReference(result: MutableResult, source: string, base: string, value: string, path: string, relativePath: boolean, requireExisting: boolean): Promise<void> {
  if (!isPathLikeAgentReference(value, relativePath)) return;
  const classification = classifyAgentPath(source, base, value);
  if (classification !== "internal") {
    issueReference(result, classification, path);
    return;
  }
  if (requireExisting && !(await referenceExists(base, value))) {
    result.externalConfigurationReferences += 1;
    issue(result, "missing-configured-reference", true, path, "portable reference does not resolve in the source home");
  }
}

async function inspectAgentDefinition(result: MutableResult, source: string, filePath: string): Promise<void> {
  let entry;
  try { entry = await lstat(filePath); } catch { issue(result, "agent-definition-unreadable", true, relativeDisplay(source, filePath)); return; }
  if (entry.isSymbolicLink()) {
    let physical: string;
    try { physical = await realpath(filePath); } catch { issue(result, "agent-definition-unreadable", true, relativeDisplay(source, filePath)); return; }
    if (!isWithin(source, physical)) return;
  }
  if (!entry.isFile() || entry.size > MAX_AGENT_DEFINITION_BYTES) {
    if (entry.isFile()) issue(result, "agent-definition-size-limit", true, relativeDisplay(source, filePath));
    return;
  }
  let content: string;
  try { content = await readFile(filePath, "utf8"); } catch { issue(result, "agent-definition-unreadable", true, relativeDisplay(source, filePath)); return; }
  const parsed = parseDefinitionFrontmatter(content);
  if (parsed.malformed) {
    issue(result, "unrecognized-agent-definition", true, relativeDisplay(source, filePath), "agent frontmatter has no closing delimiter");
    return;
  }
  if (!parsed.fields.name || !parsed.fields.description) return;
  const prefix = relativeDisplay(source, filePath);
  const definitionDir = dirname(filePath);
  for (const field of ["extensions", "subagentOnlyExtensions"] as const) {
    const values = parseFrontmatterListValue(parsed.fields[field]);
    for (let index = 0; index < values.length; index += 1) await inspectAgentReference(result, source, definitionDir, values[index]!, `${prefix}:${field}[${index}]`, true, true);
  }
  const skillPaths = parseFrontmatterListValue(parsed.fields.skillPath);
  for (let index = 0; index < skillPaths.length; index += 1) await inspectAgentReference(result, source, definitionDir, skillPaths[index]!, `${prefix}:skillPath[${index}]`, true, true);
  for (const field of ["output", "defaultReads"] as const) {
    const values = parseFrontmatterListValue(parsed.fields[field]);
    for (let index = 0; index < values.length; index += 1) await inspectAgentReference(result, source, definitionDir, values[index]!, `${prefix}:${field}[${index}]`, true, false);
  }
  const memory = parsed.fields.memory?.match(/(?:^|\n)\s*path:\s*([^\n]+)/u)?.[1]?.trim();
  if (memory && (isAbsolute(normalizedResourcePattern(memory)) || memory === "~" || memory.startsWith("~/"))) await inspectAgentReference(result, source, definitionDir, memory, `${prefix}:memory.path`, true, false);
  const runnerType = parsed.fields.runner?.match(/(?:^|\n)\s*type:\s*([^\n]+)/u)?.[1]?.trim();
  const runnerCommand = parsed.fields.runner?.match(/(?:^|\n)\s*command:\s*([^\n]+)/u)?.[1]?.trim().replace(/^['"]|['"]$/gu, "");
  if (runnerType === "external-cli" && runnerCommand && isAbsolute(runnerCommand)) await inspectAgentReference(result, source, definitionDir, runnerCommand, `${prefix}:runner.command`, false, true);
}

async function inspectAgentDefinitionDirectory(result: MutableResult, source: string, directoryPath: string, count: { value: number }, scanRoot = source): Promise<void> {
  if (count.value >= MAX_AGENT_DEFINITION_FILES) return;
  let directory;
  try { directory = await opendir(directoryPath); } catch { issue(result, "agent-definition-directory-unreadable", true, relativeDisplay(source, directoryPath)); return; }
  try {
    while (true) {
      const child = await directory.read();
      if (child === null) return;
      const childPath = resolve(directoryPath, child.name);
      if (child.isDirectory()) await inspectAgentDefinitionDirectory(result, source, childPath, count, scanRoot);
      else if (child.name.endsWith(".md")) {
        count.value += 1;
        if (count.value > MAX_AGENT_DEFINITION_FILES) { issue(result, "agent-definition-entry-limit", true, relativeDisplay(source, directoryPath)); return; }
        await inspectAgentDefinition(result, source, resolve(source, relative(scanRoot, childPath)));
      }
    }
  } finally { await directory.close(); }
}

async function inspectAgentDefinitions(result: MutableResult, source: string, scanRoot = source): Promise<void> {
  const visited = new Set<string>();
  const count = { value: 0 };
  async function findDirectories(current: string, depth: number): Promise<void> {
    if (depth > MAX_DEPTH) return;
    let directory;
    try { directory = await opendir(current); } catch { return; }
    try {
      while (true) {
        const child = await directory.read();
        if (child === null) return;
        if (!child.isDirectory()) continue;
        const childPath = resolve(current, child.name);
        if (child.name === "agents") {
          const physical = await realpath(childPath).catch(() => undefined);
          if (!physical || !isWithin(scanRoot, physical) || visited.has(physical)) continue;
          visited.add(physical);
          await inspectAgentDefinitionDirectory(result, source, physical, count, scanRoot);
        } else await findDirectories(childPath, depth + 1);
      }
    } finally { await directory.close(); }
  }
  await findDirectories(scanRoot, 0);
}

async function inspectPackageAgentMetadata(result: MutableResult, source: string): Promise<void> {
  let inspected = 0;
  const definitionCount = { value: 0 };
  async function visit(current: string, depth: number): Promise<void> {
    if (depth > MAX_DEPTH || inspected >= MAX_PACKAGE_MANIFESTS) return;
    let directory;
    try { directory = await opendir(current); } catch { return; }
    try {
      while (true) {
        const child = await directory.read();
        if (child === null) return;
        const childPath = resolve(current, child.name);
        if (child.isDirectory()) { await visit(childPath, depth + 1); continue; }
        if (child.name !== "package.json") continue;
        inspected += 1;
        if (inspected > MAX_PACKAGE_MANIFESTS) { issue(result, "package-manifest-entry-limit", true, relativeDisplay(source, current)); return; }
        let entry;
        try { entry = await lstat(childPath); } catch { issue(result, "package-manifest-unreadable", true, relativeDisplay(source, childPath)); continue; }
        if (!entry.isFile() || entry.size > MAX_SUBAGENT_CONFIG_BYTES) { issue(result, "package-manifest-size-limit", true, relativeDisplay(source, childPath)); continue; }
        let document: unknown;
        try { document = JSON.parse(await readFile(childPath, "utf8")); } catch { continue; }
        if (!document || typeof document !== "object" || Array.isArray(document)) continue;
        const root = document as Record<string, unknown>;
        const declarations: Array<[string, unknown]> = [];
        for (const key of ["pi-subagents", "pi"] as const) {
          const value = root[key];
          if (!value || typeof value !== "object" || Array.isArray(value)) continue;
          const subagents = key === "pi" ? (value as Record<string, unknown>).subagents : value;
          if (subagents && typeof subagents === "object" && !Array.isArray(subagents)) declarations.push([`${key}.subagents`, (subagents as Record<string, unknown>).agents]);
        }
        for (const [declaration, value] of declarations) {
          if (value === undefined) continue;
          if (!Array.isArray(value) || value.length > MAX_RESOURCE_ENTRIES || value.some(item => typeof item !== "string" || Buffer.byteLength(item) > MAX_RESOURCE_VALUE_BYTES)) {
            issue(result, "unrecognized-package-agents", true, `${relativeDisplay(source, childPath)}:${declaration}.agents`);
            continue;
          }
          for (let index = 0; index < value.length; index += 1) {
            const pathValue = value[index] as string;
            const location = `${relativeDisplay(source, childPath)}:${declaration}.agents[${index}]`;
            const classification = classifyAgentPath(source, dirname(childPath), pathValue);
            if (classification !== "internal") { issueReference(result, classification, location); continue; }
            if (!(await referenceExists(dirname(childPath), pathValue))) {
              result.externalConfigurationReferences += 1;
              issue(result, "missing-configured-reference", true, location, "portable agent directory does not resolve in the source home");
              continue;
            }
            const resolvedPath = resolve(dirname(childPath), normalizedResourcePattern(pathValue).trim());
            await inspectAgentDefinitionDirectory(result, source, resolvedPath, definitionCount, source);
          }
        }
      }
    } finally { await directory.close(); }
  }
  await visit(source, 0);
}

async function inspectSubagentConfig(result: MutableResult, source: string): Promise<void> {
  const configPath = resolve(source, "extensions", "subagent", "config.json");
  let entry;
  try { entry = await lstat(configPath); } catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") issue(result, "subagent-config-unreadable", true, "extensions/subagent/config.json"); return; }
  if (!entry.isFile() || entry.size > MAX_SUBAGENT_CONFIG_BYTES) { issue(result, "subagent-config-size-limit", true, "extensions/subagent/config.json"); return; }
  let document: unknown;
  try { document = JSON.parse(await readFile(configPath, "utf8")); } catch { issue(result, "malformed-subagent-config", true, "extensions/subagent/config.json", "configuration was not parsed or interpreted"); return; }
  if (!document || typeof document !== "object" || Array.isArray(document)) { issue(result, "unrecognized-subagent-config", true, "extensions/subagent/config.json"); return; }
  const values = document as Record<string, unknown>;
  const paths: Array<[string, unknown]> = [
    ["defaultSessionDir", values.defaultSessionDir], ["singleRunOutputBaseDir", values.singleRunOutputBaseDir], ["worktreeBaseDir", values.worktreeBaseDir],
    ["missions.directory", (values.missions as Record<string, unknown> | undefined)?.directory], ["missions.globalIndexDir", (values.missions as Record<string, unknown> | undefined)?.globalIndexDir],
    ["scheduledRuns.storeRoot", (values.scheduledRuns as Record<string, unknown> | undefined)?.storeRoot], ["intercomBridge.instructionFile", (values.intercomBridge as Record<string, unknown> | undefined)?.instructionFile],
  ];
  for (const [name, value] of paths) {
    if (value === undefined) continue;
    if (typeof value !== "string" || Buffer.byteLength(value) > MAX_RESOURCE_VALUE_BYTES) { issue(result, "unrecognized-subagent-config-value", true, `extensions/subagent/config.json:${name}`); continue; }
    const classification = classifyPathPattern(source, value);
    if (classification !== "internal") issueReference(result, classification, `extensions/subagent/config.json:${name}`);
  }
}

async function inspectSubagentSettings(result: MutableResult, source: string, values: Record<string, unknown>): Promise<void> {
  const subagents = values.subagents;
  if (!subagents || typeof subagents !== "object" || Array.isArray(subagents)) return;
  const settings = subagents as Record<string, unknown>;
  if (settings.defaultExtensions !== undefined) inspectResourceArray(result, settings.defaultExtensions, source, "settings.json:subagents.defaultExtensions");
  const overrideGroups = [settings.agentOverrides, settings.agentOverridesByProvider];
  for (const group of overrideGroups) {
    if (group === undefined) continue;
    if (!group || typeof group !== "object" || Array.isArray(group)) {
      issue(result, "unrecognized-settings-value", true, "settings.json:subagents.agentOverrides");
      continue;
    }
    const visit = (object: Record<string, unknown>, prefix: string): void => {
      for (const [name, value] of Object.entries(object)) {
        if (!value || typeof value !== "object" || Array.isArray(value)) {
          issue(result, "unrecognized-settings-value", true, `${prefix}.${name}`);
          continue;
        }
        const override = value as Record<string, unknown>;
        for (const field of ["extensions", "subagentOnlyExtensions"] as const) {
          if (override[field] === undefined || override[field] === false) continue;
          inspectResourceArray(result, override[field], source, `${prefix}.${name}.${field}`);
        }
      }
    };
    for (const [name, value] of Object.entries(group as Record<string, unknown>)) {
      if (name === "agentOverridesByProvider" && value && typeof value === "object" && !Array.isArray(value)) visit(value as Record<string, unknown>, "settings.json:subagents.agentOverridesByProvider");
      else if (group === settings.agentOverrides) {
        if (value && typeof value === "object" && !Array.isArray(value)) visit({ [name]: value }, "settings.json:subagents.agentOverrides");
      }
    }
  }
}

async function inspectSettings(result: MutableResult, source: string): Promise<void> {
  const settingsPath = resolve(source, "settings.json");
  let entry;
  try {
    entry = await lstat(settingsPath);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return;
    issue(result, "settings-unreadable", true, "settings.json");
    return;
  }
  if (!entry.isFile()) return;
  if (entry.size > SETTINGS_MAX_BYTES) {
    issue(result, "settings-size-limit", true, "settings.json");
    return;
  }
  let document: unknown;
  try {
    document = JSON.parse(await readFile(settingsPath, "utf8"));
  } catch {
    issue(result, "malformed-settings", true, "settings.json", "settings were not parsed or interpreted");
    return;
  }
  if (!document || typeof document !== "object" || Array.isArray(document)) {
    issue(result, "unrecognized-settings", true, "settings.json", "settings root is not an object");
    return;
  }
  const values = document as Record<string, unknown>;
  await inspectSubagentSettings(result, source, values);
  const resourceFields = ["extensions", "skills", "prompts", "themes"] as const;
  const sessionDir = values.sessionDir;
  if (sessionDir !== undefined && sessionDir !== null) {
    if (typeof sessionDir !== "string" || Buffer.byteLength(sessionDir) > MAX_RESOURCE_VALUE_BYTES) {
      issue(result, "unrecognized-settings-value", true, "settings.json:sessionDir");
    } else {
      const classification = classifyPathPattern(source, sessionDir);
      if (classification !== "internal") {
        result.externalConfigurationReferences += 1;
        issue(result, classification === "relocation-sensitive" ? "relocation-sensitive-reference" : "configured-external-reference", true, "settings.json:sessionDir", classification === "relocation-sensitive" ? "absolute or home-expanded path remains tied to the old home" : "session owner decision required");
      }
    }
  }
  for (const field of resourceFields) {
    if (values[field] !== undefined && values[field] !== null) inspectResourceArray(result, values[field], source, `settings.json:${field}`);
  }
  const packages = values.packages;
  if (packages === undefined) return;
  if (!Array.isArray(packages) || packages.length > MAX_RESOURCE_ENTRIES) {
    issue(result, "unrecognized-settings-value", true, "settings.json:packages");
    return;
  }
  for (let index = 0; index < packages.length; index += 1) {
    const packageValue = packages[index];
    const packagePath = `settings.json:packages[${index}]`;
    const raw = typeof packageValue === "string"
      ? packageValue
      : packageValue && typeof packageValue === "object" && !Array.isArray(packageValue)
        ? (packageValue as Record<string, unknown>).source
        : undefined;
    if (typeof raw !== "string" || Buffer.byteLength(raw) > MAX_RESOURCE_VALUE_BYTES) {
      issue(result, "unrecognized-settings-value", true, packagePath);
      continue;
    }
    const packageInfo = classifyPackageSource(source, raw);
    if (packageInfo.classification !== "internal" && packageInfo.classification !== "portable-package") {
      result.externalConfigurationReferences += 1;
      issue(result, packageInfo.classification === "relocation-sensitive" ? "relocation-sensitive-reference" : "configured-external-reference", true, packagePath, packageInfo.classification === "relocation-sensitive" ? "absolute or home-expanded path remains tied to the old home" : "package owner decision required");
    }
    if (packageValue && typeof packageValue === "object" && !Array.isArray(packageValue)) {
      const packageObject = packageValue as Record<string, unknown>;
      for (const field of resourceFields) {
        if (packageObject[field] === undefined || packageObject[field] === null) continue;
        if (packageInfo.packageRoot) {
          inspectResourceArray(result, packageObject[field], packageInfo.packageRoot, `${packagePath}.${field}`);
        } else if (packageInfo.classification === "portable-package") {
          // A registry/VCS package's relative resource patterns resolve inside
          // the installed tree, which moves with the agent home. Absolute or
          // home-expanded patterns still go through the normal relocation gate.
          inspectResourceArray(result, packageObject[field], source, `${packagePath}.${field}`, true);
        } else {
          issue(result, "unresolved-package-resource", true, `${packagePath}.${field}`, "package resource base is not an inspectable path");
        }
      }
    }
  }
}

function finalize(result: MutableResult): AgentHomePreflightResult {
  issue(result, "writer-quiescence-unproven", false, undefined, "preflight does not acquire locks or prove that every writer has stopped");
  const blocking = result.issues.some(entry => entry.blocking);
  const decisionOnly = new Set(["configured-external-reference", "relocation-sensitive-reference"]);
  const structuralBlocking = result.issues.some(entry => entry.blocking && !decisionOnly.has(entry.code));
  const status = structuralBlocking ? "blocked" : blocking ? "decision-required" : "assessment-only";
  return { ...result, status, issues: result.issues };
}

export async function preflightAgentHome(options: AgentHomePreflightOptions): Promise<AgentHomePreflightResult> {
  const result: MutableResult = {
    source: "",
    destination: "",
    entriesInspected: 0,
    issues: [],
    safeInternalSymlinks: 0,
    unresolvedSymlinks: 0,
    externalConfigurationReferences: 0,
    writerQuiescence: "unproven",
    changesMade: false,
    traversalLimitReported: false,
  };
  const sourceInput = typeof options.source === "string" ? options.source : "";
  const destinationInput = typeof options.destination === "string" ? options.destination : "";
  result.source = validateInput(sourceInput, "source", result);
  result.destination = validateInput(destinationInput, "destination", result);
  const sourceInputUsable = isAbsolute(sourceInput) && result.source !== parse(result.source).root;
  const destinationInputUsable = isAbsolute(destinationInput) && result.destination !== parse(result.destination).root;
  const maxEntries = options.maxEntries ?? DEFAULT_MAX_ENTRIES;
  const maxEntriesUsable = Number.isSafeInteger(maxEntries) && maxEntries >= 1 && maxEntries <= MAX_MAX_ENTRIES;
  if (!maxEntriesUsable) issue(result, "invalid-entry-limit", true, "maxEntries");
  if (!sourceInputUsable || !destinationInputUsable || !maxEntriesUsable) return finalize(result);
  if (isWithin(result.source, result.destination) || isWithin(result.destination, result.source)) {
    issue(result, "source-destination-overlap", true);
  }
  const sourceStatus = sourceInputUsable ? await inspectRoot(result, result.source, "source") : "other";
  const destinationStatus = destinationInputUsable ? await inspectRoot(result, result.destination, "destination") : "other";
  if (destinationInputUsable && destinationStatus !== "missing") issue(result, "destination-collision", true, "destination");
  const physicalSource = sourceStatus === "directory" ? await canonicalSource(result, result.source) : undefined;
  const physicalDestination = destinationInputUsable ? await canonicalDestination(result, result.destination) : undefined;
  if (physicalSource && physicalDestination
    && (isWithin(physicalSource, physicalDestination) || isWithin(physicalDestination, physicalSource))) {
    issue(result, "source-destination-overlap", true, undefined, "physical roots overlap after read-only canonicalization");
  }
  if (sourceStatus === "directory" && physicalSource) {
    await inspectTreeWithoutFollowing(result, physicalSource, physicalDestination ?? result.destination, physicalSource, 0, Number.isSafeInteger(maxEntries) && maxEntries > 0 ? Math.min(maxEntries, MAX_MAX_ENTRIES) : DEFAULT_MAX_ENTRIES);
    await inspectSettings(result, result.source);
    await inspectAgentDefinitions(result, result.source, physicalSource);
    await inspectPackageAgentMetadata(result, result.source);
    await inspectSubagentConfig(result, result.source);
  }
  return finalize(result);
}

function usage(): never {
  console.error("Usage: scripts/tron agent-home-preflight --source <absolute-path> --destination <absolute-path> [--max-entries <1..100000>]");
  process.exit(64);
}

function parseArguments(args: readonly string[]): AgentHomePreflightOptions {
  let source: string | undefined;
  let destination: string | undefined;
  let maxEntries: number | undefined;
  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index];
    if (argument === "--source") source = args[++index];
    else if (argument === "--destination") destination = args[++index];
    else if (argument === "--max-entries") {
      const raw = args[++index];
      if (!raw || !/^\d+$/u.test(raw)) usage();
      maxEntries = Number(raw);
    } else usage();
  }
  if (!source || !destination || source.length > 4_096 || destination.length > 4_096) usage();
  return maxEntries === undefined ? { source, destination } : { source, destination, maxEntries };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const result = await preflightAgentHome(parseArguments(process.argv.slice(2)));
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  if (result.status !== "assessment-only") process.exitCode = 2;
}
