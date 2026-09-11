import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { BrowserSocket, jpeg, registration } from "../../test-fixtures/browser-live.js";
import { BrowserLiveViewRegistry } from "./browser-live-view.js";
import { admitBrowserJPEG } from "./browser-live-cdp.js";
import { observeTrustedAgentBrowserResult } from "./browser-live-view-adapter.js";

const registries: BrowserLiveViewRegistry[] = [];
beforeEach(() => vi.useFakeTimers());
afterEach(() => { for (const registry of registries.splice(0)) registry.dispose(); vi.restoreAllMocks(); vi.useRealTimers(); });
function fixture() {
  const sockets: BrowserSocket[] = [];
  const registry = new BrowserLiveViewRegistry(() => { const socket = new BrowserSocket(); sockets.push(socket); return socket as never; });
  registries.push(registry);
  const loadToken = registry.beginSessionLoad(registration.sessionId);
  registry.register({ ...registration, loadToken });
  const open = (device = "device-a") => registry.open(registration.sessionId, registration.viewId, registration.generation, device);
  const frame = (leaseId: string, after = 0) => {
    const delivery = registry.acquireFrame(registration.sessionId, registration.viewId, registration.generation, leaseId, "device-a", () => {}, after);
    delivery.release();
    return delivery.frame;
  };
  return { registry, sockets, loadToken, open, frame };
}

