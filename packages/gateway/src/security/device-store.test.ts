import { createHash } from "node:crypto";
import { chmod, mkdir, mkdtemp, open, readFile, rename, rm, symlink, writeFile } from "node:fs/promises";
import { readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";
import * as durableJson from "../util/durable-json.js";
import type { DurableJsonFileSystem } from "../util/durable-json.js";
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

    expect(await store.authenticateAndAdmit(paired.token, (identity) => identity)).toEqual({ kind: "device", deviceId: paired.deviceId });
    await expect(store.pair(enrollment.code, "Other")).rejects.toThrow();
    const deviceFile = await readFile(join(root, "gateway", "devices.json"), "utf8");
    expect(deviceFile).not.toContain(paired.token);
  });

  it("keeps the wrapper credential in its dedicated gateway store", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-gateway-device-"));
    const store = new DeviceStore(root, "machine-id");
    await store.initialize();

    expect(JSON.parse(await readFile(join(root, "gateway", "local-auth.json"), "utf8"))).toMatchObject({
      version: 2,
      purpose: "local-wrapper-health",
    });
  });

  it("uses observed names unless a custom label overrides them, and supports reset", async () => {
    const { store } = await fixture();
    const enrollment = await store.ensureEnrollment();
    const paired = await store.pair(enrollment.code, "iPhone");
    expect((await store.listDevices())[0]).toMatchObject({ name: "iPhone" });
    await store.updateObservedName(paired.deviceId, "Personal iPhone");
    expect((await store.listDevices())[0]).toMatchObject({ name: "Personal iPhone" });
    await store.setCustomLabel(paired.deviceId, "Work phone");
    expect((await store.listDevices())[0]).toMatchObject({ name: "Work phone", customLabel: "Work phone" });
    await store.updateObservedName(paired.deviceId, "Renamed iPhone");
    expect((await store.listDevices())[0]).toMatchObject({ name: "Work phone" });
    await store.setCustomLabel(paired.deviceId, null);
    expect((await store.listDevices())[0]).toMatchObject({ name: "Renamed iPhone" });
  });

  it("rejects malformed custom and observed names without changing persisted identity", async () => {
    const { store } = await fixture();
    const enrollment = await store.ensureEnrollment();
    const paired = await store.pair(enrollment.code, "iPhone");
    await expect(store.setCustomLabel(paired.deviceId, " \u0000 ")).rejects.toMatchObject({ code: "invalid_request" });
    await expect(store.updateObservedName(paired.deviceId, " \u0001 ")).resolves.toBe(false);
    expect((await store.listDevices())[0]).toMatchObject({ id: paired.deviceId, name: "iPhone" });
  });

  it("retains observed metadata across persisted reads", async () => {
    const { root, store } = await fixture();
    const enrollment = await store.ensureEnrollment();
    const paired = await store.pair(enrollment.code, "iPhone");
    const path = join(root, "gateway", "devices.json");
    const document = JSON.parse(await readFile(path, "utf8"));
    document.devices[0].observedName = "Personal iPhone";
    await writeFile(path, `${JSON.stringify(document)}\n`);
    expect(await store.listDevices()).toEqual([expect.objectContaining({ id: paired.deviceId, name: "Personal iPhone" })]);
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
    await store.revoke(paired.deviceId, () => {});
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
    await expect(store.authenticateAndAdmit("not-a-token", (identity) => identity)).rejects.toMatchObject({ code: "conflict" });

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

  it("does not publish or retire authority when durable revocation fails", async () => {
    const { root, store } = await fixture();
    const enrollment = await store.ensureEnrollment();
    const paired = await store.pair(enrollment.code, "Phone");
    const gatewayPath = join(root, "gateway");
    let publications = 0;
    // Pairing schedules invitation regeneration; settle that owned write before
    // changing directory permissions for the failure injection.
    await store.ensureEnrollment();
    await chmod(gatewayPath, 0o500);
    try {
      await expect(store.revoke(paired.deviceId, () => { publications += 1; })).rejects.toBeDefined();
    } finally {
      await chmod(gatewayPath, 0o700);
    }
    expect(publications).toBe(0);
    expect(await store.authenticateAndAdmit(paired.token, (identity) => identity)).toEqual({ kind: "device", deviceId: paired.deviceId });
  });

  it("retires transport authority when revocation rename is visible but directory sync fails", async () => {
    const { root, store } = await fixture();
    const enrollment = await store.ensureEnrollment();
    const paired = await store.pair(enrollment.code, "Phone");
    await store.ensureEnrollment();
    const gatewayPath = join(root, "gateway");
    const failure = Object.assign(new Error("directory sync failed"), { code: "ENOSPC" });
    const realWrite = durableJson.durableAtomicWriteJson;
    const faultedFileSystem: DurableJsonFileSystem = {
      mkdir,
      rename,
      rm,
      open: (async (path: string, ...args: unknown[]) => {
        const handle = await open(path, ...(args as [never]));
        if (path === gatewayPath) {
          Object.defineProperty(handle, "sync", { value: async () => { throw failure; } });
        }
        return handle;
      }) as DurableJsonFileSystem["open"],
    };
    vi.spyOn(durableJson, "durableAtomicWriteJson").mockImplementationOnce((path, value, mode) =>
      realWrite(path, value, mode, faultedFileSystem));
    let publications = 0;
    try {
      await expect(store.revoke(paired.deviceId, () => { publications += 1; })).rejects.toMatchObject({ code: "ENOSPC" });
      expect(publications).toBe(1);
      expect(await store.authenticateAndAdmit(paired.token, (identity) => identity)).toBeNull();
      expect(await store.revoke(paired.deviceId, () => { publications += 1; })).toBe(false);
      expect(publications).toBe(1);
    } finally {
      vi.restoreAllMocks();
      await rm(root, { recursive: true, force: true });
    }
  });

  it("regenerates an invitation when consumption unlinks it but directory synchronization fails", async () => {
    const { root, store } = await fixture();
    const invitation = await store.ensureEnrollment();
    const realRemove = durableJson.durableRemove;
    const gatewayPath = join(root, "gateway");
    const failedSync = Object.assign(new Error("removed invitation was not synchronized"), { code: "EIO" });
    const io = {
      rm,
      open: (async (path: string, ...args: unknown[]) => {
        const handle = await open(path, ...(args as [never]));
        if (path === gatewayPath) Object.defineProperty(handle, "sync", { value: async () => { throw failedSync; } });
        return handle;
      }) as DurableJsonFileSystem["open"],
    };
    vi.spyOn(durableJson, "durableRemove").mockImplementationOnce(path => realRemove(path, io));
    try {
      await expect(store.pair(invitation.code, "Phone")).rejects.toBe(failedSync);
      // Read bytes directly: calling ensureEnrollment here would hide the bug.
      const replacement = JSON.parse(await readFile(join(gatewayPath, "enrollment.json"), "utf8"));
      expect(replacement.code).not.toBe(invitation.code);
      expect(await store.listDevices()).toEqual([]);
    } finally {
      vi.restoreAllMocks();
      await rm(root, { recursive: true, force: true });
    }
  });

  it("retains the paired device when its publication is visible but durability is uncertain", async () => {
    const { root, store } = await fixture();
    const first = await store.ensureEnrollment();
    const gatewayPath = join(root, "gateway");
    const failure = Object.assign(new Error("directory sync failed"), { code: "ENOSPC" });
    const realWrite = durableJson.durableAtomicWriteJson;
    const faultedFileSystem: DurableJsonFileSystem = {
      mkdir,
      rename,
      rm,
      open: (async (path: string, ...args: unknown[]) => {
        const handle = await open(path, ...(args as [never]));
        if (path === gatewayPath) {
          Object.defineProperty(handle, "sync", { value: async () => { throw failure; } });
        }
        return handle;
      }) as DurableJsonFileSystem["open"],
    };
    vi.spyOn(durableJson, "durableAtomicWriteJson").mockImplementationOnce((path, value, mode) =>
      realWrite(path, value, mode, faultedFileSystem));
    try {
      await expect(store.pair(first.code, "Phone")).rejects.toMatchObject({ code: "ENOSPC" });
      expect(await store.listDevices()).toHaveLength(1);
      const replacement = await store.ensureEnrollment();
      expect(replacement.code).not.toBe(first.code);
    } finally {
      vi.restoreAllMocks();
      await rm(root, { recursive: true, force: true });
    }
  });

  it("publishes revocation after the durable replacement and only once", async () => {
    const { root, store } = await fixture();
    const enrollment = await store.ensureEnrollment();
    const paired = await store.pair(enrollment.code, "Phone");
    const devicePath = join(root, "gateway", "devices.json");
    let publications = 0;
    expect(await store.revoke(paired.deviceId, () => {
      publications += 1;
      expect(readFileSync(devicePath, "utf8")).not.toContain(paired.deviceId);
    })).toBe(true);
    expect(publications).toBe(1);
    expect(await store.authenticateAndAdmit(paired.token, (identity) => identity)).toBeNull();
    expect(await store.revoke(paired.deviceId, () => { publications += 1; })).toBe(false);
    expect(publications).toBe(1);
  });
});
