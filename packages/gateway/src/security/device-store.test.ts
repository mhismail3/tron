import { chmod, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { DeviceStore } from "./device-store.js";

async function fixture(): Promise<{ root: string; store: DeviceStore }> {
  const root = await mkdtemp(join(tmpdir(), "tron-gateway-device-"));
  const store = new DeviceStore(root, "machine-id");
  await store.initialize();
  return { root, store };
}

describe("DeviceStore", () => {
  it("exchanges an enrollment code once and stores only the token hash", async () => {
    const { root, store } = await fixture();
    const enrollment = await store.ensureEnrollment();
    const paired = await store.pair(enrollment.code, "Phone");

    expect((await store.authenticate(paired.token))?.kind).toBe("device");
    await expect(store.pair(enrollment.code, "Other")).rejects.toThrow();
    const deviceFile = await readFile(join(root, "gateway", "devices.json"), "utf8");
    expect(deviceFile).not.toContain(paired.token);
  });

  it("keeps legacy auth read-only and owns a separate wrapper credential", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-gateway-device-"));
    const legacy = `${JSON.stringify({ version: 1, bearerToken: "legacy-secret", providers: { old: {} } })}\n`;
    await writeFile(join(root, "auth.json"), legacy);
    await chmod(join(root, "auth.json"), 0o600);
    const store = new DeviceStore(root, "machine-id");
    await store.initialize();

    expect(await readFile(join(root, "auth.json"), "utf8")).toBe(legacy);
    expect(JSON.parse(await readFile(join(root, "gateway", "local-auth.json"), "utf8"))).toMatchObject({
      version: 2,
      purpose: "local-wrapper-health",
    });
  });

  it("rejects pairing beyond capacity without consuming the invitation", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-gateway-device-bound-"));
    const store = new DeviceStore(root, "machine-id", { maximumDevices: 1 });
    await store.initialize();
    const firstEnrollment = await store.ensureEnrollment();
    await store.pair(firstEnrollment.code, "First");
    const secondEnrollment = await store.ensureEnrollment();
    await expect(store.pair(secondEnrollment.code, "Second")).rejects.toMatchObject({ code: "conflict" });
    await expect(store.ensureEnrollment()).resolves.toMatchObject({ code: secondEnrollment.code });
    expect(await store.listDevices()).toHaveLength(1);
  });

  it("rejects duplicate or oversized persisted device catalogs", async () => {
    const { root, store } = await fixture();
    const enrollment = await store.ensureEnrollment();
    await store.pair(enrollment.code, "Phone");
    const path = join(root, "gateway", "devices.json");
    const document = JSON.parse(await readFile(path, "utf8"));
    document.devices.push({
      ...document.devices[0],
      id: "alias",
      tokenHash: `${document.devices[0].tokenHash}=`,
    });
    await writeFile(path, `${JSON.stringify(document)}\n`);
    await expect(store.listDevices()).rejects.toMatchObject({ code: "conflict" });
    await expect(store.authenticate("not-a-token")).rejects.toMatchObject({ code: "conflict" });

    document.devices = [{ ...document.devices[0], createdAt: "2026-02-30T10:00:00Z" }];
    await writeFile(path, `${JSON.stringify(document)}\n`);
    await expect(store.listDevices()).rejects.toMatchObject({ code: "conflict" });
  });

  it("revokes one paired device", async () => {
    const { store } = await fixture();
    const enrollment = await store.ensureEnrollment();
    const paired = await store.pair(enrollment.code, "Phone");
    expect(await store.revoke(paired.deviceId)).toBe(true);
    expect(await store.authenticate(paired.token)).toBeNull();
  });
});
