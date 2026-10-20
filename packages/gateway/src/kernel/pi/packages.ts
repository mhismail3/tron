import { lstatSync, readFileSync, realpathSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

// Runtime resolution of the pinned Pi SDK (K-0 §4): every place the Gateway finds a Pi
// package on disk instead of importing it. Resolution runs from this file, which sits in
// the same package (and so the same `node_modules`) as every former call site.

const PACKAGE_JSON_MAX_BYTES = 64 * 1024;

/** Where an installed payload's `node_modules` holds `pi-coding-agent`. */
export function piCodingAgentDirectory(nodeModulesRoot: string): string {
  return join(nodeModulesRoot, "@earendil-works", "pi-coding-agent");
}

/** The pinned SDK's own package root (its exports point at dist/index.js), never a
 * user npm tree or a reserved provider install. */
export function piHostPackageRoot(): string {
  return realpathSync(dirname(dirname(fileURLToPath(import.meta.resolve("@earendil-works/pi-coding-agent")))));
}

/** The SDK's bundled CLI, which MCP administration runs. */
export function piCliBundle(): string {
  return join(dirname(fileURLToPath(import.meta.resolve("@earendil-works/pi-coding-agent"))), "bundle/cli.js");
}

/** Exact host peer aliases for loading an installed extension (the managed pi-subagents
 * closure) with its declared TypeScript loader: the Gateway's own SDK modules, `pi-ai`
 * as its `compat` entry, and the SDK's `typebox`. */
export function piExtensionAliases(): Record<string, string> {
  const hostRequire = createRequire(import.meta.resolve("@earendil-works/pi-coding-agent"));
  const aliases: Record<string, string> = {};
  for (const name of ["@earendil-works/pi-coding-agent", "@earendil-works/pi-agent-core", "@earendil-works/pi-tui",
    "@earendil-works/pi-ai/compat", "@earendil-works/pi-ai/oauth", "@earendil-works/pi-ai/providers/all"]) {
    aliases[name] = fileURLToPath(import.meta.resolve(name));
  }
  aliases["@earendil-works/pi-ai"] = aliases["@earendil-works/pi-ai/compat"]!;
  for (const name of ["typebox", "typebox/compile", "typebox/value"]) aliases[name] = hostRequire.resolve(name);
  return aliases;
}

function validatePiCliPackageRoot(packageRoot: string, nodeModulesRoot: string): string {
  const nodeModulesReal = realpathSync(nodeModulesRoot);
  const expected = join(nodeModulesReal, "@earendil-works", "pi-coding-agent");
  const expectedInfo = lstatSync(expected);
  if (!expectedInfo.isDirectory() || expectedInfo.isSymbolicLink()) {
    throw new Error("pi-coding-agent package root is substituted");
  }
  const expectedReal = realpathSync(expected);
  const packageReal = realpathSync(packageRoot);
  const fromNodeModules = relative(nodeModulesReal, packageReal);
  if (packageReal !== expectedReal || fromNodeModules.startsWith("..") || isAbsolute(fromNodeModules)) {
    throw new Error("pi-coding-agent package root is outside the Gateway node_modules");
  }
  return packageReal;
}

/** The pinned `pi` CLI executable (`bin.pi` of the Gateway's own `pi-coding-agent`), for
 * out-of-process work such as session export. */
export function resolvePiCliExecutable(): string {
  const packageEntry = fileURLToPath(import.meta.resolve("@earendil-works/pi-coding-agent"));
  const nodeModulesRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../../..", "node_modules");
  let packageRoot = dirname(packageEntry);
  for (;;) {
    const packageJsonPath = join(packageRoot, "package.json");
    try {
      const packageJsonInfo = lstatSync(packageJsonPath);
      if (!packageJsonInfo.isFile() || packageJsonInfo.isSymbolicLink() || packageJsonInfo.size > PACKAGE_JSON_MAX_BYTES) {
        throw new Error("package.json is missing, substituted, or oversized");
      }
      const packageJson = JSON.parse(readFileSync(packageJsonPath, "utf8")) as { name?: unknown; bin?: unknown };
      if (packageJson.name === "@earendil-works/pi-coding-agent") {
        const bin = typeof packageJson.bin === "object" && packageJson.bin !== null
          ? (packageJson.bin as { pi?: unknown }).pi : undefined;
        if (typeof bin !== "string" || !bin || isAbsolute(bin) || bin.split(/[\\/]/u).includes("..")) {
          throw new Error("declared bin.pi is unsafe or missing");
        }
        const executable = resolve(packageRoot, bin);
        const packageReal = validatePiCliPackageRoot(packageRoot, nodeModulesRoot);
        const executableReal = realpathSync(executable);
        const info = lstatSync(executable);
        if (!executableReal.startsWith(`${packageReal}/`) || !info.isFile() || info.isSymbolicLink()) {
          throw new Error("declared bin.pi is not an executable regular file inside its package");
        }
        if ((info.mode & 0o111) === 0) throw new Error("declared bin.pi is not executable");
        return executable;
      }
    } catch (error) {
      if (error instanceof Error && /declared bin\.pi|not an executable|not executable|package root/u.test(error.message)) throw error;
    }
    const parent = dirname(packageRoot);
    if (parent === packageRoot) break;
    packageRoot = parent;
  }
  throw new Error("could not locate pi-coding-agent package metadata");
}
