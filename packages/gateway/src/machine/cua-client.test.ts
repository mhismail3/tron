import { randomUUID } from "node:crypto";
import { writeFile } from "node:fs/promises";
import { describe, expect, it, vi } from "vitest";
import { CuaComputerClient, parseCuaOutput } from "./cua-client.js";

const binding = () => ({ canonicalSessionID: "fixture-session", runtimeLoadID: randomUUID() });
const snapshot = { pid: 123, window_id: 456, snapshot_id: "s00000001", elements: [{ element_token: "s00000001:1" }] };
function fixture() {
  const generation = randomUUID(), endpoint = { socket: `/tmp/tron-cua-${generation}/s`, generation };
  const nativeClose = vi.fn(async () => {});
  const open = vi.fn(async () => ({ automationEndpoint: async () => endpoint, close: nativeClose }));
  const run = vi.fn(async (_path: string, args: string[], _options: unknown) => ({ stdout: JSON.stringify(args[1] === "end_session" ? { active: false } : snapshot), stderr: "" }));
  const owner = binding(), client = new CuaComputerClient(owner, "/fixture/cua-driver", open as never, run as never);
  return { client, owner, endpoint, open, nativeClose, run };
}
async function observe(f: ReturnType<typeof fixture>) {
  await f.client.invoke("get_window_state", { pid: 123, window_id: 456, include_screenshot: false });
}

