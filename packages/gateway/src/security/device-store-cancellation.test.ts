import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it, vi } from "vitest";
import { DeviceStore, type DeviceRecord } from "./device-store.js";

it("abandons a credential read without releasing its mutex or admitting a late device", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-auth-cancel-"));
  let release!: () => void;
  const gate = new Promise<void>(resolve => { release = resolve; });
  const store = new DeviceStore(root, "fixture-machine");
  try {
    await store.initialize();
    const enrollment = await store.ensureEnrollment();
    const device = await store.pair(enrollment.code, "fixture-device");
    await store.ensureEnrollment();
    const io = store as unknown as { readDevices(): Promise<{ version: 1; devices: DeviceRecord[] }> };
    const document = await io.readDevices();
    let entered!: () => void;
    const reading = new Promise<void>(resolve => { entered = resolve; });
    vi.spyOn(io, "readDevices").mockImplementation(async () => { entered(); await gate; return document; });
    const controller = new AbortController();
    const admit = vi.fn(() => true);
    const authentication = store.authenticateAndAdmit(device.token, admit, controller.signal);
    void authentication.catch(() => {});
    await reading;
    controller.abort();
    await expect(authentication).rejects.toMatchObject({ name: "AbortError" });
    expect(admit).not.toHaveBeenCalled();
    let successorEntered = false;
    const successor = store.admitDevice(device.deviceId, () => { successorEntered = true; return true; });
    expect(successorEntered).toBe(false);
    release();
    await expect(successor).resolves.toBe(true);
    expect(admit).not.toHaveBeenCalled();
  } finally {
    release();
    await store.admitDevice("missing-fixture-device", () => false).catch(() => {});
    vi.restoreAllMocks();
    await rm(root, { recursive: true, force: true });
  }
});
