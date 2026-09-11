import { afterEach, describe, expect, it, vi } from "vitest";
import { BrowserLiveViewRegistry } from "./browser-live-view.js";
import { NativeCaptureHostFailure } from "../machine/native-capture-client.js";
import type { NativeLiveClient } from "./native-live-view.js";
import { jpeg } from "../../test-fixtures/browser-live.js";

function deferred<T>() { let resolve!: (value: T) => void; let reject!: (error: unknown) => void;
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; }
const source = { handle: "11111111-1111-4111-8111-111111111111", kind: "window" as const, title: "Fixture window", applicationName: "Fixture", width: 1000, height: 800 };
function client() {
  const value: NativeLiveClient = {
    catalog: vi.fn(async () => [source]), start: vi.fn(async () => {}),
    pull: vi.fn(async () => ({ generation: "native-stream", readSequence: 1, sequence: "1", width: 1, height: 1, jpeg })),
    suspend: vi.fn(async () => ({ status: "joined" as const })),
    close: vi.fn(async () => ({ status: "joined" as const })),
  };
  return value;
}
const registries: BrowserLiveViewRegistry[] = [];
afterEach(async () => { for (const registry of registries.splice(0)) { registry.dispose(); await registry.joinRetirements(); } });
function fixture(value = client()) {
  const factory = vi.fn(async () => value), failure = vi.fn();
  const views = new BrowserLiveViewRegistry(undefined, factory, failure); registries.push(views);
  views.beginSessionLoad("session");
  return { views, value, factory, failure };
}
async function selected(f: ReturnType<typeof fixture>) {
  await f.views.catalogNative("session");
  return f.views.registerNative("session", source.handle);
}

