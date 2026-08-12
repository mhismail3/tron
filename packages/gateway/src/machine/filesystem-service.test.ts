import { mkdtemp, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { FilesystemService } from "./filesystem-service.js";

describe("FilesystemService", () => {
  it("lists and creates directories under its explicit root", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-fs-"));
    await mkdir(join(root, "existing"));
    const service = new FilesystemService(root);
    expect((await service.list()).entries.map((entry) => entry.name)).toContain("existing");
    expect(await service.createDirectory(root, "new-folder")).toBe(join(service.root, "new-folder"));
  });

  it("rejects traversal", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-fs-"));
    const service = new FilesystemService(root);
    await expect(service.list("/")).rejects.toThrow("outside");
  });
});
