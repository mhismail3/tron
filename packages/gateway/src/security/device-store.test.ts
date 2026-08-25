import { createHash } from "node:crypto";
import { chmod, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
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

    expect(await store.authenticate(paired.token)).toEqual({ kind: "device", deviceId: paired.deviceId });
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

  it("reads legacy lastSeenAt but normalizes it on the next owned write", async () => {
    const { root, store } = await fixture();
    const enrollment = await store.ensureEnrollment();
    const paired = await store.pair(enrollment.code, "Phone");
    const path = join(root, "gateway", "devices.json");
    const document = JSON.parse(await readFile(path, "utf8"));
    document.devices[0].lastSeenAt = "2026-01-01T00:00:00.000Z";
    await writeFile(path, `${JSON.stringify(document)}\n`);
    expect(await store.listDevices()).toEqual([expect.objectContaining({ id: paired.deviceId })]);
    expect(await readFile(path, "utf8")).toContain("lastSeenAt");
    await store.revoke(paired.deviceId);
    expect(await readFile(path, "utf8")).not.toContain("lastSeenAt");
  });

  it("rejects duplicate or oversized persisted device catalogs", async () => {
    const { root, store } = await fixture();
    const enrollment = await store.ensureEnrollment();
    await store.pair(enrollment.code, "Phone");
    const path = join(root, "gateway", "devices.json");
    const document = JSON.parse(await readFile(path, "utf8"));
    const original = document.devices[0];
    const distinctHash = createHash("sha256").update("distinct").digest("base64url");
    document.devices.push({ ...original, id: "alias" });
    await writeFile(path, `${JSON.stringify(document)}\n`);
    await expect(store.listDevices()).rejects.toMatchObject({ code: "conflict" });

    document.devices = [original, { ...original, tokenHash: distinctHash }];
    await writeFile(path, `${JSON.stringify(document)}\n`);
    await expect(store.authenticate("not-a-token")).rejects.toMatchObject({ code: "conflict" });

    document.devices = [{ ...original, createdAt: "2026-02-30T10:00:00Z" }];
    await writeFile(path, `${JSON.stringify(document)}\n`);
    await expect(store.listDevices()).rejects.toMatchObject({ code: "conflict" });
  });

  it("rejects persisted device count overflow and unknown record fields", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-gateway-device-persisted-bound-"));
    const store = new DeviceStore(root, "machine-id", { maximumDevices: 1 });
    await store.initialize();
    const enrollment = await store.ensureEnrollment();
    await store.pair(enrollment.code, "First");
    const path = join(root, "gateway", "devices.json");
    const document = JSON.parse(await readFile(path, "utf8"));
    const original = document.devices[0];
    document.devices.push({
      ...original,
      id: "second",
      tokenHash: createHash("sha256").update("second").digest("base64url"),
    });
    await writeFile(path, JSON.stringify(document));
    await expect(store.listDevices()).rejects.toMatchObject({ code: "conflict" });

    document.devices = [{ ...original, unexpected: true }];
    await writeFile(path, JSON.stringify(document));
    await expect(store.listDevices()).rejects.toMatchObject({ code: "conflict" });
  });

  it("bounds persisted device, invitation, and local credential documents before decode", async () => {
    const { root, store } = await fixture();
    const gateway = join(root, "gateway");

    await writeFile(join(gateway, "devices.json"), "x".repeat(1 * 1_024 * 1_024 + 1));
    await expect(store.listDevices()).rejects.toMatchObject({ code: "conflict" });

    await writeFile(join(gateway, "enrollment.json"), "x".repeat(16 * 1_024 + 1));
    await expect(store.ensureEnrollment()).rejects.toMatchObject({ code: "conflict" });

    await rm(join(gateway, "enrollment.json"), { force: true });
    await writeFile(join(gateway, "local-auth.json"), "x".repeat(4 * 1_024 + 1), { mode: 0o600 });
    await chmod(join(gateway, "local-auth.json"), 0o600);
    await expect(new DeviceStore(root, "machine-id").initialize()).rejects.toMatchObject({ code: "conflict" });
  });

  it("requires owner-only regular credential and invitation files and fails closed on wrong credentials", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-gateway-device-boundary-"));
    const gateway = join(root, "gateway");
    await mkdir(gateway, { recursive: true });
    const external = join(root, "external-auth.json");
    await writeFile(external, JSON.stringify({
      version: 2, bearerToken: "x".repeat(32), purpose: "local-wrapper-health",
      lastUpdated: "2026-01-01T00:00:00.000Z",
    }));
    await symlink(external, join(gateway, "local-auth.json"));
    await expect(new DeviceStore(root, "machine-id").initialize()).rejects.toMatchObject({ code: "conflict" });

    await rm(join(gateway, "local-auth.json"), { force: true });
    await writeFile(join(gateway, "local-auth.json"), JSON.stringify({
      version: 1, bearerToken: "x".repeat(32), purpose: "legacy", lastUpdated: "2026-01-01T00:00:00.000Z",
    }), { mode: 0o600 });
    await expect(new DeviceStore(root, "machine-id").initialize()).rejects.toMatchObject({ code: "conflict" });

    await rm(join(gateway, "local-auth.json"), { force: true });
    const store = new DeviceStore(root, "machine-id");
    await store.initialize();
    const enrollment = await store.ensureEnrollment();
    const outsideEnrollment = join(root, "outside-enrollment.json");
    await writeFile(outsideEnrollment, JSON.stringify(enrollment));
    await rm(join(gateway, "enrollment.json"), { force: true });
    await symlink(outsideEnrollment, join(gateway, "enrollment.json"));
    await expect(store.ensureEnrollment()).rejects.toMatchObject({ code: "conflict" });
  });

  it("rejects unsafe, empty, and malformed persisted device catalogs", async () => {
    const { root, store } = await fixture();
    const path = join(root, "gateway", "devices.json");
    const external = join(root, "external-devices.json");
    await writeFile(external, JSON.stringify({ version: 1, devices: [] }), { mode: 0o600 });
    await rm(path, { force: true });
    await symlink(external, path);
    await expect(store.listDevices()).rejects.toMatchObject({ code: "conflict" });

    await rm(path, { force: true });
    await writeFile(path, JSON.stringify({ version: 1, devices: [] }), { mode: 0o640 });
    await chmod(path, 0o640);
    await expect(store.listDevices()).rejects.toMatchObject({ code: "conflict" });

    await chmod(path, 0o600);
    await writeFile(path, "", { mode: 0o600 });
    await expect(store.listDevices()).rejects.toMatchObject({ code: "conflict" });

    await writeFile(path, "{not-json", { mode: 0o600 });
    await expect(store.listDevices()).rejects.toMatchObject({ code: "conflict" });
  });

  it("fails closed for bounded JSON corruption and replaces wrong invitation identity", async () => {
    const { root, store } = await fixture();
    const gateway = join(root, "gateway");
    await writeFile(join(gateway, "enrollment.json"), "{not-json");
    await expect(store.ensureEnrollment()).rejects.toMatchObject({ code: "conflict" });

    await writeFile(join(gateway, "enrollment.json"), JSON.stringify({
      version: 1,
      code: "23456789AB",
      expiresAt: new Date(Date.now() + 60_000).toISOString(),
      machineId: "another-machine",
    }));
    const replacement = await store.ensureEnrollment();
    expect(replacement.machineId).toBe("machine-id");
    expect(replacement.code).not.toBe("23456789AB");

    await rm(join(gateway, "enrollment.json"), { force: true });
    await writeFile(join(gateway, "local-auth.json"), "{not-json", { mode: 0o600 });
    await chmod(join(gateway, "local-auth.json"), 0o600);
    await expect(new DeviceStore(root, "machine-id").initialize()).rejects.toMatchObject({ code: "conflict" });
  });

  it("replaces malformed bounded invitations and rejects invalid machine identity", async () => {
    const { root, store } = await fixture();
    const path = join(root, "gateway", "enrollment.json");
    await writeFile(path, JSON.stringify({
      version: 1,
      code: "not-valid",
      expiresAt: "not-a-time",
      machineId: "machine-id",
    }));

    const replacement = await store.ensureEnrollment();
    expect(replacement.code).toMatch(/^[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{10}$/);
    expect(replacement.expiresAt).not.toBe("not-a-time");
    expect(() => new DeviceStore(root, "x".repeat(257))).toThrow("Machine identity is invalid");
  });

  it("revokes one paired device", async () => {
    const { store } = await fixture();
    const enrollment = await store.ensureEnrollment();
    const paired = await store.pair(enrollment.code, "Phone");
    expect(await store.hasDevice(paired.deviceId)).toBe(true);
    expect(await store.revoke(paired.deviceId)).toBe(true);
    expect(await store.hasDevice(paired.deviceId)).toBe(false);
    expect(await store.authenticate(paired.token)).toBeNull();
  });
});