describe("native producer through the shared live-view owner", () => {
  it("listing/selecting stays capture-free; visible leases share frames and clean suspension preserves the exact target", async () => {
    const f = fixture(), view = await selected(f);
    expect(f.value.start).not.toHaveBeenCalled(); expect(f.value.pull).not.toHaveBeenCalled();
    expect(view.schema).toBe("tron.native-live-view.v1");
    const a = f.views.open("session", view.viewId, view.generation, "phone");
    const b = f.views.open("session", view.viewId, view.generation, "phone");
    await vi.waitFor(() => expect(f.value.pull).toHaveBeenCalledOnce());
    const delivery = f.views.acquireFrame("session", view.viewId, view.generation, a.leaseId, "phone", () => {});
    expect(delivery.frame).toMatchObject({ data: jpeg, sequence: 1, width: 1, height: 1 }); delivery.release();
    f.views.close(a.leaseId); expect(f.value.close).not.toHaveBeenCalled();
    f.views.close(b.leaseId); await f.views.joinRetirements();
    expect(f.value.start).toHaveBeenCalledExactlyOnceWith(source.handle, expect.any(AbortSignal), undefined);
    expect(f.value.suspend).toHaveBeenCalled(); expect(f.value.close).not.toHaveBeenCalled();
    const resumed = f.views.open("session", view.viewId, view.generation, "phone");
    await vi.waitFor(() => expect(f.value.start).toHaveBeenCalledTimes(2));
    expect(f.value.start).toHaveBeenLastCalledWith(source.handle, expect.any(AbortSignal), undefined);
    f.views.close(resumed.leaseId);
    expect(f.factory).toHaveBeenCalledOnce();
  });

  it("a display region remains capture-free until viewed and resumes only its snapshotted crop", async () => {
    const f = fixture(); f.value.catalog = vi.fn(async () => [{ ...source, kind: "display" as const }]);
    await f.views.catalogNative("session");
    const region = { x: 10, y: 20, width: 200, height: 150 };
    const selecting = f.views.registerNative("session", source.handle, region); region.x = 999;
    const view = await selecting;
    expect(f.value.start).not.toHaveBeenCalled();
    const lease = f.views.open("session", view.viewId, view.generation, "phone");
    await vi.waitFor(() => expect(f.value.start).toHaveBeenCalledOnce());
    expect(f.value.start).toHaveBeenCalledWith(source.handle, expect.any(AbortSignal), { x: 10, y: 20, width: 200, height: 150 });
    f.views.close(lease.leaseId); await f.views.joinRetirements();
    const resumed = f.views.open("session", view.viewId, view.generation, "phone");
    await vi.waitFor(() => expect(f.value.start).toHaveBeenCalledTimes(2));
    expect(f.value.start).toHaveBeenLastCalledWith(source.handle, expect.any(AbortSignal), { x: 10, y: 20, width: 200, height: 150 });
    f.views.close(resumed.leaseId);
  });

  it.each([["sourceUnavailable", "source_unavailable"], ["permissionUnavailable", "permission_required"], ["busy", "capture_busy"]])("retains safe %s failure after asynchronous start and failed cleanup", async (status, reason) => {
    const f = fixture();
    f.value.start = vi.fn(async () => { throw new NativeCaptureHostFailure(status!, "start"); });
    f.value.suspend = vi.fn(async () => { throw new Error("private cleanup path /private/fixture"); });
    const view = await selected(f), lease = f.views.open("session", view.viewId, view.generation, "phone");
    await vi.waitFor(() => expect(f.value.close).toHaveBeenCalled());
    let failure: unknown;
    try { f.views.acquireFrame("session", view.viewId, view.generation, lease.leaseId, "phone", () => {}); } catch (error) { failure = error; }
    expect(failure).toMatchObject({ code: "not_found", retryable: false, details: { liveViewFailure: reason } });
    expect(String(failure)).not.toContain("private");
    f.views.retireSession("session");
    try { f.views.describe("session", view.viewId, view.generation); } catch (error) { expect(error).not.toHaveProperty("details.liveViewFailure"); }
    expect(f.factory).toHaveBeenCalledOnce(); expect(f.value.start).toHaveBeenCalledOnce();
  });

  it("empty native reads cannot renew first-frame waiting forever", async () => {
    const clock = vi.spyOn(performance, "now").mockReturnValue(10);
    try {
      const f = fixture(); f.value.pull = vi.fn(async () => undefined);
      const view = await selected(f), lease = f.views.open("session", view.viewId, view.generation, "phone");
      await vi.waitFor(() => expect(f.value.pull).toHaveBeenCalled());
      clock.mockReturnValue(5_010);
      const waiting = f.views.acquireFrame("session", view.viewId, view.generation, lease.leaseId, "phone", () => {});
      expect(waiting.frame).toEqual({ status: "waiting" }); waiting.release();
      clock.mockReturnValue(10_010);
      let error: unknown;
      try { f.views.acquireFrame("session", view.viewId, view.generation, lease.leaseId, "phone", () => {}); } catch (failure) { error = failure; }
      expect(error).toMatchObject({ details: { liveViewFailure: "first_frame_timeout" } });
      await f.views.joinRetirements();
      expect(f.value.suspend).toHaveBeenCalled(); expect(f.value.start).toHaveBeenCalledOnce();
      expect(() => f.views.open("session", view.viewId, view.generation, "phone")).toThrow(/ended/);
    } finally { clock.mockRestore(); }
  });

  it("Stop reaches the native owner during start and retains the unfinished start until its real completion", async () => {
    const start = deferred<void>(), stop = deferred<{ status: "joined" }>();
    const value = client(); value.start = vi.fn(() => start.promise); value.suspend = vi.fn(() => stop.promise);
    const f = fixture(value), view = await selected(f);
    const lease = f.views.open("session", view.viewId, view.generation, "phone");
    await vi.waitFor(() => expect(value.start).toHaveBeenCalled());
    f.views.close(lease.leaseId); expect(value.suspend).toHaveBeenCalled();
    let settled = false; const joined = f.views.joinRetirements().then(() => { settled = true; });
    stop.resolve({ status: "joined" }); await Promise.resolve(); await Promise.resolve();
    expect(settled).toBe(false); expect(value.pull).not.toHaveBeenCalled();
    start.resolve(); await joined;
    expect(value.pull).not.toHaveBeenCalled(); expect(f.failure).not.toHaveBeenCalled();
  });

  it("late frame after viewer revocation cannot publish into the retained target", async () => {
    const frame = deferred<Awaited<ReturnType<NativeLiveClient["pull"]>>>();
    const value = client(); value.pull = vi.fn(() => frame.promise);
    const f = fixture(value), view = await selected(f);
    f.views.open("session", view.viewId, view.generation, "phone");
    await vi.waitFor(() => expect(value.pull).toHaveBeenCalled());
    f.views.closeViewerIdentity("phone");
    frame.resolve({ generation: "late", sequence: "1", readSequence: 1, width: 1, height: 1, jpeg });
    await f.views.joinRetirements();
    expect(f.views.describe("session", view.viewId, view.generation)).toEqual(view);
    expect(f.value.suspend).toHaveBeenCalled(); expect(f.value.close).not.toHaveBeenCalled();
    expect(f.factory).toHaveBeenCalledOnce();
  });

  it("a retired extension load cannot publish a delayed catalog, and closes its eventual native client", async () => {
    const opened = deferred<NativeLiveClient>(), value = client();
    const f = fixture(value); f.factory.mockImplementation(() => opened.promise);
    const catalog = f.views.catalogNative("session"); const rejected = expect(catalog).rejects.toThrow(/ended/);
    await vi.waitFor(() => expect(f.factory).toHaveBeenCalled());
    f.views.beginSessionLoad("session"); opened.resolve(value);
    await rejected; await f.views.joinRetirements(); expect(value.close).toHaveBeenCalled();
    await expect(f.views.registerNative("session", source.handle)).rejects.toThrow(/List native windows/);
  });

  it("aborting a catalog closes only that read, not this session's existing visible window", async () => {
    const f = fixture(), view = await selected(f);
    f.views.open("session", view.viewId, view.generation, "phone");
    const next = client(), catalog = deferred<readonly typeof source[]>(); next.catalog = vi.fn(() => catalog.promise);
    f.factory.mockResolvedValue(next);
    const abort = new AbortController(), reading = f.views.catalogNative("session", abort.signal);
    const rejected = expect(reading).rejects.toThrow(/ended/);
    await vi.waitFor(() => expect(next.catalog).toHaveBeenCalled());
    abort.abort(); catalog.resolve([source]); await rejected;
    expect(next.close).toHaveBeenCalled(); expect(f.value.close).not.toHaveBeenCalled();
    expect(f.views.describe("session", view.viewId, view.generation)).toEqual(view);
  });

  it("failed Stop is reported, never retried or turned into a remote join", async () => {
    const f = fixture(), view = await selected(f);
    f.value.close = vi.fn(async () => { throw new Error("remote retirement unconfirmed"); });
    await expect(f.views.stopNative("session")).rejects.toThrow(/unconfirmed/);
    await f.views.joinRetirements(); expect(f.failure).toHaveBeenCalled();
    expect(() => f.views.describe("session", view.viewId, view.generation)).toThrow();
    expect(f.factory).toHaveBeenCalledOnce();
  });

  it("a never-viewed selection closes on session retirement without starting capture", async () => {
    const f = fixture(); await selected(f); f.views.retireSession("session");
    await f.views.joinRetirements(); expect(f.value.close).toHaveBeenCalled(); expect(f.value.start).not.toHaveBeenCalled();
  });
});
