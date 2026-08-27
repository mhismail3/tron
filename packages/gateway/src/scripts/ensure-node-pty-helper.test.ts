import {
  chmodSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readlinkSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { ensureNodePtyHelper, ensurePayloadNodeAliases } from "../../scripts/ensure-node-pty-helper.mjs";

const roots: string[] = [];
afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

function temporary(prefix: string): string {
  const root = mkdtempSync(join(tmpdir(), prefix));
  roots.push(root);
  return root;
}

describe("node-pty helper extraction boundary", () => {
  it("repairs execute permission on Darwin", () => {
    const root = temporary("tron-pty-");
    const helper = join(root, "prebuilds", "darwin-arm64", "spawn-helper");
    mkdirSync(join(root, "prebuilds", "darwin-arm64"), { recursive: true });
    writeFileSync(helper, "helper");
    chmodSync(helper, 0o644);
    ensureNodePtyHelper("darwin", root);
    expect(lstatSync(helper).mode & 0o111).toBe(0o111);
  });

  it("fails closed when the Darwin helper is missing", () => {
    const root = temporary("tron-pty-");
    expect(() => ensureNodePtyHelper("darwin", root)).toThrow(/spawn helper is missing/);
  });

  it("is an explicit no-op away from Darwin", () => {
    const root = temporary("tron-pty-");
    expect(() => ensureNodePtyHelper("linux", root)).not.toThrow();
  });
});

describe("source-built payload runtime alias bridge", () => {
  it("adds exact aliases without following a substituted alias directory", () => {
    const root = temporary("tron-runtime-alias-install-");
    const app = join(root, "app");
    const runtime = join(root, "runtime");
    const outside = join(root, "outside");
    mkdirSync(join(app, "node_modules", "@earendil-works", "pi-coding-agent", "dist"), { recursive: true });
    mkdirSync(runtime);
    mkdirSync(outside);
    const piCli = join(app, "node_modules", "@earendil-works", "pi-coding-agent", "dist", "cli.js");
    writeFileSync(piCli, "#!/usr/bin/env node\n");
    chmodSync(piCli, 0o755);
    writeFileSync(join(outside, "sentinel"), "unchanged\n");
    for (const architecture of ["arm64", "x64"]) {
      const executable = join(runtime, `node-${architecture}`);
      writeFileSync(executable, "runtime\n");
      chmodSync(executable, 0o755);
    }
    symlinkSync(outside, join(runtime, "bin-arm64"));

    expect(ensurePayloadNodeAliases("darwin", app)).toBe(true);

    expect(readFileSync(join(outside, "sentinel"), "utf8")).toBe("unchanged\n");
    expect(lstatSync(join(runtime, "bin-arm64")).isDirectory()).toBe(true);
    for (const architecture of ["arm64", "x64"]) {
      const alias = join(runtime, `bin-${architecture}`, "node");
      const piAlias = join(runtime, `bin-${architecture}`, "pi");
      expect(lstatSync(alias).isSymbolicLink()).toBe(true);
      expect(readlinkSync(alias)).toBe(`../node-${architecture}`);
      expect(realpathSync(alias)).toBe(realpathSync(join(runtime, `node-${architecture}`)));
      expect(lstatSync(piAlias).isSymbolicLink()).toBe(true);
      expect(readlinkSync(piAlias)).toBe("../../app/node_modules/@earendil-works/pi-coding-agent/dist/cli.js");
      expect(realpathSync(piAlias)).toBe(realpathSync(piCli));
    }
  });

  it("leaves ordinary workspace installs without bundled runtimes unchanged", () => {
    const root = temporary("tron-runtime-alias-workspace-");
    const app = join(root, "app");
    mkdirSync(app);
    expect(ensurePayloadNodeAliases("darwin", app)).toBe(false);
    expect(() => lstatSync(join(root, "runtime"))).toThrow();
  });

  it("fails closed on a partial or substituted runtime set", () => {
    const root = temporary("tron-runtime-alias-partial-");
    const app = join(root, "app");
    const runtime = join(root, "runtime");
    mkdirSync(app);
    mkdirSync(runtime);
    writeFileSync(join(runtime, "node-arm64"), "runtime\n");
    chmodSync(join(runtime, "node-arm64"), 0o755);
    expect(() => ensurePayloadNodeAliases("darwin", app)).toThrow(/missing or substituted: x64/);
  });
});
