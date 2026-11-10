import { cp, mkdir, readFile, readdir, realpath, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { fauxProvider, type FauxProviderHandle, type FauxModelDefinition } from "@earendil-works/pi-ai";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { waitFor } from "./wait-for.js";

export const CORPUS_DIR = resolve(dirname(fileURLToPath(import.meta.url)), "../test-fixtures/pi-sdk/corpus");
export const CORPUS_AGENT_DIR = join(CORPUS_DIR, "agent");
export const CORPUS_MANIFEST_PATH = join(CORPUS_DIR, "manifest.json");
export const CORPUS_SESSIONS_DIR_NAME = "sessions";

export const CORPUS_TOKENS = {
  root: "«corpus-root»",
  workspace: "«corpus-workspace»",
  agent: "«corpus-agent»",
  sessions: "«corpus-sessions»",
  repo: "«corpus-repo»",
  node: "«corpus-node»",
  fixture: "«corpus-fixture»",
  mcpUrl: "«corpus-mcp-url»",
  mcpOrigin: "«corpus-mcp-origin»",
} as const;

export const CORPUS_MCP_SERVERS = ["corpus-mcp", "corpus-oauth"] as const;
const mcpToolServer = (name: string): string => name.replaceAll("-", "_");

export const CORPUS_STDIO_TOOLS = [{
  name: "echo",
  description: "Echo synthetic fixture input through the stdio server",
  inputSchema: { type: "object", properties: { value: { type: "string" } }, required: ["value"] },
}];
export const CORPUS_MCP_STATE_FILE = "mcp-state.json";

export const CORPUS_AZURE_PROVIDER = "azure";
export const CORPUS_AZURE_MODEL = "gpt-5";
export const CORPUS_AZURE_API_KEY = "corpus-synthetic-azure-key";
export const CORPUS_FAUX_PROVIDER = "tron-corpus";
export const CORPUS_FAUX_MODEL = "corpus-model";
export const CORPUS_FAUX_MODEL_ALT = "corpus-model-alt";
const CORPUS_FAUX_MODELS: FauxModelDefinition[] = [
  { id: CORPUS_FAUX_MODEL, input: ["text", "image"], reasoning: true },
  { id: CORPUS_FAUX_MODEL_ALT, input: ["text", "image"] },
];

export function corpusFauxProvider(): FauxProviderHandle {
  return fauxProvider({ provider: CORPUS_FAUX_PROVIDER, models: CORPUS_FAUX_MODELS, tokensPerSecond: 10_000 });
}

export async function corpusModelRuntime(agentDir: string, faux: FauxProviderHandle): Promise<ModelRuntime> {
  const runtime = await ModelRuntime.create({
    authPath: join(agentDir, "auth.json"), modelsPath: null, refreshOnCreate: false, allowModelNetwork: false,
  });
  runtime.registerNativeProvider(faux.provider);
  return runtime;
}

export interface StagedCorpusPaths {
  readonly root: string;
  readonly agentDir: string;
  readonly sessionDir: string;
  readonly cwd: string;
  readonly mcpUrl: string;
}

export interface StageCorpusOptions {
  readonly root: string;
  readonly corpusDir?: string;
  readonly mcpUrl: string;
  readonly mcpFixture: string;
  readonly nodeExecutable: string;
}

function replaceAll(text: string, replacements: ReadonlyArray<readonly [string, string]>): string {
  let result = text;
  for (const [from, to] of replacements) result = result.split(from).join(to);
  return result;
}

export async function stageCorpus(options: StageCorpusOptions): Promise<StagedCorpusPaths> {
  const root = await realpath(options.root);
  const agentDir = join(root, "agent");
  const sessionDir = join(agentDir, CORPUS_SESSIONS_DIR_NAME);
  const cwd = join(root, "workspace");
  await mkdir(cwd, { recursive: true });
  await cp(options.corpusDir ?? CORPUS_DIR, root, { recursive: true, force: true });
  const replacements: Array<readonly [string, string]> = [
    [CORPUS_TOKENS.root, root],
    [CORPUS_TOKENS.workspace, cwd],
    [CORPUS_TOKENS.agent, agentDir],
    [CORPUS_TOKENS.sessions, sessionDir],
    [CORPUS_TOKENS.node, options.nodeExecutable],
    [CORPUS_TOKENS.fixture, options.mcpFixture],
    [CORPUS_TOKENS.mcpUrl, options.mcpUrl],
    [CORPUS_TOKENS.mcpOrigin, new URL(options.mcpUrl).origin],
  ];
  const rewriteJson = async (path: string): Promise<void> => {
    const rewritten = replaceAll(await readFile(path, "utf8"), replacements);
    await writeFile(path, `${JSON.stringify(JSON.parse(rewritten), null, 2)}\n`);
  };
  await Promise.all([
    rewriteJson(join(agentDir, "settings.json")),
    rewriteJson(join(agentDir, "mcp.json")),
    rewriteJson(join(agentDir, "mcp-auth.json")),
    writeFile(join(root, CORPUS_MCP_STATE_FILE), `${JSON.stringify({ tools: CORPUS_STDIO_TOOLS })}\n`),
  ]);
  for (const entry of await readdir(sessionDir)) {
    if (!entry.endsWith(".jsonl")) continue;
    const path = join(sessionDir, entry);
    await writeFile(path, replaceAll(await readFile(path, "utf8"), replacements));
  }
  return { root, agentDir, sessionDir, cwd, mcpUrl: options.mcpUrl };
}

export async function corpusSessionFiles(corpusDir: string = CORPUS_DIR): Promise<string[]> {
  const directory = join(corpusDir, "agent", CORPUS_SESSIONS_DIR_NAME);
  const entries = await readdir(directory);
  return entries.filter((entry) => entry.endsWith(".jsonl")).sort().map((entry) => join(directory, entry));
}

export async function readSessionEntries(path: string): Promise<Array<Record<string, unknown>>> {
  const text = await readFile(path, "utf8");
  return text.trimEnd().split("\n").map((line) => JSON.parse(line) as Record<string, unknown>);
}

export interface CorpusSessionObservation {
  readonly sessionId: string;
  readonly model: { readonly provider: string; readonly id: string } | null;
  readonly thinkingLevel: string;
  readonly activeTools: ReadonlyArray<{ readonly name: string; readonly exposure: string | null }>;
  readonly transcriptTotal: number;
  readonly leafEntryId: string | null;
  readonly projection: readonly unknown[];
}

export interface CorpusServerObservation {
  readonly name: string;
  readonly tools: readonly string[];
}

export interface CorpusProviderObservation {
  readonly provider: string;
  readonly storedCredential: boolean;
  readonly model: { readonly provider: string; readonly id: string } | null;
}

export interface CorpusObservation {
  readonly recordedWith: string;
  readonly sessions: readonly CorpusSessionObservation[];
  readonly servers: readonly CorpusServerObservation[];
  readonly providers: readonly CorpusProviderObservation[];
}

export interface ObservableSlot {
  readonly sessionFile?: string | undefined;
  snapshot(): {
    model?: { provider: string; id: string } | undefined;
    thinkingLevel: string;
    leafEntryId?: string | undefined;
    transcript: readonly unknown[];
    transcriptTotal: number;
  };
  context(): Promise<unknown>;
}

export interface ObservableRegistry {
  acquire(sessionId: string): Promise<ObservableSlot>;
}

export interface ObservableModelRuntime {
  listCredentials(): Promise<ReadonlyArray<{ providerId: string }>>;
  getModel(providerId: string, modelId: string): unknown;
}

interface SlotContext {
  activeTools?: string[];
  availableTools?: Array<{ name: string; exposure?: string }>;
}

function exposureOf(tool: { exposure?: string } | undefined): string | null {
  return typeof tool?.exposure === "string" ? tool.exposure : null;
}

async function availableTools(registry: ObservableRegistry, sessionId: string): Promise<Map<string, { name: string; exposure?: string }>> {
  const context = await (await registry.acquire(sessionId)).context() as SlotContext;
  return new Map((context.availableTools ?? []).map((tool) => [tool.name, tool]));
}

export async function waitForRecordedServerTools(
  registry: ObservableRegistry,
  sessionIds: readonly string[],
  servers: readonly CorpusServerObservation[],
): Promise<void> {
  const recorded = servers.flatMap((server) => server.tools);
  if (recorded.length === 0) return;
  await waitFor(async () => {
    for (const sessionId of sessionIds) {
      const available = await availableTools(registry, sessionId);
      if (!recorded.every((tool) => available.has(tool))) return false;
    }
    return true;
  }, `every reopened session to expose the persisted MCP tools (${recorded.join(", ")})`);
}

const CORPUS_SCENARIO_SHAPES = [
  "session-header",
  "model-change",
  "thinking-level-change",
  "invocation-receipt",
  "system-loadout",
  "user-image",
  "assistant-tool-call",
  "tool-result-direct-mcp",
  "tool-result-codemode-nested",
  "tool-search-loaded-tool",
  "system-loadout-delta",
  "tool-result-searched-mcp",
  "context-edit",
  "compaction",
  "branch-sibling",
] as const;

export type CorpusScenarioShape = typeof CORPUS_SCENARIO_SHAPES[number];

type Entry = Record<string, unknown>;

function message(entry: Entry): Record<string, unknown> | undefined {
  return entry.type === "message" ? entry.message as Record<string, unknown> | undefined : undefined;
}

function hasImage(entry: Entry): boolean {
  const content = message(entry)?.content;
  return Array.isArray(content) && content.some((part) => (part as { type?: string }).type === "image");
}

function hasToolCall(entry: Entry): boolean {
  const content = message(entry)?.content;
  return Array.isArray(content) && content.some((part) => (part as { type?: string }).type === "toolCall");
}

function successfulNestedCalls(entry: Entry): number {
  const calls = (message(entry)?.nestedCalls as { calls?: Array<{ status?: string }> } | undefined)?.calls;
  return Array.isArray(calls) ? calls.filter((call) => call.status === "ok").length : 0;
}

function loadedTools(entry: Entry): string[] {
  const loaded = (message(entry)?.details as { loaded?: unknown } | undefined)?.loaded;
  return Array.isArray(loaded) ? loaded.filter((name): name is string => typeof name === "string") : [];
}

export function scenarioShapes(entries: ReadonlyArray<Entry>): Record<CorpusScenarioShape, number | null> {
  const line = (predicate: (entry: Entry) => boolean): number | null => {
    const index = entries.findIndex(predicate);
    return index < 0 ? null : index + 1;
  };
  const systemMessages = entries
    .map((entry, index) => ({ entry, index }))
    .filter(({ entry }) => message(entry)?.role === "system");
  const deltaMessage = systemMessages.slice(1).find(({ entry }) =>
    ((message(entry)?.toolsAdded as Array<{ name?: string }> | undefined) ?? [])
      .some((tool) => typeof tool.name === "string" && tool.name.includes(mcpToolServer(CORPUS_MCP_SERVERS[1]))));
  const searchLoaded = entries.findIndex((entry) => message(entry)?.toolName === "tool_search"
    && loadedTools(entry).length > 0);
  const childrenPerParent = new Map<string, number>();
  for (const entry of entries) {
    const parent = entry.parentId;
    if (typeof parent !== "string") continue;
    childrenPerParent.set(parent, (childrenPerParent.get(parent) ?? 0) + 1);
  }
  const branchParent = [...childrenPerParent.entries()].find(([, children]) => children > 1)?.[0];
  const branchSibling = branchParent === undefined ? null : line((entry) => entry.parentId === branchParent && entry.type === "message");
  return {
    "session-header": line((entry) => entry.type === "session"),
    "model-change": line((entry) => entry.type === "model_change"),
    "thinking-level-change": line((entry) => entry.type === "thinking_level_change"),
    "invocation-receipt": line((entry) => entry.type === "custom" && entry.customType === "tron.chat-invocation.v1"),
    "system-loadout": line((entry) => message(entry)?.role === "system"),
    "user-image": line((entry) => message(entry)?.role === "user" && hasImage(entry)),
    "assistant-tool-call": line((entry) => message(entry)?.role === "assistant" && hasToolCall(entry)),
    "tool-result-direct-mcp": line((entry) => message(entry)?.toolName === `mcp__${mcpToolServer(CORPUS_MCP_SERVERS[0])}__echo`),
    "tool-result-codemode-nested": line((entry) => message(entry)?.toolName === "codemode" && successfulNestedCalls(entry) > 0),
    "tool-search-loaded-tool": searchLoaded < 0 ? null : searchLoaded + 1,
    "system-loadout-delta": deltaMessage ? deltaMessage.index + 1 : null,
    "tool-result-searched-mcp": line((entry) => message(entry)?.toolName === `mcp__${mcpToolServer(CORPUS_MCP_SERVERS[1])}__echo`),
    "context-edit": line((entry) => entry.type === "context_edit"),
    compaction: line((entry) => entry.type === "compaction"),
    "branch-sibling": branchSibling,
  };
}

export function missingScenarioShapes(shapes: Record<CorpusScenarioShape, number | null>): CorpusScenarioShape[] {
  return CORPUS_SCENARIO_SHAPES.filter((shape) => shapes[shape] === null);
}

export async function corpusSessionEntries(sessionId: string, corpusDir: string = CORPUS_DIR): Promise<Array<Record<string, unknown>>> {
  for (const path of await corpusSessionFiles(corpusDir)) {
    const entries = await readSessionEntries(path);
    if (entries.some((entry) => entry.type === "session" && entry.id === sessionId)) return entries;
  }
  throw new Error(`The corpus has no session ${sessionId}`);
}

export async function observeSessions(input: {
  readonly registry: ObservableRegistry;
  readonly sessionIds: readonly string[];
  readonly servers: readonly CorpusServerObservation[];
}): Promise<Pick<CorpusObservation, "sessions" | "servers">> {
  const sessions: CorpusSessionObservation[] = [];
  for (const sessionId of input.sessionIds) {
    const slot = await input.registry.acquire(sessionId);
    const context = await slot.context() as SlotContext;
    const available = new Map((context.availableTools ?? []).map((tool) => [tool.name, tool]));
    const snapshot = slot.snapshot();
    if (!slot.sessionFile) throw new Error(`Reopened session ${sessionId} does not expose its canonical file`);
    sessions.push({
      sessionId,
      model: snapshot.model ? { provider: snapshot.model.provider, id: snapshot.model.id } : null,
      thinkingLevel: snapshot.thinkingLevel,
      activeTools: [...(context.activeTools ?? [])].sort()
        .map((name) => ({ name, exposure: exposureOf(available.get(name)) })),
      transcriptTotal: snapshot.transcriptTotal,
      leafEntryId: snapshot.leafEntryId ?? null,
      projection: snapshot.transcript,
    });
  }
  const mcpTools = [...await availableTools(input.registry, input.sessionIds[0]!).then((tools) => [...tools.keys()])]
    .filter((name) => name.startsWith("mcp__"));
  const servers: CorpusServerObservation[] = input.servers.map((server) => ({
    name: server.name,
    tools: mcpTools.filter((tool) => tool.startsWith(`mcp__${mcpToolServer(server.name)}__`)).sort(),
  }));
  return { sessions, servers };
}

export async function observeProviders(
  modelRuntime: ObservableModelRuntime,
  providers: ReadonlyArray<{ provider: string; model: { provider: string; id: string } | null }>,
): Promise<CorpusProviderObservation[]> {
  const stored = new Set((await modelRuntime.listCredentials()).map((credential) => credential.providerId));
  return providers.map((entry) => ({
    provider: entry.provider,
    storedCredential: stored.has(entry.provider),
    model: entry.model && modelRuntime.getModel(entry.model.provider, entry.model.id) ? entry.model : null,
  }));
}

export function normalizeObservation<T>(value: T, paths: StagedCorpusPaths): T {
  const replacements: Array<readonly [string, string]> = [
    [paths.agentDir, CORPUS_TOKENS.agent],
    [paths.sessionDir, CORPUS_TOKENS.sessions],
    [paths.cwd, CORPUS_TOKENS.workspace],
    [paths.mcpUrl, CORPUS_TOKENS.mcpUrl],
    [new URL(paths.mcpUrl).origin, CORPUS_TOKENS.mcpOrigin],
    [paths.root, CORPUS_TOKENS.root],
  ];
  const walk = (input: unknown): unknown => {
    if (typeof input === "string") return replaceAll(input, replacements);
    if (Array.isArray(input)) return input.map(walk);
    if (input && typeof input === "object") {
      return Object.fromEntries(Object.entries(input).map(([key, entry]) => [key, walk(entry)]));
    }
    return input;
  };
  return walk(value) as T;
}
