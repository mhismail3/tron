import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
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
import { HomeTaskReportOwner } from "../../kernel/delegation/task-report.js";
import type { NotificationService } from "../../notifications/notification-service.js";

const DRIVER = "/Applications/Tron.app/Contents/Library/Native/cua-driver";
const boundary = vi.hoisted(() => ({ driver: "", lockFile: "", deadlineScale: 1, probes: 0, host: [] as string[], console: { locked: false, asleep: false } as Record<string, unknown> }));
vi.mock("../../machine/native-capture-transport.js", () => ({ openNativeCaptureTransport: () => {
  const identity = { bootID: crypto.randomUUID(), connectionID: crypto.randomUUID(), sessionID: crypto.randomUUID() };
  const generation = crypto.randomUUID();
  return {
    request: async (control: Buffer) => {
      const request = JSON.parse(control.toString());
      boundary.host.push(request.operation);
      const reply: Record<string, unknown> = { version: 1, status: request.operation, loadID: request.loadID, ...identity, commandID: request.commandID };
      if (request.operation === "hello") reply.status = "ready";
      if (request.operation === "automationEndpoint") Object.assign(reply, { socket: `/tmp/tron-cua-${generation}/s`, generation });
      if (request.operation === "stop") reply.status = "joined";
      return { control: Buffer.from(JSON.stringify(reply)), jpeg: null };
    },
    closeLocal: async () => {},
  };
} }));
vi.mock("node:child_process", async original => {
  const actual = await original<typeof import("node:child_process")>();
  const { promisify } = await import("node:util");
  const { readFileSync } = await import("node:fs");
  const run = promisify(actual.execFile);
  const execFile = Object.assign((...args: any[]) => (actual.execFile as any)(...args), {
    [promisify.custom]: async (file: string, args: string[], options: any) => {
      if (file === "/usr/bin/osascript" && args.some(arg => arg.includes("CGSSessionScreenIsLocked") && arg.includes("JSON.stringify"))) {
        boundary.probes++;
        const lockedByDriver = boundary.lockFile !== "" && (() => { try { readFileSync(boundary.lockFile); return true; } catch { return false; } })();
        return { stdout: JSON.stringify({ console: true, ...boundary.console, locked: lockedByDriver || boundary.console.locked }), stderr: "" };
      }
      return file === DRIVER ? run(process.execPath, [boundary.driver, ...args], { ...options, timeout: options.timeout && options.timeout / boundary.deadlineScale }) : run(file, args, options);
    },
  });
  const spawn = (file: string, args: string[], options: any) => actual.spawn(file,
    file === "/usr/bin/osascript" ? args.map(arg => arg === "PreventUserIdleDisplaySleep" ? "PreventUserIdleSystemSleep" : arg) : args, options);
  return { ...actual, execFile, spawn };
});

const execute = promisify(execFile);
const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
  boundary.console = { locked: false, asleep: false }; boundary.deadlineScale = 1; boundary.probes = 0; boundary.host = []; boundary.lockFile = "";
});

