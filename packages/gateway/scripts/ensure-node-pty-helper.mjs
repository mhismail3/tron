import {
  accessSync,
  chmodSync,
  constants,
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  readlinkSync,
  realpathSync,
  rmSync,
  symlinkSync,
  unlinkSync,
} from "node:fs";
import { createRequire } from "node:module";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const PACKAGE_JSON_MAX_BYTES = 64 * 1024;

/** Ensure the Darwin node-pty helper remains executable after payload extraction. */
export function ensureNodePtyHelper(platform = process.platform, packageRoot = undefined) {
  if (platform !== "darwin") return;
  const root = packageRoot ?? dirname(createRequire(import.meta.url).resolve("node-pty/package.json"));
  const helper = join(root, "prebuilds", `darwin-${process.arch}`, "spawn-helper");
  if (!existsSync(helper)) throw new Error(`node-pty spawn helper is missing: ${helper}`);
  chmodSync(helper, 0o755);
  accessSync(helper, constants.X_OK);
}

function pathInfo(path) {
  try {
    return lstatSync(path);
  } catch (error) {
    if (error?.code === "ENOENT") return undefined;
    throw error;
  }
}

function removeWithoutFollowing(path) {
  const info = pathInfo(path);
  if (!info) return;
  if (info.isDirectory() && !info.isSymbolicLink()) rmSync(path, { recursive: true, force: true });
  else unlinkSync(path);
}

/**
 * Supply the immutable runtime aliases while npm is assembling a source-built
 * payload. This lifecycle bridge is necessary when the selected predecessor
 * payload predates the alias contract: the predecessor updater copies this
 * trusted script before running npm ci, but otherwise inherits its old runtime
 * tree byte-for-byte. Ordinary workspace installs have no sibling runtime and
 * remain unchanged.
 */
export function ensurePayloadNodeAliases(platform = process.platform, appRoot = undefined) {
  if (platform !== "darwin") return false;
  const app = resolve(appRoot ?? join(dirname(fileURLToPath(import.meta.url)), ".."));
  const runtimeRoot = resolve(app, "..", "runtime");
  const runtimes = ["arm64", "x64"].map((architecture) => ({
    architecture,
    path: join(runtimeRoot, `node-${architecture}`),
  }));
  const runtimeInfo = runtimes.map(({ path }) => pathInfo(path));
  if (runtimeInfo.every((info) => info === undefined)) return false;

  for (let index = 0; index < runtimes.length; index += 1) {
    const { architecture, path } = runtimes[index];
    const info = runtimeInfo[index];
    if (!info?.isFile() || info.isSymbolicLink()) throw new Error(`payload Node runtime is missing or substituted: ${architecture}`);
    accessSync(path, constants.X_OK);
  }
  const nodeModulesRoot = join(app, "node_modules");
  const packageRoot = join(nodeModulesRoot, "@earendil-works", "pi-coding-agent");
  const piCli = join(nodeModulesRoot, ".bin", "pi");
  const nodeModulesInfo = pathInfo(nodeModulesRoot);
  const packageRootInfo = pathInfo(packageRoot);
  const piCliInfo = pathInfo(piCli);
  if (!nodeModulesInfo?.isDirectory() || nodeModulesInfo.isSymbolicLink()
    || !packageRootInfo?.isDirectory() || packageRootInfo.isSymbolicLink()
    || !piCliInfo?.isSymbolicLink()) throw new Error("payload npm Pi projection or package root is missing or substituted");
  let declaredBin;
  try {
    const packageJsonPath = join(packageRoot, "package.json");
    const packageJsonInfo = pathInfo(packageJsonPath);
    if (!packageJsonInfo?.isFile() || packageJsonInfo.isSymbolicLink() || packageJsonInfo.size > PACKAGE_JSON_MAX_BYTES) {
      throw new Error("package metadata is missing, substituted, or oversized");
    }
    const packageJson = JSON.parse(readFileSync(packageJsonPath, "utf8"));
    declaredBin = typeof packageJson.bin === "object" && packageJson.bin !== null ? packageJson.bin.pi : undefined;
  } catch {
    throw new Error("payload pi-coding-agent package metadata is missing or invalid");
  }
  if (typeof declaredBin !== "string" || !declaredBin || isAbsolute(declaredBin) || declaredBin.split(/[\\/]/u).includes("..")) {
    throw new Error("payload pi-coding-agent bin.pi is unsafe or missing");
  }
  const declaredPath = resolve(packageRoot, declaredBin);
  const appReal = realpathSync(app);
  const nodeModulesReal = realpathSync(nodeModulesRoot);
  const packageRootReal = realpathSync(packageRoot);
  const piCliReal = realpathSync(piCli);
  if (!nodeModulesReal.startsWith(`${appReal}/`) || !packageRootReal.startsWith(`${nodeModulesReal}/`)
    || !piCliReal.startsWith(`${packageRootReal}/`)) throw new Error("payload npm Pi projection or package root escapes app/node_modules");
  const declaredReal = realpathSync(declaredPath);
  const declaredInfo = lstatSync(declaredPath);
  if (!declaredInfo.isFile() || declaredInfo.isSymbolicLink() || readlinkSync(piCli) !== relative(dirname(piCli), declaredPath)
    || realpathSync(declaredPath) !== piCliReal) {
    throw new Error("payload npm Pi projection disagrees with pi-coding-agent bin.pi");
  }
  accessSync(piCli, constants.X_OK);
  const piTarget = "../../app/node_modules/.bin/pi";

  for (const { architecture, path: runtime } of runtimes) {
    const aliasDirectory = join(runtimeRoot, `bin-${architecture}`);
    const nodeAlias = join(aliasDirectory, "node");
    const piAlias = join(aliasDirectory, "pi");
    removeWithoutFollowing(aliasDirectory);
    mkdirSync(aliasDirectory, { recursive: false, mode: 0o755 });
    symlinkSync(`../node-${architecture}`, nodeAlias);
    symlinkSync(piTarget, piAlias);
    if (readlinkSync(nodeAlias) !== `../node-${architecture}` || realpathSync(nodeAlias) !== realpathSync(runtime)) {
      throw new Error(`payload Node alias validation failed: ${architecture}`);
    }
    if (readlinkSync(piAlias) !== piTarget || realpathSync(piAlias) !== piCliReal || declaredReal !== piCliReal) {
      throw new Error(`payload Pi alias validation failed: ${architecture}`);
    }
  }
  return true;
}

ensureNodePtyHelper();
ensurePayloadNodeAliases();
