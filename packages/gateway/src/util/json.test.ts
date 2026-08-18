import { mkdir, mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";
import { readJson, updateJsonLocked } from "./json.js";

describe("bounded JSON reads", () => {
  it("admits the exact byte limit and rejects a larger file", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-bounded-json-"));
    const path = join(root, "value.json");
    const content = JSON.stringify({ value: "bounded" });
    await writeFile(path, content);

    await expect(readJson(path, {}, Buffer.byteLength(content))).resolves.toEqual({ value: "bounded" });
    await expect(readJson(path, {}, Buffer.byteLength(content) - 1)).rejects.toThrow("JSON file exceeds");
  });

  it("rejects allocation limits outside the bounded JSON policy", async () => {
    await expect(readJson("/unused", {}, 64 * 1_048_576 + 1)).rejects.toThrow("maximumBytes must be an integer");
  });

  it("applies the same bound when rereading under the update lock", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-bounded-json-update-"));
    const path = join(root, "state", "value.json");
    await mkdir(join(root, "state"));
    await writeFile(path, JSON.stringify({ value: "oversized" }));
    const update = vi.fn((current: unknown) => current);

    await expect(updateJsonLocked(path, {}, update, 4)).rejects.toThrow("JSON file exceeds");
    expect(update).not.toHaveBeenCalled();
  });
});
