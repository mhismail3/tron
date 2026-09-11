import { randomUUID } from "node:crypto";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { NativeCaptureTransport } from "./native-capture-transport.js";
import { openNativeCaptureClient } from "./native-capture-client.js";

const { openTransport } = vi.hoisted(() => ({ openTransport: vi.fn() }));
vi.mock("./native-capture-transport.js", () => ({ openNativeCaptureTransport: openTransport }));
const binding = { canonicalSessionID: "canonical-fixture-session", runtimeLoadID: randomUUID() };
const identity = { bootID: randomUUID(), connectionID: randomUUID(), sessionID: randomUUID() };
const handle = randomUUID();
const source = { handle, kind: "window", applicationName: "Fixture", title: "Markers", width: 1000, height: 800 };
const generation = randomUUID();
type Pending = {
  request: Record<string, unknown>;
  resolve: (reply: { control: Buffer; jpeg: Buffer | null }) => void;
  reject: (error: Error) => void;
};
let pending: Pending[];
let localClose: ReturnType<typeof vi.fn>;
beforeEach(() => {
  pending = [];
  localClose = vi.fn(async () => {});
  const transport: NativeCaptureTransport = {
    request: (bytes) => new Promise((resolve, reject) => pending.push({ request: JSON.parse(bytes.toString()), resolve, reject })),
    closeLocal: localClose,
  };
  openTransport.mockClear();
  openTransport.mockReturnValue(transport);
});
function at(index: number): Pending {
  const entry = pending[index];
  if (!entry) throw new Error(`request ${index} was not sent`);
  return entry;
}
function reply(index: number, status: string, fields: Record<string, unknown> = {}, jpeg: Buffer | null = null): void {
  const entry = at(index);
  entry.resolve({ control: Buffer.from(JSON.stringify({ version: 1, status, ...identity,
    loadID: entry.request.loadID,
    ...(entry.request.commandID ? { commandID: entry.request.commandID } : {}), ...fields })), jpeg });
}
async function ready() {
  const client = openNativeCaptureClient(binding);
  reply(0, "ready");
  return client;
}
async function started() {
  const client = await ready();
  const catalog = client.catalog();
  reply(1, "catalog", { sources: [source] });
  expect(await catalog).toEqual([source]);
  const start = client.start(handle);
  reply(2, "started", { generation });
  await start;
  return client;
}
// Bounded JPEG header fixture: metadata inspection only, not decoder evidence.
const jpeg = Buffer.from([
  0xff, 0xd8, 0xff, 0xc0, 0, 11, 8, 0, 2, 0, 3, 1, 1, 0x11, 0,
  0xff, 0xda, 0, 8, 1, 1, 0, 0, 63, 0, 0, 0xff, 0xd9,
]);
describe("NativeCaptureClient", () => {
  it("bootstraps only an exact generation-bound automation socket through ordinary admission", async () => {
    const client = await ready(), id = randomUUID();
    const endpoint = client.automationEndpoint();
    expect(at(1).request.operation).toBe("automationEndpoint");
    await expect(client.catalog()).rejects.toThrow(/may be pending/);
    reply(1, "automationEndpoint", { socket: `/tmp/tron-cua-${id}/s`, generation: id });
    expect(await endpoint).toEqual({ socket: `/tmp/tron-cua-${id}/s`, generation: id });
    const closed = client.close(); reply(2, "joined"); await closed;
    await expect(client.automationEndpoint()).rejects.toThrow(/closed/);
    expect(pending).toHaveLength(3);
  });
  it.each(["relative/s", "/tmp/other/s", "/tmp/../tmp/s", "/" + "x".repeat(110)])("rejects automation endpoint %s", async (socket) => {
    const client = await ready(); const endpoint = client.automationEndpoint();
    const refused = expect(endpoint).rejects.toThrow(/Invalid native automation/);
    reply(1, "automationEndpoint", { socket, generation: randomUUID() }); await refused;
    const closed = client.close(); reply(2, "joined"); await closed;
  });
  it("suspends during a read and waits for that callback before resuming the same target with a fresh stream", async () => {
    const client = await started();
    const read = client.pull(), discarded = expect(read).rejects.toThrow("retired before publication");
    const paused = client.suspend(); expect(client.suspend()).toBe(paused);
    expect(at(4).request.operation).toBe("suspend");
    const resumed = client.start(handle);
    reply(4, "joined"); await Promise.resolve(); await Promise.resolve();
    expect(pending).toHaveLength(5); // Host receipt is not the JS read callback's retirement.
    reply(3, "empty", { readSequence: 1 }); await discarded; await paused;
    await vi.waitFor(() => expect(pending).toHaveLength(6));
    expect(at(5).request).toMatchObject({ operation: "start", handle, ...identity });
    const nextGeneration = randomUUID(); reply(5, "started", { generation: nextGeneration }); await resumed;
    const frame = client.pull(); reply(6, "frame", { generation: nextGeneration, readSequence: 2, sequence: "0", width: 3, height: 2 }, jpeg);
    expect(await frame).toMatchObject({ generation: nextGeneration, sequence: "0" });
    expect(localClose).not.toHaveBeenCalled(); expect(openTransport).toHaveBeenCalledOnce();
    const closed = client.close(); reply(7, "joined"); await closed;
  });

  it("pins a display crop across suspension and snapshots caller arguments before awaiting the join", async () => {
    const client = await ready(), catalog = client.catalog();
    reply(1, "catalog", { sources: [{ ...source, kind: "display" }] }); await catalog;
    const region = { x: 100, y: 50, width: 200, height: 150 };
    const first = client.start(handle, undefined, region);
    expect(at(2).request.region).toEqual(region); reply(2, "started", { generation }); await first;
    const paused = client.suspend(), mutable = { ...region };
    const resumed = client.start(handle, undefined, mutable); mutable.width = 999;
    reply(3, "joined"); await paused; await vi.waitFor(() => expect(pending).toHaveLength(5));
    expect(at(4).request.region).toEqual(region);
    reply(4, "started", { generation: randomUUID() }); await resumed;
    const pausedAgain = client.suspend(); reply(5, "joined"); await pausedAgain;
    await expect(client.start(handle, undefined, { ...region, width: 201 })).rejects.toThrow(/cannot change/);
    expect(pending).toHaveLength(6);
    const closed = client.close(); reply(6, "joined"); await closed;
  });

  it.each(["window", "outside"])("refuses a %s crop before native admission", async (scenario) => {
    const client = await ready(), catalog = client.catalog();
    reply(1, "catalog", { sources: [{ ...source, kind: scenario === "window" ? "window" : "display" }] }); await catalog;
    await expect(client.start(handle, undefined, { x: scenario === "window" ? 0 : 999, y: 0, width: 2, height: 2 })).rejects.toThrow(/inside its selected display/);
    expect(pending).toHaveLength(2);
    const closed = client.close(); reply(2, "joined"); await closed;
  });

  it("a hidden viewer waiting for suspension cannot start capture after the join", async () => {
    const client = await started(), abort = new AbortController();
    const paused = client.suspend(), resumed = client.start(handle, abort.signal);
    const cancelled = expect(resumed).rejects.toThrow(); abort.abort(); reply(3, "joined");
    await paused; await cancelled; expect(pending).toHaveLength(4);
    const closed = client.close(); reply(4, "joined"); await closed;
  });

  it("suspension owns a pending start's stale result without discarding the selected target", async () => {
    const client = await ready(); const catalog = client.catalog();
    reply(1, "catalog", { sources: [source] }); await catalog;
    const starting = client.start(handle), interrupted = expect(starting).rejects.toThrow("stale");
    const paused = client.suspend(); reply(3, "joined");
    at(2).resolve({ control: Buffer.from(JSON.stringify({ version: 1, status: "stale" })), jpeg: null });
    await interrupted; await paused; expect(localClose).not.toHaveBeenCalled();
    const resumed = client.start(handle); reply(4, "started", { generation: randomUUID() }); await resumed;
    const closed = client.close(); reply(5, "joined"); await closed;
  });

  it.each(["retirementFailed", "diagnostic", "lost"])("failed suspension (%s) cannot resume or forge a clean retirement", async (failure) => {
    const client = await started(), paused = client.suspend();
    const rejected = expect(paused).rejects.toThrow();
    if (failure === "lost") at(3).reject(new Error("lost"));
    else reply(3, failure === "diagnostic" ? "joined" : failure, { diagnostic: "not clean" });
    await rejected; expect(localClose).toHaveBeenCalledOnce();
    await expect(client.start(handle)).rejects.toThrow("closed"); expect(pending).toHaveLength(4);
  });

  it("terminal Stop joins an in-flight suspension before using the reserved control lane", async () => {
    const client = await started(), paused = client.suspend(), closed = client.close();
    expect(client.suspend()).toBe(closed); expect(pending).toHaveLength(4);
    reply(3, "joined"); await paused; await vi.waitFor(() => expect(pending).toHaveLength(5));
    expect(at(4).request.operation).toBe("stop"); reply(4, "joined"); await closed;
    await expect(client.start(handle)).rejects.toThrow("closed");
  });
  it("binds canonical owner/load and never sends commandID on disposable pulls", async () => {
    const client = await started();
    expect(client.binding).toEqual(binding);
    const first = client.pull();
    expect(at(3).request).toMatchObject({ operation: "pull", readSequence: 1, generation, ...identity });
    expect(at(3).request).not.toHaveProperty("commandID");
    await expect(client.pull()).rejects.toThrow("One native capture");
    reply(3, "frame", { generation, readSequence: 1, sequence: "91", width: 3, height: 2 }, jpeg);
    expect(await first).toEqual({ generation, readSequence: 1, sequence: "91", width: 3, height: 2, jpeg });
    const second = client.pull();
    expect(at(4).request.readSequence).toBe(2);
    reply(4, "empty", { readSequence: 2 });
    expect(await second).toBeUndefined();
    const close = client.close();
    reply(5, "joined");
    await expect(close).resolves.toEqual({ status: "joined" });
    expect(localClose).toHaveBeenCalledTimes(1);
  });

  it("Stop bypasses pending start and survives its failure until the exact remote join", async () => {
    const client = await ready();
    const catalog = client.catalog();
    reply(1, "catalog", { sources: [source] });
    await catalog;
    const start = client.start(handle);
    const startFailure = expect(start).rejects.toThrow("uncertain");
    const close = client.close();
    expect(client.close()).toBe(close);
    expect(at(3).request.operation).toBe("stop");
    at(2).reject(new Error("uncertain start"));
    await startFailure;
    expect(localClose).not.toHaveBeenCalled();
    reply(3, "joined", { diagnostic: "stop diagnostic retained" });
    await expect(close).resolves.toEqual({ status: "joined", diagnostic: "stop diagnostic retained" });
    expect(localClose).toHaveBeenCalledTimes(1);
    await expect(client.pull()).rejects.toThrow("closed");
    expect(pending).toHaveLength(4); // no reconnect/replay
  });

  it("late frame cannot publish after Stop even if it arrives before the join", async () => {
    const client = await started();
    const frame = client.pull();
    const discarded = expect(frame).rejects.toThrow("retired before publication");
    const close = client.close();
    reply(3, "frame", { generation, readSequence: 1, sequence: "1", width: 3, height: 2 }, jpeg);
    await discarded;
    expect(localClose).not.toHaveBeenCalled();
    reply(4, "joined");
    await close;
  });

  it.each([
    { readSequence: 2 }, { generation: randomUUID() }, { connectionID: randomUUID() },
    { commandID: randomUUID() }, { sequence: "18446744073709551616" }, { width: 1281 }, { width: 2 },
  ])("rejects foreign/stale/malformed frame metadata %j before handing out pixels", async (override) => {
    const client = await started();
    const frame = client.pull();
    const refused = expect(frame).rejects.toThrow();
    reply(3, "frame", { generation, readSequence: 1, sequence: "1", width: 3, height: 2, ...override }, jpeg);
    await refused;
    expect(localClose).toHaveBeenCalledTimes(1);
    await expect(client.close()).rejects.toThrow("remote retirement unconfirmed");
    expect(pending).toHaveLength(4);
  });

  it.each(["retirementFailed", "lost"])("local shutdown never manufactures joined for %s", async (status) => {
    const client = await started();
    const close = client.close();
    const failure = expect(close).rejects.toThrow(/retirement|lost/);
    if (status === "lost") at(3).reject(new Error("transport lost"));
    else reply(3, status, { diagnostic: "stopFailed" });
    await failure;
    expect(localClose).toHaveBeenCalledTimes(1);
    expect(client.close()).toBe(close);
  });

  it.each([123, "x".repeat(257)])("malformed joined diagnostic still retires local callbacks: %j", async (diagnostic) => {
    const client = await ready();
    const close = client.close();
    const failure = expect(close).rejects.toThrow("Invalid native capture text");
    reply(1, "joined", { diagnostic });
    await failure;
    expect(localClose).toHaveBeenCalledTimes(1);
  });

  it("retains both Stop parsing and local cleanup errors", async () => {
    const client = await ready();
    localClose.mockRejectedValue(new Error("cleanup failed"));
    const close = client.close();
    const failure = expect(close).rejects.toMatchObject({ errors: [expect.any(Error), expect.objectContaining({ message: "cleanup failed" })] });
    reply(1, "joined", { diagnostic: false });
    await failure;
  });

  it("joins local callback finalization after the host join before close resolves", async () => {
    const client = await ready();
    let release!: () => void;
    localClose.mockImplementation(() => new Promise<void>((resolve) => { release = resolve; }));
    const close = client.close();
    let joined = false;
    void close.then(() => { joined = true; });
    reply(1, "joined");
    await vi.waitFor(() => expect(localClose).toHaveBeenCalledOnce());
    expect(joined).toBe(false);
    release();
    await close;
    expect(joined).toBe(true);
  });
});