describe("browser live observation", () => {
  it("expires viewer demand by elapsed time even when wall time moves backward", async () => {
    const f = fixture(), lease = f.open(), socket = f.sockets[0]!;
    socket.open(); await vi.advanceTimersByTimeAsync(1);
    socket.frame(1); await vi.advanceTimersByTimeAsync(1);
    expect(f.frame(lease.leaseId)).toHaveProperty("data");
    vi.setSystemTime(Date.now() - 3_600_000);
    await vi.advanceTimersByTimeAsync(16_001);
    expect(() => f.frame(lease.leaseId)).toThrow(/ended/);
    expect(socket.readyState).toBe(3);
  });
  it("does no observation until open; shares capture, disposes on last close, and reopens the same endpoint without old pixels", async () => {
    const f = fixture();
    expect(f.sockets).toHaveLength(0);
    const first = f.open();
    const second = f.open();
    expect(f.sockets).toHaveLength(1);
    const socket = f.sockets[0]!;
    socket.open();
    await vi.advanceTimersByTimeAsync(1);
    expect(socket.commands.some((command) => command.method === "Page.startScreencast" && command.sessionId === "observer:one")).toBe(true);
    socket.frame(11);
    await vi.advanceTimersByTimeAsync(200);
    expect(f.frame(first.leaseId)).toMatchObject({ data: jpeg, width: 1, height: 1, sequence: 1 });
    expect(f.frame(first.leaseId, 1)).toEqual({ status: "unchanged" });
    expect(f.registry.close(first.leaseId, "wrong-device")).toBe(false);
    f.registry.close(first.leaseId);
    expect(socket.readyState).toBe(1);
    f.registry.close(second.leaseId);
    expect(socket.readyState).toBe(3);
    expect(vi.getTimerCount()).toBe(0);
    const reopened = f.open();
    socket.frame(12);
    expect(f.frame(reopened.leaseId)).toEqual({ status: "waiting" });
    expect(f.sockets).toHaveLength(2);
  });

  it("paces producer credits and replaces before JPEG decoding; unexpected targets cannot publish", async () => {
    const f = fixture(); const lease = f.open(); const socket = f.sockets[0]!;
    socket.open(); await vi.advanceTimersByTimeAsync(1);
    socket.frame(1, "two");
    expect(f.frame(lease.leaseId)).toEqual({ status: "waiting" });
    socket.frame(11); socket.frame(12); socket.frame(13);
    await vi.advanceTimersByTimeAsync(1);
    const acks = () => socket.commands.filter((command) => command.method === "Page.screencastFrameAck");
    expect(acks()).toHaveLength(1);
    expect(acks()[0]?.params?.sessionId).toBe(11);
    await vi.advanceTimersByTimeAsync(198);
    expect(acks()).toHaveLength(1);
    await vi.advanceTimersByTimeAsync(2);
    expect(acks()).toHaveLength(2);
    expect(f.frame(lease.leaseId)).toMatchObject({ sequence: 1 });
    socket.frame(14); socket.frame(15); socket.frame(16); socket.frame(17); socket.frame(18);
    await vi.advanceTimersByTimeAsync(1);
    expect(socket.readyState).toBe(3);
    expect(() => f.frame(lease.leaseId)).toThrow("ended");
  });

  it.each(["Target.getTargets", "Target.attachToTarget", "Runtime.evaluate", "Page.startScreencast"])("ends and frees leases when %s never replies", async (method) => {
    const f = fixture(); const lease = f.open(); const socket = f.sockets[0]!;
    socket.silent.add(method); socket.open();
    await vi.advanceTimersByTimeAsync(5_001);
    expect(socket.readyState).toBe(3);
    expect(() => f.frame(lease.leaseId)).toThrow("ended");
    expect(vi.getTimerCount()).toBe(0);
    expect(() => f.open()).not.toThrow();
  });

  it.each(["missing", "wrong-target"])("ends successful screencast setup when its first frame is %s", async (failure) => {
    // Keep real visibility-loop scheduling; move only its monotonic clock.
    // This tests silent producers, not unanswered commands or idle expiry.
    vi.useRealTimers();
    const clock = vi.spyOn(performance, "now").mockReturnValue(0);
    const f = fixture(); const lease = f.open(); const socket = f.sockets[0]!;
    socket.open();
    await vi.waitFor(() => expect(socket.commands.some((command) => command.method === "Page.startScreencast")).toBe(true));
    if (failure === "wrong-target") socket.frame(1, "two");
    expect(f.frame(lease.leaseId)).toEqual({ status: "waiting" });
    clock.mockReturnValue(5_001);
    await vi.waitFor(() => expect(socket.readyState).toBe(3), { timeout: 1_500 });
    expect(() => f.frame(lease.leaseId)).toThrow("ended");
    expect(socket.commands.some((command) => command.method === "Browser.close")).toBe(false);
  });

  it("keeps a static painted page alive but requires a first frame from a newly selected page", async () => {
    vi.useRealTimers();
    const clock = vi.spyOn(performance, "now").mockReturnValue(0);
    const f = fixture(); const lease = f.open(); const socket = f.sockets[0]!;
    socket.open();
    await vi.waitFor(() => expect(socket.commands.some((command) => command.method === "Page.startScreencast")).toBe(true));
    socket.frame(1);
    await vi.waitFor(() => expect(f.frame(lease.leaseId)).toMatchObject({ sequence: 1 }));
    const evaluations = socket.commands.filter((command) => command.method === "Runtime.evaluate").length;
    clock.mockReturnValue(6_000);
    await vi.waitFor(() => expect(socket.commands.filter((command) => command.method === "Runtime.evaluate").length).toBeGreaterThan(evaluations));
    expect(socket.readyState).toBe(1);
    expect(f.frame(lease.leaseId, 1)).toEqual({ status: "unchanged" });
    socket.visible.set("one", false); socket.visible.set("two", true);
    await vi.waitFor(() => expect(socket.commands.some((command) => command.method === "Page.startScreencast" && command.sessionId === "observer:two")).toBe(true));
    expect(f.frame(lease.leaseId)).toEqual({ status: "waiting" });
    socket.frame(2, "one"); // The retired page cannot satisfy the new deadline.
    clock.mockReturnValue(11_001);
    await vi.waitFor(() => expect(socket.readyState).toBe(3), { timeout: 1_500 });
    expect(() => f.frame(lease.leaseId)).toThrow("ended");
  });

  it("ends on command error, connection failure and malformed input, without refreshing a waiting lease forever", async () => {
    for (const failure of ["command", "close", "malformed"] as const) {
      const f = fixture(); const lease = f.open(); const socket = f.sockets[0]!;
      if (failure === "command") socket.fail.add("Page.startScreencast");
      socket.open(); await vi.advanceTimersByTimeAsync(1);
      if (failure === "close") socket.terminate();
      if (failure === "malformed") socket.message(null);
      await vi.advanceTimersByTimeAsync(1);
      expect(socket.readyState).toBe(3);
      expect(() => f.frame(lease.leaseId)).toThrow("ended");
    }
  });

  it("retires revocation/generation replacement and rejects late load registration", () => {
    const f = fixture();
    const revoked = f.open(); f.registry.closeViewerIdentity("device-a");
    expect(() => f.frame(revoked.leaseId)).toThrow();
    const replaced = f.open(); f.registry.beginSessionLoad(registration.sessionId);
    expect(() => f.frame(replaced.leaseId)).toThrow();
    expect(() => f.registry.register({ ...registration, loadToken: f.loadToken })).toThrow("no longer active");
  });

  it.each(["close", "expiry", "observer", "reload", "dispose"])("retires an outstanding write on %s without letting an old release free a successor", async (reason) => {
    const f = fixture(); const lease = f.open(); const socket = f.sockets[0]!;
    socket.open(); await vi.advanceTimersByTimeAsync(1);
    const firstCancelled = vi.fn(), secondCancelled = vi.fn();
    const acquire = (cancel: () => void) => f.registry.acquireFrame(registration.sessionId, registration.viewId,
      registration.generation, lease.leaseId, "device-a", cancel);
    const first = acquire(firstCancelled);
    first.release();
    const second = acquire(secondCancelled);
    first.release();
    expect(() => acquire(() => {})).toThrow("outstanding frame");
    if (reason === "close") f.registry.close(lease.leaseId);
    if (reason === "expiry") await vi.advanceTimersByTimeAsync(16_001);
    if (reason === "observer") { socket.terminate(); await vi.advanceTimersByTimeAsync(1); }
    if (reason === "reload") f.registry.beginSessionLoad(registration.sessionId);
    if (reason === "dispose") f.registry.dispose();
    expect(firstCancelled).not.toHaveBeenCalled();
    expect(secondCancelled).toHaveBeenCalledOnce();
    second.release();
    expect(() => acquire(() => {})).toThrow();
    expect(vi.getTimerCount()).toBe(0);
  });

  it("does not retain a timer when connect throws", () => {
    const registry = new BrowserLiveViewRegistry(() => { throw new Error("fixture"); }); registries.push(registry);
    registry.register({ ...registration, loadToken: registry.beginSessionLoad(registration.sessionId) });
    expect(() => registry.open(registration.sessionId, registration.viewId, registration.generation, "device-a")).toThrow();
    expect(vi.getTimerCount()).toBe(0);
  });

  it("bounds registrations and per-view/total viewers", () => {
    const f = fixture();
    for (let i = 0; i < 4; i++) f.open();
    expect(() => f.open()).toThrow("capacity");
    for (let i = 1; i < 64; i++) {
      const next = { ...registration, loadToken: f.loadToken, viewId: `view-${i}`, generation: `generation-${i}`,
        cdpUrl: registration.cdpUrl.replace("123456789abc", i.toString(16).padStart(12, "0")) };
      f.registry.register(next);
      if (i < 4) for (let n = 0; n < 4; n++) f.registry.open(next.sessionId, next.viewId, next.generation, "device-a");
    }
    expect(() => f.registry.open(registration.sessionId, "view-4", "generation-4", "device-a")).toThrow("capacity");
    expect(() => f.registry.register({ ...registration, loadToken: f.loadToken, viewId: "overflow", generation: "overflow" })).toThrow("capacity");
  });

  it("follows a changed visible tab and fences old-target frames without resetting sequences", async () => {
    vi.useRealTimers();
    const f = fixture(); const lease = f.open(); const socket = f.sockets[0]!;
    socket.open();
    await vi.waitFor(() => expect(socket.commands.some((command) => command.method === "Page.startScreencast")).toBe(true));
    socket.frame(1);
    await vi.waitFor(() => expect(f.frame(lease.leaseId)).toMatchObject({ sequence: 1 }));
    socket.visible.set("one", false); socket.visible.set("two", true);
    await vi.waitFor(() => expect(socket.commands.some((command) => command.method === "Page.startScreencast" && command.sessionId === "observer:two")).toBe(true), { timeout: 1500 });
    socket.frame(2, "one");
    expect(f.frame(lease.leaseId)).toEqual({ status: "waiting" });
    socket.frame(3, "two");
    await vi.waitFor(() => expect(f.frame(lease.leaseId)).toMatchObject({ sequence: 2 }));
  });

  it("fences a detached target's late visibility reply and follows the remaining page", async () => {
    vi.useRealTimers();
    const f = fixture(); const lease = f.open(); const socket = f.sockets[0]!;
    socket.open();
    await vi.waitFor(() => expect(socket.commands.some((command) => command.method === "Page.startScreencast")).toBe(true));
    socket.silent.add("Page.screencastFrameAck");
    socket.frame(1, "one");
    await vi.waitFor(() => expect(socket.commands.some((command) => command.method === "Page.screencastFrameAck")).toBe(true));
    socket.silent.add("Runtime.evaluate");
    const evaluations: Array<{ id: number; sessionId?: string }> = [];
    socket.on("sent", (command) => {
      if (command.method !== "Runtime.evaluate" || evaluations.length >= 2) return;
      evaluations.push(command);
      if (evaluations.length === 2) queueMicrotask(() => {
        socket.visible.delete("one"); socket.visible.set("two", true);
        socket.message({ method: "Target.detachedFromTarget", params: { sessionId: "observer:one" } });
        for (const pending of evaluations) socket.message({ id: pending.id, sessionId: pending.sessionId,
          result: { result: { type: "string", value: "visible" } } });
        socket.silent.delete("Runtime.evaluate");
        socket.silent.delete("Page.screencastFrameAck");
      });
    });
    await vi.waitFor(() => expect(socket.commands.some((command) => command.method === "Page.startScreencast" && command.sessionId === "observer:two")).toBe(true), { timeout: 1500 });
    expect(socket.readyState).toBe(1);
    socket.frame(1, "two");
    await vi.waitFor(() => expect(f.frame(lease.leaseId)).toHaveProperty("data"));
  });

  it("reads encoded JPEG dimensions, rejects corrupt/oversized frames and endpoint controls", () => {
    expect(admitBrowserJPEG(jpeg)).toMatchObject({ width: 1, height: 1 });
    expect(admitBrowserJPEG(Buffer.from("jpeg"))).toBeUndefined();
    expect(admitBrowserJPEG(Buffer.alloc(2 * 1_024 * 1_024 + 1))).toBeUndefined();
    const f = fixture();
    for (const endpoint of ["ws://example.com:1234/devtools/browser/12345678-1234-1234-1234-123456789abc", `${registration.cdpUrl}?control=1`, registration.cdpUrl.replace("12345678-1234-1234-1234-123456789abc", "aaaaaaaaaaaaaaaa")]) {
      expect(() => f.registry.register({ ...registration, cdpUrl: endpoint, loadToken: f.loadToken })).toThrow();
    }
  });
});

