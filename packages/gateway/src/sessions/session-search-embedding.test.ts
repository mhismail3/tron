import { mkdtemp, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { admitSearchEmbeddingHelper } from "./session-search-embedding.js";

describe("session search helper admission", () => {
  it("rejects missing, symlinked, and unsigned helper paths", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-search-helper-"));
    const regular = join(root, "TronSearchEmbeddingHelper");
    const link = join(root, "link");
    await writeFile(regular, "synthetic helper");
    await symlink(regular, link);
    expect(await admitSearchEmbeddingHelper(join(root, "missing"))).toBe(false);
    expect(await admitSearchEmbeddingHelper(link)).toBe(false);
    expect(await admitSearchEmbeddingHelper(regular)).toBe(false);
    await rm(root, { recursive: true, force: true });
  });
});
