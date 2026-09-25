import { randomUUID } from "node:crypto";
import { access, mkdir, mkdtemp, realpath, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";
import { CuaComputerClient } from "./cua-client.js";

const binding = () => ({ canonicalSessionID: "fixture-session", runtimeLoadID: randomUUID() });
const snapshot = { pid: 123, window_id: 456, snapshot_id: "s00000001", elements: [{ element_token: "s00000001:1" }] };
function fixture() {
  const generation = randomUUID(), endpoint = { socket: `/tmp/tron-cua-${generation}/s`, generation };
  const nativeClose = vi.fn(async () => {});
  const open = vi.fn(async () => ({ automationEndpoint: async () => endpoint, close: nativeClose }));
  const run = vi.fn(async (_path: string, args: string[], _options: unknown) => ({ stdout: JSON.stringify(args[1] === "end_session" ? { active: false } : snapshot), stderr: "" }));
  const activate = vi.fn(async () => ({ stdout: '{"active":true,"revived":false}', stderr: "" }));
  const transport = vi.fn(async (path: string, args: string[], options: unknown) => args[1] === "start_session" ? activate() : run(path, args, options));
  const owner = binding(), client = new CuaComputerClient(owner, "/fixture/cua-driver", open as never, transport as never);
  return { client, owner, endpoint, open, nativeClose, run, activate, transport };
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
  it("does not label a marker-free action result completed", async () => {
    const f = fixture(); await observe(f);
    f.run.mockResolvedValueOnce({ stdout: '{}', stderr: '' });
    expect((await f.client.invoke("click", { element_token: "s00000001:1" })).status).toBe("outcomeUnknown");
    expect(() => f.client.invoke("click", { element_token: "s00000001:1" })).toThrow(/Observe/);
    expect(f.run.mock.calls.filter((call) => call[1][1] === "click")).toHaveLength(1);
    await f.client.close();
  });
  it("window geometry uses exact observed metadata, not screenshot-pixel admission", async () => {
    const f = fixture(); await observe(f);
    f.run.mockResolvedValueOnce({ stdout: '{"effect":"confirmed"}', stderr: '' });
    expect((await f.client.invoke("set_window_frame", { pid: 123, window_id: 456, x: -100, y: 20, width: 500, height: 600 })).status).toBe("completed");
    await observe(f);
    expect(() => f.client.invoke("set_window_frame", { pid: 999, window_id: 456, x: 0, y: 0, width: 500, height: 600 })).toThrow(/exact observed window/);
    await f.client.close();
  });
  it("revives expired sessions only before observations and never replays an expired action", async () => {
    const f = fixture(); await observe(f);
    f.run.mockRejectedValueOnce(new Error("session has ended"));
    await expect(f.client.invoke("click", { element_token: "s00000001:1" })).rejects.toThrow(/session has ended/);
    expect(f.transport.mock.calls.map((call) => call[1][1])).toEqual(["start_session", "get_window_state", "click"]);
    expect(() => f.client.invoke("click", { element_token: "s00000001:1" })).toThrow(/Observe/);
    f.activate.mockResolvedValueOnce({ stdout: '{"active":true,"revived":true}', stderr: "" });
    await observe(f);
    expect(f.transport.mock.calls.slice(-2).map((call) => call[1][1])).toEqual(["start_session", "get_window_state"]);
    expect(JSON.parse(f.transport.mock.calls.at(-2)![1][2]!)).toEqual({ session: f.owner.runtimeLoadID });
    expect(f.run.mock.calls.filter((call) => call[1][1] === "click")).toHaveLength(1);
    await f.client.close();
  });
  it("does not dispatch an observation after failed or cancelled session activation", async () => {
    const f = fixture();
    f.activate.mockResolvedValueOnce({ stdout: '{"active":false,"code":"session_unavailable"}', stderr: "" });
    await expect(observe(f)).rejects.toThrow(/activation was not confirmed/);
    expect(f.run).not.toHaveBeenCalled();
    const abort = new AbortController();
    f.activate.mockImplementationOnce(async () => { abort.abort(); return { stdout: '{"active":true,"revived":true}', stderr: "" }; });
    await expect(f.client.invoke("get_desktop_state", {}, abort.signal)).rejects.toThrow();
    expect(f.run).not.toHaveBeenCalled(); await f.client.close();
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
  it.each(["get_desktop_state", "get_window_state"])("publishes and cleans %s screenshots under a symlinked temporary root", async (tool) => {
    const root = await mkdtemp(join(tmpdir(), "tron-cua-path-test-"));
    const target = join(root, "real"), alias = join(root, "alias");
    const f = fixture(); let screenshotPath = "";
    // Valid 1x1 PNG; the vendor canonicalizes its returned screenshot path.
    const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=", "base64");
    try {
      await mkdir(target); await symlink(target, alias, "dir");
      vi.stubEnv("TMPDIR", alias);
      f.run.mockImplementation(async (_path, argv) => {
        screenshotPath = JSON.parse(argv[2]!).screenshot_out_file;
        await writeFile(screenshotPath, png);
        return { stdout: JSON.stringify({ ...snapshot, screenshot_frame_valid: true, screenshot_file_path: await realpath(screenshotPath), screenshot_width: 1, screenshot_height: 1 }), stderr: "" };
      });
      const result = await f.client.invoke(tool, tool === "get_window_state" ? { pid: 123, window_id: 456 } : {});
      expect(result.image?.data).toBe(png.toString("base64"));
      expect(result.output).not.toHaveProperty("screenshot_file_path");
      await expect(access(screenshotPath)).rejects.toThrow();
      f.run.mockResolvedValue({ stdout: '{"effect":"unverifiable"}', stderr: "" });
      const action = tool === "get_desktop_state"
        ? f.client.invoke("hotkey", { pid: 123, keys: ["cmd", "a"], delivery_mode: "foreground" })
        : f.client.invoke("click", { pid: 123, window_id: 456, x: 1, y: 1 });
      expect((await action).status).toBe("outcomeUnknown");
    } finally {
      vi.unstubAllEnvs(); f.run.mockResolvedValue({ stdout: '{"active":false}', stderr: "" });
      await f.client.close(); await rm(root, { recursive: true, force: true });
    }
  });
  it.each([
    ['{"code":"background_unavailable"}', "refused"], ['{"refusal":{"code":"stale_element_token"},"status":"refused"}', "refused"],
    ['{"effect":"unverifiable"}', "outcomeUnknown"], ['{"effect":"partial"}', "outcomeUnknown"], ['{"effect":"confirmed"}', "completed"],
  ])("does not confuse exit-zero payload %s with verified success", async (wire, status) => {
    const f = fixture();
    f.run.mockResolvedValue({ stdout: wire, stderr: "" });
    expect((await f.client.invoke("get_window_state", { pid: 123, include_screenshot: false })).status).toBe(status);
  });
});
