import { afterEach, expect, it, vi } from "vitest";
import { openNativeCaptureTransport } from "./native-capture-transport.js";

const { load } = vi.hoisted(() => ({ load: vi.fn() }));
vi.mock("node:module", () => ({ createRequire: () => load }));
afterEach(() => { vi.unstubAllGlobals(); load.mockReset(); });
function mac(): void { vi.stubGlobal("process", { ...process, platform: "darwin", arch: "arm64" }); }
it("module import does not load native code", () => { expect(load).not.toHaveBeenCalled(); });
it("missing binary is an actionable installed update gate", () => {
  mac();
  load.mockImplementation(() => { throw new Error("missing binary"); });
  expect(() => openNativeCaptureTransport()).toThrow("manual signed Mac app update");
  expect(load.mock.calls[0]?.[0]).toBe("/Applications/Tron.app/Contents/Library/Native/tron-native-capture.node");
});
it("explicit-open capacity/admission errors are not relabeled as app updates", () => {
  mac();
  const failure = new Error("connection capacity exhausted");
  const open = vi.fn(() => { throw failure; });
  load.mockReturnValue({ apiVersion: 2, open });
  expect(() => openNativeCaptureTransport()).toThrow(failure);
  expect(open).toHaveBeenCalledWith();
});
it("JavaScript owns request/close Promises and native callbacks settle them", async () => {
  mac();
  let reply!: (error: Error | null, value: { control: Buffer; jpeg: Buffer | null }) => void;
  let closed!: (error: Error | null) => void;
  const raw = {
    request: vi.fn((_control: Buffer, done: typeof reply) => { reply = done; }),
    closeLocal: vi.fn((done: typeof closed) => { closed = done; }),
  };
  load.mockReturnValue({ apiVersion: 2, open: () => raw });
  const transport = openNativeCaptureTransport();
  const pending = transport.request(Buffer.from("control"));
  const value = { control: Buffer.from("reply"), jpeg: null };
  reply(null, value);
  await expect(pending).resolves.toEqual(value);
  const failed = transport.request(Buffer.from("control"));
  reply(new Error("transport lost"), value);
  await expect(failed).rejects.toThrow("transport lost");
  const close = transport.closeLocal();
  expect(transport.closeLocal()).toBe(close);
  closed(null);
  await close;
  expect(raw.closeLocal).toHaveBeenCalledTimes(1);
});

it("an incompatible native API cannot open a connection", () => {
  mac();
  const open = vi.fn();
  load.mockReturnValue({ apiVersion: 1, open });
  expect(() => openNativeCaptureTransport()).toThrow("manual signed Mac app update");
  expect(open).not.toHaveBeenCalled();
});

it("unsupported runtime never attempts a fallback loader", () => {
  vi.stubGlobal("process", { ...process, platform: "linux", arch: "x64" });
  expect(() => openNativeCaptureTransport()).toThrow("installed signed Mac runtime");
  expect(load).not.toHaveBeenCalled();
});
