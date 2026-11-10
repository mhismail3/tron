import { createTestRegistry } from "../../../test-support/gateway-registry.js";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync } from "node:fs";
import { mkdtemp, readFile, realpath, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it } from "vitest";
import { TrustService } from "../../kernel/resources/trust-service.js";
import { RuntimeRegistry } from "../../kernel/session/runtime-registry.js";
import {
  CORPUS_DIR,
  CORPUS_MCP_SERVERS,
  corpusFauxProvider,
  corpusModelRuntime,
  corpusSessionEntries,
  corpusSessionFiles,
  missingScenarioShapes,
  normalizeObservation,
  observeProviders,
  observeSessions,
  scenarioShapes,
  stageCorpus,
  waitForRecordedServerTools,
  type CorpusObservation,
  type StagedCorpusPaths,
} from "../../../test-support/pi-persisted-state-corpus.js";
import { waitFor } from "../../../test-support/wait-for.js";

const PACKAGE_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const MCP_STDIO_FIXTURE = resolve(PACKAGE_ROOT, "test-fixtures/pi-sdk/mcp-jsonrpc-fixture.mjs");
const MCP_OAUTH_FIXTURE = resolve(PACKAGE_ROOT, "test-support/mcp-oauth-fixture.mjs");

const CORPUS_SOURCE_DIR = resolve(process.env.TRON_PI_PERSISTED_STATE_CORPUS_DIR ?? CORPUS_DIR);
const roots: string[] = [];
const registries: RuntimeRegistry[] = [];
const servers: Array<ReturnType<typeof spawn>> = [];
let priorAgentDir: string | undefined;
afterEach(async () => {
  if (priorAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
  else process.env.PI_CODING_AGENT_DIR = priorAgentDir;
  priorAgentDir = undefined;
  await Promise.all(registries.splice(0).map((registry) => registry.dispose().catch(() => {})));
  for (const server of servers.splice(0)) {
    if (server.exitCode !== null || server.signalCode !== null) continue;
    const exited = new Promise<void>((resolve) => server.once("exit", () => resolve()));
    server.kill("SIGTERM");
    await exited;
  }
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

async function sessionFileHashes(sessionDir: string, corpusDir: string): Promise<Record<string, string>> {
  const hashes: Record<string, string> = {};
  for (const path of await corpusSessionFiles(corpusDir)) {
    const name = path.slice(path.lastIndexOf("/") + 1);
    hashes[name] = createHash("sha256").update(await readFile(join(sessionDir, name))).digest("hex");
  }
  return hashes;
}

async function readManifest(corpusDir: string): Promise<CorpusObservation> {
  return JSON.parse(await readFile(join(corpusDir, "manifest.json"), "utf8")) as CorpusObservation;
}

async function stageWithServers(corpusDir: string = CORPUS_SOURCE_DIR): Promise<StagedCorpusPaths> {
  const root = await realpath(await mkdtemp(join(tmpdir(), "tron-corpus-reopen-")));
  roots.push(root);
  const oauthPortFile = join(root, "oauth.port");
  const oauthServer = spawn(process.execPath, [MCP_OAUTH_FIXTURE, oauthPortFile], { stdio: "ignore" });
  servers.push(oauthServer);
  await waitFor(() => existsSync(oauthPortFile), "the MCP OAuth fixture to bind a port");
  const mcpUrl = `http://127.0.0.1:${Number(await readFile(oauthPortFile, "utf8"))}/mcp`;
  const staged = await stageCorpus({ root, corpusDir, mcpUrl, mcpFixture: MCP_STDIO_FIXTURE, nodeExecutable: process.execPath });
  if (priorAgentDir === undefined) priorAgentDir = process.env.PI_CODING_AGENT_DIR;
  process.env.PI_CODING_AGENT_DIR = staged.agentDir;
  return staged;
}

function withRestoredSearchLoads(recorded: CorpusObservation["sessions"][number]): CorpusObservation["sessions"][number]["activeTools"] {
  const loaded = new Set(recorded.projection.flatMap((row) => {
    const item = row as { toolName?: string; details?: { loaded?: unknown } };
    return item.toolName === "tool_search" && Array.isArray(item.details?.loaded) ? item.details.loaded as string[] : [];
  }));
  const names = new Set(recorded.activeTools.map((tool) => tool.name));
  return [...recorded.activeTools, ...[...loaded].filter((name) => !names.has(name)).map((name) => ({ name, exposure: "deferred" }))]
    .sort((left, right) => (left.name < right.name ? -1 : left.name > right.name ? 1 : 0));
}

describe("persisted-state upgrade corpus", () => {
  it("resolves every saved provider key and model the corpus recorded", async () => {
    const manifest = await readManifest(CORPUS_SOURCE_DIR);
    const staged = await stageWithServers();
    const observed = await observeProviders(await corpusModelRuntime(staged.agentDir, corpusFauxProvider()), manifest.providers);
    expect(observed, "every saved provider key and model must still resolve").toEqual(manifest.providers);
  }, 30_000);

  it("reopens every recorded session with the same projection, tools and model", async () => {
    const manifest = await readManifest(CORPUS_SOURCE_DIR);
    const staged = await stageWithServers();
    const before = await sessionFileHashes(staged.sessionDir, CORPUS_SOURCE_DIR);
    const trust = new TrustService(staged.agentDir);
    await trust.set(staged.cwd, true);
    const registry = await createTestRegistry({
      agentDir: staged.agentDir, tronHome: join(staged.root, "tron"), idleRuntimeMs: 600_000,
      modelRuntimeFactory: () => corpusModelRuntime(staged.agentDir, corpusFauxProvider()),
      trust, broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    await waitFor(() => (registry as unknown as { sessionCatalog: { hasCompleteCut(): boolean } }).sessionCatalog.hasCompleteCut(),
      "the corpus catalog's complete cut");
    await registry.catalog("all");
    const sessionIds = manifest.sessions.map((session) => session.sessionId);
    let unready: Error | undefined;
    try {
      await waitForRecordedServerTools(registry, sessionIds, manifest.servers);
    } catch (error) {
      unready = error as Error;
    }
    const observed = normalizeObservation(await observeSessions({ registry, sessionIds, servers: manifest.servers }), staged);

    expect(observed.sessions.map((session) => session.sessionId), "every recorded session must reopen").toEqual(sessionIds);
    expect.soft(unready?.message ?? null, "every persisted MCP tool must still register").toBeNull();
    for (const [index, session] of observed.sessions.entries()) {
      const recorded = manifest.sessions[index]!;
      const where = `session ${session.sessionId}`;
      expect.soft(session.model, `${where}: the persisted model must still resolve`).toEqual(recorded.model);
      expect.soft(session.thinkingLevel, `${where}: the persisted thinking level must still resolve`).toEqual(recorded.thinkingLevel);
      expect.soft(session.activeTools, `${where}: every tool the chat's persisted selection enables must resolve to the same name and exposure`)
        .toEqual(withRestoredSearchLoads(recorded));
      expect.soft(session.leafEntryId, `${where}: the session must reopen on the same branch leaf`).toEqual(recorded.leafEntryId);
      expect.soft(session.transcriptTotal, `${where}: the transcript must project the same number of rows`).toEqual(recorded.transcriptTotal);
      expect.soft(session.projection, `${where}: the projection must equal the recorded projection`).toEqual(recorded.projection);
    }
    const shapes = scenarioShapes(await corpusSessionEntries(sessionIds[0]!, CORPUS_SOURCE_DIR));
    expect.soft(missingScenarioShapes(shapes), "the committed corpus must cover every shape this layer claims")
      .toEqual([]);
    expect.soft(observed.servers, "every configured MCP server must reconnect and expose its persisted tools")
      .toEqual(CORPUS_MCP_SERVERS.map((name) => ({
        name, tools: manifest.servers.find((server) => server.name === name)?.tools ?? [],
      })));
    expect.soft(await sessionFileHashes(staged.sessionDir, CORPUS_SOURCE_DIR), "reopening must not rewrite the canonical sessions")
      .toEqual(before);
  }, 60_000);
});
