import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createServer } from "node:http";
import WebSocket, { WebSocketServer } from "ws";
import { afterEach, describe, expect, it } from "vitest";
import { DeviceStore } from "../security/device-store.js";
import { SessionSyncBarrier } from "./session-sync.js";

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => { await Promise.all(cleanups.splice(0).map((cleanup) => cleanup())); });

describe("two-phase session synchronization protocol", () => {
  it("uses the owner-only local credential and orders acknowledgement before catch-up", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-sync-protocol-"));
    const devices = new DeviceStore(root, "machine");
    await devices.initialize();
    const token = JSON.parse(await (await import("node:fs/promises")).readFile(join(root, "gateway", "local-auth.json"), "utf8")).bearerToken;

    const http = createServer();
    const sockets = new WebSocketServer({ server: http });
    await new Promise<void>((resolve) => http.listen(0, "127.0.0.1", resolve));
    const address = http.address();
    if (!address || typeof address === "string") throw new Error("test server did not bind");
    cleanups.push(async () => {
      for (const socket of sockets.clients) socket.terminate();
      await new Promise<void>((resolve) => sockets.close(() => resolve()));
      await new Promise<void>((resolve) => http.close(() => resolve()));
    });

    sockets.on("connection", (socket, request) => {
      expect(request.headers.authorization).toBe(`Bearer ${token}`);
      const barrier = new SessionSyncBarrier();
      socket.on("message", (raw) => {
        const frame = JSON.parse(raw.toString()) as any;
        if (frame.type === "hello") socket.send(JSON.stringify({ type: "hello", protocolVersion: 2, minProtocolVersion: 2 }));
        if (frame.method === "session.open") {
          barrier.begin("token");
          barrier.offer({ type: "event", topic: "session.progress", sessionId: "session", payload: { runtimeGeneration: "generation", eventSequence: 2, revision: 2, data: {} } });
          barrier.establish({ runtimeGeneration: "generation", eventSequence: 1 } as any);
          socket.send(JSON.stringify({ type: "response", id: frame.id, ok: true, result: { session: { runtimeGeneration: "generation", eventSequence: 1 }, syncToken: "token" } }));
        }
        if (frame.method === "session.sync") {
          const completed = barrier.commit(frame.params.syncToken);
          socket.send(JSON.stringify({ type: "response", id: frame.id, ok: true, result: { synchronized: true } }));
          for (const event of completed.events) socket.send(JSON.stringify(event));
        }
      });
    });

    const socket = new WebSocket(`ws://127.0.0.1:${address.port}`, { headers: { authorization: `Bearer ${token}` } });
    const frames: any[] = [];
    socket.on("message", (raw) => frames.push(JSON.parse(raw.toString())));
    await new Promise<void>((resolve) => socket.once("open", () => resolve()));
    socket.send(JSON.stringify({ type: "hello", protocolVersion: 2 }));
    while (!frames.some((frame) => frame.type === "hello")) await new Promise((resolve) => setTimeout(resolve, 1));
    socket.send(JSON.stringify({ type: "request", id: "open", method: "session.open", params: { sessionId: "session" } }));
    while (!frames.some((frame) => frame.id === "open")) await new Promise((resolve) => setTimeout(resolve, 1));
    socket.send(JSON.stringify({ type: "request", id: "sync", method: "session.sync", params: { sessionId: "session", syncToken: "token" } }));
    while (!frames.some((frame) => frame.topic === "session.progress")) await new Promise((resolve) => setTimeout(resolve, 1));

    expect(frames.findIndex((frame) => frame.id === "open")).toBeLessThan(frames.findIndex((frame) => frame.id === "sync"));
    expect(frames.findIndex((frame) => frame.id === "sync")).toBeLessThan(frames.findIndex((frame) => frame.topic === "session.progress"));
    socket.close();
  });
});