describe("trusted browser result admission", () => {
  it("uses normalized executed commands, reuses descriptors, and fences every late effect", () => {
    const f = fixture();
    const input = { owner: { id: "extension:browser", title: "Browser", source: "git:github.com/fitchmultz/pi-agent-browser-native" },
      toolName: "agent_browser", toolCallId: "browser-call", sessionId: registration.sessionId, runtimeGeneration: "runtime-a", loadToken: f.loadToken, views: f.registry,
      result: { content: [], isError: false, details: { args: ["--session", "managed-a", "get", "cdp-url"], command: "get", subcommand: "cdp-url",
        resultCategory: "success", exitCode: 0, agentBrowserStarted: true, sessionName: "managed-a", data: { cdpUrl: registration.cdpUrl } } } };
    const adapted = observeTrustedAgentBrowserResult(input) as { details: { browserLiveView: { viewId: string; generation: string } } };
    const descriptor = adapted.details.browserLiveView;
    expect(descriptor.viewId).toEqual(expect.any(String));
    expect(observeTrustedAgentBrowserResult(input)).toEqual(adapted);
    expect(observeTrustedAgentBrowserResult({ ...input, owner: { ...input.owner, source: "local" } })).toBe(input.result);
    const token = f.registry.beginSessionLoad(registration.sessionId);
    const current = f.registry.register({ ...registration, loadToken: token });
    observeTrustedAgentBrowserResult({ ...input, result: { ...input.result, details: { ...input.result.details, command: "close" } } });
    expect(f.registry.describe(registration.sessionId, current.viewId, current.generation)).toEqual(current);
    expect(observeTrustedAgentBrowserResult(input)).toBe(input.result);
  });
});
