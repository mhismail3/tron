import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { once } from "node:events";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { afterAll, afterEach, describe, expect, it } from "vitest";
import WebSocket from "ws";
import { PROTOCOL_VERSION } from "../version.js";
import { waitFor } from "../../test-support/wait-for.js";

// #479: a terminal opened from the app and left detached at an empty prompt
// blocked every Gateway restart until someone found and quit it. These runs
// drive a real supervised source Gateway over its authenticated socket: open a
// session terminal, leave it, and ask for a restart. An abandoned prompt closes
// with a visible reason and the restart proceeds; a terminal running a program
// or holding typed input still refuses the restart and stays alive.

const gatewayRoot = fileURLToPath(new URL("../..", import.meta.url));
const resolverPreload = join(gatewayRoot, "test-support", "home-ledger-crash-preload.mjs");
const deployModule = pathToFileURL(join(gatewayRoot, "..", "..", "scripts", "gateway-payload-deploy.mjs")).href;
const reportPath = process.env.TRON_TERMINAL_IDLE_REPORT ?? join(gatewayRoot, "test-results", "terminal-idle.e2e.json");
const roots: string[] = [];
const children: Array<ReturnType<typeof spawn>> = [];
const report: Array<Record<string, unknown>> = [];

type LogRecord = { event?: string; message?: string; reason?: string; elapsedMs?: number; code?: string };
type Frame = { type: string; id?: string; ok?: boolean; result?: unknown; error?: { message?: string }; topic?: string; payload?: unknown };

async function freePort(): Promise<number> {
  return await new Promise((resolve, reject) => {
    const server = createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      server.close(() => typeof address === "object" && address ? resolve(address.port) : reject(new Error("no port")));
    });
  });
}

async function readLog(tronHome: string): Promise<LogRecord[]> {
  const text = await readFile(join(tronHome, "logs", "gateway.jsonl"), "utf8").catch(() => "");
  return text.split("\n").filter(Boolean).flatMap((line) => {
    try { return [JSON.parse(line) as LogRecord]; } catch { return []; }
  });
}

/** One authenticated socket, like the app's: requests and the events it receives. */
async function connect(port: number, token: string) {
  const ws = new WebSocket(`ws://127.0.0.1:${port}/v1/socket`, { headers: { authorization: `Bearer ${token}` }, perMessageDeflate: false });
  const pending = new Map<string, { resolve: (value: unknown) => void; reject: (error: Error) => void }>();
  const events: Frame[] = [];
  const opened = once(ws, "open");
  const ready = new Promise<void>((resolve, reject) => {
    ws.once("error", reject);
    ws.on("message", (raw) => {
      const frame = JSON.parse(raw.toString()) as Frame;
      if (frame.type === "hello") { resolve(); return; }
      if (frame.type === "event") { events.push(frame); return; }
      if (frame.type !== "response" || !frame.id) return;
      const waiter = pending.get(frame.id);
      pending.delete(frame.id);
      if (frame.ok) waiter?.resolve(frame.result ?? null);
      else waiter?.reject(new Error(frame.error?.message ?? "request failed"));
    });
  });
  await opened;
  ws.send(JSON.stringify({ type: "hello", protocolVersion: PROTOCOL_VERSION, clientId: randomUUID() }));
  await ready;
  const request = async <T>(method: string, params: Record<string, unknown> = {}): Promise<T> => {
    const id = randomUUID();
    const result = new Promise<unknown>((resolve, reject) => pending.set(id, { resolve, reject }));
    ws.send(JSON.stringify({ type: "request", id, method, params }));
    return await result as T;
  };
  const close = async () => {
    if (ws.readyState === WebSocket.CLOSED) return;
    const closed = once(ws, "close");
    ws.close();
    await closed;
  };
  return { request, events, close };
}

type Terminal = { id: string; exitedAt?: string; closedReason?: string };

