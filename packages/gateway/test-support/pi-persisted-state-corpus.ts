/**
 * The persisted-state upgrade corpus (#471, layer L1).
 *
 * A committed corpus written by the *outgoing* Pi SDK through the real Gateway
 * (regenerated with `npm run record:pi-corpus`) and reopened by the *installed*
 * SDK in `src/sessions/pi-persisted-state-corpus.integration.test.ts`. The
 * corpus is data about what Tron persisted; every assertion about it is a
 * Tron-level invariant, so a breaking SDK delta surfaces as a failed invariant
 * instead of a hand-authored fixture drifting.
 *
 * This module owns the corpus contract shared by the recorder and the test:
 * where it lives, which environment-specific values staging rebinds, and how a
 * reopened corpus is observed and normalized.
 *
 * It imports no Gateway code: the recorder and the test each build their own
 * `RuntimeRegistry`, so neither can hand the other module instances from a
 * different build of the Gateway.
 */
import { cp, mkdir, readFile, readdir, realpath, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { getCurrentTools, fauxProvider, type FauxProviderHandle, type FauxModelDefinition } from "@earendil-works/pi-ai";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { waitFor } from "./wait-for.js";

export const CORPUS_DIR = resolve(dirname(fileURLToPath(import.meta.url)), "../test-fixtures/pi-sdk/corpus");
export const CORPUS_AGENT_DIR = join(CORPUS_DIR, "agent");
export const CORPUS_MANIFEST_PATH = join(CORPUS_DIR, "manifest.json");
/** The one session directory the corpus declares in `settings.json`. */
export const CORPUS_SESSIONS_DIR_NAME = "sessions";

/**
 * Environment-specific values the corpus stores as tokens. Staging rebinds each
 * one to the machine running the test, so the committed corpus carries no host
 * path, no Node installation and no live port. `«corpus-workspace»` also
 * appears inside stored transcript content, because Pi records the session cwd
 * in the system message; the projection is therefore compared after the same
 * replacement.
 */
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

/** `mcp.json` server names in the corpus. Both are hyphenated (0.99.2 renames `-` to `_`). */
export const CORPUS_MCP_SERVERS = ["corpus-mcp", "corpus-oauth"] as const;

/**
 * The stdio fixture server's synthetic tool list. The recorder writes it as the
 * fixture's input and staging recreates it, so the corpus and the test never
 * disagree about which tools the server offers.
 */
export const CORPUS_STDIO_TOOLS = [{
  name: "echo",
  description: "Echo synthetic fixture input through the stdio server",
  inputSchema: { type: "object", properties: { value: { type: "string" } }, required: ["value"] },
}];
/** Fixture input the corpus's `mcp.json` references through the root token. */
export const CORPUS_MCP_STATE_FILE = "mcp-state.json";

/**
 * Synthetic provider credential stored in `auth.json` (1.0.3 renames this
 * provider to `azure`). The model is a reasoning model, so a session that
 * restored it keeps its persisted thinking level instead of clamping to `off`.
 */
export const CORPUS_AZURE_PROVIDER = "azure-openai-responses";
export const CORPUS_AZURE_MODEL = "gpt-5";
export const CORPUS_AZURE_API_KEY = "corpus-synthetic-azure-key";
/** The faux provider that owns every other corpus session. */
export const CORPUS_FAUX_PROVIDER = "tron-corpus";
export const CORPUS_FAUX_MODEL = "corpus-model";
/** A second faux model, so a session records a real `model_change` between two models. */
export const CORPUS_FAUX_MODEL_ALT = "corpus-model-alt";
/**
 * The faux provider's catalog. The recorder streams the scenario with it and the
 * test registers the same provider, because a reopened session only restores the
 * model its transcript names when that model still exists.
 */
export const CORPUS_FAUX_MODELS: FauxModelDefinition[] = [
  { id: CORPUS_FAUX_MODEL, input: ["text", "image"], reasoning: true },
  { id: CORPUS_FAUX_MODEL_ALT, input: ["text", "image"] },
];

/** The faux provider both sides register; only the recorder scripts responses on it. */
export function corpusFauxProvider(): FauxProviderHandle {
  return fauxProvider({ provider: CORPUS_FAUX_PROVIDER, models: CORPUS_FAUX_MODELS, tokensPerSecond: 10_000 });
}

/**
 * The model runtime both sides build: the corpus agent directory's credentials
 * (`auth.json`, where the renamed provider's key lives) plus the faux provider.
 */
export async function corpusModelRuntime(agentDir: string, faux: FauxProviderHandle): Promise<ModelRuntime> {
  const runtime = await ModelRuntime.create({
    authPath: join(agentDir, "auth.json"), modelsPath: null, refreshOnCreate: false, allowModelNetwork: false,
  });
  runtime.registerNativeProvider(faux.provider);
  return runtime;
}

export interface StagedCorpusPaths {
  /** Real path of the disposable root; every staged path is under it. */
  readonly root: string;
  readonly agentDir: string;
  readonly sessionDir: string;
  readonly cwd: string;
  /** `http://127.0.0.1:<port>/mcp` the OAuth server was rebound to. */
  readonly mcpUrl: string;
}

export interface StageCorpusOptions {
  /** Disposable directory the corpus is copied into; it must already exist. */
  readonly root: string;
  /** Path of the MCP OAuth fixture's streamable-HTTP endpoint. */
  readonly mcpUrl: string;
  /** Absolute path of the stdio MCP fixture script. */
  readonly mcpFixture: string;
  /** Absolute path of the Node executable that runs the stdio fixture. */
  readonly nodeExecutable: string;
}

function replaceAll(text: string, replacements: ReadonlyArray<readonly [string, string]>): string {
  let result = text;
  for (const [from, to] of replacements) result = result.split(from).join(to);
  return result;
}

/**
 * Rebind the committed corpus to this machine in a disposable directory:
 * replace every token, point the session header and `settings.json` at the
 * staged paths, and rebind the MCP servers to the fixture processes the caller
 * started. Only environment values move; every persisted Tron/Pi value is the
 * corpus's own.
 */
export async function stageCorpus(options: StageCorpusOptions): Promise<StagedCorpusPaths> {
  const root = await realpath(options.root);
  const agentDir = join(root, "agent");
  const sessionDir = join(agentDir, CORPUS_SESSIONS_DIR_NAME);
  const cwd = join(root, "workspace");
  await mkdir(cwd, { recursive: true });
  await cp(CORPUS_DIR, root, { recursive: true, force: true });
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

/** The corpus's canonical session files, in sorted order. */
export async function corpusSessionFiles(): Promise<string[]> {
  const directory = join(CORPUS_DIR, "agent", CORPUS_SESSIONS_DIR_NAME);
  const entries = await readdir(directory);
  return entries.filter((entry) => entry.endsWith(".jsonl")).sort().map((entry) => join(directory, entry));
}

/** One canonical session file's entries, in append order. */
export async function readSessionEntries(path: string): Promise<Array<Record<string, unknown>>> {
  const text = await readFile(path, "utf8");
  return text.trimEnd().split("\n").map((line) => JSON.parse(line) as Record<string, unknown>);
}

/**
 * The per-chat tool selection Tron persists: the loadout the canonical
 * transcript declares, replayed exactly the way Pi replays it on resume
 * (`getCurrentTools`). This is what a chat's "Available Tools" choice becomes on
 * disk, and it outlives the runtime that wrote it (#327).
 */
export function declaredToolNames(entries: ReadonlyArray<Record<string, unknown>>): string[] {
  const messages = entries.flatMap((entry) => entry.type === "message" && entry.message
    ? [entry.message as { role: string }]
    : []);
  return getCurrentTools(messages).map((tool) => tool.name).sort();
}

/** Recorded Tron-level observation of one reopened corpus session. */
export interface CorpusSessionObservation {
  readonly sessionId: string;
  readonly model: { readonly provider: string; readonly id: string } | null;
  readonly thinkingLevel: string;
  /** The loadout the transcript declares (Pi's `getCurrentTools` over the canonical file). */
  readonly declaredTools: readonly string[];
  /** The tools the reopened runtime resolves as active. */
  readonly activeTools: readonly string[];
  /** Each declared tool as the reopened runtime resolves it, or `null` when it no longer exists. */
  readonly resolvedTools: ReadonlyArray<{ readonly name: string; readonly exposure: string | null }>;
  readonly transcriptTotal: number;
  readonly leafEntryId: string | null;
  /** The transcript projection the mobile client pages. */
  readonly projection: readonly unknown[];
}

export interface CorpusServerObservation {
  readonly name: string;
  /** Tool names the reopened runtime registered from this server, as `mcp__<server>__<tool>`. */
  readonly tools: readonly string[];
}

export interface CorpusProviderObservation {
  readonly provider: string;
  /** Whether Pi's provider store still holds a credential for this provider id. */
  readonly storedCredential: boolean;
  /** The recorded model, or `null` when the installed SDK no longer registers it. */
  readonly model: { readonly provider: string; readonly id: string } | null;
}

export interface CorpusObservation {
  /** Pi SDK family version that recorded the manifest. */
  readonly recordedWith: string;
  readonly sessions: readonly CorpusSessionObservation[];
  readonly servers: readonly CorpusServerObservation[];
  readonly providers: readonly CorpusProviderObservation[];
}

/** The runtime surface the observation reads, so this module imports no Gateway code. */
export interface ObservableSlot {
  readonly sessionFile?: string;
  snapshot(): {
    model?: { provider: string; id: string } | undefined;
    thinkingLevel: string;
    leafEntryId?: string | undefined;
    transcript: readonly unknown[];
    transcriptTotal: number;
  };
  context(): Promise<unknown>;
}

/** The registry surface the observation reads. */
export interface ObservableRegistry {
  acquire(sessionId: string): Promise<ObservableSlot>;
}

/** The model-runtime surface the observation reads (Tron's own provider routes). */
export interface ObservableModelRuntime {
  /** Tron reads the saved provider credentials this way when it projects auth state. */
  listCredentials(): Promise<ReadonlyArray<{ providerId: string }>>;
  /** Tron resolves a persisted model this way before it applies a selection. */
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

/**
 * Wait until every reopened session's own runtime has registered every MCP tool
 * the corpus recorded. Each loaded runtime owns its own MCP connections, so this
 * covers all sessions; a server that was renamed, is unauthenticated, or lost its
 * persisted credential registers nothing, and the failure names the exact tool
 * names that stopped resolving instead of racing runtime creation.
 *
 * {@link observeSessions} expects this to have settled first; a caller that wants
 * every later invariant reported in the same run may catch the failure and
 * continue.
 */
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

/**
 * Observe every corpus session through Tron's own surfaces after reopening it.
 *
 * A declared tool that no longer exists is recorded as `null` rather than
 * throwing, so the comparison against the manifest reports every tool name that
 * stopped resolving instead of failing on the first one.
 */
export async function observeSessions(input: {
  readonly registry: ObservableRegistry;
  readonly sessionIds: readonly string[];
  /** The MCP tools the corpus recorded per server, as {@link waitForRecordedServerTools} awaited. */
  readonly servers: readonly CorpusServerObservation[];
}): Promise<Pick<CorpusObservation, "sessions" | "servers">> {
  const sessions: CorpusSessionObservation[] = [];
  for (const sessionId of input.sessionIds) {
    const slot = await input.registry.acquire(sessionId);
    const context = await slot.context() as SlotContext;
    const available = new Map((context.availableTools ?? []).map((tool) => [tool.name, tool]));
    const snapshot = slot.snapshot();
    if (!slot.sessionFile) throw new Error(`Reopened session ${sessionId} does not expose its canonical file`);
    const declaredTools = declaredToolNames(await readSessionEntries(slot.sessionFile));
    sessions.push({
      sessionId,
      model: snapshot.model ? { provider: snapshot.model.provider, id: snapshot.model.id } : null,
      thinkingLevel: snapshot.thinkingLevel,
      declaredTools,
      activeTools: [...(context.activeTools ?? [])].sort(),
      resolvedTools: declaredTools.map((name) => ({ name, exposure: exposureOf(available.get(name)) })),
      transcriptTotal: snapshot.transcriptTotal,
      leafEntryId: snapshot.leafEntryId ?? null,
      projection: snapshot.transcript,
    });
  }
  const mcpTools = [...await availableTools(input.registry, input.sessionIds[0]!).then((tools) => [...tools.keys()])]
    .filter((name) => name.startsWith("mcp__"));
  const servers: CorpusServerObservation[] = input.servers.map((server) => ({
    name: server.name,
    tools: mcpTools.filter((tool) => tool.startsWith(`mcp__${server.name}__`)).sort(),
  }));
  return { sessions, servers };
}

/**
 * Observe the agent directory's saved provider credentials and model keys through
 * Tron's own routes: `listCredentials`, which the Gateway's auth projection uses,
 * and `getModel`, which a session uses before it applies a persisted selection.
 */
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

/**
 * Normalize an observation for comparison: token out the environment values
 * staging rebound, so the committed manifest holds only persisted state.
 */
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
