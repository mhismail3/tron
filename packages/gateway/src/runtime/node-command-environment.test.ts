import { chmodSync, mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync, unlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { afterEach, describe, expect, it } from "vitest";
import { configureSupervisedNodeCommandEnvironment } from "./node-command-environment.js";

const roots: string[] = [];
afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

function executable(path: string, marker: string): void {
  writeFileSync(path, `#!/bin/sh\nprintf '%s\\n' '${marker}'\n`);
  chmodSync(path, 0o755);
}

function fixture(architecture: "arm64" | "x64" = "arm64") {
  const root = mkdtempSync(join(tmpdir(), "tron-node-command-"));
  roots.push(root);
  const runtime = join(root, "runtime", `node-${architecture}`);
  const aliasDirectory = join(root, "runtime", `bin-${architecture}`);
  const entryPoint = join(root, "app", "dist", "index.js");
  const piCli = join(root, "app", "node_modules", "@earendil-works", "pi-coding-agent", "dist", "cli.js");
  mkdirSync(aliasDirectory, { recursive: true });
  mkdirSync(join(root, "app", "dist"), { recursive: true });
  mkdirSync(join(root, "app", "node_modules", "@earendil-works", "pi-coding-agent", "dist"), { recursive: true });
  mkdirSync(join(root, "app", "node_modules", ".bin"), { recursive: true });
  writeFileSync(join(root, "app", "node_modules", "@earendil-works", "pi-coding-agent", "package.json"), JSON.stringify({ name: "@earendil-works/pi-coding-agent", bin: { pi: "dist/cli.js" } }));
  executable(runtime, `runtime-${architecture}`);
  executable(piCli, "pi-cli");
  symlinkSync("../@earendil-works/pi-coding-agent/dist/cli.js", join(root, "app", "node_modules", ".bin", "pi"));
  writeFileSync(entryPoint, "// fixture entry\n");
  symlinkSync(`../node-${architecture}`, join(aliasDirectory, "node"));
  symlinkSync("../../app/node_modules/.bin/pi", join(aliasDirectory, "pi"));
  return { root, runtime, aliasDirectory, alias: join(aliasDirectory, "node"), piAlias: join(aliasDirectory, "pi"), piCli, entryPoint };
}

function environment(root: string, channel: "stable" | "dev", path: string): NodeJS.ProcessEnv {
  return {
    TRON_GATEWAY_SUPERVISED: "1",
    TRON_GATEWAY_PAYLOAD_ROOT: root,
    TRON_GATEWAY_CHANNEL: channel,
    PATH: path,
  };
}

describe("supervised Gateway Node command environment", () => {
  it("makes a renamed selected runtime the deterministic Stable node command", () => {
    const selected = fixture();
    const ambientDirectory = mkdtempSync(join(tmpdir(), "tron-ambient-node-"));
    roots.push(ambientDirectory);
    executable(join(ambientDirectory, "node"), "ambient");
    const env = environment(selected.root, "stable", `/usr/bin:${ambientDirectory}`);

    const result = configureSupervisedNodeCommandEnvironment({
      environment: env,
      architecture: "arm64",
      execPath: selected.runtime,
      entryPoint: selected.entryPoint,
    });

    expect(result.managed).toBe(true);
    expect(env.PATH?.split(":")[0]).toBe(realpathSync(selected.aliasDirectory));
    const child = spawnSync("node", ["--version"], { env, encoding: "utf8" });
    expect(child.pid).toBeTypeOf("number");
    expect(child.status).toBe(0);
    expect(child.stdout.trim()).toBe("runtime-arm64");
    const piChild = spawnSync("pi", ["--version"], { env, encoding: "utf8" });
    expect(piChild.pid).toBeTypeOf("number");
    expect(piChild.status).toBe(0);
    expect(piChild.stdout.trim()).toBe("pi-cli");
  });

  it("preserves a developer Node first in Debug and supplies the payload fallback once", () => {
    const selected = fixture("x64");
    const developerDirectory = mkdtempSync(join(tmpdir(), "tron-developer-node-"));
    roots.push(developerDirectory);
    executable(join(developerDirectory, "node"), "developer");
    const env = environment(selected.root, "dev", `${developerDirectory}:${selected.aliasDirectory}:${developerDirectory}`);

    configureSupervisedNodeCommandEnvironment({ environment: env, architecture: "x86_64", execPath: selected.runtime, entryPoint: selected.entryPoint });

    expect(env.PATH).toBe(`${developerDirectory}:${developerDirectory}:${realpathSync(selected.aliasDirectory)}`);
    const child = spawnSync("node", ["--version"], { env, encoding: "utf8" });
    expect(child.stdout.trim()).toBe("developer");
  });

  it("uses the immutable alias in Debug when no developer Node resolves", () => {
    const selected = fixture();
    const env = environment(selected.root, "dev", "/usr/bin:/bin");
    configureSupervisedNodeCommandEnvironment({ environment: env, architecture: "arm64", execPath: selected.runtime, entryPoint: selected.entryPoint });
    expect(env.PATH).toBe(`${realpathSync(selected.aliasDirectory)}:/usr/bin:/bin`);
  });

  it("does not change unsupervised or inherited-marker source execution", () => {
    const env = { PATH: "/custom/bin" };
    expect(configureSupervisedNodeCommandEnvironment({ environment: env })).toEqual({ managed: false });
    expect(env.PATH).toBe("/custom/bin");

    const selected = fixture();
    const sourceEntry = join(selected.root, "source-index.js");
    writeFileSync(sourceEntry, "// source entry\n");
    const inherited = environment(selected.root, "stable", "/custom/bin");
    expect(configureSupervisedNodeCommandEnvironment({
      environment: inherited,
      architecture: "arm64",
      execPath: selected.runtime,
      entryPoint: sourceEntry,
    })).toEqual({ managed: false });
    expect(inherited.PATH).toBe("/custom/bin");
  });

  it("rejects a symlinked Pi package root outside the selected payload", () => {
    const escaped = fixture();
    const packageRoot = join(escaped.root, "app", "node_modules", "@earendil-works", "pi-coding-agent");
    const outside = mkdtempSync(join(tmpdir(), "tron-escaped-pi-"));
    roots.push(outside);
    rmSync(packageRoot, { recursive: true, force: true });
    mkdirSync(outside, { recursive: true });
    symlinkSync(outside, packageRoot);
    expect(() => configureSupervisedNodeCommandEnvironment({
      environment: environment(escaped.root, "stable", "/usr/bin"), architecture: "arm64",
      execPath: escaped.runtime, entryPoint: escaped.entryPoint,
    })).toThrow(/package root|projection/);
  });

  it("rejects missing, substituted, and incorrectly targeted aliases", () => {
    const missing = fixture();
    unlinkSync(missing.alias);
    expect(() => configureSupervisedNodeCommandEnvironment({
      environment: environment(missing.root, "stable", "/usr/bin"), architecture: "arm64",
      execPath: missing.runtime, entryPoint: missing.entryPoint,
    })).toThrow();

    const regular = fixture();
    unlinkSync(regular.alias);
    executable(regular.alias, "substitute");
    expect(() => configureSupervisedNodeCommandEnvironment({
      environment: environment(regular.root, "stable", "/usr/bin"), architecture: "arm64",
      execPath: regular.runtime, entryPoint: regular.entryPoint,
    })).toThrow(/not a symbolic link/);

    const wrong = fixture();
    unlinkSync(wrong.alias);
    symlinkSync("../node-x64", wrong.alias);
    expect(() => configureSupervisedNodeCommandEnvironment({
      environment: environment(wrong.root, "stable", "/usr/bin"), architecture: "arm64",
      execPath: wrong.runtime, entryPoint: wrong.entryPoint,
    })).toThrow(/wrong target/);

    const wrongPi = fixture();
    unlinkSync(wrongPi.piAlias);
    symlinkSync("../node-arm64", wrongPi.piAlias);
    expect(() => configureSupervisedNodeCommandEnvironment({
      environment: environment(wrongPi.root, "stable", "/usr/bin"), architecture: "arm64",
      execPath: wrongPi.runtime, entryPoint: wrongPi.entryPoint,
    })).toThrow(/Pi alias has the wrong target/);
  });

  it("rejects a runtime that differs from the running executable and oversized PATH", () => {
    const selected = fixture();
    const other = join(selected.root, "other-node");
    executable(other, "other");
    expect(() => configureSupervisedNodeCommandEnvironment({
      environment: environment(selected.root, "stable", "/usr/bin"), architecture: "arm64",
      execPath: other, entryPoint: selected.entryPoint,
    })).toThrow(/does not match/);
    expect(() => configureSupervisedNodeCommandEnvironment({
      environment: environment(selected.root, "stable", "x".repeat(65 * 1024)), architecture: "arm64",
      execPath: selected.runtime, entryPoint: selected.entryPoint,
    })).toThrow(/oversized/);
  });
});
