import { existsSync } from "node:fs";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { ModelRuntime, SessionManager } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider } from "@earendil-works/pi-ai";
import WebSocket from "ws";
import { afterAll, afterEach, describe, expect, it, vi } from "vitest";
import { TrustService } from "../admin/trust-service.js";
import { DeviceStore } from "../security/device-store.js";
import { RuntimeRegistry } from "../sessions/runtime-registry.js";
import { SessionSearchIndex } from "../sessions/session-search-index.js";
import { SessionSearchService } from "../sessions/session-search-service.js";
import { CommandReceiptStore } from "./command-receipts.js";
import { GatewayService } from "./gateway-service.js";
import { GatewayServer } from "./server.js";
import { waitFor } from "../../test-support/wait-for.js";

/** Retained, regenerable evidence for one run of this file. The path is stable
 * and gitignored so an operator can inspect exactly what the archive contract
 * did without committing one-off output. */
const REPORT_PATH = join(process.cwd(), "test-results", "session-archive.integration.json");
const report: {
  generatedAt: string;
  cases: Array<{ name: string; passed: boolean; evidence: Record<string, unknown> }>;
} = { generatedAt: new Date().toISOString(), cases: [] };

/** One archive case. The body returns the values it measured, and this records
 * the case's real outcome, so a failing case stays visible in the report with
 * its error instead of disappearing from it. */
function archiveCase(name: string, body: () => Promise<Record<string, unknown>>): void {
  it(name, async () => {
    try {
      report.cases.push({ name, passed: true, evidence: await body() });
    } catch (error) {
      report.cases.push({
        name,
        passed: false,
        evidence: { error: error instanceof Error ? error.message : String(error) },
      });
      throw error;
    }
  });
}

afterAll(async () => {
  await mkdir(dirname(REPORT_PATH), { recursive: true });
  await writeFile(REPORT_PATH, `${JSON.stringify(report, null, 2)}\n`, "utf8");
});

const cleanup: Array<() => Promise<void>> = [];
afterEach(async () => {
  const results = await Promise.allSettled(cleanup.splice(0).map((dispose) => dispose()));
  vi.restoreAllMocks();
  const failures = results.filter((result) => result.status === "rejected");
  if (failures.length) throw new AggregateError(failures.map((result) => result.reason), "Archive fixture cleanup failed");
});

interface Stack {
  registry: RuntimeRegistry;
  service: GatewayService;
  server: GatewayServer;
  receipts: CommandReceiptStore;
  port: number;
}

interface Client {
  frames: any[];
  send(id: string, method: string, params: object): void;
  request(id: string, method: string, params: object): Promise<any>;
}

async function fixture(options: {
  /** Writes one extension source into `${agentDir}/extensions/<name>`. */
  extensions?: Array<{ name: string; source: (root: string) => string }>;
  /** Writes `${agentDir}/settings.json` before the first runtime starts. */
  settings?: Record<string, unknown>;
  /** Wires a real search index and service into GatewayService. */
  search?: boolean;
  /** Runs after startup admission but before attention recovery, which is the
   * window the real Gateway already serves from. */
  duringStartupRecovery?: (registry: RuntimeRegistry, cwd: string) => Promise<void>;
} = {}) {
  const root = await mkdtemp(join(tmpdir(), "tron-session-archive-"));
  const agentDir = join(root, "agent");
  const cwd = join(root, "project");
  const sessionDirectory = join(agentDir, "sessions", "workspace");
  await Promise.all([mkdir(sessionDirectory, { recursive: true }), mkdir(cwd, { recursive: true })]);
  if (options.extensions?.length) {
    await mkdir(join(agentDir, "extensions"), { recursive: true });
    for (const extension of options.extensions) {
      await writeFile(join(agentDir, "extensions", extension.name), extension.source(root));
    }
  }
  if (options.settings) {
    await writeFile(join(agentDir, "settings.json"), `${JSON.stringify(options.settings)}\n`, "utf8");
  }
  const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
  process.env.PI_CODING_AGENT_DIR = agentDir;

  const faux = fauxProvider({ provider: "session-archive-fixture", tokensPerSecond: 10_000 });
  faux.setResponses([fauxAssistantMessage("archive fixture response")]);
  const runtimeFactory = vi.fn(async () => {
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    return runtime;
  });
  const listChanged = vi.fn();
  const archiveDiagnostic = vi.fn();
  const logs: Array<{ level: string; message: string; metadata: Record<string, unknown> }> = [];
  const captureLog = (level: string, message: string, metadata: Record<string, unknown>) => logs.push({ level, message, metadata });
  const sockets: WebSocket[] = [];
  const devices = new DeviceStore(root, "fixture-machine");
  await devices.initialize();
  const invitation = await devices.ensureEnrollment();
  const paired = await devices.pair(invitation.code, "Fixture phone");
  await devices.ensureEnrollment();

  let current: Stack | undefined;
  let server: GatewayServer | undefined;
  let searchService: SessionSearchService | undefined;
  const start = async (): Promise<Stack> => {
    server = undefined;
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: root,
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: runtimeFactory as never,
      trust: new TrustService(agentDir),
      // Mirrors gateway-main: slot events reach subscribed sockets.
      broadcast: (sessionId: string, topic: string, payload: unknown) => {
        server?.broadcastSession(sessionId, topic, payload as never);
      },
      sessionSummaryChanged: () => {},
      // Mirrors gateway-main: the registry announcement is what reaches clients.
      sessionListChanged: () => { listChanged(); server?.notifySessionListChanged(); },
      // Mirrors gateway-main: a rebind carries the connection's subscription.
      sessionRekeyed: (previousId: string, nextId: string) => server?.rekeySession(previousId, nextId),
      archiveDiagnostic,
    });
    await registry.initialize();
    // The listener serves before the owner publishes its first cut, and a read
    // refuses retryably until then (G-1c). The fixture waits so each case
    // exercises its own subject instead of the catalog's startup.
    await (registry as unknown as { sessionCatalog: { whenPublished(): Promise<void> } })
      .sessionCatalog.whenPublished();
    await options.duringStartupRecovery?.(registry, cwd);
    await registry.recoverCanonicalAttention();
    // The search owner is optional in the Gateway, so only the traversal that
    // exercises the search projection pays for a real index and coordinator.
    if (options.search) {
      searchService = new SessionSearchService(registry, await SessionSearchIndex.open(join(root, "gateway", "session-search.sqlite")));
    }
    const uploads = {
      acquire: vi.fn(),
      materialize: vi.fn(async () => ({ envelope: "", images: [], attachments: [], photoCount: 0, fileAttachmentCount: 0 })),
      removeSession: vi.fn(async () => {}),
    };
    const receipts = new CommandReceiptStore(root);
    const service = new GatewayService({
      config: { tronHome: root },
      devices,
      sessions: registry,
      receipts,
      uploads,
      terminals: { belongsToSession: () => false },
      logger: { log: captureLog },
      sessionDeleted: (sessionId: string) => server?.revokeSessionTerminals(sessionId),
      ...(searchService ? { sessionSearch: searchService } : {}),
    } as never);
    server = new GatewayServer({
      host: "127.0.0.1",
      port: 0,
      maxFrameBytes: 1_048_576,
      devices,
      sessions: registry,
      service,
      uploads: uploads as never,
      auth: { cancelOwner: () => {}, detachClient: () => {} } as never,
      logger: { log: captureLog } as never,
    });
    await server.listen();
    const port = (server as unknown as { server: { address(): { port: number } } }).server.address().port;
    current = { registry, service, server, receipts, port };
    return current;
  };
  const stack = await start();
  cleanup.push(async () => {
    if (current) {
      sockets.forEach((socket) => socket.terminate());
      await current.server.close();
      await searchService?.close();
      searchService = undefined;
      await current.registry.dispose();
      await current.receipts.dispose();
      current = undefined;
    }
    if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
    else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
    await rm(root, { recursive: true, force: true });
  });
  const restart = async (): Promise<Stack> => {
    sockets.forEach((socket) => socket.terminate());
    sockets.splice(0);
    const previous = current!;
    current = undefined;
    await previous.server.close();
    await searchService?.close();
    searchService = undefined;
    await previous.registry.dispose();
    await previous.receipts.dispose();
    return start();
  };
  const connect = async (): Promise<Client> => {
    const active = current!;
    const socket = new WebSocket(`ws://127.0.0.1:${active.port}/v1/socket`, { headers: { authorization: `Bearer ${paired.token}` } });
    sockets.push(socket);
    const frames: any[] = [];
    socket.on("message", (raw) => frames.push(JSON.parse(raw.toString())));
    await waitFor(() => socket.readyState === WebSocket.OPEN, "socket open");
    socket.send(JSON.stringify({ type: "hello", protocolVersion: 7 }));
    await waitFor(() => frames.some((frame) => frame.type === "hello"), "hello");
    const send = (id: string, method: string, params: object) => socket.send(JSON.stringify({ type: "request", id, method, params }));
    return {
      frames,
      send,
      request: async (id: string, method: string, params: object) => {
        send(id, method, params);
        await waitFor(() => frames.some((frame) => frame.id === id), `response ${method}`);
        return frames.find((frame) => frame.id === id);
      },
    };
  };
  /** The fixture writes canonical files itself, so it is an external writer to
   * the catalog: the reader no longer walks the folder, and forcing the owner's
   * cut is the deterministic equivalent of waiting the folder watcher out.
   * Without it a read right after a write races the watcher's own debounce. */
  const settle = async (): Promise<void> => {
    const owner = (current!.registry as unknown as {
      sessionCatalog: { reconcile(): Promise<void>; settled(): Promise<void> };
    }).sessionCatalog;
    await owner.reconcile();
    await owner.settled();
  };
  /** A canonical, persisted session with no live runtime, created the way the
   * pinned SDK creates one. */
  const coldSession = async (label: string): Promise<{ id: string; file: string }> => {
    const manager = SessionManager.create(cwd, sessionDirectory);
    manager.appendMessage(fauxAssistantMessage(`${label} canonical response`));
    const file = manager.getSessionFile()!;
    await settle();
    return { id: manager.getSessionId(), file };
  };
  /** A canonical session written directly instead of through the pinned
   * manager, so the fixture controls its exact bytes and revisions. */
  const rawSession = async (label: string, id: string): Promise<{ id: string; file: string; entryId: string }> => {
    const timestamp = new Date().toISOString();
    const entryId = `${label}-entry`;
    const file = join(sessionDirectory, id, "session.jsonl");
    await mkdir(dirname(file), { recursive: true });
    await writeFile(file, [
      JSON.stringify({ type: "session", version: 3, id, timestamp, cwd }),
      JSON.stringify({
        type: "message", id: entryId, parentId: null, timestamp,
        // A canonical assistant envelope: the runtime projects its usage and
        // stop reason when a search anchor opens this cold session.
        message: {
          role: "assistant", content: [{ type: "text", text: `${label} canonical response` }],
          api: "faux", provider: "faux", model: "faux-1", stopReason: "stop",
          usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
        },
      }),
    ].join("\n") + "\n", "utf8");
    await settle();
    return { id, file, entryId };
  };
  return { root, agentDir, cwd, sessionDirectory, devices, paired, faux, runtimeFactory, listChanged, archiveDiagnostic, logs, connect, coldSession, rawSession, settle, restart, current: () => current! };
}

/** An extension-owned trigger that starts a turn of its own. */
const wakeExtension = (root: string) => `
        import { existsSync, unlinkSync, writeFileSync } from "node:fs";
        import { setTimeout as delay } from "node:timers/promises";
        export default function (pi) {
          writeFileSync(${JSON.stringify(join(root, "wake-polling"))}, "polling");
          void (async () => {
            for (;;) {
              if (existsSync(${JSON.stringify(join(root, "wake-trigger"))})) {
                pi.sendMessage({ customType: "external-wake", content: "external wake", display: false }, { triggerTurn: true });
                writeFileSync(${JSON.stringify(join(root, "wake-sent"))}, "sent");
                unlinkSync(${JSON.stringify(join(root, "wake-polling"))});
                return;
              }
              await delay(5);
            }
          })();
        }
      `;

/** A command that holds its own admission until the test releases it, the way
 * a long branch summary or resource reload holds the session lane. */
const holdCommandExtension = (root: string) => `
        import { existsSync } from "node:fs";
        import { setTimeout as delay } from "node:timers/promises";
        export default function (pi) {
          pi.registerCommand("hold", { handler: async (_args, ctx) => {
            ctx.ui.setStatus("hold", "waiting");
            while (!existsSync(${JSON.stringify(join(root, "hold-release"))})) await delay(5);
            ctx.ui.setStatus("hold", "released");
          }});
        }
      `;

/** A command that replaces the live session with another canonical session
 * file, the way a session-switching extension does. */
const switchCommandExtension = () => `
        export default function (pi) {
          pi.registerCommand("switch", { handler: async (args, ctx) => {
            await ctx.switchSession(args.trim());
          }});
        }
      `;

/** A command that blocks on a real semantic user interaction. */
const selectCommandExtension = () => `
        export default function (pi) {
          pi.registerCommand("select-hold", { handler: async (_args, ctx) => {
            const answer = await ctx.ui.select("Choose a path", ["Keep", "Change"]);
            ctx.ui.setStatus("answer", answer ?? "Cancelled");
          }});
        }
      `;

