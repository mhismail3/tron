import { createServer } from "node:http";
import { AddressInfo } from "node:net";
import { WebSocketServer } from "ws";
import { afterEach, describe, expect, it, vi } from "vitest";
import { GatewayClientError, GatewayProtocolClient } from "./gateway-client.js";

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => { await Promise.all(cleanups.splice(0).map((cleanup) => cleanup())); });

async function fixture() {
  const server = createServer();
  const sockets = new WebSocketServer({ server });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = (server.address() as AddressInfo).port;
  cleanups.push(async () => {
    for (const socket of sockets.clients) socket.terminate();
    await new Promise<void>((resolve) => sockets.close(() => resolve()));
    await new Promise<void>((resolve) => server.close(() => resolve()));
  });
  return { sockets, url: `ws://127.0.0.1:${port}` };
}

describe("stable gateway protocol client", () => {
  it("correlates requests and delivers session events", async () => {
    const { sockets, url } = await fixture();
    sockets.on("connection", (socket, request) => {
      expect(request.headers.authorization).toBe("Bearer local-token");
      socket.on("message", (raw) => {
        const frame = JSON.parse(raw.toString()) as any;
        if (frame.type === "hello") socket.send(JSON.stringify({ type: "hello", protocolVersion: 3, minProtocolVersion: 3 }));
        if (frame.type === "request") {
          socket.send(JSON.stringify({ type: "response", id: frame.id, ok: true, result: { value: 1 } }));
          socket.send(JSON.stringify({ type: "event", topic: "session.snapshot", sessionId: "session", payload: { revision: 1 } }));
        }
      });
    });
    const client = new GatewayProtocolClient(url, "local-token");
    await client.connect();
    const events: string[] = [];
    client.onEvent((event) => events.push(`${event.topic}:${event.sessionId}`));
    expect(await client.request("system.info", {})).toEqual({ value: 1 });
    await new Promise((resolve) => setTimeout(resolve, 10));
    expect(events).toEqual(["session.snapshot:session"]);
    client.close();
  });

  it("rejects a v2 gateway before any session request is sent", async () => {
    const { sockets, url } = await fixture();
    let requestCount = 0;
    sockets.on("connection", (socket) => {
      socket.on("message", (raw) => {
        const frame = JSON.parse(raw.toString()) as any;
        if (frame.type === "hello") socket.send(JSON.stringify({ type: "hello", protocolVersion: 2, minProtocolVersion: 2 }));
        if (frame.type === "request") requestCount += 1;
      });
    });
    const client = new GatewayProtocolClient(url, "local-token");
    await expect(client.connect()).rejects.toMatchObject({ code: "protocol_mismatch" });
    expect(requestCount).toBe(0);
    client.close();
  });

  it("ignores stale socket callbacks after a replacement connection", async () => {
    const { sockets, url } = await fixture();
    let connectionCount = 0;
    let firstServerSocket: import("ws").WebSocket | undefined;
    let secondServerSocket: import("ws").WebSocket | undefined;
    sockets.on("connection", (socket) => {
      connectionCount += 1;
      if (connectionCount === 1) firstServerSocket = socket; else secondServerSocket = socket;
      socket.on("message", (raw) => {
        const frame = JSON.parse(raw.toString()) as any;
        if (frame.type === "hello") socket.send(JSON.stringify({ type: "hello", protocolVersion: 3, minProtocolVersion: 3 }));
        if (frame.type === "request" && connectionCount > 1) {
          setTimeout(() => socket.send(JSON.stringify({ type: "response", id: frame.id, ok: true, result: { replacement: true } })), 5);
        }
      });
    });
    const client = new GatewayProtocolClient(url, "local-token");
    await client.connect();
    const staleClientSocket = (client as unknown as { socket: import("ws").WebSocket }).socket;
    firstServerSocket?.terminate();
    await new Promise<void>((resolve) => client.onDisconnect(() => resolve()));
    await client.connect();
    const disconnect = vi.fn();
    client.onDisconnect(disconnect);
    // Exercise callbacks after the new socket is authoritative.
    staleClientSocket.emit("error", new Error("stale error"));
    staleClientSocket.emit("close", 1006, Buffer.from("stale close"));
    await expect(client.request("system.info", {})).resolves.toEqual({ replacement: true });
    expect(disconnect).not.toHaveBeenCalled();
    secondServerSocket?.terminate();
  });

  it("rejects pending work when the connection drops", async () => {
    const { sockets, url } = await fixture();
    sockets.on("connection", (socket) => {
      socket.on("message", (raw) => {
        const frame = JSON.parse(raw.toString()) as any;
        if (frame.type === "hello") socket.send(JSON.stringify({ type: "hello", protocolVersion: 3, minProtocolVersion: 3 }));
        if (frame.type === "request") socket.terminate();
      });
    });
    const client = new GatewayProtocolClient(url, "local-token");
    await client.connect();
    await expect(client.request("session.open", { sessionId: "session" })).rejects.toBeInstanceOf(GatewayClientError);
  });
});
