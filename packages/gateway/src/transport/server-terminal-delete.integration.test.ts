import { mkdtemp, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createServer } from "node:http";
import WebSocket from "ws";
import { afterEach, describe, expect, it, vi } from "vitest";
import { GatewayError } from "../errors.js";
import { DeviceStore } from "../security/device-store.js";
import { GatewayServer } from "./server.js";

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => { await Promise.all(cleanups.splice(0).map((cleanup) => cleanup())); });

async function unusedPort(): Promise<number> {
  const probe = createServer();
  await new Promise<void>((resolve) => probe.listen(0, "127.0.0.1", resolve));
  const address = probe.address();
  if (!address || typeof address === "string") throw new Error("probe did not bind");
  await new Promise<void>((resolve) => probe.close(() => resolve()));
  return address.port;
}

async function waitUntil(predicate: () => boolean): Promise<void> {
  const deadline = Date.now() + 5_000;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error("condition timed out");
    await new Promise((resolve) => setTimeout(resolve, 1));
  }
}

describe("terminal attachment revocation after session deletion", () => {
  it("rejects stale terminal control from another subscribed connection", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-terminal-delete-"));
    const devices = new DeviceStore(root, "machine");
    await devices.initialize();
    const token = JSON.parse(await readFile(join(root, "gateway", "local-auth.json"), "utf8")).bearerToken;
    const port = await unusedPort();
    let gateway!: GatewayServer;
    const service = {
      info: () => ({ gatewayVersion: "test", piVersion: "test", protocolVersion: 3, minProtocolVersion: 3, machineId: "machine", machineName: "test", capabilities: [] }),
      terminalBelongsToSession: (terminalId: string, sessionId: string) => terminalId === "terminal-1" && sessionId === "session-1",
      releaseClient: vi.fn(),
      invoke: async (context: any, method: string, params: Record<string, string>) => {
        if (method === "session.open") {
          const syncToken = context.beginSynchronization(params.sessionId);
          const snapshot = { runtimeGeneration: "generation", eventSequence: 1 };
          context.establishSynchronization(params.sessionId, snapshot);
          return { session: snapshot, syncToken, subscriptionToken: syncToken };
        }
        if (method === "session.sync") {
          context.completeSynchronization(params.sessionId, params.syncToken);
          return { synchronized: true };
        }
        if (method === "terminal.attach") {
          context.attachTerminal(params.terminalId);
          return { attached: true };
        }
        if (method === "session.delete") {
          gateway.revokeSessionTerminals(params.sessionId);
          return { deleted: true };
        }
        if (method === "terminal.write") {
          if (!context.ownsTerminal(params.terminalId)) {
            throw new GatewayError("invalid_request", "Attach the terminal before controlling it");
          }
          return { written: true };
        }
        throw new Error(`unexpected method ${method}`);
      },
    };
    const sessions = { subscribe: vi.fn(), unsubscribe: vi.fn(), unsubscribeClient: vi.fn() };
    gateway = new GatewayServer({
      host: "127.0.0.1",
      port,
      maxFrameBytes: 16_384,
      devices,
      uploads: {} as any,
      sessions: sessions as any,
      auth: { cancelClient: vi.fn() } as any,
      service: service as any,
      logger: { log: vi.fn() } as any,
    });
    await gateway.listen();
    cleanups.push(async () => { await gateway.close(); });

    const connect = async () => {
      const socket = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${token}` } });
      const frames: any[] = [];
      socket.on("message", (raw) => frames.push(JSON.parse(raw.toString())));
      await new Promise<void>((resolve) => socket.once("open", () => resolve()));
      socket.send(JSON.stringify({ type: "hello", protocolVersion: 3 }));
      await waitUntil(() => frames.some((frame) => frame.type === "hello"));
      return { socket, frames };
    };
    const request = async (client: { socket: WebSocket; frames: any[] }, id: string, method: string, params: Record<string, string>) => {
      client.socket.send(JSON.stringify({ type: "request", id, method, params }));
      await waitUntil(() => client.frames.some((frame) => frame.id === id));
      return client.frames.find((frame) => frame.id === id);
    };
    const openAndSync = async (client: { socket: WebSocket; frames: any[] }, prefix: string) => {
      const opened = await request(client, `${prefix}-open`, "session.open", { sessionId: "session-1" });
      expect(opened.ok).toBe(true);
      await request(client, `${prefix}-sync`, "session.sync", { sessionId: "session-1", syncToken: opened.result.syncToken });
    };

    const controllingClient = await connect();
    const deletingClient = await connect();
    cleanups.push(async () => {
      controllingClient.socket.terminate();
      deletingClient.socket.terminate();
    });
    await openAndSync(controllingClient, "control");
    await openAndSync(deletingClient, "delete");
    expect((await request(controllingClient, "attach", "terminal.attach", { terminalId: "terminal-1" })).ok).toBe(true);
    expect((await request(deletingClient, "delete", "session.delete", { sessionId: "session-1" })).ok).toBe(true);

    const staleWrite = await request(controllingClient, "stale-write", "terminal.write", {
      terminalId: "terminal-1", writeId: "write-1", data: "echo stale",
    });
    expect(staleWrite).toMatchObject({ ok: false, error: { code: "invalid_request" } });
  });
});
