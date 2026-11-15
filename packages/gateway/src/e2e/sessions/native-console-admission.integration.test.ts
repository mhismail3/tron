import { createServer, createConnection, type Socket } from "node:net";
import { mkdtemp, mkdir, writeFile, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { execFile, spawn } from "node:child_process";
import { promisify } from "node:util";
import { once } from "node:events";
import { afterEach, describe, expect, it, vi } from "vitest";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall } from "@earendil-works/pi-ai";
import { createTestRegistry } from "../../../test-support/gateway-registry.js";
import { waitFor } from "../../../test-support/wait-for.js";
import { TrustService } from "../../kernel/resources/trust-service.js";
import { BrowserLiveViewRegistry } from "../../display/browser-live-view.js";
import type { NativeCaptureTransport } from "../../machine/native-capture-transport.js";

const boundary = vi.hoisted(() => ({ open: undefined as unknown as () => NativeCaptureTransport, driver: "" }));
vi.mock("../../machine/native-capture-transport.js", () => ({ openNativeCaptureTransport: () => boundary.open() }));
vi.mock("node:child_process", async original => {
  const actual = await original<typeof import("node:child_process")>();
  const { promisify } = await import("node:util");
  const run = promisify(actual.execFile);
  const execFile = Object.assign((...args: any[]) => (actual.execFile as any)(...args), {
    [promisify.custom]: (file: string, args: string[], options: any) => file === "/Applications/Tron.app/Contents/Library/Native/cua-driver"
      ? run(process.execPath, [boundary.driver, ...args], options) : run(file, args, options),
  });
  return { ...actual, execFile };
});
const cleanups: Array<() => Promise<void>> = [];
const execute = promisify(execFile);
async function systemActivities(owner = process.pid): Promise<number[]> {
  const { stdout } = await execute("/bin/ps", ["-axo", "pid=,ppid=,comm="]);
  return stdout.split("\n").flatMap(line => {
    const [pid, parent, command] = line.trim().split(/\s+/u);
    return Number(parent) === owner && command === "/usr/bin/caffeinate" ? [Number(pid)] : [];
  });
}
async function hasSystemAssertion(pid: number): Promise<boolean> {
  const { stdout } = await execute("/usr/bin/pmset", ["-g", "assertions"]);
  return stdout.split("\n").some(line => line.includes(`pid ${pid}(caffeinate)`) && line.includes("PreventUserIdleSystemSleep"));
}
afterEach(async () => {
  const failures: unknown[] = [];
  for (const cleanup of cleanups.splice(0).reverse()) try { await cleanup(); } catch (error) { failures.push(error); }
  if (failures.length) throw new AggregateError(failures, "Native console fixture cleanup failed");
});

