import { visibleWidth, type Component } from "@earendil-works/pi-tui";
import { describe, expect, it, vi } from "vitest";
import { ExtensionPresentationStore } from "./extension-presentation-store.js";
import { MAX_HOST_COMPONENTS, RemotePiExtensionHost, widgetSurfaceId } from "./remote-pi-extension-host.js";
import type { SemanticUIBroker } from "../../sessions/semantic-ui-broker.js";

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((res, rej) => { resolve = res; reject = rej; });
  return { promise, resolve, reject };
}
function component(lines: string[], dispose = vi.fn()): Component & { dispose: () => void } {
  return { render: vi.fn(() => lines), invalidate: vi.fn(), dispose };
}
function fixture() {
  const events: unknown[] = [];
  const presentation = new ExtensionPresentationStore((_topic, payload) => events.push(payload));
  const context = {
    ...({} as ReturnType<SemanticUIBroker["context"]>),
    theme: undefined,
    setWidget: vi.fn(),
    setToolsExpanded: vi.fn(),
  };
  const semantic = { presentation, context: () => context } as unknown as SemanticUIBroker;
  const host = new RemotePiExtensionHost(semantic);
  return { host, presentation, events, context };
}

describe("RemotePiExtensionHost retained component foundation", () => {
  it("forwards native tools-expanded changes and schedules a rerender", async () => {
    const { host, context } = fixture();
    host.context().setToolsExpanded(true);
    expect(context.setToolsExpanded).toHaveBeenCalledWith(true);
  });

  it("lazily starts, mounts sync factories, captures one render, and publishes bounded frames", async () => {
    const { host, presentation, events } = fixture();
    const original = component(["hello", "\u001b[31mworld\u001b[0m"]);
    const context = host.context();
    expect(host.isTuiStarted).toBe(false);
    context.setWidget("one", (() => original) as never, { placement: "belowEditor" });
    expect(host.isTuiStarted).toBe(true);
    await Promise.resolve();
    const surface = presentation.state().surfaces[0];
    expect(surface).toMatchObject({ id: widgetSurfaceId("one"), kind: "widget", frame: { plainText: "hello\nworld" } });
    expect(surface?.placement).toBe("belowEditor");
    expect(original.render).toHaveBeenCalledTimes(1);
    expect(events.length).toBeGreaterThan(0);
    host.requestRender();
    await new Promise((resolve) => setTimeout(resolve, 25));
    expect(original.render).toHaveBeenCalledTimes(2);
    expect(events.length).toBe(1);
    expect(host.resize(100, 20)).toBe(true);
    await new Promise((resolve) => setTimeout(resolve, 25));
    expect(original.render).toHaveBeenCalledTimes(3);
    expect(presentation.state().surfaces[0]?.frame.width).toBe(100);
    expect(events.length).toBe(2);
    host.retire();
  });

  it("namespaces every opaque widget key without surface collisions", async () => {
    const { host, presentation } = fixture();
    const keys = ["foo", "widget:foo", "custom:c1"];
    for (const key of keys) host.context().setWidget(key, (() => component([key])) as never);
    await Promise.resolve();
    const surfaces = presentation.state().surfaces.filter((surface) => surface.kind === "widget");
    expect(new Set(surfaces.map((surface) => surface.id)).size).toBe(keys.length);
    expect(surfaces.map((surface) => surface.frame.plainText).sort()).toEqual(keys.sort());
    expect(surfaces.every((surface) => surface.id.startsWith("widget:"))).toBe(true);
    host.retire();
  });

  it("does not mount stale async factories and disposes late results exactly once", async () => {
    const { host, presentation } = fixture();
    const first = deferred<Component>();
    const firstDispose = vi.fn();
    const second = component(["new"]);
    const context = host.context();
    context.setWidget("same", (() => first.promise) as never);
    context.setWidget("same", (() => second) as never);
    await Promise.resolve();
    first.resolve(component(["old"], firstDispose));
    await Promise.resolve();
    expect(firstDispose).toHaveBeenCalledTimes(1);
    expect(presentation.state().surfaces[0]?.frame.plainText).toBe("new");
    expect(second.render).toHaveBeenCalledTimes(1);
    const rejected = deferred<Component>();
    context.setWidget("reject", (() => rejected.promise) as never);
    context.setWidget("reject", (() => component(["replacement"])) as never);
    rejected.reject(new Error("late rejection"));
    await Promise.resolve();
    expect(presentation.state().surfaces.some((surface) => surface.id === widgetSurfaceId("reject"))).toBe(true);
    host.retire();
  });

  it("publishes bounded fallbacks for throwing, rejecting, and invalid factories", async () => {
    const { host, presentation } = fixture();
    const context = host.context();
    context.setWidget("throwing", (() => { throw new Error("factory exploded"); }) as never);
    await Promise.resolve();
    expect(presentation.state().surfaces.find((surface) => surface.id === widgetSurfaceId("throwing"))?.frame.plainText)
      .toContain("Extension component unavailable");
    expect(presentation.state().diagnostics.some((diagnostic) => diagnostic.code === "component.render-failed")).toBe(true);

    const rejected = deferred<Component>();
    context.setWidget("rejected", (() => rejected.promise) as never);
    rejected.reject(new Error("factory rejected"));
    await Promise.resolve();
    expect(presentation.state().surfaces.find((surface) => surface.id === widgetSurfaceId("rejected"))?.frame.plainText)
      .toContain("Extension component unavailable");

    context.setWidget("invalid", (() => ({}) as Component) as never);
    await Promise.resolve();
    await new Promise((resolve) => setTimeout(resolve, 5));
    expect(presentation.state().surfaces.find((surface) => surface.id === widgetSurfaceId("invalid"))?.frame.plainText)
      .toContain("Extension component unavailable");
    host.retire();
  });

  it("publishes wide-Unicode factory diagnostics as protocol-valid bounded frames", async () => {
    const { host, presentation } = fixture();
    const wideMessage = `界`.repeat(200) + "👨‍👩‍👧‍👦e\u0301";
    host.context().setWidget("wide", (() => { throw new Error(wideMessage); }) as never);
    await Promise.resolve();

    const surface = presentation.state().surfaces.find((candidate) => candidate.id === widgetSurfaceId("wide"));
    expect(surface).toBeDefined();
    expect(surface?.frame.lines).toHaveLength(surface?.frame.height);
    expect(surface?.frame.plainText).toBe(surface?.frame.lines.map((line) => line.plainText).join("\n"));
    expect(surface?.frame.lines[0]?.plainText).toBe(surface?.frame.lines[0]?.runs.map((run) => run.text).join());
    expect(visibleWidth(surface?.frame.plainText ?? "")).toBeLessThanOrEqual(surface?.frame.width ?? 160);
    expect(surface?.frame.width).toBeLessThanOrEqual(160);
    expect(surface?.frame.plainText).not.toMatch(/[\u0000-\u001f\u007f-\u009f]/);
    host.retire();
  });

  it("preserves content while replacing, tracks placement changes, retries failed publication, and retires atomically", async () => {
    const { host, presentation } = fixture();
    const context = host.context();
    context.setWidget("one", (() => component(["stable"])) as never, { placement: "aboveEditor" });
    context.setWidget("two", (() => component(["second"])) as never, { placement: "belowEditor" });
    await Promise.resolve();
    expect(presentation.state().surfaces).toHaveLength(2);

    context.setWidget("one", (() => component(["stable"])) as never, { placement: "belowEditor" });
    await Promise.resolve();
    expect(presentation.state().surfaces.find((surface) => surface.id === widgetSurfaceId("one"))?.placement).toBe("belowEditor");

    let retryLines = ["stable"];
    const retrying = component(retryLines);
    context.setWidget("retry", (() => retrying) as never);
    await Promise.resolve();
    retryLines = ["changed"];
    retrying.render.mockImplementation(() => retryLines);
    const transact = vi.spyOn(presentation, "transact").mockImplementationOnce(() => { throw new Error("temporary capacity"); });
    host.requestRender(true);
    await new Promise((resolve) => setTimeout(resolve, 25));
    expect(presentation.state().surfaces.find((surface) => surface.id === widgetSurfaceId("one"))?.frame.plainText).toBe("stable");
    host.requestRender(true);
    await new Promise((resolve) => setTimeout(resolve, 25));
    expect(transact).toHaveBeenCalled();
    expect(presentation.state().surfaces.find((surface) => surface.id === widgetSurfaceId("one"))?.frame.plainText).toBe("stable");
    transact.mockRestore();

    host.retire();
    expect(presentation.state().surfaces).toEqual([]);
    expect(presentation.hasPendingComponentFactory).toBe(false);
    expect(presentation.hasScheduledRender).toBe(false);
  });

  it("balances resize activity and coalesces render storms", async () => {
    const { host, presentation } = fixture();
    const render = vi.fn(() => ["storm"]);
    host.context().setWidget("storm", (() => ({ render, invalidate: vi.fn() })) as never);
    await new Promise((resolve) => setTimeout(resolve, 25));
    const before = render.mock.calls.length;
    expect(host.resize(120, 30)).toBe(true);
    expect(presentation.hasScheduledRender).toBe(true);
    for (let index = 0; index < 50; index += 1) host.requestRender();
    await new Promise((resolve) => setTimeout(resolve, 40));
    expect(render.mock.calls.length).toBe(before + 1);
    expect(presentation.hasScheduledRender).toBe(false);
    host.retire();
  });

  it("removes components, tolerates throwing disposal, coalesces renders, and balances activity", async () => {
    const { host, presentation } = fixture();
    const dispose = vi.fn(() => { throw new Error("dispose failed"); });
    const original = component(["stable"], dispose);
    const context = host.context();
    context.setWidget("x", (() => original) as never);
    await Promise.resolve();
    const count = original.render.mock.calls.length;
    host.requestRender(); host.requestRender(); host.requestRender();
    await new Promise((resolve) => setTimeout(resolve, 25));
    expect(original.render.mock.calls.length).toBe(count + 1);
    context.setWidget("x", undefined);
    expect(dispose).toHaveBeenCalledTimes(1);
    expect(presentation.state().surfaces).toEqual([]);
    expect(presentation.hasPendingComponentFactory).toBe(false);
    expect(presentation.hasScheduledRender).toBe(false);
    host.retire();
  });

  it("rejects direct host admission at capacity before invoking factories and releases capacity", async () => {
    const { host } = fixture();
    const calls = Array.from({ length: MAX_HOST_COMPONENTS + 1 }, () => vi.fn(() => component(["bounded"])));
    for (let index = 0; index < MAX_HOST_COMPONENTS; index += 1) host.context().setWidget(`bounded-${index}`, calls[index] as never);
    await Promise.resolve();
    host.context().setWidget("overflow", calls[MAX_HOST_COMPONENTS] as never);
    expect(calls[MAX_HOST_COMPONENTS]).not.toHaveBeenCalled();
    host.context().setWidget("bounded-0", undefined);
    host.context().setWidget("released", calls[MAX_HOST_COMPONENTS] as never);
    expect(calls[MAX_HOST_COMPONENTS]).toHaveBeenCalledTimes(1);
    host.retire();
  });

  it("bounds unresolved replaced factories before invoking more work", async () => {
    const { host, presentation } = fixture();
    const pending = Array.from({ length: MAX_HOST_COMPONENTS }, () => deferred<Component>());
    const factories = pending.map((item) => vi.fn(() => item.promise));
    for (const factory of factories) host.context().setWidget("same-key", factory as never);
    expect(presentation.hasPendingComponentFactory).toBe(true);
    const overflow = vi.fn(() => component(["overflow"]));
    host.context().setWidget("same-key", overflow as never);
    expect(overflow).not.toHaveBeenCalled();
    for (const item of pending) item.resolve(component(["settled"]));
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(presentation.hasPendingComponentFactory).toBe(false);
    host.context().setWidget("same-key", overflow as never);
    expect(overflow).toHaveBeenCalledTimes(1);
    host.retire();
  });

  it("supports one blocking custom component with first-wins settlement", async () => {
    const { host, presentation } = fixture();
    const base = component(["base"]);
    host.context().setWidget("base", (() => base) as never);
    await Promise.resolve();
    const custom = component(["dialog"]);
    let done!: (value: string) => void;
    const result = host.context().custom<string>((tui, theme, keybindings, complete) => {
      void tui; void theme; void keybindings; done = complete;
      return custom;
    });
    await Promise.resolve();
    expect(presentation.state().surfaces.find((surface) => surface.id.startsWith("custom:"))).toMatchObject({
      kind: "custom", placement: "fullscreen", lifecycle: "blocking", inputMode: "keys",
    });
    expect(presentation.hasBlockingPresentation).toBe(true);
    done("accepted"); done("ignored");
    await expect(result).resolves.toBe("accepted");
    expect(custom.dispose).toHaveBeenCalledTimes(1);
    expect(presentation.state().surfaces.some((surface) => surface.kind === "custom")).toBe(false);
    expect(presentation.hasBlockingPresentation).toBe(false);
    host.retire();
  });

  it("settles async custom races and disposes late components exactly once", async () => {
    const { host, presentation } = fixture();
    const pending = deferred<Component>();
    let done!: (value: number) => void;
    const result = host.context().custom<number>((_tui, _theme, _keys, complete) => {
      done = complete;
      return pending.promise;
    });
    done(7);
    await expect(result).resolves.toBe(7);
    expect(presentation.hasPendingComponentFactory).toBe(true);
    await expect(host.context().custom(() => component(["blocked until settle"]))).rejects.toThrow("one blocking custom");
    const lateDispose = vi.fn();
    pending.resolve(component(["late"], lateDispose));
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(presentation.hasPendingComponentFactory).toBe(false);
    expect(lateDispose).toHaveBeenCalledTimes(1);
    expect(presentation.state().surfaces.some((surface) => surface.kind === "custom")).toBe(false);

    const rejection = deferred<Component>();
    const failed = host.context().custom<string>(() => rejection.promise);
    rejection.reject(new Error("custom failed"));
    await expect(failed).rejects.toThrow("custom failed");
    expect(presentation.state().surfaces.some((surface) => surface.kind === "custom")).toBe(false);
    host.retire();
  });

  it("keeps retired async factories operational until settlement and disposes late results", async () => {
    const { host, presentation } = fixture();
    const pending = deferred<Component>();
    const result = host.context().custom<string>(() => pending.promise);
    expect(presentation.hasPendingComponentFactory).toBe(true);
    host.retire();
    await expect(result).rejects.toThrow("retired");
    expect(presentation.hasPendingComponentFactory).toBe(false);
    const lateDispose = vi.fn();
    pending.resolve(component(["late"], lateDispose));
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(lateDispose).toHaveBeenCalledTimes(1);
  });

  it("fails overlay custom calls closed before invoking the factory", async () => {
    const { host, presentation } = fixture();
    const factory = vi.fn(() => component(["must not mount"]));
    await expect(host.context().custom(() => factory(), { overlay: true })).rejects.toThrow("deferred");
    expect(factory).not.toHaveBeenCalled();
    expect(presentation.state().surfaces).toEqual([]);
    expect(presentation.state().diagnostics.some((item) => item.message.includes("Overlay extension UI is deferred"))).toBe(true);
  });

  it("rejects concurrent custom ownership and admits a later call after settlement", async () => {
    const { host } = fixture();
    const pending = deferred<Component>();
    const first = host.context().custom<string>(() => pending.promise);
    const secondFactory = vi.fn(() => component(["second"]));
    await expect(host.context().custom(() => secondFactory())).rejects.toThrow("one blocking custom");
    expect(secondFactory).not.toHaveBeenCalled();
    pending.resolve(component(["first"]));
    await Promise.resolve();
    host.retire();
    await expect(first).rejects.toThrow("retired");
  });

  it("rejects and disposes a custom when mounting throws", async () => {
    const { host, presentation } = fixture();
    const disposable = vi.fn();
    const value = component(["mount"], disposable);
    const result = host.context().custom<string>(() => value);
    const screen = (host as unknown as { screen: { addChild: () => void } }).screen;
    vi.spyOn(screen, "addChild").mockImplementationOnce(() => { throw new Error("mount failed"); });
    await expect(result).rejects.toThrow("mount failed");
    expect(disposable).toHaveBeenCalledTimes(1);
    expect(presentation.hasBlockingPresentation).toBe(false);
    host.retire();
  });

  it("provides a real public pi-tui keybindings manager to custom factories", async () => {
    const { host } = fixture();
    let done!: (value: string) => void;
    const result = host.context().custom<string>((_tui, _theme, keybindings, complete) => {
      expect(typeof keybindings.getKeys).toBe("function");
      done = complete;
      return component(["keys"]);
    });
    await Promise.resolve();
    done("ok");
    await expect(result).resolves.toBe("ok");
    host.retire();
  });

  it("publishes a sanitized fallback when rendering fails and rejects stale epoch work", async () => {
    const { host, presentation } = fixture();
    const bad = component(["\u001b[31m".repeat(100_000)]);
    contextSet(host, "bad", bad);
    await Promise.resolve();
    const surface = presentation.state().surfaces[0];
    expect(surface?.frame.plainText).toContain("Extension component unavailable");
    expect(surface?.frame.plainText).not.toContain("\u001b");
    host.retire();
    expect(() => host.requestRender()).not.toThrow();
  });
});

function contextSet(host: RemotePiExtensionHost, key: string, value: Component): void {
  host.context().setWidget(key, (() => value) as never);
}
