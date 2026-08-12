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

  it("revokes one paired device", async () => {
    const { store } = await fixture();
    const enrollment = await store.ensureEnrollment();
    const paired = await store.pair(enrollment.code, "Phone");
    expect(await store.revoke(paired.deviceId)).toBe(true);
    expect(await store.authenticate(paired.token)).toBeNull();
  });
});