async function startGateway() {
  const root = await mkdtemp(join(tmpdir(), "tron-terminal-idle-"));
  roots.push(root);
  const tronHome = join(root, "tron");
  const payloadRoot = join(root, "payload");
  const project = join(root, "project");
  for (const directory of ["home", "tmp", "agent", "project", join("payload", "app", "dist")]) {
    await mkdir(join(root, directory), { recursive: true });
  }
  // As in exit-after-shutdown.e2e.test.ts: the supervised marker admits
  // gateway.restart exactly as under launchd while the Gateway runs from source.
  await writeFile(join(payloadRoot, "app", "dist", "index.js"), "");
  const port = await freePort();
  const child = spawn(process.execPath, [
    "--experimental-transform-types", "--no-warnings", "--import", pathToFileURL(resolverPreload).href, join(gatewayRoot, "src", "index.ts"),
  ], {
    cwd: gatewayRoot,
    stdio: ["ignore", "pipe", "pipe"],
    env: {
      PATH: process.env.PATH,
      SHELL: "/bin/zsh",
      HOME: join(root, "home"),
      TMPDIR: join(root, "tmp"),
      TRON_DATA_DIR: tronHome,
      PI_CODING_AGENT_DIR: join(root, "agent"),
      PI_SUBAGENTS_TEMP_ROOT: join(tronHome, "internal", "subagents"),
      TRON_GATEWAY_HOST: "127.0.0.1",
      TRON_GATEWAY_PORT: String(port),
      TRON_GATEWAY_SUPERVISED: "1",
      TRON_GATEWAY_PAYLOAD_ROOT: payloadRoot,
    },
  });
  children.push(child);
  let output = "";
  child.stdout.on("data", (chunk: Buffer) => { output += chunk.toString(); });
  child.stderr.on("data", (chunk: Buffer) => { output += chunk.toString(); });
  await waitFor(async () => {
    if (child.exitCode !== null || child.signalCode !== null) throw new Error(`Gateway exited during startup: ${output}`);
    return (await readLog(tronHome)).some((record) => record.event === "gateway.startup-budget") || undefined;
  }, "the source Gateway is serving");
  const { readLocalCredential } = await import(deployModule) as { readLocalCredential: (path: string) => Promise<string> };
  const token = await readLocalCredential(join(tronHome, "gateway", "local-auth.json"));
  const client = () => connect(port, token);
  const setup = await client();
  const { sessionId } = await setup.request<{ sessionId: string }>("session.create", { cwd: project, commandId: `create-${randomUUID()}` });
  await setup.close();

  /** Open a terminal from a session the way the app does, and run `input` in it. */
  const openTerminal = async (input?: string) => {
    const app = await client();
    await app.request("session.open", { sessionId });
    const { terminal, replay } = await app.request<{ terminal: Terminal; replay: { chunks: Array<{ data: string }> } }>(
      "terminal.open", { sessionId, commandId: `open-${randomUUID()}`, columns: 80, rows: 24 },
    );
    // The login shell prints its prompt before it is sitting idle.
    await waitFor(() => app.events.some(event => event.topic === "terminal.output") || replay.chunks.length > 0 || undefined, "the shell prompt");
    if (input !== undefined) await app.request("terminal.write", { terminalId: terminal.id, writeId: randomUUID(), data: input, commandId: `write-${randomUUID()}` });
    return { app, terminal };
  };
  const listTerminals = async () => {
    const app = await client();
    await app.request("session.open", { sessionId });
    const { terminals } = await app.request<{ terminals: Terminal[] }>("terminal.list", { sessionId });
    await app.close();
    return terminals;
  };
  const restart = async () => {
    const app = await client();
    try {
      return await app.request<Record<string, unknown>>("gateway.restart", { commandId: `restart-${randomUUID()}` });
    } finally {
      await app.close().catch(() => {});
    }
  };
  return { child, tronHome, client, openTerminal, listTerminals, restart, output: () => output };
}

afterEach(async () => {
  for (const child of children.splice(0)) {
    if (child.exitCode !== null || child.signalCode !== null) continue;
    const exited = once(child, "exit");
    child.kill("SIGKILL");
    await exited;
  }
});

afterAll(async () => {
  await mkdir(dirname(reportPath), { recursive: true });
  await writeFile(reportPath, `${JSON.stringify({ issue: 479, runs: report }, null, 2)}\n`);
  await Promise.all(roots.map((root) => rm(root, { recursive: true, force: true })));
});

describe("app terminals at a Gateway restart (#479)", () => {
  it("closes a detached terminal at an empty prompt with its reason, and the restart proceeds", async () => {
    const gateway = await startGateway();
    const { app, terminal } = await gateway.openTerminal();
    await app.close();

    const result = await gateway.restart();
    const [code, signal] = await waitFor(async () => {
      if (gateway.child.exitCode === null && gateway.child.signalCode === null) return undefined;
      return [gateway.child.exitCode, gateway.child.signalCode] as const;
    }, "the Gateway left the process table for its restart", { boundMs: 60_000 });
    const records = await readLog(gateway.tronHome);
    const closed = records.find(record => record.event === "terminal.auto-closed");
    report.push({ case: "abandoned prompt", result, code, signal, closed });

    // Admitted: the drain started (an opened session may still be settling).
    expect(result).toHaveProperty("drainId");
    expect(code).toBe(75);
    expect(closed).toMatchObject({ reason: "restart" });
    expect(closed?.message).toBe(`Terminal ${terminal.id} closed: Closed for a Gateway restart`);
  }, 90_000);

  it("refuses the restart and keeps terminals that run a program or hold typed input", async () => {
    const gateway = await startGateway();
    const running = await gateway.openTerminal("sleep 600\r");
    const typed = await gateway.openTerminal("echo half-typed");
    await running.app.close();
    await typed.app.close();
    // The program has started before the restart is requested.
    await new Promise(resolve => setTimeout(resolve, 1_000));

    const refusal = await gateway.restart().then(() => undefined, (error: Error) => error.message);
    const terminals = await gateway.listTerminals();
    report.push({ case: "busy terminals", refusal, terminals: terminals.map(({ id, exitedAt, closedReason }) => ({ id, exitedAt, closedReason })) });

    expect(refusal).toBe("Close active terminal sessions before restarting the Gateway: 1 running a program, 1 with typed input");
    expect(terminals.filter(terminal => terminal.exitedAt === undefined).map(terminal => terminal.id).sort())
      .toEqual([running.terminal.id, typed.terminal.id].sort());
    expect(gateway.child.exitCode).toBeNull();
  }, 90_000);

  it("refuses the restart while a device has the terminal open", async () => {
    const gateway = await startGateway();
    const { app, terminal } = await gateway.openTerminal();
    const refusal = await gateway.restart().then(() => undefined, (error: Error) => error.message);
    const terminals = await gateway.listTerminals();
    report.push({ case: "attached terminal", refusal });
    expect(refusal).toBe("Close active terminal sessions before restarting the Gateway: 1 open on a device");
    expect(terminals.find(candidate => candidate.id === terminal.id)?.exitedAt).toBeUndefined();
    await app.close();
  }, 90_000);
});