describe("Cua session/load adapter", () => {
  it("is inert until observation, binds once, injects session identity and sends no cancellation kill options", async () => {
    const f = fixture(); expect(f.open).not.toHaveBeenCalled();
    expect(() => f.client.invoke("click", { pid: 123 })).toThrow(/Observe/);
    await observe(f); f.run.mockResolvedValue({ stdout: '{"effect":"confirmed"}', stderr: "" });
    await f.client.invoke("click", { pid: 123, window_id: 456, element_token: "s00000001:1" });
    expect(f.open).toHaveBeenCalledExactlyOnceWith(f.owner); expect(f.nativeClose).toHaveBeenCalledOnce();
    expect(JSON.parse(f.run.mock.calls[1]![1][2]!)).toMatchObject({ session: f.owner.runtimeLoadID });
    expect(f.run.mock.calls[1]![1].slice(-2)).toEqual(["--socket", f.endpoint.socket]);
    expect(f.run.mock.calls[1]![2]).not.toHaveProperty("signal"); expect(f.run.mock.calls[1]![2]).not.toHaveProperty("timeout");
    expect(() => f.client.invoke("click", { pid: 123 })).toThrow(/Observe/);
  });
  it.each(["browser_click", "config", "history_enable", "run_shell", "unknown_new_tool"])("does not expose backend/admin surface %s", (tool) => {
    const f = fixture(); expect(() => f.client.invoke(tool, {})).toThrow(/not available/); expect(f.open).not.toHaveBeenCalled();
  });
  it.each(["session", "socket", "env", "_session_id", "screenshot_out_file"])("rejects caller-controlled %s", (key) => {
    const f = fixture(); expect(() => f.client.invoke("get_window_state", { [key]: "injected" })).toThrow(/reserved/);
  });
  it("rejects references from another observation and requires desktop inspection before foreground input", async () => {
    const f = fixture(); await observe(f);
    expect(() => f.client.invoke("click", { element_token: "s00000002:1" })).toThrow(/does not belong/);
    expect(() => f.client.invoke("click", { pid: 999, element_token: "s00000001:1" })).toThrow(/does not belong/);
    expect(() => f.client.invoke("hotkey", { pid: 123, keys: ["cmd", "a"], delivery_mode: "foreground" })).toThrow(/full desktop/);
    expect(() => f.client.invoke("click", { pid: 123, window_id: 456, x: 1, y: 1 })).toThrow(/inspect pixels/);
  });
  it("metadata help is inert and failed observation cannot fall back to prior references", async () => {
    const f = fixture();
    await f.client.invoke("help", {}); expect(f.open).not.toHaveBeenCalled(); expect(f.run).not.toHaveBeenCalled();
    f.run.mockResolvedValueOnce({ stdout: "drag schema", stderr: "" });
    expect((await f.client.invoke("help", { tool: "drag" })).output).toEqual({ documentation: "drag schema" });
    expect(f.open).not.toHaveBeenCalled();
    await observe(f); f.run.mockResolvedValueOnce({ stdout: '{"status":"refused"}', stderr: "" });
    expect((await f.client.invoke("get_window_state", { pid: 123, window_id: 999, include_screenshot: false })).status).toBe("refused");
    expect(() => f.client.invoke("click", { element_token: "s00000001:1" })).toThrow(/Observe/);
  });
  it("a cancelled accepted call remains pending until the real process result, with no replay", async () => {
    const f = fixture(); await observe(f);
    let finish!: (result: { stdout: string; stderr: string }) => void;
    f.run.mockImplementation(() => new Promise((resolve) => { finish = resolve; }));
    const abort = new AbortController(), work = f.client.invoke("click", { element_token: "s00000001:1" }, abort.signal);
    const rejected = expect(work).rejects.toThrow(/may have completed/);
    abort.abort(); let ended = false; void work.catch(() => { ended = true; });
    await Promise.resolve(); expect(ended).toBe(false);
    finish({ stdout: '{"effect":"unverifiable"}', stderr: "" }); await rejected;
    expect(f.run).toHaveBeenCalledTimes(2);
    expect(() => f.client.invoke("click", {})).toThrow(/Observe/);
  });
  it("failed endpoint is not refreshed by another action; explicit observation can establish a successor", async () => {
    const f = fixture(); await observe(f);
    f.run.mockRejectedValueOnce(new Error("socket gone"));
    await expect(f.client.invoke("click", { element_token: "s00000001:1" })).rejects.toThrow(/uncertain/);
    expect(() => f.client.invoke("click", {})).toThrow(/Observe/); expect(f.open).toHaveBeenCalledOnce();
    await observe(f); expect(f.open).toHaveBeenCalledTimes(2);
  });
  it("shutdown joins pending work and then closes only its bound session", async () => {
    const f = fixture(); await observe(f);
    let finish!: (result: { stdout: string; stderr: string }) => void;
    f.run.mockImplementationOnce(() => new Promise((resolve) => { finish = resolve; }));
    const work = f.client.invoke("click", { element_token: "s00000001:1" }); const rejected = expect(work).rejects.toThrow();
    const closed = f.client.close(); expect(f.client.close()).toBe(closed);
    let ended = false; void closed.then(() => { ended = true; }); await Promise.resolve(); expect(ended).toBe(false);
    finish({ stdout: '{}', stderr: "" }); await rejected; await closed;
    const args = f.run.mock.calls.at(-1)![1]; expect(args[1]).toBe("end_session");
    expect(JSON.parse(args[2]!)).toEqual({ session: f.owner.runtimeLoadID });
  });
  it("joins driver-declared pending cleanup without replaying an input operation", async () => {
    const f = fixture(); await observe(f);
    f.run.mockResolvedValueOnce({ stdout: '{"code":"session_cleanup_pending","cleanup_in_progress":true}', stderr: "" });
    const closing = f.client.close(); expect(f.client.close()).toBe(closing);
    await closing;
    expect(f.run.mock.calls.slice(1).map((call) => call[1][1])).toEqual(["end_session", "end_session"]);
  });
  it("returns bounded image bytes, strips disposable paths and admits full-desktop inspection", async () => {
    const f = fixture(); const png = Buffer.alloc(24); Buffer.from([137,80,78,71,13,10,26,10]).copy(png); png.writeUInt32BE(1,16); png.writeUInt32BE(1,20);
    f.run.mockImplementation(async (_path, argv) => {
      const args = JSON.parse(argv[2]!); await writeFile(args.screenshot_out_file, png);
      return { stdout: JSON.stringify({ screenshot_file_path: args.screenshot_out_file, screenshot_width: 1, screenshot_height: 1 }), stderr: "" };
    });
    const result = await f.client.invoke("get_desktop_state", {});
    expect(result.image).toMatchObject({ type: "image", mimeType: "image/png", data: png.toString("base64") });
    expect(result.output).not.toHaveProperty("screenshot_file_path");
    f.run.mockResolvedValue({ stdout: '{"effect":"unverifiable"}', stderr: "" });
    expect((await f.client.invoke("hotkey", { pid: 123, window_id: 456, keys: ["cmd","a"], delivery_mode: "foreground" })).status).toBe("outcomeUnknown");
  });
  it.each([
    ['{"code":"background_unavailable"}', "refused"], ['{"refusal":{"code":"stale_element_token"},"status":"refused"}', "refused"],
    ['{"effect":"unverifiable"}', "outcomeUnknown"], ['{"effect":"partial"}', "outcomeUnknown"], ['{"effect":"confirmed"}', "completed"],
  ])("does not confuse exit-zero payload %s with verified success", (wire, status) => {
    expect(parseCuaOutput(wire, "generation").status).toBe(status);
  });
});