async function fixture(cause: string | null, hold = false, background = false) {
  const root = await mkdtemp(join(tmpdir(), "tron-console-"));
  cleanups.push(() => rm(root, { recursive: true, force: true }));
  const endpoint = join(root, "host");
  const generation = randomUUID();
  const socket = `/tmp/tron-cua-${generation}/s`;
  const state = { onConsole: cause !== "no_console_session", loginDone: true, screenLocked: cause === "mac_locked", screensaverActive: null,
    displaysAsleep: cause === "display_asleep", lidClosed: null, activeDisplayCount: cause === "no_active_display" ? 0 : 1, topologyGeneration: generation, cause };
  const requests: string[] = [], peers = new Set<Socket>();
  let leases = 0;
  const server = createServer(peer => {
    peers.add(peer);
    const connectionID = randomUUID(), sessionID = randomUUID();
    let loadID = "", buffer = "", active = false;
    peer.setEncoding("utf8");
    peer.on("data", chunk => {
      buffer += chunk;
      for (let index; (index = buffer.indexOf("\n")) >= 0;) {
        const request = JSON.parse(buffer.slice(0, index)); buffer = buffer.slice(index + 1);
        requests.push(request.operation);
        loadID ||= request.loadID;
        let reply: Record<string, unknown> = { version: 1, status: request.operation, loadID, bootID: generation, connectionID, sessionID };
        if (request.commandID) reply.commandID = request.commandID;
        switch (request.operation) {
          case "hello": reply.status = "ready"; break;
          case "sessionState": Object.assign(reply, { readSequence: request.readSequence, state }); break;
          case "automationEndpoint":
            if (cause) { reply = { version: 1, status: cause }; break; }
            if (!active) { active = true; leases++; }
            Object.assign(reply, { socket, generation }); break;
          case "catalog": reply = { version: 1, status: cause ?? "unavailable" }; break;
          case "stop": if (active) { active = false; leases--; } reply.status = "joined"; break;
          default: reply = { version: 1, status: "invalidRequest" };
        }
        peer.write(`${JSON.stringify(reply)}\n`);
      }
    });
    peer.on("error", () => {});
    peer.on("close", () => { peers.delete(peer); if (active) leases--; });
  });
  await new Promise<void>((resolve, reject) => { server.once("error", reject); server.listen(endpoint, resolve); });
  cleanups.push(async () => {
    for (const peer of peers) peer.destroy();
    await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
  });
  boundary.open = () => {
    const peer = createConnection(endpoint);
    peer.setEncoding("utf8");
    let buffer = "", pending: { resolve(value: { control: Buffer; jpeg: null }): void; reject(error: Error): void } | undefined;
    peer.on("data", chunk => {
      buffer += chunk;
      const end = buffer.indexOf("\n");
      if (end < 0) return;
      const control = Buffer.from(buffer.slice(0, end)); buffer = buffer.slice(end + 1);
      const request = pending; pending = undefined; request?.resolve({ control, jpeg: null });
    });
    peer.on("error", error => { pending?.reject(error); pending = undefined; });
    return {
      request: control => new Promise((resolve, reject) => {
        if (pending) return reject(new Error("Concurrent fixture request"));
        pending = { resolve, reject }; peer.write(`${control}\n`);
      }),
      closeLocal: () => new Promise(resolve => { if (peer.closed) resolve(); else { peer.once("close", resolve); peer.destroy(); } }),
    };
  };
  boundary.driver = join(root, "driver.cjs");
  const marker = join(root, "dispatched"), release = join(root, "release");
  await writeFile(boundary.driver, `const fs = require('node:fs/promises');
(async () => {
  const tool = process.argv[3];
  if (tool === 'get_desktop_state') {
    await fs.writeFile(${JSON.stringify(marker)}, tool);
    if (${hold}) {
      const until = Date.now() + 3000;
      while (!(await fs.stat(${JSON.stringify(release)}).catch(() => false))) {
        if (Date.now() > until) throw Error('fixture release deadline');
        await new Promise(resolve => setTimeout(resolve, 10));
      }
    }
  }
  console.log(JSON.stringify(tool === 'start_session' ? {active:true,revived:false} : {status:'completed',observed:true}));
})().catch(error => {console.error(error);process.exit(1)});
`);
  const home = join(root, "home"), agentDir = join(home, "agent");
  await mkdir(agentDir, { recursive: true });
  const views = new BrowserLiveViewRegistry();
  cleanups.push(async () => views.dispose());
  await writeFile(join(agentDir, "settings.json"), JSON.stringify({ defaultTools: ["+computer", "+native_capture", "+bash"] }));
  const faux = fauxProvider({ provider: "tron-console-fixture", tokensPerSecond: 10_000 });
  faux.setResponses([
    fauxAssistantMessage([background
      ? fauxToolCall("bash", { command: `printf background > ${JSON.stringify(marker)}; while ! test -f ${JSON.stringify(release)}; do sleep 0.01; done; printf complete` }, { id: "desktop" })
      : fauxToolCall("computer", { tool: "get_desktop_state", arguments: { include_screenshot: false } }, { id: "desktop" })], { stopReason: "toolUse" }),
    ...(cause && !background ? [fauxAssistantMessage([fauxToolCall("native_capture", { action: "catalog" }, { id: "capture" })], { stopReason: "toolUse" })] : []),
    fauxAssistantMessage("complete"),
  ]);
  const trust = new TrustService(agentDir);
  await trust.set(root, true);
  const registry = await createTestRegistry({ tronHome: home, agentDir, trust, browserLiveViews: views,
    modelRuntimeFactory: async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    }, broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {} });
  cleanups.push(() => registry.dispose());
  await registry.initialize();
  await registry.initializeBlobStorage();
  const slot = await registry.create(root);
  const model = faux.getModel();
  await slot.setModel(model.provider, model.id);
  const result = (id: string) => slot.snapshot().transcript.find((item: any) => item.kind === "message" && item.role === "toolResult" && item.toolCallId === id) as any;
  return { slot, result, requests, leases: () => leases, dispatched: async () => !!await readFile(marker).catch(() => false),
    release: () => writeFile(release, "released") };
}

