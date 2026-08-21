import { createServer } from "node:http";
import { chmod, mkdir, mkdtemp, readFile, readdir, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { WebSocketServer } from "ws";
import { afterEach, describe, expect, it } from "vitest";
import { safeJson } from "../sessions/projection.js";
import { LegacyImportService } from "./legacy-import-service.js";

interface InvokeFrame {
  type: string;
  id: string;
  functionId?: string;
  payload?: Record<string, unknown>;
}

const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
const serverCleanups: Array<() => Promise<void>> = [];

afterEach(async () => {
  await Promise.all(serverCleanups.splice(0).map((cleanup) => cleanup()));
  if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
  else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
});

async function fixture(): Promise<{ service: LegacyImportService; token: string; workspace: string; tronHome: string; agentDir: string }> {
  const root = await mkdtemp(join(tmpdir(), "tron-legacy-import-"));
  const tronHome = join(root, "tron");
  const agentDir = join(root, "agent");
  const workspace = join(root, "workspace");
  await Promise.all([mkdir(tronHome), mkdir(agentDir), mkdir(workspace)]);
  process.env.PI_CODING_AGENT_DIR = agentDir;
  const token = "legacy-token-that-is-long-enough-for-import";
  const authPath = join(tronHome, "auth.json");
  await writeFile(authPath, `${JSON.stringify({ version: 1, bearerToken: token, providers: {} })}\n`);
  await chmod(authPath, 0o600);
  return { service: new LegacyImportService(tronHome), token, workspace, tronHome, agentDir };
}

async function legacyServer(
  token: string,
  response: (frame: InvokeFrame) => unknown | Promise<unknown>,
): Promise<number> {
  const http = createServer();
  const sockets = new WebSocketServer({ server: http });
  sockets.on("connection", (socket, request) => {
    expect(request.headers.authorization).toBe(`Bearer ${token}`);
    socket.on("message", async (data) => {
      const frame = JSON.parse(data.toString()) as InvokeFrame;
      if (frame.type !== "invoke") return;
      const result = await response(frame);
      socket.send(JSON.stringify({ type: "response", id: frame.id, ok: true, result }));
    });
  });
  await new Promise<void>((resolve) => http.listen(0, "127.0.0.1", resolve));
  const address = http.address();
  if (!address || typeof address === "string") throw new Error("missing port");
  serverCleanups.push(async () => {
    for (const socket of sockets.clients) socket.terminate();
    await new Promise<void>((resolve) => sockets.close(() => resolve()));
    await new Promise<void>((resolve) => http.close(() => resolve()));
  });
  return address.port;
}

function message(id: string): Record<string, unknown> {
  return { id, role: "user", content: `message-${id}`, timestamp: "2026-01-01T00:00:00Z" };
}

describe("LegacyImportService", () => {
  it("imports legacy history through the authenticated read-only protocol without changing legacy auth", async () => {
    const { service, token, workspace, tronHome } = await fixture();
    const authPath = join(tronHome, "auth.json");
    const auth = await readFile(authPath, "utf8");
    const port = await legacyServer(token, (frame) => frame.functionId === "session::list"
      ? { sessions: [{ sessionId: "old", model: "legacy-model", workingDirectory: workspace, title: "Imported" }] }
      : { messages: [
          { id: "u", role: "user", content: "hello", timestamp: "2026-01-01T00:00:00Z" },
          { id: "a", role: "assistant", content: "world", timestamp: "2026-01-01T00:00:01Z" },
        ], hasMore: false });

    const first = await service.import(port);
    expect(first).toMatchObject({ imported: 1, skipped: 0, sessionIds: [expect.any(String)] });
    expect(first.sessionIds[0]!.length).toBeLessThanOrEqual(200);
    expect(safeJson(first)).toEqual(first);
    expect(await readFile(authPath, "utf8")).toBe(auth);
    await expect(service.import(port)).resolves.toMatchObject({ imported: 0, skipped: 1, sessionIds: [] });
  });

  it("rejects duplicate legacy session identities before creating canonical sessions", async () => {
    const { service, token } = await fixture();
    let historyRequests = 0;
    const port = await legacyServer(token, (frame) => {
      if (frame.functionId === "session::list") return { sessions: [{ sessionId: "duplicate" }, { sessionId: "duplicate" }] };
      historyRequests++;
      return { messages: [], hasMore: false };
    });

    await expect(service.import(port)).rejects.toThrow("duplicate session identities");
    expect(historyRequests).toBe(0);
  });

  it("rejects a repeated session-list cursor", async () => {
    const { service, token } = await fixture();
    let page = 0;
    const port = await legacyServer(token, (frame) => {
      if (frame.functionId !== "session::list") return { messages: [], hasMore: false };
      page++;
      return page === 1
        ? { sessions: [{ sessionId: "one" }], nextCursor: "repeat" }
        : { sessions: [{ sessionId: "two" }], nextCursor: "repeat" };
    });

    await expect(service.import(port)).rejects.toThrow("cursor did not make progress");
    expect(page).toBe(2);
  });

  it("rejects a session catalog above the total traversal limit", async () => {
    const { service, token } = await fixture();
    let page = 0;
    const port = await legacyServer(token, (frame) => {
      if (frame.functionId !== "session::list") return { messages: [], hasMore: false };
      const count = page < 2 ? 200 : 101;
      const start = page * 200;
      page++;
      return {
        sessions: Array.from({ length: count }, (_, index) => ({ sessionId: `session-${start + index}` })),
        ...(page < 3 ? { nextCursor: `page-${page}` } : {}),
      };
    });

    await expect(service.import(port)).rejects.toThrow("session list exceeds its total item limit");
    expect(page).toBe(3);
  });

  it("rejects per-session history above the total message limit", async () => {
    const { service, token } = await fixture();
    let historyPage = 0;
    const port = await legacyServer(token, (frame) => {
      if (frame.functionId === "session::list") return { sessions: [{ sessionId: "long" }] };
      const count = historyPage < 20 ? 500 : 1;
      const start = historyPage * 500;
      historyPage++;
      return {
        messages: Array.from({ length: count }, (_, index) => message(`message-${start + index}`)),
        hasMore: true,
      };
    });

    await expect(service.import(port)).rejects.toThrow("session history exceeds its total message limit");
    expect(historyPage).toBe(21);
  });

  it("fails closed for missing, malformed, permissive, and symlinked legacy auth", async () => {
    const { service, tronHome } = await fixture();
    const authPath = join(tronHome, "auth.json");
    await rm(authPath);
    await expect(service.inspect()).resolves.toMatchObject({ available: false });

    await writeFile(authPath, "{not-json", { mode: 0o600 });
    await expect(service.inspect()).resolves.toMatchObject({ available: false });

    await chmod(authPath, 0o640);
    await expect(service.inspect()).resolves.toMatchObject({ available: false });

    await rm(authPath);
    const external = join(tronHome, "external-auth.json");
    await writeFile(external, JSON.stringify({ bearerToken: "valid-legacy-token-that-is-long-enough" }), { mode: 0o600 });
    await symlink(external, authPath);
    await expect(service.inspect()).resolves.toMatchObject({ available: false });

    await rm(authPath);
    await writeFile(authPath, JSON.stringify({ bearerToken: "valid-legacy-token-that-is-long-enough" }), { mode: 0o600 });
    await expect(service.inspect()).resolves.toMatchObject({ available: true });
  });

  it("rejects oversized index and auth JSON before decoding and bounds bearer tokens", async () => {
    const { service, tronHome } = await fixture();
    const gateway = join(tronHome, "gateway");
    await mkdir(gateway);
    await writeFile(join(gateway, "legacy-imports.json"), `{"padding":"${"x".repeat(8 * 1_024 * 1_024)}"}`);
    await expect(service.inspect()).rejects.toThrow("JSON file exceeds");

    await writeFile(join(gateway, "legacy-imports.json"), JSON.stringify({ version: 1, sessions: {} }));
    const authPath = join(tronHome, "auth.json");
    await writeFile(authPath, JSON.stringify({ bearerToken: "x".repeat(5_000) }));
    await chmod(authPath, 0o600);
    await expect(service.inspect()).resolves.toEqual({ available: false, importedCount: 0 });
    await writeFile(authPath, `{"padding":"${"x".repeat(64 * 1_024)}"}`);
    await expect(service.inspect()).resolves.toEqual({ available: false, importedCount: 0 });
  });

  it("removes a newly written canonical file when the locked index commit fails", async () => {
    const { service, token, tronHome, agentDir } = await fixture();
    const gateway = join(tronHome, "gateway");
    await mkdir(gateway);
    const indexPath = join(gateway, "legacy-imports.json");
    await writeFile(indexPath, JSON.stringify({ version: 1, sessions: {} }));
    const port = await legacyServer(token, async (frame) => {
      if (frame.functionId === "session::list") return { sessions: [{ sessionId: "cleanup" }] };
      await writeFile(indexPath, `{"padding":"${"x".repeat(8 * 1_024 * 1_024)}"}`);
      return { messages: [{ ...message("assistant"), role: "assistant" }], hasMore: false };
    });

    await expect(service.import(port)).rejects.toThrow("JSON file exceeds");
    const agentFiles = await readdir(agentDir, { recursive: true });
    expect(agentFiles.filter((path) => path.endsWith(".jsonl"))).toEqual([]);
  });

  it("persists each successful mapping so retry skips partial success after a later bounded failure", async () => {
    const { service, token, tronHome } = await fixture();
    let overflowSecond = true;
    const historyRequests: string[] = [];
    const port = await legacyServer(token, (frame) => {
      if (frame.functionId === "session::list") return { sessions: [{ sessionId: "first" }, { sessionId: "second" }] };
      const sessionId = String(frame.payload?.sessionId);
      historyRequests.push(sessionId);
      if (sessionId === "second" && overflowSecond) {
        return { messages: Array.from({ length: 501 }, (_, index) => message(`oversized-${index}`)), hasMore: false };
      }
      return { messages: [message(`${sessionId}-message`)], hasMore: false };
    });

    await expect(service.import(port)).rejects.toThrow("history page exceeds its item limit");
    const partialIndex = JSON.parse(await readFile(join(tronHome, "gateway", "legacy-imports.json"), "utf8")) as { sessions: Record<string, string> };
    expect(Object.keys(partialIndex.sessions)).toEqual(["first"]);

    overflowSecond = false;
    await expect(service.import(port)).resolves.toMatchObject({ imported: 1, skipped: 1, sessionIds: [expect.any(String)] });
    expect(historyRequests).toEqual(["first", "second", "second"]);
    const finalIndex = JSON.parse(await readFile(join(tronHome, "gateway", "legacy-imports.json"), "utf8")) as { sessions: Record<string, string> };
    expect(Object.keys(finalIndex.sessions)).toEqual(["first", "second"]);
  });
});
