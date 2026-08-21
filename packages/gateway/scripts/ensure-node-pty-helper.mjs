import { chmodSync, existsSync, accessSync, constants } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";

/** Ensure the Darwin node-pty helper remains executable after payload extraction. */
export function ensureNodePtyHelper(platform = process.platform, packageRoot = undefined) {
  if (platform !== "darwin") return;
  const root = packageRoot ?? dirname(createRequire(import.meta.url).resolve("node-pty/package.json"));
  const helper = join(root, "prebuilds", `darwin-${process.arch}`, "spawn-helper");
  if (!existsSync(helper)) throw new Error(`node-pty spawn helper is missing: ${helper}`);
  chmodSync(helper, 0o755);
  accessSync(helper, constants.X_OK);
}

ensureNodePtyHelper();
