import { mkdtemp, mkdir, rm, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { FilesystemService, WORKSPACE_MAXIMUM_ENTRIES } from "./filesystem-service.js";

describe("FilesystemService", () => {
  it("stays within the shared dynamic JSON array ceiling", () => {
    expect(WORKSPACE_MAXIMUM_ENTRIES).toBe(1_000);
  });

  it("lists and creates directories under its explicit root", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-fs-"));
    await mkdir(join(root, "existing"));
    const service = new FilesystemService(root);
    expect((await service.list()).entries.map((entry) => entry.name)).toContain("existing");
    expect(await service.createDirectory(root, "new-folder")).toBe(join(service.root, "new-folder"));
  });

  it("rejects entry and projected-byte overflow without partial listings", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-fs-bounds-"));
    try {
      await Promise.all(["a", "b", "c"].map((name) => mkdir(join(root, name))));
      const countBound = new FilesystemService(root, {
        maximumEntries: 2,
        maximumProjectedBytes: 10_000,
      });
      await expect(countBound.list()).rejects.toMatchObject({ code: "conflict" });
      await rm(join(root, "c"), { recursive: true });
      await expect(countBound.list()).resolves.toMatchObject({
        entries: [{ name: "a" }, { name: "b" }],
      });

      const byteBound = new FilesystemService(root, {
        maximumEntries: 10,
        maximumProjectedBytes: 10,
      });
      await expect(byteBound.list()).rejects.toMatchObject({ code: "conflict" });

      await Promise.all(["a", "b"].map((name) => rm(join(root, name), { recursive: true })));
      await Promise.all(["one", "two", "three"].map((name) => symlink(root, join(root, name))));
      await expect(countBound.list()).rejects.toMatchObject({ code: "conflict" });
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("rejects traversal", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-fs-"));
    const service = new FilesystemService(root);
    await expect(service.list("/")).rejects.toThrow("outside");
  });
});
