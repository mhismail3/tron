import { afterEach, describe, expect, it } from "vitest";
import { BrowserLiveViewRegistry } from "./browser-live-view.js";
import { observeTrustedAgentBrowserResult } from "./browser-live-view-adapter.js";
import { admitToolDisplayProjection } from "./display-contract.js";

const views = new BrowserLiveViewRegistry(() => { throw new Error("Tool metadata must not connect"); });
afterEach(() => views.dispose());
const endpoint = "ws://127.0.0.1:9222/devtools/browser/12345678-1234-4234-8234-123456789abc";
function fixture() {
  const loadToken = views.beginSessionLoad("session");
  return (toolCallId: string, cdpUrl = endpoint, state = "active", isError = false) => {
    const result = { content: [], isError, details: { command: "click", sessionName: "managed", agentBrowserStarted: true,
      resultCategory: isError ? "failure" : "success", exitCode: isError ? 1 : 0,
      browserBinding: { schema: "agent-browser.browser-binding.v1", cdpUrl, state, session: "native-managed", owned: true } } };
    return observeTrustedAgentBrowserResult({ owner: { id: "browser", title: "Browser", source: "git:github.com/fitchmultz/pi-agent-browser-native" },
      toolName: "agent_browser", toolCallId,
      result: state === "explicit-get" ? { ...result, details: { ...result.details, browserBinding: undefined,
        command: "get", subcommand: "cdp-url", data: { cdpUrl } } } : result, sessionId: "session", runtimeGeneration: "runtime", loadToken, views }) as typeof result & { details: Record<string, unknown> };
  };
}

