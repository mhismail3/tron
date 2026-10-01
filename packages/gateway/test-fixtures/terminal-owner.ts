import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { afterAll } from "vitest";

export const nativeFixtureDirectory = mkdtempSync("/tmp/tron-terminal-test-");
export const nativeFixtureExecutable = join(nativeFixtureDirectory, "terminal-owner");
export const nativeOwnerSource = decodeURIComponent(new URL("../native/terminal-owner.c", import.meta.url).pathname);
execFileSync("xcrun", ["--sdk", "macosx", "clang", "-O2", "-Wall", "-Wextra", "-Werror",
  "-mmacosx-version-min=15.0", nativeOwnerSource, "-o", nativeFixtureExecutable]);
afterAll(() => { rmSync(nativeFixtureDirectory, { recursive: true, force: true }); });