const list = async (client: Client, archived: "exclude" | "only", extra: Record<string, unknown> = {}) => {
  const response = await client.request(`list-${archived}-${Math.random().toString(36).slice(2, 8)}`, "session.list", { scope: "user", archived, ...extra });
  expect(response.ok, JSON.stringify(response)).toBe(true);
  return response.result as {
    sessions: Array<{ id: string; archivedAt?: string; phase?: string; updatedAt?: string; isUnread?: boolean; attentionRevision?: number }>;
    listRevision: number;
    projectionToken: string;
    notModified?: boolean;
    archivedCount?: number;
    nextCursor?: string;
  };
};

/** A live, idle session: `openedSlot` requires the subscription an open+sync
 * establishes, and archiving is allowed while a slot is idle. */
const openSession = async (client: Client, sessionId: string) => {
  const opened = await client.request(`open-${sessionId}`, "session.open", { sessionId });
  expect(opened.ok, JSON.stringify(opened)).toBe(true);
  const synced = await client.request(`sync-${sessionId}`, "session.sync", { sessionId, syncToken: opened.result.syncToken });
  expect(synced.ok, JSON.stringify(synced)).toBe(true);
};

const archiveSession = async (client: Client, sessionId: string, commandId: string) => {
  const response = await client.request(`archive-${commandId}`, "session.archive.set", { commandId, sessionId, archived: true });
  expect(response.ok, JSON.stringify(response)).toBe(true);
  return response.result as { archived: boolean; archivedAt: string };
};

const listedIds = async (client: Client, archived: "exclude" | "only") =>
  (await list(client, archived)).sessions.map((session) => session.id);

const archivedRecord = async (root: string, sessionId: string): Promise<unknown> => {
  const document = JSON.parse(await readFile(join(root, "gateway", "session-archive.json"), "utf8")) as {
    sessions: Record<string, unknown>;
  };
  return document.sessions[sessionId];
};

const attentionRecord = async (root: string, sessionId: string): Promise<unknown> => {
  const document = JSON.parse(await readFile(join(root, "gateway", "session-attention.json"), "utf8")) as {
    sessions: Record<string, unknown>;
  };
  return document.sessions[sessionId];
};

/** Fails every durable archive-record removal from now on, modelling a full or
 * failing disk at the store's exact write boundary. */
function failArchiveRemovals(registry: RuntimeRegistry): () => void {
  const store = (registry as unknown as { archive: { remove(sessionId: string): Promise<boolean> } }).archive;
  const durable = store.remove.bind(store);
  store.remove = async () => { throw new Error("Fixture archive write failure"); };
  return () => { store.remove = durable; };
}

const listChangedFrames = (client: Client) =>
  client.frames.filter((frame) => frame.type === "event" && frame.topic === "session.listChanged").length;

/** Snapshots a subscribed client actually received for one session, newest last. */
const snapshotFrames = (client: Client, sessionId: string) =>
  client.frames.filter((frame) => frame.type === "event" && frame.topic === "session.snapshot" && frame.sessionId === sessionId);

/** The authoritative state a subscribed client received for one session, newest
 * last, however the outbound queue delivered it: as its own `session.snapshot`,
 * or — when a newer snapshot of the same runtime generation superseded an
 * unsent one, and the queue covered the dropped sequence with a
 * `session.rebaseline` (`G-4`) — as the snapshot nested inside that rebaseline.
 * Both make the client install that state, so a case asserting on the state a
 * client ends up with must read both. */
const deliveredAuthorityFrames = (client: Client, sessionId: string) =>
  client.frames.flatMap((frame) => {
    if (frame.type !== "event" || frame.sessionId !== sessionId) return [];
    if (frame.topic === "session.snapshot") return [frame];
    if (frame.topic === "session.rebaseline" && frame.payload?.snapshot !== undefined) {
      return [{ ...frame, topic: "session.snapshot", payload: frame.payload.snapshot }];
    }
    return [];
  });

const latestSnapshot = (client: Client, sessionId: string) =>
  snapshotFrames(client, sessionId).at(-1)?.payload as { archivedAt?: string } | undefined;

const search = async (client: Client, query: string) => {
  const response = await client.request(`search-${Math.random().toString(36).slice(2, 8)}`, "session.search", { query, maxResults: 10 });
  expect(response.ok, JSON.stringify(response)).toBe(true);
  return response.result as {
    coverage: { omittedSessions: number };
    results: Array<{ sessionId: string; entryId: string; archived: boolean; anchorRevision: unknown }>;
  };
};