describe.skipIf(process.platform !== "darwin")("native console admission through real Gateway/Pi and external transport/driver fixtures", () => {
  it("releases the real system assertion when its owning runtime process is killed", async () => {
    const source = new URL("../../machine/agent-activity.ts", import.meta.url).href;
    const child = spawn(process.execPath, ["--experimental-strip-types", "--input-type=module", "-e",
      `import { AgentActivity } from ${JSON.stringify(source)}; const activity = new AgentActivity(); await activity.start(); process.on('message', () => {}); process.send('ready');`],
      { stdio: ["ignore", "ignore", "pipe", "ipc"] });
    let diagnostic = "";
    child.stderr!.on("data", chunk => { diagnostic += chunk; });
    const ended = once(child, "exit");
    try {
      await Promise.race([once(child, "message"), ended.then(() => { throw new Error(`Activity runtime exited before ready: ${diagnostic}`); })]);
      const activities = await systemActivities(child.pid!);
      expect(activities).toHaveLength(1);
      const pid = activities[0]!;
      await waitFor(() => hasSystemAssertion(pid), "crash fixture system assertion");
      child.kill("SIGKILL");
      await ended;
      await waitFor(async () => !await hasSystemAssertion(pid), "OS parent-liveness assertion retirement");
    } finally {
      if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
      await ended;
    }
  });
  it.each(["mac_locked", "display_asleep", "no_console_session", "no_active_display"])("refuses computer and native_capture finitely with %s, without GUI dispatch", async cause => {
    const f = await fixture(cause);
    const start = performance.now();
    await f.slot.prompt("Inspect the fixture desktop and capture sources");
    await waitFor(() => !f.slot.isBusy && !!f.result("capture"), "finite native admission");
    expect(performance.now() - start).toBeLessThan(1000);
    for (const id of ["desktop", "capture"]) {
      expect(f.result(id).isError).toBe(true);
      expect(JSON.stringify(f.result(id))).toContain(cause);
    }
    expect(f.requests).toContain("sessionState");
    expect(f.requests).not.toContain("automationEndpoint");
    expect(await f.dispatched()).toBe(false);
    expect(f.leases()).toBe(0);
  });
  it.each([{ stop: false, background: false }, { stop: true, background: false }, { stop: false, background: true }, { stop: true, background: true }])(
    "holds system activity through accepted work and retires on normal/Stop end (Stop=$stop, locked headless=$background)", async ({ stop, background }) => {
    const f = await fixture(background ? "mac_locked" : null, true, background);
    const before = new Set(await systemActivities());
    try {
      await f.slot.prompt("Inspect the fixture desktop");
      await waitFor(() => f.dispatched(), "accepted driver observation");
      expect(f.leases()).toBe(background ? 0 : 1);
      const activities = (await systemActivities()).filter(pid => !before.has(pid));
      expect(activities).toHaveLength(1);
      const pid = activities[0]!;
      await waitFor(() => hasSystemAssertion(pid), "OS-owned system sleep assertion");
      const stopping = stop ? f.slot.abort("agent") : undefined;
      await f.release();
      await stopping;
      await waitFor(() => !f.slot.isBusy, "computer turn retirement");
      expect(f.leases()).toBe(0);
      expect((await systemActivities()).filter(pid => !before.has(pid))).toEqual([]);
      expect(f.requests.filter(operation => operation === "automationEndpoint")).toHaveLength(background ? 0 : 1);
      expect(f.requests.filter(operation => operation === "stop")).toHaveLength(background ? 0 : 1);
      if (background) expect(f.requests).toEqual([]);
      if (!stop) expect(f.result("desktop").isError).not.toBe(true);
    } finally { await f.release(); }
  });
});
