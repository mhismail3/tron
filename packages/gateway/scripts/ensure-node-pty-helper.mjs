import {
  accessSync,
  chmodSync,
  constants,
  existsSync,
  lstatSync,
  mkdirSync,
  readlinkSync,
  realpathSync,
  rmSync,
  symlinkSync,
  unlinkSync,
} from "node:fs";
import { createRequire } from "node:module";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

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
  const piCli = join(app, "node_modules", "@earendil-works", "pi-coding-agent", "dist", "cli.js");
  const piCliInfo = pathInfo(piCli);
  if (!piCliInfo?.isFile() || piCliInfo.isSymbolicLink()) throw new Error("payload Pi CLI is missing or substituted");
  accessSync(piCli, constants.X_OK);
  const piTarget = "../../app/node_modules/@earendil-works/pi-coding-agent/dist/cli.js";

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
    if (readlinkSync(piAlias) !== piTarget || realpathSync(piAlias) !== realpathSync(piCli)) {
      throw new Error(`payload Pi alias validation failed: ${architecture}`);
    }
  }
  return true;
}

ensureNodePtyHelper();
ensurePayloadNodeAliases();