describe("session archive over the real Gateway", () => {
  archiveCase("keeps an archived session searchable and marked archived", async () => {
    const f = await fixture({ search: true });
    const client = await f.connect();
    const session = await f.rawSession("searchable", "searchable-archive-session");
    // The pinned SDK records its effective thinking level the first time a
    // runtime opens a canonical file. One warm query and anchor settle that
    // write before the measured revisions below.
    const warm = await search(client, "searchable");
    const warmHit = warm.results.find((result) => result.sessionId === session.id);
    expect(warmHit, JSON.stringify(warm)).toBeDefined();
    const warmAnchor = await client.request("search-anchor-warmup", "session.search.anchor", {
      sessionId: session.id, entryId: session.entryId, anchorRevision: warmHit!.anchorRevision,
    });
    expect(warmAnchor.ok, JSON.stringify(warmAnchor)).toBe(true);
    const canonicalBytes = await readFile(session.file, "utf8");

    const visible = await search(client, "searchable");
    const visibleHit = visible.results.find((result) => result.sessionId === session.id);
    expect(visibleHit, JSON.stringify(visible)).toBeDefined();
    expect(visibleHit?.archived).toBe(false);
    expect(visibleHit?.entryId).toBe(session.entryId);
    expect(visible.coverage.omittedSessions).toBe(0);
    const anchor = await client.request("search-anchor-visible", "session.search.anchor", {
      sessionId: session.id, entryId: session.entryId, anchorRevision: visibleHit!.anchorRevision,
    });
    expect(anchor.ok, JSON.stringify(anchor)).toBe(true);

    const archived = await client.request("search-archive", "session.archive.set", {
      commandId: "search-archive-command", sessionId: session.id, archived: true,
    });
    expect(archived.ok, JSON.stringify(archived)).toBe(true);
    expect((await list(client, "exclude")).sessions.map((row) => row.id)).not.toContain(session.id);

    // Search reads archive state beside the index: the same canonical passage
    // and content revision come back, only relabeled, and the session stays
    // anchorable while its dashboard row is hidden.
    const hidden = await search(client, "searchable");
    const hiddenHit = hidden.results.find((result) => result.sessionId === session.id);
    expect(hiddenHit, JSON.stringify(hidden)).toBeDefined();
    expect(hiddenHit?.archived).toBe(true);
    expect(hiddenHit?.entryId).toBe(session.entryId);
    expect(hiddenHit?.anchorRevision.branchDigest).toBe(visibleHit!.anchorRevision.branchDigest);
    expect(hiddenHit?.anchorRevision.fileIdentity).toBe(visibleHit!.anchorRevision.fileIdentity);
    expect(await readFile(session.file, "utf8")).toBe(canonicalBytes);
    const anchorWhileArchived = await client.request("search-anchor-archived", "session.search.anchor", {
      sessionId: session.id, entryId: session.entryId, anchorRevision: hiddenHit!.anchorRevision,
    });
    expect(anchorWhileArchived.ok, JSON.stringify(anchorWhileArchived)).toBe(true);

    const restored = await client.request("search-unarchive", "session.archive.set", {
      commandId: "search-unarchive-command", sessionId: session.id, archived: false,
    });
    expect(restored.ok, JSON.stringify(restored)).toBe(true);
    const afterUnarchive = await search(client, "searchable");
    expect(afterUnarchive.results.find((result) => result.sessionId === session.id)?.archived).toBe(false);
    return {
      entryId: hiddenHit?.entryId,
      archivedResult: hiddenHit?.archived,
      unchangedContentRevision: hiddenHit?.anchorRevision.branchDigest === visibleHit!.anchorRevision.branchDigest,
      anchorableWhileArchived: anchorWhileArchived.ok,
      archivedAfterUnarchive: afterUnarchive.results.find((result) => result.sessionId === session.id)?.archived,
    };
  });

  archiveCase("archives an idle session without touching its canonical file", async () => {
    const f = await fixture();
    const client = await f.connect();
    const archived = await f.coldSession("archived");
    const visible = await f.coldSession("visible");
    const before = await readFile(archived.file, "utf8");
    const beforeRow = (await list(client, "exclude")).sessions.find((session) => session.id === archived.id);
    expect(beforeRow?.updatedAt).toBeDefined();
    const factoryCallsBeforeArchive = f.runtimeFactory.mock.calls.length;
    f.listChanged.mockClear();

    const response = await client.request("archive-1", "session.archive.set", {
      commandId: "archive-command-0001", sessionId: archived.id, archived: true,
    });
    expect(response.ok, JSON.stringify(response)).toBe(true);
    expect(response.result).toMatchObject({ archived: true });
    expect(typeof response.result.archivedAt).toBe("string");

    const excluded = await list(client, "exclude");
    expect(excluded.sessions.map((session) => session.id)).toEqual([visible.id]);
    expect(excluded.archivedCount).toBe(1);
    const only = await list(client, "only");
    expect(only.sessions.map((session) => session.id)).toEqual([archived.id]);
    expect(typeof only.sessions[0]?.archivedAt).toBe("string");
    expect(only.sessions[0]?.archivedAt).toBe(response.result.archivedAt);
    expect(only.sessions[0]?.updatedAt).toBe(beforeRow!.updatedAt);
    expect(only.archivedCount).toBeUndefined();
    expect(f.listChanged).toHaveBeenCalled();

    // The canonical file, its bytes and its revision fields are untouched, and
    // archiving a cold session never starts a runtime for it.
    expect(await readFile(archived.file, "utf8")).toBe(before);
    const row = (await list(client, "exclude")).sessions.find((session) => session.id === visible.id);
    expect(row).toBeDefined();
    expect(f.runtimeFactory.mock.calls.length).toBe(factoryCallsBeforeArchive);
    return {
      archivedAt: response.result.archivedAt,
      archivedCount: excluded.archivedCount,
      canonicalBytes: before.length,
      updatedAtUnchanged: only.sessions[0]?.updatedAt === beforeRow!.updatedAt,
      runtimeStartsDuringArchive: f.runtimeFactory.mock.calls.length - factoryCallsBeforeArchive,
    };
  });

  archiveCase("keeps one receipt, one timestamp and one archived row for a replayed command", async () => {
    const f = await fixture();
    const client = await f.connect();
    const session = await f.coldSession("replay");
    const first = await client.request("archive-first", "session.archive.set", {
      commandId: "archive-command-replay", sessionId: session.id, archived: true,
    });
    const second = await client.request("archive-second", "session.archive.set", {
      commandId: "archive-command-replay", sessionId: session.id, archived: true,
    });
    expect(second.ok).toBe(true);
    expect(second.result).toEqual(first.result);
    const only = await list(client, "only");
    expect(only.sessions).toHaveLength(1);
    expect(only.sessions[0]?.archivedAt).toBe(first.result.archivedAt);

    // A distinct command ID that repeats the same state is idempotent too.
    const third = await client.request("archive-third", "session.archive.set", {
      commandId: "archive-command-replay-again", sessionId: session.id, archived: true,
    });
    expect(third.result).toEqual(first.result);
    expect((await list(client, "only")).sessions).toHaveLength(1);
    return {
      archivedAt: first.result.archivedAt,
      archivedRows: (await list(client, "only")).sessions.length,
    };
  });

  archiveCase("answers an unchanged projection token without rows and re-reads after the projection moves", async () => {
    const f = await fixture();
    const client = await f.connect();
    const phone = await f.connect();
    const session = await f.rawSession("revision", "revision-session");
    const other = await f.rawSession("revision-other", "revision-other-session");
    const third = await f.rawSession("revision-third", "revision-third-session");
    const first = await list(client, "exclude");
    expect(first.sessions.map((row) => row.id)).toEqual(expect.arrayContaining([session.id, other.id, third.id]));
    const token = first.projectionToken;
    expect(token).toContain(":");

    // An equal token is a complete revalidation of the client's rows, so the
    // answer carries neither rows nor a count.
    const unchanged = await list(client, "exclude", { projectionToken: token });
    expect(unchanged).toMatchObject({ notModified: true, projectionToken: token, sessions: [] });
    expect(unchanged.listRevision).toBe(first.listRevision);
    expect(unchanged.nextCursor).toBeUndefined();
    expect(unchanged.archivedCount).toBeUndefined();

    // A cold row's attention moves `catalogProjectionGeneration` only: the
    // structural revision is unchanged, so a token that covered membership
    // alone would falsely revalidate rows this client no longer holds.
    const attention = await phone.request(`attention-${session.id}`, "session.attention.set", {
      commandId: "revision-attention-command", sessionId: session.id, unread: true,
    });
    expect(attention.ok, JSON.stringify(attention)).toBe(true);
    const afterAttention = await list(client, "exclude", { projectionToken: token });
    expect(afterAttention.notModified).toBeUndefined();
    expect(afterAttention.listRevision).toBe(first.listRevision);
    expect(afterAttention.projectionToken).not.toBe(token);
    expect(afterAttention.sessions.find((row) => row.id === session.id)?.isUnread).toBe(true);

    // A client holding a superseded token must still receive the rows.
    const attentionToken = afterAttention.projectionToken;
    await openSession(client, session.id);
    await archiveSession(client, session.id, "revision-archive-command");
    const afterArchive = await list(client, "exclude", { projectionToken: attentionToken });
    expect(afterArchive.notModified).toBeUndefined();
    expect(afterArchive.sessions.map((row) => row.id)).not.toContain(session.id);
    const archivedToken = afterArchive.projectionToken;
    const revalidated = await list(client, "exclude", { projectionToken: archivedToken });
    expect(revalidated).toMatchObject({ notModified: true, projectionToken: archivedToken });

    // The conditional answer belongs to the first page only: a cursored page is
    // already bound to the projection its lease admitted.
    const paged = await list(client, "exclude", { limit: 1 });
    expect(paged.nextCursor).toBeDefined();
    const continued = await client.request("revision-cursor", "session.list", {
      scope: "user", archived: "exclude", limit: 1, cursor: paged.nextCursor, projectionToken: paged.projectionToken,
    });
    expect(continued.ok, JSON.stringify(continued)).toBe(true);
    const continuedResult = continued.result as { sessions: unknown[]; notModified?: boolean };
    expect(continuedResult.notModified).toBeUndefined();
    expect(continuedResult.sessions).toHaveLength(1);

    // An empty token is a client error, never a silent full read.
    const malformed = await client.request("revision-malformed", "session.list", {
      scope: "user", archived: "exclude", projectionToken: "",
    });
    expect(malformed).toMatchObject({ ok: false, error: { code: "invalid_request" } });

    // A restart starts a new runtime epoch while every revision begins again at
    // zero, so a token retained across it can never revalidate those rows.
    await f.restart();
    const replacement = await f.connect();
    const restarted = await list(replacement, "exclude", { projectionToken: archivedToken });
    expect(restarted.notModified).toBeUndefined();
    expect(restarted.sessions.length).toBeGreaterThan(0);
    return {
      token,
      attentionToken,
      archivedToken,
      afterAttentionRevision: afterAttention.listRevision,
      firstRevision: first.listRevision,
      restartedToken: restarted.projectionToken,
      continuedRowCount: continuedResult.sessions.length,
      malformedTokenCode: (malformed as { error: { code: string } }).error.code,
    };
  });

  archiveCase("moves the projection token when an acknowledged recovery clears a cold row's marker", async () => {
    const f = await fixture();
    const session = await f.coldSession("recovered-automation");
    // A recovered automation run's marker is restored at startup, and a row
    // with no live summary and no slot reads its phase from that set alone.
    const { RunMarkerStore } = await import("../sessions/run-markers.js");
    const operationId = "automation:10000000-0000-4000-8000-0000000000a9";
    await new RunMarkerStore(f.root).mark(session.id, operationId);
    const restarted = await f.restart();
    const client = await f.connect();
    const first = await list(client, "exclude");
    const row = first.sessions.find((candidate) => candidate.id === session.id);
    expect(row?.phase).toBe("interrupted");
    const token = first.projectionToken;
    expect((await list(client, "exclude", { projectionToken: token })).notModified).toBe(true);

    // The user acknowledges the recovery. Nothing structural moves: the row
    // changes phase, which only a token covering the whole row overlay can
    // carry, so an owner naming the old token must be answered with rows.
    const listChangesBefore = f.listChanged.mock.calls.length;
    await restarted.registry.clearAutomationMarker(session.id, operationId);
    expect(f.listChanged.mock.calls.length).toBeGreaterThan(listChangesBefore);
    const after = await list(client, "exclude", { projectionToken: token });
    expect(after.notModified).toBeUndefined();
    expect(after.sessions.find((candidate) => candidate.id === session.id)?.phase).toBe("idle");
    expect(after.projectionToken).not.toBe(token);
    // The row it now serves revalidates in turn.
    expect((await list(client, "exclude", { projectionToken: after.projectionToken })).notModified).toBe(true);
    return {
      phaseBefore: row?.phase,
      phaseAfter: after.sessions.find((candidate) => candidate.id === session.id)?.phase,
      tokenMoved: after.projectionToken !== token,
      listChanges: f.listChanged.mock.calls.length - listChangesBefore,
    };
  });

  archiveCase("binds a list cursor to its archive filter and orders the archived list newest first", async () => {
    const f = await fixture();
    const client = await f.connect();
    const older = await f.coldSession("cursor-archived-older");
    const visible = await f.coldSession("cursor-visible");
    const visibleOther = await f.coldSession("cursor-visible-other");
    const archive = (id: string, commandId: string) => client.request(commandId, "session.archive.set", {
      commandId, sessionId: id, archived: true,
    });
    const firstArchived = await archive(older.id, "archive-command-cursor-older");
    expect(firstArchived.ok).toBe(true);
    // Archive timestamps are the ordering source, so the two commits must not
    // share one millisecond.
    await new Promise((resolve) => setTimeout(resolve, 5));
    const newer = await f.coldSession("cursor-archived-newer");
    const secondArchived = await archive(newer.id, "archive-command-cursor-newer");
    expect(secondArchived.ok).toBe(true);
    expect((await list(client, "only")).sessions.map((row) => row.id)).toEqual([newer.id, older.id]);

    const received: string[] = [];
    let page = await list(client, "exclude", { limit: 1 });
    expect(page.archivedCount).toBe(2);
    received.push(...page.sessions.map((row) => row.id));
    while (page.nextCursor) {
      const continued = await client.request(`cursor-continue-${received.length}`, "session.list", {
        scope: "user", archived: "exclude", limit: 1, cursor: page.nextCursor,
      });
      expect(continued.ok).toBe(true);
      expect(continued.result.archivedCount).toBeUndefined();
      received.push(...continued.result.sessions.map((session: { id: string }) => session.id));
      page = continued.result;
    }
    expect(received).toHaveLength(2);
    expect([...received].sort()).toEqual([visible.id, visibleOther.id].sort());
    expect(new Set(received).size).toBe(received.length);
    // The cursor belongs to the exclude traversal: an `only` request cannot
    // continue it and receive the other projection.
    const excludeCursor = (await list(client, "exclude", { limit: 1 })).nextCursor;
    expect(excludeCursor).toBeDefined();
    const mismatched = await client.request("cursor-mismatch", "session.list", {
      scope: "user", archived: "only", limit: 1, cursor: excludeCursor,
    });
    expect(mismatched).toMatchObject({ ok: false, error: { code: "invalid_request" } });
    return {
      archivedOnlyOrder: [newer.id, older.id],
      excludeTraversal: received,
      mismatchedFilterRejected: mismatched.error.code,
    };
  });

  archiveCase("logs the exact operation and age for attention-pending RPC refusals", async () => {
    const f = await fixture();
    const client = await f.connect();
    const session = await f.coldSession("attention-pending-log");
    await openSession(client, session.id);
    const slot = await f.current().registry.acquire(session.id);
    const completion = {
      id: "synthetic-completion-id",
      completedAt: new Date(Date.now() - 2_500).toISOString(),
      operationId: "synthetic-pending-operation",
    };
    const barrier = Promise.reject(new Error("injected pending-attention failure"));
    void barrier.catch(() => {});
    const internals = slot as unknown as {
      attentionBarrier: Promise<void> | undefined;
      pendingAssistantCompletion: typeof completion | undefined;
    };
    const previousBarrier = internals.attentionBarrier;
    const previousCompletion = internals.pendingAssistantCompletion;
    internals.attentionBarrier = barrier;
    internals.pendingAssistantCompletion = completion;
    try {
      const response = await client.request("attention-pending-rpc", "session.prompt", {
        commandId: "attention-pending-command",
        sessionId: session.id,
        text: "must be held behind pending attention",
      });
      expect(response).toMatchObject({
        ok: false,
        error: {
          code: "busy",
          details: { reason: "attention-pending", operationId: "synthetic-pending-operation", ageMs: expect.any(Number) },
        },
      });
      await waitFor(() => f.logs.some(({ metadata }) => metadata.event === "rpc.error"
        && metadata.method === "session.prompt" && metadata.reason === "attention-pending"),
      "the attention-pending RPC error log");
      const log = f.logs.find(({ metadata }) => metadata.event === "rpc.error"
        && metadata.method === "session.prompt" && metadata.reason === "attention-pending");
      expect(log?.metadata).toMatchObject({
        code: "busy",
        reason: "attention-pending",
        operationId: "synthetic-pending-operation",
        ageMs: expect.any(Number),
      });
      expect(log?.metadata.ageMs).toBeGreaterThanOrEqual(2_500);
      return { reason: log?.metadata.reason, operationId: log?.metadata.operationId, ageMs: log?.metadata.ageMs };
    } finally {
      internals.attentionBarrier = previousBarrier;
      internals.pendingAssistantCompletion = previousCompletion;
    }
  });

  archiveCase("rejects archiving a session that is running or working through detached subagents", async () => {
    const f = await fixture();
    const client = await f.connect();
    const session = await f.coldSession("busy");
    let release!: () => void;
    const barrier = new Promise<void>((resolve) => { release = resolve; });
    f.faux.setResponses([async () => { await barrier; return fauxAssistantMessage("finished"); }]);
    const opened = await client.request("busy-open", "session.open", { sessionId: session.id });
    expect(opened.ok, JSON.stringify(opened)).toBe(true);
    await client.request("busy-sync", "session.sync", { sessionId: session.id, syncToken: opened.result.syncToken });
    const prompt = await client.request("busy-prompt", "session.prompt", {
      commandId: "busy-prompt-command", sessionId: session.id, text: "stay running",
    });
    expect(prompt.ok, JSON.stringify(prompt)).toBe(true);
    await waitFor(async () => (await list(client, "exclude")).sessions.some((row) => row.id === session.id && row.phase === "running"), "running phase");
    const running = await client.request("busy-archive", "session.archive.set", {
      commandId: "busy-archive-command", sessionId: session.id, archived: true,
    });
    expect(running).toMatchObject({ ok: false, error: { code: "busy" } });
    release();
    await waitFor(async () => (await list(client, "exclude")).sessions.some((row) => row.id === session.id && row.phase === "idle"), "idle phase");

    // Detached subagent work is the third projection a user sees as active, and
    // no public fixture can produce it: only the pi-subagents async-artifact
    // protocol registers a detached run activity that outlives its parent turn.
    // The published projection is the exact input this guard reads, so it is
    // injected here; the real waiting-for-user projection has its own case.
    const internals = f.current().registry as unknown as { latestSummaries: Map<string, Record<string, unknown>> };
    const published = internals.latestSummaries.get(session.id);
    expect(published).toBeDefined();
    let subagentCode: string | undefined;
    try {
      internals.latestSummaries.set(session.id, { ...published!, foregroundPhase: undefined, waitingForUser: false, hasActiveSubagents: true });
      const subagents = await client.request("subagent-archive", "session.archive.set", {
        commandId: "subagent-archive-command", sessionId: session.id, archived: true,
      });
      expect(subagents).toMatchObject({ ok: false, error: { code: "busy" } });
      subagentCode = subagents.error.code;
    } finally {
      internals.latestSummaries.set(session.id, published!);
    }
    expect((await list(client, "exclude")).sessions.map((row) => row.id)).toContain(session.id);
    expect((await list(client, "only")).sessions).toHaveLength(0);
    return {
      running: running.error.code,
      hasActiveSubagents: subagentCode,
      archivedRowsAfterRejections: (await list(client, "only")).sessions.length,
    };
  });

  archiveCase("rejects archive promptly while a long session-lane request is in flight", async () => {
    // A branch summary or resource reload holds the session lane while the
    // published projection still reads idle. Archive admission must reject that
    // before it waits on the lane, or it would hold the Gateway-wide registry
    // mutex — and every cold open, create, delete and automation lease — for the
    // whole request.
    const f = await fixture({ extensions: [{ name: "hold.ts", source: holdCommandExtension }] });
    const client = await f.connect();
    const held = await f.coldSession("lane-holder");
    const unrelated = await f.coldSession("lane-bystander");
    await openSession(client, held.id);

    const holding = client.request("lane-hold-prompt", "session.prompt", {
      commandId: "lane-hold-prompt-command", sessionId: held.id, text: "/hold",
    });
    const registry = f.current().registry as unknown as { slots: Map<string, { isBusy: boolean }> };
    await waitFor(() => registry.slots.get(held.id)?.isBusy === true, "held session lane");
    // The projection still reads idle: that is exactly the window this guards.
    const projection = (await list(client, "exclude")).sessions.find((row) => row.id === held.id);
    expect(projection?.phase).toBe("idle");

    const archive = await client.request("lane-hold-archive", "session.archive.set", {
      commandId: "lane-hold-archive-command", sessionId: held.id, archived: true,
    });
    expect(archive).toMatchObject({ ok: false, error: { code: "busy" } });
    // The Gateway mutex was never held for the lane wait: an unrelated cold open
    // and list read both complete while the holder is still running.
    const bystander = await client.request("lane-bystander-open", "session.open", { sessionId: unrelated.id });
    expect(bystander.ok, JSON.stringify(bystander)).toBe(true);
    expect(await listedIds(client, "exclude")).toContain(unrelated.id);
    expect(registry.slots.get(held.id)?.isBusy).toBe(true);

    await writeFile(join(f.root, "hold-release"), "", "utf8");
    const released = await holding;
    expect(released.ok, JSON.stringify(released)).toBe(true);
    expect(await archivedRecord(f.root, held.id)).toBeUndefined();
    return {
      archiveError: archive.error.code,
      archiveRetryable: archive.error.retryable,
      projectionWhileHeld: projection?.phase,
      unrelatedOpenWhileHeld: bystander.ok,
    };
  });

  archiveCase("rejects an archive retryably when only another request's entry blocks it", async () => {
    // Nothing about this session is working: another request (a rename, an
    // attention toggle, a second device's archive) holds one session-scoped work
    // entry. That clears by itself, so the client may retry instead of being
    // told to stop a session that is not running.
    const f = await fixture();
    const client = await f.connect();
    const session = await f.coldSession("transient-blocker");
    await openSession(client, session.id);
    const work = (f.current().registry as unknown as {
      workRegistry: { begin(admission: { kind: string; method: string; sessionId: string; hostEpoch: string }): { settle(): void } };
    }).workRegistry.begin({
      kind: "rpc-mutation", method: "session.rename", sessionId: session.id, hostEpoch: "",
    });
    try {
      const archive = await client.request("transient-archive", "session.archive.set", {
        commandId: "transient-archive-command", sessionId: session.id, archived: true,
      });
      expect(archive).toMatchObject({ ok: false, error: { code: "busy", retryable: true } });
      expect(await archivedRecord(f.root, session.id)).toBeUndefined();
      expect(await listedIds(client, "exclude")).toContain(session.id);
    } finally {
      work.settle();
    }
    const retried = await archiveSession(client, session.id, "transient-retry-archive-command");
    return {
      retriedArchivedAt: retried.archivedAt,
      archivedRows: (await list(client, "only")).sessions.map((row) => row.id),
    };
  });

  archiveCase("keeps a session unarchived when an automation holds its lease", async () => {
    // The automation lease is retained for the whole scheduled run. Archive
    // admission must see that ownership as real activity rather than as another
    // request's transient entry.
    const f = await fixture();
    const client = await f.connect();
    const session = await f.coldSession("automation-lease");
    await openSession(client, session.id);
    const lease = await f.current().registry.acquireAutomationLease(session.id);
    try {
      const archive = await client.request("automation-lease-archive", "session.archive.set", {
        commandId: "automation-lease-archive-command", sessionId: session.id, archived: true,
      });
      expect(archive).toMatchObject({ ok: false, error: { code: "busy" } });
      expect(await archivedRecord(f.root, session.id)).toBeUndefined();
      expect(await listedIds(client, "exclude")).toContain(session.id);
      return { archiveError: archive.error.code, archiveRetryable: archive.error.retryable };
    } finally {
      lease.release();
    }
  });

  archiveCase("rejects archiving a session waiting for a real user interaction", async () => {
    const f = await fixture({ extensions: [{ name: "select-hold.ts", source: selectCommandExtension }] });
    const client = await f.connect();
    const session = await f.coldSession("waiting-interaction");
    await openSession(client, session.id);
    const command = client.request("waiting-command", "session.prompt", {
      commandId: "waiting-command-command", sessionId: session.id, text: "/select-hold",
    });
    await waitFor(async () => (await list(client, "exclude")).sessions.some(
      (row) => row.id === session.id && row.waitingForUser === true), "waiting for user");
    const projection = (await list(client, "exclude")).sessions.find((row) => row.id === session.id);
    // The pending interaction the user must answer is published on the opened
    // snapshot, which is the same projection a phone renders.
    const reopened = await client.request("waiting-reopen", "session.open", { sessionId: session.id });
    const pending = reopened.result.session.extensionPresentation.pendingInteractions[0] as {
      id: string; hostEpoch: string; presentationRevision: number; method: string;
    };
    expect(pending, "pending interaction").toBeDefined();

    const archive = await client.request("waiting-archive", "session.archive.set", {
      commandId: "waiting-archive-command", sessionId: session.id, archived: true,
    });
    expect(archive).toMatchObject({ ok: false, error: { code: "busy", retryable: false } });
    expect(await archivedRecord(f.root, session.id)).toBeUndefined();

    const answered = await client.request("waiting-respond", "extension.respond", {
      commandId: "waiting-respond-command",
      sessionId: session.id,
      interactionId: pending.id,
      hostEpoch: pending.hostEpoch,
      presentationRevision: pending.presentationRevision,
      value: "Keep",
    });
    expect(answered.ok, JSON.stringify(answered)).toBe(true);
    await waitFor(async () => !(await list(client, "exclude")).sessions.some(
      (row) => row.id === session.id && row.waitingForUser === true), "interaction settled");
    await command;

    const retried = await archiveSession(client, session.id, "waiting-retry-archive-command");
    expect(retried.archivedAt).toBeDefined();
    return {
      archiveError: archive.error.code,
      archiveRetryable: archive.error.retryable,
      waitingForUserProjection: projection?.waitingForUser,
      interactionMethod: pending.method,
      archivedAfterAnswer: (await list(client, "only")).sessions.map((row) => row.id),
    };
  });

  archiveCase("keeps the record of a session that started before startup recovery finished", async () => {
    // The Gateway serves before attention recovery completes, so a session can
    // be created and archived inside that window. Recovery prunes records with
    // no canonical owner, and a live session that has not reached disk yet is an
    // owner: its record must survive.
    let liveSessionId = "";
    const f = await fixture({
      duringStartupRecovery: async (registry, cwd) => {
        const slot = await registry.create(cwd);
        liveSessionId = slot.id;
        await registry.setArchived(slot.id, true);
      },
    });
    const client = await f.connect();
    expect(await archivedRecord(f.root, liveSessionId)).toBeDefined();
    expect(await listedIds(client, "only")).toEqual([liveSessionId]);
    expect(await listedIds(client, "exclude")).not.toContain(liveSessionId);
    return {
      liveSessionId,
      archivedRows: (await list(client, "only")).sessions.map((row) => row.archivedAt),
    };
  });

  archiveCase("keeps the record of a session archived while startup recovery was scanning", async () => {
    // Recovery already holds its retained set when a session is created and
    // archived, so the archive prune must read live ownership again on the lane
    // rather than reuse the set the attention prune above was given.
    let liveSessionId = "";
    let archiving: Promise<void> | undefined;
    const f = await fixture({
      duringStartupRecovery: async (registry, cwd) => {
        const attention = (registry as unknown as {
          attention: { prune(retainedSessionIds: ReadonlySet<string>): Promise<boolean> };
        }).attention;
        const durablePrune = attention.prune.bind(attention);
        let entered!: () => void;
        const inPrune = new Promise<void>((resolve) => { entered = resolve; });
        let release!: () => void;
        const barrier = new Promise<void>((resolve) => { release = resolve; });
        attention.prune = async (retained) => {
          entered();
          await barrier;
          return durablePrune(retained);
        };
        archiving = (async () => {
          await inPrune;
          const slot = await registry.create(cwd);
          liveSessionId = slot.id;
          await registry.setArchived(slot.id, true);
          release();
        })();
      },
    });
    const client = await f.connect();
    await archiving;
    expect(await archivedRecord(f.root, liveSessionId)).toBeDefined();
    expect(await listedIds(client, "only")).toEqual([liveSessionId]);
    expect(await listedIds(client, "exclude")).not.toContain(liveSessionId);
    return {
      liveSessionId,
      archivedRows: (await list(client, "only")).sessions.map((row) => row.archivedAt),
    };
  });

  archiveCase("unarchives a session while its run is still active", async () => {
    // Unarchiving is the recovery direction, so it never requires an idle
    // session: a client must be able to reverse a hidden row even if a run has
    // already started.
    const f = await fixture();
    const client = await f.connect();
    const session = await f.coldSession("unarchive-running");
    await openSession(client, session.id);
    let release!: () => void;
    const barrier = new Promise<void>((resolve) => { release = resolve; });
    f.faux.setResponses([async () => { await barrier; return fauxAssistantMessage("running"); }]);
    await archiveSession(client, session.id, "unarchive-running-archive-command");
    const prompt = await client.request("unarchive-running-prompt", "session.prompt", {
      commandId: "unarchive-running-prompt-command", sessionId: session.id, text: "run while I unarchive",
    });
    expect(prompt.ok, JSON.stringify(prompt)).toBe(true);
    await waitFor(async () => (await list(client, "exclude")).sessions.some(
      (row) => row.id === session.id && row.phase === "running"), "running phase");
    const unarchive = await client.request("unarchive-running-reset", "session.archive.set", {
      commandId: "unarchive-running-reset-command", sessionId: session.id, archived: false,
    });
    expect(unarchive.ok, JSON.stringify(unarchive)).toBe(true);
    release();
    return {
      runningPhase: (await list(client, "exclude")).sessions.find((row) => row.id === session.id)?.phase,
      unarchiveResult: unarchive.result,
      archivedRows: (await list(client, "only")).sessions.length,
    };
  });

  archiveCase("keeps archive state across a Gateway restart and an open", async () => {
    const f = await fixture();
    const first = await f.connect();
    const session = await f.coldSession("restart");
    const archived = await first.request("restart-archive", "session.archive.set", {
      commandId: "restart-archive-command", sessionId: session.id, archived: true,
    });
    expect(archived.ok).toBe(true);
    await f.restart();
    const second = await f.connect();
    expect((await list(second, "exclude")).sessions.map((row) => row.id)).not.toContain(session.id);
    const only = await list(second, "only");
    expect(only.sessions.map((row) => row.id)).toEqual([session.id]);
    expect(only.sessions[0]?.archivedAt).toBe(archived.result.archivedAt);

    const opened = await second.request("restart-open", "session.open", { sessionId: session.id });
    expect(opened.ok).toBe(true);
    await second.request("restart-sync", "session.sync", { sessionId: session.id, syncToken: opened.result.syncToken });
    expect((await list(second, "exclude")).sessions.map((row) => row.id)).not.toContain(session.id);
    expect((await list(second, "only")).sessions.map((row) => row.id)).toEqual([session.id]);
    return {
      archivedAt: archived.result.archivedAt,
      archivedRowsAfterRestart: (await list(second, "only")).sessions.map((row) => row.id),
      archivedRowsAfterOpen: (await list(second, "only")).sessions.map((row) => row.id),
    };
  });

  archiveCase("keeps a renamed session archived and forks an unarchived child", async () => {
    const f = await fixture();
    const client = await f.connect();
    const parent = await f.coldSession("fork-parent");
    await client.request("fork-archive", "session.archive.set", {
      commandId: "fork-archive-command", sessionId: parent.id, archived: true,
    });
    const renamed = await client.request("fork-rename", "session.rename", {
      commandId: "fork-rename-command", sessionId: parent.id, name: "Archived and renamed",
    });
    expect(renamed.ok).toBe(true);
    const only = await list(client, "only");
    expect(only.sessions.map((row) => row.id)).toEqual([parent.id]);

    const opened = await client.request("fork-open", "session.open", { sessionId: parent.id });
    await client.request("fork-sync", "session.sync", { sessionId: parent.id, syncToken: opened.result.syncToken });
    const entryId = (SessionManager.open(parent.file).getBranch().at(-1) as { id?: string } | undefined)?.id;
    expect(typeof entryId).toBe("string");
    // The fork runs through its real RPC, so the rebind hook and the archive
    // ownership under test are reached exactly as a client reaches them.
    const forked = await client.request("fork-request", "session.fork", {
      commandId: "fork-command", sessionId: parent.id, entryId: entryId!, position: "at",
    });
    expect(forked.ok, JSON.stringify(forked)).toBe(true);
    const childId = forked.result.sessionId as string;
    expect(childId).not.toBe(parent.id);

    const excluded = await list(client, "exclude");
    const child = excluded.sessions.find((row) => row.id === childId);
    expect(child).toBeDefined();
    expect(child?.archivedAt).toBeUndefined();
    expect((await list(client, "only")).sessions.map((row) => row.id)).toEqual([parent.id]);
    return {
      childId,
      childArchivedAt: child?.archivedAt ?? null,
      archivedRows: (await list(client, "only")).sessions.map((row) => row.id),
    };
  });

  archiveCase("rejects archiving a runtime-owned subagent session", async () => {
    const f = await fixture();
    const client = await f.connect();
    const parent = await f.coldSession("subagent-parent");
    const childDirectory = join(f.sessionDirectory, parent.id, "worker", "run-0");
    await mkdir(childDirectory, { recursive: true });
    const childId = "runtime-owned-subagent-child";
    await writeFile(join(childDirectory, "session.jsonl"), `${JSON.stringify({
      type: "session", version: 3, id: childId, timestamp: new Date().toISOString(), cwd: f.cwd,
    })}\n`);
    await f.settle();
    const rejected = await client.request("subagent-archive-request", "session.archive.set", {
      commandId: "subagent-archive-command", sessionId: childId, archived: true,
    });
    expect(rejected).toMatchObject({ ok: false, error: { code: "conflict" } });
    expect((await list(client, "only")).sessions).toHaveLength(0);
    return { code: rejected.error.code };
  });

  archiveCase("deletes an archived session and never resurrects its archive record", async () => {
    const f = await fixture();
    const client = await f.connect();
    const session = await f.coldSession("delete");
    await client.request("delete-archive", "session.archive.set", {
      commandId: "delete-archive-command", sessionId: session.id, archived: true,
    });
    expect((await list(client, "only")).sessions).toHaveLength(1);
    const deleted = await client.request("delete-session", "session.delete", {
      commandId: "delete-archived-session-command", sessionId: session.id,
    });
    expect(deleted.ok, JSON.stringify(deleted)).toBe(true);
    const store = JSON.parse(await readFile(join(f.root, "gateway", "session-archive.json"), "utf8")) as { sessions: Record<string, unknown> };
    expect(Object.keys(store.sessions)).toEqual([]);
    expect((await list(client, "only")).sessions).toHaveLength(0);
    expect((await list(client, "exclude")).archivedCount).toBe(0);

    // A re-created canonical file with the same identity is a new session, not a
    // resurrected archive record.
    await writeFile(session.file, `${JSON.stringify({
      type: "session", version: 3, id: session.id, timestamp: new Date().toISOString(), cwd: f.cwd,
    })}\n${JSON.stringify({
      type: "message", id: "recreated-entry", timestamp: Date.now(),
      message: { role: "assistant", content: [{ type: "text", text: "re-created" }] },
    })}\n`);
    await f.settle();
    const afterRecreate = await list(client, "exclude");
    expect(afterRecreate.sessions.map((row) => row.id)).toContain(session.id);
    expect(afterRecreate.archivedCount).toBe(0);
    expect((await list(client, "only")).sessions).toHaveLength(0);
    return {
      storeAfterDelete: Object.keys(store.sessions),
      recreatedSessionVisible: afterRecreate.sessions.some((row) => row.id === session.id),
      archivedCountAfterRecreate: afterRecreate.archivedCount,
    };
  });

  archiveCase("archives a live idle session and unarchives it again", async () => {
    const f = await fixture();
    const client = await f.connect();
    const slot = await f.current().registry.create(f.cwd);
    // A brand-new session has no canonical file yet; it is still an admitted
    // dashboard row and must be archivable while it is idle.
    const response = await client.request("live-archive", "session.archive.set", {
      commandId: "live-archive-command", sessionId: slot.id, archived: true,
    });
    expect(response.ok, JSON.stringify(response)).toBe(true);
    expect(slot.persistedSessionFile).toBeUndefined();
    expect((await list(client, "only")).sessions.map((row) => row.id)).toEqual([slot.id]);

    const restored = await client.request("live-unarchive", "session.archive.set", {
      commandId: "live-unarchive-command", sessionId: slot.id, archived: false,
    });
    expect(restored.result).toEqual({ archived: false });
    expect((await list(client, "only")).sessions).toHaveLength(0);
    expect((await list(client, "exclude")).sessions.map((row) => row.id)).toEqual([slot.id]);
    return {
      liveOnlyArchivedAt: response.result.archivedAt,
      unarchiveResult: restored.result,
      runtimeStarts: f.runtimeFactory.mock.calls.length,
    };
  });

  archiveCase("carries archive state on the opened snapshot and republishes it on every change", async () => {
    const f = await fixture();
    const client = await f.connect();
    const session = await f.coldSession("snapshot-archive");
    // Archive before the session is ever opened: the projection belongs to the
    // session, not to a subscription, so the first authoritative snapshot for
    // an archived session already carries it.
    const archivedWhileCold = await archiveSession(client, session.id, "snapshot-cold-archive-command");
    await openSession(client, session.id);
    const opened = client.frames.find((frame) => frame.id === `open-${session.id}`);
    expect(opened.result.session.archivedAt).toBe(archivedWhileCold.archivedAt);

    // Unarchiving republishes the snapshot of the live subscription, so a chat
    // that is already open sees the row leave its archived state.
    const beforeUnarchive = snapshotFrames(client, session.id).length;
    const unarchive = await client.request("snapshot-unarchive", "session.archive.set", {
      commandId: "snapshot-unarchive-command", sessionId: session.id, archived: false,
    });
    expect(unarchive.ok, JSON.stringify(unarchive)).toBe(true);
    await waitFor(() => snapshotFrames(client, session.id).length > beforeUnarchive
      && latestSnapshot(client, session.id)?.archivedAt === undefined, "unarchive republish");

    // Archiving a live idle session republishes it the same way.
    const archivedWhileLive = await archiveSession(client, session.id, "snapshot-live-archive-command");
    await waitFor(() => latestSnapshot(client, session.id)?.archivedAt !== undefined, "archive republish");
    expect(latestSnapshot(client, session.id)?.archivedAt).toBe(archivedWhileLive.archivedAt);

    // The prompt that admits a run clears the record, and the snapshot the
    // admission publishes no longer reports the session as archived.
    f.faux.setResponses([fauxAssistantMessage("awake")]);
    const prompt = await client.request("snapshot-prompt", "session.prompt", {
      commandId: "snapshot-prompt-command", sessionId: session.id, text: "come back",
    });
    expect(prompt.ok, JSON.stringify(prompt)).toBe(true);
    expect(await archivedRecord(f.root, session.id)).toBeUndefined();
    await waitFor(() => latestSnapshot(client, session.id)?.archivedAt === undefined, "admission republish");
    return {
      archivedAtOnOpen: opened.result.session.archivedAt,
      snapshotWhileArchived: archivedWhileLive.archivedAt,
      snapshotAfterUnarchive: latestSnapshot(client, session.id)?.archivedAt ?? null,
      snapshotWhileRunning: latestSnapshot(client, session.id)?.archivedAt ?? null,
    };
  });

  archiveCase("clears archive state before a prompt is admitted and announces it to every client", async () => {
    const f = await fixture();
    const first = await f.connect();
    const second = await f.connect();
    const session = await f.coldSession("prompt-unarchive");
    await openSession(first, session.id);
    await archiveSession(first, session.id, "prompt-archive-command");
    expect(await listedIds(first, "exclude")).not.toContain(session.id);
    const announcementAt = { first: listChangedFrames(first), second: listChangedFrames(second) };
    f.faux.setResponses([fauxAssistantMessage("awake")]);

    const prompt = await first.request("prompt-unarchive-request", "session.prompt", {
      commandId: "prompt-unarchive-command", sessionId: session.id, text: "come back",
    });
    expect(prompt.ok, JSON.stringify(prompt)).toBe(true);
    // The admission response is the exact boundary: the durable record must
    // already be gone, before the run's first event can reach any client.
    expect(await archivedRecord(f.root, session.id)).toBeUndefined();

    await waitFor(async () => (await listedIds(first, "exclude")).includes(session.id), "visible on the prompting client");
    await waitFor(async () => (await listedIds(second, "exclude")).includes(session.id), "visible on the observing client");
    await waitFor(() => listChangedFrames(first) > announcementAt.first, "first client list change");
    await waitFor(() => listChangedFrames(second) > announcementAt.second, "second client list change");
    expect(f.archiveDiagnostic).toHaveBeenCalledWith({ outcome: "auto-unarchived", trigger: "admission" });
    await waitFor(async () => (await list(first, "exclude")).sessions.some(
      (row) => row.id === session.id && row.phase === "idle"), "settled");
    return {
      canonicalRecord: (await archivedRecord(f.root, session.id)) ?? null,
      promptingClientListChanged: listChangedFrames(first) - announcementAt.first,
      observingClientListChanged: listChangedFrames(second) - announcementAt.second,
    };
  });

  archiveCase("clears archive state when Bash is admitted", async () => {
    const f = await fixture();
    const client = await f.connect();
    const session = await f.coldSession("bash-unarchive");
    await openSession(client, session.id);
    await archiveSession(client, session.id, "bash-archive-command");

    const bash = await client.request("bash-unarchive-request", "session.bash", {
      commandId: "bash-unarchive-command", sessionId: session.id, command: "echo archive-bash", excludeFromContext: true,
    });
    expect(bash.ok, JSON.stringify(bash)).toBe(true);
    expect(await archivedRecord(f.root, session.id)).toBeUndefined();
    expect(await listedIds(client, "exclude")).toContain(session.id);
    expect(f.archiveDiagnostic).toHaveBeenCalledWith({ outcome: "auto-unarchived", trigger: "admission" });
    return {
      canonicalRecord: (await archivedRecord(f.root, session.id)) ?? null,
      archivedRows: (await list(client, "only")).sessions.length,
    };
  });

  archiveCase("clears archive state when a manual compaction is admitted", async () => {
    // A tiny compaction budget gives the session history that manual compaction
    // can actually summarize, so the admitted work is observable end to end.
    const f = await fixture({ settings: { compaction: { enabled: true, reserveTokens: 1_024, keepRecentTokens: 0 } } });
    const client = await f.connect();
    const session = await f.coldSession("compaction-unarchive");
    await openSession(client, session.id);
    f.faux.setResponses([
      fauxAssistantMessage(`History for compaction. ${"detail ".repeat(200)}`),
      // Compaction may summarize the recent turn prefix before the main summary.
      fauxAssistantMessage("turn prefix summary"),
      fauxAssistantMessage("compacted summary"),
      fauxAssistantMessage("compacted summary"),
    ]);
    const primed = await client.request("compaction-prime", "session.prompt", {
      commandId: "compaction-prime-command", sessionId: session.id, text: `Prime the history. ${"context ".repeat(200)}`,
    });
    expect(primed.ok, JSON.stringify(primed)).toBe(true);
    await waitFor(async () => (await list(client, "exclude")).sessions.some(
      (row) => row.id === session.id && row.phase === "idle"), "primed history settled");
    await archiveSession(client, session.id, "compaction-archive-command");

    const compaction = await client.request("compaction-unarchive-request", "session.compact", {
      commandId: "compaction-unarchive-command", sessionId: session.id,
    });
    expect(compaction.ok, JSON.stringify(compaction)).toBe(true);
    expect(compaction.result).toMatchObject({ compacted: true });
    // Either compaction path (immediate or queued behind a run) is admitted
    // through the same boundary, so the record must be gone once it returns.
    expect(await archivedRecord(f.root, session.id)).toBeUndefined();
    expect(await listedIds(client, "exclude")).toContain(session.id);
    expect(f.archiveDiagnostic).toHaveBeenCalledWith({ outcome: "auto-unarchived", trigger: "admission" });
    return {
      queued: compaction.result.queued,
      canonicalRecord: (await archivedRecord(f.root, session.id)) ?? null,
    };
  });

  archiveCase("keeps a refused manual compaction archived", async () => {
    // Manual compaction is refused while another owner is producing a file, and
    // an export in flight never clears archive state. That refusal is the exact
    // boundary the run-admission clear must come after.
    const f = await fixture();
    const client = await f.connect();
    // The export owner is initialized by the Gateway's storage-warming stage.
    await f.current().registry.initializeBlobStorage();
    const session = await f.coldSession("refused-compaction");
    await openSession(client, session.id);
    await archiveSession(client, session.id, "refused-compaction-archive");

    const exports = (f.current().registry as unknown as {
      exports: { withFileProductionAdmission<T>(operation: () => Promise<T>): Promise<T> };
    }).exports;
    const durableAdmission = exports.withFileProductionAdmission.bind(exports);
    let producing = false;
    let releaseExport!: () => void;
    const exportBarrier = new Promise<void>((resolve) => { releaseExport = resolve; });
    exports.withFileProductionAdmission = async (operation) => {
      producing = true;
      await exportBarrier;
      return durableAdmission(operation);
    };
    const exporting = client.request("refused-compaction-export", "session.export", { sessionId: session.id, format: "html" });
    await waitFor(() => producing, "export in flight");

    const refused = await client.request("refused-compaction-request", "session.compact", {
      commandId: "refused-compaction-command", sessionId: session.id,
    });
    expect(refused).toMatchObject({ ok: false, error: { code: "busy" } });
    // The refusal happened before run ownership, so nothing cleared the record.
    expect(await archivedRecord(f.root, session.id)).toBeDefined();
    expect(await listedIds(client, "only")).toEqual([session.id]);
    expect(await listedIds(client, "exclude")).not.toContain(session.id);
    expect(f.archiveDiagnostic).not.toHaveBeenCalledWith({ outcome: "auto-unarchived", trigger: "admission" });

    releaseExport();
    const exported = await exporting;
    expect(exported.ok, JSON.stringify(exported)).toBe(true);
    exports.withFileProductionAdmission = durableAdmission;
    return {
      compactionError: refused.error.code,
      retainedRecord: (await archivedRecord(f.root, session.id)) ?? null,
      exportBlobId: exported.result.blobId,
    };
  });

  archiveCase("clears archive state for an automation-owned prompt on an existing session", async () => {
    const f = await fixture();
    const client = await f.connect();
    const session = await f.coldSession("automation-unarchive");
    await openSession(client, session.id);
    await archiveSession(client, session.id, "automation-archive-command");
    f.faux.setResponses([fauxAssistantMessage("scheduled response")]);

    // Mirrors AutomationExecutor: take the automation lease for a persisted
    // session, then admit the prompt with its exact operation ownership.
    const lease = await f.current().registry.acquireAutomationLease(session.id);
    const admission = await lease.slot.prompt(
      "scheduled run",
      [],
      undefined,
      { text: "scheduled run", attachmentEnvelope: "", attachmentCount: 0 },
      undefined,
      {
        operationId: "automation:fixture-operation",
        origin: { kind: "gateway", ownerId: "fixture-automation", title: "Automation", confidence: "boundary" },
        onTerminal: () => {},
      },
    );
    lease.release();
    expect(admission.operationId).toBe("automation:fixture-operation");
    expect(await archivedRecord(f.root, session.id)).toBeUndefined();
    await waitFor(async () => (await listedIds(client, "exclude")).includes(session.id), "automation target visible");
    await waitFor(async () => !(await f.current().registry.acquire(session.id)).isBusy, "automation run settled");
    return {
      operationId: admission.operationId,
      canonicalRecord: (await archivedRecord(f.root, session.id)) ?? null,
    };
  });

  archiveCase("treats a queued prompt as busy for archive admission", async () => {
    const f = await fixture();
    const client = await f.connect();
    const session = await f.coldSession("queued-unarchive");
    await openSession(client, session.id);
    let release!: () => void;
    const barrier = new Promise<void>((resolve) => { release = resolve; });
    f.faux.setResponses([async () => { await barrier; return fauxAssistantMessage("finished"); }]);

    const running = await client.request("queued-running-prompt", "session.prompt", {
      commandId: "queued-running-prompt-command", sessionId: session.id, text: "stay running",
    });
    expect(running.ok, JSON.stringify(running)).toBe(true);
    await waitFor(async () => (await list(client, "exclude")).sessions.some(
      (row) => row.id === session.id && row.phase === "running"), "running phase");
    const queued = await client.request("queued-follow-up", "session.prompt", {
      commandId: "queued-follow-up-command", sessionId: session.id, text: "queued follow-up", behavior: "followUp",
    });
    expect(queued.ok, JSON.stringify(queued)).toBe(true);

    const archive = await client.request("queued-archive", "session.archive.set", {
      commandId: "queued-archive-command", sessionId: session.id, archived: true,
    });
    expect(archive).toMatchObject({ ok: false, error: { code: "busy" } });
    release();
    await waitFor(async () => (await list(client, "exclude")).sessions.some(
      (row) => row.id === session.id && row.phase === "idle"), "settled");
    expect(await archivedRecord(f.root, session.id)).toBeUndefined();
    return {
      archiveError: archive.error.code,
      queuedOperationId: queued.result.operationId,
    };
  });

  archiveCase("clears archive state when an extension starts a turn without Gateway admission", async () => {
    // An extension-owned trigger (a scheduled wake) starts the turn inside Pi,
    // so no Gateway run admission can see it. The active projection is the only
    // boundary that can restore visibility, and it must do so immediately.
    const f = await fixture({ extensions: [{ name: "wake.ts", source: wakeExtension }] });
    const client = await f.connect();
    const session = await f.coldSession("backstop-unarchive");
    await openSession(client, session.id);
    await archiveSession(client, session.id, "backstop-archive-command");
    expect(await listedIds(client, "exclude")).not.toContain(session.id);
    let release!: () => void;
    const barrier = new Promise<void>((resolve) => { release = resolve; });
    f.faux.setResponses([async () => { await barrier; return fauxAssistantMessage("woke by itself"); }]);
    try {
      await writeFile(join(f.root, "wake-trigger"), "", "utf8");
      await waitFor(async () => (await list(client, "exclude")).sessions.some(
        (row) => row.id === session.id && row.phase === "running"), "externally started run");
      // The row is visible from the moment the active projection is published,
      // and the durable record is cleared behind it rather than only hidden in
      // memory.
      const visibleWhileRunning = (await list(client, "exclude")).sessions.find((row) => row.id === session.id);
      expect(visibleWhileRunning?.phase).toBe("running");
      expect(visibleWhileRunning?.archivedAt).toBeUndefined();
      await waitFor(() => f.archiveDiagnostic.mock.calls.some(
        (call) => JSON.stringify(call[0]) === JSON.stringify({ outcome: "auto-unarchived", trigger: "backstop" })), "backstop diagnostic");
      expect(await archivedRecord(f.root, session.id)).toBeUndefined();
      release();
      await waitFor(async () => (await list(client, "exclude")).sessions.some(
        (row) => row.id === session.id && row.phase === "idle"), "settled");
      return {
        visibleWhileRunning: visibleWhileRunning?.phase,
        canonicalRecord: (await archivedRecord(f.root, session.id)) ?? null,
        diagnostics: f.archiveDiagnostic.mock.calls.map((call) => call[0]),
      };
    } finally {
      release();
    }
  });

  archiveCase("restores visibility and retries the record when the backstop write fails", async () => {
    // A run Pi starts on its own cannot be rejected, so visibility is restored
    // in memory first. The device that archived the session must still be told:
    // it is the one hiding the row, and it learns about the change from the
    // membership change rather than from the durable write.
    const f = await fixture({ extensions: [{ name: "wake.ts", source: wakeExtension }] });
    const client = await f.connect();
    const session = await f.coldSession("backstop-write-failure");
    await openSession(client, session.id);
    await archiveSession(client, session.id, "backstop-failure-archive-command");
    const listChangesBefore = listChangedFrames(client);
    const restoreRemovals = failArchiveRemovals(f.current().registry);
    let release!: () => void;
    const barrier = new Promise<void>((resolve) => { release = resolve; });
    f.faux.setResponses([async () => { await barrier; return fauxAssistantMessage("woke by itself"); }]);
    try {
      await writeFile(join(f.root, "wake-trigger"), "", "utf8");
      await waitFor(() => listChangedFrames(client) > listChangesBefore, "restoration membership change");
      const visible = (await list(client, "exclude")).sessions.find((row) => row.id === session.id);
      expect(visible?.phase).toBe("running");
      expect(visible?.archivedAt).toBeUndefined();
      expect(f.archiveDiagnostic).toHaveBeenCalledWith({ outcome: "failure", stage: "auto-unarchive" });
      // Fail closed on the durable half: the record survives a failed write.
      expect(await archivedRecord(f.root, session.id)).toBeDefined();

      // The next published summary retries the exact record once the store
      // recovers, so the retry is not lost.
      restoreRemovals();
      release();
      await waitFor(async () => (await archivedRecord(f.root, session.id)) === undefined, "record cleared on retry");
      await waitFor(async () => (await list(client, "only")).sessions.length === 0, "archived projection empty");
      return {
        listChanges: listChangedFrames(client) - listChangesBefore,
        visibleWhileRunning: visible?.phase,
        canonicalRecordAfterRetry: (await archivedRecord(f.root, session.id)) ?? null,
        archivedRowsAfterRetry: (await list(client, "only")).sessions.length,
      };
    } finally {
      restoreRemovals();
      release();
    }
  });

  archiveCase("settles a pending backstop write before disposal resolves", async () => {
    // The backstop clears records fire-and-forget while sessions publish, so its
    // write can still be in flight when the owning registry reports disposal.
    // Whoever released the Gateway state directory — a shutdown, a reinstall, a
    // test fixture — must be able to assume this owner is done writing.
    const f = await fixture({ extensions: [{ name: "wake.ts", source: wakeExtension }] });
    const client = await f.connect();
    const session = await f.coldSession("dispose-drain");
    await openSession(client, session.id);
    await archiveSession(client, session.id, "dispose-drain-archive-command");
    const registry = f.current().registry;
    const store = (registry as unknown as { archive: { remove(sessionId: string): Promise<boolean> } }).archive;
    const durable = store.remove.bind(store);
    let release!: () => void;
    const barrier = new Promise<void>((resolve) => { release = resolve; });
    let entered = false;
    let settled = false;
    store.remove = async (sessionId: string) => {
      entered = true;
      await barrier;
      const removed = await durable(sessionId);
      settled = true;
      return removed;
    };
    let resume!: () => void;
    const runBarrier = new Promise<void>((resolve) => { resume = resolve; });
    f.faux.setResponses([async () => { await runBarrier; return fauxAssistantMessage("woke by itself"); }]);
    await writeFile(join(f.root, "wake-trigger"), "", "utf8");
    await waitFor(() => entered, "backstop write in flight");
    // The run may finish; only the blocked clear must still be in flight.
    resume();

    const disposing = registry.dispose();
    const outcome = await Promise.race([
      disposing.then(() => "disposed" as const),
      new Promise<"waiting">((resolve) => { setTimeout(() => resolve("waiting"), 250); }),
    ]);
    // Disposal must not report itself done while the write it owns is in flight.
    expect(outcome).toBe("waiting");
    release();
    await disposing;
    expect(settled).toBe(true);
    expect(await archivedRecord(f.root, session.id)).toBeUndefined();
    return {
      outcomeWhileWriteBlocked: outcome,
      settledBeforeDisposeResolved: settled,
      recordAfterDispose: (await archivedRecord(f.root, session.id)) ?? null,
      pendingAttempts: (registry as unknown as { archiveRestorationAttempts: Map<string, unknown> })
        .archiveRestorationAttempts.size,
    };
  });

  archiveCase("re-archives a pending restoration with its own timestamp", async () => {
    const f = await fixture({ extensions: [{ name: "wake.ts", source: wakeExtension }] });
    const client = await f.connect();
    const session = await f.coldSession("pending-restoration");
    await openSession(client, session.id);
    const first = await archiveSession(client, session.id, "pending-archive-command");
    const restoreRemovals = failArchiveRemovals(f.current().registry);
    let release!: () => void;
    const barrier = new Promise<void>((resolve) => { release = resolve; });
    f.faux.setResponses([async () => { await barrier; return fauxAssistantMessage("woke by itself"); }]);
    try {
      await writeFile(join(f.root, "wake-trigger"), "", "utf8");
      await waitFor(async () => (await list(client, "exclude")).sessions.some(
        (row) => row.id === session.id && row.phase === "running"), "externally started run");
      release();
      await waitFor(() => !(f.current().registry as unknown as { slots: Map<string, { isBusy: boolean }> })
        .slots.get(session.id)?.isBusy, "run settled");
      // The durable clear still failed, so the stale record is what a re-archive
      // would otherwise resurrect.
      expect(await archivedRecord(f.root, session.id)).toBeDefined();
      restoreRemovals();
      // Archive timestamps are the container's ordering source, so the second
      // archive must not reuse the first one's position.
      await new Promise((resolve) => setTimeout(resolve, 5));
      const second = await archiveSession(client, session.id, "pending-rearchive-command");
      expect(Date.parse(second.archivedAt)).toBeGreaterThan(Date.parse(first.archivedAt));
      const stored = await archivedRecord(f.root, session.id) as { archivedAt: string };
      expect(stored.archivedAt).toBe(second.archivedAt);
      return {
        firstArchivedAt: first.archivedAt,
        secondArchivedAt: second.archivedAt,
        archivedRows: (await list(client, "only")).sessions.map((row) => row.archivedAt),
      };
    } finally {
      restoreRemovals();
    }
  });

  archiveCase("rejects a prompt retryably when archive state cannot be cleared", async () => {
    const f = await fixture();
    const client = await f.connect();
    const session = await f.coldSession("persist-failure");
    await openSession(client, session.id);
    await archiveSession(client, session.id, "failure-archive-command");
    const registry = f.current().registry as unknown as {
      markers: { evidence(): Promise<ReadonlyMap<string, readonly unknown[]>> };
    };
    // A failing durable write leaves the in-memory projection untouched, which
    // is exactly what a full or failing disk produces.
    const restoreRemovals = failArchiveRemovals(f.current().registry);
    f.faux.setResponses([fauxAssistantMessage("must never run")]);

    let prompt: any;
    try {
      prompt = await client.request("failure-prompt", "session.prompt", {
        commandId: "failure-prompt-command", sessionId: session.id, text: "must not run",
      });
    } finally {
      restoreRemovals();
    }
    expect(prompt).toMatchObject({ ok: false, error: { code: "busy", retryable: true } });
    expect(f.archiveDiagnostic).toHaveBeenCalledWith({ outcome: "failure", stage: "auto-unarchive" });
    // Fail closed: the session stays archived, no run marker exists, and no
    // runtime work was admitted for the rejected prompt.
    expect(await archivedRecord(f.root, session.id)).toBeDefined();
    expect(await listedIds(client, "only")).toEqual([session.id]);
    expect([...(await registry.markers.evidence()).keys()]).not.toContain(session.id);
    const slot = await f.current().registry.acquire(session.id);
    expect(slot.isBusy).toBe(false);
    expect(slot.snapshot().phase).toBe("idle");
    return {
      promptError: prompt.error.code,
      retryable: prompt.error.retryable,
      runMarkers: (await registry.markers.evidence()).size,
      phaseAfterRejection: slot.snapshot().phase,
    };
  });

  archiveCase("holds the session lane from archive admission through the durable commit", async () => {
    // The review finding this covers: if archive admission released the session
    // lane before its durable commit, a prompt could be admitted in the gap, and
    // the archive would then commit over running work. Holding the durable write
    // open inside the commit makes that gap observable.
    const f = await fixture();
    const client = await f.connect();
    const session = await f.coldSession("lane-hold");
    await openSession(client, session.id);
    const registry = f.current().registry as unknown as {
      archive: { archive(sessionId: string): Promise<string> };
    };
    const durableArchive = registry.archive.archive.bind(registry.archive);
    let enteredCommit!: () => void;
    const inCommit = new Promise<void>((resolve) => { enteredCommit = resolve; });
    let releaseCommit!: () => void;
    const commitBarrier = new Promise<void>((resolve) => { releaseCommit = resolve; });
    registry.archive.archive = async (sessionId: string) => {
      enteredCommit();
      await commitBarrier;
      return durableArchive(sessionId);
    };
    f.faux.setResponses([fauxAssistantMessage("must not be hidden")]);
    let promptSettled = false;
    try {
      const archivePromise = client.request("lane-hold-archive", "session.archive.set", {
        commandId: "lane-hold-archive-command", sessionId: session.id, archived: true,
      });
      await inCommit;
      const promptPromise = client.request("lane-hold-prompt", "session.prompt", {
        commandId: "lane-hold-prompt-command", sessionId: session.id, text: "must not run hidden",
      }).then((response) => { promptSettled = true; return response; });
      await new Promise((resolve) => setTimeout(resolve, 100));
      const admittedDuringCommit = promptSettled;
      // The archive still owns the session lane, so no prompt may be admitted.
      expect(admittedDuringCommit).toBe(false);
      releaseCommit();
      expect((await archivePromise).ok).toBe(true);
      const prompt = await promptPromise;
      // The prompt is admitted only after the commit, and it clears the record
      // before it runs: the session is never both working and hidden.
      expect(prompt.ok, JSON.stringify(prompt)).toBe(true);
      expect(await archivedRecord(f.root, session.id)).toBeUndefined();
      await waitFor(async () => (await list(client, "exclude")).sessions.some((row) => row.id === session.id), "visible after the commit");
      return {
        promptAdmittedDuringCommit: admittedDuringCommit,
        archiveCommitted: (await archivePromise).ok,
        canonicalRecordAfterAdmission: (await archivedRecord(f.root, session.id)) ?? null,
      };
    } finally {
      releaseCommit();
      registry.archive.archive = durableArchive;
    }
  });

  archiveCase("never commits an archive over a run that admission already admitted", async () => {
    const f = await fixture();
    const client = await f.connect();
    const session = await f.coldSession("race");
    await openSession(client, session.id);
    const registry = f.current().registry as unknown as {
      archive: { archivedAt(sessionId: string): string | undefined };
    };
    const slot = await f.current().registry.acquire(session.id);
    const outcomes = { promptAdmitted: 0, archiveWonPromptRejected: 0, bothCommitted: 0 };
    const rounds = 10;
    for (let round = 0; round < rounds; round += 1) {
      f.faux.setResponses([fauxAssistantMessage(`race response ${round}`)]);
      // Warm the catalog acquisition on alternating rounds so the archive
      // request can reach the session lane before the prompt does, instead of
      // always losing the walk to it.
      if (round % 2 === 1) await list(client, "exclude", { limit: 1 });
      const [archive, prompt] = await Promise.all([
        client.request(`race-archive-${round}`, "session.archive.set", {
          commandId: `race-archive-command-${round}`, sessionId: session.id, archived: true,
        }),
        client.request(`race-prompt-${round}`, "session.prompt", {
          commandId: `race-prompt-command-${round}`, sessionId: session.id, text: `race ${round}`,
        }),
      ]);
      if (prompt.ok) {
        outcomes.promptAdmitted += 1;
        // The invariant this race protects: once a run owns the session, no
        // archive record may exist, so it can never work while hidden.
        expect(registry.archive.archivedAt(session.id)).toBeUndefined();
        expect(await archivedRecord(f.root, session.id)).toBeUndefined();
        expect(await listedIds(client, "exclude")).toContain(session.id);
        if (archive.ok) outcomes.bothCommitted += 1;
      } else {
        expect(prompt).toMatchObject({ ok: false, error: { code: "busy" } });
        expect(archive.ok, JSON.stringify(archive)).toBe(true);
        outcomes.archiveWonPromptRejected += 1;
      }
      await waitFor(() => !slot.isBusy, "race run settled");
      // Reset for the next round: an unarchive is a no-op when the prompt won.
      const reset = await client.request(`race-reset-${round}`, "session.archive.set", {
        commandId: `race-reset-command-${round}`, sessionId: session.id, archived: false,
      });
      expect(reset.ok).toBe(true);
    }

    // One gated round with a committed record: the prompt then clears it and
    // the row must be visible for the whole run that follows.
    const gated = (() => {
      let release!: () => void;
      const barrier = new Promise<void>((resolve) => { release = resolve; });
      return { barrier, release: () => release() };
    })();
    f.faux.setResponses([async () => { await gated.barrier; return fauxAssistantMessage("gated response"); }]);
    await archiveSession(client, session.id, "race-gated-archive-command");
    expect(await listedIds(client, "exclude")).not.toContain(session.id);
    const gatedPrompt = await client.request("race-gated-prompt", "session.prompt", {
      commandId: "race-gated-prompt-command", sessionId: session.id, text: "gated race",
    });
    expect(gatedPrompt.ok, JSON.stringify(gatedPrompt)).toBe(true);
    await waitFor(() => slot.snapshot().phase === "running", "gated run started");
    expect(registry.archive.archivedAt(session.id)).toBeUndefined();
    const duringRun = (await list(client, "exclude")).sessions.find((row) => row.id === session.id);
    expect(duringRun?.phase).toBe("running");
    expect(duringRun?.archivedAt).toBeUndefined();
    gated.release();
    await waitFor(() => !slot.isBusy, "gated run settled");
    return {
      rounds,
      outcomes,
      visibleWhileRunning: duringRun?.phase,
    };
  });

  archiveCase("reports the restored row when a run starts during the archive write", async () => {
    // A turn Pi starts on its own can begin while the durable record is still
    // being written. The record then lands over a running session, so the
    // authoritative answer is the restored row rather than the record this
    // request wrote.
    const f = await fixture({ extensions: [{ name: "wake.ts", source: wakeExtension }] });
    const client = await f.connect();
    const session = await f.coldSession("started-during-write");
    await openSession(client, session.id);
    const store = (f.current().registry as unknown as {
      archive: { archive(sessionId: string): Promise<string> };
    }).archive;
    const durableArchive = store.archive.bind(store);
    let enteredWrite!: () => void;
    const inWrite = new Promise<void>((resolve) => { enteredWrite = resolve; });
    let releaseWrite!: () => void;
    const writeBarrier = new Promise<void>((resolve) => { releaseWrite = resolve; });
    let archiveWriteHeld = false;
    store.archive = async (sessionId) => {
      archiveWriteHeld = true;
      enteredWrite();
      await writeBarrier;
      archiveWriteHeld = false;
      return durableArchive(sessionId);
    };
    const stallState = () => `archive stall: watcherPolling=${existsSync(join(f.root, "wake-polling"))}, externalRunSubmitted=${existsSync(join(f.root, "wake-sent"))}, archiveWriteHeld=${archiveWriteHeld}`;
    const waitWithStallState = async (condition: () => boolean, label: string) => {
      try {
        await waitFor(condition, label);
      } catch (error) {
        throw new Error(`${error instanceof Error ? error.message : String(error)}; ${stallState()}`);
      }
    };
    let releaseRun!: () => void;
    const runBarrier = new Promise<void>((resolve) => { releaseRun = resolve; });
    f.faux.setResponses([async () => { await runBarrier; return fauxAssistantMessage("woke during the write"); }]);
    try {
      const archiving = client.request("started-during-write-request", "session.archive.set", {
        commandId: "started-during-write-command", sessionId: session.id, archived: true,
      });
      void archiving.catch(() => {});
      await inWrite;
      // The extension's turn never passes Gateway run admission, so only the
      // active projection the commit rechecks can notice it. Its frames arrive
      // while the commit still holds the registry mutex, which is why this
      // waits on the subscription rather than on a catalog read.
      await writeFile(join(f.root, "wake-trigger"), "", "utf8");
      await waitWithStallState(() => existsSync(join(f.root, "wake-sent")), "external turn submitted");
      await waitWithStallState(() => snapshotFrames(client, session.id).some(
        (frame) => frame.payload?.phase === "running"), "externally started run");
      releaseWrite();
      const response = await archiving;
      expect(response.ok, JSON.stringify(response)).toBe(true);
      expect(response.result).toEqual({ archived: false });
      expect(await listedIds(client, "exclude")).toContain(session.id);
      await waitFor(() => f.archiveDiagnostic.mock.calls.some(
        (call) => JSON.stringify(call[0]) === JSON.stringify({ outcome: "auto-unarchived", trigger: "backstop" })), "backstop diagnostic");
      releaseRun();
      await waitFor(async () => (await archivedRecord(f.root, session.id)) === undefined, "record cleared behind the run");
      await waitFor(async () => (await list(client, "exclude")).sessions.some(
        (row) => row.id === session.id && row.phase === "idle"), "run settled");
      return {
        response: response.result,
        canonicalRecord: (await archivedRecord(f.root, session.id)) ?? null,
      };
    } finally {
      releaseWrite();
      releaseRun();
      store.archive = durableArchive;
    }
  });
  archiveCase("keeps a session switch to a session that already has records admissible", async () => {
    // An extension switching to an existing session (`ctx.switchSession`) must
    // rebind onto that identity. The rebind is a `preserve`: it does not claim a
    // new identity, so the target's existing attention and archive records are
    // not a conflicting new-identity claim, and neither session's records may
    // change.
    const f = await fixture({ extensions: [{ name: "switch.ts", source: switchCommandExtension }] });
    let client = await f.connect();
    const target = await f.coldSession("switch-target");
    await openSession(client, target.id);
    await client.request("switch-target-prompt", "session.prompt", {
      commandId: "switch-target-prompt-command", sessionId: target.id, text: "target turn",
    });
    await waitFor(async () => (await list(client, "exclude")).sessions.some(
      (row) => row.id === target.id && row.phase === "idle"), "target run settled");
    const attentionBefore = await attentionRecord(f.root, target.id);
    expect(attentionBefore, "target attention record before the switch").toBeDefined();
    await archiveSession(client, target.id, "switch-target-archive-command");
    const archiveBefore = await archivedRecord(f.root, target.id);
    expect(archiveBefore, "target archive record before the switch").toBeDefined();
    // A restart leaves the records durable and takes the target's own runtime
    // away, which is the normal state of a session switched back to later.
    await f.restart();
    client = await f.connect();
    expect(await attentionRecord(f.root, target.id)).toEqual(attentionBefore);
    expect(await archivedRecord(f.root, target.id)).toEqual(archiveBefore);

    const source = await f.coldSession("switch-source");
    await openSession(client, source.id);
    const registry = f.current().registry as unknown as { slots: Map<string, unknown> };
    expect([...registry.slots.keys()]).toEqual([source.id]);
    const switched = await client.request("switch-command", "session.prompt", {
      commandId: "switch-command-command", sessionId: source.id, text: `/switch ${target.file}`,
    });
    expect(switched.ok, JSON.stringify(switched)).toBe(true);
    await waitFor(() => registry.slots.has(target.id), "session switch landed");
    // A refused rebind also reports itself as an extension error; the switch
    // must produce none.
    expect(client.frames.filter((frame) => frame.type === "event" && frame.topic === "session.extensionError"
      && JSON.stringify(frame.payload).includes("identity already has"))).toEqual([]);

    // The rebind R-5 owns: exactly one live identity, the switched one, and the
    // target stayed archived with both of its records byte-identical. The
    // switched session opens; the command's receipts stay with its origin.
    expect([...registry.slots.keys()]).toEqual([target.id]);
    await openSession(client, target.id);
    expect(await attentionRecord(f.root, target.id)).toEqual(attentionBefore);
    expect(await archivedRecord(f.root, target.id)).toEqual(archiveBefore);
    expect(await listedIds(client, "only")).toEqual([target.id]);
    expect(await listedIds(client, "exclude")).not.toContain(target.id);
    return {
      promptOk: switched.ok,
      liveSlots: [...registry.slots.keys()],
      archivedAfterSwitch: await archivedRecord(f.root, target.id),
      attentionAfterSwitch: await attentionRecord(f.root, target.id),
    };
  });
});

