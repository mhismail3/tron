import { randomUUID } from "node:crypto";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { createServer, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { InMemoryCredentialStore, fauxAssistantMessage, fauxProvider, fauxToolCall } from "@earendil-works/pi-ai";
import { describe, expect, it } from "vitest";
import { TrustService } from "../admin/trust-service.js";
import { GatewayWorkRegistry } from "./gateway-work-registry.js";
import { RuntimeRegistry } from "./runtime-registry.js";

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => { resolve = done; });
  return { promise, resolve };
}

async function bounded<T>(promise: Promise<T>, label: string): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      promise,
      new Promise<never>((_resolve, reject) => {
        timer = setTimeout(() => reject(new Error(`Timed out: ${label}`)), 5_000);
      }),
    ]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}

/** This peer models independently accepted native work, not a desktop executor.
 * Closing its caller's socket does not settle the accepted effect/cleanup. */
async function nativePeer() {
  const started = deferred<string>();
  const cancelled = deferred<void>();
  const sockets = new Set<Socket>();
  let active = false;
  let starts = 0;
  let cancellationCount = 0;
  let requestSocket: Socket | undefined;
  const server = createServer((socket) => {
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));
    socket.on("error", () => {});
    socket.setEncoding("utf8");
    let buffer = "";
    socket.on("data", (data: string) => {
      buffer += data;
      if (buffer.length > 4_096) { socket.destroy(); return; }
      let newline: number;
      while ((newline = buffer.indexOf("\n")) >= 0) {
        const line = buffer.slice(0, newline);
        buffer = buffer.slice(newline + 1);
        let message: { kind: string; callId?: string };
        try { message = JSON.parse(line) as typeof message; }
        catch { socket.destroy(); return; }
        if (message.kind === "act") {
          starts += 1;
          active = true;
          requestSocket = socket;
          started.resolve(message.callId!);
        } else if (message.kind === "cancel") {
          cancellationCount += 1;
          cancelled.resolve();
        }
      }
    });
  });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => { server.off("error", reject); resolve(); });
  });
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("Fixture did not bind a TCP port");
  return {
    port: address.port, started: started.promise, cancelled: cancelled.promise,
    get active() { return active; },
    get starts() { return starts; },
    get cancellationCount() { return cancellationCount; },
    finish() {
      active = false;
      requestSocket?.end(`${JSON.stringify({ effect: "uncertain", quiescent: true })}\n`);
    },
    async close() {
      active = false;
      for (const socket of sockets) socket.destroy();
      await new Promise<void>((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
    },
  };
}

function extensionSource(port: number, waiterOnly: boolean): string {
  // The bad control deliberately conflates cancellation of a socket waiter with
  // settlement. Never use that branch in a native capability implementation.
  return `import { createConnection } from "node:net";
export default function (pi) {
  pi.registerTool({
    name: "fixture_native_action", label: "Synthetic native action", description: "Test-only accepted work",
    parameters: { type: "object", properties: {}, additionalProperties: false },
    execute: async (callId, _args, signal) => await new Promise((resolve, reject) => {
      const socket = createConnection({ host: "127.0.0.1", port: ${port} });
      let buffer = "";
      let finished = false;
      const cleanup = () => signal?.removeEventListener("abort", cancel);
      const cancel = () => {
        socket.write(JSON.stringify({ kind: "cancel", callId }) + "\\n");
        if (${waiterOnly}) {
          finished = true;
          cleanup();
          socket.end();
          reject(new Error("Bad control: only the waiter stopped"));
        }
      };
      signal?.addEventListener("abort", cancel, { once: true });
      socket.setEncoding("utf8");
      socket.on("connect", () => {
        socket.write(JSON.stringify({ kind: "act", callId }) + "\\n");
        if (signal?.aborted) cancel();
      });
      socket.on("data", data => {
        buffer += data;
        if (buffer.length > 4096) { socket.destroy(new Error("Oversized fixture response")); return; }
        const newline = buffer.indexOf("\\n");
        if (finished || newline < 0) return;
        finished = true;
        cleanup();
        try {
          const receipt = JSON.parse(buffer.slice(0, newline));
          resolve({ content: [{ type: "text", text: "Native effect uncertain; cleanup settled" }], details: { receipt } });
        } catch (error) { reject(error); }
        socket.end();
      });
      socket.on("error", error => { cleanup(); reject(error); });
      socket.on("close", () => { cleanup(); if (!finished) reject(new Error("Fixture owner unavailable")); });
    }),
  });
}
`;
}

// Uses the production runtime with a private canonical session and fake model;
// no active session, credential store, native permission or GUI is consulted.
describe.sequential("native-tool settlement qualification with the pinned runtime", () => {
  for (const waiterOnly of [false, true]) {
    it(waiterOnly
      ? "negative control exposes early idle/drain when only a native waiter is cancelled"
      : "keeps Stop and drain owned until the native tool actually settles cleanup", async () => {
      const oldAgentDir = process.env.PI_CODING_AGENT_DIR;
      const root = await mkdtemp(join(tmpdir(), "tron-native-settlement-"));
      const peer = await nativePeer();
      let registry: RuntimeRegistry | undefined;
      let prompting: Promise<unknown> | undefined;
      let stopping: Promise<void> | undefined;
      let draining: Promise<void> | undefined;
      try {
        const agentDir = join(root, "agent");
        const cwd = join(root, "workspace");
        const sessionDir = join(root, "sessions");
        const extensionDir = join(cwd, ".pi", "extensions");
        await Promise.all([mkdir(agentDir), mkdir(sessionDir), mkdir(extensionDir, { recursive: true })]);
        process.env.PI_CODING_AGENT_DIR = agentDir;
        await writeFile(join(agentDir, "settings.json"), JSON.stringify({ sessionDir }));
        await writeFile(join(extensionDir, "native-fixture.ts"), extensionSource(peer.port, waiterOnly));
        const trust = new TrustService(agentDir);
        await trust.set(cwd, true);
        const faux = fauxProvider({ provider: `native-fixture-${randomUUID()}`, tokensPerSecond: 10_000 });
        const callId = "native-fixture-call";
        faux.setResponses([fauxAssistantMessage([
          fauxToolCall("fixture_native_action", {}, { id: callId }),
        ], { stopReason: "toolUse" })]);
        const workRegistry = new GatewayWorkRegistry();
        registry = new RuntimeRegistry({
          agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust, workRegistry,
          modelRuntimeFactory: async () => {
            const runtime = await ModelRuntime.create({
              modelsPath: null, refreshOnCreate: false, allowModelNetwork: false,
              credentials: new InMemoryCredentialStore(),
            });
            runtime.registerNativeProvider(faux.provider);
            return runtime;
          },
          broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
        });
        await registry.initialize();
        const slot = await registry.create(cwd);
        const model = faux.getModel();
        await slot.setModel(model.provider, model.id);
        prompting = slot.prompt("Run the private synthetic native fixture");
        await expect(bounded(peer.started, "native action admission")).resolves.toBe(callId);
        expect(peer.starts).toBe(1);
        const operationId = slot.snapshot().operation!.id;
        await expect(slot.abort("agent", "stale-operation")).rejects.toMatchObject({ code: "conflict" });
        expect(peer.cancellationCount).toBe(0);

        let stopSettled = false;
        stopping = slot.abort("agent", operationId).then(() => { stopSettled = true; });
        await bounded(peer.cancelled, "native cancellation request");
        expect(peer.active).toBe(true);
        let drainSettled = false;
        draining = registry.waitUntilIdle().then(() => { drainSettled = true; });
        if (waiterOnly) {
          // This is the intentionally incorrect outcome the positive oracle
          // must distinguish. No actual native cleanup has been permitted yet.
          await bounded(Promise.all([stopping, draining]), "bad-control early settlement");
          expect(peer.active).toBe(true);
          expect(stopSettled).toBe(true);
          expect(drainSettled).toBe(true);
        } else {
          expect(stopSettled).toBe(false);
          expect(drainSettled).toBe(false);
          expect(slot.isBusy).toBe(true);
          expect(workRegistry.hasSessionWork(slot.id)).toBe(true);
          expect(registry.administrativeDrainSnapshot().blockerCount).toBeGreaterThan(0);
        }
        peer.finish();
        await bounded(Promise.all([prompting, stopping, draining]), "joined terminal settlement");
        expect(peer.active).toBe(false);
        expect(peer.starts).toBe(1);
        expect(peer.cancellationCount).toBe(1);
        expect(workRegistry.size).toBe(0);
        expect(registry.administrativeDrainSnapshot().phase).toBe("complete");
        const entries = (await readFile(slot.sessionFile!, "utf8")).trim().split("\n").map(line => JSON.parse(line));
        const results = entries.filter(entry => entry.type === "message"
          && entry.message?.role === "toolResult" && entry.message.toolCallId === callId);
        expect(results).toHaveLength(1);
        if (!waiterOnly) {
          expect(results[0].message.details.receipt).toEqual({ effect: "uncertain", quiescent: true });
        } else {
          expect(results[0].message.isError).toBe(true);
        }
      } finally {
        let retired = false;
        try {
          peer.finish();
          await peer.close();
          await bounded(Promise.allSettled([prompting, stopping, draining].filter(Boolean)), "fixture waiter cleanup");
          if (registry) await bounded(registry.dispose(), "fixture registry cleanup");
          retired = true;
        } finally {
          if (oldAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
          else process.env.PI_CODING_AGENT_DIR = oldAgentDir;
          // A failed cleanup retains its private evidence rather than deleting
          // resources still reachable by an unretired runtime.
          if (retired) await rm(root, { recursive: true, force: true });
        }
      }
    }, 20_000);
  }
});
