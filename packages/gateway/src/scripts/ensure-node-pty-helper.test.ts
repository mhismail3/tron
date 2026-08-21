import { chmodSync, mkdtempSync, mkdirSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { ensureNodePtyHelper } from "../../scripts/ensure-node-pty-helper.mjs";

describe("node-pty helper extraction boundary", () => {
  it("repairs execute permission on Darwin", () => {
    const root = mkdtempSync(join(tmpdir(), "tron-pty-"));
    const helper = join(root, "prebuilds", "darwin-arm64", "spawn-helper");
    mkdirSync(join(root, "prebuilds", "darwin-arm64"), { recursive: true });
    writeFileSync(helper, "helper");
    chmodSync(helper, 0o644);
    ensureNodePtyHelper("darwin", root);
    expect(statSync(helper).mode & 0o111).toBe(0o111);
  });

  it("fails closed when the Darwin helper is missing", () => {
    const root = mkdtempSync(join(tmpdir(), "tron-pty-"));
    expect(() => ensureNodePtyHelper("darwin", root)).toThrow(/spawn helper is missing/);
  });

  it("is an explicit no-op away from Darwin", () => {
    const root = mkdtempSync(join(tmpdir(), "tron-pty-"));
    expect(() => ensureNodePtyHelper("linux", root)).not.toThrow();
  });
});