/** Invocation receipts one canonical session file actually holds. Pi writes a
 * new session's file only once it has content, so an unwritten file holds none. */
async function invocationReceiptsIn(file: string): Promise<Array<{ receiptKind: string; lifecycle?: string; sessionId: string; name?: string }>> {
  const text = await readFile(file, "utf8").catch((error: NodeJS.ErrnoException) => {
    if (error.code === "ENOENT") return "";
    throw error;
  });
  return text.trim().split("\n").filter(Boolean).map((line) => JSON.parse(line))
    .filter((entry) => entry.type === "custom" && entry.customType === "tron.chat-invocation.v1")
    .map((entry) => entry.data);
}

/** A command that replaces the live session, optionally failing after it. */
const replacingCommandExtension = (replace: string, afterReplace = "") => () => `
        export default function (pi) {
          pi.registerCommand("replace", { handler: async (args, ctx) => {
            ${replace}
            ${afterReplace}
          }});
        }
      `;

/** Holds a command handler after its replacement until the test creates the
 * gate file, so the replacement's live state is observable as it stands. */
const gateCall = (gate: string) => `const { existsSync: gateExists } = await import("node:fs");
            const { setTimeout: gateDelay } = await import("node:timers/promises");
            while (!gateExists(${JSON.stringify(gate)})) await gateDelay(5);`;

