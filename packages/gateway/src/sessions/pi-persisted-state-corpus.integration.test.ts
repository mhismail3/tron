/**
 * Reopens the persisted-state upgrade corpus with the installed Pi SDK (#471, layer L1).
 *
 * Failure modes this layer owns (written before the code, and the reason this is
 * a differential check against a generated corpus rather than a hand-authored
 * fixture):
 *
 * 1. A session the previous SDK wrote no longer opens through the real Gateway,
 *    so an existing chat is unreadable after an upgrade.
 * 2. It opens but projects differently, so the phone shows a different
 *    conversation than the one on disk.
 * 3. The per-chat tool selection recorded in the transcript no longer resolves:
 *    a tool the chat had enabled is gone or changed exposure. The 0.99.2 MCP name
 *    mapping (`mcp__my-server__x` -> `mcp__my_server__x`) is exactly this class,
 *    and Tron persists those names.
 * 4. The model the transcript names no longer resolves, because the provider or
 *    model key it persisted was renamed (1.0.3 renames `azure-openai-responses`
 *    to `azure`) or its saved credential is no longer found.
 * 5. A configured MCP server is no longer connected or authenticated, so its
 *    tools disappear (the fixture's OAuth server answers 401 without the
 *    credential the corpus holds).
 * 6. Reopening rewrites the canonical session, silently migrating user state
 *    instead of reading it.
 *
 * Modes 4 and 5 are separate cases so one upgrade run names both deltas: the
 * saved provider keys are read from the agent directory alone, and the sessions
 * are reopened through the Gateway.
 *
 * The corpus and its recorded manifest are produced by
 * `test-fixtures/pi-sdk/record-corpus.integration.test.ts` (`npm run record:pi-corpus`) with
 * the outgoing SDK; see `packages/gateway/README.md`, "Pi SDK maintenance".
 */
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync } from "node:fs";
import { mkdtemp, readFile, realpath, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it } from "vitest";
import { TrustService } from "../admin/trust-service.js";
import { RuntimeRegistry } from "./runtime-registry.js";
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
} from "../../test-support/pi-persisted-state-corpus.js";
import { waitFor } from "../../test-support/wait-for.js";

const PACKAGE_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
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

/** Content hash per staged session file, so reopening can be proven read-only. */
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

/**
 * Stage the corpus and start the MCP fixtures it points at. The OAuth server is
 * the one the corpus's `corpus-oauth` server authenticates against, so its
 * persisted credential has to be exercised against a live server.
 */
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

describe("persisted-state upgrade corpus", () => {
  it("resolves every saved provider key and model the corpus recorded", async () => {
    const manifest = await readManifest(CORPUS_SOURCE_DIR);
    const staged = await stageWithServers();
    const observed = await observeProviders(await corpusModelRuntime(staged.agentDir, corpusFauxProvider()), manifest.providers);
    // `azure-openai-responses` is the provider key 1.0.3 renames to `azure`. The
    // rename is detected by the model, which the settings and the transcripts
    // name; the credential read catches a store that stops returning the
    // persisted provider id at all (a re-key or a rewrite).
    expect(observed, "every saved provider key and model must still resolve").toEqual(manifest.providers);
  }, 30_000);

  it("reopens every recorded session with the same projection, tools and model", async () => {
    const manifest = await readManifest(CORPUS_SOURCE_DIR);
    const staged = await stageWithServers();
    const before = await sessionFileHashes(staged.sessionDir, CORPUS_SOURCE_DIR);
    const trust = new TrustService(staged.agentDir);
    await trust.set(staged.cwd, true);
    const registry = new RuntimeRegistry({
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
    // Readiness is reported as a soft failure so the rest of the invariants are
    // still observed in the same run: a renamed or unauthenticated MCP server
    // shows up both as the missing tool here and as an unresolved selection below.
    let unready: Error | undefined;
    try {
      await waitForRecordedServerTools(registry, sessionIds, manifest.servers);
    } catch (error) {
      unready = error as Error;
    }
    const observed = normalizeObservation(await observeSessions({ registry, sessionIds, servers: manifest.servers }), staged);

    expect(observed.sessions.map((session) => session.sessionId), "every recorded session must reopen").toEqual(sessionIds);
    expect.soft(unready?.message ?? null, "every persisted MCP tool must still register").toBeNull();
    // Soft assertions: one upgrade run reports every invariant that stopped
    // holding (a renamed MCP tool, a model that fell back, a changed projection)
    // instead of only the first one.
    for (const [index, session] of observed.sessions.entries()) {
      const recorded = manifest.sessions[index]!;
      const where = `session ${session.sessionId}`;
      expect.soft(session.model, `${where}: the persisted model must still resolve`).toEqual(recorded.model);
      expect.soft(session.thinkingLevel, `${where}: the persisted thinking level must still resolve`).toEqual(recorded.thinkingLevel);
      expect.soft(session.activeTools, `${where}: every tool the chat's persisted selection enables must resolve to the same name and exposure`)
        .toEqual(recorded.activeTools);
      expect.soft(session.leafEntryId, `${where}: the session must reopen on the same branch leaf`).toEqual(recorded.leafEntryId);
      expect.soft(session.transcriptTotal, `${where}: the transcript must project the same number of rows`).toEqual(recorded.transcriptTotal);
      expect.soft(session.projection, `${where}: the projection must equal the recorded projection`).toEqual(recorded.projection);
    }
    // The corpus's documented coverage is asserted against the committed JSONL,
    // not against prose: a regeneration that silently loses a shape (a codemode
    // call that parses as a subtraction, a tool search that loads nothing) fails
    // here even though every reopen invariant would still hold.
    const shapes = scenarioShapes(await corpusSessionEntries(sessionIds[0]!, CORPUS_SOURCE_DIR));
    expect.soft(missingScenarioShapes(shapes), "the committed corpus must cover every shape this layer claims")
      .toEqual([]);
    expect.soft(observed.servers, "every configured MCP server must reconnect and expose its persisted tools")
      .toEqual(CORPUS_MCP_SERVERS.map((name) => ({
        name, tools: manifest.servers.find((server) => server.name === name)?.tools ?? [],
      })));
    // Reopening is a read: a migration that rewrites the canonical file would
    // silently change user state instead of reading it.
    expect.soft(await sessionFileHashes(staged.sessionDir, CORPUS_SOURCE_DIR), "reopening must not rewrite the canonical sessions")
      .toEqual(before);
  }, 60_000);
});
