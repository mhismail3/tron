import { beforeEach, describe, expect, it, vi } from "vitest";
const state = vi.hoisted(() => ({ clients: [] as any[] }));
vi.mock("../machine/cua-client.js", () => ({ CuaComputerClient: class {
  invoke = vi.fn(async () => ({ status: "completed", endpointGeneration: "host", output: { value: "observed" }, image: { type: "image", data: "fixture", mimeType: "image/png" } }));
  close = vi.fn(async () => {});
  invalidateObservation = vi.fn();
  constructor(readonly binding: unknown) { state.clients.push(this); }
} }));
import { createTronComputerExtension } from "./tron-computer-extension.js";
beforeEach(() => { state.clients.length = 0; });
function fixture() {
  let tool: any; const handlers = new Map<string, () => Promise<void>>();
  createTronComputerExtension({ sessionId: () => "canonical" })({ registerTool(value: unknown) { tool = value; }, on(name: string, handler: () => Promise<void>) { handlers.set(name, handler); } } as any);
  return { tool, handlers, client: state.clients.at(-1)! };
}
describe("first-party computer extension", () => {
  it("gives each extension load an independent canonical binding, not a global client", () => {
    const a = fixture(), b = fixture();
    expect(a.client.binding.canonicalSessionID).toBe("canonical");
    expect(b.client.binding.runtimeLoadID).not.toBe(a.client.binding.runtimeLoadID);
    expect(a.client.invoke).not.toHaveBeenCalled();
    a.handlers.get("before_agent_start")!();
    expect(a.client.invalidateObservation).toHaveBeenCalledOnce();
  });
  it("passes cancellation through, emits actual image content, and does not duplicate image bytes in details", async () => {
    const f = fixture(), abort = new AbortController();
    const result = await f.tool.execute("call", { tool: "get_window_state", arguments: { pid: 123 } }, abort.signal);
    expect(f.client.invoke).toHaveBeenCalledWith("get_window_state", { pid: 123 }, abort.signal);
    expect(result.content).toContainEqual({ type: "image", data: "fixture", mimeType: "image/png" });
    expect(result.details).not.toHaveProperty("image");
  });
  it("the SDK shutdown handler awaits client retirement", async () => {
    const f = fixture(); let release!: () => void;
    f.client.close.mockImplementation(() => new Promise<void>((resolve) => { release = resolve; }));
    let done = false; const closing = f.handlers.get("session_shutdown")!().then(() => { done = true; });
    await Promise.resolve(); expect(done).toBe(false);
    release(); await closing; expect(done).toBe(true);
  });
  it("returns refusal as an actual tool error and clearly labels uncertain effects", async () => {
    const f = fixture();
    f.client.invoke.mockResolvedValueOnce({ status: "refused", endpointGeneration: "host", output: { code: "stale" } });
    await expect(f.tool.execute("refused", { tool: "click", arguments: {} })).rejects.toThrow(/refused/);
    f.client.invoke.mockResolvedValueOnce({ status: "outcomeUnknown", endpointGeneration: "host", output: { effect: "unverifiable" } });
    const result = await f.tool.execute("uncertain", { tool: "click", arguments: {} });
    expect(result.content[0].text).toContain("not verified");
    expect(f.tool.promptGuidelines.join(" ")).toContain("system dialogs");
  });
});