/** Refuses every switch, the way a guarding extension would. */
const refuseSwitchExtension = () => `
        export default function (pi) {
          pi.on("session_before_switch", async () => ({ cancel: true }));
        }
      `;

describe("command-driven session replacement over the real Gateway", () => {
  // Failure modes: the replacement target is unopenable; the origin never
  // records the command's terminal and later reports outcomeUnknown; the
  // replacement file carries orphan receipts for a command it never ran; the
  // command's work, runtime marker or pending state leaks; a client subscribed
  // to the origin never receives the replacement snapshot; a refused switch
  // hands the command off anyway; a handler failing after the switch writes a
  // failure into the replacement.
  const replace = async (
    kind: "switch" | "new" | "fork",
    options: { afterReplace?: string } = {},
  ) => {
    const call = {
      switch: "await ctx.switchSession(args.trim());",
      new: "await ctx.newSession();",
      fork: "await ctx.fork(ctx.sessionManager.getLeafId(), { position: \"at\" });",
    }[kind];
    const f = await fixture({ extensions: [{ name: "replace.ts", source: replacingCommandExtension(call, options.afterReplace) }] });
    const client = await f.connect();
    const target = await f.coldSession("replacement-target");
    const origin = await f.coldSession("replacement-origin");
    await openSession(client, origin.id);
    const registry = f.current().registry as unknown as { slots: Map<string, { sessionFile?: string }> };
    const response = await client.request(`replace-${kind}`, "session.prompt", {
      commandId: `replace-${kind}-command`, sessionId: origin.id, text: kind === "switch" ? `/replace ${target.file}` : "/replace",
    });
    expect(response.ok, JSON.stringify(response)).toBe(true);
    await waitFor(() => !registry.slots.has(origin.id) && registry.slots.size === 1, "replacement landed");
    const replacementId = [...registry.slots.keys()][0]!;
    const replacementFile = registry.slots.get(replacementId)!.sessionFile!;
    // Settlement: no drain blocker remains for either identity.
    await waitFor(() => f.current().registry.administrativeDrainSnapshot().blockerCount === 0, "command work settled");
    return { f, client, origin, replacementId, replacementFile, operationId: response.result.operationId as string };
  };

  const assertSettledInOrigin = async (
    r: Awaited<ReturnType<typeof replace>>,
    // Pi writes a new, empty session to disk only once it has content.
    replacementPersisted = true,
  ) => {
    const originReceipts = await invocationReceiptsIn(r.origin.file);
    expect(originReceipts.map((receipt) => [receipt.receiptKind, receipt.lifecycle, receipt.sessionId]))
      .toEqual([["start", "staged", r.origin.id], ["terminal", "completed", r.origin.id]]);
    // A fork copies the origin's history, including this command's start under
    // the origin's identity; nothing may be written under the replacement's.
    expect((await invocationReceiptsIn(r.replacementFile)).filter((receipt) => receipt.sessionId === r.replacementId)).toEqual([]);
    const markers = join(r.f.root, "gateway", "runtime-markers");
    const markerFiles = await import("node:fs/promises").then((fs) => fs.readdir(markers).catch(() => [] as string[]));
    expect(markerFiles.filter((name) => name.startsWith(r.origin.id))).toEqual([]);
    // The origin's subscriber follows the identity change and receives the
    // replacement's authoritative state, whether the queue delivered it as the
    // snapshot itself or as the `session.rebaseline` covering a sequence a
    // newer snapshot superseded.
    // Wait for the replacement's settled snapshot. An earlier frame, such as the
    // rebind's, still carries the command's live state until the handler returns.
    await waitFor(() => (deliveredAuthorityFrames(r.client, r.replacementId).at(-1)?.payload as { phase?: string } | undefined)?.phase === "idle",
      "replacement settled snapshot delivered");
    // The command is settled: the replacement is idle and no row for it (a
    // fork inherits one) is projected as still running by the newest authority
    // the client received.
    const replacementSnapshot = deliveredAuthorityFrames(r.client, r.replacementId).at(-1)!.payload as {
      transcript: Array<{ semantic?: { operationId?: string; lifecycle?: string } }>;
    };
    expect(replacementSnapshot.transcript.filter((item) => item.semantic?.operationId === r.operationId
      && ["running", "waitingForInput"].includes(item.semantic.lifecycle ?? ""))).toEqual([]);
    expect((await list(r.client, "exclude")).sessions.find((row) => row.id === r.replacementId)?.phase).toBe("idle");
    await openSession(r.client, r.replacementId);
    // Durable after restart: both sessions open, and the origin reports the
    // command completed rather than recovering it as an unknown outcome.
    await r.f.restart();
    const client = await r.f.connect();
    const originOpen = await client.request("origin-after-restart", "session.open", { sessionId: r.origin.id });
    expect(originOpen.ok, JSON.stringify(originOpen)).toBe(true);
    expect(JSON.stringify(originOpen.result)).not.toContain("outcomeUnknown");
    const replacementOpen = await client.request("replacement-after-restart", "session.open", { sessionId: r.replacementId });
    expect(replacementOpen.ok ? "opened" : replacementOpen.error.code).toBe(replacementPersisted ? "opened" : "not_found");
  };

  it("settles a switching command in its origin", async () => {
    await assertSettledInOrigin(await replace("switch"));
  }, 30_000);

  it("settles a new-session command in its origin", async () => {
    await assertSettledInOrigin(await replace("new"), false);
  }, 30_000);

  it("settles a forking command in its origin", async () => {
    await assertSettledInOrigin(await replace("fork"));
  }, 30_000);

  it("keeps a fork-inherited command row out of the running state while the replacement's handler is live", async () => {
    // Failure modes: the replacement's snapshot marks the origin's command row
    // running while the forked handler is still live, because the live-command
    // overlay matches the inherited row by operation identity; the command never
    // settles in the replacement; the settled snapshot still projects the row as
    // running.
    const forkCall = "await ctx.fork(ctx.sessionManager.getLeafId(), { position: \"at\" });";
    const f = await fixture({ extensions: [{
      name: "replace.ts",
      source: (root) => replacingCommandExtension(forkCall, gateCall(join(root, "fork-gate")))(),
    }] });
    const client = await f.connect();
    const origin = await f.coldSession("gated-origin");
    await openSession(client, origin.id);
    const registry = f.current().registry as unknown as { slots: Map<string, unknown> };
    const response = await client.request("gated-fork", "session.prompt", {
      commandId: "gated-fork-command", sessionId: origin.id, text: "/replace",
    });
    expect(response.ok, JSON.stringify(response)).toBe(true);
    await waitFor(() => !registry.slots.has(origin.id) && registry.slots.size === 1, "fork landed");
    const replacementId = [...registry.slots.keys()][0]!;
    // Positive control: the origin's command is still live in the replacement.
    await waitFor(() => f.current().registry.administrativeDrainSnapshot().blockerCount > 0, "forked command live");
    await waitFor(() => deliveredAuthorityFrames(client, replacementId).length > 0, "replacement snapshot delivered while live");
    const operationId = response.result.operationId as string;
    for (const frame of deliveredAuthorityFrames(client, replacementId)) {
      const transcript = (frame.payload as { transcript: Array<{ semantic?: { operationId?: string; lifecycle?: string } }> }).transcript;
      expect(transcript.filter((item) => item.semantic?.operationId === operationId
        && ["running", "waitingForInput"].includes(item.semantic.lifecycle ?? ""))).toEqual([]);
    }
    await writeFile(join(f.root, "fork-gate"), "");
    await waitFor(() => f.current().registry.administrativeDrainSnapshot().blockerCount === 0, "forked command work settled");
    await waitFor(() => (deliveredAuthorityFrames(client, replacementId).at(-1)?.payload as { phase?: string } | undefined)?.phase === "idle",
      "replacement settled snapshot delivered");
    expect((await invocationReceiptsIn(origin.file)).map((receipt) => [receipt.receiptKind, receipt.lifecycle]))
      .toEqual([["start", "staged"], ["terminal", "completed"]]);
  }, 30_000);

  it("keeps a failure after the switch out of the replacement", async () => {
    const r = await replace("switch", { afterReplace: "throw new Error(\"after the switch\");" });
    await assertSettledInOrigin(r);
  }, 30_000);

  it("keeps a handoff write that must retry in its origin", async () => {
    // Both origin writes start while the origin is bound; forcing them to fail
    // until the rebind has committed makes each succeed only on a retry after
    // the identity changed, which must still target the origin.
    const { RunMarkerStore } = await import("../sessions/run-markers.js");
    let rebound = false;
    const append = SessionManager.prototype.appendCustomEntry;
    vi.spyOn(SessionManager.prototype, "appendCustomEntry").mockImplementation(function (this: SessionManager, customType, data) {
      if (!rebound && (data as { receiptKind?: string })?.receiptKind === "terminal") throw new Error("injected transient append failure");
      return append.call(this, customType, data);
    });
    const clear = RunMarkerStore.prototype.clear;
    vi.spyOn(RunMarkerStore.prototype, "clear").mockImplementation(function (this: InstanceType<typeof RunMarkerStore>, ...args) {
      if (!rebound) return Promise.reject(new Error("injected transient marker failure"));
      return clear.apply(this, args);
    });
    const f = await fixture({ extensions: [{ name: "replace.ts", source: replacingCommandExtension("await ctx.switchSession(args.trim());") }] });
    const client = await f.connect();
    const target = await f.coldSession("retry-target");
    const origin = await f.coldSession("retry-origin");
    await openSession(client, origin.id);
    const registry = f.current().registry as unknown as { slots: Map<string, unknown> };
    const response = await client.request("retry", "session.prompt", {
      commandId: "retry-command", sessionId: origin.id, text: `/replace ${target.file}`,
    });
    expect(response.ok, JSON.stringify(response)).toBe(true);
    await waitFor(() => registry.slots.has(target.id), "replacement landed");
    rebound = true;
    await waitFor(() => f.current().registry.administrativeDrainSnapshot().blockerCount === 0, "command work settled");
    expect((await invocationReceiptsIn(origin.file)).map((receipt) => [receipt.receiptKind, receipt.lifecycle, receipt.sessionId]))
      .toEqual([["start", "staged", origin.id], ["terminal", "completed", origin.id]]);
    expect(await invocationReceiptsIn(target.file)).toEqual([]);
    const markerFiles = await import("node:fs/promises").then((fs) => fs.readdir(join(f.root, "gateway", "runtime-markers")).catch(() => [] as string[]));
    expect(markerFiles.filter((name) => name.startsWith(origin.id))).toEqual([]);
    await openSession(client, target.id);
  }, 30_000);

  it("leaves a refused switch owned and settled by its origin", async () => {
    const f = await fixture({ extensions: [
      { name: "replace.ts", source: replacingCommandExtension("await ctx.switchSession(args.trim());") },
      { name: "refuse.ts", source: refuseSwitchExtension },
    ] });
    const client = await f.connect();
    const target = await f.coldSession("refused-target");
    const origin = await f.coldSession("refused-origin");
    await openSession(client, origin.id);
    const response = await client.request("refused", "session.prompt", {
      commandId: "refused-command", sessionId: origin.id, text: `/replace ${target.file}`,
    });
    expect(response.ok, JSON.stringify(response)).toBe(true);
    await waitFor(async () => (await invocationReceiptsIn(origin.file)).some((receipt) => receipt.receiptKind === "terminal"), "refused command settled");
    const registry = f.current().registry as unknown as { slots: Map<string, unknown> };
    expect([...registry.slots.keys()]).toEqual([origin.id]);
    expect((await invocationReceiptsIn(origin.file)).map((receipt) => [receipt.receiptKind, receipt.lifecycle]))
      .toEqual([["start", "staged"], ["transition", "accepted"], ["terminal", "completed"]]);
    expect(await invocationReceiptsIn(target.file)).toEqual([]);
    await waitFor(() => f.current().registry.administrativeDrainSnapshot().blockerCount === 0, "refused command work settled");
    await openSession(client, origin.id);
  }, 30_000);
});