async function heldAssertions(owner = process.pid): Promise<number> {
  const { stdout: processes } = await execute("/bin/ps", ["-axo", "pid=,ppid=,comm="]);
  const holders = processes.split("\n").flatMap(line => {
    const [pid, parent, command] = line.trim().split(/\s+/u);
    return Number(parent) === owner && command === "/usr/bin/osascript" ? [pid] : [];
  });
  const { stdout } = await execute("/usr/bin/pmset", ["-g", "assertions"]);
  return stdout.split("\n").filter(line => holders.some(pid => line.includes(`pid ${pid}(osascript)`)) && line.includes("Tron active computer turn")).length;
}

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "tron-console-"));
  cleanups.push(() => rm(root, { recursive: true, force: true }));
  const dispatched = join(root, "dispatched"), release = join(root, "release");
  boundary.lockFile = join(root, "locked-during-dispatch");
  boundary.driver = join(root, "driver.cjs");
  await execute("/usr/bin/mkfifo", [release]);
  await writeFile(boundary.driver, `const fs = require('node:fs/promises');
(async () => {
  if (process.argv[2] === 'describe') return console.log('name: click\\n\\ninput_schema:\\n' + JSON.stringify({ properties: { session: {}, element_token: {} }, required: ['session'] }));
  const tool = process.argv[3], args = JSON.parse(process.argv[4]);
  if (tool === 'start_session') return console.log(JSON.stringify({ active: true, revived: false }));
  if (tool === 'end_session') return console.log(JSON.stringify({ active: false }));
  await fs.writeFile(${JSON.stringify(dispatched)}, tool);
  const mode = await fs.readFile(${JSON.stringify(join(root, "mode"))}, 'utf8').catch(() => '');
  if (mode === 'hold') await fs.readFile(${JSON.stringify(release)});
  if (mode === 'lock') await fs.writeFile(${JSON.stringify(boundary.lockFile)}, 'locked');
  if (mode === 'stale' && tool === 'click') { console.log(JSON.stringify({ status: 'refused', refusal: { code: 'stale_element_token', message: 'element_token is stale' } })); process.exit(1); }
  const png = Buffer.alloc(33); Buffer.from([137,80,78,71,13,10,26,10]).copy(png); png.writeUInt32BE(13, 8); png.write('IHDR', 12); png.writeUInt32BE(4, 16); png.writeUInt32BE(4, 20);
  if (args.screenshot_out_file) await fs.writeFile(args.screenshot_out_file, png);
  const window = tool === 'get_window_state' ? { pid: 1, window_id: 2, elements: [{ element_token: 's00000001:0' }] } : {};
  console.log(JSON.stringify({ status: 'completed', ...window, ...(args.screenshot_out_file ? { screenshot_file_path: args.screenshot_out_file, screenshot_width: 4, screenshot_height: 4 } : {}) }));
})().catch(error => { console.error(error); process.exit(1); });
`);
  const home = join(root, "home"), agentDir = join(home, "agent");
  await mkdir(agentDir, { recursive: true });
  const views = new BrowserLiveViewRegistry();
  cleanups.push(async () => views.dispose());
  await writeFile(join(agentDir, "settings.json"), JSON.stringify({ defaultTools: ["+computer", "+native_capture"] }));
  const faux = fauxProvider({ provider: "tron-console-fixture", tokensPerSecond: 10_000 });
  const trust = new TrustService(agentDir);
  await trust.set(root, true);
  const alerts: Array<{ title?: string; message: string }> = [];
  const notifications = { enqueue: vi.fn(async (input: { title?: string; message: string }) => { alerts.push(input); return "queued" as const; }),
    suppressAutomatic: vi.fn(async () => "suppressed" as const), markSessionInboxRead: vi.fn(async () => {}) } as unknown as NotificationService;
  const registry = await createTestRegistry({ tronHome: home, agentDir, trust, browserLiveViews: views, machineId: "machine-console-test", notifications,
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
  return {
    slot, result, registry, faux,
    lockAlerts: () => alerts.filter(alert => alert.message.startsWith("Tron paused desktop work")).length,
    root,
    mode: (value: "" | "hold" | "lock" | "stale") => writeFile(join(root, "mode"), value),
    dispatched: async () => !!await readFile(dispatched).catch(() => false),
    release: () => writeFile(release, "released"),
    turn: async (calls: Array<[string, string, Record<string, unknown>]>) => {
      faux.setResponses([
        fauxAssistantMessage(calls.map(([id, name, args]) => fauxToolCall(name, args, { id })), { stopReason: "toolUse" }),
        fauxAssistantMessage("complete"),
      ]);
      const started = performance.now();
      await slot.prompt("Use the fixture desktop");
      await waitFor(() => !slot.isBusy && calls.every(([id]) => !!result(id)), "the fixture turn");
      return performance.now() - started;
    },
  };
}

const desktop = (id: string): [string, string, Record<string, unknown>] => [id, "computer", { tool: "get_desktop_state", arguments: {} }];

describe.skipIf(process.platform !== "darwin")("console admission for computer and native capture through the real Gateway/Pi turn", () => {
  it.each([["mac_locked", { locked: true, asleep: false }], ["display_asleep", { locked: false, asleep: true }],
    ["no_console_session", { console: false, locked: false, asleep: false }], ["console_unavailable", { locked: "unreadable", asleep: false }]] as const)(
    "refuses computer and native_capture within 1 s with %s, dispatches nothing and notifies once per episode", async (cause, state) => {
    const f = await fixture();
    boundary.console = { ...state };
    const elapsed = await f.turn([desktop("desktop"), ["capture", "native_capture", { action: "catalog" }]]);
    expect(elapsed).toBeLessThan(1000);
    for (const id of ["desktop", "capture"]) {
      expect(f.result(id).isError).toBe(true);
      expect(JSON.stringify(f.result(id).content)).toContain(cause);
      expect(JSON.stringify(f.result(id).content)).not.toContain("image/png");
    }
    expect(await f.dispatched()).toBe(false);
    expect(boundary.host).toEqual([]);
    expect(await heldAssertions()).toBe(0);
    await f.turn([desktop("again")]);
    expect(f.result("again").isError).toBe(true);
    expect(f.lockAlerts()).toBe(1);
    boundary.console = { locked: false, asleep: false };
    await f.turn([desktop("unlocked")]);
    expect(f.result("unlocked").isError).not.toBe(true);
    expect(JSON.stringify(f.result("unlocked").content)).toContain("image/png");
    boundary.console = { ...state };
    await f.turn([desktop("relocked")]);
    expect(f.result("relocked").isError).toBe(true);
    expect(f.lockAlerts()).toBe(2);
  });

  it("returns no lock-screen picture when the Mac locks while a capture is being taken", async () => {
    const f = await fixture();
    await f.mode("lock");
    await f.turn([desktop("desktop")]);
    expect(await f.dispatched()).toBe(true);
    expect(f.result("desktop").isError).toBe(true);
    expect(JSON.stringify(f.result("desktop").content)).toContain("mac_locked");
    expect(JSON.stringify(f.result("desktop").content)).not.toContain("image/png");
    expect(f.lockAlerts()).toBe(1);
    expect(await heldAssertions()).toBe(0);
  });

  it.each([false, true])("holds the OS idle assertion only while a computer turn runs and releases it at turn end (Stop=%s)", async stop => {
    const f = await fixture();
    expect(await heldAssertions()).toBe(0);
    await f.mode("hold");
    const prompting = f.turn([desktop("desktop")]);
    await waitFor(() => f.dispatched(), "accepted driver observation");
    await waitFor(async () => await heldAssertions() === 1, "the scoped OS assertion while the computer turn runs");
    const stopping = stop ? f.slot.abort("agent") : undefined;
    await f.release();
    await stopping;
    await prompting;
    await waitFor(async () => await heldAssertions() === 0, "assertion release at turn end");
    if (!stop) expect(f.result("desktop").isError).not.toBe(true);
  });

  it("keeps the display assertion across a delegated task's turns until the task settles, and releases it then", async () => {
    const f = await fixture();
    const report = new HomeTaskReportOwner({ taskId: "desktop-task", homeId: "desktop-home", generation: 1, operationId: "desktop-task-operation" }, async () => {});
    const lease = await f.registry.delegation.createWorker(f.root, report);
    await lease.slot.setModel(f.faux.getModel().provider, f.faux.getModel().id);
    f.faux.setResponses([
      fauxAssistantMessage([fauxToolCall("computer", { tool: "get_desktop_state", arguments: {} }, { id: "worker-desktop" })], { stopReason: "toolUse" }),
      fauxAssistantMessage("Worker turn ends without a report."),
      fauxAssistantMessage("Still no report."),
    ]);
    await new Promise<unknown>((resolve) => {
      void lease.slot.prompt("Use the fixture desktop for the task", [], undefined, undefined, undefined, {
        operationId: "desktop-task-operation", signal: report.signal, onTerminal: resolve,
        origin: { kind: "gateway", ownerId: "desktop-task", title: "Home task", confidence: "boundary" },
      });
    });
    expect(await heldAssertions()).toBe(1);
    report.retire();
    await waitFor(async () => await heldAssertions() === 0, "assertion release when the task settles");
    await f.registry.delegation.acknowledge(lease.slot.id, "desktop-task-operation", lease);
  });

  it("ends a driver call that never answers at its deadline as an uncertain effect and leaves no driver process", async () => {
    const f = await fixture();
    await f.mode("hold");
    boundary.deadlineScale = 20;
    await f.turn([desktop("desktop")]);
    expect(f.result("desktop").isError).toBe(true);
    expect(JSON.stringify(f.result("desktop").content)).toContain("gave no answer within 10 s");
    expect((await execute("/bin/ps", ["-axo", "command="])).stdout).not.toContain(f.root);
    await waitFor(async () => await heldAssertions() === 0, "assertion release after the deadline");
  });

  it("projects help without reserved fields and types a driver-side stale element refusal", async () => {
    const f = await fixture();
    await f.turn([["help", "computer", { tool: "help", arguments: { tool: "click" } }]]);
    const help = JSON.stringify(f.result("help").content);
    expect(help).toContain("element_token");
    expect(help).not.toContain("session");
    await f.mode("stale");
    await f.turn([["window", "computer", { tool: "get_window_state", arguments: { pid: 1, window_id: 2, include_screenshot: false } }],
      ["click", "computer", { tool: "click", arguments: { element_token: "s00000001:0", pid: 1, window_id: 2 } }]]);
    expect(f.result("window").isError).not.toBe(true);
    expect(f.result("click").isError).toBe(true);
    expect(JSON.stringify(f.result("click").content)).toContain("stale_element_token");
  });

  it("releases the OS assertion when the owning runtime process is killed", async () => {
    const source = new URL("../../machine/console-probe.ts", import.meta.url).href;
    const child = spawn(process.execPath, ["--experimental-strip-types", "--input-type=module", "-e",
      `import cp from "node:child_process"; import { syncBuiltinESMExports } from "node:module";
const spawn = cp.spawn; cp.spawn = (file, args, options) => spawn(file, args.map(arg => arg === "PreventUserIdleDisplaySleep" ? "PreventUserIdleSystemSleep" : arg), options);
syncBuiltinESMExports();
const { DisplayActivity } = await import(${JSON.stringify(source)}); new DisplayActivity().hold(); process.send("ready");`],
      { stdio: ["ignore", "ignore", "pipe", "ipc"] });
    let diagnostic = "";
    child.stderr!.on("data", chunk => { diagnostic += chunk; });
    const ended = once(child, "exit");
    const holders = async () => (await execute("/usr/bin/pmset", ["-g", "assertions"])).stdout.split("\n").filter(line => line.includes("Tron active computer turn")).length;
    try {
      await Promise.race([once(child, "message"), ended.then(() => { throw new Error(`Activity runtime exited before ready: ${diagnostic}`); })]);
      await waitFor(async () => await heldAssertions(child.pid!) === 1, "the runtime's scoped OS assertion");
      child.kill("SIGKILL");
      await ended;
      await waitFor(async () => await holders() === 0, "assertion release after the runtime died");
    } finally {
      if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
    }
  });
});