describe("canonical browser action references", () => {
  it("routes successful and failed actions to one exact floating browser without observation", () => {
    const action = fixture();
    const first = admitToolDisplayProjection("agent_browser", action("open").details, "open", "session")!;
    const failed = admitToolDisplayProjection("agent_browser", action("failed", endpoint, "active", true).details, "failed", "session")!;
    expect(first.presentation.requestedSurface).toBe("floating");
    expect(failed.liveView).toEqual(first.liveView);
    expect(first.kind).toBe("browser_live");
    expect(views.describe("session", first.liveView!.viewId, first.liveView!.generation)).toEqual(first.liveView);
  });

  it("deduplicates explicit-get and native-bound aliases by the exact endpoint and closes that same view", () => {
    const action = fixture();
    const explicit = admitToolDisplayProjection("agent_browser", action("get", endpoint, "explicit-get").details, "get", "session")!;
    const native = admitToolDisplayProjection("agent_browser", action("click").details, "click", "session")!;
    expect(native.liveView).toEqual(explicit.liveView);
    const closed = admitToolDisplayProjection("agent_browser", action("close", endpoint, "closed").details, "close", "session")!;
    expect(closed.liveView).toEqual(explicit.liveView);
    const again = admitToolDisplayProjection("agent_browser", action("closed-again", endpoint, "closed").details, "closed-again", "session")!;
    expect(again.liveView).toEqual(explicit.liveView);
    expect(() => views.describe("session", explicit.liveView!.viewId, explicit.liveView!.generation)).toThrow();
  });

  it("rejects copied calls/sessions, changed descriptors and unsealed matching details", () => {
    const result = fixture()("call");
    expect(admitToolDisplayProjection("agent_browser", result.details, "other", "session")).toBeUndefined();
    expect(admitToolDisplayProjection("agent_browser", result.details, "call", "other-session")).toBeUndefined();
    expect(admitToolDisplayProjection("agent_browser", result.details, "call")).toBeUndefined();
    const changedPolicy = structuredClone(result.details) as any;
    changedPolicy.tronBrowserReference.automatic = false;
    expect(admitToolDisplayProjection("agent_browser", changedPolicy, "call", "session")).toBeUndefined();
    expect(admitToolDisplayProjection("other-tool", result.details, "call", "session")).toBeUndefined();
    const copied = structuredClone(result.details) as any;
    copied.tronBrowserReference.descriptor.generation = "successor";
    expect(admitToolDisplayProjection("agent_browser", copied, "call", "session")).toBeUndefined();
    const unsealed = { ...result.details, tronBrowserReference: undefined };
    expect(admitToolDisplayProjection("agent_browser", unsealed, "call", "session")).toBeUndefined();
  });

  it("retires only the observed generation; old chips and delayed closes never retarget", () => {
    const action = fixture();
    const old = admitToolDisplayProjection("agent_browser", action("old").details, "old", "session")!.liveView!;
    const nextEndpoint = endpoint.replace("123456789abc", "123456789def");
    const current = admitToolDisplayProjection("agent_browser", action("new", nextEndpoint).details, "new", "session")!.liveView!;
    expect(old.viewId).not.toBe(current.viewId);
    action("late-close", endpoint, "closed");
    expect(() => views.describe("session", old.viewId, old.generation)).toThrow();
    expect(admitToolDisplayProjection("agent_browser", action("late-active").details, "late-active", "session")).toBeUndefined();
    expect(views.describe("session", current.viewId, current.generation)).toEqual(current);
    const closed = admitToolDisplayProjection("agent_browser", action("close", nextEndpoint, "closed").details, "close", "session")!;
    expect(closed.liveView).toEqual(current);
    expect(closed.presentation.requestedSurface).toBe("sheet"); // manual activation, not a dead-browser popup
    expect(() => views.describe("session", current.viewId, current.generation)).toThrow();
  });

  it("a delayed first observation cannot replace an unrelated newer exact browser", () => {
    const action = fixture();
    const nextEndpoint = endpoint.replace("123456789abc", "123456789def");
    const current = admitToolDisplayProjection("agent_browser", action("new", nextEndpoint).details, "new", "session")!.liveView!;
    action("delayed-first-observation");
    expect(views.describe("session", current.viewId, current.generation)).toEqual(current);
  });

  it("a close received before any active result still fences late admission", () => {
    const action = fixture();
    const first = admitToolDisplayProjection("agent_browser", action("close-first", endpoint, "closed").details, "close-first", "session")!;
    const again = admitToolDisplayProjection("agent_browser", action("close-again", endpoint, "closed").details, "close-again", "session")!;
    expect(again.liveView).toEqual(first.liveView);
    expect(again.presentation.requestedSurface).toBe("sheet");
    expect(admitToolDisplayProjection("agent_browser", action("late").details, "late", "session")).toBeUndefined();
  });

  it("retirement receipts remain bounded and never evict a fence to admit a new generation", () => {
    const token = views.beginSessionLoad("session");
    const current = { sessionId: "session", viewId: "view", generation: "current", cdpUrl: endpoint, loadToken: token };
    const descriptor = views.register(current);
    for (let i = 1; i < 4096; i++) views.retireBrowser({ ...current, viewId: `closed-${i}`, generation: `closed-${i}` });
    expect(views.register(current)).toEqual(descriptor);
    expect(() => views.register({ ...current, viewId: "next", generation: "next" })).toThrow("generation capacity");
    expect(() => views.retireBrowser({ ...current, generation: "new-close" })).toThrow("generation capacity");
    const closed = views.retireBrowser(current);
    expect(closed).toEqual(descriptor);
    closed.viewId = "mutated-projection";
    expect(views.retireBrowser({ ...current, viewId: "another-alias" })).toEqual(descriptor);
    const nextLoad = views.beginSessionLoad("session");
    expect(views.register({ ...current, loadToken: nextLoad })).toEqual(descriptor);
  });

  it("never admits remote/page endpoints, including closed or forged lifecycle data", () => {
    const action = fixture();
    for (const state of ["active", "closed"]) {
      for (const url of ["wss://remote.invalid/browser", endpoint + "?token=secret", endpoint.replace("/browser/", "/page/"),
        endpoint.replace("127.0.0.1", "127.0.0.01"), ` ${endpoint}`, endpoint.replace(":9222", ":09222")]) {
        expect(admitToolDisplayProjection("agent_browser", action("call", url, state).details, "call", "session")).toBeUndefined();
      }
    }
  });
});
