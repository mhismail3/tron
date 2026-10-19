import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import WebSocket from "ws";
import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { startLockGateway, type LockGateway } from "../../test-support/gateway-lock-harness.js";
import { compareWithGolden, eventShapePaths, lockPaths, lockUpdateRequested } from "../../test-support/scenario-lock.js";
import { waitFor } from "../../test-support/wait-for.js";

/**
 * Wire contract lock (restructure plan §6.5, V7) for the `gateway/protocol` module:
 * the shapes the iOS and Mac clients rely on, recorded from real frames of the real
 * Gateway on a loopback WebSocket (`gateway-lock-harness.ts`).
 *
 * The lock records the declared lockstep contract (`config/GatewayProtocol.json`
 * and the shared `packages/protocol-fixtures` values), the accepted hello frame,
 * the refusal of a client outside the protocol range, and for every method the
 * scenario calls the structure (dotted key paths with leaf types) of its request
 * and of its response or error. Values that vary per run are not shapes, so the
 * golden is stable. A renamed, removed, added or retyped field fails it; such a
 * change belongs to a lockstep slice that updates both ends (plan §4.1 B4).
 */

const MODULE = "gateway/protocol";
const REPOSITORY = resolve(import.meta.dirname, "..", "..", "..", "..");
const gateways: LockGateway[] = [];
afterEach(async () => { await Promise.all(gateways.splice(0).map((gateway) => gateway.dispose())); });

/** One raw handshake: the frames received and how the socket closed. */
async function handshake(gateway: LockGateway, protocolVersion: number): Promise<{ frames: unknown[]; close: { code: number; reason: string } | null }> {
  const socket = new WebSocket(gateway.socketUrl, { headers: { authorization: `Bearer ${gateway.token}` } });
  const frames: unknown[] = [];
  let close: { code: number; reason: string } | null = null;
  socket.on("message", (raw) => frames.push(JSON.parse(raw.toString())));
  socket.on("close", (code, reason) => { close = { code, reason: reason.toString() }; });
  await waitFor(() => socket.readyState === WebSocket.OPEN, "the raw socket to open");
  socket.send(JSON.stringify({ type: "hello", protocolVersion }));
  await waitFor(() => frames.length > 0 || close !== null, "the handshake answer");
  socket.terminate();
  return { frames, close };
}

describe("gateway/protocol wire contract locks", () => {
  it("protocol 8: handshake, refusal and the method shapes clients use", async () => {
    const gateway = await startLockGateway("protocol-wire");
    gateways.push(gateway);
    gateway.script([() => fauxAssistantMessage("Wire contract answer.")]);
    const declared = JSON.parse(await readFile(resolve(REPOSITORY, "config", "GatewayProtocol.json"), "utf8")) as { protocolVersion: number; minProtocolVersion: number };

    const accepted = await handshake(gateway, declared.protocolVersion);
    const refused = await handshake(gateway, declared.protocolVersion + 1);

    const client = await gateway.connect("phone");
    const calls: Array<{ method: string; params: Record<string, unknown>; response: { ok: boolean; result?: unknown; error?: unknown } }> = [];
    const call = async (method: string, params: Record<string, unknown>) => {
      const response = await client.request(method, params);
      calls.push({ method, params, response });
      return response;
    };
    await call("system.info", {});
    const created = await call("session.create", { commandId: gateway.commandId(), cwd: gateway.cwd });
    const sessionId = (created.result as { sessionId: string }).sessionId;
    const opened = await call("session.open", { sessionId });
    await call("session.sync", { sessionId, syncToken: (opened.result as { syncToken: string }).syncToken });
    await call("session.prompt", { commandId: gateway.commandId(), sessionId, text: "wire contract" });
    await gateway.settled(sessionId);
    await call("session.transcript", { sessionId });
    await call("session.list", { scope: "user", archived: "exclude" });
    await call("session.rename", { commandId: gateway.commandId(), sessionId, name: "Wire contract" });
    await call("session.attention.set", { commandId: gateway.commandId(), sessionId, unread: true });
    await call("session.context", { sessionId });
    await call("session.commands", { sessionId });
    await call("session.resources", { sessionId });
    await call("session.tree", { sessionId });
    await call("session.history.list", { sessionId, runtimeGeneration: (opened.result as { session: { runtimeGeneration: string } }).session.runtimeGeneration });
    await call("command.status", { method: "session.rename", commandId: "lock-command-0003" });
    await call("model.list", { sessionId });
    await call("settings.resolve", { target: { kind: "mac" }, keys: ["run.retry.maxRetries"] });
    await call("settings.change", { commandId: gateway.commandId(), target: { kind: "mac" }, reason: "Wire contract",
      changes: [{ key: "run.retry.maxRetries", layer: "mac", op: "set", value: 5 }] });
    await call("settings.history", { limit: 5 });
    await call("session.archive.set", { commandId: gateway.commandId(), sessionId, archived: true });
    await call("session.prompt", { commandId: gateway.commandId(), sessionId: "missing-session", text: "refused" });
    await call("no.such.method", {});

    const trace = {
      lock: "protocol-wire",
      declared: {
        gatewayProtocol: declared,
        connectionContract: JSON.parse(await readFile(resolve(REPOSITORY, "packages", "protocol-fixtures", "gateway-connection-contract.json"), "utf8")),
      },
      handshake: {
        accepted: { frames: accepted.frames.map((frame) => eventShapePaths("hello", frame)), protocolVersion: (accepted.frames[0] as { protocolVersion?: unknown })?.protocolVersion ?? null },
        refused: { frames: refused.frames.map((frame) => eventShapePaths("refusal", frame)), close: refused.close },
      },
      methods: calls.map((entry) => ({
        method: entry.method,
        request: eventShapePaths("request", entry.params),
        ok: entry.response.ok,
        response: eventShapePaths("response", entry.response.ok ? entry.response.result : entry.response.error),
      })),
    };
    await compareWithGolden({
      module: MODULE, ...lockPaths(import.meta.url, trace.lock), trace, update: lockUpdateRequested(MODULE),
      validate: () => {
        expect(trace.handshake.accepted.protocolVersion).toBe(declared.protocolVersion);
        expect(refused.close?.code, "a client outside the range is refused with the mismatch close").toBeGreaterThanOrEqual(4000);
        const failures = trace.methods.filter((entry) => !entry.ok).map((entry) => entry.method);
        expect(failures).toEqual(["session.prompt", "no.such.method"]);
      },
    });
  });
});
