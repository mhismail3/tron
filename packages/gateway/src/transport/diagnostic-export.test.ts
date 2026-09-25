import { chmod, mkdir, mkdtemp, readFile, readdir, rm, stat, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { exportDiagnosticSnapshot } from "./diagnostic-export.js";

const roots: string[] = [];
afterEach(async () => {
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

async function root(): Promise<string> {
  const value = await mkdtemp(join(tmpdir(), "tron-diagnostic-export-"));
  roots.push(value);
  return value;
}

describe("diagnostic export", () => {
  it("writes a private server-owned file and returns its path", async () => {
    const directory = await root();
    const result = await exportDiagnosticSnapshot("Tron diagnostics\nsynthetic", [], new Date("2026-01-02T03:04:05.000Z"), directory, "device-id");
    expect(result.path).toMatch(new RegExp(`^${directory}/[a-f0-9]{32}-2026-01-02T03-04-05-000Z\\.jsonl$`));
    expect(result.exportedAt).toBe("2026-01-02T03:04:05.000Z");
    expect(await readFile(result.path, "utf8")).toBe("Tron diagnostics\nsynthetic");
    expect((await stat(result.path)).mode & 0o777).toBe(0o600);
    expect((await stat(directory)).mode & 0o777).toBe(0o700);
  });

  it("separates export filenames by required device identity", async () => {
    const directory = await root();
    const now = new Date("2026-01-02T03:04:05.000Z");
    const first = await exportDiagnosticSnapshot("first", [], now, directory, "device-one");
    const second = await exportDiagnosticSnapshot("second", [], now, directory, "device-two");
    expect(first.path).not.toBe(second.path);
    expect(await readFile(first.path, "utf8")).toBe("first");
    expect(await readFile(second.path, "utf8")).toBe("second");
  });

  it("appends the newest Gateway debug records after the client content", async () => {
    const directory = await root();
    const records = Array.from({ length: 3 }, (_, index) => ({
      timestamp: "2026-01-02T03:04:05.000Z", level: "debug" as const, message: `debug-${index}`, event: "rpc.completed",
    }));
    const result = await exportDiagnosticSnapshot("client", records, new Date(), directory, "device-id");
    const text = await readFile(result.path, "utf8");
    expect(text.startsWith("client\n{\"timestamp\":\"2026-01-02T03:04:05.000Z\",\"level\":\"debug\",\"message\":\"debug-0\",\"event\":\"rpc.completed\"}\n")).toBe(true);
    expect(text.indexOf("debug-0")).toBeLessThan(text.indexOf("debug-2"));
  });

  it("enforces the 512 KiB byte limit without creating an oversized file", async () => {
    const directory = await root();
    const maximumBytes = 512 * 1_024;
    await exportDiagnosticSnapshot("x".repeat(maximumBytes), [], new Date(), directory, "device-id");
    await expect(exportDiagnosticSnapshot("x".repeat(maximumBytes + 1), [], new Date(), directory, "device-id"))
      .rejects.toThrow("exceeds the size limit");
    expect((await readdir(directory)).filter((name) => name.endsWith(".jsonl"))).toHaveLength(1);
  });

  it("fails closed when the destination is not private", async () => {
    const directory = await root();
    await chmod(directory, 0o755);
    await expect(exportDiagnosticSnapshot("synthetic", [], new Date(), directory, "device-id"))
      .rejects.toMatchObject({ code: "conflict" });
  });

  it("rejects a preexisting symlink before creating or following its target", async () => {
    const directory = await root();
    const target = join(directory, "target");
    const link = join(directory, "diagnostics-link");
    await mkdir(target, { recursive: true, mode: 0o700 });
    await symlink(target, link);
    await expect(exportDiagnosticSnapshot("synthetic", [], new Date(), link, "device-id"))
      .rejects.toMatchObject({ code: "conflict" });
    expect((await readdir(target))).toEqual([]);
  });

  it("retains only the ten newest exports", async () => {
    const directory = await root();
    for (let index = 0; index < 12; index += 1) {
      await exportDiagnosticSnapshot(`export-${index}`, [], new Date(1_700_000_000_000 + index * 1_000), directory, "device-id");
    }
    const files = (await readdir(directory)).filter((name) => name.endsWith(".jsonl"));
    expect(files).toHaveLength(10);
    const contents = await Promise.all(files.map((file) => readFile(join(directory, file), "utf8")));
    expect(contents).toContain("export-11");
    expect(contents).toContain("export-10");
    expect(contents).not.toContain("export-0");
  });
});
