import { createServer } from "node:http";
import { chmod, mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { WebSocketServer } from "ws";
import { afterEach, describe, expect, it } from "vitest";
import { LegacyImportService } from "./legacy-import-service.js";

const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
afterEach(() => {
  if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
  else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
});

describe("LegacyImportService", () => {
  it("imports legacy history through the authenticated read-only protocol without changing legacy auth", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-legacy-import-"));
    const tronHome = join(root, "tron");
    const agentDir = join(root, "agent");
    const workspace = join(root, "workspace");
    await Promise.all([mkdir(tronHome), mkdir(agentDir), mkdir(workspace)]);
    process.env.PI_CODING_AGENT_DIR = agentDir;
    const token = "legacy-token-that-is-long-enough-for-import";
    const auth = `${JSON.stringify({ version: 1, bearerToken: token, providers: {} })}\n`;
    const authPath = join(tronHome, "auth.json");
    await writeFile(authPath, auth);
    await chmod(authPath, 0o600);

    const http = createServer();
    const sockets = new WebSocketServer({ server: http });
    sockets.on("connection", (socket, request) => {
      expect(request.headers.authorization).toBe(`Bearer ${token}`);
      socket.on("message", (data) => {
        const frame = JSON.parse(data.toString()) as { type: string; id: string; functionId?: string };
        if (frame.type !== "invoke") return;
        const result = frame.functionId === "session::list"
          ? { sessions: [{ sessionId: "old", model: "legacy-model", workingDirectory: workspace, title: "Imported" }] }
          : { messages: [
              { id: "u", role: "user", content: "hello", timestamp: "2026-01-01T00:00:00Z" },
              { id: "a", role: "assistant", content: "world", timestamp: "2026-01-01T00:00:01Z" },
            ], hasMore: false };
        socket.send(JSON.stringify({ type: "response", id: frame.id, ok: true, result }));
      });
    });
    await new Promise<void>((resolve) => http.listen(0, "127.0.0.1", resolve));
    const address = http.address();
    if (!address || typeof address === "string") throw new Error("missing port");

    const service = new LegacyImportService(tronHome);
    await expect(service.import(address.port)).resolves.toMatchObject({ imported: 1, skipped: 0 });
    expect(await readFile(authPath, "utf8")).toBe(auth);
    await expect(service.import(address.port)).resolves.toMatchObject({ imported: 0, skipped: 1 });

    sockets.close();
    await new Promise<void>((resolve) => http.close(() => resolve()));
  });
});
